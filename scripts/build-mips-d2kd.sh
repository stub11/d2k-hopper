#!/bin/sh
# Build the real C datapath daemon for MIPS32 little-endian softfloat.
# Debian mipsel userspace is the soft-float ABI used by the Malta VM.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="${1:-$ROOT/dist/mips-d2kd}"
CC="${MIPSEL_CC:-mipsel-linux-gnu-gcc}"
ASSET_DIR="${GATE3_ASSET_DIR:-$HOME/.cache/d2k-gate3}"
ROOTFS_TAR="$ASSET_DIR/debian-buster-mipsel.tar.xz"
ROOTFS_BASE="https://people.debian.org/~jcowgill/qemu-mips"

command -v "$CC" >/dev/null 2>&1 || { echo "missing MIPS cross compiler: $CC" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "missing curl" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "missing tar" >&2; exit 1; }
command -v xz >/dev/null 2>&1 || { echo "missing xz" >&2; exit 1; }
command -v file >/dev/null 2>&1 || { echo "missing file" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "missing readelf" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$ASSET_DIR"
WORK_SYSROOT="${RUNNER_TEMP:-/tmp}/d2kd-mipsel-sysroot-$$"
trap 'rm -rf "$WORK_SYSROOT"' EXIT
SYSROOT="$WORK_SYSROOT"
mkdir -p "$SYSROOT"

[ -s "$ROOTFS_TAR" ] || curl -fsSL --connect-timeout 10 --max-time 90 -o "$ROOTFS_TAR" "$ROOTFS_BASE/debian-buster-mipsel.tar.xz"
echo "Extracting Debian mipsel soft-float sysroot..."
tar -xJf "$ROOTFS_TAR" -C "$SYSROOT" ./lib ./usr/include ./usr/lib

cd "$ROOT/datapath"
SRC="d2kd.c nfq.c raw.c plan_parse.c plan_apply.c tls.c wire.c track.c session.c nl.c sched.c journal.c plans.c ctl.c ctlsrv.c"
CFLAGS="-std=c99 -O2 -Wall -Wextra -Werror -Iinclude"
LDFLAGS="-static"

echo "CC: $CC"
echo "Target: mipsel-linux-gnu / softfloat using Debian mipsel sysroot"
"$CC" $CFLAGS -msoft-float --sysroot="$SYSROOT" $LDFLAGS -o "$OUT_DIR/d2kd" $SRC
file "$OUT_DIR/d2kd"
readelf -h "$OUT_DIR/d2kd" > "$OUT_DIR/d2kd.elf-header.txt"
grep -q 'ELF32' "$OUT_DIR/d2kd.elf-header.txt"
grep -qi 'little endian' "$OUT_DIR/d2kd.elf-header.txt"
grep -qi 'MIPS' "$OUT_DIR/d2kd.elf-header.txt"
cat "$OUT_DIR/d2kd.elf-header.txt"
ls -lh "$OUT_DIR/d2kd"
