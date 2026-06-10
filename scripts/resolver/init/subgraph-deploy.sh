#!/usr/bin/env bash
# Build + deploy the SNRC subgraph to the in-stack graph-node. Automates
# docs/subgraph-local.md (parent repo) step 2. Runs on a stock node image with
# this script mounted; the subgraph source is volume-cloned at runtime, so
# install/codegen/deploy happen here. URLs are overridden to the compose-
# internal graph-node / ipfs hosts (the package.json scripts target 127.0.0.1).
# The rainbow-table seed is a separate one-shot (rainbow-seed.sh) on the
# postgres image, which already has psql.
set -euo pipefail

GRAPH_NODE="http://graph-node:8020"
IPFS_URL="http://ipfs:5001"
SLUG="graphprotocol/ens"
VERSION="0.0.1"
DIR="/src/ens-subgraph"
GRAPH="./node_modules/.bin/graph"   # project-pinned graph-cli (devDependency)

# Pin Yarn classic: the subgraph has a yarn.lock but no packageManager field, so
# corepack would otherwise default to berry (which rejects --frozen-lockfile).
corepack enable
corepack prepare yarn@1.22.22 --activate

echo "==> Waiting for $DIR and graph-node admin ($GRAPH_NODE)"
for _ in $(seq 1 120); do
  if [ -d "$DIR" ] && curl -fs -o /dev/null "$GRAPH_NODE"; then break; fi
  sleep 5
done
[ -d "$DIR" ] || { echo "ERROR: $DIR missing (src-clone failed?)" >&2; exit 1; }

cd "$DIR"

echo "==> yarn install (cached in the src volume after first run)"
# Honour the committed lockfile; fail loudly if it has drifted (don't silently
# mutate it — that would hide a real problem and break reproducibility).
yarn install --frozen-lockfile

echo "==> graph codegen"
yarn codegen   # the project's own script (incl. --output-dir)

echo "==> graph create $SLUG"
# Idempotent: tolerate only the benign 're-run, already created' case; any
# other failure (admin unreachable, auth, …) is real and must stop the script.
if ! "$GRAPH" create "$SLUG" --node "$GRAPH_NODE" >/tmp/create.log 2>&1; then
  if grep -qi "already exists" /tmp/create.log; then
    echo "    subgraph already created — continuing"
  else
    cat /tmp/create.log >&2
    echo "ERROR: graph create failed" >&2
    exit 1
  fi
fi

echo "==> graph deploy $SLUG"
"$GRAPH" deploy "$SLUG" --ipfs "$IPFS_URL" --node "$GRAPH_NODE/" --version-label "$VERSION"

echo "==> Subgraph deployed. GraphQL: http://localhost:8000/subgraphs/name/$SLUG"
echo "    (rainbow table was seeded by the rainbow-seed one-shot beforehand)"
