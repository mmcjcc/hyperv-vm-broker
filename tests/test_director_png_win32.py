"""PNG encoder (vm_director.png) and the pure parts of vm_director.win32.

The win32 tests check struct layouts and helpers only. They never call SendInput, keybd_event, SetCursorPos,
SetForegroundWindow, BitBlt/GetDIBits or launch anything: that would act on the real desktop of this machine.
"""

import ctypes
import os
import struct
import sys
import time
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import director_fakes  # noqa: E402,F401

from vm_director.png import SIGNATURE, bgra_to_rgb_rows, encode_png  # noqa: E402


def read_chunks(png: bytes):
    assert png[:8] == SIGNATURE
    i, chunks = 8, []
    while i < len(png):
        (n,) = struct.unpack(">I", png[i:i + 4])
        kind = png[i + 4:i + 8]
        data = png[i + 8:i + 8 + n]
        (crc,) = struct.unpack(">I", png[i + 8 + n:i + 12 + n])
        chunks.append((kind, data, crc))
        i += 12 + n
    return chunks


class Png(unittest.TestCase):
    def test_tiny_image_round_trip(self):
        w, h = 3, 2
        pixels = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (1, 2, 3), (250, 128, 7), (0, 0, 0)]   # RGB
        bgra = b"".join(bytes([b, g, r, 0x7F]) for r, g, b in pixels)
        png = encode_png(w, h, bgra)
        chunks = read_chunks(png)
        self.assertEqual([c[0] for c in chunks], [b"IHDR", b"IDAT", b"IEND"])
        for kind, data, crc in chunks:
            self.assertEqual(crc, zlib.crc32(kind + data) & 0xFFFFFFFF, kind)
        ihdr = struct.unpack(">IIBBBBB", chunks[0][1])
        self.assertEqual(ihdr, (3, 2, 8, 2, 0, 0, 0))
        self.assertEqual(chunks[2][1], b"")
        raw = zlib.decompress(chunks[1][1])
        self.assertEqual(len(raw), h * (1 + w * 3))
        got = []
        for y in range(h):
            row = raw[y * (1 + w * 3):(y + 1) * (1 + w * 3)]
            self.assertEqual(row[0], 0)   # filter type 0
            got += [tuple(row[1 + x * 3:4 + x * 3]) for x in range(w)]
        self.assertEqual(got, pixels)

    def test_size_mismatch(self):
        with self.assertRaises(ValueError):
            encode_png(2, 2, b"\x00" * 15)
        with self.assertRaises(ValueError):
            encode_png(0, 2, b"")

    def test_full_hd_is_fast_enough(self):
        w, h = 1920, 1080
        row = bytes((x * 7) & 0xFF for x in range(w * 4))
        bgra = row * h
        t = time.perf_counter()
        png = encode_png(w, h, bgra)
        elapsed = time.perf_counter() - t
        self.assertLess(elapsed, 5.0)
        raw = zlib.decompress(read_chunks(png)[1][1])
        self.assertEqual(len(raw), h * (1 + w * 3))
        rows = bgra_to_rgb_rows(w, h, bgra)
        self.assertEqual(bytes(rows[:4]), bytes([0, row[2], row[1], row[0]]))


@unittest.skipUnless(sys.platform == "win32", "Windows only")
class Win32Pure(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from vm_director import win32
        cls.w = win32

    def test_struct_layouts(self):
        w = self.w
        x64 = ctypes.sizeof(ctypes.c_void_p) == 8
        self.assertEqual(ctypes.sizeof(w.MOUSEINPUT), 32 if x64 else 24)
        self.assertEqual(ctypes.sizeof(w.KEYBDINPUT), 24 if x64 else 16)
        self.assertEqual(ctypes.sizeof(w.HARDWAREINPUT), 8)
        self.assertEqual(ctypes.sizeof(w.INPUT), 40 if x64 else 28)
        self.assertEqual(w.INPUT.u.offset, 8 if x64 else 4)
        self.assertEqual(w.KEYBDINPUT.dwExtraInfo.offset, 16 if x64 else 12)
        self.assertEqual(ctypes.sizeof(w.BITMAPINFOHEADER), 40)
        self.assertEqual(ctypes.sizeof(w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION), 144 if x64 else 112)
        self.assertEqual(ctypes.sizeof(w.PROCESSENTRY32W), 568 if x64 else 556)
        self.assertEqual(w.PROCESSENTRY32W.szExeFile.offset, 44 if x64 else 36)
        self.assertEqual(ctypes.sizeof(w.PROCESS_MEMORY_COUNTERS), 72 if x64 else 40)

    def test_filetime(self):
        w = self.w
        self.assertEqual(w.filetime_to_epoch(w.FILETIME_EPOCH), 0.0)
        self.assertEqual(w.filetime_to_epoch(w.FILETIME_EPOCH + 15_000_000), 1.5)
        ft = w.wintypes.FILETIME(dwLowDateTime=0x89ABCDEF, dwHighDateTime=0x01234567)
        self.assertEqual(w.filetime_value(ft), 0x0123456789ABCDEF)

    def test_shell_processes_sees_a_new_shell(self):
        # Read-only: a process snapshot and query-only handles. The cmd.exe is this test's own, without a window.
        import subprocess
        d = self.w.Win32Desktop()
        before = d.shell_processes()
        self.assertIsInstance(before, dict)
        p = subprocess.Popen(["cmd.exe", "/d", "/c", "ping -n 4 127.0.0.1 >nul"],
                             creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            deadline = time.monotonic() + 5
            mine = []
            while not mine and time.monotonic() < deadline:
                mine = [(k, v) for k, v in d.shell_processes().items() if k[0] == p.pid]
                if not mine:
                    time.sleep(0.1)
            self.assertEqual(len(mine), 1)
            key, (cpu, faults) = mine[0]
            self.assertNotIn(key, before)   # a new process: a new key
            self.assertGreater(key[1], self.w.FILETIME_EPOCH)   # its creation time is part of the key
            self.assertGreaterEqual(cpu, 0.0)
            self.assertGreater(faults, 0)
        finally:
            p.kill()
            p.wait(5)

    def test_modifier_keys(self):
        w = self.w
        self.assertEqual(sorted(w.MODIFIER_VKS), [0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5])
        for vk in (0xA3, 0xA5, 0x5B, 0x5C):   # right Ctrl, right Alt and both Win keys need the extended flag
            self.assertTrue(w.vk_flags(vk, True) & w.KEYEVENTF_EXTENDEDKEY, hex(vk))
        self.assertEqual(w.MENU_VKS, {0xA4, 0xA5, 0x5B, 0x5C})
        self.assertNotIn(w.MASK_VK, w.MODIFIER_VKS)

    def test_unicode_inputs(self):
        w = self.w
        ins = w.unicode_inputs("\U0001F600")
        self.assertEqual([(i.type, i.ki.wVk, i.ki.wScan, i.ki.dwFlags) for i in ins], [
            (1, 0, 0xD83D, w.KEYEVENTF_UNICODE), (1, 0, 0xD83D, w.KEYEVENTF_UNICODE | w.KEYEVENTF_KEYUP),
            (1, 0, 0xDE00, w.KEYEVENTF_UNICODE), (1, 0, 0xDE00, w.KEYEVENTF_UNICODE | w.KEYEVENTF_KEYUP)])
        self.assertEqual(len(w.unicode_inputs("a")), 2)

    def test_vk_flags(self):
        w = self.w
        self.assertEqual(w.vk_flags(0x41, False), 0)
        self.assertEqual(w.vk_flags(0x41, True), w.KEYEVENTF_KEYUP)
        for vk in (0x25, 0x26, 0x27, 0x28, 0x2E, 0x2D, 0x24, 0x23, 0x21, 0x22, 0x5B):
            self.assertTrue(w.vk_flags(vk, False) & w.KEYEVENTF_EXTENDEDKEY, hex(vk))

    def test_normalize_hits_every_pixel(self):
        w = self.w
        for size in (1920, 1080, 1280, 3840):
            for v in range(size):
                n = w.normalize_abs(v, 0, size)
                self.assertTrue(0 <= n <= 65535)
                self.assertEqual(n * size // 65536, v, (size, v))
        self.assertEqual(w.normalize_abs(-1920, -1920, 3840), w.normalize_abs(0, 0, 3840))
        self.assertEqual(w.normalize_abs(5, 0, 1), 0)

    def test_mouse_input(self):
        w = self.w
        i = w.mouse_input(100, 200, w.MOVE_FLAGS)
        self.assertEqual((i.type, i.mi.dx, i.mi.dy, i.mi.dwFlags), (0, 100, 200, 0xC001))
        self.assertEqual(set(w.BUTTON_FLAGS), {(b, u) for b in ("left", "right", "middle") for u in (False, True)})

    def test_every_function_has_argtypes_and_restype(self):
        w = self.w
        names = ["SendInput", "MapVirtualKeyW", "VkKeyScanW", "GetAsyncKeyState", "keybd_event", "GetCursorPos",
                 "SetCursorPos", "GetSystemMetrics", "EnumWindows", "IsWindow", "IsWindowVisible", "IsIconic", "GetWindowTextLengthW",
                 "GetWindowTextW", "GetClassNameW", "ShowWindow", "SetForegroundWindow", "GetForegroundWindow",
                 "BringWindowToTop", "GetDC", "ReleaseDC", "CreateCompatibleDC", "DeleteDC", "CreateCompatibleBitmap",
                 "SelectObject", "DeleteObject", "BitBlt", "GetDIBits", "GetDeviceCaps", "GetCurrentProcessId",
                 "ProcessIdToSessionId", "CreateJobObjectW", "SetInformationJobObject", "AssignProcessToJobObject",
                 "GetUserNameW", "GetDpiForSystem", "SetProcessDpiAwarenessContext", "SetProcessDPIAware",
                 "DwmGetWindowAttribute", "CreateToolhelp32Snapshot", "Process32FirstW", "Process32NextW",
                 "OpenProcess", "CloseHandle", "GetProcessTimes", "K32GetProcessMemoryInfo"]
        for name in names:
            f = getattr(w, name)
            if f is None:   # optional on old Windows
                continue
            with self.subTest(name=name):
                self.assertIsNotNone(f.argtypes)
                self.assertTrue(hasattr(f, "restype"))
        self.assertIsNone(w.keybd_event.restype)
        self.assertIs(w.SendInput.restype, ctypes.c_uint)

    def test_desktop_is_complete(self):
        # constructing it calls nothing; abstract methods missing would raise TypeError here
        d = self.w.Win32Desktop()
        self.assertIsNone(d._job)


if __name__ == "__main__":
    unittest.main()
