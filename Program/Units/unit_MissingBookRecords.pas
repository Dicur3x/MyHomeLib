unit unit_MissingBookRecords;

interface

uses System.SysUtils, unit_CollectionWorkerThread, unit_Globals;

type
  TMissingBookCheckIssue = record
    Title, Path, Reason: string;
  end;

  TMissingBookEntry = record
    Book: TBookRecord;
    Path, DirectoryIdentity, ArchiveIdentity, CheckIssue: string;
  end;

  TMissingBookRecords = class(TCollectionWorker)
  private
    FInfo: TCollectionInfo;
    FCatalogueIdentity: string;
    FEntries: TArray<TMissingBookEntry>;
    FSkipped: TArray<TMissingBookCheckIssue>;
    FRemove, FRootUnavailable: Boolean;
    FUnavailable, FRemoved: Integer;
    procedure Scan;
    procedure RemoveRecords;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(const Info: TCollectionInfo); overload;
    constructor Create(const Info: TCollectionInfo; const CatalogueIdentity: string;
      const Selected: TArray<TMissingBookEntry>); overload;
    property Entries: TArray<TMissingBookEntry> read FEntries;
    property Skipped: TArray<TMissingBookCheckIssue> read FSkipped;
    property CatalogueIdentity: string read FCatalogueIdentity;
    property RootUnavailable: Boolean read FRootUnavailable;
    property Unavailable: Integer read FUnavailable;
    property Removed: Integer read FRemoved;
  end;

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.Generics.Collections, Vcl.ComCtrls,
  unit_Interfaces, unit_MHLArchiveHelpers, unit_ReaderCache, unit_ZipMemberDeletion;

const
  MAX_SKIPPED_DETAILS = 500;

type
  TBookPresence = (bpPresentFile, bpProvenMissing, bpUnverified);

  TBookPresenceProbe = class
  private
    FArchive: TMHLZip;
    FArchivePath, FArchiveIdentity: string;
    FMembers: TDictionary<string, Byte>;
    FDirectories: TDictionary<string, string>;
    FCancelled: TFunc<Boolean>;
    function CheckArchive(const Book: TBookRecord; const Path: string): TBookPresence;
    function MissingDirectoryIdentity(const Directory, CollectionRoot: string): string;
  public
    constructor Create(CacheDirectories: Boolean; const Cancelled: TFunc<Boolean>);
    destructor Destroy; override;
    function DirectoryIdentity(const Path: string): string;
    function Check(const Book: TBookRecord; out Entry: TMissingBookEntry): TBookPresence;
  end;

function PhysicalDirectoryIdentity(const Path: string): string;
var Directory: THandle; Identity: TByHandleFileInformation;
begin
  Result := '';
  Directory := CreateFile(PChar(DeletionNativePath(Path)), FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Directory = INVALID_HANDLE_VALUE then Exit;
  try
    if GetFileInformationByHandle(Directory, Identity) and
      (Identity.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY <> 0) then
      Result := IntToHex(Identity.dwVolumeSerialNumber, 8) +
        IntToHex(Identity.nFileIndexHigh, 8) + IntToHex(Identity.nFileIndexLow, 8);
  finally CloseHandle(Directory); end;
end;

constructor TBookPresenceProbe.Create(CacheDirectories: Boolean; const Cancelled: TFunc<Boolean>);
begin
  inherited Create;
  FCancelled := Cancelled;
  if CacheDirectories then FDirectories := TDictionary<string, string>.Create;
  FMembers := TDictionary<string, Byte>.Create;
end;

destructor TBookPresenceProbe.Destroy;
begin
  FArchive.Free;
  FMembers.Free;
  FDirectories.Free;
  inherited;
end;

function TBookPresenceProbe.DirectoryIdentity(const Path: string): string;
begin
  if Assigned(FDirectories) and FDirectories.TryGetValue(Path, Result) then Exit;
  Result := PhysicalDirectoryIdentity(Path);
  if Assigned(FDirectories) and (FDirectories.Count < 8192) then FDirectories.AddOrSetValue(Path, Result);
end;

function TBookPresenceProbe.MissingDirectoryIdentity(const Directory, CollectionRoot: string): string;
var Root, Ancestor, Identity: string; Attributes, ErrorCode: DWORD;
begin
  Result := '';
  Root := IncludeTrailingPathDelimiter(TPath.GetFullPath(CollectionRoot));
  // Treat a removed subfolder as evidence only inside a reachable local tree.
  if GetDriveType(PChar(IncludeTrailingPathDelimiter(ExtractFileDrive(Root)))) <> DRIVE_FIXED then Exit;
  Ancestor := Directory;
  while IncludeTrailingPathDelimiter(Ancestor).StartsWith(Root, True) do
  begin
    Attributes := GetFileAttributes(PChar(DeletionNativePath(Ancestor)));
    if Attributes <> INVALID_FILE_ATTRIBUTES then
    begin
      if Attributes and FILE_ATTRIBUTE_DIRECTORY = 0 then Exit;
      Identity := DirectoryIdentity(Ancestor);
      if Identity <> '' then Result := Ancestor + '|' + Identity;
      Exit;
    end;
    ErrorCode := GetLastError;
    if not (ErrorCode in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]) or
      SameFileName(IncludeTrailingPathDelimiter(Ancestor), Root) then Exit;
    Ancestor := ExtractFileDir(Ancestor);
  end;
end;

function TBookPresenceProbe.CheckArchive(const Book: TBookRecord; const Path: string): TBookPresence;
var Member: string;
begin
  if FArchivePath <> Path then
  begin
    FreeAndNil(FArchive); FMembers.Clear; FArchivePath := '';
    FArchiveIdentity := ArchiveDeletionSourceIdentity(Path);
    FArchive := TMHLZip.Create(DeletionNativePath(Path), True, False, FCancelled);
    for var I := 0 to FArchive.FileCount - 1 do
    begin
      if FCancelled() then Abort;
      FMembers.AddOrSetValue(LowerCase(FArchive.FileNames[I].Replace('\', '/')), 0);
    end;
    // A replaced archive cannot prove absence using the previous listing.
    if ArchiveDeletionSourceIdentity(Path) <> FArchiveIdentity then Exit(bpUnverified);
    FArchivePath := Path;
  end;
  Member := Book.FileName;
  if not SameText(ExtractFileExt(Member), Book.FileExt) then Member := Member + Book.FileExt;
  if FMembers.ContainsKey(LowerCase(Member.Replace('\', '/'))) then Exit(bpPresentFile);
  // The Reader can still find legacy ordinal and trimmed-name entries.
  // Preserve ambiguous and unreadable entries as unverified.
  try
    FArchive.ResolveBookName(Member, Book.InsideNo);
    Result := bpPresentFile;
  except
    on E: EArchiveBookEntryMissing do Result := bpProvenMissing;
  end;
end;

function TBookPresenceProbe.Check(const Book: TBookRecord; out Entry: TMissingBookEntry): TBookPresence;
var Container, Alternate, Directory: string; Attr, ErrorCode: DWORD; Format: TBookFormat;
begin
  Result := bpUnverified;
  Entry := Default(TMissingBookEntry);
  if (Book.FileName = '') or not TPath.IsPathRooted(Book.CollectionRoot) then
  begin
    Entry.Path := Book.CollectionRoot;
    Entry.CheckIssue := 'У записи нет полного пути к файлу.';
    Exit;
  end;
  try
    Container := TPath.GetFullPath(TPath.Combine(Book.CollectionRoot, Book.Folder));
    Format := Book.GetBookFormat(TPath.Combine(Book.CollectionRoot, Book.Folder));
    // Keep the original locator's directory separator for GetBookFormat.
    Entry.Path := TPath.GetFullPath(Book.GetBookFileName(TPath.Combine(Book.CollectionRoot, Book.Folder)));
    if FileExists(Entry.Path) and not (Format in [bfFb2Archive, bfRawArchive]) then Exit(bpPresentFile);
    ErrorCode := ERROR_SUCCESS;
    Attr := GetFileAttributes(PChar(DeletionNativePath(Entry.Path)));
    if Attr = INVALID_FILE_ATTRIBUTES then
    begin
      ErrorCode := GetLastError;
      if not (ErrorCode in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]) then
      begin
        Entry.CheckIssue := SysErrorMessage(ErrorCode);
        Exit;
      end;
    end;
    if (Attr = INVALID_FILE_ATTRIBUTES) and not Book.IsLinkedSource and
      (Format in [bfFb2Archive, bfRawArchive]) and SameText(ExtractFileExt(Container), ZIP_EXTENSION) then
    begin
      Alternate := ChangeFileExt(Entry.Path, SEVENZIP_ARCHIVE_EXTENSION);
      var AltAttr := GetFileAttributes(PChar(DeletionNativePath(Alternate)));
      if AltAttr <> INVALID_FILE_ATTRIBUTES then
      begin
        Entry.Path := Alternate;
        Attr := AltAttr;
      end
      else
      begin
        ErrorCode := GetLastError;
        if not (ErrorCode in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]) then
        begin
          Entry.Path := Alternate;
          Entry.CheckIssue := SysErrorMessage(ErrorCode);
          Exit;
        end;
      end;
    end;
    if Attr <> INVALID_FILE_ATTRIBUTES then
    begin
      if Attr and FILE_ATTRIBUTE_DIRECTORY <> 0 then
      begin
        Entry.CheckIssue := 'По указанному пути находится папка.';
        Exit;
      end;
      if not (Format in [bfFb2Archive, bfRawArchive]) then Exit(bpPresentFile);
      Result := CheckArchive(Book, Entry.Path);
      if Result = bpUnverified then Entry.CheckIssue := 'Архив изменился во время проверки.';
      if Result <> bpProvenMissing then Exit;
      Entry.ArchiveIdentity := FArchiveIdentity;
    end;
    Directory := ExtractFileDir(Entry.Path);
    if (Attr = INVALID_FILE_ATTRIBUTES) and (ErrorCode = ERROR_PATH_NOT_FOUND) then
      Entry.DirectoryIdentity := MissingDirectoryIdentity(Directory, Book.CollectionRoot)
    else Entry.DirectoryIdentity := DirectoryIdentity(Directory);
    if Entry.DirectoryIdentity = '' then
    begin
      Entry.CheckIssue := 'Не удалось проверить папку, в которой ожидается файл.';
      Exit(bpUnverified);
    end;
    Entry.Book := Book;
    Result := bpProvenMissing;
  except
    on E: EAbort do raise;
    on E: Exception do
    begin
      Entry.CheckIssue := E.Message;
      Result := bpUnverified;
    end;
  end;
end;

constructor TMissingBookRecords.Create(const Info: TCollectionInfo);
begin
  inherited Create(Info.ID);
  FInfo := Info;
  FCatalogueIdentity := Copy(ArchiveDeletionSourceIdentity(Info.DBFileName), 1, 25);
end;

constructor TMissingBookRecords.Create(const Info: TCollectionInfo; const CatalogueIdentity: string;
  const Selected: TArray<TMissingBookEntry>);
begin
  inherited Create(Info.ID);
  FInfo := Info;
  FCatalogueIdentity := CatalogueIdentity;
  FEntries := Copy(Selected);
  FRemove := True;
end;

procedure TMissingBookRecords.Scan;
var Candidates: TList<TMissingBookEntry>; Skipped: TList<TMissingBookCheckIssue>;
  Probe: TBookPresenceProbe; Book: TBookRecord;
  Entry, OtherEntry: TMissingBookEntry; State: TBookPresence;
  Issue: TMissingBookCheckIssue;
begin
  Candidates := TList<TMissingBookEntry>.Create;
  Skipped := TList<TMissingBookCheckIssue>.Create;
  Probe := TBookPresenceProbe.Create(True, function: Boolean begin Result := Canceled; end);
  try
    FCollection.SetHideDeleted(False);
    FCollection.SetShowLocalOnly(False);
    var Iterator := FCollection.GetBookIterator(bmAll, False);
    FProgressEngine.BeginOperation(Iterator.RecordCount, 'Проверяем файлы книг…', 'Проверяем файлы книг…');
    try
      while Iterator.Next(Book) do
      begin
        if Canceled then Exit;
        State := Probe.Check(Book, Entry);
        if State = bpProvenMissing then
          for var CopyBook in FCollection.GetCatalogBookCopies(Book.BookKey) do
          begin
            var CopyState := Probe.Check(CopyBook, OtherEntry);
            if CopyState = bpPresentFile then begin State := CopyState; Break; end;
            if (CopyState = bpUnverified) and (State <> bpUnverified) then
            begin
              State := CopyState;
              Entry.Path := OtherEntry.Path;
              Entry.CheckIssue := 'Не удалось проверить известную копию. ' + OtherEntry.CheckIssue;
            end;
          end;
        if State = bpProvenMissing then Candidates.Add(Entry)
        else if State = bpUnverified then
        begin
          Inc(FUnavailable);
          if Skipped.Count < MAX_SKIPPED_DETAILS then
          begin
            Issue.Title := Book.Title;
            Issue.Path := Entry.Path;
            Issue.Reason := Entry.CheckIssue;
            Skipped.Add(Issue);
          end;
        end;
        FProgressEngine.AddProgress;
      end;
      FEntries := Candidates.ToArray;
      FSkipped := Skipped.ToArray;
    finally FProgressEngine.EndOperation; end;
  finally Probe.Free; Skipped.Free; Candidates.Free; end;
end;

procedure TMissingBookRecords.RemoveRecords;
var Writer: IBookIdentityDeletionWriter; Probe: TBookPresenceProbe;
  Expected: TMissingBookEntry; Live, OtherEntry: TMissingBookEntry;
  Match: TBookIdentityPredicate;
begin
  if not Supports(FCollection, IBookIdentityDeletionWriter, Writer) then
    raise EInvalidOperation.Create('Коллекция не поддерживает безопасное удаление записей.');
  Match := function(const Current: TBookRecord): Boolean
    begin
      Result := False;
      var Identity := ReaderBookPhysicalIdentity(Expected.Book);
      if not Current.BookKey.IsSameAs(Expected.Book.BookKey) or (Current.LibID <> Expected.Book.LibID) or
        (Current.InsideNo <> Expected.Book.InsideNo) or (Identity = '') or
        (ReaderBookPhysicalIdentity(Current) <> Identity) then Exit;
      if (Probe.Check(Expected.Book, Live) <> bpProvenMissing) or (Live.Path <> Expected.Path) or
        (Live.DirectoryIdentity <> Expected.DirectoryIdentity) or (Live.ArchiveIdentity <> Expected.ArchiveIdentity) then Exit;
      for var CopyBook in FCollection.GetCatalogBookCopies(Expected.Book.BookKey) do
        if Probe.Check(CopyBook, OtherEntry) <> bpProvenMissing then Exit;
      Result := True;
    end;
  FProgressEngine.BeginOperation(Length(FEntries), 'Удаляем записи без файлов…', 'Удаляем записи без файлов…');
  try
    for var Item in FEntries do
    begin
      if Canceled then Exit;
      Expected := Item;
      Probe := TBookPresenceProbe.Create(False, function: Boolean begin Result := Canceled; end);
      try
        if Writer.DeleteBookIfIdentity(Expected.Book, Match) = bdwDeleted then
        begin
          Inc(FRemoved);
          CollectionCommitted(FInfo.ID);
        end
        else Inc(FUnavailable);
      finally Probe.Free; end;
      FProgressEngine.AddProgress;
    end;
  finally FProgressEngine.EndOperation; end;
end;

procedure TMissingBookRecords.WorkFunction;
var LiveInfo: TCollectionInfo;
begin
  LiveInfo := FSystemData.GetCollectionInfo(FInfo.ID);
  if not isLocalCollection(LiveInfo.CollectionType) or
    not SameFileName(LiveInfo.DBFileName, FInfo.DBFileName) or
    not SameFileName(LiveInfo.GetRootPath, FInfo.GetRootPath) or
    (Copy(ArchiveDeletionSourceIdentity(LiveInfo.DBFileName), 1, 25) <> FCatalogueIdentity) then
    raise EReadError.Create('Коллекция изменилась. Повторите проверку файлов.');
  FRootUnavailable := PhysicalDirectoryIdentity(LiveInfo.GetRootPath) = '';
  if FRootUnavailable then Exit;
  if FRemove then RemoveRecords else Scan;
  FOperationSuccess := not Canceled;
end;

end.
