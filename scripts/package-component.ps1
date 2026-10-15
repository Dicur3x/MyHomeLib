[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Win32','Win64')][string]$Platform,
    [Parameter(Mandatory=$true)][ValidateSet('SQLite','AlReader','SumatraPDF','DjVuLibre','7-Zip','DocSharp')][string]$Component,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]{1,80}$')][string]$Release,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$TestFixture
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $TestFixture) { throw 'Separate component release archives are retired. This builder is only for isolated legacy installer tests; pass -TestFixture explicitly.' }
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$runtime=Join-Path $repositoryRoot $(if($Platform -eq 'Win32'){'Program\Out\Bin'}else{'Program\Out\Bin64'})
$files=@{
    SQLite=@('sqlite3.dll')
    AlReader=@('Readers/AlReader/AlReader2.exe','Readers/AlReader/$savevtut.ini','Readers/AlReader/AlDictionary.aldict',
        'Readers/AlReader/UNRAR.DLL','Readers/AlReader/readme.txt','Readers/AlReader/book_new0.m2.bmp',
        'Readers/AlReader/book_new1.m2.bmp','Readers/AlReader/book_white.m2.bmp','Readers/AlReader/DefaultTexture.BMP',
        'Readers/AlReader/DefaultTextureBlack.BMP','Readers/AlReader/English_US_hyphen_(Alan).pdb',
        'Readers/AlReader/fon_white.m1.bmp','Readers/AlReader/Russian_1251_hyphen_(Alan).pdb',
        'Readers/AlReader/Russian_EnUS_hyphen_(Alan).pdb','Readers/AlReader/Russian_hyphen_(Alan).pdb')
    SumatraPDF=@('Readers/SumatraPDF/SumatraPDF.exe','Readers/SumatraPDF/AUTHORS.txt',
        'Readers/SumatraPDF/COPYING.BSD.txt','Readers/SumatraPDF/COPYING.txt')
    '7-Zip'=@('tools/7zip/7z.exe','tools/7zip/7z.dll','tools/7zip/License.txt')
    DocSharp=@('tools/doc/DocSharp.Binary.Doc.dll','tools/doc/DocSharp.Binary.Common.dll','tools/doc/DocSharp.Binary.Ppt.dll','tools/doc/DocSharp.Binary.Xls.dll','tools/doc/HomeLibDoc.exe',
        'tools/doc/DOC_RUNTIME.json','tools/doc/DocSharp-MIT.txt','tools/doc/b2xtranslator-BSD-3-Clause.txt','tools/doc/HomeLibDoc-MIT.txt')
    DjVuLibre=@('tools/djvu/djvused.exe','tools/djvu/ddjvu.exe','tools/djvu/libdjvulibre.dll','tools/djvu/libjpeg.dll',
        'tools/djvu/libtiff.dll','tools/djvu/libz.dll','tools/djvu/COPYING.txt','tools/djvu/COPYRIGHT',
        'tools/djvu/IJG-README.txt','tools/djvu/LIBTIFF-COPYRIGHT.txt','tools/djvu/ZLIB-README.txt','tools/djvu/RUNTIME.json')
}
if($Component -eq 'DjVuLibre') {
    $descriptor=Get-Content -LiteralPath (Join-Path $runtime 'tools/djvu/RUNTIME.json') -Raw | ConvertFrom-Json
    $version=$descriptor.djvu.version
    $files.DjVuLibre+=('tools/djvu/djvulibre-'+$version+'.tar.gz')
} else {
    $info=(Get-Item -LiteralPath (Join-Path $runtime $files[$Component][0])).VersionInfo
    $version=@($info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart)-join '.'
}
if($version -notmatch '^\d+\.\d+(?:\.\d+){0,2}$'){throw 'Component has no valid version'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$destination=Join-Path $OutputDirectory ('HomeLibRu-'+$Component+'-'+$Platform+'.zip')
if(Test-Path -LiteralPath $destination){throw "Archive already exists: $destination"}
$stage=Join-Path $OutputDirectory ('HomeLibRu-component-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage)|Out-Null
[IO.File]::WriteAllText((Join-Path $stage '.component-stage'),'HomeLib Ru component staging v1')
try {
    $payload=Join-Path $stage 'payload'
    [IO.Directory]::CreateDirectory($payload)|Out-Null
    $entries=@(foreach($name in $files[$Component]) {
        $source=Join-Path $runtime $name
        $target=Join-Path $payload $name
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null
        Copy-Item -LiteralPath $source -Destination $target
        [ordered]@{path=$name;size=(Get-Item -LiteralPath $source).Length;
            sha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $manifest=[ordered]@{format=1;release=$Release;platform=$Platform;component=$Component;version=$version;files=$entries}
    [IO.File]::WriteAllText((Join-Path $payload 'HomeLibRu.update.json'),
        ($manifest|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryArchive=Join-Path $stage 'component.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload,$temporaryArchive,[IO.Compression.CompressionLevel]::Optimal,$false)
    [IO.File]::Move($temporaryArchive,$destination)
    Get-FileHash -LiteralPath $destination -Algorithm SHA256
} finally {
    $absoluteStage=[IO.Path]::GetFullPath($stage)
    $boundary=$OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if($absoluteStage.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $absoluteStage) -like 'HomeLibRu-component-*' -and
        [IO.File]::ReadAllText((Join-Path $absoluteStage '.component-stage')) -eq 'HomeLib Ru component staging v1') {
        Remove-Item -LiteralPath $absoluteStage -Recurse -Force
    } else {throw 'Unexpected component staging path; left untouched'}
}
