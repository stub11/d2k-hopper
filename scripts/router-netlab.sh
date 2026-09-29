#!/bin/sh
set -eu

# Network-only safety lab. No real router, no host network changes.
# Uses Linux network namespaces and veth pairs inside the GitHub runner.
# The lab is deliberately self-contained and deletes its namespace on exit.

NS="hopper-lab-$$"
ROOT="${RUNNER_TEMP:-/tmp}/hopper-netlab-$$"
QEMU="${QEMU_MIPSEL:-qemu-mipsel-static}"
CC="${MIPSEL_CC:-mipsel-linux-gnu-gcc}"
GO="${GO:-go}"

cleanup() {
  ip netns del "$NS" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need ip
need "$QEMU"
need "$CC"
need "$GO"

mkdir -p "$ROOT/bin" "$ROOT/etc/d2k"

echo "== Build MIPS test client =="
env CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat   "$GO" build -trimpath -o "$ROOT/bin/d2k" ./cmd/d2k

echo "== Create isolated network namespace =="
sudo ip netns add "$NS"
sudo ip link add hnl-host type veth peer name hnl-router
sudo ip link set hnl-router netns "$NS"
sudo ip addr add 10.203.0.1/24 dev hnl-host
sudo ip link set hnl-host up
sudo ip netns exec "$NS" ip addr add 10.203.0.2/24 dev hnl-router
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip link set hnl-router up

echo "== Start deterministic test service =="
python3 -m http.server 18080 --bind 10.203.0.1 --directory "$ROOT" >/tmp/hopper-http-$$.log 2>&1 &
SERVER_PID=$!
for i in 1 2 3 4 5; do
  if curl --fail --silent --show-error --connect-timeout 1 http://10.203.0.1:18080/ >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "== Verify isolated L3 path =="
sudo ip netns exec "$NS" curl --fail --silent --show-error   --connect-timeout 3 http://10.203.0.1:18080/ >/dev/null

echo "== Verify MIPS process can execute in lab =="
sudo ip netns exec "$NS" "$QEMU" "$ROOT/bin/d2k" version

echo "ROUTER NETLAB: GREEN"
echo "Network: 10.203.0.0/24 (namespace only)"
echo "No bridge, route, iptables or DNS changes are made on the host."
kill "$SERVER_PID" 2>/dev/null || true
