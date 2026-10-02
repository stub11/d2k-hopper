#!/bin/sh
set -eu
ROOT="${RUNNER_TEMP:-/tmp}/hopper-mips-entware-system-$$"
BR_TAR="$ROOT/buildroot.tar.xz"
BR_URL="https://buildroot.org/downloads/buildroot-2026.08.tar.xz"
OPT_IMAGE="$ROOT/hopper-opt.ext4"
INSTALLER="$ROOT/mipsel-installer.tar.gz"
ENTWARE_URL="https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz"
ROOTFS_MOUNT="$ROOT/rootfs"
OPT_MOUNT="$ROOT/opt"
QEMU_LOG="$ROOT/qemu.log"
# Keep boot diagnostics outside the temporary Buildroot tree, even on failure.
QEMU_EVIDENCE="$(pwd)/qemu-mips-entware-system.log"
cleanup() {
  if [ -f "$QEMU_LOG" ]; then
    cp "$QEMU_LOG" "$QEMU_EVIDENCE" || true
    echo "QEMU evidence: $QEMU_EVIDENCE" >&2
  fi
  sudo umount "$OPT_MOUNT" 2>/dev/null || true
  sudo umount "$ROOTFS_MOUNT" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
for x in curl tar truncate mkfs.ext4 mount timeout qemu-system-mipsel; do need "$x"; done
mkdir -p "$ROOT" "$ROOTFS_MOUNT" "$OPT_MOUNT"
curl --fail --silent --show-error --location --retry 3 -o "$BR_TAR" "$BR_URL"
tar -xf "$BR_TAR" -C "$ROOT"
BR="$(find "$ROOT" -maxdepth 1 -type d -name "buildroot-*" | head -n 1)"
cd "$BR"
make qemu_mips32r2el_malta_defconfig
make -j"$(nproc)"
[ -s output/images/vmlinux ] || { echo "missing or empty MIPS vmlinux kernel image" >&2; ls -lh output/images >&2 || true; exit 1; }
[ -s output/images/rootfs.ext2 ] || { echo "missing or empty MIPS rootfs.ext2 image" >&2; ls -lh output/images >&2 || true; exit 1; }
echo "== Build real Entware EXT4 /opt disk =="
truncate -s 768M "$OPT_IMAGE"
mkfs.ext4 -F -L HOPPEROPT "$OPT_IMAGE" >/dev/null
sudo mount -o loop "$OPT_IMAGE" "$OPT_MOUNT"
curl --fail --silent --show-error --location --retry 3 -o "$INSTALLER" "$ENTWARE_URL"
tar -xzf "$INSTALLER" -C "$OPT_MOUNT" --no-same-owner
[ -x "$OPT_MOUNT/opt/bin/opkg" ]
[ -f "$OPT_MOUNT/opt/etc/opkg.conf" ]
# The installer archive contains opt/... paths, but the disk itself is mounted
# at /opt inside the guest. Flatten exactly one opt/ level to avoid /opt/opt/.
cp -a "$OPT_MOUNT/opt/." "$OPT_MOUNT/"
rm -rf "$OPT_MOUNT/opt"
[ -x "$OPT_MOUNT/bin/opkg" ]
[ -f "$OPT_MOUNT/etc/opkg.conf" ]
echo "== Inject boot-time /opt mount into Buildroot rootfs =="
sudo mount -o loop "$BR/output/images/rootfs.ext2" "$ROOTFS_MOUNT"
sudo mkdir -p "$ROOTFS_MOUNT/opt" "$ROOTFS_MOUNT/etc/init.d"
sudo sh -c 'cat > "$1/etc/init.d/S20hopper-opt"' sh "$ROOTFS_MOUNT" <<'EOF'
#!/bin/sh
mount -t ext4 /dev/sdb /opt
if [ -x /opt/bin/opkg ]; then
  /opt/bin/opkg --version
  echo "HOPPER_OPT_MOUNT: GREEN"
else
  echo "HOPPER_OPT_MOUNT: FAIL" >&2
  exit 1
fi
EOF
sudo chmod 755 "$ROOTFS_MOUNT/etc/init.d/S20hopper-opt"
sudo cp /etc/resolv.conf "$ROOTFS_MOUNT/etc/resolv.conf"
sudo umount "$ROOTFS_MOUNT"
echo "== Boot Malta with separate real EXT4 /opt disk =="
set +e
timeout 90s qemu-system-mipsel -M malta -m 256 -kernel output/images/vmlinux -drive file=output/images/rootfs.ext2,format=raw,if=ide,index=0 -drive file="$OPT_IMAGE",format=raw,if=ide,index=1 -append "rootwait root=/dev/sda console=ttyS0" -net nic,model=pcnet -net user -nographic -no-reboot > "$QEMU_LOG" 2>&1
RC=$?
set -e
cp "$QEMU_LOG" "$QEMU_EVIDENCE"
require_boot_marker() {
  if ! grep -q -E "$1" "$QEMU_LOG"; then
    echo "MIPS Entware lab missing boot marker: $2 (QEMU exit $RC)" >&2
    tail -n 90 "$QEMU_LOG" >&2
    exit 1
  fi
}
require_boot_marker "Linux version" "Linux version"
require_boot_marker "pcnet32|eth0" "network interface"
require_boot_marker "HOPPER_OPT_MOUNT: GREEN" "EXT4 /opt and opkg"
require_boot_marker "opkg version" "opkg execution"
sed -n '/Linux version/p;/pcnet32/p;/eth0/p;/HOPPER_OPT_MOUNT/p;/opkg version/p' "$QEMU_LOG" | head -n 80
if [ "$RC" -ne 0 ] && [ "$RC" -ne 124 ]; then exit "$RC"; fi
echo "HOPPER3810 MIPS SYSTEM + ENTWARE LAB: GREEN"
echo "Validated: Buildroot MIPS32R2 Malta Linux, PCnet32, separate EXT4 /opt disk, official MIPSEL Entware payload, and real opkg execution inside the VM."
echo "NOT VALIDATED: KeeneticOS, EN7528DU, real USB controller, NFQUEUE, HWNAT/Wi-Fi, D2K/QUIC."
