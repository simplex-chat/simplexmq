"""Settings read from the environment, and the contracts of each TLD."""

import os


RPC = os.environ.get("SNRC_RPC", "http://127.0.0.1:8545")
BIND = os.environ.get("SNRC_BIND", "0.0.0.0")
PORT = int(os.environ.get("SNRC_PORT", "8000"))
# The smp-server gives up after 3 s, so a slower call only holds a thread.
RPC_TIMEOUT_S = float(os.environ.get("SNRC_RPC_TIMEOUT", "") or 5)
# The node and the beacon client usually share the host, so not every core.
MAX_DEFAULT_WORKERS = 4
WORKERS = int(os.environ.get("SNRC_WORKERS", "") or min(MAX_DEFAULT_WORKERS, os.cpu_count() or 1))
# Multicall3, at this address on mainnet and most chains. A node runs a JSON-RPC
# batch one call after another, so a round of reads is sent as one eth_call.
MULTICALL = os.environ.get("SNRC_MULTICALL", "") or "0xcA11bde05977b3631167028862bE2a173976CA11"

# Each TLD is its own SNRC deployment with its own ENSRegistry. Dispatch
# happens on the rightmost label of the queried name. Empty / unset means
# "not deployed" — requests for that TLD return 400 with a clear error.
# `... or "..."` makes these defaults the single source of truth:
# unset AND empty-string both fall through to the literal. docker-compose
# can therefore pass `SNRC_REGISTRY_TESTING=${SNRC_REGISTRY_TESTING:-}`
# without duplicating the registry address.
REGISTRIES = {
    "testing": os.environ.get("SNRC_REGISTRY_TESTING", "")
    or "0x58fc46996d975c57883564648bda5206d1a0102b",  # mainnet .testing
    "simplex": os.environ.get("SNRC_REGISTRY_SIMPLEX", ""),  # not deployed yet
}

REGISTRARS = {
    "testing": os.environ.get("SNRC_REGISTRAR_TESTING", "")
    or "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a",  # mainnet .testing
    "simplex": os.environ.get("SNRC_REGISTRAR_SIMPLEX", ""),  # not deployed yet
}

CONTROLLERS = {
    "testing": os.environ.get("SNRC_CONTROLLER_TESTING", "")
    # Proxy address, not SimplexControllerImpl: storage is held by the proxy.
    # Recorded in deployments.json as ETHRegistrarController.
    or "0xeeb9b6bf5fb68fb726005f7ba549c2f4b32f2dad",  # mainnet .testing
    "simplex": os.environ.get("SNRC_CONTROLLER_SIMPLEX", ""),  # not deployed yet
}
