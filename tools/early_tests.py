"""Early tests for v0.R on the recording VM (docs/design.md section 15 items 7, 11 and 12), through the normal
broker verbs, with the firewall monitor's numbers for each test's time window.

Run from the consumer folder (it holds vmbroker/consumer), after the build and before `golden` is taken:
    cd C:\\work\\cs101-walkthroughs
    C:\\work\\venvs\\vm-broker\\Scripts\\python.exe -I C:\\work\\vm-broker\\tools\\early_tests.py recording --preset ultrafast --seconds 60
    ... recording --preset veryfast --seconds 60
    ... checkpoint
    ... disk --seconds 30

Each prints one JSON result and saves it under C:\\work\\vm-broker-data\\. The firewall numbers come from the host's
monitor job (hostctl fwmon), so that job must be running.
"""
import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, r"C:\work\vm-broker\src")

from vm_broker.backend.hyperv import HyperVBackend  # noqa: E402
from vm_broker.client import load_settings, make_broker  # noqa: E402

DATA = Path(r"C:\work\vm-broker-data")
VM = "lab-p1"


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fw(t0, t1):
    s = load_settings()
    be = HyperVBackend(s["loader"])
    r = be.call(s["hosts"][0], "fwmon-summary", {"from": t0, "to": t1})
    return r.get("summary") if r.get("ok") else r


def recording(b, preset, seconds):
    name = "cost-%s-%s.mkv" % (preset, datetime.now().strftime("%H%M%S"))
    t0 = utc()
    r1 = b.director(VM, "record_start", {"filename": name, "preset": preset})
    if not r1.get("ok"):
        return {"step": "record_start", "result": r1}
    time.sleep(seconds)
    r2 = b.director(VM, "record_stop")
    t1 = utc()
    probe = b.run(VM, "$f = 'C:\\ProgramData\\LabDirector\\out\\%s'; (Get-Item $f).Length" % name)
    return {"preset": preset, "seconds": seconds, "stop": r2.get("answer"), "bytes": probe.get("stdout", "").strip(),
            "expected_frames": seconds * 30, "from": t0, "to": t1, "firewall": fw(t0, t1),
            "note": "copy the file out and run ffprobe -count_frames to see dropped frames"}


def checkpoint(b):
    t0 = utc()
    s = b.snapshot(VM, "t-early", replace=True, wait_s=600)
    t1 = utc()
    r = b.restore(VM, "t-early", wait_s=600)
    t2 = utc()
    b.delete_snapshot(VM, "t-early")
    return {"snapshot": s.get("result"), "restore": r.get("result"), "snapshot_window": [t0, t1],
            "restore_window": [t1, t2], "firewall_during_snapshot": fw(t0, t1), "firewall_during_restore": fw(t1, t2)}


def disk(b, seconds):
    # Typed enums: with strings, Windows PowerShell 5.1 finds the FileStream overload ambiguous, $fs stays $null and
    # the loop counts failed writes (2026-10-11: "405 MB/s" for a file of 0 bytes). The file's size is the check.
    cmd = ("$ErrorActionPreference = 'Stop'; $f = 'C:\\ProgramData\\vm-broker\\disk-test.bin'; "
           "$buf = New-Object byte[] (1MB); (New-Object Random 1).NextBytes($buf); "
           "$fs = New-Object IO.FileStream($f, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, "
           "4096, [IO.FileOptions]::WriteThrough); "
           "$sw = [Diagnostics.Stopwatch]::StartNew(); $n = 0; "
           "try { while ($sw.Elapsed.TotalSeconds -lt %d) { $fs.Write($buf, 0, $buf.Length); $fs.Flush($true); $n++ } } "
           "finally { $fs.Dispose() }; $len = (Get-Item $f).Length; Remove-Item $f; "
           "'{0:N1} MB/s ({1} MB written, file {2} MB)' -f ($n / $sw.Elapsed.TotalSeconds), $n, [int]($len / 1MB)" % seconds)
    t0 = utc()
    r = b.run(VM, cmd, timeout_s=seconds + 120)
    t1 = utc()
    return {"guest_write": r.get("stdout", "").strip(), "stderr": (r.get("stderr") or "")[:300],
            "exit_code": r.get("exit_code"), "from": t0, "to": t1, "firewall": fw(t0, t1)}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="test", required=True)
    s = sub.add_parser("recording"); s.add_argument("--preset", default="ultrafast"); s.add_argument("--seconds", type=int, default=60)
    sub.add_parser("checkpoint")
    s = sub.add_parser("disk"); s.add_argument("--seconds", type=int, default=30)
    a = ap.parse_args()
    b = make_broker()
    if a.test == "recording":
        r = recording(b, a.preset, a.seconds)
    elif a.test == "checkpoint":
        r = checkpoint(b)
    else:
        r = disk(b, a.seconds)
    DATA.mkdir(parents=True, exist_ok=True)
    p = DATA / ("early-%s-%s.json" % (a.test, datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")))
    p.write_text(json.dumps(r, indent=1), encoding="utf-8")
    print(json.dumps(dict(r, saved=str(p)), indent=1))


if __name__ == "__main__":
    main()
