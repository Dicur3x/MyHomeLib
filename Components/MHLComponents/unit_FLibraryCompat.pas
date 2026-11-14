(* ****************************************************************************
  Compatibility with the space-saving FLibrary torrent layout.

  The layout stores book texts in 7z archives and keeps covers/illustrations in
  sibling archives.  This unit reconstructs conventional FB2 and EPUB streams
  and PDFs from HomeLibre's own JPEG XL packing mode before reading or export.
****************************************************************************** *)

unit unit_FLibraryCompat;

interface

uses
  System.Classes, System.SysUtils;

// Returns nil when no reconstruction was needed.  The caller retains ownership
// of Source in every case and owns the returned stream when it is assigned.
function RestoreFLibraryBook(const ContainerFileName, BookEntryName: string;
  const Source: TStream): TStream;

// Read a private candidate without replacing any live image archive. Nil keeps
// normal discovery; an explicit array has covers/images slots and is strict.
function RestoreFLibraryBookWithImageSources(const ContainerFileName, BookEntryName: string;
  const Source: TStream; const ImageSources: TArray<string>): TStream;

// Extracts and decodes only the cover used by the information panel.  Unlike
// RestoreFLibraryBook, this does not touch the book text or its illustrations.
// Encoded covers are limited to 16 MiB; cancellation reaches archive reading
// and the isolated JPEG XL preview decoder.
// The caller owns the returned stream.  Nil means that no cover was found.
function ExtractFLibraryBookCover(const ContainerFileName,
  BookEntryName: string; const IsCanceled: TFunc<Boolean> = nil): TStream;

function FLibraryImageSourceFiles(const ContainerFileName: string): TArray<string>;

implementation

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Winapi.MSXML,
  System.Hash,
  System.IOUtils,
  System.StrUtils,
  System.Zip,
  System.JSON,
  System.NetEncoding,
  System.Variants,
  System.Generics.Collections,
  unit_MHLArchiveHelpers,
  unit_MHLExternalTools;

const
  FLIBRARY_IMAGE_INDEX = 'FLibraryImageIndex.json';
  PACKED_PDF_MAGIC: array[0..7] of AnsiChar = ('H','L','P','D','F','X','L','1');
  PDF_MAGIC: array[0..4] of AnsiChar = ('%','P','D','F','-');
  PACKED_PDF_LIMIT = 128 * 1024 * 1024;
  PDF_JPEG_MIN = 32 * 1024;
  PDF_JPEG_MAX = 16 * 1024 * 1024;
  PDF_JPEG_LIMIT = 256;

type
  TCoverBytesStream = class(TMemoryStream)
  public
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

  TExternalBookImage = record
    Name: string;
    IsCover: Boolean;
    Data: TBytes;
  end;

  TExternalBookImages = TList<TExternalBookImage>;

  // Binary layout shared with pack_collection.py. Integer fields are LE.
  TPackedPdfHeader = packed record
    Magic: array[0..7] of AnsiChar;
    OriginalSize: Cardinal;
    Sha256: array[0..31] of Byte;
    PartCount: Cardinal;
  end;

  TPackedPdfPart = packed record
    LiteralSize, EncodedSize, JpegSize: Cardinal;
  end;

  TTemporaryPdfStream = class(THandleStream)
  public
    destructor Destroy; override;
  end;

function TCoverBytesStream.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count<0) or (Position>16*1024*1024-Int64(Count)) then
    raise EReadError.Create('Отдельная обложка превышает 16 МБ.');
  Result:=inherited Write(Buffer,Count);
end;

destructor TTemporaryPdfStream.Destroy;
begin
  CloseHandle(Handle);
  inherited;
end;

function StreamToBytes(const Stream: TStream): TBytes;
var
  SavedPosition: Int64;
begin
  if Stream.Size > MaxInt then
    raise ERangeError.Create('Файл книги слишком велик.');
  SavedPosition := Stream.Position;
  try
    Stream.Position := 0;
    SetLength(Result, Integer(Stream.Size));
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Position := SavedPosition;
  end;
end;

function BytesToStream(const Bytes: TBytes): TMemoryStream;
begin
  Result := TMemoryStream.Create;
  try
    if Length(Bytes) > 0 then
      Result.WriteBuffer(Bytes[0], Length(Bytes));
    Result.Position := 0;
  except
    Result.Free;
    raise;
  end;
end;

function ArchiveBaseName(const ContainerFileName: string): string;
begin
  Result := ChangeFileExt(ExtractFileName(StringReplace(ContainerFileName,
    '/', PathDelim, [rfReplaceAll])), '');
end;

function BookBaseName(const BookEntryName: string): string;
begin
  Result := ChangeFileExt(ExtractFileName(StringReplace(BookEntryName,
    '/', PathDelim, [rfReplaceAll])), '');
end;

function ArchiveLeafName(const EntryName: string): string;
var
  P: Integer;
begin
  P := LastDelimiter('/\', EntryName);
  if P > 0 then
    Result := Copy(EntryName, P + 1, MaxInt)
  else
    Result := EntryName;
end;

function FindSiblingArchive(const ContainerFileName,
  SubFolder: string): string;
var
  Candidate: string;
  Root: string;
begin
  // INPX and archive members can use either separator. SysUtils' Windows
  // filename helpers recognize only PathDelim, unlike the file-opening APIs.
  Root := ExtractFileDir(StringReplace(ContainerFileName, '/', PathDelim, [rfReplaceAll]));
  Candidate := TPath.Combine(Root, TPath.Combine(SubFolder,
    ArchiveBaseName(ContainerFileName) + ZIP_EXTENSION));
  if FileExists(Candidate) then
    Exit(Candidate);

  Candidate := TPath.Combine(Root, TPath.Combine(SubFolder,
    ArchiveBaseName(ContainerFileName) + SEVENZIP_ARCHIVE_EXTENSION));
  if FileExists(Candidate) then
    Exit(Candidate);
  Result := '';
end;

function FLibraryImageSourceFiles(const ContainerFileName: string): TArray<string>;
begin
  Result := [FindSiblingArchive(ContainerFileName, 'covers'),
    FindSiblingArchive(ContainerFileName, 'images')];
end;

procedure AddImage(const Images: TExternalBookImages; const KnownNames:
  TDictionary<string, Byte>; const Name: string; const IsCover: Boolean;
  const Stream: TStream);
var
  Item: TExternalBookImage;
begin
  if KnownNames.ContainsKey(Name) then
    Exit;
  Item.Name := Name;
  Item.IsCover := IsCover;
  Item.Data := StreamToBytes(Stream);
  if Length(Item.Data) = 0 then
    Exit;
  Images.Add(Item);
  KnownNames.Add(Name, 0);
end;

procedure CollectExternalImages(const ContainerFileName, BookEntryName: string;
  const Images: TExternalBookImages; const ImageSources: TArray<string>);
var
  KnownNames: TDictionary<string, Byte>;

  procedure CollectCover;
  var
    Archive: TMHLZip;
    ArchiveName: string;
    Stream: TMemoryStream;
  begin
    if ImageSources=nil then
      ArchiveName := FindSiblingArchive(ContainerFileName, 'covers')
    else ArchiveName:=ImageSources[0];
    if ArchiveName = '' then
      Exit;
    Archive := nil;
    try
      try
        Archive := TMHLZip.Create(ArchiveName, True);
        Stream := TMemoryStream.Create;
        try
          if Archive.Find(BookBaseName(BookEntryName)) then
          begin
            Archive.ExtractToStream(Archive.LastIndex, Stream);
            AddImage(Images, KnownNames, 'cover', True, Stream);
          end;
        finally
          Stream.Free;
        end;
      except
        // During a torrent download a sparse, incomplete side archive may
        // already be visible.  Text must remain readable without pictures.
        on E: EZipException do
          if ImageSources<>nil then raise;
        on E: EFOpenError do
          if ImageSources<>nil then raise;
        on E: EMHLExternalToolError do
          if ImageSources<>nil then raise;
      end;
    finally
      Archive.Free;
    end;
  end;

  procedure CollectIllustrations;
  var
    Archive: TMHLZip;
    ArchiveName: string;
    EntryName: string;
    Stream: TMemoryStream;
  begin
    if ImageSources=nil then
      ArchiveName := FindSiblingArchive(ContainerFileName, 'images')
    else ArchiveName:=ImageSources[1];
    if ArchiveName = '' then
      Exit;
    Archive := nil;
    try
      try
        Archive := TMHLZip.Create(ArchiveName, True);
        if not Archive.Find(BookBaseName(BookEntryName) + '/*') then
          Exit;
        repeat
          EntryName := ArchiveLeafName(Archive.LastName);
          Stream := TMemoryStream.Create;
          try
            Archive.ExtractToStream(Archive.LastIndex, Stream);
            AddImage(Images, KnownNames, EntryName, False, Stream);
          finally
            Stream.Free;
          end;
        until not Archive.FindNext;
      except
        on E: EZipException do
          if ImageSources<>nil then raise;
        on E: EFOpenError do
          if ImageSources<>nil then raise;
        on E: EMHLExternalToolError do
          if ImageSources<>nil then raise;
      end;
    finally
      Archive.Free;
    end;
  end;

begin
  KnownNames := TDictionary<string, Byte>.Create;
  try
    CollectCover;
    CollectIllustrations;
  finally
    KnownNames.Free;
  end;
end;

function IsJpegXL(const Bytes: TBytes): Boolean;
const
  CONTAINER_SIGNATURE: array [0 .. 11] of Byte =
    ($00, $00, $00, $0C, $4A, $58, $4C, $20, $0D, $0A, $87, $0A);
var
  I: Integer;
begin
  Result := (Length(Bytes) >= 2) and (Bytes[0] = $FF) and (Bytes[1] = $0A);
  if Result or (Length(Bytes) < Length(CONTAINER_SIGNATURE)) then
    Exit;
  Result := True;
  for I := Low(CONTAINER_SIGNATURE) to High(CONTAINER_SIGNATURE) do
    if Bytes[I] <> CONTAINER_SIGNATURE[I] then
      Exit(False);
end;

function IsSevenZipData(const Bytes: TBytes): Boolean;
const
  SIGNATURE: array [0 .. 5] of Byte = ($37, $7A, $BC, $AF, $27, $1C);
var
  I: Integer;
begin
  if Length(Bytes) < Length(SIGNATURE) then
    Exit(False);
  for I := Low(SIGNATURE) to High(SIGNATURE) do
    if Bytes[I] <> SIGNATURE[I] then
      Exit(False);
  Result := True;
end;

function NewTemporaryFileName(const Extension: string): string;
var
  Id: TGUID;
begin
  CreateGUID(Id);
  Result := TPath.Combine(TPath.GetTempPath,
    'mhl-' + StringReplace(StringReplace(GUIDToString(Id), '{', '', []),
      '}', '', []) + Extension);
end;

function NormalizeArchiveName(const Value: string): string; forward;

function NewTemporaryDirectory: string;
var
  Id: TGUID;
begin
  CreateGUID(Id);
  Result := TPath.Combine(TPath.GetTempPath,
    'mhl-' + StringReplace(StringReplace(GUIDToString(Id), '{', '', []),
      '}', '', []));
end;

function ExtractedEntryFileName(const ExtractedRoot,
  EntryName: string): string;
var
  FullRoot: string;
  RelativeName: string;
begin
  FullRoot := IncludeTrailingPathDelimiter(TPath.GetFullPath(ExtractedRoot));
  RelativeName := StringReplace(NormalizeArchiveName(EntryName), '/',
    PathDelim, [rfReplaceAll]);
  Result := TPath.GetFullPath(TPath.Combine(FullRoot, RelativeName));
  if not StartsText(FullRoot, Result) then
    raise EZipException.CreateFmt('Недопустимый путь внутри EPUB: "%s".',
      [EntryName]);
end;

procedure ExtractArchiveEntry(const Archive: TMHLZip; const Index: Integer;
  const ExtractedRoot: string; const Destination: TStream);
var
  Source: TFileStream;
  SourceFileName: string;
begin
  if ExtractedRoot = '' then
  begin
    Archive.ExtractToStream(Index, Destination);
    Exit;
  end;

  SourceFileName := ExtractedEntryFileName(ExtractedRoot,
    Archive.FileNameAt(Index));
  Source := TFileStream.Create(SourceFileName, fmOpenRead or fmShareDenyWrite);
  try
    Destination.Position := 0;
    Destination.Size := 0;
    Destination.CopyFrom(Source, 0);
    Destination.Position := 0;
  finally
    Source.Free;
  end;
end;

function HasJpegReconstruction(const Bytes: TBytes): Boolean;
var
  Offset, Header, Remaining: Integer;
  Size: UInt64;

  function BigEndian(Start, Count: Integer): UInt64;
  begin
    Result := 0;
    for var I := Start to Start + Count - 1 do
      Result := (Result shl 8) or Bytes[I];
  end;
begin
  Result := False;
  // The raw JPEG XL codestream has no container boxes. The caller already
  // checked the signature; a container starts with the 12-byte signature box.
  if (Length(Bytes) < 12) or (Bytes[0] <> 0) then Exit;
  Offset := 12;
  Remaining := Length(Bytes) - Offset;
  while Remaining >= 8 do
  begin
    Header := 8;
    Size := BigEndian(Offset, 4);
    if Size = 1 then
    begin
      Header := 16;
      if Remaining < Header then Exit;
      Size := BigEndian(Offset + 8, 8);
    end
    else if Size = 0 then Size := UInt64(Remaining);
    if (Size < UInt64(Header)) or (Size > UInt64(Remaining)) then Exit;
    if BigEndian(Offset + 4, 4) = $6A627264 then // jbrd
      Exit(Size > UInt64(Header));
    Inc(Offset, Integer(Size));
    Dec(Remaining, Integer(Size));
  end;
end;

procedure CheckJpegXLPreview(const IsCanceled:TFunc<Boolean>; Preview:Boolean;
  Started:UInt64; const OutputFile,JpegFile:string);
var Attributes:TWin32FileAttributeData;
begin
    if Assigned(IsCanceled) and IsCanceled() then Abort;
    if not Preview then Exit;
    if GetTickCount64-Started>15000 then raise EReadError.Create('Предпросмотр обложки JPEG XL занял больше 15 секунд.');
    for var Name in TArray<string>.Create(OutputFile,JpegFile) do
      if GetFileAttributesEx(PChar(Name),GetFileExInfoStandard,@Attributes) and
        ((Attributes.nFileSizeHigh<>0) or (Attributes.nFileSizeLow>128*1024*1024)) then
        raise EReadError.Create('Декодированная обложка JPEG XL слишком велика.');
end;

function ConvertJpegXL(const Bytes: TBytes; const IsCanceled:TFunc<Boolean> = nil;
  Preview:Boolean = False): TBytes;
var
  Decoder,InputFile,OutputFile,JpegFile: string;
  Sink: TMemoryStream;
  Started:UInt64;
  procedure Decode(const Destination:string; Reconstruct:Boolean);
  var Arguments:TArray<string>;
  begin
    Arguments:=[InputFile,Destination];
    if Reconstruct then Arguments:=Arguments+['--reconstruct_jpeg'];
    if Preview then Arguments:=Arguments+['--num_threads=1'];
    Started:=GetTickCount64;
    CheckJpegXLPreview(IsCanceled,Preview,Started,OutputFile,JpegFile);
    // Only covers opt into one CPU thread and bounded time, output and memory.
    // Full-book reconstruction keeps its existing decoder behaviour.
    if Preview then
      RunExternalToolToStream(Decoder,Arguments,Sink,function:Boolean
        begin CheckJpegXLPreview(IsCanceled,Preview,Started,OutputFile,JpegFile); Result:=False; end,
        0,True,NativeUInt(512)*1024*1024)
    else RunExternalToolToStream(Decoder,Arguments,Sink,IsCanceled);
    CheckJpegXLPreview(IsCanceled,Preview,Started,OutputFile,JpegFile);
  end;
begin
  Decoder := FindExternalTool('djxl.exe', 'jpeg-xl');
  if Decoder = '' then
    raise EMHLComponentRequired.Create('JPEG XL',
        'Для иллюстраций этой книги нужен декодер JPEG XL. Его можно скачать в окне обновлений HomeLibre.');

  // Reconstruct the original JPEG bitstream only when the container carries
  // its recovery data. The general PNG path preserves alpha and also works
  // with older decoders that do not recognize --reconstruct_jpeg.
  InputFile := NewTemporaryFileName('.jxl');
  OutputFile := NewTemporaryFileName('.png');
  JpegFile := ChangeFileExt(OutputFile, '.jpg');
  try
    TFile.WriteAllBytes(InputFile, Bytes);
    Sink := TMemoryStream.Create;
    try
      if HasJpegReconstruction(Bytes) then
      begin
        try
          Decode(JpegFile,True);
          if FileExists(JpegFile) then
          begin
            Result := TFile.ReadAllBytes(JpegFile);
            if (Length(Result) >= 3) and (Result[0] = $FF) and (Result[1] = $D8) and
              (Result[2] = $FF) then Exit;
          end;
        except
          on E: EMHLExternalToolError do ;
        end;
      end;
      Decode(OutputFile,False);
    finally
      Sink.Free;
    end;
    if not FileExists(OutputFile) then
      raise EMHLExternalToolError.Create(
        'Декодер JPEG XL не создал изображение.');
    Result := TFile.ReadAllBytes(OutputFile);
  finally
    if FileExists(InputFile) then
      System.SysUtils.DeleteFile(InputFile);
    if FileExists(OutputFile) then
      System.SysUtils.DeleteFile(OutputFile);
    if FileExists(JpegFile) then
      System.SysUtils.DeleteFile(JpegFile);
  end;
end;

function ImageMediaType(const Bytes: TBytes): string; forward;

function RestorePackedPdf(const Source: TStream): TStream;
var
  Header: TPackedPdfHeader;
  Part: TPackedPdfPart;
  Output: TTemporaryPdfStream;
  OutputHandle: THandle;
  Chunk: TFileStream;
  Sink: TMemoryStream;
  SavedPosition, TailSize: Int64;
  Started: UInt64;
  Decoder, EncodedFile, JpegFile: string;
  Digest: TBytes;
  Signature: array[0..4] of AnsiChar;
begin
  Result := nil;
  SavedPosition := Source.Position;
  Output := nil;
  try
    Source.Position := 0;
    if (Source.Read(Header.Magic, SizeOf(Header.Magic)) <> SizeOf(Header.Magic)) or
      not CompareMem(@Header.Magic[0], @PACKED_PDF_MAGIC[0], SizeOf(Header.Magic)) then Exit;
    Source.Position := 0;
    Source.ReadBuffer(Header, SizeOf(Header));
    if (Header.OriginalSize > PACKED_PDF_LIMIT) or (Header.OriginalSize <= Source.Size) or
      (Header.PartCount = 0) or (Header.PartCount > PDF_JPEG_LIMIT) then
      raise EZipException.Create('Некорректный заголовок сжатого PDF.');

    Decoder := FindExternalTool('djxl.exe', 'jpeg-xl');
    if Decoder = '' then
      raise EMHLComponentRequired.Create('JPEG XL', 'Для восстановления исходного PDF нужен декодер JPEG XL.');

    OutputHandle := CreateFile(PChar(NewTemporaryFileName('.pdf')), GENERIC_READ or GENERIC_WRITE,
      0, nil, CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE, 0);
    if OutputHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    try
      Output := TTemporaryPdfStream.Create(OutputHandle);
    except
      CloseHandle(OutputHandle);
      raise;
    end;
    EncodedFile := NewTemporaryFileName('.jxl');
    JpegFile := ChangeFileExt(EncodedFile, '.jpg');
    for var Index := 1 to Header.PartCount do
    begin
      Source.ReadBuffer(Part, SizeOf(Part));
      if (Part.JpegSize < PDF_JPEG_MIN) or (Part.JpegSize > PDF_JPEG_MAX) or
        (Part.EncodedSize = 0) or (Part.EncodedSize >= Part.JpegSize) or
        (Int64(Part.LiteralSize) + Part.EncodedSize > Source.Size - Source.Position) or
        (Int64(Part.LiteralSize) + Part.JpegSize > Header.OriginalSize - Output.Position) then
        raise EZipException.Create('Некорректный блок изображения в сжатом PDF.');
      if Part.LiteralSize > 0 then Output.CopyFrom(Source, Part.LiteralSize);
      try
        Chunk := TFileStream.Create(EncodedFile, fmCreate);
        try Chunk.CopyFrom(Source, Part.EncodedSize); finally Chunk.Free; end;
        Sink := TMemoryStream.Create;
        try
          Started := GetTickCount64;
          RunExternalToolToStream(Decoder, [EncodedFile, JpegFile, '--reconstruct_jpeg', '--num_threads=1'],
            Sink, function: Boolean
              var Attributes: TWin32FileAttributeData;
              begin
                Result := (GetTickCount64 - Started > 60000) or
                  (GetFileAttributesEx(PChar(JpegFile), GetFileExInfoStandard, @Attributes) and
                    ((Attributes.nFileSizeHigh <> 0) or (Attributes.nFileSizeLow > Part.JpegSize)));
              end,
            0, True, NativeUInt(512) * 1024 * 1024);
        finally Sink.Free; end;
        Chunk := TFileStream.Create(JpegFile, fmOpenRead or fmShareDenyWrite);
        try
          if Chunk.Size <> Part.JpegSize then
            raise EZipException.Create('Размер восстановленного JPEG внутри PDF не совпал.');
          Output.CopyFrom(Chunk, Part.JpegSize);
        finally Chunk.Free; end;
      finally
        System.SysUtils.DeleteFile(EncodedFile);
        System.SysUtils.DeleteFile(JpegFile);
      end;
    end;
    TailSize := Source.Size - Source.Position;
    if TailSize <> Header.OriginalSize - Output.Position then
      raise EZipException.Create('Размер восстановленного PDF не совпал.');
    if TailSize > 0 then Output.CopyFrom(Source, TailSize);
    Output.Position := 0;
    Output.ReadBuffer(Signature, SizeOf(Signature));
    if not CompareMem(@Signature[0], @PDF_MAGIC[0], SizeOf(Signature)) then
      raise EZipException.Create('Восстановленный файл не содержит заголовка PDF.');
    Output.Position := 0;
    Digest := THashSHA2.GetHashBytes(Output);
    if not CompareMem(@Digest[0], @Header.Sha256[0], SizeOf(Header.Sha256)) then
      raise EZipException.Create('Контрольная сумма восстановленного PDF не совпала.');
    Output.Position := 0;
    Result := Output;
    Output := nil;
  finally
    Output.Free;
    Source.Position := SavedPosition;
  end;
end;

function TryExtractExternalImage(const ArchiveFileName,
  EntryName: string; out Bytes: TBytes; const IsCanceled:TFunc<Boolean>): Boolean;
var
  Archive: TMHLZip;
  I: Integer;
  Stream: TMemoryStream;
  WantedName: string;
begin
  Result := False;
  SetLength(Bytes, 0);
  if ArchiveFileName = '' then
    Exit;

  Archive := nil;
  Stream := nil;
  try
    try
      Archive := TMHLZip.Create(ArchiveFileName, True, False, IsCanceled);
      WantedName := NormalizeArchiveName(EntryName);
      for I := 0 to Archive.FileCount - 1 do
      begin
        if (I mod 256=0) and Assigned(IsCanceled) and IsCanceled() then Abort;
        if SameText(NormalizeArchiveName(Archive.FileNameAt(I)), WantedName) then
        begin
          if (Archive.FileSizes[I]<0) or (Archive.FileSizes[I]>16*1024*1024) then
            raise EReadError.Create('Отдельная обложка превышает 16 МБ.');
          Stream := TCoverBytesStream.Create;
          Archive.ExtractToStream(I, Stream);
          Bytes := StreamToBytes(Stream);
          Exit(Length(Bytes) > 0);
        end;
      end;
    except
      // Partially downloaded torrents can expose an incomplete side archive.
      // A missing preview must not prevent the book list from being used.
      on E: EZipException do
        ;
      on E: EFOpenError do
        ;
      on E: EMHLExternalToolError do
        ;
    end;
  finally
    Stream.Free;
    Archive.Free;
  end;
end;

function ExtractFLibraryBookCover(const ContainerFileName,
  BookEntryName: string; const IsCanceled:TFunc<Boolean>): TStream;
var
  ArchiveName: string;
  Bytes: TBytes;
begin
  Result := nil;
  if Assigned(IsCanceled) and IsCanceled() then Abort;
  if not IsSevenZipArchive(ContainerFileName) then
    Exit;

  // FB2 covers are normally stored in covers\<archive>.zip under the book's
  // base name.  Prefer this explicit cover for every supported book format.
  ArchiveName := FindSiblingArchive(ContainerFileName, 'covers');
  if not TryExtractExternalImage(ArchiveName, BookBaseName(BookEntryName), Bytes, IsCanceled) then
  begin
    // FLibrary moves an EPUB cover to image number zero before generating its
    // image index.  Reading this one side-archive member avoids unpacking and
    // rebuilding the complete nested EPUB merely to paint a thumbnail.
    if not SameText(ExtractFileExt(BookEntryName), '.epub') then
      Exit;
    ArchiveName := FindSiblingArchive(ContainerFileName, 'images');
    if not TryExtractExternalImage(ArchiveName,
      BookBaseName(BookEntryName) + '/0', Bytes, IsCanceled) then
      Exit;
  end;

  if IsJpegXL(Bytes) then
    Bytes := ConvertJpegXL(Bytes,IsCanceled,True);
  if ImageMediaType(Bytes) = 'application/octet-stream' then
    Exit;
  Result := BytesToStream(Bytes);
end;

function ImageMediaType(const Bytes: TBytes): string;
begin
  if (Length(Bytes) >= 3) and (Bytes[0] = $FF) and (Bytes[1] = $D8) and
    (Bytes[2] = $FF) then
    Exit('image/jpeg');
  if (Length(Bytes) >= 8) and (Bytes[0] = $89) and (Bytes[1] = $50) and
    (Bytes[2] = $4E) and (Bytes[3] = $47) then
    Exit('image/png');
  if (Length(Bytes) >= 6) and (Bytes[0] = Ord('G')) and
    (Bytes[1] = Ord('I')) and (Bytes[2] = Ord('F')) then
    Exit('image/gif');
  Result := 'application/octet-stream';
end;

procedure MakeImagesReaderCompatible(Images: TExternalBookImages);
var
  I: Integer;
  Item: TExternalBookImage;
begin
  for I := 0 to Images.Count - 1 do
    if IsJpegXL(Images[I].Data) then
    begin
      Item := Images[I];
      Item.Data := ConvertJpegXL(Item.Data);
      Images[I] := Item;
    end;
end;

function FindClosingFictionBook(const Bytes: TBytes): Integer;
var I,J,NameEnd:Integer; Name:string; Marker:AnsiString;
  function EndsAt(const Token:AnsiString; At:Integer):Boolean;
  begin
    Result:=False;
    if At<Length(Token)-1 then Exit;
    for var N:=1 to Length(Token) do
      if Bytes[At-Length(Token)+N]<>Ord(Token[N]) then Exit;
    Result:=True;
  end;
begin
  Result:=-1; I:=Length(Bytes)-1;
  // Inspect the actual final closing tag, allowing trailing XML comments/PIs.
  // A literal closing tag inside a comment must not receive the illustrations.
  while I>=0 do
  begin
    while (I>=0) and (Bytes[I] in [9,10,13,32]) do Dec(I);
    if EndsAt('-->',I) then Marker:='<!--'
    else if EndsAt('?>',I) then Marker:='<?'
    else Break;
    J:=I-Length(Marker)+1;
    while (J>=0) and not EndsAt(Marker,J) do Dec(J);
    if J<0 then Exit;
    I:=J-Length(Marker);
  end;
  if (I<0) or (Bytes[I]<>Ord('>')) then Exit;
  J:=I-1;
  while (J>=0) and (Bytes[J] in [9,10,13,32]) do Dec(J);
  NameEnd:=J;
  while (J>=0) and not (Bytes[J] in [9,10,13,32,Ord('<'),Ord('>'),Ord('/')]) do Dec(J);
  if (J<1) or (NameEnd<=J) or (Bytes[J]<>Ord('/')) or (Bytes[J-1]<>Ord('<')) then Exit;
  Name:=TEncoding.UTF8.GetString(Bytes,J+1,NameEnd-J);
  Name:=Copy(Name,LastDelimiter(':',Name)+1,MaxInt);
  if SameText(Name,'FictionBook') then Result:=J-1;
end;

function XmlEscapeAttribute(const Value: string): string;
begin
  Result := StringReplace(Value, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

function RestoreFb2(const Source: TStream;
  const Images: TExternalBookImages): TStream;
var
  Bytes: TBytes;
  ClosingPosition: Integer;
  ExistingText: string;
  I: Integer;
  InsertBytes: TBytes;
  InsertText: TStringBuilder;
  Output: TMemoryStream;
begin
  Result := nil;
  if Images.Count = 0 then
    Exit;
  MakeImagesReaderCompatible(Images);
  Bytes := StreamToBytes(Source);
  ClosingPosition := FindClosingFictionBook(Bytes);
  if ClosingPosition < 0 then
    Exit;

  // IDs in this layout are ASCII (cover, 0, 1, ...).  Decoding as ANSI is
  // sufficient for duplicate detection even when the FB2 itself is cp1251.
  ExistingText := TEncoding.ANSI.GetString(Bytes);
  InsertText := TStringBuilder.Create;
  try
    for I := 0 to Images.Count - 1 do
    begin
      if Pos('id="' + Images[I].Name + '"', ExistingText) > 0 then
        Continue;
      InsertText.Append('<binary xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" id="');
      InsertText.Append(XmlEscapeAttribute(Images[I].Name));
      InsertText.Append('" content-type="');
      InsertText.Append(ImageMediaType(Images[I].Data));
      InsertText.Append('">');
      InsertText.Append(TNetEncoding.Base64.EncodeBytesToString(
        Images[I].Data));
      InsertText.Append('</binary>');
    end;
    if InsertText.Length = 0 then
      Exit;
    InsertBytes := TEncoding.ASCII.GetBytes(InsertText.ToString);
  finally
    InsertText.Free;
  end;

  Output := TMemoryStream.Create;
  try
    if ClosingPosition > 0 then
      Output.WriteBuffer(Bytes[0], ClosingPosition);
    if Length(InsertBytes) > 0 then
      Output.WriteBuffer(InsertBytes[0], Length(InsertBytes));
    Output.WriteBuffer(Bytes[ClosingPosition], Length(Bytes) - ClosingPosition);
    Output.Position := 0;
    Result := Output;
  except
    Output.Free;
    raise;
  end;
end;

function NormalizeArchiveName(const Value: string): string;
begin
  Result := StringReplace(Value, '\', '/', [rfReplaceAll]);
end;

function OpfResourcePath(const PackageName, Href: string): string;
var Path: string; Parts: TList<string>; EndOfPath: Integer;
begin
  Result := '';
  EndOfPath := Href.IndexOfAny(['?', '#']);
  Path := Href;
  if EndOfPath >= 0 then Path := Copy(Path, 1, EndOfPath);
  try
    Path := NormalizeArchiveName(TNetEncoding.URL.Decode(Path.Replace('+', '%2B')));
  except
    on E: EConvertError do Exit;
  end;
  if (Path = '') or Path.Contains(':') or Path.StartsWith('//') then Exit;
  if Path.StartsWith('/') then Path := Path.Substring(1)
  else Path := Copy(PackageName, 1, LastDelimiter('/', PackageName)) + Path;
  Parts := TList<string>.Create;
  try
    for var Part in Path.Split(['/']) do
      if (Part = '') or (Part = '.') then Continue
      else if Part = '..' then
      begin
        if Parts.Count = 0 then Exit;
        Parts.Delete(Parts.Count - 1);
      end
      else Parts.Add(Part);
    Result := string.Join('/', Parts.ToArray);
  finally Parts.Free; end;
end;

function NormalizeOpfImageReferences(const Bytes: TBytes; const PackageName: string;
  const TargetImages: TDictionary<string, TExternalBookImage>): TBytes;
var
  Text, Original, MediaType: string;
  Document: IXMLDOMDocument3;
  Items: IXMLDOMNodeList;
  Item: IXMLDOMElement;
  Image: TExternalBookImage;
  Input, Output: TMemoryStream;
  Adapter: OleVariant;
  ComStatus: HRESULT;
  Changed: Boolean;
begin
  Result := Bytes;
  if TargetImages.Count = 0 then Exit;
  // ZIP entry names are case-sensitive.  Real-world EPUB files sometimes
  // disagree only by case between the OPF guide and its manifest (Images vs
  // images).  Desktop readers may forgive that, while e-readers commonly do
  // not.  The FLibrary image index supplies the canonical entry names, so use
  // those names everywhere in the OPF while rebuilding the archive.
  Original := TEncoding.UTF8.GetString(Bytes);
  Text := Original;
  for var ImageName in TargetImages.Keys do
    Text := StringReplace(Text, ImageName, ImageName,
      [rfReplaceAll, rfIgnoreCase]);
  if Text <> Original then Result := TEncoding.UTF8.GetBytes(Text);

  // Raw JPEG XL can restore to PNG even when the original EPUB used a JPEG
  // filename. Keep existing links and describe the bytes actually restored.
  ComStatus := CoInitializeEx(nil, COINIT_MULTITHREADED);
  if Failed(ComStatus) and (ComStatus <> RPC_E_CHANGED_MODE) then Exit;
  Input := nil;
  Output := nil;
  try
    Input := BytesToStream(Result);
    Document := CoDOMDocument60.Create;
    Document.async := False;
    Document.resolveExternals := False;
    Document.validateOnParse := False;
    Document.preserveWhiteSpace := True;
    Document.setProperty('ProhibitDTD', True);
    Document.setProperty('MaxXMLSize', 2048);
    Document.setProperty('MaxElementDepth', 128);
    Adapter := TStreamAdapter.Create(Input, soReference) as IStream;
    if not Document.load(Adapter) then Exit;
    Adapter := Unassigned;
    Items := Document.selectNodes('/*[local-name()="package"]/*[local-name()="manifest"]/*[local-name()="item"]');
    Changed := False;
    for var I := 0 to Items.length - 1 do
    begin
      Item := Items.item[I] as IXMLDOMElement;
      if not TargetImages.TryGetValue(OpfResourcePath(PackageName, VarToStr(Item.getAttribute('href'))), Image) then Continue;
      MediaType := ImageMediaType(Image.Data);
      if (MediaType <> 'application/octet-stream') and (MediaType <> VarToStr(Item.getAttribute('media-type'))) then
      begin
        Item.setAttribute('media-type', MediaType);
        Changed := True;
      end;
    end;
    if not Changed then Exit;
    Output := TMemoryStream.Create;
    Adapter := TStreamAdapter.Create(Output, soReference) as IStream;
    Document.save(Adapter);
    Result := StreamToBytes(Output);
  finally
    Adapter := Unassigned;
    Item := nil;
    Items := nil;
    Document := nil;
    Output.Free;
    Input.Free;
    if Succeeded(ComStatus) then CoUninitialize;
  end;
end;

function CommonTopFolder(const Names: TArray<string>): string;
var
  I: Integer;
  P: Integer;
  Top: string;
begin
  Result := '';
  for I := Low(Names) to High(Names) do
  begin
    if EndsText(FLIBRARY_IMAGE_INDEX, Names[I]) then
      Continue;
    P := Pos('/', NormalizeArchiveName(Names[I]));
    if P <= 1 then
      Exit('');
    if Top = '' then
      Top := Copy(NormalizeArchiveName(Names[I]), 1, P)
    else if not StartsText(Top, NormalizeArchiveName(Names[I])) then
      Exit('');
  end;
  Result := Top;
end;

function LoadEpubImageIndex(const Archive: TMHLZip;
  const Names: TArray<string>; const ExtractedRoot: string; const ImageTargets:
  TObjectDictionary<Integer, TList<string>>): Boolean;
var
  ArrayValue: TJSONArray;
  Bytes: TBytes;
  I: Integer;
  Item: TJSONValue;
  Json: TJSONValue;
  NameValue: TJSONValue;
  NumberValue: TJSONValue;
  Obj: TJSONObject;
  Stream: TMemoryStream;
  Number: Integer;
  Targets: TList<string>;
begin
  Result := False;
  for I := Low(Names) to High(Names) do
  begin
    if not EndsText(FLIBRARY_IMAGE_INDEX, Names[I]) then
      Continue;
    Stream := TMemoryStream.Create;
    try
      ExtractArchiveEntry(Archive, I, ExtractedRoot, Stream);
      Bytes := StreamToBytes(Stream);
    finally
      Stream.Free;
    end;
    Json := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
    try
      if not (Json is TJSONArray) then
        Exit(False);
      ArrayValue := TJSONArray(Json);
      for Item in ArrayValue do
      begin
        if not (Item is TJSONObject) then
          Continue;
        Obj := TJSONObject(Item);
        NameValue := Obj.GetValue('id');
        NumberValue := Obj.GetValue('num');
        if Assigned(NameValue) and Assigned(NumberValue) then
        begin
          Number := StrToIntDef(NumberValue.Value, 0);
          if not ImageTargets.TryGetValue(Number, Targets) then
          begin
            Targets := TList<string>.Create;
            ImageTargets.Add(Number, Targets);
          end;
          // A single stored illustration can appear under multiple EPUB paths.
          Targets.Add(NormalizeArchiveName(NameValue.Value));
        end;
      end;
      Result := ImageTargets.Count > 0;
    finally
      Json.Free;
    end;
    Exit;
  end;
end;

function RestoreEpub(const Source: TStream;
  const Images: TExternalBookImages): TStream;
var
  AddedNames: TDictionary<string, Byte>;
  Archive: TMHLZip;
  Bytes: TBytes;
  CommonFolder: string;
  ExtractedRoot: string;
  I: Integer;
  ImageNo: Integer;
  ImageTargets: TObjectDictionary<Integer, TList<string>>;
  Targets: TList<string>;
  InputFile: string;
  MimetypeIndex: Integer;
  Names: TArray<string>;
  Output: TMemoryStream;
  OutputFile: string;
  OutputName: string;
  Stream: TMemoryStream;
  TargetImages: TDictionary<string, TExternalBookImage>;
  Zip: TZipFile;
  SourceIsSevenZip, BatchExtract: Boolean;
begin
  Result := nil;

  Bytes := StreamToBytes(Source);
  // FLibrary stores the contents of some EPUB books as a nested 7z stream
  // while deliberately keeping the .epub entry name in the outer archive.
  // Select the reader from the actual signature, not from that logical name.
  SourceIsSevenZip := IsSevenZipData(Bytes);
  if SourceIsSevenZip then
    InputFile := NewTemporaryFileName(SEVENZIP_ARCHIVE_EXTENSION)
  else
    InputFile := NewTemporaryFileName('.epub');
  OutputFile := NewTemporaryFileName('.epub');
  ExtractedRoot := '';
  Archive := nil;
  Zip := nil;
  ImageTargets := TObjectDictionary<Integer, TList<string>>.Create([doOwnsValues]);
  TargetImages := TDictionary<string, TExternalBookImage>.Create;
  AddedNames := TDictionary<string, Byte>.Create;
  try
    TFile.WriteAllBytes(InputFile, Bytes);
    Archive := TMHLZip.Create(InputFile, True);
    SetLength(Names, Archive.FileCount);
    BatchExtract := SourceIsSevenZip;
    for I := 0 to Archive.FileCount - 1 do
    begin
      Names[I] := NormalizeArchiveName(Archive.FileNameAt(I));
      // On Windows 7-Zip replaces trailing dots and spaces with underscores
      // on disk. Read those archives by their original member names instead.
      if BatchExtract and (Names[I].Contains('./') or Names[I].Contains(' /') or
        Names[I].EndsWith('.') or Names[I].EndsWith(' ')) then BatchExtract := False;
    end;
    if BatchExtract then
    begin
      ExtractedRoot := NewTemporaryDirectory;
      Archive.ExtractAllToDirectory(ExtractedRoot);
    end;
    LoadEpubImageIndex(Archive, Names, ExtractedRoot, ImageTargets);

    MakeImagesReaderCompatible(Images);
    for I := 0 to Images.Count - 1 do
    begin
      if Images[I].IsCover then
        ImageNo := -1
      else
        ImageNo := StrToIntDef(Images[I].Name, MaxInt);
      if ImageTargets.TryGetValue(ImageNo, Targets) then
        for OutputName in Targets do
          TargetImages.AddOrSetValue(OutputName, Images[I]);
    end;

    CommonFolder := CommonTopFolder(Names);
    Zip := TZipFile.Create;
    Zip.Open(OutputFile, zmWrite);

    // EPUB requires mimetype to be the first, uncompressed entry.
    MimetypeIndex := -1;
    for I := 0 to High(Names) do
    begin
      OutputName := Names[I];
      if (CommonFolder <> '') and StartsText(CommonFolder, OutputName) then
        Delete(OutputName, 1, Length(CommonFolder));
      if SameText(OutputName, 'mimetype') then
      begin
        MimetypeIndex := I;
        Break;
      end;
    end;
    if MimetypeIndex >= 0 then
    begin
      Stream := TMemoryStream.Create;
      try
        ExtractArchiveEntry(Archive, MimetypeIndex, ExtractedRoot, Stream);
        Zip.Add(Stream, 'mimetype', zcStored);
        AddedNames.Add('mimetype', 0);
      finally
        Stream.Free;
      end;
    end
    else
    begin
      // A damaged producer occasionally omits this tiny mandatory entry.  The
      // reconstructed file can still be made into a standards-compliant EPUB.
      Stream := BytesToStream(TEncoding.ASCII.GetBytes('application/epub+zip'));
      try
        Zip.Add(Stream, 'mimetype', zcStored);
        AddedNames.Add('mimetype', 0);
      finally
        Stream.Free;
      end;
    end;

    for I := 0 to High(Names) do
    begin
      if EndsText(FLIBRARY_IMAGE_INDEX, Names[I]) then
        Continue;
      OutputName := Names[I];
      if (CommonFolder <> '') and StartsText(CommonFolder, OutputName) then
        Delete(OutputName, 1, Length(CommonFolder));
      if (OutputName = '') or EndsText('/', OutputName) or
        AddedNames.ContainsKey(OutputName) or TargetImages.ContainsKey(OutputName) then
        Continue;
      Stream := TMemoryStream.Create;
      try
        ExtractArchiveEntry(Archive, I, ExtractedRoot, Stream);
        if SameText(ExtractFileExt(OutputName), '.opf') then
        begin
          Bytes := NormalizeOpfImageReferences(StreamToBytes(Stream),
            OutputName, TargetImages);
          Stream.Size := 0;
          if Length(Bytes) > 0 then
            Stream.WriteBuffer(Bytes[0], Length(Bytes));
          Stream.Position := 0;
        end;
        Zip.Add(Stream, OutputName, zcDeflate);
        AddedNames.Add(OutputName, 0);
      finally
        Stream.Free;
      end;
    end;

    for OutputName in TargetImages.Keys do
    begin
      Bytes := TargetImages[OutputName].Data;
      Stream := BytesToStream(Bytes);
      try
        // JPEG/PNG/GIF are already compressed. Deflating them again only
        // delays opening/exporting and usually does not reduce the EPUB.
        Zip.Add(Stream, OutputName, zcStored);
      finally
        Stream.Free;
      end;
    end;
    FreeAndNil(Zip); // writes the central directory

    Output := TMemoryStream.Create;
    try
      Bytes := TFile.ReadAllBytes(OutputFile);
      if Length(Bytes) > 0 then
        Output.WriteBuffer(Bytes[0], Length(Bytes));
      Output.Position := 0;
      Result := Output;
    except
      Output.Free;
      raise;
    end;
  finally
    AddedNames.Free;
    TargetImages.Free;
    ImageTargets.Free;
    Zip.Free;
    Archive.Free;
    if FileExists(InputFile) then
      System.SysUtils.DeleteFile(InputFile);
    if FileExists(OutputFile) then
      System.SysUtils.DeleteFile(OutputFile);
    if (ExtractedRoot <> '') and TDirectory.Exists(ExtractedRoot) then
      TDirectory.Delete(ExtractedRoot, True);
  end;
end;

function RestoreFLibraryBook(const ContainerFileName, BookEntryName: string;
  const Source: TStream): TStream;
begin
  Result:=RestoreFLibraryBookWithImageSources(ContainerFileName,BookEntryName,Source,nil);
end;

function RestoreFLibraryBookWithImageSources(const ContainerFileName, BookEntryName: string;
  const Source: TStream; const ImageSources: TArray<string>): TStream;
var
  Images: TExternalBookImages;
begin
  Result := nil;
  if ImageSources<>nil then
  begin
    if Length(ImageSources)<>2 then raise EArgumentException.Create('Нужны отдельные источники обложек и иллюстраций.');
    for var ImageSource in ImageSources do
      if (ImageSource<>'') and not FileExists(ImageSource) then
        raise EReadError.Create('Не найден подготовленный архив изображений: '+ImageSource);
  end;
  if not IsSevenZipArchive(ContainerFileName) then
    Exit;

  if SameText(ExtractFileExt(BookEntryName), '.pdf') then
    Exit(RestorePackedPdf(Source));

  Images := TExternalBookImages.Create;
  try
    CollectExternalImages(ContainerFileName, BookEntryName, Images, ImageSources);
    if SameText(ExtractFileExt(BookEntryName), '.fb2') then
      Result := RestoreFb2(Source, Images)
    else if SameText(ExtractFileExt(BookEntryName), '.epub') then
      Result := RestoreEpub(Source, Images);
  finally
    Images.Free;
  end;
end;

end.
