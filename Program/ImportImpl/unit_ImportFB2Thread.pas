{******************************************************************************}
{                                                                              }
{ MyHomeLib                                                                    }
{                                                                              }
{ Version 0.9                                                                  }
{ 20.08.2008                                                                   }
{ Copyright (c) Oleksiy Penkov  oleksiy.penkov@gmail.com                       }
{                                                                              }
{ @author Nick Rymanov nrymanov@gmail.com                                      }
{                                                                              }
{ [REFACTOR] Fixed constructor signature mismatch (interface vs implementation)}
{ [REFACTOR] Removed duplicate FFiles creation in WorkFunction (now owned by  }
{            base class constructor after previous refactor)                   }
{ [REFACTOR] Fixed TMHLZip leak when constructor throws in ProcessFileListArchive}
{ [REFACTOR] Fixed TMemoryStream leak when ExtractToStream throws              }
{ [REFACTOR] Replaced silent bare `except` in SortFilesZip with logging       }
{ [REFACTOR] Removed dead empty try/finally in ProcessFileList                 }
{ [REFACTOR] Fixed typo in rstrAddedBooks resource string                      }
{                                                                              }
{******************************************************************************}

unit unit_ImportFB2Thread;

interface

uses
  unit_ImportFB2ThreadBase,
  unit_Globals,
  unit_MHLArchiveHelpers;

type

  TImportFB2Thread = class(TImportFB2ThreadBase)
  protected
    FAddCount: Integer;
    FDefectCount: Integer;
    FArchAdded: Integer;
    FFb2Added: Integer;

    procedure WorkFunction; override;
    procedure ProcessFileList; override;
    procedure ProcessFileListArchive; override;
    procedure SortFilesZip(var R: TBookRecord);

  public
    // [BUGFIX] Signature now matches the interface declaration exactly.
    constructor Create(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat);
  end;

implementation

uses
  Classes,
  SysUtils,
  IOUtils,
  unit_WorkerThread,
  FictionBook_21,
  unit_Helpers,
  unit_Consts,
  unit_Logger,
  dm_user,
  unit_Templater;

resourcestring
  rstrStructureError         = 'Ошибка структуры fb2: %s.zip -> %s';
  rstrProcessedFiles         = 'Обработаны файлы: %u из %u';
  rstrAddedFiles             = 'Добавлены файлы: %u из %u';
  rstrErrorUnpackingWithCode = 'Ошибка распаковки архива %s, Код: %d';
  rstrFoundNewArchives       = 'Обнаружены новые архивы: %u';
  rstrErrorFB2Structure      = 'Ошибка структуры fb2: %s -> %s';
  rstrErrorUnpacking         = 'Ошибка распаковки архива: ';
  rstrProcessedArchives      = 'Обработаны архивы: %u из %u';
  // [BUGFIX] Removed stray ',;' typo — was: 'Добавлено книг: %u,; пропущено книг: %u'
  rstrAddedBooks             = 'Добавлено книг: %u; пропущено книг: %u';
  rstrAddedBooksTotal        = 'Добавлено всего книг: %u; пропущено всего книг: %u';
  rstrImportFB2              = 'Импорт файлов fb2:';
  rstrImportFB2Zip           = 'Импорт файлов fb2.zip:';
  rstrErrorRenamingInArchive = 'Ошибка переименования файла в архиве %s: %s';

{ TImportFB2Thread }

// [BUGFIX] Original implementation had no parameters — would not compile against
// the interface declaration. Parameters are now correctly forwarded to base class.
constructor TImportFB2Thread.Create(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat);
begin
  inherited Create(CollectionID);

  FFullNameSearch := False;
  FArchiveFormat := ArchiveFormat;
end;

procedure TImportFB2Thread.ProcessFileList;
var
  i: Integer;
  R: TBookRecord;
  book: IXMLFictionBook;
  FileName: string;
  Added, Defective: Integer;
begin
  Added := 0;
  Defective := 0;

  FProgressEngine.BeginOperation(FFiles.Count, rstrProcessedFiles, rstrProcessedFiles);
  try
    for i := 0 to FFiles.Count - 1 do
    begin
      if Canceled then
        Break;

      R.Clear;
      FileName := ExtractFileName(FFiles[i]);
      R.FileExt := ExtractFileExt(FileName);
      R.FileName := TPath.GetFileNameWithoutExtension(CleanFileName(FileName));
      R.Size := unit_Helpers.GetFileSize(FFiles[i]);
      R.Date := Now;
      Include(R.BookProps, bpIsLocal);

      try
        if Settings.EnableSort then
        begin
          R.Folder := ExtractFilePath(FFiles[i]);
          book := LoadFictionBook(FFiles[i]);
          GetBookInfo(book, R);
          SortFiles(R);
        end
        else
        begin
          R.Folder := ExtractRelativePath(FCollectionRoot, ExtractFilePath(FFiles[i]));
          book := LoadFictionBook(FFiles[i]);
          GetBookInfo(book, R);
        end;
        FCollection.InsertBook(R, True, True);
        Inc(Added);
      except
        on E: Exception do
        begin
          Teletype(Format(rstrStructureError, [R.Folder, R.FileName + FB2_EXTENSION]), tsError);
          Inc(Defective);
        end;
      end;

      FProgressEngine.AddProgress;
    end;

    // [REFACTOR] Removed dead empty try/finally block that surrounded the loop —
    // it had no statements in the finally section and served no purpose.

    Teletype(Format(rstrAddedBooks, [Added, Defective]), tsInfo);
    FAddCount := Added;
    FDefectCount := Defective;
  finally
    FProgressEngine.EndOperation;
  end;
end;

procedure TImportFB2Thread.ProcessFileListArchive;
var
  i, j: Integer;
  R: TBookRecord;
  AFileName: string;
  book: IXMLFictionBook;
  FS: TMemoryStream;
  NoErrors: Boolean;
  numFb2FilesInZip: Integer;
  Zip: TMHLZip;
  Added, Defective: Integer;
begin
  Added := 0;
  Defective := 0;

  FProgressEngine.BeginOperation(FFiles.Count, rstrProcessedArchives, rstrProcessedArchives);
  try
    for i := 0 to FFiles.Count - 1 do
    begin
      if Canceled then
        Break;

      NoErrors := True;
      Zip := nil;

      // [BUGFIX] Zip is initialised to nil before the try so that FreeAndNil in
      // the finally block is always safe, even when the constructor throws.
      try
        try
          Zip := TMHLZip.Create(FFiles[i], True);
        except
          on E: Exception do
          begin
            Teletype(rstrErrorUnpacking + FFiles[i], tsError);
            FProgressEngine.AddProgress;
            Continue;
          end;
        end;

        j := 0;
        numFb2FilesInZip := 0;

        if Zip.Find('*.fb2') then
        repeat
          R.Clear;
          AFileName := Zip.LastName;
          R.FileExt := ExtractFileExt(AFileName);

          if R.FileExt = FB2_EXTENSION then
          begin
            Inc(numFb2FilesInZip);

            R.FileName := TPath.GetFileNameWithoutExtension(CleanFileName(AFileName));
            R.Size     := Zip.LastSize;
            R.InsideNo := j;
            R.Date     := Now;
            Include(R.BookProps, bpIsLocal);

            // [BUGFIX] FS is now created before the try/finally so that the
            // finally block can always free it — previously if ExtractToStream
            // threw, FS was never freed.
            FS := TMemoryStream.Create;
            try
              Zip.ExtractToStream(AFileName, FS);
              try
                book := LoadFictionBook(FS);
                GetBookInfo(book, R);
                if not Settings.EnableSort then
                begin
                  R.Folder := ExtractRelativePath(FCollectionRoot, FFiles[i]);
                  if FCollection.InsertBook(R, True, True) <> 0 then
                    Inc(Added);
                end;
              except
                on E: Exception do
                begin
                  NoErrors := False;
                  Teletype(Format(rstrErrorFB2Structure, [FFiles[i], R.FileName + FB2_EXTENSION]), tsError);
                  Inc(Defective);
                end;
              end;
            finally
              FreeAndNil(FS);
            end;
          end;

          Inc(j);
        until not Zip.FindNext;

        if Settings.EnableSort and NoErrors and (numFb2FilesInZip = 1) then
        begin
          R.Folder := FFiles[i];
          SortFilesZip(R);
          if FCollection.InsertBook(R, True, True) <> 0 then
            Inc(Added);
        end;

        FProgressEngine.AddProgress;
      finally
        // Safe: Zip is nil if constructor failed (caught above and we Continued),
        // or a valid instance otherwise.
        FreeAndNil(Zip);
      end;
    end;

    Inc(FAddCount, Added);
    Inc(FDefectCount, Defective);
  finally
    FProgressEngine.EndOperation;
  end;
end;

procedure TImportFB2Thread.SortFilesZip(var R: TBookRecord);
var
  FileName, NewFileName, NewFolder: string;
  archiveFileName: string;
  archiver: TMHLZip;
begin
  FileName := ExtractFileName(R.Folder);

  NewFolder := GetNewFolder(Settings.FB2FolderTemplate, R);
  CreateFolders(FCollectionRoot, NewFolder);
  CopyFile(R.Folder, FCollectionRoot + NewFolder + FileName);

  R.Folder := NewFolder + FileName;

  NewFileName := GetNewFileName(Settings.FB2FileTemplate, R);
  if NewFileName = '' then
    Exit;

  NewFolder := R.Folder;
  if FileName = NewFileName + FFb2ArchiveExt then
    Exit;

  StrReplace(FileName, NewFileName + FFb2ArchiveExt, NewFolder);
  RenameFile(FCollectionRoot + R.Folder, FCollectionRoot + NewFolder);
  R.Folder := NewFolder;

  // [BUGFIX] Replaced silent bare `except // ничего не делаем` with logging.
  // Renaming a file inside the archive is non-fatal, but silently swallowing
  // the error made debugging impossible.
  archiver := nil;
  try
    archiveFileName := TPath.Combine(FCollectionRoot, NewFolder);
    archiver := TMHLZip.Create(archiveFileName, False);
    archiver.RenameFile(R.FileName + R.FileExt, NewFileName + R.FileExt);
    R.FileName := NewFileName;
  except
    on E: Exception do
      Logger.W('SortFilesZip: failed to rename file inside archive "%s" — %s', [archiveFileName, E.Message]);
  end;
  FreeAndNil(archiver);
end;

procedure TImportFB2Thread.WorkFunction;
begin
  FAddCount := 0;
  FDefectCount := 0;

  // [BUGFIX] Removed `FFiles := TStringList.Create` — FFiles is now created and
  // owned by the base class constructor (TImportFB2ThreadBase.Create).
  // Creating it here again was leaking the instance allocated by the base class.

  // Import FB2
  Teletype(rstrImportFB2);

  FTargetExt := FB2_EXTENSION;
  FZipFolder := False;

  ScanFolder;
  if Canceled then
  begin
    Teletype(Format(rstrAddedBooksTotal, [FAddCount, FDefectCount]), tsInfo);
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

  // Import fb2.zip
  Teletype(rstrImportFB2Zip);
  FZipFolder := True;

  case FArchiveFormat of
    afZip:
    begin
      FTargetExt := ZIP_EXTENSION;
      FFb2ArchiveExt := FB2ZIP_EXTENSION;
    end;
    else
      Assert(False, 'Not supported');
  end;

  ScanFolder;
  if Canceled then
  begin
    Teletype(Format(rstrAddedBooksTotal, [FAddCount, FDefectCount]), tsInfo);
    Exit;
  end;

  FCollection.BeginBulkOperation;
  try
    ProcessFileListArchive;
    FCollection.EndBulkOperation(True);
  except
    FCollection.EndBulkOperation(False);
    raise;
  end;

  Teletype(Format(rstrAddedBooksTotal, [FAddCount, FDefectCount]), tsInfo);
end;

end.