#!/usr/bin/env python3
"""Unit tests for snrc-resolve helpers.

Run with `python3 -m unittest scripts/resolver/service/test_snrc_resolve.py`.
"""

import importlib.util
import os
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
    """`node_of` accepts a 2LD's label as an encoded labelhash `[<64 hex>]`,
    reaching the same node as the label itself."""

    # keccak-256("alice"), written out in full wherever a test needs it.
    # 9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501

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

    def test_an_encoded_subname_is_not_the_name_it_would_decode_to(self):
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
        name = "0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501.testing"
        self.assertEqual(snrc.node_of(name), snrc.namehash(name))
        self.assertNotEqual(snrc.node_of(name), snrc.node_of("alice.testing"))

    def test_a_malformed_bracket_label_falls_back_to_a_literal_name(self):
        name = "[nothex].testing"
        self.assertEqual(snrc.node_of(name), snrc.namehash(name))


if __name__ == "__main__":
    unittest.main()
