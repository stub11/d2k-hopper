package control

import (
	"encoding/binary"
	"testing"
	"time"
)

func snapshotHeader(kind uint16, id, cut, aux uint64) []byte {
	n := 32
	if kind == EvDumpRow {
		n += 80
	}
	b := make([]byte, n)
	b[0] = 1
	binary.BigEndian.PutUint64(b[8:], id)
	binary.BigEndian.PutUint64(b[16:], cut)
	binary.BigEndian.PutUint64(b[24:], aux)
	return b
}
func snapshotRow(id, cut, index uint64, proto byte, port uint16, state TCPState) []byte {
	b := snapshotHeader(EvDumpRow, id, cut, index)
	r := b[32:]
	r[0] = 4
	r[4] = 10
	r[7] = 1
	r[20] = 10
	r[23] = 2
	binary.BigEndian.PutUint16(r[36:], port)
	binary.BigEndian.PutUint16(r[38:], 443)
	r[40] = proto
	r[41] = byte(state)
	binary.BigEndian.PutUint64(r[48:], 10)
	binary.BigEndian.PutUint64(r[56:], 20)
	return b
}
func TestSessionResyncAtomicAndRetry(t *testing.T) {
	m := NewSessionMirror(4)
	key := Key{Family: 4, LowIP: [4]byte{10, 0, 0, 1}, HighIP: [4]byte{10, 0, 0, 2}, LowPort: 1000, HighPort: 443}
	m.ApplyEvent(SessionEvent{Type: EvSessionCreated, Key: key, Protocol: 6, Sequence: 1})
	m.ApplyEvent(SessionEvent{Type: EvStateChanged, Key: key, Protocol: 6, Sequence: 3, New: TCPSynRecv})
	before, complete, _ := m.Active()
	if complete || len(before) != 1 {
		t.Fatal("gap must invalidate, retain old map")
	}
	now := time.Now()
	id := m.nextRequest(now)
	if id != 1 || m.nextRequest(now.Add(time.Second)) != 0 {
		t.Fatal("unbounded retries")
	}
	// Partial dump never replaces old map; timeout discards staging and changes ID.
	for _, b := range [][]byte{snapshotHeader(EvDumpBegin, id, 7, 2), snapshotRow(id, 7, 0, 17, 2000, TCPUnknown)} {
		kind := EvDumpBegin
		if len(b) > 32 {
			kind = EvDumpRow
		}
		f, err := DecodeSnapshotFrame(kind, b)
		if err != nil {
			t.Fatal(err)
		}
		if err = m.ApplyFrame(f); err != nil {
			t.Fatal(err)
		}
	}
	if active, _, _ := m.Active(); len(active) != 1 || active[SessionID{key, 6}] != TCPUnknown {
		t.Fatal("partial dump published")
	}
	id = m.nextRequest(now.Add(5 * time.Second))
	if id != 2 {
		t.Fatal("missing retry")
	}
	if err := m.ApplyFrame(SnapshotFrame{Type: EvDumpEnd, ID: 1, Cut: 7, Aux: 2}); err != nil {
		t.Fatal(err)
	}
	for _, f := range []SnapshotFrame{
		{Type: EvDumpBegin, ID: id, Cut: 9, Aux: 2},
		{Type: EvDumpRow, ID: id, Cut: 9, Aux: 0, Record: &SnapshotRecord{ID: SessionID{key, 6}, State: TCPEstablished}},
		{Type: EvDumpRow, ID: id, Cut: 9, Aux: 1, Record: &SnapshotRecord{ID: SessionID{key, 17}, State: TCPUnknown}},
		{Type: EvDumpEnd, ID: id, Cut: 9, Aux: 2},
		{Type: EvSessionWatermark, Cut: 9, Aux: 4},
	} {
		if err := m.ApplyFrame(f); err != nil {
			t.Fatal(err)
		}
	}
	active, complete, seq := m.Active()
	if !complete || seq != 9 || len(active) != 2 || active[SessionID{key, 6}] != TCPEstablished {
		t.Fatal("exact map not recovered")
	}
	active[SessionID{key, 6}] = TCPReset // returned maps cannot mutate mirror
	m.ApplyEvent(SessionEvent{Type: EvStateChanged, Key: key, Protocol: 6, Sequence: 10, Dropped: 4, Old: TCPEstablished, New: TCPFinWait})
	if active, ok, _ := m.Active(); !ok || active[SessionID{key, 6}] != TCPFinWait {
		t.Fatal("delta after cut failed")
	}
	m.ApplyFrame(SnapshotFrame{Type: EvSessionWatermark, Cut: 11, Aux: 5})
	if _, ok, _ := m.Active(); ok {
		t.Fatal("tail loss ignored")
	}
}
func TestSessionSnapshotValidation(t *testing.T) {
	good := snapshotRow(1, 4, 0, 6, 1000, TCPEstablished)
	if _, err := DecodeSnapshotFrame(EvDumpRow, good); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func([]byte){
		func(b []byte) { b[0] = 2 }, func(b []byte) { b[1] = 1 }, func(b []byte) { b[8] = 0; b[15] = 0 },
		func(b []byte) { b[33] = 1 }, func(b []byte) { b[73] = 8 }, func(b []byte) { b[74] = 2 },
		func(b []byte) { b[76] = 4 }, func(b []byte) { b[80] = 255 },
	} {
		b := append([]byte(nil), good...)
		mutate(b)
		if _, err := DecodeSnapshotFrame(EvDumpRow, b); err == nil {
			t.Fatal("bad snapshot accepted")
		}
	}
	for _, kind := range []uint16{EvDumpBegin, EvDumpRow, EvDumpEnd} {
		if _, err := DecodeSnapshotFrame(kind, good[:31]); err == nil {
			t.Fatal("short frame accepted")
		}
	}
	m := NewSessionMirror(2)
	m.Invalidate()
	id := m.nextRequest(time.Now())
	if err := m.ApplyFrame(SnapshotFrame{Type: EvDumpBegin, ID: id, Cut: 3, Aux: 3}); err == nil {
		t.Fatal("unbounded allocation")
	}
	m.ApplyFrame(SnapshotFrame{Type: EvDumpBegin, ID: id, Cut: 3, Aux: 2})
	if err := m.ApplyFrame(SnapshotFrame{Type: EvDumpEnd, ID: id, Cut: 3, Aux: 2}); err == nil {
		t.Fatal("truncated dump accepted")
	}
	r := &SnapshotRecord{ID: SessionID{Key{Family: 4}, 17}}
	if err := m.ApplyFrame(SnapshotFrame{Type: EvDumpRow, ID: id, Cut: 3, Aux: 1, Record: r}); err == nil {
		t.Fatal("reordered row accepted")
	}
	m.ApplyFrame(SnapshotFrame{Type: EvDumpRow, ID: id, Cut: 3, Aux: 0, Record: r})
	if err := m.ApplyFrame(SnapshotFrame{Type: EvDumpRow, ID: id, Cut: 3, Aux: 1, Record: r}); err == nil {
		t.Fatal("duplicate record accepted")
	}
}
