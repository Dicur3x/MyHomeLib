unit unit_BookSaveContinuation;

interface

uses System.SysUtils, unit_Globals, unit_BookSendOptions;

const WM_RESUME_BOOK_SAVE = $8000+370;

type
  TBookSaveContinuation = record
    Token, RequiredComponent, SourceFile, SourceStamp: string;
    Options: TBookSendOptions;
    Books: TBookIdList;
  end;

// Catalogue rows must carry the expected identities captured before export.
// These plans only reopen Save As; they never copy files without user review.
procedure StoreBookSaveContinuation(const SettingsFile, RequiredComponent: string;
  const Options: TBookSendOptions; const Remaining: TBookIdList; const SourceFile: string = '');
procedure ArmBookSaveContinuation(const SettingsFile, InstallingComponent: string);
procedure DisarmBookSaveContinuation(const SettingsFile: string);
function TakeBookSaveContinuation(const SettingsFile: string; out Value: TBookSaveContinuation): Boolean;
procedure ClearBookSaveContinuation(const SettingsFile, Token: string);
function BookSaveContinuationFile(const SettingsFile: string): string;

implementation

uses System.Classes, System.IOUtils, System.JSON, System.DateUtils,
  Winapi.Windows, unit_AtomicIniFile, unit_ComponentUpdates, unit_Templater,
  unit_BookConversion, unit_Helpers, unit_BookSavePolicy, unit_BookOutput;

const MAX_PLAN_BYTES = 64*1024*1024;
  MAX_LINE_CHARS = 16384;
  PROCESS_QUERY_LIMITED_INFORMATION_ACCESS = $1000;

function BookSaveContinuationFile(const SettingsFile: string): string;
begin Result:=TPath.GetFullPath(SettingsFile)+'.pending-save.jsonl'; end;

function ProcessStamp(Handle: THandle): string;
var Created, Exited, Kernel, User: TFileTime;
begin
  Result:='';
  if GetProcessTimes(Handle,Created,Exited,Kernel,User) then
    Result:=IntToStr(Created.dwHighDateTime)+':'+IntToStr(Created.dwLowDateTime);
end;

function OwnerRunning(PID: Cardinal; const Stamp: string): Boolean;
var Handle: THandle;
begin
  Result:=False; Handle:=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION_ACCESS or SYNCHRONIZE,False,PID);
  if Handle=0 then Exit;
  try Result:=(WaitForSingleObject(Handle,0)=WAIT_TIMEOUT) and (ProcessStamp(Handle)=Stamp);
  finally CloseHandle(Handle); end;
end;

function FileStamp(const FileName: string): string;
var Info: TWin32FileAttributeData;
begin
  if not GetFileAttributesEx(PChar(FileName),GetFileExInfoStandard,@Info) or
    ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY)<>0) then
    raise Exception.Create('Исходный файл сохранения больше недоступен. Выберите книгу заново.');
  Result:=IntToStr(Info.nFileSizeHigh)+':'+IntToStr(Info.nFileSizeLow)+'|'+
    IntToStr(Info.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Info.ftLastWriteTime.dwLowDateTime);
end;

function ReadLine(Reader: TStreamReader): TJSONObject;
var Line: string; Parsed: TJSONValue;
begin
  Result:=nil;
  if Reader.EndOfStream then raise Exception.Create('План сохранения оборван. Выберите книги заново.');
  Line:=Reader.ReadLine;
  if (Length(Line)=0) or (Length(Line)>MAX_LINE_CHARS) then
    raise Exception.Create('Некорректная строка плана сохранения.');
  Parsed:=TJSONObject.ParseJSONValue(Line);
  if not (Parsed is TJSONObject) then
  begin Parsed.Free; raise Exception.Create('Повреждён план сохранения.'); end;
  Result:=TJSONObject(Parsed);
end;

function Text(Value: TJSONObject; const Name: string; Maximum: Integer; Empty: Boolean = False): string;
var Field: TJSONValue;
begin
  Field:=Value.GetValue(Name);
  if not (Field is TJSONString) then raise Exception.Create('Некорректное поле плана сохранения: '+Name+'.');
  Result:=Field.Value;
  if ((Result='') and not Empty) or (Length(Result)>Maximum) or (Pos(#0,Result)>0) then
    raise Exception.Create('Некорректное значение плана сохранения: '+Name+'.');
end;

function Number(Value: TJSONObject; const Name: string; Minimum, Maximum: Int64): Int64;
var Field: TJSONValue;
begin
  Field:=Value.GetValue(Name);
  if not (Field is TJSONNumber) or not TryStrToInt64(Field.Value,Result) or
    (Result<Minimum) or (Result>Maximum) then raise Exception.Create('Некорректное число плана сохранения: '+Name+'.');
end;

function Flag(Value: TJSONObject; const Name: string): Boolean;
var Field: TJSONValue;
begin
  Field:=Value.GetValue(Name);
  if not (Field is TJSONBool) then raise Exception.Create('Некорректный переключатель плана сохранения: '+Name+'.');
  Result:=TJSONBool(Field).AsBoolean;
end;

procedure CheckOptions(const Options: TBookSendOptions);
var Templater: TTemplater; Parts: TArray<string>;
begin
  if not (Options.Mode in [emFB2,emFB2Zip,emEpub]) or
    not (Options.NameCollision in [bncAsk,bncReplace,bncKeepBoth]) or
    (Options.KeepSourceFormat and Options.KeepFB2EPUB) or
    (Options.Folder='') or (Length(Options.Folder)>4096) or
    (not IsShellPath(Options.Folder) and not TPath.IsPathRooted(Options.Folder)) then
    raise Exception.Create('Некорректные параметры сохранения книг.');
  Templater:=TTemplater.Create;
  try
    if (Trim(Options.FileNameTemplate)='') or (Length(Options.FileNameTemplate)>2048) or
      (Templater.SetTemplate(Options.FileNameTemplate,TpFile)<>ErFine) then
      raise Exception.Create('Некорректная маска имени сохранения.');
  finally Templater.Free; end;
  if not IsValidBookSaveFolderTemplate(Options.FolderTemplate) then
    raise Exception.Create('Некорректная маска подпапок в плане сохранения.');
  Parts:=Options.ImageQuality.Split(['|']);
  if (Length(Parts)<1) or (Length(Parts)>3) or
    ((Parts[0]<>'original') and (Parts[0]<>'balanced') and (Parts[0]<>'economy') and (Parts[0]<>'none')) or
    ((Length(Parts)>1) and ((Parts[0]='none') or ((Parts[1]<>'split') and (Parts[1]<>'auto')))) or
    ((Length(Parts)>2) and (not Parts[2].StartsWith('except=') or
      not IsValidScanPageExclusions(Parts[2].Substring(7)))) then
    raise Exception.Create('Некорректная обработка изображений в плане сохранения.');
end;

procedure DisarmBookSaveContinuation(const SettingsFile: string);
var Name: string;
begin
  Name:=BookSaveContinuationFile(SettingsFile)+'.ready';
  if FileExists(Name) and not Winapi.Windows.DeleteFile(PChar(Name)) then RaiseLastOSError;
end;

procedure StoreBookSaveContinuation(const SettingsFile, RequiredComponent: string;
  const Options: TBookSendOptions; const Remaining: TBookIdList; const SourceFile: string);
var Name, Temporary, Token: string; Stream: TFileStream; Root, Row: TJSONObject;
  procedure WriteLine(Value: TJSONObject);
  var Bytes: TBytes;
  begin
    Bytes:=TEncoding.UTF8.GetBytes(Value.ToJSON+#10);
    if (Length(Bytes)>MAX_LINE_CHARS*4) or (Stream.Size+Length(Bytes)>MAX_PLAN_BYTES) then
      raise Exception.Create('План сохранения слишком большой. Сохраните книги несколькими подборками.');
    Stream.WriteBuffer(Bytes[0],Length(Bytes));
  end;
begin
  CheckOptions(Options);
  if not IsOptionalComponent(RequiredComponent) or ((SourceFile='') and (Length(Remaining)=0)) or
    ((SourceFile<>'') and (Length(Remaining)<>0)) then raise Exception.Create('Не определены книги для продолжения сохранения.');
  Token:=TGUID.NewGuid.ToString; Name:=BookSaveContinuationFile(SettingsFile);
  Temporary:=Name+'.new-'+Token;
  DisarmBookSaveContinuation(SettingsFile);
  if FileExists(Temporary) then raise Exception.Create('Временный план сохранения уже существует.');
  Stream:=TFileStream.Create(Temporary,fmCreate);
  try
    Root:=TJSONObject.Create;
    try
      Root.AddPair('schema',TJSONNumber.Create(1)); Root.AddPair('token',Token);
      Root.AddPair('component',RequiredComponent); Root.AddPair('created',DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True));
      Root.AddPair('owner',TJSONNumber.Create(GetCurrentProcessId)); Root.AddPair('owner_stamp',ProcessStamp(GetCurrentProcess));
      Root.AddPair('count',TJSONNumber.Create(Length(Remaining))); Root.AddPair('source',SourceFile);
      var Stamp:=''; if SourceFile<>'' then Stamp:=FileStamp(SourceFile);
      Root.AddPair('source_stamp',Stamp); Root.AddPair('folder',Options.Folder);
      Root.AddPair('mode',TJSONNumber.Create(Ord(Options.Mode))); Root.AddPair('keep',TJSONBool.Create(Options.KeepSourceFormat));
      Root.AddPair('keep_readable',TJSONBool.Create(Options.KeepFB2EPUB)); Root.AddPair('zip',TJSONBool.Create(Options.ZipEachBook));
      Root.AddPair('name_collision',TJSONNumber.Create(Ord(Options.NameCollision)));
      Root.AddPair('images',Options.ImageQuality); Root.AddPair('mask',Options.FileNameTemplate);
      Root.AddPair('subfolders',Options.FolderTemplate);
      WriteLine(Root);
    finally Root.Free; end;
    for var Entry in Remaining do
    begin
      if not Entry.HasExpectedIdentity or ((Entry.ExpectedLibID='') and (Entry.ExpectedPhysicalIdentity='')) then
        raise Exception.Create('Не сохранены исходные сведения о книге. Выберите книги заново.');
      Row:=TJSONObject.Create;
      try
        Row.AddPair('collection',TJSONNumber.Create(Entry.BookKey.DatabaseID));
        Row.AddPair('book',TJSONNumber.Create(Entry.BookKey.BookID));
        Row.AddPair('libid',Entry.ExpectedLibID); Row.AddPair('physical',Entry.ExpectedPhysicalIdentity);
        WriteLine(Row);
      finally Row.Free; end;
    end;
    SaveStreamAtomically(Stream,Name);
  finally Stream.Free; Winapi.Windows.DeleteFile(PChar(Temporary)); end;
end;

function OpenPlan(const Name: string): TStreamReader;
var Stream: TFileStream;
begin
  Stream:=TFileStream.Create(Name,fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size<=0) or (Stream.Size>MAX_PLAN_BYTES) then raise Exception.Create('Некорректный размер плана сохранения.');
    Result:=TStreamReader.Create(Stream,TEncoding.UTF8,True,4096);
    Result.OwnStream;
  except Stream.Free; raise; end;
end;

procedure ArmBookSaveContinuation(const SettingsFile, InstallingComponent: string);
var Reader: TStreamReader; Root: TJSONObject; Stream: TStringStream; Name, Token: string;
begin
  Name:=BookSaveContinuationFile(SettingsFile); if not FileExists(Name) then Exit;
  Reader:=OpenPlan(Name);
  try
    Root:=ReadLine(Reader);
    try
      if (Number(Root,'owner',1,High(Cardinal))<>GetCurrentProcessId) or
        (Text(Root,'owner_stamp',64)<>ProcessStamp(GetCurrentProcess)) then Exit;
      var Required:=Text(Root,'component',128);
      if (Required<>InstallingComponent) and not ((Required='DjVuLibre') and (InstallingComponent='7-Zip')) and
        not ((Required='BookConverter') and (InstallingComponent='BookProcessing')) then Exit;
      Token:=Text(Root,'token',64);
    finally Root.Free; end;
  finally Reader.Free; end;
  Stream:=TStringStream.Create(Token,TEncoding.UTF8);
  try SaveStreamAtomically(Stream,Name+'.ready'); finally Stream.Free; end;
end;

function TakeBookSaveContinuation(const SettingsFile: string; out Value: TBookSaveContinuation): Boolean;
var Name, Ready, Claimed, Token: string; Reader: TStreamReader; Root, Row: TJSONObject;
  Count: Integer; Created: TDateTime;
begin
  Result:=False; Value:=Default(TBookSaveContinuation); Name:=BookSaveContinuationFile(SettingsFile);
  Ready:=Name+'.ready'; if not FileExists(Ready) or not FileExists(Name) then Exit;
  Reader:=OpenPlan(Name);
  try
    Root:=ReadLine(Reader);
    try
      if Number(Root,'schema',1,1)<>1 then Exit;
      Token:=Text(Root,'token',64);
      if OwnerRunning(Number(Root,'owner',1,High(Cardinal)),Text(Root,'owner_stamp',64)) then Exit;
      if (TFile.GetSize(Ready)>256) or (TFile.ReadAllText(Ready,TEncoding.UTF8)<>Token) then Exit;
      Claimed:=Ready+'.claimed-'+TGUID.NewGuid.ToString;
      if not MoveFile(PChar(Ready),PChar(Claimed)) then Exit;
      try
        Value.Token:=Token; Value.RequiredComponent:=Text(Root,'component',128);
        if not IsOptionalComponent(Value.RequiredComponent) then raise Exception.Create('Неизвестный компонент в плане сохранения.');
        Created:=ISO8601ToDate(Text(Root,'created',64),True);
        var NowUTC:=TTimeZone.Local.ToUniversalTime(Now);
        if (Created<IncDay(NowUTC,-7)) or (Created>IncMinute(NowUTC,5)) then
          raise Exception.Create('План сохранения устарел. Выберите книги заново.');
        Value.SourceFile:=Text(Root,'source',4096,True); Value.SourceStamp:=Text(Root,'source_stamp',128,True);
        Value.Options.Folder:=Text(Root,'folder',4096);
        Value.Options.Mode:=TExportMode(Number(Root,'mode',Ord(Low(TExportMode)),Ord(High(TExportMode))));
        Value.Options.KeepSourceFormat:=Flag(Root,'keep'); Value.Options.KeepFB2EPUB:=Flag(Root,'keep_readable');
        Value.Options.ZipEachBook:=Flag(Root,'zip'); Value.Options.ImageQuality:=Text(Root,'images',1024);
        if Root.GetValue('name_collision')<>nil then
          Value.Options.NameCollision:=TBookNameCollision(Number(Root,'name_collision',Ord(bncAsk),Ord(bncKeepBoth)))
        else if (Root.GetValue('overwrite')<>nil) and Flag(Root,'overwrite') then
          Value.Options.NameCollision:=bncReplace;
        Value.Options.FileNameTemplate:=Text(Root,'mask',2048); Value.Options.ScriptIndex:=-1;
        Value.Options.FolderTemplate:=Text(Root,'subfolders',2048,True);
        Value.Options.ExplicitFormat:=not Value.Options.KeepSourceFormat;
        Value.Options.UseMTP:=IsShellPath(Value.Options.Folder); CheckOptions(Value.Options);
        // Even a smallest valid row needs more than 64 bytes. Bound the
        // allocation by this particular file before trusting its count.
        Count:=Number(Root,'count',0,TFile.GetSize(Name) div 64);
        if (Value.SourceFile<>'') then
        begin
          if (Count<>0) or (Value.SourceStamp<>FileStamp(Value.SourceFile)) then
            raise Exception.Create('Исходный файл изменился после остановки сохранения. Выберите его заново.');
        end
        else if Count=0 then raise Exception.Create('В плане сохранения нет книг.');
        SetLength(Value.Books,Count);
        for var I:=0 to Count-1 do
        begin
          Row:=ReadLine(Reader);
          try
            Value.Books[I].BookKey:=CreateBookKey(Number(Row,'book',1,High(Integer)),Number(Row,'collection',1,High(Integer)));
            Value.Books[I].ExpectedLibID:=Text(Row,'libid',2048,True);
            Value.Books[I].ExpectedPhysicalIdentity:=Text(Row,'physical',8192,True);
            Value.Books[I].HasExpectedIdentity:=True;
            if (Value.Books[I].ExpectedLibID='') and (Value.Books[I].ExpectedPhysicalIdentity='') then
              raise Exception.Create('Не определена исходная книга в плане сохранения.');
          finally Row.Free; end;
        end;
        if not Reader.EndOfStream then raise Exception.Create('Лишние данные в плане сохранения.');
        Result:=True;
      finally Winapi.Windows.DeleteFile(PChar(Claimed)); end;
    finally Root.Free; end;
  finally Reader.Free; end;
end;

procedure ClearBookSaveContinuation(const SettingsFile, Token: string);
var Name: string; Reader: TStreamReader; Root: TJSONObject; Matches: Boolean;
begin
  Name:=BookSaveContinuationFile(SettingsFile); if not FileExists(Name) then Exit;
  Reader:=OpenPlan(Name);
  try Root:=ReadLine(Reader); try Matches:=Text(Root,'token',64)=Token; finally Root.Free; end;
  finally Reader.Free; end;
  if not Matches then Exit;
  DisarmBookSaveContinuation(SettingsFile);
  if not Winapi.Windows.DeleteFile(PChar(Name)) then RaiseLastOSError;
end;

end.
