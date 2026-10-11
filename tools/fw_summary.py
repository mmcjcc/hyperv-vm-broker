"""The firewall monitor's numbers for a time window, next to the baseline: one line per metric.
Usage: python -I tools/fw_summary.py <host> <from UTC> [<to UTC>] [--baseline <saved summary json>]"""
import argparse
import json
import sys

sys.path.insert(0, r"C:\work\vm-broker\src")

from vm_broker.backend.hyperv import HyperVBackend  # noqa: E402
from vm_broker.client import load_settings  # noqa: E402

KEYS = ["ping 192.168.10.1", "ping 1.1.1.1", "dns 192.168.10.1", "dns 1.1.1.1", "replica Firewall3 lag_min",
        "replica Firewall3 health", "\\physicaldisk(_total)\\avg. disk sec/write",
        "\\physicaldisk(_total)\\current disk queue length", "\\hyper-v hypervisor logical processor(_total)\\% total run time",
        "\\memory\\available mbytes"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host"); ap.add_argument("frm"); ap.add_argument("to", nargs="?")
    ap.add_argument("--baseline", default=r"C:\work\vm-broker-data\baseline-serverd-20261010T1949Z.json")
    a = ap.parse_args()
    args = {"from": a.frm}
    if a.to:
        args["to"] = a.to
    r = HyperVBackend(load_settings()["loader"]).call(a.host, "fwmon-summary", args)
    if not r.get("ok"):
        print(json.dumps(r))
        return 1
    try:
        base = json.load(open(a.baseline, encoding="utf-8")).get("summary", {})
    except (OSError, ValueError):
        base = {}
    print("window %s .. %s, %s samples (baseline in brackets: p50/p95/max)" % (r.get("from"), r.get("to"), r.get("n")))
    for k in KEYS:
        v, b = r["summary"].get(k, {}), base.get(k, {})
        print("%-62s p50=%-8s p95=%-8s max=%-8s lost=%-3s [%s/%s/%s]" % (
            k, v.get("p50"), v.get("p95"), v.get("max"), v.get("lost"), b.get("p50"), b.get("p95"), b.get("max")))
    for k in sorted(r["summary"]):
        if "vmb-" in k:
            v = r["summary"][k]
            print("%-62s p50=%-8s p95=%-8s max=%s" % (k, v.get("p50"), v.get("p95"), v.get("max")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
