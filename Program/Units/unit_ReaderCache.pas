unit unit_ReaderCache;

interface

uses
  System.Classes, System.SysUtils, Vcl.Controls, unit_Globals, unit_Interfaces;

function ReaderCopyName(const Book: TBookRecord): string;
function ReaderHistoryName(const Book: TBookRecord; const LibraryNamespace: string): string;
function ReaderBaseHistoryName(const Book:TBookRecord; const LibraryNamespace:string):string;
function ReaderHistoryNeedsLocationProof(const Book:TBookRecord; const LibraryNamespace:string):Boolean;
function ReaderHistoryUsesStoredFolder(const Book:TBookRecord):Boolean;
function TryReaderHistoryAlias(const Book:TBookRecord; const LibraryNamespace:string; out OriginalName:string):Boolean;
function PrepareExternalReaderFile(const Book: TBookRecord; const PreparedFile, LibraryNamespace: string;
  ForceCopy: Boolean = False): string;
procedure PrepareExternalReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  const PreparedFile, LibraryNamespace: string; const OnReady: TProc<string>; ForceCopy: Boolean = False);
type
  TReaderArchiveSelection = record
    Expected, Opened: TArray<string>;
    Ambiguous: Boolean;
  end;
  PReaderArchiveSelection = ^TReaderArchiveSelection;

function PrepareReaderFile(const Book: TBookRecord; const PreserveImages: Boolean = False; const OnStage: TProc<string> = nil; OpenArchive: Boolean = False; ConvertKindle: Boolean = False; ConvertOffice: Boolean = False; const IsCanceled: TFunc<Boolean> = nil; Selection: PReaderArchiveSelection = nil): string;
procedure PrepareReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive: Boolean = False; ConvertKindle: Boolean = False; ConvertOffice: Boolean = False; const OnMissingComponent: TProc<string> = nil; const OnMissingComponents: TProc<TArray<string>> = nil;
  const ArchiveMembers: TArray<string> = nil; const OnArchiveOpened: TProc<TReaderArchiveSelection> = nil);
function IsReaderContainer(const FileName: string): Boolean;
// False is an intermediate source for explicit text-only export; never a reading copy.
function PrepareConversionSource(const Book: TBookRecord; const OnStage: TProc<string> = nil;
  const TargetExtension: string = ''; RestoreOriginalImages: Boolean = True; AllowArchiveChoice: Boolean = True; const IsCanceled: TFunc<Boolean> = nil): string;
function PrepareArchivePreviewFile(const Book: TBookRecord; const ArchiveFile: string;
  const IsCanceled: TFunc<Boolean>): string;
function IsReaderArchive(const FileName: string): Boolean;
procedure CancelReaderPreparations(Owner: TComponent);
function DeferCloseForReaderPreparation(Owner: TWinControl): Boolean;
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

{$IFDEF MHL_SQL_PROFILE}
var BeforeReaderArchiveExtractForProfile: TProc;
{$ENDIF}

implementation

uses
  System.IOUtils, System.Hash, System.Variants, System.Math, System.NetEncoding, System.RegularExpressions, System.StrUtils, System.Zip,
  unit_FileMutex, unit_LibrarySourceID, unit_ReaderMIME,
  System.Generics.Collections, Vcl.Forms, Vcl.StdCtrls,
  Vcl.ExtCtrls, System.SyncObjs, unit_MHLOperationStatus,
  Winapi.Windows, Winapi.Messages, unit_ReaderFormats, unit_ReaderKindle, unit_ReaderOffice, unit_ReaderLegacy, unit_Settings, unit_Consts, unit_FLibraryCompat, unit_MHLExternalTools,
  unit_MHLArchiveHelpers, unit_WebPCompat, unit_BookMetadataCache, unit_BookCache, dm_user, unit_ProgramUpdates, unit_BookConversion, unit_ComponentUpdates, unit_Diagnostics;

type
  TReaderThreadAccess = class(TThread);
  TArchiveBookChoiceForm = class(TForm)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;
  TReaderArchiveList = class(TListBox)
  protected
    procedure DblClick; override;
  end;

procedure TArchiveBookChoiceForm.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // Standalone reading hides the launcher while preparing a book. The
  // chooser must remain an application window that can be switched to.
  if not Assigned(Application.MainForm) or not Application.MainForm.Visible then
  begin
    Params.WndParent:=0;
    Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW) and not WS_EX_TOOLWINDOW;
  end;
end;

procedure TReaderArchiveList.DblClick;
var Dialog: TCustomForm;
begin
  inherited;
  if (ItemIndex<0) or (ItemIndex>=Items.Count) then Exit;
  Dialog:=GetParentForm(Self);
  if Assigned(Dialog) then Dialog.ModalResult:=mrOk;
end;

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

function ReaderBaseHistoryName(const Book: TBookRecord; const LibraryNamespace: string): string;
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

function ReaderHistoryUsesStoredFolder(const Book:TBookRecord):Boolean;
begin Result:=ReaderPlaceholderIdentity(Book.LibID); end;

function ReaderHistoryNeedsLocationProof(const Book:TBookRecord; const LibraryNamespace:string):Boolean;
begin
  var Namespace,OriginalID:string;
  Result:=not ReaderStableIdentity(Book.LibID,LibraryNamespace,Namespace,OriginalID);
end;

function TryReaderHistoryAlias(const Book:TBookRecord; const LibraryNamespace:string;
  out OriginalName:string):Boolean;
begin
  Result:=False; OriginalName:='';
  if not ReaderHistoryNeedsLocationProof(Book,LibraryNamespace) or
    (Book.BookKey.DatabaseID<=0) or (Book.BookKey.BookID<=0) or not Assigned(DMUser) or
    not Assigned(DMUser.SystemDB) then Exit;
  var Provider:IReaderHistoryIdentityProvider;
  if Supports(DMUser.SystemDB,IReaderHistoryIdentityProvider,Provider) then
    Result:=Provider.TryReaderHistoryAlias(Book,ReaderBaseHistoryName(Book,LibraryNamespace),OriginalName);
end;

function ReaderHistoryName(const Book:TBookRecord; const LibraryNamespace:string):string;
begin
  Result:=ReaderBaseHistoryName(Book,LibraryNamespace); var OriginalName:string;
  if TryReaderHistoryAlias(Book,LibraryNamespace,OriginalName) then Result:=OriginalName;
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
    // External readers commonly key their progress by the filename. Reuse a
    // prior owned alias of this exact physical/preparation identity after a
    // catalogue title/author edit; keep the readable name chosen on first use.
    if not FileExists(Candidate) and DirectoryExists(Folder) then
      for var Prior in TDirectory.GetFiles(Folder,'homelib-*') do
      begin
        // IOUtils masks treat square brackets as character sets. The stored
        // hash suffix must be compared literally, never used as a mask.
        if not ExtractFileName(Prior).EndsWith(' ['+Copy(Identity,1,SuffixLength)+']'+Extension,True) then Continue;
        var Attributes:=GetFileAttributes(PChar(Prior));
        if (Attributes=INVALID_FILE_ATTRIBUTES) or
          (Attributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY)<>0) then Continue;
        try
          if TFile.ReadAllText(Prior+'.source',TEncoding.UTF8).StartsWith(Prefix) then
          begin Candidate:=Prior; Break; end;
        except // Missing, foreign or locked metadata is never evidence of ownership.
        end;
      end;
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
  begin
    if SameText(Book.FileExt, '.epub') then
      Result := Result + '|flibrary-epub-v3';
    for Dependency in FLibraryImageSourceFiles(Source) do
      Result := Result + '|' + FileStamp(Dependency, False);
  end;
  Result := Result + '|' + FileStamp(FindExternalTool('djxl.exe', 'jpeg-xl'), False) +
    '|' + FileStamp(Settings.AppPath + 'tools\webp\libwebp.dll', False);
end;

function HtmlArchiveImageType(const Name: string): string;
var Extension: string;
begin
  Extension:=LowerCase(ExtractFileExt(Name));
  if (Extension='.jpg') or (Extension='.jpeg') then Exit('image/jpeg');
  if (Extension='.png') or (Extension='.gif') or (Extension='.webp') or (Extension='.bmp') then
    Exit('image/'+Extension.Substring(1));
  Result:='';
end;

function HtmlArchiveImageEntries(Archive: TMHLZip; Entry: Integer;
  const IsCanceled: TFunc<Boolean>; out Html: TBytes): TArray<TPair<string,Integer>>;
var Prefix, Name, Relative, Location, Path: string; Total, Size: Int64; Index, Delimiter: Integer;
  Available: TDictionary<string,Integer>; Found: TDictionary<string,Integer>; Source: TMemoryStream;
begin
  Result:=nil;
  Html:=nil;
  Name:=Archive.FileNames[Entry].Replace('\','/');
  Prefix:=Copy(Name,1,LastDelimiter('/',Name));
  Total:=Archive.FileSizes[Entry];
  if (Total<0) or (Total>32*1024*1024) then Exit;
  Available:=TDictionary<string,Integer>.Create; Found:=TDictionary<string,Integer>.Create;
  try
    for Index:=0 to Archive.FileCount-1 do
    begin
      Name:=Archive.FileNames[Index].Replace('\','/');
      if not Name.StartsWith(Prefix,True) or (HtmlArchiveImageType(Name)='') then Continue;
      Size:=Archive.FileSizes[Index];
      if (Size<=0) or (Size>16*1024*1024) then Continue;
      Relative:=LowerCase(Name.Substring(Length(Prefix)));
      if not Available.TryAdd(Relative,Index) then Available[Relative]:=-1;
    end;
    if Available.Count=0 then Exit;
    Source:=Archive.ExtractToStream(Entry);
    try
      if Source.Size<>Total then raise EReadError.Create('Размер HTML в архиве не совпадает с указанным.');
      SetLength(Html,Integer(Source.Size));
      if Length(Html)>0 then Source.ReadBuffer(Html[0],Length(Html));
    finally Source.Free; end;
    for var Token in TRegEx.Matches(DecodeReaderHTML(Html),ReaderHTMLTokenPattern,[roIgnoreCase,roSingleLine]) do
    begin
      if Assigned(IsCanceled) and IsCanceled() then Abort;
      if not TRegEx.IsMatch(Token.Value,'^<img(?:[ \t\r\n\f]|/?>)',[roIgnoreCase]) then Continue;
      Location:=ReaderHTMLImageSource(Token.Value);
      if (Location='') or Found.ContainsKey(Location) then Continue;
      Path:=Location;
      Delimiter:=Path.IndexOfAny(['?','#']);
      if Delimiter>=0 then Path:=Path.Substring(0,Delimiter);
      try
        Path:=TNetEncoding.URL.Decode(Path.Replace('+','%2B')).Replace('\','/');
      except
        Continue;
      end;
      while Path.StartsWith('./') do Path:=Path.Substring(2);
      Path:=Path.Replace('/./','/');
      if Path.StartsWith('/') or Path.Contains(':') or
        Path.StartsWith('../') or Path.Contains('/../') then Continue;
      if not Available.TryGetValue(LowerCase(Path),Index) or (Index<0) then Continue;
      Size:=Archive.FileSizes[Index];
      if (Total+Size>32*1024*1024) or (Found.Count>=2000) then Continue;
      Inc(Total,Size);
      Found.Add(Location,Index);
    end;
    Result:=Found.ToArray;
  finally Found.Free; Available.Free; end;
end;

procedure WriteArchivedHtml(Archive: TMHLZip; const Html: TBytes; const Location: string;
  const Images: TArray<TPair<string,Integer>>; Destination: TStream; const IsCanceled: TFunc<Boolean>);
var Boundary: string; Data: TBytes;
  procedure WriteText(const Value: string);
  var Data: TBytes;
  begin
    Data:=TEncoding.UTF8.GetBytes(Value);
    if Length(Data)>0 then Destination.WriteBuffer(Data[0],Length(Data));
  end;
  procedure Part(const Data: TBytes; const MediaType, PartLocation: string);
  var HeaderLocation: string;
  begin
    HeaderLocation:=TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(PartLocation)).
      Replace(#13,'').Replace(#10,'');
    WriteText('--'+Boundary+#13#10+'Content-Type: '+MediaType+#13#10+
      'Content-Location: =?UTF-8?B?'+HeaderLocation+'?='+#13#10+
      'Content-Transfer-Encoding: base64'#13#10#13#10);
    WriteText(TNetEncoding.Base64.EncodeBytesToString(Data)+#13#10);
  end;
begin
  Boundary:='HomeLibre-'+TGUID.NewGuid.ToString;
  WriteText('MIME-Version: 1.0'#13#10+'Content-Type: multipart/related; boundary="'+Boundary+'"'#13#10#13#10);
  Part(Html,'text/html',ExtractFileName(Location));
  for var Image in Images do
  begin
    if Assigned(IsCanceled) and IsCanceled() then Abort;
    var Source:=Archive.ExtractToStream(Image.Value);
    try
      if Source.Size<>Archive.FileSizes[Image.Value] then
        raise EReadError.Create('Размер изображения HTML в архиве не совпадает с указанным.');
      SetLength(Data,Integer(Source.Size));
      if Length(Data)>0 then Source.ReadBuffer(Data[0],Length(Data));
      Part(Data,HtmlArchiveImageType(Archive.FileNames[Image.Value]),Image.Key);
    finally Source.Free; end;
  end;
  WriteText('--'+Boundary+'--'#13#10);
end;

function PrepareLooseArchive(const Book: TBookRecord; const Source: string; const ConvertImages: Boolean;
  const OnStage: TProc<string>; ConversionOnly: Boolean; const TargetExtension: string; AllowArchiveChoice: Boolean;
  const IsCanceled: TFunc<Boolean>; Selection: PReaderArchiveSelection;
  const VolumeSetStamp: string = ''; Depth: Integer = 0): string; forward;

type
  TRarVolumeHeader = record
    Version, Index: Integer;
    NumberedName, First: Boolean;
  end;

function IsRarVolumeName(const FileName: string): Boolean;
var Extension: string;
begin
  Extension:=LowerCase(ExtractFileExt(FileName));
  Result:=(Extension='.rar') or ((Length(Extension)=4) and (Extension[2]='r') and
    CharInSet(Extension[3],['0'..'9']) and CharInSet(Extension[4],['0'..'9']));
end;

function ReadRarVolumeHeader(Archive: TMHLZip; const Member: string; out Volume: TRarVolumeHeader): Boolean;
const Signature: array[0..5] of Byte=($52,$61,$72,$21,$1A,$07);
var Prefix: TMemoryStream; Input: TFileStream; Bytes: TBytes; Offset: Integer;
  HeaderSize, BlockType, Flags, Ignored: Integer;
  function ReadNumber(out Value: Integer): Boolean;
  begin
    Value:=0;
    for var Shift:=0 to 3 do
    begin
      if Offset>=Length(Bytes) then Exit(False);
      var B:=Bytes[Offset]; Inc(Offset);
      Value:=Value or ((B and $7F) shl (Shift*7));
      if (B and $80)=0 then Exit(True);
    end;
    Result:=False;
  end;
begin
  Volume:=Default(TRarVolumeHeader);
  Volume.Index:=-1;
  if Assigned(Archive) then
  begin
    Prefix:=TMemoryStream.Create;
    try
      Archive.ExtractBookPrefix(Member,-1,96,Prefix);
      SetLength(Bytes,Integer(Prefix.Size));
      if Length(Bytes)>0 then Move(Prefix.Memory^,Bytes[0],Length(Bytes));
    finally Prefix.Free; end;
  end
  else
  begin
    Input:=TFileStream.Create(Member,fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Bytes,96);
      SetLength(Bytes,Input.Read(Bytes[0],Length(Bytes)));
    finally Input.Free; end;
  end;
  if Length(Bytes)<14 then Exit(False);
  if not CompareMem(@Bytes[0],@Signature,SizeOf(Signature)) then Exit(False);
  if (Bytes[6]=0) and (Bytes[9]=$73) then
  begin
    Flags:=Bytes[10] or (Bytes[11] shl 8);
    Volume.Version:=4;
    Volume.NumberedName:=(Flags and $10)<>0;
    Volume.First:=(Flags and $100)<>0;
  end
  else if (Bytes[6]=1) and (Bytes[7]=0) then
  begin
    Offset:=12;
    if not ReadNumber(HeaderSize) or (HeaderSize=0) then Exit(False);
    if not ReadNumber(BlockType) or (BlockType<>1) or not ReadNumber(Flags) then Exit(False);
    if ((Flags and 1)<>0) and not ReadNumber(Ignored) then Exit(False);
    if ((Flags and 2)<>0) and not ReadNumber(Ignored) then Exit(False);
    if not ReadNumber(Flags) then Exit(False);
    Volume.Version:=5;
    Volume.NumberedName:=True;
    Volume.First:=(Flags and 2)=0;
    if Volume.First then Volume.Index:=0
    else if not ReadNumber(Volume.Index) or (Volume.Index=0) then Exit(False);
  end
  else Exit(False);
  Result:=(Flags and 1)<>0;
end;

function TryPrepareRarVolumes(const Book: TBookRecord; Archive: TMHLZip; const ArchiveFile, Member: string;
  const ConvertImages: Boolean; const OnStage: TProc<string>; ConversionOnly: Boolean;
  const TargetExtension: string; AllowArchiveChoice: Boolean; const IsCanceled: TFunc<Boolean>;
  Selection: PReaderArchiveSelection; Depth: Integer; out Prepared: string): Boolean;
var Selected, Header: TRarVolumeHeader; Match: TMatch; First, SelectedNumber, NumberWidth, Number: Integer;
  Name, Extension, Prefix, Suffix, Folder, Candidate, ScratchPath, OuterStamp, Stamp, FirstPath: string;
  Staged, Volumes: TArray<string>; Output: TFileStream;
  function VolumeName(Value: Integer): string;
  begin
    if NumberWidth=0 then
    begin
      if Value=0 then Exit(Prefix+'.rar');
      Exit(Prefix+Format('.r%.2d',[Value-1]));
    end;
    Result:=Prefix+IntToStr(Value).PadLeft(NumberWidth,'0')+Suffix;
  end;
  function FindVolume(const Expected: string; out Actual: string): Boolean;
  begin
    if not Assigned(Archive) then
    begin
      Actual:=Expected;
      Exit(FileExists(Actual));
    end;
    try Actual:=Archive.ResolveBookName(Expected,-1);
    except on E: EArchiveBookEntryMissing do Exit(False); end;
    Result:=SameText(Actual.Replace('\','/'),Expected.Replace('\','/'));
  end;
  procedure CheckCanceled;
  begin
    if Assigned(IsCanceled) and IsCanceled() then Abort;
  end;
  function OpenSet(const FirstFile, Identity: string): string;
  begin
    try
      Result:=PrepareLooseArchive(Book,FirstFile,ConvertImages,OnStage,ConversionOnly,TargetExtension,
        AllowArchiveChoice,IsCanceled,Selection,Identity,Depth+1);
    except
      on E: EMHLComponentRequired do raise;
      on E: EMHLExternalToolError do
        raise EReadError.CreateFmt('Не удалось прочитать многотомный RAR «%s». Проверьте целостность '+
          'томов и наличие продолжения «%s».',[ExtractFileName(Member),ExtractFileName(VolumeName(Number))]);
    end;
  end;
begin
  Result:=ReadRarVolumeHeader(Archive,Member,Selected);
  if not Result then Exit;
  if Depth>=8 then raise EReadError.Create('Слишком много вложенных архивов книги.');

  // Use the actual RAR numbering. For a modern continuation, the archive
  // header gives its index. Older archives can mark only the first volume.
  Name:=Member.Replace('\','/');
  Extension:=LowerCase(ExtractFileExt(Name));
  NumberWidth:=0;
  Prefix:=ChangeFileExt(Name,'');
  Suffix:='';
  SelectedNumber:=0;
  if Selected.NumberedName and (Extension='.rar') then
  begin
    Match:=TRegEx.Match(ExtractFileName(Name),'([0-9]+)([^0-9]*\.rar)$',[roIgnoreCase]);
    if Match.Success then
    begin
      if not TryStrToInt(Match.Groups[1].Value,SelectedNumber) then
        raise EReadError.Create('Номер тома RAR слишком велик.');
      NumberWidth:=Match.Groups[1].Length;
      Suffix:=Match.Groups[2].Value;
      Prefix:=Copy(Name,1,Length(Name)-NumberWidth-Length(Suffix));
    end;
  end
  else if Extension<>'.rar' then
    SelectedNumber:=StrToInt(Copy(Extension,3,2))+1;
  First:=SelectedNumber;
  if not Selected.First then
  begin
    if Selected.Index>=0 then Dec(First,Selected.Index)
    else if NumberWidth=0 then First:=0
    else
      while First>0 do
      begin
        CheckCanceled;
        if not FindVolume(VolumeName(First-1),Candidate) then Break;
        if not ReadRarVolumeHeader(Archive,Candidate,Header) or (Header.Version<>Selected.Version) then Break;
        Dec(First);
        if Header.First then Break;
      end;
  end;
  if (First<0) or ((First>0) and (First=SelectedNumber) and not Selected.First and (SelectedNumber<>1)) then
    raise EReadError.CreateFmt('Не найден первый том архива «%s».',[ExtractFileName(Member)]);

  Number:=First;
  while FindVolume(VolumeName(Number),Candidate) do
  begin
    CheckCanceled;
    if not ReadRarVolumeHeader(Archive,Candidate,Header) or (Header.Version<>Selected.Version) or
      ((Number>First) and Header.First) or ((Header.Index>=0) and (Header.Index<>Number-First)) then Break;
    Volumes:=Volumes+[Candidate];
    if Number=MaxInt then Break;
    Inc(Number);
  end;
  if (Number<=SelectedNumber) or (Length(Volumes)=0) then
    raise EReadError.CreateFmt('Не найдены все тома RAR для «%s».',[ExtractFileName(Member)]);

  if not Assigned(Archive) then
  begin
    Stamp:='rar-files-v1';
    for Candidate in Volumes do Stamp:=Stamp+#1+FileStamp(Candidate,True);
    Prepared:=OpenSet(Volumes[0],Stamp);
    Exit;
  end;

  // Only the selected archive entries are copied, with simple local names.
  // The decoder follows that sequence and verifies the contents as usual.
  if Assigned(OnStage) then OnStage('Подготовка томов RAR…');
  Folder:=TPath.Combine(BookCachePath,'homelib-rar-'+TGUID.NewGuid.ToString);
  if not CreateDir(Folder) then RaiseLastOSError;
  try
    OuterStamp:=FileStamp(ArchiveFile,True);
    Stamp:='rar-volumes-v1|'+OuterStamp;
    for var I:=0 to High(Volumes) do
    begin
      CheckCanceled;
      if NumberWidth<>0 then Name:=Format('archive.part%.4d.rar',[I+1])
      else if I=0 then Name:='archive.rar'
      else Name:=Format('archive.r%.2d',[I-1]);
      ScratchPath:=TPath.Combine(Folder,Name);
      Staged:=Staged+[ScratchPath];
      if I=0 then FirstPath:=ScratchPath;
      Output:=TFileStream.Create(ScratchPath,fmCreate);
      try Archive.ExtractBookToStream(Volumes[I],-1,Output); finally Output.Free; end;
      Stamp:=Stamp+#1+Volumes[I];
    end;
    if FileStamp(ArchiveFile,True)<>OuterStamp then
      raise EReadError.Create('Архив коллекции изменился во время чтения томов RAR. Повторите открытие.');
    Prepared:=OpenSet(FirstPath,Stamp);
  finally
    for ScratchPath in Staged do System.SysUtils.DeleteFile(ScratchPath);
    RemoveDir(Folder);
  end;
end;

function PrepareLooseArchive(const Book: TBookRecord; const Source: string; const ConvertImages: Boolean;
  const OnStage: TProc<string>; ConversionOnly: Boolean; const TargetExtension: string; AllowArchiveChoice: Boolean;
  const IsCanceled: TFunc<Boolean>; Selection: PReaderArchiveSelection;
  const VolumeSetStamp: string; Depth: Integer): string;
var Archive: TMHLZip; Candidates, Nested, Unknown: TList<Integer>; I, Entry: Integer;
  Member, Extension, Folder, Stamp, StampFile, Temporary, ArchiveStamp, ArchiveKey: string;
  Preferred, PreferredScore, Score, SelectionIndex, EntryCount: Integer;
  Dialog: TForm; Names: TListBox; OpenButton, CancelButton: TButton; LabelControl: TLabel;
  Extracted: TFileStream; Converted: TStream; Writer: TBookCacheWrite; RequestingThread: TThread;
  HtmlImages: TArray<TPair<string,Integer>>;
  Html: TBytes;
  procedure SaveComicVolumes(const Destination: string);
  var Zip: TZipFile; Page: TFileStream; ScratchPage: string;
  begin
    ScratchPage:=Writer.TemporaryName(Destination);
    Zip:=TZipFile.Create;
    try
      Zip.Open(Destination,zmWrite);
      Page:=TFileStream.Create(ScratchPage,fmCreate);
      try
        for var Index:=0 to EntryCount-1 do
        begin
          if Assigned(IsCanceled) and IsCanceled() then Abort;
          var Name:=Archive.FileNames[Index].Replace('\','/');
          // ZIP names stay relative and never become extraction paths.
          if Name.StartsWith('/') or Name.Contains(':') or MatchText('..',Name.Split(['/'])) then
            raise EReadError.Create('В архиве комикса найден недопустимый путь.');
          Archive.ExtractToStream(Index,Page);
          if Page.Size<>Archive.FileSizes[Index] then raise EReadError.Create('Не удалось полностью прочитать страницу комикса.');
          Page.Position:=0; Zip.Add(Page,Name,zcStored);
        end;
      finally Page.Free; end;
    finally Zip.Free; end;
  end;
  function IsInfoCompanion(Index: Integer): Boolean;
  var Name, Stem, Parent: string; Readme: Boolean;
    function Matches(Candidate: Integer): Boolean;
    var Other: string;
    begin
      Other:=Archive.FileNames[Candidate].Replace('\','/');
      Result:=not SameText(ExtractFileExt(Other),'.txt') and
        (((Stem<>'') and SameText(ChangeFileExt(Other,''),Stem)) or
         (Readme and SameText(Copy(Other,1,LastDelimiter('/',Other)),Parent)));
    end;
  begin
    Result:=False;
    Name:=Archive.FileNames[Index].Replace('\','/');
    Parent:=Copy(Name,1,LastDelimiter('/',Name));
    Readme:=(Archive.FileSizes[Index]<=64*1024) and
      MatchText(Copy(Name,Length(Parent)+1,MaxInt),['readme.txt','readmi.txt']);
    if Name.EndsWith('_inf.txt',True) then Stem:=Copy(Name,1,Length(Name)-Length('_inf.txt'))
    else if not Readme then Exit;
    for var Candidate in Candidates do
      if Matches(Candidate) then Exit(True);
    for var Candidate in Nested do
      if Matches(Candidate) then Exit(True);
  end;
begin
  RequestingThread := TThread.CurrentThread;
  if Assigned(OnStage) then OnStage('Просмотр содержимого архива…');
  Result := '';
  if (VolumeSetStamp='') and IsRarVolumeName(Source) and TryPrepareRarVolumes(Book,nil,'',Source,
    ConvertImages,OnStage,ConversionOnly,TargetExtension,AllowArchiveChoice,IsCanceled,Selection,Depth,Result) then Exit;
  Archive := TMHLZip.Create(Source, True, False,
    function: Boolean
    begin
      Result:=((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated) or
        (Assigned(IsCanceled) and IsCanceled());
    end,
    not SameText(ExtractFileExt(Source),'.zip'));
  Candidates := TList<Integer>.Create; Nested:=TList<Integer>.Create; Unknown:=TList<Integer>.Create;
  try
    EntryCount:=Archive.FileCount;
    ArchiveKey:=VolumeSetStamp;
    ArchiveStamp:=VolumeSetStamp;
    if ArchiveKey='' then ArchiveKey:=LowerCase(TPath.GetFullPath(Source));
    // An image-only archive is one book. Keep every page instead of asking
    // the reader to choose a single image and silently omitting the others.
    if Archive.IsImageOnlyComic and
      ((Selection=nil) or (Length(Selection.Expected)=0) or
        (Length(Selection.Opened)=Length(Selection.Expected))) then
    begin
      Extension:=DetectReaderExtension(Source);
      if (Extension='.zip') or (VolumeSetStamp<>'') then Extension:='.cbz'
      else if Extension='.rar' then Extension:='.cbr'
      else if Extension='.7z' then Extension:='.cb7' else Extension:='';
      if Extension<>'' then
      begin
        if ArchiveStamp='' then ArchiveStamp:=SourceStamp(Book,Source,False);
        Stamp:='comic-v1|'+ArchiveStamp;
        Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-comic-'+Copy(THashSHA2.GetHashString(Stamp),1,32)+Extension));
        if FileExists(Result) and FileExists(Result+'.source') and (TFile.ReadAllText(Result+'.source',TEncoding.UTF8)=Stamp) then
        begin RegisterBookCacheFile(Result,Book.GetBookFileName);Exit;end;
        ForceDirectories(ExtractFileDir(Result)); Writer:=TBookCacheWrite.Create(Book.GetBookFileName);
        try
          Temporary:=Writer.TemporaryName(Result);StampFile:=Writer.TemporaryName(Result+'.source');
          if VolumeSetStamp<>'' then SaveComicVolumes(Temporary)
          else TFile.Copy(Source,Temporary,True);
          if Assigned(IsCanceled) and IsCanceled() then Abort;
          TFile.WriteAllText(StampFile,Stamp,TEncoding.UTF8);
          Writer.Publish(Temporary,Result,StampFile);
        finally Writer.Free;end;
        Exit;
      end;
    end;
    for I := 0 to EntryCount - 1 do
    begin
      if Assigned(IsCanceled) and IsCanceled() then Abort;
      Extension := LowerCase(ExtractFileExt(Archive.FileNames[I]));
      // Archive entry paths are never used as output paths. Container layers
      // and ambiguous names are resolved after extracting one chosen member.
      if IsReaderContainer(Archive.FileNames[I]) then begin Nested.Add(I); Continue; end;
      if (Archive.FileSizes[I]>0) and (Archive.FileSizes[I]<=MAX_PDF_CONVERSION_SOURCE) and
        (Pos('|'+Extension+'|','|.fbd|.exe|.com|.dll|.msi|.bat|.cmd|.ps1|.js|.css|.ttf|.otf|.woff|.woff2|.mp3|.wav|.ogg|.m4b|.mp4|.torrent|.apk|')=0) and
        (not ConversionOnly or not SameText(Extension,TargetExtension)) then Unknown.Add(I);
      if ConversionOnly then
      begin
        // FB2/EPUB already in the target format are valid exact-copy exports.
        // Keep them in the chooser, otherwise a bundle may offer only a short
        // HTML preview while hiding its complete EPUB books.
        if IsBasicConversionSource(Extension) and
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
        IsLegacyReaderFormat(Extension) or IsKfxReaderFormat(Extension) or
        (Extension='.prc') or IsOfficeReaderFormat(Extension) then Candidates.Add(I);
    end;
    // The archive may include a description of the named book beside it.
    // Keep unrelated text books eligible and preserve exact saved selections.
    for I:=Candidates.Count-1 downto 0 do
      if IsInfoCompanion(Candidates[I]) then Candidates.Delete(I);
    if Candidates.Count=0 then
      for I in Nested do Candidates.Add(I);
    if Candidates.Count=0 then
      for I in Unknown do Candidates.Add(I);
    if (Candidates.Count=0) and ConversionOnly then
      raise ENotSupportedException.Create('В архиве нет книг поддерживаемых форматов для этого преобразования.');
    if Candidates.Count = 0 then raise Exception.Create('В архиве не найдены книги подходящего для чтения формата.');
    // Highlight a main document before less likely choices in subfolders.
    Preferred:=0; PreferredScore:=MaxInt;
    for I:=0 to Candidates.Count-1 do
    begin
      Member:=Archive.FileNames[Candidates[I]].Replace('\','/');
      Extension:=LowerCase(ExtractFileExt(Member));
      Score:=0;
      if Pos('/',Member)>0 then Inc(Score,2);
      if Pos('|'+Extension+'|','|.txt|.htm|.html|.xhtml|.md|')>0 then Inc(Score);
      if SameText(Member,(Book.FileName+Book.FileExt).Replace('\','/')) then Score:=-2;
      if Score<PreferredScore then begin Preferred:=I; PreferredScore:=Score; end;
    end;
    Entry := Candidates[Preferred];
    if (Selection<>nil) and (Candidates.Count>1) then Selection.Ambiguous:=True;
    if (Selection<>nil) and (Length(Selection.Expected)>0) then
    begin
      SelectionIndex:=Length(Selection.Opened); Entry:=-1;
      if SelectionIndex<Length(Selection.Expected) then
        for I:=0 to EntryCount-1 do
          if Archive.FileNames[I]=Selection.Expected[SelectionIndex] then
          begin
            if Entry>=0 then raise EReadError.Create('В архиве несколько вложений с именем сохранённой книги.');
            Entry:=I;
          end;
      if Entry<0 then raise EReadError.Create('В архиве не найдено сохранённое вложение книги.');
    end
    else if Candidates.Count > 1 then
    begin
      if not AllowArchiveChoice then
        if ConversionOnly then
          raise EReadError.Create('В архиве несколько книг. Размер зависит от файла, выбранного при сохранении.')
        else
          raise EReadError.Create('В архиве несколько книг. Откройте архив и выберите нужную книгу.');
      Entry := -1;
      TThread.Synchronize(nil,
      procedure
      begin
      if Application.Terminated or TReaderThreadAccess(RequestingThread).Terminated then Exit;
      Dialog := TArchiveBookChoiceForm.CreateNew(nil);
      try
        if not Assigned(Application.MainForm) or not Application.MainForm.Visible then
        begin Dialog.PopupMode:=pmNone; Dialog.PopupParent:=nil; end;
        Dialog.Caption := 'Какую книгу открыть?';
        if ConversionOnly then Dialog.Caption:='Какую книгу конвертировать?'; Dialog.Position := poMainFormCenter;
        Dialog.ClientWidth := 620; Dialog.ClientHeight := 360;
        Dialog.Font.Name := 'Segoe UI'; Dialog.Font.Size := 9;
        Dialog.Constraints.MinWidth := 420; Dialog.Constraints.MinHeight := 240;
        LabelControl := TLabel.Create(Dialog); LabelControl.Parent := Dialog;
        LabelControl.SetBounds(12, 12, 590, 24); LabelControl.Caption := 'В архиве несколько книг. Выберите файл для чтения:';
        if ConversionOnly then LabelControl.Caption:='Выберите текстовую книгу для конвертации:';
        Names := TReaderArchiveList.Create(Dialog); Names.Parent := Dialog;
        Names.SetBounds(12, 40, 596, 266); Names.Anchors := [akLeft, akTop, akRight, akBottom];
        for var CandidateIndex in Candidates do Names.Items.Add(Archive.FileNames[CandidateIndex]); Names.ItemIndex := Preferred;
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
    if ((Archive.FileSizes[Entry]<0) or (Archive.FileSizes[Entry]>MAX_PDF_CONVERSION_SOURCE)) then
    begin
      if ConversionOnly then
        raise EReadError.Create('Книга в архиве превышает предел конвертации (512 МБ).');
      if not AllowArchiveChoice then
        raise EReadError.Create('Книга в архиве слишком большая для автоматического предпросмотра. Откройте её для чтения.');
    end;
    Member := Archive.FileNames[Entry]; Extension := LowerCase(ExtractFileExt(Member));
    if (Extension='.html') or (Extension='.htm') or (Extension='.xhtml') or (Extension='.shtml') then
    begin
      HtmlImages:=HtmlArchiveImageEntries(Archive,Entry,IsCanceled,Html);
      if Length(HtmlImages)>0 then Extension:='.mht';
    end;
    if Selection<>nil then Selection.Opened:=Selection.Opened+[Member];
    if IsRarVolumeName(Member) and TryPrepareRarVolumes(Book,Archive,Source,Member,ConvertImages,OnStage,
      ConversionOnly,TargetExtension,AllowArchiveChoice,IsCanceled,Selection,Depth,Result) then Exit;
    Folder:=BookCachePath;
    if (Extension = FB2_EXTENSION) and ConvertImages then
      Folder := TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER);
    ForceDirectories(Folder);
    Result := TPath.Combine(Folder, 'homelib-archive-' + Copy(THashSHA2.GetHashString(
      ArchiveKey + #1 + Member), 1, 32) + Extension);
    if ArchiveStamp='' then ArchiveStamp:=SourceStamp(Book,Source,ConvertImages)
    else ArchiveStamp:=ArchiveStamp+'|'+BoolToStr(ConvertImages,True)+'|'+PROGRAM_RELEASE_VERSION;
    Stamp := ArchiveStamp + '|member:' + Member;
    if Length(HtmlImages)>0 then Stamp:=Stamp+'|html-images-v2';
    if Extension='.pdf' then Stamp:=Stamp+'|pdf-archive-v2';
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
        {$IFDEF MHL_SQL_PROFILE}
        if Assigned(BeforeReaderArchiveExtractForProfile) then BeforeReaderArchiveExtractForProfile();
        {$ENDIF}
        if Assigned(IsCanceled) and IsCanceled() then Abort;
        if Length(HtmlImages)>0 then WriteArchivedHtml(Archive,Html,Member,HtmlImages,Extracted,IsCanceled)
        else if Length(Html)>0 then Extracted.WriteBuffer(Html[0],Length(Html))
        else Archive.ExtractToStream(Entry,Extracted);
        Extracted.Position := 0;
        if (Extension = FB2_EXTENSION) and ConvertImages then
          Converted := NormalizeEmbeddedWebPFb2(Extracted)
        else if Extension='.pdf' then
          Converted := RestoreFLibraryBook(Source,Member,Extracted);
        if Assigned(Converted) then
        begin Extracted.Size := 0; Extracted.Position := 0; Converted.Position := 0; Extracted.CopyFrom(Converted, 0); end;
      finally Extracted.Free; end;
      if Assigned(IsCanceled) and IsCanceled() then Abort;
      // A missing/old stamp is a miss. Publish the bytes before marking them current.
      StampFile:=Writer.TemporaryName(Result+'.source');
      TFile.WriteAllText(StampFile,Stamp,TEncoding.UTF8);
      Writer.Publish(Temporary,Result,StampFile);
    finally Converted.Free; Writer.Free; end;
  finally Unknown.Free; Nested.Free; Candidates.Free; Archive.Free; end;
end;

function PrepareReaderFileCore(const Book: TBookRecord; const PreserveImages: Boolean; const OnStage: TProc<string>; OpenArchive: Boolean; ConversionOnly: Boolean = False; const TargetExtension: string = ''; RestoreOriginalImages: Boolean = True; AllowArchiveChoice: Boolean = True; const IsCanceled: TFunc<Boolean> = nil; Selection: PReaderArchiveSelection = nil): string;
var Source, Folder, Stamp, StampFile, Temporary, TemporaryStamp: string;
  Format: TBookFormat; Stream, Converted: TStream; Target: TFileStream; ConvertImages: Boolean;
  Corrected: TBookRecord; Writer: TBookCacheWrite; Actual, Member: string; Archive: TMHLZip;
begin
  Source := Book.GetBookFileName;
  Format := Book.GetBookFormat;
  if not FileExists(Source) then
  begin
    if Book.IsLinkedSource then
      raise EFileNotFoundException.Create('Не найден исходный файл книги: '+Source+sLineBreak+
        'Подключите диск. Если книгу перенесли, откройте «Информация о книге → Файл» в исходной коллекции и укажите новый путь.');
    raise EFileNotFoundException.Create('Не найден файл или архив коллекции: '+Source+#13#10+
      'Книга: '+Book.FileName+Book.FileExt+#13#10+'Проверьте папку книг и наличие архива, указанного в INPX.');
  end;
  if Book.IsLinkedSource and (Format=bfFb2) and (DetectReaderExtension(Source)<>'.fb2') then
    Format:=bfRaw;
  ConvertImages := Settings.ConvertWebPToPNG and not PreserveImages;
  Corrected:=ResolveArchivedBook(Book);
  if (Corrected.FileName<>Book.FileName) or (Corrected.FileExt<>Book.FileExt) then
    Exit(PrepareReaderFileCore(Corrected,PreserveImages,OnStage,OpenArchive,ConversionOnly,TargetExtension,RestoreOriginalImages,AllowArchiveChoice,IsCanceled,Selection));
  if not OpenArchive and (Format=bfRawArchive) and IsRarVolumeName(Book.FileName+Book.FileExt) then
  begin
    Member:=Book.FileName;
    if not SameText(ExtractFileExt(Member),Book.FileExt) then Member:=Member+Book.FileExt;
    Archive:=TMHLZip.Create(Source,True,False,IsCanceled);
    try
      Member:=Archive.ResolveBookName(Member,Book.InsideNo);
      if TryPrepareRarVolumes(Book,Archive,Source,Member,ConvertImages,OnStage,ConversionOnly,
        TargetExtension,AllowArchiveChoice,IsCanceled,Selection,0,Result) then Exit;
    finally Archive.Free; end;
  end;
  // A continuation such as .r00 must find its first volume before format
  // detection makes a renamed .rar copy with no sibling volumes beside it.
  if not OpenArchive and (Format=bfRaw) and IsRarVolumeName(Source) and
    not SameText(ExtractFileExt(Source),'.rar') and
    TryPrepareRarVolumes(Book,nil,'',Source,ConvertImages,OnStage,ConversionOnly,TargetExtension,
      AllowArchiveChoice,IsCanceled,Selection,0,Result) then Exit;
  // An already validated FB2 compatibility copy is checked below before
  // reopening source bytes. Raw/unconverted sources still need detection here.
  if not OpenArchive and (Format in [bfRaw,bfFb2]) and
    not ((Format=bfFb2) and ConvertImages) then
  begin
    Actual:=DetectReaderExtension(Source);
    if (Actual<>'') and not SameText(Actual,ExtractFileExt(Source)) then
    begin
      Source:=PrepareDetectedReaderFile(Source,Book.GetBookFileName);
      if IsReaderContainer(Source) then Exit(PrepareLooseArchive(Book,Source,ConvertImages,OnStage,ConversionOnly,TargetExtension,AllowArchiveChoice,IsCanceled,Selection));
      Exit(Source);
    end;
  end;
  if OpenArchive and not IsReaderArchive(Book.FileName+Book.FileExt) then Exit(Source);
  if not OpenArchive and (Format in [bfRaw,bfFbd]) and IsReaderContainer(Source) then Exit(PrepareLooseArchive(Book, Source, ConvertImages,OnStage,ConversionOnly,TargetExtension,AllowArchiveChoice,IsCanceled,Selection));
  if not (Format in [bfFb2Archive, bfFbd, bfRawArchive]) and
    not ((Format = bfFb2) and ConvertImages) then Exit(Source);

  Folder:=BookCachePath;
  if (Format in [bfFb2, bfFb2Archive]) and ConvertImages then
    Folder := TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER);
  ForceDirectories(Folder);
  var CopyName:=ReaderCopyName(Book);
  if not RestoreOriginalImages then CopyName:=CopyName.Insert(Length('homelib-'),'unrestored-');
  Result := TPath.Combine(Folder, CopyName);
  Result:=ExistingBookCacheFile(Result);
  StampFile := Result + '.source';
  Stamp := SourceStamp(Book, Source, ConvertImages);
  if SameText(Book.FileExt,'.pdf') and (Format=bfRawArchive) then Stamp:=Stamp+'|pdf-archive-v2';
  if not RestoreOriginalImages then Stamp:='conversion-unrestored-v1|'+Stamp;
  if FileExists(Result) and FileExists(StampFile) then
    try
      if TFile.ReadAllText(StampFile, TEncoding.UTF8) = Stamp then
      begin
        RegisterBookCacheFile(Result,Source);
        if Assigned(OnStage) then OnStage('Открытие книги из кэша…');
        if not OpenArchive and IsReaderContainer(Result) then Result := PrepareLooseArchive(Book,Result,ConvertImages,OnStage,ConversionOnly,TargetExtension,AllowArchiveChoice,IsCanceled,Selection);
        Exit;
      end;
    except
      // An incomplete stamp is a cache miss, never a reason to use stale bytes.
    end;

  // A cache miss must still inspect content, including falsely named FB2.
  // The source stamp above invalidates this hit on source/dependency changes.
  if not OpenArchive and (Format=bfFb2) and ConvertImages then
  begin
    Actual:=DetectReaderExtension(Source);
    if (Actual<>'') and not SameText(Actual,ExtractFileExt(Source)) then
    begin
      Source:=PrepareDetectedReaderFile(Source,Book.GetBookFileName);
      if IsReaderContainer(Source) then Exit(PrepareLooseArchive(Book,Source,ConvertImages,OnStage,ConversionOnly,TargetExtension,AllowArchiveChoice,IsCanceled,Selection));
      Exit(Source);
    end;
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
      Stream := OpenRawBookSource(Book,Writer,IsCanceled);
      if (Format=bfFb2Archive) and ConvertImages then
      begin
        if Assigned(OnStage) then OnStage('Подготовка изображений для читалки…');
        Converted := NormalizeEmbeddedWebPFb2(Stream);
        if Assigned(Converted) then begin Stream.Free; Stream := Converted; end;
      end;
      Stream.Position := 0;
    end
    else Stream := Book.GetBookStream(PreserveImages,RestoreOriginalImages,IsCanceled);
    // Ordinary FB2 keeps its original path and external reader history.
    if (Format = bfFb2) and (Stream is TFileStream) then Exit(Source);
    if not Assigned(Stream) then raise Exception.Create('Не удалось подготовить книгу для чтения.');
    Target := TFileStream.Create(Temporary, fmCreate);
    try Target.CopyFrom(Stream, 0); finally Target.Free; end;
    if Assigned(IsCanceled) and IsCanceled() then Abort;
    TFile.WriteAllText(TemporaryStamp, Stamp, TEncoding.UTF8);
    Writer.Publish(Temporary,Result,TemporaryStamp);
  finally
    Stream.Free;
    Writer.Free;
  end;
  if not OpenArchive and IsReaderContainer(Result) then Result := PrepareLooseArchive(Book,Result,ConvertImages,OnStage,ConversionOnly,TargetExtension,AllowArchiveChoice,IsCanceled,Selection);
end;

function ResolvePreparedPayload(const Book: TBookRecord; const FileName: string;
  ConvertImages, ConversionOnly: Boolean; const OnStage: TProc<string>; const TargetExtension: string; AllowArchiveChoice: Boolean = True; const IsCanceled: TFunc<Boolean> = nil; Selection: PReaderArchiveSelection = nil): string;
begin
  Result:=FileName;
  for var Depth:=0 to 7 do
  begin
    if Result='' then Exit;
    Result:=PrepareDetectedReaderFile(Result,Book.GetBookFileName);
    if SameText(ExtractFileExt(Result),'.b1') then
    begin
      Result:=PrepareB1ReaderFile(Result,Book.GetBookFileName,OnStage);
      // In particular, an archived PDF stays on the instant paged reader path.
      Result:=PrepareDetectedReaderFile(Result,Book.GetBookFileName);
    end;
    if not IsReaderContainer(Result) then Exit;
    Result:=PrepareLooseArchive(Book,Result,ConvertImages,OnStage,ConversionOnly,TargetExtension,AllowArchiveChoice,IsCanceled,Selection);
  end;
  raise Exception.Create('Слишком много вложенных архивов книги (более восьми).');
end;

function PrepareArchivePreviewFile(const Book: TBookRecord; const ArchiveFile: string;
  const IsCanceled: TFunc<Boolean>): string;
begin
  Result:=ResolvePreparedPayload(Book,ArchiveFile,False,False,nil,'',False,IsCanceled);
end;

function PrepareReaderFile(const Book: TBookRecord; const PreserveImages: Boolean;
  const OnStage: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean; const IsCanceled: TFunc<Boolean>; Selection: PReaderArchiveSelection): string;
begin
  if Selection<>nil then begin Selection.Opened:=nil; Selection.Ambiguous:=False; end;
  Result := PrepareReaderFileCore(Book,PreserveImages,OnStage,OpenArchive,False,'',True,True,IsCanceled,Selection);
  if (Result <> '') and not OpenArchive then
  begin
    Result:=ResolvePreparedPayload(Book,Result,Settings.ConvertWebPToPNG and not PreserveImages,False,OnStage,'',True,IsCanceled,Selection);
    if Result='' then Exit;
    if (Selection<>nil) and (Length(Selection.Expected)>0) and
      (Length(Selection.Opened)<>Length(Selection.Expected)) then
      raise EReadError.Create('В архиве не найдено сохранённое вложение книги.');
    // The archive's extension can differ from its selected readable member.
    // Preserve a custom Kindle reader, but prepare KF8 for Sumatra as well.
    if not ConvertKindle then
      with Settings.Readers do
        if Assigned(Find(ExtractFileExt(Result))) then
          ConvertKindle := SameText(ExtractFileName(Find(ExtractFileExt(Result)).Path),'SumatraPDF.exe');
    if ConvertKindle then Result := PrepareKindleReflow(Result,Book.GetBookFileName,OnStage);
    if ConvertOffice then
    begin
      if IsKfxReaderFormat(ExtractFileExt(Result)) then
        Exit(PrepareKfxReflow(Result,Book.GetBookFileName,OnStage,IsCanceled));
      var Required:=RequiredReaderComponent(Settings.AppPath,ExtractFileExt(Result));
      if Required<>'' then raise EReaderComponentRequired.Create(Required);
      Result := PrepareLegacyReaderFile(Result,Book.GetBookFileName,OnStage,IsCanceled);
      Result := PrepareOfficeReaderFile(Result,Book.GetBookFileName,OnStage);
    end;
  end;
end;

function PrepareConversionSource(const Book: TBookRecord; const OnStage: TProc<string>; const TargetExtension: string; RestoreOriginalImages, AllowArchiveChoice: Boolean; const IsCanceled: TFunc<Boolean>): string;
var Actual: string;
begin
  if not (Book.GetBookFormat in [bfFb2Archive,bfRawArchive,bfFbd]) then
  begin
    Actual:=DetectReaderExtension(Book.GetBookFileName);
    if (Actual='.epub') or (Actual='.fb2') or (Actual='.pdf') then
      Exit(PrepareDetectedReaderFile(Book.GetBookFileName,Book.GetBookFileName));
  end;
  // Reuse exact-entry extraction, cache identity and the archive chooser, but
  // never prepare Office/Kindle. PDF/DjVu need a readable text layer, checked by
  // the converter after exact extraction; filename extensions are not proof.
  Result:=PrepareReaderFileCore(Book,True,OnStage,False,True,TargetExtension,RestoreOriginalImages,AllowArchiveChoice,IsCanceled);
  if Result<>'' then Result:=ResolvePreparedPayload(Book,Result,False,True,OnStage,TargetExtension,AllowArchiveChoice,IsCanceled);
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
    FRequiredComponents: TArray<string>;
    FOnMissingComponents: TProc<TArray<string>>;
    FReady: TProc<string>;
    FOnArchiveOpened: TProc<TReaderArchiveSelection>;
    FArchiveSelection: TReaderArchiveSelection;
    FCloseRequested: Boolean;
    procedure Tick(Sender: TObject);
  public
    constructor CreateTask(Owner: TComponent; const Book: TBookRecord;
      PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean; const OnMissingComponent: TProc<string>; const OnMissingComponents: TProc<TArray<string>>;
      const ArchiveMembers: TArray<string>; const OnArchiveOpened: TProc<TReaderArchiveSelection>);
    constructor CreateExternalTask(Owner: TComponent; const Book: TBookRecord;
      const PreparedFile, LibraryNamespace: string; const OnReady: TProc<string>; ForceCopy: Boolean);
    destructor Destroy; override;
  end;

constructor TReaderPreparation.CreateTask(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean; const OnMissingComponent: TProc<string>; const OnMissingComponents: TProc<TArray<string>>;
  const ArchiveMembers: TArray<string>; const OnArchiveOpened: TProc<TReaderArchiveSelection>);
var Snapshot: TBookRecord; Selection: PReaderArchiveSelection;
begin
  inherited Create(Owner);
  Snapshot := Book; FReady := OnReady; FOnMissingComponent:=OnMissingComponent; FOnMissingComponents:=OnMissingComponents; FLock := TCriticalSection.Create;
  FOnArchiveOpened:=OnArchiveOpened; FArchiveSelection.Expected:=Copy(ArchiveMembers);
  Selection:=nil;
  if Assigned(FOnArchiveOpened) or (Length(ArchiveMembers)>0) then Selection:=@FArchiveSelection;
  FStage := 'Подготовка книги для чтения…'; FStatus := TMHLOperationStatus.Create(FStage);
  FWorker := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        if DetailedDiagnosticLogging then
          LogDiagnosticTrace('reader-prepare-start',Format('Книга: %s; коллекция: %d; запись: %d'+sLineBreak+
            'Исходный файл: %s',[Snapshot.Title,Snapshot.BookKey.DatabaseID,Snapshot.BookKey.BookID,
            Snapshot.GetBookFileName]),Snapshot.FileExt);
        FResult := PrepareReaderFile(Snapshot,PreserveImages,
          procedure(Stage: string)
          begin
            if FWorker.CheckTerminated then Abort;
            FLock.Enter;
            try FStage := Stage; finally FLock.Leave; end;
          end,OpenArchive,ConvertKindle,ConvertOffice,
          function: Boolean begin Result:=TThread.CheckTerminated; end,Selection);
        LogDiagnosticTrace('reader-prepare-ready',Snapshot.Title+sLineBreak+FResult,Snapshot.FileExt);
      except
        on E: EAbort do begin FResult := ''; LogDiagnosticTrace('reader-prepare-cancel',Snapshot.Title,Snapshot.FileExt); end;
        on E: EMHLComponentRequired do
        begin
          FRequiredComponent:=E.ComponentID; FRequiredComponents:=Copy(E.ComponentIDs); FError:=E.Message;
          LogDiagnosticTrace('reader-module-required',Snapshot.Title+sLineBreak+String.Join(', ',FRequiredComponents)+sLineBreak+FError,Snapshot.FileExt);
        end;
        on E: EReaderComponentRequired do
        begin
          FRequiredComponent:=E.ComponentID; FError:=E.Message;
          LogDiagnosticTrace('reader-module-required',Snapshot.Title+sLineBreak+FRequiredComponent+sLineBreak+FError,Snapshot.FileExt);
        end;
        on E: Exception do
        begin
          LogDiagnosticError('reader-prepare',E,Snapshot.FileExt); FError := E.Message;
          LogDiagnosticTrace('reader-prepare-failed',Snapshot.Title+sLineBreak+FError,Snapshot.FileExt);
        end;
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
        on E: Exception do begin LogDiagnosticError('external-reader-prepare',E,ExtractFileExt(PreparedFile)); FError:=E.Message; end;
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
  FReady := nil; FOnMissingComponent:=nil; FOnMissingComponents:=nil; FTimer.Free; FTimer := nil;
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
  MissingMany:TProc<TArray<string>>; RequiredIDs:TArray<string>;
  ClosingOwner: TWinControl;
  ArchiveOpened: TProc<TReaderArchiveSelection>; Selection: TReaderArchiveSelection;
begin
  if FCloseRequested then
  begin
    if WaitForSingleObject(FWorker.Handle,0)<>WAIT_OBJECT_0 then Exit;
    ClosingOwner:=TWinControl(Owner);
    Free;
    if ClosingOwner.HandleAllocated then PostMessage(ClosingOwner.Handle,WM_CLOSE,0,0);
    Exit;
  end;
  FLock.Enter;
  try Stage := FStage; finally FLock.Leave; end;
  FStatus.SetStage(Stage);
  if WaitForSingleObject(FWorker.Handle,0) <> WAIT_OBJECT_0 then Exit;
  FTimer.Enabled := False;
  Ready := FReady; FReady := nil; WorkFile := FResult; ErrorText := FError;
  ArchiveOpened:=FOnArchiveOpened; Selection:=FArchiveSelection;
  Required:=FRequiredComponent; Missing:=FOnMissingComponent; FOnMissingComponent:=nil;
  RequiredIDs:=Copy(FRequiredComponents); MissingMany:=FOnMissingComponents; FOnMissingComponents:=nil;
  // The callback can run a modal reader or destroy its owner. Release the
  // worker and hint first so neither can survive reading or be freed twice.
  Free;
  if (Required<>'') and Assigned(MissingMany) and not Application.Terminated then
  begin
    if Length(RequiredIDs)=0 then RequiredIDs:=TArray<string>.Create(Required);
    MissingMany(RequiredIDs); Exit;
  end;
  if (Required<>'') and Assigned(Missing) and not Application.Terminated then begin Missing(Required); Exit; end;
  if ErrorText <> '' then raise Exception.Create(ErrorText);
  if (WorkFile <> '') and Assigned(Ready) and not Application.Terminated then
    try
      if Assigned(ArchiveOpened) then ArchiveOpened(Selection);
      Ready(WorkFile);
    except
      // Comic/inner archives may first need a decoder while constructing the
      // reader, after preparation has already released its background worker.
      on E: EMHLComponentRequired do
        if Assigned(MissingMany) and not Application.Terminated then MissingMany(E.ComponentIDs)
        else if Assigned(Missing) and not Application.Terminated then Missing(E.ComponentID) else raise;
      on E: EReaderComponentRequired do
        if Assigned(MissingMany) and not Application.Terminated then MissingMany(TArray<string>.Create(E.ComponentID))
        else if Assigned(Missing) and not Application.Terminated then Missing(E.ComponentID) else raise;
    end;
end;

procedure CancelReaderPreparations(Owner: TComponent);
var I: Integer;
begin
  for I := Owner.ComponentCount-1 downto 0 do
    if Owner.Components[I] is TReaderPreparation then Owner.Components[I].Free;
end;

function DeferCloseForReaderPreparation(Owner: TWinControl): Boolean;
begin
  for var Component in Owner do
    if Component is TReaderPreparation then
    begin
      var Preparation:=TReaderPreparation(Component);
      Preparation.FCloseRequested:=True;
      Preparation.FWorker.Terminate;
      Preparation.FStatus.SetStage('Отмена подготовки книги…');
      Exit(True);
    end;
  Result:=False;
end;

function ReaderPreparationsPending(Owner: TComponent): Boolean;
begin
  Result:=False; if not Assigned(Owner) then Exit;
  for var Component in Owner do
    if Component is TReaderPreparation then Exit(True);
end;

procedure PrepareReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean; const OnMissingComponent: TProc<string>; const OnMissingComponents: TProc<TArray<string>>;
  const ArchiveMembers: TArray<string>; const OnArchiveOpened: TProc<TReaderArchiveSelection>);
var Component: TComponent;
begin
  // A double click while preparing must not start duplicate decompression.
  for Component in Owner do if Component is TReaderPreparation then Exit;
  TReaderPreparation.CreateTask(Owner,Book,PreserveImages,OnReady,OpenArchive,ConvertKindle,ConvertOffice,OnMissingComponent,OnMissingComponents,
    ArchiveMembers,OnArchiveOpened);
end;

end.
