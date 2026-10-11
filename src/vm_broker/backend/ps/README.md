# Backend scripts (Windows PowerShell 5.1, ASCII only)

They run on the Hyper-V host from `<VMRoot>\vmb\code\` (servera: `C:\VMs\vmb\code\`), installed and version-checked
by `hostctl sync-code`. Every call goes through `Vmb.ps1 -Verb <verb> -Json <json> -Code <version>` and prints one
line `VMB-RESULT:{json}`. `-WhatIf` runs every check and changes nothing: every change goes through
`Test-VmbChange`, and the result lists what would have changed. Long steps are jobs: one-shot SYSTEM scheduled
tasks (`\vm-broker\vmb-job-<id>`) that run `Invoke-VmbJob.ps1 -JobId <id>`; the job's arguments are data in
`jobs\<id>.json`.

Rules for every script (`docs/design.md` sections 6 and 11):
- **Consumer strings are data on the host.** Commands, director payloads, guest paths, labels and names travel only
  as JSON values or `-ArgumentList` values and run only inside the guest. No `Invoke-Expression`, no
  `[scriptblock]::Create` (the one exception is `runner.ps1` on the laptop, which sends our own files inline before the
  code folder exists). Secrets (the MAK, passwords) go the same way, never into script text that the guest's script
  block logging (event 4104) would record. `tests/test_ps_static.py` and the Pester tests in `tests/ps/` check this.
- **VMs by VMId only** (`Get-VM -Id`, `Invoke-Command -VMId`, `New-PSSession -VMId`). A name that matches more than
  one VM is refused.
- **Ownership is re-checked here** (`Get-VmbVM`): the `vmb-` name, the Notes tag and the registry record agree, the
  denylist wins, Replica is refused, and the guards and caps are still in place.
- **Check and reserve under the lock** (`state\lock`, opened with no sharing).

| script | does |
|---|---|
| `Vmb.ps1` | the entry: verb dispatch, the code-version check, errors as JSON |
| `Invoke-VmbJob.ps1` | runs one job (create, stop, snapshot, restore, fwmon) in its SYSTEM task |
| `VmbCommon.ps1` | JSON in and out, `-WhatIf`, ids and passwords, atomic state writes, the lock, logs and events, secrets (CMS to the "vm-broker secrets" certificate, or machine DPAPI), ownership, guards, paths, capacity, PowerShell Direct helpers |
| `VmbJobs.ps1` | job records, the SYSTEM tasks, liveness (`lost`), cancel |
| `VmbHost.ps1` | inventory, the firewall baseline and monitor, the one-time install and uninstall, policy, stage folders, code and director-bundle staging, the throttled ISO copy |
| `VmbLab.ps1` | v0.R: the recording VM's build (WIM onto a VHDX as `New-WindowsVM.ps1` does, the offline firewall shield, unattend, `New-VM -Version 10.0` with guards and caps, first contact, Windows Update, the 8.3 steps, the director, the desktop check) |
| `VmbGuestBlocks.ps1` | the script blocks that run inside the guest |
| `VmbOps.ps1` | status, list, start, stop, snapshot, restore, snapshots, snapshot-rm, run, copy-to, copy-from, the director relay, console |
| `VmbActivation.ps1` | the GVLK proof and the MAK activation (WMI methods, key only as an argument, then cleared and searched for), the password verb |