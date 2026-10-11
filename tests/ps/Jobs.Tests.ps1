# Jobs.Tests.ps1 - VmbJobs.ps1 (docs/design.md 5.3): liveness, the active job of a VM, one job per VM.
# Pester 3.4, Windows PowerShell 5.1, ASCII only. Scheduled tasks and processes are the fakes in VmbTestHelpers.ps1.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

function Set-VmbTaskState {
    param($Job, [string]$State)
    $global:VmbFake.Tasks[[string]$Job.task] = [pscustomobject]@{ TaskName = [string]$Job.task; TaskPath = '\vm-broker\'; State = $State }
}

# A process in the fake table, and the pid_start string Invoke-VmbJob.ps1 would have recorded for it.
function Add-VmbFakeProcess {
    param([int]$ProcId, [DateTime]$Start)
    $global:VmbFake.Procs[$ProcId] = [pscustomobject]@{ Id = $ProcId; StartTime = $Start }
    $Start.ToUniversalTime().Ticks.ToString()
}

function Get-VmbOpArgs { param([hashtable]$More = @{}) $h = @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs' }; foreach ($k in $More.Keys) { $h[$k] = $More[$k] }; ConvertTo-VmbArgs $h }

try {
Describe 'Update-VmbJobLiveness: a job whose task and process are gone is lost' {
    It 'turns a running job with no running task and no process into lost, with its step' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running' -Step 'checkpoint' -ProcId 4242 -PidStart '638000000000000000'
        Set-VmbTaskState $j 'Ready'
        $out = Update-VmbJobLiveness $j
        $out.state | Should BeExactly 'lost'
        $out.exit | Should Be 1
        $out.error | Should BeExactly 'lost'
        $out.hint | Should Match '\(step: checkpoint\)'
        $out.ended | Should Not BeNullOrEmpty
        $disk = Get-VmbJobRecord $j.id
        $disk.state | Should BeExactly 'lost'
        $disk.step | Should BeExactly 'checkpoint'
        $ev = @([IO.File]::ReadAllLines((Get-VmbPath 'state\events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json })
        @($ev | Where-Object { $_.job -eq $j.id -and $_.state -eq 'lost' -and $_.step -eq 'checkpoint' }).Count | Should Be 1
    }

    It 'turns it into lost when the task is gone altogether' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running' -Step 'restore'
        (Update-VmbJobLiveness $j).state | Should BeExactly 'lost'
    }

    It 'turns it into lost when its pid was reused (same pid, other start time)' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = Add-VmbFakeProcess 4242 (Get-Date).AddMinutes(-1)
        $then = (Get-Date).AddHours(-3).ToUniversalTime().Ticks.ToString()
        $j = New-VmbTestJob -Vm $t.Id -State 'running' -Step 'guest' -ProcId 4242 -PidStart $then
        Set-VmbTaskState $j 'Ready'
        $out = Update-VmbJobLiveness $j
        $out.state | Should BeExactly 'lost'
        $out.hint | Should Match 'step: guest'
        ((Get-VmbCalls 'Get-Process')[0].Params['Id']) | Should Be 4242
    }

    It 'keeps a running job whose process is alive (same pid, same start time)' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $ticks = Add-VmbFakeProcess 4242 (Get-Date).AddMinutes(-30)
        $j = New-VmbTestJob -Vm $t.Id -State 'running' -ProcId 4242 -PidStart $ticks
        Set-VmbTaskState $j 'Ready'
        $before = [IO.File]::ReadAllText((Get-VmbPath "jobs\$($j.id).json"))
        (Update-VmbJobLiveness $j).state | Should BeExactly 'running'
        [IO.File]::ReadAllText((Get-VmbPath "jobs\$($j.id).json")) | Should BeExactly $before
    }

    It 'keeps a running job whose task is Running' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running'
        Set-VmbTaskState $j 'Running'
        (Update-VmbJobLiveness $j).state | Should BeExactly 'running'
        (Get-VmbCalls 'Get-Process').Count | Should Be 0
    }

    It 'keeps a queued job younger than 120 s, task not started yet' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'queued' -Step '' -AgeS 30
        Set-VmbTaskState $j 'Ready'
        (Update-VmbJobLiveness $j).state | Should BeExactly 'queued'
        (Get-VmbJobRecord $j.id).state | Should BeExactly 'queued'
    }

    It 'turns a queued job older than 120 s into lost' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'queued' -Step '' -AgeS 300
        Set-VmbTaskState $j 'Ready'
        (Update-VmbJobLiveness $j).state | Should BeExactly 'lost'
    }

    It 'leaves a <State> job alone' -TestCases @(@{ State = 'done' }, @{ State = 'failed' }, @{ State = 'lost' }, @{ State = 'cancelled' }) {
        param($State)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State $State -AgeS 9000
        $before = [IO.File]::ReadAllText((Get-VmbPath "jobs\$($j.id).json"))
        (Update-VmbJobLiveness $j).state | Should BeExactly $State
        [IO.File]::ReadAllText((Get-VmbPath "jobs\$($j.id).json")) | Should BeExactly $before
        (Get-VmbCalls 'Get-ScheduledTask').Count | Should Be 0
    }

    It 'returns the finished job when it ended while being checked' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running'
        $disk = Get-VmbJobRecord $j.id
        $disk.state = 'done'
        Save-VmbJobRecord $disk
        $out = Update-VmbJobLiveness $j
        $out.state | Should BeExactly 'done'
        (Get-VmbJobRecord $j.id).state | Should BeExactly 'done'
    }
}

Describe 'Get-VmbActiveJob: the one non-final job of a VM' {
    It 'finds only the non-final job of that VM' {
        $null = New-VmbTestRoot
        $a = New-VmbTestVM -Name 'lab-p1'
        $b = New-VmbTestVM -Name 'lab-p2'
        $null = New-VmbTestJob -Vm $a.Id -State 'done'
        $ja = New-VmbTestJob -Vm $a.Id -State 'running'
        Set-VmbTaskState $ja 'Running'
        $null = New-VmbTestJob -Vm $a.Id -State 'cancelled'
        $jb = New-VmbTestJob -Vm $b.Id -State 'running'
        Set-VmbTaskState $jb 'Running'
        (Get-VmbActiveJob $a.Id).id | Should BeExactly $ja.id
        (Get-VmbActiveJob $b.Id).id | Should BeExactly $jb.id
        Get-VmbActiveJob (New-VmbId) | Should BeNullOrEmpty
    }

    It 'returns nothing when every job of the VM is final' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        foreach ($s in 'done', 'failed', 'lost', 'cancelled') { $null = New-VmbTestJob -Vm $t.Id -State $s }
        Get-VmbActiveJob $t.Id | Should BeNullOrEmpty
    }

    It 'returns nothing for a job that turns out lost, and marks it lost' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running'
        Get-VmbActiveJob $t.Id | Should BeNullOrEmpty
        (Get-VmbJobRecord $j.id).state | Should BeExactly 'lost'
    }
}

Describe 'One job per VM' {
    It 'refuses Request-VmbJob with exit 3 while another job is active' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running'
        Set-VmbTaskState $j 'Running'
        $r = Get-VmbRefusal { Request-VmbJob (Get-VmbOpArgs) 'stop' ([ordered]@{ force = $false }) }
        $r.exit | Should Be 3
        $r.error | Should BeExactly 'busy'
        $r.hint | Should Match $j.id
        @(Get-ChildItem -LiteralPath (Get-VmbPath 'jobs') -Filter '*.json').Count | Should Be 1
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
        Test-VmbLockHeld | Should Be $false
    }

    It 'refuses <Verb> with exit 3 while another job is active' -TestCases @(
        @{ Verb = 'snapshot'; Call = { Request-VmbSnapshot (Get-VmbOpArgs @{ label = 'ch1' }) } }
        @{ Verb = 'restore'; Call = { Request-VmbRestore (Get-VmbOpArgs @{ label = 'ch1' }) } }
        @{ Verb = 'stop'; Call = { Request-VmbStop (Get-VmbOpArgs) } }
        @{ Verb = 'start'; Call = { Start-VmbVM (Get-VmbOpArgs) } }
        @{ Verb = 'snapshot-rm'; Call = { Remove-VmbCheckpoint (Get-VmbOpArgs @{ label = 'ch1' }) } }
    ) {
        param($Verb, $Call)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -State 'Off'
        $j = New-VmbTestJob -Vm $t.Id -State 'queued' -AgeS 5
        Set-VmbTaskState $j 'Ready'
        $r = Get-VmbRefusal $Call
        $r.exit | Should Be 3
        $r.error | Should BeExactly 'busy'
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
        (Get-VmbCalls 'Start-VM').Count | Should Be 0
        (Get-VmbCalls 'Remove-VMSnapshot').Count | Should Be 0
    }

    It 'starts the job once the other job is final, with the label as data' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = New-VmbTestJob -Vm $t.Id -State 'done'
        $r = Request-VmbSnapshot (Get-VmbOpArgs @{ label = 'ch1.intro_2' })
        $r.ok | Should Be $true
        $job = Get-VmbJobRecord $r.job
        $job.verb | Should BeExactly 'snapshot'
        $job.state | Should BeExactly 'queued'
        $job.args.label | Should BeExactly 'ch1.intro_2'
        $job.args.replace | Should Be $false
        [string](Get-VmbCalls 'New-ScheduledTaskAction')[0].Params['Argument'] | Should Not Match 'ch1'
        (Get-VmbCalls 'Register-ScheduledTask')[0].LockHeld | Should Be $true
    }
}
Describe 'Stop-VmbJob (job-cancel): never kills a process that is not the job''s' {
    It 'stops the task, ends the job''s own process and marks the job cancelled' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $ticks = Add-VmbFakeProcess 4242 (Get-Date).AddMinutes(-5)
        $j = New-VmbTestJob -Vm $t.Id -State 'running' -Step 'checkpoint' -ProcId 4242 -PidStart $ticks
        Set-VmbTaskState $j 'Running'
        $r = Stop-VmbJob (ConvertTo-VmbArgs @{ job = $j.id })
        $r.state | Should BeExactly 'cancelled'
        $disk = Get-VmbJobRecord $j.id
        $disk.state | Should BeExactly 'cancelled'
        $disk.hint | Should Match 'at step checkpoint'
        (Get-VmbCalls 'Stop-ScheduledTask')[0].Params['TaskName'] | Should BeExactly $j.task
        $kill = Get-VmbCalls 'Stop-Process'
        $kill.Count | Should Be 1
        $kill[0].Params['Id'] | Should Be 4242
        (Get-VmbCalls 'Unregister-ScheduledTask')[0].Params['TaskName'] | Should BeExactly $j.task
    }

    It 'does not kill a process that reuses the job''s pid' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = Add-VmbFakeProcess 4242 (Get-Date).AddMinutes(-1)
        $j = New-VmbTestJob -Vm $t.Id -State 'running' -ProcId 4242 -PidStart ((Get-Date).AddHours(-2).ToUniversalTime().Ticks.ToString())
        Set-VmbTaskState $j 'Running'
        (Stop-VmbJob (ConvertTo-VmbArgs @{ job = $j.id })).state | Should BeExactly 'cancelled'
        (Get-VmbCalls 'Stop-Process').Count | Should Be 0
    }

    It 'leaves a finished job as it is' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'done'
        (Stop-VmbJob (ConvertTo-VmbArgs @{ job = $j.id })).state | Should BeExactly 'done'
        (Get-VmbCalls 'Stop-ScheduledTask').Count | Should Be 0
        (Get-VmbJobRecord $j.id).state | Should BeExactly 'done'
    }
}

Describe 'Get-VmbJobStatus: a job is shown to its consumer and to *admin* only' {
    It 'refuses another consumer, and shows the owner the last 20 log lines' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running'
        Set-VmbTaskState $j 'Running'
        [IO.File]::WriteAllLines((Get-VmbPath "jobs\$($j.id).log"), [string[]](1..25 | ForEach-Object { "line $_" }))
        $r = Get-VmbRefusal { Get-VmbJobStatus (ConvertTo-VmbArgs @{ job = $j.id; consumer = 'other-project' }) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'not-yours'
        $s = Get-VmbJobStatus (ConvertTo-VmbArgs @{ job = $j.id; consumer = 'cs101-walkthroughs' })
        $s.state | Should BeExactly 'running'
        $s.vm | Should BeExactly 'lab-p1'
        @($s.log).Count | Should Be 20
        @($s.log)[0] | Should BeExactly 'line 6'
        @($s.log)[19] | Should BeExactly 'line 25'
        (Get-VmbJobStatus (ConvertTo-VmbArgs @{ job = $j.id; consumer = '*admin*' })).ok | Should Be $true
    }

    It 'refuses a job id that is not 32 hex digits' {
        $null = New-VmbTestRoot
        (Get-VmbRefusal { Get-VmbJobStatus (ConvertTo-VmbArgs @{ job = '..\..\state\vms\x'; consumer = '*admin*' }) }).exit | Should Be 2
    }
}

Describe 'The job bodies: snapshot, stop and restore against the fake Hyper-V' {
    # Runs one job body the way Invoke-VmbJob.ps1 does: with $script:VmbJob set for the steps and the log.
    function Invoke-VmbTestJobBody {
        param([scriptblock]$Body, $Job)
        $script:VmbJob = $Job
        try { & $Body $Job } finally { $script:VmbJob = $null }
    }

    It 'snapshot --replace takes the new checkpoint first, then removes the old one, then moves the label' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $old = Add-VmbTestCheckpoint $t.VM 'ch1' ([DateTime]::Now.AddHours(-1))
        $j = New-VmbTestJob -Vm $t.Id -Verb 'snapshot' -JobArgs @{ label = 'ch1'; replace = $true }
        $global:VmbCalls.Clear()
        $r = Invoke-VmbTestJobBody { param($x) Invoke-VmbSnapshotJob $x } $j
        $r.label | Should BeExactly 'ch1'
        $order = @($global:VmbCalls | Where-Object { $_.Name -in 'Checkpoint-VM', 'Remove-VMSnapshot', 'Rename-VMSnapshot' } | ForEach-Object { $_.Name })
        ($order -join ',') | Should BeExactly 'Checkpoint-VM,Remove-VMSnapshot,Rename-VMSnapshot'
        (Get-VmbCalls 'Checkpoint-VM')[0].Params['SnapshotName'] | Should BeExactly 'ch1~new'
        (Get-VmbCalls 'Remove-VMSnapshot')[0].Params['VMSnapshot'].Id | Should Be $old.Id
        $now = @(Get-VmbFakeItems $global:VmbFake.Snapshots "$($t.VM.Id)")
        $now.Count | Should Be 1
        $now[0].Name | Should BeExactly 'ch1'
        ($now[0].Id -ne $old.Id) | Should Be $true
        (Get-VmbJobRecord $j.id).step | Should BeExactly 'replace'
    }

    It 'snapshot --replace keeps the old checkpoint when the new one fails' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $old = Add-VmbTestCheckpoint $t.VM 'ch1'
        $j = New-VmbTestJob -Vm $t.Id -Verb 'snapshot' -JobArgs @{ label = 'ch1'; replace = $true }
        $global:VmbFake.CheckpointThrows = 'not enough disk space for the checkpoint'
        { Invoke-VmbTestJobBody { param($x) Invoke-VmbSnapshotJob $x } $j } | Should Throw 'not enough disk space'
        (Get-VmbCalls 'Remove-VMSnapshot').Count | Should Be 0
        $now = @(Get-VmbFakeItems $global:VmbFake.Snapshots "$($t.VM.Id)")
        $now.Count | Should Be 1
        $now[0].Id | Should Be $old.Id
    }

    It 'stop shuts the guest down' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -Verb 'stop' -JobArgs @{ force = $false }
        $r = Invoke-VmbTestJobBody { param($x) Invoke-VmbStopJob $x } $j
        $r.state | Should BeExactly 'Off'
        (Get-VmbCalls 'Stop-VM')[0].Params.ContainsKey('AsJob') | Should Be $true
        @((Get-VmbCalls 'Stop-VM') | Where-Object { $_.Params.ContainsKey('TurnOff') }).Count | Should Be 0
    }

    It 'stop turns the VM off after the shutdown timeout only with --force' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $global:VmbFake.GuestIgnoresShutdown = $true
        $j = New-VmbTestJob -Vm $t.Id -Verb 'stop' -JobArgs @{ force = $false }
        $r = $null
        try { $null = Invoke-VmbTestJobBody { param($x) Invoke-VmbStopJob $x } $j } catch { $r = Get-VmbErrorInfo $_ }
        $r.exit | Should Be 1
        $r.hint | Should Match 'use --force'
        @((Get-VmbCalls 'Stop-VM') | Where-Object { $_.Params.ContainsKey('TurnOff') }).Count | Should Be 0
        $t.VM.State | Should BeExactly 'Running'
        $jf = New-VmbTestJob -Vm $t.Id -Verb 'stop' -JobArgs @{ force = $true }
        (Invoke-VmbTestJobBody { param($x) Invoke-VmbStopJob $x } $jf).state | Should BeExactly 'Off'
        @((Get-VmbCalls 'Stop-VM') | Where-Object { $_.Params.ContainsKey('TurnOff') }).Count | Should Be 1
    }

    It 'restore brings back the labelled checkpoint, starts the VM and waits for the guest and the director' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = Add-VmbTestCheckpoint $t.VM 'ch0' ([DateTime]::Now.AddHours(-2))
        $null = Add-VmbTestCheckpoint $t.VM 'ch1' ([DateTime]::Now.AddHours(-1))
        $global:VmbFake.Guest = { param($c)
            if ($c.Params.ContainsKey('Session')) { , @('{"ok":true,"version":"0.r","width":1920,"height":1080,"scaling":100,"recording":false}') } else { $true }
        }
        $j = New-VmbTestJob -Vm $t.Id -Verb 'restore' -JobArgs @{ label = 'ch1' }
        $r = Invoke-VmbTestJobBody { param($x) Invoke-VmbRestoreJob $x } $j
        (Get-VmbCalls 'Restore-VMSnapshot')[0].Params['VMSnapshot'].Name | Should BeExactly 'ch1'
        (Get-VmbCalls 'Start-VM').Count | Should Be 1
        $r.label | Should BeExactly 'ch1'
        $r.state | Should BeExactly 'Running'
        $r.director.width | Should Be 1920
        $r.director.scaling | Should Be 100
        (Get-VmbJobRecord $j.id).step | Should BeExactly 'director'
    }

    It 'restore does not start the VM when the host is short of memory' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = Add-VmbTestCheckpoint $t.VM 'ch1'
        $global:VmbFake.FreeKB = [int64](6144 + 3072 - 1) * 1024
        $j = New-VmbTestJob -Vm $t.Id -Verb 'restore' -JobArgs @{ label = 'ch1' }
        $r = $null
        try { $null = Invoke-VmbTestJobBody { param($x) Invoke-VmbRestoreJob $x } $j } catch { $r = Get-VmbErrorInfo $_ }
        $r.exit | Should Be 6
        (Get-VmbCalls 'Restore-VMSnapshot').Count | Should Be 1
        (Get-VmbCalls 'Start-VM').Count | Should Be 0
    }
}

Describe 'Checkpoints that keep the activation: golden is protected, older checkpoints are not restored' {
    function Set-VmbTestActivation {
        param($T, [DateTime]$AtUtc, [string]$State = 'activated')
        $rec = Get-VmbRecord $T.Id
        $rec.activation = [ordered]@{ state = $State; at = $AtUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); channel = 'Volume:MAK'; error = $null }
        Save-VmbRecord $rec
    }

    It 'refuses a consumer snapshot-rm and snapshot --replace of golden; the admin may remove it' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = Add-VmbTestCheckpoint $t.VM 'golden'
        $r = Get-VmbRefusal { Remove-VmbCheckpoint (Get-VmbOpArgs @{ label = 'golden' }) }
        ($r.exit, $r.error) -join ',' | Should BeExactly '2,protected'
        $r = Get-VmbRefusal { Request-VmbSnapshot (Get-VmbOpArgs @{ label = 'golden'; replace = $true }) }
        ($r.exit, $r.error) -join ',' | Should BeExactly '2,protected'
        (Get-VmbCalls 'Remove-VMSnapshot').Count | Should Be 0
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
        (Remove-VmbCheckpoint (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = '*admin*'; label = 'golden' })).removed | Should Be $true
        (Get-VmbCalls 'Remove-VMSnapshot').Count | Should Be 1
    }

    It 'takes a first golden checkpoint for the consumer (only removing or replacing it is protected)' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        (Request-VmbSnapshot (Get-VmbOpArgs @{ label = 'golden' })).ok | Should Be $true
    }

    It 'refuses to restore a checkpoint from before the activation (<State>), and restores a later one' -TestCases @(
        @{ State = 'activated' }, @{ State = 'activating' }, @{ State = 'failed' }) {
        param($State)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = Add-VmbTestCheckpoint $t.VM 'smoke-start' ([DateTime]::Now.AddHours(-2))
        $null = Add-VmbTestCheckpoint $t.VM 'golden' ([DateTime]::Now.AddMinutes(-30))
        Set-VmbTestActivation $t ([DateTime]::UtcNow.AddHours(-1)) $State
        $r = Get-VmbRefusal { Request-VmbRestore (Get-VmbOpArgs @{ label = 'smoke-start' }) }
        ($r.exit, $r.error) -join ',' | Should BeExactly '2,before-activation'
        $r.hint | Should Match 'undo the activation'
        (Request-VmbRestore (Get-VmbOpArgs @{ label = 'golden' })).ok | Should Be $true
    }

    It 'checks again in the restore job: an activation after the request still stops an older checkpoint' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = Add-VmbTestCheckpoint $t.VM 'ch1' ([DateTime]::Now.AddHours(-2))
        $j = New-VmbTestJob -Vm $t.Id -Verb 'restore' -JobArgs @{ label = 'ch1' }
        Set-VmbTestActivation $t ([DateTime]::UtcNow.AddHours(-1))
        $script:VmbJob = $j
        try { $r = Get-VmbRefusal { Invoke-VmbRestoreJob $j } } finally { $script:VmbJob = $null }
        $r.error | Should BeExactly 'before-activation'
        (Get-VmbCalls 'Restore-VMSnapshot').Count | Should Be 0
    }

    It 'run and director refuse with exit 3 while a job (here a restore) runs on the VM, and touch no guest' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running' -Verb 'restore'
        $global:VmbFake.Tasks[[string]$j.task] = [pscustomobject]@{ TaskName = [string]$j.task; State = 'Running' }
        $r = Get-VmbRefusal { Invoke-VmbRun (Get-VmbOpArgs @{ command = 'Get-Date' }) }
        ($r.exit, $r.error) -join ',' | Should BeExactly '3,busy'
        $r = Get-VmbRefusal { Invoke-VmbDirector (Get-VmbOpArgs @{ steps = @([ordered]@{ action = 'health'; body = '{}'; timeout_s = 20 }) }) }
        ($r.exit, $r.error) -join ',' | Should BeExactly '3,busy'
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
        (Get-VmbCalls 'New-PSSession').Count | Should Be 0
    }

    It 'a frozen broker refuses the changing verbs (frozen) but still stops a VM, and never refuses the admin' {
        $pol = Get-VmbTestPolicy
        $pol.frozen = $true
        $null = New-VmbTestRoot -Policy $pol
        $t = New-VmbTestVM
        $null = Add-VmbTestCheckpoint $t.VM 'ch1'
        foreach ($call in { Request-VmbSnapshot (Get-VmbOpArgs @{ label = 'ch2' }) }, { Request-VmbRestore (Get-VmbOpArgs @{ label = 'ch1' }) },
                          { Remove-VmbCheckpoint (Get-VmbOpArgs @{ label = 'ch1' }) }, { Invoke-VmbRun (Get-VmbOpArgs @{ command = 'Get-Date' }) },
                          { Start-VmbVM (Get-VmbOpArgs) }) {
            $r = Get-VmbRefusal $call
            ($r.exit, $r.error) -join ',' | Should BeExactly '2,frozen'
        }
        (Get-VmbCalls 'Remove-VMSnapshot').Count | Should Be 0
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
        (Remove-VmbCheckpoint (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = '*admin*'; label = 'ch1' })).removed | Should Be $true
        (Request-VmbStop (Get-VmbOpArgs)).ok | Should Be $true      # stop frees memory: allowed while frozen
    }

    It 'restores any checkpoint on a VM that was never activated' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -ActivationState 'gvlk-proof'
        $null = Add-VmbTestCheckpoint $t.VM 'smoke-start' ([DateTime]::Now.AddHours(-2))
        (Request-VmbRestore (Get-VmbOpArgs @{ label = 'smoke-start' })).ok | Should Be $true
    }
}

Describe 'Job records: a reader and the writer never refuse each other' {
    It 'reads a record while another handle holds it open, and the writer replaces it meanwhile' {
        $null = New-VmbTestRoot
        $p = Get-VmbPath 'jobs\abc.json'
        Write-VmbJson $p @{ state = 'running'; step = 'restore' }
        # a reader that holds the file as Read-VmbJson opens it (read, write and delete shared)
        $h = [IO.File]::Open($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            Write-VmbJson $p @{ state = 'done'; step = 'director' }       # File.Replace while the reader holds it
            (Read-VmbJson $p).state | Should BeExactly 'done'
        } finally { $h.Dispose() }
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $p) -Filter '.tmp-*').Count | Should Be 0
    }
}

Describe 'Grok review fixes (2026-10-11): policy checks, guest use, masked results, every NIC guarded' {
    It 'set-policy refuses a policy with weakened caps: <Case>' -TestCases @(
        @{ Case = 'no disk cap'; Path = 'disk_iops_max'; Value = 0; Want = 'disk_iops_max' }
        @{ Case = 'no CPU limit'; Path = 'cpu.limit'; Value = 100; Want = 'cpu.limit' }
        @{ Case = 'production CPU weight'; Path = 'cpu.weight'; Value = 100; Want = 'cpu.weight' }
        @{ Case = 'a production memory priority'; Path = 'memory_priority'; Value = 80; Want = 'memory_priority' }
        @{ Case = 'the WAN switch'; Path = 'lan_switch'; Value = 'WAN'; Want = 'lan_switch' }
        @{ Case = 'another firewall VM'; Path = 'firewall_vm'; Value = 'docker01'; Want = 'firewall_vm' }) {
        param($Case, $Path, $Value, $Want)
        $null = New-VmbTestRoot
        $before = [IO.File]::ReadAllText((Get-VmbPath 'policy.json'))
        $pol = Get-VmbTestPolicy
        if ($Path -eq 'cpu.limit') { $pol.cpu.limit = $Value } elseif ($Path -eq 'cpu.weight') { $pol.cpu.weight = $Value } else { $pol.$Path = $Value }
        $r = Get-VmbRefusal { Set-VmbPolicyFile (ConvertTo-VmbArgs @{ policy = $pol }) }
        $r.exit | Should Be 2
        $r.hint | Should Match $Want
        [IO.File]::ReadAllText((Get-VmbPath 'policy.json')) | Should BeExactly $before
    }

    It 'a hand-edited policy.json with no disk cap fails closed on every verb (exit 255)' {
        $pol = Get-VmbTestPolicy
        $pol.disk_iops_max = 0
        $null = New-VmbTestRoot -Policy $pol
        $null = New-VmbTestVM
        $r = Get-VmbRefusal { Request-VmbSnapshot (Get-VmbOpArgs @{ label = 'ch1' }) }
        ($r.exit, $r.error) -join ',' | Should BeExactly '255,bad-policy'
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
    }

    It 'a job cannot start while a run, copy or director call works in the guest (exit 3), and can once it ends' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        Enter-VmbGuestUse $t.Id        # as Get-VmbRunningVM does for a guest call
        $r = Get-VmbRefusal { Request-VmbSnapshot (Get-VmbOpArgs @{ label = 'ch1' }) }
        ($r.exit, $r.error) -join ',' | Should BeExactly '3,busy'
        $r.hint | Should Match 'in progress'
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
        Exit-VmbGuestUse               # as Vmb.ps1 does when the verb ends
        (Request-VmbSnapshot (Get-VmbOpArgs @{ label = 'ch1' })).ok | Should Be $true
    }

    It 'masks every known secret in the answer, except for the password verb' {
        $null = New-VmbTestRoot
        [void]$script:VmbSecretValues.Add('Kq7#vT2=pX9@mL4.wR6_zB3%')
        $masked = Write-VmbResult ([ordered]@{ ok = $true; stdout = 'the guest printed Kq7#vT2=pX9@mL4.wR6_zB3% here' })
        $masked | Should Match 'printed \*\*\* here'
        $masked | Should Not Match 'Kq7#'
        (Write-VmbResult ([ordered]@{ ok = $true; password = 'Kq7#vT2=pX9@mL4.wR6_zB3%' }) -Unmasked) | Should Match 'Kq7#vT2'
    }

    It 'flags a disconnected NIC without its guards, and a second NIC on another switch' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $k = "$($t.VM.Id)"
        $global:VmbFake.Nics[$k] = @($global:VmbFake.Nics[$k]) + [pscustomobject]@{ Name = 'spare'; SwitchName = ''; DhcpGuard = 'Off'; RouterGuard = 'Off'; MacAddressSpoofing = 'On'; IPAddresses = @(); MacAddress = '' }
        $bad = @(Test-VmbGuards $t.VM (Get-VmbPolicy))
        ($bad -join '; ') | Should Match "DHCP guard is off on 'spare'"
        ($bad -join '; ') | Should Match "MAC spoofing is on on 'spare'"
    }
}
} finally { Remove-VmbTestRoots }
