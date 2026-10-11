"""The desktop interface the director's code uses.

Only win32.py implements it for real (with ctypes). Everything else (keys, mouse, windows, the HTTP handlers) talks
to a Desktop, so the tests can pass a fake one and never touch the real desktop of the machine they run on.
"""

from __future__ import annotations

import abc


class DesktopError(Exception):
    """A desktop operation failed. `word` is the error word the API returns; `detail` is one printable line."""

    def __init__(self, word: str, detail: str):
        super().__init__(detail)
        self.word = word
        self.detail = detail


class InputStopped(Exception):
    """An input action stopped before its end (keys.py, mouse.py). `word` is "deadline" (the relay's time for the
    step ran out) or "focus-lost" (the target window lost the foreground); `extra` goes into the answer (chars or
    chords done; for a click, whether the cursor moved and how many clicks were made)."""

    def __init__(self, word: str, detail: str, **extra):
        super().__init__(detail)
        self.word = word
        self.detail = detail
        self.extra = extra


class Desktop(abc.ABC):
    """What the director needs from the interactive desktop it runs on."""

    # --- input ---------------------------------------------------------------------------------------------
    @abc.abstractmethod
    def send_unicode(self, ch: str) -> None:
        """Type one character (one code point; astral ones as a surrogate pair) as KEYEVENTF_UNICODE events."""

    @abc.abstractmethod
    def send_vk(self, vk: int, up: bool) -> None:
        """Press (up=False) or release (up=True) one virtual key."""

    @abc.abstractmethod
    def move_abs(self, x: int, y: int) -> None:
        """Move the cursor to screen pixel (x, y)."""

    @abc.abstractmethod
    def mouse_button(self, button: str, up: bool) -> None:
        """Press or release 'left', 'right' or 'middle' at the current cursor position."""

    def warp(self, x: int, y: int) -> None:
        """Put the cursor exactly on (x, y) without a move event; used to correct a rounding miss. Optional."""
        self.move_abs(x, y)

    def vk_for_char(self, ch: str) -> tuple[int, bool] | None:
        """(virtual key, needs shift) for `ch` on the current keyboard layout, or None. Optional (typing=layout)."""
        return None

    def release_modifiers(self) -> list[int]:
        """Send key-up for every modifier (Shift, Ctrl, Alt, Win; left and right) the system reports as down, so a
        key left down (a release that failed, a director killed in the middle of a chord) cannot turn later typing
        into shortcuts. Returns the virtual keys it released. The director calls it at start and after an input
        error or a stopped input action. Optional (the default releases nothing)."""
        return []

    # --- state ---------------------------------------------------------------------------------------------
    @abc.abstractmethod
    def cursor_pos(self) -> tuple[int, int]:
        """The cursor position in screen pixels."""

    @abc.abstractmethod
    def screen_size(self) -> tuple[int, int]:
        """(width, height) of the primary screen in physical pixels."""

    @abc.abstractmethod
    def dpi(self) -> int:
        """System DPI (96 = 100 % scaling)."""

    @abc.abstractmethod
    def top_windows(self) -> list[tuple[int, str, str]]:
        """Visible top-level windows in Z order (topmost first): (hwnd, title, class name)."""

    @abc.abstractmethod
    def focus(self, hwnd: int) -> bool:
        """Bring `hwnd` to the foreground; True when it is the foreground window afterwards."""

    def foreground(self) -> int:
        """The handle of the foreground window (the one that gets the keys), 0 if there is none. /run_visible
        compares it with the terminal's before every character. Optional (the default 0 never matches)."""
        return 0

    @abc.abstractmethod
    def capture(self) -> tuple[int, int, bytes]:
        """Capture the primary screen: (width, height, BGRA bytes, top-down rows)."""

    @abc.abstractmethod
    def session_id(self) -> int:
        """The Windows session id this process runs in."""

    @abc.abstractmethod
    def user(self) -> str:
        """The user name this process runs as."""

    @abc.abstractmethod
    def free_bytes(self, path: str) -> int:
        """Free bytes on the drive that holds `path`."""

    # --- processes -----------------------------------------------------------------------------------------
    @abc.abstractmethod
    def launch(self, argv: list[str], new_console: bool = False) -> None:
        """Start a visible program in this session (no stdio redirection). new_console: give it its own console."""

    def contain_child(self, proc) -> None:
        """Tie a child process (a subprocess.Popen) to this process's lifetime, if the platform can. Optional."""
        return None

    def shell_processes(self) -> dict | None:
        """The shells (powershell.exe, pwsh.exe, cmd.exe) running in this session now, one entry per process:
        {key: (CPU seconds, page faults)}. A key identifies one process: its process id (win32 pairs the id with
        the creation time, so an id Windows reuses is a new key). /run_visible takes the keys before it starts a
        terminal and then watches only the processes whose keys were not there. None when the platform cannot
        tell. Optional."""
        return None
