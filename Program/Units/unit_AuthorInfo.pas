unit unit_AuthorInfo;

interface

uses System.Classes, System.SysUtils;

type
  TAuthorInformation = record
    HTML, PhotoArchive, Hash, SourceFile: string;
    Found: Boolean;
  end;

function AuthorNameHash(const Name: string): string;
function FindAuthorInfoFolder(const Root, Configured: string): string;
function ReadAuthorInformation(const Folder, Name: string;
  const Canceled: TFunc<Boolean> = nil): TAuthorInformation;
function AuthorPhotographs(const ArchiveFile, Hash: string): TStream;

implementation

uses System.IOUtils, System.Hash, System.Character, System.Zip,
  unit_MHLArchiveHelpers;

const MaxText = 2 * 1024 * 1024;
  MaxPhoto = 16 * 1024 * 1024;
  MaxPhotos = 64 * 1024 * 1024;

type
  TAuthorLimitedStream = class(TMemoryStream)
  private
    FLimit: Int64;
  public
    constructor Create(Limit: Int64);
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

constructor TAuthorLimitedStream.Create(Limit: Int64);
begin inherited Create; FLimit := Limit; end;

function TAuthorLimitedStream.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count < 0) or (Position + Count > FLimit) then
    raise EStreamError.Create('Слишком большой файл дополнительных сведений.');
  Result := inherited Write(Buffer, Count);
end;

function AuthorNameHash(const Name: string): string;
var Text: TStringBuilder; C: Char; Space: Boolean;
begin
  Text := TStringBuilder.Create;
  try
    Space := False;
    for C in Name do
      if C.IsWhiteSpace then Space := Text.Length > 0
      else
      begin
        if Space then Text.Append(' ');
        Text.Append(C); Space := False;
      end;
    Result := THashMD5.GetHashString(TCharacter.ToLower(Text.ToString));
  finally Text.Free; end;
end;

function FindAuthorInfoFolder(const Root, Configured: string): string;
var Path: string;
  function IfThenRoot(const Base, Subfolder: string): string;
begin
  Result := ''; if Base <> '' then Result := TPath.Combine(Base, Subfolder);
end;
  function Check(const Folder: string): Boolean;
  begin
    Result := DirectoryExists(Folder) and
      (Length(TDirectory.GetFiles(Folder, '*.7z', TSearchOption.soTopDirectoryOnly)) > 0);
  end;
begin
  Result := '';
  if (Configured <> '') and Check(TPath.Combine(Configured, 'authors')) then
    Exit(TPath.GetFullPath(TPath.Combine(Configured, 'authors')));
  for Path in TArray<string>.Create(Configured,
    IfThenRoot(Root, 'authors'), IfThenRoot(Root, 'additional\authors')) do
    if (Path <> '') and Check(Path) then Exit(TPath.GetFullPath(Path));
end;

function ReadAuthorInformation(const Folder, Name: string;
  const Canceled: TFunc<Boolean>): TAuthorInformation;
var FileName: string; Archive: TMHLZip; Stream: TAuthorLimitedStream; Bytes: TBytes; Matched: Boolean;
begin
  Result := Default(TAuthorInformation); Result.Hash := AuthorNameHash(Name);
  for FileName in TDirectory.GetFiles(Folder, '*.7z', TSearchOption.soTopDirectoryOnly) do
  begin
    if Assigned(Canceled) and Canceled() then Exit;
    Archive := nil; Matched := False;
    try
      try
        Archive := TMHLZip.Create(FileName, True, False, Canceled);
        if not Archive.Find(Result.Hash) then Continue;
        Matched := True;
        if (Archive.LastSize < 0) or (Archive.LastSize > MaxText) then
          raise EStreamError.Create('Описание автора слишком велико.');
        Stream := TAuthorLimitedStream.Create(MaxText);
        try
          Archive.ExtractToStream(Archive.LastIndex, Stream);
          SetLength(Bytes, Stream.Size); Stream.Position := 0;
          if Length(Bytes) > 0 then Stream.ReadBuffer(Bytes[0], Length(Bytes));
          Result.HTML := TEncoding.UTF8.GetString(Bytes);
        finally Stream.Free; end;
        Result.Found := True; Result.SourceFile := FileName;
        Result.PhotoArchive := TPath.Combine(Folder,
          'pictures\' + ChangeFileExt(ExtractFileName(FileName), '.zip'));
        if not FileExists(Result.PhotoArchive) then Result.PhotoArchive := '';
        Exit;
      except
        on E: EAbort do Exit;
        // A broken unrelated pack does not hide another pack with this author.
        on E: Exception do
          if Matched then raise;
      end;
    finally Archive.Free; end;
  end;
end;

function AuthorPhotographs(const ArchiveFile, Hash: string): TStream;
var Archive: TMHLZip; Zip: TZipFile; Stream: TAuthorLimitedStream;
  Name: string; Index, Count: Integer; Bytes: Int64;
begin
  // Build a small in-memory image container for the existing gallery. No path
  // from an archive is ever extracted to the filesystem or fetched from HTML.
  Result := TAuthorLimitedStream.Create(MaxPhotos + 1024 * 1024);
  Archive := nil; Zip := nil;
  try
    try
    Archive := TMHLZip.Create(ArchiveFile, True);
    Zip := TZipFile.Create; Zip.Open(Result, zmWrite); Count := 0; Bytes := 0;
    for Index := 0 to Archive.FileCount - 1 do
    begin
      Name := StringReplace(Archive.FileNames[Index], '\', '/', [rfReplaceAll]);
      if not Name.StartsWith(Hash + '/', True) then Continue;
      if (Archive.FileSizes[Index] <= 0) or (Archive.FileSizes[Index] > MaxPhoto) then Continue;
      if (Count >= 32) or (Bytes + Archive.FileSizes[Index] > MaxPhotos) then Break;
      Stream := TAuthorLimitedStream.Create(MaxPhoto);
      try
        try
          Archive.ExtractToStream(Index, Stream); Stream.Position := 0;
          Zip.Add(Stream, IntToStr(Count) + ExtractFileExt(Name));
          Inc(Bytes, Stream.Size); Inc(Count);
        except
          // Individual corrupt pictures are isolated, like book illustrations.
        end;
      finally Stream.Free; end;
    end;
    Zip.Close; Result.Position := 0;
    finally Zip.Free; Archive.Free; end;
  except Result.Free; Result := nil; raise; end;
end;

end.
