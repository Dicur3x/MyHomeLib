unit unit_PublisherSeriesSource;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  unit_Globals, unit_MHLArchiveHelpers;

type
  // One instance per indexing pass; ordinary book opening is unaffected.
  TPublisherSeriesSource = class
  private
    FArchive: TMHLZip;
    FArchivePath: string;
    FArchiveStamp: string;
    FEntryIndex: TDictionary<string, Integer>;
    FBatchFiles: TDictionary<string, string>;
    FBatchDirectory: string;
    FBatchDisabled: Boolean;
    FUpcoming: TArray<TBookRecord>;
    FUpcomingStart: Integer;
    FIsCanceled: TFunc<Boolean>;
    FArchiveOpenCount: Integer;
    FBatchCount: Integer;
    procedure ClearBatch;
    procedure OpenArchive(const Path: string);
    function PrepareBatch(const EntryName: string): Boolean;
    function SourcePath(const Book: TBookRecord): string;
  public
    constructor Create(const IsCanceled: TFunc<Boolean>);
    destructor Destroy; override;
    function GetSourceKey(const Book: TBookRecord): string;
    function OpenDescriptor(const Book: TBookRecord): TStream;
    procedure SetUpcoming(const Books: TArray<TBookRecord>; const Start: Integer);
    property ArchiveOpenCount: Integer read FArchiveOpenCount;
    property BatchCount: Integer read FBatchCount;
  end;

implementation

uses
  Winapi.Windows, System.IOUtils, System.JSON, System.Hash,
  unit_Settings, dm_user;

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
  FIsCanceled := IsCanceled;
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
  FArchive.Free;
  inherited;
end;

function TPublisherSeriesSource.SourcePath(const Book: TBookRecord): string;
begin
  Result := Book.GetBookFileName;
  if Book.GetBookFormat in [bfFb2Archive, bfFbd] then
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
    Parts.Add('publisher-metadata-v2');
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

procedure TPublisherSeriesSource.OpenArchive(const Path: string);
var
  I: Integer;
  Key, Stamp: string;
begin
  Stamp := FileStamp(Path);
  if Assigned(FArchive) and SameText(Path, FArchivePath) and
     (Stamp = FArchiveStamp) then
    Exit;
  ClearBatch;
  FreeAndNil(FArchive);
  FEntryIndex.Clear;
  FArchivePath := Path;
  FArchiveStamp := Stamp;
  FBatchDisabled := False;
  FArchive := TMHLZip.Create(Path, True, False, FIsCanceled);
  Inc(FArchiveOpenCount);
  if IsSevenZipArchive(Path) then
    for I := 0 to FArchive.FileCount - 1 do
    begin
      Key := LowerCase(FArchive.FileNameAt(I));
      if FEntryIndex.ContainsKey(Key) then
      begin
        // Ambiguous names must retain the normal single-entry behavior.
        FBatchDisabled := True;
        Break;
      end;
      FEntryIndex.Add(Key, I);
    end;
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
  if not FEntryIndex.TryGetValue(LowerCase(EntryName), StartIndex) then
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

function TPublisherSeriesSource.OpenDescriptor(const Book: TBookRecord): TStream;
var
  Path, Entry: string;
  Memory: TMemoryStream;
begin
  Result := nil;
  Path := SourcePath(Book);
  if Book.GetBookFormat = bfFb2 then
    Exit(TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite));
  if not (Book.GetBookFormat in [bfFb2Archive, bfFbd]) then
    Exit;
  OpenArchive(Path);
  if Book.GetBookFormat = bfFbd then
  begin
    if not FArchive.Find('*.fbd') then
      Exit;
    Entry := FArchive.LastName;
  end
  else
    Entry := Book.FileName + Book.FileExt;
  if IsSevenZipArchive(Path) and PrepareBatch(Entry) then
    Exit(TFileStream.Create(FBatchFiles[LowerCase(Entry)],
      fmOpenRead or fmShareDenyWrite));
  if not IsSevenZipArchive(Path) then
  begin
    if Book.GetBookFormat = bfFbd then
      Exit(FArchive.OpenEntryStream(FArchive.LastIndex));
    Exit(FArchive.OpenEntryStream(Book.InsideNo));
  end;
  Memory := TMemoryStream.Create;
  try
    if IsSevenZipArchive(Path) or (Book.GetBookFormat = bfFbd) then
      FArchive.ExtractToStream(Entry, Memory)
    else
      FArchive.ExtractToStream(Book.InsideNo, Memory);
    Result := Memory;
  except
    Memory.Free;
    raise;
  end;
end;

end.
