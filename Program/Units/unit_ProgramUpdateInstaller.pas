unit unit_ProgramUpdateInstaller;

// The updater manages only distribution files. User data is never an input
// to a recursive copy/delete operation. The journal is written before changes.
interface

uses System.SysUtils, System.Classes;

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
function SafeUpdateName(const Name: string): Boolean;
procedure AssertUpdatePath(const Path: string);
function PrepareProgramUpdate(const Archive, SHA256, Tag, Platform, Job: string;
  VerifyIdentity: Boolean = True; const ComponentID: string = '';
  const ComponentVersion: string = ''): TUpdateFiles;
function UpdateFileVersion(const FileName: string): string;
function CompareComponentVersions(const Left, Right: string; out Comparison: Integer): Boolean;
function ComponentFileName(const ID: string): string;
function SafeComponentFile(const ID, Name: string): Boolean;
procedure InstallProgramUpdate(const Job, Target: string;
  const Progress: TUpdateProgress = nil; FailAfter: Integer = -1);
procedure RollbackProgramUpdate(const Job, Target: string);
procedure CleanProgramUpdate(const Job: string);
function ProgramUpdatePlatform: string;
procedure VerifyPreparedProgramUpdate(const Job, Tag, Platform: string);
procedure PrepareOfficialComponent(const Archive, Job, ID, Version, Platform: string);
function CombinePreparedProgramUpdates(const Jobs: TArray<string>;
  const Tag, Platform, Job: string): string;
function PreparedComponentsNewer(const Job, AppPath: string): Boolean;

implementation

uses System.IOUtils, System.Hash, System.JSON, System.Zip,
  System.Generics.Collections, Winapi.Windows, System.RegularExpressions, unit_UpdateAuthenticity;

function ComponentFileName(const ID: string): string;
begin
  Result := '';
  if ID = 'SQLite' then Result := 'sqlite3.dll';
  if ID = 'AlReader' then Result := 'Readers/AlReader/AlReader2.exe';
  if ID = 'SumatraPDF' then Result := 'Readers/SumatraPDF/SumatraPDF.exe';
end;

function SafeComponentFile(const ID, Name: string): Boolean;
var Base: string;
begin
  Result := SafeUpdateName(Name);
  if not Result then Exit;
  if ID = 'SQLite' then Exit(Name = 'sqlite3.dll');
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
    Result := (Lower = 'homelibru.exe') or (Lower = 'homelibruupdater.exe') or
      (Lower = 'mhlmcpserver.exe') or (Lower = 'sqlite3.dll') or
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

procedure AssertUpdatePath(const Path: string);
var Current, Parent: string; Attributes: DWORD;
begin
  Current := ExcludeTrailingPathDelimiter(TPath.GetFullPath(Path));
  if Length(Current) <= 3 then
    raise Exception.Create('Нельзя обновлять корневую папку диска.');
  repeat
    Attributes := GetFileAttributes(PChar(Current));
    if (Attributes <> INVALID_FILE_ATTRIBUTES) and
       ((Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
      raise Exception.Create('Папка обновления содержит ссылку: ' + Current);
    Parent := ExtractFileDir(Current);
    if (Parent = Current) or (Length(Parent) < 3) then Break;
    Current := Parent;
  until False;
end;

function ChildPath(const Root, Name: string): string;
var Prefix: string;
begin
  Prefix := IncludeTrailingPathDelimiter(TPath.GetFullPath(Root));
  Result := TPath.GetFullPath(Prefix + StringReplace(Name, '/', PathDelim, [rfReplaceAll]));
  if not Result.StartsWith(Prefix, True) then
    raise Exception.Create('Недопустимый путь в обновлении: ' + Name);
  AssertUpdatePath(Result);
end;

procedure WriteJSON(const FileName: string; Value: TJSONObject);
var Temp: string;
begin
  Temp := FileName + '.new';
  TFile.WriteAllText(Temp, Value.ToJSON, TEncoding.UTF8);
  if not MoveFileEx(PChar(Temp), PChar(FileName), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
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
begin
  Component := ''; Root.TryGetValue<string>('component', Component);
  Bundle := nil; Root.TryGetValue<TJSONArray>('bundle', Bundle);
  if Component = 'batch' then
  begin
    if not Assigned(Bundle) or (Bundle.Count < 1) or (Bundle.Count > 2) then
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
      if (Bundle.Count < 1) or (Bundle.Count > 2) then raise Exception.Create('Некорректный пакет компонентов.');
      for Part in Bundle do
      begin
        if not (Part is TJSONObject) or not TJSONObject(Part).TryGetValue<string>('component', Version) or
           not ((Version = 'SQLite') or (Version = 'SumatraPDF')) or IDs.ContainsKey(Version) or
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
  finally IDs.Free; Names.Free; end;
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
    if Component = 'AlReader' then Architecture := 'Win32';
    VerifyUpdateExecutable(ChildPath(Stage, ComponentFileName(Component)), Version, Architecture, True);
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
  if (Length(Jobs) < 2) or (Length(Jobs) > 3) or DirectoryExists(Job) then
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
          if (Component <> 'SQLite') and (Component <> 'SumatraPDF') then
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
      Installed := UpdateFileVersion(ChildPath(AppPath, ComponentFileName(ID)));
      if (Installed = '') or
         (CompareComponentVersions(Version, Installed, Comparison) and (Comparison > 0)) then Exit(True);
    end;
  finally Manifest.Free; end;
end;

procedure PrepareOfficialComponent(const Archive, Job, ID, Version, Platform: string);
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
    if (Root = nil) or not Root.TryGetValue<Integer>('format', Format) or (Format <> 1) or
       not Root.TryGetValue<string>('release', Value) or (Value <> Tag) or
       not Root.TryGetValue<string>('platform', Value) or (Value <> Platform) then
      raise Exception.Create('Манифест обновления не подходит этой версии программы.');
    Component := ''; Root.TryGetValue<string>('component', Component);
    if Component <> ComponentID then raise Exception.Create('В архиве находится другое обновление.');
    if (ComponentID <> '') and (not Root.TryGetValue<string>('version', Value) or
       (Value <> ComponentVersion)) then raise Exception.Create('В архиве находится другая версия компонента.');
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
        if not CopyFile(PChar(Backup), PChar(Destination), False) then RaiseLastOSError;
      end
      else if FileExists(Destination) and not DeleteFile(PChar(Destination)) then RaiseLastOSError;
    end;
    Journal.RemovePair('state').Free; Journal.AddPair('state', 'rolled-back');
    WriteJSON(ChildPath(Job, 'journal.json'), Journal);
  finally Journal.Free; end;
end;

procedure InstallProgramUpdate(const Job, Target: string;
  const Progress: TUpdateProgress; FailAfter: Integer);
const ComponentNames: array[0..2] of string = ('SQLite', 'AlReader', 'SumatraPDF');
var Manifest, Journal, Entry: TJSONObject; Files: TUpdateFiles; List: TJSONArray;
  Info: TUpdateFile; Source, Destination, Backup, Temporary, State: string;
  Handle: THandle; Existed: Boolean; I, J, Applied, Comparison: Integer;
  ComponentID, ComponentPath, Folder: string;
begin
  AssertUpdatePath(Target); AssertUpdatePath(Job);
  if not FileExists(ChildPath(Target, 'HomeLibRu.exe')) then
    raise Exception.Create('В выбранной папке нет HomeLib Ru.');
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
      if (Files[I].Name = ComponentPath) and
         CompareComponentVersions(UpdateFileVersion(ChildPath(Target, ComponentPath)),
           UpdateFileVersion(ChildPath(Job, 'payload/' + ComponentPath)), Comparison) and
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
    if SameText(Files[I].Name, 'HomeLibRu.exe') then
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
        if not MoveFileEx(PChar(Temporary), PChar(Destination), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
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
    AssertUpdatePath(Directory);
    for Item in TDirectory.GetFiles(Directory) do
    begin AssertUpdatePath(Item); if not DeleteFile(PChar(Item)) then RaiseLastOSError; end;
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
