"""Human-cadence typing (/type) and key chords (/key).

Typing: each character is followed by a delay of 1/cps x (1 + u), u uniform in [-jitter, +jitter]; an extra 150-350 ms
after any of . , ; : ! ?; a 300-600 ms pause before every Enter. "\\n" presses Enter, "\\t" Tab, every other character
(any Unicode, astral ones as surrogate pairs) goes through KEYEVENTF_UNICODE. With typing mode "layout", characters
the keyboard layout has a key for are pressed as that key (with Shift when needed) instead; the rest stay Unicode.

Chords: "ctrl+shift+p", "win+r", "alt+f4", "enter"; several chords in one combo are separated by spaces
("ctrl+k ctrl+s"). Modifiers: ctrl, shift, alt, win. Keys: letters, digits, f1-f24, enter, esc, tab, space, backspace,
del, ins, home, end, pgup, pgdn, arrows, apps, and the US punctuation keys (` - = [ ] \\ ; ' , . /, plus "plus" and
"minus"). Anything else is refused with a message that names the token; so are ctrl+alt+del (software cannot
send it: a human step) and win+l (it would lock the desktop). Keys are released in reverse order; a release that
fails does not stop the other releases, and is then raised as input-blocked ("keys may be held").

Stopping early (InputStopped): with a deadline (a time on the injected clock), typing checks it before every
character and a key sequence before every chord; with a target window, typing checks before every character that
the desktop's foreground window is still the target. Either stop ends the action at once, before the next
character, and never presses the final Enter; the answer says how many characters (or chords) were done.

Randomness, sleeping and the clock are injected, so tests are deterministic and never sleep.
"""

from __future__ import annotations

import random
import time
from typing import Callable

from .desktop import Desktop, DesktopError, InputStopped  # noqa: F401  (InputStopped: also imported from here)

VK_BACK = 0x08
VK_TAB = 0x09
VK_RETURN = 0x0D
VK_SHIFT = 0x10
VK_CONTROL = 0x11
VK_MENU = 0x12
VK_ESCAPE = 0x1B
VK_SPACE = 0x20
VK_LWIN = 0x5B
VK_DELETE = 0x2E

MODIFIERS = {
    "ctrl": VK_CONTROL,
    "control": VK_CONTROL,
    "shift": VK_SHIFT,
    "alt": VK_MENU,
    "win": VK_LWIN,
}

NAMED_KEYS = {
    "enter": VK_RETURN,
    "return": VK_RETURN,
    "esc": VK_ESCAPE,
    "escape": VK_ESCAPE,
    "tab": VK_TAB,
    "space": VK_SPACE,
    "backspace": VK_BACK,
    "del": VK_DELETE,
    "delete": VK_DELETE,
    "ins": 0x2D,
    "insert": 0x2D,
    "home": 0x24,
    "end": 0x23,
    "pgup": 0x21,
    "pageup": 0x21,
    "pgdn": 0x22,
    "pagedown": 0x22,
    "left": 0x25,
    "up": 0x26,
    "right": 0x27,
    "down": 0x28,
    "apps": 0x5D,
    "menu": 0x5D,
    # US-layout punctuation keys (the VM is English (US))
    ";": 0xBA,
    "=": 0xBB,
    "plus": 0xBB,
    ",": 0xBC,
    "-": 0xBD,
    "minus": 0xBD,
    ".": 0xBE,
    "/": 0xBF,
    "`": 0xC0,
    "[": 0xDB,
    "\\": 0xDC,
    "]": 0xDD,
    "'": 0xDE,
}
for _n in range(1, 25):
    NAMED_KEYS[f"f{_n}"] = 0x70 + _n - 1
for _c in "abcdefghijklmnopqrstuvwxyz":
    NAMED_KEYS[_c] = ord(_c.upper())
for _c in "0123456789":
    NAMED_KEYS[_c] = ord(_c)
del _n, _c

PUNCTUATION = frozenset(".,;:!?")
PUNCT_PAUSE = (0.150, 0.350)
ENTER_PAUSE = (0.300, 0.600)
CHORD_GAP = (0.020, 0.045)    # between the down and up events of one chord
REPEAT_GAP = (0.080, 0.160)   # between chords
MAX_COMBO_CHARS = 200


class ComboError(ValueError):
    """A combo that cannot be parsed; the message says which token and why."""


def parse_combo(combo: str) -> list[tuple[int, ...]]:
    """Parse a combo into chords; each chord is a tuple of virtual keys, modifiers first, in press order."""
    if not isinstance(combo, str):
        raise ComboError("combo must be a string")
    if len(combo) > MAX_COMBO_CHARS:
        raise ComboError(f"combo is longer than {MAX_COMBO_CHARS} characters")
    words = combo.split()
    if not words:
        raise ComboError("combo is empty")
    chords = []
    for word in words:
        tokens = word.lower().split("+")
        if any(t == "" for t in tokens):
            raise ComboError(f"empty key name in {word!r} (write the + key as 'plus' and the - key as 'minus')")
        mods: list[str] = []
        for t in tokens[:-1]:
            if t not in MODIFIERS:
                if t in NAMED_KEYS:
                    raise ComboError(f"{t!r} in {word!r} is not a modifier; only the last key may be a non-modifier")
                raise ComboError(f"unknown key {t!r} in {word!r}")
            mods.append(t)
        last = tokens[-1]
        if last in MODIFIERS:
            mods.append(last)
            key = None
        elif last in NAMED_KEYS:
            key = NAMED_KEYS[last]
        else:
            raise ComboError(f"unknown key {last!r} in {word!r}")
        vks = [MODIFIERS[m] for m in mods]
        if len(set(vks)) != len(vks):
            raise ComboError(f"a modifier appears twice in {word!r}")
        if set(vks) >= {VK_CONTROL, VK_MENU} and key == VK_DELETE:
            raise ComboError("ctrl+alt+del cannot be sent by software; it is a human step (vm_console)")
        if VK_LWIN in vks and key == ord("L"):
            raise ComboError("win+l would lock the desktop (the recording would show the lock screen); refused")
        if key is not None:
            vks.append(key)
        chords.append(tuple(vks))
    return chords


def utf16_units(ch: str) -> list[int]:
    """The UTF-16 code units of one character (two for an astral character: a surrogate pair)."""
    data = ch.encode("utf-16-le", "surrogatepass")
    return [int.from_bytes(data[i:i + 2], "little") for i in range(0, len(data), 2)]


def normalize_text(text: str) -> str:
    """CR LF and lone CR become LF, so a pasted Windows text presses Enter once per line."""
    return text.replace("\r\n", "\n").replace("\r", "\n")


def bad_text_char(text: str) -> str | None:
    """The first character /type refuses (control characters other than tab, LF, CR), or None."""
    for ch in text:
        o = ord(ch)
        if ch in "\t\n\r":
            continue
        if o < 0x20 or o == 0x7F or 0x80 <= o < 0xA0:
            return ch
        if 0xD800 <= o <= 0xDFFF:   # a lone surrogate (JSON "\ud83d" without its pair)
            return ch
    return None


class Typist:
    """Types text and presses chords on a Desktop with human cadence."""

    def __init__(self, desktop: Desktop, rng: random.Random | None = None,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
                 layout: bool = False):
        self.desktop = desktop
        self.rng = rng or random.Random()
        self.sleep = sleep
        self.clock = clock
        self.layout = layout

    # -- low level ------------------------------------------------------------------------------------------
    def _tap(self, vk: int) -> None:
        self.chord((vk,))

    def _char(self, ch: str) -> None:
        if self.layout:
            hit = self.desktop.vk_for_char(ch)
            if hit is not None:
                vk, shift = hit
                self.chord((VK_SHIFT, vk) if shift else (vk,), gap=False)
                return
        self.desktop.send_unicode(ch)

    def _enter(self, check: Callable[[], None] | None = None) -> None:
        self.sleep(self.rng.uniform(*ENTER_PAUSE))
        if check is not None:   # after the pause, right before the key: a stop during the pause presses nothing
            check()
        self._tap(VK_RETURN)

    def _release(self, vks: list[int]) -> Exception | None:
        """Release `vks` in reverse order; every release is tried. Returns the first error, or None."""
        first = None
        for vk in reversed(vks):
            try:
                self.desktop.send_vk(vk, True)
            except Exception as e:   # keep releasing the others
                if first is None:
                    first = e
        return first

    def chord(self, vks: tuple[int, ...], gap: bool = True) -> None:
        """Press the keys in order (with a short pause after each when `gap`), release them in reverse. A press
        that fails: the keys already down are released and the press error is raised. A release that fails: the
        other keys are still released, then input-blocked is raised ("keys may be held")."""
        pressed: list[int] = []
        try:
            for vk in vks:
                self.desktop.send_vk(vk, False)
                pressed.append(vk)
                if gap:
                    self.sleep(self.rng.uniform(*CHORD_GAP))
        except BaseException:
            self._release(pressed)   # the press error is the one raised
            raise
        failed = self._release(pressed)
        if failed is not None:
            why = failed.detail if isinstance(failed, DesktopError) else type(failed).__name__
            raise DesktopError("input-blocked", f"a key release failed ({why}); keys may be held") from failed

    def _check(self, deadline: float | None, target: int | None, foreground: Callable[[], int] | None,
               done: int, total: int, start: float, unit: str) -> None:
        """Raise InputStopped when the deadline has passed or the target window lost the foreground."""
        if deadline is not None and self.clock() >= deadline:
            tail = "; stopped without Enter" if unit == "chars" else "; stopped"
            raise InputStopped("deadline", f"the relay's time for this step ran out after {done} of {total} "
                                           f"{'characters' if unit == 'chars' else 'chords'}{tail}",
                               **{unit: done, "seconds": round(self.clock() - start, 3)})
        if target is not None:
            fg = int(foreground() or 0)
            if fg != target:
                raise InputStopped("focus-lost", f"the target window lost the foreground (now {fg:#x}) after "
                                                 f"{done} of {total} characters; stopped without Enter",
                                   **{unit: done, "seconds": round(self.clock() - start, 3)})

    # -- endpoints ------------------------------------------------------------------------------------------
    def type_text(self, text: str, cps: float = 14, jitter: float = 0.35, enter: bool = False, *,
                  deadline: float | None = None, target: int | None = None,
                  foreground: Callable[[], int] | None = None) -> dict:
        """Type `text` (then Enter when `enter`). deadline: a time on the clock; target: a window handle that must
        stay the foreground window (`foreground`, default the desktop's, is asked before every character). Either
        stop raises InputStopped before the next character and never presses the final Enter."""
        start = self.clock()
        text = normalize_text(text)
        base = 1.0 / cps
        total = len(text)
        if target is not None and foreground is None:
            foreground = self.desktop.foreground
        guarded = deadline is not None or target is not None
        count = 0

        def check() -> None:
            if guarded:
                self._check(deadline, target, foreground, count, total, start, "chars")

        for ch in text:
            check()
            if ch == "\n":
                self._enter(check)
            elif ch == "\t":
                self._tap(VK_TAB)
            else:
                self._char(ch)
            count += 1
            self.sleep(base * (1.0 + self.rng.uniform(-jitter, jitter)))
            if ch in PUNCTUATION:
                self.sleep(self.rng.uniform(*PUNCT_PAUSE))
        if enter:
            check()
            self._enter(check)
        return {"chars": count, "seconds": round(self.clock() - start, 3)}

    def press(self, combo: str, repeat: int = 1, *, deadline: float | None = None) -> dict:
        """Press the combo's chords `repeat` times; with a deadline, checked before every chord."""
        start = self.clock()
        chords = parse_combo(combo)
        total = len(chords) * repeat
        n = 0
        for i in range(repeat):
            for vks in chords:
                if n:
                    self.sleep(self.rng.uniform(*REPEAT_GAP))
                if deadline is not None:
                    self._check(deadline, None, None, n, total, start, "chords")
                self.chord(vks)
                n += 1
        return {"chords": n}
