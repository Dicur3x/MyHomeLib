[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Win32','Win64')][string]$Platform)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path -Parent $PSScriptRoot
$framework=Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319'
$wpf=Join-Path $framework 'WPF'
$bin=if($Platform -eq 'Win64'){'Bin64'}else{'Bin'}
$architecture=if($Platform -eq 'Win64'){'x64'}else{'x86'}
$source=Join-Path $repository 'Utils/HomeLibXps/HomeLibXps.cs'
$runtime=Join-Path $repository "Program/Out/$bin/tools/xps"
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$target=Join-Path $runtime 'HomeLibXps.exe'
$references=@('WindowsBase.dll','PresentationCore.dll','PresentationFramework.dll','ReachFramework.dll') | ForEach-Object { '/reference:'+(Join-Path $wpf $_) }
& (Join-Path $framework 'csc.exe') /nologo /target:exe /optimize+ "/platform:$architecture" "/out:$target" /reference:System.Xaml.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll @references $source
if($LASTEXITCODE -ne 0){throw 'XPS helper compilation failed.'}
$manifest=[ordered]@{version=1;platform=$Platform;source_sha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant();renderer='Windows XPS/.NET Framework 4.5+'}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'RUNTIME.json') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination (Join-Path $runtime 'HomeLibXps-MIT.txt') -Force
& $target --version
if($LASTEXITCODE -ne 0){throw 'XPS helper startup failed.'}
