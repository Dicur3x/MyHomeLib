unit unit_SeriesAliases;

interface
uses System.Classes, System.Generics.Collections, unit_Interfaces,
  unit_CollectionMerge, unit_CollectionWorkerThread;
type
  TSeriesAliasPair = record OldID, NewID, FinalID: Integer; OldTitle, NewTitle, OriginalNewTitle: string; end;
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
  unit_Settings, unit_Consts, unit_Globals, dm_user,
  System.Generics.Defaults, unit_SeriesAliasMatching, unit_CollectionBackup;

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
  SavedCancel: TSQLiteCancelCallback; Candidates: TList<TSeriesAliasCandidate>;
  Parents: TArray<Integer>; First, Last, I, J, A, B: Integer; Namespace: string;
  Starts: TDictionary<string,Integer>;
  Aliases: TDictionary<Integer,TSeriesAliasCandidate>;
  function RootOf(Index: Integer): Integer;
  begin
    Result:=Index;
    while Parents[Result]<>Result do Result:=Parents[Result];
  end;
  procedure CheckCanceled;
  begin if Assigned(Canceled) and Canceled() then Abort; end;
  function Canonical(Candidate: TSeriesAliasCandidate): TSeriesAliasCandidate;
  var Next: TSeriesAliasCandidate;
  begin
    Result:=Candidate;
    while Aliases.TryGetValue(Result.ID,Next) do Result:=Next;
  end;
  procedure FinalizeAliases;
  var ReservedTitles: TStringList; FinalTitles: TDictionary<Integer,string>;
    Target: TSeriesAliasCandidate;
    function CanonicalSpelling(const Candidate: TSeriesAliasCandidate): string;
    var Name, Suffix, Proposed: string; Bracket: Integer;
    begin
      Result := Candidate.Title;
      Name := Trim(Candidate.Title);
      Bracket := LastDelimiter('(', Name);
      if (Bracket <= 1) or not Name.EndsWith(')') then Exit;
      Suffix := Trim(Copy(Name, Bracket + 1, Length(Name) - Bracket - 1));
      if (Suffix = '') or Suffix.Contains(')') then Exit;
      Proposed := TrimRight(Copy(Name, 1, Bracket - 1)) + ' (' + Suffix + ')';
      if (Proposed = Candidate.Title) or (ReservedTitles.IndexOf(Proposed) >= 0) or
        (DB.QuerySingleInt('SELECT COUNT(*) FROM Series WHERE SeriesTitle = ? COLLATE MHL_SYSTEM_NOCASE AND SeriesID <> ?',
          [Proposed, Candidate.ID]) <> 0) then Exit;
      ReservedTitles.Add(Proposed);
      Result := Proposed;
    end;
  begin
    ReservedTitles := TStringList.Create;
    FinalTitles := TDictionary<Integer,string>.Create;
    try
      ReservedTitles.Sorted := True;
      for var Index := 0 to FPairs.Count - 1 do
      begin
        CheckCanceled;
        Pair := FPairs[Index];
        Target := Canonical(Aliases[Pair.OldID]);
        Pair.FinalID := Target.ID;
        Pair.OriginalNewTitle := Target.Title;
        if not FinalTitles.TryGetValue(Target.ID, Pair.NewTitle) then
        begin
          Pair.NewTitle := CanonicalSpelling(Target);
          FinalTitles.Add(Target.ID, Pair.NewTitle);
        end;
        FPairs[Index] := Pair;
      end;
    finally FinalTitles.Free; ReservedTitles.Free; end;
  end;
  procedure AddAlias(const Source, Target: TSeriesAliasCandidate);
  begin
    Pair.OldID:=Source.ID; Pair.NewID:=Target.ID;
    Pair.OldTitle:=Source.Title; Pair.NewTitle:=Target.Title;
    FPairs.Add(Pair);
    Aliases.Add(Source.ID,Target);
  end;
  procedure MatchPublisherSuffixes;
  var Source, Target: TSeriesAliasCandidate; Index: Integer;
  begin
    for var Candidate in Candidates do
    begin
      CheckCanceled;
      if (Candidate.PublisherSuffix='') or not Starts.TryGetValue(Candidate.PublisherBaseKey,Index) then Continue;
      Source:=Canonical(Candidate);
      if (Source.PublisherBaseKey<>Candidate.PublisherBaseKey) or
        (Source.PublisherSuffix<>Candidate.PublisherSuffix) then Continue;
      while (Index<Candidates.Count) and (Candidates[Index].Key=Candidate.PublisherBaseKey) do
      begin
        CheckCanceled;
        Target:=Canonical(Candidates[Index]);
        if (Source.ID<>Target.ID) and SeriesShareRecord(DB,Candidate.ID,Candidates[Index].ID) and
          SeriesHavePublisher(DB,Candidate.ID,Candidate.PublisherSuffix) and
          ((Source.ID=Candidate.ID) or SeriesHavePublisher(DB,Source.ID,Candidate.PublisherSuffix)) then
        begin
          AddAlias(Source,Target);
          Break;
        end;
        Inc(Index);
      end;
    end;
  end;
begin
  FReady:=False; FPairs.Clear; FReport.Clear; CheckCanceled;
  if isOnlineCollection(FCollection.CollectionCode) then
    raise Exception.Create('Объединение серий доступно для локального каталога.');
  FCatalogRevision:=FCollection.GetCatalogRevision; FSystemRevision:=FSystem.GetDataRevision;
  Namespace:=VarToStr(FCollection.GetProperty(PROP_SOURCE_LIBRARY));
  DB:=TSQLiteDatabase.CreateReadOnly(Settings.ExpandCollectionFileName(
    VarToStr(FCollection.GetProperty(PROP_DATAFILE))));
  Candidates:=TList<TSeriesAliasCandidate>.Create;
  Starts:=TDictionary<string,Integer>.Create;
  Aliases:=TDictionary<Integer,TSeriesAliasCandidate>.Create;
  SavedCancel:=SQLiteCancelCallback; FQueryCanceled:=Canceled; FQueryAborted:=False;
  SQLiteCancelCallback:=QueryCanceled;
  try
    try
      Query:=DB.NewQuery('SELECT SeriesID,SeriesTitle FROM Series');
      try
        Query.Open;
        while not Query.Eof do
        begin
          CheckCanceled;
          Candidates.Add(SeriesAliasCandidate(Query.FieldAsInt(0),Query.FieldAsString(1)));
          Query.Next;
        end;
      finally Query.Free; end;
      Candidates.Sort(TComparer<TSeriesAliasCandidate>.Construct(
        function(const Left, Right: TSeriesAliasCandidate): Integer
        begin
          Result:=CompareStr(Left.Key,Right.Key);
          if Result=0 then Result:=Left.Rank-Right.Rank;
          if Result=0 then Result:=Left.SpellingRank-Right.SpellingRank;
          if Result=0 then Result:=Left.ID-Right.ID;
        end));
      First:=0;
      while First<Candidates.Count do
      begin
        CheckCanceled; Last:=First+1;
        while (Last<Candidates.Count) and (Candidates[Last].Key=Candidates[First].Key) do Inc(Last);
        Starts.Add(Candidates[First].Key,First);
        SetLength(Parents,Last-First);
        for I:=0 to High(Parents) do Parents[I]:=I;
        for I:=0 to High(Parents) do
          for J:=I+1 to High(Parents) do
          begin
            A:=RootOf(I); B:=RootOf(J); if A=B then Continue;
            // Keep the established author-cycle rule. Publisher/mixed labels
            // and bracket variants require actual overlap of catalog books.
            if ((Candidates[First+I].LiteralKey=Candidates[First+J].LiteralKey) and
              ((Candidates[First+I].Tag='a') or (Candidates[First+J].Tag='a')) and
              CharInSet(Candidates[First+I].Tag,[#0,'a']) and
              CharInSet(Candidates[First+J].Tag,[#0,'a']) and
              SeriesHaveSameAuthor(DB,Candidates[First+I].ID,Candidates[First+J].ID)) or
              SeriesHaveSameBook(DB,Candidates[First+I].ID,Candidates[First+J].ID,Namespace,Canceled) then
            begin
              if A<B then Parents[B]:=A else Parents[A]:=B;
            end;
          end;
        for I:=0 to High(Parents) do
        begin
          A:=RootOf(I); if A=I then Continue;
          AddAlias(Candidates[First+I],Candidates[First+A]);
        end;
        First:=Last;
      end;
      MatchPublisherSuffixes;
      FinalizeAliases;
    except
      on E: ESQLiteException do if FQueryAborted then Abort else raise;
    end;
  finally
    SQLiteCancelCallback:=SavedCancel; FQueryCanceled:=nil;
    Aliases.Free; Starts.Free; Candidates.Free; DB.Free;
  end;
  CheckCanceled;
  FReport.Add(Format('Найдено пар названий серий: %d.',[Count]));
  FReport.Add('Проверка ничего не изменила. Для применения нажмите «Объединить найденные серии».');
  FReport.Add('Для вариантов со скобками, тире, е/ё и метками [p], [m] проверено совпадение книг: общий библиотечный ID либо название с автором, языком и форматом.');
  FReport.Add('Для авторских меток [a] также учитывается совпадение автора при одинаковом названии серии. Разные циклы без подтверждения остаются отдельно.');
  FReport.Add('Пометка издателя в скобках объединяется с названием без пометки, если издатель подтверждён и есть общая запись книги.');
  FReport.Add('Книги обеих серий будут в одном списке. Все файлы, издания, оценки, прогресс чтения и группы сохраняются.');
  FReport.Add('Это объединение названий серий. Копии книг не удаляются; для выбора одной записи требуется отдельная проверка дублей книг.');
  FReport.Add('Повторное подключение INPX не требуется. Перед применением можно сохранить резервную копию.');
  FReport.Add('');
  for Pair in FPairs do
  begin
    if FReport.Count>=1008 then Break;
    FReport.Add(Pair.OldTitle+' → '+Pair.NewTitle);
  end;
  if Count>1000 then FReport.Add('В предпросмотре показаны первые 1000 пар. Полный список входит в отчёт при сохранении резервной копии.');
  CheckRevision; FReady:=True;
end;
procedure TSeriesAliasPlan.Apply(const BackupFolder: string; const Progress: TMergeStageProgress;
  const Canceled: TMergeCanceled);
var DB: TSQLiteDatabase; TargetFile, SystemFile, BackupRoot, TargetSnapshot: string; Pair: TSeriesAliasPair;
  I: Integer; TargetCommitted, SystemStarted, KeepBackup, KeepRecovery: Boolean; ReportFile: TStreamWriter;
  Renamed: TDictionary<Integer, Boolean>;
  procedure CheckCanceled;
  begin if Assigned(Canceled) and Canceled() then Abort; end;
  procedure Backup(const Source, Name, Stage: string);
  begin
    CheckCanceled; DB := TSQLiteDatabase.CreateReadOnly(Source);
    try DB.BackupTo(TPath.Combine(BackupRoot,Name),
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
  KeepBackup := BackupFolder <> '';
  KeepRecovery := False;
  BackupRoot := BackupFolder;
  if not KeepBackup then
    BackupRoot := TPath.Combine(TPath.GetTempPath, 'HomeLibre-series-' + TGUID.NewGuid.ToString);
  if DirectoryExists(BackupRoot) then raise Exception.Create('Для резервной копии требуется новая папка.');
  if not ForceDirectories(BackupRoot) then raise Exception.Create('Не удалось создать папку: ' + BackupRoot);
  TargetSnapshot := TPath.Combine(BackupRoot, 'destination.hlc2');
  Renamed := TDictionary<Integer, Boolean>.Create;
  try
    TargetFile := Settings.ExpandCollectionFileName(VarToStr(FCollection.GetProperty(PROP_DATAFILE)));
    if KeepBackup then
      Backup(TargetFile, 'destination.hlc2', 'Резервная копия коллекции')
    else
      Backup(TargetFile, 'destination.hlc2', 'Подготовка к безопасному изменению коллекции');
    if KeepBackup then
    begin
      SystemFile := Settings.SystemFileName[sfSystemDB];
      WriteCollectionBackupInfo(BackupRoot,cboSeries);
      Backup(SystemFile,'system.hlc2','Резервная копия групп');
      TFile.WriteAllText(TPath.Combine(BackupRoot,'restore-paths.txt'),
        'Коллекция: '+TargetFile+#13#10+'Группы и настройки: '+SystemFile+#13#10+
        'Папка книг: '+Settings.ExpandCollectionRoot(VarToStr(FCollection.GetProperty(PROP_ROOTFOLDER))),TEncoding.UTF8);
      ReportFile := TStreamWriter.Create(TPath.Combine(BackupRoot,'series.txt'),False,TEncoding.UTF8);
      try
        ReportFile.WriteLine(FReport.Text);
        for Pair in FPairs do ReportFile.WriteLine(Format('%d → %d | %s → %s',
          [Pair.OldID,Pair.FinalID,Pair.OldTitle,Pair.NewTitle]));
      finally ReportFile.Free; end;
    end;
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
      for Pair in FPairs do
        if (Pair.NewTitle <> Pair.OriginalNewTitle) and not Renamed.ContainsKey(Pair.FinalID) then
        begin
          FCollection.SetSeriesTitle(Pair.FinalID, Pair.NewTitle);
          Renamed.Add(Pair.FinalID, True);
        end;
      CheckCanceled; FCollection.EndBulkOperation(True); TargetCommitted := True;
      FSystem.EndDataUpdate(True); SystemStarted := False;
    except
      KeepRecovery := TargetCommitted;
      try
        if FCollection.InBulkOperation then FCollection.EndBulkOperation(False);
        if SystemStarted then FSystem.EndDataUpdate(False);
        if TargetCommitted then FCollection.RestoreCollectionBackup(TargetSnapshot);
        KeepRecovery := False;
      except
        on E: Exception do
          raise Exception.Create(E.Message + sLineBreak + 'Копия для восстановления: ' + TargetSnapshot);
      end;
      if KeepBackup then
        try TFile.WriteAllText(TPath.Combine(BackupRoot,'status.txt'),'Отменено',TEncoding.UTF8); except end;
      raise;
    end;
    FReady := False;
    if KeepBackup then
      try TFile.WriteAllText(TPath.Combine(BackupRoot,'status.txt'),'Завершено',TEncoding.UTF8); except end;
  finally
    Renamed.Free;
    if not KeepBackup and not KeepRecovery then
      try
        if FileExists(TargetSnapshot) then TFile.Delete(TargetSnapshot);
        TDirectory.Delete(BackupRoot, False);
      except
        on E: Exception do
          if Assigned(Progress) then Progress('Не удалось убрать временную копию: ' + BackupRoot, 0, 0);
      end;
  end;
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
    if FApply then Teletype(Format('Готово: объединено %d пар серий. Все книги сохранены.',[FPlan.Count]),tsInfo)
    else begin Teletype(Format('Проверка завершена. Найдено пар серий: %d.',[FPlan.Count]),tsInfo);
      Teletype('Изменения ещё не применены. Результат появится в окне названий серий.',tsInfo); end;
    FSuccess := True;
  except
    on E: EAbort do FError := 'Операция отменена. Изменения не применены.';
    on E: Exception do FError := E.Message;
  end;
end;
end.
