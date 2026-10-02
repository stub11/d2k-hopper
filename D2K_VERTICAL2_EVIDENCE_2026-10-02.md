# D2K Vertical 2 Evidence — 2026-10-02

## Status

**VERTICAL 2 IS OFFICIALLY CLOSED, VERIFIED & LOCKED**

This document records the final evidence for Vertical 2 of `d2k-hopper`: bounded stateful TCP/UDP tracking, NFQUEUE verdict integration, versioned C-to-Go session events, loss detection and exact state resynchronization, privileged dual-stack veth/netns integration testing, and reproducible component benchmarks.

## Merge chain

| Step | Pull request | Main commit |
|---|---:|---|
| Vertical 2 Step 1 — bounded TCP/UDP session tracker | #70 | `2ccc1590cffe5c2d9ff4ce5aa499849cfb94a16c` |
| Vertical 2 Step 2 — stateful NFQUEUE verdicts and Go session events | #71 | `c65c0eff13e322f1ca4639be908959a2324d87d5` |
| Vertical 2 Step 3 — dual-stack veth, state resync and benchmarks | #72 | `30cb37d96611794bf08adcfec9118299375cc27f` |

PR #72 feature head before squash merge was `f7f1759e3b21bc30f0217bdcfad86b93072855f0`.

## CI evidence

Step 3 feature CI: **CI #219 / run 37016408923 — SUCCESS, 6/6 jobs**.

Post-merge main verification: **CI #220 / run 37018037889 — SUCCESS, 6/6 jobs** on exact Step 3 main commit `30cb37d96611794bf08adcfec9118299375cc27f`.

The six mandatory CI jobs completed successfully:

- Go — format, vet, tests (including race-enabled coverage in the CI gate).
- C tracker — nine architectures.
- Scripts / ShellCheck gate.
- C datapath — target architecture builds.
- All-architecture Go builds / target verification.
- Stateful — real Linux NFQUEUE.

The retained C verification suite includes full C checks, IPv6 checksum/pipeline coverage and leak-enabled ASan/UBSan. Cross-target gates are compile/ELF evidence; native execution is Linux and is not claimed on every target CPU.

## Stateful datapath and recovery evidence

The production pipeline owns a bounded preallocated TCP/UDP tracker keyed by the unchanged 40-byte Unified FlowKey ABI. Stateful enforcement remains explicit/opt-in; unsupported, fragmented and capacity-exhaustion cases retain documented fail-open behavior.

The privileged Step 3 E2E creates isolated Linux network namespaces joined by a veth pair and drives real IPv4 and IPv6 TCP/UDP traffic through production libnetfilter_queue callbacks. It verifies bidirectional TCP payloads and FIN lifecycle, UDP query/reply identity, ACCEPT/DROP accounting, contiguous event decoding, and rejection of early DATA and SYN+FIN probes for both address families.

State recovery uses versioned `BEGIN / ROW / END / WATERMARK` frames. A single-owner C snapshot captures an immutable sequence cut into a fixed buffer allocated at pipeline initialization. Go detects event gaps or changed loss counters, requests a full dump, validates bounded rows and metadata, and atomically replaces the active mirror only after a complete END. A post-dump watermark baselines covered loss; loss after the cut forces another resync.

A one-entry real C ring integration test deliberately overflows session events, verifies automatic C/Go resync to the exact three-session map, then loses timeout-close events and verifies recovery to the exact empty map. Unit coverage includes malformed/versioned/oversized dumps, duplicate/reordered rows, incomplete END, retry IDs, immutable snapshots and atomic publication.

## Performance evidence

Methodology and raw local samples are retained in `docs/STATEFUL_RECOVERY_STEP3.md` and `docs/benchmarks/vertical2-local-2026-10-02.json`.

Local x86_64 Linux / AMD EPYC 9V74 / GCC 13 / `-O2`, median of five round means with 131,072 concurrent dual-stack UDP identities and 1,048,576 operations per round:

| Component | Result |
|---|---:|
| Hash lookup | **157.04 ns/op** |
| UDP state update | **147.28 ns/op** |
| Dual-stack C packet pipeline | **280.99 ns/op** |
| Derived component throughput | **3.559 Mpps** |
| Tracker owned allocation | **15,728,736 bytes (15.000 MiB)** |
| Whole pipeline incl. 256-event ring + snapshot reserve | **27,283,680 bytes (26.020 MiB)** |
| Local suite max RSS | **43,648 KiB** |

Lookup is expected **O(1)** at bounded load; this is not a worst-case collision guarantee. The latency/pps figures are component microbenchmarks using synthetic parser input, not kernel NFQUEUE throughput, per-packet percentile latency, or Keenetic hardware performance. Max RSS includes additional benchmark allocations and is not pipeline resident memory. Target ABI sizes may differ.

## Architectural guarantees retained

- No packet-hot-path heap allocation is introduced by Vertical 2.
- Timed C benchmark code uses integer arithmetic only.
- Unified FlowKey remains 40 bytes and legacy wire formats remain unchanged.
- Native C struct padding is not serialized.
- Snapshot delivery is bounded/nonblocking and does not introduce an unbounded transport queue.
- Event loss is observable and recoverable through exact state dump; incomplete mirrors are not treated as authoritative.
- Full TCP sequence/window firewall validation is outside the claimed Vertical 2 scope.

## Final verdict

The Step 1 tracker, Step 2 NFQUEUE/event bridge, and Step 3 dual-stack kernel E2E/reconciliation/benchmark work are merged into `main`. The exact Step 3 merge commit passed the mandatory post-merge CI #220 with all six jobs successful.

**VERTICAL 2 IS OFFICIALLY CLOSED, VERIFIED & LOCKED**

The repository may proceed to **Vertical 3 — Dynamic Rules Engine & BPF Offload**, using `30cb37d96611794bf08adcfec9118299375cc27f` as the verified Vertical 2 code baseline. Any subsequent documentation-only evidence commit does not alter that tested code baseline.
