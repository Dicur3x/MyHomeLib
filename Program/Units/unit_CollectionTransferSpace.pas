unit unit_CollectionTransferSpace;

interface

uses System.SysUtils, unit_CollectionTransferJournal;

type
  TTransferVolumeBudget=record
    Volume,Key:string;
    Free,Books,Working,Caches,Catalogues,Reserve:Int64;
    function Required:Int64;
  end;

// Conservative additional-space budget. It never credits future source deletion
// or filesystem compression and does not replace the live per-write guards.
function EstimateTransferSpace(Preview:TCollectionTransferJournal; const DataRoot:string;
  const Check:TProc=nil):TArray<TTransferVolumeBudget>;
function TransferSpaceText(const Rows:TArray<TTransferVolumeBudget>):TArray<string>;

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.JSON, System.Math, System.Generics.Collections,
  SQLiteWrap, unit_Consts, unit_BookCompressionPlanStore, unit_CollectionTransferPlan,
  unit_CollectionTransferCopy, unit_CollectionTransferCacheSettings, unit_ZipMemberDeletion,
  unit_BookEstimateReport;

const MB=Int64(1024)*1024;

function AddBytes(A,B:Int64):Int64;
begin
  if (A<0) or (B<0) or (A>High(Int64)-B) then raise EReadError.Create('Размер плана места слишком велик.');
  Result:=A+B;
end;

function TTransferVolumeBudget.Required:Int64;
begin Result:=AddBytes(AddBytes(AddBytes(Books,Working),AddBytes(Caches,Catalogues)),Reserve); end;

function ExistingDirectory(const Path:string):string;
begin
  Result:=ExpandFileName(Path);
  while not DirectoryExists(DeletionNativePath(Result)) do
  begin
    var Parent:=ExtractFileDir(Result);
    if (Parent='') or SameFileName(Parent,Result) then raise EDirectoryNotFoundException.Create('Недоступна папка оценки места: '+Path);
    Result:=Parent;
  end;
  Result:=TransferCanonicalDirectory(Result);
end;

function VolumeBudget(const Path:string):TTransferVolumeBudget;
begin
  Result:=Default(TTransferVolumeBudget); var Folder:=ExistingDirectory(Path);
  var Mount,Name:TArray<Char>; SetLength(Mount,32768); SetLength(Name,32768);
  if not GetVolumePathName(PChar(DeletionNativePath(Folder)),PChar(Mount),Length(Mount)) then RaiseLastOSError;
  Result.Volume:=PChar(Mount);
  if Result.Volume.StartsWith('\\?\UNC\',True) then Result.Volume:='\\'+Copy(Result.Volume,9,MaxInt)
  else if Result.Volume.StartsWith('\\?\',True) then Delete(Result.Volume,1,4);
  if GetVolumeNameForVolumeMountPoint(PChar(Mount),PChar(Name),Length(Name)) then Result.Key:=LowerCase(PChar(Name))
  else Result.Key:=LowerCase(Result.Volume);
  var Available,Capacity:UInt64;
  if not GetDiskFreeSpaceEx(PChar(DeletionNativePath(Folder)),Available,Capacity,nil) then RaiseLastOSError;
  Result.Free:=Int64(Min(Available,UInt64(High(Int64)))); Result.Reserve:=512*MB;
end;

function DatabaseBytes(DB:TSQLiteDatabase):Int64;
begin
  var Pages:=DB.QuerySingleInt('PRAGMA page_count'); var Size:=DB.QuerySingleInt('PRAGMA page_size');
  if (Pages<0) or (Size<=0) or (Pages>High(Int64) div Size) then raise EReadError.Create('Не прочитан размер базы для оценки места.');
  Result:=Pages*Size;
end;

function EstimateTransferSpace(Preview:TCollectionTransferJournal; const DataRoot:string;
  const Check:TProc):TArray<TTransferVolumeBudget>;
var Rows:TList<TTransferVolumeBudget>; Databases:TObjectDictionary<string,TSQLiteDatabase>;
    Probes:TDictionary<string,TTransferVolumeBudget>;
    Store:TCompressionPlanStore; Model:TTransferCacheSettingsPlan; Q:TSQLiteQuery;
  procedure Stop;
  begin if Assigned(Check) then Check; end;
  procedure Add(const Path:string; Books,Working,Caches,Catalogues,Reserve:Int64);
  begin
    Stop; var ProbeKey:=LowerCase(ExpandFileName(Path)); var Row:TTransferVolumeBudget;
    if not Probes.TryGetValue(ProbeKey,Row) then begin Row:=VolumeBudget(Path); Probes.Add(ProbeKey,Row); end;
    var Index:=-1;
    for var I:=0 to Rows.Count-1 do if Rows[I].Key=Row.Key then begin Index:=I; Break; end;
    if Index>=0 then begin var Current:=Rows[Index]; Current.Free:=Min(Current.Free,Row.Free); Row:=Current; end;
    Row.Books:=AddBytes(Row.Books,Books); Row.Working:=AddBytes(Row.Working,Working);
    Row.Caches:=AddBytes(Row.Caches,Caches); Row.Catalogues:=AddBytes(Row.Catalogues,Catalogues);
    Row.Reserve:=Max(Row.Reserve,Reserve); Row.Required;
    if Index<0 then Rows.Add(Row) else Rows[Index]:=Row;
  end;
  function Meta(const Name:string):string;
  begin Result:=Preview.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=?',[Name]); end;
begin
  if (Preview=nil) or not Preview.IsPreview then raise EArgumentException.Create('Для оценки нужен отдельный план просмотра.');
  Rows:=TList<TTransferVolumeBudget>.Create; Databases:=TObjectDictionary<string,TSQLiteDatabase>.Create([doOwnsValues]);
  Probes:=TDictionary<string,TTransferVolumeBudget>.Create;
  Store:=nil; Model:=nil; Q:=nil;
  try
    var SystemRoot:=TPath.GetPathRoot(GetEnvironmentVariable('SystemRoot'));
    Add(SystemRoot,0,0,0,0,8192*MB);
    var Work:=Meta('work_root'); var Destination:=Meta('destination');
    Add(Destination,0,0,0,0,512*MB); Add(DataRoot,0,0,0,0,512*MB);
    // Indexed review/state/proof and temporary projection headroom, in addition
    // to actual cache and shared-catalogue snapshots counted below.
    var ReviewRows:=Preview.Review.QuerySingleInt('SELECT count(*) FROM Bindings')+
      Preview.Review.QuerySingleInt('SELECT count(*) FROM RegisteredReferences');
    if (ReviewRows<0) or (ReviewRows>High(Int64) div 1024) then raise EReadError.Create('Слишком большой план метаданных.');
    var ReviewBytes:=TFile.GetSize(DeletionNativePath(TPath.Combine(Preview.Directory,'review.sqlite')));
    Add(Work,0,AddBytes(AddBytes(64*MB,ReviewRows*1024),AddBytes(ReviewBytes,ReviewBytes)),0,0,512*MB);
    Q:=Preview.Review.NewQuery('SELECT Source,Destination,Identity FROM Files WHERE KeepInPlace=0');
    var BookBytes:Int64:=0;
    Q.Open; while not Q.Eof do
    begin Stop; BookBytes:=AddBytes(BookBytes,TransferSourceBytes(Q.FieldAsString(0),Q.FieldAsString(2))); Q.Next; end;
    FreeAndNil(Q);
    // Every copied payload is beneath the new operation directory in this one
    // reviewed destination. No per-file volume probing of absent subfolders.
    Add(Destination,BookBytes,0,0,0,512*MB);
    Store:=TCompressionPlanStore.Create(Preview.Directory); Store.DB.ExecSQL('BEGIN');
    Model:=TTransferCacheSettingsPlan.Create(Preview.Review,Store.DB,
      procedure begin if Assigned(Check) then Check; end);
    Q:=Preview.Review.NewQuery('SELECT RegistrationID,CatalogueKey,Catalogue,SourcesJSON FROM ReferenceRegistrations WHERE State=''ready'' ORDER BY RegistrationID');
    Q.Open; while not Q.Eof do
    begin
      Stop; var Key:=Q.FieldAsString(1); var DB:TSQLiteDatabase;
      if not Databases.TryGetValue(Key,DB) then
      begin
        DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Q.FieldAsString(2))); Databases.Add(Key,DB);
        DB.ExecSQL('BEGIN'); var Size:=DatabaseBytes(DB);
        Add(Q.FieldAsString(2),0,0,0,AddBytes(Size,Size),512*MB);
      end;
      var MoveRoots:=Q.FieldAsInt(0)=StrToInt(Meta('collection'));
      Model.ProjectSources(Q.FieldAsString(3),MoveRoots);
      Model.ProjectHistory(DB.QuerySingleString('SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_LIBRARY_UPDATE_HISTORY]),MoveRoots);
      Q.Next;
    end;
    FreeAndNil(Q);
    var Personal:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Meta('personal')));
    try var Size:=DatabaseBytes(Personal); Add(Meta('personal'),0,0,0,AddBytes(Size,Size),512*MB); finally Personal.Free; end;
    Q:=Preview.Review.NewQuery('SELECT Bytes FROM ForkSources'); Q.Open;
    while not Q.Eof do begin Add(Work,0,Q.FieldAsInt(0),0,0,512*MB); Q.Next; end; FreeAndNil(Q);
    Q:=Preview.Review.NewQuery('SELECT f.Destination,s.Bytes FROM CatalogueForks f JOIN ForkSources s ON s.ID=f.SourceID'); Q.Open;
    while not Q.Eof do begin var Size:=Q.FieldAsInt(1); Add(Q.FieldAsString(0),0,0,0,AddBytes(Size,Size),512*MB); Q.Next; end; FreeAndNil(Q);
    var Jobs:=Model.Jobs; var Inputs:=Model.Inputs;
    try
      for var Value in Jobs do
      begin
        Stop; var Job:=TJSONObject(Value); var CachePath:=Job.GetValue<string>('before_file'); var DB:TSQLiteDatabase:=nil;
        try
          try
            DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(CachePath));
            var Size:=DatabaseBytes(DB); Add(Work,0,AddBytes(AddBytes(Size,Size),Size),0,0,512*MB);
            Add(DataRoot,0,0,AddBytes(Size,Size),0,512*MB);
          except
            on E:EAbort do raise;
            on E:Exception do raise EReadError.Create('Не удалось оценить сохранённый кэш '+CachePath+': '+E.Message);
          end;
        finally DB.Free; end;
      end;
      for var Value in Inputs do
      begin
        Stop; var Size:=TFile.GetSize(DeletionNativePath(TJSONObject(Value).GetValue<string>('source_file')));
        Add(Work,0,Size,0,0,512*MB); Add(DataRoot,0,0,Size,0,512*MB);
      end;
    finally Jobs.Free; Inputs.Free; end;
    Store.DB.Rollback; Result:=Rows.ToArray;
  finally
    Q.Free; Model.Free; Store.Free; Databases.Free; Rows.Free; Probes.Free;
  end;
end;

function TransferSpaceText(const Rows:TArray<TTransferVolumeBudget>):TArray<string>;
begin
  var Lines:=TList<string>.Create;
  try
    Lines.Add('Место по дискам: консервативный плановый запас, включая временные данные.');
    Lines.Add('Освобождение прежних файлов не вычитается. Сжатие файловой системы и будущие изменения не предсказываются.');
    for var Row in Rows do
    begin
      Lines.Add(Row.Volume+' — свободно '+BookEstimateSizeText(Row.Free)+'; плановый запас с резервом ≈ '+BookEstimateSizeText(Row.Required)+'.');
      Lines.Add('  Книги: '+BookEstimateSizeText(Row.Books)+'; рабочие данные: ≈ '+BookEstimateSizeText(Row.Working)+
        '; новый кэш: ≈ '+BookEstimateSizeText(Row.Caches)+'; обработка каталогов: ≈ '+BookEstimateSizeText(Row.Catalogues)+
        '; сохраняемый резерв: '+BookEstimateSizeText(Row.Reserve)+'.');
      if Row.Required>Row.Free then Lines.Add('  Плановый запас превышает свободное место. Выберите другую папку или освободите место перед переносом.');
    end;
    Lines.Add('Оценка не резервирует место. Во время работы свободное место проверяется повторно; при нехватке перенос остановится безопасно.');
    Result:=Lines.ToArray;
  finally Lines.Free; end;
end;

end.
