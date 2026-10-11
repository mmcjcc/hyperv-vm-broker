<#
.SYNOPSIS
A PNG of a broker VM's console (Hyper-V's thumbnail API, read-only), saved on this laptop. For the build session:
it shows Windows setup and OOBE pages before PowerShell Direct answers. Adapted from netadmin's
Get-VMScreenshot.ps1, but addressed by VMId and writing nothing on the host.
.EXAMPLE
powershell -File tools\Get-VmbConsoleShot.ps1 -HostName serverd.corp.example -VMId 00000000-0000-0000-0000-000000000001
#>
param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][guid]$VMId,
    [string]$OutDir = 'C:\work\vm-broker-data\console',
    [int]$Width = 1280,
    [int]$Height = 720
)
$ErrorActionPreference = 'Stop'
$loader = 'C:\src\netadmin\tools\Get-HomelabCredential.ps1'
$cred = & $loader -ConfigPath (Join-Path $env:TEMP ('vmb-no-config-' + [guid]::NewGuid().ToString('N') + '\config.txt'))
$raw = Invoke-Command -ComputerName $HostName -Credential $cred -Authentication Kerberos -ArgumentList $VMId.ToString(), $Width, $Height -ScriptBlock {
    param($Id, $W, $H)
    $vm = Get-VM -Id $Id
    if (-not $vm.Name.StartsWith('vmb-')) { throw 'not a broker VM' }
    $ns = 'root\virtualization\v2'
    $svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
    $sd = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemSettingData -Filter "ConfigurationID='$Id' AND VirtualSystemType='Microsoft:Hyper-V:System:Realized'"
    if (-not $sd) { throw 'VM not running' }
    $r = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{ TargetSystem = $sd; WidthPixels = [uint16]$W; HeightPixels = [uint16]$H }
    if (-not $r.ImageData) { throw "no thumbnail (ReturnValue $($r.ReturnValue))" }
    , [byte[]]$r.ImageData
}
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$data = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $Width, $Height), [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
[System.Runtime.InteropServices.Marshal]::Copy([byte[]]$raw, 0, $data.Scan0, [math]::Min($raw.Length, $data.Stride * $Height))
$bmp.UnlockBits($data)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = Join-Path $OutDir ('console-{0}.png' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
$out
