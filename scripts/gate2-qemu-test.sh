#!/bin/sh
# Virtual-only Gate 2. No physical router access.
# Uses official Debian MIPS Malta prebuilt kernel/rootfs assets; no Buildroot compilation.
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
WORK="${RUNNER_TEMP:-/tmp}/d2k-gate2-$$"
ASSET_DIR="${GATE2_ASSET_DIR:-$HOME/.cache/d2k-gate2}"
ROOTFS_TAR="$ASSET_DIR/debian-buster-mipsel.tar.xz"
KERNEL_BIN="$ASSET_DIR/vmlinux-3.2.0-4-4kc-malta"
ROOTFS_IMAGE="$WORK/debian-rootfs.ext4"
OPT_IMAGE="$WORK/hopper-opt.ext4"
ROOTFS_MOUNT="$WORK/rootfs"
OPT_MOUNT="$WORK/opt"
LOG_OUT="$ROOT/qemu-gate2-serial.log"
D2K_BIN="$ROOT/dist/mips/d2k"
ROOTFS_BASE="https://people.debian.org/~jcowgill/qemu-mips"
KERNEL_BASE="https://people.debian.org/~aurel32/qemu/mipsel"

cleanup() {
  timeout 30s sudo umount "$OPT_MOUNT" 2>/dev/null || true
  timeout 30s sudo umount "$ROOTFS_MOUNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
for x in curl tar truncate mkfs.ext4 mount timeout qemu-system-mipsel readelf go; do need "$x"; done
[ -x "$D2K_BIN" ] || { echo "missing built binary: $D2K_BIN" >&2; exit 1; }

mkdir -p "$WORK" "$ASSET_DIR" "$ROOTFS_MOUNT" "$OPT_MOUNT"

echo "[STEP] Download Debian Malta kernel/rootfs..."
[ -s "$ROOTFS_TAR" ] || curl -fsSL --connect-timeout 10 --max-time 30 -o "$ROOTFS_TAR" "$ROOTFS_BASE/debian-buster-mipsel.tar.xz"
[ -s "$KERNEL_BIN" ] || curl -fsSL --connect-timeout 10 --max-time 30 -o "$KERNEL_BIN" "$KERNEL_BASE/vmlinux-3.2.0-4-4kc-malta"

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

echo "[STEP] Build static MIPS Gate 2 init..."
cat > "$WORK/gate2-init.go" <<'EOF'
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

func stop(ok bool, msg string) {
	if msg != "" {
		fmt.Println(msg)
	}
	if !ok {
		os.Exit(1)
	}
	syscall.Sync()
	if err := syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF); err != nil {
		fmt.Printf("GATE2: reboot failed: %v\n", err)
		os.Exit(1)
	}
	os.Exit(0)
}

func run(name string, args ...string) bool {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	fmt.Printf("GATE2: %s\n%s", name, out)
	return err == nil
}

func main() {
	fmt.Println("GATE2: static init")
	_ = syscall.Mount("devtmpfs", "/dev", "devtmpfs", 0, "")
	for i := 0; i < 10; i++ {
		if _, err := os.Stat("/dev/sdb"); err == nil {
			break
		}
		time.Sleep(time.Second)
	}
	if err := syscall.Mount("/dev/sdb", "/opt", "ext4", 0, ""); err != nil {
		stop(false, fmt.Sprintf("GATE2_RESULT=FAIL mount-opt: %v", err))
	}
	if !run("/opt/bin/d2k", "--version") {
		stop(false, "GATE2_RESULT=FAIL version")
	}
	if !run("/opt/bin/d2k", "--help") {
		stop(false, "GATE2_RESULT=FAIL help")
	}
	if cpu, err := os.ReadFile("/proc/cpuinfo"); err == nil {
		fmt.Print(string(cpu))
	}
	if log, err := os.ReadFile("/proc/cmdline"); err == nil && strings.Contains(string(log), "console=ttyS0") {
		fmt.Println("GATE2: serial console active")
	}
	stop(true, "GATE2_RESULT=SUCCESS")
}
EOF
GOOS=linux GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0 go build -o "$WORK/gate2-init" "$WORK/gate2-init.go"
readelf -h "$WORK/gate2-init" | grep -E 'Class:|Data:|Machine:'
sudo install -m 755 "$WORK/gate2-init" "$ROOTFS_MOUNT/gate2-init"

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
  -append "root=/dev/sda rw console=ttyS0 init=/gate2-init" \
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
