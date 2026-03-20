#!/bin/bash
set -e
cd "$(dirname "$0")"

mkdir -p tmp

reset_db() {
  docker compose down -v 2>/dev/null || true
  docker compose up -d --wait
  echo "PostgreSQL ready."
}

if [ "$1" = "--compare-rts" ]; then
  shift
  for label_flags in \
    "default:-N -A16m -s" \
    "F1.2:-N -A16m -F1.2 -s" \
    "F1.5:-N -A16m -F1.5 -s" \
    "A4m:-N -A4m -s" \
    "A4m-F1.2:-N -A4m -F1.2 -s" \
    "compact:-N -A16m -c -s" \
    "nonmoving:-N -A16m -xn -s"; do
    label="${label_flags%%:*}"
    flags="${label_flags#*:}"
    echo ""
    echo "=========================================="
    echo "  RTS config: $label ($flags)"
    echo "=========================================="
    reset_db
    cabal run smp-server-bench -- \
      --timeseries "bench-${label}.csv" \
      --clients "${BENCH_CLIENTS:-1000}" \
      --minutes "${BENCH_MINUTES:-2}" \
      "$@" \
      +RTS $flags -RTS
  done
  echo ""
  echo "Done. CSV files: bench-*.csv"
else
  reset_db
  cabal run smp-server-bench -- \
    --clients "${BENCH_CLIENTS:-5000}" \
    --minutes "${BENCH_MINUTES:-5}" \
    "$@" \
    +RTS -N -A16m -s -RTS
fi

docker compose down
