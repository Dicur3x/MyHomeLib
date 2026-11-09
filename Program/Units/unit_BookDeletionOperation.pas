unit unit_BookDeletionOperation;

interface

uses System.Classes, System.SysUtils, unit_Interfaces, unit_Globals,
  unit_BookDeletionBinding, unit_ArchiveDeletionQueue;

type
  TBookDeletionOperationStatus = record
    Stage, Archive, Error, RequiredComponent, PendingJournal, CleanupWarning: string;
    CollectionName: string;
    CollectionIndex, CollectionCount: Integer;
    Done, Total: Int64;
    MoveBytes, JournalBytes: Int64;
    CompanionCount: Integer;
    ArchiveIndex, ArchiveCount, CompletedBooks, CompletedCopies: Integer;
    Stopping, Finished, CatalogueChanged, AwaitingArchiveConfirmation: Boolean;
  end;

  TBookDeletionBatchItem = record
    Binding: TBookDeletionBinding;
    CollectionName: string;
    RemoveFiles: Boolean;
  end;

  // Owns the catalogue connection and drives the existing archive worker.
  // Only snapshots cross to the window; no VCL work runs on either thread.
  TBookDeletionOperation = class(TThread)
  private
    FBinding, FRetainedDuplicates: TBookDeletionBinding;
    FBatch: TArray<TBookDeletionBatchItem>;
    FJournalRoot, FUserFile: string;
    FReviewFiles: TArray<string>;
    FRecovery, FReviewArchives: Boolean;
    FLock: TObject;
    FStop: Integer;
    FState: TBookDeletionOperationStatus;
    function Stopping: Boolean;
    procedure Report(const Stage, Archive: string; Index, Count: Integer;
      Done: Int64 = 0; Total: Int64 = 0);
    procedure WaitForArchiveConfirmation(MoveBytes, JournalBytes: Int64; CompanionCount: Integer);
    procedure CompleteBinding(const Binding: TBookDeletionBinding; const User: ISystemData);
    procedure RunQueue(Queue: TArchiveDeletionQueue; const User: ISystemData;
      Offset, Count: Integer);
    procedure RunRemoval(const User: ISystemData);
    procedure CheckDuplicateSources(const User: ISystemData);
    procedure RunBatch(const User: ISystemData);
    procedure RunRecovery(const User: ISystemData);
  protected
    procedure Execute; override;
  public
    constructor Create(const Binding: TBookDeletionBinding; const UserFile, JournalRoot: string);
    constructor CreateBatch(const Items: TArray<TBookDeletionBatchItem>;
      const UserFile, JournalRoot: string);
    constructor CreateDuplicateRemoval(const Selection: TDuplicateFileDeletion; const UserFile, JournalRoot: string);
    constructor Recover(const UserFile, JournalRoot: string);
    destructor Destroy; override;
    procedure RequestStop;
    procedure ConfirmArchive;
    function Status: TBookDeletionOperationStatus;
    property ReviewArchives: Boolean write FReviewArchives;
  end;

function IsArchiveBookSource(const Book: TBookRecord): Boolean;
function HasArchiveDeletionJournals(const JournalRoot: string): Boolean;

implementation

uses Winapi.Windows, System.IOUtils, System.SyncObjs, System.Generics.Collections,
  unit_SystemDatabase_SQLite, unit_BookDeletionPreparation, unit_ZipMemberDeletion,
  unit_MHLArchiveHelpers, unit_MHLExternalTools, unit_BookDeletionReferences,
  unit_BookDeletionInventory, unit_BookDeletionMembers, unit_ReaderCache, SQLiteWrap;

function IsArchiveBookSource(const Book: TBookRecord): Boolean;
begin
  // A catalogue-only confirmation never probes the source drive.
  Result:=not Book.IsLinkedSource and
    IsArchiveExt(Book.GetBookFileName(TPath.Combine(Book.CollectionRoot,Book.Folder)));
end;

constructor TBookDeletionOperation.Create(const Binding:TBookDeletionBinding;
  const UserFile,JournalRoot:string);
begin
  inherited Create(True);
  FLock:=TObject.Create; FreeOnTerminate:=False;
  FBinding:=Binding; FUserFile:=UserFile; FJournalRoot:=ExpandFileName(JournalRoot);
  Priority:=tpLower;
end;

constructor TBookDeletionOperation.CreateBatch(const Items:TArray<TBookDeletionBatchItem>;
  const UserFile,JournalRoot:string);
var Seen:TDictionary<Integer,Byte>; Sources:TDictionary<string,Boolean>; BookCount:Integer;
begin
  Create(Default(TBookDeletionBinding),UserFile,JournalRoot);
  if (Length(Items)=0) or (Length(Items)>128) then
    raise EArgumentException.Create('Выберите книги из 1–128 коллекций.');
  Seen:=TDictionary<Integer,Byte>.Create; Sources:=TDictionary<string,Boolean>.Create;
  try
    BookCount:=0; SetLength(FBatch,Length(Items));
    for var I:=0 to High(Items) do
    begin
      // Capture private managed arrays; the selection window may close or
      // change while this one background operation is running.
      FBatch[I].Binding:=TBookDeletionBinding.Parse(Items[I].Binding.ToJSON);
      FBatch[I].CollectionName:=Items[I].CollectionName;
      FBatch[I].RemoveFiles:=Items[I].RemoveFiles;
      var ID:=FBatch[I].Binding.CollectionID;
      if Seen.ContainsKey(ID) then
        raise EArgumentException.Create('Одна коллекция повторяется в плане удаления.');
      Seen.Add(ID,0);
      Inc(BookCount,Length(FBatch[I].Binding.ExpectedBooks));
      if BookCount>100000 then
        raise EArgumentException.Create('Выберите не более 100000 книг за одну операцию.');
      for var Book in FBatch[I].Binding.ExpectedBooks do
      begin
        var SourceKey:=LowerCase(ExpandFileName(Book.GetBookFileName(
          TPath.Combine(Book.CollectionRoot,Book.Folder))));
        if IsArchiveBookSource(Book) then
          SourceKey:=SourceKey+'|'+LowerCase(Book.FileName+Book.FileExt);
        var RemoveSource:Boolean;
        var WantsPhysical:=FBatch[I].RemoveFiles and not Book.IsLinkedSource;
        if Sources.TryGetValue(SourceKey,RemoveSource) then
        begin
          if RemoveSource<>WantsPhysical then
            raise EArgumentException.Create('Один файл выбран и для сохранения, и для удаления. Измените выбор книг.');
        end
        else Sources.Add(SourceKey,WantsPhysical);
      end;
      if not FBatch[I].RemoveFiles and not FBatch[I].Binding.RemoveRecords then
        raise EArgumentException.Create('В плане не выбрано удаление записей или файлов.');
    end;
  finally Sources.Free; Seen.Free; end;
end;

procedure TBookDeletionOperation.RunBatch(const User:ISystemData);
var Step:Integer;
begin
  // Validate every selected catalogue before the first change. Each existing
  // worker still rechecks its own bound identities immediately before writing.
  for var Item in FBatch do
  begin
    if Stopping then Exit;
    Item.Binding.CheckBeforePhysicalRemoval(User);
  end;
  // Keep catalogue-only source references alive until every physical phase
  // has checked for shared archive members and companion images.
  Step:=0;
  for var PhysicalPass in TArray<Boolean>.Create(True,False) do
  for var I:=0 to High(FBatch) do
  begin
    if FBatch[I].RemoveFiles<>PhysicalPass then Continue;
    if Stopping then Exit;
    Inc(Step);
    FBinding:=FBatch[I].Binding;
    TMonitor.Enter(FLock);
    try
      FState.CollectionIndex:=Step; FState.CollectionCount:=Length(FBatch);
      FState.CollectionName:=FBatch[I].CollectionName;
    finally TMonitor.Exit(FLock); end;
    if FBatch[I].RemoveFiles then RunRemoval(User)
    else
    begin
      Report('Удаление записей из коллекции','',0,0);
      CompleteBinding(FBinding,User);
    end;
  end;
end;

constructor TBookDeletionOperation.CreateDuplicateRemoval(const Selection: TDuplicateFileDeletion;
  const UserFile, JournalRoot: string);
begin
  Create(Selection.Removed,UserFile,JournalRoot);
  if (Selection.Retained.CollectionID<>Selection.Removed.CollectionID) or
    not Selection.Removed.RemoveRecords or (Length(Selection.Retained.ExpectedBooks)=0) then
    raise EArgumentException.Create('Не выбраны сохраняемые копии дублей.');
  FRetainedDuplicates:=Selection.Retained;
end;

procedure TBookDeletionOperation.CheckDuplicateSources(const User: ISystemData);
var Retained: TDictionary<string,Byte>; Containers: TDictionary<string,Byte>;
  PrimaryIDs: TDictionary<Integer,Byte>;
  LastInventory: TArray<string>; LastSource: string;
  Personal, Catalogue: TSQLiteDatabase;
  Collection: IBookCollection;
  procedure Locate(const Book: TBookRecord; Kept: Boolean);
  var Path, Source, Key: string; Members: TArray<string>;
  begin
    if Stopping then Abort;
    Path:=Book.GetBookFileName;
    if not FileExists(Path) or (TFile.GetSize(Path)<=0) then
    begin
      if Kept then raise EReadError.CreateFmt('Файл сохраняемой копии недоступен: %s. Удаление не началось.',[Path]);
      raise EReadError.CreateFmt('Файл удаляемой копии недоступен: %s. Удаление не началось.',[Path]);
    end;
    if not Kept and not FBinding.RemovesCopies then
    begin
      if Book.IsLinkedSource then
        raise EReadError.Create('Эта книга добавлена ссылкой. Удалите её запись из каталога, чтобы сохранить исходный файл.');
      var ID:=Book.BookKey.BookID;
      var CID:=Book.BookKey.DatabaseID;
      if (Personal.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM Books WHERE DatabaseID=? AND BookID=?) OR '+
        'EXISTS(SELECT 1 FROM BookGroups WHERE DatabaseID=? AND BookID=?)',[CID,ID,CID,ID])<>0) or
        (Catalogue.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM Books WHERE BookID=? AND '+
          '(Rate<>0 OR Progress<>0 OR length(CAST(Review AS BLOB))>0))',[ID])<>0) then
        raise EReadError.Create('У удаляемой копии появились личные данные. Повторите поиск дублей.');
      for var CopyBook in Collection.GetCatalogBookCopies(Book.BookKey) do
        if ReaderBookPhysicalIdentity(CopyBook)<>ReaderBookPhysicalIdentity(Book) then
          raise EReadError.Create('С удаляемой записью связаны дополнительные копии. Повторите поиск дублей.');
    end;
    if not Kept and not IsPrivateArchiveDeletionSource(Path) then
      raise EReadError.CreateFmt('У файла есть ссылка или несколько имён: %s. Удаление не началось.',[Path]);
    Source:=ArchiveDeletionSourceIdentity(Path);
    Key:=Copy(Source,1,25);
    if Kept then Containers.AddOrSetValue(Key,0);
    if not Kept and not Containers.ContainsKey(Key) then Exit;
    if IsArchiveBookSource(Book) and not IsWholeBookArchive(Book) then
    begin
      if Source<>LastSource then
      begin
        LastInventory:=ReadBookDeletionInventory(Path,Source,function:Boolean begin Result:=Stopping; end);
        LastSource:=Source;
      end;
      Members:=ExactBookDeletionMembers(Book,LastInventory);
    end
    else Members:=TArray<string>.Create('');
    for var Member in Members do
    begin
      var Identity:=Key+'|'+Member.Replace('\','/');
      if Kept then Retained.AddOrSetValue(Identity,0)
      else if Retained.ContainsKey(Identity) or Retained.ContainsKey(Key+'|') or
        (Member='') then
        raise EReadError.CreateFmt('Сохраняемая и удаляемая записи указывают на один файл: %s.',[Path]);
    end;
  end;
begin
  if (FRetainedDuplicates.CollectionID=0) and not FBinding.RemovesCopies then Exit;
  Report('Проверка сохраняемых копий дублей','',0,0);
  Retained:=nil; Containers:=nil; Personal:=nil; Catalogue:=nil; PrimaryIDs:=nil;
  try
    Retained:=TDictionary<string,Byte>.Create;
    Containers:=TDictionary<string,Byte>.Create;
    if FBinding.RemovesCopies then
    begin
      PrimaryIDs:=TDictionary<Integer,Byte>.Create;
      for var Book in FBinding.PrimaryBooks do
        if not PrimaryIDs.ContainsKey(Book.BookKey.BookID) then
        begin
          Locate(Book,True);
          PrimaryIDs.Add(Book.BookKey.BookID,0);
        end;
    end
    else
    begin
      FRetainedDuplicates.CheckBeforePhysicalRemoval(User);
      Personal:=TSQLiteDatabase.CreateReadOnly(FUserFile);
      Catalogue:=TSQLiteDatabase.CreateReadOnly(User.GetCollectionInfo(FBinding.CollectionID).DBFileName);
      Collection:=User.GetCollection(FBinding.CollectionID);
      for var Book in FRetainedDuplicates.ExpectedBooks do Locate(Book,True);
    end;
    for var Book in FBinding.ExpectedBooks do Locate(Book,False);
    if not FBinding.RemovesCopies then
      CheckLooseDuplicateReferences(User,FBinding.CollectionID,FBinding.ExpectedBooks,
        function:Boolean begin Result:=Stopping; end);
  finally PrimaryIDs.Free; Catalogue.Free; Personal.Free; Containers.Free; Retained.Free; end;
end;

constructor TBookDeletionOperation.Recover(const UserFile,JournalRoot:string);
begin
  Create(Default(TBookDeletionBinding),UserFile,JournalRoot);
  FRecovery:=True;
end;

destructor TBookDeletionOperation.Destroy;
begin
  RequestStop;
  inherited;
  FLock.Free;
end;

function TBookDeletionOperation.Stopping:Boolean;
begin Result:=TInterlocked.CompareExchange(FStop,0,0)<>0; end;

procedure TBookDeletionOperation.RequestStop;
begin
  TInterlocked.Exchange(FStop,1);
  if not Assigned(FLock) then Exit;
  TMonitor.Enter(FLock);
  try TMonitor.PulseAll(FLock); finally TMonitor.Exit(FLock); end;
end;

procedure TBookDeletionOperation.ConfirmArchive;
begin
  TMonitor.Enter(FLock);
  try
    FState.AwaitingArchiveConfirmation:=False;
    TMonitor.PulseAll(FLock);
  finally TMonitor.Exit(FLock); end;
end;

procedure TBookDeletionOperation.WaitForArchiveConfirmation(MoveBytes, JournalBytes: Int64;
  CompanionCount: Integer);
var Observers:TObjectList<TSQLiteDatabase>; Revisions:TArray<Int64>; Identities:TArray<string>;
begin
  // The catalogue remains usable while the archive is locked for review.
  // An edit to any catalogue may add a reference to the member being removed.
  Observers:=TObjectList<TSQLiteDatabase>.Create;
  try
    SetLength(Revisions,Length(FReviewFiles)); SetLength(Identities,Length(FReviewFiles));
    for var I:=0 to High(FReviewFiles) do
    begin
      if Stopping then Abort;
      if FileExists(FReviewFiles[I]) then
      begin
        Identities[I]:=Copy(ArchiveDeletionSourceIdentity(FReviewFiles[I]),1,25);
        Observers.Add(TSQLiteDatabase.CreateReadOnly(FReviewFiles[I]));
        Revisions[I]:=Observers[I].QuerySingleInt('PRAGMA main.data_version');
      end
      else Observers.Add(nil);
    end;
    TMonitor.Enter(FLock);
    try
      if Stopping then Abort;
      FState.MoveBytes:=MoveBytes;
      FState.JournalBytes:=JournalBytes;
      FState.CompanionCount:=CompanionCount;
      FState.AwaitingArchiveConfirmation:=True;
      try
        while FState.AwaitingArchiveConfirmation and not Stopping do TMonitor.Wait(FLock,INFINITE);
        if Stopping then Abort;
      finally FState.AwaitingArchiveConfirmation:=False; end;
    finally TMonitor.Exit(FLock); end;
    for var I:=0 to High(FReviewFiles) do
    begin
      if Stopping then Abort;
      var DB:=Observers[I];
      if (FileExists(FReviewFiles[I])<>Assigned(DB)) or (Assigned(DB) and
        ((Copy(ArchiveDeletionSourceIdentity(FReviewFiles[I]),1,25)<>Identities[I]) or
        (DB.QuerySingleInt('PRAGMA main.data_version')<>Revisions[I]))) then
        raise EReadError.Create('Коллекция изменилась во время подтверждения. Архив не изменён. Повторите выбор книг.');
    end;
  finally Observers.Free; end;
end;

function TBookDeletionOperation.Status:TBookDeletionOperationStatus;
begin
  TMonitor.Enter(FLock);
  try Result:=FState; finally TMonitor.Exit(FLock); end;
  Result.Stopping:=Stopping;
end;

procedure TBookDeletionOperation.Report(const Stage,Archive:string; Index,Count:Integer;
  Done,Total:Int64);
begin
  TMonitor.Enter(FLock);
  try
    FState.Stage:=Stage; FState.Archive:=Archive;
    FState.ArchiveIndex:=Index; FState.ArchiveCount:=Count;
    FState.Done:=Done; FState.Total:=Total;
  finally TMonitor.Exit(FLock); end;
end;

procedure TBookDeletionOperation.CompleteBinding(const Binding:TBookDeletionBinding;
  const User:ISystemData);
begin
  // Two durable stores may commit separately. Even on failure the owner must
  // refresh the view and keep the receipt so the remaining phase can replay.
  TMonitor.Enter(FLock);
  try FState.CatalogueChanged:=True; finally TMonitor.Exit(FLock); end;
  if Binding.RemovesCopies then
  begin
    Binding.CommitCopies(User);
    Exit;
  end;
  if Binding.RemoveRecords then Binding.CommitRecords(User)
  else Binding.CommitSourceMissing(User);
  var Count:=Length(Binding.ExpectedBooks);
  TMonitor.Enter(FLock);
  try Inc(FState.CompletedBooks,Count); finally TMonitor.Exit(FLock); end;
end;

procedure TBookDeletionOperation.RunQueue(Queue:TArchiveDeletionQueue; const User:ISystemData;
  Offset,Count:Integer);
var Submitted:Integer; Progress:TArchiveDeletionStatus; Receipts:TArray<TArchiveDeletionResult>;
begin
  Submitted:=0; Queue.Start;
  repeat
    if Stopping then Queue.StopAfterCurrentArchive;
    Progress:=Queue.Status;
    if Progress.Archive<>'' then
      Report(Progress.Stage,Progress.Archive,Offset+Progress.ArchiveIndex,Count,
        Progress.Done,Progress.Total);
    Receipts:=Queue.Results;
    while Submitted<Length(Receipts) do
    begin
      var Receipt:=Receipts[Submitted];
      if not Receipt.FilesVerified then Break;
      try
        Report('Обновление коллекции',Receipt.Archive,Offset+Receipt.Index+1,Count);
        CompleteBinding(TBookDeletionBinding.Parse(Receipt.CatalogueBinding),User);
        if Stopping then Queue.StopAfterCurrentArchive;
        Queue.CatalogueCommitted(Receipt.Index);
      except
        Queue.CatalogueRejected(Receipt.Index);
        TMonitor.Enter(FLock);
        try FState.PendingJournal:=Receipt.WorkDirectory; finally TMonitor.Exit(FLock); end;
        raise;
      end;
      Inc(Submitted);
    end;
    // Wake for the receipt or end of the queue instead of sleeping for each
    // small archive. The timeout still refreshes progress and checks Stop.
    if not Progress.Finished then Queue.WaitForResult(25);
  until Progress.Finished;
  Queue.WaitFor;
  if Assigned(Queue.FatalException) then
    raise EInvalidOperation.Create(Exception(Queue.FatalException).Message);
  for var Receipt in Queue.Results do
    if Receipt.Acknowledged then
    begin
      var Copies:=0;
      if FBinding.RemovesCopies or FRecovery then
      begin
        var Binding:=TBookDeletionBinding.Parse(Receipt.CatalogueBinding);
        if Binding.RemovesCopies then Copies:=Length(Binding.SourceKeys);
      end;
      TMonitor.Enter(FLock);
      try
        Inc(FState.CompletedCopies,Copies);
        if FState.CleanupWarning = '' then FState.CleanupWarning := Receipt.CleanupWarning;
      finally TMonitor.Exit(FLock); end;
    end
    else
    begin
      if Receipt.JournalDirectory<>'' then
      begin
        TMonitor.Enter(FLock);
        try FState.PendingJournal:=Receipt.WorkDirectory; finally TMonitor.Exit(FLock); end;
      end;
      if Receipt.Cancelled then Abort;
      if Receipt.Error<>'' then raise EInOutError.Create(Receipt.Error);
      raise EInOutError.Create('Не удалось подтвердить удаление из архива.');
    end;
end;

procedure DeleteLooseBook(const Book:TBookRecord);
begin
  var Path:=DeletionNativePath(Book.GetBookFileName);
  if IsArchiveExt(Path) then raise EInOutError.Create('Путь книги изменился и указывает на архив.');
  var Attributes:=GetFileAttributes(PChar(Path));
  if Attributes=INVALID_FILE_ATTRIBUTES then
  begin
    var Error:=GetLastError;
    if Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND] then Exit;
    RaiseLastOSError(Error);
  end;
  if Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0 then
    raise EInOutError.Create('Путь книги указывает на папку или ссылку. Файл не удалён.');
  if not Winapi.Windows.DeleteFile(PChar(Path)) then RaiseLastOSError;
end;

procedure TBookDeletionOperation.RunRemoval(const User:ISystemData);
var Archives,Loose,Absent,Linked:TList<Integer>; Preparation:TBookDeletionPreparation;
  Progress:TBookDeletionPreparationStatus; Tasks:TArray<TArchiveDeletionTask>;
  Queue:TArchiveDeletionQueue; Review:TArchiveDeletionReview;
  Info:TCollectionInfo;
begin
  Report('Проверка выбранных книг','',0,0);
  if Stopping then Exit;
  FBinding.CheckBeforePhysicalRemoval(User);
  CheckDuplicateSources(User);
  var Books:=FBinding.ExpectedBooks;
  Archives:=TList<Integer>.Create; Loose:=TList<Integer>.Create; Absent:=TList<Integer>.Create;
  Linked:=TList<Integer>.Create;
  try
    for var I:=0 to High(Books) do
    begin
      if Stopping then Exit;
      if FBinding.RemovesCopies then
      begin
        // The preflight verified both copies. Use a durable receipt for
        // every file, including individual books outside an archive.
        Archives.Add(I);
        Continue;
      end;
      if Books[I].IsLinkedSource then
      begin
        if FBinding.RemoveRecords then Linked.Add(I);
        Continue;
      end;
      if not IsArchiveBookSource(Books[I]) then
      begin Loose.Add(I); Continue; end;
      var Path:=DeletionNativePath(Books[I].GetBookFileName);
      if GetFileAttributes(PChar(Path))=INVALID_FILE_ATTRIBUTES then
      begin
        var Error:=GetLastError;
        if Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND] then
        begin Absent.Add(I); Continue; end;
        RaiseLastOSError(Error);
      end;
      Archives.Add(I);
    end;
    if Loose.Count>0 then
      CheckLinkedLooseReferences(User,Books,function:Boolean begin Result:=Stopping; end);
    if Archives.Count>0 then
    begin
      Preparation:=TBookDeletionPreparation.Create(FBinding.Slice(Archives.ToArray));
      try
        Preparation.Start;
        repeat
          if Stopping then Preparation.RequestStop;
          Progress:=Preparation.Status;
          if Progress.Stage<>'' then Report(Progress.Stage,Progress.Archive,0,Progress.ArchiveCount);
          if not Progress.Finished then Sleep(25);
        until Progress.Finished;
        Preparation.WaitFor;
        if Assigned(Preparation.FatalException) then
          raise EInvalidOperation.Create(Exception(Preparation.FatalException).Message);
        if Progress.RequiredComponent<>'' then
        begin
          TMonitor.Enter(FLock);
          try FState.RequiredComponent:=Progress.RequiredComponent; finally TMonitor.Exit(FLock); end;
        end;
        if Progress.Error<>'' then raise EReadError.Create(Progress.Error);
        if Progress.Cancelled or Stopping then Exit;
        Tasks:=Preparation.PreparedTasks;
      finally Preparation.Free; end;

      Report('Проверка других записей в этих архивах','',0,Length(Tasks));
      CheckArchiveDeletionReferences(User,Tasks,function:Boolean begin Result:=Stopping; end);
      Review:=nil;
      if FReviewArchives then
      begin
        FReviewFiles:=[FUserFile];
        var Collections:=User.GetCollectionInfoIterator;
        while Collections.Next(Info) do FReviewFiles:=FReviewFiles+[Info.DBFileName];
        Review:=WaitForArchiveConfirmation;
      end;
      for var I:=0 to High(Tasks) do
      begin
        if Stopping then Exit;
        TBookDeletionBinding.Parse(Tasks[I].CatalogueBinding).CheckBeforePhysicalRemoval(User);
        Report('Проверка архива',Tasks[I].Archive,I+1,Length(Tasks));
        Queue:=TArchiveDeletionQueue.Create([Tasks[I]],FJournalRoot,True,Review);
        try
          if Stopping then Queue.StopAfterCurrentArchive;
          RunQueue(Queue,User,I,Length(Tasks));
        finally Queue.Free; end;
      end;
    end;
    for var I in Absent do
    begin
      if Stopping then Exit;
      var Binding:=FBinding.Slice([I]);
      Binding.CheckBeforePhysicalRemoval(User);
      if GetFileAttributes(PChar(DeletionNativePath(Books[I].GetBookFileName)))<>INVALID_FILE_ATTRIBUTES then
        raise EInOutError.Create('Архив появился во время удаления. Повторите выбор книг.');
      var Error:=GetLastError;
      if not (Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Error);
      CompleteBinding(Binding,User);
    end;
    for var I in Loose do
    begin
      if Stopping then Exit;
      var Binding:=FBinding.Slice([I]);
      Report('Удаление отдельных файлов',Books[I].GetBookFileName,0,0);
      Binding.CheckBeforePhysicalRemoval(User);
      // Preserve the existing loose-file contract: a failed catalogue
      // delete must never remove a source that still belongs to that row.
      if Binding.RemoveRecords then
      begin CompleteBinding(Binding,User); DeleteLooseBook(Books[I]); end
      else begin DeleteLooseBook(Books[I]); CompleteBinding(Binding,User); end;
    end;
    if (Linked.Count>0) and not Stopping then
    begin
      Report('Удаление ссылок из коллекции','',0,0);
      CompleteBinding(FBinding.Slice(Linked.ToArray),User);
    end;
  finally Linked.Free; Absent.Free; Loose.Free; Archives.Free; end;
end;

function OrdinaryDirectory(const Path:string):Boolean;
begin
  var Attr:=GetFileAttributes(PChar(DeletionNativePath(Path)));
  Result:=(Attr<>INVALID_FILE_ATTRIBUTES) and (Attr and FILE_ATTRIBUTE_DIRECTORY<>0) and
    (Attr and FILE_ATTRIBUTE_REPARSE_POINT=0);
end;

function HasArchiveDeletionJournals(const JournalRoot:string):Boolean;
var Search:TSearchRec;
begin
  Result:=False;
  if not OrdinaryDirectory(JournalRoot) or
    (System.SysUtils.FindFirst(TPath.Combine(JournalRoot,'archive-delete-*'),faDirectory,Search)<>0) then Exit;
  try
    repeat
      if (Search.Attr and faDirectory<>0) and OrdinaryDirectory(TPath.Combine(JournalRoot,Search.Name)) then
        Exit(True);
    until System.SysUtils.FindNext(Search)<>0;
  finally System.SysUtils.FindClose(Search); end;
end;

procedure TBookDeletionOperation.RunRecovery(const User:ISystemData);
var Jobs:TList<string>; Queue:TArchiveDeletionQueue;
begin
  if not DirectoryExists(FJournalRoot) then Exit;
  if not OrdinaryDirectory(FJournalRoot) then
    raise EReadError.Create('Папка журналов удаления недоступна или является ссылкой.');
  Report('Поиск незавершённых удалений','',0,0);
  Jobs:=TList<string>.Create;
  try
    for var OperationDir in TDirectory.GetDirectories(FJournalRoot,'archive-delete-*') do
    begin
      if Stopping then Exit;
      if not OrdinaryDirectory(OperationDir) then Continue;
      for var TaskDir in TDirectory.GetDirectories(OperationDir,'archive-*') do
        if OrdinaryDirectory(TaskDir) and
          (Length(TDirectory.GetDirectories(TaskDir,'zip-delete-*'))>0) then
        begin
          if Jobs.Count>=10000 then raise EReadError.Create('Слишком много незавершённых удалений.');
          Jobs.Add(TaskDir);
        end;
    end;
    if Stopping or (Jobs.Count=0) then Exit;
    Report('Проверка журналов удаления','',0,Jobs.Count);
    TMonitor.Enter(FLock);
    try FState.PendingJournal:=FJournalRoot; finally TMonitor.Exit(FLock); end;
    Queue:=TArchiveDeletionQueue.Recover(Jobs.ToArray,True);
    try
      if Stopping then Queue.StopAfterCurrentArchive;
      RunQueue(Queue,User,0,Jobs.Count);
    finally Queue.Free; end;
    if not Stopping then
    begin
      TMonitor.Enter(FLock);
      try FState.PendingJournal:=''; finally TMonitor.Exit(FLock); end;
    end;
  finally Jobs.Free; end;
end;

procedure TBookDeletionOperation.Execute;
var User:ISystemData;
begin
  try
    try
      if Stopping then Exit;
      if not FileExists(FUserFile) then raise EReadError.Create('База коллекций не найдена.');
      User:=TSystemData_SQLite.Create(FUserFile);
      if FRecovery then RunRecovery(User)
      else if Length(FBatch)>0 then RunBatch(User)
      else RunRemoval(User);
    except
      on E:EAbort do RequestStop;
      on E:Exception do
      begin
        TMonitor.Enter(FLock);
        try
          FState.Error:=E.Message;
          if E is EMHLComponentRequired then FState.RequiredComponent:=EMHLComponentRequired(E).ComponentID;
        finally TMonitor.Exit(FLock); end;
      end;
    end;
  finally
    if Assigned(User) then User.ClearCollectionCache;
    User:=nil;
    // Remove only our empty journal root. Failed or interrupted jobs stay.
    if OrdinaryDirectory(FJournalRoot) then
      RemoveDirectory(PChar(DeletionNativePath(FJournalRoot)));
    TMonitor.Enter(FLock);
    try FState.Finished:=True; finally TMonitor.Exit(FLock); end;
  end;
end;

end.
