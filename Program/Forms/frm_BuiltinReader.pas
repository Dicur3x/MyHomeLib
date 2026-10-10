unit frm_BuiltinReader;

interface

uses Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Graphics, Vcl.Menus, unit_MHLOperationStatus, unit_ReaderDocument, unit_ReaderPDF,
  unit_ReaderRaster;

type
  TfrmBuiltinReader = class;
  TReaderSurface = class(TCustomControl)
  private FReader: TfrmBuiltinReader;
  protected
    procedure Paint; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X,Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X,Y: Integer); override;
  end;

  TReaderLoadThread = class(TThread)
  private FFileName: string;
  protected procedure Execute; override;
  public
    Document: TReaderDocument;
    Pages: TReaderPDF;
    Error: string;
    constructor Create(const FileName: string);
    destructor Destroy; override;
  end;

  TReaderPageThread = class(TThread)
  private FReader: TReaderRaster;
  protected procedure Execute; override;
  public
    Index: Integer;
    Navigated: Boolean;
    Error: string;
    constructor Create(Reader: TReaderRaster; Page: Integer);
  end;

  TfrmBuiltinReader = class(TForm)
  private
    FSurface: TReaderSurface;
    FTop, FButtons, FBottom, FSearchPanel: TPanel;
    FStatus: TLabel;
    FSearch: TEdit;
    FThemes: TComboBox;
    FSearchCase, FSearchWord, FSearchAll: TCheckBox;
    FTheme: Integer;
    FHighlightColor: TColor;
    FHighlighted: TList<TPoint>;
    FTextMatch, FTextMatchLength: Integer;
    FSearchBackward, FUpdatingSearch: Boolean;
    FChapters: TComboBox;
    FRichEdit: TRichEdit;
    FFormattingHost: TForm;
    FOleCallback: IInterface;
    FBitmap: TBitmap;
    FDocument: TReaderDocument;
    FPDF: TReaderPDF;
    FLoadStatus: TMHLOperationStatus;
    FLoader: TReaderLoadThread;
    FPageWorker: TReaderPageThread;
    FRequestedPage: Integer;
    FRequestedMoved: Boolean;
    FPageTimer: TTimer;
    FPageStatus: TMHLOperationStatus;
    FPages: TList<Integer>;
    FPage, FNext, FLength, FFontSize, FZoom, FWheel: Integer;
    FNight, FFullScreen, FReady, FClosing, FLoadFinished, FReadingMoved, FWheelControl: Boolean;
    FIdentity, FSettingsFile, FFileName: string;
    FNormalBounds, FRestoredBounds: TRect;
    FBeforeFullScreenState: TWindowState;
    FPan, FDrag: TPoint;
    FInspect: Boolean;
    FInspectZoom: Integer;
    FInspectPan, FInspectSize: TPoint;
    FResizeTimer, FSearchTimer: TTimer;
    FFontName, FSearchQuery, FPDFQuery, FSearchStatus: string;
    FLinePercent, FMargin, FSearchPage, FSearchStart, FSearchVisited: Integer;
    FPDFMatchPage, FPDFMatchIndex: Integer;
    FPDFRects: TArray<TRectF>;
    FImageWidth, FImageHeight: Integer;
    FOnProgress: TProc<Integer>;
    FBookmarks: TPopupMenu;
    procedure MakeButton(const Caption: string; Action: TNotifyEvent; Width: Integer);
    procedure LoaderFinished(Sender: TObject);
    procedure RequestPage(Index: Integer; Moved: Boolean = True);
    procedure PageLoaded(Sender: TObject);
    procedure ResetInspection;
    procedure LoadPresentation;
    procedure RenderPage;
    procedure PaintPage(Canvas: TCanvas);
    procedure ResizePage(Sender: TObject);
    procedure ScheduleResize(Sender: TObject);
    procedure KeyReader(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure NextClick(Sender: TObject);
    procedure PreviousClick(Sender: TObject);
    procedure BiggerClick(Sender: TObject);
    procedure SmallerClick(Sender: TObject);
    procedure NightClick(Sender: TObject);
    procedure FullScreenClick(Sender: TObject);
    procedure BookmarkClick(Sender: TObject);
    procedure BookmarkSaveClick(Sender: TObject);
    procedure BookmarkOpenClick(Sender: TObject);
    procedure SearchClick(Sender: TObject);
    procedure SearchKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SearchTick(Sender: TObject);
    procedure ShowSearchStatus(const Text: string);
    procedure SearchPreviousClick(Sender: TObject);
    procedure SearchNextClick(Sender: TObject);
    procedure SearchOptionsClick(Sender: TObject);
    procedure SearchColorClick(Sender: TObject);
    procedure SearchCloseClick(Sender: TObject);
    procedure ThemeClick(Sender: TObject);
    function ThemeBackground: TColor;
    function ThemeText: TColor;
    function VisibleHighlightCount: Integer;
    function FindTextRange(const Query: string; Start, Finish: Integer; Backward: Boolean): Integer;
    procedure ClearTextHighlights;
    procedure HighlightTextPage;
    procedure ClampPan;
    procedure StyleClick(Sender: TObject);
    procedure ChapterClick(Sender: TObject);
    procedure CloseReader(Sender: TObject; var Action: TCloseAction);
    procedure RestoreSettings;
    procedure SaveSettings;
    procedure InvalidateLayout;
    function FormatText(Start, Finish: Integer; Draw: Boolean): Integer;
    function CurrentPosition: Integer;
    procedure NavigateTo(Position: Integer);
  protected
    procedure WMWindowPosChanged(var Message: TWMWindowPosChanged); message WM_WINDOWPOSCHANGED;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure OpenBook(const FileName, BookTitle, Identity, SettingsFile, PDFLibrary: string;
      const OnProgress: TProc<Integer> = nil);
    procedure NextPage;
    procedure PreviousPage;
    procedure ChangeSize(Delta: Integer);
    procedure ToggleNight;
    procedure SetTypography(const FontName: string; LinePercent, Margin: Integer);
    procedure FindText(const Query: string; Backward: Boolean = False);
    procedure SetSearchOptions(MatchCase, WholeWord, AllMatches: Boolean);
    procedure SetHighlightColor(Value: TColor);
    procedure SetTheme(Index: Integer);
    procedure StopSearch;
    procedure ToggleInspection(X,Y: Integer);
    procedure MoveInspection(X,Y: Integer);
    procedure EndInspection;
    function PageLoading: Boolean;
    function SearchRunning: Boolean;
    procedure GoToChapter(Index: Integer);
    function ChapterCount: Integer;
    procedure AddBookmark;
    procedure GoToBookmark(Index: Integer);
    function BookText: string;
    function PictureCount: Integer;
    function PageRasterSize: TPoint;
    function PageBackground: TColor;
    property Ready: Boolean read FReady;
    property LoadFinished: Boolean read FLoadFinished;
    property ReaderStatus: TLabel read FStatus;
    property ReadingSurface: TReaderSurface read FSurface;
    property TextPosition: Integer read CurrentPosition;
    property TextLength: Integer read FLength;
    property ReaderFontSize: Integer read FFontSize;
    property ReaderFontName: string read FFontName;
    property ReaderLinePercent: Integer read FLinePercent;
    property ReaderMargin: Integer read FMargin;
    property PDFZoom: Integer read FZoom;
    property ThemeIndex: Integer read FTheme;
    property HighlightColor: TColor read FHighlightColor;
    property MatchPosition: Integer read FTextMatch;
    property HighlightCount: Integer read VisibleHighlightCount;
    property PDFPan: TPoint read FPan;
    property Inspecting: Boolean read FInspect;
  end;

procedure OpenBuiltinReader(Owner: TComponent; const FileName, BookTitle, Identity,
  SettingsFile, PDFLibrary: string; const OnProgress: TProc<Integer> = nil);

implementation

uses Winapi.ActiveX, Winapi.RichEdit, Winapi.CommDlg, System.Math, System.IOUtils,
  System.IniFiles, System.Hash, Vcl.Dialogs, unit_ReaderRichEdit;

type
  // Own the immutable RTF string rather than copying it into another full buffer.
  TReaderRTFStream = class(TCustomMemoryStream)
  private FBytes: UTF8String;
  public
    constructor Create(const Bytes: UTF8String);
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

constructor TReaderRTFStream.Create(const Bytes: UTF8String);
begin
  inherited Create; FBytes:=Bytes;
  if FBytes<>'' then SetPointer(@FBytes[1],Length(FBytes)) else SetPointer(nil,0);
end;

function TReaderRTFStream.Write(const Buffer; Count: Longint): Longint;
begin raise EStreamError.Create('Поток книги доступен только для чтения.'); end;

procedure TReaderSurface.Paint;
begin if Assigned(FReader) then FReader.PaintPage(Canvas); end;

function TReaderSurface.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var Steps: Integer;
begin
  Result:=True;
  if not Assigned(FReader) then Exit;
  if not FReader.FReady then begin FReader.FWheel:=0; Exit; end;
  if WheelDelta=0 then Exit;
  if FReader.FWheelControl<>(ssCtrl in Shift) then
  begin FReader.FWheel:=0; FReader.FWheelControl:=ssCtrl in Shift; end;
  Inc(FReader.FWheel,WheelDelta);
  if ssCtrl in Shift then
  begin
    Steps:=FReader.FWheel div WHEEL_DELTA;
    FReader.FWheel:=FReader.FWheel mod WHEEL_DELTA;
    if Steps<>0 then FReader.ChangeSize(Steps);
    Exit;
  end;
  while FReader.FWheel>=WHEEL_DELTA do begin Dec(FReader.FWheel,WHEEL_DELTA); FReader.PreviousPage; end;
  while FReader.FWheel<=-WHEEL_DELTA do begin Inc(FReader.FWheel,WHEEL_DELTA); FReader.NextPage; end;
end;

procedure TReaderSurface.MouseDown(Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
begin
  inherited; SetFocus;
  if Assigned(FReader) and (Button=mbLeft) and not (ssCtrl in Shift) and Assigned(FReader.FPDF) then
  begin FReader.ToggleInspection(X,Y); Exit; end;
  if Assigned(FReader) then FReader.FDrag:=Point(X-FReader.FPan.X,Y-FReader.FPan.Y);
end;

procedure TReaderSurface.MouseMove(Shift: TShiftState; X,Y: Integer);
begin
  inherited;
  if Assigned(FReader) and FReader.FInspect then
  begin FReader.MoveInspection(X,Y); Exit; end;
  if (ssLeft in Shift) and (ssCtrl in Shift) and Assigned(FReader) and Assigned(FReader.FPDF) then
  begin
    FReader.FPan:=Point(X-FReader.FDrag.X,Y-FReader.FDrag.Y);
    FReader.ClampPan;
    Invalidate;
  end;
end;

constructor TReaderLoadThread.Create(const FileName: string);
begin inherited Create(True); FreeOnTerminate:=False; FFileName:=FileName; end;

destructor TReaderLoadThread.Destroy;
begin Pages.Free; Document.Free; inherited; end;

procedure TReaderLoadThread.Execute;
var HR: HRESULT;
begin
  HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try
    try
      if IsRasterReaderFormat(ExtractFileExt(FFileName)) then Pages:=TReaderRaster.Create(FFileName)
      else
      begin
        Document:=TReaderDocument.Create;
        Document.Load(FFileName,function: Boolean begin Result:=Terminated; end);
      end;
    except on E: Exception do Error:=E.Message; end;
  finally if Succeeded(HR) then CoUninitialize; end;
end;

constructor TReaderPageThread.Create(Reader: TReaderRaster; Page: Integer);
begin inherited Create(True); FreeOnTerminate:=False; FReader:=Reader; Index:=Page; end;

procedure TReaderPageThread.Execute;
var HR: HRESULT;
begin
  HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try
    try FReader.PreparePage(Index); except on E: Exception do Error:=E.Message; end;
  finally if Succeeded(HR) then CoUninitialize; end;
end;

constructor TfrmBuiltinReader.Create(AOwner: TComponent);
var SearchRow, OptionsRow: TPanel; Button: TButton;
  procedure SearchButton(const Text: string; Width: Integer; Handler: TNotifyEvent);
  begin
    Button:=TButton.Create(Self); Button.Parent:=SearchRow; Button.Align:=alRight;
    Button.Width:=Width; Button.Caption:=Text; Button.OnClick:=Handler; Button.TabStop:=False;
  end;
  function SearchCheck(const Text: string; Width: Integer): TCheckBox;
  begin
    Result:=TCheckBox.Create(Self); Result.Parent:=OptionsRow; Result.Align:=alLeft;
    Result.Left:=MaxInt; Result.Width:=Width; Result.Caption:=Text; Result.OnClick:=SearchOptionsClick;
  end;
begin
  inherited CreateNew(AOwner);
  Caption:='HomeLib Ru — Читалка (экспериментальная)';
  Position:=poScreenCenter; SetBounds(0,0,820,680); FRestoredBounds:=BoundsRect;
  Constraints.MinWidth:=520; Constraints.MinHeight:=360;
  Font.Name:='Segoe UI'; Font.Size:=9; KeyPreview:=True; DoubleBuffered:=True;
  FFontSize:=14; FFontName:='Georgia'; FLinePercent:=110; FMargin:=32;
  FPDFMatchPage:=-1; FPDFMatchIndex:=-1;
  FTextMatch:=-1; FHighlightColor:=$0080E5FF; FHighlighted:=TList<TPoint>.Create;
  FZoom:=100; FPages:=TList<Integer>.Create; FPages.Add(0);
  FBitmap:=TBitmap.Create; FBitmap.PixelFormat:=pf32bit;
  FTop:=TPanel.Create(Self); FTop.Parent:=Self; FTop.Align:=alTop; FTop.Height:=70; FTop.BevelOuter:=bvNone;
  FButtons:=TPanel.Create(Self); FButtons.Parent:=FTop; FButtons.Align:=alTop; FButtons.Height:=38; FButtons.BevelOuter:=bvNone;
  MakeButton('‹',PreviousClick,30); MakeButton('›',NextClick,30);
  MakeButton('−',SmallerClick,30); MakeButton('+',BiggerClick,30);
  FThemes:=TComboBox.Create(Self); FThemes.Parent:=FButtons; FThemes.Align:=alLeft;
  FThemes.Left:=MaxInt; FThemes.Width:=90; FThemes.Style:=csDropDownList;
  FThemes.Items.Text:='Светлая'+#13+'Бумага'+#13+'Сепия'+#13+'Серая'+#13+'Тёмная'+#13+'Ночь';
  FThemes.ItemIndex:=0; FThemes.OnChange:=ThemeClick; FThemes.ShowHint:=True;
  FThemes.Hint:='Цветовая тема; для PDF тёмные темы включают инверсию страниц';
  MakeButton('Закладки',BookmarkClick,80);
  MakeButton('Текст',StyleClick,50);
  MakeButton('Поиск',SearchClick,50); MakeButton('F11',FullScreenClick,50);
  FChapters:=TComboBox.Create(Self); FChapters.Parent:=FTop; FChapters.Align:=alClient;
  FChapters.TextHint:='Содержание книги'; FChapters.Style:=csDropDownList; FChapters.OnChange:=ChapterClick; FChapters.Hint:='Содержание книги'; FChapters.ShowHint:=True;
  FBottom:=TPanel.Create(Self); FBottom.Parent:=Self; FBottom.Align:=alBottom; FBottom.Height:=28; FBottom.BevelOuter:=bvNone;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=FBottom; FStatus.Align:=alClient; FStatus.Layout:=tlCenter; FStatus.Alignment:=taCenter;
  FStatus.Caption:='Колесо — страницы · Ctrl+колесо — размер · F11 — весь экран · Ctrl+F — поиск';
  FSearchPanel:=TPanel.Create(Self); FSearchPanel.Parent:=Self; FSearchPanel.Align:=alTop; FSearchPanel.Height:=66; FSearchPanel.Visible:=False;
  SearchRow:=TPanel.Create(Self); SearchRow.Parent:=FSearchPanel; SearchRow.Align:=alTop; SearchRow.Height:=32; SearchRow.BevelOuter:=bvNone;
  SearchButton('×',28,SearchCloseClick); SearchButton('Далее',65,SearchNextClick); SearchButton('Назад',65,SearchPreviousClick);
  FSearch:=TEdit.Create(Self); FSearch.Parent:=SearchRow; FSearch.Align:=alClient; FSearch.TextHint:='Найти… Enter / Shift+Enter'; FSearch.OnKeyDown:=SearchKey;
  OptionsRow:=TPanel.Create(Self); OptionsRow.Parent:=FSearchPanel; OptionsRow.Align:=alClient; OptionsRow.BevelOuter:=bvNone;
  FSearchCase:=SearchCheck('Регистр',78); FSearchWord:=SearchCheck('Слово целиком',118);
  FSearchAll:=SearchCheck('Подсветить все',122);
  Button:=TButton.Create(Self); Button.Parent:=OptionsRow; Button.Align:=alLeft; Button.Left:=MaxInt;
  Button.Width:=64; Button.Caption:='Цвет…'; Button.OnClick:=SearchColorClick;
  FSurface:=TReaderSurface.Create(Self); FSurface.Parent:=Self; FSurface.Align:=alClient; FSurface.FReader:=Self;
  FSurface.DoubleBuffered:=True; FSurface.TabStop:=True;
  // Start with page keys ready; the contents selector keeps its own keys after a click.
  ActiveControl:=FSurface;
  FRichEdit:=TRichEdit.Create(Self);
  // This hidden formatting buffer must survive showing, scaling and restyling
  // the reader form: recreating a VCL child would discard its OLE pictures.
  FFormattingHost:=TForm.CreateNew(Self); FFormattingHost.Scaled:=False;
  FRichEdit.Parent:=FFormattingHost; FRichEdit.Visible:=False;
  FRichEdit.ReadOnly:=True; FRichEdit.PlainText:=False; FRichEdit.MaxLength:=MAXINT;
  // Only EM_FORMATRANGE paginates this hidden buffer; skip its narrow on-screen wrapping.
  FRichEdit.WordWrap:=False;
  FOleCallback:=AttachReaderPictures(FRichEdit);
  FResizeTimer:=TTimer.Create(Self); FResizeTimer.Enabled:=False; FResizeTimer.Interval:=140; FResizeTimer.OnTimer:=ResizePage;
  FPageTimer:=TTimer.Create(Self); FPageTimer.Enabled:=False; FPageTimer.Interval:=30; FPageTimer.OnTimer:=PageLoaded;
  FSearchTimer:=TTimer.Create(Self); FSearchTimer.Enabled:=False; FSearchTimer.Interval:=1; FSearchTimer.OnTimer:=SearchTick;
  FBookmarks:=TPopupMenu.Create(Self);
  OnKeyDown:=KeyReader; OnResize:=ScheduleResize; OnClose:=CloseReader;
end;

procedure TfrmBuiltinReader.MakeButton(const Caption: string; Action: TNotifyEvent; Width: Integer);
var Button: TButton;
begin
  Button:=TButton.Create(Self); Button.Parent:=FButtons; Button.Align:=alLeft;
  Button.Left:=MaxInt; Button.Width:=Width; Button.Caption:=Caption; Button.OnClick:=Action;
  Button.TabStop:=False;
  if Caption='Ночь' then begin Button.Hint:='Ночной фон текста / инверсия страниц PDF'; Button.ShowHint:=True; end;
  if Caption='F11' then begin Button.Hint:='На весь экран / вернуть окно'; Button.ShowHint:=True; end;
end;

destructor TfrmBuiltinReader.Destroy;
begin
  FClosing:=True; FreeAndNil(FLoadStatus);
  FPageTimer.Enabled:=False;
  if Assigned(FPageWorker) then begin FPageWorker.Terminate; FPageWorker.WaitFor; FreeAndNil(FPageWorker); end;
  FreeAndNil(FPageStatus);
  FSearchTimer.Enabled:=False;
  if Assigned(FLoader) then begin FLoader.OnTerminate:=nil; FLoader.Terminate; FLoader.WaitFor; FreeAndNil(FLoader); end;
  FSurface.FReader:=nil;
  FPDF.Free; FDocument.Free; FBitmap.Free; FPages.Free; FHighlighted.Free; inherited;
end;

procedure TfrmBuiltinReader.OpenBook(const FileName, BookTitle, Identity, SettingsFile, PDFLibrary: string;
  const OnProgress: TProc<Integer>);
var Stream: TFileStream; Chapter: TPDFChapter;
begin
  FFileName:=FileName; FIdentity:=Copy(THashSHA2.GetHashString(Identity),1,40);
  FSettingsFile:=SettingsFile; FOnProgress:=OnProgress;
  Caption:='HomeLib Ru — '+BookTitle+' — Читалка (экспериментальная)';
  RestoreSettings;
  if SameText(ExtractFileExt(FileName),'.pdf') then
  begin
    FPDF:=TReaderPDF.Create(PDFLibrary,FileName); FLength:=FPDF.PageCount;
    for Chapter in FPDF.Chapters do
      FChapters.Items.AddObject(StringOfChar(' ',Chapter.Depth*2)+Chapter.Title,
        TObject(NativeInt(Chapter.Page)));
    FReady:=True; FLoadFinished:=True; RestoreSettings; RenderPage;
  end
  else if SameText(ExtractFileExt(FileName),'.rtf') then
  begin
    Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size>64*1024*1024 then raise Exception.Create('RTF слишком велик.');
      FOleCallback:=AttachReaderPictures(FRichEdit);
      ReaderLoadRTF(FRichEdit,Stream);
    finally Stream.Free; end;
    FLength:=ReaderTextLength(FRichEdit); FReady:=True; FLoadFinished:=True; InvalidateLayout; RestoreSettings; RenderPage;
  end
  else
  begin
    FStatus.Caption:='Открытие книги…';
    FLoadStatus:=TMHLOperationStatus.Create('Подготовка текста и изображений книги…');
    FLoader:=TReaderLoadThread.Create(FileName); FLoader.OnTerminate:=LoaderFinished; FLoader.Start;
  end;
end;

procedure TfrmBuiltinReader.LoaderFinished(Sender: TObject);
var C: TReaderChapter; Chapter: TPDFChapter; SavedPage: Integer;
begin
  if FClosing then Exit;
  FLoadFinished:=True; FreeAndNil(FLoadStatus);
  if FLoader.Error<>'' then
  begin FStatus.Caption:=FLoader.Error; FSurface.Invalidate; Exit; end;
  try
  if Assigned(FLoader.Pages) then
  begin
    FPDF:=FLoader.Pages; FLoader.Pages:=nil; FLength:=FPDF.PageCount;
    for Chapter in FPDF.Chapters do FChapters.Items.AddObject(Chapter.Title,TObject(NativeInt(Chapter.Page)));
    FReady:=True; RestoreSettings; SavedPage:=FPage; FPage:=0; FRequestedPage:=0;
    RenderPage;
    if SavedPage<>0 then RequestPage(SavedPage,False);
    Exit;
  end;
  FDocument:=FLoader.Document; FLoader.Document:=nil;
  LoadPresentation;
  FLength:=ReaderTextLength(FRichEdit);
  for C in FDocument.Chapters do FChapters.Items.AddObject(C.Title,TObject(NativeInt(C.Position)));
  FDocument.ReleaseUnusedBuffers;
  FReady:=True; InvalidateLayout; RestoreSettings; RenderPage;
  except
    on E: Exception do
    begin FReady:=False; FStatus.Caption:='Не удалось открыть книгу: '+E.Message; FSurface.Invalidate; end;
  end;
end;

function TfrmBuiltinReader.PageLoading: Boolean;
begin Result:=Assigned(FPageWorker); end;

procedure TfrmBuiltinReader.RequestPage(Index: Integer; Moved: Boolean);
begin
  if not FReady or FClosing or not (FPDF is TReaderRaster) then Exit;
  FRequestedPage:=EnsureRange(Index,0,FPDF.PageCount-1);
  FRequestedMoved:=Moved;
  if Assigned(FPageWorker) then Exit;
  if FRequestedPage=FPage then Exit;
  ResetInspection; FSearchStatus:='';
  FStatus.Caption:=Format('Открытие страницы %d из %d…',[FRequestedPage+1,FPDF.PageCount]);
  if not Assigned(FPageStatus) then FPageStatus:=TMHLOperationStatus.Create('Открытие страницы комикса или изображения…');
  FPageWorker:=TReaderPageThread.Create(TReaderRaster(FPDF),FRequestedPage);
  FPageWorker.Navigated:=FRequestedMoved;
  FPageTimer.Enabled:=True; FPageWorker.Start;
end;

procedure TfrmBuiltinReader.PageLoaded(Sender: TObject);
var Index: Integer; Error: string; Moved: Boolean;
begin
  if not Assigned(FPageWorker) or (WaitForSingleObject(FPageWorker.Handle,0)<>WAIT_OBJECT_0) then Exit;
  Index:=FPageWorker.Index; Error:=FPageWorker.Error; Moved:=FPageWorker.Navigated;
  FreeAndNil(FPageWorker); FPageTimer.Enabled:=False;
  FreeAndNil(FPageStatus);
  // Commit the decoded page before starting a newer wheel request. Painting
  // always uses its own finished raster while the next original is decoded.
  if Error='' then
  begin
    FPage:=Index; FReadingMoved:=FReadingMoved or Moved;
    try RenderPage; except on E: Exception do Error:=E.Message; end;
  end;
  if FRequestedPage<>Index then RequestPage(FRequestedPage,FRequestedMoved)
  else
  begin
    if Error<>'' then
    begin FStatus.Caption:='Не удалось открыть страницу: '+Error; end;
  end;
end;

procedure TfrmBuiltinReader.LoadPresentation;
var Stream: TReaderRTFStream;
begin
  FImageWidth:=Max(16,FSurface.ClientWidth-FMargin*2-16);
  FImageHeight:=Max(16,FSurface.ClientHeight-80);
  Stream:=TReaderRTFStream.Create(FDocument.RTF(FImageWidth,FImageHeight));
  try
    // Showing or scaling the form can recreate the native edit handle.
    // Bind picture storage to the current handle before every RTF stream.
    FOleCallback:=AttachReaderPictures(FRichEdit);
    ReaderLoadRTF(FRichEdit,Stream);
  finally Stream.Free; end;
end;

function TfrmBuiltinReader.CurrentPosition: Integer;
begin
  if Assigned(FPDF) then Result:=FPage
  else if (FPage>=0) and (FPage<FPages.Count) then Result:=FPages[FPage] else Result:=0;
end;

function TfrmBuiltinReader.BookText: string;
begin Result:=ReaderTextRange(FRichEdit,0,FLength); end;

function TfrmBuiltinReader.PictureCount: Integer;
begin Result:=ReaderPictureCount(FRichEdit); end;

function TfrmBuiltinReader.PageRasterSize: TPoint;
begin Result:=Point(FBitmap.Width,FBitmap.Height); end;

function TfrmBuiltinReader.PageBackground: TColor;
begin Result:=FBitmap.Canvas.Pixels[10,10]; end;

function TfrmBuiltinReader.FormatText(Start, Finish: Integer; Draw: Boolean): Integer;
var Range: TFormatRange; DPI: Integer;
begin
  FillChar(Range,SizeOf(Range),0); DPI:=GetDeviceCaps(FBitmap.Canvas.Handle,LOGPIXELSY);
  Range.hdc:=FBitmap.Canvas.Handle; Range.hdcTarget:=Range.hdc;
  Range.rcPage:=Rect(0,0,MulDiv(FBitmap.Width,1440,DPI),MulDiv(FBitmap.Height,1440,DPI));
  Range.rc:=Range.rcPage; InflateRect(Range.rc,-MulDiv(FMargin,1440,96),-MulDiv(20,1440,96));
  Range.chrg.cpMin:=Start; Range.chrg.cpMax:=Finish;
  try Result:=SendMessage(FRichEdit.Handle,EM_FORMATRANGE,Ord(Draw),LPARAM(@Range));
  finally SendMessage(FRichEdit.Handle,EM_FORMATRANGE,0,0); end;
end;

procedure TfrmBuiltinReader.ResetInspection;
begin
  if not FInspect then Exit;
  FInspect:=False; FZoom:=FInspectZoom; FSurface.Cursor:=crDefault;
end;

procedure TfrmBuiltinReader.ToggleInspection(X,Y: Integer);
begin
  if FInspect then begin EndInspection; Exit; end;
  if not FReady or not Assigned(FPDF) or PageLoading or (FBitmap.Width=0) or
    not PtInRect(Rect(FPan.X,FPan.Y,FPan.X+FBitmap.Width,FPan.Y+FBitmap.Height),Point(X,Y)) then Exit;
  FInspectZoom:=FZoom; FInspectPan:=FPan; FInspectSize:=Point(FBitmap.Width,FBitmap.Height);
  FZoom:=Min(300,Max(200,FZoom*2));
  try RenderPage; except FZoom:=FInspectZoom; raise; end;
  FInspect:=True; FSurface.Cursor:=crSizeAll;
  MoveInspection(X,Y);
end;

procedure TfrmBuiltinReader.MoveInspection(X,Y: Integer);
var PX,PY: Double;
begin
  if not FInspect or PageLoading then Exit;
  PX:=EnsureRange((X-FInspectPan.X)/Max(1,FInspectSize.X),0.0,1.0);
  PY:=EnsureRange((Y-FInspectPan.Y)/Max(1,FInspectSize.Y),0.0,1.0);
  FPan:=Point(X-Round(PX*FBitmap.Width),Y-Round(PY*FBitmap.Height));
  ClampPan; FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.EndInspection;
begin
  if not FInspect then Exit;
  ResetInspection; RenderPage; FPan:=FInspectPan; ClampPan; FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.RenderPage;
var Size: TPoint; Scale: Double; Temporary: TBitmap; W,H,I: Integer; Match: TPDFMatch;
  procedure MarkPDF(const Rectangles: TArray<TRectF>);
  var R: TRectF; Box: TRect; X,Y: Integer; Pixel: PRGBQuad; Color: Cardinal;
  begin
    Color:=ColorToRGB(FHighlightColor); GdiFlush;
    for R in Rectangles do
    begin
      Box:=Rect(Max(0,Round(R.Left*W/Size.X)-2),Max(0,Round((Size.Y-R.Bottom)*H/Size.Y)-2),
        Min(W,Round(R.Right*W/Size.X)+2),Min(H,Round((Size.Y-R.Top)*H/Size.Y)+2));
      for Y:=Box.Top to Box.Bottom-1 do
      begin
        // VCL DIB scanlines run bottom to top; PDF rectangles are screen coordinates.
        Pixel:=FBitmap.ScanLine[H-1-Y]; Inc(Pixel,Box.Left);
        for X:=Box.Left to Box.Right-1 do
        begin
          Pixel.rgbRed:=(Integer(Pixel.rgbRed)*2+GetRValue(Color)) div 3;
          Pixel.rgbGreen:=(Integer(Pixel.rgbGreen)*2+GetGValue(Color)) div 3;
          Pixel.rgbBlue:=(Integer(Pixel.rgbBlue)*2+GetBValue(Color)) div 3; Inc(Pixel);
        end;
      end;
    end;
  end;
begin
  if not FReady or FClosing or Assigned(FPageWorker) or (FSurface.ClientWidth<100) or (FSurface.ClientHeight<100) then Exit;
  if Assigned(FPDF) then
  begin
    FPage:=EnsureRange(FPage,0,FPDF.PageCount-1); Size:=FPDF.PageSize(FPage);
    Scale:=Min((FSurface.ClientWidth-24)/Size.X,(FSurface.ClientHeight-24)/Size.Y)*FZoom/100;
    // Keep even 300% on a large display within the PDF bitmap budget.
    Scale:=Min(Scale,Sqrt(24000000.0/(Double(Size.X)*Size.Y)));
    W:=Max(1,Round(Size.X*Scale)); H:=Max(1,Round(Size.Y*Scale));
    Temporary:=FPDF.Render(FPage,W,H,FNight);
    // Transfer the finished page, keeping the old raster until rendering succeeds.
    FBitmap.Free; FBitmap:=Temporary;
    if FSearchAll.Checked and (FPDFQuery<>'') then
    begin
      for Match in FPDF.FindAllOnPage(FPage,FPDFQuery,FSearchCase.Checked,FSearchWord.Checked) do
        MarkPDF(Match.Rects);
    end
    else if FPDFMatchPage=FPage then MarkPDF(FPDFRects);
    FPan:=Point(Max(0,(FSurface.ClientWidth-W) div 2),Max(0,(FSurface.ClientHeight-H) div 2));
    FStatus.Caption:=Format('%s · Страница %d из %d · Масштаб %d%% · Щелчок — приблизить; Esc — вернуть',[FPDF.DisplayName,FPage+1,FPDF.PageCount,FZoom]);
  end
  else
  begin
    FBitmap.SetSize(FSurface.ClientWidth,FSurface.ClientHeight);
    FBitmap.Canvas.Brush.Color:=ThemeBackground;
    FBitmap.Canvas.FillRect(Rect(0,0,FBitmap.Width,FBitmap.Height));
    ClearTextHighlights;
    if FSearchQuery<>'' then
    begin FNext:=FormatText(CurrentPosition,-1,False); HighlightTextPage; end;
    FNext:=FormatText(CurrentPosition,-1,True);
    FStatus.Caption:=Format('%d%% · Шрифт %d · Колесо — страницы · Ctrl+колесо — размер',[Min(100,Round(CurrentPosition*100/Max(1,FLength))),FFontSize]);
    if Assigned(FDocument) and (FDocument.SkippedImages>0) then FStatus.Caption:=FStatus.Caption+' · Изображений пропущено: '+IntToStr(FDocument.SkippedImages);
  end;
  for I:=FChapters.Items.Count-1 downto 0 do
    if NativeInt(FChapters.Items.Objects[I])<=CurrentPosition then
    begin FChapters.ItemIndex:=I; Break; end;
  if FSearchStatus<>'' then FStatus.Caption:=FSearchStatus;
  FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.PaintPage(Canvas: TCanvas);
begin
  Canvas.Brush.Color:=ThemeBackground;
  Canvas.FillRect(FSurface.ClientRect);
  if FReady then
  begin if Assigned(FPDF) then Canvas.Draw(FPan.X,FPan.Y,FBitmap) else Canvas.Draw(0,0,FBitmap); end
  else
    begin Canvas.Font.Assign(Font); Canvas.Font.Color:=ThemeText; Canvas.TextOut(24,24,FStatus.Caption); end;
end;

procedure TfrmBuiltinReader.InvalidateLayout;
var Position: Integer; Para: TParaFormat2; Characters: TCharFormat2;
begin
  if not FReady then Exit;
  Position:=CurrentPosition;
  if not Assigned(FPDF) then
  begin
    if Assigned(FDocument) and (FDocument.ImageCount>0) and
      ((FImageWidth<>Max(16,FSurface.ClientWidth-FMargin*2-16)) or
       (FImageHeight<>Max(16,FSurface.ClientHeight-80))) then LoadPresentation;
    FRichEdit.SelectAll;
    // Apply face/size/color together, preserving bold and italic source runs.
    FillChar(Characters,SizeOf(Characters),0); Characters.cbSize:=SizeOf(Characters);
    Characters.dwMask:=CFM_SIZE or CFM_FACE or CFM_COLOR; Characters.yHeight:=FFontSize*20;
    StrPLCopy(PChar(@Characters.szFaceName[0]),FFontName,LF_FACESIZE-1);
    Characters.crTextColor:=ThemeText;
    SendMessage(FRichEdit.Handle,EM_SETCHARFORMAT,SCF_ALL,LPARAM(@Characters));
    FillChar(Para,SizeOf(Para),0); Para.cbSize:=SizeOf(Para);
    Para.dwMask:=$00000100; Para.bLineSpacingRule:=5; Para.dyLineSpacing:=FLinePercent div 5;
    SendMessage(FRichEdit.Handle,EM_SETPARAFORMAT,0,LPARAM(@Para));
    FRichEdit.Color:=ThemeBackground;
    FRichEdit.SelLength:=0;
    FPages.Clear; FPages.Add(Position); FPage:=0;
  end;
  RenderPage;
end;

procedure TfrmBuiltinReader.NextPage;
begin
  if not FReady then Exit;
  if FPDF is TReaderRaster then
  begin
    RequestPage(FRequestedPage+1);
    Exit;
  end;
  ResetInspection;
  if Assigned(FPDF) then begin if FPage>=FPDF.PageCount-1 then Exit; Inc(FPage); end
  else
  begin
    if (FNext<=CurrentPosition) or (FNext>=FLength) then Exit;
    Inc(FPage); if FPage>=FPages.Count then FPages.Add(FNext);
  end;
  FSearchStatus:=''; FReadingMoved:=True; RenderPage;
end;

procedure TfrmBuiltinReader.PreviousPage;
var L,H,M,Target,Start,Index: Integer; S: string;
begin
  if not FReady then Exit;
  if FPDF is TReaderRaster then
  begin
    RequestPage(FRequestedPage-1);
    Exit;
  end;
  ResetInspection;
  if Assigned(FPDF) then begin if FPage<=0 then Exit; Dec(FPage); end
  else if FPage>0 then Dec(FPage)
  else
  begin
    Target:=CurrentPosition; if Target=0 then Exit;
    L:=Max(0,Target-100000); H:=Target;
    while L<H do
    begin M:=L+(H-L) div 2; if FormatText(M,Target,False)>=Target then H:=M else L:=M+1; end;
    Start:=L; Index:=1;
    S:=ReaderTextRange(FRichEdit,Max(0,Start-1),Min(4096,Target-Start+1));
    while (Start<Target) and (Start>0) and (Index<=Length(S)) and not CharInSet(S[Index],[#13,' ']) do
    begin Inc(Start); Inc(Index); end;
    // A paragraph may have no word boundary (CJK, a long URL or one word).
    // Keep the fitted page start instead of moving all the way to Target.
    if (Start>=Target) or (Index>Length(S)) then Start:=Min(L,Target-1);
    Start:=ReaderCharacterStart(FRichEdit,Start);
    FPages.Insert(0,Start);
  end;
  FSearchStatus:=''; FReadingMoved:=True; RenderPage;
end;

procedure TfrmBuiltinReader.NavigateTo(Position: Integer);
begin
  if not FReady then Exit;
  if FPDF is TReaderRaster then begin RequestPage(Position); Exit; end;
  ResetInspection;
  if Assigned(FPDF) then Position:=EnsureRange(Position,0,FPDF.PageCount-1)
  else Position:=EnsureRange(Position,0,Max(0,FLength-1));
  if Position=CurrentPosition then Exit;
  if Assigned(FPDF) then FPage:=Position
  else begin FPages.Clear; FPages.Add(Position); FPage:=0; end;
  FSearchStatus:=''; FReadingMoved:=True; RenderPage;
end;

procedure TfrmBuiltinReader.ChangeSize(Delta: Integer);
var NewSize: Integer;
begin
  ResetInspection;
  if Assigned(FPDF) then
  begin NewSize:=EnsureRange(FZoom+Delta*10,50,300); if NewSize=FZoom then Exit; FZoom:=NewSize; end
  else
  begin NewSize:=EnsureRange(FFontSize+Delta,8,48); if NewSize=FFontSize then Exit; FFontSize:=NewSize; end;
  InvalidateLayout;
end;

procedure TfrmBuiltinReader.ResizePage(Sender: TObject);
begin FResizeTimer.Enabled:=False; ResetInspection; InvalidateLayout; end;
procedure TfrmBuiltinReader.ScheduleResize(Sender: TObject);
begin
  if Assigned(FResizeTimer) then
  begin
    FResizeTimer.Enabled:=False;
    if Assigned(FPDF) then FResizeTimer.Interval:=75 else FResizeTimer.Interval:=140;
    FResizeTimer.Enabled:=True;
    if Assigned(FPDF) then begin ClampPan; FSurface.Invalidate; end;
  end;
end;
procedure TfrmBuiltinReader.NextClick(Sender: TObject); begin NextPage; end;
procedure TfrmBuiltinReader.PreviousClick(Sender: TObject); begin PreviousPage; end;
procedure TfrmBuiltinReader.BiggerClick(Sender: TObject); begin ChangeSize(1); end;
procedure TfrmBuiltinReader.SmallerClick(Sender: TObject); begin ChangeSize(-1); end;
procedure TfrmBuiltinReader.ToggleNight;
begin if FNight then SetTheme(0) else SetTheme(5); end;
procedure TfrmBuiltinReader.NightClick(Sender: TObject); begin ToggleNight; end;

function TfrmBuiltinReader.ThemeBackground: TColor;
const Colors: array[0..5] of TColor = ($00F4F7FB,$00DDECF5,$00C5DBEC,$00E4E4E4,$002B2927,$00222222);
begin Result:=Colors[EnsureRange(FTheme,0,5)]; end;

function TfrmBuiltinReader.ThemeText: TColor;
const Colors: array[0..5] of TColor = ($00202020,$002E343A,$00353B44,$00252525,$00B8C3CE,$00DCE1E8);
begin Result:=Colors[EnsureRange(FTheme,0,5)]; end;

procedure TfrmBuiltinReader.SetTheme(Index: Integer);
begin
  Index:=EnsureRange(Index,0,5); if Index=FTheme then Exit;
  FTheme:=Index; FThemes.ItemIndex:=Index; FNight:=Index>=4; InvalidateLayout;
end;

procedure TfrmBuiltinReader.ThemeClick(Sender: TObject);
begin SetTheme(FThemes.ItemIndex); FSurface.SetFocus; end;

procedure TfrmBuiltinReader.ClampPan;
begin
  if FBitmap.Width<=FSurface.ClientWidth then FPan.X:=(FSurface.ClientWidth-FBitmap.Width) div 2
  else FPan.X:=EnsureRange(FPan.X,FSurface.ClientWidth-FBitmap.Width,0);
  if FBitmap.Height<=FSurface.ClientHeight then FPan.Y:=(FSurface.ClientHeight-FBitmap.Height) div 2
  else FPan.Y:=EnsureRange(FPan.Y,FSurface.ClientHeight-FBitmap.Height,0);
end;

function TfrmBuiltinReader.VisibleHighlightCount: Integer;
begin Result:=FHighlighted.Count; end;

procedure TfrmBuiltinReader.ClearTextHighlights;
var Range: TPoint; Style: TCharFormat2;
begin
  FillChar(Style,SizeOf(Style),0); Style.cbSize:=SizeOf(Style);
  Style.dwMask:=CFM_BACKCOLOR or CFM_COLOR; Style.dwEffects:=CFE_AUTOBACKCOLOR;
  Style.crTextColor:=ThemeText;
  for Range in FHighlighted do
  begin
    FRichEdit.SelStart:=Range.X; FRichEdit.SelLength:=Range.Y;
    SendMessage(FRichEdit.Handle,EM_SETCHARFORMAT,SCF_SELECTION,LPARAM(@Style));
  end;
  FRichEdit.SelLength:=0; FHighlighted.Clear;
end;

procedure TfrmBuiltinReader.HighlightTextPage;
var At, P: Integer; Style: TCharFormat2;
  procedure Mark(Start, Count: Integer);
  begin
    FRichEdit.SelStart:=Start; FRichEdit.SelLength:=Count;
    SendMessage(FRichEdit.Handle,EM_SETCHARFORMAT,SCF_SELECTION,LPARAM(@Style));
    FHighlighted.Add(Point(Start,Count));
  end;
begin
  FillChar(Style,SizeOf(Style),0); Style.cbSize:=SizeOf(Style);
  Style.dwMask:=CFM_BACKCOLOR or CFM_COLOR; Style.crBackColor:=ColorToRGB(FHighlightColor);
  Style.crTextColor:=clBlack;
  if FSearchAll.Checked then
  begin
    At:=CurrentPosition;
    while (At<FNext) and (FHighlighted.Count<1000) do
    begin
      P:=FindTextRange(FSearchQuery,At,FNext,False); if P<0 then Break;
      Mark(P,Length(FSearchQuery)); At:=P+Max(1,Length(FSearchQuery));
    end;
  end
  else if (FTextMatch>=CurrentPosition) and (FTextMatch<FNext) and (FTextMatchLength>0) then Mark(FTextMatch,FTextMatchLength);
  FRichEdit.SelLength:=0;
end;

function TfrmBuiltinReader.FindTextRange(const Query: string; Start, Finish: Integer; Backward: Boolean): Integer;
type TUnicodeFind = record Range: TCharRange; Text: PWideChar; Found: TCharRange; end;
var Search: TUnicodeFind; Flags: Cardinal;
begin
  FillChar(Search,SizeOf(Search),0); Search.Range.cpMin:=Start; Search.Range.cpMax:=Finish;
  Search.Text:=PWideChar(Query); Flags:=0;
  if not Backward then Flags:=Flags or FR_DOWN;
  if FSearchCase.Checked then Flags:=Flags or FR_MATCHCASE;
  if FSearchWord.Checked then Flags:=Flags or FR_WHOLEWORD;
  Result:=SendMessage(FRichEdit.Handle,EM_FINDTEXTEXW,Flags,LPARAM(@Search));
end;
procedure TfrmBuiltinReader.BookmarkClick(Sender: TObject);
var Ini: TMemIniFile; Item: TMenuItem; I, Count: Integer; Point: TPoint;
begin
  if not FReady or (FSettingsFile='') then Exit;
  FBookmarks.Items.Clear;
  Item:=TMenuItem.Create(FBookmarks); Item.Caption:='Добавить закладку здесь'; Item.OnClick:=BookmarkSaveClick;
  FBookmarks.Items.Add(Item);
  Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    Count:=EnsureRange(Ini.ReadInteger('Bookmarks.'+FIdentity,'Count',0),0,100);
    if Count>0 then
    begin Item:=TMenuItem.Create(FBookmarks); Item.Caption:='-'; FBookmarks.Items.Add(Item); end;
    for I:=0 to Count-1 do
    begin
      Item:=TMenuItem.Create(FBookmarks); Item.Tag:=I;
      Item.Caption:=Ini.ReadString('Bookmarks.'+FIdentity,'Title'+IntToStr(I),'Закладка '+IntToStr(I+1));
      Item.OnClick:=BookmarkOpenClick; FBookmarks.Items.Add(Item);
    end;
  finally Ini.Free; end;
  Point:=Mouse.CursorPos; FBookmarks.Popup(Point.X,Point.Y);
end;

procedure TfrmBuiltinReader.BookmarkSaveClick(Sender: TObject); begin AddBookmark; end;
procedure TfrmBuiltinReader.BookmarkOpenClick(Sender: TObject); begin GoToBookmark(TMenuItem(Sender).Tag); end;

procedure TfrmBuiltinReader.AddBookmark;
var Ini: TMemIniFile; Section, Title, Text: string; I, Count: Integer;
begin
  if not FReady or (FSettingsFile='') then Exit;
  Section:='Bookmarks.'+FIdentity;
  Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    Count:=EnsureRange(Ini.ReadInteger(Section,'Count',0),0,100);
    for I:=0 to Count-1 do
      if Ini.ReadInteger(Section,'Position'+IntToStr(I),-1)=CurrentPosition then
      begin FStatus.Caption:='На этой странице уже есть закладка.'; Exit; end;
    if Count>=100 then begin FStatus.Caption:='В этой книге уже сохранено 100 закладок.'; Exit; end;
    if Assigned(FPDF) then Title:='Страница '+IntToStr(FPage+1)
    else
    begin
      Text:=ReaderTextRange(FRichEdit,CurrentPosition,65);
      Title:=IntToStr(Round(CurrentPosition*100/Max(1,FLength)))+'% · '+Text.Replace(#13,' ').Trim;
    end;
    Ini.WriteInteger(Section,'Position'+IntToStr(Count),CurrentPosition);
    Ini.WriteString(Section,'Title'+IntToStr(Count),Title.Replace('&','&&'));
    Ini.WriteInteger(Section,'Count',Count+1); Ini.UpdateFile;
  finally Ini.Free; end;
  FStatus.Caption:='Закладка сохранена. Она доступна в меню «Закладки».';
end;

procedure TfrmBuiltinReader.GoToBookmark(Index: Integer);
var Ini: TMemIniFile; Position, Count: Integer; Section: string;
begin
  if not FReady or (FSettingsFile='') then Exit;
  Section:='Bookmarks.'+FIdentity; Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    Count:=EnsureRange(Ini.ReadInteger(Section,'Count',0),0,100);
    if (Index<0) or (Index>=Count) then Exit;
    Position:=Ini.ReadInteger(Section,'Position'+IntToStr(Index),0);
    NavigateTo(Position);
  finally Ini.Free; end;
end;

procedure TfrmBuiltinReader.SearchClick(Sender: TObject);
begin
  FSearchPanel.Visible:=not FSearchPanel.Visible;
  if FSearchPanel.Visible then FSearch.SetFocus else begin StopSearch; FSurface.SetFocus; end;
end;

procedure TfrmBuiltinReader.SearchKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key=VK_ESCAPE then begin StopSearch; FSearchPanel.Visible:=False; FSurface.SetFocus; Key:=0; Exit; end;
  if (Key<>VK_RETURN) or (FSearch.Text='') then Exit;
  FindText(FSearch.Text,ssShift in Shift);
  Key:=0;
end;

procedure TfrmBuiltinReader.FindText(const Query: string; Backward: Boolean);
var P, Start: Integer; RepeatQuery: Boolean;
begin
  StopSearch;
  if not FReady or (Query='') then Exit;
  if Assigned(FPDF) and not FPDF.HasTextSearch then
  begin ShowSearchStatus('В этом формате нет текстового слоя. Поиск недоступен.'); Exit; end;
  FSearchStatus:='';
  RepeatQuery:=FSearchQuery=Query;
  FSearchQuery:=Copy(Query,1,1024); FSearch.Text:=FSearchQuery;
  FSearchBackward:=Backward;
  if Assigned(FPDF) then
  begin
    FSearchPage:=FPage; FSearchStart:=0; FSearchVisited:=0;
    if Backward then FSearchStart:=-1;
    if RepeatQuery and (FPDFQuery=FSearchQuery) and (FPDFMatchPage=FPage) then
      if Backward then
      begin
        FSearchStart:=FPDFMatchIndex-1;
        if FPDFMatchIndex=0 then
        begin FSearchPage:=(FPage+FPDF.PageCount-1) mod FPDF.PageCount; FSearchStart:=-1; end;
      end
      else FSearchStart:=FPDFMatchIndex+1;
    ShowSearchStatus('Поиск в PDF… Esc — отменить'); FSearchTimer.Enabled:=True;
  end
  else
  begin
    Start:=CurrentPosition;
    if RepeatQuery and (FTextMatch>=CurrentPosition) and (FTextMatch<FNext) then
      if Backward then Start:=FTextMatch else Start:=FTextMatch+Max(1,FTextMatchLength);
    if Backward then
    begin
      P:=FindTextRange(FSearchQuery,Start,0,True);
      if P<0 then P:=FindTextRange(FSearchQuery,FLength,0,True);
    end
    else
    begin
      P:=FindTextRange(FSearchQuery,Start,FLength,False);
      if P<0 then P:=FindTextRange(FSearchQuery,0,FLength,False);
    end;
    FTextMatch:=P; FTextMatchLength:=0;
    if P>=0 then
    begin
      FTextMatchLength:=Length(FSearchQuery);
      if (P>=CurrentPosition) and (P<FNext) then RenderPage else NavigateTo(P);
      ShowSearchStatus('Найдено · Enter / F3 — далее · Shift+Enter / Shift+F3 — назад');
    end
    else begin RenderPage; ShowSearchStatus('Текст не найден.'); end;
  end;
end;

procedure TfrmBuiltinReader.SearchPreviousClick(Sender: TObject);
begin FindText(FSearch.Text,True); end;
procedure TfrmBuiltinReader.SearchNextClick(Sender: TObject);
begin FindText(FSearch.Text); end;
procedure TfrmBuiltinReader.SearchCloseClick(Sender: TObject);
begin StopSearch; FSearchPanel.Visible:=False; FSurface.SetFocus; end;

procedure TfrmBuiltinReader.SetSearchOptions(MatchCase, WholeWord, AllMatches: Boolean);
begin
  StopSearch; FSearchStatus:='';
  FUpdatingSearch:=True;
  try FSearchCase.Checked:=MatchCase; FSearchWord.Checked:=WholeWord; FSearchAll.Checked:=AllMatches;
  finally FUpdatingSearch:=False; end;
  FTextMatch:=-1; FTextMatchLength:=0; FPDFMatchPage:=-1; FPDFQuery:='';
  RenderPage;
end;

procedure TfrmBuiltinReader.SearchOptionsClick(Sender: TObject);
begin
  if FUpdatingSearch then Exit;
  if Sender=FSearchAll then begin RenderPage; Exit; end;
  StopSearch; FSearchStatus:=''; FTextMatch:=-1; FTextMatchLength:=0; FPDFMatchPage:=-1; FPDFQuery:='';
  FSearchQuery:=''; if FSearch.Text<>'' then FindText(FSearch.Text) else RenderPage;
end;

procedure TfrmBuiltinReader.SetHighlightColor(Value: TColor);
begin FHighlightColor:=ColorToRGB(Value); RenderPage; end;
procedure TfrmBuiltinReader.SearchColorClick(Sender: TObject);
var Dialog: TColorDialog;
begin
  Dialog:=TColorDialog.Create(Self);
  try Dialog.Color:=FHighlightColor; if Dialog.Execute then SetHighlightColor(Dialog.Color);
  finally Dialog.Free; end;
end;

procedure TfrmBuiltinReader.StopSearch;
begin
  if FSearchTimer.Enabled then FSearchStatus:='';
  FSearchTimer.Enabled:=False;
end;
procedure TfrmBuiltinReader.ShowSearchStatus(const Text: string);
begin FSearchStatus:=Text; FStatus.Caption:=Text; end;
function TfrmBuiltinReader.SearchRunning: Boolean;
begin Result:=FSearchTimer.Enabled; end;

procedure TfrmBuiltinReader.SearchTick(Sender: TObject);
var Match: TPDFMatch;
begin
  if FClosing or not Assigned(FPDF) then begin StopSearch; Exit; end;
  try
    if FPDF.FindOnPage(FSearchPage,FSearchQuery,FSearchStart,Match,
      FSearchCase.Checked,FSearchWord.Checked,FSearchBackward) then
    begin
      StopSearch; FPDFQuery:=FSearchQuery; FPDFMatchPage:=FSearchPage;
      FPDFMatchIndex:=Match.Index; FPDFRects:=Match.Rects;
      // A new match on the current page must repaint without counting a page move.
      if FSearchPage=FPage then RenderPage else NavigateTo(FSearchPage);
      ShowSearchStatus('Найдено на странице '+IntToStr(FSearchPage+1)+' · Enter — следующее');
      Exit;
    end;
    Inc(FSearchVisited);
    if FSearchVisited>FPDF.PageCount then
    begin StopSearch; ShowSearchStatus('Текст не найден. В PDF из сканов поиск требует текстового слоя.'); Exit; end;
    if FSearchBackward then
    begin FSearchPage:=(FSearchPage+FPDF.PageCount-1) mod FPDF.PageCount; FSearchStart:=-1; end
    else begin FSearchPage:=(FSearchPage+1) mod FPDF.PageCount; FSearchStart:=0; end;
    ShowSearchStatus(Format('Поиск в PDF · %d из %d страниц · Esc — отменить',[FSearchVisited,FPDF.PageCount]));
  except on E: Exception do begin StopSearch; ShowSearchStatus('Не удалось выполнить поиск: '+E.Message); end; end;
end;

function TfrmBuiltinReader.ChapterCount: Integer;
begin Result:=FChapters.Items.Count; end;
procedure TfrmBuiltinReader.GoToChapter(Index: Integer);
begin
  if (Index<0) or (Index>=FChapters.Items.Count) then Exit;
  FChapters.ItemIndex:=Index; ChapterClick(nil);
end;

procedure TfrmBuiltinReader.SetTypography(const FontName: string; LinePercent, Margin: Integer);
begin
  if FontName.Trim<>'' then FFontName:=Copy(FontName.Trim,1,100);
  FLinePercent:=EnsureRange(LinePercent,100,180); FMargin:=EnsureRange(Margin,12,80);
  InvalidateLayout;
end;

procedure TfrmBuiltinReader.StyleClick(Sender: TObject);
var Dialog: TForm; FontBox, SpacingBox, MarginBox: TComboBox; LabelText: TLabel; Button: TButton;
  procedure AddLabel(const Text: string; Top: Integer);
  begin LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.SetBounds(16,Top,100,22); LabelText.Caption:=Text; end;
  function Choice(Top: Integer): TComboBox;
  begin Result:=TComboBox.Create(Dialog); Result.Parent:=Dialog; Result.SetBounds(118,Top,216,26); Result.Style:=csDropDownList; end;
begin
  if Assigned(FPDF) then begin FStatus.Caption:='В PDF меняется масштаб страницы кнопками −/+ и Ctrl+колесом.'; Exit; end;
  Dialog:=TForm.CreateNew(Self);
  try
    Dialog.Caption:='Текст и поля'; Dialog.BorderStyle:=bsDialog; Dialog.Position:=poOwnerFormCenter;
    Dialog.ClientWidth:=350; Dialog.ClientHeight:=166; Dialog.Font.Assign(Font);
    AddLabel('Шрифт',20); FontBox:=Choice(16); FontBox.Items.Assign(Screen.Fonts); FontBox.ItemIndex:=FontBox.Items.IndexOf(FFontName);
    AddLabel('Интервал, %',58); SpacingBox:=Choice(54); SpacingBox.Items.Text:='100'+#13+'110'+#13+'120'+#13+'130'+#13+'140'+#13+'150'+#13+'160'+#13+'170'+#13+'180';
    SpacingBox.ItemIndex:=SpacingBox.Items.IndexOf(IntToStr(FLinePercent)); if SpacingBox.ItemIndex<0 then SpacingBox.ItemIndex:=1;
    AddLabel('Поля, пикс.',96); MarginBox:=Choice(92); MarginBox.Items.Text:='12'+#13+'20'+#13+'24'+#13+'32'+#13+'40'+#13+'48'+#13+'64'+#13+'80';
    MarginBox.ItemIndex:=MarginBox.Items.IndexOf(IntToStr(FMargin)); if MarginBox.ItemIndex<0 then MarginBox.ItemIndex:=3;
    Button:=TButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(156,130,86,26); Button.Caption:='Применить'; Button.Default:=True; Button.ModalResult:=mrOk;
    Button:=TButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(248,130,86,26); Button.Caption:='Отмена'; Button.Cancel:=True; Button.ModalResult:=mrCancel;
    if Dialog.ShowModal=mrOk then SetTypography(FontBox.Text,StrToIntDef(SpacingBox.Text,110),StrToIntDef(MarginBox.Text,32));
  finally Dialog.Free; end;
end;

procedure TfrmBuiltinReader.ChapterClick(Sender: TObject);
begin
  if FChapters.ItemIndex>=0 then NavigateTo(NativeInt(FChapters.Items.Objects[FChapters.ItemIndex]));
  // OnChange also fires while the native combo is open and arrows select
  // a chapter. Moving focus would close it before the user confirms.
  if Sender<>FChapters then FSurface.SetFocus;
end;

procedure TfrmBuiltinReader.FullScreenClick(Sender: TObject);
begin
  if not FFullScreen then
  begin
    FBeforeFullScreenState:=WindowState;
    if WindowState=wsNormal then FNormalBounds:=BoundsRect else FNormalBounds:=FRestoredBounds;
    BorderStyle:=bsNone; WindowState:=wsMaximized;
  end
  else
  begin
    WindowState:=wsNormal; BorderStyle:=bsSizeable; BoundsRect:=FNormalBounds;
    WindowState:=FBeforeFullScreenState;
  end;
  FFullScreen:=not FFullScreen; FSurface.SetFocus;
end;

procedure TfrmBuiltinReader.KeyReader(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key=VK_F3) and (FSearch.Text<>'') then
  begin FindText(FSearch.Text,ssShift in Shift); Key:=0; Exit; end;
  if FSearch.Focused then Exit;
  if (FChapters.Focused or FThemes.Focused) and ((Key in [VK_UP,VK_DOWN,VK_LEFT,VK_RIGHT,VK_HOME,VK_END,VK_PRIOR,VK_NEXT,VK_SPACE,VK_RETURN]) or
    ((Key=VK_ESCAPE) and (FChapters.DroppedDown or FThemes.DroppedDown))) then Exit;
  if (Key=VK_ESCAPE) and SearchRunning then begin StopSearch; RenderPage; Key:=0; Exit; end;
  if (Key=VK_ESCAPE) and FInspect then begin EndInspection; Key:=0; Exit; end;
  if (ssCtrl in Shift) and (Key=Ord('F')) then begin SearchClick(nil); Key:=0; Exit; end;
  case Key of
    VK_NEXT,VK_RIGHT,VK_DOWN,VK_SPACE: NextPage;
    VK_PRIOR,VK_LEFT,VK_UP: PreviousPage;
    VK_HOME: NavigateTo(0);
    VK_END: NavigateTo(Max(0,FLength-1));
    VK_ADD,VK_OEM_PLUS: ChangeSize(1);
    VK_SUBTRACT,VK_OEM_MINUS: ChangeSize(-1);
    VK_F11: FullScreenClick(nil);
    VK_ESCAPE: if FFullScreen then FullScreenClick(nil) else Close;
  else Exit;
  end;
  Key:=0;
end;

procedure TfrmBuiltinReader.WMWindowPosChanged(var Message: TWMWindowPosChanged);
begin
  inherited;
  // Preserve screen coordinates, including moves that do not resize the window.
  if not FFullScreen and not IsZoomed(Handle) and not IsIconic(Handle) then
    FRestoredBounds:=BoundsRect;
end;

procedure TfrmBuiltinReader.RestoreSettings;
var Ini: TMemIniFile; Bounds,Work: TRect; Position: Integer;
begin
  if FSettingsFile='' then Exit;
  Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    // Loading can finish after the user has already adjusted the reader controls.
    if not FReady then
    begin
      FFontSize:=EnsureRange(Ini.ReadInteger('Reader','FontSize',14),8,48);
      FFontName:=Ini.ReadString('Reader','FontName','Georgia');
      FLinePercent:=EnsureRange(Ini.ReadInteger('Reader','LinePercent',110),100,180);
      FMargin:=EnsureRange(Ini.ReadInteger('Reader','Margin',32),12,80);
      FZoom:=EnsureRange(Ini.ReadInteger('Reader','PDFZoom',100),50,300); FNight:=Ini.ReadBool('Reader','Night',False);
      FTheme:=EnsureRange(Ini.ReadInteger('Reader','Theme',IfThen(FNight,5,0)),0,5);
      FThemes.ItemIndex:=FTheme; FNight:=FTheme>=4;
      FHighlightColor:=Ini.ReadInteger('Reader','HighlightColor',$0080E5FF) and $00FFFFFF;
      FUpdatingSearch:=True;
      try
        FSearchCase.Checked:=Ini.ReadBool('Reader','SearchCase',False);
        FSearchWord.Checked:=Ini.ReadBool('Reader','SearchWord',False);
        FSearchAll.Checked:=Ini.ReadBool('Reader','SearchAll',False);
      finally FUpdatingSearch:=False; end;
      Work:=Screen.WorkAreaRect;
      Bounds:=Rect(Ini.ReadInteger('Reader','Left',Work.Left+80),Ini.ReadInteger('Reader','Top',Work.Top+50),0,0);
      Bounds.Width:=EnsureRange(Ini.ReadInteger('Reader','Width',820),520,Max(520,Work.Width));
      Bounds.Height:=EnsureRange(Ini.ReadInteger('Reader','Height',680),360,Max(360,Work.Height));
      Bounds.Offset(EnsureRange(Bounds.Left,Work.Left,Max(Work.Left,Work.Right-Bounds.Width))-Bounds.Left,
        EnsureRange(Bounds.Top,Work.Top,Max(Work.Top,Work.Bottom-Bounds.Height))-Bounds.Top);
      Self.Position:=poDesigned;
      BoundsRect:=Bounds; FRestoredBounds:=Bounds;
    end
    else
    begin
      Position:=Ini.ReadInteger('Book.'+FIdentity,'Position',0);
      if Assigned(FPDF) then FPage:=EnsureRange(Position,0,FPDF.PageCount-1)
      else begin FPages.Clear; FPages.Add(EnsureRange(Position,0,Max(0,FLength-1))); FPage:=0; end;
    end;
  finally Ini.Free; end;
end;

procedure TfrmBuiltinReader.SaveSettings;
var Ini: TMemIniFile; Bounds: TRect;
begin
  if FSettingsFile='' then Exit;
  Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    if FFullScreen then Bounds:=FNormalBounds
    else if WindowState<>wsNormal then Bounds:=FRestoredBounds else Bounds:=BoundsRect;
    Ini.WriteInteger('Reader','Left',Bounds.Left); Ini.WriteInteger('Reader','Top',Bounds.Top);
    Ini.WriteInteger('Reader','Width',Bounds.Width); Ini.WriteInteger('Reader','Height',Bounds.Height);
    Ini.WriteInteger('Reader','FontSize',FFontSize);
    if FInspect then Ini.WriteInteger('Reader','PDFZoom',FInspectZoom) else Ini.WriteInteger('Reader','PDFZoom',FZoom);
    Ini.WriteBool('Reader','Night',FNight);
    Ini.WriteInteger('Reader','Theme',FTheme); Ini.WriteInteger('Reader','HighlightColor',FHighlightColor);
    Ini.WriteBool('Reader','SearchCase',FSearchCase.Checked); Ini.WriteBool('Reader','SearchWord',FSearchWord.Checked);
    Ini.WriteBool('Reader','SearchAll',FSearchAll.Checked);
    Ini.WriteString('Reader','FontName',FFontName); Ini.WriteInteger('Reader','LinePercent',FLinePercent); Ini.WriteInteger('Reader','Margin',FMargin);
    if FReady then Ini.WriteInteger('Book.'+FIdentity,'Position',CurrentPosition);
    Ini.UpdateFile;
  finally Ini.Free; end;
  if FReady and FReadingMoved and Assigned(FOnProgress) then
    if not Assigned(FPDF) and (FNext>=FLength) then FOnProgress(100)
    else FOnProgress(EnsureRange(Round((CurrentPosition+Ord(Assigned(FPDF)))*100/Max(1,FLength)),0,100));
end;

procedure TfrmBuiltinReader.CloseReader(Sender: TObject; var Action: TCloseAction);
begin StopSearch; SaveSettings; end;

procedure OpenBuiltinReader(Owner: TComponent; const FileName, BookTitle, Identity,
  SettingsFile, PDFLibrary: string; const OnProgress: TProc<Integer>);
var Form: TfrmBuiltinReader;
begin
  Form:=TfrmBuiltinReader.Create(Owner);
  try Form.OpenBook(FileName,BookTitle,Identity,SettingsFile,PDFLibrary,OnProgress); Form.ShowModal;
  finally Form.Free; end;
end;

end.
