(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
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
  SyncObjs,
  unit_Globals,
  unit_Downloader,
  unit_DownloadView,
  unit_Interfaces;

type
  //
  // Менеджер очереди загрузок.
  //
  // Поток не знает ни о главной форме, ни о дереве очереди: все общение
  // с интерфейсом идет через IDownloadView и только в пределах Synchronize.
  //
  TDownloadManagerThread = class(TThread)
  private
    FView: IDownloadView;
    FDownloader : TDownloader;
    FDownloaderLock: TCriticalSection;

    FCanceled : boolean;
    FFinished : boolean;
    FIgnoreErrors : boolean;

    FProcessed: integer;

    FCurrentItem: TDownloadItem;
    FHasCurrentItem: Boolean;

    FError : boolean;

    //
    // Обертки над IDownloadView: каждая выполняется в главном потоке.
    //
    procedure ShowState(const State: string);
    procedure ShowProgress(Position: Integer);
    procedure ShowCurrentItem;
    procedure SetQueueControlsEnabled(Enabled: Boolean);
    function AskIgnoreErrors: Integer;

    //
    // Шаги очереди
    //
    procedure SelectNextFile;
    procedure FinishCurrentFile;
    procedure CancelCurrentFile;

    procedure InterruptibleSleep(Milliseconds: Integer);
    procedure SetDownloader(const Downloader: TDownloader);
    procedure ClearDownloader(const Downloader: TDownloader);
    procedure StopDownloader;

    //
    // Обратные вызовы загрузчика. Приходят из фонового потока, поэтому
    // внутри только Synchronize.
    //
    procedure SetComment(const Current, Total: string);
    procedure SetProgress(Current, Total: Integer);

  protected
    procedure Execute; override;
    procedure WorkFunction;

  public
    constructor Create(const View: IDownloadView);
    destructor Destroy; override;

    procedure Stop;
    procedure TerminateNow;
   end;

implementation

uses
  SysUtils,
  DateUtils,
  Math,
  Windows,
  dm_user,
  unit_Consts;

resourcestring
rstrConnecting = 'Подключение...';
  rstrConnectingWithInfo = '%s %s %s Подключение...';
  rstrDownloading = '%s. %s %s Загрузка: %s КБ/с %d %%';

constructor TDownloadManagerThread.Create(const View: IDownloadView);
begin
  //
  // Создаем приостановленным: поток не должен стартовать, пока не получит View.
  //
  inherited Create(True);
  FDownloaderLock := TCriticalSection.Create;
  try
    Assert(Assigned(View));
    FView := View;
    FCanceled := False;
    Start;
  except
    FreeAndNil(FDownloaderLock);
    raise;
  end;
end;

destructor TDownloadManagerThread.Destroy;
begin
  TerminateNow;
  try
    // TThread.Destroy waits for Execute. Keep the lock alive until the worker
    // has detached its downloader in WorkFunction's finally block.
    inherited Destroy;
  finally
    FreeAndNil(FDownloaderLock);
  end;
end;

procedure TDownloadManagerThread.SetDownloader(const Downloader: TDownloader);
begin
  FDownloaderLock.Acquire;
  try
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
  try
    //
    // Загрузчика может уже не быть: поток мог завершить работу сам.
    //
    FCanceled := True;
    StopDownloader;
    Terminate;
  except
    on EAbort do ; // swallow thread-termination abort; rethrow everything else
  end;
end;

//
// Пауза, которую можно прервать.
//
// Обычный Sleep заставил бы и закрытие программы, и перезапуск очереди ожидать до
// 30 секунд - именно столько длится пауза после ошибки загрузки.
//
procedure TDownloadManagerThread.InterruptibleSleep(Milliseconds: Integer);
const
  SLICE = 100;
var
  Elapsed: Integer;
begin
  Elapsed := 0;
  while (Elapsed < Milliseconds) and not Terminated and not FCanceled do
  begin
    Sleep(Min(SLICE, Milliseconds - Elapsed));
    Inc(Elapsed, SLICE);
  end;
end;

//
// - - - - - - - - - - - Обёртки над представлением - - - - - - - - - - - - - -
//

procedure TDownloadManagerThread.ShowState(const State: string);
begin
  Synchronize(
    procedure
    begin
      FView.ShowDownloadState(State);
    end
  );
end;

procedure TDownloadManagerThread.ShowProgress(Position: Integer);
begin
  Synchronize(
    procedure
    begin
      if FView.IsMainFormVisible then
        FView.ShowDownloadProgress(Position)
      else
        FView.SetTrayHint(Format(rstrDownloading,
                                 [FCurrentItem.Author,
                                  FCurrentItem.Title,
                                  CRLF,
                                  '',
                                  Position]));
    end
  );
end;

procedure TDownloadManagerThread.ShowCurrentItem;
begin
  Synchronize(
    procedure
    begin
      if FView.IsMainFormVisible then
      begin
        FView.ShowDownloadState(rstrConnecting);
        FView.ShowDownloadInfo(FCurrentItem.Author, FCurrentItem.Title);
      end
      else
        FView.SetTrayHint(Format(rstrConnectingWithInfo,
                                 [FCurrentItem.Author,
                                  FCurrentItem.Title,
                                  CRLF]));

      FView.SetDownloadRunning(True);
    end
  );
end;

procedure TDownloadManagerThread.SetQueueControlsEnabled(Enabled: Boolean);
begin
  Synchronize(
    procedure
    begin
      FView.SetQueueControlsEnabled(Enabled);
    end
  );
end;

function TDownloadManagerThread.AskIgnoreErrors: Integer;
var
  Res: Integer;
begin
  Synchronize(
    procedure
    begin
      Res := FView.AskIgnoreDownloadErrors;
    end
  );
  Result := Res;
end;

//
// - - - - - - - - - - - - - - - Шаги очереди - - - - - - - - - - - - - - - - - -
//

procedure TDownloadManagerThread.SelectNextFile;
var
  HasItem: Boolean;
  Item: TDownloadItem;
begin
  FFinished := True;
  if FCanceled then
    Exit;

  Synchronize(
    procedure
    begin
      HasItem := FView.SelectNextDownload(Item);
    end
  );

  FHasCurrentItem := HasItem;
  if not HasItem then
    Exit;

  FCurrentItem := Item;
  FFinished := False;
  ShowCurrentItem;
end;

procedure TDownloadManagerThread.FinishCurrentFile;
var
  Success: Boolean;
  HadItem: Boolean;
begin
  HadItem := FHasCurrentItem;
  Success := not FError;
  if HadItem and Success then
    Inc(FProcessed);

  Synchronize(
    procedure
    begin
      if HadItem then
        FView.CompleteCurrentDownload(Success);
      FView.ResetDownloadState;
      FView.SetDownloadRunning(False);
    end
  );

  if Success then
    FHasCurrentItem := False;
end;

procedure TDownloadManagerThread.CancelCurrentFile;
begin
  Synchronize(
    procedure
    begin
      FView.CancelCurrentDownload;
      FView.ResetDownloadState;
      FView.SetDownloadRunning(False);
    end
  );
end;

//
// - - - - - - - - - - - Обратные вызовы загрузчика - - - - - - - - - - - - -
//

procedure TDownloadManagerThread.SetComment(const Current, Total: string);
begin
  ShowState(Current);
end;

procedure TDownloadManagerThread.SetProgress(Current, Total: Integer);
begin
  ShowProgress(Current);
end;

//
// - - - - - - - - - - - - - - - - Робота - - - - - - - - - - - - - - - - - - - -
//

procedure TDownloadManagerThread.Execute;
begin
  WorkFunction;
end;

procedure TDownloadManagerThread.Stop;
begin
  FCanceled := True;
  StopDownloader;
  CancelCurrentFile;
  SetQueueControlsEnabled(True);
  Terminate;
end;

procedure TDownloadManagerThread.WorkFunction;
var
  Res: integer;
  FSystemDB: ISystemData;
  Downloader: TDownloader;
begin
  FSystemDB := DMUser.GetSystemDBConnection;
  try
    SetQueueControlsEnabled(False);

    FIgnoreErrors := False;
    FError := False;

    FProcessed := 0;

    Downloader := TDownloader.Create;
    SetDownloader(Downloader);
    try
      Downloader.OnSetComment := SetComment;
      Downloader.OnProgress := SetProgress;
      try
        SelectNextFile;
        //
        // Ничего не качаем, пока очередь не выдала книгу: иначе первый проход
        // пошел бы загружать пустой ключ.
        //
        while not (FFinished or FCanceled) do
        begin
          if FError then
            InterruptibleSleep(30000);
          InterruptibleSleep(Settings.DwnldInterval);
          Downloader.IgnoreErrors := FIgnoreErrors;
          FError := not Downloader.Download(FSystemDB, FCurrentItem.BookKey);
          FinishCurrentFile;

          SelectNextFile;
          if FError and not FIgnoreErrors and not FCanceled then
          begin
            Res := AskIgnoreErrors;
            FCanceled := (Res = IDCANCEL);
            FIgnoreErrors := (Res = IDYES);
          end;
        end;
        FinishCurrentFile;
      finally
        SetQueueControlsEnabled(True);
      end;
    finally
      ClearDownloader(Downloader);
      Downloader.Free;
    end;
  finally
    FSystemDB.ClearCollectionCache;
    FSystemDB := nil;
  end;
end;

end.
