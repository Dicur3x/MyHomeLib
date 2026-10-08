unit unit_ReaderCache;

interface

uses
  unit_Globals;

function ReaderCopyName(const Book: TBookRecord): string;
function PrepareReaderFile(const Book: TBookRecord): string;

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Hash,
  Winapi.Windows, unit_Settings, unit_Consts, unit_FLibraryCompat, unit_MHLExternalTools,
  dm_user, unit_ProgramUpdates;

function ReaderCopyName(const Book: TBookRecord): string;
var Identity: string;
begin
  Identity := Book.LibID;
  if Identity = '' then
    Identity := LowerCase(Book.Folder + #1 + Book.FileName + Book.FileExt);
  // BookID, author and title can change after a full INPX import.
  Result := 'homelib-' + IntToStr(Book.BookKey.DatabaseID) + '-' +
    Copy(THashSHA2.GetHashString(Identity), 1, 32) + LowerCase(Book.FileExt);
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

function SourceStamp(const Book: TBookRecord; const Source: string): string;
var Dependency: string;
begin
  Result := 'reader-cache-v1|' + FileStamp(Source, True) + '|' +
    Book.FileName + Book.FileExt + '|' + IntToStr(Book.InsideNo) + '|' +
    BoolToStr(Settings.ConvertWebPToPNG, True) + '|' + PROGRAM_RELEASE_VERSION;
  if SameText(ExtractFileExt(Source), '.7z') then
    for Dependency in FLibraryImageSourceFiles(Source) do
      Result := Result + '|' + FileStamp(Dependency, False);
  Result := Result + '|' + FileStamp(FindExternalTool('djxl.exe', 'jpeg-xl'), False) +
    '|' + FileStamp(Settings.AppPath + 'tools\webp\libwebp.dll', False);
end;

procedure PublishFile(const Temporary, Destination: string);
begin
  if not MoveFileEx(PChar(Temporary), PChar(Destination),
    MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
end;

function PrepareReaderFile(const Book: TBookRecord): string;
var Source, Folder, Stamp, StampFile, Temporary, TemporaryStamp: string;
  Format: TBookFormat; Stream: TStream; Target: TFileStream;
begin
  Source := Book.GetBookFileName;
  Format := Book.GetBookFormat;
  if not (Format in [bfFb2Archive, bfFbd, bfRawArchive]) and
    not ((Format = bfFb2) and Settings.ConvertWebPToPNG) then Exit(Source);

  Folder := Settings.ReadPath;
  if (Format in [bfFb2, bfFb2Archive]) and Settings.ConvertWebPToPNG then
    Folder := TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER);
  ForceDirectories(Folder);
  Result := TPath.Combine(Folder, ReaderCopyName(Book));
  StampFile := Result + '.source';
  Stamp := SourceStamp(Book, Source);
  if FileExists(Result) and FileExists(StampFile) then
    try
      if TFile.ReadAllText(StampFile, TEncoding.UTF8) = Stamp then Exit;
    except
      // An incomplete stamp is a cache miss, never a reason to use stale bytes.
    end;

  Stream := nil;
  Temporary := Result + '.pending-' + IntToStr(GetCurrentProcessId) + Book.FileExt;
  TemporaryStamp := StampFile + '.pending-' + IntToStr(GetCurrentProcessId);
  try
    Stream := Book.GetBookStream;
    // Ordinary FB2 keeps its original path and external reader history.
    if (Format = bfFb2) and (Stream is TFileStream) then Exit(Source);
    if not Assigned(Stream) then raise Exception.Create('Не удалось подготовить книгу для чтения.');
    Target := TFileStream.Create(Temporary, fmCreate);
    try Target.CopyFrom(Stream, 0); finally Target.Free; end;
    TFile.WriteAllText(TemporaryStamp, Stamp, TEncoding.UTF8);
    PublishFile(Temporary, Result);
    PublishFile(TemporaryStamp, StampFile);
  finally
    Stream.Free;
    if FileExists(Temporary) then System.SysUtils.DeleteFile(Temporary);
    if FileExists(TemporaryStamp) then System.SysUtils.DeleteFile(TemporaryStamp);
  end;
end;

end.
