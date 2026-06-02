# Ethereum stack for SMP names role

Reth (execution) + Nimbus (consensus) on Holesky testnet by default.

## Quickstart

```sh
cd scripts/docker/reth-nimbus
docker compose up -d
docker compose logs -f reth nimbus
```

Sync takes a few hours on Holesky, ~1 day on mainnet. When synced:

```sh
curl -s -X POST http://127.0.0.1:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

Point smp-server: `[NAMES] ethereum_endpoint: http://127.0.0.1:8545`.

## How the trust bootstrap works

- **Reth** holds Ethereum state and runs the EVM. It does not decide which fork is canonical.
- **Nimbus** follows the beacon chain and tells Reth which payloads to execute.
- Nimbus needs **one trusted starting point** to break the chicken-and-egg of peer-claims. `--trusted-node-url` fetches that checkpoint once from a public beacon API; from that point on every block is verified locally against the validator set.
- The default `TRUSTED_NODE_URL` is publicnode.com (no API key, no rate limits). Replace with any beacon API you trust — only consulted once on first sync.

## Switching to mainnet

Edit `.env`:

```
NETWORK=mainnet
TRUSTED_NODE_URL=https://ethereum-beacon-api.publicnode.com
```

Then `docker compose down -v && docker compose up -d` (the `-v` wipes state so Nimbus re-bootstraps against the new network). Reth on mainnet needs ~260 GB pruned NVMe.

## Notes

- Reth's RPC is bound to `127.0.0.1:8545` only. For remote access (multiple smp-server hosts → one Reth), put Caddy + Let's Encrypt + Basic auth in front — see `plans/20260522_01_smp_public_namespaces.md` §"Operator deployment".
- Ports 30303/9000 are p2p — open on your firewall for sync.
- `jwt.hex` is generated on first run by the `jwt-init` service and shared between Reth and Nimbus via the `jwt` volume.
- To wipe state and re-sync: `docker compose down -v`.
