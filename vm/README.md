# Ручные бенчмарки в VirtualBox (ARM64)

Минимальный набор для Medium-задания: установка и запуск разделены, никакого создания VM и оркестрации.

## Скрипты

| Скрипт | Назначение | Запуск |
|---|---|---|
| `ubuntu26-install.sh` | Ставит PostgreSQL из PGDG и HammerDB 6.1.1 в Ubuntu Server 26 ARM64 | `sudo bash ~/ubuntu26-install.sh` |
| `ubuntu26-run.sh` | Один замер TPROC-C в уже настроенной Ubuntu VM | `bash ~/ubuntu26-run.sh` |
| `rhel103-install.sh` | Ставит PostgreSQL из PGDG и HammerDB 6.1.1 в RHEL 10.3 ARM64 | `sudo bash ~/rhel103-install.sh` |
| `rhel103-run.sh` | Один замер TPROC-C в уже настроенной RHEL VM | `bash ~/rhel103-run.sh` |
| `ubuntu26-bench.sh` / `rhel103-bench.sh` | Wrapper: install + run (только для первого запуска) | `sudo bash ~/ubuntu26-bench.sh` |
| `configs.md` | Матрица C0–C4 и смена CPU/RAM хоста | — |

PostgreSQL и HammerDB работают в одной VM. Установку делаешь **один раз**, дальше для каждой конфигурации вызываешь только `*-run.sh`.

## Быстрый запуск

1. Установи VM с ARM64 ISO (50 GB диск, 2 vCPU, 4 GB RAM), включи SSH, создай пользователя с sudo.
2. Скопируй install + run в VM:

   ```bash
   scp vm/ubuntu26-install.sh vm/ubuntu26-run.sh bench@ubuntu-vm:~/
   ssh bench@ubuntu-vm
   ```

3. Установка (один раз):

   ```bash
   sudo bash ~/ubuntu26-install.sh
   ```

4. Первый замер:

   ```bash
   bash ~/ubuntu26-run.sh
   ```

5. Смени конфигурацию по `vm/configs.md`, загрузи VM и запусти только раннер:

   ```bash
   CONFIG=C2 LABEL=vm-ubuntu26-c2 bash ~/ubuntu26-run.sh
   ```

Если хочешь одним шагом: `sudo bash ~/ubuntu26-bench.sh` — это просто wrapper вокруг install + run.

## Переменные окружения

Установка (`*-install.sh`):

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PG_VERSION` | `16` | Версия PostgreSQL из PGDG |
| `PGDG_CODENAME` | авто | Suite PGDG; авто-фолбэк на `resolute` для arm64 |
| `HAMMERDB_VERSION` | `6.1.1` | Версия HammerDB |
| `HAMMERDB_DEB_PATH` | пусто | Ubuntu: путь к уже скачанному `.deb` |
| `HAMMERDB_LOCAL_FILE` | пусто | RHEL: путь к уже скачанному `.rpm` или `.tar.gz` |
| `PG_SUPERPASS` | `postgres` | Пароль суперпользователя PostgreSQL |

Запуск (`*-run.sh`):

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `CONFIG` | `C0` | Метка конфигурации в CSV |
| `LABEL` | `ubuntu26-arm64-C0` / `rhel103-arm64-C0` | Имя лога |
| `WAREHOUSES` | `10` | Число складов TPROC-C |
| `NUM_VU` | `4` | VU для сборки схемы |
| `VUSERS` | `8` | VU нагрузочного теста |
| `RAMPUP` | `2` | Ramp-up, минуты |
| `DURATION` | `10` | Замер, минуты |
| `BUILD_SCHEMA` | `1` | `0` — использовать существующую схему без сброса |
| `RESULTS_DIR` | `$PWD/results` | Куда писать логи и CSV |
| `HAMMERDB_CLI` | авто | Явный путь к `hammerdbcli` |

Быстрая проверка перед длинными прогонами:

```bash
WAREHOUSES=1 NUM_VU=1 VUSERS=2 RAMPUP=1 DURATION=1 LABEL=smoke bash ~/ubuntu26-run.sh
```

## Результаты

В `RESULTS_DIR` появятся:

- `<LABEL>_<timestamp>.log` и `<LABEL>_<timestamp>.log.build` — вывод HammerDB;
- `vm-bench-results.csv` — строка на каждый прогон с TPM/NOPM.

Итоговая строка в логе:

```text
Vuser 1:TEST RESULT : System achieved 32510 NOPM from 74825 PostgreSQL TPM
```

Не смешивай результаты с Docker-отчётом: это разные уровни изоляции.

## Если кластер PostgreSQL не создался

Ошибки `grep: /etc/postgresql/16/main/pg_hba.conf: No such file or directory` и `Error: specified cluster '16 main' does not exist` означают, что пакет `postgresql-16` установлен, но кластер `16/main` отсутствует. Текущий install-скрипт это исправляет: он проверяет `pg_lsclusters`, при необходимости выполняет `dpkg --configure -a`, а затем `pg_createcluster <version> main`. После повторного запуска в логе должна появиться строка `==> Creating PostgreSQL cluster 16/main` и вывод `pg_lsclusters`.

Если кластер нужно создать вручную:

```bash
sudo pg_createcluster 16 main --start
sudo pg_lsclusters
```

## Если при установке падает TLS/GPG

Ошибка `TLS connect error: ... unexpected eof while reading` и следующая за ней `gpg: no valid OpenPGP data found` означает, что `curl` не скачал ключ. Установочные скрипты уже делают следующее:

- `curl` сначала пытается строго по IPv4 (`-4`) и с HTTP/1.1;
- ключ PGDG качается по HTTP, но проверяется по отпечатку `B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8`;
- apt/yum-репозиторий PGDG тоже переключён на HTTP.

Для Ubuntu 26.10 (`stonking`) PGDG публикует только `amd64`. Скрипт проверяет `Architectures:` в `Release` и автоматически использует `resolute-pgdg`:

```text
==> stonking-pgdg has no arm64 packages; using resolute-pgdg instead
```

Если GitHub для HammerDB недоступен, скачай пакет на хосте:

```bash
scp hammerdb_6.1.1-1_arm64.deb bench@ubuntu-vm:~/hammerdb.deb
sudo env HAMMERDB_DEB_PATH=~/hammerdb.deb bash ~/ubuntu26-install.sh
```

Для RHEL:

```bash
scp HammerDB-6.1.1-Prod-Lin-RHEL9-ARM64.tar.gz bench@rhel-vm:~/hammerdb.tar.gz
sudo env HAMMERDB_LOCAL_FILE=~/hammerdb.tar.gz bash ~/rhel103-install.sh
```

Диагностика сети:

```bash
env | grep -i proxy
curl -4 -v https://apt.postgresql.org/pub/repos/apt/ACCC4CF8.asc -o /dev/null
ip -br link
```

Если IPv4 помогает, проблема была в IPv6. Если нет — временно снизь MTU интерфейса VM до 1400.
