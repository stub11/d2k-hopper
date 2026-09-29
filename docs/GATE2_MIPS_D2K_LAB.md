# Gate 2 — MIPS softfloat D2K execution lab

## Scope

Build the actual Go CLI entry point (`./cmd/d2k`) for Linux MIPS little-endian
with `GOARCH=mipsle`, `GOMIPS=softfloat`, and `CGO_ENABLED=0`. Boot the
existing Buildroot MIPS32R2 Malta system with QEMU CPU model `24Kc` and
`128M` RAM. Mount a separate EXT4 disk at `/opt`, populated with the official
MIPSEL Entware installer, then execute the D2K CLI from that disk.

## Reproduce

On Ubuntu with Go matching `go.mod`, QEMU system MIPS, Buildroot dependencies,
e2fsprogs, binutils, and ShellCheck:

```sh
sh scripts/build-mips-d2k.sh
sudo sh scripts/gate2-qemu-test.sh
```

The CI workflow runs both commands and uploads the serial log, binary, and ELF
header. It is intentionally independent of physical-router access.

## Green criteria

- ELF is 32-bit, little-endian, MIPS.
- The VM boots with `-cpu 24Kc -m 128M`.
- EXT4 disk mounts at `/opt`; the actual Entware `opkg` and D2K binary are present.
- `/opt/bin/d2k --version` and `/opt/bin/d2k --help` return zero.
- Serial log contains `GATE2_RESULT=SUCCESS`.
- Kernel/serial logs contain no illegal/reserved instruction, bus error, or OOM-killer signatures.

## Limitations

This is a Malta/QEMU compatibility test, not an MT7621 silicon emulator. It does
not establish exact physical RAM availability to userspace, performance, stock
KeeneticOS ABI/kernel behavior, availability of `nfnetlink_queue` or
`xt_NFQUEUE`, MT7621 HWNAT visibility, DSA/switch/VLAN behavior, or Wi-Fi.
It does not run the C datapath (`d2kd`) or validate NFQUEUE, TLS, or QUIC.
A clean kernel log is limited to messages emitted during this VM boot and test.
