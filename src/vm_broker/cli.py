"""The vmb command line (entry point main()).

Verbs as in CONTRACT.md section 5: contract, whoami, profiles, capacity, plan, create, list, status, start, stop,
destroy (--confirm), extend, snapshot (--replace), restore, snapshots, snapshot-rm, run (--interactive, --timeout,
then "--" and the command), copy-to, copy-from, director, console, job, wait.

Prints the verb's JSON (or a short text form with --text) and exits with its exit code. Exception: run exits 0 when
the command ran; the command's own code is in exit_code, so a guest's exit 2 to 6 is never read as a broker answer.
Accepts v0's positional shorthand for the director's main payload field (vmb director lab-p1 record_start smoke.mkv).
The consumer name comes from vmbroker/consumer at the repo root (client.py), never from a flag.
"""
import argparse
import json
import sys

from . import schema as S


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        print(json.dumps({"ok": False, "exit": S.EXIT_REJECTED, "error": "usage", "hint": message}), file=sys.stderr)
        sys.exit(S.EXIT_REJECTED)


def build_parser():
    p = _Parser(prog="vmb", description="vm-broker: VMs on the operator's Hyper-V hosts (CONTRACT.md)")
    p.add_argument("--text", action="store_true", help="short text instead of JSON")
    sub = p.add_subparsers(dest="verb", required=True)
    for v in ("contract", "whoami", "profiles", "capacity", "list"):
        sub.add_parser(v)
    for v in ("plan", "create"):
        s = sub.add_parser(v)
        s.add_argument("request")
        if v == "create":
            s.add_argument("--wait", type=int, dest="wait_s")
    s = sub.add_parser("status"); s.add_argument("vm"); s.add_argument("--director", action="store_true")
    s = sub.add_parser("start"); s.add_argument("vm")
    s = sub.add_parser("stop"); s.add_argument("vm"); s.add_argument("--force", action="store_true"); s.add_argument("--wait", type=int, dest="wait_s")
    s = sub.add_parser("destroy"); s.add_argument("vm"); s.add_argument("--confirm", required=True)
    s = sub.add_parser("extend"); s.add_argument("vm"); s.add_argument("days", type=int)
    s = sub.add_parser("snapshot"); s.add_argument("vm"); s.add_argument("label"); s.add_argument("--replace", action="store_true"); s.add_argument("--wait", type=int, dest="wait_s")
    s = sub.add_parser("restore"); s.add_argument("vm"); s.add_argument("label"); s.add_argument("--wait", type=int, dest="wait_s")
    s = sub.add_parser("snapshots"); s.add_argument("vm")
    s = sub.add_parser("snapshot-rm"); s.add_argument("vm"); s.add_argument("label")
    s = sub.add_parser("run"); s.add_argument("vm"); s.add_argument("--interactive", action="store_true")
    s.add_argument("--timeout", type=int, default=S.RUN_TIMEOUT_DEFAULT_S, dest="timeout_s")
    s.add_argument("--file", dest="command_file",
                   help="read the command from this local file (UTF-8; inside the project or VMB_OUT_DIR)")
    s.add_argument("command", nargs="*")      # main() hands it everything after "--"
    s = sub.add_parser("copy-to"); s.add_argument("vm"); s.add_argument("local"); s.add_argument("guest"); s.add_argument("--overwrite", action="store_true")
    s = sub.add_parser("copy-from"); s.add_argument("vm"); s.add_argument("guest"); s.add_argument("local", nargs="?")
    s.add_argument("--overwrite", action="store_true")
    s = sub.add_parser("director"); s.add_argument("vm"); s.add_argument("action"); s.add_argument("payload", nargs="?")
    s = sub.add_parser("console"); s.add_argument("vm")
    s = sub.add_parser("job"); s.add_argument("job")
    s = sub.add_parser("wait"); s.add_argument("job"); s.add_argument("--timeout", type=int, dest="wait_s")
    return p


def director_payload(action, text):
    """A JSON object, or v0's shorthand for the action's main field."""
    if text is None:
        return None
    t = text.strip()
    if t.startswith("{"):
        try:
            v = json.loads(t)
        except ValueError as e:
            raise ValueError("payload: not valid JSON (%s)" % e.msg)
        if not isinstance(v, dict):
            raise ValueError("payload: a JSON object")
        return v
    field = S.DIRECTOR_SHORTHAND.get(action)
    if not field:
        raise ValueError("payload: %s takes a JSON object" % action)
    return {field: text}


def dispatch(b, a):
    v = a.verb
    if v == "contract": return b.contract()
    if v == "whoami": return b.whoami()
    if v == "profiles": return b.profiles()
    if v == "capacity": return b.capacity()
    if v == "list": return b.list()
    if v == "plan": return b.plan(a.request)
    if v == "create": return b.create(a.request, wait_s=a.wait_s)
    if v == "status": return b.status(a.vm, director=a.director)
    if v == "start": return b.start(a.vm)
    if v == "stop": return b.stop(a.vm, force=a.force, wait_s=a.wait_s)
    if v == "destroy": return b.destroy(a.vm, a.confirm)
    if v == "extend": return b.extend(a.vm, a.days)
    if v == "snapshot": return b.snapshot(a.vm, a.label, replace=a.replace, wait_s=a.wait_s)
    if v == "restore": return b.restore(a.vm, a.label, wait_s=a.wait_s)
    if v == "snapshots": return b.list_snapshots(a.vm)
    if v == "snapshot-rm": return b.delete_snapshot(a.vm, a.label)
    if v == "run":
        command = " ".join(a.command)
        if a.command_file:
            if command:
                return {"ok": False, "exit": S.EXIT_REJECTED, "error": "usage", "hint": "give --file or a command after --, not both"}
            src, err = b.local_source(a.command_file, "--file")
            if err:
                return err
            try:
                with open(src, "r", encoding="utf-8-sig") as fh:
                    command = fh.read(S.RUN_COMMAND_MAX_BYTES + 1)
            except (OSError, UnicodeDecodeError) as e:
                return {"ok": False, "exit": S.EXIT_REJECTED, "error": "usage",
                        "hint": "--file: %s" % (getattr(e, "strerror", None) or "not UTF-8 text")}
        return b.run(a.vm, command, interactive=a.interactive, timeout_s=a.timeout_s)
    if v == "copy-to": return b.copy_to(a.vm, a.local, a.guest, overwrite=a.overwrite)
    if v == "copy-from": return b.copy_from(a.vm, a.guest, a.local, overwrite=a.overwrite)
    if v == "director":
        try:
            payload = director_payload(a.action, a.payload)
        except ValueError as e:
            return {"ok": False, "exit": S.EXIT_REJECTED, "error": "rejected", "hint": str(e)}
        return b.director(a.vm, a.action, payload)
    if v == "console": return b.console(a.vm)
    if v == "job": return b.job_status(a.job)
    if v == "wait": return b.job_wait(a.job, wait_s=a.wait_s)
    return {"ok": False, "exit": S.EXIT_REJECTED, "error": "usage", "hint": "unknown verb"}


def as_text(r):
    lines = []
    head = "ok" if r.get("ok") else "%s (exit %s)" % (r.get("error", "failed"), r.get("exit"))
    lines.append(head)
    for k in ("hint", "vm", "state", "job", "console", "addresses", "decision", "exit_code", "local", "png_path"):
        if r.get(k) not in (None, "", []):
            lines.append("%s: %s" % (k, r[k]))
    for f in r.get("findings") or []:
        lines.append("  - %s" % f)
    if isinstance(r.get("stdout"), str) and r["stdout"]:
        lines.append(r["stdout"].rstrip("\n"))
    if isinstance(r.get("stderr"), str) and r["stderr"]:
        lines.append(r["stderr"].rstrip("\n"))
    return "\n".join(lines)


def main(argv=None, broker=None, out=None):
    out = out or sys.stdout
    argv = list(sys.argv[1:] if argv is None else argv)
    cut = argv.index("--") if "--" in argv else len(argv)
    text = "--text" in argv[:cut]
    argv = [x for i, x in enumerate(argv) if not (i < cut and x == "--text")]
    # run: everything after "--" is the command, whatever it looks like; options go before it
    command = None
    if "run" in argv[:cut] and "--" in argv:
        cut = argv.index("--")
        command, argv = argv[cut + 1:], argv[:cut]
    a = build_parser().parse_args(argv)
    a.text = a.text or text
    if command is not None:
        a.command = command
    if broker is None:
        from .client import make_broker
        broker = make_broker()
    try:
        r = dispatch(broker, a)
    except KeyboardInterrupt:
        r = {"ok": False, "exit": S.EXIT_FAILED, "error": "interrupted",
             "hint": "stopped waiting; a job keeps running on the host (vmb job <id>)"}
    if a.verb == "contract" and r.get("ok") and a.text:
        out.write("contract %s, vm-broker %s, stage %s, commit %s\n\n%s" % (
            r.get("contract"), r.get("version"), r.get("stage"), (r.get("commit") or "unknown")[:12], r.get("text", "")))
        return 0
    out.write((as_text(r) if a.text else json.dumps(r, indent=1, sort_keys=True)) + "\n")
    if a.verb == "run" and r.get("ok"):
        return 0
    return int(r.get("exit", S.EXIT_FAILED))


if __name__ == "__main__":
    sys.exit(main())
