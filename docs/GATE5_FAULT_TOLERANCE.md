# Gate 5 — Fault Tolerance Evidence

## Final verified result

Gate 5 is SUCCESS on the final pre-Gate-6 verification tree.

- Workflow: Gate 5 — Fault tolerance & resource limits
- Run ID: 36895720915
- Run number: 40
- Job: fault-lab
- Head SHA: 261740286a7662dfcc98002254e16b4fd70d40dd
- Merged main SHA: 6884a35c9b2d85cc449ab5aa7328808595381f46
- Conclusion: SUCCESS

## QEMU serial evidence

The 128 MiB QEMU resource lab produced the required markers:

    GATE5-QEMU-BOOT
    GATE5-QEMU-LOAD-OK
    GATE5-QEMU-NO-OOM

The successful serial sequence demonstrates that the minimal initramfs booted, completed the bounded resource load, and did not report the configured OOM signatures.

The final QEMU test uses a 40 MiB tmpfs mounted at /tmp while QEMU remains constrained to -m 128M.

## Fault-tolerance evidence

The same successful Gate 5 job executed:

    [gate5] Entware autostart + watchdog recovery
    [gate5] rollback removes D2K iptables chain and stops service
    [gate5] fail-open HTTP continuity after d2kd SIGKILL

The watchdog test starts the deterministic d2kd stand-in, sends SIGKILL (kill -9) to its recorded PID, and requires a different live PID before continuing.

The rollback test verifies removal of the D2K_HOPPER iptables chain operations and PID-file cleanup.

The fail-open test verifies HTTP continuity before and after a d2kd SIGKILL.

The job ended with:

    [gate5] PASS: fault injection, watchdog/autostart, rollback and 128M QEMU resource checks

## CI corroboration

For the same head SHA 261740286a7662dfcc98002254e16b4fd70d40dd, CI Run ID 36895720911 / Run #199 was SUCCESS.

Successful CI jobs included:

- Go — format, vet, tests
- Datapath on C — target-architecture builds
- C sanitizer tests (ASan/UBSan test step)
- all-architecture builds
- scripts / ShellCheck

Gate 2 Run 36895720904, Gate 3 Run 36895721037, and Gate 4 Run 36895721229 were also SUCCESS on this verification SHA.

## Status

Gate 5: GREEN

This document records the successful verification rather than inferring success from a merge alone.
