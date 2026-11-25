#!/usr/bin/env bash
# Запуск одного замера HammerDB TPROC-C в уже настроенной Ubuntu ARM64 VM.
# Предварительно: sudo bash ubuntu26-install.sh
# Запуск: bash ubuntu26-run.sh
set -euo pipefail

CONFIG="${CONFIG:-C0}"
LABEL="${LABEL:-ubuntu26-arm64-${CONFIG}}"
WAREHOUSES="${WAREHOUSES:-10}"
NUM_VU="${NUM_VU:-4}"
VUSERS="${VUSERS:-8}"
RAMPUP="${RAMPUP:-2}"
DURATION="${DURATION:-10}"
BUILD_SCHEMA="${BUILD_SCHEMA:-1}"
RESULTS_DIR="${RESULTS_DIR:-$PWD/results}"
WORK_DIR="${WORK_DIR:-$PWD/.hammerdb-tpcc}"
OS_NAME="ubuntu26"

PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
PG_SUPERPASS="${PG_SUPERPASS:-postgres}"
PG_USER="${PG_USER:-tpcc}"
PG_PASS="${PG_PASS:-tpcc}"
PG_DBASE="${PG_DBASE:-tpcc}"

find_hammerdb_cli() {
  if [[ -n "${HAMMERDB_CLI:-}" ]]; then printf '%s\n' "$HAMMERDB_CLI"; return; fi
  if command -v hammerdbcli >/dev/null 2>&1; then command -v hammerdbcli; return; fi
  find /opt -maxdepth 3 -type f -name hammerdbcli -perm -u+x 2>/dev/null | sort -V | tail -1 || true
}
HAMMERDB_CLI="$(find_hammerdb_cli)"
[[ -n "$HAMMERDB_CLI" && -x "$HAMMERDB_CLI" ]] || {
  echo "hammerdbcli not found; run ubuntu26-install.sh first" >&2
  exit 1
}

mkdir -p "$RESULTS_DIR" "$WORK_DIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUT="$RESULTS_DIR/${LABEL}_${STAMP}.log"
CSV="$RESULTS_DIR/vm-bench-results.csv"

echo "==> Config=${CONFIG} label=${LABEL} warehouses=${WAREHOUSES} VU=${VUSERS} rampup=${RAMPUP}m duration=${DURATION}m"

cat > "${WORK_DIR}/build_schema.tcl" <<'TCL'
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C

diset connection pg_host $::env(PG_HOST)
diset connection pg_port $::env(PG_PORT)
diset tpcc pg_superuser $::env(PG_SUPERUSER)
diset tpcc pg_superuserpass $::env(PG_SUPERPASS)
diset tpcc pg_defaultdbase postgres
diset tpcc pg_user $::env(PG_USER)
diset tpcc pg_pass $::env(PG_PASS)
diset tpcc pg_dbase $::env(PG_DBASE)
diset tpcc pg_count_ware $::env(WAREHOUSES)
diset tpcc pg_num_vu $::env(NUM_VU)
diset tpcc pg_partition false

print dict
buildschema
puts "SCHEMA BUILD COMPLETE"
TCL

cat > "${WORK_DIR}/run_tprocc.tcl" <<'TCL'
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C

diset connection pg_host $::env(PG_HOST)
diset connection pg_port $::env(PG_PORT)
diset tpcc pg_superuser $::env(PG_SUPERUSER)
diset tpcc pg_superuserpass $::env(PG_SUPERPASS)
diset tpcc pg_defaultdbase postgres
diset tpcc pg_user $::env(PG_USER)
diset tpcc pg_pass $::env(PG_PASS)
diset tpcc pg_dbase $::env(PG_DBASE)
diset tpcc pg_driver timed
diset tpcc pg_rampup $::env(RAMPUP)
diset tpcc pg_duration $::env(DURATION)
diset tpcc pg_allwarehouse true
diset tpcc pg_timeprofile false

loadscript
print dict
vuset logtotemp 1
vuset vu $::env(VUSERS)
vucreate
vurun
runtimer [expr {($::env(RAMPUP) + $::env(DURATION) + 2) * 60}]
vudestroy
puts "TEST COMPLETE"
TCL

export PG_HOST PG_PORT PG_SUPERUSER PG_SUPERPASS PG_USER PG_PASS PG_DBASE
export WAREHOUSES NUM_VU VUSERS RAMPUP DURATION

if [[ "$BUILD_SCHEMA" == "1" ]]; then
  echo "==> Reset TPROC-C schema on ${PG_HOST}:${PG_PORT}"
  PGPASSWORD="$PG_SUPERPASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${PG_DBASE}\" WITH (FORCE);" \
    -c "DROP ROLE IF EXISTS \"${PG_USER}\";"

  echo "==> Build schema (warehouses=${WAREHOUSES}, build VU=${NUM_VU})"
  "$HAMMERDB_CLI" auto "${WORK_DIR}/build_schema.tcl" 2>&1 | tee "${OUT}.build"
  if grep -qE 'FINISHED FAILED|Error in Virtual User' "${OUT}.build"; then
    echo "Schema build failed; see ${OUT}.build" >&2
    exit 1
  fi
else
  echo "==> Reuse existing schema; set BUILD_SCHEMA=1 to rebuild"
fi

echo "==> Run TPROC-C: rampup=${RAMPUP}m, duration=${DURATION}m, VU=${VUSERS}"
"$HAMMERDB_CLI" auto "${WORK_DIR}/run_tprocc.tcl" 2>&1 | tee "$OUT"

RESULT_LINE="$(grep -m1 'System achieved' "$OUT" || true)"
NOPM="$(printf '%s\n' "$RESULT_LINE" | sed -n 's/.*System achieved \([0-9,]*\) NOPM.*/\1/p' | tr -d ',')"
TPM="$(printf '%s\n' "$RESULT_LINE" | sed -n 's/.*NOPM from \([0-9,]*\) PostgreSQL TPM.*/\1/p' | tr -d ',')"

if [[ ! -f "$CSV" ]]; then
  echo "timestamp,config,os,label,warehouses,vusers,rampup_min,duration_min,tpm,nopm,log" > "$CSV"
fi
printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$TS" "$CONFIG" "$OS_NAME" "$LABEL" "$WAREHOUSES" "$VUSERS" "$RAMPUP" "$DURATION" \
  "$TPM" "$NOPM" "$(basename "$OUT")" >> "$CSV"

echo
if [[ -n "$TPM" && -n "$NOPM" ]]; then
  echo "==> ${LABEL}: TPM=${TPM}, NOPM=${NOPM}"
else
  echo "==> TPM/NOPM not found; inspect $OUT" >&2
fi
echo "==> Log: $OUT"
echo "==> CSV: $CSV"
