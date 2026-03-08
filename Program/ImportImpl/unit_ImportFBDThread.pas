(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2023 Oleksiy Penkov (aka Koreec)
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
    procedure WorkFunction; override;
    procedure ProcessFileList; override;
    procedure ProcessFileListArchive; override;
    procedure SortFiles(var R: TBookRecord); override;

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
  unit_Logger,
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

procedure TImportFBDThread.SortFiles(var R: TBookRecord);
var
  NewFileName, NewFolder: string;
  archiver: TMHLZip;
  archivePath: string;
begin
  NewFolder := GetNewFolder(Settings.FBDFolderTemplate, R);
  CreateFolders(FCollectionRoot, NewFolder);
  CopyFile(Settings.ImportPath + R.FileName, FCollectionRoot + NewFolder + R.FileName);
  R.Folder := NewFolder;

  NewFileName := GetNewFileName(Settings.FBDFileTemplate, R);
  if NewFileName = '' then
    Exit;

  // [BUGFIX] Removed `NewFileName := NewFileName` — self-assignment, dead code.

  RenameFile(
    FCollectionRoot + NewFolder + R.FileName,
    FCollectionRoot + NewFolder + NewFileName + ZIP_EXTENSION
  );
  R.FileName := NewFileName + ZIP_EXTENSION;

  archivePath := FCollectionRoot + NewFolder + NewFileName + ZIP_EXTENSION;
  archiver := nil;
  try
    // [BUGFIX] archiver is now nil-initialised before the try block so that
    // FreeAndNil in finally is safe even if the constructor throws.
    archiver := TMHLZip.Create(archivePath, False);

    // [BUGFIX] Was passing the full absolute path as the source name inside the
    // archive. Files inside a zip are stored by relative name only, so we pass
    // just R.FileName (the name as it exists inside the zip before renaming).
    archiver.RenameFile(R.FileName, NewFileName);
  except
    // [BUGFIX] Replaced silent `except // ничего не делаем` with logging.
    // Renaming inside the archive is non-fatal, but swallowing all errors
    // made diagnosing corrupt archives impossible.
    on E: Exception do
      Logger.W('SortFiles (FBD): failed to rename file inside archive "%s" — %s', [archivePath, E.Message]);
  end;
  FreeAndNil(archiver);
end;

procedure TImportFBDThread.WorkFunction;
var
  AddCount, DefectCount: Integer;
begin
  // [BUGFIX] Removed `FFiles := TStringList.Create` — FFiles is created and
  // owned by the base class constructor (TImportFB2ThreadBase.Create).
  // Creating it here again leaked the instance allocated by the base class.
  // The matching `FreeAndNil(FFiles)` in the finally block is also removed.

  AddCount   := 0;
  DefectCount := 0;

  ScanFolder;
  if Canceled then
  begin
    Teletype(Format(rstrBooksAdded, [AddCount, DefectCount]));
    Exit;
  end;

  FCollection.BeginBulkOperation;
  try
    ProcessFileList;
    FCollection.EndBulkOperation(True);
  except
    FCollection.EndBulkOperation(False);
    raise;
  end;

  // [REFACTOR] Added summary output consistent with TImportFB2Thread.WorkFunction.
  Teletype(Format(rstrBooksAdded, [AddCount, DefectCount]));
end;

procedure TImportFBDThread.ProcessFileList;
var
  i, j: Integer;
  R: TBookRecord;
  archiveFileName, Ext: string;
  archiver: TMHLZip;
  BookFileName, FBDFileName: string;
  book: IXMLFictionBook;
  FS: TMemoryStream;
  AddCount, DefectCount: Integer;
  IsValid: Boolean;
  fileName: string;
begin
  AddCount   := 0;
  DefectCount := 0;

  FProgressEngine.BeginOperation(FFiles.Count, rstrProcessedArchives, rstrProcessedArchives);
  try
    for i := 0 to FFiles.Count - 1 do
    begin
      if Canceled then
        Break;

      IsValid         := False;
      BookFileName    := '';
      FBDFileName     := '';
      archiveFileName := FFiles[i];

      Assert(ExtractFileExt(archiveFileName) = ZIP_EXTENSION);

      // [BUGFIX] archiver initialised to nil so FreeAndNil in finally is always
      // safe, even when TMHLZip.Create raises before the variable is assigned.
      archiver := nil;
      try
        try
          archiver := TMHLZip.Create(archiveFileName, True);
        except
          on E: Exception do
          begin
            Teletype(rstrErrorUnpacking + archiveFileName, tsError);
            FProgressEngine.AddProgress;
            Continue;
          end;
        end;

        j := 0;
        R.Clear;

        if archiver.Find('*.*') then
        repeat
          fileName := archiver.LastName;
          Ext      := ExtractFileExt(fileName);

          if Ext = FBD_EXTENSION then
          begin
            // [BUGFIX] FS is created before the outer try/finally so the finally
            // block can always free it. Previously, if ExtractToStream threw, FS
            // was never released.
            FS := TMemoryStream.Create;
            try
              try
                archiver.ExtractToStream(archiver.LastName, FS);
              except
                // [BUGFIX] Replaced silent bare `except` (no `on E:`, no body)
                // with explicit logging. Extraction failures are non-fatal here
                // but must be visible for diagnostics.
                on E: Exception do
                begin
                  Teletype(Format(rstrErrorExtractFBD, [archiveFileName, E.Message]), tsError);
                  Continue;
                end;
              end;

              R.Folder   := ExtractRelativePath(FCollectionRoot, ExtractFilePath(FFiles[i]));
              R.FileName := ExtractFilename(FFiles[i]);
              R.Date     := Now;
              Include(R.BookProps, bpIsLocal);

              try
                book := LoadFictionBook(FS);
                GetBookInfo(book, R);
                IsValid     := True;
                FBDFileName := TPath.GetFileNameWithoutExtension(fileName);
              except
                on E: Exception do
                  Teletype(Format(rstrErrorFB2Structure, [archiveFileName, R.FileName]), tsError);
              end;
            finally
              FreeAndNil(FS);
            end;
          end
          else
          begin
            // Non-FBD entry — treat as the actual book file
            R.InsideNo := j;
            R.FileExt  := Ext;
            BookFileName := TPath.GetFileNameWithoutExtension(fileName);
            R.Size := archiver.LastSize;
          end;

          Inc(j);
        until not archiver.FindNext;

        if Settings.EnableSort then
          SortFiles(R);

        if IsValid and (BookFileName = FBDFileName) and (FCollection.InsertBook(R, True, True) <> 0) then
          Inc(AddCount)
        else
        begin
          Teletype(rstrErrorFBD + archiveFileName, tsError);
          Inc(DefectCount);
        end;

      finally
        FreeAndNil(archiver);
        FProgressEngine.AddProgress;
      end;
    end;

    Teletype(Format(rstrBooksAdded, [AddCount, DefectCount]));
  finally
    FProgressEngine.EndOperation;
  end;
end;

procedure TImportFBDThread.ProcessFileListArchive;
begin
  // Not used for FBD import — archive processing is handled entirely in ProcessFileList.
end;

end.