import time
import unittest

from snrc_resolve import abi, answers, config, registration_status, rpc
from fakes import abi_bytes, prices_return, registration


class ErrorCodeTests(unittest.TestCase):
    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"

    def setUp(self):
        self._saved = (
            config.REGISTRIES,
            config.REGISTRARS,
            config.CONTROLLERS,
            rpc.eth_call,
            registration_status.chain_now,
        )
        config.REGISTRIES = {"testing": self.REGISTRY, "simplex": ""}
        config.REGISTRARS = {"testing": self.REGISTRAR}
        config.CONTROLLERS = {"testing": ""}
        registration_status.chain_now = lambda: int(time.time())

    def tearDown(self):
        (
            config.REGISTRIES,
            config.REGISTRARS,
            config.CONTROLLERS,
            rpc.eth_call,
            registration_status.chain_now,
        ) = self._saved

    def _chain(self, expires, resolver=None):
        def eth_call(to, data):
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(90 * 86400)
            if data.startswith(abi.selector("resolver(bytes32)")):
                return "0x" + "00" * 12 + (resolver or "00" * 20)
            return "0x" + abi.encode_uint(expires)

        return eth_call

    def test_an_unconfigured_tld_names_the_ones_that_are(self):
        status, body = answers.resolve("alice.nosuchtld")
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "tldNotConfigured")
        self.assertEqual(body["configuredTlds"], ["testing"])
        self.assertIn("nosuchtld", body["message"])

    def test_a_registration_problem_reports_the_status_as_the_code(self):
        for expires, code in (
            (0, "unregistered"),
            (int(time.time()) - 91 * 86400, "expired"),
        ):
            with self.subTest(code=code):
                rpc.eth_call = self._chain(expires)
                _, body = answers.resolve("alice.testing")
                self.assertEqual(body["error"], code)
                self.assertEqual(body["status"], code)

    def test_a_name_in_grace_still_resolves(self):
        rpc.eth_call = self._chain(int(time.time()) - 3600)
        status, body = answers.resolve("alice.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "grace")
        self.assertNotIn("error", body)

    def test_a_registered_name_pointing_nowhere_resolves_with_empty_records(self):
        rpc.eth_call = self._chain(int(time.time()) + 86400)
        status, body = answers.resolve("alice.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "registered")
        self.assertEqual(body["resolver"], abi.ZERO_ADDR)
        self.assertEqual(body["simplexContact"], [])

    def test_every_error_body_carries_both_fields(self):
        rpc.eth_call = self._chain(0)
        for name in ("alice.nosuchtld", "alice.testing"):
            with self.subTest(name=name):
                _, body = answers.resolve(name)
                self.assertIsInstance(body["error"], str)
                self.assertIsInstance(body["message"], str)
                self.assertNotEqual(body["error"], body["message"])

    def test_an_upstream_failure_does_not_echo_the_exception(self):
        with self.assertLogs("snrc_resolve", "WARNING") as logs:
            body = answers.upstream_error(
                {"name": "alice.testing"},
                RuntimeError("http://user:secret@rpc.example/kEy8 refused"),
            )
        # the operator still sees the detail in the log
        [record] = logs.records
        self.assertEqual(record.getMessage(), "upstream_error")
        self.assertEqual(record.fields["name"], "alice.testing")
        self.assertEqual(record.fields["error"], "RuntimeError")
        self.assertIn("secret", record.fields["message"])
        self.assertEqual(body["error"], "upstreamError")
        self.assertIn("RuntimeError", body["message"])
        self.assertNotIn("secret", body["message"])
        self.assertNotIn("kEy8", body["message"])


class RegistrationV2Tests(unittest.TestCase):
    """`/v2/resolve` answers with the SMP protocol's NameRegistration, which the
    relay decodes as is. The key names are the wire contract, so they are pinned
    here: renaming one without the Haskell side is a silent break."""

    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"
    ORACLE = "0x1e0c9a2b9d1a4c8f7b3e5d6a9c2f4b8e1d7a3c50"
    OWNER = "0xd83bd7e0e6b8a4c1f2593a7b0c4e8d1a6f9b2c37"

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

    _abi_bytes = staticmethod(abi_bytes)

    def _chain(self, expires, reserved=0, oracle=None, label=b"acme", owner=None):
        """The registry answers a zero resolver, so name_record returns the
        empty record a registered name still has. `label` is what the registrar
        recorded for the 2LD; b"" means it recorded none. `owner` is the owner of
        the queried node; ZERO_ADDR means that node was never created."""
        oracle = self.ORACLE if oracle is None else oracle
        owner = self.OWNER if owner is None else owner

        def eth_call(to, data):
            if data.startswith(abi.selector("labelOf(uint256)")):
                return self._abi_bytes(label)
            if data.startswith(abi.selector("nameExpires(uint256)")):
                return "0x" + abi.encode_uint(expires)
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(self.GRACE)
            if data.startswith(abi.selector("reservedNames(bytes32)")):
                return "0x" + abi.encode_uint(reserved)
            if data.startswith(abi.selector("minCharLength()")):
                return "0x" + abi.encode_uint(self.MIN_LENGTH)
            if data.startswith(abi.selector("prices()")):
                if to == self.CONTROLLER:
                    return "0x" + abi.encode_uint(int(oracle, 16))
                return self._prices_return()
            if data.startswith(abi.selector("resolver(bytes32)")):
                return "0x" + abi.encode_uint(0)
            if data.startswith(abi.selector("owner(bytes32)")):
                return "0x" + abi.encode_uint(int(owner, 16))
            return self.fail("unexpected call " + data[:10])

        return eth_call

    def _lapsed(self, days_past_grace):
        return self.now - self.GRACE - 1 - days_past_grace * 86400

    def test_a_live_name_is_registered_and_carries_its_record(self):
        expires = self.now + 3600
        rpc.eth_call = self._chain(expires)
        status, body = registration("acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "registered")
        self.assertEqual(body["expires"], expires)
        self.assertEqual(body["graceUntil"], expires + self.GRACE)
        self.assertIsNone(body["reservedReason_"])
        self.assertEqual(body["nameRecord"]["name"], "acme.testing")

    def test_a_name_in_grace_is_still_registered(self):
        expires = self.now - 3600
        rpc.eth_call = self._chain(expires)
        _, body = registration("acme.testing")
        self.assertEqual(body["type"], "registered")
        self.assertGreater(body["graceUntil"], self.now)

    def test_a_registered_name_that_is_held_back_says_so(self):
        rpc.eth_call = self._chain(self.now + 3600, reserved=1)
        _, body = registration("acme.testing")
        self.assertEqual(body["type"], "registered")
        self.assertEqual(body["reservedReason_"], "internal")

    def test_an_unregistered_name_is_available_with_its_pricing(self):
        rpc.eth_call = self._chain(0)
        status, body = registration("acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "available")
        # lengths below minCharLength are unregistrable, so they are not priced
        self.assertEqual(body["pricing"]["registrationPrices"], {3: 1600, 4: 800, 5: 500})
        self.assertEqual(body["pricing"]["basePrice"], self.BASE)
        self.assertEqual(body["pricing"]["minLabelLength"], self.MIN_LENGTH)

    def test_a_lapsed_name_is_available_at_the_ordinary_price(self):
        rpc.eth_call = self._chain(self._lapsed(1))
        _, body = registration("acme.testing")
        self.assertEqual(body["type"], "available")
        self.assertEqual(body["pricing"]["basePrice"], self.BASE)

    def test_a_held_back_name_is_reserved_and_is_never_priced(self):
        rpc.eth_call = self._chain(0, reserved=2)
        status, body = registration("acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "reserved")
        self.assertEqual(body["reservedReason"], "trademark")
        self.assertNotIn("pricing", body)

    def test_a_hashed_query_answers_the_same_as_the_name(self):
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        rpc.eth_call = self._chain(0)
        _, by_name = registration("acme.testing")
        _, by_hash = registration(hashed + ".testing")
        self.assertEqual(by_name, by_hash)

    def test_an_unconfigured_tld_is_refused_not_answered(self):
        config.REGISTRIES = {"testing": ""}
        rpc.eth_call = lambda *a: self.fail("must not reach the chain")
        status, body = registration("acme.testing")
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "tldNotConfigured")

    def test_no_price_oracle_is_an_error_not_a_free_name(self):
        rpc.eth_call = self._chain(0, oracle=abi.ZERO_ADDR)
        status, body = registration("acme.testing")
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "noPriceOracle")

    def test_a_status_it_cannot_read_is_an_error_not_a_registration(self):
        config.REGISTRARS = {"testing": ""}
        rpc.eth_call = self._chain(0)
        status, body = registration("acme.testing")
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "unknown")

    def test_each_answer_carries_exactly_its_own_fields(self):
        """The relay decodes by these names; an extra or missing one is a break."""
        cases = {
            "registered": (self._chain(self.now + 3600),
                           {"type", "expires", "graceUntil", "reservedReason_", "nameRecord"}),
            "available": (self._chain(0), {"type", "pricing"}),
            "reserved": (self._chain(0, reserved=1), {"type", "reservedReason"}),
        }
        for expected_type, (chain, keys) in cases.items():
            with self.subTest(type=expected_type):
                rpc.eth_call = chain
                _, body = registration("acme.testing")
                self.assertEqual(body["type"], expected_type)
                self.assertEqual(set(body), keys)
    def test_a_hashed_query_the_registrar_cannot_name_is_refused(self):
        """The client checks the record names what it asked about, so answering
        with a record the registrar could not name would only fail there."""
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        rpc.eth_call = self._chain(self.now + 3600, label=b"")
        status, body = registration(hashed + ".testing")
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "labelNotRecorded")

    def test_a_hashed_query_is_answered_with_the_name_the_registrar_recorded(self):
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        rpc.eth_call = self._chain(self.now + 3600)
        status, body = registration(hashed + ".testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["nameRecord"]["name"], "acme.testing")
    def test_a_subname_that_exists_is_registered_with_its_parents_dates(self):
        expires = self.now + 3600
        rpc.eth_call = self._chain(expires)
        status, body = registration("sub.acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "registered")
        self.assertEqual(body["expires"], expires)
        self.assertEqual(body["nameRecord"]["name"], "sub.acme.testing")

    def test_a_subname_nobody_created_is_not_registered(self):
        """The registrar only tracks 2LDs, so the parent's registration says
        nothing about a child that was never created: its node has no owner."""
        rpc.eth_call = self._chain(self.now + 3600, owner=abi.ZERO_ADDR)
        status, body = registration("sub.acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "available")

    def test_a_2ld_is_not_subject_to_the_owner_check(self):
        """Only a subname can be absent under a registered parent."""
        rpc.eth_call = self._chain(self.now + 3600, owner=abi.ZERO_ADDR)
        _, body = registration("acme.testing")
        self.assertEqual(body["type"], "registered")

    def test_v1_does_not_report_an_uncreated_subname_as_registered(self):
        """v1 has no availability, so the only honest answer is not-found. The
        2LD case is untouched: a registered name with no resolver still resolves."""
        rpc.eth_call = self._chain(self.now + 3600, owner=abi.ZERO_ADDR)
        status, body = answers.resolve("sub.acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "unregistered")

    def test_v1_still_resolves_a_2ld_with_no_resolver_set(self):
        rpc.eth_call = self._chain(self.now + 3600, owner=abi.ZERO_ADDR)
        status, body = answers.resolve("acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["resolver"], abi.ZERO_ADDR)

    def test_the_answer_says_which_block_it_was_read_at(self):
        """The resolver is only as current as its node. Without this a client
        cannot tell an answer that predates its own registration."""
        rpc.eth_call = self._chain(self.now + 3600)
        _, res = answers.registration("acme.testing")
        self.assertEqual(res["lastBlockTs"], self.now)
        self.assertEqual(res["registration"]["type"], "registered")

    def test_an_available_name_says_so_too(self):
        """This is the path that reads no block otherwise, and the one where
        staleness matters most: the name may already be taken."""
        rpc.eth_call = self._chain(0)
        _, res = answers.registration("acme.testing")
        self.assertEqual(res["lastBlockTs"], self.now)
        self.assertEqual(res["registration"]["type"], "available")
