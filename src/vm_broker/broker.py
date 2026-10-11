"""The operations, one method per consumer verb (docs/design.md 5.1). The CLI and the MCP server both call these;
nothing else decides what a verb does. Admin verbs live in admin.py and hostctl.py.

Each method checks its arguments, refuses what the running stage does not offer (exit 2, "not in v0.R"), and calls
the host verb, which resolves the VM by name to its registry record and VMId and re-checks ownership, the denylist
and the guardrails itself. Long verbs are jobs on the host; the method waits up to wait_s and otherwise returns the
job id with exit 4.

Rules worth repeating: run answers exit 0 when the command ran, with the guest's code in exit_code; snapshot
--replace takes the new checkpoint before it removes the old one (on the host); director wait_for waits at most
600 s per call; copy_from writes only inside VMB_OUT_DIR (never into OneDrive, never over a file unless asked);
copy_to and run --file read only from the project repo or VMB_OUT_DIR, never from a credentials folder.
"""
import base64
import hashlib
import json
import math
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

from . import STAGE, __version__, jobs
from . import schema as S
from .errors import BrokerError, ok, printable, rejected
from .profiles import PROFILES

PACKAGE_DIR = Path(__file__).resolve().parent
SOURCE_ROOT = PACKAGE_DIR.parents[1]          # the working copy (src/vm_broker -> repo root)


def _now_tag():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


_DEVICE_NAME = re.compile(r"(?i)^(con|prn|aux|nul|com[0-9\u00b9\u00b2\u00b3]|lpt[0-9\u00b9\u00b2\u00b3]|conin\$|conout\$)(\..*)?$")
# Folder names a consumer file never comes from (copy_to, run --file): credentials live there. Anywhere in the path:
SECRET_FOLDERS = frozenset({"netadmin", "secrets", ".ssh", ".gnupg", ".aws", ".azure", ".kube"})
# and below the project or VMB_OUT_DIR (tokens in .git/config, session settings):
PRIVATE_FOLDERS = frozenset({".git", ".claude", ".grok", "appdata"})


def local_path_problem(s):
    """Why `s` is not a plain local path, or None: text, at most 400 characters, no control characters, no UNC or
    device-namespace prefix, no colon but the drive letter's (no alternate data streams), no device name."""
    if not isinstance(s, str) or not s:
        return "a local path"
    if len(s) > 400:
        return "at most 400 characters"
    if any(ord(c) < 32 for c in s):
        return "no control characters"
    t = s.replace("/", "\\")
    if t.startswith("\\\\"):
        return "a path on this machine (no UNC, \\\\?\\ or \\\\.\\ paths)"
    if ":" in (t[2:] if re.match(r"^[A-Za-z]:", t) else t):
        return "no ':' except after the drive letter (no alternate data streams)"
    for part in t.split("\\"):
        if _DEVICE_NAME.match(part.rstrip(" .")):
            return "no device names (%s)" % part
    return None


def _inside(path, root):
    return path == root or root in path.parents


LOCK_WAIT_S = 30          # the director's input lock wait


def _typing_s(text, cps, jitter, enter):
    """The longest the director's Typist takes for text (vm_director/keys.py): 1/cps x (1 + jitter) per character,
    up to 0.35 s more after punctuation, up to 0.6 s per Enter, and 10 ms per character for SendInput itself."""
    n = len(text)
    punct = sum(text.count(c) for c in ".,;:!?")
    enters = text.count("\n") + (1 if enter else 0)
    return n / cps * (1 + jitter) + 0.35 * punct + 0.6 * enters + 0.01 * n


def _num_or(value, default):
    """A finite int or float (not a bool), else the default: the director takes floats for cps and timeout_s."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    if isinstance(value, float) and not math.isfinite(value):
        return default
    return value


def director_step_timeout(action, payload):
    """Seconds the relay allows one director step. Not capped here: director() refuses a step over
    S.DIRECTOR_STEP_MAX_S (the host's limit) instead of letting the relay give up while the director still types."""
    p = payload if isinstance(payload, dict) else {}
    if action == "type":
        text = p.get("text") if isinstance(p.get("text"), str) else ""
        cps = max(1.0, _num_or(p.get("cps"), 14))
        jitter = min(1.0, max(0.0, _num_or(p.get("jitter"), 0.35)))
        t = _typing_s(text, cps, jitter, bool(p.get("enter"))) + LOCK_WAIT_S + 20
    elif action == "run_visible":
        cmd = p.get("command") if isinstance(p.get("command"), str) else ""
        # a new terminal: up to 90 s for its window and 60 s for its shell, then the typing and Enter
        t = _typing_s(cmd, 14, 0.35, True) + LOCK_WAIT_S + 90 + 60 + 20
    elif action == "wait_for":
        t = min(S.WAIT_FOR_MAX_S, max(1, _num_or(p.get("timeout_s"), 30))) + 20
    elif action == "click":
        # the input lock may be busy for up to LOCK_WAIT_S first (the director answers deadline after that)
        t = min(5000, max(0, _num_or(p.get("move_ms"), 400))) / 1000 * 2 + LOCK_WAIT_S + 15
    elif action == "key":
        t = 15 + min(100, max(1, _num_or(p.get("repeat"), 1))) + LOCK_WAIT_S
    elif action in ("record_start", "record_stop"):
        # record_start waits for ffmpeg's first frame: behind the disk cap, while the host merges a removed
        # checkpoint, that took over a minute (2026-10-11); a relay that gave up would hide a running recording
        t = 90
    elif action == "screenshot":
        t = 45
    else:
        t = 20
    return int(math.ceil(max(5, t)))


class Broker:
    def __init__(self, backend, consumer=None, consumer_error=None, repo_root=None, settings=None, stage=STAGE,
                 clock=time.monotonic, sleep=time.sleep):
        self.backend = backend
        self.consumer = consumer
        self.consumer_error = consumer_error
        self.repo_root = Path(repo_root) if repo_root else None
        self.settings = settings or {"hosts": ["servera"], "out_dir": "", "wait_s": S.WAIT_DEFAULT_S,
                                     "transport": "direct", "loader": ""}
        self.stage = stage
        self.clock, self.sleep = clock, sleep

    # ---- plumbing ----

    @property
    def out_dir(self):
        d = self.settings.get("out_dir") or os.path.join("C:\\work\\recordings", self.consumer or "no-consumer")
        return d

    def _host(self):
        offered = S.STAGES[self.stage]["hosts"]
        for h in self.settings.get("hosts") or []:
            if h in offered:
                return h
        return offered[0]

    def _need(self, verb):
        if self.consumer_error or not self.consumer:
            return BrokerError(S.EXIT_REJECTED, "no-consumer", self.consumer_error or "no consumer name").result()
        if verb not in S.STAGES[self.stage]["verbs"]:
            return rejected("%s: not in %s" % (verb, self.stage), error="not-in-stage")
        return None

    def _vm_arg(self, vm):
        if not isinstance(vm, str) or not S.NAME_RE.fullmatch(vm) or vm.endswith("-") or vm.startswith(S.VM_PREFIX):
            return rejected("vm: a VM name as in its request (without vmb-), ^[a-z][a-z0-9-]{1,10}$")
        return None

    def _call(self, verb, args, **kw):
        a = {"consumer": self.consumer}
        a.update(args)
        return self.backend.call(self._host(), verb, a, **kw)

    def _wait_s(self, wait_s):
        if wait_s is None:
            return self.settings.get("wait_s", S.WAIT_DEFAULT_S)
        return max(0, min(S.WAIT_MAX_S, int(wait_s)))

    def _job(self, r, wait_s):
        if not r.get("ok") or not r.get("job"):
            return r
        st = jobs.wait(self.backend, self._host(), r["job"], self.consumer, self._wait_s(wait_s),
                       clock=self.clock, sleep=self.sleep)
        out = dict(st)
        out.setdefault("vm", r.get("vm"))
        out["job"] = r["job"]
        return out

    def _out_path(self, *parts):
        d = Path(self.out_dir)
        from .client import is_under_onedrive
        if is_under_onedrive(d):
            raise BrokerError(S.EXIT_REJECTED, "rejected", "VMB_OUT_DIR is inside OneDrive; set it to a folder outside")
        return d.joinpath(*parts)

    def _source_roots(self):
        """Where copy_to and run --file may read: VMB_OUT_DIR and the project repo, unless the repo root is so high
        that it holds the home folder or a OneDrive root (a vmbroker/consumer file placed too far up)."""
        roots = []
        try:
            roots.append(self._out_path().resolve())
        except (BrokerError, OSError):
            pass
        if self.repo_root:
            r = Path(self.repo_root).resolve()
            broad = [Path.home().resolve()] + [Path(os.environ[k]).resolve() for k in
                                               ("OneDrive", "OneDriveCommercial", "OneDriveConsumer") if os.environ.get(k)]
            if len(r.parts) > 1 and not any(_inside(b, r) for b in broad):
                roots.append(r)
        return roots

    def local_source(self, local, what="local"):
        """(resolved Path, None) for a file a consumer may send into a VM, else (None, the rejection)."""
        why = local_path_problem(local)
        if why:
            return None, rejected("%s: %s" % (what, why))
        p = Path(local)
        try:
            p = (p if p.is_absolute() else Path.cwd() / p).resolve(strict=True)
        except OSError:
            return None, rejected("%s: an existing file" % what)
        if not p.is_file():
            return None, rejected("%s: an existing file" % what)
        roots = [r for r in self._source_roots() if _inside(p, r)]
        if not roots:
            return None, rejected("%s: a file inside this project or VMB_OUT_DIR (%s)"
                                  % (what, " or ".join(map(str, self._source_roots()))))
        below = p.relative_to(roots[0]).parts
        if (any(part.lower() in SECRET_FOLDERS for part in p.parts)
                or any(part.lower() in PRIVATE_FOLDERS for part in below)):
            return None, rejected("%s: never from a credentials or settings folder" % what)
        return p, None

    # ---- read-only verbs ----

    def contract(self):
        p = SOURCE_ROOT / "CONTRACT.md"
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            text = ""
        commit = None
        try:
            head = (SOURCE_ROOT / ".git" / "HEAD").read_text().strip()
            if head.startswith("ref: "):
                ref = SOURCE_ROOT / ".git" / head[5:]
                commit = ref.read_text().strip() if ref.exists() else None
            else:
                commit = head
        except OSError:
            pass
        return ok(contract=S.CONTRACT, version=__version__, stage=self.stage, commit=commit, text=text)

    def whoami(self):
        e = self._need("whoami")
        if e:
            return e
        st = S.STAGES[self.stage]
        reach = self._call("list", {})
        r = ok(consumer=self.consumer, stage=self.stage, transport=self.settings.get("transport", "direct"),
               hosts=list(st["hosts"]), out_dir=str(self.out_dir),
               offers={"profiles": list(st["profiles"]), "networks": list(st["networks"]), "verbs": list(st["verbs"]),
                       "director": "director" in st["verbs"]},
               refuses=self._refusals(), quotas="not in %s (one recording VM at a time)" % self.stage
               if self.stage == "v0.R" else "see CONTRACT.md 12")
        if not reach.get("ok"):
            r.update(ok=False, exit=reach.get("exit", S.EXIT_UNREACHABLE), error=reach.get("error", "unreachable"),
                     hint=reach.get("hint", "the host did not answer"))
        else:
            r["vms"] = len(reach.get("vms") or [])
        return r

    def _refusals(self):
        st = S.STAGES[self.stage]
        out = ["profiles other than %s" % ", ".join(st["profiles"])]
        out.append("verbs: %s" % ", ".join(v for v in S.STAGES["v1"]["verbs"] if v not in st["verbs"]) or "none")
        if self.stage == "v0.R":
            out += ["isolated networks", "users, firewall rules, software and scripts in the request",
                    "activation: mak and lease: {keep: true} except for the recording VM the host policy names",
                    "a second recording VM", "Linux run and copy"]
        return out

    def profiles(self):
        st = S.STAGES[self.stage]
        items = []
        for name, p in PROFILES.items():
            items.append({
                "profile": name, "from": p["from"], "offered": name in st["profiles"], "what": p["what"],
                "default": {"cpu": p["default"]["cpu"], "memory": "%dg" % (p["default"]["memory_mb"] // 1024),
                            "disk": "%dg" % p["default"]["disk_gb"]},
                "min": {"cpu": p["min"]["cpu"], "memory": "%dg" % (p["min"]["memory_mb"] // 1024),
                        "disk": "%dg" % p["min"]["disk_gb"]},
                "access": list(p["access"]), "packages": list(p["packages"]), "checkpoints": p["checkpoints"],
            })
        r = ok(stage=self.stage, profiles=items, limits={"cpu": S.MAX_CPU, "memory": "16g", "disk": "500g"})
        if self.stage == "v0.R":
            r["note"] = ("v0.R: win11-lab is one kept VM on Windows Server 2025 Desktop Experience (lab_os win2025), "
                         "on serverd, activated once, on lan with all inbound blocked; no image, no clones")
        return r

    def capacity(self):
        inv = self.backend.call(self._host(), "inventory", {})
        if not inv.get("ok"):
            return inv
        pol = (inv.get("broker") or {}).get("policy") or {}
        fw = pol.get("firewall_vm", "Firewall3")
        fw_vm = next((v for v in inv.get("vms") or [] if v.get("name") == fw), None)
        broker_mb = sum(v.get("memory_assigned_mb") or 0 for v in inv.get("vms") or [] if v.get("broker_name"))
        return ok(hosts=[{
            "host": inv.get("host"), "available_mb": (inv.get("memory") or {}).get("available_mb"),
            "floor_gb": pol.get("floor_gb"), "budget": "what is available above the floor",
            "broker_vms_mb": broker_mb, "firewall_running_here": bool(fw_vm and fw_vm.get("state") == "Running"),
        }])

    # ---- requests ----

    def _load_request(self, request):
        from . import yamlstrict
        from .validate import validate_request
        if not isinstance(request, str) or not request:
            return None, None, rejected("request: the path of the request file")
        root = (self.repo_root or Path.cwd()).resolve()
        p = Path(request)
        p = (p if p.is_absolute() else Path.cwd() / p).resolve()
        if root not in p.parents:
            return None, None, rejected("request: the file must be inside the project repo (%s)" % root.name)
        try:
            data = p.read_bytes()
        except OSError:
            return None, None, rejected("request: cannot read %s" % p.name)
        try:
            raw = yamlstrict.load_mapping(data)
        except yamlstrict.StrictYAMLError as e:
            return None, None, rejected("the request file is not acceptable", ["file: %s" % e])
        except ImportError:
            return None, None, BrokerError(S.EXIT_UNREACHABLE, "unreachable",
                                           "PyYAML is not installed in the broker's venv; tell the operator").result()
        scripts = {}
        named = raw.get("scripts") if isinstance(raw.get("scripts"), list) else []
        for s in named:
            if isinstance(s, str) and s and ".." not in s and not s.startswith(("/", "\\")):
                sp = (root / s).resolve()
                if root in sp.parents and sp.is_file():
                    try:
                        scripts[s] = sp.read_bytes()
                    except OSError:
                        pass
        norm, findings = validate_request(raw, scripts, self.consumer, self.stage)
        if findings:
            return None, None, rejected("the request has findings; nothing changed", findings)
        return norm, scripts, None

    def plan(self, request):
        e = self._need("plan")
        if e:
            return e
        norm, _scripts, err = self._load_request(request)
        if err:
            return err
        from .validate import needs_approval, request_hash
        h = request_hash(norm)
        host = self._host()
        check = self._call("create", {"request": norm, "request_hash": h}, whatif=True)
        r = ok(request=norm, request_hash=h, host=host, needs=needs_approval(norm, self.stage))
        if check.get("ok"):
            if check.get("existing"):
                r["decision"] = "exists: create returns the existing VM %s (state %s)" % (norm["name"], check.get("state"))
            elif r["needs"] and self.stage == "v0.R":
                r["decision"] = "automatic: %s approved for this recording VM in the host policy" % ", ".join(r["needs"])
            else:
                r["decision"] = "automatic"
        else:
            r.update(ok=False, exit=check.get("exit", S.EXIT_REJECTED), error=check.get("error"),
                     hint=check.get("hint"), findings=check.get("findings") or [])
            r["decision"] = "refused by %s" % host
        return r

    def create(self, request, wait_s=None):
        e = self._need("create")
        if e:
            return e
        norm, _scripts, err = self._load_request(request)
        if err:
            return err
        from .validate import request_hash
        h = request_hash(norm)
        r = self._call("create", {"request": norm, "request_hash": h})
        if not r.get("ok"):
            return r
        if r.get("existing") and not r.get("job"):
            st = self.status(norm["name"])
            st["existing"] = True
            return st
        out = self._job(r, wait_s)
        if out.get("ok"):
            st = self.status(norm["name"])
            st["job"] = r.get("job")
            return st
        return out

    # ---- VM verbs ----

    def list(self):
        e = self._need("list")
        return e or self._call("list", {})

    def status(self, vm, director=False):
        e = self._need("status") or self._vm_arg(vm)
        return e or self._call("status", {"name": vm, "director": bool(director)})

    def start(self, vm):
        e = self._need("start") or self._vm_arg(vm)
        return e or self._call("start", {"name": vm})

    def stop(self, vm, force=False, wait_s=None):
        e = self._need("stop") or self._vm_arg(vm)
        return e or self._job(self._call("stop", {"name": vm, "force": bool(force)}), wait_s)

    def destroy(self, vm, confirm):
        e = self._vm_arg(vm)
        if e:
            return e
        if confirm != vm:
            return rejected("confirm: must repeat the VM name exactly")
        if "destroy" not in S.STAGES[self.stage]["verbs"]:
            return rejected("destroy: not in %s (the recording VM holds a MAK activation; only the operator destroys it)"
                            % self.stage, error="not-in-stage")
        return self._need("destroy") or self._call("destroy", {"name": vm})

    def extend(self, vm, days):
        e = self._vm_arg(vm)
        if e:
            return e
        if "extend" not in S.STAGES[self.stage]["verbs"]:
            return rejected("extend: not in %s (the recording VM is kept; it has no lease)" % self.stage,
                            error="not-in-stage")
        return self._need("extend") or self._call("extend", {"name": vm, "days": days})

    def _label(self, label):
        if not isinstance(label, str) or not S.LABEL_RE.fullmatch(label):
            return rejected("label: must match ^[a-z0-9][a-z0-9._-]{0,47}$")
        return None

    def snapshot(self, vm, label, replace=False, wait_s=None):
        e = self._need("snapshot") or self._vm_arg(vm) or self._label(label)
        return e or self._job(self._call("snapshot", {"name": vm, "label": label, "replace": bool(replace)}), wait_s)

    def restore(self, vm, label, wait_s=None):
        e = self._need("restore") or self._vm_arg(vm) or self._label(label)
        return e or self._job(self._call("restore", {"name": vm, "label": label}), wait_s)

    def list_snapshots(self, vm):
        e = self._need("snapshots") or self._vm_arg(vm)
        return e or self._call("snapshots", {"name": vm})

    def delete_snapshot(self, vm, label):
        e = self._need("snapshot-rm") or self._vm_arg(vm) or self._label(label)
        return e or self._call("snapshot-rm", {"name": vm, "label": label})

    def console(self, vm):
        e = self._need("console") or self._vm_arg(vm)
        return e or self._call("console", {"name": vm})

    def run(self, vm, command, interactive=False, timeout_s=S.RUN_TIMEOUT_DEFAULT_S):
        e = self._need("run") or self._vm_arg(vm)
        if e:
            return e
        if not isinstance(command, str) or not command or len(command.encode("utf-8")) > S.RUN_COMMAND_MAX_BYTES:
            return rejected("command: 1 to 8192 bytes")
        if not isinstance(timeout_s, int) or isinstance(timeout_s, bool) or not 1 <= timeout_s <= S.RUN_TIMEOUT_MAX_S:
            return rejected("timeout_s: 1 to 3600")
        return self._call("run", {"name": vm, "command": command, "interactive": bool(interactive),
                                  "timeout_s": timeout_s}, timeout_s=timeout_s + 240)

    def copy_to(self, vm, local, guest, overwrite=False):
        e = self._need("copy-to") or self._vm_arg(vm)
        if e:
            return e
        p, e = self.local_source(local)
        if e:
            return e
        size = p.stat().st_size
        if size > S.COPY_TO_MAX_BYTES:
            return rejected("local: at most 512 MiB in %s" % self.stage, error="too-large")
        sha = _sha256_file(p)
        name = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in p.name) or "file"
        r = self._call("copy-to", {"name": vm, "guest": guest, "overwrite": bool(overwrite), "sha256": sha},
                       mode="upload", upload=[{"local": str(p), "rel": name}], timeout_s=3600)
        return r

    def copy_from(self, vm, guest, local=None, overwrite=False):
        e = self._need("copy-from") or self._vm_arg(vm)
        if e:
            return e
        if not isinstance(guest, str) or not guest:
            return rejected("guest: the file's full path in the guest")
        if local is not None and local != "":
            why = local_path_problem(local)
            if why:
                return rejected("local: " + why)
        base = guest.replace("/", "\\").rsplit("\\", 1)[-1] or "file"
        base = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in base)
        from .client import is_under_onedrive
        try:
            root = self._out_path().resolve()
            if local:
                dest = Path(local)
                if not dest.is_absolute():
                    dest = root / dest          # relative: under VMB_OUT_DIR
                if dest.is_dir() or str(local).endswith(("\\", "/")):
                    dest = dest / base
            else:
                dest = root / vm / base
            dest = dest.resolve()
        except BrokerError as be:
            return be.result()
        except OSError:
            return rejected("local: cannot resolve the path")
        if is_under_onedrive(dest):
            return rejected("local: never into OneDrive (it syncs every large file); use VMB_OUT_DIR (%s)" % root)
        if not _inside(dest, root) or dest == root:
            return rejected("local: inside VMB_OUT_DIR (%s); copy on from there yourself if you must" % root)
        if dest.is_dir():
            return rejected("local: %s is a folder" % dest)
        if dest.exists() and not overwrite:
            return rejected("local: %s exists; pass overwrite to replace it" % dest, error="exists")
        r = self._call("copy-from", {"name": vm, "guest": guest}, mode="download", download_to=str(dest),
                       timeout_s=4000)
        if r.get("ok") and r.get("download"):
            d = r.pop("download")
            r["local"] = d.get("local")
            r.pop("file", None)
            r.pop("stage", None)
        return r

    # ---- the director ----

    def director(self, vm, action, payload=None):
        e = self._need("director") or self._vm_arg(vm)
        if e:
            return e
        if payload is not None and not isinstance(payload, dict):
            return rejected("payload: a JSON object")
        if action == "batch":
            steps_in = (payload or {}).get("steps")
            if not isinstance(steps_in, list) or not 1 <= len(steps_in) <= S.DIRECTOR_MAX_STEPS:
                return rejected("payload.steps: 1 to 50 steps, each {action, payload}")
            steps = []
            for i, s in enumerate(steps_in):
                if not isinstance(s, dict) or s.get("action") not in S.DIRECTOR_ACTIONS or \
                        not isinstance(s.get("payload", {}), dict) or set(s) - {"action", "payload"}:
                    return rejected("payload.steps[%d]: {action: one of %s, payload: {...}}" % (i, ", ".join(S.DIRECTOR_ACTIONS)))
                steps.append((s["action"], s.get("payload") or {}))
        elif action in S.DIRECTOR_ACTIONS:
            steps = [(action, payload or {})]
        else:
            return rejected("action: one of %s, or batch" % ", ".join(S.DIRECTOR_ACTIONS + ("batch",)))
        wire = []
        for i, (a, p) in enumerate(steps):
            try:
                body = json.dumps(p, ensure_ascii=True, allow_nan=False)
            except ValueError:
                return rejected("payload: numbers must be finite (no NaN or Infinity)")
            if len(body) > S.DIRECTOR_PAYLOAD_MAX_BYTES:
                return rejected("payload: at most 64 KiB per step")
            t = director_step_timeout(a, p)
            if t > S.DIRECTOR_STEP_MAX_S:
                return rejected("payload: step %d (%s) would take about %d s, more than one step may (%d s); split it"
                                % (i, a, t, S.DIRECTOR_STEP_MAX_S), error="too-long")
            wire.append({"action": a, "body": body, "timeout_s": t})
        total = sum(w["timeout_s"] for w in wire)
        if total > S.DIRECTOR_CALL_MAX_S:
            return rejected("payload: these steps may take up to %d s; one director call takes at most %d s, so split "
                            "the batch (a wait_for can be called again)" % (total, S.DIRECTOR_CALL_MAX_S), error="too-long")
        r = self._call("director", {"name": vm, "steps": wire}, timeout_s=sum(w["timeout_s"] + 10 for w in wire) + 180)
        if not r.get("ok"):
            return r
        answers = []
        for raw in r.get("answers") or []:
            try:
                a = json.loads(raw)
            except (TypeError, ValueError):
                a = {"ok": False, "error": "bad-answer", "detail": printable(str(raw)[:200])}
            if not isinstance(a, dict):
                a = {"ok": False, "error": "bad-answer"}
            answers.append(a)
        png_path = None
        for i, a in enumerate(answers):
            if isinstance(a.get("png_b64"), str):
                try:
                    data = base64.b64decode(a.pop("png_b64"), validate=True)
                    path = self._out_path(vm, "screenshot-%s-%d.png" % (_now_tag(), i))
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                    a["png_path"] = png_path = str(path)
                except (ValueError, OSError, BrokerError) as ex:
                    a["png_error"] = printable(str(ex))[:200]
        failed = next((a for a in answers if not a.get("ok")), None)
        done = sum(1 for a in answers if a.get("ok"))
        out = ok(vm=vm, action=action)
        if action == "batch":
            out.update(answers=answers, completed=done, steps=len(steps))
        else:
            out["answer"] = answers[0] if answers else None
        if png_path:
            out["png_path"] = png_path
        if failed is not None or done < len(steps):
            f = failed or {"error": "no-answer", "detail": "the relay returned %d of %d answers" % (len(answers), len(steps))}
            hint = "director: %s: %s" % (f.get("error", "error"), f.get("detail", ""))
            if action == "batch":
                hint += " (the batch stopped after %d of %d steps)" % (done, len(steps))
            out.update(ok=False, exit=S.EXIT_FAILED, error="director", hint=printable(hint))
            if action != "screenshot" and not png_path:
                shot = self.director(vm, "screenshot")
                if shot.get("png_path"):
                    out["png_path"] = shot["png_path"]
        return out

    # ---- jobs ----

    def job_status(self, job):
        if not isinstance(job, str) or not S.ID_RE.fullmatch(job):
            return rejected("job: a job id (32 hex)")
        e = self._need("job")
        return e or self._call("job", {"job": job})

    def job_wait(self, job, wait_s=None):
        if not isinstance(job, str) or not S.ID_RE.fullmatch(job):
            return rejected("job: a job id (32 hex)")
        e = self._need("wait")
        if e:
            return e
        return jobs.wait(self.backend, self._host(), job, self.consumer, self._wait_s(wait_s), clock=self.clock,
                         sleep=self.sleep)
