unit unit_SeriesAliases;

interface
uses System.Classes, System.Generics.Collections, unit_Interfaces,
  unit_CollectionMerge, unit_CollectionWorkerThread;
type
  TSeriesAliasPair = record OldID, NewID: Integer; OldTitle, NewTitle: string; end;
  TSeriesAliasPlan = class
  private
    FCollection: IBookCollection;
    FSystem: ISystemData;
    FPairs: TList<TSeriesAliasPair>;
    FReport: TStringList;
    FCatalogRevision, FSystemRevision: string;
    FReady: Boolean;
    FQueryCanceled: TMergeCanceled;
    FQueryAborted: Boolean;
    function QueryCanceled: Boolean;
    procedure CheckRevision;
  public
    constructor Create(const Collection: IBookCollection; const SystemData: ISystemData);
    destructor Destroy; override;
    procedure Preview(const Canceled: TMergeCanceled);
    procedure Apply(const BackupFolder: string; const Progress: TMergeStageProgress;
      const Canceled: TMergeCanceled);
    property Report: TStringList read FReport;
    function Count: Integer;
  end;
  TSeriesAliasWorker = class(TCollectionWorker)
  private
    FPlan: TSeriesAliasPlan;
    FApply, FSuccess: Boolean;
    FError, FBackup: string;
    procedure ReportStage(const Stage: string; Current, Total: Integer);
  protected
    procedure WorkFunction; override;
  public
    constructor CreatePreview(CollectionID: Integer);
    constructor CreateApply(Plan: TSeriesAliasPlan; const BackupFolder: string);
    destructor Destroy; override;
    function TakePlan: TSeriesAliasPlan;
    property Success: Boolean read FSuccess;
    property Error: string read FError;
  end;
implementation
uses System.SysUtils, System.IOUtils, System.Variants, Vcl.ComCtrls, SQLiteWrap,
  unit_Settings, unit_Consts, unit_Globals, dm_user;

constructor TSeriesAliasPlan.Create(const Collection: IBookCollection; const SystemData: ISystemData);
begin
  inherited Create; FCollection := Collection; FSystem := SystemData;
  FPairs := TList<TSeriesAliasPair>.Create; FReport := TStringList.Create;
end;
destructor TSeriesAliasPlan.Destroy;
begin FReport.Free; FPairs.Free; inherited; end;
function TSeriesAliasPlan.Count: Integer;
begin Result := FPairs.Count; end;
function TSeriesAliasPlan.QueryCanceled: Boolean;
begin
  Result := Assigned(FQueryCanceled) and FQueryCanceled();
  if Result then FQueryAborted := True;
end;
procedure TSeriesAliasPlan.CheckRevision;
begin
  if (FCollection.GetCatalogRevision <> FCatalogRevision) or
    (FSystem.GetDataRevision <> FSystemRevision) then
    raise Exception.Create('Каталог изменился. Повторите предпросмотр дублей серий.');
end;
procedure TSeriesAliasPlan.Preview(const Canceled: TMergeCanceled);
var DB: TSQLiteDatabase; Query: TSQLiteQuery; Pair: TSeriesAliasPair;
  SavedCancel: TSQLiteCancelCallback;
begin
  FReady := False; FPairs.Clear; FReport.Clear;
  if Assigned(Canceled) and Canceled() then Abort;
  if isOnlineCollection(FCollection.CollectionCode) then
    raise Exception.Create('Объединение серий доступно для локального каталога.');
  FCatalogRevision := FCollection.GetCatalogRevision; FSystemRevision := FSystem.GetDataRevision;
  DB := TSQLiteDatabase.CreateReadOnly(Settings.ExpandCollectionFileName(
    VarToStr(FCollection.GetProperty(PROP_DATAFILE))));
  SavedCancel := SQLiteCancelCallback; FQueryCanceled := Canceled; FQueryAborted := False;
  SQLiteCancelCallback := QueryCanceled;
  try
    // The extended INPX uses [a] / [[a]] for author cycles. Only an exact
    // untagged name with a shared catalog author is a verified alias here.
    // Publisher [p] and mixed [m] labels are deliberately different kinds.
    Query := DB.NewQuery(
      'SELECT tagged.SeriesID, plain.SeriesID, tagged.SeriesTitle, plain.SeriesTitle ' +
      'FROM Series tagged JOIN Series plain ON plain.SeriesTitle = RTRIM(CASE ' +
      'WHEN LOWER(SUBSTR(tagged.SeriesTitle,-5))=''[[a]]'' THEN SUBSTR(tagged.SeriesTitle,1,LENGTH(tagged.SeriesTitle)-5) ' +
      'ELSE SUBSTR(tagged.SeriesTitle,1,LENGTH(tagged.SeriesTitle)-3) END) COLLATE MHL_SYSTEM_NOCASE ' +
      'WHERE (LOWER(SUBSTR(tagged.SeriesTitle,-3))=''[a]'' OR LOWER(SUBSTR(tagged.SeriesTitle,-5))=''[[a]]'') ' +
      'AND EXISTS(SELECT 1 FROM Series_List x JOIN Author_List a ON a.BookID=x.BookID ' +
      'JOIN Author_List b ON b.AuthorID=a.AuthorID JOIN Series_List y ON y.BookID=b.BookID ' +
      'WHERE x.SeriesID=tagged.SeriesID AND y.SeriesID=plain.SeriesID) ORDER BY plain.SeriesTitle');
    try
      try
      Query.Open;
      while not Query.Eof do
      begin
        if Assigned(Canceled) and Canceled() then Abort;
        Pair.OldID := Query.FieldAsInt(0); Pair.NewID := Query.FieldAsInt(1);
        Pair.OldTitle := Query.FieldAsString(2); Pair.NewTitle := Query.FieldAsString(3);
        FPairs.Add(Pair); Query.Next;
      end;
      except
        on E: ESQLiteException do
          if FQueryAborted then Abort else raise;
      end;
    finally Query.Free; end;
  finally
    SQLiteCancelCallback := SavedCancel; FQueryCanceled := nil; DB.Free;
  end;
  if Assigned(Canceled) and Canceled() then Abort;
  FReport.Add(Format('Найдено пар авторских серий: %d.',[Count]));
  FReport.Add('Совпадают название без метки [a] и хотя бы один автор. Издательские [p] и смешанные [m] серии сохраняются отдельно.');
  FReport.Add('Книги обеих серий будут в одном списке. Все файлы, издания, оценки, прогресс чтения и группы сохраняются.');
  FReport.Add('Это объединение названий серий; выбор копий книг задаётся отдельно режимом объединения источников.');
  FReport.Add('Повторное подключение INPX не требуется. Перед применением создаются резервные копии.');
  FReport.Add('');
  for Pair in FPairs do
  begin
    if FReport.Count >= 1006 then Break;
    FReport.Add(Pair.OldTitle+' → '+Pair.NewTitle);
  end;
  if Count > 1000 then FReport.Add('В предпросмотре показаны первые 1000 пар. Полный список будет сохранён вместе с резервной копией.');
  CheckRevision; FReady := True;
end;
procedure TSeriesAliasPlan.Apply(const BackupFolder: string; const Progress: TMergeStageProgress;
  const Canceled: TMergeCanceled);
var DB: TSQLiteDatabase; TargetFile, SystemFile: string; Pair: TSeriesAliasPair;
  I: Integer; TargetCommitted, SystemStarted: Boolean; ReportFile: TStreamWriter;
  procedure CheckCanceled;
  begin if Assigned(Canceled) and Canceled() then Abort; end;
  procedure Backup(const Source, Name, Stage: string);
  begin
    CheckCanceled; DB := TSQLiteDatabase.CreateReadOnly(Source);
    try DB.BackupTo(TPath.Combine(BackupFolder,Name),
      procedure(Current, Total: Integer)
      begin
        if Assigned(Canceled) and Canceled() then Abort;
        if Assigned(Progress) then Progress(Stage,Current,Total);
      end);
    finally DB.Free; end;
  end;
begin
  if not FReady then raise Exception.Create('Сначала выполните предпросмотр дублей серий.');
  CheckRevision; CheckCanceled;
  if DirectoryExists(BackupFolder) then raise Exception.Create('Для резервной копии требуется новая папка.');
  ForceDirectories(BackupFolder);
  TargetFile := Settings.ExpandCollectionFileName(VarToStr(FCollection.GetProperty(PROP_DATAFILE)));
  SystemFile := Settings.SystemFileName[sfSystemDB];
  Backup(TargetFile,'destination.hlc2','Резервная копия коллекции');
  Backup(SystemFile,'system.hlc2','Резервная копия групп');
  TFile.WriteAllText(TPath.Combine(BackupFolder,'restore-paths.txt'),
    'Коллекция: '+TargetFile+#13#10+'Группы и настройки: '+SystemFile,TEncoding.UTF8);
  ReportFile := TStreamWriter.Create(TPath.Combine(BackupFolder,'series.txt'),False,TEncoding.UTF8);
  try
    ReportFile.WriteLine(FReport.Text);
    for Pair in FPairs do ReportFile.WriteLine(Format('%d → %d | %s → %s',
      [Pair.OldID,Pair.NewID,Pair.OldTitle,Pair.NewTitle]));
  finally ReportFile.Free; end;
  CheckRevision; CheckCanceled; TargetCommitted := False; SystemStarted := False;
  FCollection.BeginBulkOperation;
  try
    FSystem.BeginDataUpdate; SystemStarted := True; I := 0;
    for Pair in FPairs do
    begin
      CheckCanceled;
      FCollection.ChangeBookSeriesID(Pair.OldID,Pair.NewID,FCollection.CollectionID);
      Inc(I);
      if Assigned(Progress) and ((I mod 100=0) or (I=Count)) then Progress('Объединение названий серий',I,Count);
    end;
    CheckCanceled; FCollection.EndBulkOperation(True); TargetCommitted := True;
    FSystem.EndDataUpdate(True); SystemStarted := False;
  except
    if FCollection.InBulkOperation then FCollection.EndBulkOperation(False);
    if SystemStarted then FSystem.EndDataUpdate(False);
    if TargetCommitted then FCollection.RestoreCollectionBackup(TPath.Combine(BackupFolder,'destination.hlc2'));
    try TFile.WriteAllText(TPath.Combine(BackupFolder,'status.txt'),'Отменено',TEncoding.UTF8); except end;
    raise;
  end;
  FReady := False;
  // A diagnostic write after both commits must never undo one database only.
  try TFile.WriteAllText(TPath.Combine(BackupFolder,'status.txt'),'Завершено',TEncoding.UTF8); except end;
end;
constructor TSeriesAliasWorker.CreatePreview(CollectionID: Integer);
begin inherited Create(CollectionID); end;
constructor TSeriesAliasWorker.CreateApply(Plan: TSeriesAliasPlan; const BackupFolder: string);
begin inherited Create(MHL_INVALID_ID); FApply := True; FPlan := Plan; FBackup := BackupFolder; end;
destructor TSeriesAliasWorker.Destroy;
begin if not FApply then FPlan.Free; inherited; end;
function TSeriesAliasWorker.TakePlan: TSeriesAliasPlan;
begin Result := FPlan; FPlan := nil; end;
procedure TSeriesAliasWorker.ReportStage(const Stage: string; Current, Total: Integer);
begin
  if Total > 0 then
  begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Current)*100 div Total));
    SetComment(Format('%s: %d%%',[Stage,Integer(Int64(Current)*100 div Total)])); end
  else begin SetProgressHint(pbstMarquee); SetComment(Stage+'…'); end;
end;
procedure TSeriesAliasWorker.WorkFunction;
begin
  try
    ReportStage('Поиск дублей названий серий',0,0);
    if not FApply then
    begin FPlan := TSeriesAliasPlan.Create(FCollection,FSystemData);
      FPlan.Preview(function: Boolean begin Result := Canceled; end); end
    else FPlan.Apply(FBackup,
      procedure(const Stage: string; Current, Total: Integer)
      begin ReportStage(Stage,Current,Total); end,
      function: Boolean begin Result := Canceled; end);
    FSuccess := True;
  except
    on E: EAbort do FError := 'Операция отменена. Изменения не применены.';
    on E: Exception do FError := E.Message;
  end;
end;
end.
