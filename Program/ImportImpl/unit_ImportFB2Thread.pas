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
  Classes,
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
    procedure ReadImportedMetadata(Input: TStream; var Book: TBookRecord);
    procedure SortFilesZip(var R: TBookRecord; const SourceArchive,
      SourceEntryName: string; out CreatedFileName: string);

  public
    // [BUGFIX] Signature now matches the interface declaration exactly.
    constructor Create(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat);
  end;

  TImportLocalBookThread = class(TImportFB2Thread)
  private
    FSources: TArray<string>;
    function ImportSource(const Source: string): Integer;
    procedure AddSelectedBook(const DisplayName, RelativeFolder, Name, Extension, LocalID: string;
      const Size, ArchiveIndex: Integer; Input: TStream);
  protected
    procedure WorkFunction; override;
  public
    constructor Create(const CollectionID: Integer; const Sources: TArray<string>);
  end;

implementation

uses
  Winapi.Windows,
  SysUtils,
  IOUtils,
  unit_WorkerThread,
  FictionBook_21,
  unit_Helpers,
  unit_Consts,
  dm_user,
  unit_Templater,
  unit_ReaderFormats, unit_ReaderOffice, unit_ReaderCache, unit_CollectionPacking,
  unit_LibrarySourceID, unit_PackageBookMetadata, unit_FB2PublisherMetadataReader;

resourcestring
  rstrStructureError         = 'Ошибка структуры fb2: %s.zip -> %s';
  rstrProcessedFiles         = 'Обработаны файлы: %u из %u';
  rstrAddedFiles             = 'Добавлены файлы: %u из %u';
  rstrErrorUnpackingWithCode = 'Ошибка распаковки архива %s, Код: %d';
  rstrFoundNewArchives       = 'Обнаружены новые архивы: %u';
  rstrErrorFB2Structure      = 'Ошибка структуры fb2: %s -> %s';
  rstrErrorUnpacking         = 'Ошибка распаковки архива: ';
  rstrNoSupportedArchiveBooks = 'В архиве «%s» нет книг поддерживаемых форматов.';
  rstrArchiveBookError       = 'Не удалось добавить «%s» из архива «%s»: %s';
  rstrProcessedArchives      = 'Обработаны архивы: %u из %u';
  // [BUGFIX] Removed stray ',;' typo — was: 'Добавлено книг: %u,; пропущено книг: %u'
  rstrAddedBooks             = 'Добавлено книг: %u; пропущено книг: %u';
  rstrAddedBooksTotal        = 'Добавлено всего книг: %u; пропущено всего книг: %u';
  rstrImportFB2              = 'Импорт файлов fb2:';
  rstrImportFB2Zip           = 'Импорт книг из архивов ZIP и 7z:';
  rstrErrorRenamingInArchive = 'Ошибка переименования файла в архиве %s: %s';


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
  CreatedFileName: string;
  BookID: Integer;
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
      CreatedFileName := '';

      try
        if Settings.EnableSort then
        begin
          R.Folder := ExtractFilePath(FFiles[i]);
          book := LoadFictionBook(FFiles[i]);
          GetBookInfo(book, R);
          SortFiles(R, FFiles[i], CreatedFileName);
        end
        else
        begin
          R.Folder := ExtractRelativePath(FCollectionRoot, ExtractFilePath(FFiles[i]));
          book := LoadFictionBook(FFiles[i]);
          GetBookInfo(book, R);
        end;
        BookID := FCollection.InsertBook(R, True, True, FImportCache);
        if BookID <> 0 then
          Inc(Added)
        else
        begin
          ForgetCreatedFile(CreatedFileName, True);
          Inc(Defective);
        end;
      except
        on E: Exception do
        begin
          ForgetCreatedFile(CreatedFileName, True);
          Teletype(Format(rstrStructureError, [R.Folder, R.FileName + FB2_EXTENSION]), tsError);
          LogWarning('ProcessFileList: failed to import "%s" — %s', [FFiles[i], E.Message]);
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

function IsLocalImportFormat(const Extension: string): Boolean; forward;

procedure TImportFB2Thread.ReadImportedMetadata(Input: TStream; var Book: TBookRecord);
var
  Metadata: TFB2CatalogMetadata;
  Details, Author: string;
begin
  if Book.FileExt = FB2_EXTENSION then
    GetBookInfo(LoadFictionBook(Input), Book)
  else if IsMetadataPackage(Book.FileExt) and
    (ReadPackageMetadata(Input, Book.FileExt, Metadata, Details, True,
      function: Boolean begin Result := Canceled; end) = fmsComplete) then
  begin
    if Metadata.Title <> '' then Book.Title := Metadata.Title;
    Book.Lang := Copy(Metadata.Language, 1, 2);
    for Author in Metadata.Authors do TAuthorsHelper.Add(Book.Authors, Author, '', '');
    Book.Publisher := Metadata.Publisher;
    Book.City := Metadata.City;
    Book.ISBN := Metadata.ISBN;
    Book.PubYear := Metadata.PubYear;
    Book.Translators := Metadata.Translators;
    Book.Annotation := Metadata.Annotation;
  end;
end;

procedure TImportFB2Thread.ProcessFileListArchive;
const
  MaxMetadataMember = 256*1024*1024;
type
  TBookRecordArray = array of TBookRecord;
  TStringArray = array of string;
var
  i, j, k, EntryIndex, EntryCount: Integer;
  R: TBookRecord;
  AFileName, Extension: string;
  FS: TMemoryStream;
  NoErrors: Boolean;
  MatchedEntryCount: Integer;
  Zip: TMHLZip;
  Records: TBookRecordArray;
  EntryNames: TStringArray;
  NewFolder: string;
  ArchiveName: string;
  StoredArchiveName: string;
  TargetArchiveName: string;
  CreatedArchiveName: string;
  AddedBeforeArchive: Integer;
  BookID: Integer;
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
      SetLength(Records, 0);
      SetLength(EntryNames, 0);
      CreatedArchiveName := '';

      // [BUGFIX] Zip is initialised to nil before the try so that FreeAndNil in
      // the finally block is always safe, even when the constructor throws.
      try
        try
          Zip := TMHLZip.Create(FFiles[i], True, False,
            function: Boolean begin Result := Canceled; end);
          EntryCount := Zip.FileCount;
        except
          on E: Exception do
          begin
            if Canceled then Break;
            Teletype(rstrErrorUnpacking + FFiles[i] + '. ' + E.Message, tsError);
            LogWarning('ProcessFileListArchive: cannot open "%s" — %s',
              [FFiles[i], E.Message]);
            Inc(Defective);
            FProgressEngine.AddProgress;
            Continue;
          end;
        end;

        MatchedEntryCount := 0;

        for EntryIndex := 0 to EntryCount - 1 do
        begin
          if Canceled then Break;
          AFileName := Zip.FileNames[EntryIndex];
          Extension := LowerCase(ExtractFileExt(AFileName));
          if not IsLocalImportFormat(Extension) or IsMetadataContainer(Extension) then Continue;
          R.Clear;
          Inc(MatchedEntryCount);

          R.FileExt := Extension;
          R.FileName := ChangeFileExt(AFileName, '');
          R.Title := ChangeFileExt(ExtractFileName(AFileName), '');
          R.InsideNo := EntryIndex;
          R.Date     := Now;
          Include(R.BookProps, bpIsLocal);
          if Extension <> FB2_EXTENSION then R.LibID := NewLocalBookID;

          FS := nil;
          try
            try
              R.Size := Zip.FileSizes[EntryIndex];
              if R.Size = 0 then raise EReadError.Create('Файл пуст.');
              if (Extension = FB2_EXTENSION) or IsMetadataPackage(Extension) then
              begin
                if R.Size > MaxMetadataMember then
                  raise EReadError.Create('Файл слишком велик для чтения описания.');
                FS := Zip.ExtractToStream(EntryIndex);
                ReadImportedMetadata(FS, R);
              end;

              j := Length(Records);
              SetLength(Records, j + 1);
              SetLength(EntryNames, j + 1);
              Records[j] := R;
              EntryNames[j] := AFileName;
            except
              on E: Exception do
              begin
                NoErrors := False;
                Teletype(Format(rstrArchiveBookError,
                  [AFileName, ExtractFileName(FFiles[i]), E.Message]), tsError);
                LogWarning('ProcessFileListArchive: failed to parse "%s" in "%s" — %s',
                  [AFileName, FFiles[i], E.Message]);
                Inc(Defective);
              end;
            end;
          finally
            FreeAndNil(FS);
          end;
        end;

        if Canceled then Break;

        if MatchedEntryCount = 0 then
        begin
          Teletype(Format(rstrNoSupportedArchiveBooks, [ExtractFileName(FFiles[i])]), tsError);
          Inc(Defective);
        end;

        if Length(Records) > 0 then
        begin
          AddedBeforeArchive := Added;
          try
            if Settings.EnableSort and NoErrors and
               (MatchedEntryCount = 1) and (Length(Records) = 1) and
               (Records[0].FileExt = FB2_EXTENSION) and
               not IsSevenZipArchive(FFiles[i]) then
              SortFilesZip(Records[0], FFiles[i], EntryNames[0],
                CreatedArchiveName)
            else
            begin
              if Settings.EnableSort then
              begin
                // A multi-book container cannot have one unambiguous template
                // name.  A 7z container is deliberately read-only as well, so
                // it cannot be renamed internally like an ordinary ZIP.
                // Preserve the archive and every entry, but still place the
                // container in the templated folder of its first book.
                Records[0].Folder := FFiles[i];
                NewFolder := GetNewFolder(Settings.FB2FolderTemplate, Records[0]);
                if not CreateFolders(FCollectionRoot, NewFolder) then
                  RaiseLastOSError;

                ArchiveName := ExtractFileName(FFiles[i]);
                TargetArchiveName := TPath.Combine(
                  TPath.Combine(FCollectionRoot, NewFolder), ArchiveName
                );
                if CopyForImport(FFiles[i], TargetArchiveName) then
                  CreatedArchiveName := TargetArchiveName;
                StoredArchiveName := TPath.Combine(NewFolder, ArchiveName);
              end
              else
                StoredArchiveName := ExtractRelativePath(FCollectionRoot, FFiles[i]);

              for k := 0 to High(Records) do
                Records[k].Folder := StoredArchiveName;
            end;

            for k := 0 to High(Records) do
            begin
              try
                if Canceled then Break;
                BookID := FCollection.InsertBook(
                  Records[k], True, True, FImportCache
                );
                if BookID <> 0 then
                  Inc(Added)
                else
                  Inc(Defective);
              except
                on E: Exception do
                begin
                  Teletype(Format(rstrArchiveBookError,
                    [EntryNames[k], ExtractFileName(FFiles[i]), E.Message]), tsError);
                  LogWarning('ProcessFileListArchive: failed to insert "%s" from "%s" — %s',
                    [Records[k].FileName, FFiles[i], E.Message]);
                  Inc(Defective);
                end;
              end;
            end;

            if Added = AddedBeforeArchive then
              ForgetCreatedFile(CreatedArchiveName, True);
          except
            on E: Exception do
            begin
              ForgetCreatedFile(CreatedArchiveName, True);
              Teletype(rstrErrorUnpacking + FFiles[i], tsError);
              LogWarning('ProcessFileListArchive: failed to sort "%s" — %s',
                [FFiles[i], E.Message]);
              Inc(Defective, Length(Records));
            end;
          end;
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

procedure TImportFB2Thread.SortFilesZip(var R: TBookRecord;
  const SourceArchive, SourceEntryName: string; out CreatedFileName: string);
var
  NewFileName, NewFolder: string;
  ArchiveName: string;
  NewArchiveName: string;
  ArchiveFileName: string;
  TemplateBook: TBookRecord;
  archiver: TMHLZip;
begin
  CreatedFileName := '';
  ArchiveName := ExtractFileName(SourceArchive);
  R.Folder := SourceArchive;
  NewFolder := GetNewFolder(Settings.FB2FolderTemplate, R);
  if not CreateFolders(FCollectionRoot, NewFolder) then
    RaiseLastOSError;

  // The historical template contract evaluates the file name after the book
  // already points at the copied (but not yet renamed) archive.
  R.Folder := TPath.Combine(NewFolder, ArchiveName);
  TemplateBook := R;
  TemplateBook.FileName := TPath.GetFileNameWithoutExtension(
    CleanFileName(ExtractFileName(SourceEntryName)));
  NewFileName := GetNewFileName(Settings.FB2FileTemplate, TemplateBook);
  if NewFileName <> '' then
    NewArchiveName := NewFileName + FFb2ArchiveExt
  else
    NewArchiveName := ExtractFileName(SourceArchive);

  ArchiveFileName := TPath.Combine(
    TPath.Combine(FCollectionRoot, NewFolder), NewArchiveName
  );
  if CopyForImport(SourceArchive, ArchiveFileName) then
    CreatedFileName := ArchiveFileName;
  R.Folder := TPath.Combine(NewFolder, NewArchiveName);

  if NewFileName = '' then
    Exit;

  archiver := nil;
  try
    archiver := TMHLZip.Create(ArchiveFileName, False, True);
    try
      archiver.RenameFile(SourceEntryName, NewFileName + R.FileExt);
      // Only publish the new inner name after System.Zip confirmed the rename.
      R.InsideNo := archiver.LastIndex;
      R.FileName := NewFileName;
    except
      on E: Exception do
        LogWarning('SortFilesZip: failed to rename file inside archive "%s" — %s',
          [ArchiveFileName, E.Message]);
    end;
  finally
    FreeAndNil(archiver);
  end;
end;

procedure TImportFB2Thread.WorkFunction;
var
  BulkOperationActive: Boolean;
begin
  FAddCount := 0;
  FDefectCount := 0;

  // [BUGFIX] Removed `FFiles := TStringList.Create` — FFiles is now created and
  // owned by the base class constructor (TImportFB2ThreadBase.Create).
  // Creating it here again was leaking the instance allocated by the base class.

  Teletype(rstrImportFB2);

  FTargetExt := FB2_EXTENSION;
  FZipFolder := False;

  ScanFolder;
  if Canceled then
  begin
    Teletype(Format(rstrAddedBooksTotal, [FAddCount, FDefectCount]), tsInfo);
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
    FChangesCommitted := True;
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
  CollectionCommitted(FCollectionID);

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

  BulkOperationActive := True;
  FCollection.BeginBulkOperation;
  try
    ProcessFileListArchive;
    if Canceled then
    begin
      FCollection.EndBulkOperation(False);
      BulkOperationActive := False;
      RollbackFileOperations;
      Exit;
    end;
    FCollection.EndBulkOperation(True);
    BulkOperationActive := False;
    FChangesCommitted := True;
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
  CollectionCommitted(FCollectionID);
  FOperationSuccess := True;

  Teletype(Format(rstrAddedBooksTotal, [FAddCount, FDefectCount]), tsInfo);
end;

constructor TImportLocalBookThread.Create(const CollectionID: Integer; const Sources: TArray<string>);
begin
  inherited Create(CollectionID,afZip);
  FSources := Copy(Sources);
end;

function IsLocalImportFormat(const Extension: string): Boolean;
begin
  Result := IsBuiltinReaderFormat(Extension) or IsOfficeReaderFormat(Extension) or
    (Extension='.mobi') or (Extension='.azw') or (Extension='.azw3') or
    (Extension='.prc') or (Extension='.mp3') or (Extension='.ogg') or
    (Extension='.wav') or (Extension='.m4b') or IsReaderArchive('book'+Extension);
end;

procedure TImportLocalBookThread.AddSelectedBook(const DisplayName, RelativeFolder,
  Name, Extension, LocalID: string; const Size, ArchiveIndex: Integer; Input: TStream);
var
  Book: TBookRecord;
begin
  Book.Clear;
  Book.LibID := LocalID;
  Book.Title := ChangeFileExt(ExtractFileName(DisplayName),'');
  Book.Folder := RelativeFolder;
  Book.FileName := Name;
  Book.FileExt := Extension;
  Book.InsideNo := ArchiveIndex;
  Book.Size := Size;
  Book.Date := Now;
  Include(Book.BookProps,bpIsLocal);

  ReadImportedMetadata(Input, Book);

  if Canceled then Abort;
  if FCollection.InsertBook(Book,False,False,FImportCache)=0 then
    raise EInvalidOperation.CreateFmt('Не удалось добавить книгу «%s».',[Book.Title]);
end;

function TImportLocalBookThread.ImportSource(const Source: string): Integer;
const
  LocalFolder = 'HomeLibre-local-books\';
  MaxMetadataMember = 256*1024*1024;
var
  Extension, Detected, Folder, Path, RelativePath, Name, LocalID, Member, MemberExt, ID: string;
  Attr: DWORD;
  Archive: TMHLZip;
  Input: TStream;
  Added: Integer;
begin
  if not FileExists(Source) then raise EInOutError.Create('Выбранный файл недоступен.');
  Detected := DetectReaderExtension(Source);
  Extension := LowerCase(ExtractFileExt(Source));
  // Comic archives remain a single book. Preserve the Kindle suffix when
  // the shared MOBI signature cannot distinguish the container versions.
  if not (((Detected='.zip') and (Extension='.cbz')) or
    ((Detected='.7z') and (Extension='.cb7')) or
    ((Detected='.rar') and (Extension='.cbr')) or
    ((Detected='.mobi') and ((Extension='.azw') or (Extension='.azw3') or (Extension='.prc')))) then
  begin
    if Detected<>'' then Extension := Detected;
  end;
  if not IsLocalImportFormat(Extension) then
    raise ENotSupportedException.Create('Этот файл не распознан как книга или документ.');

  LocalID := NewLocalBookID;
  Name := Copy(LocalID,Length(LOCAL_BOOK_ID_PREFIX)+1,MaxInt);
  Folder := TPath.Combine(FCollectionRoot,LocalFolder);
  if not DirectoryExists(Folder) and not CreateDir(ExcludeTrailingPathDelimiter(Folder)) then
    RaiseLastOSError;
  Attr := GetFileAttributes(PChar(ExcludeTrailingPathDelimiter(Folder)));
  if (Attr=INVALID_FILE_ATTRIBUTES) or ((Attr and FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
    raise EInOutError.Create('Папка для своих книг недоступна или является ссылкой.');
  RelativePath := LocalFolder+Name+Extension;
  Path := TPath.Combine(FCollectionRoot,RelativePath);
  SetComment('Копируем книгу в папку коллекции…');
  if not CopyForImport(Source,Path) then
    raise EInOutError.Create('Не удалось создать отдельную копию файла.');

  try
    Attr := GetFileAttributes(PChar(Path));
    if (Attr=INVALID_FILE_ATTRIBUTES) or
      (((Attr and FILE_ATTRIBUTE_READONLY)<>0) and
      not SetFileAttributes(PChar(Path),Attr and not FILE_ATTRIBUTE_READONLY)) then
      RaiseLastOSError;
    if Canceled then Abort;
    FCollection.BeginBulkOperation;
    try
      Added := 0;
      SetComment('Добавляем книгу в каталог…');
      if IsArchiveExt(Path) then
      begin
        Archive := TMHLZip.Create(Path,True,False,function: Boolean begin Result:=Canceled; end);
        try
          for var I:=0 to Archive.FileCount-1 do
          begin
            if Canceled then Abort;
            Member := Archive.FileNames[I];
            MemberExt := LowerCase(ExtractFileExt(Member));
            if not IsLocalImportFormat(MemberExt) or IsMetadataContainer(MemberExt) then Continue;
            var MemberSize := Archive.FileSizes[I];
            if MemberSize=0 then
              raise EReadError.CreateFmt('Файл «%s» пуст или слишком велик для каталога.',[Member]);
            if Added=0 then ID := LocalID else ID := NewLocalBookID;
            Input := nil;
            try
              if (MemberExt=FB2_EXTENSION) or IsMetadataPackage(MemberExt) then
              begin
                if MemberSize>MaxMetadataMember then
                  raise EReadError.CreateFmt('Файл «%s» слишком велик для чтения описания.',[Member]);
                Input := Archive.ExtractToStream(I);
              end;
              AddSelectedBook(Member,RelativePath,Copy(Member,1,Length(Member)-Length(MemberExt)),
                MemberExt,ID,MemberSize,I,Input);
            finally
              Input.Free;
            end;
            Inc(Added);
          end;
        finally
          Archive.Free;
        end;
      end
      else
      begin
        Input := TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
        try
          if Input.Size=0 then raise EReadError.Create('Выбранный файл пуст.');
          if Input.Size>MaxInt then raise EReadError.Create('Файл слишком велик для каталога.');
          AddSelectedBook(Source,LocalFolder,Name,Extension,LocalID,Integer(Input.Size),0,Input);
          Added := 1;
        finally
          Input.Free;
        end;
      end;
      if Added=0 then raise EReadError.Create('В архиве нет поддерживаемых книг.');
      if Canceled then Abort;
      FCollection.EndBulkOperation(True);
    except
      if FCollection.InBulkOperation then FCollection.EndBulkOperation(False)
      else if FCollection.ResolveBookID(LocalID,0)<>0 then
      begin
        // A failure after committing must not remove a catalogued file.
        ForgetCreatedFile(Path,False);
        CollectionCommitted(FCollectionID);
      end;
      raise;
    end;
    ForgetCreatedFile(Path,False);
    CollectionCommitted(FCollectionID);
    Result := Added;
  finally
    RollbackFileOperations;
  end;
end;

procedure TImportLocalBookThread.WorkFunction;
var
  Source: string;
  Added, Failed: Integer;
begin
  if not isLocalCollection(FCollection.CollectionCode) or
    IsPackedCollectionCatalog(FCollection.GetProperty(PROP_DATAFILE)) then
  begin
    Teletype('Свои файлы можно добавить в обычную локальную коллекцию.',tsError);
    Exit;
  end;
  Added := 0;
  Failed := 0;
  FProgressEngine.BeginOperation(Length(FSources),rstrProcessedFiles,rstrProcessedFiles);
  try
    for Source in FSources do
    begin
      if Canceled then Break;
      try
        Inc(Added, ImportSource(TPath.GetFullPath(Source)));
      except
        on E: Exception do
        begin
          if Canceled and (E is EAbort) then Break;
          Inc(Failed);
          Teletype(Format('Не удалось добавить «%s». %s',[ExtractFileName(Source),E.Message]),tsError);
          LogWarning('Local book import failed for "%s": %s',[Source,E.Message]);
          // A rolled-back file may have added author or series IDs to this cache.
          FreeAndNil(FImportCache);
          FImportCache := TImportCache.Create;
        end;
      end;
      FProgressEngine.AddProgress;
    end;
  finally
    FProgressEngine.EndOperation;
  end;
  FOperationSuccess := (Added>0) and not Canceled;
  Teletype(Format('Добавлено книг: %d. Файлов с ошибками: %d.',[Added,Failed]),tsInfo);
end;

end.
