#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/d2k-gate4-$$"
ASSET_DIR="${GATE4_ASSET_DIR:-$HOME/.cache/d2k-gate4}"
ROOTFS_TAR="$ASSET_DIR/debian-buster-mipsel.tar.xz"
KERNEL_BIN="$ASSET_DIR/vmlinux-3.2.0-4-4kc-malta"
ROOTFS_IMAGE="$WORK/rootfs.ext4"; OPT_IMAGE="$WORK/opt.ext4"
ROOTFS_MOUNT="$WORK/rootfs"; OPT_MOUNT="$WORK/opt"
LOG_OUT="$ROOT/qemu-gate4-serial.log"
TARGET="$ROOT/dist/mips-d2k-parser/d2kd_parser_test"
ROOTFS_BASE="https://people.debian.org/~jcowgill/qemu-mips"
KERNEL_BASE="https://people.debian.org/~aurel32/qemu/mipsel"
cleanup(){
  set +e
  if [ -n "${QEMU_PID:-}" ]; then
    kill "$QEMU_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
for x in curl tar truncate mkfs.ext4 mount umount timeout qemu-system-mipsel readelf grep go script; do need "$x"; done
[ -x "$TARGET" ] || { echo "missing parser binary: $TARGET" >&2; exit 1; }
mkdir -p "$WORK" "$ASSET_DIR" "$ROOTFS_MOUNT" "$OPT_MOUNT"
[ -s "$ROOTFS_TAR" ] || curl -fsSL --connect-timeout 10 --max-time 60 -o "$ROOTFS_TAR" "$ROOTFS_BASE/debian-buster-mipsel.tar.xz"
[ -s "$KERNEL_BIN" ] || curl -fsSL --connect-timeout 10 --max-time 60 -o "$KERNEL_BIN" "$KERNEL_BASE/vmlinux-3.2.0-4-4kc-malta"
truncate -s 1G "$ROOTFS_IMAGE"; mkfs.ext4 -F -O ^metadata_csum,^64bit "$ROOTFS_IMAGE" >/dev/null
timeout 30s sudo mount -o loop "$ROOTFS_IMAGE" "$ROOTFS_MOUNT"; sudo tar -xJpf "$ROOTFS_TAR" -C "$ROOTFS_MOUNT"
sudo mkdir -p "$ROOTFS_MOUNT/dev"
for spec in "sdb 8 16" "hdb 3 68" "vdb 252 16" "sda2 8 2"; do
  # shellcheck disable=SC2086
  set -- $spec
  node="$ROOTFS_MOUNT/dev/$1"
  [ -b "$node" ] || sudo mknod "$node" b "$2" "$3"
  sudo chmod 600 "$node"
done
truncate -s 32M "$OPT_IMAGE"; mkfs.ext4 -F -O ^metadata_csum,^64bit "$OPT_IMAGE" >/dev/null
timeout 30s sudo mount -o loop "$OPT_IMAGE" "$OPT_MOUNT"; sudo mkdir -p "$OPT_MOUNT/bin"; sudo install -m 755 "$TARGET" "$OPT_MOUNT/bin/d2kd_parser_test"
cat > "$WORK/init.go" <<'EOF'
package main

import (
    "fmt"
    "os"
    "os/exec"
    "syscall"
    "time"
)

func poweroff() {
    syscall.Sync()
    _ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
}

func main() {
    if err := os.MkdirAll("/dev", 0755); err != nil { fmt.Printf("GATE4: mkdir /dev err=%v\n", err); poweroff(); return }
    if err := syscall.Mount("devtmpfs", "/dev", "devtmpfs", 0, ""); err != nil { fmt.Printf("GATE4: devtmpfs mount err=%v\n", err) }
    _ = syscall.Mount("proc", "/proc", "proc", 0, "")
    _ = syscall.Mount("sysfs", "/sys", "sysfs", 0, "")
    _ = os.MkdirAll("/opt", 0755)

    for i := 0; i < 40; i++ {
        if st, err := os.Stat("/dev/sdb"); err == nil && st.Mode()&os.ModeDevice != 0 {
            break
        }
        time.Sleep(250 * time.Millisecond)
    }

    if st, err := os.Stat("/dev/sdb"); err != nil || st.Mode()&os.ModeDevice == 0 || st.Mode()&os.ModeCharDevice != 0 {
        _ = syscall.Mknod("/dev/sdb", syscall.S_IFBLK|0600, int((uint32(8)<<8)|uint32(16)))
    }
    for _, spec := range []struct{name string; major int; minor int}{
        {"sdb", 8, 16}, {"hdb", 3, 68}, {"vdb", 252, 16}, {"sda2", 8, 2},
    } {
        path := "/dev/" + spec.name
        st, statErr := os.Stat(path)
        if statErr == nil && st.Mode()&os.ModeDevice != 0 && st.Mode()&os.ModeCharDevice == 0 {
            continue
        }
        mErr := syscall.Mknod(path, syscall.S_IFBLK|0600, int((uint32(spec.major)<<8)|uint32(spec.minor)))
        fmt.Printf("GATE4: mknod %s err=%v\n", path, mErr)
    }
    st, err := os.Stat("/dev/sdb")
    fmt.Printf("GATE4: disk candidate=/dev/sdb exists=%t block=%t err=%v\n", err == nil, err == nil && st.Mode()&os.ModeDevice != 0 && st.Mode()&os.ModeCharDevice == 0, err)
    if err != nil || st.Mode()&os.ModeDevice == 0 || st.Mode()&os.ModeCharDevice != 0 {
        fmt.Println("GATE4_RESULT=FAIL opt device")
        poweroff()
        return
    }

    if err := syscall.Mount("/dev/sdb", "/opt", "ext4", 0, ""); err != nil {
        fmt.Printf("GATE4_RESULT=FAIL mount=%v\n", err)
        poweroff()
        return
    }

    cmd := exec.Command("/opt/bin/d2kd_parser_test")
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr
    if err := cmd.Run(); err != nil {
        fmt.Printf("GATE4_RESULT=FAIL parser=%v\n", err)
        poweroff()
        return
    }

    fmt.Println("GATE4_RESULT=SUCCESS")
    poweroff()
}
EOF
GOOS=linux GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0 go build -o "$WORK/init" "$WORK/init.go"
sudo install -m 755 "$WORK/init" "$ROOTFS_MOUNT/gate4-init"
timeout 30s sudo umount "$ROOTFS_MOUNT"; timeout 30s sudo umount "$OPT_MOUNT"
rm -f "$LOG_OUT"; set +e
script -qefc "qemu-system-mipsel -M malta -cpu 24Kc -m 128M -kernel \"$KERNEL_BIN\" -drive file=\"$ROOTFS_IMAGE\",format=raw,if=ide,index=0 -drive file=\"$OPT_IMAGE\",format=raw,if=ide,index=1 -append \"root=/dev/sda rw console=ttyS0 init=/gate4-init\" -nographic -vga none -no-reboot -global driver=pcnet,property=romfile,value="" -net none" "$LOG_OUT" &
QEMU_PID=$!; set -e
for _ in $(seq 1 180); do grep -q 'GATE4_RESULT=' "$LOG_OUT" 2>/dev/null && break; kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 1; done
wait "$QEMU_PID" || true
cat "$LOG_OUT"
grep -q 'GATE4_RESULT=SUCCESS' "$LOG_OUT"
echo 'GATE4: PASS QEMU parser test'
