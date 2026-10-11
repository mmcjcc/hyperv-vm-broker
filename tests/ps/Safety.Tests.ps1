# Safety.Tests.ps1 - the stubs are in place, record their calls, and keep files inside the test root.
# Pester 3.4, Windows PowerShell 5.1, ASCII only. No test here calls a command whose real version changes anything.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

try {
Describe 'Safety: the stubs shadow every command that could change this laptop' {
    It 'resolves each stub name to the stub function' {
        { Assert-VmbStubsInPlace } | Should Not Throw
        foreach ($n in 'New-VM', 'Set-VM', 'Start-VM', 'Stop-VM', 'Remove-VM', 'Checkpoint-VM', 'Restore-VMSnapshot', 'Remove-VMSnapshot',
                       'Set-VMNetworkAdapter', 'Set-VMProcessor', 'New-VHD', 'Mount-VHD', 'Mount-DiskImage', 'Initialize-Disk', 'Format-Volume',
                       'Register-ScheduledTask', 'Start-ScheduledTask', 'Unregister-ScheduledTask', 'New-SelfSignedCertificate',
                       'Invoke-Command', 'New-PSSession', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Acl', 'Remove-Item',
                       'Stop-Process', 'Stop-Computer', 'Restart-Computer', 'reg.exe', 'Start-Sleep', 'Get-VM', 'Get-CimInstance') {
            "$((Get-Command -Name $n).CommandType)" | Should Be 'Function'
        }
    }

    It 'resolves them from inside a backend function as well' {
        $null = New-VmbTestRoot
        $null = Test-VmbCapacity (Get-VmbPolicy) 1024
        (Get-VmbCalls 'Get-VM').Count | Should Be 1
        (Get-VmbCalls 'Get-CimInstance').Count | Should Be 1
    }

    It 'covers every command the backend scripts name' {
        { Assert-VmbBackendCommandsCovered $script:VmbBackendDir } | Should Not Throw
    }

    It 'records a call with its named, switch and positional arguments' {
        $null = New-VmbTestRoot
        $null = Get-ScheduledTask -TaskName 'vmb-none' -TaskPath '\vmb-none\' -ErrorAction SilentlyContinue
        Get-VMHostSupportedVersion -Default | Out-Null
        $c = Get-VmbCalls 'Get-ScheduledTask'
        $c.Count | Should Be 1
        $c[0].Params['TaskName'] | Should BeExactly 'vmb-none'
        $c[0].Params['TaskPath'] | Should BeExactly '\vmb-none\'
        $c[0].Params['ErrorAction'] | Should BeExactly 'SilentlyContinue'
        (Get-VmbCalls 'Get-VMHostSupportedVersion')[0].Params['Default'] | Should Be $true
        $v = '-not-a-parameter'
        $null = Get-ScheduledTaskInfo $v -TaskName:'x'
        $i = (Get-VmbCalls 'Get-ScheduledTaskInfo')[0]
        $i.Positional[0] | Should BeExactly '-not-a-parameter'
        $i.Params['TaskName'] | Should BeExactly 'x'
    }

    It 'refuses a file command outside the test root, and records the refusal' {
        $null = New-VmbTestRoot
        { Remove-Item -LiteralPath 'C:\vmb-pester-nothing-here' -Recurse -Force } | Should Throw
        { Copy-Item -LiteralPath (Join-Path $env:TEMP 'vmb-pester-none\x') -Destination 'C:\vmb-pester-nothing-here' } | Should Throw
        $calls = @($global:VmbCalls | Where-Object { $_.Refused })
        $calls.Count | Should Be 2
    }

    It 'acts on files inside the test root' {
        $root = New-VmbTestRoot
        $f = Join-Path $root 'stage\x.txt'
        [IO.File]::WriteAllText($f, 'x')
        Remove-Item -LiteralPath $f -Force
        [IO.File]::Exists($f) | Should Be $false
    }

    It 'throws for a command that must never run on the host' {
        $null = New-VmbTestRoot
        { Get-LocalUser -Name 'vmb-none' } | Should Throw
        { whoami } | Should Throw
        (Get-VmbCalls 'Get-LocalUser').Count | Should Be 1
    }

    It 'gives each test a fresh root under %TEMP%\vmb-pester-*' {
        $a = New-VmbTestRoot
        $b = New-VmbTestRoot
        $a | Should Not Be $b
        $b | Should Match 'vmb-pester-[0-9a-f]{12}\\vmb$'
        (Test-VmbInTestRoot $b) | Should Be $true
        (Test-VmbInTestRoot 'C:\VMs\vmb') | Should Be $false
        (Test-VmbInTestRoot (Join-Path $b '..\..\..\x')) | Should Be $false
        $script:VmbRoot | Should BeExactly $b
    }
}
} finally { Remove-VmbTestRoots }
