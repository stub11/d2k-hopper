# D2K Vertical 2 Evidence — 2026-10-02

## Status

**VERTICAL 2 (STATEFUL SESSION TRACKING & NFQUEUE DATAPATH) IS OFFICIALLY CLOSED, VERIFIED & GOLDEN LOCKED.**

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

**VERTICAL 2 (STATEFUL SESSION TRACKING & NFQUEUE DATAPATH) IS OFFICIALLY CLOSED, VERIFIED & GOLDEN LOCKED.**

The repository may proceed to **Vertical 3 — Dynamic Rules Engine & BPF Offload**, using `30cb37d96611794bf08adcfec9118299375cc27f` as the verified Vertical 2 code baseline. Any subsequent documentation-only evidence commit does not alter that tested code baseline.

## Golden Lock verification matrix (verified 2026-10-02)

The following are **six evidence dimensions**, not a claim of six separately named GitHub workflows. All six required jobs of the post-merge [CI #220](https://github.com/stub11/d2k-hopper/actions/runs/37018037889) completed successfully on the immutable code baseline `30cb37d96611794bf08adcfec9118299375cc27f`:

| Evidence dimension | Result and evidence | Scope / limitation |
|---|---|---|
| 1. Dual-stack veth E2E | PASS — `Stateful — real Linux NFQUEUE` job, step `Real dual-stack veth and namespace bridge`: real IPv4/IPv6 TCP and UDP through veth/netns and production queue callbacks, bidirectional traffic, FIN, and early DATA/SYN+FIN DROP probes. | Native privileged Linux CI, not a physical Keenetic performance test. |
| 2. NFQUEUE datapath / C➜Go bridge | PASS — native NFQUEUE job includes `Isolated netns — real queue and verdicts`; verdict accounting and session events are checked by Step 2/Step 3 tests. | Opt-in stateful enforcement and documented fail-open cases remain in place. |
| 3. State Resync Protocol | PASS — bounded versioned `BEGIN/ROW/END/WATERMARK`, cut validation, loss detection, atomic map replacement and overflow recovery; covered by C/Go regression suites in CI, including one-entry C ring E2E. | Recovered active identity/state map is exact at cut; silent data/UDP timestamp refreshes are not a live full metadata mirror. |
| 4. Integer-only component benchmarks | PASS — C job step `C benchmarks — 131072 live dual-stack UDP sessions` and Go job step `Go bridge and decoder benchmarks`. Local raw samples preserved in `docs/benchmarks/vertical2-local-2026-10-02.json`. | Synthetic component workload; no claims about hardware throughput or kernel NFQUEUE Mpps. |
| 5. Nine-architecture verification | PASS — `C tracker — девять архитектур` plus `Сборка под все арки`; target datapath builds also PASS. | Cross-architecture compilation/ELF identity, not native runtime execution on nine hardware devices. |
| 6. Sanitizers / regression safety | PASS — C datapath job step `Тесты под санитайзерами` (ASan/UBSan suite), plus IPv6 pipeline, plan tests, Go format/vet/race. | Recorded as clean **within CI test coverage**, not proof of absence of all defects. |

**Performance interpretation:** At the measured bounded load, the tracker hash lookup is expected **average O(1)**; this is algorithmic complexity, not a constant worst-case bound. The local measured mean latency median is **157.04 ns/op lookup**, **147.28 ns/op UDP update**, and **280.99 ns/op dual-stack C pipeline**, equivalent to **3.559 million synthetic pipeline operations/sec** (derived component Mpps). Measured tracker allocation is **15,728,736 bytes (15.000 MiB)**; whole 64-bit pipeline including 256-event ring and snapshot reserve is **27,283,680 bytes (26.020 MiB)**. Local suite max RSS **43,648 KiB** includes separate benchmark setup and is not the pipeline memory footprint. These results are not hardware latency, per-packet tail latency, or a forwarding-rate benchmark.

**Code freeze reference:** `30cb37d96611794bf08adcfec9118299375cc27f` — PR #72 merge baseline validated by CI #220. The pre-existing evidence-only main commit `bb6a11fa87249e73720f5e3f9c132e6c2e72aa03` changes the evidence file, not the tested datapath code. Subsequent documentation refinements do not change the frozen code baseline.

**Workflow scope notice:** The six mandatory `CI` jobs above are green; independent `Gate 3 — MIPS NFQUEUE Forwarding Path` and `Hopper 3810 Virtual Lab` workflow runs on the evidence-only commit have recorded failures, and a separate hardware system lab run was in progress at verification. The Golden Lock certifies the described Vertical 2 CI scope, **not** a claim that every repository workflow or physical-router gate is green. Those independent lab issues must be evaluated before describing a full physical-device release as verified.

## Vertical 3 handoff

Vertical 3 — **Dynamic Rules Engine & BPF Offload** may proceed from the frozen, tested Vertical 2 code baseline. Maintain the 40-byte Unified FlowKey ABI, the established serialized event formats, bounded no-heap packet hot path and integer-only C constraints; require fresh CI for any code change. Golden Lock is a traceable engineering milestone, not a GitHub branch-protection rule or a claim of production router certification.

**Official final verdict: VERTICAL 2 (STATEFUL SESSION TRACKING & NFQUEUE DATAPATH) IS OFFICIALLY CLOSED, VERIFIED & GOLDEN LOCKED.**
