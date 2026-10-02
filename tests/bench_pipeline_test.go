package tests

import (
	"encoding/binary"
	"github.com/necronicle/d2k/internal/control"
	"testing"
)

// Includes AF_UNIX framing, stdin/stdout IPC and Go decoding. This latency is
// intentionally separate from the C-only packet throughput microbenchmark.
func BenchmarkPipelineBridge(b *testing.B) {
	bridge := startBridge(b, "enforce")
	bridge.packet(b, 0, rawPacket(6, false, true, 0, 0, 0, "warmup"), 1)
	packet := rawPacket(6, false, true, 0, 0, 0, "payload")
	b.SetBytes(int64(len(packet)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		bridge.packet(b, uint64(i+1), packet, 1)
	}
}
func BenchmarkSessionEventDecoder(b *testing.B) {
	wire := make([]byte, control.SessionEventSize)
	wire[0] = 1
	wire[1] = 6
	wire[2] = 17
	binary.BigEndian.PutUint64(wire[16:], 1)
	wire[24] = 6
	wire[28] = 0x20
	wire[44] = 0x20
	wire[43] = 1
	wire[59] = 2
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := control.DecodeSessionEvent(control.EvSessionCreated, wire); err != nil {
			b.Fatal(err)
		}
	}
}
