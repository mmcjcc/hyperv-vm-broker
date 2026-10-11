# VmbOps.ps1 - consumer verbs on an existing broker VM (docs/design.md 5.1). Dot-sourced by Vmb.ps1 and
# Invoke-VmbJob.ps1. Windows PowerShell 5.1, ASCII only.
#
# Each verb: the record (by name, owned by the consumer), then the VM by VMId after every ownership check
# (Get-VmbVM), then the work. Labels, commands, paths and director payloads are data: cmdlet parameter values or
# -ArgumentList values into the guest, never script text.

$script:VmbDirectorEndpoints = @{
    health = '/health'; type = '/type'; key = '/key'; click = '/click'; wait_for = '/wait_for'; screenshot = '/screenshot'
    record_start = '/record/start'; record_stop = '/record/stop'; marker = '/marker'; run_visible = '/run_visible'
}

function Test-VmbLabel {
    param([string]$Label)
    if ($Label -cnotmatch $script:VmbLabelPattern) { Stop-Vmb 2 'rejected' "label: must match $($script:VmbLabelPattern)" }
}

function Get-VmbCheckpoints {
    param($VM)
    @(Get-VMSnapshot -VM $VM -ErrorAction SilentlyContinue | Sort-Object CreationTime)
}

function Find-VmbCheckpoint {
    param($VM, [string]$Label)
    $hits = @(Get-VmbCheckpoints $VM | Where-Object { $_.Name -eq $Label })
    if ($hits.Count -gt 1) { Stop-Vmb 1 'failed' "two checkpoints are labelled '$Label'; ask the operator" }
    if ($hits.Count) { $hits[0] } else { $null }
}

# A checkpoint from before the activation would undo it on restore (and a MAK activation is not repeated for
# free). Restore refuses one on a VM that may hold an activation.
function Assert-VmbRestoreKeepsActivation {
    param($Rec, $Checkpoint, [string]$Label)
    if (-not (Test-VmbMayHoldActivation $Rec)) { return }
    $at = Get-VmbActivationTime $Rec
    if (-not $at -or $Checkpoint.CreationTime.ToUniversalTime() -lt $at) {
        Stop-Vmb 2 'before-activation' "checkpoint '$Label' is from before the activation ($(Get-VmbField $Rec.activation 'at')); restoring it would undo the activation"
    }
}

# The labels in policy protected_checkpoints (default golden): only the admin may remove or replace them.
function Assert-VmbLabelChangeable {
    param([string]$Label, [string]$Consumer, [string]$What)
    $protected = @(Get-VmbField (Get-VmbPolicy) 'protected_checkpoints' @('golden'))
    if ($Consumer -cne '*admin*' -and $protected -ccontains $Label) {
        Stop-Vmb 2 'protected' "checkpoint '$Label' is protected (policy protected_checkpoints); only the operator can $What it (vmb-hostctl snapshot-rm)"
    }
}

function Get-VmbConsoleLine {
    param($Rec)
    "vmconnect.exe $($env:COMPUTERNAME.ToLower()) -G $($Rec.vmid)"
}

# ---- read-only ------------------------------------------------------------------------------------------

function Get-VmbStatus {
    param($A)
    $rec = Get-VmbOwnedRecord ([string]$A.name) ([string]$A.consumer)
    $pol = Get-VmbPolicy
    $out = [ordered]@{ vm = $rec.name; hyperv_name = $rec.hyperv_name; host = $env:COMPUTERNAME.ToLower(); profile = $rec.profile
                       lab_os = (Get-VmbField $rec 'lab_os'); owner = $rec.owner; record_state = $rec.state
                       activation = (Get-VmbField $rec 'activation'); lease = $rec.request.lease; done_steps = @($rec.done_steps) }
    $job = Get-VmbActiveJob $rec.id
    $out.job = if ($job) { [ordered]@{ id = $job.id; verb = $job.verb; state = $job.state; step = $job.step } } else { $null }
    if (Get-VmbField $rec 'vmid') {
        $vm = Get-VmbVM $rec $pol -NoGuardCheck
        $out.state = "$($vm.State)"
        $out.uptime_s = [int]$vm.Uptime.TotalSeconds
        $out.vmid = $rec.vmid
        $out.cpus = $vm.ProcessorCount
        $out.memory_assigned_mb = [int64]($vm.MemoryAssigned / 1MB)
        $out.addresses = @(Get-VmbAddresses $vm)
        $out.mac = @(Get-VMNetworkAdapter -VM $vm | ForEach-Object { $_.MacAddress })
        $out.checkpoints = @(Get-VmbCheckpoints $vm).Count
        $out.guardrails = @(Test-VmbGuards $vm $pol)
        $out.console = Get-VmbConsoleLine $rec
        if ((Get-VmbField $A 'director' $false) -eq $true -and "$($vm.State)" -eq 'Running') {
            try {
                $h = (Invoke-VmbDirectorSteps $vm (New-VmbGuestCredential $rec) @(@{ endpoint = '/health'; body = '{}'; timeout_s = 15 }))[0] | ConvertFrom-Json
                $out.director = $h
            } catch { $out.director = [ordered]@{ ok = $false; error = 'unreachable' } }
        }
    } else { $out.state = 'none' }
    New-VmbOk $out
}

function Get-VmbList {
    param($A)
    $consumer = [string]$A.consumer
    $items = @(Get-VmbRecords | Where-Object { $_.state -ne 'destroyed' -and ($consumer -eq '*admin*' -or $_.owner -eq $consumer) } | ForEach-Object {
        $st = 'none'
        if (Get-VmbField $_ 'vmid') { $v = Get-VM -Id $_.vmid -ErrorAction SilentlyContinue; if ($v) { $st = "$($v.State)" } else { $st = 'missing' } }
        [ordered]@{ vm = $_.name; host = $env:COMPUTERNAME.ToLower(); profile = $_.profile; record_state = $_.state; state = $st; addresses = @($_.addresses); lease = $_.request.lease }
    })
    New-VmbOk @{ vms = $items }
}

function Get-VmbSnapshotList {
    param($A)
    $rec = Get-VmbOwnedRecord ([string]$A.name) ([string]$A.consumer)
    $vm = Get-VmbVM $rec (Get-VmbPolicy) -NoGuardCheck
    $items = @(Get-VmbCheckpoints $vm | ForEach-Object {
        [ordered]@{ label = $_.Name; time = $_.CreationTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); parent = "$($_.ParentSnapshotName)"; type = "$($_.SnapshotType)" }
    })
    New-VmbOk @{ vm = $rec.name; snapshots = $items }
}

function Get-VmbConsole {
    param($A)
    $rec = Get-VmbOwnedRecord ([string]$A.name) ([string]$A.consumer)
    if (-not (Get-VmbField $rec 'vmid')) { Stop-Vmb 2 'rejected' 'the VM does not exist yet' }
    New-VmbOk @{ vm = $rec.name; console = (Get-VmbConsoleLine $rec); note = 'basic session only: do not switch to enhanced session (it ends the auto-logon session and the recording goes black)' }
}

# ---- power ----------------------------------------------------------------------------------------------

function Start-VmbVM {
    param($A)
    $rec = Get-VmbOwnedRecord ([string]$A.name) ([string]$A.consumer)
    $pol = Get-VmbPolicy
    Assert-VmbNotFrozen $pol ([string]$A.consumer)
    $lock = Enter-VmbLock
    try {
        $job = Get-VmbActiveJob $rec.id
        if ($job) { Stop-Vmb 3 'busy' "job $($job.id) ($($job.verb)) is running on '$($rec.name)'" }
        $vm = Get-VmbVM $rec $pol
        if ("$($vm.State)" -eq 'Running') { return New-VmbOk @{ vm = $rec.name; state = 'Running'; already = $true } }
        $null = Test-VmbCapacity $pol ([int64]($vm.MemoryStartup / 1MB))
        if (Test-VmbChange "start $($rec.hyperv_name)") { Start-VM -VM $vm }
    } finally { Exit-VmbLock $lock }
    Add-VmbEvent @{ verb = 'start'; vm = $rec.name; consumer = $A.consumer; exit = 0 }
    New-VmbOk @{ vm = $rec.name; state = "$((Get-VM -Id $rec.vmid).State)" }
}

# The jobs (stop, snapshot, restore) start under the lock after the one-job-per-VM check.
function Request-VmbJob {
    param($A, [string]$Verb, $JobArgs, [scriptblock]$Check = { })
    $rec = Get-VmbOwnedRecord ([string]$A.name) ([string]$A.consumer)
    $pol = Get-VmbPolicy
    if ($Verb -ne 'stop') { Assert-VmbNotFrozen $pol ([string]$A.consumer) }
    $lock = Enter-VmbLock
    try {
        $active = Get-VmbActiveJob $rec.id
        if ($active) { Stop-Vmb 3 'busy' "job $($active.id) ($($active.verb)) is running on '$($rec.name)'" }
        $vm = Get-VmbVM $rec $pol
        $early = & $Check $rec $vm
        if ($early) { return $early }
        Assert-VmbNoGuestUse $rec      # a run, copy or director call still working in the guest
        $job = Start-VmbJob $Verb $rec.id $JobArgs ([string]$A.consumer)
    } finally { Exit-VmbLock $lock }
    New-VmbOk @{ vm = $rec.name; job = $job.id; state = 'running' }
}

function Request-VmbStop {
    param($A)
    $force = [bool](Get-VmbField $A 'force' $false)
    Request-VmbJob $A 'stop' ([ordered]@{ force = $force }) {
        param($rec, $vm)
        if ("$($vm.State)" -eq 'Off') { New-VmbOk @{ vm = $rec.name; state = 'Off'; already = $true } }
    }
}

function Invoke-VmbStopJob {
    param($Job)
    $rec = Get-VmbRecord $Job.vm
    $vm = Get-VmbVM $rec (Get-VmbPolicy)
    if ("$($vm.State)" -eq 'Off') { return @{ state = 'Off' } }
    Set-VmbJobStep 'shutdown'
    $j = Stop-VM -VM $vm -Force -AsJob
    $null = Wait-Job $j -Timeout 120
    $state = "$((Get-VM -Id $vm.Id).State)"
    if ($state -ne 'Off' -and $Job.args.force) {
        Set-VmbJobStep 'turn-off'
        Stop-VM -VM $vm -TurnOff -Force
        $state = "$((Get-VM -Id $vm.Id).State)"
    }
    Remove-Job $j -Force -ErrorAction SilentlyContinue
    if ($state -ne 'Off') { Stop-Vmb 1 'failed' "the guest did not shut down within 120 s (state $state); use --force" }
    Add-VmbEvent @{ verb = 'stop'; vm = $rec.name; job = $Job.id; exit = 0 }
    @{ state = $state }
}

# ---- checkpoints ----------------------------------------------------------------------------------------

function Request-VmbSnapshot {
    param($A)
    $label = [string]$A.label; Test-VmbLabel $label
    $replace = [bool](Get-VmbField $A 'replace' $false)
    Request-VmbJob $A 'snapshot' ([ordered]@{ label = $label; replace = $replace }) {
        param($rec, $vm)
        $old = Find-VmbCheckpoint $vm $label
        if ($old -and -not $replace) { Stop-Vmb 2 'label-exists' "checkpoint '$label' exists; use --replace" }
        if ($old) { Assert-VmbLabelChangeable $label ([string]$A.consumer) 'replace' }
        if (-not $old -and @(Get-VmbCheckpoints $vm).Count -ge $script:VmbMaxCheckpoints) { Stop-Vmb 2 'limit' "$($script:VmbMaxCheckpoints) checkpoints already; delete some first" }
        $null
    }
}

# --replace takes the new checkpoint first, then removes the old one and gives the new one the label, so a
# failure keeps the old one.
function Invoke-VmbSnapshotJob {
    param($Job)
    $rec = Get-VmbRecord $Job.vm
    $vm = Get-VmbVM $rec (Get-VmbPolicy)
    $label = [string]$Job.args.label; Test-VmbLabel $label
    $old = Find-VmbCheckpoint $vm $label
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Set-VmbJobStep 'checkpoint'
    if ($old) {
        $tmp = "$label~new"
        Checkpoint-VM -VM $vm -SnapshotName $tmp
        $new = Find-VmbCheckpoint $vm $tmp
        if (-not $new) { Stop-Vmb 1 'failed' 'the new checkpoint did not appear; the old one is kept' }
        Set-VmbJobStep 'replace'
        Remove-VMSnapshot -VMSnapshot $old -Confirm:$false
        Rename-VMSnapshot -VMSnapshot $new -NewName $label
    } else {
        Checkpoint-VM -VM $vm -SnapshotName $label
    }
    $cp = Find-VmbCheckpoint $vm $label
    if (-not $cp) { Stop-Vmb 1 'failed' "checkpoint '$label' is missing after the job" }
    Add-VmbEvent @{ verb = 'snapshot'; vm = $rec.name; job = $Job.id; exit = 0; seconds = [int]$sw.Elapsed.TotalSeconds }
    @{ label = $label; time = $cp.CreationTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); type = "$($cp.SnapshotType)"; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Request-VmbRestore {
    param($A)
    $label = [string]$A.label; Test-VmbLabel $label
    Request-VmbJob $A 'restore' ([ordered]@{ label = $label }) {
        param($rec, $vm)
        $cp = Find-VmbCheckpoint $vm $label
        if (-not $cp) { Stop-Vmb 2 'unknown-label' "no checkpoint '$label'" }
        Assert-VmbRestoreKeepsActivation $rec $cp $label
        $null
    }
}

# Restore, start, and on the lab VM wait until the director answers (docs/design.md 5.1, 13.3).
function Invoke-VmbRestoreJob {
    param($Job)
    $rec = Get-VmbRecord $Job.vm
    $pol = Get-VmbPolicy
    $vm = Get-VmbVM $rec $pol
    $label = [string]$Job.args.label; Test-VmbLabel $label
    $cp = Find-VmbCheckpoint $vm $label
    if (-not $cp) { Stop-Vmb 2 'unknown-label' "no checkpoint '$label'" }
    Assert-VmbRestoreKeepsActivation $rec $cp $label     # again: the record may have changed since the request
    $t = [ordered]@{}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Set-VmbJobStep 'restore'
    Restore-VMSnapshot -VMSnapshot $cp -Confirm:$false
    $t.restore_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Set-VmbJobStep 'start'
    # the restored configuration is the checkpoint's: every ownership and guard check again before it runs
    $vm = Get-VmbVM $rec $pol
    if ("$($vm.State)" -ne 'Running') {
        $null = Test-VmbCapacity $pol ([int64]($vm.MemoryStartup / 1MB))
        Start-VM -VM $vm
    }
    $t.start_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $cred = New-VmbGuestCredential $rec
    Set-VmbJobStep 'guest'
    $null = Wait-VmbGuest $vm $cred 900
    $t.guest_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ((Get-VmbField $rec.request 'director' $false) -eq $true -and @($rec.done_steps) -contains 'director') {
        Set-VmbJobStep 'director'
        $h = Wait-VmbDirector $vm $cred 600
        $t.director_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $t.director = [ordered]@{ version = $h.version; width = $h.width; height = $h.height; scaling = $h.scaling; recording = $h.recording }
    }
    Add-VmbEvent @{ verb = 'restore'; vm = $rec.name; job = $Job.id; exit = 0; seconds = [int]$sw.Elapsed.TotalSeconds }
    $t.label = $label; $t.state = "$((Get-VM -Id $vm.Id).State)"
    $t
}

function Remove-VmbCheckpoint {
    param($A)
    $label = [string]$A.label; Test-VmbLabel $label
    $rec = Get-VmbOwnedRecord ([string]$A.name) ([string]$A.consumer)
    Assert-VmbNotFrozen (Get-VmbPolicy) ([string]$A.consumer)
    $lock = Enter-VmbLock
    try {
        $active = Get-VmbActiveJob $rec.id
        if ($active) { Stop-Vmb 3 'busy' "job $($active.id) ($($active.verb)) is running on '$($rec.name)'" }
        $vm = Get-VmbVM $rec (Get-VmbPolicy)
        $cp = Find-VmbCheckpoint $vm $label
        if (-not $cp) { return New-VmbOk @{ vm = $rec.name; label = $label; already = $true } }
        Assert-VmbLabelChangeable $label ([string]$A.consumer) 'remove'
        if (Test-VmbChange "remove checkpoint '$label' of $($rec.hyperv_name)") { Remove-VMSnapshot -VMSnapshot $cp -Confirm:$false }
    } finally { Exit-VmbLock $lock }
    Add-VmbEvent @{ verb = 'snapshot-rm'; vm = $rec.name; consumer = $A.consumer; exit = 0 }
    New-VmbOk @{ vm = $rec.name; label = $label; removed = $true }
}

# ---- run and copy (Windows guests, over PowerShell Direct as vmbadmin) -------------------------------------

function Get-VmbRunningVM {
    param($A)
    $rec = Get-VmbOwnedRecord ([string]$A.name) ([string]$A.consumer)
    $pol = Get-VmbPolicy
    Assert-VmbNotFrozen $pol ([string]$A.consumer)
    $vm = Get-VmbVM $rec $pol
    if ("$($vm.State)" -ne 'Running') { Stop-Vmb 2 'not-running' "'$($rec.name)' is $($vm.State); start it first" }
    if (@($rec.done_steps) -notcontains 'first-contact') { Stop-Vmb 2 'not-ready' "'$($rec.name)' is still being built" }
    # no guest work while a job (restore, stop, snapshot, the build) runs on this VM, and no job while this call
    # works in the guest: the use handle is taken under the same lock that starts jobs and held until the verb ends
    $lock = Enter-VmbLock
    try {
        $active = Get-VmbActiveJob $rec.id
        if ($active) { Stop-Vmb 3 'busy' "job $($active.id) ($($active.verb)) is running on '$($rec.name)'; wait for it" }
        Enter-VmbGuestUse $rec.id
    } finally { Exit-VmbLock $lock }
    @{ rec = $rec; vm = $vm; cred = (New-VmbGuestCredential $rec) }
}

function Invoke-VmbRun {
    param($A)
    $cmd = [string]$A.command
    if (-not $cmd -or [Text.Encoding]::UTF8.GetByteCount($cmd) -gt 8192) { Stop-Vmb 2 'rejected' 'command: 1 to 8192 bytes' }
    $timeout = [int](Get-VmbField $A 'timeout_s' 300); if ($timeout -lt 1 -or $timeout -gt 3600) { Stop-Vmb 2 'rejected' 'timeout_s: 1..3600' }
    $interactive = [bool](Get-VmbField $A 'interactive' $false)
    $g = Get-VmbRunningVM $A
    $r = Invoke-VmbGuestOnce $g.vm $g.cred $script:VmbGuestRun @($cmd, $timeout, 1048576, $interactive)
    if (Get-VmbField $r 'error') { Stop-Vmb 2 ([string]$r.error) ([string]$r.detail) }
    Add-VmbEvent @{ verb = 'run'; vm = $g.rec.name; consumer = $A.consumer; exit = 0; guest_exit = $r.exit_code; seconds = $r.seconds }
    if ($r.timed_out) {
        $o = New-VmbOk @{ vm = $g.rec.name; exit_code = $null; stdout = $r.stdout; stderr = $r.stderr; timed_out = $true; seconds = $r.seconds }
        $o.ok = $false; $o.exit = 1; $o.error = 'timeout'; $o.hint = "the command ran longer than $timeout s and was stopped"
        return $o
    }
    New-VmbOk @{ vm = $g.rec.name; exit_code = $r.exit_code; stdout = $r.stdout; stderr = $r.stderr; stdout_cut = $r.stdout_cut; stderr_cut = $r.stderr_cut
                 timed_out = $false; seconds = $r.seconds; interactive = $r.interactive }
}

function Test-VmbGuestPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Length -gt 260 -or $Path -match '[\x00-\x1F"*?<>|]' -or $Path -match '(^|\\)\.\.(\\|$)' -or $Path.EndsWith('\')) {
        Stop-Vmb 2 'rejected' 'guest path: an absolute Windows file path (C:\...), at most 260 characters, no wildcards or ..'
    }
}

# Host-side copies are throttled (docs/design.md 6.5): chunks of 4 MiB, at most copy_mbps.
function Copy-VmbChunks {
    param([scriptblock]$Read, [scriptblock]$Write, [long]$Length, [double]$MBps)
    $chunk = 4MB; $off = 0L
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($off -lt $Length -or ($off -eq 0 -and $Length -eq 0)) {
        $n = [int][math]::Min($chunk, $Length - $off)
        $bytes = & $Read $off $n
        & $Write $off $bytes ($off -eq 0)
        $off += $bytes.Length
        if ($Length -eq 0) { break }
        if ($bytes.Length -eq 0) { throw 'the copy stopped short' }
        $ahead = $off / ($MBps * 1MB) - $sw.Elapsed.TotalSeconds
        if ($ahead -gt 0.05) { Start-Sleep -Milliseconds ([int]($ahead * 1000)) }
    }
    $off
}

# copy-to, second half: the file the laptop uploaded into a stage folder goes into the guest.
function Copy-VmbToGuest {
    param($A)
    $guest = [string]$A.guest; Test-VmbGuestPath $guest
    $stage = Resolve-VmbStage ([string]$A.stage)
    $files = @(Get-ChildItem -LiteralPath $stage -File)
    if ($files.Count -ne 1) { Stop-Vmb 1 'failed' 'the stage folder must hold exactly one file' }
    $src = $files[0].FullName
    try {
        $len = $files[0].Length
        if ($len -gt 512MB) { Stop-Vmb 2 'too-large' 'copy_to: 512 MiB per file in v0.R' }
        $sha = Get-VmbFileHash $src
        if ($sha -ne ([string]$A.sha256).ToLower()) { Stop-Vmb 1 'failed' 'SHA-256 mismatch after the upload to the host' }
        $g = Get-VmbRunningVM $A
        $sess = New-VmbGuestSession $g.vm $g.cred
        try {
            $info = Invoke-Command -Session $sess -ScriptBlock $script:VmbGuestFileInfo -ArgumentList $guest
            if ($info.exists) {
                if ($info.sha256 -eq $sha) { return New-VmbOk @{ vm = $g.rec.name; guest = $guest; bytes = $len; sha256 = $sha; already = $true } }
                if (-not [bool](Get-VmbField $A 'overwrite' $false)) { Stop-Vmb 2 'exists' "the guest file exists with other content; use --overwrite" }
            }
            if ($info.dir) { Stop-Vmb 2 'rejected' 'the guest path is a folder; give the full file path' }
            $copied = $false
            try {
                $fs = [IO.File]::OpenRead($src)
                try {
                    $read = { param($off, $n) $b = New-Object byte[] $n; [void]$fs.Seek($off, 'Begin'); $got = $fs.Read($b, 0, $n); if ($got -lt $n) { $c = New-Object byte[] $got; [Array]::Copy($b, $c, $got); $b = $c }; , $b }
                    $write = { param($off, $bytes, $first) $null = Invoke-Command -Session $sess -ScriptBlock $script:VmbGuestWriteChunk -ArgumentList $guest, $off, $bytes, $first }
                    $null = Copy-VmbChunks $read $write $len ([double]$((Get-VmbPolicy).copy_mbps))
                } finally { $fs.Dispose() }
                $after = Invoke-Command -Session $sess -ScriptBlock $script:VmbGuestFileInfo -ArgumentList $guest
                if ($after.sha256 -ne $sha) { Stop-Vmb 1 'failed' 'SHA-256 mismatch in the guest after the copy; the partial file was removed' }
                $copied = $true
            } finally {
                # a half-written or wrong file must not look like a finished copy to the next step
                if (-not $copied) { try { $null = Invoke-Command -Session $sess -ScriptBlock $script:VmbGuestRemoveFile -ArgumentList $guest } catch { } }
            }
        } finally { Remove-PSSession $sess }
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    Add-VmbEvent @{ verb = 'copy-to'; vm = $g.rec.name; consumer = $A.consumer; exit = 0; bytes = $len }
    New-VmbOk @{ vm = $g.rec.name; guest = $guest; bytes = $len; sha256 = $sha }
}

# copy-from, first half: guest file into a new stage folder; the laptop then downloads it and removes the stage.
function Copy-VmbFromGuest {
    param($A)
    $guest = [string]$A.guest; Test-VmbGuestPath $guest
    $g = Get-VmbRunningVM $A
    $sess = New-VmbGuestSession $g.vm $g.cred
    try {
        $info = Invoke-Command -Session $sess -ScriptBlock $script:VmbGuestFileInfo -ArgumentList $guest
        if (-not $info.exists) { Stop-Vmb 2 'missing' "no such file in the guest: $guest" }
        if ($info.bytes -gt 8GB) { Stop-Vmb 2 'too-large' 'copy_from: 8 GiB at most' }
        $id = New-VmbId
        $stage = Get-VmbPath "stage\$id"
        [void][IO.Directory]::CreateDirectory($stage)
        $dest = Join-Path $stage ([IO.Path]::GetFileName($guest) -replace '[^A-Za-z0-9._-]', '_')
        $fs = [IO.File]::Open($dest, 'Create', 'Write', 'None')
        try {
            $read = { param($off, $n) , (Invoke-Command -Session $sess -ScriptBlock $script:VmbGuestReadChunk -ArgumentList $guest, $off, $n) }
            $write = { param($off, $bytes, $first) $fs.Write($bytes, 0, $bytes.Length) }
            $n = Copy-VmbChunks $read $write ([long]$info.bytes) ([double]$((Get-VmbPolicy).copy_mbps))
        } catch {
            # a copy that fails half way leaves nothing behind (recordings are GBs)
            $fs.Dispose(); Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue; throw
        } finally { $fs.Dispose() }
        $sha = Get-VmbFileHash $dest
        if ($sha -ne $info.sha256) { Remove-Item -LiteralPath $stage -Recurse -Force; Stop-Vmb 1 'failed' 'SHA-256 mismatch on the host after the copy (the file may have changed in the guest)' }
    } finally { Remove-PSSession $sess }
    Add-VmbEvent @{ verb = 'copy-from'; vm = $g.rec.name; consumer = $A.consumer; exit = 0; bytes = $n }
    New-VmbOk @{ vm = $g.rec.name; guest = $guest; stage = $stage; file = $dest; bytes = $n; sha256 = $sha }
}

# ---- the director relay (docs/design.md 10.2) -------------------------------------------------------------

function Invoke-VmbDirectorSteps {
    param($VM, [pscredential]$Credential, $Steps)
    $json = ConvertTo-Json -InputObject @($Steps) -Depth 4 -Compress
    $limit = 60
    foreach ($s in @($Steps)) { $limit += [int]$s.timeout_s + 5 }
    $sess = New-VmbGuestSession $VM $Credential
    try {
        $r = Invoke-Command -Session $sess -ScriptBlock $script:VmbGuestDirectorRelay -ArgumentList $json -ErrorAction Stop
    } finally { Remove-PSSession $sess }
    , @($r)
}

function Wait-VmbDirector {
    param($VM, [pscredential]$Credential, [int]$TimeoutS = 300)
    $t0 = [DateTime]::UtcNow
    $until = $t0.AddSeconds($TimeoutS)
    $last = ''; $restarted = $false
    while ([DateTime]::UtcNow -lt $until) {
        try {
            $a = (Invoke-VmbDirectorSteps $VM $Credential @(@{ endpoint = '/health'; body = '{}'; timeout_s = 10 }))[0] | ConvertFrom-Json
            if ($a.ok) { return $a }
            $last = "$($a.error)"
        } catch { $last = 'no session' }
        # silent for a minute: not listening (no-director) or listening but not answering (relay-timeout); restart
        # it once
        if (-not $restarted -and $last -in 'no-director', 'relay-timeout' -and ([DateTime]::UtcNow - $t0).TotalSeconds -ge 60) {
            try {
                $on = Invoke-VmbGuest $VM $Credential $script:VmbGuestDirectorRestart
                Write-VmbLog "the director did not answer for a minute; its task restarted (student signed in: $on)"
                $restarted = $true
            } catch { Write-VmbLog "restarting the director's task failed: $($_.Exception.Message)" }
        }
        Start-Sleep -Seconds 5
    }
    Stop-Vmb 1 'timeout' "the director did not answer within $TimeoutS s (last: $last)"
}

function Invoke-VmbDirector {
    param($A)
    $steps = @()
    foreach ($s in @($A.steps)) {
        $action = [string]$s.action
        if (-not $script:VmbDirectorEndpoints.ContainsKey($action)) { Stop-Vmb 2 'rejected' "director action '$action' is unknown" }
        $body = [string]$s.body
        if ([Text.Encoding]::UTF8.GetByteCount($body) -gt 65536) { Stop-Vmb 2 'rejected' 'a director payload is at most 64 KiB' }
        $to = [int]$s.timeout_s
        if ($to -lt 5 -or $to -gt 900) { Stop-Vmb 2 'rejected' 'step timeout_s: 5..900' }
        $steps += [ordered]@{ endpoint = $script:VmbDirectorEndpoints[$action]; body = $body; timeout_s = $to }
    }
    if (-not $steps.Count -or $steps.Count -gt 50) { Stop-Vmb 2 'rejected' 'director: 1 to 50 steps per call' }
    $g = Get-VmbRunningVM $A
    if (@($g.rec.done_steps) -notcontains 'director') { Stop-Vmb 2 'no-director' "'$($g.rec.name)' has no director yet" }
    $raw = Invoke-VmbDirectorSteps $g.vm $g.cred $steps
    New-VmbOk @{ vm = $g.rec.name; answers = @($raw) }
}
