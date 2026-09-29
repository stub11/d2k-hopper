#!/bin/sh
# D2K — Cloudflare DNS-over-HTTPS Setup
set -e
DOH_ENDPOINT="https://1.1.1.1/dns-query"
echo "Configuring DoH via $DOH_ENDPOINT..."
