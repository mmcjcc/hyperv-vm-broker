<#
.SYNOPSIS
Presses one key on a broker VM's virtual keyboard (Msvm_Keyboard), by VMId, for the build session: wakes a sleeping
display or answers a setup page. Refuses any VM whose name does not start with vmb-. Adapted from netadmin's
Send-VMKeys.ps1. Keys are virtual-key codes (0x10 Shift, 0x0D Enter, 0x09 Tab, 0x20 Space).
#>
param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][guid]$VMId,
    [ValidateSet(0x10, 0x0D, 0x09, 0x20, 0x1B)][int]$Key = 0x10
)
$ErrorActionPreference = 'Stop'
$loader = 'C:\src\netadmin\tools\Get-HomelabCredential.ps1'
$cred = & $loader -ConfigPath (Join-Path $env:TEMP ('vmb-no-config-' + [guid]::NewGuid().ToString('N') + '\config.txt'))
Invoke-Command -ComputerName $HostName -Credential $cred -Authentication Kerberos -ArgumentList $VMId.ToString(), $Key -ScriptBlock {
    param($Id, $K)
    $vm = Get-VM -Id $Id
    if (-not $vm.Name.StartsWith('vmb-')) { throw 'not a broker VM' }
    $cs = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "Name='$Id'"
    $kbd = Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_Keyboard
    $r = Invoke-CimMethod -InputObject $kbd -MethodName TypeKey -Arguments @{ keyCode = [uint32]$K }
    "key 0x{0:X2} sent to {1} (return {2})" -f $K, $vm.Name, $r.ReturnValue
}
