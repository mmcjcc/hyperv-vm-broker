# Ownership.Tests.ps1 - Get-VmbVM (docs/design.md 6.1, 6.2), Test-VmbGuards (6.3 to 6.5), Test-VmbPaths (6.3).
# Pester 3.4, Windows PowerShell 5.1, ASCII only. Hyper-V is the fake in VmbTestHelpers.ps1.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'VmbTestHelpers.ps1')

try {
Describe 'Get-VmbVM: a VM is the broker''s only when name, VMId, Notes and record agree' {
    It 'passes a VM whose name, VMId and Notes agree with its record' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $vm = Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy)
        "$($vm.Id)" | Should Be "$($t.VM.Id)"
        $vm.Name | Should BeExactly 'vmb-lab-p1'
        $byId = @((Get-VmbCalls 'Get-VM') | Where-Object { $_.Params.ContainsKey('Id') })
        $byId.Count | Should Be 1
        "$($byId[0].Params['Id'])" | Should Be "$($t.VM.Id)"
    }

    It 'refuses when the Hyper-V name differs from the record' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $t.VM.Name = 'vmb-other'
        $r = Get-VmbRefusal { Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'not-broker'
        $r.hint | Should Match "now called 'vmb-other'"
    }

    It 'refuses a record whose VMId belongs to another VM (Firewall3)' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $rec = Get-VmbRecord $t.Id
        $rec.vmid = "$((@($global:VmbFake.VMs) | Where-Object { $_.Name -eq 'Firewall3' }).Id)"
        $r = Get-VmbRefusal { Get-VmbVM $rec (Get-VmbPolicy) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'not-broker'
        $r.hint | Should Match "now called 'Firewall3'"
    }

    It 'refuses when the record''s Hyper-V name is not vmb-<name>' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $rec = Get-VmbRecord $t.Id
        $rec.hyperv_name = 'lab-p1'
        $r = Get-VmbRefusal { Get-VmbVM $rec (Get-VmbPolicy) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'not-broker'
    }

    It 'refuses when the Notes are <Case>' -TestCases @(
        @{ Case = 'empty'; Notes = '' }
        @{ Case = 'for another id'; Notes = 'vm-broker id=0123456789abcdef0123456789abcdef; do not edit' }
        @{ Case = 'without "; do not edit"'; Notes = 'vm-broker id=<id>' }
        @{ Case = 'not at the start'; Notes = 'x vm-broker id=<id>; do not edit' }
        @{ Case = 'edited by hand'; Notes = 'production firewall' }
    ) {
        param($Case, $Notes)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $t.VM.Notes = $Notes.Replace('<id>', $t.Id)
        $r = Get-VmbRefusal { Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'not-broker'
        $r.hint | Should Match 'Notes tag'
    }

    It 'refuses when two VMs share the name' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $null = Add-VmbFakeVM -Name 'vmb-lab-p1' -Notes "vm-broker id=$($t.Id); do not edit" -State 'Off'
        $r = Get-VmbRefusal { Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'duplicate-name'
        $r.hint | Should Match "2 VMs are called 'vmb-lab-p1'"
    }

    It 'refuses a VM with Hyper-V Replica (<State>)' -TestCases @(@{ State = 'Replicating' }, @{ State = 'Suspended' }, @{ State = 'WaitingForStartResynchronize' }) {
        param($State)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $t.VM.ReplicationState = $State
        $r = Get-VmbRefusal { Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'not-broker'
        $r.hint | Should Match 'Replica'
    }

    It 'refuses a destroyed record' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -RecordState 'destroyed'
        $r = Get-VmbRefusal { Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'unknown-vm'
        (Get-VmbCalls 'Get-VM').Count | Should Be 0
    }

    It 'refuses a record without a vmid' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -RecordState 'creating'
        $rec = Get-VmbRecord $t.Id
        $rec.vmid = $null
        $r = Get-VmbRefusal { Get-VmbVM $rec (Get-VmbPolicy) }
        $r.exit | Should Be 1
        $r.error | Should BeExactly 'failed'
        $r.hint | Should Match 'never created'
        (Get-VmbCalls 'Get-VM').Count | Should Be 0
    }

    It 'refuses when the VM with that id is gone' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $global:VmbFake.VMs.Remove($t.VM)
        $r = Get-VmbRefusal { Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy) }
        $r.exit | Should Be 1
        $r.error | Should BeExactly 'missing'
    }

    It 'refuses the production name <Name> before any other check, even with a matching record' -TestCases @(
        @{ Name = 'Firewall3' }, @{ Name = 'Firewall4' }, @{ Name = 'servera' }, @{ Name = 'serverd' }, @{ Name = 'servere' },
        @{ Name = 'docker01' }, @{ Name = 'claude01' }, @{ Name = 'cloud01' }, @{ Name = 'ops01' }, @{ Name = 'LabHV1' },
        @{ Name = 'LabClient' }, @{ Name = 'LabISP' }, @{ Name = 'FIREWALL3' }, @{ Name = 'labhv2' }
    ) {
        param($Name)
        $null = New-VmbTestRoot
        $id = New-VmbId
        $vm = Add-VmbFakeVM -Name $Name -Notes "vm-broker id=$id; do not edit" -State 'Running'
        $rec = [pscustomobject]@{ id = $id; name = $Name; hyperv_name = $Name; vmid = "$($vm.Id)"; state = 'ready'; owner = 'cs101-walkthroughs' }
        $global:VmbCalls.Clear()
        $r = Get-VmbRefusal { Get-VmbVM $rec (Get-VmbPolicy) }
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'not-broker'
        $r.hint | Should Match 'denylist'
        (Get-VmbCalls 'Get-VM').Count | Should Be 0
        (Get-VmbCalls 'Get-VMNetworkAdapter').Count | Should Be 0
    }

    It 'refuses when the guardrails changed, and skips that check with -NoGuardCheck' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $global:VmbFake.Nics["$($t.VM.Id)"][0].DhcpGuard = 'Off'
        $r = Get-VmbRefusal { Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy) }
        $r.exit | Should Be 1
        $r.error | Should BeExactly 'guardrails'
        $r.hint | Should Match 'DHCP guard is off'
        $vm = Get-VmbVM (Get-VmbRecord $t.Id) (Get-VmbPolicy) -NoGuardCheck
        "$($vm.Id)" | Should Be "$($t.VM.Id)"
    }
}

Describe 'A consumer acts only on the VMs its records name it the owner of' {
    It 'refuses <Verb> on a VM of another consumer (exit 2), before any Hyper-V call' -TestCases @(
        @{ Verb = 'status'; Call = { Get-VmbStatus $A } }
        @{ Verb = 'run'; Call = { Invoke-VmbRun $A } }
        @{ Verb = 'start'; Call = { Start-VmbVM $A } }
        @{ Verb = 'stop'; Call = { Request-VmbStop $A } }
        @{ Verb = 'snapshot'; Call = { Request-VmbSnapshot $A } }
        @{ Verb = 'restore'; Call = { Request-VmbRestore $A } }
        @{ Verb = 'snapshot-rm'; Call = { Remove-VmbCheckpoint $A } }
        @{ Verb = 'snapshots'; Call = { Get-VmbSnapshotList $A } }
        @{ Verb = 'console'; Call = { Get-VmbConsole $A } }
        @{ Verb = 'copy-from'; Call = { Copy-VmbFromGuest $A } }
        @{ Verb = 'director'; Call = { Invoke-VmbDirector $A } }
    ) {
        param($Verb, $Call)
        $null = New-VmbTestRoot
        $null = New-VmbTestVM -Owner 'cs101-walkthroughs'
        $global:VmbCalls.Clear()
        $A = ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = 'other-project'; command = 'hostname'; label = 'ch1'; guest = 'C:\x.txt'
                                  steps = @(@{ action = 'health'; body = '{}'; timeout_s = 10 }) }
        $r = Get-VmbRefusal $Call
        $r.exit | Should Be 2
        $r.error | Should BeExactly 'not-yours'
        (Get-VmbCalls 'Get-VM').Count | Should Be 0
        (Get-VmbCalls 'Invoke-Command').Count | Should Be 0
        (Get-VmbCalls 'Register-ScheduledTask').Count | Should Be 0
    }

    It 'lets *admin* look at any VM' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM -Owner 'cs101-walkthroughs'
        $s = Get-VmbStatus (ConvertTo-VmbArgs @{ name = 'lab-p1'; consumer = '*admin*' })
        $s.ok | Should Be $true
        $s.state | Should BeExactly 'Running'
        $s.vmid | Should BeExactly "$($t.VM.Id)"
        ($s.addresses -join ',') | Should BeExactly '192.168.10.50'
        @($s.guardrails).Count | Should Be 0
        $s.console | Should BeExactly "vmconnect.exe $($env:COMPUTERNAME.ToLower()) -G $($t.VM.Id)"
    }

    It 'lists only the consumer''s own VMs, never a destroyed one; *admin* sees them all' {
        $null = New-VmbTestRoot
        $null = New-VmbTestVM -Name 'lab-p1' -Owner 'cs101-walkthroughs'
        $null = New-VmbTestVM -Name 'web-1' -Owner 'other-project'
        $null = New-VmbTestVM -Name 'old-1' -Owner 'cs101-walkthroughs' -RecordState 'destroyed'
        $mine = @((Get-VmbList (ConvertTo-VmbArgs @{ consumer = 'cs101-walkthroughs' })).vms | ForEach-Object { $_.vm })
        ($mine -join ',') | Should BeExactly 'lab-p1'
        $all = @((Get-VmbList (ConvertTo-VmbArgs @{ consumer = '*admin*' })).vms | ForEach-Object { $_.vm } | Sort-Object)
        ($all -join ',') | Should BeExactly 'lab-p1,web-1'
    }
}

Describe 'Test-VmbGuards: guards, CPU limit, I/O cap and memory priority' {
    It 'reports nothing for a VM set up as the design says' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        @(Test-VmbGuards $t.VM (Get-VmbPolicy)).Count | Should Be 0
    }

    It 'reports <Case>' -TestCases @(
        @{ Case = 'DHCP guard off'; Table = 'Nics'; Field = 'DhcpGuard'; Value = 'Off'; Want = "DHCP guard is off on 'Network Adapter'" }
        @{ Case = 'router guard off'; Table = 'Nics'; Field = 'RouterGuard'; Value = 'Off'; Want = "router guard is off on 'Network Adapter'" }
        @{ Case = 'MAC spoofing on'; Table = 'Nics'; Field = 'MacAddressSpoofing'; Value = 'On'; Want = "MAC spoofing is on on 'Network Adapter'" }
        @{ Case = 'a NIC on WAN'; Table = 'Nics'; Field = 'SwitchName'; Value = 'WAN'; Want = "a NIC is on switch 'WAN'" }
        @{ Case = 'a NIC on CARP-Sync'; Table = 'Nics'; Field = 'SwitchName'; Value = 'CARP-Sync'; Want = "a NIC is on switch 'CARP-Sync'" }
        @{ Case = 'a NIC on LabLAN'; Table = 'Nics'; Field = 'SwitchName'; Value = 'LabLAN'; Want = "a NIC is on switch 'LabLAN'" }
        @{ Case = 'the default CPU weight'; Table = 'Cpu'; Field = 'RelativeWeight'; Value = 100; Want = 'CPU weight is 100' }
        @{ Case = 'no CPU limit'; Table = 'Cpu'; Field = 'Maximum'; Value = 100; Want = 'CPU limit is 100' }
        @{ Case = 'no IOPS cap'; Table = 'Disks'; Field = 'MaximumIOPS'; Value = 0; Want = 'disk IOPS cap is 0' }
        @{ Case = 'a looser IOPS cap'; Table = 'Disks'; Field = 'MaximumIOPS'; Value = 5000; Want = 'disk IOPS cap is 5000' }
        @{ Case = 'the default memory priority'; Table = 'Mem'; Field = 'Priority'; Value = 50; Want = 'memory priority is 50' }
    ) {
        param($Case, $Table, $Field, $Value, $Want)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        @($global:VmbFake[$Table]["$($t.VM.Id)"])[0].$Field = $Value
        $bad = @(Test-VmbGuards $t.VM (Get-VmbPolicy))
        $bad.Count | Should Be 1
        $bad[0] | Should BeExactly $Want
    }

    It 'reports a second NIC on WAN next to a good one on LAN2' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $k = "$($t.VM.Id)"
        $global:VmbFake.Nics[$k] = @($global:VmbFake.Nics[$k]) + [pscustomobject]@{ Name = 'wan'; SwitchName = 'WAN'; DhcpGuard = 'On'; RouterGuard = 'On'; MacAddressSpoofing = 'Off'; IPAddresses = @(); MacAddress = '' }
        $bad = @(Test-VmbGuards $t.VM (Get-VmbPolicy))
        ($bad -join ' | ') | Should BeExactly "a NIC is on switch 'WAN'"
    }

    It 'checks every disk' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $k = "$($t.VM.Id)"
        $global:VmbFake.Disks[$k] = @($global:VmbFake.Disks[$k]) + [pscustomobject]@{ Path = (Join-Path $t.Dir 'data.vhdx'); MaximumIOPS = [uint64]0 }
        $bad = @(Test-VmbGuards $t.VM (Get-VmbPolicy))
        ($bad -join ' | ') | Should BeExactly 'disk IOPS cap is 0'
    }

    It 'accepts a guarded NIC on a Private vmb-net-* switch, or not connected (every NIC keeps its guards)' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $k = "$($t.VM.Id)"
        $global:VmbFake.Nics[$k] = @(
            [pscustomobject]@{ Name = 'lab'; SwitchName = 'vmb-net-lab1'; DhcpGuard = 'On'; RouterGuard = 'On'; MacAddressSpoofing = 'Off'; IPAddresses = @(); MacAddress = '' }
            [pscustomobject]@{ Name = 'spare'; SwitchName = $null; DhcpGuard = 'On'; RouterGuard = 'On'; MacAddressSpoofing = 'Off'; IPAddresses = @(); MacAddress = '' }
        )
        @(Test-VmbGuards $t.VM (Get-VmbPolicy)).Count | Should Be 0
    }

    It 'reports every defect at once' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $k = "$($t.VM.Id)"
        $global:VmbFake.Nics[$k][0].RouterGuard = 'Off'
        $global:VmbFake.Cpu[$k].Maximum = 100
        $global:VmbFake.Mem[$k].Priority = 50
        @(Test-VmbGuards $t.VM (Get-VmbPolicy)).Count | Should Be 3
    }
}

Describe 'Test-VmbPaths: every file of the VM inside vms\<id>\' {
    It 'reports nothing when every file is inside the folder' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        @(Test-VmbPaths $t.VM (Get-VmbRecord $t.Id)).Count | Should Be 0
    }

    It 'reports a <Case>' -TestCases @(
        @{ Case = 'disk on another drive'; Path = 'D:\elsewhere\x.vhdx' }
        @{ Case = 'disk in a sibling folder with the same prefix'; Path = '<dir>-old\x.vhdx' }
        @{ Case = 'disk reached through ..'; Path = '<dir>\..\0123456789abcdef0123456789abcdef\x.vhdx' }
        @{ Case = 'disk in the image folder'; Path = '<root>\images\win2025\base.vhdx' }
    ) {
        param($Case, $Path)
        $root = New-VmbTestRoot
        $t = New-VmbTestVM
        $p = $Path.Replace('<dir>', $t.Dir).Replace('<root>', $root)
        $global:VmbFake.Disks["$($t.VM.Id)"] = @([pscustomobject]@{ Path = $p; MaximumIOPS = [uint64]800 })
        $bad = @(Test-VmbPaths $t.VM (Get-VmbRecord $t.Id))
        ($bad -join ' | ') | Should BeExactly "outside its folder: $p"
    }

    It 'reports a checkpoint disk outside the folder' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $snap = [pscustomobject]@{ Id = [guid]::NewGuid(); Name = 'ch1'; CreationTime = Get-Date; SnapshotType = 'Standard'; ParentSnapshotName = '' }
        $global:VmbFake.Snapshots["$($t.VM.Id)"] = @($snap)
        $global:VmbFake.SnapDisks["$($snap.Id)"] = @([pscustomobject]@{ Path = 'D:\elsewhere\ch1.avhdx' })
        $bad = @(Test-VmbPaths $t.VM (Get-VmbRecord $t.Id))
        ($bad -join ' | ') | Should BeExactly 'outside its folder: D:\elsewhere\ch1.avhdx'
    }

    It 'reports the <Field> outside the folder' -TestCases @(@{ Field = 'Path' }, @{ Field = 'ConfigurationLocation' }, @{ Field = 'SnapshotFileLocation' }, @{ Field = 'SmartPagingFilePath' }) {
        param($Field)
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $t.VM.$Field = 'C:\ProgramData\Microsoft\Windows\Hyper-V'
        $bad = @(Test-VmbPaths $t.VM (Get-VmbRecord $t.Id))
        ($bad -join ' | ') | Should BeExactly 'outside its folder: C:\ProgramData\Microsoft\Windows\Hyper-V'
    }

    It 'accepts the folder in another letter case' {
        $null = New-VmbTestRoot
        $t = New-VmbTestVM
        $global:VmbFake.Disks["$($t.VM.Id)"] = @([pscustomobject]@{ Path = (Join-Path $t.Dir.ToUpper() 'X.VHDX'); MaximumIOPS = [uint64]800 })
        @(Test-VmbPaths $t.VM (Get-VmbRecord $t.Id)).Count | Should Be 0
    }
}
} finally { Remove-VmbTestRoots }
