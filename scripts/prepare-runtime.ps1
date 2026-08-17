[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,

    [string]$SqliteDll,

    [string]$OpenSslDirectory,

    [switch]$Copy
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

        throw "Файл назначения уже существует и отличается. Скрипт не будет его перезаписывать: $destinationPath"
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
$programDirectory = Join-Path $repositoryRoot 'Program'
$outputSubdirectory = if ($Platform -eq 'Win32') { 'Out\Bin' } else { 'Out\Bin64' }
$outputDirectory = Join-Path $programDirectory $outputSubdirectory
$exePath = Join-Path $outputDirectory 'MyHomeLib.exe'
$sqliteDestination = Join-Path $outputDirectory 'sqlite3.dll'
$sslFileNames = @('libeay32.dll', 'ssleay32.dll')

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

if ([string]::IsNullOrWhiteSpace($OpenSslDirectory)) {
    $existingSslFiles = @($sslFileNames | Where-Object {
        Test-Path -LiteralPath (Join-Path $outputDirectory $_) -PathType Leaf
    })

    if ($existingSslFiles.Count -eq 0) {
        Write-Warning 'OpenSSL DLL не найдены. Программа запустится, но HTTPS-функции Indy могут не работать.'
    }
    elseif ($existingSslFiles.Count -ne $sslFileNames.Count) {
        throw 'В папке запуска найдена только часть пары OpenSSL. Нужны одновременно libeay32.dll и ssleay32.dll.'
    }
    else {
        foreach ($name in $sslFileNames) {
            Assert-Architecture -Path (Join-Path $outputDirectory $name) -Expected $Platform
        }
    }
}
else {
    $resolvedSslDirectory = (Resolve-Path -LiteralPath $OpenSslDirectory).Path
    foreach ($name in $sslFileNames) {
        $sourcePath = Join-Path $resolvedSslDirectory $name
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "В каталоге OpenSSL отсутствует '$name': $resolvedSslDirectory"
        }

        Assert-Architecture -Path $sourcePath -Expected $Platform
        Copy-CheckedFile -Source $sourcePath -Destination (Join-Path $outputDirectory $name)
    }
}

foreach ($recommendedFile in @('genres_fb2.glst', 'genres_nonfb2.glst')) {
    if (-not (Test-Path -LiteralPath (Join-Path $outputDirectory $recommendedFile) -PathType Leaf)) {
        Write-Warning "Не найден '$recommendedFile': для создания коллекции этого типа положите штатный файл рядом с EXE либо явно выберите совместимый .glst в мастере."
    }
}

Write-Host ''
Write-Host 'Проверенные файлы:'
Write-FileHash -Path $exePath
Write-FileHash -Path $sqliteDestination
foreach ($name in $sslFileNames) {
    Write-FileHash -Path (Join-Path $outputDirectory $name)
}
