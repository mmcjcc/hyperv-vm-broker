"""The real desktop: Win32 through ctypes. The ONLY module of the director that calls Win32.

Input: SendInput (keys as virtual-key events with their scan code and the extended flag where Windows wants it; text
as KEYEVENTF_UNICODE events, astral characters as a surrogate pair; the mouse as MOVE|ABSOLUTE|VIRTUALDESK events
normalized to 0..65535, then SetCursorPos only if rounding left the cursor off the target). Windows: EnumWindows,
visible and not cloaked. Foreground: restore if minimized, SetForegroundWindow, and only if Windows refuses, the
Alt-key trick (keybd_event VK_MENU down and up) and a second try, checked with GetForegroundWindow. Capture: GetDC(0),
a compatible DC and bitmap, BitBlt(SRCCOPY|CAPTUREBLT), GetDIBits as 32 bpp top-down BGRA. Shells: a Toolhelp
process snapshot, then GetProcessTimes and K32GetProcessMemoryInfo through query-only handles. Stuck modifiers:
GetAsyncKeyState for left and right Shift, Ctrl, Alt and Win; key-up for each one down (an unassigned key is tapped
first when Alt or Win is down, so the release opens no menu).

The tests import this module (struct layouts, the pure helpers) but never call Win32Desktop's input, capture, focus,
launch or release_modifiers methods: on the build machine those would type into, click on or capture the real
desktop. They do call shell_processes, which only reads.
"""

from __future__ import annotations

import ctypes
import os
import shutil
import subprocess
import sys
import time
from ctypes import wintypes

from .desktop import Desktop, DesktopError
from .keys import utf16_units

if sys.platform != "win32":   # pragma: no cover
    raise ImportError("vm_director.win32 needs Windows")

ULONG_PTR = ctypes.c_size_t   # pointer-sized unsigned (8 bytes on x64)

INPUT_MOUSE = 0
INPUT_KEYBOARD = 1
KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040
MOUSEEVENTF_VIRTUALDESK = 0x4000
MOUSEEVENTF_ABSOLUTE = 0x8000
MOVE_FLAGS = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK
BUTTON_FLAGS = {
    ("left", False): MOUSEEVENTF_LEFTDOWN, ("left", True): MOUSEEVENTF_LEFTUP,
    ("right", False): MOUSEEVENTF_RIGHTDOWN, ("right", True): MOUSEEVENTF_RIGHTUP,
    ("middle", False): MOUSEEVENTF_MIDDLEDOWN, ("middle", True): MOUSEEVENTF_MIDDLEUP,
}
SM_CXSCREEN, SM_CYSCREEN = 0, 1
SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN = 76, 77, 78, 79
MAPVK_VK_TO_VSC = 0
SW_RESTORE = 9
VK_MENU = 0x12
SRCCOPY = 0x00CC0020
CAPTUREBLT = 0x40000000
BI_RGB = 0
DIB_RGB_COLORS = 0
LOGPIXELSX = 88
DWMWA_CLOAKED = 14
JobObjectExtendedLimitInformation = 9
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
TH32CS_SNAPPROCESS = 0x00000002
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
FILETIME_EPOCH = 116444736000000000   # 1970-01-01 in 100 ns units since 1601
SHELL_NAMES = frozenset({"powershell.exe", "pwsh.exe", "cmd.exe"})

# Keys Windows sends with the E0 prefix: without KEYEVENTF_EXTENDEDKEY some programs see the numpad keys instead.
EXTENDED_VKS = frozenset({
    0x21, 0x22, 0x23, 0x24,          # PgUp, PgDn, End, Home
    0x25, 0x26, 0x27, 0x28,          # arrows
    0x2C, 0x2D, 0x2E,                # PrintScreen, Insert, Delete
    0x5B, 0x5C, 0x5D,                # LWin, RWin, Apps
    0x6F, 0x90, 0xA3, 0xA5,          # numpad divide, NumLock, RCtrl, RAlt
})
# release_modifiers: left and right Shift, Ctrl, Alt, Win (the async key state tracks the sides separately)
MODIFIER_VKS = (0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C)
MENU_VKS = frozenset({0xA4, 0xA5, 0x5B, 0x5C})   # released alone, these open a menu bar or the Start menu
MASK_VK = 0xE8   # unassigned: tapped while Alt or Win is down, so their release opens nothing


# --- structures ----------------------------------------------------------------------------------------------
class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
                ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
                ("biClrImportant", wintypes.DWORD)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wintypes.DWORD * 1)]


class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", wintypes.LARGE_INTEGER), ("PerJobUserTimeLimit", wintypes.LARGE_INTEGER),
                ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ULONG_PTR), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]


class IO_COUNTERS(ctypes.Structure):
    _fields_ = [(n, ctypes.c_ulonglong) for n in ("ReadOperationCount", "WriteOperationCount",
                                                    "OtherOperationCount", "ReadTransferCount",
                                                    "WriteTransferCount", "OtherTransferCount")]


class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION), ("IoInfo", IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ULONG_PTR), ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
                ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]


class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
        (n, ctypes.c_size_t) for n in ("PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                                       "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                                       "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage")]


WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

# --- functions (argtypes and restype set for every one) ------------------------------------------------------
user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)


def _fn(dll, name, restype, *argtypes, optional=False):
    try:
        f = getattr(dll, name)
    except AttributeError:
        if optional:
            return None
        raise
    f.restype = restype
    f.argtypes = list(argtypes)
    return f


SendInput = _fn(user32, "SendInput", wintypes.UINT, wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int)
MapVirtualKeyW = _fn(user32, "MapVirtualKeyW", wintypes.UINT, wintypes.UINT, wintypes.UINT)
VkKeyScanW = _fn(user32, "VkKeyScanW", wintypes.SHORT, wintypes.WCHAR)
GetAsyncKeyState = _fn(user32, "GetAsyncKeyState", wintypes.SHORT, ctypes.c_int)
keybd_event = _fn(user32, "keybd_event", None, wintypes.BYTE, wintypes.BYTE, wintypes.DWORD, ULONG_PTR)
GetCursorPos = _fn(user32, "GetCursorPos", wintypes.BOOL, ctypes.POINTER(wintypes.POINT))
SetCursorPos = _fn(user32, "SetCursorPos", wintypes.BOOL, ctypes.c_int, ctypes.c_int)
GetSystemMetrics = _fn(user32, "GetSystemMetrics", ctypes.c_int, ctypes.c_int)
GetDpiForSystem = _fn(user32, "GetDpiForSystem", wintypes.UINT, optional=True)
SetProcessDpiAwarenessContext = _fn(user32, "SetProcessDpiAwarenessContext", wintypes.BOOL, wintypes.HANDLE,
                                    optional=True)
SetProcessDPIAware = _fn(user32, "SetProcessDPIAware", wintypes.BOOL, optional=True)
EnumWindows = _fn(user32, "EnumWindows", wintypes.BOOL, WNDENUMPROC, wintypes.LPARAM)
IsWindow = _fn(user32, "IsWindow", wintypes.BOOL, wintypes.HWND)
IsWindowVisible = _fn(user32, "IsWindowVisible", wintypes.BOOL, wintypes.HWND)
IsIconic = _fn(user32, "IsIconic", wintypes.BOOL, wintypes.HWND)
GetWindowTextLengthW = _fn(user32, "GetWindowTextLengthW", ctypes.c_int, wintypes.HWND)
GetWindowTextW = _fn(user32, "GetWindowTextW", ctypes.c_int, wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
GetClassNameW = _fn(user32, "GetClassNameW", ctypes.c_int, wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
ShowWindow = _fn(user32, "ShowWindow", wintypes.BOOL, wintypes.HWND, ctypes.c_int)
SetForegroundWindow = _fn(user32, "SetForegroundWindow", wintypes.BOOL, wintypes.HWND)
GetForegroundWindow = _fn(user32, "GetForegroundWindow", wintypes.HWND)
BringWindowToTop = _fn(user32, "BringWindowToTop", wintypes.BOOL, wintypes.HWND)
GetDC = _fn(user32, "GetDC", wintypes.HDC, wintypes.HWND)
ReleaseDC = _fn(user32, "ReleaseDC", ctypes.c_int, wintypes.HWND, wintypes.HDC)
CreateCompatibleDC = _fn(gdi32, "CreateCompatibleDC", wintypes.HDC, wintypes.HDC)
DeleteDC = _fn(gdi32, "DeleteDC", wintypes.BOOL, wintypes.HDC)
CreateCompatibleBitmap = _fn(gdi32, "CreateCompatibleBitmap", wintypes.HBITMAP, wintypes.HDC, ctypes.c_int,
                             ctypes.c_int)
SelectObject = _fn(gdi32, "SelectObject", wintypes.HGDIOBJ, wintypes.HDC, wintypes.HGDIOBJ)
DeleteObject = _fn(gdi32, "DeleteObject", wintypes.BOOL, wintypes.HGDIOBJ)
BitBlt = _fn(gdi32, "BitBlt", wintypes.BOOL, wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
             wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD)
GetDIBits = _fn(gdi32, "GetDIBits", ctypes.c_int, wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT,
                wintypes.LPVOID, ctypes.POINTER(BITMAPINFO), wintypes.UINT)
GetDeviceCaps = _fn(gdi32, "GetDeviceCaps", ctypes.c_int, wintypes.HDC, ctypes.c_int)
GetCurrentProcessId = _fn(kernel32, "GetCurrentProcessId", wintypes.DWORD)
ProcessIdToSessionId = _fn(kernel32, "ProcessIdToSessionId", wintypes.BOOL, wintypes.DWORD,
                           ctypes.POINTER(wintypes.DWORD))
CreateJobObjectW = _fn(kernel32, "CreateJobObjectW", wintypes.HANDLE, wintypes.LPVOID, wintypes.LPCWSTR)
SetInformationJobObject = _fn(kernel32, "SetInformationJobObject", wintypes.BOOL, wintypes.HANDLE, ctypes.c_int,
                              wintypes.LPVOID, wintypes.DWORD)
AssignProcessToJobObject = _fn(kernel32, "AssignProcessToJobObject", wintypes.BOOL, wintypes.HANDLE,
                               wintypes.HANDLE)
CreateToolhelp32Snapshot = _fn(kernel32, "CreateToolhelp32Snapshot", wintypes.HANDLE, wintypes.DWORD,
                               wintypes.DWORD)
Process32FirstW = _fn(kernel32, "Process32FirstW", wintypes.BOOL, wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W))
Process32NextW = _fn(kernel32, "Process32NextW", wintypes.BOOL, wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W))
OpenProcess = _fn(kernel32, "OpenProcess", wintypes.HANDLE, wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
CloseHandle = _fn(kernel32, "CloseHandle", wintypes.BOOL, wintypes.HANDLE)
GetProcessTimes = _fn(kernel32, "GetProcessTimes", wintypes.BOOL, wintypes.HANDLE,
                      *([ctypes.POINTER(wintypes.FILETIME)] * 4))
K32GetProcessMemoryInfo = _fn(kernel32, "K32GetProcessMemoryInfo", wintypes.BOOL, wintypes.HANDLE,
                              ctypes.POINTER(PROCESS_MEMORY_COUNTERS), wintypes.DWORD)
GetUserNameW = _fn(advapi32, "GetUserNameW", wintypes.BOOL, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD))
try:
    dwmapi = ctypes.WinDLL("dwmapi")
    DwmGetWindowAttribute = _fn(dwmapi, "DwmGetWindowAttribute", ctypes.c_long, wintypes.HWND, wintypes.DWORD,
                                wintypes.LPVOID, wintypes.DWORD)
except OSError:   # pragma: no cover - no DWM (Server Core)
    DwmGetWindowAttribute = None


# --- pure helpers (tested) -----------------------------------------------------------------------------------
def key_input(vk: int, scan: int, flags: int) -> INPUT:
    inp = INPUT(type=INPUT_KEYBOARD)
    inp.ki = KEYBDINPUT(wVk=vk, wScan=scan, dwFlags=flags, time=0, dwExtraInfo=0)
    return inp


def unicode_inputs(ch: str) -> list[INPUT]:
    """Down and up events for every UTF-16 code unit of `ch` (a surrogate pair for an astral character)."""
    out = []
    for unit in utf16_units(ch):
        out.append(key_input(0, unit, KEYEVENTF_UNICODE))
        out.append(key_input(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP))
    return out


def vk_flags(vk: int, up: bool) -> int:
    return (KEYEVENTF_KEYUP if up else 0) | (KEYEVENTF_EXTENDEDKEY if vk in EXTENDED_VKS else 0)


def mouse_input(dx: int, dy: int, flags: int) -> INPUT:
    inp = INPUT(type=INPUT_MOUSE)
    inp.mi = MOUSEINPUT(dx=dx, dy=dy, mouseData=0, dwFlags=flags, time=0, dwExtraInfo=0)
    return inp


def normalize_abs(v: int, origin: int, size: int) -> int:
    """Pixel -> 0..65535 absolute coordinate, aimed at the pixel's centre (Windows maps n back as n * size / 65536)."""
    if size <= 1:
        return 0
    n = ((v - origin) * 2 + 1) * 65536 // (2 * size)
    return max(0, min(65535, n))


def filetime_value(ft) -> int:
    """A FILETIME as one integer (100 ns units)."""
    return (int(ft.dwHighDateTime) << 32) | int(ft.dwLowDateTime)


def filetime_to_epoch(value: int) -> float:
    """A FILETIME integer (100 ns units since 1601) as Unix epoch seconds."""
    return (value - FILETIME_EPOCH) / 1e7


def set_dpi_awareness() -> str:
    """Per-monitor v2 if Windows allows it, else system aware. Call before anything reads metrics."""
    if SetProcessDpiAwarenessContext is not None:
        if SetProcessDpiAwarenessContext(wintypes.HANDLE(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)):
            return "per-monitor-v2"
    if SetProcessDPIAware is not None and SetProcessDPIAware():
        return "system"
    return "unchanged"


# --- the desktop -----------------------------------------------------------------------------------------------
class Win32Desktop(Desktop):
    def __init__(self):
        self._job = None

    # input
    def _send(self, inputs: list[INPUT]) -> None:
        n = len(inputs)
        arr = (INPUT * n)(*inputs)
        sent = SendInput(n, arr, ctypes.sizeof(INPUT))
        if sent != n:
            err = ctypes.get_last_error()
            raise DesktopError("input-blocked", f"SendInput inserted {sent} of {n} events (Windows error {err}); "
                                                "a UAC prompt, an elevated window or the lock screen may be in front")

    def send_unicode(self, ch: str) -> None:
        self._send(unicode_inputs(ch))

    def send_vk(self, vk: int, up: bool) -> None:
        scan = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC) & 0xFFFF
        self._send([key_input(vk, scan, vk_flags(vk, up))])

    def vk_for_char(self, ch: str) -> tuple[int, bool] | None:
        if len(ch) != 1 or ord(ch) > 0xFFFF:
            return None
        r = VkKeyScanW(ch)
        if r == -1:
            return None
        vk, state = r & 0xFF, (r >> 8) & 0xFF
        if vk == 0xFF or state & ~1:   # needs Ctrl or Alt (AltGr): leave it to KEYEVENTF_UNICODE
            return None
        return vk, bool(state & 1)

    def release_modifiers(self) -> list[int]:
        down = [vk for vk in MODIFIER_VKS if GetAsyncKeyState(vk) & 0x8000]
        if not down:
            return []
        if any(vk in MENU_VKS for vk in down):
            try:   # another key between Alt/Win down and up: their release then opens no menu
                self._send([key_input(MASK_VK, 0, 0), key_input(MASK_VK, 0, KEYEVENTF_KEYUP)])
            except DesktopError:
                pass
        released = []
        for vk in down:
            try:
                self.send_vk(vk, True)
                released.append(vk)
            except DesktopError:
                pass
        return released

    def move_abs(self, x: int, y: int) -> None:
        vx, vy = GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN)
        vw, vh = GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN)
        if vw <= 0 or vh <= 0:
            vx, vy = 0, 0
            vw, vh = self.screen_size()
        self._send([mouse_input(normalize_abs(x, vx, vw), normalize_abs(y, vy, vh), MOVE_FLAGS)])

    def warp(self, x: int, y: int) -> None:
        if not SetCursorPos(x, y):
            raise DesktopError("input-blocked", f"SetCursorPos failed (Windows error {ctypes.get_last_error()})")

    def mouse_button(self, button: str, up: bool) -> None:
        self._send([mouse_input(0, 0, BUTTON_FLAGS[(button, up)])])

    # state
    def cursor_pos(self) -> tuple[int, int]:
        pt = wintypes.POINT()
        if not GetCursorPos(ctypes.byref(pt)):
            raise DesktopError("desktop-unavailable",
                               f"GetCursorPos failed (Windows error {ctypes.get_last_error()}); secure desktop?")
        return pt.x, pt.y

    def screen_size(self) -> tuple[int, int]:
        return GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)

    def dpi(self) -> int:
        if GetDpiForSystem is not None:
            return int(GetDpiForSystem())
        hdc = GetDC(None)
        try:
            return int(GetDeviceCaps(hdc, LOGPIXELSX))
        finally:
            ReleaseDC(None, hdc)

    @staticmethod
    def _cloaked(hwnd) -> bool:
        if DwmGetWindowAttribute is None:
            return False
        val = wintypes.DWORD(0)
        hr = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, ctypes.byref(val), ctypes.sizeof(val))
        return hr == 0 and val.value != 0

    def top_windows(self) -> list[tuple[int, str, str]]:
        found: list[tuple[int, str, str]] = []

        def visit(hwnd, _lparam):
            try:
                if not hwnd or not IsWindowVisible(hwnd) or self._cloaked(hwnd):
                    return True
                n = min(max(GetWindowTextLengthW(hwnd), 0), 4096)
                title = ctypes.create_unicode_buffer(n + 1)
                if n:
                    GetWindowTextW(hwnd, title, n + 1)
                cls = ctypes.create_unicode_buffer(257)
                GetClassNameW(hwnd, cls, 257)
                found.append((int(hwnd), title.value, cls.value))
            except Exception:   # one odd window must not end the enumeration
                pass
            return True

        EnumWindows(WNDENUMPROC(visit), 0)
        return found

    def foreground(self) -> int:
        return int(GetForegroundWindow() or 0)

    def _wait_foreground(self, hwnd: int, seconds: float) -> bool:
        end = time.monotonic() + seconds
        while True:
            if self.foreground() == hwnd:
                return True
            if time.monotonic() >= end:
                return False
            time.sleep(0.05)

    def focus(self, hwnd: int) -> bool:
        if not IsWindow(hwnd):
            return False
        if IsIconic(hwnd):
            ShowWindow(hwnd, SW_RESTORE)   # only when minimized: SW_RESTORE would un-maximize a maximized window
        if self.foreground() == hwnd:
            return True
        SetForegroundWindow(hwnd)
        if self._wait_foreground(hwnd, 0.3):
            return True
        # Foreground lock: a tap of Alt makes Windows accept SetForegroundWindow from this process.
        keybd_event(VK_MENU, 0, 0, 0)
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0)
        SetForegroundWindow(hwnd)
        BringWindowToTop(hwnd)
        return self._wait_foreground(hwnd, 1.0)

    def capture(self) -> tuple[int, int, bytes]:
        w, h = self.screen_size()
        if w <= 0 or h <= 0:
            raise DesktopError("capture-failed", "the screen size is 0")
        screen = GetDC(None)
        if not screen:
            raise DesktopError("capture-failed", "GetDC failed")
        mem = bmp = old = None
        try:
            mem = CreateCompatibleDC(screen)
            bmp = CreateCompatibleBitmap(screen, w, h) if mem else None
            if not mem or not bmp:
                raise DesktopError("capture-failed", "cannot create a bitmap for the screen")
            old = SelectObject(mem, bmp)
            if not BitBlt(mem, 0, 0, w, h, screen, 0, 0, SRCCOPY | CAPTUREBLT):
                raise DesktopError("capture-failed", f"BitBlt failed (Windows error {ctypes.get_last_error()}); "
                                                     "the desktop may be locked or on the secure desktop")
            SelectObject(mem, old)   # GetDIBits wants the bitmap selected out of every DC
            old = None
            bmi = BITMAPINFO()
            bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
            bmi.bmiHeader.biWidth = w
            bmi.bmiHeader.biHeight = -h   # negative: top-down rows
            bmi.bmiHeader.biPlanes = 1
            bmi.bmiHeader.biBitCount = 32
            bmi.bmiHeader.biCompression = BI_RGB
            buf = ctypes.create_string_buffer(w * h * 4)
            rows = GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(bmi), DIB_RGB_COLORS)
            if rows != h:
                raise DesktopError("capture-failed", f"GetDIBits copied {rows} of {h} rows")
            return w, h, buf.raw
        finally:
            if old:
                SelectObject(mem, old)
            if bmp:
                DeleteObject(bmp)
            if mem:
                DeleteDC(mem)
            ReleaseDC(None, screen)

    def session_id(self) -> int:
        sid = wintypes.DWORD(0)
        if not ProcessIdToSessionId(GetCurrentProcessId(), ctypes.byref(sid)):
            return -1
        return int(sid.value)

    def user(self) -> str:
        size = wintypes.DWORD(257)
        buf = ctypes.create_unicode_buffer(size.value)
        if GetUserNameW(buf, ctypes.byref(size)):
            return buf.value
        return os.environ.get("USERNAME", "")

    def free_bytes(self, path: str) -> int:
        return shutil.disk_usage(path).free

    # processes
    def launch(self, argv: list[str], new_console: bool = False) -> None:
        flags = subprocess.CREATE_NEW_CONSOLE if new_console else 0
        cwd = os.environ.get("USERPROFILE") or None
        if cwd and not os.path.isdir(cwd):
            cwd = None
        try:
            # Out of the scheduled task's job when allowed, so a director restart does not take the window along.
            subprocess.Popen(argv, cwd=cwd, creationflags=flags | subprocess.CREATE_BREAKAWAY_FROM_JOB)
            return
        except OSError:
            pass
        try:
            subprocess.Popen(argv, cwd=cwd, creationflags=flags)
        except OSError as e:
            raise DesktopError("launch-failed", f"cannot start {os.path.basename(argv[0])}: "
                                                f"{e.strerror or type(e).__name__}") from None

    def contain_child(self, proc) -> None:
        """Put ffmpeg in a job that closes with the director, so a director crash cannot leave it recording."""
        try:
            if self._job is None:
                job = CreateJobObjectW(None, None)
                if not job:
                    return
                info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                if not SetInformationJobObject(job, JobObjectExtendedLimitInformation, ctypes.byref(info),
                                               ctypes.sizeof(info)):
                    return
                self._job = job   # never closed: it closes when the director exits
            handle = getattr(proc, "_handle", None)
            if handle:
                AssignProcessToJobObject(self._job, int(handle))
        except Exception:
            pass

    def shell_processes(self) -> dict | None:
        """Shells (SHELL_NAMES) in this session: {(pid, creation FILETIME): (CPU seconds, page faults)}. The
        creation time is part of the key, so a process id Windows reuses counts as a new process. Read-only: a
        process snapshot and query-only handles."""
        session = self.session_id()
        if session < 0:
            return None
        snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        if not snap or snap == INVALID_HANDLE_VALUE:
            return None
        found: dict = {}
        try:
            entry = PROCESSENTRY32W()
            entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
            more = Process32FirstW(snap, ctypes.byref(entry))
            while more:
                if entry.szExeFile.lower() in SHELL_NAMES:
                    pid = int(entry.th32ProcessID)
                    stats = self._process_stats(pid, session)
                    if stats is not None:
                        created, cpu, faults = stats
                        found[(pid, created)] = (cpu, faults)
                more = Process32NextW(snap, ctypes.byref(entry))
        finally:
            CloseHandle(snap)
        return found

    @staticmethod
    def _process_stats(pid: int, session: int) -> tuple[int, float, int] | None:
        """(creation FILETIME, CPU seconds, page faults) of a process in `session`, or None."""
        sid = wintypes.DWORD(0)
        if not ProcessIdToSessionId(pid, ctypes.byref(sid)) or int(sid.value) != session:
            return None
        h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return None   # gone, or not ours
        try:
            created, exited, kernel, user = (wintypes.FILETIME() for _ in range(4))
            if not GetProcessTimes(h, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel),
                                   ctypes.byref(user)):
                return None
            pmc = PROCESS_MEMORY_COUNTERS()
            pmc.cb = ctypes.sizeof(PROCESS_MEMORY_COUNTERS)
            faults = int(pmc.PageFaultCount) if K32GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb) else 0
            return filetime_value(created), (filetime_value(kernel) + filetime_value(user)) / 1e7, faults
        finally:
            CloseHandle(h)
