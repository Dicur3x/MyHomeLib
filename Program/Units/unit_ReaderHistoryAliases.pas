unit unit_ReaderHistoryAliases;

interface

uses System.SysUtils, System.Generics.Collections, SQLiteWrap, unit_Globals, unit_ReaderHistoryEvidence;

type
  // Borrows the existing personal connection; never opens a database per book.
  TReaderHistoryAliasLookup=class
  private
    FDB:TSQLiteDatabase;
    FQuery:TSQLiteQuery;
    FChecked,FPresent:Boolean;
  public
    constructor Create(DB:TSQLiteDatabase);
    destructor Destroy; override;
    procedure Invalidate;
    function Find(const Book:TBookRecord; const CurrentName:string; out OriginalName:string):Boolean;
  end;

  // Caller owns the personal transaction together with the locator receipt.
  TReaderHistoryAliasWriter=class
  private
    FDB:TSQLiteDatabase;
    FLookup:TReaderHistoryAliasLookup;
    FInsert:TSQLiteQuery;
    FOperation,FReviewSHA:string;
    FNextSpaceCheck:UInt64;
    FEvidence:TReaderHistoryEvidence;
    procedure PrepareInsert;
  public
    constructor Create(DB:TSQLiteDatabase; const Operation,ReviewSHA:string);
    destructor Destroy; override;
    function RecordMove(const Before,After:TBookRecord; RequireExisting:Boolean):string;
    // Reads and validates a saved mapping without creating a personal card or alias.
    function ExistingBinding(const Book:TBookRecord):string;
  end;

implementation

uses System.Classes, System.Hash, System.JSON, System.IOUtils, Winapi.Windows,
  unit_ReaderCache;

const AliasTable='HomeLibreReaderHistoryAliases';

function LocationSHA(const Book:TBookRecord):string;
begin
  var Location:=ReaderBookPhysicalIdentity(Book);
  if Location='' then
  begin
    var Value:=TJSONArray.Create;
    try
      Value.Add(Book.CollectionRoot); Value.Add(Book.Folder); Value.Add(Book.FileName);
      Value.Add(Book.FileExt); Value.Add(Book.InsideNo); Location:='unnamed:'+Value.ToJSON;
    finally Value.Free; end;
  end;
  Result:=THashSHA2.GetHashString(Location);
end;

function MappingSHA(const Book:TBookRecord; const Location,CurrentName,OriginalName:string):string;
begin
  var Value:=TJSONArray.Create;
  try
    Value.Add('HomeLibre reader history alias v1'); Value.Add(Book.BookKey.DatabaseID);
    Value.Add(Book.BookKey.BookID); Value.Add(Book.LibID); Value.Add(Location);
    Value.Add(CurrentName); Value.Add(OriginalName); Result:=THashSHA2.GetHashString(Value.ToJSON);
  finally Value.Free; end;
end;

procedure CheckName(const Name:string; CID:Integer);
begin
  var Prefix:='homelib-'+IntToStr(CID)+'-';
  if not Name.StartsWith(Prefix) or (Length(Name)>128) or (Length(Name)<Length(Prefix)+34) or
    (ExtractFileName(Name)<>Name) or (Name[Length(Prefix)+33]<>'.') then
    raise EReadError.Create('Неверный сохранённый ключ истории чтения.');
  for var I:=Length(Prefix)+1 to Length(Prefix)+32 do
    if not CharInSet(Name[I],['0'..'9','a'..'f','A'..'F']) then
      raise EReadError.Create('Неверный хеш ключа истории чтения.');
  for var I:=Length(Prefix)+33 to Length(Name) do
    if CharInSet(Name[I],[#0,'\','/',':','*','?','"','<','>','|']) then
      raise EReadError.Create('Неверное имя истории чтения.');
end;

constructor TReaderHistoryAliasLookup.Create(DB:TSQLiteDatabase);
begin inherited Create; FDB:=DB; end;

destructor TReaderHistoryAliasLookup.Destroy;
begin FQuery.Free; inherited; end;

procedure TReaderHistoryAliasLookup.Invalidate;
begin
  TMonitor.Enter(Self);
  try FreeAndNil(FQuery); FChecked:=False; FPresent:=False;
  finally TMonitor.Exit(Self); end;
end;

function TReaderHistoryAliasLookup.Find(const Book:TBookRecord; const CurrentName:string;
  out OriginalName:string):Boolean;
begin
  Result:=False; OriginalName:='';
  if (Book.BookKey.DatabaseID<=0) or (Book.BookKey.BookID<=0) then Exit;
  TMonitor.Enter(Self);
  try
    if not FChecked then
    begin
      FPresent:=FDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[AliasTable])=1;
      FChecked:=True;
    end;
    if not FPresent then Exit;
    if FQuery=nil then FQuery:=FDB.NewQuery('SELECT OriginalName,MappingSHA256 FROM '+AliasTable+
      ' WHERE CollectionID=? AND BookID=? AND LibID=? AND LocationSHA256=? AND CurrentName=?');
    var Location:=LocationSHA(Book);
    FQuery.Reset; FQuery.SetParam(0,Book.BookKey.DatabaseID); FQuery.SetParam(1,Book.BookKey.BookID);
    FQuery.SetParam(2,Book.LibID); FQuery.SetParam(3,Location); FQuery.SetParam(4,CurrentName);
    try
      FQuery.Open; if FQuery.Eof then Exit;
      OriginalName:=FQuery.FieldAsString(0); CheckName(OriginalName,Book.BookKey.DatabaseID);
      if FQuery.FieldAsString(1)<>MappingSHA(Book,Location,CurrentName,OriginalName) then
        raise EReadError.Create('Сохранённая связь истории чтения изменена.');
      Result:=True;
    finally FQuery.Reset; end;
  finally TMonitor.Exit(Self); end;
end;

constructor TReaderHistoryAliasWriter.Create(DB:TSQLiteDatabase; const Operation,ReviewSHA:string);
begin
  inherited Create;
  if (DB=nil) or not DB.InTransaction or (Operation='') or (Length(ReviewSHA)<>64) then
    raise EArgumentException.Create('Нужна привязанная транзакция истории чтения.');
  FDB:=DB; FOperation:=Operation; FReviewSHA:=ReviewSHA; FLookup:=TReaderHistoryAliasLookup.Create(DB); FEvidence:=TReaderHistoryEvidence.Create;
end;

destructor TReaderHistoryAliasWriter.Destroy;
begin FEvidence.Free; FInsert.Free; FLookup.Free; inherited; end;

procedure TReaderHistoryAliasWriter.PrepareInsert;
begin
  if GetTickCount64>=FNextSpaceCheck then
  begin
    var Root:=GetEnvironmentVariable('SystemDrive'); if Root='' then Root:='C:';
    var FreeBytes,TotalBytes:UInt64;
    if not GetDiskFreeSpaceEx(PChar(IncludeTrailingPathDelimiter(Root)),FreeBytes,TotalBytes,nil) then RaiseLastOSError;
    if FreeBytes<UInt64(8)*1024*1024*1024 then
      raise EWriteError.Create('На системном диске осталось меньше 8 ГБ. Перенос остановлен; готовые данные и журнал сохранены.');
    FNextSpaceCheck:=GetTickCount64+1000;
  end;
  if FInsert<>nil then Exit;
  FDB.ExecSQL('CREATE TABLE IF NOT EXISTS '+AliasTable+'(CollectionID INTEGER NOT NULL,BookID INTEGER NOT NULL,'+
    'LibID TEXT NOT NULL,LocationSHA256 TEXT NOT NULL,CurrentName TEXT NOT NULL,OriginalName TEXT NOT NULL,'+
    'MappingSHA256 TEXT NOT NULL,Operation TEXT NOT NULL,ReviewSHA256 TEXT NOT NULL,'+
    'PRIMARY KEY(CollectionID,BookID,LibID,LocationSHA256,CurrentName)) WITHOUT ROWID');
  FLookup.Invalidate;
  FInsert:=FDB.NewQuery('INSERT INTO '+AliasTable+' VALUES(?,?,?,?,?,?,?,?,?)');
end;

function TReaderHistoryAliasWriter.ExistingBinding(const Book:TBookRecord):string;
begin
  Result:='';
  if (Book.BookKey.BookID<=0) or (Book.BookKey.DatabaseID<=0) then
    raise EReadError.Create('История чтения относится к другой книге.');
  if not ReaderHistoryNeedsLocationProof(Book,'') then Exit;
  var Name:=ReaderBaseHistoryName(Book,''); var OriginalName:string;
  if FLookup.Find(Book,Name,OriginalName) then
    Result:=MappingSHA(Book,LocationSHA(Book),Name,OriginalName);
end;

function TReaderHistoryAliasWriter.RecordMove(const Before,After:TBookRecord; RequireExisting:Boolean):string;
begin
  Result:='';
  if not Before.BookKey.IsSameAs(After.BookKey) or (Before.LibID<>After.LibID) or
    (Before.BookKey.BookID<=0) or (Before.BookKey.DatabaseID<=0) then
    raise EReadError.Create('История чтения относится к другой книге.');
  if not ReaderHistoryNeedsLocationProof(Before,'') and not ReaderHistoryNeedsLocationProof(After,'') then Exit;
  var PriorName:=ReaderBaseHistoryName(Before,''); var CurrentName:=ReaderBaseHistoryName(After,'');
  var OriginalName:string;
  var HasPriorAlias:=FLookup.Find(Before,PriorName,OriginalName);
  var Variants:=TList<string>.Create;
  var StoredCount:=0;
  try
    Variants.Add(PriorName);
    // Only equivalent physical representations of this exact book qualify.
    // No other book/history name is accepted as a benign legacy variant.
    if ReaderHistoryUsesStoredFolder(Before) then
    begin
      var Physical:=ReaderBookPhysicalIdentity(Before);
      for var Absolute in [False,True] do
      begin
        var Variant:=Before;
        if Absolute then Variant.Folder:=ExpandFileName(TPath.Combine(Before.CollectionRoot,Before.Folder))
        else if TPath.IsPathRooted(Before.Folder) then
          Variant.Folder:=ExtractRelativePath(IncludeTrailingPathDelimiter(ExpandFileName(Before.CollectionRoot)),ExpandFileName(Before.Folder));
        if (Physical<>'') and (Physical=ReaderBookPhysicalIdentity(Variant)) then
        begin
          var Name:=ReaderBaseHistoryName(Variant,'');
          if not Variants.Contains(Name) then Variants.Add(Name);
        end;
      end;
    end;
    if not HasPriorAlias then
    begin
      OriginalName:=PriorName;
      if Variants.Count>1 then
        for var Name in Variants do
          if FEvidence.Contains(Name) then begin Inc(StoredCount); OriginalName:=Name; end;
      if StoredCount>1 then
        raise EReadError.Create('Для одной книги сохранены две истории чтения по разным старым путям. Перенос остановлен; обе истории сохранены.');
    end;
  var Location:=LocationSHA(After);
  if (LocationSHA(Before)=Location) and (PriorName=CurrentName) and (OriginalName=CurrentName) then Exit;
  CheckName(CurrentName,After.BookKey.DatabaseID); CheckName(OriginalName,After.BookKey.DatabaseID);
  Result:=MappingSHA(After,Location,CurrentName,OriginalName);
  var Existing:string;
  if FLookup.Find(After,CurrentName,Existing) then
  begin
    if Existing<>OriginalName then
    begin
      if HasPriorAlias or (StoredCount<>0) or not Variants.Contains(Existing) then
        raise EReadError.Create('Конфликт сохранённых историй чтения. Обе истории оставлены без изменений.');
      // The other representation has no saved reader state. Reuse the exact
      // already validated binding instead of creating a conflicting mapping.
      FEvidence.CheckStable;
      Result:=MappingSHA(After,Location,CurrentName,Existing);
    end;
    Exit;
  end;
  if RequireExisting then raise EReadError.Create('Потеряна подтверждённая связь истории чтения.');
  PrepareInsert;
  FInsert.Reset; FInsert.SetParam(0,After.BookKey.DatabaseID); FInsert.SetParam(1,After.BookKey.BookID);
  FInsert.SetParam(2,After.LibID); FInsert.SetParam(3,Location); FInsert.SetParam(4,CurrentName);
  FInsert.SetParam(5,OriginalName); FInsert.SetParam(6,Result); FInsert.SetParam(7,FOperation); FInsert.SetParam(8,FReviewSHA);
  FInsert.ExecSQL;
  if FDB.LastChangedRows<>1 then raise EWriteError.Create('Не сохранена связь истории чтения.');
  finally Variants.Free; end;
end;

end.
