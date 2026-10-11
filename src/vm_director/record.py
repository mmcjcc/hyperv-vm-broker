"""Recording the desktop with ffmpeg gdigrab (/record/start, /record/stop, /marker).

ffmpeg runs as
    <root>\\bin\\ffmpeg.exe -hide_banner -loglevel error -f gdigrab -framerate <fps> -draw_mouse 1 -i desktop
        -c:v libx264 -preset <preset> -crf <crf> -pix_fmt yuv420p -progress pipe:1 -nostats <root>\\out\\<filename>
with stdin and stdout as pipes, stderr to <root>\\out\\<base>.ffmpeg.log, and no window. A reader thread parses the
-progress blocks (key=value lines ending with progress=continue or progress=end).

Start answers only once ffmpeg has its first frame: it waits up to 45 s, and with a deadline (the relay's
X-Vmb-Timeout) never so long that the answer, cleanup included, would come after it. ffmpeg that exits first:
ffmpeg-failed (with the last line of its log). No frame in time: ffmpeg is stopped ("q", 3 s of grace, then kill),
the empty video and markers files are removed (a retry may use the same name), its log stays, no session is left
(a retry is not already-recording), and the answer is error no-first-frame. A start that succeeds always has
first_frame true.

Time zero: t0 = monotonic() - out_time_us / 1e6 at the first progress block with frame >= 1, i.e. the moment of the
video's first frame. A marker's t is monotonic() - t0, rounded to 1 ms, so t is a position in the video. Markers go to
<root>\\out\\<base>.markers.json (smoke.mkv -> smoke.markers.json): a JSON array of {"t", "label"}, rewritten
atomically (temp file, then os.replace) on every marker; the file is created empty ([]) when the recording starts. A
marker is kept only once the file holds it (a write that fails answers out-not-writable and keeps nothing).

Stop: "q" on stdin, stdin closed, up to 30 s for ffmpeg to finish the file, then kill. An ffmpeg that ended by itself
before the stop (gdigrab ends its input when a screen grab fails: the UAC secure desktop, a locked or ended session)
leaves a shorter video than the caller expects: the stop answers ok false, error ended-early, with the video's
duration and how many seconds before the stop ffmpeg ended (the reader thread notes when ffmpeg's stdout closed).
/health's recording block says the same while it is not yet stopped (ended_early, ended_s_ago). popen, the clock and
the root folder are injected for tests.
"""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import threading
import time
from typing import Callable

FILENAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.mkv")
PRESETS = ("ultrafast", "superfast", "veryfast", "faster", "fast")
FIRST_FRAME_WAIT_S = 45.0   # /record/start waits this long at most for ffmpeg's first frame
STOP_GRACE_S = 3.0          # an ffmpeg without a first frame gets this long after "q", then it is killed
CLEANUP_S = 2.0             # what the kill and the reader thread may still take after the grace
RESERVED = {"CON", "PRN", "AUX", "NUL"} | {f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)


class RecordError(Exception):
    def __init__(self, word: str, detail: str):
        super().__init__(detail)
        self.word = word
        self.detail = detail


def filename_problem(name) -> str | None:
    """Why `name` is not an acceptable recording file name, or None."""
    if not isinstance(name, str) or not FILENAME_RE.fullmatch(name):
        return "filename must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\.mkv$"
    if name.split(".", 1)[0].upper() in RESERVED:
        return "filename uses a reserved Windows device name"
    return None


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def write_json_atomic(path: str, obj) -> None:
    tmp = path + ".tmp"
    data = json.dumps(obj, indent=2, ensure_ascii=True) + "\n"
    with open(tmp, "w", encoding="ascii", newline="\n") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    for attempt in range(5):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:   # a reader (a copy out of the VM) has the file open; try again shortly
            if attempt == 4:
                raise
            time.sleep(0.05)


def log_tail(path: str, limit: int = 200) -> str:
    """The last non-empty line of a log file, printable, at most `limit` characters ("" if none)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 4096))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return ""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines:
        return ""
    line = "".join(ch if ch.isprintable() else " " for ch in lines[-1])
    return line[:limit]


def _int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


class _Session:
    def __init__(self, proc, filename: str, path: str, markers_path: str, log_path: str, started: str):
        self.proc = proc
        self.filename = filename
        self.path = path
        self.markers_path = markers_path
        self.log_path = log_path
        self.started = started
        self.lock = threading.Lock()
        self.wake = threading.Event()     # first frame or end of stdout
        self.first = threading.Event()    # first frame
        self.t0: float | None = None
        self.last_out_us: int | None = None
        self.frames = 0
        self.ended = False                # progress=end seen
        self.eof = False                  # stdout closed
        self.ended_at: float | None = None   # clock time when the reader saw stdout close (ffmpeg ended)
        self.stopped = False
        self.markers: list[dict] = []
        self.reader: threading.Thread | None = None

    def running(self) -> bool:
        return not self.stopped and self.proc.poll() is None


class Recorder:
    def __init__(self, root: str, popen: Callable = subprocess.Popen, clock: Callable[[], float] = time.monotonic,
                 now: Callable[[], str] = utc_now, on_spawn: Callable | None = None,
                 first_frame_wait_s: float = FIRST_FRAME_WAIT_S, stop_grace_s: float = STOP_GRACE_S,
                 stop_timeout_s: float = 30.0, marker_wait_s: float = 5.0):
        self.root = root
        self.out_dir = os.path.join(root, "out")
        self.ffmpeg = os.path.join(root, "bin", "ffmpeg.exe")
        self.popen = popen
        self.clock = clock
        self.now = now
        self.on_spawn = on_spawn
        self.first_frame_wait_s = first_frame_wait_s
        self.stop_grace_s = stop_grace_s
        self.stop_timeout_s = stop_timeout_s
        self.marker_wait_s = marker_wait_s
        self._lock = threading.Lock()
        self._session: _Session | None = None

    # -- state ----------------------------------------------------------------------------------------------
    def ffmpeg_present(self) -> bool:
        return os.path.isfile(self.ffmpeg)

    def active(self) -> bool:
        s = self._session
        return s is not None and s.running()

    def _ended_s_ago(self, s: _Session, at: float | None = None) -> float | None:
        if s.ended_at is None:
            return None
        return round(max(0.0, (self.clock() if at is None else at) - s.ended_at), 1)

    def status(self) -> dict:
        """active, filename, started; ended_early (ffmpeg ended by itself and nobody stopped it yet: the video is
        shorter than the time since the start) with ended_s_ago, and then exit_code."""
        s = self._session
        if s is None:
            return {"active": False, "filename": None, "started": None, "ended_early": False, "ended_s_ago": None}
        out = {"active": s.running(), "filename": s.filename, "started": s.started, "ended_early": False,
               "ended_s_ago": None}
        if not out["active"] and not s.stopped:
            out["exit_code"] = s.proc.poll()   # ffmpeg ended by itself; /record/stop collects the file
            out["ended_early"] = True
            out["ended_s_ago"] = self._ended_s_ago(s)
        return out

    def command(self, filename: str, fps: int, crf: int, preset: str) -> list[str]:
        return [self.ffmpeg, "-hide_banner", "-loglevel", "error",
                "-f", "gdigrab", "-framerate", str(fps), "-draw_mouse", "1", "-i", "desktop",
                "-c:v", "libx264", "-preset", preset, "-crf", str(crf), "-pix_fmt", "yuv420p",
                "-progress", "pipe:1", "-nostats",
                os.path.join(self.out_dir, filename)]

    # -- progress -------------------------------------------------------------------------------------------
    def _read(self, s: _Session) -> None:
        block: dict[str, str] = {}
        try:
            for raw in iter(s.proc.stdout.readline, b""):
                line = raw.decode("utf-8", "replace").strip()
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                block[key.strip()] = value.strip()
                if key.strip() == "progress":
                    self._progress(s, block)
                    block = {}
        except (OSError, ValueError):
            pass
        finally:
            s.ended_at = self.clock()
            s.eof = True
            s.wake.set()

    def _progress(self, s: _Session, block: dict[str, str]) -> None:
        frame = _int(block.get("frame"))
        us = _int(block.get("out_time_us"))
        if us is None:
            us = _int(block.get("out_time_ms"))   # older builds: microseconds despite the name
        if us is not None and us < 0:              # older builds print INT64_MIN for "unknown"
            us = None
        with s.lock:
            if frame is not None:
                s.frames = frame
            if us is not None:
                s.last_out_us = us
            if s.t0 is None and frame is not None and frame >= 1 and us is not None:
                s.t0 = self.clock() - us / 1e6
                s.first.set()
                s.wake.set()
            if block.get("progress") == "end":
                s.ended = True

    @staticmethod
    def _halt(proc, grace_s: float) -> tuple[int | None, bool]:
        """"q" on stdin, stdin closed, up to `grace_s` for ffmpeg to end, then kill: (exit code or None, killed)."""
        if proc.poll() is None:
            try:
                proc.stdin.write(b"q")
                proc.stdin.flush()
            except (OSError, ValueError):
                pass
        try:
            proc.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            return proc.wait(timeout=grace_s), False
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                return proc.wait(timeout=5), True
            except subprocess.TimeoutExpired:
                return None, True

    # -- endpoints ------------------------------------------------------------------------------------------
    def start(self, filename: str, fps: int = 30, crf: int = 20, preset: str = "ultrafast",
              deadline: float | None = None) -> dict:
        """Start ffmpeg and answer once it has its first frame. deadline: a time on the clock; the wait for the
        first frame ends early enough that the answer, the cleanup of a failed start included, comes before it."""
        problem = filename_problem(filename)
        if problem:
            raise RecordError("bad-request", problem)
        if preset not in PRESETS:
            raise RecordError("bad-request", f"preset must be one of {', '.join(PRESETS)}")
        with self._lock:
            old = self._session
            if old is not None and old.running():
                raise RecordError("already-recording", f"already recording {old.filename} since {old.started}")
            # a session whose ffmpeg ended by itself is dropped here; its file stays in out\
            self._session = None
            path = os.path.join(self.out_dir, filename)
            if os.path.lexists(path):
                raise RecordError("file-exists", f"{filename} already exists in the out folder")
            base = filename[:-4]
            markers_path = os.path.join(self.out_dir, base + ".markers.json")
            log_path = os.path.join(self.out_dir, base + ".ffmpeg.log")
            cmd = self.command(filename, fps, crf, preset)
            try:
                write_json_atomic(markers_path, [])
                log = open(log_path, "wb")
            except OSError as e:
                raise RecordError("out-not-writable",
                                  f"cannot write to the out folder: {e.strerror or type(e).__name__}") from None
            try:
                proc = self.popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                  creationflags=CREATE_NO_WINDOW)
            except OSError as e:
                raise RecordError("ffmpeg-failed", f"cannot start ffmpeg: {e.strerror or type(e).__name__}") from None
            finally:
                log.close()
            if self.on_spawn is not None:
                try:
                    self.on_spawn(proc)
                except Exception:
                    pass
            s = _Session(proc, filename, path, markers_path, log_path, self.now())
            s.reader = threading.Thread(target=self._read, args=(s,), name="ffmpeg-progress", daemon=True)
            s.reader.start()
            budget = self.first_frame_wait_s
            if deadline is not None:   # leave the time a failed start needs to stop ffmpeg
                budget = min(budget, deadline - self.clock() - self.stop_grace_s - CLEANUP_S)
            budget = max(0.0, budget)
            s.wake.wait(budget)   # set by the first frame or by the end of ffmpeg's output
            if s.t0 is None and s.eof:
                try:
                    rc = proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    rc = proc.wait(timeout=5)
                s.reader.join(timeout=2)
                tail = log_tail(log_path)
                raise RecordError("ffmpeg-failed", f"ffmpeg exited with code {rc}" + (f": {tail}" if tail else ""))
            if s.t0 is None:
                rc, killed = self._halt(proc, self.stop_grace_s)
                s.reader.join(timeout=2)
                for leftover in (path, markers_path):   # nothing was recorded; a retry may use the same name
                    try:
                        os.remove(leftover)
                    except OSError:
                        pass
                tail = log_tail(log_path)
                how = "killed" if killed else f"stopped (exit code {rc})"
                raise RecordError("no-first-frame", f"ffmpeg produced no frame within {round(budget, 1):g} s and was "
                                                    f"{how}; its log is {os.path.basename(log_path)}"
                                                    + (f": {tail}" if tail else ""))
            self._session = s
            return {"path": path, "filename": filename, "markers": markers_path, "started": s.started,
                    "first_frame": True}

    def marker(self, label: str) -> dict:
        with self._lock:
            s = self._session
            if s is None:
                raise RecordError("not-recording", "no recording is running")
            if not s.running():
                if s.stopped:
                    raise RecordError("not-recording", "no recording is running")
                ago = self._ended_s_ago(s)
                raise RecordError("not-recording", "the recording ended by itself"
                                  + (f" {ago:g} s ago" if ago is not None else "")
                                  + f" (ffmpeg exit code {s.proc.poll()}); /record/stop collects the file")
        if s.t0 is None:
            s.first.wait(self.marker_wait_s)
        with s.lock:
            if s.stopped:
                raise RecordError("not-recording", "the recording was stopped")
            if s.t0 is None:
                raise RecordError("not-ready", "ffmpeg has not produced its first frame yet")
            t = round(self.clock() - s.t0, 3)
            entry = {"t": t, "label": label}
            try:   # the marker counts only once the file holds it
                write_json_atomic(s.markers_path, s.markers + [entry])
            except OSError as e:
                raise RecordError("out-not-writable", f"cannot write {os.path.basename(s.markers_path)}: "
                                                      f"{e.strerror or type(e).__name__}; the marker was not kept"
                                  ) from None
            s.markers.append(entry)
            return {"t": t, "count": len(s.markers)}

    def stop(self) -> dict:
        with self._lock:
            s = self._session
            if s is None:
                raise RecordError("not-recording", "no recording to stop")
            stop_at = self.clock()
            with s.lock:
                s.stopped = True
            proc = s.proc
            ended_early = proc.poll() is not None   # ffmpeg was gone before the "q": the video ends early
            if not ended_early:
                try:
                    proc.stdin.write(b"q")
                    proc.stdin.flush()
                except (OSError, ValueError):
                    pass
            try:
                proc.stdin.close()
            except (OSError, ValueError):
                pass
            killed = False
            try:
                rc = proc.wait(timeout=self.stop_timeout_s)
            except subprocess.TimeoutExpired:
                proc.kill()
                killed = True
                rc = proc.wait(timeout=10)
            if s.reader is not None:
                s.reader.join(timeout=5)
            self._session = None
            try:
                size = os.path.getsize(s.path)
            except OSError:
                size = 0
            with s.lock:
                duration = round(s.last_out_us / 1e6, 3) if s.last_out_us is not None else 0.0
                count = len(s.markers)
            result = {"ok": True, "path": s.path, "duration_s": duration, "size_bytes": size,
                      "markers": s.markers_path, "marker_count": count, "exit_code": rc, "killed": killed}
            if ended_early:
                ago = self._ended_s_ago(s, stop_at)
                tail = log_tail(s.log_path)
                why = "ffmpeg ended by itself" + (f" {ago:g} s before the stop" if ago is not None else "")
                why += f" (exit code {rc}); the video ends at {duration:g} s"
                if size == 0:
                    why += ", no video written"
                result.update(ok=False, error="ended-early", ended_s_before_stop=ago,
                              detail=why + (f": {tail}" if tail else ""))
            elif killed or rc != 0 or size == 0:
                tail = log_tail(s.log_path)
                why = "killed after the stop timeout" if killed else f"exited with code {rc}"
                if size == 0:
                    why += ", no video written"
                result.update(ok=False, error="ffmpeg-failed",
                              detail=f"ffmpeg {why}" + (f": {tail}" if tail else ""))
            return result

    def shutdown(self) -> None:
        """Stop a running recording (director exit)."""
        if self._session is not None:
            try:
                self.stop()
            except RecordError:
                pass
