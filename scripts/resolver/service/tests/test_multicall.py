import unittest

from snrc_resolve import multicall
from fakes import FakeChain, decode_aggregate3_calls, encode_aggregate3_results


class Aggregate3Tests(unittest.TestCase):
    def test_calls_are_encoded_as_multicall3_reads_them(self):
        calls = [(FakeChain.REGISTRY, "0x0178b8bf" + "11" * 32), (FakeChain.RESOLVER, "0x59d1d43c" + "22" * 100)]
        data = multicall.encode_aggregate3(calls)
        self.assertTrue(data.startswith(multicall.AGGREGATE3))
        self.assertEqual(decode_aggregate3_calls(data), calls)

    def test_results_are_decoded_with_their_success_flags(self):
        results = [(True, b"\x01" * 40), (False, b""), (True, b"")]
        self.assertEqual(multicall.decode_aggregate3(encode_aggregate3_results(results)), results)

    def test_a_truncated_answer_is_refused(self):
        whole = encode_aggregate3_results([(True, b"\x01" * 40)])
        with self.assertRaises(ValueError):
            multicall.decode_aggregate3(whole[:-64])
        with self.assertRaises(ValueError):
            multicall.decode_aggregate3("0x")
