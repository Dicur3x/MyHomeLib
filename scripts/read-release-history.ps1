[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$NotesDirectory,
    [Parameter(Mandatory = $true)][string]$CurrentTag,
    [Parameter(Mandatory = $true)][string]$CurrentDisplay,
    [ValidateRange(1, 64)][int]$Limit = 9
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-ReleaseTag([string]$Tag) {
    if ($Tag -cnotmatch '^([0-9]+)\.([0-9]+)\.([0-9]+)(?:_pre([0-9]+)(?:\.([0-9]+))?)?$') {
        throw "Unsupported release-history tag: $Tag"
    }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
    $stage = [int]::MaxValue; $number = 0
    if ($Matches.ContainsKey(4)) {
        $stage = [int]$Matches[4]
        if ($Matches.ContainsKey(5)) { $number = [int]$Matches[5] }
    }
    $display = "$major.$minor"
    if ($patch -ne 0) { $display += ".$patch" }
    if ($stage -eq 1 -and $number -gt 0 -and $number -lt 65535) { $display += " beta $number" }
    elseif ($stage -eq [int]::MaxValue -and $patch -eq 0) { $display += ' release' }
    elseif ($stage -ne [int]::MaxValue) { $display = $Tag }
    [pscustomobject]@{ Tag=$Tag; Base=[version]"$major.$minor.$patch"; Stage=$stage; Number=$number; Display=$display }
}

$current = Convert-ReleaseTag $CurrentTag
if ($current.Display -cne $CurrentDisplay) { throw 'Release-history display identity disagrees with its tag.' }
$currentPath = Join-Path $NotesDirectory ("RELEASE_NOTES_$CurrentTag.md")
if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { throw "Current release notes are missing: $currentPath" }
$entries = @(foreach ($file in Get-ChildItem -LiteralPath $NotesDirectory -Filter 'RELEASE_NOTES_*.md' -File) {
    $entry = Convert-ReleaseTag $file.BaseName.Substring('RELEASE_NOTES_'.Length)
    # Do not ship notes for future, unpublished releases from the working tree.
    if ($entry.Base -gt $current.Base -or
        ($entry.Base -eq $current.Base -and $entry.Stage -gt $current.Stage) -or
        ($entry.Base -eq $current.Base -and $entry.Stage -eq $current.Stage -and $entry.Number -gt $current.Number)) { continue }
    $entry | Add-Member -NotePropertyName Path -NotePropertyValue $file.FullName -PassThru
})
foreach ($entry in $entries | Sort-Object Base, Stage, Number -Descending | Select-Object -First $Limit) {
    $notes = Get-Content -LiteralPath $entry.Path -Raw -Encoding UTF8
    if ($entry.Base.Major -ge 3) {
        $heading = '# HomeLibre ' + $entry.Display
        if (($notes -split '\r?\n', 2)[0] -cne $heading) { throw "Release notes heading disagrees with its tag: $($entry.Path)" }
    } else {
        if ($notes -notmatch '\A# HomeLib Ru[^\r\n]*') { throw "Unsupported legacy release notes heading: $($entry.Path)" }
        # Old documents sometimes use a build number; the history viewer needs the full tag.
        $notes = [regex]::Replace($notes, '\A# HomeLib Ru[^\r\n]*', ('# HomeLib Ru ' + $entry.Tag))
    }
    $notes
}
