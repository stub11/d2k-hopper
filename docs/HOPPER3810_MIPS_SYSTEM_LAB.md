# Hopper 3810 MIPS System Lab

This lab builds the official Buildroot 2026.08 qemu_mips32r2el_malta_defconfig and boots little-endian MIPS32R2 Linux under qemu-system-mipsel.

Malta provides an emulated PCI PCnet32 network device. This is the system-level substrate needed for real Linux networking tests; unlike qemu-mipsel-static, it has a virtual NIC and a Linux kernel.

Validated by the first gate: kernel boot, MIPS32R2 little-endian, Malta, PCnet32 and DHCP-related startup.

Malta is not the Hopper 3810 SoC. It does not emulate KeeneticOS, EN7528DU, USB storage management, HWNAT/WHNAT, Wi-Fi or flash/recovery.

Next stage: attach a second EXT4 disk as /opt, populate it with the official KN-3810 MIPSEL Entware installer, then run real Entware binaries inside the MIPS system VM.
