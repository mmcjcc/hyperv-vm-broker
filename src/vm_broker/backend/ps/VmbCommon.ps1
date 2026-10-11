# VmbCommon.ps1 - helpers dot-sourced by Vmb.ps1 and Invoke-VmbJob.ps1 on the Hyper-V host.
# Windows PowerShell 5.1, ASCII only. docs/design.md sections 3.5, 6, 11 and 12.
#
# Patterns are matched case-sensitively and anchored with \z (-cmatch, -cnotmatch): PowerShell's -match ignores
# case, and $ also matches before a final newline.
#
# Rules that every function here keeps:
# - Consumer strings are data. They arrive as JSON values and go on only as -ArgumentList values into a guest.
#   Nothing here builds script text from them: no Invoke-Expression, no [scriptblock]::Create.
# - VMs are addressed by VMId. A name that matches more than one VM is refused.
# - Every change goes through Test-VmbChange, so -WhatIf runs every check and changes nothing.
# - Secrets never reach a log, a result or an error message.

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

$script:VmbRoot = $null                       # <VMRoot>\vmb, set by the entry script
$script:VmbWhatIf = $false
$script:VmbPlanned = New-Object System.Collections.ArrayList
$script:VmbSecretValues = New-Object System.Collections.ArrayList
$script:VmbJob = $null                        # the job record while a job runs (for the log)

$script:VmbDenyPatterns = @('Firewall*', 'servera', 'serverd', 'servere', 'docker01', 'claude01', 'cloud01', 'ops01', 'Lab*')
$script:VmbNamePattern = '^[a-z][a-z0-9-]{1,10}\z'
$script:VmbIdPattern = '^[0-9a-f]{32}\z'
$script:VmbLabelPattern = '^[a-z0-9][a-z0-9._-]{0,47}\z'
$script:VmbConsumerPattern = '^[a-z][a-z0-9-]{1,39}\z'
$script:VmbMaxCheckpoints = 40

# ---- results and errors ---------------------------------------------------------------------------------

# A refusal or failure with an exit code (docs/design.md 5.5). The hint is one printable line; never a secret.
function Stop-Vmb {
    param([int]$Exit, [string]$Word, [string]$Hint, [string[]]$Findings = @())
    $e = New-Object System.InvalidOperationException ($Hint)
    $e.Data['vmb'] = @{ exit = $Exit; error = $Word; hint = $Hint; findings = @($Findings) }
    throw $e
}

function Get-VmbErrorInfo {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex.Data -and $ex.Data.Contains('vmb')) { return $ex.Data['vmb'] }
        $ex = $ex.InnerException
    }
    # hide secrets first: a cut through the middle of one would leave its first characters behind
    $msg = (Hide-VmbSecret "$($ErrorRecord.Exception.Message)") -replace '[^\x20-\x7E]', ' '
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
    @{ exit = 1; error = 'failed'; hint = $msg; findings = @() }
}

function ConvertTo-VmbJson {
    param($Value)
    $j = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    # Escape everything outside printable ASCII, so no console code page can change a byte on the way.
    [regex]::Replace($j, '[^\x20-\x7E]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

# Every secret this process knows (guest passwords it used, a key it was given) is masked in the answer too, not
# only in logs and errors: a guest that prints one must not put it into a session's transcript. -Unmasked only for
# The operator's password verb, whose answer is the password.
function Write-VmbResult {
    param($Result, [switch]$Unmasked)
    if ($script:VmbWhatIf) { $Result['whatif'] = @($script:VmbPlanned) }
    $json = ConvertTo-VmbJson $Result
    if (-not $Unmasked) { $json = Hide-VmbSecret $json }
    'VMB-RESULT:' + $json
}

function New-VmbOk {
    param([hashtable]$Fields = @{})
    $r = [ordered]@{ ok = $true; exit = 0 }
    foreach ($k in $Fields.Keys) { $r[$k] = $Fields[$k] }
    $r
}

# ---- -WhatIf --------------------------------------------------------------------------------------------

# Every change asks here first. Under -WhatIf it records what would have happened and answers $false.
function Test-VmbChange {
    param([string]$What)
    if ($script:VmbWhatIf) { [void]$script:VmbPlanned.Add($What); return $false }
    # the job's own bookkeeping (its record, the registry) is not worth a log line each time
    if ($What -notmatch '^write .*\\vmb\\(jobs|state)\\') { Write-VmbLog "change: $What" }
    $true
}

# ---- time, ids, passwords -------------------------------------------------------------------------------

function Get-VmbNow { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

# A VM whose activation is activated, failed (installed, not permanent) or activating (the guest call never came
# back) may hold a used-up MAK activation: it keeps its disk, its key and its post-activation state.
function Test-VmbMayHoldActivation {
    param($Rec)
    [string](Get-VmbField $Rec.activation 'state') -in 'activated', 'failed', 'activating'
}

# policy frozen: true (the operator's incident switch) refuses every consumer verb that changes something, except stop
# (it frees memory, for example before Firewall3 fails over). The admin is never refused.
function Assert-VmbNotFrozen {
    param($Policy, [string]$Consumer)
    if ($Consumer -cne '*admin*' -and (Get-VmbField $Policy 'frozen' $false) -eq $true) {
        Stop-Vmb 2 'frozen' 'the broker is frozen on this host; ask the operator'
    }
}

function Get-VmbActivationTime {
    param($Rec)
    $at = [string](Get-VmbField $Rec.activation 'at')
    if (-not $at) { return $null }
    [DateTime]::ParseExact($at, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
}

function Get-VmbRandomBytes {
    param([int]$Count)
    $b = New-Object byte[] $Count
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    , $b
}

function New-VmbId { -join ((Get-VmbRandomBytes 16) | ForEach-Object { $_.ToString('x2') }) }

# 24 characters from four classes, each class at least twice; meets the local complexity policy.
function New-VmbPassword {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '#%+-.=@_')
    $all = -join $sets
    $chars = New-Object System.Collections.ArrayList
    foreach ($s in $sets) { foreach ($i in 1..2) { [void]$chars.Add($s[(Get-VmbRandomBytes 1)[0] % $s.Length]) } }
    while ($chars.Count -lt 24) { [void]$chars.Add($all[(Get-VmbRandomBytes 1)[0] % $all.Length]) }
    # Fisher-Yates with the crypto RNG
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [BitConverter]::ToUInt32((Get-VmbRandomBytes 4), 0) % ($i + 1)
        $t = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $t
    }
    $p = -join $chars
    [void]$script:VmbSecretValues.Add($p)
    $p
}

function Hide-VmbSecret {
    param([string]$Text)
    foreach ($s in $script:VmbSecretValues) { if ($s -and $s.Length -ge 6) { $Text = $Text.Replace($s, '***') } }
    $Text
}

# ---- files and state ------------------------------------------------------------------------------------

function Get-VmbPath {
    param([string]$Relative)
    if (-not $script:VmbRoot) { throw 'VmbRoot is not set' }
    Join-Path $script:VmbRoot $Relative
}

# A job writes its record while the laptop polls it: a reader shares read, write and delete (so the writer's
# File.Replace is never refused), and retries a read that meets the replace itself (2026-10-11: a restore was
# reported failed because its status read hit the job's own write).
function Test-VmbSharingError {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception; while ($e.InnerException) { $e = $e.InnerException }
    $e -is [IO.IOException] -or $e -is [UnauthorizedAccessException]
}

function Read-VmbJson {
    param([string]$Path)
    for ($try = 1; ; $try++) {
        if (-not [IO.File]::Exists($Path)) { return $null }
        try {
            $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $text = (New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding $false))).ReadToEnd() } finally { $fs.Dispose() }
            return ($text | ConvertFrom-Json)
        } catch {
            if (-not (Test-VmbSharingError $_) -or $try -ge 30) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

# Atomic: a temp file in the same folder, then a rename over the old one (retried while a reader holds it).
function Write-VmbJson {
    param([string]$Path, $Value)
    if (-not (Test-VmbChange "write $Path")) { return }
    $dir = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $tmp = Join-Path $dir ('.tmp-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Value -Depth 12), (New-Object Text.UTF8Encoding $false))
    for ($try = 1; ; $try++) {
        try {
            if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch {
            if (-not (Test-VmbSharingError $_) -or $try -ge 30) {
                if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
                throw
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function ConvertTo-VmbHashtable {
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable] -or $Object -is [Collections.Specialized.OrderedDictionary]) { return $Object }
    if ($Object -is [Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-VmbHashtable $p.Value }
        return $h
    }
    if ($Object -is [Array]) { return , @($Object | ForEach-Object { ConvertTo-VmbHashtable $_ }) }
    $Object
}

function Get-VmbField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $Default } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $Default }
}

# The host lock (docs/design.md 3.2): opened with no sharing; Windows releases it if the process dies.
function Enter-VmbLock {
    param([int]$TimeoutS = 60)
    if ($script:VmbWhatIf) { return $null }
    $p = Get-VmbPath 'state\lock'
    $until = [DateTime]::UtcNow.AddSeconds($TimeoutS)
    while ($true) {
        try { return [IO.File]::Open($p, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch {
            $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
            if (-not ($inner -is [IO.IOException])) { throw }
            if ([DateTime]::UtcNow -gt $until) { Stop-Vmb 3 'busy' 'the host lock is held by another broker call; try again in a minute' }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Exit-VmbLock {
    param($Lock)
    if ($Lock) { $Lock.Dispose() }
}

# Guest work and jobs exclude each other for the whole call (docs/design.md 5.1): a run, copy or director call
# holds a shared handle on state\vmuse-<id> from its check (under the host lock) until its verb ends; a job starts
# only if it can open that file alone. Windows closes the handle if the process dies.
$script:VmbGuestUse = @{}

function Enter-VmbGuestUse {
    param([string]$Id)       # call while holding the host lock
    if ($script:VmbWhatIf -or $script:VmbGuestUse.ContainsKey($Id)) { return }
    $p = Get-VmbPath "state\vmuse-$Id"
    $script:VmbGuestUse[$Id] = [IO.File]::Open($p, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
}

function Exit-VmbGuestUse {
    foreach ($h in @($script:VmbGuestUse.Values)) { if ($h) { $h.Dispose() } }
    $script:VmbGuestUse.Clear()
}

function Assert-VmbNoGuestUse {
    param($Rec)              # call while holding the host lock, before a job starts
    if ($script:VmbWhatIf) { return }
    $p = Get-VmbPath "state\vmuse-$($Rec.id)"
    try { $h = [IO.File]::Open($p, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $h.Dispose() }
    catch {
        $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
        if (-not ($inner -is [IO.IOException])) { throw }
        Stop-Vmb 3 'busy' "a run, copy or director call is in progress on '$($Rec.name)'; start the job when it is done"
    }
}

# The policy's guardrail values, checked on every read (a hand edit fails closed) and before set-policy and install
# write one: the switch, the CPU, disk and memory caps, the firewall rule and the build memory (Grok review
# 2026-10-11: set-policy took any object, and a resume then applied weakened caps).
$script:VmbLanSwitches = @('LAN2')

function Test-VmbPolicy {
    param($Pol)
    $bad = New-Object System.Collections.ArrayList
    $num = { param($v) $v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] }
    if ((Get-VmbField $Pol 'policy') -ne 1) { [void]$bad.Add('policy: 1') }
    if ($script:VmbLanSwitches -cnotcontains [string](Get-VmbField $Pol 'lan_switch')) { [void]$bad.Add("lan_switch: one of $($script:VmbLanSwitches -join ', ')") }
    $cpu = Get-VmbField $Pol 'cpu'
    $w = Get-VmbField $cpu 'weight'; $l = Get-VmbField $cpu 'limit'
    if (-not (& $num $w) -or $w -lt 1 -or $w -gt 50) { [void]$bad.Add('cpu.weight: 1..50 (production keeps 100)') }
    if (-not (& $num $l) -or $l -lt 10 -or $l -gt 75) { [void]$bad.Add('cpu.limit: 10..75') }
    $io = Get-VmbField $Pol 'disk_iops_max'
    if (-not (& $num $io) -or $io -lt 100 -or $io -gt 5000) { [void]$bad.Add('disk_iops_max: 100..5000 (0 would be no cap)') }
    $mp = Get-VmbField $Pol 'memory_priority'
    if (-not (& $num $mp) -or $mp -lt 0 -or $mp -gt 50) { [void]$bad.Add('memory_priority: 0..50 (production keeps 50)') }
    if ([string](Get-VmbField $Pol 'firewall_mode' 'here') -cnotin 'here', 'elsewhere') { [void]$bad.Add('firewall_mode: here or elsewhere') }
    if ([string](Get-VmbField $Pol 'firewall_vm') -cnotmatch '^Firewall[0-9]*\z') { [void]$bad.Add('firewall_vm: the production firewall VM (Firewall<n>)') }
    $fl = Get-VmbField $Pol 'floor_gb'
    if (-not (& $num $fl) -or $fl -lt 1 -or $fl -gt 16) { [void]$bad.Add('floor_gb: 1..16') }
    $profiles = Get-VmbField $Pol 'profiles'
    $named = @()
    if ($profiles -is [Collections.IDictionary]) { $named = @($profiles.Keys | ForEach-Object { , @($_, $profiles[$_]) }) }
    elseif ($profiles) { $named = @($profiles.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) }) }
    foreach ($pair in $named) {
        $m = Get-VmbField $pair[1] 'memory'
        if (-not $m) { continue }
        $s = Get-VmbField $m 'startup_mb'; $mn = Get-VmbField $m 'minimum_mb'; $mx = Get-VmbField $m 'maximum_mb'
        $cap = [double](Get-VmbField $pair[1] 'memory_max_gb' 8) * 1024
        if (-not ((& $num $s) -and (& $num $mn) -and (& $num $mx)) -or $mn -lt 512 -or $mn -gt $s -or $s -gt $mx -or $mx -gt $cap) {
            [void]$bad.Add("profiles.$($pair[0]).memory: 512 <= minimum <= startup <= maximum <= memory_max_gb")
        }
    }
    @($bad)
}

function Get-VmbPolicy {
    $p = Get-VmbPath 'policy.json'
    $pol = Read-VmbJson $p
    if (-not $pol) { Stop-Vmb 255 'not-installed' "vm-broker is not installed on $env:COMPUTERNAME (no policy.json)" }
    if ((Get-VmbField $pol 'policy') -ne 1) { Stop-Vmb 255 'bad-policy' 'policy.json has an unknown version; fail closed' }
    $bad = @(Test-VmbPolicy $pol)
    if ($bad.Count) { Stop-Vmb 255 'bad-policy' ("policy.json fails its checks; fail closed: " + ($bad -join '; ')) }
    $pol
}

function Get-VmbCodeVersion {
    $p = Get-VmbPath 'code\VERSION'
    if ([IO.File]::Exists($p)) { ([IO.File]::ReadAllText($p)).Trim() } else { '' }
}

# ---- logs and events ------------------------------------------------------------------------------------

function Write-VmbLog {
    param([string]$Message)
    if (-not $script:VmbJob -or $script:VmbWhatIf) { return }
    $line = '{0} [{1}] {2}' -f (Get-VmbNow), (Get-VmbField $script:VmbJob 'step' ''), (Hide-VmbSecret $Message)
    $line = $line -replace '[^\x20-\x7E]', '?'
    [IO.File]::AppendAllText((Get-VmbPath "jobs\$($script:VmbJob.id).log"), $line + "`r`n")
}

# One line per request and state change (docs/design.md 12). Never a secret or script content.
function Add-VmbEvent {
    param([hashtable]$Fields)
    if ($script:VmbWhatIf) { return }
    $e = [ordered]@{ t = (Get-VmbNow); host = $env:COMPUTERNAME.ToLower() }
    foreach ($k in $Fields.Keys) { $e[$k] = $Fields[$k] }
    $p = Get-VmbPath 'state\events.jsonl'
    if ([IO.Directory]::Exists((Split-Path -Parent $p))) {
        [IO.File]::AppendAllText($p, (ConvertTo-VmbJson $e) + "`n")
    }
}

# ---- secrets (docs/design.md 3.7): CMS to the "vm-broker secrets" certificate, or machine DPAPI ------------

function Get-VmbSecretCert {
    Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq 'CN=vm-broker secrets' -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
}

function Set-VmbSecret {
    param([string]$Id, [string]$Name, [string]$Value)
    if ($Id -cnotmatch $script:VmbIdPattern -or $Name -cnotmatch '^[a-z][a-z0-9-]{0,31}\z') { throw 'bad secret id or name' }
    [void]$script:VmbSecretValues.Add($Value)
    if (-not (Test-VmbChange "store secret '$Name' of $Id")) { return }
    $dir = Get-VmbPath "secrets\$Id"
    [void][IO.Directory]::CreateDirectory($dir)
    $cert = Get-VmbSecretCert
    # Fail closed: once secrets are CMS-encrypted on this host, a missing or expired certificate must not quietly
    # downgrade new secrets to machine DPAPI (any process on the host can unprotect that).
    if (-not $cert -and @(Get-ChildItem -LiteralPath (Get-VmbPath 'secrets') -Recurse -Filter '*.cms' -ErrorAction SilentlyContinue).Count) {
        Stop-Vmb 1 'failed' 'the "CN=vm-broker secrets" certificate is missing or expired; no secret is written with a weaker key (ask the operator)'
    }
    foreach ($old in (Get-ChildItem -LiteralPath $dir -Filter "$Name.*" -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $old.FullName -Force }
    if ($cert) {
        # the certificate object itself: -To refuses a Cert:\ path ("must resolve to a file system path")
        $text = Protect-CmsMessage -To $cert -Content $Value
        [IO.File]::WriteAllText((Join-Path $dir "$Name.cms"), $text)
    } else {
        Add-Type -AssemblyName System.Security
        $b = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Value), $null, 'LocalMachine')
        [IO.File]::WriteAllText((Join-Path $dir "$Name.dpapi"), [Convert]::ToBase64String($b))
    }
}

function Get-VmbSecret {
    param([string]$Id, [string]$Name)
    if ($Id -cnotmatch $script:VmbIdPattern -or $Name -cnotmatch '^[a-z][a-z0-9-]{0,31}\z') { throw 'bad secret id or name' }
    $dir = Get-VmbPath "secrets\$Id"
    $cms = Join-Path $dir "$Name.cms"; $dp = Join-Path $dir "$Name.dpapi"
    if ([IO.File]::Exists($cms)) {
        $cert = Get-VmbSecretCert
        if (-not $cert) { Stop-Vmb 1 'secret' "the vm-broker secrets certificate is missing; cannot read secret '$Name'" }
        $v = Unprotect-CmsMessage -Content ([IO.File]::ReadAllText($cms)) -To $cert
    } elseif ([IO.File]::Exists($dp)) {
        Add-Type -AssemblyName System.Security
        $v = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([IO.File]::ReadAllText($dp)), $null, 'LocalMachine'))
    } else {
        Stop-Vmb 1 'secret' "secret '$Name' of this VM is missing on the host"
    }
    [void]$script:VmbSecretValues.Add($v)
    $v
}

function New-VmbGuestCredential {
    param($Rec, [string]$User = 'vmbadmin')
    $pw = Get-VmbSecret $Rec.id $User
    # ".\<user>": the guest refused "<computer>\<user>" over PowerShell Direct (serverd, 2026-10-10), and a bare name
    # fails after the first post-setup restart (netadmin's New-WindowsVM.ps1 note)
    New-Object Management.Automation.PSCredential (".\$User", (ConvertTo-SecureString $pw -AsPlainText -Force))
}

# ---- ownership (docs/design.md 6.1, 6.2, 6.3) -----------------------------------------------------------

function Test-VmbDenied {
    param([string]$Name)
    foreach ($p in $script:VmbDenyPatterns) { if ($Name -like $p) { return $true } }
    $false
}

function Get-VmbRecord {
    param([string]$Id)
    if ($Id -cnotmatch $script:VmbIdPattern) { Stop-Vmb 2 'rejected' 'bad record id' }
    Read-VmbJson (Get-VmbPath "state\vms\$Id.json")
}

function Get-VmbRecords {
    $dir = Get-VmbPath 'state\vms'
    if (-not [IO.Directory]::Exists($dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Filter '*.json' | Where-Object { $_.BaseName -cmatch $script:VmbIdPattern } |
        ForEach-Object { Read-VmbJson $_.FullName })
}

# The live (not destroyed) record of a request name, or $null. Two live records with one name: refused.
function Find-VmbRecord {
    param([string]$Name)
    if ($Name -cnotmatch $script:VmbNamePattern) { Stop-Vmb 2 'rejected' "bad VM name (expected $($script:VmbNamePattern))" }
    $hits = @(Get-VmbRecords | Where-Object { $_.name -eq $Name -and $_.state -ne 'destroyed' })
    if ($hits.Count -gt 1) { Stop-Vmb 1 'registry' "two live registry records for '$Name'; ask the operator" }
    if ($hits.Count -eq 1) { $hits[0] } else { $null }
}

function Save-VmbRecord {
    param($Rec)
    $Rec.updated = Get-VmbNow
    Write-VmbJson (Get-VmbPath "state\vms\$($Rec.id).json") $Rec
}

# The record for a consumer verb: it must exist, and the consumer must own it.
function Get-VmbOwnedRecord {
    param([string]$Name, [string]$Consumer)
    $rec = Find-VmbRecord $Name
    if (-not $rec) { Stop-Vmb 2 'unknown-vm' "no VM named '$Name' on $($env:COMPUTERNAME.ToLower())" }
    if ($Consumer -ne '*admin*' -and $rec.owner -ne $Consumer) { Stop-Vmb 2 'not-yours' "VM '$Name' belongs to another consumer" }
    $rec
}

# The Hyper-V VM of a record, after every ownership check: name prefix, Notes tag and registry all agree,
# the denylist wins, a duplicate name or Replica is refused, and the guardrails are still in place.
function Get-VmbVM {
    param($Rec, $Policy, [switch]$NoGuardCheck)
    $name = [string]$Rec.hyperv_name
    if (Test-VmbDenied $name) { Stop-Vmb 2 'not-broker' "$name is on the production denylist; the broker never touches it" }
    if (-not $name.StartsWith('vmb-') -or $name -ne "vmb-$($Rec.name)") { Stop-Vmb 2 'not-broker' "$name is not a broker VM name" }
    if ($Rec.state -eq 'destroyed') { Stop-Vmb 2 'unknown-vm' "VM '$($Rec.name)' was destroyed" }
    if (-not (Get-VmbField $Rec 'vmid')) { Stop-Vmb 1 'failed' "VM '$($Rec.name)' was never created (state $($Rec.state))" }
    $vm = Get-VM -Id $Rec.vmid -ErrorAction SilentlyContinue
    if (-not $vm) { Stop-Vmb 1 'missing' "the Hyper-V VM of '$($Rec.name)' is gone; ask the operator" }
    if ($vm.Name -ne $name) { Stop-Vmb 2 'not-broker' "the VM with this id is now called '$($vm.Name)', not '$name'; refusing" }
    if (-not ("$($vm.Notes)").StartsWith("vm-broker id=$($Rec.id); do not edit")) { Stop-Vmb 2 'not-broker' "the Notes tag of '$name' does not match the registry; refusing" }
    $same = @(Get-VM | Where-Object { $_.Name -eq $name })
    if ($same.Count -ne 1) { Stop-Vmb 2 'duplicate-name' "$($same.Count) VMs are called '$name'; refusing until there is one" }
    if ("$($vm.ReplicationState)" -ne 'Disabled') { Stop-Vmb 2 'not-broker' "'$name' has Hyper-V Replica; the broker never touches it" }
    if (-not $NoGuardCheck) {
        $bad = @(Test-VmbGuards $vm $Policy)
        if ($bad.Count) { Stop-Vmb 1 'guardrails' ("guardrails changed on ${name}: " + ($bad -join '; ') + '; ask the operator') }
    }
    $vm
}

# Guards, CPU limit, I/O cap and memory priority (docs/design.md 6.3 to 6.5). Returns what is wrong.
function Test-VmbGuards {
    param($VM, $Policy)
    $bad = @()
    $lan = [string]$Policy.lan_switch
    # every NIC, connected or not (a disconnected one can be connected later): the three guards, and only the
    # policy's LAN switch or a broker net (v0.2; its router VMs will need their own rule: they serve DHCP and route)
    foreach ($n in @(Get-VMNetworkAdapter -VM $VM)) {
        $sw = "$($n.SwitchName)"
        if ("$($n.DhcpGuard)" -ne 'On') { $bad += "DHCP guard is off on '$($n.Name)'" }
        if ("$($n.RouterGuard)" -ne 'On') { $bad += "router guard is off on '$($n.Name)'" }
        if ("$($n.MacAddressSpoofing)" -ne 'Off') { $bad += "MAC spoofing is on on '$($n.Name)'" }
        if ($sw -and $sw -ne $lan -and $sw -notlike 'vmb-net-*') { $bad += "a NIC is on switch '$sw'" }
    }
    $cpu = Get-VMProcessor -VM $VM
    if ($cpu.RelativeWeight -ne [int]$Policy.cpu.weight) { $bad += "CPU weight is $($cpu.RelativeWeight)" }
    if ($cpu.Maximum -ne [int]$Policy.cpu.limit) { $bad += "CPU limit is $($cpu.Maximum)" }
    foreach ($d in @(Get-VMHardDiskDrive -VM $VM)) {
        if ([int64]$d.MaximumIOPS -ne [int64]$Policy.disk_iops_max) { $bad += "disk IOPS cap is $($d.MaximumIOPS)" }
    }
    $mem = Get-VMMemory -VM $VM
    if ($mem.Priority -ne [int]$Policy.memory_priority) { $bad += "memory priority is $($mem.Priority)" }
    $bad
}

# Every file the VM uses must be inside its own folder (docs/design.md 6.3).
function Test-VmbPaths {
    param($VM, $Rec)
    $root = (Get-VmbPath "vms\$($Rec.id)").TrimEnd('\') + '\'
    $bad = @()
    $paths = @($VM.Path, $VM.ConfigurationLocation, $VM.SnapshotFileLocation, $VM.SmartPagingFilePath)
    $paths += @(Get-VMHardDiskDrive -VM $VM | ForEach-Object { $_.Path })
    $paths += @(Get-VMSnapshot -VM $VM -ErrorAction SilentlyContinue | ForEach-Object { Get-VMHardDiskDrive -VMSnapshot $_ } | ForEach-Object { $_.Path })
    foreach ($p in $paths) {
        if (-not $p) { continue }
        $full = [IO.Path]::GetFullPath($p).TrimEnd('\') + '\'
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $bad += "outside its folder: $p" }
    }
    $bad
}

# ---- capacity (docs/design.md 6.4) ----------------------------------------------------------------------

function Get-VmbAvailableMB {
    [int64]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
}

function Test-VmbCapacity {
    param($Policy, [int64]$StartupMB)
    $fwName = [string]$Policy.firewall_vm
    $fw = @(Get-VM | Where-Object { $_.Name -eq $fwName })
    $fwHere = ($fw.Count -eq 1 -and "$($fw[0].State)" -eq 'Running')
    $mode = [string](Get-VmbField $Policy 'firewall_mode' 'here')
    if ($mode -eq 'here' -and -not $fwHere) {
        Stop-Vmb 6 'no-capacity' "$fwName is not running on $($env:COMPUTERNAME.ToLower()); broker VMs start only on the host where it runs"
    }
    # the host that holds the firewall's replica: broker VMs give way while the firewall has failed over to it
    if ($mode -eq 'elsewhere' -and $fwHere) {
        Stop-Vmb 6 'no-capacity' "$fwName runs on $($env:COMPUTERNAME.ToLower()) (a failover); no broker VM starts here until it moves back"
    }
    if ($mode -notin 'here', 'elsewhere') { Stop-Vmb 255 'bad-policy' 'policy.json: firewall_mode must be here or elsewhere' }
    if ([double]$Policy.budget_gb -le 0) { Stop-Vmb 6 'no-capacity' "the broker budget on $($env:COMPUTERNAME.ToLower()) is 0" }
    $avail = Get-VmbAvailableMB
    $floor = [int64]([double]$Policy.floor_gb * 1024)
    if ($avail - $StartupMB -lt $floor) {
        Stop-Vmb 6 'no-capacity' ("{0} MB available, {1} MB needed to start, floor {2} MB" -f $avail, $StartupMB, $floor)
    }
    $avail
}

function Test-VmbCopyWindow {
    param($Policy, [DateTime]$Now = (Get-Date))
    $w = $Policy.copy_window
    if ((Get-VmbField $w 'always' $false) -eq $true) { return $true }
    $s = [TimeSpan]::Parse([string]$w.start); $e = [TimeSpan]::Parse([string]$w.end); $t = $Now.TimeOfDay
    if ($s -le $e) { return ($t -ge $s -and $t -lt $e) }
    ($t -ge $s -or $t -lt $e)
}

# ---- PowerShell Direct ----------------------------------------------------------------------------------

# Runs one of OUR script blocks once, in a session from New-VmbGuestSession; consumer strings only in -ArgumentList.
function Invoke-VmbGuestOnce {
    param($VM, [pscredential]$Credential, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    $sess = New-VmbGuestSession $VM $Credential
    try { Invoke-Command -Session $sess -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop }
    finally { Remove-PSSession $sess -ErrorAction SilentlyContinue }
}

# Runs one of OUR script blocks in the guest; consumer strings go only in -ArgumentList.
function Invoke-VmbGuest {
    param($VM, [pscredential]$Credential, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$Retries = 3)
    for ($i = 1; ; $i++) {
        try {
            return Invoke-Command -VMId $VM.Id -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        } catch {
            if ($i -ge $Retries) { throw }
            Start-Sleep -Seconds (5 * $i)
        }
    }
}

# Opens a PowerShell Direct session, retrying for up to TimeoutS: an open fails now and then ("an error has occurred
# which Windows PowerShell cannot handle", even "the credential is invalid"), and a failed open has run nothing.
function New-VmbGuestSession {
    param($VM, [pscredential]$Credential, [int]$TimeoutS = 120)
    $until = [DateTime]::UtcNow.AddSeconds($TimeoutS)
    while ($true) {
        try { return New-PSSession -VMId $VM.Id -Credential $Credential -ErrorAction Stop }
        catch {
            if ([DateTime]::UtcNow -gt $until) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

# Waits until PowerShell Direct answers as $Credential. Returns seconds waited.
function Wait-VmbGuest {
    param($VM, [pscredential]$Credential, [int]$TimeoutS = 600, [scriptblock]$Ready = { $true })
    $t0 = [DateTime]::UtcNow
    $last = ''
    while (([DateTime]::UtcNow - $t0).TotalSeconds -lt $TimeoutS) {
        $st = "$((Get-VM -Id $VM.Id).State)"
        if ($st -ne 'Running') { Stop-Vmb 1 'failed' "the VM is $st while waiting for the guest" }
        try {
            $ok = Invoke-Command -VMId $VM.Id -Credential $Credential -ScriptBlock $Ready -ErrorAction Stop
            if ($ok -eq $true) { return [int]([DateTime]::UtcNow - $t0).TotalSeconds }
            $s = "answered: $ok"
        } catch { $s = 'no answer' }
        if ($s -ne $last) { Write-VmbLog "guest: $s"; $last = $s }
        Start-Sleep -Seconds 10
    }
    Stop-Vmb 1 'timeout' "the guest did not answer within $TimeoutS s (last: $last)"
}

function Get-VmbAddresses {
    param($VM)
    @(Get-VMNetworkAdapter -VM $VM | ForEach-Object { $_.IPAddresses } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
}
