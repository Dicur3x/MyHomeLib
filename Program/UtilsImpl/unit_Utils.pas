(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             20.08.2008
  * Description
  *
  * $Id: unit_Utils.pas 1167 2014-06-16 02:07:14Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_Utils;

interface

uses
  Windows,
  Dialogs,
  unit_UserData;

procedure SyncOnLineFiles(const CollectionID: Integer);

procedure SyncFolders(const CollectionID: Integer);

function LibrusecUpdate(const LogFileName: string): Boolean; overload;
function LibrusecUpdate(const LogFileName: string;
  out AffectedCollectionIDs: TArray<Integer>): Boolean; overload;

function ManualCollectionUpdate(const CollectionID: Integer; const LogFileName: string): Boolean; overload;
function ManualCollectionUpdate(const CollectionID: Integer; const LogFileName: string;
  out CommittedChanges: Boolean): Boolean; overload;

function PrepareSqlCatalogue(const Source, Folder, Version, IndexFile: string): Boolean;
function ApplyPreparedCollectionUpdate(const CollectionID: Integer; const FileName, LogFileName: string;
  Full: Boolean; out CommittedChanges: Boolean): Boolean;

procedure ShowPopup(const Msg: string);
procedure HidePopup;

procedure LocateBook;

implementation

uses
  Forms, System.Classes, System.SysUtils, System.IOUtils,
  unit_WorkerThread, unit_FormatComponents, unit_MHLExternalTools, unit_ComponentUsage,
  unit_SyncOnLineThread,
  frm_SyncOnLineProgressForm,
  unit_SyncFoldersThread,
  frm_ImportProgressFormEx,
  unit_libupdateThread,
  unit_MetabibReader,
  unit_CatalogComponents,
  frm_info_popup,
  frm_search,
  frm_main,
  frm_UpdateFromFile,
  unit_Globals,
  unit_Interfaces,
  unit_Settings,
  unit_Consts,
  dm_user;

resourcestring
  rstrUpdateCollections = 'Обновление коллекций';
  rstrUpdateFromFile = 'Обновление коллекции из файла';

type
  TSqlCatalogueOutput = class(TMemoryStream)
  private
    FLineStart: NativeInt;
    FOnLine: TProc<string>;
  public
    function Write(const Buffer; Count: TNativeCount): TNativeCount; override;
  end;

  TSqlCatalogueWorker = class(TWorker)
  private
    FSource, FFolder, FVersion, FIndexFile: string;
    FSuccess: Boolean;
  protected
    procedure WorkFunction; override;
  end;

function TSqlCatalogueOutput.Write(const Buffer; Count: TNativeCount): TNativeCount;
var Start, I: NativeInt; Line: UTF8String; Bytes: PByte;
begin
  Start:=Position;
  Result:=inherited Write(Buffer,Count);
  Bytes:=Memory;
  for I:=Start to Position-1 do
    if Bytes[I]=10 then
    begin
      SetString(Line,PAnsiChar(Bytes+FLineStart),I-FLineStart);
      FLineStart:=I+1;
      FOnLine(Trim(UTF8ToString(Line)));
    end;
end;

procedure TSqlCatalogueWorker.WorkFunction;
var Output: TSqlCatalogueOutput; Args: TArray<string>; LastLine: string;
begin
  SetComment('Подготовка онлайн-каталога');
  Output:=TSqlCatalogueOutput.Create;
  try
    Output.FOnLine:=
      procedure(Line: string)
      begin
        LastLine:=Line;
        SetComment(Line);
      end;
    Args:=TArray<string>.Create('-B',TPath.Combine(Settings.AppPath,SQL_CATALOGUE_WORKER),
      FSource,FIndexFile);
    if FFolder<>'' then
      Args:=Args+TArray<string>.Create('--folder',FFolder,'--version',FVersion);
    try
      RunExternalToolToStream(TPath.Combine(Settings.AppPath,FormatComponentFile('BookProcessing')),
        Args,Output,function: Boolean begin Result:=Canceled; end,0,True);
      FSuccess:=not Canceled and FileExists(FIndexFile);
      if FSuccess then
      begin
        Teletype(LastLine,tsInfo);
        RecordComponentUse('BookProcessing');
      end;
    except
      on E:Exception do
        if not Canceled then
        begin
          if LastLine='' then LastLine:=E.Message;
          Teletype(LastLine,tsError);
        end;
    end;
  finally Output.Free; end;
end;

function PrepareSqlCatalogue(const Source, Folder, Version, IndexFile: string): Boolean;
var Worker: TSqlCatalogueWorker; Progress: TImportProgressFormEx;
begin
  Worker:=TSqlCatalogueWorker.Create;
  try
    Worker.FSource:=Source;
    Worker.FFolder:=Folder;
    Worker.FVersion:=Version;
    Worker.FIndexFile:=IndexFile;
    Progress:=TImportProgressFormEx.Create(Application);
    try
      Progress.Caption:='Подготовка каталога из SQL-дампов';
      Progress.WorkerThread:=Worker;
      Progress.ShowModal;
      Worker.WaitFor;
      Result:=Worker.FSuccess and not Worker.Canceled;
    finally Progress.Free; end;
  finally Worker.Free; end;
end;

procedure SyncOnLineFiles(const CollectionID: Integer);
var
  worker: TSyncOnLineThread;
  frmProgress: TSyncOnLineProgressForm;
begin
  worker := TSyncOnLineThread.Create(CollectionID);
  try
    frmProgress := TSyncOnLineProgressForm.Create(Application);
    try
      frmProgress.WorkerThread := worker;
      frmProgress.ShowModal;
    finally
      frmProgress.Free;
    end;
  finally
    worker.Free;
  end;
end;

procedure SyncFolders(const CollectionID: Integer);
var
  worker: TSyncFoldersThread;
  frmProgress: TSyncOnLineProgressForm;
begin
  worker := TSyncFoldersThread.Create(CollectionID);
  try
    frmProgress := TSyncOnLineProgressForm.Create(Application);
    try
      frmProgress.WorkerThread := worker;
      frmProgress.ShowModal;
    finally
      frmProgress.Free;
    end;
  finally
    worker.Free;
  end;
end;

function LibrusecUpdate(const LogFileName: string): Boolean;
var AffectedCollectionIDs: TArray<Integer>;
begin
  Result := LibrusecUpdate(LogFileName, AffectedCollectionIDs);
end;

function LibrusecUpdate(const LogFileName: string;
  out AffectedCollectionIDs: TArray<Integer>): Boolean;
var
  worker : TLibUpdateThread;
  ProgressForm : TImportProgressFormEx;
begin
  AffectedCollectionIDs := nil;
  worker := TLibUpdateThread.Create;
  try
    ProgressForm := TImportProgressFormEx.Create(Application);
    ProgressForm.Caption := rstrUpdateCollections;
    ProgressForm.CloseOnTimer := True;
    try
      ProgressForm.WorkerThread := worker;
      ProgressForm.ShowModal;
      worker.WaitFor;
      Result := worker.Updated;
      AffectedCollectionIDs := worker.CommittedCollectionIDs;
      ProgressForm.SaveErrorLog(LogFileName);
    finally
      ProgressForm.Free;
    end;
  finally
    worker.Free;
  end;
end;

function ManualCollectionUpdate(const CollectionID: Integer; const LogFileName: string): Boolean;
var CommittedChanges: Boolean;
begin
  Result := ManualCollectionUpdate(CollectionID, LogFileName, CommittedChanges);
end;

function ManualCollectionUpdate(const CollectionID: Integer; const LogFileName: string;
  out CommittedChanges: Boolean): Boolean;
var FileName: string; Full: Boolean;
begin
  Result:=False;
  CommittedChanges:=False;
  if not AskUpdateFile(FileName,Full) then Exit;
  Result:=ApplyPreparedCollectionUpdate(CollectionID,FileName,LogFileName,Full,CommittedChanges);
end;

function ApplyPreparedCollectionUpdate(const CollectionID: Integer; const FileName, LogFileName: string;
  Full: Boolean; out CommittedChanges: Boolean): Boolean;
var
  GenresType: TGenresType;
  CollectionInfo: TCollectionInfo;
  worker: TManualUpdateThread;
  mbWorker: TMetabibManualUpdateThread;
  ProgressForm: TImportProgressFormEx;
begin
  Result := False;
  CommittedChanges := False;

  if not EnsureCatalogReaderComponent(Application,FileName) then Exit;

  CollectionInfo := DMUser.GetSystemDBConnection.GetCollectionInfo(CollectionID);

  // То же распределение, что и у мастера создания коллекции: локальная не-FB2
  // коллекция (CT_EXTERNAL_LOCAL_NONFB) всё равно использует жанры fb2.
  case CollectionInfo.CollectionType of
    CT_PRIVATE_NONFB, CT_EXTERNAL_ONLINE_NONFB:
      GenresType := gtAny;
  else
    GenresType := gtFb2;
  end;

  if TMetabibReader.IsDatasetFile(FileName) then
  begin
    // Каталог metabib всегда содержит полный срез: флаг Full не имеет смысла
    mbWorker := TMetabibManualUpdateThread.Create(CollectionID, FileName, GenresType);
    try
      mbWorker.DisplayName := CollectionInfo.DisplayName;

      ProgressForm := TImportProgressFormEx.Create(Application);
      ProgressForm.Caption := rstrUpdateFromFile;
      try
        ProgressForm.btnSaveLog.Visible := True;
        ProgressForm.WorkerThread := mbWorker;
        ProgressForm.ShowModal;
        mbWorker.WaitFor;
        Result := mbWorker.Success;
        CommittedChanges := mbWorker.CommittedChanges;
        ProgressForm.SaveErrorLog(LogFileName);
      finally
        ProgressForm.Free;
      end;
    finally
      mbWorker.Free;
    end;
    Exit;
  end;

  worker := TManualUpdateThread.Create(CollectionID, FileName, Full, GenresType);
  try
    worker.DisplayName := CollectionInfo.DisplayName;

    ProgressForm := TImportProgressFormEx.Create(Application);
    ProgressForm.Caption := rstrUpdateFromFile;
    try
      ProgressForm.btnSaveLog.Visible := True;
      ProgressForm.WorkerThread := worker;
      ProgressForm.ShowModal;
      worker.WaitFor;
      Result := worker.Success;
      CommittedChanges := worker.CommittedChanges;
      ProgressForm.SaveErrorLog(LogFileName);
    finally
      ProgressForm.Free;
    end;
  finally
    worker.Free;
  end;

end;

procedure LocateBook;
var
  SearchForm: TfrmBookSearch;
begin
  SearchForm := TfrmBookSearch.Create(Application);
  SearchForm.OnLocateBook := frmMain.LocateBook;
  try
    SearchForm.ShowModal;
  finally
    SearchForm.Free;
  end;
end;

procedure ShowPopup(const Msg: string);
begin
  frmInfoPopup := TfrmInfoPopup.Create(nil);
  frmInfoPopup.lblText.Caption := Msg;
  frmInfoPopup.Refresh;
  frmInfoPopup.Show;
end;

procedure HidePopup;
begin
  if Assigned(frmInfoPopup) then
  begin
    frmInfoPopup.Hide;
    frmInfoPopup.Free;
  end;
end;

end.
