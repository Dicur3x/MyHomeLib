(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2023 Oleksiy Penkov (aka Koreec)
  *
  * Authors             Oleksiy Penkov   oleksiy.penkov@gmail.com
  *                     Nick Rymanov     nrymanov@gmail.com
  * Created             
  * Description         
  *
  * $Id: unit_DownloadManagerThread.pas 953 2011-02-18 02:12:22Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_DownloadManagerThread;

interface

uses
  Classes,
  Forms,
  SyncObjs,
  VirtualTrees,
  unit_Globals,
  unit_Downloader,
  unit_Interfaces;

type
  TDownloadManagerThread = class(TThread)
  private
    FDownloader : TDownloader;
    FDownloaderLock: TCriticalSection;

    FCanceled : boolean;
    FFinished : boolean;
    FIgnoreErrors : boolean;

    FProcessed: integer;
    FTotal: integer;

    FBookKey: TBookKey;

    FCurrentNode : PVirtualNode;
    FCurrentData : PDownloadData;

    FError : boolean;
    FControlState: boolean;
    FCurrentComment: string;
    FCurrentProgress: Integer;
    FDialogResult: Integer;
    FThreadError: string;

    procedure DoSetComment;
    procedure DoSetProgress;
    procedure DoShowThreadError;
    procedure AskIgnoreErrors;
    procedure SetDownloader(const Downloader: TDownloader);
    procedure ClearDownloader(const Downloader: TDownloader);
    procedure StopDownloader;
    function WaitCancelable(Milliseconds: Integer): Boolean;

  protected
    procedure SetComment(const Current, Total: string);
    procedure SetProgress(Current, Total: Integer);
    procedure GetCurrentFile;
    procedure Finished;
    procedure Canceled;
    procedure Execute; override;
    procedure WorkFunction;

    procedure SetControlsState;

  public
    constructor Create(CreateSuspended: Boolean); reintroduce;
    destructor Destroy; override;

    procedure Stop;
    procedure TerminateNow;
   end;

implementation

uses
  frm_main,
  SysUtils,
  DateUtils,
  IdStack,
  IdStackConsts,
  IdException,
  Windows,
  dm_user,
  IdMultipartFormData;

resourcestring
rstrDone = 'Готово';
  rstrConnecting = 'Подключение...';
  rstrConnectingWithInfo = '%s %s %s Подключение...';
  rstrDownloading = '%s. %s %s Загрузка: %s Kb/s %d %%';
  rstrIgnoreDownloadErrors = 'Игнорировать ошибки загрузки?';
  rstrDownloadError = 'Ошибка закачки';

constructor TDownloadManagerThread.Create(CreateSuspended: Boolean);
begin
  // Create the lifecycle lock before TThread can start Execute.
  FDownloaderLock := TCriticalSection.Create;
  try
    inherited Create(CreateSuspended);
  except
    FreeAndNil(FDownloaderLock);
    raise;
  end;
  FreeOnTerminate := False;
end;

destructor TDownloadManagerThread.Destroy;
begin
  TerminateNow;
  try
    // TThread.Destroy waits for Execute to finish. The lifecycle lock must stay
    // alive because the worker detaches FDownloader from its finally block.
    inherited Destroy;
  finally
    FreeAndNil(FDownloaderLock);
  end;
end;

procedure TDownloadManagerThread.SetDownloader(const Downloader: TDownloader);
begin
  FDownloaderLock.Acquire;
  try
    Assert(not Assigned(FDownloader));
    FDownloader := Downloader;
  finally
    FDownloaderLock.Release;
  end;
end;

procedure TDownloadManagerThread.ClearDownloader(const Downloader: TDownloader);
begin
  FDownloaderLock.Acquire;
  try
    if FDownloader = Downloader then
      FDownloader := nil;
  finally
    FDownloaderLock.Release;
  end;
end;

procedure TDownloadManagerThread.StopDownloader;
begin
  if not Assigned(FDownloaderLock) then
    Exit;

  FDownloaderLock.Acquire;
  try
    if Assigned(FDownloader) then
      FDownloader.Stop;
  finally
    FDownloaderLock.Release;
  end;
end;

procedure TDownloadManagerThread.TerminateNow;
begin
  FCanceled := True;
  Terminate;
  StopDownloader;
end;
procedure TDownloadManagerThread.Canceled;
begin
  if Assigned(FCurrentData) then
    FCurrentData.State := dsError;
  if Assigned(FCurrentNode) then
    frmMain.tvDownloadList.RepaintNode(FCurrentNode);

  frmMain.pbDownloadProgress.Position := 0;
  frmMain.lblDownloadState.Caption := rstrDone;
  frmMain.lblDnldAuthor.Caption := '';
  frmMain.lblDnldTitle.Caption :=  '';

  frmMain.btnPauseDownload.Enabled := False;
  frmMain.btnStartDownload.Enabled := True;
end;

procedure TDownloadManagerThread.AskIgnoreErrors;
begin
  FDialogResult := Application.MessageBox(PWideChar(rstrIgnoreDownloadErrors),
    '', MB_YESNOCANCEL);
end;

procedure TDownloadManagerThread.DoSetComment;
begin
  frmMain.lblDownloadState.Caption := FCurrentComment;
end;

procedure TDownloadManagerThread.DoSetProgress;
begin
  if frmMain.Visible then
    frmMain.pbDownloadProgress.Position := FCurrentProgress
  else if Assigned(FCurrentData) then
    frmMain.TrayIcon.Hint := Format(rstrDownloading,
      [FCurrentData.Author, FCurrentData.Title, CRLF, '', FCurrentProgress]);
end;

procedure TDownloadManagerThread.DoShowThreadError;
begin
  Application.MessageBox(PChar(FThreadError), PChar(rstrDownloadError),
    MB_OK or MB_ICONERROR);
end;

procedure TDownloadManagerThread.Execute;
begin
  try
    WorkFunction;
  except
    on E: Exception do
    begin
      FThreadError := E.Message;
      FCanceled := True;
      FControlState := True;
      if not Terminated then
        Synchronize(DoShowThreadError);
      Synchronize(Canceled);
      Synchronize(SetControlsState);
    end;
  end;
end;

procedure TDownloadManagerThread.Finished;
var
  node: PVirtualNode;
begin
  if FCurrentData <> nil then
    if Not FError then
    begin
      FCurrentData.State := dsOk ;

      // Need to search before delete, to prevent Access Violation
      node := frmMain.tvDownloadList.GetFirst;
      while Assigned(node) do
      begin
        if node = FCurrentNode then
        begin
          frmMain.tvDownloadList.DeleteNode(FCurrentNode);
          break;
        end;
        node := frmMain.tvDownloadList.GetNext(node);
      end;

      FCurrentNode := nil;
      FCurrentData := nil;
      inc(FProcessed);
    end
    else
    begin
      FCurrentData.State := dsError;
      frmMain.tvDownloadList.RepaintNode(FCurrentNode);
    end;

  frmMain.pbDownloadProgress.Position := 0;
  frmMain.lblDownloadState.Caption := rstrDone;
  frmMain.lblDnldAuthor.Caption := '';
  frmMain.lblDnldTitle.Caption :=  '';

  frmMain.lblDownloadCount.Caption := Format('(%d)',[frmMain.tvDownloadList.ChildCount[Nil]]);

  if FFinished then
  begin
    frmMain.pbDownloadProgress.Visible := False;
    frmMain.btnPauseDownload.Enabled := False;
    frmMain.btnStartDownload.Enabled := True;
  end;
end;

procedure TDownloadManagerThread.GetCurrentFile;
var
  ErrorCount : integer;

begin
  FFinished := True;
  if FCanceled then Exit;

  if FCurrentNode <> nil then
    FCurrentNode := frmMain.tvDownloadList.GetNext(FCurrentNode);
  if FCurrentNode = nil then
  begin
    ErrorCount := 0;
    FCurrentNode := frmMain.tvDownloadList.GetFirst;
    FCurrentData := frmMain.tvDownloadList.GetNodeData(FCurrentNode);
    while (FCurrentData <> nil) and
          ((FCurrentData.State = dsError) and (FCurrentNode <> nil)) do
    begin
      FCurrentNode := frmMain.tvDownloadList.GetNext(FCurrentNode);
      FCurrentData := frmMain.tvDownloadList.GetNodeData(FCurrentNode);
      Inc(ErrorCount);
    end;

    if (ErrorCount > 0) and (FCurrentNode = Nil) then
        FCurrentNode := frmMain.tvDownloadList.GetFirst;

  end;

  while FCurrentNode <> nil do
  begin
    FCurrentData := frmMain.tvDownloadList.GetNodeData(FCurrentNode);
    if FCurrentData.State <> dsOk then
    begin
      FBookKey := FCurrentData^.BookKey;

      FCurrentData.State := dsRun;
      frmMain.tvDownloadList.RepaintNode(FCurrentNode);

      if frmMain.Visible then
      begin
        frmMain.lblDownloadState.Caption := rstrConnecting;
        frmMain.lblDnldAuthor.Caption := FCurrentData.Author;
        frmMain.lblDnldTitle.Caption := FCurrentData.Title;
        frmMain.pbDownloadProgress.Visible := True;
      end
      else
        frmMain.TrayIcon.Hint := Format(rstrConnectingWithInfo,
                                            [FCurrentData.Author,
                                             FCurrentData.Title,
                                             CRLF]);
      frmMain.btnPauseDownload.Enabled := True;
      frmMain.btnStartDownload.Enabled := False;

      frmMain.TrayIcon.Hint := 'MyHomeLib';

      FFinished := False;
      Break;
    end;
    FCurrentNode := frmMain.tvDownloadList.GetNext(FCurrentNode);
  end;
end;


procedure TDownloadManagerThread.SetComment(const Current, Total: string);
begin
  FCurrentComment := Current;
  Synchronize(DoSetComment);
end;

procedure TDownloadManagerThread.SetControlsState;
begin
  frmMain.BtnFirstRecord.Enabled := FControlState;
  frmMain.BtnDwnldUp.Enabled := FControlState;
  frmMain.BtnDwnldDown.Enabled := FControlState;
  frmMain.BtnLastRecord.Enabled := FControlState;

//  frmMain.BtnDelete.Enabled := FControlState;
  frmMain.BtnSave.Enabled := FControlState;

  frmMain.mi_dwnl_Delete.Enabled := FControlState;
end;

procedure TDownloadManagerThread.SetProgress(Current, Total: Integer);
begin
  FCurrentProgress := Current;
  Synchronize(DoSetProgress);
end;
procedure TDownloadManagerThread.Stop;
begin
  FCanceled := True;
  Terminate;
  StopDownloader;
  Synchronize(Canceled);
  FControlState := True;
  Synchronize(SetControlsState);
end;

function TDownloadManagerThread.WaitCancelable(Milliseconds: Integer): Boolean;
const
  WAIT_SLICE_MS = 100;
var
  Delay: Integer;
begin
  while (Milliseconds > 0) and not FCanceled and not Terminated do
  begin
    Delay := Milliseconds;
    if Delay > WAIT_SLICE_MS then
      Delay := WAIT_SLICE_MS;
    Sleep(Delay);
    Dec(Milliseconds, Delay);
  end;
  Result := not FCanceled and not Terminated;
end;

procedure TDownloadManagerThread.WorkFunction;
var
  Res: integer;
  FSystemDB: ISystemData;
  Downloader: TDownloader;
begin
  FSystemDB := DMUser.GetSystemDBConnection;
  try
    FControlState := False;
    Synchronize(SetControlsState);

    FIgnoreErrors := False;
    FError := False;

    FProcessed := 0;

    Downloader := TDownloader.Create;
    try
      SetDownloader(Downloader);
      Downloader.OnSetComment := SetComment;
      Downloader.OnProgress := SetProgress;
      try
        Synchronize(GetCurrentFile);
        while not FFinished and not FCanceled and not Terminated do
        begin
          if FError then
            if not WaitCancelable(30000) then
              Break;
          if not WaitCancelable(Settings.DwnldInterval) then
            Break;
          Downloader.IgnoreErrors := FIgnoreErrors;
          FError := not Downloader.Download(FSystemDB, FBookKey);
          if FCanceled or Terminated then
            Break;
          Synchronize(Finished);

          Synchronize(GetCurrentFile);
          if FError and not FIgnoreErrors and not FCanceled then
          begin
            Synchronize(AskIgnoreErrors);
            Res := FDialogResult;
            FCanceled := (Res = IDCANCEL);
            FIgnoreErrors := (Res = IDYES);
            if FCanceled then
            begin
              Terminate;
              Synchronize(Canceled);
            end;
          end;
        end;
      finally
        FControlState := True;
        Synchronize(SetControlsState);
      end;
    finally
      ClearDownloader(Downloader);
      FreeAndNil(Downloader);
    end;
    if not FCanceled and not Terminated then
      Synchronize(Finished);
  finally
    FSystemDB.ClearCollectionCache;
    FSystemDB := nil;
  end;
end;

end.
