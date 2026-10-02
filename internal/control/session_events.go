package control

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

const (
	EvSessionCreated    uint16 = 0x0020
	EvStateChanged      uint16 = 0x0021
	EvSessionClosed     uint16 = 0x0022
	SessionEventVersion        = 1
	SessionEventSize           = 72
)

type TCPState uint8

const (
	TCPUnknown TCPState = iota
	TCPSynSent
	TCPSynRecv
	TCPEstablished
	TCPFinWait
	TCPCloseWait
	TCPClosed
	TCPReset
)
const (
	CloseNone uint8 = iota
	CloseFIN
	CloseRST
	CloseTimeout
)

// SessionEvent is a versioned observation, not a lossless conntrack replica.
// Sequence gaps, Dropped, socket loss and disconnects invalidate completeness.
// Monotonic timestamps belong to the C process; they are not Unix wall times.
type SessionEvent struct {
	Version                 uint8
	Type                    uint16
	Protocol                uint8
	Key                     Key
	Old, New                TCPState
	Reason                  uint8
	AtNS, Sequence, Dropped uint64
}

func DecodeSessionEvent(kind uint16, b []byte) (SessionEvent, error) {
	var e SessionEvent
	if len(b) != SessionEventSize || b[0] != SessionEventVersion {
		return e, fmt.Errorf("session event: unsupported size/version")
	}
	if b[6] != 0 || b[7] != 0 || b[25] != 0 || b[26] != 0 || b[27] != 0 ||
		b[1] != b[24] || (b[1] != 4 && b[1] != 6) || (b[2] != 6 && b[2] != 17) ||
		b[3] > uint8(TCPReset) || b[4] > uint8(TCPReset) {
		return e, fmt.Errorf("session event: invalid fields/padding")
	}
	e = SessionEvent{Version: b[0], Type: kind, Protocol: b[2], Old: TCPState(b[3]),
		New: TCPState(b[4]), Reason: b[5], AtNS: binary.BigEndian.Uint64(b[8:16]),
		Sequence: binary.BigEndian.Uint64(b[16:24]), Dropped: binary.BigEndian.Uint64(b[64:72])}
	if e.Sequence == 0 {
		return SessionEvent{}, fmt.Errorf("session event: zero sequence")
	}
	e.Key.Family = b[1]
	addr := 16
	if b[1] == 4 {
		addr = 4
		if !bytes.Equal(b[32:44], make([]byte, 12)) || !bytes.Equal(b[48:60], make([]byte, 12)) {
			return SessionEvent{}, fmt.Errorf("session event: IPv4 union tail")
		}
		copy(e.Key.LowIP[:], b[28:32])
		copy(e.Key.HighIP[:], b[44:48])
	} else {
		copy(e.Key.LowIP6[:], b[28:44])
		copy(e.Key.HighIP6[:], b[44:60])
	}
	e.Key.LowPort = binary.BigEndian.Uint16(b[60:62])
	e.Key.HighPort = binary.BigEndian.Uint16(b[62:64])
	order := bytes.Compare(b[28:28+addr], b[44:44+addr])
	if order > 0 || (order == 0 && e.Key.LowPort > e.Key.HighPort) {
		return SessionEvent{}, fmt.Errorf("session event: noncanonical key")
	}
	valid := false
	switch kind {
	case EvSessionCreated:
		valid = e.Old == TCPUnknown && e.New == TCPUnknown && e.Reason == CloseNone
	case EvStateChanged:
		// Accepted transitions from the passive C tracker, not arbitrary enum pairs.
		allowed := map[TCPState][]TCPState{
			TCPUnknown:     {TCPSynSent, TCPSynRecv, TCPReset},
			TCPSynSent:     {TCPSynRecv, TCPEstablished, TCPReset},
			TCPSynRecv:     {TCPEstablished, TCPReset},
			TCPEstablished: {TCPFinWait, TCPCloseWait, TCPReset},
			TCPFinWait:     {TCPClosed, TCPReset}, TCPCloseWait: {TCPClosed, TCPReset},
		}
		if e.Protocol == 6 && e.Reason == CloseNone {
			for _, next := range allowed[e.Old] {
				if next == e.New {
					valid = true
				}
			}
		}
	case EvSessionClosed:
		switch e.Reason {
		case CloseFIN:
			valid = e.Protocol == 6 && (e.Old == TCPFinWait || e.Old == TCPCloseWait) && e.New == TCPClosed
		case CloseRST:
			valid = e.Protocol == 6 && e.Old < TCPClosed && e.New == TCPReset
		case CloseTimeout:
			valid = (e.Protocol == 6 && e.Old < TCPClosed && e.New == TCPClosed) ||
				(e.Protocol == 17 && e.Old == TCPUnknown && e.New == TCPUnknown)
		}
	}
	if !valid {
		return SessionEvent{}, fmt.Errorf("session event: invalid type/state/reason")
	}
	return e, nil
}
