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
$converterFiles = @('convert_book.py', 'text_inputs.py', 'kindle_input.py', 'LICENSE.txt', 'README.md', 'THIRD_PARTY.md')
$converterFiles += @(Get-ChildItem -LiteralPath (Join-Path $sourceDirectory 'vendor') -Recurse -File |
    Where-Object { $_.Extension -eq '.py' -or $_.Name -eq 'py.typed' -or $_.Name -eq 'MISTUNE_LICENSE.txt' } |
    ForEach-Object { $_.FullName.Substring($sourceDirectory.Length + 1) })
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
Write-Host "[OK] Built-in FB2/EPUB converter matches source ($Platform)."
