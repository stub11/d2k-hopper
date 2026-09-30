#!/bin/sh
# Build the real C datapath daemon for MIPS32 little-endian softfloat.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="${1:-$ROOT/dist/mips-d2kd}"
CC="${MIPSEL_CC:-mipsel-linux-gnu-gcc}"

command -v "$ZIG" >/dev/null 2>&1 || {
  echo "missing Zig toolchain: $ZIG" >&2
  exit 1
}
command -v file >/dev/null 2>&1 || { echo "missing file" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "missing readelf" >&2; exit 1; }

mkdir -p "$OUT_DIR"
cd "$ROOT/datapath"

SRC="d2kd.c nfq.c raw.c plan_parse.c plan_apply.c tls.c wire.c track.c session.c nl.c sched.c journal.c plans.c ctl.c ctlsrv.c"
CFLAGS="-std=c99 -O2 -Wall -Wextra -Werror -Iinclude"
LDFLAGS="-static"

echo "CC: $ZIG cc"
echo "Target: mipsel-linux.1.1.82-musleabi / softfloat"
"$ZIG" version
"$ZIG" targets >/dev/null

"$ZIG" cc -target mipsel-linux-musl -msoft-float $CFLAGS $LDFLAGS -o "$OUT_DIR/d2kd" $SRC
file "$OUT_DIR/d2kd"
readelf -h "$OUT_DIR/d2kd" > "$OUT_DIR/d2kd.elf-header.txt"
grep -q 'ELF32' "$OUT_DIR/d2kd.elf-header.txt"
grep -qi 'little endian' "$OUT_DIR/d2kd.elf-header.txt"
grep -qi 'MIPS' "$OUT_DIR/d2kd.elf-header.txt"
cat "$OUT_DIR/d2kd.elf-header.txt"
ls -lh "$OUT_DIR/d2kd"
