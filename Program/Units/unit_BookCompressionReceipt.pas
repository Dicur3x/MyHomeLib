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
    procedure WriteHistory(DB: TSQLiteDatabase; PreserveKnownInput: Boolean = False);
    procedure WriteChecks(DB: TSQLiteDatabase);
  public
    constructor Create(const JSON: string);
    destructor Destroy; override;
    function ToJSON: string;
    function SHA256: string;
    procedure CheckBeforeWrite;
    procedure CheckApplied;
    procedure RecordInspection(const Cancelled: TFunc<Boolean> = nil);
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
  if FData.GetValue('compression_options')<>nil then
  begin
    if not (FData.GetValue('compression_options') is TJSONObject) then
      raise EReadError.Create('Неверные настройки проверки сжатия.');
    var Options:=TJSONObject(FData.GetValue('compression_options'));
    var Profile:=JSONText(Options,'profile');
    var Identity:=JSONText(Options,'source_identity');
    JSONBool(Options,'grayscale');
    if (JSONNumber(Options,'version')<>1) or
      not HexString(JSONText(Options,'engine_sha256'),64) or
      not ((Profile='original') or (Profile='balanced') or (Profile='economy') or (Profile='maximum')) or
      (Length(Identity)<>59) or (Copy(Identity,1,25)<>Text('source_file_key')) or
      (Identity[26]<>':') or (Identity[43]<>':') or
      not HexString(Copy(Identity,27,16),16) or not HexString(Copy(Identity,44,16),16) then
      raise EReadError.Create('Неверные настройки или исходный файл проверки сжатия.');
  end;
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
      if Item.GetValue('retry_original')<>nil then JSONBool(Item,'retry_original');
      if Item.GetValue('checked')<>nil then JSONBool(Item,'checked');
      if Item.GetValue('image_outputs')<>nil then
      begin
        var Images:=JSONArray(Item,'image_outputs');
        if Images.Count>5000 then raise EReadError.Create('Слишком много изображений в журнале сжатия книги.');
        for var Image in Images do
          if not (Image is TJSONString) or not HexString(Image.Value,64) then
            raise EReadError.Create('Неверная контрольная сумма обработанного изображения.');
      end;
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

procedure TBookCompressionReceipt.WriteChecks(DB: TSQLiteDatabase);
var Options, Item: TJSONObject; Current, Key, Profile, Engine: string; Gray: Integer;
begin
  // Older durable receipts remain replayable, without inventing cache proof.
  if FData.GetValue('compression_options')=nil then Exit;
  Options:=TJSONObject(FData.GetValue('compression_options'));
  Current:=ArchiveDeletionSourceIdentity(Text('source'));
  Key:=UpperCase(Text('source_file_key'));
  Profile:=JSONText(Options,'profile'); Gray:=Ord(JSONBool(Options,'grayscale'));
  Engine:=JSONText(Options,'engine_sha256');
  DB.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibreCompressionChecks('+
    'FileKey TEXT NOT NULL,Member TEXT NOT NULL,Profile TEXT NOT NULL,Grayscale INTEGER NOT NULL,'+
    'EngineSHA256 TEXT NOT NULL,SourceIdentity TEXT NOT NULL,SourceSHA256 TEXT NOT NULL,PayloadSHA256 TEXT NOT NULL,'+
    'PRIMARY KEY(FileKey,Member,Profile,Grayscale,EngineSHA256)) WITHOUT ROWID');
  if Text('source_sha256')<>Text('result_sha256') then
    for var Value in JSONArray(FData,'payloads') do
      DB.ExecSQL('DELETE FROM HomeLibreCompressionChecks WHERE FileKey=? AND Member=?',
        [Key,JSONText(TJSONObject(Value),'member')]);
  // Other members were preserved byte-exact. Advance only witnesses for the
  // verified input checksum, including when only its timestamp had changed.
  DB.ExecSQL('UPDATE HomeLibreCompressionChecks SET SourceIdentity=?,SourceSHA256=? '+
    'WHERE FileKey=? AND SourceSHA256=?',
    [Current,LowerCase(Text('result_sha256')),Key,LowerCase(Text('source_sha256'))]);
  for var Value in JSONArray(FData,'payloads') do
  begin
    Item:=TJSONObject(Value);
    // A failed attempt must invalidate this choice's earlier proof, including
    // the same engine. Other quality choices still have their own witnesses.
    DB.ExecSQL('DELETE FROM HomeLibreCompressionChecks WHERE FileKey=? AND Member=? '+
      'AND Profile=? AND Grayscale=?',
      [Key,JSONText(Item,'member'),Profile,Gray]);
    if (Item.GetValue('checked')<>nil) and not JSONBool(Item,'checked') then Continue;
    DB.ExecSQL('INSERT INTO HomeLibreCompressionChecks VALUES(?,?,?,?,?,?,?,?) '+
      'ON CONFLICT(FileKey,Member,Profile,Grayscale,EngineSHA256) DO UPDATE SET '+
      'SourceIdentity=excluded.SourceIdentity,SourceSHA256=excluded.SourceSHA256,PayloadSHA256=excluded.PayloadSHA256',
      [Key,JSONText(TJSONObject(Value),'member'),Profile,Gray,Engine,Current,LowerCase(Text('result_sha256')),
       LowerCase(JSONText(TJSONObject(Value),'output_sha256'))]);
  end;
end;

procedure TBookCompressionReceipt.WriteHistory(DB: TSQLiteDatabase; PreserveKnownInput: Boolean);
var Item: TJSONObject; ImageTableReady, OutcomesReady: Boolean; InputSQL: string;
begin
  DB.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibreBookCompression('+
    'FileKey TEXT NOT NULL,Member TEXT NOT NULL,ProfileSHA256 TEXT NOT NULL,'+
    'InputSHA256 TEXT NOT NULL,OutputSHA256 TEXT NOT NULL,BookSize INTEGER NOT NULL,'+
    'PRIMARY KEY(FileKey,Member))');
  ImageTableReady:=False;
  OutcomesReady:=False; InputSQL:='excluded.InputSHA256';
  if PreserveKnownInput then
    InputSQL:='CASE WHEN HomeLibreBookCompression.ProfileSHA256=excluded.ProfileSHA256 '+
      'AND HomeLibreBookCompression.OutputSHA256=excluded.OutputSHA256 '+
      'THEN HomeLibreBookCompression.InputSHA256 ELSE excluded.InputSHA256 END';
  for var Value in JSONArray(FData,'payloads') do
  begin
    Item:=TJSONObject(Value);
    DB.ExecSQL('INSERT INTO HomeLibreBookCompression VALUES(?,?,?,?,?,?) '+
      'ON CONFLICT(FileKey,Member) DO UPDATE SET ProfileSHA256=excluded.ProfileSHA256,'+
      'InputSHA256='+InputSQL+','+
      'OutputSHA256=excluded.OutputSHA256,BookSize=excluded.BookSize',
      [UpperCase(Text('source_file_key')),JSONText(Item,'member'),LowerCase(Text('profile_sha256')),
       LowerCase(JSONText(Item,'input_sha256')),LowerCase(JSONText(Item,'output_sha256')),JSONNumber(Item,'size')]);
    if Item.GetValue('retry_original')<>nil then
    begin
      if not OutcomesReady then
      begin
        DB.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibreCompressionOutcomes('+
          'FileKey TEXT NOT NULL,Member TEXT NOT NULL,ProfileSHA256 TEXT NOT NULL,'+
          'OutputSHA256 TEXT NOT NULL,RetryOriginal INTEGER NOT NULL,PRIMARY KEY(FileKey,Member)) WITHOUT ROWID');
        OutcomesReady:=True;
      end;
      DB.ExecSQL('INSERT INTO HomeLibreCompressionOutcomes VALUES(?,?,?,?,?) '+
        'ON CONFLICT(FileKey,Member) DO UPDATE SET ProfileSHA256=excluded.ProfileSHA256,'+
        'OutputSHA256=excluded.OutputSHA256,RetryOriginal=excluded.RetryOriginal',
        [UpperCase(Text('source_file_key')),JSONText(Item,'member'),LowerCase(Text('profile_sha256')),
         LowerCase(JSONText(Item,'output_sha256')),Ord(JSONBool(Item,'retry_original'))]);
    end;
    if Item.GetValue('image_outputs')<>nil then
      for var Image in JSONArray(Item,'image_outputs') do
      begin
        if not ImageTableReady then
        begin
          DB.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibreCompressedImages('+
            'ProfileSHA256 TEXT NOT NULL,ImageSHA256 TEXT NOT NULL,'+
            'PRIMARY KEY(ProfileSHA256,ImageSHA256)) WITHOUT ROWID');
          ImageTableReady:=True;
        end;
        DB.ExecSQL('INSERT OR IGNORE INTO HomeLibreCompressedImages(ProfileSHA256,ImageSHA256) VALUES(?,?)',
          [LowerCase(Text('profile_sha256')),LowerCase(Image.Value)]);
      end;
  end;
  WriteChecks(DB);
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
            // Personal cards can be created by a Reader while compression is
            // running, with a corrected actual size instead of INPX's size.
            // The exact library/book locator still has to match; only its
            // BookSize is updated and the newly written notes stay intact.
            ((Kind=1) or (CurrentSize=JSONNumber(Item,'old_size')) or (CurrentSize=NewSize));
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
    if Commit and not Personal then WriteHistory(DB);
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
        if Item.GetValue('image_outputs')<>nil then
          for var Image in JSONArray(Item,'image_outputs') do
          begin
            var ImageQuery:=Catalogue.NewQuery('SELECT 1 FROM HomeLibreCompressedImages WHERE ProfileSHA256=? AND ImageSHA256=?',
              [LowerCase(Text('profile_sha256')),LowerCase(Image.Value)]);
            try
              ImageQuery.Open;
              if ImageQuery.Eof then raise EReadError.Create('Нет подтверждения сохранения истории изображений.');
            finally ImageQuery.Free; end;
          end;
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

procedure TBookCompressionReceipt.RecordInspection(const Cancelled: TFunc<Boolean>);
var Source: TFileStream; Catalogue, Personal: TSQLiteDatabase;
    CatalogueLease, PersonalLease: IInterface; Buffer: TBytes; Count: Integer; Hash: THashSHA2;
begin
  if (Text('source_sha256')<>Text('result_sha256')) or
    (FData.GetValue('compression_options')=nil) then
    raise EReadError.Create('Отметка проверки не должна менять исходную книгу.');
  for var Value in JSONArray(FData,'payloads') do
  begin
    var Item:=TJSONObject(Value);
    if (JSONText(Item,'input_sha256')<>JSONText(Item,'output_sha256')) or
      ((Item.GetValue('image_outputs')<>nil) and (JSONArray(Item,'image_outputs').Count<>0)) then
      raise EReadError.Create('Нельзя запомнить отброшенные изображения как сохранённый результат.');
  end;
  // Hash before acquiring SQLite writer locks. Keep the source unwritable
  // until this metadata-only inspection has committed; personal data is read.
  Source:=TFileStream.Create(DeletionNativePath(Text('source')),fmOpenRead or fmShareDenyWrite);
  try
    if CompressionFileKey(Text('source'))<>Text('source_file_key') then
      raise EReadError.Create('Исходная книга изменилась перед сохранением проверки.');
    Hash:=THashSHA2.Create; SetLength(Buffer,1024*1024);
    repeat
      if Assigned(Cancelled) and Cancelled() then Abort;
      Count:=Source.Read(Buffer[0],Length(Buffer));
      if Count>0 then Hash.Update(Buffer[0],Count);
    until Count=0;
    if not SameText(Hash.HashAsString,Text('source_sha256')) then
      raise EReadError.Create('Исходная книга изменилась; проверка не сохранена.');
    CatalogueLease:=TCompressionDatabaseLease.Create(Text('catalogue'),Text('catalogue_key'));
    PersonalLease:=TCompressionDatabaseLease.Create(Text('personal'),Text('personal_key'));
    Catalogue:=TSQLiteDatabase.Create(Text('catalogue'));
    try
      Personal:=TSQLiteDatabase.CreateReadOnly(Text('personal'));
      try
        Catalogue.SetTimeout(2000); Catalogue.Start('','IMMEDIATE'); Personal.Start;
        ProcessRows(Catalogue,False,False); ProcessRows(Personal,True,False);
        if Assigned(Cancelled) and Cancelled() then Abort;
        WriteHistory(Catalogue,True); Catalogue.Commit;
      finally
        try if Personal.InTransaction then Personal.Rollback; finally Personal.Free; end;
      end;
    finally
      try if Catalogue.InTransaction then Catalogue.Rollback; finally Catalogue.Free; end;
    end;
  finally Source.Free; end;
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
