# Vertical 2 Step 2: packet verdicts and C/Go session events

Base main: `2ccc1590cffe5c2d9ff4ce5aa499849cfb94a16c` (PR #70, CI #215).

## Runtime integration

`d2kd.c` owns one preallocated `d2k_pipeline` beside the existing plan engine.
Each complete NFQUEUE IP payload goes through `d2k_nfqueue_handle` before plan
execution. A policy DROP suppresses plan emission and becomes the kernel verdict;
an ACCEPT still permits the existing plan engine to replace/drop the original.
The normal loop expires tracker sessions and pumps events over its control
socket. Initialization failure and normal shutdown release both allocations.
There are no allocations, FPU operations, clocks, or blocking I/O in the C
parser/tracker/ring update. The caller supplies monotonic nanoseconds.

Default `--stateful observe` updates observations without changing existing
verdicts. `--stateful off` disables the new tracker; `--stateful enforce` requires
`--mode apply`. It is an explicit strict observed-handshake policy: both packet
directions and the handshake must be visible. Existing `apply` requirements for
plan/control and a bypass mark remain in place. This opt-in protects running
connections and asymmetric queues from a new default drop policy.

The original raw NFNETLINK backend remains the router default. An optional
`D2K_WITH_LIBNFQ` build provides a real `nfq_create_queue` callback adapter in
`nfqueue_handler.c`, using `nfq_get_payload` and `nfq_set_verdict` with the same
pipeline. `nfqueue_libprobe` is its Linux integration harness, not a second
production daemon. Library dependencies are linked only by this explicit
target; the raw daemon does not acquire a new shared-library dependency.

## Verdict policy and scope

| Observation | enforce | observe |
|---|---|---|
| Valid observed SYN / SYN+ACK / final ACK | ACCEPT | ACCEPT |
| Established TCP DATA, UDP | ACCEPT | ACCEPT |
| DATA/FIN before proven handshake | DROP | ACCEPT |
| SYN+FIN, SYN+RST, FIN+RST, missing required ACK flags | DROP | ACCEPT, no invalid flag record |
| SYN+ACK or handshake ACK with wrong observed sequence end | DROP | ACCEPT |
| Non-SYN traffic in CLOSED/RST | DROP | ACCEPT |
| New bare SYN reusing terminal tuple | ACCEPT, reset observation | ACCEPT |
| Malformed IP/TCP/UDP lengths | DROP | ACCEPT |
| Table full, unsupported protocols, IP fragments/IPsec | ACCEPT, counted/bypassed | ACCEPT |

Matched SYN/SYN+ACK retransmissions do not regress established state. Final
handshake ACK may carry DATA. FIN is a half-close; CLOSED requires both FINs
and their exact acknowledgements. RST yields a terminal event. UDP reverse
traffic refreshes one record. The existing `--idle` controls UDP idle timeout
when positive; TCP state-specific defaults come from the Step 1 configuration
API. Older per-record timestamps cannot alter state or publish new events.

This is not RFC-complete firewall conntrack, receive-window/RST authenticity
validation, stream reassembly, or an endpoint TIME_WAIT implementation. Strict
mode rejects terminal traffic and DATA retransmitted after that side's observed
FIN; packet loss/reordering and TCP Fast Open can lack the evidence this policy
requires. Use observe for arbitrary existing traffic. Checksums are deliberately
not judged here: NFQUEUE offload metadata can indicate incomplete checksums.
Full-copy capture is required for strict mode. The raw backend bypasses its
explicit truncated flag; the library adapter fails open on metadata-only capture
and checks advertised IP length. IPv6 jumbograms and fragmented transport are
not tracked. The parser reads bytes rather than unaligned C header structs.

## Bounded event transport

Three new types use unused control-socket IDs, preserving every existing type:

| Event | Type |
|---|---:|
| EVENT_SESSION_CREATED | 0x20 |
| EVENT_STATE_CHANGED | 0x21 |
| EVENT_SESSION_CLOSED | 0x22 |

An instance owns a fixed ring (daemon capacity 256). It retains queued oldest
events and drops newest when full; its monotonic sequence and saturating drop
counter make gaps visible. A disconnected controller does not block packet
updates. Pumping uses the existing nonblocking framed AF_UNIX transport; its
independent loss counter still applies. This is best-effort observation, not
an authoritative replicated table: gaps/disconnects invalidate completeness.

Framing stays `[u32 BE payload length][u16 BE type][body]`. Body v1 is exactly
72 bytes; integers are big-endian and no native metadata structs are copied:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | version = 1 |
| 1 | 1 | family = 4/6 |
| 2 | 1 | protocol = TCP 6 / UDP 17 |
| 3, 4 | 1 each | old / new TCP state |
| 5 | 1 | close reason: none=0, FIN=1, RST=2, timeout=3 |
| 6 | 2 | reserved zero |
| 8 | 8 | monotonic observation timestamp ns |
| 16 | 8 | event sequence, starts at 1 |
| 24 | 40 | explicitly serialized Vertical 1 key; padding/IPv4 union tails zero |
| 64 | 8 | ring loss counter at enqueue |

CREATED starts at UNKNOWN, followed by STATE_CHANGED when appropriate. CLOSED
is emitted once on completed FIN/RST or expiration of an active session. Later
removal of a retained terminal record does not duplicate CLOSED. UDP timeout
has old/new UNKNOWN and reason timeout. Tuple reuse creates a new observation.
`expire_notify` borrows the removed record before unlinking, without allocating;
its callback must not mutate the table or retain the pointer.

Go `DecodeSessionEvent` validates exact size, version, protocol/family, canonical
key order, zero padding, nonzero sequence, event types, allowed transitions,
and close reasons. `control.Conn.Next` decodes these before legacy key parsing;
existing event formats and consumers remain compatible. `Event.Session` exposes
the structured observation. Sequence/time are scoped to the C process and
must not be interpreted as wall time or durable connection identity.

## Evidence gates

* C `test_stateful_pipeline`: IPv4/IPv6, accepted handshake/DATA/half-close,
  early/terminal DATA and invalid flags/ACKs, RST and tuple reuse, exact event
  order, UDP reverse/timeout, ring overflow/gaps, capacity fail-open, all packet
  truncation boundaries, unaligned input, IPv6 extension headers, fragments,
  and 2,000 handshake/reset cycles. Included in check, san, and gcc-warn.
* `tests/e2e_stateful_pipeline_test.go`: complete checksummed IP packets enter
  the real C parser over the test harness's stdin; verdicts return on stdout,
  and versioned events travel over a real AF_UNIX bridge using the production
  pump and Go decoder. Both families cover handshake/DATA/FIN/RST, UDP timeout,
  observe midstream, and 1,000 cycles (4,000 packets) with ordered events.
  This socket bridge is a simulation, not veth forwarding.
* Native Linux CI builds the actual libnetfilter_queue adapter and executes
  `check-stateful-nfq.sh` in a disposable network namespace. Fourteen marked
  synthetic TCP packets pass through real kernel NFQUEUE; ACCEPT/DROP and
  FIN/RST event sequences are asserted. Automatic kernel replies are excluded
  from the queue by mark. Namespace deletion is guaranteed by a cleanup trap.
* Existing full C/IPv6/FlowKey, ASan/UBSan/leak, Go format/vet/race/bridge,
  ShellCheck and nine Go builds remain mandatory. The pinned Zig cross gate
  compiles all portable units, daemon sources and test sources (including the
  new pipeline) for nine architectures and verifies MIPS soft-float objects.
  This is object-compilation evidence; external library linking/execution on
  all nine CPUs is not claimed.
