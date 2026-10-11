"""Wait until a broker job leaves the given steps (or ends), then print its state, step and last log lines.
Usage: python -I tools/wait_step.py <host> <job> <step>[,<step>...] [poll seconds]"""
import sys
import time

sys.path.insert(0, r"C:\work\vm-broker\src")

from vm_broker.backend.hyperv import HyperVBackend  # noqa: E402
from vm_broker.client import load_settings  # noqa: E402


def main():
    host, job, steps = sys.argv[1], sys.argv[2], set(sys.argv[3].split(","))
    poll = int(sys.argv[4]) if len(sys.argv) > 4 else 60
    be = HyperVBackend(load_settings()["loader"])
    while True:
        r = be.call(host, "job", {"consumer": "*admin*", "job": job}, timeout_s=300)
        if r.get("ok") and (r.get("state") in ("done", "failed", "lost", "cancelled") or r.get("step") not in steps):
            print("job %s: %s / %s %s" % (job[:8], r.get("state"), r.get("step"), r.get("hint") or ""))
            for line in (r.get("log") or [])[-8:]:
                print("  " + line[:240])
            return
        time.sleep(poll)


if __name__ == "__main__":
    main()
