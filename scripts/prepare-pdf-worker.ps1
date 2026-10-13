[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Win32', 'Win64')][string]$Platform,
    [switch]$Copy
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$pinPath = Join-Path $repository 'Installer\PDF_WORKER_RUNTIME.json'
$pin = Get-Content -LiteralPath $pinPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($entry in $pin.sources.PSObject.Properties) {
    if ((Get-FileHash -LiteralPath (Join-Path $repository $entry.Name) -Algorithm SHA256).Hash -ine $entry.Value) {
        throw "PDF renderer sources differ from the compiled release pin: $($entry.Name)"
    }
}
$bin = if ($Platform -eq 'Win64') {'Bin64'} else {'Bin'}
$runtime = Join-Path $repository "Program\Out\$bin\tools\pdfium"
$source = Join-Path $repository "Utils\HomeLibPDF\Out\$Platform\HomeLibPDF.exe"
$target = Join-Path $runtime 'HomeLibPDF.exe'
if ($Copy) {
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $pin.$Platform.sha256) {
        throw 'Build the matching HomeLibPDF Release project in RAD Studio first.'
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
    Copy-Item -LiteralPath $pinPath -Destination (Join-Path $runtime 'WORKER_RUNTIME.json') -Force
    Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination (Join-Path $runtime 'HomeLibPDF-LICENSE.txt') -Force
}
if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $pin.$Platform.sha256) {
    throw 'PDF renderer missing or differs from the release pin.'
}
if ((Get-FileHash -LiteralPath (Join-Path $runtime 'WORKER_RUNTIME.json')).Hash -ine
    (Get-FileHash -LiteralPath $pinPath).Hash) {throw 'PDF renderer pin missing from the runtime.'}
if ((Get-FileHash -LiteralPath (Join-Path $runtime 'HomeLibPDF-LICENSE.txt')).Hash -ine
    (Get-FileHash -LiteralPath (Join-Path $repository 'LICENSE')).Hash) {throw 'PDF renderer licence missing.'}
Write-Output "Pinned isolated PDF renderer verified ($Platform)."
