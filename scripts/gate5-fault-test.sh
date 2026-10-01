#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/d2k-gate5.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

log() { printf '[gate5] %s\n' "$*"; }
fail() { printf '[gate5] FAIL: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"; }

need sh
need awk
need grep
need sed
need python3

log "static shell validation"
sh -n "$ROOT/scripts/rollback.sh"
sh -n "$ROOT/scripts/S99d2k"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$ROOT/scripts/rollback.sh" "$ROOT/scripts/S99d2k"
fi

# A deterministic d2kd stand-in is used only to test the supervisor contract.
# The actual d2kd binary is exercised by the normal build/CI jobs; this test
# isolates watchdog/rollback semantics from NFQUEUE privileges.
cat >"$TMP/d2kd-stub" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "$TMP/d2kd-stub"

export D2K_ROOT="$TMP/root"
export D2K_BIN="$TMP/d2kd-stub"
export D2K_PIDFILE="$TMP/root/var/run/d2kd.pid"
export D2K_WATCHDOG_PIDFILE="$TMP/root/var/run/d2kd-watchdog.pid"
export D2K_LOG="$TMP/root/var/log/d2kd.log"
export D2K_WATCHDOG_SEC=1
mkdir -p "$TMP/root/var/run" "$TMP/root/var/log"

log "Entware autostart + watchdog recovery"
"$ROOT/scripts/S99d2k" start
pid=$(cat "$D2K_PIDFILE")
kill -9 "$pid"
i=0
while :; do
    newpid=$(cat "$D2K_PIDFILE" 2>/dev/null || true)
    if [ -n "$newpid" ] && [ "$newpid" != "$pid" ] && kill -0 "$newpid" 2>/dev/null; then
        break
    fi
    i=$((i + 1))
    [ "$i" -lt 30 ] || fail "watchdog did not restart d2kd"
    sleep 0.2
done
"$ROOT/scripts/S99d2k" status >/dev/null
"$ROOT/scripts/S99d2k" stop

log "rollback removes D2K iptables chain and stops service"
FAKE_IPTABLES="$TMP/fake-iptables"
cat >"$FAKE_IPTABLES" <<'EOF'
#!/bin/sh
set -eu
state=${D2K_FAKE_IPTABLES_STATE:?}
cmd="$*"
printf '%s\n' "$cmd" >>"$state"
case "$cmd" in
  *" -D FORWARD -j D2K_HOPPER") exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_IPTABLES"
: >"$TMP/iptables.log"
export D2K_IPTABLES_BIN="$FAKE_IPTABLES"
export D2K_FAKE_IPTABLES_STATE="$TMP/iptables.log"
export D2K_PIDFILE="$TMP/rollback.pid"
"$TMP/d2kd-stub" &
echo $! >"$D2K_PIDFILE"
"$ROOT/scripts/rollback.sh"
grep -q -- '-F D2K_HOPPER' "$TMP/iptables.log"
grep -q -- '-X D2K_HOPPER' "$TMP/iptables.log"
[ ! -e "$D2K_PIDFILE" ]

log "fail-open HTTP continuity after d2kd SIGKILL"
python3 -m http.server 18080 --bind 127.0.0.1 --directory "$TMP" >"$TMP/http.log" 2>&1 &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT INT TERM
sleep 0.5
python3 - <<'PY'
import urllib.request
u='http://127.0.0.1:18080/d2kd-stub'
with urllib.request.urlopen(u, timeout=3) as r:
    assert r.status == 200
PY
"$TMP/d2kd-stub" &
KILL_PID=$!
kill -9 "$KILL_PID"
python3 - <<'PY'
import urllib.request
u='http://127.0.0.1:18080/d2kd-stub'
with urllib.request.urlopen(u, timeout=3) as r:
    assert r.status == 200
PY
kill "$HTTP_PID" 2>/dev/null || true

log "QEMU 128M resource lab"
QEMU=${QEMU_BIN:-qemu-system-x86_64}
KERNEL=${QEMU_KERNEL:-}
[ -n "$KERNEL" ] || KERNEL=$(ls /boot/vmlinuz-* 2>/dev/null | tail -1 || true)
if command -v "$QEMU" >/dev/null 2>&1 && [ -n "$KERNEL" ] && [ -f "$KERNEL" ] && command -v cpio >/dev/null 2>&1 && command -v busybox >/dev/null 2>&1; then
    G="$TMP/initramfs"
    mkdir -p "$G/bin" "$G/proc" "$G/sys" "$G/dev"
    cp "$(command -v busybox)" "$G/bin/busybox"
    ln -s busybox "$G/bin/sh"
    ln -s busybox "$G/bin/dmesg"
    ln -s busybox "$G/bin/grep"
    ln -s busybox "$G/bin/awk"
    cat >"$G/init" <<'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
echo GATE5-QEMU-BOOT
(
    i=0
    while [ "$i" -lt 20 ]; do
        dd if=/dev/zero of="/tmp/load-$i" bs=1M count=2 2>/dev/null || exit 2
        i=$((i + 1))
    done
    echo GATE5-QEMU-LOAD-OK
) &
pid=$!
wait "$pid" || { echo GATE5-QEMU-LOAD-FAIL; poweroff -f; exit 1; }
if dmesg | grep -Eiq 'out of memory|oom-killer|killed process|sigsegv|general protection'; then
    echo GATE5-QEMU-OOM-EVIDENCE
    poweroff -f
    exit 1
fi
echo GATE5-QEMU-NO-OOM
poweroff -f
EOF
    chmod +x "$G/init"
    (cd "$G" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1 >"$TMP/initramfs.gz")
    timeout 45 "$QEMU" -nographic -no-reboot -m 128M -kernel "$KERNEL"         -initrd "$TMP/initramfs.gz" -append 'console=ttyS0 rdinit=/init'         >"$TMP/qemu.log" 2>&1 || true
    grep -q 'GATE5-QEMU-BOOT' "$TMP/qemu.log"
    grep -q 'GATE5-QEMU-NO-OOM' "$TMP/qemu.log"
else
    fail "QEMU resource lab prerequisites missing (qemu-system-x86_64, kernel, cpio, busybox)"
fi

log "PASS: fault injection, watchdog/autostart, rollback and 128M QEMU resource checks"
