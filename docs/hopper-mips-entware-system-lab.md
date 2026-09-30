# Hopper 3810 MIPS system + Entware lab

This is the next isolation layer after the separate EXT4/Entware userspace lab.

It boots the official Buildroot 2026.08 qemu_mips32r2el_malta_defconfig under qemu-system-mipsel, attaches a second real EXT4 disk, populates that disk with the official KN-3810 MIPSEL Entware installer, mounts it as /opt, and executes the real MIPSEL opkg from the mounted disk.

This is intentionally not a Hopper SoC emulator. Malta does not emulate EN7528DU, KeeneticOS, NDM, HWNAT/WHNAT, Wi-Fi, flash, or the router's USB controller.

## Acceptance gates

- MIPS32R2 little-endian Linux boots.
- PCnet32 is present.
- The second disk is EXT4.
- The official Entware MIPSEL installer populates /opt.
- Linux mounts the second disk as /opt during boot.
- /opt/bin/opkg executes inside the MIPS Linux VM.

The next gate is real opkg update from inside the VM, followed by a minimal D2K binary and network/NFQUEUE tests. External package repository availability remains an independent CI dependency and is not silently treated as a local emulation result.
