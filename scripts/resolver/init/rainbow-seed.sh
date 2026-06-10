#!/usr/bin/env bash
# Seed the ENS rainbow table (public.ens_names) so graph-node can map label
# hashes back to human names. Must run BEFORE the subgraph indexes: graph-node
# heals labels at index time via nameByHash, and labels indexed before the seed
# are not retroactively healed. graph-node creates the table via a startup
# migration (varchar hash/name columns), so we wait for it to appear (covers the
# startup race). Runs on the postgres image (has psql). Idempotent: ON CONFLICT.
set -euo pipefail

echo "==> Waiting for public.ens_names (graph-node creates it via startup migration)"
for _ in $(seq 1 120); do
  if psql -tAc "SELECT to_regclass('public.ens_names')" | grep -q ens_names; then break; fi
  echo "    not present yet — waiting..."
  sleep 5
done

echo "==> Seeding rainbow table"
psql -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.ens_names (hash, name) VALUES
 ('0x5f16f4c7f149ac4f9510d9cf8cf384038ad348b3bcdc01915f95de12df9d1b02','testing'),
 ('0xe5e14487b78f85faa6e1808e89246cf57dd34831548ff2e6097380d98db2504a','addr'),
 ('0xdec08c9dbbdd0890e300eb5062089b2d4b1c40e3673bbccb5423f7b37dcf9a9c','reverse'),
 ('0x329539a1d23af1810c48a07fe7fc66a3b34fbc8b37e9b3cdb97bb88ceab7e4bf','resolver')
ON CONFLICT (hash) DO NOTHING;
SQL

echo "==> Rainbow table seeded."
