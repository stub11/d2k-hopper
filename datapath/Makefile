# Датапат d2k. Здесь живёт то, что видит чужие пакеты, и только оно.
#
# -Werror не роскошь: непереносимость обязана ловиться в тот день, когда её
# внесли, а не на роутере. Замер этапа 0 показал, что C даёт ошибки работы с
# памятью там, где Go не даёт, и единственная защита — жёсткие ключи и тесты.

CC      ?= cc
CFLAGS  ?= -std=c99 -O2 -Wall -Wextra -Werror -Iinclude
LDFLAGS ?=

# Кросс-компиляторы для проверки переносимости. Пути переопределяются извне.
ZIG        ?= /opt/homebrew/bin/zig
MIPSEL_CC  ?= mipsel-unknown-linux-gnu-gcc

# Переносимый датапат: собирается и проверяется на любой машине.
SRC     = plan_parse.c plan_apply.c tls.c wire.c track.c session.c nl.c sched.c journal.c plans.c ctl.c ctlsrv.c
# Системный слой: только Linux. На маке не собирается намеренно — подделывать
# сокеты ядра ради сборки значило бы проверять подделку. Проверяется целью
# cross, которая линкует ПОЛНУЮ службу под обе целевые арки: полная сборка
# доказывает больше, чем компиляция объектников.
LINUXSRC = nfq.c raw.c
DAEMON   = d2kd.c
HDR     = include/d2k_plan.h include/d2k_tls.h include/d2k_wire.h include/d2k_track.h include/d2k_session.h include/d2k_nl.h include/d2k_sched.h include/d2k_nfq.h include/d2k_raw.h include/d2k_journal.h include/d2k_plans.h include/d2k_ctl.h include/d2k_ctlsrv.h plan_internal.h ipv6.h

# Тесты и их объектные файлы. Один список — чтобы санитайзерная цель не
# разъезжалась с обычной: разъехавшись, она проверяла бы не то дерево.
TESTS   = test_plan_parse test_plan_apply test_tls test_wire test_track test_session test_nl test_sched test_journal test_plans test_ctl ipv6_test test_ipv6_pipeline test_flowkey_e2e

.PHONY: all check san gcc-warn ctlprobe d2kd-aarch64 test-parse test-apply test-tls test-wire test-track test-session test-nl test-sched test-journal test-plans test-ctl test-ipv6 test-ipv6-pipeline test-flowkey-e2e cross clean

all: planlab ctlprobe

plan_parse.o: plan_parse.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

plan_apply.o: plan_apply.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

test_plan_parse: test_plan_parse.c plan_parse.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_plan_parse.c plan_parse.o $(LDFLAGS)

tls.o: tls.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

test_tls: test_tls.c tls.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_tls.c tls.o $(LDFLAGS)

session.o: session.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

journal.o: journal.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

plans.o: plans.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

ctl.o: ctl.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

test_ctl: test_ctl.c ctl.o journal.o track.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_ctl.c ctl.o journal.o track.o $(LDFLAGS)

test_ipv6: ipv6_test.c ipv6.h
	$(CC) $(CFLAGS) -o $@ ipv6_test.c $(LDFLAGS)

test_plans: test_plans.c plans.o plan_parse.o plan_apply.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_plans.c plans.o plan_parse.o plan_apply.o $(LDFLAGS)

test_journal: test_journal.c journal.o track.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_journal.c journal.o track.o $(LDFLAGS)

test_session: test_session.c session.o track.o tls.o wire.o journal.o plans.o plan_parse.o plan_apply.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_session.c session.o track.o tls.o wire.o journal.o plans.o plan_parse.o plan_apply.o $(LDFLAGS)

track.o: track.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

test_track: test_track.c track.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_track.c track.o $(LDFLAGS)

wire.o: wire.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

nl.o: nl.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

test_nl: test_nl.c nl.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_nl.c nl.o $(LDFLAGS)

sched.o: sched.c $(HDR)
	$(CC) $(CFLAGS) -c -o $@ $<

test_sched: test_sched.c sched.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_sched.c sched.o $(LDFLAGS)

test_wire: test_wire.c wire.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_wire.c wire.o $(LDFLAGS)

test_plan_apply: test_plan_apply.c plan_parse.o plan_apply.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_plan_apply.c plan_parse.o plan_apply.o $(LDFLAGS)

planlab: planlab.c plan_parse.o plan_apply.o $(HDR)
	$(CC) $(CFLAGS) -o $@ planlab.c plan_parse.o plan_apply.o $(LDFLAGS)

# Стенд управляющего сокета: тот же разбор команд и та же сессия, что в d2kd,
# но пакеты собираются на месте. Нужен, чтобы Go-клиент проверялся против
# настоящего C-сервера, а не против представления о нём.
ctlprobe: ctlprobe.c $(SRC:.c=.o) $(HDR)
	$(CC) $(CFLAGS) -o $@ ctlprobe.c $(SRC:.c=.o) $(LDFLAGS)

test-parse: test_plan_parse
	./test_plan_parse

test-apply: test_plan_apply
	./test_plan_apply

test-tls: test_tls
	./test_tls

test-wire: test_wire
	./test_wire

test-track: test_track
	./test_track

test-session: test_session
	./test_session

test-nl: test_nl
	./test_nl

test-sched: test_sched
	./test_sched

test-journal: test_journal
	./test_journal

test-plans: test_plans
	./test_plans

test-ctl: test_ctl
	./test_ctl

test-ipv6: test_ipv6
	./test_ipv6

# End-to-end IPv6/TCP pipeline: parser, canonical flow key, TLS payload and wire checksum.
test-ipv6-pipeline: test_ipv6_pipeline
	./test_ipv6_pipeline

test_ipv6_pipeline: test_ipv6_pipeline.c ipv6.h wire.c tls.c track.c $(HDR)
	$(CC) $(CFLAGS) -o $@ test_ipv6_pipeline.c wire.c tls.c track.c $(LDFLAGS)

test_flowkey_e2e: test_flowkey_e2e.c track.o $(HDR)
	$(CC) $(CFLAGS) -o $@ test_flowkey_e2e.c track.o $(LDFLAGS)

test-flowkey-e2e: test_flowkey_e2e
	./test_flowkey_e2e

# Тот же набор под санитайзерами. «Не упало» и «не читало за буфером» — разные
# утверждения, а весь датапат состоит из разбора чужих байтов. Отдельная цель,
# потому что -fsanitize замедляет и не собирается частью кросс-компиляторов.
SANFLAGS = -std=c99 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all \
           -fno-omit-frame-pointer -Wall -Wextra -Werror -Iinclude
san:
	@set -e; for t in $(TESTS); do \
		echo "== $$t =="; \
		$(CC) $(SANFLAGS) -o /tmp/d2k-san-$$t $$t.c \
			$$(echo "$(SRC)" | tr ' ' '\n' | grep -v '^$$') ; \
		/tmp/d2k-san-$$t; \
	done
	@echo "== test_ipv6 =="
	$(CC) $(SANFLAGS) -o /tmp/d2k-san-test_ipv6 ipv6_test.c
	/tmp/d2k-san-test_ipv6
	@echo "санитайзеры: все проверки прошли"

# Тот же набор ЧУЖИМ компилятором. Не роскошь: локально всё собирает clang, а
# CI — gcc, и они расходятся. gcc ловит sign-compare там, где clang молчит, и
# из-за этого КАЖДЫЙ прогон CI был красным с первого коммита, пока локальный
# гейт горел зелёным. Компиляция без запуска: цель тут — предупреждения, а
# исполняются те же тесты обычной целью check.
#
# Берётся кросс-компилятор под mipsel, потому что это настоящий gcc и он уже
# нужен для переносимости. Переопределяется через GCC=.
GCC ?= mipsel-unknown-linux-gnu-gcc
gcc-warn:
	@for f in $(SRC) $(LINUXSRC) $(DAEMON) planlab.c ctlprobe.c $(TESTS:=.c); do \
		$(GCC) $(CFLAGS) -c -o /tmp/d2k-gccwarn.o $$f || exit 1; \
	done
	@echo "чужой компилятор: предупреждений нет"

# Переносимость проверяется компиляцией под целевые арки. Запускать там нечего
# и не нужно: ловим порядок байт, выравнивание и ширину типов.
cross:
	@for f in $(SRC); do \
		echo "== $$f =="; \
		$(ZIG) cc -target aarch64-linux-musl $(CFLAGS) -c -o /tmp/d2k-a64.o $$f || exit 1; \
		$(MIPSEL_CC) $(CFLAGS) -c -o /tmp/d2k-mipsel.o $$f || exit 1; \
	done
	@echo "== d2kd целиком =="
	@$(ZIG) cc -target aarch64-linux-musl $(CFLAGS) -o /tmp/d2kd-a64 \
		$(DAEMON) $(LINUXSRC) $(SRC) || exit 1
	@$(MIPSEL_CC) $(CFLAGS) -o /tmp/d2kd-mipsel $(DAEMON) $(LINUXSRC) $(SRC) || exit 1
	@echo "переносимость: aarch64 и mipsel собираются, служба линкуется"

# Служба для целевого устройства. Статическая musl: на роутере нет ни нужной
# libc, ни желания зависеть от той, что там есть.
BUILDDIR ?= ../builds
d2kd-aarch64:
	@mkdir -p $(BUILDDIR)
	$(ZIG) cc -target aarch64-linux-musl $(CFLAGS) -static \
		-o $(BUILDDIR)/d2kd-aarch64 $(DAEMON) $(LINUXSRC) $(SRC)
	@ls -l $(BUILDDIR)/d2kd-aarch64

# planlab тоже в зависимостях, и это не украшение: он собирается отдельной
# целью, поэтому однажды check остался зелёным при несобирающейся
# лаборатории. Проверка, не собирающая всё, что есть, проверяет не дерево.
check: all test-parse test-apply test-tls test-wire test-track test-session test-nl test-sched test-journal test-plans test-ctl test-ipv6 test-ipv6-pipeline test-flowkey-e2e

clean:
	rm -f *.o $(TESTS) test_ipv6 planlab ctlprobe

PARSER_TEST = d2kd_parser_test
PARSER_CFLAGS = -std=c99 -O2 -Wall -Wextra -Werror -Iinclude
PARSER_ZIG ?= zig

$(PARSER_TEST): test_parsers.c tls.c quic.c $(HDR) include/d2k_quic.h
	$(PARSER_ZIG) cc -target mipsel-linux.1.1.82-musleabi $(PARSER_CFLAGS) -static -o $@ test_parsers.c tls.c quic.c

test-parsers: $(PARSER_TEST)
	./$(PARSER_TEST)
