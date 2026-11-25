#!/usr/bin/env bash
# Одноразовая установка PostgreSQL + HammerDB в RHEL 10.3 ARM64 VM.
# Запуск: sudo bash rhel103-install.sh
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) echo "This script is for ARM64 VMs only; current arch: $(uname -m)" >&2; exit 1 ;;
esac

PG_VERSION="${PG_VERSION:-16}"
HAMMERDB_VERSION="${HAMMERDB_VERSION:-6.1.1}"
HAMMERDB_LOCAL_FILE="${HAMMERDB_LOCAL_FILE:-}"
PG_SUPERPASS="${PG_SUPERPASS:-postgres}"

curl_download() {
  local url="$1" dest="$2"
  if curl -4 -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 --http1.1 -o "$dest" "$url"; then
    return 0
  fi
  if curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 --http1.1 --tlsv1.2 -o "$dest" "$url"; then
    return 0
  fi
  return 1
}

echo "==> RHEL ARM64 install: PostgreSQL ${PG_VERSION}, HammerDB ${HAMMERDB_VERSION}"

# ---------------------------------------------------------------------------
# 1. PostgreSQL из PGDG
# ---------------------------------------------------------------------------
dnf install -y curl ca-certificates tar

source /etc/os-release
RHEL_MAJOR="${VERSION_ID%%.*}"
PGDG_REPO_URL="http://download.postgresql.org/pub/repos/yum/reporpms/EL-${RHEL_MAJOR}-aarch64/pgdg-redhat-repo-latest.noarch.rpm"
PGDG_REPO_RPM="/tmp/pgdg-redhat-repo-latest.noarch.rpm"
curl -4 -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 -o "$PGDG_REPO_RPM" "$PGDG_REPO_URL"
dnf install -y "$PGDG_REPO_RPM"
rm -f "$PGDG_REPO_RPM"
# PGDG доступен и по HTTP; убираем HTTPS из репо, чтобы сломанный TLS в VM не мешал.
sed -i 's|https://download\.postgresql\.org|http://download.postgresql.org|g' /etc/yum.repos.d/pgdg*.repo 2>/dev/null || true
dnf -qy module disable postgresql || true
if ! dnf list "postgresql${PG_VERSION}-server" >/dev/null 2>&1; then
  echo "postgresql${PG_VERSION}-server is not available from PGDG for EL${RHEL_MAJOR}." >&2
  echo "Set PG_VERSION=<number> to use another version." >&2
  exit 1
fi
dnf install -y "postgresql${PG_VERSION}-server" "postgresql${PG_VERSION}-contrib"

PG_BIN="/usr/pgsql-${PG_VERSION}/bin"
DATA_DIR="/var/lib/pgsql/${PG_VERSION}/data"
if [[ ! -f "${DATA_DIR}/PG_VERSION" ]]; then
  "${PG_BIN}/postgresql-${PG_VERSION}-setup" initdb
fi

if ! grep -q '# HAMMERDB-BENCH' "${DATA_DIR}/postgresql.conf"; then
  cat >> "${DATA_DIR}/postgresql.conf" <<'EOF'
# HAMMERDB-BENCH: конфигурация не тюнится, чтобы сравнивать только ресурсы VM.
listen_addresses = '*'
password_encryption = 'scram-sha-256'
EOF
fi

if ! grep -q '# HAMMERDB-BENCH' "${DATA_DIR}/pg_hba.conf"; then
  cat >> "${DATA_DIR}/pg_hba.conf" <<'EOF'
# HAMMERDB-BENCH
host all all 127.0.0.1/32 scram-sha-256
host all all ::1/128      scram-sha-256
host all all 192.168.50.0/24 scram-sha-256
EOF
fi

systemctl enable --now "postgresql-${PG_VERSION}"
systemctl restart "postgresql-${PG_VERSION}"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
  -c "ALTER USER postgres WITH PASSWORD '${PG_SUPERPASS}';"

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-service=ssh >/dev/null
  firewall-cmd --permanent --add-port=5432/tcp >/dev/null
  firewall-cmd --reload >/dev/null
fi

# ---------------------------------------------------------------------------
# 2. HammerDB
# ---------------------------------------------------------------------------
RPM_URL="https://github.com/TPC-Council/HammerDB/releases/download/v${HAMMERDB_VERSION}/hammerdb-${HAMMERDB_VERSION}-1.el9.aarch64.rpm"
TAR_URL="https://github.com/TPC-Council/HammerDB/releases/download/v${HAMMERDB_VERSION}/HammerDB-${HAMMERDB_VERSION}-Prod-Lin-RHEL9-ARM64.tar.gz"
RPM_PATH="/tmp/hammerdb-${HAMMERDB_VERSION}-1.el9.aarch64.rpm"
TAR_PATH="/tmp/HammerDB-${HAMMERDB_VERSION}-RHEL9-ARM64.tar.gz"

if [[ -n "$HAMMERDB_LOCAL_FILE" ]]; then
  [[ -f "$HAMMERDB_LOCAL_FILE" ]] || { echo "HAMMERDB_LOCAL_FILE not found: $HAMMERDB_LOCAL_FILE" >&2; exit 1; }
  case "$HAMMERDB_LOCAL_FILE" in
    *.rpm)
      dnf install -y "$HAMMERDB_LOCAL_FILE"
      ;;
    *.tar.gz)
      rm -rf "/opt/HammerDB-${HAMMERDB_VERSION}"
      tar -xzf "$HAMMERDB_LOCAL_FILE" -C /opt
      ;;
    *)
      echo "HAMMERDB_LOCAL_FILE must be .rpm or .tar.gz" >&2
      exit 1
      ;;
  esac
elif curl_download "$RPM_URL" "$RPM_PATH"; then
  dnf install -y "$RPM_PATH"
  rm -f "$RPM_PATH"
else
  echo "==> RPM download failed; falling back to ${TAR_URL}"
  if ! curl_download "$TAR_URL" "$TAR_PATH"; then
    echo "Cannot download HammerDB from GitHub (TLS issue). Download it on the host and run:" >&2
    echo "  scp HammerDB-${HAMMERDB_VERSION}-Prod-Lin-RHEL9-ARM64.tar.gz bench@<vm>:~/hammerdb.tar.gz" >&2
    echo "  sudo env HAMMERDB_LOCAL_FILE=~/hammerdb.tar.gz bash ~/rhel103-install.sh" >&2
    exit 1
  fi
  rm -rf "/opt/HammerDB-${HAMMERDB_VERSION}"
  tar -xzf "$TAR_PATH" -C /opt
  rm -f "$TAR_PATH"
fi

find_hammerdb_cli() {
  if [[ -n "${HAMMERDB_CLI:-}" ]]; then printf '%s\n' "$HAMMERDB_CLI"; return; fi
  if command -v hammerdbcli >/dev/null 2>&1; then command -v hammerdbcli; return; fi
  find /opt -maxdepth 3 -type f -name hammerdbcli -perm -u+x 2>/dev/null | sort -V | tail -1 || true
}
HAMMERDB_CLI="$(find_hammerdb_cli)"
[[ -n "$HAMMERDB_CLI" && -x "$HAMMERDB_CLI" ]] || {
  echo "hammerdbcli not found; set HAMMERDB_CLI explicitly" >&2
  exit 1
}

echo "==> Install complete: PostgreSQL ${PG_VERSION}, HammerDB ${HAMMERDB_VERSION}"
echo "==> hammerdbcli: $HAMMERDB_CLI"
echo "==> Next: bash ~/rhel103-run.sh"
