"""FakeBackend: an in-memory Hyper-V host for unit tests, behind the same call() interface as HyperVBackend.

It mirrors what the host scripts decide (backend/ps): the registry by name with an owner, one recording VM at a time,
create idempotency by request hash, "destroy, then create" on a failed VM, one job per VM (exit 3), the capacity
check above the floor while the firewall runs here, checkpoint labels (exists, --replace keeps the old one if the new
one fails, at most 40), the director relay's answers, run's exit_code, and copy SHA-256 checks. Jobs finish at once
by default, or stay running (job_mode = "running") until finish_job() is called, or die (lose_job()). Every call is
recorded in .calls so tests can prove that a refusal never reached the host.
"""
import base64
import hashlib
import json
import struct
import zlib
from pathlib import Path

from . import Backend
from .. import schema as S


def tiny_png():
    raw = b"\x00\xff\x00\x00"
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def _err(exit_code, error, hint):
    return {"ok": False, "exit": exit_code, "error": error, "hint": hint, "findings": []}


class FakeBackend(Backend):
    def __init__(self):
        self.calls = []
        self.records = {}
        self.vms = {}
        self.jobs = {}
        self.available_mb = 12000
        self.floor_mb = 3072
        self.firewall_running = True
        self.job_mode = "done"
        self.fail_next_job = None
        self.director_fail = {}
        self.run_exit = 0
        self.recording_vm = {"name": "lab-p1", "consumer": "cs101-walkthroughs"}
        self._n = 0

    # ---- helpers ----
    def _id(self):
        self._n += 1
        return "%032x" % self._n

    def _rec(self, a, admin_ok=True):
        name = a.get("name")
        rec = self.records.get(name)
        if not rec:
            return None, _err(2, "unknown-vm", "no VM named '%s'" % name)
        c = a.get("consumer")
        if not (admin_ok and c == "*admin*") and rec["owner"] != c:
            return None, _err(2, "not-yours", "VM '%s' belongs to another consumer" % name)
        return rec, None

    def _active_job(self, rec_id):
        for j in self.jobs.values():
            if j["vm"] == rec_id and j["state"] in ("queued", "running"):
                return j
        return None

    def _start_job(self, verb, rec, args, consumer):
        jid = self._id()
        j = {"id": jid, "verb": verb, "vm": rec["id"] if rec else None, "consumer": consumer, "args": args,
             "state": "running", "step": "", "exit": None, "error": None, "hint": None, "result": None}
        self.jobs[jid] = j
        if self.job_mode == "done":
            self.finish_job(jid)
        return j

    def finish_job(self, jid, fail=None):
        j = self.jobs[jid]
        rec = next((r for r in self.records.values() if r["id"] == j["vm"]), None)
        fail = fail or self.fail_next_job
        self.fail_next_job = None
        if fail:
            j.update(state="failed", exit=1, error="failed", hint=fail)
            if j["verb"] == "create" and rec:
                rec["state"] = "failed"
            return
        vm = self.vms.get(rec["vmid"]) if rec and rec.get("vmid") else None
        if j["verb"] == "create":
            vmid = "vm-%s" % rec["id"][-6:]
            self.vms[vmid] = {"state": "Running", "checkpoints": [], "files": {}, "addresses": ["192.168.10.150"]}
            rec.update(vmid=vmid, state="ready")
            j["result"] = {"vm": rec["name"], "state": "ready"}
        elif j["verb"] == "stop":
            vm["state"] = "Off"
            j["result"] = {"state": "Off"}
        elif j["verb"] == "snapshot":
            label, replace = j["args"]["label"], j["args"].get("replace")
            if replace and label in vm["checkpoints"]:
                vm["checkpoints"].remove(label)
            vm["checkpoints"].append(label)
            j["result"] = {"label": label}
        elif j["verb"] == "restore":
            vm["state"] = "Running"
            j["result"] = {"label": j["args"]["label"], "restore_s": 1.0, "director_s": 2.0}
        j.update(state="done", exit=0)

    def lose_job(self, jid):
        self.jobs[jid].update(state="lost", exit=1, error="lost", hint="the job's task is gone")

    # ---- the interface ----
    def call(self, host, verb, args, mode="call", upload=None, download_to=None, stage_inline=False, whatif=False,
             timeout_s=None):
        self.calls.append({"host": host, "verb": verb, "args": json.loads(json.dumps(args)), "mode": mode,
                           "whatif": whatif})
        fn = getattr(self, "v_" + verb.replace("-", "_"), None)
        if not fn:
            return _err(2, "rejected", "unknown verb '%s'" % verb)
        return fn(dict(args or {}), upload=upload, download_to=download_to, whatif=whatif)

    def v_inventory(self, a, **kw):
        vms = [{"name": "Firewall3", "state": "Running" if self.firewall_running else "Off", "memory_assigned_mb": 8192,
                "broker_name": False}]
        for r in self.records.values():
            if r.get("vmid"):
                vms.append({"name": "vmb-" + r["name"], "state": self.vms[r["vmid"]]["state"],
                            "memory_assigned_mb": 4096, "broker_name": True})
        return {"ok": True, "exit": 0, "host": "serverd", "memory": {"available_mb": self.available_mb},
                "vms": vms, "broker": {"installed": True, "policy": {"floor_gb": 3, "firewall_vm": "Firewall3"}}}

    def v_create(self, a, whatif=False, **kw):
        req, h, c = a["request"], a["request_hash"], a["consumer"]
        name = req["name"]
        rec = self.records.get(name)
        if rec:
            if rec["owner"] != c or rec["request_hash"] != h:
                return _err(2, "name-taken", "'%s' already exists with a different request (or owner)" % name)
            if rec["state"] == "failed":
                return _err(1, "failed", "'%s' is in state failed: destroy, then create" % name)
            j = self._active_job(rec["id"])
            return {"ok": True, "exit": 0, "existing": True, "vm": name, "state": rec["state"], "job": j["id"] if j else None}
        special = [f for f, on in (("activation", req.get("activation") == "mak"), ("keep", req.get("lease", {}).get("keep"))) if on]
        if special and not (self.recording_vm["name"] == name and self.recording_vm["consumer"] == c):
            return _err(2, "rejected", "%s: approved only for the recording VM named in policy.json" % " and ".join(special))
        if any(r["profile"] == "win11-lab" and r["state"] != "destroyed" for r in self.records.values()):
            return _err(2, "rejected", "one recording VM at a time (v0.R); it already exists")
        if not self.firewall_running:
            return _err(6, "no-capacity", "Firewall3 is not running on servera")
        if self.available_mb - req["size"]["memory_mb"] < self.floor_mb:
            return _err(6, "no-capacity", "not enough memory above the floor")
        if whatif:
            return {"ok": True, "exit": 0, "existing": False, "vm": name, "state": "creating", "job": "0" * 32,
                    "whatif": ["create %s" % name]}
        rec = {"id": self._id(), "name": name, "owner": c, "profile": req["profile"], "request_hash": h,
               "request": req, "state": "creating", "vmid": None}
        self.records[name] = rec
        j = self._start_job("create", rec, {}, c)
        return {"ok": True, "exit": 0, "existing": False, "vm": name, "state": "creating", "job": j["id"]}

    def v_list(self, a, **kw):
        c = a.get("consumer")
        return {"ok": True, "exit": 0, "vms": [{"vm": r["name"], "record_state": r["state"],
                                                 "state": self.vms[r["vmid"]]["state"] if r.get("vmid") else "none"}
                                                for r in self.records.values() if c == "*admin*" or r["owner"] == c]}

    def v_status(self, a, **kw):
        rec, e = self._rec(a)
        if e:
            return e
        vm = self.vms.get(rec.get("vmid"))
        j = self._active_job(rec["id"])
        return {"ok": True, "exit": 0, "vm": rec["name"], "record_state": rec["state"],
                "state": vm["state"] if vm else "none", "addresses": vm["addresses"] if vm else [],
                "checkpoints": len(vm["checkpoints"]) if vm else 0,
                "job": {"id": j["id"], "verb": j["verb"], "state": j["state"]} if j else None,
                "console": "vmconnect.exe servera -G %s" % rec.get("vmid")}

    def _vm(self, a, running=False):
        rec, e = self._rec(a)
        if e:
            return None, None, e
        if not rec.get("vmid"):
            return None, None, _err(1, "failed", "the VM was never created")
        vm = self.vms[rec["vmid"]]
        if running and vm["state"] != "Running":
            return None, None, _err(2, "not-running", "'%s' is %s; start it first" % (rec["name"], vm["state"]))
        return rec, vm, None

    def v_start(self, a, **kw):
        rec, vm, e = self._vm(a)
        if e:
            return e
        if self._active_job(rec["id"]):
            return _err(3, "busy", "a job is running")
        if vm["state"] == "Running":
            return {"ok": True, "exit": 0, "vm": rec["name"], "state": "Running", "already": True}
        if self.available_mb - 4096 < self.floor_mb:
            return _err(6, "no-capacity", "not enough memory above the floor")
        vm["state"] = "Running"
        return {"ok": True, "exit": 0, "vm": rec["name"], "state": "Running"}

    def _jobverb(self, verb, a, check=None):
        rec, vm, e = self._vm(a)
        if e:
            return e
        if self._active_job(rec["id"]):
            return _err(3, "busy", "a job is running on '%s'" % rec["name"])
        if check:
            r = check(rec, vm)
            if r:
                return r
        j = self._start_job(verb, rec, {k: v for k, v in a.items() if k not in ("consumer", "name")}, a.get("consumer"))
        return {"ok": True, "exit": 0, "vm": rec["name"], "job": j["id"], "state": "running"}

    def v_stop(self, a, **kw):
        return self._jobverb("stop", a, lambda rec, vm: {"ok": True, "exit": 0, "vm": rec["name"], "state": "Off",
                                                         "already": True} if vm["state"] == "Off" else None)

    def v_snapshot(self, a, **kw):
        def check(rec, vm):
            if a["label"] in vm["checkpoints"] and not a.get("replace"):
                return _err(2, "label-exists", "checkpoint '%s' exists; use --replace" % a["label"])
            if a["label"] not in vm["checkpoints"] and len(vm["checkpoints"]) >= S.MAX_CHECKPOINTS:
                return _err(2, "limit", "40 checkpoints already")
            return None
        return self._jobverb("snapshot", a, check)

    def v_restore(self, a, **kw):
        return self._jobverb("restore", a, lambda rec, vm: None if a["label"] in vm["checkpoints"]
                             else _err(2, "unknown-label", "no checkpoint '%s'" % a["label"]))

    def v_snapshots(self, a, **kw):
        rec, vm, e = self._vm(a)
        if e:
            return e
        return {"ok": True, "exit": 0, "vm": rec["name"], "snapshots": [{"label": c} for c in vm["checkpoints"]]}

    def v_snapshot_rm(self, a, **kw):
        rec, vm, e = self._vm(a)
        if e:
            return e
        if self._active_job(rec["id"]):
            return _err(3, "busy", "a job is running")
        if a["label"] not in vm["checkpoints"]:
            return {"ok": True, "exit": 0, "vm": rec["name"], "label": a["label"], "already": True}
        vm["checkpoints"].remove(a["label"])
        return {"ok": True, "exit": 0, "vm": rec["name"], "label": a["label"], "removed": True}

    def v_run(self, a, **kw):
        rec, vm, e = self._vm(a, running=True)
        if e:
            return e
        return {"ok": True, "exit": 0, "vm": rec["name"], "exit_code": self.run_exit, "stdout": "ran: %s\n" % a["command"],
                "stderr": "", "timed_out": False, "seconds": 0.1}

    def v_copy_to(self, a, upload=None, **kw):
        rec, vm, e = self._vm(a, running=True)
        if e:
            return e
        data = Path(upload[0]["local"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != a["sha256"]:
            return _err(1, "failed", "SHA-256 mismatch after the upload to the host")
        if a["guest"] in vm["files"] and not a.get("overwrite"):
            if hashlib.sha256(vm["files"][a["guest"]]).hexdigest() == a["sha256"]:
                return {"ok": True, "exit": 0, "vm": rec["name"], "guest": a["guest"], "already": True, "sha256": a["sha256"]}
            return _err(2, "exists", "the guest file exists with other content; use --overwrite")
        vm["files"][a["guest"]] = data
        return {"ok": True, "exit": 0, "vm": rec["name"], "guest": a["guest"], "bytes": len(data), "sha256": a["sha256"]}

    def v_copy_from(self, a, download_to=None, **kw):
        rec, vm, e = self._vm(a, running=True)
        if e:
            return e
        data = vm["files"].get(a["guest"])
        if data is None:
            return _err(2, "missing", "no such file in the guest: %s" % a["guest"])
        sha = hashlib.sha256(data).hexdigest()
        Path(download_to).parent.mkdir(parents=True, exist_ok=True)
        Path(download_to).write_bytes(data)
        return {"ok": True, "exit": 0, "vm": rec["name"], "guest": a["guest"], "stage": "x", "file": "x",
                "bytes": len(data), "sha256": sha, "download": {"local": download_to, "sha256": sha, "bytes": len(data)}}

    def v_director(self, a, **kw):
        rec, vm, e = self._vm(a, running=True)
        if e:
            return e
        answers = []
        for s in a["steps"]:
            act = s["action"]
            if act in self.director_fail:
                answers.append(json.dumps({"ok": False, "error": self.director_fail[act], "detail": "fake failure"}))
                break
            if act == "screenshot":
                answers.append(json.dumps({"ok": True, "width": 1920, "height": 1080,
                                           "png_b64": base64.b64encode(tiny_png()).decode("ascii")}))
            elif act == "health":
                answers.append(json.dumps({"ok": True, "version": "0.1.0", "width": 1920, "height": 1080, "scaling": 100}))
            else:
                answers.append(json.dumps({"ok": True, "action": act, "body": json.loads(s["body"])}))
        return {"ok": True, "exit": 0, "vm": rec["name"], "answers": answers}

    def v_console(self, a, **kw):
        rec, e = self._rec(a)
        if e:
            return e
        return {"ok": True, "exit": 0, "vm": rec["name"], "console": "vmconnect.exe servera -G %s" % rec.get("vmid")}

    def v_job(self, a, **kw):
        j = self.jobs.get(a.get("job"))
        if not j:
            return _err(2, "unknown-job", "no job %s" % a.get("job"))
        if a.get("consumer") != "*admin*" and j["consumer"] != a.get("consumer"):
            return _err(2, "not-yours", "that job belongs to another consumer")
        name = next((r["name"] for r in self.records.values() if r["id"] == j["vm"]), None)
        return {"ok": True, "exit": 0, "job": j["id"], "verb": j["verb"], "vm": name, "state": j["state"],
                "step": j["step"], "job_exit": j["exit"], "error": j["error"], "hint": j["hint"],
                "result": j["result"], "log": []}
