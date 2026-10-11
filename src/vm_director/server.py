"""HTTP/JSON front of the director: 127.0.0.1 only, POST only, bearer token, one log line per request.

Order of checks for every request:
  1. an Origin header, or a Host header other than 127.0.0.1:<port> / localhost:<port>  -> 403 (browsers, rebinding)
  2. a method other than POST                                                           -> 405
  3. Authorization: Bearer <token> against <root>\\token.txt (hmac.compare_digest; the file is re-read when its
     mtime or size changes; missing, empty or shorter than 16 characters -> every request) -> 401
  4. an unknown path                                                                    -> 404
  5. a body over 64 KiB                                                                 -> 413 (chunked: 411)
  6. a body that is not a JSON object (empty is {})                                     -> 400
  7. the endpoint                                                                       -> 200 with {"ok": ...}
A well-formed request always gets 200 with {"ok": true, ...} or {"ok": false, "error": "<word>", "detail": "<one
printable line>"}; an unexpected exception is a 200 with error "internal" and the exception's type name (where it
happened goes to the log), never a stack trace.

"X-Vmb-Timeout: <whole seconds, 1..900>" (the relay sends its timeout for the step): the endpoint gets a deadline of
the request's start + that - 2 s, on the app's clock (time.monotonic in the guest). Input actions do no more after
it (app.py). A missing, repeated or bad value means no deadline.

The log, <root>\\out\\director.log, gets one line per request (UTC time, endpoint, HTTP status, ok, error word, ms),
rotated at 1 MiB to director.log.1. It never holds the token or payload text. The socket is bound with
SO_EXCLUSIVEADDRUSE (and without SO_REUSEADDR), so no other process can bind the port beside the director.
"""

from __future__ import annotations

import datetime
import hmac
import json
import os
import socket
import socketserver
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import VERSION

MAX_BODY = 64 * 1024
DRAIN_LIMIT = 1024 * 1024
MIN_TOKEN_CHARS = 16
LOG_MAX_BYTES = 1024 * 1024
TIMEOUT_HEADER = "X-Vmb-Timeout"
MAX_RELAY_TIMEOUT_S = 900
DEADLINE_MARGIN_S = 2.0   # the answer must be on its way before the relay gives up

HTTP_WORDS = {400: "bad-json", 401: "unauthorized", 403: "forbidden", 404: "not-found", 405: "method-not-allowed",
              408: "timeout", 411: "length-required", 413: "too-large", 414: "too-large", 431: "too-large",
              500: "internal", 501: "method-not-allowed", 505: "bad-http"}


def one_line(text, limit: int = 300) -> str:
    """Printable, single line, at most `limit` characters."""
    s = "".join(ch if ch.isprintable() else " " for ch in str(text))
    s = " ".join(s.split())
    return s if len(s) <= limit else s[:limit - 3] + "..."


def where(exc: BaseException) -> str:
    """Exception type and the innermost frames (file:line function), without the message (it may hold payload)."""
    frames = traceback.extract_tb(exc.__traceback__)[-3:]
    at = "; ".join(f"{os.path.basename(f.filename)}:{f.lineno} {f.name}" for f in frames)
    return f"{type(exc).__name__} at {at}" if at else type(exc).__name__


class RequestLog:
    """Append-only text log, one line per call, rotated at 1 MiB keeping one old file. Opened per line, so no
    handle stays open (a copy out of the VM can read it at any time)."""

    def __init__(self, path: str, max_bytes: int = LOG_MAX_BYTES):
        self.path = path
        self.max_bytes = max_bytes
        self._lock = threading.Lock()

    def write(self, line: str) -> None:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        with self._lock:
            try:
                if os.path.getsize(self.path) >= self.max_bytes:
                    os.replace(self.path, self.path + ".1")
            except OSError:
                pass
            try:
                with open(self.path, "a", encoding="utf-8", newline="\n") as f:
                    f.write(f"{stamp} {one_line(line, 1000)}\n")
            except OSError:
                pass


class TokenFile:
    """The per-VM token in <root>\\token.txt; re-read when the file's mtime or size changes."""

    def __init__(self, path: str, log: RequestLog | None = None):
        self.path = path
        self.log = log
        self._lock = threading.Lock()
        self._sig = None
        self._token = ""

    @staticmethod
    def decode(raw: bytes) -> str:
        if raw.startswith((b"\xff\xfe", b"\xfe\xff")):   # Windows PowerShell 5.1 Out-File writes UTF-16
            text = raw.decode("utf-16")
        else:
            text = raw.decode("utf-8-sig", "replace")    # Set-Content -Encoding UTF8 writes a BOM
        return text.strip()

    def get(self) -> str:
        with self._lock:
            try:
                st = os.stat(self.path)
            except OSError:
                self._sig, self._token = None, ""
                return ""
            sig = (st.st_mtime_ns, st.st_size)
            if sig != self._sig:
                try:
                    with open(self.path, "rb") as f:
                        token = self.decode(f.read(4096))
                except (OSError, UnicodeError):
                    token = ""
                if token and len(token) < MIN_TOKEN_CHARS:
                    if self.log:
                        self.log.write(f"token.txt holds fewer than {MIN_TOKEN_CHARS} characters; refusing every call")
                    token = ""
                self._sig, self._token = sig, token
            return self._token

    def check(self, header: str | None) -> bool:
        token = self.get()
        if not token or not header:
            return False
        parts = header.split(None, 1)
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return False
        return hmac.compare_digest(parts[1].strip().encode("utf-8"), token.encode("utf-8"))


def _reject_constant(name):
    raise ValueError(f"{name} is not JSON")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"   # so Expect: 100-continue (Windows PowerShell's default) gets its 100 at once
    timeout = 30                    # socket reads; a silent client cannot hold a thread for ever
    server: "DirectorServer"

    def version_string(self) -> str:
        return "vm-director"

    def log_message(self, format, *args):   # http.server writes to stderr, which pythonw does not have
        pass

    # every method lands here; only POST gets past the method check
    def do_POST(self):
        self._serve()

    do_GET = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_TRACE = do_CONNECT = do_POST

    def send_error(self, code, message=None, explain=None):
        """Protocol-level errors (bad request line, headers too long, unsupported method): JSON, then close."""
        self.close_connection = True
        try:
            self._send(code, {"ok": False, "error": HTTP_WORDS.get(code, "bad-http"),
                              "detail": one_line(message or explain or "bad request")})
        except OSError:
            pass
        self.server.log.write(f"- status={code} ok=false error={HTTP_WORDS.get(code, 'bad-http')} ms=0")

    def _send(self, status: int, body: dict, headers: tuple = ()) -> None:
        data = json.dumps(body, ensure_ascii=True, separators=(",", ":")).encode("ascii")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if getattr(self, "command", None) != "HEAD":
            self.wfile.write(data)
        self.close_connection = True

    def _content_length(self) -> int | None:
        values = self.headers.get_all("Content-Length") or []
        if not values:
            return 0
        if len(set(v.strip() for v in values)) != 1:
            return None
        try:
            n = int(values[0].strip())
        except ValueError:
            return None
        return n if n >= 0 else None

    def _drain(self) -> None:
        """Read an unused body (up to 1 MiB) so closing the socket does not reset the client before it reads."""
        n = self._content_length()
        if not n or n > DRAIN_LIMIT or self.headers.get("Transfer-Encoding"):
            return
        try:
            while n > 0:
                chunk = self.rfile.read(min(n, 65536))
                if not chunk:
                    break
                n -= len(chunk)
        except OSError:
            pass

    @staticmethod
    def _err(word: str, detail: str) -> dict:
        return {"ok": False, "error": word, "detail": detail}

    def _process(self):
        """(status, body, endpoint label, extra headers)."""
        app = self.server.app
        port = self.server.server_address[1]
        path = self.path
        label = path if path in app.routes else one_line(path, 64) or "-"

        if self.headers.get("Origin") is not None:
            self._drain()
            return 403, self._err("forbidden", "requests from a browser (Origin header) are refused"), label, ()
        hosts = self.headers.get_all("Host") or []
        if len(hosts) != 1 or hosts[0].strip().lower() not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            self._drain()
            return 403, self._err("forbidden", f"Host must be 127.0.0.1:{port} or localhost:{port}"), label, ()
        if self.command != "POST":
            self._drain()
            return 405, self._err("method-not-allowed", "only POST is accepted"), label, (("Allow", "POST"),)
        auths = self.headers.get_all("Authorization") or []
        if len(auths) != 1 or not self.server.tokens.check(auths[0]):
            self._drain()
            return 401, self._err("unauthorized", "missing or wrong bearer token"), label, (
                ("WWW-Authenticate", "Bearer"),)
        if path not in app.routes:
            self._drain()
            return 404, self._err("not-found", "unknown endpoint"), label, ()
        if self.headers.get("Transfer-Encoding"):
            return 411, self._err("length-required", "send the body with a Content-Length"), label, ()
        n = self._content_length()
        if n is None:
            return 400, self._err("bad-json", "bad Content-Length"), label, ()
        if n > MAX_BODY:
            self._drain()
            return 413, self._err("too-large", f"the body is over {MAX_BODY} bytes"), label, ()
        try:
            raw = self.rfile.read(n) if n else b""
        except OSError:   # the client stopped sending (socket timeout) or went away
            raw = b""
        if len(raw) != n:
            return 400, self._err("bad-json", "the body ended early"), label, ()
        if raw.strip():
            try:
                payload = json.loads(raw.decode("utf-8-sig"), parse_constant=_reject_constant)
            except (UnicodeDecodeError, ValueError, RecursionError):
                return 400, self._err("bad-json", "the body is not UTF-8 JSON"), label, ()
            if not isinstance(payload, dict):
                return 400, self._err("bad-json", "the body must be a JSON object"), label, ()
        else:
            payload = {}
        body = app.handle(path, payload, deadline=self._deadline())
        if not body.get("ok") and "detail" in body:
            body["detail"] = one_line(body["detail"])
        return 200, body, label, ()

    def _deadline(self) -> float | None:
        """From X-Vmb-Timeout: the request's start (on the app's clock) + the relay's timeout - DEADLINE_MARGIN_S;
        None without exactly one header holding whole seconds 1..MAX_RELAY_TIMEOUT_S."""
        values = self.headers.get_all(TIMEOUT_HEADER) or []
        if len(values) != 1:
            return None
        text = values[0].strip()
        if not (text.isascii() and text.isdigit()) or len(text) > 3:
            return None
        seconds = int(text)
        if not 1 <= seconds <= MAX_RELAY_TIMEOUT_S:
            return None
        return self._started + seconds - DEADLINE_MARGIN_S

    def _serve(self) -> None:
        start = time.monotonic()
        self._started = getattr(self.server.app, "clock", time.monotonic)()   # the deadline's base
        status, body, label, headers = 500, None, "-", ()
        try:
            status, body, label, headers = self._process()
        except Exception as e:   # never a stack trace to the caller; where it happened goes to the log
            self.server.log.write(f"internal error: {where(e)}")
            status, body = 200, self._err("internal", f"unexpected {type(e).__name__}; see out/director.log")
        try:
            self._send(status, body, headers)
        except OSError:
            pass
        ms = int((time.monotonic() - start) * 1000)
        ok = bool(body.get("ok")) if isinstance(body, dict) else False
        err = f" error={body.get('error')}" if isinstance(body, dict) and not ok and body.get("error") else ""
        self.server.log.write(f"{label} status={status} ok={'true' if ok else 'false'}{err} ms={ms}")


class DirectorServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False   # on Windows SO_REUSEADDR would let a second socket share the port

    def __init__(self, app, port: int, root: str, log: RequestLog):
        self.app = app
        self.log = log
        self.tokens = TokenFile(os.path.join(root, "token.txt"), log)
        super().__init__(("127.0.0.1", port), Handler)

    def server_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        socketserver.TCPServer.server_bind(self)   # skips HTTPServer's getfqdn() (a DNS lookup)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if exc is not None and not isinstance(exc, (ConnectionError, TimeoutError)):
            self.log.write(f"connection error: {where(exc)}")


def make_server(app, root: str, port: int, log: RequestLog | None = None) -> DirectorServer:
    out = os.path.join(root, "out")
    log = log or RequestLog(os.path.join(out, "director.log"))
    return DirectorServer(app, port, root, log)


__all__ = ["DirectorServer", "Handler", "RequestLog", "TokenFile", "make_server", "VERSION"]
