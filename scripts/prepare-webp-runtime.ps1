[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Build current libwebp ourselves: Google no longer supplies an up-to-date
# Windows x86 binary. TinyCC needs no installed toolchain or VC redistributable.
# SIMD and threading are disabled for the compact, CPU-only book-image decoder.
$sourceUrl = 'https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz'
$sourceSha = 'E4AB7009BF0629FD11982D4C2AA83964CF244CFFBA7347ECD39019A9E38C4564'
$compiler = if ($Platform -eq 'Win32') {
    @{
        Url = 'https://download.savannah.nongnu.org/releases/tinycc/tcc-0.9.27-win32-bin.zip'
        Sha = '02E2BFE8C272A549B15E4BFA4507BD7E05304692AF1761DB6C1E8E88AF675651'
    }
} else {
    @{
        Url = 'https://download.savannah.nongnu.org/releases/tinycc/tcc-0.9.27-win64-bin.zip'
        Sha = '34A721949A2583FDFF725312DA092FA0F5F1F284B702E6F811C6954714FAABB2'
    }
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$bin = if ($Platform -eq 'Win32') { 'Bin' } else { 'Bin64' }
$output = Join-Path $repoRoot "Program\Out\$bin\tools\webp"
$sevenZip = Join-Path $repoRoot "Program\Out\$bin\tools\7zip\7za.exe"
if (-not (Test-Path -LiteralPath $sevenZip -PathType Leaf)) {
    throw 'Prepare the existing FLibrary runtime first (7-Zip is required).'
}
$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('HomeLibRu-WebP-build-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($buildRoot) | Out-Null

function Get-VerifiedSource([string]$Url, [string]$Path, [string]$Sha) {
    Invoke-WebRequest -Uri $Url -OutFile $Path
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash -ne $Sha) {
        throw "Source checksum mismatch: $Url"
    }
}

try {
    $compilerZip = Join-Path $buildRoot 'tcc.zip'
    $sourceGzip = Join-Path $buildRoot 'libwebp.tar.gz'
    Get-VerifiedSource $compiler.Url $compilerZip $compiler.Sha
    Get-VerifiedSource $sourceUrl $sourceGzip $sourceSha
    Expand-Archive -LiteralPath $compilerZip -DestinationPath (Join-Path $buildRoot 'compiler')
    & $sevenZip x -y "-o$buildRoot" -- $sourceGzip | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot unpack libwebp gzip.' }
    & $sevenZip x -y "-o$buildRoot" -- (Join-Path $buildRoot 'libwebp.tar') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot unpack libwebp sources.' }
    $sourceRoot = Join-Path $buildRoot 'libwebp-1.6.0'
    $compilerExe = Join-Path $buildRoot 'compiler\tcc\tcc.exe'
    [IO.Directory]::CreateDirectory($output) | Out-Null
    $temporaryDll = Join-Path $buildRoot 'libwebp.dll'
    $arguments = @('-shared', '-DWEBP_DLL', '-DWEBP_DISABLE_SIMD', "-I$sourceRoot", '-o', $temporaryDll)
    foreach ($folder in @('src\dec', 'src\dsp', 'src\utils')) {
        $arguments += @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot $folder) -Filter '*.c' -File |
            Sort-Object Name | ForEach-Object FullName)
    }
    & $compilerExe @arguments
    if (($LASTEXITCODE -ne 0) -or (-not (Test-Path -LiteralPath $temporaryDll -PathType Leaf))) {
        throw 'Cannot build the libwebp decoder.'
    }
    Copy-Item -LiteralPath $temporaryDll -Destination (Join-Path $output 'libwebp.dll') -Force
    foreach ($license in @('COPYING', 'PATENTS', 'AUTHORS')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $license) -Destination (Join-Path $output "$license.txt") -Force
    }
    Write-Host "[OK] libwebp 1.6.0 ${Platform}: $output"
    Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $output 'libwebp.dll')
} finally {
    $resolvedBuildRoot = [IO.Path]::GetFullPath($buildRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedBuildRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $resolvedBuildRoot).StartsWith('HomeLibRu-WebP-build-')) {
        throw 'Unexpected build directory; cleanup was skipped.'
    }
    Remove-Item -LiteralPath $resolvedBuildRoot -Recurse -Force
}
