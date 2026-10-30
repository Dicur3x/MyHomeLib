[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$identity = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Installer/Release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($identity.format -ne 1 -or $identity.version -cnotmatch '^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$') {
    throw 'Invalid release identity.'
}
$parts = @($Matches[1], $Matches[2], $Matches[3], $Matches[4])
foreach ($part in $parts) { if ([int]$part -gt 65535) { throw 'Release version exceeds the Windows version range.' } }
if ([int]$parts[0] -lt 3 -or [int]$parts[3] -eq 0) { throw 'A 3.x beta or final identity is required.' }
$base = $parts[0..2] -join '.'
$display = $parts[0..1] -join '.'
if ([int]$parts[2] -ne 0) { $display += '.' + $parts[2] }
$tag = $base
if ([int]$parts[3] -lt 65535) {
    $tag += '_pre1.' + $parts[3]
    $display += ' beta ' + $parts[3]
} elseif ([int]$parts[2] -eq 0) { $display += ' release' }
if ($identity.release -cne $tag -or $identity.display_version -cne $display) {
    throw 'Transport, numeric and display versions disagree.'
}
$source = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Program/Units/unit_ProgramUpdates.pas') -Raw -Encoding UTF8
foreach ($pair in @(@('PROGRAM_RELEASE_VERSION', $tag), @('PROGRAM_FILE_VERSION', $identity.version))) {
    $pattern = '\b' + $pair[0] + "\s*=\s*'([^']+)';"
    if ($source -notmatch $pattern -or $Matches[1] -cne $pair[1]) {
        throw ('Native release constant disagrees: ' + $pair[0])
    }
}
$expected = @{VerInfo_MajorVer=$parts[0]; VerInfo_MinorVer=$parts[1]; VerInfo_Release=$parts[2]; VerInfo_Build=$parts[3]}
foreach ($project in @('Program/MyhomeLib.dproj', 'Utils/HomeLibReader/HomeLibReader.dproj',
    'Utils/HomeLibRuUpdater/HomeLibRuUpdater.dproj', 'Utils/MHLMcpServer/MHLMcpServer.dproj')) {
    [xml]$xml = Get-Content -LiteralPath (Join-Path $repositoryRoot $project) -Raw -Encoding UTF8
    foreach ($name in $expected.Keys) {
        $nodes = @($xml.SelectNodes("//*[local-name()='$name']"))
        if ($nodes.Count -eq 0) { throw "Missing numeric version property in $project : $name" }
        foreach ($node in $nodes) {
            if ($node.InnerText -cne $expected[$name]) { throw "Conflicting version override in $project : $name" }
        }
    }
    foreach ($keys in $xml.SelectNodes("//*[local-name()='VerInfo_Keys']")) {
        $values = @{}
        foreach ($entry in $keys.InnerText.Split(';')) {
            $pair = $entry.Split('=', 2)
            if ($pair.Count -eq 2) { $values[$pair[0]] = $pair[1] }
        }
        if ($values.FileVersion -cne $identity.version -or $values.ProductVersion -cne $tag) {
            throw "Conflicting string version in $project"
        }
    }
}
$feed = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Installer/Components.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$own = @('HomeLibReader','MHLMcpServer','BookProcessing','ImageProcessing','Kindle','LegacyBooks','LegacyOffice','XPS')
foreach ($component in $own) {
    foreach ($platform in @('Win32','Win64')) {
        $rows = @($feed.components | Where-Object { $_.id -ceq $component -and $_.platform -ceq $platform })
        if ($rows.Count -ne 1 -or $rows[0].version -cne $identity.version) {
            throw "First-party package version disagrees: $component / $platform"
        }
    }
}
Write-Host "Verified release source: $display / $tag / $($identity.version)"
