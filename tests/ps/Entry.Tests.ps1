# Entry.Tests.ps1 - Vmb.ps1 (one verb per call, one VMB-RESULT line) and runner.ps1's Get-InlineScript.
# Vmb.ps1 runs in this process, so the global stubs of VmbTestHelpers.ps1 stand in for every cmdlet it calls; it
# always gets -Root pointing at the test root. Pester 3.4, Windows PowerShell 5.1, ASCII only.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

$script:VmbVersion = 'c' * 64

function Set-VmbCodeVersion { [IO.File]::WriteAllText((Get-VmbPath 'code\VERSION'), $script:VmbVersion) }

# Runs Vmb.ps1 in this process against the test root and returns every line it printed.
function Invoke-VmbEntry {
    param([string]$Verb, [hashtable]$Fields = @{}, [string]$Code = $script:VmbVersion, [switch]$WhatIf)
    if (-not (Test-VmbInTestRoot $script:VmbRoot)) { throw 'SAFETY: Vmb.ps1 runs only against a test root' }
    $json = ConvertTo-Json -InputObject $Fields -Depth 8 -Compress
    , @(& (Join-Path $script:VmbBackendPs 'Vmb.ps1') -Verb $Verb -Json $json -Code $Code -Root $script:VmbRoot -WhatIf:$WhatIf)
}

function ConvertFrom-VmbLine { param([string]$Line) $Line.Substring('VMB-RESULT:'.Length) | ConvertFrom-Json }

# The field names of a result, sorted (New-VmbOk copies a hashtable, whose order is not fixed).
function Get-VmbKeys { param($Object) (@($Object.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object) -join ',') }

$script:VmbCreateFields = @{
    consumer = 'cs101-walkthroughs'; request_hash = ('a' * 64)
    request = @{ name = 'lab-p1'; profile = 'win11-lab'; network = @{ mode = 'lan' }; activation = 'mak'; director = $true
                 lease = @{ keep = $true }; size = @{ cpu = 4; memory_mb = 6144; disk_gb = 127 } }
}

# runner.ps1 reads stdin at the top, so it cannot be dot-sourced: take Get-InlineScript out of its syntax tree.
function Get-VmbInlineScript {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:VmbBackendDir 'runner.ps1'), [ref]$tokens, [ref]$errors)
    $fn = $ast.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-InlineScript' }, $true)
    if (-not $fn) { throw 'runner.ps1 has no Get-InlineScript' }
    $psdir = $script:VmbBackendPs
    & ($fn.Body.GetScriptBlock())
}

function Get-VmbRunnerModuleList {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:VmbBackendDir 'runner.ps1'), [ref]$tokens, [ref]$errors)
    $fn = $ast.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-InlineScript' }, $true)
    @($fn.Body.FindAll({ param($x) $x -is [Management.Automation.Language.StringConstantExpressionAst] -and $x.Value -match '^Vmb[A-Za-z]+\.ps1$' }, $true) |
        ForEach-Object { $_.Value } | Where-Object { $_ -ne 'Vmb.ps1' })
}

try {
Describe 'Vmb.ps1: one verb per call, one VMB-RESULT line' {
    It 'refuses a verb that is not in the switch (exit 2)' {
        $null = New-VmbTestRoot
        Set-VmbCodeVersion
        $out = Invoke-VmbEntry 'frobnicate' @{ consumer = 'cs101-walkthroughs' }
        $out.Count | Should Be 1
        $res = ConvertFrom-VmbLine $out[0]
        $res.ok | Should Be $false
        $res.exit | Should Be 2
        $res.error | Should BeExactly 'rejected'
        $res.hint | Should BeExactly "unknown verb 'frobnicate'"
    }

    It 'refuses the installed-code verb <Verb> when the code version differs (exit 255)' -TestCases @(
        @{ Verb = 'status' }, @{ Verb = 'list' }, @{ Verb = 'run' }, @{ Verb = 'create' }, @{ Verb = 'snapshot' }, @{ Verb = 'activate' }, @{ Verb = 'resume' }
    ) {
        param($Verb)
        $null = New-VmbTestRoot
        Set-VmbCodeVersion
        $null = New-VmbTestVM
        $global:VmbCalls.Clear()
        $res = ConvertFrom-VmbLine (Invoke-VmbEntry $Verb @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; command = 'hostname'; label = 'ch1' } -Code ('d' * 64))[0]
        $res.exit | Should Be 255
        $res.error | Should BeExactly 'code-mismatch'
        $res.hint | Should Match "host code is 'cccccccccccc', the client expects 'dddddddddddd'"
        $global:VmbCalls.Count | Should Be 0
    }

    It 'refuses an empty client version, and a host without code\VERSION (exit 255)' {
        $null = New-VmbTestRoot
        Set-VmbCodeVersion
        (ConvertFrom-VmbLine (Invoke-VmbEntry 'status' @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs' } -Code '')[0]).exit | Should Be 255
        [IO.File]::Delete((Get-VmbPath 'code\VERSION'))
        (ConvertFrom-VmbLine (Invoke-VmbEntry 'status' @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs' } -Code '')[0]).exit | Should Be 255
    }

    It 'skips the version check for inventory' {
        $null = New-VmbTestRoot -NoPolicy
        $res = ConvertFrom-VmbLine (Invoke-VmbEntry 'inventory' @{} -Code ('d' * 64))[0]
        $res.ok | Should Be $true
        $res.exit | Should Be 0
        @($res.vms | Where-Object { $_.name -eq 'Firewall3' }).Count | Should Be 1
        $res.broker.installed | Should Be $false
        $res.memory.available_mb | Should Be 12288
    }

    It 'keeps the verb''s answer when a cmdlet leaks stray objects before it' {
        $null = New-VmbTestRoot
        Set-VmbCodeVersion
        $t = New-VmbTestVM -State 'Off'
        $global:VmbFake.StrayFromStartVM = $true
        # called directly, start returns the stray string and hashtable before its own answer
        $direct = @(Start-VmbVM (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs' }))
        $direct.Count | Should Be 3
        $t.VM.State = 'Off'
        $out = Invoke-VmbEntry 'start' @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs' }
        $out.Count | Should Be 1
        $res = ConvertFrom-VmbLine $out[0]
        $res.ok | Should Be $true
        $res.vm | Should BeExactly 'lab-p1'
        $res.state | Should BeExactly 'Running'
        (Get-VmbKeys $res) | Should BeExactly 'exit,ok,state,vm'
        (Get-VmbCalls 'Start-VM').Count | Should Be 2
    }

    It 'prints one line that starts with VMB-RESULT: and is printable ASCII (\u escapes)' {
        $null = New-VmbTestRoot -NoPolicy
        $name = 'vmb-caf' + [char]0xE9 + [char]0x4E2D + "`t" + [char]0x7F
        $null = Add-VmbFakeVM -Name $name -State 'Off'
        $out = Invoke-VmbEntry 'inventory' @{}
        $out.Count | Should Be 1
        $out[0] | Should MatchExactly '^VMB-RESULT:\{'
        $out[0] | Should MatchExactly '^[\x20-\x7E]+$'
        $out[0] | Should Match '\\u00e9'
        $out[0] | Should Match '\\u4e2d'
        $out[0] | Should Match '\\u007f'
        $res = ConvertFrom-VmbLine $out[0]
        @($res.vms | Where-Object { $_.name -ceq $name }).Count | Should Be 1
    }

    It 'escapes every character outside printable ASCII in ConvertTo-VmbJson' {
        $s = -join @([char]0x0, [char]0x1F, [char]0x80, [char]0xFF, [char]0x2028, [char]0xFEFF)
        $j = ConvertTo-VmbJson @{ v = $s }
        $j | Should MatchExactly '^[\x20-\x7E]+$'
        ($j | ConvertFrom-Json).v | Should BeExactly $s
    }

    It 'returns a refusal as ok, exit, error, hint and findings only' {
        $null = New-VmbTestRoot
        Set-VmbCodeVersion
        $out = Invoke-VmbEntry 'frobnicate' @{ consumer = 'cs101-walkthroughs' }
        (Get-VmbKeys (ConvertFrom-VmbLine $out[0])) | Should BeExactly 'error,exit,findings,hint,ok'
    }

    It 'returns an unexpected error without a stack trace' {
        $null = New-VmbTestRoot -NoPolicy
        $global:VmbFake.CimThrows = 'the fake CIM call failed'
        $out = Invoke-VmbEntry 'inventory' @{}
        $out.Count | Should Be 1
        $res = ConvertFrom-VmbLine $out[0]
        (Get-VmbKeys $res) | Should BeExactly 'error,exit,findings,hint,ok'
        $res.ok | Should Be $false
        $res.exit | Should Be 1
        $res.error | Should BeExactly 'failed'
        $res.hint | Should BeExactly 'the fake CIM call failed'
        $out[0] | Should Not Match '(?i)\.ps1|line:? ?\d+|ScriptStackTrace|StackTrace|at <ScriptBlock>|InvocationInfo|CategoryInfo'
    }

    It 'cuts a long error to one line of 300 characters' {
        $null = New-VmbTestRoot -NoPolicy
        $global:VmbFake.CimThrows = New-Object System.IO.IOException ((('x' * 290) + "`r`n" + ('y' * 200)))
        $res = ConvertFrom-VmbLine (Invoke-VmbEntry 'inventory' @{})[0]
        $res.hint.Length | Should Be 300
        $res.hint | Should MatchExactly '^[\x20-\x7E]+$'
        $res.hint.StartsWith(('x' * 290) + '  y') | Should Be $true
    }

    It 'with -WhatIf, create writes nothing and the result lists what would change' {
        $root = New-VmbTestRoot
        Set-VmbCodeVersion
        $parent = Split-Path -Parent $root
        $before = Get-VmbTreeSnapshot $parent
        $out = Invoke-VmbEntry 'create' $script:VmbCreateFields -WhatIf
        $out.Count | Should Be 1
        $res = ConvertFrom-VmbLine $out[0]
        $res.ok | Should Be $true
        $res.existing | Should Be $false
        $planned = @($res.whatif)
        @($planned | Where-Object { $_ -eq "register and start the SYSTEM task \vm-broker\vmb-job-$($res.job)" }).Count | Should Be 1
        @($planned | Where-Object { $_ -like 'write *\state\vms\*.json' }).Count | Should Be 2
        Get-VmbTreeSnapshot $parent | Should BeExactly $before
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
    }

    It 'without -WhatIf, the same create reserves the VM and has no whatif list' {
        $null = New-VmbTestRoot
        Set-VmbCodeVersion
        $res = ConvertFrom-VmbLine (Invoke-VmbEntry 'create' $script:VmbCreateFields)[0]
        $res.ok | Should Be $true
        ($res.PSObject.Properties.Name -contains 'whatif') | Should Be $false
        (Get-VmbRecord $res.id).state | Should BeExactly 'creating'
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 1
    }
}

Describe 'runner.ps1 Get-InlineScript: the scripts sent inline before the code folder exists' {
    It 'names the same modules as the dot-source block of Vmb.ps1, in the same order' {
        $mods = Get-VmbModuleList
        $mods.Count | Should Be 7
        ((Get-VmbRunnerModuleList) -join ',') | Should BeExactly ($mods -join ',')
    }

    It 'contains every module''s whole text, in order' {
        $inline = Get-VmbInlineScript
        $pos = -1
        foreach ($m in (Get-VmbModuleList)) {
            $i = $inline.IndexOf([IO.File]::ReadAllText((Join-Path $script:VmbBackendPs $m)), [StringComparison]::Ordinal)
            ($i -gt $pos) | Should Be $true
            $pos = $i
        }
    }

    It 'keeps the rest of Vmb.ps1 around the modules and wraps it for -ArgumentList' {
        $inline = Get-VmbInlineScript
        $main = [IO.File]::ReadAllText((Join-Path $script:VmbBackendPs 'Vmb.ps1'))
        $b = $main.IndexOf('#VMB-DOTSOURCE-BEGIN'); $e = $main.IndexOf('#VMB-DOTSOURCE-END') + '#VMB-DOTSOURCE-END'.Length
        $inline.Contains($main.Substring(0, $b)) | Should Be $true
        $inline.Contains($main.Substring($e)) | Should Be $true
        $inline.StartsWith('param($v, $j, $c, $r, $w)') | Should Be $true
        $inline.TrimEnd() | Should Match '\} -Verb \$v -Json \$j -Code \$c -Root \$r -WhatIf:\$w$'
    }

    It 'parses' {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput((Get-VmbInlineScript), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should Be 0
    }

    It 'contains no dot-source line and no dot-source markers' {
        $inline = Get-VmbInlineScript
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($inline, [ref]$tokens, [ref]$errors)
        @($ast.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] -and "$($x.InvocationOperator)" -eq 'Dot' }, $true)).Count | Should Be 0
        $inline | Should Not Match '(?m)^\s*\.\s'
        $inline | Should Not Match 'VMB-DOTSOURCE'
        $inline | Should Not Match 'Join-Path \$PSScriptRoot'
    }

    It 'runs in this process like Vmb.ps1: inventory, and the code check for an installed-code verb' {
        $root = New-VmbTestRoot -NoPolicy
        $sb = [scriptblock]::Create((Get-VmbInlineScript))
        $out = @(& $sb 'inventory' '{}' '' $root $false)
        $out.Count | Should Be 1
        (ConvertFrom-VmbLine $out[0]).ok | Should Be $true
        Set-VmbCodeVersion
        $res = ConvertFrom-VmbLine (@(& $sb 'status' '{"name":"lab-p1","consumer":"cs101-walkthroughs"}' ('d' * 64) $root $false)[0])
        $res.exit | Should Be 255
    }
}
} finally { Remove-VmbTestRoots }
