"""Watch a broker job: one line per step change and one for the end (done, failed, lost, cancelled), for the Monitor
tool or a terminal. Usage: python -I tools/watch_job.py <host> <job id> [poll seconds]"""
import json
import sys
import time

sys.path.insert(0, r"C:\work\vm-broker\src")

from vm_broker.backend.hyperv import HyperVBackend  # noqa: E402
from vm_broker.client import load_settings  # noqa: E402


def main():
    host, job = sys.argv[1], sys.argv[2]
    poll = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    be = HyperVBackend(load_settings()["loader"])
    last, misses = None, 0
    while True:
        r = be.call(host, "job", {"consumer": "*admin*", "job": job}, timeout_s=300)
        if not r.get("ok"):
            misses += 1
            if misses in (1, 5, 20):
                print("job %s: host did not answer (%s: %s)" % (job[:8], r.get("error"), r.get("hint")), flush=True)
            time.sleep(poll)
            continue
        misses = 0
        state, step = r.get("state"), r.get("step")
        log = (r.get("log") or [])[-1:] or [""]
        key = (state, step)
        if key != last:
            print("job %s %s: %s | %s" % (job[:8], state, step or "-", log[0][:200]), flush=True)
            last = key
        if state in ("done", "failed", "lost", "cancelled"):
            tail = r.get("log") or []
            print("job %s ended %s: %s | %s" % (job[:8], state, r.get("hint") or "", json.dumps(r.get("result"))[:300]), flush=True)
            for line in tail[-6:]:
                print("  " + line[:220], flush=True)
            return
        time.sleep(poll)


if __name__ == "__main__":
    main()
