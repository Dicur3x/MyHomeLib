unit unit_ReaderRaster;

interface

uses System.SysUtils, System.Classes, System.Types, Vcl.Graphics,
  unit_ReaderPDF, unit_MHLArchiveHelpers, unit_ReaderDjvuNative;

function IsRasterReaderFormat(const Extension: string): Boolean;

type
  // Only one decoded original page is retained. Archive entries stay compressed.
  TReaderRaster = class(TReaderPDF)
  private
    FArchive: TMHLZip;
    FNames: TArray<string>;
    FFileName: string;
    FCachedPage: Integer;
    FOriginalPixels: TBytes;
    FOriginalWidth, FOriginalHeight: Integer;
    FTiff, FDjvu: Boolean;
    FSourceStream: TStream;
    FNativeDjvu: TReaderDjvuNative;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
    procedure PreparePage(Index: Integer);
    function PageSize(Index: Integer): TPoint; override;
    function Render(Index, Width, Height: Integer; Night: Boolean = False): TBitmap; override;
    function Chapters: TArray<TPDFChapter>; override;
    function DisplayName: string; override;
    function HasTextSearch: Boolean; override;
    function FindOnPage(Page: Integer; const Query: string; Start: Integer;
      out Match: TPDFMatch; MatchCase: Boolean = False; WholeWord: Boolean = False;
      Backward: Boolean = False): Boolean; override;
    function FindAllOnPage(Page: Integer; const Query: string; MatchCase,
      WholeWord: Boolean): TArray<TPDFMatch>; override;
  end;

implementation

uses Winapi.Windows, Winapi.ActiveX, Winapi.Wincodec, System.Math, System.IOUtils,
  System.Generics.Collections, System.Generics.Defaults, System.Win.ComObj,
  unit_WebPCompat, unit_ReaderDjvu, unit_BookCache;

type TBitmap = Vcl.Graphics.TBitmap;

function ImageExtension(const E: string): Boolean;
begin Result:=Pos('|'+LowerCase(E)+'|','|.jpg|.jpeg|.png|.gif|.bmp|.webp|.tif|.tiff|')>0; end;

function IsRasterReaderFormat(const Extension: string): Boolean;
begin Result:=ImageExtension(Extension) or (Pos('|'+LowerCase(Extension)+'|','|.cbr|.cbz|.cb7|.djvu|.djv|.dju|.djm|.djvm|')>0); end;

function PageCompare(const A,B: string): Integer;
var I,J,AI,BJ: Integer; X,Y: string;
begin
  I:=1; J:=1;
  while (I<=Length(A)) and (J<=Length(B)) do
  begin
    if CharInSet(A[I],['0'..'9']) and CharInSet(B[J],['0'..'9']) then
    begin
      AI:=I; BJ:=J;
      while (I<=Length(A)) and CharInSet(A[I],['0'..'9']) do Inc(I);
      while (J<=Length(B)) and CharInSet(B[J],['0'..'9']) do Inc(J);
      X:=Copy(A,AI,I-AI).TrimLeft(['0']); Y:=Copy(B,BJ,J-BJ).TrimLeft(['0']);
      Result:=Length(X)-Length(Y); if Result<>0 then Exit;
      Result:=CompareStr(X,Y); if Result<>0 then Exit;
    end
    else
    begin Result:=CompareText(A[I],B[J]); if Result<>0 then Exit; Inc(I); Inc(J); end;
  end;
  Result:=(Length(A)-I)-(Length(B)-J);
  if Result=0 then Result:=CompareStr(A,B);
end;

procedure TiffDecoder(const FileName: string; out Factory: IWICImagingFactory;
  out Decoder: IWICBitmapDecoder);
begin
  OleCheck(CoCreateInstance(CLSID_WICImagingFactory,nil,CLSCTX_INPROC_SERVER,IWICImagingFactory,Factory));
  OleCheck(Factory.CreateDecoderFromFilename(PWideChar(FileName),GUID_NULL,GENERIC_READ,WICDecodeMetadataCacheOnDemand,Decoder));
end;

constructor TReaderRaster.Create(const FileName: string);
var Names: TList<string>; I: Integer; Name, E: string; Factory: IWICImagingFactory;
  Decoder: IWICBitmapDecoder; Frames: Cardinal;
begin
  inherited CreateEmpty; FFileName:=TPath.GetFullPath(FileName); FCachedPage:=-1;
  E:=LowerCase(ExtractFileExt(FFileName)); FTiff:=(E='.tif') or (E='.tiff');
  FSourceStream:=OpenCachedBookFile(FFileName);
  FDjvu:=Pos('|'+E+'|','|.djvu|.djv|.dju|.djm|.djvm|')>0;
  if FDjvu then
  begin
    if NativeDjvuAvailable then
    begin FNativeDjvu:=TReaderDjvuNative.Create(FFileName); FPageCount:=FNativeDjvu.PageCount; end
    else FPageCount:=DjvuPageCount(FFileName);
  end
  else if ImageExtension(E) then
  begin
    FPageCount:=1;
    if FTiff then
    begin TiffDecoder(FFileName,Factory,Decoder); OleCheck(Decoder.GetFrameCount(Frames));
      if (Frames=0) or (Frames>100000) then raise Exception.Create('Некорректное число страниц TIFF.');
      FPageCount:=Frames;
    end;
  end
  else
  begin
    FArchive:=TMHLZip.Create(FFileName,True,False,
      function: Boolean begin Result:=(GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated; end,
      E<>'.cbz');
    Names:=TList<string>.Create;
    try
      for I:=0 to FArchive.FileCount-1 do
      begin
        Name:=FArchive.FileNames[I];
        if ImageExtension(ExtractFileExt(Name)) and not Name.StartsWith('__MACOSX/',True) and
          not ExtractFileName(Name).StartsWith('._') then Names.Add(Name);
      end;
      Names.Sort(TComparer<string>.Construct(PageCompare)); FNames:=Names.ToArray;
    finally Names.Free; end;
    FPageCount:=Length(FNames);
    if FPageCount=0 then raise Exception.Create('В комиксе не найдены изображения страниц.');
  end;
  PreparePage(0);
end;

destructor TReaderRaster.Destroy;
begin FNativeDjvu.Free; FArchive.Free; FSourceStream.Free; inherited; end;

procedure TReaderRaster.PreparePage(Index: Integer);
var Stream, Converted, PageStream: TStream; Adapter: IStream;
  Factory: IWICImagingFactory; Decoder: IWICBitmapDecoder;
  Frame: IWICBitmapFrameDecode; Converter: IWICFormatConverter;
  Scaler: IWICBitmapScaler; Source: IWICBitmapSource;
  W,H: Cardinal; Scale: Double; PageFile: string; OriginalPixels: TBytes;
  I,A,NativeWidth,NativeHeight: Integer;
begin
  if Index=FCachedPage then Exit;
  if (Index<0) or (Index>=FPageCount) then raise ERangeError.Create('Номер страницы вне диапазона.');
  if (GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated then Abort;
  if Assigned(FNativeDjvu) then
  begin
    FNativeDjvu.RenderPage(Index,OriginalPixels,NativeWidth,NativeHeight);
    FOriginalWidth:=NativeWidth; FOriginalHeight:=NativeHeight;
    FOriginalPixels:=OriginalPixels; FCachedPage:=Index; Exit;
  end;
  Stream:=nil; Converted:=nil; PageStream:=nil;
  try
    OleCheck(CoCreateInstance(CLSID_WICImagingFactory,nil,CLSCTX_INPROC_SERVER,IWICImagingFactory,Factory));
    if FTiff or FDjvu then
    begin
      PageFile:=FFileName;
      if FDjvu then
      begin PageFile:=PrepareDjvuPage(FFileName,Index); PageStream:=OpenCachedBookFile(PageFile); end;
      OleCheck(Factory.CreateDecoderFromFilename(PWideChar(PageFile),GUID_NULL,GENERIC_READ,WICDecodeMetadataCacheOnDemand,Decoder));
      if FDjvu then OleCheck(Decoder.GetFrame(0,Frame)) else OleCheck(Decoder.GetFrame(Index,Frame));
    end
    else
    begin
      if Assigned(FArchive) then
      begin
        if not FArchive.Find(FNames[Index]) then raise Exception.Create('Страница комикса отсутствует.');
        if (FArchive.LastSize<0) or (FArchive.LastSize>32*1024*1024) then raise Exception.Create('Изображение комикса превышает 32 МБ.');
        Stream:=TMemoryStream.Create; FArchive.ExtractToStream(FNames[Index],Stream);
      end else Stream:=TFileStream.Create(FFileName,fmOpenRead or fmShareDenyNone);
      Stream.Position:=0; Converted:=ConvertWebPStreamToPNG(Stream);
      if Assigned(Converted) then Adapter:=TStreamAdapter.Create(Converted,soReference)
      else begin Stream.Position:=0; Adapter:=TStreamAdapter.Create(Stream,soReference); end;
      OleCheck(Factory.CreateDecoderFromStream(Adapter,GUID_NULL,WICDecodeMetadataCacheOnDemand,Decoder));
      OleCheck(Decoder.GetFrame(0,Frame));
    end;
    OleCheck(Frame.GetSize(W,H));
    if (W=0) or (H=0) or (W>100000) or (H>100000) then raise Exception.Create('Некорректный размер изображения страницы.');
    Source:=Frame;
    if UInt64(W)*H>16000000 then
    begin
      Scale:=Sqrt(16000000.0/(Double(W)*H)); W:=Max(1,Trunc(W*Scale)); H:=Max(1,Trunc(H*Scale));
      OleCheck(Factory.CreateBitmapScaler(Scaler));
      OleCheck(Scaler.Initialize(Frame,W,H,WICBitmapInterpolationModeFant)); Source:=Scaler;
    end;
    OleCheck(Factory.CreateFormatConverter(Converter));
    OleCheck(Converter.Initialize(Source,GUID_WICPixelFormat32bppBGRA,WICBitmapDitherTypeNone,nil,0,WICBitmapPaletteTypeCustom));
    SetLength(OriginalPixels,W*H*4);
    OleCheck(Converter.CopyPixels(nil,W*4,Length(OriginalPixels),@OriginalPixels[0]));
    // Flatten transparency on paper without using a VCL canvas in a worker.
    I:=0;
    while I<Length(OriginalPixels) do
    begin
      A:=OriginalPixels[I+3];
      if A<>255 then
      begin
        OriginalPixels[I]:=(Integer(OriginalPixels[I])*A+255*(255-A)) div 255;
        OriginalPixels[I+1]:=(Integer(OriginalPixels[I+1])*A+255*(255-A)) div 255;
        OriginalPixels[I+2]:=(Integer(OriginalPixels[I+2])*A+255*(255-A)) div 255;
      end;
      OriginalPixels[I+3]:=255; Inc(I,4);
    end;
    if (GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated then Abort;
    // Only a finished pixel buffer crosses the thread boundary, never a GDI handle.
    FOriginalWidth:=W; FOriginalHeight:=H; FOriginalPixels:=OriginalPixels; FCachedPage:=Index;
  finally
    Converter:=nil; Source:=nil; Scaler:=nil; Frame:=nil; Decoder:=nil; Adapter:=nil; Factory:=nil;
    Converted.Free; Stream.Free; PageStream.Free;
  end;
end;

function TReaderRaster.PageSize(Index: Integer): TPoint;
begin
  if FCachedPage<>Index then raise Exception.Create('Страница ещё подготавливается.');
  Result:=Point(FOriginalWidth,FOriginalHeight);
end;

function TReaderRaster.Render(Index, Width, Height: Integer; Night: Boolean): TBitmap;
var Info: TBitmapInfo;
begin
  PageSize(Index);
  if (Width<=0) or (Height<=0) or (Int64(Width)*Height>25000000) then raise ERangeError.Create('Слишком большой масштаб страницы.');
  Result:=TBitmap.Create;
  try
    Result.PixelFormat:=pf32bit; Result.SetSize(Width,Height);
    SetStretchBltMode(Result.Canvas.Handle,HALFTONE); SetBrushOrgEx(Result.Canvas.Handle,0,0,nil);
    FillChar(Info,SizeOf(Info),0); Info.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
    Info.bmiHeader.biWidth:=FOriginalWidth; Info.bmiHeader.biHeight:=-FOriginalHeight;
    Info.bmiHeader.biPlanes:=1; Info.bmiHeader.biBitCount:=32;
    if StretchDIBits(Result.Canvas.Handle,0,0,Width,Height,0,0,FOriginalWidth,FOriginalHeight,
      @FOriginalPixels[0],Info,DIB_RGB_COLORS,SRCCOPY)<=0 then
      raise Exception.Create('Не удалось отрисовать страницу.');
    // Comics retain their original colours even in a dark interface theme.
  except Result.Free; raise; end;
end;

function TReaderRaster.Chapters: TArray<TPDFChapter>;
var I: Integer;
begin
  SetLength(Result,Min(FPageCount,4096));
  for I:=0 to High(Result) do
  begin
    Result[I].Page:=I; Result[I].Depth:=0;
    if Assigned(FArchive) then Result[I].Title:=FNames[I] else Result[I].Title:='Страница '+IntToStr(I+1);
  end;
end;

function TReaderRaster.DisplayName: string;
begin if FDjvu then Result:='DjVu' else if FTiff then Result:='TIFF' else if Assigned(FArchive) then Result:='Комикс' else Result:='Изображение'; end;
function TReaderRaster.HasTextSearch: Boolean;
begin Result:=False; end;
function TReaderRaster.FindOnPage(Page: Integer; const Query: string; Start: Integer;
  out Match: TPDFMatch; MatchCase, WholeWord, Backward: Boolean): Boolean;
begin Match:=Default(TPDFMatch); Result:=False; end;
function TReaderRaster.FindAllOnPage(Page: Integer; const Query: string; MatchCase, WholeWord: Boolean): TArray<TPDFMatch>;
begin Result:=nil; end;

end.
