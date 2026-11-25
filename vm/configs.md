# Конфигурации виртуальных машин

HammerDB и PostgreSQL запускаются **внутри одной и той же VM**, поэтому отдельная driver VM не нужна. На хосте меняются только CPU и RAM; диск, сеть и настройки PostgreSQL остаются постоянными.

Установку (`*-install.sh`) делаешь один раз до начала матрицы. Для каждой строки C0–C4 меняешь ресурсы VM и запускаешь только `*-run.sh`.

Имена VM в командах ниже — примеры. Подставь свои имена, которые видны в `VBoxManage list vms`.

| ID | vCPU | RAM | Что проверяем |
|---|---:|---:|---|
| C0 | 2 | 4096 MB | База: Ubuntu Server 26 arm64 vs RHEL 10.3 arm64 |
| C1 | 1 | 4096 MB | Меньше CPU |
| C2 | 4 | 4096 MB | Больше CPU |
| C3 | 2 | 2048 MB | Меньше RAM |
| C4 | 2 | 8192 MB | Больше RAM |

Параметры HammerDB во всех прогонах одинаковые:

```bash
WAREHOUSES=10 NUM_VU=4 VUSERS=8 RAMPUP=2 DURATION=10
```

Один замер: 2 минуты ramp-up + 10 минут измерений плюс время сборки схемы. Для серии повторов после первого прогона можно использовать `BUILD_SCHEMA=0`, чтобы не пересобирать схему.

## Как менять конфигурацию

Перед изменением VM полностью выключи её:

```bash
VBoxManage controlvm ubuntu26-arm64 acpipowerbutton
VBoxManage showvminfo ubuntu26-arm64 --machinereadable | grep VMState
# ждать VMState="poweroff"
```

Затем применить одну строку:

| Конфигурация | Команда на хосте |
|---|---|
| C0 | `VBoxManage modifyvm ubuntu26-arm64 --cpus 2 --memory 4096` |
| C1 | `VBoxManage modifyvm ubuntu26-arm64 --cpus 1 --memory 4096` |
| C2 | `VBoxManage modifyvm ubuntu26-arm64 --cpus 4 --memory 4096` |
| C3 | `VBoxManage modifyvm ubuntu26-arm64 --cpus 2 --memory 2048` |
| C4 | `VBoxManage modifyvm ubuntu26-arm64 --cpus 2 --memory 8192` |

Для RHEL те же команды с другим именем VM, например `rhel103-arm64`.

После смены ресурсов запустить VM и выполнить бенч-скрипт с новым `CONFIG` и `LABEL`:

```bash
VBoxManage startvm ubuntu26-arm64 --type headless
CONFIG=C2 LABEL=vm-ubuntu26-c2 bash ~/ubuntu26-run.sh
```

## Важно

- На хосте 8 vCPU и 16 GB RAM. Не запускай одновременно две тестируемые VM, особенно конфигурацию C4 (8 GB).
- Меняй только один параметр за раз: либо CPU, либо RAM.
- Не меняй `postgresql.conf` между прогонами — иначе результат зависит и от тюнинга, и от ресурсов VM.
- ISO должны быть ARM64/aarch64: `ubuntu-26.04-*-arm64.iso` и `rhel-10.3-*-aarch64.iso`.
- Для RHEL нужен доступ к базовым репозиториям (активная подписка или локальное зеркало); PGDG-репозиторий PostgreSQL публичный.
