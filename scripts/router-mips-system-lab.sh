#!/bin/sh
set -eu
ROOT="${RUNNER_TEMP:-/tmp}/hopper-system-lab-$$"
TAR="$ROOT/buildroot.tar.xz"
URL="https://buildroot.org/downloads/buildroot-2026.08.tar.xz"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT INT TERM
mkdir -p "$ROOT"
curl --fail --silent --show-error --location --retry 3 -o "$TAR" "$URL"
tar -xf "$TAR" -C "$ROOT"
BR="$(find "$ROOT" -maxdepth 1 -type d -name "buildroot-*" | head -n 1)"
cd "$BR"
make qemu_mips32r2el_malta_defconfig
make -j2
[ -x output/images/vmlinux ]
[ -s output/images/rootfs.ext2 ]
set +e
timeout 45s qemu-system-mipsel -M malta -m 256 -kernel output/images/vmlinux -drive file=output/images/rootfs.ext2,format=raw -append "rootwait root=/dev/sda console=ttyS0" -net nic,model=pcnet -net user -nographic -no-reboot > "$ROOT/qemu.log" 2>&1
RC=$?
set -e
grep -q "Linux version" "$ROOT/qemu.log"
grep -q -E "pcnet32|eth0|udhcpc|DHCP" "$ROOT/qemu.log"
sed -n "/Linux version/p;/pcnet32/p;/eth0/p;/udhcpc/p;/DHCP/p" "$ROOT/qemu.log" | head -n 40
if [ "$RC" -ne 0 ] && [ "$RC" -ne 124 ]; then exit "$RC"; fi
echo "HOPPER3810 MIPS SYSTEM LAB: GREEN"
echo "Validated: MIPS32R2 little-endian Linux boot, Malta, PCnet32 network path."
echo "NOT VALIDATED: KeeneticOS, EN7528DU, USB/EXT4 /opt lifecycle, NFQUEUE, HWNAT/Wi-Fi, D2K/QUIC."
