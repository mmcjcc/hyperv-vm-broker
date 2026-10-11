"""Constants of the closed contract-1 request schema (docs/design.md 4 to 6; CONTRACT.md 3). Standard library only,
no I/O. Every pattern is used with re.fullmatch, never match or search (as in app-broker's schema.py).
"""
import re

CONTRACT = 1

# ---- sizes ----
MAX_REQUEST_BYTES = 32 * 1024
MAX_COMMAND_BYTES = 300            # the v1 gate's command line
MAX_STDIN_BYTES = 1024 * 1024      # the v1 gate's JSON arguments
MAX_SCRIPTS = 8
MAX_SCRIPT_BYTES = 64 * 1024
MAX_SCRIPTS_TOTAL = 256 * 1024
MAX_USERS = 8
MAX_KEYS_PER_USER = 8
MAX_FIREWALL_RULES = 32
MAX_PACKAGES_PER_LIST = 64
MAX_CHECKPOINTS = 40
MAX_LEASE_DAYS = 30
DEFAULT_LEASE_DAYS = 7
MEMORY_STEP_MB = 256
MAX_CPU = 4
MAX_MEMORY_MB = 16 * 1024
MAX_DISK_GB = 500
MCP_RESULT_MAX_BYTES = 64 * 1024
WAIT_FOR_MAX_S = 600
RUN_COMMAND_MAX_BYTES = 8 * 1024
RUN_TIMEOUT_DEFAULT_S = 300
RUN_TIMEOUT_MAX_S = 3600
COPY_TO_MAX_BYTES = 512 * 1024 * 1024        # v0.1 and v0.R (WinRM copy); 2 GiB in v1
COPY_FROM_MAX_BYTES = 8 * 1024 * 1024 * 1024
WAIT_DEFAULT_S = 120
WAIT_MAX_S = 600
DIRECTOR_MAX_STEPS = 50
DIRECTOR_PAYLOAD_MAX_BYTES = 64 * 1024
DIRECTOR_STEP_MAX_S = 900      # the host refuses a longer step
DIRECTOR_CALL_MAX_S = 1800     # one director call (batch included): the MCP server serves one call at a time
PURPOSE_MAX = 200

# ---- exit codes (docs/design.md 5.5) ----
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_REJECTED = 2
EXIT_BUSY = 3
EXIT_NOT_DONE = 4
EXIT_WAITING_FOR_OPERATOR = 5
EXIT_NO_CAPACITY = 6
EXIT_UNREACHABLE = 255

# ---- names ----
NAME_RE = re.compile(r"[a-z][a-z0-9-]{1,10}")
RESERVED_NAME_PREFIXES = ("rtr-", "img-", "net-")
NET_RE = re.compile(r"[a-z][a-z0-9]{1,6}")
CONSUMER_RE = re.compile(r"[a-z][a-z0-9-]{1,39}")
HOSTNAME_RE = re.compile(r"[a-z][a-z0-9-]{0,14}")
USER_RE = re.compile(r"[a-z][a-z0-9_-]{0,19}")
RESERVED_USERS = frozenset({"administrator", "guest", "root", "vmb", "vmbadmin", "student", "ubuntu", "daemon", "nobody"})
SECRET_NAME_RE = re.compile(r"[A-Z][A-Z0-9_]{0,63}")
LABEL_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,47}")
ID_RE = re.compile(r"[0-9a-f]{32}")
HOST_NAMES = ("servera", "serverd")
MEMORY_RE = re.compile(r"([1-9][0-9]{0,5})(g|m)")
DISK_RE = re.compile(r"([1-9][0-9]{0,3})g")

PACKAGE_RES = {
    "features": re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,99}"),
    "winget": re.compile(r"[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}"),
    "choco": re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}"),
    "apt": re.compile(r"[a-z0-9][a-z0-9+.-]{0,63}"),
}

SSH_KEY_TYPES = ("ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "sk-ssh-ed25519@openssh.com", "ssh-rsa")
SSH_KEY_RE = re.compile(r"(\S+) ([A-Za-z0-9+/]{16,8192}={0,3})( [\x21-\x7e][\x20-\x7e]{0,99})?")
SSH_RSA_MIN_BITS = 3072

VM_PREFIX = "vmb-"
ROUTER_PREFIX = "vmb-rtr-"
IMAGE_BUILD_PREFIX = "vmb-img-"
IMAGE_BUILD_CODES = ("w25c", "w25d", "w11l", "ubs", "ubx", "rtr")
NET_SWITCH_PREFIX = "vmb-net-"
NOTES_TAG = "vm-broker id={id}; do not edit"

# ---- the production denylist (docs/design.md 6.2) and switches ----
DENY_PATTERNS = ("Firewall*", "servera", "serverd", "servere", "docker01", "claude01", "cloud01", "ops01", "Lab*")
ALLOWED_EXTERNAL_SWITCH = "LAN2"

# ---- firewall sources (docs/design.md 7.5) ----
LAN_SOURCES = ("192.168.10.0/24", "10.18.0.0/24", "10.20.100.0/24")
ISOLATED_RANGE = "10.77.0.0/16"
FIREWALL_PROTOS = ("tcp", "udp")

# ---- secret-looking content the validator refuses (docs/design.md 11) ----
SECRET_PATTERNS = (
    ("a private key block", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("a product key", re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}-[A-Za-z0-9]{5}(?![A-Za-z0-9])")),
    ("a GitHub token", re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")),
    ("an AWS access key", re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("a Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("an API key (sk-...)", re.compile(r"\bsk-(ant-)?[A-Za-z0-9_-]{20,}")),
    ("a GitLab token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}")),
    ("a Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
)

# ---- director actions (CONTRACT.md 11) ----
DIRECTOR_ACTIONS = ("health", "type", "key", "click", "wait_for", "screenshot", "record_start", "record_stop", "marker",
                    "run_visible")
# v0's positional shorthand: vmb director lab-p1 record_start smoke.mkv
DIRECTOR_SHORTHAND = {"type": "text", "key": "combo", "wait_for": "window_title", "record_start": "filename",
                      "marker": "label", "run_visible": "command"}

_ALL_VERBS = ("contract", "whoami", "profiles", "capacity", "plan", "create", "list", "status", "start", "stop",
              "destroy", "extend", "snapshot", "restore", "snapshots", "snapshot-rm", "run", "copy-to", "copy-from",
              "director", "console", "job", "wait")

# ---- stages: what each one offers (docs/design.md 6.6 and 14) ----
# v0.R is the recording slice: one win11-lab VM (lab_os win2025) on lan (Q16's interim), activation and keep only for
# the recording VM that the host policy names, no destroy or extend; on serverd (the operator, 2026-10-10: servera is to be
# rebuilt soon). The host re-checks all of it.
STAGES = {
    "v0.R": {
        "profiles": ("win11-lab",),
        "networks": ("lan",),
        "access": (),
        "hosts": ("serverd",),
        "verbs": tuple(v for v in _ALL_VERBS if v not in ("destroy", "extend")),
        "activation_mak": "recording-vm", "keep": "recording-vm",
        "users": False, "software": False, "scripts": False, "firewall": False, "secrets": False,
    },
    "v0.1": {
        "profiles": ("win2025-core", "ubuntu-server"),
        "networks": ("lan",),
        "access": ("ssh",),
        "hosts": ("servera",),
        "verbs": tuple(v for v in _ALL_VERBS if v != "director"),
        "activation_mak": None, "keep": None,
        "users": True, "software": True, "scripts": True, "firewall": True, "secrets": False,
    },
    "v0.2": {
        "profiles": ("win2025-core", "ubuntu-server", "win11-lab"),
        "networks": ("lan", "isolated"),
        "access": ("ssh",),
        "hosts": ("servera",),
        "verbs": _ALL_VERBS,
        "activation_mak": None, "keep": None,
        "users": True, "software": True, "scripts": True, "firewall": True, "secrets": False,
    },
    "v1": {
        "profiles": ("win2025-core", "win2025-desktop", "win11-lab", "ubuntu-server", "ubuntu-desktop-xrdp"),
        "networks": ("lan", "isolated"),
        "access": ("ssh", "rdp", "winrm", "xrdp"),
        "hosts": ("servera", "serverd"),
        "verbs": _ALL_VERBS,
        "activation_mak": "approval", "keep": "approval",
        "users": True, "software": True, "scripts": True, "firewall": True, "secrets": True,
    },
}
CURRENT_STAGE = "v0.R"
