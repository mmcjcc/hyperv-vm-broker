"""HyperVBackend: runs the host verbs (backend/ps/Vmb.ps1) over WinRM from the laptop (direct mode, v0.1 and v0.R).

Each call starts Windows PowerShell with backend/runner.ps1 and writes one JSON envelope to its stdin: the host, the
verb, its arguments, the code version, and the path of netadmin's Get-HomelabCredential.ps1. The runner loads the
credential from the DPAPI cache only (with a -ConfigPath that does not exist, so it never reads netadmin's
config.txt), opens one Kerberos session, and prints "VMB-RESULT:{json}". Arguments never go on a command line: an
envelope can carry a product key (vmb-admin activate). Nothing here logs the envelope.

Every child process starts with its stdin from our own pipe and its stdout captured: the MCP server's stdio is the
JSON-RPC stream. Consumer strings travel only as JSON values; the host scripts take them as data.
"""
import hashlib
import json
import os
import subprocess
from pathlib import Path

from . import HOSTS, Backend
from .. import schema as S

PS_DIR = Path(__file__).resolve().parent / "ps"
RUNNER = Path(__file__).resolve().parent / "runner.ps1"
POWERSHELL = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0",
                          "powershell.exe")


def host_scripts():
    """The scripts that go into the host's code folder, sorted by name."""
    return sorted(p for p in PS_DIR.glob("*.ps1") if p.is_file())


def code_version():
    """SHA-256 over each host script's name and SHA-256; the host keeps the same value in code\\VERSION."""
    h = hashlib.sha256()
    for p in host_scripts():
        h.update(p.name.encode("ascii") + b"\n" + hashlib.sha256(p.read_bytes()).hexdigest().encode("ascii") + b"\n")
    return h.hexdigest()


def child_env():
    """The environment for Windows PowerShell 5.1: without PowerShell 7's PSModulePath, which makes 5.1 load the
    wrong module versions (Get-FileHash and friends go missing)."""
    return {k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}


def _unreachable(hint):
    return {"ok": False, "exit": S.EXIT_UNREACHABLE, "error": "unreachable", "hint": hint}


class HyperVBackend(Backend):
    def __init__(self, loader, hosts=None, runner=None):
        self.loader = loader
        self.hosts = hosts or HOSTS
        self.runner = Path(runner) if runner else RUNNER

    def code_version(self):
        return code_version()

    def call(self, host, verb, args, mode="call", upload=None, download_to=None, stage_inline=False, whatif=False,
             timeout_s=None):
        if host not in self.hosts:
            return {"ok": False, "exit": S.EXIT_REJECTED, "error": "rejected", "hint": "unknown host %s" % host}
        if not self.loader:
            return _unreachable("VMB_CREDENTIAL_LOADER is not set (path of netadmin's Get-HomelabCredential.ps1)")
        envelope = {
            "fqdn": self.hosts[host]["fqdn"], "vmb_root": self.hosts[host]["vmb_root"], "loader": str(self.loader),
            "verb": verb, "args": args or {}, "code": self.code_version(), "whatif": bool(whatif), "mode": mode,
            "upload": upload or [], "download_to": str(download_to) if download_to else None,
            "stage_inline": bool(stage_inline),
        }
        data = json.dumps(envelope, ensure_ascii=True).encode("ascii")
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            p = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                                str(self.runner)], input=data, capture_output=True, timeout=timeout_s or 4200,
                               creationflags=flags, env=child_env())
        except subprocess.TimeoutExpired:
            return _unreachable("the call to %s did not finish in time (%s s)" % (host, timeout_s or 4200))
        except OSError as e:
            return _unreachable("cannot start Windows PowerShell: %s" % e.strerror)
        out = p.stdout.decode("ascii", errors="replace").splitlines()
        result, download = None, None
        for line in out:
            if line.startswith("VMB-RESULT:"):
                try:
                    result = json.loads(line[len("VMB-RESULT:"):])
                except ValueError:
                    result = None
            elif line.startswith("VMB-DOWNLOAD:"):
                try:
                    download = json.loads(line[len("VMB-DOWNLOAD:"):])
                except ValueError:
                    download = None
        if not isinstance(result, dict):
            err = p.stderr.decode("ascii", errors="replace").strip().splitlines()
            first = next((ln.strip() for ln in err if ln.strip()), "no output")
            return _unreachable("the host gave no answer (%s)" % "".join(ch for ch in first if 0x20 <= ord(ch) < 0x7F)[:200])
        if download is not None:
            result["download"] = download
        return result
