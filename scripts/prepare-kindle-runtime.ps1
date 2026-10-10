[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Win32','Win64')][string]$Platform,
      [switch]$Download, [switch]$Copy)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $repository 'Installer/KINDLE_RUNTIME.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$arch = if ($Platform -eq 'Win64') { 'x64' } else { 'x86' }
$runtime = Join-Path $repository "tools/runtime/$arch/kindle"
if ($Download) {
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $staging = Join-Path $temporaryBase ('homelibru-kindle-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        foreach ($entry in @(@{Name='python';Spec=$manifest.python.$Platform},@{Name='kindle';Spec=$manifest.kindleunpack})) {
            $archive = Join-Path $staging ($entry.Name+'.zip')
            Invoke-WebRequest -Uri $entry.Spec.url -OutFile $archive
            if ((Get-FileHash -LiteralPath $archive).Hash -ine $entry.Spec.sha256) { throw ('Checksum mismatch: '+$entry.Name) }
            $destination = Join-Path $staging $entry.Name
            Expand-Archive -LiteralPath $archive -DestinationPath $destination
        }
        [IO.Directory]::CreateDirectory($runtime) | Out-Null
        Copy-Item -LiteralPath (Join-Path $staging 'python') -Destination $runtime -Recurse -Force
        $kindle = Join-Path $staging ('kindle/KindleUnpack-'+$manifest.kindleunpack.commit)
        Copy-Item -LiteralPath (Join-Path $kindle 'lib') -Destination $runtime -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $kindle 'COPYING.txt') -Destination $runtime -Force
        $provenance = 'KindleUnpack https://github.com/kevinhendricks/KindleUnpack' + [Environment]::NewLine + 'Commit ' + $manifest.kindleunpack.commit + [Environment]::NewLine + 'GPL-3.0, separate helper process; upstream source preserved.'
        Set-Content -LiteralPath (Join-Path $runtime 'SOURCE_COMMIT.txt') -Value $provenance -Encoding ascii
    } finally {
        $resolved = [IO.Path]::GetFullPath($staging)
        if (-not $resolved.StartsWith($temporaryBase,[StringComparison]::OrdinalIgnoreCase) -or
            -not [IO.Path]::GetFileName($resolved).StartsWith('homelibru-kindle-')) { throw 'Unsafe temporary path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
$converter = Join-Path $repository 'tools/kindle/convert_kf8.py'
if ($Download) { Copy-Item -LiteralPath $converter -Destination $runtime -Force }
foreach ($name in @('python/python.exe','python/python313.dll','python/python313.zip','python/LICENSE.txt','lib/kindleunpack.py','COPYING.txt','convert_kf8.py')) {
    if (-not (Test-Path -LiteralPath (Join-Path $runtime $name) -PathType Leaf)) { throw "Missing Kindle runtime: $name. Use -Download." }
}
if ((Get-FileHash -LiteralPath (Join-Path $runtime 'convert_kf8.py')).Hash -ine (Get-FileHash -LiteralPath $converter).Hash) { throw 'Kindle converter differs from its source.' }
$outputName = if ($Platform -eq 'Win64') { 'Bin64' } else { 'Bin' }
$output = Join-Path $repository "Program/Out/$outputName/tools/kindle"
if ($Copy) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $output)) | Out-Null
    Copy-Item -LiteralPath $runtime -Destination (Split-Path -Parent $output) -Recurse -Force
}
foreach ($source in Get-ChildItem -LiteralPath $runtime -File -Recurse) {
    $relative = [IO.Path]::GetRelativePath($runtime,$source.FullName)
    if ($relative.Contains('__pycache__')) { continue }
    $target = Join-Path $output $relative
    if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
        (Get-FileHash -LiteralPath $source.FullName).Hash -ine (Get-FileHash -LiteralPath $target).Hash) { throw "Kindle runtime differs: $relative. Use -Copy." }
}
Write-Host "[OK] Private Kindle runtime, source and licenses match ($Platform)."
