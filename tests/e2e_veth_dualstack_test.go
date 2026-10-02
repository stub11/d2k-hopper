//go:build linux

package tests

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"github.com/necronicle/d2k/internal/control"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// Explicit privileged gate, mandatory in CI with D2K_REQUIRE_VETH=1. Ordinary
// developer/go race tests need neither root nor host firewall modification.
func TestE2EVethDualStack(t *testing.T) {
	if os.Getenv("D2K_REQUIRE_VETH") != "1" {
		t.Skip("run privileged CI gate with D2K_REQUIRE_VETH=1")
	}
	if os.Geteuid() != 0 {
		t.Fatal("mandatory veth gate requires root")
	}
	suffix := strconv.FormatInt(time.Now().UnixNano(), 16)
	suffix = suffix[len(suffix)-7:]
	client, server := "d2k-client-"+suffix, "d2k-server-"+suffix
	va, vb := "d2ka"+suffix, "d2kb"+suffix
	run := func(args ...string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, args[0], args[1:]...).CombinedOutput()
		if err != nil {
			t.Fatalf("%v: %v\n%s", args, err, out)
		}
	}
	t.Cleanup(func() {
		for _, ns := range []string{client, server} {
			_ = exec.Command("ip", "netns", "del", ns).Run()
		}
		_ = exec.Command("ip", "link", "del", va).Run()
	})
	run("ip", "netns", "add", client)
	run("ip", "netns", "add", server)
	run("ip", "link", "add", va, "type", "veth", "peer", "name", vb)
	run("ip", "link", "set", va, "netns", client)
	run("ip", "link", "set", vb, "netns", server)
	for i, ns := range []string{client, server} {
		iface := []string{va, vb}[i]
		run("ip", "-n", ns, "link", "set", "lo", "up")
		run("ip", "-n", ns, "addr", "add", fmt.Sprintf("10.201.0.%d/24", i+1), "dev", iface)
		run("ip", "-n", ns, "-6", "addr", "add", fmt.Sprintf("fd00:d2:71::%d/64", i+1), "dev", iface, "nodad")
		run("ip", "-n", ns, "link", "set", iface, "up")
	}
	for _, tool := range []string{"iptables", "ip6tables"} {
		for _, proto := range []string{"tcp", "udp"} {
			port := "44001"
			if proto == "udp" {
				port = "44002"
			}
			for _, direction := range []struct{ chain, opt string }{{"INPUT", "--dport"}, {"OUTPUT", "--sport"}} {
				run("ip", "netns", "exec", server, tool, "-t", "mangle", "-A", direction.chain, "-p", proto, direction.opt, port, "-j", "NFQUEUE", "--queue-num", "71")
			}
		}
	}
	probePath := os.Getenv("D2K_NFQ_PROBE")
	if probePath == "" {
		probePath = "../datapath/nfqueue_libprobe"
	}
	probe, err := filepath.Abs(probePath)
	if err != nil {
		t.Fatal(err)
	}
	// Run without ip-exec parent so Process.Signal reaches the actual lab process.
	nfq := exec.Command("ip", "netns", "exec", server, probe, "71", "0")
	var stderr bytes.Buffer
	nfq.Stderr = &stderr
	out, err := nfq.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = nfq.Start(); err != nil {
		t.Fatal(err)
	}
	finished := false
	t.Cleanup(func() {
		if !finished {
			_ = nfq.Process.Kill()
			_ = nfq.Wait()
		}
	})
	lines := make(chan string, 4096)
	scanErr := make(chan error, 1)
	go func() {
		s := bufio.NewScanner(out)
		for s.Scan() {
			lines <- s.Text()
		}
		scanErr <- s.Err()
		close(lines)
	}()
	select {
	case line := <-lines:
		if line != "ready" {
			t.Fatalf("NFQUEUE startup %q %s", line, stderr.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("queue startup timeout")
	}
	binaryPath, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	helper := func(ns, mode string) *exec.Cmd {
		c := exec.Command("ip", "netns", "exec", ns, binaryPath, "-test.run=^TestVethHelper$")
		c.Env = append(os.Environ(), "D2K_VETH_HELPER="+mode)
		return c
	}
	srv := helper(server, "server")
	var serverErr bytes.Buffer
	srv.Stderr = &serverErr
	srvOut, err := srv.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = srv.Start(); err != nil {
		t.Fatal(err)
	}
	srvDone := false
	t.Cleanup(func() {
		if !srvDone {
			_ = srv.Process.Kill()
			_ = srv.Wait()
		}
	})
	serverScan := bufio.NewScanner(srvOut)
	if !serverScan.Scan() || serverScan.Text() != "listeners ready" {
		t.Fatal("server startup")
	}
	cli := helper(client, "client")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// CommandContext ensures socket/deadline bugs cannot hang a privileged gate.
	cli = exec.CommandContext(ctx, "ip", cli.Args[1:]...)
	cli.Env = append(os.Environ(), "D2K_VETH_HELPER=client")
	if output, e := cli.CombinedOutput(); e != nil {
		t.Fatalf("real dual-stack traffic: %v %s", e, output)
	}
	for serverScan.Scan() {
	} // server checks both TCP payloads and UDP payloads before exiting
	if err = srv.Wait(); err != nil {
		t.Fatalf("server %v %s", err, serverErr.String())
	}
	srvDone = true
	bad := helper(client, "invalid")
	if output, e := bad.CombinedOutput(); e != nil {
		t.Fatalf("invalid traffic %v %s", e, output)
	}
	time.Sleep(300 * time.Millisecond) // bounded delivery grace for terminal ACKs
	if err = nfq.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err = <-scanErr:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("queue shutdown/EOF timeout")
	}
	if err = nfq.Wait(); err != nil {
		finished = true
		t.Fatalf("queue %v %s", err, stderr.String())
	}
	finished = true
	var events []control.SessionEvent
	var rows [][]byte
	drops, accepts := 0, 0
	for line := range lines {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		switch f[0] {
		case "V":
			if f[2] == "0" {
				drops++
			} else {
				accepts++
			}
		case "EV":
			kind, e := strconv.ParseUint(f[1], 10, 16)
			if e != nil {
				t.Fatal(e)
			}
			wire, e := hex.DecodeString(f[2])
			if e != nil {
				t.Fatal(e)
			}
			event, e := control.DecodeSessionEvent(uint16(kind), wire)
			if e != nil {
				t.Fatal(e)
			}
			events = append(events, event)
		case "ROW":
			wire, e := hex.DecodeString(f[1])
			if e != nil {
				t.Fatal(e)
			}
			rows = append(rows, wire)
		}
	}
	if drops != 4 || accepts < 16 {
		t.Fatalf("real verdicts accepts=%d drops=%d", accepts, drops)
	}
	created := make(map[control.SessionID]int)
	established, closed := map[uint8]int{}, map[uint8]int{}
	for i, e := range events {
		if e.Sequence != uint64(i+1) || e.Dropped != 0 {
			t.Fatal("event loss")
		}
		id := control.SessionID{Key: e.Key, Protocol: e.Protocol}
		if e.Type == control.EvSessionCreated {
			created[id]++
		}
		if e.Type == control.EvStateChanged && e.New == control.TCPEstablished {
			established[e.Key.Family]++
		}
		if e.Type == control.EvSessionClosed && e.Reason == control.CloseFIN {
			closed[e.Key.Family]++
		}
	}
	if len(created) != 4 || established[4] != 1 || established[6] != 1 || closed[4] != 1 || closed[6] != 1 {
		t.Fatalf("dual-stack states: created=%d established=%v FIN=%v", len(created), established, closed)
	}
	for id, n := range created {
		if n != 1 {
			t.Fatalf("bidirectional identity duplicated: %#v", id)
		}
	}
	udpRows := 0
	for i, r := range rows {
		wire := make([]byte, 112)
		wire[0] = 1
		binary.BigEndian.PutUint64(wire[8:], 1)
		binary.BigEndian.PutUint64(wire[24:], uint64(i))
		copy(wire[32:], r)
		f, e := control.DecodeSnapshotFrame(control.EvDumpRow, wire)
		if e != nil {
			t.Fatal(e)
		}
		if f.Record.ID.Protocol == 17 {
			udpRows++
			if f.Record.LastNS <= f.Record.FirstNS {
				t.Fatal("reverse UDP did not refresh one session")
			}
		}
	}
	if udpRows != 2 {
		t.Fatalf("UDP dump rows %d", udpRows)
	}
	t.Logf("dual-stack veth + real NFQUEUE: PASS accepts=%d drops=%d sessions=4 TCP ESTABLISHED/FIN IPv4+IPv6 UDP reverse identity", accepts, drops)
}

// Helper code runs the SAME Go test binary inside an isolated namespace.
func TestVethHelper(t *testing.T) {
	mode := os.Getenv("D2K_VETH_HELPER")
	if mode == "" {
		t.Skip("namespace helper")
	}
	if mode == "invalid" {
		for _, family := range []int{4, 6} {
			for _, flags := range []byte{0x18, 0x03} {
				p := rawPacket(family, false, false, flags, 100, 200, "")
				if flags == 0x18 {
					p = rawPacket(family, false, false, flags, 100, 200, "early")
				}
				ip := 20
				domain := syscall.AF_INET
				var sa syscall.Sockaddr
				if family == 4 {
					copy(p[12:16], net.ParseIP("10.201.0.1").To4())
					copy(p[16:20], net.ParseIP("10.201.0.2").To4())
					sa = &syscall.SockaddrInet4{Addr: [4]byte{10, 201, 0, 2}}
				} else {
					ip = 40
					domain = syscall.AF_INET6
					copy(p[8:24], net.ParseIP("fd00:d2:71::1").To16())
					copy(p[24:40], net.ParseIP("fd00:d2:71::2").To16())
					var addr [16]byte
					copy(addr[:], p[24:40])
					sa = &syscall.SockaddrInet6{Addr: addr}
				}
				binary.BigEndian.PutUint16(p[ip:], 45000+uint16(flags))
				binary.BigEndian.PutUint16(p[ip+2:], 44001)
				p[ip+16] = 0
				p[ip+17] = 0
				var pseudo []byte
				if family == 4 {
					pseudo = append(pseudo, p[12:20]...)
					pseudo = append(pseudo, 0, 6, byte((len(p)-ip)>>8), byte(len(p)-ip))
					p[10] = 0
					p[11] = 0
					binary.BigEndian.PutUint16(p[10:], checksum(p[:20]))
				} else {
					pseudo = append(pseudo, p[8:40]...)
					pseudo = append(pseudo, 0, 0, 0, byte(len(p)-ip), 0, 0, 0, 6)
				}
				binary.BigEndian.PutUint16(p[ip+16:], checksum(append(pseudo, p[ip:]...)))
				fd, err := syscall.Socket(domain, syscall.SOCK_RAW, syscall.IPPROTO_RAW)
				if err != nil {
					t.Fatal(err)
				}
				err = syscall.Sendto(fd, p, 0, sa)
				syscall.Close(fd)
				if err != nil {
					t.Fatal(err)
				}
			}
		}
		return
	}
	addresses := []string{"10.201.0.2", "fd00:d2:71::2"}
	if mode == "client" {
		for i, addr := range addresses {
			network := []string{"tcp4", "tcp6"}[i]
			conn, err := net.DialTimeout(network, net.JoinHostPort(addr, "44001"), 3*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			tcp := conn.(*net.TCPConn)
			tcp.SetDeadline(time.Now().Add(3 * time.Second))
			fmt.Fprint(tcp, "hello")
			if err = tcp.CloseWrite(); err != nil {
				t.Fatal(err)
			}
			reply, err := io.ReadAll(tcp)
			tcp.Close()
			if err != nil || string(reply) != "reply:hello" {
				t.Fatalf("TCP exchange %q %v", reply, err)
			}
			udp, err := net.DialTimeout([]string{"udp4", "udp6"}[i], net.JoinHostPort(addr, "44002"), 3*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			udp.SetDeadline(time.Now().Add(3 * time.Second))
			fmt.Fprint(udp, "query")
			b := make([]byte, 100)
			n, err := udp.Read(b)
			udp.Close()
			if err != nil || string(b[:n]) != "reply:query" {
				t.Fatalf("UDP exchange %q %v", b[:n], err)
			}
		}
		return
	}
	if mode != "server" {
		t.Fatal("unknown helper mode")
	}
	var wg sync.WaitGroup
	fail := make(chan error, 4)
	for i, addr := range addresses {
		tcp, err := net.ListenTCP([]string{"tcp4", "tcp6"}[i], &net.TCPAddr{IP: net.ParseIP(addr), Port: 44001})
		if err != nil {
			t.Fatal(err)
		}
		udp, err := net.ListenUDP([]string{"udp4", "udp6"}[i], &net.UDPAddr{IP: net.ParseIP(addr), Port: 44002})
		if err != nil {
			t.Fatal(err)
		}
		wg.Add(2)
		go func() {
			defer wg.Done()
			defer tcp.Close()
			tcp.SetDeadline(time.Now().Add(5 * time.Second))
			c, e := tcp.AcceptTCP()
			if e != nil {
				fail <- e
				return
			}
			defer c.Close()
			c.SetDeadline(time.Now().Add(3 * time.Second))
			data, e := io.ReadAll(c)
			if e != nil || string(data) != "hello" {
				fail <- fmt.Errorf("TCP input %q %v", data, e)
				return
			}
			_, e = c.Write(append([]byte("reply:"), data...))
			if e == nil {
				e = c.CloseWrite()
			}
			if e != nil {
				fail <- e
			}
		}()
		go func() {
			defer wg.Done()
			defer udp.Close()
			udp.SetDeadline(time.Now().Add(5 * time.Second))
			b := make([]byte, 100)
			n, a, e := udp.ReadFromUDP(b)
			if e != nil || string(b[:n]) != "query" {
				fail <- fmt.Errorf("UDP input %q %v", b[:n], e)
				return
			}
			_, e = udp.WriteToUDP(append([]byte("reply:"), b[:n]...), a)
			if e != nil {
				fail <- e
			}
		}()
	}
	fmt.Println("listeners ready")
	wg.Wait()
	close(fail)
	for e := range fail {
		t.Error(e)
	}
}
