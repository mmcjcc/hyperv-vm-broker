"""Tests for vm_broker.validate, schema and yamlstrict (docs/design.md 13.1)."""
import copy
import os
import re
import sys
import unittest

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")
sys.path.insert(0, SRC)

from vm_broker import schema as S                       # noqa: E402
from vm_broker import validate as V                     # noqa: E402
from vm_broker import yamlstrict                        # noqa: E402

try:
    import yaml  # noqa: F401
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False

REPO = os.path.dirname(SRC)

LAB = {
    "contract": 1, "name": "lab-p1", "profile": "win11-lab", "host": "serverd",
    "size": {"cpu": 4, "memory": "4g", "disk": "80g"}, "network": {"mode": "lan"}, "access": [],
    "director": True, "checkpoints": "standard", "activation": "mak", "lease": {"keep": True},
    "purpose": "CS 101 walkthrough recordings",
}


def check(raw, stage="v0.R", scripts=None):
    return V.validate_request(raw, scripts or {}, "cs101-walkthroughs", stage)


class V0R(unittest.TestCase):
    def ok(self, raw, stage="v0.R"):
        n, f = check(raw, stage)
        self.assertEqual(f, [], f)
        return n

    def bad(self, raw, needle, stage="v0.R"):
        n, f = check(raw, stage)
        self.assertIsNone(n)
        self.assertTrue(any(needle in x for x in f), "%r not in %r" % (needle, f))
        for x in f:
            self.assertTrue(all(0x20 <= ord(ch) <= 0x7E for ch in x), x)

    def test_the_recording_vm_request_is_valid_and_normalized(self):
        n = self.ok(LAB)
        self.assertEqual(n["size"], {"cpu": 4, "memory": "4g", "disk": "80g", "memory_mb": 4096, "disk_gb": 80})
        self.assertEqual(n["lease"], {"keep": True})
        self.assertEqual(n["network"], {"mode": "lan"})
        self.assertEqual(V.needs_approval(n), ["activation", "lease.keep"])

    def test_hash_is_stable_and_covers_the_request(self):
        a = self.ok(LAB)
        b = self.ok(copy.deepcopy(LAB))
        self.assertEqual(V.request_hash(a), V.request_hash(b))
        c = copy.deepcopy(LAB); c["purpose"] = "other"
        self.assertNotEqual(V.request_hash(a), V.request_hash(self.ok(c)))
        self.assertRegex(V.request_hash(a), r"^[0-9a-f]{64}$")

    def test_what_v0r_refuses(self):
        cases = [
            ({"profile": "ubuntu-server"}, "not in v0.R"),
            ({"network": {"mode": "isolated", "net": "demo1", "internet": True}}, "not in v0.R"),
            ({"access": ["ssh"]}, "not allowed on win11-lab"),
            ({"lease": {"days": 7}}, "kept"),
            ({"firewall": [{"port": 80, "proto": "tcp", "from": "lan"}]}, "blocks all inbound"),
            ({"software": {"winget": ["Git.Git"]}}, "not in v0.R"),
            ({"scripts": ["vmbroker/x.ps1"]}, "not in v0.R"),
            ({"users": []}, "not for win11-lab"),
            ({"host": "servera"}, "not in v0.R"),
            ({"autostart": True}, "not in v0.R"),
        ]
        for change, needle in cases:
            with self.subTest(change=change):
                r = copy.deepcopy(LAB); r.update(change)
                self.bad(r, needle)

    def test_field_rules(self):
        cases = [
            ({"name": "Lab"}, "name"), ({"name": "lab-"}, "hyphen"), ({"name": "rtr-x"}, "reserved"),
            ({"name": "a"}, "name"), ({"name": "abcdefghijkl"}, "name"), ({"name": True}, "quote it"),
            ({"contract": 2}, "must be 1"), ({"contract": True}, "must be 1"),
            ({"size": {"cpu": 1, "memory": "4g", "disk": "80g"}}, "size.cpu"),
            ({"size": {"cpu": 5, "memory": "4g", "disk": "80g"}}, "size.cpu"),
            ({"size": {"cpu": 4, "memory": "4100m", "disk": "80g"}}, "steps of 256m"),
            ({"size": {"cpu": 4, "memory": "4G", "disk": "80g"}}, "lower case"),
            ({"size": {"cpu": 4, "memory": "2g", "disk": "80g"}}, "size.memory"),
            ({"size": {"cpu": 4, "memory": "32g", "disk": "80g"}}, "size.memory"),
            ({"size": {"cpu": 4, "memory": "4g", "disk": "20g"}}, "size.disk"),
            ({"size": {"cpu": 4, "memory": "4g", "disk": "80g", "gpu": 1}}, "unknown key"),
            ({"switch": "WAN"}, "unknown key"), ({"vlan": 5}, "unknown key"),
            ({"purpose": ""}, "purpose"), ({"purpose": "x" * 201}, "200"), ({"purpose": "café"}, "printable ASCII"),
            ({"purpose": "a `b`"}, "backticks"), ({"checkpoints": "fast"}, "standard or production"),
            ({"purpose": "a\x9bb"}, "control, invisible or bidi"), ({"purpose": "ab‮cd"}, "bidi"),
            ({"purpose": "a​b"}, "invisible"),
            ({"activation": "kms"}, "none or mak"), ({"director": "yes"}, "true or false"),
            ({"lease": {"keep": True, "days": 3}}, "lease"),
            ({"network": {"mode": "lan", "net": "x1"}}, "unknown key for mode lan"),
            ({"hostname": "pc"}, "not for win11-lab"),
        ]
        for change, needle in cases:
            with self.subTest(change=change):
                r = copy.deepcopy(LAB); r.update(change)
                self.bad(r, needle)

    def test_required(self):
        for k in V.REQUIRED:
            r = copy.deepcopy(LAB); del r[k]
            self.bad(r, "%s: required" % k)

    def test_secrets_are_refused_and_never_echoed(self):
        key = "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY"
        r = copy.deepcopy(LAB); r["purpose"] = "use key %s" % key
        n, f = check(r)
        self.assertIsNone(n)
        self.assertTrue(any("product key" in x for x in f))
        self.assertFalse(any(key in x for x in f))
        for text, what in (("-----BEGIN OPENSSH PRIVATE KEY-----", "private key"),
                           ("ghp_" + "a" * 36, "GitHub"), ("AKIA" + "A" * 16, "AWS"), ("sk-ant-" + "x" * 30, "API key")):
            r = copy.deepcopy(LAB); r["purpose"] = "x %s" % text
            self.bad(r, what)

    def test_never_raises_on_odd_input(self):
        odd = [None, [], "x", 1, {"name": None}, {"size": []}, {"network": "lan"}, {"lease": None}, {1: 2},
               {"access": "ssh"}, {"users": "x"}, {"firewall": {}}, {"software": []}, {"scripts": "a"}]
        for o in odd:
            with self.subTest(o=o):
                r = o if not isinstance(o, dict) else dict(copy.deepcopy(LAB), **{str(k): v for k, v in o.items()})
                n, f = check(r)
                self.assertIsNone(n)
                self.assertTrue(f)

    def test_later_stages(self):
        r = {"contract": 1, "name": "api-test", "profile": "ubuntu-server", "network": {"mode": "lan"},
             "access": ["ssh"], "purpose": "test", "users": [{"name": "operator", "admin": True, "password": "none",
                                                             "ssh_keys": ["ssh-ed25519 " + "A" * 68 + " operator@laptop"]}]}
        self.ok(r, "v0.1")
        r2 = dict(r, activation="mak")
        self.bad(r2, "not for ubuntu-server", "v0.1")
        lab = dict(LAB, network={"mode": "isolated", "net": "demo1", "internet": True}, lease={"days": 14}, activation="none")
        lab.pop("host")
        self.ok(lab, "v0.2")
        self.bad(dict(lab, network={"mode": "lan"}), "isolated", "v0.2")


@unittest.skipUnless(HAVE_YAML, "PyYAML is not installed")
class ContractExamples(unittest.TestCase):
    STAGE_OF = {"ubuntu-server": "v0.1", "win2025-core": "v0.1", "ubuntu-desktop-xrdp": "v1", "win2025-desktop": "v1",
                "win11-lab": "v0.2"}

    def blocks(self):
        with open(os.path.join(REPO, "CONTRACT.md"), encoding="utf-8") as fh:
            text = fh.read()
        return re.findall(r"```yaml\n(.*?)```", text, re.S)

    def test_every_contract_example_passes_in_its_stage(self):
        blocks = self.blocks()
        self.assertGreaterEqual(len(blocks), 5)
        for b in blocks:
            raw = yamlstrict.load_mapping(b.replace("...shortened...", "A" * 40).encode("utf-8"))
            stage = "v0.R" if raw.get("network") == {"mode": "lan"} and raw["profile"] == "win11-lab" else self.STAGE_OF[raw["profile"]]
            scripts = {s: b"echo ok\n" for s in raw.get("scripts", [])}
            with self.subTest(name=raw.get("name")):
                n, f = V.validate_request(raw, scripts, "x", stage)
                self.assertEqual(f, [], f)

    def test_examples_lab_p1_file(self):
        with open(os.path.join(REPO, "examples", "lab-p1.yml"), "rb") as fh:
            raw = yamlstrict.load_mapping(fh.read())
        n, f = check(raw)
        self.assertEqual(f, [])
        self.assertEqual(n["name"], "lab-p1")

    def test_yaml_refusals(self):
        for data, needle in ((b"a: &x 1\n", "anchors"), (b"a: 1\na: 2\n", "duplicate"), (b"a: 0x10\n", "plain decimal"),
                             (b"a: 2026-10-01\n", "quote it"), (b"a: 1\r\n", "CR"), (b"---\na: 1\n---\nb: 2\n", "more than one")):
            with self.subTest(data=data):
                with self.assertRaises(yamlstrict.StrictYAMLError) as c:
                    yamlstrict.load_mapping(data)
                self.assertIn(needle, str(c.exception))


class NoYamlImport(unittest.TestCase):
    def test_pure_modules_never_import_yaml(self):
        import subprocess
        code = ("import sys; sys.path.insert(0, %r); import vm_broker.schema, vm_broker.validate, vm_broker.yamlstrict, "
                "vm_broker.broker, vm_broker.cli, vm_broker.mcp; sys.exit(1 if 'yaml' in sys.modules else 0)" % SRC)
        self.assertEqual(subprocess.run([sys.executable, "-I", "-B", "-c", code]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
