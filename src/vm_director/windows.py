"""Top-level windows: /wait_for (a title regex appears, or is gone) and finding a terminal window for /run_visible.

The regex is matched with re.search against the first 256 characters of the titles of visible top-level windows
(win32.py also leaves out cloaked ones: suspended Store apps, other virtual desktops). Polling every 250 ms on an
injected clock. A pattern that could backtrack for minutes is refused: Python's re holds the interpreter lock while it
matches, so one such pattern would stop every other request (typing, /health, markers) as well. Refused: a repeat
inside a repeat ("(a+)+", "(\\w+\\s?)*"), and backreferences and group conditionals ("\\1", "(?P=name)", "(?(1)...)").
"""

from __future__ import annotations

import re
import time
from typing import Callable

from .desktop import Desktop

try:   # the parser the re module itself uses (Python 3.11+); without it, a conservative textual check
    from re import _constants as _re_constants
    from re import _parser as _re_parser
except ImportError:   # pragma: no cover
    _re_parser = _re_constants = None

POLL_S = 0.25
MAX_PATTERN = 200
MAX_TITLE_MATCH = 256    # characters of each title the pattern sees
TERMINAL_CLASSES = ("CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass")   # Windows Terminal, conhost

NESTED = "must not put a repeat inside a repeat (such as (a+)+ or (\\w+\\s?)*): it can take exponential time"
BACKREF = "must not use backreferences or group conditionals (\\1, (?P=name), (?(1)...))"


def _parsed_problem(pattern: str) -> str | None:
    """Walk the parse tree: a repeat of more than one (+, *, {m,n} with n > 1) inside another, or a group
    reference."""
    c = _re_constants
    repeats = {c.MAX_REPEAT, c.MIN_REPEAT}
    if hasattr(c, "POSSESSIVE_REPEAT"):
        repeats.add(c.POSSESSIVE_REPEAT)
    refs = {c.GROUPREF, c.GROUPREF_EXISTS}
    atomic = getattr(c, "ATOMIC_GROUP", None)

    def walk(items, in_repeat: bool) -> str | None:
        for op, av in items:
            found = None
            if op in refs:
                return BACKREF
            if op in repeats:
                _lo, hi, item = av
                many = hi > 1
                if many and in_repeat:
                    return NESTED
                found = walk(item, in_repeat or many)
            elif op == c.SUBPATTERN:
                found = walk(av[-1], in_repeat)
            elif op == c.BRANCH:
                for alt in av[1]:
                    found = found or walk(alt, in_repeat)
            elif op in (c.ASSERT, c.ASSERT_NOT):
                found = walk(av[1], in_repeat)
            elif atomic is not None and op == atomic:
                found = walk(av, in_repeat)
            if found:
                return found
        return None

    return walk(_re_parser.parse(pattern), False)


def _quantifier_at(p: str, i: int) -> tuple[bool, int] | None:
    """A quantifier starting at p[i]: (repeats more than once, its length), or None."""
    if i >= len(p):
        return None
    ch = p[i]
    if ch in "*+?":
        n = 1 + (1 if p[i + 1:i + 2] in ("?", "+") else 0)
        return ch != "?", n
    if ch == "{":
        m = re.match(r"\{(\d*)(,(\d*))?\}", p[i:])
        if not m or (m.group(1) == "" and m.group(2) is None):
            return None   # a literal brace
        if m.group(2) is None:
            many = int(m.group(1)) > 1
        else:
            many = m.group(3) == "" or int(m.group(3)) > 1
        n = len(m.group(0))
        n += 1 if p[i + n:i + n + 1] in ("?", "+") else 0
        return many, n
    return None


def _textual_problem(pattern: str) -> str | None:
    """Conservative check without the parser: a group that holds a repeat and is itself repeated, or a
    backreference. It may refuse a harmless pattern; it does not let a nested repeat through."""
    stack = [False]   # per open group: does it hold a repeat
    i, n = 0, len(pattern)
    while i < n:
        ch = pattern[i]
        if ch == "\\":
            nxt = pattern[i + 1:i + 2]
            if nxt.isdigit() and nxt != "0":
                return BACKREF
            i += 2
            continue
        if ch == "[":   # a character class: skip to its end (a ']' first, or after '^', is a literal)
            j = i + 1
            if pattern[j:j + 1] == "^":
                j += 1
            if pattern[j:j + 1] == "]":
                j += 1
            while j < n and pattern[j] != "]":
                j += 2 if pattern[j] == "\\" else 1
            i = j + 1
            continue
        if ch == "(":
            if pattern.startswith("(?P=", i) or pattern.startswith("(?(", i):
                return BACKREF
            stack.append(False)
            i += 1
            if pattern[i:i + 1] == "?":   # (?:...), (?=...), (?i) ...: not a quantifier
                i += 1
            continue
        if ch == ")":
            inner = stack.pop() if len(stack) > 1 else False
            q = _quantifier_at(pattern, i + 1)
            if q and q[0] and inner:
                return NESTED
            if inner or (q and q[0]):
                stack[-1] = True
            i += 1 + (q[1] if q else 0)
            continue
        q = _quantifier_at(pattern, i)
        if q:
            if q[0]:
                stack[-1] = True
            i += q[1]
            continue
        i += 1
    return None


def pattern_problem(pattern: str) -> str | None:
    """Why `pattern` could take too long to match (a reason), or None. The pattern must compile."""
    if _re_parser is not None:
        try:
            return _parsed_problem(pattern)
        except Exception:   # an unexpected parser shape: fall back to the textual check
            pass
    return _textual_problem(pattern)


def compile_title(pattern: str) -> re.Pattern:
    """Compile a window-title regex; ValueError with a one-line reason when it is too long, invalid or could take
    exponential time."""
    if not isinstance(pattern, str) or not pattern:
        raise ValueError("window_title must be a non-empty string")
    if len(pattern) > MAX_PATTERN:
        raise ValueError(f"window_title is longer than {MAX_PATTERN} characters")
    try:
        rx = re.compile(pattern)
    except re.error as e:
        raise ValueError(f"window_title is not a valid regex: {e}") from None
    problem = pattern_problem(pattern)
    if problem:
        raise ValueError(f"window_title {problem}")
    return rx


def find_title(desktop: Desktop, rx: re.Pattern) -> tuple[int, str] | None:
    """The first visible window whose title (its first MAX_TITLE_MATCH characters) matches: (hwnd, full title)."""
    for hwnd, title, _cls in desktop.top_windows():
        if title and rx.search(title[:MAX_TITLE_MATCH]):
            return hwnd, title
    return None


def wait_for(desktop: Desktop, pattern: str, timeout_s: float = 30, gone: bool = False,
             clock: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep,
             poll_s: float = POLL_S) -> dict:
    """Wait until a window whose title matches exists (or, with gone, until none does).

    Returns {"ok": True, "found": True, "title", "waited_s"} when a window is there, {"ok": True, "found": False,
    "title": None, "waited_s"} when it is gone, and {"ok": False, "error": "timeout", "detail", "waited_s"}.
    """
    rx = compile_title(pattern)
    start = clock()
    while True:
        hit = find_title(desktop, rx)
        waited = round(clock() - start, 3)
        if hit and not gone:
            return {"ok": True, "found": True, "title": hit[1], "waited_s": waited}
        if not hit and gone:
            return {"ok": True, "found": False, "title": None, "waited_s": waited}
        remaining = timeout_s - (clock() - start)
        if remaining <= 0:
            what = "still there" if gone else "not found"
            return {"ok": False, "error": "timeout", "detail": f"window {what} after {waited} s",
                    "waited_s": waited}
        sleep(min(poll_s, remaining))


def find_terminal(desktop: Desktop) -> tuple[int, str, str] | None:
    """The topmost visible Windows Terminal or console window: (hwnd, title, class), or None."""
    for hwnd, title, cls in desktop.top_windows():
        if cls in TERMINAL_CLASSES:
            return hwnd, title, cls
    return None
