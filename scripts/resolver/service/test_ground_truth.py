import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from eth_hash.auto import keccak

HERE = os.path.dirname(os.path.abspath(__file__))
DEV_CHAIN = os.environ.get("SNRC_DEV_CHAIN", "")
MAINNET_RPC = os.environ.get("SNRC_MAINNET_RPC", "")
DAY = 86400
BAKERY_CONTACT = "https://smp8.simplex.im/a#Y8m3qT0vLw2Ab7cD9eF1gH3jK5mN7pQ9rSAAAAAAAAA"
BAKERY_CHANNEL = "https://smp9.simplex.im/c#Rk27xN4pDe9Tz1Wb3Yc5Vd7Xf9Hg2Jk4LmAAAAAAAAA"
CONTACT = "https://localhost/a#ground-truth"
MENU_CONTACT = "https://localhost/a#menu"
TRADEMARK = 2
COMMUNITY = 3


def get(url):
    try:
        with urlopen(url, timeout=30) as r:
            return r.status, json.load(r)
    except HTTPError as e:
        return e.code, json.load(e)


def wait_for(url, process):
    for _ in range(600):
        if process.poll() is not None:
            raise RuntimeError(f"{process.args[0]} exited with {process.returncode}")
        try:
            urlopen(url, timeout=1).close()
            return
        except HTTPError:
            return
        except OSError:
            time.sleep(0.5)
    raise TimeoutError(url)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_resolver(test_class, env):
    port = free_port()
    process = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "snrc-resolve.py")],
        env={**os.environ, **env, "SNRC_BIND": "127.0.0.1", "SNRC_PORT": str(port), "SNRC_WORKERS": "1"},
    )
    test_class.addClassCleanup(process.terminate)
    url = f"http://127.0.0.1:{port}"
    wait_for(url + "/health", process)
    return url


def rpc(chain, method, *params):
    request = Request(chain, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(), {"Content-Type": "application/json"})
    with urlopen(request, timeout=30) as r:
        body = json.load(r)
    if "error" in body:
        raise RuntimeError(f"{method}: {body['error']}")
    return body["result"]


def namehash(name):
    node = bytes(32)
    for label in reversed(name.split(".")):
        node = keccak(node + keccak(label.encode()))
    return node


def call_data(signature, *args):
    params = signature[signature.index("(") + 1 : -1]
    types = params.split(",") if params else []
    return "0x" + (keccak(signature.encode())[:4] + encode(types, args)).hex()


def encode(types, values):
    heads, tails = [], []
    offset = 32 * len(types)
    for type_, value in zip(types, values, strict=True):
        if type_ in ("string", "string[]"):
            tail = encode_dynamic(type_, value)
            heads.append(offset.to_bytes(32, "big"))
            tails.append(tail)
            offset += len(tail)
        else:
            heads.append(encode_static(value))
    return b"".join(heads + tails)


def encode_static(value):
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        value = int(value, 16)
    return int(value).to_bytes(32, "big")


def encode_dynamic(type_, value):
    if type_ == "string[]":
        return len(value).to_bytes(32, "big") + encode(["string"] * len(value), value)
    data = value.encode()
    return len(data).to_bytes(32, "big") + data + bytes(-len(data) % 32)


def read(chain, contract, signature, *args):
    return rpc(chain, "eth_call", {"to": contract, "data": call_data(signature, *args)}, "latest")


def send(chain, tx):
    tx_hash = rpc(chain, "eth_sendTransaction", tx)
    for _ in range(100):
        receipt = rpc(chain, "eth_getTransactionReceipt", tx_hash)
        if receipt:
            if receipt["status"] != "0x1":
                raise RuntimeError(f"{tx_hash} reverted")
            return receipt
        time.sleep(0.1)
    raise TimeoutError(tx_hash)


def transact(chain, sender, contract, signature, *args):
    return send(chain, {"from": sender, "to": contract, "data": call_data(signature, *args)})


def start_chain(test_class):
    port = free_port()
    anvil = subprocess.Popen(
        [os.path.join(DEV_CHAIN, "anvil"), "--port", str(port), "--block-time", "1", "--mixed-mining"],
        stdout=subprocess.DEVNULL,
    )
    test_class.addClassCleanup(anvil.terminate)
    chain = f"http://127.0.0.1:{port}"
    wait_for(chain, anvil)
    return chain


def deploy(chain):
    with tempfile.TemporaryDirectory() as out:
        deployment = os.path.join(out, "local-chain.json")
        subprocess.run(
            ["node", "dev/deploy.ts"],
            cwd=os.path.join(DEV_CHAIN, "simplex.domains", "webapp"),
            env={
                **os.environ,
                "RPC_URL": chain,
                "ENS_CONTRACTS_DIR": os.path.join(DEV_CHAIN, "ens-contracts"),
                "LOCAL_CHAIN_OUT": deployment,
                "MIN_COMMITMENT_AGE": "1",
            },
            check=True,
        )
        with open(deployment) as f:
            return json.load(f)


def seed_lookup_states(chain, contracts):
    owner, holder = contracts["owner"], contracts["holder"]
    registry, registrar, resolver, policy = contracts["ens"], contracts["baseRegistrar"], contracts["resolver"], contracts["namePolicy"]
    transact(chain, owner, registrar, "addController(address)", owner)
    transact(chain, owner, registrar, "registerWithLabel(string,address,uint256,uint256)", "lapsed", holder, DAY, 0)
    transact(chain, owner, registrar, "registerWithLabel(string,address,uint256,uint256)", "expiring", holder, 30 * DAY, 0)
    transact(chain, holder, registry, "setResolver(bytes32,address)", namehash("expiring.simplex"), resolver)
    transact(chain, holder, resolver, "setText(bytes32,string,string)", namehash("expiring.simplex"), "simplex.contact", CONTACT)
    subnames = "0x" + read(chain, registrar, "subnameHook()")[-40:]
    transact(chain, holder, registry, "setApprovalForAll(address,bool)", subnames, True)
    transact(chain, holder, subnames, "createSubname(bytes32,string)", namehash("bakery.simplex"), "menu")
    transact(chain, holder, resolver, "setText(bytes32,string,string)", namehash("menu.bakery.simplex"), "simplex.contact", MENU_CONTACT)
    transact(chain, owner, policy, "addReservedNames(string[],uint8)", ["brandname"], TRADEMARK)
    transact(chain, owner, policy, "addReservedNames(string[],uint8)", ["privacy"], COMMUNITY)
    grace = int(read(chain, registrar, "GRACE_PERIOD()"), 16)
    rpc(chain, "evm_increaseTime", hex(grace + 2 * DAY))
    rpc(chain, "evm_mine")


def deploy_multicall(chain, sender):
    with open(os.path.join(DEV_CHAIN, "ens-contracts", "artifacts", "contracts", "mocks", "Multicall3.sol", "Multicall3.json")) as f:
        bytecode = json.load(f)["bytecode"]
    return send(chain, {"from": sender, "data": bytecode})["contractAddress"]


class GroundTruthTestCase(unittest.TestCase):
    def registration(self, name):
        status, body = get(f"{self.url}/v2/resolve/{name}")
        self.assertEqual(status, 200, body)
        return body["lastBlockTs"], body["registration"]

    def assert_registered(self, name, contact=None):
        now, reg = self.registration(name)
        self.assertEqual(reg["type"], "registered", name)
        self.assertGreater(reg["graceUntil"], now)
        if contact is not None:
            self.assertEqual(reg["nameRecord"]["simplexContact"], contact)
        return now, reg

    def assert_type(self, name, type_, **fields):
        reg = self.registration(name)[1]
        self.assertEqual(reg["type"], type_, name)
        for key, value in fields.items():
            self.assertEqual(reg[key], value, name)


@unittest.skipUnless(DEV_CHAIN, "SNRC_DEV_CHAIN is not set")
class LocalChainTests(GroundTruthTestCase):
    @classmethod
    def setUpClass(cls):
        chain = start_chain(cls)
        contracts = deploy(chain)
        seed_lookup_states(chain, contracts)
        cls.holder = contracts["holder"].lower()
        cls.url = start_resolver(cls, {
            "SNRC_RPC": chain,
            "SNRC_MULTICALL": deploy_multicall(chain, contracts["owner"]),
            "SNRC_REGISTRY_SIMPLEX": contracts["ens"],
            "SNRC_REGISTRAR_SIMPLEX": contracts["baseRegistrar"],
            "SNRC_CONTROLLER_SIMPLEX": contracts["controller"],
        })

    def test_a_live_name_is_registered_with_its_records(self):
        now, reg = self.assert_registered("bakery.simplex", [BAKERY_CONTACT])
        self.assertGreater(reg["expires"], now)
        self.assertEqual(reg["nameRecord"]["simplexChannel"], [BAKERY_CHANNEL])
        self.assertEqual(reg["nameRecord"]["owner"], self.holder)
        self.assert_registered("harbour.simplex", [])

    def test_a_name_in_grace_is_registered(self):
        now, reg = self.assert_registered("expiring.simplex", [CONTACT])
        self.assertLess(reg["expires"], now)

    def test_a_held_subname_is_registered(self):
        reg = self.assert_registered("menu.bakery.simplex", [MENU_CONTACT])[1]
        self.assertEqual(reg["nameRecord"]["name"], "menu.bakery.simplex")
        self.assertEqual(reg["nameRecord"]["owner"], self.holder)

    def test_names_nobody_holds_are_available_at_the_launch_price(self):
        pricing = {"registrationPrices": {"6": 20000, "7": 10000}, "basePrice": 5000, "minLabelLength": 6}
        for name in ("sunflower.simplex", "lapsed.simplex", "menu.expiring.simplex"):
            self.assert_type(name, "available", pricing=pricing)

    def test_reserved_names_carry_their_reason(self):
        for name, reason in (("simplex.simplex", "internal"), ("brandname.simplex", "trademark"), ("privacy.simplex", "community")):
            self.assert_type(name, "reserved", reservedReason=reason)

    def test_v1_answers_each_state_by_its_status(self):
        status, body = get(f"{self.url}/resolve/bakery.simplex")
        self.assertEqual((status, body["simplexContact"]), (200, [BAKERY_CONTACT]))
        for name, code in (("sunflower.simplex", 404), ("lapsed.simplex", 410), ("menu.expiring.simplex", 404)):
            self.assertEqual(get(f"{self.url}/resolve/{name}")[0], code, name)


@unittest.skipUnless(MAINNET_RPC, "SNRC_MAINNET_RPC is not set")
class MainnetTests(GroundTruthTestCase):
    @classmethod
    def setUpClass(cls):
        cls.url = start_resolver(cls, {"SNRC_RPC": MAINNET_RPC})

    def test_known_names_are_registered(self):
        self.assert_registered("foobar.testing", ["https://smp16.simplex.im/a#Q_F00BA7"])
        self.assert_registered("bitcoin.testing")
        self.assert_registered("evgenypoberezkin.simplex")

    def test_reserved_names_carry_their_reason(self):
        for name in ("simplex.testing", "simplex.simplex"):
            self.assert_type(name, "reserved", reservedReason="internal")

    def test_a_name_nobody_registered_is_available(self):
        for name in ("groundtruthcheck.testing", "groundtruthcheck.simplex"):
            self.assert_type(name, "available")
