[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,
    [string]$Archive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repositoryRoot 'Installer\PDFIUM_RUNTIME.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target = $manifest.$Platform
$runtimeName = if ($Platform -eq 'Win32') { 'Bin' } else { 'Bin64' }
$destination = Join-Path $repositoryRoot "Program\Out\$runtimeName\tools\pdfium"
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$staging = Join-Path $temporaryRoot ('homelibru-pdfium-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($staging) | Out-Null
try {
    if ([string]::IsNullOrWhiteSpace($Archive)) {
        $Archive = Join-Path $staging 'pdfium.tgz'
        Invoke-WebRequest -Uri $target.url -OutFile $Archive
    }
    $Archive = (Resolve-Path -LiteralPath $Archive).Path
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ine $target.archive_sha256) {
        throw 'PDFium archive SHA-256 does not match the pinned runtime.'
    }
    $unpacked = Join-Path $staging 'unpacked'
    [IO.Directory]::CreateDirectory($unpacked) | Out-Null
    & tar.exe -xf $Archive -C $unpacked
    if ($LASTEXITCODE -ne 0) { throw 'Cannot extract PDFium.' }
    $dll = Join-Path $unpacked 'bin\pdfium.dll'
    if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ine $target.dll_sha256) {
        throw 'PDFium DLL SHA-256 does not match the pinned runtime.'
    }
    $arguments = Get-Content -LiteralPath (Join-Path $unpacked 'args.gn') -Raw
    foreach ($required in @('pdf_enable_v8 = false', 'pdf_enable_xfa = false', 'is_debug = false')) {
        if (-not $arguments.Contains($required)) { throw "Unexpected PDFium build: $required" }
    }
    $payload = Join-Path $staging 'payload'
    [IO.Directory]::CreateDirectory($payload) | Out-Null
    foreach ($name in @('LICENSE', 'VERSION', 'args.gn', 'licenses')) {
        Copy-Item -LiteralPath (Join-Path $unpacked $name) -Destination $payload -Recurse
    }
    Copy-Item -LiteralPath $dll -Destination (Join-Path $payload 'pdfium.dll')
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $payload 'RUNTIME.json')
    [IO.File]::WriteAllText((Join-Path $payload 'NOTICE.txt'),
        "PDFium runtime $($manifest.version), built by bblanchon/pdfium-binaries.`r`n$($manifest.source)`r`nPDFium and all bundled third-party notices are in licenses/.`r`nNo V8 JavaScript or XFA runtime is included.`r`n",
        [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $destination) {
        # A repeated preparation is read-only. Replacing a different pinned
        # component must be an explicit future change to the distribution.
        foreach ($file in Get-ChildItem -LiteralPath $payload -Recurse -File) {
            $relative = $file.FullName.Substring($payload.Length + 1)
            $existing = Join-Path $destination $relative
            if (-not (Test-Path -LiteralPath $existing -PathType Leaf) -or
                (Get-FileHash -LiteralPath $existing).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) {
                throw "Existing PDFium runtime differs: $existing"
            }
        }
    } else {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-Item -LiteralPath $payload -Destination $destination -Recurse
    }
    Write-Output "PDFium $($manifest.version) prepared for $Platform with its licences: $destination"
} finally {
    $resolved = [IO.Path]::GetFullPath($staging)
    $prefix = $temporaryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFileName($resolved).StartsWith('homelibru-pdfium-')) {
        throw "Refusing to clean unexpected staging: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
