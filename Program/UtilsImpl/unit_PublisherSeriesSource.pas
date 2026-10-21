unit unit_PublisherSeriesSource;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  unit_Globals, unit_MHLArchiveHelpers, unit_SevenZipMetadata, unit_FB2PublisherMetadataReader;

type
  EMetadataAmbiguousBook = class(EReadError);
  // One instance per indexing pass; ordinary book opening is unaffected.
  TPublisherSeriesSource = class
  private
    FArchive: TMHLZip;
    FNative: TSevenZipMetadataArchive;
    FNativeOnly: Boolean;
    FPrefixReader: TFB2PublisherMetadataReader;
    FOwnerThread: Cardinal;
    FArchivePath: string;
    FArchiveStamp: string;
    FArchiveIndexReady: Boolean;
    FEntryIndex: TDictionary<string, Integer>;
    FBatchFiles: TDictionary<string, string>;
    FBatchDirectory: string;
    FBatchDisabled: Boolean;
    FUpcoming: TArray<TBookRecord>;
    FUpcomingStart: Integer;
    FIsCanceled: TFunc<Boolean>;
    FArchiveOpenCount: Integer;
    FBatchCount: Integer;
    function ArchiveCount: Integer;
    function ArchiveName(Index: Integer): string;
    function PrefixComplete(Stream: TStream): Boolean;
    procedure ClearBatch;
    procedure OpenArchive(const Path: string);
    function PrepareBatch(const EntryName: string): Boolean;
    function SourcePath(const Book: TBookRecord): string;
  public
    constructor Create(const IsCanceled: TFunc<Boolean>);
    destructor Destroy; override;
    function GetSourceKey(const Book: TBookRecord): string;
    function OpenCatalogMetadata(const Book: TBookRecord; out Extension: string): TStream;
    function OpenDescriptor(const Book: TBookRecord;
      const AllowExternalDecoder: Boolean = True): TStream;
    // Hold the physical container unchanged while committing a metadata plan.
    function LockSource(const Book: TBookRecord): TStream;
    procedure SetUpcoming(const Books: TArray<TBookRecord>; const Start: Integer);
    property ArchiveOpenCount: Integer read FArchiveOpenCount;
    property BatchCount: Integer read FBatchCount;
  end;

implementation

uses
  Winapi.Windows, System.IOUtils, System.JSON, System.Hash,
  unit_Settings, unit_PackageBookMetadata, dm_user, unit_MHLExternalTools;

function FileStamp(const Path: string): string;
var
  Data: TWin32FileAttributeData;
begin
  Result := '';
  if not GetFileAttributesEx(PChar(Path), GetFileExInfoStandard, @Data) or
     ((Data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) then
    Exit;
  Result := IntToHex(Data.nFileSizeHigh, 8) + IntToHex(Data.nFileSizeLow, 8) +
    IntToHex(Data.ftLastWriteTime.dwHighDateTime, 8) +
    IntToHex(Data.ftLastWriteTime.dwLowDateTime, 8);
end;

function SafeFlatBookName(const Name: string): Boolean;
var
  Ch: Char;
  Base: string;
begin
  Result := False;
  if (Name = '') or (Length(Name) > 180) or
     not SameText(ExtractFileExt(Name), '.fb2') then
    Exit;
  for Ch in Name do
    if (Ord(Ch) < 32) or CharInSet(Ch, ['/', '\', ':', '*', '?', '"', '<', '>', '|']) then
      Exit;
  Base := UpperCase(Copy(Name, 1, Pos('.', Name) - 1));
  if (Base = 'CON') or (Base = 'PRN') or (Base = 'AUX') or (Base = 'NUL') or
     ((Length(Base) = 4) and
      ((Copy(Base, 1, 3) = 'COM') or (Copy(Base, 1, 3) = 'LPT')) and
      CharInSet(Base[4], ['1'..'9'])) then
    Exit;
  Result := True;
end;

procedure TPublisherSeriesSource.SetUpcoming(const Books: TArray<TBookRecord>;
  const Start: Integer);
begin
  FUpcoming := Books;
  FUpcomingStart := Start;
end;

constructor TPublisherSeriesSource.Create(const IsCanceled: TFunc<Boolean>);
begin
  inherited Create;
  FIsCanceled := IsCanceled; FOwnerThread:=GetCurrentThreadId;
  FEntryIndex := TDictionary<string, Integer>.Create;
  FBatchFiles := TDictionary<string, string>.Create;
end;

procedure TPublisherSeriesSource.ClearBatch;
var
  Path: string;
begin
  // Only explicitly tracked files in our unique flat directory are removed.
  for Path in FBatchFiles.Values do
    if SameText(ExtractFilePath(Path), IncludeTrailingPathDelimiter(FBatchDirectory)) then
      System.SysUtils.DeleteFile(Path);
  FBatchFiles.Clear;
  if FBatchDirectory <> '' then
    RemoveDir(FBatchDirectory);
  FBatchDirectory := '';
end;

destructor TPublisherSeriesSource.Destroy;
begin
  ClearBatch;
  FBatchFiles.Free;
  FEntryIndex.Free;
  FArchive.Free; FNative.Free; FPrefixReader.Free;
  inherited;
end;

function TPublisherSeriesSource.SourcePath(const Book: TBookRecord): string;
begin
  Result := Book.GetBookFileName;
  if Book.GetBookFormat in [bfFb2Archive, bfRawArchive, bfFbd] then
    Result := TPath.Combine(Settings.ReadPath, Result);
  Result := ExpandFileName(Result);
end;

function TPublisherSeriesSource.GetSourceKey(const Book: TBookRecord): string;
var
  Path, Stamp: string;
  Parts: TJSONArray;
begin
  Result := '';
  Path := SourcePath(Book);
  Stamp := FileStamp(Path);
  if Stamp = '' then
    Exit;
  Parts := TJSONArray.Create;
  try
    Parts.Add('publisher-metadata-v3');
    Parts.Add(LowerCase(Path));
    Parts.Add(Stamp);
    Parts.Add(Ord(Book.GetBookFormat));
    Parts.Add(Book.FileName + Book.FileExt);
    Parts.Add(Book.InsideNo);
    Parts.Add(Book.LibID);
    Result := THashSHA2.GetHashString(Parts.ToJSON);
  finally
    Parts.Free;
  end;
end;

function MetadataEntryKey(const Name: string): string;
begin Result := LowerCase(StringReplace(Name,'\','/',[rfReplaceAll])); end;

function TPublisherSeriesSource.ArchiveCount: Integer;
begin if FNativeOnly then Result:=FNative.Count else Result:=FArchive.FileCount; end;
function TPublisherSeriesSource.ArchiveName(Index: Integer): string;
begin if FNativeOnly then Result:=FNative.NameAt(Index) else Result:=FArchive.FileNameAt(Index); end;
function TPublisherSeriesSource.PrefixComplete(Stream: TStream): Boolean;
var Metadata: TFB2CatalogMetadata; ErrorText: string;
begin
  Result:=False;
  // A codec may write on another thread. Do not use a COM SAX reader there;
  // the bounded prefix still works and is parsed on our owning thread later.
  if GetCurrentThreadId<>FOwnerThread then Exit;
  if not Assigned(FPrefixReader) then FPrefixReader:=TFB2PublisherMetadataReader.Create;
  Result:=FPrefixReader.ReadCatalogMetadata(Stream,Metadata,ErrorText,False,FIsCanceled)=fmsComplete;
end;

procedure TPublisherSeriesSource.OpenArchive(const Path: string);
const MaxEntries = 200000; MaxNameChars = 8*1024*1024;
var I, NameChars, Existing: Integer; Key, Stamp: string;
begin
  Stamp := FileStamp(Path);
  if (Assigned(FArchive) or Assigned(FNative)) and SameText(Path,FArchivePath) and (Stamp=FArchiveStamp) then
  begin
    if not FArchiveIndexReady then
      raise EReadError.Create('Список файлов архива слишком велик для чтения метаданных');
    Exit;
  end;
  ClearBatch; FreeAndNil(FArchive); FreeAndNil(FNative); FEntryIndex.Clear;
  FArchivePath:=Path; FArchiveStamp:=Stamp; FArchiveIndexReady:=False;
  FBatchDisabled:=False;
  FNativeOnly:=not SameText(ExtractFileExt(Path),'.zip');
  if FNativeOnly then FNative:=TSevenZipMetadataArchive.Create(Path,FIsCanceled)
  else FArchive:=TMHLZip.Create(Path,True,False,FIsCanceled);
  Inc(FArchiveOpenCount);
  if ArchiveCount>MaxEntries then
    raise EReadError.Create('Список файлов архива слишком велик для чтения метаданных');
  NameChars:=0;
  for I:=0 to ArchiveCount-1 do
  begin
    if Assigned(FIsCanceled) and FIsCanceled() then raise EAbort.Create('Чтение отменено');
    Key:=MetadataEntryKey(ArchiveName(I)); Inc(NameChars,Length(Key));
    if NameChars>MaxNameChars then
      raise EReadError.Create('Имена файлов архива превышают предел чтения метаданных');
    if FEntryIndex.TryGetValue(Key,Existing) then
    begin
      // Even a matching legacy ordinal cannot disambiguate duplicate names.
      FEntryIndex.AddOrSetValue(Key,-1); FBatchDisabled:=True;
    end else FEntryIndex.Add(Key,I);
  end;
  FArchiveIndexReady:=True;
end;

function TPublisherSeriesSource.PrepareBatch(const EntryName: string): Boolean;
const
  MaxBatchBytes = 64 * 1024 * 1024;
  MaxBatchFiles = 128;
var
  StartIndex, I, J, Count, Size: Integer;
  Total: Int64;
  Names: TArray<string>;
  Name, Path: string;
  ID: TGUID;
  FileStream: TFileStream;
begin
  Result := False;
  if FBatchDisabled or not SafeFlatBookName(EntryName) then
    Exit;
  if FBatchFiles.ContainsKey(LowerCase(EntryName)) then
    Exit(True);
  if not FEntryIndex.TryGetValue(MetadataEntryKey(EntryName), StartIndex) or (StartIndex<0) then
    Exit;
  ClearBatch;
  SetLength(Names, MaxBatchFiles);
  Names[0] := EntryName;
  Total := FArchive.FileSizes[StartIndex];
  if Total > MaxBatchBytes then
    Exit;
  Count := 1;
  for I := FUpcomingStart to High(FUpcoming) do
  begin
    Name := FUpcoming[I].FileName + FUpcoming[I].FileExt;
    if SameText(Name, EntryName) or not SafeFlatBookName(Name) or
       not SameText(SourcePath(FUpcoming[I]), FArchivePath) or
       not FEntryIndex.TryGetValue(LowerCase(Name), StartIndex) then
      Continue;
    // A catalog can contain multiple records for the same archive member.
    J := 0;
    while (J < Count) and not SameText(Names[J], Name) do
      Inc(J);
    if J < Count then
      Continue;
    Size := FArchive.FileSizes[StartIndex];
    if (Size < 0) or (Total + Size > MaxBatchBytes) then
      Continue;
    Names[Count] := Name;
    Inc(Count);
    Inc(Total, Size);
    if Count = MaxBatchFiles then
      Break;
  end;
  if Count < 2 then
    Exit;
  SetLength(Names, Count);
  CreateGUID(ID);
  FBatchDirectory := TPath.Combine(TPath.GetTempPath,
    'homelib-publisher-' + GUIDToString(ID));
  if not CreateDir(FBatchDirectory) then
    RaiseLastOSError;
  for Name in Names do
    FBatchFiles.Add(LowerCase(Name), TPath.Combine(FBatchDirectory, Name));
  try
    FArchive.ExtractFlatBatch(Names, FBatchDirectory, FIsCanceled);
    Inc(FBatchCount);
    for Name in Names do
    begin
      Path := FBatchFiles[LowerCase(Name)];
      if (GetFileAttributes(PChar(Path)) and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
        raise EReadError.Create('Unexpected extracted file');
      FileStream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
      try
        if FileStream.Size <> FArchive.FileSizes[FEntryIndex[LowerCase(Name)]] then
          raise EReadError.Create('Incomplete extracted file');
      finally
        FileStream.Free;
      end;
    end;
    Result := True;
  except
    on E: EOutOfMemory do raise;
    on E: EAccessViolation do raise;
    on E: EMHLComponentRequired do raise;
    on E: Exception do
    begin
      ClearBatch;
      if Assigned(FIsCanceled) and FIsCanceled() then
        raise;
      // Corrupt or unusual archives can still contain readable entries.
      FBatchDisabled := True;
    end;
  end;
end;

function TPublisherSeriesSource.LockSource(const Book: TBookRecord): TStream;
begin
  Result := TFileStream.Create(SourcePath(Book), fmOpenRead or fmShareDenyWrite);
end;

function TPublisherSeriesSource.OpenCatalogMetadata(const Book: TBookRecord; out Extension: string): TStream;
var Path,Entry,CandidateExtension: string; Candidate,MimeIndex: Integer; MimeStream: TStream; MimeBytes: TBytes;
begin
  Extension:=LowerCase(Book.FileExt);
  if not IsMetadataContainer(Extension) then Exit(OpenDescriptor(Book,False));
  Path:=SourcePath(Book); OpenArchive(Path);
  // A packaged EPUB can itself have been named .zip. Inspect the package
  // marker before treating its HTML resources as independent books.
  if FEntryIndex.ContainsKey('meta-inf/container.xml') then
  begin Extension:='.epub'; Exit(TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite)); end;
  if FEntryIndex.ContainsKey('fb3/body.xml') and FEntryIndex.ContainsKey('fb3/description.xml') then
  begin Extension:='.fb3'; Exit(TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite)); end;
  if FEntryIndex.ContainsKey('word/document.xml') and FEntryIndex.ContainsKey('[content_types].xml') then
  begin Extension:='.docx'; Exit(TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite)); end;
  if FEntryIndex.ContainsKey('content.xml') and FEntryIndex.ContainsKey('meta.xml') and
    FEntryIndex.TryGetValue('mimetype',MimeIndex) and (MimeIndex>=0) then
  begin
    if not Assigned(FNative) then FNative:=TSevenZipMetadataArchive.Create(Path,FIsCanceled);
    MimeStream:=FNative.ReadEntry('mimetype',256);
    try
      SetLength(MimeBytes,MimeStream.Size);
      if Length(MimeBytes)>0 then MimeStream.ReadBuffer(MimeBytes[0],Length(MimeBytes));
      if Trim(TEncoding.UTF8.GetString(MimeBytes))='application/vnd.oasis.opendocument.text' then
      begin Extension:='.odt'; Exit(TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite)); end;
    finally MimeStream.Free; end;
  end;
  Candidate:=-1;
  for var I:=0 to ArchiveCount-1 do
  begin
    CandidateExtension:=LowerCase(ExtractFileExt(ArchiveName(I)));
    if (CandidateExtension<>'.fb2') and (CandidateExtension<>'.fbd') and not IsMetadataPackage(CandidateExtension) then Continue;
    if Candidate>=0 then raise EMetadataAmbiguousBook.Create('В архиве несколько книг. Нельзя автоматически приписать их сведения одной записи каталога.');
    Candidate:=I; Entry:=ArchiveName(I); Extension:=CandidateExtension;
  end;
  if Candidate<0 then begin Extension:=''; Exit(nil); end;
  if not Assigned(FNative) then FNative:=TSevenZipMetadataArchive.Create(Path,FIsCanceled);
  if (Extension='.fb2') or (Extension='.fbd') then Result:=FNative.ReadPrefix(Entry,16*1024*1024,
    function(Stream: TStream): Boolean begin Result:=PrefixComplete(Stream); end)
  else Result:=FNative.ReadEntry(Entry,64*1024*1024);
end;

function TPublisherSeriesSource.OpenDescriptor(const Book: TBookRecord;
  const AllowExternalDecoder: Boolean): TStream;
const MaxMetadataPrefix = 16*1024*1024;
var
  Path, Entry: string;
  EntryIndex: Integer;
begin
  Result := nil;
  Path := SourcePath(Book);
  if IsMetadataPackage(Book.FileExt) then
  begin
    if Book.GetBookFormat<>bfRawArchive then
      Exit(TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite));
    OpenArchive(Path);
    if not Assigned(FNative) then FNative:=TSevenZipMetadataArchive.Create(Path,FIsCanceled);
    Exit(FNative.ReadEntry(Book.FileName+Book.FileExt,64*1024*1024));
  end;
  if Book.GetBookFormat = bfFb2 then
    Exit(TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite));
  if not (Book.GetBookFormat in [bfFb2Archive, bfFbd]) then
    Exit;
  OpenArchive(Path);
  if Book.GetBookFormat = bfFbd then
  begin
    EntryIndex:=-1;
    for var I:=0 to ArchiveCount-1 do
      if SameText(ExtractFileExt(ArchiveName(I)),'.fbd') then
      begin
        if EntryIndex>=0 then raise EReadError.Create('В архиве несколько описаний FBD; книга не определена однозначно');
        EntryIndex:=I; Entry:=ArchiveName(I);
      end;
    if EntryIndex<0 then Exit;
  end
  else
  begin
    Entry := Book.FileName + Book.FileExt;
    if not FEntryIndex.TryGetValue(MetadataEntryKey(Entry),EntryIndex) or (EntryIndex<0) then
      raise EReadError.Create('Файл книги не найден однозначно в архиве: '+Entry);
  end;
  if FNativeOnly or FArchive.EntryUsesExternalDecoder(EntryIndex) then
  begin
    // The bundled DLL decodes the exact entry into a bounded memory prefix.
    // No per-book helper process, full-file extraction or temporary book copy.
    if not Assigned(FNative) then FNative:=TSevenZipMetadataArchive.Create(Path,FIsCanceled);
    Exit(FNative.ReadPrefix(Entry,MaxMetadataPrefix,
      function(Stream: TStream): Boolean begin Result:=PrefixComplete(Stream); end));
  end
  else Result := FArchive.OpenEntryStream(EntryIndex);
end;

end.
