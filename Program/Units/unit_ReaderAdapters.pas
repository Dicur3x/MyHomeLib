unit unit_ReaderAdapters;

interface

type
  TReaderAdapterPackage = record
    ID, Name, SHA256: string;
    Size: Int64;
  end;

function ReaderAdapterFiles(const ID: string): TArray<string>;
function ReaderAdapterPackage(const ID: string; out Package: TReaderAdapterPackage): Boolean;
function ReaderAdapterRequired(const AppPath, ID: string): Boolean;
function ReaderAdapterURL(const Package: TReaderAdapterPackage): string;

implementation

uses System.SysUtils, System.IOUtils;

{$I ReaderAdapterPackages.inc}

function ReaderAdapterFiles(const ID: string): TArray<string>;
begin
  Result:=nil;
  if ID='DocSharp' then Exit(TArray<string>.Create('tools/doc/HomeLibDoc.exe',
    'tools/doc/HomeLibDoc-MIT.txt','tools/doc/DocSharp-MIT.txt','tools/doc/b2xtranslator-BSD-3-Clause.txt'));
  if ID='DjVuLibre' then Result:=TArray<string>.Create('tools/djvu/HomeLibDjvu.exe',
    'tools/djvu/COPYING.txt','tools/djvu/COPYRIGHT','tools/djvu/IJG-README.txt',
    'tools/djvu/LIBTIFF-COPYRIGHT.txt','tools/djvu/ZLIB-README.txt',
    'tools/djvu/HomeLibDjvu-source/HomeLibDjvu.dpr','tools/djvu/HomeLibDjvu-source/HomeLibDjvu.dproj',
    'tools/djvu/HomeLibDjvu-source/LICENSE','tools/djvu/HomeLibDjvu-source/README.md',
    'tools/djvu/HomeLibDjvu-source/unit_DjvuProtocol.pas');
end;

function ReaderAdapterPackage(const ID: string; out Package: TReaderAdapterPackage): Boolean;
begin
  Package:=Default(TReaderAdapterPackage);
  for var Item in READER_ADAPTER_PACKAGES do
    if Item.ID=ID then begin Package:=Item; Exit(True); end;
  Result:=False;
end;

function ReaderAdapterRequired(const AppPath, ID: string): Boolean;
begin
  Result:=False;
  for var Name in ReaderAdapterFiles(ID) do
    if not FileExists(TPath.Combine(AppPath,Name)) then Exit(True);
end;

function ReaderAdapterURL(const Package: TReaderAdapterPackage): string;
begin
  Result:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+
    'optional-alreader-2.5.1009.25/'+Package.Name;
end;

end.
