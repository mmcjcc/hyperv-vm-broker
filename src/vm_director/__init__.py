"""The in-guest director for win11-lab (docs/design.md section 10; CONTRACT.md section 11).

Standard library only (Python 3.14 embeddable distribution; also runs on 3.12), Win32 through ctypes. Staged by
tools/Stage-LabDirector.ps1 into C:/ProgramData/LabDirector/: Python in bin/python/ (its ._pth file puts bin/app on
sys.path), this package in bin/app/vm_director/, a static ffmpeg in bin/ffmpeg.exe (bin/ is Users read only and the
image; no antivirus exclusion: the interpreter is PSF-signed), the per-VM token in token.txt (student read), recordings and director.log in out/
(student modify). Started at logon in the student's session by a scheduled task, at normal
integrity: bin/python/pythonw.exe -I -m vm_director [--root DIR] [--port 47800] [--typing unicode|layout].

HTTP/JSON on 127.0.0.1:47800 only, POST only, "Authorization: Bearer <per-VM token>". Endpoints: /health, /type
(human cadence, Unicode through SendInput), /key (chords), /click (x, y, eased path), /wait_for (window title regex,
or gone; at most 600 s per call; no nested repeats or backreferences), /screenshot (PNG, base64), /record/start and
/record/stop (ffmpeg gdigrab; refuse unless 1920x1080 at 100 % with 2 GB free; start answers once ffmpeg has its first
frame, else no-first-frame; a recording ffmpeg ended by itself answers ended-early), /marker (time from ffmpeg's first
frame), /run_visible (Windows Terminal or PowerShell; a new one is typed into once its new shell has done real work
and then sits idle; typing stops when the terminal loses the foreground; then Enter). "X-Vmb-Timeout: <seconds>" (the
relay's timeout) gives a request a deadline: input actions do no more after it (no key, no button), and
/record/start waits for the first frame only that long. v2: find and click by image or by UI Automation name.

Holds no credentials. Modules:
  desktop.py   the Desktop interface every other module uses (tests pass a fake one)
  win32.py     Win32Desktop: the only module that calls Win32 (SendInput, EnumWindows, BitBlt/GetDIBits, ...)
  keys.py      human-cadence typing and key chords
  mouse.py     eased cursor path and clicks
  windows.py   window-title waits and finding a terminal window
  png.py       BGRA -> PNG encoder (zlib)
  record.py    ffmpeg recording, -progress parsing, markers
  payload.py   payload validation (closed field lists, types, ranges)
  app.py       the endpoints
  server.py    HTTP server: 127.0.0.1 only, Host/Origin checks, token, size limit, request log
  __main__.py  command line, DPI awareness, single instance
"""

VERSION = "0.1.3"
