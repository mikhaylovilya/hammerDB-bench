#!/usr/bin/env bash
# Одноразовая установка PostgreSQL + HammerDB в Ubuntu Server 26 ARM64 VM.
# Запуск: sudo bash ubuntu26-install.sh
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi
case "$(uname -m)" in
  aarch64|arm64) HAMMERDB_PKG_ARCH="arm64" ;;
  *) echo "This script is for ARM64 VMs only; current arch: $(uname -m)" >&2; exit 1 ;;
esac

PG_VERSION="${PG_VERSION:-16}"
PGDG_CODENAME="${PGDG_CODENAME:-}"
HAMMERDB_VERSION="${HAMMERDB_VERSION:-6.1.1}"
HAMMERDB_DEB_PATH="${HAMMERDB_DEB_PATH:-}"
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

echo "==> Ubuntu ARM64 install: PostgreSQL ${PG_VERSION}, HammerDB ${HAMMERDB_VERSION}"

# ---------------------------------------------------------------------------
# 1. PostgreSQL из PGDG
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

PGDG_KEY_RING="/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg"
PGDG_KEY_SRC="/tmp/ACCC4CF8.asc"
PGDG_KEY_FPRS="/tmp/ACCC4CF8.fprs"
PGDG_KEY_FPR="B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"
install -d -m 0755 "$(dirname "$PGDG_KEY_RING")"

PGDG_KEY_OK=0
for key_url in \
  http://apt.postgresql.org/pub/repos/apt/ACCC4CF8.asc \
  http://www.postgresql.org/media/keys/ACCC4CF8.asc \
  https://apt.postgresql.org/pub/repos/apt/ACCC4CF8.asc \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
do
  if curl -4 -fsSL --retry 2 --retry-delay 2 --connect-timeout 15 -o "$PGDG_KEY_SRC" "$key_url" \
     && grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$PGDG_KEY_SRC"; then
    gpg --show-keys --with-colons "$PGDG_KEY_SRC" > "$PGDG_KEY_FPRS" 2>/dev/null || true
    FPR="$(awk -F: '$1=="fpr"{print $10; exit}' "$PGDG_KEY_FPRS")"
    if [[ "$FPR" == "$PGDG_KEY_FPR" ]]; then
      echo "==> PGDG key: $key_url (fingerprint OK)"
      PGDG_KEY_OK=1
      break
    fi
  fi
done
if [[ "$PGDG_KEY_OK" -ne 1 ]]; then
  echo "Failed to download/verify PGDG key. Check DNS, proxy and IPv4 connectivity." >&2
  exit 1
fi
gpg --dearmor -o "$PGDG_KEY_RING" "$PGDG_KEY_SRC"
chmod 0644 "$PGDG_KEY_RING"
rm -f "$PGDG_KEY_SRC" "$PGDG_KEY_FPRS"

source /etc/os-release
CODENAME="${VERSION_CODENAME:-$(lsb_release -cs)}"
ARCH="$(dpkg --print-architecture)"

pgdg_suite_has_arm64() {
  local suite="$1"
  local release
  release="$(curl -4 -fsS --connect-timeout 15 \
    "http://apt.postgresql.org/pub/repos/apt/dists/${suite}-pgdg/Release" 2>/dev/null || true)"
  [[ "$release" == *"Architectures:"* && "$release" == *" arm64"* ]]
}

if [[ -n "$PGDG_CODENAME" ]]; then
  if ! pgdg_suite_has_arm64 "$PGDG_CODENAME"; then
    echo "PGDG_CODENAME=${PGDG_CODENAME} has no arm64 packages." >&2
    exit 1
  fi
else
  PGDG_CODENAME="$CODENAME"
  if ! pgdg_suite_has_arm64 "$PGDG_CODENAME"; then
    for fallback_suite in resolute noble jammy; do
      if pgdg_suite_has_arm64 "$fallback_suite"; then
        echo "==> ${CODENAME}-pgdg has no arm64 packages; using ${fallback_suite}-pgdg instead"
        PGDG_CODENAME="$fallback_suite"
        break
      fi
    done
  fi
fi
if [[ -z "$PGDG_CODENAME" ]]; then
  echo "No PGDG suite with arm64 packages found. Set PGDG_CODENAME explicitly." >&2
  exit 1
fi
echo "==> OS: ${VERSION_ID:-?} (${CODENAME}), arch=${ARCH}, PGDG suite=${PGDG_CODENAME}-pgdg"

cat > /etc/apt/sources.list.d/pgdg.list <<EOF
deb [signed-by=${PGDG_KEY_RING}] http://apt.postgresql.org/pub/repos/apt ${PGDG_CODENAME}-pgdg main
EOF

apt-get update
PG_POLICY="$(apt-cache policy "postgresql-${PG_VERSION}" 2>/dev/null || true)"
if [[ "$PG_POLICY" != *"Candidate: "* || "$PG_POLICY" == *"Candidate: (none)"* ]]; then
  echo "postgresql-${PG_VERSION} is not available for ${PGDG_CODENAME}-pgdg." >&2
  apt-cache search '^postgresql-[0-9]+$' | sort >&2 || true
  echo "Set PG_VERSION=<number> to use another version." >&2
  exit 1
fi
apt-get install -y "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"

# Иногда пакет ставится, но кластер main не создаётся (например, после
# прерванной установки или с create_main_cluster = false). Доводим это до
# рабочего состояния до того, как писать конфиги и дёргать pg_ctlcluster.
cluster_exists() {
  [[ -n "$(pg_lsclusters --no-header "$PG_VERSION" main 2>/dev/null | awk 'NF')" ]]
}

if ! cluster_exists; then
  echo "==> PostgreSQL cluster ${PG_VERSION}/main not found; trying dpkg --configure -a"
  dpkg --configure -a || echo "==> dpkg --configure -a returned non-zero; continuing"
fi

if ! cluster_exists; then
  CLUSTER_CONF="/etc/postgresql/${PG_VERSION}/main"
  # После неудачного прошлого запуска здесь может остаться только conf.d/ и
  # пустой pg_hba.conf. Такой каталог не является кластером — убираем его,
  # чтобы pg_createcluster мог создать нормальные конфиги.
  if [[ -d "$CLUSTER_CONF" && ! -f "${CLUSTER_CONF}/postgresql.conf" ]]; then
    mv "$CLUSTER_CONF" "${CLUSTER_CONF}.incomplete.$(date +%s)"
    echo "==> Moved incomplete config dir to ${CLUSTER_CONF}.incomplete.*"
  fi
  echo "==> Creating PostgreSQL cluster ${PG_VERSION}/main"
  pg_createcluster "$PG_VERSION" main
fi

pg_lsclusters "$PG_VERSION" main

CONF_DIR="/etc/postgresql/${PG_VERSION}/main/conf.d"
mkdir -p "$CONF_DIR"
cat > "${CONF_DIR}/99-hammerdb.conf" <<'EOF'
# HAMMERDB-BENCH: конфигурация не тюнится, чтобы сравнивать только ресурсы VM.
listen_addresses = '*'
password_encryption = 'scram-sha-256'
EOF

PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if ! grep -q '# HAMMERDB-BENCH' "$PG_HBA" 2>/dev/null; then
  cat >> "$PG_HBA" <<'EOF'
# HAMMERDB-BENCH
host all all 127.0.0.1/32 scram-sha-256
host all all ::1/128      scram-sha-256
host all all 192.168.50.0/24 scram-sha-256
EOF
fi

systemctl enable "postgresql@${PG_VERSION}-main" >/dev/null 2>&1 || true
pg_ctlcluster "$PG_VERSION" main restart || pg_ctlcluster "$PG_VERSION" main start
runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
  -c "ALTER USER postgres WITH PASSWORD '${PG_SUPERPASS}';"

# ---------------------------------------------------------------------------
# 2. HammerDB
# ---------------------------------------------------------------------------
DEB_URL="https://github.com/TPC-Council/HammerDB/releases/download/v${HAMMERDB_VERSION}/hammerdb_${HAMMERDB_VERSION}-1_${HAMMERDB_PKG_ARCH}.deb"
DEB_PATH="/tmp/hammerdb_${HAMMERDB_VERSION}-1_${HAMMERDB_PKG_ARCH}.deb"
if [[ -n "$HAMMERDB_DEB_PATH" ]]; then
  [[ -f "$HAMMERDB_DEB_PATH" ]] || { echo "HAMMERDB_DEB_PATH not found: $HAMMERDB_DEB_PATH" >&2; exit 1; }
  cp "$HAMMERDB_DEB_PATH" "$DEB_PATH"
elif ! curl_download "$DEB_URL" "$DEB_PATH"; then
  echo "Cannot download HammerDB .deb from GitHub (TLS issue). Download it on the host and run:" >&2
  echo "  scp hammerdb_${HAMMERDB_VERSION}-1_${HAMMERDB_PKG_ARCH}.deb bench@<vm>:~/hammerdb.deb" >&2
  echo "  sudo env HAMMERDB_DEB_PATH=~/hammerdb.deb bash ~/ubuntu26-install.sh" >&2
  exit 1
fi
apt-get install -y "$DEB_PATH"
rm -f "$DEB_PATH"

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
echo "==> Next: bash ~/ubuntu26-run.sh"
