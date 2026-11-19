unit frm_CollectionTransfer;

interface

uses System.Classes, System.SysUtils, System.Generics.Collections, Vcl.Forms, Vcl.Controls,
  Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, unit_Globals, unit_CollectionTransferRegistry;

procedure ShowCollectionTransfer(Owner:TCustomForm; const Info:TCollectionInfo; const PersonalFile:string;
  const Pending:TRegisteredCollectionTransfer; const ReleaseCollection,RefreshCollection:TProc;
  const ApplicationReady:TFunc<Boolean>);

implementation

uses Winapi.Windows, Winapi.Messages, Winapi.ActiveX, System.IOUtils, System.SyncObjs, System.Math,
  Vcl.Dialogs, Vcl.Clipbrd, unit_Settings, dm_user, unit_MHLTheme, unit_BookEstimateReport,
  unit_CollectionTransferCatalogue, unit_CollectionTransferPlan, unit_CollectionTransferJournal,
  unit_CollectionTransferOperation, unit_CollectionTransferCompletion, unit_CollectionTransferSpace,
  unit_CollectionTransferReferences, unit_AtomicIniFile, unit_ContextToolGuide, SQLiteWrap;

const
  DestinationUnavailable = 'Папка назначения «%s» недоступна. Подключите диск или восстановите доступ к папке и повторите попытку.';

type
  TTransferUIPhase=(tpPreview,tpRun,tpComplete);
  TTransferUIState=(usIdle,usPreview,usReady,usRunning,usWaiting,usCompleting,usStopped,usFailed,usCompleted);
  TTransferUIStatus=record
    Stage,FileName:string;
    GroupsDone,GroupsTotal,Done,Total:Int64;
  end;
  TTransferUIContext=class
  private
    FLock:TObject;
    FStatus:TTransferUIStatus;
    FNextSpaceCheck:UInt64;
  public
    Info:TCollectionInfo;
    Personal,Destination,WorkRoot,Error:string;
    Pending:TRegisteredCollectionTransfer;
    Capture:TCollectionTransferCatalogue;
    Plan:TCollectionTransferPlan;
    Journal:TCollectionTransferJournal;
    Files,CopyFiles,CopyBytes,Missing:Int64;
    PreviewLines:TArray<string>;
    RootsReady,Stopped:Boolean;
    ReadyFlag,CancelFlag:Integer;
    Outcome:TTransferCompletionResult;
    Cleanup:TTransferCleanupResult;
    constructor Create;
    destructor Destroy; override;
    function Cancelled:Boolean;
    procedure Progress(const Stage,Source:string; GroupsDone,GroupsTotal,Done,Total:Int64);
    procedure CatalogueProgress(Count:Int64);
    function Status:TTransferUIStatus;
    procedure BeginPhase;
    procedure CheckSpace;
  end;
  TTransferUIWorker=class(TThread)
  private
    FContext:TTransferUIContext;
    FPhase:TTransferUIPhase;
    FReady:TFunc<Boolean>;
    FDone:Integer;
    function Cancelled:Boolean;
    procedure Progress(const Stage,Source:string; GroupsDone,GroupsTotal,Done,Total:Int64);
  protected
    procedure Execute; override;
  public
    constructor Create(Context:TTransferUIContext; Phase:TTransferUIPhase; const Ready:TFunc<Boolean>);
    procedure RequestStop;
    function Done:Boolean;
    function Status:TTransferUIStatus;
  end;
  TfrmCollectionTransfer=class(TForm)
  private
    FContext:TTransferUIContext;
    FWorker:TTransferUIWorker;
    FState:TTransferUIState;
    FRelease,FRefresh:TProc;
    FReady:TFunc<Boolean>;
    FReleased,FCloseAfterStop,FLayoutBusy,FWorkAutomatic,FUpdatingWork:Boolean;
    FToolGuide:TContextToolGuide;
    FDestination,FWork:TEdit;
    FChooseDestination,FChooseWork,FResetWork,FPreview,FRun,FStop,FClose,FPin,FSaveReport:TButton;
    FCompletionText: string;
    FStage,FSource,FHelp,FDestinationLabel,FWorkLabel:TLabel;
    FReport:TMemo;
    FBar:TProgressBar;
    FTimer:TTimer;
    function Button(const AName,Text:string; X,Y,W:Integer; Click:TNotifyEvent):TButton;
    procedure SetState(Value:TTransferUIState; const Text:string);
    function ReleaseView:Boolean;
    procedure RefreshView;
    procedure Start(Phase:TTransferUIPhase);
    procedure ChooseFolder(Sender:TObject);
    procedure LocationChanged(Sender:TObject);
    function DefaultWorkFolder: string;
    procedure UpdateAutomaticWorkFolder;
    procedure ResetWorkFolder(Sender: TObject);
    procedure SaveReport(Sender: TObject);
    procedure WriteRetainedSources(Limit: Integer; const WriteLine: TProc<string>);
    procedure Preview(Sender:TObject);
    procedure Run(Sender:TObject);
    procedure Stop(Sender:TObject);
    procedure Pin(Sender:TObject);
    procedure CloseClick(Sender:TObject);
    procedure CloseQuery(Sender:TObject; var CanClose:Boolean);
    procedure Tick(Sender:TObject);
    procedure Finished;
    procedure LayoutControls;
  protected
    procedure Resize; override;
    procedure DoShow; override;
    procedure DoHide; override;
  public
    procedure ScaleForPPI(NewPPI:Integer); override;
    constructor CreateFor(Owner:TCustomForm; const Info:TCollectionInfo; const Personal:string;
      const Pending:TRegisteredCollectionTransfer; const ReleaseCollection,RefreshCollection:TProc;
      const ApplicationReady:TFunc<Boolean>);
    destructor Destroy; override;
  end;

function UnverifiedTransferCatalogues(Review: TSQLiteDatabase): string;
begin
  Result := Review.QuerySingleString('SELECT coalesce(group_concat(Name,'', ''),'''') FROM ' +
    '(SELECT DISTINCT ''«'' || coalesce(NULLIF(r.Name,''''),r.Catalogue) || ''»'' AS Name ' +
    'FROM ReferenceIssues i JOIN ReferenceRegistrations r ON r.RegistrationID=i.RegistrationID ' +
    'ORDER BY r.RegistrationID LIMIT 12)');
end;

procedure AppendSharedTransferCatalogues(Review: TSQLiteDatabase; CollectionID: Integer;
  Finished: Boolean; Lines: TStrings);
var Query: TSQLiteQuery; Header: string;
begin
  if Review.QuerySingleInt('SELECT count(*) FROM ReferenceRegistrations ' +
    'WHERE RegistrationID<>? AND State=''ready''', [CollectionID]) = 0 then Exit;
  if Finished then Header := 'В других коллекциях переключены ссылки на общие файлы:'
  else Header := 'Перенос переключит ссылки на общие файлы в других коллекциях:';
  Query := Review.NewQuery('SELECT c.Name,count(DISTINCT r.FileID) FROM RegisteredReferences r ' +
    'JOIN ReferenceRegistrations c ON c.RegistrationID=r.RegistrationID ' +
    'JOIN Files f ON f.ID=r.FileID WHERE r.RegistrationID<>? AND r.RetainReason='''' ' +
    'AND r.Resource=0 AND f.KeepInPlace=0 GROUP BY c.RegistrationID,c.Name ORDER BY c.Name',
    [CollectionID]);
  try
    Query.Open;
    if not Query.Eof then
    begin
      Lines.Add(Header);
      while not Query.Eof do
      begin
        Lines.Add(Format('«%s» — файлов %d', [Query.FieldAsString(0), Query.FieldAsInt(1)]));
        Query.Next;
      end;
      Lines.Add('');
    end;
  finally Query.Free; end;
end;

procedure AppendTransferPaths(Review: TSQLiteDatabase; CollectionID: Integer;
  Lines: TStrings; const Cancelled: TFunc<Boolean>);
var Files, References: TSQLiteQuery; Catalogues, Note: string; ID: Int64;
begin
  Files := Review.NewQuery('SELECT ID,Source,Destination,KeepInPlace FROM Files ORDER BY Source LIMIT 200');
  try
    References := Review.NewQuery('SELECT c.Name FROM RegisteredReferences r ' +
      'JOIN ReferenceRegistrations c ON c.RegistrationID=r.RegistrationID ' +
      'WHERE r.FileID=? AND r.RegistrationID<>? AND r.RetainReason='''' AND r.Resource=0 ' +
      'GROUP BY c.RegistrationID,c.Name ORDER BY c.Name');
    try
      Files.Open;
      while not Files.Eof do
      begin
        if Assigned(Cancelled) and Cancelled() then Abort;
        ID := Files.FieldAsInt(0);
        Lines.Add(Files.FieldAsString(1) + sLineBreak + '  → ' + Files.FieldAsString(2));
        References.Reset;
        References.SetParam(0, ID);
        References.SetParam(1, CollectionID);
        References.Open;
        Catalogues := '';
        while not References.Eof do
        begin
          if Catalogues <> '' then Catalogues := Catalogues + ', ';
          Catalogues := Catalogues + '«' + References.FieldAsString(0) + '»';
          References.Next;
        end;
        if Catalogues <> '' then
        begin
          if Files.FieldAsInt(3) <> 0 then Note := 'Файл уже по нужному адресу.'
          else if TransferReferenceRequiresRetention(Review, ID) then
            Note := 'Исходник будет сохранён.'
          else Note := 'Планируется освободить прежний путь после проверки.';
          Lines.Add('  Общий файл с коллекциями ' + Catalogues + '. ' + Note);
        end;
        Files.Next;
      end;
    finally References.Free; end;
  finally Files.Free; end;
end;

constructor TTransferUIContext.Create;
begin inherited; FLock:=TObject.Create; end;

destructor TTransferUIContext.Destroy;
begin Journal.Free; Plan.Free; Capture.Free; FLock.Free; inherited; end;

function TTransferUIContext.Cancelled:Boolean;
begin Result:=TInterlocked.CompareExchange(CancelFlag,0,0)<>0; end;

procedure TTransferUIContext.BeginPhase;
begin
  FNextSpaceCheck:=0;
  TInterlocked.Exchange(CancelFlag,0);
  System.TMonitor.Enter(FLock);
  try FStatus:=Default(TTransferUIStatus); finally System.TMonitor.Exit(FLock); end;
end;

procedure TTransferUIContext.CheckSpace;
var Available,Capacity:UInt64;
begin
  if GetTickCount64<FNextSpaceCheck then Exit;
  FNextSpaceCheck:=GetTickCount64+1000;
  var SystemDrive:=GetEnvironmentVariable('SystemDrive'); if SystemDrive='' then SystemDrive:='C:';
  if not GetDiskFreeSpaceEx(PChar(IncludeTrailingPathDelimiter(SystemDrive)),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then
    raise EWriteError.Create('На системном диске нужно сохранить не менее 8 ГБ. Подготовка остановлена.');
  if (Destination<>'') and not DirectoryExists(Destination) then
    raise EDirectoryNotFoundException.CreateFmt(DestinationUnavailable,[Destination]);
  for var Path in TArray<string>.Create(WorkRoot,Destination) do
    if (Path<>'') and DirectoryExists(Path) then
    begin
      if not GetDiskFreeSpaceEx(PChar(IncludeTrailingPathDelimiter(Path)),Available,Capacity,nil) then RaiseLastOSError;
      if Available<UInt64(512)*1024*1024 then
        raise EWriteError.CreateFmt('В папке «%s» доступно %s. Освободите место, чтобы сохранить резерв 512 МБ, и повторите попытку.',
          [Path,BookEstimateSizeText(Available)]);
    end;
end;

function TTransferUIContext.Status:TTransferUIStatus;
begin System.TMonitor.Enter(FLock); try Result:=FStatus; finally System.TMonitor.Exit(FLock); end; end;

procedure TTransferUIContext.Progress(const Stage,Source:string; GroupsDone,GroupsTotal,Done,Total:Int64);
begin
  System.TMonitor.Enter(FLock);
  try
    FStatus.Stage:=Stage; FStatus.FileName:=Source; FStatus.GroupsDone:=GroupsDone;
    FStatus.GroupsTotal:=GroupsTotal; FStatus.Done:=Done; FStatus.Total:=Total;
  finally System.TMonitor.Exit(FLock); end;
end;

procedure TTransferUIContext.CatalogueProgress(Count:Int64);
begin Progress('Проверка записей коллекции','',0,0,Count,0); end;

constructor TTransferUIWorker.Create(Context:TTransferUIContext; Phase:TTransferUIPhase; const Ready:TFunc<Boolean>);
begin
  inherited Create(True); FContext:=Context; FPhase:=Phase; FReady:=Ready;
end;

function TTransferUIWorker.Cancelled:Boolean;
begin Result:=FContext.Cancelled; end;

procedure TTransferUIWorker.RequestStop;
begin TInterlocked.Exchange(FContext.CancelFlag,1); end;

function TTransferUIWorker.Done:Boolean;
begin Result:=TInterlocked.CompareExchange(FDone,0,0)<>0; end;

function TTransferUIWorker.Status:TTransferUIStatus;
begin Result:=FContext.Status; end;

procedure TTransferUIWorker.Progress(const Stage,Source:string; GroupsDone,GroupsTotal,Done,Total:Int64);
begin
  FContext.Progress(Stage,Source,GroupsDone,GroupsTotal,Done,Total);
end;

procedure TTransferUIWorker.Execute;
begin
  // Capture the stable context explicitly: converting FContext.Method to an
  // anonymous callback can retain an expression through this short-lived Self.
  var Context:=FContext;
  var COM:=CoInitializeEx(nil,COINIT_MULTITHREADED);
  try
    FContext.Error:=''; FContext.Stopped:=False;
    try
      Context.CheckSpace;
      case FPhase of
        tpPreview:
          begin
            FreeAndNil(FContext.Plan); FreeAndNil(FContext.Capture);
            ForceDirectories(FContext.WorkRoot);
            FContext.Capture:=TCollectionTransferCatalogue.Create(FContext.Info,FContext.Personal,FContext.WorkRoot,
              function:Boolean begin Context.CheckSpace; Result:=Context.Cancelled; end,
              procedure(Count:Int64) begin Context.CatalogueProgress(Count); end);
            if Cancelled then Abort;
            FContext.Plan:=FContext.Capture.BuildFilePlan(FContext.Destination,FContext.WorkRoot,TGUID.NewGuid);
            FContext.Files:=FContext.Plan.FileCount; FContext.CopyFiles:=FContext.Plan.CopyFileCount;
            FContext.CopyBytes:=FContext.Plan.CopyBytes; FContext.Missing:=FContext.Capture.Count(tbsMissing);
            var Lines:=TStringList.Create;
            try
              Progress('Оценка места и сохранённых источников','',0,0,0,0);
              var SpaceReview:=TCollectionTransferJournal.Create(FContext.WorkRoot,FContext.Capture,FContext.Plan,
                function:Boolean begin Context.CheckSpace; Result:=Context.Cancelled; end,True);
              try
                var Budget:=EstimateTransferSpace(SpaceReview,Settings.DataPath,
                  procedure begin Context.CheckSpace; if Context.Cancelled then Abort; end);
                AppendSharedTransferCatalogues(SpaceReview.Review, FContext.Info.ID, False, Lines);
                var Unverified := UnverifiedTransferCatalogues(SpaceReview.Review);
                if Unverified <> '' then
                begin
                  Lines.Add('Исходники будут сохранены, поскольку не удалось проверить ссылки коллекций: ' + Unverified + '.');
                  Lines.Add('');
                end;
                Lines.AddStrings(TransferSpaceText(Budget)); Lines.Add('');
                AppendTransferPaths(SpaceReview.Review, FContext.Info.ID, Lines,
                  function: Boolean begin Result := Context.Cancelled; end);
              finally SpaceReview.Free; end;
              FContext.PreviewLines:=Lines.ToStringArray;
            finally Lines.Free; end;
          end;
        tpRun:
          begin
            if FContext.Journal=nil then
            begin
              if FContext.Pending.Operation<>'' then
                FContext.Journal:=ResumeRegisteredCollectionTransfer(FContext.Personal,FContext.Pending.Operation)
              else
                FContext.Journal:=TCollectionTransferJournal.Create(FContext.WorkRoot,FContext.Capture,FContext.Plan,
                  function:Boolean begin Result:=Context.Cancelled; end);
              FreeAndNil(FContext.Plan); FreeAndNil(FContext.Capture);
            end;
            // A stop immediately after journal creation must remain discoverable
            // on the next launch, even before the first file group starts.
            var Registry:=TCollectionTransferRegistry.Create(FContext.Journal);
            try Registry.RegisterOperation; finally Registry.Free; end;
            var Operation:=TCollectionTransferOperation.Create(FContext.Journal);
            try
              var Result:=Operation.Run(Cancelled,Progress,True,True,True);
              FContext.RootsReady:=Result.RootsApplied;
            finally Operation.Free; end;
          end;
        tpComplete:
          begin
            FContext.Outcome:=FContext.Journal.CompleteTransfer(FReady,Cancelled);
            Progress('Очистка рабочих снимков','',0,0,0,0);
            // Completion is durable. A deferred cleanup cannot undo the move.
            try FContext.Cleanup:=FContext.Journal.CleanupCompletedCacheSnapshots(Cancelled);
            except on E:Exception do FContext.Cleanup.Warning:=E.Message; end;
          end;
      end;
    except
      on E:EAbort do
      begin
        FContext.Stopped:=True;
        if FPhase=tpPreview then FContext.Error:='Проверка остановлена. Книги не перемещались.'
        else FContext.Error:='Остановлено. Готовые копии и журнал сохранены.';
      end;
      on E:Exception do
        if (E is EOSError) and (FContext.Destination<>'') and not DirectoryExists(FContext.Destination) then
          FContext.Error:=Format(DestinationUnavailable,[FContext.Destination])
        else FContext.Error:=E.Message;
    end;
  finally
    if Succeeded(COM) then CoUninitialize;
    TInterlocked.Exchange(FDone,1);
  end;
end;

function TfrmCollectionTransfer.Button(const AName,Text:string; X,Y,W:Integer; Click:TNotifyEvent):TButton;
begin
  Result:=TButton.Create(Self); Result.Parent:=Self; Result.Name:=AName; Result.Caption:=Text;
  Result.SetBounds(X,Y,W,30); Result.OnClick:=Click;
end;

constructor TfrmCollectionTransfer.CreateFor(Owner:TCustomForm; const Info:TCollectionInfo; const Personal:string;
  const Pending:TRegisteredCollectionTransfer; const ReleaseCollection,RefreshCollection:TProc;
  const ApplicationReady:TFunc<Boolean>);
  function LabelAt(const Text:string; X,Y,W,H:Integer):TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=Self; Result.AutoSize:=False;
    Result.SetBounds(X,Y,W,H); Result.WordWrap:=True; Result.Caption:=Text;
    Result.Anchors:=[akLeft,akTop,akRight];
  end;
begin
  inherited CreateNew(Owner); Name:='CollectionTransferWindow'; Caption:='Перенос файлов коллекции';
  PixelsPerInch:=96; Font.PixelsPerInch:=96;
  Position:=poOwnerFormCenter; PopupMode:=pmExplicit; PopupParent:=Owner;
  Font.Name:='Segoe UI'; Font.Size:=9; ClientWidth:=800; ClientHeight:=640;
  Constraints.MinWidth:=700; Constraints.MinHeight:=560; BorderIcons:=[biSystemMenu,biMinimize,biMaximize];
  FContext:=TTransferUIContext.Create; FContext.Info:=Info; FContext.Personal:=Personal; FContext.Pending:=Pending;
  FRelease:=ReleaseCollection; FRefresh:=RefreshCollection; FReady:=ApplicationReady;
  FHelp:=LabelAt('Собрать файлы текущей коллекции в одной папке. Архивы переносятся целиком, без повторного сжатия. '+
    'Для источников создаются подпапки: одинаковые имена не заменят чужой архив. '+
    'Прежний файл освобождается только после проверки копии и сохранения адресов. Общие или занятые исходники могут остаться.',12,12,732,70);
  FHelp.Name:='TransferIntro';
  FDestinationLabel:=LabelAt('Папка назначения:',12,90,776,20);
  FDestination:=TEdit.Create(Self); FDestination.Parent:=Self; FDestination.Name:='TransferDestination';
  FDestination.SetBounds(12,112,650,25); FDestination.Anchors:=[akLeft,akTop,akRight];
  FDestination.Text:=Settings.ExpandCollectionRoot(Info.RootFolder);
  FChooseDestination:=Button('ChooseTransferDestination','Выбрать…',674,110,114,ChooseFolder);
  FChooseDestination.Anchors:=[akTop,akRight];
  FWorkLabel:=LabelAt('Рабочая папка для журнала и подготовки:',12,146,776,20);
  FWork:=TEdit.Create(Self); FWork.Parent:=Self; FWork.Name:='TransferWorkRoot';
  FWork.SetBounds(12,168,650,25); FWork.Anchors:=[akLeft,akTop,akRight];
  FWorkAutomatic := True;
  FWork.Text := DefaultWorkFolder;
  FChooseWork:=Button('ChooseTransferWorkRoot','Выбрать…',478,166,114,ChooseFolder); FChooseWork.Anchors:=[akTop,akRight];
  FResetWork:=Button('ResetTransferWorkRoot','Вернуть путь по умолчанию',604,166,184,ResetWorkFolder);
  FResetWork.Anchors:=[akTop,akRight];
  FStage:=LabelAt('',12,207,776,38); FStage.Name:='TransferStage';
  FSource:=LabelAt('',12,248,776,22); FSource.Name:='TransferCurrentFile'; FSource.WordWrap:=False;
  FSource.EllipsisPosition:=epPathEllipsis;
  FBar:=TProgressBar.Create(Self); FBar.Parent:=Self; FBar.Name:='TransferProgress';
  FBar.SetBounds(12,276,776,15); FBar.Anchors:=[akLeft,akTop,akRight];
  FReport:=TMemo.Create(Self); FReport.Parent:=Self; FReport.Name:='TransferReport';
  FReport.SetBounds(12,304,776,238); FReport.Anchors:=[akLeft,akTop,akRight,akBottom];
  FReport.ReadOnly:=True; FReport.ScrollBars:=ssVertical; FReport.WordWrap:=True; FReport.TabStop:=False;
  FReport.Text:='Сначала проверьте план. Проверка не переносит книги.';
  FPreview:=Button('PreviewCollectionTransfer','Проверить план',12,554,160,Preview);
  FRun:=Button('RunCollectionTransfer','Перенести',184,554,160,Run);
  FStop:=Button('StopCollectionTransfer','Остановить',356,554,140,Stop);
  FPin:=Button('PinCollectionTransfer','Поверх окон',12,598,160,Pin);
  FSaveReport:=Button('SaveCollectionTransferReport','Сохранить отчёт…',184,598,180,SaveReport);
  FSaveReport.Anchors := [akLeft,akBottom];
  FClose:=Button('CloseCollectionTransfer','Закрыть',668,598,120,CloseClick);
  for var B in [FPreview,FRun,FStop,FPin,FClose] do B.Anchors:=[akLeft,akBottom];
  FClose.Anchors:=[akRight,akBottom]; FClose.Cancel:=True;
  FTimer:=TTimer.Create(Self); FTimer.Interval:=100; FTimer.OnTimer:=Tick;
  FToolGuide:=TContextToolGuide.CreateForTool(Self,Self,'collection-transfer','Как собрать коллекцию в одной папке',
    'Выберите папку для книг и нажмите «Проверить план». На этом шаге можно посмотреть список файлов и нужное место на каждом диске.',
    'В папку назначения попадут книги и целые архивы. Одноимённые архивы разных источников получат отдельные пути.'+sLineBreak+
    'В рабочей папке хранятся журнал и временные данные. Оставьте её доступной до завершения переноса.'+sLineBreak+
    'Если план подходит, нажмите «Перенести». Чтобы прерваться, нажмите «Остановить». При следующем запуске выберите «Продолжить».',
    110,'transfer');
  FToolGuide.Name:='TransferContextGuide';
  OnCloseQuery:=CloseQuery; ApplyMHLControlTheme(Self);
  if Pending.Operation<>'' then
  begin
    FWorkAutomatic := False;
    FDestination.Text:=Pending.Destination; FWork.Text:=Pending.WorkRoot;
    FContext.Destination:=Pending.Destination; FContext.WorkRoot:=Pending.WorkRoot;
    FRun.Caption:='Продолжить'; FReport.Text:='Незавершённый перенос.'+sLineBreak+Pending.Directory;
    SetState(usStopped,'Готовые этапы будут проверены и использованы повторно.');
  end
  else SetState(usIdle,'Выберите папку и нажмите «Проверить план».');
  FDestination.OnChange:=LocationChanged; FWork.OnChange:=LocationChanged;
  ScaleForPPI(Screen.PixelsPerInch);
  var WorkArea:=Screen.WorkAreaRect;
  if Height>WorkArea.Height then Height:=WorkArea.Height;
  if Width>WorkArea.Width then Width:=WorkArea.Width;
end;

destructor TfrmCollectionTransfer.Destroy;
begin
  if FTimer<>nil then FTimer.Enabled:=False;
  if FWorker<>nil then begin FWorker.RequestStop; FWorker.WaitFor; FWorker.Free; end;
  FContext.Free; inherited;
end;

procedure TfrmCollectionTransfer.ScaleForPPI(NewPPI:Integer);
begin inherited; LayoutControls; end;

procedure TfrmCollectionTransfer.DoShow;
begin
  inherited;
  if FContext.Pending.Operation='' then FToolGuide.FirstUse;
end;

procedure TfrmCollectionTransfer.DoHide;
begin
  if Assigned(FToolGuide) then FToolGuide.Hide;
  inherited;
end;

procedure TfrmCollectionTransfer.Resize;
begin inherited; LayoutControls; end;

procedure TfrmCollectionTransfer.LayoutControls;
  function Px(Value:Integer):Integer;
  begin Result:=MulDiv(Value,Max(96,Font.PixelsPerInch),96); end;
begin
  if FLayoutBusy or (FClose=nil) then Exit;
  FLayoutBusy:=True;
  try
    Constraints.MinWidth:=Px(700); Constraints.MinHeight:=Px(560);
    var W:=ClientWidth; var Gap:=Px(12); var ChooseWidth:=Px(114); var ResetWidth:=Px(184);
    if Assigned(FToolGuide) then
      FToolGuide.HelpButton.SetBounds(W-Gap-Px(28),Px(8),Px(28),Px(28));
    FHelp.SetBounds(Gap,Px(12),W-3*Gap-Px(28),Px(70));
    FDestinationLabel.SetBounds(Gap,Px(90),W-2*Gap,Px(20));
    FWorkLabel.SetBounds(Gap,Px(146),W-2*Gap,Px(20));
    FDestination.SetBounds(Gap,Px(112),W-3*Gap-ChooseWidth,Px(25));
    FWork.SetBounds(Gap,Px(168),W-4*Gap-ChooseWidth-ResetWidth,Px(25));
    FChooseDestination.SetBounds(W-Gap-ChooseWidth,Px(110),ChooseWidth,Px(30));
    FChooseWork.SetBounds(W-2*Gap-ChooseWidth-ResetWidth,Px(166),ChooseWidth,Px(30));
    FResetWork.SetBounds(W-Gap-ResetWidth,Px(166),ResetWidth,Px(30));
    FStage.SetBounds(Gap,Px(207),W-2*Gap,Px(38));
    FSource.SetBounds(Gap,Px(248),W-2*Gap,Px(22));
    FBar.SetBounds(Gap,Px(276),W-2*Gap,Px(15));
    var RunTop:=ClientHeight-Px(86); var CloseTop:=ClientHeight-Px(42);
    FReport.SetBounds(Gap,Px(304),W-2*Gap,Max(Px(40),RunTop-Px(316)));
    FPreview.SetBounds(Gap,RunTop,Px(160),Px(30));
    FRun.SetBounds(Px(184),RunTop,Px(160),Px(30));
    FStop.SetBounds(Px(356),RunTop,Px(140),Px(30));
    FPin.SetBounds(Gap,CloseTop,Px(160),Px(30));
    FSaveReport.SetBounds(Px(184),CloseTop,Px(180),Px(30));
    FClose.SetBounds(W-Gap-Px(120),CloseTop,Px(120),Px(30));
  finally FLayoutBusy:=False; end;
end;

procedure TfrmCollectionTransfer.SetState(Value:TTransferUIState; const Text:string);
begin
  FState:=Value; FStage.Caption:=Text; FStage.Hint:=Text; FStage.ShowHint:=True;
  var Busy:=Assigned(FWorker) or (Value=usWaiting);
  var Frozen:=(FContext.Pending.Operation<>'') or (FContext.Journal<>nil);
  FDestination.Enabled:=not Busy and not Frozen; FWork.Enabled:=FDestination.Enabled;
  FChooseDestination.Enabled:=FDestination.Enabled; FChooseWork.Enabled:=FDestination.Enabled;
  FResetWork.Enabled:=FDestination.Enabled and not FWorkAutomatic;
  FPreview.Enabled:=not Busy and not Frozen and (Value<>usCompleted);
  FRun.Enabled:=not Busy and (Value<>usCompleted) and
    ((((FContext.Plan<>nil) and (FContext.Files>0)) and (Value=usReady)) or Frozen);
  FStop.Enabled:=Busy; FClose.Enabled:=True;
  FSaveReport.Visible := Value = usCompleted;
  FRun.Default:=FRun.Enabled;
  if Value=usCompleted then FBar.Position:=100;
end;

function TfrmCollectionTransfer.ReleaseView:Boolean;
begin
  Result:=True; if FReleased then Exit;
  Result:=FReady();
  if not Result then begin FStage.Caption:='Дождитесь завершения загрузки, чтения или других заданий.'; Exit; end;
  FRelease(); FReleased:=True;
end;

procedure TfrmCollectionTransfer.RefreshView;
begin if FReleased then begin FRefresh(); FReleased:=False; end; end;

procedure TfrmCollectionTransfer.Start(Phase:TTransferUIPhase);
begin
  // Preview plans retain callbacks until a later run. Their state belongs to
  // this context, which outlives every worker, rather than the preview thread.
  FContext.BeginPhase;
  FContext.RootsReady:=False; FContext.Error:=''; FContext.Stopped:=False;
  TInterlocked.Exchange(FContext.ReadyFlag,Ord(FReady()));
  FWorker:=TTransferUIWorker.Create(FContext,Phase,
    function:Boolean begin Result:=TInterlocked.CompareExchange(FContext.ReadyFlag,0,0)<>0; end);
  case Phase of
    tpPreview:SetState(usPreview,'Проверка плана…');
    tpRun:SetState(usRunning,'Перенос файлов…');
    tpComplete:SetState(usCompleting,'Подтверждение завершения…');
  end;
  FBar.Style:=pbstMarquee; FWorker.Start;
end;

procedure TfrmCollectionTransfer.ChooseFolder(Sender:TObject);
begin
  var Dialog:=TFileOpenDialog.Create(Self);
  try
    Dialog.Options:=[fdoPickFolders,fdoPathMustExist]; Dialog.Title:='Выберите папку';
    if Sender=FChooseWork then Dialog.DefaultFolder:=FWork.Text else Dialog.DefaultFolder:=FDestination.Text;
    if not Dialog.Execute(Handle) then Exit;
    if Sender=FChooseWork then
    begin
      if FWork.Text = Dialog.FileName then
      begin
        FWorkAutomatic := False;
        FResetWork.Enabled := True;
      end
      else FWork.Text := Dialog.FileName;
    end
    else FDestination.Text := Dialog.FileName;
  finally Dialog.Free; end;
end;

function TfrmCollectionTransfer.DefaultWorkFolder: string;
begin
  Result := Trim(FDestination.Text);
  if Result <> '' then Result := IncludeTrailingPathDelimiter(Result) + '.homelibre-transfer-work';
end;

procedure TfrmCollectionTransfer.UpdateAutomaticWorkFolder;
begin
  if not FWorkAutomatic then Exit;
  FUpdatingWork := True;
  try
    FWork.Text := DefaultWorkFolder;
  finally
    FUpdatingWork := False;
  end;
end;

procedure TfrmCollectionTransfer.ResetWorkFolder(Sender: TObject);
begin
  FWorkAutomatic := True;
  LocationChanged(FDestination);
end;

procedure TfrmCollectionTransfer.LocationChanged(Sender:TObject);
begin
  if FUpdatingWork or (FWorker<>nil) or (FContext.Journal<>nil) or (FContext.Pending.Operation<>'') then Exit;
  if Sender = FWork then FWorkAutomatic := False else UpdateAutomaticWorkFolder;
  FreeAndNil(FContext.Plan); FreeAndNil(FContext.Capture);
  FContext.PreviewLines := nil;
  FSource.Caption := '';
  FBar.Position := 0;
  FReport.Text := 'План для выбранных папок ещё не рассчитан.';
  SetState(usIdle,'Папки изменены. Нажмите «Проверить план».');
end;

procedure TfrmCollectionTransfer.WriteRetainedSources(Limit: Integer; const WriteLine: TProc<string>);
var CollectionNames, LastReason: string;
begin
  if FContext.Outcome.Retained = 0 then Exit;
  CollectionNames := UnverifiedTransferCatalogues(FContext.Journal.Review);
  LastReason := '';
  WriteLine('');
  WriteLine('Сохранённые исходники');
  VisitRetainedTransferSources(FContext.Journal, Limit,
    procedure(Path, Reason: string)
    var Text: string;
    begin
      Text := Reason;
      if (CollectionNames <> '') and Text.StartsWith('Исходник нужен другой записи') then
        Text := 'Не удалось проверить ссылки коллекций: ' + CollectionNames + '.'
      else if Text = '' then Text := 'Причина в журнале не указана.';
      if Text <> LastReason then
      begin
        WriteLine(Text);
        LastReason := Text;
      end;
      WriteLine('  ' + Path);
    end);
end;

procedure TfrmCollectionTransfer.SaveReport(Sender: TObject);
var Dialog: TSaveDialog; Writer: TStreamWriter; Stream: THandleStream;
  Temporary: string; HandleToReport: THandle;
begin
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Title := 'Сохранить отчёт о переносе';
    Dialog.FileName := 'Перенос коллекции.txt';
    Dialog.DefaultExt := 'txt';
    Dialog.Filter := 'Текстовые файлы (*.txt)|*.txt';
    Dialog.Options := Dialog.Options + [ofOverwritePrompt, ofPathMustExist];
    if not Dialog.Execute(Handle) then Exit;
    try
      Temporary := TPath.Combine(ExtractFileDir(Dialog.FileName),
        '.homelibre-report-' + GUIDToString(TGUID.NewGuid) + '.tmp');
      HandleToReport := CreateFile(PChar(Temporary), GENERIC_READ or GENERIC_WRITE,
        0, nil, CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY, 0);
      if HandleToReport = INVALID_HANDLE_VALUE then RaiseLastOSError;
      try
        Stream := THandleStream.Create(HandleToReport);
        try
          Writer := TStreamWriter.Create(Stream, TEncoding.UTF8);
          try
            Writer.WriteLine(FCompletionText);
            WriteRetainedSources(-1, procedure(Line: string) begin Writer.WriteLine(Line); end);
          finally Writer.Free; end;
          SaveStreamAtomically(Stream, Dialog.FileName);
        finally Stream.Free; end;
      finally
        CloseHandle(HandleToReport);
        Winapi.Windows.DeleteFile(PChar(Temporary));
      end;
    except
      on E: Exception do MessageDlg('Не удалось сохранить отчёт. ' + E.Message, mtError, [mbOK], 0);
    end;
  finally Dialog.Free; end;
end;

procedure TfrmCollectionTransfer.Preview(Sender:TObject);
begin
  if not TPath.IsPathRooted(Trim(FDestination.Text)) or not TPath.IsPathRooted(Trim(FWork.Text)) then
  begin FStage.Caption:='Укажите полные пути к папкам или нажмите «Выбрать». '; Exit; end;
  if not ReleaseView then Exit;
  FContext.Destination:=ExpandFileName(Trim(FDestination.Text)); FContext.WorkRoot:=ExpandFileName(Trim(FWork.Text));
  if (Trim(FDestination.Text)='') or (Trim(FWork.Text)='') then begin FStage.Caption:='Укажите папки назначения и подготовки.'; Exit; end;
  Start(tpPreview);
end;

procedure TfrmCollectionTransfer.Run(Sender:TObject);
begin if ReleaseView then Start(tpRun); end;

procedure TfrmCollectionTransfer.Stop(Sender:TObject);
begin
  if FWorker<>nil then begin FWorker.RequestStop; FStage.Caption:='Остановка. Текущие безопасные этапы завершатся…'; end
  else if FState=usWaiting then begin SetState(usStopped,'Завершение отложено. Нажмите «Продолжить» позже.'); FRun.Caption:='Продолжить'; end;
end;

procedure TfrmCollectionTransfer.Pin(Sender:TObject);
begin
  if FormStyle=fsStayOnTop then begin FormStyle:=fsNormal; FPin.Caption:='Поверх окон'; end
  else begin FormStyle:=fsStayOnTop; FPin.Caption:='Открепить'; end;
end;

procedure TfrmCollectionTransfer.CloseClick(Sender:TObject);
begin Close; end;

procedure TfrmCollectionTransfer.CloseQuery(Sender:TObject; var CanClose:Boolean);
begin
  CanClose:=FWorker=nil;
  if not CanClose then begin FCloseAfterStop:=True; Stop(nil); end;
end;

procedure TfrmCollectionTransfer.Tick(Sender:TObject);
begin
  TInterlocked.Exchange(FContext.ReadyFlag,Ord(FReady()));
  if FWorker<>nil then
  begin
    var Current:=FWorker.Status;
    if Current.Stage<>'' then
    begin
      FStage.Caption:=Current.Stage;
      if (Current.Total=0) and (Current.Done>0) then FStage.Caption:=FStage.Caption+' — '+IntToStr(Current.Done)
      else if Current.GroupsTotal>0 then FStage.Caption:=FStage.Caption+Format(' (%d из %d групп)',[Current.GroupsDone,Current.GroupsTotal]);
    end;
    FSource.Caption:=Current.FileName; FSource.Hint:=Current.FileName; FSource.ShowHint:=True;
    if Current.Total>0 then
    begin FBar.Style:=pbstNormal; FBar.Position:=EnsureRange(Round(100.0*Current.Done/Current.Total),0,100); end;
    if FWorker.Done then Finished;
  end
  else if (FState=usWaiting) and FReady() then Start(tpComplete);
end;

procedure TfrmCollectionTransfer.Finished;
begin
  var Previous:=FState; FWorker.WaitFor; var Cancelled:=FWorker.Cancelled;
  FreeAndNil(FWorker); FBar.Style:=pbstNormal;
  if Cancelled and (Previous<>usCompleting) and (FContext.Error='') then
    FContext.Error:='Остановлено. Нажмите «Продолжить» позже.';
  if FContext.Error<>'' then FReport.Lines.Add(sLineBreak+FContext.Error);
  if Previous=usPreview then
  begin
    if FContext.Error<>'' then SetState(usFailed,FContext.Error)
    else
    begin
      FReport.Lines.Text:=Format('Физических файлов и архивов: %d. Требует копирования: %d (%s).'+sLineBreak+
        'Недоступных записей: %d. Их ожидаемые адреса сохранятся для последующего обновления.'+sLineBreak+
        'Ниже показано до 200 файлов. Сведения о совместно используемых файлах приведены рядом с путями.'+sLineBreak,
        [FContext.Files,FContext.CopyFiles,BookEstimateSizeText(FContext.CopyBytes),FContext.Missing]);
      for var Line in FContext.PreviewLines do FReport.Lines.Add(Line);
      FReport.SelStart:=0; FReport.Perform(EM_SCROLLCARET,0,0);
      SetState(usReady,'План готов. Проверьте папки и нажмите «Перенести».');
      if FContext.Files=0 then FStage.Caption:='Доступных файлов для переноса не найдено. Проверьте подключение папок книг.';
    end;
  end
  else if Previous=usRunning then
  begin
    try RefreshView;
    except on E:Exception do FContext.Error:=FContext.Error+sLineBreak+'Не удалось обновить открытый каталог: '+E.Message; end;
    if FContext.Journal=nil then begin FreeAndNil(FContext.Plan); FreeAndNil(FContext.Capture); end;
    if (FContext.Journal<>nil) or (FContext.Pending.Operation<>'') then FRun.Caption:='Продолжить'
    else FRun.Caption:='Перенести';
    if FContext.Error<>'' then SetState(usStopped,FContext.Error)
    else if FContext.RootsReady then SetState(usWaiting,'Файлы обработаны. Ожидание обновления открытой коллекции…')
    else SetState(usStopped,'Освобождение исходных файлов отложено. Закройте внешнюю читалку и нажмите «Продолжить».');
  end
  else if Previous=usCompleting then
  begin
    if FContext.Error<>'' then
    begin
      var Saved:TTransferCompletionResult;
      try
        if ReadTransferCompletion(FContext.Journal,Saved) then begin FContext.Outcome:=Saved; FContext.Error:=''; end;
      except on E:Exception do FContext.Error:=FContext.Error+sLineBreak+E.Message; end;
    end;
    if FContext.Error<>'' then SetState(usStopped,FContext.Error)
    else
    begin
      var Result:=FContext.Outcome;
      FReport.Text:=Format('Перенос завершён.'+sLineBreak+'Обработано физических файлов: %d (%s).'+sLineBreak+
        'Прежних файлов освобождено: %d. Уже отсутствовали: %d. Сохранены: %d.'+sLineBreak+sLineBreak+
        'Источники обновлений, личные данные и история чтения сохранены.'+sLineBreak,
        [Result.Files,BookEstimateSizeText(Result.Bytes),Result.Removed,Result.Missing,Result.Retained]);
      FReport.Lines.Add(sLineBreak+Format('Удалено рабочих файлов: %d (%s данных).',
        [FContext.Cleanup.FilesRemoved,BookEstimateSizeText(FContext.Cleanup.BytesRemoved)]));
      if FContext.Cleanup.Stopped or (FContext.Cleanup.DirectoriesRetained>0) or (FContext.Cleanup.Warning<>'') then
        FReport.Lines.Add('Уборка оставшихся рабочих снимков будет повторена при следующем запуске.'+sLineBreak+FContext.Cleanup.Warning);
      try
        AppendSharedTransferCatalogues(FContext.Journal.Review, FContext.Info.ID, True, FReport.Lines);
        FCompletionText := FReport.Text;
        WriteRetainedSources(8, procedure(Line: string) begin FReport.Lines.Add(Line); end);
        if Result.Retained > 8 then FReport.Lines.Add('Остальные пути доступны в полном отчёте.');
      except
        on E: Exception do
        begin
          FCompletionText := FReport.Text;
          FReport.Lines.Add('Не удалось прочитать подробности переноса. ' + E.Message);
        end;
      end;
      FReport.SelStart := 0; FReport.Perform(EM_SCROLLCARET, 0, 0);
      SetState(usCompleted,'Перенос завершён. Открытая коллекция обновлена.');
      FSource.Caption:=FContext.Destination;
      FormStyle:=fsStayOnTop; FPin.Caption:='Открепить'; BringToFront;
    end;
  end;
  if FCloseAfterStop then Close;
end;

procedure ShowCollectionTransfer(Owner:TCustomForm; const Info:TCollectionInfo; const PersonalFile:string;
  const Pending:TRegisteredCollectionTransfer; const ReleaseCollection,RefreshCollection:TProc;
  const ApplicationReady:TFunc<Boolean>);
begin
  var Dialog:=TfrmCollectionTransfer.CreateFor(Owner,Info,PersonalFile,Pending,ReleaseCollection,RefreshCollection,ApplicationReady);
  var Restore:Boolean;
  try Dialog.ShowModal;
  finally
    Restore:=Dialog.FReleased; Dialog.Free;
    if Restore then RefreshCollection();
  end;
end;

end.
