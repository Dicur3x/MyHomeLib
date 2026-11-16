unit unit_CollectionTransferCatalogue;

interface

uses System.SysUtils, System.Generics.Collections, SQLiteWrap, unit_Globals,
  unit_BookCompressionPlan, unit_CollectionTransferPlan, unit_BookCompressionPlanStore;

type
  TTransferBindingState = (tbsAvailable, tbsMissing, tbsMetadataOnly);
  TTransferCatalogueBinding = record
    ID: Int64;
    Locator: TCompressionLocator;
    Source, CanonicalSource, RootID, Identity, Reason: string;
    State: TTransferBindingState;
  end;
  TTransferBindingVisitor = reference to procedure(const Binding: TTransferCatalogueBinding);

  // Read-only capture of native primary, alternate-copy and personal locators.
  // No catalogue snapshot copy, payload write or original deletion is made.
  TCollectionTransferCatalogue = class
  private
    FInfo: TCollectionInfo;
    FPersonalFile, FCatalogueKey, FPersonalKey, FBaseRoot, FBaseCatalogue, FSourcesJSON: string;
    FStore: TCompressionPlanStore;
    FCatalogue, FPersonal: TSQLiteDatabase;
    FCatalogueLease, FPersonalLease: IInterface;
    FCatalogueVersion, FPersonalVersion, FRowCount: Int64;
    FRoots: TList<TCollectionTransferRoot>;
    FContainers, FAbsentContainers: TDictionary<string,string>;
    FCancelled: TFunc<Boolean>;
    FProgress: TProc<Int64>;
    procedure CheckCancelled;
    function AddRoot(const ID, Path: string): string;
    function RootFor(const Row: TCompressionLocator; const Source: string): string;
    function ResolveSource(const Row: TCompressionLocator; out AbsentContainer: string): string;
    procedure ReadRoots;
    procedure Scan(DB: TSQLiteDatabase; const SQL: string; Kind: Integer);
    procedure InspectCandidates;
  public
    constructor Create(const Info: TCollectionInfo; const PersonalFile, WorkRoot: string;
      const Cancelled: TFunc<Boolean> = nil; const Progress: TProc<Int64> = nil);
    destructor Destroy; override;
    procedure CheckUnchanged;
    procedure ForEachBinding(const Visit: TTransferBindingVisitor);
    procedure ForEachRoot(const Visit: TProc<TCollectionTransferRoot>);
    procedure ForEachMissingContainer(const Visit: TProc<string>);
    function CollectionInfo: TCollectionInfo;
    function BuildFilePlan(const Destination, WorkRoot: string; const OperationID: TGUID): TCollectionTransferPlan;
    function Count(State: TTransferBindingState): Int64;
    function CandidateCount: Int64;
    property RowCount: Int64 read FRowCount;
    property SourcesJSON: string read FSourcesJSON;
    property CatalogueKey: string read FCatalogueKey;
    property PersonalKey: string read FPersonalKey;
    property PersonalFile: string read FPersonalFile;
    property BaseRoot: string read FBaseRoot;
    property BaseCatalogue: string read FBaseCatalogue;
  end;

implementation

uses System.Classes, System.IOUtils, System.JSON, System.Hash, Winapi.Windows, unit_Settings, dm_user,
  unit_Consts, unit_ZipMemberDeletion, unit_BookCompressionReceipt;

const Columns='BookID,LibID,Folder,FileName,Ext,InsideNo,BookSize';
  BindingStateSQL='CASE WHEN b.CandidateID IS NULL THEN b.State WHEN c.Available=1 THEN 0 ELSE 1 END';

function RootPath(const Value:string):string;
begin
  if (Value='') or not TPath.IsPathRooted(Value) then
    raise EReadError.Create('Не указана абсолютная папка источника переноса.');
  Result:=IncludeTrailingPathDelimiter(ExpandFileName(StringReplace(Value,'/','\',[rfReplaceAll])));
end;

function Within(const Path,Root:string):Boolean;
begin Result:=Path.StartsWith(Root,True); end;

function PayloadPresent(const Path:string):Boolean;
begin
  var Attributes:=GetFileAttributes(PChar(DeletionNativePath(Path)));
  if Attributes<>INVALID_FILE_ATTRIBUTES then Exit(True);
  var Code:=GetLastError;
  if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
  Result:=False;
end;

procedure TCollectionTransferCatalogue.CheckCancelled;
begin
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Подготовка переноса остановлена. Книги и каталоги не изменены.');
end;

function TCollectionTransferCatalogue.AddRoot(const ID,Path:string):string;
begin
  Result:=ID; var Normal:=RootPath(Path);
  for var Root in FRoots do
    if Root.ID=ID then
    begin
      if Root.Path<>Normal then raise EReadError.Create('Один источник переноса получил разные папки.');
      Exit;
    end;
  if (ID='') or (FRoots.Count>=4096) then
    raise EReadError.Create('Слишком много отдельных папок источников для одного переноса.');
  var NewRoot:TCollectionTransferRoot; NewRoot.ID:=ID; NewRoot.Path:=Normal; FRoots.Add(NewRoot);
end;

procedure TCollectionTransferCatalogue.ReadRoots;
var Value:TJSONValue;
begin
  AddRoot('collection',FInfo.RootFolder);
  if FCatalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''Settings''')=0 then Exit;
  FSourcesJSON:=FCatalogue.QuerySingleString('SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_CATALOG_SOURCES]);
  if FSourcesJSON='' then Exit;
  Value:=TJSONObject.ParseJSONValue(FSourcesJSON);
  try
    if not (Value is TJSONArray) then raise EReadError.Create('Повреждён список источников коллекции.');
    var Seen:=TDictionary<string,Byte>.Create;
    try
      for var Item in TJSONArray(Value) do
      begin
        if not (Item is TJSONObject) then raise EReadError.Create('Повреждена запись источника коллекции.');
        var ID:=TJSONObject(Item).GetValue<string>('id');
        if (ID='') or Seen.ContainsKey(ID) then raise EReadError.Create('Повторный или пустой номер источника коллекции.');
        Seen.Add(ID,0);
        var Path:=TJSONObject(Item).GetValue<string>('root','');
        if Path<>'' then AddRoot('source:'+ID,Settings.ExpandCollectionRoot(Path));
      end;
    finally Seen.Free; end;
  finally Value.Free; end;
end;

function TCollectionTransferCatalogue.ResolveSource(const Row:TCompressionLocator; out AbsentContainer:string):string;
var Book:TBookRecord; Container,Key,Logical,Fallback:string;
begin
  Book:=Default(TBookRecord); Book.BookKey:=CreateBookKey(Row.BookID,FInfo.ID);
  Book.LibID:=Row.LibID; Book.Folder:=Row.Folder; Book.FileName:=Row.FileName;
  Book.FileExt:=Row.Extension; Book.InsideNo:=Row.InsideNo;
  Book.CollectionRoot:=FInfo.GetRootPath;
  if Row.Root<>'' then Book.CollectionRoot:=RootPath(Settings.ExpandCollectionRoot(Row.Root));
  AbsentContainer:=''; Logical:=TPath.Combine(Book.CollectionRoot,Book.Folder);
  Key:=Book.CollectionRoot+#0+Book.Folder+#0+BoolToStr(Book.IsLinkedSource,True);
  if not FContainers.TryGetValue(Key,Container) then
  begin
    Container:=Book.GetBookContainer;
    // Native ZIP-to-7z resolution, also for hosts without a long-path manifest.
    if not Book.IsLinkedSource and SameText(ExtractFileExt(Logical),'.zip') then
    begin
      if PayloadPresent(Logical) then Container:=Logical
      else
      begin
        Fallback:=ChangeFileExt(Logical,'.7z');
        if PayloadPresent(Fallback) then begin Container:=Fallback; AbsentContainer:=Logical; end
        else begin Container:=Logical; AbsentContainer:=Fallback; end;
      end;
    end;
    if FContainers.Count>=4096 then begin FContainers.Clear; FAbsentContainers.Clear; end;
    FContainers.Add(Key,Container); FAbsentContainers.Add(Key,AbsentContainer);
  end
  else AbsentContainer:=FAbsentContainers[Key];
  Result:=ExpandFileName(StringReplace(Book.GetBookFileName(Container),'/','\',[rfReplaceAll]));
end;

function TCollectionTransferCatalogue.RootFor(const Row:TCompressionLocator; const Source:string):string;
var Best:Integer; Expected:string;
begin
  Expected:=RootPath(FInfo.RootFolder);
  if Row.Root<>'' then
  begin
    Expected:=RootPath(Settings.ExpandCollectionRoot(Row.Root));
    AddRoot('path:'+THashSHA2.GetHashString(Expected),Expected);
  end;
  if not Within(Source,Expected) and not TPath.IsPathRooted(Row.Folder) then
    raise EReadError.Create('Относительный путь книги выходит за пределы её папки: '+Source);
  Result:=''; Best:=0;
  for var Root in FRoots do
    if Within(Source,Root.Path) and (Length(Root.Path)>Best) then
    begin Result:=Root.ID; Best:=Length(Root.Path); end;
  if Result='' then
  begin
    // Explicit absolute/linked locators outside declared source roots are
    // separately reviewed, not silently omitted or flattened by filename.
    Expected:=RootPath(ExtractFilePath(Source));
    Result:=AddRoot('path:'+THashSHA2.GetHashString(Expected),Expected);
  end;
end;

procedure TCollectionTransferCatalogue.Scan(DB:TSQLiteDatabase; const SQL:string; Kind:Integer);
var Q:TSQLiteQuery; Row:TCompressionLocator; Source,RootID,Key,Reason,AbsentContainer:string; Candidate:Int64;
    Cache:TDictionary<string,Int64>; State:TTransferBindingState;
begin
  Q:=DB.NewQuery(SQL); Cache:=TDictionary<string,Int64>.Create;
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckCancelled; Row:=Default(TCompressionLocator); Row.Kind:=Kind;
      Row.BookID:=Q.FieldAsInt(0); Row.LibID:=Q.FieldAsString(1); Row.Folder:=Q.FieldAsString(2);
      Row.FileName:=Q.FieldAsString(3); Row.Extension:=Q.FieldAsString(4);
      Row.InsideNo:=Q.FieldAsInt(5); Row.OldSize:=StrToInt64Def(Q.FieldAsString(6),0);
      if Kind=2 then begin Row.Root:=Q.FieldAsString(7); Row.SourceKey:=Q.FieldAsString(8); end;
      Candidate:=0; Reason:=''; State:=tbsAvailable;
      if Row.FileName='' then
      begin
        if Kind=1 then begin State:=tbsMetadataOnly; Reason:='Личные данные без локального файла.'; end
        else begin State:=tbsMissing; Reason:='В записи не указано имя файла.'; end;
      end
      else
      begin
        Source:=ResolveSource(Row,AbsentContainer); RootID:=RootFor(Row,Source); Key:=RootID+#0+Source;
        if AbsentContainer<>'' then
          FStore.DB.ExecSQL('INSERT OR IGNORE INTO TransferMissingContainers VALUES(?)',[AbsentContainer]);
        if not Cache.TryGetValue(Key,Candidate) then
        begin
          FStore.DB.ExecSQL('INSERT OR IGNORE INTO TransferCandidates(RootID,Path) VALUES(?,?)',[RootID,Source]);
          Candidate:=FStore.DB.QuerySingleInt('SELECT ID FROM TransferCandidates WHERE RootID=? AND Path=?',[RootID,Source]);
          if Cache.Count>=4096 then Cache.Clear;
          Cache.Add(Key,Candidate);
        end;
      end;
      FStore.DB.ExecSQL('INSERT INTO TransferCatalogueBindings(Kind,BookID,LibID,Folder,FileName,Ext,InsideNo,'+
        'BookSize,Root,SourceKey,CandidateID,State,Reason) VALUES(?,?,?,?,?,?,?,?,?,?,nullif(?,0),?,?)',
        [Kind,Row.BookID,Row.LibID,Row.Folder,Row.FileName,Row.Extension,Row.InsideNo,Row.OldSize,
         Row.Root,Row.SourceKey,Candidate,Ord(State),Reason]);
      Inc(FRowCount);
      if FRowCount mod 4096=0 then
      begin
        FStore.DB.ExecSQL('COMMIT'); FStore.DB.ExecSQL('BEGIN');
        if Assigned(FProgress) then FProgress(FRowCount);
      end;
      Q.Next;
    end;
  finally Cache.Free; Q.Free; end;
end;

procedure TCollectionTransferCatalogue.InspectCandidates;
var Q:TSQLiteQuery; Canonical,Identity,Reason,Path:string; Bytes:Int64; Present:Boolean;
begin
  Q:=FStore.DB.NewQuery('SELECT ID,Path FROM TransferCandidates ORDER BY ID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckCancelled; Path:=Q.FieldAsString(1); Present:=PayloadPresent(Path);
      Canonical:=''; Identity:=''; Bytes:=0; Reason:='';
      if Present then TransferReadFileState(Path,Canonical,Identity,Bytes)
      else Reason:='Файл отсутствует: '+Path;
      FStore.DB.ExecSQL('UPDATE TransferCandidates SET Canonical=?,Identity=?,Bytes=?,Available=?,Reason=? WHERE ID=?',
        [Canonical,Identity,Bytes,Ord(Present),Reason,StrToInt64(Q.FieldAsString(0))]);
      Q.Next;
    end;
  finally Q.Free; end;
end;

constructor TCollectionTransferCatalogue.Create(const Info:TCollectionInfo; const PersonalFile,WorkRoot:string;
  const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>);
var Q:TSQLiteQuery;
begin
  inherited Create; FInfo:=Info; FCancelled:=Cancelled; FProgress:=Progress; CheckCancelled;
  if (Info.ID<=0) or (Info.DBFileName='') or isOnlineCollection(Info.CollectionType) then
    raise EArgumentException.Create('Нужна подключённая локальная коллекция.');
  FInfo.DBFileName:=ExpandFileName(Info.DBFileName); FInfo.RootFolder:=RootPath(Info.RootFolder);
  FPersonalFile:=ExpandFileName(PersonalFile);
  FCatalogueKey:=CompressionFileKey(FInfo.DBFileName); FPersonalKey:=CompressionFileKey(FPersonalFile);
  if FCatalogueKey=FPersonalKey then raise EReadError.Create('Каталог и личные данные должны быть разными базами.');
  FCatalogueLease:=AcquireCompressionDatabaseLease(FInfo.DBFileName,FCatalogueKey);
  FPersonalLease:=AcquireCompressionDatabaseLease(FPersonalFile,FPersonalKey);
  FCatalogue:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(FInfo.DBFileName));
  FPersonal:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(FPersonalFile));
  FCatalogueVersion:=FCatalogue.QuerySingleInt('PRAGMA data_version');
  FPersonalVersion:=FPersonal.QuerySingleInt('PRAGMA data_version');
  FCatalogue.ExecSQL('BEGIN'); FPersonal.ExecSQL('BEGIN');
  FRoots:=TList<TCollectionTransferRoot>.Create; FContainers:=TDictionary<string,string>.Create;
  FAbsentContainers:=TDictionary<string,string>.Create;
  Q:=FPersonal.NewQuery('SELECT RootFolder,DBFileName FROM Bases WHERE DatabaseID=?',[Info.ID]);
  try
    Q.Open;
    if Q.Eof then raise EReadError.Create('Коллекция больше не подключена.');
    FBaseRoot:=Q.FieldAsString(0); FBaseCatalogue:=Q.FieldAsString(1);
    if not SameFileName(RootPath(Settings.ExpandCollectionRoot(FBaseRoot)),FInfo.RootFolder) or
      not SameFileName(Settings.ExpandCollectionFileName(FBaseCatalogue),FInfo.DBFileName) then
      raise EReadError.Create('Подключение коллекции изменилось. Повторите подготовку переноса.');
  finally Q.Free; end;
  ReadRoots;
  FStore:=TCompressionPlanStore.Create(WorkRoot);
  FStore.DB.ExecSQL('CREATE TABLE TransferCandidates(ID INTEGER PRIMARY KEY,RootID TEXT NOT NULL,Path TEXT NOT NULL,'+
    'Canonical TEXT,Identity TEXT,Bytes INTEGER,Available INTEGER,Reason TEXT,UNIQUE(RootID,Path))');
  FStore.DB.ExecSQL('CREATE TABLE TransferCatalogueBindings(ID INTEGER PRIMARY KEY,Kind INTEGER NOT NULL,BookID INTEGER NOT NULL,'+
    'LibID TEXT,Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER,Root TEXT,SourceKey TEXT,'+
    'CandidateID INTEGER,State INTEGER NOT NULL,Reason TEXT)');
  FStore.DB.ExecSQL('CREATE INDEX TransferCatalogueBindings_Candidate ON TransferCatalogueBindings(CandidateID)');
  FStore.DB.ExecSQL('CREATE TABLE TransferMissingContainers(Path TEXT NOT NULL PRIMARY KEY) WITHOUT ROWID');
  FStore.DB.ExecSQL('BEGIN');
  Scan(FPersonal,'SELECT '+Columns+' FROM Books WHERE DatabaseID='+IntToStr(Info.ID),1);
  // Release personal read locks before scanning a potentially huge catalogue.
  // The retained connection's data_version still rejects intervening changes.
  FPersonal.ExecSQL('COMMIT');
  Scan(FCatalogue,'SELECT '+Columns+' FROM Books',0);
  if FCatalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')<>0 then
    Scan(FCatalogue,'SELECT '+Columns+',Root,SourceKey FROM CatalogBookCopies',2);
  FCatalogue.ExecSQL('COMMIT'); FContainers.Clear; FAbsentContainers.Clear;
  InspectCandidates; FStore.DB.ExecSQL('COMMIT'); FStore.Seal;
  CheckUnchanged;
  if Assigned(FProgress) then FProgress(FRowCount);
end;

destructor TCollectionTransferCatalogue.Destroy;
begin
  FStore.Free; FContainers.Free; FAbsentContainers.Free; FRoots.Free;
  FPersonal.Free; FCatalogue.Free; FPersonalLease:=nil; FCatalogueLease:=nil;
  inherited;
end;

procedure TCollectionTransferCatalogue.CheckUnchanged;
var Q:TSQLiteQuery; Canonical,Identity:string; Bytes:Int64;
  procedure CheckDatabases;
  begin
    CheckCancelled;
    if (CompressionFileKey(FInfo.DBFileName)<>FCatalogueKey) or
      (CompressionFileKey(FPersonalFile)<>FPersonalKey) or
      (FCatalogue.QuerySingleInt('PRAGMA data_version')<>FCatalogueVersion) or
      (FPersonal.QuerySingleInt('PRAGMA data_version')<>FPersonalVersion) then
      raise EReadError.Create('Каталог или личные данные изменились. Повторите подготовку переноса.');
  end;
begin
  CheckDatabases;
  Q:=FStore.DB.NewQuery('SELECT Path FROM TransferMissingContainers');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckCancelled;
      if PayloadPresent(Q.FieldAsString(0)) then
        raise EReadError.Create('Изменился выбор ZIP/7z-контейнера. Повторите подготовку переноса.');
      Q.Next;
    end;
  finally Q.Free; end;
  Q:=FStore.DB.NewQuery('SELECT Path,Canonical,Identity,Available FROM TransferCandidates ORDER BY ID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckCancelled;
      if Q.FieldAsInt(3)<>0 then
      begin
        TransferReadFileState(Q.FieldAsString(0),Canonical,Identity,Bytes);
        if (Canonical<>Q.FieldAsString(1)) or (Identity<>Q.FieldAsString(2)) then
          raise EReadError.Create('Файл изменился после подготовки переноса.');
      end
      else if PayloadPresent(Q.FieldAsString(0)) then
        raise EReadError.Create('Появился ранее отсутствовавший файл. Повторите подготовку переноса.');
      Q.Next;
    end;
  finally Q.Free; end;
  CheckDatabases;
end;

procedure TCollectionTransferCatalogue.ForEachBinding(const Visit:TTransferBindingVisitor);
var Q:TSQLiteQuery; Row:TTransferCatalogueBinding;
begin
  if not Assigned(Visit) then Exit;
  Q:=FStore.DB.NewQuery('SELECT b.ID,b.Kind,b.BookID,b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.BookSize,b.Root,b.SourceKey,'+
    'c.Path,c.Canonical,c.RootID,c.Identity,'+BindingStateSQL+',CASE WHEN b.CandidateID IS NULL THEN b.Reason ELSE c.Reason END '+
    'FROM TransferCatalogueBindings b LEFT JOIN TransferCandidates c ON c.ID=b.CandidateID ORDER BY b.ID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckCancelled; Row:=Default(TTransferCatalogueBinding);
      Row.ID:=StrToInt64(Q.FieldAsString(0)); Row.Locator.Kind:=Q.FieldAsInt(1); Row.Locator.BookID:=Q.FieldAsInt(2);
      Row.Locator.LibID:=Q.FieldAsString(3); Row.Locator.Folder:=Q.FieldAsString(4); Row.Locator.FileName:=Q.FieldAsString(5);
      Row.Locator.Extension:=Q.FieldAsString(6); Row.Locator.InsideNo:=Q.FieldAsInt(7); Row.Locator.OldSize:=StrToInt64(Q.FieldAsString(8));
      Row.Locator.Root:=Q.FieldAsString(9); Row.Locator.SourceKey:=Q.FieldAsString(10);
      Row.Source:=Q.FieldAsString(11); Row.CanonicalSource:=Q.FieldAsString(12); Row.RootID:=Q.FieldAsString(13);
      Row.Identity:=Q.FieldAsString(14); Row.State:=TTransferBindingState(Q.FieldAsInt(15)); Row.Reason:=Q.FieldAsString(16);
      Visit(Row); Q.Next;
    end;
  finally Q.Free; end;
end;

function TCollectionTransferCatalogue.Count(State:TTransferBindingState):Int64;
begin
  Result:=FStore.DB.QuerySingleInt('SELECT count(*) FROM TransferCatalogueBindings b LEFT JOIN TransferCandidates c '+
    'ON c.ID=b.CandidateID WHERE '+BindingStateSQL+'=?',[Ord(State)]);
end;

function TCollectionTransferCatalogue.CandidateCount:Int64;
begin Result:=FStore.DB.QuerySingleInt('SELECT count(*) FROM TransferCandidates'); end;

procedure TCollectionTransferCatalogue.ForEachRoot(const Visit:TProc<TCollectionTransferRoot>);
begin
  if Assigned(Visit) then
    for var Root in FRoots do begin CheckCancelled; Visit(Root); end;
end;

function TCollectionTransferCatalogue.CollectionInfo:TCollectionInfo;
begin Result:=FInfo; end;

procedure TCollectionTransferCatalogue.ForEachMissingContainer(const Visit:TProc<string>);
begin
  if not Assigned(Visit) then Exit;
  var Q:=FStore.DB.NewQuery('SELECT Path FROM TransferMissingContainers ORDER BY Path');
  try
    Q.Open;
    while not Q.Eof do begin CheckCancelled; Visit(Q.FieldAsString(0)); Q.Next; end;
  finally Q.Free; end;
end;

function TCollectionTransferCatalogue.BuildFilePlan(const Destination,WorkRoot:string; const OperationID:TGUID):TCollectionTransferPlan;
var Roots:TArray<TCollectionTransferRoot>;
begin
  CheckUnchanged; Roots:=nil;
  for var Root in FRoots do
    if DirectoryExists(DeletionNativePath(Root.Path)) then
    begin SetLength(Roots,Length(Roots)+1); Roots[High(Roots)]:=Root; end;
  if (Length(Roots)=0) or (FStore.DB.QuerySingleInt('SELECT count(*) FROM TransferCandidates WHERE Available=1')=0) then
    raise EReadError.Create('Нет доступных локальных файлов для переноса.');
  Result:=TCollectionTransferPlan.Create(Destination,WorkRoot,Roots,
    procedure(const Visit:TCollectionTransferVisitor)
    var Q:TSQLiteQuery; Input:TCollectionTransferInput;
    begin
      Q:=FStore.DB.NewQuery('SELECT RootID,Path FROM TransferCandidates WHERE Available=1 ORDER BY ID');
      try
        Q.Open;
        while not Q.Eof do
        begin
          CheckCancelled; Input.RootID:=Q.FieldAsString(0); Input.FileName:=Q.FieldAsString(1);
          Visit(Input); Q.Next;
        end;
      finally Q.Free; end;
    end,OperationID,FCancelled);
  try CheckUnchanged;
  except Result.Free; Result:=nil; raise; end;
end;

end.
