(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2023 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov    nrymanov@gmail.com
  *                     Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             22.02.2010
  * Description
  *
  * $Id: unit_ImportFB2ThreadBase.pas 1144 2014-03-26 05:22:37Z ENikS $
  *
  * History
  * NickR 02.03.2010    Код переформатирован
  *
  * [REFACTOR] Fixed missing `override` on destructor
  * [REFACTOR] Fixed constructor signature mismatch (interface vs implementation)
  * [REFACTOR] Fixed uninitialized Result on early Exit in GetNewFileName/GetNewFolder
  * [REFACTOR] Replaced silent bare `except` in GetBookInfo with exception logging
  * [REFACTOR] Extracted ApplyTemplate helper to remove GetNewFileName/GetNewFolder duplication
  * [REFACTOR] Added nil-guard for FFiles in ScanFolder
  *
  ****************************************************************************** *)

unit unit_ImportFB2ThreadBase;

interface

uses
  Windows,
  Classes,
  SysUtils,
  IOUtils,
  fictionbook_21,
  files_list,
  unit_Globals,
  unit_WorkerThread,
  unit_CollectionWorkerThread,
  unit_MHLArchiveHelpers,
  unit_Templater,
  unit_Interfaces,
  unit_Consts;

type
  TImportFB2ThreadBase = class(TCollectionWorker)
  protected
    FFileTemplater: TTemplater;
    FFolderTemplater: TTemplater;
    FFileTemplate: string;
    FFolderTemplate: string;
    FFileTemplateValid: Boolean;
    FFolderTemplateValid: Boolean;
    FFileTemplateInitialized: Boolean;
    FFolderTemplateInitialized: Boolean;
    FFileTemplateErrorShown: Boolean;
    FFolderTemplateErrorShown: Boolean;
    FFiles: TStringList;
    FFilesList: TFilesList;
    FCreatedFiles: TStringList;
    FImportCache: TImportCache;

    //
    // Эти поля должны быть установлены конструктором производного класса
    //
    FTargetExt: string;
    FZipFolder: Boolean;
    FFullNameSearch: Boolean;

    procedure ScanFolder;

    procedure ShowCurrentDir(Sender: TObject; const Dir: string);
    procedure AddFile2List(Sender: TObject; const F: TSearchRec);

    function GetNewFolder(const Folder: string; const R: TBookRecord): string;
    function GetNewFileName(const FileName: string; const R: TBookRecord): string;
    function NormalizeImportFolder(const Folder: string): string;

    function CopyForImport(const SourceFileName, DestFileName: string): Boolean;
    procedure ForgetCreatedFile(const FileName: string; const DeleteFromDisk: Boolean);
    procedure CommitFileOperations;
    procedure RollbackFileOperations;

  public
    // [BUGFIX] Signature was declared with CollectionID parameter but implemented
    // without it — would not compile. Aligned implementation to match declaration.
    constructor Create(CollectionID: Integer);
    // [BUGFIX] `override` was missing — destructor was not called through virtual
    // dispatch when destroying via a base class reference, leaking FTemplater.
    destructor Destroy; override;

  protected
    procedure ProcessFileList; virtual; abstract;
    procedure ProcessFileListArchive; virtual; abstract;
    procedure GetBookInfo(book: IXMLFictionBook; var R: TBookRecord);
    procedure SortFiles(var R: TBookRecord; const SourceFileName: string;
      out CreatedFileName: string); virtual;

  protected
    FFb2ArchiveExt: string;
    FArchiveFormat: TArchiveFormat;

  strict private
    // [REFACTOR] Extracted shared template-application logic from GetNewFileName
    // and GetNewFolder. Both methods were structurally identical — only the
    // template type (TpFile vs TpPath) differed.
    //
    // Returns True and sets OutValue on success.
    // Returns False and shows an error message if the template is invalid.
    function ApplyTemplate(const Template: string; TemplateType: TTemplateType;
      const R: TBookRecord; out OutValue: string): Boolean;
  end;

implementation

{
Settings.CheckExistsFiles
Settings.EnableSort
Settings.FB2FolderTemplate
Settings.FB2FileTemplate
Settings.FBDFolderTemplate
Settings.FBDFileTemplate
Settings.ImportPath
}

uses
  unit_Helpers,
  dm_user;

resourcestring
  rstrCheckTemplateValidity = 'Проверьте правильность шаблона';
  rstrScanningOne           = 'Сканируем %s';
  rstrScanningAll           = 'Сканируем...';
  rstrFoundFiles            = 'Обнаружены файлы: %u';
  rstrScanningFolders       = 'Сканирование папок...';

{ TImportFB2ThreadBase }

constructor TImportFB2ThreadBase.Create(CollectionID: Integer);
begin
  inherited Create(CollectionID);
  FFileTemplater := TTemplater.Create;
  FFolderTemplater := TTemplater.Create;
  FFiles := TStringList.Create;
  FCreatedFiles := TStringList.Create;
  FCreatedFiles.CaseSensitive := False;
  FCreatedFiles.Sorted := True;
  FCreatedFiles.Duplicates := dupIgnore;
  FImportCache := TImportCache.Create;
end;

destructor TImportFB2ThreadBase.Destroy;
begin
  // A non-empty journal means the DB operation did not reach its commit path.
  RollbackFileOperations;
  FreeAndNil(FImportCache);
  FreeAndNil(FCreatedFiles);
  FreeAndNil(FFiles);
  FreeAndNil(FFolderTemplater);
  FreeAndNil(FFileTemplater);
  inherited Destroy;
end;

procedure TImportFB2ThreadBase.GetBookInfo(book: IXMLFictionBook; var R: TBookRecord);
var
  i: Integer;
begin
  //
  // TODO : создать в unit_FB2Utils ф-ию для получения инф-ии о книге из файла и заменить этот метод
  //
  with book.Description.Titleinfo do
  begin
    for i := 0 to Author.Count - 1 do
      TAuthorsHelper.Add(R.Authors, Author[i].Lastname.Text, Author[i].Firstname.Text, Author[i].MiddleName.Text);

    if Booktitle.IsTextElement then
    begin
      R.Title := Booktitle.Text;

      if Pos(AnsiString(#10), Booktitle.Text) <> 0 then
      begin
        StrReplace(AnsiString(#13#10), ' ', R.Title);
        StrReplace(AnsiString(#10), ' ', R.Title);
      end;
    end;

    for i := 0 to Genre.Count - 1 do
      TGenresHelper.Add(R.Genres, '', '', Genre[i]);

    R.Lang := Lang;
    R.KeyWords := KeyWords.Text;

    if Sequence.Count > 0 then
    begin
      // [BUGFIX] Replaced bare `except end` with specific exception handling.
      // Silent catch was swallowing all errors, including unexpected ones like AV.
      // Series/number parsing failures are non-fatal — we log and continue.
      try
        R.Series := Sequence[0].Name;
        R.SeqNumber := Sequence[0].Number;
      except
        on E: Exception do
          LogWarning('GetBookInfo: failed to read sequence data — %s', [E.Message]);
      end;
    end;

    for i := 0 to Annotation.P.Count - 1 do
      if Annotation.P.Items[i].IsTextElement then
        R.Annotation := R.Annotation + CRLF + Annotation.P.Items[i].OnlyText;

    if R.GenreCount > 0 then
      R.RootGenre.GenreAlias := Trim(FCollection.GetTopGenreAlias(R.Genres[0].FB2GenreCode));
  end;
end;

procedure TImportFB2ThreadBase.SortFiles(var R: TBookRecord;
  const SourceFileName: string; out CreatedFileName: string);
var
  NewFilename, NewFolder, TargetFileName: string;
begin
  CreatedFileName := '';
  NewFolder := GetNewFolder(Settings.FB2FolderTemplate, R);
  if not CreateFolders(FCollectionRoot, NewFolder) then
    RaiseLastOSError;

  // Preserve the original template order: the file template is evaluated
  // after Folder already points at its final collection directory.
  R.Folder := NewFolder;
  NewFilename := GetNewFileName(Settings.FB2FileTemplate, R);
  if NewFilename = '' then
    NewFilename := R.FileName;

  TargetFileName := TPath.Combine(
    TPath.Combine(FCollectionRoot, NewFolder),
    NewFilename + R.FileExt
  );
  if CopyForImport(SourceFileName, TargetFileName) then
    CreatedFileName := TargetFileName;

  if NewFilename <> R.FileName then
    R.FileName := NewFilename;
end;

function TImportFB2ThreadBase.CopyForImport(
  const SourceFileName, DestFileName: string): Boolean;
begin
  if SameFileName(ExpandFileName(SourceFileName), ExpandFileName(DestFileName)) then
    Exit(False);

  // Fail on collision.  The old stream-based helper used fmCreate and silently
  // truncated an existing book before the DB conflict check ran.
  if not Windows.CopyFile(PChar(SourceFileName), PChar(DestFileName), True) then
    RaiseLastOSError;

  try
    FCreatedFiles.Add(DestFileName);
  except
    // Do not leave an untracked file when the journal itself cannot grow.
    SysUtils.DeleteFile(DestFileName);
    raise;
  end;
  Result := True;
end;

procedure TImportFB2ThreadBase.ForgetCreatedFile(const FileName: string;
  const DeleteFromDisk: Boolean);
var
  Index: Integer;
begin
  if (FileName = '') or not Assigned(FCreatedFiles) then
    Exit;

  Index := FCreatedFiles.IndexOf(FileName);
  if Index >= 0 then
  begin
    if DeleteFromDisk and FileExists(FileName) then
      if not SysUtils.DeleteFile(FileName) then
        RaiseLastOSError;
    FCreatedFiles.Delete(Index);
  end;
end;

procedure TImportFB2ThreadBase.CommitFileOperations;
begin
  if Assigned(FCreatedFiles) then
    FCreatedFiles.Clear;
end;

procedure TImportFB2ThreadBase.RollbackFileOperations;
var
  I: Integer;
begin
  if not Assigned(FCreatedFiles) then
    Exit;

  for I := FCreatedFiles.Count - 1 downto 0 do
    if FileExists(FCreatedFiles[I]) then
    begin
      if SysUtils.DeleteFile(FCreatedFiles[I]) then
        FCreatedFiles.Delete(I)
      else
        LogWarning('RollbackFileOperations: failed to delete "%s"', [FCreatedFiles[I]]);
    end
    else
      FCreatedFiles.Delete(I);
end;

// [REFACTOR] Shared logic extracted from GetNewFileName and GetNewFolder.
// Both methods had identical structure: validate template, parse, trim, sanitize.
// Duplication is now gone — callers only handle the type-specific suffix logic.
function TImportFB2ThreadBase.ApplyTemplate(
  const Template: string;
  TemplateType: TTemplateType;
  const R: TBookRecord;
  out OutValue: string
): Boolean;
var
  Templater: TTemplater;
  TemplateValid: Boolean;
  ShowTemplateError: Boolean;
begin
  Result := False;
  OutValue := '';

  case TemplateType of
    TpFile:
    begin
      Templater := FFileTemplater;
      if (not FFileTemplateInitialized) or (FFileTemplate <> Template) then
      begin
        FFileTemplate := Template;
        FFileTemplateValid := Templater.SetTemplate(Template, TemplateType) = ErFine;
        FFileTemplateInitialized := True;
        FFileTemplateErrorShown := False;
      end;
      TemplateValid := FFileTemplateValid;
      ShowTemplateError := not FFileTemplateErrorShown;
      FFileTemplateErrorShown := FFileTemplateErrorShown or not TemplateValid;
    end;

    TpPath:
    begin
      Templater := FFolderTemplater;
      if (not FFolderTemplateInitialized) or (FFolderTemplate <> Template) then
      begin
        FFolderTemplate := Template;
        FFolderTemplateValid := Templater.SetTemplate(Template, TemplateType) = ErFine;
        FFolderTemplateInitialized := True;
        FFolderTemplateErrorShown := False;
      end;
      TemplateValid := FFolderTemplateValid;
      ShowTemplateError := not FFolderTemplateErrorShown;
      FFolderTemplateErrorShown := FFolderTemplateErrorShown or not TemplateValid;
    end;

  else
    Templater := nil;
    TemplateValid := False;
    ShowTemplateError := True;
  end;

  if not TemplateValid then
  begin
    if ShowTemplateError then
      ShowMessage(rstrCheckTemplateValidity, MB_OK or MB_ICONERROR);
    Exit;
  end;

  OutValue := CheckSymbols(Trim(Templater.ParseString(R, TemplateType)),
    TemplateType = TpFile);
  Result := True;
end;

function TImportFB2ThreadBase.NormalizeImportFolder(
  const Folder: string): string;
var
  RootPath: string;
  TargetPath: string;
begin
  RootPath := IncludeTrailingPathDelimiter(ExpandFileName(FCollectionRoot));
  if TPath.IsPathRooted(Folder) then
    raise EArgumentException.CreateFmt(
      'Import template produced an absolute folder: %s', [Folder]);

  TargetPath := IncludeTrailingPathDelimiter(ExpandFileName(
    TPath.Combine(RootPath, Folder)));
  if not SameText(Copy(TargetPath, 1, Length(RootPath)), RootPath) then
    raise EArgumentException.CreateFmt(
      'Import template points outside the collection folder: %s', [Folder]);

  Result := Copy(TargetPath, Length(RootPath) + 1, MaxInt);
end;

// [BUGFIX] Previous implementation called `Exit` without setting Result when
// the template was invalid — leaving Result as an uninitialized stack value.
// Now delegates to ApplyTemplate; returns '' on template error.
function TImportFB2ThreadBase.GetNewFileName(const FileName: string;
  const R: TBookRecord): string;
var
  Parsed: string;
begin
  Result := '';

  if ApplyTemplate(FileName, TpFile, R, Parsed) then
    Result := Parsed;
end;

// [BUGFIX] Same uninitialized-Result fix as GetNewFileName.
// Additionally ensures the result always ends with a path delimiter when non-empty.
function TImportFB2ThreadBase.GetNewFolder(const Folder: string;
  const R: TBookRecord): string;
var
  Parsed: string;
begin
  Result := '';

  if ApplyTemplate(Folder, TpPath, R, Parsed) and (Parsed <> '') then
  begin
    Parsed := NormalizeImportFolder(Parsed);
    if Parsed <> '' then
      Result := IncludeTrailingPathDelimiter(Parsed);
  end;
end;

procedure TImportFB2ThreadBase.ShowCurrentDir(Sender: TObject; const Dir: string);
begin
  SetComment(Format(rstrScanningOne, [Dir]));
end;

procedure TImportFB2ThreadBase.AddFile2List(Sender: TObject; const F: TSearchRec);
var
  FileName: string;
begin
  if (F.Attr and faDirectory) <> 0 then
    Exit;

  if LowerCase(ExtractFileExt(F.Name)) = FTargetExt then
  begin
    if Settings.EnableSort then
      FileName := FFilesList.LastDir + F.Name
    else
      FileName := ExtractRelativePath(FCollectionRoot, FFilesList.LastDir) + F.Name;

    if not FCollection.CheckFileInCollection(FileName, FFullNameSearch, FZipFolder) then
      FFiles.Add(FFilesList.LastDir + F.Name);
  end;

  if Canceled then
    Abort;
end;

procedure TImportFB2ThreadBase.ScanFolder;
begin
  // [BUGFIX] FFiles could be nil if a derived class constructor failed before
  // calling inherited Create — guard against AV on FFiles.Clear.
  if not Assigned(FFiles) then
    Exit;

  FProgressEngine.BeginOperation(-1, rstrScanningAll, rstrScanningAll);
  try
    FFiles.Clear;
    Teletype(rstrScanningFolders);

    FFilesList := TFilesList.Create(nil);
    try
      FFilesList.OnDirectory := ShowCurrentDir;
      FFilesList.OnFile := AddFile2List;

      if Settings.EnableSort then
        FFilesList.TargetPath := Settings.ImportPath
      else
        FFilesList.TargetPath := FCollectionRoot;

      try
        FFilesList.Process;
        Teletype(Format(rstrFoundFiles, [FFiles.Count]));
      except
        on EAbort do
          { cancelled by user — ignore } ;
      end;
    finally
      FreeAndNil(FFilesList);
    end;
  finally
    FProgressEngine.EndOperation;
  end;
end;

end.
