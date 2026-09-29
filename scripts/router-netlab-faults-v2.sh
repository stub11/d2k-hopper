#!/bin/sh
set -eu
NS="hopper-lab-v2-$$"
ROOT="${RUNNER_TEMP:-/tmp}/hopper-netlab-v2-$$"
QEMU="${QEMU_MIPSEL:-qemu-mipsel-static}"
GO="${GO:-go}"
D2K_PID=""
DNS_PID=""
cleanup() {
  if [ -n "${D2K_PID:-}" ]; then kill "$D2K_PID" 2>/dev/null || true; wait "$D2K_PID" 2>/dev/null || true; fi
  if [ -n "${DNS_PID:-}" ]; then kill "$DNS_PID" 2>/dev/null || true; wait "$DNS_PID" 2>/dev/null || true; fi
  ip netns del "$NS" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need ip; need "$QEMU"; need "$GO"; need curl; need python3; need tc

mkdir -p "$ROOT/bin" "$ROOT/state"
env CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat "$GO" build -trimpath -o "$ROOT/bin/d2k" ./cmd/d2k
cat > "$ROOT/config" <<EOF
SCHEMA=1
MODE=observe
PANEL_LISTEN=10.204.0.2:18081
STATE_DIR=$ROOT/state
QUEUE_NUM=2000
CONTROL_SOCKET=
DECOY_SNI=disk.rzd.ru
EOF

sudo ip netns add "$NS"
sudo ip link add hnl2-host type veth peer name hnl2-router
sudo ip link set hnl2-router netns "$NS"
sudo ip addr add 10.204.0.1/24 dev hnl2-host
sudo ip link set hnl2-host up
sudo ip netns exec "$NS" ip addr add 10.204.0.2/24 dev hnl2-router
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip link set hnl2-router up

echo "== MIPS/QEMU D2K TCP baseline =="
sudo ip netns exec "$NS" env D2K_CONFIG="$ROOT/config" "$QEMU" "$ROOT/bin/d2k" serve >"$ROOT/d2k.log" 2>&1 &
D2K_PID=$!
attempt=0
while [ "$attempt" -lt 10 ]; do
  attempt=$((attempt + 1))
  if curl --fail --silent --connect-timeout 1 http://10.204.0.2:18081/ >/dev/null 2>&1; then break; fi
  sleep 1
done
curl --fail --silent --show-error --connect-timeout 3 http://10.204.0.2:18081/ >/dev/null

echo "== DNS packet encode/decode validation =="
python3 - <<'PY'
import struct
name=b"\x07hopper\x04test\x00"
tid=0x1234
query=struct.pack("!HHHHHH",tid,0x0100,1,0,0,0)+name+struct.pack("!HH",1,1)
answer=b"\xc0\x0c"+struct.pack("!HHIH",1,1,60,4)+bytes((10,204,0,2))
response=struct.pack("!HHHHHH",tid,0x8180,1,1,0,0)+name+struct.pack("!HH",1,1)+answer
if response[:2] != query[:2]: raise SystemExit("DNS transaction id mismatch")
if (response[2] & 0x80) == 0: raise SystemExit("DNS response flag missing")
if response[3] & 0x0f: raise SystemExit("DNS error response")
if struct.unpack("!H", response[4:6])[0] != 1: raise SystemExit("DNS question count invalid")
if struct.unpack("!H", response[6:8])[0] != 1: raise SystemExit("DNS answer count invalid")
if response[-4:] != bytes((10,204,0,2)): raise SystemExit("DNS address mismatch")
PY

echo "== Deterministic packet-loss failure and recovery =="
sudo ip netns exec "$NS" tc qdisc replace dev hnl2-router root netem loss 100%
if curl --silent --connect-timeout 2 http://10.204.0.2:18081/ >/dev/null 2>&1; then
  echo "100% loss unexpectedly allowed TCP request" >&2
  exit 1
fi
sudo ip netns exec "$NS" tc qdisc del dev hnl2-router root
curl --fail --silent --show-error --connect-timeout 3 http://10.204.0.2:18081/ >/dev/null

echo "== Reordering/delay profile =="
sudo ip netns exec "$NS" tc qdisc replace dev hnl2-router root netem delay 40ms 20ms distribution normal reorder 50% 50%
curl --fail --silent --show-error --connect-timeout 5 http://10.204.0.2:18081/ >/dev/null
sudo ip netns exec "$NS" tc qdisc del dev hnl2-router root

echo "== Service disappearance / TCP connection failure =="
kill "$D2K_PID"; wait "$D2K_PID" 2>/dev/null || true; D2K_PID=
if curl --silent --connect-timeout 2 http://10.204.0.2:18081/ >/dev/null 2>&1; then
  echo "service remained reachable after termination" >&2
  exit 1
fi

echo "== Final restart/recovery =="
sudo ip netns exec "$NS" env D2K_CONFIG="$ROOT/config" "$QEMU" "$ROOT/bin/d2k" serve >"$ROOT/d2k-final.log" 2>&1 &
D2K_PID=$!
attempt=0
while [ "$attempt" -lt 10 ]; do
  attempt=$((attempt + 1))
  if curl --fail --silent --connect-timeout 1 http://10.204.0.2:18081/ >/dev/null 2>&1; then break; fi
  sleep 1
done
curl --fail --silent --show-error --connect-timeout 3 http://10.204.0.2:18081/ >/dev/null
echo "ROUTER NETLAB V2 FAULT MATRIX: GREEN"
