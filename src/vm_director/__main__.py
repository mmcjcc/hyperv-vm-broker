"""python -I -m vm_director [--root DIR] [--port N] [--typing unicode|layout]

Started at logon in the student's session by a scheduled task:
    C:\\ProgramData\\LabDirector\\bin\\python\\pythonw.exe -I -m vm_director
Sets DPI awareness first (per-monitor v2, else system aware), builds the real desktop and serves on 127.0.0.1 until
the process ends. Single instance: if the port is taken it writes one line to out\\director.log and exits 1.
"""

from __future__ import annotations

import argparse
import os
import sys

DEFAULT_ROOT = r"C:\ProgramData\LabDirector"
DEFAULT_PORT = 47800


def main(argv: list[str] | None = None) -> int:
    from . import win32   # first: DPI awareness must be set before anything reads screen metrics

    awareness = win32.set_dpi_awareness()

    from . import VERSION
    from .app import Director
    from .server import RequestLog, make_server

    ap = argparse.ArgumentParser(prog="vm_director", description="vm-broker in-guest director")
    ap.add_argument("--root", default=DEFAULT_ROOT, help=f"director folder (default {DEFAULT_ROOT})")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"port on 127.0.0.1 (default {DEFAULT_PORT})")
    ap.add_argument("--typing", choices=("unicode", "layout"), default="unicode",
                    help="unicode: every character as a KEYEVENTF_UNICODE event (default); layout: characters the "
                         "keyboard layout has a key for are pressed as that key")
    args = ap.parse_args(argv)
    if not 1 <= args.port <= 65535:
        ap.error("--port must be 1 to 65535")

    root = os.path.abspath(args.root)
    out = os.path.join(root, "out")
    try:
        os.makedirs(out, exist_ok=True)
    except OSError:
        return 1   # nowhere to log; the scheduled task's last result shows the exit code
    log = RequestLog(os.path.join(out, "director.log"))

    desktop = win32.Win32Desktop()
    app = Director(root, desktop, typing_mode=args.typing)
    try:
        server = make_server(app, root, args.port, log)
    except OSError as e:
        log.write(f"cannot listen on 127.0.0.1:{args.port} ({e.strerror or type(e).__name__}); "
                  "another director is probably running; exiting")
        return 1

    try:
        session, user = desktop.session_id(), desktop.user()
    except Exception:
        session, user = -1, ""
    log.write(f"start version={VERSION} pid={os.getpid()} port={args.port} session={session} user={user} "
              f"dpi_awareness={awareness} typing={args.typing} python={sys.version.split()[0]}")
    released = app.on_start()   # keys an earlier director left down (killed in the middle of a chord)
    if released:
        log.write("released modifier keys left down: " + " ".join(f"0x{vk:02X}" for vk in released))
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        app.recorder.shutdown()
        server.server_close()
        log.write("stop")
    return 0


if __name__ == "__main__":
    sys.exit(main())
