# VmbLab.ps1 - v0.R: the one recording VM (win11-lab with lab_os win2025, docs/design.md 8.3 and 14), built from
# the Server 2025 ISO the way netadmin's New-WindowsVM.ps1 does (WIM straight onto a VHDX, unattend, no Setup UI).
# Dot-sourced by Vmb.ps1 and Invoke-VmbJob.ps1. Windows PowerShell 5.1, ASCII only.

$script:VmbLabSteps = @('window', 'iso', 'disk', 'vm', 'boot', 'first-contact', 'updates', 'lab-setup', 'director', 'check')
# Microsoft's public KMS client setup keys (GVLKs, learn.microsoft.com "KMS client activation keys"). In the answer
# file they keep OOBE from stopping at "It's time to enter the product key" on volume media; with no KMS host they
# activate nothing and use up nothing. The MAK replaces the key at activation (VmbActivation.ps1).
$script:VmbLabGvlks = @{ 'standard' = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'; 'datacenter' = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF' }
$script:GptBasic = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$script:GptEsp = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:GptMsr = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

# ---- from New-WindowsVM.ps1 -----------------------------------------------------------------------------

function Get-VmbWimNames {
    param([string]$Path)
    $fs = [IO.File]::OpenRead($Path); $br = New-Object IO.BinaryReader($fs)
    try {
        $fs.Seek(0x48, 'Begin') | Out-Null; $size = $br.ReadInt64() -band 0x00FFFFFFFFFFFFFF; $off = $br.ReadInt64()
        $fs.Seek($off, 'Begin') | Out-Null; $x = [Text.Encoding]::Unicode.GetString($br.ReadBytes([int]$size))
    } finally { $fs.Close() }
    ([xml]$x.TrimStart([char]0xFEFF)).WIM.IMAGE | ForEach-Object { [pscustomobject]@{ Index = [int]$_.INDEX; Name = $_.NAME; Display = $_.DISPLAYNAME } }
}

# Read-only mount; part of the checks, so it also runs under -WhatIf. Leaves an ISO someone else mounted alone.
function Mount-VmbIso {
    param([string]$Path)
    $di = Get-DiskImage -ImagePath $Path; $mine = -not $di.Attached; $done = $false
    try {
        if ($mine) { $di = Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly -PassThru }
        for ($i = 0; $i -lt 15; $i++) {
            $dl = "$((Get-DiskImage -ImagePath $Path | Get-Volume -ErrorAction SilentlyContinue).DriveLetter)"
            if ($dl -match '^[A-Za-z]$') { $done = $true; return [pscustomobject]@{ Root = "$($dl):\"; Mine = $mine } }
            Start-Sleep 1
        }
        throw "ISO mounted without a drive letter: $Path"
    } finally {
        if ($mine -and -not $done) { try { Dismount-DiskImage -ImagePath $Path | Out-Null } catch { } }
    }
}

function Get-VmbPartLetter {
    param([uint32]$Disk, [uint32]$Part)
    for ($i = 0; $i -lt 5; $i++) {
        $dl = "$((Get-Partition -DiskNumber $Disk -PartitionNumber $Part).DriveLetter)"
        if ($dl -match '^[A-Za-z]$') { return $dl }
        if ($i -eq 0) { Add-PartitionAccessPath -DiskNumber $Disk -PartitionNumber $Part -AssignDriveLetter }
        Start-Sleep 1
    }
    throw "no free drive letter for disk $Disk partition $Part"
}

# Windows SIM "Hide Sensitive Data" form: base64(UTF-16LE(password + 'AdministratorPassword')), PlainText=false.
function Get-VmbHiddenPassword {
    param([string]$Password)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Password + 'AdministratorPassword'))
}

# DHCP (lan), RDP off, every OOBE page skipped, local Administrator password, the public GVLK. No domain join.
function New-VmbLabUnattend {
    param([string]$Computer, [string]$TimeZone, [string]$HiddenPw, [string]$ProductKey)
    if ($ProductKey -cnotmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\z' -or $script:VmbLabGvlks.Values -notcontains $ProductKey) { throw 'the answer file takes only a public GVLK' }
    $c = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    $tz = [Security.SecurityElement]::Escape($TimeZone)
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <ComputerName>$Computer</ComputerName>
      <ProductKey>$ProductKey</ProductKey>
      <RegisteredOrganization>CORP</RegisteredOrganization>
      <TimeZone>$tz</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" $c>
      <fDenyTSConnections>true</fDenyTSConnections>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $c>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$HiddenPw</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

# Offline, before the first boot: the guest firewall blocks all inbound on every profile from the start (so the
# window between the first DHCP lease and our first contact is closed), WinRM and sshd are disabled, RDP is
# denied, and the new-network prompt is off. Only our constants reach reg.exe.
function Set-VmbOfflineShield {
    param([string]$WindowsRoot)
    $hive = Join-Path $WindowsRoot 'Windows\System32\config\SYSTEM'
    $key = 'HKLM\vmb_off_' + (New-VmbId).Substring(0, 8)
    & reg.exe load $key $hive | Out-Null
    if ($LASTEXITCODE) { throw "reg load of the offline SYSTEM hive failed: $LASTEXITCODE" }
    try {
        $cs = "$key\ControlSet001"
        foreach ($p in 'DomainProfile', 'StandardProfile', 'PublicProfile') {
            foreach ($v in @(@('EnableFirewall', 1), @('DefaultInboundAction', 1), @('DoNotAllowExceptions', 1))) {
                & reg.exe add "$cs\Services\SharedAccess\Parameters\FirewallPolicy\$p" /v $v[0] /t REG_DWORD /d $v[1] /f | Out-Null
                if ($LASTEXITCODE) { throw "offline firewall value $p\$($v[0]) failed" }
            }
        }
        foreach ($svc in 'WinRM', 'sshd') {
            & reg.exe query "$cs\Services\$svc" 2>&1 | Out-Null
            if (-not $LASTEXITCODE) { & reg.exe add "$cs\Services\$svc" /v Start /t REG_DWORD /d 4 /f | Out-Null }
        }
        & reg.exe add "$cs\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 1 /f | Out-Null
        & reg.exe add "$cs\Control\Network\NewNetworkWindowOff" /f | Out-Null
    } finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        for ($i = 0; $i -lt 10; $i++) { & reg.exe unload $key 2>&1 | Out-Null; if (-not $LASTEXITCODE) { break }; Start-Sleep 1 }
        if ($LASTEXITCODE) { throw "reg unload $key failed; unload it by hand before the VHDX is used" }
    }
}

# ---- the create request (inline, under the host lock) ---------------------------------------------------

function Get-VmbLabProfile {
    param($Policy)
    $p = Get-VmbField $Policy.profiles 'win11-lab'
    if (-not $p) { Stop-Vmb 2 'rejected' 'win11-lab: not in v0.R on this host' }
    $p
}

# Startup, minimum and maximum memory (MB) for a new lab VM: the host policy's "memory" when it sets one (serverd
# is tight: the operator, 2026-10-10, "use a smaller amount of RAM for the initial build"), else the request's size with the
# profile's maximum.
function Get-VmbLabMemory {
    param($Policy, $Request)
    $prof = Get-VmbLabProfile $Policy
    $m = Get-VmbField $prof 'memory'
    if ($m) { return @{ startup = [int64]$m.startup_mb; minimum = [int64]$m.minimum_mb; maximum = [int64]$m.maximum_mb } }
    $s = [int64]$Request.size.memory_mb
    @{ startup = $s; minimum = $s; maximum = [int64]([double]$prof.memory_max_gb * 1024) }
}

function Get-VmbStartupMB {
    param($Request, $Policy)
    (Get-VmbLabMemory $Policy $Request).startup
}

# Checks what the host decides (the laptop's validator ran first), reserves the name with a "creating" record,
# and starts the build job. A repeat with the same request hash returns the existing VM or its job.
function Request-VmbCreate {
    param($A)
    $consumer = [string](Get-VmbField $A 'consumer')
    $req = Get-VmbField $A 'request'
    $hash = [string](Get-VmbField $A 'request_hash')
    if ($consumer -cnotmatch $script:VmbConsumerPattern) { Stop-Vmb 2 'rejected' 'bad consumer name' }
    if ($hash -cnotmatch '^[0-9a-f]{64}\z') { Stop-Vmb 2 'rejected' 'bad request hash' }
    $name = [string]$req.name
    if ($name -cnotmatch $script:VmbNamePattern -or $name.EndsWith('-') -or $name -cmatch '^(rtr|img|net|vmb)-') { Stop-Vmb 2 'rejected' "name: '$name' is not allowed" }
    $pol = Get-VmbPolicy
    if ((Get-VmbField $pol 'frozen' $false) -eq $true) { Stop-Vmb 2 'frozen' 'the broker is frozen on this host; ask the operator' }
    if ($req.profile -ne 'win11-lab') { Stop-Vmb 2 'rejected' "profile: $($req.profile) is not in v0.R" }
    $prof = Get-VmbLabProfile $pol
    if ($req.network.mode -ne 'lan' -or (Get-VmbField $prof 'on_lan' $false) -ne $true) { Stop-Vmb 2 'rejected' 'network: v0.R builds the recording VM on lan only, as allowed in policy.json' }
    $rv = Get-VmbField $pol 'recording_vm'
    $special = @()
    if ($req.activation -eq 'mak') { $special += 'activation' }
    if ((Get-VmbField $req.lease 'keep' $false) -eq $true) { $special += 'keep' }
    if ($special.Count -and -not ($rv -and $rv.name -eq $name -and $rv.consumer -eq $consumer)) {
        Stop-Vmb 2 'rejected' ("$($special -join ' and '): approved only for the recording VM named in policy.json")
    }
    # v0.R builds only that one VM, kept, and none of what later stages add: the host checks it too, for a caller
    # that does not go through the laptop's validator (Grok review 2026-10-11)
    if (-not ($rv -and $rv.name -ceq $name -and $rv.consumer -ceq $consumer)) { Stop-Vmb 2 'rejected' 'v0.R builds only the recording VM named in policy.json' }
    if ((Get-VmbField $req.lease 'keep' $false) -ne $true) { Stop-Vmb 2 'rejected' 'v0.R keeps its one VM: lease {keep: true}' }
    foreach ($f in 'users', 'firewall', 'software', 'scripts', 'access') {
        $v = Get-VmbField $req $f
        # the laptop sends [] and {} when they are empty; @({}).Count is 1, so count what is inside
        $n = if ($null -eq $v) { 0 } elseif ($v -is [string]) { $v.Length } elseif ($v -is [Collections.IDictionary]) { $v.Count }
             elseif ($v -is [Collections.ICollection]) { $v.Count } else { @($v.PSObject.Properties).Count }
        if ($n) { Stop-Vmb 2 'rejected' "$f`: not in v0.R" }
    }
    if ((Get-VmbField $req 'autostart' $false) -eq $true) { Stop-Vmb 2 'rejected' 'autostart: not in v0.R' }
    $cpu = [int]$req.size.cpu; $memMB = [int64]$req.size.memory_mb; $diskGB = [int]$req.size.disk_gb
    if ($cpu -lt 2 -or $cpu -gt 4) { Stop-Vmb 2 'rejected' 'size.cpu must be 2..4' }
    if ($memMB -lt 4096 -or $memMB -gt [int64]([double]$prof.memory_max_gb * 1024) -or $memMB % 256) { Stop-Vmb 2 'rejected' 'size.memory is outside the profile range' }
    if ($diskGB -lt 64 -or $diskGB -gt 500) { Stop-Vmb 2 'rejected' 'size.disk must be 64g..500g' }

    $lock = Enter-VmbLock
    try {
        $rec = Find-VmbRecord $name
        if ($rec) {
            if ($rec.owner -ne $consumer -or $rec.request_hash -ne $hash) { Stop-Vmb 2 'name-taken' "'$name' already exists with a different request (or owner)" }
            if ($rec.state -eq 'failed') { Stop-Vmb 1 'failed' "'$name' is in state failed: destroy, then create (v0.R: ask the operator)" }
            $job = Get-VmbActiveJob $rec.id
            return New-VmbOk @{ existing = $true; id = $rec.id; vm = $name; state = $rec.state; job = if ($job) { $job.id } else { $null } }
        }
        $hv = "vmb-$name"
        if (@(Get-VM | Where-Object { $_.Name -eq $hv }).Count) { Stop-Vmb 2 'name-taken' "a Hyper-V VM called '$hv' exists without a registry record; refusing" }
        $labs = @(Get-VmbRecords | Where-Object { $_.state -ne 'destroyed' -and $_.profile -eq 'win11-lab' })
        if ($labs.Count -ge [int](Get-VmbField $prof 'max_vms' 1)) { Stop-Vmb 2 'rejected' 'one recording VM at a time (v0.R); it already exists' }
        $null = Test-VmbCapacity $pol (Get-VmbStartupMB $req $pol)
        $vmRoot = Split-Path -Parent $script:VmbRoot
        $vol = Get-Volume -DriveLetter ((Split-Path -Qualifier $vmRoot).TrimEnd(':'))
        if ($vol.SizeRemaining -lt 500GB -or $vol.SizeRemaining -lt 0.1 * $vol.Size) { Stop-Vmb 6 'no-capacity' 'the VM volume would drop below 500 GB or 10 % free' }
        $id = New-VmbId
        $rec = [ordered]@{
            record = 1; id = $id; name = $name; hyperv_name = $hv; vmid = $null; owner = $consumer
            profile = 'win11-lab'; lab_os = [string]$prof.lab_os; request_hash = $hash; request = $req
            state = 'creating'; created = (Get-VmbNow); updated = (Get-VmbNow); host = $env:COMPUTERNAME.ToLower()
            done_steps = @(); activation = [ordered]@{ state = 'none'; at = $null }; addresses = @(); job = $null
        }
        Save-VmbRecord $rec
        if (Test-VmbChange "create $(Get-VmbPath "vms\$id")") { [void][IO.Directory]::CreateDirectory((Get-VmbPath "vms\$id")) }
        $job = Start-VmbJob 'create' $id ([ordered]@{ from = $null }) $consumer
        $rec.job = $job.id
        Save-VmbRecord $rec
    } finally { Exit-VmbLock $lock }
    Add-VmbEvent @{ verb = 'create'; consumer = $consumer; vm = $name; job = $job.id; request_hash = $hash; exit = 4 }
    New-VmbOk @{ existing = $false; id = $id; vm = $name; state = 'creating'; job = $job.id }
}

# vmb-admin / hostctl: run the build again from a step, for a record in state failed (v0.R's one kept VM).
function Request-VmbResume {
    param($A)
    $rec = Get-VmbOwnedRecord ([string](Get-VmbField $A 'name')) '*admin*'
    $from = [string](Get-VmbField $A 'from')
    if ($from -and $script:VmbLabSteps -notcontains $from) { Stop-Vmb 2 'rejected' "from must be one of: $($script:VmbLabSteps -join ', ')" }
    # the disk step builds a new disk: on a VM that may hold an activation (activated, failed or activating) that
    # would throw away its one MAK activation
    $diskAt = [array]::IndexOf($script:VmbLabSteps, 'disk')
    if ((Test-VmbMayHoldActivation $rec) -and $from -and [array]::IndexOf($script:VmbLabSteps, $from) -le $diskAt) {
        Stop-Vmb 2 'rejected' "'$($rec.name)' may hold an activation ($(Get-VmbField $rec.activation 'state')); resuming from $from would replace its disk and lose it"
    }
    if ($rec.state -eq 'ready' -and -not $from) { Stop-Vmb 2 'rejected' "'$($rec.name)' is ready; name the step to run again (--from)" }
    $lock = Enter-VmbLock
    try {
        $active = Get-VmbActiveJob $rec.id
        if ($active) { Stop-Vmb 3 'busy' "job $($active.id) is still running on '$($rec.name)'" }
        Assert-VmbNoGuestUse $rec      # a run, copy or director call (a recording session) still working in the guest
        if ($from) {
            $i = [array]::IndexOf($script:VmbLabSteps, $from)
            $rec.done_steps = @($rec.done_steps | Where-Object { [array]::IndexOf($script:VmbLabSteps, $_) -lt $i })
        }
        $rec.state = 'creating'
        Save-VmbRecord $rec
        $job = Start-VmbJob 'create' $rec.id ([ordered]@{ from = $from }) $rec.owner
        $rec.job = $job.id
        Save-VmbRecord $rec
    } finally { Exit-VmbLock $lock }
    New-VmbOk @{ vm = $rec.name; job = $job.id; from = $from; done_steps = @($rec.done_steps) }
}

# ---- the build job --------------------------------------------------------------------------------------

function Add-VmbDoneStep {
    param($Ctx, [string]$Step)
    $Ctx.rec.done_steps = @(@($Ctx.rec.done_steps) + $Step | Select-Object -Unique)
    Save-VmbRecord $Ctx.rec
}

function Invoke-VmbCreateJob {
    param($Job)
    $pol = Get-VmbPolicy
    $prof = Get-VmbLabProfile $pol
    $rec = Get-VmbRecord $Job.vm
    $ctx = @{ rec = $rec; pol = $pol; prof = $prof; vm = $null; dir = (Get-VmbPath "vms\$($rec.id)") }
    $vhdx = Join-Path $ctx.dir "$($rec.hyperv_name).vhdx"
    $iso = [string]$prof.iso
    try {
        foreach ($step in $script:VmbLabSteps) {
            if (@($ctx.rec.done_steps) -contains $step) { continue }
            Set-VmbJobStep $step
            switch ($step) {
                'window' {
                    while (-not (Test-VmbCopyWindow $pol)) { Start-Sleep -Seconds 60 }
                }
                'iso' {
                    $until = [DateTime]::UtcNow.AddHours(5)
                    while (-not [IO.File]::Exists($iso) -or [IO.File]::Exists("$iso.partial")) {
                        if ([DateTime]::UtcNow -gt $until) { Stop-Vmb 1 'failed' "the ISO did not arrive: $iso" }
                        Start-Sleep -Seconds 60
                    }
                    $sha = if ([IO.File]::Exists("$iso.sha256")) { ([IO.File]::ReadAllText("$iso.sha256")).Trim() } else { Get-VmbFileHash $iso }
                    $want = [string](Get-VmbField $prof 'iso_sha256' '')
                    if ($want -and $want.ToLower() -ne $sha) { Stop-Vmb 1 'failed' "the ISO's SHA-256 is $sha, the policy expects $want" }
                    Write-VmbLog "ISO $iso, sha256 $sha"
                }
                'disk' { New-VmbLabDisk $ctx $vhdx $iso }
                'vm' { New-VmbLabVM $ctx $vhdx }
                'boot' {
                    $vm = Get-VmbVM $ctx.rec $pol
                    if ("$($vm.State)" -ne 'Running') {
                        $null = Test-VmbCapacity $pol ([int64]($vm.MemoryStartup / 1MB))
                        Start-VM -VM $vm
                    }
                    $cred = New-VmbGuestCredential $ctx.rec 'administrator'
                    $s = Wait-VmbGuest $vm $cred 5400 { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState -eq 'IMAGE_STATE_COMPLETE' }
                    Write-VmbLog "setup complete after $s s"
                }
                'first-contact' { Invoke-VmbFirstContact $ctx }
                'updates' { Invoke-VmbLabUpdates $ctx }
                'lab-setup' {
                    $vm = Get-VmbVM $ctx.rec $pol
                    $r = Invoke-VmbGuest $vm (New-VmbGuestCredential $ctx.rec) $script:VmbGuestLabSetup @((Get-VmbSecret $ctx.rec.id 'student'))
                    Write-VmbLog "lab setup: $(@($r.notes) -join '; ')"
                }
                'director' { Install-VmbLabDirector $ctx }
                'check' { Test-VmbLabDesktop $ctx }
            }
            Add-VmbDoneStep $ctx $step
        }
        $vm = Get-VmbVM $ctx.rec $pol
        $ctx.rec.state = 'ready'
        $ctx.rec.addresses = @(Get-VmbAddresses $vm)
        Save-VmbRecord $ctx.rec
        Add-VmbEvent @{ verb = 'create'; vm = $ctx.rec.name; job = $Job.id; exit = 0; state = 'ready' }
        @{ vm = $ctx.rec.name; state = 'ready'; addresses = @($ctx.rec.addresses) }
    } catch {
        $r2 = Get-VmbRecord $Job.vm
        if ($r2) { $r2.state = 'failed'; Save-VmbRecord $r2 }
        throw
    }
}

# The answer file and the generated Administrator password, on the applied image's Windows volume ($W:).
function Write-VmbLabAnswer {
    param($Ctx, [string]$W)
    $adminPw = New-VmbPassword
    Set-VmbSecret $Ctx.rec.id 'administrator' $adminPw
    $panther = "$($W):\Windows\Panther"
    New-Item -ItemType Directory -Force -Path $panther | Out-Null
    $tz = [string](Get-VmbField $Ctx.pol 'time_zone' 'Eastern Standard Time')
    $edition = ([string](Get-VmbField $Ctx.prof 'edition' 'standard')).ToLower()
    if (-not $script:VmbLabGvlks.ContainsKey($edition)) { throw "no public GVLK for edition '$edition'" }
    $xml = New-VmbLabUnattend -Computer $Ctx.rec.hyperv_name -TimeZone $tz -HiddenPw (Get-VmbHiddenPassword $adminPw) -ProductKey $script:VmbLabGvlks[$edition]
    [xml]$xml | Out-Null
    [IO.File]::WriteAllText("$panther\unattend.xml", $xml, [Text.Encoding]::UTF8)
    Write-VmbLog 'answer file written'
}

# An earlier disk step applied the image and failed after it: finish that step (shield, answer file, the EFI
# partition's type) instead of applying the image again. Answers $false when the VHDX does not hold a whole image.
function Complete-VmbLabDisk {
    param($Ctx, [string]$Vhdx)
    $disk = Mount-VHD -Path $Vhdx -Passthru | Get-Disk
    $n = $disk.Number
    try {
        if ($disk.IsOffline) { Set-Disk -Number $n -IsOffline $false }
        if ($disk.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false }
        $win = $null; $esp = $null
        foreach ($p in @(Get-Partition -DiskNumber $n)) {
            $v = $p | Get-Volume -ErrorAction SilentlyContinue
            if ($v -and $v.FileSystemLabel -eq 'Windows' -and "$($v.FileSystem)" -eq 'NTFS') { $win = $p }
            elseif ("$($p.GptType)" -eq $script:GptEsp -or ($v -and $v.FileSystemLabel -eq 'System' -and "$($v.FileSystem)" -like 'FAT*')) { $esp = $p }
        }
        if (-not $win -or -not $esp) { Write-VmbLog 'the earlier VHDX lacks its Windows or System volume'; return $false }
        $W = Get-VmbPartLetter $n $win.PartitionNumber
        if (-not (Test-Path -LiteralPath "$($W):\Windows\System32\config\SYSTEM") -or -not (Test-Path -LiteralPath "$($W):\Windows\explorer.exe")) {
            Write-VmbLog 'the earlier VHDX holds no whole image'; return $false
        }
        # setup has run on it (it booted): specialize is done and cannot be run again, so start over
        if ((Test-Path -LiteralPath "$($W):\Windows\Panther\UnattendGC") -or (Test-Path -LiteralPath "$($W):\Windows\Panther\setupact.log")) {
            Write-VmbLog 'the earlier VHDX has booted already; applying the image again'; return $false
        }
        if ("$($esp.GptType)" -ne $script:GptEsp) {
            $S = Get-VmbPartLetter $n $esp.PartitionNumber
            if (-not (Test-Path -LiteralPath "$($S):\EFI\Boot\bootx64.efi")) { Write-VmbLog 'the earlier VHDX has no boot files'; return $false }
            Remove-PartitionAccessPath -DiskNumber $n -PartitionNumber $esp.PartitionNumber -AccessPath "$($S):\"
            Set-Partition -DiskNumber $n -PartitionNumber $esp.PartitionNumber -GptType $script:GptEsp -Confirm:$false
        }
        Write-VmbLog 'the image was applied by an earlier attempt; finishing the disk step only'
        Set-VmbOfflineShield "$($W):\"
        Write-VmbLog 'offline shield set (inbound blocked on all profiles, WinRM and sshd disabled, RDP denied)'
        Write-VmbLabAnswer $Ctx $W
        return $true
    } finally {
        if ((Get-VHD -Path $Vhdx -ErrorAction SilentlyContinue).Attached) { Dismount-VHD -Path $Vhdx }
    }
}

function New-VmbLabDisk {
    param($Ctx, [string]$Vhdx, [string]$IsoPath)
    $prof = $Ctx.prof
    $diskGB = [int]$Ctx.rec.request.size.disk_gb
    if ([IO.File]::Exists($Vhdx)) {
        if ((Get-VHD -Path $Vhdx).Attached) { Dismount-VHD -Path $Vhdx }
        if (Complete-VmbLabDisk $Ctx $Vhdx) { return }
        Write-VmbLog 'removing the VHDX of an earlier, unfinished disk step'
        Remove-Item -LiteralPath $Vhdx -Force
    }
    $iso = Mount-VmbIso $IsoPath
    try {
        $wim = Join-Path $iso.Root 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $wim)) { throw "no sources\install.wim on $IsoPath" }
        $names = @(Get-VmbWimNames $wim)
        $img = @($names | Where-Object { $_.Name -eq $prof.image_name -or $_.Display -eq $prof.image_name })
        if ($img.Count -ne 1) { throw "image '$($prof.image_name)' not found once in install.wim; available: $(($names | ForEach-Object { $_.Name }) -join ', ')" }
        $img = $img[0]
        Write-VmbLog "image [$($img.Index)] $($img.Name)"
        New-VHD -Path $Vhdx -SizeBytes ([int64]$diskGB * 1GB) -Dynamic -LogicalSectorSizeBytes 512 | Out-Null
        try {
            $disk = Mount-VHD -Path $Vhdx -Passthru | Get-Disk; $n = $disk.Number
            if ($disk.IsOffline) { Set-Disk -Number $n -IsOffline $false }
            if ($disk.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false }
            Initialize-Disk -Number $n -PartitionStyle GPT
            $haveMsr = $false
            foreach ($p in @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)) {
                try { Remove-Partition -DiskNumber $n -PartitionNumber $p.PartitionNumber -Confirm:$false }
                catch { if ($p.GptType -eq $script:GptMsr) { $haveMsr = $true } else { throw } }
            }
            $esp = New-Partition -DiskNumber $n -Size 260MB -GptType $script:GptBasic
            $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel System -Confirm:$false -Force | Out-Null
            if (-not $haveMsr) { New-Partition -DiskNumber $n -Size 16MB -GptType $script:GptMsr | Out-Null }
            $win = New-Partition -DiskNumber $n -UseMaximumSize -GptType $script:GptBasic
            $win | Format-Volume -FileSystem NTFS -NewFileSystemLabel Windows -Confirm:$false -Force | Out-Null
            $S = Get-VmbPartLetter $n $esp.PartitionNumber; $W = Get-VmbPartLetter $n $win.PartitionNumber
            Write-VmbLog "disk $n ready (EFI ${S}:, Windows ${W}:), applying the image"
            # A 26100 image wants a Windows 11-era DISM (netadmin's New-WindowsVM.ps1): the ADK's, else the one on the
            # Server 2025 media itself (Microsoft-signed, read-only), else the host's own as a last resort.
            $adk = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe"
            $media = Join-Path $iso.Root 'sources\dism.exe'
            $applyLog = Join-Path $Ctx.dir 'apply.log'
            $pref = [string](Get-VmbField $Ctx.pol 'dism' 'auto')      # 'host' forces the host's own DISM
            $dism = if ($pref -eq 'host') { $null } elseif (Test-Path -LiteralPath $adk) { $adk } elseif (Test-Path -LiteralPath $media) { $media } else { $null }
            if ($dism) {
                $sig = Get-AuthenticodeSignature -FilePath $dism
                if ("$($sig.Status)" -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "the DISM at $dism is not Microsoft-signed" }
                Write-VmbLog "applying with $dism ($((Get-Item -LiteralPath $dism).VersionInfo.FileVersion))"
                $scratch = Join-Path $Ctx.dir 'dism-scratch'
                [void][IO.Directory]::CreateDirectory($scratch)
                & $dism /Apply-Image "/ImageFile:$wim" "/Index:$($img.Index)" "/ApplyDir:$($W):\" "/LogPath:$applyLog" "/ScratchDir:$scratch" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "dism /Apply-Image failed: $LASTEXITCODE (see apply.log)" }
                Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Write-VmbLog 'no ADK DISM and no DISM on the media; applying with the host DISM'
                Expand-WindowsImage -ImagePath $wim -Index $img.Index -ApplyPath "$($W):\" -LogPath $applyLog | Out-Null
            }
            Write-VmbLog 'image applied'
            # Boot files from the image's own bcdboot (/offline on 26100.8037+, as New-WindowsVM.ps1 explains)
            $bb = "$($W):\Windows\System32\bcdboot.exe"
            $v = (Get-Item -LiteralPath $bb).VersionInfo
            $tries = @(@{ Exe = $bb; Extra = @('/offline') }, @{ Exe = $bb; Extra = @() }, @{ Exe = "$env:windir\System32\bcdboot.exe"; Extra = @() })
            if (-not ($v.FileBuildPart -gt 26100 -or ($v.FileBuildPart -eq 26100 -and $v.FilePrivatePart -ge 8037))) { $tries = $tries[1..2] }
            $rc = -1
            foreach ($t in $tries) {
                $a = @("$($W):\Windows", '/s', "$($S):", '/f', 'UEFI') + $t.Extra
                try { $null = & $t.Exe @a; $rc = $LASTEXITCODE } catch { $rc = -1 }
                if ($rc -eq 0) { Write-VmbLog "bcdboot: $($t.Exe) $($a -join ' ')"; break }
                Write-VmbLog "bcdboot exit $rc ($($t.Exe))"
            }
            if ($rc -ne 0) { throw 'bcdboot failed' }
            if (-not (Test-Path -LiteralPath "$($S):\EFI\Boot\bootx64.efi")) { throw 'bcdboot left no \EFI\Boot\bootx64.efi' }
            Set-VmbOfflineShield "$($W):\"
            Write-VmbLog 'offline shield set (inbound blocked on all profiles, WinRM and sshd disabled, RDP denied)'
            Write-VmbLabAnswer $Ctx $W
            Remove-PartitionAccessPath -DiskNumber $n -PartitionNumber $esp.PartitionNumber -AccessPath "$($S):\"
            Set-Partition -DiskNumber $n -PartitionNumber $esp.PartitionNumber -GptType $script:GptEsp -Confirm:$false
        } finally {
            if ((Get-VHD -Path $Vhdx -ErrorAction SilentlyContinue).Attached) { Dismount-VHD -Path $Vhdx }
        }
    } finally {
        if ($iso.Mine) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
    }
}

# Hyper-V gives a VM's own account (NT VIRTUAL MACHINE\<VMId>) access to a disk when the disk is attached. A VHDX
# made again for an existing VM (a resumed disk step) inherits only vmb\'s ACL (SYSTEM and Administrators), and the
# VM fails to start with "Account does not have permission to open attachment". Grant it as Hyper-V would.
function Grant-VmbDiskAccess {
    param($VM)
    $sid = (New-Object Security.Principal.NTAccount "NT VIRTUAL MACHINE\$($VM.Id)").Translate([Security.Principal.SecurityIdentifier])
    foreach ($d in @(Get-VMHardDiskDrive -VM $VM)) {
        $acl = Get-Acl -LiteralPath $d.Path
        if (@($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $sid }).Count) { continue }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $sid, 'FullControl', 'Allow'))
        Set-Acl -LiteralPath $d.Path -AclObject $acl
        Write-VmbLog "granted the VM's own account access to $(Split-Path -Leaf $d.Path)"
    }
}

# Gen2, config version 10.0 (docs/design.md 9.1), Secure Boot, no vTPM; the guards and caps of 6.3 to 6.5 are
# set before the first start; 1920x1080 Single while it is off (without Single, 1920x1080 is only a maximum).
function New-VmbLabVM {
    param($Ctx, [string]$Vhdx)
    $rec = $Ctx.rec; $pol = $Ctx.pol; $prof = $Ctx.prof
    $name = [string]$rec.hyperv_name
    $existing = $null
    if (Get-VmbField $rec 'vmid') { $existing = Get-VM -Id $rec.vmid -ErrorAction SilentlyContinue }
    if ($existing) { Write-VmbLog 'the VM exists already; re-applying its settings'; $vm = $existing; Grant-VmbDiskAccess $vm }
    else {
        if (@(Get-VM | Where-Object { $_.Name -eq $name }).Count) { throw "a VM called '$name' appeared without our record; refusing" }
        $startB = (Get-VmbLabMemory $pol $rec.request).startup * 1MB
        $vm = New-VM -Name $name -Generation 2 -Version 10.0 -MemoryStartupBytes $startB -VHDPath $Vhdx -SwitchName ([string]$pol.lan_switch) -Path $Ctx.dir
        $rec.vmid = $vm.Id.ToString()
        Save-VmbRecord $rec
    }
    if ("$($vm.State)" -ne 'Off') { throw "VM '$name' is $($vm.State); settings are applied only while it is off" }
    $mem = Get-VmbLabMemory $pol $rec.request
    $startB = $mem.startup * 1MB; $minB = $mem.minimum * 1MB; $maxB = $mem.maximum * 1MB
    Set-VM -VM $vm -ProcessorCount ([int]$rec.request.size.cpu) -DynamicMemory -MemoryMinimumBytes $minB -MemoryStartupBytes $startB -MemoryMaximumBytes $maxB `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -CheckpointType Standard -AutomaticCheckpointsEnabled $false `
        -SnapshotFileLocation $Ctx.dir -SmartPagingFilePath $Ctx.dir -Notes "vm-broker id=$($rec.id); do not edit"
    Set-VMMemory -VM $vm -Priority ([int]$pol.memory_priority)
    Set-VMProcessor -VM $vm -RelativeWeight ([int]$pol.cpu.weight) -Maximum ([int]$pol.cpu.limit)
    Get-VMNetworkAdapter -VM $vm | Set-VMNetworkAdapter -DhcpGuard On -RouterGuard On -MacAddressSpoofing Off
    Get-VMHardDiskDrive -VM $vm | Set-VMHardDiskDrive -MaximumIOPS ([int64]$pol.disk_iops_max)
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice (Get-VMHardDiskDrive -VM $vm)
    Set-VMVideo -VM $vm -ResolutionType Single -HorizontalResolution 1920 -VerticalResolution 1080
    $bad = @(Test-VmbGuards $vm $pol)
    if ($bad.Count) { throw ('guardrails did not apply: ' + ($bad -join '; ')) }
    $bad = @(Test-VmbPaths $vm $rec)
    if ($bad.Count) { throw ('VM files outside its folder: ' + ($bad -join '; ')) }
    Write-VmbLog "VM $($vm.Id) ready: $($rec.request.size.cpu) vCPU (weight $($pol.cpu.weight), limit $($pol.cpu.limit) %), memory $($mem.startup) MB (minimum $($mem.minimum), maximum $($mem.maximum)), IOPS cap $($pol.disk_iops_max), guards on"
}

function Invoke-VmbFirstContact {
    param($Ctx)
    $vm = Get-VmbVM $Ctx.rec $Ctx.pol
    $id = $Ctx.rec.id
    $admin = New-VmbGuestCredential $Ctx.rec 'administrator'
    $vmbPw = $null; $stuPw = $null
    try { $vmbPw = Get-VmbSecret $id 'vmbadmin' } catch { $vmbPw = New-VmbPassword; Set-VmbSecret $id 'vmbadmin' $vmbPw }
    try { $stuPw = Get-VmbSecret $id 'student' } catch { $stuPw = New-VmbPassword; Set-VmbSecret $id 'student' $stuPw }
    $r = Invoke-VmbGuest $vm $admin $script:VmbGuestFirstContact @($vmbPw, $stuPw)
    Write-VmbLog "guest: $($r.os) $($r.build) ($($r.edition)); firewall: $(@($r.firewall) -join '; '); listeners: $(@($r.listeners) -join ',')"
    $sc = @(Invoke-VmbGuest $vm $admin $script:VmbGuestScrub)
    foreach ($f in $sc) { Write-VmbLog "answer file $($f.file): overwrote $($f.overwrote)" }
    $who = Invoke-VmbGuest $vm (New-VmbGuestCredential $Ctx.rec 'vmbadmin') $script:VmbGuestWhoAmI
    if (-not $who.elevated) { Stop-Vmb 1 'failed' "PowerShell Direct as vmbadmin is not elevated ($($who.user)); built-in Administrator left enabled" }
    $d = Invoke-VmbGuest $vm (New-VmbGuestCredential $Ctx.rec 'vmbadmin') $script:VmbGuestDisableBuiltinAdmin
    Write-VmbLog "vmbadmin is elevated; built-in $($d.name) enabled=$($d.enabled)"
}

function Invoke-VmbLabUpdates {
    param($Ctx)
    $max = [int](Get-VmbField $Ctx.pol 'update_rounds' 5)
    for ($round = 1; $round -le $max; $round++) {
        $vm = Get-VmbVM $Ctx.rec $Ctx.pol
        $cred = New-VmbGuestCredential $Ctx.rec
        $tag = "{0}-{1}" -f [DateTime]::UtcNow.ToString('yyyyMMddHHmm'), $round
        $null = Invoke-VmbGuest $vm $cred $script:VmbGuestWuStart @($script:VmbGuestWuScript, $tag)
        Write-VmbLog "Windows Update round $round started"
        $until = [DateTime]::UtcNow.AddHours(3)
        $st = $null
        while ([DateTime]::UtcNow -lt $until) {
            Start-Sleep -Seconds 60
            try { $st = Invoke-VmbGuest $vm $cred $script:VmbGuestWuStatus @($tag) } catch { continue }
            if ($st.state -in 'done', 'error' -and $st.task -ne 'Running') { break }
        }
        if (-not $st -or $st.state -notin 'done', 'error') { Stop-Vmb 1 'timeout' "Windows Update round $round did not finish in 3 hours" }
        if ($st.state -eq 'error') { Stop-Vmb 1 'failed' "Windows Update round ${round}: $($st.error)" }
        Write-VmbLog "round ${round}: found $(@($st.found).Count); $(@($st.installed) -join ' | '); reboot=$($st.reboot)"
        if (-not $st.reboot -and @($st.found).Count -eq 0) { return }
        if ($st.reboot) { Restart-VmbGuest $Ctx }
        elseif (@($st.found).Count -eq 0) { return }
    }
    Write-VmbLog "stopped after $max Windows Update rounds"
}

function Restart-VmbGuest {
    param($Ctx)
    $vm = Get-VmbVM $Ctx.rec $Ctx.pol
    $cred = New-VmbGuestCredential $Ctx.rec
    try { Invoke-Command -VMId $vm.Id -Credential $cred -ScriptBlock { Restart-Computer -Force } -ErrorAction Stop } catch { }
    Start-Sleep -Seconds 90
    $s = Wait-VmbGuest $vm $cred 3600 { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState -eq 'IMAGE_STATE_COMPLETE' }
    Write-VmbLog "guest back after a restart ($s s after the wait began)"
}

function Install-VmbLabDirector {
    param($Ctx)
    $media = Get-VmbDirectorMedia
    if (-not $media) { Stop-Vmb 1 'failed' 'the director bundle is not staged on the host (hostctl stage-director); resume from step director once it is' }
    $manifest = [IO.File]::ReadAllText((Join-Path $media.path 'manifest.json'))
    $vm = Get-VmbVM $Ctx.rec $Ctx.pol
    $cred = New-VmbGuestCredential $Ctx.rec
    $null = Invoke-VmbGuest $vm $cred $script:VmbGuestDirectorPrepare
    $sess = New-VmbGuestSession $vm $cred
    try { Copy-Item -ToSession $sess -LiteralPath (Join-Path $media.path 'bin') -Destination 'C:\ProgramData\LabDirector' -Recurse -Force }
    finally { Remove-PSSession $sess }
    $r = Invoke-VmbGuest $vm $cred $script:VmbGuestDirectorFinish @($manifest) 1
    Write-VmbLog "director bundle $($media.version): $($r.files) files checked; started=$($r.started)"
}

# Restart, then the student desktop and the director must come up by themselves: auto-logon, the logon task,
# 1920x1080 at 100 %. Saves a screenshot next to the VM for the operator's check.
function Test-VmbLabDesktop {
    param($Ctx)
    Restart-VmbGuest $Ctx
    $vm = Get-VmbVM $Ctx.rec $Ctx.pol
    $cred = New-VmbGuestCredential $Ctx.rec
    $null = Wait-VmbGuest $vm $cred 600 $script:VmbGuestStudentLoggedOn
    $h = Wait-VmbDirector $vm $cred 300
    if ($h.width -ne 1920 -or $h.height -ne 1080 -or $h.scaling -ne 100) {
        Stop-Vmb 1 'failed' ("the desktop is {0}x{1} at {2} %, not 1920x1080 at 100 %" -f $h.width, $h.height, $h.scaling)
    }
    $shot = Invoke-VmbDirectorSteps $vm $cred @(@{ endpoint = '/screenshot'; body = '{}'; timeout_s = 60 })
    $a = $shot[0] | ConvertFrom-Json
    if ($a.ok) { [IO.File]::WriteAllBytes((Join-Path $Ctx.dir 'setup-desktop.png'), [Convert]::FromBase64String($a.png_b64)) }
    Write-VmbLog "desktop: $($h.width)x$($h.height) at $($h.scaling) %, director $($h.version), session $($h.session_id)"
}
