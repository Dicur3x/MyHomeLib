[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Win32','Win64')][string]$Platform,
    [switch]$Copy,
    [string]$CacheRoot = 'G:\HomeLibRu-build-cache\docsharp-0.21.0'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$pinPath = Join-Path $repository 'Installer\DOC_RUNTIME.json'
$pin = Get-Content -LiteralPath $pinPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bin = if ($Platform -eq 'Win64') {'Bin64'} else {'Bin'}
$runtime = Join-Path $repository "Program\Out\$bin\tools\doc"
function Assert-Hash([string]$Path,[string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Expected) {
        throw "DOC component differs from its release pin: $Path"
    }
}
Assert-Hash (Join-Path $repository 'Utils\HomeLibDoc\HomeLibDoc.cs') $pin.source_sha256
if ($Copy) {
    $cachePath = [System.IO.Path]::GetFullPath($CacheRoot)
    if ($cachePath.StartsWith('E:',[System.StringComparison]::OrdinalIgnoreCase)) {throw 'Drive E is prohibited.'}
    [System.IO.Directory]::CreateDirectory($cachePath) | Out-Null
    [System.IO.Directory]::CreateDirectory($runtime) | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($package in $pin.packages) {
        $archivePath = Join-Path $cachePath ($package.id+'.'+$package.version+'.nupkg')
        if (-not (Test-Path -LiteralPath $archivePath)) {
            Invoke-WebRequest -Uri $package.url -OutFile $archivePath
        }
        Assert-Hash $archivePath $package.package_sha256
        $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $entry = $archive.GetEntry($package.entry)
            if ($null -eq $entry -or $entry.Length -ne $package.bytes) {throw 'Invalid pinned DOC package entry.'}
            $destination = Join-Path $runtime $package.file
            # Extract only the explicitly pinned filename, never archive paths.
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$destination,$true)
        } finally {$archive.Dispose()}
        Assert-Hash $destination $package.sha256
    }
    $helper = Join-Path $repository 'Utils\HomeLibDoc\Out\HomeLibDoc.exe'
    Assert-Hash $helper $pin.helper_sha256
    Copy-Item -LiteralPath $helper -Destination (Join-Path $runtime 'HomeLibDoc.exe') -Force
    Copy-Item -LiteralPath $pinPath -Destination (Join-Path $runtime 'DOC_RUNTIME.json') -Force
    foreach ($license in @('DocSharp-MIT.txt','b2xtranslator-BSD-3-Clause.txt')) {
        Copy-Item -LiteralPath (Join-Path $repository "Installer\DocReaderLicenses\$license") -Destination (Join-Path $runtime $license) -Force
    }
    Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination (Join-Path $runtime 'HomeLibDoc-MIT.txt') -Force
}
Assert-Hash (Join-Path $runtime 'HomeLibDoc.exe') $pin.helper_sha256
foreach ($package in $pin.packages) {Assert-Hash (Join-Path $runtime $package.file) $package.sha256}
Assert-Hash (Join-Path $runtime 'DOC_RUNTIME.json') (Get-FileHash -LiteralPath $pinPath).Hash
foreach ($license in @('DocSharp-MIT.txt','b2xtranslator-BSD-3-Clause.txt')) {
    Assert-Hash (Join-Path $runtime $license) (Get-FileHash -LiteralPath (Join-Path $repository "Installer\DocReaderLicenses\$license")).Hash
}
Assert-Hash (Join-Path $runtime 'HomeLibDoc-MIT.txt') (Get-FileHash -LiteralPath (Join-Path $repository 'LICENSE')).Hash
Write-Output "Pinned bundled DOC reader verified ($Platform; AnyCPU helper)."
