(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  *                     Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             20.08.2008
  * Description
  *
  * $Id: unit_ImportFBDThread.pas 1119 2012-10-29 01:52:46Z koreec $
  *
  * History
  *
  * [REFACTOR] Removed duplicate FFiles creation in WorkFunction (now owned by
  *            base class constructor after previous refactor)
  * [REFACTOR] Fixed TMHLZip leak in SortFiles when constructor/RenameFile throws
  * [REFACTOR] Replaced silent bare `except` in SortFiles with logging
  * [REFACTOR] Fixed self-assignment `NewFileName := NewFileName` in SortFiles
  * [REFACTOR] Fixed wrong path passed to archiver.RenameFile in SortFiles —
  *            was passing full absolute path instead of filename inside the archive
  * [REFACTOR] Fixed TMHLZip leak in ProcessFileList when constructor throws
  * [REFACTOR] Fixed TMemoryStream leak when ExtractToStream throws
  * [REFACTOR] Replaced silent bare `except` for ExtractToStream with logging
  * [REFACTOR] Clarified nested try/except/finally structure in ProcessFileList
  * [REFACTOR] Added summary Teletype at the end of WorkFunction
  *
  ****************************************************************************** *)

unit unit_ImportFBDThread;

interface

uses
  unit_ImportFB2ThreadBase,
  unit_Globals;

type
  TImportFBDThread = class(TImportFB2ThreadBase)
  protected
    FAddCount: Integer;
    FDefectCount: Integer;
    FDescriptionEntryName: string;

    procedure WorkFunction; override;
    procedure ProcessFileList; override;
    procedure ProcessFileListArchive; override;
    procedure SortFiles(var R: TBookRecord; const SourceFileName: string;
      out CreatedFileName: string); override;

  public
    constructor Create(const CollectionID: Integer);
  end;

implementation

uses
  Classes,
  SysUtils,
  IOUtils,
  unit_WorkerThread,
  FictionBook_21,
  unit_Consts,
  unit_Helpers,
  dm_user,
  unit_MHLArchiveHelpers;

resourcestring
  rstrFoundNewArchives  = 'Найдены новые архивы: %u';
  rstrErrorFB2Structure = 'Ошибка структуры fb2: %s -> %s.fbd';
  rstrErrorFBD          = 'Ошибка FBD: ';
  rstrErrorUnpacking    = 'Ошибка распаковки архива: ';
  rstrProcessedArchives = 'Обработаны архивы: %u из %u';
  rstrBooksAdded        = 'Добавлено книг: %u, пропущено книг: %u';
  rstrErrorExtractFBD   = 'Ошибка извлечения файла из архива %s: %s';
  rstrErrorRenameFBD    = 'Ошибка переименования файла в архиве %s: %s';

{ TImportFBDThread }

constructor TImportFBDThread.Create(const CollectionID: Integer);
begin
  inherited Create(CollectionID);

  FTargetExt    := ZIP_EXTENSION;
  FZipFolder    := False;
  FFullNameSearch := True;
end;

procedure TImportFBDThread.SortFiles(var R: TBookRecord;
  const SourceFileName: string; out CreatedFileName: string);
var
  NewFileName, NewFolder: string;
  NewArchiveName: string;
  OldBookEntryName: string;
  OldDescriptionEntryName: string;
  archiver: TMHLZip;
  archivePath: string;
begin
  CreatedFileName := '';
  NewFolder := GetNewFolder(Settings.FBDFolderTemplate, R);
  if not CreateFolders(FCollectionRoot, NewFolder) then
    RaiseLastOSError;

  R.Folder := NewFolder;
  NewFileName := GetNewFileName(Settings.FBDFileTemplate, R);
  if NewFileName <> '' then
    NewArchiveName := NewFileName + ZIP_EXTENSION
  else
    NewArchiveName := ExtractFileName(SourceFileName);

  archivePath := TPath.Combine(
    TPath.Combine(FCollectionRoot, NewFolder), NewArchiveName
  );
  if CopyForImport(SourceFileName, archivePath) then
    CreatedFileName := archivePath;

  // FileName is the outer FBD zip name.  It may only change after the new
  // container was successfully created; inner-entry renames are independent.
  R.FileName := NewArchiveName;

  if NewFileName = '' then
    Exit;

  archiver := nil;
  try
    archiver := TMHLZip.Create(archivePath, False, True);
    OldBookEntryName := archiver.FileNameAt(R.InsideNo);
    OldDescriptionEntryName := FDescriptionEntryName;

    try
      archiver.RenameFile(OldBookEntryName, NewFileName + R.FileExt);
      R.InsideNo := archiver.LastIndex;
      if OldDescriptionEntryName <> '' then
        archiver.RenameFile(OldDescriptionEntryName, NewFileName + FBD_EXTENSION);
    except
      on E: Exception do
        LogWarning('SortFiles (FBD): failed to rename entries inside archive "%s" — %s',
          [archivePath, E.Message]);
    end;
  finally
    FreeAndNil(archiver);
  end;
end;
procedure TImportFBDThread.WorkFunction;
var
  BulkOperationActive: Boolean;
begin
  // [BUGFIX] Removed `FFiles := TStringList.Create` — FFiles is created and
  // owned by the base class constructor (TImportFB2ThreadBase.Create).
  // Creating it here again leaked the instance allocated by the base class.
  // The matching `FreeAndNil(FFiles)` in the finally block is also removed.

  FAddCount := 0;
  FDefectCount := 0;

  ScanFolder;
  if Canceled then
  begin
    Teletype(Format(rstrBooksAdded, [FAddCount, FDefectCount]));
    Exit;
  end;

  BulkOperationActive := True;
  FCollection.BeginBulkOperation;
  try
    ProcessFileList;
    if Canceled then
    begin
      FCollection.EndBulkOperation(False);
      BulkOperationActive := False;
      RollbackFileOperations;
      Exit;
    end;
    FCollection.EndBulkOperation(True);
    BulkOperationActive := False;
    CommitFileOperations;
  except
    try
      if BulkOperationActive then
        FCollection.EndBulkOperation(False);
    finally
      RollbackFileOperations;
    end;
    raise;
  end;

  // [REFACTOR] Added summary output consistent with TImportFB2Thread.WorkFunction.
  Teletype(Format(rstrBooksAdded, [FAddCount, FDefectCount]));
end;
procedure TImportFBDThread.ProcessFileList;
type
  TArchiveEntryInfo = record
    Name: string;
    Index: Integer;
    Size: Integer;
  end;
  TArchiveEntryArray = array of TArchiveEntryInfo;
var
  i, j, k: Integer;
  R: TBookRecord;
  archiveFileName: string;
  archiver: TMHLZip;
  book: IXMLFictionBook;
  FS: TMemoryStream;
  Entries: TArchiveEntryArray;
  DescriptionIndex: Integer;
  BookIndex: Integer;
  CandidateBookIndex: Integer;
  MatchingBooks: Integer;
  PairCount: Integer;
  CreatedFileName: string;
  BookID: Integer;

  function EntryBaseName(const EntryName: string): string;
  begin
    Result := ChangeFileExt(
      StringReplace(EntryName, '/', '\', [rfReplaceAll]), ''
    );
  end;

  function IsDirectoryEntry(const EntryName: string): Boolean;
  var
    L: Integer;
  begin
    L := Length(EntryName);
    Result := (L > 0) and CharInSet(EntryName[L], ['/', '\']);
  end;
begin
  FProgressEngine.BeginOperation(FFiles.Count, rstrProcessedArchives, rstrProcessedArchives);
  try
    for i := 0 to FFiles.Count - 1 do
    begin
      if Canceled then
        Break;

      archiveFileName := FFiles[i];
      CreatedFileName := '';
      FDescriptionEntryName := '';
      archiver := nil;
      try
        try
          archiver := TMHLZip.Create(archiveFileName, True);

          SetLength(Entries, 0);
          if archiver.Find('*.*') then
          repeat
            if not IsDirectoryEntry(archiver.LastName) then
            begin
              j := Length(Entries);
              SetLength(Entries, j + 1);
              Entries[j].Name := archiver.LastName;
              Entries[j].Index := archiver.LastIndex;
              Entries[j].Size := archiver.LastSize;
            end;
          until not archiver.FindNext;

          DescriptionIndex := -1;
          BookIndex := -1;
          PairCount := 0;
          for j := 0 to High(Entries) do
            if SameText(ExtractFileExt(Entries[j].Name), FBD_EXTENSION) then
            begin
              MatchingBooks := 0;
              CandidateBookIndex := -1;
              for k := 0 to High(Entries) do
                if (k <> j) and
                   not SameText(ExtractFileExt(Entries[k].Name), FBD_EXTENSION) and
                   SameText(EntryBaseName(Entries[k].Name),
                     EntryBaseName(Entries[j].Name)) then
                begin
                  Inc(MatchingBooks);
                  CandidateBookIndex := k;
                end;

              if MatchingBooks = 1 then
              begin
                Inc(PairCount);
                DescriptionIndex := j;
                BookIndex := CandidateBookIndex;
              end;
            end;

          if (PairCount <> 1) or (DescriptionIndex < 0) or (BookIndex < 0) then
            raise EInvalidOpException.Create('FBD archive must contain one matching description/book pair');

          // Preserve the exact descriptor selected by the pairing algorithm.
          // Looking it up again by '*.fbd' after copying could rename an
          // unrelated auxiliary descriptor that happened to occur first.
          FDescriptionEntryName := Entries[DescriptionIndex].Name;

          R.Clear;
          R.Folder   := ExtractRelativePath(FCollectionRoot,
            ExtractFilePath(archiveFileName));
          R.FileName := ExtractFileName(archiveFileName);
          R.FileExt  := LowerCase(ExtractFileExt(Entries[BookIndex].Name));
          R.InsideNo := Entries[BookIndex].Index;
          R.Size     := Entries[BookIndex].Size;
          R.Date     := Now;
          Include(R.BookProps, bpIsLocal);

          FS := TMemoryStream.Create;
          try
            try
              archiver.ExtractToStream(Entries[DescriptionIndex].Index, FS);
              book := LoadFictionBook(FS);
              GetBookInfo(book, R);
            except
              on E: Exception do
              begin
                Teletype(Format(rstrErrorFB2Structure,
                  [archiveFileName, R.FileName]), tsError);
                LogWarning('FBD metadata parse failed for "%s" — %s',
                  [archiveFileName, E.Message]);
                raise;
              end;
            end;
          finally
            FreeAndNil(FS);
          end;
        finally
          FreeAndNil(archiver);
        end;

        if Settings.EnableSort then
          SortFiles(R, archiveFileName, CreatedFileName);

        BookID := FCollection.InsertBook(R, True, True, FImportCache);
        if BookID <> 0 then
          Inc(FAddCount)
        else
        begin
          ForgetCreatedFile(CreatedFileName, True);
          Inc(FDefectCount);
          Teletype(rstrErrorFBD + archiveFileName, tsError);
        end;
      except
        on E: Exception do
        begin
          ForgetCreatedFile(CreatedFileName, True);
          Teletype(rstrErrorUnpacking + archiveFileName, tsError);
          LogWarning('FBD import failed for "%s" — %s',
            [archiveFileName, E.Message]);
          Inc(FDefectCount);
        end;
      end;

      FProgressEngine.AddProgress;
    end;

    Teletype(Format(rstrBooksAdded, [FAddCount, FDefectCount]));
  finally
    FProgressEngine.EndOperation;
  end;
end;

procedure TImportFBDThread.ProcessFileListArchive;
begin
  // Not used for FBD import — archive processing is handled entirely in ProcessFileList.
end;

end.
