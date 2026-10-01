# Virtual Laboratory Complete

## Exit manifest

Final virtual-lab verification is complete for the pre-Gate-6 software/test scope.

- Gate 2: MIPS D2K execution lab — SUCCESS (Run 36895720904).
- Gate 3: MIPS NFQUEUE forwarding path — SUCCESS (Run 36895721037).
- Gate 4: TLS ClientHello and QUIC Initial parsing — SUCCESS (Run 36895721229).
- Gate 5: fault tolerance and 128 MiB QEMU resource lab — SUCCESS (Run 36895720915).
- CI: Go format/vet/tests, C target builds, sanitizer tests, all-architecture builds, and ShellCheck — SUCCESS (Run 36895720911).

## Validated capability manifest

### MIPS32R2 / 128 MiB resource envelope
Gate 2/CI validate the target datapath builds and MIPS execution path. Gate 5 boots QEMU constrained to 128 MiB and completes the bounded resource load without the configured OOM signatures.

### NFQUEUE forwarding path
Gate 3 validates the NFQUEUE forwarding path and its forwarding tests in the virtual lab.

### L7 parsers
Gate 4 validates TLS ClientHello SNI parsing and QUIC Initial parsing for the RFC 9000 path.

### Dual-stack Control ABI
The repository contains the IPv4 and IPv6 Control ABI, including D2K_CMD_SET_ADDR6 and the typed IPv6 event/control structures.

### Fault tolerance
Gate 5 validates kill -9 handling, Entware-style autostart/watchdog recovery, fail-open HTTP continuity, and rollback cleanup of the D2K_HOPPER iptables chain.

## Exit condition

The software/test laboratory evidence is sufficient to begin the separate physical-preflight checklist. This document does not claim that a physical Keenetic Hopper KN-3810 run has occurred.

Physical activation remains gated by docs/GATE6_PHYSICAL_PREFLIGHT.md.