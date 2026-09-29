#!/bin/sh
# Build only the actual Go CLI entry point for MT7621-class MIPS32 little-endian.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR=${1:-"$ROOT/dist/mips"}
GO_BIN=${GO:-go}

command -v "$GO_BIN" >/dev/null 2>&1 || { echo "missing Go toolchain: $GO_BIN" >&2; exit 1; }
command -v file >/dev/null 2>&1 || { echo "missing file utility" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "missing readelf" >&2; exit 1; }

cd "$ROOT"
mkdir -p "$OUT_DIR"
echo "Go: $("$GO_BIN" version)"
echo "Target: GOOS=linux GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0"

VERSION=${VERSION:-gate2}
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || printf unknown)
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS="-s -w -X github.com/necronicle/d2k/internal/buildinfo.Version=$VERSION -X github.com/necronicle/d2k/internal/buildinfo.Commit=$COMMIT -X github.com/necronicle/d2k/internal/buildinfo.Date=$DATE -X github.com/necronicle/d2k/internal/buildinfo.Dirty=0"

env CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat \
  "$GO_BIN" build -trimpath -ldflags "$LDFLAGS" -o "$OUT_DIR/d2k" ./cmd/d2k

file "$OUT_DIR/d2k"
readelf -h "$OUT_DIR/d2k" > "$OUT_DIR/d2k.elf-header.txt"
grep -q 'ELF32' "$OUT_DIR/d2k.elf-header.txt"
grep -qi 'little endian' "$OUT_DIR/d2k.elf-header.txt"
grep -qi 'MIPS' "$OUT_DIR/d2k.elf-header.txt"
cat "$OUT_DIR/d2k.elf-header.txt"
ls -lh "$OUT_DIR/d2k"
