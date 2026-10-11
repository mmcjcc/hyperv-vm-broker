"""Acceptance A for v0.R (docs/design.md 13.3, on lan, without its last step: the recording VM is kept).

Runs the sequence through the consumer CLI from the consumer folder (it holds vmbroker/consumer and lab-p1.yml),
checks the video with ffprobe and the markers file, and writes a JSON report under C:\\work\\vm-broker-data\\.

    cd C:\\work\\cs101-walkthroughs
    C:\\work\\venvs\\vm-broker\\Scripts\\python.exe -I C:\\work\\vm-broker\\tools\\acceptance_a.py
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

VMB = r"C:\work\venvs\vm-broker\Scripts\vmb.cmd"
FFPROBE = r"C:\work\tools\ffmpeg-9.0.2\ffprobe.exe"
OUT = Path(r"C:\work\recordings\cs101-walkthroughs")
DATA = Path(r"C:\work\vm-broker-data")
GUEST_OUT = "C:\\ProgramData\\LabDirector\\out\\"


def vmb(*args, timeout=1800):
    t0 = time.monotonic()
    env = {k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}
    p = subprocess.run([VMB] + list(args), capture_output=True, text=True, timeout=timeout, env=env,
                       stdin=subprocess.DEVNULL)
    try:
        r = json.loads(p.stdout)
    except ValueError:
        r = {"ok": False, "exit": p.returncode, "raw": p.stdout[-500:], "stderr": p.stderr[-500:]}
    r["_seconds"] = round(time.monotonic() - t0, 1)
    r["_exit"] = p.returncode
    print("%-60s exit %s  %.1f s" % (" ".join(args)[:60], p.returncode, r["_seconds"]), flush=True)
    return r


def main():
    tag = datetime.now().strftime("%H%M%S")
    name = "smoke-%s" % tag
    rep = {"started": datetime.now(timezone.utc).isoformat(), "steps": {}}
    s = rep["steps"]
    s["create"] = vmb("create", "vmbroker/lab-p1.yml", "--wait", "60")
    s["snapshot"] = vmb("snapshot", "lab-p1", "smoke-start", "--replace", "--wait", "600")
    s["record_start"] = vmb("director", "lab-p1", "record_start", "%s.mkv" % name)
    s["run_visible"] = vmb("director", "lab-p1", "run_visible", "winget --version")
    time.sleep(4)
    s["marker"] = vmb("director", "lab-p1", "marker", "winget-version")
    time.sleep(2)
    s["record_stop"] = vmb("director", "lab-p1", "record_stop")
    OUT.mkdir(parents=True, exist_ok=True)
    s["copy_mkv"] = vmb("copy-from", "lab-p1", GUEST_OUT + name + ".mkv", str(OUT) + os.sep)
    s["copy_markers"] = vmb("copy-from", "lab-p1", GUEST_OUT + name + ".markers.json", str(OUT) + os.sep)
    s["restore"] = vmb("restore", "lab-p1", "smoke-start", "--wait", "900")
    s["health"] = vmb("director", "lab-p1", "health")
    checks = {}
    mkv = OUT / (name + ".mkv")
    if mkv.exists() and Path(FFPROBE).exists():
        p = subprocess.run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
                            "stream=codec_name,width,height:format=duration", "-of", "json", str(mkv)],
                           capture_output=True, text=True)
        probe = json.loads(p.stdout or "{}")
        st = (probe.get("streams") or [{}])[0]
        dur = float((probe.get("format") or {}).get("duration") or 0)
        checks["ffprobe"] = {"codec": st.get("codec_name"), "width": st.get("width"), "height": st.get("height"),
                             "duration_s": round(dur, 2)}
        checks["video_ok"] = st.get("codec_name") == "h264" and st.get("width") == 1920 and st.get("height") == 1080 and dur >= 3
    else:
        checks["video_ok"] = False
        checks["video_missing"] = str(mkv)
    mk = OUT / (name + ".markers.json")
    try:
        m = json.loads(mk.read_text(encoding="utf-8"))
        checks["markers"] = m
        checks["markers_ok"] = isinstance(m, list) and len(m) == 1 and m[0].get("label") == "winget-version"
    except (OSError, ValueError):
        checks["markers_ok"] = False
    res = (s["restore"].get("result") or {})
    checks["restore_s"] = res.get("restore_s")
    checks["director_after_restore_s"] = res.get("director_s")
    checks["director_within_60s"] = bool(res.get("director_s") is not None and res["director_s"] <= 60)
    checks["all_steps_ok"] = all(v.get("ok") for v in s.values())
    rep["checks"] = checks
    rep["passed"] = bool(checks["all_steps_ok"] and checks["video_ok"] and checks["markers_ok"])
    DATA.mkdir(parents=True, exist_ok=True)
    p = DATA / ("acceptance-a-%s.json" % datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    p.write_text(json.dumps(rep, indent=1), encoding="utf-8")
    print(json.dumps(checks, indent=1))
    print("passed: %s; report %s" % (rep["passed"], p))
    return 0 if rep["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
