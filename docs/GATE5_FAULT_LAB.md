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


## Automated lab

The implementation is in `scripts/gate5-fault-test.sh`, with the Entware contract in
`scripts/S99d2k` and one-command rollback in `scripts/rollback.sh`.

The CI workflow `.github/workflows/gate5-fault.yml` runs four checks:

- **Fault injection / fail-open continuity:** a datapath-process SIGKILL is injected while a local HTTP endpoint is serving; subsequent requests must remain HTTP 200.
- **Watchdog/autostart:** the Entware-style `S99d2k` starts the daemon and restarts it after SIGKILL.
- **Rollback:** a controlled iptables shim verifies that the D2K chain is detached, flushed and deleted, while the service PID is stopped; the script must exit 0.
- **128M QEMU resource lab:** a Linux guest is booted with `-m 128M`; sustained allocation is exercised and serial output is rejected if it contains OOM-killer/SIGSEGV evidence.

The watchdog/rollback tests use an isolated deterministic daemon stub so CI does not require
NFQUEUE or privileged host networking. The normal datapath CI remains responsible for
building and testing the real `d2kd` binary.

## Evidence

The QEMU prerequisite line is logged before boot so a failed runner environment is diagnosable.

Evidence is uploaded by the Gate 5 workflow as the `gate5-fault-evidence` artifact.
The workflow prepares a readable guest kernel for unprivileged QEMU execution. The kernel is copied into RUNNER_TEMP before boot, and the workflow also runs on pushes to main so merged Gate 5 code is validated on main. The gate is not considered passed until the workflow is green and the QEMU serial log
contains both `GATE5-QEMU-BOOT` and `GATE5-QEMU-NO-OOM`.
