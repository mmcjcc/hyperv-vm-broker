"""Structured results and errors (docs/design.md 5.4 and 5.5).

Every verb answers one JSON object: {"ok": true, "exit": 0, ...} or {"ok": false, "exit": N, "error": "<word>",
"findings": [...], "hint": "..."}. Never a stack trace, a secret value, or a host path outside <VMRoot>/vmb/.
"""
from . import schema as S


class BrokerError(Exception):
    """A refusal or failure with its exit code. str() is one printable line."""

    def __init__(self, exit_code, error, hint="", findings=()):
        super().__init__(hint or error)
        self.exit = int(exit_code)
        self.error = str(error)
        self.hint = printable(hint)
        self.findings = [printable(f) for f in findings]

    def result(self):
        r = {"ok": False, "exit": self.exit, "error": self.error}
        if self.hint:
            r["hint"] = self.hint
        if self.findings:
            r["findings"] = list(self.findings)
        return r


def printable(text, limit=400):
    """One line of printable ASCII, at most limit characters; nothing a terminal would interpret."""
    s = "".join(ch if 0x20 <= ord(ch) <= 0x7E else " " for ch in str(text))
    return s if len(s) <= limit else s[:limit - 3] + "..."


def ok(**fields):
    r = {"ok": True, "exit": S.EXIT_OK}
    r.update(fields)
    return r


def rejected(hint, findings=(), error="rejected"):
    return BrokerError(S.EXIT_REJECTED, error, hint, findings).result()


def not_in_stage(what, stage=S.CURRENT_STAGE):
    return rejected("%s: not in %s" % (what, stage), error="not-in-stage")
