"""vmb-admin: the operator's verbs (entry point main()); docs/design.md 5.2.

v0.R has: activate (the recording VM's one MAK activation, section 9), password (a generated guest password, shown
on this terminal only), job-cancel, list and status of every broker VM. The rest of 5.2 comes with v0.1 and v1.

Refuses to run without a TTY (an agent's shell has none). The MAK is read at a no-echo prompt, from --key-file (its
first line), or with --key-from-config from a config file that holds it among other lines (netadmin's config.txt by
default): this process finds the 5x5 product keys in that file, shows only each one's line number and the name in
front of it, and asks which to use. The file is read here, on the operator's terminal, never by a Claude session. The key
travels only inside the runner's stdin envelope to the host and on into the guest as an argument; nothing here
prints, logs or stores it. Never an MCP tool.
"""
import argparse
import getpass
import json
import re
import sys

from . import schema as S

KEY_RE = re.compile(r"[A-Z0-9]{5}(-[A-Z0-9]{5}){4}")
NETADMIN_CONFIG = r"C:\src\netadmin\config.txt"
# a 5x5 key standing on its own in a line, and the name just in front of it ("WIN2025_MAK=", "mak:"): one token only,
# so whatever else sits earlier on that line (a password, say) is never shown
_KEY_IN_LINE = re.compile(r"(?<![A-Za-z0-9-])([A-Za-z0-9]{5}(?:-[A-Za-z0-9]{5}){4})(?![A-Za-z0-9-])")
_LABEL = re.compile(r"([A-Za-z][A-Za-z0-9_.-]{0,29})\s*[:=]?\s*[\"']?\s*$")
# Microsoft's published client keys (GVLK, AVMA) for Server 2025: never the MAK
PUBLIC_KEYS = frozenset({"TVRH6-WHNXV-R9WG3-9XRFY-MY832", "D764K-2NDRG-47T6Q-P8T8W-YP6DF",
                         "XGN3F-F394H-FD2MY-PP6FD-8MCRC", "YQB4H-NKHHJ-Q6K4R-4VMY6-VCH67",
                         "WWVGQ-PNHV9-B89P4-8GGM9-9HPQ4", "6NMQ9-T38WF-6MFGM-QYGYM-88J4F"})


def find_keys(path):
    """The product keys in a config file, as (line number, label, key), public client keys left out. Callers show
    only the line number and the label, never the key. The first line (netadmin's user and password) gets no label."""
    found = []
    with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            for m in _KEY_IN_LINE.finditer(line):
                key = m.group(1).upper()
                if key in PUBLIC_KEYS:
                    continue
                lm = _LABEL.search(line[:m.start()]) if n > 1 else None
                found.append((n, lm.group(1) if lm else "", key))
    return found


def key_from_config(path, ask=input, say=print):
    """The one key the operator picks from a config file; ValueError when there is none or the operator does not confirm."""
    found = find_keys(path)
    if not found:
        raise ValueError("no product key found in %s" % path)
    shown = ["line %d%s" % (n, " (%s)" % label if label else "") for n, label, _key in found]
    if len(found) == 1:
        if ask("Use the key on %s of %s? [y/N] " % (shown[0], path)).strip().lower() not in ("y", "yes"):
            raise ValueError("not confirmed")
        return found[0][2]
    say("Product keys in %s (the keys themselves are not shown):" % path)
    for i, s in enumerate(shown, 1):
        say("  %d. %s" % (i, s))
    choice = ask("Which one is the Server 2025 MAK (1-%d)? " % len(found)).strip()
    if not choice.isdigit() or not 1 <= int(choice) <= len(found):
        raise ValueError("no key chosen")
    return found[int(choice) - 1][2]


def _tty():
    try:
        return sys.stdin.isatty() and sys.stdout.isatty()
    except (AttributeError, ValueError):
        return False


def _backend():
    from .backend.hyperv import HyperVBackend
    from .client import load_settings
    s = load_settings()
    return HyperVBackend(s["loader"]), (s["hosts"] or ["servera"])[0]


def _print(r):
    print(json.dumps(r, indent=1, sort_keys=True))
    return int(r.get("exit", 1))


def read_key(key_file=None):
    if key_file:
        with open(key_file, "r", encoding="utf-8-sig") as fh:
            key = fh.readline().strip().upper()
    else:
        key = getpass.getpass("Server 2025 MAK (not shown): ").strip().upper()
    if not KEY_RE.fullmatch(key):
        raise ValueError("that is not a 5x5 product key")
    return key


def main(argv=None):
    p = argparse.ArgumentParser(prog="vmb-admin", description="The operator's vm-broker verbs (v0.R subset)")
    sub = p.add_subparsers(dest="verb", required=True)
    s = sub.add_parser("activate", help="the recording VM's one MAK activation")
    s.add_argument("vm")
    src = s.add_mutually_exclusive_group()
    src.add_argument("--key-file", help="a file whose first line is the MAK")
    src.add_argument("--key-from-config", nargs="?", const=NETADMIN_CONFIG, metavar="PATH",
                     help="find the MAK among the lines of a config file (default: netadmin's config.txt); you pick it "
                          "by line and name, the key is never shown")
    s = sub.add_parser("password", help="show a generated guest password on this terminal")
    s.add_argument("vm"); s.add_argument("user", choices=("vmbadmin", "student", "administrator"))
    s = sub.add_parser("job-cancel"); s.add_argument("job")
    sub.add_parser("list")
    s = sub.add_parser("status"); s.add_argument("vm")
    a = p.parse_args(argv)
    if not _tty():
        print("vmb-admin needs a terminal (the operator only); it refuses to run without one", file=sys.stderr)
        return S.EXIT_REJECTED
    be, host = _backend()
    if a.verb == "activate":
        if not S.NAME_RE.fullmatch(a.vm):
            print("bad VM name", file=sys.stderr)
            return S.EXIT_REJECTED
        print("This uses one activation of the MAK, for good. VM: %s (Hyper-V name vmb-%s) on %s." % (a.vm, a.vm, host))
        # either name confirms: the prompt showed the Hyper-V name while only the broker name was accepted (2026-10-11)
        if input("Type %s to go on: " % a.vm).strip() not in (a.vm, "vmb-" + a.vm):
            print("not confirmed; nothing changed")
            return S.EXIT_REJECTED
        try:
            key = key_from_config(a.key_from_config) if a.key_from_config else read_key(a.key_file)
            if not KEY_RE.fullmatch(key):
                raise ValueError("that is not a 5x5 product key")
        except (OSError, ValueError) as e:
            print("key: %s" % (e.strerror if isinstance(e, OSError) and e.strerror else e), file=sys.stderr)
            return S.EXIT_REJECTED
        r = be.call(host, "activate", {"name": a.vm, "mode": "mak", "key": key}, timeout_s=900)
        key = None
        code = _print(r)
        if r.get("ok") and r.get("permanent"):
            print("Activated permanently. The watermark goes at the next sign-in; the session takes the golden checkpoint next.")
        elif r.get("ok"):
            print("Not permanently activated: %s. Nothing was retried; tell the session." % r.get("error"))
        return code
    if a.verb == "password":
        r = be.call(host, "password", {"name": a.vm, "user": a.user})
        if r.get("ok"):
            print("%s: %s" % (r.get("user"), r.get("password")))
            return 0
        return _print(r)
    if a.verb == "job-cancel":
        return _print(be.call(host, "job-cancel", {"job": a.job}))
    if a.verb == "list":
        return _print(be.call(host, "list", {"consumer": "*admin*"}))
    if a.verb == "status":
        return _print(be.call(host, "status", {"consumer": "*admin*", "name": a.vm, "director": True}))
    return S.EXIT_REJECTED


if __name__ == "__main__":
    sys.exit(main())
