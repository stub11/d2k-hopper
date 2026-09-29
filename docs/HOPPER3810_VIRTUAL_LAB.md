# Hopper 3810 Virtual Lab

Цель стенда — максимально рано ловить ошибки, которые можно проверить без
физического KN-3810: MIPS little-endian ABI, soft-float, запуск Linux-бинарников,
CLI/config parser и C unit tests.

Официальная документация Keenetic указывает для KN-3810 CPU EN7528DU, MIPS
1004Kc, 900 MHz, 2 ядра / 4 потока и 256 MB DDR3. Стенд поэтому использует
MIPS little-endian userspace через QEMU.

## Что делает стенд

1. Собирает Go-контур как linux/mipsle с GOMIPS=softfloat.
2. Запускает d2k version, help, config и status под QEMU.
3. Создаёт отдельный временный rootfs стенда, не связанный с роутером.
4. Собирает C unit tests статически mipsel-компилятором.
5. Запускает C unit tests под QEMU.
6. Собирает d2kd статически и проверяет, что бинарник доходит до CLI parser.

## Чего стенд НЕ доказывает

QEMU userspace не является эмуляцией KeeneticOS. Стенд не подтверждает:

- точное поведение KeeneticOS;
- NFQUEUE в ядре KeeneticOS;
- hardware NAT / wireless hardware offload;
- реальные интерфейсы Hopper;
- Wi-Fi;
- flash layout и recovery;
- реальные ограничения RAM/CPU именно на устройстве.

Поэтому зелёный результат Virtual Lab означает только, что соответствующий
слой можно проверить без физического устройства. Перед первым полевым
запуском всё равно нужен отдельный read-only/observe этап на реальном 3810.

## Почему это безопаснее

Скрипт не подключается к роутеру, не использует SSH, не меняет маршруты,
iptables, DNS или flash и не требует реального сетевого устройства.

Следующий уровень после этого стенда — отдельная system-level VM с MIPS Linux,
сетевыми namespace и тестовым сервером. Её также нужно держать отдельно от
домашней сети.
