"""ffmpeg recording (vm_director.record) with a fake ffmpeg process and a fake clock."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from director_fakes import NO_FRAME, FakeClock, FakePopen  # noqa: E402

from vm_director import record as record_mod  # noqa: E402
from vm_director.record import (CREATE_NO_WINDOW, Recorder, RecordError, filename_problem,  # noqa: E402
                                write_json_atomic)


class Filenames(unittest.TestCase):
    def test_good(self):
        for name in ("smoke.mkv", "p1-ch03.mkv", "a.mkv", "A_b.c-d.mkv", "x" * 64 + ".mkv", "9.mkv"):
            self.assertIsNone(filename_problem(name), name)

    def test_bad(self):
        for name in (".mkv", "smoke.mp4", "smoke.MKV", "-a.mkv", "_a.mkv", ".a.mkv", "x" * 65 + ".mkv",
                     "smoke.mkv\n", "a b.mkv", "../x.mkv", "..\\x.mkv", "C:x.mkv", "dir/x.mkv", "", None, 5,
                     "con.mkv", "NUL.mkv", "com1.mkv", "lpt9.x.mkv", "café.mkv"):
            self.assertIsNotNone(filename_problem(name), repr(name))
        self.assertIsNone(filename_problem("console.mkv"))


class Recording(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vmdir-rec-")
        os.makedirs(os.path.join(self.root, "out"))
        os.makedirs(os.path.join(self.root, "bin"))
        self.clock = FakeClock(1000.0)
        self.popen = FakePopen()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def out(self, name):
        return os.path.join(self.root, "out", name)

    def recorder(self, **kw):
        return Recorder(self.root, popen=self.popen, clock=self.clock, now=lambda: "2026-10-11T10:00:00Z", **kw)

    def test_command_and_popen_arguments(self):
        r = self.recorder()
        res = r.start("smoke.mkv", fps=25, crf=18, preset="veryfast")
        p = self.popen.procs[0]
        self.assertEqual(p.argv, [os.path.join(self.root, "bin", "ffmpeg.exe"), "-hide_banner", "-loglevel", "error",
                                  "-f", "gdigrab", "-framerate", "25", "-draw_mouse", "1", "-i", "desktop",
                                  "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
                                  "-progress", "pipe:1", "-nostats", self.out("smoke.mkv")])
        self.assertIs(p.kwargs["stdin"], subprocess.PIPE)
        self.assertIs(p.kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(p.kwargs["creationflags"], CREATE_NO_WINDOW)
        self.assertEqual(os.path.basename(p.kwargs["stderr"].name), "smoke.ffmpeg.log")
        self.assertTrue(p.kwargs["stderr"].closed)   # the director keeps no handle; ffmpeg has its own
        self.assertEqual(res, {"path": self.out("smoke.mkv"), "filename": "smoke.mkv",
                               "markers": self.out("smoke.markers.json"), "started": "2026-10-11T10:00:00Z",
                               "first_frame": True})
        with open(self.out("smoke.markers.json")) as f:
            self.assertEqual(json.load(f), [])
        r.stop()

    def test_t0_markers_and_stop(self):
        r = self.recorder()
        r.start("smoke.mkv")
        self.assertTrue(r.active())
        # first block with frame >= 1 had out_time_us=40000 at clock 1000.0, so t0 = 999.96
        self.clock.advance(2.5)
        self.assertEqual(r.marker("winget-version"), {"t": 2.54, "count": 1})
        self.clock.advance(1.0)
        self.assertEqual(r.marker("second é"), {"t": 3.54, "count": 2})
        with open(self.out("smoke.markers.json"), encoding="ascii") as f:
            self.assertEqual(json.load(f), [{"t": 2.54, "label": "winget-version"}, {"t": 3.54, "label": "second é"}])
        self.assertFalse(os.path.exists(self.out("smoke.markers.json.tmp")))
        st = r.status()
        self.assertEqual(st, {"active": True, "filename": "smoke.mkv", "started": "2026-10-11T10:00:00Z",
                              "ended_early": False, "ended_s_ago": None})
        res = r.stop()
        p = self.popen.procs[0]
        self.assertEqual(p.stdin.data, b"q")
        self.assertTrue(p.stdin.closed)
        self.assertEqual(res, {"ok": True, "path": self.out("smoke.mkv"), "duration_s": 5.0, "size_bytes": 1234,
                               "markers": self.out("smoke.markers.json"), "marker_count": 2, "exit_code": 0,
                               "killed": False})
        self.assertFalse(r.active())
        self.assertEqual(r.status(), {"active": False, "filename": None, "started": None, "ended_early": False,
                                      "ended_s_ago": None})
        with self.assertRaises(RecordError) as cm:
            r.marker("late")
        self.assertEqual(cm.exception.word, "not-recording")
        with self.assertRaises(RecordError) as cm:
            r.stop()
        self.assertEqual(cm.exception.word, "not-recording")

    def test_start_waits_for_a_real_frame(self):
        # blocks without a frame, and with the "unknown" out_time of older builds, do not end the wait
        self.popen = FakePopen(start="frame=0\nout_time_us=0\nprogress=continue\n"
                                     "frame=0\nout_time_us=-9223372036854775807\nprogress=continue\n")
        r = self.recorder(first_frame_wait_s=10)
        later = threading.Timer(0.3, lambda: self.popen.procs[0].stdout.feed(
            "frame=3\nout_time_ms=100000\nprogress=continue\n"))   # old key name
        later.start()
        t = time.monotonic()
        res = r.start("a.mkv")
        self.assertGreaterEqual(time.monotonic() - t, 0.25)   # answered only once the frame was there
        self.assertTrue(res["first_frame"])
        self.assertAlmostEqual(r._session.t0, 999.9)   # 1000.0 - 0.1
        self.clock.advance(1.0)
        self.assertEqual(r.marker("now"), {"t": 1.1, "count": 1})
        self.assertEqual(r.stop()["duration_s"], 5.0)

    def test_no_first_frame_stops_ffmpeg_and_leaves_no_session(self):
        self.popen = FakePopen(start=NO_FRAME)
        r = self.recorder(first_frame_wait_s=0.2)
        with self.assertRaises(RecordError) as cm:
            r.start("blank.mkv")
        self.assertEqual(cm.exception.word, "no-first-frame")
        self.assertIn("no frame within 0.2 s and was stopped (exit code 0)", cm.exception.detail)
        self.assertIn("blank.ffmpeg.log", cm.exception.detail)
        p = self.popen.procs[0]
        self.assertEqual(p.stdin.data, b"q")
        self.assertFalse(p.killed)
        self.assertFalse(os.path.exists(self.out("blank.mkv")))            # nothing was recorded
        self.assertFalse(os.path.exists(self.out("blank.markers.json")))
        self.assertTrue(os.path.exists(self.out("blank.ffmpeg.log")))      # its log stays
        self.assertFalse(r.active())
        self.assertIsNone(r.status()["filename"])
        self.popen.opts = {}   # a working ffmpeg: the retry, with the same name, is not already-recording
        self.assertTrue(r.start("blank.mkv")["first_frame"])
        r.stop()

    def test_no_first_frame_kills_an_ffmpeg_that_ignores_q(self):
        self.popen = FakePopen(start=NO_FRAME, hang=True)
        r = self.recorder(first_frame_wait_s=0.1, stop_grace_s=0.1)
        with self.assertRaises(RecordError) as cm:
            r.start("stuck.mkv")
        self.assertEqual(cm.exception.word, "no-first-frame")
        self.assertIn("was killed", cm.exception.detail)
        self.assertTrue(self.popen.procs[0].killed)
        self.assertIsNone(r._session)

    def test_the_first_frame_wait_ends_before_the_deadline(self):
        self.popen = FakePopen(start=NO_FRAME)
        r = self.recorder(first_frame_wait_s=30, stop_grace_s=0.1)
        # the cleanup takes up to grace + 2 s: with the deadline 2.4 s away, the wait is 0.3 s, not 30 s
        t = time.monotonic()
        with self.assertRaises(RecordError) as cm:
            r.start("short.mkv", deadline=self.clock() + 2.4)
        self.assertEqual(cm.exception.word, "no-first-frame")
        self.assertLess(time.monotonic() - t, 5.0)
        self.assertIn("within 0.3 s", cm.exception.detail)
        with self.assertRaises(RecordError) as cm:   # a deadline already past: no wait at all
            r.start("late.mkv", deadline=self.clock() - 1)
        self.assertIn("within 0 s", cm.exception.detail)

    def test_a_far_deadline_still_waits_for_the_frame(self):
        r = self.recorder()
        self.assertTrue(r.start("quick.mkv", deadline=self.clock() + 100)["first_frame"])
        r.stop()

    def test_refusals(self):
        r = self.recorder()
        for bad in ("x.mp4", "../x.mkv"):
            with self.assertRaises(RecordError) as cm:
                r.start(bad)
            self.assertEqual(cm.exception.word, "bad-request")
        with self.assertRaises(RecordError):
            r.start("x.mkv", preset="placebo")
        with open(self.out("old.mkv"), "wb") as f:
            f.write(b"x")
        with self.assertRaises(RecordError) as cm:
            r.start("old.mkv")
        self.assertEqual(cm.exception.word, "file-exists")
        r.start("one.mkv")
        with self.assertRaises(RecordError) as cm:
            r.start("two.mkv")
        self.assertEqual(cm.exception.word, "already-recording")
        self.assertEqual(len(self.popen.procs), 1)
        r.stop()

    def test_ffmpeg_fails_at_start(self):
        self.popen = FakePopen(exit_at_start=1)
        r = self.recorder()
        with self.assertRaises(RecordError) as cm:
            r.start("bad.mkv")
        self.assertEqual(cm.exception.word, "ffmpeg-failed")
        self.assertIn("code 1", cm.exception.detail)
        self.assertIn("Failed to capture image", cm.exception.detail)
        self.assertFalse(r.active())
        self.assertEqual(r.status()["active"], False)

    def test_ffmpeg_missing_binary(self):
        def popen(*a, **k):
            raise FileNotFoundError(2, "The system cannot find the file specified")
        r = Recorder(self.root, popen=popen, clock=self.clock)
        with self.assertRaises(RecordError) as cm:
            r.start("x.mkv")
        self.assertEqual(cm.exception.word, "ffmpeg-failed")

    def test_stop_kills_a_hung_ffmpeg(self):
        self.popen = FakePopen(hang=True)
        r = self.recorder(stop_timeout_s=0.1)
        r.start("hang.mkv")
        res = r.stop()
        self.assertTrue(self.popen.procs[0].killed)
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"], "ffmpeg-failed")
        self.assertTrue(res["killed"])
        self.assertIn("killed", res["detail"])
        self.assertEqual(res["size_bytes"], 0)
        self.assertEqual(res["duration_s"], 0.04)

    def test_ffmpeg_died_while_recording(self):
        r = self.recorder()
        r.start("die.mkv")
        p = self.popen.procs[0]
        p.returncode = 1
        p.stdout.close()
        self.assertFalse(r.active())
        st = r.status()
        self.assertEqual((st["active"], st["filename"], st["exit_code"], st["ended_early"]), (False, "die.mkv", 1, True))
        with self.assertRaises(RecordError) as cm:
            r.marker("x")
        self.assertEqual(cm.exception.word, "not-recording")
        self.assertIn("ended by itself", cm.exception.detail)
        r.start("next.mkv")   # a dead session does not block a new one
        self.assertTrue(r.active())
        r.stop()

    def wait_eof(self, r):
        for _ in range(500):
            if r._session.eof:
                return
            time.sleep(0.01)
        self.fail("the reader thread never saw the end of ffmpeg's output")

    def test_ffmpeg_that_ended_by_itself_is_not_a_success(self):
        r = self.recorder()
        r.start("uac.mkv")
        self.clock.advance(12.0)
        self.popen.procs[0].end_by_itself(code=0, out_us=12_000_000)
        self.wait_eof(r)
        self.clock.advance(600.0)
        st = r.status()
        self.assertEqual((st["active"], st["ended_early"], st["ended_s_ago"], st["exit_code"]), (False, True, 600.0, 0))
        res = r.stop()
        self.assertEqual(self.popen.procs[0].stdin.data, b"")   # no "q" to an ffmpeg that is gone
        self.assertEqual((res["ok"], res["error"], res["duration_s"], res["exit_code"], res["ended_s_before_stop"]),
                         (False, "ended-early", 12.0, 0, 600.0))
        self.assertIn("ended by itself 600 s before the stop (exit code 0); the video ends at 12 s", res["detail"])
        self.assertEqual(res["size_bytes"], 1234)
        self.assertFalse(r.status()["ended_early"])   # collected

    def test_ended_early_with_an_error_and_no_video(self):
        r = self.recorder()
        r.start("gone.mkv")
        self.popen.procs[0].end_by_itself(code=1, out_us=0, frames=0, video=False)
        self.wait_eof(r)
        res = r.stop()
        self.assertEqual((res["ok"], res["error"], res["exit_code"], res["size_bytes"]), (False, "ended-early", 1, 0))
        self.assertIn("no video written", res["detail"])

    def test_a_marker_the_file_did_not_take_is_not_kept(self):
        r = self.recorder()
        r.start("full.mkv")

        def disk_full(path, obj):
            raise OSError(28, "No space left on device")
        real = record_mod.write_json_atomic
        record_mod.write_json_atomic = disk_full
        try:
            with self.assertRaises(RecordError) as cm:
                r.marker("lost")
        finally:
            record_mod.write_json_atomic = real
        self.assertEqual(cm.exception.word, "out-not-writable")
        self.assertIn("No space left on device", cm.exception.detail)
        self.assertEqual(r._session.markers, [])
        self.assertEqual(r.marker("kept")["count"], 1)
        with open(self.out("full.markers.json")) as f:
            self.assertEqual([m["label"] for m in json.load(f)], ["kept"])
        r.stop()

    def test_out_folder_missing(self):
        shutil.rmtree(os.path.join(self.root, "out"))
        r = self.recorder()
        with self.assertRaises(RecordError) as cm:
            r.start("x.mkv")
        self.assertEqual(cm.exception.word, "out-not-writable")
        self.assertEqual(self.popen.procs, [])

    def test_spawn_hook(self):
        seen = []
        r = self.recorder(on_spawn=seen.append)
        r.start("hook.mkv")
        self.assertEqual(seen, [self.popen.procs[0]])
        r.stop()

    def test_write_json_atomic(self):
        path = self.out("m.json")
        write_json_atomic(path, [{"t": 1.0, "label": "中"}])
        with open(path, "rb") as f:
            raw = f.read()
        self.assertEqual(json.loads(raw), [{"t": 1.0, "label": "中"}])
        self.assertTrue(raw.isascii())


if __name__ == "__main__":
    unittest.main()
