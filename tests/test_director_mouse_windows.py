"""Eased cursor path and clicks (vm_director.mouse); window waits (vm_director.windows). Fake desktop and clock."""

import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from director_fakes import FakeClock, FakeDesktop  # noqa: E402

from vm_director.desktop import InputStopped  # noqa: E402
from vm_director.mouse import Mouse, ease_in_out, eased_path  # noqa: E402
from vm_director.windows import compile_title, find_terminal, wait_for  # noqa: E402


class EasedPath(unittest.TestCase):
    def test_ease(self):
        self.assertEqual(ease_in_out(0), 0.0)
        self.assertEqual(ease_in_out(1), 1.0)
        self.assertAlmostEqual(ease_in_out(0.5), 0.5)
        vals = [ease_in_out(i / 100) for i in range(101)]
        self.assertEqual(vals, sorted(vals))
        self.assertLess(vals[10], 0.1)   # slow start
        self.assertGreater(vals[90], 0.9)   # slow end

    def test_straight_move(self):
        p = eased_path(0, 500, 1000, 500, 400)
        self.assertEqual(p[0], (0, 500))
        self.assertEqual(p[-1], (1000, 500))
        self.assertEqual(len(p), 1 + 24)   # 400 ms at 60 steps per second
        xs = [x for x, _ in p]
        self.assertEqual(xs, sorted(xs))
        self.assertTrue(all(y == 500 for _, y in p))
        steps = [b - a for a, b in zip(xs, xs[1:])]
        self.assertLess(steps[0], steps[len(steps) // 2])   # eased: faster in the middle
        self.assertLess(steps[-1], steps[len(steps) // 2])

    def test_backwards_and_diagonal(self):
        p = eased_path(1900, 1000, 20, 30, 1000)
        self.assertEqual((p[0], p[-1]), ((1900, 1000), (20, 30)))
        self.assertEqual(len(p), 61)
        xs, ys = [x for x, _ in p], [y for _, y in p]
        self.assertEqual(xs, sorted(xs, reverse=True))
        self.assertEqual(ys, sorted(ys, reverse=True))

    def test_zero_ms_and_no_move(self):
        self.assertEqual(eased_path(1, 2, 3, 4, 0), [(1, 2), (3, 4)])
        self.assertEqual(eased_path(5, 5, 5, 5, 400), [(5, 5), (5, 5)])
        self.assertEqual(eased_path(0, 0, 10, 10, 5), [(0, 0), (10, 10)])   # under one step: one step


class Clicks(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.desk = FakeDesktop(self.clock)
        self.desk.cursor = (100, 100)
        self.m = Mouse(self.desk, random.Random(1), self.clock.sleep)

    def test_click_moves_then_clicks(self):
        r = self.m.click(900, 600, move_ms=400)
        self.assertEqual(r, {"x": 900, "y": 600, "from": [100, 100], "button": "left", "double": False})
        moves = [e for e in self.desk.log if e[0] == "move"]
        self.assertEqual(moves[-1], ("move", 900, 600))
        self.assertGreater(len(moves), 15)
        inputs = [e for e in self.desk.log if e[0] in ("move", "button")]
        self.assertEqual(inputs[-2:], [("button", "left", False), ("button", "left", True)])
        self.assertAlmostEqual(sum(self.clock.sleeps[:24]), 0.4, places=6)   # the path takes move_ms
        self.assertEqual(self.desk.warps, [])

    def test_double_right(self):
        self.m.click(10, 10, button="right", double=True, move_ms=0)
        buttons = [e for e in self.desk.log if e[0] == "button"]
        self.assertEqual(buttons, [("button", "right", False), ("button", "right", True)] * 2)
        moves = [e for e in self.desk.log if e[0] == "move"]
        self.assertEqual(moves, [("move", 10, 10)])

    def test_rounding_miss_is_corrected(self):
        self.desk.move_error = (1, 0)
        self.m.click(500, 500, move_ms=100)
        self.assertEqual(self.desk.warps, [(500, 500)])
        self.assertEqual(self.desk.cursor, (500, 500))

    def test_bad_button(self):
        with self.assertRaises(ValueError):
            self.m.click(1, 1, button="back")

    def deadline_mouse(self):
        return Mouse(self.desk, random.Random(1), self.clock.sleep, self.clock)

    def inputs(self, kind):
        return [e for e in self.desk.log if e[0] == kind]

    def test_nothing_after_the_deadline(self):
        with self.assertRaises(InputStopped) as cm:
            self.deadline_mouse().click(900, 600, move_ms=400, deadline=self.clock() - 0.1)
        e = cm.exception
        self.assertEqual((e.word, e.extra), ("deadline", {"moved": False, "clicks": 0}))
        self.assertIn("before the cursor moved; no button was pressed", e.detail)
        self.assertEqual(self.inputs("move") + self.inputs("button"), [])

    def test_the_deadline_cuts_the_path_and_presses_nothing(self):
        with self.assertRaises(InputStopped) as cm:
            self.deadline_mouse().click(900, 600, move_ms=1000, deadline=self.clock() + 0.5)   # a 1 s path
        e = cm.exception
        self.assertEqual(e.extra, {"moved": True, "clicks": 0})
        self.assertIn("while the cursor moved", e.detail)
        self.assertTrue(15 <= len(self.inputs("move")) <= 35, len(self.inputs("move")))   # about half the path
        self.assertNotEqual(self.desk.cursor, (900, 600))
        self.assertEqual(self.inputs("button"), [])

    def test_the_deadline_just_before_the_button(self):
        # the 400 ms path ends at 0.4 s, the settle at 0.43 s; the deadline falls between
        with self.assertRaises(InputStopped) as cm:
            self.deadline_mouse().click(900, 600, move_ms=400, deadline=self.clock() + 0.415)
        e = cm.exception
        self.assertEqual(e.extra, {"moved": True, "clicks": 0})
        self.assertIn("before the button went down", e.detail)
        self.assertEqual(self.desk.cursor, (900, 600))
        self.assertEqual(self.inputs("button"), [])

    def test_a_double_click_cut_after_the_first_click(self):
        # settle 0.03 s, first click done by 0.12 s, the gap ends at 0.16 s at the earliest
        with self.assertRaises(InputStopped) as cm:
            self.deadline_mouse().click(10, 10, double=True, move_ms=0, deadline=self.clock() + 0.13)
        e = cm.exception
        self.assertEqual(e.extra, {"moved": True, "clicks": 1})
        self.assertIn("the second click was not made", e.detail)
        self.assertEqual(self.inputs("button"), [("button", "left", False), ("button", "left", True)])

    def test_a_far_deadline_changes_nothing(self):
        r = self.deadline_mouse().click(900, 600, double=True, move_ms=400, deadline=self.clock() + 100)
        self.assertEqual((r["x"], r["y"], r["double"]), (900, 600, True))
        self.assertEqual(len(self.inputs("button")), 4)
        self.assertEqual(self.desk.cursor, (900, 600))


class WaitFor(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock(500.0)
        self.desk = FakeDesktop(self.clock)

    def test_found_at_once(self):
        self.desk.windows = [(1, "", "Shell_TrayWnd"), (2, "readme.md - Visual Studio Code", "Chrome_WidgetWin_1")]
        r = wait_for(self.desk, r"Visual Studio Code$", 30, False, self.clock, self.clock.sleep)
        self.assertEqual(r, {"ok": True, "found": True, "title": "readme.md - Visual Studio Code", "waited_s": 0.0})

    def test_found_later(self):
        appear = self.clock() + 2.0
        self.desk.windows = lambda now: [(7, "Sign in to GitHub", "X")] if now >= appear else [(1, "Desktop", "X")]
        r = wait_for(self.desk, "Sign in", 30, False, self.clock, self.clock.sleep)
        self.assertTrue(r["ok"])
        self.assertEqual(r["title"], "Sign in to GitHub")
        self.assertAlmostEqual(r["waited_s"], 2.0)
        self.assertTrue(all(abs(s - 0.25) < 1e-9 for s in self.clock.sleeps))   # polls every 250 ms

    def test_gone(self):
        leave = self.clock() + 1.0
        self.desk.windows = lambda now: [(3, "Installing...", "X")] if now < leave else []
        r = wait_for(self.desk, "^Installing", 30, True, self.clock, self.clock.sleep)
        self.assertEqual(r, {"ok": True, "found": False, "title": None, "waited_s": 1.0})

    def test_timeout(self):
        self.desk.windows = [(1, "Something else", "X")]
        r = wait_for(self.desk, "Never", 3, False, self.clock, self.clock.sleep)
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"], "timeout")
        self.assertEqual(r["waited_s"], 3.0)
        self.assertEqual(len(self.clock.sleeps), 12)
        self.desk.windows = [(1, "Still here", "X")]
        r = wait_for(self.desk, "Still", 1.1, True, self.clock, self.clock.sleep)
        self.assertEqual((r["ok"], r["error"], r["waited_s"]), (False, "timeout", 1.1))

    def test_empty_titles_never_match(self):
        self.desk.windows = [(1, "", "X")]
        r = wait_for(self.desk, ".*", 1, False, self.clock, self.clock.sleep)
        self.assertFalse(r["ok"])

    def test_bad_patterns(self):
        for bad in ("", "(", "x" * 201, None):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                compile_title(bad)
        compile_title("x" * 200)

    SLOW = [r"^(\w+\s?)+$", r"(a+)+", r"(a*)*b", r"(?:a+){2,}", r"((a+)b)+", r"(a|b+)*", r"(?=a+)+", r"(?>a+)+",
            r"(a{2,5})*", r"(\d+)++", r"(?:x(?:y+))*"]
    REFS = [r"(a)\1", r"(?P<x>a)(?P=x)", r"(a)?(?(1)b|c)"]
    FINE = [r"PowerShell$", r"^(Windows )?PowerShell", r"(?:ab|cd)*", r"a{2,5}", r"(a+)?", r"[(+]+", r"\(a+\)+",
            r"(?i)notepad", r"^Sign in .* GitHub", r"(\w+) - Visual Studio Code$", r"(?:a{1})+", r"\d+\.\d+",
            r"[\w\s]+ - Notepad", r"x{3}", r"\0"]

    def test_slow_patterns_are_refused(self):
        for bad in self.SLOW:
            with self.subTest(bad=bad), self.assertRaises(ValueError) as cm:
                compile_title(bad)
            self.assertIn("repeat inside a repeat", str(cm.exception))
        for bad in self.REFS:
            with self.subTest(bad=bad), self.assertRaises(ValueError) as cm:
                compile_title(bad)
            self.assertIn("backreferences", str(cm.exception))
        for good in self.FINE:
            with self.subTest(good=good):
                compile_title(good)

    def test_textual_check_without_the_parser(self):
        from vm_director import windows
        for bad in self.SLOW:
            with self.subTest(bad=bad):
                self.assertEqual(windows._textual_problem(bad), windows.NESTED)
        for bad in self.REFS:
            with self.subTest(bad=bad):
                self.assertEqual(windows._textual_problem(bad), windows.BACKREF)
        for good in self.FINE:
            with self.subTest(good=good):
                self.assertIsNone(windows._textual_problem(good))
        saved = windows._re_parser
        windows._re_parser = None   # as if re._parser did not import
        try:
            with self.assertRaises(ValueError):
                compile_title(r"(\w+\s?)+$")
            compile_title(r"^(Windows )?PowerShell")
        finally:
            windows._re_parser = saved

    def test_titles_are_cut_before_matching(self):
        from vm_director.windows import MAX_TITLE_MATCH
        long_title = "x" * (MAX_TITLE_MATCH - 3) + "TAIL of a long title"
        self.desk.windows = [(4, long_title, "X")]
        r = wait_for(self.desk, "TAI", 1, False, self.clock, self.clock.sleep)
        self.assertEqual((r["found"], r["title"]), (True, long_title))   # the whole title comes back
        r = wait_for(self.desk, "TAIL", 1, False, self.clock, self.clock.sleep)
        self.assertFalse(r["ok"])   # past character 256

    def test_find_terminal(self):
        self.desk.windows = [(1, "Notepad", "Notepad"), (2, "Windows PowerShell", "ConsoleWindowClass"),
                             (3, "PowerShell", "CASCADIA_HOSTING_WINDOW_CLASS")]
        self.assertEqual(find_terminal(self.desk), (2, "Windows PowerShell", "ConsoleWindowClass"))
        self.desk.windows = [(1, "Notepad", "Notepad")]
        self.assertIsNone(find_terminal(self.desk))


if __name__ == "__main__":
    unittest.main()
