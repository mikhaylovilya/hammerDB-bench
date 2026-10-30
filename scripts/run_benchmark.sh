#!/usr/bin/env bash
# Запуск одного теста HammerDB против контейнера PostgreSQL
# Usage: ./scripts/run_benchmark.sh <host> <port> <label> [cpus] [mem]
set -euo pipefail

PG_HOST="${1:?host}"
PG_PORT="${2:?port}"
LABEL="${3:?label}"
WAREHOUSES="${WAREHOUSES:-10}"
NUM_VU="${NUM_VU:-4}"
VUSERS="${VUSERS:-8}"
RAMPUP="${RAMPUP:-1}"
DURATION="${DURATION:-5}"
RESULTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/results"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$RESULTS_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="$RESULTS_DIR/${LABEL}_${STAMP}.log"

echo "==> Build schema: $LABEL ($PG_HOST:$PG_PORT)"
docker run --rm --network host \
  -e PG_HOST="$PG_HOST" \
  -e PG_PORT="$PG_PORT" \
  -e WAREHOUSES="$WAREHOUSES" \
  -e NUM_VU="$NUM_VU" \
  -v "$SCRIPTS_DIR:/scripts:ro" \
  tpcorg/hammerdb \
  ./hammerdbcli auto /scripts/build_schema.tcl | tee "$OUT.build"

echo "==> Run TPROC-C: $LABEL (VU=$VUSERS, rampup=${RAMPUP}m, duration=${DURATION}m)"
docker run --rm --network host \
  -e PG_HOST="$PG_HOST" \
  -e PG_PORT="$PG_PORT" \
  -e VUSERS="$VUSERS" \
  -e RAMPUP="$RAMPUP" \
  -e DURATION="$DURATION" \
  -v "$SCRIPTS_DIR:/scripts:ro" \
  tpcorg/hammerdb \
  ./hammerdbcli auto /scripts/run_tprocc.tcl | tee "$OUT"

echo "==> Done: $OUT"
grep -E "TPM|NOPM|SYSTEM|TEST RESULT" "$OUT" || true
