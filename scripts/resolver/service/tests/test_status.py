import time
import unittest

from snrc_resolve import abi, answers, config, registration_status, rpc


class NameStatusTests(unittest.TestCase):
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"

    GRACE = 90 * 86400

    def _expiry(self, value):
        def eth_call(to, data):
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(self.GRACE)
            self.assertTrue(data.startswith(abi.selector("nameExpires(uint256)")))
            return "0x" + abi.encode_uint(value)

        return eth_call

    def _keys(self, status, expires, grace_ends, read_at=-1):
        """Every branch answers with the same keys; only some carry values."""
        return {
            "status": status,
            "lastBlockTs": self.now if read_at == -1 else read_at,
            "expires": expires,
            "graceEnds": grace_ends,
            "reasonCode": None,
            "reason": None,
        }

    def setUp(self):
        self._saved = (
            config.REGISTRARS,
            config.CONTROLLERS,
            rpc.eth_call,
            registration_status.chain_now,
            rpc.call,
        )
        config.REGISTRARS = {"testing": self.REGISTRAR}
        # Expiry alone; ReservedTests covers a configured controller.
        config.CONTROLLERS = {"testing": ""}
        self.now = int(time.time())
        registration_status.chain_now = lambda: self.now

    def tearDown(self):
        (
            config.REGISTRARS,
            config.CONTROLLERS,
            rpc.eth_call,
            registration_status.chain_now,
            rpc.call,
        ) = self._saved

    def test_now_is_the_latest_blocks_timestamp(self):
        # setUp replaced chain_now with the fixture clock; test the real one
        real_chain_now = self._saved[3]
        rpc.call = lambda method, params: {"timestamp": "0x65f1a2c0", "number": "0x123"}
        self.assertEqual(real_chain_now(), 0x65F1A2C0)

    def test_status_reads_the_chain_clock_not_the_host_clock(self):
        future = int(time.time()) + 3600
        rpc.eth_call = self._expiry(future)
        self.assertEqual(registration_status.name_status("alice.testing")["status"], "registered")
        registration_status.chain_now = lambda: future + 3650 * 86400
        self.assertEqual(registration_status.name_status("alice.testing")["status"], "expired")

    def test_a_registrar_that_is_not_a_contract_is_an_error_not_a_free_name(self):
        """An address with no code answers eth_call with empty data. Read as
        zero, that would make every name look free."""
        rpc.eth_call = self._saved[2]  # the real one, so its guard runs
        rpc.call = lambda method, params: "0x"
        with self.assertRaises(RuntimeError):
            registration_status.name_status("alice.testing")

    def test_zero_expiry_means_never_registered(self):
        rpc.eth_call = self._expiry(0)
        self.assertEqual(
            registration_status.name_status("alice.testing"),
            self._keys("unregistered", None, None),
        )

    def test_recently_expired_is_in_grace_and_says_when_it_ends(self):
        past = int(time.time()) - 3600
        rpc.eth_call = self._expiry(past)
        self.assertEqual(
            registration_status.name_status("alice.testing"),
            self._keys("grace", past, past + self.GRACE),
        )

    def test_past_the_grace_window_it_is_expired_and_claimable(self):
        past = int(time.time()) - self.GRACE - 3600
        rpc.eth_call = self._expiry(past)
        self.assertEqual(registration_status.name_status("alice.testing")["status"], "expired")

    def test_the_boundary_belongs_to_grace(self):
        """The registrar frees a name only when expires + GRACE < now."""
        now = int(time.time())
        rpc.eth_call = self._expiry(now - self.GRACE)
        self.assertEqual(registration_status.name_status("alice.testing")["status"], "grace")

    def test_future_expiry_is_registered(self):
        future = int(time.time()) + 3600
        rpc.eth_call = self._expiry(future)
        self.assertEqual(
            registration_status.name_status("alice.testing"),
            self._keys("registered", future, future + self.GRACE),
        )

    def test_never_registered_is_not_confused_with_claimable(self):
        """`available(id)` is true for both, since 0 + GRACE < now."""
        rpc.eth_call = self._expiry(0)
        self.assertEqual(registration_status.name_status("alice.testing")["status"], "unregistered")
        self.assertNotEqual(registration_status.name_status("alice.testing")["status"], "expired")

    def test_a_subname_reports_the_status_of_its_2ld(self):
        future = int(time.time()) + 3600
        seen = []

        def eth_call(to, data):
            seen.append(data)
            return "0x" + abi.encode_uint(future)

        rpc.eth_call = eth_call
        self.assertEqual(registration_status.name_status("x.alice.testing")["status"], "registered")
        # the token asked about is keccak("alice"), not keccak("x")
        self.assertTrue(seen[0].endswith(abi.keccak(b"alice").hex()))

    def test_a_hashed_2ld_is_queried_by_its_hash_at_any_depth(self):
        """The token must come from the hash, not from hashing the brackets."""
        seen = []

        def eth_call(to, data):
            seen.append(data)
            return "0x" + abi.encode_uint(0)

        rpc.eth_call = eth_call
        hashed = "[" + abi.keccak(b"alice").hex() + "]"
        registration_status.name_status("x." + hashed + ".testing")
        self.assertTrue(seen[0].endswith(abi.keccak(b"alice").hex()))

    def test_unconfigured_tld_is_unknown_rather_than_unregistered(self):
        config.REGISTRARS = {"testing": ""}
        rpc.eth_call = lambda *a: self.fail("must not reach the chain")
        self.assertEqual(
            registration_status.name_status("alice.testing"),
            self._keys("unknown", None, None, read_at=None),
        )

    def test_every_branch_returns_the_same_keys(self):
        keys = {
            "status",
            "lastBlockTs",
            "expires",
            "graceEnds",
            "reasonCode",
            "reason",
        }
        rpc.eth_call = self._expiry(0)
        self.assertEqual(set(registration_status.name_status("alice.testing")), keys)
        rpc.eth_call = self._expiry(int(time.time()) + 3600)
        self.assertEqual(set(registration_status.name_status("alice.testing")), keys)
        config.REGISTRARS = {"testing": ""}
        rpc.eth_call = lambda *a: self.fail("must not reach the chain")
        self.assertEqual(set(registration_status.name_status("alice.testing")), keys)


class ReservedTests(unittest.TestCase):
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"

    def setUp(self):
        self._saved = (config.REGISTRARS, config.CONTROLLERS, rpc.eth_call, registration_status.chain_now)
        config.REGISTRARS = {"testing": self.REGISTRAR}
        config.CONTROLLERS = {"testing": self.CONTROLLER}
        registration_status.chain_now = lambda: int(time.time())

    def tearDown(self):
        config.REGISTRARS, config.CONTROLLERS, rpc.eth_call, registration_status.chain_now = self._saved

    def _chain(self, expires, reserved):
        def eth_call(to, data):
            if data.startswith(abi.selector("reservedNames(bytes32)")):
                self.assertEqual(to, self.CONTROLLER)
                return "0x" + abi.encode_uint(1 if reserved else 0)
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(90 * 86400)
            if data.startswith(abi.selector("prices()")):
                return "0x" + abi.encode_uint(0)  # no price oracle, no auction
            return "0x" + abi.encode_uint(expires)

        return eth_call

    def test_unregistered_and_reserved_reports_the_reservation(self):
        rpc.eth_call = self._chain(0, True)
        reg = registration_status.name_status("acme.testing")
        self.assertEqual(reg["status"], "unregistered")
        self.assertEqual(reg["reasonCode"], "internal")

    def test_unregistered_and_not_reserved_reads_unregistered(self):
        rpc.eth_call = self._chain(0, False)
        self.assertEqual(registration_status.name_status("acme.testing")["status"], "unregistered")

    def test_a_lapsed_reserved_name_keeps_its_reservation(self):
        past = int(time.time()) - 91 * 86400
        rpc.eth_call = self._chain(past, True)
        reg = registration_status.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")
        self.assertEqual(reg["reasonCode"], "internal")

    def test_a_live_name_is_registered_even_if_reserved(self):
        rpc.eth_call = self._chain(int(time.time()) + 86400, True)
        self.assertEqual(registration_status.name_status("acme.testing")["status"], "registered")

    def test_a_name_in_grace_belongs_to_its_owner_not_the_reserved_set(self):
        rpc.eth_call = self._chain(int(time.time()) - 3600, True)
        self.assertEqual(registration_status.name_status("acme.testing")["status"], "grace")

    def test_no_controller_configured_means_reserved_is_never_reported(self):
        config.CONTROLLERS = {"testing": ""}
        rpc.eth_call = self._chain(0, True)  # reserved on chain, but unread
        self.assertEqual(registration_status.name_status("acme.testing")["status"], "unregistered")

    def test_reserved_is_asked_by_labelhash_so_a_hashed_query_works(self):
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        rpc.eth_call = self._chain(0, True)
        self.assertEqual(registration_status.name_status(hashed + ".testing")["reasonCode"], "internal")


class ReservedReasonTests(unittest.TestCase):
    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"

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
        registration_status.chain_now = lambda: int(time.time())

    def tearDown(self):
        (
            config.REGISTRIES,
            config.REGISTRARS,
            config.CONTROLLERS,
            rpc.eth_call,
            registration_status.chain_now,
        ) = self._saved

    def _chain(self, expires, reserved):
        def eth_call(to, data):
            if data.startswith(abi.selector("reservedNames(bytes32)")):
                return "0x" + abi.encode_uint(1 if reserved else 0)
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(90 * 86400)
            if data.startswith(abi.selector("prices()")):
                return "0x" + abi.encode_uint(0)  # no price oracle, no auction
            return "0x" + abi.encode_uint(expires)

        return eth_call

    def _reserved_as(self, code):
        def eth_call(to, data):
            if data.startswith(abi.selector("reservedNames(bytes32)")):
                return "0x" + abi.encode_uint(code)
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(90 * 86400)
            if data.startswith(abi.selector("prices()")):
                return "0x" + abi.encode_uint(0)
            return "0x" + abi.encode_uint(0)

        return eth_call

    def test_every_enum_value_has_a_code_and_a_sentence(self):
        for code, (name, sentence) in registration_status.RESERVED_REASONS.items():
            rpc.eth_call = self._reserved_as(code)
            reg = registration_status.name_status("acme.testing")
            self.assertEqual(reg["reasonCode"], name)
            self.assertEqual(reg["reason"], sentence)

    def test_a_trademark_reservation_says_so(self):
        rpc.eth_call = self._reserved_as(2)
        _, body = answers.resolve("acme.testing")
        self.assertEqual(body["reasonCode"], "trademark")

    def test_a_controller_storing_a_bool_reads_as_internal(self):
        """Before the enum `reservedNames` was a bool; its `true` decodes as 1."""
        rpc.eth_call = self._reserved_as(1)
        reg = registration_status.name_status("acme.testing")
        self.assertEqual(reg["reasonCode"], "internal")
        self.assertEqual(reg["reason"], "reserved for SimpleX")

    def test_an_enum_value_this_resolver_predates_is_not_dropped(self):
        """A new Reason still reserves the name, and says it is unknown rather
        than claiming the chain recorded none."""
        rpc.eth_call = self._reserved_as(99)
        reg = registration_status.name_status("acme.testing")
        self.assertEqual(reg["reasonCode"], "unknown")
        self.assertEqual(reg["reason"], "reserved")

    def test_a_reserved_name_carries_the_reason(self):
        rpc.eth_call = self._chain(0, True)
        status, body = answers.resolve("acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["status"], "unregistered")
        self.assertEqual(body["reason"], "reserved for SimpleX")

    def test_the_message_does_not_claim_a_trademark(self):
        rpc.eth_call = self._chain(0, True)
        _, body = answers.resolve("acme.testing")
        self.assertNotIn("trademark", body["message"])

    def test_an_unregistered_name_has_no_reason(self):
        rpc.eth_call = self._chain(0, False)
        status, body = answers.resolve("acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["status"], "unregistered")
        self.assertIsNone(body["reason"])

    def test_an_expired_name_has_no_reason(self):
        rpc.eth_call = self._chain(1, False)
        status, body = answers.resolve("acme.testing")
        self.assertEqual(status, 410)
        self.assertEqual(body["status"], "expired")
        self.assertIsNone(body["reason"])

    def test_a_hashed_query_gets_the_reason_too(self):
        rpc.eth_call = self._chain(0, True)
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        _, body = answers.resolve(hashed + ".testing")
        self.assertEqual(body["reason"], "reserved for SimpleX")
