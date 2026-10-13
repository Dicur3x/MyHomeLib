unit unit_ReaderPDF;

interface

uses Winapi.Windows, System.SysUtils, System.Classes, System.Types, Vcl.Graphics;

type
  TPDFChapter = record
    Title: string;
    Page, Depth: Integer;
  end;
  TPDFMatch = record
    Index, Count: Integer;
    Rects: TArray<TRectF>;
  end;
  TPDFGetBlock = function(Param: Pointer; Position: Cardinal; Buffer: Pointer; Size: Cardinal): Integer; cdecl;
  TPDFFileAccess = record
    Length: Cardinal;
    GetBlock: TPDFGetBlock;
    Param: Pointer;
  end;
  TPDFRasterCache = record
    Pixels: TBytes;
    Index, Width, Height: Integer;
    Night: Boolean;
    Used: UInt64;
  end;
  // All PDFium calls run on the reader's UI thread. The backing stream lives
  // until CloseDocument; pages are rendered on demand, never indexed eagerly.
  TReaderPDF = class
  private
    FStream: TFileStream;
    FAccess: TPDFFileAccess;
    FDocument: Pointer;
    FCopyPage, FCopyText: Pointer;
    FCopyIndex: Integer;
    FRasters: array[0..2] of TPDFRasterCache;
    FRasterClock: UInt64;
    FRenderCount: Integer;
    function CachedRaster(Index, Width, Height: Integer; Night: Boolean): Integer;
    procedure StoreRaster(Index, Width, Height: Integer; Night: Boolean; Pixels: Pointer);
    function SelectionPage(Index: Integer): Pointer;
    procedure CloseSelectionPage;
  protected
    FPageCount: Integer;
    constructor CreateEmpty;
  public
    constructor Create(const LibraryFile, FileName: string);
    destructor Destroy; override;
    function PageSize(Index: Integer): TPoint; virtual;
    function AsyncPages: Boolean; virtual;
    procedure PreparePage(Index: Integer; Prefetch: Boolean = False; RenderEdge: Integer = 4000); virtual;
    function IsPageCached(Index: Integer; MinEdge: Integer = 0): Boolean; virtual;
    procedure RenderPixels(Index, Width, Height: Integer; Pixels: Pointer);
    function Render(Index, Width, Height: Integer; Night: Boolean = False): TBitmap; virtual;
    function Chapters: TArray<TPDFChapter>; virtual;
    function DisplayName: string; virtual;
    function HasTextSearch: Boolean; virtual;
    function PageHasText(Page: Integer): Boolean;
    function TextCharacterAt(Page: Integer; X, Y, ToleranceX, ToleranceY: Double): Integer;
    function TextRange(Page, Start, Count: Integer): string;
    function TextRectangles(Page, Start, Count: Integer): TArray<TRectF>;
    function FindOnPage(Page: Integer; const Query: string; Start: Integer;
      out Match: TPDFMatch; MatchCase: Boolean = False; WholeWord: Boolean = False;
      Backward: Boolean = False): Boolean; virtual;
    function FindAllOnPage(Page: Integer; const Query: string; MatchCase,
      WholeWord: Boolean): TArray<TPDFMatch>; virtual;
    property PageCount: Integer read FPageCount;
    property NativeRenderCount: Integer read FRenderCount;
  end;

implementation

uses System.Math, System.Generics.Collections;

type
  // The pinned bblanchon non-V8/non-XFA runtime exports the C ABI on Win32.
  // Using stdcall here corrupts the stack; Win64 has one calling convention.
  TInit = procedure; cdecl;
  TLoadCustom = function(Access: Pointer; Password: PAnsiChar): Pointer; cdecl;
  TCloseDocument = procedure(Document: Pointer); cdecl;
  TGetPageCount = function(Document: Pointer): Integer; cdecl;
  TLoadPage = function(Document: Pointer; Index: Integer): Pointer; cdecl;
  TClosePage = procedure(Page: Pointer); cdecl;
  TDimension = function(Page: Pointer): Single; cdecl;
  TCreateBitmap = function(Width, Height, Format: Integer; Buffer: Pointer; Stride: Integer): Pointer; cdecl;
  TDestroyBitmap = procedure(Bitmap: Pointer); cdecl;
  TFillBitmap = procedure(Bitmap: Pointer; Left, Top, Width, Height: Integer; Color: Cardinal); cdecl;
  TRenderBitmap = procedure(Bitmap, Page: Pointer; X,Y,Width,Height,Rotate,Flags: Integer); cdecl;
  TTwoHandles = function(Document, Value: Pointer): Pointer; cdecl;
  TGetTitle = function(Bookmark, Buffer: Pointer; Bytes: Cardinal): Cardinal; cdecl;
  TGetDestPage = function(Document, Dest: Pointer): Integer; cdecl;
  TOneHandle = function(Value: Pointer): Pointer; cdecl;
  TCloseHandle = procedure(Value: Pointer); cdecl;
  TFindStart = function(TextPage: Pointer; Query: PWideChar; Flags: Cardinal; Start: Integer): Pointer; cdecl;
  THandleInt = function(Value: Pointer): Integer; cdecl;
  TCountRects = function(TextPage: Pointer; Start, Count: Integer): Integer; cdecl;
  TGetRect = function(TextPage: Pointer; Index: Integer; var Left, Top, Right, Bottom: Double): Integer; cdecl;
  TCharAt = function(TextPage: Pointer; X, Y, ToleranceX, ToleranceY: Double): Integer; cdecl;
  TGetText = function(TextPage: Pointer; Start, Count: Integer; Buffer: PWideChar): Integer; cdecl;

var
  Module: HMODULE;
  InitLibrary, DestroyLibrary: TInit;
  LoadCustom: TLoadCustom;
  CloseDocument: TCloseDocument;
  GetPageCount: TGetPageCount;
  LoadPage: TLoadPage;
  ClosePage: TClosePage;
  PageWidth, PageHeight: TDimension;
  CreateBitmap: TCreateBitmap;
  DestroyBitmap: TDestroyBitmap;
  FillBitmap: TFillBitmap;
  RenderBitmap: TRenderBitmap;
  BookmarkFirst, BookmarkNext, BookmarkDest: TTwoHandles;
  BookmarkTitle: TGetTitle;
  DestPage: TGetDestPage;
  TextLoad: TOneHandle;
  TextClose, FindClose: TCloseHandle;
  FindStart: TFindStart;
  FindNext, FindPrevious, FindIndex, FindCount: THandleInt;
  CountRects: TCountRects;
  GetRect: TGetRect;
  CountChars: THandleInt; CharAt: TCharAt; GetText: TGetText;

procedure LoadPDFLibrary(const FileName: string);
  procedure Entry(var Proc; const Name: AnsiString);
  begin
    Pointer(Proc):=GetProcAddress(Module,PAnsiChar(Name));
    if Pointer(Proc)=nil then raise Exception.Create('В PDFium отсутствует функция '+string(Name));
  end;
begin
  if Module<>0 then Exit;
  Module:=LoadLibraryEx(PChar(ExpandFileName(FileName)),0,LOAD_WITH_ALTERED_SEARCH_PATH);
  if Module=0 then raise Exception.Create('Компонент PDFium не найден. PDF можно открыть внешней читалкой.');
  try
    Entry(InitLibrary,'FPDF_InitLibrary'); Entry(DestroyLibrary,'FPDF_DestroyLibrary');
    Entry(LoadCustom,'FPDF_LoadCustomDocument'); Entry(CloseDocument,'FPDF_CloseDocument');
    Entry(GetPageCount,'FPDF_GetPageCount'); Entry(LoadPage,'FPDF_LoadPage'); Entry(ClosePage,'FPDF_ClosePage');
    Entry(PageWidth,'FPDF_GetPageWidthF'); Entry(PageHeight,'FPDF_GetPageHeightF');
    Entry(CreateBitmap,'FPDFBitmap_CreateEx'); Entry(DestroyBitmap,'FPDFBitmap_Destroy');
    Entry(FillBitmap,'FPDFBitmap_FillRect'); Entry(RenderBitmap,'FPDF_RenderPageBitmap');
    Entry(BookmarkFirst,'FPDFBookmark_GetFirstChild'); Entry(BookmarkNext,'FPDFBookmark_GetNextSibling');
    Entry(BookmarkTitle,'FPDFBookmark_GetTitle'); Entry(BookmarkDest,'FPDFBookmark_GetDest');
    Entry(DestPage,'FPDFDest_GetDestPageIndex');
    Entry(TextLoad,'FPDFText_LoadPage'); Entry(TextClose,'FPDFText_ClosePage');
    Entry(FindStart,'FPDFText_FindStart'); Entry(FindNext,'FPDFText_FindNext');
    Entry(FindPrevious,'FPDFText_FindPrev');
    Entry(FindIndex,'FPDFText_GetSchResultIndex'); Entry(FindCount,'FPDFText_GetSchCount');
    Entry(FindClose,'FPDFText_FindClose'); Entry(CountRects,'FPDFText_CountRects'); Entry(GetRect,'FPDFText_GetRect');
    Entry(CountChars,'FPDFText_CountChars'); Entry(CharAt,'FPDFText_GetCharIndexAtPos');
    Entry(GetText,'FPDFText_GetText');
    InitLibrary;
  except FreeLibrary(Module); Module:=0; raise; end;
end;

function ReadBlock(Param: Pointer; Position: Cardinal; Buffer: Pointer; Size: Cardinal): Integer; cdecl;
var Stream: TFileStream;
begin
  Result:=0;
  try
    Stream:=TFileStream(Param);
    if Int64(Position)+Size>Stream.Size then Exit;
    Stream.Position:=Position;
    if Size>Cardinal(MaxInt) then Exit;
    if Stream.Read(Buffer^,Integer(Size))=Integer(Size) then Result:=1;
  except Result:=0; end;
end;

constructor TReaderPDF.CreateEmpty;
begin inherited Create; FCopyIndex:=-1; end;

function TReaderPDF.DisplayName: string;
begin Result:='PDF'; end;

function TReaderPDF.HasTextSearch: Boolean;
begin Result:=True; end;

function TReaderPDF.AsyncPages: Boolean;
begin Result:=False; end;

procedure TReaderPDF.PreparePage(Index: Integer; Prefetch: Boolean; RenderEdge: Integer);
begin end;

function TReaderPDF.IsPageCached(Index, MinEdge: Integer): Boolean;
begin Result:=True; end;

procedure TReaderPDF.RenderPixels(Index, Width, Height: Integer; Pixels: Pointer);
var Page, Bitmap: Pointer;
begin
  if (Index<0) or (Index>=FPageCount) or (Pixels=nil) or (Width<=0) or (Height<=0) or
    (Int64(Width)*Height>16000000) then raise ERangeError.Create('Некорректный размер страницы PDF.');
  Page:=LoadPage(FDocument,Index);
  if Page=nil then raise Exception.Create('Не удалось прочитать страницу PDF.');
  try
    Bitmap:=CreateBitmap(Width,Height,4,Pixels,Width*4);
    if Bitmap=nil then raise Exception.Create('Недостаточно памяти для страницы PDF.');
    try
      FillBitmap(Bitmap,0,0,Width,Height,$FFFFFFFF);
      RenderBitmap(Bitmap,Page,0,0,Width,Height,0,1); Inc(FRenderCount);
    finally DestroyBitmap(Bitmap); end;
  finally ClosePage(Page); end;
end;

constructor TReaderPDF.Create(const LibraryFile, FileName: string);
begin
  inherited Create; FCopyIndex:=-1; LoadPDFLibrary(LibraryFile);
  FStream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
  if FStream.Size>High(Cardinal) then raise Exception.Create('PDF больше 4 ГБ пока открывается внешней читалкой.');
  FAccess.Length:=FStream.Size; FAccess.GetBlock:=ReadBlock; FAccess.Param:=FStream;
  FDocument:=LoadCustom(@FAccess,nil);
  if FDocument=nil then raise Exception.Create('Не удалось открыть PDF. Файл повреждён или защищён паролем.');
  FPageCount:=GetPageCount(FDocument);
  if FPageCount<=0 then raise Exception.Create('В PDF нет страниц.');
end;

destructor TReaderPDF.Destroy;
begin
  CloseSelectionPage;
  if (FDocument<>nil) and Assigned(CloseDocument) then CloseDocument(FDocument);
  FStream.Free; inherited;
end;

procedure TReaderPDF.CloseSelectionPage;
begin
  if FCopyText<>nil then TextClose(FCopyText);
  if FCopyPage<>nil then ClosePage(FCopyPage);
  FCopyText:=nil; FCopyPage:=nil; FCopyIndex:=-1;
end;

function TReaderPDF.SelectionPage(Index: Integer): Pointer;
begin
  Result:=nil;
  if not HasTextSearch or (FDocument=nil) or (Index<0) or (Index>=FPageCount) then Exit;
  if FCopyIndex<>Index then
  begin
    CloseSelectionPage;
    FCopyPage:=LoadPage(FDocument,Index);
    if FCopyPage<>nil then FCopyText:=TextLoad(FCopyPage);
    FCopyIndex:=Index;
  end;
  Result:=FCopyText;
end;

function TReaderPDF.PageHasText(Page: Integer): Boolean;
var Text: Pointer;
begin Text:=SelectionPage(Page); Result:=(Text<>nil) and (CountChars(Text)>0); end;

function TReaderPDF.TextCharacterAt(Page: Integer; X, Y, ToleranceX, ToleranceY: Double): Integer;
var Text: Pointer;
begin
  Result:=-1; Text:=SelectionPage(Page);
  if Text<>nil then Result:=CharAt(Text,X,Y,ToleranceX,ToleranceY);
end;

function TReaderPDF.TextRange(Page, Start, Count: Integer): string;
var Text: Pointer; Copied, Available: Integer;
begin
  Result:=''; Text:=SelectionPage(Page); if Text=nil then Exit;
  Available:=CountChars(Text); Start:=EnsureRange(Start,0,Max(0,Available));
  Count:=Min(1000000,Min(Max(0,Count),Available-Start)); if Count<=0 then Exit;
  SetLength(Result,Count*2+1);
  Copied:=GetText(Text,Start,Count,PWideChar(Result));
  if Copied<=0 then Result:='' else SetLength(Result,Copied-1);
end;

function TReaderPDF.TextRectangles(Page, Start, Count: Integer): TArray<TRectF>;
var Text: Pointer; I,N: Integer; L,T,R,B: Double;
begin
  Result:=nil; Text:=SelectionPage(Page); if (Text=nil) or (Start<0) or (Count<=0) then Exit;
  N:=CountRects(Text,Start,Count); if (N<=0) or (N>100000) then Exit;
  SetLength(Result,N);
  for I:=0 to N-1 do
    if GetRect(Text,I,L,T,R,B)<>0 then Result[I]:=TRectF.Create(L,B,R,T);
end;

function TReaderPDF.PageSize(Index: Integer): TPoint;
var Page: Pointer;
begin
  if (Index<0) or (Index>=FPageCount) then raise ERangeError.Create('Номер страницы PDF вне диапазона.');
  Page:=LoadPage(FDocument,Index);
  if Page=nil then raise Exception.Create('Не удалось прочитать страницу PDF.');
  try Result:=Point(Max(1,Round(PageWidth(Page))),Max(1,Round(PageHeight(Page))));
  finally ClosePage(Page); end;
end;

function TReaderPDF.CachedRaster(Index, Width, Height: Integer; Night: Boolean): Integer;
var I: Integer;
begin
  Result:=-1;
  for I:=0 to High(FRasters) do
    if (Length(FRasters[I].Pixels)>0) and (FRasters[I].Index=Index) and
      (FRasters[I].Width=Width) and (FRasters[I].Height=Height) and
      (FRasters[I].Night=Night) then
    begin Inc(FRasterClock); FRasters[I].Used:=FRasterClock; Exit(I); end;
end;

procedure TReaderPDF.StoreRaster(Index, Width, Height: Integer; Night: Boolean; Pixels: Pointer);
var I, Slot, Bytes: Integer;
begin
  // Three CPU buffers, each at most 16 MiB. No persistent GDI handles and no
  // unbounded cache growth when the reader is resized or zoomed repeatedly.
  if Int64(Width)*Height*4>16*1024*1024 then Exit;
  Slot:=0;
  for I:=0 to High(FRasters) do
    if Length(FRasters[I].Pixels)=0 then begin Slot:=I; Break; end
    else if FRasters[I].Used<FRasters[Slot].Used then Slot:=I;
  Bytes:=Width*Height*4;
  SetLength(FRasters[Slot].Pixels,Bytes); Move(Pixels^,FRasters[Slot].Pixels[0],Bytes);
  FRasters[Slot].Index:=Index; FRasters[Slot].Width:=Width; FRasters[Slot].Height:=Height;
  FRasters[Slot].Night:=Night; Inc(FRasterClock); FRasters[Slot].Used:=FRasterClock;
end;

function TReaderPDF.Render(Index, Width, Height: Integer; Night: Boolean): TBitmap;
var Page, Bitmap: Pointer; Pixels: PByte; I, Cached: Integer;
  Info: TBitmapInfo; DIB: HBITMAP;
begin
  if (Index<0) or (Index>=FPageCount) then raise ERangeError.Create('Номер страницы PDF вне диапазона.');
  if (Width<=0) or (Height<=0) or (Int64(Width)*Height>25000000) then
    raise ERangeError.Create('Слишком большой масштаб страницы PDF.');
  Result:=nil; Page:=nil; Cached:=CachedRaster(Index,Width,Height,Night);
  if Cached<0 then
  begin
    Page:=LoadPage(FDocument,Index);
    if Page=nil then raise Exception.Create('Не удалось прочитать страницу PDF.');
  end;
  try
    // PDFium needs a nonnegative stride. A top-down DIB lets it render into
    // the VCL bitmap itself, without a second full-page pixel allocation.
    FillChar(Info,SizeOf(Info),0);
    Info.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
    Info.bmiHeader.biWidth:=Width; Info.bmiHeader.biHeight:=-Height;
    Info.bmiHeader.biPlanes:=1; Info.bmiHeader.biBitCount:=32;
    Info.bmiHeader.biCompression:=BI_RGB; Pixels:=nil;
    DIB:=Winapi.Windows.CreateDIBSection(0,Info,DIB_RGB_COLORS,Pointer(Pixels),0,0);
    if (DIB=0) or (Pixels=nil) then
    begin
      if DIB<>0 then DeleteObject(DIB);
      raise Exception.Create('Недостаточно памяти для страницы PDF.');
    end;
    try
      Result:=TBitmap.Create;
      Result.Handle:=DIB; DIB:=0; // TBitmap owns the DIB from this point.
      GdiFlush;
      if Cached>=0 then
      begin Move(FRasters[Cached].Pixels[0],Pixels^,Width*Height*4); Exit; end;
      Bitmap:=CreateBitmap(Width,Height,4,Pixels,Width*4);
      if Bitmap=nil then raise Exception.Create('Недостаточно памяти для страницы PDF.');
      try
        FillBitmap(Bitmap,0,0,Width,Height,$FFFFFFFF);
        RenderBitmap(Bitmap,Page,0,0,Width,Height,0,1); Inc(FRenderCount);
        // Only the disposable page raster changes; the source remains intact.
        if Night then
          for I:=0 to Width*Height-1 do
          begin
            Pixels[I*4]:=34+(255-Pixels[I*4])*186 div 255;
            Pixels[I*4+1]:=34+(255-Pixels[I*4+1])*186 div 255;
            Pixels[I*4+2]:=34+(255-Pixels[I*4+2])*186 div 255;
          end;
      finally DestroyBitmap(Bitmap); end;
      StoreRaster(Index,Width,Height,Night,Pixels);
    except
      if DIB<>0 then DeleteObject(DIB);
      FreeAndNil(Result); raise;
    end;
  finally if Page<>nil then ClosePage(Page); end;
end;

function TReaderPDF.Chapters: TArray<TPDFChapter>;
var List: TList<TPDFChapter>; Seen: TDictionary<Pointer,Boolean>;
  procedure Walk(Bookmark: Pointer; Depth: Integer);
  var Size: Cardinal; Item: TPDFChapter; Dest: Pointer; Title: string;
  begin
    if Depth>32 then Exit;
    while (Bookmark<>nil) and (Seen.Count<4096) do
    begin
      if Seen.ContainsKey(Bookmark) then Exit;
      Seen.Add(Bookmark,True);
      Size:=BookmarkTitle(Bookmark,nil,0);
      if (Size>=2) and (Size<=32768) and (Size mod 2=0) then
      begin
        SetLength(Title,Size div 2);
        BookmarkTitle(Bookmark,PChar(Title),Size); SetLength(Title,Length(Title)-1);
        Dest:=BookmarkDest(FDocument,Bookmark);
        if Dest<>nil then
        begin
          Item.Page:=DestPage(FDocument,Dest); Item.Title:=Title.Trim; Item.Depth:=Depth;
          if (Item.Page>=0) and (Item.Page<FPageCount) and (Item.Title<>'') then List.Add(Item);
        end;
      end;
      Walk(BookmarkFirst(FDocument,Bookmark),Depth+1);
      Bookmark:=BookmarkNext(FDocument,Bookmark);
    end;
  end;
begin
  List:=TList<TPDFChapter>.Create; Seen:=TDictionary<Pointer,Boolean>.Create;
  try Walk(BookmarkFirst(FDocument,nil),0); Result:=List.ToArray;
  finally Seen.Free; List.Free; end;
end;

function TReaderPDF.FindOnPage(Page: Integer; const Query: string; Start: Integer;
  out Match: TPDFMatch; MatchCase, WholeWord, Backward: Boolean): Boolean;
var PageHandle, TextPage, Search: Pointer; I, Count: Integer;
  Left, Top, Right, Bottom: Double; Flags: Cardinal;
begin
  Result:=False; Match.Index:=-1; Match.Count:=0; Match.Rects:=nil;
  if (Page<0) or (Page>=FPageCount) or (Query='') or (Length(Query)>1024) then Exit;
  PageHandle:=LoadPage(FDocument,Page); if PageHandle=nil then Exit;
  try
    TextPage:=TextLoad(PageHandle); if TextPage=nil then Exit;
    try
      Flags:=Ord(MatchCase) or (Ord(WholeWord) shl 1);
      if not Backward then Start:=Max(0,Start);
      Search:=FindStart(TextPage,PChar(Query),Flags,Start); if Search=nil then Exit;
      try
        if Backward then begin if FindPrevious(Search)=0 then Exit; end
        else if FindNext(Search)=0 then Exit;
        Match.Index:=FindIndex(Search); Match.Count:=FindCount(Search);
        Count:=EnsureRange(CountRects(TextPage,Match.Index,Match.Count),0,256);
        SetLength(Match.Rects,Count);
        for I:=0 to Count-1 do
          if GetRect(TextPage,I,Left,Top,Right,Bottom)<>0 then
            Match.Rects[I]:=TRectF.Create(Left,Bottom,Right,Top);
        Result:=True;
      finally FindClose(Search); end;
    finally TextClose(TextPage); end;
  finally ClosePage(PageHandle); end;
end;

function TReaderPDF.FindAllOnPage(Page: Integer; const Query: string;
  MatchCase, WholeWord: Boolean): TArray<TPDFMatch>;
var PageHandle, TextPage, Search: Pointer; Matches: TList<TPDFMatch>;
  Match: TPDFMatch; I, Count: Integer; Left, Top, Right, Bottom: Double;
begin
  Result:=nil;
  if (Page<0) or (Page>=FPageCount) or (Query='') or (Length(Query)>1024) then Exit;
  PageHandle:=LoadPage(FDocument,Page); if PageHandle=nil then Exit;
  try
    TextPage:=TextLoad(PageHandle); if TextPage=nil then Exit;
    try
      Search:=FindStart(TextPage,PChar(Query),Ord(MatchCase) or (Ord(WholeWord) shl 1),0);
      if Search=nil then Exit;
      Matches:=TList<TPDFMatch>.Create;
      try
        while (Matches.Count<1000) and (FindNext(Search)<>0) do
        begin
          Match.Index:=FindIndex(Search); Match.Count:=FindCount(Search);
          Count:=EnsureRange(CountRects(TextPage,Match.Index,Match.Count),0,256);
          Match.Rects:=nil; SetLength(Match.Rects,Count);
          for I:=0 to Count-1 do
            if GetRect(TextPage,I,Left,Top,Right,Bottom)<>0 then
              Match.Rects[I]:=TRectF.Create(Left,Bottom,Right,Top);
          Matches.Add(Match);
        end;
        Result:=Matches.ToArray;
      finally Matches.Free; FindClose(Search); end;
    finally TextClose(TextPage); end;
  finally ClosePage(PageHandle); end;
end;

initialization
finalization
  if Module<>0 then begin if Assigned(DestroyLibrary) then DestroyLibrary; FreeLibrary(Module); end;
end.
