#!/bin/sh
# Clone the PRIVATE parent repo (brenzi/simplex-namespace-contract) into the
# shared /src volume, then init ONLY the ens-subgraph submodule (the only source
# the stack needs — ens-app-v3 / ens-contracts are skipped). Idempotent: on
# re-run, refresh the submodule rather than re-cloning. GITHUB_TOKEN is read
# from the environment and used only to rewrite https github URLs — never echoed
# or written to disk beyond git's own config inside this throwaway container.
set -eu

REPO_URL="https://github.com/brenzi/simplex-namespace-contract.git"
SUBMODULE="ens-subgraph"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN is not set" >&2
  exit 1
fi

# Authenticate github https fetches (parent repo + the ens-subgraph submodule)
# via the x-access-token scheme. insteadOf rewrites every https://github.com/ URL.
git config --global \
  url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf \
  "https://github.com/"

if [ -d /src/.git ]; then
  echo "Parent repo already present — updating ${SUBMODULE}..."
  git -C /src submodule update --init "$SUBMODULE"
else
  echo "Cloning parent repo (no submodules)..."
  git clone "$REPO_URL" /src
  echo "Initializing ${SUBMODULE} submodule only..."
  git -C /src submodule update --init "$SUBMODULE"
fi

echo "Source tree ready at /src (subgraph at /src/${SUBMODULE})"
