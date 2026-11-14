unit unit_BookCompressionContinuation;

interface

uses System.SysUtils, unit_Globals, unit_Interfaces, unit_CollectionPacking,
  unit_BookCompressionOperation;

const
  BOOK_COMPRESSION_RESUME_SWITCH = '--resume-book-compression=';
  WM_RESUME_BOOK_COMPRESSION = $8000+373;

type
  TCompressionResumeScope = (crsCollection, crsNew, crsSelected);
  TCompressionResumeBook = record
    ID: Integer;
    LibID, Physical, Source, SourceIdentity: string;
  end;
  TBookCompressionContinuation = record
    Identity: TCollectionPackingRequest;
    Scope: TCompressionResumeScope;
    Options: TBookCompressionOperationOptions;
    Books: TArray<TCompressionResumeBook>;
  end;
  PBookCompressionContinuation = ^TBookCompressionContinuation;

function CaptureCompressionContinuation(const Identity: TCollectionPackingRequest;
  Scope: TCompressionResumeScope; const Options: TBookCompressionOperationOptions;
  const Books: TArray<TBookRecord>): TBookCompressionContinuation;
function ResolveCompressionContinuationBooks(const Request: TBookCompressionContinuation;
  const Collection: IBookCollection): TArray<TBookRecord>;
function StoreCompressionContinuation(const SettingsFile: string;
  const Request: TBookCompressionContinuation): string;
function TakeCompressionContinuation(const SettingsFile, Argument: string;
  out Request: TBookCompressionContinuation): Boolean;

implementation

uses System.Classes, System.IOUtils, System.JSON, System.DateUtils, System.StrUtils,
  Winapi.Windows, unit_AtomicIniFile, unit_ReaderCache, unit_ZipMemberDeletion;

const MAX_PLAN_BYTES = 64*1024*1024;
  MAX_LINE_CHARS = 32768;

function PlanFile(const SettingsFile: string): string;
begin Result:=TPath.GetFullPath(SettingsFile)+'.pending-compression.jsonl'; end;

function SourceStamp(const Name: string): string;
begin
  Result:='';
  if FileExists(Name) then Result:=ArchiveDeletionSourceIdentity(Name);
end;

procedure CheckOptions(const Options: TBookCompressionOperationOptions);
begin
  if not MatchStr(Options.Profile,['original','balanced','economy','maximum']) or
    (Options.WorkRoot='') or not TPath.IsPathRooted(Options.WorkRoot) or
    (Length(Options.WorkRoot)>4096) or Options.WorkRoot.Contains(#0) or
    (Length(Options.BackupFolder)>4096) or Options.BackupFolder.Contains(#0) or
    ((Options.BackupFolder<>'') and not TPath.IsPathRooted(Options.BackupFolder)) or
    (Options.BackupOriginals and (Options.BackupFolder='')) then
    raise EReadError.Create('Повреждены настройки продолжения сжатия. Выберите их заново.');
end;

function CaptureCompressionContinuation(const Identity: TCollectionPackingRequest;
  Scope: TCompressionResumeScope; const Options: TBookCompressionOperationOptions;
  const Books: TArray<TBookRecord>): TBookCompressionContinuation;
begin
  CheckOptions(Options);
  if (Scope=crsSelected)<>(Length(Books)>0) then
    raise EArgumentException.Create('Не определена подборка для продолжения сжатия.');
  Result:=Default(TBookCompressionContinuation);
  Result.Identity:=Identity; Result.Identity.CaptureIdentity;
  Result.Scope:=Scope; Result.Options:=Options;
  Result.Options.OnlyNew:=Scope=crsNew;
  SetLength(Result.Books,Length(Books));
  for var I:=0 to High(Books) do
  begin
    if (Books[I].BookKey.DatabaseID<>Identity.SourceID) or (Books[I].BookKey.BookID<=0) then
      raise EReadError.Create('Для продолжения сжатия нужны книги одной коллекции.');
    Result.Books[I].ID:=Books[I].BookKey.BookID;
    Result.Books[I].LibID:=Books[I].LibID;
    Result.Books[I].Physical:=ReaderBookPhysicalIdentity(Books[I]);
    Result.Books[I].Source:=TPath.GetFullPath(Books[I].GetBookFileName);
    Result.Books[I].SourceIdentity:=SourceStamp(Result.Books[I].Source);
    if Result.Books[I].Physical='' then
      raise EReadError.Create('Не удалось сохранить расположение выбранной книги. Повторите выбор.');
  end;
end;

function ResolveCompressionContinuationBooks(const Request: TBookCompressionContinuation;
  const Collection: IBookCollection): TArray<TBookRecord>;
begin
  if not Assigned(Collection) or (Collection.CollectionID<>Request.Identity.SourceID) then
    raise EReadError.Create('Для продолжения откройте исходную коллекцию и повторите сжатие.');
  SetLength(Result,Length(Request.Books));
  for var I:=0 to High(Request.Books) do
  begin
    try Collection.GetBookRecord(CreateBookKey(Request.Books[I].ID,Collection.CollectionID),Result[I],False);
    except on E:Exception do
      raise EReadError.Create('После перезапуска выбранная книга недоступна. Начните сжатие заново.'); end;
    if (Result[I].LibID<>Request.Books[I].LibID) or
      (ReaderBookPhysicalIdentity(Result[I])<>Request.Books[I].Physical) or
      not SameFileName(TPath.GetFullPath(Result[I].GetBookFileName),Request.Books[I].Source) or
      (SourceStamp(Request.Books[I].Source)<>Request.Books[I].SourceIdentity) then
      raise EReadError.Create('После выбора книга или её архив изменились. Выберите книги для сжатия заново.');
  end;
end;

function Text(Obj: TJSONObject; const Name: string; Maximum: Integer;
  AllowEmpty: Boolean = False): string;
var Field: TJSONValue;
begin
  Field:=Obj.GetValue(Name);
  if not (Field is TJSONString) then raise EReadError.Create('Повреждён план продолжения сжатия.');
  Result:=Field.Value;
  if ((Result='') and not AllowEmpty) or (Length(Result)>Maximum) or Result.Contains(#0) then
    raise EReadError.Create('Некорректное значение в плане продолжения сжатия.');
end;

function Number(Obj: TJSONObject; const Name: string; Minimum,Maximum: Int64): Int64;
var Field: TJSONValue;
begin
  Field:=Obj.GetValue(Name);
  if not (Field is TJSONNumber) or not TryStrToInt64(Field.Value,Result) or
    (Result<Minimum) or (Result>Maximum) then
    raise EReadError.Create('Некорректное число в плане продолжения сжатия.');
end;

function Flag(Obj: TJSONObject; const Name: string): Boolean;
var Field: TJSONValue;
begin
  Field:=Obj.GetValue(Name);
  if not (Field is TJSONBool) then raise EReadError.Create('Некорректный переключатель продолжения сжатия.');
  Result:=TJSONBool(Field).AsBoolean;
end;

function PathField(Obj: TJSONObject; const Name: string; AllowEmpty: Boolean = False): string;
begin
  Result:=Text(Obj,Name,4096,AllowEmpty);
  if (Result<>'') and not TPath.IsPathRooted(Result) then
    raise EReadError.Create('Недопустимый путь в плане продолжения сжатия.');
end;

function StoreCompressionContinuation(const SettingsFile: string;
  const Request: TBookCompressionContinuation): string;
var Name,Temporary,Token: string; Stream: TFileStream; Root,Row: TJSONObject;
  procedure WriteLine(Value: TJSONObject);
  var Bytes: TBytes;
  begin
    var Line:=Value.ToJSON;
    Bytes:=TEncoding.UTF8.GetBytes(Line+#10);
    if (Length(Line)>MAX_LINE_CHARS) or (Stream.Size+Length(Bytes)>MAX_PLAN_BYTES) then
      raise EReadError.Create('Слишком большая подборка продолжения. Сожмите её несколькими частями или выберите всю коллекцию.');
    Stream.WriteBuffer(Bytes[0],Length(Bytes));
  end;
begin
  CheckOptions(Request.Options);
  if (Request.Identity.SourceID<=0) or (Length(Request.Identity.CatalogIdentity)<>24) or
    ((Request.Scope=crsSelected)<>(Length(Request.Books)>0)) then
    raise EReadError.Create('Не определена исходная коллекция продолжения сжатия.');
  Token:=TGUID.NewGuid.ToString; Name:=PlanFile(SettingsFile); Temporary:=Name+'.new-'+Token;
  if FileExists(Temporary) then raise EWriteError.Create('Временный план сжатия уже существует.');
  Stream:=TFileStream.Create(Temporary,fmCreate);
  try
    Root:=TJSONObject.Create;
    try
      Root.AddPair('schema',TJSONNumber.Create(1)); Root.AddPair('token',Token);
      Root.AddPair('created',DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True));
      Root.AddPair('scope',TJSONNumber.Create(Ord(Request.Scope)));
      Root.AddPair('collection',TJSONNumber.Create(Request.Identity.SourceID));
      Root.AddPair('catalog',Request.Identity.CatalogFile); Root.AddPair('catalog_identity',Request.Identity.CatalogIdentity);
      Root.AddPair('source_root',Request.Identity.SourceRoot);
      Root.AddPair('count',TJSONNumber.Create(Length(Request.Books)));
      Root.AddPair('profile',Request.Options.Profile); Root.AddPair('grayscale',TJSONBool.Create(Request.Options.Grayscale));
      Root.AddPair('review',TJSONBool.Create(Request.Options.ReviewResults));
      Root.AddPair('estimate',TJSONBool.Create(Request.Options.EstimateFirst));
      Root.AddPair('work_root',Request.Options.WorkRoot); Root.AddPair('backup_folder',Request.Options.BackupFolder);
      Root.AddPair('backup',TJSONBool.Create(Request.Options.BackupOriginals));
      WriteLine(Root);
    finally Root.Free; end;
    for var Book in Request.Books do
    begin
      Row:=TJSONObject.Create;
      try
        Row.AddPair('id',TJSONNumber.Create(Book.ID)); Row.AddPair('libid',Book.LibID);
        Row.AddPair('physical',Book.Physical); Row.AddPair('source',Book.Source);
        Row.AddPair('identity',Book.SourceIdentity); WriteLine(Row);
      finally Row.Free; end;
    end;
    SaveStreamAtomically(Stream,Name);
  finally Stream.Free; Winapi.Windows.DeleteFile(PChar(Temporary)); end;
  Result:=BOOK_COMPRESSION_RESUME_SWITCH+Token;
end;

function TakeCompressionContinuation(const SettingsFile, Argument: string;
  out Request: TBookCompressionContinuation): Boolean;
var Name,Claimed,Token: string; Stream: TFileStream; Reader: TStreamReader;
  Root,Row: TJSONObject; Created,NowUTC: TDateTime; Count: Integer;
  function OpenPlan: TStreamReader;
  begin
    if not IsPrivateArchiveDeletionSource(Name) then raise EReadError.Create('Некорректный файл продолжения сжатия.');
    Stream:=TFileStream.Create(Name,fmOpenRead or fmShareDenyWrite);
    try
      if (Stream.Size<=0) or (Stream.Size>MAX_PLAN_BYTES) then raise EReadError.Create('Некорректный размер плана сжатия.');
      Result:=TStreamReader.Create(Stream,TEncoding.UTF8,True,4096); Result.OwnStream;
    except Stream.Free; raise; end;
  end;
  function ReadLine: TJSONObject;
  var Line: string; Value: TJSONValue;
  begin
    if Reader.EndOfStream then raise EReadError.Create('План продолжения сжатия оборван.');
    Line:=Reader.ReadLine;
    if (Length(Line)=0) or (Length(Line)>MAX_LINE_CHARS) then raise EReadError.Create('Повреждена строка продолжения сжатия.');
    Value:=TJSONObject.ParseJSONValue(Line);
    if not (Value is TJSONObject) then begin Value.Free; raise EReadError.Create('Повреждён план продолжения сжатия.'); end;
    Result:=TJSONObject(Value);
  end;
begin
  Result:=False; Request:=Default(TBookCompressionContinuation);
  if not Argument.StartsWith(BOOK_COMPRESSION_RESUME_SWITCH) then Exit;
  Token:=Argument.Substring(Length(BOOK_COMPRESSION_RESUME_SWITCH));
  if Length(Token)<>38 then Exit;
  Name:=PlanFile(SettingsFile); if not FileExists(Name) then Exit;
  Reader:=OpenPlan;
  try Root:=ReadLine; try if Text(Root,'token',38)<>Token then Exit; finally Root.Free; end;
  finally Reader.Free; end;
  Claimed:=Name+'.claimed-'+TGUID.NewGuid.ToString;
  if not MoveFile(PChar(Name),PChar(Claimed)) then Exit;
  Name:=Claimed;
  try
    Reader:=OpenPlan;
    try
      Root:=ReadLine;
      try
        if Text(Root,'token',38)<>Token then Exit;
        Number(Root,'schema',1,1);
        Created:=ISO8601ToDate(Text(Root,'created',64),True); NowUTC:=TTimeZone.Local.ToUniversalTime(Now);
        if (Created<IncDay(NowUTC,-1)) or (Created>IncMinute(NowUTC,5)) then
          raise EReadError.Create('План продолжения сжатия устарел. Выберите книги заново.');
        Request.Identity.SourceID:=Number(Root,'collection',1,High(Integer));
        Request.Identity.CatalogFile:=PathField(Root,'catalog');
        Request.Identity.CatalogIdentity:=Text(Root,'catalog_identity',24);
        if Length(Request.Identity.CatalogIdentity)<>24 then raise EReadError.Create('Повреждены сведения об исходном каталоге.');
        Request.Identity.SourceRoot:=PathField(Root,'source_root');
        Request.Scope:=TCompressionResumeScope(Number(Root,'scope',Ord(Low(TCompressionResumeScope)),Ord(High(TCompressionResumeScope))));
        Count:=Number(Root,'count',0,TFile.GetSize(Name) div 64);
        if (Request.Scope=crsSelected)<>(Count>0) then raise EReadError.Create('Повреждена подборка продолжения сжатия.');
        Request.Options.Profile:=Text(Root,'profile',32);
        Request.Options.Grayscale:=Flag(Root,'grayscale'); Request.Options.ReviewResults:=Flag(Root,'review');
        Request.Options.EstimateFirst:=Flag(Root,'estimate'); Request.Options.OnlyNew:=Request.Scope=crsNew;
        Request.Options.WorkRoot:=PathField(Root,'work_root');
        Request.Options.BackupFolder:=PathField(Root,'backup_folder',True);
        Request.Options.BackupOriginals:=Flag(Root,'backup'); CheckOptions(Request.Options);
        Request.Options.QueueName:=TGUID.NewGuid.ToString;
      finally Root.Free; end;
      SetLength(Request.Books,Count);
      for var I:=0 to Count-1 do
      begin
        Row:=ReadLine;
        try
          Request.Books[I].ID:=Number(Row,'id',1,High(Integer));
          Request.Books[I].LibID:=Text(Row,'libid',2048,True);
          Request.Books[I].Physical:=Text(Row,'physical',8192);
          Request.Books[I].Source:=PathField(Row,'source');
          Request.Books[I].SourceIdentity:=Text(Row,'identity',128,True);
        finally Row.Free; end;
      end;
      if not Reader.EndOfStream then raise EReadError.Create('Лишние данные в плане продолжения сжатия.');
      Result:=True;
    finally Reader.Free; end;
  finally Winapi.Windows.DeleteFile(PChar(Claimed)); end;
end;

end.
