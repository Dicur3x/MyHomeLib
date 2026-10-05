program LightLibTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.NetEncoding,
  System.RegularExpressions,
  System.Zip,
  Vcl.Graphics,
  Vcl.Imaging.pngimage,
  unit_MHLArchiveHelpers in '..\unit_MHLArchiveHelpers.pas',
  unit_MHLExternalTools in '..\unit_MHLExternalTools.pas',
  unit_WebPCompat in '..\unit_WebPCompat.pas',
  unit_FB2Utils in '..\unit_FB2Utils.pas',
  unit_InpxSeries in '..\unit_InpxSeries.pas',
  unit_LibrarySourceID in '..\unit_LibrarySourceID.pas';

const
  TRANSPARENT_WEBP =
    'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';

var
  Checks: Integer;

procedure Check(Condition: Boolean; const Description: string);
begin
  Inc(Checks);
  if not Condition then
    raise Exception.Create('FAIL: ' + Description);
end;

function BytesStream(const Bytes: TBytes): TMemoryStream;
begin
  Result := TMemoryStream.Create;
  if Length(Bytes) > 0 then
    Result.WriteBuffer(Bytes[0], Length(Bytes));
  Result.Position := 0;
end;

function StreamBytes(const Stream: TStream): TBytes;
begin
  Stream.Position := 0;
  SetLength(Result, Stream.Size);
  if Length(Result) > 0 then
    Stream.ReadBuffer(Result[0], Length(Result));
end;

function SampleBook(const Binary: string): string;
begin
  Result := '<?xml version="1.0" encoding="utf-8"?>' + #13#10 +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" ' +
    'xmlns:l="http://www.w3.org/1999/xlink">' +
    '<description><title-info><book-title>Книга</book-title>' +
    '<coverpage><image l:href="#cover.jpg"/></coverpage>' +
    '</title-info></description><body><section><p>Текст &amp; ' +
    'метаданные</p><image l:href="#cover.jpg"/></section></body>' +
    Binary + '</FictionBook>';
end;

procedure TestImageAndBook;
var
  ImageBytes, PNGBytes, Bytes, OutBytes: TBytes;
  Source: TMemoryStream;
  Converted: TStream;
  PNG: TPngImage;
  Graphic: TGraphic;
  Book, Text: string;
  Match: TMatch;
  Legacy: TEncoding;
begin
  ImageBytes := TNetEncoding.Base64.DecodeStringToBytes(TRANSPARENT_WEBP);
  Check(IsWebP(ImageBytes), 'WebP signature');
  Check(not IsWebP(TEncoding.ASCII.GetBytes('image/jpeg')), 'MIME is not magic');
  PNGBytes := ConvertWebPToPNG(ImageBytes);
  Source := BytesStream(ImageBytes);
  Graphic := nil;
  try
    Graphic := CreateGraphicFromStream(Source);
    Check(Assigned(Graphic) and (Graphic.Width = 2) and (Graphic.Height = 2),
      'original WebP cover preview decoded');
  finally
    Graphic.Free;
    Source.Free;
  end;
  Source := BytesStream(PNGBytes);
  PNG := TPngImage.Create;
  try
    PNG.LoadFromStream(Source);
    Check((PNG.Width = 2) and (PNG.Height = 2), 'image dimensions');
    Check(PNG.AlphaScanline[0][0] = 0, 'transparent pixel retained');
    Check(PNG.AlphaScanline[0][1] = 128, 'partial alpha retained');
    Check(PNG.AlphaScanline[1][0] = 255, 'opaque alpha retained');
    Check(ColorToRGB(PNG.Canvas.Pixels[0, 1]) = $0000FF, 'red channels retained');
  finally
    PNG.Free;
    Source.Free;
  end;

  Book := SampleBook('<binary content-type=''image/jpeg'' id="cover.jpg">' +
    TRANSPARENT_WEBP + '</binary><binary id="unchanged" ' +
    'content-type="image/png">' +
    TNetEncoding.Base64.EncodeBytesToString(PNGBytes) + '</binary>');
  Source := BytesStream(TEncoding.UTF8.GetBytes(Book));
  Converted := nil;
  try
    Source.Position := 7;
    Converted := NormalizeEmbeddedWebPFb2(Source);
    Check(Assigned(Converted), 'embedded WebP converted despite JPEG MIME');
    Check(Source.Position = 7, 'source position retained');
    Text := TEncoding.UTF8.GetString(StreamBytes(Converted));
    Check(Pos('id="cover.jpg"', Text) > 0, 'binary ID retained');
    Check(Pos('l:href="#cover.jpg"', Text) > 0, 'image references retained');
    Check(Pos('content-type="image/png" id="cover.jpg"', Text) > 0,
      'MIME updated to actual PNG');
    Check(Copy(Text, 1, Pos('<binary', Text) - 1) =
      Copy(Book, 1, Pos('<binary', Book) - 1), 'book metadata/text byte content retained');
    Check(Pos('<binary id="unchanged" content-type="image/png">' +
      TNetEncoding.Base64.EncodeBytesToString(PNGBytes) + '</binary>', Text) > 0,
      'existing PNG unchanged');
    Match := TRegEx.Match(Text, 'id="cover.jpg">([^<]+)</binary>');
    Check(Match.Success, 'converted binary found');
    Bytes := TNetEncoding.Base64.DecodeStringToBytes(Match.Groups[1].Value);
    Check(not IsWebP(Bytes) and (Length(Bytes) > 8) and (Bytes[0] = $89),
      'output binary actual PNG');
  finally
    Converted.Free;
    Source.Free;
  end;

  Source := BytesStream(TEncoding.UTF8.GetBytes(SampleBook('')));
  try
    Converted := NormalizeEmbeddedWebPFb2(Source);
    Check(not Assigned(Converted), 'ordinary FB2 returns unchanged');
    Converted.Free;
  finally
    Source.Free;
  end;

  Legacy := TEncoding.GetEncoding(1251);
  try
    Book := StringReplace(Book, 'utf-8', 'windows-1251', []);
    Bytes := Legacy.GetBytes(Book);
    Source := BytesStream(Bytes);
    Converted := nil;
    try
      Converted := NormalizeEmbeddedWebPFb2(Source);
      Check(Assigned(Converted), 'legacy cp1251 converted');
      OutBytes := StreamBytes(Converted);
      Check(Legacy.GetString(OutBytes).StartsWith(
        Copy(Book, 1, Pos('<binary', Book) - 1)), 'cp1251 prefix retained');
      Check(Pos('encoding="windows-1251"', Legacy.GetString(OutBytes)) > 0,
        'legacy XML encoding retained');
    finally
      Converted.Free;
      Source.Free;
    end;
  finally
    Legacy.Free;
  end;
end;

procedure TestSeriesAndIDs;
var
  Series: TInpxSeriesItems;
  SourceName, ID: string;
begin
  Series := ParseInpxSeries('Цикл\Издательская серия\Попаданцы', '2:0:7');
  Check(Length(Series) = 3, 'three inline series');
  Check((Series[0].Title = 'Цикл') and (Series[0].Number = 2), 'first series/number');
  Check((Series[2].Title = 'Попаданцы') and (Series[2].Number = 7), 'third series/number');
  Series := ParseInpxSeries('Цикл\Вторая', '4');
  Check((Length(Series) = 2) and (Series[1].Number = 0), 'missing series number');
  Series := ParseInpxSeries('Обычная серия', '12');
  Check((Length(Series) = 1) and (Series[0].Number = 12), 'ordinary INPX series');
  Check(Length(ParseInpxSeries('', '')) = 0, 'empty series');
  Check(IsMixedLibraryIndex(['fb2-1-10.inp', 'f.fb2-1-10.inp']), 'mixed index detected');
  Check(not IsMixedLibraryIndex(['fb2-1-10.inp', 'structure.info']), 'ordinary index retained');
  Check(not IsMixedLibraryIndex(['f.fb2-1-10.inp']), 'Flibusta-only index retained');
  Check(ScopedLibraryID('fb2-1-10.inp', '42') = 'librusec:42', 'Librusec scope');
  Check(ScopedLibraryID('f.fb2-1-10.inp', '42') = 'flibusta:42', 'Flibusta scope');
  Check(ScopedLibraryID('fb2-1-10.inp', 'already:42') = 'already:42', 'already-scoped IDs retained');
  Check(TryParseLibrarySourceID('flibusta:42', SourceName, ID) and
    (SourceName = 'flibusta') and (ID = '42'), 'original source ID for URL');
  Check(not TryParseLibrarySourceID('arbitrary:42', SourceName, ID), 'other IDs not interpreted');
  Check(not TryParseLibrarySourceID('flibusta:../42', SourceName, ID), 'unsafe source ID rejected');
end;

procedure TestArchives;
var
  TempRoot, Tool, PPMdArchive, StandardArchive: string;
  Id: TGUID;
  Sink, Source: TMemoryStream;
  Opened: TStream;
  Archive: TMHLZip;
  Bytes: TBytes;
  Zip: TZipFile;
  MissingRejected: Boolean;
begin
  Tool := FindExternalTool('7za.exe', '7zip');
  Check(Tool <> '', '7-Zip runtime available');
  CreateGUID(Id);
  TempRoot := TPath.Combine(TPath.GetTempPath, 'HomeLibRu-LightLibTest-' +
    GUIDToString(Id));
  TDirectory.CreateDirectory(TempRoot);
  try
    PPMdArchive := TPath.Combine(TempRoot, 'ppmd.zip');
    StandardArchive := TPath.Combine(TempRoot, 'deflate.zip');
    TFile.WriteAllText(TPath.Combine(TempRoot, 'book.fb2'), SampleBook(''), TEncoding.UTF8);
    Sink := TMemoryStream.Create;
    try
      RunExternalToolToStream(Tool, ['a', '-tzip', '-mm=PPMd', '-mx=5',
        '--', PPMdArchive, TPath.Combine(TempRoot, 'book.fb2')], Sink);
    finally
      Sink.Free;
    end;
    Zip := TZipFile.Create;
    try
      Zip.Open(StandardArchive, zmWrite);
      Zip.Add(TPath.Combine(TempRoot, 'book.fb2'), 'book.fb2', zcDeflate);
    finally
      Zip.Free;
    end;
    Bytes := TFile.ReadAllBytes(TPath.Combine(TempRoot, 'book.fb2'));
    for PPMdArchive in TArray<string>.Create(PPMdArchive, StandardArchive) do
    begin
      Archive := TMHLZip.Create(PPMdArchive, True);
      Source := TMemoryStream.Create;
      Opened := nil;
      try
        Check(Archive.FileCount = 1, 'archive directory');
        Check(Archive.Find('*.fb2'), 'archive wildcard lookup');
        Archive.ExtractToStream('book.fb2', Source);
        Check(TEncoding.UTF8.GetString(StreamBytes(Source)) =
          TEncoding.UTF8.GetString(Bytes), 'exact named archive extraction');
        Check(Archive.FileSizes[0] = Length(Bytes), 'archive size');
        Source.Clear;
        Archive.ExtractBookToStream('book.fb2', 12345, Source);
        Check(TEncoding.UTF8.GetString(StreamBytes(Source)) =
          TEncoding.UTF8.GetString(Bytes), 'exact name beats stale source index');
        Source.Clear;
        MissingRejected := False;
        try
          Archive.ExtractBookToStream('missing.fb2', 0, Source);
        except
          on E: EZipException do MissingRejected := True;
        end;
        if SameText(ExtractFileName(PPMdArchive), 'ppmd.zip') then
          Check(MissingRejected, 'PPMd never opens a different book by stale index')
        else
          Check(not MissingRejected and (Source.Size = Length(Bytes)),
            'ordinary ZIP legacy-index compatibility retained');
        Opened := Archive.OpenEntryStream(0);
        Check(TEncoding.UTF8.GetString(StreamBytes(Opened)) =
          TEncoding.UTF8.GetString(Bytes), 'metadata stream with PPMd/Deflate');
      finally
        Opened.Free;
        Source.Free;
        Archive.Free;
      end;
    end;
  finally
    TDirectory.Delete(TempRoot, True);
  end;
end;

// Optional read-only real-world sample: archive path and one exact member.
// No collection is imported and no file in the supplied archive is changed.
procedure TestRealSample(const ArchivePath, EntryName: string);
var
  Archive: TMHLZip;
  Source: TMemoryStream;
  Converted: TStream;
  Original, Output, Retained: TBytes;
  Text: string;
  Match: TMatch;
  Picture: TBytes;
  Pictures: Integer;
  ByteEncoding: TEncoding;
begin
  Archive := TMHLZip.Create(ArchivePath, True);
  Source := TMemoryStream.Create;
  Converted := nil;
  try
    Archive.ExtractBookToStream(EntryName, -1, Source);
    Original := StreamBytes(Source);
    Check(Length(Original) > 0, 'real PPMd sample extracted');
    Converted := NormalizeEmbeddedWebPFb2(Source);
    Check(Assigned(Converted), 'real compact sample contains converted WebP');
    Output := StreamBytes(Converted);
    Retained := StreamBytes(Source);
    Check((Length(Retained) = Length(Original)) and
      CompareMem(@Original[0], @Retained[0], Length(Original)),
      'original extracted book remains unchanged');
    // Real LightLib books can retain windows-1251. Inspect ASCII XML/binary
    // markup through a byte-preserving view rather than assuming UTF-8.
    ByteEncoding := TEncoding.GetEncoding(28591);
    try
      Text := ByteEncoding.GetString(Output);
    finally
      ByteEncoding.Free;
    end;
    Match := TRegEx.Match(Text, '<binary\b([^>]*)>([\s\S]*?)</binary>', [roIgnoreCase]);
    Pictures := 0;
    while Match.Success do
    begin
      Picture := TNetEncoding.Base64.DecodeStringToBytes(Match.Groups[2].Value);
      Check(not IsWebP(Picture), 'real output contains no WebP image');
      if (Length(Picture) > 8) and (Picture[0] = $89) then
      begin
        Inc(Pictures);
        Check(Pos('image/png', Match.Groups[1].Value) > 0, 'real PNG MIME correct');
      end;
      Match := Match.NextMatch;
    end;
    Check(Pictures > 0, 'real book PNG pictures retained');
    Writeln('Real sample: ', EntryName, ', PNG pictures: ', Pictures);
  finally
    Converted.Free;
    Source.Free;
    Archive.Free;
  end;
end;

begin
  try
    TestImageAndBook;
    TestSeriesAndIDs;
    TestArchives;
    if ParamCount >= 2 then
      TestRealSample(ParamStr(1), ParamStr(2));
    Writeln('PASS: ', Checks, ' LightLib compatibility checks');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
