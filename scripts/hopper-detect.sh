#!/bin/sh
# D2K — read-only Hopper profile detection
set -eu

usage() {
    cat <<'EOF'
Usage: hopper-detect.sh [--dry-run] [--help]

Read-only inspection of router model, architecture and RAM.
--dry-run is accepted for automation compatibility; this script never changes state.
EOF
}

case "${1:-}" in
    --help) usage; exit 0 ;;
    --dry-run|"") ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

command -v uname >/dev/null 2>&1 || { echo "uname is required" >&2; exit 1; }

model="unknown"
if command -v ndmc >/dev/null 2>&1; then
    detected=$(ndmc -c "show version" 2>/dev/null || true)
    model=$(printf '%s\n' "$detected" | awk -F': ' '/model:/{print $2; exit}')
    [ -n "$model" ] || model="unknown"
fi

arch=$(uname -m 2>/dev/null || echo unknown)
ram_kb=0
if [ -r /proc/meminfo ]; then
    ram_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
fi
case "$ram_kb" in
    ''|*[!0-9]*) ram_kb=0 ;;
esac

printf 'model=%s\narch=%s\nram_mb=%s\n' "$model" "$arch" "$((ram_kb / 1024))"
