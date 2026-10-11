# VmbActivation.ps1 - activation of the recording VM (docs/design.md 9 and 14; section 15 item 15).
# Dot-sourced by Vmb.ps1. Windows PowerShell 5.1, ASCII only. The operator's verb only (vmb-admin activate).
#
# The key reaches the guest only as an -ArgumentList value and is used there through WMI methods
# (SoftwareLicensingService.InstallProductKey), never on a command line (slmgr) or in script text, so neither
# script block logging (4104), module logging (4103) nor process auditing (4688) records it. After activation the
# key is cleared from the registry (ClearProductKeyFromRegistry, what slmgr /cpky does) and the registry is
# searched for it, plainly and as a decoded DigitalProductId. Results name places, never the key. No job: the key
# is never written to a job file or a log.
#
# The GVLK proof runs the same path with Microsoft's public KMS client key (no activation is used up), with
# script block and module logging turned on for the test, and then searches those logs for the key.

$script:VmbPublicGvlks = @{
    'standard' = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'      # Windows Server 2025 Standard (Microsoft's KMS client keys page)
    'datacenter' = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'    # Windows Server 2025 Datacenter
}
$script:VmbWindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'

$script:VmbGuestLogging = {
    param([bool]$On, $Saved)
    $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
    $keys = @(@('ScriptBlockLogging', 'EnableScriptBlockLogging'), @('ModuleLogging', 'EnableModuleLogging'))
    if ($On) {
        $before = [ordered]@{}
        foreach ($k in $keys) {
            $v = Get-ItemProperty -Path "$base\$($k[0])" -Name $k[1] -ErrorAction SilentlyContinue
            $before[$k[0]] = if ($v) { [int]$v.($k[1]) } else { $null }
            if (-not (Test-Path "$base\$($k[0])")) { New-Item -Path "$base\$($k[0])" -Force | Out-Null }
            Set-ItemProperty -Path "$base\$($k[0])" -Name $k[1] -Value 1 -Type DWord
        }
        if (-not (Test-Path "$base\ModuleLogging\ModuleNames")) { New-Item -Path "$base\ModuleLogging\ModuleNames" -Force | Out-Null }
        Set-ItemProperty -Path "$base\ModuleLogging\ModuleNames" -Name '*' -Value '*' -Type String
        return $before
    }
    foreach ($k in $keys) {
        $old = $Saved.($k[0])
        if ($null -eq $old) { Remove-ItemProperty -Path "$base\$($k[0])" -Name $k[1] -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path "$base\$($k[0])" -Name $k[1] -Value $old -Type DWord }
    }
    Remove-ItemProperty -Path "$base\ModuleLogging\ModuleNames" -Name '*' -ErrorAction SilentlyContinue
    $true
}

# Where can the key still be found? Plain text in any value under CurrentVersion and SoftwareProtectionPlatform,
# or a DigitalProductId that decodes to it. Optionally also the PowerShell and Security logs. Never returns the key.
$script:VmbGuestKeySearch = {
    param([string]$Key, [bool]$Logs)
    function Get-DpidKey([byte[]]$d) {
        if (-not $d -or $d.Length -lt 67) { return $null }
        $k = [byte[]]$d[52..66]
        $win8 = [int][math]::Floor($k[14] / 6) -band 1
        $k[14] = [byte](($k[14] -band 0xF7) -bor (($win8 -band 2) * 4))
        $chars = 'BCDFGHJKMPQRTVWXY2346789'
        $out = ''; $last = 0
        for ($i = 24; $i -ge 0; $i--) {
            $cur = 0
            for ($j = 14; $j -ge 0; $j--) { $cur = $cur * 256; $cur = $k[$j] + $cur; $k[$j] = [byte][math]::Floor($cur / 24); $cur = $cur % 24 }
            $out = $chars[$cur] + $out; $last = $cur
        }
        if ($win8 -eq 1) { $rest = $out.Substring(1); $out = $rest.Substring(0, $last) + 'N' + $rest.Substring($last) }
        ($out.Substring(0, 5), $out.Substring(5, 5), $out.Substring(10, 5), $out.Substring(15, 5), $out.Substring(20, 5)) -join '-'
    }
    $plain = $Key.Replace('-', '')
    $hits = New-Object System.Collections.ArrayList
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion') {
        $p = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $v = $prop.Value
            if ($v -is [string]) { if ($v.Contains($Key) -or $v.Replace('-', '').Contains($plain)) { [void]$hits.Add("$root\$($prop.Name) (text)") } }
            elseif ($v -is [byte[]]) {
                if ((Get-DpidKey $v) -eq $Key) { [void]$hits.Add("$root\$($prop.Name) (decodes)") }
                $u = [Text.Encoding]::Unicode.GetString($v)
                if ($u.Contains($Key)) { [void]$hits.Add("$root\$($prop.Name) (UTF-16)") }
            }
        }
    }
    $ev = $null
    if ($Logs) {
        $ev = [ordered]@{}
        foreach ($log in 'Microsoft-Windows-PowerShell/Operational', 'Windows PowerShell', 'Security') {
            $n = 0
            try { $n = @(Get-WinEvent -LogName $log -MaxEvents 20000 -ErrorAction Stop | Where-Object { $_.Message -and ($_.Message.Contains($Key) -or $_.Message.Contains($plain)) }).Count } catch { $n = -1 }
            $ev[$log] = $n
        }
    }
    [ordered]@{ registry = @($hits); events = $ev }
}

$script:VmbGuestInstallKey = {
    param([string]$Key, [bool]$Activate, [string]$AppId, [string]$FallbackKey)
    $ErrorActionPreference = 'Stop'
    $svc = Get-WmiObject -Class SoftwareLicensingService
    $res = [ordered]@{ installed = $false; activated = $false; error = $null; cleared = $false }
    try { $null = $svc.InstallProductKey($Key); $res.installed = $true }
    catch { $res.error = 'install: ' + ('0x{0:X8}' -f ($_.Exception.InnerException.ErrorCode)); return $res }
    $null = $svc.RefreshLicenseStatus()
    $prod = @(Get-WmiObject -Class SoftwareLicensingProduct -Filter "ApplicationID='$AppId' AND PartialProductKey IS NOT NULL")
    # Only a MAK is activated here. A KMS host key would make this VM a KMS host that publishes itself in DNS (and use
    # up a KMS activation); a retail or OEM key is not this VM's to spend. Anything else is removed again, the public
    # GVLK goes back, and nothing is activated.
    if ($Activate -and ($prod.Count -ne 1 -or "$($prod[0].ProductKeyChannel)" -notlike '*MAK*')) {
        $ch = if ($prod.Count -eq 1) { "$($prod[0].ProductKeyChannel)" } else { "$($prod.Count) products with a key" }
        foreach ($p in $prod) { try { $null = $p.UninstallProductKey() } catch { } }
        if ($FallbackKey) { try { $null = $svc.InstallProductKey($FallbackKey) } catch { } }
        try { $null = $svc.ClearProductKeyFromRegistry(); $res.cleared = $true } catch { }
        $null = $svc.RefreshLicenseStatus()
        $res.installed = $false
        $res.error = "not a MAK (channel $ch): removed again, the GVLK is back, nothing was activated"
        return $res
    }
    if ($Activate -and $prod.Count -eq 1) {
        try { $null = $prod[0].Activate(); $res.activated = $true }
        catch { $code = $_.Exception.InnerException.ErrorCode; $res.error = 'activate: ' + $(if ($code) { '0x{0:X8}' -f $code } else { "$($_.Exception.Message)" }) }
        $null = $svc.RefreshLicenseStatus()
    }
    try { $null = $svc.ClearProductKeyFromRegistry(); $res.cleared = $true } catch { $res.error = "$($res.error) cpky failed" }
    $prod = @(Get-WmiObject -Class SoftwareLicensingProduct -Filter "ApplicationID='$AppId' AND PartialProductKey IS NOT NULL")
    if ($prod.Count -eq 1) {
        $res.edition = $prod[0].Name
        $res.channel = $prod[0].ProductKeyChannel
        $res.license_status = [int]$prod[0].LicenseStatus           # 1 = licensed
        $res.grace_minutes = [int]$prod[0].GracePeriodRemaining     # 0 with status 1 = permanently activated
    }
    $res
}

# The guest's Windows licence as it is now: read only, no key involved.
$script:VmbGuestLicenseState = {
    param([string]$AppId)
    $prod = @(Get-WmiObject -Class SoftwareLicensingProduct -Filter "ApplicationID='$AppId' AND PartialProductKey IS NOT NULL")
    $o = [ordered]@{ products = $prod.Count; channel = $null; license_status = $null; grace_minutes = $null }
    if ($prod.Count -eq 1) {
        $o.channel = "$($prod[0].ProductKeyChannel)"
        $o.license_status = [int]$prod[0].LicenseStatus
        $o.grace_minutes = [int]$prod[0].GracePeriodRemaining
    }
    $o
}

function Invoke-VmbActivate {
    param($A)
    $rec = Get-VmbOwnedRecord ([string]$A.name) '*admin*'
    $mode = [string]$A.mode
    $key = ([string]$A.key).Trim().ToUpper()
    if ($key -cnotmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\z') { Stop-Vmb 2 'rejected' 'the key is not in the 5x5 form' }
    [void]$script:VmbSecretValues.Add($key)
    $isGvlk = $script:VmbPublicGvlks.Values -contains $key
    if ($mode -eq 'gvlk-proof' -and -not $isGvlk) { Stop-Vmb 2 'rejected' 'the proof uses only a public GVLK' }
    if ($mode -eq 'mak' -and $isGvlk) { Stop-Vmb 2 'rejected' 'that is a public GVLK, not a MAK' }
    if ($mode -notin 'gvlk-proof', 'mak') { Stop-Vmb 2 'rejected' 'mode: gvlk-proof or mak' }
    $pol = Get-VmbPolicy
    $rv = Get-VmbField $pol 'recording_vm'
    if ($mode -eq 'mak' -and -not ($rv -and $rv.name -eq $rec.name -and (Get-VmbField $rv 'approved' @()) -contains 'activation')) { Stop-Vmb 2 'rejected' 'a MAK activation is approved only for the recording VM in policy.json' }
    if ($mode -eq 'mak' -and (Get-VmbField $rec.activation 'state') -eq 'activated') { Stop-Vmb 2 'rejected' 'this VM is already activated; another MAK activation would be used up for nothing' }
    if ($mode -eq 'gvlk-proof' -and (Test-VmbMayHoldActivation $rec)) {
        Stop-Vmb 2 'rejected' "the proof installs a GVLK; on '$($rec.name)' (activation $(Get-VmbField $rec.activation 'state')) it would replace the MAK"
    }
    if ($mode -eq 'mak' -and @($rec.done_steps) -notcontains 'lab-setup') { Stop-Vmb 2 'rejected' 'activate after the build has finished its lab-setup step' }
    $g = Get-VmbRunningVM @{ name = $rec.name; consumer = '*admin*' }
    $out = [ordered]@{ vm = $rec.name; mode = $mode }
    $lock = Enter-VmbLock
    try {
        $active = Get-VmbActiveJob $rec.id
        if ($active) { Stop-Vmb 3 'busy' "job $($active.id) ($($active.verb)) is running on '$($rec.name)'" }
        # The guest's own state decides too: a record can be behind (a guest call that never came back).
        $pre = Invoke-VmbGuestOnce $g.vm $g.cred $script:VmbGuestLicenseState @($script:VmbWindowsAppId)
        if ("$($pre.channel)" -match 'MAK' -or ($pre.license_status -eq 1 -and $pre.grace_minutes -eq 0)) {
            Stop-Vmb 2 'rejected' "the guest is already activated (channel $($pre.channel), licence status $($pre.license_status)); no key was installed"
        }
        if (-not (Test-VmbChange "install the key in $($rec.hyperv_name) ($mode)")) { return New-VmbOk $out }
        if ($mode -eq 'mak') {
            # before the key goes in: if the guest call never comes back, the record still says an activation may
            # have been used (resume from disk and restores of older checkpoints are refused)
            $rec.activation = [ordered]@{ state = 'activating'; at = (Get-VmbNow); channel = $pre.channel; error = $null }
            Save-VmbRecord $rec
        }
        $saved = $null
        if ($mode -eq 'gvlk-proof') { $saved = Invoke-VmbGuestOnce $g.vm $g.cred $script:VmbGuestLogging @($true, $null) }
        try {
            # a new session after the logging change, so the policy applies to it
            # the edition's public GVLK goes back if the key turns out not to be a MAK
            $edition = ([string](Get-VmbField (Get-VmbField (Get-VmbField $pol 'profiles') 'win11-lab') 'edition' 'standard')).ToLower()
            $r = Invoke-VmbGuestOnce $g.vm $g.cred $script:VmbGuestInstallKey @($key, ($mode -eq 'mak'), $script:VmbWindowsAppId, $script:VmbLabGvlks[$edition])
            Start-Sleep -Seconds 5
            $s = Invoke-VmbGuestOnce $g.vm $g.cred $script:VmbGuestKeySearch @($key, ($mode -eq 'gvlk-proof'))
        } finally {
            if ($mode -eq 'gvlk-proof') { $null = Invoke-VmbGuestOnce $g.vm $g.cred $script:VmbGuestLogging @($false, $saved) }
        }
        foreach ($k in 'installed', 'activated', 'cleared', 'error', 'edition', 'channel', 'license_status', 'grace_minutes') { $out[$k] = Get-VmbField $r $k }
        $out.key_found_in_registry = @($s.registry)
        $out.key_found_in_logs = $s.events
        $out.permanent = ((Get-VmbField $r 'license_status') -eq 1 -and (Get-VmbField $r 'grace_minutes') -eq 0)
        if ($mode -eq 'mak') {
            # 'at' stays the time the key went in: restores of checkpoints from before it are refused
            $rec.activation = [ordered]@{ state = if ($out.permanent) { 'activated' } elseif ($r.installed) { 'failed' } else { 'none' }; at = $rec.activation.at; channel = $out.channel; error = $out.error }
            Save-VmbRecord $rec
        } elseif (-not (Test-VmbMayHoldActivation $rec)) {
            $rec.activation = [ordered]@{ state = 'gvlk-proof'; at = (Get-VmbNow); channel = $out.channel; error = $out.error }
            Save-VmbRecord $rec
        }
    } finally { Exit-VmbLock $lock }
    Add-VmbEvent @{ verb = 'activate'; vm = $rec.name; mode = $mode; exit = 0; activation_used = ($mode -eq 'mak' -and [bool]$out.installed); permanent = $out.permanent; error = $out.error }
    $o = New-VmbOk $out
    $o
}

# The operator's verb: a generated password, shown only on their terminal.
function Get-VmbPassword {
    param($A)
    $rec = Get-VmbOwnedRecord ([string]$A.name) '*admin*'
    $user = [string]$A.user
    if ($user -notin 'vmbadmin', 'student', 'administrator') { Stop-Vmb 2 'rejected' 'user: vmbadmin, student or administrator' }
    $pw = Get-VmbSecret $rec.id $user
    Add-VmbEvent @{ verb = 'password'; vm = $rec.name; user = $user; exit = 0 }
    New-VmbOk @{ vm = $rec.name; user = "$($rec.hyperv_name)\$user"; password = $pw }
}
