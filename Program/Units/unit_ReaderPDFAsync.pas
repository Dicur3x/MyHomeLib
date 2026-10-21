unit unit_ReaderPDFAsync;

interface

uses System.SysUtils, System.Types, System.Generics.Collections, Vcl.Graphics,
  unit_ReaderPDF, unit_ReaderPDFWorker;

type
  TPDFPreparedPage = record
    Pixels: TBytes;
    Width, Height, Edge: Integer;
    Used: UInt64;
  end;
  // UI PDFium handles serve selection/search only. A persistent isolated
  // renderer prepares bounded CPU buffers, keeping slow image decoding off UI.
  TReaderPDFAsync = class(TReaderPDF)
  private
    FFileName: string;
    FWorker: TReaderPDFWorker;
    FPages: TDictionary<Integer,TPDFPreparedPage>;
    FLock: TObject;
    FBytes: Int64;
    FAge: UInt64;
    FVisiblePage, FVisibleFirst, FVisibleCount: Integer;
    function CachedPage(Index: Integer; out Page: TPDFPreparedPage; Visible: Boolean = False): Boolean;
  public
    constructor Create(const LibraryFile, FileName: string);
    destructor Destroy; override;
    function AsyncPages: Boolean; override;
    procedure PreparePage(Index: Integer; Prefetch: Boolean = False; RenderEdge: Integer = 4000); override;
    function IsPageCached(Index: Integer; MinEdge: Integer = 0): Boolean; override;
    procedure SetVisibleRange(First, Count: Integer); override;
    function Render(Index, Width, Height: Integer; Night: Boolean = False): TBitmap; override;
  end;

implementation

uses Winapi.Windows, System.Math;

type TBitmap = Vcl.Graphics.TBitmap;

constructor TReaderPDFAsync.Create(const LibraryFile, FileName: string);
begin
  inherited Create(LibraryFile,FileName);
  if not PDFWorkerAvailable then raise Exception.Create('В комплекте программы отсутствует HomeLibPDF.exe.');
  FFileName:=FileName; FVisiblePage:=-1; FLock:=TObject.Create;
  FPages:=TDictionary<Integer,TPDFPreparedPage>.Create;
end;

destructor TReaderPDFAsync.Destroy;
begin FWorker.Free; FPages.Free; FLock.Free; inherited; end;

function TReaderPDFAsync.AsyncPages: Boolean;
begin Result:=True; end;

function TReaderPDFAsync.CachedPage(Index: Integer; out Page: TPDFPreparedPage; Visible: Boolean): Boolean;
begin
  TMonitor.Enter(FLock);
  try
    Result:=FPages.TryGetValue(Index,Page);
    if Result then
    begin
      Inc(FAge); Page.Used:=FAge; FPages[Index]:=Page;
      if Visible then FVisiblePage:=Index;
    end;
  finally TMonitor.Exit(FLock); end;
end;

procedure TReaderPDFAsync.SetVisibleRange(First, Count: Integer);
var Page: TPDFPreparedPage;
begin
  TMonitor.Enter(FLock);
  try
    FVisibleFirst:=Max(0,First); FVisibleCount:=EnsureRange(Count,1,2);
    // Refit buffers retained from a magnified single-page view before loading
    // its neighbour. The displayed composite remains valid while reloading.
    if FVisibleCount=2 then
      for var I:=FVisibleFirst to FVisibleFirst+1 do
        if FPages.TryGetValue(I,Page) and (Page.Edge>3200) then
        begin Dec(FBytes,Length(Page.Pixels)); FPages.Remove(I); end;
  finally TMonitor.Exit(FLock); end;
end;

function TReaderPDFAsync.IsPageCached(Index, MinEdge: Integer): Boolean;
var Page: TPDFPreparedPage;
begin
  TMonitor.Enter(FLock);
  try Result:=FPages.TryGetValue(Index,Page); if Result then Result:=Page.Edge>=MinEdge;
  finally TMonitor.Exit(FLock); end;
end;

procedure TReaderPDFAsync.PreparePage(Index: Integer; Prefetch: Boolean; RenderEdge: Integer);
const Budget = 96*1024*1024;
var Page, Visible, Old: TPDFPreparedPage; Pair: TPair<Integer,TPDFPreparedPage>;
  Protected, Oldest: Integer; Stamp: UInt64;
begin
  RenderEdge:=EnsureRange(RenderEdge,200,4000);
  TMonitor.Enter(FLock);
  try if FVisibleCount=2 then RenderEdge:=Min(RenderEdge,3200);
  finally TMonitor.Exit(FLock); end;
  if CachedPage(Index,Page) and (Page.Edge>=RenderEdge) then Exit;
  if not Assigned(FWorker) then FWorker:=TReaderPDFWorker.Create(FFileName);
  Page:=Default(TPDFPreparedPage);
  FWorker.RenderPage(Index,Page.Pixels,Page.Width,Page.Height,RenderEdge); Page.Edge:=RenderEdge;
  TMonitor.Enter(FLock);
  try
    Protected:=FVisiblePage; if FVisibleCount>0 then Protected:=FVisibleFirst;
    if Prefetch and (Protected<>Index) and FPages.TryGetValue(Protected,Visible) and
      (Int64(Length(Visible.Pixels))+Length(Page.Pixels)>Budget) then Exit;
    if FPages.TryGetValue(Index,Old) then begin Dec(FBytes,Length(Old.Pixels)); FPages.Remove(Index); end;
    if not Prefetch then Protected:=Index;
    while (FPages.Count>=3) or (FBytes+Length(Page.Pixels)>Budget) do
    begin
      Oldest:=-1; Stamp:=High(UInt64);
      for Pair in FPages do
        if (Pair.Key<>Protected) and
          ((FVisibleCount=0) or (Pair.Key<FVisibleFirst) or (Pair.Key>=FVisibleFirst+FVisibleCount)) and (Pair.Value.Used<Stamp) then
        begin Oldest:=Pair.Key; Stamp:=Pair.Value.Used; end;
      if Oldest<0 then Break;
      Old:=FPages[Oldest]; Dec(FBytes,Length(Old.Pixels)); FPages.Remove(Oldest);
    end;
    Inc(FAge); Page.Used:=FAge; FPages.Add(Index,Page); Inc(FBytes,Length(Page.Pixels));
  finally TMonitor.Exit(FLock); end;
end;

function TReaderPDFAsync.Render(Index, Width, Height: Integer; Night: Boolean): TBitmap;
var Page: TPDFPreparedPage; Info: TBitmapInfo; Pixel: PRGBQuad; X,Y: Integer;
begin
  if not CachedPage(Index,Page,True) then raise Exception.Create('Страница ещё подготавливается.');
  if (Width<=0) or (Height<=0) or (Int64(Width)*Height>25000000) then
    raise ERangeError.Create('Слишком большой масштаб страницы PDF.');
  Result:=TBitmap.Create;
  try
    Result.PixelFormat:=pf32bit; Result.SetSize(Width,Height);
    SetStretchBltMode(Result.Canvas.Handle,HALFTONE); SetBrushOrgEx(Result.Canvas.Handle,0,0,nil);
    Info:=Default(TBitmapInfo); Info.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
    Info.bmiHeader.biWidth:=Page.Width; Info.bmiHeader.biHeight:=-Page.Height;
    Info.bmiHeader.biPlanes:=1; Info.bmiHeader.biBitCount:=32;
    if StretchDIBits(Result.Canvas.Handle,0,0,Width,Height,0,0,Page.Width,Page.Height,
      @Page.Pixels[0],Info,DIB_RGB_COLORS,SRCCOPY)<=0 then raise Exception.Create('Не удалось отрисовать страницу PDF.');
    if Night then
    begin
      GdiFlush;
      for Y:=0 to Height-1 do
      begin
        Pixel:=Result.ScanLine[Y];
        for X:=0 to Width-1 do
        begin
          Pixel.rgbBlue:=34+(255-Pixel.rgbBlue)*186 div 255;
          Pixel.rgbGreen:=34+(255-Pixel.rgbGreen)*186 div 255;
          Pixel.rgbRed:=34+(255-Pixel.rgbRed)*186 div 255; Inc(Pixel);
        end;
      end;
    end;
  except Result.Free; raise; end;
end;

end.
