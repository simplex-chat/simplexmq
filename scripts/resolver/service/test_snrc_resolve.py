#!/usr/bin/env python3
"""Unit tests for snrc-resolve helpers.

Run with `python3 -m unittest scripts/resolver/service/test_snrc_resolve.py`.
"""

import importlib.util
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
        self.assertEqual(body["names"][0]["labelhash"], hex(11))

    def test_enumeration_is_bounded_and_says_so(self):
        future = int(time.time()) + 86400
        snrc.MAX_OWNED, keep = 2, snrc.MAX_OWNED
        try:
            snrc.eth_call = self._fake_chain(
                [(i, "n%d" % i, future) for i in range(1, 6)]
            )
            _, body = snrc.owned_by(self.OWNER)
            self.assertEqual(len(body["names"]), 2)
            self.assertTrue(body["truncated"])
        finally:
            snrc.MAX_OWNED = keep

    def test_a_malformed_address_is_refused_before_any_rpc(self):
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        status, body = snrc.owned_by("0xnope")
        self.assertEqual(status, 400)
        self.assertIn("address", body["error"])

    def test_no_configured_registrar_is_an_error_not_an_empty_list(self):
        snrc.REGISTRARS = {"testing": "", "simplex": ""}
        snrc.eth_call = lambda *a: self.fail("must not reach the chain")
        status, body = snrc.owned_by(self.OWNER)
        self.assertEqual(status, 400)
        self.assertEqual(body["configured_tlds"], [])


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
        self._registrars, self._eth_call = snrc.REGISTRARS, snrc.eth_call
        snrc.REGISTRARS = {"testing": self.REGISTRAR}

    def tearDown(self):
        snrc.REGISTRARS, snrc.eth_call = self._registrars, self._eth_call

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


if __name__ == "__main__":
    unittest.main()
