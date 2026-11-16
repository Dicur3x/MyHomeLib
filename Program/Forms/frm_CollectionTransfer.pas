unit frm_CollectionTransfer;

interface

uses System.Classes, System.SysUtils, System.Generics.Collections, Vcl.Forms, Vcl.Controls,
  Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, unit_Globals, unit_CollectionTransferRegistry;

procedure ShowCollectionTransfer(Owner:TCustomForm; const Info:TCollectionInfo; const PersonalFile:string;
  const Pending:TRegisteredCollectionTransfer; const ReleaseCollection,RefreshCollection:TProc;
  const ApplicationReady:TFunc<Boolean>);

implementation

uses Winapi.Windows, Winapi.ActiveX, System.IOUtils, System.SyncObjs, System.Math,
  Vcl.Dialogs, Vcl.Clipbrd, unit_Settings, dm_user, unit_MHLTheme, unit_BookEstimateReport,
  unit_CollectionTransferCatalogue, unit_CollectionTransferPlan, unit_CollectionTransferJournal,
  unit_CollectionTransferOperation, unit_CollectionTransferCompletion;

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
    constructor Create;
    destructor Destroy; override;
    function Cancelled:Boolean;
    procedure Progress(const Stage,Source:string; GroupsDone,GroupsTotal,Done,Total:Int64);
    procedure CatalogueProgress(Count:Int64);
    function Status:TTransferUIStatus;
    procedure BeginPhase;
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
    FReleased,FCloseAfterStop,FLayoutBusy:Boolean;
    FDestination,FWork:TEdit;
    FChooseDestination,FChooseWork,FPreview,FRun,FStop,FClose,FPin:TButton;
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
  public
    procedure ScaleForPPI(NewPPI:Integer); override;
    constructor CreateFor(Owner:TCustomForm; const Info:TCollectionInfo; const Personal:string;
      const Pending:TRegisteredCollectionTransfer; const ReleaseCollection,RefreshCollection:TProc;
      const ApplicationReady:TFunc<Boolean>);
    destructor Destroy; override;
  end;

constructor TTransferUIContext.Create;
begin inherited; FLock:=TObject.Create; end;

destructor TTransferUIContext.Destroy;
begin Journal.Free; Plan.Free; Capture.Free; FLock.Free; inherited; end;

function TTransferUIContext.Cancelled:Boolean;
begin Result:=TInterlocked.CompareExchange(CancelFlag,0,0)<>0; end;

procedure TTransferUIContext.BeginPhase;
begin
  TInterlocked.Exchange(CancelFlag,0);
  System.TMonitor.Enter(FLock);
  try FStatus:=Default(TTransferUIStatus); finally System.TMonitor.Exit(FLock); end;
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
      var SystemRoot:=GetEnvironmentVariable('SystemDrive'); if SystemRoot='' then SystemRoot:='C:';
      var FreeBytes,TotalBytes:UInt64;
      if not GetDiskFreeSpaceEx(PChar(IncludeTrailingPathDelimiter(SystemRoot)),FreeBytes,TotalBytes,nil) then RaiseLastOSError;
      if FreeBytes<UInt64(8)*1024*1024*1024 then
        raise EWriteError.Create('На системном диске нужно оставить не менее 8 ГБ. Готовые данные и журнал сохраняются.');
      case FPhase of
        tpPreview:
          begin
            FreeAndNil(FContext.Plan); FreeAndNil(FContext.Capture);
            if not DirectoryExists(FContext.Destination) then
              raise EDirectoryNotFoundException.Create('Выберите существующую папку назначения.');
            ForceDirectories(FContext.WorkRoot);
            FContext.Capture:=TCollectionTransferCatalogue.Create(FContext.Info,FContext.Personal,FContext.WorkRoot,
              function:Boolean begin Result:=Context.Cancelled; end,
              procedure(Count:Int64) begin Context.CatalogueProgress(Count); end);
            if Cancelled then Abort;
            FContext.Plan:=FContext.Capture.BuildFilePlan(FContext.Destination,FContext.WorkRoot,TGUID.NewGuid);
            FContext.Files:=FContext.Plan.FileCount; FContext.CopyFiles:=FContext.Plan.CopyFileCount;
            FContext.CopyBytes:=FContext.Plan.CopyBytes; FContext.Missing:=FContext.Capture.Count(tbsMissing);
            var Lines:=TList<string>.Create;
            try
              FContext.Plan.ForEachFile(procedure(const Item:TCollectionTransferFile)
                begin
                  if Cancelled then Abort;
                  if Lines.Count<200 then Lines.Add(Item.Source+sLineBreak+'  → '+Item.Destination);
                end);
              FContext.PreviewLines:=Lines.ToArray;
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
          FContext.Outcome:=FContext.Journal.CompleteTransfer(FReady,Cancelled);
      end;
    except
      on E:EAbort do begin FContext.Stopped:=True; FContext.Error:='Остановлено. Готовые копии и журнал сохранены.'; end;
      on E:Exception do FContext.Error:=E.Message;
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
    'Прежний файл освобождается только после проверки копии и сохранения адресов. Общие или занятые исходники могут остаться.',12,12,776,70);
  FDestinationLabel:=LabelAt('Папка назначения:',12,90,776,20);
  FDestination:=TEdit.Create(Self); FDestination.Parent:=Self; FDestination.Name:='TransferDestination';
  FDestination.SetBounds(12,112,650,25); FDestination.Anchors:=[akLeft,akTop,akRight];
  FDestination.Text:=Settings.ExpandCollectionRoot(Info.RootFolder);
  FChooseDestination:=Button('ChooseTransferDestination','Выбрать…',674,110,114,ChooseFolder);
  FChooseDestination.Anchors:=[akTop,akRight];
  FWorkLabel:=LabelAt('Рабочая папка для журнала и подготовки:',12,146,776,20);
  FWork:=TEdit.Create(Self); FWork.Parent:=Self; FWork.Name:='TransferWorkRoot';
  FWork.SetBounds(12,168,650,25); FWork.Anchors:=[akLeft,akTop,akRight];
  FWork.Text:=TPath.Combine(ExcludeTrailingPathDelimiter(FDestination.Text),'.homelibre-transfer-work');
  FChooseWork:=Button('ChooseTransferWorkRoot','Выбрать…',674,166,114,ChooseFolder); FChooseWork.Anchors:=[akTop,akRight];
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
  FClose:=Button('CloseCollectionTransfer','Закрыть',668,598,120,CloseClick);
  for var B in [FPreview,FRun,FStop,FPin,FClose] do B.Anchors:=[akLeft,akBottom];
  FClose.Anchors:=[akRight,akBottom]; FClose.Cancel:=True;
  FTimer:=TTimer.Create(Self); FTimer.Interval:=100; FTimer.OnTimer:=Tick;
  OnCloseQuery:=CloseQuery; ApplyMHLControlTheme(Self);
  if Pending.Operation<>'' then
  begin
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
    var W:=ClientWidth; var Gap:=Px(12); var ChooseWidth:=Px(114);
    FHelp.SetBounds(Gap,Px(12),W-2*Gap,Px(70));
    FDestinationLabel.SetBounds(Gap,Px(90),W-2*Gap,Px(20));
    FWorkLabel.SetBounds(Gap,Px(146),W-2*Gap,Px(20));
    FDestination.SetBounds(Gap,Px(112),W-3*Gap-ChooseWidth,Px(25));
    FWork.SetBounds(Gap,Px(168),FDestination.Width,Px(25));
    FChooseDestination.SetBounds(W-Gap-ChooseWidth,Px(110),ChooseWidth,Px(30));
    FChooseWork.SetBounds(W-Gap-ChooseWidth,Px(166),ChooseWidth,Px(30));
    FStage.SetBounds(Gap,Px(207),W-2*Gap,Px(38));
    FSource.SetBounds(Gap,Px(248),W-2*Gap,Px(22));
    FBar.SetBounds(Gap,Px(276),W-2*Gap,Px(15));
    var RunTop:=ClientHeight-Px(86); var CloseTop:=ClientHeight-Px(42);
    FReport.SetBounds(Gap,Px(304),W-2*Gap,Max(Px(40),RunTop-Px(316)));
    FPreview.SetBounds(Gap,RunTop,Px(160),Px(30));
    FRun.SetBounds(Px(184),RunTop,Px(160),Px(30));
    FStop.SetBounds(Px(356),RunTop,Px(140),Px(30));
    FPin.SetBounds(Gap,CloseTop,Px(160),Px(30));
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
  FPreview.Enabled:=not Busy and not Frozen and (Value<>usCompleted);
  FRun.Enabled:=not Busy and (Value<>usCompleted) and (((FContext.Plan<>nil) and (FContext.Files>0)) or Frozen);
  FStop.Enabled:=Busy; FClose.Enabled:=True;
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
    if Sender=FChooseWork then FWork.Text:=Dialog.FileName
    else
    begin
      FDestination.Text:=Dialog.FileName; FWork.Text:=TPath.Combine(Dialog.FileName,'.homelibre-transfer-work');
    end;
    FreeAndNil(FContext.Plan); FreeAndNil(FContext.Capture); SetState(usIdle,'Папка изменена. Проверьте новый план.');
  finally Dialog.Free; end;
end;

procedure TfrmCollectionTransfer.LocationChanged(Sender:TObject);
begin
  if (FWorker<>nil) or (FContext.Journal<>nil) or (FContext.Pending.Operation<>'') then Exit;
  FreeAndNil(FContext.Plan); FreeAndNil(FContext.Capture);
  SetState(usIdle,'Папки изменены. Проверьте новый план.');
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
        'Ниже показано до 200 файлов. Общие исходники сохраняются, если нужны другой коллекции.'+sLineBreak,
        [FContext.Files,FContext.CopyFiles,BookEstimateSizeText(FContext.CopyBytes),FContext.Missing]);
      for var Line in FContext.PreviewLines do FReport.Lines.Add(Line);
      SetState(usReady,'План готов. Проверьте папки и нажмите «Перенести».');
      if FContext.Files=0 then FStage.Caption:='Доступных файлов для переноса не найдено. Проверьте подключение папок книг.';
    end;
  end
  else if Previous=usRunning then
  begin
    try RefreshView;
    except on E:Exception do FContext.Error:=FContext.Error+sLineBreak+'Не удалось обновить открытый каталог: '+E.Message; end;
    if FContext.Journal=nil then begin FreeAndNil(FContext.Plan); FreeAndNil(FContext.Capture); end;
    FRun.Caption:='Продолжить';
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
        'Книги не перепаковывались. Источники обновлений, личные данные и история чтения сохранены.'+sLineBreak+
        'Общие, занятые или изменённые исходники могли остаться на прежних местах.',
        [Result.Files,BookEstimateSizeText(Result.Bytes),Result.Removed,Result.Missing,Result.Retained]);
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
