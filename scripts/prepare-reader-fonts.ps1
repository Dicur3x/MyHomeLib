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
$source = Join-Path $repositoryRoot 'Installer\ReaderFonts'
$output = if ($Platform -eq 'Win32') { 'Program\Out\Bin' } else { 'Program\Out\Bin64' }
$destination = Join-Path $repositoryRoot "$output\tools\fonts"
$manifest = Get-Content -LiteralPath (Join-Path $source 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($file in $manifest.files) {
    $original = Join-Path $source $file.path
    $target = Join-Path $destination $file.path
    if ((Get-FileHash -LiteralPath $original).Hash -ine $file.sha256) {
        throw "Reader font source hash mismatch: $($file.path)"
    }
    if ($Copy) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $original -Destination $target
    }
    if ((Get-FileHash -LiteralPath $target).Hash -ine $file.sha256) {
        throw "Reader font runtime hash mismatch: $($file.path)"
    }
}
if ($Copy) { Copy-Item -LiteralPath (Join-Path $source 'manifest.json') -Destination $destination }
Write-Host '[OK] Portable PT / Noto reading fonts and multilingual resources with original OFL licenses.'
