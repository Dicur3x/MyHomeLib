(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  *                     Oleksiy Penkov oleksiy.penkov@gmail.com
  * Created             20.08.2008
  * Description
  *
  * $Id: frm_NewCollectionWizard.pas 1104 2012-01-27 04:43:24Z koreec $
  *
  * History
  * NickR 03.09.2010    Импорт из XML больше не поддерживается. Удалил соответствующую страницу визарда.
  *
  ****************************************************************************** *)

unit frm_NewCollectionWizard;

interface

uses
  Windows,
  Messages,
  SysUtils,
  Classes,
  Controls,
  Forms,
  Dialogs,
  StdCtrls,
  ExtCtrls,
  unit_WorkerThread,
  unit_NCWParams,
  frame_WizardPageBase,
  frame_NCWWelcom,
  frame_NCWOperation,
  frame_NCWInpxSource,
  frame_NCWDownload,
  frame_NCWCollectionNameAndLocation,
  frame_NCWCollectionFileTypes,
  frame_NCWSelectGenreFile,
  frame_NCWProgress,
  frame_NCWFinish,
  frm_MHLWizardBase;

type
  TNewCollectionWizard = class(TMHLWizardBase)
  private const
    WELCOM_PAGE_ID = 0;
    OPERATION_PAGE_ID = 1;
    INPXSOURCE_PAGE_ID = 2;
    DOWNLOAD_PAGE_ID = 3;
    NAMEANDLOCATION_PAGE_ID = 4;
    FILETYPES_PAGE_ID = 5;
    GENREFILE_PAGE_ID = 6;
    PROGRESS_PAGE_ID = 7;
    FINISH_PAGE_ID = 8;

  private
    FWelcomPage: TframeNCWWelcom;
    FCollectionTypePage: TframeNCWOperation;
    FInpxSourcePage: TframeNCWInpxSource;
    FDownloadPage: TframeNCWDownload;
    FNameAndLocationPage: TframeNCWNameAndLocation;
    FFileTypesPage: TframeNCWCollectionFileTypes;
    FSelectGenreFilePage: TframeNCWSelectGenreFile;
    FProgressPage: TframeNCWProgress;
    FFinishPage: TframeNCWFinish;

    FParams: TNCWParams;
    FWorker: TWorker;

    FAutoImport: boolean;
    FOperationSucceeded: Boolean;
    FCollectionCommittedChanges: Boolean;
    FRequestedMetadataFill: Boolean;

    function CanRequestMetadataFill: Boolean;
    procedure RequestMetadataFill(Sender: TObject);
    procedure CorrectParams;
    function CreateCollection: Boolean;
    function StartImportData: Boolean;

    procedure CloseWorker;
    procedure CancelWorker;

    function ShowMessage(const Text: string; Flags: Longint = MB_OK): Integer;

  protected
    procedure PMWorkerDone(var Message: TMessage); message PM_WORKERDONE;

    procedure InitWizard; override;
    function IsPageVisible(PageIndex: Integer): Boolean; override;
    procedure AfterShowPage; override;
    function CanCloseWizard: Boolean; override;
    procedure CancelWizard; override;

  public
    destructor Destroy; override;

    function NewCollectionID: Integer; inline;
    property AutoImport:boolean  read FAutoImport;
    property OperationSucceeded: Boolean read FOperationSucceeded;
    property CommittedChanges: Boolean read FCollectionCommittedChanges;
    property RequestedMetadataFill: Boolean read FRequestedMetadataFill;
  end;

var
  NewCollectionWizard: TNewCollectionWizard;

implementation

uses
  Math,
  unit_MHL_strings,
  unit_Consts,
  unit_Globals,
  unit_Settings,
  dm_user,
  unit_Interfaces,
  unit_ImportInpxThread,
  unit_CollectionWorkerThread,
  unit_ImportMetabibThread;

{$R *.dfm}

resourcestring
rstrCreationCollection = 'Создание коллекции';
   rstrDataImport = 'Импорт данных';
   rstrDataImporting = 'Импортируем данные';
   rstrRegistration = 'Регистрируем коллекцию';
   rstrDownloadFailed = 'Загрузка не удалась. Сервер сообщает об ошибке.';
   rstrImportDoneWithErrors = 'Импорт окончен с ошибками. Продолжить регистрацию коллекции?';

destructor TNewCollectionWizard.Destroy;
begin
  CloseWorker;
  inherited;
end;

function TNewCollectionWizard.NewCollectionID: Integer;
begin
  Result := FParams.CollectionID;
end;

procedure TNewCollectionWizard.InitWizard;
var
  frame: TWizardPageBase;
begin
  FParams.Operation := otNew;
  FParams.CollectionType := ltUser;
  FParams.FileTypes := ftFB2;
  FParams.DefaultGenres := True;

  FWelcomPage := AddPage(TframeNCWWelcom) as TframeNCWWelcom;
  FCollectionTypePage := AddPage(TframeNCWOperation) as TframeNCWOperation;
  FInpxSourcePage := AddPage(TframeNCWInpxSource) as TframeNCWInpxSource;
  FDownloadPage := AddPage(TframeNCWDownload) as TframeNCWDownload;
  FNameAndLocationPage := AddPage(TframeNCWNameAndLocation) as TframeNCWNameAndLocation;
  FFileTypesPage := AddPage(TframeNCWCollectionFileTypes) as TframeNCWCollectionFileTypes;
  FSelectGenreFilePage := AddPage(TframeNCWSelectGenreFile) as TframeNCWSelectGenreFile;
  FProgressPage := AddPage(TframeNCWProgress) as TframeNCWProgress;
  FFinishPage := AddPage(TframeNCWFinish) as TframeNCWFinish;

  for frame in FPages do
    frame.Initialize(@FParams);

  FFinishPage.lblPageHint.Caption := '';
  FFinishPage.btnMetadataFill.OnClick := RequestMetadataFill;
end;

function TNewCollectionWizard.IsPageVisible(PageIndex: Integer): Boolean;
begin
  case PageIndex of
    WELCOM_PAGE_ID:
      Result := True;

    OPERATION_PAGE_ID:
      Result := True;

    INPXSOURCE_PAGE_ID:
      Result := FParams.Operation in [otInpx, otMetabib];

    DOWNLOAD_PAGE_ID:
      Result := (FParams.Operation = otInpxDownload);

    NAMEANDLOCATION_PAGE_ID:
      Result := True;

    FILETYPES_PAGE_ID:
      Result := (FParams.Operation = otNew);

    GENREFILE_PAGE_ID:
      Result := (FParams.Operation = otNew) and (FParams.FileTypes = ftAny);

    PROGRESS_PAGE_ID:
      Result := True;

    FINISH_PAGE_ID:
      Result := True;
  else
    Assert(False);
    Result := True;
  end;
end;

function TNewCollectionWizard.CanRequestMetadataFill: Boolean;
var Info: TCollectionInfo;
begin
  Result := False;
  if not FOperationSucceeded or not FCollectionCommittedChanges or (FParams.CollectionID <= 0) then Exit;
  try
    if SystemDB.FindFirstExistingCollectionID(FParams.CollectionID) <> FParams.CollectionID then Exit;
    Info := SystemDB.GetCollectionInfo(FParams.CollectionID);
    Result := (Info.ID = FParams.CollectionID) and not isOnlineCollection(Info.CollectionType) and
      (Trim(Info.RootFolder) <> '') and DirectoryExists(Info.RootFolder);
  except
    // The finish action cannot turn a vanished/unavailable collection into a
    // successful metadata request. No files or book descriptions are opened.
    Result := False;
  end;
end;

procedure TNewCollectionWizard.RequestMetadataFill(Sender: TObject);
begin
  if FCurrentPage <> FINISH_PAGE_ID then Exit;
  FFinishPage.SetMetadataFillAvailable(CanRequestMetadataFill);
  if not FFinishPage.btnMetadataFill.Enabled then Exit;
  FRequestedMetadataFill := True;
  ModalResult := mrOk;
end;

procedure TNewCollectionWizard.AfterShowPage;
begin
  Assert(IsValidPageIndex(FCurrentPage));

  if DOWNLOAD_PAGE_ID = FCurrentPage then
  begin
    AdjustButtons([wbCancel], [wbCancel]);
    try
      if FDownloadPage.Download then
        DoChangePage(btnForward);
    except
      on E: Exception do
      begin
        MessageDlg(rstrDownloadFailed, mtError, [mbOK], 0);
        DoChangePage(btnBackward);
      end;
    end;
  end
  else if PROGRESS_PAGE_ID = FCurrentPage then
  begin
    CorrectParams;

    if not CreateCollection then
    begin
      FProgressPage.ShowSaveLogPanel(True);
      AdjustButtons([wbFinish], [wbFinish]);
      Exit;
    end;

    FModalResult := mrOk;

    if not StartImportData then
    begin
      FOperationSucceeded := True;
      DoChangePage(btnForward);
    end;
  end
  else if FINISH_PAGE_ID = FCurrentPage then
    FFinishPage.SetMetadataFillAvailable(CanRequestMetadataFill);
end;

function TNewCollectionWizard.CanCloseWizard: Boolean;
begin
  if Assigned(FWorker) and not FWorker.Finished then
  begin
    CancelWorker;
    Result := False;
    Exit;
  end;

  Result := inherited CanCloseWizard;
end;

procedure TNewCollectionWizard.CancelWizard;
begin
  FRequestedMetadataFill := False;
  if DOWNLOAD_PAGE_ID = FCurrentPage then
  begin
    FDownloadPage.Stop;
  end;

  if Assigned(FWorker) then
  begin
    CancelWorker;
    Exit;
  end;

  inherited CancelWizard;
end;

procedure TNewCollectionWizard.CorrectParams;
begin
  if FParams.CollectionCode = 0 then
  begin
    case FParams.CollectionType of
      ltUser:              FParams.CollectionCode := IfThen(FParams.FileTypes = ftFB2, CT_PRIVATE_FB, CT_PRIVATE_NONFB);
      ltUserFB:            FParams.CollectionCode := CT_PRIVATE_FB;
      ltUserAny:           FParams.CollectionCode := CT_PRIVATE_NONFB;
      ltExternalLocalFB:   FParams.CollectionCode := CT_EXTERNAL_LOCAL_FB;
      ltExternalOnlineFB:  FParams.CollectionCode := CT_EXTERNAL_ONLINE_FB;
      ltExternalLocalAny:  FParams.CollectionCode := CT_EXTERNAL_LOCAL_NONFB;
      ltExternalOnlineAny: FParams.CollectionCode := CT_EXTERNAL_ONLINE_NONFB;
    end;
  end;

  case FParams.CollectionType of
    ltUser: ;

    ltUserFB, ltExternalLocalFB, ltExternalOnlineFB:
    begin
      FParams.DefaultGenres := True;
      FParams.FileTypes := ftFB2;
      FParams.GenreFile := Settings.SystemFileName[sfGenresFB2]
    end;

    ltUserAny, ltExternalOnlineAny:
    begin
      FParams.FileTypes := ftAny;
      FParams.GenreFile := Settings.SystemFileName[sfGenresNonFB2];
    end;

    ltExternalLocalAny:
    begin
      FParams.GenreFile := Settings.SystemFileName[sfGenresFB2];
      FParams.FileTypes := ftAny;
    end;
  end;

  if not FParams.DefaultGenres then
    FParams.GenreFile := ExpandFileName(FParams.GenreFile)
  else if FParams.GenreFile = '' then
  begin
    if FParams.FileTypes = ftFB2 then
      FParams.GenreFile := Settings.SystemFileName[sfGenresFB2]
    else
      FParams.GenreFile := Settings.SystemFileName[sfGenresNonFB2];
  end;

  Assert(FileExists(FParams.GenreFile));
end;

function TNewCollectionWizard.CreateCollection: Boolean;
begin
  Assert(Assigned(FProgressPage));

  Result := False;
  FOperationSucceeded := False;
  FCollectionCommittedChanges := False;
  FRequestedMetadataFill := False;

  FProgressPage.OpenProgress;
  FProgressPage.SetComment(rstrCreationCollection);

  try
    if FParams.Operation = otExisting then
    begin
      FParams.CollectionID := SystemDB.RegisterCollection(
        FParams.CollectionFile,
        FParams.DisplayName,
        FParams.CollectionRoot
      );
    end
    else
    begin
      FProgressPage.ShowTeletype(rstrCreationCollection, tsInfo);
      Assert(FileExists(FParams.GenreFile));
      FParams.CollectionID := SystemDB.CreateCollection(
        FParams.DisplayName,
        FParams.CollectionRoot,
        FParams.CollectionFile,
        FParams.CollectionCode,
        FParams.GenreFile
      );
    end;

    FProgressPage.ShowProgress(100);

    FAutoImport := FParams.AutoImport;
    FCollectionCommittedChanges := True;

    Result := True;
  except
    on e: Exception do
      FProgressPage.ShowTeletype(e.Message, tsError);
  end;
end;

function TNewCollectionWizard.StartImportData: Boolean;
var
  GenresType: TGenresType;
begin
  Assert(Assigned(FProgressPage));

  if FParams.Operation in [otNew, otExisting] then
  begin
    Result := False;
    Exit;
  end;

  Assert(FParams.CollectionType <> ltUser);
  Assert(FParams.INPXFile <> '');

  Assert(not Assigned(FWorker));
  FWorker := nil;

  // Assert убирается в Release, так что без значения по умолчанию
  // неожиданный тип коллекции передал бы в поток неинициализированную переменную
  GenresType := gtFb2;

  case FParams.CollectionType of
    ltUserFB, ltExternalLocalFB, ltExternalOnlineFB, ltExternalLocalAny:
      GenresType := gtFb2;

    ltUserAny, ltExternalOnlineAny:
      GenresType := gtAny;

    else
      Assert(False);
  end;
  // Формат определяется операцией мастера, а не анализом файла: metabib
  // теперь отдельная ветка выбора, а не скрытый вариант источника INPX.
  if FParams.Operation = otMetabib then
    FWorker := TImportMetabibThread.Create(FParams.CollectionID, FParams.INPXFile, GenresType)
  else
    FWorker := TImportInpxThread.Create(FParams.CollectionID, FParams.INPXFile, GenresType);

  FProgressPage.SetComment(rstrDataImport);
  FProgressPage.ShowTeletype(rstrDataImporting, tsInfo);

  FWorker.OnOpenProgress := FProgressPage.OpenProgress;
  FWorker.OnProgressHint := FProgressPage.SetProgressHint;
  FWorker.OnProgress := FProgressPage.ShowProgress;
  FWorker.OnCloseProgress := FProgressPage.CloseProgress;
  FWorker.OnTeletype := FProgressPage.ShowTeletype;
  FWorker.OnSetComment := FProgressPage.SetComment;
  FWorker.OnShowMessage := ShowMessage;

  FWorker.Start;

  Result := True;
end;

function TNewCollectionWizard.ShowMessage(const Text: string; Flags: Integer): Integer;
begin
  Result := Application.MessageBox(PChar(Text), PChar(Application.Title), Flags);
end;

procedure TNewCollectionWizard.CancelWorker;
begin
  if Assigned(FWorker) then
  begin
    if FWorker.Finished then
      Exit;

    if not FWorker.Canceled then
      if ShowMessage(rstrCancelOperationWarningMsg, MB_OKCANCEL or MB_ICONEXCLAMATION) = IDCANCEL then
        Exit;

    FWorker.Cancel;
    AdjustButtons([], []);
  end;
end;

procedure TNewCollectionWizard.CloseWorker;
begin
  if Assigned(FWorker) then
  begin
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
end;

procedure TNewCollectionWizard.PMWorkerDone(var Message: TMessage);
var
  stayOnCurrentPage: Boolean;
  IgnoreErrors : Boolean;
begin
  // Completion notification precedes Uninitialize. Join before inspecting
  // the final worker outcome or freeing its committed/success flags.
  if Assigned(FWorker) then
  begin
    FWorker.WaitFor;
    if FWorker is TCollectionWorker then
    begin
      FOperationSucceeded := TCollectionWorker(FWorker).Success and
        not Assigned(FWorker.FatalException);
      FCollectionCommittedChanges := FCollectionCommittedChanges or
        TCollectionWorker(FWorker).CommittedChanges;
    end;
  end;
  IgnoreErrors := True;
  if FProgressPage.HasErrors then
    IgnoreErrors := (MessageDlg(rstrImportDoneWithErrors, mtWarning, [mbYes,mbNo], 0) = mrYes);

  stayOnCurrentPage := (not IgnoreErrors) or FWorker.Canceled;

  CloseWorker;

  if stayOnCurrentPage then
  begin
    // User cancelled or errors occurred — destroy the partially created collection
    SystemDB.DeleteCollection(FParams.CollectionID);
    FOperationSucceeded := False;
    FCollectionCommittedChanges := False;

    if FProgressPage.HasErrors then
    begin
      FProgressPage.ShowSaveLogPanel(True);
      AdjustButtons([wbFinish], [wbFinish]);
    end
    else
    begin
      ModalResult := FModalResult;
    end;
  end
  else
  begin
    DoChangePage(btnForward);
  end;
end;

end.
