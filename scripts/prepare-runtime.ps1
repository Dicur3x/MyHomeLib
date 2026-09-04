[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,

    [string]$SqliteDll,

    [switch]$Copy,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PeArchitecture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $stream = [System.IO.File]::Open(
        $resolvedPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $reader = [System.IO.BinaryReader]::new($stream)

    try {
        if ($stream.Length -lt 64) {
            throw "Файл слишком мал и не является PE: $resolvedPath"
        }

        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "Не найден заголовок MZ: $resolvedPath"
        }

        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if (($peOffset -lt 0) -or (($peOffset + 6) -gt $stream.Length)) {
            throw "Некорректное смещение PE-заголовка: $resolvedPath"
        }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Не найден заголовок PE: $resolvedPath"
        }

        $machine = $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }

    switch ($machine) {
        0x014C { return 'Win32' }
        0x8664 { return 'Win64' }
        default { throw ('Неподдерживаемая PE-архитектура 0x{0:X4}: {1}' -f $machine, $resolvedPath) }
    }
}

function Assert-Architecture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Expected
    )

    $actual = Get-PeArchitecture -Path $Path
    if ($actual -ne $Expected) {
        throw "Архитектура '$Path' — $actual, а требуется $Expected."
    }

    Write-Host "[OK] $Path ($actual)"
}

function Copy-CheckedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $sourcePath = (Resolve-Path -LiteralPath $Source).Path
    $destinationPath = [System.IO.Path]::GetFullPath($Destination)

    if ($sourcePath -ieq $destinationPath) {
        Write-Host "[OK] Файл уже находится в папке запуска: $destinationPath"
        return
    }

    if (Test-Path -LiteralPath $destinationPath) {
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash
        $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destinationPath).Hash

        if ($sourceHash -eq $destinationHash) {
            Write-Host "[OK] Файл назначения уже совпадает по SHA-256: $destinationPath"
            return
        }

        if (-not ($Copy -and $Force)) {
            throw "Файл назначения уже существует и отличается. Для явного обновления используйте -Copy -Force: $destinationPath"
        }

        [System.IO.File]::Copy($sourcePath, $destinationPath, $true)
        Write-Host "[REPLACED] $destinationPath"
        return
    }

    if (-not $Copy) {
        Write-Host "[CHECK] Можно скопировать '$sourcePath' в '$destinationPath'. Добавьте -Copy."
        return
    }

    [System.IO.File]::Copy($sourcePath, $destinationPath, $false)
    Write-Host "[COPIED] $destinationPath"
}

function Write-FileHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
        Write-Host "SHA-256  $hash  $Path"
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot

if ($Force -and (-not $Copy)) {
    throw "Параметр -Force разрешён только вместе с -Copy."
}

$programDirectory = Join-Path $repositoryRoot 'Program'
$outputSubdirectory = if ($Platform -eq 'Win32') { 'Out\Bin' } else { 'Out\Bin64' }
$outputDirectory = Join-Path $programDirectory $outputSubdirectory
$exePath = Join-Path $outputDirectory 'MyHomeLib.exe'
$sqliteDestination = Join-Path $outputDirectory 'sqlite3.dll'
$zstdDestination = Join-Path $outputDirectory 'libzstd.dll'
$sevenZipDestination = Join-Path $outputDirectory 'tools\7zip\7za.exe'
$jpegXlDestination = Join-Path $outputDirectory 'tools\jpeg-xl\djxl.exe'

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Сначала соберите $Platform Release: не найден '$exePath'."
}

$exeInfo = Get-Item -LiteralPath $exePath
if ($exeInfo.Length -eq 0) {
    throw "EXE имеет нулевой размер и не является успешной сборкой: $exePath"
}

Assert-Architecture -Path $exePath -Expected $Platform

if ([string]::IsNullOrWhiteSpace($SqliteDll)) {
    if (-not (Test-Path -LiteralPath $sqliteDestination -PathType Leaf)) {
        throw "Не найдена обязательная sqlite3.dll. Укажите доверенный файл через -SqliteDll, сначала без -Copy."
    }

    Assert-Architecture -Path $sqliteDestination -Expected $Platform
}
else {
    Assert-Architecture -Path $SqliteDll -Expected $Platform
    Copy-CheckedFile -Source $SqliteDll -Destination $sqliteDestination

    if (Test-Path -LiteralPath $sqliteDestination -PathType Leaf) {
        Assert-Architecture -Path $sqliteDestination -Expected $Platform
    }
}

$requiredRuntimeFiles = @(
    (Join-Path $outputDirectory 'Icons\MHLIcons.dll'),
    (Join-Path $outputDirectory 'Help\index.html'),
    (Join-Path $outputDirectory 'MHLMcpServer.exe'),
    $zstdDestination,
    $sevenZipDestination,
    (Join-Path $outputDirectory 'tools\7zip\License.txt'),
    $jpegXlDestination,
    (Join-Path $outputDirectory 'tools\jpeg-xl\licenses\LICENSE.libjxl')
)
foreach ($requiredFile in $requiredRuntimeFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Неполная сборка: отсутствует '$requiredFile'. Соберите три проекта по порядку из BUILDING.md."
    }
}

Assert-Architecture -Path (Join-Path $outputDirectory 'Icons\MHLIcons.dll') -Expected $Platform
Assert-Architecture -Path (Join-Path $outputDirectory 'MHLMcpServer.exe') -Expected $Platform
Assert-Architecture -Path $zstdDestination -Expected $Platform
Assert-Architecture -Path $sevenZipDestination -Expected $Platform
# libjxl currently publishes a static Windows x64 decoder.  A Win32 MyHomeLib
# process can launch it normally on 64-bit Windows.
Assert-Architecture -Path $jpegXlDestination -Expected 'Win64'

$genreSourceDirectory = Join-Path $repositoryRoot 'Installer\GenreLists'
foreach ($genreFile in Get-ChildItem -LiteralPath $genreSourceDirectory -Filter '*.glst' -File) {
    Copy-CheckedFile -Source $genreFile.FullName -Destination (Join-Path $outputDirectory $genreFile.Name)
}

Write-Host ''
Write-Host 'Проверенные файлы:'
Write-FileHash -Path $exePath
Write-FileHash -Path $sqliteDestination
Write-FileHash -Path $zstdDestination
Write-FileHash -Path (Join-Path $outputDirectory 'Icons\MHLIcons.dll')
Write-FileHash -Path (Join-Path $outputDirectory 'MHLMcpServer.exe')
Write-FileHash -Path $sevenZipDestination
Write-FileHash -Path $jpegXlDestination
