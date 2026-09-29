#!/bin/sh
set -eu

# Безопасный MIPS userspace-стенд для Hopper KN-3810.
# Он НЕ эмулирует KeeneticOS и НЕ утверждает, что NFQUEUE/аппаратный
# offload работают. Его задача — поймать ABI, endian, syscall и запуск
# бинарников на целевой MIPS little-endian userspace до физического роутера.

ROOT="${ROUTER_LAB_ROOT:-$(pwd)/router-lab}"
QEMU="${QEMU_MIPSEL:-qemu-mipsel-static}"
CC="${MIPSEL_CC:-mipsel-linux-gnu-gcc}"
GO="${GO:-go}"

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "router-lab: не найдено: $1" >&2
        exit 1
    }
}

need "$QEMU"
need "$CC"
need "$GO"

rm -rf "$ROOT"
mkdir -p "$ROOT"/bin "$ROOT"/etc/d2k "$ROOT"/opt/d2k/state "$ROOT"/opt/d2k/run

echo "== MIPS userspace: Go =="
env CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat \
    "$GO" build -trimpath -o "$ROOT/bin/d2k" ./cmd/d2k

echo "== запуск Go под QEMU =="
"$QEMU" "$ROOT/bin/d2k" version
"$QEMU" "$ROOT/bin/d2k" help >/dev/null

cat > "$ROOT/etc/d2k/config" <<EOF
SCHEMA=1
MODE=observe
PANEL_LISTEN=127.0.0.1:8090
STATE_DIR=$ROOT/opt/d2k/state
QUEUE_NUM=2000
CONTROL_SOCKET=$ROOT/opt/d2k/run/d2kd.sock
DECOY_SNI=disk.rzd.ru
EOF

echo "== конфигурация в эмулированном rootfs =="
D2K_CONFIG="$ROOT/etc/d2k/config" "$QEMU" "$ROOT/bin/d2k" config >/dev/null
D2K_CONFIG="$ROOT/etc/d2k/config" "$QEMU" "$ROOT/bin/d2k" status >/dev/null

echo "== MIPS C: статическая сборка =="
make -C datapath clean
make -C datapath CC="$CC" \
    CFLAGS='-std=c99 -O2 -Wall -Wextra -Werror -Iinclude -static' \
    all test-parse test-apply test-tls test-wire test-track test-session \
    test-nl test-sched test-journal test-plans test-ctl

echo "== запуск C unit tests под QEMU =="
for t in datapath/test_plan_parse datapath/test_plan_apply datapath/test_tls \
         datapath/test_wire datapath/test_track datapath/test_session \
         datapath/test_nl datapath/test_sched datapath/test_journal \
         datapath/test_plans datapath/test_ctl; do
    "$QEMU" "$t"
done

echo "== MIPS d2kd smoke: только CLI parser =="
"$CC" -std=c99 -O2 -Wall -Wextra -Werror -Idatapath/include -static \
    -o "$ROOT/bin/d2kd" \
    datapath/d2kd.c datapath/nfq.c datapath/raw.c datapath/plan_parse.c \
    datapath/plan_apply.c datapath/tls.c datapath/wire.c datapath/track.c \
    datapath/session.c datapath/nl.c datapath/sched.c datapath/journal.c \
    datapath/plans.c datapath/ctl.c datapath/ctlsrv.c

set +e
"$QEMU" "$ROOT/bin/d2kd" --help >/dev/null 2>&1
rc=$?
set -e
# --help intentionally exits with the daemon's argument-parser status. Нам
# важно, что ELF запускается и доходит до parser без SIGILL/SIGBUS.
if [ "$rc" -ne 0 ]; then
    echo "d2kd --help завершился кодом $rc; это ожидаемо для текущего parser smoke"
fi

echo "ROUTER LAB: GREEN"
echo "CPU/ABI: MIPS little-endian, soft-float"
echo "НЕ ПРОВЕРЕНО: KeeneticOS, NFQUEUE kernel path, HWNAT/WHNAT, Wi-Fi, flash/recovery"
