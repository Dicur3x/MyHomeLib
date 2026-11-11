unit unit_ReaderFonts;

interface

uses System.Classes, System.SysUtils;

procedure PrepareReaderFonts;
procedure LoadReaderProfileFonts(const SettingsFile: string);
procedure ImportReaderProfileFont(const SettingsFile, SourceFile: string);
procedure ReaderFontChoices(Names, Labels: TStrings; const Current: string;
  const SettingsFile: string = '');
function AvailableReaderFont(const Name: string): string;
function EnsureReaderFont(const Name: string): Boolean;
function DefaultReaderFont(const SettingsFile: string): string;
procedure ReaderFontLibraryNames(const SettingsFile: string; Names: TStrings);
procedure ReaderFontKnownNames(const SettingsFile: string; Names: TStrings);
function ReaderFontIsListed(const SettingsFile, Family: string): Boolean;
function ReaderFontSource(const SettingsFile, Family: string): string;
procedure AddReaderWindowsFont(const SettingsFile, Family: string);
procedure RequestReaderLibraryFont(const SettingsFile, Family: string);
procedure RemoveReaderFont(const SettingsFile, Family: string);

const ReaderFontPack: array[0..3] of string = ('PT Serif','PT Sans','Noto Serif','Noto Sans');

implementation

uses Winapi.Windows, System.IOUtils, System.Hash, System.IniFiles, System.JSON,
  Vcl.Forms, unit_ReaderFontDownloads, unit_AtomicIniFile, unit_FileMutex;

const MaxFontBytes = 32*1024*1024;

var LoadedFonts, LoadedFamilies: TStringList;
  Prepared: Boolean;

procedure EditFontLibrary(const SettingsFile: string; const Edit: TProc<TMemIniFile>);
var Lock: TFileMutex; Ini: TMemIniFile;
begin
  if SettingsFile='' then raise EWriteError.Create('Профиль читалки недоступен.');
  ForceDirectories(ExtractFileDir(ExpandFileName(SettingsFile)));
  Lock:=TFileMutex.Create(SettingsFile);
  try
    if not Lock.TryAcquire then
      raise EWriteError.Create('Настройки шрифтов сейчас заняты. Повторите действие.');
    Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
    try
      Edit(Ini);
      SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
  finally Lock.Free; end;
end;

procedure ReadFontNames(Ini: TCustomIniFile; const Key: string; Names: TStrings);
var Value: TJSONValue;
begin
  Names.Clear;
  Value:=TJSONObject.ParseJSONValue(Ini.ReadString('ReaderFontLibrary',Key,'[]'));
  try
    if Value is TJSONArray then
      for var Item in TJSONArray(Value) do
        if (Item is TJSONString) and (Item.Value<>'') and (Length(Item.Value)<=100) and
          (Names.IndexOf(Item.Value)<0) then Names.Add(Item.Value);
  finally Value.Free; end;
end;

procedure WriteFontNames(Ini: TCustomIniFile; const Key: string; Names: TStrings);
var Value: TJSONArray;
begin
  Value:=TJSONArray.Create;
  try
    for var Name in Names do Value.Add(Name);
    Ini.WriteString('ReaderFontLibrary',Key,Value.ToJSON);
  finally Value.Free; end;
end;

procedure FontFileFamilies(const Data: TBytes; Names: TStrings);
  function Fits(At, Count: UInt64): Boolean;
  begin Result:=(At<=UInt64(Length(Data))) and (Count<=UInt64(Length(Data))-At); end;
  function U16(At: Integer): Word;
  begin Result:=Word(Data[At]) shl 8 or Data[At+1]; end;
  function U32(At: Integer): Cardinal;
  begin Result:=Cardinal(Data[At]) shl 24 or Cardinal(Data[At+1]) shl 16 or
    Cardinal(Data[At+2]) shl 8 or Data[At+3]; end;
  procedure ReadFace(Offset: Cardinal);
  var At, Table, Size, Storage, RecordAt, TextAt, TextBytes: UInt64;
    NameID, Platform: Word; Name: string;
  begin
    if not Fits(Offset,12) then Exit;
    for var I:=0 to Integer(U16(Offset+4))-1 do
    begin
      At:=UInt64(Offset)+12+UInt64(I)*16;
      if not Fits(At,16) then Exit;
      if U32(At)<>$6E616D65 then Continue;
      Table:=U32(At+8); Size:=U32(At+12);
      if (Size<6) or not Fits(Table,Size) then Exit;
      Storage:=U16(Table+4);
      for var J:=0 to Integer(U16(Table+2))-1 do
      begin
        RecordAt:=6+UInt64(J)*12;
        if RecordAt+12>Size then Break;
        RecordAt:=Table+RecordAt;
        Platform:=U16(RecordAt); NameID:=U16(RecordAt+6);
        if not (NameID in [1,16]) or not (Platform in [0,3]) then Continue;
        TextBytes:=U16(RecordAt+8); TextAt:=Storage+U16(RecordAt+10);
        if (TextBytes=0) or Odd(TextBytes) or (TextAt+TextBytes>Size) then Continue;
        Name:=TEncoding.BigEndianUnicode.GetString(Data,Integer(Table+TextAt),Integer(TextBytes)).Trim;
        if (Name<>'') and (Length(Name)<=100) and not Name.Contains(#0) and
          (Names.IndexOf(Name)<0) then Names.Add(Name);
      end;
      Exit;
    end;
  end;
begin
  Names.Clear;
  if not Fits(0,12) then Exit;
  if U32(0)=$74746366 then
  begin
    var Faces:=U32(8);
    if not Fits(12,UInt64(Faces)*4) then Exit;
    for var I:=0 to Integer(Faces)-1 do ReadFace(U32(12+I*4));
  end
  else ReadFace(0);
end;

procedure RememberImportedFont(const SettingsFile, FileName: string; Names: TStrings);
begin
  EditFontLibrary(SettingsFile,
    procedure(Ini: TMemIniFile)
    var Active, Removed: TStringList; Values: TJSONArray;
    begin
      Active:=TStringList.Create; Removed:=TStringList.Create; Values:=TJSONArray.Create;
      try
        ReadFontNames(Ini,'Active',Active); ReadFontNames(Ini,'Removed',Removed);
        for var Name in Names do
          if (Screen.Fonts.IndexOf(Name)>=0) and not Name.StartsWith('@') then
          begin
            Values.Add(Name);
            if Active.IndexOf(Name)<0 then Active.Add(Name);
            var Index:=Removed.IndexOf(Name);
            if Index>=0 then Removed.Delete(Index);
          end;
        Ini.WriteString('ReaderFontFiles',ExtractFileName(FileName),Values.ToJSON);
        WriteFontNames(Ini,'Active',Active); WriteFontNames(Ini,'Removed',Removed);
      finally Values.Free; Removed.Free; Active.Free; end;
    end);
end;

function RegisterPrivateFont(const FileName: string): Boolean;
begin
  if LoadedFonts.IndexOf(FileName)>=0 then Exit(True);
  Result:=AddFontResourceEx(PChar(FileName),FR_PRIVATE,nil)>0;
  if Result then LoadedFonts.Add(FileName);
end;

function ReaderProfileFontFolder(const SettingsFile: string): string;
begin
  Result:=TPath.Combine(ExtractFileDir(ExpandFileName(SettingsFile)),'Fonts');
end;

function IsReaderFontExtension(const Extension: string): Boolean;
begin
  Result:=SameText(Extension,'.ttf') or SameText(Extension,'.otf');
end;

function EnsureReaderFont(const Name: string): Boolean;
const Styles: array[0..3] of string = ('Regular','Bold','Italic','BoldItalic');
var Prefix, Extension, FileName, Style: string;
begin
  if LoadedFamilies.IndexOf(Name)>=0 then Exit(Screen.Fonts.IndexOf(Name)>=0);
  Prefix:=ExtractFilePath(ParamStr(0))+'tools\fonts\'; Extension:='.ttf';
  if Name='PT Serif' then Prefix:=Prefix+'ptserif\PT_Serif-Web-'
  else if Name='PT Sans' then Prefix:=Prefix+'ptsans\PT_Sans-Web-'
  else if Name.StartsWith('Noto Serif CJK') or Name.StartsWith('Noto Sans CJK') then
  begin
    if Name.StartsWith('Noto Serif') then Prefix:=Prefix+'noto-cjk\NotoSerifCJK-'
    else Prefix:=Prefix+'noto-cjk\NotoSansCJK-';
    Extension:='.ttc';
  end
  else Prefix:=Prefix+'noto\'+Name.Replace(' ','')+'-';
  for Style in Styles do
  begin
    FileName:=Prefix+Style+Extension;
    if not FileExists(FileName) and (ReaderFontPrefix(Name)<>'') and ReaderFontFamilyCached(Name) then
      FileName:=TPath.Combine(ReaderFontCachePath,ReaderFontPrefix(Name).Replace('/',PathDelim)+Style+Extension);
    // Private resources require neither installation nor Windows settings.
    if FileExists(FileName) then RegisterPrivateFont(FileName);
  end;
  Screen.ResetFonts;
  Result:=Screen.Fonts.IndexOf(Name)>=0;
  if Result then LoadedFamilies.Add(Name);
end;

procedure PrepareReaderFonts;
begin
  if Prepared then Exit;
  Prepared:=True; LoadedFonts:=TStringList.Create; LoadedFamilies:=TStringList.Create;
  EnsureReaderFont('PT Serif'); EnsureReaderFont('PT Sans');
  EnsureReaderFont('Noto Serif'); EnsureReaderFont('Noto Sans');
  // Register other writing systems only when a book needs them.
end;

procedure LoadReaderProfileFonts(const SettingsFile: string);
var Folder, FileName: string; Entry: TSearchRec; Changed, Migrate: Boolean;
  Ini: TMemIniFile; Names: TStringList;
begin
  if SettingsFile='' then Exit;
  PrepareReaderFonts;
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try Migrate:=Ini.ReadInteger('ReaderFontLibrary','Version',0)=0; finally Ini.Free; end;
  Folder:=IncludeTrailingPathDelimiter(ReaderProfileFontFolder(SettingsFile));
  if FindFirst(Folder+'*',faAnyFile,Entry)<>0 then Exit;
  Changed:=False;
  try
    repeat
      if ((Entry.Attr and faDirectory)=0) and (Entry.Size>0) and (Entry.Size<=MaxFontBytes) and
         IsReaderFontExtension(ExtractFileExt(Entry.Name)) then
      begin
        FileName:=Folder+Entry.Name;
        if (LoadedFonts.IndexOf(FileName)<0) and RegisterPrivateFont(FileName) then Changed:=True;
        if Migrate then
        begin
          Screen.ResetFonts;
          Names:=TStringList.Create;
          try
            FontFileFamilies(TFile.ReadAllBytes(FileName),Names);
            RememberImportedFont(SettingsFile,FileName,Names);
          finally Names.Free; end;
        end;
      end;
    until FindNext(Entry)<>0;
  finally System.SysUtils.FindClose(Entry); end;
  if Changed then Screen.ResetFonts;
end;

procedure ImportReaderProfileFont(const SettingsFile, SourceFile: string);
var Extension, Folder, Destination, Temporary: string; Input, Output: TFileStream;
  Data: TBytes; Resource: THandle; Count: DWORD; Hash: THashSHA2; Names: TStringList;
begin
  if SettingsFile='' then raise EArgumentException.Create('Профиль читалки недоступен.');
  Extension:=LowerCase(ExtractFileExt(SourceFile));
  if not IsReaderFontExtension(Extension) then raise EReadError.Create('Выберите файл TTF или OTF.');
  Input:=TFileStream.Create(SourceFile,fmOpenRead or fmShareDenyWrite);
  try
    if (Input.Size<12) or (Input.Size>MaxFontBytes) then
      raise EReadError.Create('Файл шрифта повреждён или превышает 32 МБ.');
    SetLength(Data,Integer(Input.Size)); Input.ReadBuffer(Data[0],Length(Data));
  finally Input.Free; end;
  Resource:=AddFontMemResourceEx(@Data[0],Length(Data),nil,@Count);
  if Resource=0 then raise EReadError.Create('Windows не смогла прочитать этот шрифт.');
  RemoveFontMemResourceEx(Resource);

  // Different files with the same name can supply different styles. Publish
  // a complete copy once and reuse it if another reader imported it first.
  Hash:=THashSHA2.Create; Hash.Update(Data);
  Folder:=ReaderProfileFontFolder(SettingsFile);
  ForceDirectories(Folder);
  Destination:=TPath.Combine(Folder,Hash.HashAsString+Extension);
  if not FileExists(Destination) then
  begin
    Temporary:=TPath.Combine(Folder,TPath.GetRandomFileName+'.part');
    try
      Output:=TFileStream.Create(Temporary,fmCreate);
      try Output.WriteBuffer(Data[0],Length(Data)); finally Output.Free; end;
      if not MoveFileEx(PChar(Temporary),PChar(Destination),MOVEFILE_WRITE_THROUGH) and
        not FileExists(Destination) then RaiseLastOSError;
    finally if FileExists(Temporary) then DeleteFile(PChar(Temporary)); end;
  end;
  if THashSHA2.GetHashStringFromFile(Destination)<>Hash.HashAsString then
    raise EReadError.Create('В профиле обнаружена повреждённая копия этого шрифта.');
  PrepareReaderFonts;
  if not RegisterPrivateFont(Destination) then raise EReadError.Create('Не удалось загрузить шрифт в читалку.');
  Screen.ResetFonts;
  Names:=TStringList.Create;
  try
    FontFileFamilies(Data,Names);
    if Names.Count=0 then raise EReadError.Create('В файле не найдено название гарнитуры.');
    RememberImportedFont(SettingsFile,Destination,Names);
  finally Names.Free; end;
end;

function AvailableReaderFont(const Name: string): string;
begin
  PrepareReaderFonts;
  if (Name<>'') and (Screen.Fonts.IndexOf(Name)>=0) then Exit(Name);
  if Screen.Fonts.IndexOf('PT Serif')>=0 then Exit('PT Serif');
  Result:='Georgia';
end;

procedure InitializeFontLibrary(const SettingsFile, Current: string);
var Ini: TMemIniFile; Initialized: Boolean;
begin
  if SettingsFile='' then Exit;
  PrepareReaderFonts;
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try Initialized:=Ini.ReadInteger('ReaderFontLibrary','Version',0)>0; finally Ini.Free; end;
  if Initialized then Exit;
  EditFontLibrary(SettingsFile,
    procedure(Values: TMemIniFile)
    var Active: TStringList; Name: string;
      procedure Add(const Family: string);
      begin
        if (Family<>'') and not Family.StartsWith('@') and
          (Screen.Fonts.IndexOf(Family)>=0) and (Active.IndexOf(Family)<0) then Active.Add(Family);
      end;
    begin
      if Values.ReadInteger('ReaderFontLibrary','Version',0)>0 then Exit;
      Active:=TStringList.Create;
      try
        ReadFontNames(Values,'Active',Active);
        Name:=AvailableReaderFont('PT Serif'); Add(Name);
        Values.WriteString('ReaderFontLibrary','Default',Name);
        for var Family in ReaderFontPack do Add(Family);
        Add(Values.ReadString('Reader','FontName',Current)); Add(Current);
        WriteFontNames(Values,'Active',Active);
        Values.WriteInteger('ReaderFontLibrary','Version',1);
      finally Active.Free; end;
    end);
end;

procedure CompleteLibraryDownloads(const SettingsFile: string);
var Ini: TMemIniFile; Pending, Ready: TStringList;
begin
  if SettingsFile='' then Exit;
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  Pending:=TStringList.Create; Ready:=TStringList.Create;
  try
    ReadFontNames(Ini,'Pending',Pending);
    for var Family in Pending do
      if EnsureReaderFont(Family) then Ready.Add(Family);
    if Ready.Count=0 then Exit;
    EditFontLibrary(SettingsFile,
      procedure(Values: TMemIniFile)
      var Active, Removed, Waiting: TStringList;
      begin
        Active:=TStringList.Create; Removed:=TStringList.Create; Waiting:=TStringList.Create;
        try
          ReadFontNames(Values,'Active',Active); ReadFontNames(Values,'Removed',Removed);
          ReadFontNames(Values,'Pending',Waiting);
          for var Family in Ready do
          begin
            var Index:=Waiting.IndexOf(Family); if Index<0 then Continue;
            Waiting.Delete(Index);
            Index:=Removed.IndexOf(Family); if Index>=0 then Removed.Delete(Index);
            if Active.IndexOf(Family)<0 then Active.Add(Family);
          end;
          WriteFontNames(Values,'Active',Active); WriteFontNames(Values,'Removed',Removed);
          WriteFontNames(Values,'Pending',Waiting);
        finally Waiting.Free; Removed.Free; Active.Free; end;
      end);
  finally Ready.Free; Pending.Free; Ini.Free; end;
end;

function DefaultReaderFont(const SettingsFile: string): string;
var Ini: TMemIniFile;
begin
  Result:=AvailableReaderFont('PT Serif');
  if SettingsFile='' then Exit;
  InitializeFontLibrary(SettingsFile,'');
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try Result:=Ini.ReadString('ReaderFontLibrary','Default',Result); finally Ini.Free; end;
end;

procedure ReaderFontLibraryNames(const SettingsFile: string; Names: TStrings);
var Ini: TMemIniFile; Removed: TStringList; Default: string;
begin
  InitializeFontLibrary(SettingsFile,''); CompleteLibraryDownloads(SettingsFile); Names.Clear;
  if SettingsFile='' then
  begin
    Names.Add(AvailableReaderFont('PT Serif'));
    for var Family in ReaderFontPack do
      if (Screen.Fonts.IndexOf(Family)>=0) and (Names.IndexOf(Family)<0) then Names.Add(Family);
    Exit;
  end;
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8); Removed:=TStringList.Create;
  try
    ReadFontNames(Ini,'Active',Names); ReadFontNames(Ini,'Removed',Removed);
    Default:=Ini.ReadString('ReaderFontLibrary','Default',AvailableReaderFont('PT Serif'));
    for var I:=Names.Count-1 downto 0 do
      if (Removed.IndexOf(Names[I])>=0) and not SameText(Names[I],Default) then Names.Delete(I);
    var Index:=Names.IndexOf(Default);
    if Index>=0 then Names.Delete(Index);
    Names.Insert(0,Default);
  finally Removed.Free; Ini.Free; end;
end;

procedure ReaderFontKnownNames(const SettingsFile: string; Names: TStrings);
var Ini: TMemIniFile; Removed: TStringList;
begin
  ReaderFontLibraryNames(SettingsFile,Names);
  for var Family in ReaderFontPack do if Names.IndexOf(Family)<0 then Names.Add(Family);
  if SettingsFile='' then Exit;
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8); Removed:=TStringList.Create;
  try
    ReadFontNames(Ini,'Removed',Removed);
    for var Family in Removed do if Names.IndexOf(Family)<0 then Names.Add(Family);
  finally Removed.Free; Ini.Free; end;
end;

function ReaderFontIsListed(const SettingsFile, Family: string): Boolean;
var Names: TStringList;
begin
  Names:=TStringList.Create;
  try ReaderFontLibraryNames(SettingsFile,Names); Result:=Names.IndexOf(Family)>=0;
  finally Names.Free; end;
end;

function ReaderFontSource(const SettingsFile, Family: string): string;
var Ini: TMemIniFile; Files: TStringList; Value: TJSONValue;
begin
  if SameText(Family,DefaultReaderFont(SettingsFile)) then Exit('По умолчанию');
  for var Name in ReaderFontPack do if SameText(Family,Name) then Exit('Набор для чтения');
  if SettingsFile<>'' then
  begin
    Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8); Files:=TStringList.Create;
    try
      Ini.ReadSection('ReaderFontFiles',Files);
      for var Key in Files do
      begin
        Value:=TJSONObject.ParseJSONValue(Ini.ReadString('ReaderFontFiles',Key,''));
        try
          if Value is TJSONArray then
            for var Item in TJSONArray(Value) do
              if SameText(Item.Value,Family) then Exit('Ваш файл');
        finally Value.Free; end;
      end;
    finally Files.Free; Ini.Free; end;
  end;
  Result:='Windows';
end;

procedure AddReaderWindowsFont(const SettingsFile, Family: string);
begin
  PrepareReaderFonts;
  if (Family='') or (Length(Family)>100) or Family.StartsWith('@') or
    (Screen.Fonts.IndexOf(Family)<0) then raise EArgumentException.Create('Этот шрифт сейчас недоступен.');
  InitializeFontLibrary(SettingsFile,'');
  EditFontLibrary(SettingsFile,
    procedure(Ini: TMemIniFile)
    var Active, Removed: TStringList;
    begin
      Active:=TStringList.Create; Removed:=TStringList.Create;
      try
        ReadFontNames(Ini,'Active',Active); ReadFontNames(Ini,'Removed',Removed);
        if Active.IndexOf(Family)<0 then Active.Add(Family);
        var Index:=Removed.IndexOf(Family); if Index>=0 then Removed.Delete(Index);
        WriteFontNames(Ini,'Active',Active); WriteFontNames(Ini,'Removed',Removed);
      finally Removed.Free; Active.Free; end;
    end);
end;

procedure RemoveReaderFont(const SettingsFile, Family: string);
begin
  InitializeFontLibrary(SettingsFile,'');
  EditFontLibrary(SettingsFile,
    procedure(Ini: TMemIniFile)
    var Active, Removed: TStringList; Default: string;
    begin
      Default:=Ini.ReadString('ReaderFontLibrary','Default',AvailableReaderFont('PT Serif'));
      if SameText(Family,Default) then raise EArgumentException.Create('Шрифт по умолчанию нельзя убрать.');
      if ReaderFontRequestPending(Family) then raise EWriteError.Create('Дождитесь окончания загрузки этого шрифта.');
      Active:=TStringList.Create; Removed:=TStringList.Create;
      try
        ReadFontNames(Ini,'Active',Active); ReadFontNames(Ini,'Removed',Removed);
        var Index:=Active.IndexOf(Family); if Index>=0 then Active.Delete(Index);
        if Removed.IndexOf(Family)<0 then Removed.Add(Family);
        WriteFontNames(Ini,'Active',Active); WriteFontNames(Ini,'Removed',Removed);
        // Font choices persist independently of the appearance dialog. Keep
        // other Reader windows and Windows fonts intact; only this library changes.
        if SameText(Ini.ReadString('Reader','FontName',''),Family) then
          Ini.WriteString('Reader','FontName',Default);
      finally Removed.Free; Active.Free; end;
    end);
end;

procedure RequestReaderLibraryFont(const SettingsFile, Family: string);
begin
  if ReaderFontPrefix(Family)='' then raise EArgumentException.Create('Этот шрифт нельзя скачать из набора.');
  InitializeFontLibrary(SettingsFile,'');
  EditFontLibrary(SettingsFile,
    procedure(Ini: TMemIniFile)
    var Pending: TStringList;
    begin
      Pending:=TStringList.Create;
      try
        ReadFontNames(Ini,'Pending',Pending);
        if Pending.IndexOf(Family)<0 then Pending.Add(Family);
        WriteFontNames(Ini,'Pending',Pending);
      finally Pending.Free; end;
    end);
  RequestReaderFont(Family);
end;

procedure ReaderFontChoices(Names, Labels: TStrings; const Current, SettingsFile: string);
var LibraryNames: TStringList; Default, Description: string;
  procedure Add(const Name: string);
  begin
    if (Screen.Fonts.IndexOf(Name)<0) or (Names.IndexOf(Name)>=0) then Exit;
    Description:='';
    if SameText(Name,Default) then Description:='по умолчанию'
    else if (Name='PT Serif') or (Name='Noto Serif') then Description:='с засечками'
    else if (Name='PT Sans') or (Name='Noto Sans') then Description:='без засечек';
    Names.Add(Name);
    if Description='' then Labels.Add(Name) else Labels.Add(Name+' — '+Description);
  end;
begin
  PrepareReaderFonts; Names.Clear; Labels.Clear;
  InitializeFontLibrary(SettingsFile,Current);
  Default:=DefaultReaderFont(SettingsFile); LibraryNames:=TStringList.Create;
  try
    ReaderFontLibraryNames(SettingsFile,LibraryNames);
    for var Family in LibraryNames do Add(Family);
    if Names.Count=0 then Add(AvailableReaderFont('PT Serif'));
  finally LibraryNames.Free; end;
end;

procedure ReleaseReaderFonts;
var FileName: string;
begin
  if not Assigned(LoadedFonts) then Exit;
  for FileName in LoadedFonts do RemoveFontResourceEx(PChar(FileName),FR_PRIVATE,nil);
  FreeAndNil(LoadedFamilies); FreeAndNil(LoadedFonts);
end;

initialization
  Prepared:=False;

finalization
  ReleaseReaderFonts;

end.
