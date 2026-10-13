[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]{1,80}$')][string]$Release,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
# Component releases are obtained from their authors, not mirrored as our assets.
throw 'Separate component release archives are retired. Use package-release.ps1 for the complete program; component updates use official author resources.'
