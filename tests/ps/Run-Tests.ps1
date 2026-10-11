<#
.SYNOPSIS
Runs the Pester tests of vm-broker's PowerShell backend (tests\ps\*.Tests.ps1) with the Pester 3.4 that ships with
Windows. Exit 0 when every test passes; 1 when a test fails or none ran; 99 when the safety pre-flight fails.

.DESCRIPTION
Windows PowerShell 5.1 only, on the laptop, in the working copy outside OneDrive. From PowerShell 7, remove
PSModulePath from the environment first, or 5.1 loads the wrong module versions (Get-FileHash goes missing):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\ps\Run-Tests.ps1

Nothing here touches Hyper-V, the registry, scheduled tasks, certificates or remoting: VmbTestHelpers.ps1 shadows
every such command with a stub, and this script checks that before Pester starts. Each test works in a fresh
%TEMP%\vmb-pester-<random>\vmb, removed afterwards.

-Backend <folder> runs the same tests against a copy of src\vm_broker\backend (runner.ps1 and ps\), for example a
proposed fix before it goes into src.
#>
param([string]$Backend = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($PSVersionTable.PSVersion.Major -ne 5) { [Console]::Error.WriteLine('Run-Tests.ps1 needs Windows PowerShell 5.1'); exit 99 }
$pester = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\Pester\3.4.0\Pester.psd1'
if (-not (Test-Path -LiteralPath $pester)) { [Console]::Error.WriteLine("Pester 3.4.0 is not at $pester"); exit 99 }
Import-Module $pester -Force
if ((Get-Module Pester).Version -ne [version]'3.4.0') { [Console]::Error.WriteLine('the wrong Pester is loaded'); exit 99 }

if ($Backend) {
    if (-not (Test-Path -LiteralPath (Join-Path $Backend 'ps\Vmb.ps1'))) { [Console]::Error.WriteLine("no ps\Vmb.ps1 under $Backend"); exit 99 }
    $global:VmbTestBackend = (Resolve-Path -LiteralPath $Backend).ProviderPath
    "testing the backend copy in $global:VmbTestBackend"
}

# Safety pre-flight: the stubs must shadow every command that could change this laptop before any test file runs.
try { . (Join-Path $here 'VmbTestHelpers.ps1') }
catch { [Console]::Error.WriteLine("SAFETY: $($_.Exception.Message)"); exit 99 }

$code = 1
try {
    $r = Invoke-Pester -Path $here -PassThru
    "vm-broker backend tests: $($r.TotalCount) run, $($r.PassedCount) passed, $($r.FailedCount) failed, $($r.SkippedCount) skipped, $($r.PendingCount) pending"
    if ($r.TotalCount -gt 0 -and $r.FailedCount -eq 0) { $code = 0 }
} finally {
    Remove-VmbTestRoots
}
exit $code
