[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,
    [switch]$Copy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputName = if ($Platform -eq 'Win64') { 'Bin64' } else { 'Bin' }
$sourceDirectory = Join-Path $repositoryRoot 'tools\bookconvert'
$destinationDirectory = Join-Path $repositoryRoot "Program\Out\$outputName\tools\bookconvert"

# The converter shares the already bundled Python runtime. Ship only the
# production script and its documentation, never fixtures or validation tools.
$converterFiles = @('convert_book.py', 'text_inputs.py', 'kindle_input.py', 'legacy_inputs.py', 'legacy_helper.py', 'rgo_input.py', 'isilo_input.py', 'isilo_image.py', 'jutoh_input.py', 'pages_input.py', 'cr3_input.py', 'b1_input.py', 'fixed_layout.py', 'office_inputs.py', 'xps_input.py', 'image_input.py', 'tiff_jpeg.py', 'image_quality.py', 'scan_export.py', 'ha_input.py', 'LICENSE.txt', 'README.md', 'THIRD_PARTY.md')
$converterFiles += @(Get-ChildItem -LiteralPath (Join-Path $sourceDirectory 'vendor') -Recurse -File |
    Where-Object { $_.Extension -eq '.py' -or $_.Name -eq 'py.typed' -or $_.Name -eq 'SOURCE.json' -or $_.Name -like '*_LICENSE.txt' } |
    ForEach-Object { $_.FullName.Substring($sourceDirectory.Length + 1) })
$converterFiles += @('sm_input.py', 'sm_runtime.js', 'sm_reader.py', 'sm_resources.py', 'js_runtime.py')
$converterFiles += 'rgo_outline.py'
$converterFiles += @('ibk_input.py', 'ibk_crypto.py', 'ibk_parameters.json', 'ibk_tables.bin')
foreach ($name in $converterFiles) {
    $sourcePath = Join-Path $sourceDirectory $name
    $destinationPath = Join-Path $destinationDirectory $name
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Missing book converter source: $sourcePath"
    }
    if ($Copy) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
        [IO.File]::Copy($sourcePath, $destinationPath, $true)
    }
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $sourcePath).Hash -ine
        (Get-FileHash -LiteralPath $destinationPath).Hash) {
        throw "Book converter differs from source: $name. Use -Copy."
    }
}
$legacyRoot = Join-Path $destinationDirectory 'vendor/calibre_legacy/native'
$legacyDll = Join-Path $legacyRoot 'HomeLibLegacy.dll'
$legacyManifest = Join-Path $legacyRoot 'RUNTIME.json'
if (-not (Test-Path -LiteralPath $legacyDll -PathType Leaf) -or
    -not (Test-Path -LiteralPath $legacyManifest -PathType Leaf)) {
    throw 'Missing LIT decoder. Build it with scripts/prepare-legacy-runtime.py for this platform.'
}
$legacyInfo = Get-Content -LiteralPath $legacyManifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($legacyInfo.platform -ne $Platform -or
    $legacyInfo.sha256 -ine (Get-FileHash -LiteralPath $legacyDll -Algorithm SHA256).Hash) {
    throw 'LIT decoder identity mismatch.'
}
foreach ($entry in $legacyInfo.sources.PSObject.Properties) {
    if ($entry.Name -notmatch '^[A-Za-z0-9._-]+\.(c|h)$') { throw 'Invalid decoder source name.' }
    $source = Join-Path $sourceDirectory "vendor/calibre_legacy/native/$($entry.Name)"
    if ($entry.Value -ine (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash) { throw "LIT decoder requires rebuilding: $($entry.Name)" }
}
$reader = [IO.BinaryReader]::new([IO.File]::OpenRead($legacyDll))
try {
    $reader.BaseStream.Position = 0x3c
    $reader.BaseStream.Position = $reader.ReadInt32() + 4
    $machine = $reader.ReadUInt16()
    $expected = if ($Platform -eq 'Win32') { 0x14c } else { 0x8664 }
    if ($machine -ne $expected) { throw 'LIT decoder architecture mismatch.' }
} finally { $reader.Dispose() }
Write-Host "[OK] Built-in FB2/EPUB converter and LIT decoder match source ($Platform)."

$xpsRoot = Join-Path $destinationDirectory '../xps'
$xpsInfo = Get-Content -LiteralPath (Join-Path $xpsRoot 'RUNTIME.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($xpsInfo.platform -ne $Platform -or
    $xpsInfo.source_sha256 -ine (Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'Utils/HomeLibXps/HomeLibXps.cs')).Hash -or
    $xpsInfo.sha256 -ine (Get-FileHash -LiteralPath (Join-Path $xpsRoot 'HomeLibXps.exe')).Hash) {
    throw 'XPS renderer requires rebuilding: scripts/prepare-xps-runtime.ps1.'
}
$xpsReader = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $xpsRoot 'HomeLibXps.exe')))
try {
    $xpsReader.BaseStream.Position = 0x3c
    $xpsReader.BaseStream.Position = $xpsReader.ReadInt32() + 4
    $expected = if ($Platform -eq 'Win32') { 0x14c } else { 0x8664 }
    if ($xpsReader.ReadUInt16() -ne $expected) { throw 'XPS renderer architecture mismatch.' }
} finally { $xpsReader.Dispose() }
Write-Host "[OK] XPS renderer matches source ($Platform)."
