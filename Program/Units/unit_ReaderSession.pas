unit unit_ReaderSession;

interface

uses System.SysUtils, System.Classes, unit_Globals, unit_ReaderAnnotations;

type
  // The reader receives a resolved locator, never a connection to a catalogue.
  // HistoryIdentity is exactly the identity used by the existing reader.
  TReaderSessionRequest = record
    ID, RequestFile, SourceFile, HistoryIdentity, SettingsFile, OriginalSource,
      OriginalMember: string;
    Book: TBookRecord;
    RequirePersonalProgress: Boolean;
  end;
  TReaderSessionReply = record
    State, RequiredComponent, ErrorText: string;
    ProcessID, OriginProcessID: Cardinal;
    HasProgress: Boolean;
    Progress: Integer;
    RequestedNote: TReaderAnnotation;
  end;
  TReaderSessionLease = class
  private
    FLock: TObject;
    FRequest, FSource, FOriginalSource: TFileStream;
  public
    constructor Create(const Request: TReaderSessionRequest);
    destructor Destroy; override;
  end;

function CreateReaderSession(const Directory: string; const Book: TBookRecord;
  const HistoryIdentity, SettingsFile: string; RequirePersonalProgress: Boolean = False;
  const OriginalSource: string = ''; const OriginalMember: string = ''): TReaderSessionRequest;
function LoadReaderSession(const RequestFile: string): TReaderSessionRequest;
procedure WriteReaderSessionReply(const Request: TReaderSessionRequest;
  const Reply: TReaderSessionReply);
function TryReadReaderSessionReply(const Request: TReaderSessionRequest;
  out Reply: TReaderSessionReply): Boolean;
function ReaderSessionSourceMatches(const Request: TReaderSessionRequest;
  const FileName: string): Boolean;

implementation

uses System.IOUtils, System.JSON, System.RegularExpressions, Winapi.Windows,
  unit_AtomicIniFile, unit_FileMutex;

const MAX_SESSION_BYTES = 128 * 1024;

function Text(Value: TJSONObject; const Name: string; Limit: Integer;
  Required: Boolean = True): string;
var Item: TJSONValue;
begin
  Item:=Value.GetValue(Name);
  if not Assigned(Item) and not Required then Exit('');
  if not (Item is TJSONString) then
    raise Exception.Create('Повреждены параметры открытия книги: '+Name+'.');
  Result:=Item.Value;
  if (Required and (Result='')) or (Length(Result)>Limit) or (Pos(#0,Result)>0) then
    raise Exception.Create('Некорректный параметр открытия книги: '+Name+'.');
end;

function Number(Value: TJSONObject; const Name: string; Minimum, Maximum: Int64): Int64;
var Item: TJSONValue;
begin
  Item:=Value.GetValue(Name);
  if not (Item is TJSONNumber) or not TryStrToInt64(Item.Value,Result) or
    (Result<Minimum) or (Result>Maximum) then
    raise Exception.Create('Некорректный числовой параметр открытия книги: '+Name+'.');
end;

function ReadObject(const FileName: string): TJSONObject;
var Stream: TFileStream; Data: TBytes; Value: TJSONValue; Offset: Integer;
begin
  Result:=nil; Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
  try
    if (Stream.Size=0) or (Stream.Size>MAX_SESSION_BYTES) then
      raise Exception.Create('Файл параметров открытия книги имеет недопустимый размер.');
    SetLength(Data,Stream.Size); Stream.ReadBuffer(Data[0],Length(Data));
  finally Stream.Free; end;
  Offset:=0;
  if (Length(Data)>=3) and (Data[0]=$EF) and (Data[1]=$BB) and (Data[2]=$BF) then Offset:=3;
  Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data,Offset,Length(Data)-Offset));
  if not (Value is TJSONObject) then
  begin Value.Free; raise Exception.Create('Повреждён файл параметров открытия книги.'); end;
  Result:=TJSONObject(Value);
end;

procedure WriteObject(const FileName: string; Value: TJSONObject);
var Stream: TStringStream;
begin
  Stream:=TStringStream.Create(Value.ToJSON,TEncoding.UTF8);
  try
    if Stream.Size>MAX_SESSION_BYTES then
      raise Exception.Create('Слишком много данных открытия книги.');
    SaveStreamAtomically(Stream,FileName);
  finally Stream.Free; end;
end;

function AbsoluteFile(const Value: string): string;
begin
  if not TPath.IsPathRooted(Value) or (Length(Value)>32767) or (Pos(#0,Value)>0) then
    raise Exception.Create('Для открытия книги нужен полный путь.');
  Result:=TPath.GetFullPath(Value);
end;

function RequestObject(const Request: TReaderSessionRequest): TJSONObject;
var Locator: TJSONObject;
begin
  Result:=TJSONObject.Create;
  Result.AddPair('format',TJSONNumber.Create(1));
  Result.AddPair('kind','HomeLibReader-session'); Result.AddPair('id',Request.ID);
  Result.AddPair('source',Request.SourceFile); Result.AddPair('identity',Request.HistoryIdentity);
  if Request.OriginalSource<>'' then Result.AddPair('original_source',Request.OriginalSource);
  if Request.OriginalMember<>'' then Result.AddPair('original_member',Request.OriginalMember);
  Result.AddPair('settings',Request.SettingsFile);
  Result.AddPair('personal_progress',TJSONBool.Create(Request.RequirePersonalProgress));
  Locator:=TJSONObject.Create; Result.AddPair('book',Locator);
  Locator.AddPair('collection_id',TJSONNumber.Create(Request.Book.BookKey.DatabaseID));
  Locator.AddPair('book_id',TJSONNumber.Create(Request.Book.BookKey.BookID));
  Locator.AddPair('root',Request.Book.CollectionRoot); Locator.AddPair('folder',Request.Book.Folder);
  Locator.AddPair('file',Request.Book.FileName); Locator.AddPair('extension',Request.Book.FileExt);
  Locator.AddPair('inside',TJSONNumber.Create(Request.Book.InsideNo));
  Locator.AddPair('size',TJSONNumber.Create(Request.Book.Size));
  Locator.AddPair('lib_id',Request.Book.LibID); Locator.AddPair('title',Request.Book.Title);
  Locator.AddPair('language',Request.Book.Lang);
end;

function LoadReaderSession(const RequestFile: string): TReaderSessionRequest;
var Root, Locator: TJSONObject; Value: TJSONValue;
begin
  Result:=Default(TReaderSessionRequest); Result.RequestFile:=AbsoluteFile(RequestFile);
  Root:=ReadObject(Result.RequestFile);
  try
    if (Number(Root,'format',1,1)<>1) or (Text(Root,'kind',40)<>'HomeLibReader-session') then
      raise Exception.Create('Неизвестный формат параметров открытия книги.');
    Result.ID:=Text(Root,'id',32);
    if not TRegEx.IsMatch(Result.ID,'\A[0-9a-f]{32}\z') then
      raise Exception.Create('Некорректный номер сеанса чтения.');
    Result.SourceFile:=AbsoluteFile(Text(Root,'source',32767));
    Result.OriginalSource:=Text(Root,'original_source',32767,False);
    if Result.OriginalSource<>'' then Result.OriginalSource:=AbsoluteFile(Result.OriginalSource);
    Result.OriginalMember:=Text(Root,'original_member',32767,False);
    Result.SettingsFile:=AbsoluteFile(Text(Root,'settings',32767));
    if not ExtractFileName(Result.SettingsFile).EndsWith('reader.ini',True) then
      raise Exception.Create('Некорректный файл настроек читалки.');
    Result.HistoryIdentity:=Text(Root,'identity',8192);
    Value:=Root.GetValue('personal_progress');
    if Assigned(Value) then
    begin
      if not (Value is TJSONBool) then raise Exception.Create('Некорректный режим личного прогресса.');
      Result.RequirePersonalProgress:=TJSONBool(Value).AsBoolean;
    end;
    Value:=Root.GetValue('book');
    if not (Value is TJSONObject) then raise Exception.Create('Нет данных выбранной книги.');
    Locator:=TJSONObject(Value);
    Result.Book:=Default(TBookRecord); Result.Book.NodeType:=ntBookInfo;
    Result.Book.BookKey:=CreateBookKey(Number(Locator,'book_id',0,MaxInt),
      Number(Locator,'collection_id',0,MaxInt));
    Result.Book.CollectionRoot:=AbsoluteFile(Text(Locator,'root',32767));
    Result.Book.Folder:=Text(Locator,'folder',32767,False);
    Result.Book.FileName:=Text(Locator,'file',32767);
    Result.Book.FileExt:=Text(Locator,'extension',128,False);
    Result.Book.InsideNo:=Number(Locator,'inside',-1,MaxInt);
    Result.Book.Size:=Number(Locator,'size',0,MaxInt);
    Result.Book.LibID:=Text(Locator,'lib_id',8192,False);
    Result.Book.Title:=Text(Locator,'title',16384,False);
    Result.Book.Lang:=Text(Locator,'language',128,False);
    Include(Result.Book.BookProps,bpIsLocal);
    if not SameFileName(AbsoluteFile(Result.Book.GetBookFileName),Result.SourceFile) then
      raise Exception.Create('Путь книги не совпадает с данными выбранной записи.');
  finally Root.Free; end;
end;

function CreateReaderSession(const Directory: string; const Book: TBookRecord;
  const HistoryIdentity, SettingsFile: string; RequirePersonalProgress: Boolean;
  const OriginalSource, OriginalMember: string): TReaderSessionRequest;
var Folder: string; Value: TJSONObject;
begin
  Result:=Default(TReaderSessionRequest);
  Result.ID:=LowerCase(TGUID.NewGuid.ToString.Replace('{','').Replace('}','').Replace('-',''));
  Result.Book:=Book; Result.SourceFile:=AbsoluteFile(Book.GetBookFileName);
  Result.RequirePersonalProgress:=RequirePersonalProgress;
  Result.HistoryIdentity:=HistoryIdentity; Result.SettingsFile:=AbsoluteFile(SettingsFile);
  if OriginalSource<>'' then Result.OriginalSource:=AbsoluteFile(OriginalSource);
  Result.OriginalMember:=OriginalMember;
  Folder:=TPath.Combine(AbsoluteFile(Directory),'HomeLibReader-session-'+Result.ID);
  if DirectoryExists(Folder) then raise Exception.Create('Папка сеанса чтения уже существует.');
  ForceDirectories(Folder); Result.RequestFile:=TPath.Combine(Folder,'request.json');
  Value:=RequestObject(Result);
  try WriteObject(Result.RequestFile,Value); finally Value.Free; end;
  // Validate our serialized representation too; do not launch a book with a
  // locator that a separately downloaded reader would interpret differently.
  Result:=LoadReaderSession(Result.RequestFile);
end;

function ValidState(const Value: string): Boolean;
begin
  Result:=(Value='opening') or (Value='displaying') or (Value='component_required') or
    (Value='restarting') or (Value='closed') or (Value='failed');
end;

function ReplyFile(const Request: TReaderSessionRequest): string;
begin Result:=TPath.Combine(ExtractFileDir(Request.RequestFile),'response.json'); end;

procedure WriteReaderSessionReply(const Request: TReaderSessionRequest;
  const Reply: TReaderSessionReply);
var Value, Note: TJSONObject;
begin
  if not ValidState(Reply.State) or (Reply.ProcessID=0) or
    (Reply.HasProgress and ((Reply.Progress<0) or (Reply.Progress>100))) then
    raise Exception.Create('Некорректный результат чтения книги.');
  Value:=TJSONObject.Create;
  try
    Value.AddPair('format',TJSONNumber.Create(1)); Value.AddPair('id',Request.ID);
    Value.AddPair('state',Reply.State); Value.AddPair('pid',TJSONNumber.Create(Reply.ProcessID));
    if Reply.OriginProcessID<>0 then Value.AddPair('origin_pid',TJSONNumber.Create(Reply.OriginProcessID));
    if Reply.HasProgress then Value.AddPair('progress',TJSONNumber.Create(Reply.Progress));
    if Reply.RequiredComponent<>'' then Value.AddPair('component',Reply.RequiredComponent);
    if Reply.ErrorText<>'' then Value.AddPair('error',Copy(Reply.ErrorText,1,4096));
    if Reply.RequestedNote.ID<>'' then
    begin
      Note:=TJSONObject.Create; Value.AddPair('note',Note);
      Note.AddPair('id',Reply.RequestedNote.ID); Note.AddPair('book_id',Reply.RequestedNote.BookID);
      Note.AddPair('book_title',Reply.RequestedNote.BookTitle);
      Note.AddPair('position',TJSONNumber.Create(Reply.RequestedNote.Position));
    end;
    WriteObject(ReplyFile(Request),Value);
  finally Value.Free; end;
end;

function TryReadReaderSessionReply(const Request: TReaderSessionRequest;
  out Reply: TReaderSessionReply): Boolean;
var Root, Note: TJSONObject; Value: TJSONValue; Pending: TReaderSessionReply;
begin
  Result:=False; Reply:=Default(TReaderSessionReply);
  if not FileExists(ReplyFile(Request)) then Exit;
  Root:=nil;
  try
    try
      Root:=ReadObject(ReplyFile(Request));
      if (Number(Root,'format',1,1)<>1) or (Text(Root,'id',32)<>Request.ID) then Exit;
      Pending:=Default(TReaderSessionReply);
      Pending.State:=Text(Root,'state',32); if not ValidState(Pending.State) then Exit;
      Pending.ProcessID:=Number(Root,'pid',1,High(Cardinal));
      if Assigned(Root.GetValue('origin_pid')) then
        Pending.OriginProcessID:=Number(Root,'origin_pid',1,High(Cardinal));
      Pending.HasProgress:=Assigned(Root.GetValue('progress'));
      if Pending.HasProgress then Pending.Progress:=Number(Root,'progress',0,100);
      Pending.RequiredComponent:=Text(Root,'component',128,False);
      Pending.ErrorText:=Text(Root,'error',4096,False);
      Value:=Root.GetValue('note');
      if Assigned(Value) then
      begin
        if not (Value is TJSONObject) then Exit; Note:=TJSONObject(Value);
        Pending.RequestedNote.ID:=Text(Note,'id',256);
        Pending.RequestedNote.BookID:=Text(Note,'book_id',8192);
        Pending.RequestedNote.BookTitle:=Text(Note,'book_title',16384,False);
        Pending.RequestedNote.Position:=Number(Note,'position',0,MaxInt);
      end;
      Reply:=Pending; Result:=True;
    except on E: Exception do begin Reply:=Default(TReaderSessionReply); Result:=False; end; end;
  finally Root.Free; end;
end;

function ReaderSessionSourceMatches(const Request: TReaderSessionRequest;
  const FileName: string): Boolean;
begin Result:=(Request.SourceFile<>'') and SameFileName(Request.SourceFile,TPath.GetFullPath(FileName)); end;

constructor TReaderSessionLease.Create(const Request: TReaderSessionRequest);
var Lock: TFileMutex;
begin
  inherited Create;
  Lock:=TFileMutex.Create(Request.RequestFile); FLock:=Lock;
  if not Lock.TryAcquire then raise Exception.Create('Эта книга уже открывается в другом экземпляре читалки.');
  FRequest:=TFileStream.Create(Request.RequestFile,fmOpenRead or fmShareDenyWrite);
  // Keep an extracted input or source archive alive while the catalogue exits.
  // It remains readable, but cannot be overwritten/deleted during this view.
  FSource:=TFileStream.Create(Request.SourceFile,fmOpenRead or fmShareDenyWrite);
  if (Request.OriginalSource<>'') and not SameFileName(Request.OriginalSource,Request.SourceFile) then
    FOriginalSource:=TFileStream.Create(Request.OriginalSource,fmOpenRead or fmShareDenyWrite);
end;

destructor TReaderSessionLease.Destroy;
begin FOriginalSource.Free; FSource.Free; FRequest.Free; FLock.Free; inherited; end;

end.
