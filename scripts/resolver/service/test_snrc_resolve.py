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
    """Querying by labelhash instead of by label.

    A client that asks whether a name is free is usually about to register it,
    and whoever runs the resolver could register it first. namehash is
    keccak(parent || keccak(label)), so supplying keccak(label) gives the same
    node and the same answer without sending the label.

    The encoding is ENS's own `[<64 hex>]`. It cannot collide with a real name,
    because brackets are not valid in a normalised ENS name."""

    # keccak-256("alice") = 9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501
    # - written out in full wherever a test needs a real labelhash.

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
        # uppercase hex is not it either: the handler lowercases the whole name
        self.assertFalse(snrc.is_encoded_labelhash("[" + "A" * 64 + "]"))
        # explicitly disallowed prefix
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

    def test_an_encoded_subname_is_not_the_name_it_would_decode_to(self):
        """Only 2LDs are queried by hash. If a label in `[<64 hex>]` form were
        decoded in a subname, that subname would silently be the name the hash
        stands for - here `alice.alice.testing`."""
        self.assertNotEqual(
            snrc.node_of(
                "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
                ".alice.testing"
            ),
            snrc.namehash("alice.alice.testing"),
        )
        self.assertNotEqual(
            snrc.node_of(
                "alice."
                "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
                ".testing"
            ),
            snrc.namehash("alice.alice.testing"),
        )

    def test_a_0x_prefixed_label_is_taken_literally(self):
        """`0x<64 hex>` is a registrable name, not a hash. Only the bracket
        form is read as a labelhash."""
        name = "0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501.testing"
        self.assertEqual(snrc.node_of(name), snrc.namehash(name))
        self.assertNotEqual(snrc.node_of(name), snrc.node_of("alice.testing"))

    def test_a_malformed_bracket_label_falls_back_to_a_literal_name(self):
        name = "[nothex].testing"
        self.assertEqual(snrc.node_of(name), snrc.namehash(name))

    def test_status_by_hash_matches_status_by_name(self):
        """The registrar keys registration data on the labelhash too. A hashed
        query therefore answers "is it free?" as well as "what does it say?",
        without the label."""
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
    """unresolvable has three causes and a caller has to tell them apart.
    Names expire lazily, so the chain still holds the answer."""

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
        self._saved = (
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
            snrc.rpc,
        )
        snrc.REGISTRARS = {"testing": self.REGISTRAR}
        # These cases are about expiry alone. ReservedTests covers what a
        # configured controller adds.
        snrc.CONTROLLERS = {"testing": ""}
        snrc.chain_now = lambda: int(time.time())

    def tearDown(self):
        (
            snrc.REGISTRARS,
            snrc.CONTROLLERS,
            snrc.eth_call,
            snrc.chain_now,
            snrc.rpc,
        ) = self._saved

    def test_now_is_the_latest_blocks_timestamp(self):
        # setUp replaces chain_now with the fixture clock; this is about the
        # real one, saved as the 4th element of the setUp snapshot
        real_chain_now = self._saved[3]
        snrc.rpc = lambda method, params: {"timestamp": "0x65f1a2c0", "number": "0x123"}
        self.assertEqual(real_chain_now(), 0x65F1A2C0)

    def test_status_reads_the_chain_clock_not_the_host_clock(self):
        """The registrar compares expiry to block.timestamp, so the resolver
        must too - a host clock years ahead must not turn a live name into a
        claimable one."""
        future = int(time.time()) + 3600
        snrc.eth_call = self._expiry(future)
        self.assertEqual(snrc.name_status("alice.testing")["status"], "registered")
        snrc.chain_now = lambda: future + 3650 * 86400
        self.assertEqual(snrc.name_status("alice.testing")["status"], "expired")

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


class ReservedTests(unittest.TestCase):
    """A reserved name is unregistered and still unavailable, which a client
    intending to register needs to know before it tries."""

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
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        snrc.eth_call = self._chain(0, True)
        self.assertEqual(snrc.name_status(hashed + ".testing")["status"], "reserved")


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
        self.assertNotIn("trademark", body["error"])

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
        # keccak-256("acme")
        hashed = "[e29dae06ef4c3e336b7538b6d4f52ca1ecec009b1df6fb501320e11b223aeeaf]"
        _, body = snrc.resolve(hashed + ".testing")
        self.assertEqual(body["reason"], "reserved for a brand or public interest")


if __name__ == "__main__":
    unittest.main()
