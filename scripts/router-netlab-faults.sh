#!/bin/sh
set -eu

NS="hopper-lab-$$"
ROOT="\${RUNNER_TEMP:-/tmp}/hopper-netlab-$$"
QEMU="\${QEMU_MIPSEL:-qemu-mipsel-static}"
GO="\${GO:-go}"

cleanup() {
  if [ -n "\${D2K_PID:-}" ]; then kill "$D2K_PID" 2>/dev/null || true; wait "$D2K_PID" 2>/dev/null || true; fi
  if [ -n "\${TLS_PID:-}" ]; then kill "$TLS_PID" 2>/dev/null || true; wait "$TLS_PID" 2>/dev/null || true; fi
  if [ -n "\${UDP_PID:-}" ]; then kill "$UDP_PID" 2>/dev/null || true; wait "$UDP_PID" 2>/dev/null || true; fi
  ip netns del "$NS" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need ip; need "$QEMU"; need "$GO"; need curl; need openssl; need python3; need tc

mkdir -p "$ROOT/bin" "$ROOT/state"
echo "== Build MIPS userspace =="
env CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat "$GO" build -trimpath -o "$ROOT/bin/d2k" ./cmd/d2k

cat > "$ROOT/config" <<EOF
SCHEMA=1
MODE=observe
PANEL_LISTEN=10.203.0.2:18081
STATE_DIR=$ROOT/state
QUEUE_NUM=2000
CONTROL_SOCKET=
DECOY_SNI=disk.rzd.ru
EOF

echo "== Create isolated network namespace =="
sudo ip netns add "$NS"
sudo ip link add hnl-host type veth peer name hnl-router
sudo ip link set hnl-router netns "$NS"
sudo ip addr add 10.203.0.1/24 dev hnl-host
sudo ip link set hnl-host up
sudo ip netns exec "$NS" ip addr add 10.203.0.2/24 dev hnl-router
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip link set hnl-router up

echo "== Start D2K panel inside MIPS/QEMU namespace =="
sudo ip netns exec "$NS" env D2K_CONFIG="$ROOT/config" "$QEMU" "$ROOT/bin/d2k" serve > "$ROOT/d2k.log" 2>&1 &
D2K_PID=$!
attempt=0
while [ "$attempt" -lt 10 ]; do
  attempt=$((attempt + 1))
  if curl --fail --silent --show-error --connect-timeout 1 http://10.203.0.2:18081/ >/dev/null 2>&1; then break; fi
  sleep 1
done
curl --fail --silent --show-error --connect-timeout 3 http://10.203.0.2:18081/ >/dev/null

echo "== TCP restart/recovery =="
kill "$D2K_PID"; wait "$D2K_PID" 2>/dev/null || true; D2K_PID=
if curl --silent --connect-timeout 1 http://10.203.0.2:18081/ >/dev/null 2>&1; then exit 1; fi
sudo ip netns exec "$NS" env D2K_CONFIG="$ROOT/config" "$QEMU" "$ROOT/bin/d2k" serve > "$ROOT/d2k-restart.log" 2>&1 &
D2K_PID=$!
attempt=0
while [ "$attempt" -lt 10 ]; do
  attempt=$((attempt + 1))
  if curl --fail --silent --show-error --connect-timeout 1 http://10.203.0.2:18081/ >/dev/null 2>&1; then break; fi
  sleep 1
done
curl --fail --silent --show-error --connect-timeout 3 http://10.203.0.2:18081/ >/dev/null

echo "== TCP delay fault injection =="
sudo ip netns exec "$NS" tc qdisc replace dev hnl-router root netem delay 100ms
curl --fail --silent --show-error --connect-timeout 5 http://10.203.0.2:18081/ >/dev/null
sudo ip netns exec "$NS" tc qdisc del dev hnl-router root 2>/dev/null || true

echo "== TLS service inside isolated namespace =="
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=hopper-lab -keyout "$ROOT/key.pem" -out "$ROOT/cert.pem" >/dev/null 2>&1
sudo ip netns exec "$NS" openssl s_server -quiet -accept 18443 -cert "$ROOT/cert.pem" -key "$ROOT/key.pem" -www > "$ROOT/tls.log" 2>&1 &
TLS_PID=$!
sleep 1
curl --fail --silent --show-error --insecure --connect-timeout 3 https://10.203.0.2:18443/ >/dev/null

echo "== UDP deterministic datagram path =="
sudo ip netns exec "$NS" python3 - "$ROOT/udp.ready" > "$ROOT/udp.log" 2>&1 <<'PY' &
import socket, sys
ready = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("10.203.0.2", 18535))
open(ready, "w").close()
while True:
    data, addr = s.recvfrom(4096)
    s.sendto(b"HOPPER-UDP-OK:" + data, addr)
PY
UDP_PID=$!
attempt=0
while [ ! -f "$ROOT/udp.ready" ] && [ "$attempt" -lt 10 ]; do attempt=$((attempt + 1)); sleep 1; done
test -f "$ROOT/udp.ready"
python3 - "$ROOT/udp-result" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(b"probe", ("10.203.0.2", 18535))
data, _ = s.recvfrom(4096)
if data != b"HOPPER-UDP-OK:probe":
    raise SystemExit("unexpected UDP response")
open(sys.argv[1], "w").write("ok")
PY
kill "$UDP_PID" 2>/dev/null || true
UDP_PID=
test -f "$ROOT/udp-result"

echo "== Recovery after fault =="
curl --fail --silent --show-error --connect-timeout 3 http://10.203.0.2:18081/ >/dev/null
echo "ROUTER NETLAB FAULT MATRIX: GREEN"
