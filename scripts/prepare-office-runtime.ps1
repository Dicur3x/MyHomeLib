[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Win32','Win64')][string]$Platform,
    [switch]$Copy,
    [string]$CacheRoot = 'G:\HomeLibRu-build-cache\office-portable-v1'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$bin = if ($Platform -eq 'Win64') {'Bin64'} else {'Bin'}
$runtime = Join-Path $repository "Program\Out\$bin\tools"
$arguments = @('-I','-B','-X','utf8',(Join-Path $PSScriptRoot 'prepare-office-runtime.py'),
    '--runtime',(Join-Path $runtime 'office'),'--cache',$CacheRoot,
    '--seven',(Join-Path $runtime '7zip\7z.exe'))
if ($Copy) {$arguments += '--copy'}
& (Join-Path $runtime 'kindle\python\python.exe') @arguments
if ($LASTEXITCODE -ne 0) {throw 'Portable office runtime verification failed.'}
