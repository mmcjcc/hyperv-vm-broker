# vm-broker: design

Status: draft for the operator, 2026-10-08, revised the same day after an adversarial review (outcomes: "Review notes" at
the end). The operator's answers of 2026-10-10 are in (Q3, Q8, Q16; Q4 and Q6 for the recording VM): the first build is the
recording slice v0.R (section 14), due Wednesday 2026-10-14. v0.R is built and its recording VM runs on serverd
(2026-10-11; section 15 has the results). Its deviations from this text are D19 to D24 in section 2.

Inputs: the operator's brief of 2026-10-08, their v0 spec (not in the public copy), the netadmin tools
(`New-WindowsVM.ps1`, `New-LinuxVM.ps1`, `Send-VMKeys.ps1`, `Get-VMScreenshot.ps1`, `Get-HomelabCredential.ps1`,
`lab-ilo\LabBmcAgent.ps1`), netadmin's notes on production memory (2026-09-27) and disk speed (2026-10-02),
app-broker (`HOSTING.md`, `CLAUDE.md`, `broker/homelab/`), and a research pass by Grok
(`docs/research/grok-vm-provisioning-2026-10-08.md`: leads with sources, not verified facts).

Reading order: this file, then `CONTRACT.md` (what a consumer session sees). Section 16 lists every decision that waits
for the operator, each with a recommended default.

## 1. Purpose

vm-broker is the one narrow way for the operator's Claude Code sessions to get VMs on the home Hyper-V hosts. A session writes
a request file (a profile plus options). The broker checks it, builds the VM from a prepared image, sets up users,
remote access, the guest firewall and software, and reports how to reach the VM. The session can then snapshot,
restore, run commands, copy files, drive the desktop (lab profile only) and destroy the VM. It cannot touch anything
else on the hosts.

Consumers:
- First: `cs101-walkthroughs`, the CS 101 lab walkthrough recordings (the v0 spec).
- Then: class lab dry runs, test servers, and apps that need a whole VM (IIS, SQL Server, a Windows desktop app, an
  RDP-able Linux desktop). A web app that fits in a container goes to app-broker instead.

What vm-broker is not:
- not a way to change the hosts, their external switches, DHCP, DNS or OPNsense (netadmin owns those);
- not a way to manage VMs it did not create (Firewall3, the DCs, docker01, claude01, cloud01, ops01, the fw-arbiter lab);
- not a hosting platform for internet-facing services (exposure stays with netadmin and app-broker, section 7.6).

It follows app-broker's model: the request is a REQUEST; the schema is closed and validated strictly; limits are
enforced by the broker, not by the session; the operator approves anything above them; secrets are names, never values.

## 2. Where this deviates from the v0 spec

| # | v0 spec | this design | why |
|---|---|---|---|
| D1 | Windows lab VMs only; Linux out of scope (s. 8) | five profiles, two of them Ubuntu (section 4.2) | The operator's brief: Server 2025 or Linux, GUI and non-GUI, terminal access, firewall, RDP including RDP to Linux |
| D2 | `vm_create(name, template, cpu, mem, disk, switch, resolution)` | a request file by profile, closed schema; the consumer picks a network mode, never a switch | servera's other external switches are `WAN` (the WAN) and `CARP-Sync` (the firewall pair's sync link). A free-form switch is one typo from a VM on the internet side. Few profiles means few images to keep patched and tested |
| D3 | host and guest credentials and the director token in `.env` | no secret in any `.env`. Host access: netadmin's DPAPI credential (v0.1) or a per-machine SSH key (v1). Guest passwords and director tokens are generated per VM and kept on the host | a `.env` in a consumer repo is readable by every session in that repo and one `git add -f` away from GitHub |
| D4 | refuse to destroy a VM not tagged `lab` in Notes | a VM is the broker's only if the name prefix `vmb-`, the Notes tag and the broker's registry entry for that VM id all agree; plus a fixed denylist of production names | anyone with Hyper-V Manager can edit Notes; the registry is the authority |
| D5 | an internal switch `lab` with NAT on the host | a Private switch per lab network, plus a small router VM when the lab needs internet | both hosts are DCs. A host adapter registers itself in AD DNS (the HostLink 10.250.250.9 incident) and gives lab VMs a direct path to a DC's LDAP, SMB and DNS. A Private switch has no host adapter at all |
| D6 | the director listens on the lab switch (HTTP + token) | the director listens on 127.0.0.1 inside the guest; the broker reaches it through PowerShell Direct | the host has no address on a Private switch, so it could not reach a network listener anyway. Nothing listens on any network, and the director works with networking off |
| D7 | one golden Windows 11 VM, checkpoint `golden`, cloned per run | a versioned, read-only golden VHDX per profile. Short-lease clones are differencing disks, long-lived VMs get a full copy. Server images are sysprepped; Linux comes from the Ubuntu cloud image with a NoCloud seed | creating a VM takes seconds instead of a WIM apply or a 20-60 min autoinstall on the slow RAID 5; patches are baked in once per image |
| D8 | recordings copied into the consumer repo (`labs/p1/out/`) | large files land outside OneDrive by default (`C:\work\recordings\<consumer>\`); the repo keeps the markers JSON | OneDrive syncs every large file (machine rule) |
| D9 | ffmpeg `-preset veryfast` in the guest | default `ultrafast` in the guest and a re-encode on the laptop afterwards; broker VMs get a lower CPU weight than production VMs and a CPU limit | the host is a 4-core Xeon E-2224 shared with the production firewall. Measure first (section 15); keep `veryfast` if it fits |
| D10 | `/find`, image `/click`, image `/wait_for` (OpenCV) in v1 | v1: coordinates, keys, window titles, `run_visible`. Image matching or UI Automation in v2 | OpenCV makes the exe large; template matching breaks on DPI, theme and font changes; most lab steps have a keyboard path |
| D11 | tools return when the work is done | long operations (create, restore, destroy) are jobs; a tool waits up to a limit and otherwise returns the job id | a dropped WinRM shell ends a long wait (`New-WindowsVM.ps1` note), and MCP tool calls time out |
| D12 | "Enhanced Session off" | the broker never changes host-wide settings at run time (its one-time install steps: section 3.8). `vm_console` tells the operator to use a basic session; the director refuses to record unless the desktop is 1920x1080 at 100 %; RDP is off for `win11-lab` | the enhanced-session switch is a host setting shared with production; an RDP logon takes over the auto-logon console session and the recording goes black |
| D13 | pause Windows Update for 5 weeks | the golden image holds updates by policy (notify only, no auto-restart); updates go in when the image is rebuilt | a pause expires after 35 days, and restoring an old checkpoint moves the guest clock forward past the pause date |
| D14 | the director token is generated at image build | the token is generated per VM at clone time | every clone of an image would otherwise share one token |
| D15 | one acceptance test (Windows lab) | three: the v0 lab sequence, an `ubuntu-desktop-xrdp` VM, and the guardrails | Linux is in scope; refusals must be shown to work |
| D16 | backend as a class so Azure/VMware can be added | kept, plus a fake backend for unit tests and a transport split (direct WinRM in v0.1, the SSH gate in v1) | |
| D17 | `vm_create` defaults cpu=4, mem_gb=8 | `win11-lab` defaults to 3 vCPUs and 6g; every broker VM gets a CPU limit (75 %) and a disk I/O cap | the host has 4 cores and one slow RAID 5 shared with the production firewall and a DC (sections 6.4, 6.5). Measure (section 15), then raise if it fits |
| D18 | two checkpoints per chapter (`-start` and `-end`, s. 6) | one checkpoint per chapter boundary: the end of chapter N is the start of chapter N+1 (section 10.6) | a standard checkpoint of a running VM writes its whole memory to the slow array: minutes for 6-8 GB (section 6.5) |
| D19 | the director as one exe (PyInstaller; spec s. 5) | the Python 3.14 embeddable distribution (PSF-signed `python.exe`/`pythonw.exe`) plus the `vm_director` source under `LabDirector\bin\`, started as `pythonw.exe -I -m vm_director`; standard library only (ctypes for input, capture and windows; zlib for PNG) | no unsigned bootloader for Defender to flag, no build step, one download of 12.7 MB instead of PyInstaller plus pyautogui, mss and Pillow; changes Q19's default |
| D20 | MCP server with FastMCP (spec s. 1) | a JSON-RPC 2.0 stdio server written with the standard library (`vm_broker/mcp.py`) | fewer third-party packages in the process that holds the host credential; the protocol subset the tools need is small |
| D21 | `policy.yml` on each host (3.5) | `policy.json` | the host scripts run in Windows PowerShell 5.1, which has no YAML parser; the operator edits it through `hostctl set-policy` (later `vmb-admin`) |
| D22 | the director token kept by the broker in `secrets\` (10.2) | the token is made inside the guest when the director is installed and never leaves it: the relay's own script block reads `token.txt` inside the guest and posts to 127.0.0.1 | one secret fewer on the host, and nothing to keep in step after a restore |
| D23 | updates held by "notify only" (D13, 8.3) | `NoAutoUpdate = 1` plus no automatic restart; the broker installs updates itself through the WUA API in a SYSTEM task in the guest | a notify-only policy shows an "updates available" toast, which would be filmed |
| D24 | one director call per step | also `batch`: up to 50 steps in one guest session | each relay call costs seconds (WinRM, then PowerShell Direct), and that pause shows in the video between calls |

Everything else in v0 stays: the operation names, the "clean student PC" (no dev tools, auto-logon `student`,
1920x1080 at 100 %, light theme, no first-run prompts), the director's endpoints and typing cadence, the recording
path, human steps in VMConnect with the GitHub device-code flow, and the acceptance sequence.

## 3. Architecture

### 3.1 Components

| component | what it does | where it runs | language |
|---|---|---|---|
| `vmb` CLI | the verbs, for humans and scripts | laptop (v0.1); laptop and claude01 (v1) | Python |
| MCP server (`python -I -m vm_broker.mcp`) | the same verbs as MCP tools, a standard-library JSON-RPC server over stdio (D20) | the consumer session's machine | Python |
| broker core | validation, policy, ownership checks, planning, jobs | laptop (v0.1); each Hyper-V host (v1) | Python |
| backend scripts | the Hyper-V and in-guest work: clone, configure, checkpoint, run, copy, destroy | each Hyper-V host, always | Windows PowerShell 5.1, ASCII only |
| gate (v1) | SSH forced command: parses the verb, validates, passes the request to the executor | each host, as an account with no rights | Python |
| executor (v1) | re-validates, runs the backend scripts, runs jobs, applies leases, watches host memory | each host, a SYSTEM scheduled task at startup | Python (embeddable) |
| `vmb-admin` | The operator's verbs: approve, secrets, passwords, budgets, images, freeze; a subset from v0.1 (section 5.2) | The operator's own terminal on the laptop (direct WinRM, a TTY is required) | Python |
| image builds | the golden images | each host, started by the operator | PowerShell |
| director | input, screenshots and recording inside a `win11-lab` VM | the guest, the logged-on session | Python, packaged as one exe |
| router VM | NAT and DNS for an isolated net that has internet | one broker VM per such net | Ubuntu (built from the `ubuntu-server` image), nftables, dnsmasq |

### 3.2 v0.1: direct mode, from the operator's laptop

```
consumer session (laptop) --MCP/CLI--> broker core (laptop, same Windows user)
     |  WinRM + Kerberos as svc-vmb@corp.example (netadmin's Get-HomelabCredential.ps1, DPAPI cache)
     v
servera: backend scripts. Short calls run inline; long ones run as one-shot SYSTEM scheduled tasks
     |  Hyper-V cmdlets; PowerShell Direct with the VM's own admin credential
     v
broker VMs (vmb-*)
```

- The consumer session runs as the operator on the laptop and could reach the same credential itself. In v0.1 the guardrails
  are code, not a boundary. That is acceptable for the operator's own sessions on the laptop, and for nothing else.
- Long jobs run as tasks on the host, so a closed laptop lid or a dropped WinRM shell does not stop a build. The
  client polls `jobs\<id>.json` on the host.
- **Check and reserve on the host, under a lock.** Every MCP server and CLI process is its own broker core, so two
  sessions could both pass a capacity check made on the laptop. One backend script therefore opens the lock file
  `state\lock` with no sharing (Windows releases it if the process dies), checks the budget, the quota, the name and
  "one job per VM", writes the registry record or the job record, and closes the lock. The laptop's own checks only
  make errors arrive early.
- **The credential:** the client calls `Get-HomelabCredential.ps1` with `-ConfigPath` set to a path that does not
  exist. A missing DPAPI cache is then an error ("ask the operator to refresh the cache"), never a read of netadmin's
  `config.txt`, which the loader otherwise falls back to.
- The registry and all state live on the host from the start, and the consumer is the project in v0.1 and in v1
  (section 3.4), so v1 needs no migration. `vmb-admin owner` moves a VM to another consumer name if a project is
  renamed.

### 3.3 v1: a gate on each Hyper-V host (the v1 decision)

```
consumer session (laptop or claude01)
   vmb / MCP --- ssh vmb-servera <consumer> <verb>, arguments as JSON on stdin (key ~/.ssh/vmbroker_ed25519) --->
servera: sshd -> gate (domain account svc-vmbroker, no groups) -> named pipe -> executor (SYSTEM)
                                                                                 | backend scripts
                                                                                 v
                                                                            broker VMs
the operator: vmb-admin (their terminal, WinRM + Kerberos, TTY) ---> the executor's admin verbs
```

Why the gate on the host, for v1:
- **Enforcement sits where the power is.** The consumer holds a key that only reaches the gate's verbs; the executor
  re-validates every request. The session cannot grant itself more. Same idea as app-broker's `homelab-gate` and its
  sudo-run executor.
- **Works from claude01** (Linux, the machine the operator steers from their phone) exactly as from the laptop, without the
  domain credential ever leaving the laptop.
- **Same consumer pattern as app-broker:** a forced command behind `ssh <alias>`, one key per machine generated on
  that machine, the private key never moves, a served contract, a skill. Sessions already know it.
- **Long jobs run on the host,** independent of the client's connection.
- **No listener code of our own:** sshd is Microsoft's OpenSSH; the gate is a short-lived process per connection.

Costs, all to be tried on a lab host before production: OpenSSH Server, an embeddable Python and a SYSTEM task on
both hosts, and both hosts are domain controllers. To verify: forced commands (`command=` in `authorized_keys`) on
Windows OpenSSH; which logon right a domain account needs for key logons through sshd on a DC. Scope the sshd firewall
rule to the consumer machines.

Hardening, each item checked by `vmb-admin selftest`:
- **Folders.** `<VMRoot>\vmb\` and the code folder are created with inheritance off: SYSTEM and Administrators full
  control, nothing else (Hyper-V adds each VM's own SID to that VM's files itself). The default ACL of `C:\` and of a
  data volume lets ordinary users create files and folders in subfolders, and on a DC every domain user is in
  BUILTIN\Users. Left inherited, a bug in the gate (which parses untrusted input) could plant job files, registry
  records or code that SYSTEM runs: SYSTEM on a DC. `svc-vmbroker` gets read and execute on the code folder (the gate
  runs from it) and nothing under `<VMRoot>\vmb\`. This applies from v0.1 on (section 3.8).
- **sshd.** A forced command alone does not stop `ssh -N -L`, `-D`, agent forwarding or the sftp subsystem: a
  consumer key could use the DC as a TCP pivot to its own loopback services (WinRM, LDAP) and to the LAN. So: every
  key line starts with `restrict,command="..."` (the command carries the key's name); the keys file is owned by
  Administrators (`AuthorizedKeysFile` outside the account's profile), so the gate account cannot add a key; a
  `Match User svc-vmbroker` block sets `AllowTcpForwarding no`, `PermitTunnel no`, `AllowAgentForwarding no`,
  `X11Forwarding no`, `PermitTTY no` and `PasswordAuthentication no`; `AllowUsers` names only `svc-vmbroker`; there
  is no `Subsystem` line.
- **The pipe.** Python's own pipe helpers (`multiprocessing`) take no DACL, and the default DACL of a named pipe gives
  Everyone read and `svc-vmbroker` no write. The executor creates the pipe with `CreateNamedPipeW` through ctypes, with
  an explicit SDDL (SYSTEM and Administrators full, `svc-vmbroker` read and write), `FILE_FLAG_FIRST_PIPE_INSTANCE`
  (no other process can own the name first) and `PIPE_REJECT_REMOTE_CLIENTS` (no access over SMB).
- **Address.** Consumers reach the gate at the host's IP address (192.168.10.9, 192.168.10.7), as app-broker's clients
  reach docker01, not at a `.local` name, which a Linux resolver may send to mDNS. The operator installs each host's verified
  key line in every consumer machine's `known_hosts`: with `BatchMode yes`, an unknown host key fails.
- **Command line.** The gate reads only the consumer name and the verb from the command line (at most 300 bytes,
  `[a-z0-9 @:/._-]`, as in app-broker). Every argument travels as one JSON document on stdin (at most 1 MiB; a copy
  streams the file after it), because commands, Windows paths and director payloads need upper case, backslashes and
  quotes. So consumers use `vmb` for every verb except `contract` and `whoami`.

Rejected for v1:
- **Broker on a Windows admin box with WinRM** (v0.1 as the final shape): the contract would stay advisory, and
  claude01 could use it only with the domain credential copied onto it. It stays as v0.1 and as the operator's admin channel.
- **Bearer-token HTTPS agent:** a token is a string the session holds and sends; it ends up in environment variables
  and transcripts. It also needs TLS and a listener we would write. Kept as the fallback if sshd on the DCs is not
  acceptable, in the fw-arbiter form: HTTPS with client certificates from the Example Root CA.
- **Gate on a Linux VM (docker01, claude01):** it would have to hold Hyper-V admin rights over two DCs, on a VM that
  runs agent sessions or internet-facing apps.
- **JEA endpoint per host:** Windows-native and narrow, but consumers on claude01 would need a domain password or a
  Kerberos keytab, virtual accounts behave differently on DCs (check before relying on them), and the validation would
  live in PowerShell, apart from the Python validator. Possible later as the admin channel.

### 3.4 Who holds what

| who | credential | can do | where it lives |
|---|---|---|---|
| consumer session, v0.1 | none of its own; the broker uses the operator's netadmin credential. The consumer name comes from the project's `vmbroker/consumer` file | what the broker code allows (advisory) | laptop, `%LOCALAPPDATA%\netadmin` (DPAPI) |
| consumer session, v1 | one SSH key per machine; the operator binds it to the consumer names (projects) that machine may act as. Every call names its consumer | the verbs in `CONTRACT.md`, on that consumer's VMs | `~/.ssh/vmbroker_ed25519` on that machine; never moves |
| gate, v1 | domain account `svc-vmbroker`: no groups, logon limited to servera and serverd, "sensitive, cannot be delegated" | write requests to the executor's pipe; read and run the code folder | AD |
| executor, v1 | SYSTEM on the host | Hyper-V, VHD mounts, PowerShell Direct with guest credentials | host |
| Windows Server guest admin | a random password per VM, made at create | PowerShell Direct into that VM | host `secrets\` (section 3.7) |
| `win11-lab` guest admin | the image's own admin account `vmbadmin` (never `student`); the broker changes its image password to a random one per VM at the first contact | PowerShell Direct into that VM | host `secrets\` (the image password is an image secret) |
| Linux guest control, v1 | one SSH key pair per host; the public half goes into each broker Linux VM as user `vmb` | run and copy over a Hyper-V socket | host `secrets\` |
| user passwords | `generate` (random) or `{secret: NAME}` (value set by the operator, v1) | console, RDP, xrdp logons | host `secrets\`; the operator reads them with `vmb-admin`; consumers never |
| director token | random, per VM | call the director | host `secrets\` and that VM's `C:\ProgramData\LabDirector\token.txt` |
| MAK | broker secret `WIN2025_MAK`, set by the operator | activate an approved VM; it reaches the guest only as an argument and is cleared from the guest's registry after activation (section 9) | host `secrets\` |

**Consumers are projects**, in v0.1 and in v1. A consumer name matches `^[a-z][a-z0-9-]{1,39}$`, does not end in a
hyphen, and is normally the project's repository name. `vmb` and the MCP server read it from `vmbroker/consumer` at
the root of the project repo (one line); there is no flag or setting for it, so every tool in a repo acts as the same
consumer. In v1 each machine's key is bound by the operator to the consumer names it may use, every call names one, and the
gate refuses a name the key is not bound to. Projects on one machine share that machine's key, so the separation
between them is a guardrail, not a wall: a session that edits its `vmbroker/consumer` can act as another project bound
to the same key. Between machines (the laptop, claude01) the separation is enforced. Quotas count per consumer.

### 3.5 State on the host

```
<VMRoot>\vmb\                     servera: C:\VMs\vmb\   serverd: D:\VMs\vmb\
  policy.yml                      budget, floor, quotas, caps, copy window, flags, allowed switch (the operator edits it)
  images\<image>\<version>\       disk.vhdx (read-only) + image.json (source, build, date, sha256, expiry)
  vms\<id>\                       one folder per broker VM: disk(s), seed, VM config, the create log
  nets\<net>.json                 isolated nets: owner (a consumer), subnet, switch, router VM, members
  state\vms\<id>.json             the registry: one record per VM (id, Hyper-V VMId, name, owner, request hash, lease)
  state\events.jsonl              one line per request and action (section 12)
  state\pending\<approval>.json   requests waiting for the operator (v1)
  state\lock                      the lock file for check-and-reserve (section 3.2)
  jobs\<job>.json, jobs\<job>.log job state and its log
  secrets\                        guest passwords, director tokens, named secrets (encrypted, section 3.7)
```

`<id>` is 32 hex characters, random. Records are written atomically (write a temp file, then rename). The folder's
ACL: section 3.3 (inheritance off; SYSTEM and Administrators only), from v0.1 on. The broker deletes files only here:
- `vms\<id>\` of a VM being destroyed, after the check in section 6.3;
- `jobs\` (records older than 30 days) and `state\pending\`;
- the secrets of a destroyed VM, and `nets\<net>.json` when its net is removed;
- `images\<image>\<version>\`, only through `vmb-admin image retire`;
- rotated logs (section 12).

### 3.6 Code layout

`src/vm_broker/` holds the broker (each module's docstring says what goes there); the PowerShell backend scripts ship
inside it (`backend/ps/`) because the executor runs them on the host. `src/vm_director/` is the in-guest director,
built separately into one exe. `skill/SKILL.md` is the consumer skill (draft). Development and tests run in a working
copy outside OneDrive (`C:\work\vm-broker`), never in this folder.

### 3.7 Backups and host rebuilds

servera is to be rebuilt (Q7), and nothing of the broker is backed up yet. What a rebuild would lose, and how to keep
it:

| what | why a rebuild loses it | keep it like this |
|---|---|---|
| `vmb\state\`, `policy.yml`, `nets\` | they exist only on the host | copied with the VM exports in netadmin's rebuild runbook; from v1 also nightly to serverd |
| secrets: guest passwords, director tokens, named secrets, the MAK | machine-scope DPAPI cannot be decrypted by a reinstalled OS | encrypted to a "vm-broker secrets" certificate on each host (CMS, `Protect-CmsMessage`); the operator backs up its PFX the way the operator backs up the CA key, and documents name it only (Q24) |
| vTPM VMs (`win11-lab`, any VM with a vTPM) | the host's local guardian certificates open their vTPMs | export both guardian certificates with their keys once the first vTPM VM exists; keep them with the CA backup |
| `keep` VMs | without their registry records they fail the ownership check (section 6.1), so the broker can neither manage nor destroy them | export them with their folders; restore `state\` first, then import with the same VMId |

If the operator prefers machine DPAPI anyway, a rebuild loses the secrets: lease VMs are then destroyed and created again, and
the operator resets each `keep` VM's guest admin password and keys from the console. Rehearse the whole move on a lab host
(export, rebuild, restore `state\` and the certificates, import, start a vTPM VM, read a secret) before the first
`keep` VM exists (v1).

### 3.8 One-time host install steps

The broker never changes host settings at run time (section 6.2). These one-time steps are host changes all the same.
The operator approves each, as the operator did for the lab BMC agent on serverd (`netadmin\tools\lab\lab-ilo\README.md`), and each
has an uninstall.

| step | from | what it changes on the host |
|---|---|---|
| `<VMRoot>\vmb\` and the code folder (in v0.1, the backend scripts that the one-shot SYSTEM tasks run), inheritance off (section 3.3) | v0.1 | folders and their ACLs |
| the "vm-broker secrets" certificate (section 3.7) | v0.1 | a certificate in the machine store |
| the event-log source `vm-broker` (section 12) | v0.1 | a registry key under `Services\EventLog\Application` |
| the local guardian, if the host has none: `Set-VMKeyProtector -NewLocalKeyProtector` creates it with the first vTPM VM | v0.2 | two self-signed certificates in "Shielded VM Local Certificates" (back them up, section 3.7) |
| the Hyper-V socket service GUID for Linux guest control (section 7.3) | v1 | a key under `Virtualization\GuestCommunicationServices` |
| OpenSSH Server and its config, `svc-vmbroker`, the embeddable Python, the executor task (section 3.3) | v1 | a service, a firewall rule scoped to the consumer machines, an AD account, a SYSTEM task |

## 4. Requests and profiles

### 4.1 The request file

One YAML file per VM in the consumer repo, `vmbroker/<name>.yml`, LF line ends, at most 32 KiB, the same strict rules
as app-broker (no anchors, aliases, tags, merge keys or duplicate keys; numbers plain decimal; an unknown key is
rejected). `CONTRACT.md` section 3 is the field reference; the summary:

| field | rule |
|---|---|
| `contract` | `1` |
| `name` | `^[a-z][a-z0-9-]{1,10}$`, no trailing hyphen, not starting with `rtr-`, `img-` or `net-` (reserved for routers, image builds and nets). The Hyper-V name is `vmb-<name>` (15 characters at most, so it is also a valid Windows computer name). Unique across both hosts (section 6.1) |
| `profile` | one of section 4.2 |
| `host` | `auto` (default), `servera`, `serverd`. A VM for an existing isolated net goes to that net's host; another value is rejected |
| `size` | `{cpu, memory, disk}`: cpu from the profile's minimum to 4; memory like `4g` or `512m`, in steps of 256m (Hyper-V needs multiples of 2 MB; a value that passes here must not fail at `New-VM`); disk like `60g`. Within the profile's minimum and maximum |
| `network` | `{mode: lan}` or `{mode: isolated, net: <name>, internet: true/false}` (v0.2; section 7). A net belongs to the consumer that created it |
| `hostname` | optional, only on isolated nets; the default is `vmb-<name>` |
| `access` | list of `ssh`, `rdp`, `winrm`, `xrdp`; allowed set per profile; `winrm` needs the operator (section 4.2) |
| `users` | up to 8: `name`, `admin`, `ssh_keys` (public key lines), `password` (`none`, `generate` or `{secret: NAME}` (v1)) |
| `firewall` | up to 32 inbound rules `{port, proto, from}`; `from` is `lan`, `net` or a CIDR inside the LAN, the VPN ranges or the VM's own net |
| `software` | `features` (Windows roles and features), `winget`, `choco`, `apt`: lists of names, 64 at most per list |
| `scripts` | up to 8 paths in the consumer repo (`.ps1` on Windows, `.sh` on Linux), 64 KiB each, 256 KiB in total; run once, in order, elevated, after software |
| `checkpoints` | `standard` or `production`; the profile sets the default |
| `activation` | Windows Server only: `none` (default) or `mak` (v1, needs approval) |
| `director` | `win11-lab` only: `true` (default) or `false` |
| `lease` | `{days: 1-30}` (default 7) or `{keep: true}` (v1, needs approval). Never past the image's expiry (section 6.7) |
| `autostart` | only with `keep: true`; default `false` |
| `purpose` | up to 200 printable ASCII characters; shown to the operator with any approval |

The request has no consumer field: the consumer is the project (section 3.4).

The client (`vmb` or the MCP server) reads the request and the scripts it names and sends them as one JSON document.
The request hash (SHA-256 of the normalized request plus each script's SHA-256) is what makes `create` idempotent and
what an approval id is computed from.

### 4.2 Profiles

| profile | from | OS and image | GUI | default size (cpu / memory / disk) | min cpu / memory / disk | access allowed (default) | packages | checkpoints | activation |
|---|---|---|---|---|---|---|---|---|---|
| `win2025-core` | v0.1 | Windows Server 2025 Standard, Server Core; sysprepped golden | no | 2 / 4g / 60g | 1 / 2g / 40g | ssh, rdp (v1), winrm (v1, needs the operator) (ssh) | features, winget if the image has it, choco | production | none, mak (v1) |
| `win2025-desktop` | v1 | Windows Server 2025 Standard, Desktop Experience; sysprepped golden | yes | 2 / 6g / 80g | 1 / 4g / 60g | rdp, ssh, winrm (needs the operator) (rdp, ssh) | features, winget, choco | production | none, mak |
| `win11-lab` | v0.2 | Windows 11 Enterprise evaluation, the CS 101 "clean student PC" with the director; not sysprepped | yes | 3 / 6g / 80g | 2 / 4g / 64g | none; console only (RDP breaks the recording, D12) | winget, choco | standard (memory included, so a restore lands on the running desktop) | built-in 90-day evaluation |
| `ubuntu-server` | v0.1 | Ubuntu 24.04 LTS from the cloud image | no | 2 / 2g / 30g | 1 / 1g / 10g | ssh (ssh) | apt | production | n/a |
| `ubuntu-desktop-xrdp` | v1 | Ubuntu 24.04 + Xfce + xrdp, golden built from `ubuntu-server` | yes, RDP | 2 / 4g / 40g | 1 / 2g / 20g | ssh, xrdp (ssh, xrdp) | apt | production | n/a |

Profile rules:
- Maximum per VM: 4 vCPUs (the hosts have 4 cores), 16g memory, 500g disk. The host budget (section 6.4) is usually
  the tighter limit. Minimum cpu per profile as above (`win11-lab`: 2, Windows 11's own minimum); memory in steps of
  256m.
- `win11-lab` defaults to 3 vCPUs and 6g (D17): a 4-vCPU guest rendering in software and encoding video can keep every
  core of the E-2224 busy, and a smaller memory makes each standard checkpoint shorter (section 6.5). Section 15
  (items 7 and 11) settles both; raise them if the measurements allow.
- `win11-lab` runs only on isolated nets: every clone has the same computer name, local password and auto-logon, and
  it is meant to be filmed. It takes no `users`, no `hostname` and no `access`. (A possible interim exception for the
  first recordings: Q16.)
- `xrdp` only on `ubuntu-desktop-xrdp`; `rdp` only on the Windows profiles; every user who logs on over RDP or xrdp
  needs a password (`generate` or a secret). SSH logons use keys only; SSH password logons are off on every profile.
- Agents use `ssh`. On Windows it opens Windows PowerShell (the images set OpenSSH's `DefaultShell`; the default would
  be cmd.exe). `winrm` is for the operator's own tools and needs their approval (v1): WinRM over HTTPS to a workgroup VM needs a
  local password (only the operator can read a generated one), Basic or NTLM from Linux, and a client that accepts the
  self-signed certificate. A certificate from the Example Root CA would be a netadmin change.
- Xfce, not GNOME, for the Linux desktop: xrdp with GNOME is fragile (one session per user, extensions, colord
  prompts), and gnome-remote-desktop's RDP needs a GPU-backed session that a Hyper-V VM does not have (research s. 2).
- Edition: Standard, unless the MAK turns out to be for Datacenter (question Q4).

### 4.3 What `create` does

Common start, on the host under the lock (section 3.2): validate; check ownership, quota and budget; reserve the name
and write the registry record (`creating`; from here it counts toward the budget); create `vms\<id>\`; pick the image
version; start a job. Every later step addresses the VM by its VMId, never by its name (section 6.1).

Every profile, when the VM is created: static memory (v0.R's recording VM on serverd: Dynamic Memory, section 14); `Set-VMProcessor -RelativeWeight 50 -Maximum 75`; a Storage QoS
cap on each disk (section 6.5); automatic start off (unless `autostart`); automatic stop = shut down; the checkpoint
type; the Notes tag; the NIC on the allowed switch, and on `LAN2` with DHCP guard and router guard on and MAC spoofing
off (section 6.3).

Windows Server profiles (sysprepped image):
1. Disk: a differencing child of the golden VHDX (lease) or a full copy (`keep: true`; throttled, in the copy window,
   section 6.5); grow it to the requested size.
2. Mount the disk on the host and write `Windows\Panther\unattend.xml`: computer name, the generated admin password
   (the "hide sensitive data" form `New-WindowsVM.ps1` already writes), time zone, DHCP or a static address on an
   isolated net, RDP on or off. Dismount.
3. Create the VM: Gen2, Secure Boot template `MicrosoftWindows`, the settings above. Start.
4. Wait for PowerShell Direct with `IMAGE_STATE_COMPLETE`, then scrub the cached answer files (both reused from
   `New-WindowsVM.ps1`).
5. In the guest, over PowerShell Direct: extend C:; activation first, if approved (section 9: the key goes in only as
   an argument and is cleared from the registry before any user or script exists); guest firewall (section 7.5); users
   and their keys; sshd; WinRM over HTTPS with a self-signed certificate if approved; features; winget/choco packages;
   the scripts in order.
6. Read the addresses, mark the record `ready`, finish the job.

`win11-lab` (not sysprepped): a differencing child of the golden VHDX, a new VM with a new vTPM,
`Set-VMVideo -ResolutionType Single -HorizontalResolution 1920 -VerticalResolution 1080` while it is off (without
`Single`, 1920x1080 is only a maximum), the settings above, NIC on the lab net, start. The clone boots to the logged-on
`student` desktop with the director running. The broker then connects over PowerShell Direct as the image's admin
account `vmbadmin` (never `student`, section 8.3), checks that the session's token is elevated (setting the address
needs it), changes `vmbadmin`'s password to a random per-VM one, writes the per-VM director token, restarts the
director task, sets the static address on whatever the adapter is now called, and waits for `/health`. Because the
clone is a new VM, Windows sees a new network adapter; the golden image suppresses the network-location prompt so
nothing pops up on camera. If clones still show first-boot noise, try `Import-VM -Copy -GenerateNewId` of an exported
golden VM whose disk is a differencing child (it keeps the NIC and vTPM identity); measure both.

Ubuntu profiles:
1. Disk: a differencing child of the image VHDX (lease) or a full copy (`keep`, as for Windows), grown to the
   requested size; cloud-init's growpart extends the root filesystem at first boot.
2. Build the seed disk the way `New-LinuxVM.ps1` does (a small FAT32 VHDX labelled `CIDATA`): `meta-data`
   (`instance-id` = the record id, `local-hostname`), `user-data` (users, keys, SHA-512 password hashes, packages, ufw,
   xrdp settings, scripts as `write_files` + `runcmd`, and a last step that writes `/etc/cloud/cloud-init.disabled` and
   then reports `done` or `failed` to the host over KVP), `network-config` (DHCP on `lan`, static on an isolated net).
3. Create the VM: Gen2, Secure Boot template `MicrosoftUEFICertificateAuthority`, the settings above. Start.
4. Wait for the KVP status (30 min at most). Then detach and delete the seed disk: it holds the user-data and password
   hashes.
5. Read the addresses, mark `ready`.

Why cloud-init is switched off after the first boot: a Hyper-V VM carries the same chassis asset tag as an Azure VM
(`7783-7084-3265-9085-8269-3286-77`). Once the seed is gone, cloud-init's `ds-identify` likely finds "Azure", NoCloud
cannot confirm its cached instance id without a seed, and cloud-init may treat the next boot as a new instance: Azure
timeouts, then `DataSourceNone`, new SSH host keys (consumers' `known_hosts` break), a default `ubuntu` user, and a
fallback network config (DHCP on the first NIC; a router would lose 10.77.N.1). Likely, not yet verified (section 15
item 2). The images also pin `datasource_list: [NoCloud, None]` (section 8.4).

A failed create leaves the VM in state `failed` for inspection (console, ssh). It counts toward the quota until
`destroy`; `create` on it answers exit 1 "destroy, then create". A failure before the VM exists removes what was made.

## 5. Operations

MCP tool = CLI verb. In v1 both call the gate (`ssh vmb-<host> <consumer> <verb>`, arguments as JSON on stdin,
section 3.3); the gate's verbs are the contract.

### 5.1 Consumer verbs

| MCP tool | CLI | arguments | result | errors (exit) | idempotency |
|---|---|---|---|---|---|
| `broker_contract` | `vmb contract` | | contract version, installed commit, `CONTRACT.md` | 255 | read-only |
| `broker_whoami` | `vmb whoami` | | consumer name, key name (v1), hosts, what this version offers, quotas and current use | 255 | read-only |
| `broker_profiles` | `vmb profiles` | | per host: profiles and the version that brings each, image versions and expiry, size limits | | read-only |
| `broker_capacity` | `vmb capacity` | | per host: budget, used, free, floor | | read-only |
| `vm_plan` | `vmb plan <request.yml>` | request path | normalized request, chosen host, "automatic" or "needs approval: <fields>", findings | 2 | changes nothing |
| `vm_create` | `vmb create <request.yml>` | request path, `wait_s` | job id; when done: VM name, host, state, addresses, access lines, lease end | 1, 2, 3, 4, 5, 6 | same name and same request hash: returns the existing VM (or its running job); if that VM is `failed`: 1, "destroy, then create". Same name, different request: 2 |
| `vm_list` | `vmb list` | | this consumer's VMs: name, host, profile, state, address, lease end | | read-only |
| `vm_status` | `vmb status <vm>` | vm | state, uptime, host, addresses, MAC, access lines, lease end, checkpoint count, running job, director reachable | 2 | read-only |
| `vm_start` | `vmb start <vm>` | vm | state | 3, 6 | running: no-op |
| `vm_stop` | `vmb stop <vm> [--force]` | vm, force | state | 3 | off: no-op. Guest shutdown; `force` turns it off after 120 s |
| `vm_destroy` | `vmb destroy <vm> --confirm <vm>` | vm, confirm | gone | 2 (confirm differs), 3 (a running job; a `lost` job does not block) | already destroyed: 0 "already gone" |
| `vm_extend` | `vmb extend <vm> <days>` | vm, days | new lease end | 5 (beyond the maximum), 2 (past the image's expiry) | the same end date: no-op |
| `vm_snapshot` | `vmb snapshot <vm> <label> [--replace]` | vm, label, replace | label, time, type | 2 (label exists without `--replace`, limit reached), 3 | with `--replace`: takes the new checkpoint, then removes the old one and gives the new one the label, so a failure keeps the old one |
| `vm_restore` | `vmb restore <vm> <label>` | vm, label, `wait_s` | state; for `win11-lab`, waits until the director answers | 2 (unknown label), 3 | repeatable; same end state |
| `vm_list_snapshots` | `vmb snapshots <vm>` | vm | labels, times, parent | | read-only |
| `vm_delete_snapshot` | `vmb snapshot-rm <vm> <label>` | vm, label | ok | 3 | missing label: 0 |
| `vm_run` | `vmb run <vm> [--interactive] [--timeout s] -- <command>` | vm, command (8 KiB max), interactive, `timeout_s` (default 300, max 3600) | stdout and stderr (1 MiB each, cut; an MCP result keeps the first 64 KiB of each and saves the whole output under `VMB_OUT_DIR`), the command's own code in `exit_code` | 0 when the command ran, whatever its own code; 2 (not running), 1 (timeout) | not idempotent; the command decides |
| `vm_copy_to` | `vmb copy-to <vm> <local> <guest> [--overwrite]` | vm, local path, guest path | bytes, SHA-256 | 2 (too large, exists) | the same file with the same hash: no-op |
| `vm_copy_from` | `vmb copy-from <vm> <guest> [<local>]` | vm, guest path, local path (default `VMB_OUT_DIR\<vm>\`) | bytes, SHA-256, local path | 2 (too large, missing) | repeatable |
| `vm_director` | `vmb director <vm> <action> [payload]` | vm, action, payload (JSON) | the director's answer; a screenshot comes back as an image and a file | 2 (no director), 1 (director error, with a screenshot) | `health`, `screenshot`, `wait_for` (at most 600 s per call; loop for longer): repeatable; the others act |
| `vm_console` | `vmb console <vm>` | vm | the line the operator runs (`vmconnect.exe <host> -G <VMId>`, basic session), RDP/xrdp lines if enabled | | read-only; opens nothing |
| `job_status` | `vmb job <id>` | job | state, current step, log tail | | read-only |
| `job_wait` | `vmb wait <id> [--timeout s]` | job, `wait_s` (max 600) | as `job_status` when done | 4 (still running) | read-only |

Notes:
- Availability: v0.1 has every verb above except `vm_director` (v0.2) and `run`, `copy-to` and `copy-from` on Linux
  (v1). `CONTRACT.md` sections 1 and 5 mark each item, and `vmb whoami` lists what the running version offers.
- In v1, `vmb` sends every argument as JSON on stdin (section 3.3); raw `ssh vmb-<host>` is only for `contract` and
  `whoami`.
- `vmb run` exits 0 when the command ran; the command's own exit code is in `exit_code`, so a command's exit 2 to 6
  is never read as a broker answer.
- An MCP tool result is cut at 64 KiB (Claude Code caps a tool result at about 25,000 tokens by default,
  `MAX_MCP_OUTPUT_TOKENS`); the result says so and names the file under `VMB_OUT_DIR` that holds the whole output.
- `vm_run` on Windows runs PowerShell over PowerShell Direct as the VM's admin, in session 0 (invisible).
  `interactive=true` registers and runs a one-shot scheduled task in the logged-on user's session, so the window shows
  (v0). On `win11-lab` prefer `vm_director run_visible`. On Linux, `vm_run` runs bash as `vmb` with sudo, over SSH
  through a Hyper-V socket (v1; section 7.3).
- Size limits: `copy_to` 512 MiB per file in v0.1 (WinRM copy is slow), 2 GiB in v1; `copy_from` 8 GiB.
- The CLI accepts v0's positional shorthand for the main payload field: `vmb director lab-p1 record_start smoke.mkv`.
- Labels: `^[a-z0-9][a-z0-9._-]{0,47}$` (v0's `p1-ch03-start` fits).

### 5.2 Admin verbs (the operator only; `vmb-admin`, needs a TTY; never an MCP tool)

| verb | what it does | from |
|---|---|---|
| `pending`, `approve <id>`, `reject <id>` | requests waiting for approval; `approve` shows the request and asks for the VM name to be typed | v1 |
| `secret set\|list\|rm <scope> <NAME>` | named secrets; `<scope>` is a consumer or `broker`. Values are typed at a no-echo prompt | v1 |
| `password <vm> <user>` | shows a generated password on the operator's terminal | v0.1 |
| `budget <host> <gb>`, `floor <host> <gb>` | host limits (they live in `policy.yml`); a budget above the safe value (section 6.4) asks the operator to type the host name | v0.1 |
| `quota <consumer> <field> <value>` | per-consumer limits | v1 |
| `freeze`, `unfreeze` `[<consumer>\|<host>]` | refuse every changing verb | v0.1 |
| `key add\|rm\|list` | consumer keys and the consumer names each one may act as | v1 |
| `owner <vm> <consumer>` | move a VM to another consumer name (a renamed project) | v1 |
| `image build <profile>`, `image list`, `image retire <image> <version>` | golden images (section 8) | v0.1 |
| `net list`, `net rm <net>` | isolated nets and their routers | v0.2 |
| `evacuate <host>` | shut down every broker VM on a host, for a failover (question Q14) | v1 |
| `reap` | apply lease ends now | v0.1 |
| `job cancel <job>` | stop a job's task and mark the job `failed: cancelled` | v0.1 |
| `destroy <vm> --any-owner` | destroy a broker VM of any consumer | v0.1 |
| `selftest` | the guardrail checks of sections 3.3, 6.3 and 13.5, read-only | v0.1 |

### 5.3 Jobs, waiting and idempotency

- `create`, `restore`, `destroy`, `snapshot` and `stop` are jobs. A tool waits up to `wait_s` (default 120 s; set by
  `VMB_WAIT_S`) and then returns `{job, state: running}` with exit 4. `job_wait` waits again.
- One job per VM at a time, checked under the host lock (section 3.2); a second changing verb on that VM gets exit 3.
- A job record holds its scheduled task's name, the PID and start time of its process, and the step it has reached.
  `job_status` checks that the task still runs (`Get-ScheduledTaskInfo`, and the PID with its start time, so a reused
  PID does not count); a job whose task is gone becomes `failed: lost`, with its step. In v1 the executor marks every
  job of its previous run `lost` when it starts. A host reboot for patching or a killed task therefore cannot block a
  VM for good.
- `destroy` is allowed on a VM whose job is `lost`. The operator stops any job with `vmb-admin job cancel`.
- Every changing verb either completes or leaves a recorded state (`failed` or `lost`, with the step and the log)
  that `destroy` cleans up. `create` on a `failed` VM answers exit 1 "destroy, then create"; it never repairs. No verb
  leaves an unregistered VM, disk or switch behind.
- The director's `wait_for` is not a job: one call waits at most 600 s, and a chapter script loops for longer waits.

### 5.4 Results and errors

Every verb answers one JSON object; the CLI prints it (`--text` for people).

```json
{"ok": true, "exit": 0, "vm": "vmb-api-test", "host": "servera", "state": "Running",
 "addresses": ["192.168.10.143"], "access": {"ssh": "ssh operator@192.168.10.143"},
 "lease_end": "2026-10-22T00:00:00Z", "job": "5f0c...", "minutes": 6.5}

{"ok": false, "exit": 2, "error": "rejected",
 "findings": ["size.memory: 24g is above the profile maximum 16g", "access: xrdp is not allowed on win2025-core"]}
```

No stack traces, no secret values, no host paths outside `vmb\`. Findings name the field and the rule, like app-broker.

### 5.5 Exit codes

| code | meaning | what the consumer does |
|---|---|---|
| 0 | done | report the result |
| 1 | failed; the result says what was left (a `failed` VM, or nothing) | read `job_status`; `destroy` a `failed` VM, fix, then create again |
| 2 | rejected; nothing changed | fix what the findings say |
| 3 | busy: a job is running on this VM | wait, then `vm_status` |
| 4 | not done yet: the job is still running | `job_wait` |
| 5 | waiting for the operator; nothing changed | show them the printed line, then stop |
| 6 | no capacity: the host budget, the host's free memory or disk would be exceeded; nothing changed | pick a smaller size, stop another VM, or ask the operator |
| 255 | the broker could not be reached | `vmb whoami`; tell the operator |

## 6. Guardrails and quotas

### 6.1 Ownership

A VM belongs to the broker only if all of these hold:
1. its Hyper-V name starts with `vmb-`;
2. its Notes start with `vm-broker id=<32 hex>; do not edit`;
3. `state\vms\<id>.json` exists, is not a tombstone, and records the same Hyper-V `VMId` and name.

Every backend script re-checks 1-3 itself before it changes a VM, in v0.1 too. A consumer may act only on VMs whose
record names it as the owner. Router VMs and image build VMs are owned by `broker`, never by a consumer.

Names and ids:
- The backend addresses a VM only by its VMId (`Get-VM -Id`, `Invoke-Command -VMId`, `vmconnect -G`). Hyper-V allows
  two VMs with the same name, so a name that matches more than one VM on a host is refused, whatever the registry says.
- Names are unique across both hosts, so a verb that takes only a name finds one VM. Each host enforces uniqueness
  among its own VMs (in v1 one executor cannot read the other host's registry); `vmb plan` and `vmb create` ask every
  host whether the name is taken, whoever owns it; and `vmb` resolves a name to its host by asking every host in
  `VMB_HOSTS`. A consumer that bypasses `vmb` in v1 can at worst confuse itself.
- The prefixes `rtr-`, `img-` and `net-` are reserved: no request `name` starts with them, so `vmb-rtr-<net>` and
  `vmb-img-<code>` can never be a consumer's VM.

### 6.2 Never touched

Refused by name before any other check, whatever the registry says: `Firewall*`, `servera`, `serverd`, `servere`,
`docker01`, `claude01`, `cloud01`, `ops01`, `Lab*` (the fw-arbiter lab), and any VM with Hyper-V Replica enabled. The
broker never enables Replica, never imports or adopts an existing VM, and never changes host settings at run time
(`Set-VMHost`, enhanced session mode, NUMA spanning, storage paths, the host's own network adapters). Its one-time
install steps (section 3.8) are host changes that the operator approves once.

### 6.3 Paths and switches

- Files: only under `<VMRoot>\vmb\`. Golden images are read-only; `destroy` removes a VM's folder only after checking
  that every disk the VM uses (and every checkpoint file) is inside that folder.
- ISOs: read-only, from `<VMRoot>\iso\`, only during image builds.
- Switches a broker VM may use: `LAN2`, and Private switches named `vmb-net-<net>`. Never `WAN`, `CARP-Sync`,
  `LabLAN`, `LabWAN`, `LabLINK`, or anything else.
- Switches the broker may create or remove: only Private switches named `vmb-net-<net>`, and remove one only when
  nothing is connected to it. Never an External or Internal switch, never `-AllowManagementOS`, never a host adapter
  (section 7.4).
- Every broker vNIC on `LAN2`, routers and image builds included, has `DhcpGuard On`, `RouterGuard On` and
  `MacAddressSpoofing Off` (`Set-VMNetworkAdapter`; per-VM settings, not host settings). Hyper-V leaves both guards off
  by default, so an admin user in a broker VM, or an agent setting up a test service, could otherwise answer DHCP or
  send router advertisements to the whole house. Every backend script re-checks them before it changes a VM, and
  `selftest` checks every broker VM. No vSwitch setting checks the content of ARP, so a forged ARP reply for
  192.168.10.1 stays possible; section 15 tests whether a port ACL can stop it. Private `vmb-net-*` switches keep
  Hyper-V's defaults, so a lab can run its own DHCP server.

### 6.4 Host budget (RAM)

**The operator's answer to Q3 (2026-10-10):** "I'm not worried about the memory situation. Dynamic memory is fine here as long
as firewall is not impacted. Those servers are maxed out already at 32GB." So the broker no longer keeps room for
production's Dynamic Memory maxima (claude01 12 GB and docker01 8 GB on servera): while a broker VM runs, those two may
not get all of it, and the operator accepts that. There is no RAM upgrade (two slots per host, both 16 GB). What protects the
firewall:

- **Firewall3's memory is static** (8 GB, given by Hyper-V when it starts). Nothing a broker VM does can take it back.
- **Its failover room.** The host that holds Firewall3's replica (serverd today) gets no broker VMs (budget 0), so a
  design B failover always finds 8 GB there. The broker starts VMs only on the host where Firewall3 is Running; if it
  is not Running there (a failover moved it), creates and starts on that host are refused, and broker VMs on it are
  shut down before the firewall comes back (`vmb-admin evacuate`, Q14; by hand until v1). The VM name is in
  `policy.yml`; when fw-arbiter's design C goes live (two running copies), the rule becomes "the host with the active
  copy".
- **The CPU and disk caps** (6.5): with RAM settled, these are what could still slow the firewall down.

Broker VMs may use Dynamic Memory. Each profile sets startup, minimum and maximum in `policy.yml`, and every broker VM
gets `Set-VMMemory -Priority 20` (production VMs keep Hyper-V's default, 50), so under pressure Hyper-V takes memory
back from broker VMs first.

```
create/start is allowed when all hold:
  the host's budget is not 0, and Firewall3 is Running on this host (a read-only look at its state)
  host "Available MBytes" - startup memory(new VM) [- 512 MB for a new router]  >=  floor(host)
otherwise: exit 6, nothing changed
```

The check and the reservation (the `creating` record) happen in one host-side script under the lock (section 3.2), in
v0.1 too.

| host | budget | floor | why |
|---|---|---|---|
| servera | what is available above the floor: about 10 GB (13.3 GB free on 2026-10-08) | 3 GB | Firewall3 runs here (static memory); the host is a DC with DNS, DHCP and AD CS |
| serverd | 0 GB | 3 GB | it holds the replicas of Firewall3, docker01 and claude01 and must keep room to start them on a failover; the fw-arbiter lab uses the rest |

The memory watcher (shut broker VMs down, newest first, while "Available MBytes" is below the floor) stays a v1
option; the operator has not asked for it.
### 6.5 CPU and disk

CPU:
- At most 4 vCPUs per VM. Every broker VM gets `Set-VMProcessor -RelativeWeight 50 -Maximum 75`. The weight (production
  VMs keep the default 100) makes the firewall and the other production VMs win under contention; it changes shares
  only. The limit keeps a broker VM below three quarters of its vCPUs' time, so Firewall3's vCPUs and the root
  partition (DC, DNS, DHCP) still find a free core: the E-2224 has 4 cores and no hyper-threading, and a 4-vCPU lab VM
  rendering in software and encoding video could otherwise keep all of them busy. The broker does not change
  production VMs.

Disk I/O: every VM, Firewall3's disk and the DC's AD database share one S100i software RAID 5 on desktop HDDs, and
servera's drive write cache is off: about 18 MB/s write-through (netadmin notes, 2026-10-02). A Windows Update or apt
run in a broker VM, a checkpoint merge, or a host-side copy can saturate it, and Firewall3's and the DC's I/O then
queue behind. So:
- every broker disk gets a Storage QoS cap (`Set-VMHardDiskDrive -MaximumIOPS`, in normalized 8 KB IOPS; this works on
  a standalone host). The value lives in `policy.yml` and comes from the section 15 measurement (item 12);
- host-side copies (full copies for `keep`, image versions, copy staging) are throttled (robocopy `/IPG`, or a low I/O
  priority);
- image builds and `keep` copies run only inside a copy window from `policy.yml` (default 01:00 to 06:00 local); a
  `keep` create waits for it as a job (exit 4);
- lease VMs of every profile, Ubuntu included, are differencing children, so a create copies nothing.

Disk space:
- Refuse a create if the volume holding `<VMRoot>` would drop below 10 % free or 500 GB free. servera's array has
  about 15 TB free, so this is a backstop, not a limit.

Checkpoints:
- At most 40 per VM (Hyper-V allows 50).
- A standard checkpoint of a running VM writes the VM's whole memory to disk (the `.vmrs` file): about 6 minutes for
  6 GB at 18 MB/s, with Firewall3 and the DC queued behind it, and a restore reads it back. Forty standard checkpoints
  of an 8 GB VM would hold about 320 GB of memory files, so the disk quota counts them (section 6.6).
- Long checkpoint chains slow I/O on the RAID 5 too. Take one checkpoint per chapter boundary (D18, section 10.6) and
  delete the ones you no longer need. Section 15 (item 11) times a checkpoint and a restore at 4 and at 8 GB.

### 6.6 Quotas and approvals

Default quotas per consumer, per host (question Q9):

| quota | default |
|---|---|
| VMs (routers not counted) | 3 |
| memory of running VMs | 9g (the host budget is the real limit today) |
| disk | 400g: each VM's disk sizes plus the files its checkpoints hold (`.avhdx` and the memory `.vmrs`); a standard checkpoint counts the VM's memory before it is taken |
| checkpoints per VM | 40 |
| lease without approval | 30 days |
| creates per hour | 6 |
| pending approvals | 3 |

| automatic | needs the operator (exit 5) | only the operator |
|---|---|---|
| any profile and size within the quotas and the budget; `lan`; isolated nets without internet; access `ssh`, `rdp`, `xrdp`, users, keys, firewall rules, software and scripts within the rules; snapshots; run, copy, director; lease up to 30 days; extend up to 30 days from now; destroy own VMs | `internet: true` on an isolated net, until the operator records in `policy.yml` that netadmin's firewall rule for router VMs is in place (section 7.3, Q23); `access: winrm`; `activation: mak` (each one uses up a MAK activation for good); `lease: {keep: true}` and `autostart`; anything above a quota; a `{secret: NAME}` whose value the operator has not set yet | budgets, floors, quotas, keys, secret values, passwords, images, freeze, evacuate, destroying another consumer's VM |

The approval id is 32 hex characters, a hash of the consumer, the request hash and the fields that need approval (as
in app-broker). If the request changes, the id changes.

Approvals arrive with v1. Before that, a request that would need one is rejected (exit 2, "not in v0.1" or "not in
v0.2"), and so is anything else the running version lacks: v0.1 rejects `activation: mak`, `keep`,
`{secret: NAME}`, isolated nets, `rdp`, `xrdp`, `winrm`, and `run` and `copy` on Linux; v0.2 accepts isolated nets,
and `internet: true` only once netadmin's rule is recorded. `vmb profiles` and `vmb whoami` say what the running
version offers.

### 6.7 Leases

- Every VM has a lease end: `lease.days` (default 7, at most 30 without approval) from creation, or none with `keep`.
- At the lease end the executor shuts the VM down and marks it `expired`. Seven days later it destroys it, unless it
  was extended. `vmb list` and `vm_status` show both dates.
- A create or an extend whose lease end is later than the image's expiry (`win11-lab`: the end of the evaluation) is
  refused (exit 2): past it the evaluation shuts the VM down every hour.
- v0.1 has no background task: `vmb list` shows expired VMs and the operator runs `vmb-admin reap` (part of v0.1's
  `vmb-admin`). From v1 the executor checks every hour.

## 7. Networking

### 7.1 Modes

| mode | switch | addresses | can reach | reachable from |
|---|---|---|---|---|
| `lan` | `LAN2` (External) | Windows DHCP (servera and servere failover), 192.168.10.0/24 | LAN, VPN clients, the internet through Firewall3, like any LAN client | LAN and VPN clients, through the guest firewall |
| `isolated`, `internet: false` | `vmb-net-<net>` (Private) | static, set by the broker: 10.77.N.10 and up | other VMs on the same net only | nothing; humans use the console |
| `isolated`, `internet: true` | `vmb-net-<net>` + router VM | static, gateway and DNS 10.77.N.1 | the same net, and public addresses through the router's NAT and Firewall3; never a private address, and, once netadmin's rule is in place, never Firewall3 itself (section 7.3) | nothing; humans use the console |

### 7.2 `lan`

- Addresses come from the Windows DHCP scope. The broker reports the address (Hyper-V KVP) and the MAC.
- Whether the name `vmb-<name>` resolves depends on the DHCP server registering names for non-domain clients
  (question Q10). Until then, use the address.
- A static address or a DHCP reservation is a netadmin change: give netadmin the MAC.
- Every broker vNIC on `LAN2` has DHCP guard and router guard on and MAC spoofing off (section 6.3).
- A VM on `lan` is as trusted as any LAN client. No broker VM runs untrusted code, on any network (section 11); an
  isolated net is not a sandbox.

### 7.3 Isolated nets and the router VM

- One Private switch per net, `vmb-net-<net>`, with `<net>` matching `^[a-z][a-z0-9]{1,6}$`. Created with the first VM
  that names it, removed with the last.
- A net belongs to the consumer whose VM created it: `nets\<net>.json` records the owner and the host. A VM of another
  consumer that names the net is refused (exit 2). Net names are unique across both hosts, and a net lives on one host
  only: a VM for an existing net is placed on that net's host, and a `host:` value that disagrees is refused. Two
  unconnected nets with one name cannot happen.
- Subnet: 10.77.N.0/24, N from 1 to 200, picked by the broker (question Q11 confirms the range is unused; it avoids
  the VPN ranges 10.18.0.0/24 and 10.20.100.0/24, the fw-arbiter lab's 10.80.0.0/24, HostLink 10.250.250.0/24, and
  10.19.0.0/24).
- With `internet: true` the broker also runs `vmb-rtr-<net>`, a clone of the `router` image (built from
  `ubuntu-server`, section 8.1), 1 vCPU, 512 MB. NIC 1 on `LAN2` gets one of the router addresses netadmin reserves (a
  DHCP reservation for a static MAC the broker assigns, Q23; until those exist, an ordinary lease); NIC 2 on the
  Private switch is 10.77.N.1. Configured entirely by cloud-init:
  - nftables, one `inet` table: masquerade out of NIC 1; forward from NIC 2 only to public IPv4 addresses, so never to
    10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 0.0.0.0/8, 224.0.0.0/4 (multicast) or
    240.0.0.0/4; nothing forwarded inward; the forward policy is drop; no IPv6 on NIC 2 and no IPv6 forwarding;
  - input: on NIC 1 only replies; on NIC 2 only DNS (port 53) and ICMP echo to 10.77.N.1;
  - IPv4 forwarding is turned on by the nftables unit after its ruleset has loaded (an `ExecStartPost`), never by
    `sysctl.d`, which runs earlier: no unfiltered window at boot;
  - dnsmasq answers DNS on NIC 2 only (no DHCP: addresses on isolated nets are static), forwarding to public resolvers
    (1.1.1.1, 9.9.9.9), never to the AD DNS servers;
  - no TCP sshd at all (`ssh.socket` and `ssh.service` off); the broker manages the router over the Hyper-V socket.
- **The house's own WAN address is public too.** A lab packet to it goes through the router's NAT to Firewall3 and
  reaches Firewall3 itself (its web GUI and other services listen on every interface by default, and the LAN rules
  allow LAN to any), or, with NAT reflection, the WAN 443 forward to docker01:8443. The router cannot block it: the
  address is dynamic. Netadmin closes it with an OPNsense rule (Q23): the reserved router addresses in an alias,
  blocked to "This Firewall" and to the LAN net. Until the operator records in `policy.yml` that the rule is in place,
  `internet: true` needs their approval (v1) or is refused (v0.1, v0.2). Acceptance C checks it (section 13.5).
- Humans reach VMs on isolated nets through VMConnect (`vm_console`). Port forwards from the router's LAN address to a
  lab VM (for RDP into a lab) are a v2 option.
- Lab traffic leaves through Firewall3 like any LAN client's, so it is subject to the home firewall's policy and comes
  from the home IP. An isolated net is not a sandbox: no untrusted code runs on any broker VM (section 11); the v2
  `sandbox` profile is the place for it.
- Later, a lab VLAN on OPNsense (netadmin) could replace the router VMs.

The broker reaches guests on isolated nets without any network path: PowerShell Direct for Windows, SSH over a Hyper-V
socket for Linux (v1). In the guest, with the `hv_sock` module loaded, a systemd socket unit listens on AF_VSOCK and
hands connections to sshd; on the host a small helper connects with AF_HYPERV to the VM's id and the service GUID
`<port in hex>-facb-11e6-bd58-64006a7986d3` and serves as ssh's `ProxyCommand`. lab-ilo on serverd uses the same
socket family and GUID scheme in the other direction (the guest calls the host's agent), so the helper is new code;
it can reuse lab-ilo's AF_HYPERV endpoint class. Registering the service GUID on each host is a one-time install step
(section 3.8).

### 7.4 The DNS-registration trap

Both hosts are DCs. Any adapter the host gets on a new network registers its address in AD DNS (servera's HostLink
10.250.250.9 was published as a DC record). So vm-broker never gives a host an address on any network it creates: no
Internal switches, no NetNat, no `-AllowManagementOS`, no `Add-VMNetworkAdapter -ManagementOS`. `vmb-admin selftest`
checks that no host adapter is connected to a `vmb-*` switch and that every `vmb-*` switch is Private. If a future
design needs a host adapter, it is a netadmin change, with DNS registration turned off on that adapter first.

### 7.5 Guest firewall

The guest firewall belongs to vm-broker and is set at create.

- Default inbound: deny, on every profile (Windows Firewall: all three network profiles; Linux: ufw default deny).
- Each `access` item opens its port from `lan`: ssh 22, rdp 3389, winrm 5986 (HTTPS only), xrdp 3389.
- `from` values: `lan` = 192.168.10.0/24 plus the VPN client ranges 10.18.0.0/24 and 10.20.100.0/24 (app-broker's
  `lan-vpn` set); `net` = the VM's isolated net; or one CIDR inside those ranges. Nothing wider.
- Windows rules live in the rule group `vm-broker`; the broker replaces that group as a whole and leaves rules made
  inside the guest alone. Linux: ufw rules with the comment `vm-broker`.
- Outbound: allowed. Restricting it is what isolated nets are for.

### 7.6 Exposure beyond the LAN

Not part of the contract. A VM on `lan` is already reachable from VPN clients. A consumer that needs internet
exposure:
- for an HTTP(S) app: host it with app-broker (container) instead, or ask the operator; a Traefik route to a VM would be an
  app-broker change;
- for anything else (a port forward on OPNsense): ask the operator; it is a netadmin change.

The request has no field for either.

## 8. Images and the build pipeline

### 8.1 Catalogue

| image | source | how it is built | generalized | clone | refresh |
|---|---|---|---|---|---|
| `win2025-core` | the Server 2025 ISO on serverd (`en-us_windows_server_2025_updated_sep_2026_x64_dvd_f69d8ae5.iso`), Standard Core | `New-WindowsVM.ps1`'s apply path (WIM straight onto a VHDX, unattend, no Setup UI), then updates, then sysprep | `sysprep /generalize /oobe /shutdown /mode:vm` | differencing (lease), copy (`keep`) | monthly, after Patch Tuesday |
| `win2025-desktop` | same ISO, Standard with Desktop Experience | same | same | same | monthly |
| `win11-lab` | Windows 11 Enterprise evaluation ISO (the operator downloads it from the Evaluation Center) | the same apply path adapted for a client, then the v0 golden steps (section 8.3) | no | differencing | once per term (the evaluation lasts 90 days from the build) |
| `ubuntu-server` | `ubuntu-24.04-server-cloudimg-amd64.img` (the generic QCOW2, release stream) with `SHA256SUMS` and its GPG signature | downloaded, checked and converted on claude01, carried to the host by the laptop (section 8.4), then one boot with a build seed | `cloud-init clean --logs --machine-id --seed` | differencing (lease), copy (`keep`) | monthly |
| `ubuntu-desktop-xrdp` | `ubuntu-server` | one boot with a build seed that adds the desktop | same | differencing (lease), copy (`keep`) | monthly |
| `router` | `ubuntu-server` | one boot with a build seed that adds nftables and dnsmasq | same | differencing | monthly |

The Azure VHD build of Ubuntu is the wrong artifact: it expects Azure and its cloud-init looks only for the Azure
datasource (research s. 1). The minimal cloud image is not used either: it is built for KVM (its `.manifest` lists the
`linux-kvm` kernel flavour), which lacks Hyper-V's vmbus, storvsc and netvsc drivers, KVP and `hv_sock`.

Image builds run on `lan`, inside the copy window (section 6.5): the build VM is the operator's, short-lived, its inbound is
denied, and it runs only Microsoft's or Ubuntu's code plus the director. Build VMs are named `vmb-img-<code>` with a
short code (`w25c`, `w25d`, `w11l`, `ubs`, `ubx`, `rtr`), because `New-WindowsVM.ps1` uses the VM name as the
computer name and allows 15 characters (`vmb-img-win2025-core` would be 20).

### 8.2 Windows Server images

1. Copy the 2025 ISO to servera's `C:\VMs\iso\` (netadmin step; servera has only the Ubuntu ISO today).
2. Build a VM `vmb-img-w25c` (or `vmb-img-w25d`) with `New-WindowsVM.ps1`'s apply logic, on `lan`.
3. Install all updates; install nothing else except: the OpenSSH server present but stopped (Server 2025 ships it),
   with `DefaultShell` set to Windows PowerShell (`HKLM:\SOFTWARE\OpenSSH`; the default is cmd.exe), winget if it is
   not present and can be added, the `vm-broker` firewall rule group empty. No product key.
4. `sysprep /generalize /oobe /shutdown /mode:vm`; `/mode:vm` skips device detection on clones that run on the same
   hypervisor.
5. Copy the VHDX to `images\<image>\<yyyy-mm-dd>\disk.vhdx`, mark it read-only, write `image.json` (ISO name and
   SHA-256, build number, update level, date), delete the build VM.

### 8.3 `win11-lab` image (the v0 "clean student PC")

**The base OS is a choice (the operator, 2026-10-08):** Windows 11 Enterprise evaluation, or Windows Server 2025 Desktop
Experience ("I don't see any reason server 2025 wouldn't work"). Server 2025 runs everything the labs install (winget,
Windows Terminal, VS Code, Git, Python, Copilot) and is licensed better here: 180 days of evaluation, or AVMA once
servera runs 2025 Datacenter, against Windows 11's 90 days. Its differences on camera: Server Manager opens at logon
(turned off in the image), "Windows Server" branding, no Store by default. The image build takes the base as a
parameter (`lab_os: win11 | win2025`); everything else in this section applies to both. Default: `win2025` unless the
course wants viewers to see exactly what students run on their own Windows 11 machines.

**v0.R (the operator, 2026-10-10):** the recording slice builds this as one VM with `lab_os: win2025`, activated once with
the operator's MAK, not as an image with clones (section 14). The expiry bullet below applies to evaluation media only.

Kept from v0 section 4: English (US); local admin `student` with auto-logon; 1920x1080 at 100 % scaling; light theme;
default taskbar; clean desktop; no dev tools (no Python, Git, Node, VS Code); integration services on; the director,
a static ffmpeg build and a scheduled task that starts the director at logon, all under the hidden
`C:\ProgramData\LabDirector\`: program files in `bin\`, the token in `token.txt`, recordings in `out\`.

Changed or added:
- **A broker admin account, `vmbadmin`:** a second local administrator, used only for PowerShell Direct. Its image
  password is an image secret, and the broker changes it to a random per-VM password at the first contact (section
  4.3). Never `student`: every clone shares its password, and auto-logon keeps it in plain text in the Winlogon
  `DefaultPassword` value.
- **First-run prompts by policy, not by clicking:** Edge `HideFirstRunExperience`, OneDrive `DisableFileSyncNGSC`,
  consumer features and "finish setting up" screens off, privacy express settings off (`ProtectYourPC` = 3). Teams:
  test against the ISO actually downloaded (research s. 3).
- **Updates held by policy** (D13): Windows Update set to notify only, no automatic restart with a user logged on.
  Updates are installed while building the image, then held.
- **Never locks:** no lock screen, inactivity limit 0, monitor and standby timeouts 0, no screen saver.
- **Auto-logon that lasts:** set the Winlogon values in a first-logon command; the unattend `AutoLogon` element counts
  logons down (research s. 3).
- **No new-network prompt** on clones (they get a new adapter).
- **UAC:** see question Q15. The director runs at the student's normal integrity, so what it opens looks like what a
  student sees. It cannot type into elevated windows or the UAC prompt (the secure desktop).
- **Defender: no exclusion** (changed 2026-10-10). The exclusion for `bin\` was meant for an unsigned PyInstaller exe;
  the director now runs on the PSF-signed embeddable Python (D19), and Defender in the recording VM, with current
  definitions and no exclusion, scanned and ran it and ffmpeg without a finding. An exclusion followed by a hidden
  program at logon is also what antivirus models look for: the laptop's Defender quarantined a session log that
  contained that pattern. `LabDirector\` still gets an explicit ACL with inheritance off: SYSTEM and Administrators
  full, `student` read on `token.txt`, Users read on `bin\`, `student` modify on `out\` (ProgramData's inherited ACL
  would let any standard user drop files into `bin\`, which the logon task runs).
- **vTPM and Secure Boot** (`MicrosoftWindows`) for Windows 11's requirements. **No BitLocker, enforced:** before the
  first boot the build sets `PreventDeviceEncryption` = 1 under `Control\BitLocker` in the applied image's offline
  SYSTEM hive (`ControlSet001`, which becomes `CurrentControlSet` at boot). Windows 11 24H2 and later turn on automatic
  device encryption on far more hardware, a Gen2 VM with a vTPM likely included. A Microsoft-account sign-in during the
  build would then bind the key to the build VM's vTPM and back it up to that account, and every clone, which has a new
  vTPM, would stop at the recovery screen; with a local account alone the disk would still be encrypted, with a clear
  key, at a CPU and I/O cost. The build checks that `manage-bde -status` shows "Fully Decrypted" before the image is
  frozen. No Windows Hello PIN either, so a clone with a new vTPM boots cleanly.
- **Expiry:** `image.json` records the evaluation end date (build date + 90 days). The broker refuses a create or an
  extend whose lease would end after it (section 6.7). After expiry the evaluation shuts down every hour.
- **Microsoft account risk:** the Evaluation Center page for the current Enterprise evaluation says a Microsoft account
  is required. Test whether the unattend local account still works with the apply path; fallbacks are the
  `BypassNRO` value in the specialize pass, or the LTSC 2024 evaluation (which lacks the Store, so winget would have to
  be added).

How the image is built (`vmb-img-w11l`): apply the WIM; set `PreventDeviceEncryption` offline; boot on `lan` (section
8.1); install updates; apply the policies; create `vmbadmin`; stage the director, ffmpeg and the task with their ACLs;
reboot to check that auto-logon and the director come up; check `manage-bde -status`; shut down cleanly; copy the VHDX
to `images\win11-lab\<date>\`. The human steps (checking the desktop looks right) are the operator's.

### 8.4 Ubuntu images

- On claude01: download the release image, `SHA256SUMS` and `SHA256SUMS.gpg` (the operator approves the download); verify
  with the Ubuntu cloud-image keyring; `qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic` (Ubuntu's own
  `qemu-utils`, not a third-party Windows build).
- From the laptop: copy the VHDX from claude01 to `C:\work\vm-broker\images\` (scp), then push it to the host over
  WinRM (`Copy-Item -ToSession`, in the copy window). claude01 never holds the domain credential, and v0.1 has no sshd
  on the hosts. Check that Hyper-V mounts the result and that its SHA-256 matches on both ends.
- Build seed for `ubuntu-server`: `linux-cloud-tools` for the image's kernel flavour (the KVP daemon reports addresses
  to the host; the VSS daemon makes production checkpoints consistent), `hv_sock` loaded at boot, the vsock SSH unit,
  the KVP status helper, `ufw`, unattended-upgrades for security updates, and
  `/etc/cloud/cloud.cfg.d/90-vmb.cfg` with `datasource_list: [NoCloud, None]` (section 4.3). Then `cloud-init clean`.
- `router`: plus `nftables` and `dnsmasq`, both left for the clone's seed to configure; `ssh.socket` and `ssh.service`
  disabled (the vsock SSH unit stays).
- `ubuntu-desktop-xrdp`: plus `xfce4`, `xfce4-session`, `xrdp` with `xorgxrdp` (install recommends), the `xrdp` user in
  `ssl-cert`, `startwm.sh` starting Xfce, no `colord` (or a polkit rule for it), a self-signed TLS certificate for
  xrdp made at first boot (not baked into the image).
- First check on a patched Server 2022 host: that the current 24.04 shim boots with the `MicrosoftUEFICertificateAuthority`
  template (the 2023 UEFI CA changes; research s. 1).

### 8.5 Versions, refresh and retirement

- An image version is never changed after it is written. A new build is a new version folder; new clones use the
  newest version.
- `image retire` refuses while a VM still depends on that version (differencing children: lease VMs of every profile,
  and routers). Long-lived VMs are full copies, so they never pin an image.
- Images exist per host. v0.1 builds them on servera only.

### 8.6 Clone speed

| step | before (netadmin tools) | with images |
|---|---|---|
| Windows Server | WIM apply + setup, about 45 min to a logon on serverd's RAID 5 | differencing disk in seconds; first boot runs specialize and OOBE only (`/mode:vm`). Measure |
| Ubuntu | autoinstall from the ISO, 20-60 min | differencing disk in seconds (a `keep` VM copies about 3 GB); first boot is cloud-init only. Measure |
| `win11-lab` | n/a | differencing disk in seconds; boots to the desktop |

## 9. Activation

| VM | policy |
|---|---|
| short-lease Windows Server (up to 30 days) | no activation. Volume media without a key, or the 180-day evaluation media if the operator prefers it (question Q6). Never a MAK. Check `slmgr /dlv` on the first VMs to see what an unactivated install does |
| long-lived Windows Server (`keep: true`, v1) | MAK with the operator's approval, one activation per VM. The executor installs the key over PowerShell Direct from the broker secret `WIN2025_MAK`, as an `-ArgumentList` value only (never in a script block's text, which the guest's script block logging, event 4104, would record), and activates online. Then it runs `slmgr /cpky` and checks that the registry no longer holds the key: Windows otherwise keeps it in a form any admin of the VM can decode with a key-finder tool, and these VMs have admin users. All of this happens before any user, key or script is set up. The key is never written to an answer file or a log. `events.jsonl` counts the activations used. Such a VM is never destroyed and created again to apply a change: each new one uses up another activation, so the consumer asks the operator |
| `win11-lab` | the evaluation's own activation (online, through the router). Rebuilt each term |
| a lab or recording VM on Server 2025 Desktop Experience (the operator, 2026-10-08: "I don't see any reason server 2025 wouldn't work"; see 8.3) | never unactivated: an unactivated install shows the "Activate Windows" watermark and locks personalization, which spoils a recording. **The recording VM of the slice (v0.R, the operator 2026-10-10): one MAK activation.** It is one VM, kept: chapters restore its checkpoints, and it is never destroyed and created again (each new VM would use another activation); across servera's rebuild it is exported and imported with its VM ID. Other lab VMs: the 180-day evaluation media until servera runs Server 2025 Datacenter, then AVMA on servera (no count, no expiry) |
| after servera is rebuilt on Server 2025 Datacenter | AVMA for Server 2025 guests on servera: no MAK used, no count. Requires Datacenter on the host and the host's version at least the guest's. HPE does not support servera's S100i software RAID on Server 2025 without an E208i-p controller (netadmin notes), so this depends on that card (Q7) |

Facts behind this:
- MAK activations are finite and are not given back when a VM is destroyed; a rebuild uses another one.
- Before the first real MAK use, the handling is proved on a test VM with the public Server 2025 Standard GVLK (section
  15 item 15): the key never shows in event 4104, and after `slmgr /cpky` the registry no longer yields it.
- AVMA needs an activated Datacenter host. servera is 2022 Standard; serverd is 2022 Datacenter and can activate
  Server 2022 and older guests today, but not 2025.
- KMS is another route for many VMs: a patched Server 2022 KMS host can activate Server 2025 clients. It needs a KMS
  host key from the operator's licensing and at least five server clients in 30 days before it activates anything
  (question Q5).
- Licensing (how many Windows Server VMs a Standard host may run) is the operator's call. If the operator wants, the policy can cap
  Windows Server VMs per host.
- The operator's keys come from their Visual Studio subscription (2026-10-08): the Server 2025 MAK, and the operator can get a Windows 11
  key there too. Those keys have a fixed activation count as well; the dev/test purpose does not make them unlimited.
  The remaining count shows in Microsoft's Volume Activation Management Tool (VAMT); my.visualstudio.com (Product
  Keys) shows each key's type, and a key listed as "Static Activation Key" needs no online activation at all. The same
  portal usually offers Windows Server Datacenter keys, which is what servera's rebuild needs for AVMA (Q7).
- servera moves to Server 2025 soon (the operator, 2026-10-08), serverd perhaps later (it needs its own controller first:
  the same S100i). That makes AVMA on servera the default answer for Server 2025 lab VMs, if the host key is
  Datacenter.

### 9.1 Mixed host versions

While one host runs Server 2025 and the other 2022, a VM created on the 2025 host gets a configuration version the
2022 host cannot run (2022's highest is 10.0). The broker creates every VM with `New-VM -Version 10.0` while any host
runs 2022, so that any VM can be exported, moved or rebuilt on either host; `image.json` and `selftest` check it. The
same rule binds netadmin for production VMs that replicate or fail over between the hosts (the rebuild plan,
netadmin `docs/runbooks/06b-servera-rebuild-automation.md`). Once both hosts run 2025 the rule is lifted.

## 10. CS 101 director module

### 10.1 Scope

The director is optional and exists only on `win11-lab`. It drives the logged-on desktop and records it, so a chapter
script in `cs101-walkthroughs` can produce a walkthrough without anyone at the keyboard. vm-broker provides the
director, the image and the `vm_director` relay. The chapter scripts, the orchestrator that runs them, and the video
assembler belong to the consumer.

### 10.2 Transport (D6)

```
vm_director(vm, action, payload)
  -> broker (laptop in v0.1, executor in v1)
  -> PowerShell Direct session into the VM (as vmbadmin, section 8.3; kept open while a chapter runs)
  -> Invoke-RestMethod http://127.0.0.1:47800/<endpoint>  (Authorization: Bearer <per-VM token>)
  -> director.exe in the student's session
```

- The director binds 127.0.0.1 only. No firewall rule, no network listener.
- The token is per VM (D14), readable by `student` and the admins, and kept by the broker in `secrets\`.
- A restore drops the PowerShell Direct session; the broker reconnects and waits for `/health`.
- Latency per call is a second or two in v0.1. It does not show in the video: `/type` types a whole string inside the
  guest with human cadence.
- Later option: a Hyper-V socket listener in the director (Python 3.12 has `AF_HYPERV`), if PowerShell Direct proves
  too slow.

### 10.3 API

All POST, JSON, `Authorization: Bearer <token>`.

| endpoint | payload | behaviour | release |
|---|---|---|---|
| `/health` | | version, session, resolution and scaling, recording state | v1 (new) |
| `/type` | text, cps=14, jitter=0.35, enter=false | human cadence as v0; Unicode text through `SendInput` Unicode events | v1 |
| `/key` | combo, repeat=1 | key chords | v1 |
| `/click` | x, y, button=left, double=false, move_ms=400 | eased cursor path, then click | v1 |
| `/wait_for` | window_title (regex), timeout_s (at most 600) | blocks until a top-level window with that title exists (or is gone, with `gone: true`) | v1 |
| `/screenshot` | | PNG of the desktop | v1 |
| `/record/start` | filename, fps=30, crf=20, preset=ultrafast | ffmpeg gdigrab of the desktop, cursor included; refuses unless 1920x1080 at 100 % and enough free disk | v1 |
| `/record/stop` | | `q` to ffmpeg, waits for the file; path, duration, size | v1 |
| `/marker` | label | appends `(t, label)` to `<file>.markers.json`, t measured from ffmpeg's first frame | v1 |
| `/run_visible` | command | opens Windows Terminal if needed (then waits for its shell to sit idle), types the command with `/type`, presses Enter | v1 |
| `/find`, `/click` by image, `/wait_for` image | image, timeout_s | template match (or UI Automation by element name, which survives theme and DPI changes better) | v2 |

The director never holds credentials. It runs in the student's session at normal integrity (question Q15).

### 10.4 Recording

- ffmpeg `gdigrab` inside the logged-on session (it needs no GPU; Desktop Duplication may not work on the Hyper-V video
  adapter).
- Defaults (D9): 30 fps, CRF 20, `ultrafast`, `yuv420p`, `.mkv` under `C:\ProgramData\LabDirector\out\` (outside the
  bin\ folder, section 8.3). The laptop re-encodes for publishing. Measure the vCPU cost and dropped frames
  first; keep `veryfast` if the host can afford it.
- The recording leaves the guest with `vm_copy_from` to `VMB_OUT_DIR` (outside OneDrive, D8).
- First test (section 15): does the desktop keep rendering, and gdigrab keep getting new frames, with no VMConnect
  window open?

### 10.5 Human steps

Sign-ins (GitHub with the device-code flow, Microsoft, Copilot) and the one drag-and-drop chapter stay human, as in v0:
1. the chapter script reaches the step and calls `vm_console`, which returns `vmconnect.exe servera -G <VMId>`;
2. the orchestrator tells the operator (basic session; do not switch to enhanced session);
3. the script calls `vm_director wait_for` with `timeout_s` 600, and again until the window shows up (one call waits
   at most 600 s; it is not a job, section 5.3);
4. The operator finishes in VMConnect; the script resumes. Markers (`human-start`, `human-end`) let the assembler cut.

The operator's steps outside the VM: download the Windows 11 Enterprise evaluation ISO (the Evaluation Center asks for a
form) and put it in servera's `C:\VMs\iso\`; check the golden desktop before it is frozen. (v0.R needs no Windows 11 ISO.)

While the operator travels (October 2026), a device-code sign-in needs no VMConnect: the chapter script reads the code from
the guest (`vm_run` output or `/screenshot`), the orchestrator gives it to the operator in chat, and the operator enters it on their
phone at the provider's device page. VMConnect over the VPN only for steps that need the desktop itself.

### 10.6 Chapters and checkpoints (D18)

v0 takes two checkpoints per chapter (`p1-ch03-start`, `p1-ch03-end`). A standard checkpoint of a running 6-8 GB VM
writes that much memory to servera's array, minutes each (section 6.5). So a chapter script takes one checkpoint per
chapter boundary: the end of chapter N is the start of chapter N+1, and a failed chapter is re-run from it as in v0.
Delete the checkpoints a finished recording no longer needs; they count toward the disk quota.

## 11. Security

- **Tier 0.** Both hosts are DCs; anything that runs with admin rights on them can reach AD. The executor is small,
  reviewed, has no network listener of its own, and never calls AD. The gate account has no rights. The host changes
  the broker needs are one-time install steps (section 3.8); the hardening (folder ACLs from v0.1, the sshd options and
  the pipe's DACL in v1) is in section 3.3, and `selftest` checks each item.
- **No new standing credential in v0.1:** the broker uses netadmin's existing credential the way netadmin does,
  through its DPAPI cache only: the loader gets a `-ConfigPath` that does not exist, so a missing cache never turns
  into a read of netadmin's `config.txt` (section 3.2). In v1 the domain credential is not used by consumers at all.
- **Consumers hold keys, not passwords.** One key per machine, bound by the operator to the consumer names (projects) that
  machine may act as; private keys never move. Between projects on one machine the separation is a guardrail
  (section 3.4).
- **Validation twice** in v1: the gate and the executor run the same validator. The gate's command line carries only
  the consumer and the verb (`[a-z0-9 @:/._-]`, 300 bytes, as in app-broker); arguments arrive as JSON on stdin.
- **Consumer strings never become code on a host.** Commands for `vm_run`, director payloads, guest paths, labels and
  every other string from a request reach PowerShell on a DC (as `svc-vmb` in v0.1, as SYSTEM in v1). They travel only
  as JSON values or `-ArgumentList` values and run only inside the guest. No `Invoke-Expression`, no
  `[scriptblock]::Create`, no `Invoke-Command` script text built from them on the host. Pester tests put quotes,
  `$()`, backticks, `;` and newlines into every field (section 13.2).
- **No secrets in requests:** the validator refuses a request or script that contains a private-key block, a
  five-by-five product-key pattern, or a known token format. A false positive is fixed by moving the value out, not
  by weakening the check.
- **Generated secrets stay on the host:** guest admin passwords, user passwords, director tokens and the MAK, under
  `secrets\` (ACL SYSTEM + Administrators, encrypted to the host's vm-broker certificate, section 3.7). Unattend files
  are scrubbed after setup (reused from `New-WindowsVM.ps1`); Linux seed disks are deleted after first boot and carry
  password hashes, not passwords; the MAK is cleared from the guest's registry after activation (section 9).
- **Guest isolation:** `lan` VMs are ordinary LAN clients, with DHCP guard, router guard and no MAC spoofing on their
  vNICs (section 6.3). Isolated nets have no host adapter; their router forwards only to public addresses, and once
  netadmin's rule is in place Firewall3 blocks the routers from the firewall itself and from the LAN (section 7.3).
- **No untrusted code on any broker VM:** no malware samples, no exploit code, no binaries or packages from sources
  you would not install on a laptop on the LAN. Two reasons. An isolated net with internet is not a sandbox (section
  7.3). And until v1 the guardrails are advisory, while `vm_run` output, director answers and screenshots flow into
  sessions that run as the operator on the laptop, next to the host credential: a hostile guest is a prompt-injection path to
  the hosts. The v2 `sandbox` profile (the v1 gate, netadmin's rule, no copy-from) is the place for such code.
- **Copy-from:** files from a VM pass through the host as bytes; the host never opens or runs them. The v2 `sandbox`
  profile will refuse `copy_from` and keep the Guest Service Interface off.
- **What VMs print is data.** Output of `vm_run`, director answers, screenshots and logs come from the guest; a
  consumer session treats them as data, never as instructions (`CONTRACT.md` says so).
- **The MCP server's process.** It runs as `python -I -m vm_broker.mcp`: plain `-m` would put the working directory
  (the consumer repo) first on `sys.path`, so a repo's `mcp/` folder or `yaml.py` could replace the broker's imports in
  a process that holds the host credential. Every child process (powershell.exe) starts with stdin from `DEVNULL` and
  its stdout captured, so it can neither read nor corrupt the JSON-RPC stream on the server's stdio.
- **Supply chain:** ISO and cloud-image checksums recorded in `image.json`; the Ubuntu image's GPG signature checked,
  and the image converted with Ubuntu's own `qemu-utils`; the ffmpeg build's source and SHA-256 recorded; packages a
  consumer installs come from public sources at its own choice.

## 12. Logging

- `state\events.jsonl` on each host: one JSON line per request and per state change: time (UTC), host, consumer, verb,
  VM, job, request hash, exit code, duration, finding names. Never a secret, a password hash or script content.
  Kept 180 days, rotated monthly.
- `jobs\<job>.log`: the backend scripts' output per job. Scripts never print secrets; the executor also replaces any
  known secret value with `***` before writing, as a backstop. Kept 30 days.
- The Windows Application log gets one summary event per changing verb (source `vm-broker`, registered once at
  install, section 3.8), so a later monitor can pick it up.
- `vm_status` and `job_status` show the last 20 log lines to the owner; `vmb-admin` shows everything.
- Client side: the MCP server logs to stderr only.

## 13. Testing

All tests run in a working copy outside OneDrive (`C:\work\vm-broker`), or on claude01.

### 13.1 Unit tests (standard-library `unittest` + PyYAML)

- Strict YAML: the cases from app-broker's `yamlstrict.py` tests, ported.
- Validator: one good request per profile; bad ones per rule (each finding names its field). Golden files, including
  every example in `CONTRACT.md` section 4 run through `plan`, so an example cannot drift from the rules.
- Policy: budget math from production maxima, reservations (`creating` records) and the floor; quotas (disk counting
  checkpoint files); approval rules; the approval id; the "not in v0.1" rejections.
- Ownership: name, Notes and registry mismatches; the denylist wins over a registry entry; reserved name prefixes; a
  name that matches two VMs; a net owned by another consumer.
- Paths and switches: everything outside `vmb\` and the allowed switches is refused.
- Jobs: states, one job per VM, timeouts, idempotent repeats, a job whose task died (`lost`), `destroy` after `lost`,
  `create` on a `failed` VM (exit 1).
- Concurrency: two creates at once that together cross the budget (one gets exit 6), and two creates of the same name
  (one gets exit 2), against the host-side lock (the fake backend models it).
- Results: `run` exits 0 with the guest's code in `exit_code`; an MCP result over 64 KiB is cut and the whole output
  saved; `snapshot --replace` keeps the old checkpoint when the new one fails.
- A **fake backend** (in memory: hosts, VMs, switches, RAM, disks, checkpoints) behind the same interface as the
  Hyper-V backend; every verb runs against it end to end.
- MCP tools and CLI verbs return the same JSON for the same fake state.

### 13.2 Backend scripts

- Every script takes JSON in and prints JSON out, supports `-WhatIf` (every check runs, nothing changes, like
  `New-WindowsVM.ps1`), and re-checks ownership itself.
- Pester tests with the Hyper-V cmdlets mocked, run on the laptop in `C:\work`.
- Injection: Pester tests put quotes, `$()`, backticks, `;` and newlines into every string field (commands, payloads,
  paths, labels, names) and check that nothing runs on the host and the value reaches the guest stub unchanged
  (section 11).
- `Test-VmbHost` (`selftest`) checks: no host adapter on a `vmb-*` switch; guards and MAC spoofing on every `LAN2`
  vNIC; the CPU limit and the I/O cap on every broker VM; the folder ACLs; in v1 also the sshd options, the keys file,
  and the pipe's DACL and flags.
- A `-WhatIf` pass against servera is a live read: it needs the operator's go-ahead the first time.

### 13.3 Acceptance A: `win11-lab` (v0 section 7)

```
vmb create examples/lab-p1.yml                       # win11-lab, isolated net with internet (needs Q23's rule)
vmb snapshot lab-p1 smoke-start
vmb director lab-p1 record_start smoke.mkv
vmb director lab-p1 run_visible "winget --version"
vmb director lab-p1 marker winget-version
vmb director lab-p1 record_stop
vmb copy-from lab-p1 C:\ProgramData\LabDirector\out\smoke.mkv C:\work\recordings\smoke.mkv
vmb copy-from lab-p1 C:\ProgramData\LabDirector\out\smoke.markers.json C:\work\recordings\
vmb restore lab-p1 smoke-start
vmb destroy lab-p1 --confirm lab-p1
```

Passes when: `ffprobe` shows H.264 1920x1080 and at least 3 s; the video shows the terminal and the typed command; the
markers file has one entry; the director answers within the restore time measured in section 15 item 11 (target 60 s,
which reading an 8 GB memory file from the RAID 5 may miss); after `destroy` there is no VM, no folder, no switch or
router left, the record is a tombstone, and the host's broker use is back to where it was. The same sequence as MCP
tool calls from another Claude Code project gives the same result.

### 13.4 Acceptance B: `ubuntu-desktop-xrdp`

```
vmb create examples/xrdp-test.yml      # lan; user "tester" with an SSH key and password: generate
vmb status xrdp-test                    # address
ssh tester@<address> 'systemctl is-active xrdp; sudo ufw status verbose'
vmb snapshot xrdp-test clean ; vmb restore xrdp-test clean
vmb stop xrdp-test ; vmb start xrdp-test     # the first reboot after the seed was removed
ssh tester@<address> 'id; ip -4 addr'
vmb destroy xrdp-test --confirm xrdp-test
```

Passes when: create finishes in under 15 minutes (target; record the time); ssh works with the key and refuses a
password; ufw allows only 22/tcp and 3389/tcp, only from 192.168.10.0/24 and the two VPN ranges; port 3389 answers an RDP
connection request from claude01; after the stop and start the SSH host key is unchanged (no `known_hosts` warning),
there is no `ubuntu` user, and the address is the same. Human step: the operator reads the password with
`vmb-admin password xrdp-test tester`, runs `xfreerdp3 /auth-only` from claude01 (password typed by them), then opens
`mstsc` from the laptop once and sees the Xfce desktop.

### 13.5 Acceptance C: guardrails

Each must be refused with nothing changed:
- `destroy docker01`, `stop Firewall3`, `snapshot servere` (denylist);
- a hand-made VM named `vmb-fake` without a registry record (ownership), and a second hand-made VM with the same name
  as a broker VM (a name that matches two VMs);
- a request with `switch: WAN` (unknown key) and a `network.net` that would collide with a non-`vmb` switch;
- `name: rtr-x` (reserved prefix), and a name already used on the other host;
- a create on serverd while its budget is 0, and a create on servera that would cross the budget (exit 6);
- two creates started at once that together would cross the budget: one gets exit 6;
- `activation: mak`, `lease: {keep: true}` and `access: [winrm]` (v1: exit 5, a pending request, nothing built; before
  v1: exit 2, "not in v0.1");
- `internet: true` while `policy.yml` does not record netadmin's rule (v1: exit 5; v0.2: exit 2);
- a second consumer naming the first consumer's net, and a VM for an existing net with a `host:` that disagrees;
- a second consumer acting on the first consumer's VM (v1);
- `selftest`: no host adapter on any `vmb-*` switch, every `vmb-*` switch Private, every broker VM's files inside its
  folder, the guards and caps of section 13.2.

And each of these must fail from inside the broker:
- from a lab VM on an isolated net with internet: `curl` to the house's WAN address, to 192.168.10.1, to docker01
  (192.168.10.11) and to TCP 22 on its router (10.77.N.1) must all fail, while `curl` to a public site works;
- a broker VM on `lan` running a DHCP server that answers only a second test VM's MAC: the second VM's lease still
  comes from the Windows DHCP servers (DHCP guard), and a router advertisement from the first VM does not reach it.

## 14. Milestones

**v0.R: the recording slice, due Wednesday 2026-10-14 (built first, before v0.1).** The operator wants the CS 101
walkthrough recordings by then (Q8, answered 2026-10-10). Only what the recordings need: direct mode from the laptop,
one host.

**The operator, 2026-10-10 evening: build it on serverd, now.** "I would prefer that you build it out on serverd as servera is
going to get rebuilt soon. just use a smaller amount of ram for the initial build if needed. also, no need to wait just
do it all now." So, superseding servera in the rest of this section:
- The recording VM lives on serverd (`policy/serverd.json`); the ISO is already there (`D:\ISO\`), so no copy.
- serverd holds Firewall3's replica, which 6.4 kept free of broker VMs for a failover. The policy's
  `firewall_mode: elsewhere` turns that around for v0.R: a broker VM starts on serverd only while Firewall3 is not
  running there. **Before Firewall3 fails over to serverd (servera down, or its rebuild), `vmb stop lab-p1` must free
  the VM's memory**: netadmin's failover steps need that line, and so does servera's rebuild runbook.
- Memory: serverd had about 4.7 GB available (the fw-arbiter lab holds 14 GB). Above the 3 GB floor the build gets
  1024 MB startup, 1024 MB minimum and 3072 MB maximum (Dynamic Memory, priority 20). For the recordings it wants
  about 4 GB: the operator frees room on serverd (for example the lab while it is idle) and the memory is raised.
- The copy window is open all day (`copy_window.always`); the firewall monitor runs throughout.
- On serverd the firewall's own CPU and disk are not shared with the VM (Firewall3 runs on servera); what the monitor
  watches there is ping and DNS through Firewall3, Firewall3's replica health and lag, and serverd's disk latency.

The operator's decisions (2026-10-10):
- **One recording VM, Server 2025 Desktop Experience** (`win11-lab` with `lab_os: win2025`, section 8.3), **activated
  once with their MAK.** The edition follows the key: read `slmgr /dlv` on servere first (servere is MAK-activated 2025
  Standard, so most likely Standard). Because of the activation it is one kept VM: no image and no clones in this
  slice. Its checkpoint `golden` (activated, policies set, director staged, no dev tools) is the clean student PC, and
  chapters restore checkpoints as in v0. Request name `lab-p1` (Hyper-V name `vmb-lab-p1`), unless the walkthrough
  session wants another.
- **On `lan`** (Q16's interim, approved): Windows Firewall blocks all inbound (`Set-NetFirewallProfile -All
  -DefaultInboundAction Block -AllowInboundRules False`); no RDP, SSH or WinRM listener; DHCP guard and router guard
  on; internet through Firewall3 like any LAN PC. One recording VM at a time.
- **Dynamic Memory** (6.4): startup 4 GB, minimum 4 GB, maximum 8 GB, priority 20; 4 vCPUs with the weight and limit
  of 6.5; the disk I/O cap. **The firewall must not notice:** measure ping and DNS through Firewall3 from servera's
  host before anything runs, then during the build, a recording and a checkpoint (section 15 items 7, 11, 12). If they
  get worse than the baseline, lower the caps before going on.
- **The chapter scripts do not exist yet.** A separate walkthrough session (`cs101-walkthroughs`) writes them once
  the VM records, from the lab material the operator gives it. vm-broker provides the VM, the director and the relay.

In the slice:
- Backend scripts (PowerShell; `-WhatIf`; JSON in and out; their own ownership checks): create the VM from the Server
  2025 ISO the way `New-WindowsVM.ps1` does, with `New-VM -Version 10.0` (9.1), the guards and the caps; start, stop,
  status; snapshot (standard checkpoint); restore (then wait for the director's `/health`); snapshots, snapshot-rm;
  run, copy-to and copy-from over PowerShell Direct as `vmbadmin`; console (the `vmconnect` line). `destroy` is
  refused for this VM except through `vmb-admin` (it holds an activation).
- The 8.3 image steps, applied to this one VM: policies, never locks, auto-logon, `vmbadmin`, the director and ffmpeg
  staged with their ACLs, `Set-VMVideo` 1920x1080, Server Manager off at logon, updates
  installed and then held. Patch Tuesday is 2026-10-13, the day before the deadline: the hold must be in place by then.
- The director: the 10.3 API without image matching; recording as in 10.4.
- The CLI and MCP verbs for the above plus `director`, enough for acceptance A; a registry entry for the VM.
- `vmb-admin activate <vm> --key-file <path>`: the operator runs it; the key travels only as an `-ArgumentList` value; online
  activation, then `slmgr /cpky` and the registry check (section 9). Proved first with the public GVLK on the same VM
  (section 15 item 15). The session never reads the key file.

Not in the slice: Ubuntu, isolated nets and the router, images and clones, quotas, leases, approvals, the gate. They
follow in v0.1 and v0.2 after Wednesday.

| day | broker session | The operator |
|---|---|---|
| Sat 10-10 | the code against the fake backend, with unit tests; the director; the backend scripts with `-WhatIf`; one message to the operator with every go-ahead (below) | answers the go-aheads |
| Sat night | builds the VM on servera: WIM applied, first boot, Windows Update | |
| Sun 10-11 | the 8.3 steps; the early tests 6, 7, 8, 11, 12, 13, 16; the GVLK proof | runs `vmb-admin activate` once; checks a screenshot of the desktop; then `golden` is taken |
| Mon 10-12 | acceptance A on `lan`; fixes | approves the smoke video; starts the walkthrough session with the lab material |
| Tue 10-13 | supports the walkthrough session; fixes | sign-ins and the other human steps (10.5) |
| Wed 10-14 | re-takes; recordings copied to `C:\work\recordings\` | |

The go-aheads to ask for in one message, early (the operator is traveling): read-only facts on servera and servere
(`slmgr /dlv` on servere); copying the Server 2025 ISO from serverd to servera (a netadmin change: throttled, or done
by the netadmin session); the downloads (a static ffmpeg build, Python embeddable or PyInstaller: name, source, size);
creating the VM on servera with the one-time install steps of 3.8 that the slice needs; and when the heavy disk work
may run (the copy window is 01:00-06:00).

Done when: acceptance A (13.3) passes on `lan` instead of an isolated net, without its last step (this VM is kept;
`destroy` is tested on throwaway VMs in v0.1); the desktop shows no watermark (`slmgr /xpr`: permanently activated);
and the firewall measurements are no worse than the baseline.

**v0.R as built (2026-10-10).** The code is in `src/vm_broker/` (core, CLI, MCP, `hostctl` for the build session,
`vmb-admin` for the operator), `src/vm_broker/backend/ps/` (the host scripts: `Vmb.ps1` dispatches one verb per call; long
steps run as one-shot SYSTEM tasks through `Invoke-VmbJob.ps1`), `src/vm_broker/backend/runner.ps1` (the laptop side of
each WinRM call), `src/vm_director/` and `tools/Stage-LabDirector.ps1`. The order of the live steps, each after
the operator's go-ahead:

| # | step | how | writes on servera |
|---|---|---|---|
| 1 | read-only facts and the firewall baseline | `hostctl inventory`, `hostctl baseline --minutes 30` (inline: no code installed yet) | nothing |
| 2 | the one-time install (3.8) | `hostctl install` (`--whatif` first) | `C:\VMs\vmb\` with its ACL, `policy.json`, the secrets certificate |
| 3 | the host scripts | `hostctl sync-code` (SHA-256 checked; `code\VERSION`; every later call refuses a version mismatch) | `vmb\code\` |
| 4 | the director bundle | the downloads, `tools/Stage-LabDirector.ps1`, `hostctl stage-director <dir>` | `vmb\media\labdirector\<version>\` |
| 5 | the build | `vmb create vmbroker/lab-p1.yml` as `cs101-walkthroughs`; the job waits for the copy window, then for the ISO | the VM under `vmb\vms\<id>\`, one SYSTEM task |
| 6 | the monitor | `hostctl fwmon --hours 30` (ping, DNS and counters every 10 s into `state\fwmon\`) | one SYSTEM task, small files |
| 7 | the ISO | `hostctl copy-iso \\serverd.corp.example\D$\VMs\iso\<iso>` (throttled, in the window, disconnected session) | `C:\VMs\iso\<iso>` and `.sha256` |
| 8 | morning | `vmb status`, the setup screenshot, `hostctl gvlk-proof lab-p1`, the operator's `vmb-admin activate lab-p1`, `vmb snapshot lab-p1 golden`, the early tests, acceptance A | checkpoints |

The build job's steps (`window`, `iso`, `disk`, `vm`, `boot`, `first-contact`, `updates`, `lab-setup`, `director`,
`check`) are recorded on the registry record; `hostctl resume lab-p1 --from <step>` runs it again from a step.

**v0.1: the operator's laptop, servera, two profiles.** Smallest slice that is useful by itself.
- Q3 is answered (section 6.4): the budget is what servera has available above the floor.
- Core: schema, strict YAML, validator, profiles, policy (budget above the floor, the Firewall3 check, denylist), registry on
  the host, jobs (with `lost` detection), errors, the consumer name from `vmbroker/consumer`. Check-and-reserve on the
  host under the lock. Fake backend and unit tests.
- Hyper-V backend over WinRM from the laptop (direct mode), long steps as one-shot SYSTEM tasks on servera. VMs
  addressed by VMId; DHCP guard, router guard, the CPU limit and the I/O cap on every VM.
- One-time install on servera (section 3.8): `C:\VMs\vmb\` with its ACL, the secrets certificate, the event source.
- Images: `ubuntu-server` and `win2025-core` on servera, built on `lan` in the copy window.
- Network: `lan` only. Access: ssh. Guest firewall, users and keys, apt/features/choco, scripts.
- Verbs: contract, whoami, profiles, capacity, plan, create, list, status, start, stop, destroy, extend, snapshot,
  restore, snapshots, snapshot-rm, run (Windows), copy-to and copy-from (Windows), console, job, wait. CLI and MCP.
- `vmb-admin` on the operator's terminal: image build and list, password, reap, budget, floor, freeze and unfreeze, job
  cancel, destroy --any-owner, selftest (section 5.2).
- Refused with exit 2 and "not in v0.1": `activation: mak`, `keep`, `{secret: NAME}`, isolated nets, rdp, xrdp,
  winrm, and run and copy on Linux.
- Done when: an `ubuntu-server` VM (create, ssh with a key, ufw as requested, a reboot that keeps keys and address,
  destroy) and a `win2025-core` VM (create, run, copy, snapshot, restore, destroy) pass on servera, and acceptance C's
  single-host cases pass (guards, names, concurrency, the v0.1 refusals).

**v0.2: the CS 101 slice** (still direct mode).
- `win11-lab` image (needs the operator's ISO), isolated nets with the router VM, the director (v1 API), recording, the
  `vm_director` relay. Acceptance A.
- `internet: true` works once netadmin's rule for router VMs is in place and recorded (Q23); until then it is refused,
  and so is acceptance A. If the recordings are due earlier: Q8 and Q16's interim.

**v1: the enforced contract.**
- Gate (SSH forced command) and executor (SYSTEM) on each host, hardened as in section 3.3; consumer keys bound to
  consumer names; quotas; approvals and the rest of `vmb-admin`; the lease reaper; the memory watcher (if the operator wants
  it, Q3); named secrets; served `CONTRACT.md` and skill; consumers on claude01.
- Profiles `win2025-desktop` and `ubuntu-desktop-xrdp`; access rdp and xrdp with generated passwords; winrm by
  approval.
- Linux `vm_run` and copy over a Hyper-V socket; MAK activation with approval, proved first with the public GVLK.
- The backup and rebuild rehearsal on a lab host (section 3.7), before the first `keep` VM.
- Acceptance A, B and C through the gate.

**v2: later.**
- `sandbox` profile (no internet unless approved, no copy-from, Guest Service Interface off): the only place for
  untrusted code.
- Director: image matching or UI Automation; a Hyper-V socket transport.
- AVMA once servera runs Server 2025 Datacenter (which needs the HPE controller, Q7). Optional domain join into a
  delegated OU.
- Router port forwards (RDP into lab nets); DHCP reservations and DNS names through netadmin.
- Multi-VM requests (several VMs on one net in one request); an `update` verb (resize, firewall, lease, software).
- Serial console logs of Linux first boots; enhanced session for Linux desktops over a Hyper-V socket (xrdp on vsock).
- `evacuate` called by netadmin's failover tooling; an Azure backend if ever needed.

## 15. Open items to test early

Items 1 to 10 are leads from `docs/research/grok-vm-provisioning-2026-10-08.md`; items 11 to 17 come from the review
(section "Review notes"). Each is settled on servera (or a lab host) before the design depends on it:

1. The current Ubuntu 24.04 shim boots on a patched Server 2022 host with `MicrosoftUEFICertificateAuthority`.
2. The generic image finds a `CIDATA` FAT VHDX seed with no kernel command line change; the KVP daemon reports the
   address; a guest-to-host KVP status value reaches `Msvm_KvpExchangeComponent`. After the seed is removed, a reboot
   keeps the SSH host keys, the users and the addresses: check what `ds-identify` reports (does it find "Azure"?), with
   and without `cloud-init.disabled` and the pinned `datasource_list`.
3. `qemu-img`'s VHDX mounts in Hyper-V (fallback: `vpc` then `Convert-VHD`).
4. A differencing child can be grown with `Resize-VHD` before first boot (fallback: copy).
5. Windows 11 evaluation ISO: `install.wim` or `install.esd`; the Enterprise index; whether an unattend local account
   still skips the Microsoft account and network pages; that `PreventDeviceEncryption` set offline keeps the disk
   unencrypted through the build and on a clone (`manage-bde -status`: Fully Decrypted).
6. `Set-VMVideo -ResolutionType Single` at 1920x1080 gives 100 % scaling in the guest, not 150 %.
7. gdigrab keeps getting frames with no VMConnect window open; vCPU cost of `ultrafast` and `veryfast` at 1080p30, with
   3 and with 4 vCPUs; dropped frames while the firewall is busy; ping and DNS latency through Firewall3 while a
   recording runs.
8. The lock settings survive a reboot; auto-logon survives a restore.
9. Windows OpenSSH forced commands (`restrict,command=`), the `Match` block options, and key logons for a domain
   account through sshd on a DC (on a lab host first).
10. What an unactivated Server 2025 volume install does after its grace period (`slmgr /dlv`, `/xpr`).
11. Checkpoints: the time to take a standard checkpoint and to restore it for a `win11-lab` VM at 4 GB and at 8 GB on
    servera, with Firewall3's latency (ping and DNS through it) measured meanwhile. This settles the 6g default and
    acceptance A's restore target.
12. Disk: that `Set-VMHardDiskDrive -MaximumIOPS` caps a broker VM on servera's local array, the cap's value, and
    Firewall3's and the DC's disk latency during an image build and a full copy, with and without the cap and the copy
    throttle.
13. winget over PowerShell Direct (session 0, App Installer not registered for that account). Fallbacks: the
    `Microsoft.WinGet.Client` module, or a one-shot scheduled task in a user session.
14. LAN2 guards: a test VM's DHCP server reaches no LAN client (with a scope that answers only one other test VM's MAC);
    whether a Hyper-V port ACL can stop a broker VM's forged ARP reply for 192.168.10.1.
15. MAK handling on a test VM with the public Server 2025 Standard GVLK (from `docs/research/`): passed as an argument,
    the key does not show in event 4104 with script block logging on; after `slmgr /cpky` the `DigitalProductId` value
    no longer decodes to the key (checked with a short script of our own, not a downloaded key-finder).
16. `win11-lab`: PowerShell Direct as `vmbadmin` gets an elevated token (setting the address needs one).
17. Lost jobs, on a lab host: kill a create job's task, and reboot the host in the middle of another job; `job_status`
    shows `failed: lost` with the step it reached, and `destroy` cleans up.

**Results of the first build (2026-10-10, serverd).**

| what | found | done about it |
|---|---|---|
| DISM for a 26100 image on a 2022 host without the ADK | the Server 2025 media's own `sources\dism.exe` (10.0.26100.1, Microsoft-signed) applies it | the build uses the ADK's, else the media's (signature checked), else the host's |
| speed on serverd's array | the ISO's SHA-256 in 4.5 min (8.6 GB); the apply about 47 min (about 15 GB at 6 MB/s); specialize about 25 min | a resumed disk step finishes an applied but unbooted image instead of applying it again |
| OOBE on this media without a key in the answer file | it stops at "It's time to enter the product key" | the answer file carries the edition's public GVLK (no KMS host, so nothing is activated or used up; the MAK replaces it) |
| PowerShell Direct logons | `<computer>\<user>` is refused intermittently ("an error has occurred which Windows PowerShell cannot handle"); `.\<user>` works | every guest credential is `.\<user>` |
| `Protect-CmsMessage -To` | refuses a `Cert:\` path | the certificate object is passed |
| serverd's memory | about 4.5 GB available; it dips about 0.4 GB while a big write is in flight | the build starts at 1 GB (Dynamic Memory to 3 GB) to clear the 3 GB floor |
| the firewall during the apply, seen from servera | ping p95 1.7 ms, DNS p95 2.9 ms, Firewall3's vCPUs 1-2 %: no change | none needed |
| the firewall seen from serverd during the apply | spikes (ping max 2.3 s, DNS p95 0.4-0.8 s) while serverd ran at 72-81 % CPU with a disk queue up to 95 | a sampler on the loaded host measures its own host; the firewall is judged from servera |
| the I/O cap on serverd | for small random writes 800 normalized IOPS is more than the RAID 5 gives, so it never binds; reads it does bind: a guest boot reads at 6.2 MB/s (normalized throughput 805, queue 8 at the VM's disk) while serverd's array is 77 % busy (disk queue 12, up to 55); a boot takes about 5 minutes to the desktop | the cap stays at 800: a higher one would load the array further, with servere, cloud01 and the Replica copies behind it. More guest memory (a bigger file cache, kept in each checkpoint) helps more; the operator's call, serverd being shared (item 12) |
| `run_visible` on a cold Windows Terminal (acceptance A, 2026-10-11) | behind the cap, Windows Terminal's window showed after more than 20 s and its shell started 25 s after the launch; the first build's 20 s wait gave up | the director waits up to 90 s for the window, then for the new shell to do real work (0.3 s of CPU) and sit idle (2 s, at most 60 s in all) before it types; the answer says how long each took |
| acceptance A on `lan` (2026-10-11 03:58, director 0.1.2) | **passed**: every step ok; H.264 1920x1080, 48.7 s; the frame at 38 s shows `winget --version` and its output; one marker. `run_visible` cold: window 9.8 s, shell ready 3.6 s later, 16 characters in 1.9 s. The director answered 97.7 s after the restore began: restore 47.7 s, then PowerShell Direct 38 s, because `smoke-start` was taken just after a reboot while the guest was still busy | the restore target comes from item 11 (below): take `golden` on a settled VM |
| item 7: recording cost, 60 s at 30 fps | `ultrafast`: 2.9 MB, 1762 of 2046 frames (86 %); `veryfast`: 1.6 MB, 2124 of 2430 (87 %). The VM's vCPUs p50 17-38 %, p95 at most 45 % (far from the 75 % limit), while serverd ran at 53-67 % (p95 up to 93 %) with the fw-arbiter lab; the missing frames come from the host's contention (weight 50) | `ultrafast` stays the default (`veryfast` slowed the guest's next call); for clean timing record at 24 fps, or with serverd quieter |
| item 11: checkpoint and restore of a settled VM (about 1.3 GB of memory) | checkpoint 29 s; restore 50.5 s, PowerShell Direct at 57 s, the director at 62.6 s | acceptance A's restore target on serverd: about 65 s for a settled checkpoint |
| item 12: the guest's write-through rate | 6.2 MB/s (189 MB in 30 s), the 800-IOPS cap exactly, with serverd's disk about half idle. The first run reported 405 MB/s: with string arguments Windows PowerShell 5.1 found the FileStream overload ambiguous, the stream stayed `$null` and the loop counted failed writes | the cap binds writes as it binds reads; the test now uses typed arguments, stops on errors and checks the file's size |
| removing or replacing a checkpoint | the host merges disks for minutes; in acceptance A the next director call (`record_start`, waiting for ffmpeg's first frame) took 136 s | the relay gives `record_start` 90 s; CONTRACT.md 9: no recording right after |
| a job's status read during its own write (acceptance A, 2026-10-11 05:51) | the restore job finished (director at 59 s), but the laptop's status poll met the job's `File.Replace` of its record ("being used by another process") and reported the restore failed; the reverse (a reader blocking the writer's replace) could fail the job itself | readers share read, write and delete and retry; writers retry the replace; `jobs.wait` retries a failed status read twice |
| the guest firewall and listeners after first contact | all three profiles block every inbound connection; RPC and SMB (135, 139, 445) listen but nothing reaches them: from the LAN, TCP 22, 135, 139, 445, 3389, 5985 and 5986 and ICMP echo all fail | none needed |
| PowerShell Direct as `vmbadmin` (item 16) | an elevated token (with `LocalAccountTokenFilterPolicy` = 1) | none needed |
| the GVLK proof (item 15) | with script block and module logging on, the key shows in neither PowerShell log nor the Security log; after `ClearProductKeyFromRegistry` no registry value holds it, as text or as a decoded DigitalProductId | the MAK takes the same path |
| Windows Update on the September 2026 media | three updates; the Defender definitions fail every round while the "Windows Security platform" update is offered again each time; the image's antimalware platform is 4.18.25080.5 (August 2025) with definitions from 2025-09-16 | the build stops after five rounds; definitions are then taken from Microsoft's MMPC |
| the director started by its logon task | three times it stalled before it listened (0.4 s of CPU, no log line), once even with the 30 s delay; a later start serves at once. The cause (2026-10-11): Task Scheduler's default priority 7 ran it below normal with I/O priority Low (Explorer: Normal, I/O normal), and during sign-in the guest's disk sits at its cap | the task runs at priority 4 (normal CPU and I/O; the ffmpeg it starts inherits that); the 30 s delay and the broker's restart after a minute of silence stay as a backstop |
| `vmb.cmd` from PowerShell | double quotes inside a command are lost on the way (PowerShell passes arguments to batch files without escaping them) | the contract says: single quotes inside commands, or the MCP tool |
## 16. Decisions and open questions for the operator

Each has a recommended default; the build session uses the default until the operator says otherwise.

| # | question | recommended default |
|---|---|---|
| Q1 | Where does the broker run in v1? | A gate (SSH forced command) and a SYSTEM executor on each Hyper-V host, tried on a lab host first. Fallback: an HTTPS agent with client certificates (fw-arbiter style). v0.1 runs from the laptop over WinRM. |
| Q2 | Is it acceptable to install OpenSSH Server, an embeddable Python and a SYSTEM task on servera and serverd, which are DCs? | Yes, with sshd allowed only for `svc-vmbroker` and only from the consumer machines. If not, the fallback in Q1 has the same footprint minus sshd. |
| Q3 | Host budgets (section 6.4). Production on servera can grow to 28 of 32 GB (claude01 and docker01 Dynamic Memory maxima 12 and 8 GB, Firewall3 8 GB static), which leaves a safe budget of about 1 GB. Which lever? | **Answered (the operator, 2026-10-10):** Dynamic Memory is fine as long as the firewall is not affected; both hosts are at their 32 GB maximum. The budget is what is available above the floor, only on the host where Firewall3 runs (section 6.4); serverd stays at 0. |
| Q4 | Which edition is the Server 2025 MAK for, and how many activations are left? (A Visual Studio subscription key: VAMT shows the remaining count; the portal shows the key type, and whether a Datacenter key can be claimed for servera.) | Profiles use Standard; MAK only for `keep: true` VMs, one approval each. **Approved (2026-10-10): one activation for the recording VM of v0.R** (section 14). The edition is read from servere's `slmgr /dlv` first; the remaining count from VAMT when the operator has it. |
| Q5 | Do you have a KMS host key? | If yes, a KMS host is the better route for many Server VMs than the MAK; if no, ignore. |
| Q6 | Throwaway Windows Server VMs: unactivated volume media or 180-day evaluation media? | General throwaway VMs: volume media, unactivated, leases up to 30 days. Lab and recording VMs on Server 2025: the 180-day evaluation (no watermark) until servera runs 2025 Datacenter, then AVMA (section 9). **Answered for the recording VM (2026-10-10): Server 2025 with one MAK activation instead of the evaluation.** |
| Q7 | Rebuild servera on Server 2025 Datacenter? | Yes if licensed, and only with an HPE E208i-p controller: HPE does not support the S100i software RAID on Server 2025 (netadmin notes). AVMA then activates every 2025 guest on servera with no MAK count. Without the card servera stays on 2022, and long-lived 2025 VMs use the MAK (or KMS, Q5). Either way, back up the broker first (section 3.7). |
| Q8 | Milestone order: general VMs first (v0.1), then the CS 101 slice (v0.2)? And when are the recordings due? | **Answered (the operator, 2026-10-10): the recordings are due Wednesday 2026-10-14**, so the recording slice v0.R (section 14) comes first, with Q16's interim; v0.1 and v0.2 follow. |
| Q9 | Quotas per consumer | 3 VMs, 9g running memory, 400g disk, 40 checkpoints per VM, 30-day leases, 6 creates per hour. |
| Q10 | Should DHCP register DNS names for broker VMs on the LAN? | Not in v1; consumers use the address the broker reports. Ask netadmin later. |
| Q11 | Address range for isolated nets | 10.77.0.0/16, one /24 per net. Confirm nothing uses it. |
| Q12 | Router VM | Built from the `ubuntu-server` image (not the minimal cloud image, whose KVM kernel lacks Hyper-V's drivers), nftables + dnsmasq, 512 MB, public resolvers (1.1.1.1, 9.9.9.9), never the AD DNS servers, no TCP sshd. |
| Q13 | Leases | 7 days by default, 30 without approval; at the end the VM is shut down, and destroyed 7 days later unless extended. |
| Q14 | Should netadmin's failover tooling shut broker VMs down first (`vmb-admin evacuate`)? | Yes, in v1: broker VMs are the first thing to give up RAM in a failover. |
| Q15 | UAC in the lab image | The director runs at normal integrity; elevation steps are human steps. Alternative: admins elevate without a prompt in the lab image, and no UAC prompt is ever filmed. |
| Q16 | `win11-lab` only on isolated nets? | Yes. Interim, only if the recordings are due before the router and Q23's rule: `win11-lab` on `lan` with inbound deny-all, no RDP or SSH, one clone at a time, allowed by the operator in `policy.yml` for the recording period. **Answered (2026-10-10): approved for the recordings** (Windows Firewall blocks all inbound; no RDP, SSH or WinRM listener; one recording VM at a time). |
| Q17 | Recordings outside OneDrive (`C:\work\recordings\<consumer>\`)? | Yes; the consumer repo keeps the markers. |
| Q18 | In-guest recording preset | `ultrafast` with a re-encode on the laptop, decided after the CPU measurement. |
| Q19 | ffmpeg build and director packaging | Answered by D19 (2026-10-10): the Python embeddable, no PyInstaller and no Defender exclusion. Was: a static ffmpeg build from a named source with its SHA-256 recorded; the director as a PyInstaller onedir build, unsigned, with the Defender exclusion in the lab image. Signing with an AD CS code-signing certificate later. |
| Q20 | Domain join for broker VMs | Not offered in v1. In v2, if wanted, into a dedicated OU with a join account limited to it. |
| Q21 | Repository | Answered 2026-10-10: the operator asked for a GitHub repo with the architecture and diagrams; the build session created a private GitHub repo, private like app-broker and fw-arbiter. CI later. |
| Q22 | Which consumer keys in v1? | The laptop and claude01, as for app-broker; each bound to the projects that use VMs from that machine. |
| Q23 | OPNsense rule for router VMs (netadmin) | netadmin reserves a few LAN addresses for router VMs (for example four, each a DHCP reservation for a static MAC the broker assigns, so a new net needs no netadmin change), puts them in an alias, and blocks the alias to "This Firewall" and to the LAN net. The operator records it in `policy.yml` once acceptance C's checks pass; until then `internet: true` needs their approval (v1) or is refused (v0.1, v0.2). Wanted before v0.2. |
| Q24 | Broker secrets across a rebuild (section 3.7) | A "vm-broker secrets" certificate per host (CMS encryption), its PFX backed up with the CA backup. Alternative: machine DPAPI, accepting that a rebuild loses the secrets. |
| Q25 | Disk I/O (section 6.5) | The I/O cap and the copy window (default 01:00 to 06:00) from the section 15 measurement. Longer term, if checkpoints or builds still hurt Firewall3: an SSD for broker VMs, or servera's drive write cache (your call: servera is the firewall host). |
| Q26 | Who is a consumer? (section 3.4) | The project, in v0.1 and v1: `vmbroker/consumer` in its repo, and each machine's key bound to the projects that use it. Alternative: the machine (one consumer per key), so projects on one machine share VMs and quotas. |

## Review notes (2026-10-08)

An adversarial review of this draft raised 27 findings: 2 critical, 12 major, 13 minor. Each was checked against the
files named in it, netadmin's tools and netadmin's notes. All 27 were accepted and are worked into the sections above,
`CONTRACT.md`, `CLAUDE.md`, the skill and the module docstrings.

**Rejected:** none.

Where the change differs from the fix the review proposed, and why:

| finding | proposed | done instead | why |
|---|---|---|---|
| router reaches Firewall3 and the LAN (critical) | router VMs on DHCP reservations in an OPNsense alias; `internet: true` needs approval until then | a small fixed set of reserved router addresses, tied to static MACs the broker assigns (Q23); before v1 `internet: true` is refused rather than approved | a new net then needs no netadmin change; v0.1 and v0.2 have no approvals |
| DHCP and router guard (critical) | guards on every broker vNIC on `LAN2`; consider a port ACL that drops ARP replies for 192.168.10.1 | the guards as proposed; the ARP ACL became a test (section 15 item 14), and the residual risk is written down (section 6.3) | Hyper-V port ACLs match addresses, and it is not established that one can stop an ARP reply; no built-in vSwitch setting inspects ARP |
| v1 hardening gaps | `svc-vmbroker` gets no file access at all | read and execute on the code folder, nothing under `<VMRoot>\vmb\`; also an admin-owned keys file and `PIPE_REJECT_REMOTE_CLIENTS` | the gate runs as `svc-vmbroker` and must read its own code; the keys file and the SMB path were further holes of the same kind |
| Ubuntu image never reaches servera | convert on the laptop (qemu-img for Windows) or on the host | download, check and convert on claude01 with Ubuntu's own packages; the laptop relays the VHDX over WinRM | avoids a third-party Windows build of qemu-img, and claude01 still never holds the domain credential |
| Defender exclusion on `LabDirector\` | move the output folder outside the exclusion; exclude only the exe | exclude only `LabDirector\bin\` (read-only to users); `out\` stays where it is, outside the exclusion | same protection, and acceptance A and the contract keep their paths |
| shared `student` password on clones | a separate image admin account kept as an image secret | the same, plus a per-VM password for it at the first contact | the image password then works only on a fresh clone |
| disk I/O not capped | QoS caps, throttled copies, a build window | also: Ubuntu leases became differencing children | most creates then copy nothing |
| consumer identity | consumer = machine, or consumer = project | consumer = project (Q26) | it matches app-broker, where keys are bound to apps, and keeps v0.1's owners valid in v1 |
| names unique across hosts | the registry check covers both hosts | each executor enforces its own host; the client checks every host | in v1 one host's executor cannot read the other's registry |

## Review notes (2026-10-11)

After the first build, an adversarial review of the code (three passes: the host scripts, the Python side, the
director) raised 26 findings: 1 critical, 5 high, 9 medium, 11 low. Grok Build was asked for as a second reviewer; the session
could not run it on the code (its tool policy treats that as sending the code out), so `grok-review-prompt.md` and the
command went to the operator. The fixes are in commits `dae2bb2` and `731ca43`; architecture.md section 8.6 lists them.

| area | finding (severity) | done |
|---|---|---|
| activation | `gvlk-proof` on an activated VM replaces the MAK and leaves the record "activated" (high) | refused once the VM may hold an activation; both modes read the guest's licence first and refuse an activated guest |
| activation | a restore of a pre-activation checkpoint, or removing `golden`, undoes the activation (high) | such restores refused (request and job); `protected_checkpoints` (default `golden`) only for the admin |
| activation | the state is written only after the guest call returns (medium) | `activating` before the key; resume and restores treat it as activated |
| copies | `copy_from` writes guest bytes to any laptop path, the broker's own code included (critical) | only inside `VMB_OUT_DIR`, never over a file unless asked, plain local paths only |
| copies | `copy_to` uploads any file the laptop user can read (high) | only from the project or `VMB_OUT_DIR`, never from credential folders |
| director | a recording that ends by itself reports success (high) | `ended-early`; `health` says so |
| director | an input step the relay gave up on still types or clicks later (high) | `X-Vmb-Timeout` deadline in the director; `relay-timeout` in the relay; better typing estimate; step and call caps |
| director | the shell-idle wait calls a stalled shell ready; the wall-clock filter breaks on a clock step (medium) | readiness needs 0.3 s of CPU, then 2 s of quiet; new shells by (pid, creation time) |
| director | typing never checks the foreground (medium); a failed key release is swallowed (medium) | `focus-lost` in `run_visible`; releases raised; stuck modifiers released at start and after errors |
| director | a backtracking `wait_for` pattern freezes the director (medium) | nested repeats and backreferences refused; titles cut to 256 characters |
| relay | a director that listens but does not answer is never restarted (medium, from the new error word) | `Wait-VmbDirector` restarts on `relay-timeout` too |
| broker | one batch can wedge the MCP server for hours; float timeouts ignored (medium) | step at most 900 s, call at most 1800 s, floats counted, NaN refused |
| host | run, copy and director take no lock and ignore running jobs (medium) | exit 3 while a job runs on the VM |
| host | a restore does not re-check guards (low); the ISO path pattern ends in `$` (low) | full `Get-VmbVM` before the restored VM starts; `\z` |
| other low ones | C1, bidi and zero-width characters in request strings; markers kept after a failed write; an orphaned ffmpeg after a restart | refused; kept only once written; the restart block stops it |

Left open (low, architecture.md section 15): the relay trusts whatever listens on 127.0.0.1:47800 while the director
is down; `run_visible` types into an existing terminal that may still be busy; markers come about 0.2 s early with
`ultrafast` (the encoder's delay); the 100 % scaling check reads the sign-in value; `typing=layout` ignores Caps Lock
and dead keys; the console tools check only the `vmb-` prefix.

The director's logon stall, open since the first build, had its cause found in the same session: Task Scheduler's
default priority 7 (below normal, I/O priority Low) behind the guest's disk cap at sign-in. The task runs at priority
4 now, and the director starts by itself after a reboot (section 15).

### Grok Build's review (2026-10-11)

The operator then authorized Grok Build (1.0.30) as a second reviewer: read-only (plan mode, no web search) over a clean
export of `main`, with `grok-review-prompt.md`. Of its 13 findings, 9 were fixed (director 0.1.3 and the host code
of the same commit), 4 recorded:

| finding | done |
|---|---|
| `record_start` answered ok after 5 s without a frame (high) | it waits up to 45 s for the first frame; without one `no-first-frame`, ffmpeg stopped, nothing left behind |
| guest work and jobs were exclusive only for the check (high) | a guest call holds a shared handle on `state\vmuse-<id>` until its verb ends; a job starts only if it can open it alone |
| `set-policy` took any object (high) | `Test-VmbPolicy` on set-policy, install and every read (a hand edit fails closed): LAN switch, CPU, disk and memory caps, firewall rule, build memory |
| the host built any `win11-lab` name without `mak` or `keep` (medium) | v0.R builds only the policy's recording VM, kept, without users, firewall rules, software, scripts, access or autostart |
| a click landed after the relay gave up (medium) | the deadline is checked along the path and before each button; the click budget counts the lock wait |
| the student password or token in a result (medium) | every known secret is masked in every answer (not the password verb's); Winlogon's cleartext auto-logon password stays (v0.2: an LSA secret) |
| a disconnected or broker-net NIC passed without guards (low) | every NIC needs the three guards (router VMs, v0.2, will need their own rule) |
| a missing certificate downgraded secrets to machine DPAPI (low) | refused once `.cms` secrets exist on the host; the key stays exportable for its PFX backup (Q24) |
| a failed `copy-to` left a partial guest file (low) | the file is removed when the copy fails or its hash differs |
| admin verbs not bound to a person (high) | recorded: direct mode is advisory (architecture.md 8.5); the v1 gate is the fix |
| resume after `disk` still reinstalls and reboots (high) | recorded: by design (it is how the director is updated), admin only; never during a recording |
| checkpoint `CreationTime` kind (high, unverified) | checked on serverd: the snapshot job's UTC time matched its log, so the value is local time and the comparison holds |
| `copy-iso` leaves the credential in a disconnected session for up to 4 hours (medium) | recorded: `copy-iso` was not used in v0.R; fix before v0.1 uses it |
