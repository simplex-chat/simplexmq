"""Registration status of a name: expiry, grace, reservation, and the block it was read at."""

import time

from . import config, rpc
from .abi import decode_uint, label_token
from .calls import expires_call, grace_call, reserved_call
from .pricing import pricing_params


# `reservedNames` holds a SimplexController.Reason; 0 means not reserved. A
# controller from before the enum stores a bool, whose `true` decodes as 1,
# which is why 1 reads as "internal".
RESERVED_REASONS = {
    1: ("internal", "reserved for SimpleX"),
    2: ("trademark", "reserved to protect a trademark"),
    3: ("community", "reserved for the community"),
}
# a Reason added to the contract after this resolver: still reserved, unworded
UNKNOWN_REASON = ("unknown", "reserved")


def head_block():
    """How far behind the node is. Unlike expiry, this is the one thing that has
    to be measured against the host clock: a node that stops still has a block."""
    try:
        block = rpc.call(*rpc.BLOCK_READ)
        return {
            "blockNumber": decode_uint(block["number"]),
            "chainLagSeconds": int(time.time()) - decode_uint(block["timestamp"]),
        }
    except Exception:
        return {"blockNumber": None, "chainLagSeconds": None}


def chain_now() -> int:
    """Expiry is compared against the block timestamp, never the host clock."""
    block = rpc.call(*rpc.BLOCK_READ)
    return decode_uint(block["timestamp"])


def grace_period(registrar: str) -> int:
    """A deployment can configure a different window, so it is read on chain."""
    return decode_uint(rpc.eth_call(*grace_call(registrar)))


def expiry_status(expires: int, grace: int, now: int) -> str:
    """The registrar's `available(id)` is not enough on its own: it is also
    true for a name nobody registered, since 0 + GRACE_PERIOD < now."""
    if expires == 0:
        return "unregistered"
    if expires > now:
        return "registered"
    if expires + grace >= now:
        return "grace"
    return "expired"


def reservation_reason(tld: str, token: int) -> int:
    """The SimplexController.Reason held for the name, 0 when not reserved."""
    controller = config.CONTROLLERS.get(tld)
    if not controller:
        return 0
    return decode_uint(rpc.eth_call(*reserved_call(controller, token)))


def name_status(name: str):
    labels = name.split(".")
    tld = labels[-1]
    registrar = config.REGISTRARS.get(tld)
    if not registrar or len(labels) < 2:
        return {
            "status": "unknown",
            # nothing was read, so there is no block to report
            "lastBlockTs": None,
            "expires": None,
            "graceEnds": None,
            "reasonCode": None,
            "reason": None,
        }

    # nameExpires and reservedNames are keyed on uint256(keccak(label)).
    # The 2LD's label is that key at any depth. node_of decodes a bracket only
    # in a two-label name, so a bracket subname gets a status but no record.
    token = label_token(labels[-2])
    expires = decode_uint(rpc.eth_call(*expires_call(registrar, token)))
    grace = grace_period(registrar) if expires else 0
    now = chain_now()
    status = expiry_status(expires, grace, now)

    # A reservation is orthogonal to the registration: a registered name can be
    # held back too.
    code = reservation_reason(tld, token)
    reason = RESERVED_REASONS.get(code, UNKNOWN_REASON) if code else None

    out = {
        "status": status,
        # the block this was read at
        "lastBlockTs": now,
        "expires": expires or None,
        "graceEnds": (expires + grace) if expires else None,
        "reasonCode": reason[0] if reason else None,
        "reason": reason[1] if reason else None,
    }
    if status in ("unregistered", "expired"):
        pricing = pricing_params(tld)
        # a lapsed name may carry a premium this resolver cannot read, and a
        # quote without it would be below what the registry charges
        if pricing and not (status == "expired" and pricing["_premiumUnknown"]):
            out.update({k: v for k, v in pricing.items() if not k.startswith("_")})
    return out
