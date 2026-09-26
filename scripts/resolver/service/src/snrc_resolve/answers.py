"""The /v2/resolve registration and the /v1 /resolve record."""

import logging

from . import config, log, rpc
from .abi import ZERO_ADDR, decode_address, is_encoded_labelhash, label_token, node_of
from .calls import expires_call, grace_call, label_call, owner_call, reserved_call, resolver_call
from .coins import COIN_BTC, COIN_DOT, COIN_ETH, COIN_XMR
from .pricing import pricing_params
from .records import TEXT_KEYS, addr_multicoin, canonical_name, name_record, record_reads, split_links, text
from .registration_status import name_status


def lookup_reads(name: str):
    """The reads a lookup makes before it knows the name's resolver."""
    labels = name.split(".")
    tld = labels[-1]
    reads = []
    registrar = config.REGISTRARS.get(tld)
    if registrar and len(labels) >= 2:
        token = label_token(labels[-2])
        reads += [rpc.BLOCK_READ, rpc.eth_call_read(*expires_call(registrar, token)), rpc.eth_call_read(*grace_call(registrar))]
        if len(labels) == 2 and is_encoded_labelhash(labels[0]):
            reads.append(rpc.eth_call_read(*label_call(registrar, token)))
        if config.CONTROLLERS.get(tld):
            reads.append(rpc.eth_call_read(*reserved_call(config.CONTROLLERS[tld], token)))
    registry = config.REGISTRIES.get(tld)
    if registry:
        node = node_of(name)
        reads += [rpc.eth_call_read(*resolver_call(registry, node)), rpc.eth_call_read(*owner_call(registry, node))]
    return reads


def upstream_error(subject: dict, e: Exception) -> dict:
    """The exception can carry the failing URL and SNRC_RPC can carry a provider
    key, so the text goes to the log and only the type to the caller."""
    log.event(logging.WARNING, "upstream_error", **subject, error=type(e).__name__, message=str(e))
    return {
        **subject,
        "error": "upstreamError",
        "message": f"upstream RPC failed ({type(e).__name__})",
    }


def name_response(reg, registration_body):
    """The SMP protocol's NameResponse: the registration and the block read at."""
    return 200, {"lastBlockTs": reg["lastBlockTs"], "registration": registration_body}


def registration(name: str):
    """The SMP protocol's NameRegistration, which the relay decodes as is.
    Translating the contract's model to it is this resolver's job."""
    tld = name.rsplit(".", 1)[-1]
    if not config.REGISTRIES.get(tld):
        return 400, {"name": name, "error": "tldNotConfigured"}
    rpc.prefetch(lookup_reads(name))
    reg = name_status(name)
    status = reg["status"]
    if status in ("registered", "grace"):
        rec = name_record(name)
        # the client checks that the record names what it asked about, so a
        # hashed query the registrar cannot name is refused rather than answered
        if rec["name"] is None:
            return 502, {"name": name, "error": "labelNotRecorded"}
        # a subname inherits the 2LD's status, so only its node's owner says
        # whether anyone created it
        if len(name.split(".")) > 2 and rec["owner"] == ZERO_ADDR:
            # name_status reads pricing only when the name was already
            # unregistered, so read it here
            status = "unregistered"
            pricing = pricing_params(tld)
            if pricing:
                reg.update({k: v for k, v in pricing.items() if not k.startswith("_")})
        else:
            return name_response(reg, {
                "type": "registered",
                "expires": reg["expires"],
                "graceUntil": reg["graceEnds"],
                "reservedReason_": reg["reasonCode"],
                "nameRecord": rec,
            })
    if reg["reasonCode"]:
        return name_response(reg, {"type": "reserved", "reservedReason": reg["reasonCode"]})
    if status in ("unregistered", "expired"):
        if "basePrice" not in reg:
            return 502, {"name": name, "error": "noPriceOracle"}
        return name_response(reg, {
            "type": "available",
            "pricing": {
                "registrationPrices": reg["registrationPrices"],
                "basePrice": reg["basePrice"],
                "minLabelLength": reg["minLabelLength"],
            },
        })
    return 502, {"name": name, "error": status}


def resolve(name: str):
    tld = name.rsplit(".", 1)[-1]
    registry = config.REGISTRIES.get(tld)
    if not registry:
        configured = [k for k, v in config.REGISTRIES.items() if v]
        return 400, {
            "name": name,
            "error": "tldNotConfigured",
            "message": f"TLD '{tld}' is not configured on this resolver",
            "configuredTlds": configured,
        }

    node = node_of(name)
    rpc.prefetch(lookup_reads(name))

    # Before the resolver lookup, so a lapsed name is not reported as noResolver.
    reg = name_status(name)
    if reg["status"] in ("unregistered", "expired"):
        # A name in grace is not here: its record still resolves.
        body = {
            "name": name,
            **reg,
            "error": reg["status"],
            "message": (
                "this name has never been registered"
                if reg["status"] == "unregistered"
                else "this registration expired and is open to anyone"
            ),
        }
        return (404 if reg["status"] == "unregistered" else 410), body

    resolver_addr = decode_address(rpc.eth_call(*resolver_call(registry, node)))
    if resolver_addr == ZERO_ADDR:
        # A registered name always resolves: with no resolver set the record is
        # still returned with every field unset, so "taken until <date>" stays
        # answerable. For a subname, no owner means nobody created it.
        owner = decode_address(rpc.eth_call(*owner_call(registry, node)))
        if len(name.split(".")) > 2 and owner == ZERO_ADDR:
            return 404, {
                "name": name,
                **reg,
                "status": "unregistered",
                "error": "unregistered",
                "message": "this subname has never been created",
            }
        return 200, {
            "name": canonical_name(name) or name,
            "nickname": "",
            "website": "",
            "location": "",
            "simplexContact": [],
            "simplexChannel": [],
            "eth": None,
            "btc": None,
            "xmr": None,
            "dot": None,
            "owner": owner,
            "resolver": ZERO_ADDR,
            **reg,
        }

    owner = decode_address(rpc.eth_call(*owner_call(registry, node)))

    rpc.prefetch(record_reads(resolver_addr, node))
    texts = {}
    for k in TEXT_KEYS:
        try:
            v = text(resolver_addr, node, k)
        except RuntimeError:
            v = ""
        if v:
            texts[k] = v

    # The user-facing "nickname" prefers an explicit `nickname` record,
    # falls back to `name`, then `description` (ENSIP-5 convention).
    nickname = texts.get("nickname") or texts.get("name") or texts.get("description") or ""

    # Keys chosen to be valid Haskell record-field identifiers (lowercase
    # initial, no dots) so consumers can derive aeson FromJSON instances
    # without a key-rewriting layer. On-chain text-record names still
    # use the ENSIP-5 dot convention (e.g. "simplex.contact") — only the
    # resolver's JSON surface camelCases them.
    return 200, {
        "name": canonical_name(name) or name,
        "nickname": nickname,
        "website": texts.get("url", ""),
        "location": texts.get("location", ""),
        "simplexContact": split_links(texts.get("simplex.contact", "")),
        "simplexChannel": split_links(texts.get("simplex.channel", "")),
        "eth": addr_multicoin(resolver_addr, node, COIN_ETH),
        "btc": addr_multicoin(resolver_addr, node, COIN_BTC),
        "xmr": addr_multicoin(resolver_addr, node, COIN_XMR),
        "dot": addr_multicoin(resolver_addr, node, COIN_DOT),
        "owner": owner,
        "resolver": resolver_addr,
        **reg,
    }
