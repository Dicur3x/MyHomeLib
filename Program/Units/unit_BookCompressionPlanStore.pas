unit unit_BookCompressionPlanStore;

interface

uses System.SysUtils, Winapi.Windows, SQLiteWrap;

type
  // Scratch metadata only. A published per-file compression job contains its
  // own immutable receipt and never depends on this temporary planning store.
  TCompressionPlanStore = class
  private
    FFolder, FMarker: string;
    FGuard: THandle;
    FDB: TSQLiteDatabase;
    FSealed: Boolean;
  public
    constructor Create(const Root: string);
    destructor Destroy; override;
    procedure Seal;
    procedure Edit(const Change: TProc<TSQLiteDatabase>);
    property DB: TSQLiteDatabase read FDB;
    property Folder: string read FFolder;
    property Sealed: Boolean read FSealed;
    class function CleanAbandoned(const Root: string): Integer; static;
  end;

implementation

uses System.Classes, System.IOUtils, System.StrUtils, unit_ZipMemberDeletion;

const Marker='HomeLibre collection compression plan v1';

function GuardFolder(const Folder:string; ForCleanup:Boolean):THandle;
var Path:TArray<Char>; Count:DWORD; Actual:string; Access:DWORD;
begin
  Result:=0; Access:=FILE_READ_ATTRIBUTES;
  // A live plan's directory lease does not share DELETE access. Acquiring it
  // here proves that no other instance is still using this planning folder.
  if ForCleanup then Access:=Access or Winapi.Windows._DELETE;
  var Handle:=CreateFile(PChar(DeletionNativePath(Folder)),Access,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Handle=INVALID_HANDLE_VALUE then Exit;
  try
    SetLength(Path,32768);
    Count:=GetFinalPathNameByHandle(Handle,@Path[0],Length(Path),0);
    if (Count=0) or (Count>=DWORD(Length(Path))) then Exit;
    SetString(Actual,PChar(@Path[0]),Count);
    var Info:TByHandleFileInformation;
    if not GetFileInformationByHandle(Handle,Info) or
      (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
      not SameFileName(Actual,DeletionNativePath(Folder)) then Exit;
    Result:=Handle; Handle:=INVALID_HANDLE_VALUE;
  finally if Handle<>INVALID_HANDLE_VALUE then CloseHandle(Handle); end;
end;

function RemovePlanFolder(const Folder:string):Boolean;
var Guard:THandle; Name:string; Attr:DWORD;
begin
  Result:=False;
  var Leaf:=ExtractFileName(Folder);
  if not Leaf.StartsWith('collection-plan-') then Exit;
  var ID:TGUID;
  try ID:=StringToGUID(Copy(Leaf,Length('collection-plan-')+1,MaxInt));
  except on E:EConvertError do Exit; end;
  if Leaf<>'collection-plan-'+GUIDToString(ID) then Exit;
  Guard:=GuardFolder(Folder,True); if Guard=0 then Exit;
  try
    try
      var Owner:=TPath.Combine(Folder,'owner.txt');
      Attr:=GetFileAttributes(PChar(DeletionNativePath(Owner)));
      if (Attr=INVALID_FILE_ATTRIBUTES) or
        (Attr and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY)<>0) or
        (TFile.GetSize(DeletionNativePath(Owner))>1024) or
        (TFile.ReadAllText(DeletionNativePath(Owner),TEncoding.UTF8)<>Marker+sLineBreak+Leaf) then Exit;
      // Never recursively delete. A foreign file or link keeps this folder
      // intact for inspection instead of being mistaken for temporary data.
      for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(Folder)) do
      begin
        Name:=ExtractFileName(Path); Attr:=GetFileAttributes(PChar(Path));
        if not MatchText(Name,['owner.txt','plan.sqlite','plan.sqlite-journal','plan.sqlite-wal','plan.sqlite-shm']) or
          (Attr=INVALID_FILE_ATTRIBUTES) or
          (Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) then Exit;
      end;
      for Name in ['plan.sqlite-journal','plan.sqlite-wal','plan.sqlite-shm','plan.sqlite','owner.txt'] do
      begin
        var Path:=DeletionNativePath(TPath.Combine(Folder,Name));
        if FileExists(Path) and not Winapi.Windows.DeleteFile(PChar(Path)) then Exit;
      end;
      // RemoveDirectory requires releasing our own DELETE lease first. The
      // directory must still be empty; any new unrelated file prevents it.
      CloseHandle(Guard); Guard:=0;
      Result:=RemoveDirectory(PChar(DeletionNativePath(Folder)));
    except Result:=False; end;
  finally if Guard<>0 then CloseHandle(Guard); end;
end;

class function TCompressionPlanStore.CleanAbandoned(const Root:string):Integer;
var Search:TSearchRec; Base,Path:string;
begin
  Result:=0; if (Root='') or not TPath.IsPathRooted(Root) then Exit;
  Base:=ExcludeTrailingPathDelimiter(ExpandFileName(Root));
  if FindFirst(DeletionNativePath(TPath.Combine(Base,'collection-plan-*')),faDirectory,Search)<>0 then Exit;
  try
    repeat
      if (Search.Attr and faDirectory<>0) and not ((Search.Name='.') or (Search.Name='..')) then
      begin
        Path:=TPath.Combine(Base,Search.Name);
        if SameFileName(ExtractFileDir(Path),Base) and RemovePlanFolder(Path) then Inc(Result);
      end;
    until FindNext(Search)<>0;
  finally System.SysUtils.FindClose(Search); end;
end;

constructor TCompressionPlanStore.Create(const Root:string);
begin
  inherited Create;
  if (Root='') or not TPath.IsPathRooted(Root) then
    raise EArgumentException.Create('Нужна папка временного плана сжатия.');
  var Base:=ExcludeTrailingPathDelimiter(ExpandFileName(Root));
  ForceDirectories(DeletionNativePath(Base));
  CleanAbandoned(Base);
  FFolder:=TPath.Combine(Base,'collection-plan-'+TGUID.NewGuid.ToString);
  if not CreateDirectory(PChar(DeletionNativePath(FFolder)),nil) then RaiseLastOSError;
  FGuard:=GuardFolder(FFolder,False);
  if FGuard=0 then raise EReadError.Create('Рабочая папка плана проходит через ссылку или недоступна.');
  FMarker:=TPath.Combine(FFolder,'owner.txt');
  TFile.WriteAllText(DeletionNativePath(FMarker),Marker+sLineBreak+ExtractFileName(FFolder),TEncoding.UTF8);
  var FileName:=TPath.Combine(FFolder,'plan.sqlite');
  var Stream:=TFileStream.Create(DeletionNativePath(FileName),fmCreate or fmShareExclusive);
  Stream.Free;
  // SQLite must receive the extended path too, including on reopen: its
  // journal files cannot rely on the host executable being long-path aware.
  FDB:=TSQLiteDatabase.Create(DeletionNativePath(FileName));
  FDB.QuerySingleString('PRAGMA journal_mode=DELETE');
  FDB.ExecSQL('PRAGMA synchronous=NORMAL');
  FDB.ExecSQL('PRAGMA temp_store=FILE');
  FDB.ExecSQL('PRAGMA cache_size=-4096');
  FDB.ExecSQL('CREATE TABLE Candidates(ID INTEGER PRIMARY KEY,PathKey TEXT NOT NULL UNIQUE,'+
    'Source TEXT NOT NULL,Active INTEGER NOT NULL)');
  FDB.ExecSQL('CREATE INDEX Candidates_Active ON Candidates(Active DESC,ID)');
  FDB.ExecSQL('CREATE TABLE Sources(ID INTEGER PRIMARY KEY,Source TEXT NOT NULL,FileKey TEXT NOT NULL UNIQUE,'+
    'Identity TEXT NOT NULL)');
  FDB.ExecSQL('CREATE TABLE Locators(CandidateID INTEGER NOT NULL,Kind INTEGER NOT NULL,BookID INTEGER NOT NULL,'+
    'LibID TEXT NOT NULL,Folder TEXT NOT NULL,FileName TEXT NOT NULL,Ext TEXT NOT NULL,InsideNo INTEGER NOT NULL,'+
    'BookSize INTEGER NOT NULL,Root TEXT NOT NULL,SourceKey TEXT NOT NULL,FileID INTEGER,Member TEXT)');
  FDB.ExecSQL('CREATE INDEX Locators_Candidate ON Locators(CandidateID)');
  FDB.ExecSQL('CREATE INDEX Locators_File ON Locators(FileID)');
  FDB.ExecSQL('CREATE TABLE Members(FileID INTEGER NOT NULL,Member TEXT NOT NULL,Ext TEXT NOT NULL,'+
    'PRIMARY KEY(FileID,Member)) WITHOUT ROWID');
end;

procedure TCompressionPlanStore.Seal;
begin
  if FSealed then Exit;
  FreeAndNil(FDB);
  FDB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(TPath.Combine(FFolder,'plan.sqlite')));
  FSealed:=True;
end;

procedure TCompressionPlanStore.Edit(const Change: TProc<TSQLiteDatabase>);
begin
  if not FSealed or not Assigned(Change) then
    raise EInvalidOperation.Create('План сжатия ещё не готов к отбору новых книг.');
  FreeAndNil(FDB); FSealed:=False;
  try
    FDB:=TSQLiteDatabase.Create(DeletionNativePath(TPath.Combine(FFolder,'plan.sqlite')));
    FDB.QuerySingleString('PRAGMA journal_mode=DELETE');
    FDB.ExecSQL('PRAGMA cache_size=-4096');
    FDB.ExecSQL('PRAGMA temp_store=FILE');
    FDB.ExecSQL('BEGIN');
    try Change(FDB); FDB.Commit;
    except FDB.Rollback; raise; end;
  finally Seal; end;
end;

destructor TCompressionPlanStore.Destroy;
begin
  FDB.Free;
  if FGuard<>0 then CloseHandle(FGuard);
  if FFolder<>'' then RemovePlanFolder(FFolder);
  inherited;
end;

end.
