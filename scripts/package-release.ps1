[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,

    [string]$OutputDirectory,
    [switch]$Full,
    [switch]$DocSharpBridge,
    [string]$OfflineComponents,
    [string]$OfflineVerifier,
    [string]$OfflinePrerequisiteInputs,
    [string]$WorkingDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (($Full -or $DocSharpBridge) -and [string]::IsNullOrWhiteSpace($OfflineComponents)) {
    throw 'Сборка с компонентами требует -OfflineComponents: проверенный список архивов с SHA-256.'
}
if ($DocSharpBridge -and ($Full -or $OfflinePrerequisiteInputs)) {
    throw '-DocSharpBridge предназначен для компактного архива.'
}
if ($Full -and [string]::IsNullOrWhiteSpace($OfflinePrerequisiteInputs)) {
    throw 'Полная сборка требует -OfflinePrerequisiteInputs: папку с закреплёнными полными установщиками Microsoft.'
}
if (-not ($Full -or $DocSharpBridge) -and ($OfflineComponents -or $OfflineVerifier -or $OfflinePrerequisiteInputs)) {
    throw 'Параметры компонентов разрешены с -Full или -DocSharpBridge.'
}
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$releaseIdentity = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Installer\Release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$release = $releaseIdentity.release
$outputSubdirectory = if ($Platform -eq 'Win32') { 'Program\Out\Bin' } else { 'Program\Out\Bin64' }
$runtimeDirectory = Join-Path $repositoryRoot $outputSubdirectory
# Beta 2 is the bridge for clients which only recognise HomeLibRu*.zip.
# Its updated parser accepts HomeLibre*.zip, used from beta 3 onwards.
$archiveBrand = if ([version]$releaseIdentity.version -lt [version]'3.0.0.3') { 'HomeLibRu' } else { 'HomeLibre' }
$baseArchiveName = if ($Platform -eq 'Win32') { "$archiveBrand.zip" } else { "${archiveBrand}_x64.zip" }
$archiveSuffix = if ($Full) { '_full.zip' }
    elseif ([version]$releaseIdentity.version -ge [version]'3.0.0.16') { '_compact.zip' }
    else { '_portable.zip' }
$archiveName = $baseArchiveName.Replace('.zip', $archiveSuffix)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot "Installer\Out\$release"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$archivePath = Join-Path $OutputDirectory $archiveName
# Beta 14 already accepts the regular portable archive. Keep historical
# packaging reproducible and use beta 14 as the bridge from beta 13.
$compatibilityArchivePath = if (-not $Full -and [version]$releaseIdentity.version -lt [version]'3.0.0.15') {
    Join-Path $OutputDirectory $baseArchiveName
} else { $null }
if (Test-Path -LiteralPath $archivePath) {
    throw "Archive already exists; choose a new output directory: $archivePath"
}
if ($compatibilityArchivePath -and (Test-Path -LiteralPath $compatibilityArchivePath)) {
    throw "Compatibility archive already exists: $compatibilityArchivePath"
}

# Preparation is explicit: this verifies the runtime without changing it.
& (Join-Path $PSScriptRoot 'prepare-runtime.ps1') -Platform $Platform -CoreOnly | Out-Host

$temporaryDirectory = if ($WorkingDirectory) { [IO.Path]::GetFullPath($WorkingDirectory) } else { [IO.Path]::GetFullPath([IO.Path]::GetTempPath()) }
if (-not (Test-Path -LiteralPath $temporaryDirectory -PathType Container)) { throw 'Не найдена рабочая папка упаковки.' }
function Assert-PackageDiskSpace {
    $systemVolume = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($env:SystemRoot))
    if ($systemVolume.AvailableFreeSpace -lt 8GB) { throw 'Для упаковки нужно оставить не менее 8 ГБ на системном диске.' }
    $workVolume = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($temporaryDirectory))
    if ($workVolume.AvailableFreeSpace -lt 512MB) { throw 'В рабочей папке упаковки нужно оставить резерв 512 МБ.' }
}
Assert-PackageDiskSpace
$stagingRoot = Join-Path $temporaryDirectory ('homelibru-package-' + [guid]::NewGuid().ToString('N'))
$payloadDirectory = Join-Path $stagingRoot 'payload'
[System.IO.Directory]::CreateDirectory($payloadDirectory) | Out-Null
[IO.File]::WriteAllText((Join-Path $stagingRoot '.package-stage'), 'HomeLibre release packaging v1')
try {
    foreach ($name in @('HomeLibre.exe', 'HomeLibRu.exe', 'HomeLibRuUpdater.exe', 'sqlite3.dll', 'LICENSE', 'NOTICE')) {
        Copy-Item -LiteralPath (Join-Path $runtimeDirectory $name) -Destination $payloadDirectory
    }
    & (Join-Path $PSScriptRoot 'check-release-identity.ps1') -RuntimeDirectory $payloadDirectory `
        -Release $release -Version $releaseIdentity.version -Platform $Platform
    $genreDestination = Join-Path $payloadDirectory 'tools\genres'
    [IO.Directory]::CreateDirectory($genreDestination) | Out-Null
    foreach ($genre in Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'Installer\GenreLists') -Filter '*.glst' -File) {
        Copy-Item -LiteralPath $genre.FullName -Destination $genreDestination
    }
    $history = @(& (Join-Path $PSScriptRoot 'read-release-history.ps1') `
        -NotesDirectory (Join-Path $repositoryRoot 'docs/releases') `
        -CurrentTag $release -CurrentDisplay $releaseIdentity.display_version)
    # The runtime preflight has already matched Help to the source tree.
    Copy-Item -LiteralPath (Join-Path $runtimeDirectory 'Help') -Destination $payloadDirectory -Recurse
    # Local files next to the icon DLL are not part of the distribution.
    $iconDestination = Join-Path $payloadDirectory 'Icons'
    [IO.Directory]::CreateDirectory($iconDestination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $runtimeDirectory 'Icons\MHLIcons.dll') -Destination $iconDestination
    [IO.File]::WriteAllText((Join-Path $payloadDirectory 'Help\CHANGES.txt'),
        ($history -join "`r`n`r`n"), [Text.UTF8Encoding]::new($false))
    $updateMetadata = Join-Path $payloadDirectory 'tools\updates'
    [IO.Directory]::CreateDirectory($updateMetadata) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'Installer\Components.json') -Destination (Join-Path $updateMetadata 'COMPONENTS.json')
    $toolsDestination = Join-Path $payloadDirectory 'tools'
    # Genre/update metadata is shared catalogue data. Fonts belong to the
    # optional Reader package; native format adapters arrive with their modules.
    $offline = $null
    if ($Full -or $DocSharpBridge) {
        if (-not $OfflineVerifier) {
            $OfflineVerifier = Join-Path $repositoryRoot "Program/Tests/Out/$Platform/ProgramUpdateInstallerTest.exe"
        }
        $offlineReport = Join-Path $stagingRoot 'offline-components.json'
        $componentOptions = @()
        if ($DocSharpBridge) { $componentOptions += '--docsharp-bridge' }
        & python -B (Join-Path $PSScriptRoot 'stage-offline-components.py') `
            --payload $payloadDirectory --definition $OfflineComponents --native $OfflineVerifier --report $offlineReport @componentOptions | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить и собрать автономные компоненты.' }
        $offline = Get-Content -LiteralPath $offlineReport -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($offline.platform -cne $Platform) { throw 'Разрядность списка автономных компонентов не совпадает.' }
    }
    if ($Full) {
        $fontSource = Join-Path $repositoryRoot 'Installer/ReaderFonts'
        $fontDestination = Join-Path $toolsDestination 'fonts'
        $fontManifest = Get-Content -LiteralPath (Join-Path $fontSource 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($font in $fontManifest.files) {
            Assert-PackageDiskSpace
            $source = [IO.Path]::GetFullPath((Join-Path $fontSource $font.path))
            if (-not $source.StartsWith(($fontSource.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Путь шрифта выходит за папку источников.'
            }
            if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $font.sha256) {
                throw "Контрольная сумма шрифта не совпадает: $($font.path)"
            }
            $target = Join-Path $fontDestination $font.path
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            Copy-Item -LiteralPath $source -Destination $target
        }
        Copy-Item -LiteralPath (Join-Path $fontSource 'manifest.json') -Destination $fontDestination
        & python -B (Join-Path $PSScriptRoot 'stage-offline-prerequisites.py') `
            --payload $payloadDirectory --inputs $OfflinePrerequisiteInputs --native $OfflineVerifier | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить автономные компоненты Windows.' }
        $offlinePublic = [ordered]@{ format = 1; platform = $Platform; components = @($offline.components) }
        [IO.File]::WriteAllText((Join-Path $updateMetadata 'OFFLINE.json'),
            ($offlinePublic | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    }

    $manifestFiles = @(Get-ChildItem -LiteralPath $payloadDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($payloadDirectory.Length + 1).Replace('\', '/')
            size = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $manifest = [ordered]@{ format = 1; release = $release; platform = $Platform;
        distribution = $(if ($Full) { 'full' } else { 'minimal' }); files = $manifestFiles }
    if ($null -ne $offline) { $manifest.bundle = @($offline.components) }
    if ($Full) { $manifest.offline_prerequisites = $true }
    # Keep this transport manifest at the legacy ZIP root: older clients read
    # it before running the new updater. It is not an installed payload file.
    [IO.File]::WriteAllText((Join-Path $payloadDirectory 'HomeLibRu.update.json'),
        ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

    # No whole-runtime copy: Data, Presets, INI files, logs, old EXEs and test
    # fixtures in the output directory do not belong in a release archive.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryArchive = Join-Path $stagingRoot $archiveName
    Assert-PackageDiskSpace
    $zipOutput = [IO.Compression.ZipFile]::Open($temporaryArchive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $payloadDirectory -Recurse -File | Sort-Object FullName) {
            Assert-PackageDiskSpace
            $member = $file.FullName.Substring($payloadDirectory.Length + 1).Replace('\', '/')
            # Microsoft standalone installers already contain compressed data.
            # Recompressing them costs CPU without useful size reduction.
            $level = if ($Full -and $member -cmatch '^tools/prerequisites/(webview2-(x86|x64)|dotnet-framework-4\.8)\.exe$') {
                [IO.Compression.CompressionLevel]::NoCompression
            } else { [IO.Compression.CompressionLevel]::Optimal }
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipOutput, $file.FullName, $member, $level) | Out-Null
        }
    }
    finally { $zipOutput.Dispose() }
    Assert-PackageDiskSpace
    $archive = [System.IO.Compression.ZipFile]::OpenRead($temporaryArchive)
    try {
        if (-not $Full) {
            foreach ($entry in $archive.Entries) {
                $coreResource = $entry.FullName -ceq 'tools/updates/COMPONENTS.json' -or
                    $entry.FullName -cmatch '^tools/genres/genres_(fb2|nonfb2)(_(bg|en|uk))?\.glst$'
                if ($DocSharpBridge -and $entry.FullName.StartsWith('tools/doc/', [StringComparison]::Ordinal)) {
                    $coreResource = $true
                }
                if (($entry.FullName.StartsWith('tools/') -and -not $coreResource) -or
                    $entry.FullName.StartsWith('Readers/') -or $entry.FullName.StartsWith('converters/') -or
                    $entry.FullName -in @('HomeLibReader.exe', 'HomeLibreReader.exe', 'MHLMcpServer.exe', 'HomeLibRu.url', 'HomeLibre.url', 'libzstd.dll')) {
                    throw "Optional payload leaked into minimal catalogue archive: $($entry.FullName)"
                }
                if (-not $entry.FullName.Contains('/') -and $entry.FullName -notin @(
                    'HomeLibre.exe', 'HomeLibRu.exe', 'HomeLibRuUpdater.exe', 'sqlite3.dll', 'LICENSE', 'NOTICE', 'HomeLibRu.update.json')) {
                    throw "Unexpected file in minimal catalogue root: $($entry.FullName)"
                }
            }
        }
        foreach ($name in @('HomeLibre.exe', 'HomeLibRu.exe', 'LICENSE', 'NOTICE')) {
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
    if ($compatibilityArchivePath) {
        # Published clients through beta 13 reject unknown root EXE names.
        # They still see the old-name compatibility launcher and transport the
        # real catalogue under an accepted tools path. The matching updater
        # journals its final destination as HomeLibre.exe; it is never run here.
        $transportName = 'tools/updates/catalogue/HomeLibre.exe'
        $transportPath = Join-Path $payloadDirectory $transportName
        [IO.Directory]::CreateDirectory((Split-Path -Parent $transportPath)) | Out-Null
        Move-Item -LiteralPath (Join-Path $payloadDirectory 'HomeLibre.exe') -Destination $transportPath
        $applicationEntry = @($manifestFiles | Where-Object { $_.path -ceq 'HomeLibre.exe' })
        if ($applicationEntry.Count -ne 1) { throw 'Missing canonical catalogue manifest entry.' }
        $applicationEntry[0].path = $transportName
        [IO.File]::WriteAllText((Join-Path $payloadDirectory 'HomeLibRu.update.json'),
            ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        $temporaryBridge = Join-Path $stagingRoot $baseArchiveName
        [IO.Compression.ZipFile]::CreateFromDirectory($payloadDirectory, $temporaryBridge,
            [IO.Compression.CompressionLevel]::Optimal, $false)
        $bridge = [IO.Compression.ZipFile]::OpenRead($temporaryBridge)
        try {
            if ($null -ne $bridge.GetEntry('HomeLibre.exe') -or
                $null -eq $bridge.GetEntry($transportName) -or
                $null -eq $bridge.GetEntry('HomeLibRu.exe')) { throw 'Invalid compatibility archive layout.' }
        } finally { $bridge.Dispose() }
        Move-Item -LiteralPath $temporaryBridge -Destination $compatibilityArchivePath
    }
    [pscustomobject]@{
        Release = $release
        Platform = $Platform
        Archive = $archivePath
        SHA256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        CompatibilityArchive = $compatibilityArchivePath
        CompatibilitySHA256 = $(if ($compatibilityArchivePath) {
            (Get-FileHash -LiteralPath $compatibilityArchivePath -Algorithm SHA256).Hash
        } else { $null })
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
