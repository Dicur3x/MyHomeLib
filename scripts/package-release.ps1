[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,

    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$release = '2.7.0_pre5.04'
$outputSubdirectory = if ($Platform -eq 'Win32') { 'Program\Out\Bin' } else { 'Program\Out\Bin64' }
$runtimeDirectory = Join-Path $repositoryRoot $outputSubdirectory
$archiveName = if ($Platform -eq 'Win32') { 'HomeLibRu.zip' } else { 'HomeLibRu_x64.zip' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot "Installer\Out\$release"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$archivePath = Join-Path $OutputDirectory $archiveName
if (Test-Path -LiteralPath $archivePath) {
    throw "Archive already exists; choose a new output directory: $archivePath"
}

# Preparation is explicit: this verifies the runtime without changing it.
& (Join-Path $PSScriptRoot 'prepare-runtime.ps1') -Platform $Platform | Out-Host

$temporaryDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$stagingRoot = Join-Path $temporaryDirectory ('homelibru-package-' + [guid]::NewGuid().ToString('N'))
$payloadDirectory = Join-Path $stagingRoot 'payload'
[System.IO.Directory]::CreateDirectory($payloadDirectory) | Out-Null
try {
    foreach ($name in @('HomeLibRu.exe', 'MHLMcpServer.exe', 'sqlite3.dll', 'libzstd.dll', 'LICENSE', 'NOTICE')) {
        Copy-Item -LiteralPath (Join-Path $runtimeDirectory $name) -Destination $payloadDirectory
    }
    foreach ($genre in Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'Installer\GenreLists') -Filter '*.glst' -File) {
        Copy-Item -LiteralPath $genre.FullName -Destination $payloadDirectory
    }
    foreach ($directory in @('Help', 'Icons', 'tools')) {
        Copy-Item -LiteralPath (Join-Path $runtimeDirectory $directory) -Destination $payloadDirectory -Recurse
    }
    # Readers can save reading history alongside their executables. Ship only
    # their distribution files, never a recursively copied working profile.
    $readerFiles = @{
        AlReader = @('$savevtut.ini', 'AlDictionary.aldict', 'AlReader2.exe',
            'book_new0.m2.bmp', 'book_new1.m2.bmp', 'book_white.m2.bmp',
            'DefaultTexture.BMP', 'DefaultTextureBlack.BMP',
            'English_US_hyphen_(Alan).pdb', 'fon_white.m1.bmp', 'readme.txt',
            'Russian_1251_hyphen_(Alan).pdb', 'Russian_EnUS_hyphen_(Alan).pdb',
            'Russian_hyphen_(Alan).pdb', 'UNRAR.DLL')
        SumatraPDF = @('SumatraPDF.exe', 'AUTHORS.txt', 'COPYING.BSD.txt', 'COPYING.txt')
    }
    foreach ($reader in $readerFiles.Keys) {
        $destination = Join-Path $payloadDirectory "Readers\$reader"
        [System.IO.Directory]::CreateDirectory($destination) | Out-Null
        foreach ($name in $readerFiles[$reader]) {
            Copy-Item -LiteralPath (Join-Path $runtimeDirectory "Readers\$reader\$name") -Destination $destination
        }
    }
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'Installer\HomeLibRu.url') -Destination $payloadDirectory
    $converter = Join-Path $runtimeDirectory 'converters\fb2lrf'
    if (Test-Path -LiteralPath $converter -PathType Container) {
        $converterDestination = Join-Path $payloadDirectory 'converters'
        [System.IO.Directory]::CreateDirectory($converterDestination) | Out-Null
        Copy-Item -LiteralPath $converter -Destination $converterDestination -Recurse
    }

    # No whole-runtime copy: Data, Presets, INI files, logs, old EXEs and test
    # fixtures in the output directory do not belong in a release archive.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryArchive = Join-Path $stagingRoot $archiveName
    [System.IO.Compression.ZipFile]::CreateFromDirectory($payloadDirectory, $temporaryArchive,
        [System.IO.Compression.CompressionLevel]::Optimal, $false)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($temporaryArchive)
    try {
        foreach ($name in @('HomeLibRu.exe', 'LICENSE', 'NOTICE')) {
            if ($null -eq $archive.GetEntry($name)) {
                throw "Release archive is missing $name"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    Move-Item -LiteralPath $temporaryArchive -Destination $archivePath
    [pscustomobject]@{
        Release = $release
        Platform = $Platform
        Archive = $archivePath
        SHA256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    }
}
finally {
    $resolvedStagingRoot = [System.IO.Path]::GetFullPath($stagingRoot)
    $temporaryPrefix = $temporaryDirectory.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStagingRoot.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove staging outside the temporary directory: $resolvedStagingRoot"
    }
    Remove-Item -LiteralPath $resolvedStagingRoot -Recurse -Force
}
