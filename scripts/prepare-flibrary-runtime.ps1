[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sevenZipVersion = '26.02'
$sevenZipBootstrapUrl = 'https://github.com/ip7z/7zip/releases/download/26.02/7zr.exe'
$sevenZipBootstrapSha256 = '56B8CC9F4971CEF253644FAFE54063ED7FDCA551D4DEE0F8C6BAA81B855ACD72'
$sevenZipExtraUrl = 'https://github.com/ip7z/7zip/releases/download/26.02/7z2602-extra.7z'
$sevenZipExtraSha256 = '081DF9E9311DFD9C9E0E98C1C80180B99BB51E4CB24156B5F3057FE3C259D70A'

$jpegXlVersion = '0.12.0'
$jpegXlRuntime = if ($Platform -eq 'Win32') {
    @{
        Url = 'https://github.com/libjxl/libjxl/releases/download/v0.12.0/jxl-x86-windows-static.7z'
        Sha256 = 'C6F419659910A68782810A400AADAF5C1BFCBC67EA324223AF09D7A7477C16CC'
        Root = 'x86-windows-static'
    }
}
else {
    @{
        Url = 'https://github.com/libjxl/libjxl/releases/download/v0.12.0/jxl-x64-windows-static.7z'
        Sha256 = 'FF147DC7AC4CE55392974CCC70F2A8A8EC0EFF3AE28529B072258B66C8F01AB2'
        Root = 'x64-windows-static'
    }
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    Invoke-WebRequest -Uri $Uri -OutFile $Destination
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
    if ($actual -ne $Sha256) {
        throw "Downloaded file checksum mismatch: $Destination"
    }
    Write-Host "[OK] SHA-256 $actual  $Destination"
}

function Copy-RuntimeFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    if (Test-Path -LiteralPath $Destination) {
        $same = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash -eq
            (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
        if ($same) {
            Write-Host "[OK] Already current: $Destination"
            return
        }
        if (-not $Force) {
            throw "Destination differs. Add -Force to replace it: $Destination"
        }
    }
    [System.IO.File]::Copy($Source, $Destination, $true)
    Write-Host "[COPIED] $Destination"
}

if (($Platform -eq 'Win64') -and (-not [Environment]::Is64BitOperatingSystem)) {
    throw 'A Win64 runtime cannot be prepared on 32-bit Windows.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputSubdirectory = if ($Platform -eq 'Win32') { 'Program\Out\Bin' } else { 'Program\Out\Bin64' }
$outputDirectory = Join-Path $repositoryRoot $outputSubdirectory
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Build MyHomeLib first; output folder not found: '$outputDirectory'."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mhl-runtime-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $bootstrap = Join-Path $tempRoot '7zr.exe'
    $sevenZipExtra = Join-Path $tempRoot '7z-extra.7z'
    $jpegXlArchive = Join-Path $tempRoot 'jpeg-xl.7z'
    $sevenZipExtracted = Join-Path $tempRoot 'sevenzip'
    $jpegXlExtracted = Join-Path $tempRoot 'jpeg-xl'

    Get-VerifiedDownload -Uri $sevenZipBootstrapUrl -Destination $bootstrap -Sha256 $sevenZipBootstrapSha256
    Get-VerifiedDownload -Uri $sevenZipExtraUrl -Destination $sevenZipExtra -Sha256 $sevenZipExtraSha256
    [System.IO.Directory]::CreateDirectory($sevenZipExtracted) | Out-Null
    & $bootstrap x -y "-o$sevenZipExtracted" -- $sevenZipExtra | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Cannot unpack the 7-Zip runtime.'
    }

    $sevenZipExe = if ($Platform -eq 'Win32') {
        Join-Path $sevenZipExtracted '7za.exe'
    }
    else {
        Join-Path $sevenZipExtracted 'x64\7za.exe'
    }
    $sevenZipLicense = Join-Path $sevenZipExtracted 'License.txt'
    Copy-RuntimeFile -Source $sevenZipExe -Destination (Join-Path $outputDirectory 'tools\7zip\7za.exe')
    Copy-RuntimeFile -Source $sevenZipLicense -Destination (Join-Path $outputDirectory 'tools\7zip\License.txt')

    Get-VerifiedDownload -Uri $jpegXlRuntime.Url -Destination $jpegXlArchive -Sha256 $jpegXlRuntime.Sha256
    [System.IO.Directory]::CreateDirectory($jpegXlExtracted) | Out-Null
    & $sevenZipExe x -y "-o$jpegXlExtracted" -- $jpegXlArchive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Cannot unpack the JPEG XL runtime.'
    }

    $jpegXlRoot = Join-Path $jpegXlExtracted $jpegXlRuntime.Root
    Copy-RuntimeFile -Source (Join-Path $jpegXlRoot 'bin\djxl.exe') -Destination (Join-Path $outputDirectory 'tools\jpeg-xl\djxl.exe')
    foreach ($license in Get-ChildItem -LiteralPath (Join-Path $jpegXlRoot 'licenses') -File) {
        Copy-RuntimeFile -Source $license.FullName -Destination (Join-Path $outputDirectory ('tools\jpeg-xl\licenses\' + $license.Name))
    }

    Write-Host ''
    Write-Host "Done: FLibrary compatibility runtime prepared for $Platform."
    Write-Host "7-Zip $sevenZipVersion; JPEG XL $jpegXlVersion"
}
finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemp).StartsWith('mhl-runtime-', [StringComparison]::OrdinalIgnoreCase)) {
        [System.IO.Directory]::Delete($resolvedTemp, $true)
    }
}
