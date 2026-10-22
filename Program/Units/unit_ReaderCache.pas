unit unit_ReaderCache;

interface

uses
  System.Classes, System.SysUtils, unit_Globals, unit_Interfaces;

function ReaderCopyName(const Book: TBookRecord): string;
function ReaderHistoryName(const Book: TBookRecord; const LibraryNamespace: string): string;
function PrepareExternalReaderFile(const Book: TBookRecord; const PreparedFile, LibraryNamespace: string;
  ForceCopy: Boolean = False): string;
procedure PrepareExternalReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  const PreparedFile, LibraryNamespace: string; const OnReady: TProc<string>; ForceCopy: Boolean = False);
function PrepareReaderFile(const Book: TBookRecord; const PreserveImages: Boolean = False; const OnStage: TProc<string> = nil; OpenArchive: Boolean = False; ConvertKindle: Boolean = False; ConvertOffice: Boolean = False): string;
procedure PrepareReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive: Boolean = False; ConvertKindle: Boolean = False; ConvertOffice: Boolean = False; const OnMissingComponent: TProc<string> = nil);
function PrepareConversionSource(const Book: TBookRecord; const OnStage: TProc<string> = nil;
  const TargetExtension: string = ''): string;
function IsReaderArchive(const FileName: string): Boolean;
procedure CancelReaderPreparations(Owner: TComponent);
function ReaderPreparationsPending(Owner: TComponent): Boolean;
function ResolveReaderBook(const Collection: IBookCollection; const Book: TBookRecord): TBookRecord;
function ReaderBookPhysicalIdentity(const Book: TBookRecord): string;
function ReaderBookMatchesExpectedIdentity(const ExpectedLibID, ExpectedPhysicalIdentity: string;
  const Current: TBookRecord; const LibraryNamespace: string): Boolean;
function ReaderBookMatchesCatalog(const Collection: IBookCollection; const Saved: TBookRecord): Boolean;
function ReaderTryGetPersonalBook(const User: ISystemData; const Collection: IBookCollection;
  const Saved: TBookRecord; out Stored: TBookRecord): Boolean;
type TReaderPersonalWriteResult = (rpwRejected, rpwCatalog, rpwPersonal);
function TryStoreReaderBookPersonal(const Collection: IBookCollection; const User: ISystemData;
  const Expected: TBookRecord; const Fields: TBookPersonalFields;
  RequirePersonal: Boolean = True): TReaderPersonalWriteResult;
function TryStoreReaderBookProgress(const Collection: IBookCollection; const Saved: TBookRecord;
  Progress: Integer): Boolean;

implementation

uses
  System.IOUtils, System.Hash, System.Variants, System.Math, unit_FileMutex, unit_LibrarySourceID,
  System.Generics.Collections, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls,
  Vcl.ExtCtrls, System.SyncObjs, unit_MHLOperationStatus,
  Winapi.Windows, unit_ReaderFormats, unit_ReaderKindle, unit_ReaderOffice, unit_ReaderLegacy, unit_Settings, unit_Consts, unit_FLibraryCompat, unit_MHLExternalTools,
  unit_MHLArchiveHelpers, unit_WebPCompat, unit_BookMetadataCache, unit_BookCache, dm_user, unit_ProgramUpdates, unit_BookConversion, unit_ComponentUpdates;

type TReaderThreadAccess = class(TThread);

function IsReaderArchive(const FileName: string): Boolean;
var Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  Result := (Ext = '.zip') or (Ext = '.7z') or (Ext = '.rar') or
    (Ext = '.cbz') or (Ext = '.cbr') or (Ext = '.cb7') or (Ext = '.tar') or
    (Ext = '.gz') or (Ext = '.gzip') or (Ext = '.fbz') or (Ext = '.bz2') or (Ext = '.xz') or (Ext = '.cab') or (Ext = '.tgz') or (Ext = '.7zip');
end;

function IsReaderContainer(const FileName: string): Boolean;
var Ext: string;
begin
  Ext:=LowerCase(ExtractFileExt(FileName));
  // Comic archives remain intact for a comic reader, preserving image order.
  Result:=IsReaderArchive(FileName) and (Ext<>'.cbr') and (Ext<>'.cbz') and (Ext<>'.cb7');
end;

function ReaderPlaceholderIdentity(const Value: string): Boolean;
var ID, Source, OriginalID: string; Separator, Depth: Integer;
begin
  ID := Trim(Value); Depth := 0;
  if (Length(ID) > 4096) or (Pos(#0, ID) <> 0) then Exit(True);
  while ID.StartsWith('merged:', True) do
  begin
    Inc(Depth); if Depth > 32 then Exit(True);
    Delete(ID, 1, Length('merged:')); Separator := Pos(':', ID);
    if Separator = 0 then Exit(True);
    Delete(ID, 1, Separator);
  end;
  if TryParseLibrarySourceID(ID, Source, OriginalID) then ID := OriginalID
  else if ID.StartsWith('flibusta:', True) or ID.StartsWith('librusec:', True) then
    // A reserved prefix with an empty/zero payload is still a placeholder,
    // even when whitespace makes the strict source-ID parser reject it.
    ID := Trim(Copy(ID, Pos(':', ID) + 1, MaxInt));
  if ID = '' then Exit(True);
  for var C in ID do if C <> '0' then Exit(False);
  Result := True;
end;

function ReaderCopyName(const Book: TBookRecord): string;
var Identity, Extension: string;
begin
  Identity := Book.LibID;
  if ReaderPlaceholderIdentity(Identity) then
  begin
    Identity := LowerCase(Book.Folder + #1 + Book.FileName + Book.FileExt);
    // Only unnamed members need their index to avoid sharing cache/history.
    // Named members retain the longstanding identity across index changes.
    if Book.FileName = '' then Identity := Identity + #1 + 'member-index:' + IntToStr(Book.InsideNo);
  end;
  // BookID, author and title can change after a full INPX import.
  Extension:='.'+Book.GetFileType;
  if (Pos(' ',Extension)>0) or (Length(Extension)>11) then Extension:='.bin';
  Result := 'homelib-' + IntToStr(Book.BookKey.DatabaseID) + '-' +
    Copy(THashSHA2.GetHashString(Identity), 1, 32) + Extension;
end;

function ReaderStableIdentity(const Value, DefaultLibrary: string;
  out LibraryName, OriginalID: string): Boolean;
var ID, Namespace: string; Separator, Depth: Integer; Numeric, Nonzero: Boolean;
begin
  Result := False; LibraryName := ''; OriginalID := ''; ID := Trim(Value);
  if (Length(ID) > 4096) or (Pos(#0, ID) <> 0) then Exit;
  // Merged source wrappers preserve library provenance. File-derived merge
  // keys are physical identities, not evidence that a different copy matches.
  Depth := 0;
  while ID.StartsWith('merged:', True) do
  begin
    Inc(Depth); if Depth > 32 then Exit;
    Delete(ID, 1, Length('merged:')); Separator := Pos(':', ID);
    if Separator = 0 then Exit;
    Delete(ID, 1, Separator);
  end;
  if (ID = '') or ID.StartsWith('file:', True) then Exit;
  Namespace := '';
  if TryParseLibrarySourceID(ID, Namespace, OriginalID) then
    ID := OriginalID
  else
  begin
    // These library prefixes reserve numeric IDs. Malformed source IDs must
    // not become opaque global identities after their parser rejects them.
    if ID.StartsWith('flibusta:', True) or ID.StartsWith('librusec:', True) then Exit;
    Namespace := '';
  end;
  Numeric := True; Nonzero := False;
  for var C in ID do
  begin
    Numeric := Numeric and CharInSet(C, ['0'..'9']);
    Nonzero := Nonzero or (C <> '0');
  end;
  if Numeric and not Nonzero then Exit;
  if Numeric and (Namespace = '') then
  begin
    // A numeric ID belongs to a source library; it is not globally unique.
    if not (SameText(DefaultLibrary, 'flibusta') or SameText(DefaultLibrary, 'librusec')) then Exit;
    Namespace := LowerCase(DefaultLibrary);
  end;
  LibraryName := Namespace; OriginalID := ID; Result := True;
end;

function ReaderPhysicalIdentity(const Book: TBookRecord): string;
var Container, Member: string;
begin
  Result := '';
  try
    // Metadata only. GetBookContainer probes ZIP/7z paths, so it must not be
    // used to establish identity before a candidate has been authorized.
    Container := TPath.GetFullPath(TPath.Combine(Book.CollectionRoot, Book.Folder));
    if Book.GetBookFormat(Container) in [bfFb2Archive, bfRawArchive] then
    begin
      // An index alone is not stable physical proof after archive updates.
      if Book.FileName = '' then Exit;
      Member := Book.FileName;
      if not SameText(ExtractFileExt(Member), Book.FileExt) then Member := Member + Book.FileExt;
      if Member = '' then Exit;
      Result := Container.Replace('/', '\') + #1 + Member.Replace('/', '\');
    end
    else Result := TPath.GetFullPath(Book.GetBookFileName(Container)).Replace('/', '\');
  except on E: Exception do Result := ''; end;
end;

function ReaderHistoryName(const Book: TBookRecord; const LibraryNamespace: string): string;
var ID, Namespace, OriginalID, Physical, Extension: string; Separator, Depth: Integer;
  Numeric: Boolean;
begin
  Result := ReaderCopyName(Book);
  if ReaderStableIdentity(Book.LibID, LibraryNamespace, Namespace, OriginalID) then Exit;
  ID := Trim(Book.LibID); Depth := 0;
  while ID.StartsWith('merged:', True) do
  begin
    Inc(Depth); if Depth > 32 then Exit;
    Delete(ID, 1, Length('merged:')); Separator := Pos(':', ID);
    if Separator = 0 then Exit;
    Delete(ID, 1, Separator);
  end;
  // Preserve placeholders/known merged physical keys and all opaque IDs.
  // A positive unscoped numeric ID cannot identify a book across row reuse.
  Numeric := ID <> '';
  for var C in ID do Numeric := Numeric and CharInSet(C, ['0'..'9']);
  if not Numeric or ReaderPlaceholderIdentity(Book.LibID) then Exit;
  Physical := ReaderPhysicalIdentity(Book);
  if Physical = '' then Physical := Book.CollectionRoot + #1 + Book.Folder + #1 +
    Book.FileName + Book.FileExt + #1 + IntToStr(Book.InsideNo);
  Extension := '.' + Book.GetFileType;
  if (Pos(' ', Extension) > 0) or (Length(Extension) > 11) then Extension := '.bin';
  Result := 'homelib-' + IntToStr(Book.BookKey.DatabaseID) + '-' +
    Copy(THashSHA2.GetHashString('reader-physical-history-v1' + #1 + Physical), 1, 32) + Extension;
end;

function ReaderSamePhysical(const First, Second: TBookRecord): Boolean;
var Identity: string;
begin
  Identity := ReaderPhysicalIdentity(First);
  // Exact case also protects case-sensitive directories and archive members.
  Result := (Identity <> '') and (Identity = ReaderPhysicalIdentity(Second));
end;

function ReaderBookPhysicalIdentity(const Book: TBookRecord): string;
begin Result := ReaderPhysicalIdentity(Book); end;

function ReaderBookMatchesExpectedIdentity(const ExpectedLibID, ExpectedPhysicalIdentity: string;
  const Current: TBookRecord; const LibraryNamespace: string): Boolean;
var SavedLibrary, SavedID, CurrentLibrary, CurrentID: string;
begin
  Result := ReaderStableIdentity(ExpectedLibID, LibraryNamespace, SavedLibrary, SavedID) and
    ReaderStableIdentity(Current.LibID, LibraryNamespace, CurrentLibrary, CurrentID) and
    (SavedID = CurrentID) and (SavedLibrary = CurrentLibrary);
  if not Result then
    Result := (ExpectedPhysicalIdentity <> '') and
      (ExpectedPhysicalIdentity = ReaderPhysicalIdentity(Current));
end;

function ReaderBookMatchesCatalog(const Collection: IBookCollection; const Saved: TBookRecord): Boolean;
var Current: TBookRecord;
begin
  Result := False;
  if not Assigned(Collection) or (Saved.BookKey.BookID <= 0) or
    (Saved.BookKey.DatabaseID <> Collection.CollectionID) then Exit;
  try
    Collection.GetBookRecord(Saved.BookKey, Current, False);
    Result := Current.BookKey.IsSameAs(Saved.BookKey) and
      ReaderBookMatchesExpectedIdentity(Saved.LibID, ReaderPhysicalIdentity(Saved), Current,
        VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)));
  except on E: Exception do Result := False; end;
end;

function ReaderTryGetPersonalBook(const User: ISystemData; const Collection: IBookCollection;
  const Saved: TBookRecord; out Stored: TBookRecord): Boolean;
var Namespace: string;
begin
  Result := False; Stored := Default(TBookRecord); Namespace := '';
  if not Assigned(User) or (Saved.BookKey.BookID = 0) then Exit;
  try
    User.GetBookRecord(Saved.BookKey, Stored);
    if Assigned(Collection) then Namespace := VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
    Result := Stored.BookKey.IsSameAs(Saved.BookKey) and
      ReaderBookMatchesExpectedIdentity(Saved.LibID, ReaderPhysicalIdentity(Saved), Stored, Namespace);
  except on E: Exception do Result := False; end;
end;

function TryStoreReaderBookPersonal(const Collection: IBookCollection; const User: ISystemData;
  const Expected: TBookRecord; const Fields: TBookPersonalFields;
  RequirePersonal: Boolean): TReaderPersonalWriteResult;
var Writer: IBookIdentityPersonalWriter; Physical, Namespace: string;
  Matches: TBookIdentityPredicate;
begin
  Result := rpwRejected; Physical := ReaderPhysicalIdentity(Expected); Namespace := '';
  try
    if Assigned(Collection) then
    begin
      if Collection.InBulkOperation then Exit;
      Namespace := VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
    end;
    Matches := function(const Current: TBookRecord): Boolean
      begin
        Result := Current.BookKey.IsSameAs(Expected.BookKey) and
          ReaderBookMatchesExpectedIdentity(Expected.LibID, Physical, Current, Namespace);
      end;
    if Assigned(Collection) and (Expected.BookKey.BookID > 0) and
      (Expected.BookKey.DatabaseID = Collection.CollectionID) and
      Supports(Collection, IBookIdentityPersonalWriter, Writer) then
      if Writer.TrySetIdentityPersonal(Expected, Fields,
        function(const Current: TBookRecord): Boolean
        begin
          // Fetch provenance inside the writer's snapshot as well.
          Result := Current.BookKey.IsSameAs(Expected.BookKey) and
            ReaderBookMatchesExpectedIdentity(Expected.LibID, Physical, Current,
              VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)));
        end, RequirePersonal) = biwSaved then Exit(rpwCatalog);
    Writer := nil;
    if Assigned(User) and Supports(User, IBookIdentityPersonalWriter, Writer) then
      if Writer.TrySetIdentityPersonal(Expected, Fields, Matches) = biwSaved then Result := rpwPersonal;
  except on E: Exception do Result := rpwRejected; end;
end;

function TryStoreReaderBookProgress(const Collection: IBookCollection; const Saved: TBookRecord;
  Progress: Integer): Boolean;
var Writer: IBookIdentityProgressWriter; Physical: string;
begin
  Result := False;
  if not Assigned(Collection) or (Saved.BookKey.BookID <= 0) or
    (Saved.BookKey.DatabaseID <> Collection.CollectionID) or
    (Progress < 0) or (Progress > 100) or not Supports(Collection, IBookIdentityProgressWriter, Writer) then Exit;
  Physical := ReaderPhysicalIdentity(Saved);
  try
    Result := Writer.TrySetIdentityProgress(Saved, Progress,
      function(const Current: TBookRecord): Boolean
      begin
        Result := Current.BookKey.IsSameAs(Saved.BookKey) and
          ReaderBookMatchesExpectedIdentity(Saved.LibID, Physical, Current,
            VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)));
      end);
  except on E: Exception do Result := False; end;
end;

function ResolveReaderBook(const Collection: IBookCollection; const Book: TBookRecord): TBookRecord;
var CopyBook, Current: TBookRecord; Namespace, SavedLibrary, SavedID,
  CurrentLibrary, CurrentID, CopyLibrary, CopyID: string; SavedKnown, CurrentKnown, BoundKnown: Boolean;
begin
  Result := Book;
  if not Assigned(Collection) or (Book.BookKey.BookID <= 0) or
    (Book.BookKey.DatabaseID <> Collection.CollectionID) then Exit;
  if FileExists(Book.GetBookFileName) then Exit;
  // A positive row number can be reused after a catalog replacement. Verify
  // the saved card against the current row before consulting its copy links.
  try
    Collection.GetBookRecord(Book.BookKey, Current, False);
    Namespace := VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
  except on E: Exception do Exit; end;
  SavedKnown := ReaderStableIdentity(Book.LibID, Namespace, SavedLibrary, SavedID);
  CurrentKnown := ReaderStableIdentity(Current.LibID, Namespace, CurrentLibrary, CurrentID);
  BoundKnown := SavedKnown and CurrentKnown and (SavedID = CurrentID) and
    (SavedLibrary = CurrentLibrary);
  if not BoundKnown and not ReaderSamePhysical(Book, Current) then Exit;
  for CopyBook in Collection.GetCatalogBookCopies(Book.BookKey) do
  begin
    if not ReaderSamePhysical(Book, CopyBook) then
    begin
      if not BoundKnown or not ReaderStableIdentity(CopyBook.LibID, SavedLibrary, CopyLibrary, CopyID) or
        (SavedID <> CopyID) then Continue;
      // Only a validated saved/current library can scope a raw merged copy
      // ID. The target's default may describe a different preferred source.
      // An explicit different library never qualifies.
      if (CopyLibrary <> '') and (CopyLibrary <> SavedLibrary) then Continue;
      if (SavedLibrary = '') and (CopyLibrary <> '') then Continue;
    end;
    if FileExists(CopyBook.GetBookFileName) then
    begin
      Result.Folder := CopyBook.Folder; Result.CollectionRoot := CopyBook.CollectionRoot;
      Result.FileName := CopyBook.FileName; Result.FileExt := CopyBook.FileExt;
      Result.InsideNo := CopyBook.InsideNo; Result.Size := CopyBook.Size;
      Include(Result.BookProps, bpIsLocal); Exit;
    end;
  end;
end;

function FileStamp(const Source: string; Required: Boolean): string;
var Data: TWin32FileAttributeData;
begin
  if not GetFileAttributesEx(PChar(Source), GetFileExInfoStandard, @Data) then
  begin
    if Required then RaiseLastOSError;
    Exit(Source + '|absent');
  end;
  Result := LowerCase(TPath.GetFullPath(Source)) + '|' +
    IntToStr(Data.nFileSizeHigh) + ':' + IntToStr(Data.nFileSizeLow) + '|' +
    IntToStr(Data.ftLastWriteTime.dwHighDateTime) + ':' + IntToStr(Data.ftLastWriteTime.dwLowDateTime);
end;

function ReaderSameSourcePath(const First, Second: string): Boolean;
var A, B: string; FirstHandle, SecondHandle: THandle;
  FirstInfo, SecondInfo: BY_HANDLE_FILE_INFORMATION;
begin
  A:=TPath.GetFullPath(First).Replace('/','\'); B:=TPath.GetFullPath(Second).Replace('/','\');
  if A=B then Exit(True);
  if not SameText(A,B) then Exit(False);
  // Windows casing is normally immaterial, but case-sensitive NTFS folders
  // can hold distinct books. Prove the actual file, without reading bytes.
  Result:=False;
  FirstHandle:=CreateFile(PChar(A),0,FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
  if FirstHandle=INVALID_HANDLE_VALUE then Exit;
  try
    SecondHandle:=CreateFile(PChar(B),0,FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    if SecondHandle=INVALID_HANDLE_VALUE then Exit;
    try
      Result:=GetFileInformationByHandle(FirstHandle,FirstInfo) and
        GetFileInformationByHandle(SecondHandle,SecondInfo) and
        ((FirstInfo.nFileIndexHigh<>0) or (FirstInfo.nFileIndexLow<>0)) and
        (FirstInfo.dwVolumeSerialNumber=SecondInfo.dwVolumeSerialNumber) and
        (FirstInfo.nFileIndexHigh=SecondInfo.nFileIndexHigh) and
        (FirstInfo.nFileIndexLow=SecondInfo.nFileIndexLow);
    finally CloseHandle(SecondHandle); end;
  finally CloseHandle(FirstHandle); end;
end;

function ReaderMachineFileName(const FileName: string): Boolean;
var Name: string; Numeric, Hexadecimal: Boolean; Digits: Integer;
begin
  Name:=ChangeFileExt(ExtractFileName(FileName),'');
  if Name.StartsWith('homelib-',True) then Exit(True);
  Numeric:=Name<>''; Hexadecimal:=Name<>''; Digits:=0;
  for var Ch in Name do
  begin
    Numeric:=Numeric and CharInSet(Ch,['0'..'9']);
    Hexadecimal:=Hexadecimal and CharInSet(Ch,['0'..'9','a'..'f','A'..'F','-','{','}']);
    if CharInSet(Ch,['0'..'9','a'..'f','A'..'F']) then Inc(Digits);
  end;
  Result:=Numeric or (Hexadecimal and (Digits>=16));
end;

function ReaderDisplayPart(const Value: string; MaxLength: Integer): string;
var Text: string; OutText: TStringBuilder; I, N: Integer; Ch: Char;
begin
  Text:=CheckSymbols(Value,True).Replace('.', ' '); OutText:=TStringBuilder.Create;
  try
    I:=1;
    while I<=Length(Text) do
    begin
      Ch:=Text[I]; N:=Ord(Ch);
      if (N<32) or (N=127) then Ch:=' ';
      if (N>=$D800) and (N<=$DBFF) then
      begin
        if (I<Length(Text)) and (Ord(Text[I+1])>=$DC00) and (Ord(Text[I+1])<=$DFFF) then
        begin OutText.Append(Ch).Append(Text[I+1]); Inc(I,2); Continue; end;
        Ch:=Char($FFFD);
      end
      else if (N>=$DC00) and (N<=$DFFF) then Ch:=Char($FFFD);
      if (Ch<>' ') or (OutText.Length=0) or (OutText.Chars[OutText.Length-1]<>' ') then OutText.Append(Ch);
      Inc(I);
    end;
    Result:=Trim(OutText.ToString);
  finally OutText.Free; end;
  if Length(Result)>MaxLength then
  begin
    Result:=Copy(Result,1,MaxLength);
    if (Result<>'') and (Ord(Result[Length(Result)])>=$D800) and
      (Ord(Result[Length(Result)])<=$DBFF) then Delete(Result,Length(Result),1);
    Result:=Trim(Result);
  end;
end;

function ReaderExternalPreparedStamp(const Prepared, Original: string; out Stable: Boolean): string;
var Data: TWin32FileAttributeData; Origin, Dependency: string;
begin
  Stable:=False;
  if not GetFileAttributesEx(PChar(Prepared),GetFileExInfoStandard,@Data) then RaiseLastOSError;
  // Cache maintenance touches payload last-write times on every open. A
  // proved derived copy instead uses its immutable preparation dependency.
  // Original files keep their real timestamp; missing metadata is a miss.
  if not ReaderSameSourcePath(Prepared,Original) and FileExists(Prepared+'.origin') and
    FileExists(Prepared+'.source') then
  begin
    try
      Origin:=TFile.ReadAllText(Prepared+'.origin',TEncoding.UTF8);
      if ReaderSameSourcePath(Origin,Original) then
      begin
        Dependency:=TFile.ReadAllText(Prepared+'.source',TEncoding.UTF8);
        if Dependency<>'' then
        begin
          Stable:=True;
          Exit('prepared-cache-v1|'+LowerCase(TPath.GetFullPath(Prepared))+'|'+
            IntToStr(Data.nFileSizeHigh)+':'+IntToStr(Data.nFileSizeLow)+'|'+THashSHA2.GetHashString(Dependency));
        end;
      end;
    except
      // Old/incomplete sidecars cannot authorize a cached alias hit.
    end;
  end;
  Result:=FileStamp(Prepared,True);
end;

function PrepareExternalReaderFile(const Book: TBookRecord; const PreparedFile, LibraryNamespace: string;
  ForceCopy: Boolean): string;
var Identity, Prefix, Stamp, ExistingStamp, Extension, Folder, DisplayName, Author,
  Candidate, Original, Temporary, TemporaryStamp, PendingSuffix: string;
  Writer: TBookCacheWrite; Input, Target: TStream; NameLimit: Integer;
  OwnIdentity, StablePrepared, PostStable, ForceRefresh: Boolean;
  Mutex: TFileMutex; Buffer: TBytes; ReadCount: Integer;
begin
  Result:=ExistingBookCacheFile(PreparedFile);
  if Result='' then Exit;
  Original:=Book.GetBookFileName;
  if not ReaderSameSourcePath(Result,Original) and
    not ReaderSameSourcePath(BookCacheSource(Result),Original) then
    raise Exception.Create('Подготовленная копия относится к другой книге. Откройте книгу заново.');
  if not ForceCopy and not ReaderMachineFileName(Result) then Exit;
  if (GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated then Abort;
  Extension:=ExtractFileExt(Result); Folder:=BookCachePath;
  // These are cache metadata suffixes, not supported reading formats.
  if SameText(Extension,'.source') or SameText(Extension,'.origin') or
    SameText(Extension,'.retire') or Extension.StartsWith('.pending',True) then Exit;
  Identity:=THashSHA2.GetHashString('external-reader-display-v1'+#1+IntToStr(Book.BookKey.DatabaseID)+#1+
    ReaderHistoryName(Book,LibraryNamespace)+#1+LowerCase(Trim(LibraryNamespace))+#1+
    ReaderPhysicalIdentity(Book)+#1+ExtractFileName(Result)+#1+Extension+#1+BoolToStr(ForceCopy,True));
  Prefix:='external-reader-display-v1|'+Identity+'|';
  Stamp:=Prefix+ReaderExternalPreparedStamp(Result,Original,StablePrepared);
  // The caller captures rewrite intent before starting this worker. Its
  // private copy is refreshed each time and has a separate reading identity.
  ForceRefresh:=ForceCopy or (not StablePrepared and not ReaderSameSourcePath(Result,Original));
  DisplayName:=ReaderDisplayPart(Book.Title,110);
  if DisplayName='' then DisplayName:='Книга без названия';
  Author:=''; if Length(Book.Authors)>0 then Author:=ReaderDisplayPart(Book.Authors[0].GetFullName,32);
  if Author<>'' then DisplayName:=DisplayName+' — '+Author;
  // Leave room for both .source and the writer's actual pending suffix.
  PendingSuffix:='.pending-4294967295-4294967295-{00000000-0000-0000-0000-000000000000}';
  for var SuffixLength in TArray<Integer>.Create(12,20,32,64) do
  begin
    NameLimit:=Min(140,MAX_PATH-1-Length(IncludeTrailingPathDelimiter(Folder))-Length('homelib-')-
      Length(' []')-SuffixLength-Length(Extension)-Length('.source')-Length(PendingSuffix));
    if NameLimit<8 then raise EArgumentException.Create('Папка кэша слишком длинная для имени книги. Выберите более короткий путь в настройках кэша.');
    Candidate:=ExistingBookCacheFile(TPath.Combine(Folder,'homelib-'+ReaderDisplayPart(DisplayName,NameLimit)+
      ' ['+Copy(Identity,1,SuffixLength)+']'+Extension));
    // A rewrite copy can never overwrite the original or its prepared input,
    // even if a user-supplied source happens to have our generated filename.
    if ReaderSameSourcePath(Candidate,Original) or ReaderSameSourcePath(Candidate,Result) then Continue;
    Mutex:=TFileMutex.Create(CurrentBookCacheFile(Candidate));
    try
    if not Mutex.TryAcquire then raise Exception.Create('Копия этой книги уже готовится в другом окне. Откройте её ещё раз через несколько секунд.');
    ExistingStamp:=''; OwnIdentity:=False;
    if FileExists(Candidate+'.source') then
      try ExistingStamp:=TFile.ReadAllText(Candidate+'.source',TEncoding.UTF8);
        OwnIdentity:=ExistingStamp.StartsWith(Prefix);
      except end;
    // An occupied name of another identity is never replaced, even if the
    // short hash or filename sanitization happens to collide.
    if (FileExists(Candidate) or FileExists(Candidate+'.source') or FileExists(Candidate+'.origin')) and
      not OwnIdentity then Continue;
    if not ForceRefresh and FileExists(Candidate) and (ExistingStamp=Stamp) then
    begin Result:=Candidate; RegisterBookCacheFile(Result,Original); PinReaderCacheFile(Result); Exit; end;
    ForceDirectories(Folder); Writer:=TBookCacheWrite.Create(Original); Input:=nil; Target:=nil;
    try
      Temporary:=Writer.TemporaryName(Candidate); TemporaryStamp:=Writer.TemporaryName(Candidate+'.source');
      Input:=OpenCachedBookFile(Result);
      // Establish the snapshot after the cache's own Touch, while the stream
      // denies writes. Keep this stream through publication and output pinning:
      // closing a managed input may immediately evict it under a small limit.
      Stamp:=Prefix+ReaderExternalPreparedStamp(Result,Original,StablePrepared);
      Target:=TFileStream.Create(Temporary,fmCreate);
      SetLength(Buffer,65536);
      repeat
        if (GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated then Abort;
        ReadCount:=Input.Read(Buffer[0],Length(Buffer));
        if ReadCount>0 then Target.WriteBuffer(Buffer[0],ReadCount);
      until ReadCount=0;
      FreeAndNil(Target);
      if (GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated then Abort;
      // A changing prepared copy is not valid evidence for cached bytes.
      if Prefix+ReaderExternalPreparedStamp(Result,Original,PostStable)<>Stamp then raise EAbort.Create('Подготовленная книга изменилась. Откройте её ещё раз.');
      TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8);
      Writer.Publish(Temporary,Candidate,TemporaryStamp); Result:=Candidate;
      PinReaderCacheFile(Result); Exit;
    finally Target.Free; Input.Free; Writer.Free; end;
    finally Mutex.Free; end;
  end;
  raise Exception.Create('Не удалось выбрать свободное имя копии книги для читалки.');
end;

function SourceStamp(const Book: TBookRecord; const Source: string; const ConvertImages: Boolean): string;
var Dependency: string;
begin
  Result := 'reader-cache-v2|' + FileStamp(Source, True) + '|' +
    Book.FileName + Book.FileExt + '|' + IntToStr(Book.InsideNo) + '|' +
    BoolToStr(ConvertImages, True) + '|' + PROGRAM_RELEASE_VERSION;
  if SameText(ExtractFileExt(Source), '.7z') then
    for Dependency in FLibraryImageSourceFiles(Source) do
      Result := Result + '|' + FileStamp(Dependency, False);
  Result := Result + '|' + FileStamp(FindExternalTool('djxl.exe', 'jpeg-xl'), False) +
    '|' + FileStamp(Settings.AppPath + 'tools\webp\libwebp.dll', False);
end;

function PrepareLooseArchive(const Book: TBookRecord; const Source: string; const ConvertImages: Boolean; const OnStage: TProc<string>; ConversionOnly: Boolean; const TargetExtension: string): string;
var Archive: TMHLZip; Candidates, Nested, Unknown: TList<Integer>; I, Entry, ImagePages: Integer;
  Member, Extension, Folder, Stamp, StampFile, Temporary: string;
  Dialog: TForm; Names: TListBox; OpenButton, CancelButton: TButton; LabelControl: TLabel;
  Extracted: TFileStream; Converted: TStream; Writer: TBookCacheWrite; RequestingThread: TThread;
  OnlyImages: Boolean;
begin
  RequestingThread := TThread.CurrentThread;
  if Assigned(OnStage) then OnStage('Просмотр содержимого архива…');
  Result := '';
  Archive := TMHLZip.Create(Source, True, False,
    function: Boolean begin Result:=(GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated; end,
    not SameText(ExtractFileExt(Source),'.zip'));
  Candidates := TList<Integer>.Create; Nested:=TList<Integer>.Create; Unknown:=TList<Integer>.Create;
  try
    ImagePages:=0; OnlyImages:=True;
    for I := 0 to Archive.FileCount - 1 do
    begin
      Extension := LowerCase(ExtractFileExt(Archive.FileNames[I]));
      if Archive.FileSizes[I]>0 then
        if Pos('|'+Extension+'|','|.jpg|.jpeg|.png|.gif|.bmp|.tif|.tiff|.webp|')>0 then Inc(ImagePages)
        else if not SameText(ExtractFileName(Archive.FileNames[I]),'ComicInfo.xml') and
          not SameText(ExtractFileName(Archive.FileNames[I]),'.DS_Store') and
          not SameText(ExtractFileName(Archive.FileNames[I]),'Thumbs.db') then OnlyImages:=False;
      // Archive entry paths are never used as output paths. Container layers
      // and ambiguous names are resolved after extracting one chosen member.
      if IsReaderContainer(Archive.FileNames[I]) then begin Nested.Add(I); Continue; end;
      if (Archive.FileSizes[I]>0) and (Archive.FileSizes[I]<=64*1024*1024) and
        (Pos('|'+Extension+'|','|.fbd|.exe|.com|.dll|.msi|.bat|.cmd|.ps1|.js|.css|.ttf|.otf|.woff|.woff2|.mp3|.wav|.ogg|.m4b|.mp4|.torrent|.apk|')=0) and
        (not ConversionOnly or not SameText(Extension,TargetExtension)) then Unknown.Add(I);
      if ConversionOnly then
      begin
        if IsBasicConversionSource(Extension) and not SameText(Extension,TargetExtension) and
          (Pos('|'+Extension+'|','|.jpg|.jpeg|.png|.gif|.bmp|.tif|.tiff|.webp|')=0) then Candidates.Add(I);
        Continue;
      end;
      if (Extension = '.fb2') or (Extension = '.epub') or (Extension = '.pdf') or
        (Extension = '.djvu') or (Extension = '.djv') or (Extension = '.mobi') or
        (Extension = '.azw') or (Extension = '.azw3') or (Extension = '.rtf') or
        (Extension = '.txt') or (Extension = '.doc') or (Extension = '.docx') or
        (Extension = '.htm') or (Extension = '.html') or (Extension = '.xhtml') or
        (Extension = '.odt') or (Extension = '.chm') or (Extension = '.mht') or
        (Extension = '.mhtml') or (Extension = '.wri') or (Extension = '.ppt') or
        (Extension = '.pptx') or (Extension = '.md') or (Extension = '.fb3') or
        IsLegacyReaderFormat(Extension) or (Extension='.prc') or IsOfficeReaderFormat(Extension) then Candidates.Add(I);
    end;
    // An image-only archive is one book. Keep every page instead of asking
    // the reader to choose a single image and silently omitting the others.
    if OnlyImages and (ImagePages>0) then
    begin
      Extension:=DetectReaderExtension(Source);
      if Extension='.zip' then Extension:='.cbz'
      else if Extension='.rar' then Extension:='.cbr'
      else if Extension='.7z' then Extension:='.cb7' else Extension:='';
      if Extension<>'' then
      begin
        Stamp:='comic-v1|'+SourceStamp(Book,Source,False);
        Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-comic-'+Copy(THashSHA2.GetHashString(Stamp),1,32)+Extension));
        if FileExists(Result) and FileExists(Result+'.source') and (TFile.ReadAllText(Result+'.source',TEncoding.UTF8)=Stamp) then
        begin RegisterBookCacheFile(Result,Book.GetBookFileName);Exit;end;
        ForceDirectories(ExtractFileDir(Result)); Writer:=TBookCacheWrite.Create(Book.GetBookFileName);
        try
          Temporary:=Writer.TemporaryName(Result);StampFile:=Writer.TemporaryName(Result+'.source');
          TFile.Copy(Source,Temporary,True);TFile.WriteAllText(StampFile,Stamp,TEncoding.UTF8);
          Writer.Publish(Temporary,Result,StampFile);
        finally Writer.Free;end;
        Exit;
      end;
    end;
    if Candidates.Count=0 then
      for I in Nested do Candidates.Add(I);
    if Candidates.Count=0 then
      for I in Unknown do Candidates.Add(I);
    if (Candidates.Count=0) and ConversionOnly then
      raise ENotSupportedException.Create('В архиве нет книг поддерживаемых форматов для этого преобразования. Книга, уже имеющая формат результата, повторно не конвертируется.');
    if Candidates.Count = 0 then raise Exception.Create('В архиве не найдены книги подходящего для чтения формата.');
    Entry := Candidates[0];
    if Candidates.Count > 1 then
    begin
      Entry := -1;
      TThread.Synchronize(nil,
      procedure
      begin
      if Application.Terminated or TReaderThreadAccess(RequestingThread).Terminated then Exit;
      Dialog := TForm.CreateNew(nil);
      try
        Dialog.Caption := 'Какую книгу открыть?';
        if ConversionOnly then Dialog.Caption:='Какую книгу конвертировать?'; Dialog.Position := poMainFormCenter;
        Dialog.ClientWidth := 620; Dialog.ClientHeight := 360;
        Dialog.Font.Name := 'Segoe UI'; Dialog.Font.Size := 9;
        Dialog.Constraints.MinWidth := 420; Dialog.Constraints.MinHeight := 240;
        LabelControl := TLabel.Create(Dialog); LabelControl.Parent := Dialog;
        LabelControl.SetBounds(12, 12, 590, 24); LabelControl.Caption := 'В архиве несколько книг. Выберите файл для чтения:';
        if ConversionOnly then LabelControl.Caption:='Выберите текстовую книгу для конвертации:';
        Names := TListBox.Create(Dialog); Names.Parent := Dialog;
        Names.SetBounds(12, 40, 596, 266); Names.Anchors := [akLeft, akTop, akRight, akBottom];
        for var CandidateIndex in Candidates do Names.Items.Add(Archive.FileNames[CandidateIndex]); Names.ItemIndex := 0;
        OpenButton := TButton.Create(Dialog); OpenButton.Parent := Dialog;
        OpenButton.SetBounds(380, 318, 110, 30); OpenButton.Anchors := [akRight, akBottom];
        OpenButton.Caption := 'Открыть'; OpenButton.Default := True; OpenButton.ModalResult := mrOk;
        if ConversionOnly then OpenButton.Caption:='Выбрать';
        CancelButton := TButton.Create(Dialog); CancelButton.Parent := Dialog;
        CancelButton.SetBounds(498, 318, 110, 30); CancelButton.Anchors := [akRight, akBottom];
        CancelButton.Caption := 'Отмена'; CancelButton.Cancel := True; CancelButton.ModalResult := mrCancel;
        Dialog.ScaleForPPI(Screen.PixelsPerInch);
        if Dialog.ShowModal <> mrOk then Exit;
        if Names.ItemIndex < 0 then Exit;
        Entry := Candidates[Names.ItemIndex];
      finally Dialog.Free; end;
      end);
      if Entry < 0 then Exit;
    end;
    if ConversionOnly and ((Archive.FileSizes[Entry]<0) or (Archive.FileSizes[Entry]>64*1024*1024)) then
      raise EReadError.Create('Книга в архиве превышает предел конвертации (64 МБ).');
    Member := Archive.FileNames[Entry]; Extension := LowerCase(ExtractFileExt(Member));
    Folder:=BookCachePath;
    if (Extension = FB2_EXTENSION) and ConvertImages then
      Folder := TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER);
    ForceDirectories(Folder);
    Result := TPath.Combine(Folder, 'homelib-archive-' + Copy(THashSHA2.GetHashString(
      LowerCase(TPath.GetFullPath(Source)) + #1 + Member), 1, 32) + Extension);
    Stamp := SourceStamp(Book, Source, ConvertImages) + '|member:' + Member;
    Result:=ExistingBookCacheFile(Result);
    StampFile := Result + '.source';
    if FileExists(Result) and FileExists(StampFile) then
      try if TFile.ReadAllText(StampFile, TEncoding.UTF8) = Stamp then
      begin RegisterBookCacheFile(Result,Book.GetBookFileName);
        if Assigned(OnStage) then OnStage('Открытие книги из кэша…'); Exit; end;
      except end;
    if Assigned(OnStage) then OnStage('Распаковка книги из архива…');
    Writer:=TBookCacheWrite.Create(Book.GetBookFileName);
    Converted:=nil;
    try
      Temporary:=Writer.TemporaryName(Result);
      Extracted := TFileStream.Create(Temporary, fmCreate);
      try
        Archive.ExtractToStream(Entry, Extracted); Extracted.Position := 0;
        if (Extension = FB2_EXTENSION) and ConvertImages then
          Converted := NormalizeEmbeddedWebPFb2(Extracted);
        if Assigned(Converted) then
        begin Extracted.Size := 0; Extracted.Position := 0; Converted.Position := 0; Extracted.CopyFrom(Converted, 0); end;
      finally Extracted.Free; end;
      // A missing/old stamp is a miss. Publish the bytes before marking them current.
      StampFile:=Writer.TemporaryName(Result+'.source');
      TFile.WriteAllText(StampFile,Stamp,TEncoding.UTF8);
      Writer.Publish(Temporary,Result,StampFile);
    finally Converted.Free; Writer.Free; end;
  finally Unknown.Free; Nested.Free; Candidates.Free; Archive.Free; end;
end;

function PrepareReaderFileCore(const Book: TBookRecord; const PreserveImages: Boolean; const OnStage: TProc<string>; OpenArchive: Boolean; ConversionOnly: Boolean = False; const TargetExtension: string = ''): string;
var Source, Folder, Stamp, StampFile, Temporary, TemporaryStamp: string;
  Format: TBookFormat; Stream, Converted: TStream; Target: TFileStream; ConvertImages: Boolean;
  Corrected: TBookRecord; Writer: TBookCacheWrite; Actual: string;
begin
  Source := Book.GetBookFileName;
  Format := Book.GetBookFormat;
  if not FileExists(Source) then
    raise EFileNotFoundException.Create('Не найден файл или архив коллекции: '+Source+#13#10+
      'Книга: '+Book.FileName+Book.FileExt+#13#10+'Проверьте папку книг и наличие архива, указанного в INPX.');
  ConvertImages := Settings.ConvertWebPToPNG and not PreserveImages;
  Corrected:=ResolveArchivedBook(Book);
  if (Corrected.FileName<>Book.FileName) or (Corrected.FileExt<>Book.FileExt) then
    Exit(PrepareReaderFileCore(Corrected,PreserveImages,OnStage,OpenArchive,ConversionOnly,TargetExtension));
  if not OpenArchive and (Format in [bfRaw,bfFb2]) then
  begin
    Actual:=DetectReaderExtension(Source);
    if (Actual<>'') and not SameText(Actual,ExtractFileExt(Source)) then
    begin
      Source:=PrepareDetectedReaderFile(Source,Book.GetBookFileName);
      if IsReaderContainer(Source) then Exit(PrepareLooseArchive(Book,Source,ConvertImages,OnStage,ConversionOnly,TargetExtension));
      Exit(Source);
    end;
  end;
  if OpenArchive and not IsReaderArchive(Book.FileName+Book.FileExt) then Exit(Source);
  if not OpenArchive and (Format in [bfRaw,bfFbd]) and IsReaderContainer(Source) then Exit(PrepareLooseArchive(Book, Source, ConvertImages,OnStage,ConversionOnly,TargetExtension));
  if not (Format in [bfFb2Archive, bfFbd, bfRawArchive]) and
    not ((Format = bfFb2) and ConvertImages) then Exit(Source);

  Folder:=BookCachePath;
  if (Format in [bfFb2, bfFb2Archive]) and ConvertImages then
    Folder := TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER);
  ForceDirectories(Folder);
  Result := TPath.Combine(Folder, ReaderCopyName(Book));
  Result:=ExistingBookCacheFile(Result);
  StampFile := Result + '.source';
  Stamp := SourceStamp(Book, Source, ConvertImages);
  if FileExists(Result) and FileExists(StampFile) then
    try
      if TFile.ReadAllText(StampFile, TEncoding.UTF8) = Stamp then
      begin
        RegisterBookCacheFile(Result,Source);
        if Assigned(OnStage) then OnStage('Открытие книги из кэша…');
        if not OpenArchive and IsReaderContainer(Result) then Result := PrepareLooseArchive(Book,Result,ConvertImages,OnStage,ConversionOnly,TargetExtension);
        Exit;
      end;
    except
      // An incomplete stamp is a cache miss, never a reason to use stale bytes.
    end;

  if Assigned(OnStage) then
    if Format in [bfFb2Archive,bfRawArchive,bfFbd] then OnStage('Распаковка книги из архива…')
    else OnStage('Подготовка книги для чтения…');
  Stream := nil;
  Writer:=TBookCacheWrite.Create(Source);
  try
    Temporary:=Writer.TemporaryName(Result); TemporaryStamp:=Writer.TemporaryName(StampFile);
    if (Format in [bfFb2Archive,bfRawArchive]) and not IsSevenZipArchive(Source) then
    begin
      // Share original bytes with the gallery and metadata reader. Conversion
      // belongs only to the external-reader copy, never the original cache.
      Stream := OpenRawBookSource(Book,Writer);
      if (Format=bfFb2Archive) and ConvertImages then
      begin
        if Assigned(OnStage) then OnStage('Подготовка изображений для читалки…');
        Converted := NormalizeEmbeddedWebPFb2(Stream);
        if Assigned(Converted) then begin Stream.Free; Stream := Converted; end;
      end;
      Stream.Position := 0;
    end
    else Stream := Book.GetBookStream(PreserveImages);
    // Ordinary FB2 keeps its original path and external reader history.
    if (Format = bfFb2) and (Stream is TFileStream) then Exit(Source);
    if not Assigned(Stream) then raise Exception.Create('Не удалось подготовить книгу для чтения.');
    Target := TFileStream.Create(Temporary, fmCreate);
    try Target.CopyFrom(Stream, 0); finally Target.Free; end;
    TFile.WriteAllText(TemporaryStamp, Stamp, TEncoding.UTF8);
    Writer.Publish(Temporary,Result,TemporaryStamp);
  finally
    Stream.Free;
    Writer.Free;
  end;
  if not OpenArchive and IsReaderContainer(Result) then Result := PrepareLooseArchive(Book,Result,ConvertImages,OnStage,ConversionOnly,TargetExtension);
end;

function ResolvePreparedPayload(const Book: TBookRecord; const FileName: string;
  ConvertImages, ConversionOnly: Boolean; const OnStage: TProc<string>; const TargetExtension: string): string;
begin
  Result:=FileName;
  for var Depth:=0 to 7 do
  begin
    if Result='' then Exit;
    Result:=PrepareDetectedReaderFile(Result,Book.GetBookFileName);
    if not IsReaderContainer(Result) then Exit;
    Result:=PrepareLooseArchive(Book,Result,ConvertImages,OnStage,ConversionOnly,TargetExtension);
  end;
  raise Exception.Create('Слишком много вложенных архивов книги (более восьми).');
end;

function PrepareReaderFile(const Book: TBookRecord; const PreserveImages: Boolean;
  const OnStage: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean): string;
begin
  Result := PrepareReaderFileCore(Book,PreserveImages,OnStage,OpenArchive);
  if (Result <> '') and not OpenArchive then
  begin
    Result:=ResolvePreparedPayload(Book,Result,Settings.ConvertWebPToPNG and not PreserveImages,False,OnStage,'');
    if Result='' then Exit;
    // The archive's extension can differ from its selected readable member.
    // Preserve a custom Kindle reader, but prepare KF8 for Sumatra as well.
    if not ConvertKindle then
      with Settings.Readers do
        if Assigned(Find(ExtractFileExt(Result))) then
          ConvertKindle := SameText(ExtractFileName(Find(ExtractFileExt(Result)).Path),'SumatraPDF.exe');
    if ConvertKindle then Result := PrepareKindleReflow(Result,Book.GetBookFileName,OnStage);
    if ConvertOffice then
    begin
      var Required:=RequiredReaderComponent(Settings.AppPath,ExtractFileExt(Result));
      if Required<>'' then raise EReaderComponentRequired.Create(Required);
      Result := PrepareLegacyReaderFile(Result,Book.GetBookFileName,OnStage);
      Result := PrepareOfficeReaderFile(Result,Book.GetBookFileName,OnStage);
    end;
  end;
end;

function PrepareConversionSource(const Book: TBookRecord; const OnStage: TProc<string>; const TargetExtension: string): string;
var Actual: string;
begin
  if not (Book.GetBookFormat in [bfFb2Archive,bfRawArchive,bfFbd]) then
  begin
    Actual:=DetectReaderExtension(Book.GetBookFileName);
    if (Actual='.epub') or (Actual='.fb2') then
      Exit(PrepareDetectedReaderFile(Book.GetBookFileName,Book.GetBookFileName));
  end;
  // Reuse exact-entry extraction, cache identity and the archive chooser, but
  // never prepare Office/Kindle. PDF/DjVu need a readable text layer, checked by
  // the converter after exact extraction; filename extensions are not proof.
  Result:=PrepareReaderFileCore(Book,True,OnStage,False,True,TargetExtension);
  if Result<>'' then Result:=ResolvePreparedPayload(Book,Result,False,True,OnStage,TargetExtension);
end;

type
  TReaderPreparation = class(TComponent)
  private
    FWorker: TThread;
    FTimer: TTimer;
    FStatus: TMHLOperationStatus;
    FLock: TCriticalSection;
    FStage, FResult, FError, FRequiredComponent: string;
    FOnMissingComponent: TProc<string>;
    FReady: TProc<string>;
    procedure Tick(Sender: TObject);
  public
    constructor CreateTask(Owner: TComponent; const Book: TBookRecord;
      PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean; const OnMissingComponent: TProc<string>);
    constructor CreateExternalTask(Owner: TComponent; const Book: TBookRecord;
      const PreparedFile, LibraryNamespace: string; const OnReady: TProc<string>; ForceCopy: Boolean);
    destructor Destroy; override;
  end;

constructor TReaderPreparation.CreateTask(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean; const OnMissingComponent: TProc<string>);
var Snapshot: TBookRecord;
begin
  inherited Create(Owner);
  Snapshot := Book; FReady := OnReady; FOnMissingComponent:=OnMissingComponent; FLock := TCriticalSection.Create;
  FStage := 'Подготовка книги для чтения…'; FStatus := TMHLOperationStatus.Create(FStage);
  FWorker := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        FResult := PrepareReaderFile(Snapshot,PreserveImages,
          procedure(Stage: string)
          begin
            if FWorker.CheckTerminated then Abort;
            FLock.Enter;
            try FStage := Stage; finally FLock.Leave; end;
          end,OpenArchive,ConvertKindle,ConvertOffice);
      except
        on E: EAbort do FResult := '';
        on E: EMHLComponentRequired do begin FRequiredComponent:=E.ComponentID; FError:=E.Message; end;
        on E: EReaderComponentRequired do begin FRequiredComponent:=E.ComponentID; FError:=E.Message; end;
        on E: Exception do FError := E.Message;
      end;
    end);
  FWorker.FreeOnTerminate := False;
  FTimer := TTimer.Create(Self); FTimer.Interval := 50; FTimer.OnTimer := Tick;
  FWorker.Start;
end;

constructor TReaderPreparation.CreateExternalTask(Owner: TComponent; const Book: TBookRecord;
  const PreparedFile, LibraryNamespace: string; const OnReady: TProc<string>; ForceCopy: Boolean);
var Snapshot: TBookRecord;
begin
  inherited Create(Owner);
  Snapshot:=Book; FReady:=OnReady; FLock:=TCriticalSection.Create;
  FStage:='Открытие книги во внешней читалке…'; FStatus:=TMHLOperationStatus.Create(FStage);
  FWorker:=TThread.CreateAnonymousThread(
    procedure
    begin
      try
        if FWorker.CheckTerminated then Abort;
        FResult:=PrepareExternalReaderFile(Snapshot,PreparedFile,LibraryNamespace,ForceCopy);
      except
        on E: EAbort do FResult:='';
        on E: Exception do FError:=E.Message;
      end;
    end);
  FWorker.FreeOnTerminate:=False;
  FTimer:=TTimer.Create(Self); FTimer.Interval:=50; FTimer.OnTimer:=Tick; FWorker.Start;
end;

procedure PrepareExternalReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  const PreparedFile, LibraryNamespace: string; const OnReady: TProc<string>; ForceCopy: Boolean);
var Component: TComponent;
begin
  for Component in Owner do if Component is TReaderPreparation then Exit;
  TReaderPreparation.CreateExternalTask(Owner,Book,PreparedFile,LibraryNamespace,OnReady,ForceCopy);
end;

destructor TReaderPreparation.Destroy;
begin
  FReady := nil; FTimer.Free; FTimer := nil;
  if Assigned(FWorker) then
  begin
    FWorker.Terminate;
    // Finish outstanding archive I/O before owner settings and cache unload.
    // Synchronize is needed only for the optional archive member chooser.
    FWorker.WaitFor; FWorker.Free;
  end;
  FStatus.Free; FLock.Free;
  inherited;
end;

procedure TReaderPreparation.Tick(Sender: TObject);
var Stage, ErrorText, Required: string; Ready, Missing: TProc<string>; WorkFile: string;
begin
  FLock.Enter;
  try Stage := FStage; finally FLock.Leave; end;
  FStatus.SetStage(Stage);
  if WaitForSingleObject(FWorker.Handle,0) <> WAIT_OBJECT_0 then Exit;
  FTimer.Enabled := False;
  Ready := FReady; FReady := nil; WorkFile := FResult; ErrorText := FError;
  Required:=FRequiredComponent; Missing:=FOnMissingComponent; FOnMissingComponent:=nil;
  // The callback can run a modal reader or destroy its owner. Release the
  // worker and hint first so neither can survive reading or be freed twice.
  Free;
  if (Required<>'') and Assigned(Missing) and not Application.Terminated then begin Missing(Required); Exit; end;
  if ErrorText <> '' then raise Exception.Create(ErrorText);
  if (WorkFile <> '') and Assigned(Ready) and not Application.Terminated then
    try Ready(WorkFile);
    except
      // Comic/inner archives may first need a decoder while constructing the
      // reader, after preparation has already released its background worker.
      on E: EMHLComponentRequired do
        if Assigned(Missing) and not Application.Terminated then Missing(E.ComponentID) else raise;
      on E: EReaderComponentRequired do
        if Assigned(Missing) and not Application.Terminated then Missing(E.ComponentID) else raise;
    end;
end;

procedure CancelReaderPreparations(Owner: TComponent);
var I: Integer;
begin
  for I := Owner.ComponentCount-1 downto 0 do
    if Owner.Components[I] is TReaderPreparation then Owner.Components[I].Free;
end;

function ReaderPreparationsPending(Owner: TComponent): Boolean;
begin
  Result:=False; if not Assigned(Owner) then Exit;
  for var Component in Owner do
    if Component is TReaderPreparation then Exit(True);
end;

procedure PrepareReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean; const OnMissingComponent: TProc<string>);
var Component: TComponent;
begin
  // A double click while preparing must not start duplicate decompression.
  for Component in Owner do if Component is TReaderPreparation then Exit;
  TReaderPreparation.CreateTask(Owner,Book,PreserveImages,OnReady,OpenArchive,ConvertKindle,ConvertOffice,OnMissingComponent);
end;

end.
