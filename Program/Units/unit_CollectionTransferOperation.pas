unit unit_CollectionTransferOperation;

interface

uses System.SysUtils, unit_CollectionTransferJournal, unit_CollectionTransferRegistry;

type
  TTransferOperationResult=record
    GroupsDone,GroupsTotal,FilesVerified:Int64;
    Originals:TTransferRemovalResult;
    RootsApplied:Boolean;
    CachesPrepared:Int64;
    CacheDatabasesPublished:Int64;
  end;
  TTransferOperationProgress=reference to procedure(const Stage,Source:string;
    GroupsDone,GroupsTotal,Done,Total:Int64);

  // Sequential available-file phase. The caller retains the journal and must
  // coordinate live DAO/jobs and finalize roots before declaring completion.
  TCollectionTransferOperation=class
  private
    FJournal:TCollectionTransferJournal;
    FCancelled:TFunc<Boolean>;
    FProgress:TTransferOperationProgress;
    FResult:TTransferOperationResult;
    function CheckStop:Boolean;
    procedure Notify(const Stage,Source:string; Done,Total:Int64);
  public
    constructor Create(Journal:TCollectionTransferJournal);
    function Run(const Cancelled:TFunc<Boolean> = nil;
      const Progress:TTransferOperationProgress = nil; FinalizeRoots:Boolean=False;
      PrepareCaches:Boolean=False; PublishCaches:Boolean=False):TTransferOperationResult;
  end;

implementation

uses System.Classes;

constructor TCollectionTransferOperation.Create(Journal:TCollectionTransferJournal);
begin
  inherited Create;
  if Journal=nil then raise EArgumentException.Create('Не указан журнал переноса коллекции.');
  FJournal:=Journal;
end;

function TCollectionTransferOperation.CheckStop:Boolean;
begin
  Result:=False;
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Перенос остановлен. Готовые копии и журнал сохранены для продолжения.');
end;

procedure TCollectionTransferOperation.Notify(const Stage,Source:string; Done,Total:Int64);
begin
  if Assigned(FProgress) then FProgress(Stage,Source,FResult.GroupsDone,FResult.GroupsTotal,Done,Total);
end;

function TCollectionTransferOperation.Run(const Cancelled:TFunc<Boolean>;
  const Progress:TTransferOperationProgress; FinalizeRoots,PrepareCaches,PublishCaches:Boolean):TTransferOperationResult;
var Registry:TCollectionTransferRegistry;
begin
  FCancelled:=Cancelled; FProgress:=Progress; Registry:=nil;
  FResult:=Default(TTransferOperationResult); FResult.GroupsTotal:=FJournal.GroupCount;
  try
    CheckStop; Registry:=TCollectionTransferRegistry.Create(FJournal);
    Registry.RegisterOperation(CheckStop);
    if FJournal.HasRootFinalization then
    begin
      if PublishCaches or FJournal.HasCachePublication then
      begin FResult.CacheDatabasesPublished:=FJournal.PublishSourceCacheSettings(CheckStop); FResult.RootsApplied:=True; end
      else
      begin
        FResult.RootsApplied:=FJournal.FinalizeRoots(CheckStop);
        if PrepareCaches or FJournal.HasCachePreparation then FResult.CachesPrepared:=FJournal.PrepareSourceCaches(CheckStop);
      end;
      FResult.GroupsDone:=FResult.GroupsTotal; FResult.FilesVerified:=FJournal.FileCount; Result:=FResult;
      Notify('Итоговые пути сохранены; требуется завершение переноса','',FResult.GroupsDone,FResult.GroupsTotal); Exit;
    end;
    Notify('Подготовка каталогов','',0,FResult.GroupsTotal);
    FJournal.PublishCatalogueForks(CheckStop);
    if PrepareCaches or PublishCaches or FJournal.HasCachePreparation then
    begin
      Notify('Подготовка сохранённых источников','',0,0);
      FResult.CachesPrepared:=FJournal.PrepareSourceCaches(CheckStop);
    end;
    FJournal.ForEachGroup(
      procedure(const Group:TTransferJournalGroup)
      var Prepared:TPreparedTransferGroup;
      begin
        CheckStop; Prepared:=nil;
        Notify('Перенос файлов','',0,Group.Files);
        try
          if Registry.HasPublishedGroup(Group.ID) then
          begin
            Prepared:=Registry.RecoverGroup(Group.ID,CheckStop);
            Registry.ReconcilePublishedGroup(Prepared,CheckStop);
          end
          else
          begin
            Prepared:=FJournal.PrepareGroup(Group.ID,CheckStop,
              procedure(const Stage,Source:string; Done,Total:Int64) begin Notify(Stage,Source,Done,Total); end);
            Registry.PublishPreparedGroup(Prepared,CheckStop);
          end;
          Notify('Освобождение исходников','',0,Group.Files);
          var Removed:=Registry.RemovePublishedGroup(Prepared,CheckStop,
            procedure(const Stage,Source:string; Done,Total:Int64) begin Notify(Stage,Source,Done,Total); end);
          Inc(FResult.Originals.Removed,Removed.Removed); Inc(FResult.Originals.Missing,Removed.Missing);
          Inc(FResult.Originals.Retained,Removed.Retained); Inc(FResult.Originals.Pending,Removed.Pending);
          Inc(FResult.FilesVerified,Prepared.Count); Inc(FResult.GroupsDone);
          Notify('Группа перенесена','',Group.Files,Group.Files);
        finally Prepared.Free; end;
      end);
    if FResult.Originals.Pending>0 then
    begin
      // A reader may keep a deleted file alive. Final roots would select the
      // metadata-only resume path and bypass this unfinished unlink phase.
      Result:=FResult;
      Notify('Освобождение исходных файлов отложено; перенос можно продолжить позже.','',
        FResult.Originals.Pending,0);
      Exit;
    end;
    if PublishCaches then
    begin FResult.CacheDatabasesPublished:=FJournal.PublishSourceCacheSettings(CheckStop); FResult.RootsApplied:=True; end
    else if FinalizeRoots then FResult.RootsApplied:=FJournal.FinalizeRoots(CheckStop);
    Result:=FResult;
    if FResult.RootsApplied then Notify('Итоговые пути сохранены; требуется завершение переноса','',FResult.GroupsDone,FResult.GroupsTotal)
    else Notify('Файлы обработаны; требуется завершение настройки путей','',FResult.GroupsDone,FResult.GroupsTotal);
  finally Registry.Free; FCancelled:=nil; FProgress:=nil; end;
end;

end.
