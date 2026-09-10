#!/usr/bin/env python3
"""Unit tests for snrc-resolve helpers.

Run with `python3 -m unittest scripts/resolver/service/test_snrc_resolve.py`.
"""

import contextlib
import importlib.util
import io
import os
import time
import unittest

# snrc-resolve.py has a hyphen, so import it via importlib instead of `import`.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "snrc_resolve", os.path.join(_HERE, "snrc-resolve.py")
)
snrc = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(snrc)


class SplitLinksTests(unittest.TestCase):
    """`split_links` decodes the multi-URL convention for simplex.contact /
    simplex.channel text records. Reuses the same rule the dApp's
    `parseSimplexUrls` uses (separator `;`), so the two sides round-trip
    cleanly."""

    def test_empty_string_yields_empty_list(self):
        self.assertEqual(snrc.split_links(""), [])

    def test_whitespace_only_yields_empty_list(self):
        self.assertEqual(snrc.split_links("   "), [])
        self.assertEqual(snrc.split_links(" ; ; "), [])

    def test_single_url_yields_singleton_list(self):
        self.assertEqual(
            snrc.split_links("https://smp16.simplex.im/a#H1"),
            ["https://smp16.simplex.im/a#H1"],
        )

    def test_two_urls_split_on_separator(self):
        self.assertEqual(
            snrc.split_links(
                "https://smp16.simplex.im/a#H1;https://smp19.simplex.im/a#H1"
            ),
            [
                "https://smp16.simplex.im/a#H1",
                "https://smp19.simplex.im/a#H1",
            ],
        )

    def test_whitespace_around_separators_is_trimmed(self):
        self.assertEqual(
            snrc.split_links(
                "  https://smp16.simplex.im/a#H1 ;\thttps://smp19.simplex.im/a#H1 "
            ),
            [
                "https://smp16.simplex.im/a#H1",
                "https://smp19.simplex.im/a#H1",
            ],
        )

    def test_trailing_separator_does_not_produce_empty_entry(self):
        self.assertEqual(
            snrc.split_links("https://smp16.simplex.im/a#H1;"),
            ["https://smp16.simplex.im/a#H1"],
        )

    def test_doubled_separator_does_not_produce_empty_entry(self):
        self.assertEqual(
            snrc.split_links(
                "https://smp16.simplex.im/a#H1;;https://smp19.simplex.im/a#H1"
            ),
            [
                "https://smp16.simplex.im/a#H1",
                "https://smp19.simplex.im/a#H1",
            ],
        )

    def test_order_is_preserved(self):
        self.assertEqual(
            snrc.split_links("c;a;b"),
            ["c", "a", "b"],
        )


class EncodedLabelhashTests(unittest.TestCase):
    # keccak-256("alice"), written out in full wherever a test needs it.
    # 9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501

    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    GRACE = 90 * 86400

    def setUp(self):
        self._saved = (snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call, snrc.chain_now)
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": ""}
        snrc.chain_now = lambda: int(time.time())
        snrc._constants.clear()

    def tearDown(self):
        snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call, snrc.chain_now = self._saved

    def test_the_encoded_form_is_recognised(self):
        self.assertTrue(
            snrc.is_encoded_labelhash(
                "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
            )
        )

    def test_an_ordinary_label_is_not(self):
        self.assertFalse(snrc.is_encoded_labelhash("alice"))
        self.assertFalse(snrc.is_encoded_labelhash("[alice]"))
        self.assertFalse(snrc.is_encoded_labelhash("9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501"))

    def test_non_hex_between_the_brackets_is_not(self):
        self.assertFalse(snrc.is_encoded_labelhash("[" + "z" * 64 + "]"))
        # uppercase is rejected because the handler lowercases the whole name
        self.assertFalse(snrc.is_encoded_labelhash("[" + "A" * 64 + "]"))
        self.assertFalse(snrc.is_encoded_labelhash("[0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"))

    def test_the_wrong_length_is_not(self):
        self.assertFalse(snrc.is_encoded_labelhash("[" + "a" * 63 + "]"))
        self.assertFalse(snrc.is_encoded_labelhash("[" + "a" * 65 + "]"))

    def test_hash_and_label_reach_the_same_node(self):
        self.assertEqual(
            snrc.node_of("alice.testing"),
            snrc.node_of(
                "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
                ".testing"
            ),
        )

    def test_a_plain_name_is_unaffected(self):
        self.assertEqual(snrc.node_of("alice.testing"), snrc.namehash("alice.testing"))

    def test_a_bracket_subname_label_stays_literal(self):
        """Only the 2LD is a key, so a bracket label left of it is hashed as
        written."""
        self.assertNotEqual(
            snrc.node_of(
                "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
                ".alice.testing"
            ),
            snrc.namehash("alice.alice.testing"),
        )

    def test_a_0x_prefixed_label_is_taken_literally(self):
        name = "0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501.testing"
        self.assertEqual(snrc.node_of(name), snrc.namehash(name))
        self.assertNotEqual(snrc.node_of(name), snrc.node_of("alice.testing"))

    def test_a_malformed_bracket_label_falls_back_to_a_literal_name(self):
        name = "[nothex].testing"
        self.assertEqual(snrc.node_of(name), snrc.namehash(name))

    def test_status_by_hash_matches_status_by_name(self):
        future = int(time.time()) + 86400
        seen = []

        def eth_call(to, data):
            seen.append(data)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            return "0x" + snrc.encode_uint(future)

        snrc.eth_call = eth_call
        by_name = snrc.name_status("alice.testing")
        by_hash = snrc.name_status(
            "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
            ".testing"
        )
        self.assertEqual(by_name, by_hash)
        self.assertEqual(by_name["status"], "registered")
        # nothing in either request carried the label itself
        self.assertTrue(all("alice".encode().hex() not in d for d in seen))


class NameStatusTests(unittest.TestCase):
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"

    GRACE = 90 * 86400

    def _expiry(self, value):
        def eth_call(to, data):
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            self.assertTrue(data.startswith(snrc.selector("nameExpires(uint256)")))
            return "0x" + snrc.encode_uint(value)

        return eth_call

    def _keys(self, status, expires, grace_ends):
        """Every branch answers with the same keys; only some carry values."""
        return {
            "status": status,
            "expires": expires,
            "graceEnds": grace_ends,
            "reasonCode": None,
            "reason": None,
            "auctionUntil": None,
        }

    def setUp(self):
        self._saved = (
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
            snrc.rpc,
        )
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        # Expiry alone; ReservedTests covers a configured controller.
        snrc.CONTROLLERS = {"testing": ""}
        snrc.chain_now = lambda: int(time.time())
        snrc._constants.clear()

    def tearDown(self):
        (
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
            snrc.rpc,
        ) = self._saved

    def test_now_is_the_latest_blocks_timestamp(self):
        # setUp replaced chain_now with the fixture clock; test the real one
        real_chain_now = self._saved[3]
        snrc.rpc = lambda method, params: {"timestamp": "0x65f1a2c0", "number": "0x123"}
        self.assertEqual(real_chain_now(), 0x65F1A2C0)

    def test_status_reads_the_chain_clock_not_the_host_clock(self):
        future = int(time.time()) + 3600
        snrc.eth_call = self._expiry(future)
        self.assertEqual(snrc.name_status("alice.testing")["status"], "registered")
        snrc.chain_now = lambda: future + 3650 * 86400
        self.assertEqual(snrc.name_status("alice.testing")["status"], "expired")

    def test_a_registrar_that_is_not_a_contract_is_an_error_not_a_free_name(self):
        """An address with no code answers eth_call with empty data. Read as
        zero, that would make every name look free."""
        snrc.eth_call = self._saved[2]  # the real one, so its guard runs
        snrc.rpc = lambda method, params: "0x"
        with self.assertRaises(RuntimeError):
            snrc.name_status("alice.testing")

    def test_the_grace_period_is_read_once_not_per_query(self):
        seen = []

        def eth_call(to, data):
            seen.append(data[:10])
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            return "0x" + snrc.encode_uint(int(time.time()) - 3600)

        snrc.eth_call = eth_call
        snrc.name_status("alice.testing")
        snrc.name_status("alice.testing")
        self.assertEqual(seen.count(snrc.selector("GRACE_PERIOD()")), 1)

    def test_zero_expiry_means_never_registered(self):
        snrc.eth_call = self._expiry(0)
        self.assertEqual(
            snrc.name_status("alice.testing"),
            self._keys("unregistered", None, None),
        )

    def test_recently_expired_is_in_grace_and_says_when_it_ends(self):
        past = int(time.time()) - 3600
        snrc.eth_call = self._expiry(past)
        self.assertEqual(
            snrc.name_status("alice.testing"),
            self._keys("grace", past, past + self.GRACE),
        )

    def test_past_the_grace_window_it_is_expired_and_claimable(self):
        past = int(time.time()) - self.GRACE - 3600
        snrc.eth_call = self._expiry(past)
        self.assertEqual(snrc.name_status("alice.testing")["status"], "expired")

    def test_the_boundary_belongs_to_grace(self):
        """The registrar frees a name only when expires + GRACE < now."""
        now = int(time.time())
        snrc.eth_call = self._expiry(now - self.GRACE)
        self.assertEqual(snrc.name_status("alice.testing")["status"], "grace")

    def test_future_expiry_is_registered(self):
        future = int(time.time()) + 3600
        snrc.eth_call = self._expiry(future)
        self.assertEqual(
            snrc.name_status("alice.testing"),
            self._keys("registered", future, future + self.GRACE),
        )

    def test_never_registered_is_not_confused_with_claimable(self):
        """`available(id)` is true for both, since 0 + GRACE < now."""
        snrc.eth_call = self._expiry(0)
        self.assertEqual(snrc.name_status("alice.testing")["status"], "unregistered")
        self.assertNotEqual(snrc.name_status("alice.testing")["status"], "expired")

    def test_a_subname_reports_the_status_of_its_2ld(self):
        future = int(time.time()) + 3600
        seen = []

        def eth_call(to, data):
            seen.append(data)
            return "0x" + snrc.encode_uint(future)

        snrc.eth_call = eth_call
        self.assertEqual(snrc.name_status("x.alice.testing")["status"], "registered")
        # the token asked about is keccak("alice"), not keccak("x")
        self.assertTrue(seen[0].endswith(snrc.keccak(b"alice").hex()))

    def test_a_hashed_2ld_is_queried_by_its_hash_at_any_depth(self):
        """The token must come from the hash, not from hashing the brackets."""
        seen = []

        def eth_call(to, data):
            seen.append(data)
            return "0x" + snrc.encode_uint(0)

        snrc.eth_call = eth_call
        hashed = "[" + snrc.keccak(b"alice").hex() + "]"
        snrc.name_status("x." + hashed + ".testing")
        self.assertTrue(seen[0].endswith(snrc.keccak(b"alice").hex()))

    def test_unconfigured_tld_is_unknown_rather_than_unregistered(self):
        snrc.REGISTRARS = {"testing": ""}
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        self.assertEqual(
            snrc.name_status("alice.testing"),
            self._keys("unknown", None, None),
        )

    def test_every_branch_returns_the_same_keys(self):
        keys = {
            "status",
            "expires",
            "graceEnds",
            "reasonCode",
            "reason",
            "auctionUntil",
        }
        snrc.eth_call = self._expiry(0)
        self.assertEqual(set(snrc.name_status("alice.testing")), keys)
        snrc.eth_call = self._expiry(int(time.time()) + 3600)
        self.assertEqual(set(snrc.name_status("alice.testing")), keys)
        snrc.REGISTRARS = {"testing": ""}
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        self.assertEqual(set(snrc.name_status("alice.testing")), keys)


class ReservedTests(unittest.TestCase):
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"

    def setUp(self):
        self._saved = (snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call, snrc.chain_now)
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": self.CONTROLLER}
        snrc.chain_now = lambda: int(time.time())
        snrc._constants.clear()

    def tearDown(self):
        snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call, snrc.chain_now = self._saved

    def _chain(self, expires, reserved):
        def eth_call(to, data):
            if data.startswith(snrc.selector("reservedNames(bytes32)")):
                self.assertEqual(to, self.CONTROLLER)
                return "0x" + snrc.encode_uint(1 if reserved else 0)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(90 * 86400)
            if data.startswith(snrc.selector("prices()")):
                return "0x" + snrc.encode_uint(0)  # no price oracle, no auction
            return "0x" + snrc.encode_uint(expires)

        return eth_call

    def test_unregistered_and_reserved_reports_the_reservation(self):
        snrc.eth_call = self._chain(0, True)
        reg = snrc.name_status("acme.testing")
        self.assertEqual(reg["status"], "unregistered")
        self.assertEqual(reg["reasonCode"], "internal")

    def test_unregistered_and_not_reserved_reads_unregistered(self):
        snrc.eth_call = self._chain(0, False)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "unregistered")

    def test_a_lapsed_reserved_name_keeps_its_reservation(self):
        past = int(time.time()) - 91 * 86400
        snrc.eth_call = self._chain(past, True)
        reg = snrc.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")
        self.assertEqual(reg["reasonCode"], "internal")

    def test_a_live_name_is_registered_even_if_reserved(self):
        snrc.eth_call = self._chain(int(time.time()) + 86400, True)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "registered")

    def test_a_name_in_grace_belongs_to_its_owner_not_the_reserved_set(self):
        snrc.eth_call = self._chain(int(time.time()) - 3600, True)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "grace")

    def test_no_controller_configured_means_reserved_is_never_reported(self):
        snrc.CONTROLLERS = {"testing": ""}
        snrc.eth_call = self._chain(0, True)  # reserved on chain, but unread
        self.assertEqual(snrc.name_status("acme.testing")["status"], "unregistered")

    def test_reserved_is_asked_by_labelhash_so_a_hashed_query_works(self):
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        snrc.eth_call = self._chain(0, True)
        self.assertEqual(snrc.name_status(hashed + ".testing")["reasonCode"], "internal")


class ReservedReasonTests(unittest.TestCase):
    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"

    def setUp(self):
        self._saved = (
            snrc.REGISTRIES,
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
        )
        snrc.REGISTRIES = {"testing": self.REGISTRY}
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": self.CONTROLLER}
        snrc.chain_now = lambda: int(time.time())
        snrc._constants.clear()

    def tearDown(self):
        (
            snrc.REGISTRIES,
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
        ) = self._saved

    def _chain(self, expires, reserved):
        def eth_call(to, data):
            if data.startswith(snrc.selector("reservedNames(bytes32)")):
                return "0x" + snrc.encode_uint(1 if reserved else 0)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(90 * 86400)
            if data.startswith(snrc.selector("prices()")):
                return "0x" + snrc.encode_uint(0)  # no price oracle, no auction
            return "0x" + snrc.encode_uint(expires)

        return eth_call

    def _reserved_as(self, code):
        def eth_call(to, data):
            if data.startswith(snrc.selector("reservedNames(bytes32)")):
                return "0x" + snrc.encode_uint(code)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(90 * 86400)
            if data.startswith(snrc.selector("prices()")):
                return "0x" + snrc.encode_uint(0)
            return "0x" + snrc.encode_uint(0)

        return eth_call

    def test_every_enum_value_has_a_code_and_a_sentence(self):
        for code, (name, sentence) in snrc.RESERVED_REASONS.items():
            snrc.eth_call = self._reserved_as(code)
            reg = snrc.name_status("acme.testing")
            self.assertEqual(reg["reasonCode"], name)
            self.assertEqual(reg["reason"], sentence)

    def test_a_trademark_reservation_says_so(self):
        snrc.eth_call = self._reserved_as(2)
        _, body = snrc.resolve("acme.testing")
        self.assertEqual(body["reasonCode"], "trademark")

    def test_a_controller_storing_a_bool_reads_as_internal(self):
        """Before the enum `reservedNames` was a bool; its `true` decodes as 1."""
        snrc.eth_call = self._reserved_as(1)
        reg = snrc.name_status("acme.testing")
        self.assertEqual(reg["reasonCode"], "internal")
        self.assertEqual(reg["reason"], "reserved for SimpleX")

    def test_an_enum_value_this_resolver_predates_is_not_dropped(self):
        """A new Reason still reserves the name, and says it is unknown rather
        than claiming the chain recorded none."""
        snrc.eth_call = self._reserved_as(99)
        reg = snrc.name_status("acme.testing")
        self.assertEqual(reg["reasonCode"], "unknown")
        self.assertEqual(reg["reason"], "reserved")

    def test_a_reserved_name_carries_the_reason(self):
        snrc.eth_call = self._chain(0, True)
        status, body = snrc.resolve("acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["status"], "unregistered")
        self.assertEqual(body["reason"], "reserved for SimpleX")

    def test_the_message_does_not_claim_a_trademark(self):
        snrc.eth_call = self._chain(0, True)
        _, body = snrc.resolve("acme.testing")
        self.assertNotIn("trademark", body["message"])

    def test_an_unregistered_name_has_no_reason(self):
        snrc.eth_call = self._chain(0, False)
        status, body = snrc.resolve("acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["status"], "unregistered")
        self.assertIsNone(body["reason"])

    def test_an_expired_name_has_no_reason(self):
        snrc.eth_call = self._chain(1, False)
        status, body = snrc.resolve("acme.testing")
        self.assertEqual(status, 410)
        self.assertEqual(body["status"], "expired")
        self.assertIsNone(body["reason"])

    def test_a_hashed_query_gets_the_reason_too(self):
        snrc.eth_call = self._chain(0, True)
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        _, body = snrc.resolve(hashed + ".testing")
        self.assertEqual(body["reason"], "reserved for SimpleX")


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
            snrc.REGISTRIES,
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
        )
        snrc.REGISTRIES = {"testing": self.REGISTRY}
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": self.CONTROLLER}
        self.now = int(time.time())
        snrc.chain_now = lambda: self.now
        snrc._constants.clear()

    def tearDown(self):
        (
            snrc.REGISTRIES,
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
        ) = self._saved

    def _prices_return(self):
        words = [snrc.encode_uint(self.BASE), snrc.encode_uint(0x40),
                 snrc.encode_uint(len(self.EXCEPTIONS))]
        for length, cents in self.EXCEPTIONS.items():
            words += [snrc.encode_uint(length), snrc.encode_uint(cents)]
        return "0x" + "".join(words)

    def _chain(self, expires, oracle=None, reserved=0):
        oracle = self.ORACLE if oracle is None else oracle
        self.oracle_calls = []

        def eth_call(to, data):
            if data.startswith(snrc.selector("nameExpires(uint256)")):
                return "0x" + snrc.encode_uint(expires)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            if data.startswith(snrc.selector("reservedNames(bytes32)")):
                return "0x" + snrc.encode_uint(reserved)
            if data.startswith(snrc.selector("minCharLength()")):
                self.assertEqual(to, self.CONTROLLER)
                return "0x" + snrc.encode_uint(self.MIN_LENGTH)
            if data.startswith(snrc.selector("prices()")):
                if to == self.CONTROLLER:
                    return "0x" + snrc.encode_uint(int(oracle, 16))
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
        snrc.eth_call = self._chain(self._lapsed(0))
        reg = snrc.name_status("acme.testing")
        # 1 and 2 are below minCharLength
        self.assertEqual(reg["rentPrices"], {3: 1600, 4: 800, 5: 500})
        self.assertEqual(reg["basePrice"], self.BASE)
        self.assertEqual(reg["minLabelLength"], self.MIN_LENGTH)

    def test_a_lapsed_name_costs_the_ordinary_price(self):
        snrc.eth_call = self._chain(self._lapsed(0))
        reg = snrc.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")
        self.assertIsNone(reg["auctionUntil"])

    def test_a_controller_with_no_oracle_leaves_the_name_merely_expired(self):
        snrc.eth_call = self._chain(self._lapsed(0), oracle=snrc.ZERO_ADDR)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "expired")

    def test_a_name_in_grace_never_reaches_the_oracle(self):
        snrc.eth_call = self._chain(self.now - 3600)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "grace")
        self.assertEqual(self.oracle_calls, [])

    def test_the_oracle_curve_is_read_once_not_per_query(self):
        snrc.eth_call = self._chain(self._lapsed(1))
        snrc.name_status("acme.testing")
        seen_first = len(self.oracle_calls)
        snrc.name_status("acme.testing")
        self.assertEqual(self.oracle_calls[seen_first:], [])

    def test_a_reserved_lapsed_name_keeps_its_reservation(self):
        snrc.eth_call = self._chain(self._lapsed(0), reserved=2)
        reg = snrc.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")
        self.assertEqual(reg["reasonCode"], "trademark")

    def test_resolve_reports_the_prices(self):
        snrc.eth_call = self._chain(self._lapsed(1))
        status, body = snrc.resolve("acme.testing")
        self.assertEqual(status, 410)
        self.assertEqual(body["status"], "expired")
        self.assertEqual(body["basePrice"], self.BASE)
        self.assertIsNone(body["auctionUntil"])

    def test_a_hashed_query_is_priced_too(self):
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        snrc.eth_call = self._chain(self._lapsed(0))
        _, body = snrc.resolve(hashed + ".testing")
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
        self._saved = (snrc.REGISTRIES, snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call, snrc.chain_now)
        snrc.REGISTRIES = {"testing": self.REGISTRY}
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": self.CONTROLLER}
        self.now = int(time.time())
        snrc.chain_now = lambda: self.now
        snrc._constants.clear()

    def tearDown(self):
        (snrc.REGISTRIES, snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call, snrc.chain_now) = self._saved

    def _chain(self, expires, letter_cents=0):
        def eth_call(to, data):
            if data.startswith(snrc.selector("nameExpires(uint256)")):
                return "0x" + snrc.encode_uint(expires)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            if data.startswith(snrc.selector("reservedNames(bytes32)")):
                return "0x" + snrc.encode_uint(0)
            if data.startswith(snrc.selector("minCharLength()")):
                return "0x" + snrc.encode_uint(self.MIN_LENGTH)
            if data.startswith(snrc.selector("prices()")):
                if to == self.CONTROLLER:
                    return "0x" + snrc.encode_uint(int(self.ORACLE, 16))
                raise RuntimeError("eth_call returned 0x")  # no prices() on this oracle
            for n in range(1, 7):
                if data.startswith(snrc.selector(f"price{n}Letter()")):
                    rate = letter_cents * snrc.ATTO_PER_CENT // snrc.SECONDS_PER_YEAR
                    return "0x" + snrc.encode_uint(rate)
            return self.fail("unexpected call " + data[:10])

        return eth_call

    def test_a_never_registered_name_is_priced_from_the_letter_curve(self):
        snrc.eth_call = self._chain(0)
        reg = snrc.name_status("ghost.testing")
        self.assertEqual(reg["status"], "unregistered")
        self.assertEqual(reg["basePrice"], 0)
        self.assertEqual(reg["minLabelLength"], self.MIN_LENGTH)

    def test_a_non_zero_letter_curve_converts_to_cents_per_year(self):
        snrc.eth_call = self._chain(0, letter_cents=1200)
        self.assertEqual(snrc.name_status("ghost.testing")["basePrice"], 1200)

    def test_a_lapsed_name_is_not_priced_because_the_premium_is_unreadable(self):
        snrc.eth_call = self._chain(self.now - self.GRACE - 1)
        reg = snrc.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")
        self.assertNotIn("basePrice", reg)


class ErrorCodeTests(unittest.TestCase):
    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"

    def setUp(self):
        self._saved = (
            snrc.REGISTRIES,
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
        )
        snrc.REGISTRIES = {"testing": self.REGISTRY, "simplex": ""}
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": ""}
        snrc.chain_now = lambda: int(time.time())
        snrc._constants.clear()

    def tearDown(self):
        (
            snrc.REGISTRIES,
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
        ) = self._saved

    def _chain(self, expires, resolver=None):
        def eth_call(to, data):
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(90 * 86400)
            if data.startswith(snrc.selector("resolver(bytes32)")):
                return "0x" + "00" * 12 + (resolver or "00" * 20)
            return "0x" + snrc.encode_uint(expires)

        return eth_call

    def test_an_unconfigured_tld_names_the_ones_that_are(self):
        status, body = snrc.resolve("alice.nosuchtld")
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
                snrc.eth_call = self._chain(expires)
                _, body = snrc.resolve("alice.testing")
                self.assertEqual(body["error"], code)
                self.assertEqual(body["status"], code)

    def test_a_name_in_grace_still_resolves(self):
        snrc.eth_call = self._chain(int(time.time()) - 3600)
        status, body = snrc.resolve("alice.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "grace")
        self.assertNotIn("error", body)

    def test_a_registered_name_pointing_nowhere_resolves_with_empty_records(self):
        snrc.eth_call = self._chain(int(time.time()) + 86400)
        status, body = snrc.resolve("alice.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "registered")
        self.assertEqual(body["resolver"], snrc.ZERO_ADDR)
        self.assertEqual(body["simplexContact"], [])

    def test_every_error_body_carries_both_fields(self):
        snrc.eth_call = self._chain(0)
        for name in ("alice.nosuchtld", "alice.testing"):
            with self.subTest(name=name):
                _, body = snrc.resolve(name)
                self.assertIsInstance(body["error"], str)
                self.assertIsInstance(body["message"], str)
                self.assertNotEqual(body["error"], body["message"])

    def test_an_upstream_failure_does_not_echo_the_exception(self):
        with contextlib.redirect_stderr(io.StringIO()) as log:
            body = snrc.upstream_error(
                {"name": "alice.testing"},
                RuntimeError("http://user:secret@rpc.example/kEy8 refused"),
            )
        # the operator still sees the detail in the log
        self.assertIn("secret", log.getvalue())
        self.assertEqual(body["error"], "upstreamError")
        self.assertIn("RuntimeError", body["message"])
        self.assertNotIn("secret", body["message"])
        self.assertNotIn("kEy8", body["message"])


if __name__ == "__main__":
    unittest.main()
