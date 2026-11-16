unit unit_CollectionTransferReferences;

interface

uses System.SysUtils, SQLiteWrap;

// Writes only the owning transfer's not-yet-sealed review. Registered catalogue
// and personal databases stay read-only. Unknown references retain originals.
procedure CaptureTransferReferences(Review:TSQLiteDatabase; const PersonalFile:string;
  const Cancelled:TFunc<Boolean> = nil; const Progress:TProc<Int64> = nil);
function TransferReferenceConflictCount(Review:TSQLiteDatabase):Int64;
function TransferReferenceRequiresRetention(Review:TSQLiteDatabase; FileID:Int64):Boolean;

{$IFDEF MHL_TRANSFER_TEST}
var TransferReferenceTestPoint:TProc<string>;
{$ENDIF}

implementation

uses System.Classes, System.IOUtils, System.JSON, System.Generics.Collections,
  Winapi.Windows, unit_Globals, unit_Consts, unit_Settings, dm_user,
  unit_CollectionTransferPlan, unit_BookCompressionReceipt, unit_ZipMemberDeletion,
  unit_MHLArchiveHelpers;

type
  TPathInfo = record
    Canonical, FileKey, Error: string;
    FileID: Int64;
    FileLink: Boolean;
  end;
  TReferenceScan = class
  private
    FReview,FPersonal:TSQLiteDatabase;
    FCancelled:TFunc<Boolean>;
    FProgress:TProc<Int64>;
    FExamined:Int64;
    FPaths:TDictionary<string,TPathInfo>;
    FContainers,FRootCanonical:TDictionary<string,string>;
    FResources:TDictionary<string,Byte>;
    FConnections:TObjectList<TSQLiteDatabase>;
    FLeases:TList<IInterface>;
    FVersions:TList<Int64>;
    FRoots:TList<string>;
    procedure CheckStop;
    procedure Issue(CID:Integer; const Path,Reason:string);
    procedure ReadRegistrations;
    function Probe(const Path:string):TPathInfo;
    function Resolve(var Book:TBookRecord):string;
    function AliasReason(const Path:string; const Info:TPathInfo):string;
    procedure AddReference(CID,Kind:Integer; Q:TSQLiteQuery; const Book:TBookRecord;
      const Source:string; const Info:TPathInfo; FileID:Int64; const SourceKey,Reason,Owner:string; Resource:Boolean);
    procedure Scan(DB:TSQLiteDatabase; const SQL:string; const Registration:TCollectionInfo;
      const CatalogueKey:string; Kind:Integer; Shared:Boolean);
    procedure Resources(CID,Kind:Integer; Q:TSQLiteQuery; const Book:TBookRecord;
      const Source,SourceKey:string; OwnerFileID:Int64);
    procedure SetRoots(const DefaultRoot,SourceJSON:string);
  public
    constructor Create(Review:TSQLiteDatabase; const PersonalFile:string;
      const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>);
    destructor Destroy; override;
    procedure Run;
  end;

procedure TReferenceScan.CheckStop;
begin
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Проверка ссылок остановлена. Каталоги и книги не изменены.');
end;

procedure TReferenceScan.Issue(CID:Integer; const Path,Reason:string);
begin
  FReview.ExecSQL('INSERT OR IGNORE INTO ReferenceIssues VALUES(?,?,?)',[CID,Path,Reason]);
end;

function TReferenceScan.Probe(const Path:string):TPathInfo;
var Handle:THandle; Info:TByHandleFileInformation;
begin
  if FPaths.TryGetValue(Path,Result) then Exit;
  Result:=Default(TPathInfo);
  var Attr:=GetFileAttributes(PChar(DeletionNativePath(Path)));
  if Attr<>INVALID_FILE_ATTRIBUTES then Result.FileLink:=Attr and FILE_ATTRIBUTE_REPARSE_POINT<>0;
  Handle:=CreateFile(PChar(DeletionNativePath(Path)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,0);
  if Handle=INVALID_HANDLE_VALUE then
  begin
    var Code:=GetLastError;
    if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then Result.Error:=SysErrorMessage(Code);
  end
  else
  try
    if not GetFileInformationByHandle(Handle,Info) then Result.Error:=SysErrorMessage(GetLastError)
    else if Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY<>0 then Result.Error:='Вместо файла указана папка.'
    else
    begin
      Result.Canonical:=TransferFinalHandlePath(Handle);
      Result.FileKey:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
      Result.FileID:=FReview.QuerySingleInt('SELECT FileID FROM ReferenceTargets WHERE FileKey=?',[Result.FileKey]);
    end;
  finally CloseHandle(Handle); end;
  if FPaths.Count>=4096 then FPaths.Clear;
  FPaths.Add(Path,Result);
end;

function TReferenceScan.Resolve(var Book:TBookRecord):string;
var Container,Key,Logical:string;
begin
  Key:=Book.CollectionRoot+#0+Book.Folder+#0+BoolToStr(Book.IsLinkedSource,True);
  if not FContainers.TryGetValue(Key,Container) then
  begin
    Container:=Book.GetBookContainer; Logical:=TPath.Combine(Book.CollectionRoot,Book.Folder);
    if not Book.IsLinkedSource and SameText(ExtractFileExt(Logical),'.zip') then
    begin
      if GetFileAttributes(PChar(DeletionNativePath(Logical)))<>INVALID_FILE_ATTRIBUTES then Container:=Logical
      else if GetFileAttributes(PChar(DeletionNativePath(ChangeFileExt(Logical,'.7z'))))<>INVALID_FILE_ATTRIBUTES then
        Container:=ChangeFileExt(Logical,'.7z');
    end;
    if FContainers.Count>=4096 then FContainers.Clear;
    FContainers.Add(Key,Container);
  end;
  Result:=ExpandFileName(StringReplace(Book.GetBookFileName(Container),'/','\',[rfReplaceAll]));
end;

procedure TReferenceScan.SetRoots(const DefaultRoot,SourceJSON:string);
begin
  FRoots.Clear; FRoots.Add(IncludeTrailingPathDelimiter(DefaultRoot));
  if SourceJSON='' then Exit;
  var Value:=TJSONObject.ParseJSONValue(SourceJSON);
  try
    if not (Value is TJSONArray) then raise EReadError.Create('Повреждён список источников.');
    for var Item in TJSONArray(Value) do
    begin
      if not (Item is TJSONObject) then raise EReadError.Create('Повреждена запись источника.');
      var Root:=TJSONObject(Item).GetValue<string>('root','');
      if Root<>'' then FRoots.Add(IncludeTrailingPathDelimiter(Settings.ExpandCollectionRoot(Root)));
    end;
  finally Value.Free; end;
end;

function TReferenceScan.AliasReason(const Path:string; const Info:TPathInfo):string;
var Root,Canonical:string;
begin
  Result:=''; if Info.FileLink then Exit('Ссылка на файл требует сохранения исходника.');
  Root:='';
  for var Candidate in FRoots do
    if Path.StartsWith(Candidate,True) and (Length(Candidate)>Length(Root)) then Root:=Candidate;
  if Root='' then Root:=IncludeTrailingPathDelimiter(ExtractFileDir(Path));
  try
    if not FRootCanonical.TryGetValue(Root,Canonical) then
    begin
      Canonical:=TransferCanonicalDirectory(Root);
      if FRootCanonical.Count>=4096 then FRootCanonical.Clear;
      FRootCanonical.Add(Root,Canonical);
    end;
    if not SameFileName(Canonical+Copy(Path,Length(Root)+1,MaxInt),Info.Canonical) then
      Result:='Внутренняя ссылка меняет расположение книги относительно источника.';
  except on E:Exception do Result:='Не удалось проверить папку ссылки: '+E.Message; end;
end;

procedure TReferenceScan.AddReference(CID,Kind:Integer; Q:TSQLiteQuery; const Book:TBookRecord;
  const Source:string; const Info:TPathInfo; FileID:Int64; const SourceKey,Reason,Owner:string; Resource:Boolean);
begin
  FReview.ExecSQL('INSERT INTO RegisteredReferences(RegistrationID,Kind,BookID,SourceKey,LibID,Folder,FileName,Ext,'+
    'InsideNo,CopyRoot,Source,Canonical,FileKey,FileID,RetainReason,Owner,Resource) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    [CID,Kind,Q.FieldAsInt(0),SourceKey,Book.LibID,Book.Folder,Book.FileName,Book.FileExt,Book.InsideNo,
     Q.FieldAsString(7),Source,Info.Canonical,Info.FileKey,FileID,Reason,Owner,Ord(Resource)]);
end;

procedure TReferenceScan.Resources(CID,Kind:Integer; Q:TSQLiteQuery; const Book:TBookRecord;
  const Source,SourceKey:string; OwnerFileID:Int64);
const Magic:array[0..5] of Byte=($37,$7A,$BC,$AF,$27,$1C);
var Header:array[0..5] of Byte;
begin
  var CacheKey:=IntToStr(CID)+#0+Source;
  if FResources.ContainsKey(CacheKey) then Exit;
  if FResources.Count>=4096 then FResources.Clear;
  FResources.Add(CacheKey,0);
  // Read the actual signature, including 7z bytes stored with a ZIP suffix.
  // The extension-only native decoder hint is insufficient for dependencies.
  if not (IsArchiveExt(Source) or SameText(ExtractFileExt(Source),'.bin')) then Exit;
  var Stream:=TFileStream.Create(DeletionNativePath(Source),fmOpenRead or fmShareDenyNone);
  try
    if (Stream.Read(Header,SizeOf(Header))<>SizeOf(Header)) or not CompareMem(@Header,@Magic,SizeOf(Magic)) then Exit;
  finally Stream.Free; end;
  var Value:=TJSONObject.ParseJSONValue(TransferImageSourcesSnapshot(Source));
  try
    if not (Value is TJSONArray) then raise EReadError.Create('Неверный список внешних картинок.');
    for var Item in TJSONArray(Value) do
      if Item.Value<>'' then
      begin
        var Info:=Probe(Item.Value);
        if Info.Error<>'' then Issue(CID,Item.Value,Info.Error);
        if (OwnerFileID<>0) and (FReview.QuerySingleInt('SELECT count(*) FROM Edges WHERE OwnerID=? AND FileID=?',
          [OwnerFileID,Info.FileID])<>0) then Continue;
        if Info.FileID<>0 then AddReference(CID,Kind,Q,Book,Item.Value,Info,Info.FileID,SourceKey,
          'Внешние картинки нужны архиву вне его проверенной группы переноса.',Source,True);
        if OwnerFileID<>0 then
          AddReference(CID,Kind,Q,Book,Source,Probe(Source),OwnerFileID,SourceKey,
            'Другое подключение использует отдельный набор внешних картинок.',Source,False);
      end;
  finally Value.Free; end;
end;

procedure TReferenceScan.Scan(DB:TSQLiteDatabase; const SQL:string; const Registration:TCollectionInfo;
  const CatalogueKey:string; Kind:Integer; Shared:Boolean);
var Q:TSQLiteQuery; Book:TBookRecord; Source,SourceKey,Reason,Variant:string; PathInfo:TPathInfo; FileID:Int64;
begin
  Q:=DB.NewQuery(SQL);
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop; Inc(FExamined);
{$IFDEF MHL_TRANSFER_TEST}
      if Assigned(TransferReferenceTestPoint) then TransferReferenceTestPoint('reference-row');
{$ENDIF}
      if Assigned(FProgress) and (FExamined mod 4096=0) then FProgress(FExamined);
      Book:=Default(TBookRecord); Book.CollectionRoot:=Registration.GetRootPath;
      Book.LibID:=Q.FieldAsString(1); Book.Folder:=Q.FieldAsString(2); Book.FileName:=Q.FieldAsString(3);
      Book.FileExt:=Q.FieldAsString(4); Book.InsideNo:=Q.FieldAsInt(5); SourceKey:='';
      if Kind=2 then
      begin
        if Q.FieldAsString(7)<>'' then Book.CollectionRoot:=IncludeTrailingPathDelimiter(Settings.ExpandCollectionRoot(Q.FieldAsString(7)));
        SourceKey:=Q.FieldAsString(8);
      end;
      Source:=''; PathInfo:=Default(TPathInfo); FileID:=0;
      if Book.FileName<>'' then
      try
        Source:=Resolve(Book); PathInfo:=Probe(Source);
        if PathInfo.Error<>'' then Issue(Registration.ID,Source,PathInfo.Error);
        FileID:=PathInfo.FileID;
        if FileID<>0 then
        begin
          Reason:=AliasReason(Source,PathInfo);
          AddReference(Registration.ID,Kind,Q,Book,Source,PathInfo,FileID,SourceKey,Reason,'',False);
        end;
        if PathInfo.FileKey<>'' then Resources(Registration.ID,Kind,Q,Book,Source,SourceKey,FileID);
      except
        on E:EAbort do raise;
        on E:Exception do
        begin
          if (E is EOutOfMemory) or (E is EExternalException) then raise;
          Issue(Registration.ID,Source,E.Message);
        end;
      end;
      if Shared and (Kind<>1) then
      begin
        Variant:=PathInfo.FileKey;
        if Variant='' then Variant:='unresolved:'+Source;
        FReview.ExecSQL('INSERT INTO ReferenceVariants VALUES(?,?,?,?,?,?,?)',
          [CatalogueKey,Kind,Q.FieldAsInt(0),SourceKey,Registration.ID,Variant,FileID]);
      end;
      Q.Next;
    end;
  finally Q.Free; end;
end;

procedure TReferenceScan.ReadRegistrations;
begin
  var Q:=FPersonal.NewQuery('SELECT DatabaseID,BaseName,DBFileName,RootFolder,Code FROM Bases ORDER BY DatabaseID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop; var CID:=Q.FieldAsInt(0); var Path:=''; var Root:=''; var Key:=''; var State:='ready'; var Reason:='';
      try
        Path:=Settings.ExpandCollectionFileName(Q.FieldAsString(2)); Root:=Settings.ExpandCollectionRoot(Q.FieldAsString(3));
        if isOnlineCollection(Q.FieldAsInt(4)) then begin State:='unknown'; Reason:='Сетевой каталог не проверен как локальный.'; end
        else
        begin
          var Info:=Probe(Path); Key:=Info.FileKey;
          if Key='' then begin State:='unknown'; Reason:='Файл зарегистрированного каталога недоступен. '+Info.Error; end;
        end;
      except
        on E:EAbort do raise;
        on E:Exception do
        begin
          if (E is EOutOfMemory) or (E is EExternalException) then raise;
          State:='unknown'; Reason:=E.Message;
        end;
      end;
      FReview.ExecSQL('INSERT INTO ReferenceRegistrations VALUES(?,?,?,?,?,?,?,?,?,?,?)',
        [CID,Q.FieldAsString(1),Q.FieldAsString(2),Q.FieldAsString(3),Q.FieldAsInt(4),Path,Root,Key,State,Reason,'']);
      if State<>'ready' then Issue(CID,Path,Reason);
      Q.Next;
    end;
  finally Q.Free; end;
end;

constructor TReferenceScan.Create(Review:TSQLiteDatabase; const PersonalFile:string;
  const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>);
begin
  inherited Create; FReview:=Review; FCancelled:=Cancelled; FProgress:=Progress;
  if (FReview=nil) or not FReview.InTransaction or
    (FReview.QuerySingleString('SELECT Value FROM Context WHERE Name=''kind''')<>'HomeLibre collection transfer preparation v1') or
    (CompressionFileKey(PersonalFile)<>FReview.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal_key''')) then
    raise EArgumentException.Create('Нужен собственный незавершённый план переноса.');
  FPersonal:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(PersonalFile));
  FPaths:=TDictionary<string,TPathInfo>.Create; FContainers:=TDictionary<string,string>.Create;
  FRootCanonical:=TDictionary<string,string>.Create; FResources:=TDictionary<string,Byte>.Create;
  FConnections:=TObjectList<TSQLiteDatabase>.Create; FLeases:=TList<IInterface>.Create;
  FVersions:=TList<Int64>.Create; FRoots:=TList<string>.Create;
end;

destructor TReferenceScan.Destroy;
begin
  FRoots.Free; FVersions.Free; FConnections.Free; FLeases.Free; FResources.Free; FRootCanonical.Free;
  FContainers.Free; FPaths.Free; FPersonal.Free; inherited;
end;

procedure TReferenceScan.Run;
const Columns='BookID,LibID,Folder,FileName,Ext,InsideNo,BookSize';
var Q:TSQLiteQuery; Info:TCollectionInfo; DB:TSQLiteDatabase; Key,SourceJSON:string;
  Version:Int64;
begin
  FReview.ExecSQL('CREATE TABLE ReferenceTargets(FileKey TEXT PRIMARY KEY,FileID INTEGER NOT NULL) WITHOUT ROWID');
  FReview.ExecSQL('INSERT INTO ReferenceTargets SELECT substr(Identity,1,25),ID FROM Files');
  FReview.ExecSQL('CREATE TABLE ReferenceRegistrations(RegistrationID INTEGER PRIMARY KEY,Name TEXT,RawCatalogue TEXT,RawRoot TEXT,'+
    'Code INTEGER,Catalogue TEXT,Root TEXT,CatalogueKey TEXT,State TEXT,Reason TEXT,SourcesJSON TEXT)');
  FReview.ExecSQL('CREATE INDEX ReferenceRegistrations_Key ON ReferenceRegistrations(CatalogueKey)');
  FReview.ExecSQL('CREATE TABLE RegisteredReferences(ID INTEGER PRIMARY KEY,RegistrationID INTEGER,Kind INTEGER,BookID INTEGER,'+
    'SourceKey TEXT,LibID TEXT,Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,CopyRoot TEXT,Source TEXT,Canonical TEXT,'+
    'FileKey TEXT,FileID INTEGER,RetainReason TEXT,Owner TEXT,Resource INTEGER)');
  FReview.ExecSQL('CREATE INDEX RegisteredReferences_File ON RegisteredReferences(FileID)');
  FReview.ExecSQL('CREATE TABLE ReferenceVariants(CatalogueKey TEXT,Kind INTEGER,BookID INTEGER,SourceKey TEXT,RegistrationID INTEGER,'+
    'PhysicalKey TEXT,FileID INTEGER)');
  FReview.ExecSQL('CREATE INDEX ReferenceVariants_Row ON ReferenceVariants(CatalogueKey,Kind,BookID,SourceKey)');
  FReview.ExecSQL('CREATE TABLE ReferenceIssues(RegistrationID INTEGER,Path TEXT,Reason TEXT,PRIMARY KEY(RegistrationID,Path,Reason)) WITHOUT ROWID');
  var PersonalVersion:=FPersonal.QuerySingleInt('PRAGMA data_version'); FPersonal.ExecSQL('BEGIN');
  ReadRegistrations;
  Q:=FReview.NewQuery('SELECT RegistrationID,Root FROM ReferenceRegistrations ORDER BY RegistrationID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      Info.Clear; Info.ID:=Q.FieldAsInt(0); Info.RootFolder:=Q.FieldAsString(1); SetRoots(Info.RootFolder,'');
      Scan(FPersonal,'SELECT '+Columns+','''' AS Root,'''' AS SourceKey FROM Books WHERE DatabaseID='+IntToStr(Info.ID),Info,'',1,False);
      Q.Next;
    end;
  finally Q.Free; end;
  FPersonal.ExecSQL('COMMIT');
  Q:=FReview.NewQuery('SELECT RegistrationID,Catalogue,Root,CatalogueKey FROM ReferenceRegistrations WHERE State=''ready'' ORDER BY RegistrationID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop; Info.Clear; Info.ID:=Q.FieldAsInt(0); Info.DBFileName:=Q.FieldAsString(1); Info.RootFolder:=Q.FieldAsString(2);
      Key:=Q.FieldAsString(3); DB:=nil;
      try
        FLeases.Add(AcquireCompressionDatabaseLease(Info.DBFileName,Key));
        DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Info.DBFileName));
        try Version:=DB.QuerySingleInt('PRAGMA data_version');
        except FreeAndNil(DB); raise; end;
        FConnections.Add(DB); FVersions.Add(Version);
        if CompressionFileKey(Info.DBFileName)<>Key then raise EReadError.Create('Файл каталога заменён во время проверки.');
        DB.ExecSQL('BEGIN'); SourceJSON:='';
        if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''Settings''')<>0 then
          SourceJSON:=DB.QuerySingleString('SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_CATALOG_SOURCES]);
        SetRoots(Info.RootFolder,SourceJSON);
        FReview.ExecSQL('UPDATE ReferenceRegistrations SET SourcesJSON=? WHERE RegistrationID=?',[SourceJSON,Info.ID]);
        var Shared:=FReview.QuerySingleInt('SELECT count(*) FROM ReferenceRegistrations WHERE CatalogueKey=?',[Key])>1;
        Scan(DB,'SELECT '+Columns+','''' AS Root,'''' AS SourceKey FROM Books',Info,Key,0,Shared);
        if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')<>0 then
          Scan(DB,'SELECT '+Columns+',Root,SourceKey FROM CatalogBookCopies',Info,Key,2,Shared);
        DB.ExecSQL('COMMIT');
      except
        on E:EAbort do raise;
        on E:Exception do
        begin
          if (E is EOutOfMemory) or (E is EExternalException) then raise;
          if (DB<>nil) and DB.InTransaction then DB.Rollback;
          Issue(Info.ID,Info.DBFileName,E.Message);
          FReview.ExecSQL('UPDATE ReferenceRegistrations SET State=''unknown'',Reason=? WHERE RegistrationID=?',[E.Message,Info.ID]);
        end;
      end;
      Q.Next;
    end;
  finally Q.Free; end;
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferReferenceTestPoint) then TransferReferenceTestPoint('references-read');
{$ENDIF}
  if FPersonal.QuerySingleInt('PRAGMA data_version')<>PersonalVersion then
    raise EReadError.Create('Личные данные или подключения изменились во время проверки ссылок.');
  for var I:=0 to FConnections.Count-1 do
    if FConnections[I].QuerySingleInt('PRAGMA data_version')<>FVersions[I] then
      raise EReadError.Create('Другой каталог изменился во время проверки ссылок.');
  FReview.ExecSQL('CREATE TABLE ReferenceConflicts AS SELECT CatalogueKey,Kind,BookID,SourceKey '+
    'FROM ReferenceVariants GROUP BY CatalogueKey,Kind,BookID,SourceKey HAVING count(DISTINCT PhysicalKey)>1 AND max(FileID)>0');
  FReview.ExecSQL('CREATE UNIQUE INDEX ReferenceConflicts_Row ON ReferenceConflicts(CatalogueKey,Kind,BookID,SourceKey)');
  FReview.ExecSQL('INSERT INTO Context VALUES(''reference_rows'',?)',[IntToStr(FExamined)]);
  if Assigned(FProgress) then FProgress(FExamined);
end;

procedure CaptureTransferReferences(Review:TSQLiteDatabase; const PersonalFile:string;
  const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>);
begin
  var Scan:=TReferenceScan.Create(Review,PersonalFile,Cancelled,Progress);
  try Scan.Run; finally Scan.Free; end;
end;

function TransferReferenceConflictCount(Review:TSQLiteDatabase):Int64;
begin Result:=Review.QuerySingleInt('SELECT count(*) FROM ReferenceConflicts'); end;

function TransferReferenceRequiresRetention(Review:TSQLiteDatabase; FileID:Int64):Boolean;
begin
  Result:=(Review.QuerySingleInt('SELECT count(*) FROM ReferenceIssues')<>0) or
    (Review.QuerySingleInt('SELECT count(*) FROM RegisteredReferences WHERE FileID=? AND RetainReason<>''''',[FileID])<>0) or
    (Review.QuerySingleInt('SELECT count(*) FROM ReferenceVariants v JOIN ReferenceConflicts c '+
      'ON c.CatalogueKey=v.CatalogueKey AND c.Kind=v.Kind AND c.BookID=v.BookID AND c.SourceKey=v.SourceKey WHERE v.FileID=?',[FileID])<>0);
end;

end.
