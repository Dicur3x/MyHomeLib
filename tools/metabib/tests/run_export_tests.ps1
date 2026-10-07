param(
    [ValidateSet('Win64', 'Win32')][string]$Platform = 'Win64',
    [ValidateSet('all', 'metadata', 'worker', 'ui')][string]$Case = 'all',
    [string]$Node = 'node'
)
$ErrorActionPreference = 'Stop'
# Build the two .dproj files in RAD Studio first. This also works with Trial.
$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$Runtime = Join-Path $Root $(if ($Platform -eq 'Win64') { 'Program/Out/Bin64' } else { 'Program/Out/Bin' })
$ExportExe = Join-Path $PSScriptRoot "Out/$Platform/MetabibExportTest.exe"
$UiExe = Join-Path $PSScriptRoot "Out/$Platform/GroupExportUITest.exe"
& $Node (Join-Path $PSScriptRoot 'export_tests.js') $Runtime $ExportExe $UiExe $Case
if ($LASTEXITCODE -ne 0) { throw "Export regression failed ($Platform, $Case)." }
# The isolated runner prints and preserves its own diagnostic folders.
