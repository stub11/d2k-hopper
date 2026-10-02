#!/bin/sh
# Root CI only. All firewall/network changes are in a unique disposable netns.
set -eu
ns="d2k-stateful-$$"
tmp=$(mktemp -d)
runner_pid=
cleanup() {
    if [ -n "$runner_pid" ]; then kill "$runner_pid" 2>/dev/null || true; fi
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
ip netns add "$ns"
ip -n "$ns" link set lo up
ip -n "$ns" addr add 192.0.2.1/32 dev lo
ip -n "$ns" addr add 192.0.2.2/32 dev lo
# Only marked synthetic packets enter the queue; automatic kernel RSTs do not.
ip netns exec "$ns" iptables -t mangle -A OUTPUT -m mark --mark 71 \
    -j NFQUEUE --queue-num 71 --queue-bypass
ip netns exec "$ns" ./datapath/nfqueue_libprobe 71 14 > "$tmp/events" 2> "$tmp/errors" &
runner_pid=$!
i=0
while ! grep -q '^ready$' "$tmp/events"; do
    if ! kill -0 "$runner_pid" 2>/dev/null || [ "$i" -ge 100 ]; then
        cat "$tmp/errors" >&2; exit 1
    fi
    i=$((i+1)); sleep 0.1
done
ip netns exec "$ns" python3 scripts/stateful-nfq-traffic.py send
if ! wait "$runner_pid"; then cat "$tmp/errors" >&2; exit 1; fi
runner_pid=
python3 scripts/stateful-nfq-traffic.py verify "$tmp/events"
