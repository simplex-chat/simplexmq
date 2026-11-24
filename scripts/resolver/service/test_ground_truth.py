import json
import os
import socket
import subprocess
import sys
import time
import unittest
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.request import urlopen

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACTS = os.environ.get("SNRC_CONTRACTS", "")
MAINNET_RPC = os.environ.get("SNRC_MAINNET_RPC", "")
LOCAL_RPC = "http://127.0.0.1:8545"
LOCAL_OWNER = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
CONTACT = "https://localhost/a#ground-truth"
SIMPLEX_MAINNET = {
    "SNRC_REGISTRY_SIMPLEX": "0xa7f6497be2f1aa41aa2db55aba8a6e0145dff0d2",
    "SNRC_REGISTRAR_SIMPLEX": "0x44052f7dc9c1cef20b0319a6b75288988dbb12a1",
    "SNRC_CONTROLLER_SIMPLEX": "0x8005011c6e966656cdb9a222e9a4792600a37219",
}


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


def start_resolver(test_class, env):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    process = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "snrc-resolve.py")],
        env={**os.environ, **env, "SNRC_BIND": "127.0.0.1", "SNRC_PORT": str(port), "SNRC_WORKERS": "1"},
    )
    test_class.addClassCleanup(process.terminate)
    url = f"http://127.0.0.1:{port}"
    wait_for(url + "/health", process)
    return url


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


@unittest.skipUnless(CONTRACTS, "SNRC_CONTRACTS is not set")
class LocalChainTests(GroundTruthTestCase):
    @classmethod
    def setUpClass(cls):
        start = datetime.now(timezone.utc) - timedelta(days=900)
        node = subprocess.Popen(
            [os.path.join("node_modules", ".bin", "hardhat"), "--network", "hardhat", "node"],
            cwd=os.path.join(CONTRACTS, "ens-contracts"),
            env={**os.environ, "HARDHAT_INITIAL_DATE": start.isoformat()},
            stdout=subprocess.DEVNULL,
        )
        cls.addClassCleanup(node.terminate)
        wait_for(LOCAL_RPC, node)
        env = {**os.environ, "SIMPLEX_TLD": "simplex", "RPC_URL": LOCAL_RPC, "CONTACT_LINK": CONTACT}
        subprocess.run(["node", "scripts/deploy-local.mjs"], cwd=CONTRACTS, env=env, check=True)
        with open(os.path.join(CONTRACTS, "deployments.local.json")) as f:
            cls.addrs = json.load(f)
        subprocess.run(["node", "scripts/seed-lookup-states.mjs"], cwd=CONTRACTS, env={**env, "ADDRS": json.dumps(cls.addrs)}, check=True)
        cls.url = start_resolver(cls, {
            "SNRC_RPC": LOCAL_RPC,
            "SNRC_MULTICALL": cls.addrs["Multicall"],
            "SNRC_REGISTRY_SIMPLEX": cls.addrs["ENSRegistry"],
            "SNRC_REGISTRAR_SIMPLEX": cls.addrs["BaseRegistrarImplementation"],
            "SNRC_CONTROLLER_SIMPLEX": cls.addrs["ETHRegistrarController"],
        })

    def test_a_live_name_is_registered_with_its_records(self):
        now, reg = self.assert_registered("bakery.simplex", [CONTACT])
        self.assertGreater(reg["expires"], now)
        self.assertEqual(reg["nameRecord"]["owner"], LOCAL_OWNER)
        self.assert_registered("nolink.simplex", [])

    def test_a_name_in_grace_is_registered(self):
        now, reg = self.assert_registered("expiring.simplex", [CONTACT])
        self.assertLess(reg["expires"], now)

    def test_a_held_subname_is_registered(self):
        reg = self.assert_registered("menu.bakery.simplex")[1]
        self.assertEqual(reg["nameRecord"]["name"], "menu.bakery.simplex")
        self.assertEqual(reg["nameRecord"]["owner"], self.addrs["SubnameRegistrar"].lower())

    def test_names_nobody_holds_are_available_at_the_launch_price(self):
        pricing = {"registrationPrices": {}, "basePrice": 5000, "minLabelLength": 6}
        for name in ("sunflower.simplex", "lapsed.simplex", "menu.expiring.simplex"):
            self.assert_type(name, "available", pricing=pricing)

    def test_reserved_names_carry_their_reason(self):
        for name, reason in (("simplex.simplex", "internal"), ("brandname.simplex", "trademark"), ("privacy.simplex", "community")):
            self.assert_type(name, "reserved", reservedReason=reason)

    def test_v1_answers_each_state_by_its_status(self):
        status, body = get(f"{self.url}/resolve/bakery.simplex")
        self.assertEqual((status, body["simplexContact"]), (200, [CONTACT]))
        for name, code in (("sunflower.simplex", 404), ("lapsed.simplex", 410), ("menu.expiring.simplex", 404)):
            self.assertEqual(get(f"{self.url}/resolve/{name}")[0], code, name)


@unittest.skipUnless(MAINNET_RPC, "SNRC_MAINNET_RPC is not set")
class MainnetTests(GroundTruthTestCase):
    @classmethod
    def setUpClass(cls):
        cls.url = start_resolver(cls, {"SNRC_RPC": MAINNET_RPC, **SIMPLEX_MAINNET})

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
