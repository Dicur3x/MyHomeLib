unit frm_BuiltinReader;

interface

uses Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Graphics, Vcl.Menus, unit_MHLOperationStatus, unit_ReaderDocument, unit_ReaderPDF,
  unit_ReaderRaster, unit_ReaderPDFAsync, unit_ReaderFonts, unit_ReaderFontDownloads, unit_ReaderFontFallback, unit_ReaderAnnotations, unit_ReaderPageSelection;

type
  TReaderInitialsMode = (rimNone, rimChapter, rimParagraph);
  TReaderProgress = class(TPaintBox)
  public property MouseCapture; end;
  TReaderVisibleAnnotation = record
    Note: TReaderAnnotation;
    Rectangles: TArray<TRect>;
  end;
  TfrmBuiltinReader = class;
  TReaderSurface = class(TCustomControl)
  private FReader: TfrmBuiltinReader;
  protected
    procedure Paint; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X,Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X,Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X,Y: Integer); override;
    procedure WMCaptureChanged(var Message: TMessage); message WM_CAPTURECHANGED;
  end;

  TReaderLoadThread = class(TThread)
  private FFileName: string; FRasterEdge: Integer;
  protected procedure Execute; override;
  public
    Document: TReaderDocument;
    Pages: TReaderPDF;
    Error: string;
    constructor Create(const FileName: string; RasterEdge: Integer = 4000);
    destructor Destroy; override;
  end;

  TReaderPageThread = class(TThread)
  private FReader: TReaderPDF; FRasterEdge: Integer;
  protected procedure Execute; override;
  public
    Index: Integer;
    Navigated, Prefetch: Boolean;
    Error: string;
    constructor Create(Reader: TReaderPDF; Page: Integer; RasterEdge: Integer = 4000);
  end;

  TfrmBuiltinReader = class(TForm)
  private
    FSurface: TReaderSurface;
    FTop, FButtons, FBottom, FSearchPanel: TPanel;
    FStatus, FChapterPath: TLabel;
    FSearch: TEdit;
    FThemes: TComboBox;
    FFitButton: TButton;
    FPDFSelecting, FPDFPageHasText: Boolean;
    FPDFSelectionAnchor, FPDFSelectionEnd: Integer;
    FPDFSelectionRects: TArray<TRectF>;
    FCopyMenu, FAnnotationMenu: TPopupMenu;
    FAnnotationIndex: TReaderAnnotationIndex;
    FVisibleAnnotations: TArray<TReaderVisibleAnnotation>;
    FAnnotationMenuNotes: TArray<TReaderAnnotation>;
    FAnnotationLoadError: string;
    FAnnotationClick: Integer;
    FAnnotationMouseDown: TPoint;
    FBookmarkPositions: TArray<Integer>;
    FPageHasBookmark, FBookmarkClick: Boolean;
    FCopyItem, FCopyPageItem, FCopyAllItem, FCopyViewItem: TMenuItem;
    FSearchCase, FSearchWord, FSearchAll: TCheckBox;
    FTheme: Integer;
    FHighlightColor: TColor;
    FHighlighted: TList<TPoint>;
    FStyledIntervals: TList<TPoint>;
    FTextMatch, FTextMatchLength: Integer;
    FSearchBackward, FUpdatingSearch: Boolean;
    FChapters: TComboBox;
    FContentsButton: TButton;
    FChapterOutline, FChapterSourceTitles: TStringList;
    FChapterDepths: TList<Integer>;
    FNumberChapters: Boolean;
    FChapterNumbers: array[0..15] of Integer;
    FChapterParents: array[0..15] of string;
    FProgressLine: TPaintBox;
    FProgressDragging, FGlobalPagesDone, FGlobalPagesFailed: Boolean;
    FProgressTarget: Double;
    FSeekTimer, FPaginationTimer: TTimer;
    FGlobalPages: TList<Integer>;
    FMeasureBitmap: TBitmap;
    FLastPageInteraction: UInt64;
    FRichEdit: TRichEdit;
    FPageSelection: TReaderPageSelection;
    FTextSelecting, FInspectionHold, FSelectionEnabled: Boolean;
    FTextSelectionStart, FTextSelectionEnd: Integer;
    FTextSelectionRects: TArray<TRect>;
    FSelectionTint: TBitmap;
    FFormattingHost: TForm;
    FOleCallback: IInterface;
    FBitmap: TBitmap;
    FDocument: TReaderDocument;
    FStyleRanges: TArray<TReaderStyledRange>;
    FPDF: TReaderPDF;
    FLoadStatus: TMHLOperationStatus;
    FLoader: TReaderLoadThread;
    FPageWorker: TReaderPageThread;
    FRequestedPage: Integer;
    FRequestedMoved: Boolean;
    FPrefetchedForPage: Integer;
    FQualityAttemptPage, FQualityAttemptEdge: Integer;
    FPageTimer: TTimer;
    FPageStatus: TMHLOperationStatus;
    FPages: TList<Integer>;
    FPage, FNext, FLength, FFontSize, FZoom, FWheel: Integer;
    FNight, FFullScreen, FReady, FClosing, FLoadFinished, FReadingMoved, FWheelControl: Boolean;
    FBookFormatting, FShowFootnotes, FDecorativeInitials, FTypographyDirty: Boolean;
    FInitialsMode: TReaderInitialsMode;
    FHeadingColors: array[0..1,0..1] of TColor;
    FFootnotesPanel: TPanel;
    FFootnotesLabel: TLabel;
    FFootnotesMemo: TMemo;
    FIdentity, FSettingsFile, FFileName, FBookTitle: string;
    FNormalBounds, FRestoredBounds: TRect;
    FBeforeFullScreenState: TWindowState;
    FPan, FDrag: TPoint;
    FInspect: Boolean;
    FInspectZoom: Integer;
    FInspectionPercent: Integer;
    FInspectPan, FInspectSize: TPoint;
    FResizeTimer, FSearchTimer: TTimer;
    FFontName, FSearchQuery, FPDFQuery, FSearchStatus: string;
    FFontWindowCookie: Cardinal;
    FMissingFonts: TStringList;
    FFontOffer: TPanel;
    FFontOfferText: TLabel;
    FFontDownload: TButton;
    FFontOfferDeclined, FFontsDownloading: Boolean;
    FLinePercent, FMargin, FMaxTextWidth, FSearchPage, FSearchStart, FSearchVisited: Integer;
    FPDFMatchPage, FPDFMatchIndex: Integer;
    FPDFRects: TArray<TRectF>;
    FImageWidth, FImageHeight: Integer;
    FOnProgress: TProc<Integer>;
    FRequestedNote: TReaderAnnotation;
    FBookmarks: TPopupMenu;
    procedure ReloadBookmarkMarkers;
    function BookmarkMarkerBounds: TRect;
    procedure PaintBookmarkMarker(Canvas: TCanvas);
    procedure MissingReaderFont(const Family: string);
    procedure DownloadFontsClick(Sender: TObject);
    procedure DismissFontsClick(Sender: TObject);
    procedure WMReaderFontOffer(var Message: TMessage); message WM_APP + $0542;
    procedure MakeButton(const Caption: string; Action: TNotifyEvent; Width: Integer);
    procedure LoaderFinished(Sender: TObject);
    procedure RequestPage(Index: Integer; Moved: Boolean = True);
    procedure PrefetchNextPage;
    function DesiredRasterEdge: Integer;
    procedure PageLoaded(Sender: TObject);
    procedure ResetInspection;
    procedure LoadPresentation;
    function TextCharacterAt(X,Y: Integer): Integer;
    procedure UpdateTextSelection(X,Y: Integer);
    procedure PaintSelection(Canvas: TCanvas; const Boxes: TArray<TRect>);
    procedure PreparePageSelection;
    procedure RebuildAnnotationMarkers;
    procedure PaintAnnotations(Canvas: TCanvas);
    function AnnotationRectangle(const Box: TRect): TRect;
    procedure AnnotationHover(X,Y: Integer);
    procedure AnnotationClick(X,Y: Integer);
    procedure AnnotationMenuClick(Sender: TObject);
    procedure RenderPage;
    procedure PaintPage(Canvas: TCanvas);
    procedure ResizePage(Sender: TObject);
    procedure ScheduleResize(Sender: TObject);
    procedure KeyReader(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure NextClick(Sender: TObject);
    procedure PreviousClick(Sender: TObject);
    procedure BiggerClick(Sender: TObject);
    procedure FitPageClick(Sender: TObject);
    procedure CopyReaderText(const Text, SuccessStatus: string);
    procedure CopyTextClick(Sender: TObject);
    procedure CopyPageClick(Sender: TObject);
    procedure CopyAllClick(Sender: TObject);
    procedure CopyViewClick(Sender: TObject);
    function HeadingColor(Subtitle: Boolean = False): TColor;
    procedure CopyMenuPopup(Sender: TObject);
    function PDFCharacterAt(X,Y: Integer): Integer;
    procedure SelectPDFCharacter(Index: Integer);
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
    procedure SearchResultsClick(Sender: TObject);
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
    procedure ContentsClick(Sender: TObject);
    procedure DrawChapterItem(Control: TWinControl; Index: Integer; Rect: TRect; State: TOwnerDrawState);
    procedure AddChapter(const Title: string; Position, Depth: Integer);
    procedure PaintProgress(Sender: TObject);
    procedure ProgressMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
    procedure ProgressMouseMove(Sender: TObject; Shift: TShiftState; X,Y: Integer);
    procedure ProgressMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
    procedure SeekTick(Sender: TObject);
    procedure PaginationTick(Sender: TObject);
    procedure ResetPagination;
    function MeasureGlobalPage(Start: Integer): Integer;
    procedure RebuildChapterTitles;
    procedure UpdateChapterPath;
    function ChapterIndexAt(Position: Integer): Integer;
    procedure NotesClick(Sender: TObject);
    procedure NotesManageClick(Sender: TObject);
    procedure ExportNotesClick(Sender: TObject);
    procedure ExportFormatChanged(Sender: TObject);
    procedure QuoteNoteClick(Sender: TObject);
    procedure AddNote(const Quote: string);
    procedure CloseReader(Sender: TObject; var Action: TCloseAction);
    procedure RestoreSettings;
    procedure SaveSettings;
    procedure InvalidateLayout;
    function TextAreaWidth: Integer;
    function FullTextHeight: Integer;
    procedure UpdateFootnotesPanel;
    procedure ApplyBookStyles(ColorsOnly: Boolean = False; Start: Integer = 0; Finish: Integer = MaxInt);
    procedure EnsureBookStyles(Start, Finish: Integer);
    function FormatText(Start, Finish: Integer; Draw: Boolean; Target: TBitmap = nil; LayoutWidth: Integer = 0; LayoutHeight: Integer = 0): Integer;
    function CurrentPosition: Integer;
    procedure NavigateTo(Position: Integer);
  protected
    procedure WMReaderFontsReady(var Message: TMessage); message WM_READER_FONTS_READY;
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure WMAppTheme(var Message: TMessage); message WM_APP + $42;
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
    procedure SetMaxTextWidth(Value: Integer);
    procedure SetShowFootnotes(Value: Boolean);
    procedure SetBookFormatting(Value: Boolean);
    procedure SetDecorativeInitials(Value: Boolean);
    procedure SetInitialsMode(Value: TReaderInitialsMode);
    procedure SetHeadingColor(Value: TColor; Subtitle: Boolean = False);
    function PageText: string;
    function AllBookText: string;
    procedure FindText(const Query: string; Backward: Boolean = False);
    procedure ShowSearchResults(const Query: string);
    procedure SetSearchOptions(MatchCase, WholeWord, AllMatches: Boolean);
    procedure SetHighlightColor(Value: TColor);
    procedure SetTheme(Index: Integer);
    procedure StopSearch;
    procedure SetInspectionPercent(Value: Integer);
    procedure SetInspectionHold(Value: Boolean);
    procedure SetSelectionEnabled(Value: Boolean);
    procedure ToggleInspection(X,Y: Integer);
    procedure MoveInspection(X,Y: Integer);
    procedure EndInspection;
    function PageLoading: Boolean;
    function SearchRunning: Boolean;
    procedure GoToChapter(Index: Integer);
    procedure GoToPosition(Position: Integer);
    function ReadingProgress: Double;
    procedure SeekProgress(Value: Double);
    procedure RequestGlobalPages;
    function GlobalPageAt(Position: Integer): Integer;
    function GlobalPaginationReady: Boolean;
    procedure SetNumberChapters(Value: Boolean);
    procedure ReloadAnnotations;
    function VisibleAnnotationCount: Integer;
    property PageHasBookmark: Boolean read FPageHasBookmark;
    function AnnotationAtPoint(X,Y: Integer): Integer;
    function AnnotationDraft(const Quote: string): TReaderAnnotation;
    function CurrentChapterPath: string;
    function BookmarkContext(Index: Integer): string;
    function AnnotationItems(AllBooks: Boolean): TArray<TReaderAnnotation>;
    function ExportAnnotations(AllBooks, HTML: Boolean): string;
    property NumberChapters: Boolean read FNumberChapters;
    function ChapterTitle(Index: Integer): string;
    function ChapterCount: Integer;
    procedure AddBookmark(const CustomTitle: string = '');
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
    property InspectionPercent: Integer read FInspectionPercent;
    function VisibleFootnotes: string;
    property ShowFootnotes: Boolean read FShowFootnotes;
    property BookFormatting: Boolean read FBookFormatting;
    property DecorativeInitials: Boolean read FDecorativeInitials;
    property InitialsMode: TReaderInitialsMode read FInitialsMode;
    property MaxTextWidth: Integer read FMaxTextWidth;
    property InspectionHold: Boolean read FInspectionHold;
    property SelectionEnabled: Boolean read FSelectionEnabled;
    function SelectedText: string;
    function PDFSelectedText: string;
    procedure SelectPDFText(Start, Count: Integer);
    procedure SelectText(Start, Count: Integer);
    property PDFPageHasText: Boolean read FPDFPageHasText;
  end;

function ReaderColorContrast(Foreground, Background: TColor): Double;
function ReadableReaderColor(Color, Background: TColor): TColor;
function ResolveReaderSettingsFile(const DataDir: string): string;

procedure ConfigureReaderColorBox(Box: TColorBox; SelectedColor: TColor);

procedure OpenBuiltinReader(Owner: TComponent; const FileName, BookTitle, Identity,
  SettingsFile, PDFLibrary: string; const OnProgress: TProc<Integer> = nil;
  const OnOpenNote: TProc<TReaderAnnotation> = nil);
function BrowseReaderNotes(Owner: TComponent; const SettingsFile: string; out OpenNote: TReaderAnnotation): Boolean;

implementation

uses Winapi.ActiveX, Winapi.RichEdit, Winapi.CommDlg, Winapi.CommCtrl, System.Math, System.DateUtils, System.IOUtils, System.RegularExpressions,
  System.IniFiles, System.Hash, System.NetEncoding, Vcl.Dialogs, Vcl.Clipbrd, unit_ReaderRichEdit, unit_MHLTheme, unit_AtomicIniFile, Vcl.Themes;

type
  TReaderChapterSelector = class(TComboBox)
  private
    FOpenContents: TNotifyEvent;
  protected
    procedure WndProc(var Message: TMessage); override;
  public
    property OpenContents: TNotifyEvent read FOpenContents write FOpenContents;
  end;

procedure TReaderChapterSelector.WndProc(var Message: TMessage);
begin
  if Enabled and Assigned(FOpenContents) and
    ((Message.Msg=WM_LBUTTONDOWN) or (Message.Msg=WM_LBUTTONDBLCLK) or
     ((Message.Msg=CB_SHOWDROPDOWN) and (Message.WParam<>0)) or
     ((Message.Msg=WM_KEYDOWN) and (Message.WParam=VK_F4)) or
     ((Message.Msg=WM_SYSKEYDOWN) and (Message.WParam=VK_DOWN))) then
  begin
    // Every way of opening contents uses the same searchable hierarchy.
    // Keep native arrows for quickly moving between neighboring chapters.
    if CanFocus then SetFocus;
    FOpenContents(Self); Message.Result:=0; Exit;
  end;
  inherited;
end;

type
  // Own the immutable RTF string rather than copying it into another full buffer.
  TReaderRTFStream = class(TCustomMemoryStream)
  private FBytes: UTF8String;
  public
    constructor Create(const Bytes: UTF8String);
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

function ReaderColorContrast(Foreground, Background: TColor): Double;
  function Luminance(Value: TColor): Double;
    function Linear(Channel: Byte): Double;
    var Level: Double;
    begin
      Level:=Channel/255;
      if Level<=0.04045 then Result:=Level/12.92 else Result:=Power((Level+0.055)/1.055,2.4);
    end;
  var RGBValue: Cardinal;
  begin
    RGBValue:=ColorToRGB(Value);
    Result:=0.2126*Linear(GetRValue(RGBValue))+0.7152*Linear(GetGValue(RGBValue))+0.0722*Linear(GetBValue(RGBValue));
  end;
var A,B: Double;
begin
  A:=Luminance(Foreground); B:=Luminance(Background);
  Result:=(Max(A,B)+0.05)/(Min(A,B)+0.05);
end;

function ReadableReaderColor(Color, Background: TColor): TColor;
var Original: Cardinal; Percent: Integer;
begin
  Result:=ColorToRGB(Color); Original:=Result;
  // Preserve the chosen hue while making dark purple/blue readable on a dark page.
  // Settings retain the original color. The light theme does not use this adjustment.
  if ReaderColorContrast(Result,Background)>=4.5 then Exit;
  for Percent:=1 to 100 do
  begin
    Result:=RGB(GetRValue(Original)+(255-GetRValue(Original))*Percent div 100,
      GetGValue(Original)+(255-GetGValue(Original))*Percent div 100,
      GetBValue(Original)+(255-GetBValue(Original))*Percent div 100);
    if ReaderColorContrast(Result,Background)>=4.5 then Exit;
  end;
end;

function ResolveReaderSettingsFile(const DataDir: string): string;
var Legacy, Temporary: string;
begin
  Result:=TPath.Combine(DataDir,'reader.ini');
  // Older releases omitted the path separator. Keep the original profile,
  // including reading positions and bookmarks, until the copied one exists.
  Legacy:=ExcludeTrailingPathDelimiter(DataDir)+'reader.ini';
  if not TFile.Exists(Result) and TFile.Exists(Legacy) then
  begin
    Temporary:=Result+'.migrating-'+TGUID.NewGuid.ToString;
    try
      try
        ForceDirectories(DataDir);
        TFile.Copy(Legacy,Temporary,False);
        // Publish only the complete copy; never treat a partial migration as a profile.
        if not MoveFile(PChar(Temporary),PChar(Result)) then RaiseLastOSError;
      except
        // A read-only installation must still be able to reopen its old profile.
        if not TFile.Exists(Result) then Result:=Legacy;
      end;
    finally
      if TFile.Exists(Temporary) then
        try TFile.Delete(Temporary); except end;
    end;
  end;
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
  if Assigned(FReader) and (Button=mbLeft) then
  begin
    FReader.FAnnotationMouseDown:=Point(X,Y);
    FReader.FAnnotationClick:=FReader.AnnotationAtPoint(X,Y);
    FReader.FBookmarkClick:=FReader.FPageHasBookmark and PtInRect(FReader.BookmarkMarkerBounds,Point(X,Y));
    if FReader.FBookmarkClick then begin MouseCapture:=True; Exit; end;
  end;
  if Assigned(FReader) and (Button=mbLeft) and not (ssCtrl in Shift) and Assigned(FReader.FPDF) then
  begin
    if FReader.FPDFPageHasText and FReader.FSelectionEnabled then
    begin
      FReader.FPDFSelecting:=True;
      FReader.FPDFSelectionAnchor:=FReader.PDFCharacterAt(X,Y);
      FReader.FPDFSelectionEnd:=FReader.FPDFSelectionAnchor;
      FReader.FPDFSelectionRects:=nil; MouseCapture:=True; Invalidate;
    end
    else begin FReader.ToggleInspection(X,Y); MouseCapture:=FReader.FInspectionHold and FReader.FInspect; end;
    Exit;
  end;
  if Assigned(FReader) and FReader.FSelectionEnabled and (Button=mbLeft) and not Assigned(FReader.FPDF) then
  begin
    FReader.FTextSelectionStart:=FReader.TextCharacterAt(X,Y);
    FReader.FTextSelectionEnd:=FReader.FTextSelectionStart;
    FReader.FTextSelectionRects:=nil; FReader.FTextSelecting:=FReader.FTextSelectionStart>=0;
    MouseCapture:=FReader.FTextSelecting; Invalidate; Exit;
  end;
  if Assigned(FReader) then FReader.FDrag:=Point(X-FReader.FPan.X,Y-FReader.FPan.Y);
end;

procedure TReaderSurface.MouseMove(Shift: TShiftState; X,Y: Integer);
begin
  inherited;
  if Assigned(FReader) and not (ssLeft in Shift) then FReader.AnnotationHover(X,Y);
  if Assigned(FReader) and FReader.FTextSelecting and (ssLeft in Shift) then
  begin FReader.UpdateTextSelection(X,Y); Exit; end;
  if Assigned(FReader) and FReader.FPDFSelecting and (ssLeft in Shift) then
  begin FReader.SelectPDFCharacter(FReader.PDFCharacterAt(X,Y)); Exit; end;
  if Assigned(FReader) and FReader.FInspect then
  begin FReader.MoveInspection(X,Y); Exit; end;
  if (ssLeft in Shift) and (ssCtrl in Shift) and Assigned(FReader) and Assigned(FReader.FPDF) then
  begin
    FReader.FPan:=Point(X-FReader.FDrag.X,Y-FReader.FDrag.Y);
    FReader.ClampPan;
    Invalidate;
  end;
end;

procedure TReaderSurface.MouseUp(Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
begin
  inherited;
  if Assigned(FReader) and (Button=mbLeft) then
  begin
    if FReader.FTextSelecting then FReader.UpdateTextSelection(X,Y);
    FReader.FTextSelecting:=False; FReader.FPDFSelecting:=False; MouseCapture:=False;
    if FReader.FInspectionHold and FReader.FInspect then FReader.EndInspection;
    if (FReader.FAnnotationClick>=0) and not (ssCtrl in Shift) and
      (Abs(X-FReader.FAnnotationMouseDown.X)<=3) and (Abs(Y-FReader.FAnnotationMouseDown.Y)<=3) then
      FReader.AnnotationClick(X,Y);
    if FReader.FBookmarkClick and (Abs(X-FReader.FAnnotationMouseDown.X)<=3) and
      (Abs(Y-FReader.FAnnotationMouseDown.Y)<=3) then FReader.BookmarkClick(nil);
    FReader.FAnnotationClick:=-1; FReader.FBookmarkClick:=False;
  end;
end;

procedure TReaderSurface.WMCaptureChanged(var Message: TMessage);
begin
  inherited;
  if not Assigned(FReader) then Exit;
  FReader.FTextSelecting:=False; FReader.FPDFSelecting:=False;
  if FReader.FInspectionHold and FReader.FInspect then FReader.EndInspection;
end;

constructor TReaderLoadThread.Create(const FileName: string; RasterEdge: Integer);
begin inherited Create(True); FreeOnTerminate:=False; FFileName:=FileName; FRasterEdge:=RasterEdge; end;

destructor TReaderLoadThread.Destroy;
begin Pages.Free; Document.Free; inherited; end;

procedure TReaderLoadThread.Execute;
var HR: HRESULT;
begin
  HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try
    try
      if IsRasterReaderFormat(ExtractFileExt(FFileName)) then Pages:=TReaderRaster.Create(FFileName,FRasterEdge)
      else
      begin
        Document:=TReaderDocument.Create;
        Document.Load(FFileName,function: Boolean begin Result:=Terminated; end);
      end;
    except on E: Exception do Error:=E.Message; end;
  finally if Succeeded(HR) then CoUninitialize; end;
end;

constructor TReaderPageThread.Create(Reader: TReaderPDF; Page, RasterEdge: Integer);
begin inherited Create(True); FreeOnTerminate:=False; FReader:=Reader; Index:=Page; FRasterEdge:=RasterEdge; end;

procedure TReaderPageThread.Execute;
var HR: HRESULT;
begin
  HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try
    try FReader.PreparePage(Index,Prefetch,FRasterEdge); except on E: Exception do Error:=E.Message; end;
  finally if Succeeded(HR) then CoUninitialize; end;
end;

type
  TReaderContentsDialog = class(TForm)
  private
    FReader: TfrmBuiltinReader;
    FSearch: TEdit;
    FTree: TTreeView;
    FGo: TButton;
    FNumbers: TCheckBox;
    procedure NumbersChanged(Sender: TObject);
    procedure Filter(Sender: TObject);
    procedure OpenSelected(Sender: TObject);
    procedure TreeKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TreeResize(Sender: TObject);
    procedure DrawNode(Sender: TCustomTreeView; Node: TTreeNode; State: TCustomDrawState; var DefaultDraw: Boolean);
  public
    constructor CreateFor(Reader: TfrmBuiltinReader);
    function SelectedChapter: Integer;
  end;

constructor TReaderContentsDialog.CreateFor(Reader: TfrmBuiltinReader);
var Row, Footer: TPanel; Close: TButton;
begin
  inherited CreateNew(Reader); FReader:=Reader;
  Caption:='Оглавление'; Position:=poOwnerFormCenter; BorderStyle:=bsSizeable;
  PixelsPerInch:=96; Font.PixelsPerInch:=96;
  ClientWidth:=624; ClientHeight:=640; Constraints.MinWidth:=460; Constraints.MinHeight:=360;
  Font.Name:='Segoe UI'; Font.Size:=10;
  Row:=TPanel.Create(Self); Row.Parent:=Self; Row.Align:=alTop; Row.Height:=44;
  Row.BevelOuter:=bvNone; Row.Padding.SetBounds(10,8,10,8);
  FSearch:=TEdit.Create(Self); FSearch.Parent:=Row; FSearch.Align:=alClient;
  FSearch.TextHint:='Найти главу…'; FSearch.OnChange:=Filter;
  FNumbers:=TCheckBox.Create(Self); FNumbers.Parent:=Self; FNumbers.Align:=alTop; FNumbers.Top:=44;
  FNumbers.Height:=28; FNumbers.Caption:='Добавлять номера ненумерованным главам';
  FNumbers.Checked:=Reader.FNumberChapters; FNumbers.OnClick:=NumbersChanged;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom;
  Footer.Height:=44; Footer.BevelOuter:=bvNone;
  FGo:=TButton.Create(Self); FGo.Parent:=Footer; FGo.SetBounds(380,8,110,28);
  FGo.Anchors:=[akRight,akBottom]; FGo.Caption:='Перейти'; FGo.Default:=True; FGo.ModalResult:=mrOk;
  Close:=TButton.Create(Self); Close.Parent:=Footer; Close.SetBounds(500,8,112,28);
  Close.Anchors:=[akRight,akBottom]; Close.Caption:='Закрыть'; Close.Cancel:=True; Close.ModalResult:=mrCancel;
  FTree:=TTreeView.Create(Self); FTree.Parent:=Self; FTree.Align:=alClient;
  FTree.ReadOnly:=True; FTree.RowSelect:=True; FTree.HideSelection:=False;
  FTree.ShowLines:=False; FTree.ShowRoot:=True; FTree.BorderStyle:=bsNone;
  FTree.Font.Size:=11; FTree.Indent:=22; OnResize:=TreeResize;
  FTree.OnCustomDrawItem:=DrawNode; FTree.OnDblClick:=OpenSelected; FTree.OnKeyDown:=TreeKey;
  Filter(nil); ApplyMHLControlTheme(Self);
  if MHLThemeDark then FTree.Color:=RGB(31,32,33) else FTree.Color:=clWindow;
  ScaleForPPI(Screen.PixelsPerInch);
  ClientWidth:=MulDiv(624,CurrentPPI,96);
  ClientHeight:=Min(MulDiv(640,CurrentPPI,96),Max(MulDiv(320,CurrentPPI,96),Monitor.WorkareaRect.Height-80));
  TreeResize(nil); ActiveControl:=FSearch;
end;

procedure TReaderContentsDialog.TreeResize(Sender: TObject);
begin
  if Assigned(FTree) and not (csDestroying in ComponentState) and not (csDestroying in FTree.ComponentState) then
    SendMessage(FTree.Handle,TVM_SETITEMHEIGHT,MulDiv(28,CurrentPPI,96),0);
end;

procedure DrawReaderOutline(Canvas: TCanvas; const Bounds: TRect; const Title: string; Depth, PPI: Integer; Selected: Boolean);
var TextBounds: TRect;
begin
  if MHLThemeDark then begin Canvas.Brush.Color:=RGB(31,32,33); Canvas.Font.Color:=RGB(218,221,226); end
  else begin Canvas.Brush.Color:=clWindow; Canvas.Font.Color:=clWindowText; end;
  if Selected then begin Canvas.Brush.Color:=RGB(51,102,168); Canvas.Font.Color:=clWhite; end;
  Canvas.FillRect(Bounds);
  if Depth=0 then Canvas.Font.Style:=[fsBold] else Canvas.Font.Style:=[];
  TextBounds:=Bounds; Inc(TextBounds.Left,MulDiv(10+Max(0,Depth)*18,PPI,96)); Dec(TextBounds.Right,MulDiv(8,PPI,96));
  DrawText(Canvas.Handle,PChar(Title),Length(Title),TextBounds,DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
end;

procedure TReaderContentsDialog.DrawNode(Sender: TCustomTreeView; Node: TTreeNode; State: TCustomDrawState; var DefaultDraw: Boolean);
var Chapter: Integer;
begin
  Chapter:=NativeInt(Node.Data); FTree.Canvas.Font.Assign(FTree.Font);
  if (Chapter>=0) and (Chapter<FReader.FChapterDepths.Count) and (FReader.FChapterDepths[Chapter]<=0) then
    FTree.Canvas.Font.Style:=[fsBold];
  DefaultDraw:=True;
end;

procedure TfrmBuiltinReader.DrawChapterItem(Control: TWinControl; Index: Integer; Rect: TRect; State: TOwnerDrawState);
var Title: string; Depth: Integer;
begin
  if (Index<0) or (Index>=FChapters.Items.Count) then Exit;
  FChapters.Canvas.Font.Assign(FChapters.Font);
  if odComboBoxEdit in State then
  begin
    if Index<FChapterOutline.Count then Title:=FChapterOutline[Index].Trim else Title:=FChapters.Items[Index];
    Depth:=0;
  end
  else begin Title:=FChapterOutline[Index].Trim; Depth:=FChapterDepths[Index]; end;
  DrawReaderOutline(FChapters.Canvas,Rect,Title,Depth,CurrentPPI,odSelected in State);
end;

procedure TReaderContentsDialog.NumbersChanged(Sender: TObject);
begin FReader.SetNumberChapters(FNumbers.Checked); Filter(nil); end;

procedure TReaderContentsDialog.Filter(Sender: TObject);
var I, Selected, Depth, Parent, FirstMatch: Integer; Pattern: string;
  Parents: TArray<Integer>; Included, Matches: TArray<Boolean>; Nodes: TArray<TTreeNode>;
  Stack: array[0..16] of Integer;
begin
  Pattern:=string(FSearch.Text).ToLower.Replace('ё','е'); Selected:=FReader.FChapters.ItemIndex;
  if Assigned(FTree.Selected) then Selected:=SelectedChapter;
  SetLength(Parents,FReader.FChapters.Items.Count); SetLength(Included,Length(Parents));
  SetLength(Matches,Length(Parents)); SetLength(Nodes,Length(Parents));
  for I:=0 to High(Stack) do Stack[I]:=-1;
  FirstMatch:=-1;
  for I:=0 to High(Parents) do
  begin
    Depth:=EnsureRange(FReader.FChapterDepths[I]+1,0,High(Stack)); Parent:=Depth-1;
    while (Parent>=0) and (Stack[Parent]<0) do Dec(Parent);
    if Parent>=0 then Parents[I]:=Stack[Parent] else Parents[I]:=-1;
    Stack[Depth]:=I; for var D:=Depth+1 to High(Stack) do Stack[D]:=-1;
    Matches[I]:=(Pattern='') or FReader.FChapters.Items[I].ToLower.Replace('ё','е').Contains(Pattern);
    if Matches[I] then
    begin
      if FirstMatch<0 then FirstMatch:=I;
      Included[I]:=True; Parent:=Parents[I];
      while Parent>=0 do begin Included[Parent]:=True; Parent:=Parents[Parent]; end;
    end;
  end;
  if (Selected<0) or (Selected>=Length(Matches)) or not Matches[Selected] then Selected:=FirstMatch;
  FTree.Items.BeginUpdate;
  try
    FTree.Items.Clear;
    for I:=0 to High(Parents) do
      if Included[I] then
      begin
        Parent:=Parents[I];
        if Parent>=0 then Nodes[I]:=FTree.Items.AddChild(Nodes[Parent],FReader.FChapterOutline[I].Trim)
        else Nodes[I]:=FTree.Items.Add(nil,FReader.FChapterOutline[I].Trim);
        Nodes[I].Data:=Pointer(NativeInt(I));
      end;
    for I:=0 to High(Nodes) do
      if Assigned(Nodes[I]) then Nodes[I].Expanded:=(Pattern<>'') or (Nodes[I].Level=0);
    if Selected>=0 then begin FTree.Selected:=Nodes[Selected]; Nodes[Selected].MakeVisible; end;
    FGo.Enabled:=Assigned(FTree.Selected);
  finally FTree.Items.EndUpdate; end;
end;

function TReaderContentsDialog.SelectedChapter: Integer;
begin
  Result:=-1;
  if Assigned(FTree.Selected) then Result:=NativeInt(FTree.Selected.Data);
end;

procedure TReaderContentsDialog.OpenSelected(Sender: TObject);
begin if SelectedChapter>=0 then ModalResult:=mrOk; end;

procedure TReaderContentsDialog.TreeKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin if Key=VK_RETURN then begin OpenSelected(nil); Key:=0; end; end;

type
  TReaderSearchHit = record Page, Position, Count: Integer; end;
  TReaderSearchResults = class(TForm)
  private
    FReader: TfrmBuiltinReader;
    FQuery: string;
    FHits: TList<TReaderSearchHit>;
    FList: TListView;
    FStatus: TLabel;
    FTimer: TTimer;
    FStop: TButton;
    FPage, FPosition, FTotal, FLastPageCount: Integer;
    procedure Tick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure OpenSelected(Sender: TObject);
    procedure ItemData(Sender: TObject; Item: TListItem);
    procedure ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure UpdateStatus(const Stage: string);
  public
    constructor CreateFor(Reader: TfrmBuiltinReader; const Query: string);
    destructor Destroy; override;
    function SelectedHit(out Hit: TReaderSearchHit): Boolean;
  end;

constructor TReaderSearchResults.CreateFor(Reader: TfrmBuiltinReader; const Query: string);
var Row: TPanel; LabelText: TLabel; Button: TButton;
begin
  inherited CreateNew(Reader); FReader:=Reader; FQuery:=Query; FHits:=TList<TReaderSearchHit>.Create;
  Caption:='Результаты поиска'; Position:=poOwnerFormCenter; PopupMode:=pmExplicit; PopupParent:=Reader;
  ClientWidth:=740; ClientHeight:=460; Constraints.MinWidth:=520; Constraints.MinHeight:=300;
  Font.Name:='Segoe UI'; Font.Size:=10; BorderStyle:=bsSizeable;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Self; LabelText.Align:=alTop; LabelText.Height:=48;
  LabelText.WordWrap:=True; LabelText.Caption:='Поиск: «'+Query+'»'+sLineBreak+
    'Дважды нажмите на результат, чтобы перейти к тексту.';
  Row:=TPanel.Create(Self); Row.Parent:=Self; Row.Align:=alBottom; Row.Height:=76; Row.BevelOuter:=bvNone;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Row; FStatus.SetBounds(10,2,720,30);
  FStatus.AutoSize:=False; FStatus.WordWrap:=True; FStatus.Anchors:=[akLeft,akRight,akTop];
  FStop:=TButton.Create(Self); FStop.Parent:=Row; FStop.SetBounds(10,38,152,30);
  FStop.Caption:='Остановить поиск'; FStop.OnClick:=StopClick;
  Button:=TButton.Create(Self); Button.Parent:=Row; Button.SetBounds(462,38,158,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Перейти к результату'; Button.OnClick:=OpenSelected; Button.Default:=True;
  Button:=TButton.Create(Self); Button.Parent:=Row; Button.SetBounds(630,38,100,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Закрыть'; Button.ModalResult:=mrCancel; Button.Cancel:=True;
  FList:=TListView.Create(Self); FList.Parent:=Self; FList.Align:=alClient; FList.ViewStyle:=vsReport;
  FList.OwnerData:=True; FList.ReadOnly:=True; FList.RowSelect:=True; FList.HideSelection:=False;
  with FList.Columns.Add do begin Caption:='№'; Width:=46; end;
  with FList.Columns.Add do begin Caption:='Страница книги'; Width:=110; end;
  with FList.Columns.Add do begin Caption:='Глава'; Width:=240; end;
  with FList.Columns.Add do begin Caption:='Текст вокруг совпадения'; Width:=480; end;
  FList.OnData:=ItemData; FList.OnDblClick:=OpenSelected; FList.OnKeyDown:=ListKey;
  FTimer:=TTimer.Create(Self); FTimer.Interval:=15; FTimer.OnTimer:=Tick;
  UpdateStatus('Поиск…'); ApplyMHLControlTheme(Self); ActiveControl:=FList;
end;

destructor TReaderSearchResults.Destroy;
begin if Assigned(FTimer) then FTimer.Enabled:=False; FReader.FPaginationTimer.Enabled:=False; FHits.Free; inherited; end;

procedure TReaderSearchResults.UpdateStatus(const Stage: string);
begin
  FStatus.Caption:=Stage+' · Совпадений: '+IntToStr(FTotal);
  if (FTotal>0) and not Assigned(FReader.FPDF) and not FReader.FGlobalPagesDone then
    if FReader.FGlobalPagesFailed then FStatus.Caption:=FStatus.Caption+' · Позиции показаны в процентах'
    else FStatus.Caption:=FStatus.Caption+' · Рассчитываются страницы книги…';
  if FTotal>FHits.Count then FStatus.Caption:=FStatus.Caption+'; в списке первые '+IntToStr(FHits.Count)+'. Уточните запрос.';
end;

procedure TReaderSearchResults.StopClick(Sender: TObject);
begin FTimer.Enabled:=False; FStop.Enabled:=False; UpdateStatus('Поиск остановлен'); end;

procedure TReaderSearchResults.Tick(Sender: TObject);
var Started: UInt64; P, Finish: Integer; Match: TPDFMatch; Hit: TReaderSearchHit; Done: Boolean;
begin
  FTimer.Enabled:=False; Started:=GetTickCount64; Done:=FPosition<0;
  if FLastPageCount<>FReader.FGlobalPages.Count then begin FLastPageCount:=FReader.FGlobalPages.Count; FList.Invalidate; end;
  try
    if not Done then repeat
      if Assigned(FReader.FPDF) then
      begin
        if FPage>=FReader.FPDF.PageCount then begin Done:=True; Break; end;
        if not FReader.FPDF.FindOnPage(FPage,FQuery,FPosition,Match,FReader.FSearchCase.Checked,FReader.FSearchWord.Checked) then
        begin Inc(FPage); FPosition:=0; Continue; end;
        Hit.Page:=FPage; Hit.Position:=Match.Index; Hit.Count:=Match.Count;
        FPosition:=Match.Index+Max(1,Match.Count);
      end
      else
      begin
        if FPosition>=FReader.FLength then begin Done:=True; Break; end;
        Finish:=Min(FReader.FLength,FPosition+32768+Length(FQuery)-1);
        P:=FReader.FindTextRange(FQuery,FPosition,Finish,False);
        if P<0 then
        begin
          if Finish=FReader.FLength then begin Done:=True; Break; end;
          FPosition:=Finish-Length(FQuery)+1; Continue;
        end;
        Hit.Page:=-1; Hit.Position:=P; Hit.Count:=Length(FQuery); FPosition:=P+Max(1,Hit.Count);
      end;
      Inc(FTotal);
      // Keep list memory bounded. Continue counting the entire document and
      // create context only for visible rows, without formatting any page.
      if FHits.Count<10000 then FHits.Add(Hit);
    until GetTickCount64-Started>=12;
    FList.Items.Count:=FHits.Count; if FHits.Count>0 then FReader.RequestGlobalPages;
    if Done then
    begin
      FPosition:=-1; FStop.Enabled:=False; UpdateStatus('Поиск завершён');
      if not Assigned(FReader.FPDF) and not FReader.FGlobalPagesDone and not FReader.FGlobalPagesFailed and (FTotal>0) then FTimer.Enabled:=True;
    end
    else begin UpdateStatus('Поиск…'); FTimer.Enabled:=True; end;
  except
    on E: Exception do begin FStop.Enabled:=False; UpdateStatus('Не удалось завершить поиск: '+E.Message); end;
  end;
end;

procedure TReaderSearchResults.ItemData(Sender: TObject; Item: TListItem);
var Hit: TReaderSearchHit; Context, Title, Page: string; I, Number: Integer;
begin
  if (Item.Index<0) or (Item.Index>=FHits.Count) then Exit;
  Hit:=FHits[Item.Index]; Title:='';
  if Hit.Page>=0 then
  begin
    Page:=IntToStr(Hit.Page+1);
    I:=FReader.ChapterIndexAt(Hit.Page); if I>=0 then Title:=FReader.ChapterTitle(I);
    Context:=FReader.FPDF.TextRange(Hit.Page,Max(0,Hit.Position-55),Hit.Count+140);
  end
  else
  begin
    Number:=FReader.GlobalPageAt(Hit.Position);
    if Number>0 then Page:=IntToStr(Number) else Page:='… ('+IntToStr(Round(Hit.Position*100/Max(1,FReader.FLength)))+'%)';
    I:=FReader.ChapterIndexAt(Hit.Position); if I>=0 then Title:=FReader.ChapterTitle(I);
    Context:=ReaderTextRange(FReader.FRichEdit,Max(0,Hit.Position-55),Hit.Count+140);
  end;
  Item.Caption:=IntToStr(Item.Index+1);
  Item.SubItems.Clear; Item.SubItems.Add(Page); Item.SubItems.Add(Title);
  Item.SubItems.Add(TRegEx.Replace(Context,'\s+',' ').Trim);
end;

function TReaderSearchResults.SelectedHit(out Hit: TReaderSearchHit): Boolean;
begin
  Result:=Assigned(FList.Selected) and (FList.Selected.Index>=0) and (FList.Selected.Index<FHits.Count);
  if Result then Hit:=FHits[FList.Selected.Index];
end;

procedure TReaderSearchResults.OpenSelected(Sender: TObject);
var Hit: TReaderSearchHit;
begin if SelectedHit(Hit) then ModalResult:=mrOk; end;

procedure TReaderSearchResults.ListKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin if Key=VK_RETURN then begin OpenSelected(nil); Key:=0; end; end;

procedure TfrmBuiltinReader.ShowSearchResults(const Query: string);
var Dialog: TReaderSearchResults; Hit: TReaderSearchHit; Match: TPDFMatch;
begin
  StopSearch;
  if not FReady or (Query='') then Exit;
  if Assigned(FPDF) and not FPDF.HasTextSearch then
  begin ShowSearchStatus('В этом формате нет текстового слоя. Поиск недоступен.'); Exit; end;
  FSearchQuery:=Copy(Query,1,1024); FSearch.Text:=FSearchQuery;
  Dialog:=TReaderSearchResults.CreateFor(Self,FSearchQuery);
  try
    if (Dialog.ShowModal=mrOk) and Dialog.SelectedHit(Hit) then
    begin
      if Hit.Page<0 then
      begin
        FTextMatch:=Hit.Position; FTextMatchLength:=Hit.Count;
        if Hit.Position=CurrentPosition then RenderPage else NavigateTo(Hit.Position);
      end
      else if FPDF.FindOnPage(Hit.Page,FSearchQuery,Hit.Position,Match,FSearchCase.Checked,FSearchWord.Checked) then
      begin
        FPDFQuery:=FSearchQuery; FPDFMatchPage:=Hit.Page; FPDFMatchIndex:=Match.Index; FPDFRects:=Match.Rects;
        if Hit.Page=FPage then RenderPage else NavigateTo(Hit.Page);
      end;
      ShowSearchStatus('Выбран результат · F3 — следующий · Shift+F3 — предыдущий');
    end;
  finally Dialog.Free; end;
end;

procedure TfrmBuiltinReader.SearchResultsClick(Sender: TObject);
begin ShowSearchResults(FSearch.Text); end;

constructor TfrmBuiltinReader.Create(AOwner: TComponent);
var SearchRow, NavigationRow, OptionsRow, ContentsRow: TPanel; Button: TButton; MenuItem: TMenuItem; I,J: Integer;
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
  if AOwner is TCustomForm then
  begin PopupMode:=pmExplicit; PopupParent:=TCustomForm(AOwner); end;
  Caption:='HomeLib Ru — Читалка (beta)';
  Position:=poScreenCenter; SetBounds(0,0,820,680); FRestoredBounds:=BoundsRect;
  Constraints.MinWidth:=640; Constraints.MinHeight:=360;
  Font.Name:='Segoe UI'; Font.Size:=9; KeyPreview:=True; DoubleBuffered:=True;
  PrepareReaderFonts;
  FFontSize:=14; FFontName:=AvailableReaderFont('PT Serif'); FLinePercent:=110; FMargin:=32; FMaxTextWidth:=960; FBookFormatting:=True; FShowFootnotes:=True; FInspectionPercent:=150;
  for I:=0 to 1 do for J:=0 to 1 do FHeadingColors[I,J]:=clDefault;
  FPDFMatchPage:=-1; FPDFMatchIndex:=-1;
  FTextMatch:=-1; FHighlightColor:=$0080E5FF; FHighlighted:=TList<TPoint>.Create;
  FTypographyDirty:=True; FStyledIntervals:=TList<TPoint>.Create; FChapterOutline:=TStringList.Create;
  FChapterSourceTitles:=TStringList.Create; FChapterDepths:=TList<Integer>.Create; FNumberChapters:=True;
  FGlobalPages:=TList<Integer>.Create; FMeasureBitmap:=TBitmap.Create; FMeasureBitmap.SetSize(1,1);
  FZoom:=100; FPrefetchedForPage:=-1; FPages:=TList<Integer>.Create; FPages.Add(0);
  FBitmap:=TBitmap.Create; FBitmap.PixelFormat:=pf32bit;
  FTop:=TPanel.Create(Self); FTop.Parent:=Self; FTop.Align:=alTop; FTop.Height:=92; FTop.BevelOuter:=bvNone;
  FButtons:=TPanel.Create(Self); FButtons.Parent:=FTop; FButtons.Align:=alTop; FButtons.Height:=38; FButtons.BevelOuter:=bvNone;
  MakeButton('‹',PreviousClick,30); MakeButton('›',NextClick,30);
  MakeButton('−',SmallerClick,30); MakeButton('+',BiggerClick,30);
  FThemes:=TComboBox.Create(Self); FThemes.Parent:=FButtons; FThemes.Align:=alLeft;
  FThemes.Left:=MaxInt; FThemes.Width:=90; FThemes.Style:=csDropDownList;
  FThemes.Items.Text:='Светлая'+#13+'Бумага'+#13+'Сепия'+#13+'Серая'+#13+'Тёмная'+#13+'Ночь';
  FThemes.ItemIndex:=0; FThemes.OnChange:=ThemeClick; FThemes.ShowHint:=True;
  FThemes.Hint:='Цветовая тема; для PDF тёмные темы включают инверсию страниц';
  FFitButton:=TButton.Create(Self); FFitButton.Parent:=FButtons; FFitButton.Align:=alLeft;
  FFitButton.Left:=MaxInt; FFitButton.Width:=72; FFitButton.Caption:='Вписать';
  FFitButton.OnClick:=FitPageClick; FFitButton.Visible:=False;
  MakeButton('🔖︎',BookmarkSaveClick,34);
  MakeButton('✎',NotesClick,34);
  MakeButton('Закладки и заметки',NotesManageClick,154);
  MakeButton('Вид',StyleClick,50);
  MakeButton('Поиск',SearchClick,50); MakeButton('F11',FullScreenClick,50);
  FChapterPath:=TLabel.Create(Self); FChapterPath.Name:='ReaderChapterPath';
  FChapterPath.Parent:=FTop; FChapterPath.Align:=alBottom; FChapterPath.AutoSize:=False;
  FChapterPath.Height:=22; FChapterPath.Margins.SetBounds(12,0,12,0); FChapterPath.AlignWithMargins:=True;
  FChapterPath.Layout:=tlCenter; FChapterPath.EllipsisPosition:=epEndEllipsis;
  FChapterPath.Font.Name:='Segoe UI'; FChapterPath.Font.Size:=9; FChapterPath.ShowHint:=True;
  FChapterPath.Hint:='Текущая глава и её разделы';
  ContentsRow:=TPanel.Create(Self); ContentsRow.Parent:=FTop; ContentsRow.Align:=alClient; ContentsRow.BevelOuter:=bvNone;
  FContentsButton:=TButton.Create(Self); FContentsButton.Parent:=ContentsRow; FContentsButton.Align:=alLeft;
  FContentsButton.Width:=36; FContentsButton.Caption:='☰'; FContentsButton.Hint:='Оглавление (Ctrl+T)';
  FContentsButton.ShowHint:=True; FContentsButton.Enabled:=False; FContentsButton.OnClick:=ContentsClick;
  FChapters:=TReaderChapterSelector.Create(Self); FChapters.Name:='ReaderChapterSelector';
  TReaderChapterSelector(FChapters).OpenContents:=ContentsClick; FChapters.Parent:=ContentsRow; FChapters.Align:=alClient; FChapters.DropDownCount:=20;
  FChapters.TextHint:='Содержание книги'; FChapters.Style:=csOwnerDrawFixed; FChapters.ItemHeight:=24; FChapters.OnDrawItem:=DrawChapterItem; FChapters.OnChange:=ChapterClick; FChapters.Hint:='Содержание книги'; FChapters.ShowHint:=True;
  FBottom:=TPanel.Create(Self); FBottom.Parent:=Self; FBottom.Align:=alBottom; FBottom.Height:=40; FBottom.BevelOuter:=bvNone;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=FBottom; FStatus.Align:=alClient; FStatus.Layout:=tlCenter; FStatus.Alignment:=taCenter;
  FStatus.Caption:='Колесо — страницы · Ctrl+колесо — размер · F11 — весь экран · Ctrl+F — поиск';
  FProgressLine:=TReaderProgress.Create(Self); FProgressLine.Parent:=FBottom; FProgressLine.Align:=alBottom;
  FProgressLine.Height:=14; FProgressLine.OnPaint:=PaintProgress; FProgressLine.Cursor:=crHandPoint;
  FProgressLine.Hint:='Щёлкните или перетащите, чтобы перейти к нужному месту книги'; FProgressLine.ShowHint:=True;
  FProgressLine.OnMouseDown:=ProgressMouseDown; FProgressLine.OnMouseMove:=ProgressMouseMove; FProgressLine.OnMouseUp:=ProgressMouseUp;
  FFootnotesPanel:=TPanel.Create(Self); FFootnotesPanel.Parent:=Self;
  FFootnotesPanel.Align:=alBottom; FFootnotesPanel.Top:=0; FFootnotesPanel.Height:=110;
  FFootnotesPanel.BevelOuter:=bvNone; FFootnotesPanel.Caption:=''; FFootnotesPanel.Visible:=False;
  FFootnotesPanel.Padding.SetBounds(16,8,16,8);
  with TBevel.Create(Self) do begin Parent:=FFootnotesPanel; Align:=alTop; Height:=6; Shape:=bsTopLine; end;
  FFootnotesLabel:=TLabel.Create(Self); FFootnotesLabel.Parent:=FFootnotesPanel;
  FFootnotesLabel.Align:=alTop; FFootnotesLabel.AutoSize:=False; FFootnotesLabel.Height:=24;
  FFootnotesLabel.Font.Style:=[fsBold]; FFootnotesLabel.Caption:='Сноски на этой странице';
  FFootnotesMemo:=TMemo.Create(Self); FFootnotesMemo.Parent:=FFootnotesPanel;
  FFootnotesMemo.Align:=alClient; FFootnotesMemo.ReadOnly:=True; FFootnotesMemo.WordWrap:=True;
  FFootnotesMemo.ScrollBars:=ssVertical; FFootnotesMemo.BorderStyle:=bsNone;
  FFootnotesMemo.Font.Name:='Segoe UI'; FFootnotesMemo.Font.Size:=10;
  FFootnotesMemo.Font.Quality:=fqClearTypeNatural;
  FFootnotesMemo.StyleElements:=FFootnotesMemo.StyleElements-[seClient,seFont];
  FSearchPanel:=TPanel.Create(Self); FSearchPanel.Parent:=Self; FSearchPanel.Align:=alTop; FSearchPanel.Height:=98; FSearchPanel.Visible:=False;
  SearchRow:=TPanel.Create(Self); SearchRow.Parent:=FSearchPanel; SearchRow.Align:=alTop; SearchRow.Height:=32; SearchRow.BevelOuter:=bvNone;
  SearchButton('×',28,SearchCloseClick);
  FSearch:=TEdit.Create(Self); FSearch.Parent:=SearchRow; FSearch.Align:=alClient; FSearch.TextHint:='Найти… Enter / Shift+Enter'; FSearch.OnKeyDown:=SearchKey;
  NavigationRow:=TPanel.Create(Self); NavigationRow.Parent:=FSearchPanel; NavigationRow.Align:=alTop;
  NavigationRow.Top:=32; NavigationRow.Height:=32; NavigationRow.BevelOuter:=bvNone;
  for I:=0 to 2 do
  begin
    Button:=TButton.Create(Self); Button.Parent:=NavigationRow; Button.Align:=alLeft; Button.Left:=MaxInt;
    case I of
      0: begin Button.Caption:='Предыдущий результат'; Button.Width:=172; Button.OnClick:=SearchPreviousClick; end;
      1: begin Button.Caption:='Следующий результат'; Button.Width:=162; Button.OnClick:=SearchNextClick; end;
      2: begin Button.Caption:='Найти все…'; Button.Width:=110; Button.OnClick:=SearchResultsClick; end;
    end;
    Button.TabStop:=False;
  end;
  OptionsRow:=TPanel.Create(Self); OptionsRow.Parent:=FSearchPanel; OptionsRow.Align:=alClient; OptionsRow.BevelOuter:=bvNone;
  FSearchCase:=SearchCheck('Регистр',78); FSearchWord:=SearchCheck('Слово целиком',118);
  FSearchAll:=SearchCheck('Подсветить все',122);
  Button:=TButton.Create(Self); Button.Parent:=OptionsRow; Button.Align:=alLeft; Button.Left:=MaxInt;
  Button.Width:=64; Button.Caption:='Цвет…'; Button.OnClick:=SearchColorClick;
  FSurface:=TReaderSurface.Create(Self); FSurface.Parent:=Self; FSurface.Align:=alClient; FSurface.FReader:=Self;
  FSurface.DoubleBuffered:=True; FSurface.TabStop:=True;
  FPDFSelectionAnchor:=-1; FPDFSelectionEnd:=-1; FTextSelectionStart:=-1; FTextSelectionEnd:=-1; FInspectionHold:=True; FSelectionEnabled:=True;
  FCopyMenu:=TPopupMenu.Create(Self); FCopyMenu.OnPopup:=CopyMenuPopup;
  FAnnotationMenu:=TPopupMenu.Create(Self); FAnnotationMenu.Name:='ReaderAnnotationMenu'; FAnnotationClick:=-1; FSurface.ShowHint:=True;
  FCopyItem:=TMenuItem.Create(FCopyMenu); FCopyItem.Caption:='Копировать выделенный текст';
  FCopyItem.OnClick:=CopyTextClick; FCopyItem.ShortCut:=ShortCut(Ord('C'),[ssCtrl]);
  FCopyMenu.Items.Add(FCopyItem);
  FCopyPageItem:=TMenuItem.Create(FCopyMenu); FCopyPageItem.Caption:='Копировать текст страницы';
  FCopyPageItem.OnClick:=CopyPageClick; FCopyMenu.Items.Add(FCopyPageItem);
  FCopyAllItem:=TMenuItem.Create(FCopyMenu); FCopyAllItem.Caption:='Копировать весь текст книги';
  FCopyAllItem.ShortCut:=ShortCut(Ord('C'),[ssCtrl,ssShift]); FCopyAllItem.OnClick:=CopyAllClick; FCopyMenu.Items.Add(FCopyAllItem);
  FCopyViewItem:=TMenuItem.Create(FCopyMenu); FCopyViewItem.Caption:='Текст страницы…';
  FCopyViewItem.OnClick:=CopyViewClick; FCopyViewItem.Visible:=False; FCopyMenu.Items.Add(FCopyViewItem); FSurface.PopupMenu:=FCopyMenu;
  MenuItem:=TMenuItem.Create(FCopyMenu); MenuItem.Caption:='Добавить заметку…';
  MenuItem.OnClick:=NotesClick; FCopyMenu.Items.Add(MenuItem);
  // Start with page keys ready; the contents selector keeps its own keys after a click.
  ActiveControl:=FSurface;
  FRichEdit:=TRichEdit.Create(Self);
  // This hidden formatting buffer must survive showing, scaling and restyling
  // the reader form: recreating a VCL child would discard its OLE pictures.
  FFormattingHost:=TForm.CreateNew(Self); FFormattingHost.Scaled:=False;
  FFormattingHost.Name:='ReaderFormattingHost'; FFormattingHost.StyleElements:=[];
  FRichEdit.Parent:=FFormattingHost; FRichEdit.Visible:=False;
  FRichEdit.StyleElements:=[];
  FRichEdit.Font.Quality:=fqClearTypeNatural;
  FRichEdit.ReadOnly:=True; FRichEdit.PlainText:=False; FRichEdit.MaxLength:=MAXINT;
  // The buffer is read-only. Thousands of decorative runs need no undo history.
  SendMessage(FRichEdit.Handle,EM_SETUNDOLIMIT,0,0);
  // Only EM_FORMATRANGE paginates this hidden buffer; skip its narrow on-screen wrapping.
  FRichEdit.WordWrap:=False;
  FOleCallback:=AttachReaderPictures(FRichEdit);
  FPageSelection:=TReaderPageSelection.Create(Self,FFormattingHost);
  FSelectionTint:=TBitmap.Create; FSelectionTint.PixelFormat:=pf32bit; FSelectionTint.SetSize(1,1);
  FResizeTimer:=TTimer.Create(Self); FResizeTimer.Enabled:=False; FResizeTimer.Interval:=140; FResizeTimer.OnTimer:=ResizePage;
  FPageTimer:=TTimer.Create(Self); FPageTimer.Enabled:=False; FPageTimer.Interval:=30; FPageTimer.OnTimer:=PageLoaded;
  FSearchTimer:=TTimer.Create(Self); FSearchTimer.Enabled:=False; FSearchTimer.Interval:=1; FSearchTimer.OnTimer:=SearchTick;
  FSeekTimer:=TTimer.Create(Self); FSeekTimer.Enabled:=False; FSeekTimer.Interval:=90; FSeekTimer.OnTimer:=SeekTick;
  FPaginationTimer:=TTimer.Create(Self); FPaginationTimer.Enabled:=False; FPaginationTimer.Interval:=35; FPaginationTimer.OnTimer:=PaginationTick;
  FBookmarks:=TPopupMenu.Create(Self);
  FMissingFonts:=TStringList.Create;
  FFontOffer:=TPanel.Create(Self); FFontOffer.Name:='ReaderLanguageFonts'; FFontOffer.Parent:=Self; FFontOffer.Align:=alTop;
  FFontOffer.Height:=68; FFontOffer.BevelOuter:=bvNone; FFontOffer.Visible:=False;
  FFontOfferText:=TLabel.Create(Self); FFontOfferText.Parent:=FFontOffer;
  FFontOfferText.Align:=alClient; FFontOfferText.WordWrap:=True; FFontOfferText.Layout:=tlCenter;
  FFontOfferText.Margins.SetBounds(12,4,12,4); FFontOfferText.AlignWithMargins:=True;
  FFontDownload:=TButton.Create(Self); FFontDownload.Parent:=FFontOffer; FFontDownload.Align:=alRight;
  FFontDownload.Width:=100; FFontDownload.Caption:='Скачать'; FFontDownload.OnClick:=DownloadFontsClick;
  var LaterFont:=TButton.Create(Self); LaterFont.Parent:=FFontOffer; LaterFont.Align:=alRight;
  LaterFont.Width:=80; LaterFont.Caption:='Позже'; LaterFont.OnClick:=DismissFontsClick;
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
  if Caption='✎' then begin Button.Name:='ReaderAddNote'; Button.Hint:='Добавить заметку с выделенной цитатой (Ctrl+M)'; Button.ShowHint:=True; end;
  if Caption='🔖︎' then
  begin Button.Name:='ReaderAddBookmark'; Button.Font.Name:='Segoe UI Symbol'; Button.Font.Size:=13;
    Button.Hint:='Добавить закладку (Ctrl+B)'; Button.ShowHint:=True; end;
  if Caption='Закладки и заметки' then Button.Name:='ReaderSavedItems';
end;

procedure TfrmBuiltinReader.MissingReaderFont(const Family: string);
begin
  if FMissingFonts.IndexOf(Family)>=0 then Exit;
  FMissingFonts.Add(Family);
  if not FFontOfferDeclined then PostMessage(Handle,WM_APP+$0542,FFontWindowCookie,0);
end;

procedure TfrmBuiltinReader.WMReaderFontOffer(var Message: TMessage);
var Languages: TStringList; Bytes: Int64; Size: string;
begin
  Message.Result:=0;
  if FClosing or FFontOfferDeclined or (Cardinal(Message.WParam)<>FFontWindowCookie) then Exit;
  Languages:=TStringList.Create; Bytes:=0;
  try
    for var Family in FMissingFonts do
    begin
      var Name:=ReaderFontLanguage(Family); if Languages.IndexOf(Name)<0 then Languages.Add(Name);
      Bytes:=Bytes+ReaderFontDownloadBytes(Family);
    end;
    if Bytes>=1048576 then Size:=Format('%.1f МБ',[Bytes/1048576]) else Size:=Format('%d КБ',[(Bytes+1023) div 1024]);
    FFontOfferText.Caption:='Скачать шрифты для '+Languages.CommaText+' текста ('+Size+')? '+
      'Они сохранятся для следующих книг. Сейчас используется доступный шрифт Windows.';
  finally Languages.Free; end;
  FFontOffer.Color:=ThemeBackground; FFontOfferText.Font.Color:=ThemeText;
  FFontOffer.Visible:=FMissingFonts.Count>0;
end;

procedure TfrmBuiltinReader.DownloadFontsClick(Sender: TObject);
begin
  FFontsDownloading:=True;
  for var Family in FMissingFonts do RequestReaderFont(Family);
  FFontOfferText.Caption:='Шрифты загружаются. Можно продолжать читать.';
end;

procedure TfrmBuiltinReader.DismissFontsClick(Sender: TObject);
begin FFontOfferDeclined:=True; FFontOffer.Visible:=False; end;

procedure TfrmBuiltinReader.CreateWnd;
begin inherited; FFontWindowCookie:=RegisterReaderFontWindow(Handle); end;

procedure TfrmBuiltinReader.DestroyWnd;
begin UnregisterReaderFontWindow(Handle); FFontWindowCookie:=0; inherited; end;

procedure TfrmBuiltinReader.WMReaderFontsReady(var Message: TMessage);
begin
  Message.Result:=0;
  if FClosing or not FReady or Assigned(FPDF) or (Cardinal(Message.WParam)<>FFontWindowCookie) or
    (FMissingFonts.Count=0) then Exit;
  // InvalidateLayout retains the exact text position; no book reload or history write.
  if Message.LParam=0 then
  begin
    if not FFontsDownloading then Exit;
    FFontOfferText.Caption:='Не удалось скачать шрифты. Проверьте соединение и нажмите «Скачать» ещё раз.'; Exit; end;
  FStyledIntervals.Clear; InvalidateLayout;
  for var I:=FMissingFonts.Count-1 downto 0 do
    if EnsureReaderFont(FMissingFonts[I]) then FMissingFonts.Delete(I);
  if FMissingFonts.Count=0 then begin FFontsDownloading:=False; FFontOffer.Visible:=False; end;
end;

destructor TfrmBuiltinReader.Destroy;
begin
  FClosing:=True; FSeekTimer.Enabled:=False; FPaginationTimer.Enabled:=False; FreeAndNil(FLoadStatus);
  FPageTimer.Enabled:=False;
  if Assigned(FPageWorker) then begin FPageWorker.Terminate; FPageWorker.WaitFor; FreeAndNil(FPageWorker); end;
  FreeAndNil(FPageStatus);
  FSearchTimer.Enabled:=False;
  if Assigned(FLoader) then begin FLoader.OnTerminate:=nil; FLoader.Terminate; FLoader.WaitFor; FreeAndNil(FLoader); end;
  FreeAndNil(FMissingFonts);
  FSurface.FReader:=nil; FreeAndNil(FAnnotationIndex); FreeAndNil(FPageSelection); FreeAndNil(FSelectionTint);
  FPDF.Free; FDocument.Free; FBitmap.Free; FPages.Free; FHighlighted.Free; FStyledIntervals.Free; FChapterOutline.Free; FChapterSourceTitles.Free; FChapterDepths.Free; FGlobalPages.Free; FMeasureBitmap.Free; inherited;
end;

procedure TfrmBuiltinReader.OpenBook(const FileName, BookTitle, Identity, SettingsFile, PDFLibrary: string;
  const OnProgress: TProc<Integer>);
var Stream: TFileStream; Chapter: TPDFChapter;
begin
  FMissingFonts.Clear; FFontOfferDeclined:=False; FFontsDownloading:=False; FFontOffer.Visible:=False;
  FFileName:=FileName; FIdentity:=Copy(THashSHA2.GetHashString(Identity),1,40);
  FSettingsFile:=SettingsFile; FOnProgress:=OnProgress; FBookTitle:=BookTitle;
  Caption:='HomeLib Ru — '+BookTitle+' — Читалка (beta)';
  RestoreSettings;
  ReloadAnnotations;
  if SameText(ExtractFileExt(FileName),'.pdf') then
  begin
    FPDF:=TReaderPDFAsync.Create(PDFLibrary,FileName); FLength:=FPDF.PageCount;
    for Chapter in FPDF.Chapters do
      AddChapter(Chapter.Title,Chapter.Page,Chapter.Depth);
    RebuildChapterTitles; FReady:=True; RestoreSettings; FRequestedPage:=FPage; RenderPage;
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
    FLoader:=TReaderLoadThread.Create(FileName,DesiredRasterEdge); FLoader.OnTerminate:=LoaderFinished; FLoader.Start;
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
    for Chapter in FPDF.Chapters do AddChapter(Chapter.Title,Chapter.Page,Chapter.Depth);
    RebuildChapterTitles;
    FReady:=True; RestoreSettings; SavedPage:=FPage; FPage:=0; FRequestedPage:=0;
    RenderPage;
    if SavedPage<>0 then RequestPage(SavedPage,False);
    Exit;
  end;
  FDocument:=FLoader.Document; FLoader.Document:=nil;
  UpdateFootnotesPanel; LoadPresentation;
  FLength:=ReaderTextLength(FRichEdit);
  for C in FDocument.Chapters do AddChapter(C.Title,C.Position,C.Depth);
  RebuildChapterTitles;
  FStyleRanges:=FDocument.Styles; FDocument.ReleaseUnusedBuffers;
  FReady:=True; ReloadAnnotations; InvalidateLayout; RestoreSettings; RenderPage;
  except
    on E: Exception do
    begin FReady:=False; FStatus.Caption:='Не удалось открыть книгу: '+E.Message; FSurface.Invalidate; end;
  end;
end;

function TfrmBuiltinReader.PageLoading: Boolean;
begin
  Result:=Assigned(FPageWorker) and ((not FPageWorker.Prefetch) or (FRequestedPage<>FPage));
end;

function TfrmBuiltinReader.DesiredRasterEdge: Integer;
var Zoom: Integer;
begin
  Zoom:=FZoom;
  if FInspect then Zoom:=FInspectZoom;
  // Reserve enough detail for click magnification, without decoding a 4000px
  // image for a small reading window. Larger windows/zoom upgrade in background.
  Result:=EnsureRange(Ceil(Max(FSurface.ClientWidth,FSurface.ClientHeight)*
    Max(100,Zoom)/100*Max(100,FInspectionPercent)/100*1.1),1200,4000);
end;

procedure TfrmBuiltinReader.PrefetchNextPage;
var Edge: Integer;
begin
  if FClosing or not FReady or (not Assigned(FPDF) or not FPDF.AsyncPages) or Assigned(FPageWorker) or
    (FRequestedPage<>FPage) then Exit;
  Edge:=DesiredRasterEdge;
  if not FPDF.IsPageCached(FPage,Edge) and
    ((FQualityAttemptPage<>FPage) or (FQualityAttemptEdge<>Edge)) then
  begin
    FQualityAttemptPage:=FPage; FQualityAttemptEdge:=Edge;
    FPageWorker:=TReaderPageThread.Create(FPDF,FPage,Edge);
    FPageWorker.Prefetch:=True; FPageTimer.Enabled:=True; FPageWorker.Start; Exit;
  end;
  if (FPage+1>=FPDF.PageCount) or (FPrefetchedForPage=FPage) then Exit;
  FPrefetchedForPage:=FPage;
  if FPDF.IsPageCached(FPage+1,Edge) then Exit;
  FPageWorker:=TReaderPageThread.Create(FPDF,FPage+1,Edge);
  FPageWorker.Prefetch:=True; FPageTimer.Enabled:=True; FPageWorker.Start;
end;

procedure TfrmBuiltinReader.RequestPage(Index: Integer; Moved: Boolean);
begin
  if not FReady or FClosing or (not Assigned(FPDF) or not FPDF.AsyncPages) then Exit;
  FRequestedPage:=EnsureRange(Index,0,FPDF.PageCount-1); FRequestedMoved:=Moved;
  if FRequestedPage=FPage then
  begin
    // Returning to the visible page cancels navigation, although the decoder
    // may still finish its private buffer. Restore the visible page's status.
    FreeAndNil(FPageStatus); RenderPage;
    Exit;
  end;
  ResetInspection; FSearchStatus:=''; FSurface.Invalidate;
  // A foreground decode owns the pending navigation until it completes.
  if Assigned(FPageWorker) and not FPageWorker.Prefetch then Exit;
  if FPDF.IsPageCached(FRequestedPage) then
  begin
    ResetInspection; FSearchStatus:=''; FPage:=FRequestedPage;
    FReadingMoved:=FReadingMoved or Moved; RenderPage; PrefetchNextPage; Exit;
  end;
  FStatus.Caption:=Format('Открытие страницы %d из %d…',[FRequestedPage+1,FPDF.PageCount]);
  if not Assigned(FPageStatus) then FPageStatus:=TMHLOperationStatus.Create('Открытие страницы книги…');
  if Assigned(FPageWorker) then Exit;
  ResetInspection; FSearchStatus:='';
  FPageWorker:=TReaderPageThread.Create(FPDF,FRequestedPage,DesiredRasterEdge);
  FPageWorker.Navigated:=Moved; FPageTimer.Enabled:=True; FPageWorker.Start;
end;

procedure TfrmBuiltinReader.PageLoaded(Sender: TObject);
var Index: Integer; Error: string; Moved, Preloaded: Boolean; SavedPan: TPoint;
begin
  if not Assigned(FPageWorker) or (WaitForSingleObject(FPageWorker.Handle,0)<>WAIT_OBJECT_0) then Exit;
  Index:=FPageWorker.Index; Error:=FPageWorker.Error; Moved:=FPageWorker.Navigated;
  Preloaded:=FPageWorker.Prefetch;
  FreeAndNil(FPageWorker); FPageTimer.Enabled:=False; FreeAndNil(FPageStatus);
  if not Preloaded and (Error='') and (Index=FRequestedPage) then
  begin
    FPage:=Index; FReadingMoved:=FReadingMoved or Moved;
    try RenderPage; except on E: Exception do Error:=E.Message; end;
  end;
  if Preloaded and (Error='') and (Index=FPage) and (FRequestedPage=FPage) then
  begin
    SavedPan:=FPan;
    try RenderPage; FPan:=SavedPan; ClampPan; FSurface.Invalidate;
    except on E: Exception do Error:=E.Message; end;
  end;
  if (FRequestedPage<>FPage) and (Preloaded or (FRequestedPage<>Index)) then
    RequestPage(FRequestedPage,FRequestedMoved)
  else if not Preloaded and (Error<>'') and (Index=FRequestedPage) then
    FStatus.Caption:='Не удалось открыть страницу: '+Error
  else PrefetchNextPage;
end;

procedure TfrmBuiltinReader.LoadPresentation;
var Stream: TReaderRTFStream;
begin
  FImageWidth:=Max(16,TextAreaWidth-16);
  FImageHeight:=Max(16,FullTextHeight-80);
  FTypographyDirty:=True;
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

function TfrmBuiltinReader.TextAreaWidth: Integer;
begin
  Result:=Max(16,FSurface.ClientWidth-FMargin*2);
  if FMaxTextWidth>0 then Result:=Min(Result,MulDiv(FMaxTextWidth,CurrentPPI,96));
end;

function TfrmBuiltinReader.FullTextHeight: Integer;
begin
  Result:=FSurface.ClientHeight;
  if FFootnotesPanel.Visible then Inc(Result,FFootnotesPanel.Height);
end;

function TfrmBuiltinReader.FormatText(Start, Finish: Integer; Draw: Boolean; Target: TBitmap; LayoutWidth, LayoutHeight: Integer): Integer;
var Range: TFormatRange; DPI, Width, Limit: Integer;
begin
  if not Assigned(Target) then Target:=FBitmap;
  if LayoutWidth<=0 then LayoutWidth:=Target.Width;
  if LayoutHeight<=0 then LayoutHeight:=Target.Height;
  Limit:=Finish;
  if Limit<0 then Limit:=Min(FLength,Start+4096);
  repeat
    EnsureBookStyles(Start,Limit);
    // Preparing styles can allocate other VCL drawing contexts. Acquire and
    // protect this bitmap's DC afterwards, keeping it live for native layout.
    Target.Canvas.Lock;
    try
      FillChar(Range,SizeOf(Range),0); DPI:=GetDeviceCaps(Target.Canvas.Handle,LOGPIXELSY);
      Range.hdc:=Target.Canvas.Handle; Range.hdcTarget:=Range.hdc;
      Range.rcPage:=Rect(0,0,MulDiv(LayoutWidth,1440,DPI),MulDiv(LayoutHeight,1440,DPI));
      Range.rc:=Range.rcPage; InflateRect(Range.rc,-MulDiv(FMargin,1440,96),-MulDiv(20,1440,96));
      Width:=Min(Range.rc.Width,MulDiv(TextAreaWidth,1440,DPI));
      Inc(Range.rc.Left,(Range.rc.Width-Width) div 2); Range.rc.Right:=Range.rc.Left+Width;
      Range.chrg.cpMin:=Start; Range.chrg.cpMax:=Finish;
      try Result:=SendMessage(FRichEdit.Handle,EM_FORMATRANGE,Ord(Draw),LPARAM(@Range));
      finally SendMessage(FRichEdit.Handle,EM_FORMATRANGE,0,0); end;
    finally Target.Canvas.Unlock; end;
    // RichEdit can include the implicit final paragraph mark in its end index.
    // Clamp that valid sentinel; a negative native result is a layout error.
    if (Result<Start) or (Result>FLength+1) then
      raise Exception.Create('Не удалось разметить страницу книги.');
    Result:=Min(Result,FLength);
    if (Finish>=0) or (Result<Limit) or (Limit>=FLength) then Break;
    // Start with a typical visible page, not several off-screen pages.
    // Very wide pages and small fonts extend this interval until all visible
    // text is styled, retaining exact layout without costly distant work.
    Limit:=Min(FLength,Limit+4096);
  until False;
end;

procedure TfrmBuiltinReader.ResetInspection;
begin
  FPDFSelecting:=False; FPDFSelectionAnchor:=-1; FPDFSelectionEnd:=-1; FPDFSelectionRects:=nil;
  if not FInspect then Exit;
  FInspect:=False; FZoom:=FInspectZoom; FSurface.Cursor:=crDefault;
end;

procedure TfrmBuiltinReader.SetSelectionEnabled(Value: Boolean);
begin
  if FSelectionEnabled=Value then Exit;
  if FInspect then EndInspection;
  FSelectionEnabled:=Value; FTextSelecting:=False; FPDFSelecting:=False;
  FTextSelectionStart:=-1; FTextSelectionEnd:=-1; FTextSelectionRects:=nil;
  FPDFSelectionAnchor:=-1; FPDFSelectionEnd:=-1; FPDFSelectionRects:=nil;
  if Assigned(FPDF) and FPDFPageHasText and Value then FSurface.Cursor:=crIBeam
  else if not Assigned(FPDF) and Value then FSurface.Cursor:=crIBeam else FSurface.Cursor:=crDefault;
  FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.SetInspectionHold(Value: Boolean);
begin
  if FInspectionHold=Value then Exit;
  if FInspect then EndInspection;
  FInspectionHold:=Value;
end;

procedure TfrmBuiltinReader.SetInspectionPercent(Value: Integer);
begin
  if FInspect then EndInspection;
  FInspectionPercent:=EnsureRange(Value,120,300);
end;

procedure TfrmBuiltinReader.ToggleInspection(X,Y: Integer);
begin
  if FInspect then begin EndInspection; Exit; end;
  if not FReady or not Assigned(FPDF) or PageLoading or (FBitmap.Width=0) or
    not PtInRect(Rect(FPan.X,FPan.Y,FPan.X+FBitmap.Width,FPan.Y+FBitmap.Height),Point(X,Y)) then Exit;
  FInspectZoom:=FZoom; FInspectPan:=FPan; FInspectSize:=Point(FBitmap.Width,FBitmap.Height);
  FZoom:=Min(900,Max(FZoom+1,MulDiv(FZoom,FInspectionPercent,100)));
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
var Size: TPoint; Scale: Double; Temporary: TBitmap; W,H,I, FullHeight, NotesHeight: Integer; Match: TPDFMatch; Notes: string; NotesRect: TRect;
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
  FVisibleAnnotations:=nil; FSurface.Hint:=''; FAnnotationClick:=-1;
  FFontOffer.Color:=ThemeBackground; FFontOfferText.Font.Color:=ThemeText;
  if not FReady or FClosing or (Assigned(FPageWorker) and not FPageWorker.Prefetch) or (FSurface.ClientWidth<100) or (FSurface.ClientHeight<100) then Exit;
  if Assigned(FPDF) then
  begin
    if FPDF.AsyncPages and not FPDF.IsPageCached(FPage) then
    begin
      if not Assigned(FPageWorker) then
      begin
        FRequestedPage:=FPage;
        FStatus.Caption:=Format('Открытие страницы %d из %d…',[FPage+1,FPDF.PageCount]);
        FPageWorker:=TReaderPageThread.Create(FPDF,FPage,DesiredRasterEdge);
        FPageTimer.Enabled:=True; FPageWorker.Start;
      end;
      Exit;
    end;
    FLoadFinished:=True;
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
    FPDFPageHasText:=FPDF.PageHasText(FPage); FFitButton.Visible:=True;
    if FPDFPageHasText and FSelectionEnabled then FSurface.Cursor:=crIBeam else FSurface.Cursor:=crDefault;
    FStatus.Caption:=Format('%s · Страница %d из %d · Масштаб %d%%',[FPDF.DisplayName,FPage+1,FPDF.PageCount,FZoom]);
    if FPDFPageHasText and FSelectionEnabled then FStatus.Caption:=FStatus.Caption+' · Выделение мышью · Ctrl+C — копировать'
    else if FInspectionHold then FStatus.Caption:=FStatus.Caption+' · Держите кнопку — приблизить; отпустите — вернуть'
    else FStatus.Caption:=FStatus.Caption+' · Щелчок — приблизить; Esc — вернуть';
  end
  else
  begin
    FPageSelection.Clear; FTextSelecting:=False; FTextSelectionStart:=-1; FTextSelectionEnd:=-1; FTextSelectionRects:=nil;
    if FSelectionEnabled then FSurface.Cursor:=crIBeam else FSurface.Cursor:=crDefault;
    FullHeight:=FullTextHeight;
    FBitmap.SetSize(FSurface.ClientWidth,FullHeight);
    ClearTextHighlights;
    FNext:=FormatText(CurrentPosition,-1,False); Notes:=''; NotesHeight:=0;
    if FShowFootnotes and Assigned(FDocument) then Notes:=FDocument.FootnotesForRange(CurrentPosition,FNext);
    if Notes<>'' then
    begin
      FBitmap.Canvas.Font.Assign(FFootnotesMemo.Font);
      NotesRect:=Rect(0,0,Max(40,FSurface.ClientWidth-56),0);
      DrawText(FBitmap.Canvas.Handle,PChar(Notes),Length(Notes),NotesRect,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      NotesHeight:=Min(Max(70,NotesRect.Height+54),Max(70,Min(200,FullHeight div 3)));
      FBitmap.SetSize(FSurface.ClientWidth,Max(100,FullHeight-NotesHeight));
      FNext:=FormatText(CurrentPosition,-1,False);
      Notes:=FDocument.FootnotesForRange(CurrentPosition,FNext);
      // If reserving room moves the first reference off this page, end the
      // body before that reference. Its note will accompany the next page.
      if Notes='' then begin NotesHeight:=0; FBitmap.SetSize(FSurface.ClientWidth,FullHeight); end;
    end;
    DisableAlign;
    try
      FFootnotesPanel.Height:=Max(70,NotesHeight); FFootnotesPanel.Visible:=Notes<>'';
      FFootnotesMemo.Color:=ThemeBackground; FFootnotesMemo.Font.Color:=ThemeText;
      FFootnotesPanel.Color:=ThemeBackground; FFootnotesLabel.Font.Color:=HeadingColor;
      FFootnotesMemo.Text:=Notes; FFootnotesLabel.Caption:='Сноски на этой странице';
    finally EnableAlign; end;
    FBitmap.Canvas.Brush.Color:=ThemeBackground;
    FBitmap.Canvas.FillRect(Rect(0,0,FBitmap.Width,FBitmap.Height));
    if FSearchQuery<>'' then HighlightTextPage;
    FNext:=FormatText(CurrentPosition,FNext,True);
    FStatus.Caption:=Format('%d%% · Шрифт %d · Колесо — страницы · Ctrl+колесо — размер',[Min(100,Round(ReadingProgress*100)),FFontSize]);
    if Assigned(FDocument) and (FDocument.SkippedImages>0) then FStatus.Caption:=FStatus.Caption+' · Изображений пропущено: '+IntToStr(FDocument.SkippedImages);
  end;
  if Assigned(FPDF) then I:=ChapterIndexAt(CurrentPosition) else I:=ChapterIndexAt(Max(CurrentPosition,FNext-1));
  FChapters.ItemIndex:=I;
  if I>=0 then FChapters.Hint:=ChapterTitle(I) else FChapters.Hint:='Оглавление (Ctrl+T)';
  UpdateChapterPath; RebuildAnnotationMarkers;
  FPageHasBookmark:=False;
  for var Position in FBookmarkPositions do
    if Assigned(FPDF) then begin if Position=FPage then FPageHasBookmark:=True; end
    else if (Position>=CurrentPosition) and (Position<FNext) then FPageHasBookmark:=True;
  if FAnnotationLoadError<>'' then FStatus.Caption:=FStatus.Caption+' · Заметки недоступны: '+FAnnotationLoadError;
  FLastPageInteraction:=GetTickCount64;
  if FSearchStatus<>'' then FStatus.Caption:=FSearchStatus;
  FProgressLine.Invalidate; FSurface.Invalidate; PrefetchNextPage;
end;

procedure TfrmBuiltinReader.PaintPage(Canvas: TCanvas);
var R: TRectF; Box: TRect; Size: TPoint; Boxes: TList<TRect>;
begin
  Canvas.Brush.Color:=ThemeBackground;
  Canvas.FillRect(FSurface.ClientRect);
  if FReady then
    begin
      if Assigned(FPDF) then
      begin
        Canvas.Draw(FPan.X,FPan.Y,FBitmap); PaintAnnotations(Canvas);
        if Length(FPDFSelectionRects)>0 then
        begin
          Size:=FPDF.PageSize(FPage); Boxes:=TList<TRect>.Create;
          try
          for R in FPDFSelectionRects do
          begin
            Box:=Rect(FPan.X+Round(R.Left*FBitmap.Width/Size.X),FPan.Y+Round((Size.Y-R.Bottom)*FBitmap.Height/Size.Y),
              FPan.X+Round(R.Right*FBitmap.Width/Size.X),FPan.Y+Round((Size.Y-R.Top)*FBitmap.Height/Size.Y));
            IntersectRect(Box,Box,FSurface.ClientRect);
            if not IsRectEmpty(Box) then Boxes.Add(Box);
          end;
          PaintSelection(Canvas,Boxes.ToArray);
          finally Boxes.Free; end;
        end;
      end else begin Canvas.Draw(0,0,FBitmap); PaintAnnotations(Canvas); PaintSelection(Canvas,FTextSelectionRects); end;
      PaintBookmarkMarker(Canvas);
    end
  else
    begin Canvas.Font.Assign(Font); Canvas.Font.Color:=ThemeText; Canvas.TextOut(24,24,FStatus.Caption); end;
end;

procedure TfrmBuiltinReader.ApplyBookStyles(ColorsOnly: Boolean; Start, Finish: Integer);
var Range: TReaderStyledRange; Characters: TCharFormat2; Selection: TCharRange; Color, TitleColor, SubtitleColor: TColor;
begin
  if not Assigned(FDocument) then Exit;
  // Semantic ranges survive reflow, font changes and search highlighting.
  // Nested ranges are stored after their enclosing block, so headings keep
  // their own appearance even inside a quote or poem.
  TitleColor:=HeadingColor; SubtitleColor:=HeadingColor(True);
  for Range in FStyleRanges do
  begin
    if (Range.Count<=0) or (Range.Start>=Finish) or (Range.Start+Range.Count<=Start) then Continue;
    if not FBookFormatting and not (Range.Kind in [rbInitial,rbParagraphInitial]) then Continue;
    Color:=ThemeText;
    if Range.Kind in [rbTitle,rbSubtitle] then
      begin if Range.Kind=rbSubtitle then Color:=SubtitleColor else Color:=TitleColor; end
    else if Range.Kind in [rbInitial,rbParagraphInitial] then
    begin
      if (FInitialsMode=rimNone) or ((Range.Kind=rbParagraphInitial) and (FInitialsMode<>rimParagraph)) then Continue;
      Color:=TitleColor;
    end
    else if Range.Kind=rbFootnote then
      if FNight then Color:=RGB(132,180,242) else Color:=RGB(34,94,164)
    else if Range.Kind in [rbEpigraph,rbCite,rbAuthor] then
      if FNight then Color:=RGB(178,193,184) else Color:=RGB(65,94,82);
    if (Range.Kind=rbRelativeSize) and ColorsOnly then Continue;
    FillChar(Characters,SizeOf(Characters),0); Characters.cbSize:=SizeOf(Characters);
    if Range.Kind=rbRelativeSize then
    begin
      Characters.dwMask:=CFM_SIZE;
      Characters.yHeight:=Max(160,MulDiv(FFontSize*20,Range.ScalePercent,100));
    end
    else begin Characters.dwMask:=CFM_COLOR; Characters.crTextColor:=ColorToRGB(Color); end;
    if not ColorsOnly then
    begin
      if Range.Kind in [rbTitle,rbSubtitle] then
      begin
        Characters.dwMask:=Characters.dwMask or CFM_SIZE;
        if Range.Kind=rbTitle then Characters.yHeight:=FFontSize*25 else Characters.yHeight:=FFontSize*22;
      end;
      if Range.Kind in [rbInitial,rbParagraphInitial] then
      begin Characters.dwMask:=Characters.dwMask or CFM_SIZE; Characters.yHeight:=FFontSize*32; end;
      if Range.Kind=rbCode then
      begin Characters.dwMask:=Characters.dwMask or CFM_FACE; StrPLCopy(PChar(@Characters.szFaceName[0]),'Consolas',LF_FACESIZE-1); end;
    end;
    // VCL SelLength obtains the length of the entire book on every run.
    // Native UTF-16 ranges avoid rescanning a million-character novel.
    Selection.cpMin:=Max(Start,Range.Start); Selection.cpMax:=Min(Finish,Range.Start+Range.Count);
    SendMessage(FRichEdit.Handle,EM_EXSETSEL,0,LPARAM(@Selection));
    SendMessage(FRichEdit.Handle,EM_SETCHARFORMAT,SCF_SELECTION,LPARAM(@Characters));
  end;
  FRichEdit.SelLength:=0;
end;

procedure TfrmBuiltinReader.EnsureBookStyles(Start, Finish: Integer);
var Interval: TPoint; I, First, Last, Previous: Integer; Language: string;
begin
  if Finish<=Start then Exit;
  First:=Max(0,Start); Last:=Min(FLength,Finish);
  repeat
    Previous:=First;
    for Interval in FStyledIntervals do
      if (Interval.X<=First) and (Interval.Y>First) then First:=Min(Last,Interval.Y);
  until First=Previous;
  if First>=Last then Exit;
  for Interval in FStyledIntervals do
    if (Interval.X<Last) and (Interval.Y>=Last) then Last:=Max(First,Interval.X);
  if First>=Last then Exit;
  // A page formats a small UTF-16 interval instead of every paragraph of a
  // long novel. Existing neighbouring intervals merge into one cache entry.
  ApplyBookStyles(False,First,Last);
  Language:=''; if Assigned(FDocument) then Language:=FDocument.Language;
  ApplyReaderFallbackFonts(FRichEdit,ReaderTextRange(FRichEdit,First,Last-First),FFontName,Language,First,
    procedure(Family: string) begin MissingReaderFont(Family); end);
  I:=FStyledIntervals.Count-1;
  while I>=0 do
  begin
    Interval:=FStyledIntervals[I];
    if (Interval.X<=Last) and (Interval.Y>=First) then
    begin First:=Min(First,Interval.X); Last:=Max(Last,Interval.Y); FStyledIntervals.Delete(I); end;
    Dec(I);
  end;
  FStyledIntervals.Add(Point(First,Last));
end;

procedure TfrmBuiltinReader.UpdateFootnotesPanel;
begin
  if not FShowFootnotes or not Assigned(FDocument) then FFootnotesPanel.Visible:=False;
  // RenderPage decides visibility from references on this page, not the whole book.
end;

procedure TfrmBuiltinReader.SetShowFootnotes(Value: Boolean);
begin
  if FShowFootnotes=Value then Exit;
  FShowFootnotes:=Value; UpdateFootnotesPanel; InvalidateLayout;
end;

function TfrmBuiltinReader.VisibleFootnotes: string;
begin if FFootnotesPanel.Visible then Result:=FFootnotesMemo.Text else Result:=''; end;

procedure TfrmBuiltinReader.SetBookFormatting(Value: Boolean);
begin
  if FBookFormatting=Value then Exit;
  FBookFormatting:=Value; FTypographyDirty:=True; InvalidateLayout;
end;

function TfrmBuiltinReader.HeadingColor(Subtitle: Boolean): TColor;
begin
  Result:=FHeadingColors[Ord(FNight),Ord(Subtitle)];
  if Result=clDefault then
    if FNight then Result:=RGB(164,190,225) else Result:=RGB(53,83,121);
  if FNight then Result:=ReadableReaderColor(Result,ThemeBackground);
end;

procedure TfrmBuiltinReader.SetHeadingColor(Value: TColor; Subtitle: Boolean);
begin
  if Value<>clDefault then Value:=ColorToRGB(Value) and $00FFFFFF;
  FHeadingColors[Ord(FNight),Ord(Subtitle)]:=Value; FTypographyDirty:=True; InvalidateLayout;
end;

procedure TfrmBuiltinReader.SetDecorativeInitials(Value: Boolean);
begin
  if Value then SetInitialsMode(rimChapter) else SetInitialsMode(rimNone);
end;

procedure TfrmBuiltinReader.SetInitialsMode(Value: TReaderInitialsMode);
begin
  if FInitialsMode=Value then Exit;
  FInitialsMode:=Value; FDecorativeInitials:=Value<>rimNone; FTypographyDirty:=True; InvalidateLayout;
end;

procedure TfrmBuiltinReader.InvalidateLayout;
var Position: Integer; Para: TParaFormat2; Characters: TCharFormat2;
begin
  if not FReady then Exit;
  FResizeTimer.Enabled:=False; Position:=CurrentPosition; ResetPagination;
  if not Assigned(FPDF) then
  begin
    if Assigned(FDocument) and (FDocument.ImageCount>0) and
      ((FImageWidth<>Max(16,TextAreaWidth-16)) or
       (FImageHeight<>Max(16,FullTextHeight-80))) then LoadPresentation;
    if FTypographyDirty then
    begin
    FRichEdit.Lines.BeginUpdate;
    try
    FRichEdit.SelectAll;
    // Apply face/size/color together, preserving bold and italic source runs.
    FillChar(Characters,SizeOf(Characters),0); Characters.cbSize:=SizeOf(Characters);
    Characters.dwMask:=CFM_SIZE or CFM_FACE or CFM_COLOR or CFM_BACKCOLOR;
    Characters.dwEffects:=CFE_AUTOBACKCOLOR; Characters.yHeight:=FFontSize*20;
    StrPLCopy(PChar(@Characters.szFaceName[0]),FFontName,LF_FACESIZE-1);
    Characters.crTextColor:=ThemeText;
    SendMessage(FRichEdit.Handle,EM_SETCHARFORMAT,SCF_ALL,LPARAM(@Characters));
    FillChar(Para,SizeOf(Para),0); Para.cbSize:=SizeOf(Para);
    Para.dwMask:=$00000100; Para.bLineSpacingRule:=5; Para.dyLineSpacing:=FLinePercent div 5;
    SendMessage(FRichEdit.Handle,EM_SETPARAFORMAT,0,LPARAM(@Para));
    FStyledIntervals.Clear; FHighlighted.Clear;
    FRichEdit.Color:=ThemeBackground;
    FRichEdit.SelLength:=0;
    finally FRichEdit.Lines.EndUpdate; end;
    FTypographyDirty:=False;
    end;
    FPages.Clear; FPages.Add(Position); FPage:=0;
  end;
  RenderPage;
end;

procedure TfrmBuiltinReader.NextPage;
begin
  if not FReady then Exit;
  if Assigned(FPDF) and FPDF.AsyncPages then
  begin
    RequestPage(FRequestedPage+1);
    Exit;
  end;
  ResetInspection;
  if Assigned(FPDF) then begin if FPage>=FPDF.PageCount-1 then Exit; Inc(FPage); end
  else
  begin
    // Returning from a fitted previous page must honor its already visited
    // successor, even when the final short tail also fits on this page.
    if FPage+1<FPages.Count then Inc(FPage)
    else
    begin
      if (FNext<=CurrentPosition) or (FNext>=FLength) then Exit;
      Inc(FPage); FPages.Add(FNext);
    end;
  end;
  FSearchStatus:=''; FReadingMoved:=True; RenderPage;
end;

procedure TfrmBuiltinReader.PreviousPage;
var L,H,M,Target,Start,Index: Integer; S: string;
begin
  if not FReady then Exit;
  if Assigned(FPDF) and FPDF.AsyncPages then
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
  if Assigned(FPDF) and FPDF.AsyncPages then begin RequestPage(Position); Exit; end;
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
  begin NewSize:=EnsureRange(FFontSize+Delta,8,48); if NewSize=FFontSize then Exit; FFontSize:=NewSize; FTypographyDirty:=True; end;
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
procedure TfrmBuiltinReader.FitPageClick(Sender: TObject);
begin if not FReady or not Assigned(FPDF) then Exit; ResetInspection; FZoom:=100; RenderPage; end;

procedure TfrmBuiltinReader.PreparePageSelection;
var Content: TRect; DPI, Width, Margin: Integer;
begin
  if not FReady or Assigned(FPDF) or (FNext<=CurrentPosition) then Exit;
  if not FPageSelection.Ready then
  begin
    DPI:=GetDeviceCaps(FBitmap.Canvas.Handle,LOGPIXELSX); Margin:=MulDiv(FMargin,DPI,96);
    Width:=Min(FBitmap.Width-2*Margin,TextAreaWidth);
    Content:=Rect((FBitmap.Width-Width) div 2,MulDiv(20,DPI,96),
      (FBitmap.Width+Width) div 2,FBitmap.Height-MulDiv(20,DPI,96));
    FPageSelection.Prepare(FRichEdit,CurrentPosition,FNext-CurrentPosition,FBitmap.Width,FBitmap.Height,DPI,Content);
  end;
end;

function TfrmBuiltinReader.TextCharacterAt(X,Y: Integer): Integer;
begin
  Result:=-1; if not FReady or Assigned(FPDF) or (FNext<=CurrentPosition) then Exit;
  PreparePageSelection; Result:=FPageSelection.CharacterAt(X,Y);
end;

procedure TfrmBuiltinReader.UpdateTextSelection(X,Y: Integer);
var Index: Integer;
begin
  Index:=TextCharacterAt(X,Y); if (Index<0) or (FTextSelectionStart<0) then Exit;
  FTextSelectionEnd:=Index; FTextSelectionRects:=FPageSelection.Rectangles(FTextSelectionStart,FTextSelectionEnd);
  FSurface.Invalidate;
end;

function TfrmBuiltinReader.SelectedText: string;
begin
  if Assigned(FPDF) then Exit(PDFSelectedText);
  Result:='';
  if (FTextSelectionStart<CurrentPosition) or (FTextSelectionStart>FNext) or (FTextSelectionEnd<0) then Exit;
  Result:=ReaderTextRange(FRichEdit,Min(FTextSelectionStart,FTextSelectionEnd),Abs(FTextSelectionEnd-FTextSelectionStart));
  Result:=Result.Replace(#$FFFC,'').Replace(#13#10,#10).Replace(#13,#10).Replace(#10,#13#10);
end;

procedure TfrmBuiltinReader.PaintSelection(Canvas: TCanvas; const Boxes: TArray<TRect>);
var Box, Clip: TRect; Blend: TBlendFunction;
begin
  if Length(Boxes)=0 then Exit;
  FSelectionTint.Canvas.Brush.Color:=RGB(75,135,210); FSelectionTint.Canvas.FillRect(Rect(0,0,1,1));
  FillChar(Blend,SizeOf(Blend),0); Blend.BlendOp:=AC_SRC_OVER; Blend.SourceConstantAlpha:=72;
  if FNight then Blend.SourceConstantAlpha:=56;
  for Box in Boxes do
    if IntersectRect(Clip,Box,FSurface.ClientRect) and not IsRectEmpty(Clip) then
      Winapi.Windows.AlphaBlend(Canvas.Handle,Clip.Left,Clip.Top,Clip.Width,Clip.Height,
        FSelectionTint.Canvas.Handle,0,0,1,1,Blend);
end;

function TfrmBuiltinReader.PDFCharacterAt(X,Y: Integer): Integer;
var Size: TPoint;
begin
  Result:=-1;
  if not FPDFPageHasText or PageLoading or not Assigned(FPDF) or (FBitmap.Width=0) then Exit;
  Size:=FPDF.PageSize(FPage);
  Result:=FPDF.TextCharacterAt(FPage,(X-FPan.X)*Size.X/FBitmap.Width,
    Size.Y-(Y-FPan.Y)*Size.Y/FBitmap.Height,4*Size.X/FBitmap.Width,4*Size.Y/FBitmap.Height);
end;

procedure TfrmBuiltinReader.SelectPDFCharacter(Index: Integer);
var Start,Count: Integer;
begin
  if (Index<0) or (FPDFSelectionAnchor<0) then Exit;
  FPDFSelectionEnd:=Index; Start:=Min(Index,FPDFSelectionAnchor); Count:=Abs(Index-FPDFSelectionAnchor)+1;
  FPDFSelectionRects:=FPDF.TextRectangles(FPage,Start,Count); FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.SelectText(Start, Count: Integer);
begin
  if Assigned(FPDF) then begin SelectPDFText(Start,Count); Exit; end;
  if not FReady or not FSelectionEnabled then Exit;
  FTextSelectionStart:=EnsureRange(Start,CurrentPosition,FNext);
  FTextSelectionEnd:=Min(FNext,FTextSelectionStart+Min(Max(0,Count),FNext-FTextSelectionStart));
  PreparePageSelection; FTextSelectionRects:=FPageSelection.Rectangles(FTextSelectionStart,FTextSelectionEnd);
  FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.SelectPDFText(Start, Count: Integer);
begin
  if not FPDFPageHasText or (Start<0) or (Count<=0) then Exit;
  FPDFSelectionAnchor:=Start; SelectPDFCharacter(Start+Count-1);
end;

function TfrmBuiltinReader.PDFSelectedText: string;
begin
  Result:='';
  if not FPDFPageHasText or (FPDFSelectionAnchor<0) or (FPDFSelectionEnd<0) then Exit;
  Result:=FPDF.TextRange(FPage,Min(FPDFSelectionAnchor,FPDFSelectionEnd),Abs(FPDFSelectionAnchor-FPDFSelectionEnd)+1);
end;

function TfrmBuiltinReader.PageText: string;
begin
  Result:=''; if not FReady then Exit;
  if Assigned(FPDF) then
  begin
    if FPDFPageHasText and not PageLoading then Result:=FPDF.TextRange(FPage,0,MaxInt);
  end
  else
  begin
    Result:=ReaderTextRange(FRichEdit,CurrentPosition,Max(0,FNext-CurrentPosition));
    if VisibleFootnotes<>'' then Result:=Result+#13#10+#13#10+VisibleFootnotes;
  end;
  Result:=Result.Replace(#$FFFC,'').Replace(#13#10,#10).Replace(#13,#10).Replace(#10,#13#10).Trim;
end;

function TfrmBuiltinReader.AllBookText: string;
begin
  Result:=''; if not FReady then Exit;
  if Assigned(FPDF) then Exit(PageText);
  Result:=BookText.Replace(#$FFFC,'').Replace(#13#10,#10).Replace(#13,#10).Replace(#10,#13#10).Trim;
  if Assigned(FDocument) then
  begin
    var Notes:=FDocument.FootnotesForRange(0,FLength,0);
    if Notes<>'' then Result:=Result+#13#10+#13#10+Notes;
  end;
end;

procedure TfrmBuiltinReader.CopyMenuPopup(Sender: TObject);
begin
  FCopyItem.Visible:=True; FCopyItem.Enabled:=SelectedText<>'';
  FCopyPageItem.Enabled:=PageText<>'';
  FCopyAllItem.Visible:=not Assigned(FPDF); FCopyAllItem.Enabled:=FReady and (FLength>0);
  FCopyViewItem.Enabled:=FCopyPageItem.Enabled;
end;

procedure TfrmBuiltinReader.CopyReaderText(const Text, SuccessStatus: string);
var Attempt: Integer;
begin
  // Other applications can briefly hold the shared Windows clipboard open.
  // Bound the retry and report contention without raising a UI exception.
  for Attempt:=0 to 9 do
  begin
    try
      Clipboard.AsText:=Text; FStatus.Caption:=SuccessStatus; Exit;
    except
      on E: EClipboardException do
        if Attempt<9 then Sleep(20);
    end;
  end;
  FStatus.Caption:='Буфер обмена занят. Повторите копирование.';
end;

procedure TfrmBuiltinReader.CopyTextClick(Sender: TObject);
var Text: string;
begin
  Text:=SelectedText; if Text='' then Text:=PageText;
  if Text='' then Exit;
  CopyReaderText(Text,'Текст скопирован');
end;

procedure TfrmBuiltinReader.CopyPageClick(Sender: TObject);
var Text: string;
begin
  Text:=PageText; if Text='' then Exit;
  CopyReaderText(Text,'Текст страницы скопирован');
end;

procedure TfrmBuiltinReader.CopyAllClick(Sender: TObject);
var Text: string;
begin
  if not FReady then Exit; Text:=AllBookText; if Text='' then Exit;
  CopyReaderText(Text,'Текст книги скопирован');
end;

procedure TfrmBuiltinReader.CopyViewClick(Sender: TObject);
var Dialog: TForm; Memo: TRichEdit; Tip: TLabel; CloseButton, NoteButton: TButton; Footer: TPanel; Text, Quote: string;
begin
  Text:=PageText; if Text='' then Exit;
  Dialog:=TForm.CreateNew(Self);
  try
    Dialog.Caption:='Текст страницы — выделение и копирование'; Dialog.Position:=poOwnerFormCenter;
    Dialog.SetBounds(0,0,720,540); Dialog.Constraints.MinWidth:=400; Dialog.Constraints.MinHeight:=300;
    Tip:=TLabel.Create(Dialog); Tip.Parent:=Dialog; Tip.Align:=alTop; Tip.Height:=30;
    Tip.Caption:='Выделите фрагмент мышью и нажмите Ctrl+C. Ctrl+A — выделить всю страницу.';
    Memo:=TRichEdit.Create(Dialog); Memo.PlainText:=True; Memo.Parent:=Dialog; Memo.Align:=alClient; Memo.ReadOnly:=True;
    Memo.ScrollBars:=ssVertical; Memo.WordWrap:=True; Memo.Font.Name:=FFontName; Memo.Font.Size:=FFontSize;
    Memo.Color:=ThemeBackground; Memo.Font.Color:=ThemeText; Memo.Text:=Text;
    Footer:=TPanel.Create(Dialog); Footer.Parent:=Dialog; Footer.Align:=alBottom; Footer.Height:=36; Footer.BevelOuter:=bvNone;
    NoteButton:=TButton.Create(Dialog); NoteButton.Parent:=Footer; NoteButton.Align:=alLeft; NoteButton.Width:=250;
    NoteButton.Caption:='Заметка с выделенной цитатой…'; NoteButton.OnClick:=QuoteNoteClick;
    CloseButton:=TButton.Create(Dialog); CloseButton.Parent:=Footer; CloseButton.Align:=alRight; CloseButton.Width:=120;
    CloseButton.Height:=32; CloseButton.Caption:='Закрыть'; CloseButton.ModalResult:=mrOk; CloseButton.Cancel:=True;
    Dialog.ActiveControl:=Memo; ApplyMHLControlTheme(Dialog);
    Memo.Color:=ThemeBackground; Memo.Font.Color:=ThemeText;
    ApplyReaderFallbackFonts(Memo,Memo.Text,FFontName);
    if Dialog.ShowModal=mrYes then begin Quote:=Memo.SelText; AddNote(Quote); end;
  finally Dialog.Free; end;
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
  FTheme:=Index; FThemes.ItemIndex:=Index; FNight:=Index>=4; FTypographyDirty:=True; InvalidateLayout;
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
  for Range in FHighlighted do ApplyBookStyles(True,Range.X,Range.X+Range.Y);
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
function EditReaderNote(Reader: TCustomForm; var Note: TReaderAnnotation): Boolean;
var Dialog: TForm; Header, Footer, Body: TPanel; TitleBox: TEdit; TextBox, QuoteBox: TMemo; Button: TButton; LabelText: TLabel;
begin
  Result:=False; Dialog:=TForm.CreateNew(Reader);
  try
    Dialog.Caption:='Заметка к книге'; Dialog.Position:=poOwnerFormCenter; Dialog.BorderStyle:=bsSizeable;
    Dialog.PopupMode:=pmExplicit;
    if Assigned(Screen.ActiveCustomForm) then Dialog.PopupParent:=Screen.ActiveCustomForm else Dialog.PopupParent:=Reader;
    Dialog.ClientWidth:=610; Dialog.ClientHeight:=440;
    Dialog.Constraints.MinWidth:=440; Dialog.Constraints.MinHeight:=350; Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=10;
    Header:=TPanel.Create(Dialog); Header.Parent:=Dialog; Header.Align:=alTop; Header.Height:=108; Header.BevelOuter:=bvNone;
    LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Header; LabelText.AutoSize:=False; LabelText.SetBounds(12,8,586,36);
    LabelText.WordWrap:=True; LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.Caption:=Note.BookTitle+' · '+Note.Place;
    LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Header; LabelText.Caption:='Название (необязательно)'; LabelText.SetBounds(12,48,586,20);
    TitleBox:=TEdit.Create(Dialog); TitleBox.Parent:=Header; TitleBox.SetBounds(12,72,586,26);
    TitleBox.Anchors:=[akLeft,akTop,akRight]; TitleBox.TextHint:='Название заметки'; TitleBox.MaxLength:=256; TitleBox.Text:=Note.Title;
    Footer:=TPanel.Create(Dialog); Footer.Parent:=Dialog; Footer.Align:=alBottom; Footer.Height:=48; Footer.BevelOuter:=bvNone;
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.SetBounds(368,8,110,30);
    Button.Anchors:=[akRight,akBottom]; Button.Caption:='Сохранить'; Button.ModalResult:=mrOk; Button.Default:=True;
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.SetBounds(486,8,112,30);
    Button.Anchors:=[akRight,akBottom]; Button.Caption:='Отмена'; Button.ModalResult:=mrCancel; Button.Cancel:=True;
    Body:=TPanel.Create(Dialog); Body.Parent:=Dialog; Body.Align:=alClient; Body.BevelOuter:=bvNone;
    LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Body; LabelText.AutoSize:=False; LabelText.Align:=alTop;
    LabelText.Height:=24; LabelText.Caption:='Ваши мысли';
    QuoteBox:=TMemo.Create(Dialog); QuoteBox.Parent:=Body; QuoteBox.Align:=alBottom; QuoteBox.Height:=100;
    QuoteBox.Text:='Цитата: '+Note.Quote; QuoteBox.ReadOnly:=True; QuoteBox.ScrollBars:=ssVertical; QuoteBox.Visible:=Note.Quote<>'';
    TextBox:=TMemo.Create(Dialog); TextBox.Parent:=Body; TextBox.Align:=alClient; TextBox.ScrollBars:=ssVertical;
    TextBox.TextHint:='Ваши мысли об этом месте книги…'; TextBox.MaxLength:=16384; TextBox.Text:=Note.Text;
    ApplyMHLControlTheme(Dialog); Dialog.ActiveControl:=TextBox;
    if Dialog.ShowModal=mrOk then
    begin
      Note.Title:=string(TitleBox.Text).Trim; Note.Text:=string(TextBox.Text).Trim;
      Result:=(Note.Title<>'') or (Note.Text<>'');
    end;
  finally Dialog.Free; end;
end;

procedure ExportReaderAnnotationItems(Owner: TCustomForm; const Items: TArray<TReaderAnnotation>; const Scope: string); forward;

function SavedReaderBookmarks(const SettingsFile, Identity: string; IncludeQuotes: Boolean = True): TArray<TReaderAnnotation>;
var Ini: TMemIniFile; Sections: TStringList; List: TList<TReaderAnnotation>; Note: TReaderAnnotation;
  BookID, Encoded: string;
begin
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8); Sections:=TStringList.Create; List:=TList<TReaderAnnotation>.Create;
  try
    if Identity<>'' then Sections.Add('Bookmarks.'+Identity) else Ini.ReadSections(Sections);
    for var Section in Sections do
    begin
      if not Section.StartsWith('Bookmarks.') then Continue;
      BookID:=Section.Substring(Length('Bookmarks.'));
      for var I:=0 to EnsureRange(Ini.ReadInteger(Section,'Count',0),0,100)-1 do
      begin
        Note:=Default(TReaderAnnotation); Note.ID:=IntToStr(I); Note.BookID:=BookID;
        Note.BookTitle:=Ini.ReadString('Book.'+BookID,'Title','Книга '+Copy(BookID,1,8));
        Note.Title:=Ini.ReadString(Section,'Title'+IntToStr(I),'Закладка '+IntToStr(I+1)).Replace('&&','&');
        Note.Position:=Ini.ReadInteger(Section,'Position'+IntToStr(I),0);
        Note.Created:=Ini.ReadString(Section,'Created'+IntToStr(I),'');
        Note.Place:=Ini.ReadString(Section,'Place'+IntToStr(I),'Сохранённое место в книге');
        Note.RangeIsPageText:=Ini.ReadBool(Section,'PageText'+IntToStr(I),False);
        if IncludeQuotes then
        begin
          Encoded:=Ini.ReadString(Section,'PageQuote'+IntToStr(I),'');
          if Length(Encoded)<=1024*1024 then
            try Note.Quote:=TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(Encoded));
            except Note.Quote:=''; end;
        end;
        List.Add(Note);
      end;
    end;
    Result:=List.ToArray;
  finally List.Free; Sections.Free; Ini.Free; end;
end;

type
  TReaderSavedDialog = class(TForm)
  private
    FReader: TfrmBuiltinReader;
    FSettingsFile, FCurrentIdentity, FCurrentTitle: string;
    FStore: TReaderAnnotations;
    FNotes: TArray<TReaderAnnotation>;
    FBookmarkRows: TArray<TReaderAnnotation>;
    FShowNotes, FShowBookmarks: TCheckBox;
    FList: TListView;
    FContext: TMemo;
    FBooks: TComboBox;
    FBookIDs: TStringList;
    FAdd, FExport: TButton;
    FExports: TPopupMenu;
    FRequestedNote: TReaderAnnotation;
    FUpdatingBooks: Boolean;
    procedure BuildUI;
    function SelectedBookID: string;
    procedure RebuildBooks;
    procedure BooksChanged(Sender: TObject);
    procedure KindChanged(Sender: TObject);
    procedure Reload;
    procedure SelectItem(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure OpenSelected(Sender: TObject);
    procedure EditSelected(Sender: TObject);
    procedure DeleteSelected(Sender: TObject);
    procedure DeleteAll(Sender: TObject);
    procedure AddSelected(Sender: TObject);
    procedure ExportMenu(Sender: TObject);
    procedure ExportSelected(Sender: TObject);
  protected
    procedure DoShow; override;
  public
    constructor CreateFor(Reader: TfrmBuiltinReader);
    constructor CreateProfile(AOwner: TComponent; const SettingsFile: string);
    destructor Destroy; override;
  end;

constructor TReaderSavedDialog.CreateFor(Reader: TfrmBuiltinReader);
begin
  inherited CreateNew(Reader); FReader:=Reader; FSettingsFile:=Reader.FSettingsFile;
  FCurrentIdentity:=Reader.FIdentity; FCurrentTitle:=Reader.FBookTitle; BuildUI;
end;

constructor TReaderSavedDialog.CreateProfile(AOwner: TComponent; const SettingsFile: string);
begin inherited CreateNew(AOwner); FSettingsFile:=SettingsFile; BuildUI; end;

procedure TReaderSavedDialog.BuildUI;
var Row, Footer, Body, Scope: TPanel; Button: TButton; Item: TMenuItem;
  procedure AddButton(const Name, Text: string; Width: Integer; Handler: TNotifyEvent);
  begin
    Button:=TButton.Create(Self); Button.Name:=Name; Button.Parent:=Row; Button.Align:=alLeft; Button.Left:=MaxInt;
    Button.Width:=Width; Button.Caption:=Text; Button.OnClick:=Handler;
  end;
begin
  FStore:=TReaderAnnotations.Create(FSettingsFile); FBookIDs:=TStringList.Create;
  Caption:='Закладки и заметки'; Position:=poOwnerFormCenter; BorderStyle:=bsSizeable;
  PopupMode:=pmExplicit;
  if Assigned(FReader) then PopupParent:=FReader else if Owner is TCustomForm then PopupParent:=TCustomForm(Owner);
  ClientWidth:=1100; ClientHeight:=560; Constraints.MinWidth:=730; Constraints.MinHeight:=380;
  Font.Name:='Segoe UI'; Font.Size:=10;
  Row:=TPanel.Create(Self); Row.Parent:=Self; Row.Align:=alTop; Row.Height:=38; Row.BevelOuter:=bvNone;
  AddButton('NotesAdd','Добавить заметку…',146,AddSelected); FAdd:=Button;
  AddButton('NotesEdit','Изменить…',106,EditSelected);
  AddButton('NotesDelete','Удалить',80,DeleteSelected);
  AddButton('NotesDeleteAll','Удалить все…',128,DeleteAll);
  AddButton('NotesExport','Экспорт…',130,ExportMenu); FExport:=Button;
  FExports:=TPopupMenu.Create(Self); FExports.Name:='NotesExportMenu';
  Item:=TMenuItem.Create(Self); Item.Name:='ExportBookNotes';
  Item.Caption:='Экспорт закладок и заметок выбранной книги…'; Item.Tag:=0; Item.OnClick:=ExportSelected; FExports.Items.Add(Item);
  Item:=TMenuItem.Create(Self); Item.Name:='ExportAllNotes';
  Item.Caption:='Экспорт закладок и заметок всех книг…'; Item.Tag:=1; Item.OnClick:=ExportSelected; FExports.Items.Add(Item);
  Scope:=TPanel.Create(Self); Scope.Parent:=Self; Scope.Align:=alTop; Scope.Top:=Row.Height; Scope.Height:=36; Scope.BevelOuter:=bvNone;
  FBooks:=TComboBox.Create(Self); FBooks.Name:='NotesBooks'; FBooks.Parent:=Scope; FBooks.SetBounds(8,4,ClientWidth-270,26);
  FBooks.Anchors:=[akLeft,akTop,akRight]; FBooks.Style:=csDropDownList; FBooks.OnChange:=BooksChanged;
  FShowNotes:=TCheckBox.Create(Self); FShowNotes.Name:='NotesShowNotes'; FShowNotes.Parent:=Scope;
  FShowNotes.SetBounds(ClientWidth-250,4,112,26); FShowNotes.Anchors:=[akTop,akRight];
  FShowNotes.Caption:='Заметки'; FShowNotes.Checked:=True; FShowNotes.OnClick:=KindChanged;
  FShowBookmarks:=TCheckBox.Create(Self); FShowBookmarks.Name:='NotesShowBookmarks'; FShowBookmarks.Parent:=Scope;
  FShowBookmarks.SetBounds(ClientWidth-130,4,122,26); FShowBookmarks.Anchors:=[akTop,akRight];
  FShowBookmarks.Caption:='Закладки'; FShowBookmarks.Checked:=True; FShowBookmarks.OnClick:=KindChanged;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom; Footer.Height:=42; Footer.BevelOuter:=bvNone;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.SetBounds(ClientWidth-248,6,132,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Открыть книгу'; Button.OnClick:=OpenSelected;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.SetBounds(ClientWidth-108,6,100,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Закрыть'; Button.ModalResult:=mrCancel; Button.Cancel:=True;
  Body:=TPanel.Create(Self); Body.Parent:=Self; Body.Align:=alClient; Body.BevelOuter:=bvNone;
  FContext:=TMemo.Create(Self); FContext.Parent:=Body; FContext.Align:=alBottom; FContext.Height:=155;
  FContext.ReadOnly:=True; FContext.ScrollBars:=ssVertical;
  FList:=TListView.Create(Self); FList.Name:='NotesList'; FList.Parent:=Body; FList.Align:=alClient; FList.ViewStyle:=vsReport;
  FList.ReadOnly:=True; FList.RowSelect:=True; FList.HideSelection:=False;
  with FList.Columns.Add do begin Caption:='Вид'; Width:=80; end;
  with FList.Columns.Add do begin Caption:='Название'; Width:=235; end;
  with FList.Columns.Add do begin Caption:='Место в книге'; Width:=175; end;
  with FList.Columns.Add do begin Caption:='Книга'; Width:=250; end;
  with FList.Columns.Add do begin Caption:='Добавлено'; Width:=280; end;
  FList.OnSelectItem:=SelectItem; FList.OnDblClick:=OpenSelected;
  RebuildBooks;
  if FCurrentIdentity<>'' then FBooks.ItemIndex:=FBookIDs.IndexOf(FCurrentIdentity);
  Reload; ApplyMHLControlTheme(Self); ActiveControl:=FList;
end;

procedure TReaderSavedDialog.DoShow;
var Work: TRect;
begin
  inherited;
  Work:=Monitor.WorkareaRect;
  if Assigned(PopupParent) then Work:=PopupParent.Monitor.WorkareaRect;
  // A dialog wider than a reader near the screen edge still stays reachable.
  Width:=Min(Width,Work.Width); Height:=Min(Height,Work.Height);
  SetBounds(EnsureRange(Left,Work.Left,Max(Work.Left,Work.Right-Width)),
    EnsureRange(Top,Work.Top,Max(Work.Top,Work.Bottom-Height)),Width,Height);
end;

destructor TReaderSavedDialog.Destroy;
begin FBookIDs.Free; FStore.Free; inherited; end;

function TReaderSavedDialog.SelectedBookID: string;
begin
  Result:='';
  if (FBooks.ItemIndex>=0) and (FBooks.ItemIndex<FBookIDs.Count) then Result:=FBookIDs[FBooks.ItemIndex];
end;

procedure TReaderSavedDialog.RebuildBooks;
var Titles: TStringList; Seen: TDictionary<string,Boolean>; Selected: string;
begin
  Selected:=SelectedBookID; FUpdatingBooks:=True;
  Titles:=TStringList.Create; Seen:=TDictionary<string,Boolean>.Create;
  try
    Titles.NameValueSeparator:=#9; Titles.Sorted:=True;
    if FCurrentIdentity<>'' then
    begin Seen.Add(FCurrentIdentity,True); Titles.Add(FCurrentTitle.Replace(#9,' ') + #9 + FCurrentIdentity); end;
    for var Note in FStore.Items do
      if Seen.TryAdd(Note.BookID,True) then Titles.Add(Note.BookTitle.Replace(#9,' ')+#9+Note.BookID);
    for var Note in SavedReaderBookmarks(FSettingsFile,'',False) do
      if Seen.TryAdd(Note.BookID,True) then Titles.Add(Note.BookTitle.Replace(#9,' ')+#9+Note.BookID);
    FBooks.Items.BeginUpdate;
    try
      FBooks.Clear; FBookIDs.Clear; FBooks.Items.Add('Все книги'); FBookIDs.Add('');
      for var I:=0 to Titles.Count-1 do
      begin FBooks.Items.Add(Titles.Names[I]); FBookIDs.Add(Titles.ValueFromIndex[I]); end;
      FBooks.ItemIndex:=Max(0,FBookIDs.IndexOf(Selected));
    finally FBooks.Items.EndUpdate; end;
  finally Seen.Free; Titles.Free; FUpdatingBooks:=False; end;
end;

procedure TReaderSavedDialog.BooksChanged(Sender: TObject);
begin if not FUpdatingBooks then Reload; end;

procedure TReaderSavedDialog.KindChanged(Sender: TObject);
begin Reload; end;

procedure TReaderSavedDialog.Reload;
var Row: TListItem; Identity, Created: string; Note: TReaderAnnotation;
begin
  FList.Items.BeginUpdate;
  try
    FList.Clear; Identity:=SelectedBookID; FNotes:=FStore.Items(Identity); FContext.Clear;
    if Identity='' then Caption:='Закладки и заметки — все книги'
    else Caption:='Закладки и заметки — '+FBooks.Text;
    FAdd.Enabled:=Assigned(FReader) and (Identity=FCurrentIdentity);
    for var I:=0 to High(FNotes) do
    begin
      if not FShowNotes.Checked then Continue;
      Row:=FList.Items.Add; Row.Caption:='Заметка'; Row.Data:=Pointer(NativeInt(I+1));
      Row.SubItems.Add(ReaderAnnotationDisplayTitle(FNotes[I])); Row.SubItems.Add(FNotes[I].Place);
      Row.SubItems.Add(FNotes[I].BookTitle); Row.SubItems.Add(ReaderAnnotationLocalTime(FNotes[I].Created));
    end;
    FBookmarkRows:=SavedReaderBookmarks(FSettingsFile,Identity);
    if FShowBookmarks.Checked then
    begin
      for var I:=0 to High(FBookmarkRows) do
      begin
        Note:=FBookmarkRows[I];
        if Assigned(FReader) and (Note.BookID=FCurrentIdentity) then
        begin
          Note.BookTitle:=FCurrentTitle;
          if Assigned(FReader.FPDF) then Note.Place:='Страница '+IntToStr(Note.Position+1)+' · '+Note.Place
          else Note.Place:=IntToStr(Round(Note.Position*100/Max(1,FReader.FLength)))+'% · '+Note.Place;
          if Note.Quote='' then Note.Quote:=FReader.BookmarkContext(StrToIntDef(Note.ID,-1));
          FBookmarkRows[I]:=Note;
        end;
        Row:=FList.Items.Add; Row.Caption:='Закладка'; Row.Data:=Pointer(-NativeInt(I+1));
        Row.SubItems.Add(Note.Title); Row.SubItems.Add(Note.Place); Row.SubItems.Add(Note.BookTitle);
        Created:=ReaderAnnotationLocalTime(Note.Created);
        if Created='' then Created:='Не сохранено в старой версии';
        Row.SubItems.Add(Created);
      end;
    end;
    if FList.Items.Count>0 then FList.Items[0].Selected:=True;
  finally FList.Items.EndUpdate; end;
end;

procedure TReaderSavedDialog.SelectItem(Sender: TObject; Item: TListItem; Selected: Boolean);
var Index: Integer;
begin
  if not Selected then Exit; Index:=NativeInt(Item.Data)-1; FContext.Clear;
  if (Index>=0) and (Index<Length(FNotes)) then
  begin
    FContext.Text:=FNotes[Index].Text+sLineBreak+sLineBreak+ReaderAnnotationLocalTime(FNotes[Index].Created);
    if FNotes[Index].Quote<>'' then FContext.Text:=FContext.Text+sLineBreak+sLineBreak+'Цитата: '+FNotes[Index].Quote;
  end
  else if NativeInt(Item.Data)<0 then
  begin
    var Note:=FBookmarkRows[-NativeInt(Item.Data)-1];
    FContext.Text:=Note.Title+sLineBreak+sLineBreak+ReaderAnnotationLocalTime(Note.Created)+sLineBreak+sLineBreak+Note.Quote;
  end;
end;

procedure TReaderSavedDialog.OpenSelected(Sender: TObject);
var Index: Integer;
begin
  if not Assigned(FList.Selected) then Exit; Index:=NativeInt(FList.Selected.Data);
  if Index>0 then
  begin
    if Assigned(FReader) and (FNotes[Index-1].BookID=FCurrentIdentity) then FReader.GoToPosition(FNotes[Index-1].Position)
    else FRequestedNote:=FNotes[Index-1];
  end
  else
  begin
    var Note:=FBookmarkRows[-Index-1];
    if Assigned(FReader) and (Note.BookID=FCurrentIdentity) then FReader.GoToPosition(Note.Position)
    else begin FRequestedNote:=Note; FRequestedNote.ID:='bookmark-'+Note.BookID+'-'+Note.ID; end;
  end;
  ModalResult:=mrOk;
end;

procedure TReaderSavedDialog.EditSelected(Sender: TObject);
var Index: Integer; Note: TReaderAnnotation; Ini: TMemIniFile; Title: string;
begin
  if not Assigned(FList.Selected) then Exit; Index:=NativeInt(FList.Selected.Data);
  if Index>0 then
  begin
    Note:=FNotes[Index-1];
    while EditReaderNote(Self,Note) do
    begin
      try FStore.Put(Note); if Assigned(FReader) then FReader.ReloadAnnotations; Reload; Break;
      except on E: Exception do MessageDlg('Не удалось сохранить. Текст остаётся в редакторе.'+sLineBreak+E.Message,mtError,[mbOK],0); end;
    end;
  end
  else
  begin
    Title:=FList.Selected.SubItems[0];
    if not InputQuery('Название закладки','Название:',Title) or (Title.Trim='') then Exit;
    Note:=FBookmarkRows[-Index-1];
    Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
    try
      Ini.WriteString('Bookmarks.'+Note.BookID,'Title'+Note.ID,Copy(Title.Trim,1,256).Replace('&','&&'));
      SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
    Reload;
  end;
end;

procedure TReaderSavedDialog.DeleteSelected(Sender: TObject);
var Index, Count: Integer; Ini: TMemIniFile; Section: string; Note: TReaderAnnotation;
begin
  if not Assigned(FList.Selected) then Exit;
  if MessageDlg('Удалить выбранную запись?',mtConfirmation,[mbYes,mbNo],0)<>mrYes then Exit;
  Index:=NativeInt(FList.Selected.Data);
  if Index>0 then begin FStore.Remove(FNotes[Index-1].ID); if Assigned(FReader) then FReader.ReloadAnnotations; end
  else
  begin
    Note:=FBookmarkRows[-Index-1]; Index:=StrToInt(Note.ID);
    Section:='Bookmarks.'+Note.BookID; Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
    try
      Count:=EnsureRange(Ini.ReadInteger(Section,'Count',0),0,100);
      for var I:=Index to Count-2 do
      begin
        Ini.WriteString(Section,'Title'+IntToStr(I),Ini.ReadString(Section,'Title'+IntToStr(I+1),''));
        Ini.WriteInteger(Section,'Position'+IntToStr(I),Ini.ReadInteger(Section,'Position'+IntToStr(I+1),0));
        Ini.WriteInteger(Section,'EndPosition'+IntToStr(I),Ini.ReadInteger(Section,'EndPosition'+IntToStr(I+1),0));
        Ini.WriteString(Section,'PageQuote'+IntToStr(I),Ini.ReadString(Section,'PageQuote'+IntToStr(I+1),''));
        for var Key in TArray<string>.Create('Created','Place','PageText') do
          Ini.WriteString(Section,Key+IntToStr(I),Ini.ReadString(Section,Key+IntToStr(I+1),''));
      end;
      Ini.DeleteKey(Section,'Title'+IntToStr(Count-1)); Ini.DeleteKey(Section,'Position'+IntToStr(Count-1));
      Ini.DeleteKey(Section,'EndPosition'+IntToStr(Count-1)); Ini.DeleteKey(Section,'PageQuote'+IntToStr(Count-1));
      for var Key in TArray<string>.Create('Created','Place','PageText') do Ini.DeleteKey(Section,Key+IntToStr(Count-1));
      Ini.WriteInteger(Section,'Count',Max(0,Count-1)); SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
  end;
  if Assigned(FReader) then begin FReader.ReloadBookmarkMarkers; FReader.RenderPage; end;
  RebuildBooks; Reload;
end;

procedure TReaderSavedDialog.AddSelected(Sender: TObject);
begin
  if not Assigned(FReader) then Exit;
  FReader.NotesClick(Sender); FreeAndNil(FStore); FStore:=TReaderAnnotations.Create(FSettingsFile); RebuildBooks; Reload;
end;

procedure TReaderSavedDialog.DeleteAll(Sender: TObject);
var Identity, Scope: string; Count: Integer; Ini: TMemIniFile; Sections: TStringList;
begin
  Identity:=SelectedBookID; Count:=FList.Items.Count;
  if Count=0 then Exit;
  if Identity='' then Scope:='из всех книг' else Scope:='книги «'+FBooks.Text+'»';
  if MessageDlg(Format('Удалить все показанные записи %s? Записей: %d. Учитываются галочки «Заметки» и «Закладки».',[Scope,Count]),mtConfirmation,[mbYes,mbNo],0)<>mrYes then Exit;
  if FShowNotes.Checked then FStore.RemoveAll(Identity);
  if FShowBookmarks.Checked then
  begin
    Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8); Sections:=TStringList.Create;
    try
      if Identity<>'' then Ini.EraseSection('Bookmarks.'+Identity)
      else
      begin
        Ini.ReadSections(Sections);
        for var Section in Sections do if Section.StartsWith('Bookmarks.') then Ini.EraseSection(Section);
      end;
      SaveMemIniFileAtomically(Ini);
    finally Sections.Free; Ini.Free; end;
  end;
  if Assigned(FReader) then FReader.ReloadAnnotations;
  RebuildBooks; Reload;
end;

procedure TReaderSavedDialog.ExportMenu(Sender: TObject);
var Point: TPoint;
begin
  FExports.Items[0].Enabled:=SelectedBookID<>'';
  FExports.Items[0].Caption:='Экспорт закладок и заметок выбранной книги…';
  FExports.Items[1].Caption:='Экспорт закладок и заметок всех книг…';
  Point:=FExport.ClientToScreen(System.Types.Point(0,FExport.Height)); FExports.Popup(Point.X,Point.Y);
end;

procedure TReaderSavedDialog.ExportSelected(Sender: TObject);
var Identity, Scope: string; AllBooks: Boolean; Items: TList<TReaderAnnotation>;
begin
  AllBooks:=TComponent(Sender).Tag=1; Identity:=SelectedBookID;
  if AllBooks then Identity:='';
  if FShowNotes.Checked and FShowBookmarks.Checked then Scope:='Закладки и заметки'
  else if FShowBookmarks.Checked then Scope:='Закладки' else Scope:='Заметки';
  if AllBooks then Scope:=Scope+' всех книг' else Scope:=Scope+' книги: '+FBooks.Text;
  Items:=TList<TReaderAnnotation>.Create;
  try
    if FShowNotes.Checked then for var Note in FStore.Items(Identity) do Items.Add(Note);
    if FShowBookmarks.Checked then for var Saved in SavedReaderBookmarks(FSettingsFile,Identity) do
    begin var Note:=Saved; Note.Title:='Закладка: '+Note.Title; Items.Add(Note); end;
    ExportReaderAnnotationItems(Self,Items.ToArray,Scope);
  finally Items.Free; end;
end;

function BrowseReaderNotes(Owner: TComponent; const SettingsFile: string; out OpenNote: TReaderAnnotation): Boolean;
var Dialog: TReaderSavedDialog;
begin
  OpenNote:=Default(TReaderAnnotation); Dialog:=TReaderSavedDialog.CreateProfile(Owner,SettingsFile);
  try
    Result:=(Dialog.ShowModal=mrOk) and (Dialog.FRequestedNote.ID<>'');
    if Result then OpenNote:=Dialog.FRequestedNote;
  finally Dialog.Free; end;
end;

procedure TfrmBuiltinReader.NotesClick(Sender: TObject);
begin
  if SelectedText<>'' then AddNote(SelectedText)
  else AddNote(PageText);
end;

procedure TfrmBuiltinReader.ReloadAnnotations;
var Store: TReaderAnnotations; Notes: TArray<TReaderAnnotation>; Needle, Context: string;
  First, Found: Integer;
begin
  FreeAndNil(FAnnotationIndex); FVisibleAnnotations:=nil; FAnnotationLoadError:='';
  ReloadBookmarkMarkers;
  if FSettingsFile='' then Exit;
  try
    Store:=TReaderAnnotations.Create(FSettingsFile);
    try Notes:=Store.Items(FIdentity); finally Store.Free; end;
    // Old profiles have a page position and quote, without a character range.
    // Resolve only an unambiguous nearby quote in memory; never rewrite it.
    if FReady and not Assigned(FPDF) then
      for var I:=0 to High(Notes) do
        if not ReaderAnnotationHasRange(Notes[I]) and (Notes[I].Quote<>'') then
        begin
          First:=EnsureRange(Notes[I].Position-4096,0,FLength);
          Context:=ReaderTextRange(FRichEdit,First,Min(24576,FLength-First));
          Needle:=Notes[I].Quote.Replace(#13#10,#13).Replace(#10,#13);
          Found:=Pos(Needle,Context);
          if (Found>0) and (Pos(Needle,Context,Found+1)=0) then
          begin Notes[I].RangeStart:=First+Found-1; Notes[I].RangeEnd:=Notes[I].RangeStart+Length(Needle); end;
        end;
    FAnnotationIndex:=TReaderAnnotationIndex.Create(Notes);
  except on E: Exception do FAnnotationLoadError:=E.Message; end;
  if FReady then begin RebuildAnnotationMarkers; FSurface.Invalidate; end;
end;

function TfrmBuiltinReader.VisibleAnnotationCount: Integer;
begin Result:=Length(FVisibleAnnotations); end;

procedure TfrmBuiltinReader.RebuildAnnotationMarkers;
var Notes: TArray<TReaderAnnotation>; Size: TPoint; Rectangles: TArray<TRectF>; Boxes: TList<TRect>;
  PageMarker, First, Last: Integer; R: TRectF; Box: TRect;
begin
  FVisibleAnnotations:=nil;
  if not FReady or not Assigned(FAnnotationIndex) or PageLoading then Exit;
  if Assigned(FPDF) then Notes:=FAnnotationIndex.QueryPage(FPage)
  else Notes:=FAnnotationIndex.Query(CurrentPosition,FNext);
  if Length(Notes)=0 then Exit;
  SetLength(FVisibleAnnotations,Length(Notes)); PageMarker:=0;
  for var I:=0 to High(Notes) do
  begin
    FVisibleAnnotations[I].Note:=Notes[I];
    if ReaderAnnotationHasRange(Notes[I]) then
    begin
      if Assigned(FPDF) then
      begin
        if not FPDFPageHasText or not Notes[I].RangeIsPageText then Continue;
        Size:=FPDF.PageSize(FPage);
        Rectangles:=FPDF.TextRectangles(FPage,Notes[I].RangeStart,Notes[I].RangeEnd-Notes[I].RangeStart);
        Boxes:=TList<TRect>.Create;
        try
          for R in Rectangles do
          begin
            Box:=Rect(Round(R.Left*FBitmap.Width/Max(1,Size.X)),Round((Size.Y-R.Bottom)*FBitmap.Height/Max(1,Size.Y)),
              Round(R.Right*FBitmap.Width/Max(1,Size.X)),Round((Size.Y-R.Top)*FBitmap.Height/Max(1,Size.Y)));
            if not IsRectEmpty(Box) then Boxes.Add(Box);
          end;
          FVisibleAnnotations[I].Rectangles:=Boxes.ToArray;
        finally Boxes.Free; end;
      end
      else if not Notes[I].RangeIsPageText then
      begin
        PreparePageSelection; First:=Max(CurrentPosition,Notes[I].RangeStart); Last:=Min(FNext,Notes[I].RangeEnd);
        FVisibleAnnotations[I].Rectangles:=FPageSelection.Rectangles(First,Last);
      end;
    end
    else
    begin
      // Notes without a quote mark the saved page rather than arbitrary text.
      Box:=Rect(5,24+PageMarker*24,22,43+PageMarker*24); Inc(PageMarker);
      FVisibleAnnotations[I].Rectangles:=TArray<TRect>.Create(Box);
    end;
  end;
end;

function TfrmBuiltinReader.AnnotationRectangle(const Box: TRect): TRect;
begin
  Result:=Box;
  if Assigned(FPDF) then OffsetRect(Result,FPan.X,FPan.Y);
end;

function TfrmBuiltinReader.AnnotationAtPoint(X,Y: Integer): Integer;
begin
  Result:=-1;
  if not FReady or PageLoading or FInspect then Exit;
  for var I:=0 to High(FVisibleAnnotations) do
    for var Box in FVisibleAnnotations[I].Rectangles do
      if PtInRect(AnnotationRectangle(Box),Point(X,Y)) then Exit(I);
end;

procedure TfrmBuiltinReader.PaintAnnotations(Canvas: TCanvas);
var Box, Clip: TRect; Blend: TBlendFunction; Color: TColor;
begin
  Color:=RGB(192,137,35); if FNight then Color:=RGB(232,190,87);
  FSelectionTint.Canvas.Brush.Color:=Color; FSelectionTint.Canvas.FillRect(Rect(0,0,1,1));
  FillChar(Blend,SizeOf(Blend),0); Blend.BlendOp:=AC_SRC_OVER; Blend.SourceConstantAlpha:=34;
  Canvas.Pen.Color:=Color; Canvas.Pen.Width:=Max(1,MulDiv(1,CurrentPPI,96));
  for var Mark in FVisibleAnnotations do
    for var R in Mark.Rectangles do
    begin
      Box:=AnnotationRectangle(R);
      if not IntersectRect(Clip,Box,FSurface.ClientRect) or IsRectEmpty(Clip) then Continue;
      Winapi.Windows.AlphaBlend(Canvas.Handle,Clip.Left,Clip.Top,Clip.Width,Clip.Height,
        FSelectionTint.Canvas.Handle,0,0,1,1,Blend);
      Canvas.MoveTo(Clip.Left,Clip.Bottom-2); Canvas.LineTo(Clip.Right,Clip.Bottom-2);
      if not ReaderAnnotationHasRange(Mark.Note) then
      begin
        Canvas.Brush.Style:=bsClear; Canvas.Rectangle(Clip); Canvas.Brush.Style:=bsSolid;
        Canvas.Font.Name:='Segoe UI'; Canvas.Font.Size:=9; Canvas.Font.Color:=Color;
        Canvas.TextOut(Clip.Left+4,Clip.Top,'✎');
      end;
    end;
end;

procedure TfrmBuiltinReader.AnnotationHover(X,Y: Integer);
var Index: Integer; Hint: string;
begin
  Index:=AnnotationAtPoint(X,Y); Hint:='';
  if Index>=0 then
  begin
    if FVisibleAnnotations[Index].Note.Title.Trim<>'' then Hint:=FVisibleAnnotations[Index].Note.Title+sLineBreak;
    Hint:=Hint+FVisibleAnnotations[Index].Note.Text;
    if Hint.Trim='' then Hint:=FVisibleAnnotations[Index].Note.Quote;
    if Length(Hint)>1200 then
    begin
      Hint:=Copy(Hint,1,1200);
      // Keep a shortened preview valid UTF-16 when its last character is emoji.
      if (Hint[Length(Hint)]>=#$D800) and (Hint[Length(Hint)]<=#$DBFF) then
        SetLength(Hint,Length(Hint)-1);
      Hint:=Hint+'…';
    end;
    Hint:=Hint+sLineBreak+'Щёлкните, чтобы открыть заметку целиком.';
  end;
  if FPageHasBookmark and PtInRect(BookmarkMarkerBounds,Point(X,Y)) then Hint:='На этой странице есть закладка. Щёлкните, чтобы открыть меню закладок.';
  if FSurface.Hint<>Hint then begin Application.CancelHint; FSurface.Hint:=Hint; end;
end;

procedure TfrmBuiltinReader.AnnotationClick(X,Y: Integer);
var Item: TMenuItem; Caption: string; P: TPoint;
begin
  FAnnotationMenu.Items.Clear; FAnnotationMenuNotes:=nil;
  for var I:=0 to High(FVisibleAnnotations) do
    for var Box in FVisibleAnnotations[I].Rectangles do
      if PtInRect(AnnotationRectangle(Box),Point(X,Y)) then
      begin
        Caption:=ReaderAnnotationDisplayTitle(FVisibleAnnotations[I].Note);
        if Caption='—' then Caption:=Copy(FVisibleAnnotations[I].Note.Text.Replace(#13,' ').Replace(#10,' '),1,72);
        if Caption='' then Caption:='Заметка к странице';
        Item:=TMenuItem.Create(FAnnotationMenu); Item.Caption:=Caption.Replace('&','&&');
        Item.Tag:=Length(FAnnotationMenuNotes); SetLength(FAnnotationMenuNotes,Item.Tag+1);
        FAnnotationMenuNotes[Item.Tag]:=FVisibleAnnotations[I].Note;
        Item.OnClick:=AnnotationMenuClick; FAnnotationMenu.Items.Add(Item); Break;
      end;
  if FAnnotationMenu.Items.Count=0 then Exit;
  P:=FSurface.ClientToScreen(Point(X,Y)); FAnnotationMenu.Popup(P.X,P.Y);
end;

procedure TfrmBuiltinReader.AnnotationMenuClick(Sender: TObject);
var Note, Current: TReaderAnnotation; Store: TReaderAnnotations;
  Index: Integer; Found: Boolean;
begin
  Index:=TMenuItem(Sender).Tag;
  if (Index<0) or (Index>=Length(FAnnotationMenuNotes)) then Exit;
  Note:=FAnnotationMenuNotes[Index];
  try Store:=TReaderAnnotations.Create(FSettingsFile);
  except on E: Exception do
    begin MessageDlg('Не удалось прочитать заметки.'+sLineBreak+E.Message,mtError,[mbOK],0); Exit; end;
  end;
  try
    Found:=False;
    for Current in Store.Items(FIdentity) do
      if Current.ID=Note.ID then begin Note:=Current; Found:=True; Break; end;
    if not Found then
    begin
      ReloadAnnotations;
      MessageDlg('Эта заметка уже удалена. Список обновлён.',mtInformation,[mbOK],0);
      Exit;
    end;
    while EditReaderNote(Self,Note) do
    begin
      try Store.Put(Note); ReloadAnnotations; Break;
      except on E: Exception do MessageDlg('Не удалось сохранить. Текст остаётся в редакторе.'+sLineBreak+E.Message,mtError,[mbOK],0); end;
    end;
  finally Store.Free; end;
end;

function TfrmBuiltinReader.CurrentChapterPath: string;
begin
  Result:=ChapterTitle(FChapters.ItemIndex);
  if Result='' then Result:=FBookTitle;
end;

procedure TfrmBuiltinReader.UpdateChapterPath;
var Foreground, Background: Cardinal;
begin
  FChapterPath.Caption:=CurrentChapterPath; FChapterPath.Hint:=FChapterPath.Caption;
  FChapterPath.Transparent:=False; FChapterPath.Color:=ThemeBackground;
  Foreground:=ColorToRGB(ThemeText); Background:=ColorToRGB(ThemeBackground);
  FChapterPath.Font.Color:=RGB((GetRValue(Foreground)*4+GetRValue(Background)) div 5,
    (GetGValue(Foreground)*4+GetGValue(Background)) div 5,
    (GetBValue(Foreground)*4+GetBValue(Background)) div 5);
end;

function TfrmBuiltinReader.AnnotationDraft(const Quote: string): TReaderAnnotation;
var Page, First, Last: Integer;
begin
  Result:=Default(TReaderAnnotation); Result.BookID:=FIdentity; Result.BookTitle:=FBookTitle;
  Result.Position:=CurrentPosition; Result.Quote:=Quote;
  if (Quote<>'') and (SelectedText=Quote) then
  begin
    if Assigned(FPDF) then
    begin
      First:=Min(FPDFSelectionAnchor,FPDFSelectionEnd); Last:=Max(FPDFSelectionAnchor,FPDFSelectionEnd)+1;
      Result.RangeIsPageText:=True;
    end
    else begin First:=Min(FTextSelectionStart,FTextSelectionEnd); Last:=Max(FTextSelectionStart,FTextSelectionEnd); end;
    if (First>=0) and (Last>First) then
    begin
      Result.RangeStart:=First; Result.RangeEnd:=Last;
      if not Assigned(FPDF) then Result.Position:=First;
    end;
  end
  else if (Quote<>'') and (Quote=PageText) then
  begin
    if Assigned(FPDF) then
    begin Result.RangeIsPageText:=True; Result.RangeStart:=0; Result.RangeEnd:=Length(Quote); end
    else begin Result.RangeStart:=CurrentPosition; Result.RangeEnd:=FNext; end;
  end;
  Page:=GlobalPageAt(Result.Position);
  Result.Place:=IntToStr(Round(ReadingProgress*100))+'%';
  if Page>0 then Result.Place:='Страница '+IntToStr(Page)+' · '+Result.Place;
  if FChapters.ItemIndex>=0 then Result.Place:=Result.Place+' · '+CurrentChapterPath;
end;

procedure TfrmBuiltinReader.AddNote(const Quote: string);
var Note: TReaderAnnotation; Store: TReaderAnnotations;
begin
  if not FReady or (FSettingsFile='') then Exit;
  Note:=AnnotationDraft(Quote);
  Store:=TReaderAnnotations.Create(FSettingsFile);
  try
    while True do
    begin
      if not EditReaderNote(Self,Note) then Exit;
      try Store.Put(Note); ReloadAnnotations; Break;
      except on E: Exception do MessageDlg('Не удалось сохранить. Текст остаётся в редакторе.'+sLineBreak+E.Message,mtError,[mbOK],0); end;
    end;
  finally Store.Free; end;
  FStatus.Caption:='Заметка сохранена. Открыть и экспортировать: «Закладки и заметки».';
end;

procedure TfrmBuiltinReader.NotesManageClick(Sender: TObject);
var Dialog: TReaderSavedDialog;
begin
  if not FReady or (FSettingsFile='') then Exit;
  Dialog:=TReaderSavedDialog.CreateFor(Self);
  try
    Dialog.ShowModal; FRequestedNote:=Dialog.FRequestedNote;
  finally Dialog.Free; end;
  if FRequestedNote.ID<>'' then ModalResult:=mrOk;
end;

function TfrmBuiltinReader.AnnotationItems(AllBooks: Boolean): TArray<TReaderAnnotation>;
var Store: TReaderAnnotations; List: TList<TReaderAnnotation>; Identity: string;
begin
  Store:=TReaderAnnotations.Create(FSettingsFile); List:=TList<TReaderAnnotation>.Create;
  try
    if AllBooks then Identity:='' else Identity:=FIdentity;
    for var Note in Store.Items(Identity) do List.Add(Note);
    for var Saved in SavedReaderBookmarks(FSettingsFile,Identity) do
    begin
      var Note:=Saved;
      Note.Title:='Закладка: '+Note.Title;
      if Note.BookID=FIdentity then
      begin
        Note.BookTitle:=FBookTitle;
        if Note.Quote='' then Note.Quote:=BookmarkContext(StrToIntDef(Note.ID,-1));
      end;
      List.Add(Note);
    end;
    Result:=List.ToArray;
  finally List.Free; Store.Free; end;
end;

function TfrmBuiltinReader.ExportAnnotations(AllBooks, HTML: Boolean): string;
begin Result:=ReaderAnnotationsText(AnnotationItems(AllBooks),HTML); end;

procedure TfrmBuiltinReader.ExportFormatChanged(Sender: TObject);
var Styles: TComponent;
begin
  Styles:=TComboBox(Sender).Owner.FindComponent('ExportStyle');
  if Styles is TComboBox then TComboBox(Styles).Enabled:=TComboBox(Sender).ItemIndex<>2;
end;

type TReaderExportOptionsDialog = class(TForm)
  procedure FormatChanged(Sender: TObject);
end;

procedure TReaderExportOptionsDialog.FormatChanged(Sender: TObject);
var Styles: TComponent;
begin
  Styles:=FindComponent('ExportStyle');
  if Styles is TComboBox then TComboBox(Styles).Enabled:=TComboBox(Sender).ItemIndex<>2;
end;

procedure ExportReaderAnnotationItems(Owner: TCustomForm; const Items: TArray<TReaderAnnotation>; const Scope: string);
var Dialog: TFileSaveDialog; StyleDialog: TForm; Styles, Formats: TComboBox; Tip: TLabel; Button: TButton;
  Text, Temporary, Extension, FilterName: string; Style, FormatIndex: Integer;
begin
  if Length(Items)=0 then begin MessageDlg('Нет записей для экспорта.',mtInformation,[mbOK],0); Exit; end;
  StyleDialog:=TReaderExportOptionsDialog.CreateNew(Owner); Dialog:=TFileSaveDialog.Create(Owner);
  try
    StyleDialog.Caption:='Экспорт заметок — оформление'; StyleDialog.Position:=poOwnerFormCenter;
    StyleDialog.PopupMode:=pmExplicit;
    if Assigned(Screen.ActiveCustomForm) then StyleDialog.PopupParent:=Screen.ActiveCustomForm else StyleDialog.PopupParent:=Owner;
    StyleDialog.BorderStyle:=bsDialog; StyleDialog.ClientWidth:=410; StyleDialog.ClientHeight:=244;
    StyleDialog.Font.Name:='Segoe UI'; StyleDialog.Font.Size:=10;
    Tip:=TLabel.Create(StyleDialog); Tip.Parent:=StyleDialog; Tip.AutoSize:=False; Tip.SetBounds(12,12,386,74); Tip.WordWrap:=True;
    Tip.Caption:=Scope+'. Оформление для HTML и DOCX сохраняет закладки, цитаты и ваши мысли.';
    Formats:=TComboBox.Create(StyleDialog); Formats.Parent:=StyleDialog; Formats.SetBounds(12,92,386,26);
    Formats.Style:=csDropDownList; Formats.Items.Add('Документ Word (DOCX)'); Formats.Items.Add('Документ HTML');
    Formats.Items.Add('Обычный текст (UTF-8)'); Formats.ItemIndex:=0;
    Styles:=TComboBox.Create(StyleDialog); Styles.Name:='ExportStyle'; Styles.Parent:=StyleDialog; Styles.SetBounds(12,130,386,26);
    Styles.Style:=csDropDownList; Styles.Items.Add('Строгий — компактный отчёт с разделителями');
    Styles.Items.Add('Классический — книжные заголовки и цитаты'); Styles.Items.Add('Современный — карточки с полями');
    Styles.Items.Add('Бумага — дневник с полями для размышлений'); Styles.ItemIndex:=1; Formats.OnChange:=TReaderExportOptionsDialog(StyleDialog).FormatChanged;
    Button:=TButton.Create(StyleDialog); Button.Parent:=StyleDialog; Button.SetBounds(166,198,112,30);
    Button.Caption:='Продолжить'; Button.ModalResult:=mrOk; Button.Default:=True;
    Button:=TButton.Create(StyleDialog); Button.Parent:=StyleDialog; Button.SetBounds(286,198,112,30);
    Button.Caption:='Отмена'; Button.ModalResult:=mrCancel; Button.Cancel:=True;
    ApplyMHLControlTheme(StyleDialog);
    if StyleDialog.ShowModal<>mrOk then Exit; Style:=Styles.ItemIndex; FormatIndex:=Formats.ItemIndex;
    Dialog.Title:='Экспорт — '+Scope;
    case FormatIndex of
      0: begin FilterName:='Документ Word (DOCX)'; Extension:='docx'; end;
      1: begin FilterName:='Документ HTML'; Extension:='html'; end;
    else begin FilterName:='Обычный текст UTF-8'; Extension:='txt'; end; end;
    Dialog.DefaultExtension:=Extension; Dialog.Options:=Dialog.Options+[fdoOverWritePrompt,fdoPathMustExist,fdoStrictFileTypes];
    with Dialog.FileTypes.Add do begin DisplayName:=FilterName; FileMask:='*.'+Extension; end;
    Dialog.FileName:='Закладки и заметки';
    // The Shell owns its file list. Do not apply a partial VCL skin to it.
    // A modern native picker follows Windows and restores our hooks on cancel.
    var SavedHooks:=TStyleManager.SystemHooks;
    TStyleManager.SystemHooks:=SavedHooks-[shDialogs];
    try
      if not Dialog.Execute(Owner.Handle) then Exit;
    finally TStyleManager.SystemHooks:=SavedHooks; end;
    Temporary:=Dialog.FileName+'.new-'+TGUID.NewGuid.ToString;
    try
      if FormatIndex=0 then TFile.WriteAllBytes(Temporary,ReaderAnnotationsDocx(Items,Style))
      else
      begin Text:=ReaderAnnotationsText(Items,FormatIndex=1,Style); TFile.WriteAllText(Temporary,Text,TEncoding.UTF8); end;
      if not MoveFileEx(PChar(Temporary),PChar(Dialog.FileName),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
    finally if TFile.Exists(Temporary) then TFile.Delete(Temporary); end;
    MessageDlg('Экспорт завершён. Записей: '+IntToStr(Length(Items))+sLineBreak+Dialog.FileName,mtInformation,[mbOK],0);
  finally Dialog.Free; StyleDialog.Free; end;
end;

procedure TfrmBuiltinReader.ExportNotesClick(Sender: TObject);
var AllBooks: Boolean; Scope: string;
begin
  AllBooks:=(Sender is TComponent) and (TComponent(Sender).Tag=1);
  if AllBooks then Scope:='Закладки и заметки всех книг'
  else Scope:='Закладки и заметки этой книги: '+FBookTitle;
  ExportReaderAnnotationItems(Self,AnnotationItems(AllBooks),Scope);
end;

procedure TfrmBuiltinReader.QuoteNoteClick(Sender: TObject);
begin TForm(TButton(Sender).Owner).ModalResult:=mrYes; end;

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

procedure TfrmBuiltinReader.BookmarkSaveClick(Sender: TObject);
var Title: string;
begin
  if not FReady then Exit;
  Title:=CurrentChapterPath;
  if InputQuery('Добавить закладку','Название (необязательно):',Title) then AddBookmark(Title);
end;
procedure TfrmBuiltinReader.BookmarkOpenClick(Sender: TObject); begin GoToBookmark(TMenuItem(Sender).Tag); end;

procedure TfrmBuiltinReader.AddBookmark(const CustomTitle: string);
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
    if CustomTitle.Trim<>'' then Title:=Copy(CustomTitle.Trim,1,256);
    Ini.WriteInteger(Section,'Position'+IntToStr(Count),CurrentPosition);
    if not Assigned(FPDF) then Ini.WriteInteger(Section,'EndPosition'+IntToStr(Count),FNext);
    // INI values remain single-line; preserve the whole rendered page verbatim.
    Ini.WriteString(Section,'PageQuote'+IntToStr(Count),TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(PageText)).Replace(#13,'').Replace(#10,''));
    Ini.WriteString(Section,'Title'+IntToStr(Count),Title.Replace('&','&&'));
    Ini.WriteString(Section,'Created'+IntToStr(Count),DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True));
    Ini.WriteString(Section,'Place'+IntToStr(Count),CurrentChapterPath);
    Ini.WriteBool(Section,'PageText'+IntToStr(Count),Assigned(FPDF));
    Ini.WriteString('Book.'+FIdentity,'Title',FBookTitle);
    Ini.WriteInteger(Section,'Count',Count+1); SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
  ReloadBookmarkMarkers; FPageHasBookmark:=True; FSurface.Invalidate;
  FStatus.Caption:='Закладка сохранена. Она доступна в «Закладки и заметки».';
end;

procedure TfrmBuiltinReader.ReloadBookmarkMarkers;
var Ini: TMemIniFile; Section: string; Count: Integer;
begin
  FBookmarkPositions:=nil; FPageHasBookmark:=False; if FSettingsFile='' then Exit;
  Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    Section:='Bookmarks.'+FIdentity; Count:=EnsureRange(Ini.ReadInteger(Section,'Count',0),0,100);
    SetLength(FBookmarkPositions,Count);
    for var I:=0 to Count-1 do
    begin
      FBookmarkPositions[I]:=Ini.ReadInteger(Section,'Position'+IntToStr(I),-1);
      if FReady then
        if Assigned(FPDF) then
        begin if FBookmarkPositions[I]=FPage then FPageHasBookmark:=True; end
        else if (FBookmarkPositions[I]>=CurrentPosition) and (FBookmarkPositions[I]<FNext) then FPageHasBookmark:=True;
    end;
  finally Ini.Free; end;
end;

function TfrmBuiltinReader.BookmarkMarkerBounds: TRect;
var Width, Height, Gap: Integer;
begin
  Width:=MulDiv(15,CurrentPPI,96); Height:=MulDiv(23,CurrentPPI,96); Gap:=MulDiv(8,CurrentPPI,96);
  Result:=Rect(FSurface.ClientWidth-Gap-Width,Gap,FSurface.ClientWidth-Gap,Gap+Height);
end;

procedure TfrmBuiltinReader.PaintBookmarkMarker(Canvas: TCanvas);
var R: TRect; Color: TColor;
begin
  if not FPageHasBookmark then Exit; R:=BookmarkMarkerBounds;
  Color:=RGB(113,130,145); if FNight then Color:=RGB(154,173,190);
  Canvas.Brush.Color:=Color; Canvas.Pen.Color:=Color; Canvas.Pen.Width:=1;
  Canvas.Polygon([Point(R.Left,R.Top),Point(R.Right,R.Top),Point(R.Right,R.Bottom),
    Point((R.Left+R.Right) div 2,R.Bottom-R.Width div 2),Point(R.Left,R.Bottom)]);
end;

function TfrmBuiltinReader.BookmarkContext(Index: Integer): string;
var Ini: TMemIniFile; Section, Encoded: string; Position, Finish: Integer;
begin
  Result:=''; if FSettingsFile='' then Exit;
  Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    Section:='Bookmarks.'+FIdentity;
    if (Index<0) or (Index>=EnsureRange(Ini.ReadInteger(Section,'Count',0),0,100)) then Exit;
    Encoded:=Ini.ReadString(Section,'PageQuote'+IntToStr(Index),'');
    if Encoded<>'' then Exit(TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(Encoded)));
    Position:=Ini.ReadInteger(Section,'Position'+IntToStr(Index),-1);
    if not FReady or (Position<0) or (Position>=FLength) then Exit;
    if Assigned(FPDF) then begin if FPDF.IsPageCached(Position) then Result:=FPDF.TextRange(Position,0,MaxInt); Exit; end;
    Finish:=Ini.ReadInteger(Section,'EndPosition'+IntToStr(Index),0);
    if (Finish<=Position) or (Finish>FLength) then Finish:=MeasureGlobalPage(Position);
    Result:=ReaderTextRange(FRichEdit,Position,Max(0,Finish-Position));
  finally Ini.Free; end;
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
      ShowSearchStatus('Найдено · Enter / F3 — следующий результат · Shift+F3 — предыдущий');
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
  if FontName.Trim<>'' then FFontName:=AvailableReaderFont(Copy(FontName.Trim,1,100));
  FLinePercent:=EnsureRange(LinePercent,100,180); FMargin:=EnsureRange(Margin,12,80);
  FTypographyDirty:=True; InvalidateLayout;
end;

procedure TfrmBuiltinReader.SetMaxTextWidth(Value: Integer);
begin
  if Value=0 then FMaxTextWidth:=0 else FMaxTextWidth:=EnsureRange(Value,320,1600);
  InvalidateLayout;
end;

procedure ConfigureReaderColorBox(Box: TColorBox; SelectedColor: TColor);
var I, SelectedIndex: Integer; Color: TColor; Caption: string;
begin
  // VCL includes clDefault only together with cbSystemColors. Keep the
  // automatic choice, but hide the unrelated Windows element colors.
  Box.Style:=[cbStandardColors,cbSystemColors,cbIncludeDefault,cbCustomColor];
  Box.Selected:=SelectedColor;
  for I:=Box.Items.Count-1 downto 17 do
    if Box.Colors[I]<>clDefault then
      Box.Items.Delete(I);
  SelectedIndex:=0;
  for I:=0 to Box.Items.Count-1 do
  begin
    Color:=Box.Colors[I]; Caption:=Box.Items[I];
    if I=0 then Caption:='Другой цвет…'
    else
    begin
      case Color of
        clDefault: Caption:='Автоматически (по теме)';
        clBlack: Caption:='Чёрный'; clMaroon: Caption:='Бордовый';
        clGreen: Caption:='Зелёный'; clOlive: Caption:='Оливковый';
        clNavy: Caption:='Тёмно-синий'; clPurple: Caption:='Фиолетовый';
        clTeal: Caption:='Бирюзовый'; clGray: Caption:='Серый';
        clSilver: Caption:='Светло-серый'; clRed: Caption:='Красный';
        clLime: Caption:='Лаймовый'; clYellow: Caption:='Жёлтый';
        clBlue: Caption:='Синий'; clFuchsia: Caption:='Фуксия';
        clAqua: Caption:='Голубой'; clWhite: Caption:='Белый';
      end;
      if Color=SelectedColor then SelectedIndex:=I;
    end;
    // Native combo string replacement can recreate its item. Keep the color
    // value as well as its caption, then select the actual standard item.
    Box.Items[I]:=Caption;
    Box.Items.Objects[I]:=TObject(NativeInt(Color));
  end;
  Box.ItemIndex:=SelectedIndex;
end;

procedure TfrmBuiltinReader.StyleClick(Sender: TObject);
var Dialog: TForm; FontBox, SizeBox, SpacingBox, MarginBox, WidthBox, ZoomBox, InitialBox: TComboBox; FontNames: TStringList; LabelText: TLabel; Button: TButton; FormattingBox, NotesBox, InitialCheck, HoldCheck, SelectionCheck: TCheckBox; TitleBox, SubtitleBox: TColorBox; I: Integer;
  procedure AddLabel(const Text: string; Top: Integer);
  begin LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.SetBounds(16,Top,100,22); LabelText.Caption:=Text; end;
  function Choice(Top: Integer): TComboBox;
  begin Result:=TComboBox.Create(Dialog); Result.Parent:=Dialog; Result.SetBounds(118,Top,216,26); Result.Style:=csDropDownList; end;
begin
  if Assigned(FPDF) then
  begin
    Dialog:=TForm.CreateNew(Self);
    try
      Dialog.Caption:='Приближение страницы'; Dialog.BorderStyle:=bsDialog; Dialog.Position:=poOwnerFormCenter;
      Dialog.ClientWidth:=350; Dialog.ClientHeight:=202; Dialog.Font.Assign(Font);
      AddLabel('Приближение, %',20); ZoomBox:=Choice(16);
      for I:=12 to 30 do ZoomBox.Items.Add(IntToStr(I*10));
      ZoomBox.ItemIndex:=ZoomBox.Items.IndexOf(IntToStr(FInspectionPercent));
      LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.AutoSize:=False; LabelText.SetBounds(16,52,318,32);
      LabelText.WordWrap:=True; LabelText.Caption:='Для сканов и комиксов. На странице с текстом мышь выделяет текст для копирования.';
      HoldCheck:=TCheckBox.Create(Dialog); HoldCheck.Parent:=Dialog; HoldCheck.SetBounds(16,88,320,28);
      HoldCheck.Caption:='Приближение при удержании'; HoldCheck.Checked:=FInspectionHold;
      HoldCheck.ShowHint:=True; HoldCheck.Hint:='Отпускание кнопки возвращает прежний масштаб. Без галочки возвращает повторный щелчок.';
      SelectionCheck:=TCheckBox.Create(Dialog); SelectionCheck.Parent:=Dialog; SelectionCheck.SetBounds(16,118,320,28);
      SelectionCheck.Caption:='Выделять текст мышью'; SelectionCheck.Checked:=FSelectionEnabled;
      Button:=TButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(156,164,86,26); Button.Caption:='Применить'; Button.Default:=True; Button.ModalResult:=mrOk;
      Button:=TButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(248,164,86,26); Button.Caption:='Отмена'; Button.Cancel:=True; Button.ModalResult:=mrCancel;
      if Dialog.ShowModal=mrOk then begin SetInspectionPercent(StrToIntDef(ZoomBox.Text,150)); SetInspectionHold(HoldCheck.Checked); SetSelectionEnabled(SelectionCheck.Checked); end;
    finally Dialog.Free; end;
    Exit;
  end;
  Dialog:=TForm.CreateNew(Self); FontNames:=TStringList.Create;
  try
    Dialog.Caption:='Текст и оформление'; Dialog.BorderStyle:=bsDialog; Dialog.Position:=poOwnerFormCenter;
    Dialog.ClientWidth:=350; Dialog.ClientHeight:=467; Dialog.Font.Assign(Font);
    AddLabel('Шрифт / размер',20); FontBox:=Choice(16); FontBox.Width:=160;
    ReaderFontChoices(FontNames,FontBox.Items,FFontName); FontBox.ItemIndex:=FontNames.IndexOf(FFontName);
    SizeBox:=TComboBox.Create(Dialog); SizeBox.Parent:=Dialog; SizeBox.SetBounds(286,16,48,26); SizeBox.Style:=csDropDownList;
    SizeBox.Hint:='Размер шрифта'; SizeBox.ShowHint:=True;
    for I:=8 to 32 do SizeBox.Items.Add(IntToStr(I));
    if SizeBox.Items.IndexOf(IntToStr(FFontSize))<0 then SizeBox.Items.Add(IntToStr(FFontSize));
    SizeBox.ItemIndex:=SizeBox.Items.IndexOf(IntToStr(FFontSize));
    AddLabel('Интервал, %',58); SpacingBox:=Choice(54); SpacingBox.Items.Text:='100'+#13+'110'+#13+'120'+#13+'130'+#13+'140'+#13+'150'+#13+'160'+#13+'170'+#13+'180';
    SpacingBox.ItemIndex:=SpacingBox.Items.IndexOf(IntToStr(FLinePercent)); if SpacingBox.ItemIndex<0 then SpacingBox.ItemIndex:=1;
    AddLabel('Поля, пикс.',96); MarginBox:=Choice(92); MarginBox.Items.Text:='12'+#13+'20'+#13+'24'+#13+'32'+#13+'40'+#13+'48'+#13+'64'+#13+'80';
    MarginBox.ItemIndex:=MarginBox.Items.IndexOf(IntToStr(FMargin)); if MarginBox.ItemIndex<0 then MarginBox.ItemIndex:=3;
    AddLabel('Ширина, пикс.',134); WidthBox:=Choice(130);
    WidthBox.Items.Text:='Вся ширина'+#13+'320'+#13+'640'+#13+'800'+#13+'960'+#13+'1120'+#13+'1280'+#13+'1600';
    if FMaxTextWidth=0 then WidthBox.ItemIndex:=0 else
    begin
      if WidthBox.Items.IndexOf(IntToStr(FMaxTextWidth))<0 then WidthBox.Items.Add(IntToStr(FMaxTextWidth));
      WidthBox.ItemIndex:=WidthBox.Items.IndexOf(IntToStr(FMaxTextWidth));
    end;
    FormattingBox:=TCheckBox.Create(Dialog); FormattingBox.Parent:=Dialog; FormattingBox.SetBounds(16,166,320,26);
    FormattingBox.Caption:='Оформление книги: заголовки, стихи, цитаты'; FormattingBox.Checked:=FBookFormatting;
    NotesBox:=TCheckBox.Create(Dialog); NotesBox.Parent:=Dialog; NotesBox.SetBounds(16,196,320,26);
    NotesBox.Caption:='Показывать сноски этой страницы внизу'; NotesBox.Checked:=FShowFootnotes;
    InitialCheck:=TCheckBox.Create(Dialog); InitialCheck.Parent:=Dialog; InitialCheck.SetBounds(16,226,320,26);
    InitialCheck.Caption:='Выделять первые буквы абзацев'; InitialCheck.Checked:=FInitialsMode<>rimNone;
    AddLabel('Где выделять',260); InitialBox:=Choice(256);
    InitialBox.Items.Text:='В начале главы'+#13+'В каждом абзаце';
    InitialBox.ItemIndex:=Max(0,Ord(FInitialsMode)-1);
    AddLabel('Заголовки',296); TitleBox:=TColorBox.Create(Dialog); TitleBox.Parent:=Dialog; TitleBox.SetBounds(118,292,216,26);
    TitleBox.Style:=[cbStandardColors,cbIncludeDefault,cbCustomColor]; TitleBox.Selected:=FHeadingColors[Ord(FNight),0];
    AddLabel('Подзаголовки',330); SubtitleBox:=TColorBox.Create(Dialog); SubtitleBox.Parent:=Dialog; SubtitleBox.SetBounds(118,326,216,26);
    SubtitleBox.Style:=TitleBox.Style; SubtitleBox.Selected:=FHeadingColors[Ord(FNight),1];
    ConfigureReaderColorBox(TitleBox,FHeadingColors[Ord(FNight),0]);
    ConfigureReaderColorBox(SubtitleBox,FHeadingColors[Ord(FNight),1]);
    LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.AutoSize:=False; LabelText.SetBounds(16,392,318,34); LabelText.WordWrap:=True;
    SelectionCheck:=TCheckBox.Create(Dialog); SelectionCheck.Parent:=Dialog; SelectionCheck.SetBounds(16,356,320,28);
    SelectionCheck.Caption:='Выделять текст мышью'; SelectionCheck.Checked:=FSelectionEnabled;
    LabelText.Caption:='Цвета сохраняются для каждой темы. В тёмной теме слишком тёмные оттенки подсветляются.';
    Button:=TButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(156,435,86,26); Button.Caption:='Применить'; Button.Default:=True; Button.ModalResult:=mrOk;
    Button:=TButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(248,435,86,26); Button.Caption:='Отмена'; Button.Cancel:=True; Button.ModalResult:=mrCancel;
    if Dialog.ShowModal=mrOk then
    begin
      FBookFormatting:=FormattingBox.Checked; FShowFootnotes:=NotesBox.Checked; SetSelectionEnabled(SelectionCheck.Checked);
      if InitialCheck.Checked then FInitialsMode:=TReaderInitialsMode(EnsureRange(InitialBox.ItemIndex+1,1,2)) else FInitialsMode:=rimNone;
      FDecorativeInitials:=FInitialsMode<>rimNone; FTypographyDirty:=True;
      FHeadingColors[Ord(FNight),0]:=TitleBox.Selected; FHeadingColors[Ord(FNight),1]:=SubtitleBox.Selected;
      if WidthBox.ItemIndex=0 then FMaxTextWidth:=0 else FMaxTextWidth:=EnsureRange(StrToIntDef(WidthBox.Text,960),320,1600);
      FFontSize:=EnsureRange(StrToIntDef(SizeBox.Text,FFontSize),8,48);
      UpdateFootnotesPanel; SetTypography(FontNames[FontBox.ItemIndex],StrToIntDef(SpacingBox.Text,110),StrToIntDef(MarginBox.Text,32));
    end;
  finally FontNames.Free; Dialog.Free; end;
end;

procedure TfrmBuiltinReader.AddChapter(const Title: string; Position, Depth: Integer);
begin
  FChapterSourceTitles.Add(Title.Trim); FChapterDepths.Add(EnsureRange(Depth,-1,15));
  FChapters.Items.AddObject(Title.Trim,TObject(NativeInt(Position))); FContentsButton.Enabled:=True;
end;

procedure TfrmBuiltinReader.RebuildChapterTitles;
var Numbered: array[0..15] of Boolean; I, J, Depth, Selected: Integer; Title, Path: string;
  Matcher: TRegEx; Rebuilt: TStringList;
const NumberPattern = '^(\d+([.\-]\d+)*([.)]|\s|$)|[IVXLCDM]+([.)]|\s|$)|Глава\s+\d+|Chapter\s+\d+)';
begin
  Matcher:=TRegEx.Create(NumberPattern,[roIgnoreCase]);
  Rebuilt:=TStringList.Create;
  try
    Rebuilt.Capacity:=FChapterSourceTitles.Count;
    FillChar(Numbered,SizeOf(Numbered),0); FillChar(FChapterNumbers,SizeOf(FChapterNumbers),0);
    for I:=0 to 15 do FChapterParents[I]:='';
    for I:=0 to FChapterSourceTitles.Count-1 do
    begin
      Depth:=FChapterDepths[I];
      if (Depth>=0) and Matcher.IsMatch(FChapterSourceTitles[I]) then Numbered[Depth]:=True;
    end;
    Selected:=FChapters.ItemIndex; FChapters.Items.BeginUpdate; FChapterOutline.Clear;
    try
      for I:=0 to FChapterSourceTitles.Count-1 do
      begin
        Depth:=FChapterDepths[I]; Title:=FChapterSourceTitles[I];
        if Depth>=0 then
        begin
          Inc(FChapterNumbers[Depth]);
          for J:=Depth+1 to 15 do begin FChapterNumbers[J]:=0; FChapterParents[J]:=''; end;
          if FNumberChapters and not Numbered[Depth] then Title:=IntToStr(FChapterNumbers[Depth])+'. '+Title;
          FChapterParents[Depth]:=Title;
        end;
        Path:='';
        for J:=0 to Depth-1 do if FChapterParents[J]<>'' then Path:=Path+FChapterParents[J]+' › ';
        Rebuilt.AddObject(Path+Title,FChapters.Items.Objects[I]);
        FChapterOutline.Add(StringOfChar(' ',Max(0,Depth)*3)+Title);
      end;
      // Publish the identical labels/positions once, after the outline is complete.
      FChapters.Items.Assign(Rebuilt);
      FChapters.ItemIndex:=Selected;
    finally FChapters.Items.EndUpdate; end;
  finally Rebuilt.Free; end;
end;

procedure TfrmBuiltinReader.SetNumberChapters(Value: Boolean);
begin FNumberChapters:=Value; RebuildChapterTitles; UpdateChapterPath; end;

function TfrmBuiltinReader.ChapterIndexAt(Position: Integer): Integer;
begin
  Result:=-1;
  for var I:=FChapters.Items.Count-1 downto 0 do
    if NativeInt(FChapters.Items.Objects[I])<=Position then Exit(I);
end;

procedure TfrmBuiltinReader.ContentsClick(Sender: TObject);
var Dialog: TReaderContentsDialog;
begin
  if not FReady or (ChapterCount=0) then Exit;
  Dialog:=TReaderContentsDialog.CreateFor(Self);
  try if (Dialog.ShowModal=mrOk) and (Dialog.SelectedChapter>=0) then GoToChapter(Dialog.SelectedChapter);
  finally Dialog.Free; end;
  FSurface.SetFocus;
end;

function TfrmBuiltinReader.ChapterTitle(Index: Integer): string;
begin
  Result:=''; if (Index>=0) and (Index<ChapterCount) then Result:=FChapters.Items[Index];
end;

procedure TfrmBuiltinReader.GoToPosition(Position: Integer);
begin NavigateTo(Position); end;

function TfrmBuiltinReader.ReadingProgress: Double;
begin
  Result:=0; if not FReady or (FLength=0) then Exit;
  if Assigned(FPDF) then Result:=(CurrentPosition+1)/FLength
  else if FNext>=FLength then Result:=1 else Result:=CurrentPosition/FLength;
end;

procedure TfrmBuiltinReader.SeekProgress(Value: Double);
begin
  if not FReady then Exit; StopSearch;
  Value:=EnsureRange(Value,0.0,1.0);
  if Assigned(FPDF) then NavigateTo(Round(Value*Max(0,FLength-1)))
  else NavigateTo(ReaderCharacterStart(FRichEdit,Round(Value*Max(0,FLength-1))));
end;

procedure TfrmBuiltinReader.ProgressMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
begin
  if (Button<>mbLeft) or not FReady then Exit;
  FProgressDragging:=True; TReaderProgress(FProgressLine).MouseCapture:=True;
  FProgressTarget:=EnsureRange(X/Max(1,FProgressLine.Width-1),0.0,1.0);
  SeekProgress(FProgressTarget); FProgressLine.Invalidate;
end;

procedure TfrmBuiltinReader.ProgressMouseMove(Sender: TObject; Shift: TShiftState; X,Y: Integer);
begin
  if not FProgressDragging then Exit;
  if not (ssLeft in Shift) then begin ProgressMouseUp(Sender,mbLeft,Shift,X,Y); Exit; end;
  FProgressTarget:=EnsureRange(X/Max(1,FProgressLine.Width-1),0.0,1.0);
  FSeekTimer.Enabled:=True; FProgressLine.Invalidate;
end;

procedure TfrmBuiltinReader.ProgressMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
begin
  if not FProgressDragging or (Button<>mbLeft) then Exit;
  FProgressDragging:=False; TReaderProgress(FProgressLine).MouseCapture:=False; FSeekTimer.Enabled:=False;
  FProgressTarget:=EnsureRange(X/Max(1,FProgressLine.Width-1),0.0,1.0);
  SeekProgress(FProgressTarget); FSurface.SetFocus; FProgressLine.Invalidate;
end;

procedure TfrmBuiltinReader.SeekTick(Sender: TObject);
begin FSeekTimer.Enabled:=False; if FProgressDragging then SeekProgress(FProgressTarget); end;

procedure TfrmBuiltinReader.ResetPagination;
begin
  FGlobalPages.Clear; FGlobalPages.Add(0); FGlobalPagesDone:=False; FGlobalPagesFailed:=False;
  FPaginationTimer.Enabled:=False; FLastPageInteraction:=GetTickCount64;
end;

procedure TfrmBuiltinReader.RequestGlobalPages;
begin
  if FReady and not Assigned(FPDF) and not FGlobalPagesDone and not FGlobalPagesFailed then FPaginationTimer.Enabled:=True;
end;

function TfrmBuiltinReader.MeasureGlobalPage(Start: Integer): Integer;
var Height, NotesHeight: Integer; Notes: string; Box: TRect;
begin
  Height:=FullTextHeight;
  Result:=FormatText(Start,-1,False,FMeasureBitmap,FSurface.ClientWidth,Height);
  if FShowFootnotes and Assigned(FDocument) then
  begin
    Notes:=FDocument.FootnotesForRange(Start,Result);
    if Notes<>'' then
    begin
      FMeasureBitmap.Canvas.Font.Assign(FFootnotesMemo.Font);
      Box:=Rect(0,0,Max(40,FSurface.ClientWidth-56),0);
      DrawText(FMeasureBitmap.Canvas.Handle,PChar(Notes),Length(Notes),Box,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      NotesHeight:=Min(Max(70,Box.Height+54),Max(70,Min(200,Height div 3)));
      Result:=FormatText(Start,-1,False,FMeasureBitmap,FSurface.ClientWidth,Max(100,Height-NotesHeight));
    end;
  end;
end;

procedure TfrmBuiltinReader.PaginationTick(Sender: TObject);
var Started: UInt64; Next: Integer;
begin
  if FClosing or not FReady or Assigned(FPDF) or FGlobalPagesDone then begin FPaginationTimer.Enabled:=False; Exit; end;
  if FProgressDragging or FResizeTimer.Enabled or SearchRunning or (GetTickCount64-FLastPageInteraction<180) then Exit;
  FPaginationTimer.Enabled:=False; Started:=GetTickCount64;
  try
    repeat
      Next:=MeasureGlobalPage(FGlobalPages.Last);
      if (Next<=FGlobalPages.Last) or (Next>=FLength) then begin FGlobalPagesDone:=True; Break; end;
      FGlobalPages.Add(Next);
    until GetTickCount64-Started>=8;
  except
    // Optional page numbering must never interrupt reading or lose a position.
    FGlobalPagesFailed:=True; Exit;
  end;
  FPaginationTimer.Enabled:=not FGlobalPagesDone;
end;

function TfrmBuiltinReader.GlobalPageAt(Position: Integer): Integer;
var L,H,M: Integer;
begin
  Result:=0;
  if Assigned(FPDF) then Exit(EnsureRange(Position,0,Max(0,FLength-1))+1);
  if Position=0 then Exit(1);
  if (FGlobalPages.Count=0) or ((Position>=FGlobalPages.Last) and not FGlobalPagesDone) then Exit;
  L:=0; H:=FGlobalPages.Count-1;
  while L<H do begin M:=(L+H+1) div 2; if FGlobalPages[M]<=Position then L:=M else H:=M-1; end;
  Result:=L+1;
end;

function TfrmBuiltinReader.GlobalPaginationReady: Boolean;
begin Result:=Assigned(FPDF) or FGlobalPagesDone; end;

procedure TfrmBuiltinReader.PaintProgress(Sender: TObject);
begin
  if FNight then FProgressLine.Canvas.Brush.Color:=RGB(68,71,75) else FProgressLine.Canvas.Brush.Color:=RGB(215,220,226);
  FProgressLine.Canvas.FillRect(FProgressLine.ClientRect);
  if FNight then FProgressLine.Canvas.Brush.Color:=RGB(114,159,213) else FProgressLine.Canvas.Brush.Color:=RGB(67,117,174);
  FProgressLine.Canvas.FillRect(Rect(0,0,Round(FProgressLine.Width*IfThen(FProgressDragging,FProgressTarget,ReadingProgress)),FProgressLine.Height));
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
  if (ssCtrl in Shift) and (Key=Ord('C')) and (ActiveControl=FSurface) then
  begin
    if ssShift in Shift then CopyAllClick(nil) else CopyTextClick(nil); Key:=0; Exit;
  end;
  if (Key=VK_F3) and (FSearch.Text<>'') then
  begin FindText(FSearch.Text,ssShift in Shift); Key:=0; Exit; end;
  if FSearch.Focused then Exit;
  if (Key=Ord('T')) and (Shift=[ssCtrl]) then begin ContentsClick(nil); Key:=0; Exit; end;
  if (Key=Ord('M')) and (Shift=[ssCtrl]) then begin NotesClick(nil); Key:=0; Exit; end;
  if (Key=Ord('B')) and (Shift=[ssCtrl]) then begin BookmarkSaveClick(nil); Key:=0; Exit; end;
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
var Ini: TMemIniFile; Bounds,Work: TRect; Position,I,J: Integer;
begin
  if FSettingsFile='' then Exit;
  Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    // Loading can finish after the user has already adjusted the reader controls.
    if not FReady then
    begin
      FFontSize:=EnsureRange(Ini.ReadInteger('Reader','FontSize',14),8,48);
      FFontName:=AvailableReaderFont(Ini.ReadString('Reader','FontName','PT Serif'));
      FLinePercent:=EnsureRange(Ini.ReadInteger('Reader','LinePercent',110),100,180);
      FMargin:=EnsureRange(Ini.ReadInteger('Reader','Margin',32),12,80);
      FMaxTextWidth:=Ini.ReadInteger('Reader','MaxTextWidth',960);
      if FMaxTextWidth<>0 then FMaxTextWidth:=EnsureRange(FMaxTextWidth,320,1600);
      FBookFormatting:=Ini.ReadBool('Reader','BookFormatting',True);
      FShowFootnotes:=Ini.ReadBool('Reader','ShowFootnotes',True); FNumberChapters:=Ini.ReadBool('Reader','NumberChapters',True);
      FDecorativeInitials:=Ini.ReadBool('Reader','DecorativeInitials',False);
      FInitialsMode:=TReaderInitialsMode(EnsureRange(Ini.ReadInteger('Reader','InitialsMode',Ord(FDecorativeInitials)),0,2));
      FDecorativeInitials:=FInitialsMode<>rimNone;
      for I:=0 to 1 do for J:=0 to 1 do
      begin
        FHeadingColors[I,J]:=Ini.ReadInteger('Reader',Format('HeadingColor%d_%d',[I,J]),clDefault);
        if FHeadingColors[I,J]<>clDefault then FHeadingColors[I,J]:=FHeadingColors[I,J] and $00FFFFFF;
      end;
      FInspectionPercent:=EnsureRange(Ini.ReadInteger('Reader','InspectionPercent',150),120,300);
      FInspectionHold:=Ini.ReadBool('Reader','InspectionHold',True);
      FSelectionEnabled:=Ini.ReadBool('Reader','SelectionEnabled',True);
      // A new book always fits the window; zoom belongs to that book alone.
      FZoom:=EnsureRange(Ini.ReadInteger('Book.'+FIdentity,'Zoom',100),50,300); FNight:=Ini.ReadBool('Reader','Night',False);
      FTheme:=EnsureRange(Ini.ReadInteger('Reader','Theme',IfThen(FNight,5,0)),0,5);
      // Legacy settings do not record which app theme saved this reader choice.
      // Infer it once, then preserve manual reader choices within the same app theme.
      if Ini.ReadBool('Reader','AppThemeDark',FTheme>=4)<>MHLThemeDark then
        if MHLThemeDark then FTheme:=4 else FTheme:=1;
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

procedure TfrmBuiltinReader.WMAppTheme(var Message: TMessage);
begin
  if Message.WParam<>0 then SetTheme(4) else SetTheme(1);
end;

procedure TfrmBuiltinReader.SaveSettings;
var Ini: TMemIniFile; Bounds: TRect; I,J: Integer;
begin
  if FSettingsFile='' then Exit;
  Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
  try
    if FFullScreen then Bounds:=FNormalBounds
    else if WindowState<>wsNormal then Bounds:=FRestoredBounds else Bounds:=BoundsRect;
    Ini.WriteInteger('Reader','Left',Bounds.Left); Ini.WriteInteger('Reader','Top',Bounds.Top);
    Ini.WriteInteger('Reader','Width',Bounds.Width); Ini.WriteInteger('Reader','Height',Bounds.Height);
    Ini.WriteInteger('Reader','FontSize',FFontSize);
    Ini.WriteBool('Reader','BookFormatting',FBookFormatting);
    Ini.WriteBool('Reader','ShowFootnotes',FShowFootnotes); Ini.WriteBool('Reader','NumberChapters',FNumberChapters);
    Ini.WriteBool('Reader','DecorativeInitials',FDecorativeInitials);
    Ini.WriteInteger('Reader','InitialsMode',Ord(FInitialsMode));
    for I:=0 to 1 do for J:=0 to 1 do Ini.WriteInteger('Reader',Format('HeadingColor%d_%d',[I,J]),FHeadingColors[I,J]);
    Ini.WriteInteger('Reader','MaxTextWidth',FMaxTextWidth);
    Ini.WriteInteger('Reader','InspectionPercent',FInspectionPercent);
    Ini.WriteBool('Reader','InspectionHold',FInspectionHold);
    Ini.WriteBool('Reader','SelectionEnabled',FSelectionEnabled);
    if FInspect then Ini.WriteInteger('Reader','PDFZoom',FInspectZoom) else Ini.WriteInteger('Reader','PDFZoom',FZoom);
    Ini.WriteBool('Reader','Night',FNight);
    Ini.WriteInteger('Reader','Theme',FTheme); Ini.WriteBool('Reader','AppThemeDark',MHLThemeDark);
    Ini.WriteInteger('Reader','HighlightColor',FHighlightColor);
    Ini.WriteBool('Reader','SearchCase',FSearchCase.Checked); Ini.WriteBool('Reader','SearchWord',FSearchWord.Checked);
    Ini.WriteBool('Reader','SearchAll',FSearchAll.Checked);
    Ini.WriteString('Reader','FontName',FFontName); Ini.WriteInteger('Reader','LinePercent',FLinePercent); Ini.WriteInteger('Reader','Margin',FMargin);
    if FReady then
    begin
      Ini.WriteString('Book.'+FIdentity,'Title',FBookTitle);
      Ini.WriteInteger('Book.'+FIdentity,'Position',CurrentPosition);
      if FInspect then Ini.WriteInteger('Book.'+FIdentity,'Zoom',FInspectZoom) else Ini.WriteInteger('Book.'+FIdentity,'Zoom',FZoom);
    end;
    SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
  if FReady and FReadingMoved and Assigned(FOnProgress) then
    if not Assigned(FPDF) and (FNext>=FLength) then FOnProgress(100)
    else FOnProgress(EnsureRange(Round((CurrentPosition+Ord(Assigned(FPDF)))*100/Max(1,FLength)),0,100));
end;

procedure TfrmBuiltinReader.CloseReader(Sender: TObject; var Action: TCloseAction);
begin StopSearch; SaveSettings; end;

procedure OpenBuiltinReader(Owner: TComponent; const FileName, BookTitle, Identity,
  SettingsFile, PDFLibrary: string; const OnProgress: TProc<Integer>; const OnOpenNote: TProc<TReaderAnnotation>);
var Form: TfrmBuiltinReader; Requested: TReaderAnnotation;
begin
  Requested:=Default(TReaderAnnotation); Form:=TfrmBuiltinReader.Create(Owner);
  try
    Form.OpenBook(FileName,BookTitle,Identity,SettingsFile,PDFLibrary,OnProgress); Form.ShowModal;
    Requested:=Form.FRequestedNote;
  finally Form.Free; end;
  if (Requested.ID<>'') and Assigned(OnOpenNote) then OnOpenNote(Requested);
end;

end.
