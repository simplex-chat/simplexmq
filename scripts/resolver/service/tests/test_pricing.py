import time
import unittest

from snrc_resolve import abi, answers, config, pricing, registration_status, rpc
from fakes import prices_return


class PricingTests(unittest.TestCase):
    """The oracle keeps the curve in US cents per year, and a lapsed name costs
    the ordinary price: this registry runs no auction."""

    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"
    ORACLE = "0x1e0c9a2b9d1a4c8f7b3e5d6a9c2f4b8e1d7a3c50"

    GRACE = 90 * 86400
    BASE = 200
    EXCEPTIONS = {1: 64000, 2: 16000, 3: 1600, 4: 800, 5: 500}
    MIN_LENGTH = 3

    def setUp(self):
        self._saved = (
            config.REGISTRIES,
            config.REGISTRARS,
            config.CONTROLLERS,
            rpc.eth_call,
            registration_status.chain_now,
        )
        config.REGISTRIES = {"testing": self.REGISTRY}
        config.REGISTRARS = {"testing": self.REGISTRAR}
        config.CONTROLLERS = {"testing": self.CONTROLLER}
        self.now = int(time.time())
        registration_status.chain_now = lambda: self.now

    def tearDown(self):
        (
            config.REGISTRIES,
            config.REGISTRARS,
            config.CONTROLLERS,
            rpc.eth_call,
            registration_status.chain_now,
        ) = self._saved

    def _prices_return(self):
        return prices_return(self.BASE, self.EXCEPTIONS)

    def _chain(self, expires, oracle=None, reserved=0):
        oracle = self.ORACLE if oracle is None else oracle
        self.oracle_calls = []

        def eth_call(to, data):
            if data.startswith(abi.selector("nameExpires(uint256)")):
                return "0x" + abi.encode_uint(expires)
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(self.GRACE)
            if data.startswith(abi.selector("reservedNames(bytes32)")):
                return "0x" + abi.encode_uint(reserved)
            if data.startswith(abi.selector("minCharLength()")):
                self.assertEqual(to, self.CONTROLLER)
                return "0x" + abi.encode_uint(self.MIN_LENGTH)
            if data.startswith(abi.selector("prices()")):
                if to == self.CONTROLLER:
                    return "0x" + abi.encode_uint(int(oracle, 16))
                self.oracle_calls.append(data[:10])
                self.assertEqual(to, oracle)
                return self._prices_return()
            return self.fail("unexpected call " + data[:10])

        return eth_call

    def _lapsed(self, days_past_grace):
        """An expiry whose grace ended `days_past_grace` days ago. The extra
        second clears the boundary, which counts as still in grace."""
        return self.now - self.GRACE - 1 - days_past_grace * 86400

    def test_the_prices_are_the_oracles_cents_per_year(self):
        rpc.eth_call = self._chain(self._lapsed(0))
        reg = registration_status.name_status("acme.testing")
        # 1 and 2 are below minCharLength
        self.assertEqual(reg["registrationPrices"], {3: 1600, 4: 800, 5: 500})
        self.assertEqual(reg["basePrice"], self.BASE)
        self.assertEqual(reg["minLabelLength"], self.MIN_LENGTH)

    def test_a_lapsed_name_costs_the_ordinary_price(self):
        rpc.eth_call = self._chain(self._lapsed(0))
        reg = registration_status.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")

    def test_a_controller_with_no_oracle_leaves_the_name_merely_expired(self):
        rpc.eth_call = self._chain(self._lapsed(0), oracle=abi.ZERO_ADDR)
        self.assertEqual(registration_status.name_status("acme.testing")["status"], "expired")

    def test_a_name_in_grace_never_reaches_the_oracle(self):
        rpc.eth_call = self._chain(self.now - 3600)
        self.assertEqual(registration_status.name_status("acme.testing")["status"], "grace")
        self.assertEqual(self.oracle_calls, [])

    def test_a_reserved_lapsed_name_keeps_its_reservation(self):
        rpc.eth_call = self._chain(self._lapsed(0), reserved=2)
        reg = registration_status.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")
        self.assertEqual(reg["reasonCode"], "trademark")

    def test_resolve_reports_the_prices(self):
        rpc.eth_call = self._chain(self._lapsed(1))
        status, body = answers.resolve("acme.testing")
        self.assertEqual(status, 410)
        self.assertEqual(body["status"], "expired")
        self.assertEqual(body["basePrice"], self.BASE)

    def test_a_hashed_query_is_priced_too(self):
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        rpc.eth_call = self._chain(self._lapsed(0))
        _, body = answers.resolve(hashed + ".testing")
        self.assertEqual(body["status"], "expired")
        self.assertEqual(body["basePrice"], self.BASE)


class EnsOracleTests(unittest.TestCase):
    """.testing runs an ENS-shaped oracle: it prices in attoUSD per second and
    charges a premium on lapsed names that it does not expose."""

    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"
    ORACLE = "0x1e0c9a2b9d1a4c8f7b3e5d6a9c2f4b8e1d7a3c50"
    GRACE = 90 * 86400
    MIN_LENGTH = 6

    def setUp(self):
        self._saved = (config.REGISTRIES, config.REGISTRARS, config.CONTROLLERS, rpc.eth_call, registration_status.chain_now)
        config.REGISTRIES = {"testing": self.REGISTRY}
        config.REGISTRARS = {"testing": self.REGISTRAR}
        config.CONTROLLERS = {"testing": self.CONTROLLER}
        self.now = int(time.time())
        registration_status.chain_now = lambda: self.now

    def tearDown(self):
        (config.REGISTRIES, config.REGISTRARS, config.CONTROLLERS, rpc.eth_call, registration_status.chain_now) = self._saved

    def _chain(self, expires, letter_cents=0):
        def eth_call(to, data):
            if data.startswith(abi.selector("nameExpires(uint256)")):
                return "0x" + abi.encode_uint(expires)
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(self.GRACE)
            if data.startswith(abi.selector("reservedNames(bytes32)")):
                return "0x" + abi.encode_uint(0)
            if data.startswith(abi.selector("minCharLength()")):
                return "0x" + abi.encode_uint(self.MIN_LENGTH)
            if data.startswith(abi.selector("prices()")):
                if to == self.CONTROLLER:
                    return "0x" + abi.encode_uint(int(self.ORACLE, 16))
                raise RuntimeError("eth_call returned 0x")  # no prices() on this oracle
            for n in range(1, 7):
                if data.startswith(abi.selector(f"price{n}Letter()")):
                    rate = letter_cents * pricing.ATTO_PER_CENT // pricing.SECONDS_PER_YEAR
                    return "0x" + abi.encode_uint(rate)
            return self.fail("unexpected call " + data[:10])

        return eth_call

    def test_a_never_registered_name_is_priced_from_the_letter_curve(self):
        rpc.eth_call = self._chain(0)
        reg = registration_status.name_status("ghost.testing")
        self.assertEqual(reg["status"], "unregistered")
        self.assertEqual(reg["basePrice"], 0)
        self.assertEqual(reg["minLabelLength"], self.MIN_LENGTH)

    def test_a_non_zero_letter_curve_converts_to_cents_per_year(self):
        rpc.eth_call = self._chain(0, letter_cents=1200)
        self.assertEqual(registration_status.name_status("ghost.testing")["basePrice"], 1200)

    def test_a_lapsed_name_is_not_priced_because_the_premium_is_unreadable(self):
        rpc.eth_call = self._chain(self.now - self.GRACE - 1)
        reg = registration_status.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")
        self.assertNotIn("basePrice", reg)
