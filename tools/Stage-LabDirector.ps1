<#
.SYNOPSIS
    Stages the vm-broker director for a lab VM: Python embeddable, the vm_director package, ffmpeg.exe, a manifest.

.DESCRIPTION
    Builds this layout under -Out (it is copied to C:\ProgramData\LabDirector\ in the guest):

        bin\python\           the Python embeddable distribution; its python3NN._pth lists the stdlib zip, "."
                              and "..\app", with "import site" left commented
        bin\app\vm_director\  the package from src\vm_director (*.py only, no __pycache__)
        bin\ffmpeg.exe        only that one file from the ffmpeg zip (<top folder>\bin\ffmpeg.exe)
        manifest.json         relative path, size and SHA-256 of every file, and the two source zips

    The scheduled task in the guest runs: bin\python\pythonw.exe -I -m vm_director

    Refuses an -Out under any OneDrive folder, and an -Out that exists and is not empty (nothing is ever deleted).
    -WhatIf runs every check and reads the zips' directories, and writes nothing.
    Windows PowerShell 5.1 compatible. Never downloads anything: the zips are given.

.PARAMETER PythonZip
    The Python embeddable zip, for example python-3.14.7-embed-amd64.zip (python.org).

.PARAMETER FfmpegZip
    The ffmpeg build zip, for example ffmpeg-9.0.2-essentials_build.zip.

.PARAMETER Out
    The staging folder; new or empty, outside OneDrive (for example C:\work\stage\LabDirector).

.PARAMETER Source
    The vm_director package folder. Default: ..\src\vm_director next to this script.

.EXAMPLE
    .\tools\Stage-LabDirector.ps1 -PythonZip C:\work\dl\python-3.14.7-embed-amd64.zip `
        -FfmpegZip C:\work\dl\ffmpeg-9.0.2-essentials_build.zip -Out C:\work\stage\LabDirector
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$PythonZip,
    [Parameter(Mandatory = $true)][string]$FfmpegZip,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Source
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-FullPath([string]$Path) {
    # Relative to the current location, also for a path that does not exist yet.
    $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    return [System.IO.Path]::GetFullPath($p).TrimEnd('\')
}

function Test-UnderOneDrive([string]$FullPath) {
    $withSlash = $FullPath.TrimEnd('\') + '\'
    foreach ($root in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
        if (-not $root) { continue }
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        if ($withSlash.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($segment in $FullPath.Split('\')) {
        if ($segment -like '*OneDrive*') { return $true }
    }
    return $false
}

function Get-ZipEntryNames([string]$Zip) {
    $z = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try { return @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# --- checks (all of them run under -WhatIf too) -------------------------------------------------------------
$pythonZipFull = Get-FullPath $PythonZip
$ffmpegZipFull = Get-FullPath $FfmpegZip
$outFull = Get-FullPath $Out
if (-not $Source) { $Source = Join-Path $PSScriptRoot '..\src\vm_director' }
$sourceFull = Get-FullPath $Source

if (Test-UnderOneDrive $outFull) {
    throw "Refusing -Out '$outFull': it is under a OneDrive folder. Stage outside OneDrive (for example C:\work\stage)."
}
foreach ($zip in @($pythonZipFull, $ffmpegZipFull)) {
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "Zip not found: $zip" }
}
if (Test-Path -LiteralPath $outFull -PathType Leaf) { throw "-Out '$outFull' is a file." }
if (Test-Path -LiteralPath $outFull -PathType Container) {
    if (@(Get-ChildItem -LiteralPath $outFull -Force).Count -gt 0) {
        throw "-Out '$outFull' is not empty. Give a new or empty folder (this script never deletes anything)."
    }
}

foreach ($name in @('__init__.py', '__main__.py', 'server.py', 'win32.py')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceFull $name) -PathType Leaf)) {
        throw "Source '$sourceFull' does not look like the vm_director package ($name is missing)."
    }
}
$packageFiles = @(Get-ChildItem -LiteralPath $sourceFull -Filter '*.py' -File | Sort-Object Name)
$initText = [System.IO.File]::ReadAllText((Join-Path $sourceFull '__init__.py'))
$m = [regex]::Match($initText, '(?m)^VERSION\s*=\s*"([^"]+)"')
if (-not $m.Success) { throw "No VERSION = ""..."" line in $sourceFull\__init__.py" }
$version = $m.Groups[1].Value

$pyEntries = Get-ZipEntryNames $pythonZipFull
$pthNames = @($pyEntries | Where-Object { $_ -match '^python3\d+\._pth$' })
$stdlibNames = @($pyEntries | Where-Object { $_ -match '^python3\d+\.zip$' })
foreach ($need in @('python.exe', 'pythonw.exe')) {
    if ($pyEntries -notcontains $need) { throw "$pythonZipFull is not a Python embeddable zip ($need is missing)." }
}
if ($pthNames.Count -ne 1) { throw "$pythonZipFull holds $($pthNames.Count) python3NN._pth files; expected 1." }
if ($stdlibNames.Count -ne 1) { throw "$pythonZipFull holds $($stdlibNames.Count) python3NN.zip files; expected 1." }
$pthName = $pthNames[0]
$stdlibName = $stdlibNames[0]
if ([System.IO.Path]::GetFileNameWithoutExtension($pthName) -ne [System.IO.Path]::GetFileNameWithoutExtension($stdlibName)) {
    throw "$pthName and $stdlibName do not belong together."
}

$ffEntries = @(Get-ZipEntryNames $ffmpegZipFull | Where-Object { $_ -match '^[^/\\]+[/\\]bin[/\\]ffmpeg\.exe$' })
if ($ffEntries.Count -ne 1) {
    throw "$ffmpegZipFull holds $($ffEntries.Count) <top>\bin\ffmpeg.exe entries; expected exactly 1."
}
$ffEntryName = $ffEntries[0]

$bin = Join-Path $outFull 'bin'
$pyDir = Join-Path $bin 'python'
$appDir = Join-Path $bin 'app\vm_director'
$ffDest = Join-Path $bin 'ffmpeg.exe'
$manifestPath = Join-Path $outFull 'manifest.json'
$pthPath = Join-Path $pyDir $pthName

Write-Verbose "Python zip: $pythonZipFull ($pthName, $stdlibName)"
Write-Verbose "ffmpeg zip: $ffmpegZipFull ($ffEntryName)"
Write-Verbose "Package:    $sourceFull ($($packageFiles.Count) files, version $version)"
Write-Verbose "Out:        $outFull"

# --- staging --------------------------------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($pyDir, "Expand $([System.IO.Path]::GetFileName($pythonZipFull))")) {
    New-Item -ItemType Directory -Path $pyDir -Force -WhatIf:$false | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($pythonZipFull, $pyDir)
}

$pthLines = @($stdlibName, '.', '..\app', '', '# Uncomment to run site.main() automatically', '#import site')
if ($PSCmdlet.ShouldProcess($pthPath, 'Write the ._pth file (stdlib zip, ".", "..\app"; import site commented)')) {
    # ASCII, no BOM: a BOM would become part of the first path and Python would lose its standard library.
    [System.IO.File]::WriteAllText($pthPath, (($pthLines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
}

if ($PSCmdlet.ShouldProcess($appDir, "Copy $($packageFiles.Count) vm_director *.py files")) {
    New-Item -ItemType Directory -Path $appDir -Force -WhatIf:$false | Out-Null
    foreach ($f in $packageFiles) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $appDir $f.Name) -WhatIf:$false
    }
}

if ($PSCmdlet.ShouldProcess($ffDest, "Extract $ffEntryName")) {
    New-Item -ItemType Directory -Path $bin -Force -WhatIf:$false | Out-Null
    $z = [System.IO.Compression.ZipFile]::OpenRead($ffmpegZipFull)
    try {
        $entry = $z.Entries | Where-Object { $_.FullName -eq $ffEntryName } | Select-Object -First 1
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $ffDest, $false)
    } finally {
        $z.Dispose()
    }
}

if ($PSCmdlet.ShouldProcess($manifestPath, 'Write manifest.json (path, size and SHA-256 of every file)')) {
    $prefixLength = $outFull.Length + 1
    $files = @(Get-ChildItem -LiteralPath $outFull -Recurse -File -Force |
        Where-Object { $_.FullName -ne $manifestPath } |
        Sort-Object { $_.FullName.Substring($prefixLength) })
    $items = @(foreach ($f in $files) {
        [ordered]@{ path = $f.FullName.Substring($prefixLength); size = $f.Length; sha256 = (Get-Sha256 $f.FullName) }
    })
    $manifest = [ordered]@{
        name        = 'LabDirector'
        version     = $version
        created_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        start       = 'bin\python\pythonw.exe -I -m vm_director'
        python_zip  = [ordered]@{ name = [System.IO.Path]::GetFileName($pythonZipFull); size = (Get-Item -LiteralPath $pythonZipFull).Length; sha256 = (Get-Sha256 $pythonZipFull) }
        ffmpeg_zip  = [ordered]@{ name = [System.IO.Path]::GetFileName($ffmpegZipFull); size = (Get-Item -LiteralPath $ffmpegZipFull).Length; sha256 = (Get-Sha256 $ffmpegZipFull); entry = $ffEntryName }
        files       = $items
    }
    $json = ConvertTo-Json -InputObject $manifest -Depth 6
    [System.IO.File]::WriteAllText($manifestPath, $json + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    $total = 0
    foreach ($i in $items) { $total += $i.size }
    [pscustomobject]@{ Out = $outFull; Version = $version; Files = $items.Count; Bytes = $total; Manifest = $manifestPath }
}
