unit unit_CollectionTransferForks;

interface

uses System.SysUtils, Winapi.Windows, SQLiteWrap, unit_CollectionTransferPlan;

type TTransferForkOwnership=reference to procedure(const Path:string; Handle:THandle; Directory,Created:Boolean);

// Called only while constructing the owning, unsealed review. Snapshots are
// private metadata, not registered catalogues. Nothing is removed or rebound.
procedure CaptureTransferCatalogueForks(Review:TSQLiteDatabase; const Cancelled:TFunc<Boolean>;
  MetadataOnly:Boolean=False; const Ownership:TTransferForkOwnership=nil);
function TransferForkRootToken(const Root:string):string;
function TransferForkEntry(Review:TSQLiteDatabase; ForkID:Int64):TCollectionTransferFile;
function AcquireTransferForkSource(Review:TSQLiteDatabase; SourceID:Int64;
  const Cancelled:TFunc<Boolean>):IInterface;

{$IFDEF MHL_TRANSFER_TEST}
var TransferForkDraftTestPoint:TProc<string,string,Integer,Integer>;
{$ENDIF}

implementation

uses System.Classes, System.IOUtils, System.Hash, System.JSON, System.Generics.Collections,
  unit_ZipMemberDeletion, unit_BookCompressionReceipt, unit_CollectionTransferLayout;

type
  TPinnedCatalogue = class(TInterfacedObject)
  private
    FStreams:TObjectList<TFileStream>;
    FDirectories:TList<THandle>;
    FCancelled:TFunc<Boolean>;
    FPath,FWitness:string;
    procedure CheckStop;
    procedure PinParents(const Path:string);
    procedure AddWitness(Data:TJSONArray; const Path:string; Optional:Boolean);
  public
    constructor Create(const Path,ExpectedKey:string; const Cancelled:TFunc<Boolean>);
    destructor Destroy; override;
    property Path:string read FPath;
    property Witness:string read FWitness;
  end;

procedure TPinnedCatalogue.CheckStop;
begin
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Подготовка копии общего каталога остановлена. Подключения не изменены.');
end;

procedure TPinnedCatalogue.PinParents(const Path:string);
var Info:TByHandleFileInformation;
begin
  var Parent:=ExtractFileDir(Path);
  repeat
    var Handle:=CreateFile(PChar(DeletionNativePath(Parent)),FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
    if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
    try
      if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
      if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0) or
        (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
        raise EReadError.Create('Папка общего каталога перенаправлена.');
      FDirectories.Add(Handle);
    except CloseHandle(Handle); raise; end;
    if SameFileName(IncludeTrailingPathDelimiter(Parent),TPath.GetPathRoot(Path)) then Break;
    var Next:=ExtractFileDir(ExcludeTrailingPathDelimiter(Parent));
    if (Next='') or SameFileName(Next,Parent) then Break;
    Parent:=Next;
  until False;
end;

procedure TPinnedCatalogue.AddWitness(Data:TJSONArray; const Path:string; Optional:Boolean);
var Canonical,Identity:string; Bytes:Int64; Hash:THashSHA2; Buffer:TBytes; N:Integer;
begin
  CheckStop;
  if GetFileAttributes(PChar(DeletionNativePath(Path)))=INVALID_FILE_ATTRIBUTES then
  begin
    var Code:=GetLastError;
    if Optional and (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then Exit;
    RaiseLastOSError(Code);
  end;
  var Sharing:=fmShareDenyWrite;
  if Optional then Sharing:=fmShareDenyNone; // Read-only SQLite may open its WAL with read/write access.
  var Stream:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or Sharing);
  FStreams.Add(Stream);
  TransferReadFileState(Path,Canonical,Identity,Bytes);
  if not SameFileName(Canonical,Path) then raise EReadError.Create('Файл общего каталога перенаправлен.');
  // SQLite may create an empty WAL for a read-only connection. Its presence
  // carries no committed pages; absent and zero-byte WALs are equivalent.
  if Optional and (Bytes=0) then Exit;
  Hash:=THashSHA2.Create; SetLength(Buffer,1024*1024);
  repeat
    CheckStop; N:=Stream.Read(Buffer[0],Length(Buffer)); if N>0 then Hash.Update(Buffer,N);
  until N=0;
  var Item:=TJSONObject.Create; Data.AddElement(Item);
  Item.AddPair('path',Canonical); Item.AddPair('identity',Identity); Item.AddPair('sha256',Hash.HashAsString);
end;

constructor TPinnedCatalogue.Create(const Path,ExpectedKey:string; const Cancelled:TFunc<Boolean>);
begin
  inherited Create; FCancelled:=Cancelled; FStreams:=TObjectList<TFileStream>.Create; FDirectories:=TList<THandle>.Create;
  // Deny ordinary SQLite writers, replacement and rename through publication.
  // The normal UI must release affected writable catalogue connections first.
  var Main:TFileStream;
  try Main:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
  except on E:EFOpenError do raise EReadError.Create('Не удалось защитить общий каталог от изменений. '+
    'Завершите работу с его другими подключениями и повторите. '+E.Message); end;
  FStreams.Add(Main);
  FPath:=TransferFinalHandlePath(Main.Handle); PinParents(FPath);
  if (CompressionFileKey(FPath)<>ExpectedKey) or (CompressionFileKey(Path)<>ExpectedKey) or
    not SameFileName(TransferFinalHandlePath(Main.Handle),FPath) then
    raise EReadError.Create('Общий каталог заменён после проверки.');
  var Data:=TJSONArray.Create;
  try AddWitness(Data,FPath,False); AddWitness(Data,FPath+'-wal',True); FWitness:=Data.ToJSON;
  finally Data.Free; end;
end;

destructor TPinnedCatalogue.Destroy;
begin
  FStreams.Free;
  if FDirectories<>nil then begin for var Handle in FDirectories do CloseHandle(Handle); FDirectories.Free; end;
  inherited;
end;

function TransferForkRootToken(const Root:string):string;
var Info:TByHandleFileInformation;
begin
  var Handle:=CreateFile(PChar(DeletionNativePath(Root)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,0);
  if Handle=INVALID_HANDLE_VALUE then
  begin
    var Code:=GetLastError;
    if Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND] then
      Exit('missing:'+IncludeTrailingPathDelimiter(ExpandFileName(Root)));
    RaiseLastOSError(Code);
  end;
  try
    if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
    if Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0 then raise EReadError.Create('Корень коллекции больше не является папкой.');
    if (Info.nFileIndexHigh<>0) or (Info.nFileIndexLow<>0) then
      Result:='directory:'+IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8)
    else Result:='path:'+IncludeTrailingPathDelimiter(TransferFinalHandlePath(Handle));
  finally CloseHandle(Handle); end;
end;

procedure RequireSpace(const Directory:string; Remaining:Int64);
var Available,Capacity:UInt64;
begin
  if not GetDiskFreeSpaceEx(PChar(DeletionNativePath(Directory)),Available,Capacity,nil) then RaiseLastOSError;
  if (Remaining<0) or (UInt64(Remaining)>Available) or (Available-UInt64(Remaining)<UInt64(512)*1024*1024) then
    raise EWriteError.Create('Для копии общего каталога не хватает места с резервом 512 МБ.');
end;

function Snapshot(Review:TSQLiteDatabase; const Source,Key:string; const Cancelled:TFunc<Boolean>;
  MetadataOnly:Boolean; const Ownership:TTransferForkOwnership):Int64;
var Guard:TPinnedCatalogue; Lease:IInterface; DB:TSQLiteDatabase; SnapshotLease:IInterface;
  Canonical,Identity,SHA,Directory,FileName:string; Bytes,PageSize:Int64;
begin
  Guard:=TPinnedCatalogue.Create(Source,Key,Cancelled); Lease:=Guard;
  if MetadataOnly then
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Guard.Path),Review.TemporaryDirectory);
    try Bytes:=DB.QuerySingleInt('PRAGMA page_count')*DB.QuerySingleInt('PRAGMA page_size'); finally DB.Free; end;
    Result:=Review.QuerySingleInt('SELECT coalesce(max(ID),0)+1 FROM ForkSources');
    Review.ExecSQL('INSERT INTO ForkSources VALUES(?,?,?,?,?,?,?,?,?)',
      [Result,Source,Key,Guard.Witness,'','',Bytes,'',Guard.Path]);
    Exit;
  end;
  Directory:=TPath.Combine(Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''work_root'''),
    Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''directory'''));
  Directory:=TPath.Combine(Directory,'catalogue-snapshots');
  var CreatedDirectory:=GetFileAttributes(PChar(DeletionNativePath(Directory)))=INVALID_FILE_ATTRIBUTES;
  if CreatedDirectory then if not CreateDirectory(PChar(DeletionNativePath(Directory)),nil) then RaiseLastOSError;
  if not SameFileName(TransferCanonicalDirectory(Directory),IncludeTrailingPathDelimiter(Directory)) then
    raise EReadError.Create('Папка снимков каталога перенаправлена.');
  FileName:=TPath.Combine(Directory,GUIDToString(TGUID.NewGuid)+'.hlc2');
  var DirectoryHandle:=CreateFile(PChar(DeletionNativePath(Directory)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if DirectoryHandle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if Assigned(Ownership) then Ownership(Directory,DirectoryHandle,True,CreatedDirectory);
    Guard.PinParents(FileName);
  finally CloseHandle(DirectoryHandle); end;
  DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Guard.Path),Review.TemporaryDirectory);
  try
    PageSize:=DB.QuerySingleInt('PRAGMA page_size'); RequireSpace(Directory,DB.QuerySingleInt('PRAGMA page_count')*PageSize);
  finally DB.Free; end;
  var Handle:=CreateFile(PChar(DeletionNativePath(FileName)),GENERIC_WRITE,0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try if Assigned(Ownership) then Ownership(FileName,Handle,False,True); finally CloseHandle(Handle); end;
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferForkDraftTestPoint) then TransferForkDraftTestPoint('fork-draft-reserved',FileName,0,0);
{$ENDIF}
  SnapshotLease:=AcquireCompressionDatabaseLease(FileName,CompressionFileKey(FileName));
  DB:=TSQLiteDatabase.Create(DeletionNativePath(FileName),False,False,Review.TemporaryDirectory);
  try
    if Assigned(Ownership) then
    begin
      if DB.QuerySingleString('PRAGMA journal_mode=MEMORY')<>'memory' then
        raise EWriteError.Create('Не удалось подготовить одноразовый снимок каталога.');
    end
    else DB.QuerySingleString('PRAGMA journal_mode=DELETE');
    DB.ExecSQL('PRAGMA synchronous=FULL'); DB.ExecSQL('PRAGMA cache_size=-512');
    DB.RestoreFrom(DeletionNativePath(Guard.Path),
      procedure(Done,Total:Integer)
      begin
        if Assigned(Cancelled) and Cancelled() then raise EAbort.Create('Подготовка копии каталога остановлена.');
        RequireSpace(Directory,Int64(Total-Done)*PageSize);
{$IFDEF MHL_TRANSFER_TEST}
        if Assigned(TransferForkDraftTestPoint) then TransferForkDraftTestPoint('fork-draft-copying',FileName,Done,Total);
{$ENDIF}
      end);
    if DB.QuerySingleString('PRAGMA quick_check')<>'ok' then raise EReadError.Create('Копия общего каталога не прошла проверку.');
    if DB.QuerySingleString('PRAGMA journal_mode=DELETE')<>'delete' then
      raise EWriteError.Create('Не удалось сохранить снимок общего каталога.');
  finally DB.Free; end;
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferForkDraftTestPoint) then TransferForkDraftTestPoint('fork-draft-ready',FileName,0,0);
{$ENDIF}
  // Reopen under a read lease before freezing the full payload fingerprint.
  var Stream:=TFileStream.Create(DeletionNativePath(FileName),fmOpenRead or fmShareDenyWrite);
  try
    TransferReadFileState(FileName,Canonical,Identity,Bytes);
    var Hash:=THashSHA2.Create; var Buffer:TBytes; SetLength(Buffer,1024*1024); var N:Integer;
    repeat
      if Assigned(Cancelled) and Cancelled() then raise EAbort.Create('Подготовка копии каталога остановлена.');
      N:=Stream.Read(Buffer[0],Length(Buffer)); if N>0 then Hash.Update(Buffer,N);
    until N=0;
    SHA:=Hash.HashAsString;
    Result:=Review.QuerySingleInt('SELECT coalesce(max(ID),0)+1 FROM ForkSources');
    Review.ExecSQL('INSERT INTO ForkSources VALUES(?,?,?,?,?,?,?,?,?)',
      [Result,Source,Key,Guard.Witness,Canonical,Identity,Bytes,SHA,Guard.Path]);
  finally Stream.Free; end;
end;

procedure CaptureTransferCatalogueForks(Review:TSQLiteDatabase; const Cancelled:TFunc<Boolean>;
  MetadataOnly:Boolean; const Ownership:TTransferForkOwnership);
var Keys,Regs:TSQLiteQuery; Key,Keeper,Token,Role,Source,SelectedKey,OriginalRoot:string;
    SourceID,ForkID,MemberID:Int64; SelectedID:Integer; SelectedMoves:Boolean;
begin
  if not Review.InTransaction then raise EArgumentException.Create('Нужен незавершённый план переноса.');
  SelectedID:=StrToInt(Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''collection'''));
  SelectedKey:=Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''catalogue_key''');
  OriginalRoot:=Review.QuerySingleString('SELECT coalesce(CanonicalPath,InputPath) FROM Roots WHERE ID=''collection''');
  var Layout:=TCollectionTransferLayout.Create(Review);
  try SelectedMoves:=not SameFileName(IncludeTrailingPathDelimiter(Layout.RootDestination('collection')),
    IncludeTrailingPathDelimiter(OriginalRoot));
  finally Layout.Free; end;
  Review.ExecSQL('CREATE TABLE ForkSources(ID INTEGER PRIMARY KEY,Source TEXT,CatalogueKey TEXT UNIQUE,Witness TEXT,'+
    'Snapshot TEXT,Identity TEXT,Bytes INTEGER,SHA256 TEXT,CanonicalSource TEXT)');
  Review.ExecSQL('CREATE TABLE CatalogueForks(ID INTEGER PRIMARY KEY,SourceID INTEGER,RootToken TEXT,Destination TEXT UNIQUE,'+
    'UNIQUE(SourceID,RootToken))');
  Review.ExecSQL('CREATE TABLE ForkMembers(RegistrationID INTEGER PRIMARY KEY,ForkID INTEGER,RootToken TEXT)');
  Keys:=Review.NewQuery('SELECT DISTINCT CatalogueKey FROM ReferenceConflicts UNION '+
    'SELECT CatalogueKey FROM ReferenceRegistrations WHERE State=''ready'' AND CatalogueKey=? AND ?=1 '+
    'GROUP BY CatalogueKey HAVING count(*)>1 ORDER BY CatalogueKey',[SelectedKey,Ord(SelectedMoves)]);
  try
    Keys.Open;
    while not Keys.Eof do
    begin
      Key:=Keys.FieldAsString(0); SourceID:=0; Source:=''; Keeper:='';
      Regs:=Review.NewQuery('SELECT RegistrationID,Root,Catalogue FROM ReferenceRegistrations WHERE CatalogueKey=? AND State=''ready'' '+
        'ORDER BY CASE WHEN RegistrationID=? THEN 0 ELSE 1 END,RegistrationID',
        [Key,SelectedID]);
      try
        Regs.Open;
        while not Regs.Eof do
        begin
          if Assigned(Cancelled) and Cancelled() then raise EAbort.Create('Подготовка копий каталога остановлена.');
          MemberID:=Regs.FieldAsInt(0); Token:=TransferForkRootToken(Regs.FieldAsString(1));
          Role:=Token;
          // Equal old roots stop being equivalent if only the selected alias
          // gets a different final default root. Other aliases retain one fork.
          if SelectedMoves and (Key=SelectedKey) and (MemberID<>SelectedID) and (Token=Keeper) then
            Role:='retained:'+Token;
          if Keeper='' then begin Keeper:=Token; Source:=Regs.FieldAsString(2); end
          else if Role<>Keeper then
          begin
            if SourceID=0 then SourceID:=Snapshot(Review,Source,Key,Cancelled,MetadataOnly,Ownership);
            ForkID:=Review.QuerySingleInt('SELECT ID FROM CatalogueForks WHERE SourceID=? AND RootToken=?',[SourceID,Role]);
            if ForkID=0 then
            begin
              ForkID:=Review.QuerySingleInt('SELECT coalesce(max(ID),0)+1 FROM CatalogueForks');
              var Destination:=TPath.Combine(Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''content_root'''),
                'catalogues\'+IntToStr(ForkID)+'.hlc2');
              Review.ExecSQL('INSERT INTO CatalogueForks VALUES(?,?,?,?)',[ForkID,SourceID,Role,Destination]);
            end;
            Review.ExecSQL('INSERT INTO ForkMembers VALUES(?,?,?)',[MemberID,ForkID,Token]);
          end;
          Regs.Next;
        end;
      finally Regs.Free; end;
      Keys.Next;
    end;
  finally Keys.Free; end;
end;

function TransferForkEntry(Review:TSQLiteDatabase; ForkID:Int64):TCollectionTransferFile;
begin
  Result:=Default(TCollectionTransferFile);
  var Q:=Review.NewQuery('SELECT s.Snapshot,f.Destination,s.Identity,s.Bytes FROM CatalogueForks f JOIN ForkSources s ON s.ID=f.SourceID WHERE f.ID=?',[ForkID]);
  try
    Q.Open; if Q.Eof then raise EArgumentException.Create('Неизвестная копия общего каталога.');
    Result.Source:=Q.FieldAsString(0); Result.Destination:=Q.FieldAsString(1);
    Result.Identity:=Q.FieldAsString(2); Result.Bytes:=Q.FieldAsInt(3);
  finally Q.Free; end;
end;

function AcquireTransferForkSource(Review:TSQLiteDatabase; SourceID:Int64; const Cancelled:TFunc<Boolean>):IInterface;
begin
  var Q:=Review.NewQuery('SELECT Source,CatalogueKey,Witness FROM ForkSources WHERE ID=?',[SourceID]);
  try
    Q.Open; if Q.Eof then raise EReadError.Create('Нет снимка исходного общего каталога.');
    var Guard:=TPinnedCatalogue.Create(Q.FieldAsString(0),Q.FieldAsString(1),Cancelled); Result:=Guard;
    if Guard.Witness<>Q.FieldAsString(2) then raise EReadError.Create('Общий каталог изменился после подготовки копии. Нужен новый план.');
  finally Q.Free; end;
end;

end.
