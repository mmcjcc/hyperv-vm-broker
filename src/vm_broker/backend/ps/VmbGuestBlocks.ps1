# VmbGuestBlocks.ps1 - the script blocks that run INSIDE a guest over PowerShell Direct. Dot-sourced by Vmb.ps1
# and Invoke-VmbJob.ps1. Windows PowerShell 5.1, ASCII only.
#
# These are our own code. Anything that comes from a consumer or a secret reaches them only as a parameter
# (-ArgumentList), never as script text, so the guest's script block logging (event 4104) records no value.

# First contact, as the built-in Administrator from the unattend: shield the guest (all inbound blocked, no
# remote listener), make the broker admin and the student, hold Windows Update, lock down the broker folder.
$script:VmbGuestFirstContact = {
    param([string]$VmbAdminPw, [string]$StudentPw)
    $ErrorActionPreference = 'Stop'
    Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -AllowInboundRules False -DefaultOutboundAction Allow
    foreach ($s in 'WinRM', 'sshd') {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) {
            if ("$($svc.Status)" -ne 'Stopped') { Stop-Service -Name $s -Force }
            Set-Service -Name $s -StartupType Disabled
        }
    }
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1 -Type DWord
    function Set-VmbUser([string]$Name, [string]$Pw, [string]$Desc) {
        $sp = ConvertTo-SecureString $Pw -AsPlainText -Force
        if (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) { Set-LocalUser -Name $Name -Password $sp -PasswordNeverExpires $true }
        else { New-LocalUser -Name $Name -Password $sp -PasswordNeverExpires -AccountNeverExpires -Description $Desc | Out-Null }
        Enable-LocalUser -Name $Name
        $admins = Get-LocalGroup -SID 'S-1-5-32-544'
        $members = @(Get-LocalGroupMember -Group $admins | ForEach-Object { ($_.Name -split '\\')[-1] })
        if ($members -notcontains $Name) { Add-LocalGroupMember -Group $admins -Member $Name }
    }
    Set-VmbUser 'vmbadmin' $VmbAdminPw 'vm-broker admin (PowerShell Direct only)'
    Set-VmbUser 'student' $StudentPw 'CS 101 lab student (auto-logon)'
    $ul = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (-not (Test-Path $ul)) { New-Item -Path $ul -Force | Out-Null }
    Set-ItemProperty -Path $ul -Name vmbadmin -Value 0 -Type DWord
    # PowerShell Direct as vmbadmin must get a full admin token (docs/design.md 15 item 16). No network
    # listener is reachable (all inbound blocked), so this opens nothing.
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
    # Windows Update: nothing automatic; the broker installs updates itself, then they stay held (D13).
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }
    Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord
    Set-ItemProperty -Path $au -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    Set-ItemProperty -Path $wu -Name SetAutoRestartNotificationDisable -Value 1 -Type DWord
    Set-ItemProperty -Path $wu -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord
    $d = 'C:\ProgramData\vm-broker'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $d -AclObject $acl
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [ordered]@{
        computer = $env:COMPUTERNAME
        os = (Get-CimInstance Win32_OperatingSystem).Caption
        build = '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR
        edition = $cv.EditionID
        firewall = @(Get-NetFirewallProfile | ForEach-Object { '{0}: enabled={1} inbound={2} rules={3}' -f $_.Name, $_.Enabled, $_.DefaultInboundAction, $_.AllowInboundRules })
        listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -notin '127.0.0.1', '::1' } | ForEach-Object { $_.LocalPort } | Sort-Object -Unique)
    }
}

# Setup blanks sensitive values in the cached answer files; overwrite any value that survived (from netadmin's
# New-WindowsVM.ps1). Returns the files and how many values it had to overwrite.
$script:VmbGuestScrub = {
    $ErrorActionPreference = 'Stop'
    $mark = '*SENSITIVE*DATA*DELETED*'
    $rxs = '(?s)(?<a><(?<n>AdministratorPassword|Password)>(?:(?!</\k<n>>).)*?<Value>)(?<v>[^<]*)(?<b></Value>)',
           '(?<a><ProductKey>\s*(?:<Key>)?)(?<v>[^<]*)(?<b><)'
    $ev = [Text.RegularExpressions.MatchEvaluator] { param($m) $v = $m.Groups['v'].Value.Trim()
        if ($v -and $v -ne '*SENSITIVE*DATA*DELETED*') { $m.Groups['a'].Value + '*SENSITIVE*DATA*DELETED*' + $m.Groups['b'].Value } else { $m.Value } }
    @(foreach ($f in "$env:windir\Panther\unattend.xml", "$env:windir\Panther\unattend-original.xml",
                     "$env:windir\Panther\Unattend\unattend.xml", "$env:windir\System32\Sysprep\unattend.xml") {
        if (-not [IO.File]::Exists($f)) { continue }
        $sr = New-Object IO.StreamReader($f, $true)
        try { $t = $sr.ReadToEnd(); $enc = $sr.CurrentEncoding } finally { $sr.Close() }
        $left = 0; $new = $t
        foreach ($rx in $rxs) {
            $left += @([regex]::Matches($new, $rx) | Where-Object { $v = $_.Groups['v'].Value.Trim(); $v -and $v -ne $mark }).Count
            $new = [regex]::Replace($new, $rx, $ev)
        }
        if ($new -ne $t) { [IO.File]::WriteAllText($f, $new, $enc) }
        [ordered]@{ file = $f; overwrote = $left }
    })
}

# Who am I, and is the token elevated? (IsInRole(Administrator) is false for a UAC-filtered token.)
$script:VmbGuestWhoAmI = {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    [ordered]@{ user = $id.Name; elevated = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
}

$script:VmbGuestDisableBuiltinAdmin = {
    $ErrorActionPreference = 'Stop'
    $a = Get-LocalUser | Where-Object { $_.SID.Value -match '^S-1-5-21-.*-500$' }
    if ($a.Enabled) { Disable-LocalUser -InputObject $a }
    [ordered]@{ name = $a.Name; enabled = (Get-LocalUser -SID $a.SID).Enabled }
}

$script:VmbGuestStudentLoggedOn = {
    [bool](Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { "$($_.UserName)" -like '*\student' })
}

# ---- Windows Update (the WUA API refuses to download or install from a remote session, so a SYSTEM task in the
# guest runs it; adapted from netadmin's tools\wu-install-local.ps1) ---------------------------------------

$script:VmbGuestWuScript = @'
param([string]$Tag)
$dir = 'C:\ProgramData\vm-broker'
$log = Join-Path $dir "wu-$Tag.log"
$json = Join-Path $dir "wu-$Tag.json"
function Log($m) { Add-Content -Path $log -Value "$(Get-Date -Format s) $m" }
$result = [ordered]@{ Tag = $Tag; State = 'running'; Found = @(); Installed = @(); RebootRequired = $false; Error = $null }
$result | ConvertTo-Json -Depth 4 | Set-Content -Path $json -Encoding UTF8
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'vm-broker'
    Log 'Searching for updates'
    $search = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0")
    $result.Found = @($search.Updates | ForEach-Object { "$($_.Title) [$([math]::Round($_.MaxDownloadSize / 1MB))MB]" })
    Log "Found $($search.Updates.Count) update(s)"
    if ($search.Updates.Count -gt 0) {
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $search.Updates) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) }
        Log 'Downloading'
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
        $ready = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $coll) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
        Log "Installing $($ready.Count) downloaded update(s)"
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $ready
        $ir = $inst.Install()
        $codes = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }
        for ($i = 0; $i -lt $ready.Count; $i++) { $result.Installed += "$($codes[$ir.GetUpdateResult($i).ResultCode]): $($ready.Item($i).Title)" }
        $result.RebootRequired = $ir.RebootRequired
        Log "Install result=$($codes[$ir.ResultCode]) rebootRequired=$($ir.RebootRequired)"
    }
    $result.State = 'done'
} catch {
    $result.State = 'error'; $result.Error = $_.Exception.Message; Log "ERROR $($_.Exception.Message)"
}
$result | ConvertTo-Json -Depth 4 | Set-Content -Path $json -Encoding UTF8
'@

$script:VmbGuestWuStart = {
    param([string]$ScriptText, [string]$Tag)
    $ErrorActionPreference = 'Stop'
    $f = 'C:\ProgramData\vm-broker\wu.ps1'
    [IO.File]::WriteAllText($f, $ScriptText, (New-Object Text.UTF8Encoding $true))
    $act = New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$f`" -Tag $Tag"
    $pr = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'vmb-wu' -TaskPath '\vm-broker\' -Action $act -Principal $pr -Settings $set -Force | Out-Null
    Start-ScheduledTask -TaskName 'vmb-wu' -TaskPath '\vm-broker\'
    $true
}

$script:VmbGuestWuStatus = {
    param([string]$Tag)
    $j = "C:\ProgramData\vm-broker\wu-$Tag.json"
    $t = Get-ScheduledTask -TaskName 'vmb-wu' -TaskPath '\vm-broker\' -ErrorAction SilentlyContinue
    $r = if (Test-Path $j) { Get-Content $j -Raw | ConvertFrom-Json } else { $null }
    [ordered]@{ task = "$($t.State)"; state = if ($r) { $r.State } else { 'starting' }; found = if ($r) { @($r.Found) } else { @() }
                installed = if ($r) { @($r.Installed) } else { @() }; reboot = if ($r) { [bool]$r.RebootRequired } else { $false }; error = if ($r) { $r.Error } else { $null } }
}

# ---- the lab image steps (docs/design.md 8.3), applied to this one VM --------------------------------------

$script:VmbGuestLabSetup = {
    param([string]$StudentPw)
    $ErrorActionPreference = 'Stop'
    $notes = New-Object System.Collections.ArrayList
    function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type
    }
    # auto-logon that lasts: the Winlogon values, not the unattend AutoLogon element (which counts down)
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-Reg $wl 'AutoAdminLogon' '1' 'String'
    Set-Reg $wl 'ForceAutoLogon' '1' 'String'
    Set-Reg $wl 'DefaultUserName' 'student' 'String'
    Set-Reg $wl 'DefaultDomainName' $env:COMPUTERNAME 'String'
    Set-Reg $wl 'DefaultPassword' $StudentPw 'String'
    Remove-ItemProperty -LiteralPath $wl -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    # never locks
    $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-Reg $sys 'InactivityTimeoutSecs' 0
    Set-Reg $sys 'DisableCAD' 1
    Set-Reg $sys 'EnableFirstLogonAnimation' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1
    foreach ($a in @('/change monitor-timeout-ac 0', '/change standby-timeout-ac 0', '/change hibernate-timeout-ac 0', '/hibernate off',
                     '/setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0', '/setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK 0',
                     '/setactive SCHEME_CURRENT')) {
        $null = & powercfg.exe ($a -split ' ') 2>&1
        if ($LASTEXITCODE) { [void]$notes.Add("powercfg $a exit $LASTEXITCODE") }
    }
    # Server Manager, Windows Admin Center and the Azure Arc tray stay off camera
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager' 'DoNotOpenAtLogon' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\ServerManager' 'DoNotPopWACConsoleAtSMLaunch' 1
    Get-ScheduledTask -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName 'ServerManager' -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $f = Get-WindowsFeature -Name AzureArcSetup -ErrorAction SilentlyContinue
        if ($f -and $f.Installed) { $null = Uninstall-WindowsFeature -Name AzureArcSetup; [void]$notes.Add('removed the AzureArcSetup feature') }
    }
    # first-run and consumer prompts by policy, not by clicking
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    foreach ($kv in @(@('HideFirstRunExperience', 1), @('DefaultBrowserSettingEnabled', 0), @('ShowRecommendationsEnabled', 0),
                      @('PromotionalTabsEnabled', 0), @('StartupBoostEnabled', 0), @('BackgroundModeEnabled', 0))) { Set-Reg $edge $kv[0] $kv[1] }
    $cc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    foreach ($n in 'DisableWindowsConsumerFeatures', 'DisableSoftLanding', 'DisableCloudOptimizedContent', 'DisableConsumerAccountStateContent') { Set-Reg $cc $n 1 }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' 'ShutdownReasonOn' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' 'DisableEnhancedNotifications' 1
    if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff')) { New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff' -Force | Out-Null }
    # Windows Update stays held (first contact set it; again here in case an update reset it)
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    # per-user settings: the default profile (student's is made from it at the first logon), and student's own
    function Set-UserHive([string]$Root) {
        Set-Reg "$Root\Control Panel\Desktop" 'ScreenSaveActive' '0' 'String'
        Set-Reg "$Root\Control Panel\Desktop" 'ScreenSaverIsSecure' '0' 'String'
        Set-Reg "$Root\Control Panel\Desktop" 'LogPixels' 96
        Set-Reg "$Root\Control Panel\Desktop" 'Win8DpiScaling' 1
        Set-Reg "$Root\Software\Policies\Microsoft\Windows\Control Panel\Desktop" 'ScreenSaveActive' '0' 'String'
        Set-Reg "$Root\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'AppsUseLightTheme' 1
        Set-Reg "$Root\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'SystemUsesLightTheme' 1
        Set-Reg "$Root\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0
        foreach ($n in 'SubscribedContent-310093Enabled', 'SubscribedContent-338389Enabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled') {
            Set-Reg "$Root\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" $n 0
        }
        Set-Reg "$Root\Software\Microsoft\ServerManager" 'DoNotOpenServerManagerAtLogon' 1
    }
    function Edit-HiveFile([string]$File, [string]$Mount) {
        & reg.exe load "HKU\$Mount" $File | Out-Null
        if ($LASTEXITCODE) { throw "reg load $File failed: $LASTEXITCODE" }
        try { Set-UserHive "Registry::HKEY_USERS\$Mount" }
        finally {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            for ($i = 0; $i -lt 10; $i++) { & reg.exe unload "HKU\$Mount" 2>&1 | Out-Null; if (-not $LASTEXITCODE) { break }; Start-Sleep 1 }
        }
    }
    Edit-HiveFile 'C:\Users\Default\NTUSER.DAT' 'vmb_default'
    $stu = Get-LocalUser -Name student
    $sid = $stu.SID.Value
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") { Set-UserHive "Registry::HKEY_USERS\$sid"; [void]$notes.Add('student hive (logged on)') }
    elseif (Test-Path -LiteralPath 'C:\Users\student\NTUSER.DAT') { Edit-HiveFile 'C:\Users\student\NTUSER.DAT' 'vmb_student'; [void]$notes.Add('student hive (file)') }
    [ordered]@{ notes = @($notes) }
}

# ---- the director (docs/design.md 8.3 and 10) -------------------------------------------------------------

# Before the bundle is copied: the folder with its ACL (inheritance off), the old bin\ removed.
$script:VmbGuestDirectorPrepare = {
    $ErrorActionPreference = 'Stop'
    $root = 'C:\ProgramData\LabDirector'
    Stop-ScheduledTask -TaskName 'LabDirector' -TaskPath '\vm-broker\' -ErrorAction SilentlyContinue
    Get-Process -Name pythonw, python, ffmpeg -ErrorAction SilentlyContinue | Where-Object { "$($_.Path)" -like "$root\bin\*" } | Stop-Process -Force
    foreach ($d in $root, "$root\out") { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
    if (Test-Path -LiteralPath "$root\bin") { Remove-Item -LiteralPath "$root\bin" -Recurse -Force }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($r in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (New-Object Security.Principal.SecurityIdentifier $r[0]), $r[1], $inh, 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $root -AclObject $acl
    $item = Get-Item -LiteralPath $root -Force
    $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
    $true
}

# After the bundle is copied: check every file against the manifest, the student's rights on out\ and
# token.txt, a new per-VM token, and the logon task. No antivirus exclusion: the director runs on the PSF-signed
# embeddable Python, and Defender in the VM scanned and ran it, ffmpeg included, without a finding (2026-10-10).
$script:VmbGuestDirectorFinish = {
    param([string]$ManifestJson)
    $ErrorActionPreference = 'Stop'
    $root = 'C:\ProgramData\LabDirector'
    $m = $ManifestJson | ConvertFrom-Json
    $bad = @()
    foreach ($f in @($m.files)) {
        $p = Join-Path $root $f.path
        if (-not (Test-Path -LiteralPath $p)) { $bad += "missing $($f.path)"; continue }
        if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() -ne ([string]$f.sha256).ToLower()) { $bad += "hash $($f.path)" }
    }
    if ($bad.Count) { throw ('director bundle check failed: ' + ($bad -join ', ')) }
    $student = New-Object Security.Principal.NTAccount "$env:COMPUTERNAME\student"
    $acl = Get-Acl -LiteralPath "$root\out"
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $student, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath "$root\out" -AclObject $acl
    $tok = Join-Path $root 'token.txt'
    if (-not (Test-Path -LiteralPath $tok)) { [IO.File]::WriteAllText($tok, '') }
    $ta = New-Object Security.AccessControl.FileSecurity
    $ta.SetAccessRuleProtection($true, $false)
    $ta.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'), 'FullControl', 'Allow'))
    $ta.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'), 'FullControl', 'Allow'))
    $ta.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $student, 'Read', 'Allow'))
    Set-Acl -LiteralPath $tok -AclObject $ta
    $b = New-Object byte[] 32
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider; $rng.GetBytes($b); $rng.Dispose()
    [IO.File]::WriteAllText($tok, (-join ($b | ForEach-Object { $_.ToString('x2') })))
    $act = New-ScheduledTaskAction -Execute "$root\bin\python\pythonw.exe" -Argument '-I -m vm_director' -WorkingDirectory "$root\bin"
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\student"
    # 30 s after sign-in: an instance started at the very start of the session hung before it listened (serverd,
    # 2026-10-10); a later start serves at once
    $trg.Delay = 'PT30S'
    $pr = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\student" -LogonType Interactive -RunLevel Limited
    # Priority 4 = normal. The default 7 runs the director, and the ffmpeg it starts, below normal with low I/O
    # priority: during sign-in, with the guest's disk at its cap, that first instance starved (serverd, 2026-10-11).
    $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 4
    Register-ScheduledTask -TaskName 'LabDirector' -TaskPath '\vm-broker\' -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
    $started = $false
    if (Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { "$($_.UserName)" -like '*\student' }) {
        Start-ScheduledTask -TaskName 'LabDirector' -TaskPath '\vm-broker\'; $started = $true
    }
    [ordered]@{ files = @($m.files).Count; started = $started }
}

# A director that does not answer: stop its task and any stuck instance, start the task again. Needs the student
# signed in (the task runs in that session).
$script:VmbGuestDirectorRestart = {
    $root = 'C:\ProgramData\LabDirector'
    Stop-ScheduledTask -TaskName 'LabDirector' -TaskPath '\vm-broker\' -ErrorAction SilentlyContinue
    # an ffmpeg left behind would record on to a full disk, and a new director would start a second one
    Get-Process -Name pythonw, python, ffmpeg -ErrorAction SilentlyContinue | Where-Object { "$($_.Path)" -like "$root\bin\*" } | Stop-Process -Force
    Start-Sleep -Seconds 2
    $on = [bool](Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { "$($_.UserName)" -like '*\student' })
    if ($on) { Start-ScheduledTask -TaskName 'LabDirector' -TaskPath '\vm-broker\' }
    $on
}

# The relay: our own loop runs inside the guest, reads the per-VM token there (it never leaves the guest) and
# posts each step to the director on 127.0.0.1. Bodies are consumer data (JSON strings), passed as arguments.
# Stops at the first step that fails. Returns the director's raw JSON answers.
$script:VmbGuestDirectorRelay = {
    param([string]$StepsJson)
    $ErrorActionPreference = 'Stop'
    $tokPath = 'C:\ProgramData\LabDirector\token.txt'
    if (-not (Test-Path -LiteralPath $tokPath)) { return , @('{"ok":false,"error":"no-director","detail":"the director is not installed in this VM"}') }
    $tok = ([IO.File]::ReadAllText($tokPath)).Trim()
    $answers = New-Object System.Collections.ArrayList
    # 5.1's ConvertFrom-Json writes an array as ONE object: no @() here, so foreach walks its items
    foreach ($s in ($StepsJson | ConvertFrom-Json)) {
        $body = [Text.Encoding]::UTF8.GetBytes([string]$s.body)
        $text = $null
        try {
            # X-Vmb-Timeout: the director starts no input after this many seconds, so a step given up here never
            # types or clicks later (a retry would do it twice on camera)
            $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ('http://127.0.0.1:47800' + [string]$s.endpoint) `
                -Headers @{ Authorization = "Bearer $tok"; 'X-Vmb-Timeout' = [string][int]$s.timeout_s } -MaximumRedirection 0 `
                -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec ([int]$s.timeout_s)
            $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        } catch {
            $resp = $_.Exception.Response
            if ($resp) {
                $code = [int]$resp.StatusCode
                $text = '{"ok":false,"error":"http-' + $code + '","detail":"the director answered HTTP ' + $code + '"}'
            } elseif ($_.Exception -is [System.Net.WebException] -and "$($_.Exception.Status)" -eq 'Timeout') {
                $text = '{"ok":false,"error":"relay-timeout","detail":"no answer within ' + [int]$s.timeout_s + ' s; the director may still be working on this step"}'
            } else {
                $msg = ("$($_.Exception.Message)" -replace '[^\x20-\x7E]', ' ' -replace '["\\]', ' ')
                $text = '{"ok":false,"error":"no-director","detail":"' + $msg + '"}'
            }
        }
        [void]$answers.Add($text)
        if ($text -notmatch '"ok"\s*:\s*true') { break }
    }
    , @($answers)
}

# ---- running a consumer command (docs/design.md 5.1 vm_run) -----------------------------------------------
# The command becomes code only here, inside the guest: written to a file and run by a child powershell.exe,
# with a timeout and the output cut at MaxChars.
$script:VmbGuestRun = {
    param([string]$Command, [int]$TimeoutS, [int]$MaxChars, [bool]$Interactive)
    $ErrorActionPreference = 'Stop'
    $d = 'C:\ProgramData\vm-broker\run'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    $f = Join-Path $d ([guid]::NewGuid().ToString('N') + '.ps1')
    $prefix = "[Console]::OutputEncoding = New-Object Text.UTF8Encoding `$false`r`n"
    [IO.File]::WriteAllText($f, $prefix + $Command, (New-Object Text.UTF8Encoding $true))
    $ps = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Interactive) {
            $stu = Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { "$($_.UserName)" -like '*\student' }
            if (-not $stu) { return [ordered]@{ error = 'no-session'; detail = 'student is not logged on' } }
            $acl = Get-Acl -LiteralPath $f
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule "$env:COMPUTERNAME\student", 'Read', 'Allow'))
            Set-Acl -LiteralPath $f -AclObject $acl
            $acld = Get-Acl -LiteralPath $d
            $acld.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule "$env:COMPUTERNAME\student", 'ReadAndExecute', 'Allow'))
            Set-Acl -LiteralPath $d -AclObject $acld
            $name = 'vmb-run-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
            $act = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$f`""
            $pr = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\student" -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $name -TaskPath '\vm-broker\' -Action $act -Principal $pr -Force | Out-Null
            try {
                Start-ScheduledTask -TaskName $name -TaskPath '\vm-broker\'
                Start-Sleep -Seconds 1
                $timedOut = $true
                while ($sw.Elapsed.TotalSeconds -lt $TimeoutS) {
                    if ("$((Get-ScheduledTask -TaskName $name -TaskPath '\vm-broker\').State)" -ne 'Running') { $timedOut = $false; break }
                    Start-Sleep -Milliseconds 500
                }
                if ($timedOut) { Stop-ScheduledTask -TaskName $name -TaskPath '\vm-broker\' -ErrorAction SilentlyContinue }
                $info = Get-ScheduledTaskInfo -TaskName $name -TaskPath '\vm-broker\'
                return [ordered]@{ exit_code = [int]$info.LastTaskResult; stdout = ''; stderr = ''; timed_out = $timedOut; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); interactive = $true }
            } finally { Unregister-ScheduledTask -TaskName $name -TaskPath '\vm-broker\' -Confirm:$false -ErrorAction SilentlyContinue }
        }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $ps
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$f`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        $timedOut = -not $p.WaitForExit($TimeoutS * 1000)
        if ($timedOut) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null; $null = $p.WaitForExit(10000) }
        $out = if ($o.Wait(10000)) { $o.Result } else { '' }
        $err = if ($e.Wait(10000)) { $e.Result } else { '' }
        $cutO = $out.Length -gt $MaxChars; $cutE = $err.Length -gt $MaxChars
        if ($cutO) { $out = $out.Substring(0, $MaxChars) }
        if ($cutE) { $err = $err.Substring(0, $MaxChars) }
        [ordered]@{ exit_code = if ($timedOut) { $null } else { $p.ExitCode }; stdout = $out; stderr = $err; stdout_cut = $cutO; stderr_cut = $cutE
                    timed_out = $timedOut; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); interactive = $false }
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

# ---- files (chunked, so the host can throttle; a byte[] travels as one object) ----------------------------

$script:VmbGuestFileInfo = {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return [ordered]@{ exists = $false; dir = [IO.Directory]::Exists($Path) } }
    [ordered]@{ exists = $true; bytes = (New-Object IO.FileInfo $Path).Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower() }
}

$script:VmbGuestReadChunk = {
    param([string]$Path, [long]$Offset, [int]$Count)
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($Offset, 'Begin')
        $buf = New-Object byte[] $Count
        $n = $fs.Read($buf, 0, $Count)
        if ($n -lt $Count) { $b2 = New-Object byte[] $n; [Array]::Copy($buf, $b2, $n); $buf = $b2 }
        , $buf
    } finally { $fs.Dispose() }
}

$script:VmbGuestWriteChunk = {
    param([string]$Path, [long]$Offset, [byte[]]$Bytes, [bool]$First)
    if ($First) {
        $dir = [IO.Path]::GetDirectoryName($Path)
        if ($dir -and -not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    }
    $mode = if ($First) { 'Create' } else { 'Open' }
    $fs = [IO.File]::Open($Path, $mode, 'Write', 'None')
    try { [void]$fs.Seek($Offset, 'Begin'); $fs.Write($Bytes, 0, $Bytes.Length) } finally { $fs.Dispose() }
    $true
}

# A copy-to that failed or whose hash does not match leaves no partial file behind.
$script:VmbGuestRemoveFile = {
    param([string]$Path)
    if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
    $true
}
