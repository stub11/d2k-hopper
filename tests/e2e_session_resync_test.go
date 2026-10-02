package tests

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"github.com/necronicle/d2k/internal/control"
	"reflect"
	"testing"
	"time"
)

func TestE2ERealRingLossResync(t *testing.T) {
	b := startBridge(t, "loss")
	send := func(line string) {
		t.Helper()
		if _, err := fmt.Fprintln(b.in, line); err != nil {
			t.Fatal(err)
		}
		if !b.out.Scan() || b.out.Text() == "error" {
			t.Fatalf("probe %q", b.out.Text())
		}
	}
	packets := [][]byte{rawPacket(4, false, true, 0, 0, 0, "a"), rawPacket(6, false, true, 0, 0, 0, "b"), rawPacket(4, false, true, 0, 0, 0, "c")}
	packets[2][20] = 0x23
	packets[2][21] = 0x45
	packets[2][26] = 0
	packets[2][27] = 0
	pseudo := append(append([]byte(nil), packets[2][12:20]...), 0, 17, 0, byte(len(packets[2])-20))
	sum := checksum(append(pseudo, packets[2][20:]...))
	if sum == 0 {
		sum = 65535
	}
	binary.BigEndian.PutUint16(packets[2][26:], sum) // distinct source port
	for i, p := range packets {
		send(fmt.Sprintf("hold %d %s", i+1, hex.EncodeToString(p)))
	}
	send("pump")
	read := func() control.Event {
		t.Helper()
		b.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		e, err := b.conn.Next()
		if err != nil {
			t.Fatal(err)
		}
		return e
	}
	if e := read(); e.Session == nil || e.Session.Sequence != 1 {
		t.Fatal("retained oldest event missing")
	}
	if e := read(); e.Snapshot == nil || e.Snapshot.Type != control.EvSessionWatermark || e.Snapshot.Cut != 3 || e.Snapshot.Aux != 2 {
		t.Fatal("actual overflow not detected")
	}
	if _, complete, _ := b.conn.SessionMirror().Active(); complete {
		t.Fatal("loss reported as complete")
	}
	// Next automatically requested a C dump; pumping reads the real command.
	send("pump")
	for i := 0; i < 6; i++ {
		read()
	} // BEGIN, three ROWs, END, watermark
	full := b.conn.SessionMirror().FullDump()
	active, complete, seq := b.conn.SessionMirror().Active()
	if !complete || len(full) != 3 || len(active) != 3 || seq != 3 {
		t.Fatalf("bad resync: full=%d active=%d complete=%v seq=%d", len(full), len(active), complete, seq)
	}
	expected := make(map[control.SessionID]control.TCPState)
	for i, packet := range packets {
		key := control.Key{Family: packet[0] >> 4}
		ip := 20
		if key.Family == 4 {
			copy(key.LowIP[:], packet[12:16])
			copy(key.HighIP[:], packet[16:20])
		} else {
			ip = 40
			copy(key.LowIP6[:], packet[8:24])
			copy(key.HighIP6[:], packet[24:40])
		}
		key.LowPort = binary.BigEndian.Uint16(packet[ip:])
		key.HighPort = binary.BigEndian.Uint16(packet[ip+2:])
		id := control.SessionID{Key: key, Protocol: 17}
		expected[id] = control.TCPUnknown
		rec, exists := full[id]
		if !exists || rec.FirstNS != uint64(i+1) || rec.LastNS != uint64(i+1) || rec.State != control.TCPUnknown {
			t.Fatalf("C snapshot differs from injected flow: %#v %#v", id, rec)
		}
	}
	if !reflect.DeepEqual(active, expected) {
		t.Fatal("identity/state map differs from complete C dump")
	}
	// Expiration loses two tail close events; recover the exact empty map.
	send("expire 100")
	read()
	read()
	send("pump")
	read()
	read()
	read()
	active, complete, _ = b.conn.SessionMirror().Active()
	if !complete || len(active) != 0 || len(b.conn.SessionMirror().FullDump()) != 0 {
		t.Fatal("timeout loss did not resync empty map")
	}
	t.Log("real C ring capacity=1: loss -> automatic dump -> exact 3-session map -> timeout loss -> exact empty map")
}
