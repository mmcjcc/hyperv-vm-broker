"""Key combos and human-cadence typing (vm_director.keys), on the fake desktop and a fake clock."""

import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from director_fakes import FakeClock, FakeDesktop  # noqa: E402

from vm_director import keys  # noqa: E402
from vm_director.desktop import DesktopError  # noqa: E402
from vm_director.keys import ComboError, Typist, parse_combo  # noqa: E402

CTRL, SHIFT, ALT, WIN = 0x11, 0x10, 0x12, 0x5B


class ComboParsing(unittest.TestCase):
    def test_good_combos(self):
        cases = {
            "ctrl+shift+p": [(CTRL, SHIFT, ord("P"))],
            "win+r": [(WIN, ord("R"))],
            "alt+f4": [(ALT, 0x73)],
            "enter": [(0x0D,)],
            "return": [(0x0D,)],
            "esc": [(0x1B,)],
            "ESC": [(0x1B,)],
            "Ctrl+Shift+P": [(CTRL, SHIFT, ord("P"))],
            "tab": [(0x09,)],
            "f1": [(0x70,)],
            "f24": [(0x87,)],
            "home": [(0x24,)], "end": [(0x23,)], "pgup": [(0x21,)], "pgdn": [(0x22,)],
            "del": [(0x2E,)], "ins": [(0x2D,)], "backspace": [(0x08,)], "space": [(0x20,)],
            "left": [(0x25,)], "up": [(0x26,)], "right": [(0x27,)], "down": [(0x28,)],
            "a": [(0x41,)], "z": [(0x5A,)], "0": [(0x30,)], "9": [(0x39,)],
            "ctrl+`": [(CTRL, 0xC0)],
            "ctrl+,": [(CTRL, 0xBC)],
            "ctrl+plus": [(CTRL, 0xBB)],
            "ctrl+minus": [(CTRL, 0xBD)],
            "win": [(WIN,)],
            "ctrl+shift": [(CTRL, SHIFT)],
            "ctrl+k ctrl+s": [(CTRL, ord("K")), (CTRL, ord("S"))],
            "  alt+tab  ": [(ALT, 0x09)],
        }
        for combo, want in cases.items():
            with self.subTest(combo=combo):
                self.assertEqual(parse_combo(combo), want)

    def test_bad_combos(self):
        cases = {
            "": "empty",
            "   ": "empty",
            "ctrl+": "empty key name",
            "ctrl++": "empty key name",
            "+a": "empty key name",
            "hyper+x": "unknown key 'hyper'",
            "ctrl+foo": "unknown key 'foo'",
            "f25": "unknown key 'f25'",
            "a+ctrl": "not a modifier",
            "ctrl+ctrl+a": "twice",
            "ctrl+alt+del": "human step",
            "alt+ctrl+delete": "human step",
            "win+l": "lock the desktop",
            "win+shift+L": "lock the desktop",
            "ctrl + p": "empty key name",
            "x" * 201: "longer than 200",
        }
        for combo, msg in cases.items():
            with self.subTest(combo=combo):
                with self.assertRaises(ComboError) as cm:
                    parse_combo(combo)
                self.assertIn(msg, str(cm.exception))
        with self.assertRaises(ComboError):
            parse_combo(None)


class Chords(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.desk = FakeDesktop(self.clock)
        self.t = Typist(self.desk, random.Random(7), self.clock.sleep, self.clock)

    def keys(self):
        return [e for e in self.desk.log if e[0] == "vk"]

    def test_chord_order(self):
        self.t.press("ctrl+shift+p")
        self.assertEqual(self.keys(), [("vk", CTRL, False), ("vk", SHIFT, False), ("vk", 0x50, False),
                                       ("vk", 0x50, True), ("vk", SHIFT, True), ("vk", CTRL, True)])

    def test_repeat_and_sequence(self):
        r = self.t.press("down", repeat=3)
        self.assertEqual(r, {"chords": 3})
        self.assertEqual(self.keys(), [("vk", 0x28, False), ("vk", 0x28, True)] * 3)
        self.desk.log.clear()
        r = self.t.press("ctrl+k ctrl+s", repeat=2)
        self.assertEqual(r, {"chords": 4})
        downs = [e[1] for e in self.keys() if not e[2]]
        self.assertEqual(downs, [CTRL, ord("K"), CTRL, ord("S")] * 2)

    def test_modifiers_released_when_a_key_fails(self):
        self.desk.fail_vk = (ord("P"), False)
        with self.assertRaises(DesktopError):
            self.t.press("ctrl+shift+p")
        self.assertEqual(self.keys(), [("vk", CTRL, False), ("vk", SHIFT, False), ("vk", SHIFT, True),
                                       ("vk", CTRL, True)])

    def test_a_release_that_fails_is_raised_after_the_other_releases(self):
        self.desk.fail_vk = (SHIFT, True)
        with self.assertRaises(DesktopError) as cm:
            self.t.press("ctrl+shift+p")
        self.assertEqual(cm.exception.word, "input-blocked")
        self.assertIn("keys may be held", cm.exception.detail)
        self.assertEqual(self.keys(), [("vk", CTRL, False), ("vk", SHIFT, False), ("vk", 0x50, False),
                                       ("vk", 0x50, True), ("vk", CTRL, True)])   # Ctrl still released

    def test_a_failed_release_in_typing_is_raised(self):
        self.desk.fail_vk = (0x0D, True)   # the Enter release
        with self.assertRaises(DesktopError) as cm:
            self.t.type_text("a\nb")
        self.assertIn("keys may be held", cm.exception.detail)
        self.assertNotIn(("char", "b"), self.desk.log)

    def test_deadline_before_every_chord(self):
        # each chord: one key with a 20-45 ms gap, then 80-160 ms between chords
        r_ok = self.t.press("down", repeat=3, deadline=self.clock() + 100)
        self.assertEqual(r_ok, {"chords": 3})
        with self.assertRaises(keys.InputStopped) as cm:
            self.t.press("down", repeat=100, deadline=self.clock() + 1.0)
        e = cm.exception
        self.assertEqual(e.word, "deadline")
        self.assertTrue(5 <= e.extra["chords"] <= 10, e.extra)   # 0.100 to 0.205 s per chord
        downs = [k for k in self.keys() if not k[2]]
        ups = [k for k in self.keys() if k[2]]
        self.assertEqual(len(downs), len(ups))   # stopped between chords: nothing held
        self.assertEqual(len(downs), 3 + e.extra["chords"])


class Stops(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock(100.0)
        self.desk = FakeDesktop(self.clock)
        self.t = Typist(self.desk, random.Random(3), self.clock.sleep, self.clock)

    def chars(self):
        return "".join(e[1] for e in self.desk.log if e[0] == "char")

    def test_deadline_stops_before_the_next_character_and_never_presses_enter(self):
        with self.assertRaises(keys.InputStopped) as cm:
            self.t.type_text("abcdef", cps=1, jitter=0, enter=True, deadline=self.clock() + 2.5)
        e = cm.exception
        self.assertEqual((e.word, e.extra["chars"]), ("deadline", 3))
        self.assertIn("after 3 of 6 characters; stopped without Enter", e.detail)
        self.assertEqual(self.chars(), "abc")
        self.assertNotIn(("vk", 0x0D, False), self.desk.log)

    def test_deadline_in_the_pause_before_enter_presses_nothing(self):
        # "ab" takes 2 s at cps 1; the deadline falls inside the 300-600 ms pause before the final Enter
        with self.assertRaises(keys.InputStopped) as cm:
            self.t.type_text("ab", cps=1, jitter=0, enter=True, deadline=self.clock() + 2.2)
        self.assertEqual(cm.exception.extra["chars"], 2)
        self.assertNotIn(("vk", 0x0D, False), self.desk.log)
        self.desk.log.clear()
        with self.assertRaises(keys.InputStopped):
            self.t.type_text("a\nb", cps=1, jitter=0, deadline=self.clock() + 1.2)   # the same for a newline
        self.assertNotIn(("vk", 0x0D, False), self.desk.log)
        self.assertEqual(self.chars(), "a")

    def test_no_deadline_and_a_far_one_type_everything(self):
        self.assertEqual(self.t.type_text("abc", cps=10)["chars"], 3)
        self.assertEqual(self.t.type_text("abc", cps=10, enter=True, deadline=self.clock() + 1000)["chars"], 3)
        self.assertIn(("vk", 0x0D, False), self.desk.log)

    def test_focus_lost_stops_before_the_next_character(self):
        self.desk.fg = 9
        self.desk.on_char = lambda d, n: setattr(d, "fg", 12) if n == 2 else None
        with self.assertRaises(keys.InputStopped) as cm:
            self.t.type_text("Get-Date", enter=True, target=9)   # the desktop's foreground() by default
        e = cm.exception
        self.assertEqual((e.word, e.extra["chars"]), ("focus-lost", 2))
        self.assertIn("0xc", e.detail)
        self.assertEqual(self.chars(), "Ge")
        self.assertNotIn(("vk", 0x0D, False), self.desk.log)

    def test_focus_is_checked_before_the_first_character_and_the_enter(self):
        with self.assertRaises(keys.InputStopped) as cm:
            self.t.type_text("x", target=9, foreground=lambda: 0)
        self.assertEqual(cm.exception.extra["chars"], 0)
        self.assertEqual(self.chars(), "")
        seen = []

        def fg():
            seen.append(self.clock())
            return 9 if len(seen) < 2 else 4   # fine for the character, gone before the Enter
        with self.assertRaises(keys.InputStopped) as cm:
            self.t.type_text("y", enter=True, target=9, foreground=fg)
        self.assertEqual(cm.exception.extra["chars"], 1)
        self.assertNotIn(("vk", 0x0D, False), self.desk.log)

    def test_the_target_kept_types_everything(self):
        r = self.t.type_text("dir", enter=True, target=9, foreground=lambda: 9)
        self.assertEqual(r["chars"], 3)
        self.assertEqual(self.desk.log[-1], ("vk", 0x0D, True))


class Cadence(unittest.TestCase):
    def run_text(self, text, cps=10, jitter=0.35, enter=False, seed=42, layout=False, desk_layout=None):
        clock = FakeClock()
        desk = FakeDesktop(clock)
        if desk_layout:
            desk.layout = desk_layout
        t = Typist(desk, random.Random(seed), clock.sleep, clock, layout=layout)
        r = t.type_text(text, cps=cps, jitter=jitter, enter=enter)
        return r, desk.log, clock

    def test_delays_within_bounds(self):
        cps, jitter = 10, 0.35
        text = "Hello, world. Is it fine? Yes: ok; go!"
        r, log, clock = self.run_text(text, cps, jitter)
        self.assertEqual(r["chars"], len(text))
        lo, hi = (1 - jitter) / cps, (1 + jitter) / cps
        chars = 0
        for i, e in enumerate(log):
            if e[0] != "char":
                continue
            chars += 1
            base = log[i + 1]
            self.assertEqual(base[0], "sleep")
            self.assertGreaterEqual(base[1], lo - 1e-12)
            self.assertLessEqual(base[1], hi + 1e-12)
            nxt = log[i + 2] if i + 2 < len(log) else None
            if e[1] in ".,;:!?":
                self.assertEqual(nxt[0], "sleep", e)
                self.assertGreaterEqual(nxt[1], 0.150)
                self.assertLessEqual(nxt[1], 0.350)
            elif nxt is not None:
                self.assertEqual(nxt[0], "char", (e, nxt))   # no extra pause after other characters
        self.assertEqual(chars, len(text))
        self.assertAlmostEqual(r["seconds"], round(sum(clock.sleeps), 3), places=3)

    def test_jitter_actually_varies(self):
        _, log, _ = self.run_text("abcdefghij" * 3, cps=14, jitter=0.35)
        bases = {round(e[1], 6) for i, e in enumerate(log) if e[0] == "sleep" and log[i - 1][0] == "char"}
        self.assertGreater(len(bases), 10)

    def test_zero_jitter_is_exact(self):
        _, log, _ = self.run_text("abc", cps=20, jitter=0)
        bases = [e[1] for i, e in enumerate(log) if e[0] == "sleep" and log[i - 1][0] == "char"]
        self.assertEqual(bases, [0.05, 0.05, 0.05])

    def test_pause_before_every_enter(self):
        r, log, _ = self.run_text("dir\nls\r\nexit", enter=True)
        self.assertEqual(r["chars"], len("dir\nls\nexit"))
        enter_downs = [i for i, e in enumerate(log) if e == ("vk", 0x0D, False)]
        self.assertEqual(len(enter_downs), 3)   # two newlines (CR LF counts once) and enter=true
        for i in enter_downs:
            self.assertEqual(log[i - 1][0], "sleep")
            self.assertGreaterEqual(log[i - 1][1], 0.300)
            self.assertLessEqual(log[i - 1][1], 0.600)
            self.assertEqual(log[i + 1][0], "sleep")
            self.assertEqual(log[i + 2], ("vk", 0x0D, True))
        self.assertEqual(log[-1], ("vk", 0x0D, True))   # enter=true is the last thing

    def test_tab_and_unicode(self):
        _, log, _ = self.run_text("a\tbé中\U0001F600")
        inputs = [e for e in log if e[0] != "sleep"]
        self.assertEqual(inputs, [("char", "a"), ("vk", 0x09, False), ("vk", 0x09, True), ("char", "b"),
                                  ("char", "é"), ("char", "中"), ("char", "\U0001F600")])

    def test_deterministic_with_seed(self):
        a = self.run_text("Same text, same seed.", seed=3)[1]
        b = self.run_text("Same text, same seed.", seed=3)[1]
        c = self.run_text("Same text, same seed.", seed=4)[1]
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)

    def test_layout_mode(self):
        lay = {"A": (0x41, True), "b": (0x42, False)}
        _, log, _ = self.run_text("Abé", layout=True, desk_layout=lay)
        inputs = [e for e in log if e[0] != "sleep"]
        self.assertEqual(inputs, [("vk", 0x10, False), ("vk", 0x41, False), ("vk", 0x41, True), ("vk", 0x10, True),
                                  ("vk", 0x42, False), ("vk", 0x42, True), ("char", "é")])

    def test_empty_text(self):
        r, log, _ = self.run_text("")
        self.assertEqual(r, {"chars": 0, "seconds": 0.0})
        self.assertEqual(log, [])


class TextHelpers(unittest.TestCase):
    def test_utf16_units(self):
        self.assertEqual(keys.utf16_units("A"), [0x41])
        self.assertEqual(keys.utf16_units("中"), [0x4E2D])
        self.assertEqual(keys.utf16_units("\U0001F600"), [0xD83D, 0xDE00])

    def test_bad_text_char(self):
        self.assertIsNone(keys.bad_text_char("ok\ttab\nnew\r\nline é \U0001F600"))
        self.assertEqual(keys.bad_text_char("bell\x07"), "\x07")
        self.assertEqual(keys.bad_text_char("esc\x1b[0m"), "\x1b")
        self.assertEqual(keys.bad_text_char("del\x7f"), "\x7f")
        self.assertEqual(keys.bad_text_char("lone \ud83d"), "\ud83d")


if __name__ == "__main__":
    unittest.main()
