#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/mips-d2k-parser}"
ZIG="${ZIG:-zig}"
mkdir -p "$OUT"
command -v "$ZIG" >/dev/null 2>&1
cd "$ROOT/datapath"
"$ZIG" cc -target mipsel-linux.1.1.82-musleabi -std=c99 -O2 -Wall -Wextra -Werror -Iinclude -static -o "$OUT/d2kd_parser_test" test_parsers.c tls.c quic.c
file "$OUT/d2kd_parser_test"
readelf -h "$OUT/d2kd_parser_test" > "$OUT/d2kd_parser_test.elf-header.txt"
grep -q 'ELF32' "$OUT/d2kd_parser_test.elf-header.txt"
grep -qi 'MIPS' "$OUT/d2kd_parser_test.elf-header.txt"
grep -qi 'little endian' "$OUT/d2kd_parser_test.elf-header.txt"
