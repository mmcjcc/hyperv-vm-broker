"""Fakes for the director tests: a clock, a desktop and an ffmpeg process. Nothing here touches the real desktop."""

from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")
if SRC not in sys.path:
    sys.path.insert(0, SRC)

from vm_director.desktop import Desktop, DesktopError  # noqa: E402

GIB = 1024 ** 3


class FakeClock:
    """A monotonic clock that only moves when something sleeps on it (or the test advances it)."""

    def __init__(self, t: float = 1000.0, log: list | None = None):
        self.t = t
        self.log = log if log is not None else []
        self.sleeps: list[float] = []
        self._lock = threading.Lock()

    def __call__(self) -> float:
        return self.t

    def sleep(self, s: float) -> None:
        assert s >= 0, s
        with self._lock:
            self.sleeps.append(s)
            self.log.append(("sleep", s))
            self.t += s

    def advance(self, s: float) -> None:
        with self._lock:
            self.t += s


class FakeDesktop(Desktop):
    def __init__(self, clock: FakeClock | None = None, width: int = 1920, height: int = 1080, dpi: int = 96,
                 free: int = 100 * GIB):
        self.clock = clock or FakeClock()
        self.log = self.clock.log           # input events and sleeps, in order
        self.width, self.height, self._dpi, self.free = width, height, dpi, free
        self.cursor = (100, 100)
        self.windows = []                   # list of (hwnd, title, class), or a callable(now) returning one
        self.focus_ok = True
        self.focused: list[int] = []
        self.launched: list[tuple[list[str], bool]] = []
        self.on_launch = None               # callable(desktop) run after launch()
        self.image = (3, 2, bytes(range(24)))
        self.layout = {}                    # ch -> (vk, shift) for typing=layout
        self.fail_vk = None                 # (vk, up) that raises input-blocked
        self.move_error = (0, 0)            # added to every move_abs (a rounding miss)
        self.warps: list[tuple[int, int]] = []
        self.session_error = None
        self.shells = None                  # None (cannot tell), or a callable(now) -> {key: (cpu s, page faults)}
        self.shell_calls: list[tuple[float, int]] = []   # (fake time, launches so far) per shell_processes()
        self.fg = 0                         # the foreground window; focus() sets it when focus_ok
        self.on_char = None                 # callable(desktop, chars sent so far) run after each send_unicode
        self.chars_sent = 0
        self.down_modifiers: list[int] = []  # what release_modifiers() finds down (and releases)
        self.modifier_releases: list[float] = []   # fake time of every release_modifiers() call

    def _ev(self, *e):
        self.log.append(e)

    # input
    def send_unicode(self, ch):
        self._ev("char", ch)
        self.chars_sent += 1
        if self.on_char:
            self.on_char(self, self.chars_sent)

    def send_vk(self, vk, up):
        if self.fail_vk == (vk, up):
            raise DesktopError("input-blocked", "fake failure")
        self._ev("vk", vk, up)

    def move_abs(self, x, y):
        self.cursor = (x + self.move_error[0], y + self.move_error[1])
        self._ev("move", x, y)

    def warp(self, x, y):
        self.cursor = (x, y)
        self.warps.append((x, y))
        self._ev("warp", x, y)

    def mouse_button(self, button, up):
        self._ev("button", button, up)

    def vk_for_char(self, ch):
        return self.layout.get(ch)

    def release_modifiers(self):
        self.modifier_releases.append(self.clock())
        released, self.down_modifiers = list(self.down_modifiers), []
        return released

    # state
    def cursor_pos(self):
        return self.cursor

    def screen_size(self):
        return self.width, self.height

    def dpi(self):
        return self._dpi

    def top_windows(self):
        w = self.windows(self.clock()) if callable(self.windows) else self.windows
        return list(w)

    def focus(self, hwnd):
        self.focused.append(hwnd)
        self._ev("focus", hwnd)
        if self.focus_ok:
            self.fg = hwnd
        return self.focus_ok

    def foreground(self):
        return self.fg

    def capture(self):
        return self.image

    def session_id(self):
        if self.session_error:
            raise self.session_error
        return 1

    def user(self):
        return "student"

    def free_bytes(self, path):
        return self.free

    def launch(self, argv, new_console=False):
        self.launched.append((list(argv), new_console))
        self._ev("launch", list(argv), new_console)
        if self.on_launch:
            self.on_launch(self)

    def shell_processes(self):
        self.shell_calls.append((self.clock(), len(self.launched)))
        return None if self.shells is None else dict(self.shells(self.clock()))


class LinePipe:
    """stdout of the fake ffmpeg: readline() blocks until the test feeds a line or closes the pipe."""

    def __init__(self):
        self.q: queue.Queue = queue.Queue()

    def feed(self, text: str) -> None:
        for line in text.splitlines(True):
            self.q.put(line.encode("utf-8"))

    def close(self) -> None:
        self.q.put(None)

    def readline(self) -> bytes:
        item = self.q.get()
        if item is None:
            self.q.put(None)
            return b""
        return item


class FakeStdin:
    def __init__(self, proc):
        self.proc = proc
        self.data = b""
        self.closed = False

    def write(self, b):
        if self.closed:
            raise ValueError("write to closed file")
        self.data += b
        if b"q" in b:
            self.proc.on_q()

    def flush(self):
        pass

    def close(self):
        self.closed = True


START = ("frame=0\nfps=0.0\nout_time_us=N/A\nout_time=N/A\nprogress=continue\n"
         "frame=1\nfps=0.0\nout_time_us=40000\nout_time=00:00:00.040000\nprogress=continue\n")
END = "frame=150\nfps=30.0\nout_time_us=5000000\nout_time=00:00:05.000000\nprogress=end\n"
NO_FRAME = "frame=0\nfps=0.0\nout_time_us=N/A\nout_time=N/A\nprogress=continue\n"   # running, but no frame yet
FIRST_FRAME = "frame=1\nfps=0.0\nout_time_us=40000\nout_time=00:00:00.040000\nprogress=continue\n"


class FakeFfmpeg:
    def __init__(self, argv, kwargs, start=START, end=END, video=b"\x1a\x45\xdf\xa3" + b"v" * 1230,
                 hang=False, exit_at_start=None):
        self.argv = list(argv)
        self.kwargs = kwargs
        self.stdout = LinePipe()
        self.stdin = FakeStdin(self)
        self.returncode = None
        self.killed = False
        self.end, self.video, self.hang = end, video, hang
        self._done = threading.Event()
        self.output = self.argv[-1]
        if exit_at_start is not None:
            kwargs["stderr"].write(b"[gdigrab @ 0000] Failed to capture image (error 5)\n")
            self.returncode = exit_at_start
            self.stdout.close()
            self._done.set()
        else:
            with open(self.output, "wb"):
                pass
            self.stdout.feed(start)

    def on_q(self):
        if self.hang:
            return
        with open(self.output, "ab") as f:
            f.write(self.video)
        self.stdout.feed(self.end)
        self.stdout.close()
        self.returncode = 0
        self._done.set()

    def end_by_itself(self, code=0, out_us=12_000_000, frames=360, video=True):
        """What gdigrab does when a screen grab fails (secure desktop, locked session): ffmpeg ends its input,
        finishes the file and exits, without any "q"."""
        if video:
            with open(self.output, "ab") as f:
                f.write(self.video)
        self.stdout.feed(f"frame={frames}\nout_time_us={out_us}\nprogress=end\n")
        self.stdout.close()
        self.returncode = code
        self._done.set()

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        if not self._done.wait(timeout):
            raise subprocess.TimeoutExpired(self.argv, timeout)
        return self.returncode

    def kill(self):
        self.killed = True
        if self.returncode is None:
            self.returncode = 1
        self.stdout.close()
        self._done.set()


class FakePopen:
    def __init__(self, **opts):
        self.opts = opts
        self.procs: list[FakeFfmpeg] = []

    def __call__(self, argv, **kwargs):
        p = FakeFfmpeg(argv, kwargs, **self.opts)
        self.procs.append(p)
        return p
