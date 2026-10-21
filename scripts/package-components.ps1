[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]{1,80}$')][string]$Release,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$feed=Join-Path $OutputDirectory 'HomeLibRu.components.json'
if (Test-Path -LiteralPath $feed) { throw "Component feed already exists: $feed" }
# Both architectures are verified before publishing any package description.
foreach ($platform in @('Win32','Win64')) {
    & (Join-Path $PSScriptRoot 'prepare-runtime.ps1') -Platform $platform | Out-Host
}
foreach ($platform in @('Win32','Win64')) {
    foreach ($component in @('AlReader','SumatraPDF','DjVuLibre','DocSharp')) {
        & (Join-Path $PSScriptRoot 'package-component.ps1') -Platform $platform -Component $component -Release $Release -OutputDirectory $OutputDirectory | Out-Host
    }
}
# Version/history metadata is descriptive. Clients accept an archive's exact
# URL, SHA-256 and byte size only from the corresponding live GitHub asset.
$descriptor=Get-Content -LiteralPath (Join-Path $repositoryRoot 'Installer/Components.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($platform in @('Win32','Win64')) {
    foreach ($component in @('AlReader','SumatraPDF','DjVuLibre','DocSharp')) {
        $archive=[IO.Compression.ZipFile]::OpenRead((Join-Path $OutputDirectory ("HomeLibRu-$component-$platform.zip")))
        try {
            $reader=[IO.StreamReader]::new($archive.GetEntry('HomeLibRu.update.json').Open())
            try { $identity=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            if ($identity.component -ne $component -or $identity.platform -ne $platform -or $identity.release -ne $Release) {
                throw 'Component package identity does not match its feed entry'
            }
            $entry=@($descriptor.components | Where-Object { $_.id -eq $component -and $_.platform -eq $platform })
            if ($entry.Count -ne 1) { throw 'Missing or ambiguous optional feed entry' }
            # The installer validates exact manifest/binary versions. Keep the
            # descriptive feed in sync with the bytes just packaged.
            $entry[0].version=$identity.version
        } finally { $archive.Dispose() }
    }
}
[IO.File]::WriteAllText($feed,($descriptor|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $feed
