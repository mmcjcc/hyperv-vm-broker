"""/click: an eased cursor path from where the cursor is to (x, y), then a click.

The path follows ease-in-out (cubic) over `move_ms` at about 60 steps per second; move_ms 0 jumps straight there.
After the last step the cursor is checked and put exactly on the target if rounding left it a pixel off. A click is
button down, a short hold, button up; a double click is two of them within the double-click time.

Deadline (a time on the injected clock, from the relay's X-Vmb-Timeout): checked before the move starts, between the
steps of the path, before the button goes down, and before the second click of a double click. Past it, nothing more
is done (no button goes down) and InputStopped("deadline") says whether the cursor moved and how many clicks were
made (0, or 1 when the second click of a double click was cut).
"""

from __future__ import annotations

import random
import time
from typing import Callable

from .desktop import Desktop, InputStopped

STEPS_PER_SECOND = 60
HOLD = (0.050, 0.090)        # button down to button up
DOUBLE_GAP = (0.080, 0.130)  # between the two clicks of a double click (well inside the default 500 ms)
SETTLE = 0.030               # after the last move, before checking the cursor and clicking
BUTTONS = ("left", "right", "middle")


def ease_in_out(t: float) -> float:
    """Cubic ease-in-out on [0, 1]: slow start, fast middle, slow end; monotonic."""
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0
    if t < 0.5:
        return 4.0 * t * t * t
    u = -2.0 * t + 2.0
    return 1.0 - u * u * u / 2.0


def eased_path(x0: int, y0: int, x1: int, y1: int, move_ms: int,
               rate: int = STEPS_PER_SECOND) -> list[tuple[int, int]]:
    """Points from (x0, y0) (the first one) to (x1, y1) (the last one)."""
    if move_ms <= 0 or (x0, y0) == (x1, y1):
        return [(x0, y0), (x1, y1)]
    steps = max(1, round(move_ms * rate / 1000))
    points = [(x0, y0)]
    for i in range(1, steps + 1):
        e = ease_in_out(i / steps)
        points.append((round(x0 + (x1 - x0) * e), round(y0 + (y1 - y0) * e)))
    points[-1] = (x1, y1)
    return points


class Mouse:
    def __init__(self, desktop: Desktop, rng: random.Random | None = None,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic):
        self.desktop = desktop
        self.rng = rng or random.Random()
        self.sleep = sleep
        self.clock = clock

    def _check(self, deadline: float | None, when: str, moved: bool, clicks: int) -> None:
        if deadline is not None and self.clock() >= deadline:
            tail = "the second click was not made" if clicks else "no button was pressed"
            raise InputStopped("deadline", f"the relay's time for this step ran out {when}; {tail}",
                               moved=moved, clicks=clicks)

    def move(self, x: int, y: int, move_ms: int = 400, deadline: float | None = None) -> tuple[int, int]:
        """Move along the eased path; returns where the cursor started. With a deadline: checked before the move
        starts and between its steps (InputStopped("deadline") with moved and clicks=0)."""
        x0, y0 = self.desktop.cursor_pos()
        self._check(deadline, "before the cursor moved", False, 0)
        points = eased_path(x0, y0, x, y, move_ms)
        steps = points[1:]
        delay = (move_ms / 1000.0) / len(steps) if move_ms > 0 else 0.0
        last = (x0, y0)
        moved = False
        for p in steps:
            if p != last:
                if moved:
                    self._check(deadline, "while the cursor moved", True, 0)
                self.desktop.move_abs(*p)
                last = p
                moved = True
            if delay:
                self.sleep(delay)
        if last != (x, y):
            self.desktop.move_abs(x, y)
        self.sleep(SETTLE)
        if self.desktop.cursor_pos() != (x, y):
            self.desktop.warp(x, y)
        return x0, y0

    def click(self, x: int, y: int, button: str = "left", double: bool = False, move_ms: int = 400,
              deadline: float | None = None) -> dict:
        """Move, then click (twice when `double`). With a deadline, no button goes down after it."""
        if button not in BUTTONS:
            raise ValueError(f"button must be one of {', '.join(BUTTONS)}")
        x0, y0 = self.move(x, y, move_ms, deadline)
        moved = (x0, y0) != (x, y)
        for i in range(2 if double else 1):
            if i:
                self.sleep(self.rng.uniform(*DOUBLE_GAP))
            self._check(deadline, "after the first click of a double click" if i else "before the button went down",
                        moved, i)
            self.desktop.mouse_button(button, False)
            try:
                self.sleep(self.rng.uniform(*HOLD))
            finally:
                self.desktop.mouse_button(button, True)
        return {"x": x, "y": y, "from": [x0, y0], "button": button, "double": double}
