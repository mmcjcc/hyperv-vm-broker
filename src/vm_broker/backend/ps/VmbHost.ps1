# VmbHost.ps1 - host-level verbs: inventory, firewall measurement, one-time install, code and media staging,
# the ISO copy. Dot-sourced by Vmb.ps1. Windows PowerShell 5.1, ASCII only.

# ---- inventory (read-only) ------------------------------------------------------------------------------

function Get-VmbInventory {
    param($A)
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $vmRoot = Split-Path -Parent $script:VmbRoot
    $vms = @(Get-VM | ForEach-Object {
        [ordered]@{
            name = $_.Name; id = $_.Id.ToString(); state = "$($_.State)"; generation = $_.Generation
            version = "$($_.Version)"; cpus = $_.ProcessorCount
            memory_assigned_mb = [int64]($_.MemoryAssigned / 1MB); memory_startup_mb = [int64]($_.MemoryStartup / 1MB)
            dynamic = [bool]$_.DynamicMemoryEnabled; memory_max_mb = [int64]($_.MemoryMaximum / 1MB)
            replication = "$($_.ReplicationState)"; broker_name = $_.Name.StartsWith('vmb-')
        }
    })
    $switches = @(Get-VMSwitch | ForEach-Object { [ordered]@{ name = $_.Name; type = "$($_.SwitchType)"; management_os = [bool]$_.AllowManagementOS } })
    $drive = (Split-Path -Qualifier $vmRoot).TrimEnd(':')
    $vol = Get-Volume -DriveLetter $drive
    $isoDir = Join-Path $vmRoot 'iso'
    $isos = @()
    if (Test-Path -LiteralPath $isoDir) {
        $isos = @(Get-ChildItem -LiteralPath $isoDir -File | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length } })
    }
    $versions = @()
    try { $versions = @(Get-VMHostSupportedVersion | ForEach-Object { "$($_.Version)" }) } catch { }
    $default = ''
    try { $default = "$((Get-VMHostSupportedVersion -Default).Version)" } catch { }
    $logKeys = [ordered]@{}
    foreach ($k in @('ScriptBlockLogging\EnableScriptBlockLogging', 'ModuleLogging\EnableModuleLogging', 'Transcription\EnableTranscripting')) {
        $parts = $k.Split('\')
        $v = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\$($parts[0])" -Name $parts[1] -ErrorAction SilentlyContinue
        $logKeys[$parts[0]] = if ($v) { [int]$v.($parts[1]) } else { $null }
    }
    $broker = [ordered]@{ installed = $false }
    if ([IO.File]::Exists((Get-VmbPath 'policy.json'))) {
        $acl = Get-Acl -LiteralPath $script:VmbRoot
        $broker = [ordered]@{
            installed = $true
            code = (Get-VmbCodeVersion)
            policy = (Read-VmbJson (Get-VmbPath 'policy.json'))
            cert = [bool](Get-VmbSecretCert)
            acl_protected = [bool]$acl.AreAccessRulesProtected
            acl = @($acl.Access | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights) $($_.AccessControlType)" })
            records = @(Get-VmbRecords | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; state = $_.state; owner = $_.owner; vmid = (Get-VmbField $_ 'vmid') } })
            director_media = (Get-VmbDirectorMedia)
        }
    }
    New-VmbOk @{
        host = $env:COMPUTERNAME.ToLower(); time = (Get-VmbNow)
        os = $os.Caption; build = $os.BuildNumber
        memory = [ordered]@{ total_mb = [int64]($cs.TotalPhysicalMemory / 1MB); available_mb = [int64]($os.FreePhysicalMemory / 1024) }
        logical_cpus = $cs.NumberOfLogicalProcessors
        volume = [ordered]@{ root = $vmRoot; free_gb = [math]::Round($vol.SizeRemaining / 1GB, 1); size_gb = [math]::Round($vol.Size / 1GB, 1) }
        vms = $vms; switches = $switches; isos = $isos
        hyperv = [ordered]@{ versions = $versions; default = $default }
        adk_dism = (Test-Path -LiteralPath "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe")
        execution_policy = @(Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" })
        powershell_logging = $logKeys
        broker = $broker
    }
}

# ---- firewall measurement (docs/design.md 14: "the firewall must not notice") ------------------------------

function Get-VmbStats {
    param([double[]]$Values, [int]$Lost)
    $v = @($Values | Sort-Object)
    if (-not $v.Count) { return [ordered]@{ n = 0; lost = $Lost } }
    $p = { param($q) $v[[math]::Min($v.Count - 1, [int][math]::Floor($q * ($v.Count - 1) + 0.5))] }
    [ordered]@{
        n = $v.Count; lost = $Lost
        p50 = [math]::Round((& $p 0.5), 2); p95 = [math]::Round((& $p 0.95), 2); max = [math]::Round($v[-1], 2)
        mean = [math]::Round(($v | Measure-Object -Average).Average, 2)
    }
}

# One sample: ping and DNS through the firewall, and the host counters that show contention.
function Get-VmbFirewallSample {
    param($Targets, [string[]]$Counters)
    $s = [ordered]@{ t = (Get-VmbNow) }
    $ping = New-Object Net.NetworkInformation.Ping
    try {
        foreach ($ip in @($Targets.ping)) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { $r = $ping.Send($ip, 1000); $ok = ("$($r.Status)" -eq 'Success') } catch { $ok = $false }
            $s["ping $ip"] = if ($ok) { [math]::Round($sw.Elapsed.TotalMilliseconds, 2) } else { $null }
        }
    } finally { $ping.Dispose() }
    foreach ($d in @($Targets.dns)) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Resolve-DnsName -Name $d.name -Server $d.server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
            $s["dns $($d.server)"] = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        } catch { $s["dns $($d.server)"] = $null }
    }
    # replicas held here (serverd holds Firewall3's): 0 normal, 1 warning, 2 critical, and minutes since the last cycle
    foreach ($r in @(Get-VMReplication -ErrorAction SilentlyContinue | Where-Object { "$($_.Mode)" -eq 'Replica' })) {
        $s["replica $($r.Name) health"] = switch ("$($r.Health)") { 'Normal' { 0 } 'Warning' { 1 } 'Critical' { 2 } default { 3 } }
        if ($r.LastReplicationTime) { $s["replica $($r.Name) lag_min"] = [math]::Round(((Get-Date) - $r.LastReplicationTime).TotalMinutes, 2) }
    }
    try {
        $c = Get-Counter -Counter $Counters -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
        foreach ($x in @($c.CounterSamples)) {
            $key = ($x.Path -replace '^\\\\[^\\]+', '').ToLower()
            $s[$key] = [math]::Round($x.CookedValue, 4)
        }
    } catch { }
    $s
}

function Get-VmbCounterList {
    param([string]$Firewall)
    @('\Hyper-V Hypervisor Logical Processor(_Total)\% Total Run Time',
      "\Hyper-V Hypervisor Virtual Processor($($Firewall):*)\% Total Run Time",
      '\Hyper-V Hypervisor Virtual Processor(vmb-*)\% Total Run Time',
      '\PhysicalDisk(_Total)\Avg. Disk sec/Write', '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
      '\PhysicalDisk(_Total)\Current Disk Queue Length', '\Memory\Available MBytes')
}

function Get-VmbDefaultTargets {
    [ordered]@{ ping = @('192.168.10.1', '1.1.1.1'); dns = @(@{ server = '1.1.1.1'; name = 'example.com' }, @{ server = '192.168.10.1'; name = 'example.com' }) }
}

# Summaries per metric over a list of samples (ping and DNS in ms; counters as read).
function Get-VmbSampleSummary {
    param($Samples)
    $keys = New-Object System.Collections.ArrayList
    foreach ($s in $Samples) { foreach ($k in $s.Keys) { if ($k -ne 't' -and -not $keys.Contains($k)) { [void]$keys.Add($k) } } }
    $sum = [ordered]@{}
    foreach ($k in $keys) {
        $vals = New-Object System.Collections.ArrayList; $lost = 0
        foreach ($s in $Samples) {
            if (-not $s.Contains($k)) { continue }
            if ($null -eq $s[$k]) { $lost++ } else { [void]$vals.Add([double]$s[$k]) }
        }
        $sum[$k] = Get-VmbStats ([double[]]$vals) $lost
    }
    $sum
}

# Read-only, inline (no files written): the baseline before anything runs. At most 10 minutes per call.
function Measure-VmbFirewall {
    param($A)
    $dur = [int](Get-VmbField $A 'duration_s' 300); if ($dur -lt 10 -or $dur -gt 600) { Stop-Vmb 2 'rejected' 'duration_s must be 10..600' }
    $int = [int](Get-VmbField $A 'interval_s' 5); if ($int -lt 2 -or $int -gt 60) { Stop-Vmb 2 'rejected' 'interval_s must be 2..60' }
    $fw = [string](Get-VmbField $A 'firewall_vm' 'Firewall3')
    if ($fw -notmatch '^[A-Za-z0-9-]{1,32}\z') { Stop-Vmb 2 'rejected' 'bad firewall VM name' }
    $targets = Get-VmbDefaultTargets
    $counters = Get-VmbCounterList $fw
    $samples = New-Object System.Collections.ArrayList
    $until = [DateTime]::UtcNow.AddSeconds($dur)
    while ([DateTime]::UtcNow -lt $until) {
        $t = [DateTime]::UtcNow
        [void]$samples.Add((Get-VmbFirewallSample $targets $counters))
        $left = $int - ([DateTime]::UtcNow - $t).TotalSeconds
        if ($left -gt 0) { Start-Sleep -Milliseconds ([int]($left * 1000)) }
    }
    New-VmbOk @{ host = $env:COMPUTERNAME.ToLower(); from = $samples[0].t; to = $samples[-1].t; samples = @($samples); summary = (Get-VmbSampleSummary $samples) }
}

# The monitor job: one sample every interval_s for hours, one JSON line each in state\fwmon\<date>.jsonl.
function Invoke-VmbFirewallMonitor {
    param($Job)
    $A = $Job.args
    $pol = Get-VmbPolicy
    $hours = [double](Get-VmbField $A 'hours' 8); if ($hours -le 0 -or $hours -gt 96) { Stop-Vmb 2 'rejected' 'hours must be 0..96' }
    $int = [int](Get-VmbField $A 'interval_s' 10)
    $targets = Get-VmbDefaultTargets
    $counters = Get-VmbCounterList ([string]$pol.firewall_vm)
    $until = [DateTime]::UtcNow.AddHours($hours)
    $dir = Get-VmbPath 'state\fwmon'
    [void][IO.Directory]::CreateDirectory($dir)
    while ([DateTime]::UtcNow -lt $until) {
        $t = [DateTime]::UtcNow
        $s = Get-VmbFirewallSample $targets $counters
        [IO.File]::AppendAllText((Join-Path $dir ($t.ToString('yyyy-MM-dd') + '.jsonl')), (ConvertTo-VmbJson $s) + "`n")
        $left = $int - ([DateTime]::UtcNow - $t).TotalSeconds
        if ($left -gt 0) { Start-Sleep -Milliseconds ([int]($left * 1000)) }
        $j = Read-VmbJson (Get-VmbPath "jobs\$($Job.id).json")
        if ($j -and $j.state -eq 'cancelled') { break }
    }
    @{ samples_until = (Get-VmbNow) }
}

# Summaries of the monitor's samples between two UTC times (ISO 8601), read-only.
function Get-VmbFirewallSummary {
    param($A)
    $from = [DateTime]::Parse([string](Get-VmbField $A 'from'), [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal')
    $to = [DateTime]::Parse([string](Get-VmbField $A 'to' (Get-VmbNow)), [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal')
    $dir = Get-VmbPath 'state\fwmon'
    $samples = New-Object System.Collections.ArrayList
    for ($d = $from.Date; $d -le $to.Date; $d = $d.AddDays(1)) {
        $f = Join-Path $dir ($d.ToString('yyyy-MM-dd') + '.jsonl')
        if (-not [IO.File]::Exists($f)) { continue }
        foreach ($line in [IO.File]::ReadAllLines($f)) {
            if (-not $line) { continue }
            $o = ConvertTo-VmbHashtable ($line | ConvertFrom-Json)
            $t = [DateTime]::Parse([string]$o.t, [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal')
            if ($t -ge $from -and $t -le $to) { [void]$samples.Add($o) }
        }
    }
    New-VmbOk @{ from = $from.ToString('yyyy-MM-ddTHH:mm:ssZ'); to = $to.ToString('yyyy-MM-ddTHH:mm:ssZ'); n = $samples.Count; summary = (Get-VmbSampleSummary $samples) }
}

# ---- one-time install (docs/design.md 3.8), with an uninstall ------------------------------------------

function Set-VmbFolderAcl {
    param([string]$Path)
    if (-not (Test-VmbChange "ACL of $Path (inheritance off; SYSTEM and Administrators full control)")) { return }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $id = New-Object Security.Principal.SecurityIdentifier $sid
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $id, 'FullControl', $inherit, 'None', 'Allow'))
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Install-VmbHost {
    param($A)
    $done = New-Object System.Collections.ArrayList
    $root = $script:VmbRoot
    if (-not [IO.Directory]::Exists($root)) {
        if (Test-VmbChange "create $root") { [void][IO.Directory]::CreateDirectory($root); [void]$done.Add("created $root") }
    }
    if ([IO.Directory]::Exists($root)) { Set-VmbFolderAcl $root } else { [void]$script:VmbPlanned.Add("ACL of $root") }
    foreach ($sub in 'code', 'state', 'state\vms', 'state\fwmon', 'jobs', 'vms', 'secrets', 'stage', 'media') {
        $p = Join-Path $root $sub
        if (-not [IO.Directory]::Exists($p)) {
            if (Test-VmbChange "create $p") { [void][IO.Directory]::CreateDirectory($p); [void]$done.Add("created $p") }
        }
    }
    $polPath = Join-Path $root 'policy.json'
    $pol = Get-VmbField $A 'policy'
    if (-not [IO.File]::Exists($polPath)) {
        if (-not $pol) { Stop-Vmb 2 'rejected' 'install needs the initial policy' }
        $bad = @(Test-VmbPolicy $pol)
        if ($bad.Count) { Stop-Vmb 2 'rejected' ('the policy fails its checks: ' + ($bad -join '; ')) }
        Write-VmbJson $polPath $pol
        if (-not $script:VmbWhatIf) { [void]$done.Add('wrote policy.json') }
    }
    if ((Get-VmbField $A 'secrets' 'cms') -eq 'cms' -and -not (Get-VmbSecretCert)) {
        if (Test-VmbChange "create the self-signed 'vm-broker secrets' certificate in LocalMachine\My") {
            $c = New-SelfSignedCertificate -Type DocumentEncryptionCert -Subject 'CN=vm-broker secrets' -FriendlyName 'vm-broker secrets' `
                -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 3072 -NotAfter (Get-Date).AddYears(10)
            [void]$done.Add("created certificate $($c.Thumbprint)")
        }
    }
    New-VmbOk @{ root = $root; done = @($done); cert = [bool](Get-VmbSecretCert) }
}

# Refuses while any broker VM is not destroyed: uninstalling never orphans a VM or its secrets.
function Uninstall-VmbHost {
    param($A)
    $live = @(Get-VmbRecords | Where-Object { $_.state -ne 'destroyed' })
    if ($live.Count) { Stop-Vmb 2 'rejected' "$($live.Count) broker VM(s) still exist; destroy them first" }
    $broker = @(Get-VM | Where-Object { $_.Name.StartsWith('vmb-') })
    if ($broker.Count) { Stop-Vmb 2 'rejected' 'Hyper-V still has VMs named vmb-*; refusing' }
    $done = @()
    if (Test-VmbChange "remove $script:VmbRoot") { Remove-Item -LiteralPath $script:VmbRoot -Recurse -Force; $done += "removed $script:VmbRoot" }
    if ((Get-VmbField $A 'remove_cert' $false) -eq $true) {
        foreach ($c in @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq 'CN=vm-broker secrets' })) {
            if (Test-VmbChange "remove certificate $($c.Thumbprint)") { Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($c.Thumbprint)" -DeleteKey; $done += "removed certificate $($c.Thumbprint)" }
        }
    }
    foreach ($t in @(Get-ScheduledTask -TaskPath '\vm-broker\' -ErrorAction SilentlyContinue)) {
        if (Test-VmbChange "unregister task $($t.TaskName)") { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath '\vm-broker\' -Confirm:$false; $done += "removed task $($t.TaskName)" }
    }
    New-VmbOk @{ done = $done }
}

function Set-VmbPolicyFile {
    param($A)
    $pol = Get-VmbField $A 'policy'
    if (-not $pol -or (Get-VmbField $pol 'policy') -ne 1) { Stop-Vmb 2 'rejected' 'set-policy needs a policy object with policy: 1' }
    $bad = @(Test-VmbPolicy $pol)
    if ($bad.Count) { Stop-Vmb 2 'rejected' ('the policy fails its checks: ' + ($bad -join '; ')) }
    $lock = Enter-VmbLock
    try { Write-VmbJson (Get-VmbPath 'policy.json') $pol } finally { Exit-VmbLock $lock }
    New-VmbOk @{ policy = $pol }
}

# ---- staging folders, code and media --------------------------------------------------------------------

function New-VmbStage {
    $id = New-VmbId
    $p = Get-VmbPath "stage\$id"
    if (Test-VmbChange "create $p") { [void][IO.Directory]::CreateDirectory($p) }
    New-VmbOk @{ stage = $p }
}

function Resolve-VmbStage {
    param([string]$Stage)
    $base = (Get-VmbPath 'stage').TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Stage)
    $leaf = Split-Path -Leaf $full
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or $leaf -cnotmatch $script:VmbIdPattern -or (Split-Path -Parent $full).TrimEnd('\') + '\' -ne $base) {
        Stop-Vmb 2 'rejected' 'a stage folder must be directly under vmb\stage'
    }
    $full
}

function Remove-VmbStage {
    param($A)
    $p = Resolve-VmbStage ([string](Get-VmbField $A 'stage'))
    if ([IO.Directory]::Exists($p) -and (Test-VmbChange "remove $p")) { Remove-Item -LiteralPath $p -Recurse -Force }
    New-VmbOk @{ removed = $p }
}

function Get-VmbFileHash {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

# Checks an uploaded tree against its manifest: every listed file exists with its SHA-256, nothing else is there.
function Test-VmbManifest {
    param([string]$Dir, $Files)
    $want = @{}
    foreach ($f in @($Files)) {
        $rel = [string]$f.path
        if ($rel -notmatch '^[A-Za-z0-9_][A-Za-z0-9_. -]*(\\[A-Za-z0-9_][A-Za-z0-9_. -]*)*\z' -or $rel -match '\.\.') { Stop-Vmb 2 'rejected' "bad manifest path: $rel" }
        $want[$rel.ToLower()] = ([string]$f.sha256).ToLower()
    }
    $base = $Dir.TrimEnd('\') + '\'
    $have = @(Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object { $_.FullName.Substring($base.Length) })
    foreach ($h in $have) { if (-not $want.ContainsKey($h.ToLower())) { Stop-Vmb 2 'rejected' "unexpected file in the upload: $h" } }
    foreach ($k in $want.Keys) {
        $p = Join-Path $Dir $k
        if (-not [IO.File]::Exists($p)) { Stop-Vmb 1 'failed' "missing from the upload: $k" }
        if ((Get-VmbFileHash $p) -ne $want[$k]) { Stop-Vmb 1 'failed' "SHA-256 mismatch after upload: $k" }
    }
    $want.Count
}

function Install-VmbCode {
    param($A)
    $stage = Resolve-VmbStage ([string](Get-VmbField $A 'stage'))
    $version = [string](Get-VmbField $A 'version')
    if ($version -cnotmatch '^[0-9a-f]{64}\z') { Stop-Vmb 2 'rejected' 'bad code version' }
    $files = @(Get-VmbField $A 'files')
    foreach ($f in $files) { if ([string]$f.path -notmatch '^[A-Za-z][A-Za-z0-9-]*\.ps1\z') { Stop-Vmb 2 'rejected' "only top-level .ps1 files go into code\: $($f.path)" } }
    $n = Test-VmbManifest $stage $files
    $code = Get-VmbPath 'code'
    $lock = Enter-VmbLock
    try {
        if (Test-VmbChange "replace the scripts in $code ($n files)") {
            foreach ($old in @(Get-ChildItem -LiteralPath $code -File)) { Remove-Item -LiteralPath $old.FullName -Force }
            foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $stage $f.path) -Destination (Join-Path $code $f.path) }
            [IO.File]::WriteAllText((Join-Path $code 'VERSION'), $version)
        }
        if (Test-VmbChange "remove $stage") { Remove-Item -LiteralPath $stage -Recurse -Force }
    } finally { Exit-VmbLock $lock }
    New-VmbOk @{ code = $version; files = $n }
}

# The director bundle (Python embeddable + vm_director + ffmpeg) under media\labdirector\<version>\.
function Get-VmbDirectorMedia {
    $cur = Get-VmbPath 'media\labdirector\current.txt'
    if (-not [IO.File]::Exists($cur)) { return $null }
    $v = ([IO.File]::ReadAllText($cur)).Trim()
    $dir = Get-VmbPath "media\labdirector\$v"
    if (-not [IO.Directory]::Exists($dir)) { return $null }
    [ordered]@{ version = $v; path = $dir }
}

function Install-VmbDirectorMedia {
    param($A)
    $stage = Resolve-VmbStage ([string](Get-VmbField $A 'stage'))
    $version = [string](Get-VmbField $A 'version')
    if ($version -cnotmatch '^[0-9a-f]{16}\z') { Stop-Vmb 2 'rejected' 'bad media version (16 hex)' }
    $n = Test-VmbManifest $stage @(Get-VmbField $A 'files')
    $dest = Get-VmbPath "media\labdirector\$version"
    if (Test-VmbChange "move the director bundle to $dest") {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
        if ([IO.Directory]::Exists($dest)) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $stage -Destination $dest
        [IO.File]::WriteAllText((Get-VmbPath 'media\labdirector\current.txt'), $version)
    }
    New-VmbOk @{ media = $version; files = $n }
}

# ---- the ISO copy from another host (a netadmin step the operator approved; docs/design.md 8.2) ---------------
# Runs in a WinRM session with the credential passed explicitly (no double hop). Throttled; hashed while it
# copies; writes <dest>.partial, then renames and writes <dest>.sha256. Resumes nothing: a partial is restarted.

function Copy-VmbIso {
    param($A, [pscredential]$Credential)
    $src = [string](Get-VmbField $A 'source')            # \\serverd.corp.example\D$\VMs\iso\<file>.iso
    $mbps = [double](Get-VmbField $A 'mbps' 8)
    $wait = [bool](Get-VmbField $A 'wait_for_window' $true)
    if ($src -notmatch '^\\\\[a-z0-9.-]+\\[A-Za-z]\$\\VMs\\iso\\[A-Za-z0-9_.-]+\.iso\z') { Stop-Vmb 2 'rejected' 'bad ISO source path' }
    if ($mbps -lt 1 -or $mbps -gt 50) { Stop-Vmb 2 'rejected' 'mbps must be 1..50' }
    $destDir = Join-Path (Split-Path -Parent $script:VmbRoot) 'iso'
    $dest = Join-Path $destDir (Split-Path -Leaf $src)
    if ([IO.File]::Exists($dest) -and [IO.File]::Exists("$dest.sha256")) { return New-VmbOk @{ dest = $dest; already = $true; sha256 = ([IO.File]::ReadAllText("$dest.sha256")).Trim() } }
    $pol = Get-VmbPolicy
    if ($wait) { while (-not (Test-VmbCopyWindow $pol)) { Start-Sleep -Seconds 60 } }
    if (-not (Test-VmbChange "copy $src to $dest at $mbps MB/s")) { return New-VmbOk @{ dest = $dest } }
    $share = ($src -split '\\')[0..3] -join '\'
    $drv = New-PSDrive -Name ('vmbiso' + (Get-Random)) -PSProvider FileSystem -Root $share -Credential $Credential
    try {
        [void][IO.Directory]::CreateDirectory($destDir)
        $part = "$dest.partial"
        $in = [IO.File]::OpenRead($src)
        $out = [IO.File]::Open($part, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $sha = [Security.Cryptography.SHA256]::Create()
        $buf = New-Object byte[] (1MB)
        $sw = [Diagnostics.Stopwatch]::StartNew(); $n = 0L
        try {
            while (($r = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $r); [void]$sha.TransformBlock($buf, 0, $r, $null, 0); $n += $r
                $ahead = $n / ($mbps * 1MB) - $sw.Elapsed.TotalSeconds
                if ($ahead -gt 0.05) { Start-Sleep -Milliseconds ([int]($ahead * 1000)) }
            }
            [void]$sha.TransformFinalBlock($buf, 0, 0)
        } finally { $in.Dispose(); $out.Dispose() }
        $hex = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
        Move-Item -LiteralPath $part -Destination $dest -Force
        [IO.File]::WriteAllText("$dest.sha256", $hex)
        New-VmbOk @{ dest = $dest; bytes = $n; sha256 = $hex; minutes = [math]::Round($sw.Elapsed.TotalMinutes, 1) }
    } finally {
        Remove-PSDrive -Name $drv.Name -ErrorAction SilentlyContinue
    }
}
