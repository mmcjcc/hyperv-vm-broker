<#
.SYNOPSIS
vm-broker's laptop-side runner (direct mode, docs/design.md 3.2): one WinRM session to a Hyper-V host per call.

.DESCRIPTION
Reads one JSON envelope from stdin (never from the command line: it can carry a product key), loads the host
credential with netadmin's Get-HomelabCredential.ps1 and a -ConfigPath that does not exist (a missing DPAPI cache
is an error, never a read of netadmin's config.txt), opens a Kerberos WinRM session, and runs the verb:
  call      the host's installed code: <vmb_root>\code\Vmb.ps1 -Verb -Json -Code
  inline    the same scripts sent from this laptop (before the code folder exists: inventory, baseline, install)
  upload    a new stage folder (inline or installed), the files copied into it, then the verb with args.stage
  download  the verb (copy-from), then the staged file copied here, then the stage removed
  iso       copy-iso in a disconnected session (it outlives this process), with the credential passed explicitly
Prints "VMB-RESULT:{json}" (and "VMB-DOWNLOAD:{json}" for download). Never prints the envelope or the credential.
Windows PowerShell 5.1, ASCII only. Consumer strings go only into -ArgumentList.
#>
$ErrorActionPreference = 'Stop'

function Out-Result($h) {
    $j = ConvertTo-Json -InputObject $h -Depth 8 -Compress
    'VMB-RESULT:' + [regex]::Replace($j, '[^\x20-\x7E]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}
function Fail([int]$exit, [string]$word, [string]$hint) {
    Out-Result ([ordered]@{ ok = $false; exit = $exit; error = $word; hint = ($hint -replace '[^\x20-\x7E]', ' ') })
    exit 0
}

$stdin = [Console]::OpenStandardInput()
$ms = New-Object IO.MemoryStream
$stdin.CopyTo($ms)
$Req = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
$ms.Dispose()

$psdir = Join-Path $PSScriptRoot 'ps'
$fqdn = [string]$Req.fqdn
if ($fqdn -cnotmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+\z') { Fail 2 'rejected' 'bad host name' }
$root = [string]$Req.vmb_root
if ($root -notmatch '^[A-Za-z]:\\[A-Za-z0-9\\_-]+\\vmb\z') { Fail 2 'rejected' 'bad vmb_root' }
$verb = [string]$Req.verb
$json = ConvertTo-Json -InputObject $Req.args -Depth 12 -Compress
$code = [string]$Req.code
$whatIf = [bool]$Req.whatif

# ---- the credential: DPAPI cache only ----
$loader = [string]$Req.loader
if (-not $loader -or -not (Test-Path -LiteralPath $loader -PathType Leaf)) { Fail 255 'unreachable' 'VMB_CREDENTIAL_LOADER does not point at Get-HomelabCredential.ps1' }
$noConfig = Join-Path $env:TEMP ('vmb-no-config-' + [guid]::NewGuid().ToString('N') + '\config.txt')
if (Test-Path -LiteralPath $noConfig) { Fail 255 'unreachable' 'the stand-in config path exists; refusing' }
try { $cred = & $loader -ConfigPath $noConfig }
catch { Fail 255 'unreachable' 'no netadmin credential cache on this laptop; ask the operator to refresh it' }
if (-not ($cred -is [pscredential])) { Fail 255 'unreachable' 'the credential loader returned no credential' }

function Get-InlineScript {
    $main = [IO.File]::ReadAllText((Join-Path $psdir 'Vmb.ps1'))
    $b = $main.IndexOf('#VMB-DOTSOURCE-BEGIN'); $e = $main.IndexOf('#VMB-DOTSOURCE-END')
    if ($b -lt 0 -or $e -lt $b) { throw 'Vmb.ps1 has no dot-source markers' }
    $mods = foreach ($m in 'VmbCommon.ps1', 'VmbJobs.ps1', 'VmbHost.ps1', 'VmbGuestBlocks.ps1', 'VmbLab.ps1', 'VmbOps.ps1', 'VmbActivation.ps1') {
        [IO.File]::ReadAllText((Join-Path $psdir $m))
    }
    $body = $main.Substring(0, $b) + ($mods -join "`r`n") + $main.Substring($e + '#VMB-DOTSOURCE-END'.Length)
    # our own files only; consumer strings stay in -ArgumentList
    "param(`$v, `$j, `$c, `$r, `$w)`r`n& {`r`n$body`r`n} -Verb `$v -Json `$j -Code `$c -Root `$r -WhatIf:`$w"
}

$installed = { param($r, $v, $j, $c, $w) Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; & (Join-Path $r 'code\Vmb.ps1') -Verb $v -Json $j -Code $c -WhatIf:$w }

function Invoke-Verb($session, [string]$v, [string]$j, [bool]$inline) {
    if ($inline) {
        $sb = [scriptblock]::Create((Get-InlineScript))
        $out = Invoke-Command -Session $session -ScriptBlock $sb -ArgumentList $v, $j, $code, $root, $whatIf
    } else {
        $out = Invoke-Command -Session $session -ScriptBlock $installed -ArgumentList $root, $v, $j, $code, $whatIf
    }
    $line = @($out | Where-Object { $_ -is [string] -and $_.StartsWith('VMB-RESULT:') })[-1]
    if (-not $line) { return $null }
    $line
}

$session = $null
try {
    try { $session = New-PSSession -ComputerName $fqdn -Credential $cred -Authentication Kerberos -ErrorAction Stop }
    catch { Fail 255 'unreachable' ("WinRM to $fqdn failed: " + ("$($_.Exception.Message)" -split "`n")[0]) }
    $mode = [string]$Req.mode
    switch ($mode) {
        'call' { $l = Invoke-Verb $session $verb $json $false; if ($l) { $l } else { Fail 1 'failed' 'the host printed no result' } }
        'inline' { $l = Invoke-Verb $session $verb $json $true; if ($l) { $l } else { Fail 1 'failed' 'the host printed no result' } }
        'upload' {
            $sl = Invoke-Verb $session 'stage-new' '{}' ([bool]$Req.stage_inline)
            $st = ($sl.Substring(11) | ConvertFrom-Json)
            if (-not $st.ok) { $sl; break }
            $stage = [string]$st.stage
            try {
                foreach ($f in @($Req.upload)) {
                    $rel = [string]$f.rel
                    if ($rel -match '\.\.' -or $rel -notmatch '^[A-Za-z0-9_][A-Za-z0-9_. \\-]*\z') { Fail 2 'rejected' "bad upload path $rel" }
                    $dest = $stage.TrimEnd('\') + '\' + $rel      # a host path: Join-Path would look for its drive here
                    $null = Invoke-Command -Session $session -ScriptBlock { param($d) [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($d)) } -ArgumentList $dest
                    Copy-Item -ToSession $session -LiteralPath ([string]$f.local) -Destination $dest -Force
                }
                $a = $Req.args
                if ($null -eq $a) { $a = New-Object psobject }
                $a | Add-Member -NotePropertyName stage -NotePropertyValue $stage -Force
                $l = Invoke-Verb $session $verb (ConvertTo-Json -InputObject $a -Depth 12 -Compress) ([bool]$Req.stage_inline)
                if ($l) { $l } else { Fail 1 'failed' 'the host printed no result' }
            } finally {
                $null = Invoke-Command -Session $session -ScriptBlock { param($p) if ([IO.Directory]::Exists($p)) { Remove-Item -LiteralPath $p -Recurse -Force } } -ArgumentList $stage
            }
        }
        'download' {
            $l = Invoke-Verb $session $verb $json $false
            if (-not $l) { Fail 1 'failed' 'the host printed no result' }
            $l
            $r = $l.Substring(11) | ConvertFrom-Json
            if (-not $r.ok) { break }
            $local = [string]$Req.download_to
            try {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($local))
                $part = "$local.partial"
                Copy-Item -FromSession $session -LiteralPath ([string]$r.file) -Destination $part -Force
                $sha = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLower()
                if ($sha -ne [string]$r.sha256) { Remove-Item -LiteralPath $part -Force; Fail 1 'failed' 'SHA-256 mismatch on the laptop after the download' }
                Move-Item -LiteralPath $part -Destination $local -Force
                $d = ConvertTo-Json -InputObject ([ordered]@{ local = $local; sha256 = $sha; bytes = (Get-Item -LiteralPath $local).Length }) -Compress
                'VMB-DOWNLOAD:' + [regex]::Replace($d, '[^\x20-\x7E]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
            } finally {
                $null = Invoke-Verb $session 'stage-rm' (ConvertTo-Json -InputObject @{ stage = [string]$r.stage } -Compress) $false
            }
        }
        'iso' {
            $opt = New-PSSessionOption -IdleTimeout 14400000
            $sb = { param($r, $j, $c, $cr) Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; & (Join-Path $r 'code\Vmb.ps1') -Verb 'copy-iso' -Json $j -Code $c -Credential $cr }
            $ds = Invoke-Command -ComputerName $fqdn -Credential $cred -Authentication Kerberos -InDisconnectedSession -SessionOption $opt `
                -ScriptBlock $sb -ArgumentList $root, $json, $code, $cred -SessionName ('vmb-iso-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmm'))
            Out-Result ([ordered]@{ ok = $true; exit = 0; session = $ds.Name; state = "$($ds.State)"; note = 'the copy runs in a disconnected session; check inventory for the ISO and its .sha256' })
        }
        default { Fail 2 'rejected' "unknown runner mode '$mode'" }
    }
} catch {
    Fail 255 'unreachable' ("the runner failed: " + ("$($_.Exception.Message)" -split "`n")[0])
} finally {
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
}
