"""The director's HTTP server end to end: the real ThreadingHTTPServer on 127.0.0.1 port 0, with the fake desktop,
a fake ffmpeg and a fake clock, in a temp root folder."""

import base64
import http.client
import json
import os
import random
import shutil
import struct
import sys
import tempfile
import threading
import time
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from director_fakes import GIB, NO_FRAME, FakeClock, FakeDesktop, FakePopen  # noqa: E402

from vm_director import VERSION  # noqa: E402
from vm_director.app import Director  # noqa: E402
from vm_director.desktop import DesktopError  # noqa: E402
from vm_director.record import Recorder  # noqa: E402
from vm_director.server import MAX_BODY, RequestLog, TokenFile, make_server  # noqa: E402

TOKEN = "t0k3n-0123456789abcdef-ZYXWVU"
WT_WINDOW = (42, "Windows PowerShell", "CASCADIA_HOSTING_WINDOW_CLASS")
NO_RECORDING = {"active": False, "filename": None, "started": None, "ended_early": False, "ended_s_ago": None}


class ServerCase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vmdir-srv-")
        os.makedirs(os.path.join(self.root, "out"))
        os.makedirs(os.path.join(self.root, "bin"))
        with open(os.path.join(self.root, "bin", "ffmpeg.exe"), "wb") as f:
            f.write(b"MZ fake")
        self.write_token(TOKEN)
        self.clock = FakeClock(1000.0)
        self.desk = FakeDesktop(self.clock)
        self.popen = FakePopen()
        self.which = {}
        self.isfile_ok = set()
        self.environ = {"LOCALAPPDATA": r"C:\Users\student\AppData\Local", "SystemRoot": r"C:\Windows"}
        self.recorder = Recorder(self.root, popen=self.popen, clock=self.clock, now=lambda: "2026-10-11T10:00:00Z")
        self.app = Director(self.root, self.desk, recorder=self.recorder, rng=random.Random(5),
                            sleep=self.clock.sleep, clock=self.clock,
                            which=lambda n: self.which.get(n), environ=self.environ,
                            isfile=lambda p: p in self.isfile_ok)
        self.server = make_server(self.app, self.root, 0)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()

    def tearDown(self):
        if self.recorder.active():
            self.recorder.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        shutil.rmtree(self.root, ignore_errors=True)

    def write_token(self, token, raw=None):
        path = os.path.join(self.root, "token.txt")
        with open(path, "wb") as f:
            f.write(raw if raw is not None else token.encode())

    def request(self, path, body=None, *, token=TOKEN, method="POST", host=None, headers=None, raw=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=20)
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else b"")
        conn.putrequest(method, path, skip_host=host is not None, skip_accept_encoding=True)
        if host is not None:
            conn.putheader("Host", host)
        if token is not None:
            conn.putheader("Authorization", f"Bearer {token}")
        for k, v in (headers.items() if isinstance(headers, dict) else headers or ()):   # a list may repeat a name
            conn.putheader(k, v)
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(len(data)))
        conn.endheaders(data)
        resp = conn.getresponse()
        text = resp.read()
        status = resp.status
        ctype = resp.getheader("Content-Type")
        conn.close()
        if method == "HEAD":
            return status, None
        self.assertEqual(ctype, "application/json; charset=utf-8")
        return status, json.loads(text)

    def ok(self, path, body=None):
        status, r = self.request(path, body)
        self.assertEqual(status, 200, r)
        self.assertTrue(r["ok"], r)
        return r

    def fails(self, path, body, error="bad-request", contains=None):
        status, r = self.request(path, body)
        self.assertEqual(status, 200, r)
        self.assertFalse(r["ok"], r)
        self.assertEqual(r["error"], error, r)
        self.assertIsInstance(r["detail"], str)
        self.assertTrue(r["detail"].isprintable(), r)
        if contains:
            self.assertIn(contains, r["detail"])
        return r

    def log_text(self):
        with open(os.path.join(self.root, "out", "director.log"), encoding="utf-8") as f:
            return f.read()

    def logged(self, needle, timeout=5.0):
        """True once the log holds `needle` (the server writes a request's line just after its answer)."""
        def has():
            try:
                return needle in self.log_text()
            except OSError:
                return False
        return wait_until(has, timeout)


class Protocol(ServerCase):
    def test_401_without_or_with_wrong_token(self):
        for token in (None, "", "wrong-token-but-long-enough", TOKEN + "x", TOKEN[:-1]):
            with self.subTest(token=token):
                status, r = self.request("/health", token=token)
                self.assertEqual(status, 401)
                self.assertEqual(r["error"], "unauthorized")
        status, r = self.request("/health", headers={"Authorization": f"Basic {TOKEN}"}, token=None)
        self.assertEqual(status, 401)
        status, r = self.request("/nope", token=None)
        self.assertEqual(status, 401)   # the path is not revealed before auth

    def test_token_file_rules(self):
        os.remove(os.path.join(self.root, "token.txt"))
        self.assertEqual(self.request("/health")[0], 401)   # missing file: everything 401
        self.write_token("")
        self.assertEqual(self.request("/health")[0], 401)   # empty
        self.write_token("short")
        self.assertEqual(self.request("/health", token="short")[0], 401)   # under 16 characters
        self.write_token(None, raw=b"\xef\xbb\xbf" + TOKEN.encode() + b"\r\n")   # UTF-8 BOM and CRLF
        self.assertEqual(self.request("/health")[0], 200)
        self.write_token(None, raw=("\ufeff" + "u16-token-0123456789" + "\r\n").encode("utf-16-le"))
        self.assertEqual(self.request("/health", token="u16-token-0123456789")[0], 200)
        self.assertEqual(self.request("/health")[0], 401)

    def test_token_reread_when_file_changes(self):
        self.assertEqual(self.request("/health")[0], 200)
        new = "a-brand-new-token-0123456789"
        self.write_token(new + "\n")
        path = os.path.join(self.root, "token.txt")
        st = os.stat(path)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 5_000_000_000))
        self.assertEqual(self.request("/health", token=new)[0], 200)
        self.assertEqual(self.request("/health")[0], 401)

    def test_405(self):
        for method in ("GET", "PUT", "DELETE", "PATCH", "OPTIONS"):
            with self.subTest(method=method):
                status, r = self.request("/health", method=method)
                self.assertEqual(status, 405)
                self.assertEqual(r["error"], "method-not-allowed")
        self.assertEqual(self.request("/health", method="HEAD")[0], 405)

    def test_404(self):
        for path in ("/", "/nope", "/health/", "/health?x=1", "/record", "/HEALTH"):
            with self.subTest(path=path):
                status, r = self.request(path, {})
                self.assertEqual(status, 404)
                self.assertEqual(r["error"], "not-found")

    def test_413(self):
        big = json.dumps({"text": "x" * (MAX_BODY + 10)}).encode()
        status, r = self.request("/type", raw=big)
        self.assertEqual(status, 413)
        self.assertEqual(r["error"], "too-large")
        self.assertEqual([e for e in self.desk.log if e[0] == "char"], [])
        just = json.dumps({"text": "y" * (MAX_BODY - 20)}).encode()
        self.assertLessEqual(len(just), MAX_BODY)
        status, r = self.request("/type", raw=just)
        self.assertEqual(status, 200)   # within 64 KiB: the body is read (and refused for its length)
        self.assertEqual(r["error"], "bad-request")

    def test_403_origin_and_host(self):
        status, r = self.request("/health", headers={"Origin": "http://evil.example"})
        self.assertEqual(status, 403)
        self.assertEqual(r["error"], "forbidden")
        for host in ("evil.example", f"evil.example:{self.port}", "127.0.0.1", f"127.0.0.1:{self.port + 1}",
                     f"192.168.10.50:{self.port}", f"[::1]:{self.port}", ""):
            with self.subTest(host=host):
                self.assertEqual(self.request("/health", host=host)[0], 403)
        self.assertEqual(self.request("/health", host=f"localhost:{self.port}")[0], 200)
        self.assertEqual(self.request("/health", host=f"LOCALHOST:{self.port}")[0], 200)
        self.assertEqual(self.request("/health", host=f"127.0.0.1:{self.port}")[0], 200)

    def test_400_bad_json(self):
        for raw in (b"{", b"[1, 2]", b'"text"', b"\xff\xfe{}", b'{"cps": NaN, "text": "a"}', b"null"):
            with self.subTest(raw=raw):
                status, r = self.request("/type", raw=raw)
                self.assertEqual(status, 400)
                self.assertEqual(r["error"], "bad-json")

    def test_empty_body_is_an_empty_object(self):
        status, r = self.request("/health", raw=b"")
        self.assertEqual((status, r["ok"]), (200, True))
        status, r = self.request("/health", raw=b"\xef\xbb\xbf{}")
        self.assertEqual((status, r["ok"]), (200, True))

    def test_binds_loopback_only(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")

    def test_log_lines_without_token_or_payload(self):
        self.ok("/type", {"text": "secret-payload-text"})
        self.request("/health", token="wrong-token-0123456789")
        self.assertTrue(self.logged("/health status=401"))
        log = self.log_text()
        self.assertIn("/type status=200 ok=true ms=", log)
        self.assertIn("/health status=401 ok=false error=unauthorized", log)
        self.assertNotIn("secret-payload-text", log)
        self.assertNotIn(TOKEN, log)
        self.assertNotIn("wrong-token", log)

    def test_internal_error_has_no_stack_trace(self):
        self.desk.session_error = RuntimeError("boom secret-detail")
        status, r = self.request("/health")
        self.assertEqual(status, 200)
        self.assertEqual(r["error"], "internal")
        self.assertIn("RuntimeError", r["detail"])
        self.assertNotIn("boom", json.dumps(r))
        self.assertNotIn("Traceback", json.dumps(r))
        log = self.log_text()
        self.assertIn("internal error: RuntimeError at", log)
        self.assertNotIn("secret-detail", log)


class Endpoints(ServerCase):
    def test_health(self):
        r = self.ok("/health")
        self.assertEqual(r, {"ok": True, "version": VERSION, "session_id": 1, "user": "student", "width": 1920,
                             "height": 1080, "resolution": "1920x1080", "scaling": 100,
                             "recording": NO_RECORDING, "ffmpeg": True, "free_gb": 100.0, "typing": "unicode"})
        self.desk._dpi = 144
        self.assertEqual(self.ok("/health")["scaling"], 150)
        self.fails("/health", {"x": 1}, contains="unknown field 'x'")

    def test_type(self):
        r = self.ok("/type", {"text": "Hi, you.", "cps": 20, "jitter": 0.1, "enter": True})
        self.assertEqual(r["chars"], 8)
        self.assertGreater(r["seconds"], 0)
        chars = "".join(e[1] for e in self.desk.log if e[0] == "char")
        self.assertEqual(chars, "Hi, you.")
        self.assertEqual([e for e in self.desk.log if e[0] == "vk"][-2:], [("vk", 0x0D, False), ("vk", 0x0D, True)])
        self.assertEqual(self.ok("/type", {"text": "x"})["chars"], 1)   # defaults
        self.ok("/type", {"text": "\u4e2d\U0001F600", "cps": 1, "jitter": 0})
        self.ok("/type", {"text": "a" * 8192, "cps": 60})

    def test_type_validation(self):
        bad = [
            ({}, "text is required"),
            ({"text": 5}, "text must be a string"),
            ({"text": "a" * 8193}, "at most 8192"),
            ({"text": "a\x07"}, "U+0007"),
            ({"text": "a", "cps": 0}, "cps must be between 1 and 60"),
            ({"text": "a", "cps": 61}, "cps"),
            ({"text": "a", "cps": "14"}, "cps must be a number"),
            ({"text": "a", "cps": True}, "cps must be a number"),
            ({"text": "a", "jitter": 0.95}, "jitter"),
            ({"text": "a", "jitter": -0.1}, "jitter"),
            ({"text": "a", "enter": 1}, "enter must be true or false"),
            ({"text": "a", "enter": "true"}, "enter must be true or false"),
            ({"text": "a", "enter": None}, "must not be null"),
            ({"text": "a", "speed": 3}, "unknown field 'speed'"),
        ]
        for body, msg in bad:
            with self.subTest(body=body):
                self.fails("/type", body, contains=msg)
        self.assertEqual([e for e in self.desk.log if e[0] == "char"], [])

    def test_key(self):
        r = self.ok("/key", {"combo": "ctrl+shift+p"})
        self.assertEqual(r["chords"], 1)
        self.assertEqual(self.ok("/key", {"combo": "down", "repeat": 3})["chords"], 3)
        vks = [e for e in self.desk.log if e[0] == "vk"]
        self.assertEqual(vks[:3], [("vk", 0x11, False), ("vk", 0x10, False), ("vk", 0x50, False)])
        for body, msg in [({"combo": "hyper+x"}, "unknown key"), ({"combo": ""}, "combo"),
                          ({"combo": "a", "repeat": 0}, "repeat"), ({"combo": "a", "repeat": 101}, "repeat"),
                          ({"combo": "a", "repeat": True}, "repeat must be an integer"),
                          ({"combo": "a", "repeat": 2.0}, "repeat must be an integer"),
                          ({"combo": "ctrl+alt+del"}, "human step"), ({}, "combo is required")]:
            with self.subTest(body=body):
                self.fails("/key", body, contains=msg)

    def test_click(self):
        self.desk.cursor = (0, 0)
        r = self.ok("/click", {"x": 1919, "y": 1079})
        self.assertEqual((r["x"], r["y"], r["button"], r["double"], r["from"]), (1919, 1079, "left", False, [0, 0]))
        self.assertEqual(self.desk.cursor, (1919, 1079))
        self.ok("/click", {"x": 0, "y": 0, "button": "middle", "double": True, "move_ms": 0})
        buttons = [e for e in self.desk.log if e[0] == "button"]
        self.assertEqual(len(buttons), 2 + 4)
        for body, msg in [({"x": 1920, "y": 5}, "inside the screen"), ({"x": -1, "y": 5}, "inside the screen"),
                          ({"x": 5, "y": 1080}, "inside the screen"), ({"x": 5.0, "y": 5}, "x must be an integer"),
                          ({"x": 5}, "y is required"), ({"x": 5, "y": 5, "button": "back"}, "button must be one of"),
                          ({"x": 5, "y": 5, "move_ms": 5001}, "move_ms"), ({"x": 5, "y": 5, "double": "no"}, "double")]:
            with self.subTest(body=body):
                self.fails("/click", body, contains=msg)

    def test_wait_for(self):
        self.desk.windows = [(1, "Windows PowerShell", "ConsoleWindowClass")]
        r = self.ok("/wait_for", {"window_title": "PowerShell$"})
        self.assertEqual((r["found"], r["title"], r["waited_s"]), (True, "Windows PowerShell", 0.0))
        r = self.fails("/wait_for", {"window_title": "PowerShell", "timeout_s": 2, "gone": True}, error="timeout")
        self.assertEqual(r["waited_s"], 2.0)
        r = self.ok("/wait_for", {"window_title": "Notepad", "gone": True})
        self.assertEqual((r["found"], r["title"]), (False, None))
        r = self.fails("/wait_for", {"window_title": "Notepad", "timeout_s": 600}, error="timeout")
        self.assertEqual(r["waited_s"], 600.0)
        for body, msg in [({"window_title": "("}, "not a valid regex"), ({"window_title": "x" * 201}, "200"),
                          ({"window_title": "x", "timeout_s": 0.5}, "timeout_s"),
                          ({"window_title": "x", "timeout_s": 601}, "timeout_s"),
                          ({"window_title": "x", "gone": 0}, "gone must be true or false"), ({}, "window_title")]:
            with self.subTest(body=body):
                self.fails("/wait_for", body, contains=msg)

    def test_screenshot(self):
        w, h = 4, 3
        self.desk.image = (w, h, bytes((i * 11) & 0xFF for i in range(w * h * 4)))
        r = self.ok("/screenshot")
        self.assertEqual((r["width"], r["height"]), (4, 3))
        png = base64.b64decode(r["png_b64"])
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        n = struct.unpack(">I", png[33:37])[0]
        self.assertEqual(png[37:41], b"IDAT")
        raw = zlib.decompress(png[41:41 + n])
        bgra = self.desk.image[2]
        self.assertEqual(raw[1:4], bytes([bgra[2], bgra[1], bgra[0]]))
        self.fails("/screenshot", {"region": [0, 0, 1, 1]}, contains="unknown field")

    def test_marker_validation(self):
        self.fails("/marker", {"label": "x"}, error="not-recording")
        for body, msg in [({"label": ""}, "label"), ({"label": "a\nb"}, "printable"), ({"label": "x" * 101}, "100"),
                          ({}, "label is required"), ({"label": 3}, "string")]:
            with self.subTest(body=body):
                self.fails("/marker", body, contains=msg)
        self.fails("/record/stop", {}, error="not-recording")

    def test_busy_when_another_input_action_runs(self):
        self.app.input_lock_timeout_s = 0.05
        self.assertTrue(self.app.input_lock.acquire())
        try:
            self.fails("/type", {"text": "x"}, error="busy")
            self.fails("/click", {"x": 1, "y": 1}, error="busy")
            self.ok("/health")   # not an input action
            self.ok("/screenshot")
        finally:
            self.app.input_lock.release()
        self.ok("/type", {"text": "x"})


class Recording(ServerCase):
    def test_full_run(self):
        r = self.ok("/record/start", {"filename": "smoke.mkv"})
        out = os.path.join(self.root, "out")
        self.assertEqual(r["path"], os.path.join(out, "smoke.mkv"))
        self.assertEqual(r["markers"], os.path.join(out, "smoke.markers.json"))
        self.assertTrue(r["first_frame"])
        p = self.popen.procs[0]
        self.assertEqual(p.argv[p.argv.index("-framerate") + 1], "30")
        self.assertEqual(p.argv[p.argv.index("-crf") + 1], "20")
        self.assertEqual(p.argv[p.argv.index("-preset") + 1], "ultrafast")
        h = self.ok("/health")["recording"]
        self.assertEqual(h, {"active": True, "filename": "smoke.mkv", "started": "2026-10-11T10:00:00Z",
                             "ended_early": False, "ended_s_ago": None})
        self.fails("/record/start", {"filename": "other.mkv"}, error="already-recording")
        self.clock.advance(2.5)
        self.assertEqual(self.ok("/marker", {"label": "winget-version"})["t"], 2.54)
        res = self.ok("/record/stop")
        self.assertEqual((res["duration_s"], res["size_bytes"], res["marker_count"]), (5.0, 1234, 1))
        self.assertEqual(res["markers"], os.path.join(out, "smoke.markers.json"))
        with open(res["markers"]) as f:
            self.assertEqual(json.load(f), [{"t": 2.54, "label": "winget-version"}])
        self.assertFalse(self.ok("/health")["recording"]["active"])
        self.fails("/record/start", {"filename": "smoke.mkv"}, error="file-exists")
        self.ok("/record/start", {"filename": "take2.mkv", "fps": 60, "crf": 0, "preset": "fast"})
        self.ok("/record/stop")

    def test_refusals(self):
        self.desk.width, self.desk.height = 1280, 720
        self.fails("/record/start", {"filename": "a.mkv"}, error="bad-resolution", contains="1280x720")
        self.desk.width, self.desk.height = 1920, 1080
        self.desk._dpi = 144
        self.fails("/record/start", {"filename": "a.mkv"}, error="bad-scaling", contains="150")
        self.desk._dpi = 96
        self.desk.free = 2 * GIB - 1
        self.fails("/record/start", {"filename": "a.mkv"}, error="low-disk")
        self.desk.free = 2 * GIB
        os.remove(os.path.join(self.root, "bin", "ffmpeg.exe"))
        self.fails("/record/start", {"filename": "a.mkv"}, error="no-ffmpeg")
        self.assertFalse(self.ok("/health")["ffmpeg"])
        self.assertEqual(self.popen.procs, [])

    def test_payload_validation(self):
        for body, msg in [({}, "filename is required"), ({"filename": "a.mp4"}, "filename must match"),
                          ({"filename": "..\\a.mkv"}, "filename must match"), ({"filename": "nul.mkv"}, "reserved"),
                          ({"filename": "a.mkv", "fps": 4}, "fps"), ({"filename": "a.mkv", "fps": 61}, "fps"),
                          ({"filename": "a.mkv", "crf": 52}, "crf"), ({"filename": "a.mkv", "preset": "slow"}, "preset"),
                          ({"filename": "a.mkv", "fps": "30"}, "fps must be an integer")]:
            with self.subTest(body=body):
                self.fails("/record/start", body, contains=msg)
        self.fails("/record/stop", {"now": True}, contains="unknown field")

    def test_record_start_without_a_first_frame(self):
        self.popen.opts = {"start": NO_FRAME}   # ffmpeg runs but no frame comes
        self.recorder.first_frame_wait_s = 30
        self.recorder.stop_grace_s = 0.1
        t = time.monotonic()
        status, r = self.request("/record/start", {"filename": "nf.mkv"}, headers={"X-Vmb-Timeout": "5"})
        # deadline = start + 3 s; less the 0.1 s grace and 2 s of cleanup: a 0.9 s wait, not 30 s
        self.assertEqual((status, r["ok"], r["error"]), (200, False, "no-first-frame"), r)
        self.assertLess(time.monotonic() - t, 10)
        self.assertIn("no frame within 0.9 s", r["detail"])
        self.assertEqual(self.ok("/health")["recording"], NO_RECORDING)
        self.popen.opts = {}
        self.assertTrue(self.ok("/record/start", {"filename": "nf.mkv"})["first_frame"])   # the retry works
        self.ok("/record/stop")

    def test_a_recording_that_ended_by_itself(self):
        # gdigrab after a failed screen grab (the UAC secure desktop): ffmpeg finishes the file and exits 0
        self.ok("/record/start", {"filename": "uac.mkv"})
        self.popen.procs[0].end_by_itself(code=0, out_us=12_000_000)
        self.assertTrue(wait_until(lambda: self.recorder._session.eof))
        self.clock.advance(600.0)   # the chapter goes on for ten minutes
        h = self.ok("/health")["recording"]
        self.assertEqual(h, {"active": False, "filename": "uac.mkv", "started": "2026-10-11T10:00:00Z",
                             "ended_early": True, "ended_s_ago": 600.0, "exit_code": 0})
        self.fails("/marker", {"label": "step-4"}, error="not-recording", contains="ended by itself 600 s ago")
        r = self.fails("/record/stop", {}, error="ended-early", contains="600 s before the stop")
        self.assertEqual((r["duration_s"], r["exit_code"], r["ended_s_before_stop"], r["killed"]), (12.0, 0, 600.0, False))
        self.assertGreater(r["size_bytes"], 0)
        self.assertIn("the video ends at 12 s", r["detail"])
        self.assertEqual(self.ok("/health")["recording"], NO_RECORDING)


class RunVisible(ServerCase):
    def test_existing_terminal(self):
        self.desk.windows = [(5, "Notepad", "Notepad"), (9, "Windows PowerShell", "CASCADIA_HOSTING_WINDOW_CLASS")]
        r = self.ok("/run_visible", {"command": "winget --version"})
        self.assertEqual((r["title"], r["class"], r["launched"], r["chars"]),
                         ("Windows PowerShell", "CASCADIA_HOSTING_WINDOW_CLASS", False, 16))
        self.assertEqual(self.desk.focused, [9])
        self.assertEqual(self.desk.launched, [])
        log = [e for e in self.desk.log if e[0] != "sleep"]
        focus_at = log.index(("focus", 9))
        typed = "".join(e[1] for e in log[focus_at:] if e[0] == "char")
        self.assertEqual(typed, "winget --version")
        self.assertEqual(log[-2:], [("vk", 0x0D, False), ("vk", 0x0D, True)])
        self.assertNotIn("shell", r)          # nothing launched, so no shell to wait for
        self.assertEqual(self.desk.shell_calls, [])
        self.assertEqual(self.desk.modifier_releases, [])

    def launch_wt(self, after_s=0.0):
        """wt.exe on PATH; its window shows `after_s` fake seconds after the launch."""
        self.which["wt.exe"] = r"C:\bin\wt.exe"

        def appear(desk):
            when = desk.clock() + after_s
            desk.windows = lambda now: [WT_WINDOW] if now >= when else []
        self.desk.on_launch = appear

    def after_launch(self, shells):
        """shells(now) once the terminal was launched; no shell before that."""
        return lambda now: shells(now) if self.desk.launched else {}

    def elapsed_before_first_char(self):
        log = self.desk.log
        first = next(i for i, e in enumerate(log) if e[0] == "char")
        return sum(e[1] for e in log[:first] if e[0] == "sleep")

    def test_launches_windows_terminal(self):
        wt = r"C:\Users\student\AppData\Local\Microsoft\WindowsApps\wt.exe"
        self.isfile_ok.add(wt)   # not on PATH, but the app execution alias exists

        def appear(desk):
            desk.windows = [WT_WINDOW]
        self.desk.on_launch = appear
        r = self.ok("/run_visible", {"command": "Get-Date"})
        self.assertTrue(r["launched"])
        self.assertEqual(self.desk.launched, [([wt], False)])
        self.assertEqual(self.desk.focused, [42])
        # The fake desktop cannot tell the shell's state: the fixed settle pause instead.
        self.assertEqual((r["window_s"], r["shell"]), (0.0, "unknown"))
        self.assertIn(("sleep", 1.5), self.desk.log)

    def test_waits_until_the_new_shell_is_idle(self):
        self.launch_wt()
        t0 = self.clock()

        def shells(now):
            procs = {101: (5.0 + (now - t0) * 0.2, 9000 + int((now - t0) * 50))}   # busy, but there before the launch
            if not self.desk.launched or now < t0 + 3:
                return procs                          # a blank pane: no new shell yet
            busy = min(now, t0 + 8) - (t0 + 3)        # loading for 5 s: CPU time and page faults climb
            procs[202] = (busy * 0.5, int(busy * 400))
            return procs
        self.desk.shells = shells
        r = self.ok("/run_visible", {"command": "Get-Date"})
        self.assertEqual(r["shell"], "ready")   # shell 101 never counted: it was running before the launch
        self.assertGreaterEqual(r["shell_wait_s"], 10.0)   # 8 s of loading, then 2 s idle
        self.assertLess(r["shell_wait_s"], 10.5)
        self.assertEqual(self.desk.shell_calls[0][1], 0)   # the shells were listed before the launch
        self.assertGreaterEqual(self.elapsed_before_first_char(), 10.0)
        self.assertEqual("".join(e[1] for e in self.desk.log if e[0] == "char"), "Get-Date")

    def test_a_stalled_new_shell_is_not_ready(self):
        # Created at 0.5 s, then blocked for 1.7 s (a module load waiting on a virus scan or the disk: no CPU, no
        # page faults), then it really loads for 10 s. Quiet only counts after 0.3 s of CPU.
        self.launch_wt()
        t0 = self.clock()

        def shells(now):
            dt = now - t0
            if dt < 0.5:
                return {}
            if dt < 2.2:
                return {7: (0.02, 300)}
            load = min(dt, 12.2) - 2.2
            return {7: (0.02 + load * 0.4, 300 + int(load * 500))}
        self.desk.shells = self.after_launch(shells)
        r = self.ok("/run_visible", {"command": "Get-Date"})
        self.assertEqual(r["shell"], "ready")
        self.assertGreaterEqual(r["shell_wait_s"], 14.2)   # loading ends at 12.2 s, then 2 s idle
        self.assertLess(r["shell_wait_s"], 14.6)
        self.assertGreaterEqual(self.elapsed_before_first_char(), 14.2)

    def test_a_shell_below_the_cpu_floor_is_typed_into_after_the_wait(self):
        self.launch_wt()   # cmd.exe as the terminal's profile: idle at once, but far under 0.3 s of CPU
        self.desk.shells = self.after_launch(lambda now: {8: (0.05, 120)})
        r = self.ok("/run_visible", {"command": "dir"})
        self.assertEqual(r["shell"], "busy")
        self.assertGreaterEqual(r["shell_wait_s"], 60)
        self.assertEqual("".join(e[1] for e in self.desk.log if e[0] == "char"), "dir")

    def test_shells_from_before_the_launch_are_not_the_new_one(self):
        self.launch_wt()
        self.desk.shells = lambda now: {5: (2.0, 100)}   # one idle shell, there before and after: no new shell
        r = self.ok("/run_visible", {"command": "dir"})
        self.assertEqual(r["shell"], "none")
        self.assertGreaterEqual(r["shell_wait_s"], 60)

    def test_a_shell_that_never_settles_is_typed_into_after_the_wait(self):
        self.launch_wt()
        self.desk.shells = self.after_launch(lambda now: {9: (now * 0.5, int(now * 400))})
        r = self.ok("/run_visible", {"command": "dir"})
        self.assertEqual(r["shell"], "busy")
        self.assertGreaterEqual(r["shell_wait_s"], 60)
        self.assertEqual("".join(e[1] for e in self.desk.log if e[0] == "char"), "dir")

    def test_no_shell_in_time(self):
        self.launch_wt()
        self.desk.shells = lambda now: {}
        r = self.ok("/run_visible", {"command": "dir"})
        self.assertEqual(r["shell"], "none")
        self.assertGreaterEqual(r["shell_wait_s"], 60)

    def test_a_second_shell_restarts_the_quiet_time(self):
        self.launch_wt()
        t0 = self.clock()
        # one idle shell from the start; a second one appears at 1 s (a profile that starts two) and idles at once
        self.desk.shells = self.after_launch(
            lambda now: {1: (0.5, 100)} if now < t0 + 1 else {1: (0.5, 100), 2: (0.1, 50)})
        r = self.ok("/run_visible", {"command": "dir"})
        self.assertEqual(r["shell"], "ready")
        self.assertGreaterEqual(r["shell_wait_s"], 3.0)
        self.assertLess(r["shell_wait_s"], 3.5)

    def test_typing_stops_when_the_terminal_loses_the_foreground(self):
        self.desk.windows = [(9, "Windows PowerShell", "CASCADIA_HOSTING_WINDOW_CLASS")]
        self.desk.on_char = lambda d, n: setattr(d, "fg", 77) if n == 3 else None   # a window pops up
        r = self.fails("/run_visible", {"command": "Get-Date"}, error="focus-lost", contains="after 3 of 8")
        self.assertEqual(r["chars"], 3)
        self.assertEqual("".join(e[1] for e in self.desk.log if e[0] == "char"), "Get")
        self.assertNotIn(("vk", 0x0D, False), self.desk.log)   # never Enter
        self.assertEqual(len(self.desk.modifier_releases), 1)
        self.desk.fg = 0
        self.assertEqual(self.ok("/type", {"text": "abc"})["chars"], 3)   # /type does not check the foreground

    def test_deadline_during_the_shell_wait_types_nothing(self):
        self.launch_wt()
        self.desk.shells = self.after_launch(lambda now: {9: (now * 0.5, int(now * 400))})   # never settles
        status, r = self.request("/run_visible", {"command": "dir"}, headers={"X-Vmb-Timeout": "30"})
        self.assertEqual((status, r["ok"], r["error"], r["chars"]), (200, False, "deadline", 0))
        self.assertEqual([e for e in self.desk.log if e[0] in ("char", "vk")], [])

    def test_a_slow_window_within_the_launch_wait(self):
        self.launch_wt(after_s=40.0)   # a cold start behind the disk cap
        r = self.ok("/run_visible", {"command": "dir"})
        self.assertTrue(r["launched"])
        self.assertGreaterEqual(r["window_s"], 40.0)
        self.assertLess(r["window_s"], 40.5)

    def test_launches_powershell_without_terminal(self):
        def appear(desk):
            when = desk.clock() + 1.0   # the console window shows up a second later
            desk.windows = lambda now: [(7, "Windows PowerShell", "ConsoleWindowClass")] if now >= when else []
        self.desk.on_launch = appear
        r = self.ok("/run_visible", {"command": "dir"})
        self.assertEqual(self.desk.launched,
                         [([r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"], True)])
        self.assertEqual((r["class"], r["launched"]), ("ConsoleWindowClass", True))
        self.which["wt.exe"] = r"C:\bin\wt.exe"
        self.assertEqual(self.app.terminal_argv(), ([r"C:\bin\wt.exe"], False))

    def test_no_terminal_appears(self):
        r = self.fails("/run_visible", {"command": "dir"}, error="no-terminal")
        self.assertIn("90 s", r["detail"])
        self.assertEqual([e for e in self.desk.log if e[0] == "char"], [])

    def test_focus_failure_types_nothing(self):
        self.desk.windows = [(9, "PowerShell", "ConsoleWindowClass")]
        self.desk.focus_ok = False
        self.fails("/run_visible", {"command": "Remove-Item x"}, error="focus-failed")
        self.assertEqual([e for e in self.desk.log if e[0] in ("char", "vk")], [])

    def test_validation(self):
        for body, msg in [({}, "command is required"), ({"command": ""}, "command"),
                          ({"command": "x" * 4097}, "4096"), ({"command": "a\x00b"}, "U+0000"),
                          ({"command": "dir", "cps": 5}, "unknown field")]:
            with self.subTest(body=body):
                self.fails("/run_visible", body, contains=msg)


class SignalLock:
    """A lock that says when someone starts waiting for it."""

    def __init__(self):
        self.lock = threading.Lock()
        self.waiting = threading.Event()

    def acquire(self, timeout=-1):
        self.waiting.set()
        return self.lock.acquire(timeout=timeout)

    def release(self):
        self.lock.release()


class Deadlines(ServerCase):
    """X-Vmb-Timeout: deadline = the request's start (fake clock 1000.0) + timeout - 2 s."""

    def deadline_request(self, path, body, timeout="5"):
        status, r = self.request(path, body, headers={"X-Vmb-Timeout": timeout})
        self.assertEqual(status, 200, r)
        return r

    def test_type_stops_at_the_deadline_without_enter(self):
        # one character a second (cps 1, no jitter); the deadline is 3 s after the start
        r = self.deadline_request("/type", {"text": "abcdefghij", "cps": 1, "jitter": 0, "enter": True})
        self.assertEqual((r["ok"], r["error"], r["chars"]), (False, "deadline", 3), r)
        self.assertIn("after 3 of 10 characters", r["detail"])
        self.assertEqual("".join(e[1] for e in self.desk.log if e[0] == "char"), "abc")
        self.assertNotIn(("vk", 0x0D, False), self.desk.log)
        self.assertEqual(len(self.desk.modifier_releases), 1)
        self.assertTrue(self.logged("/type status=200 ok=false error=deadline"))

    def test_key_stops_at_the_deadline(self):
        r = self.deadline_request("/key", {"combo": "down", "repeat": 100})
        self.assertEqual((r["ok"], r["error"]), (False, "deadline"), r)
        self.assertGreater(r["chords"], 0)
        self.assertLess(r["chords"], 100)
        downs = [e for e in self.desk.log if e[0] == "vk" and not e[2]]
        ups = [e for e in self.desk.log if e[0] == "vk" and e[2]]
        self.assertEqual((len(downs), len(ups)), (r["chords"], r["chords"]))   # every chord released
        self.assertEqual(len(self.desk.modifier_releases), 1)

    def test_bad_timeout_values_mean_no_deadline(self):
        for value in ("abc", "0", "901", "5.5", "-5", "", "1e3", "²", "1000"):
            with self.subTest(value=value):
                r = self.deadline_request("/type", {"text": "abcdef", "cps": 1, "jitter": 0}, timeout=value)
                self.assertEqual((r["ok"], r["chars"]), (True, 6), r)
        status, r = self.request("/type", {"text": "abcdef", "cps": 1, "jitter": 0},
                                 headers=[("X-Vmb-Timeout", "5"), ("X-Vmb-Timeout", "5")])
        self.assertEqual((status, r["ok"], r["chars"]), (200, True, 6))   # repeated: no deadline
        r = self.deadline_request("/type", {"text": "abcdef", "cps": 1, "jitter": 0}, timeout=" 900 ")
        self.assertEqual((r["ok"], r["chars"]), (True, 6))
        self.assertEqual(self.desk.modifier_releases, [])

    def test_the_lock_freed_after_the_deadline_does_nothing(self):
        lock = SignalLock()
        self.app.input_lock = lock
        lock.lock.acquire()   # an earlier input action still runs
        results = []
        t = threading.Thread(target=lambda: results.append(
            self.request("/click", {"x": 5, "y": 5, "move_ms": 0}, headers={"X-Vmb-Timeout": "5"})))
        t.start()
        self.assertTrue(lock.waiting.wait(10))   # the request waits for the lock (deadline: start + 3 s)
        self.clock.advance(10.0)                 # the deadline passes while it waits
        lock.lock.release()
        t.join(10)
        status, r = results[0]
        self.assertEqual((status, r["ok"], r["error"]), (200, False, "deadline"), r)
        self.assertIn("nothing was done", r["detail"])
        self.assertEqual([e for e in self.desk.log if e[0] in ("button", "move")], [])
        self.assertTrue(lock.lock.acquire(blocking=False))   # given back
        lock.lock.release()
        self.ok("/click", {"x": 5, "y": 5, "move_ms": 0})

    def test_the_wait_for_the_lock_ends_at_the_deadline(self):
        self.assertTrue(self.app.input_lock.acquire())
        try:
            r = self.deadline_request("/type", {"text": "x"}, timeout="3")   # deadline 1 s after the start
        finally:
            self.app.input_lock.release()
        self.assertEqual((r["ok"], r["error"]), (False, "deadline"), r)
        self.assertEqual([e for e in self.desk.log if e[0] == "char"], [])

    def test_other_endpoints_ignore_the_deadline(self):
        self.desk.windows = [(1, "Notepad", "Notepad")]
        r = self.deadline_request("/wait_for", {"window_title": "Never", "timeout_s": 10}, timeout="3")
        self.assertEqual((r["ok"], r["error"], r["waited_s"]), (False, "timeout", 10.0))
        self.assertTrue(self.deadline_request("/health", {}, timeout="1")["ok"])

    def test_click_stops_during_its_move(self):
        # deadline 3 s after the start; the path takes 5 s
        r = self.deadline_request("/click", {"x": 1500, "y": 900, "move_ms": 5000})
        self.assertEqual((r["ok"], r["error"], r["moved"], r["clicks"]), (False, "deadline", True, 0), r)
        self.assertEqual([e for e in self.desk.log if e[0] == "button"], [])
        self.assertNotEqual(self.desk.cursor, (1500, 900))
        self.assertEqual(len(self.desk.modifier_releases), 1)

    def test_a_release_that_fails_is_reported_and_modifiers_are_released(self):
        self.desk.fail_vk = (0x11, True)   # the Ctrl release is refused
        self.fails("/key", {"combo": "ctrl+s"}, error="input-blocked", contains="keys may be held")
        self.assertIn(("vk", 0x53, True), self.desk.log)   # S was still released
        self.assertEqual(len(self.desk.modifier_releases), 1)


def wait_until(cond, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.01)
    return cond()


class Units(unittest.TestCase):
    def test_request_log_rotation(self):
        d = tempfile.mkdtemp(prefix="vmdir-log-")
        try:
            log = RequestLog(os.path.join(d, "director.log"), max_bytes=200)
            for i in range(20):
                log.write(f"/health status=200 ok=true ms={i}")
            self.assertTrue(os.path.exists(os.path.join(d, "director.log.1")))
            self.assertLessEqual(os.path.getsize(os.path.join(d, "director.log")), 200 + 80)
            self.assertEqual(sorted(os.listdir(d)), ["director.log", "director.log.1"])
            log.write("line\nwith\x00control")
            with open(os.path.join(d, "director.log"), encoding="utf-8") as f:
                last = f.read().splitlines()[-1]
            self.assertTrue(last.endswith("line with control"))
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_token_decode(self):
        self.assertEqual(TokenFile.decode(b"abc\r\n"), "abc")
        self.assertEqual(TokenFile.decode(b"\xef\xbb\xbfabc"), "abc")
        self.assertEqual(TokenFile.decode("\ufeffabc\r\n".encode("utf-16-le")), "abc")
        self.assertEqual(TokenFile.decode("\ufeffabc".encode("utf-16-be")), "abc")

    def test_port_in_use_is_refused(self):
        root = tempfile.mkdtemp(prefix="vmdir-port-")
        try:
            os.makedirs(os.path.join(root, "out"))
            app = Director(root, FakeDesktop(), recorder=Recorder(root, popen=FakePopen()))
            first = make_server(app, root, 0)
            try:
                with self.assertRaises(OSError):
                    make_server(app, root, first.server_address[1])
            finally:
                first.server_close()
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_on_start_releases_modifiers_left_down(self):
        root = tempfile.mkdtemp(prefix="vmdir-start-")
        try:
            desk = FakeDesktop()
            desk.down_modifiers = [0xA2, 0x5B]   # left Ctrl and Win, left down by a director that was killed
            app = Director(root, desk, recorder=Recorder(root, popen=FakePopen()))
            self.assertEqual(desk.modifier_releases, [])   # not at construction
            self.assertEqual(app.on_start(), [0xA2, 0x5B])
            self.assertEqual(len(desk.modifier_releases), 1)

            def broken():
                raise DesktopError("input-blocked", "fake")
            desk.release_modifiers = broken
            self.assertEqual(app.on_start(), [])   # never an exception at start
        finally:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
