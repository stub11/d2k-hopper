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

echo "== DNS protocol round-trip =="
sudo ip netns exec "$NS" python3 - "$ROOT/dns.ready" >"$ROOT/dns.log" 2>&1 <<'PY' &
import socket,struct,sys
ready=sys.argv[1]
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind(("10.204.0.2",15353))
open(ready,"w").close()
while True:
    q,addr=s.recvfrom(4096)
    if len(q)<12: continue
    tid=q[:2]
    flags=struct.pack("!H",0x8180)
    counts=struct.pack("!HHHH",1,1,0,0)
    pos=12
    while pos<len(q) and q[pos]:
        pos += 1+q[pos]
    if pos+5>len(q): continue
    question=q[12:pos+5]
    answer=b"\xc0\x0c"+struct.pack("!HHIH",1,1,60,4)+socket.inet_aton("10.204.0.2")
    s.sendto(tid+flags+counts+question+answer,addr)
PY
DNS_PID=$!
attempt=0
while [ ! -f "$ROOT/dns.ready" ] && [ "$attempt" -lt 10 ]; do attempt=$((attempt + 1)); sleep 1; done
test -f "$ROOT/dns.ready"
sudo ip netns exec "$NS" ip addr show hnl2-router
sudo ip netns exec "$NS" ss -lun || true
python3 - "$ROOT/dns.ok" <<'PY'
import socket,struct,sys
name=b"\x07hopper\x04test\x00"
q=struct.pack("!HHHHHH",0x1234,0x0100,1,0,0,0)+name+struct.pack("!HH",1,1)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(q,("10.204.0.2",15353)); r,_=s.recvfrom(4096)
if r[:2]!=b"\x12\x34" or len(r)<12 or r[3]&0x0f != 0: raise SystemExit("DNS response invalid")
open(sys.argv[1],"w").write("ok")
PY
test -f "$ROOT/dns.ok"

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
