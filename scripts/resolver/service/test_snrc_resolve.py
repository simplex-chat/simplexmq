#!/usr/bin/env python3
"""Unit tests for snrc-resolve helpers.

Run with `python3 -m unittest scripts/resolver/service/test_snrc_resolve.py`.
"""

import contextlib
import importlib.util
import io
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import urlopen

# snrc-resolve.py has a hyphen, so import it via importlib instead of `import`.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "snrc_resolve", os.path.join(_HERE, "snrc-resolve.py")
)
snrc = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(snrc)


def registration(name):
    """registration() answers a NameResponse; most tests assert what is in it."""
    status, body = snrc.registration(name)
    return status, (body["registration"] if status == 200 else body)


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
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
            snrc.rpc,
        )
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        # Expiry alone; ReservedTests covers a configured controller.
        snrc.CONTROLLERS = {"testing": ""}
        self.now = int(time.time())
        snrc.chain_now = lambda: self.now

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
        self.assertEqual(reg["registrationPrices"], {3: 1600, 4: 800, 5: 500})
        self.assertEqual(reg["basePrice"], self.BASE)
        self.assertEqual(reg["minLabelLength"], self.MIN_LENGTH)

    def test_a_lapsed_name_costs_the_ordinary_price(self):
        snrc.eth_call = self._chain(self._lapsed(0))
        reg = snrc.name_status("acme.testing")
        self.assertEqual(reg["status"], "expired")

    def test_a_controller_with_no_oracle_leaves_the_name_merely_expired(self):
        snrc.eth_call = self._chain(self._lapsed(0), oracle=snrc.ZERO_ADDR)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "expired")

    def test_a_name_in_grace_never_reaches_the_oracle(self):
        snrc.eth_call = self._chain(self.now - 3600)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "grace")
        self.assertEqual(self.oracle_calls, [])

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

    @staticmethod
    def _abi_bytes(value: bytes) -> str:
        """head offset, length, then the payload padded to a 32-byte word."""
        pad = (-len(value)) % 32
        return ("0x" + snrc.encode_uint(0x20) + snrc.encode_uint(len(value))
                + (value + b"\x00" * pad).hex())

    def _chain(self, expires, reserved=0, oracle=None, label=b"acme", owner=None):
        """The registry answers a zero resolver, so name_record returns the
        empty record a registered name still has. `label` is what the registrar
        recorded for the 2LD; b"" means it recorded none. `owner` is the owner of
        the queried node; ZERO_ADDR means that node was never created."""
        oracle = self.ORACLE if oracle is None else oracle
        owner = self.OWNER if owner is None else owner

        def eth_call(to, data):
            if data.startswith(snrc.selector("labelOf(uint256)")):
                return self._abi_bytes(label)
            if data.startswith(snrc.selector("nameExpires(uint256)")):
                return "0x" + snrc.encode_uint(expires)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            if data.startswith(snrc.selector("reservedNames(bytes32)")):
                return "0x" + snrc.encode_uint(reserved)
            if data.startswith(snrc.selector("minCharLength()")):
                return "0x" + snrc.encode_uint(self.MIN_LENGTH)
            if data.startswith(snrc.selector("prices()")):
                if to == self.CONTROLLER:
                    return "0x" + snrc.encode_uint(int(oracle, 16))
                return self._prices_return()
            if data.startswith(snrc.selector("resolver(bytes32)")):
                return "0x" + snrc.encode_uint(0)
            if data.startswith(snrc.selector("owner(bytes32)")):
                return "0x" + snrc.encode_uint(int(owner, 16))
            return self.fail("unexpected call " + data[:10])

        return eth_call

    def _lapsed(self, days_past_grace):
        return self.now - self.GRACE - 1 - days_past_grace * 86400

    def test_a_live_name_is_registered_and_carries_its_record(self):
        expires = self.now + 3600
        snrc.eth_call = self._chain(expires)
        status, body = registration("acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "registered")
        self.assertEqual(body["expires"], expires)
        self.assertEqual(body["graceUntil"], expires + self.GRACE)
        self.assertIsNone(body["reservedReason_"])
        self.assertEqual(body["nameRecord"]["name"], "acme.testing")

    def test_a_name_in_grace_is_still_registered(self):
        expires = self.now - 3600
        snrc.eth_call = self._chain(expires)
        _, body = registration("acme.testing")
        self.assertEqual(body["type"], "registered")
        self.assertGreater(body["graceUntil"], self.now)

    def test_a_registered_name_that_is_held_back_says_so(self):
        snrc.eth_call = self._chain(self.now + 3600, reserved=1)
        _, body = registration("acme.testing")
        self.assertEqual(body["type"], "registered")
        self.assertEqual(body["reservedReason_"], "internal")

    def test_an_unregistered_name_is_available_with_its_pricing(self):
        snrc.eth_call = self._chain(0)
        status, body = registration("acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "available")
        # lengths below minCharLength are unregistrable, so they are not priced
        self.assertEqual(body["pricing"]["registrationPrices"], {3: 1600, 4: 800, 5: 500})
        self.assertEqual(body["pricing"]["basePrice"], self.BASE)
        self.assertEqual(body["pricing"]["minLabelLength"], self.MIN_LENGTH)

    def test_a_lapsed_name_is_available_at_the_ordinary_price(self):
        snrc.eth_call = self._chain(self._lapsed(1))
        _, body = registration("acme.testing")
        self.assertEqual(body["type"], "available")
        self.assertEqual(body["pricing"]["basePrice"], self.BASE)

    def test_a_held_back_name_is_reserved_and_is_never_priced(self):
        snrc.eth_call = self._chain(0, reserved=2)
        status, body = registration("acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "reserved")
        self.assertEqual(body["reservedReason"], "trademark")
        self.assertNotIn("pricing", body)

    def test_a_hashed_query_answers_the_same_as_the_name(self):
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        snrc.eth_call = self._chain(0)
        _, by_name = registration("acme.testing")
        _, by_hash = registration(hashed + ".testing")
        self.assertEqual(by_name, by_hash)

    def test_an_unconfigured_tld_is_refused_not_answered(self):
        snrc.REGISTRIES = {"testing": ""}
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        status, body = registration("acme.testing")
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "tldNotConfigured")

    def test_no_price_oracle_is_an_error_not_a_free_name(self):
        snrc.eth_call = self._chain(0, oracle=snrc.ZERO_ADDR)
        status, body = registration("acme.testing")
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "noPriceOracle")

    def test_a_status_it_cannot_read_is_an_error_not_a_registration(self):
        snrc.REGISTRARS = {"testing": ""}
        snrc.eth_call = self._chain(0)
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
                snrc.eth_call = chain
                _, body = registration("acme.testing")
                self.assertEqual(body["type"], expected_type)
                self.assertEqual(set(body), keys)
    def test_a_hashed_query_the_registrar_cannot_name_is_refused(self):
        """The client checks the record names what it asked about, so answering
        with a record the registrar could not name would only fail there."""
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        snrc.eth_call = self._chain(self.now + 3600, label=b"")
        status, body = registration(hashed + ".testing")
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "labelNotRecorded")

    def test_a_hashed_query_is_answered_with_the_name_the_registrar_recorded(self):
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        snrc.eth_call = self._chain(self.now + 3600)
        status, body = registration(hashed + ".testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["nameRecord"]["name"], "acme.testing")
    def test_a_subname_that_exists_is_registered_with_its_parents_dates(self):
        expires = self.now + 3600
        snrc.eth_call = self._chain(expires)
        status, body = registration("sub.acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "registered")
        self.assertEqual(body["expires"], expires)
        self.assertEqual(body["nameRecord"]["name"], "sub.acme.testing")

    def test_a_subname_nobody_created_is_not_registered(self):
        """The registrar only tracks 2LDs, so the parent's registration says
        nothing about a child that was never created: its node has no owner."""
        snrc.eth_call = self._chain(self.now + 3600, owner=snrc.ZERO_ADDR)
        status, body = registration("sub.acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["type"], "available")

    def test_a_2ld_is_not_subject_to_the_owner_check(self):
        """Only a subname can be absent under a registered parent."""
        snrc.eth_call = self._chain(self.now + 3600, owner=snrc.ZERO_ADDR)
        _, body = registration("acme.testing")
        self.assertEqual(body["type"], "registered")

    def test_v1_does_not_report_an_uncreated_subname_as_registered(self):
        """v1 has no availability, so the only honest answer is not-found. The
        2LD case is untouched: a registered name with no resolver still resolves."""
        snrc.eth_call = self._chain(self.now + 3600, owner=snrc.ZERO_ADDR)
        status, body = snrc.resolve("sub.acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "unregistered")

    def test_v1_still_resolves_a_2ld_with_no_resolver_set(self):
        snrc.eth_call = self._chain(self.now + 3600, owner=snrc.ZERO_ADDR)
        status, body = snrc.resolve("acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["resolver"], snrc.ZERO_ADDR)

    def test_the_answer_says_which_block_it_was_read_at(self):
        """The resolver is only as current as its node. Without this a client
        cannot tell an answer that predates its own registration."""
        snrc.eth_call = self._chain(self.now + 3600)
        _, res = snrc.registration("acme.testing")
        self.assertEqual(res["lastBlockTs"], self.now)
        self.assertEqual(res["registration"]["type"], "registered")

    def test_an_available_name_says_so_too(self):
        """This is the path that reads no block otherwise, and the one where
        staleness matters most: the name may already be taken."""
        snrc.eth_call = self._chain(0)
        _, res = snrc.registration("acme.testing")
        self.assertEqual(res["lastBlockTs"], self.now)
        self.assertEqual(res["registration"]["type"], "available")


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux drops SYNs on a full accept queue")
class ListenBacklogTests(unittest.TestCase):
    """The smp-server opens a connection per lookup and gives up after 3 s, so a
    burst the accept queue cannot hold fails: TCP retries a dropped SYN after 1 s."""

    BURST = 50

    def test_a_burst_of_connections_is_queued_while_the_server_is_busy(self):
        # never accepts, so every connection must wait in the queue
        server = snrc.ResolverServer(("127.0.0.1", 0), snrc.Handler)
        clients = []
        try:
            for i in range(self.BURST):
                c = socket.socket()
                clients.append(c)
                c.settimeout(0.5)
                try:
                    c.connect(server.server_address)
                except TimeoutError:
                    self.fail(f"connection {i + 1} of {self.BURST} was not queued")
        finally:
            for c in clients:
                c.close()
            server.server_close()


def _word(value: int) -> bytes:
    return value.to_bytes(32, "big")


def _decode_aggregate3_calls(data: str):
    """Multicall3.aggregate3 calldata back to (to, data) pairs, written apart
    from the resolver's encoder so the two check each other."""
    raw = bytes.fromhex(data[len(snrc.AGGREGATE3):])

    def word(at):
        return int.from_bytes(raw[at:at + 32], "big")

    array = word(0)
    base = array + 32
    calls = []
    for i in range(word(array)):
        item = base + word(base + 32 * i)
        call = item + word(item + 64)
        calls.append(("0x" + raw[item + 12:item + 32].hex(), "0x" + raw[call + 32:call + 32 + word(call)].hex()))
    return calls


def _encode_aggregate3_results(results) -> str:
    tuples = [
        _word(int(ok)) + _word(0x40) + _word(len(data)) + data + b"\x00" * ((-len(data)) % 32)
        for ok, data in results
    ]
    offsets, at = b"", 32 * len(tuples)
    for t in tuples:
        offsets += _word(at)
        at += len(t)
    return "0x" + (_word(0x20) + _word(len(tuples)) + offsets + b"".join(tuples)).hex()


class FakeChain:
    """Contract state for one registered name and one free name. Any other
    call reverts, as a view function asked for something unset does."""

    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"
    ORACLE = "0x1e0c9a2b9d1a4c8f7b3e5d6a9c2f4b8e1d7a3c50"
    OWNER = "0xd83bd7e0e6b8a4c1f2593a7b0c4e8d1a6f9b2c37"
    RESOLVER = "0x80fa2b1c3d4e5f60718293a4b5c6d7e8f9012345"
    GRACE = 90 * 86400
    TEXTS = {"nickname": "Acme", "url": "https://acme.example", "simplex.channel": "https://a.example/c#1;https://b.example/c#2"}

    def __init__(self):
        self.now = int(time.time())
        acme, free = snrc.label_token("acme"), snrc.label_token("free")
        node = snrc.node_of("acme.testing")
        abi_bytes = RegistrationV2Tests._abi_bytes
        prices = RegistrationV2Tests._prices_return(RegistrationV2Tests())
        self.answers = {
            snrc.expires_call(self.REGISTRAR, acme): "0x" + snrc.encode_uint(self.now + 3600),
            snrc.expires_call(self.REGISTRAR, free): "0x" + snrc.encode_uint(0),
            snrc.grace_call(self.REGISTRAR): "0x" + snrc.encode_uint(self.GRACE),
            snrc.label_call(self.REGISTRAR, acme): abi_bytes(b"acme"),
            snrc.reserved_call(self.CONTROLLER, acme): "0x" + snrc.encode_uint(0),
            snrc.reserved_call(self.CONTROLLER, free): "0x" + snrc.encode_uint(0),
            snrc.resolver_call(self.REGISTRY, node): "0x" + snrc.encode_uint(int(self.RESOLVER, 16)),
            snrc.owner_call(self.REGISTRY, node): "0x" + snrc.encode_uint(int(self.OWNER, 16)),
            snrc.addr_call(self.RESOLVER, node, snrc.COIN_ETH): abi_bytes(bytes.fromhex(self.OWNER[2:])),
            snrc.prices_call(self.CONTROLLER): "0x" + snrc.encode_uint(int(self.ORACLE, 16)),
            snrc.prices_call(self.ORACLE): prices,
            snrc.min_length_call(self.CONTROLLER): "0x" + snrc.encode_uint(3),
        }
        for key, value in self.TEXTS.items():
            self.answers[snrc.text_call(self.RESOLVER, node, key)] = abi_bytes(value.encode())

    def call(self, to, data):
        answer = self.answers.get((to.lower(), data))
        if answer is None:
            raise RuntimeError("execution reverted")
        return answer


class FakeNode(ThreadingHTTPServer):
    """A JSON-RPC node over HTTP/1.1 keep-alive, serving FakeChain, with
    batches and Multicall3, each of which a test can take away."""

    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _FakeNodeHandler)
        self.chain = FakeChain()
        self.block = 100
        self.requests = 0
        self.connections = 0
        self.batch = True
        self.multicall = True
        self.status = 200
        self.hang_up = False
        self.drop_after_reply = False
        threading.Thread(target=self.serve_forever, args=(0.05,), daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}/"

    def stop(self):
        self.shutdown()
        self.server_close()

    def answer(self, req):
        out = {"jsonrpc": "2.0", "id": req.get("id")}
        method, params = req["method"], req["params"]
        if method == "eth_blockNumber":
            out["result"] = hex(self.block)
        elif method == "eth_getBlockByNumber":
            out["result"] = {"number": hex(self.block), "timestamp": hex(self.chain.now)}
        elif method == "eth_call" and params[0]["to"].lower() == snrc.MULTICALL.lower():
            if not self.multicall:
                out["error"] = {"code": -32000, "message": "no contract code"}
            else:
                results = []
                for to, data in _decode_aggregate3_calls(params[0]["data"]):
                    try:
                        results.append((True, bytes.fromhex(self.chain.call(to, data)[2:])))
                    except RuntimeError:
                        results.append((False, b""))
                out["result"] = _encode_aggregate3_results(results)
        elif method == "eth_call":
            try:
                out["result"] = self.chain.call(params[0]["to"], params[0]["data"])
            except RuntimeError:
                out["error"] = {"code": 3, "message": "execution reverted"}
        else:
            out["error"] = {"code": -32601, "message": "method not found"}
        return out


class _FakeNodeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        # headers and body go out in separate writes, which Nagle holds for the client's delayed ACK
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.server.connections += 1

    def do_POST(self):  # noqa: N802 - http.server contract
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        node = self.server
        node.requests += 1
        if node.hang_up:
            self.close_connection = True
            return
        if node.status != 200:
            reply = {"error": "unavailable"}
        elif isinstance(request, list):
            reply = [node.answer(r) for r in request] if node.batch else {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "batch not supported"}}
        else:
            reply = node.answer(request)
        data = json.dumps(reply).encode()
        self.send_response(node.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        # closes without `Connection: close`, as a node dropping an idle connection does
        self.close_connection = node.drop_after_reply

    def log_message(self, fmt, *args):
        pass


class FakeNodeTestCase(unittest.TestCase):
    """Points the resolver at a FakeNode and at FakeChain's contracts."""

    def setUp(self):
        self.node = FakeNode()
        self._saved = (snrc.RPC, snrc.RPC_URL, snrc.REGISTRIES, snrc.REGISTRARS, snrc.CONTROLLERS)
        snrc.RPC = self.node.url
        snrc.RPC_URL = urlparse(snrc.RPC)
        snrc.REGISTRIES = {"testing": FakeChain.REGISTRY, "simplex": ""}
        snrc.REGISTRARS = {"testing": FakeChain.REGISTRAR}
        snrc.CONTROLLERS = {"testing": FakeChain.CONTROLLER}
        snrc._multicall_failed_logged = False
        self._drain_pool()

    def tearDown(self):
        self._drain_pool()
        snrc.RPC, snrc.RPC_URL, snrc.REGISTRIES, snrc.REGISTRARS, snrc.CONTROLLERS = self._saved
        self.node.stop()

    def _drain_pool(self):
        while not snrc._rpc_pool.empty():
            snrc._rpc_pool.get_nowait().close()

    def requests_made(self, action):
        before = self.node.requests
        result = action()
        return result, self.node.requests - before


class RpcTransportTests(FakeNodeTestCase):
    """A lookup makes several reads, and a new connection per read costs CPU
    and leaves a TIME_WAIT socket each, which exhausts local ports under load."""

    def test_reads_share_one_connection(self):
        for _ in range(18):
            self.assertEqual(snrc.rpc("eth_blockNumber", []), hex(self.node.block))
        self.assertEqual(self.node.connections, 1)

    def test_a_connection_the_node_closed_is_replaced(self):
        self.node.drop_after_reply = True
        for _ in range(3):
            self.assertEqual(snrc.rpc("eth_blockNumber", []), hex(self.node.block))
        self.assertEqual(self.node.connections, 3)

    def test_a_fresh_connection_that_fails_is_not_retried(self):
        """Only a pooled connection can be stale; a new one failing means the
        node is down, and resending would only double the wait."""
        self.node.hang_up = True
        with self.assertRaises(ConnectionError):
            snrc.rpc("eth_blockNumber", [])
        self.assertEqual(self.node.requests, 1)

    def test_a_node_failure_is_not_a_reverted_call(self):
        """Callers read RuntimeError as the call reverting and fall back to an
        empty value, so a node failure must not look like one."""
        self.node.status = 502
        with self.assertRaises(HTTPError) as cm:
            snrc.rpc("eth_blockNumber", [])
        self.assertNotIsInstance(cm.exception, RuntimeError)
        self.assertEqual(cm.exception.code, 502)

    def test_a_reverted_call_is_a_runtime_error_and_keeps_the_connection(self):
        with self.assertRaises(RuntimeError):
            snrc.eth_call("0x" + "11" * 20, "0xdeadbeef")
        snrc.rpc("eth_blockNumber", [])
        self.assertEqual(self.node.connections, 1)


class BatchedReadsTests(FakeNodeTestCase):
    """Inside a request a round of reads is one round trip, and its contract
    reads one multicall, because a node runs the calls of a JSON-RPC batch one
    after another. Answers must be exactly those of reading one call at a time."""

    def batched(self, answer, name):
        def action():
            with snrc.request_reads():
                return answer(name)
        return self.requests_made(action)

    def assert_same_answer(self, answer, name, round_trips):
        one_by_one, one_by_one_trips = self.requests_made(lambda: answer(name))
        batched, batched_trips = self.batched(answer, name)
        self.assertEqual(batched, one_by_one)
        self.assertEqual(batched_trips, round_trips)
        self.assertGreater(one_by_one_trips, round_trips)
        return batched

    def test_a_registered_name_takes_two_round_trips(self):
        status, body = self.assert_same_answer(snrc.registration, "acme.testing", 2)
        record = body["registration"]["nameRecord"]
        self.assertEqual(record["nickname"], "Acme")
        self.assertEqual(record["simplexChannel"], ["https://a.example/c#1", "https://b.example/c#2"])
        self.assertIsNone(record["btc"])

    def test_a_hashed_query_is_named_from_the_same_round_trip(self):
        hashed = "[" + snrc.keccak(b"acme").hex() + "].testing"
        status, body = self.assert_same_answer(snrc.registration, hashed, 2)
        self.assertEqual(body["registration"]["nameRecord"]["name"], "acme.testing")

    def test_an_available_name_is_priced_in_three_round_trips(self):
        status, body = self.assert_same_answer(snrc.registration, "free.testing", 3)
        self.assertEqual(body["registration"]["type"], "available")

    def test_v1_answers_the_same(self):
        self.assert_same_answer(snrc.resolve, "acme.testing", 2)

    def test_without_multicall_a_round_is_still_one_batch(self):
        self.node.multicall = False
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assert_same_answer(snrc.registration, "acme.testing", 4)
        self.assertIn("batching calls instead", err.getvalue())

    def test_a_node_that_does_not_batch_is_read_one_call_at_a_time(self):
        self.node.batch = False
        one_by_one, one_by_one_trips = self.requests_made(lambda: snrc.registration("acme.testing"))
        with contextlib.redirect_stderr(io.StringIO()) as err:
            batched, batched_trips = self.batched(snrc.registration, "acme.testing")
        self.assertEqual(batched, one_by_one)
        # one refused batch per round, then the reads the batch would have made
        self.assertEqual(batched_trips, one_by_one_trips + 2)
        self.assertEqual(err.getvalue(), "")

    def test_a_read_reverted_in_the_multicall_is_a_reverted_call(self):
        with snrc.request_reads():
            snrc.prefetch([snrc.eth_call_read(*snrc.grace_call(FakeChain.REGISTRAR)), snrc.eth_call_read(FakeChain.REGISTRY, "0xdeadbeef")])
            _, trips = self.requests_made(lambda: self.assertRaises(RuntimeError, snrc.eth_call, FakeChain.REGISTRY, "0xdeadbeef"))
        self.assertEqual(trips, 0)

    def test_outside_a_request_nothing_is_prefetched(self):
        _, trips = self.requests_made(lambda: snrc.prefetch(snrc.lookup_reads("acme.testing")))
        self.assertEqual(trips, 0)


class Aggregate3Tests(unittest.TestCase):
    def test_calls_are_encoded_as_multicall3_reads_them(self):
        calls = [(FakeChain.REGISTRY, "0x0178b8bf" + "11" * 32), (FakeChain.RESOLVER, "0x59d1d43c" + "22" * 100)]
        data = snrc.encode_aggregate3(calls)
        self.assertTrue(data.startswith(snrc.AGGREGATE3))
        self.assertEqual(_decode_aggregate3_calls(data), calls)

    def test_results_are_decoded_with_their_success_flags(self):
        results = [(True, b"\x01" * 40), (False, b""), (True, b"")]
        self.assertEqual(snrc.decode_aggregate3(_encode_aggregate3_results(results)), results)

    def test_a_truncated_answer_is_refused(self):
        whole = _encode_aggregate3_results([(True, b"\x01" * 40)])
        with self.assertRaises(ValueError):
            snrc.decode_aggregate3(whole[:-64])
        with self.assertRaises(ValueError):
            snrc.decode_aggregate3("0x")


class RequestLogTests(unittest.TestCase):
    def test_each_request_is_logged_with_its_duration(self):
        server = snrc.ResolverServer(("127.0.0.1", 0), snrc.Handler)
        threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True).start()
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                with self.assertRaises(HTTPError):
                    urlopen(f"http://127.0.0.1:{server.server_address[1]}/v2/resolve/x.simplex", timeout=5)
                time.sleep(0.1)
        finally:
            server.shutdown()
            server.server_close()
        self.assertRegex(err.getvalue(), r'"GET /v2/resolve/x\.simplex HTTP/1\.1" 400 - \d+ms')


@unittest.skipUnless(sys.platform.startswith("linux"), "reads worker processes from /proc")
class WorkerProcessesTests(unittest.TestCase):
    """Workers share the port, and the service stops as a whole, so the
    container restarts rather than serving on fewer workers."""

    def setUp(self):
        self.node = FakeNode()
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        env = dict(os.environ, SNRC_RPC=self.node.url, SNRC_BIND="127.0.0.1", SNRC_PORT=str(self.port), SNRC_WORKERS="2",
                   SNRC_REGISTRY_TESTING=FakeChain.REGISTRY, SNRC_REGISTRAR_TESTING=FakeChain.REGISTRAR, SNRC_CONTROLLER_TESTING=FakeChain.CONTROLLER)
        self.service = subprocess.Popen([sys.executable, os.path.join(_HERE, "snrc-resolve.py")], env=env, stderr=subprocess.DEVNULL)
        self.workers = self._wait_for_workers(2)

    def tearDown(self):
        if self.service.poll() is None:
            self.service.kill()
            self.service.wait()
        for pid in self.workers:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGKILL)
        self.node.stop()

    def _wait_for_workers(self, count):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            workers = [int(p) for p in os.listdir("/proc") if p.isdigit() and self._parent(p) == self.service.pid]
            if len(workers) == count and self._serving():
                return workers
            time.sleep(0.05)
        self.fail("workers did not start")

    @staticmethod
    def _parent(pid):
        try:
            with open(f"/proc/{pid}/stat") as f:
                return int(f.read().rsplit(")", 1)[1].split()[1])
        except (FileNotFoundError, ProcessLookupError):
            return None

    def _serving(self):
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=1):
                return True
        except OSError:
            return False

    def _gone(self, pid):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self._parent(pid) != self.service.pid:
                return True
            time.sleep(0.05)
        return False

    def test_workers_answer_on_the_shared_port(self):
        for _ in range(20):
            with urlopen(f"http://127.0.0.1:{self.port}/v2/resolve/acme.testing", timeout=5) as res:
                self.assertEqual(json.loads(res.read())["registration"]["type"], "registered")

    def test_stopping_the_service_stops_every_worker(self):
        self.service.send_signal(signal.SIGTERM)
        self.assertEqual(self.service.wait(timeout=5), 0)
        self.assertTrue(all(self._gone(pid) for pid in self.workers))

    def test_a_worker_exiting_stops_the_service(self):
        os.kill(self.workers[0], signal.SIGKILL)
        self.assertEqual(self.service.wait(timeout=5), 1)
        self.assertTrue(self._gone(self.workers[1]))


if __name__ == "__main__":
    unittest.main()
