(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             12.02.2010
  * Description
  *
  * $Id: unit_Helpers.pas 1136 2014-02-22 05:34:11Z koreec $
  *
  * History
  * NickR 15.02.2010    Код переформатирован
  *
  ****************************************************************************** *)

unit unit_Helpers;

interface

uses
  Windows,
  Classes,
  StdCtrls,
  Dialogs,
  ComCtrls,
  Graphics,
  Generics.Collections,
  ShlObj,
  unit_Consts;

type
  TIniStringList = class(TStringList)
  public
    constructor Create; overload;
  end;

procedure SetTextNoChange(editControl: TCustomEdit; const newText: string);

function GetFileSize(const FileName: string): Integer;

function ExpandFileNameEx(const basePath: string; const path: string): string;


type
  TMHLFileName = (
    fnGenreList,
    fnOpenCollection,
    fnSelectReader,
    fnSelectScript,
    fnOpenImportFile,
    fnSaveCollection,
    fnSaveLog,
    fnSaveImportFile,
    fnOpenINPX,
    fnSaveINPX,
    fnOpenUserData,
    fnSaveUserData,
    fnOpenCoverImage,
    fnOpenUpdate
  );

  TListViewHelper = class helper for TListView
    procedure AutosizeColumn(nColumn: Integer);
  end;

function GetFileName(key: TMHLFileName; out FileName: string): Boolean;

function GetFolderName(Handle: Integer; const Caption: string; var strFolder: string): Boolean;
function GetFolderShellItem(Handle: HWND; const Caption: string; var strFolder: string; out ShellItem: IShellItem): Boolean;
function ShellCopyFile(const SourceFile: string; const DestFolder: IShellItem; const DestName: string): Boolean;
function ResolveOrCreateShellSubfolder(const Root: IShellItem; const RelPath: string): IShellItem;
function IsShellPath(const Path: string): Boolean;

function CreateImageFromResource(GraphicClass: TGraphicClass; const ResName: string; ResType: PChar = RT_RCDATA): TGraphic;

function MoveToRecycle(sFileName: string): Boolean;

function SimpleShellExecute(
  hWnd: HWND;
  const FileName: string;
  const Parameters: string = '';
  const Operation: string = 'open';
  ShowCmd: Integer = SW_SHOWNORMAL;
  const Directory: string = ''
  ): Cardinal;

implementation

uses
  SysUtils,
  StrUtils,
  IOUtils,
  Forms,
  dm_user,
  CommCtrl,
  ShellAPI,
  ShLwApi,
  ActiveX,
  ComObj;

// ============================================================================
// TIniStringList
// ============================================================================
constructor TIniStringList.Create;
begin
  inherited Create;

  QuoteChar := '"';
  Delimiter := ';';
  StrictDelimiter := True;
end;

// ============================================================================
type
  THackEdit = class(TCustomEdit);

procedure SetTextNoChange(editControl: TCustomEdit; const newText: string);
var
  FOnChange: TNotifyEvent;
begin
  Assert(Assigned(editControl));

  FOnChange := THackEdit(editControl).OnChange;
  THackEdit(editControl).OnChange := nil;
  try
    editControl.Text := newText;
  finally
    THackEdit(editControl).OnChange := FOnChange;
  end;
end;

// ============================================================================
function GetFileSize(const FileName: string): Integer;
var
  hFile: THandle;
  FileSize: Int64;
begin
  hFile := SysUtils.FileOpen(FileName, fmOpenRead or fmShareDenyWrite);
  if hFile = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  try
    if not Windows.GetFileSizeEx(hFile, FileSize) then
      RaiseLastOSError;
    if FileSize > MaxInt then
      raise ERangeError.CreateFmt('File is too large: %s', [FileName]);
    Result := Integer(FileSize);
  finally
    SysUtils.FileClose(hFile);
  end;
end;

function ExpandFileNameEx(const basePath: string; const path: string): string;
var
  pathBuf: array[0..MAX_PATH] of WideChar;
begin
  Result := TPath.Combine(basePath, path);
  if PathCanonicalizeW(pathBuf, PWideChar(Result)) then
    Result := pathBuf;
end;

// ============================================================================
type
  TStdDialogClass = class of TOpenDialog;

function InternalGetFileName(
  DialogClass: TStdDialogClass;
  const Title: string;
  const DefaultExt: string;
  const Filter: string;
  out strFileName: string;
  ExtraOptions: TOpenOptions;
  const dialogKey: string = ''
  ): Boolean;
var
  dlg: TOpenDialog;
begin
  dlg := DialogClass.Create(nil);
  try
    if Title <> '' then
      dlg.Title := Title;
    dlg.DefaultExt := DefaultExt;
    dlg.Filter := Filter;
    dlg.Options := dlg.Options + ExtraOptions;
    dlg.InitialDir := Settings.InitialDir[dialogKey];

    Result := dlg.Execute;
    if Result then
    begin
      strFileName := dlg.FileName;

      Settings.InitialDir[dialogKey] := ExtractFilePath(strFileName);
    end;
  finally
    dlg.Free;
  end;
end;

function GetOpenFileName(
  const Title: string;
  const DefaultExt: string;
  const Filter: string;
  out strFileName: string;
  const dialogKey: string = '';
  ExtraOptions: TOpenOptions = []
  ): Boolean;
begin
  //
  // TODO -oNickR -cUsability : использовать TFileOpenDialog под Vista-ой
  //
  Include(ExtraOptions, ofFileMustExist);
  Include(ExtraOptions, ofNoChangeDir);
  Result := InternalGetFileName(TOpenDialog, Title, DefaultExt, Filter, strFileName, ExtraOptions, dialogKey);
end;

function GetSaveFileName(
  const Title: string;
  const DefaultExt: string;
  const Filter: string;
  out strFileName: string;
  const dialogKey: string = '';
  ExtraOptions: TOpenOptions = []
  ): Boolean;
begin
  //
  // TODO -oNickR -cUsability : использовать TFileSaveDialog под Vista-ой
  //
  Include(ExtraOptions, ofOverwritePrompt);
  Include(ExtraOptions, ofNoChangeDir);
  Result := InternalGetFileName(TSaveDialog, Title, DefaultExt, Filter, strFileName, ExtraOptions, dialogKey);
end;

type
  TDialogParams = record
    Title: string;
    Filter: string;
    DefaultExt: string;
    DialogKey: string;
    OpenFile: Boolean;
  end;

resourcestring
//fnGenreList
   rstrGenreListDlgTitle = 'Выбор списка жанров';
   rstrGenreListDlgFilter = 'Список жанров MyHomeLib (*.glst)|*.glst|Все типы|*.*';
   rstrGenreListDlgDefaultExt = GENRELIST_EXTENSION_SHORT;

   // fnOpenCollection
   rstrOpenCollectionDlgTitle = 'Открыть файл коллекции';
   // fnSaveCollection
   rstrSaveCollectionDlgTitle = 'Сохранить файл коллекции';
   rstrCollectionDlgFilter = 'Коллекция MyHomeLib (*.hlc2)|*.hlc2|Все типы|*.*';
   rstrCollectionDlgDefaultExt = COLLECTION_EXTENSION_SHORT;

   // fnSelectReader
   rstrSelectReaderDlgTitle = 'Выбор программы для просмотра';
   // fnSelectScript
   rstrSelectScriptDlgTitle = 'Выбор скрипта';
   rstrSelectProgrammDlgFilter = 'Скрипты, программы (*.exe;*.bat;*.cmd;*.vbs;*.js)|*.exe;*.bat;*.cmd;*.vbs;*.js|Все типы |*.*';
   rstrSelectProgrammDlgDefaultExt = 'exe';

   // fnOpenImportFile
   rstrOpenImportFileDlgTitle = 'Открыть xml';
   // fnSaveImportFile
   rstrSaveImportFileDlgTitle = 'Сохранить xml';
   rstrImportFileDlgFilter = 'xml (*.xml)|*.xml|Все файлы|*.*';
   rstrImportFileDlgDefaultExt = 'xml';

   // fnSaveLog
   rstrSaveLogDlgTitle = 'Сохранить лог работы';
   rstrSaveLogDlgFilter = 'Файл протокола (*.log)|*.log|Все типы|*.*';
   rstrSaveLogDlgDefaultExt = 'log';
   //fnOpenINPX
   rstrOpenINPXDlgTitle = 'Выбор файла списков';
   rstrOpenINPXDlgFilter = 'Список книг MyHomeLib (*.inpx)|*.inpx|Все типы|*.*';
   rstrOpenINPXDlgDefaultExt = 'inpx';

   //fnSaveINPX
   rstrSaveINPXDlgTitle = 'Выбор файла списков';
   rstrSaveINPXDlgFilter = 'Список книг MyHomeLib (*.inpx)|*.inpx|Все типы|*.*';
   rstrSaveINPXDlgDefaultExt = 'inpx';

   //fnOpenUserData
   rstrOpenUDDlgTitle = 'Импорт пользовательских данных';
   rstrOpenUDDlgFilter = 'Дополнительные данные MyHomeLib (mhlud, mhlud2)|*.mhlud2;*.mhlud|Все типы|*.*';
   rstrOpenUDDlgDefaultExt = 'mhlud2';

   //fnSaveUserData
   rstrSaveUDDlgTitle = 'Экспорт пользовательских данных';
   rstrSaveUDDlgFilter = 'Дополнительные данные MyHomeLib (mhlud2)|*.mhlud2|Все типы|*.*';
   rstrSaveUDDlgDefaultExt = 'mhlud2';

   //fnOpenCoverImage
   rstrOpenCIDlgTitle = 'Загрузка файла обложки';
   rstrOpenCIDlgFilter = 'Изображение (*.png;*.jpg;*.jpeg)|*.jpeg;*.jpg;*.png';
   rstrOpenCIDlgDefaultExt = 'jpeg';

   //fnOpenUpdate
   rstrOpenUpdateDlgTitle = 'Выбор файла обновления';
   rstrOpenUpdateDlgFilter = 'Файл обновления (*.inpx, *.zip)|*.inpx;*.zip|Все типы|*.*';
   rstrOpenUpdateDlgDefaultExt = 'inpx';


function GetFileName(key: TMHLFileName; out FileName: string): Boolean;
const
  DlgParams: array[TMHLFileName] of TDialogParams = (
    ( // fnGenreList
      Title:      rstrGenreListDlgTitle;
      Filter:     rstrGenreListDlgFilter;      DefaultExt: rstrGenreListDlgDefaultExt;
      DialogKey:  'SelectGenreList';           OpenFile:   True
    ),
    ( // fnOpenCollection
      Title:      rstrOpenCollectionDlgTitle;
      Filter:     rstrCollectionDlgFilter;     DefaultExt: rstrCollectionDlgDefaultExt;
      DialogKey:  'OpenCollection';            OpenFile:   True
    ),
    ( // fnSelectReader
      Title:      rstrSelectReaderDlgTitle;
      Filter:     rstrSelectProgrammDlgFilter; DefaultExt: rstrSelectProgrammDlgDefaultExt;
      DialogKey:  'SelectReader';              OpenFile:   True
    ),
    ( // fnSelectScript
      Title:      rstrSelectScriptDlgTitle;
      Filter:     rstrSelectProgrammDlgFilter; DefaultExt: rstrSelectProgrammDlgDefaultExt;
      DialogKey:  'SelectScript';              OpenFile:   True
    ),
    ( // fnOpenImportFile
      Title:      rstrOpenImportFileDlgTitle;
      Filter:     rstrImportFileDlgFilter;     DefaultExt: rstrImportFileDlgDefaultExt;
      DialogKey:  'OpenImportFile';            OpenFile:   True
    ),
    ( // fnSaveCollection
      Title:      rstrSaveCollectionDlgTitle;
      Filter:     rstrCollectionDlgFilter;     DefaultExt: rstrCollectionDlgDefaultExt;
      DialogKey:  'SaveCollection';            OpenFile:   False
    ),
    ( // fnSaveLog
      Title:      rstrSaveLogDlgTitle;
      Filter:     rstrSaveLogDlgFilter;        DefaultExt: rstrSaveLogDlgDefaultExt;
      DialogKey:  'SaveLog';                   OpenFile:   False
    ),
    ( // fnSaveImportFile
      Title:      rstrSaveImportFileDlgTitle;
      Filter:     rstrImportFileDlgFilter;     DefaultExt: rstrImportFileDlgDefaultExt;
      DialogKey:  'SaveImportFile';            OpenFile:   False
    ),
    ( // fnLoadINPX
      Title:      rstrOpenINPXDlgTitle;
      Filter:     rstrOpenINPXDlgFilter;     DefaultExt: rstrOpenINPXDlgDefaultExt;
      DialogKey:  'OpenINPXFile';            OpenFile:   True
    ),
    ( // fnSaveINPX
      Title:      rstrSaveINPXDlgTitle;
      Filter:     rstrSaveINPXDlgFilter;     DefaultExt: rstrSaveINPXDlgDefaultExt;
      DialogKey:  'SaveINPXFile';            OpenFile:   False
    ),
    ( // fnOpenUserData
      Title:      rstrOpenUDDlgTitle;
      Filter:     rstrOpenUDDlgFilter;     DefaultExt: rstrOpenUDDlgDefaultExt;
      DialogKey:  'OpenUserData';            OpenFile: True
    ),
    ( // fnSaveUserData
      Title:      rstrSaveUDDlgTitle;
      Filter:     rstrSaveUDDlgFilter;     DefaultExt: rstrSaveUDDlgDefaultExt;
      DialogKey:  'SaveUserData';            OpenFile: False
    ),
    ( // fnOpenCoverImage
      Title:      rstrOpenCIDlgTitle;
      Filter:     rstrOpenCIDlgFilter;     DefaultExt: rstrOpenCIDlgDefaultExt;
      DialogKey:  'OpenCoverImage';        OpenFile: True
    ),
    ( // fnOpenUpdate
      Title:      rstrOpenUpdateDlgTitle;
      Filter:     rstrOpenUpdateDlgFilter; DefaultExt: rstrOpenUpdateDlgDefaultExt;
      DialogKey:  'OpenUpdateFile';        OpenFile: True
    )


    //(Title: ''; Filter: ''; DefaultExt: ''; ExtraOptions: ; DialogKey: ''; GetFileNameFunction:)
  );
begin
  if DlgParams[key].OpenFile then
    Result := GetOpenFileName(
      DlgParams[key].Title, DlgParams[key].DefaultExt, DlgParams[key].Filter, FileName, DlgParams[key].DialogKey, []
      )
  else
    Result := GetSaveFileName(
      DlgParams[key].Title, DlgParams[key].DefaultExt, DlgParams[key].Filter, FileName, DlgParams[key].DialogKey, []
      );
end;

function GetFolderName(Handle: Integer; const Caption: string; var strFolder: string): Boolean;
var
  Dialog: IFileOpenDialog;
  Options: Cardinal;
  InitFolder, ResultItem: IShellItem;
  DisplayName: PWideChar;
  OwnerWnd: HWND;
begin
  Result := False;

  if Handle <> 0 then
    OwnerWnd := Handle
  else
    OwnerWnd := Application.Handle;

  if not Succeeded(CoCreateInstance(CLSID_FileOpenDialog, nil, CLSCTX_INPROC_SERVER, IFileOpenDialog, Dialog)) then
    Exit;

  Dialog.SetTitle(PChar(Caption));
  Dialog.GetOptions(Options);
  Dialog.SetOptions(Options or FOS_PICKFOLDERS or FOS_FORCEFILESYSTEM);

  if (strFolder <> '') and Succeeded(SHCreateItemFromParsingName(PChar(strFolder), nil, IShellItem, InitFolder)) then
    Dialog.SetFolder(InitFolder);

  if Succeeded(Dialog.Show(OwnerWnd)) then
  begin
    if Succeeded(Dialog.GetResult(ResultItem)) then
    begin
      if Succeeded(ResultItem.GetDisplayName(SIGDN_FILESYSPATH, DisplayName)) then
      begin
        strFolder := DisplayName;
        CoTaskMemFree(DisplayName);
        Result := True;
      end;
    end;
  end;
end;

function GetFolderShellItem(Handle: HWND; const Caption: string; var strFolder: string; out ShellItem: IShellItem): Boolean;
var
  Dialog: IFileOpenDialog;
  Options: Cardinal;
  InitFolder: IShellItem;
  DisplayName: PWideChar;
begin
  Result := False;
  ShellItem := nil;

  if Succeeded(CoCreateInstance(CLSID_FileOpenDialog, nil, CLSCTX_INPROC_SERVER, IFileOpenDialog, Dialog)) then
  begin
    Dialog.SetTitle(PChar(Caption));
    Dialog.GetOptions(Options);
    Dialog.SetOptions((Options or FOS_PICKFOLDERS) and not FOS_FORCEFILESYSTEM); // allow non-filesystem (MTP)

    // Set initial folder if available
    if (strFolder <> '') and Succeeded(SHCreateItemFromParsingName(PChar(strFolder), nil, IShellItem, InitFolder)) then
      Dialog.SetFolder(InitFolder);

    if Succeeded(Dialog.Show(Handle)) then
    begin
      if Succeeded(Dialog.GetResult(ShellItem)) then
      begin
        Result := True;
        if Succeeded(ShellItem.GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING, DisplayName)) then
        begin
          strFolder := DisplayName;
          CoTaskMemFree(DisplayName);
        end;
      end;
    end;
  end;
end;

function ShellCopyFile(const SourceFile: string; const DestFolder: IShellItem; const DestName: string): Boolean;
var
  FileOp: IFileOperation;
  SrcItem: IShellItem;
begin
  Result := False;
  if not Assigned(DestFolder) then
    Exit;

  if Succeeded(CoCreateInstance(CLSID_FileOperation, nil, CLSCTX_INPROC_SERVER, IFileOperation, FileOp)) then
  begin
    // FOF_RENAMEONCOLLISION avoids silent overwrite-failures on MTP when a file
    // with the same name already exists in the target folder (#65).
    FileOp.SetOperationFlags(FOF_NOCONFIRMATION or FOF_NOERRORUI or FOF_SILENT or FOF_RENAMEONCOLLISION);
    if Succeeded(SHCreateItemFromParsingName(PChar(SourceFile), nil, IShellItem, SrcItem)) then
    begin
      if Succeeded(FileOp.CopyItem(SrcItem, DestFolder, PChar(DestName), nil)) then
        Result := Succeeded(FileOp.PerformOperations);
    end;
  end;
end;

// Walk RelPath ('Author\Series\') under Root, creating missing subfolders.
// Works for both filesystem and MTP shell items. Returns nil on failure.
function ResolveOrCreateShellSubfolder(const Root: IShellItem; const RelPath: string): IShellItem;
var
  Segments: TArray<string>;
  Segment, Trimmed: string;
  Current, Child: IShellItem;
  FileOp: IFileOperation;
begin
  Result := nil;
  if not Assigned(Root) then Exit;

  Trimmed := Trim(RelPath);
  if Trimmed <> '' then
    Trimmed := ExcludeTrailingPathDelimiter(Trimmed);
  if Trimmed = '' then
  begin
    Result := Root;
    Exit;
  end;

  Segments := Trimmed.Split([PathDelim, '/']);
  Current := Root;
  for Segment in Segments do
  begin
    if Segment = '' then Continue;

    if Succeeded(SHCreateItemFromRelativeName(Current, PChar(Segment), nil, IShellItem, Child)) then
    begin
      Current := Child;
      Child := nil;
      Continue;
    end;

    // Not found - create it
    if Failed(CoCreateInstance(CLSID_FileOperation, nil, CLSCTX_INPROC_SERVER, IFileOperation, FileOp)) then Exit;
    FileOp.SetOperationFlags(FOF_NOCONFIRMATION or FOF_NOERRORUI or FOF_SILENT);
    if Failed(FileOp.NewItem(Current, FILE_ATTRIBUTE_DIRECTORY, PChar(Segment), nil, nil)) then Exit;
    if Failed(FileOp.PerformOperations) then Exit;
    FileOp := nil;

    if Failed(SHCreateItemFromRelativeName(Current, PChar(Segment), nil, IShellItem, Child)) then Exit;
    Current := Child;
    Child := nil;
  end;
  Result := Current;
end;

function IsShellPath(const Path: string): Boolean;
begin
  // MTP/shell paths start with \\?\ or ::{  or don't have a drive letter
  Result := (Path <> '') and not TPath.DriveExists(Path) and
    ((Pos('\\?\', Path) = 1) or (Pos('::{', Path) = 1) or
     ((Length(Path) >= 2) and (Path[2] <> ':')));
end;

function CreateImageFromResource(GraphicClass: TGraphicClass; const ResName: string; ResType: PChar): TGraphic;
var
  s: TResourceStream;
begin
  s := TResourceStream.Create(HInstance, ResName, ResType);
  try
    Result := GraphicClass.Create;
    Result.LoadFromStream(s);
  finally
    s.Free;
  end;
end;

function SimpleQuoteString(const Value: string): string;
const
  QUOTECHAR = '"';
begin
  if (Value = '') or (Value[1] = QUOTECHAR) then
    Result := Value
  else
    Result := QUOTECHAR + Value + QUOTECHAR;
end;

function SimpleShellExecute(
  hWnd: HWND;
  const FileName: string;
  const Parameters: string = '';
  const Operation: string = 'open';
  ShowCmd: Integer = SW_SHOWNORMAL;
  const Directory: string = ''
  ): Cardinal;
var
  AParameters: string;
  ADirectory: string;
begin
  if pos('"', Parameters) = 0 then
      AParameters := SimpleQuoteString(Parameters)
    else
      AParameters := Parameters;

    //  AFileName := FileName;
//  AParameters := Parameters;

  ADirectory := Directory;
  if ADirectory = '' then
    ADirectory := TPath.GetDirectoryName(Application.ExeName);

  Result := ShellAPI.ShellExecute(
    hWnd,
    PChar(Operation),
    PChar(FileName),
    PChar(AParameters),
    PChar(ADirectory),
    ShowCmd
  );
end;

function MoveToRecycle(sFileName: string): Boolean;
var
  fos: TSHFileOpStruct;
begin
  // SHFileOperation consumes a double-null-terminated list of paths.
  sFileName := sFileName + #0;
  FillChar(fos, SizeOf(fos), 0);
  with fos do
  begin
    wFunc  := FO_DELETE;
    pFrom  := PChar(sFileName);
    fFlags := FOF_ALLOWUNDO or FOF_NOCONFIRMATION or FOF_SILENT;
  end;
  Result := (0 = ShFileOperation(fos));
end;

{ TListViewHelper }

procedure TListViewHelper.AutosizeColumn(nColumn: Integer);
begin
  ListView_SetColumnWidth(Self.Handle, nColumn, LVSCW_AUTOSIZE);
end;

end.



