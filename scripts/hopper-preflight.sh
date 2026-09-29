#!/bin/sh
set -eu
usage() { echo "Usage: hopper-preflight.sh [--strict] [--help]"; }
strict=0
case "\${1:-}" in
  --strict) strict=1 ;;
  --help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
fail=0
warn=0
check_cmd() {
  if command -v "\$1" >/dev/null 2>&1; then
    echo "OK command \$1=\$(command -v "\$1")"
  else
    echo "FAIL command \$1"
    fail=\$((fail + 1))
  fi
}
check_optional() {
  if command -v "\$1" >/dev/null 2>&1; then
    echo "OK optional \$1"
  else
    echo "WARN optional \$1"
    warn=\$((warn + 1))
  fi
}
for t in uname opkg ip iptables ipset openssl; do check_cmd "\$t"; done
for t in ip6tables start-stop-daemon; do check_optional "\$t"; done
arch=\$(uname -m 2>/dev/null || echo unknown)
echo "INFO arch=\$arch"
model=unknown
if command -v ndmc >/dev/null 2>&1; then
  model=\$(ndmc -c "show version" 2>/dev/null | awk -F": " '/model:/{print \$2; exit}' || true)
  [ -n "\$model" ] || model=unknown
fi
echo "INFO model=\$model"
ram_kb=0
if [ -r /proc/meminfo ]; then ram_kb=\$(awk '/^MemTotal:/{print \$2; exit}' /proc/meminfo); fi
case "\$ram_kb" in ''|*[!0-9]*) ram_kb=0;; esac
echo "INFO ram_mb=\$((ram_kb / 1024))"
if [ -r /proc/net/netfilter/nfnetlink_queue ]; then echo "OK nfnetlink_queue"; else echo "FAIL nfnetlink_queue"; fail=\$((fail + 1)); fi
if grep -qw NFQUEUE /proc/net/ip_tables_targets 2>/dev/null; then echo "OK iptables NFQUEUE"; else echo "FAIL iptables NFQUEUE"; fail=\$((fail + 1)); fi
if grep -qw connbytes /proc/net/ip_tables_matches 2>/dev/null; then echo "OK iptables connbytes"; else echo "FAIL iptables connbytes"; fail=\$((fail + 1)); fi
if command -v opkg >/dev/null 2>&1; then
  echo "INFO opkg architectures:"
  opkg print-architecture 2>/dev/null || { echo "FAIL opkg print-architecture"; fail=\$((fail + 1)); }
fi
if [ -d /opt ]; then echo "OK /opt"; else echo "FAIL /opt"; fail=\$((fail + 1)); fi
if [ -w /opt ] 2>/dev/null; then echo "OK /opt writable"; else echo "WARN /opt not writable"; warn=\$((warn + 1)); fi
if [ "\$strict" -eq 1 ] && [ "\$warn" -gt 0 ]; then fail=\$((fail + warn)); fi
if [ "\$fail" -gt 0 ]; then echo "PREFLIGHT: FAIL failures=\$fail warnings=\$warn"; exit 1; fi
echo "PREFLIGHT: GREEN failures=0 warnings=\$warn"
