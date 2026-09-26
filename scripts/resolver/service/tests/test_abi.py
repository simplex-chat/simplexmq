import time
import unittest

from snrc_resolve import abi, config, registration_status, rpc


class EncodedLabelhashTests(unittest.TestCase):
    # keccak-256("alice"), written out in full wherever a test needs it.
    # 9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501

    REGISTRAR = "0xef47eb4384b46c89e4482a677c2cbcbd2a6fd85a"
    GRACE = 90 * 86400

    def setUp(self):
        self._saved = (config.REGISTRARS, config.CONTROLLERS, rpc.eth_call, registration_status.chain_now)
        config.REGISTRARS = {"testing": self.REGISTRAR}
        config.CONTROLLERS = {"testing": ""}
        registration_status.chain_now = lambda: int(time.time())

    def tearDown(self):
        config.REGISTRARS, config.CONTROLLERS, rpc.eth_call, registration_status.chain_now = self._saved

    def test_the_encoded_form_is_recognised(self):
        self.assertTrue(
            abi.is_encoded_labelhash(
                "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
            )
        )

    def test_an_ordinary_label_is_not(self):
        self.assertFalse(abi.is_encoded_labelhash("alice"))
        self.assertFalse(abi.is_encoded_labelhash("[alice]"))
        self.assertFalse(abi.is_encoded_labelhash("9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501"))

    def test_non_hex_between_the_brackets_is_not(self):
        self.assertFalse(abi.is_encoded_labelhash("[" + "z" * 64 + "]"))
        # uppercase is rejected because the handler lowercases the whole name
        self.assertFalse(abi.is_encoded_labelhash("[" + "A" * 64 + "]"))
        self.assertFalse(abi.is_encoded_labelhash("[0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"))

    def test_the_wrong_length_is_not(self):
        self.assertFalse(abi.is_encoded_labelhash("[" + "a" * 63 + "]"))
        self.assertFalse(abi.is_encoded_labelhash("[" + "a" * 65 + "]"))

    def test_hash_and_label_reach_the_same_node(self):
        self.assertEqual(
            abi.node_of("alice.testing"),
            abi.node_of(
                "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
                ".testing"
            ),
        )

    def test_a_plain_name_is_unaffected(self):
        self.assertEqual(abi.node_of("alice.testing"), abi.namehash("alice.testing"))

    def test_a_bracket_subname_label_stays_literal(self):
        """Only the 2LD is a key, so a bracket label left of it is hashed as
        written."""
        self.assertNotEqual(
            abi.node_of(
                "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
                ".alice.testing"
            ),
            abi.namehash("alice.alice.testing"),
        )

    def test_a_0x_prefixed_label_is_taken_literally(self):
        name = "0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501.testing"
        self.assertEqual(abi.node_of(name), abi.namehash(name))
        self.assertNotEqual(abi.node_of(name), abi.node_of("alice.testing"))

    def test_a_malformed_bracket_label_falls_back_to_a_literal_name(self):
        name = "[nothex].testing"
        self.assertEqual(abi.node_of(name), abi.namehash(name))

    def test_status_by_hash_matches_status_by_name(self):
        future = int(time.time()) + 86400
        seen = []

        def eth_call(to, data):
            seen.append(data)
            if data.startswith(abi.selector("GRACE_PERIOD()")):
                return "0x" + abi.encode_uint(self.GRACE)
            return "0x" + abi.encode_uint(future)

        rpc.eth_call = eth_call
        by_name = registration_status.name_status("alice.testing")
        by_hash = registration_status.name_status(
            "[9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501]"
            ".testing"
        )
        self.assertEqual(by_name, by_hash)
        self.assertEqual(by_name["status"], "registered")
        # nothing in either request carried the label itself
        self.assertTrue(all("alice".encode().hex() not in d for d in seen))
