"""The director's endpoints: payload in (a dict), result out (a dict with "ok").

Input actions (/type, /key, /click, /run_visible) run one at a time under one lock; a call that cannot get it within
30 s gets error "busy". /wait_for, /screenshot, /health and the recording endpoints do not take it.

Deadline: the server passes one when the request carries "X-Vmb-Timeout: <seconds>" (the relay's timeout for the
step): the request's start plus that, less 2 s, on this Director's clock. An input action never starts after it: if
the input lock comes free only after the deadline (or not before it), the action does nothing and answers error
"deadline". /type, /key and /run_visible check it again before every character or chord and stop there (no Enter);
the answer then carries chars (or chords) done so far. /click checks it before the cursor moves, between the steps of
its path, before the button goes down and before the second click of a double click; stopped, it presses no (more)
button and the answer carries moved and clicks. /record/start waits for ffmpeg's first frame (at most 45 s) only as
long as the deadline allows. Without the header there is no deadline.

/run_visible types into the terminal window it focused and checks before every character that this window still has
the foreground; when another window took it, typing stops without Enter: error "focus-lost", with chars done.

After an input error or a stop, and at director start (on_start), every modifier key still down is released.

Errors come back as {"ok": false, "error": "<word>", "detail": "<one line>"}: bad-request (payload), busy, deadline,
focus-lost, input-blocked, desktop-unavailable, capture-failed, launch-failed, no-terminal, focus-failed, timeout, and
for recording bad-resolution, bad-scaling, low-disk, no-ffmpeg, already-recording, file-exists, out-not-writable,
ffmpeg-failed, no-first-frame, ended-early, not-recording, not-ready. The server adds internal (an unexpected
exception; the log says where).
"""

from __future__ import annotations

import base64
import contextlib
import os
import random
import shutil
import threading
import time
from typing import Callable

from . import VERSION
from .desktop import Desktop, DesktopError
from .keys import ComboError, InputStopped, Typist, bad_text_char, parse_combo
from .mouse import BUTTONS, Mouse
from .payload import BadRequest, Bool, Int, Num, Str, validate
from .png import encode_png
from .record import PRESETS, Recorder, RecordError, filename_problem
from .windows import POLL_S, compile_title, find_terminal, wait_for

GIB = 1024 ** 3
MIN_FREE_BYTES = 2 * GIB
REQUIRED_SIZE = (1920, 1080)
REQUIRED_SCALING = 100
INPUT_LOCK_TIMEOUT_S = 30.0
LAUNCH_WAIT_S = 90.0     # a cold Windows Terminal start behind the disk cap took 25 s to its shell (2026-10-11)
SHELL_READY_MAX_S = 60.0
SHELL_MIN_CPU_S = 0.3    # CPU seconds the new shells must have used before quiet counts (5.1 uses well over that)
SHELL_QUIET_S = 2.0      # then this long without CPU time or page faults: the new shell is waiting for keys
SHELL_CPU_EPS_S = 0.035  # CPU seconds per poll that still count as quiet (about two scheduler ticks)
SHELL_FAULTS_EPS = 5     # page faults per poll that still count as quiet
LAUNCH_SETTLE_S = 1.5    # when the shell's state is not known: a new terminal's shell needs a moment
FOCUS_SETTLE_S = 0.3


class ActionError(Exception):
    def __init__(self, word: str, detail: str):
        super().__init__(detail)
        self.word = word
        self.detail = detail


def _text_check(value: str) -> str | None:
    ch = bad_text_char(value)
    if ch is None:
        return None
    return f"contains the control character U+{ord(ch):04X} (only tab and newline are typed)"


def _label_check(value: str) -> str | None:
    return None if value.isprintable() else "must be printable characters only"


def _combo_check(value: str) -> str | None:
    try:
        parse_combo(value)
    except ComboError as e:
        return str(e)
    return None


def _title_check(value: str) -> str | None:
    try:
        compile_title(value)
    except ValueError as e:
        return str(e)
    return None


FIELDS = {
    "/health": {},
    "/type": {"text": Str(hi=8192, check=_text_check), "cps": Num(14, 1, 60), "jitter": Num(0.35, 0, 0.9),
              "enter": Bool(False)},
    "/key": {"combo": Str(lo=1, hi=200, check=_combo_check), "repeat": Int(1, 1, 100)},
    "/click": {"x": Int(), "y": Int(), "button": Str("left", choices=BUTTONS), "double": Bool(False),
               "move_ms": Int(400, 0, 5000)},
    "/wait_for": {"window_title": Str(lo=1, hi=200, check=_title_check), "timeout_s": Num(30, 1, 600),
                  "gone": Bool(False)},
    "/screenshot": {},
    "/record/start": {"filename": Str(check=filename_problem), "fps": Int(30, 5, 60), "crf": Int(20, 0, 51),
                      "preset": Str("ultrafast", choices=PRESETS)},
    "/record/stop": {},
    "/marker": {"label": Str(lo=1, hi=100, check=_label_check)},
    "/run_visible": {"command": Str(lo=1, hi=4096, check=_text_check)},
}


class Director:
    def __init__(self, root: str, desktop: Desktop, *, recorder: Recorder | None = None,
                 rng: random.Random | None = None, sleep: Callable[[float], None] = time.sleep,
                 clock: Callable[[], float] = time.monotonic,
                 which: Callable = shutil.which, environ: dict | None = None,
                 isfile: Callable[[str], bool] = os.path.isfile,
                 typing_mode: str = "unicode", input_lock_timeout_s: float = INPUT_LOCK_TIMEOUT_S):
        if typing_mode not in ("unicode", "layout"):
            raise ValueError("typing_mode must be unicode or layout")
        self.root = root
        self.out_dir = os.path.join(root, "out")
        self.desktop = desktop
        self.sleep = sleep
        self.clock = clock
        self.which = which
        self.environ = os.environ if environ is None else environ
        self.isfile = isfile
        self.typing_mode = typing_mode
        self.recorder = recorder or Recorder(root, clock=clock, on_spawn=desktop.contain_child)
        rng = rng or random.Random()
        self.typist = Typist(desktop, rng, sleep, clock, layout=typing_mode == "layout")
        self.mouse = Mouse(desktop, rng, sleep, clock)
        self.input_lock = threading.Lock()
        self.input_lock_timeout_s = input_lock_timeout_s
        self.routes: dict[str, Callable[..., dict]] = {
            "/health": self.health,
            "/type": self.type_,
            "/key": self.key,
            "/click": self.click,
            "/wait_for": self.wait_for,
            "/screenshot": self.screenshot,
            "/record/start": self.record_start,
            "/record/stop": self.record_stop,
            "/marker": self.marker,
            "/run_visible": self.run_visible,
        }

    # -- plumbing -------------------------------------------------------------------------------------------
    def handle(self, path: str, payload, deadline: float | None = None) -> dict:
        """Run one endpoint. deadline: a time on self.clock after which input actions do no more (None: none).
        Known failures become {"ok": false, ...}; anything else propagates (the server turns it into error
        "internal" without a stack trace)."""
        try:
            values = validate(payload, FIELDS[path])
            return self.routes[path](values, deadline=deadline)
        except BadRequest as e:
            return {"ok": False, "error": "bad-request", "detail": e.detail}
        except InputStopped as e:
            return {"ok": False, "error": e.word, "detail": e.detail, **e.extra}
        except (ActionError, DesktopError, RecordError) as e:
            return {"ok": False, "error": e.word, "detail": e.detail}

    def on_start(self) -> list[int]:
        """At director start: release the modifier keys still down (a director killed in the middle of a chord
        leaves them so). Returns the virtual keys released."""
        return self._release_modifiers()

    def _release_modifiers(self) -> list[int]:
        try:
            return list(self.desktop.release_modifiers() or [])
        except Exception:   # never hide the error that brought us here
            return []

    @contextlib.contextmanager
    def _input(self, deadline: float | None = None):
        """The input lock, for one input action. With a deadline: wait for the lock at most until the deadline,
        and do nothing (error deadline) when it is free only after it. An exception from the action releases the
        modifier keys that are still down before the lock is released."""
        wait = self.input_lock_timeout_s
        cut = False
        if deadline is not None:
            left = deadline - self.clock()
            if left < wait:
                wait, cut = max(0.0, left), True
        if not self.input_lock.acquire(timeout=wait):
            if cut:
                raise ActionError("deadline", "the relay's time for this step ran out while another input action "
                                              "ran; nothing was done")
            raise ActionError("busy", "another input action is still running")
        if deadline is not None and self.clock() >= deadline:
            self.input_lock.release()
            raise ActionError("deadline", "the relay's time for this step ran out before the input lock was free; "
                                          "nothing was done")
        try:
            yield
        except BaseException:
            self._release_modifiers()
            raise
        finally:
            self.input_lock.release()

    def _free_bytes(self) -> int | None:
        try:
            return int(self.desktop.free_bytes(self.out_dir))
        except OSError:
            return None

    def _scaling(self) -> int:
        return round(self.desktop.dpi() * 100 / 96)

    # -- endpoints ------------------------------------------------------------------------------------------
    def health(self, v: dict, deadline: float | None = None) -> dict:
        w, h = self.desktop.screen_size()
        free = self._free_bytes()
        return {
            "ok": True,
            "version": VERSION,
            "session_id": self.desktop.session_id(),
            "user": self.desktop.user(),
            "width": w,
            "height": h,
            "resolution": f"{w}x{h}",
            "scaling": self._scaling(),
            "recording": self.recorder.status(),
            "ffmpeg": self.recorder.ffmpeg_present(),
            "free_gb": None if free is None else round(free / GIB, 1),
            "typing": self.typing_mode,
        }

    def type_(self, v: dict, deadline: float | None = None) -> dict:
        with self._input(deadline):
            r = self.typist.type_text(v["text"], v["cps"], v["jitter"], v["enter"], deadline=deadline)
        return {"ok": True, **r}

    def key(self, v: dict, deadline: float | None = None) -> dict:
        with self._input(deadline):
            r = self.typist.press(v["combo"], v["repeat"], deadline=deadline)
        return {"ok": True, **r}

    def click(self, v: dict, deadline: float | None = None) -> dict:
        w, h = self.desktop.screen_size()
        if not (0 <= v["x"] < w and 0 <= v["y"] < h):
            raise BadRequest(f"x and y must be inside the screen (0..{w - 1}, 0..{h - 1})")
        with self._input(deadline):
            r = self.mouse.click(v["x"], v["y"], v["button"], v["double"], v["move_ms"], deadline=deadline)
        return {"ok": True, **r}

    def wait_for(self, v: dict, deadline: float | None = None) -> dict:
        return wait_for(self.desktop, v["window_title"], v["timeout_s"], v["gone"], self.clock, self.sleep)

    def screenshot(self, v: dict, deadline: float | None = None) -> dict:
        w, h, bgra = self.desktop.capture()
        data = encode_png(w, h, bgra)
        return {"ok": True, "width": w, "height": h, "png_b64": base64.b64encode(data).decode("ascii")}

    def record_start(self, v: dict, deadline: float | None = None) -> dict:
        w, h = self.desktop.screen_size()
        if (w, h) != REQUIRED_SIZE:
            raise ActionError("bad-resolution", f"the desktop is {w}x{h}; recording needs 1920x1080")
        scaling = self._scaling()
        if scaling != REQUIRED_SCALING:
            raise ActionError("bad-scaling", f"display scaling is {scaling} %; recording needs 100 %")
        free = self._free_bytes()
        if free is None or free < MIN_FREE_BYTES:
            shown = "unknown" if free is None else f"{free / GIB:.1f} GB"
            raise ActionError("low-disk", f"free space on the out folder's drive is {shown}; recording needs 2 GB")
        if not self.recorder.ffmpeg_present():
            raise ActionError("no-ffmpeg", "bin\\ffmpeg.exe is missing")
        r = self.recorder.start(v["filename"], v["fps"], v["crf"], v["preset"], deadline=deadline)
        return {"ok": True, **r}

    def record_stop(self, v: dict, deadline: float | None = None) -> dict:
        return self.recorder.stop()

    def marker(self, v: dict, deadline: float | None = None) -> dict:
        r = self.recorder.marker(v["label"])
        return {"ok": True, **r}

    # -- run_visible ----------------------------------------------------------------------------------------
    def terminal_argv(self) -> tuple[list[str], bool]:
        """Windows Terminal if it is there, else Windows PowerShell in a console of its own."""
        wt = self.which("wt.exe")
        if not wt:
            local = self.environ.get("LOCALAPPDATA")
            if local:
                candidate = os.path.join(local, "Microsoft", "WindowsApps", "wt.exe")
                if self.isfile(candidate):
                    wt = candidate
        if wt:
            return [wt], False
        ps = self.which("powershell.exe")
        if not ps:
            system_root = self.environ.get("SystemRoot") or self.environ.get("SYSTEMROOT") or r"C:\Windows"
            ps = os.path.join(system_root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        return [ps], True

    def _wait_terminal(self, timeout_s: float):
        start = self.clock()
        while True:
            term = find_terminal(self.desktop)
            if term is not None:
                return term
            remaining = timeout_s - (self.clock() - start)
            if remaining <= 0:
                return None
            self.sleep(min(POLL_S, remaining))

    def _new_shells(self, before: set) -> tuple[int, float, int] | None:
        """(count, CPU seconds, page faults) summed over the shells whose keys are not in `before`."""
        procs = self.desktop.shell_processes()
        if procs is None:
            return None
        new = [v for k, v in procs.items() if k not in before]
        return len(new), sum(cpu for cpu, _f in new), sum(f for _cpu, f in new)

    def _wait_shell(self, before: set, timeout_s: float) -> tuple[str, float]:
        """Wait until the shells that were not running before the launch (keys not in `before`) have done real
        work (SHELL_MIN_CPU_S of CPU between them) and then sit idle: no CPU time and no page faults for
        SHELL_QUIET_S. A window can show long before its shell has loaded (a blank pane behind a slow disk), and
        keys typed then may be lost or echoed twice; a shell blocked on the disk or a virus scan also uses no
        CPU, which is why quiet only counts after the work.

        Returns (state, seconds waited): "ready"; "busy" (a new shell, never ready in time); "none" (no new shell
        in time); "unknown" (the desktop cannot tell).
        """
        start = self.clock()
        prev = None          # (count, cpu, faults, clock) of the last sample with a shell
        quiet_from = None
        seen = False
        while True:
            act = self._new_shells(before)
            now = self.clock()
            if act is None:
                return "unknown", round(now - start, 3)
            count, cpu, faults = act
            if not count:
                prev = quiet_from = None
            else:
                seen = True
                polls = max(1.0, (now - prev[3]) / POLL_S) if prev else 1.0
                busy = (prev is None or prev[0] != count or cpu < SHELL_MIN_CPU_S
                        or cpu - prev[1] > SHELL_CPU_EPS_S * polls or faults - prev[2] > SHELL_FAULTS_EPS * polls)
                if busy:
                    quiet_from = now
                elif now - quiet_from >= SHELL_QUIET_S:
                    return "ready", round(now - start, 3)
                prev = (count, cpu, faults, now)
            remaining = timeout_s - (now - start)
            if remaining <= 0:
                return ("busy" if seen else "none"), round(now - start, 3)
            self.sleep(min(POLL_S, remaining))

    def run_visible(self, v: dict, deadline: float | None = None) -> dict:
        with self._input(deadline):
            term = find_terminal(self.desktop)
            launched = False
            extra: dict = {}
            if term is None:
                argv, new_console = self.terminal_argv()
                procs = self.desktop.shell_processes()   # the shells already running are not the new one
                before = None if procs is None else set(procs)
                t0 = self.clock()
                self.desktop.launch(argv, new_console)
                launched = True
                term = self._wait_terminal(LAUNCH_WAIT_S)
                if term is None:
                    raise ActionError("no-terminal", f"no terminal window within {LAUNCH_WAIT_S:g} s after "
                                                     f"starting {os.path.basename(argv[0])}")
                extra["window_s"] = round(self.clock() - t0, 3)
                if before is None:
                    state, waited = "unknown", 0.0
                else:
                    state, waited = self._wait_shell(before, SHELL_READY_MAX_S)
                extra["shell"], extra["shell_wait_s"] = state, waited
                if state != "ready":
                    self.sleep(LAUNCH_SETTLE_S)
            hwnd, title, cls = term
            if not self.desktop.focus(hwnd):
                raise ActionError("focus-failed", f"could not bring the terminal window to the front ({cls})")
            self.sleep(FOCUS_SETTLE_S)
            for h, t, _c in self.desktop.top_windows():   # the title as it is now (a new shell renames it)
                if h == hwnd:
                    title = t
                    break
            r = self.typist.type_text(v["command"], enter=True, deadline=deadline, target=hwnd,
                                      foreground=self.desktop.foreground)
        return {"ok": True, "title": title, "class": cls, "launched": launched, **extra, **r}
