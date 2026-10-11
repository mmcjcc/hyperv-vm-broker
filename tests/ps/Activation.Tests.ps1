# Activation.Tests.ps1 - Invoke-VmbActivate and secret redaction (docs/design.md 9 and 14; section 15 item 15).
# The MAK here is a made-up value in the 5x5 form, not a key. Pester 3.4, Windows PowerShell 5.1, ASCII only.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

$script:FakeMak = 'ABCDE-12345-FGHIJ-67890-KLMNO'
$script:PublicGvlk = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'    # Microsoft's published KMS client key for Server 2025 Standard

# The guest's answers, chosen by which of the backend's own blocks was sent (by text: Vmb.ps1 run in-process has
# its own copies of the blocks).
function Set-VmbActivationGuest {
    param([switch]$KeyInError, [switch]$AlreadyActivated, [switch]$InstallLost)
    $global:VmbTestBlocks = @{ install = $script:VmbGuestInstallKey.ToString(); search = $script:VmbGuestKeySearch.ToString(); logging = $script:VmbGuestLogging.ToString()
                               licence = $script:VmbGuestLicenseState.ToString() }
    $global:VmbTestKeyInError = [bool]$KeyInError
    $global:VmbTestAlreadyActivated = [bool]$AlreadyActivated
    $global:VmbTestInstallLost = [bool]$InstallLost
    $global:VmbFake.Guest = { param($c)
        $sb = $c.Params['ScriptBlock'].ToString(); $a = @($c.Params['ArgumentList'])
        if ($sb -ceq $global:VmbTestBlocks.licence) {
            if ($global:VmbTestAlreadyActivated) { return [pscustomobject]@{ products = 1; channel = 'Volume:MAK'; license_status = 1; grace_minutes = 0 } }
            return [pscustomobject]@{ products = 1; channel = 'Volume:GVLK'; license_status = 5; grace_minutes = 0 }
        }
        if ($sb -ceq $global:VmbTestBlocks.install) {
            if ($global:VmbTestInstallLost) { throw 'The pipe has been ended.' }   # the session dropped mid-call
            if ($global:VmbTestKeyInError) { throw "InstallProductKey failed for $($a[0])" }
            return [pscustomobject]@{ installed = $true; activated = [bool]$a[1]; error = $null; cleared = $true; edition = 'Windows(R), ServerStandard edition'
                                      channel = $(if ($a[1]) { 'Volume:MAK' } else { 'Volume:GVLK' }); license_status = $(if ($a[1]) { 1 } else { 5 }); grace_minutes = 0 }
        }
        if ($sb -ceq $global:VmbTestBlocks.search) {
            $ev = if ($a[1]) { [pscustomobject]@{ 'Microsoft-Windows-PowerShell/Operational' = 0; 'Windows PowerShell' = 0; Security = 0 } } else { $null }
            return [pscustomobject]@{ registry = @(); events = $ev }
        }
        if ($sb -ceq $global:VmbTestBlocks.logging) {
            if ($a[0]) { return [pscustomobject]@{ ScriptBlockLogging = $null; ModuleLogging = 1 } } else { return $true }
        }
        throw 'the test guest got a script block it does not know'
    }
}

function Get-VmbActivateArgs { param([string]$Key = $script:FakeMak, [string]$Mode = 'mak', [string]$Name = 'lab-p1') ConvertTo-VmbArgs @{ name = $Name; mode = $Mode; key = $Key } }

# The key in any form a leak could take: as given, without dashes, in any case.
function Test-VmbHasKey {
    param([string]$Text, [string]$Key = $script:FakeMak)
    $Text.IndexOf($Key, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $Text.IndexOf($Key.Replace('-', ''), [StringComparison]::OrdinalIgnoreCase) -ge 0
}

# Every file under the test root, read as UTF-8 and as UTF-16.
function Get-VmbFilesWithKey {
    param([string]$Root, [string]$Key = $script:FakeMak)
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        $b = [IO.File]::ReadAllBytes($_.FullName)
        (Test-VmbHasKey ([Text.Encoding]::UTF8.GetString($b)) $Key) -or (Test-VmbHasKey ([Text.Encoding]::Unicode.GetString($b)) $Key)
    } | ForEach-Object { $_.FullName })
}

try {
Describe 'Invoke-VmbActivate: refusals (the key never leaves the host)' {
    It 'refuses a key that is not in the 5x5 form: <Shown>' -TestCases @(
        @{ Shown = 'too short'; Key = 'ABCDE-12345' }
        @{ Shown = 'one character short'; Key = 'ABCDE-12345-FGHIJ-67890-KLMN' }
        @{ Shown = 'underscores'; Key = 'ABCDE_12345_FGHIJ_67890_KLMNO' }
        @{ Shown = 'a subexpression'; Key = '$(WHOAMI)-12345-FGHIJ-67890-KLMNO' }
        @{ Shown = 'a quote'; Key = 'ABCD"-12345-FGHIJ-67890-KLMNO' }
        @{ Shown = 'six groups'; Key = 'ABCDE-12345-FGHIJ-67890-KLMNO-PQRST' }
        @{ Shown = 'empty'; Key = '' }
    ) {
        param($Shown, $Key)
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbActivationGuest
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs -Key $Key) }
        $r.exit | Should Be 2
        $r.hint | Should BeExactly 'the key is not in the 5x5 form'
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses a public GVLK in mode mak' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs -Key $script:PublicGvlk) }
        $r.exit | Should Be 2
        $r.hint | Should Match 'public GVLK, not a MAK'
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses a key that is not a public GVLK in mode gvlk-proof' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs -Mode 'gvlk-proof') }
        $r.exit | Should Be 2
        $r.hint | Should Match 'only a public GVLK'
        (Test-VmbHasKey $r.hint) | Should Be $false
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses an unknown mode' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        (Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs -Mode 'kms') }).exit | Should Be 2
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses a MAK for a VM that is not policy.recording_vm' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM -Name 'lab-p2'
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs -Name 'lab-p2') }
        $r.exit | Should Be 2
        $r.hint | Should Match 'approved only for the recording VM'
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses a MAK when policy.json does not approve activation for the recording VM' {
        $pol = Get-VmbTestPolicy
        $pol.recording_vm.approved = @('keep', 'lan')
        $null = New-VmbTestRoot -Policy $pol
        $null = New-VmbTestVM
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs) }
        $r.exit | Should Be 2
        $r.hint | Should Match 'approved only for the recording VM'
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses a second MAK on an activated VM' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM -ActivationState 'activated'
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs) }
        $r.exit | Should Be 2
        $r.hint | Should Match 'already activated'
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses a MAK before the build finished its lab-setup step' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM -DoneSteps @('window', 'iso', 'disk', 'vm', 'boot', 'first-contact', 'updates')
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs) }
        $r.exit | Should Be 2
        $r.hint | Should Match 'lab-setup'
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses while a job runs on the VM (exit 3)' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $j = New-VmbTestJob -Vm $t.Id -State 'running'
        $global:VmbFake.Tasks[[string]$j.task] = [pscustomobject]@{ TaskName = [string]$j.task; State = 'Running' }
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs) }
        $r.exit | Should Be 3
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }

    It 'refuses the GVLK proof on a VM whose activation is <State>: it would replace the MAK' -TestCases @(
        @{ State = 'activated' }, @{ State = 'failed' }, @{ State = 'activating' }) {
        param($State)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -ActivationState $State
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs -Key $script:PublicGvlk -Mode 'gvlk-proof') }
        $r.exit | Should Be 2
        $r.hint | Should Match 'replace the MAK'
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
        (Get-VmbRecord $t.Id).activation.state | Should BeExactly $State
    }

    It 'refuses <Mode> when the guest itself is already activated, whatever the record says' -TestCases @(
        @{ Mode = 'mak' }, @{ Mode = 'gvlk-proof' }) {
        param($Mode)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        Set-VmbActivationGuest -AlreadyActivated
        $key = if ($Mode -eq 'mak') { $script:FakeMak } else { $script:PublicGvlk }
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs -Key $key -Mode $Mode) }
        $r.exit | Should Be 2
        $r.hint | Should Match 'guest is already activated \(channel Volume:MAK'
        $ic = @(Get-VmbCalls 'Invoke-Command')
        $ic.Count | Should Be 1                      # only the read of the licence state
        [object]::ReferenceEquals($ic[0].Params['ScriptBlock'], $script:VmbGuestLicenseState) | Should Be $true
        (Get-VmbRecord $t.Id).activation.state | Should BeExactly 'none'
    }

    It 'marks the record activating before the key goes in, and leaves it so when the guest call is lost' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        Set-VmbActivationGuest -InstallLost
        $r = Get-VmbRefusal { Invoke-VmbActivate (Get-VmbActivateArgs) }
        $r.exit | Should Not Be 0
        $rec = Get-VmbRecord $t.Id
        $rec.activation.state | Should BeExactly 'activating'
        $rec.activation.at | Should Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        (Test-VmbMayHoldActivation $rec) | Should Be $true
        # a second try reads the guest first; here the guest is not activated, so it may go ahead
        Set-VmbActivationGuest
        (Invoke-VmbActivate (Get-VmbActivateArgs)).ok | Should Be $true
        $rec2 = Get-VmbRecord $t.Id
        $rec2.activation.state | Should BeExactly 'activated'
        # the time of the latest try: a checkpoint taken between two tries may lack the activation, so restores of
        # anything older than the last key installation are refused
        ([string]$rec2.activation.at -ge [string]$rec.activation.at) | Should Be $true
    }
}

Describe 'Invoke-VmbActivate: the key goes only into -ArgumentList and never comes back' {
    It 'passes the MAK to the guest as data and keeps it out of the result, the record, the events and the logs' {
        $root = New-VmbTestRoot
        $t = New-VmbTestVM
        Set-VmbActivationGuest
        $r = Invoke-VmbActivate (Get-VmbActivateArgs -Key (' ' + $script:FakeMak.ToLower() + ' '))
        $r.ok | Should Be $true
        $r.mode | Should BeExactly 'mak'
        $r.installed | Should Be $true
        $r.activated | Should Be $true
        $r.cleared | Should Be $true
        $r.permanent | Should Be $true
        @($r.key_found_in_registry).Count | Should Be 0

        $ic = Get-VmbCalls 'Invoke-Command'
        $ic.Count | Should Be 3
        [object]::ReferenceEquals($ic[0].Params['ScriptBlock'], $script:VmbGuestLicenseState) | Should Be $true
        [object]::ReferenceEquals($ic[1].Params['ScriptBlock'], $script:VmbGuestInstallKey) | Should Be $true
        [object]::ReferenceEquals($ic[2].Params['ScriptBlock'], $script:VmbGuestKeySearch) | Should Be $true
        (Test-VmbHasKey (ConvertTo-VmbJson @($ic[0].Params['ArgumentList']))) | Should Be $false   # the read carries no key
        $install = @($ic[1].Params['ArgumentList'])
        ($install[0] -ceq $script:FakeMak) | Should Be $true
        $install[1] | Should Be $true
        $install[2] | Should BeExactly '55c92734-d682-4d71-983e-d6ec3f16059f'
        $install[3] | Should BeExactly $script:PublicGvlk     # the GVLK that goes back if the key is not a MAK
        $script:VmbGuestInstallKey.ToString() | Should Match "-notlike '\*MAK\*'"
        $search = @($ic[2].Params['ArgumentList'])
        ($search[0] -ceq $script:FakeMak) | Should Be $true
        $search[1] | Should Be $false
        foreach ($c in $ic) {
            (Test-VmbHasKey $c.Params['ScriptBlock'].ToString()) | Should Be $false
            $c.Params.ContainsKey('Session') | Should Be $true
        }
        $ns = Get-VmbCalls 'New-PSSession'; $ns.Count | Should Be 3; for ($k = 0; $k -lt $ns.Count; $k++) { "$($ns[$k].Params['VMId'])" | Should Be "$($t.VM.Id)" }
        (Test-VmbHasKey (ConvertTo-VmbJson $r)) | Should Be $false
        (Get-VmbFilesWithKey (Split-Path -Parent $root)).Count | Should Be 0
        $rec = Get-VmbRecord $t.Id
        $rec.activation.state | Should BeExactly 'activated'
        $rec.activation.channel | Should BeExactly 'Volume:MAK'
        (Get-VmbSleepMs) -join ',' | Should BeExactly '5000'
        # the key is now a known secret: redacted wherever the backend writes text
        Hide-VmbSecret "slmgr said $($script:FakeMak) is fine" | Should BeExactly 'slmgr said *** is fine'
    }

    It 'runs the GVLK proof with the guest logging on, then restores it; the key only in -ArgumentList' {
        $root = New-VmbTestRoot
        $t = New-VmbTestVM
        Set-VmbActivationGuest
        $r = Invoke-VmbActivate (Get-VmbActivateArgs -Key $script:PublicGvlk -Mode 'gvlk-proof')
        $r.ok | Should Be $true
        $ic = Get-VmbCalls 'Invoke-Command'
        $ic.Count | Should Be 5
        $order = @($ic | ForEach-Object { $sb = $_.Params['ScriptBlock']
            if ([object]::ReferenceEquals($sb, $script:VmbGuestLicenseState)) { 'licence' }
            elseif ([object]::ReferenceEquals($sb, $script:VmbGuestLogging)) { 'logging' }
            elseif ([object]::ReferenceEquals($sb, $script:VmbGuestInstallKey)) { 'install' }
            elseif ([object]::ReferenceEquals($sb, $script:VmbGuestKeySearch)) { 'search' } else { 'other' } })
        ($order -join ',') | Should BeExactly 'licence,logging,install,search,logging'
        @($ic[1].Params['ArgumentList'])[0] | Should Be $true
        @($ic[4].Params['ArgumentList'])[0] | Should Be $false
        @($ic[4].Params['ArgumentList'])[1].ModuleLogging | Should Be 1
        (@($ic[2].Params['ArgumentList'])[0] -ceq $script:PublicGvlk) | Should Be $true
        @($ic[2].Params['ArgumentList'])[1] | Should Be $false
        @($ic[3].Params['ArgumentList'])[1] | Should Be $true
        foreach ($c in $ic) { (Test-VmbHasKey $c.Params['ScriptBlock'].ToString() $script:PublicGvlk) | Should Be $false }
        (Get-VmbRecord $t.Id).activation.state | Should BeExactly 'gvlk-proof'
        (Test-VmbHasKey (ConvertTo-VmbJson $r) $script:PublicGvlk) | Should Be $false
    }

    It 'masks the key when the guest error quotes it' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbActivationGuest -KeyInError
        $info = $null
        try { $null = Invoke-VmbActivate (Get-VmbActivateArgs) } catch { $info = Get-VmbErrorInfo $_ }
        $info | Should Not BeNullOrEmpty
        $info.hint | Should BeExactly 'InstallProductKey failed for ***'
    }

    It 'masks the key end to end: Vmb.ps1 activate prints no key even when the guest error quotes it' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        $ver = 'c' * 64
        [IO.File]::WriteAllText((Join-Path $root 'code\VERSION'), $ver)
        Set-VmbActivationGuest -KeyInError
        $json = ConvertTo-Json -Compress -InputObject @{ name = 'lab-p1'; mode = 'mak'; key = $script:FakeMak }
        $out = @(& (Join-Path $script:VmbBackendPs 'Vmb.ps1') -Verb 'activate' -Json $json -Code $ver -Root $root)
        $out.Count | Should Be 1
        (Test-VmbHasKey $out[0]) | Should Be $false
        ($out[0].Substring(11) | ConvertFrom-Json).hint | Should BeExactly 'InstallProductKey failed for ***'
        (Get-VmbFilesWithKey (Split-Path -Parent $root)).Count | Should Be 0
    }
}

Describe 'Hide-VmbSecret and the job log' {
    It 'replaces every known secret of 6 characters or more, and nothing shorter' {
        $null = New-VmbTestRoot
        [void]$script:VmbSecretValues.Add($script:FakeMak)
        [void]$script:VmbSecretValues.Add('short')
        Hide-VmbSecret "a $($script:FakeMak) b $($script:FakeMak)" | Should BeExactly 'a *** b ***'
        Hide-VmbSecret 'a short word' | Should BeExactly 'a short word'
    }

    It 'redacts a generated password and a known key in the job log' {
        $root = New-VmbTestRoot
        $pw = New-VmbPassword
        [void]$script:VmbSecretValues.Add($script:FakeMak)
        $script:VmbJob = [pscustomobject]@{ id = (New-VmbId); step = 'activate' }
        try {
            Write-VmbLog "key $($script:FakeMak) and password $pw"
            $log = [IO.File]::ReadAllText((Get-VmbPath "jobs\$($script:VmbJob.id).log"))
        } finally { $script:VmbJob = $null }
        $log | Should Match '\[activate\] key \*\*\* and password \*\*\*'
        (Test-VmbHasKey $log) | Should Be $false
        $log.Contains($pw) | Should Be $false
        $pw.Length | Should Be 24
    }

    It 'masks a secret that straddles the 300-character cut of an error message' {
        $null = New-VmbTestRoot
        [void]$script:VmbSecretValues.Add($script:FakeMak)
        $info = $null
        try { throw (('x' * 285) + ' ' + $script:FakeMak + ' tail') } catch { $info = Get-VmbErrorInfo $_ }
        $info.hint | Should Not Match 'ABCDE'
        $info.hint | Should BeExactly (('x' * 285) + ' *** tail')
    }

    It 'still cuts a long error after masking' {
        $null = New-VmbTestRoot
        [void]$script:VmbSecretValues.Add($script:FakeMak)
        $info = $null
        try { throw ($script:FakeMak + ' ' + ('y' * 400)) } catch { $info = Get-VmbErrorInfo $_ }
        $info.hint.Length | Should Be 300
        $info.hint.StartsWith('*** yyy') | Should Be $true
    }

    It 'redacts a secret read back with Get-VmbSecret' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $script:VmbSecretValues.Clear()
        $v = Get-VmbSecret $t.Id 'vmbadmin'
        $v | Should BeExactly 'fake-test-value-not-a-secret'
        Hide-VmbSecret "pw=$v" | Should BeExactly 'pw=***'
    }
}
} finally { Remove-VmbTestRoots }
