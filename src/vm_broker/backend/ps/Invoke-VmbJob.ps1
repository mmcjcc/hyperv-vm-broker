<#
.SYNOPSIS
Runs one broker job; started by its one-shot SYSTEM scheduled task (\vm-broker\vmb-job-<id>).

.DESCRIPTION
The command line carries only the job id. Everything else is data in jobs\<id>.json. Records its own process
id and start time so job_status can tell a live job from a lost one (docs/design.md 5.3). Windows PowerShell 5.1,
ASCII only.
#>
param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$JobId)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VmbCommon.ps1')
. (Join-Path $PSScriptRoot 'VmbJobs.ps1')
. (Join-Path $PSScriptRoot 'VmbHost.ps1')
. (Join-Path $PSScriptRoot 'VmbGuestBlocks.ps1')
. (Join-Path $PSScriptRoot 'VmbLab.ps1')
. (Join-Path $PSScriptRoot 'VmbOps.ps1')
$script:VmbRoot = Split-Path -Parent $PSScriptRoot

$job = Get-VmbJobRecord $JobId
if (-not $job -or $job.state -ne 'queued') { exit 2 }
$me = Get-Process -Id $PID
$job.state = 'running'; $job.started = Get-VmbNow
$job.pid = $PID; $job.pid_start = $me.StartTime.ToUniversalTime().Ticks.ToString()
Save-VmbJobRecord $job
$script:VmbJob = $job
Write-VmbLog "job $($job.verb) started (pid $PID)"
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $r = switch ($job.verb) {
        'create'   { Invoke-VmbCreateJob $job }
        'stop'     { Invoke-VmbStopJob $job }
        'snapshot' { Invoke-VmbSnapshotJob $job }
        'restore'  { Invoke-VmbRestoreJob $job }
        'fwmon'    { Invoke-VmbFirewallMonitor $job }
        default    { Stop-Vmb 2 'rejected' "unknown job verb '$($job.verb)'" }
    }
    $job = Get-VmbJobRecord $JobId
    if ($job.state -eq 'cancelled') { exit 1 }
    $job.state = 'done'; $job.exit = 0; $job.result = $r
    Write-VmbLog "done after $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min"
} catch {
    $info = Get-VmbErrorInfo $_
    $job = Get-VmbJobRecord $JobId
    if ($job.state -eq 'cancelled') { exit 1 }
    $job.state = 'failed'; $job.exit = [int]$info.exit; $job.error = $info.error; $job.hint = $info.hint
    $script:VmbJob = $job
    Write-VmbLog "FAILED at step $($job.step): $($info.hint)"
    $pos = "$($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    Write-VmbLog "  at $pos"
}
$job.ended = Get-VmbNow
Save-VmbJobRecord $job
Add-VmbEvent @{ verb = $job.verb; job = $JobId; vm = (Get-VmbField $job 'vm'); exit = $job.exit; state = $job.state; step = $job.step; minutes = [math]::Round($sw.Elapsed.TotalMinutes, 1) }
