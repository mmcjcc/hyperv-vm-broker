"""hostctl: the build session's host steps for v0.R (python -I -m vm_broker.hostctl <verb>). Not a consumer tool,
never an MCP tool. Every live step here waits for the operator's go-ahead the first time (CLAUDE.md).

  inventory               read-only facts (inline: works before the install)
  baseline --minutes N    read-only firewall baseline from the host (ping and DNS through Firewall3, counters)
  install [--whatif]      the one-time install (docs/design.md 3.8): vmb\\ with its ACL, policy.json, the certificate
  uninstall [--whatif]    the reverse; refuses while a broker VM exists
  sync-code [--whatif]    the backend scripts into vmb\\code\\ (checked by SHA-256), and code\\VERSION
  set-policy FILE         replace policy.json
  stage-director DIR      the director bundle (tools/Stage-LabDirector.ps1 output) into vmb\\media\\labdirector\\
  copy-iso SOURCE         the Server 2025 ISO from another host, throttled, in the copy window (disconnected)
  fwmon --hours H         the firewall monitor job; fwmon-summary --from T [--to T]
  resume VM [--from STEP] run the recording VM's build again from a step
  gvlk-proof VM           section 15 item 15 with Microsoft's public GVLK (uses no activation; refused once the
                          VM may hold an activation)
  snapshot-rm VM LABEL    remove a checkpoint, a protected one (policy protected_checkpoints: golden) included
  list | status VM | job ID | job-cancel ID   as the operator sees them

Results print as JSON; large ones (baseline samples) are also saved under C:\\work\\vm-broker-data\\.
"""
import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from .backend.hyperv import HyperVBackend, code_version, host_scripts
from .client import is_under_onedrive, load_settings

DATA_DIR = Path(r"C:\work\vm-broker-data")
REPO = Path(__file__).resolve().parents[2]
GVLK = {"standard": "TVRH6-WHNXV-R9WG3-9XRFY-MY832", "datacenter": "D764K-2NDRG-47T6Q-P8T8W-YP6DF"}


def _save(name, value):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    p = DATA_DIR / ("%s-%s.json" % (name, datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")))
    p.write_text(json.dumps(value, indent=1, sort_keys=True), encoding="utf-8")
    return str(p)


def _sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hostctl")
    ap.add_argument("--host", default=None)
    ap.add_argument("--whatif", action="store_true")
    sub = ap.add_subparsers(dest="verb", required=True)
    sub.add_parser("inventory")
    s = sub.add_parser("baseline"); s.add_argument("--minutes", type=int, default=30); s.add_argument("--interval", type=int, default=5)
    s = sub.add_parser("install"); s.add_argument("--secrets", choices=("cms", "dpapi"), default="cms")
    s.add_argument("--policy", default=None, help="default: policy/<host>.json")
    s = sub.add_parser("uninstall"); s.add_argument("--remove-cert", action="store_true")
    sub.add_parser("sync-code")
    s = sub.add_parser("set-policy"); s.add_argument("file")
    s = sub.add_parser("stage-director"); s.add_argument("bundle")
    s = sub.add_parser("copy-iso"); s.add_argument("source"); s.add_argument("--mbps", type=float, default=8)
    s.add_argument("--now", action="store_true", help="do not wait for the copy window")
    s = sub.add_parser("fwmon"); s.add_argument("--hours", type=float, default=12); s.add_argument("--interval", type=int, default=10)
    s = sub.add_parser("fwmon-summary"); s.add_argument("--from", dest="frm", required=True); s.add_argument("--to")
    s = sub.add_parser("resume"); s.add_argument("vm"); s.add_argument("--from", dest="frm")
    s = sub.add_parser("gvlk-proof"); s.add_argument("vm"); s.add_argument("--edition", choices=tuple(GVLK), default="standard")
    s = sub.add_parser("snapshot-rm"); s.add_argument("vm"); s.add_argument("label")
    sub.add_parser("list")
    s = sub.add_parser("status"); s.add_argument("vm")
    s = sub.add_parser("job"); s.add_argument("job")
    s = sub.add_parser("job-cancel"); s.add_argument("job")
    a = ap.parse_args(argv)

    st = load_settings()
    host = a.host or (st["hosts"] or ["servera"])[0]
    be = HyperVBackend(st["loader"])
    call = lambda verb, args, **kw: be.call(host, verb, args, whatif=a.whatif, **kw)

    if a.verb == "inventory":
        r = call("inventory", {}, mode="inline")
    elif a.verb == "baseline":
        samples, chunks = [], []
        left = a.minutes * 60
        while left > 0:
            d = min(600, left)
            r = call("baseline", {"duration_s": d, "interval_s": a.interval}, mode="inline", timeout_s=d + 300)
            if not r.get("ok"):
                break
            samples += r.get("samples") or []
            chunks.append(r.get("summary"))
            left -= d
        if r.get("ok"):
            r = {"ok": True, "exit": 0, "host": host, "minutes": a.minutes, "n": len(samples), "chunks": chunks,
                 "from": samples[0]["t"] if samples else None, "to": samples[-1]["t"] if samples else None}
            r["saved"] = _save("baseline-%s" % host, {"summary_per_chunk": chunks, "samples": samples})
    elif a.verb == "install":
        pol = json.loads(Path(a.policy or (REPO / "policy" / ("%s.json" % host))).read_text(encoding="utf-8"))
        r = call("install", {"policy": pol, "secrets": a.secrets}, mode="inline")
    elif a.verb == "uninstall":
        r = call("uninstall", {"remove_cert": a.remove_cert}, mode="inline")
    elif a.verb == "sync-code":
        files = host_scripts()
        r = call("install-code", {"version": code_version(), "files": [{"path": p.name, "sha256": _sha(p)} for p in files]},
                 mode="upload", stage_inline=True, upload=[{"local": str(p), "rel": p.name} for p in files])
    elif a.verb == "set-policy":
        r = call("set-policy", {"policy": json.loads(Path(a.file).read_text(encoding="utf-8"))})
    elif a.verb == "stage-director":
        root = Path(a.bundle).resolve()
        if is_under_onedrive(root):
            print("the bundle must be outside OneDrive", file=sys.stderr)
            return 2
        man = root / "manifest.json"
        if not man.is_file():
            print("no manifest.json in %s" % root, file=sys.stderr)
            return 2
        files = sorted(p for p in root.rglob("*") if p.is_file())
        rel = [str(p.relative_to(root)) for p in files]
        r = call("stage-director", {"version": hashlib.sha256(man.read_bytes()).hexdigest()[:16],
                                    "files": [{"path": rp, "sha256": _sha(p)} for rp, p in zip(rel, files)]},
                 mode="upload", upload=[{"local": str(p), "rel": rp} for rp, p in zip(rel, files)], timeout_s=3600)
    elif a.verb == "copy-iso":
        r = call("copy-iso", {"source": a.source, "mbps": a.mbps, "wait_for_window": not a.now}, mode="iso")
    elif a.verb == "fwmon":
        r = call("fwmon", {"hours": a.hours, "interval_s": a.interval})
    elif a.verb == "fwmon-summary":
        args = {"from": a.frm}
        if a.to:
            args["to"] = a.to
        r = call("fwmon-summary", args)
    elif a.verb == "resume":
        args = {"name": a.vm}
        if a.frm:
            args["from"] = a.frm
        r = call("resume", args)
    elif a.verb == "gvlk-proof":
        r = call("activate", {"name": a.vm, "mode": "gvlk-proof", "key": GVLK[a.edition]}, timeout_s=900)
    elif a.verb == "snapshot-rm":
        r = call("snapshot-rm", {"consumer": "*admin*", "name": a.vm, "label": a.label})
    elif a.verb == "list":
        r = call("list", {"consumer": "*admin*"})
    elif a.verb == "status":
        r = call("status", {"consumer": "*admin*", "name": a.vm, "director": True})
    elif a.verb == "job":
        r = call("job", {"consumer": "*admin*", "job": a.job})
    elif a.verb == "job-cancel":
        r = call("job-cancel", {"job": a.job})
    else:
        r = {"ok": False, "exit": 2, "error": "usage"}
    print(json.dumps(r, indent=1, sort_keys=True))
    return int(r.get("exit", 1))


if __name__ == "__main__":
    sys.exit(main())
