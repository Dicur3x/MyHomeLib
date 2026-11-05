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

uses System.SyncObjs, System.IOUtils, System.Generics.Collections, unit_Globals,
  unit_BookDeletionMembers, unit_BookDeletionInventory, unit_ZipMemberDeletion,
  unit_MHLExternalTools;

type
  TArchiveBookGroup = class
    Archive, Identity: string;
    Rows: TList<Integer>;
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
  // Parse a private validated copy rather than retaining an outward record's
  // managed-array storage. This also bounds a future durable receipt up front.
  FBinding:=TBookDeletionBinding.Parse(Binding.ToJSON);
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
        if not (Book.GetBookFormat(TPath.Combine(Book.CollectionRoot,Book.Folder)) in
          [bfFb2Archive,bfRawArchive,bfFbd]) then
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
      end;
      SetLength(Tasks,Groups.Count); Done:=0;
      for var I:=0 to Groups.Count-1 do
      begin
        if Cancelled then Abort;
        var Group:=Groups[I]; Members.Clear; Selected.Clear;
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
        Inventory:=nil;
        Tasks[I].Archive:=Group.Archive; Tasks[I].SourceIdentity:=Group.Identity;
        Tasks[I].Members:=Members.ToArray;
        Tasks[I].CatalogueBinding:=FBinding.Slice(Group.Rows.ToArray).ToJSON;
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
