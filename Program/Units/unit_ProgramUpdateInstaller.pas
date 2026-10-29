unit unit_ProgramUpdateInstaller;

// The updater manages only distribution files. User data is never an input
// to a recursive copy/delete operation. The journal is written before changes.
interface

uses System.SysUtils, System.Classes, System.JSON;

const
  UPDATE_MANIFEST = 'HomeLibRu.update.json';
  UPDATE_MAX_ARCHIVE = 256 * 1024 * 1024;

type
  TUpdateFile = record
    Name, SHA256: string;
    Size: Int64;
    KeepExisting, Skip: Boolean;
  end;
  TUpdateFiles = TArray<TUpdateFile>;
  TUpdateProgress = reference to procedure(const Text: string; Position, Total: Integer);

function UpdateSHA256(const FileName: string): string;
function IsUpdateSHA256(const Value: string): Boolean;
function IsProgramUpdateApplicationName(const Value: string): Boolean;
function ReadProgramUpdateApplication(const Request: TJSONObject): string;
function SafeUpdateName(const Name: string): Boolean;
procedure AssertUpdatePath(const Path: string);
function PrepareProgramUpdate(const Archive, SHA256, Tag, Platform, Job: string;
  VerifyIdentity: Boolean = True; const ComponentID: string = '';
  const ComponentVersion: string = ''): TUpdateFiles;
function UpdateFileVersion(const FileName: string): string;
function CompareComponentVersions(const Left, Right: string; out Comparison: Integer): Boolean;
function ComponentFileName(const ID: string): string;
function InstalledComponentVersion(const AppPath, ID: string): string;
function ComponentNeedsRepair(const AppPath, ID: string): Boolean;
function PreparedProgramUpdateHelper(const Job, Tag, Platform, ExpectedSHA256: string): string;
function SafeComponentFile(const ID, Name: string): Boolean;
procedure InstallProgramUpdate(const Job, Target: string;
  const Progress: TUpdateProgress = nil; FailAfter: Integer = -1);
procedure RollbackProgramUpdate(const Job, Target: string);
procedure CleanProgramUpdate(const Job: string);
function ProgramUpdatePlatform: string;
procedure VerifyPreparedProgramUpdate(const Job, Tag, Platform: string);
procedure PrepareOfficialComponent(const Archive, Job, ID, Version, Platform: string;
  const SecondaryArchive: string = ''; const AppPath: string = ''; const AdditionalArchives: TArray<string> = nil;
  const AdapterPath: string = '');
function ExtractReaderAdapter(const Archive, Job, ID: string): string;
procedure MergePreparedReaderAdapter(const Job, ID, AdapterPath: string);
function IsOfficialComponentURL(const ID, Version, URL, Platform: string; Secondary: Boolean): Boolean;
function CombinePreparedProgramUpdates(const Jobs: TArray<string>;
  const Tag, Platform, Job: string): string;
function PreparedComponentsNewer(const Job, AppPath: string): Boolean;
function PreparedIncludesComponent(const Job, Component: string): Boolean;

implementation

uses System.IOUtils, System.Hash, System.Zip,
  System.Generics.Collections, Winapi.Windows, System.RegularExpressions, unit_UpdateAuthenticity, unit_MHLExternalTools,
  unit_IBKRuntime, unit_ReaderAdapters, unit_ZstdRuntime, unit_FormatComponents;

function IsProgramUpdateApplicationName(const Value: string): Boolean;
begin
  // Windows filenames are case insensitive. Keep the two application names
  // explicit: accepting an arbitrary renamed EXE could restart an old binary.
  Result:=SameText(Value,'HomeLibRu.exe') or SameText(Value,'HomeLibReader.exe');
end;

function ReadProgramUpdateApplication(const Request: TJSONObject): string;
var Value: TJSONValue;
begin
  Value:=Request.GetValue('application');
  // Releases before the standalone Reader supplied no application field.
  // TryGetValue has an out parameter and clears a preassigned default.
  if Value=nil then Result:='HomeLibRu.exe'
  else if Value is TJSONString then Result:=Value.Value
  else raise Exception.Create('Повреждено имя приложения для обновления.');
  if not IsProgramUpdateApplicationName(Result) then
    raise Exception.Create('Недопустимое приложение для обновления.'+sLineBreak+'Имя файла: '+Result);
end;

function ComponentFileName(const ID: string): string;
begin
  if IsFormatComponent(ID) then Exit(FormatComponentFile(ID));
  Result := '';
  if ID = 'SQLite' then Result := 'sqlite3.dll';
  if ID = 'HomeLibReader' then Result := 'HomeLibReader.exe';
  if ID = 'MHLMcpServer' then Result := 'MHLMcpServer.exe';
  if ID = 'Zstandard' then Result := 'libzstd.dll';
  if ID = 'PDFium' then Result := 'tools/pdfium/pdfium.dll';
  if ID = 'BookConverter' then Result := 'tools/kindle/python/python.exe';
  if ID = 'IBK' then Result := 'tools/ibk/Rus.key';
  if ID = 'AlReader' then Result := 'Readers/AlReader/AlReader2.exe';
  if ID = 'SumatraPDF' then Result := 'Readers/SumatraPDF/SumatraPDF.exe';
  if ID = 'DjVuLibre' then Result := 'tools/djvu/djvused.exe';
  if ID = '7-Zip' then Result := 'tools/7zip/7z.exe';
  if ID = 'DocSharp' then Result := 'tools/doc/DocSharp.Binary.Doc.dll';
  if ID = 'JPEG XL' then Result := 'tools/jpeg-xl/djxl.exe';
  if ID = 'WebP' then Result := 'tools/webp/libwebp.dll';
end;

function SafeComponentFile(const ID, Name: string): Boolean;
var Base: string;
begin
  if IsFormatComponent(ID) then Exit(SafeUpdateName(Name) and SafeFormatComponentFile(ID,Name));
  if ID='Zstandard' then Exit((Name='libzstd.dll') or
    (Name='tools/zstd/RUNTIME.json') or (Name='tools/zstd/LICENSE'));
  if ID='MHLMcpServer' then Exit((Name='MHLMcpServer.exe') or
    (Name='MHLMcpServer-LICENSE.txt') or (Name='MHLMcpServer-README.txt'));
  if (ID='DocSharp') or (ID='DjVuLibre') then
    for var AdapterName in ReaderAdapterFiles(ID) do if Name=AdapterName then Exit(True);
  if ID='IBK' then
  begin
    for var FileName in IBK_FILES do if Name='tools/ibk/'+FileName then Exit(True);
    Exit(False);
  end;
  if ID='HomeLibReader' then Exit((Name='HomeLibReader.exe') or (Name='HomeLibRuUpdater.exe') or
    (Name='HomeLibReader-LICENSE.txt') or (Name='sqlite3.dll') or (Name='libzstd.dll') or (Name='NOTICE') or
    (Name='tools/fonts/manifest.json') or
    (Name='tools/doc/HomeLibDoc.exe') or
    (Name='tools/doc/HomeLibDoc-MIT.txt') or
    (Name='tools/doc/DocSharp-MIT.txt') or
    (Name='tools/doc/b2xtranslator-BSD-3-Clause.txt') or
    (Name='tools/djvu/HomeLibDjvu.exe') or
    (Name='tools/djvu/COPYING.txt') or
    (Name='tools/djvu/COPYRIGHT') or
    (Name='tools/djvu/IJG-README.txt') or
    (Name='tools/djvu/LIBTIFF-COPYRIGHT.txt') or
    (Name='tools/djvu/ZLIB-README.txt') or
    (Name='tools/djvu/HomeLibDjvu-source/HomeLibDjvu.dpr') or
    (Name='tools/djvu/HomeLibDjvu-source/HomeLibDjvu.dproj') or
    (Name='tools/djvu/HomeLibDjvu-source/LICENSE') or
    (Name='tools/djvu/HomeLibDjvu-source/README.md') or
    (Name='tools/djvu/HomeLibDjvu-source/unit_DjvuProtocol.pas'));
  if ID='PDFium' then Exit(SafeUpdateName(Name) and Name.StartsWith('tools/pdfium/') and
    ((Name='tools/pdfium/pdfium.dll') or (Name='tools/pdfium/HomeLibPDF.exe') or
     (Name='tools/pdfium/RUNTIME.json') or (Name='tools/pdfium/WORKER_RUNTIME.json') or
     (Name='tools/pdfium/HomeLibPDF-LICENSE.txt') or (Name='tools/pdfium/LICENSE') or
     (Name='tools/pdfium/NOTICE.txt') or (Name='tools/pdfium/VERSION') or
     (Name='tools/pdfium/args.gn') or Name.StartsWith('tools/pdfium/licenses/')));
  if ID='BookConverter' then Exit(SafeUpdateName(Name) and
    (Name.StartsWith('tools/bookconvert/') or Name.StartsWith('tools/kindle/') or Name.StartsWith('tools/office/') or
     (Name='tools/xps/HomeLibXps.exe') or (Name='tools/xps/HomeLibXps-MIT.txt') or (Name='tools/xps/RUNTIME.json')));
  if ID='JPEG XL' then Exit((Name='tools/jpeg-xl/djxl.exe') or
    (Name='tools/jpeg-xl/RUNTIME.json') or
    TRegEx.IsMatch(Name,'\Atools/jpeg-xl/licenses/LICENSE\.[A-Za-z0-9._-]{1,64}\z'));
  if ID='WebP' then Exit((Name='tools/webp/libwebp.dll') or (Name='tools/webp/RUNTIME.json') or
    (Name='tools/webp/COPYING.txt') or (Name='tools/webp/PATENTS.txt') or (Name='tools/webp/AUTHORS.txt'));
  Result := SafeUpdateName(Name);
  if not Result then Exit;
  if ID = 'SQLite' then Exit(Name = 'sqlite3.dll');
  if ID='DocSharp' then Exit((Name='tools/doc/DocSharp.Binary.Doc.dll') or
    (Name='tools/doc/DocSharp.Binary.Common.dll') or (Name='tools/doc/DocSharp.Binary.Ppt.dll') or (Name='tools/doc/DocSharp.Binary.Xls.dll') or (Name='tools/doc/HomeLibDoc.exe') or
    (Name='tools/doc/DOC_RUNTIME.json') or (Name='tools/doc/DocSharp-MIT.txt') or
    (Name='tools/doc/b2xtranslator-BSD-3-Clause.txt') or (Name='tools/doc/HomeLibDoc-MIT.txt'));
  if ID='7-Zip' then Exit((Name='tools/7zip/7z.exe') or (Name='tools/7zip/7z.dll') or
    (Name='tools/7zip/License.txt') or (Name='tools/7zip/7za.exe'));
  if ID='DjVuLibre' then Exit((Name='tools/djvu/HomeLibDjvu.exe') or (Name='tools/djvu/ddjvu.exe') or (Name='tools/djvu/djvused.exe') or
    (Name='tools/djvu/libdjvulibre.dll') or (Name='tools/djvu/libjpeg.dll') or
    (Name='tools/djvu/libtiff.dll') or (Name='tools/djvu/libz.dll') or
    (Name='tools/djvu/COPYING.txt') or (Name='tools/djvu/COPYRIGHT') or
    (Name='tools/djvu/IJG-README.txt') or (Name='tools/djvu/LIBTIFF-COPYRIGHT.txt') or
    (Name='tools/djvu/ZLIB-README.txt') or (Name='tools/djvu/RUNTIME.json') or
    TRegEx.IsMatch(Name,'^tools/djvu/djvulibre-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$'));
  if ID = 'SumatraPDF' then
    Exit((Name = 'Readers/SumatraPDF/SumatraPDF.exe') or
      (Name = 'Readers/SumatraPDF/AUTHORS.txt') or
      (Name = 'Readers/SumatraPDF/COPYING.BSD.txt') or
      (Name = 'Readers/SumatraPDF/COPYING.txt'));
  if (ID <> 'AlReader') or not Name.StartsWith('Readers/AlReader/') then Exit(False);
  Base := Copy(Name, Length('Readers/AlReader/') + 1, MaxInt);
  Result := (Pos('/', Base) = 0) and
    ((Base = 'AlReader2.exe') or (Base = '$savevtut.ini') or (Base = 'AlDictionary.aldict') or
    (Base = 'UNRAR.DLL') or (Base = 'readme.txt') or (Base = 'book_new0.m2.bmp') or
    (Base = 'book_new1.m2.bmp') or (Base = 'book_white.m2.bmp') or
    (Base = 'DefaultTexture.BMP') or (Base = 'DefaultTextureBlack.BMP') or
    (Base = 'English_US_hyphen_(Alan).pdb') or (Base = 'fon_white.m1.bmp') or
    (Base = 'Russian_1251_hyphen_(Alan).pdb') or
    (Base = 'Russian_EnUS_hyphen_(Alan).pdb') or (Base = 'Russian_hyphen_(Alan).pdb'));
end;

function CompareComponentVersions(const Left, Right: string; out Comparison: Integer): Boolean;
var A, B: TArray<string>; I, X, Y: Integer; C: Char;
begin
  Comparison := 0; Result := False; A := Left.Split(['.']); B := Right.Split(['.']);
  for C in Left + Right do if not CharInSet(C, ['0'..'9', '.']) then Exit;
  if (Length(A) < 2) or (Length(A) > 4) or (Length(B) < 2) or (Length(B) > 4) then Exit;
  for I := 0 to 3 do
  begin
    X := 0; Y := 0;
    if (I < Length(A)) and (not TryStrToInt(A[I], X) or (X < 0) or (X > 65535)) then Exit;
    if (I < Length(B)) and (not TryStrToInt(B[I], Y) or (Y < 0) or (Y > 65535)) then Exit;
    if (Comparison = 0) and (X <> Y) then
      if X > Y then Comparison := 1 else Comparison := -1;
  end;
  Result := True;
end;

function UpdateFileVersion(const FileName: string): string;
var Size, Dummy: DWORD; Buffer: TBytes; Fixed: PVSFixedFileInfo; Len: UINT;
begin
  Result := ''; Size := GetFileVersionInfoSize(PChar(FileName), Dummy);
  if Size = 0 then Exit;
  SetLength(Buffer, Size);
  if GetFileVersionInfo(PChar(FileName), 0, Size, @Buffer[0]) and
     VerQueryValue(@Buffer[0], '\', Pointer(Fixed), Len) and
     (Len >= SizeOf(TVSFixedFileInfo)) and (Fixed.dwSignature = $FEEF04BD) then
    Result := Format('%d.%d.%d.%d', [HiWord(Fixed.dwFileVersionMS), LoWord(Fixed.dwFileVersionMS),
      HiWord(Fixed.dwFileVersionLS), LoWord(Fixed.dwFileVersionLS)]);
end;

function InstalledComponentVersion(const AppPath, ID: string): string;
var Root: TJSONValue; Metadata, Hashes: TJSONObject; HashValue: TJSONValue;
  FileName, MetadataFile, Version, Hash: string; Comparison: Integer;
begin
  FileName:=IncludeTrailingPathDelimiter(AppPath)+StringReplace(ComponentFileName(ID),'/',PathDelim,[rfReplaceAll]);
  Result:=UpdateFileVersion(FileName);
  if IsFormatComponent(ID) then Exit(FormatComponentVersion(AppPath,ID));
  if ID='Zstandard' then Exit(ZstdRuntimeVersion(AppPath));
  if ID='IBK' then
  begin
    if IBKRuntimeAvailable(AppPath) then Result:=IBK_VERSION else Result:='';
    Exit;
  end;
  if (ID='PDFium') or (ID='BookConverter') then
  begin
    Result:=''; Root:=nil;
    try
      try
        if ID='PDFium' then MetadataFile:=ExtractFilePath(FileName)+'RUNTIME.json'
        else MetadataFile:=IncludeTrailingPathDelimiter(AppPath)+'tools/bookconvert/COMPONENT.json';
        if not FileExists(MetadataFile) or (TFile.GetSize(MetadataFile)>65536) then Exit;
        Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(MetadataFile,TEncoding.UTF8));
        if not (Root is TJSONObject) or not Root.TryGetValue<string>('version',Version) or
          not CompareComponentVersions(Version,Version,Comparison) then Exit;
        if ID='PDFium' then
        begin
          if not Root.TryGetValue<TJSONObject>(ProgramUpdatePlatform,Metadata) or
            not Metadata.TryGetValue<string>('dll_sha256',Hash) then Exit;
        end
        else if not Root.TryGetValue<string>('pythonSha256',Hash) then Exit;
        if not FileExists(FileName) or not IsUpdateSHA256(Hash) or not SameText(UpdateSHA256(FileName),Hash) then Exit;
        if ID='BookConverter' then
        begin
          if not Root.TryGetValue<string>('converterSha256',Hash) then Exit;
          MetadataFile:=IncludeTrailingPathDelimiter(AppPath)+'tools/bookconvert/convert_book.py';
          if not FileExists(MetadataFile) or not IsUpdateSHA256(Hash) or not SameText(UpdateSHA256(MetadataFile),Hash) then Exit;
        end;
        Result:=Version;
      except Result:=''; end;
    finally Root.Free; end;
    Exit;
  end;
  if (ID='JPEG XL') or (ID='WebP') then
  begin
    Result:=''; if not FileExists(FileName) then Exit;
    Root:=nil;
    try
      try
        MetadataFile:=ExtractFilePath(FileName)+'RUNTIME.json';
        if FileExists(MetadataFile) and (TFile.GetSize(MetadataFile)<=65536) then
        begin
          Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(MetadataFile,TEncoding.UTF8));
          if (Root is TJSONObject) and Root.TryGetValue<string>('component',Hash) and (Hash=ID) and
            Root.TryGetValue<TJSONObject>('codec',Metadata) and Metadata.TryGetValue<string>('version',Version) and
            CompareComponentVersions(Version,Version,Comparison) and Metadata.TryGetValue<TJSONObject>('files',Hashes) then
          begin
            HashValue:=Hashes.GetValue(ExtractFileName(FileName));
            if (HashValue is TJSONString) and IsUpdateSHA256(HashValue.Value) and
              SameText(UpdateSHA256(FileName),HashValue.Value) then Exit(Version);
          end;
        end;
        // Older full distributions did not carry a codec descriptor. Recognize
        // only the exact previously shipped binaries, without starting an EXE
        // or loading a DLL merely to populate the update window.
        Hash:=UpdateSHA256(FileName);
{$IFDEF WIN64}
        if (ID='JPEG XL') and SameText(Hash,'6970ce73de51e046b39bd5f28fc7bc5da64e9f6505c11194319f43d8849d2bf4') then Result:='0.12.0';
        if (ID='WebP') and SameText(Hash,'21b5076aa61ba7c049c7da37656b3e743f0207b6f0fec64e98589025a044b6bf') then Result:='1.6.0';
{$ELSE}
        if (ID='JPEG XL') and SameText(Hash,'ce031db2a11536654ae2a7b08920783b9a1a3813f74c45e18df89c39723cc172') then Result:='0.12.0';
        if (ID='WebP') and SameText(Hash,'afbf76daf9ee8a4faf9eee375694587f49aece0cb03b444341a9e9085a4a17d7') then Result:='1.6.0';
{$ENDIF}
      except Result:=''; end;
    finally Root.Free; end;
    Exit;
  end;
  if ID='DocSharp' then
  begin
    if not FileExists(ExtractFilePath(FileName)+'HomeLibDoc.exe') or
      not SameText(Result,UpdateFileVersion(ExtractFilePath(FileName)+'DocSharp.Binary.Common.dll')) then Result:='';
    if FileExists(ExtractFilePath(FileName)+'DocSharp.Binary.Ppt.dll') or
      FileExists(ExtractFilePath(FileName)+'DocSharp.Binary.Xls.dll') then
      for var Name in ['DocSharp.Binary.Ppt.dll','DocSharp.Binary.Xls.dll'] do
        if not SameText(Result,UpdateFileVersion(ExtractFilePath(FileName)+Name)) then Result:='';
  end;
  if (ID<>'DjVuLibre') or (Result<>'') or not FileExists(FileName) then Exit;
  Root:=nil;
  try
    try
      MetadataFile:=ExtractFilePath(FileName)+'RUNTIME.json';
      if not FileExists(MetadataFile) or (TFile.GetSize(MetadataFile)>65536) then Exit;
      Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(MetadataFile,TEncoding.UTF8));
      if (Root is TJSONObject) and TJSONObject(Root).TryGetValue<TJSONObject>('djvu',Metadata) and
        Metadata.TryGetValue<string>('version',Version) and
        CompareComponentVersions(Version,Version,Comparison) and Metadata.TryGetValue<TJSONObject>('files',Hashes) then
      begin
        HashValue:=Hashes.GetValue('djvused.exe');
        if HashValue is TJSONString then
        begin Hash:=HashValue.Value; if IsUpdateSHA256(Hash) and SameText(UpdateSHA256(FileName),Hash) then Result:=Version; end;
      end;
    except Result:=''; end;
  finally Root.Free; end;
end;

function ComponentNeedsRepair(const AppPath, ID: string): Boolean;
var Names: TArray<string>; Name, FullName, Version: string; Comparison: Integer;
begin
  if IsFormatComponent(ID) then Exit(FormatComponentVersion(AppPath,ID)='');
  Result:=True;
  try
    Version:=InstalledComponentVersion(AppPath,ID);
    if Version='' then Exit;
    // An older Reader still requests the former all-format converter. Update
    // it on first use so catalogue launches obey the new dependency layout.
    if (ID='HomeLibReader') and
      (not CompareComponentVersions(Version,'2.7.0.1105',Comparison) or (Comparison<0)) then Exit;
    if ID='HomeLibReader' then Names:=TArray<string>.Create('HomeLibReader.exe','HomeLibRuUpdater.exe',
      'HomeLibReader-LICENSE.txt','sqlite3.dll','libzstd.dll','NOTICE')
    else if ID='MHLMcpServer' then Names:=TArray<string>.Create('MHLMcpServer.exe')
    else if ID='Zstandard' then
    begin
      Names:=TArray<string>.Create('libzstd.dll');
      if FileExists(TPath.Combine(AppPath,'tools/zstd/RUNTIME.json')) then
        Names:=Names+TArray<string>.Create('tools/zstd/RUNTIME.json','tools/zstd/LICENSE');
    end
    else if ID='PDFium' then Names:=TArray<string>.Create('tools/pdfium/pdfium.dll','tools/pdfium/HomeLibPDF.exe',
      'tools/pdfium/RUNTIME.json','tools/pdfium/WORKER_RUNTIME.json','tools/pdfium/LICENSE','tools/pdfium/HomeLibPDF-LICENSE.txt')
    else if ID='BookConverter' then Names:=TArray<string>.Create('tools/kindle/python/python.exe',
      'tools/bookconvert/convert_book.py','tools/bookconvert/COMPONENT.json')
    else if ID='IBK' then Names:=TArray<string>.Create('tools/ibk/Rus.key','tools/ibk/License.txt','tools/ibk/ICEBookReader-original.zip')
    else if ID='SQLite' then Names:=TArray<string>.Create('sqlite3.dll')
    else if ID='AlReader' then Names:=TArray<string>.Create('Readers/AlReader/AlReader2.exe')
    else if ID='SumatraPDF' then Names:=TArray<string>.Create('Readers/SumatraPDF/SumatraPDF.exe')
    else if ID='7-Zip' then Names:=TArray<string>.Create('tools/7zip/7z.exe','tools/7zip/7z.dll','tools/7zip/License.txt')
    else if ID='JPEG XL' then Names:=TArray<string>.Create('tools/jpeg-xl/djxl.exe','tools/jpeg-xl/licenses/LICENSE.libjxl')
    else if ID='WebP' then Names:=TArray<string>.Create('tools/webp/libwebp.dll','tools/webp/COPYING.txt','tools/webp/PATENTS.txt','tools/webp/AUTHORS.txt')
    else if ID='DocSharp' then Names:=TArray<string>.Create('tools/doc/HomeLibDoc.exe',
      'tools/doc/DocSharp.Binary.Doc.dll','tools/doc/DocSharp.Binary.Common.dll',
      'tools/doc/DocSharp.Binary.Ppt.dll','tools/doc/DocSharp.Binary.Xls.dll',
      'tools/doc/DocSharp-MIT.txt','tools/doc/b2xtranslator-BSD-3-Clause.txt','tools/doc/HomeLibDoc-MIT.txt')
    else if ID='DjVuLibre' then Names:=TArray<string>.Create('tools/djvu/HomeLibDjvu.exe',
      'tools/djvu/ddjvu.exe','tools/djvu/djvused.exe','tools/djvu/libdjvulibre.dll',
      'tools/djvu/libjpeg.dll','tools/djvu/libtiff.dll','tools/djvu/libz.dll',
      'tools/djvu/COPYING.txt','tools/djvu/COPYRIGHT','tools/djvu/IJG-README.txt',
      'tools/djvu/LIBTIFF-COPYRIGHT.txt','tools/djvu/ZLIB-README.txt')
    else Exit;
    for Name in Names do
    begin
      FullName:=TPath.Combine(AppPath,Name);
      if not FileExists(FullName) or (TFile.GetSize(FullName)=0) then Exit;
    end;
    if (ID='7-Zip') and not SameText(UpdateFileVersion(TPath.Combine(AppPath,'tools/7zip/7z.exe')),
      UpdateFileVersion(TPath.Combine(AppPath,'tools/7zip/7z.dll'))) then Exit;
    Result:=False;
  except Result:=True; end;
end;

function ProgramUpdatePlatform: string;
begin
{$IFDEF WIN64}
  Result := 'Win64';
{$ELSE}
  Result := 'Win32';
{$ENDIF}
end;

function UpdateSHA256(const FileName: string): string;
var Stream: TFileStream;
begin
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try Result := THashSHA2.GetHashString(Stream); finally Stream.Free; end;
end;

function IsUpdateSHA256(const Value: string): Boolean;
var C: Char;
begin
  Result := Length(Value) = 64;
  if not Result then Exit;
  for C in Value do
    if not CharInSet(C, ['0'..'9', 'a'..'f', 'A'..'F']) then Exit(False);
end;

function SafeUpdateName(const Name: string): Boolean;
var Parts: TArray<string>; Part, Lower, Base: string; C: Char;
begin
  Result := False;
  if (Name = '') or (Name[1] = '/') or (Pos('\', Name) > 0) or
     (Pos(':', Name) > 0) or (Pos(#0, Name) > 0) then Exit;
  Parts := Name.Split(['/']);
  for Part in Parts do
  begin
    if (Part = '') or (Part = '.') or (Part = '..') or
       (Part.Trim <> Part) or Part.EndsWith('.') or
       (Pos('*', Part) > 0) or (Pos('?', Part) > 0) then Exit;
    for C in Part do
      if (Ord(C) < 32) or CharInSet(C, ['"', '<', '>', '|']) then Exit;
    Base := UpperCase(Part.Split(['.'])[0]);
    if (Base = 'CON') or (Base = 'PRN') or (Base = 'AUX') or (Base = 'NUL') or
       ((Length(Base) = 4) and (Copy(Base, 1, 3) = 'COM') and CharInSet(Base[4], ['0'..'9'])) or
       ((Length(Base) = 4) and (Copy(Base, 1, 3) = 'LPT') and CharInSet(Base[4], ['0'..'9'])) then Exit;
  end;
  Lower := LowerCase(Name);
  if Length(Parts) = 1 then
    Result := (Lower = 'homelibru.exe') or (Lower = 'homelibreader.exe') or
      (Lower = 'homelibreader-license.txt') or (Lower = 'homelibruupdater.exe') or
      (Lower = 'mhlmcpserver.exe') or (Lower = 'mhlmcpserver-license.txt') or
      (Lower = 'mhlmcpserver-readme.txt') or (Lower = 'sqlite3.dll') or
      (Lower = 'libzstd.dll') or (Lower = 'license') or (Lower = 'notice') or
      (Lower = 'homelibru.url') or (Lower = 'changes.txt') or (Lower = 'components.json') or Lower.EndsWith('.glst')
  else
    Result := (Parts[0] = 'Help') or (Parts[0] = 'Icons') or
      (Parts[0] = 'tools') or (Parts[0] = 'Readers') or (Parts[0] = 'converters');
  // Distribution marker is copied only if absent; other profiles are excluded.
  if Lower.EndsWith('.ini') or Lower.EndsWith('.db') or Lower.EndsWith('.sqlite') or
     Lower.EndsWith('.sqlite3') or Lower.EndsWith('.cxml2') or
     Lower.EndsWith('.log') or Lower.EndsWith('.dat') or
     Lower.EndsWith('.settings') or Lower.EndsWith('.history') then
    Result := SameText(Name, 'Readers/AlReader/$savevtut.ini');
end;

function UpdateVolumeMount(const Path: string): Boolean;
var Data: TWin32FindData; Find: THandle; Volume: array[0..63] of Char; ID: TGUID;
  Name: string;
begin
  Result:=False;
  Find:=FindFirstFile(PChar(Path),Data);
  if Find=INVALID_HANDLE_VALUE then Exit;
  try
    if (Data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0) or
      (Data.dwReserved0<>$A0000003) then Exit; // IO_REPARSE_TAG_MOUNT_POINT
  finally Winapi.Windows.FindClose(Find); end;
  if not GetVolumeNameForVolumeMountPoint(PChar(IncludeTrailingPathDelimiter(Path)),Volume,Length(Volume)) then Exit;
  Name:=Volume;
  if (Length(Name)<>49) or not Name.StartsWith('\\?\Volume{',True) or not Name.EndsWith('}\') then Exit;
  try ID:=StringToGUID(Copy(Name,11,38)); Result:=True;
  except on E: EConvertError do Result:=False; end;
end;

procedure AssertUpdatePathBelow(const Path, Boundary: string);
var Current, Parent, Root: string; Attributes: DWORD; BelowRoot: Boolean;
begin
  Current:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(Path));
  Root:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(Boundary));
  if Length(Current)<=3 then
    raise Exception.Create('Нельзя обновлять корневую папку диска.');
  repeat
    Attributes:=GetFileAttributes(PChar(Current));
    if (Attributes<>INVALID_FILE_ATTRIBUTES) and (Attributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
    begin
      BelowRoot:=Current.StartsWith(IncludeTrailingPathDelimiter(Root),True);
      // A real volume mounted above the installation is a normal disk path.
      // Descendants in the managed payload/target must never redirect writes
      // or recursive cleanup, even when they point at another whole volume.
      if BelowRoot or not UpdateVolumeMount(Current) then
        raise Exception.Create('Папка обновления содержит ссылку: '+Current);
    end;
    Parent:=ExtractFileDir(Current);
    if (Parent=Current) or (Length(Parent)<3) then Break;
    Current:=Parent;
  until False;
end;

procedure AssertUpdatePath(const Path: string);
begin AssertUpdatePathBelow(Path,Path); end;

function ChildPath(const Root, Name: string): string;
var Prefix: string;
begin
  Prefix:=IncludeTrailingPathDelimiter(TPath.GetFullPath(Root));
  Result:=TPath.GetFullPath(Prefix+StringReplace(Name,'/',PathDelim,[rfReplaceAll]));
  if not Result.StartsWith(Prefix,True) then
    raise Exception.Create('Недопустимый путь в обновлении: '+Name);
  AssertUpdatePathBelow(Result,Root);
end;

function RetryUpdateFileOperation(const Operation: TFunc<Boolean>): Boolean;
var Error: DWORD; Deadline: UInt64;
begin
  // File scans can briefly deny an atomic rename after preflight succeeded.
  // Retry only sharing/access locks, with a fixed upper bound for each write.
  Deadline:=GetTickCount64+2000;
  repeat
    if Operation() then Exit(True);
    Error:=GetLastError;
    if ((Error<>ERROR_ACCESS_DENIED) and (Error<>ERROR_SHARING_VIOLATION) and
      (Error<>ERROR_LOCK_VIOLATION)) or (GetTickCount64>=Deadline) then Break;
    Sleep(50);
  until False;
  SetLastError(Error);
  Result:=False;
end;

procedure WriteJSON(const FileName: string; Value: TJSONObject);
var Temp: string;
begin
  Temp := FileName + '.new';
  TFile.WriteAllText(Temp, Value.ToJSON, TEncoding.UTF8);
  if not RetryUpdateFileOperation(function: Boolean
    begin Result:=MoveFileEx(PChar(Temp),PChar(FileName),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH); end) then
    RaiseLastOSError;
end;

function ReadJSON(const FileName: string): TJSONObject;
var Value: TJSONValue;
begin
  Value := TJSONObject.ParseJSONValue(TFile.ReadAllText(FileName, TEncoding.UTF8));
  if not (Value is TJSONObject) then
  begin Value.Free; raise Exception.Create('Повреждён файл состояния обновления.'); end;
  Result := TJSONObject(Value);
end;

function ManifestFiles(Root: TJSONObject): TUpdateFiles;
var ArrayValue: TJSONArray; Value: TJSONValue; I: Integer;
  Names: TDictionary<string, Boolean>; FileInfo: TUpdateFile; Total: Int64;
  Component, Version: string; Comparison: Integer;
  Bundle: TJSONArray; Part: TJSONValue; Allowed: Boolean; IDs: TDictionary<string, Boolean>;
  procedure RequireMember(const Name: string);
  begin
    if not Names.ContainsKey(LowerCase(Name)) then
      raise Exception.Create('В комплекте компонента отсутствует файл: '+Name);
  end;
  procedure RequireComponentMembers(const ID, Version: string);
  begin
    if IsFormatComponent(ID) then
    begin
      RequireMember(FormatComponentDescriptor(ID));
      for var Name in FormatComponentRequiredFiles(ID) do RequireMember(Name);
    end;
    if ID='Zstandard' then
      for var Name in ['libzstd.dll','tools/zstd/RUNTIME.json','tools/zstd/LICENSE'] do RequireMember(Name);
    if ID='MHLMcpServer' then
      for var Name in ['MHLMcpServer-LICENSE.txt','MHLMcpServer-README.txt'] do RequireMember(Name);
    if ID='HomeLibReader' then
      for var Name in ['HomeLibReader-LICENSE.txt','HomeLibRuUpdater.exe','sqlite3.dll','libzstd.dll','NOTICE'] do
        RequireMember(Name);
    if ID='PDFium' then
      for var Name in ['pdfium.dll','HomeLibPDF.exe','RUNTIME.json','WORKER_RUNTIME.json','LICENSE','HomeLibPDF-LICENSE.txt'] do
        RequireMember('tools/pdfium/'+Name);
    if ID='BookConverter' then
    begin
      RequireMember('tools/kindle/python/python.exe');
      RequireMember('tools/bookconvert/convert_book.py'); RequireMember('tools/bookconvert/COMPONENT.json');
    end;
    if ID='IBK' then
      for var Name in IBK_FILES do RequireMember('tools/ibk/'+Name);
    if ID='DocSharp' then
      for var Name in ['DocSharp.Binary.Doc.dll','DocSharp.Binary.Common.dll','HomeLibDoc.exe',
        'DOC_RUNTIME.json','DocSharp-MIT.txt','b2xtranslator-BSD-3-Clause.txt','HomeLibDoc-MIT.txt'] do
        RequireMember('tools/doc/'+Name);
    if (ID='DocSharp') and (Names.ContainsKey('tools/doc/docsharp.binary.ppt.dll') or
      Names.ContainsKey('tools/doc/docsharp.binary.xls.dll')) then
    begin
      RequireMember('tools/doc/DocSharp.Binary.Ppt.dll'); RequireMember('tools/doc/DocSharp.Binary.Xls.dll');
    end;
    if ID='7-Zip' then
      for var Name in ['7z.exe','7z.dll','License.txt'] do RequireMember('tools/7zip/'+Name);
    if ID='JPEG XL' then
      for var Name in ['djxl.exe','RUNTIME.json','licenses/LICENSE.libjxl'] do RequireMember('tools/jpeg-xl/'+Name);
    if ID='WebP' then
      for var Name in ['libwebp.dll','RUNTIME.json','COPYING.txt','PATENTS.txt','AUTHORS.txt'] do RequireMember('tools/webp/'+Name);
    if ID='DjVuLibre' then
    begin
      for var Name in ['ddjvu.exe','djvused.exe','libdjvulibre.dll','libjpeg.dll','libtiff.dll','libz.dll',
        'COPYING.txt','COPYRIGHT','IJG-README.txt','LIBTIFF-COPYRIGHT.txt','ZLIB-README.txt','RUNTIME.json'] do
        RequireMember('tools/djvu/'+Name);
      RequireMember('tools/djvu/djvulibre-'+Version+'.tar.gz');
    end;
  end;
begin
  Component := ''; Root.TryGetValue<string>('component', Component);
  Bundle := nil; Root.TryGetValue<TJSONArray>('bundle', Bundle);
  if Component = 'batch' then
  begin
    if not Assigned(Bundle) or (Bundle.Count < 1) or (Bundle.Count > 20) then
      raise Exception.Create('Некорректный пакет компонентов.');
  end
  else if (Component <> '') and ((ComponentFileName(Component) = '') or
     not Root.TryGetValue<string>('version', Version) or
     not CompareComponentVersions(Version, Version, Comparison)) then
    raise Exception.Create('Некорректный компонент обновления.');
  if not Root.TryGetValue<TJSONArray>('files', ArrayValue) or
     (ArrayValue.Count < 1) or (ArrayValue.Count > 4000) or
     ((Component = '') and (ArrayValue.Count < 3)) then
    raise Exception.Create('Некорректный список файлов обновления.');
  Names := TDictionary<string, Boolean>.Create;
  IDs := TDictionary<string, Boolean>.Create;
  try
    if Assigned(Bundle) then
    begin
      if (Bundle.Count < 1) or (Bundle.Count > 12) then raise Exception.Create('Некорректный пакет компонентов.');
      for Part in Bundle do
      begin
        if not (Part is TJSONObject) or not TJSONObject(Part).TryGetValue<string>('component', Version) or
           (ComponentFileName(Version)='') or IDs.ContainsKey(Version) or
           Assigned(TJSONObject(Part).GetValue('bundle')) then
          raise Exception.Create('Некорректный компонент пакета.');
        IDs.Add(Version, True);
        if not TJSONObject(Part).TryGetValue<string>('version', Version) or
           not CompareComponentVersions(Version, Version, Comparison) then
          raise Exception.Create('Некорректная версия компонента пакета.');
      end;
    end;
    SetLength(Result, ArrayValue.Count); I := 0; Total := 0;
    for Value in ArrayValue do
    begin
      FileInfo := Default(TUpdateFile);
      Allowed := Component <> 'batch';
      if (Component = 'batch') and (Value is TJSONObject) and
         TJSONObject(Value).TryGetValue<string>('path', Version) then
        for Part in Bundle do
          if SafeComponentFile(TJSONObject(Part).GetValue<string>('component'), Version) then Allowed := True;
      if not (Value is TJSONObject) or
         not TJSONObject(Value).TryGetValue<string>('path', FileInfo.Name) or
         not SafeUpdateName(FileInfo.Name) or
         not Allowed or
         ((Component <> '') and (Component <> 'batch') and not SafeComponentFile(Component, FileInfo.Name)) or
         not TJSONObject(Value).TryGetValue<string>('sha256', FileInfo.SHA256) or
         not IsUpdateSHA256(FileInfo.SHA256) or
         not TJSONObject(Value).TryGetValue<Int64>('size', FileInfo.Size) or
         (FileInfo.Size < 0) or (FileInfo.Size > 128 * 1024 * 1024) or
         Names.ContainsKey(LowerCase(FileInfo.Name)) then
        raise Exception.Create('Недопустимый файл в обновлении.');
      FileInfo.KeepExisting := SameText(FileInfo.Name, 'Readers/AlReader/$savevtut.ini');
      Total := Total + FileInfo.Size;
      if Total > 1024 * 1024 * 1024 then
        raise Exception.Create('Обновление превышает допустимый размер.');
      Names.Add(LowerCase(FileInfo.Name), True);
      Result[I] := FileInfo; Inc(I);
    end;
    if ((Component = '') and (not Names.ContainsKey('homelibru.exe') or
       not Names.ContainsKey('license') or not Names.ContainsKey('notice'))) or
       ((Component <> '') and (Component <> 'batch') and not Names.ContainsKey(LowerCase(ComponentFileName(Component)))) then
      raise Exception.Create('В обновлении отсутствуют обязательные файлы.');
    if Assigned(Bundle) then for Part in Bundle do
      if not Names.ContainsKey(LowerCase(ComponentFileName(TJSONObject(Part).GetValue<string>('component')))) then
        raise Exception.Create('В пакете отсутствует файл компонента.');
    if (Component<>'') and (Component<>'batch') then
      RequireComponentMembers(Component,Root.GetValue<string>('version'));
    if Assigned(Bundle) then for Part in Bundle do
      RequireComponentMembers(TJSONObject(Part).GetValue<string>('component'),TJSONObject(Part).GetValue<string>('version'));
  finally IDs.Free; Names.Free; end;
end;

procedure VerifyManagedAnyCPU(const FileName: string);
var Stream: TFileStream; PEOffset: Integer; Sections, OptionalSize, Magic: Word;
  CLR, CLRSize, Flags, HeaderSize, VirtualAddress, RawSize, RawOffset: Cardinal;
  Section: array[0..39] of Byte; Found: Boolean;
begin
  Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
  try
    if Stream.Size<64 then raise Exception.Create('Некорректная библиотека DOC.');
    Stream.Position:=$3C; Stream.ReadBuffer(PEOffset,4);
    if (PEOffset<64) or (Int64(PEOffset)+248>Stream.Size) then raise Exception.Create('Некорректная библиотека DOC.');
    Stream.Position:=PEOffset+6; Stream.ReadBuffer(Sections,2);
    Stream.Position:=PEOffset+20; Stream.ReadBuffer(OptionalSize,2);
    Stream.Position:=PEOffset+24; Stream.ReadBuffer(Magic,2);
    if (Magic<>$10B) or (OptionalSize<224) or (Sections<1) or (Sections>96) or
      (Int64(PEOffset)+24+OptionalSize+Int64(Sections)*40>Stream.Size) then
      raise Exception.Create('Библиотека DOC должна поддерживать обе разрядности Windows.');
    Stream.Position:=PEOffset+24+96+14*8; Stream.ReadBuffer(CLR,4); Stream.ReadBuffer(CLRSize,4);
    if (CLR=0) or (CLRSize<72) then raise Exception.Create('В библиотеке DOC нет управляемого кода.');
    Found:=False;
    for var I:=0 to Sections-1 do
    begin
      Stream.Position:=PEOffset+24+OptionalSize+I*40; Stream.ReadBuffer(Section,40);
      Move(Section[12],VirtualAddress,4); Move(Section[16],RawSize,4); Move(Section[20],RawOffset,4);
      if (CLR>=VirtualAddress) and (UInt64(CLR-VirtualAddress)+72<=RawSize) and
        (UInt64(RawOffset)+CLR-VirtualAddress+72<=UInt64(Stream.Size)) then
      begin
        Stream.Position:=UInt64(RawOffset)+CLR-VirtualAddress; Stream.ReadBuffer(HeaderSize,4);
        Stream.Position:=Stream.Position+12; Stream.ReadBuffer(Flags,4);
        if (HeaderSize<72) or ((Flags and 1)=0) or ((Flags and $20002)<>0) then
          raise Exception.Create('Библиотека DOC не поддерживает режим AnyCPU.');
        Found:=True; Break;
      end;
    end;
    if not Found then raise Exception.Create('Некорректный заголовок библиотеки DOC.');
  finally Stream.Free; end;
end;

procedure VerifyUpdateExecutable(const FileName, Tag, Platform: string; Component: Boolean = False);
type TTranslation = packed record Language, CodePage: Word; end;
var Stream: TFileStream; MZ, Machine: Word; Offset: Integer; PE: Cardinal;
  Size, Dummy: DWORD; Buffer: TBytes; Value: Pointer; Len: UINT; Product: string;
  Translations: Pointer; TranslationLength: UINT; I, Comparison: Integer; Translation: TTranslation;
begin
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    if Stream.Size < 64 then raise Exception.Create('Некорректный EXE обновления.');
    Stream.ReadBuffer(MZ, 2); Stream.Position := $3C; Stream.ReadBuffer(Offset, 4);
    if (MZ <> $5A4D) or (Offset < 64) or (Offset > Stream.Size - 6) then
      raise Exception.Create('Некорректный EXE обновления.');
    Stream.Position := Offset; Stream.ReadBuffer(PE, 4); Stream.ReadBuffer(Machine, 2);
    if (PE <> $4550) or ((Platform = 'Win64') and (Machine <> $8664)) or
       ((Platform = 'Win32') and (Machine <> $14C)) then
      raise Exception.Create('Разрядность обновления не подходит этой программе.');
  finally Stream.Free; end;
  if Component then
  begin
    if Tag = '' then Exit;
    if not CompareComponentVersions(UpdateFileVersion(FileName), Tag, Comparison) or (Comparison <> 0) then
      raise Exception.Create('Версия компонента не совпадает с описанием обновления.');
    Exit;
  end;
  Size := GetFileVersionInfoSize(PChar(FileName), Dummy);
  SetLength(Buffer, Size);
  if (Size = 0) or not GetFileVersionInfo(PChar(FileName), 0, Size, @Buffer[0]) then
    raise Exception.Create('В EXE обновления нет сведений о версии.');
  Product := '';
  if VerQueryValue(@Buffer[0], '\VarFileInfo\Translation', Translations, TranslationLength) then
    for I := 0 to Integer(TranslationLength div SizeOf(TTranslation)) - 1 do
    begin
      Move(PByte(NativeUInt(Translations) + NativeUInt(I * SizeOf(TTranslation)))^, Translation, SizeOf(Translation));
      if VerQueryValue(@Buffer[0], PChar(Format('\StringFileInfo\%.4x%.4x\ProductVersion',
        [Translation.Language, Translation.CodePage])), Value, Len) and (Len > 0) then
      begin Product := PChar(Value); Break; end;
    end;
  if Product <> Tag then
    raise Exception.Create('Версия EXE не совпадает с версией обновления.');
end;

procedure VerifyPreparedProgramUpdateIdentity(Manifest: TJSONObject;
  const Stage, Tag, Platform: string);
var Component, Version, Architecture: string; Official: Boolean; Bundle: TJSONArray; Part: TJSONValue;
begin
  Component := ''; Manifest.TryGetValue<string>('component', Component);
  if Manifest.TryGetValue<TJSONArray>('bundle', Bundle) then
    for Part in Bundle do
      VerifyPreparedProgramUpdateIdentity(TJSONObject(Part), Stage, Tag, Platform);
  if Component = 'batch' then Exit;
  if Component = '' then
    VerifyUpdateExecutable(ChildPath(Stage, 'HomeLibRu.exe'), Tag, Platform)
  else
  begin
    if (ComponentFileName(Component) = '') or not Manifest.TryGetValue<string>('version', Version) then
      raise Exception.Create('Некорректное описание компонента.');
    Architecture := Platform;
    // AlReader's Windows edition is a 32-bit application in both distributions.
    if (Component='AlReader') or (Component='DocSharp') or (Component='DjVuLibre') or (Component='IBK') then Architecture:='Win32';
    if IsFormatComponent(Component) then
    begin
      if Component='LegacyOffice' then Architecture:='Win64';
      if Component<>'Kindle' then
        VerifyUpdateExecutable(ChildPath(Stage,ComponentFileName(Component)),'',Architecture,True);
      if InstalledComponentVersion(Stage,Component)<>Version then
        raise Exception.Create('Версия или контрольная сумма модуля '+Component+' не совпадает с описанием пакета.');
    end
    else if Component='IBK' then
    begin
      if InstalledComponentVersion(Stage,Component)<>Version then
        raise Exception.Create('Не совпала версия или контрольная сумма данных IBK.');
    end
    else if (Component='PDFium') or (Component='BookConverter') or (Component='Zstandard') then
    begin
      VerifyUpdateExecutable(ChildPath(Stage,ComponentFileName(Component)),'',Architecture,True);
      if InstalledComponentVersion(Stage,Component)<>Version then
        raise Exception.Create('Версия или контрольная сумма модуля не совпадает с описанием пакета.');
      if Component='PDFium' then VerifyUpdateExecutable(ChildPath(Stage,'tools/pdfium/HomeLibPDF.exe'),'',Architecture,True);
    end
    else if (Component='JPEG XL') or (Component='WebP') then
    begin
      VerifyUpdateExecutable(ChildPath(Stage,ComponentFileName(Component)),'',Architecture,True);
      if InstalledComponentVersion(Stage,Component)<>Version then
        raise Exception.Create('Версия или контрольная сумма декодера изображений не совпадает с описанием пакета.');
    end
    else if Component='DjVuLibre' then
    begin
      VerifyUpdateExecutable(ChildPath(Stage,ComponentFileName(Component)),'',Architecture,True);
      if InstalledComponentVersion(Stage,Component)<>Version then
        raise Exception.Create('Версия или контрольная сумма DjVuLibre не совпадает с описанием пакета.');
      for var Name in ['ddjvu.exe','libdjvulibre.dll','libjpeg.dll','libtiff.dll','libz.dll'] do
        VerifyUpdateExecutable(ChildPath(Stage,'tools/djvu/'+Name),'',Architecture,True);
    end
    else VerifyUpdateExecutable(ChildPath(Stage, ComponentFileName(Component)), Version, Architecture, True);
    if Component='HomeLibReader' then
      for var Name in ['HomeLibRuUpdater.exe','sqlite3.dll','libzstd.dll'] do
        VerifyUpdateExecutable(ChildPath(Stage,Name),'',Architecture,True);
    if Component='DocSharp' then
    begin
      for var Name in ['DocSharp.Binary.Doc.dll','DocSharp.Binary.Common.dll','DocSharp.Binary.Ppt.dll','DocSharp.Binary.Xls.dll','HomeLibDoc.exe'] do
      begin
        if ((Name='DocSharp.Binary.Ppt.dll') or (Name='DocSharp.Binary.Xls.dll')) and
          not FileExists(ChildPath(Stage,'tools/doc/'+Name)) then Continue;
        VerifyManagedAnyCPU(ChildPath(Stage,'tools/doc/'+Name));
        if Name='HomeLibDoc.exe' then
          VerifyUpdateExecutable(ChildPath(Stage,'tools/doc/'+Name),'',Architecture,True)
        else VerifyUpdateExecutable(ChildPath(Stage,'tools/doc/'+Name),Version,Architecture,True);
      end;
    end;
    if Component='7-Zip' then
      VerifyUpdateExecutable(ChildPath(Stage,'tools/7zip/7z.dll'),Version,Architecture,True);
    Official := False; Manifest.TryGetValue<Boolean>('official', Official);
    if Official and (Component = 'SumatraPDF') then
      VerifySumatraSignature(ChildPath(Stage, ComponentFileName(Component)));
    if (Component = 'AlReader') and FileExists(ChildPath(Stage, 'Readers/AlReader/UNRAR.DLL')) then
      VerifyUpdateExecutable(ChildPath(Stage, 'Readers/AlReader/UNRAR.DLL'), '', 'Win32', True);
  end;
end;

function CombinePreparedProgramUpdates(const Jobs: TArray<string>;
  const Tag, Platform, Job: string): string;
var Manifest, Child, Entry, Part: TJSONObject; Bundle, List: TJSONArray;
  Files: TDictionary<string, TUpdateFile>; Info: TUpdateFile; JobName, Stage, Component, ReleaseTag: string;
  Zip: TZipFile; HasApplication: Boolean; Values: TUpdateFiles;
begin
  if (Length(Jobs) < 2) or (Length(Jobs) > 9) or DirectoryExists(Job) then
    raise Exception.Create('Некорректный набор подготовленных обновлений.');
  AssertUpdatePath(Job); ForceDirectories(Job); Stage := ChildPath(Job, 'payload');
  Manifest := TJSONObject.Create; Files := TDictionary<string, TUpdateFile>.Create;
  Bundle := TJSONArray.Create; List := TJSONArray.Create; Zip := TZipFile.Create;
  Manifest.AddPair('format', TJSONNumber.Create(1)); Manifest.AddPair('release', Tag);
  Manifest.AddPair('platform', Platform); Manifest.AddPair('bundle', Bundle); Manifest.AddPair('files', List);
  HasApplication := False;
  try
    for JobName in Jobs do
    begin
      AssertUpdatePath(JobName); Child := ReadJSON(ChildPath(JobName, 'manifest.json'));
      try
        ReleaseTag := Child.GetValue<string>('release');
        VerifyPreparedProgramUpdate(JobName, ReleaseTag, Platform);
        Component := ''; Child.TryGetValue<string>('component', Component);
        if Component = '' then
        begin
          if HasApplication or (ReleaseTag <> Tag) or (Bundle.Count > 0) then
            raise Exception.Create('Обновление программы должно быть первым в пакете.');
          HasApplication := True;
        end
        else
        begin
          if ComponentFileName(Component)='' then
            raise Exception.Create('Этот компонент нельзя включить в пакет.');
          Part := TJSONObject.Create; Part.AddPair('component', Component);
          Part.AddPair('version', Child.GetValue<string>('version'));
          Part.AddPair('official', TJSONBool.Create(Child.GetValue<Boolean>('official', False)));
          Bundle.AddElement(Part);
        end;
        Values := ManifestFiles(Child);
        for Info in Values do
        begin
          if not SameText(UpdateSHA256(ChildPath(JobName, 'payload/' + Info.Name)), Info.SHA256) then
            raise Exception.Create('Подготовленное обновление повреждено: ' + Info.Name);
          ForceDirectories(ExtractFileDir(ChildPath(Stage, Info.Name)));
          TFile.Copy(ChildPath(JobName, 'payload/' + Info.Name), ChildPath(Stage, Info.Name), True);
          Files.AddOrSetValue(Info.Name, Info);
        end;
      finally Child.Free; end;
    end;
    if not HasApplication then Manifest.AddPair('component', 'batch');
    for Info in Files.Values do
    begin
      Entry := TJSONObject.Create; Entry.AddPair('path', Info.Name);
      Entry.AddPair('sha256', Info.SHA256); Entry.AddPair('size', TJSONNumber.Create(Info.Size));
      List.AddElement(Entry);
    end;
    ManifestFiles(Manifest);
    VerifyPreparedProgramUpdateIdentity(Manifest, Stage, Tag, Platform);
    WriteJSON(ChildPath(Job, 'manifest.json'), Manifest);
    Zip.Open(ChildPath(Job, 'release.zip'), zmWrite);
    Zip.Add(ChildPath(Job, 'manifest.json'), UPDATE_MANIFEST);
    for Info in Files.Values do Zip.Add(ChildPath(Stage, Info.Name), Info.Name);
    Zip.Close;
    Result := UpdateSHA256(ChildPath(Job, 'release.zip'));
  finally Zip.Free; Files.Free; Manifest.Free; end;
end;

function PreparedComponentsNewer(const Job, AppPath: string): Boolean;
var Manifest: TJSONObject; Bundle: TJSONArray; Part: TJSONValue;
  ID, Version, Installed: string; Comparison: Integer;
begin
  Result := False; Manifest := ReadJSON(ChildPath(Job, 'manifest.json'));
  try
    ManifestFiles(Manifest);
    if not Manifest.TryGetValue<TJSONArray>('bundle', Bundle) then Exit;
    for Part in Bundle do
    begin
      ID := TJSONObject(Part).GetValue<string>('component');
      Version := TJSONObject(Part).GetValue<string>('version');
      Installed := InstalledComponentVersion(AppPath,ID);
      if (Installed = '') or
         (CompareComponentVersions(Version, Installed, Comparison) and (Comparison > 0)) then Exit(True);
    end;
  finally Manifest.Free; end;
end;

function PreparedIncludesComponent(const Job, Component: string): Boolean;
var Manifest: TJSONObject; Bundle: TJSONArray; Part: TJSONValue; ID: string;
begin
  Result:=False; Manifest:=ReadJSON(ChildPath(Job,'manifest.json'));
  try
    ManifestFiles(Manifest);
    if Manifest.TryGetValue<string>('component',ID) and (ID=Component) then Exit(True);
    if Manifest.TryGetValue<TJSONArray>('bundle',Bundle) then
      for Part in Bundle do
        if (Part is TJSONObject) and TJSONObject(Part).TryGetValue<string>('component',ID) and
          (ID=Component) then Exit(True);
  finally Manifest.Free; end;
end;

procedure PrepareOfficialSimpleComponent(const Archive, Job, ID, Version, Platform: string);
var Zip: TZipFile; I, Selected: Integer; Name, Stage, Destination: string; Bytes: TBytes;
  Manifest, Entry: TJSONObject; Files: TJSONArray;
begin
  if (ID <> 'SQLite') and (ID <> 'SumatraPDF') then
    raise Exception.Create('Прямое обновление этого компонента пока недоступно.');
  AssertUpdatePath(Archive); AssertUpdatePath(Job); Stage := ChildPath(Job, 'payload');
  if DirectoryExists(Stage) then raise Exception.Create('Папка обновления уже занята.');
  Zip := TZipFile.Create; Manifest := nil; Selected := -1;
  try
    Zip.Open(Archive, zmRead);
    if (Zip.FileCount < 1) or (Zip.FileCount > 10) then
      raise Exception.Create('Неожиданное содержимое официального архива.');
    for I := 0 to Zip.FileCount - 1 do
    begin
      Name := Zip.FileNames[I];
      if (Pos('/', Name) > 0) or (Pos('\', Name) > 0) or
         (Zip.FileInfo[I].UncompressedSize > 128 * 1024 * 1024) then
        raise Exception.Create('Неожиданный путь в архиве компонента.');
      if ((ID = 'SQLite') and (Name = 'sqlite3.dll')) or
         ((ID = 'SumatraPDF') and TRegEx.IsMatch(Name, '^SumatraPDF(?:-[0-9.]+(?:-(?:32|64))?)?\.exe$')) then
      begin
        if Selected <> -1 then raise Exception.Create('В архиве несколько файлов компонента.');
        Selected := I;
      end
      else if not (((ID = 'SQLite') and (Name = 'sqlite3.def')) or
        ((ID = 'SumatraPDF') and ((Name = 'LICENSE') or (Name = 'COPYING') or (Name = 'README.txt')))) then
        raise Exception.Create('В официальном архиве обнаружен неожиданный файл: ' + Name);
    end;
    if Selected < 0 then raise Exception.Create('В архиве отсутствует компонент.');
    Zip.Read(Selected, Bytes); Destination := ChildPath(Stage, ComponentFileName(ID));
    ForceDirectories(ExtractFileDir(Destination)); TFile.WriteAllBytes(Destination, Bytes);
    Manifest := TJSONObject.Create; Manifest.AddPair('format', TJSONNumber.Create(1));
    Manifest.AddPair('release', Version); Manifest.AddPair('platform', Platform);
    Manifest.AddPair('component', ID); Manifest.AddPair('version', Version);
    Manifest.AddPair('official', TJSONBool.Create(True));
    Files := TJSONArray.Create; Manifest.AddPair('files', Files); Entry := TJSONObject.Create;
    Entry.AddPair('path', ComponentFileName(ID)); Entry.AddPair('size', TJSONNumber.Create(Length(Bytes)));
    Entry.AddPair('sha256', UpdateSHA256(Destination)); Files.AddElement(Entry);
    ManifestFiles(Manifest); VerifyPreparedProgramUpdateIdentity(Manifest, Stage, Version, Platform);
    WriteJSON(ChildPath(Job, 'manifest.json'), Manifest);
  finally Manifest.Free; Zip.Free; end;
end;


function IsOfficialComponentURL(const ID, Version, URL, Platform: string; Secondary: Boolean): Boolean;
var Suffix: string;
begin
  Result:=False;
  if not TRegEx.IsMatch(Version,'^[0-9]+\.[0-9]+(?:\.[0-9]+){0,2}$') then Exit;
  if ID='IBK' then
  begin
    if Version<>IBK_VERSION then Exit;
    if Secondary then Exit((URL=IBK_EXTRACTOR_URL) or (URL=IBK_MIRROR_PREFIX+IBK_EXTRACTOR_MIRROR_NAME));
    Exit(IsIBKPackageURL(URL) or (URL=IBK_MIRROR_PREFIX+IBK_MIRROR_NAME));
  end;
  if ID='SQLite' then
  begin
    if Platform='Win64' then Suffix:='x64' else Suffix:='x86';
    Exit(not Secondary and TRegEx.IsMatch(URL,'^https://www\.sqlite\.org/[0-9]{4}/sqlite-dll-win-'+Suffix+'-[0-9]{7}\.zip$'));
  end;
  if ID='SumatraPDF' then
  begin
    if Platform='Win64' then Suffix:='-64' else Suffix:='';
    Exit(not Secondary and (URL='https://www.sumatrapdfreader.org/dl/rel/'+Version+'/SumatraPDF-'+Version+Suffix+'.zip'));
  end;
  if ID='7-Zip' then
  begin
    if Platform='Win64' then Suffix:='-x64' else Suffix:='';
    if Secondary then Exit(URL='https://github.com/ip7z/7zip/releases/download/'+Version+'/7zr.exe');
    Exit(URL='https://github.com/ip7z/7zip/releases/download/'+Version+'/7z'+Version.Replace('.','')+Suffix+'.exe');
  end;
  if ID='JPEG XL' then
  begin
    if Platform='Win64' then Suffix:='x64' else Suffix:='x86';
    Exit(not Secondary and (URL='https://github.com/libjxl/libjxl/releases/download/v'+Version+'/jxl-'+Suffix+'-windows-static.zip'));
  end;
  if ID='DocSharp' then
  begin
    if Secondary then Suffix:='common' else Suffix:='doc';
    Exit(URL='https://api.nuget.org/v3-flatcontainer/docsharp.binary.'+Suffix+'/'+Version+'/docsharp.binary.'+Suffix+'.'+Version+'.nupkg');
  end;
  if ID='DjVuLibre' then
  begin
    if Secondary then Exit(URL='https://master.dl.sourceforge.net/project/djvu/DjVuLibre/'+Version+'/djvulibre-'+Version+'.tar.gz?viasf=1');
    Exit(TRegEx.IsMatch(URL,'^https://master\.dl\.sourceforge\.net/project/djvu/DjVuLibre_Windows/'+
      Version.Replace('.','\.')+'%2B[0-9.]+/DjVuLibre-'+Version.Replace('.','\.')+'_DjView-[0-9.]+_Setup\.exe\?viasf=1$'));
  end;
end;

function ExtractReaderAdapter(const Archive, Job, ID: string): string;
var Package: TReaderAdapterPackage; Zip: TZipFile; Bytes: TBytes; Index: Integer;
  Names: TArray<string>; Destination: string;
begin
  AssertUpdatePath(Archive); AssertUpdatePath(Job);
  if not ReaderAdapterPackage(ID,Package) or (TFile.GetSize(Archive)<>Package.Size) or
    not SameText(UpdateSHA256(Archive),Package.SHA256) then
    raise Exception.Create('Не совпала контрольная сумма вспомогательного модуля чтения.');
  Result:=ChildPath(Job,'native-adapter');
  if DirectoryExists(Result) then raise Exception.Create('Папка модуля чтения уже занята.');
  Names:=ReaderAdapterFiles(ID); Zip:=TZipFile.Create;
  try
    Zip.Open(Archive,zmRead);
    if Zip.FileCount<>Length(Names) then raise Exception.Create('Некорректный состав модуля чтения.');
    for var Name in Names do
    begin
      Index:=Zip.IndexOf(Name);
      if (Index<0) or not SafeComponentFile(ID,Name) or
        (Zip.FileInfo[Index].UncompressedSize<1) or (Zip.FileInfo[Index].UncompressedSize>2*1024*1024) then
        raise Exception.Create('В модуле чтения отсутствует нужный файл: '+Name);
      Zip.Read(Index,Bytes); Destination:=ChildPath(Result,Name);
      ForceDirectories(ExtractFileDir(Destination)); TFile.WriteAllBytes(Destination,Bytes);
    end;
  finally Zip.Free; end;
end;

procedure MergePreparedReaderAdapter(const Job, ID, AdapterPath: string);
var Root: TJSONObject; Files: TJSONArray; Entry: TJSONObject; Stage, Source, Destination: string;
begin
  if AdapterPath='' then Exit;
  AssertUpdatePath(Job); AssertUpdatePath(AdapterPath);
  if not SameFileName(AdapterPath,ChildPath(Job,'native-adapter')) then
    raise Exception.Create('Некорректная папка модуля чтения.');
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ChildPath(Job,'manifest.json'),TEncoding.UTF8)) as TJSONObject;
  try
    if not Assigned(Root) or (Root.GetValue<string>('component','')<>ID) or
      not Root.TryGetValue<TJSONArray>('files',Files) then
      raise Exception.Create('Подготовлен другой компонент.');
    Stage:=ChildPath(Job,'payload');
    for var Name in ReaderAdapterFiles(ID) do
    begin
      Source:=ChildPath(AdapterPath,Name); Destination:=ChildPath(Stage,Name);
      ForceDirectories(ExtractFileDir(Destination)); TFile.Copy(Source,Destination,True);
      Entry:=nil;
      for var Value in Files do
        if Value.GetValue<string>('path','')=Name then begin Entry:=TJSONObject(Value); Break; end;
      if not Assigned(Entry) then
      begin Entry:=TJSONObject.Create; Entry.AddPair('path',Name); Files.AddElement(Entry); end;
      Entry.RemovePair('size').Free; Entry.RemovePair('sha256').Free;
      Entry.AddPair('size',TJSONNumber.Create(TFile.GetSize(Destination)));
      Entry.AddPair('sha256',UpdateSHA256(Destination));
    end;
    ManifestFiles(Root);
    VerifyPreparedProgramUpdateIdentity(Root,Stage,Root.GetValue<string>('release'),Root.GetValue<string>('platform'));
    WriteJSON(ChildPath(Job,'manifest.json'),Root);
  finally Root.Free; end;
end;

procedure PrepareOfficialComponent(const Archive, Job, ID, Version, Platform: string;
  const SecondaryArchive, AppPath: string; const AdditionalArchives: TArray<string>; const AdapterPath: string);
var Stage, Raw, Source, Destination, Tools, RuntimePath, AdapterRuntime: string; Names: TArray<string>;
  Manifest, Entry, Metadata, Hashes: TJSONObject; Files: TJSONArray;
  Zip: TZipFile; Bytes: TBytes; Log: TStringStream; Started: UInt64;
  procedure AddFile(const Name, SourceFile: string);
  begin
    if not SafeComponentFile(ID,Name) or not FileExists(SourceFile) or (TFile.GetSize(SourceFile)>128*1024*1024) then
      raise Exception.Create('В официальном комплекте отсутствует файл: '+Name);
    Destination:=ChildPath(Stage,Name); ForceDirectories(ExtractFileDir(Destination));
    if not SameText(SourceFile,Destination) then TFile.Copy(SourceFile,Destination,False);
    Entry:=TJSONObject.Create; Entry.AddPair('path',Name); Entry.AddPair('size',TJSONNumber.Create(TFile.GetSize(Destination)));
    Entry.AddPair('sha256',UpdateSHA256(Destination)); Files.AddElement(Entry);
  end;
  procedure NuGetDLL(const PackageFile, AssemblyName: string);
  var Text: string;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(PackageFile,zmRead);
      if (Zip.FileCount<2) or (Zip.FileCount>1024) then raise Exception.Create('Некорректный пакет NuGet.');
      var Index:=Zip.IndexOf(AssemblyName+'.nuspec');
      if (Index<0) or (Zip.FileInfo[Index].UncompressedSize>131072) then raise Exception.Create('Нет описания официального пакета NuGet.');
      Zip.Read(Index,Bytes); Text:=TEncoding.UTF8.GetString(Bytes);
      if not Text.Contains('<id>'+AssemblyName+'</id>') or not Text.Contains('<version>'+Version+'</version>') then
        raise Exception.Create('Версия или имя пакета NuGet не совпадает.');
      Index:=Zip.IndexOf('lib/net462/'+AssemblyName+'.dll');
      if (Index<0) or (Zip.FileInfo[Index].UncompressedSize>16*1024*1024) then
        raise Exception.Create('Этот выпуск DocSharp не поддерживает встроенную читалку (.NET 4.6.2).');
      Zip.Read(Index,Bytes); Source:=ChildPath(Stage,'tools/doc/'+AssemblyName+'.dll');
      ForceDirectories(ExtractFileDir(Source)); TFile.WriteAllBytes(Source,Bytes); AddFile('tools/doc/'+AssemblyName+'.dll',Source);
    finally Zip.Free; end;
  end;
  procedure RunBounded(const Tool: string; const Arguments: array of string);
  begin
    Log:=TStringStream.Create('',TEncoding.UTF8); Started:=GetTickCount64;
    try
      RunExternalToolToStream(Tool,Arguments,Log,
        function: Boolean begin Result:=False; if (GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated then Abort; if GetTickCount64-Started>30000 then
          raise Exception.Create('Подготовка официального компонента превысила 30 секунд.'); end,0,True,512*1024*1024);
    finally Log.Free; end;
  end;
begin
  if (ID='SQLite') or (ID='SumatraPDF') then
  begin PrepareOfficialSimpleComponent(Archive,Job,ID,Version,Platform); Exit; end;
  if (ID<>'7-Zip') and (ID<>'DocSharp') and (ID<>'DjVuLibre') and (ID<>'JPEG XL') and (ID<>'IBK') then
    raise Exception.Create('Не найден официальный Windows-пакет этого компонента.');
  AssertUpdatePath(Archive); AssertUpdatePath(Job); Stage:=ChildPath(Job,'payload');
  if DirectoryExists(Stage) then raise Exception.Create('Папка обновления уже занята.');
  RuntimePath:=AppPath; if RuntimePath='' then RuntimePath:=ExtractFilePath(ParamStr(0));
  AdapterRuntime:=RuntimePath;
  if AdapterPath<>'' then
  begin
    AssertUpdatePath(AdapterPath);
    if not SameFileName(AdapterPath,ChildPath(Job,'native-adapter')) then
      raise Exception.Create('Некорректная папка модуля чтения.');
    AdapterRuntime:=AdapterPath;
  end;
  Manifest:=TJSONObject.Create;
  try
    Manifest.AddPair('format',TJSONNumber.Create(1)); Manifest.AddPair('release',Version); Manifest.AddPair('platform',Platform);
    Manifest.AddPair('component',ID); Manifest.AddPair('version',Version); Manifest.AddPair('official',TJSONBool.Create(True));
    Files:=TJSONArray.Create; Manifest.AddPair('files',Files);
    if ID='IBK' then
    begin
      // Preserve the complete, unchanged original distribution. Only the
      // independently verified read data are used; ICE itself is never run.
      if (Version<>IBK_VERSION) or not SameText(UpdateSHA256(Archive),IBK_PACKAGE_SHA256) or
        (SecondaryArchive='') then raise Exception.Create('Не совпал исходный пакет IBK.');
      AssertUpdatePath(SecondaryArchive);
      if not SameText(UpdateSHA256(SecondaryArchive),IBK_EXTRACTOR_SHA256) then
        raise Exception.Create('Не совпал исходный пакет распаковщика IBK.');
      Raw:=ChildPath(Job,'ibk-extract'); ForceDirectories(Raw);
      Zip:=TZipFile.Create;
      try
        Zip.Open(Archive,zmRead);
        if (Zip.FileCount<>1) or (Zip.FileNames[0]<>'ICE Book Reader Rus.exe') or
          (Zip.FileInfo[0].UncompressedSize<>6444144) then
          raise Exception.Create('Неожиданное содержимое исходного пакета IBK.');
        Zip.Read(0,Bytes); Source:=ChildPath(Raw,'original-installer.exe'); TFile.WriteAllBytes(Source,Bytes);
      finally Zip.Free; end;
      if not SameText(UpdateSHA256(Source),IBK_INSTALLER_SHA256) then
        raise Exception.Create('Не совпала контрольная сумма исходного установщика IBK.');
      Zip:=TZipFile.Create;
      try
        Zip.Open(SecondaryArchive,zmRead);
        var Index:=Zip.IndexOf('innoextract.exe');
        if (Index<0) or (Zip.FileCount>30) or (Zip.FileInfo[Index].UncompressedSize<>1218560) then
          raise Exception.Create('В исходном пакете отсутствует распаковщик IBK.');
        Zip.Read(Index,Bytes); Tools:=ChildPath(Raw,'innoextract.exe'); TFile.WriteAllBytes(Tools,Bytes);
      finally Zip.Free; end;
      if not SameText(UpdateSHA256(Tools),IBK_EXTRACTOR_EXE_SHA256) then
        raise Exception.Create('Не совпала контрольная сумма распаковщика IBK.');
      RunBounded(Tools,['--silent','--output-dir',ChildPath(Raw,'data'),
        '-I','app\Rus.key','-I','app\License.txt',Source]);
      for var Name in ['Rus.key','License.txt'] do
        AddFile('tools/ibk/'+Name,ChildPath(Raw,'data/app/'+Name));
      AddFile('tools/ibk/ICEBookReader-original.zip',Archive);
      Bytes:=nil;
      if not IBKRuntimeAvailable(Stage) then raise Exception.Create('Данные IBK не прошли итоговую проверку.');
    end
    else if ID='JPEG XL' then
    begin
      if Platform='Win64' then Raw:='x64-windows-static/' else Raw:='x86-windows-static/';
      Zip:=TZipFile.Create;
      try
        Zip.Open(Archive,zmRead);
        if Zip.FileCount>4000 then raise Exception.Create('Слишком много файлов в пакете JPEG XL.');
        for var I:=0 to Zip.FileCount-1 do
        begin
          Source:=Zip.FileNames[I];
          if Source=Raw+'bin/djxl.exe' then Source:='tools/jpeg-xl/djxl.exe'
          else if Source.StartsWith(Raw+'licenses/LICENSE.') then
            Source:='tools/jpeg-xl/licenses/'+Copy(Source,Length(Raw+'licenses/')+1,MaxInt)
          else Continue;
          if not SafeComponentFile(ID,Source) or (Zip.FileInfo[I].UncompressedSize>128*1024*1024) then
            raise Exception.Create('Неподдерживаемый файл в пакете JPEG XL.');
          Destination:=ChildPath(Stage,Source); ForceDirectories(ExtractFileDir(Destination));
          Zip.Read(I,Bytes); TFile.WriteAllBytes(Destination,Bytes); Bytes:=nil; AddFile(Source,Destination);
        end;
      finally Zip.Free; end;
      Metadata:=TJSONObject.Create; Entry:=TJSONObject.Create; Hashes:=TJSONObject.Create;
      try
        Metadata.AddPair('component',ID); Metadata.AddPair('codec',Entry);
        Entry.AddPair('version',Version); Entry.AddPair('files',Hashes);
        Hashes.AddPair('djxl.exe',UpdateSHA256(ChildPath(Stage,'tools/jpeg-xl/djxl.exe')));
        WriteJSON(ChildPath(Stage,'tools/jpeg-xl/RUNTIME.json'),Metadata);
      finally Metadata.Free; end;
      AddFile('tools/jpeg-xl/RUNTIME.json',ChildPath(Stage,'tools/jpeg-xl/RUNTIME.json'));
    end
    else if ID='DocSharp' then
    begin
      if SecondaryArchive='' then raise Exception.Create('Отсутствует второй пакет DocSharp.');
      AssertUpdatePath(SecondaryArchive);
      NuGetDLL(Archive,'DocSharp.Binary.Doc'); NuGetDLL(SecondaryArchive,'DocSharp.Binary.Common');
      if Length(AdditionalArchives)=2 then
      begin
        AssertUpdatePath(AdditionalArchives[0]); AssertUpdatePath(AdditionalArchives[1]);
        NuGetDLL(AdditionalArchives[0],'DocSharp.Binary.Ppt'); NuGetDLL(AdditionalArchives[1],'DocSharp.Binary.Xls');
      end
      else if FileExists(TPath.Combine(RuntimePath,'tools/doc/DocSharp.Binary.Ppt.dll')) or
        FileExists(TPath.Combine(RuntimePath,'tools/doc/DocSharp.Binary.Xls.dll')) then
        raise Exception.Create('Нужны все четыре согласованных пакета DocSharp: DOC, Common, PPT и XLS.');
      for var Name in ReaderAdapterFiles(ID) do
        AddFile(Name,TPath.Combine(AdapterRuntime,Name));
      Metadata:=TJSONObject.Create;
      try
        Metadata.AddPair('version',Version); Metadata.AddPair('upstream','https://github.com/manfromarce/DocSharp');
        WriteJSON(ChildPath(Stage,'tools/doc/DOC_RUNTIME.json'),Metadata);
      finally Metadata.Free; end;
      AddFile('tools/doc/DOC_RUNTIME.json',ChildPath(Stage,'tools/doc/DOC_RUNTIME.json'));
      // JIT of the retained converter catches incompatible public API before installation.
      RunBounded(ChildPath(Stage,'tools/doc/HomeLibDoc.exe'),['--version']);
    end
    else
    begin
      Tools:=FindFullSevenZip(RuntimePath);
      if (ID='7-Zip') and (SecondaryArchive<>'') then
      begin
        AssertUpdatePath(SecondaryArchive);
        Tools:=ChildPath(Job,'7zr.exe'); TFile.Copy(SecondaryArchive,Tools,False);
      end;
      if not FileExists(Tools) then
        raise Exception.Create('Для подготовки этого компонента сначала скачайте 7-Zip в окне обновлений.');
      Raw:=ChildPath(Job,'official-files'); ForceDirectories(Raw);
      if ID='7-Zip' then Names:=TArray<string>.Create('7z.exe','7z.dll','License.txt')
      else Names:=TArray<string>.Create('ddjvu.exe','djvused.exe','libdjvulibre.dll','libjpeg.dll','libtiff.dll','libz.dll','COPYING.txt');
      var Arguments:=TArray<string>.Create('e',Archive,'-o'+Raw,'-y','-bd');
      Arguments:=Arguments+Names;
      // Extract selected members. The downloaded installer itself is never executed.
      RunBounded(Tools,Arguments);
      for var Name in Names do
        if ID='7-Zip' then AddFile('tools/7zip/'+Name,ChildPath(Raw,Name))
        else AddFile('tools/djvu/'+Name,ChildPath(Raw,Name));
      if ID='DjVuLibre' then
      begin
        for var Name in ReaderAdapterFiles(ID) do
          if Name<>'tools/djvu/COPYING.txt' then AddFile(Name,TPath.Combine(AdapterRuntime,Name));
        if SecondaryArchive='' then raise Exception.Create('Нет соответствующего исходного кода DjVuLibre.');
        AssertUpdatePath(SecondaryArchive);
        AddFile('tools/djvu/djvulibre-'+Version+'.tar.gz',SecondaryArchive);
        Metadata:=TJSONObject.Create; Hashes:=TJSONObject.Create;
        try
          Entry:=TJSONObject.Create; Entry.AddPair('version',Version); Entry.AddPair('files',Hashes); Metadata.AddPair('djvu',Entry);
          for var Name in Names do Hashes.AddPair(Name,UpdateSHA256(ChildPath(Stage,'tools/djvu/'+Name)));
          WriteJSON(ChildPath(Stage,'tools/djvu/RUNTIME.json'),Metadata);
        finally Metadata.Free; end;
        AddFile('tools/djvu/RUNTIME.json',ChildPath(Stage,'tools/djvu/RUNTIME.json'));
        var Probe:=ChildPath(Job,'decoder-probe'); ForceDirectories(Probe);
        for var Name in ['libdjvulibre.dll','libjpeg.dll','libtiff.dll','libz.dll'] do
          TFile.Copy(ChildPath(Stage,'tools/djvu/'+Name),ChildPath(Probe,Name),False);
        TFile.Copy(TPath.Combine(AdapterRuntime,'tools/djvu/HomeLibDjvu.exe'),ChildPath(Probe,'HomeLibDjvu.exe'),False);
        RunBounded(ChildPath(Probe,'HomeLibDjvu.exe'),['--self-test']);
      end;
    end;
    ManifestFiles(Manifest); VerifyPreparedProgramUpdateIdentity(Manifest,Stage,Version,Platform);
    WriteJSON(ChildPath(Job,'manifest.json'),Manifest);
  finally Manifest.Free; end;
end;

function PrepareProgramUpdate(const Archive, SHA256, Tag, Platform, Job: string;
  VerifyIdentity: Boolean; const ComponentID, ComponentVersion: string): TUpdateFiles;
var Zip: TZipFile; Root: TJSONObject; Bytes: TBytes; Names: TDictionary<string, Integer>;
  I, Index, Format: Integer; Name, Stage, Value, Component: string; Info: TUpdateFile;
begin
  AssertUpdatePath(Job); AssertUpdatePath(Archive);
  if not IsUpdateSHA256(SHA256) or (TFile.GetSize(Archive) > UPDATE_MAX_ARCHIVE) or
     not SameText(UpdateSHA256(Archive), SHA256) then
    raise Exception.Create('Архив обновления повреждён: контрольная сумма не совпадает.');
  Stage := ChildPath(Job, 'payload');
  if DirectoryExists(Stage) then raise Exception.Create('Обновление уже подготовлено в этой папке.');
  Zip := TZipFile.Create; Names := TDictionary<string, Integer>.Create; Root := nil;
  try
    Zip.Open(Archive, zmRead);
    if Zip.FileCount > 4001 then raise Exception.Create('Слишком много файлов в архиве обновления.');
    for I := 0 to Zip.FileCount - 1 do
    begin
      Name := Zip.FileNames[I];
      if ((Name <> UPDATE_MANIFEST) and not SafeUpdateName(Name)) or
         Names.ContainsKey(LowerCase(Name)) then
        raise Exception.Create('Недопустимый путь в архиве обновления: ' + Name);
      Names.Add(LowerCase(Name), I);
    end;
    if not Names.TryGetValue(LowerCase(UPDATE_MANIFEST), Index) or
       (Zip.FileInfo[Index].UncompressedSize > 1024 * 1024) then
      raise Exception.Create('В архиве нет манифеста обновления. Скачайте выпуск вручную.');
    Zip.Read(Index, Bytes);
    Root := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes)) as TJSONObject;
    Component:=ComponentID; if Component='' then Component:='HomeLib Ru';
    if (Root = nil) or not Root.TryGetValue<Integer>('format', Format) or (Format <> 1) then
      raise Exception.Create('Неизвестный формат манифеста обновления.');
    if not Root.TryGetValue<string>('release', Value) or (Value <> Tag) then
      raise Exception.Create('Пакет обновления относится к другому выпуску. Ожидается: '+Tag+
        '. Компонент: '+Component+'. Повторите проверку обновлений.');
    if not Root.TryGetValue<string>('platform', Value) or
       ((Value<>Platform) and not ((ComponentID='AlReader') and (Value='AnyWindows'))) then
      raise Exception.Create('Разрядность пакета обновления не подходит программе. Ожидается: '+Platform+'.');
    Component := ''; Root.TryGetValue<string>('component', Component);
    if Component <> ComponentID then raise Exception.Create('В архиве находится другое обновление.');
    if (ComponentID <> '') and (not Root.TryGetValue<string>('version', Value) or
       (Value <> ComponentVersion)) then raise Exception.Create('В архиве находится другая версия компонента.');
    // Only the x86 AlReader payload is shared across host architectures.
    if (ComponentID='AlReader') and (Value=ComponentVersion) and
      (Root.GetValue<string>('platform')='AnyWindows') then
    begin Root.RemovePair('platform').Free; Root.AddPair('platform',Platform); end;
    Result := ManifestFiles(Root);
    if Length(Result) + 1 <> Zip.FileCount then
      raise Exception.Create('Содержимое архива не совпадает с манифестом.');
    ForceDirectories(Stage);
    for Info in Result do
    begin
      if not Names.TryGetValue(LowerCase(Info.Name), Index) or
         (Int64(Zip.FileInfo[Index].UncompressedSize) <> Info.Size) then
        raise Exception.Create('Размер файла обновления не совпадает: ' + Info.Name);
      Zip.Read(Index, Bytes);
      if Length(Bytes) <> Info.Size then
        raise Exception.Create('Файл обновления повреждён: ' + Info.Name);
      Name := ChildPath(Stage, Info.Name); ForceDirectories(ExtractFileDir(Name));
      TFile.WriteAllBytes(Name, Bytes); Bytes := nil;
      if not SameText(UpdateSHA256(Name), Info.SHA256) then
        raise Exception.Create('Контрольная сумма файла не совпадает: ' + Info.Name);
    end;
    if VerifyIdentity then VerifyPreparedProgramUpdateIdentity(Root, Stage, Tag, Platform);
    WriteJSON(ChildPath(Job, 'manifest.json'), Root);
  finally Root.Free; Names.Free; Zip.Free; end;
end;

procedure VerifyPreparedProgramUpdate(const Job, Tag, Platform: string);
var Manifest: TJSONObject; Value: string; Bundle: TJSONArray; Zip: TZipFile; PackedBytes, Saved: TBytes;
begin
  Manifest := ReadJSON(ChildPath(Job, 'manifest.json'));
  try
    if not Manifest.TryGetValue<string>('release', Value) or (Value <> Tag) or
       not Manifest.TryGetValue<string>('platform', Value) or (Value <> Platform) then
      raise Exception.Create('Подготовленное обновление не подходит этой программе.');
    ManifestFiles(Manifest);
    if Manifest.TryGetValue<TJSONArray>('bundle', Bundle) then
    begin
      Zip := TZipFile.Create;
      try
        Zip.Open(ChildPath(Job, 'release.zip'), zmRead); Zip.Read(UPDATE_MANIFEST, PackedBytes);
        Saved := TFile.ReadAllBytes(ChildPath(Job, 'manifest.json'));
        if (Length(PackedBytes) <> Length(Saved)) or (Length(Saved) = 0) or
           not CompareMem(@PackedBytes[0], @Saved[0], Length(Saved)) then
          raise Exception.Create('Манифест пакета обновлений изменён.');
      finally Zip.Free; end;
    end;
    VerifyPreparedProgramUpdateIdentity(Manifest, ChildPath(Job, 'payload'), Tag, Platform);
  finally Manifest.Free; end;
end;

function PreparedProgramUpdateHelper(const Job, Tag, Platform, ExpectedSHA256: string): string;
var Manifest: TJSONObject; Info: TUpdateFile; Found: Boolean; Zip: TZipFile; Bytes: TBytes; PackedHash: THashSHA2;
begin
  if not IsUpdateSHA256(ExpectedSHA256) or
    not SameText(UpdateSHA256(ChildPath(Job,'release.zip')),ExpectedSHA256) then
    raise Exception.Create('Архив восстановления повреждён. Повторите загрузку.');
  VerifyPreparedProgramUpdate(Job,Tag,Platform);
  Manifest:=ReadJSON(ChildPath(Job,'manifest.json'));
  try
    Found:=False;
    for Info in ManifestFiles(Manifest) do
      if Info.Name='HomeLibRuUpdater.exe' then
      begin
        Result:=ChildPath(ChildPath(Job,'payload'),Info.Name);
        if (TFile.GetSize(Result)<>Info.Size) or not SameText(UpdateSHA256(Result),Info.SHA256) then
          raise Exception.Create('Файл механизма обновления повреждён. Повторите загрузку.');
        Found:=True; Break;
      end;
    if not Found then raise Exception.Create('Нужно скачать полный комплект HomeLib Ru для восстановления механизма обновления.');
    // Bind executable bytes to the verified download, not just to editable
    // extracted metadata. A loose or modified staged helper is never run.
    Zip:=TZipFile.Create;
    try
      Zip.Open(ChildPath(Job,'release.zip'),zmRead);
      Zip.Read('HomeLibRuUpdater.exe',Bytes);
      PackedHash:=THashSHA2.Create(THashSHA2.TSHA2Version.SHA256); PackedHash.Update(Bytes);
      if not SameText(PackedHash.HashAsString,UpdateSHA256(Result)) then
        raise Exception.Create('Механизм обновления не совпадает с проверенным архивом.');
    finally Zip.Free; end;
    VerifyUpdateExecutable(Result,Tag,Platform);
  finally Manifest.Free; end;
end;

procedure RollbackProgramUpdate(const Job, Target: string);
var Journal: TJSONObject; Files: TJSONArray; Value: TJSONValue;
  Name, OriginalTarget, Destination, Backup, State: string; Existed: Boolean; I: Integer;
begin
  Journal := ReadJSON(ChildPath(Job, 'journal.json'));
  try
    if not Journal.TryGetValue<string>('target', OriginalTarget) or
       not SameText(TPath.GetFullPath(Target), OriginalTarget) or
       not Journal.TryGetValue<TJSONArray>('files', Files) then
      raise Exception.Create('Не удалось прочитать резервную копию обновления.');
    if Journal.TryGetValue<string>('state', State) and (State = 'installed') then Exit;
    for I := Files.Count - 1 downto 0 do
    begin
      Value := Files.Items[I];
      if not (Value is TJSONObject) or
         not TJSONObject(Value).TryGetValue<string>('path', Name) or not SafeUpdateName(Name) or
         not TJSONObject(Value).TryGetValue<Boolean>('existed', Existed) then
        raise Exception.Create('Повреждён журнал обновления.');
      Destination := ChildPath(Target, Name); Backup := ChildPath(Job, 'backup/' + Name);
      if Existed then
      begin
        // An operation that failed before replacement must not overwrite an
        // unchanged locked DLL during rollback.
        if FileExists(Destination) and SameText(UpdateSHA256(Destination), UpdateSHA256(Backup)) then Continue;
        if not RetryUpdateFileOperation(function: Boolean
          begin Result:=CopyFile(PChar(Backup),PChar(Destination),False); end) then RaiseLastOSError;
      end
      else if FileExists(Destination) and not RetryUpdateFileOperation(function: Boolean
        begin Result:=DeleteFile(PChar(Destination)); end) then RaiseLastOSError;
    end;
    Journal.RemovePair('state').Free; Journal.AddPair('state', 'rolled-back');
    WriteJSON(ChildPath(Job, 'journal.json'), Journal);
  finally Journal.Free; end;
end;

procedure InstallProgramUpdate(const Job, Target: string;
  const Progress: TUpdateProgress; FailAfter: Integer);
const ComponentNames: array[0..19] of string = ('SQLite', 'AlReader', 'SumatraPDF','DjVuLibre','7-Zip','DocSharp','JPEG XL','WebP','HomeLibReader','PDFium','BookConverter','IBK','MHLMcpServer','Zstandard','BookProcessing','ImageProcessing','Kindle','LegacyBooks','LegacyOffice','XPS');
var Manifest, Journal, Entry: TJSONObject; Files: TUpdateFiles; List: TJSONArray;
  Info: TUpdateFile; Source, Destination, Backup, Temporary, State: string;
  Handle: THandle; Existed: Boolean; I, J, Applied, Comparison: Integer;
  ComponentID, ComponentPath, Folder: string;
begin
  AssertUpdatePath(Target); AssertUpdatePath(Job);
  if not FileExists(ChildPath(Target,'HomeLibRu.exe')) and not FileExists(ChildPath(Target,'HomeLibReader.exe')) then
    raise Exception.Create('В выбранной папке нет HomeLib Ru или HomeLib Reader.');
  if FileExists(ChildPath(Job, 'journal.json')) then
  begin
    Journal := ReadJSON(ChildPath(Job, 'journal.json'));
    try
      if Journal.TryGetValue<string>('state', State) and (State = 'installed') then Exit;
    finally Journal.Free; end;
    RollbackProgramUpdate(Job, Target);
    raise Exception.Create('Предыдущее обновление восстановлено. Проверьте обновления ещё раз.');
  end;
  Manifest := ReadJSON(ChildPath(Job, 'manifest.json'));
  try
    if Assigned(Manifest.GetValue('bundle')) then
      VerifyPreparedProgramUpdate(Job, Manifest.GetValue<string>('release'), ProgramUpdatePlatform);
    Files := ManifestFiles(Manifest);
  finally Manifest.Free; end;
  // A full application archive can bundle an older component than the user
  // has already installed independently. Preserve that whole component.
  for ComponentID in ComponentNames do
  begin
    ComponentPath := ComponentFileName(ComponentID);
    for I := 0 to High(Files) do
      if (Files[I].Name = ComponentPath) and not ComponentNeedsRepair(Target,ComponentID) and
         CompareComponentVersions(InstalledComponentVersion(Target,ComponentID),
           InstalledComponentVersion(ChildPath(Job,'payload'),ComponentID), Comparison) and
         (Comparison > 0) then
      begin
        Folder := Copy(ComponentPath, 1, LastDelimiter('/', ComponentPath));
        for J := 0 to High(Files) do
          if (Files[J].Name = ComponentPath) or
             ((Folder <> '') and Files[J].Name.StartsWith(Folder)) then Files[J].Skip := True;
        Break;
      end;
  end;
  // Update the main EXE last. The earlier EXE remains available during copying.
  for I := 0 to High(Files) do
    if SameText(Files[I].Name, 'HomeLibRu.exe') or SameText(Files[I].Name, 'HomeLibReader.exe') then
    begin Info := Files[High(Files)]; Files[High(Files)] := Files[I]; Files[I] := Info; Break; end;
  // Preflight every destination and back up every original before changing any.
  for Info in Files do
  begin
    Source := ChildPath(Job, 'payload/' + Info.Name); Destination := ChildPath(Target, Info.Name);
    if not FileExists(Source) or not SameText(UpdateSHA256(Source), Info.SHA256) then
      raise Exception.Create('Подготовленное обновление повреждено: ' + Info.Name);
    if Info.Skip or (Info.KeepExisting and FileExists(Destination)) then Continue;
    ForceDirectories(ExtractFileDir(Destination));
    if FileExists(Destination) then
    begin
      Handle := CreateFile(PChar(Destination), GENERIC_READ or GENERIC_WRITE, 0, nil,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
      if Handle = INVALID_HANDLE_VALUE then
        raise Exception.Create('Файл занят или недоступен. Закройте читалки и другие экземпляры программы: ' + Info.Name);
      CloseHandle(Handle);
      Backup := ChildPath(Job, 'backup/' + Info.Name); ForceDirectories(ExtractFileDir(Backup));
      if not CopyFile(PChar(Destination), PChar(Backup), False) then RaiseLastOSError;
    end;
    Temporary := Destination + '.homelibru-new'; AssertUpdatePath(Temporary);
    Handle := CreateFile(PChar(Temporary), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    CloseHandle(Handle); DeleteFile(PChar(Temporary));
  end;
  Journal := TJSONObject.Create; List := TJSONArray.Create;
  Journal.AddPair('target', TPath.GetFullPath(Target)); Journal.AddPair('state', 'installing');
  Journal.AddPair('files', List); Applied := 0;
  try
    WriteJSON(ChildPath(Job, 'journal.json'), Journal);
    try
      for Info in Files do
      begin
        Destination := ChildPath(Target, Info.Name); Existed := FileExists(Destination);
        if Info.Skip or (Info.KeepExisting and Existed) then Continue;
        if Assigned(Progress) then Progress('Обновление HomeLib Ru', Applied, Length(Files));
        Entry := TJSONObject.Create; Entry.AddPair('path', Info.Name);
        Entry.AddPair('existed', TJSONBool.Create(Existed)); List.AddElement(Entry);
        WriteJSON(ChildPath(Job, 'journal.json'), Journal);
        Source := ChildPath(Job, 'payload/' + Info.Name); Temporary := Destination + '.homelibru-new';
        if not CopyFile(PChar(Source), PChar(Temporary), True) then
        begin
          I := GetLastError;
          // CREATE_NEW preflight proved this is our temporary destination.
          // Do not remove a pre-existing file created by another process.
          if (I <> ERROR_FILE_EXISTS) and (I <> ERROR_ALREADY_EXISTS) then DeleteFile(PChar(Temporary));
          RaiseLastOSError(I);
        end;
        if not RetryUpdateFileOperation(function: Boolean
          begin Result:=MoveFileEx(PChar(Temporary),PChar(Destination),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH); end) then
        begin I := GetLastError; DeleteFile(PChar(Temporary)); RaiseLastOSError(I); end;
        Inc(Applied);
        if (FailAfter >= 0) and (Applied >= FailAfter) then
          raise Exception.Create('Имитированная ошибка установки');
      end;
      Journal.RemovePair('state').Free; Journal.AddPair('state', 'installed');
      WriteJSON(ChildPath(Job, 'journal.json'), Journal);
    except
      RollbackProgramUpdate(Job, Target);
      raise;
    end;
  finally Journal.Free; end;
end;

procedure CleanProgramUpdate(const Job: string);
var Root, Current: string;
  procedure RemoveOwnedDirectory(const Directory: string);
  var Item: string;
  begin
    AssertUpdatePathBelow(Directory,ExtractFileDir(Root));
    for Item in TDirectory.GetFiles(Directory) do
    begin AssertUpdatePathBelow(Item,ExtractFileDir(Root)); if not DeleteFile(PChar(Item)) then RaiseLastOSError; end;
    for Item in TDirectory.GetDirectories(Directory) do RemoveOwnedDirectory(Item);
    if not RemoveDir(Directory) then RaiseLastOSError;
  end;
begin
  Root := TPath.GetFullPath(Job); Current := ExtractFileName(Root);
  if not Current.StartsWith('HomeLibRu-update-') then
    raise Exception.Create('Отказ очистки посторонней папки обновления.');
  AssertUpdatePath(Root);
  if DirectoryExists(Root) then RemoveOwnedDirectory(Root);
end;

end.
