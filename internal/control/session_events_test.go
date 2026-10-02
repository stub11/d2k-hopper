package control

import (
	"encoding/binary"
	"testing"
)

func sessionWire() []byte {
	b := make([]byte, 72)
	b[0] = 1
	b[1] = 4
	b[2] = 6
	b[24] = 4
	b[28] = 1
	b[44] = 2
	binary.BigEndian.PutUint64(b[16:24], 1)
	binary.BigEndian.PutUint16(b[60:62], 1234)
	binary.BigEndian.PutUint16(b[62:64], 443)
	return b
}
func TestSessionEventValidation(t *testing.T) {
	b := sessionWire()
	e, err := DecodeSessionEvent(EvSessionCreated, b)
	if err != nil || e.Key.LowPort != 1234 {
		t.Fatalf("valid create: %v %#v", err, e)
	}
	mutations := []struct {
		name   string
		change func([]byte)
	}{
		{"version", func(b []byte) { b[0] = 2 }}, {"family", func(b []byte) { b[1] = 5 }},
		{"key family mismatch", func(b []byte) { b[24] = 6 }}, {"protocol", func(b []byte) { b[2] = 1 }},
		{"reserved", func(b []byte) { b[6] = 1 }}, {"key padding", func(b []byte) { b[26] = 1 }},
		{"union tail", func(b []byte) { b[33] = 1 }}, {"noncanonical", func(b []byte) { b[28] = 3 }},
		{"sequence", func(b []byte) { b[23] = 0 }}, {"state", func(b []byte) { b[4] = 8 }},
		{"created state", func(b []byte) { b[4] = 1 }}, {"reason", func(b []byte) { b[5] = 1 }},
	}
	for _, m := range mutations {
		t.Run(m.name, func(t *testing.T) {
			c := append([]byte(nil), b...)
			m.change(c)
			if _, err := DecodeSessionEvent(EvSessionCreated, c); err == nil {
				t.Fatal("accepted invalid wire")
			}
		})
	}
	for n := 0; n < 72; n++ {
		if _, err := DecodeSessionEvent(EvSessionCreated, b[:n]); err == nil {
			t.Fatalf("accepted truncated %d", n)
		}
	}
	if _, err := DecodeSessionEvent(EvSessionCreated, append(b, 0)); err == nil {
		t.Fatal("accepted trailing data")
	}
	if _, err := DecodeSessionEvent(0xffff, b); err == nil {
		t.Fatal("unknown event")
	}
	b[3] = byte(TCPEstablished)
	b[4] = byte(TCPFinWait)
	if _, err := DecodeSessionEvent(EvStateChanged, b); err != nil {
		t.Fatal(err)
	}
	b[4] = byte(TCPSynSent)
	if _, err := DecodeSessionEvent(EvStateChanged, b); err == nil {
		t.Fatal("state regression")
	}
	b[3] = byte(TCPFinWait)
	b[4] = byte(TCPClosed)
	b[5] = CloseFIN
	if _, err := DecodeSessionEvent(EvSessionClosed, b); err != nil {
		t.Fatal(err)
	}
	b[5] = CloseRST
	if _, err := DecodeSessionEvent(EvSessionClosed, b); err == nil {
		t.Fatal("RST reason mismatch")
	}
	b[2] = 17
	b[3] = 0
	b[4] = 0
	b[5] = CloseTimeout
	if _, err := DecodeSessionEvent(EvSessionClosed, b); err != nil {
		t.Fatal(err)
	}
}
