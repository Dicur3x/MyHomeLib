unit unit_BookDeletionPreparation;

interface

uses System.Classes, System.SysUtils, unit_BookDeletionBinding, unit_ArchiveDeletionQueue;

type
  TBookDeletionPreparationStatus = record
    Archive, Stage, Error, RequiredComponent: string;
    BookIndex, BookCount, ArchiveCount: Integer;
    Finished, Cancelled: Boolean;
  end;

  // Only immutable source snapshots cross this thread boundary. No database
  // connection or UI component is used by the preparation worker.
  TBookDeletionPreparation = class(TThread)
  private
    FBinding: TBookDeletionBinding;
    FLock: TObject;
    FStop: Integer;
    FState: TBookDeletionPreparationStatus;
    FTasks: TArray<TArchiveDeletionTask>;
    function Cancelled: Boolean;
    procedure Report(const Stage, Archive: string; Index, ArchiveCount: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(const Binding: TBookDeletionBinding);
    destructor Destroy; override;
    procedure RequestStop;
    function Status: TBookDeletionPreparationStatus;
    function PreparedTasks: TArray<TArchiveDeletionTask>;
  end;

implementation

uses System.SyncObjs, System.IOUtils, System.StrUtils, System.Generics.Collections, unit_Globals,
  unit_BookDeletionMembers, unit_BookDeletionInventory, unit_ZipMemberDeletion,
  unit_MHLExternalTools, unit_FLibraryCompat, unit_MHLArchiveHelpers;

type
  TArchiveBookGroup = class
    Archive, Identity: string;
    Rows: TList<Integer>;
    WholeSource: Boolean;
    constructor Create(const FileName, SourceIdentity: string);
    destructor Destroy; override;
  end;

constructor TArchiveBookGroup.Create(const FileName,SourceIdentity:string);
begin
  inherited Create; Archive:=FileName; Identity:=SourceIdentity; Rows:=TList<Integer>.Create;
end;

destructor TArchiveBookGroup.Destroy;
begin Rows.Free; inherited; end;

constructor TBookDeletionPreparation.Create(const Binding:TBookDeletionBinding);
begin
  inherited Create(True); FreeOnTerminate:=False; FLock:=TObject.Create;
  // The binding exposes copies of its arrays. Serialize only each archive's
  // slice so an operation spanning many archives has no single-receipt cap.
  FBinding:=Binding;
  FState.BookCount:=Length(FBinding.ExpectedBooks); Priority:=tpLower;
end;

destructor TBookDeletionPreparation.Destroy;
begin RequestStop; inherited; FLock.Free; end;

function TBookDeletionPreparation.Cancelled:Boolean;
begin Result:=TInterlocked.CompareExchange(FStop,0,0)<>0; end;

procedure TBookDeletionPreparation.RequestStop;
begin TInterlocked.Exchange(FStop,1); end;

procedure TBookDeletionPreparation.Report(const Stage,Archive:string; Index,ArchiveCount:Integer);
begin
  TMonitor.Enter(FLock);
  try FState.Stage:=Stage; FState.Archive:=Archive; FState.BookIndex:=Index; FState.ArchiveCount:=ArchiveCount;
  finally TMonitor.Exit(FLock); end;
end;

function TBookDeletionPreparation.Status:TBookDeletionPreparationStatus;
begin TMonitor.Enter(FLock); try Result:=FState; finally TMonitor.Exit(FLock); end; end;

function TBookDeletionPreparation.PreparedTasks:TArray<TArchiveDeletionTask>;
begin
  TMonitor.Enter(FLock);
  try
    if not FState.Finished or FState.Cancelled or (FState.Error<>'') then
      raise EInvalidOperation.Create('Подготовка удаления не завершена.');
    Result:=Copy(FTasks);
  finally TMonitor.Exit(FLock); end;
end;

function SafePicturePath(const Name:string):Boolean;
begin
  if (Name='') or (Length(Name)>1024) then Exit(False);
  for var Ch in Name do
    if (Ch<' ') or CharInSet(Ch,['*','?','[',']',':']) then Exit(False);
  for var Part in Name.Split(['/']) do
    if (Part='') or (Part='.') or (Part='..') then Exit(False);
  Result:=True;
end;

function CollectPictureStems(const Name:string; const Stems:TDictionary<string,Byte>):Boolean;
begin
  var Normalized:=LowerCase(Name.Replace('\','/'));
  var Separator:=LastDelimiter('/',Normalized);
  var Leaf:=ChangeFileExt(Copy(Normalized,Separator+1,MaxInt),'');
  var FullStem:=Copy(Normalized,1,Separator)+Leaf;
  var ReaderStem:=LowerCase(ChangeFileExt(ExtractFileName(Name),'').Replace('\','/'));
  Result:=SafePicturePath(FullStem) and SafePicturePath(Leaf) and SafePicturePath(ReaderStem);
  if not Result then Exit;
  // Readers receive both archive member paths and names from catalogue rows.
  // Account for the flat name and either path separator used by old indexes.
  Stems.AddOrSetValue(FullStem,0); Stems.AddOrSetValue(Leaf,0);
  Stems.AddOrSetValue(ReaderStem,0);
end;

function OwnsPicture(const Name:string; Cover:Boolean;
  const Eligible,Retained:TDictionary<string,Byte>):Boolean;
begin
  Result:=False;
  if not SafePicturePath(Name) then Exit;
  if Cover then Exit(Eligible.ContainsKey(Name) and not Retained.ContainsKey(Name));
  for var I:=1 to Length(Name) do
    if Name[I]='/' then
    begin
      var Stem:=Copy(Name,1,I-1);
      if Retained.ContainsKey(Stem) then Exit(False);
      if Eligible.ContainsKey(Stem) then Result:=True;
    end;
end;

procedure PlanPictureRemoval(var Task:TArchiveDeletionTask; const Inventory:TArray<string>;
  const Selected:TDictionary<string,Byte>; const Cancel:TFunc<Boolean>);
var Eligible,Retained:TDictionary<string,Byte>; Paths:TArray<string>;
  ExactNames:TDictionary<string,Byte>; Names:TList<string>;
begin
  if not IsSevenZipArchive(Task.Archive) then Exit;
  Paths:=FLibraryImageSourceFiles(Task.Archive);
  if (Paths[0]='') and (Paths[1]='') then Exit;
  Eligible:=TDictionary<string,Byte>.Create;
  Retained:=TDictionary<string,Byte>.Create;
  ExactNames:=TDictionary<string,Byte>.Create;
  Names:=TList<string>.Create;
  try
    for var Member in Task.Members do
      if MatchText(ExtractFileExt(Member),['.fb2','.epub']) then
        CollectPictureStems(Member,Eligible);
    if Eligible.Count=0 then Exit;
    for var Member in Inventory do
      if not Selected.ContainsKey(Member.Replace('\','/')) and
        not Member.EndsWith('/') and not Member.EndsWith('\') then
      begin
        // The reader accepts masks and ignores case for image lookup. An
        // unusual live stem can match more than its literal filename.
        if not CollectPictureStems(Member,Retained) then Exit;
      end;
    for var I:=0 to High(Paths) do
    begin
      if Cancel() then Abort;
      if (Paths[I]='') or not IsPrivateArchiveDeletionSource(Paths[I]) then Continue;
      try
        var Entry:TArchiveDeletionCompanion;
        Entry.Archive:=ExpandFileName(Paths[I]);
        Entry.SourceIdentity:=ArchiveDeletionSourceIdentity(Entry.Archive);
        ExactNames.Clear; Names.Clear;
        for var Member in ReadBookDeletionInventory(Entry.Archive,Entry.SourceIdentity,Cancel) do
        begin
          var Key:=LowerCase(Member.Replace('\','/'));
          if not OwnsPicture(Key,I=0,Eligible,Retained) then Continue;
          if ExactNames.ContainsKey(Key) then
          begin Names.Clear; Break; end;
          ExactNames.Add(Key,0); Names.Add(Member);
        end;
        if Names.Count>0 then
        begin Entry.Members:=Names.ToArray; Task.Companions:=Task.Companions+[Entry]; end;
      except
        on E:EAbort do raise;
        // An unavailable optional image archive cannot authorize deletion.
        on E:Exception do Continue;
      end;
    end;
  finally Names.Free; ExactNames.Free; Retained.Free; Eligible.Free; end;
end;

procedure TBookDeletionPreparation.Execute;
var Groups:TObjectList<TArchiveBookGroup>; Lookup:TDictionary<string,Integer>;
  Members:TList<string>; Selected:TDictionary<string,Byte>; Index,Done:Integer;
  Tasks:TArray<TArchiveDeletionTask>;
begin
  Groups:=TObjectList<TArchiveBookGroup>.Create(True); Lookup:=TDictionary<string,Integer>.Create;
  Members:=TList<string>.Create; Selected:=TDictionary<string,Byte>.Create;
  try
    try
      var Books:=FBinding.ExpectedBooks;
      for var I:=0 to High(Books) do
      begin
        if Cancelled then Abort;
        Report('Проверка путей выбранных книг','',I,Groups.Count);
        var Book:=Books[I];
        var IsMember:=Book.GetBookFormat(TPath.Combine(Book.CollectionRoot,Book.Folder)) in
          [bfFb2Archive,bfRawArchive,bfFbd];
        // Individual linked-copy files use the same durable whole-file
        // receipt as single-book archives.
        var WholeSource:=IsWholeBookArchive(Book) or (FBinding.RemovesCopies and not IsMember);
        if not WholeSource and not IsMember then
          raise EArgumentException.Create('В очередь архивов передана отдельная книга.');
        var Archive:=TPath.GetFullPath(Book.GetBookFileName);
        var Identity:=ArchiveDeletionSourceIdentity(Archive);
        var Key:=Copy(Identity,1,25);
        if not Lookup.TryGetValue(Key,Index) then
        begin
          if Groups.Count>=10000 then raise EArgumentException.Create('Выбрано слишком много разных архивов.');
          Index:=Groups.Add(TArchiveBookGroup.Create(Archive,Identity)); Lookup.Add(Key,Index);
        end
        else if Groups[Index].Identity<>Identity then
          raise EReadError.Create('Архив изменился во время подготовки. Удаление не начато.');
        Groups[Index].Rows.Add(I);
        Groups[Index].WholeSource:=Groups[Index].WholeSource or WholeSource;
      end;
      SetLength(Tasks,Groups.Count); Done:=0;
      for var I:=0 to Groups.Count-1 do
      begin
        if Cancelled then Abort;
        var Group:=Groups[I]; Members.Clear; Selected.Clear;
        Tasks[I].Archive:=Group.Archive; Tasks[I].SourceIdentity:=Group.Identity;
        Tasks[I].CatalogueBinding:=FBinding.Slice(Group.Rows.ToArray).ToJSON;
        if Group.WholeSource then
        begin
          Tasks[I].WholeSource:=True;
          Inc(Done,Group.Rows.Count);
          Continue;
        end;
        Report('Чтение списка файлов архива',Group.Archive,Done,Groups.Count);
        // Inventories are loaded one archive at a time, even if selected books
        // came in a mixed order. No whole-library filename cache is retained.
        var Inventory:=ReadBookDeletionInventory(Group.Archive,Group.Identity,
          function:Boolean begin Result:=Cancelled; end);
        for var Row in Group.Rows do
        begin
          if Cancelled then Abort;
          for var Member in ExactBookDeletionMembers(Books[Row],Inventory) do
          begin
            var Normal:=Member.Replace('\','/');
            if not Selected.ContainsKey(Normal) then
            begin Selected.Add(Normal,0); Members.Add(Member); end;
          end;
          Inc(Done);
        end;
        Tasks[I].Members:=Members.ToArray;
        PlanPictureRemoval(Tasks[I],Inventory,Selected,function:Boolean begin Result:=Cancelled; end);
        Inventory:=nil;
      end;
      if Cancelled then Abort;
      TMonitor.Enter(FLock);
      try FTasks:=Tasks; finally TMonitor.Exit(FLock); end;
      Report('Подготовка завершена','',Done,Groups.Count);
    except
      on E:EAbort do
      begin TMonitor.Enter(FLock); try FState.Cancelled:=True; finally TMonitor.Exit(FLock); end; end;
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
    Selected.Free; Members.Free; Lookup.Free; Groups.Free;
    TMonitor.Enter(FLock);
    try FState.Finished:=True; finally TMonitor.Exit(FLock); end;
  end;
end;

end.
