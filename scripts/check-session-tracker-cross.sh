#!/bin/sh
# Compile every portable C unit/test on the nine Go targets.
# Cross objects are build evidence, not executed tests. MIPS is soft-float.
set -eu
ZIG=${ZIG:-zig}
OUT=${OUT:-builds/session-tracker}
mkdir -p "$OUT"
for arch in amd64 386 arm arm64 mips mipsle mips64le ppc64 riscv64; do
    flags=
    case "$arch" in
        amd64) target=x86_64-linux-musl ;;
        386) target=x86-linux-musl ;;
        arm) target=arm-linux-musleabi; flags=-mcpu=arm926ej_s ;;
        arm64) target=aarch64-linux-musl ;;
        mips) target=mips-linux.1.1.82-musleabi; flags=-msoft-float ;;
        mipsle) target=mipsel-linux.1.1.82-musleabi; flags=-msoft-float ;;
        # Zig 0.15.1 ignores the driver's -msoft-float for n64. Override
        # Clang's ABI and feature explicitly, and verify the emitted ELF.
        mips64le) target=mips64el-linux-muslabi64
            flags='-fPIC -Xclang -mfloat-abi -Xclang soft -Xclang -target-feature -Xclang +soft-float' ;;
        ppc64) target=powerpc64-linux-musl ;;
        riscv64) target=riscv64-linux-musl ;;
    esac
    echo "== C $arch ($target $flags) =="
    # Zig's optimized mode defines NDEBUG; keep existing test assertions live.
    make -C datapath gcc-warn GCC="$ZIG cc -target $target $flags -UNDEBUG"
    # flags is a fixed list above, never untrusted input.
    # shellcheck disable=SC2086
    "$ZIG" cc -target "$target" $flags -UNDEBUG -std=c99 -O2 -Wall -Wextra -Werror \
        -Idatapath/include -c -o "$OUT/session_tracker-$arch.o" datapath/session_tracker.c
    elf=$(file -b "$OUT/session_tracker-$arch.o")
    echo "$arch: $elf"
    case "$arch:$elf" in
        amd64:*x86-64*|386:*Intel\ 80386*|arm:*ARM,*|arm64:*aarch64*) ;;
        mips:*MSB*MIPS*|mipsle:*LSB*MIPS*|mips64le:*LSB*MIPS*) ;;
        ppc64:*MSB*PowerPC*|riscv64:*RISC-V*) ;;
        *) echo "unexpected ELF architecture" >&2; exit 1 ;;
    esac
    case "$arch" in
        mips|mipsle|mips64le)
            readelf -A "$OUT/session_tracker-$arch.o" | grep 'FP ABI: Soft float'
            ;;
    esac
done
echo "C cross-build: PASS (9 architectures; compile-only, no cross execution)"
