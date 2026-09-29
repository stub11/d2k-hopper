# Hopper 3810 Virtual Network Lab

Этот стенд добавляет сетевой слой к существующему MIPS userspace lab.

Он создаёт внутри Linux runner отдельный network namespace с двумя виртуальными
концами veth:

    host namespace
       |
    10.203.0.1
       |
      veth
       |
    10.203.0.2
    isolated namespace

В namespace запускается MIPS little-endian Hopper/D2K бинарник через QEMU.
Тестовый HTTP-сервис работает только на адресе host-side veth.

## Safety

Стенд не подключается к физическому KN-3810 и не меняет сеть пользователя.
Все сетевые интерфейсы создаются внутри CI runner. После завершения namespace
удаляется через trap.

## Что проверяем

- создание изолированного сетевого пространства;
- L3-связность между виртуальными endpoints;
- запуск MIPS little-endian binary внутри изолированного namespace;
- доступ к детерминированному локальному HTTP test service.

## Что ещё не проверяем

- KeeneticOS;
- реальные NFQUEUE hooks;
- hardware NAT/offload;
- Wi-Fi;
- flash/recovery;
- реальную топологию портов KN-3810.

Следующий шаг после этого — добавить виртуальный UDP/TCP/TLS test matrix и
fault injection (loss, delay, reset), не выходя из namespace.
