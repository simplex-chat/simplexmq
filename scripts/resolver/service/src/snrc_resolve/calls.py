"""Contract calls as (to, data), shared by the reads and prefetch, so a prefetched read is found by the code that makes it."""

from .abi import encode_addr_multicoin_call, encode_text_call, encode_uint, selector


# Shared by the reads and prefetch, so a prefetched read is found by the code that makes it.
def expires_call(registrar: str, token: int):
    return registrar, selector("nameExpires(uint256)") + encode_uint(token)


def grace_call(registrar: str):
    return registrar, selector("GRACE_PERIOD()")


def label_call(registrar: str, token: int):
    return registrar, selector("labelOf(uint256)") + encode_uint(token)


def reserved_call(controller: str, token: int):
    return controller, selector("reservedNames(bytes32)") + encode_uint(token)


def prices_call(contract: str):
    return contract, selector("prices()")


def letter_price_call(oracle: str, letters: int):
    return oracle, selector(f"price{letters}Letter()")


def min_length_call(controller: str):
    return controller, selector("minCharLength()")


def resolver_call(registry: str, node: bytes):
    return registry, selector("resolver(bytes32)") + node.hex()


def owner_call(registry: str, node: bytes):
    return registry, selector("owner(bytes32)") + node.hex()


def text_call(resolver: str, node: bytes, key: str):
    return resolver, encode_text_call(node, key)


def addr_call(resolver: str, node: bytes, coin_type: int):
    return resolver, encode_addr_multicoin_call(node, coin_type)
