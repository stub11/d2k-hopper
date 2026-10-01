#!/bin/sh
set -eu

IPTABLES_BIN=${D2K_IPTABLES_BIN:-iptables}
SERVICE=${D2K_SERVICE_NAME:-d2kd}
PIDFILE=${D2K_PIDFILE:-/var/run/d2kd.pid}
CHAIN=${D2K_IPTABLES_CHAIN:-D2K_HOPPER}
TABLES=${D2K_IPTABLES_TABLES:-filter mangle nat}

stop_pid() {
    pid="$1"
    case "$pid" in
        ''|*[!0-9]*) return 0 ;;
    esac
    kill "$pid" 2>/dev/null || true
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
}

if [ -r "$PIDFILE" ]; then
    stop_pid "$(cat "$PIDFILE" 2>/dev/null || true)"
    rm -f "$PIDFILE"
fi

if command -v service >/dev/null 2>&1; then
    service "$SERVICE" stop >/dev/null 2>&1 || true
fi

for table in $TABLES; do
    while "$IPTABLES_BIN" -t "$table" -D FORWARD -j "$CHAIN" >/dev/null 2>&1; do :; done
    "$IPTABLES_BIN" -t "$table" -F "$CHAIN" >/dev/null 2>&1 || true
    "$IPTABLES_BIN" -t "$table" -X "$CHAIN" >/dev/null 2>&1 || true
done

exit 0
