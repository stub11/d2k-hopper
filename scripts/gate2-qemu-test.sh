#!/bin/sh
# Virtual-only Gate 2. No physical router access.
# Uses official Debian MIPS Malta prebuilt kernel/rootfs assets; no Buildroot compilation.
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
WORK="${RUNNER_TEMP:-/tmp}/d2k-gate2-$$"
ASSET_DIR="${GATE2_ASSET_DIR:-$HOME/.cache/d2k-gate2}"
ROOTFS_TAR="$ASSET_DIR/debian-buster-mipsel.tar.xz"
KERNEL_BIN="$ASSET_DIR/vmlinux-3.2.0-4-4kc-malta"
INITRD_BIN=""
ROOTFS_IMAGE="$WORK/debian-rootfs.ext4"
OPT_IMAGE="$WORK/hopper-opt.ext4"
ROOTFS_MOUNT="$WORK/rootfs"
OPT_MOUNT="$WORK/opt"
LOG_OUT="$ROOT/qemu-gate2-serial.log"
D2K_BIN="$ROOT/dist/mips/d2k"
ASSET_BASE="https://people.debian.org/~aurel32/qemu/mipsel"

cleanup() {
  timeout 30s sudo umount "$OPT_MOUNT" 2>/dev/null || true
  timeout 30s sudo umount "$ROOTFS_MOUNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
for x in curl tar truncate mkfs.ext4 mount timeout qemu-system-mipsel readelf; do need "$x"; done
[ -x "$D2K_BIN" ] || { echo "missing built binary: $D2K_BIN" >&2; exit 1; }

mkdir -p "$WORK" "$ASSET_DIR" "$ROOTFS_MOUNT" "$OPT_MOUNT"

echo "[STEP] Download Debian Malta kernel/rootfs..."
[ -s "$ROOTFS_TAR" ] || curl -fsSL --connect-timeout 10 --max-time 30 -o "$ROOTFS_TAR" "$ASSET_BASE/debian-buster-mipsel.tar.xz"
[ -s "$KERNEL_BIN" ] || curl -fsSL --connect-timeout 10 --max-time 30 -o "$KERNEL_BIN" "$ASSET_BASE/vmlinux-4.14.0-3-5kc-malta.mipsel.buster"

echo "[STEP] Prepare Debian rootfs image..."
truncate -s 1G "$ROOTFS_IMAGE"
mkfs.ext4 -F -O ^metadata_csum,^64bit -L D2KROOT "$ROOTFS_IMAGE" >/dev/null
echo "[STEP] Mount rootfs image..."
timeout 30s sudo mount -o loop "$ROOTFS_IMAGE" "$ROOTFS_MOUNT"
echo "[STEP] Extract Debian rootfs..."
sudo tar -xJpf "$ROOTFS_TAR" -C "$ROOTFS_MOUNT"

echo "[STEP] Prepare /opt image..."
truncate -s 256M "$OPT_IMAGE"
mkfs.ext4 -F -L HOPPEROPT "$OPT_IMAGE" >/dev/null
echo "[STEP] Mount /opt image..."
timeout 30s sudo mount -o loop "$OPT_IMAGE" "$OPT_MOUNT"
sudo mkdir -p "$OPT_MOUNT/bin"
sudo install -m 755 "$D2K_BIN" "$OPT_MOUNT/bin/d2k"
[ -x "$OPT_MOUNT/bin/d2k" ]

echo "[STEP] Inject Gate 2 init..."
sudo mkdir -p "$ROOTFS_MOUNT/opt"
sudo sh -c 'cat > "$1/opt/gate2-init"' sh "$ROOTFS_MOUNT" <<'EOF'
#!/bin/sh
set -u
echo "GATE2: init"
mkdir -p /opt
i=0
while [ ! -b /dev/sdb ] && [ "$i" -lt 10 ]; do
  sleep 1
  i=$((i + 1))
done
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t ext4 /dev/sdb /opt || { echo "GATE2_RESULT=FAIL mount-opt"; poweroff -f; exit 1; }
[ -x /opt/bin/d2k ] || { echo "GATE2_RESULT=FAIL missing-d2k"; poweroff -f; exit 1; }
echo "GATE2: cpu"
cat /proc/cpuinfo
echo "GATE2: version"
if ! /opt/bin/d2k --version; then
  echo "GATE2_RESULT=FAIL version"
  poweroff -f
  exit 1
fi
echo "GATE2: help"
if ! /opt/bin/d2k --help > /tmp/d2k-help.txt 2>&1; then
  cat /tmp/d2k-help.txt
  echo "GATE2_RESULT=FAIL help"
  poweroff -f
  exit 1
fi
head -n 12 /tmp/d2k-help.txt
echo "GATE2: dmesg scan"
if dmesg | grep -iE 'illegal instruction|reserved instruction|bus error|out of memory|oom-killer|killed process'; then
  echo "GATE2_RESULT=FAIL kernel-fault"
  poweroff -f
  exit 1
fi
echo "GATE2_RESULT=SUCCESS"
sync
poweroff -f
EOF
sudo chmod 755 "$ROOTFS_MOUNT/opt/gate2-init"

echo "[STEP] Unmount rootfs image..."
timeout 30s sudo umount "$ROOTFS_MOUNT"
echo "[STEP] Unmount /opt image..."
timeout 30s sudo umount "$OPT_MOUNT"

echo "[STEP] Launch QEMU..."
rm -f "$LOG_OUT"
set +e
echo "[STEP] QEMU timeout: 180s"
timeout 180s qemu-system-mipsel \
  -M malta -cpu 4Kc -m 128M \
  -kernel "$KERNEL_BIN" \
  -drive file="$ROOTFS_IMAGE",format=raw,if=ide,index=0 \
  -drive file="$OPT_IMAGE",format=raw,if=ide,index=1 \
  -append "root=/dev/sda rw console=ttyS0 init=/opt/gate2-init" \
  -net nic,model=pcnet -net user -nographic -no-reboot \
  2>&1 | tee "$LOG_OUT"
QEMU_RC=$?
set -e

echo "[STEP] Analyze results..."
cat "$LOG_OUT"
grep -q 'GATE2_RESULT=SUCCESS' "$LOG_OUT" || { echo "Gate 2 failed (QEMU rc=$QEMU_RC)" >&2; exit 1; }
if grep -qiE 'illegal instruction|reserved instruction|bus error|out of memory|oom-killer|killed process' "$LOG_OUT"; then
  echo "Kernel fault signature found in serial log" >&2
  exit 1
fi
echo "GATE2: PASS (QEMU exit=$QEMU_RC)"
echo "LIMITATION: Debian Malta/QEMU is not the MT7621 silicon or KeeneticOS; NFQUEUE, HWNAT, switch/VLAN and Wi-Fi are not tested."
