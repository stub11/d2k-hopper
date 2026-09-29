# Hopper 3810 Virtual Network Fault Matrix

The lab extends the isolated MIPS network namespace without touching a physical
KN-3810 or the user's network.

Coverage:
- MIPS little-endian D2K panel over TCP;
- process termination and restart recovery;
- 100 ms network delay injection;
- local TLS service and handshake;
- deterministic UDP datagram round-trip;
- final TCP recovery.

Limits: this is userspace/network-namespace testing, not KeeneticOS emulation.
It does not prove NFQUEUE, hardware NAT/offload, Wi-Fi, flash/recovery, exact
router resource limits, or QUIC behavior. A green run does not validate the
physical Hopper 3810. The physical device remains untouched.
