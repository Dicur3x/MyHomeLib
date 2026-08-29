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
    //
    // Возвращает False, если пользователь отменил операцию: изменения откатились,
    // коллекция осталась такой, какой была.
    //
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

  //
  // Ручное обновление из каталога metabib. Каталог всегда содержит полный срез,
  // поэтому инкрементальной ветки нет: только полный переимпорт с сохранением
  // пользовательских данных (аналогично TCollectionUpdateThreadBase для INPX).
  //
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
rstrDownloadProgress = 'Загружено: %u%% из %u байт';
   rstrCheckingUpdate = 'Проверяем наличие обновлений основной базы...';
   rstrCheckingExtraUpdate = 'Проверяем наличие обновлений для on-line...';
   rstrErrorCheckingUpdate = 'Ошибка. Не удалось проверить обновление.';
   rstrErrorDownloadUpdate = 'Ошибка. Не удалось загрузить обновление.';
   rstrReady = 'Готово';
   rstrDownloadingUpdates = 'Загрузка обновлений...';
   rstrYouHaveLatestListsVersion = 'У вас самая свежая версия списков.';
   rstrUpdatingFromLocalArchive = 'Обновление из локального архива';
   rstrListsUpdateIsAvailable = 'Доступно обновление списков до версии %d';
   rstrListsExtraUpdateIsAvailable = 'Доступно обновление списков on-line до версии %d';
   rstrNothingToUpdate = 'Нечего обновлять!';
   rstrUpdateComplete = 'Обновление завершено.';
   rstrUpdateFailed = 'Обновление не удалось.';
   rstrBackupUserData = 'Сохранение резервной копии пользовательских данных';
   rstrRestoreUserData = 'Восстановление пользовательских данных';
   rstrRemovingOldCollection = 'Удаление всех записей старой коллекции "%s" ...';
   rstrCreatingCollection = 'Создание новой коллекции %s...';
   rstrSpeed = 'Загрузка: %s КБ/с';
   rstrConnectingToServer = 'Подключение к серверу...';
   rstrOnlineCollectionUpdate = 'Обновление коллекции %s до версии %d:';
   rstrLocalCollectionUpdate = 'Обновление коллекции %s:';
   rstrUpdateFailedDownload = 'Загрузка обновлений не удалась.';
   rstrCancelledByUser = 'Операция отменена пользователем.';
   rstrImportIntoCollection = 'Импорт данных в коллекцию:';
   rstrManualCollectionUpdate = 'Обновление коллекции %s из файла %s:';
   rstrUpdateFileNotFound = 'Файл обновления не найден: %s';
   rstrInvalidUpdateFile = 'Неверный формат файла INPX: %s';
   rstrMbDatasetAlwaysFull = 'Каталог metabib всегда импортируется полностью.';

{ TCollectionUpdateThreadBase }

//
// Обновление одной коллекции из одного файла списков.
// Файл AFileName не удаляется — о нем заботится вызывающий.
//
function TCollectionUpdateThreadBase.UpdateCollection(const AFileName: string;
  ACollectionID: Integer; AFull: Boolean; const ADisplayName: string): Boolean;
var
  Collection: IBookCollection;
  UserDataBackup: TUserData;
begin
  Result := False;

  //Truncate won't work with TBookCollection.Create(DBFileName, False)
  Collection := FSystemData.GetCollection(ACollectionID);
  Collection.BeginBulkOperation;
  try
    UserDataBackup := TUserData.Create;
    try
      if AFull then
      begin
        // Backup user data:
        Teletype(Format(rstrBackupUserData, [ADisplayName]), tsInfo);
        Collection.ExportUserData(UserDataBackup);

        // clear most tables in a collection
        Teletype(Format(rstrRemovingOldCollection, [ADisplayName]), tsInfo);
        Collection.TruncateTablesBeforeImport;
      end;

      Teletype(rstrImportIntoCollection, tsInfo);
      Import(AFileName, not AFull, Collection);

      //
      // Импорт лишь прерывает свои циклы по Canceled и возвращает управление
      // штатно. Без этой проверки отменённый полный переимпорт закоммитил бы
      // обрезанную коллекцию, а RemapCollectionBookIDs ещё и почистил бы группы.
      //
      if Canceled then
      begin
        Collection.EndBulkOperation(False);
        Teletype(rstrCancelledByUser, tsInfo);
        Exit;
      end;

      if AFull then
      begin
        // Restore user data:
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

  //
  // При полном переимпорте BookID в коллекции переприсваиваются, и сохранённые
  // в группах BookID начинают указывать на чужие книги. Приводим их к новой
  // нумерации по LibID (при полном переимпорте заодно убираем книги, которых
  // в коллекции больше нет).
  // Делается только после коммита коллекции: системная БД - отдельный файл,
  // её изменения не откатятся вместе с импортом.
  //
  FSystemData.RemapCollectionBookIDs(ACollectionID, AFull);
  Result := True;
end;

{ TLibUpdateThread }

constructor TLibUpdateThread.Create;
begin
  inherited Create(MHL_INVALID_ID);
  //
  // Сейчас считается, что обновления могут быть только для коллекций, содержащих fb2 жанры
  //
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

      //
      // Отмена во время импорта: изменения уже отменены, файлы обновлений
      // оставляем на месте, чтобы можно было повторить попытку.
      //
      if not UpdateCollection(InpxFileName, updateInfo.CollectionID, updateInfo.Full, updateInfo.Name) then
        Exit;

      Teletype(rstrReady, tsInfo);
    end; //for .. with

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
      //
      // InpxFileName - файл, на котором произошла ошибка обработки; до первой итерации цикла
      // он пуст. Ранее здесь использовался счетчик i, неопределенный
      // за пределами цикла, да еще и с другой папкой.
      //
      if (InpxFileName <> '') and FileExists(InpxFileName) then
        DeleteFile(InpxFileName);
    end;
  end;
end;

{ TManualUpdateThread }

constructor TManualUpdateThread.Create(const ACollectionID: Integer;
  const AFileName: string; AFull: Boolean; AGenresType: TGenresType);
begin
  inherited Create(ACollectionID);
  FFileName := AFileName;
  FFull := AFull;
  FGenresType := AGenresType;
  //
  // Файл выбрал пользователь, он может быть из любого источника: не разрешаем
  // ему collection.info перезаписать URL и скрипт подключения коллекции.
  //
  FKeepCollectionProps := True;
end;

//
// Import некорректно обрабатывает файл, который не является архивом, или архив без .inp:
// его finally освобождает неинициализированные указатели. Проверяем заранее.
//
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

{ TMetabibManualUpdateThread }

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

        //
        // Import штатно завершается и после Canceled; без этой проверки
        // отмена закоммитила бы обрезанную коллекцию.
        //
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

    //
    // Полный переимпорт переназначает BookID — группы приводим к новой
    // нумерации по LibID. Только после коммита коллекции: системная БД отдельная.
    //
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
