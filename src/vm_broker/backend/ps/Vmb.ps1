<#
.SYNOPSIS
The vm-broker backend on a Hyper-V host: one verb per call, JSON in, one JSON line out.

.DESCRIPTION
Runs on the host (servera: C:\VMs\vmb\code\Vmb.ps1), called by the laptop's runner over WinRM, or inline before
the code folder exists (inventory, baseline, install). Windows PowerShell 5.1, ASCII only.

Prints one line "VMB-RESULT:{json}". Every consumer string in -Json is data. -WhatIf runs every check and changes
nothing (the result lists what would have changed). -Code is the client's code version; a mismatch with
code\VERSION is refused, so a laptop never drives older or newer host scripts by accident.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z-]{1,30}$')][string]$Verb,
    [string]$Json = '{}',
    [string]$Code = '',
    [string]$Root = '',
    [pscredential]$Credential
)
$ErrorActionPreference = 'Stop'
#VMB-DOTSOURCE-BEGIN
. (Join-Path $PSScriptRoot 'VmbCommon.ps1')
. (Join-Path $PSScriptRoot 'VmbJobs.ps1')
. (Join-Path $PSScriptRoot 'VmbHost.ps1')
. (Join-Path $PSScriptRoot 'VmbGuestBlocks.ps1')
. (Join-Path $PSScriptRoot 'VmbLab.ps1')
. (Join-Path $PSScriptRoot 'VmbOps.ps1')
. (Join-Path $PSScriptRoot 'VmbActivation.ps1')
#VMB-DOTSOURCE-END

$script:VmbWhatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false        # our own Test-VmbChange decides; read-only cmdlets must still run
if ($Root) { $script:VmbRoot = $Root } elseif ($PSScriptRoot) { $script:VmbRoot = Split-Path -Parent $PSScriptRoot }

# Verbs that may run before the code folder exists (inline from the laptop) skip the version check.
$preInstall = @('inventory', 'baseline', 'install', 'uninstall', 'stage-new', 'install-code')
$admin = @('install', 'uninstall', 'set-policy', 'stage-new', 'stage-rm', 'install-code', 'stage-director', 'resume',
           'activate', 'password', 'job-cancel', 'fwmon', 'fwmon-summary', 'copy-iso', 'baseline', 'inventory')

$result = $null
try {
    if (-not $script:VmbRoot) { Stop-Vmb 255 'not-installed' 'no vm-broker root' }
    $A = $Json | ConvertFrom-Json
    if ($null -eq $A) { $A = New-Object psobject }
    if ($preInstall -notcontains $Verb) {
        $have = Get-VmbCodeVersion
        if (-not $Code -or $Code -ne $have) { Stop-Vmb 255 'code-mismatch' "host code is '$($have.Substring(0, [math]::Min(12, $have.Length)))', the client expects '$($Code.Substring(0, [math]::Min(12, $Code.Length)))'; sync the host code (hostctl sync-code)" }
    }
    if ($admin -notcontains $Verb) {
        $c = [string](Get-VmbField $A 'consumer')
        if ($c -ne '*admin*' -and $c -cnotmatch $script:VmbConsumerPattern) { Stop-Vmb 2 'rejected' 'bad consumer name' }
    }
    $result = switch ($Verb) {
        'inventory'      { Get-VmbInventory $A }
        'baseline'       { Measure-VmbFirewall $A }
        'install'        { Install-VmbHost $A }
        'uninstall'      { Uninstall-VmbHost $A }
        'set-policy'     { Set-VmbPolicyFile $A }
        'stage-new'      { New-VmbStage }
        'stage-rm'       { Remove-VmbStage $A }
        'install-code'   { Install-VmbCode $A }
        'stage-director' { Install-VmbDirectorMedia $A }
        'copy-iso'       { Copy-VmbIso $A $Credential }
        'fwmon'          { $l = Enter-VmbLock; try { $j = Start-VmbJob 'fwmon' $null $A '*admin*' } finally { Exit-VmbLock $l }; New-VmbOk @{ job = $j.id } }
        'fwmon-summary'  { Get-VmbFirewallSummary $A }
        'create'         { Request-VmbCreate $A }
        'resume'         { Request-VmbResume $A }
        'status'         { Get-VmbStatus $A }
        'list'           { Get-VmbList $A }
        'start'          { Start-VmbVM $A }
        'stop'           { Request-VmbStop $A }
        'snapshot'       { Request-VmbSnapshot $A }
        'restore'        { Request-VmbRestore $A }
        'snapshots'      { Get-VmbSnapshotList $A }
        'snapshot-rm'    { Remove-VmbCheckpoint $A }
        'run'            { Invoke-VmbRun $A }
        'copy-to'        { Copy-VmbToGuest $A }
        'copy-from'      { Copy-VmbFromGuest $A }
        'director'       { Invoke-VmbDirector $A }
        'console'        { Get-VmbConsole $A }
        'job'            { Get-VmbJobStatus $A }
        'job-cancel'     { Stop-VmbJob $A }
        'activate'       { Invoke-VmbActivate $A }
        'password'       { Get-VmbPassword $A }
        default          { Stop-Vmb 2 'rejected' "unknown verb '$Verb'" }
    }
    # a stray object from a cmdlet must not hide the verb's answer, which is always the last dictionary
    if ($result -is [array]) { $result = @($result | Where-Object { $_ -is [Collections.IDictionary] })[-1] }
    if (-not ($result -is [Collections.IDictionary])) { Stop-Vmb 1 'internal' "verb '$Verb' returned no result" }
} catch {
    $info = Get-VmbErrorInfo $_
    $result = [ordered]@{ ok = $false; exit = [int]$info.exit; error = $info.error; hint = $info.hint; findings = @($info.findings) }
} finally {
    Exit-VmbGuestUse      # the verb's guest work is over: jobs may start on the VM again
}
Write-VmbResult $result -Unmasked:($Verb -eq 'password')
