from urllib.error import HTTPError

from snrc_resolve import abi, answers, calls, rpc
from fakes import FakeChain, FakeNodeTestCase


class RpcTransportTests(FakeNodeTestCase):
    """A lookup makes several reads, and a new connection per read costs CPU
    and leaves a TIME_WAIT socket each, which exhausts local ports under load."""

    def test_reads_share_one_connection(self):
        for _ in range(18):
            self.assertEqual(rpc.call("eth_blockNumber", []), hex(self.node.block))
        self.assertEqual(self.node.connections, 1)

    def test_a_connection_the_node_closed_is_replaced(self):
        self.node.drop_after_reply = True
        for _ in range(3):
            self.assertEqual(rpc.call("eth_blockNumber", []), hex(self.node.block))
        self.assertEqual(self.node.connections, 3)

    def test_a_fresh_connection_that_fails_is_not_retried(self):
        """Only a pooled connection can be stale; a new one failing means the
        node is down, and resending would only double the wait."""
        self.node.hang_up = True
        with self.assertRaises(ConnectionError):
            rpc.call("eth_blockNumber", [])
        self.assertEqual(self.node.requests, 1)

    def test_a_node_failure_is_not_a_reverted_call(self):
        """Callers read RuntimeError as the call reverting and fall back to an
        empty value, so a node failure must not look like one."""
        self.node.status = 502
        with self.assertRaises(HTTPError) as cm:
            rpc.call("eth_blockNumber", [])
        self.assertNotIsInstance(cm.exception, RuntimeError)
        self.assertEqual(cm.exception.code, 502)

    def test_a_reverted_call_is_a_runtime_error_and_keeps_the_connection(self):
        with self.assertRaises(RuntimeError):
            rpc.eth_call("0x" + "11" * 20, "0xdeadbeef")
        rpc.call("eth_blockNumber", [])
        self.assertEqual(self.node.connections, 1)


class BatchedReadsTests(FakeNodeTestCase):
    """Inside a request a round of reads is one round trip, and its contract
    reads one multicall, because a node runs the calls of a JSON-RPC batch one
    after another. Answers must be exactly those of reading one call at a time."""

    def batched(self, answer, name):
        def action():
            with rpc.request_reads():
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
        status, body = self.assert_same_answer(answers.registration, "acme.testing", 2)
        record = body["registration"]["nameRecord"]
        self.assertEqual(record["nickname"], "Acme")
        self.assertEqual(record["simplexChannel"], ["https://a.example/c#1", "https://b.example/c#2"])
        self.assertIsNone(record["btc"])

    def test_a_hashed_query_is_named_from_the_same_round_trip(self):
        hashed = "[" + abi.keccak(b"acme").hex() + "].testing"
        status, body = self.assert_same_answer(answers.registration, hashed, 2)
        self.assertEqual(body["registration"]["nameRecord"]["name"], "acme.testing")

    def test_an_available_name_is_priced_in_three_round_trips(self):
        status, body = self.assert_same_answer(answers.registration, "free.testing", 3)
        self.assertEqual(body["registration"]["type"], "available")

    def test_v1_answers_the_same(self):
        self.assert_same_answer(answers.resolve, "acme.testing", 2)

    def test_without_multicall_a_round_is_still_one_batch(self):
        self.node.multicall = False
        with self.assertLogs("snrc_resolve", "WARNING") as logs:
            self.assert_same_answer(answers.registration, "acme.testing", 4)
        [record] = logs.records
        self.assertEqual((record.getMessage(), record.fields["fallback"]), ("multicall_unavailable", "batch"))

    def test_a_node_that_does_not_batch_is_read_one_call_at_a_time(self):
        self.node.batch = False
        one_by_one, one_by_one_trips = self.requests_made(lambda: answers.registration("acme.testing"))
        with self.assertNoLogs("snrc_resolve"):
            batched, batched_trips = self.batched(answers.registration, "acme.testing")
        self.assertEqual(batched, one_by_one)
        # one refused batch per round, then the reads the batch would have made
        self.assertEqual(batched_trips, one_by_one_trips + 2)

    def test_a_read_reverted_in_the_multicall_is_a_reverted_call(self):
        with rpc.request_reads():
            rpc.prefetch([rpc.eth_call_read(*calls.grace_call(FakeChain.REGISTRAR)), rpc.eth_call_read(FakeChain.REGISTRY, "0xdeadbeef")])
            _, trips = self.requests_made(lambda: self.assertRaises(RuntimeError, rpc.eth_call, FakeChain.REGISTRY, "0xdeadbeef"))
        self.assertEqual(trips, 0)

    def test_outside_a_request_nothing_is_prefetched(self):
        _, trips = self.requests_made(lambda: rpc.prefetch(answers.lookup_reads("acme.testing")))
        self.assertEqual(trips, 0)
