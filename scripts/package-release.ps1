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
$release = '2.7.0_pre5.18'
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
    foreach ($name in @('HomeLibRu.exe', 'HomeLibRuUpdater.exe', 'MHLMcpServer.exe', 'sqlite3.dll', 'libzstd.dll', 'LICENSE', 'NOTICE')) {
        Copy-Item -LiteralPath (Join-Path $runtimeDirectory $name) -Destination $payloadDirectory
    }
    foreach ($genre in Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'Installer\GenreLists') -Filter '*.glst' -File) {
        Copy-Item -LiteralPath $genre.FullName -Destination $payloadDirectory
    }
    $history = @(Get-ChildItem -LiteralPath $repositoryRoot -Filter 'RELEASE_NOTES_2.7.0_pre5.*.md' -File |
        Sort-Object { [int]($_.BaseName.Split('.')[-1]) } -Descending |
        Select-Object -First 8 | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 })
    [IO.File]::WriteAllText((Join-Path $payloadDirectory 'CHANGES.txt'),
        ($history -join "`r`n`r`n"), [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'Installer\Components.json') -Destination (Join-Path $payloadDirectory 'COMPONENTS.json')
    foreach ($directory in @('Help', 'Icons')) {
        Copy-Item -LiteralPath (Join-Path $runtimeDirectory $directory) -Destination $payloadDirectory -Recurse
    }
    $toolsDestination = Join-Path $payloadDirectory 'tools'
    [IO.Directory]::CreateDirectory($toolsDestination) | Out-Null
    foreach ($directory in Get-ChildItem -LiteralPath (Join-Path $runtimeDirectory 'tools') -Directory) {
        if ($directory.Name -notin @('fonts', 'bookconvert')) { Copy-Item -LiteralPath $directory.FullName -Destination $toolsDestination -Recurse }
    }
    $bookConverterDestination = Join-Path $toolsDestination 'bookconvert'
    [IO.Directory]::CreateDirectory($bookConverterDestination) | Out-Null
    foreach ($name in @('convert_book.py', 'LICENSE.txt', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $runtimeDirectory "tools\bookconvert\$name") -Destination $bookConverterDestination
    }
    $fontSource = Join-Path $runtimeDirectory 'tools\fonts'
    $fontDestination = Join-Path $toolsDestination 'fonts'
    $fontManifest = Get-Content -LiteralPath (Join-Path $fontSource 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($font in $fontManifest.files) {
        if ($font.path -match '^(ptserif|ptsans)/' -or
            $font.path -match '^noto/(NotoSerif|NotoSans)-(Regular|Bold|Italic|BoldItalic)\.ttf$' -or
            $font.path -match '(OFL|LICENSE).*\.(txt|md)$') {
            $target = Join-Path $fontDestination $font.path
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            Copy-Item -LiteralPath (Join-Path $fontSource $font.path) -Destination $target
        }
    }
    Copy-Item -LiteralPath (Join-Path $fontSource 'manifest.json') -Destination $fontDestination
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

    $manifestFiles = @(Get-ChildItem -LiteralPath $payloadDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($payloadDirectory.Length + 1).Replace('\', '/')
            size = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $manifest = [ordered]@{ format = 1; release = $release; platform = $Platform; files = $manifestFiles }
    [IO.File]::WriteAllText((Join-Path $payloadDirectory 'HomeLibRu.update.json'),
        ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

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
