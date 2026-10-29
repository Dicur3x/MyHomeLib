[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$Release,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][ValidateSet('Win32', 'Win64')][string]$Platform
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('HomeLibRu.exe', 'HomeLibRuUpdater.exe')) {
    $file = Join-Path $RuntimeDirectory $name
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($file)
    $numeric = '{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart,
        $info.FileBuildPart, $info.FilePrivatePart
    if ($info.ProductVersion -cne $Release -or $numeric -cne $Version) {
        throw "Release identity mismatch in ${name}: expected $Release / $Version, found $($info.ProductVersion) / $numeric. Rebuild BOTH application and updater."
    }
    if ($info.OriginalFilename -cne $name -or
        $info.InternalName -cne [IO.Path]::GetFileNameWithoutExtension($name) -or
        $info.ProductName -cne 'HomeLibre') {
        throw "Incorrect release executable identity: $file"
    }
    $stream = [IO.File]::OpenRead($file)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid EXE: $file" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw "Invalid PE header: $file" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $file" }
        $machine = $reader.ReadUInt16()
        $expected = if ($Platform -eq 'Win64') { 0x8664 } else { 0x14c }
        if ($machine -ne $expected) { throw "Incorrect $Platform release executable: $file" }
    }
    finally { $reader.Dispose() }
}
Write-Host "Verified application AND updater: $Release / $Version / $Platform"
