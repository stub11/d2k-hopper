package tests

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"github.com/necronicle/d2k/internal/control"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type bridge struct {
	in       io.WriteCloser
	out      *bufio.Scanner
	conn     *control.Conn
	sequence uint64
}

func startBridge(t testing.TB, mode string) *bridge {
	t.Helper()
	bin, err := filepath.Abs("../datapath/pipelineprobe")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(bin); err != nil {
		t.Fatalf("required C pipelineprobe missing: %v", err)
	}
	dir, err := os.MkdirTemp("/tmp", "d2k-state-")
	if err != nil {
		t.Fatal(err)
	}
	sock := filepath.Join(dir, "ctl.sock")
	cmd := exec.Command(bin, sock, mode)
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = fmt.Fprintln(in, "quit")
		_ = in.Close()
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case <-done:
		case <-time.After(time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
		_ = os.RemoveAll(dir)
	})
	scanner := bufio.NewScanner(out)
	if !scanner.Scan() || scanner.Text() != "ready" {
		t.Fatalf("C probe startup: %q", scanner.Text())
	}
	conn, err := control.Dial(sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return &bridge{in: in, out: scanner, conn: conn}
}
func (b *bridge) command(t testing.TB, command string, verdict uint64) []control.SessionEvent {
	t.Helper()
	if _, err := fmt.Fprintln(b.in, command); err != nil {
		t.Fatal(err)
	}
	if !b.out.Scan() {
		t.Fatalf("C probe stopped: %v", b.out.Err())
	}
	fields := strings.Fields(b.out.Text())
	if len(fields) != 6 {
		t.Fatalf("C response %q", b.out.Text())
	}
	nums := make([]uint64, 6)
	for i, v := range fields {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			t.Fatal(err)
		}
		nums[i] = n
	}
	if nums[0] != verdict {
		t.Fatalf("verdict got %d want %d: %s", nums[0], verdict, command)
	}
	if nums[5] != 0 {
		t.Fatalf("unexpected ring loss %d", nums[5])
	}
	events := make([]control.SessionEvent, 0, nums[3])
	for i := uint64(0); i < nums[3]; {
		if err := b.conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
			t.Fatal(err)
		}
		e, err := b.conn.Next()
		if err != nil {
			t.Fatal(err)
		}
		if e.Snapshot != nil {
			continue
		}
		if e.Session == nil {
			t.Fatalf("not a session event: %#v", e)
		}
		i++
		s := *e.Session
		if s.Sequence != b.sequence+1 {
			t.Fatalf("event sequence gap %d -> %d", b.sequence, s.Sequence)
		}
		b.sequence = s.Sequence
		events = append(events, s)
	}
	return events
}
func checksum(b []byte) uint16 {
	var sum uint32
	for len(b) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(b))
		b = b[2:]
	}
	if len(b) > 0 {
		sum += uint32(b[0]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 65535) + (sum >> 16)
	}
	return ^uint16(sum)
}

// Complete IP/TCP/UDP wire packets, including valid checksums. Both directions
// enter the actual C parser; Go does not send precomputed keys/states/verdicts.
func rawPacket(family int, reverse, udp bool, flags byte, seq, ack uint32, payload string) []byte {
	ip, l4 := 20, 20
	if family == 6 {
		ip = 40
	}
	if udp {
		l4 = 8
	}
	b := make([]byte, ip+l4+len(payload))
	proto := byte(6)
	if udp {
		proto = 17
	}
	var src, dst []byte
	if family == 4 {
		b[0] = 0x45
		b[8] = 64
		b[9] = proto
		binary.BigEndian.PutUint16(b[2:4], uint16(len(b)))
		copy(b[12:16], []byte{10, 0, 0, 1})
		copy(b[16:20], []byte{10, 0, 0, 2})
		src, dst = b[12:16], b[16:20]
	} else {
		b[0] = 0x60
		b[6] = proto
		b[7] = 64
		binary.BigEndian.PutUint16(b[4:6], uint16(len(b)-40))
		copy(b[8:12], []byte{0x20, 1, 0x0d, 0xb8})
		copy(b[24:28], b[8:12])
		b[23] = 1
		b[39] = 2
		src, dst = b[8:24], b[24:40]
	}
	if reverse {
		tmp := append([]byte(nil), src...)
		copy(src, dst)
		copy(dst, tmp)
	}
	low, high := uint16(1234), uint16(443)
	if reverse {
		low, high = high, low
	}
	binary.BigEndian.PutUint16(b[ip:ip+2], low)
	binary.BigEndian.PutUint16(b[ip+2:ip+4], high)
	checkOffset := ip + 16
	if udp {
		binary.BigEndian.PutUint16(b[ip+4:ip+6], uint16(len(b)-ip))
		checkOffset = ip + 6
	} else {
		binary.BigEndian.PutUint32(b[ip+4:ip+8], seq)
		binary.BigEndian.PutUint32(b[ip+8:ip+12], ack)
		b[ip+12] = 0x50
		b[ip+13] = flags
		binary.BigEndian.PutUint16(b[ip+14:ip+16], 4096)
	}
	copy(b[ip+l4:], payload)
	pseudo := append(append([]byte(nil), src...), dst...)
	if family == 4 {
		pseudo = append(pseudo, 0, proto, byte((len(b)-ip)>>8), byte(len(b)-ip))
	} else {
		length := make([]byte, 4)
		binary.BigEndian.PutUint32(length, uint32(len(b)-ip))
		pseudo = append(pseudo, length...)
		pseudo = append(pseudo, 0, 0, 0, proto)
	}
	c := checksum(append(pseudo, b[ip:]...))
	if udp && c == 0 {
		c = 65535
	}
	binary.BigEndian.PutUint16(b[checkOffset:checkOffset+2], c)
	if family == 4 {
		binary.BigEndian.PutUint16(b[10:12], checksum(b[:20]))
	}
	return b
}
func (b *bridge) packet(t testing.TB, now uint64, packet []byte, verdict uint64) []control.SessionEvent {
	return b.command(t, fmt.Sprintf("packet %d %s", now, hex.EncodeToString(packet)), verdict)
}
func TestE2EStatefulPipeline(t *testing.T) {
	for _, family := range []int{4, 6} {
		t.Run(fmt.Sprint(family), func(t *testing.T) {
			b := startBridge(t, "enforce")
			var events []control.SessionEvent
			// Reject without changing session state or publishing created events.
			if e := b.packet(t, 0, rawPacket(family, false, false, 0x18, 101, 201, "early"), 0); len(e) != 0 {
				t.Fatal("early DATA created events")
			}
			b.packet(t, 0, rawPacket(family, false, false, 0x03, 100, 0, ""), 0)
			cases := []struct {
				reverse  bool
				flags    byte
				seq, ack uint32
				data     string
				verdict  uint64
			}{
				{false, 2, 100, 0, "", 1}, {true, 0x12, 200, 101, "", 1},
				{false, 0x10, 101, 201, "", 1}, {false, 0x18, 101, 201, "hello", 1},
				{true, 0x18, 201, 106, "world", 1}, {false, 0x11, 106, 206, "", 1},
				{true, 0x10, 206, 107, "", 1}, {true, 0x11, 206, 107, "", 1},
				{false, 0x10, 107, 207, "", 1}, {false, 0x18, 107, 207, "late", 0},
			}
			for i, c := range cases {
				events = append(events, b.packet(t, uint64(i+1), rawPacket(family, c.reverse, false, c.flags, c.seq, c.ack, c.data), c.verdict)...)
			}
			if len(events) != 7 {
				t.Fatalf("events=%d", len(events))
			}
			want := []control.TCPState{control.TCPUnknown, control.TCPSynSent, control.TCPSynRecv, control.TCPEstablished, control.TCPFinWait, control.TCPClosed, control.TCPClosed}
			for i, e := range events {
				if e.Key.Family != uint8(family) || e.Key.LowPort != 1234 || e.Key.HighPort != 443 || e.New != want[i] {
					t.Fatalf("event %d %#v", i, e)
				}
			}
			if events[6].Type != control.EvSessionClosed || events[6].Reason != control.CloseFIN {
				t.Fatal("FIN close missing")
			}
			// RST produces exactly one close; retention expiry cannot duplicate it.
			b.packet(t, 12, rawPacket(family, false, false, 2, 300, 0, ""), 1)
			reset := b.packet(t, 13, rawPacket(family, true, false, 0x14, 0, 301, ""), 1)
			if len(reset) != 2 || reset[1].Reason != control.CloseRST {
				t.Fatal("RST close missing")
			}
			if e := b.command(t, "expire 18", 1); len(e) != 0 {
				t.Fatal("terminal expiry duplicated close")
			}
			udp := b.packet(t, 20, rawPacket(family, false, true, 0, 0, 0, "query"), 1)
			if len(udp) != 1 || udp[0].Protocol != 17 {
				t.Fatal("UDP create missing")
			}
			b.packet(t, 21, rawPacket(family, true, true, 0, 0, 0, "reply"), 1)
			b.command(t, "expire 70", 1)
			closed := b.command(t, "expire 71", 1)
			if len(closed) != 1 || closed[0].Reason != control.CloseTimeout || closed[0].Protocol != 17 {
				t.Fatal("UDP timeout missing")
			}
		})
	}
}
func TestE2EObserveAndLoad(t *testing.T) {
	b := startBridge(t, "observe")
	e := b.packet(t, 0, rawPacket(4, false, false, 0x18, 0, 0, "midstream"), 1)
	if len(e) != 1 || e[0].New != control.TCPUnknown {
		t.Fatal("observe must preserve UNKNOWN")
	}
	b.command(t, "expire 50", 1)
	for i := 0; i < 1000; i++ {
		now := uint64(100 + i*5)
		b.packet(t, now, rawPacket(6, false, false, 2, 100, 0, ""), 1)
		b.packet(t, now+1, rawPacket(6, true, false, 0x12, 200, 101, ""), 1)
		b.packet(t, now+2, rawPacket(6, false, false, 0x10, 101, 201, ""), 1)
		e = b.packet(t, now+3, rawPacket(6, true, false, 4, 0, 0, ""), 1)
		if len(e) != 2 || e[1].Reason != control.CloseRST {
			t.Fatalf("load cycle %d lost close", i)
		}
	}
}
