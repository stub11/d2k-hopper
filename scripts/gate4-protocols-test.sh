#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
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
cleanup(){ set +e; [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
for x in curl tar truncate mkfs.ext4 mount umount timeout qemu-system-mipsel readelf grep go script; do need "$x"; done
[ -x "$TARGET" ] || { echo "missing parser binary: $TARGET" >&2; exit 1; }
mkdir -p "$WORK" "$ASSET_DIR" "$ROOTFS_MOUNT" "$OPT_MOUNT"
[ -s "$ROOTFS_TAR" ] || curl -fsSL --connect-timeout 10 --max-time 60 -o "$ROOTFS_TAR" "$ROOTFS_BASE/debian-buster-mipsel.tar.xz"
[ -s "$KERNEL_BIN" ] || curl -fsSL --connect-timeout 10 --max-time 60 -o "$KERNEL_BIN" "$KERNEL_BASE/vmlinux-3.2.0-4-4kc-malta"
truncate -s 1G "$ROOTFS_IMAGE"; mkfs.ext4 -F -O ^metadata_csum,^64bit "$ROOTFS_IMAGE" >/dev/null
timeout 30s sudo mount -o loop "$ROOTFS_IMAGE" "$ROOTFS_MOUNT"; sudo tar -xJpf "$ROOTFS_TAR" -C "$ROOTFS_MOUNT"
truncate -s 32M "$OPT_IMAGE"; mkfs.ext4 -F -O ^metadata_csum,^64bit "$OPT_IMAGE" >/dev/null
timeout 30s sudo mount -o loop "$OPT_IMAGE" "$OPT_MOUNT"; sudo mkdir -p "$OPT_MOUNT/bin"; sudo install -m 755 "$TARGET" "$OPT_MOUNT/bin/d2kd_parser_test"
cat > "$WORK/init.go" <<'EOF'
package main
import ("fmt";"os";"os/exec";"syscall";"time")
func main(){
 _=syscall.Mount("devtmpfs","/dev","devtmpfs",0,""); _=syscall.Mount("proc","/proc","proc",0,""); _=syscall.Mount("sysfs","/sys","sysfs",0,""); _=os.MkdirAll("/opt",0755)
 for i:=0;i<40;i++{if st,e:=os.Stat("/dev/sdb");e==nil&&st.Mode()&os.ModeDevice!=0{break};time.Sleep(250*time.Millisecond)}
 st,e:=os.Stat("/dev/sdb");if e!=nil||st.Mode()&os.ModeDevice==0{fmt.Println("GATE4_RESULT=FAIL opt device");syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF);return}
 if e:=syscall.Mount("/dev/sdb","/opt","ext4",0,"");e!=nil{fmt.Printf("GATE4_RESULT=FAIL mount=%v\n",e);syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF);return}
 c:=exec.Command("/opt/bin/d2kd_parser_test");c.Stdout=os.Stdout;c.Stderr=os.Stderr;e=c.Run();if e!=nil{fmt.Printf("GATE4_RESULT=FAIL parser=%v\n",e)};syscall.Sync();syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
}
EOF
GOOS=linux GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0 go build -o "$WORK/init" "$WORK/init.go"
sudo install -m 755 "$WORK/init" "$ROOTFS_MOUNT/gate4-init"
timeout 30s sudo umount "$ROOTFS_MOUNT"; timeout 30s sudo umount "$OPT_MOUNT"
rm -f "$LOG_OUT"; set +e
script -qefc "qemu-system-mipsel -M malta -cpu 24Kc -m 128M -kernel \"$KERNEL_BIN\" -drive file=\"$ROOTFS_IMAGE\",format=raw,if=ide,index=0 -drive file=\"$OPT_IMAGE\",format=raw,if=ide,index=1 -append \"root=/dev/sda rw console=ttyS0 init=/gate4-init\" -nographic -vga none -no-reboot" "$LOG_OUT" &
QEMU_PID=$!; set -e
for _ in $(seq 1 180); do grep -q 'GATE4_RESULT=' "$LOG_OUT" 2>/dev/null && break; kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 1; done
wait "$QEMU_PID" || true
cat "$LOG_OUT"
grep -q 'GATE4_RESULT=SUCCESS' "$LOG_OUT"
echo 'GATE4: PASS QEMU parser test'
