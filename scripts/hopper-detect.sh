#!/bin/sh
# D2K — Auto-detect Hopper 3810 and optimize RAM
set -e
ROUTER_MODEL=$(ndm system device model 2>/dev/null || echo "Hopper 3810")
ROUTER_ARCH=$(uname -m)
ROUTER_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "256000")
echo "=== D2K Hopper Profile: Model=$ROUTER_MODEL, Arch=$ROUTER_ARCH, RAM=$((ROUTER_RAM_KB/1024))MB ==="
