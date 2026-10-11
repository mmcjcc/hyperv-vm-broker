# VmbTestHelpers.ps1 - shared setup for the Pester tests of the PowerShell backend (tests\ps\*.Tests.ps1).
# Dot-sourced by every test file and by Run-Tests.ps1. Windows PowerShell 5.1, Pester 3.4, ASCII only.
#
# SAFETY FIRST. The laptop that runs these tests has Hyper-V and is the operator's real machine. Before any backend script
# is dot-sourced, this file defines a GLOBAL stub function for every command the backend could use to change
# something: Hyper-V, disks, scheduled tasks, certificates, remoting, the registry, services, users, files outside
# the test root, reg.exe and friends. A function shadows a cmdlet or an .exe of the same name. Every stub records
# its call in $global:VmbCalls. Then this file checks
#   1. that each stub name resolves to our stub function (no alias, no cmdlet, no .exe in front of it), and
#   2. that every command the backend scripts name is a stub, one of their own functions, or on a short list of
#      read-only or pure cmdlets.
# Anything else throws, and Run-Tests.ps1 aborts before Pester starts. Pester 3.4 calls its own helpers through
# $SafeCommands, so the stubs do not touch Pester itself.

$ErrorActionPreference = 'Stop'

$script:VmbTestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:VmbRepo = Split-Path -Parent (Split-Path -Parent $script:VmbTestsDir)
# Run-Tests.ps1 -Backend <folder> tests a copy of src\vm_broker\backend (runner.ps1 and ps\) instead, for example a
# proposed fix before it goes into src.
if ((Test-Path variable:global:VmbTestBackend) -and $global:VmbTestBackend) { $script:VmbBackendDir = $global:VmbTestBackend }
else { $script:VmbBackendDir = Join-Path $script:VmbRepo 'src\vm_broker\backend' }
$script:VmbBackendPs = Join-Path $script:VmbBackendDir 'ps'
$script:VmbTestPolicyFile = Join-Path $script:VmbRepo 'policy\servera.json'

# ---- the stubs ------------------------------------------------------------------------------------------

# Recorded; the fake Hyper-V below (or a handler a test sets) answers.
$script:VmbStubFake = @(
    'Get-VM', 'New-VM', 'Set-VM', 'Start-VM', 'Stop-VM', 'Remove-VM', 'Restart-VM', 'Save-VM', 'Suspend-VM', 'Resume-VM',
    'Export-VM', 'Import-VM', 'Checkpoint-VM', 'Get-VMSnapshot', 'Restore-VMSnapshot', 'Remove-VMSnapshot', 'Rename-VMSnapshot',
    'Get-VMNetworkAdapter', 'Set-VMNetworkAdapter', 'Add-VMNetworkAdapter', 'Remove-VMNetworkAdapter', 'Connect-VMNetworkAdapter',
    'Get-VMProcessor', 'Set-VMProcessor', 'Get-VMMemory', 'Set-VMMemory',
    'Get-VMHardDiskDrive', 'Set-VMHardDiskDrive', 'Add-VMHardDiskDrive', 'Remove-VMHardDiskDrive',
    'Add-VMDvdDrive', 'Set-VMDvdDrive', 'Remove-VMDvdDrive', 'Set-VMFirmware', 'Set-VMVideo', 'Enable-VMTPM', 'Set-VMKeyProtector',
    'Enable-VMIntegrationService', 'Disable-VMIntegrationService', 'Copy-VMFile', 'Enable-VMReplication', 'Remove-VMReplication',
    'Get-VMReplication', 'Measure-VMReplication', 'Get-AuthenticodeSignature',
    'Get-VMSwitch', 'New-VMSwitch', 'Set-VMSwitch', 'Remove-VMSwitch', 'Get-VMHostSupportedVersion', 'Set-VMHost',
    'Get-VHD', 'New-VHD', 'Mount-VHD', 'Dismount-VHD', 'Resize-VHD', 'Convert-VHD', 'Merge-VHD', 'Optimize-VHD',
    'Get-DiskImage', 'Mount-DiskImage', 'Dismount-DiskImage', 'Get-Disk', 'Set-Disk', 'Initialize-Disk', 'Clear-Disk',
    'Get-Partition', 'New-Partition', 'Remove-Partition', 'Set-Partition', 'Add-PartitionAccessPath', 'Remove-PartitionAccessPath',
    'Format-Volume', 'Get-Volume', 'Expand-WindowsImage',
    'Get-ScheduledTask', 'Get-ScheduledTaskInfo', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Start-ScheduledTask',
    'Stop-ScheduledTask', 'Set-ScheduledTask', 'New-ScheduledTaskAction', 'New-ScheduledTaskPrincipal',
    'New-ScheduledTaskSettingsSet', 'New-ScheduledTaskTrigger',
    'Invoke-Command', 'New-PSSession', 'Remove-PSSession', 'New-PSSessionOption',
    'Get-CimInstance', 'Get-Process', 'Stop-Process', 'Start-Sleep', 'Wait-Job', 'Remove-Job',
    'Get-ItemProperty', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Acl',
    'Resolve-DnsName', 'Get-Counter', 'reg.exe', 'reg',
    'Invoke-WebRequest'     # answers only when a test sets $global:VmbFake.Web (the guest relay, run here); never the network
)
# Never on the host in a test: guest-only commands, and host changes no test may reach. Recorded, then they throw.
$script:VmbStubForbidden = @(
    'New-SelfSignedCertificate', 'Protect-CmsMessage', 'Unprotect-CmsMessage', 'New-PSDrive', 'Remove-PSDrive', 'Enter-PSSession',
    'Set-ExecutionPolicy', 'Restart-Computer', 'Stop-Computer', 'Invoke-Expression', 'Start-Process', 'Out-File',
    'Set-NetFirewallProfile', 'Get-NetFirewallProfile', 'Get-NetTCPConnection', 'New-NetFirewallRule', 'Set-NetFirewallRule',
    'Get-Service', 'Start-Service', 'Stop-Service', 'Restart-Service', 'Set-Service',
    'New-LocalUser', 'Set-LocalUser', 'Enable-LocalUser', 'Disable-LocalUser', 'Get-LocalUser', 'Remove-LocalUser',
    'Get-LocalGroup', 'Get-LocalGroupMember', 'Add-LocalGroupMember',
    'Invoke-RestMethod', 'Get-WmiObject', 'Get-WinEvent',
    'Get-WindowsFeature', 'Install-WindowsFeature', 'Uninstall-WindowsFeature', 'Disable-ScheduledTask', 'Enable-ScheduledTask',
    'powercfg.exe', 'powercfg', 'taskkill.exe', 'taskkill', 'bcdboot.exe', 'bcdboot', 'dism.exe', 'dism', 'manage-bde.exe',
    'manage-bde', 'slmgr', 'slmgr.vbs', 'cscript.exe', 'cscript', 'vmconnect.exe', 'vmconnect', 'robocopy.exe', 'robocopy',
    'netsh.exe', 'netsh', 'shutdown.exe', 'shutdown', 'schtasks.exe', 'schtasks', 'sc.exe', 'whoami', 'whoami.exe'
)
# Files: passed to the real cmdlet only when every path is inside a vmb-pester-* folder under %TEMP%.
$script:VmbStubFiles = @('Remove-Item', 'Copy-Item', 'Move-Item', 'New-Item', 'Rename-Item', 'Set-Content', 'Add-Content', 'Clear-Content')

# Real cmdlets the backend may use in tests: read-only, or pure (no state outside the process).
$script:VmbSafeReal = @(
    'Add-Member', 'Add-Type', 'ConvertFrom-Json', 'ConvertTo-Json', 'ConvertTo-SecureString', 'ForEach-Object', 'Get-Acl',
    'Get-ChildItem', 'Get-Command', 'Get-Content', 'Get-Date', 'Get-ExecutionPolicy', 'Get-FileHash', 'Get-Item', 'Get-Random',
    'Join-Path', 'Measure-Object', 'New-Object', 'New-TimeSpan', 'Out-Null', 'Select-Object', 'Set-StrictMode', 'Sort-Object',
    'Split-Path', 'Test-Path', 'Where-Object'
)

if (-not (Test-Path variable:global:VmbCalls)) { $global:VmbCalls = New-Object System.Collections.ArrayList }
$global:VmbStubKind = @{}
foreach ($n in $script:VmbStubFake) { $global:VmbStubKind[$n] = 'fake' }
foreach ($n in $script:VmbStubForbidden) { $global:VmbStubKind[$n] = 'forbidden' }
foreach ($n in $script:VmbStubFiles) { $global:VmbStubKind[$n] = 'file' }
$global:VmbStubSwitches = @('Force', 'Recurse', 'PassThru', 'AsJob', 'TurnOff', 'DynamicMemory', 'Dynamic', 'AssignDriveLetter',
    'UseMaximumSize', 'AsPlainText', 'DeleteKey', 'AllowStartIfOnBatteries', 'DontStopIfGoingOnBatteries', 'StartWhenAvailable',
    'Default', 'DnsOnly', 'NoHostsFile', 'QuickTimeout', 'File', 'Directory', 'IncludeUserName', 'InDisconnectedSession')

# "-Name value", "-Name:value" and "-Switch" from a simple function's $args. A parameter name carries the hidden
# note property <CommandParameterName>; a string value that merely starts with "-" does not.
function global:ConvertTo-VmbStubParams {
    param([object[]]$ArgList)
    $named = @{}
    $pos = New-Object System.Collections.ArrayList
    if ($null -eq $ArgList) { $ArgList = @() }
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $a = $ArgList[$i]
        $isName = ($a -is [string]) -and [bool]$a.PSObject.Properties['<CommandParameterName>']
        if (-not $isName) { [void]$pos.Add($a); continue }
        $n = $a.TrimStart('-')
        if ($n.EndsWith(':')) { $named[$n.TrimEnd(':')] = $ArgList[$i + 1]; $i++; continue }
        $last = ($i + 1 -ge $ArgList.Count)
        $nextIsName = (-not $last) -and ($ArgList[$i + 1] -is [string]) -and [bool]$ArgList[$i + 1].PSObject.Properties['<CommandParameterName>']
        if ($last -or $nextIsName -or $global:VmbStubSwitches -contains $n) { $named[$n] = $true }
        else { $named[$n] = $ArgList[$i + 1]; $i++ }
    }
    @{ Named = $named; Positional = @($pos) }
}

function global:Test-VmbInTestRoot {
    param([string]$Path)
    if (-not $Path) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $false }
    $base = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\vmb-pester-'
    $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and $full.Length -gt $base.Length + 4
}

function global:Invoke-VmbFileStub {
    param($Call)
    $paths = @()
    foreach ($k in 'LiteralPath', 'Path', 'Destination') { if ($Call.Params.ContainsKey($k)) { $paths += @($Call.Params[$k]) } }
    $paths += @($Call.Positional | Where-Object { $_ -is [string] })
    $bad = @($paths | Where-Object { -not (Test-VmbInTestRoot ([string]$_)) })
    if (-not $paths.Count -or $bad.Count -or $Call.Params.ContainsKey('ToSession') -or $Call.Params.ContainsKey('FromSession')) {
        $Call.Refused = $true
        throw "VMB-STUB: $($Call.Name) refused outside the test root: $($paths -join ', ')"
    }
    $splat = @{}
    foreach ($k in $Call.Params.Keys) { $splat[$k] = $Call.Params[$k] }
    $pos = @($Call.Positional)
    $real = Get-Command -Name "Microsoft.PowerShell.Management\$($Call.Name)" -CommandType Cmdlet
    & $real @splat @pos
}

function global:Invoke-VmbStub {
    param([string]$Name, [object[]]$ArgList, [object[]]$Piped)
    $p = ConvertTo-VmbStubParams $ArgList
    $call = [pscustomobject]@{ Name = $Name; Params = $p.Named; Positional = $p.Positional; Piped = @($Piped); Refused = $false; LockHeld = $null }
    [void]$global:VmbCalls.Add($call)
    $kind = $global:VmbStubKind[$Name]
    if ($kind -eq 'forbidden') {
        if ($Name -like 'whoami*') { $global:VmbPwned = 'whoami ran' }
        throw "VMB-STUB: $Name must never run on the host in a test"
    }
    if ($kind -eq 'file') { Invoke-VmbFileStub $call; return }
    $h = $global:VmbHandlers[$Name]
    if ($h) { & $h $call }
}

# One body for every stub: who am I, then record and answer.
$global:VmbStubBody = { Invoke-VmbStub $MyInvocation.MyCommand.Name $args @($input) }
foreach ($n in $global:VmbStubKind.Keys) { Set-Item -Path "function:global:$n" -Value $global:VmbStubBody }

# ---- the fake Hyper-V host ------------------------------------------------------------------------------

function global:Get-VmbFakeItems {
    param($Table, [string]$Key)
    $x = $Table[$Key]
    if ($null -ne $x) { foreach ($i in @($x)) { $i } }
}

function global:Test-VmbLockHeld {
    $p = Join-Path $global:VmbTestRoot 'state\lock'
    try { $fs = [IO.File]::Open($p, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $fs.Dispose(); $false }
    catch { $true }
}

$global:VmbHandlers = @{
    'Get-VM' = { param($c)
        $all = @($global:VmbFake.VMs)
        if ($c.Params.ContainsKey('Id')) { $want = "$($c.Params['Id'])"; return @($all | Where-Object { "$($_.Id)" -eq $want }) }
        if ($c.Params.ContainsKey('Name')) { $want = "$($c.Params['Name'])"; return @($all | Where-Object { $_.Name -eq $want }) }
        $all
    }
    'Get-VMNetworkAdapter' = { param($c) Get-VmbFakeItems $global:VmbFake.Nics "$($c.Params['VM'].Id)" }
    'Get-VMProcessor' = { param($c) Get-VmbFakeItems $global:VmbFake.Cpu "$($c.Params['VM'].Id)" }
    'Get-VMMemory' = { param($c) Get-VmbFakeItems $global:VmbFake.Mem "$($c.Params['VM'].Id)" }
    'Get-VMHardDiskDrive' = { param($c)
        if ($c.Params.ContainsKey('VMSnapshot')) { Get-VmbFakeItems $global:VmbFake.SnapDisks "$($c.Params['VMSnapshot'].Id)" }
        else { Get-VmbFakeItems $global:VmbFake.Disks "$($c.Params['VM'].Id)" }
    }
    'Get-VMSnapshot' = { param($c) Get-VmbFakeItems $global:VmbFake.Snapshots "$($c.Params['VM'].Id)" }
    'Get-VMSwitch' = { param($c) $global:VmbFake.Switches }
    'Get-VMHostSupportedVersion' = { param($c)
        if ($c.Params.ContainsKey('Default')) { [pscustomobject]@{ Version = [version]'10.0' } }
        else { [pscustomobject]@{ Version = [version]'9.0' }; [pscustomobject]@{ Version = [version]'10.0' } }
    }
    'Get-CimInstance' = { param($c)
        $cls = if ($c.Params.ContainsKey('ClassName')) { [string]$c.Params['ClassName'] } else { [string]$c.Positional[0] }
        if ($global:VmbFake.CimThrows) { throw $global:VmbFake.CimThrows }
        switch ($cls) {
            'Win32_OperatingSystem' { [pscustomobject]@{ FreePhysicalMemory = [uint64]$global:VmbFake.FreeKB; Caption = 'Fake Windows Server'; BuildNumber = '20348' } }
            'Win32_ComputerSystem' { [pscustomobject]@{ TotalPhysicalMemory = [uint64]32GB; NumberOfLogicalProcessors = 4 } }
            default { throw "fake Get-CimInstance: no class $cls" }
        }
    }
    'Get-Volume' = { param($c) $global:VmbFake.Volume }
    'Get-ScheduledTask' = { param($c)
        if ($c.Params.ContainsKey('TaskName')) { $t = $global:VmbFake.Tasks[[string]$c.Params['TaskName']]; if ($t) { $t } }
        else { @($global:VmbFake.Tasks.Values) }
    }
    'Get-ScheduledTaskInfo' = { param($c) [pscustomobject]@{ LastTaskResult = 0 } }
    'Register-ScheduledTask' = { param($c)
        $n = [string]$c.Params['TaskName']
        $c.LockHeld = Test-VmbLockHeld
        $global:VmbFake.RecordsAtRegister = @(Get-ChildItem -LiteralPath (Join-Path $global:VmbTestRoot 'state\vms') -Filter '*.json' |
            ForEach-Object { [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json })
        $global:VmbFake.Tasks[$n] = [pscustomobject]@{ TaskName = $n; TaskPath = [string]$c.Params['TaskPath']; State = 'Ready' }
        [pscustomobject]@{ TaskName = $n }
    }
    'Start-ScheduledTask' = { param($c) $t = $global:VmbFake.Tasks[[string]$c.Params['TaskName']]; if ($t) { $t.State = 'Running' } }
    'Stop-ScheduledTask' = { param($c) $t = $global:VmbFake.Tasks[[string]$c.Params['TaskName']]; if ($t) { $t.State = 'Ready' } }
    'Unregister-ScheduledTask' = { param($c) $global:VmbFake.Tasks.Remove([string]$c.Params['TaskName']) }
    'New-ScheduledTaskAction' = { param($c) [pscustomobject]@{ Kind = 'action'; Execute = $c.Params['Execute']; Argument = $c.Params['Argument'] } }
    'New-ScheduledTaskPrincipal' = { param($c) [pscustomobject]@{ Kind = 'principal'; UserId = $c.Params['UserId'] } }
    'New-ScheduledTaskSettingsSet' = { param($c) [pscustomobject]@{ Kind = 'settings' } }
    'New-ScheduledTaskTrigger' = { param($c) [pscustomobject]@{ Kind = 'trigger' } }
    'New-PSSessionOption' = { param($c) [pscustomobject]@{ Kind = 'option' } }
    'Get-Process' = { param($c) if ($c.Params.ContainsKey('Id')) { $p = $global:VmbFake.Procs[[int]$c.Params['Id']]; if ($p) { $p } } }
    'Invoke-Command' = { param($c) if ($global:VmbFake.Guest) { & $global:VmbFake.Guest $c } }
    'New-PSSession' = { param($c) [pscustomobject]@{ Name = 'vmb-fake-session'; VMId = $c.Params['VMId']; Id = 7 } }
    'Start-VM' = { param($c)
        $vm = $c.Params['VM']; if ($vm) { $vm.State = 'Running' }
        if ($global:VmbFake.StrayFromStartVM) { 'a stray string from Start-VM'; @{ stray = $true } }
    }
    'Stop-VM' = { param($c)
        $vm = $c.Params['VM']
        if ($vm -and ($c.Params.ContainsKey('TurnOff') -or -not $global:VmbFake.GuestIgnoresShutdown)) { $vm.State = 'Off' }
        if ($c.Params.ContainsKey('AsJob')) { [pscustomobject]@{ Kind = 'job'; Name = 'fake-stop-vm' } }
    }
    'Checkpoint-VM' = { param($c)
        if ($global:VmbFake.CheckpointThrows) { throw $global:VmbFake.CheckpointThrows }
        $vm = $c.Params['VM']; $k = "$($vm.Id)"
        $snap = [pscustomobject]@{ Id = [guid]::NewGuid(); VMId = $vm.Id; Name = [string]$c.Params['SnapshotName']; CreationTime = [DateTime]::Now
                                   SnapshotType = 'Standard'; ParentSnapshotName = '' }
        $global:VmbFake.Snapshots[$k] = @(@(Get-VmbFakeItems $global:VmbFake.Snapshots $k) + $snap)
    }
    'Remove-VMSnapshot' = { param($c)
        $s = $c.Params['VMSnapshot']; $k = "$($s.VMId)"
        $global:VmbFake.Snapshots[$k] = @(Get-VmbFakeItems $global:VmbFake.Snapshots $k | Where-Object { $_.Id -ne $s.Id })
    }
    'Rename-VMSnapshot' = { param($c) $c.Params['VMSnapshot'].Name = [string]$c.Params['NewName'] }
    # a standard checkpoint of a running VM comes back in the Saved state; Start-VM resumes it
    'Restore-VMSnapshot' = { param($c) $vm = @($global:VmbFake.VMs | Where-Object { "$($_.Id)" -eq "$($c.Params['VMSnapshot'].VMId)" }); if ($vm) { $vm[0].State = 'Saved' } }
    'Get-VHD' = { param($c) [pscustomobject]@{ Attached = $false } }
    'Invoke-WebRequest' = { param($c)
        if (-not $global:VmbFake.Web) { throw 'VMB-STUB: Invoke-WebRequest without a test handler' }
        & $global:VmbFake.Web $c
    }
    'reg.exe' = { param($c) $global:LASTEXITCODE = 0 }
    'reg' = { param($c) $global:LASTEXITCODE = 0 }
}

function global:Add-VmbFakeVM {
    param([string]$Name, [string]$Notes = '', [string]$State = 'Off', [string]$Replication = 'Disabled', [string]$Dir = $null,
          [string]$Id = ([guid]::NewGuid().ToString()))
    $vm = [pscustomobject]@{
        Name = $Name; Id = [guid]$Id; Notes = $Notes; State = $State; ReplicationState = $Replication
        Path = $Dir; ConfigurationLocation = $Dir; SnapshotFileLocation = $Dir; SmartPagingFilePath = $Dir
        ProcessorCount = 4; MemoryAssigned = [int64]0; MemoryStartup = [int64]6GB; MemoryMaximum = [int64]8GB
        DynamicMemoryEnabled = $true; Generation = 2; Version = '10.0'; Uptime = [TimeSpan]::Zero
    }
    [void]$global:VmbFake.VMs.Add($vm)
    $k = $vm.Id.ToString()
    $global:VmbFake.Nics[$k] = @([pscustomobject]@{ Name = 'Network Adapter'; SwitchName = 'LAN2'; DhcpGuard = 'On'; RouterGuard = 'On'
                                                     MacAddressSpoofing = 'Off'; IPAddresses = @('192.168.10.50', 'fe80::5'); MacAddress = '00155D0A0B0C' })
    $global:VmbFake.Cpu[$k] = [pscustomobject]@{ RelativeWeight = 50; Maximum = 75 }
    $global:VmbFake.Mem[$k] = [pscustomobject]@{ Priority = 20 }
    if ($Dir) { $global:VmbFake.Disks[$k] = @([pscustomobject]@{ Path = (Join-Path $Dir "$Name.vhdx"); MaximumIOPS = [uint64]800 }) }
    $vm
}

function global:Reset-VmbFake {
    $global:VmbCalls.Clear()
    $global:VmbFake = @{
        VMs = New-Object System.Collections.ArrayList
        Nics = @{}; Cpu = @{}; Mem = @{}; Disks = @{}; Snapshots = @{}; SnapDisks = @{}
        FreeKB = [int64](12GB / 1KB)
        Volume = [pscustomobject]@{ DriveLetter = 'C'; SizeRemaining = [int64](15TB); Size = [int64](21TB) }
        Switches = @([pscustomobject]@{ Name = 'LAN2'; SwitchType = 'External'; AllowManagementOS = $true })
        Tasks = @{}; Procs = @{}
        Guest = $null; Web = $null; StrayFromStartVM = $false; CimThrows = $null; RecordsAtRegister = $null
        CheckpointThrows = $null; GuestIgnoresShutdown = $false
    }
    $null = Add-VmbFakeVM -Name 'Firewall3' -State 'Running'
    Remove-Variable -Scope Global -Name VmbPwned -ErrorAction SilentlyContinue
}

# The calls of one stub, as an array even for one call (a lone [pscustomobject] has no .Count in 5.1).
function global:Get-VmbCalls {
    param([string]$Name)
    , @($global:VmbCalls | Where-Object { $_.Name -eq $Name })
}

# Milliseconds asked of Start-Sleep, in order.
function global:Get-VmbSleepMs {
    , @((Get-VmbCalls 'Start-Sleep') | ForEach-Object {
        if ($_.Params.ContainsKey('Milliseconds')) { [int]$_.Params['Milliseconds'] }
        elseif ($_.Params.ContainsKey('Seconds')) { [int]$_.Params['Seconds'] * 1000 }
        else { [int]$_.Positional[0] * 1000 }
    })
}

# ---- the safety checks ----------------------------------------------------------------------------------

function global:Assert-VmbStubsInPlace {
    $want = $global:VmbStubBody.ToString()
    $bad = @()
    foreach ($n in @($global:VmbStubKind.Keys)) {
        $c = @(Get-Command -Name $n -ErrorAction SilentlyContinue)[0]
        if (-not $c -or "$($c.CommandType)" -ne 'Function' -or $c.ScriptBlock.ToString() -ne $want) {
            $bad += "$n resolves to $(if ($c) { "$($c.CommandType) $($c.Source)" } else { 'nothing' })"
        }
    }
    foreach ($n in 'New-VM', 'Start-VM', 'Invoke-Command', 'New-PSSession', 'Register-ScheduledTask', 'New-SelfSignedCertificate', 'reg.exe', 'Remove-Item') {
        if ("$((Get-Command -Name $n).CommandType)" -ne 'Function') { $bad += "$n is not a stub" }
    }
    if ($bad.Count) { throw ('SAFETY: stubs are not in place, refusing to run: ' + ($bad -join '; ')) }
}

# Every command the backend scripts name must be a stub, one of their own functions, or on the safe list.
function global:Assert-VmbBackendCommandsCovered {
    param([string]$Dir)
    $used = @{}; $defined = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter '*.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "SAFETY: $($f.Name) does not parse" }
        foreach ($c in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] }, $true)) {
            $n = $c.GetCommandName(); if ($n) { $used[$n] = $f.Name }
        }
        foreach ($d in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined[$d.Name] = $true }
    }
    $unknown = @($used.Keys | Where-Object { -not $defined.ContainsKey($_) -and -not $global:VmbStubKind.ContainsKey($_) -and $script:VmbSafeReal -notcontains $_ } | Sort-Object)
    if ($unknown.Count) { throw ('SAFETY: the backend uses commands that are neither stubbed nor known safe: ' + ($unknown -join ', ')) }
}

Assert-VmbStubsInPlace
Assert-VmbBackendCommandsCovered $script:VmbBackendDir

# ---- the backend, dot-sourced in the order of Vmb.ps1's dot-source block ---------------------------------

function global:Get-VmbModuleList {
    $main = [IO.File]::ReadAllText((Join-Path $script:VmbBackendPs 'Vmb.ps1'))
    $b = $main.IndexOf('#VMB-DOTSOURCE-BEGIN'); $e = $main.IndexOf('#VMB-DOTSOURCE-END')
    @([regex]::Matches($main.Substring($b, $e - $b), "'(Vmb[A-Za-z]+\.ps1)'") | ForEach-Object { $_.Groups[1].Value })
}

foreach ($m in (Get-VmbModuleList)) { . (Join-Path $script:VmbBackendPs $m) }

Assert-VmbStubsInPlace     # no backend function may have replaced a stub

# Defence in depth, for what a function cannot shadow (an .exe called by full path) or what reaches the network.
function New-VmbLabDisk { throw 'VMB-STUB: New-VmbLabDisk is never run in a test (it calls dism and bcdboot by path)' }
function Set-VmbOfflineShield { throw 'VMB-STUB: Set-VmbOfflineShield is never run in a test' }
function Copy-VmbIso { throw 'VMB-STUB: Copy-VmbIso is never run in a test' }
function Measure-VmbFirewall { throw 'VMB-STUB: Measure-VmbFirewall is never run in a test (it pings)' }
function Invoke-VmbFirewallMonitor { throw 'VMB-STUB: Invoke-VmbFirewallMonitor is never run in a test (it pings)' }
# Secrets use machine DPAPI in a test, whatever certificates this laptop has.
function Get-VmbSecretCert { $null }

# ---- test roots and fixtures ----------------------------------------------------------------------------

if (-not (Test-Path variable:global:VmbTestRoots)) { $global:VmbTestRoots = New-Object System.Collections.ArrayList }

# A fresh <TEMP>\vmb-pester-<random>\vmb with the folders install makes and (unless -NoPolicy) servera's policy.
function New-VmbTestRoot {
    param([switch]$NoPolicy, $Policy = $null)
    Exit-VmbGuestUse      # a test starts with no guest-use handle from the one before
    $parent = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('vmb-pester-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $root = Join-Path $parent 'vmb'
    foreach ($s in 'code', 'state', 'state\vms', 'state\fwmon', 'jobs', 'vms', 'secrets', 'stage', 'media') {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $s))
    }
    [void]$global:VmbTestRoots.Add($parent)
    if ($Policy) { [IO.File]::WriteAllText((Join-Path $root 'policy.json'), (ConvertTo-Json -InputObject $Policy -Depth 10)) }
    elseif (-not $NoPolicy) { [IO.File]::WriteAllText((Join-Path $root 'policy.json'), [IO.File]::ReadAllText($script:VmbTestPolicyFile)) }
    $script:VmbRoot = $root
    $global:VmbTestRoot = $root
    $script:VmbWhatIf = $false
    $script:VmbPlanned.Clear()
    $script:VmbSecretValues.Clear()
    $script:VmbJob = $null
    Reset-VmbFake
    $root
}

function Get-VmbTestPolicy { [IO.File]::ReadAllText($script:VmbTestPolicyFile) | ConvertFrom-Json }

function Remove-VmbTestRoots {
    Exit-VmbGuestUse      # in-process tests keep the guest-use handles that Vmb.ps1 closes when a verb ends
    $base = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\vmb-pester-'
    foreach ($p in @($global:VmbTestRoots)) {
        if ($p.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($p)) { [IO.Directory]::Delete($p, $true) }
    }
    $global:VmbTestRoots.Clear()
}

# Every file under the root with its size and time: equal before and after means nothing was written.
function Get-VmbTreeSnapshot {
    param([string]$Root)
    @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { "D $($_.FullName)" } else { "F $($_.FullName) $($_.Length) $($_.LastWriteTimeUtc.Ticks)" }
    }) -join "`n"
}

# A broker VM: its record on disk, its fake Hyper-V VM inside vms\<id>\, and (unless -NoSecret) a vmbadmin secret.
function New-VmbTestVM {
    param([string]$Name = 'lab-p1', [string]$Owner = 'cs101-walkthroughs', [string]$State = 'Running', [string]$RecordState = 'ready',
          [string[]]$DoneSteps = @('window', 'iso', 'disk', 'vm', 'boot', 'first-contact', 'updates', 'lab-setup', 'director', 'check'),
          [string]$ActivationState = 'none', [switch]$NoSecret)
    $id = New-VmbId
    $dir = Get-VmbPath "vms\$id"
    [void][IO.Directory]::CreateDirectory($dir)
    $vm = Add-VmbFakeVM -Name "vmb-$Name" -Notes "vm-broker id=$id; do not edit" -State $State -Dir $dir
    $rec = [ordered]@{
        record = 1; id = $id; name = $Name; hyperv_name = "vmb-$Name"; vmid = $vm.Id.ToString(); owner = $Owner
        profile = 'win11-lab'; lab_os = 'win2025'; request_hash = ('a' * 64)
        request = [ordered]@{ name = $Name; profile = 'win11-lab'; network = [ordered]@{ mode = 'lan' }; activation = 'mak'; director = $true
                              lease = [ordered]@{ keep = $true }; size = [ordered]@{ cpu = 4; memory_mb = 6144; disk_gb = 127 } }
        state = $RecordState; created = (Get-VmbNow); updated = (Get-VmbNow); host = 'testhost'
        done_steps = @($DoneSteps); activation = [ordered]@{ state = $ActivationState; at = $null }; addresses = @(); job = $null
    }
    Write-VmbJson (Get-VmbPath "state\vms\$id.json") $rec
    if (-not $NoSecret) { Set-VmbSecret $id 'vmbadmin' 'fake-test-value-not-a-secret' }
    [pscustomobject]@{ Id = $id; VM = $vm; Dir = $dir }
}

# A job record on disk, as Start-VmbJob and Invoke-VmbJob.ps1 leave it.
function New-VmbTestJob {
    param([string]$Vm, [string]$State = 'running', [string]$Step = 'checkpoint', [int]$AgeS = 600, $ProcId = $null, [string]$PidStart = $null,
          [string]$Verb = 'snapshot', [string]$Consumer = 'cs101-walkthroughs', [hashtable]$JobArgs = @{ label = 'ch1' })
    $id = New-VmbId
    $job = [ordered]@{
        job = 1; id = $id; verb = $Verb; vm = $Vm; consumer = $Consumer; args = $JobArgs
        state = $State; step = $Step; created = [DateTime]::UtcNow.AddSeconds(-$AgeS).ToString('yyyy-MM-ddTHH:mm:ssZ')
        started = $null; ended = $null; exit = $null; error = $null; hint = $null; result = $null
        task = "vmb-job-$id"; pid = $ProcId; pid_start = $PidStart
    }
    Write-VmbJson (Get-VmbPath "jobs\$id.json") $job
    Get-VmbJobRecord $id
}

# A checkpoint in the fake, as Checkpoint-VM would leave it.
function Add-VmbTestCheckpoint {
    param($VM, [string]$Name, [DateTime]$At = [DateTime]::Now)
    $k = "$($VM.Id)"
    $snap = [pscustomobject]@{ Id = [guid]::NewGuid(); VMId = $VM.Id; Name = $Name; CreationTime = $At; SnapshotType = 'Standard'; ParentSnapshotName = '' }
    $global:VmbFake.Snapshots[$k] = @(@(Get-VmbFakeItems $global:VmbFake.Snapshots $k) + $snap)
    $snap
}

# The refusal a block raises (Stop-Vmb's exit, error, hint), or $null when it does not throw.
function Get-VmbRefusal {
    param([scriptblock]$Block)
    try { $null = & $Block } catch { return (Get-VmbErrorInfo $_) }
    $null
}

# Request-VmbCreate's argument, through JSON like the real call.
function New-VmbCreateArgs {
    param([string]$Name = 'lab-p1', [string]$Consumer = 'cs101-walkthroughs', [string]$Hash = ('a' * 64), [string]$Activation = 'mak',
          [bool]$Keep = $true, [int64]$MemoryMB = 6144, [string]$Mode = 'lan', [string]$ProfileName = 'win11-lab')
    $h = [ordered]@{
        consumer = $Consumer; request_hash = $Hash
        request = [ordered]@{ name = $Name; profile = $ProfileName; network = [ordered]@{ mode = $Mode }; activation = $Activation; director = $true
                              lease = [ordered]@{ keep = $Keep }; size = [ordered]@{ cpu = 4; memory_mb = $MemoryMB; disk_gb = 127 } }
    }
    ConvertTo-Json -InputObject $h -Depth 8 | ConvertFrom-Json
}

function ConvertTo-VmbArgs {
    param([hashtable]$Fields)
    ConvertTo-Json -InputObject $Fields -Depth 8 | ConvertFrom-Json
}

# A JSON array as a PowerShell array. Windows PowerShell 5.1's ConvertFrom-Json writes an array as ONE object, so
# @($json | ConvertFrom-Json) is an array holding the array.
function ConvertFrom-VmbJsonArray {
    param([string]$Json)
    $a = ConvertFrom-Json -InputObject $Json
    , @($a)
}

function Get-VmbSha256Hex {
    param([byte[]]$Bytes)
    $h = [Security.Cryptography.SHA256]::Create()
    try { -join ($h.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $h.Dispose() }
}
