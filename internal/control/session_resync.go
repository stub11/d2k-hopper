package control

import (
	"encoding/binary"
	"fmt"
	"sync"
	"time"
)

const (
	CmdSessionDump     uint16 = 0x008a
	EvDumpBegin        uint16 = 0x0023
	EvDumpRow          uint16 = 0x0024
	EvDumpEnd          uint16 = 0x0025
	EvSessionWatermark uint16 = 0x0026
	SnapshotRecordSize        = 80
)

type SessionID struct {
	Key      Key
	Protocol uint8
}

// SnapshotRecord is exact observation metadata at Cut, not continuously updated
// packet counters. The live mirror deliberately exposes only identity/state.
type SnapshotRecord struct {
	ID                                                            SessionID
	State                                                         TCPState
	InitiatorLow, RoleKnown, SynSeen, SynAcked, FinSeen, FinAcked uint8
	FirstNS, LastNS                                               uint64
	SynEnd, FinEnd                                                [2]uint32
}
type SnapshotFrame struct {
	Type         uint16
	ID, Cut, Aux uint64 // Aux: total rows, row index, or watermark loss counter.
	Record       *SnapshotRecord
}

func DecodeSnapshotFrame(kind uint16, b []byte) (SnapshotFrame, error) {
	var f SnapshotFrame
	size := 32
	if kind == EvDumpRow {
		size += SnapshotRecordSize
	}
	if kind < EvDumpBegin || kind > EvSessionWatermark || len(b) != size || b[0] != 1 {
		return f, fmt.Errorf("snapshot: type/size/version")
	}
	for _, v := range b[1:8] {
		if v != 0 {
			return f, fmt.Errorf("snapshot: reserved bits")
		}
	}
	f = SnapshotFrame{Type: kind, ID: binary.BigEndian.Uint64(b[8:16]), Cut: binary.BigEndian.Uint64(b[16:24]), Aux: binary.BigEndian.Uint64(b[24:32])}
	if (kind == EvSessionWatermark) != (f.ID == 0) {
		return SnapshotFrame{}, fmt.Errorf("snapshot: request ID")
	}
	if kind != EvDumpRow {
		return f, nil
	}
	r := b[32:]
	// Reuse the exact canonical key/padding/protocol validation of v1 events.
	e := make([]byte, SessionEventSize)
	e[0] = 1
	e[1] = r[0]
	e[2] = r[40]
	binary.BigEndian.PutUint64(e[16:24], 1)
	copy(e[24:64], r[:40])
	key, err := DecodeSessionEvent(EvSessionCreated, e)
	if err != nil {
		return SnapshotFrame{}, err
	}
	if r[41] > uint8(TCPReset) || r[42] > 1 || r[43] > 1 {
		return SnapshotFrame{}, fmt.Errorf("snapshot: state/role")
	}
	for _, v := range r[44:48] {
		if v > 3 {
			return SnapshotFrame{}, fmt.Errorf("snapshot: masks")
		}
	}
	first, last := binary.BigEndian.Uint64(r[48:56]), binary.BigEndian.Uint64(r[56:64])
	if first > last || (r[40] == 17 && r[41] != 0) {
		return SnapshotFrame{}, fmt.Errorf("snapshot: timestamps/UDP state")
	}
	rec := SnapshotRecord{ID: SessionID{key.Key, r[40]}, State: TCPState(r[41]), InitiatorLow: r[42], RoleKnown: r[43], SynSeen: r[44], SynAcked: r[45], FinSeen: r[46], FinAcked: r[47], FirstNS: first, LastNS: last}
	for i := 0; i < 2; i++ {
		rec.SynEnd[i] = binary.BigEndian.Uint32(r[64+4*i : 68+4*i])
		rec.FinEnd[i] = binary.BigEndian.Uint32(r[72+4*i : 76+4*i])
	}
	f.Record = &rec
	return f, nil
}

// SessionMirror atomically replaces the active identity/state map only after a
// complete, ordered dump. Terminal retention records remain in FullDump, not
// the active map. All methods synchronize access; callers receive copies.
type SessionMirror struct {
	baseline                                     bool
	mu                                           sync.RWMutex
	active                                       map[SessionID]TCPState
	full                                         map[SessionID]SnapshotRecord
	stage                                        map[SessionID]SnapshotRecord
	limit                                        int
	complete                                     bool
	sequence, dropped, request, cut, total, rows uint64
	pending                                      bool
	requested                                    time.Time
}

func NewSessionMirror(limit int) *SessionMirror {
	if limit <= 0 {
		limit = 1000000
	}
	return &SessionMirror{limit: limit, active: make(map[SessionID]TCPState), complete: true}
}
func (m *SessionMirror) Active() (map[SessionID]TCPState, bool, uint64) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make(map[SessionID]TCPState, len(m.active))
	for k, v := range m.active {
		out[k] = v
	}
	return out, m.complete, m.sequence
}
func (m *SessionMirror) FullDump() map[SessionID]SnapshotRecord {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make(map[SessionID]SnapshotRecord, len(m.full))
	for k, v := range m.full {
		out[k] = v
	}
	return out
}
func (m *SessionMirror) Invalidate() { m.mu.Lock(); defer m.mu.Unlock(); m.complete = false }
func (m *SessionMirror) ApplyEvent(e SessionEvent) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.complete || m.pending || e.Sequence <= m.sequence {
		return
	}
	if m.baseline {
		m.dropped = e.Dropped
		m.baseline = false
	}
	if e.Sequence != m.sequence+1 || e.Dropped != m.dropped {
		m.complete = false
		return
	}
	id := SessionID{e.Key, e.Protocol}
	switch e.Type {
	case EvSessionCreated:
		if len(m.active) >= m.limit {
			m.complete = false
			return
		}
		m.active[id] = TCPUnknown
	case EvStateChanged:
		old, ok := m.active[id]
		if !ok || old != e.Old {
			m.complete = false
			return
		}
		if e.New >= TCPClosed {
			delete(m.active, id)
		} else {
			m.active[id] = e.New
		}
	case EvSessionClosed:
		delete(m.active, id)
	}
	m.sequence = e.Sequence
}
func (m *SessionMirror) ApplyFrame(f SnapshotFrame) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if f.Type == EvSessionWatermark {
		if !m.pending && (f.Cut != m.sequence || (!m.baseline && f.Aux != m.dropped)) {
			m.complete = false
		}
		// The cut covers previous losses; only the current watermark baselines them.
		if m.complete && f.Cut == m.sequence {
			m.dropped = f.Aux
			m.baseline = false
		}
		return nil
	}
	if !m.pending || f.ID != m.request {
		return nil
	} // delayed frames from a timed-out request
	switch f.Type {
	case EvDumpBegin:
		if f.Aux > uint64(m.limit) {
			return fmt.Errorf("snapshot: count exceeds mirror limit")
		}
		m.cut = f.Cut
		m.total = f.Aux
		m.rows = 0
		m.stage = make(map[SessionID]SnapshotRecord, int(f.Aux))
	case EvDumpRow:
		if m.stage == nil || f.Cut != m.cut || f.Aux != m.rows || m.rows >= m.total || f.Record == nil {
			return fmt.Errorf("snapshot: row order")
		}
		if _, ok := m.stage[f.Record.ID]; ok {
			return fmt.Errorf("snapshot: duplicate session")
		}
		m.stage[f.Record.ID] = *f.Record
		m.rows++
	case EvDumpEnd:
		if m.stage == nil || f.Cut != m.cut || f.Aux != m.total || m.rows != m.total {
			return fmt.Errorf("snapshot: incomplete dump")
		}
		active := make(map[SessionID]TCPState, len(m.stage))
		for id, r := range m.stage {
			if r.State < TCPClosed {
				active[id] = r.State
			}
		}
		m.active = active
		m.full = m.stage
		m.stage = nil
		m.sequence = m.cut
		m.complete = true
		m.pending = false
		m.baseline = true
	}
	return nil
}

// nextRequest retries a stalled dump after 5 seconds. PollSessionResync must
// also be called by the controller tick, since a silent stream cannot retry itself.
func (m *SessionMirror) nextRequest(now time.Time) uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.complete && !m.pending {
		return 0
	}
	if m.pending && now.Sub(m.requested) < 5*time.Second {
		return 0
	}
	m.request++
	if m.request == 0 {
		m.request = 1
	}
	m.pending = true
	m.requested = now
	m.stage = nil
	return m.request
}
func (c *Conn) RequestSessionDump(id uint64) error {
	if id == 0 {
		return fmt.Errorf("snapshot: zero request ID")
	}
	b := make([]byte, 16)
	b[0] = 1
	binary.BigEndian.PutUint64(b[8:], id)
	return c.send(CmdSessionDump, b)
}
func (c *Conn) SessionMirror() *SessionMirror { return c.mirror }
func (c *Conn) PollSessionResync() error {
	if c.mirror == nil {
		return nil
	}
	if id := c.mirror.nextRequest(time.Now()); id != 0 {
		return c.RequestSessionDump(id)
	}
	return nil
}
