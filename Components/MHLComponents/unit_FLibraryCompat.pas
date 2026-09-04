(* ****************************************************************************
  Compatibility with the space-saving FLibrary torrent layout.

  The layout stores book texts in 7z archives and keeps covers/illustrations in
  sibling archives.  This unit reconstructs a conventional FB2 or EPUB stream
  before MyHomeLib passes it to a reader or exporter.  Ordinary ZIP/INPX
  collections never enter this code path.
****************************************************************************** *)

unit unit_FLibraryCompat;

interface

uses
  System.Classes;

// Returns nil when no reconstruction was needed.  The caller retains ownership
// of Source in every case and owns the returned stream when it is assigned.
function RestoreFLibraryBook(const ContainerFileName, BookEntryName: string;
  const Source: TStream): TStream;

// Extracts and decodes only the cover used by the information panel.  Unlike
// RestoreFLibraryBook, this does not touch the book text or its illustrations.
// The caller owns the returned stream.  Nil means that no cover was found.
function ExtractFLibraryBookCover(const ContainerFileName,
  BookEntryName: string): TStream;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.StrUtils,
  System.Zip,
  System.JSON,
  System.NetEncoding,
  System.Generics.Collections,
  unit_MHLArchiveHelpers,
  unit_MHLExternalTools;

const
  FLIBRARY_IMAGE_INDEX = 'FLibraryImageIndex.json';

type
  TExternalBookImage = record
    Name: string;
    IsCover: Boolean;
    Data: TBytes;
  end;

  TExternalBookImages = TList<TExternalBookImage>;

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
  Result := ChangeFileExt(ExtractFileName(ContainerFileName), '');
end;

function BookBaseName(const BookEntryName: string): string;
begin
  Result := ChangeFileExt(ExtractFileName(BookEntryName), '');
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
  Root := ExtractFileDir(ContainerFileName);
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
  const Images: TExternalBookImages);
var
  KnownNames: TDictionary<string, Byte>;

  procedure CollectCover;
  var
    Archive: TMHLZip;
    ArchiveName: string;
    Stream: TMemoryStream;
  begin
    ArchiveName := FindSiblingArchive(ContainerFileName, 'covers');
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
          ;
        on E: EFOpenError do
          ;
        on E: EMHLExternalToolError do
          ;
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
    ArchiveName := FindSiblingArchive(ContainerFileName, 'images');
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
          ;
        on E: EFOpenError do
          ;
        on E: EMHLExternalToolError do
          ;
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

function ConvertJpegXL(const Bytes: TBytes;
  const PreferredFileName: string): TBytes;
var
  Decoder: string;
  InputFile: string;
  OutputExtension: string;
  OutputFile: string;
  Sink: TMemoryStream;
begin
  Decoder := FindExternalTool('djxl.exe', 'jpeg-xl');
  if Decoder = '' then
    raise EMHLExternalToolError.Create(
      'Для восстановления иллюстраций нужен tools\jpeg-xl\djxl.exe.');

  if SameText(ExtractFileExt(PreferredFileName), '.png') then
    OutputExtension := '.png'
  else
    OutputExtension := '.jpg';
  InputFile := NewTemporaryFileName('.jxl');
  OutputFile := NewTemporaryFileName(OutputExtension);
  try
    TFile.WriteAllBytes(InputFile, Bytes);
    Sink := TMemoryStream.Create;
    try
      RunExternalToolToStream(Decoder, [InputFile, OutputFile], Sink);
    finally
      Sink.Free;
    end;
    if not FileExists(OutputFile) then
      raise EMHLExternalToolError.Create(
        'Декодер JPEG XL не создал изображение.');
    Result := TFile.ReadAllBytes(OutputFile);
  finally
    if FileExists(InputFile) then
      DeleteFile(InputFile);
    if FileExists(OutputFile) then
      DeleteFile(OutputFile);
  end;
end;

function ImageMediaType(const Bytes: TBytes): string; forward;

function TryExtractExternalImage(const ArchiveFileName,
  EntryName: string; out Bytes: TBytes): Boolean;
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
      Archive := TMHLZip.Create(ArchiveFileName, True);
      WantedName := NormalizeArchiveName(EntryName);
      for I := 0 to Archive.FileCount - 1 do
        if SameText(NormalizeArchiveName(Archive.FileNameAt(I)), WantedName) then
        begin
          Stream := TMemoryStream.Create;
          Archive.ExtractToStream(I, Stream);
          Bytes := StreamToBytes(Stream);
          Exit(Length(Bytes) > 0);
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
  BookEntryName: string): TStream;
var
  ArchiveName: string;
  Bytes: TBytes;
  PreferredName: string;
begin
  Result := nil;
  if not IsSevenZipArchive(ContainerFileName) then
    Exit;

  // FB2 covers are normally stored in covers\<archive>.zip under the book's
  // base name.  Prefer this explicit cover for every supported book format.
  ArchiveName := FindSiblingArchive(ContainerFileName, 'covers');
  if TryExtractExternalImage(ArchiveName, BookBaseName(BookEntryName), Bytes) then
    PreferredName := 'cover.png'
  else
  begin
    // FLibrary moves an EPUB cover to image number zero before generating its
    // image index.  Reading this one side-archive member avoids unpacking and
    // rebuilding the complete nested EPUB merely to paint a thumbnail.
    if not SameText(ExtractFileExt(BookEntryName), '.epub') then
      Exit;
    ArchiveName := FindSiblingArchive(ContainerFileName, 'images');
    if not TryExtractExternalImage(ArchiveName,
      BookBaseName(BookEntryName) + '/0', Bytes) then
      Exit;
    PreferredName := 'cover.png';
  end;

  if IsJpegXL(Bytes) then
    Bytes := ConvertJpegXL(Bytes, PreferredName);
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

procedure MakeImagesReaderCompatible(Images: TExternalBookImages;
  const PreferredNames: TDictionary<string, string> = nil);
var
  I: Integer;
  Item: TExternalBookImage;
  PreferredName: string;
begin
  for I := 0 to Images.Count - 1 do
    if IsJpegXL(Images[I].Data) then
    begin
      Item := Images[I];
      PreferredName := Item.Name;
      if Assigned(PreferredNames) and
        not PreferredNames.TryGetValue(Item.Name, PreferredName) then
        PreferredName := Item.Name;
      Item.Data := ConvertJpegXL(Item.Data, PreferredName);
      Images[I] := Item;
    end;
end;

function FindClosingFictionBook(const Bytes: TBytes): Integer;
const
  TOKEN: AnsiString = '</fictionbook>';
var
  B: Byte;
  I: Integer;
  J: Integer;
begin
  for I := Length(Bytes) - Length(TOKEN) downto 0 do
  begin
    Result := I;
    for J := 1 to Length(TOKEN) do
    begin
      B := Bytes[I + J - 1];
      if (B >= Ord('A')) and (B <= Ord('Z')) then
        Inc(B, Ord('a') - Ord('A'));
      if B <> Ord(TOKEN[J]) then
      begin
        Result := -1;
        Break;
      end;
    end;
    if Result >= 0 then
      Exit;
  end;
  Result := -1;
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
      InsertText.Append('<binary id="');
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

function NormalizeOpfImageReferenceCase(const Bytes: TBytes;
  const TargetImages: TDictionary<string, TExternalBookImage>): TBytes;
var
  ImageName: string;
  Text: string;
begin
  // ZIP entry names are case-sensitive.  Real-world EPUB files sometimes
  // disagree only by case between the OPF guide and its manifest (Images vs
  // images).  Desktop readers may forgive that, while e-readers commonly do
  // not.  The FLibrary image index supplies the canonical entry names, so use
  // those names everywhere in the OPF while rebuilding the archive.
  Text := TEncoding.UTF8.GetString(Bytes);
  for ImageName in TargetImages.Keys do
    Text := StringReplace(Text, ImageName, ImageName,
      [rfReplaceAll, rfIgnoreCase]);
  Result := TEncoding.UTF8.GetBytes(Text);
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
  TDictionary<Integer, string>): Boolean;
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
          ImageTargets.AddOrSetValue(StrToIntDef(NumberValue.Value, 0),
            NormalizeArchiveName(NameValue.Value));
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
  ImageTargets: TDictionary<Integer, string>;
  InputFile: string;
  MimetypeIndex: Integer;
  Names: TArray<string>;
  Output: TMemoryStream;
  OutputFile: string;
  OutputName: string;
  PreferredNames: TDictionary<string, string>;
  Stream: TMemoryStream;
  TargetImages: TDictionary<string, TExternalBookImage>;
  Zip: TZipFile;
  SourceIsSevenZip: Boolean;
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
  ImageTargets := TDictionary<Integer, string>.Create;
  PreferredNames := TDictionary<string, string>.Create;
  TargetImages := TDictionary<string, TExternalBookImage>.Create;
  AddedNames := TDictionary<string, Byte>.Create;
  try
    TFile.WriteAllBytes(InputFile, Bytes);
    Archive := TMHLZip.Create(InputFile, True);
    SetLength(Names, Archive.FileCount);
    for I := 0 to Archive.FileCount - 1 do
      Names[I] := NormalizeArchiveName(Archive.FileNameAt(I));
    if SourceIsSevenZip then
    begin
      ExtractedRoot := NewTemporaryDirectory;
      Archive.ExtractAllToDirectory(ExtractedRoot);
    end;
    LoadEpubImageIndex(Archive, Names, ExtractedRoot, ImageTargets);

    for I := 0 to Images.Count - 1 do
    begin
      if Images[I].IsCover then
        ImageNo := -1
      else
        ImageNo := StrToIntDef(Images[I].Name, MaxInt);
      if not ImageTargets.TryGetValue(ImageNo, OutputName) then
        Continue;
      PreferredNames.AddOrSetValue(Images[I].Name, OutputName);
    end;
    MakeImagesReaderCompatible(Images, PreferredNames);
    for I := 0 to Images.Count - 1 do
    begin
      if Images[I].IsCover then
        ImageNo := -1
      else
        ImageNo := StrToIntDef(Images[I].Name, MaxInt);
      if ImageTargets.TryGetValue(ImageNo, OutputName) then
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
          Bytes := NormalizeOpfImageReferenceCase(StreamToBytes(Stream),
            TargetImages);
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
    PreferredNames.Free;
    ImageTargets.Free;
    Zip.Free;
    Archive.Free;
    if FileExists(InputFile) then
      DeleteFile(InputFile);
    if FileExists(OutputFile) then
      DeleteFile(OutputFile);
    if (ExtractedRoot <> '') and TDirectory.Exists(ExtractedRoot) then
      TDirectory.Delete(ExtractedRoot, True);
  end;
end;

function RestoreFLibraryBook(const ContainerFileName, BookEntryName: string;
  const Source: TStream): TStream;
var
  Images: TExternalBookImages;
begin
  Result := nil;
  if not IsSevenZipArchive(ContainerFileName) then
    Exit;

  Images := TExternalBookImages.Create;
  try
    CollectExternalImages(ContainerFileName, BookEntryName, Images);
    if SameText(ExtractFileExt(BookEntryName), '.fb2') then
      Result := RestoreFb2(Source, Images)
    else if SameText(ExtractFileExt(BookEntryName), '.epub') then
      Result := RestoreEpub(Source, Images);
  finally
    Images.Free;
  end;
end;

end.
