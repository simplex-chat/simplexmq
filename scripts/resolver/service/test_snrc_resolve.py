#!/usr/bin/env python3
"""Unit tests for snrc-resolve helpers.

Run with `python3 -m unittest scripts/resolver/service/test_snrc_resolve.py`.
"""

import importlib.util
import json
import os
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

# snrc-resolve.py has a hyphen, so import it via importlib instead of `import`.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "snrc_resolve", os.path.join(_HERE, "snrc-resolve.py")
)
snrc = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(snrc)


class AbiCodecTests(unittest.TestCase):
    """The word-level codec the owner lookup is built from. Wrong padding here
    is a silently empty answer rather than an error, so each direction is
    pinned."""

    def test_address_is_left_padded_to_a_word_and_lowercased(self):
        self.assertEqual(
            snrc.encode_address("0xEF47eb4384b46C89E4482a677c2cbcbd2a6fd85a"),
            "00" * 12 + "ef47eb4384b46c89e4482a677c2cbcbd2a6fd85a",
        )

    def test_uint_round_trips_through_a_word(self):
        for n in (0, 1, 42, 2**64, 2**255):
            self.assertEqual(snrc.decode_uint("0x" + snrc.encode_uint(n)), n)

    def test_decode_uint_of_empty_is_zero(self):
        self.assertEqual(snrc.decode_uint(""), 0)
        self.assertEqual(snrc.decode_uint("0x"), 0)

    def test_decode_string_reads_the_dynamic_layout(self):
        label = b"alice"
        word = (32).to_bytes(32, "big") + len(label).to_bytes(32, "big")
        padded = label + b"\x00" * (32 - len(label))
        self.assertEqual(snrc.decode_string("0x" + (word + padded).hex()), "alice")

    def test_decode_string_of_empty_return_is_empty(self):
        self.assertEqual(snrc.decode_string("0x"), "")

    def test_is_address_accepts_only_20_byte_hex(self):
        self.assertTrue(snrc.is_address("0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"))
        self.assertTrue(snrc.is_address("0xEF47EB4384B46C89E4482A677C2CBCBD2A6FD85A"))
        self.assertFalse(snrc.is_address("ef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"))
        self.assertFalse(snrc.is_address("0xef47eb"))
        self.assertFalse(snrc.is_address("0x" + "g" * 40))


class OwnedByTests(unittest.TestCase):
    """owner -> names, read off the ERC-721 registrar.

    The registrar's own invariant is that enumeration is maintained on
    transfer/mint/burn and NOT on expiry, so an expired name stays enumerable
    until it is re-registered. These pin the filter that follows from it.
    """

    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    OWNER = "0x69a6000000000000000000000000000000002d32"
    GRACE = 90 * 86400

    def _fake_chain(self, tokens):
        """tokens :: [(labelhash, label, expires)] held by OWNER."""
        sel = snrc.selector

        def eth_call(to, data):
            self.assertEqual(to, self.REGISTRAR)
            if data.startswith(sel("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            if data.startswith(sel("balanceOf(address)")):
                return "0x" + snrc.encode_uint(len(tokens))
            if data.startswith(sel("tokenOfOwnerByIndex(address,uint256)")):
                i = int(data[-64:], 16)
                return "0x" + snrc.encode_uint(tokens[i][0])
            if data.startswith(sel("nameExpires(uint256)")):
                tid = int(data[-64:], 16)
                return "0x" + snrc.encode_uint(dict((t[0], t[2]) for t in tokens)[tid])
            if data.startswith(sel("labelOf(uint256)")):
                tid = int(data[-64:], 16)
                label = dict((t[0], t[1]) for t in tokens)[tid].encode()
                head = (32).to_bytes(32, "big") + len(label).to_bytes(32, "big")
                pad = b"\x00" * ((-len(label)) % 32)
                return "0x" + (head + label + pad).hex()
            raise AssertionError("unexpected call " + data[:10])

        return eth_call

    def setUp(self):
        self._registrars = snrc.REGISTRARS
        self._eth_call = snrc.eth_call
        snrc.REGISTRARS = {"testing": self.REGISTRAR, "simplex": ""}

    def tearDown(self):
        snrc.REGISTRARS = self._registrars
        snrc.eth_call = self._eth_call

    def test_lists_names_with_their_labels(self):
        future = int(time.time()) + 86400
        snrc.eth_call = self._fake_chain([(11, "alice", future), (22, "bob", future)])
        status, body = snrc.owned_by(self.OWNER)
        self.assertEqual(status, 200)
        self.assertEqual([n["name"] for n in body["names"]], ["alice.testing", "bob.testing"])
        self.assertFalse(body["truncated"])
        self.assertEqual(body["checkedTlds"], ["testing"])

    def test_expired_names_are_reported_not_dropped(self):
        """A scan is how a user finds out a name lapsed, so an expired name has
        to come back labelled rather than vanish."""
        now = int(time.time())
        snrc.eth_call = self._fake_chain(
            [(11, "live", now + 86400), (22, "lapsed", now - 1)]
        )
        _, body = snrc.owned_by(self.OWNER)
        self.assertEqual([n["name"] for n in body["names"]], ["lapsed.testing", "live.testing"])
        by_name = {n["name"]: n for n in body["names"]}
        self.assertEqual(by_name["live.testing"]["status"], "registered")
        # lapsed an hour ago, so still renewable by its owner
        self.assertEqual(by_name["lapsed.testing"]["status"], "grace")
        self.assertEqual(by_name["lapsed.testing"]["expires"], now - 1)
        self.assertEqual(by_name["lapsed.testing"]["graceEnds"], now - 1 + self.GRACE)

    def test_a_name_past_grace_is_reported_as_claimable(self):
        now = int(time.time())
        snrc.eth_call = self._fake_chain([(11, "gone", now - self.GRACE - 3600)])
        _, body = snrc.owned_by(self.OWNER)
        self.assertEqual(body["names"][0]["status"], "expired")

    def test_status_uses_the_same_vocabulary_as_resolve(self):
        now = int(time.time())
        snrc.eth_call = self._fake_chain([(11, "live", now + 86400)])
        _, body = snrc.owned_by(self.OWNER)
        self.assertIn(
            body["names"][0]["status"], ("registered", "grace", "expired", "unregistered")
        )

    def test_a_name_with_no_recorded_label_is_reported_by_labelhash(self):
        future = int(time.time()) + 86400
        snrc.eth_call = self._fake_chain([(11, "", future)])
        _, body = snrc.owned_by(self.OWNER)
        self.assertEqual(body["names"][0]["name"], None)
        # a labelhash is bytes32, not the shortest integer literal that fits
        self.assertEqual(body["names"][0]["labelhash"], "0x" + "0" * 63 + "b")

    def test_enumeration_is_bounded_and_offers_a_cursor(self):
        future = int(time.time()) + 86400
        snrc.MAX_OWNED, keep = 2, snrc.MAX_OWNED
        try:
            snrc.eth_call = self._fake_chain(
                [(i, "n%d" % i, future) for i in range(1, 6)]
            )
            _, body = snrc.owned_by(self.OWNER)
            self.assertEqual(len(body["names"]), 2)
            self.assertTrue(body["truncated"])
            # a flag with no way to act on it is a dead end, so it carries one
            self.assertEqual(body["nextOffset"], 2)
        finally:
            snrc.MAX_OWNED = keep

    def test_the_cursor_walks_the_whole_list_without_repeats(self):
        future = int(time.time()) + 86400
        snrc.MAX_OWNED, keep = 2, snrc.MAX_OWNED
        try:
            snrc.eth_call = self._fake_chain(
                [(i, "n%d" % i, future) for i in range(1, 6)]
            )
            seen, offset = [], 0
            while offset is not None:
                _, body = snrc.owned_by(self.OWNER, offset)
                seen += [n["name"] for n in body["names"]]
                offset = body["nextOffset"]
            self.assertEqual(sorted(seen), sorted("n%d.testing" % i for i in range(1, 6)))
            self.assertEqual(len(seen), len(set(seen)))
        finally:
            snrc.MAX_OWNED = keep

    def test_an_offset_past_the_end_is_an_empty_page_not_an_error(self):
        future = int(time.time()) + 86400
        snrc.eth_call = self._fake_chain([(1, "only", future)])
        status, body = snrc.owned_by(self.OWNER, 99)
        self.assertEqual(status, 200)
        self.assertEqual(body["names"], [])
        self.assertIsNone(body["nextOffset"])

    def test_a_malformed_address_is_refused_before_any_rpc(self):
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        status, body = snrc.owned_by("0xnope")
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "badAddress")
        self.assertIn("address", body["message"])

    def test_no_configured_registrar_is_an_error_not_an_empty_list(self):
        snrc.REGISTRARS = {"testing": "", "simplex": ""}
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        status, body = snrc.owned_by(self.OWNER)
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "noRegistrarConfigured")
        self.assertEqual(body["configuredTlds"], [])


class LabelhashQueryTests(unittest.TestCase):
    """Asking by labelhash instead of by label.

    A client checking whether a name is free is about to register it, so
    telling the resolver which name that is hands whoever runs it a
    front-running opportunity. namehash is keccak(parent || keccak(label)), so
    a caller who supplies keccak(label) gets an identical answer having said
    nothing about the name."""

    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    GRACE = 90 * 86400

    def setUp(self):
        self._saved = (snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call)
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": ""}

    def tearDown(self):
        snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call = self._saved

    def test_a_hashed_label_is_recognised_and_a_real_one_is_not(self):
        self.assertTrue(snrc.is_labelhash("0x" + snrc.keccak(b"alice").hex()))
        self.assertFalse(snrc.is_labelhash("alice"))
        self.assertFalse(snrc.is_labelhash("0x" + "z" * 64))
        # a label cannot be this long, which is what keeps the forms apart
        self.assertFalse(snrc.is_labelhash("0x" + "a" * 62))

    def test_hash_and_label_give_the_same_token_and_node(self):
        h = "0x" + snrc.keccak(b"alice").hex()
        self.assertEqual(snrc.label_token("alice"), snrc.label_token(h))
        self.assertEqual(snrc.node_of("alice.testing"), snrc.node_of(h + ".testing"))

    def test_status_by_hash_matches_status_by_name(self):
        future = int(time.time()) + 86400
        seen = []

        def eth_call(to, data):
            seen.append(data)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            return "0x" + snrc.encode_uint(future)

        snrc.eth_call = eth_call
        h = "0x" + snrc.keccak(b"alice").hex()
        by_name = snrc.name_status("alice.testing")
        by_hash = snrc.name_status(h + ".testing")
        self.assertEqual(by_name, by_hash)
        self.assertEqual(by_name["status"], "registered")
        # nothing in either request carried the label itself
        self.assertTrue(all("alice".encode().hex() not in d for d in seen))


class ReservedTests(unittest.TestCase):
    """A reserved name is unregistered and still unavailable, which a client
    intending to register needs to know before it tries."""

    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"

    def setUp(self):
        self._saved = (snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call)
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": self.CONTROLLER}

    def tearDown(self):
        snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call = self._saved

    def _chain(self, expires, reserved):
        def eth_call(to, data):
            if data.startswith(snrc.selector("reservedNames(bytes32)")):
                self.assertEqual(to, self.CONTROLLER)
                return "0x" + snrc.encode_uint(1 if reserved else 0)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(90 * 86400)
            return "0x" + snrc.encode_uint(expires)

        return eth_call

    def test_unregistered_and_reserved_reads_reserved(self):
        snrc.eth_call = self._chain(0, True)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "reserved")

    def test_unregistered_and_not_reserved_reads_unregistered(self):
        snrc.eth_call = self._chain(0, False)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "unregistered")

    def test_a_lapsed_reserved_name_is_reserved_not_claimable(self):
        past = int(time.time()) - 91 * 86400
        snrc.eth_call = self._chain(past, True)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "reserved")

    def test_a_live_name_is_registered_even_if_reserved(self):
        """It was handed to its brand; the reservation is no longer the answer."""
        snrc.eth_call = self._chain(int(time.time()) + 86400, True)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "registered")

    def test_a_name_in_grace_belongs_to_its_owner_not_the_reserved_set(self):
        snrc.eth_call = self._chain(int(time.time()) - 3600, True)
        self.assertEqual(snrc.name_status("acme.testing")["status"], "grace")

    def test_no_controller_configured_means_reserved_is_never_reported(self):
        snrc.CONTROLLERS = {"testing": ""}
        snrc.eth_call = self._chain(0, True)  # would say reserved if asked
        self.assertEqual(snrc.name_status("acme.testing")["status"], "unregistered")

    def test_reserved_is_asked_by_labelhash_so_a_hashed_query_works(self):
        h = "0x" + snrc.keccak(b"acme").hex()
        snrc.eth_call = self._chain(0, True)
        self.assertEqual(snrc.name_status(h + ".testing")["status"], "reserved")


class ReservedReasonTests(unittest.TestCase):
    """Why a name is reserved travels in its own field, so a client can show it
    without parsing the message, and so a per-name reason can replace the fixed
    one without moving anything."""

    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"

    def setUp(self):
        self._saved = (
            snrc.REGISTRIES,
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
        )
        snrc.REGISTRIES = {"testing": self.REGISTRY}
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": self.CONTROLLER}

    def tearDown(self):
        (
            snrc.REGISTRIES,
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
        ) = self._saved

    def _chain(self, expires, reserved):
        def eth_call(to, data):
            if data.startswith(snrc.selector("reservedNames(bytes32)")):
                return "0x" + snrc.encode_uint(1 if reserved else 0)
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(90 * 86400)
            return "0x" + snrc.encode_uint(expires)

        return eth_call

    def test_a_reserved_name_carries_the_reason(self):
        snrc.eth_call = self._chain(0, True)
        status, body = snrc.resolve("acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["status"], "reserved")
        self.assertEqual(body["reason"], "reserved for a brand or public interest")

    def test_the_message_does_not_claim_a_trademark(self):
        snrc.eth_call = self._chain(0, True)
        _, body = snrc.resolve("acme.testing")
        self.assertNotIn("trademark", body["message"])

    def test_an_unregistered_name_has_no_reason(self):
        snrc.eth_call = self._chain(0, False)
        status, body = snrc.resolve("acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["status"], "unregistered")
        self.assertNotIn("reason", body)

    def test_an_expired_name_has_no_reason(self):
        snrc.eth_call = self._chain(1, False)
        status, body = snrc.resolve("acme.testing")
        self.assertEqual(status, 410)
        self.assertEqual(body["status"], "expired")
        self.assertNotIn("reason", body)

    def test_a_hashed_query_gets_the_reason_too(self):
        snrc.eth_call = self._chain(0, True)
        h = "0x" + snrc.keccak(b"acme").hex()
        _, body = snrc.resolve(h + ".testing")
        self.assertEqual(body["reason"], "reserved for a brand or public interest")


class NameStatusTests(unittest.TestCase):
    """simplexmq#1821: unresolvable has three causes and a caller has to tell
    them apart. Names expire lazily, so the chain still holds the answer."""

    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"

    GRACE = 90 * 86400

    def _expiry(self, value):
        def eth_call(to, data):
            if data.startswith(snrc.selector("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(self.GRACE)
            self.assertTrue(data.startswith(snrc.selector("nameExpires(uint256)")))
            return "0x" + snrc.encode_uint(value)

        return eth_call

    def setUp(self):
        self._saved = (snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call)
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        # These cases are about expiry alone. ReservedTests covers what a
        # configured controller adds.
        snrc.CONTROLLERS = {"testing": ""}

    def tearDown(self):
        snrc.REGISTRARS, snrc.CONTROLLERS, snrc.eth_call = self._saved

    def test_zero_expiry_means_never_registered(self):
        snrc.eth_call = self._expiry(0)
        self.assertEqual(
            snrc.name_status("alice.testing"),
            {"status": "unregistered", "expires": None, "graceEnds": None},
        )

    def test_recently_expired_is_in_grace_and_says_when_it_ends(self):
        """Only the previous owner may renew during grace - nobody else can
        take the name yet, so this is a different answer from `expired`."""
        past = int(time.time()) - 3600
        snrc.eth_call = self._expiry(past)
        self.assertEqual(
            snrc.name_status("alice.testing"),
            {"status": "grace", "expires": past, "graceEnds": past + self.GRACE},
        )

    def test_past_the_grace_window_it_is_expired_and_claimable(self):
        past = int(time.time()) - self.GRACE - 3600
        snrc.eth_call = self._expiry(past)
        self.assertEqual(snrc.name_status("alice.testing")["status"], "expired")

    def test_the_boundary_belongs_to_grace(self):
        """The registrar frees a name when expires + GRACE < now, so the last
        second of the window is still the owner's."""
        now = int(time.time())
        snrc.eth_call = self._expiry(now - self.GRACE)
        self.assertEqual(snrc.name_status("alice.testing")["status"], "grace")

    def test_future_expiry_is_registered(self):
        future = int(time.time()) + 3600
        snrc.eth_call = self._expiry(future)
        self.assertEqual(
            snrc.name_status("alice.testing"),
            {"status": "registered", "expires": future, "graceEnds": future + self.GRACE},
        )

    def test_never_registered_is_not_confused_with_claimable(self):
        """`available(id)` is true for both, since 0 + GRACE < now. The zero
        expiry is the only thing that separates them."""
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

    def test_unconfigured_tld_is_unknown_rather_than_unregistered(self):
        snrc.REGISTRARS = {"testing": ""}
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        self.assertEqual(
            snrc.name_status("alice.testing"),
            {"status": "unknown", "expires": None, "graceEnds": None},
        )

    def test_every_branch_returns_the_same_keys(self):
        """Callers read status/expires/graceEnds unconditionally, so a branch
        that omits one is a KeyError in the caller rather than a missing field
        in the JSON."""
        keys = {"status", "expires", "graceEnds"}
        snrc.eth_call = self._expiry(0)
        self.assertEqual(set(snrc.name_status("alice.testing")), keys)
        snrc.eth_call = self._expiry(int(time.time()) + 3600)
        self.assertEqual(set(snrc.name_status("alice.testing")), keys)
        snrc.REGISTRARS = {"testing": ""}
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        self.assertEqual(set(snrc.name_status("alice.testing")), keys)


class AuthTests(unittest.TestCase):
    """The Haskell client has always been able to send `Authorization`; until
    now nothing here read it, so configuring auth protected nothing."""

    def setUp(self):
        self._saved = (snrc.AUTH_BEARER, snrc.AUTH_BASIC)

    def tearDown(self):
        snrc.AUTH_BEARER, snrc.AUTH_BASIC = self._saved

    def test_no_secret_configured_accepts_anything(self):
        snrc.AUTH_BEARER = snrc.AUTH_BASIC = ""
        self.assertTrue(snrc.auth_ok(""))
        self.assertTrue(snrc.auth_ok("Bearer whatever"))

    def test_bearer_accepts_only_the_configured_token(self):
        snrc.AUTH_BEARER, snrc.AUTH_BASIC = "sekrit", ""
        self.assertTrue(snrc.auth_ok("Bearer sekrit"))
        self.assertFalse(snrc.auth_ok("Bearer sekri"))
        self.assertFalse(snrc.auth_ok("Bearer sekrit2"))
        self.assertFalse(snrc.auth_ok(""))
        self.assertFalse(snrc.auth_ok(None))

    def test_basic_matches_what_the_haskell_client_builds(self):
        snrc.AUTH_BEARER, snrc.AUTH_BASIC = "", "user:pass"
        # HttpResolver.hs: "Basic " <> base64(user <> ":" <> password)
        self.assertEqual(snrc.expected_auth_header(), "Basic dXNlcjpwYXNz")
        self.assertTrue(snrc.auth_ok("Basic dXNlcjpwYXNz"))
        self.assertFalse(snrc.auth_ok("Basic bm9wZQ=="))


class CallCacheTests(unittest.TestCase):
    """One /resolve is 15 upstream calls and one /owned-by can be hundreds, so
    repeating a call the node just answered is the cost worth removing."""

    def setUp(self):
        self._saved = (snrc.eth_call, snrc.rpc, snrc.CACHE_TTL, dict(snrc._CALL_CACHE))
        snrc._CALL_CACHE.clear()

    def tearDown(self):
        snrc.eth_call, snrc.rpc, snrc.CACHE_TTL, cache = self._saved
        snrc._CALL_CACHE.clear()
        snrc._CALL_CACHE.update(cache)

    def test_a_repeated_call_asks_the_node_once(self):
        calls = []
        snrc.rpc = lambda method, params: calls.append(params) or "0x2a"
        snrc.CACHE_TTL = 60
        self.assertEqual(snrc.eth_call("0xto", "0xdata"), "0x2a")
        self.assertEqual(snrc.eth_call("0xto", "0xdata"), "0x2a")
        self.assertEqual(len(calls), 1)

    def test_different_calls_are_not_confused(self):
        snrc.rpc = lambda method, params: params[0]["data"]
        snrc.CACHE_TTL = 60
        self.assertEqual(snrc.eth_call("0xto", "0xaa"), "0xaa")
        self.assertEqual(snrc.eth_call("0xto", "0xbb"), "0xbb")
        self.assertEqual(snrc.eth_call("0xother", "0xaa"), "0xaa")

    def test_zero_ttl_disables_it(self):
        calls = []
        snrc.rpc = lambda method, params: calls.append(1) or "0x"
        snrc.CACHE_TTL = 0
        snrc.eth_call("0xto", "0xdata")
        snrc.eth_call("0xto", "0xdata")
        self.assertEqual(len(calls), 2)


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


class HandlerTests(unittest.TestCase):
    """The HTTP layer: routing, auth, query parsing, and the mapping from a
    (status, body) pair to a response.

    These go over a real socket because that is the only way to reach them —
    every branch here lives in `do_GET`, which no function-level test calls.
    """

    REGISTRY = "0x58fc46996d975c57883564648bda5206d1a0102b"
    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    CONTROLLER = "0x281ca41311c2aa808c917c4674639d7567b75714"
    RESOLVER = "0x1111111111111111111111111111111111111111"
    OWNER = "0x69a6000000000000000000000000000000002d32"
    FUTURE = 4102444800  # 2100-01-01

    def setUp(self):
        self._saved = {
            k: getattr(snrc, k)
            for k in (
                "REGISTRIES",
                "REGISTRARS",
                "CONTROLLERS",
                "AUTH_BEARER",
                "AUTH_BASIC",
                "eth_call",
                "text",
                "addr_multicoin",
            )
        }
        snrc.REGISTRIES = {"testing": self.REGISTRY}
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        snrc.CONTROLLERS = {"testing": self.CONTROLLER}
        snrc.AUTH_BEARER = ""
        snrc.AUTH_BASIC = ""
        self.chain(expires=self.FUTURE)

        class Quiet(snrc.Handler):
            def log_message(self, fmt, *args):
                pass

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
        # Default poll_interval is 0.5s and shutdown() waits for it, which
        # would cost half a second per test in this class alone.
        threading.Thread(
            target=self.srv.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        ).start()
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        for k, v in self._saved.items():
            setattr(snrc, k, v)

    # -- fixtures ---------------------------------------------------------

    def chain(self, expires, reserved=False, resolver=None, raises=None):
        """Install a fake chain. `raises` makes every call fail, which is how
        the 502 path is reached."""
        resolver = self.RESOLVER if resolver is None else resolver
        sel = snrc.selector

        def eth_call(to, data):
            if raises is not None:
                raise raises
            if data.startswith(sel("reservedNames(bytes32)")):
                return "0x" + snrc.encode_uint(1 if reserved else 0)
            if data.startswith(sel("GRACE_PERIOD()")):
                return "0x" + snrc.encode_uint(90 * 86400)
            if data.startswith(sel("nameExpires(uint256)")):
                return "0x" + snrc.encode_uint(expires)
            if data.startswith(sel("resolver(bytes32)")):
                return "0x" + snrc.encode_uint(int(resolver, 16))
            if data.startswith(sel("owner(bytes32)")):
                return "0x" + snrc.encode_uint(int(self.OWNER, 16))
            if data.startswith(sel("balanceOf(address)")):
                return "0x" + snrc.encode_uint(1)
            if data.startswith(sel("tokenOfOwnerByIndex(address,uint256)")):
                return "0x" + snrc.encode_uint(int.from_bytes(snrc.keccak(b"acme"), "big"))
            if data.startswith(sel("labelOf(uint256)")):
                label = b"acme"
                head = (32).to_bytes(32, "big") + len(label).to_bytes(32, "big")
                return "0x" + (head + label + b"\x00" * 28).hex()
            raise AssertionError("unexpected call " + data[:10])

        snrc.eth_call = eth_call
        snrc.text = lambda r, node, key: {"name": "Acme", "url": "https://acme.example"}.get(key, "")
        snrc.addr_multicoin = lambda r, node, coin: (
            self.OWNER if coin == snrc.COIN_ETH else None
        )

    def get(self, path, auth=None):
        req = urllib.request.Request(self.base + path)
        if auth is not None:
            req.add_header("Authorization", auth)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json.loads(e.read())

    # -- routing ----------------------------------------------------------

    def test_health_reports_the_version_and_the_registrars(self):
        status, body = self.get("/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["version"], snrc.API_VERSION)
        # Present so an operator can see why status would read "unknown".
        self.assertEqual(body["registrars"], {"testing": self.REGISTRAR})

    def test_an_unknown_route_names_the_routes_that_exist(self):
        status, body = self.get("/nope")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "noSuchRoute")
        self.assertIn("/resolve/<name>", body["routes"])

    def test_the_root_path_is_not_a_route(self):
        status, body = self.get("/")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "noSuchRoute")

    # -- auth -------------------------------------------------------------

    def test_no_auth_configured_means_no_header_is_needed(self):
        self.assertEqual(self.get("/health")[0], 200)

    def test_a_configured_token_is_required(self):
        snrc.AUTH_BEARER = "s3cret"
        status, body = self.get("/health")
        self.assertEqual(status, 401)
        self.assertEqual(body["error"], "unauthorized")

    def test_the_right_token_is_accepted(self):
        snrc.AUTH_BEARER = "s3cret"
        self.assertEqual(self.get("/health", auth="Bearer s3cret")[0], 200)

    def test_a_wrong_token_is_refused(self):
        snrc.AUTH_BEARER = "s3cret"
        self.assertEqual(self.get("/health", auth="Bearer nope")[0], 401)

    def test_auth_is_checked_before_the_route_exists(self):
        # An unauthenticated caller learns nothing about which routes exist.
        snrc.AUTH_BEARER = "s3cret"
        status, body = self.get("/nope")
        self.assertEqual(status, 401)
        self.assertNotIn("routes", body)

    # -- /resolve ---------------------------------------------------------

    def test_a_live_name_returns_its_record(self):
        status, body = self.get("/resolve/acme.testing")
        self.assertEqual(status, 200)
        self.assertEqual(body["name"], "acme.testing")
        self.assertEqual(body["nickname"], "Acme")
        self.assertEqual(body["website"], "https://acme.example")
        self.assertEqual(body["owner"], self.OWNER)
        self.assertEqual(body["status"], "registered")
        self.assertEqual(body["expires"], self.FUTURE)

    def test_a_bare_label_is_rejected_before_any_rpc(self):
        self.chain(expires=0, raises=AssertionError("must not reach the chain"))
        status, body = self.get("/resolve/acme")
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "notFullyQualified")

    def test_a_name_is_lowercased(self):
        status, body = self.get("/resolve/ACME.TESTING")
        self.assertEqual(status, 200)
        self.assertEqual(body["name"], "acme.testing")

    def test_a_reserved_name_is_404_with_its_reason(self):
        self.chain(expires=0, reserved=True)
        status, body = self.get("/resolve/acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["status"], "reserved")
        self.assertEqual(body["reason"], "reserved for a brand or public interest")

    def test_an_expired_name_is_410(self):
        self.chain(expires=1)
        status, body = self.get("/resolve/acme.testing")
        self.assertEqual(status, 410)
        self.assertEqual(body["status"], "expired")

    def test_a_name_with_no_resolver_is_404(self):
        self.chain(expires=self.FUTURE, resolver=snrc.ZERO_ADDR)
        status, body = self.get("/resolve/acme.testing")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"], "noResolver")

    def test_an_unconfigured_tld_is_400(self):
        status, body = self.get("/resolve/acme.example")
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "tldNotConfigured")
        self.assertEqual(body["configuredTlds"], ["testing"])

    # -- /owned-by --------------------------------------------------------

    def test_owned_by_lists_the_names_held(self):
        status, body = self.get("/owned-by/" + self.OWNER)
        self.assertEqual(status, 200)
        self.assertEqual([n["name"] for n in body["names"]], ["acme.testing"])
        self.assertEqual(body["offset"], 0)

    def test_a_negative_offset_is_rejected(self):
        status, body = self.get("/owned-by/%s?offset=-1" % self.OWNER)
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "badOffset")

    def test_a_non_numeric_offset_is_rejected(self):
        status, body = self.get("/owned-by/%s?offset=abc" % self.OWNER)
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "badOffset")

    def test_a_bad_address_is_rejected(self):
        status, body = self.get("/owned-by/not-an-address")
        self.assertEqual(status, 400)
        self.assertEqual(body["error"], "badAddress")

    # -- upstream failure -------------------------------------------------

    def test_an_rpc_failure_is_502_and_does_not_leak_the_rpc_url(self):
        # SNRC_RPC can carry a key, and urlopen puts the URL it failed on into
        # the exception message, so the body must not quote the exception.
        self.chain(expires=0, raises=RuntimeError("failed on http://user:key@rpc.internal:8545"))
        status, body = self.get("/resolve/acme.testing")
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "upstreamError")
        self.assertNotIn("rpc.internal", json.dumps(body))
        self.assertNotIn("key", json.dumps(body))

    def test_an_rpc_failure_on_owned_by_is_also_502(self):
        self.chain(expires=0, raises=RuntimeError("boom"))
        status, body = self.get("/owned-by/" + self.OWNER)
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "upstreamError")


if __name__ == "__main__":
    unittest.main()
