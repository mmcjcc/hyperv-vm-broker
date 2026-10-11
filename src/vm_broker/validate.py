"""Validation of requests and the request hash. Standard library only.

Works on plain dicts (from yamlstrict, or JSON) so the same rules can run on the client (vmb plan), the gate and the
executor. Untrusted input never raises: the result is (normalized request or None, findings), each finding one
printable line naming the field and the rule (app-broker's style). The host re-checks what only it can know (the
recording VM in its policy, a name taken, its capacity) and answers with findings of its own.

Every example in CONTRACT.md section 4 is a golden test case (tests/test_validate.py).
"""
import base64
import hashlib
import ipaddress
import json
import re

from . import schema as S
from .profiles import PROFILES, STAGE_ORDER

TOP_KEYS = ("contract", "name", "profile", "host", "size", "network", "hostname", "access", "users", "firewall",
            "software", "scripts", "checkpoints", "activation", "director", "lease", "autostart", "purpose")
REQUIRED = ("contract", "name", "profile", "network", "purpose")


class _F:
    def __init__(self):
        self.items = []

    def add(self, field, rule):
        line = "%s: %s" % (field, rule)
        line = "".join(ch if 0x20 <= ord(ch) <= 0x7E else "?" for ch in line)
        if len(line) > 300:
            line = line[:297] + "..."
        if line not in self.items and len(self.items) < 100:
            self.items.append(line)


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _quote_hint(v):
    return " (YAML read it as a boolean; quote it)" if isinstance(v, bool) else ""


# C0 and C1 controls, DEL, and the invisible and bidi format characters (U+200B-200F, U+2028-202E, U+2060,
# U+2066-2069, U+FEFF): they can hide or reorder what a log line or a path shows.
_INVISIBLE = frozenset("\u200b\u200c\u200d\u200e\u200f\u2028\u2029\u202a\u202b\u202c\u202d\u202e\u2060"
                       "\u2066\u2067\u2068\u2069\ufeff")
SCRIPT_PATH_RE = re.compile(r"[A-Za-z0-9._/-]{1,200}")


def _bad_char(ch):
    o = ord(ch)
    return o < 0x20 or 0x7F <= o <= 0x9F or ch in _INVISIBLE


def _walk_strings(value, path):
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield "%s.%s" % (path, k) if path else str(k), str(k)
            yield from _walk_strings(v, "%s.%s" % (path, k) if path else str(k))
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from _walk_strings(v, "%s[%d]" % (path, i))


def secret_findings(text, field):
    """Findings for text that looks like a secret value (docs/design.md 11). Never echoes the text."""
    out = []
    for what, rx in S.SECRET_PATTERNS:
        if rx.search(text):
            out.append("%s: looks like %s; secrets are names, never values" % (field, what))
    return out


def parse_memory(text):
    m = S.MEMORY_RE.fullmatch(text) if isinstance(text, str) else None
    if not m:
        return None
    n = int(m.group(1))
    return n * 1024 if m.group(2) == "g" else n


def parse_disk(text):
    m = S.DISK_RE.fullmatch(text) if isinstance(text, str) else None
    return int(m.group(1)) if m else None


def format_memory(mb):
    return "%dg" % (mb // 1024) if mb % 1024 == 0 else "%dm" % mb


def _stage_has(stage, item):
    return S.STAGES[stage][item]


def _offered_in(profile_name):
    """The first stage that offers a profile (for 'not in v0.R; from v0.2')."""
    for st in STAGE_ORDER:
        if profile_name in S.STAGES[st]["profiles"]:
            return st
    return "later"


def _rsa_bits(blob_b64):
    try:
        blob = base64.b64decode(blob_b64, validate=True)
        parts = []
        i = 0
        while i < len(blob) and len(parts) < 3:
            n = int.from_bytes(blob[i:i + 4], "big")
            parts.append(blob[i + 4:i + 4 + n])
            i += 4 + n
        if len(parts) != 3 or parts[0] != b"ssh-rsa":
            return 0
        return int.from_bytes(parts[2], "big").bit_length()
    except (ValueError, TypeError):
        return 0


def validate_request(raw, scripts=None, consumer=None, stage=S.CURRENT_STAGE):
    """(normalized, []) or (None, findings). scripts maps each script path named in the request to its bytes."""
    f = _F()
    if stage not in S.STAGES:
        return None, ["stage: unknown stage %s" % stage]
    st = S.STAGES[stage]
    if not isinstance(raw, dict):
        return None, ["request: the top level must be a mapping"]
    for k in raw:
        if not isinstance(k, str) or k not in TOP_KEYS:
            f.add(str(k), "unknown key (the schema is closed; CONTRACT.md 3)")
    for k in REQUIRED:
        if k not in raw:
            f.add(k, "required")
    # no control, invisible or bidi characters and no backticks anywhere; nothing that looks like a secret
    for path, s in _walk_strings(raw, ""):
        if any(_bad_char(ch) for ch in s) or "`" in s:
            f.add(path, "no control, invisible or bidi characters, and no backticks")
        for line in secret_findings(s, path):
            f.items.append(line) if line not in f.items else None
    n = {}

    c = raw.get("contract")
    if "contract" in raw and not (_is_int(c) and c == S.CONTRACT):
        f.add("contract", "must be 1")
    n["contract"] = S.CONTRACT

    name = raw.get("name")
    if "name" in raw:
        if not isinstance(name, str) or not S.NAME_RE.fullmatch(name):
            f.add("name", "must match ^[a-z][a-z0-9-]{1,10}$%s" % _quote_hint(name))
        elif name.endswith("-"):
            f.add("name", "must not end in a hyphen")
        elif name.startswith(S.RESERVED_NAME_PREFIXES + (S.VM_PREFIX,)):
            f.add("name", "rtr-, img-, net- and vmb- are reserved (the VM is called vmb-<name>)")
    n["name"] = name

    prof_name = raw.get("profile")
    prof = PROFILES.get(prof_name) if isinstance(prof_name, str) else None
    if "profile" in raw and not prof:
        f.add("profile", "must be one of %s" % ", ".join(PROFILES))
    elif prof and prof_name not in st["profiles"]:
        f.add("profile", "%s is not in %s (from %s)" % (prof_name, stage, _offered_in(prof_name)))
    n["profile"] = prof_name
    lab_on_lan = stage == "v0.R" and prof_name == "win11-lab"

    host = raw.get("host", "auto")
    if not isinstance(host, str) or host not in ("auto",) + S.HOST_NAMES:
        f.add("host", "auto, servera or serverd%s" % _quote_hint(host))
    elif host != "auto" and host not in st["hosts"]:
        f.add("host", "%s is not in %s" % (host, stage))
    n["host"] = host

    # size
    size = raw.get("size", {})
    if not isinstance(size, dict):
        f.add("size", "a mapping {cpu, memory, disk}")
        size = {}
    for k in size:
        if k not in ("cpu", "memory", "disk"):
            f.add("size.%s" % k, "unknown key")
    d = prof["default"] if prof else {"cpu": 2, "memory_mb": 4096, "disk_gb": 60}
    mn = prof["min"] if prof else {"cpu": 1, "memory_mb": 512, "disk_gb": 10}
    cpu = size.get("cpu", d["cpu"])
    if not _is_int(cpu) or not mn["cpu"] <= cpu <= S.MAX_CPU:
        f.add("size.cpu", "a whole number from %d to %d" % (mn["cpu"], S.MAX_CPU))
    mem = size.get("memory", format_memory(d["memory_mb"]))
    mem_mb = parse_memory(mem)
    if mem_mb is None:
        f.add("size.memory", "like 4g or 512m, lower case")
    elif mem_mb % S.MEMORY_STEP_MB:
        f.add("size.memory", "in steps of 256m")
    elif not mn["memory_mb"] <= mem_mb <= S.MAX_MEMORY_MB:
        f.add("size.memory", "from %s to 16g" % format_memory(mn["memory_mb"]))
    disk = size.get("disk", "%dg" % d["disk_gb"])
    disk_gb = parse_disk(disk)
    if disk_gb is None:
        f.add("size.disk", "like 60g")
    elif not mn["disk_gb"] <= disk_gb <= S.MAX_DISK_GB:
        f.add("size.disk", "from %dg to %dg" % (mn["disk_gb"], S.MAX_DISK_GB))
    n["size"] = {"cpu": cpu, "memory": format_memory(mem_mb) if mem_mb else mem, "disk": disk,
                 "memory_mb": mem_mb, "disk_gb": disk_gb}

    # network
    net = raw.get("network")
    mode = None
    if "network" in raw:
        if not isinstance(net, dict) or not isinstance(net.get("mode"), str):
            f.add("network", "{mode: lan} or {mode: isolated, net: <net>, internet: true|false}")
            net = {}
        mode = net.get("mode")
        if mode == "lan":
            for k in net:
                if k != "mode":
                    f.add("network.%s" % k, "unknown key for mode lan")
            n["network"] = {"mode": "lan"}
        elif mode == "isolated":
            for k in net:
                if k not in ("mode", "net", "internet"):
                    f.add("network.%s" % k, "unknown key")
            if not isinstance(net.get("net"), str) or not S.NET_RE.fullmatch(net.get("net")):
                f.add("network.net", "must match ^[a-z][a-z0-9]{1,6}$")
            if not isinstance(net.get("internet", False), bool):
                f.add("network.internet", "true or false")
            n["network"] = {"mode": "isolated", "net": net.get("net"), "internet": bool(net.get("internet", False))}
        else:
            f.add("network.mode", "lan or isolated")
        if mode in ("lan", "isolated") and mode not in st["networks"]:
            f.add("network.mode", "%s is not in %s" % (mode, stage))
        if prof and mode in ("lan", "isolated") and mode not in prof["networks"] and not lab_on_lan:
            f.add("network.mode", "%s runs only on %s networks" % (prof_name, "/".join(prof["networks"])))

    hostname = raw.get("hostname")
    if "hostname" in raw:
        if prof and not prof["hostname"]:
            f.add("hostname", "not for %s" % prof_name)
        elif mode != "isolated":
            f.add("hostname", "only on isolated networks")
        elif not isinstance(hostname, str) or not S.HOSTNAME_RE.fullmatch(hostname):
            f.add("hostname", "must match ^[a-z][a-z0-9-]{0,14}$")
    n["hostname"] = hostname if "hostname" in raw else None

    # access
    access = raw.get("access", list(prof["default_access"]) if prof else [])
    if not isinstance(access, list) or not all(isinstance(a, str) for a in access):
        f.add("access", "a list of ssh, rdp, winrm, xrdp")
        access = []
    for a in access:
        if a not in ("ssh", "rdp", "winrm", "xrdp"):
            f.add("access", "%s is not an access type" % a)
        elif prof and a not in prof["access"]:
            f.add("access", "%s is not allowed on %s" % (a, prof_name))
        elif a not in st["access"]:
            f.add("access", "%s is not in %s" % (a, stage))
    if len(set(access)) != len(access):
        f.add("access", "each item once")
    n["access"] = sorted(set(a for a in access if isinstance(a, str)))

    # users
    users = raw.get("users", [])
    n["users"] = []
    if "users" in raw:
        if prof and not prof["users"]:
            f.add("users", "not for %s" % prof_name)
        elif not st["users"]:
            f.add("users", "not in %s" % stage)
        if not isinstance(users, list) or len(users) > S.MAX_USERS:
            f.add("users", "a list of at most %d users" % S.MAX_USERS)
            users = []
        seen = set()
        for i, u in enumerate(users):
            p = "users[%d]" % i
            if not isinstance(u, dict):
                f.add(p, "a mapping {name, admin, ssh_keys, password}")
                continue
            for k in u:
                if k not in ("name", "admin", "ssh_keys", "password"):
                    f.add("%s.%s" % (p, k), "unknown key")
            un = u.get("name")
            if not isinstance(un, str) or not S.USER_RE.fullmatch(un):
                f.add(p + ".name", "must match ^[a-z][a-z0-9_-]{0,19}$")
            elif un in S.RESERVED_USERS:
                f.add(p + ".name", "%s is reserved" % un)
            elif un in seen:
                f.add(p + ".name", "each user once")
            seen.add(un)
            if not isinstance(u.get("admin", False), bool):
                f.add(p + ".admin", "true or false")
            keys = u.get("ssh_keys", [])
            if not isinstance(keys, list) or len(keys) > S.MAX_KEYS_PER_USER:
                f.add(p + ".ssh_keys", "a list of at most %d public key lines" % S.MAX_KEYS_PER_USER)
                keys = []
            for j, kl in enumerate(keys):
                m = S.SSH_KEY_RE.fullmatch(kl) if isinstance(kl, str) else None
                if not m or m.group(1) not in S.SSH_KEY_TYPES:
                    f.add("%s.ssh_keys[%d]" % (p, j), "a public key line: %s" % ", ".join(S.SSH_KEY_TYPES))
                elif m.group(1) == "ssh-rsa" and _rsa_bits(m.group(2)) < S.SSH_RSA_MIN_BITS:
                    f.add("%s.ssh_keys[%d]" % (p, j), "ssh-rsa keys need at least 3072 bits")
            pw = u.get("password", "none")
            if isinstance(pw, dict):
                if list(pw) != ["secret"] or not isinstance(pw["secret"], str) or not S.SECRET_NAME_RE.fullmatch(pw["secret"]):
                    f.add(p + ".password", "{secret: NAME} with NAME ^[A-Z][A-Z0-9_]{0,63}$")
                elif not st["secrets"]:
                    f.add(p + ".password", "{secret: NAME} is not in %s" % stage)
            elif pw not in ("none", "generate"):
                f.add(p + ".password", "none, generate or {secret: NAME}%s" % _quote_hint(pw))
            n["users"].append({"name": un, "admin": bool(u.get("admin", False)),
                               "ssh_keys": list(keys) if isinstance(keys, list) else [], "password": pw})
        if any(a in ("rdp", "xrdp") for a in n["access"]) and not any(u["password"] != "none" for u in n["users"]):
            f.add("users", "rdp and xrdp need at least one user with a password (generate or a secret)")

    # firewall
    rules = raw.get("firewall", [])
    n["firewall"] = []
    if "firewall" in raw:
        if lab_on_lan:
            f.add("firewall", "v0.R blocks all inbound on the recording VM; no rules")
        elif not st["firewall"]:
            f.add("firewall", "not in %s" % stage)
        if not isinstance(rules, list) or len(rules) > S.MAX_FIREWALL_RULES:
            f.add("firewall", "a list of at most %d rules" % S.MAX_FIREWALL_RULES)
            rules = []
        for i, r in enumerate(rules):
            p = "firewall[%d]" % i
            if not isinstance(r, dict):
                f.add(p, "{port, proto, from}")
                continue
            for k in r:
                if k not in ("port", "proto", "from"):
                    f.add("%s.%s" % (p, k), "unknown key")
            if not _is_int(r.get("port")) or not 1 <= r.get("port") <= 65535:
                f.add(p + ".port", "1 to 65535")
            if r.get("proto") not in S.FIREWALL_PROTOS:
                f.add(p + ".proto", "tcp or udp")
            src = r.get("from")
            if src == "net":
                if mode != "isolated":
                    f.add(p + ".from", "net only on isolated networks")
            elif src != "lan":
                ok_cidr = False
                try:
                    cidr = ipaddress.ip_network(src, strict=True) if isinstance(src, str) and "/" in src else None
                    ranges = [ipaddress.ip_network(x) for x in S.LAN_SOURCES]
                    if mode == "isolated":
                        ranges.append(ipaddress.ip_network(S.ISOLATED_RANGE))
                    ok_cidr = bool(cidr) and cidr.version == 4 and any(cidr.subnet_of(x) for x in ranges)
                except (ValueError, TypeError):
                    ok_cidr = False
                if not ok_cidr:
                    f.add(p + ".from", "lan, net, or one CIDR inside the LAN, the VPN ranges or the VM's own net")
            n["firewall"].append({"port": r.get("port"), "proto": r.get("proto"), "from": src})

    # software
    sw = raw.get("software", {})
    n["software"] = {}
    if "software" in raw:
        if lab_on_lan:
            f.add("software", "not in v0.R (the lab installs its tools on camera)")
        elif not st["software"]:
            f.add("software", "not in %s" % stage)
        if not isinstance(sw, dict):
            f.add("software", "a mapping of features, winget, choco, apt")
            sw = {}
        for mgr, items in sw.items():
            p = "software.%s" % mgr
            if mgr not in S.PACKAGE_RES:
                f.add(p, "unknown package manager")
                continue
            if prof and mgr not in prof["packages"]:
                f.add(p, "not on %s" % prof_name)
            if not isinstance(items, list) or len(items) > S.MAX_PACKAGES_PER_LIST:
                f.add(p, "a list of at most %d names" % S.MAX_PACKAGES_PER_LIST)
                continue
            for j, it in enumerate(items):
                if not isinstance(it, str) or not S.PACKAGE_RES[mgr].fullmatch(it):
                    f.add("%s[%d]" % (p, j), "a plain package name (no versions, URLs or switches)%s" % _quote_hint(it))
            if len(set(map(str, items))) != len(items):
                f.add(p, "each name once")
            n["software"][mgr] = list(items)

    # scripts
    sc = raw.get("scripts", [])
    n["scripts"] = []
    if "scripts" in raw:
        if lab_on_lan:
            f.add("scripts", "not in v0.R")
        elif not st["scripts"]:
            f.add("scripts", "not in %s" % stage)
        if not isinstance(sc, list) or len(sc) > S.MAX_SCRIPTS:
            f.add("scripts", "a list of at most %d paths" % S.MAX_SCRIPTS)
            sc = []
        total = 0
        for i, path in enumerate(sc):
            p = "scripts[%d]" % i
            if (not isinstance(path, str) or not SCRIPT_PATH_RE.fullmatch(path) or path.startswith("/")
                    or ".." in path):
                f.add(p, "a relative path inside the repo, with forward slashes")
                continue
            want = ".ps1" if prof and prof["os"] == "windows" else ".sh"
            if not path.endswith(want):
                f.add(p, "%s scripts on this profile" % want)
            body = (scripts or {}).get(path)
            if body is None:
                f.add(p, "not found in the repo")
                continue
            total += len(body)
            if len(body) > S.MAX_SCRIPT_BYTES:
                f.add(p, "at most 64 KiB")
            try:
                text = body.decode("utf-8")
            except UnicodeDecodeError:
                f.add(p, "must be UTF-8")
                continue
            for line in secret_findings(text, p):
                f.items.append(line) if line not in f.items else None
            n["scripts"].append({"path": path, "sha256": hashlib.sha256(body).hexdigest()})
        if total > S.MAX_SCRIPTS_TOTAL:
            f.add("scripts", "at most 256 KiB in total")

    # checkpoints, activation, director
    cp = raw.get("checkpoints", prof["checkpoints"] if prof else "production")
    if cp not in ("standard", "production"):
        f.add("checkpoints", "standard or production")
    n["checkpoints"] = cp

    act = raw.get("activation", "none")
    if act not in ("none", "mak"):
        f.add("activation", "none or mak%s" % _quote_hint(act))
    elif prof and act != "none" and act not in prof["activation"]:
        f.add("activation", "not for %s" % prof_name)
    elif act == "mak" and not st["activation_mak"]:
        f.add("activation", "mak is not in %s" % stage)
    n["activation"] = act

    director = raw.get("director", True if prof and prof["director"] else None)
    if "director" in raw:
        if prof and not prof["director"]:
            f.add("director", "only on win11-lab")
        elif not isinstance(director, bool):
            f.add("director", "true or false")
    n["director"] = director

    # lease and autostart
    lease = raw.get("lease", {"days": S.DEFAULT_LEASE_DAYS})
    keep = False
    if not isinstance(lease, dict) or len(lease) != 1 or list(lease)[0] not in ("days", "keep"):
        f.add("lease", "{days: 1-30} or {keep: true}")
        lease = {"days": S.DEFAULT_LEASE_DAYS}
    elif "days" in lease:
        if not _is_int(lease["days"]) or not 1 <= lease["days"] <= S.MAX_LEASE_DAYS:
            f.add("lease.days", "1 to 30 (longer needs the operator)")
    else:
        if lease["keep"] is not True:
            f.add("lease.keep", "only true")
        elif not st["keep"]:
            f.add("lease.keep", "keep is not in %s" % stage)
        keep = True
    if lab_on_lan and not keep:
        f.add("lease", "v0.R has no leases: the recording VM is kept ({keep: true})")
    n["lease"] = {"keep": True} if keep else {"days": lease.get("days", S.DEFAULT_LEASE_DAYS)}

    autostart = raw.get("autostart", False)
    if not isinstance(autostart, bool):
        f.add("autostart", "true or false")
    elif autostart and not keep:
        f.add("autostart", "only with lease: {keep: true}")
    elif autostart and stage == "v0.R":
        f.add("autostart", "not in v0.R")
    n["autostart"] = bool(autostart) if isinstance(autostart, bool) else False

    purpose = raw.get("purpose")
    if "purpose" in raw:
        if not isinstance(purpose, str) or not purpose.strip():
            f.add("purpose", "what the VM is for, as text%s" % _quote_hint(purpose))
        elif len(purpose) > S.PURPOSE_MAX or any(not 0x20 <= ord(ch) <= 0x7E for ch in purpose):
            f.add("purpose", "at most 200 printable ASCII characters")
    n["purpose"] = purpose

    if f.items:
        return None, list(f.items)
    return n, []


def needs_approval(normalized, stage=S.CURRENT_STAGE):
    """Fields that need the operator (docs/design.md 6.6). In v0.R, activation and keep are approved for one VM only, in the
    host policy; the host refuses them for any other."""
    fields = []
    if normalized.get("activation") == "mak":
        fields.append("activation")
    if normalized.get("lease", {}).get("keep"):
        fields.append("lease.keep")
    if normalized.get("autostart"):
        fields.append("autostart")
    if "winrm" in normalized.get("access", []):
        fields.append("access.winrm")
    net = normalized.get("network") or {}
    if net.get("mode") == "isolated" and net.get("internet"):
        fields.append("network.internet")
    return fields


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def request_hash(normalized):
    """SHA-256 of the canonical normalized request; scripts are in it by their SHA-256 (create idempotency)."""
    return hashlib.sha256(canonical_json(normalized).encode("ascii")).hexdigest()


def approval_id(consumer, req_hash, fields):
    text = canonical_json({"consumer": consumer, "request": req_hash, "fields": sorted(fields)})
    return hashlib.sha256(text.encode("ascii")).hexdigest()[:32]
