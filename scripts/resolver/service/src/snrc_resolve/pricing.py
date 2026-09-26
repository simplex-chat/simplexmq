"""What registering a name costs, read from the TLD's price oracle."""

from . import config, rpc
from .abi import ZERO_ADDR, decode_address, decode_uint
from .calls import letter_price_call, min_length_call, prices_call


def pricing_params(tld: str):
    """What it costs to register a name under this TLD, in US cents, or None
    when no controller or price oracle is configured."""
    controller = config.CONTROLLERS.get(tld)
    if not controller:
        return None
    rpc.prefetch([rpc.eth_call_read(*prices_call(controller)), rpc.eth_call_read(*min_length_call(controller))])
    oracle = decode_address(rpc.eth_call(*prices_call(controller)))
    if oracle == ZERO_ADDR:
        return None
    try:
        return read_oracle_prices(controller, oracle)
    except RuntimeError:
        # An oracle that does not expose its curve cannot be quoted from. The
        # name is still registrable; the price is simply not ours to state.
        return None


SECONDS_PER_YEAR = 31536000
# an ENS-shaped oracle prices names by length up to six letters
LETTER_TIERS = range(1, 7)
# The registry prices in attoUSD (1e-18 USD); the protocol carries US cents.
ATTO_PER_CENT = 10**16


def read_oracle_prices(controller: str, oracle: str):
    """SimplexPriceOracle keeps the curve in US cents per year, the unit the SMP
    protocol carries. An ENS-shaped oracle prices in attoUSD per second and
    charges a premium on lapsed names that it does not expose, so a quote from
    it is only safe for a name that was never registered."""
    # either oracle shape is answered in the same round trip
    rpc.prefetch([rpc.eth_call_read(*prices_call(oracle))] + [rpc.eth_call_read(*letter_price_call(oracle, n)) for n in LETTER_TIERS])
    try:
        base, tiers = decode_prices(rpc.eth_call(*prices_call(oracle)))
        premium_unknown = False
    except RuntimeError:
        base, tiers = decode_letter_prices(oracle)
        premium_unknown = True
    min_len = decode_uint(rpc.eth_call(*min_length_call(controller)))
    return {
        # lengths the registry refuses are left out rather than priced at zero
        "registrationPrices": {n: c for n, c in tiers.items() if n >= min_len},
        "basePrice": base,
        "minLabelLength": min_len,
        "_premiumUnknown": premium_unknown,
    }


def decode_letter_prices(oracle: str):
    """`price1Letter()`..`price6Letter()`, in attoUSD per second. Quotes round
    up, so one is never below what the registry charges. An oracle built before
    the six-letter tier stops at five, and charges its highest tier for anything
    longer, which is what basePrice means here."""
    tiers = {}
    for n in LETTER_TIERS:
        try:
            rate = decode_uint(rpc.eth_call(*letter_price_call(oracle, n)))
        except RuntimeError:
            if n <= 5:
                raise
            break
        tiers[n] = ceil_div(rate * SECONDS_PER_YEAR, ATTO_PER_CENT)
    return tiers.pop(max(tiers)), tiers


def ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def decode_prices(hex_data: str):
    """`prices()` returns the base price and the lengths priced differently."""
    raw = bytes.fromhex(hex_data[2:] if hex_data.startswith("0x") else hex_data)
    # a short answer is not a curve: decoding it would quote every name as free
    if len(raw) < 96:
        raise RuntimeError("prices(): short response")
    base = int.from_bytes(raw[:32], "big")
    at = int.from_bytes(raw[32:64], "big")
    count = int.from_bytes(raw[at:at + 32], "big")
    # the count comes from the answer, so it is checked against the answer's length
    if at + 32 + count * 64 > len(raw):
        raise RuntimeError("prices(): short response")
    tiers = {}
    for i in range(count):
        item = at + 32 + i * 64
        length = int.from_bytes(raw[item:item + 32], "big")
        tiers[length] = int.from_bytes(raw[item + 32:item + 64], "big")
    return base, tiers
