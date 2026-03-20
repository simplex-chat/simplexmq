#!/bin/bash
set -e
cd "$(dirname "$0")"

mkdir -p results

reset_db() {
  docker compose down -v 2>/dev/null || true
  docker compose up -d --wait postgres
  echo "PostgreSQL ready."
}

if [ "$1" = "--compare-rts" ]; then
  shift
  docker compose build bench
  for label_flags in \
    "default:-N -A16m -T" \
    "F1.2:-N -A16m -F1.2 -T" \
    "F1.5:-N -A16m -F1.5 -T" \
    "A4m:-N -A4m -T" \
    "A4m-F1.2:-N -A4m -F1.2 -T" \
    "compact:-N -A16m -c -T" \
    "nonmoving:-N -A16m -xn -T"; do
    label="${label_flags%%:*}"
    flags="${label_flags#*:}"
    echo ""
    echo "=========================================="
    echo "  RTS config: $label ($flags)"
    echo "=========================================="
    reset_db
    docker compose run --rm \
      -e BENCH_CLIENTS="${BENCH_CLIENTS:-1000}" \
      -e BENCH_MINUTES="${BENCH_MINUTES:-2}" \
      bench \
      --pg "postgresql://smp@postgres/smp_bench" \
      --clients "${BENCH_CLIENTS:-1000}" \
      --minutes "${BENCH_MINUTES:-2}" \
      --timeseries "/results/bench-${label}.csv" \
      "$@" \
      +RTS $flags -RTS
  done
  echo ""
  echo "Done. Results in bench/results/"
elif [ "$1" = "--local" ]; then
  # Run natively (not in container) — requires local Postgres
  shift
  reset_db
  cabal run smp-server-bench -f server_postgres -- \
    --pg "postgresql://smp@localhost:15432/smp_bench" \
    --clients "${BENCH_CLIENTS:-5000}" \
    --minutes "${BENCH_MINUTES:-5}" \
    "$@" \
    +RTS -N -A16m -s -RTS
else
  # Run fully in containers
  reset_db
  docker compose run --rm bench "$@"
fi

docker compose down
