# Vertical 2 Step 1: bounded passive session tracker

Baseline: Vertical 1 main `9aa531611298487f6ae47fc6398db5f22ba7b93d`.
This step adds a standalone C API. It does not change packet verdicts, the
NFQUEUE loop, Go event payloads, or the existing plan execution engine.

## Names and ABI

`struct d2k_session` already names the opaque packet/plan engine in
`include/d2k_session.h`. Redefining it would break that public API. The new
record is `struct d2k_tracked_session`; its table is the opaque
`struct d2k_session_tracker`. Both APIs can be included in one translation unit.

Vertical 1's `d2k_key` is an anonymous typedef, not a tagged `struct d2k_key`.
It remains exactly 40 bytes, alignment 4:

| Field | Offset | Size |
|---|---:|---:|
| family | 0 | 1 |
| padding | 1 | 3 |
| low_addr | 4 | 16 |
| high_addr | 20 | 16 |
| low_port | 36 | 2 |
| high_port | 38 | 2 |

The existing builders canonicalize endpoints and return whether the packet's
source is low. Address/port bytes remain in network order. The tracker copies
only meaningful fields into a zeroed key, normalizing padding and unused IPv4
union bytes. Identity is **(IP protocol, key)** so TCP and UDP do not alias.
Protocol is stored outside the key. Record metadata has native alignment and
must never be memcpy'd across a Go/C boundary or used as a wire format.

## Ownership, bounds, and lookup

Construction preallocates a fixed slot array, power-of-two hash buckets
(at least twice capacity), and a free list. Packet observation, lookup, add,
remove, and expiration allocate no memory. One owner must serialize calls;
there are no locks. Separate chaining gives expected O(1) lookup/add/remove,
not a worst-case O(1) guarantee against chosen hash collisions. Worst-case
lookup is O(capacity), and hard capacity bounds memory. FNV-1a is not a keyed
DoS-resistant hash. A capacity refusal returns NULL and increments a saturating
counter; unrelated live records are never silently evicted.

Expiration walks buckets/chains once, O(capacity), and unlinks in place.
Pointers to surviving records remain stable. A borrowed pointer becomes
invalid after its own remove/expire/reuse or table destruction. Callers must
not modify records. `add` is idempotent and does not refresh an existing idle
timestamp; TCP/UDP observation performs the refresh.

## TCP observations

Provide validated header flags, host-order seq/ack, payload length, and
`src_is_low` from the existing key builder. This is a conservative observation
state machine, not a TCP endpoint or firewall conntrack implementation.

| Evidence | State |
|---|---|
| No observed handshake, including midstream ACK | UNKNOWN |
| Bare SYN | SYN_SENT |
| SYN+ACK | SYN_RECV |
| Both SYNs observed and acknowledged by peer | ESTABLISHED |
| First FIN from initiator | FIN_WAIT |
| First FIN from responder | CLOSE_WAIT |
| Both FINs observed and acknowledged by peer | CLOSED |
| Observed RST on nonterminal record | RST |

The initiator is determined from the first SYN (or inferred from SYN+ACK),
independently of canonical endpoint order. Both address families and both
directions use the same state logic; simultaneous open/close is supported.

An ACK advances handshake/close only if it equals the peer's observed sequence
end: `seq + payload_len + 1` for SYN/FIN, using unsigned 32-bit wrap. SYN and FIN
consume sequence space as specified in [RFC 9293 sections 3.3, 3.5, 3.6](https://www.rfc-editor.org/rfc/rfc9293.html).
Retransmitted SYN does not regress established/closing state. Contradictory
SYN+FIN/SYN+RST and lengths above 2^31-1 are rejected before insertion.
Unobserved/reordered evidence can leave state incomplete; arbitrary ACKs do
not manufacture ESTABLISHED/CLOSED. There is no TCP receive-window validation,
RST authenticity check, TIME_WAIT endpoint semantics, or full stream tracking.
Step 2 must not use these observations alone to authorize packet verdicts.

CLOSED/RST records are retained for a terminal idle timeout. A subsequent bare
SYN resets a terminal record for tuple reuse. Other terminal packets only
refresh idle time. A different SYN sequence on an active tuple is not treated
as a new handshake until removal/expiration/terminal reuse.

## Time and UDP

All times are caller-provided monotonic integer nanoseconds. No clock or
floating-point operation occurs in packet updates. Older per-record timestamps
are ignored, including state changes. Expiration checks `now >= last` before
subtracting, and evicts at `idle >= timeout`. UDP reverse packets refresh the
same record. Default timeouts are configurable and must all be nonzero:

| Kind | Default |
|---|---:|
| TCP UNKNOWN/handshake | 30 s |
| TCP established | 300 s |
| TCP closing | 30 s |
| TCP CLOSED/RST | 5 s |
| UDP idle | 30 s |

## Verification

`make -C datapath check` includes `test_session_tracker`; `san` and `gcc-warn`
derive their inputs from the same Makefile lists. Always-on test checks cover
IPv4/IPv6, both initiator directions, active/passive and simultaneous close,
sequence wrap, wrong/stale ACKs, retransmission, RST, tuple reuse, protocol
separation, padding normalization, exact idle boundaries, backwards time,
capacity refusal, and 2,000 model-checked churn operations.

`scripts/check-session-tracker-cross.sh` compiles every portable C source/test
for amd64, 386, arm (ARMv5), arm64, mips, mipsle,
mips64le, ppc64, riscv64 using pinned Zig 0.15.1/musl. It preserves existing
assertions with `-UNDEBUG` and selects soft-float MIPS. ELF architecture checks
are mandatory. This is object compilation evidence, not cross linking or
execution on nine CPUs. In particular Zig 0.15.1's MIPS64 compiler runtime does
not link consistently with soft-float C, and its driver ignores `-msoft-float`
for n64. The gate explicitly overrides Clang's `-mfloat-abi soft` and
`+soft-float` feature via `-Xclang`, and requires `readelf` to report
`FP ABI: Soft float` for all three MIPS objects. Cross linking needs a
compatible target libc/compiler runtime in the integration step.
Native CI executes full C tests and ASan/UBSan with leak detection, Go format,
vet/race/bridge tests, ShellCheck, and the existing nine-target Go builds.

## Step 2 integration contract

1. Feed observations only after IPv4/IPv6 transport validation in `nfq.c`.
   Existing production NFQUEUE uses raw NFNETLINK (`nfq.c`/`nl.c`), not
   libnetfilter_queue. Decide whether to retain that backend or introduce an
   optional library adapter; do not duplicate queues or change dependencies
   implicitly.
2. Own the tracker in the existing datapath session lifecycle, use monotonic
   timestamps, run bounded periodic maintenance, expose capacity refusals,
   and free it on every initialization/shutdown error path.
3. Define an explicitly versioned event encoding for Go containing protocol,
   canonical key, state, and timestamp. Serialize fields; never copy this
   native record. Keep existing event consumers and key ABI compatible.
4. Add packet-to-tracker integration and Go bridge tests for IPv4/IPv6 TCP/UDP,
   truncated headers, fragments, out-of-order evidence, capacity pressure,
   and event backpressure before changing runtime behavior.
