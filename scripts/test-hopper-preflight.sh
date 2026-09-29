#!/bin/sh
set -eu
ROOT=\$(CDPATH="" cd -- "\$(dirname -- "\$0")/.." && pwd)
shellcheck -s sh "\$ROOT/scripts/hopper-preflight.sh"
"\$ROOT/scripts/hopper-preflight.sh" --help >/dev/null
echo "preflight tests: GREEN"
