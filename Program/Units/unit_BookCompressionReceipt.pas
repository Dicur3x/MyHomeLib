unit unit_BookCompressionReceipt;

interface

uses System.SysUtils, System.JSON, System.Generics.Collections, SQLiteWrap, unit_ZipMemberDeletion;

type
  // Immutable per-file receipt. Only BookSize and the compression ledger are
  // written; catalogue/personal commits can safely replay independently.
  TBookCompressionReceipt = class
  private
    FData: TJSONObject;
    FJSON: string;
    FPayloads: TDictionary<string,TJSONObject>;
    procedure Validate;
    function Text(const Name: string): string;
    function Payload(const Member: string): TJSONObject;
    function ProcessRows(DB: TSQLiteDatabase; Personal, Commit: Boolean;
      RequireApplied: Boolean = False): Integer;
    procedure CheckEngine(Engine: TZipMemberDeletion);
  public
    constructor Create(const JSON: string);
    destructor Destroy; override;
    function ToJSON: string;
    function SHA256: string;
    procedure CheckBeforeWrite;
    procedure CheckApplied;
    function Apply(Engine: TZipMemberDeletion; const Fault: TProc<string> = nil): Integer;
  end;

function CompressionFileKey(const FileName: string): string;

implementation

uses Winapi.Windows, System.Classes, System.Hash;

const
  MaxReceiptBytes = 16 * 1024 * 1024;
  MaxReceiptRows = 100000;

type
  TCompressionDatabaseLease = class(TInterfacedObject)
  private
    FHandle: THandle;
  public
    constructor Create(const FileName, Expected: string);
    destructor Destroy; override;
  end;

function JSONText(Obj: TJSONObject; const Name: string): string;
begin
  var Value:=Obj.GetValue(Name);
  if not (Value is TJSONString) then raise EReadError.Create('Неполный журнал сжатия книг.');
  Result:=Value.Value;
end;

function JSONNumber(Obj: TJSONObject; const Name: string): Int64;
begin
  var Value:=Obj.GetValue(Name);
  if not (Value is TJSONNumber) or not TryStrToInt64(Value.Value,Result) then
    raise EReadError.Create('Неверное число в журнале сжатия книг.');
end;

function JSONBool(Obj: TJSONObject; const Name: string): Boolean;
begin
  var Value:=Obj.GetValue(Name);
  if not (Value is TJSONBool) then raise EReadError.Create('Неполный журнал сжатия книг.');
  Result:=TJSONBool(Value).AsBoolean;
end;

function JSONArray(Obj: TJSONObject; const Name: string): TJSONArray;
begin
  var Value:=Obj.GetValue(Name);
  if not (Value is TJSONArray) then raise EReadError.Create('Нет списка книг в журнале сжатия.');
  Result:=TJSONArray(Value);
end;

function HexString(const Value: string; Count: Integer): Boolean;
begin
  Result:=Length(Value)=Count;
  for var C in Value do if not CharInSet(C,['0'..'9','a'..'f','A'..'F']) then Exit(False);
end;

function FileKeyValid(const Value: string): Boolean;
begin
  Result:=(Length(Value)=25) and (Value[9]=':') and
    HexString(Copy(Value,1,8),8) and HexString(Copy(Value,10,16),16);
end;

function CompressionFileKey(const FileName: string): string;
begin Result:=Copy(ArchiveDeletionSourceIdentity(FileName),1,25); end;

constructor TCompressionDatabaseLease.Create(const FileName, Expected: string);
var Info: TByHandleFileInformation; Actual: string;
begin
  inherited Create;
  FHandle:=INVALID_HANDLE_VALUE;
  // Allow normal SQLite traffic, but prevent replacement of the very file
  // whose rows this receipt is about. Never create a missing database.
  FHandle:=CreateFile(PChar(DeletionNativePath(FileName)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FHandle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  if not GetFileInformationByHandle(FHandle,Info) then RaiseLastOSError;
  Actual:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+
    IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
  if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) or
    not SameText(Actual,Expected) then
    raise EReadError.Create('База коллекции изменилась. Журнал сжатия сохранён.');
end;

destructor TCompressionDatabaseLease.Destroy;
begin
  if FHandle<>INVALID_HANDLE_VALUE then CloseHandle(FHandle);
  inherited;
end;

constructor TBookCompressionReceipt.Create(const JSON: string);
var Value: TJSONValue;
begin
  inherited Create;
  if TEncoding.UTF8.GetByteCount(JSON)>MaxReceiptBytes then
    raise EReadError.Create('Слишком большой журнал сжатия одного архива.');
  Value:=TJSONObject.ParseJSONValue(JSON);
  if not (Value is TJSONObject) then
  begin Value.Free; raise EReadError.Create('Не удалось прочитать журнал сжатия книг.'); end;
  FData:=TJSONObject(Value);
  FPayloads:=TDictionary<string,TJSONObject>.Create;
  Validate;
  FJSON:=FData.ToJSON;
end;

destructor TBookCompressionReceipt.Destroy;
begin FPayloads.Free; FData.Free; inherited; end;

function TBookCompressionReceipt.Text(const Name: string): string;
begin Result:=JSONText(FData,Name); end;

function TBookCompressionReceipt.ToJSON: string;
begin Result:=FJSON; end;

function TBookCompressionReceipt.SHA256: string;
var Hash: THashSHA2;
begin
  Hash:=THashSHA2.Create;
  Hash.Update(TEncoding.UTF8.GetBytes(FJSON));
  Result:=Hash.HashAsString;
end;

function TBookCompressionReceipt.Payload(const Member: string): TJSONObject;
begin
  if not FPayloads.TryGetValue(Member,Result) then
    raise EReadError.Create('Для книги нет проверенного результата сжатия.');
end;

procedure TBookCompressionReceipt.Validate;
var Seen: TDictionary<string,Byte>; Key: string; Item: TJSONObject;
begin
  if (JSONNumber(FData,'schema')<>1) or (Text('kind')<>'HomeLibre book compression') or
    (JSONNumber(FData,'collection_id')<=0) or (JSONNumber(FData,'collection_id')>MaxInt) or
    not FileKeyValid(Text('catalogue_key')) or not FileKeyValid(Text('personal_key')) or
    not FileKeyValid(Text('source_file_key')) or
    SameText(Text('catalogue_key'),Text('personal_key')) then
    raise EReadError.Create('Журнал сжатия не относится к отдельным базам коллекции и личных данных.');
  for var Name in ['catalogue','personal','source'] do
    if (Text(Name)='') or (Text(Name)<>ExpandFileName(Text(Name))) then
      raise EReadError.Create('В журнале сжатия нужен полный путь файла.');
  for var Name in ['source_sha256','result_sha256','profile_sha256'] do
    if not HexString(Text(Name),64) then raise EReadError.Create('Нет контрольной суммы результата сжатия.');
  if (Length(Text('base_root'))>32767) or (Text('base_catalogue')='') or
    (Length(Text('base_catalogue'))>32767) then
    raise EReadError.Create('Нет привязки к подключённой коллекции.');
  if (JSONArray(FData,'rows').Count=0) or (JSONArray(FData,'rows').Count>MaxReceiptRows) or
    (JSONArray(FData,'payloads').Count=0) or (JSONArray(FData,'payloads').Count>MaxReceiptRows) then
    raise EReadError.Create('Неверное число книг в журнале сжатия.');
  Seen:=TDictionary<string,Byte>.Create;
  try
    for var Value in JSONArray(FData,'payloads') do
    begin
      if not (Value is TJSONObject) then raise EReadError.Create('Неверный результат сжатия книги.');
      Item:=TJSONObject(Value);
      Key:=JSONText(Item,'member');
      if (Length(Key)>32767) or Seen.ContainsKey(Key) or
        not HexString(JSONText(Item,'input_sha256'),64) or
        not HexString(JSONText(Item,'output_sha256'),64) or (JSONNumber(Item,'size')<0) then
        raise EReadError.Create('Результаты сжатия книги неполны или повторяются.');
      Seen.Add(Key,0);
      FPayloads.Add(Key,Item);
    end;
    Seen.Clear;
    for var Value in JSONArray(FData,'rows') do
    begin
      if not (Value is TJSONObject) then raise EReadError.Create('Неверная запись в журнале сжатия.');
      Item:=TJSONObject(Value);
      var Kind:=JSONNumber(Item,'kind');
      var Required:=JSONBool(Item,'required');
      if not (Kind in [0,1,2]) or (JSONNumber(Item,'id')<=0) or
        (JSONNumber(Item,'id')>MaxInt) or (JSONNumber(Item,'old_size')<0) or
        ((Kind<>1) and not Required) then
        raise EReadError.Create('Неверная привязка сжатия к книге.');
      for var Name in ['lib_id','folder','file_name','ext','root','source_key','member'] do
        if Length(JSONText(Item,Name))>32767 then raise EReadError.Create('Слишком длинное поле книги.');
      JSONNumber(Item,'inside_no');
      if Kind=2 then Key:='copy:'+JSONText(Item,'source_key')
      else Key:=IntToStr(Kind)+':'+IntToStr(JSONNumber(Item,'id'));
      if ((Kind=2) and (JSONText(Item,'source_key')='')) or Seen.ContainsKey(Key) then
        raise EReadError.Create('Повторная привязка книги в журнале сжатия.');
      Seen.Add(Key,0);
      Payload(JSONText(Item,'member'));
    end;
  finally Seen.Free; end;
end;

function TBookCompressionReceipt.ProcessRows(DB: TSQLiteDatabase; Personal, Commit,
  RequireApplied: Boolean): Integer;
var Query: TSQLiteQuery; SQL, Table: string;
    Item: TJSONObject; Kind, NewSize, CurrentSize: Int64; Matches: Boolean;
begin
  Result:=0;
  if Personal then
  begin
    Query:=DB.NewQuery('SELECT RootFolder,DBFileName FROM Bases WHERE DatabaseID=?',
      [JSONNumber(FData,'collection_id')]);
    try
      Query.Open;
      if Query.Eof or (Query.FieldAsString(0)<>Text('base_root')) or
        (Query.FieldAsString(1)<>Text('base_catalogue')) then
        raise EReadError.Create('Папка или подключение коллекции изменились. Журнал сжатия сохранён.');
    finally Query.Free; end;
  end;
  DB.BeginQueryBatch;
  try
    for var Value in JSONArray(FData,'rows') do
    begin
      Item:=TJSONObject(Value);
      Kind:=JSONNumber(Item,'kind');
      if Personal<>(Kind=1) then Continue;
      Table:='Books';
      if Kind=2 then Table:='CatalogBookCopies';
      SQL:='SELECT LibID,Folder,FileName,Ext,InsideNo,BookSize';
      if Kind=2 then SQL:=SQL+',Root,BookID';
      SQL:=SQL+' FROM '+Table;
      if Kind=2 then SQL:=SQL+' WHERE SourceKey=?'
      else SQL:=SQL+' WHERE BookID=?';
      if Personal then SQL:=SQL+' AND DatabaseID=?';
      Query:=DB.NewQuery(SQL);
      try
        if Kind=2 then Query.SetParam(0,JSONText(Item,'source_key'))
        else Query.SetParam(0,JSONNumber(Item,'id'));
        if Personal then Query.SetParam(1,JSONNumber(FData,'collection_id'));
        Query.Open;
        NewSize:=JSONNumber(Payload(JSONText(Item,'member')),'size');
        Matches:=not Query.Eof;
        CurrentSize:=-1;
        if Matches then
        begin
          CurrentSize:=Query.FieldAsInt(5);
          Matches:=(Query.FieldAsString(0)=JSONText(Item,'lib_id')) and
            (Query.FieldAsString(1)=JSONText(Item,'folder')) and
            (Query.FieldAsString(2)=JSONText(Item,'file_name')) and
            (Query.FieldAsString(3)=JSONText(Item,'ext')) and
            (Query.FieldAsInt(4)=JSONNumber(Item,'inside_no')) and
            ((CurrentSize=JSONNumber(Item,'old_size')) or (CurrentSize=NewSize));
          if Matches and (Kind=2) then
            Matches:=(Query.FieldAsString(6)=JSONText(Item,'root')) and
              (Query.FieldAsInt(7)=JSONNumber(Item,'id'));
        end;
      finally Query.Free; end;
      if not Matches then
      begin
        if JSONBool(Item,'required') then
          raise EReadError.Create('Книга в каталоге изменилась. Обновление размеров остановлено, журнал сохранён.');
        Continue; // A historical personal card can refer to another source.
      end;
      if RequireApplied and (CurrentSize<>NewSize) then
        raise EReadError.Create('Размер книги ещё не сохранён. Задание сжатия нельзя считать завершённым.');
      if Commit and (CurrentSize<>NewSize) then
      begin
        SQL:='UPDATE '+Table+' SET BookSize=?';
        if Kind=2 then SQL:=SQL+' WHERE SourceKey=?' else SQL:=SQL+' WHERE BookID=?';
        if Personal then SQL:=SQL+' AND DatabaseID=?';
        Query:=DB.NewQuery(SQL);
        try
          Query.SetParam(0,NewSize);
          if Kind=2 then Query.SetParam(1,JSONText(Item,'source_key'))
          else Query.SetParam(1,JSONNumber(Item,'id'));
          if Personal then Query.SetParam(2,JSONNumber(FData,'collection_id'));
          Query.ExecSQL;
          if DB.LastChangedRows<>1 then raise EWriteError.Create('Не удалось обновить размер книги.');
          Inc(Result);
        finally Query.Free; end;
      end;
    end;
    if Commit and not Personal then
    begin
      DB.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibreBookCompression('+
        'FileKey TEXT NOT NULL,Member TEXT NOT NULL,ProfileSHA256 TEXT NOT NULL,'+
        'InputSHA256 TEXT NOT NULL,OutputSHA256 TEXT NOT NULL,BookSize INTEGER NOT NULL,'+
        'PRIMARY KEY(FileKey,Member))');
      for var Value in JSONArray(FData,'payloads') do
      begin
        Item:=TJSONObject(Value);
        DB.ExecSQL('INSERT INTO HomeLibreBookCompression VALUES(?,?,?,?,?,?) '+
          'ON CONFLICT(FileKey,Member) DO UPDATE SET ProfileSHA256=excluded.ProfileSHA256,'+
          'InputSHA256=excluded.InputSHA256,OutputSHA256=excluded.OutputSHA256,BookSize=excluded.BookSize',
          [UpperCase(Text('source_file_key')),JSONText(Item,'member'),LowerCase(Text('profile_sha256')),
           LowerCase(JSONText(Item,'input_sha256')),LowerCase(JSONText(Item,'output_sha256')),JSONNumber(Item,'size')]);
      end;
    end;
  finally DB.EndQueryBatch; end;
end;

procedure TBookCompressionReceipt.CheckApplied;
var Catalogue, Personal: TSQLiteDatabase; CatalogueLease, PersonalLease: IInterface;
begin
  CatalogueLease:=TCompressionDatabaseLease.Create(Text('catalogue'),Text('catalogue_key'));
  PersonalLease:=TCompressionDatabaseLease.Create(Text('personal'),Text('personal_key'));
  Catalogue:=TSQLiteDatabase.CreateReadOnly(Text('catalogue'));
  try
    Personal:=TSQLiteDatabase.CreateReadOnly(Text('personal'));
    try
      Catalogue.Start; Personal.Start;
      ProcessRows(Catalogue,False,False,True);
      ProcessRows(Personal,True,False,True);
      for var Value in JSONArray(FData,'payloads') do
      begin
        var Item:=TJSONObject(Value);
        var Query:=Catalogue.NewQuery('SELECT ProfileSHA256,InputSHA256,OutputSHA256,BookSize '+
          'FROM HomeLibreBookCompression WHERE FileKey=? AND Member=?',
          [UpperCase(Text('source_file_key')),JSONText(Item,'member')]);
        try
          Query.Open;
          if Query.Eof or (Query.FieldAsString(0)<>LowerCase(Text('profile_sha256'))) or
            (Query.FieldAsString(1)<>LowerCase(JSONText(Item,'input_sha256'))) or
            (Query.FieldAsString(2)<>LowerCase(JSONText(Item,'output_sha256'))) or
            (Query.FieldAsInt(3)<>JSONNumber(Item,'size')) then
            raise EReadError.Create('Нет подтверждения обновления каталога после сжатия.');
        finally Query.Free; end;
      end;
    finally
      try if Personal.InTransaction then Personal.Rollback; finally Personal.Free; end;
    end;
  finally
    try if Catalogue.InTransaction then Catalogue.Rollback; finally Catalogue.Free; end;
  end;
end;

procedure TBookCompressionReceipt.CheckBeforeWrite;
var Catalogue, Personal: TSQLiteDatabase; CatalogueLease, PersonalLease: IInterface;
begin
  CatalogueLease:=TCompressionDatabaseLease.Create(Text('catalogue'),Text('catalogue_key'));
  PersonalLease:=TCompressionDatabaseLease.Create(Text('personal'),Text('personal_key'));
  Catalogue:=TSQLiteDatabase.CreateReadOnly(Text('catalogue'));
  try
    Personal:=TSQLiteDatabase.CreateReadOnly(Text('personal'));
    try
      Catalogue.Start; Personal.Start;
      ProcessRows(Catalogue,False,False);
      ProcessRows(Personal,True,False);
    finally
      try if Personal.InTransaction then Personal.Rollback; finally Personal.Free; end;
    end;
  finally
    try if Catalogue.InTransaction then Catalogue.Rollback; finally Catalogue.Free; end;
  end;
end;

procedure TBookCompressionReceipt.CheckEngine(Engine: TZipMemberDeletion);
begin
  if not Assigned(Engine) then raise EReadError.Create('Нет проверенного сжатого файла.');
  Engine.CheckReplacementReceipt(Text('source'),Text('source_file_key'),
    Text('source_sha256'),Text('result_sha256'),SHA256);
end;

function TBookCompressionReceipt.Apply(Engine: TZipMemberDeletion; const Fault: TProc<string>): Integer;
var Catalogue, Personal: TSQLiteDatabase; CatalogueLease, PersonalLease: IInterface;
begin
  CheckEngine(Engine);
  CatalogueLease:=TCompressionDatabaseLease.Create(Text('catalogue'),Text('catalogue_key'));
  PersonalLease:=TCompressionDatabaseLease.Create(Text('personal'),Text('personal_key'));
  Catalogue:=TSQLiteDatabase.Create(Text('catalogue'));
  try
    Personal:=TSQLiteDatabase.Create(Text('personal'));
    try
      // Acquire both writer locks before validating or changing either store.
      // No long filesystem compression occurs while these locks are held.
      Catalogue.SetTimeout(2000); Personal.SetTimeout(2000);
      Catalogue.Start('','IMMEDIATE'); Personal.Start('','IMMEDIATE');
      ProcessRows(Catalogue,False,False);
      ProcessRows(Personal,True,False);
      Result:=ProcessRows(Catalogue,False,True);
      Inc(Result,ProcessRows(Personal,True,True));
      Catalogue.Commit;
      if Assigned(Fault) then Fault('catalogue-committed');
      Personal.Commit;
      if Assigned(Fault) then Fault('personal-committed');
    finally
      try if Personal.InTransaction then Personal.Rollback; finally Personal.Free; end;
    end;
  finally
    try if Catalogue.InTransaction then Catalogue.Rollback; finally Catalogue.Free; end;
  end;
end;

end.
