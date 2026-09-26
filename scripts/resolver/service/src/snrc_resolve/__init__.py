"""SimpleX Namespace (SNRC) resolver — REST API.

Resolves names like `alice.testing` / `bob.simplex` against the SNRC
deployment on Ethereum mainnet (or any compatible ENS-shaped registry)
and returns a flat JSON document with these fields:

  name, nickname, website, location,
  simplexContact, simplexChannel,    -- list[str], primary first
  eth, btc, xmr, dot,
  owner, resolver

`simplexContact` and `simplexChannel` are arrays so a name can advertise
multiple SMP servers for redundancy. Clients SHOULD try the URLs in the
order returned. The on-chain text record stores them as a single
`LINK_SEPARATOR` (`;`)-joined string; this resolver splits and trims into a list.

All keys are valid Haskell record-field identifiers (lowercase initial,
no dots), so consumers can derive aeson FromJSON instances directly
without a key-rewriting layer.

Usage:
  uv run snrc-resolve                  # serve on :8000, from scripts/resolver/service
  python -m snrc_resolve               # the same, with the package installed

  curl -s http://127.0.0.1:8000/resolve/foobar.testing | jq .
  curl -s 'http://127.0.0.1:8000/resolve/[<64-hex labelhash>].testing' | jq .
  curl -s http://127.0.0.1:8000/health

Environment:
  SNRC_RPC               JSON-RPC endpoint (default: http://127.0.0.1:8545)
  SNRC_REGISTRY_TESTING  ENSRegistry for the .testing deployment
                         (default: mainnet,
                          0x58fc46996d975c57883564648bda5206d1a0102b)
  SNRC_REGISTRY_SIMPLEX  ENSRegistry for the .simplex deployment
                         (default: empty — TLD not yet deployed)
  SNRC_REGISTRAR_<TLD>   BaseRegistrar (ERC-721) for the TLD; expiry and status
                         (default: mainnet for .testing, empty for .simplex)
  SNRC_CONTROLLER_<TLD>  SimplexController (proxy) for the TLD; reservations,
                         and through its `prices()` oracle what registering costs
                         (default: mainnet for .testing, empty for .simplex)
  SNRC_PORT              Listen port (default: 8000)
  SNRC_BIND              Bind address (default: 0.0.0.0)
  SNRC_WORKERS           Worker processes sharing the port (default: CPU count, at most 4)
  SNRC_RPC_TIMEOUT       Seconds to wait for each RPC request (default: 5)
  SNRC_MULTICALL         Multicall3 contract that runs a round of reads as one call
                         (default: 0xcA11bde05977b3631167028862bE2a173976CA11)

Each TLD is a separate SNRC deployment with its own ENSRegistry; the
resolver dispatches by the queried name's rightmost label.

Addresses are returned in each chain's canonical presentation:
  eth  EIP-55 mixed-case checksummed hex      (e.g. 0xEa65A0…1572)
  btc  bech32(m) for segwit/taproot, base58check for P2PKH/P2SH
       (e.g. bc1q…  /  1A1zP1…)
  dot  SS58 with Polkadot network prefix 0    (e.g. 15oF4u…)
  xmr  Monero base58                          (e.g. 4Aux5y…)
Unrecognised payloads fall back to `0x`-prefixed raw hex.
"""
