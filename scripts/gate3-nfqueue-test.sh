#!/bin/sh
# Gate 3: real C d2kd on Debian Malta, NFQUEUE in the IPv4 FORWARD path.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK="${RUNNER_TEMP:-/tmp}/d2k-gate3-$$"
ASSET_DIR="${GATE3_ASSET_DIR:-$HOME/.cache/d2k-gate3}"
ROOTFS_TAR="$ASSET_DIR/debian-buster-mipsel.tar.xz"
KERNEL_BIN="$ASSET_DIR/vmlinux-3.2.0-4-4kc-malta"
ROOTFS_IMAGE="$WORK/debian-rootfs.ext4"
OPT_IMAGE="$WORK/hopper-opt.ext4"
ROOTFS_MOUNT="$WORK/rootfs"
OPT_MOUNT="$WORK/opt"
LOG_OUT="$ROOT/qemu-gate3-serial.log"
D2KD_BIN="$ROOT/dist/mips-d2kd/d2kd"
ROOTFS_BASE="https://people.debian.org/~jcowgill/qemu-mips"
KERNEL_BASE="https://people.debian.org/~aurel32/qemu/mipsel"
TAP="d2k-g3-tap"
BR="d2k-g3-br"
NS="d2k-g3-http"

cleanup() {
  set +e
  [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true
  timeout 10s sudo ip netns del "$NS" 2>/dev/null || true
  timeout 10s sudo ip link del "$BR" 2>/dev/null || true
  timeout 10s sudo ip link del "$TAP" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
for x in curl tar truncate mkfs.ext4 mount timeout qemu-system-mipsel readelf go ip curl grep; do need "$x"; done
[ -x "$D2KD_BIN" ] || { echo "missing real C binary: $D2KD_BIN" >&2; exit 1; }

mkdir -p "$WORK" "$ASSET_DIR" "$ROOTFS_MOUNT" "$OPT_MOUNT"

echo "[STEP] Download Debian Malta assets..."
[ -s "$ROOTFS_TAR" ] || curl -fsSL --connect-timeout 10 --max-time 60 -o "$ROOTFS_TAR" "$ROOTFS_BASE/debian-buster-mipsel.tar.xz"
[ -s "$KERNEL_BIN" ] || curl -fsSL --connect-timeout 10 --max-time 60 -o "$KERNEL_BIN" "$KERNEL_BASE/vmlinux-3.2.0-4-4kc-malta"

echo "[STEP] Prepare rootfs..."
truncate -s 1G "$ROOTFS_IMAGE"
mkfs.ext4 -F -O ^metadata_csum,^64bit -L D2KROOT "$ROOTFS_IMAGE" >/dev/null
timeout 30s sudo mount -o loop "$ROOTFS_IMAGE" "$ROOTFS_MOUNT"
sudo tar -xJpf "$ROOTFS_TAR" -C "$ROOTFS_MOUNT"
sudo mkdir -p "$ROOTFS_MOUNT/dev"
for spec in "sdb 8 16" "hdb 3 68" "vdb 252 16" "sda2 8 2"; do
  read -r name major minor <<EOF
$spec
EOF
  node="$ROOTFS_MOUNT/dev/$name"
  [ -b "$node" ] || sudo mknod "$node" b "$major" "$minor"
  sudo chmod 600 "$node"
done

echo "[STEP] Prepare /opt image with real d2kd..."
truncate -s 128M "$OPT_IMAGE"
mkfs.ext4 -F -O ^metadata_csum,^64bit -L HOPPEROPT "$OPT_IMAGE" >/dev/null
timeout 30s sudo mount -o loop "$OPT_IMAGE" "$OPT_MOUNT"
sudo mkdir -p "$OPT_MOUNT/bin"
sudo install -m 755 "$D2KD_BIN" "$OPT_MOUNT/bin/d2kd"
sudo sh -c 'printf "%s\n" "#!/bin/sh" "echo Gate3 d2kd real C binary" "/opt/bin/d2kd --help" > "$1" && chmod 755 "$1"' sh "$OPT_MOUNT/bin/verify-d2kd.sh"

echo "[STEP] Build MIPS static Gate 3 init..."
cat > "$WORK/gate3-init.go" <<'EOF'
package main

import (
  "fmt"
  "os"
  "os/exec"
  "strings"
  "syscall"
  "time"
)

func run(name string, args ...string) bool {
  cmd := exec.Command(name, args...)
  out, err := cmd.CombinedOutput()
  fmt.Printf("GATE3: %s %s\n%s", name, strings.Join(args, " "), out)
  return err == nil
}

func must(name string, args ...string) {
  if !run(name, args...) {
    fmt.Printf("GATE3_RESULT=FAIL command=%s\n", name)
    syscall.Sync()
    syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
    os.Exit(1)
  }
}

func stop(ok bool) {
  if ok { fmt.Println("GATE3_RESULT=SUCCESS") } else { fmt.Println("GATE3_RESULT=FAIL") }
  syscall.Sync()
  _ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
  os.Exit(0)
}

func main() {
  fmt.Println("GATE3: static init")
  _ = syscall.Mount("devtmpfs", "/dev", "devtmpfs", 0, "")
  _ = os.MkdirAll("/opt", 0755)

  opt := ""
  for i := 0; i < 15; i++ {
    for _, dev := range []string{"/dev/sdb", "/dev/hdb", "/dev/vdb", "/dev/sda2"} {
      if st, err := os.Stat(dev); err == nil && st.Mode()&os.ModeDevice != 0 {
        opt = dev
        break
      }
    }
    if opt != "" { break }
    time.Sleep(1 * time.Second)
  }
  fmt.Printf("GATE3: opt device=%q\n", opt)
  if opt == "" { stop(false) }
  if err := syscall.Mount(opt, "/opt", "ext4", 0, ""); err != nil {
    fmt.Printf("GATE3: mount /opt: %v\n", err); stop(false)
  }

  // Debian buster is archived; use the Debian archive while the VM has its
  // temporary QEMU user-network interface. This installs only the iptables
  // userspace required by the gate.
  _ = os.MkdirAll("/etc/apt/sources.list.d", 0755)
  os.WriteFile("/etc/apt/sources.list", []byte(
    "deb [check-valid-until=no] http://archive.debian.org/debian buster main\n"+
    "deb [check-valid-until=no] http://archive.debian.org/debian buster-updates main\n"), 0644)
  must("apt-get", "-o", "Acquire::Check-Valid-Until=false", "update")
  must("apt-get", "-y", "-o", "Acquire::Check-Valid-Until=false", "install", "iptables")

  must("ip", "addr", "add", "10.20.0.1/24", "dev", "eth1")
  must("ip", "link", "set", "eth1", "up")
  must("sysctl", "-w", "net.ipv4.ip_forward=1")

  // QEMU user networking sends host:18080 to guest:10.0.2.15:18080.
  // DNAT makes that traffic a real FORWARD path to the HTTP namespace.
  must("iptables", "-t", "nat", "-A", "PREROUTING", "-p", "tcp",
       "--dport", "18080", "-j", "DNAT", "--to-destination", "10.20.0.2:80")
  must("iptables", "-A", "FORWARD", "-p", "tcp", "--dport", "80",
       "-j", "NFQUEUE", "--queue-num", "0", "--queue-bypass")
  must("iptables", "-A", "FORWARD", "-p", "tcp", "--sport", "80",
       "-j", "ACCEPT")
  must("iptables", "-A", "FORWARD", "-p", "tcp", "--dport", "80",
       "-j", "ACCEPT")

  fmt.Println("GATE3: iptables FORWARD NFQUEUE queue=0 bypass=1 installed")
  fmt.Println("GATE3: launching real /opt/bin/d2kd --mode observe --queue 0")
  d := exec.Command("/opt/bin/d2kd", "--mode", "observe", "--queue", "0",
                   "--queue-len", "1024", "--copy-range", "1600",
                   "--stats", "1", "--duration", "30")
  d.Stdout = os.Stdout
  d.Stderr = os.Stderr
  if err := d.Start(); err != nil {
    fmt.Printf("GATE3: d2kd start: %v\n", err); stop(false)
  }
  fmt.Printf("GATE3: d2kd pid=%d\n", d.Process.Pid)
  fmt.Println("GATE3_READY")
  err := d.Wait()
  fmt.Printf("GATE3: d2kd exited: %v\n", err)

  // The NFQUEUE rule remains installed. With --queue-bypass, a new packet
  // must traverse the rule without a userspace listener.
  fmt.Println("GATE3_D2KD_STOPPED")
  fmt.Println("GATE3: queue-bypass rule remains installed")
  must("iptables", "-t", "nat", "-L", "PREROUTING", "-n")
  must("iptables", "-L", "FORWARD", "-n", "-v")
  if out, e := exec.Command("dmesg").CombinedOutput(); e == nil {
    fmt.Printf("GATE3_DMESG_BEGIN\n%sGATE3_DMESG_END\n", out)
  }
  stop(err == nil)
}
EOF

GOOS=linux GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0 go build -o "$WORK/gate3-init" "$WORK/gate3-init.go"
readelf -h "$WORK/gate3-init" | grep -E 'Class:|Data:|Machine:'
sudo install -m 755 "$WORK/gate3-init" "$ROOTFS_MOUNT/gate3-init"

timeout 30s sudo umount "$ROOTFS_MOUNT"
timeout 30s sudo umount "$OPT_MOUNT"

echo "[STEP] Create isolated HTTP server namespace..."
sudo ip netns add "$NS"
sudo ip link add "$BR" type bridge
sudo ip link set "$BR" up
sudo ip tuntap add dev "$TAP" mode tap user="$(id -u)"
sudo ip link set "$TAP" master "$BR"
sudo ip link set "$TAP" up
sudo ip link add g3veth type veth peer name g3srv
sudo ip link set g3veth master "$BR"
sudo ip link set g3veth up
sudo ip link set g3srv netns "$NS"
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip link set g3srv up
sudo ip netns exec "$NS" ip addr add 10.20.0.2/24 dev g3srv
sudo ip netns exec "$NS" ip route add default via 10.20.0.1
sudo ip netns exec "$NS" python3 -m http.server 80 --bind 10.20.0.2 >"$WORK/http-server.log" 2>&1 &
HTTP_PID=$!

echo "[STEP] Launch QEMU two-NIC gateway..."
rm -f "$LOG_OUT"
set +e
qemu-system-mipsel \
  -M malta -cpu 4Kc -m 192M \
  -kernel "$KERNEL_BIN" \
  -drive file="$ROOTFS_IMAGE",format=raw,if=ide,index=0 \
  -drive file="$OPT_IMAGE",format=raw,if=ide,index=1 \
  -append "root=/dev/sda rw console=ttyS0 init=/gate3-init" \
  -netdev user,id=wan,hostfwd=tcp:127.0.0.1:18080-10.0.2.15:18080 \
  -device pcnet,netdev=wan \
  -netdev tap,id=lan,ifname="$TAP",script=no,downscript=no \
  -device pcnet,netdev=lan \
  -nographic -no-reboot >"$LOG_OUT" 2>&1 &
QEMU_PID=$!
set -e

echo "[STEP] Wait for GATE3_READY..."
ready=0
for _ in $(seq 1 180); do
  if grep -q '^GATE3_READY$' "$LOG_OUT" 2>/dev/null; then ready=1; break; fi
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { cat "$LOG_OUT"; echo "Gate 3 VM did not become ready" >&2; exit 1; }

echo "[STEP] 20 HTTP requests through QEMU MIPS gateway..."
ok=0
for i in $(seq 1 20); do
  code=$(curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/ || true)
  echo "HTTP[$i]=$code"
  [ "$code" = "200" ] && ok=$((ok+1))
done
[ "$ok" -eq 20 ] || { echo "HTTP success count $ok/20" >&2; cat "$LOG_OUT"; exit 1; }

echo "[STEP] Wait for d2kd to stop, leaving NFQUEUE rule in place..."
stopped=0
for _ in $(seq 1 60); do
  if grep -q '^GATE3_D2KD_STOPPED$' "$LOG_OUT" 2>/dev/null; then stopped=1; break; fi
  sleep 1
done
[ "$stopped" -eq 1 ] || { cat "$LOG_OUT"; echo "d2kd did not stop" >&2; exit 1; }

echo "[STEP] queue-bypass check: NEW HTTP request after d2kd exit..."
bypass_code=$(curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/ || true)
echo "HTTP_BYPASS=$bypass_code"
[ "$bypass_code" = "200" ] || { cat "$LOG_OUT"; echo "queue-bypass request failed" >&2; exit 1; }

wait "$QEMU_PID" || true
QEMU_RC=$?

echo "[STEP] Analyze Gate 3 evidence..."
cat "$LOG_OUT"

grep -q 'GATE3_RESULT=SUCCESS' "$LOG_OUT" || { echo "GATE3_RESULT missing/failure" >&2; exit 1; }
grep -q 'GATE3_D2KD_STOPPED' "$LOG_OUT" || { echo "d2kd stop marker missing" >&2; exit 1; }

# Hard counters: the final d2kd summary must show seen > 0, accepted == seen,
# and zero verdict/send/receive errors and zero drops.
python3 - "$LOG_OUT" <<'PY'
import re, sys
text=open(sys.argv[1], encoding='utf-8', errors='replace').read()
m=re.findall(r'пакетов (\d+), байт \d+, пропущено (\d+), снято (\d+)', text)
e=re.findall(r'потеряно ядром (\d+), ошибок вердикта (\d+), ошибок отправки (\d+), ошибок чтения (\d+)', text)
if not m or not e:
    raise SystemExit("missing d2kd final counters")
seen, accepted, dropped = map(int, m[-1])
lost, verdict_fail, send_fail, recv_err = map(int, e[-1])
print(f"GATE3_COUNTERS seen={seen} accepted={accepted} dropped={dropped} verdict_fail={verdict_fail} send_fail={send_fail} recv_err={recv_err} lost={lost}")
if not (seen > 0 and accepted == seen and dropped == 0 and verdict_fail == 0 and send_fail == 0 and recv_err == 0 and lost == 0):
    raise SystemExit("Gate 3 counter criteria failed")
PY

grep -Eiq 'kernel panic|nf_queue.*full|oom-killer|out of memory|killed process' "$LOG_OUT" && {
  echo "Gate 3 forbidden kernel fault signature found" >&2
  exit 1
} || true

echo "GATE3: PASS HTTP=20/20 bypass=200 QEMU_RC=$QEMU_RC"
