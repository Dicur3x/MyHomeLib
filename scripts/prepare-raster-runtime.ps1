[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Win32', 'Win64')][string]$Platform,
    [string]$DjvuArchive,
    [string]$SevenZipArchive,
    [string]$Extractor,
    [switch]$Copy
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$pinPath = Join-Path $repository 'Installer\RASTER_RUNTIME.json'
$pin = Get-Content -LiteralPath $pinPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bin = if ($Platform -eq 'Win64') {'Bin64'} else {'Bin'}
$runtime = Join-Path $repository "Program\Out\$bin\tools"
function Assert-PinnedFiles($Directory, $Files) {
    foreach ($property in $Files.PSObject.Properties) {
        $path = Join-Path $Directory $property.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $property.Value) {
            throw "Raster runtime missing or differs from pinned official file: $path"
        }
    }
}
if ($Copy) {
    if ([string]::IsNullOrWhiteSpace($Extractor)) {
        $Extractor = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    }
    if (-not (Test-Path -LiteralPath $Extractor -PathType Leaf)) {throw 'Provide an existing full 7-Zip extractor.'}
    foreach ($entry in @(
        @{Name='djvu';Archive=$DjvuArchive;Spec=$pin.djvu},
        @{Name='7zip';Archive=$SevenZipArchive;Spec=$pin.sevenzip.$Platform}
    )) {
        if ([string]::IsNullOrWhiteSpace($entry.Archive)) {throw 'Provide the pinned DjVu and 7-Zip installer files; they are extracted, never installed.'}
        if ((Get-FileHash -LiteralPath $entry.Archive -Algorithm SHA256).Hash -ine $entry.Spec.sha256) {throw "Official archive checksum mismatch: $($entry.Name)"}
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $staging = Join-Path $tempBase ('homelibru-raster-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        try {
            # 7-Zip installer may ignore the member selection. Only the pinned
            # allowlist below is ever copied into our runtime.
            $arguments = @('x', $entry.Archive, "-o$staging", '-y') + @($entry.Spec.files.PSObject.Properties.Name)
            & $Extractor @arguments | Out-Null
            if ($LASTEXITCODE -ne 0) {throw "Cannot extract $($entry.Name)"}
            Assert-PinnedFiles $staging $entry.Spec.files
            $destination = Join-Path $runtime $entry.Name
            [IO.Directory]::CreateDirectory($destination) | Out-Null
            foreach ($property in $entry.Spec.files.PSObject.Properties) {
                Copy-Item -LiteralPath (Join-Path $staging $property.Name) -Destination $destination -Force
            }
            Copy-Item -LiteralPath $pinPath -Destination (Join-Path $destination 'RUNTIME.json') -Force
        } finally {
            $resolved = [IO.Path]::GetFullPath($staging)
            if (-not $resolved.StartsWith($tempBase.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
                -not [IO.Path]::GetFileName($resolved).StartsWith('homelibru-raster-')) {throw 'Unexpected staging path'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
    $sourceDirectory = Join-Path $repository 'tools\runtime\djvu'
    Assert-PinnedFiles $sourceDirectory $pin.djvu.distribution
    foreach ($property in $pin.djvu.distribution.PSObject.Properties) {
        Copy-Item -LiteralPath (Join-Path $sourceDirectory $property.Name) -Destination (Join-Path $runtime 'djvu') -Force
    }
}
$helperSource = Join-Path $repository 'Utils\HomeLibDjvu\Out\Win32\HomeLibDjvu.exe'
$helperTarget = Join-Path $runtime 'djvu\HomeLibDjvu.exe'
if ($Copy) {
    if (-not (Test-Path -LiteralPath $helperSource -PathType Leaf) -or
        (Get-FileHash -LiteralPath $helperSource -Algorithm SHA256).Hash -ine $pin.viewer_helper.sha256) {
        throw 'Build the pinned HomeLibDjvu Win32 Release project in RAD Studio first.'
    }
    Copy-Item -LiteralPath $helperSource -Destination $helperTarget -Force
}
if (-not (Test-Path -LiteralPath $helperTarget -PathType Leaf) -or
    (Get-FileHash -LiteralPath $helperTarget -Algorithm SHA256).Hash -ine $pin.viewer_helper.sha256) {
    throw 'Persistent DjVu renderer missing or differs from the release pin.'
}
$helperSources = @{
    'HomeLibDjvu.dpr'='Utils\HomeLibDjvu\HomeLibDjvu.dpr';
    'HomeLibDjvu.dproj'='Utils\HomeLibDjvu\HomeLibDjvu.dproj';
    'unit_DjvuProtocol.pas'='Program\Units\unit_DjvuProtocol.pas';
    'README.md'='Utils\HomeLibDjvu\README.md';
    'LICENSE'='Utils\HomeLibDjvu\LICENSE'
}
# The helper's complete matching source accompanies the GPL decoder sources.
$sourceTarget = Join-Path $runtime 'djvu\HomeLibDjvu-source'
if ($Copy) {[IO.Directory]::CreateDirectory($sourceTarget) | Out-Null}
foreach ($entry in $helperSources.GetEnumerator()) {
    $source = Join-Path $repository $entry.Value
    $target = Join-Path $sourceTarget $entry.Key
    if ($Copy) {Copy-Item -LiteralPath $source -Destination $target -Force}
    if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
        throw "Persistent renderer source missing or differs from the release: $($entry.Key)"
    }
}
Assert-PinnedFiles (Join-Path $runtime 'djvu') $pin.djvu.files
Assert-PinnedFiles (Join-Path $runtime 'djvu') $pin.djvu.distribution
Assert-PinnedFiles (Join-Path $runtime '7zip') $pin.sevenzip.$Platform.files
Write-Host "[OK] DjVu $($pin.djvu.version) separate x86 helper and full 7-Zip $($pin.sevenzip.version), pinned files ($Platform). No OCR runtime."
