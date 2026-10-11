# VmbJobs.ps1 - long operations as one-shot SYSTEM scheduled tasks on the host (docs/design.md 5.3).
# Dot-sourced by Vmb.ps1 and Invoke-VmbJob.ps1. Windows PowerShell 5.1, ASCII only.
#
# The task's command line carries only the job id (32 hex). Everything else, consumer strings included, is data
# in jobs\<id>.json. One job per VM at a time, checked under the host lock by the caller. A job whose task and
# process are gone becomes "lost" with the step it reached.

$script:VmbTaskPath = '\vm-broker\'
$script:VmbFinalStates = @('done', 'failed', 'lost', 'cancelled')

function Get-VmbJobRecord {
    param([string]$Id)
    if ($Id -cnotmatch $script:VmbIdPattern) { Stop-Vmb 2 'rejected' 'bad job id' }
    Read-VmbJson (Get-VmbPath "jobs\$Id.json")
}

function Save-VmbJobRecord {
    param($Job)
    Write-VmbJson (Get-VmbPath "jobs\$($Job.id).json") $Job
}

# The running (not final) job of a VM, after the liveness check; $null if none.
function Get-VmbActiveJob {
    param([string]$RecId)
    $dir = Get-VmbPath 'jobs'
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $j = Read-VmbJson $f.FullName
        if (-not $j -or (Get-VmbField $j 'vm') -ne $RecId) { continue }
        if ($script:VmbFinalStates -contains $j.state) { continue }
        $j = Update-VmbJobLiveness $j
        if ($script:VmbFinalStates -notcontains $j.state) { return $j }
    }
    $null
}

function Test-VmbJobAlive {
    param($Job)
    $task = Get-ScheduledTask -TaskPath $script:VmbTaskPath -TaskName $Job.task -ErrorAction SilentlyContinue
    if ($task -and "$($task.State)" -eq 'Running') { return $true }
    $procId = Get-VmbField $Job 'pid'
    if ($procId) {
        $p = Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
        if ($p) {
            try { if ($p.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$Job.pid_start) { return $true } } catch { }
        }
    }
    $false
}

# queued/running with no live task or process: "lost". A queued job gets two minutes to start.
function Update-VmbJobLiveness {
    param($Job)
    if ($script:VmbFinalStates -contains $Job.state) { return $Job }
    if (Test-VmbJobAlive $Job) { return $Job }
    if ($Job.state -eq 'queued') {
        $created = [DateTime]::Parse([string]$Job.created, [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal')
        if (([DateTime]::UtcNow - $created).TotalSeconds -lt 120) { return $Job }
    }
    $again = Get-VmbJobRecord $Job.id                       # the job may have finished in the meantime
    if ($script:VmbFinalStates -contains $again.state) { return $again }
    $again.state = 'lost'; $again.ended = Get-VmbNow; $again.exit = 1
    $again.error = 'lost'; $again.hint = "the job's task is gone (step: $($again.step)); a host reboot or a killed task"
    Save-VmbJobRecord $again
    Add-VmbEvent @{ verb = $again.verb; job = $again.id; vm = (Get-VmbField $again 'vm'); exit = 1; state = 'lost'; step = $again.step }
    $again
}

# Registers and starts the task. Call it with the host lock held, after the one-job-per-VM check.
function Start-VmbJob {
    param([string]$Verb, [string]$RecId, $JobArgs, [string]$Consumer)
    $id = New-VmbId
    $job = [ordered]@{
        job = 1; id = $id; verb = $Verb; vm = $RecId; consumer = $Consumer; args = $JobArgs
        state = 'queued'; step = ''; created = (Get-VmbNow); started = $null; ended = $null
        exit = $null; error = $null; hint = $null; result = $null
        task = "vmb-job-$id"; pid = $null; pid_start = $null
    }
    Save-VmbJobRecord $job
    $code = Get-VmbPath 'code'
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-VmbChange "register and start the SYSTEM task $($script:VmbTaskPath)$($job.task)") {
        $act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}\Invoke-VmbJob.ps1" -JobId {1}' -f $code, $id)
        $pr = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 20) -MultipleInstances IgnoreNew `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $job.task -TaskPath $script:VmbTaskPath -Action $act -Principal $pr -Settings $set | Out-Null
        Start-ScheduledTask -TaskName $job.task -TaskPath $script:VmbTaskPath
    }
    Add-VmbEvent @{ verb = $Verb; job = $id; vm = $RecId; consumer = $Consumer; state = 'queued' }
    $job
}

function Remove-VmbJobTask {
    param($Job)
    $t = Get-ScheduledTask -TaskPath $script:VmbTaskPath -TaskName $Job.task -ErrorAction SilentlyContinue
    if ($t -and "$($t.State)" -ne 'Running' -and (Test-VmbChange "unregister the finished task $($Job.task)")) {
        Unregister-ScheduledTask -TaskName $Job.task -TaskPath $script:VmbTaskPath -Confirm:$false
    }
}

function Get-VmbJobLogTail {
    param([string]$Id, [int]$Lines = 20)
    $p = Get-VmbPath "jobs\$Id.log"
    if (-not [IO.File]::Exists($p)) { return @() }
    $all = [IO.File]::ReadAllLines($p)
    @($all | Select-Object -Last $Lines)
}

# job_status for consumers (their own jobs) and for the operator (*admin*).
function Get-VmbJobStatus {
    param($A)
    $id = [string](Get-VmbField $A 'job')
    $consumer = [string](Get-VmbField $A 'consumer')
    $job = Get-VmbJobRecord $id
    if (-not $job) { Stop-Vmb 2 'unknown-job' "no job $id on $($env:COMPUTERNAME.ToLower())" }
    if ($consumer -ne '*admin*' -and (Get-VmbField $job 'consumer') -ne $consumer) { Stop-Vmb 2 'not-yours' 'that job belongs to another consumer' }
    $job = Update-VmbJobLiveness $job
    if ($script:VmbFinalStates -contains $job.state) { Remove-VmbJobTask $job }
    $vmName = $null
    if (Get-VmbField $job 'vm') { $r = Get-VmbRecord $job.vm; if ($r) { $vmName = $r.name } }
    New-VmbOk @{
        job = $job.id; verb = $job.verb; vm = $vmName; state = $job.state; step = $job.step
        created = $job.created; started = $job.started; ended = $job.ended
        job_exit = $job.exit; error = $job.error; hint = $job.hint; result = $job.result
        log = @(Get-VmbJobLogTail $job.id)
    }
}

function Stop-VmbJob {
    param($A)
    $job = Get-VmbJobRecord ([string](Get-VmbField $A 'job'))
    if (-not $job) { Stop-Vmb 2 'unknown-job' 'no such job' }
    if ($script:VmbFinalStates -contains $job.state) { return New-VmbOk @{ job = $job.id; state = $job.state } }
    if (Test-VmbChange "stop the task $($job.task) and mark the job cancelled") {
        Stop-ScheduledTask -TaskName $job.task -TaskPath $script:VmbTaskPath -ErrorAction SilentlyContinue
        $procId = Get-VmbField $job 'pid'
        if ($procId -and (Test-VmbJobAlive $job)) { Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue }
        $job.state = 'cancelled'; $job.ended = Get-VmbNow; $job.exit = 1; $job.error = 'cancelled'; $job.hint = "cancelled at step $($job.step) (vmb-admin or hostctl job-cancel)"
        Save-VmbJobRecord $job
        Remove-VmbJobTask $job
        Add-VmbEvent @{ verb = $job.verb; job = $job.id; vm = (Get-VmbField $job 'vm'); state = 'cancelled' }
    }
    New-VmbOk @{ job = $job.id; state = 'cancelled' }
}

# Inside the job's own process: mark the step, log it, save.
function Set-VmbJobStep {
    param([string]$Step)
    $script:VmbJob.step = $Step
    Save-VmbJobRecord $script:VmbJob
    Write-VmbLog "step $Step"
}
