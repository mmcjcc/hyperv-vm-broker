# Injection.Tests.ps1 - consumer strings are data on the host (docs/design.md 11 and 13.2).
# Each payload would change something if the host ran it as code; the canary payloads set $global:VmbPwned. The
# tests check that the value reaches the guest stub unchanged, only as an -ArgumentList value, inside one of the
# backend's own $script:VmbGuest* script blocks, and that nothing ran on the host. Pester 3.4, Windows PowerShell 5.1,
# ASCII only. Even if a payload did run, the stubs would catch it: Remove-Item outside the test root, Stop-Computer
# and whoami throw and are recorded.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

$script:VmbPayloads = @(
    @{ Shown = 'a subexpression that deletes'; Payload = '$(Remove-Item C:\ -Recurse)' }
    @{ Shown = 'a subexpression canary'; Payload = '$(Set-Variable -Scope Global -Name VmbPwned -Value 1)' }
    @{ Shown = 'backticks'; Payload = '`whoami`' }
    @{ Shown = 'double quotes around Stop-Computer'; Payload = '"; Stop-Computer; "' }
    @{ Shown = 'double quotes around a canary'; Payload = '"; Set-Variable -Scope Global -Name VmbPwned -Value 2; "' }
    @{ Shown = 'single quotes around exit'; Payload = "'; exit; '" }
    @{ Shown = 'single quotes around a canary'; Payload = "'; Set-Variable -Scope Global -Name VmbPwned -Value 3; '" }
    @{ Shown = 'a semicolon'; Payload = 'a;b' }
    @{ Shown = 'a newline in the middle'; Payload = "first line`nSet-Variable -Scope Global -Name VmbPwned -Value 4" }
    @{ Shown = 'a hashtable literal'; Payload = '@{x=1}' }
    @{ Shown = 'a variable, a subexpression and a call'; Payload = '${env:COMPUTERNAME}$(whoami)& whoami' }
)

# Nothing ran on the host: no canary, no forbidden command, no file stub refused.
function Assert-VmbNotRun {
    (Test-Path variable:global:VmbPwned) | Should Be $false
    foreach ($n in 'Stop-Computer', 'Restart-Computer', 'whoami', 'whoami.exe', 'Invoke-Expression', 'Start-Process') { (Get-VmbCalls $n).Count | Should Be 0 }
    @($global:VmbCalls | Where-Object { $_.Refused }).Count | Should Be 0
}

function Set-VmbRunGuest {
    $global:VmbFake.Guest = { param($c)
        [pscustomobject]@{ exit_code = 0; stdout = 'guest output'; stderr = ''; stdout_cut = $false; stderr_cut = $false; timed_out = $false; seconds = 0.1; interactive = $false }
    }
}

function Get-VmbArgsFor { param([hashtable]$More) $h = @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs' }; foreach ($k in $More.Keys) { $h[$k] = $More[$k] }; ConvertTo-VmbArgs $h }

try {
Describe 'Invoke-VmbRun: the command reaches the guest unchanged, as data' {
    It 'passes <Shown> as the first -ArgumentList value of $script:VmbGuestRun' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        Set-VmbRunGuest
        $r = Invoke-VmbRun (Get-VmbArgsFor @{ command = $Payload })
        $r.ok | Should Be $true
        $r.stdout | Should BeExactly 'guest output'
        $ic = Get-VmbCalls 'Invoke-Command'
        $ic.Count | Should Be 1
        $sb = $ic[0].Params['ScriptBlock']
        [object]::ReferenceEquals($sb, $script:VmbGuestRun) | Should Be $true
        $sb.ToString() | Should BeExactly $script:VmbGuestRun.ToString()
        $sb.ToString().Contains($Payload) | Should Be $false
        $al = @($ic[0].Params['ArgumentList'])
        $al.Count | Should Be 4
        ($al[0] -is [string]) | Should Be $true
        ($al[0] -ceq $Payload) | Should Be $true
        $al[1] | Should Be 300
        "$((Get-VmbCalls 'New-PSSession')[0].Params['VMId'])" | Should Be "$($t.VM.Id)"
        (Get-VmbCalls 'New-PSSession')[0].Params['Credential'].UserName | Should BeExactly '.\vmbadmin'
        Assert-VmbNotRun
    }

    It 'passes <Shown> unchanged end to end: -Json, Vmb.ps1, the guest stub' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        $ver = 'c' * 64
        [IO.File]::WriteAllText((Join-Path $root 'code\VERSION'), $ver)
        Set-VmbRunGuest
        $json = ConvertTo-Json -Compress -InputObject @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; command = $Payload }
        $out = @(& (Join-Path $script:VmbBackendPs 'Vmb.ps1') -Verb 'run' -Json $json -Code $ver -Root $root)
        $out.Count | Should Be 1
        $res = $out[0].Substring(11) | ConvertFrom-Json
        $res.ok | Should Be $true
        $ic = Get-VmbCalls 'Invoke-Command'
        $ic.Count | Should Be 1
        $ic[0].Params['ScriptBlock'].ToString() | Should BeExactly $script:VmbGuestRun.ToString()
        (@($ic[0].Params['ArgumentList'])[0] -ceq $Payload) | Should Be $true
        Assert-VmbNotRun
    }

    It 'refuses an empty command and one over 8192 bytes, before any guest call' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        (Get-VmbRefusal { Invoke-VmbRun (Get-VmbArgsFor @{ command = '' }) }).exit | Should Be 2
        (Get-VmbRefusal { Invoke-VmbRun (Get-VmbArgsFor @{ command = ('x' * 8193) }) }).exit | Should Be 2
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
    }
}

Describe 'Invoke-VmbDirector: step bodies are relayed unchanged, as one JSON argument' {
    It 'relays <Shown> in a step body' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $global:VmbFake.Guest = { param($c) , @('{"ok":true}', '{"ok":true}') }
        $typed = ConvertTo-Json -Compress -InputObject @{ text = $Payload; cps = 20 }
        $r = Invoke-VmbDirector (Get-VmbArgsFor @{ steps = @(@{ action = 'type'; body = $typed; timeout_s = 30 }, @{ action = 'key'; body = $Payload; timeout_s = 5 }) })
        $r.ok | Should Be $true
        @($r.answers).Count | Should Be 2
        $ic = Get-VmbCalls 'Invoke-Command'
        $ic.Count | Should Be 1
        [object]::ReferenceEquals($ic[0].Params['ScriptBlock'], $script:VmbGuestDirectorRelay) | Should Be $true
        $ic[0].Params['ScriptBlock'].ToString().Contains($Payload) | Should Be $false
        $ic[0].Params['Session'].Name | Should BeExactly 'vmb-fake-session'
        $al = @($ic[0].Params['ArgumentList'])
        $al.Count | Should Be 1
        ($al[0] -is [string]) | Should Be $true
        $steps = ConvertFrom-VmbJsonArray $al[0]
        $steps.Count | Should Be 2
        $steps[0].endpoint | Should BeExactly '/type'
        ($steps[0].body -ceq $typed) | Should Be $true
        ((($steps[0].body | ConvertFrom-Json).text) -ceq $Payload) | Should Be $true
        $steps[0].timeout_s | Should Be 30
        $steps[1].endpoint | Should BeExactly '/key'
        ($steps[1].body -ceq $Payload) | Should Be $true
        "$((Get-VmbCalls 'New-PSSession')[0].Params['VMId'])" | Should Be "$($t.VM.Id)"
        (Get-VmbCalls 'Remove-PSSession').Count | Should Be 1
        Assert-VmbNotRun
    }

    It 'refuses <Shown> as a director action, before any guest call' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        $r = Get-VmbRefusal { Invoke-VmbDirector (Get-VmbArgsFor @{ steps = @(@{ action = $Payload; body = '{}'; timeout_s = 30 }) }) }
        $r.exit | Should Be 2
        $r.hint | Should Match '^director action '
        (Get-VmbCalls 'New-PSSession').Count | Should Be 0
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
        Assert-VmbNotRun
    }

    It 'maps actions to endpoints from its own table only' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        $global:VmbFake.Guest = { param($c) , @('{"ok":true}') }
        $null = Invoke-VmbDirector (Get-VmbArgsFor @{ steps = @(@{ action = 'record_start'; body = '{"file":"ch1.mkv"}'; timeout_s = 10 }) })
        $steps = ConvertFrom-VmbJsonArray (@((Get-VmbCalls 'Invoke-Command')[0].Params['ArgumentList'])[0])
        $steps.Count | Should Be 1
        $steps[0].endpoint | Should BeExactly '/record/start'
        (Get-VmbRefusal { Invoke-VmbDirector (Get-VmbArgsFor @{ steps = @(@{ action = '/health'; body = '{}'; timeout_s = 10 }) }) }).exit | Should Be 2
        (Get-VmbRefusal { Invoke-VmbDirector (Get-VmbArgsFor @{ steps = @(@{ action = 'health/../x'; body = '{}'; timeout_s = 10 }) }) }).exit | Should Be 2
    }
}

Describe 'Checkpoint labels: refused by the label rule, never executed' {
    It 'refuses <Shown> as a label for snapshot, restore and snapshot-rm' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        $A = Get-VmbArgsFor @{ label = $Payload; replace = $true }
        foreach ($call in { Request-VmbSnapshot $A }, { Request-VmbRestore $A }, { Remove-VmbCheckpoint $A }) {
            $r = Get-VmbRefusal $call
            $r.exit | Should Be 2
            $r.error | Should BeExactly 'rejected'
            $r.hint | Should Match '^label: must match '
        }
        foreach ($n in 'Get-VM', 'Invoke-Command', 'Register-ScheduledTask', 'Checkpoint-VM', 'Restore-VMSnapshot', 'Remove-VMSnapshot') { (Get-VmbCalls $n).Count | Should Be 0 }
        @(Get-ChildItem -LiteralPath (Get-VmbPath 'jobs')).Count | Should Be 0
        Assert-VmbNotRun
    }
}

Describe 'Guest paths: refused, or passed to the guest as data' {
    It 'copy-from: <Shown> in the guest path' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        $guest = 'C:\t\' + $Payload
        $global:VmbTestContent = [Text.Encoding]::ASCII.GetBytes('hello from the guest')
        $global:VmbTestSha = Get-VmbSha256Hex $global:VmbTestContent
        $global:VmbTestBlocks = @{ info = $script:VmbGuestFileInfo; read = $script:VmbGuestReadChunk }
        $global:VmbFake.Guest = { param($c)
            $sb = $c.Params['ScriptBlock']; $a = @($c.Params['ArgumentList'])
            if ([object]::ReferenceEquals($sb, $global:VmbTestBlocks.info)) { return [pscustomobject]@{ exists = $true; bytes = [long]$global:VmbTestContent.Length; sha256 = $global:VmbTestSha } }
            if ([object]::ReferenceEquals($sb, $global:VmbTestBlocks.read)) {
                $off = [int]$a[1]; $n = [Math]::Min([int]$a[2], $global:VmbTestContent.Length - $off)
                $b = New-Object byte[] $n; [Array]::Copy($global:VmbTestContent, $off, $b, 0, $n)
                return , $b
            }
            throw 'the test guest got a script block it does not know'
        }
        $A = Get-VmbArgsFor @{ guest = $guest }
        if ($guest -match '[\x00-\x1F"*?<>|]') {
            $r = Get-VmbRefusal { Copy-VmbFromGuest $A }
            $r.exit | Should Be 2
            $r.hint | Should Match '^guest path: '
            (Get-VmbCalls 'New-PSSession').Count | Should Be 0
            (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
        } else {
            $r = Copy-VmbFromGuest $A
            $r.ok | Should Be $true
            ($r.guest -ceq $guest) | Should Be $true
            $r.bytes | Should Be 20
            $r.sha256 | Should BeExactly $global:VmbTestSha
            (Test-VmbInTestRoot $r.file) | Should Be $true
            $r.file.StartsWith((Get-VmbPath 'stage\'), [StringComparison]::OrdinalIgnoreCase) | Should Be $true
            [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($r.file)) | Should BeExactly 'hello from the guest'
            $ic = Get-VmbCalls 'Invoke-Command'
            $ic.Count | Should Be 2
            [object]::ReferenceEquals($ic[0].Params['ScriptBlock'], $script:VmbGuestFileInfo) | Should Be $true
            [object]::ReferenceEquals($ic[1].Params['ScriptBlock'], $script:VmbGuestReadChunk) | Should Be $true
            foreach ($c in $ic) { (@($c.Params['ArgumentList'])[0] -ceq $guest) | Should Be $true }
            (Get-VmbCalls 'Remove-PSSession').Count | Should Be 1
        }
        Assert-VmbNotRun
    }

    It 'copy-to: <Shown> in the guest path' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        $guest = 'C:\t\' + $Payload
        $stage = Join-Path $root ('stage\' + (New-VmbId))
        [void][IO.Directory]::CreateDirectory($stage)
        $content = [Text.Encoding]::ASCII.GetBytes('hello to the guest')
        [IO.File]::WriteAllBytes((Join-Path $stage 'upload.bin'), $content)
        $global:VmbTestWritten = New-Object IO.MemoryStream
        $global:VmbTestBlocks = @{ info = $script:VmbGuestFileInfo; write = $script:VmbGuestWriteChunk }
        $global:VmbFake.Guest = { param($c)
            $sb = $c.Params['ScriptBlock']; $a = @($c.Params['ArgumentList'])
            if ([object]::ReferenceEquals($sb, $global:VmbTestBlocks.info)) {
                if ($global:VmbTestWritten.Length -eq 0) { return [pscustomobject]@{ exists = $false; dir = $false } }
                return [pscustomobject]@{ exists = $true; bytes = $global:VmbTestWritten.Length; sha256 = (Get-VmbSha256Hex $global:VmbTestWritten.ToArray()) }
            }
            if ([object]::ReferenceEquals($sb, $global:VmbTestBlocks.write)) { $b = [byte[]]$a[2]; $global:VmbTestWritten.Write($b, 0, $b.Length); return $true }
            throw 'the test guest got a script block it does not know'
        }
        $A = Get-VmbArgsFor @{ guest = $guest; stage = $stage; sha256 = (Get-VmbSha256Hex $content) }
        if ($guest -match '[\x00-\x1F"*?<>|]') {
            $r = Get-VmbRefusal { Copy-VmbToGuest $A }
            $r.exit | Should Be 2
            $r.hint | Should Match '^guest path: '
            (Get-VmbCalls 'New-PSSession').Count | Should Be 0
            (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
        } else {
            $r = Copy-VmbToGuest $A
            $r.ok | Should Be $true
            ($r.guest -ceq $guest) | Should Be $true
            [Text.Encoding]::ASCII.GetString($global:VmbTestWritten.ToArray()) | Should BeExactly 'hello to the guest'
            $ic = Get-VmbCalls 'Invoke-Command'
            $ic.Count | Should Be 3
            [object]::ReferenceEquals($ic[1].Params['ScriptBlock'], $script:VmbGuestWriteChunk) | Should Be $true
            foreach ($c in $ic) {
                (@($c.Params['ArgumentList'])[0] -ceq $guest) | Should Be $true
                $c.Params['ScriptBlock'].ToString().Contains($Payload) | Should Be $false
            }
            [IO.Directory]::Exists($stage) | Should Be $false
        }
        Assert-VmbNotRun
    }
}

Describe 'Names and consumers: refused before any Hyper-V call' {
    It 'refuses <Shown> as a VM name' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $null = New-VmbTestRoot
        $null = New-VmbTestVM
        $A = ConvertTo-VmbArgs @{ name = $Payload; consumer = 'cs101-walkthroughs'; command = 'hostname'; label = 'ch1'; guest = 'C:\x.txt' }
        foreach ($call in { Get-VmbStatus $A }, { Invoke-VmbRun $A }, { Request-VmbStop $A }, { Start-VmbVM $A }, { Request-VmbSnapshot $A }, { Copy-VmbFromGuest $A }) {
            $r = Get-VmbRefusal $call
            $r.exit | Should Be 2
            $r.error | Should BeExactly 'rejected'
        }
        (Get-VmbCalls 'Get-VM').Count | Should Be 0
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
        Assert-VmbNotRun
    }

    It 'refuses <Shown> as a consumer name in Vmb.ps1' -TestCases $script:VmbPayloads {
        param($Shown, $Payload)
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        $ver = 'c' * 64
        [IO.File]::WriteAllText((Join-Path $root 'code\VERSION'), $ver)
        $json = ConvertTo-Json -Compress -InputObject @{ name = 'lab-p1'; consumer = $Payload }
        $res = (@(& (Join-Path $script:VmbBackendPs 'Vmb.ps1') -Verb 'status' -Json $json -Code $ver -Root $root)[0]).Substring(11) | ConvertFrom-Json
        $res.exit | Should Be 2
        $res.hint | Should BeExactly 'bad consumer name'
        (Get-VmbCalls 'Get-VM').Count | Should Be 0
        Assert-VmbNotRun
    }
}

Describe 'Invoke-VmbGuest: values go only into -ArgumentList' {
    It 'passes each value unchanged and retries a failed call with a back-off' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $global:VmbTestTries = 0
        $global:VmbFake.Guest = { param($c) $global:VmbTestTries++; if ($global:VmbTestTries -lt 3) { throw 'the guest is not ready' }; 'ok' }
        $cred = New-VmbGuestCredential (Get-VmbRecord $t.Id)
        $values = @($script:VmbPayloads | ForEach-Object { $_.Payload })
        Invoke-VmbGuest $t.VM $cred $script:VmbGuestLabSetup $values | Should BeExactly 'ok'
        $ic = Get-VmbCalls 'Invoke-Command'
        $ic.Count | Should Be 3
        foreach ($c in $ic) {
            [object]::ReferenceEquals($c.Params['ScriptBlock'], $script:VmbGuestLabSetup) | Should Be $true
            $al = @($c.Params['ArgumentList'])
            $al.Count | Should Be $values.Count
            for ($i = 0; $i -lt $values.Count; $i++) { ($al[$i] -ceq $values[$i]) | Should Be $true }
        }
        (Get-VmbSleepMs) -join ',' | Should BeExactly '5000,10000'
        Assert-VmbNotRun
    }
}
} finally { Remove-VmbTestRoots }
