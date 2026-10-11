# Grok Build code review (2026-10-11)

Grok Build 1.0.30, read-only (plan mode, no web search), over a clean export of `main` at `43b8100`, prompt
`grok-review-prompt.md`. What was done about each finding: design.md, "Grok Build's review (2026-10-11)". Raw output below.

---

I'll review the broker against those invariants, starting with the contract and design sections you named, then the host scripts and the laptop-side code that calls them.The contract and design are loaded. Next I’ll search the host scripts and the laptop broker for the ways those invariants can break.The review is still open. I am checking the strongest defect candidates against the current code so the report quotes the lines that actually fail the invariants.The worst defects are an ungated admin path onto the domain controller, a resume that rewrites an activated VM, guest work that does not stay exclusive with jobs, and a recording start that reports success before any frame exists.

## 1. High — Admin verbs are not bound to a person at a terminal

`src/vm_broker/hostctl.py:46`, `src/vm_broker/admin.py:62`, `src/vm_broker/backend/ps/Vmb.ps1:38`, `src/vm_broker/backend/ps/VmbHost.ps1:348`

`vmb-admin` refuses to run unless both stdin and stdout are TTYs. `hostctl` has no such check, and the host does not authenticate an admin caller either. Any process that can run the broker's Python (the same laptop session Design 11 treats as prompt-injectable) can call the host as SYSTEM.

```62:64:src/vm_broker/admin.py
    if not _tty():
        print("vmb-admin needs a terminal (the operator only); it refuses to run without one", file=sys.stderr)
        return S.EXIT_REJECTED
```

```46:47:src/vm_broker/hostctl.py
def main(argv=None):
    ap = argparse.ArgumentParser(prog="hostctl")
```

```348:351:src/vm_broker/backend/ps/VmbHost.ps1
        if (Test-VmbChange "replace the scripts in $code ($n files)") {
            foreach ($old in @(Get-ChildItem -LiteralPath $code -File)) { Remove-Item -LiteralPath $old.FullName -Force }
            foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $stage $f.path) -Destination (Join-Path $code $f.path) }
```

Those scripts are what the one-shot tasks run as `NT AUTHORITY\SYSTEM` (`VmbJobs.ps1:83`).

**Failure.** From the consumer session, `python -m vm_broker.hostctl sync-code` replaces the host scripts. The next job runs the replacement as SYSTEM on the domain controller and can stop `Firewall3` or read `secrets\`. The same entry point runs `snapshot-rm lab-p1 golden` (`hostctl.py:137` sends `consumer: *admin*`), `job-cancel`, and `resume`. A short script can also call the `password` and `activate` verbs; the TTY check lives only in `vmb-admin`'s `main`.

**Fix.** Enforce the same TTY-and-confirmation gate inside the host admin verbs, not only in one CLI. Do not treat "CLAUDE.md says wait for the operator" as that gate.

## 2. High — `set-policy` accepts any object, and resume applies it

`src/vm_broker/backend/ps/VmbHost.ps1:276`, `src/vm_broker/backend/ps/VmbLab.ps1:506`

The only check is `policy: 1`. CPU limit, IOPS cap, memory priority, `lan_switch`, `firewall_vm`, and `firewall_mode` are not checked. `New-VmbLabVM` (including a later resume from `vm`) writes those values onto the VM, and `Test-VmbGuards` then compares the VM to the same policy, so the weakened values pass.

```276:282:src/vm_broker/backend/ps/VmbHost.ps1
function Set-VmbPolicyFile {
    param($A)
    $pol = Get-VmbField $A 'policy'
    if (-not $pol -or (Get-VmbField $pol 'policy') -ne 1) { Stop-Vmb 2 'rejected' 'set-policy needs a policy object with policy: 1' }
    $lock = Enter-VmbLock
    try { Write-VmbJson (Get-VmbPath 'policy.json') $pol } finally { Exit-VmbLock $lock }
```

```506:509:src/vm_broker/backend/ps/VmbLab.ps1
    Set-VMMemory -VM $vm -Priority ([int]$pol.memory_priority)
    Set-VMProcessor -VM $vm -RelativeWeight ([int]$pol.cpu.weight) -Maximum ([int]$pol.cpu.limit)
    Get-VMNetworkAdapter -VM $vm | Set-VMNetworkAdapter -DhcpGuard On -RouterGuard On -MacAddressSpoofing Off
    Get-VMHardDiskDrive -VM $vm | Set-VMHardDiskDrive -MaximumIOPS ([int64]$pol.disk_iops_max)
```

**Failure.** `hostctl set-policy` with `disk_iops_max: 0`, `cpu.limit: 100`, `memory_priority: 50`, then `hostctl resume lab-p1 --from vm`. Hyper-V treats maximum IOPS 0 as unlimited. The recording VM no longer has the CPU cap, the disk cap, or the low memory priority. Setting `firewall_vm` to a name that is not running, with `firewall_mode: elsewhere`, makes `Test-VmbCapacity` (`VmbCommon.ps1:428`) stop refusing starts while Firewall3 has failed over onto serverd.

**Fix.** Reject a policy that does not match a fixed schema (switch name from an allow-list, CPU limit and weight, IOPS at least 1, memory priority, `firewall_mode` of `here` or `elsewhere`, firewall VM name unchanged). Re-apply guards from those constants, not from whatever was last written.

## 3. High — Resume past `disk` still rebuilds an activated VM's guest

`src/vm_broker/backend/ps/VmbLab.ps1:232`

The activation guard requires `$from` and only refuses steps at or before `disk`. `--from vm` (and `boot`, `first-contact`, `updates`, `lab-setup`, `director`) is allowed while `Test-VmbMayHoldActivation` is true. The record's `done_steps` are trimmed before the job runs.

```232:237:src/vm_broker/backend/ps/VmbLab.ps1
    # the disk step builds a new disk: on a VM that may hold an activation (activated, failed or activating) that
    # would throw away its one MAK activation
    $diskAt = [array]::IndexOf($script:VmbLabSteps, 'disk')
    if ((Test-VmbMayHoldActivation $rec) -and $from -and [array]::IndexOf($script:VmbLabSteps, $from) -le $diskAt) {
        Stop-Vmb 2 'rejected' "'$($rec.name)' may hold an activation ($(Get-VmbField $rec.activation 'state')); resuming from $from would replace its disk and lose it"
    }
```

Steps after `disk` are not harmless. `vm` calls `Set-VM` and puts memory back to the policy values (`Get-VmbLabMemory`, startup 1024 MB on serverd). `first-contact` runs `Set-LocalUser` for `student` and `vmbadmin`. `updates` installs Windows updates and reboots. `director` deletes `C:\ProgramData\LabDirector\bin` and kills `python` and `ffmpeg` (`VmbGuestBlocks.ps1:259-261`). `check` calls `Restart-VmbGuest`. If the VM is running, the `vm` step throws (`VmbLab.ps1:500`) only after `done_steps` has already been saved.

**Failure.** `hostctl resume lab-p1 --from director` on the activated recording VM deletes the director, kills ffmpeg, writes a new token, then reboots. The chapter file is abandoned. `--from vm` also throws away a memory size the operator raised for the recording and, on failure, leaves the record `failed` with the later steps no longer marked done.

**Fix.** If `Test-VmbMayHoldActivation` is true, refuse every `--from` except a step that cannot reset accounts, reinstall the director, install updates, or reboot. Do not trim `done_steps` until that check has passed.

## 4. High — Guest work and jobs are exclusive only for an instant

`src/vm_broker/backend/ps/VmbOps.ps1:305`

`Get-VmbRunningVM` takes the host lock, refuses if a job is active, then drops the lock before `run`, `copy-to`, `copy-from`, or `director`. `Request-VmbJob` only looks for another job. Nothing records that a guest call is in progress.

```305:311:src/vm_broker/backend/ps/VmbOps.ps1
    # no guest work while a job (restore, stop, snapshot, the build) runs on this VM: its result would be undefined
    $lock = Enter-VmbLock
    try {
        $active = Get-VmbActiveJob $rec.id
        if ($active) { Stop-Vmb 3 'busy' "job $($active.id) ($($active.verb)) is running on '$($rec.name)'; wait for it" }
    } finally { Exit-VmbLock $lock }
```

**Failure.** One process is inside `director` `record_start` or a long `type`. Another process (`vmb` in a shell, or a second broker) calls `restore golden`. The restore job starts, `Restore-VMSnapshot` reverts the disk, and the in-progress `.mkv` is gone. The same window exists for `stop` and for `snapshot` while input is still being sent.

**Fix.** Hold a per-VM lease across the whole guest operation, taken under the same lock that starts jobs, and refuse `Start-VmbJob` while it is held.

## 5. High — `record_start` returns success before ffmpeg has a frame

`src/vm_director/record.py:257`, `src/vm_broker/broker.py:116`

The broker budgets 90 seconds because the first frame took over a minute after a checkpoint merge. The director waits 5 seconds (`start_wait_s`, default 5.0), then returns success if ffmpeg has not exited, with `first_frame` false. `app.record_start` returns that as `ok: true`. The broker fails a director call only when `ok` is false (`broker.py:603`).

```257:269:src/vm_director/record.py
            s.wake.wait(self.start_wait_s)
            if s.t0 is None and s.eof:
                ...
                raise RecordError("ffmpeg-failed", ...)
            self._session = s
            return {"path": path, "filename": filename, "markers": markers_path, "started": s.started,
                    "first_frame": s.t0 is not None}
```

```116:119:src/vm_broker/broker.py
    elif action in ("record_start", "record_stop"):
        # record_start waits for ffmpeg's first frame: behind the disk cap, while the host merges a removed
        # checkpoint, that took over a minute (2026-10-11); a relay that gave up would hide a running recording
        t = 90
```

**Failure.** `vmb director lab-p1 record_start ch1.mkv` returns in about 5 seconds with `ok: true` and `first_frame: false`. The session types the chapter opening. gdigrab's first frame arrives a minute later, or ffmpeg exits at 6 seconds. `marker` can still fail with `not-ready`, but `type` and `click` do not look at the recorder. `record_stop` then reports `ended-early` or a file that is missing the start. The 90 second budget is never used to wait.

**Fix.** Block in `Recorder.start` until the first frame or until the relay budget is nearly gone, and return `ok: false` if none arrives. Treat `first_frame: false` as failure in `Broker.director`.

## 6. High — A pre-activation checkpoint can compare as newer (unverified)

`src/vm_broker/backend/ps/VmbOps.ps1:36`

`at` is UTC (`Get-VmbNow`, parsed with `AssumeUniversal`). The checkpoint is compared with `CreationTime.ToUniversalTime()`. If that value is UTC stored as `DateTimeKind.Unspecified`, `ToUniversalTime` treats it as local. On serverd (Eastern) that adds 4 or 5 hours.

```34:37:src/vm_broker/backend/ps/VmbOps.ps1
    if (-not (Test-VmbMayHoldActivation $Rec)) { return }
    $at = Get-VmbActivationTime $Rec
    if (-not $at -or $Checkpoint.CreationTime.ToUniversalTime() -lt $at) {
        Stop-Vmb 2 'before-activation' "checkpoint '$Label' is from before the activation ...
```

The tests never hit this. They assign `CreationTime = [DateTime]::Now` (`tests/ps/VmbTestHelpers.ps1:231`) and `CreationTime = Get-Date` (`tests/ps/Ownership.Tests.ps1:295`), both `Kind=Local`.

**Failure.** Unverified, because this repo does not show the Kind Hyper-V returns. If it is Unspecified UTC, a checkpoint taken 3 hours before activation compares as after `at`. `restore` is allowed, the MAK image is reverted, and `Invoke-VmbActivate` then refuses because the record still says `activated` (`VmbActivation.ps1:145`). The activation cannot be repeated.

**Fix.** Convert only when `Kind` is `Local`. If it is `Unspecified`, require the Hyper-V module's documented kind and compare in that kind. Add a test whose `CreationTime` is UTC with `Kind=Unspecified` and must be refused.

## 7. Medium — The student password and the director token come back to the consumer

`src/vm_broker/backend/ps/VmbGuestBlocks.ps1:185`, `src/vm_broker/backend/ps/VmbGuestBlocks.ps1:299`, `src/vm_broker/backend/ps/VmbCommon.ps1:60`

Lab setup stores the student password in cleartext for auto-logon. `student` is a local Administrator (`VmbGuestBlocks.ps1:28-31`). `token.txt` is readable by `student`. `vm_run` is an elevated `vmbadmin` shell and returns stdout in the result. `copy-from` accepts any absolute path (`Test-VmbGuestPath` only checks shape). `Write-VmbResult` does not run `Hide-VmbSecret`.

```185:185:src/vm_broker/backend/ps/VmbGuestBlocks.ps1
    Set-Reg $wl 'DefaultPassword' $StudentPw 'String'
```

```60:63:src/vm_broker/backend/ps/VmbCommon.ps1
function Write-VmbResult {
    param($Result)
    if ($script:VmbWhatIf) { $Result['whatif'] = @($script:VmbPlanned) }
    'VMB-RESULT:' + (ConvertTo-VmbJson $Result)
```

```335:335:src/vm_broker/backend/ps/VmbGuestBlocks.ps1
# The relay: our own loop runs inside the guest, reads the per-VM token there (it never leaves the guest) and
```

**Failure.** The guest (or a prompt injected from it) asks the session to `vmb run` `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultPassword`, or `vmb copy-from` `C:\ProgramData\LabDirector\token.txt`. The password and the token are in the tool result and the session transcript. The relay comment is false for any path `copy-from` can read.

**Fix.** Do not put the password in Winlogon; use a logon mechanism that does not store it. Deny `vm_run` and `copy-from` for `token.txt`, the Winlogon key, and the registry hives. Run `Hide-VmbSecret` over every result string, not only logs and exceptions.

Scrub of `setupact.log` after the hidden unattend password: unverified. `VmbGuestScrub` only rewrites listed unattend files (`VmbGuestBlocks.ps1:74-75`).

## 8. Medium — A click still happens after the relay has given up

`src/vm_director/app.py:244`, `src/vm_director/mouse.py:76`, `src/vm_broker/broker.py:112`

`type` stops at the deadline per character. `click` checks the deadline only while acquiring the input lock, then `Mouse.click` moves for the full `move_ms` with no deadline. The relay budget for a click is `move_ms/1000 + 15` (at most 20 seconds) and does not include the 30 second lock wait.

```244:245:src/vm_director/app.py
        with self._input(deadline):
            r = self.mouse.click(v["x"], v["y"], v["button"], v["double"], v["move_ms"])
```

```76:79:src/vm_director/mouse.py
    def click(self, x: int, y: int, button: str = "left", double: bool = False, move_ms: int = 400) -> dict:
        if button not in BUTTONS:
            raise ValueError(f"button must be one of {', '.join(BUTTONS)}")
        x0, y0 = self.move(x, y, move_ms)
```

**Failure.** A `type` holds the input lock. A second process's `click` (`move_ms` 5000, relay 20 seconds, deadline 18 seconds) acquires the lock at 17 seconds and moves for 5 seconds. The relay times out at 20 seconds and returns `relay-timeout`. The click lands at about 22 seconds. The session retries the click. Both clicks are on camera.

**Fix.** Pass the deadline into `Mouse.move` and stop before the button goes down if it has passed. Add the lock wait to the click budget, as `type` already does.

## 9. Medium — The host does not enforce the v0.R recording-VM rule

`src/vm_broker/backend/ps/VmbLab.ps1:181`, `src/vm_broker/schema.py:119`

The laptop validator requires `lease: {keep: true}` for this stage (`validate.py:460`). The host applies the recording-VM name and consumer check only when the request actually asks for `mak` or `keep`. There is no host `destroy` verb. `schema.py` says the host re-checks all of it.

```181:186:src/vm_broker/backend/ps/VmbLab.ps1
    $rv = Get-VmbField $pol 'recording_vm'
    $special = @()
    if ($req.activation -eq 'mak') { $special += 'activation' }
    if ((Get-VmbField $req.lease 'keep' $false) -eq $true) { $special += 'keep' }
    if ($special.Count -and -not ($rv -and $rv.name -eq $name -and $rv.consumer -eq $consumer)) {
```

**Failure.** A direct `create` (same WinRM credential, not via `vmb`) with profile `win11-lab`, network `lan`, no `mak`, no `keep`, and a name other than `lab-p1` is accepted. It consumes `max_vms` of 1. v0.R cannot destroy it, and `Uninstall-VmbHost` refuses while the record exists (`VmbHost.ps1:259`). The approved `lab-p1` create then gets "one recording VM at a time".

**Fix.** On the host, require the policy `recording_vm` name, that consumer, `lan`, and `keep`. Reject a body that still contains `users`, `firewall`, `software`, `scripts`, or `autostart`.

## 10. Medium — The ISO copy leaves the host credential in a disconnected session

`src/vm_broker/backend/runner.ps1:131`

```131:133:src/vm_broker/backend/runner.ps1
            $sb = { param($r, $j, $c, $cr) Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; & (Join-Path $r 'code\Vmb.ps1') -Verb 'copy-iso' -Json $j -Code $c -Credential $cr }
            $ds = Invoke-Command -ComputerName $fqdn -Credential $cred -Authentication Kerberos -InDisconnectedSession -SessionOption $opt `
                -ScriptBlock $sb -ArgumentList $root, $json, $code, $cred -SessionName ('vmb-iso-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmm'))
```

`$cred` is the homelab WinRM credential. The session is not removed. `IdleTimeout` is 14400000 ms (4 hours). Whether another admin on the DC can receive that session and read `$cr`: unverified.

**Failure.** `hostctl copy-iso` returns while a disconnected session on the domain controller still holds that credential, for up to 4 hours. Nothing in the runner records the session id where a later call would remove it.

**Fix.** Do not pass the credential into the disconnected session. Copy with a task that reads a CMS secret, or remove the session when the copy ends.

## 11. Low — Guard checks do not cover every vNIC

`src/vm_broker/backend/ps/VmbCommon.ps1:378`

```378:383:src/vm_broker/backend/ps/VmbCommon.ps1
        if ($sw -eq $lan) {
            if ("$($n.DhcpGuard)" -ne 'On') { $bad += "DHCP guard is off on '$($n.Name)'" }
            ...
        } elseif ($sw -like 'vmb-net-*' -or -not $sw) {
        } else { $bad += "a NIC is on switch '$sw'" }
```

A NIC whose `SwitchName` is empty, or `vmb-net-*`, is accepted with DHCP guard off, router guard off, and MAC spoofing on. A VM with no NIC also passes. `New-VmbLabVM` does set the three guards on the NIC it attaches (`VmbLab.ps1:508`). v0.R does not create `vmb-net-*` switches.

**Failure.** The LAN adapter is disconnected in Hyper-V Manager (or a second adapter is added on `vmb-net-lab` with spoofing on). `start` and `restore` succeed. The guest can spoof a MAC on that adapter.

**Fix.** Require exactly one NIC, on `lan_switch`, with all three guards, and refuse any other adapter.

## 12. Low — Secrets fall back to machine DPAPI, and the CMS key is exportable

`src/vm_broker/backend/ps/VmbCommon.ps1:269`, `src/vm_broker/backend/ps/VmbHost.ps1:249`

```269:272:src/vm_broker/backend/ps/VmbCommon.ps1
    } else {
        Add-Type -AssemblyName System.Security
        $b = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Value), $null, 'LocalMachine')
        [IO.File]::WriteAllText((Join-Path $dir "$Name.dpapi"), [Convert]::ToBase64String($b))
```

```249:249:src/vm_broker/backend/ps/VmbHost.ps1
                -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 3072 -NotAfter (Get-Date).AddYears(10)
```

If `CN=vm-broker secrets` is missing or expired, `Set-VmbSecret` writes DPAPI `LocalMachine` and does not fail. Any process on the host can unprotect that scope. The CMS private key is marked exportable.

**Failure.** The certificate is deleted or expires. The next password written for the VM is in `secrets\<id>\student.dpapi`. Code running as a normal user on the DC decrypts it.

**Fix.** Fail closed when the certificate is missing. Use `NonExportable`.

## 13. Low — A failed `copy-to` leaves a partial file in the guest

`src/vm_broker/backend/ps/VmbOps.ps1:387`

`copy-from` deletes its stage folder when the copy throws (`VmbOps.ps1:414-415`). `copy-to` deletes only the host stage. On a guest SHA mismatch it throws and leaves the partial guest file.

```387:387:src/vm_broker/backend/ps/VmbOps.ps1
            if ($after.sha256 -ne $sha) { Stop-Vmb 1 'failed' 'SHA-256 mismatch in the guest after the copy' }
```

**Failure.** The copy stops halfway. The next `copy-to` of the same path returns `exists` unless `--overwrite` is passed. With `--overwrite`, a later crash can again leave a short file that a later step treats as present.

**Fix.** Delete the guest file when the final hash does not match, as `copy-from` deletes its stage folder.

---

Sound, as far as the files show:

- Consumer strings on the host stay JSON values or `-ArgumentList` values; the only `[scriptblock]::Create` is `runner.ps1` building a script from the broker's own files; `Invoke-Expression` does not appear in the host scripts.
- A VM is opened by VMId only after the denylist, the `vmb-` prefix, the Notes tag, the registry id, a single name, and `ReplicationState -eq Disabled` all match.
- The create path sets DHCP guard, router guard, MAC spoofing off, the CPU cap, the IOPS cap, and memory priority before the first start.
- No host script creates an Internal or External switch, a NetNat, or a host management adapter.
- Check-and-reserve for create holds `Enter-VmbLock`; the scheduled-task command line carries only the 32-hex job id; resume from `window`, `iso`, or `disk` is refused when the record may hold an activation.
- The laptop v0.R gate drops `destroy` and `extend` and rejects any other profile, an isolated network, `users`, `firewall`, `software`, `scripts`, and `autostart`; `mak` and `keep` are limited to the policy recording VM.
- One consumer's `vmb` or MCP call cannot name `*admin*` or another consumer; `Get-VmbOwnedRecord` and `Get-VmbJobStatus` enforce the owner on the host.
- The director listens on `127.0.0.1` with `SO_EXCLUSIVEADDRUSE`, compares the token with `hmac.compare_digest`, and starts ffmpeg from an argument list; the relay reads the token only inside the guest.
- The unattend password is the hidden-sensitive-data blob, the answer-file key is limited to the public GVLKs, and the MAK is not written to a job file; `activating` is stored before the guest key call.
