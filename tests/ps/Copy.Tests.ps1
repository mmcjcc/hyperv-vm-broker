# Copy.Tests.ps1 - Copy-VmbChunks (docs/design.md 6.5): 4 MiB chunks, in order, throttled to copy_mbps.
# The read and write blocks are fakes; Start-Sleep is the recording stub. Pester 3.4, Windows PowerShell 5.1, ASCII only.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

# Fake ends of a copy: reads slice $global:VmbTestSrc, writes append to $global:VmbTestDst and are logged.
function Reset-VmbCopy {
    param([int]$Bytes)
    $global:VmbTestSrc = New-Object byte[] $Bytes
    (New-Object Random 7).NextBytes($global:VmbTestSrc)
    $global:VmbTestDst = New-Object IO.MemoryStream
    $global:VmbTestReads = New-Object System.Collections.ArrayList
    $global:VmbTestWrites = New-Object System.Collections.ArrayList
}

$script:VmbRead = { param($o, $c)
    [void]$global:VmbTestReads.Add("$o+$c")
    $c = [int][Math]::Max(0, [Math]::Min($c, $global:VmbTestSrc.Length - $o))
    $b = New-Object byte[] $c
    if ($c) { [Array]::Copy($global:VmbTestSrc, [long]$o, $b, 0, $c) }
    , $b
}
$script:VmbWrite = { param($o, $b, $f)
    [void]$global:VmbTestWrites.Add([pscustomobject]@{ Off = [long]$o; Len = $b.Length; First = [bool]$f })
    $global:VmbTestDst.Write($b, 0, $b.Length)
}

try {
Describe 'Copy-VmbChunks: chunked and throttled host-side copies' {
    It 'moves a 10 MiB file in 4 MiB chunks, in order, byte for byte' {
        $null = New-VmbTestRoot
        Reset-VmbCopy (10MB)
        $n = Copy-VmbChunks $script:VmbRead $script:VmbWrite ([long]10MB) 1000.0
        $n | Should Be (10MB)
        ($global:VmbTestReads -join ' ') | Should BeExactly '0+4194304 4194304+4194304 8388608+2097152'
        (@($global:VmbTestWrites | ForEach-Object { "$($_.Off):$($_.Len):$($_.First)" }) -join ' ') | Should BeExactly '0:4194304:True 4194304:4194304:False 8388608:2097152:False'
        (Get-VmbSha256Hex $global:VmbTestDst.ToArray()) | Should BeExactly (Get-VmbSha256Hex $global:VmbTestSrc)
    }

    It 'copies a zero-length file with one empty first write' {
        $null = New-VmbTestRoot
        Reset-VmbCopy 0
        $n = Copy-VmbChunks $script:VmbRead $script:VmbWrite ([long]0) 10.0
        $n | Should Be 0
        ($global:VmbTestReads -join ' ') | Should BeExactly '0+0'
        (@($global:VmbTestWrites | ForEach-Object { "$($_.Off):$($_.Len):$($_.First)" }) -join ' ') | Should BeExactly '0:0:True'
        (Get-VmbSleepMs).Count | Should Be 0
    }

    It 'copies a file of exactly one chunk, and one a byte longer' {
        $null = New-VmbTestRoot
        Reset-VmbCopy (4MB)
        (Copy-VmbChunks $script:VmbRead $script:VmbWrite ([long]4MB) 1000.0) | Should Be (4MB)
        $global:VmbTestWrites.Count | Should Be 1
        Reset-VmbCopy (4MB + 1)
        (Copy-VmbChunks $script:VmbRead $script:VmbWrite ([long](4MB + 1)) 1000.0) | Should Be (4MB + 1)
        (@($global:VmbTestWrites | ForEach-Object { $_.Len }) -join ',') | Should BeExactly '4194304,1'
    }

    It 'sleeps to hold the rate: at 2 MB/s, about 2, 4 and 5 s after the three chunks' {
        $null = New-VmbTestRoot
        Reset-VmbCopy (10MB)
        $null = Copy-VmbChunks $script:VmbRead $script:VmbWrite ([long]10MB) 2.0
        $ms = Get-VmbSleepMs
        $ms.Count | Should Be 3
        $want = @(2000, 4000, 5000)
        for ($i = 0; $i -lt 3; $i++) {
            # the stubbed sleep returns at once, so each wait is the whole time still owed, less the copying itself
            ($ms[$i] -le $want[$i]) | Should Be $true
            ($ms[$i] -gt $want[$i] - 1500) | Should Be $true
        }
        (Get-VmbCalls 'Start-Sleep')[0].Params.ContainsKey('Milliseconds') | Should Be $true
    }

    It 'does not sleep when the copy is already slower than the cap' {
        $null = New-VmbTestRoot
        Reset-VmbCopy (10MB)
        $null = Copy-VmbChunks $script:VmbRead $script:VmbWrite ([long]10MB) 1000.0
        (Get-VmbSleepMs).Count | Should Be 0
    }

    It 'stops when the source runs dry before the length' {
        $null = New-VmbTestRoot
        Reset-VmbCopy (1MB)
        { Copy-VmbChunks $script:VmbRead $script:VmbWrite ([long]10MB) 1000.0 } | Should Throw 'the copy stopped short'
    }
}

Describe 'Test-VmbCopyWindow: heavy disk work only inside the copy window' {
    It 'is open at <At> for 01:00 to 06:00: <Open>' -TestCases @(
        @{ At = '00:59'; Open = $false }, @{ At = '01:00'; Open = $true }, @{ At = '03:30'; Open = $true },
        @{ At = '05:59'; Open = $true }, @{ At = '06:00'; Open = $false }, @{ At = '13:00'; Open = $false }
    ) {
        param($At, $Open)
        $t = [TimeSpan]::Parse($At)
        $now = New-Object DateTime 2026, 10, 12, $t.Hours, $t.Minutes, 0
        Test-VmbCopyWindow (Get-VmbTestPolicy) $now | Should Be $Open
    }

    It 'wraps around midnight for 22:00 to 02:00: open at <At>: <Open>' -TestCases @(
        @{ At = '21:59'; Open = $false }, @{ At = '22:00'; Open = $true }, @{ At = '23:30'; Open = $true },
        @{ At = '00:00'; Open = $true }, @{ At = '01:59'; Open = $true }, @{ At = '02:00'; Open = $false }
    ) {
        param($At, $Open)
        $pol = Get-VmbTestPolicy
        $pol.copy_window.start = '22:00'
        $pol.copy_window.end = '02:00'
        $t = [TimeSpan]::Parse($At)
        $now = New-Object DateTime 2026, 10, 12, $t.Hours, $t.Minutes, 0
        Test-VmbCopyWindow $pol $now | Should Be $Open
    }
}
} finally { Remove-VmbTestRoots }
