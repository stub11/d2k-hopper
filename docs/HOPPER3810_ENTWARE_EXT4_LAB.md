# Hopper 3810 Entware / EXT4 Virtual Lab

This lab models the storage and package layer used by the official KN-3810 Entware installation flow.

Keenetic's KN-3810 documentation specifies:
- an external USB drive formatted as EXT4;
- the Open Package Support (OPKG) component;
- the MIPSEL `mipsel-installer.tar.gz`;
- Entware mounted at `/opt`;
- package repositories under `mipselsf-k3.4`;
- `opkg update` followed by normal package installation.

The CI lab reproduces the safe, device-independent part:

1. creates a real EXT4 filesystem image;
2. creates the USB-style `install/` directory;
3. downloads the current official MIPSEL installer;
4. verifies the installer contains the expected `opkg` and configuration;
5. reconstructs the Entware `/opt` tree;
6. executes the real MIPSEL `opkg` binary with QEMU;
7. performs a live `opkg update` against the Entware repository;
8. verifies the package index was populated.

## Why this matters

The D2K runtime should be treated as an **Entware application installed on the USB-backed `/opt` filesystem**, not as a standalone binary copied into an abstract router root.

The next integration tests can therefore place D2K and other MIPSEL utilities under this same `/opt` tree and test:
- executable/library compatibility;
- startup scripts;
- configuration persistence;
- restart after process failure;
- package dependencies;
- storage removal/reappearance scenarios.

## Explicit limits

This is not a KeeneticOS emulator. It does not prove:
- NDM/OPKG GUI behavior;
- real USB controller behavior;
- KeeneticOS mount lifecycle;
- NFQUEUE kernel integration;
- HWNAT/WHNAT;
- Wi-Fi;
- flash/recovery;
- exact KN-3810 CPU/RAM behavior.

A green result means the Entware/MIPSEL storage and package layer can be exercised without risking the physical Hopper.
