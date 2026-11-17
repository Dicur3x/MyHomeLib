unit unit_CollectionTransferCleanup;

interface

uses System.SysUtils, System.Classes, unit_CollectionTransferJournal, unit_CollectionTransferRegistry;

type
  TTransferCleanupWorker=class(TThread)
  private
    FPersonal:string;
    FDone:Integer;
    FOutcome:TTransferCleanupResult;
  protected
    procedure Execute; override;
  public
    constructor Create(const PersonalFile:string);
    destructor Destroy; override;
    function Done:Boolean;
    property Outcome:TTransferCleanupResult read FOutcome;
  end;

function CleanupCompletedTransferCaches(Journal:TCollectionTransferJournal;
  const Cancelled:TFunc<Boolean>=nil):TTransferCleanupResult;
function CompletedTransferCleanupQueue(const PersonalFile:string):TArray<TRegisteredCollectionTransfer>;
function CleanupRegisteredCompletedTransfers(const PersonalFile:string;
  const Cancelled:TFunc<Boolean>=nil):TTransferCleanupResult;

{$IFDEF MHL_TRANSFER_TEST}
var TransferCleanupTestPoint:TProc<string,string>;
{$ENDIF}

implementation

uses System.IOUtils, System.JSON, System.Hash, System.DateUtils, System.SyncObjs,
  System.Generics.Collections, Winapi.Windows, SQLiteWrap, unit_CollectionTransferCompletion,
  unit_CollectionTransferPlan, unit_BookCompressionReceipt, unit_ZipMemberDeletion;

const Claims='HomeLibreTransferCacheClaims'; Intent='HomeLibreTransferCacheIntent';
  Cleanup='HomeLibreTransferCacheCleanup'; Operations='HomeLibreTransferOperations';
  ForkReceipts='HomeLibreTransferForkReceipts'; ForkCleanup='HomeLibreTransferForkCleanup';

constructor TTransferCleanupWorker.Create(const PersonalFile:string);
begin inherited Create(True); FreeOnTerminate:=False; FPersonal:=PersonalFile; Priority:=tpLowest; end;

destructor TTransferCleanupWorker.Destroy;
begin Terminate; inherited; end;

function TTransferCleanupWorker.Done:Boolean;
begin Result:=TInterlocked.CompareExchange(FDone,0,0)<>0; end;

procedure TTransferCleanupWorker.Execute;
begin
  try
    try FOutcome:=CleanupRegisteredCompletedTransfers(FPersonal,function:Boolean begin Result:=Terminated; end);
    except on E:Exception do FOutcome.Warning:=E.Message; end;
  finally TInterlocked.Exchange(FDone,1); end;
end;

type
  TWorkDirectory=class
    Job,Path,Key:string;
    Files:TDictionary<string,string>;
    Hashes:TDictionary<string,string>;
    Sizes:TDictionary<string,Int64>;
    Fork:Boolean;
    constructor Create;
    destructor Destroy; override;
  end;
  THeldWorkFile=record Handle:THandle; Path:string; Bytes:Int64; end;

constructor TWorkDirectory.Create;
begin
  inherited; Files:=TDictionary<string,string>.Create;
  Hashes:=TDictionary<string,string>.Create; Sizes:=TDictionary<string,Int64>.Create;
end;
destructor TWorkDirectory.Destroy;
begin Sizes.Free; Hashes.Free; Files.Free; inherited; end;

function WorkSetInformation(Handle:THandle; InfoClass:Integer; Data:Pointer; Bytes:DWORD):BOOL;
  stdcall; external kernel32 name 'SetFileInformationByHandle';
function WorkGetInformation(Handle:THandle; InfoClass:Integer; Data:Pointer; Bytes:DWORD):BOOL;
  stdcall; external kernel32 name 'GetFileInformationByHandleEx';

procedure Point(const Stage,Path:string);
begin
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferCleanupTestPoint) then TransferCleanupTestPoint(Stage,Path);
{$ENDIF}
end;

function HasTable(DB:TSQLiteDatabase; const Name:string):Boolean;
begin Result:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[Name])=1; end;
function Meta(Journal:TCollectionTransferJournal; const Name:string):string;
begin Result:=Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=?',[Name]); end;

function ObjectKey(Handle:THandle; Directory:Boolean; out Bytes:Int64):string;
begin
  var Info:TByHandleFileInformation;
  if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
  if ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY<>0)<>Directory) or
    (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
    (not Directory and ((Info.nNumberOfLinks<>1) or (Info.dwFileAttributes and FILE_ATTRIBUTE_READONLY<>0))) or
    ((Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0)) then raise EReadError.Create('Рабочий объект изменён, занят или является ссылкой.');
  Bytes:=(Int64(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow;
  if Bytes<0 then raise EReadError.Create('Неверный размер рабочего файла.');
  Result:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
end;

procedure RequireDefaultStream(Handle:THandle; Directory:Boolean);
begin
  // FILE_STREAM_INFO is 8-byte aligned. Query through the held file handle:
  // opening another path would either race or violate our exclusive lease.
  var Buffer:array[0..63] of UInt64; FillChar(Buffer,SizeOf(Buffer),0);
  if not WorkGetInformation(Handle,7,@Buffer[0],SizeOf(Buffer)) then
  begin
    var Code:=GetLastError;
    // Directories have no unnamed data stream. EOF proves an empty stream set.
    if Directory and (Code=ERROR_HANDLE_EOF) then Exit;
    RaiseLastOSError(Code);
  end;
  if Directory then raise EReadError.Create('В рабочей папке появился дополнительный поток.');
  var Next,NameBytes:DWORD; Move(Buffer[0],Next,4); Move(PByte(@Buffer[0])[4],NameBytes,4);
  var Name:string;
  if (Next<>0) or (NameBytes<>14) then raise EReadError.Create('В рабочем файле появились дополнительные потоки.');
  SetString(Name,PWideChar(PByte(@Buffer[0])+24),7);
  if Name<>'::$DATA' then raise EReadError.Create('Неизвестный поток рабочего файла.');
end;

function Hold(const Path,Expected:string; Directory:Boolean; ReadData:Boolean=False):THandle;
begin
  var Share:DWORD:=0; if Directory then Share:=FILE_SHARE_READ or FILE_SHARE_WRITE;
  var Access:DWORD:=FILE_READ_ATTRIBUTES or Winapi.Windows._DELETE; if ReadData then Access:=Access or GENERIC_READ;
  Result:=CreateFile(PChar(DeletionNativePath(Path)),Access,Share,nil,
    OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS,0);
  if Result=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    var Bytes:Int64;
    if (Length(Expected)<>25) or (ObjectKey(Result,Directory,Bytes)<>Expected) or
      not SameFileName(DeletionNativePath(TransferFinalHandlePath(Result)),DeletionNativePath(ExpandFileName(Path))) then
      raise EReadError.Create('Рабочий объект заменён или перенаправлен.');
    RequireDefaultStream(Result,Directory);
  except CloseHandle(Result); Result:=0; raise; end;
end;

procedure Unlink(Handle:THandle);
begin
  var Flag:Byte:=1;
  if not WorkSetInformation(Handle,4,@Flag,SizeOf(Flag)) then RaiseLastOSError;
end;

function ReadDirectories(Journal:TCollectionTransferJournal; DB:TSQLiteDatabase;
  const Check:TProc):TObjectList<TWorkDirectory>;
begin
  Result:=TObjectList<TWorkDirectory>.Create(True);
  var Allowed:=TObjectDictionary<string,TDictionary<string,Boolean>>.Create([doOwnsValues]);
  var Seen:=TDictionary<string,Boolean>.Create; var Q:TSQLiteQuery:=nil;
  try
    try
      if not HasTable(DB,Claims) then Exit;
      if not HasTable(DB,Intent) then raise EReadError.Create('Нет независимого плана рабочих снимков.');
      Q:=DB.NewQuery('SELECT ReviewSHA256,IntentJSON,IntentSHA256,State FROM '+Intent+' WHERE Operation=?',[Meta(Journal,'directory')]); Q.Open;
      if Q.Eof or (Q.FieldAsString(0)<>Journal.ReviewSHA256) or (Q.FieldAsString(3)<>'prepared') or
        (Length(Q.FieldAsString(1))>16*1024*1024) or (THashSHA2.GetHashString(Q.FieldAsString(1))<>Q.FieldAsString(2)) then
        raise EReadError.Create('Не подтверждён независимый план рабочих снимков.');
      var Data:=TJSONObject.ParseJSONValue(Q.FieldAsString(1)) as TJSONObject; FreeAndNil(Q);
      try
        if (Data=nil) or (Data.GetValue<string>('kind')<>'HomeLibre cache preparation v1') or
          (Data.GetValue<string>('operation')<>Meta(Journal,'directory')) or (Data.GetValue<string>('review')<>Journal.ReviewSHA256) then
          raise EReadError.Create('Рабочие снимки относятся к другому переносу.');
        for var Value in Data.GetValue<TJSONArray>('jobs') do
        begin
          Check; var ID:=TJSONObject(Value).GetValue<string>('job');
          if (Length(ID)<>64) or Allowed.ContainsKey(ID) then raise EReadError.Create('Неверное задание рабочего снимка.');
          var Names:=TDictionary<string,Boolean>.Create; Allowed.Add(ID,Names);
          Names.Add('catalog.hlc2',True); Names.Add('ready.json',True);
        end;
        for var Value in Data.GetValue<TJSONArray>('inputs') do
        begin
          Check; var Row:=TJSONObject(Value); var Names:TDictionary<string,Boolean>;
          if not Allowed.TryGetValue(Row.GetValue<string>('job'),Names) then raise EReadError.Create('Индекс не связан с заданием снимка.');
          var Name:=ExtractFileName(Row.GetValue<string>('target_file'));
          if not Name.StartsWith('index-') or (Pos(':',Name)>0) or (Pos('/',Name)>0) or (Pos('\',Name)>0) then
            raise EReadError.Create('Неверное имя рабочего индекса.');
          Names.AddOrSetValue(LowerCase(Name),True);
        end;
      finally Data.Free; end;
      Q:=DB.NewQuery('SELECT Job,Directory,Path,FileKey FROM '+Claims+' WHERE Operation=? AND Stage=''cache-directory-created'' ORDER BY Job,Directory',
        [Meta(Journal,'directory')]); Q.Open;
      while not Q.Eof do
      begin
        Check; var Item:=TWorkDirectory.Create; Result.Add(Item);
        Item.Job:=Q.FieldAsString(0); Item.Path:=Q.FieldAsString(1); Item.Key:=Q.FieldAsString(3);
        var Leaf:=ExtractFileName(Item.Path); var ID:TGUID;
        if not Leaf.StartsWith('cache-snapshot-') then raise EReadError.Create('Неизвестная папка рабочих данных.');
        ID:=StringToGUID(Copy(Leaf,16,MaxInt));
        if (Leaf<>'cache-snapshot-'+GUIDToString(ID)) or (Q.FieldAsString(2)<>Item.Path) or
          not SameFileName(ExtractFileDir(Item.Path),Journal.Directory) or not Allowed.ContainsKey(Item.Job) or
          Seen.ContainsKey(LowerCase(Item.Path)) or (Length(Item.Key)<>25) then
          raise EReadError.Create('Не совпала независимая привязка рабочей папки.');
        Seen.Add(LowerCase(Item.Path),True);
        var F:=DB.NewQuery('SELECT Path,FileKey FROM '+Claims+' WHERE Operation=? AND Job=? AND Directory=? AND Stage=''cache-file-reserved''',
          [Meta(Journal,'directory'),Item.Job,Item.Path]);
        try F.Open; while not F.Eof do
          begin
            Check; var Path:=F.FieldAsString(0); var Name:=LowerCase(ExtractFileName(Path));
            if not SameFileName(ExtractFileDir(Path),Item.Path) or not Allowed[Item.Job].ContainsKey(Name) or
              Item.Files.ContainsKey(Name) or (Length(F.FieldAsString(1))<>25) then
              raise EReadError.Create('Не совпала независимая привязка рабочего файла.');
            Item.Files.Add(Name,F.FieldAsString(1)); F.Next;
          end;
        finally F.Free; end;
        Q.Next;
      end;
    except Result.Free; Result:=nil; raise; end;
  finally Q.Free; Seen.Free; Allowed.Free; end;
end;

procedure ReadForkSnapshots(Journal:TCollectionTransferJournal; DB:TSQLiteDatabase;
  Items:TObjectList<TWorkDirectory>; const Check:TProc);
begin
  if Journal.Review.QuerySingleInt('SELECT count(*) FROM ForkSources')=0 then Exit;
  if not HasTable(DB,ForkReceipts) then raise EReadError.Create('Нет подтверждения публикации копий общего каталога.');
  var Expected:=Journal.Review.QuerySingleInt('SELECT count(*) FROM ForkMembers');
  if (Expected=0) or (DB.QuerySingleInt('SELECT count(*) FROM '+ForkReceipts+' WHERE Operation=?',
    [Meta(Journal,'directory')])<>Expected) then raise EReadError.Create('Изменились подтверждения копий общего каталога.');
  var Q:=Journal.Review.NewQuery('SELECT m.ForkID,m.RegistrationID,f.Destination,s.SHA256 '+
    'FROM ForkMembers m JOIN CatalogueForks f ON f.ID=m.ForkID JOIN ForkSources s ON s.ID=f.SourceID');
  try
    Q.Open; var Seen:=0;
    while not Q.Eof do
    begin
      Check;
      if DB.QuerySingleInt('SELECT count(*) FROM '+ForkReceipts+
        ' WHERE Operation=? AND ForkID=? AND RegistrationID=? AND ReviewSHA256=? AND Target=? AND SnapshotSHA256=?',
        [Meta(Journal,'directory'),Q.FieldAsInt(0),Q.FieldAsInt(1),Journal.ReviewSHA256,Q.FieldAsString(2),Q.FieldAsString(3)])<>1 then
        raise EReadError.Create('Не совпало подтверждение копии общего каталога.');
      Inc(Seen); Q.Next;
    end;
    if Seen<>Expected then raise EReadError.Create('Неполный план копий общего каталога.');
  finally Q.Free; end;
  var Item:=TWorkDirectory.Create; Items.Add(Item); Item.Fork:=True;
  Item.Path:=TPath.Combine(Journal.Directory,'catalogue-snapshots');
  Item.Key:=Meta(Journal,'fork_snapshots_key');
  // Legacy experimental reviews have no sealed directory key. They remain
  // recoverable but cannot authorize reclaiming this folder from a draft lease.
  Q:=Journal.Review.NewQuery('SELECT Snapshot,Identity,Bytes,SHA256 FROM ForkSources');
  try
    Q.Open;
    while not Q.Eof do
    begin
      Check; var Path:=Q.FieldAsString(0); var Name:=ExtractFileName(Path); var ID:TGUID;
      if not Name.EndsWith('.hlc2') then raise EReadError.Create('Неизвестное имя снимка каталога.');
      ID:=StringToGUID(ChangeFileExt(Name,''));
      var Identity:=Q.FieldAsString(1); var SHA:=Q.FieldAsString(3); var Bytes:=StrToInt64(Q.FieldAsString(2));
      if (Name<>GUIDToString(ID)+'.hlc2') or not SameFileName(ExtractFileDir(Path),Item.Path) or
        not SameFileName(ExpandFileName(Path),Path) or (Length(Identity)<>59) or (Length(SHA)<>64) or
        (Bytes<0) or Item.Files.ContainsKey(LowerCase(Name)) then raise EReadError.Create('Неверная привязка снимка общего каталога.');
      Name:=LowerCase(Name); Item.Files.Add(Name,Copy(Identity,1,25));
      Item.Hashes.Add(Name,SHA); Item.Sizes.Add(Name,Bytes); Q.Next;
    end;
  finally Q.Free; end;
end;

procedure VerifySnapshot(Item:TWorkDirectory; const FileItem:THeldWorkFile; const Check:TProc);
begin
  var Name:=LowerCase(ExtractFileName(FileItem.Path)); var Expected:string;
  if not Item.Hashes.TryGetValue(Name,Expected) then Exit;
  if FileItem.Bytes<>Item.Sizes[Name] then raise EReadError.Create('Размер рабочего снимка изменён.');
  var Hash:=THashSHA2.Create; var Buffer:TBytes; SetLength(Buffer,1024*1024); var Count:DWORD; var Total:Int64:=0;
  repeat
    Check;
    if not ReadFile(FileItem.Handle,Buffer[0],Length(Buffer),Count,nil) then RaiseLastOSError;
    if Count>0 then begin Hash.Update(Buffer,Count); Inc(Total,Count); end;
  until Count=0;
  if (Total<>FileItem.Bytes) or (Hash.HashAsString<>Expected) then raise EReadError.Create('Содержимое рабочего снимка изменено.');
end;

procedure RemoveDirectoryFiles(Item:TWorkDirectory; const Check:TProc; var Outcome:TTransferCleanupResult);
var Root:THandle; Files:TList<THeldWorkFile>;
begin
  Root:=0; Files:=TList<THeldWorkFile>.Create;
  try
    Point('cleanup-before-directory',Item.Path); Check;
    var Attr:=GetFileAttributes(PChar(DeletionNativePath(Item.Path)));
    if Attr=INVALID_FILE_ATTRIBUTES then
    begin
      if GetLastError in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND] then begin Inc(Outcome.DirectoriesMissing); Exit; end;
      RaiseLastOSError;
    end;
    Root:=Hold(Item.Path,Item.Key,True);
    for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(Item.Path)) do
    begin
      Check; var Expected:string; var FileItem:=Default(THeldWorkFile);
      if not Item.Files.TryGetValue(LowerCase(ExtractFileName(Path)),Expected) then raise EReadError.Create('В рабочем снимке есть неизвестный файл.');
      FileItem.Path:=Path; FileItem.Handle:=Hold(Path,Expected,False,Item.Fork);
      try ObjectKey(FileItem.Handle,False,FileItem.Bytes); VerifySnapshot(Item,FileItem,Check); Files.Add(FileItem);
      except CloseHandle(FileItem.Handle); raise; end;
    end;
    // Validate the entire directory and hold every file before deleting any.
    for var I:=0 to Files.Count-1 do
    begin
      Check; var FileItem:=Files[I]; Point('cleanup-before-file',FileItem.Path); Check;
      Unlink(FileItem.Handle); CloseHandle(FileItem.Handle); FileItem.Handle:=0; Files[I]:=FileItem;
      Inc(Outcome.FilesRemoved); Inc(Outcome.BytesRemoved,FileItem.Bytes); Point('cleanup-after-file',FileItem.Path);
    end;
    Check; RequireDefaultStream(Root,True); Unlink(Root); CloseHandle(Root); Root:=0;
    Inc(Outcome.DirectoriesRemoved); Point('cleanup-after-directory',Item.Path);
  finally
    for var FileItem in Files do if FileItem.Handle<>0 then CloseHandle(FileItem.Handle);
    Files.Free; if Root<>0 then CloseHandle(Root);
  end;
end;

procedure RememberAttempt(const PersonalFile,PersonalKey,Operation,ReviewSHA:string; Done:Boolean;
  const TempDirectory:string=''; Forks:Boolean=False);
begin
  var Marker:=Cleanup; if Forks then Marker:=ForkCleanup;
  var Lease:=AcquireCompressionDatabaseLease(PersonalFile,PersonalKey);
  var DB:=TSQLiteDatabase.Create(DeletionNativePath(PersonalFile),False,False,TempDirectory);
  try
    DB.ExecSQL('BEGIN IMMEDIATE');
    if DB.QuerySingleInt('SELECT count(*) FROM '+Operations+' WHERE Operation=? AND PersonalKey=? AND ReviewSHA256=? AND State=''completed''',
      [Operation,PersonalKey,ReviewSHA])<>1 then raise EReadError.Create('Регистрация завершённого переноса изменилась.');
    if Done and HasTable(DB,Marker) and (DB.QuerySingleInt('SELECT count(*) FROM '+Marker+
      ' WHERE Operation=? AND ReviewSHA256=? AND Done=1',[Operation,ReviewSHA])=1) then
    begin DB.Rollback; Exit; end;
    DB.ExecSQL('CREATE TABLE IF NOT EXISTS '+Marker+'(Operation TEXT PRIMARY KEY,ReviewSHA256 TEXT,Done INTEGER CHECK(Done IN (0,1)),LastAttempt TEXT) WITHOUT ROWID');
    DB.ExecSQL('INSERT OR REPLACE INTO '+Marker+' VALUES(?,?,?,?)',
      [Operation,ReviewSHA,Ord(Done),DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True)]);
    DB.Commit;
  finally DB.Free; Lease:=nil; end;
end;

function CleanupCompletedTransferCaches(Journal:TCollectionTransferJournal; const Cancelled:TFunc<Boolean>):TTransferCleanupResult;
var Check:TProc;
begin
  Check:=procedure begin if Assigned(Cancelled) and Cancelled() then raise EAbort.Create('Уборка рабочих снимков отложена.'); end;
  Result:=Default(TTransferCleanupResult); var Completed:TTransferCompletionResult;
  if (Journal=nil) or not ReadTransferCompletion(Journal,Completed) then raise EReadError.Create('Нет подтверждённого завершения переноса.');
  var PersonalFile:=Meta(Journal,'personal'); var PersonalKey:=Meta(Journal,'personal_key');
  var Lease:=AcquireCompressionDatabaseLease(PersonalFile,PersonalKey);
  var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(PersonalFile),Journal.Directory); var Directories:TObjectList<TWorkDirectory>:=nil;
  try
    try
      DB.ExecSQL('BEGIN'); Directories:=ReadDirectories(Journal,DB,Check);
      ReadForkSnapshots(Journal,DB,Directories,Check);
    except Directories.Free; raise; end;
  finally DB.Free; Lease:=nil; end;
  try
    var CacheRetained:=False; var ForkRetained:=False; var HasForks:=False;
    try
      for var Item in Directories do
      begin
        if Item.Fork then HasForks:=True;
        Check;
        try RemoveDirectoryFiles(Item,Check,Result);
        except
          on E:EAbort do raise;
          on E:Exception do
          begin
            if Item.Fork then ForkRetained:=True else CacheRetained:=True;
            Inc(Result.DirectoriesRetained); if Result.Warning='' then Result.Warning:=Item.Path+': '+E.Message;
          end;
        end;
      end;
    except on E:EAbort do Result.Stopped:=True; end;
    if not Result.Stopped then
    begin
      Point('cleanup-before-record',Journal.Directory);
      RememberAttempt(PersonalFile,PersonalKey,Meta(Journal,'directory'),Journal.ReviewSHA256,not CacheRetained,Journal.Directory);
      if HasForks then RememberAttempt(PersonalFile,PersonalKey,Meta(Journal,'directory'),Journal.ReviewSHA256,
        not ForkRetained,Journal.Directory,True);
      Point('cleanup-after-record',Journal.Directory);
    end;
  finally Directories.Free; end;
end;

function CompletedTransferCleanupQueue(const PersonalFile:string):TArray<TRegisteredCollectionTransfer>;
begin
  Result:=nil; var Key:=CompressionFileKey(PersonalFile); var Lease:=AcquireCompressionDatabaseLease(PersonalFile,Key);
  var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(PersonalFile)); var Items:=TList<TRegisteredCollectionTransfer>.Create;
  var Q:TSQLiteQuery:=nil;
  try
    if not HasTable(DB,Operations) then Exit;
    var Join:string:=''; var Filter:string:='0'; var CacheOrder:string:=''''''; var ForkOrder:string:='''''';
    if HasTable(DB,Cleanup) then
    begin
      Join:=' LEFT JOIN '+Cleanup+' c ON c.Operation=o.Operation AND c.ReviewSHA256=o.ReviewSHA256';
      CacheOrder:='coalesce(c.LastAttempt,'''')';
    end;
    if HasTable(DB,Claims) then
    begin
      Filter:='EXISTS(SELECT 1 FROM '+Claims+' x WHERE x.Operation=o.Operation AND x.Stage=''cache-directory-created'')';
      if HasTable(DB,Cleanup) then Filter:='('+Filter+' AND coalesce(c.Done,0)=0)';
    end;
    if HasTable(DB,ForkCleanup) then
    begin
      Join:=Join+' LEFT JOIN '+ForkCleanup+' f ON f.Operation=o.Operation AND f.ReviewSHA256=o.ReviewSHA256';
      ForkOrder:='coalesce(f.LastAttempt,'''')';
    end;
    if HasTable(DB,ForkReceipts) then
    begin
      var Pending:='EXISTS(SELECT 1 FROM '+ForkReceipts+' x WHERE x.Operation=o.Operation)';
      if HasTable(DB,ForkCleanup) then Pending:='('+Pending+' AND coalesce(f.Done,0)=0)';
      Filter:=Filter+' OR '+Pending;
    end;
    Q:=DB.NewQuery('SELECT o.Operation,o.Directory,o.ReviewSHA256,o.PersonalKey,o.WorkRoot,o.Destination,o.CollectionID FROM '+Operations+' o'+Join+
      ' WHERE o.State=''completed'' AND ('+Filter+') ORDER BY max('+CacheOrder+','+ForkOrder+'),o.Operation LIMIT 1024'); Q.Open;
    while not Q.Eof do
    begin
      var Item:=Default(TRegisteredCollectionTransfer); Item.Operation:=Q.FieldAsString(0); Item.Directory:=Q.FieldAsString(1);
      Item.ReviewSHA256:=Q.FieldAsString(2); Item.PersonalKey:=Q.FieldAsString(3); Item.WorkRoot:=Q.FieldAsString(4);
      Item.Destination:=Q.FieldAsString(5); Item.CollectionID:=Q.FieldAsInt(6);
      if Item.PersonalKey<>Key then raise EReadError.Create('Уборка относится к другой личной базе.');
      Items.Add(Item); Q.Next;
    end;
    Result:=Items.ToArray;
  finally Q.Free; Items.Free; DB.Free; Lease:=nil; end;
end;

function CleanupRegisteredCompletedTransfers(const PersonalFile:string; const Cancelled:TFunc<Boolean>):TTransferCleanupResult;
begin
  Result:=Default(TTransferCleanupResult);
  for var Item in CompletedTransferCleanupQueue(PersonalFile) do
  begin
    if Assigned(Cancelled) and Cancelled() then begin Result.Stopped:=True; Break; end;
    try
      var Journal:=TCollectionTransferJournal.OpenCompletedForCleanup(Item.WorkRoot,Item.Destination,Item.Directory,Item.ReviewSHA256,Cancelled);
      try
        var One:=Journal.CleanupCompletedCacheSnapshots(Cancelled);
        Inc(Result.FilesRemoved,One.FilesRemoved); Inc(Result.BytesRemoved,One.BytesRemoved);
        Inc(Result.DirectoriesRemoved,One.DirectoriesRemoved); Inc(Result.DirectoriesMissing,One.DirectoriesMissing);
        Inc(Result.DirectoriesRetained,One.DirectoriesRetained); Result.Stopped:=One.Stopped;
        if Result.Warning='' then Result.Warning:=One.Warning;
      finally Journal.Free; end;
    except
      on E:EAbort do Result.Stopped:=True;
      on E:Exception do
      begin
        Inc(Result.DirectoriesRetained); if Result.Warning='' then Result.Warning:=E.Message;
        try RememberAttempt(PersonalFile,Item.PersonalKey,Item.Operation,Item.ReviewSHA256,False); except end;
      end;
    end;
    if Result.Stopped then Break;
  end;
end;

end.
