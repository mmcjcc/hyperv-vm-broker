# Create.Tests.ps1 - Request-VmbCreate (docs/design.md 6.4, 14): check and reserve under the lock, then one job.
# Pester 3.4, Windows PowerShell 5.1, ASCII only. Hyper-V, scheduled tasks and memory are the fakes in VmbTestHelpers.ps1.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

function Get-VmbRecordFiles { @(Get-ChildItem -LiteralPath (Get-VmbPath 'state\vms') -Filter '*.json') }
function Get-VmbJobFiles { @(Get-ChildItem -LiteralPath (Get-VmbPath 'jobs') -Filter '*.json') }

# Nothing was reserved or started: no record, no job, no task.
function Assert-VmbNothingChanged {
    (Get-VmbRecordFiles).Count | Should Be 0
    (Get-VmbJobFiles).Count | Should Be 0
    (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
    (Get-VmbCalls 'Start-ScheduledTask').Count | Should Be 0
}

try {
Describe 'Request-VmbCreate: reserve under the lock, then start one job' {
    It 'writes a creating record under the lock and starts one SYSTEM task for the job' {
        $null = New-VmbTestRoot
        $r = Request-VmbCreate (New-VmbCreateArgs)
        $r.ok | Should Be $true
        $r.exit | Should Be 0
        $r.existing | Should Be $false
        $r.state | Should BeExactly 'creating'
        $r.vm | Should BeExactly 'lab-p1'

        $rec = Get-VmbRecord $r.id
        $rec.state | Should BeExactly 'creating'
        $rec.name | Should BeExactly 'lab-p1'
        $rec.hyperv_name | Should BeExactly 'vmb-lab-p1'
        $rec.owner | Should BeExactly 'cs101-walkthroughs'
        $rec.request_hash | Should BeExactly ('a' * 64)
        $rec.profile | Should BeExactly 'win11-lab'
        $rec.vmid | Should BeNullOrEmpty
        $rec.job | Should BeExactly $r.job
        [IO.Directory]::Exists((Get-VmbPath "vms\$($r.id)")) | Should Be $true

        $job = Get-VmbJobRecord $r.job
        $job.state | Should BeExactly 'queued'
        $job.verb | Should BeExactly 'create'
        $job.vm | Should BeExactly $r.id
        $job.consumer | Should BeExactly 'cs101-walkthroughs'

        $reg = Get-VmbCalls 'Register-ScheduledTask'
        $reg.Count | Should Be 1
        $reg[0].Params['TaskName'] | Should BeExactly "vmb-job-$($r.job)"
        $reg[0].Params['TaskPath'] | Should BeExactly '\vm-broker\'
        $reg[0].LockHeld | Should Be $true
        # the creating record was on disk before the task existed
        @($global:VmbFake.RecordsAtRegister | Where-Object { $_.id -eq $r.id -and $_.state -eq 'creating' }).Count | Should Be 1
        (Get-VmbCalls 'Start-ScheduledTask').Count | Should Be 1
        # the task's command line carries only the job id; everything else is data in the job file
        $act = Get-VmbCalls 'New-ScheduledTaskAction'
        $act.Count | Should Be 1
        [string]$act[0].Params['Argument'] | Should Match ('\\Invoke-VmbJob\.ps1" -JobId ' + $r.job + '$')
        [string]$act[0].Params['Argument'] | Should Not Match 'lab-p1|cs101'
        (Get-VmbCalls 'New-ScheduledTaskPrincipal')[0].Params['UserId'] | Should BeExactly 'NT AUTHORITY\SYSTEM'
        (Get-VmbCalls 'New-ScheduledTaskPrincipal')[0].Params['LogonType'] | Should BeExactly 'ServiceAccount'
        # the lock is released afterwards
        Test-VmbLockHeld | Should Be $false
        $ev = @([IO.File]::ReadAllLines((Get-VmbPath 'state\events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json })
        @($ev | Where-Object { $_.verb -eq 'create' -and $_.vm -eq 'lab-p1' -and $_.exit -eq 4 -and $_.job -eq $r.job }).Count | Should Be 1
    }

    It 'returns the existing VM for a repeat with the same request hash' {
        $null = New-VmbTestRoot
        $a = Request-VmbCreate (New-VmbCreateArgs)
        $b = Request-VmbCreate (New-VmbCreateArgs)
        $b.ok | Should Be $true
        $b.existing | Should Be $true
        $b.id | Should BeExactly $a.id
        $b.job | Should BeExactly $a.job
        $b.state | Should BeExactly 'creating'
        (Get-VmbRecordFiles).Count | Should Be 1
        (Get-VmbJobFiles).Count | Should Be 1
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 1
    }

    It 'refuses a repeat with a different request hash (exit 2)' {
        $null = New-VmbTestRoot
        $null = Request-VmbCreate (New-VmbCreateArgs)
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Hash ('b' * 64)) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'name-taken'
        (Get-VmbRecordFiles).Count | Should Be 1
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 1
    }

    It 'refuses the same name for another consumer (exit 2)' {
        $null = New-VmbTestRoot
        $null = Request-VmbCreate (New-VmbCreateArgs)
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Consumer 'other-project' -Activation 'none' -Keep $false) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'rejected'           # v0.R: the recording VM belongs to the consumer in policy.json
        (Get-VmbRecordFiles).Count | Should Be 1
    }

    It 'refuses a failed record with exit 1: destroy, then create' {
        $null = New-VmbTestRoot
        $a = Request-VmbCreate (New-VmbCreateArgs)
        $rec = Get-VmbRecord $a.id
        $rec.state = 'failed'
        Save-VmbRecord $rec
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 1
        $r.error | Should BeExactly 'failed'
        $r.hint | Should Match 'destroy, then create'
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 1
    }

    It 'refuses a second win11-lab VM (exit 2)' {
        $null = New-VmbTestRoot
        $null = Request-VmbCreate (New-VmbCreateArgs)
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Name 'lab-p2' -Activation 'none' -Keep $false) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'rejected'
        $r.hint | Should Match 'v0.R builds only the recording VM named in policy.json'
        (Get-VmbRecordFiles).Count | Should Be 1
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 1
    }

    It 'refuses <Case> (exit 2)' -TestCases @(
        @{ Case = 'activation mak for another name'; Name = 'lab-p2'; Consumer = 'cs101-walkthroughs'; Activation = 'mak'; Keep = $false }
        @{ Case = 'keep for another name'; Name = 'lab-p2'; Consumer = 'cs101-walkthroughs'; Activation = 'none'; Keep = $true }
        @{ Case = 'activation mak for another consumer'; Name = 'lab-p1'; Consumer = 'other-project'; Activation = 'mak'; Keep = $false }
        @{ Case = 'keep for another consumer'; Name = 'lab-p1'; Consumer = 'other-project'; Activation = 'none'; Keep = $true }
    ) {
        param($Case, $Name, $Consumer, $Activation, $Keep)
        $null = New-VmbTestRoot
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Name $Name -Consumer $Consumer -Activation $Activation -Keep $Keep) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'rejected'
        $r.hint | Should Match 'approved only for the recording VM named in policy.json'
        Assert-VmbNothingChanged
    }

    It 'refuses another name even without mak or keep: v0.R builds only the recording VM (Grok review)' {
        $null = New-VmbTestRoot
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Name 'lab-p2' -Activation 'none' -Keep $false) }
        $r.exit | Should Be 2
        $r.hint | Should Match 'v0.R builds only the recording VM named in policy.json'
        Assert-VmbNothingChanged
    }

    It 'refuses the recording VM without keep, and with fields v0.R does not have' {
        $null = New-VmbTestRoot
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Keep $false) }
        $r.hint | Should Match 'keep'
        $a = New-VmbCreateArgs
        $a.request | Add-Member -NotePropertyName users -NotePropertyValue @([pscustomobject]@{ name = 'x' }) -Force
        $r = Get-VmbRefusal { Request-VmbCreate $a }
        ($r.exit, $r.hint) -join ' ' | Should Match '^2 users: not in v0.R'
        Assert-VmbNothingChanged
    }

    It 'refuses with exit 6 when Firewall3 is not Running' {
        $null = New-VmbTestRoot
        (@($global:VmbFake.VMs) | Where-Object { $_.Name -eq 'Firewall3' }).State = 'Off'
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 6
        $r.error | Should BeExactly 'no-capacity'
        $r.hint | Should Match 'Firewall3 is not running'
        Assert-VmbNothingChanged
    }

    It 'refuses with exit 6 when Firewall3 is not on this host' {
        $null = New-VmbTestRoot
        $global:VmbFake.VMs.Clear()
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 6
        $r.error | Should BeExactly 'no-capacity'
        Assert-VmbNothingChanged
    }

    It 'refuses with exit 6 when the new VM would take the host below the floor' {
        $null = New-VmbTestRoot
        $global:VmbFake.FreeKB = [int64](6144 + 3072 - 1) * 1024
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 6
        $r.error | Should BeExactly 'no-capacity'
        $r.hint | Should BeExactly '9215 MB available, 6144 MB needed to start, floor 3072 MB'
        (Get-VmbCalls 'Get-CimInstance')[0].Positional[0] | Should BeExactly 'Win32_OperatingSystem'
        Assert-VmbNothingChanged
    }

    It 'accepts exactly the floor' {
        $null = New-VmbTestRoot
        $global:VmbFake.FreeKB = [int64](6144 + 3072) * 1024
        (Request-VmbCreate (New-VmbCreateArgs)).ok | Should Be $true
    }

    It 'refuses with exit 6 when the host budget is 0' {
        $pol = Get-VmbTestPolicy
        $pol.budget_gb = 0
        $null = New-VmbTestRoot -Policy $pol
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 6
        $r.hint | Should Match 'budget'
        Assert-VmbNothingChanged
    }

    It 'refuses with exit 6 when the VM volume would drop below 500 GB free' {
        $null = New-VmbTestRoot
        $global:VmbFake.Volume.SizeRemaining = [int64](499GB)
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 6
        $r.hint | Should Match '500 GB'
        Assert-VmbNothingChanged
    }

    It 'refuses the name <Shown> (exit 2)' -TestCases @(
        @{ Shown = 'Lab'; Name = 'Lab' }
        @{ Shown = 'Lab-P1'; Name = 'Lab-P1' }
        @{ Shown = 'rtr-x'; Name = 'rtr-x' }
        @{ Shown = 'img-x'; Name = 'img-x' }
        @{ Shown = 'net-x'; Name = 'net-x' }
        @{ Shown = 'vmb-x'; Name = 'vmb-x' }
        @{ Shown = 'a-'; Name = 'a-' }
        @{ Shown = 'a'; Name = 'a' }
        @{ Shown = 'lab_p1'; Name = 'lab_p1' }
        @{ Shown = '1lab'; Name = '1lab' }
        @{ Shown = 'twelve-chars'; Name = 'twelve-chars' }
        @{ Shown = 'lab-p1 + newline'; Name = "lab-p1`n" }
        @{ Shown = 'empty'; Name = '' }
    ) {
        param($Shown, $Name)
        $null = New-VmbTestRoot
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Name $Name -Activation 'none' -Keep $false) }
        $r | Should Not BeNullOrEmpty
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'rejected'
        Assert-VmbNothingChanged
    }

    It 'refuses the consumer <Shown> (exit 2)' -TestCases @(
        @{ Shown = 'cs101-walkthroughs'; Consumer = 'cs101-walkthroughs' }
        @{ Shown = 'cs101-walkthroughs + newline'; Consumer = "cs101-walkthroughs`n" }
        @{ Shown = 'x'; Consumer = 'x' }
        @{ Shown = '*admin*'; Consumer = '*admin*' }
        @{ Shown = 'empty'; Consumer = '' }
    ) {
        param($Shown, $Consumer)
        $null = New-VmbTestRoot
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Consumer $Consumer -Name 'lab-p2' -Activation 'none' -Keep $false) }
        $r | Should Not BeNullOrEmpty
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'rejected'
        Assert-VmbNothingChanged
    }

    It 'refuses a Hyper-V VM called vmb-<name> that has no record (exit 2)' {
        $null = New-VmbTestRoot
        $null = Add-VmbFakeVM -Name 'vmb-lab-p1' -State 'Off'
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'name-taken'
        Assert-VmbNothingChanged
    }

    It 'refuses another profile or network in v0.R (exit 2)' {
        $null = New-VmbTestRoot
        (Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -ProfileName 'ubuntu-server') }).exit | Should Be 2
        (Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs -Mode 'isolated') }).exit | Should Be 2
        Assert-VmbNothingChanged
    }

    It 'refuses while the broker is frozen (exit 2)' {
        $pol = Get-VmbTestPolicy
        $pol.frozen = $true
        $null = New-VmbTestRoot -Policy $pol
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'frozen'
        Assert-VmbNothingChanged
    }
}

Describe 'Capacity and memory per host policy (servera: firewall here; serverd: firewall elsewhere, small memory)' {
    function Get-VmbServerdPolicy { [IO.File]::ReadAllText((Join-Path $script:VmbRepo 'policy\serverd.json')) | ConvertFrom-Json }
    function Set-VmbFirewallState { param([string]$State) (@($global:VmbFake.VMs) | Where-Object { $_.Name -eq 'Firewall3' }).State = $State }

    It 'takes the memory from the request on servera, and from the policy on serverd' {
        $req = (New-VmbCreateArgs).request
        $a = Get-VmbLabMemory (Get-VmbTestPolicy) $req
        "$($a.startup)/$($a.minimum)/$($a.maximum)" | Should BeExactly '6144/6144/8192'
        $d = Get-VmbLabMemory (Get-VmbServerdPolicy) $req
        "$($d.startup)/$($d.minimum)/$($d.maximum)" | Should BeExactly '1024/1024/3072'
    }

    It 'checks the floor with the policy''s startup memory on serverd' {
        $null = New-VmbTestRoot -Policy (Get-VmbServerdPolicy)
        Set-VmbFirewallState 'Off'
        $global:VmbFake.FreeKB = [int64](1024 + 3072 - 1) * 1024
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 6
        $r.hint | Should BeExactly '4095 MB available, 1024 MB needed to start, floor 3072 MB'
        $global:VmbFake.FreeKB = [int64](1024 + 3072) * 1024
        (Request-VmbCreate (New-VmbCreateArgs)).ok | Should Be $true
    }

    It 'refuses on serverd while Firewall3 runs there (a failover), and allows it otherwise' {
        $null = New-VmbTestRoot -Policy (Get-VmbServerdPolicy)
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 6
        $r.hint | Should Match 'a failover'
        (Get-VmbRecordFiles).Count | Should Be 0
        $global:VmbFake.VMs.Clear()
        (Request-VmbCreate (New-VmbCreateArgs)).ok | Should Be $true
    }

    It 'refuses an unknown firewall_mode (exit 255)' {
        $pol = Get-VmbTestPolicy
        $pol.firewall_mode = 'both'
        $null = New-VmbTestRoot -Policy $pol
        $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) }
        $r.exit | Should Be 255
        $r.error | Should BeExactly 'bad-policy'
        (Get-VmbRecordFiles).Count | Should Be 0
    }

    It 'start checks the floor with the VM''s own startup memory' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -State 'Off'
        $global:VmbFake.FreeKB = [int64](6144 + 3072 - 1) * 1024
        $A = ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs' }
        $r = Get-VmbRefusal { Start-VmbVM $A }
        $r.exit | Should Be 6
        $r.hint | Should Match '6144 MB needed to start'
        (Get-VmbCalls 'Start-VM').Count | Should Be 0
        $t.VM.MemoryStartup = [int64]1280MB
        $ok = Start-VmbVM $A
        $ok.ok | Should Be $true
        $ok.state | Should BeExactly 'Running'
        (Get-VmbCalls 'Start-VM').Count | Should Be 1
    }

    It 'keeps the copy window open all day when copy_window.always is set (serverd)' {
        $pol = Get-VmbServerdPolicy
        foreach ($h in 0, 7, 13, 23) { Test-VmbCopyWindow $pol (New-Object DateTime 2026, 10, 12, $h, 30, 0) | Should Be $true }
    }
}

Describe 'Request-VmbResume: run the build again from a step, never at the cost of the activation' {
    function Get-VmbResumeArgs { param([string]$From = '') $h = @{ name = 'lab-p1'; consumer = '*admin*' }; if ($From) { $h.from = $From }; ConvertTo-VmbArgs $h }

    It 'refuses to rerun <From> on a VM whose activation is <State> (exit 2), and changes nothing' -TestCases @(
        @{ From = 'window'; State = 'activated' }, @{ From = 'iso'; State = 'activated' }, @{ From = 'disk'; State = 'activated' },
        @{ From = 'disk'; State = 'failed' }, @{ From = 'disk'; State = 'activating' }) {
        param($From, $State)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -ActivationState $State
        $before = [IO.File]::ReadAllText((Get-VmbPath "state\vms\$($t.Id).json"))
        $r = Get-VmbRefusal { Request-VmbResume (Get-VmbResumeArgs $From) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'rejected'
        $r.hint | Should Match "may hold an activation \($State\)"
        [IO.File]::ReadAllText((Get-VmbPath "state\vms\$($t.Id).json")) | Should BeExactly $before
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
    }

    It 'reruns <From> on an activated VM, keeping the steps before it' -TestCases @(@{ From = 'vm'; Kept = 'window,iso,disk' }, @{ From = 'director'; Kept = 'window,iso,disk,vm,boot,first-contact,updates,lab-setup' }) {
        param($From, $Kept)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -ActivationState 'activated'
        $r = Request-VmbResume (Get-VmbResumeArgs $From)
        $r.ok | Should Be $true
        (@($r.done_steps) -join ',') | Should BeExactly $Kept
        $rec = Get-VmbRecord $t.Id
        $rec.state | Should BeExactly 'creating'
        $rec.job | Should BeExactly $r.job
        (Get-VmbJobRecord $r.job).args.from | Should BeExactly $From
        (Get-VmbCalls 'Register-ScheduledTask')[0].LockHeld | Should Be $true
    }

    It 'refuses a ready VM without --from (exit 2)' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM -RecordState 'ready'
        $r = Get-VmbRefusal { Request-VmbResume (Get-VmbResumeArgs) }
        $r.exit | Should Be 2
        $r.hint | Should Match 'name the step'
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
    }

    It 'continues a failed build without --from, from the first step not done' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -RecordState 'failed' -DoneSteps @('window', 'iso', 'disk', 'vm')
        $r = Request-VmbResume (Get-VmbResumeArgs)
        $r.ok | Should Be $true
        (@($r.done_steps) -join ',') | Should BeExactly 'window,iso,disk,vm'
        (Get-VmbRecord $t.Id).state | Should BeExactly 'creating'
    }

    It 'refuses an unknown step, and a VM with a job still running' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -RecordState 'failed'
        (Get-VmbRefusal { Request-VmbResume (Get-VmbResumeArgs 'format-c') }).exit | Should Be 2
        $j = New-VmbTestJob -Vm $t.Id -State 'running'
        $global:VmbFake.Tasks[[string]$j.task] = [pscustomobject]@{ TaskName = [string]$j.task; State = 'Running' }
        (Get-VmbRefusal { Request-VmbResume (Get-VmbResumeArgs 'director') }).exit | Should Be 3
    }
}

Describe 'Install-VmbHost: the one-time install into a new root' {
    It 'under -WhatIf creates nothing, lists every step and reports nothing as done' {
        $root = New-VmbTestRoot
        $script:VmbRoot = Join-Path (Split-Path -Parent $root) 'vmb-new'
        $parent = Split-Path -Parent $root
        $before = Get-VmbTreeSnapshot $parent
        $script:VmbWhatIf = $true
        try { $r = Install-VmbHost (ConvertTo-VmbArgs @{ policy = (Get-VmbTestPolicy); secrets = 'cms' }) } finally { $script:VmbWhatIf = $false }
        @($r.done).Count | Should Be 0
        Get-VmbTreeSnapshot $parent | Should BeExactly $before
        $planned = @($script:VmbPlanned)
        @($planned | Where-Object { $_ -like 'create *\vmb-new*' }).Count | Should Be 10
        @($planned | Where-Object { $_ -like '*vm-broker secrets*' }).Count | Should Be 1
        (Get-VmbCalls 'New-SelfSignedCertificate').Count | Should Be 0
        (Get-VmbCalls 'Set-Acl').Count | Should Be 0
    }

    It 'creates the folders and the policy, and sets the root ACL: inheritance off, SYSTEM and Administrators only' {
        $root = New-VmbTestRoot
        $new = Join-Path (Split-Path -Parent $root) 'vmb-new'
        $script:VmbRoot = $new
        $r = Install-VmbHost (ConvertTo-VmbArgs @{ policy = (Get-VmbTestPolicy); secrets = 'dpapi' })
        $r.ok | Should Be $true
        @($r.done).Count | Should Be 11
        foreach ($sub in 'code', 'state\vms', 'jobs', 'vms', 'secrets', 'stage', 'media') { [IO.Directory]::Exists((Join-Path $new $sub)) | Should Be $true }
        ([IO.File]::ReadAllText((Join-Path $new 'policy.json')) | ConvertFrom-Json).host | Should BeExactly 'servera'
        $acl = Get-VmbCalls 'Set-Acl'
        $acl.Count | Should Be 1
        $acl[0].Params['LiteralPath'] | Should BeExactly $new
        $o = $acl[0].Params['AclObject']
        $o.AreAccessRulesProtected | Should Be $true
        $sids = @($o.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { "$($_.IdentityReference.Value):$($_.FileSystemRights)" } | Sort-Object)
        ($sids -join ',') | Should BeExactly 'S-1-5-18:FullControl,S-1-5-32-544:FullControl'
        (Get-VmbCalls 'New-SelfSignedCertificate').Count | Should Be 0
    }
}

Describe 'Enter-VmbLock: one broker call at a time on a host' {
    It 'gives exit 3 while another call holds the lock, and takes it once it is free' {
        $null = New-VmbTestRoot
        $other = [IO.File]::Open((Get-VmbPath 'state\lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $r = Get-VmbRefusal { Enter-VmbLock -TimeoutS 0 }
            $r.exit | Should Be 3
            $r.error | Should BeExactly 'busy'
        } finally { $other.Dispose() }
        $l = Enter-VmbLock -TimeoutS 0
        try { Test-VmbLockHeld | Should Be $true } finally { Exit-VmbLock $l }
        Test-VmbLockHeld | Should Be $false
    }

    It 'takes no lock under -WhatIf' {
        $root = New-VmbTestRoot
        $script:VmbWhatIf = $true
        try { Enter-VmbLock | Should BeNullOrEmpty } finally { $script:VmbWhatIf = $false }
        [IO.File]::Exists((Join-Path $root 'state\lock')) | Should Be $false
    }
}

Describe 'Request-VmbCreate with -WhatIf: every check runs, nothing changes' {
    It 'writes no file under the root and lists the planned changes' {
        $root = New-VmbTestRoot
        $parent = Split-Path -Parent $root
        $before = Get-VmbTreeSnapshot $parent
        $script:VmbWhatIf = $true
        try { $r = Request-VmbCreate (New-VmbCreateArgs) } finally { $script:VmbWhatIf = $false }
        $r.ok | Should Be $true
        $r.existing | Should Be $false
        Get-VmbTreeSnapshot $parent | Should BeExactly $before
        $planned = @($script:VmbPlanned)
        @($planned | Where-Object { $_ -eq ('write ' + (Get-VmbPath "state\vms\$($r.id).json")) }).Count | Should Be 2
        @($planned | Where-Object { $_ -eq ('create ' + (Get-VmbPath "vms\$($r.id)")) }).Count | Should Be 1
        @($planned | Where-Object { $_ -eq ('write ' + (Get-VmbPath "jobs\$($r.job).json")) }).Count | Should Be 1
        @($planned | Where-Object { $_ -eq "register and start the SYSTEM task \vm-broker\vmb-job-$($r.job)" }).Count | Should Be 1
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
        (Get-VmbCalls 'Start-ScheduledTask').Count | Should Be 0
        (Get-VmbCalls 'New-ScheduledTaskAction').Count | Should Be 0
    }

    It 'still refuses what it would refuse without -WhatIf' {
        $root = New-VmbTestRoot
        (@($global:VmbFake.VMs) | Where-Object { $_.Name -eq 'Firewall3' }).State = 'Off'
        $before = Get-VmbTreeSnapshot $root
        $script:VmbWhatIf = $true
        try { $r = Get-VmbRefusal { Request-VmbCreate (New-VmbCreateArgs) } } finally { $script:VmbWhatIf = $false }
        $r.exit | Should Be 6
        Get-VmbTreeSnapshot $root | Should BeExactly $before
    }
}
} finally { Remove-VmbTestRoots }
