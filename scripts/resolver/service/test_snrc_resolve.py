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


if __name__ == "__main__":
    unittest.main()
