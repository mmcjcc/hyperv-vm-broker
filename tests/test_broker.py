"""The verbs end to end against the fake backend (docs/design.md 13.1), including acceptance A's sequence."""
import base64
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")
sys.path.insert(0, SRC)

from vm_broker import cli, yamlstrict                    # noqa: E402
from vm_broker.backend.fake import FakeBackend           # noqa: E402
from vm_broker.broker import Broker, director_step_timeout  # noqa: E402

LAB = {
    "contract": 1, "name": "lab-p1", "profile": "win11-lab", "host": "serverd",
    "size": {"cpu": 4, "memory": "4g", "disk": "80g"}, "network": {"mode": "lan"}, "access": [],
    "director": True, "checkpoints": "standard", "activation": "mak", "lease": {"keep": True},
    "purpose": "CS 101 walkthrough recordings",
}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "cs101-walkthroughs"
        (self.root / "vmbroker").mkdir(parents=True)
        (self.root / "vmbroker" / "consumer").write_text("cs101-walkthroughs\n")
        self.req = self.root / "vmbroker" / "lab-p1.yml"
        self.req.write_text("placeholder: parsed by the patched loader\n")
        self.out = Path(self.tmp.name) / "out"
        self.be = FakeBackend()
        self.b = Broker(self.be, consumer="cs101-walkthroughs", repo_root=self.root,
                        settings={"hosts": ["serverd"], "out_dir": str(self.out), "wait_s": 30, "transport": "direct"},
                        sleep=lambda s: None)
        self.raw = json.loads(json.dumps(LAB))
        p = mock.patch.object(yamlstrict, "load_mapping", side_effect=lambda data: json.loads(json.dumps(self.raw)))
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)

    def create(self):
        return self.b.create(str(self.req))


class Create(Base):
    def test_plan_changes_nothing(self):
        r = self.b.plan(str(self.req))
        self.assertTrue(r["ok"], r)
        self.assertIn("automatic", r["decision"])
        self.assertEqual(self.be.records, {})
        self.assertTrue(self.be.calls[-1]["whatif"])

    def test_create_then_repeat_returns_the_same_vm(self):
        r = self.create()
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["state"], "Running")
        r2 = self.create()
        self.assertTrue(r2["ok"])
        self.assertTrue(r2.get("existing"))
        self.assertEqual(sum(1 for c in self.be.calls if c["verb"] == "create"), 2)
        self.assertEqual(len(self.be.records), 1)

    def test_a_changed_request_under_the_same_name_is_rejected(self):
        self.create()
        self.raw["purpose"] = "something else"
        r = self.create()
        self.assertEqual(r["exit"], 2)
        self.assertEqual(r["error"], "name-taken")

    def test_findings_never_reach_the_host(self):
        self.raw["access"] = ["ssh"]
        r = self.create()
        self.assertEqual(r["exit"], 2)
        self.assertTrue(r["findings"])
        self.assertEqual(self.be.calls, [])

    def test_failed_vm_answers_destroy_then_create(self):
        self.be.fail_next_job = "boom"
        r = self.create()
        self.assertEqual(r["exit"], 1)
        r = self.create()
        self.assertEqual(r["exit"], 1)
        self.assertIn("destroy, then create", r["hint"])

    def test_a_running_create_returns_exit_4_with_the_job(self):
        self.be.job_mode = "running"
        r = self.b.create(str(self.req), wait_s=0)
        self.assertEqual(r["exit"], 4)
        self.assertRegex(r["job"], r"^[0-9a-f]{32}$")
        self.be.finish_job(r["job"])
        w = self.b.job_wait(r["job"], wait_s=0)
        self.assertTrue(w["ok"])

    def test_another_consumer_cannot_get_the_recording_vm(self):
        b2 = Broker(self.be, consumer="other-project", repo_root=self.root, settings=self.b.settings, sleep=lambda s: None)
        r = b2.create(str(self.req))
        self.assertEqual(r["exit"], 2)
        self.assertIn("recording VM", r["hint"])

    def test_no_capacity(self):
        self.be.available_mb = 6000
        r = self.create()
        self.assertEqual(r["exit"], 6)
        self.be.available_mb = 12000
        self.be.firewall_running = False
        self.assertEqual(self.create()["exit"], 6)

    def test_request_outside_the_repo(self):
        other = Path(self.tmp.name) / "elsewhere.yml"
        other.write_text("x: 1\n")
        r = self.b.create(str(other))
        self.assertEqual(r["exit"], 2)
        self.assertEqual(self.be.calls, [])

    def test_no_consumer(self):
        b = Broker(self.be, consumer=None, consumer_error="no vmbroker/consumer in this project", sleep=lambda s: None)
        for r in (b.list(), b.status("lab-p1"), b.create("x.yml"), b.whoami()):
            self.assertEqual(r["exit"], 2)
            self.assertEqual(r["error"], "no-consumer")


class AcceptanceA(Base):
    """docs/design.md 13.3, on lan, without its last step (v0.R keeps the VM)."""

    def test_the_sequence(self):
        b = self.b
        self.assertTrue(self.create()["ok"])
        self.assertTrue(b.snapshot("lab-p1", "smoke-start")["ok"])
        self.assertEqual(b.snapshot("lab-p1", "smoke-start")["exit"], 2)          # label exists
        self.assertTrue(b.snapshot("lab-p1", "smoke-start", replace=True)["ok"])
        r = b.director("lab-p1", "record_start", {"filename": "smoke.mkv"})
        self.assertTrue(r["ok"], r)
        self.assertTrue(b.director("lab-p1", "run_visible", {"command": "winget --version"})["ok"])
        self.assertTrue(b.director("lab-p1", "marker", {"label": "winget-version"})["ok"])
        self.assertTrue(b.director("lab-p1", "record_stop")["ok"])
        vm = next(iter(self.be.vms.values()))
        vm["files"][r"C:\ProgramData\LabDirector\out\smoke.mkv"] = b"\x1aE\xdf\xa3fake-mkv"
        vm["files"][r"C:\ProgramData\LabDirector\out\smoke.markers.json"] = b'[{"t": 1.0, "label": "winget-version"}]'
        c = b.copy_from("lab-p1", r"C:\ProgramData\LabDirector\out\smoke.mkv")
        self.assertTrue(c["ok"], c)
        self.assertTrue(Path(c["local"]).read_bytes().startswith(b"\x1aE\xdf\xa3"))
        self.assertTrue(str(c["local"]).startswith(str(self.out)))
        c2 = b.copy_from("lab-p1", r"C:\ProgramData\LabDirector\out\smoke.markers.json", str(self.out) + os.sep)
        self.assertEqual(json.loads(Path(c2["local"]).read_text())[0]["label"], "winget-version")
        r = b.restore("lab-p1", "smoke-start")
        self.assertTrue(r["ok"], r)
        self.assertEqual(b.destroy("lab-p1", "lab-p1")["error"], "not-in-stage")
        names = [s["label"] for s in b.list_snapshots("lab-p1")["snapshots"]]
        self.assertEqual(names, ["smoke-start"])


class Verbs(Base):
    def setUp(self):
        super().setUp()
        self.assertTrue(self.create()["ok"])

    def test_run_exits_0_and_carries_the_guest_code(self):
        self.be.run_exit = 3
        r = self.b.run("lab-p1", "exit 3")
        self.assertTrue(r["ok"])
        self.assertEqual(r["exit_code"], 3)
        out = []
        class W:
            def write(self, s):
                out.append(s)
        self.assertEqual(cli.main(["run", "lab-p1", "--", "exit", "3"], broker=self.b, out=W()), 0)

    def test_run_options_before_the_double_dash(self):
        seen = {}
        real = self.b.run
        def spy(vm, command, interactive=False, timeout_s=300):
            seen.update(vm=vm, command=command, interactive=interactive, timeout_s=timeout_s)
            return real(vm, command, interactive=interactive, timeout_s=timeout_s)
        self.b.run = spy
        class W:
            def write(self, s):
                pass
        cli.main(["run", "lab-p1", "--timeout", "120", "--", "& 'C:\\x.ps1' --timeout 5 -- y"], broker=self.b, out=W())
        self.assertEqual(seen, {"vm": "lab-p1", "command": "& 'C:\\x.ps1' --timeout 5 -- y", "interactive": False, "timeout_s": 120})
        cli.main(["run", "--interactive", "lab-p1", "--", "Get-Date"], broker=self.b, out=W())
        self.assertEqual((seen["command"], seen["interactive"], seen["timeout_s"]), ("Get-Date", True, 300))

    def test_run_from_a_file(self):
        f = self.root / "cmd.ps1"            # inside the project
        f.write_bytes(b"$a = 1\r\n'two \"quoted\" lines'\n")
        out = []
        class W:
            def write(self, s):
                out.append(s)
        self.assertEqual(cli.main(["run", "lab-p1", "--file", str(f)], broker=self.b, out=W()), 0)
        self.assertEqual(self.be.calls[-1]["args"]["command"], "$a = 1\n'two \"quoted\" lines'\n")
        out.clear()
        self.assertEqual(cli.main(["run", "lab-p1", "--file", str(f), "--", "x"], broker=self.b, out=W()), 2)

    def test_run_limits(self):
        self.assertEqual(self.b.run("lab-p1", "")["exit"], 2)
        self.assertEqual(self.b.run("lab-p1", "x" * 9000)["exit"], 2)
        self.assertEqual(self.b.run("lab-p1", "x", timeout_s=0)["exit"], 2)
        self.assertEqual(self.b.run("lab-p1", "x", timeout_s=True)["exit"], 2)

    def test_busy_when_a_job_runs(self):
        self.be.job_mode = "running"
        r = self.b.snapshot("lab-p1", "a", wait_s=0)
        self.assertEqual(r["exit"], 4)
        self.assertEqual(self.b.snapshot("lab-p1", "b", wait_s=0)["exit"], 3)
        self.assertEqual(self.b.start("lab-p1")["exit"], 3)

    def test_lost_job(self):
        self.be.job_mode = "running"
        r = self.b.restore("lab-p1", "nope", wait_s=0)
        self.assertEqual(r["exit"], 2)
        r = self.b.stop("lab-p1", wait_s=0)
        self.be.lose_job(r["job"])
        w = self.b.job_wait(r["job"], wait_s=0)
        self.assertEqual(w["state"], "lost")
        self.assertEqual(w["exit"], 1)

    def test_labels_and_names_are_checked_before_the_host(self):
        n = len(self.be.calls)
        for r in (self.b.snapshot("lab-p1", "Bad Label"), self.b.restore("lab-p1", "../x"), self.b.status("vmb-lab-p1"),
                  self.b.status("Firewall3"), self.b.delete_snapshot("lab-p1", ""), self.b.job_status("x")):
            self.assertEqual(r["exit"], 2)
        self.assertEqual(len(self.be.calls), n)

    def test_v0r_refuses_destroy_and_extend(self):
        self.assertEqual(self.b.destroy("lab-p1", "lab-p1")["error"], "not-in-stage")
        self.assertEqual(self.b.destroy("lab-p1", "other")["exit"], 2)
        self.assertEqual(self.b.extend("lab-p1", 7)["error"], "not-in-stage")

    def test_director_screenshot_is_saved_and_not_inlined(self):
        r = self.b.director("lab-p1", "screenshot")
        self.assertTrue(r["ok"], r)
        self.assertNotIn("png_b64", json.dumps(r))
        self.assertTrue(Path(r["png_path"]).read_bytes().startswith(b"\x89PNG"))

    def test_director_failure_brings_a_screenshot(self):
        self.be.director_fail["wait_for"] = "timeout"
        r = self.b.director("lab-p1", "wait_for", {"window_title": "GitHub", "timeout_s": 5})
        self.assertEqual(r["exit"], 1)
        self.assertIn("timeout", r["hint"])
        self.assertTrue(r.get("png_path"))

    def test_director_batch(self):
        steps = [{"action": "type", "payload": {"text": "hello"}}, {"action": "key", "payload": {"combo": "enter"}},
                 {"action": "screenshot"}]
        r = self.b.director("lab-p1", "batch", {"steps": steps})
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["completed"], 3)
        self.assertTrue(r["png_path"])
        self.be.director_fail["key"] = "bad-request"
        r = self.b.director("lab-p1", "batch", {"steps": steps})
        self.assertEqual(r["exit"], 1)
        self.assertEqual(r["completed"], 1)
        for bad in ({"steps": []}, {"steps": [{"action": "rm"}]}, {"steps": [{"action": "type", "x": 1}]}, {}):
            self.assertEqual(self.b.director("lab-p1", "batch", bad)["exit"], 2)
        self.assertEqual(self.b.director("lab-p1", "find", {})["exit"], 2)
        self.assertEqual(self.b.director("lab-p1", "type", "text")["exit"], 2)

    def test_director_payload_travels_as_data(self):
        nasty = "$(Remove-Item C:\\ -Recurse); `whoami`; \"quoted\" 'single'\nnext line"
        r = self.b.director("lab-p1", "type", {"text": nasty})
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["answer"]["body"]["text"], nasty)
        sent = self.be.calls[-1]["args"]["steps"][0]
        self.assertEqual(json.loads(sent["body"])["text"], nasty)

    def test_step_timeouts(self):
        self.assertEqual(director_step_timeout("wait_for", {"timeout_s": 600}), 620)
        self.assertEqual(director_step_timeout("wait_for", {"timeout_s": 600.0}), 620)   # floats count too
        self.assertEqual(director_step_timeout("type", {"text": "x" * 600, "cps": 1.0}),
                         director_step_timeout("type", {"text": "x" * 600, "cps": 1}))
        self.assertGreater(director_step_timeout("type", {"text": "x" * 8192, "cps": 1}), 900)   # not capped here
        self.assertGreaterEqual(director_step_timeout("type", {"text": "x" * 100}), 20)
        self.assertEqual(director_step_timeout("health", None), 20)
        self.assertEqual(director_step_timeout("wait_for", {"timeout_s": float("nan")}), 50)    # the default
        self.assertEqual(director_step_timeout("record_start", {"filename": "a.mkv"}), 90)      # ffmpeg's first frame

    def test_activate_takes_either_name_at_the_confirmation_and_nothing_else(self):
        from vm_broker import admin
        sent = []

        class B:
            def call(self, host, verb, args, **kw):
                sent.append((verb, args.get("name")))
                return {"ok": True, "exit": 0, "permanent": True}
        for typed, goes in (("lab-p1", True), ("vmb-lab-p1", True), (" vmb-lab-p1 ", True), ("lab-p2", False), ("", False)):
            with self.subTest(typed=typed):
                sent.clear()
                with mock.patch.object(admin, "_tty", return_value=True), \
                        mock.patch.object(admin, "_backend", return_value=(B(), "serverd")), \
                        mock.patch.object(admin, "read_key", return_value="ABCDE-FGHIJ-KLMNO-PQRST-VWXYZ"), \
                        mock.patch("builtins.input", return_value=typed), \
                        mock.patch("builtins.print"):
                    code = admin.main(["activate", "lab-p1"])
                self.assertEqual((code == 0, bool(sent)), (goes, goes))

    def test_key_from_config_shows_line_and_name_never_the_key(self):
        from vm_broker import admin
        cfg = Path(self.tmp.name) / "config.txt"      # made-up values only
        cfg.write_text("homelab\\svc NotTheKey\n"
                       "gvlk TVRH6-WHNXV-R9WG3-9XRFY-MY832\n"                       # public: left out
                       "WIN2025_MAK=ABCDE-FGHIJ-KLMNO-PQRST-UVWX1\n"
                       "ilo_password=Hunter2 OFFICE_KEY: \"AAAAA-BBBBB-CCCCC-DDDDD-EEEE2\"\n", encoding="utf-8")
        found = admin.find_keys(str(cfg))
        self.assertEqual([(n, label) for n, label, _k in found], [(3, "WIN2025_MAK"), (4, "OFFICE_KEY")])
        said = []
        key = admin.key_from_config(str(cfg), ask=lambda q: (said.append(q), "1")[1], say=said.append)
        self.assertEqual(key, "ABCDE-FGHIJ-KLMNO-PQRST-UVWX1")
        shown = "\n".join(said)
        for secret in ("ABCDE", "AAAAA", "Hunter2", "NotTheKey"):
            self.assertNotIn(secret, shown)
        self.assertIn("2. line 4 (OFFICE_KEY)", shown)
        one = Path(self.tmp.name) / "one.txt"
        one.write_text("user pw\nmak: abcde-fghij-klmno-pqrst-uvwx1\n", encoding="utf-8")
        self.assertEqual(admin.key_from_config(str(one), ask=lambda q: "y"), "ABCDE-FGHIJ-KLMNO-PQRST-UVWX1")
        with self.assertRaises(ValueError):
            admin.key_from_config(str(one), ask=lambda q: "n")
        none = Path(self.tmp.name) / "none.txt"
        none.write_text("user pw\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            admin.key_from_config(str(none))

    def test_a_failed_status_read_is_retried_not_reported_as_the_jobs_failure(self):
        from vm_broker import jobs
        answers = [{"ok": False, "exit": 1, "error": "failed", "hint": "the file is being used by another process"},
                   {"ok": True, "state": "running", "step": "restore"},
                   {"ok": False, "exit": 255, "error": "unreachable"},
                   {"ok": True, "state": "done", "step": "director", "result": {"restore_s": 50}}]

        class B:
            def call(self, host, verb, args, **kw):
                return answers.pop(0)
        r = jobs.wait(B(), "serverd", "j1", "c", 600, clock=lambda: 0.0, sleep=lambda s: None)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["state"], "done")
        refusal = [{"ok": False, "exit": 2, "error": "unknown-job"}]

        class R:
            def call(self, host, verb, args, **kw):
                return refusal.pop(0)
        self.assertEqual(jobs.wait(R(), "serverd", "j1", "c", 600, clock=lambda: 0.0, sleep=lambda s: None)["exit"], 2)

    def test_director_refuses_steps_and_calls_that_outlast_the_relay(self):
        calls = len(self.be.calls)
        r = self.b.director("lab-p1", "type", {"text": "x" * 8192, "cps": 2})
        self.assertEqual((r["exit"], r["error"]), (2, "too-long"), r)
        self.assertIn("split it", r["hint"])
        steps = [{"action": "wait_for", "payload": {"window_title": "x", "timeout_s": 600}}] * 3
        r = self.b.director("lab-p1", "batch", {"steps": steps})
        self.assertEqual((r["exit"], r["error"]), (2, "too-long"), r)
        self.assertIn("1800", r["hint"])
        r = self.b.director("lab-p1", "click", {"x": float("nan"), "y": 1})
        self.assertEqual(r["exit"], 2)
        self.assertIn("finite", r["hint"])
        self.assertEqual(len(self.be.calls), calls)   # none of them reached the host

    def test_copy_to_and_idempotent_repeat(self):
        f = self.root / "a.txt"              # inside the project
        f.write_bytes(b"hello")
        r = self.b.copy_to("lab-p1", str(f), r"C:\Users\student\Desktop\a.txt")
        self.assertTrue(r["ok"], r)
        r = self.b.copy_to("lab-p1", str(f), r"C:\Users\student\Desktop\a.txt")
        self.assertTrue(r.get("already"))
        f.write_bytes(b"changed")
        self.assertEqual(self.b.copy_to("lab-p1", str(f), r"C:\Users\student\Desktop\a.txt")["exit"], 2)
        self.assertTrue(self.b.copy_to("lab-p1", str(f), r"C:\Users\student\Desktop\a.txt", overwrite=True)["ok"])
        self.assertEqual(self.b.copy_to("lab-p1", str(f) + ".missing", "C:\\x")["exit"], 2)

    def test_copy_from_never_into_onedrive(self):
        with mock.patch.dict(os.environ, {"OneDrive": str(Path(self.tmp.name) / "od")}):
            od = Path(self.tmp.name) / "od" / "repo"
            od.mkdir(parents=True)
            r = self.b.copy_from("lab-p1", r"C:\x.mkv", str(od) + os.sep)
            self.assertEqual(r["exit"], 2)
            self.assertIn("OneDrive", r["hint"])

    def guest_file(self, path, data=b"from the guest"):
        next(iter(self.be.vms.values()))["files"][path] = data

    def test_copy_from_writes_only_inside_the_out_dir(self):
        self.guest_file(r"C:\x\runner.ps1")
        calls = len(self.be.calls)
        victim = Path(self.tmp.name) / "victim" / "runner.ps1"     # outside VMB_OUT_DIR (the laptop's code, say)
        for local in (str(victim), str(self.out) + r"\..\victim\runner.ps1", str(self.root / "x.ps1")):
            with self.subTest(local=local):
                r = self.b.copy_from("lab-p1", r"C:\x\runner.ps1", local)
                self.assertEqual(r["exit"], 2, r)
                self.assertIn("VMB_OUT_DIR", r["hint"])
        self.assertFalse(victim.exists())
        self.assertEqual(len(self.be.calls), calls)               # refused before the host was asked
        r = self.b.copy_from("lab-p1", r"C:\x\runner.ps1", r"ch1\runner.ps1")   # relative: under VMB_OUT_DIR
        self.assertTrue(r["ok"], r)
        self.assertEqual(Path(r["local"]), (self.out / "ch1" / "runner.ps1").resolve())

    def test_copy_from_does_not_replace_a_file_unless_asked(self):
        self.guest_file(r"C:\out\a.mkv", b"new")
        (self.out / "lab-p1").mkdir(parents=True)
        old = self.out / "lab-p1" / "a.mkv"
        old.write_bytes(b"old")
        r = self.b.copy_from("lab-p1", r"C:\out\a.mkv")
        self.assertEqual((r["exit"], r["error"]), (2, "exists"))
        self.assertEqual(old.read_bytes(), b"old")
        self.assertTrue(self.b.copy_from("lab-p1", r"C:\out\a.mkv", overwrite=True)["ok"])
        self.assertEqual(old.read_bytes(), b"new")

    def test_odd_local_paths_are_refused(self):
        self.guest_file(r"C:\a.txt")
        for local, word in [(str(self.out / "a.txt") + ":stream", "data streams"), (r"\\server\share\a.txt", "UNC"),
                            (r"\\?\C:\a.txt", "UNC"), (str(self.out / "NUL"), "device"),
                            (str(self.out / "con.txt"), "device"), (str(self.out) + "\\a\x00b", "control"),
                            ("x" * 401, "400")]:
            with self.subTest(local=local):
                r = self.b.copy_from("lab-p1", r"C:\a.txt", local)
                self.assertEqual(r["exit"], 2, r)
                self.assertIn(word, r["hint"])

    def test_copy_to_reads_only_from_the_project_or_the_out_dir(self):
        outside = Path(self.tmp.name) / "elsewhere" / "config.txt"
        outside.parent.mkdir()
        outside.write_text("not for the guest")
        calls = len(self.be.calls)
        r = self.b.copy_to("lab-p1", str(outside), r"C:\x\y.txt")
        self.assertEqual(r["exit"], 2, r)
        self.assertIn("inside this project", r["hint"])
        secret = self.root / "netadmin" / "config.txt"            # a credentials folder, even inside the repo
        secret.parent.mkdir()
        secret.write_text("x")
        r = self.b.copy_to("lab-p1", str(secret), r"C:\x\y.txt")
        self.assertIn("credentials", r["hint"])
        self.assertEqual(len(self.be.calls), calls)
        self.out.mkdir(parents=True, exist_ok=True)
        ok_file = self.out / "notes.txt"
        ok_file.write_text("fine")
        self.assertTrue(self.b.copy_to("lab-p1", str(ok_file), r"C:\x\notes.txt")["ok"])

    def test_a_repo_root_above_the_home_folder_is_not_a_source(self):
        home = Path(self.tmp.name) / "home"
        home.mkdir()
        f = self.root / "a.txt"
        f.write_text("x")
        b = Broker(self.be, consumer="cs101-walkthroughs", repo_root=Path(self.tmp.name),
                   settings={"hosts": ["serverd"], "out_dir": str(self.out), "transport": "direct"})
        with mock.patch.object(Path, "home", return_value=home):
            r = b.copy_to("lab-p1", str(f), r"C:\x\a.txt")
        self.assertEqual(r["exit"], 2, r)
        self.assertIn("inside this project", r["hint"])

    def test_run_file_reads_only_from_the_project(self):
        outside = Path(self.tmp.name) / "cmd.ps1"
        outside.write_text("Get-Date")

        class W:
            def write(self, s):
                pass
        self.assertEqual(cli.main(["run", "lab-p1", "--file", str(outside)], broker=self.b, out=W()), 2)

    def test_cli_director_shorthand(self):
        self.assertEqual(cli.director_payload("record_start", "smoke.mkv"), {"filename": "smoke.mkv"})
        self.assertEqual(cli.director_payload("marker", "winget-version"), {"label": "winget-version"})
        self.assertEqual(cli.director_payload("click", '{"x": 1, "y": 2}'), {"x": 1, "y": 2})
        with self.assertRaises(ValueError):
            cli.director_payload("click", "1,2")

    def test_cli_exit_codes_and_json(self):
        out = []
        class W:
            def write(self, s):
                out.append(s)
        code = cli.main(["status", "lab-p1"], broker=self.b, out=W())
        self.assertEqual(code, 0)
        self.assertEqual(json.loads("".join(out))["vm"], "lab-p1")
        out.clear()
        self.assertEqual(cli.main(["destroy", "lab-p1", "--confirm", "lab-p1"], broker=self.b, out=W()), 2)

    def test_whoami_and_profiles(self):
        w = self.b.whoami()
        self.assertTrue(w["ok"], w)
        self.assertEqual(w["stage"], "v0.R")
        self.assertIn("director", w["offers"]["verbs"])
        self.assertNotIn("destroy", w["offers"]["verbs"])
        p = self.b.profiles()
        self.assertEqual([x["profile"] for x in p["profiles"] if x["offered"]], ["win11-lab"])
        c = self.b.contract()
        self.assertTrue(c["text"].startswith("# CONTRACT"))


if __name__ == "__main__":
    unittest.main()
