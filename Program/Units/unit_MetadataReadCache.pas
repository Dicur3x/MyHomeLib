unit unit_MetadataReadCache;

interface

uses System.SysUtils, SQLiteWrap, unit_FB2PublisherMetadataReader;

type
  // Successful, bounded reads only. The catalogue and the source books are
  // never opened for writing here. One instance belongs to one scan thread.
  TMetadataReadCache = class
  private
    FDatabase: TSQLiteDatabase;
    FPending: Integer;
    FBatchReady: Boolean;
    FLastCommit: UInt64;
  public
    constructor Create;
    destructor Destroy; override;
    function TryRead(const SourceKey: string; out Metadata: TFB2CatalogMetadata): Boolean;
    procedure Store(const SourceKey: string; const Metadata: TFB2CatalogMetadata);
    procedure Flush;
  end;

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.JSON, System.ZLib,
  unit_Settings, dm_user;

const
  CacheApplicationID = $484C4D52;
  CacheVersion = 1;
  MaxPayloadBytes = 256 * 1024;
  CacheTable = 'CREATE TABLE Reads (SourceKey TEXT PRIMARY KEY NOT NULL, Payload BLOB NOT NULL) WITHOUT ROWID';

function EncodeMetadata(const Metadata: TFB2CatalogMetadata): string;
var Value: TJSONObject;
begin
  Value:=TJSONObject.Create;
  try
    Value.AddPair('publisher',Metadata.Publisher); Value.AddPair('city',Metadata.City);
    Value.AddPair('year',TJSONNumber.Create(Metadata.PubYear)); Value.AddPair('isbn',Metadata.ISBN);
    Value.AddPair('translators',Metadata.Translators); Value.AddPair('annotation',Metadata.Annotation);
    Result:=Value.ToJSON;
  finally Value.Free; end;
end;

constructor TMetadataReadCache.Create;
var Folder, FileName: string; Attributes: DWORD; Existing: TSQLiteDatabase;
begin
  inherited;
  Folder:=TPath.Combine(Settings.DataPath,'MetadataScan');
  if not ForceDirectories(Folder) then RaiseLastOSError;
  FileName:=TPath.Combine(Folder,'reads-v1.sqlite');
  Attributes:=GetFileAttributes(PChar(FileName));
  if Attributes<>INVALID_FILE_ATTRIBUTES then
  begin
    if Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0 then
      raise EReadError.Create('Некорректный файл сохранённых сведений книг');
    // Check ownership before opening an existing file for writing.
    Existing:=TSQLiteDatabase.CreateReadOnly(FileName);
    try
      if (Existing.QuerySingleInt('PRAGMA application_id')<>CacheApplicationID) or
         (Existing.QuerySingleInt('PRAGMA user_version')<>CacheVersion) or
         (Existing.QuerySingleString('SELECT sql FROM sqlite_master WHERE name=''Reads''')<>CacheTable) then
        raise EReadError.Create('Файл сохранённых сведений имеет неизвестный формат. Он не изменён.');
    finally Existing.Free; end;
  end;
  FDatabase:=TSQLiteDatabase.Create(FileName); FDatabase.SetTimeout(1000);
  if Attributes=INVALID_FILE_ATTRIBUTES then
  begin
    FDatabase.Start;
    try
      FDatabase.ExecSQL(CacheTable);
      FDatabase.ExecSQL('PRAGMA application_id='+IntToStr(CacheApplicationID));
      FDatabase.ExecSQL('PRAGMA user_version='+IntToStr(CacheVersion)); FDatabase.Commit;
    except FDatabase.Rollback; raise; end;
  end;
  if not SameText(FDatabase.QuerySingleString('PRAGMA journal_mode=WAL'),'wal') then
    raise EReadError.Create('Не удалось открыть журнал сохранённых сведений');
  FDatabase.ExecSQL('PRAGMA synchronous=FULL');
  FDatabase.BeginQueryBatch; FBatchReady:=True; FLastCommit:=GetTickCount64;
end;

destructor TMetadataReadCache.Destroy;
begin
  try
    if Assigned(FDatabase) then
    begin
      Flush; if FBatchReady then FDatabase.EndQueryBatch;
    end;
  finally FDatabase.Free; inherited; end;
end;

function TMetadataReadCache.TryRead(const SourceKey: string; out Metadata: TFB2CatalogMetadata): Boolean;
var Query: TSQLiteQuery; Compressed: TStream; Decoder: TZDecompressionStream;
  Raw: TMemoryStream; Buffer: array[0..4095] of Byte; N: Integer;
  Bytes: TBytes; Value: TJSONValue; Obj: TJSONObject;
begin
  Result:=False; Metadata:=Default(TFB2CatalogMetadata);
  Query:=FDatabase.NewQuery('SELECT Payload FROM Reads WHERE SourceKey=?',[SourceKey]);
  try
    Query.Open; if Query.Eof then Exit;
    Compressed:=Query.FieldAsBlob(0);
    try
      if (Compressed.Size<1) or (Compressed.Size>MaxPayloadBytes) then Exit;
      try
      Decoder:=TZDecompressionStream.Create(Compressed); Raw:=TMemoryStream.Create;
      try
        repeat
          N:=Decoder.Read(Buffer,SizeOf(Buffer));
          if Raw.Size+N>MaxPayloadBytes then Exit;
          if N>0 then Raw.WriteBuffer(Buffer,N);
        until N=0;
        SetLength(Bytes,Raw.Size); Raw.Position:=0;
        if Length(Bytes)>0 then Raw.ReadBuffer(Bytes[0],Length(Bytes));
        Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
        try
          if not (Value is TJSONObject) then Exit;
          Obj:=TJSONObject(Value); if Obj.Count<>6 then Exit;
          Metadata.Publisher:=Obj.GetValue<string>('publisher'); Metadata.City:=Obj.GetValue<string>('city');
          Metadata.PubYear:=Obj.GetValue<Integer>('year'); Metadata.ISBN:=Obj.GetValue<string>('isbn');
          Metadata.Translators:=Obj.GetValue<string>('translators'); Metadata.Annotation:=Obj.GetValue<string>('annotation');
          Result:=True;
        finally Value.Free; end;
      finally Raw.Free; Decoder.Free; end;
      except
        on E: EOutOfMemory do raise;
        on E: EAccessViolation do raise;
        on E: Exception do begin Metadata:=Default(TFB2CatalogMetadata); Result:=False; end;
      end;
    finally Compressed.Free; end;
  finally Query.Free; end;
end;

procedure TMetadataReadCache.Store(const SourceKey: string; const Metadata: TFB2CatalogMetadata);
var Bytes: TBytes; Compressed: TMemoryStream; Encoder: TZCompressionStream; Query: TSQLiteQuery;
begin
  Bytes:=TEncoding.UTF8.GetBytes(EncodeMetadata(Metadata));
  // Oversized package descriptions must not abort other successful reads.
  if Length(Bytes)>MaxPayloadBytes then Exit;
  Compressed:=TMemoryStream.Create;
  try
    Encoder:=TZCompressionStream.Create(Compressed);
    try if Length(Bytes)>0 then Encoder.WriteBuffer(Bytes[0],Length(Bytes));
    finally Encoder.Free; end;
    if not FDatabase.InTransaction then FDatabase.Start;
    Query:=FDatabase.NewQuery('INSERT OR REPLACE INTO Reads(SourceKey,Payload) VALUES (?,?)');
    try
      Query.SetParam(0,SourceKey); Compressed.Position:=0; Query.SetBlobParam(1,Compressed); Query.ExecSQL;
    finally Query.Free; end;
    Inc(FPending);
    if (FPending>=64) or (GetTickCount64-FLastCommit>=2000) then Flush;
  finally Compressed.Free; end;
end;

procedure TMetadataReadCache.Flush;
begin
  if FDatabase.InTransaction then FDatabase.Commit;
  FPending:=0; FLastCommit:=GetTickCount64;
end;

end.
