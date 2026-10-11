# GuestBlocks.Tests.ps1 - some of the backend's own in-guest script blocks, run HERE under the stubs, on files
# inside the test root only: the director relay (its token path moved into the test root, Invoke-WebRequest the
# recording stub) and the chunked file blocks behind copy-to and copy-from. Blocks that change a machine (users,
# firewall, registry, tasks, the WU and run blocks) are never run. Pester 3.4, Windows PowerShell 5.1, ASCII only.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

# The backend's relay text with only its token path moved into the test root, and a test token there.
function New-VmbTestRelay {
    $text = $script:VmbGuestDirectorRelay.ToString()
    $tokPath = "'C:\ProgramData\LabDirector\token.txt'"
    $n = ([regex]::Matches($text, [regex]::Escape($tokPath))).Count
    if ($n -ne 1) { throw "the relay names its token path $n times; update this test" }
    $global:VmbTestToken = Join-Path $script:VmbRoot 'guest\LabDirector\token.txt'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $global:VmbTestToken))
    [IO.File]::WriteAllText($global:VmbTestToken, "fake-director-token`r`n")
    [scriptblock]::Create($text.Replace($tokPath, "'$($global:VmbTestToken)'"))
}

# The director's answers, one per request, in order; 'THROW:<text>' makes the request fail without a response.
function Set-VmbTestDirector {
    param([string[]]$Answers)
    $global:VmbTestAnswers = New-Object System.Collections.Queue
    foreach ($a in $Answers) { $global:VmbTestAnswers.Enqueue($a) }
    $global:VmbFake.Web = { param($c)
        $a = [string]$global:VmbTestAnswers.Dequeue()
        if ($a -ceq 'TIMEOUT') { throw (New-Object System.Net.WebException 'The operation has timed out', ([System.Net.WebExceptionStatus]::Timeout)) }
        if ($a.StartsWith('THROW:')) { throw $a.Substring(6) }
        [pscustomobject]@{ RawContentStream = (New-Object IO.MemoryStream (, [Text.Encoding]::UTF8.GetBytes($a))) }
    }
}

# Steps as the host sends them (Invoke-VmbDirectorSteps).
function ConvertTo-VmbStepsJson { param([object[]]$Steps) ConvertTo-Json -InputObject @($Steps) -Depth 4 -Compress }

# The relay returns its answers as ONE array object (, @($answers)); unroll it once, as Invoke-VmbDirectorSteps does.
function Invoke-VmbTestRelay {
    param([scriptblock]$Relay, [string]$Json)
    , @(& $Relay $Json | ForEach-Object { $_ })
}

try {
Describe 'VmbGuestDirectorRelay: one request per step, in order' {
    It 'posts each step on its own, with the token, the body as UTF-8 and the step timeout' {
        $null = New-VmbTestRoot
        $relay = New-VmbTestRelay
        Set-VmbTestDirector @('{"ok":true,"n":1}', '{"ok":true,"n":2}', '{"ok":true,"n":3}')
        $text = 'caf' + [char]0xE9 + ' "quoted" $(not code)'
        $json = ConvertTo-VmbStepsJson @(
            [ordered]@{ endpoint = '/type'; body = (ConvertTo-Json -Compress -InputObject @{ text = $text }); timeout_s = 30 }
            [ordered]@{ endpoint = '/key'; body = '{"combo":"enter"}'; timeout_s = 5 }
            [ordered]@{ endpoint = '/screenshot'; body = '{}'; timeout_s = 60 }
        )
        $answers = Invoke-VmbTestRelay $relay $json
        $web = Get-VmbCalls 'Invoke-WebRequest'
        (@($web | ForEach-Object { [string]$_.Params['Uri'] }) -join ' ') | Should BeExactly 'http://127.0.0.1:47800/type http://127.0.0.1:47800/key http://127.0.0.1:47800/screenshot'
        $web.Count | Should Be 3
        ($answers -join ' ') | Should BeExactly '{"ok":true,"n":1} {"ok":true,"n":2} {"ok":true,"n":3}'
        ([Text.Encoding]::UTF8.GetString([byte[]]$web[0].Params['Body']) | ConvertFrom-Json).text | Should BeExactly $text
        [Text.Encoding]::UTF8.GetString([byte[]]$web[1].Params['Body']) | Should BeExactly '{"combo":"enter"}'
        foreach ($w in $web) {
            $w.Params['Method'] | Should BeExactly 'Post'
            $w.Params['Headers']['Authorization'] | Should BeExactly 'Bearer fake-director-token'
            $w.Params['ContentType'] | Should BeExactly 'application/json; charset=utf-8'
            $w.Params['MaximumRedirection'] | Should Be 0
        }
        (@($web | ForEach-Object { $_.Params['TimeoutSec'] }) -join ',') | Should BeExactly '30,5,60'
        # the director starts no input after the relay's own timeout
        (@($web | ForEach-Object { $_.Params['Headers']['X-Vmb-Timeout'] }) -join ',') | Should BeExactly '30,5,60'
    }

    It 'answers relay-timeout, not no-director, when the director does not answer in time' {
        $null = New-VmbTestRoot
        $relay = New-VmbTestRelay
        Set-VmbTestDirector @('TIMEOUT')
        $answers = Invoke-VmbTestRelay $relay (ConvertTo-VmbStepsJson @([ordered]@{ endpoint = '/type'; body = '{}'; timeout_s = 40 }))
        $a = $answers[0] | ConvertFrom-Json
        $a.ok | Should Be $false
        $a.error | Should BeExactly 'relay-timeout'
        $a.detail | Should Match '40 s'
    }

    It 'sends a single step' {
        $null = New-VmbTestRoot
        $relay = New-VmbTestRelay
        Set-VmbTestDirector @('{"ok":true}')
        $answers = Invoke-VmbTestRelay $relay (ConvertTo-VmbStepsJson @([ordered]@{ endpoint = '/health'; body = '{}'; timeout_s = 10 }))
        $answers.Count | Should Be 1
        [string](Get-VmbCalls 'Invoke-WebRequest')[0].Params['Uri'] | Should BeExactly 'http://127.0.0.1:47800/health'
    }

    It 'stops at the first step that does not answer ok:true' {
        $null = New-VmbTestRoot
        $relay = New-VmbTestRelay
        Set-VmbTestDirector @('{"ok":true}', '{"ok":false,"error":"timeout"}', '{"ok":true}')
        $steps = @(1..3 | ForEach-Object { [ordered]@{ endpoint = '/wait_for'; body = '{}'; timeout_s = 5 } })
        $answers = Invoke-VmbTestRelay $relay (ConvertTo-VmbStepsJson $steps)
        $answers.Count | Should Be 2
        (Get-VmbCalls 'Invoke-WebRequest').Count | Should Be 2
        ($answers[1] | ConvertFrom-Json).error | Should BeExactly 'timeout'
    }

    It 'turns a failed request into an ok:false answer that is still valid JSON' {
        $null = New-VmbTestRoot
        $relay = New-VmbTestRelay
        Set-VmbTestDirector @('THROW:connect to "127.0.0.1:47800" failed at C:\x\y')
        $answers = Invoke-VmbTestRelay $relay (ConvertTo-VmbStepsJson @([ordered]@{ endpoint = '/health'; body = '{}'; timeout_s = 10 }))
        $answers.Count | Should Be 1
        $a = $answers[0] | ConvertFrom-Json
        $a.ok | Should Be $false
        $a.error | Should BeExactly 'no-director'
        $a.detail | Should Match 'connect to'
    }

    It 'answers no-director, and sends nothing, when the token file is missing' {
        $null = New-VmbTestRoot
        $relay = New-VmbTestRelay
        [IO.File]::Delete($global:VmbTestToken)
        Set-VmbTestDirector @('{"ok":true}')
        $answers = Invoke-VmbTestRelay $relay (ConvertTo-VmbStepsJson @([ordered]@{ endpoint = '/health'; body = '{}'; timeout_s = 10 }))
        ($answers[0] | ConvertFrom-Json).error | Should BeExactly 'no-director'
        (Get-VmbCalls 'Invoke-WebRequest').Count | Should Be 0
    }
}

Describe 'Guest file blocks behind copy-to and copy-from, run on files in the test root' {
    # The "guest": the backend's own file blocks, run here, and only on paths inside the test root. -ReadFailAt N
    # makes the Nth chunk read fail (a dropped session); -InfoSha makes the guest report another SHA-256.
    function Set-VmbLocalGuest {
        param([int]$ReadFailAt = 0, [string]$InfoSha = '')
        $global:VmbTestFileBlocks = @($script:VmbGuestFileInfo.ToString(), $script:VmbGuestReadChunk.ToString(), $script:VmbGuestWriteChunk.ToString())
        $global:VmbTestReads = 0
        $global:VmbTestReadFailAt = $ReadFailAt
        $global:VmbTestInfoSha = $InfoSha
        $global:VmbFake.Guest = { param($c)
            $sb = $c.Params['ScriptBlock']; $a = @($c.Params['ArgumentList'])
            if ($global:VmbTestFileBlocks -cnotcontains $sb.ToString()) { throw 'the local guest runs only the file blocks' }
            if (-not (Test-VmbInTestRoot ([string]$a[0]))) { throw 'SAFETY: a guest path outside the test root' }
            if ($sb.ToString() -ceq $global:VmbTestFileBlocks[1]) {
                $global:VmbTestReads++
                if ($global:VmbTestReadFailAt -and $global:VmbTestReads -ge $global:VmbTestReadFailAt) { throw 'the PowerShell Direct session dropped' }
            }
            if ($global:VmbTestInfoSha -and $sb.ToString() -ceq $global:VmbTestFileBlocks[0]) {
                $o = & $sb @a
                if ($o.exists) { $o.sha256 = $global:VmbTestInfoSha }
                return $o
            }
            & $sb @a
        }
    }

    function New-VmbTestStage {
        param([byte[]]$Bytes)
        $stage = Get-VmbPath ('stage\' + (New-VmbId))
        [void][IO.Directory]::CreateDirectory($stage)
        [IO.File]::WriteAllBytes((Join-Path $stage 'upload.bin'), $Bytes)
        $stage
    }

    It 'moves 9 MiB and 3 bytes to the guest and back, unchanged, in 4 MiB chunks' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbLocalGuest
        $guest = Join-Path $root 'guest\sub\data.bin'
        $src = New-Object byte[] (9MB + 3)
        (New-Object Random 11).NextBytes($src)
        $sha = Get-VmbSha256Hex $src
        $stage = New-VmbTestStage $src
        $up = Copy-VmbToGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = $guest; stage = $stage; sha256 = $sha })
        $up.ok | Should Be $true
        $up.bytes | Should Be (9MB + 3)
        (Get-VmbSha256Hex ([IO.File]::ReadAllBytes($guest))) | Should BeExactly $sha
        [IO.Directory]::Exists($stage) | Should Be $false
        $writes = @((Get-VmbCalls 'Invoke-Command') | Where-Object { $_.Params['ScriptBlock'].ToString() -ceq $script:VmbGuestWriteChunk.ToString() })
        (@($writes | ForEach-Object { $a = @($_.Params['ArgumentList']); "$($a[1]):$(([byte[]]$a[2]).Length):$($a[3])" }) -join ' ') | Should BeExactly '0:4194304:True 4194304:4194304:False 8388608:1048579:False'

        $global:VmbCalls.Clear()
        $down = Copy-VmbFromGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = $guest })
        $down.ok | Should Be $true
        $down.sha256 | Should BeExactly $sha
        $down.bytes | Should Be (9MB + 3)
        (Get-VmbSha256Hex ([IO.File]::ReadAllBytes($down.file))) | Should BeExactly $sha
        $down.file.StartsWith((Get-VmbPath 'stage\'), [StringComparison]::OrdinalIgnoreCase) | Should Be $true
        [IO.Path]::GetFileName($down.file) | Should BeExactly 'data.bin'
    }

    It 'copy-to says already when the guest has the same file, and writes nothing' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbLocalGuest
        $guest = Join-Path $root 'guest\same.txt'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $guest))
        $b = [Text.Encoding]::ASCII.GetBytes('same content')
        [IO.File]::WriteAllBytes($guest, $b)
        $r = Copy-VmbToGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = $guest; stage = (New-VmbTestStage $b); sha256 = (Get-VmbSha256Hex $b) })
        $r.already | Should Be $true
        @((Get-VmbCalls 'Invoke-Command') | Where-Object { $_.Params['ScriptBlock'].ToString() -ceq $script:VmbGuestWriteChunk.ToString() }).Count | Should Be 0
    }

    It 'copy-to refuses to replace other content unless asked to overwrite' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbLocalGuest
        $guest = Join-Path $root 'guest\other.txt'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $guest))
        [IO.File]::WriteAllText($guest, 'old content, longer than the new one')
        $b = [Text.Encoding]::ASCII.GetBytes('new content')
        $r = Get-VmbRefusal { Copy-VmbToGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = $guest; stage = (New-VmbTestStage $b); sha256 = (Get-VmbSha256Hex $b) }) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'exists'
        [IO.File]::ReadAllText($guest) | Should BeExactly 'old content, longer than the new one'
        $ok = Copy-VmbToGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = $guest; stage = (New-VmbTestStage $b); sha256 = (Get-VmbSha256Hex $b); overwrite = $true })
        $ok.ok | Should Be $true
        [IO.File]::ReadAllText($guest) | Should BeExactly 'new content'
    }

    It 'copy-to refuses a guest path that is a folder' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbLocalGuest
        $guest = Join-Path $root 'guest\afolder'
        [void][IO.Directory]::CreateDirectory($guest)
        $b = [Text.Encoding]::ASCII.GetBytes('x')
        $r = Get-VmbRefusal { Copy-VmbToGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = $guest; stage = (New-VmbTestStage $b); sha256 = (Get-VmbSha256Hex $b) }) }
        $r.exit | Should Be 2
        $r.hint | Should Match 'is a folder'
    }

    It 'copy-to refuses a stage whose file does not match the uploaded SHA-256' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbLocalGuest
        $b = [Text.Encoding]::ASCII.GetBytes('x')
        $r = Get-VmbRefusal { Copy-VmbToGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = (Join-Path $root 'guest\x.txt'); stage = (New-VmbTestStage $b); sha256 = ('0' * 64) }) }
        $r.exit | Should Be 1
        $r.hint | Should Match 'SHA-256 mismatch'
        (Get-VmbCalls 'New-PSSession').Count | Should Be 0
    }

    It 'copy-from removes its stage folder when the copy fails half way (no partial file left on the host)' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbLocalGuest -ReadFailAt 2
        $guest = Join-Path $root 'guest\recording.mkv'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $guest))
        [IO.File]::WriteAllBytes($guest, (New-Object byte[] (9MB)))
        $r = $null
        try { $null = Copy-VmbFromGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = $guest }) } catch { $r = Get-VmbErrorInfo $_ }
        $r | Should Not BeNullOrEmpty
        $r.hint | Should Match 'session dropped'
        (Get-VmbCalls 'Remove-PSSession').Count | Should Be 1
        @(Get-ChildItem -LiteralPath (Get-VmbPath 'stage')).Count | Should Be 0
    }

    It 'copy-from removes its stage folder when the SHA-256 does not match' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbLocalGuest -InfoSha ('0' * 64)
        $guest = Join-Path $root 'guest\notes.txt'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $guest))
        [IO.File]::WriteAllText($guest, 'changed while copying')
        $r = Get-VmbRefusal { Copy-VmbFromGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = $guest }) }
        $r.exit | Should Be 1
        $r.hint | Should Match 'SHA-256 mismatch'
        @(Get-ChildItem -LiteralPath (Get-VmbPath 'stage')).Count | Should Be 0
    }

    It 'copy-from refuses a guest file that is not there' {
        $root = New-VmbTestRoot
        $null = New-VmbTestVM
        Set-VmbLocalGuest
        $r = Get-VmbRefusal { Copy-VmbFromGuest (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'cs101-walkthroughs'; guest = (Join-Path $root 'guest\none.txt') }) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'missing'
        @(Get-ChildItem -LiteralPath (Get-VmbPath 'stage')).Count | Should Be 0
    }
}
} finally { Remove-VmbTestRoots }
