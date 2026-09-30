# Gate 5 — Fault Injection, Rollback, OOM & Watchdog

## Scope

Gate 5 validates controlled failure handling in the MIPS datapath/runtime.

Acceptance targets:
1. Fault injection can trigger deterministic datapath failures without corrupting persistent state.
2. Rollback restores the last known-good state after an injected failure.
3. OOM pressure is detected and handled without kernel panic, SIGSEGV/SIGBUS, or unbounded retry.
4. Watchdog timeout/recovery is deterministic and leaves the datapath in a usable state.
5. CI records serial evidence for each fault scenario and verifies the final recovery state.
6. Tests remain reproducible under Debian Malta QEMU and fit the CI time budget.

The gate must not be considered passed until QEMU serial evidence demonstrates every required recovery scenario.
