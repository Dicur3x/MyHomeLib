[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,

    [string]$AlReaderDirectory,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sumatraVersion = '3.6.1'
$sumatraNotices = @(
    @{
        Name = 'COPYING.txt'
        Url = 'https://raw.githubusercontent.com/sumatrapdfreader/sumatrapdf/3.6.1rel/COPYING'
        Sha256 = '3972DC9744F6499F0F9B2DBF76696F2AE7AD8AF9B23DDE66D6AF86C9DFB36986'
    },
    @{
        Name = 'COPYING.BSD.txt'
        Url = 'https://raw.githubusercontent.com/sumatrapdfreader/sumatrapdf/3.6.1rel/COPYING.BSD'
        Sha256 = 'FF33648659AA06892ED13A731588A57006FAFEE2F848D35F70BF273A13CF9D27'
    },
    @{
        Name = 'AUTHORS.txt'
        Url = 'https://raw.githubusercontent.com/sumatrapdfreader/sumatrapdf/3.6.1rel/AUTHORS'
        Sha256 = 'E16C411B4A9E65058E198DBB3A5E5941A65D9C44BD1A321B977644EC0B18AA53'
    }
)

$sumatra = if ($Platform -eq 'Win32') {
    @{
        Url = 'https://www.sumatrapdfreader.org/dl/rel/3.6.1/SumatraPDF-3.6.1.zip'
        ZipSha256 = '670E694A5C91633D28AB0DF689B4DBF92021183CFE82270AE552CB617A0A07ED'
        ExeName = 'SumatraPDF-3.6.1-32.exe'
        ExeSha256 = '3793FA285BC890A5E4C263F6F9854CF425BEE63C72E52F5362DBC41D60956BCF'
    }
}
else {
    @{
        Url = 'https://www.sumatrapdfreader.org/dl/rel/3.6.1/SumatraPDF-3.6.1-64.zip'
        ZipSha256 = '98B33A518D42986856D225064B0CD2D3643ECF78CBF84AB873D26CC51877A544'
        ExeName = 'SumatraPDF-3.6.1-64.exe'
        ExeSha256 = '719F689B34F47BE8CA105CE8484948474DAFDE0E106BAB599E4A89326070C3D0'
    }
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
    if ($actual -ne $Sha256) {
        throw "Downloaded file checksum mismatch: $Destination"
    }
    Write-Host "[OK] SHA-256 $actual  $Destination"
}

function Copy-CheckedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
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

function Copy-CheckedTree {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        Copy-CheckedFile -Source $file.FullName -Destination (Join-Path $DestinationDirectory $relative)
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputSubdirectory = if ($Platform -eq 'Win32') { 'Program\Out\Bin' } else { 'Program\Out\Bin64' }
$outputDirectory = Join-Path $repositoryRoot $outputSubdirectory
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Build MyHomeLib first; output folder not found: '$outputDirectory'."
}

$readersDirectory = Join-Path $outputDirectory 'Readers'
$alReaderDestination = Join-Path $readersDirectory 'AlReader'
$sumatraDestination = Join-Path $readersDirectory 'SumatraPDF'

if ([string]::IsNullOrWhiteSpace($AlReaderDirectory)) {
    $legacyAlReader = Join-Path $outputDirectory 'AlReader'
    if (Test-Path -LiteralPath (Join-Path $alReaderDestination 'AlReader2.exe') -PathType Leaf) {
        $AlReaderDirectory = $alReaderDestination
    }
    elseif (Test-Path -LiteralPath (Join-Path $legacyAlReader 'AlReader2.exe') -PathType Leaf) {
        $AlReaderDirectory = $legacyAlReader
    }
    else {
        throw 'AlReader was not found. Pass its portable folder with -AlReaderDirectory.'
    }
}
elseif (-not (Test-Path -LiteralPath (Join-Path $AlReaderDirectory 'AlReader2.exe') -PathType Leaf)) {
    throw "AlReader2.exe was not found in '$AlReaderDirectory'."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mhl-readers-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $sumatraArchive = Join-Path $tempRoot 'sumatra.zip'
    $sumatraExtracted = Join-Path $tempRoot 'sumatra'

    Get-VerifiedDownload -Uri $sumatra.Url -Destination $sumatraArchive -Sha256 $sumatra.ZipSha256
    Expand-Archive -LiteralPath $sumatraArchive -DestinationPath $sumatraExtracted
    $sumatraExe = Join-Path $sumatraExtracted $sumatra.ExeName
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $sumatraExe).Hash -ne $sumatra.ExeSha256) {
        throw 'The extracted SumatraPDF executable checksum does not match.'
    }

    Copy-CheckedTree -SourceDirectory $AlReaderDirectory -DestinationDirectory $alReaderDestination
    Copy-CheckedFile -Source $sumatraExe -Destination (Join-Path $sumatraDestination 'SumatraPDF.exe')
    foreach ($notice in $sumatraNotices) {
        $noticeSource = Join-Path $tempRoot $notice.Name
        Get-VerifiedDownload -Uri $notice.Url -Destination $noticeSource -Sha256 $notice.Sha256
        Copy-CheckedFile -Source $noticeSource -Destination (Join-Path $sumatraDestination $notice.Name)
    }

    Write-Host ''
    Write-Host "Done: bundled readers prepared for $Platform."
    Write-Host "AlReader 2; SumatraPDF $sumatraVersion"
}
finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemp).StartsWith('mhl-readers-', [StringComparison]::OrdinalIgnoreCase)) {
        [System.IO.Directory]::Delete($resolvedTemp, $true)
    }
}
