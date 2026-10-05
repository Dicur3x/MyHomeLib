(* ****************************************************************************
  Embedded WebP compatibility for FB2 readers.

  Detect pictures by their bytes: compact INPX distributions can retain .jpg
  IDs and image/jpeg MIME attributes while storing WebP. Only converted binary
  elements change. Their IDs, references, book text and metadata stay intact.
****************************************************************************** *)
unit unit_WebPCompat;

interface

uses
  System.Classes,
  System.SysUtils;

function IsWebP(const Bytes: TBytes): Boolean;
function ConvertWebPToPNG(const Bytes: TBytes): TBytes;
// Nil means unchanged. The caller owns Source and the returned stream.
function NormalizeEmbeddedWebPFb2(const Source: TStream): TStream;
function ConvertWebPStreamToPNG(const Source: TStream): TStream;

implementation

uses
  Winapi.Windows,
  System.IOUtils,
  System.RegularExpressions,
  System.NetEncoding,
  System.SyncObjs,
  Vcl.Graphics,
  Vcl.Imaging.pngimage,
  unit_MHLExternalTools;

type
  TWebPGetInfo = function(Data: Pointer; DataSize: NativeUInt;
    var Width, Height: Integer): Integer; cdecl;
  TWebPDecodeBGRAInto = function(Data: Pointer; DataSize: NativeUInt;
    Output: Pointer; OutputSize: NativeUInt; Stride: Integer): Pointer; cdecl;
  TWebPGetDecoderVersion = function: Integer; cdecl;

var
  DecoderModule: HMODULE;
  DecoderLock: TCriticalSection;
  WebPGetInfo: TWebPGetInfo;
  WebPDecodeBGRAInto: TWebPDecodeBGRAInto;
  WebPGetDecoderVersion: TWebPGetDecoderVersion;

function IsWebP(const Bytes: TBytes): Boolean;
begin
  Result := (Length(Bytes) >= 12) and
    (Bytes[0] = Ord('R')) and (Bytes[1] = Ord('I')) and
    (Bytes[2] = Ord('F')) and (Bytes[3] = Ord('F')) and
    (Bytes[8] = Ord('W')) and (Bytes[9] = Ord('E')) and
    (Bytes[10] = Ord('B')) and (Bytes[11] = Ord('P'));
end;

function StreamBytes(const Source: TStream): TBytes;
var
  SavedPosition: Int64;
begin
  if Source.Size > MaxInt then
    raise ERangeError.Create('Файл книги слишком велик.');
  SavedPosition := Source.Position;
  try
    Source.Position := 0;
    SetLength(Result, Integer(Source.Size));
    if Length(Result) > 0 then
      Source.ReadBuffer(Result[0], Length(Result));
  finally
    Source.Position := SavedPosition;
  end;
end;

function BytesStream(const Bytes: TBytes): TStream;
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

procedure EnsureDecoder;
var
  DecoderPath: string;
begin
  DecoderLock.Acquire;
  try
    if DecoderModule <> 0 then
      Exit;
    // Use an absolute private runtime path, never a DLL from PATH or the book
    // folder. libwebp uses a CPU decoder and does not need an installed codec.
    DecoderPath := TPath.Combine(ExtractFilePath(ParamStr(0)),
      'tools\webp\libwebp.dll');
    if not FileExists(DecoderPath) then
      raise EMHLExternalToolError.Create(
        'Для преобразования WebP в PNG нужен tools\webp\libwebp.dll из архива HomeLib Ru.');
    DecoderModule := LoadLibraryEx(PChar(DecoderPath), 0,
      LOAD_WITH_ALTERED_SEARCH_PATH);
    if DecoderModule = 0 then
      raise EMHLExternalToolError.CreateFmt(
        'Не удалось загрузить декодер WebP (ошибка Windows %d).', [GetLastError]);
    WebPGetInfo := TWebPGetInfo(GetProcAddress(DecoderModule, 'WebPGetInfo'));
    WebPDecodeBGRAInto := TWebPDecodeBGRAInto(GetProcAddress(DecoderModule,
      'WebPDecodeBGRAInto'));
    WebPGetDecoderVersion := TWebPGetDecoderVersion(GetProcAddress(DecoderModule,
      'WebPGetDecoderVersion'));
    if not Assigned(WebPGetInfo) or not Assigned(WebPDecodeBGRAInto) or
      not Assigned(WebPGetDecoderVersion) then
    begin
      FreeLibrary(DecoderModule);
      DecoderModule := 0;
      raise EMHLExternalToolError.Create('Неверная версия декодера WebP.');
    end;
  finally
    DecoderLock.Release;
  end;
end;

function ConvertWebPToPNG(const Bytes: TBytes): TBytes;
var
  Width, Height, X, Y, PixelOffset: Integer;
  Pixels: TBytes;
  Bitmap: TBitmap;
  PNG: TPngImage;
  Row: PByte;
  Alpha: PByteArray;
  Stream: TMemoryStream;
begin
  if not IsWebP(Bytes) then
    Exit(Bytes);
  EnsureDecoder;
  // The small decoder build disables libwebp's own worker threads. Serialize
  // its lazy DSP initialization as well as decoding; PNG encoding stays outside
  // the lock so concurrent OPDS clients do not share mutable image objects.
  DecoderLock.Acquire;
  try
    if WebPGetDecoderVersion() < $010600 then
      raise EMHLExternalToolError.Create('Для преобразования WebP нужен libwebp 1.6.0 или новее.');
    if WebPGetInfo(@Bytes[0], Length(Bytes), Width, Height) = 0 then
      raise EMHLExternalToolError.Create('Не удалось прочитать изображение WebP.');
    if (Width <= 0) or (Height <= 0) or
      (Int64(Width) * Height > 64 * 1024 * 1024) then
      raise ERangeError.Create('Изображение WebP слишком велико.');
    SetLength(Pixels, Width * Height * 4);
    if WebPDecodeBGRAInto(@Bytes[0], Length(Bytes), @Pixels[0],
      Length(Pixels), Width * 4) = nil then
      raise EMHLExternalToolError.Create('Не удалось преобразовать WebP в PNG.');
  finally
    DecoderLock.Release;
  end;
  Bitmap := TBitmap.Create;
  PNG := TPngImage.Create;
  Stream := TMemoryStream.Create;
  try
    Bitmap.PixelFormat := pf24bit;
    Bitmap.SetSize(Width, Height);
    for Y := 0 to Height - 1 do
    begin
      // VCL exposes logical rows through ScanLine, already accounting for the
      // DIB storage direction. Keep RGB and alpha in the decoder's row order.
      Row := Bitmap.ScanLine[Y];
      for X := 0 to Width - 1 do
      begin
        PixelOffset := (Y * Width + X) * 4;
        Row^ := Pixels[PixelOffset]; Inc(Row);
        Row^ := Pixels[PixelOffset + 1]; Inc(Row);
        Row^ := Pixels[PixelOffset + 2]; Inc(Row);
      end;
    end;
    PNG.Assign(Bitmap);
    PNG.CreateAlpha;
    for Y := 0 to Height - 1 do
    begin
      Alpha := PNG.AlphaScanline[Y];
      for X := 0 to Width - 1 do
        Alpha[X] := Pixels[(Y * Width + X) * 4 + 3];
    end;
    PNG.SaveToStream(Stream);
    Result := StreamBytes(Stream);
  finally
    Stream.Free;
    PNG.Free;
    Bitmap.Free;
  end;
end;

function ConvertWebPStreamToPNG(const Source: TStream): TStream;
var
  Bytes: TBytes;
begin
  Result := nil;
  Bytes := StreamBytes(Source);
  if IsWebP(Bytes) then
    Result := BytesStream(ConvertWebPToPNG(Bytes));
end;

function NormalizeEmbeddedWebPFb2(const Source: TStream): TStream;
const
  BINARY_PATTERN = '<((?:[A-Za-z_][\w.-]*:)?binary)\b([^>]*)>' +
    '([\s\S]*?)</\1\s*>';
var
  Bytes, ImageBytes, OutputBytes: TBytes;
  Encoding: TEncoding;
  Text, Attributes, NewAttributes, Replacement: string;
  Match, MimeMatch: TMatch;
  Builder: TStringBuilder;
  LastEnd: Integer;
  Changed: Boolean;
begin
  Result := nil;
  Bytes := StreamBytes(Source);
  // Latin-1 round-trips every byte, retaining UTF-8/cp1251 and the original
  // XML declaration verbatim. UTF-16 is decoded with its byte order instead.
  if (Length(Bytes) >= 2) and (Bytes[0] = $FF) and (Bytes[1] = $FE) then
    Encoding := TEncoding.Unicode
  else if (Length(Bytes) >= 2) and (Bytes[0] = $FE) and (Bytes[1] = $FF) then
    Encoding := TEncoding.BigEndianUnicode
  else
    Encoding := TEncoding.GetEncoding(28591);
  Builder := TStringBuilder.Create;
  try
    Text := Encoding.GetString(Bytes);
    LastEnd := 0;
    Changed := False;
    Match := TRegEx.Match(Text, BINARY_PATTERN, [roIgnoreCase]);
    while Match.Success do
    begin
      try
        ImageBytes := TNetEncoding.Base64.DecodeStringToBytes(Match.Groups[3].Value);
      except
        ImageBytes := nil;
      end;
      if IsWebP(ImageBytes) then
      begin
        ImageBytes := ConvertWebPToPNG(ImageBytes);
        Attributes := Match.Groups[2].Value;
        MimeMatch := TRegEx.Match(Attributes,
          '\bcontent-type\s*=\s*(?:"[^"]*"|''[^'']*'')', [roIgnoreCase]);
        if MimeMatch.Success then
          NewAttributes := Copy(Attributes, 1, MimeMatch.Index - 1) +
            'content-type="image/png"' +
            Copy(Attributes, MimeMatch.Index + MimeMatch.Length, MaxInt)
        else
          NewAttributes := Attributes + ' content-type="image/png"';
        Replacement := '<' + Match.Groups[1].Value + NewAttributes + '>' +
          TNetEncoding.Base64.EncodeBytesToString(ImageBytes) + '</' +
          Match.Groups[1].Value + '>';
        // Delphi TMatch.Index is one-based, just like Copy.
        Builder.Append(Copy(Text, LastEnd + 1, Match.Index - LastEnd - 1));
        Builder.Append(Replacement);
        LastEnd := Match.Index + Match.Length - 1;
        Changed := True;
      end;
      Match := Match.NextMatch;
    end;
    if not Changed then
      Exit;
    Builder.Append(Copy(Text, LastEnd + 1, MaxInt));
    OutputBytes := Encoding.GetBytes(Builder.ToString);
    Result := BytesStream(OutputBytes);
  finally
    Builder.Free;
    if (Encoding <> TEncoding.Unicode) and
      (Encoding <> TEncoding.BigEndianUnicode) then
      Encoding.Free;
  end;
end;

initialization
  DecoderModule := 0;
  DecoderLock := TCriticalSection.Create;
finalization
  if DecoderModule <> 0 then
    FreeLibrary(DecoderModule);
  DecoderLock.Free;
end.
