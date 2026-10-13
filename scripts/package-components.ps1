[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]{1,80}$')][string]$Release,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$feedPath=Join-Path $OutputDirectory 'HomeLibRu.components.json'
if(Test-Path -LiteralPath $feedPath){throw 'Component feed already exists; choose a new output directory'}
$descriptorPath=Join-Path $repositoryRoot 'Installer\Components.json'
$descriptor=Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json
$componentIDs=@('SQLite','AlReader','SumatraPDF','DjVuLibre','7-Zip','DocSharp')
Add-Type -AssemblyName System.IO.Compression.FileSystem
function NormalizedVersion([string]$Version) {
    if($Version -notmatch '^\d+\.\d+(?:\.\d+){0,2}$'){throw 'Invalid component version'}
    $parts=@($Version.Split('.')|ForEach-Object {[int]$_})
    while($parts.Count -lt 4){$parts+=0}
    $parts -join '.'
}
foreach($targetPlatform in @('Win32','Win64')) {
    foreach($componentID in $componentIDs) {
        $metadata=@($descriptor.components|Where-Object {$_.id -eq $componentID -and $_.platform -eq $targetPlatform})
        if($metadata.Count -ne 1){throw "Missing or repeated metadata: $componentID $targetPlatform"}
        & (Join-Path $PSScriptRoot 'package-component.ps1') -Platform $targetPlatform -Component $componentID `
            -Release $Release -OutputDirectory $OutputDirectory | Out-Host
        $archivePath=Join-Path $OutputDirectory ('HomeLibRu-'+$componentID+'-'+$targetPlatform+'.zip')
        $archive=[IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $reader=[IO.StreamReader]::new($archive.GetEntry('HomeLibRu.update.json').Open())
            try {$manifest=$reader.ReadToEnd()|ConvertFrom-Json} finally {$reader.Dispose()}
            if((NormalizedVersion $manifest.version) -ne (NormalizedVersion $metadata[0].version)) {
                throw "Runtime version and feed disagree: $componentID $targetPlatform"
            }
        } finally {$archive.Dispose()}
    }
}
# A feed is advertised only after every architecture has its complete package.
$temporaryFeed=$feedPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
[IO.File]::WriteAllText($temporaryFeed,([IO.File]::ReadAllText($descriptorPath)),[Text.UTF8Encoding]::new($false))
[IO.File]::Move($temporaryFeed,$feedPath)
Get-ChildItem -LiteralPath $OutputDirectory -File | Where-Object {$_.Name -like 'HomeLibRu-*.zip' -or $_.Name -eq 'HomeLibRu.components.json'} |
    ForEach-Object {Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256}
