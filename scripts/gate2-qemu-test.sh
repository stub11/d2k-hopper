#!/bin/sh
# Virtual-only Gate 2. No physical router access.
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
WORK="${RUNNER_TEMP:-/tmp}/d2k-gate2-$$"
BR_TAR="$WORK/buildroot.tar.xz"
BR_URL="https://buildroot.org/downloads/buildroot-2026.08.tar.xz"
OPT_IMAGE="$WORK/hopper-opt.ext4"
INSTALLER="$WORK/mipsel-installer.tar.gz"
ROOTFS_MOUNT="$WORK/rootfs"
OPT_MOUNT="$WORK/opt"
LOG_OUT="$ROOT/qemu-gate2-serial.log"
D2K_BIN="$ROOT/dist/mips/d2k"

cleanup() {
  sudo umount "$OPT_MOUNT" 2>/dev/null || true
  sudo umount "$ROOTFS_MOUNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
for x in curl tar truncate mkfs.ext4 mount timeout qemu-system-mipsel readelf; do need "$x"; done
[ -x "$D2K_BIN" ] || { echo "missing built binary: $D2K_BIN" >&2; exit 1; }

mkdir -p "$WORK" "$ROOTFS_MOUNT" "$OPT_MOUNT"
echo "[STEP] Download Buildroot..."
curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 30 -o "$BR_TAR" "$BR_URL"
echo "[STEP] Extract Buildroot..."
tar -xf "$BR_TAR" -C "$WORK"
BR=$(find "$WORK" -maxdepth 1 -type d -name 'buildroot-*' | head -n 1)
[ -n "$BR" ]
cd "$BR"
echo "[STEP] Configure Buildroot..."
timeout 180s make qemu_mips32r2el_malta_defconfig
echo "[STEP] Build Buildroot..."
timeout 180s make -j"$(nproc)"
echo "[STEP] Verify Buildroot images..."
[ -s output/images/vmlinux ]
[ -s output/images/rootfs.ext2 ]

echo "[STEP] Prepare /opt image..."
truncate -s 768M "$OPT_IMAGE"
mkfs.ext4 -F -L HOPPEROPT "$OPT_IMAGE" >/dev/null
echo "[STEP] Mount /opt image..."
timeout 30s sudo mount -o loop "$OPT_IMAGE" "$OPT_MOUNT"
echo "[STEP] Download Entware installer..."
curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 30 -o "$INSTALLER" \
  "https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz"
tar -xzf "$INSTALLER" -C "$OPT_MOUNT" --no-same-owner
sudo install -m 755 "$D2K_BIN" "$OPT_MOUNT/bin/d2k"
[ -x "$OPT_MOUNT/bin/opkg" ]
echo "[STEP] Unmount /opt image..."
sudo umount "$OPT_MOUNT"

echo "[STEP] Inject Gate 2 boot test..."
echo "== Inject Gate 2 boot test into Buildroot rootfs =="
echo "[STEP] Mount rootfs image..."
timeout 30s sudo mount -o loop "$BR/output/images/rootfs.ext2" "$ROOTFS_MOUNT"
sudo mkdir -p "$ROOTFS_MOUNT/opt" "$ROOTFS_MOUNT/etc/init.d"
sudo sh -c 'cat > "$1/etc/init.d/S99gate2-d2k"' sh "$ROOTFS_MOUNT" <<'EOF'
#!/bin/sh
echo "GATE2: start"
mount -t ext4 /dev/sdb /opt || { echo "GATE2_RESULT=FAIL mount-opt"; exit 1; }
[ -x /opt/bin/d2k ] || { echo "GATE2_RESULT=FAIL missing-d2k"; exit 1; }
echo "GATE2: cpu"
cat /proc/cpuinfo
echo "GATE2: version"
if ! /opt/bin/d2k --version; then
  echo "GATE2_RESULT=FAIL version"
  exit 1
fi
echo "GATE2: help"
if ! /opt/bin/d2k --help > /tmp/d2k-help.txt 2>&1; then
  cat /tmp/d2k-help.txt
  echo "GATE2_RESULT=FAIL help"
  exit 1
fi
head -n 12 /tmp/d2k-help.txt
echo "GATE2: dmesg scan"
if dmesg | grep -iE 'illegal instruction|reserved instruction|bus error|out of memory|oom-killer|killed process'; then
  echo "GATE2_RESULT=FAIL kernel-fault"
  exit 1
fi
echo "GATE2_RESULT=SUCCESS"
sync
echo 1 > /proc/sys/kernel/sysrq && echo o > /proc/sysrq-trigger || poweroff -f || halt -f
EOF
sudo chmod 755 "$ROOTFS_MOUNT/etc/init.d/S99gate2-d2k"
echo "[STEP] Unmount rootfs image..."
sudo umount "$ROOTFS_MOUNT"

echo "[STEP] Launch QEMU..."
rm -f "$LOG_OUT"
set +e
echo "[STEP] QEMU timeout: 180s"
timeout 180s qemu-system-mipsel \
  -M malta -cpu 24Kc -m 128M \
  -kernel "$BR/output/images/vmlinux" \
  -drive file="$BR/output/images/rootfs.ext2",format=raw,if=ide,index=0 \
  -drive file="$OPT_IMAGE",format=raw,if=ide,index=1 \
  -append "rootwait root=/dev/sda console=ttyS0" \
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
echo "LIMITATION: Malta/QEMU is not the MT7621 silicon or KeeneticOS; NFQUEUE, HWNAT, switch/VLAN and Wi-Fi are not tested."
