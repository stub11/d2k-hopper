# Gate 5 — Fault Tolerance Evidence

## Scope

This document records the GitHub Actions evidence actually available for the Gate 5 fault-tolerance lab. It intentionally distinguishes individual checks that passed from the overall Gate 5 result.

## Key run

- Workflow: Gate 5 — Fault tolerance & resource limits
- Run number: 5
- Run ID: 36834596712
- Event: pull_request
- Branch: fix-gate5-qemu-kernel
- Head SHA: c931aaa314b3472103e475ad11013a302a3be6f2
- Started: 2026-10-01 08:09:37 UTC
- Finished: 2026-10-01 08:10:15 UTC
- Overall conclusion: failure
- Job: fault-lab
- Job conclusion: failure

## Evidence from the key log

The Gate 5 validation step reached these stages successfully:

1. Static shell validation — passed.
2. Entware autostart + watchdog recovery — the test started the daemon, sent SIGKILL (kill -9) to the recorded PID, and detected a new live PID before continuing.
3. Rollback — the rollback test completed and verified the D2K iptables chain operations and PID-file removal.
4. Fail-open HTTP continuity after d2kd SIGKILL — HTTP returned successfully before and after the daemon was killed.

Relevant log sequence:

    [gate5] static shell validation
    [gate5] Entware autostart + watchdog recovery
    [gate5] rollback removes D2K iptables chain and stops service
    [gate5] fail-open HTTP continuity after d2kd SIGKILL

The run then entered the 128M QEMU stage:

    [gate5] QEMU 128M resource lab
    [gate5] QEMU=/usr/bin/qemu-system-x86_64 kernel=/home/runner/work/_temp/vmlinuz cpio=/usr/bin/cpio busybox=/usr/bin/busybox
    [gate5] FAIL: QEMU resource lab prerequisites missing (qemu-system-x86_64, kernel, cpio, busybox)
    ##[error]Process completed with exit code 1.

The workflow therefore did not produce the required QEMU evidence artifact. The artifact query for Run ID 36834596712 returned no artifacts.

## Gate 5 status

NOT PASSED by this recorded run.

The available evidence proves:

- SIGKILL / watchdog restart: PASS
- Entware-style autostart contract: PASS
- rollback / D2K chain cleanup: PASS
- fail-open HTTP continuity after daemon SIGKILL: PASS
- 128M QEMU boot + no-OOM evidence: NOT VERIFIED
- Overall Gate 5: FAIL

## Important history

PR #39 (fix(gate5): make 128M QEMU kernel readable) was subsequently merged to main as:

ca3b0e68c518491ab7a8a12fb916ed7af1ec457e

The PR changed the Gate 5 workflow to provide QEMU_KERNEL under the runner temporary directory and made the QEMU prerequisite test require an executable QEMU binary and a readable kernel.

This document does not infer a successful Gate 5 result from the merge. A fresh successful Gate 5 run containing both GATE5-QEMU-BOOT and GATE5-QEMU-NO-OOM is still required before marking the gate green.
