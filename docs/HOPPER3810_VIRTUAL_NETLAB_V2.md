# Hopper 3810 Virtual Network Fault Matrix v2

Adds deterministic DNS protocol validation, 100% packet-loss failure/recovery,
delay plus packet reordering, service disappearance, and final restart recovery.

All tests run in a disposable Linux network namespace with MIPS/QEMU userspace.
The physical Hopper 3810 and the user's network are untouched.

A green run does not emulate KeeneticOS, NFQUEUE, hardware NAT/offload, Wi-Fi,
flash/recovery, exact hardware resource limits, or prove QUIC behavior.
