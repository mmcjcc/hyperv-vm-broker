"""How the CLI and the MCP server reach the broker (the transport split, docs/design.md 3.2 and 3.3).

v0.R and v0.1 run in direct mode on the operator's laptop: broker.py in-process, the Hyper-V backend over WinRM with
netadmin's DPAPI credential (backend/hyperv.py). v1 adds an SSH transport to the gate; not built yet.

Here: the per-machine settings (%LOCALAPPDATA%/vm-broker/client.env or ~/.config/vm-broker/client.env, names in
.env.example; environment variables of the same names win), the consumer name (one line in vmbroker/consumer at the
root of the project repo; no flag or setting overrides it), and make_broker(), which builds the broker without
touching the network (the MCP server calls it before it answers initialize).
"""
import os
import re
from pathlib import Path

from . import schema as S

SETTING_NAMES = ("VMB_TRANSPORT", "VMB_HOSTS", "VMB_CREDENTIAL_LOADER", "VMB_SSH_ALIAS_PREFIX", "VMB_OUT_DIR",
                 "VMB_WAIT_S")


def settings_path():
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "vm-broker" / "client.env"
    return Path.home() / ".config" / "vm-broker" / "client.env"


def load_settings(path=None, environ=None):
    environ = os.environ if environ is None else environ
    values = {}
    p = Path(path) if path else settings_path()
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        text = ""
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if k in SETTING_NAMES:
            values[k] = v
    for k in SETTING_NAMES:
        if environ.get(k):
            values[k] = environ[k]
    s = {
        "transport": values.get("VMB_TRANSPORT") or "direct",
        "hosts": [h.strip() for h in (values.get("VMB_HOSTS") or "servera").split(",") if h.strip()],
        "loader": values.get("VMB_CREDENTIAL_LOADER") or "",
        "out_dir": values.get("VMB_OUT_DIR") or "",
        "wait_s": S.WAIT_DEFAULT_S,
    }
    try:
        s["wait_s"] = max(0, min(S.WAIT_MAX_S, int(values.get("VMB_WAIT_S") or S.WAIT_DEFAULT_S)))
    except ValueError:
        pass
    return s


class ConsumerError(Exception):
    pass


def find_repo_root(start=None):
    """The nearest folder at or above start that holds vmbroker/consumer (else the nearest with .git)."""
    here = Path(start or os.getcwd()).resolve()
    git = None
    for d in [here] + list(here.parents):
        if (d / "vmbroker" / "consumer").is_file():
            return d
        if git is None and (d / ".git").exists():
            git = d
    return git


def read_consumer(repo_root):
    if repo_root is None:
        raise ConsumerError("no vmbroker/consumer in this project (one line: the project's consumer name)")
    p = Path(repo_root) / "vmbroker" / "consumer"
    try:
        lines = p.read_text(encoding="utf-8").splitlines()
    except OSError:
        raise ConsumerError("no vmbroker/consumer in this project (one line: the project's consumer name)")
    name = lines[0].strip() if lines else ""
    if not S.CONSUMER_RE.fullmatch(name) or name.endswith("-"):
        raise ConsumerError("vmbroker/consumer must hold one name matching ^[a-z][a-z0-9-]{1,39}$ (no trailing hyphen)")
    return name


def is_under_onedrive(path):
    p = str(Path(path).resolve()).lower()
    roots = [os.environ.get(k) for k in ("OneDrive", "OneDriveCommercial", "OneDriveConsumer")]
    if any(r and p.startswith(str(Path(r).resolve()).lower()) for r in roots):
        return True
    return re.search(r"[\\/]onedrive( - [^\\/]*)?[\\/]", p + os.sep) is not None


def make_broker(cwd=None, backend=None, settings=None):
    """The broker for this project, without any network call."""
    from .broker import Broker
    s = settings or load_settings()
    root = find_repo_root(cwd)
    consumer, consumer_error = None, None
    try:
        consumer = read_consumer(root)
    except ConsumerError as e:
        consumer_error = str(e)
    if backend is None:
        from .backend.hyperv import HyperVBackend
        backend = HyperVBackend(s["loader"])
    return Broker(backend, consumer=consumer, consumer_error=consumer_error, repo_root=root, settings=s)
