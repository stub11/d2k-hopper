# Vertical 2 Step 3 — veth, recovery and component benchmarks

Base main: `c65c0eff13e322f1ca4639be908959a2324d87d5` (PR #71, CI #217 SUCCESS).
The Vertical 1 40-byte key ABI and legacy control frames remain unchanged.

## Full state dump v1

Command `0x8a` has a 16-byte body: version 1 at byte 0, seven zero reserved
bytes, and a nonzero big-endian u64 request ID at byte 8. The single C owner
copies ALL tracker records, including retained CLOSED/RST records, to a fixed
buffer allocated at pipeline initialization. It records the event sequence cut
at that instant. Capture is O(capacity), does not call malloc or block on I/O;
it does consume owner-loop time once per accepted request. Only one dump is
in progress. This is an inspection/recovery API, not a packet-path operation.

Frames use unused IDs `0x23 BEGIN`, `0x24 ROW`, `0x25 END`, `0x26 WATERMARK`.
Their common 32-byte header is:

| Offset | Bytes | Meaning |
|---:|---:|---|
| 0 | 1 | version = 1 |
| 1 | 7 | reserved zero |
| 8 | 8 | request ID; zero only for watermark |
| 16 | 8 | snapshot cut / current global sequence |
| 24 | 8 | BEGIN/END record count; ROW zero-based index; watermark ring loss count |

ROW adds this explicit 80-byte record (no native struct serialization):

| Record offset | Bytes | Meaning |
|---:|---:|---|
| 0 | 40 | canonical Unified FlowKey, padding and IPv4 tails zero |
| 40, 41 | 1 each | protocol / TCP state |
| 42, 43 | 1 each | initiator-low / known-role flags |
| 44..47 | 1 each | SYN seen/acked, FIN seen/acked masks |
| 48, 56 | 8 each | first / last monotonic observation ns |
| 64, 72 | 8 each | two u32 SYN ends / two u32 FIN ends |

All integers are big-endian; masks use low/high side bits as in Step 1.
The single owner captures immutable records before later packets can mutate
sessions. Packets continue during dump delivery. A pump accepts at most 32
frames per call. Snapshot frames take precedence over session deltas; legacy
control events can still interleave. Nonblocking `d2k_ctl_try_event` retains
one partial frame and returns backpressure so dump cursor and ring head advance
only after acceptance. No unbounded C transport queue is introduced.

The Go mirror detects sequence gaps and changed loss counters, requests a dump,
and stages rows under a configurable hard record limit (default one million).
It checks request ID, cut, index, count, uniqueness, version, key/padding and
metadata bounds. Only a complete END publishes an atomic replacement. Older
queued events at or before cut are ignored. Later deltas update the recovered
map. The post-dump watermark baselines already-covered losses; a gap AFTER the
cut forces another resync. A changed sequence watermark also exposes a lost
tail with no subsequent event. The controller's regular tick retries a stalled
dump after five seconds; stale request frames are ignored. Disconnects require
a new Conn/mirror, and sequence exhaustion requires restarting the datapath.

`SessionMirror.Active()` is the exact recovered **active identity/state map**,
not live packet timing statistics. FIN/RST/timeout removes an active key;
terminal retention is deliberately excluded. `FullDump()` returns all exact
metadata at the last completed cut, including terminal records. UDP and DATA
refresh timestamps without event deltas, so those metadata are not claimed
continuously current. Sustained losses may require repeated snapshots; callers
must check completeness and cannot use an incomplete map as authoritative policy.

## Real dual-stack Linux veth gate

`tests/e2e_veth_dualstack_test.go` creates two unique disposable network
namespaces and a veth pair with IPv4 and IPv6 addresses. Only the server
namespace's INPUT/OUTPUT TCP/UDP test ports are queued using iptables/ip6tables.
Real Go TCP sockets perform handshake, DATA in both directions and FIN close;
UDP query/reply exercises a single canonical identity in both directions.
The actual libnetfilter_queue callback feeds production C parsing and policy.
Four additional raw segments (early DATA and SYN+FIN for each family) must DROP.
The gate verifies Go payload receipt, both ESTABLISHED/FIN event lifecycles,
canonical session counts, ACCEPT/DROP counts, contiguous event decoding and
UDP reverse timestamp refresh in the final C dump. Cleanup removes only its
own namespaces/interfaces. It is mandatory with `D2K_REQUIRE_VETH=1` in the
native Linux NFQUEUE CI job; ordinary unprivileged tests explicitly skip it.

The separate portable E2E deliberately uses a one-entry real C ring, overflows
it with three flows, observes loss, verifies automatic dump recovery of the
three-session map, then loses timeout close events and recovers the empty map.
Unit tests cover immutable C snapshots, malformed/versioned/oversized dumps,
row reordering/duplicates, missing END, retry IDs and atomic map publication.

## Benchmarks and reproducibility

```
make -C datapath bench_session_tracker
./datapath/bench_session_tracker 131072 1048576
go test ./tests -run '^$' -bench 'Benchmark(PipelineBridge|SessionEventDecoder)' -benchtime=100ms -count=3
```

C creates 131072 concurrent active UDP identities, alternating IPv4/IPv6,
then performs five rounds of 1048576 finds, updates and packet pipeline calls.
Each loop cycles the entire default dataset with stride 1009. Initialization,
packet creation and allocation are outside timing. Nanoseconds come from
CLOCK_MONOTONIC; the timed C code contains integer arithmetic only. Workload
packets are synthetic parser input, not a kernel throughput benchmark. Hash
lookup is expected O(1) at bounded load, not a worst-case collision guarantee.

Raw local samples are committed in `docs/benchmarks/vertical2-local-2026-10-02.json`.
Local x86_64 Linux / AMD EPYC 9V74, GCC 13, -O2: median of five round means:
lookup 157.04 ns/op; UDP update 147.28 ns/op; dual-stack pipeline 280.99 ns/op
(3.559 Mpps). These are component measurements, not per-packet percentile
latencies or Keenetic performance claims. CI reports its own independently
measured raw samples. Shared-runner scheduling and CPU cache affect results.

Exact owned allocations on this 64-bit ABI: tracker 15728736 bytes (15.000 MiB),
whole pipeline including tracker, 256-event ring and full snapshot buffer
27283680 bytes (26.020 MiB). Record sizeof is 88. Process max RSS in the local
suite is 43648 KiB; it includes a separate benchmark tracker and packet/key
samples, so it is NOT pipeline resident memory. These figures exclude allocator
metadata and Go maps, and vary by target ABI. The suite validates active counts
and frees all setup allocations. The snapshot reserve is a deliberate memory
tradeoff for a consistent nonblocking dump; router capacity remains configurable.

Go's bridge benchmark includes stdin/stdout, AF_UNIX, encoding and decoding,
and must not be equated with C packet pps. The decoder benchmark measures only
structured validation. CI keeps full C checks, IPv6 checksum/pipeline,
ASan/UBSan/leak detection, Go format/vet/race, ShellCheck and nine Go/C targets.
The nine C gate compiles portable units and tests; execution is native Linux,
not claimed on every target CPU.
