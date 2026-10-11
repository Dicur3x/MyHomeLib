(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors Oleksiy Penkov   oleksiy.penkov@gmail.com
  *         Nick Rymanov     nrymanov@gmail.com
  * Created                  20.08.2008
  * Description
  *
  * $Id: unit_libupdateThread.pas 1169 2014-06-17 07:31:08Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_libupdateThread;

interface

uses
  Windows,
  Classes,
  SysUtils,
  unit_ImportInpxThread,
  unit_ImportMetabibThread,
  unit_MetabibReader,
  System.Net.HttpClient,
  unit_Globals;

type
  TDownloadProgressEvent = procedure (Current, Total: Integer) of object;
  TDownloadSetCommentEvent = procedure (const Current, Total: string) of object;

  TCollectionUpdateThreadBase = class(TImportInpxThreadBase)
  protected
    // False = скасовано користувачем; зміни відкочено.
    function UpdateCollection(const AFileName: string; ACollectionID: Integer;
      AFull: Boolean; const ADisplayName: string): Boolean;
  end;

  TLibUpdateThread = class(TCollectionUpdateThreadBase)
  private
    FHTTPClient: THTTPClient;
    FStartDate: TDateTime;
    FUpdated: Boolean;

  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
    procedure WorkFunction; override;
    procedure HTTPReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64; var AAbort: Boolean);

  public
    constructor Create;
    property Updated: Boolean read FUpdated;
  end;

  TManualUpdateThread = class(TCollectionUpdateThreadBase)
  private
    FFileName: string;
    FFull: Boolean;
    FDisplayName: string;
    function IsValidUpdateArchive: Boolean;

  protected
    procedure WorkFunction; override;

  public
    constructor Create(const ACollectionID: Integer; const AFileName: string;
      AFull: Boolean; AGenresType: TGenresType);
    property DisplayName: string read FDisplayName write FDisplayName;
  end;

  // Каталог metabib - завжди повний зріз: лише повний переімпорт зі збереженням даних користувача.
  TMetabibManualUpdateThread = class(TImportMetabibThreadBase)
  private
    FFileName: string;
    FDisplayName: string;

  protected
    procedure WorkFunction; override;

  public
    constructor Create(const ACollectionID: Integer; const AFileName: string;
      AGenresType: TGenresType);
    property DisplayName: string read FDisplayName write FDisplayName;
  end;

implementation

uses
  IOUtils,
  DateUtils,
  unit_Consts,
  unit_Settings,
  dm_user,
  unit_WorkerThread,
  unit_Lib_Updates,
  unit_Interfaces,
  unit_Logger,
  unit_MHLHttpClient,
  unit_MHLArchiveHelpers,
  unit_UserData;

resourcestring
rstrDownloadProgress = 'Завантажено: %u%% із %u байт';
   rstrCheckingUpdate = 'Перевіряємо наявність оновлень основної бази...';
   rstrCheckingExtraUpdate = 'Перевіряємо наявність оновлень для on-line...';
   rstrErrorCheckingUpdate = 'ПОМИЛКА. Не вдалося перевірити оновлення.';
   rstrErrorDownloadUpdate = 'ПОМИЛКА. Не вдалося завантажити оновлення.';
   rstrReady = 'Готово';
   rstrDownloadingUpdates = 'Завантаження оновлень...';
   rstrYouHaveLatestListsVersion = 'У вас найсвіжіша версія списків.';
   rstrUpdatingFromLocalArchive = 'Оновлення з локального архіву';
   rstrListsUpdateIsAvailable = 'Доступно оновлення списків до версії %d';
   rstrListsExtraUpdateIsAvailable = 'Доступне оновлення списків on-line до версії %d';
   rstrNothingToUpdate = 'Нема чого оновлювати!';
   rstrUpdateComplete = 'Оновлення завершено.';
   rstrUpdateFailed = 'Оновлення не вдалося.';
   rstrBackupUserData = 'Збереження резервної копії даних користувача';
   rstrRestoreUserData = 'Відновлення даних користувача';
   rstrRemovingOldCollection = 'Видалення всіх записів старої колекції "%s" ...';
   rstrCreatingCollection = 'Створення нової колекції %s...';
   rstrSpeed = 'Завантаження: %s Kb/s';
   rstrConnectingToServer = 'Підключення до сервера...';
   rstrOnlineCollectionUpdate = 'Оновлення колекції %s до версії %d:';
   rstrLocalCollectionUpdate = 'Оновлення колекції %s:';
   rstrUpdateFailedDownload = 'Завантаження оновлень не вдалося.';
   rstrCancelledByUser = 'Операцію скасовано користувачем.';
   rstrImportIntoCollection = 'Імпорт даних до колекції:';
   rstrManualCollectionUpdate = 'Оновлення колекції %s з файлу %s:';
   rstrUpdateFileNotFound = 'Файл оновлення не знайдено: %s';
   rstrInvalidUpdateFile = 'Неправильний формат файлу INPX: %s';
   rstrMbDatasetAlwaysFull = 'Каталог metabib імпортується завжди повністю.';

function TCollectionUpdateThreadBase.UpdateCollection(const AFileName: string;
  ACollectionID: Integer; AFull: Boolean; const ADisplayName: string): Boolean;
var
  Collection: IBookCollection;
  UserDataBackup: TUserData;
begin
  Result := False;

  // Truncate won't work with TBookCollection.Create(DBFileName, False)
  Collection := FSystemData.GetCollection(ACollectionID);
  Collection.BeginBulkOperation;
  try
    UserDataBackup := TUserData.Create;
    try
      if AFull then
      begin
        Teletype(Format(rstrBackupUserData, [ADisplayName]), tsInfo);
        Collection.ExportUserData(UserDataBackup);

        Teletype(Format(rstrRemovingOldCollection, [ADisplayName]), tsInfo);
        Collection.TruncateTablesBeforeImport;
      end;

      Teletype(rstrImportIntoCollection, tsInfo);
      Import(AFileName, not AFull, Collection);

      // Import повертається штатно і після Canceled; без перевірки закомітилась
      // би обрізана колекція, а RemapCollectionBookIDs вичистив би групи.
      if Canceled then
      begin
        Collection.EndBulkOperation(False);
        Teletype(rstrCancelledByUser, tsInfo);
        Exit;
      end;

      if AFull then
      begin
        Teletype(Format(rstrRestoreUserData, [ADisplayName]), tsInfo);
        Collection.ImportUserData(UserDataBackup, nil);
      end;
    finally
      FreeAndNil(UserDataBackup);
    end;

    Collection.EndBulkOperation(True);
  except
    Collection.EndBulkOperation(False);
    raise;
  end;

  // Повний переімпорт переприсвоює BookID, і BookID у групах вказують на чужі
  // книги. Лише після коміту колекції: системна БД - окремий файл і не відкотиться.
  FSystemData.RemapCollectionBookIDs(ACollectionID, AFull);
  Result := True;
end;

constructor TLibUpdateThread.Create;
begin
  inherited Create(MHL_INVALID_ID);
  // Вважається, що оновлення бувають лише для колекцій з fb2-жанрами.
  FGenresType := gtFb2;
end;

procedure TLibUpdateThread.HTTPReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64; var AAbort: Boolean);
var
  ElapsedTime: Cardinal;
  Speed: string;
begin
  if Canceled then
  begin
    AAbort := True;
    Exit;
  end;

  if AContentLength > 0 then
    SetProgress(AReadCount * 100 div AContentLength);

  ElapsedTime := SecondsBetween(Now, FStartDate);
  if ElapsedTime > 0 then
  begin
    Speed := FormatFloat('0.00', AReadCount / 1024 / ElapsedTime);
    SetComment(Format(rstrSpeed, [Speed]));
  end;
end;

procedure TLibUpdateThread.Initialize;
begin
  inherited Initialize;
  FHTTPClient := CreateHTTPClientUpdate;
  FHTTPClient.OnReceiveData := HTTPReceiveData;
end;

procedure TLibUpdateThread.Uninitialize;
begin
  FreeAndNil(FHTTPClient);
  inherited Uninitialize;
end;

procedure TLibUpdateThread.WorkFunction;
var
  i: integer;
  InpxFileName: string;
  updateInfo: TUpdateInfo;
begin
  SetComment(rstrCheckingUpdate);

  try
    for i := 0 to Settings.Updates.Count - 1 do
    begin
      updateInfo := Settings.Updates[i];

      if not updateInfo.Available then
        Continue;

      if updateInfo.ExternalVersion > 0 then
         Teletype(Format(rstrOnlineCollectionUpdate, [updateInfo.Name, updateInfo.ExternalVersion]), tsInfo)
      else
         Teletype(Format(rstrLocalCollectionUpdate, [updateInfo.Name]), tsInfo);


      if updateInfo.Local then
        Teletype(rstrUpdatingFromLocalArchive, tsInfo)
      else
      begin
        Teletype(rstrDownloadingUpdates, tsInfo);
        SetComment(rstrConnectingToServer);
        FStartDate := Now;
        SetProgress(0);
        if not Settings.Updates.DownloadUpdate(i, FHTTPClient) then
        begin
          Teletype(rstrUpdateFailedDownload, tsInfo);
          Continue;
        end;
      end;

      InpxFileName := TPath.Combine(Settings.UpdatePath, updateInfo.UpdateFile);

      if Canceled then
      begin
        DeleteFile(InpxFileName);
        Teletype(rstrCancelledByUser, tsInfo);
        Exit;
      end;

      // Скасування: зміни відкочено, файли оновлень лишаємо для повторної спроби.
      if not UpdateCollection(InpxFileName, updateInfo.CollectionID, updateInfo.Full, updateInfo.Name) then
        Exit;

      Teletype(rstrReady, tsInfo);
    end;

    Teletype(rstrUpdateComplete, tsInfo);
    for i := 0 to Settings.Updates.Count - 1 do
    begin
      updateInfo := Settings.Updates[i];
      InpxFileName := TPath.Combine(Settings.UpdatePath, updateInfo.UpdateFile);
      if FileExists(InpxFileName) then
         DeleteFile(InpxFileName);
    end;

    SetComment(rstrReady);
  except
    on E: Exception do
    begin
      Teletype(rstrUpdateFailed, tsError);
{$IFDEF USELOGGER}
      GetLogger.Log('TLibUpdateThread.WorkFunction ERROR', E.Message);
{$ENDIF}
      // До першої ітерації InpxFileName порожній.
      if (InpxFileName <> '') and FileExists(InpxFileName) then
        DeleteFile(InpxFileName);
    end;
  end;
end;

constructor TManualUpdateThread.Create(const ACollectionID: Integer;
  const AFileName: string; AFull: Boolean; AGenresType: TGenresType);
begin
  inherited Create(ACollectionID);
  FFileName := AFileName;
  FFull := AFull;
  FGenresType := AGenresType;
  // Файл з довільного джерела: його collection.info не має перезаписати URL і скрипт колекції.
  FKeepCollectionProps := True;
end;

// Import на не-архіві чи архіві без .inp звільняє неініціалізовані вказівники у finally.
function TManualUpdateThread.IsValidUpdateArchive: Boolean;
var
  Zip: TMHLZip;
begin
  try
    Zip := TMHLZip.Create(FFileName, True);
    try
      Result := Zip.Find('*.inp');
    finally
      FreeAndNil(Zip);
    end;
  except
    Result := False;
  end;
end;

procedure TManualUpdateThread.WorkFunction;
begin
  if not FileExists(FFileName) then
  begin
    Teletype(Format(rstrUpdateFileNotFound, [FFileName]), tsError);
    Exit;
  end;

  if not IsValidUpdateArchive then
  begin
    Teletype(Format(rstrInvalidUpdateFile, [FFileName]), tsError);
    Exit;
  end;

  try
    Teletype(Format(rstrManualCollectionUpdate, [FDisplayName, FFileName]), tsInfo);
    if UpdateCollection(FFileName, FCollectionID, FFull, FDisplayName) then
      Teletype(rstrUpdateComplete, tsInfo);
    SetComment(rstrReady);
  except
    on E: Exception do
    begin
      Teletype(rstrUpdateFailed, tsError);
      Teletype(E.Message, tsError);
    end;
  end;
end;

constructor TMetabibManualUpdateThread.Create(const ACollectionID: Integer;
  const AFileName: string; AGenresType: TGenresType);
begin
  inherited Create(ACollectionID);
  FFileName := AFileName;
  FGenresType := AGenresType;
end;

procedure TMetabibManualUpdateThread.WorkFunction;
var
  Collection: IBookCollection;
  UserDataBackup: TUserData;
begin
  if not FileExists(FFileName) then
  begin
    Teletype(Format(rstrUpdateFileNotFound, [FFileName]), tsError);
    Exit;
  end;

  if not TMetabibReader.IsDatasetFile(FFileName) then
  begin
    Teletype(Format(rstrInvalidUpdateFile, [FFileName]), tsError);
    Exit;
  end;

  try
    Teletype(Format(rstrManualCollectionUpdate, [FDisplayName, FFileName]), tsInfo);
    Teletype(rstrMbDatasetAlwaysFull, tsInfo);

    Collection := FSystemData.GetCollection(FCollectionID);
    Collection.BeginBulkOperation;
    try
      UserDataBackup := TUserData.Create;
      try
        Teletype(Format(rstrBackupUserData, [FDisplayName]), tsInfo);
        Collection.ExportUserData(UserDataBackup);

        Teletype(Format(rstrRemovingOldCollection, [FDisplayName]), tsInfo);
        Collection.TruncateTablesBeforeImport;

        Teletype(rstrImportIntoCollection, tsInfo);
        Import(FFileName, False, Collection);

        // Import повертається штатно і після Canceled.
        if Canceled then
        begin
          Collection.EndBulkOperation(False);
          Teletype(rstrCancelledByUser, tsInfo);
          Exit;
        end;

        Teletype(Format(rstrRestoreUserData, [FDisplayName]), tsInfo);
        Collection.ImportUserData(UserDataBackup, nil);
      finally
        FreeAndNil(UserDataBackup);
      end;

      Collection.EndBulkOperation(True);
    except
      Collection.EndBulkOperation(False);
      raise;
    end;

    // Лише після коміту колекції: системна БД окрема.
    FSystemData.RemapCollectionBookIDs(FCollectionID, True);

    Teletype(rstrUpdateComplete, tsInfo);
    SetComment(rstrReady);
  except
    on E: Exception do
    begin
      Teletype(rstrUpdateFailed, tsError);
      Teletype(E.Message, tsError);
    end;
  end;
end;

end.
