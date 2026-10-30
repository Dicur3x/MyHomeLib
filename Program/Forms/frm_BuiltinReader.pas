unit frm_BuiltinReader;

interface

uses Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Graphics, Vcl.Menus, unit_MHLOperationStatus, unit_ReaderDocument, unit_ReaderPDF,
  unit_ReaderRaster, unit_ReaderPDFAsync, unit_ReaderFonts, unit_ReaderFontDownloads, unit_ReaderFontFallback, unit_ReaderAnnotations, unit_ReaderPageSelection;

type
  TReaderInitialsMode = (rimNone, rimChapter, rimParagraph);
  TReaderPageLayout = (rplSingle, rplDouble, rplAutomatic);
  TReaderPageTurn = (rptSpread, rptSliding);
  TReaderPageAppearance = (rpaFlat, rpaBook);
  TReaderPDFPageView = record
    Page: Integer;
    Size: TPoint;
    Bounds: TRect;
  end;
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
    Error, RequiredComponent: string;
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
    FInterfaceReturn: TButton;
    FInterfaceMenu: TMainMenu;
    FInterfaceSearch: Boolean;
    FOnInterfaceModeChanged: TNotifyEvent;
    FPDFSelecting, FPDFPageHasText: Boolean;
    FPDFSelectionAnchor, FPDFSelectionEnd: Integer;
    FPDFSelectionPage: Integer;
    FPDFPageViews: TArray<TReaderPDFPageView>;
    FPDFSelectionRects: TArray<TRectF>;
    FCopyMenu, FAnnotationMenu: TPopupMenu;
    FAnnotationIndex: TReaderAnnotationIndex;
    FVisibleAnnotations: TArray<TReaderVisibleAnnotation>;
    FAnnotationMenuNotes: TArray<TReaderAnnotation>;
    FAnnotationLoadError: string;
    FAnnotationClick: Integer;
    FTextLinkClick: Integer;
    FAnnotationMouseDown: TPoint;
    FBookmarkPositions: TArray<Integer>;
    FPageHasBookmark, FBookmarkClick: Boolean;
    FCopyItem, FCopyPageItem, FCopyAllItem, FCopyViewItem: TMenuItem;
    FDictionaryItem, FWebLookupItem, FGoogleItem, FYandexItem: TMenuItem;
    FDictionaryExecutable: string;
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
    FSecondPageSelection: TReaderPageSelection;
    FPageLayout: TReaderPageLayout;
    FPageTurn: TReaderPageTurn;
    FPageAppearance: TReaderPageAppearance;
    FSpreadLoading: Boolean;
    FSpreadBreaks: TArray<Integer>;
    FTextSelecting, FInspectionHold, FSelectionEnabled: Boolean;
    FTextSelectionStart, FTextSelectionEnd: Integer;
    FTextSelectionRects: TArray<TRect>;
    FSelectionTint: TBitmap;
    FFormattingHost: TForm;
    FOleCallback: IInterface;
    FBitmap: TBitmap;
    FDocument: TReaderDocument;
    FRequiredComponent: string;
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
    FNight, FFullScreen, FInterfaceHidden, FReady, FClosing, FLoadFinished, FReadingMoved, FWheelControl: Boolean;
    FBookFormatting, FShowFootnotes, FDecorativeInitials, FTypographyDirty: Boolean;
    FInitialsMode: TReaderInitialsMode;
    FHeadingColors: array[0..1,0..1] of TColor;
    FFootnotesPanel: TPanel;
    FFootnotesLabel: TLabel;
    FFootnotesMemo: TMemo;
    FIdentity, FSettingsFile, FFileName, FBookTitle: string;
    FNormalBounds, FRestoredBounds: TRect;
    FFullScreenPlacement: TWindowPlacement;
    FFullScreenBorder: TFormBorderStyle;
    FOnFullScreenModeChanged: TNotifyEvent;
    FFullScreenButton: TButton;
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
    FImageWidth, FImageHeight, FIllustrationHeightPercent: Integer;
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
    function TextLinkTargetAt(X,Y: Integer): Integer;
    procedure UpdateTextSelection(X,Y: Integer);
    procedure SelectWordAt(X,Y: Integer);
    procedure PaintSelection(Canvas: TCanvas; const Boxes: TArray<TRect>);
    procedure PreparePageSelection;
    function TextSelectionRectangles(Start, Finish: Integer): TArray<TRect>;
    procedure RebuildAnnotationMarkers;
    procedure PaintAnnotations(Canvas: TCanvas);
    function AnnotationRectangle(const Box: TRect): TRect;
    procedure AnnotationHover(X,Y: Integer);
    procedure AnnotationClick(X,Y: Integer);
    procedure AnnotationMenuClick(Sender: TObject);
    procedure RenderPage;
    procedure RenderPDFPages;
    function PDFViewRectangles(Page: Integer; const Rectangles: TArray<TRectF>): TArray<TRect>;
    procedure PaintPage(Canvas: TCanvas);
    procedure PaintPageDecoration(Canvas: TCanvas);
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
    procedure DictionaryLookupClick(Sender: TObject);
    procedure WebLookupClick(Sender: TObject);
    procedure ConfigureDictionaryClick(Sender: TObject);
    function ChooseDictionaryExecutable: Boolean;
    function PDFCharacterAt(X,Y: Integer): Integer;
    procedure SelectPDFCharacter(Index: Integer);
    procedure SmallerClick(Sender: TObject);
    procedure NightClick(Sender: TObject);
    procedure FullScreenClick(Sender: TObject);
    procedure InterfaceClick(Sender: TObject);
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
    function TextPageCount: Integer;
    function TextPageWidth(LayoutWidth: Integer = 0): Integer;
    function TextPageGap: Integer;
    function PageTurnStep: Integer;
    function NextTextPosition: Integer;
    function MeasurePreviousText(Start, Finish: Integer): Integer;
    function FullTextHeight: Integer;
    function IllustrationHeight: Integer;
    procedure UpdateFootnotesPanel;
    procedure ApplyBookStyles(ColorsOnly: Boolean = False; Start: Integer = 0; Finish: Integer = MaxInt);
    procedure EnsureBookStyles(Start, Finish: Integer);
    function FormatText(Start, Finish: Integer; Draw: Boolean; Target: TBitmap = nil; LayoutWidth: Integer = 0; LayoutHeight: Integer = 0): Integer;
    function FormatTextColumn(Start, Finish: Integer; Draw: Boolean; Target: TBitmap;
      LayoutWidth, LayoutHeight, Left: Integer): Integer;
    function CurrentPosition: Integer;
    procedure NavigateTo(Position: Integer);
  protected
    function OpenLookupTarget(const Target, Parameters, WorkingDirectory: string): Boolean; virtual;
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
    procedure SetPageLayout(Value: TReaderPageLayout);
    procedure SetPageTurn(Value: TReaderPageTurn);
    procedure SetPageAppearance(Value: TReaderPageAppearance);
    procedure RefreshWindowTheme;
    procedure ToggleInterface;
    property InterfaceHidden: Boolean read FInterfaceHidden;
    procedure ToggleFullScreen;
    property FullScreenMode: Boolean read FFullScreen;
    property OnFullScreenModeChanged: TNotifyEvent read FOnFullScreenModeChanged write FOnFullScreenModeChanged;
    property OnInterfaceModeChanged: TNotifyEvent read FOnInterfaceModeChanged write FOnInterfaceModeChanged;
    procedure ApplyWindowPalette(Form: TCustomForm);
    procedure SetShowFootnotes(Value: Boolean);
    procedure SetBookFormatting(Value: Boolean);
    procedure SetIllustrationHeightPercent(Value: Integer);
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
    property RequiredComponent: string read FRequiredComponent;
    property RequestedNote: TReaderAnnotation read FRequestedNote;
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
    property PageLayout: TReaderPageLayout read FPageLayout;
    property PageTurn: TReaderPageTurn read FPageTurn;
    property PageAppearance: TReaderPageAppearance read FPageAppearance;
    property VisiblePageCount: Integer read TextPageCount;
    property InspectionHold: Boolean read FInspectionHold;
    property SelectionEnabled: Boolean read FSelectionEnabled;
    function SelectedText: string;
    function PDFSelectedText: string;
    procedure SelectPDFText(Start, Count: Integer);
    procedure SelectText(Start, Count: Integer);
    property PDFPageHasText: Boolean read FPDFPageHasText;
  end;

  TReaderSavedDialog = class(TForm)
  private
    FReader: TfrmBuiltinReader;
    FSettingsFile, FCurrentIdentity, FCurrentTitle: string;
    FStore: TReaderAnnotations;
    FNotes, FBookmarkRows: TArray<TReaderAnnotation>;
    FVisibleRows: TArray<Integer>;
    FShowNotes, FShowBookmarks: TCheckBox;
    FList: TListView;
    FContext: TMemo;
    FBooks: TComboBox;
    FSearch: TEdit;
    FSearchTimer: TTimer;
    FResultStatus: TLabel;
    FBookIDs: TStringList;
    FAdd, FExport, FDeleteVisible: TButton;
    FExports: TPopupMenu;
    FRequestedNote: TReaderAnnotation;
    FUpdatingBooks: Boolean;
    procedure BuildUI;
    function SelectedBookID: string;
    function RowValue(Item: TListItem): Integer;
    function ScopeDescription: string;
    procedure RebuildBooks;
    procedure BooksChanged(Sender: TObject);
    procedure KindChanged(Sender: TObject);
    procedure SearchChanged(Sender: TObject);
    procedure SearchTick(Sender: TObject);
    procedure ClearSearch(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure FlushSearch;
    procedure ApplyFilter;
    procedure ItemData(Sender: TObject; Item: TListItem);
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
    function VisibleItems: TArray<TReaderAnnotation>;
  end;

function ReaderColorContrast(Foreground, Background: TColor): Double;
function ReadableReaderColor(Color, Background: TColor): TColor;
function ResolveReaderSettingsFile(const DataDir: string): string;

procedure ConfigureReaderColorBox(Box: TColorBox; SelectedColor: TColor);

procedure OpenBuiltinReader(Owner: TComponent; const FileName, BookTitle, Identity,
  SettingsFile, PDFLibrary: string; const OnProgress: TProc<Integer> = nil;
  const OnOpenNote: TProc<TReaderAnnotation> = nil; const OnMissingComponent: TProc<string> = nil);
function BrowseReaderNotes(Owner: TComponent; const SettingsFile: string; out OpenNote: TReaderAnnotation): Boolean;
function CreateReaderNotesDialog(Owner: TComponent; const SettingsFile: string): TCustomForm;
function EditAndSaveReaderNote(Owner: TCustomForm; Store: TReaderAnnotations;
  var Note: TReaderAnnotation): Boolean;

implementation

uses Winapi.ActiveX, Winapi.RichEdit, Winapi.CommDlg, Winapi.CommCtrl, Winapi.ShellAPI, System.Math, System.DateUtils, System.IOUtils, System.RegularExpressions,
  System.IniFiles, System.Hash, System.NetEncoding, Vcl.Dialogs, Vcl.Clipbrd, unit_ReaderRichEdit, unit_ReaderLookup, unit_MHLTheme, unit_AtomicIniFile, Vcl.Themes, unit_MHLExternalTools, unit_ReaderPalette;

type
  TReaderChapterSelector = class(TReaderPaletteCombo)
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
  if Assigned(FReader) and FReader.FReady and FReader.FSelectionEnabled and
    (Button=mbLeft) and (ssDouble in Shift) and not (ssCtrl in Shift) and
    (not Assigned(FReader.FPDF) or FReader.FPDFPageHasText) then
  begin
    FReader.FTextSelecting:=False; FReader.FPDFSelecting:=False; MouseCapture:=False;
    FReader.FAnnotationClick:=-1; FReader.FTextLinkClick:=-1; FReader.FBookmarkClick:=False;
    FReader.SelectWordAt(X,Y); Exit;
  end;
  if Assigned(FReader) and (Button=mbLeft) then
  begin
    FReader.FAnnotationMouseDown:=Point(X,Y);
    FReader.FAnnotationClick:=FReader.AnnotationAtPoint(X,Y);
    FReader.FTextLinkClick:=FReader.TextLinkTargetAt(X,Y);
    FReader.FBookmarkClick:=FReader.FPageHasBookmark and PtInRect(FReader.BookmarkMarkerBounds,Point(X,Y));
    if FReader.FBookmarkClick then begin MouseCapture:=True; Exit; end;
  end;
  if Assigned(FReader) and (Button=mbLeft) and not (ssCtrl in Shift) and Assigned(FReader.FPDF) then
  begin
    if FReader.FPDFPageHasText and FReader.FSelectionEnabled then
    begin
      FReader.FPDFSelecting:=False; FReader.FPDFSelectionAnchor:=-1;
      FReader.FPDFSelectionAnchor:=FReader.PDFCharacterAt(X,Y);
      FReader.FPDFSelecting:=FReader.FPDFSelectionAnchor>=0;
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
    if (FReader.FTextLinkClick>=0) and (FReader.FAnnotationClick<0) and not FReader.FBookmarkClick and
      not (ssCtrl in Shift) and (Abs(X-FReader.FAnnotationMouseDown.X)<=3) and
      (Abs(Y-FReader.FAnnotationMouseDown.Y)<=3) and
      (FReader.TextLinkTargetAt(X,Y)=FReader.FTextLinkClick) then
      FReader.NavigateTo(FReader.FTextLinkClick);
    FReader.FTextLinkClick:=-1;
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
    except
      on E: EMHLComponentRequired do begin Error:=E.Message; RequiredComponent:=E.ComponentID; end;
      on E: Exception do Error:=E.Message;
    end;
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
  FNumbers:=TReaderPaletteCheckBox.Create(Self); FNumbers.Parent:=Self; FNumbers.Align:=alTop; FNumbers.Top:=44;
  FNumbers.Height:=28; FNumbers.Caption:='Добавлять номера ненумерованным главам';
  FNumbers.Checked:=Reader.FNumberChapters; FNumbers.OnClick:=NumbersChanged;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom;
  Footer.Height:=44; Footer.BevelOuter:=bvNone;
  FGo:=TReaderPaletteButton.Create(Self); FGo.Parent:=Footer; FGo.SetBounds(380,8,110,28);
  FGo.Anchors:=[akRight,akBottom]; FGo.Caption:='Перейти'; FGo.Default:=True; FGo.ModalResult:=mrOk;
  Close:=TReaderPaletteButton.Create(Self); Close.Parent:=Footer; Close.SetBounds(500,8,112,28);
  Close.Anchors:=[akRight,akBottom]; Close.Caption:='Закрыть'; Close.Cancel:=True; Close.ModalResult:=mrCancel;
  FTree:=TTreeView.Create(Self); FTree.Parent:=Self; FTree.Align:=alClient;
  FTree.ReadOnly:=True; FTree.RowSelect:=True; FTree.HideSelection:=False;
  FTree.ShowLines:=False; FTree.ShowRoot:=True; FTree.BorderStyle:=bsNone;
  FTree.Font.Size:=11; FTree.Indent:=22; OnResize:=TreeResize;
  FTree.OnCustomDrawItem:=DrawNode; FTree.OnDblClick:=OpenSelected; FTree.OnKeyDown:=TreeKey;
  Filter(nil); Reader.ApplyWindowPalette(Self);
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

procedure DrawReaderOutline(Canvas: TCanvas; const Bounds: TRect; const Title: string; Depth, PPI: Integer; Selected: Boolean; Background, Foreground: TColor);
var TextBounds: TRect;
begin
  Canvas.Brush.Color:=Background; Canvas.Font.Color:=Foreground;
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
  DrawReaderOutline(FChapters.Canvas,Rect,Title,Depth,CurrentPPI,
    (odSelected in State) and not (odComboBoxEdit in State),ThemeBackground,ThemeText);
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
  FStop:=TReaderPaletteButton.Create(Self); FStop.Parent:=Row; FStop.SetBounds(10,38,152,30);
  FStop.Caption:='Остановить поиск'; FStop.OnClick:=StopClick;
  Button:=TReaderPaletteButton.Create(Self); Button.Parent:=Row; Button.SetBounds(462,38,158,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Перейти к результату'; Button.OnClick:=OpenSelected; Button.Default:=True;
  Button:=TReaderPaletteButton.Create(Self); Button.Parent:=Row; Button.SetBounds(630,38,100,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Закрыть'; Button.ModalResult:=mrCancel; Button.Cancel:=True;
  FList:=TListView.Create(Self); FList.Parent:=Self; FList.Align:=alClient; FList.ViewStyle:=vsReport;
  FList.OwnerData:=True; FList.ReadOnly:=True; FList.RowSelect:=True; FList.HideSelection:=False;
  with FList.Columns.Add do begin Caption:='№'; Width:=46; end;
  with FList.Columns.Add do begin Caption:='Страница книги'; Width:=110; end;
  with FList.Columns.Add do begin Caption:='Глава'; Width:=240; end;
  with FList.Columns.Add do begin Caption:='Текст вокруг совпадения'; Width:=480; end;
  FList.OnData:=ItemData; FList.OnDblClick:=OpenSelected; FList.OnKeyDown:=ListKey;
  FTimer:=TTimer.Create(Self); FTimer.Interval:=15; FTimer.OnTimer:=Tick;
  UpdateStatus('Поиск…'); Reader.ApplyWindowPalette(Self); ActiveControl:=FList;
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
    Button:=TReaderPaletteButton.Create(Self); Button.Parent:=SearchRow; Button.Align:=alRight;
    Button.Width:=Width; Button.Caption:=Text; Button.OnClick:=Handler; Button.TabStop:=False;
  end;
  function SearchCheck(const Text: string; Width: Integer): TCheckBox;
  begin
    Result:=TReaderPaletteCheckBox.Create(Self); Result.Parent:=OptionsRow; Result.Align:=alLeft;
    Result.Left:=MaxInt; Result.Width:=Width; Result.Caption:=Text; Result.OnClick:=SearchOptionsClick;
  end;
begin
  inherited CreateNew(AOwner);
  StyleName:='Windows'; StyleElements:=[];
  if AOwner is TCustomForm then
  begin PopupMode:=pmExplicit; PopupParent:=TCustomForm(AOwner); end;
  Caption:='HomeLibre — Читалка';
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
  FTop.Name:='ReaderToolbar'; FTop.Caption:='';
  FButtons:=TPanel.Create(Self); FButtons.Parent:=FTop; FButtons.Align:=alTop; FButtons.Height:=38; FButtons.BevelOuter:=bvNone;
  MakeButton('‹',PreviousClick,30); MakeButton('›',NextClick,30);
  MakeButton('−',SmallerClick,30); MakeButton('+',BiggerClick,30);
  FThemes:=TReaderPaletteCombo.Create(Self); FThemes.Parent:=FButtons; FThemes.Align:=alLeft;
  FThemes.Name:='ReaderThemeSelector';
  FThemes.Left:=MaxInt; FThemes.Width:=90; FThemes.Style:=csDropDownList;
  FThemes.Style:=csOwnerDrawFixed;
  FThemes.Items.Text:='Светлая'+#13+'Бумага'+#13+'Сепия'+#13+'Серая'+#13+'Тёмная'+#13+'Ночь';
  FThemes.ItemIndex:=0; FThemes.OnChange:=ThemeClick; FThemes.ShowHint:=True;
  FThemes.Hint:='Цветовая тема; для PDF тёмные темы включают инверсию страниц';
  FFitButton:=TReaderPaletteButton.Create(Self); FFitButton.Parent:=FButtons; FFitButton.Align:=alLeft;
  FFitButton.Left:=MaxInt; FFitButton.Width:=72; FFitButton.Caption:='Вписать';
  FFitButton.OnClick:=FitPageClick; FFitButton.Visible:=False;
  MakeButton('🔖︎',BookmarkSaveClick,34);
  MakeButton('✎',NotesClick,34);
  MakeButton('Закладки и заметки',NotesManageClick,154);
  MakeButton('Вид',StyleClick,50);
  MakeButton('Поиск',SearchClick,50);
  FChapterPath:=TLabel.Create(Self); FChapterPath.Name:='ReaderChapterPath';
  FChapterPath.Parent:=FTop; FChapterPath.Align:=alBottom; FChapterPath.AutoSize:=False;
  FChapterPath.Height:=22; FChapterPath.Margins.SetBounds(12,0,12,0); FChapterPath.AlignWithMargins:=True;
  FChapterPath.Layout:=tlCenter; FChapterPath.EllipsisPosition:=epEndEllipsis;
  FChapterPath.Font.Name:='Segoe UI'; FChapterPath.Font.Size:=9; FChapterPath.ShowHint:=True;
  FChapterPath.Hint:='Текущая глава и её разделы';
  ContentsRow:=TPanel.Create(Self); ContentsRow.Parent:=FTop; ContentsRow.Align:=alClient; ContentsRow.BevelOuter:=bvNone;
  Button:=TReaderPaletteButton.Create(Self); Button.Parent:=ContentsRow; Button.Align:=alRight;
  Button.Name:='ReaderHideInterface'; Button.Width:=132; Button.Caption:='Скрыть интерфейс';
  Button.OnClick:=InterfaceClick; Button.TabStop:=False;
  Button.Hint:='Скрыть меню и панели, сохранив размер окна'; Button.ShowHint:=True;
  FFullScreenButton:=TReaderPaletteButton.Create(Self); FFullScreenButton.Parent:=ContentsRow;
  FFullScreenButton.Align:=alRight; FFullScreenButton.Name:='ReaderFullScreen';
  FFullScreenButton.Width:=36; FFullScreenButton.Caption:='⛶';
  FFullScreenButton.OnClick:=FullScreenClick; FFullScreenButton.TabStop:=False;
  FFullScreenButton.Hint:='На весь экран / В окне (F11)'; FFullScreenButton.ShowHint:=True;
  FContentsButton:=TReaderPaletteButton.Create(Self); FContentsButton.Parent:=ContentsRow; FContentsButton.Align:=alLeft;
  FContentsButton.Width:=36; FContentsButton.Caption:='☰'; FContentsButton.Hint:='Оглавление (Ctrl+T)';
  FContentsButton.ShowHint:=True; FContentsButton.Enabled:=False; FContentsButton.OnClick:=ContentsClick;
  FChapters:=TReaderChapterSelector.Create(Self); FChapters.Name:='ReaderChapterSelector';
  TReaderChapterSelector(FChapters).OpenContents:=ContentsClick; FChapters.Parent:=ContentsRow; FChapters.Align:=alClient; FChapters.DropDownCount:=20;
  FChapters.TextHint:='Содержание книги'; FChapters.Style:=csOwnerDrawFixed; FChapters.ItemHeight:=24; FChapters.OnDrawItem:=DrawChapterItem; FChapters.OnChange:=ChapterClick; FChapters.Hint:='Содержание книги'; FChapters.ShowHint:=True;
  FBottom:=TPanel.Create(Self); FBottom.Parent:=Self; FBottom.Align:=alBottom; FBottom.Height:=40; FBottom.BevelOuter:=bvNone;
  FBottom.Name:='ReaderFooter'; FBottom.Caption:='';
  FStatus:=TLabel.Create(Self); FStatus.Parent:=FBottom; FStatus.Align:=alClient; FStatus.Layout:=tlCenter; FStatus.Alignment:=taCenter;
  FStatus.Caption:='Колесо — страницы · Ctrl+колесо — размер · F11 — полный экран · Ctrl+F — поиск';
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
  FSearchPanel:=TPanel.Create(Self); FSearchPanel.Name:='ReaderSearchPanel'; FSearchPanel.Parent:=Self; FSearchPanel.Align:=alTop; FSearchPanel.Height:=98; FSearchPanel.Visible:=False;
  SearchRow:=TPanel.Create(Self); SearchRow.Parent:=FSearchPanel; SearchRow.Align:=alTop; SearchRow.Height:=32; SearchRow.BevelOuter:=bvNone;
  SearchButton('×',28,SearchCloseClick);
  FSearch:=TEdit.Create(Self); FSearch.Parent:=SearchRow; FSearch.Align:=alClient; FSearch.TextHint:='Найти… Enter / Shift+Enter'; FSearch.OnKeyDown:=SearchKey;
  NavigationRow:=TPanel.Create(Self); NavigationRow.Parent:=FSearchPanel; NavigationRow.Align:=alTop;
  NavigationRow.Top:=32; NavigationRow.Height:=32; NavigationRow.BevelOuter:=bvNone;
  for I:=0 to 2 do
  begin
    Button:=TReaderPaletteButton.Create(Self); Button.Parent:=NavigationRow; Button.Align:=alLeft; Button.Left:=MaxInt;
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
  Button:=TReaderPaletteButton.Create(Self); Button.Parent:=OptionsRow; Button.Align:=alLeft; Button.Left:=MaxInt;
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
  MenuItem:=TMenuItem.Create(FCopyMenu); MenuItem.Caption:='-'; FCopyMenu.Items.Add(MenuItem);
  FDictionaryItem:=TMenuItem.Create(Self); FDictionaryItem.Name:='ReaderDictionaryLookup';
  FDictionaryItem.Caption:='Найти в словаре'; FDictionaryItem.OnClick:=DictionaryLookupClick;
  FCopyMenu.Items.Add(FDictionaryItem);
  FWebLookupItem:=TMenuItem.Create(Self); FWebLookupItem.Name:='ReaderWebLookup';
  FWebLookupItem.Caption:='Поиск в интернете'; FCopyMenu.Items.Add(FWebLookupItem);
  FGoogleItem:=TMenuItem.Create(Self); FGoogleItem.Name:='ReaderGoogleLookup';
  FGoogleItem.Caption:='Google'; FGoogleItem.Tag:=Ord(rltGoogle); FGoogleItem.OnClick:=WebLookupClick;
  FWebLookupItem.Add(FGoogleItem);
  FYandexItem:=TMenuItem.Create(Self); FYandexItem.Name:='ReaderYandexLookup';
  FYandexItem.Caption:='Яндекс'; FYandexItem.Tag:=Ord(rltYandex); FYandexItem.OnClick:=WebLookupClick;
  FWebLookupItem.Add(FYandexItem);
  MenuItem:=TMenuItem.Create(Self); MenuItem.Name:='ReaderDictionarySettings';
  MenuItem.Caption:='Выбрать словарь (GoldenDict)…'; MenuItem.OnClick:=ConfigureDictionaryClick;
  FCopyMenu.Items.Add(MenuItem);
  MenuItem:=TMenuItem.Create(FCopyMenu); MenuItem.Caption:='-'; FCopyMenu.Items.Add(MenuItem);
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
  FFontOffer.Caption:='';
  FFontOffer.Height:=68; FFontOffer.BevelOuter:=bvNone; FFontOffer.Visible:=False;
  FFontOfferText:=TLabel.Create(Self); FFontOfferText.Parent:=FFontOffer;
  FFontOfferText.Align:=alClient; FFontOfferText.WordWrap:=True; FFontOfferText.Layout:=tlCenter;
  FFontOfferText.Margins.SetBounds(12,4,12,4); FFontOfferText.AlignWithMargins:=True;
  FFontDownload:=TReaderPaletteButton.Create(Self); FFontDownload.Parent:=FFontOffer; FFontDownload.Align:=alRight;
  FFontDownload.Width:=100; FFontDownload.Caption:='Скачать'; FFontDownload.OnClick:=DownloadFontsClick;
  var LaterFont:=TReaderPaletteButton.Create(Self); LaterFont.Parent:=FFontOffer; LaterFont.Align:=alRight;
  LaterFont.Width:=80; LaterFont.Caption:='Позже'; LaterFont.OnClick:=DismissFontsClick;
  FInterfaceReturn:=TReaderPaletteButton.Create(Self); FInterfaceReturn.Parent:=Self;
  FInterfaceReturn.Name:='ReaderShowInterface'; FInterfaceReturn.Align:=alTop;
  FInterfaceReturn.Height:=20; FInterfaceReturn.Caption:='Показать интерфейс';
  FInterfaceReturn.Font.Size:=8; FInterfaceReturn.TabStop:=False;
  FInterfaceReturn.Visible:=False; FInterfaceReturn.OnClick:=InterfaceClick;
  FInterfaceReturn.Hint:='Вернуть меню и панели читалки'; FInterfaceReturn.ShowHint:=True;
  OnKeyDown:=KeyReader; OnResize:=ScheduleResize; OnClose:=CloseReader;
  RefreshWindowTheme;
end;

procedure TfrmBuiltinReader.MakeButton(const Caption: string; Action: TNotifyEvent; Width: Integer);
var Button: TButton;
begin
  Button:=TReaderPaletteButton.Create(Self); Button.Parent:=FButtons; Button.Align:=alLeft;
  Button.Left:=MaxInt; Button.Width:=Width; Button.Caption:=Caption; Button.OnClick:=Action;
  Button.TabStop:=False;
  if Caption='Ночь' then begin Button.Hint:='Ночной фон текста / инверсия страниц PDF'; Button.ShowHint:=True; end;
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
  FFontOffer.Visible:=(FMissingFonts.Count>0) and not FInterfaceHidden;
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
begin
  inherited; FFontWindowCookie:=RegisterReaderFontWindow(Handle);
  if Assigned(FSurface) then RefreshWindowTheme;
end;

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
  FSurface.FReader:=nil; FreeAndNil(FAnnotationIndex); FreeAndNil(FPageSelection); FreeAndNil(FSecondPageSelection); FreeAndNil(FSelectionTint);
  FPDF.Free; FDocument.Free; FBitmap.Free; FPages.Free; FHighlighted.Free; FStyledIntervals.Free; FChapterOutline.Free; FChapterSourceTitles.Free; FChapterDepths.Free; FGlobalPages.Free; FMeasureBitmap.Free; inherited;
end;

procedure TfrmBuiltinReader.OpenBook(const FileName, BookTitle, Identity, SettingsFile, PDFLibrary: string;
  const OnProgress: TProc<Integer>);
var Stream: TFileStream; Chapter: TPDFChapter;
begin
  FRequiredComponent := '';
  FMissingFonts.Clear; FFontOfferDeclined:=False; FFontsDownloading:=False; FFontOffer.Visible:=False;
  FFileName:=FileName; FIdentity:=Copy(THashSHA2.GetHashString(Identity),1,40);
  FSettingsFile:=SettingsFile; FOnProgress:=OnProgress; FBookTitle:=BookTitle;
  Caption:='HomeLibre — '+BookTitle+' — Читалка';
  RestoreSettings;
  RefreshWindowTheme;
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
  if FLoader.RequiredComponent<>'' then
  begin
    FRequiredComponent:=FLoader.RequiredComponent; FStatus.Caption:=FLoader.Error;
    ModalResult:=mrCancel; Close; Exit;
  end;
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
  Result:=FSpreadLoading or (Assigned(FPageWorker) and ((not FPageWorker.Prefetch) or (FRequestedPage<>FPage)));
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
  if TextPageCount=2 then Result:=Min(Result,3200);
end;

procedure TfrmBuiltinReader.PrefetchNextPage;
var Edge: Integer;
begin
  if FClosing or not FReady or (not Assigned(FPDF) or not FPDF.AsyncPages) or Assigned(FPageWorker) or
    (FRequestedPage<>FPage) then Exit;
  Edge:=DesiredRasterEdge;
  if TextPageCount=2 then
  begin
    for var I:=FPage to Min(FPDF.PageCount-1,FPage+1) do
      if not FPDF.IsPageCached(I,Edge) and
        ((FQualityAttemptPage<>I) or (FQualityAttemptEdge<>Edge)) then
      begin
        FQualityAttemptPage:=I; FQualityAttemptEdge:=Edge;
        FPageWorker:=TReaderPageThread.Create(FPDF,I,Edge);
        FPageWorker.Prefetch:=True; FPageTimer.Enabled:=True; FPageWorker.Start; Exit;
      end;
    Exit;
  end;
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
  FPDF.SetVisibleRange(FRequestedPage,Min(TextPageCount,FPDF.PageCount-FRequestedPage));
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
  if Preloaded and (Error='') and (Index>=FPage) and (Index<FPage+TextPageCount) and (FRequestedPage=FPage) then
  begin
    SavedPan:=FPan;
    try RenderPage; FPan:=SavedPan; ClampPan; FSurface.Invalidate;
    except on E: Exception do Error:=E.Message; end;
  end;
  if Preloaded and (Error<>'') and (Index>=FPage) and (Index<FPage+TextPageCount) then
  begin FSpreadLoading:=False; FStatus.Caption:='Не удалось открыть страницу: '+Error; end;
  if (FRequestedPage<>FPage) and (Preloaded or (FRequestedPage<>Index)) then
    RequestPage(FRequestedPage,FRequestedMoved)
  else if not Preloaded and (Error<>'') and (Index=FRequestedPage) then
  begin FSpreadLoading:=False; FStatus.Caption:='Не удалось открыть страницу: '+Error; end
  else PrefetchNextPage;
end;

function TfrmBuiltinReader.IllustrationHeight: Integer;
begin
  Result:=Max(16,FullTextHeight-80);
  // Zero keeps the ordinary book layout. Interactive scenes reserve space
  // for their prose instead of spending the first page on background art.
  if FIllustrationHeightPercent>0 then
    Result:=Max(16,MulDiv(Result,FIllustrationHeightPercent,100));
end;

procedure TfrmBuiltinReader.SetIllustrationHeightPercent(Value: Integer);
begin
  if (Value<0) or (Value>100) then raise EArgumentOutOfRangeException.Create('Неверная высота иллюстрации.');
  if FIllustrationHeightPercent=Value then Exit;
  FIllustrationHeightPercent:=Value;
  InvalidateLayout;
end;

procedure TfrmBuiltinReader.LoadPresentation;
var Stream: TReaderRTFStream;
begin
  FImageWidth:=Max(16,TextAreaWidth-16);
  FImageHeight:=IllustrationHeight;
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

function TfrmBuiltinReader.TextPageGap: Integer;
begin Result:=MulDiv(24,CurrentPPI,96); end;

function TfrmBuiltinReader.TextPageCount: Integer;
var Minimum: Integer;
begin
  Result:=1;
  if FPageLayout=rplSingle then Exit;
  Minimum:=2*(MulDiv(200,CurrentPPI,96)+2*MulDiv(FMargin,CurrentPPI,96))+TextPageGap;
  if FPageLayout=rplAutomatic then Minimum:=Max(Minimum,MulDiv(1100,CurrentPPI,96));
  if FSurface.ClientWidth>=Minimum then Result:=2;
end;

function TfrmBuiltinReader.TextPageWidth(LayoutWidth: Integer): Integer;
begin
  if LayoutWidth<=0 then LayoutWidth:=FSurface.ClientWidth;
  Result:=(LayoutWidth-(TextPageCount-1)*TextPageGap) div TextPageCount;
end;

function TfrmBuiltinReader.PageTurnStep: Integer;
begin
  Result:=1; if (TextPageCount=2) and (FPageTurn=rptSpread) then Result:=2;
end;

function TfrmBuiltinReader.NextTextPosition: Integer;
begin
  Result:=FNext;
  if (TextPageCount=2) and (FPageTurn=rptSliding) and (Length(FSpreadBreaks)>2) then Result:=FSpreadBreaks[1];
end;

function TfrmBuiltinReader.MeasurePreviousText(Start, Finish: Integer): Integer;
begin
  if (TextPageCount=2) and (FPageTurn=rptSliding) then
    Result:=FormatTextColumn(Start,Finish,False,FBitmap,TextPageWidth,FBitmap.Height,0)
  else Result:=FormatText(Start,Finish,False);
end;

procedure TfrmBuiltinReader.SetPageTurn(Value: TReaderPageTurn);
begin
  if FPageTurn=Value then Exit;
  FPageTurn:=Value; InvalidateLayout;
end;

procedure TfrmBuiltinReader.SetPageAppearance(Value: TReaderPageAppearance);
begin
  if FPageAppearance=Value then Exit;
  FPageAppearance:=Value; FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.SetPageLayout(Value: TReaderPageLayout);
begin
  if FPageLayout=Value then Exit;
  ResetInspection; FPageLayout:=Value; InvalidateLayout;
end;

function TfrmBuiltinReader.TextAreaWidth: Integer;
begin
  Result:=Max(16,TextPageWidth-FMargin*2);
  if FMaxTextWidth>0 then Result:=Min(Result,MulDiv(FMaxTextWidth,CurrentPPI,96));
end;

function TfrmBuiltinReader.FullTextHeight: Integer;
begin
  Result:=FSurface.ClientHeight;
  if FFootnotesPanel.Visible then Inc(Result,FFootnotesPanel.Height);
end;

function TfrmBuiltinReader.FormatText(Start, Finish: Integer; Draw: Boolean; Target: TBitmap; LayoutWidth, LayoutHeight: Integer): Integer;
var I, Count, Width: Integer;
begin
  if not Assigned(Target) then Target:=FBitmap;
  if LayoutWidth<=0 then LayoutWidth:=Target.Width;
  if LayoutHeight<=0 then LayoutHeight:=Target.Height;
  Count:=TextPageCount; Width:=TextPageWidth(LayoutWidth); Result:=Start;
  if Draw then SetLength(FSpreadBreaks,Count+1);
  for I:=0 to Count-1 do
  begin
    if Draw then FSpreadBreaks[I]:=Result;
    if (Result<FLength) and ((Finish<0) or (Result<Finish)) then
      Result:=FormatTextColumn(Result,Finish,Draw,Target,Width,LayoutHeight,I*(Width+TextPageGap));
    if Draw then FSpreadBreaks[I+1]:=Result;
  end;
end;

function TfrmBuiltinReader.FormatTextColumn(Start, Finish: Integer; Draw: Boolean; Target: TBitmap;
  LayoutWidth, LayoutHeight, Left: Integer): Integer;
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
      Range.rcPage:=Rect(MulDiv(Left,1440,DPI),0,MulDiv(Left+LayoutWidth,1440,DPI),MulDiv(LayoutHeight,1440,DPI));
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

function TfrmBuiltinReader.PDFViewRectangles(Page: Integer; const Rectangles: TArray<TRectF>): TArray<TRect>;
var Boxes: TList<TRect>; Box: TRect;
begin
  Boxes:=TList<TRect>.Create;
  try
    for var View in FPDFPageViews do
      if View.Page=Page then
        for var R in Rectangles do
        begin
          Box:=Rect(View.Bounds.Left+Round(R.Left*View.Bounds.Width/Max(1,View.Size.X)),
            View.Bounds.Top+Round((View.Size.Y-R.Bottom)*View.Bounds.Height/Max(1,View.Size.Y)),
            View.Bounds.Left+Round(R.Right*View.Bounds.Width/Max(1,View.Size.X)),
            View.Bounds.Top+Round((View.Size.Y-R.Top)*View.Bounds.Height/Max(1,View.Size.Y)));
          if not IsRectEmpty(Box) then Boxes.Add(Box);
        end;
    Result:=Boxes.ToArray;
  finally Boxes.Free; end;
end;

procedure TfrmBuiltinReader.RenderPDFPages;
var Views: TArray<TReaderPDFPageView>; Raster, Spread: TBitmap;
  Count, Gap, TotalWidth, MaximumHeight, Width, Height, Left: Integer; Scale: Double;
  procedure Mark(Raster: TBitmap; const Size: TPoint; const Rectangles: TArray<TRectF>);
  var Box: TRect; Pixel: PRGBQuad; Color: Cardinal;
  begin
    Color:=ColorToRGB(FHighlightColor); GdiFlush;
    for var R in Rectangles do
    begin
      Box:=Rect(Max(0,Round(R.Left*Raster.Width/Size.X)-2),Max(0,Round((Size.Y-R.Bottom)*Raster.Height/Size.Y)-2),
        Min(Raster.Width,Round(R.Right*Raster.Width/Size.X)+2),Min(Raster.Height,Round((Size.Y-R.Top)*Raster.Height/Size.Y)+2));
      for var Y:=Box.Top to Box.Bottom-1 do
      begin
        // PDF rasters are top-down DIBs. ScanLine already follows their
        // stored row order; reversing Y mirrors the highlight vertically.
        Pixel:=Raster.ScanLine[Y]; Inc(Pixel,Box.Left);
        for var X:=Box.Left to Box.Right-1 do
        begin
          Pixel.rgbRed:=(Integer(Pixel.rgbRed)*2+GetRValue(Color)) div 3;
          Pixel.rgbGreen:=(Integer(Pixel.rgbGreen)*2+GetGValue(Color)) div 3;
          Pixel.rgbBlue:=(Integer(Pixel.rgbBlue)*2+GetBValue(Color)) div 3; Inc(Pixel);
        end;
      end;
    end;
  end;
begin
  FPage:=EnsureRange(FPage,0,FPDF.PageCount-1);
  Count:=Min(TextPageCount,FPDF.PageCount-FPage); SetLength(Views,Count);
  TotalWidth:=0; MaximumHeight:=0;
  for var I:=0 to Count-1 do
  begin
    Views[I].Page:=FPage+I; Views[I].Size:=FPDF.PageSize(FPage+I);
    Inc(TotalWidth,Views[I].Size.X); MaximumHeight:=Max(MaximumHeight,Views[I].Size.Y);
  end;
  Gap:=(Count-1)*TextPageGap;
  Scale:=Min((FSurface.ClientWidth-24-Gap)/Max(1,TotalWidth),(FSurface.ClientHeight-24)/Max(1,MaximumHeight))*FZoom/100;
  Scale:=Min(Scale,Sqrt(23000000.0/(Double(TotalWidth)*Max(1,MaximumHeight))));
  Width:=Gap; Height:=0;
  for var I:=0 to Count-1 do
  begin
    Inc(Width,Max(1,Round(Views[I].Size.X*Scale)));
    Height:=Max(Height,Max(1,Round(Views[I].Size.Y*Scale)));
  end;
  Spread:=TBitmap.Create;
  try
    Spread.PixelFormat:=pf32bit; Spread.SetSize(Width,Height);
    Spread.Canvas.Brush.Color:=ThemeBackground; Spread.Canvas.FillRect(Rect(0,0,Width,Height));
    Left:=0; FPDFPageHasText:=False;
    for var I:=0 to Count-1 do
    begin
      Views[I].Bounds:=Rect(Left,0,Left+Max(1,Round(Views[I].Size.X*Scale)),Max(1,Round(Views[I].Size.Y*Scale)));
      OffsetRect(Views[I].Bounds,0,(Height-Views[I].Bounds.Height) div 2);
      Raster:=FPDF.Render(Views[I].Page,Views[I].Bounds.Width,Views[I].Bounds.Height,FNight);
      try
        if FSearchAll.Checked and (FPDFQuery<>'') then
          for var Match in FPDF.FindAllOnPage(Views[I].Page,FPDFQuery,FSearchCase.Checked,FSearchWord.Checked) do Mark(Raster,Views[I].Size,Match.Rects)
        else if FPDFMatchPage=Views[I].Page then Mark(Raster,Views[I].Size,FPDFRects);
        Spread.Canvas.Draw(Views[I].Bounds.Left,Views[I].Bounds.Top,Raster);
      finally Raster.Free; end;
      FPDFPageHasText:=FPDFPageHasText or FPDF.PageHasText(Views[I].Page);
      Left:=Views[I].Bounds.Right+TextPageGap;
    end;
    FBitmap.Free; FBitmap:=Spread; Spread:=nil; FPDFPageViews:=Views;
  finally Spread.Free; end;
  FLoadFinished:=True; FSpreadLoading:=False;
  FPan:=Point(Max(0,(FSurface.ClientWidth-Width) div 2),Max(0,(FSurface.ClientHeight-Height) div 2));
  FFitButton.Visible:=True;
  if FPDFPageHasText and FSelectionEnabled then FSurface.Cursor:=crIBeam else FSurface.Cursor:=crDefault;
  if Count=1 then FStatus.Caption:=Format('%s · Страница %d из %d · Масштаб %d%%',[FPDF.DisplayName,FPage+1,FPDF.PageCount,FZoom])
  else FStatus.Caption:=Format('%s · Страницы %d–%d из %d · Масштаб %d%%',[FPDF.DisplayName,FPage+1,FPage+Count,FPDF.PageCount,FZoom]);
  if FPDFPageHasText and FSelectionEnabled then FStatus.Caption:=FStatus.Caption+' · Выделение мышью · Ctrl+C — копировать'
  else if FInspectionHold then FStatus.Caption:=FStatus.Caption+' · Держите кнопку — приблизить; отпустите — вернуть'
  else FStatus.Caption:=FStatus.Caption+' · Щелчок — приблизить; Esc — вернуть';
end;

procedure TfrmBuiltinReader.RenderPage;
var I, FullHeight, NotesHeight: Integer; Notes: string; NotesRect: TRect;
begin
  FVisibleAnnotations:=nil; FSurface.Hint:=''; FAnnotationClick:=-1;
  FFontOffer.Color:=ThemeBackground; FFontOfferText.Font.Color:=ThemeText;
  if not FReady or FClosing or (Assigned(FPageWorker) and not FPageWorker.Prefetch) or (FSurface.ClientWidth<100) or (FSurface.ClientHeight<100) then Exit;
  if Assigned(FPDF) then
  begin
    FPDF.SetVisibleRange(FPage,Min(TextPageCount,FPDF.PageCount-FPage));
    if FPDF.AsyncPages then
      for I:=FPage to Min(FPDF.PageCount-1,FPage+TextPageCount-1) do
        if not FPDF.IsPageCached(I) then
        begin
          FSpreadLoading:=True;
          if not Assigned(FPageWorker) then
          begin
            FRequestedPage:=FPage;
            FStatus.Caption:=Format('Открытие страницы %d из %d…',[I+1,FPDF.PageCount]);
            FPageWorker:=TReaderPageThread.Create(FPDF,I,DesiredRasterEdge); FPageWorker.Prefetch:=True;
            FPageTimer.Enabled:=True; FPageWorker.Start;
          end;
          Exit;
        end;
    RenderPDFPages;
  end
  else
  begin
    FPageSelection.Clear; if Assigned(FSecondPageSelection) then FSecondPageSelection.Clear; FTextSelecting:=False; FTextSelectionStart:=-1; FTextSelectionEnd:=-1; FTextSelectionRects:=nil;
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
    if TextPageCount=2 then
    begin
      FBitmap.Canvas.Pen.Color:=$00D8D8D8; if FNight then FBitmap.Canvas.Pen.Color:=$00404040;
      FBitmap.Canvas.MoveTo(FBitmap.Width div 2,20);
      FBitmap.Canvas.LineTo(FBitmap.Width div 2,FBitmap.Height-20);
    end;
    FStatus.Caption:=Format('%d%% · Шрифт %d · Колесо — страницы · Ctrl+колесо — размер',[Min(100,Round(ReadingProgress*100)),FFontSize]);
    if TextPageCount=2 then FStatus.Caption:=FStatus.Caption+' · Две страницы';
    if Assigned(FDocument) and (FDocument.SkippedImages>0) then FStatus.Caption:=FStatus.Caption+' · Изображений пропущено: '+IntToStr(FDocument.SkippedImages);
  end;
  if Assigned(FPDF) then I:=ChapterIndexAt(CurrentPosition) else I:=ChapterIndexAt(Max(CurrentPosition,FNext-1));
  FChapters.ItemIndex:=I;
  if I>=0 then FChapters.Hint:=ChapterTitle(I) else FChapters.Hint:='Оглавление (Ctrl+T)';
  UpdateChapterPath; RebuildAnnotationMarkers;
  FPageHasBookmark:=False;
  for var Position in FBookmarkPositions do
    if Assigned(FPDF) then begin if (Position>=FPage) and (Position<FPage+Length(FPDFPageViews)) then FPageHasBookmark:=True; end
    else if (Position>=CurrentPosition) and (Position<FNext) then FPageHasBookmark:=True;
  if FAnnotationLoadError<>'' then FStatus.Caption:=FStatus.Caption+' · Заметки недоступны: '+FAnnotationLoadError;
  FLastPageInteraction:=GetTickCount64;
  if FSearchStatus<>'' then FStatus.Caption:=FSearchStatus;
  FProgressLine.Invalidate; FSurface.Invalidate; PrefetchNextPage;
end;

procedure TfrmBuiltinReader.PaintPageDecoration(Canvas: TCanvas);
var Pages: array[0..1] of TRect; Book, Bounds: TRect;
  Count, Width, Inset, MaximumDepth, Shadow, SavedDC, Middle, Curve, Opacity: Integer;
  LeftDepth, RightDepth: Integer; Progress: Double;
  Blend: TBlendFunction; Reflow: Boolean; Desk, Cover, PaperEdge: TColor;
  function Px(Value: Integer): Integer;
  begin Result:=Max(1,MulDiv(Value,CurrentPPI,96)); end;
  procedure Tint(const Area: TRect; Alpha: Integer; Light: Boolean = False);
  var Clip: TRect;
  begin
    if not IntersectRect(Clip,Area,FSurface.ClientRect) or (Alpha<=0) then Exit;
    if Light then FSelectionTint.Canvas.Brush.Color:=clWhite else FSelectionTint.Canvas.Brush.Color:=clBlack;
    FSelectionTint.Canvas.FillRect(Rect(0,0,1,1));
    Blend.SourceConstantAlpha:=Byte(EnsureRange(Alpha,0,255));
    Winapi.Windows.AlphaBlend(Canvas.Handle,Clip.Left,Clip.Top,Clip.Width,Clip.Height,
      FSelectionTint.Canvas.Handle,0,0,1,1,Blend);
  end;
  procedure LeafBlock(Index, Depth, Direction: Integer);
  var Top, Bottom, Line: array[0..8] of TPoint;
    Shape: array[0..17] of TPoint;
    Face: array[0..3] of TPoint; R: TRect;
    Bend, VerticalDepth, Layers, X, Y, Outside: Integer; Ratio, Sag: Double;
    function Shifted(const P: TPoint; Fraction, Layer: Double; Extra: Integer = 0): TPoint;
    var Horizontal, Vertical: Double;
    begin
      if Count=1 then
      begin
        Horizontal:=-LeftDepth*(1-Fraction)+RightDepth*Fraction;
        Vertical:=(Max(1,Min(Px(10),LeftDepth*2 div 3+1))*(1-Fraction)+
          Max(1,Min(Px(10),RightDepth*2 div 3+1))*Fraction);
        Horizontal:=Horizontal+Extra*(2*Fraction-1);
      end
      else begin Horizontal:=Direction*(Depth+Extra); Vertical:=VerticalDepth; end;
      Result:=Point(P.X+Round(Horizontal*Layer),P.Y+Round((Vertical+Extra)*Layer));
    end;
  begin
    R:=Pages[Index]; Bend:=0;
    if Reflow then Bend:=Px(6);
    VerticalDepth:=Max(1,Min(Px(10),Depth*2 div 3+1));
    for var J:=0 to 8 do
    begin
      Ratio:=J/8;
      // The paper rises away from the binding and falls into its fold.
      // Only the existing blank margins are shaped; content is never warped.
      if Count=2 then
        if Index=0 then Sag:=Sqr(Ratio) else Sag:=Sqr(1-Ratio)
      else Sag:=Sqr(1-Ratio);
      X:=R.Left+Round(R.Width*Ratio);
      Top[J]:=Point(X,R.Top+Round(Bend*Sag));
      Bottom[J]:=Point(X,R.Bottom+Round(Bend*Sag));
    end;
    if Reflow and ((Count=2) or (Direction<0)) then
    begin
      Canvas.Pen.Style:=psClear; Canvas.Brush.Color:=Desk;
      Shape[0]:=Point(R.Left,0); Shape[1]:=Point(R.Right,0);
      for var J:=0 to 8 do Shape[J+2]:=Top[8-J];
      Canvas.Polygon(Slice(Shape,11));
      Shape[0]:=Point(R.Left,FSurface.Height); Shape[1]:=Point(R.Right,FSurface.Height);
      for var J:=0 to 8 do Shape[J+2]:=Bottom[8-J];
      Canvas.Polygon(Slice(Shape,11));
    end;
    // A single-page block is a continuous wedge: it must not be painted
    // twice with two intersecting bottom edges.
    if (Count=2) or (Direction<0) then
    begin
      for var J:=0 to 8 do
      begin
        Shape[J]:=Bottom[J]; Shape[17-J]:=Shifted(Bottom[J],J/8,1,Px(3));
      end;
      Canvas.Pen.Style:=psSolid; Canvas.Pen.Color:=Cover; Canvas.Brush.Color:=Cover;
      Canvas.Polygon(Shape);
      Canvas.Brush.Color:=PaperEdge; Canvas.Pen.Color:=PaperEdge;
      for var J:=0 to 8 do Shape[17-J]:=Shifted(Bottom[J],J/8,1);
      Canvas.Polygon(Shape);
      Layers:=VerticalDepth;
      if Count=1 then Layers:=Max(1,Min(Px(10),Max(LeftDepth,RightDepth)*2 div 3+1));
      for var Layer:=Layers downto 1 do
      begin
        for var J:=0 to 8 do Line[J]:=Shifted(Bottom[J],J/8,Layer/Layers);
        Canvas.Pen.Color:=ReaderBlendColor(PaperEdge,Cover,IfThen(Layer mod 2=0,56,20));
        Canvas.Polyline(Line);
      end;
    end;
    Canvas.Pen.Style:=psSolid; Canvas.Pen.Color:=Cover; Canvas.Brush.Color:=Cover;
    Outside:=R.Left; if Direction>0 then Outside:=R.Right;
    Face[0]:=Point(Outside,R.Top+Px(2)); Face[1]:=Point(Outside,R.Bottom);
    Face[2]:=Point(Outside+Direction*(Depth+Px(2)),R.Bottom+VerticalDepth+Px(3));
    Face[3]:=Point(Outside+Direction*(Depth+Px(2)),R.Top+VerticalDepth+Px(2));
    Canvas.Polygon(Face);
    Canvas.Brush.Color:=PaperEdge; Canvas.Pen.Color:=PaperEdge;
    Face[2]:=Point(Outside+Direction*Depth,R.Bottom+VerticalDepth);
    Face[3]:=Point(Outside+Direction*Depth,R.Top+VerticalDepth+Px(2));
    Canvas.Polygon(Face);
    for var Layer:=1 to Depth do
    begin
      X:=Outside+Direction*Layer; Y:=MulDiv(VerticalDepth,Layer,Max(1,Depth));
      Canvas.Pen.Color:=ReaderBlendColor(PaperEdge,Cover,IfThen(Layer mod 3=0,52,12));
      Canvas.MoveTo(X,R.Top+Y+Px(2)); Canvas.LineTo(X,R.Bottom+Y);
    end;
    Canvas.Pen.Color:=ReaderBlendColor(ThemeBackground,clWhite,IfThen(FNight,13,25));
    Canvas.Polyline(Top);
    Canvas.Pen.Color:=ReaderBlendColor(ThemeBackground,Cover,40); Canvas.Polyline(Bottom);
  end;
begin
  if (FPageAppearance<>rpaBook) or FBitmap.Empty then Exit;
  // Paint after the finished raster. Text selection, images, pagination and
  // cached source pixels keep their original coordinates in both appearances.
  Blend.BlendOp:=AC_SRC_OVER; Blend.BlendFlags:=0; Blend.AlphaFormat:=0;
  Reflow:=not Assigned(FPDF); Shadow:=Px(5); Width:=TextPageWidth;
  if Reflow then Count:=TextPageCount else Count:=Min(2,Length(FPDFPageViews));
  if Count=0 then Exit;
  Inset:=Max(Px(3),Min(Px(22),MulDiv(FMargin,CurrentPPI,96)-Px(6)));
  MaximumDepth:=Min(Px(16),Max(Px(2),Inset-Shadow));
  Progress:=EnsureRange(ReadingProgress,0.0,1.0);
  LeftDepth:=Max(Px(1),Round(MaximumDepth*Progress));
  RightDepth:=Max(Px(1),MaximumDepth-LeftDepth);
  Middle:=(FSurface.Width-1) div 2;
  for var I:=0 to Count-1 do
    if Reflow then
    begin
      Pages[I]:=Rect(I*(Width+TextPageGap),Px(5),I*(Width+TextPageGap)+Width,FBitmap.Height-Px(18));
      if I=0 then Inc(Pages[I].Left,Inset);
      if I=Count-1 then Dec(Pages[I].Right,Inset);
      if Count=2 then
        if I=0 then Pages[I].Right:=Middle else Pages[I].Left:=Middle;
    end
    else
    begin Pages[I]:=FPDFPageViews[I].Bounds; OffsetRect(Pages[I],FPan.X,FPan.Y); end;
  Book:=Pages[0]; if Count=2 then UnionRect(Book,Book,Pages[1]);
  Desk:=ReaderBlendColor(ThemeBackground,clBlack,IfThen(FNight,82,100));
  Cover:=ReaderBlendColor(ThemeBackground,RGB(38,33,27),IfThen(FNight,70,180));
  PaperEdge:=ReaderBlendColor(ThemeBackground,ThemeText,IfThen(FNight,32,46));
  SavedDC:=SaveDC(Canvas.Handle);
  try
    IntersectClipRect(Canvas.Handle,0,0,FSurface.Width,FSurface.Height);
    if Reflow then
    begin
      Canvas.Brush.Color:=Desk;
      Canvas.FillRect(Rect(0,0,FSurface.Width,Book.Top));
      Canvas.FillRect(Rect(0,Book.Bottom+Px(6),FSurface.Width,FSurface.Height));
      Canvas.FillRect(Rect(0,Book.Top,Book.Left,FSurface.Height));
      Canvas.FillRect(Rect(Book.Right,Book.Top,FSurface.Width,FSurface.Height));
    end;
    for var N:=Shadow downto 1 do
    begin
      Tint(Rect(Book.Left-LeftDepth+N,Book.Bottom+Px(10)+N-1,
        Book.Right+RightDepth+N,Book.Bottom+Px(10)+N),(Shadow-N+1)*6);
      Tint(Rect(Book.Right+RightDepth+N-1,Book.Top+Px(8),
        Book.Right+RightDepth+N,Book.Bottom+Px(12)),(Shadow-N+1)*5);
    end;
    LeafBlock(0,LeftDepth,-1);
    if Count=2 then LeafBlock(1,RightDepth,1)
    else LeafBlock(0,RightDepth,1);
    Curve:=Max(Px(12),Min(Px(48),TextPageGap div 2+MulDiv(Max(4,FMargin-8),CurrentPPI,96)));
    if Count=2 then
    begin
      Middle:=(Pages[0].Right+Pages[1].Left) div 2;
      if not Reflow then
      begin
        Canvas.Brush.Color:=Cover;
        Canvas.FillRect(Rect(Pages[0].Right,Book.Top+Px(3),Pages[1].Left,Book.Bottom+Px(8)));
      end;
      for var N:=0 to Curve-1 do
      begin
        Opacity:=Round(145*Sqr(1-N/Curve));
        Tint(Rect(Middle-N-1,Book.Top+Px(6),Middle-N,Book.Bottom+Px(6)),Opacity);
        Tint(Rect(Middle+N,Book.Top+Px(6),Middle+N+1,Book.Bottom+Px(6)),Opacity);
      end;
      Tint(Rect(Middle-1,Book.Top+Px(6),Middle+1,Book.Bottom+Px(8)),95);
    end
    else
    begin
      // A visible binding remains in one-page mode as well.
      for var N:=0 to Curve-1 do
        Tint(Rect(Book.Left+N,Book.Top+Px(6),Book.Left+N+1,Book.Bottom),
          Round(100*Sqr(1-N/Curve)));
    end;
    for var Side:=0 to 1 do
    begin
      if Side=0 then Bounds:=Pages[0] else Bounds:=Pages[Count-1];
      for var N:=0 to Px(16)-1 do
      begin
        Opacity:=Round(22*Sqr(1-N/Px(16)));
        if Side=0 then Tint(Rect(Bounds.Left+N,Bounds.Top+Px(5),Bounds.Left+N+1,Bounds.Bottom),Opacity)
        else Tint(Rect(Bounds.Right-N-1,Bounds.Top+Px(5),Bounds.Right-N,Bounds.Bottom),Opacity);
      end;
    end;
  finally RestoreDC(Canvas.Handle,SavedDC); end;
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
        Canvas.Draw(FPan.X,FPan.Y,FBitmap); PaintPageDecoration(Canvas); PaintAnnotations(Canvas);
        if Length(FPDFSelectionRects)>0 then
        begin
          Boxes:=TList<TRect>.Create;
          try
            Boxes.AddRange(PDFViewRectangles(FPDFSelectionPage,FPDFSelectionRects));
            var ScreenBoxes:=Boxes.ToArray;
            for var J:=0 to High(ScreenBoxes) do OffsetRect(ScreenBoxes[J],FPan.X,FPan.Y);
            PaintSelection(Canvas,ScreenBoxes);
          finally Boxes.Free; end;
        end;
      end else begin Canvas.Draw(0,0,FBitmap); PaintPageDecoration(Canvas); PaintAnnotations(Canvas); PaintSelection(Canvas,FTextSelectionRects); end;
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
    else if Range.Kind in [rbFootnote,rbLink] then
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
       (FImageHeight<>IllustrationHeight)) then LoadPresentation;
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
    if FRequestedPage+PageTurnStep<FPDF.PageCount then RequestPage(FRequestedPage+PageTurnStep);
    Exit;
  end;
  ResetInspection;
  if Assigned(FPDF) then begin if FPage+PageTurnStep>=FPDF.PageCount then Exit; Inc(FPage,PageTurnStep); end
  else
  begin
    // Returning from a fitted previous page must honor its already visited
    // successor, even when the final short tail also fits on this page.
    if FPage+1<FPages.Count then Inc(FPage)
    else
    begin
      if (NextTextPosition<=CurrentPosition) or (NextTextPosition>=FLength) then Exit;
      var NextPosition:=NextTextPosition; Inc(FPage); FPages.Add(NextPosition);
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
    RequestPage(FRequestedPage-PageTurnStep);
    Exit;
  end;
  ResetInspection;
  if Assigned(FPDF) then begin if FPage<=0 then Exit; FPage:=Max(0,FPage-PageTurnStep); end
  else if FPage>0 then Dec(FPage)
  else
  begin
    Target:=CurrentPosition; if Target=0 then Exit;
    L:=Max(0,Target-100000); H:=Target;
    while L<H do
    begin M:=L+(H-L) div 2; if MeasurePreviousText(M,Target)>=Target then H:=M else L:=M+1; end;
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
var Content: TRect; DPI, Width, Margin, PageWidth, FirstEnd: Integer;
begin
  if not FReady or Assigned(FPDF) or (FNext<=CurrentPosition) then Exit;
  if not FPageSelection.Ready then
  begin
    DPI:=GetDeviceCaps(FBitmap.Canvas.Handle,LOGPIXELSX); Margin:=MulDiv(FMargin,DPI,96);
    PageWidth:=TextPageWidth; Width:=Min(PageWidth-2*Margin,TextAreaWidth);
    Content:=Rect((PageWidth-Width) div 2,MulDiv(20,DPI,96),
      (PageWidth+Width) div 2,FBitmap.Height-MulDiv(20,DPI,96));
    FirstEnd:=FNext;
    if Length(FSpreadBreaks)>2 then FirstEnd:=FSpreadBreaks[1];
    FPageSelection.Prepare(FRichEdit,CurrentPosition,FirstEnd-CurrentPosition,PageWidth,FBitmap.Height,DPI,Content);
    if (Length(FSpreadBreaks)>2) and (FNext>FirstEnd) then
    begin
      if not Assigned(FSecondPageSelection) then FSecondPageSelection:=TReaderPageSelection.Create(Self,FFormattingHost);
      FSecondPageSelection.Prepare(FRichEdit,FirstEnd,FNext-FirstEnd,PageWidth,FBitmap.Height,DPI,Content,PageWidth+TextPageGap);
    end;
  end;
end;

function TfrmBuiltinReader.TextSelectionRectangles(Start, Finish: Integer): TArray<TRect>;
var Boxes: TList<TRect>;
begin
  Boxes:=TList<TRect>.Create;
  try
    Boxes.AddRange(FPageSelection.Rectangles(Start,Finish));
    if Assigned(FSecondPageSelection) and FSecondPageSelection.Ready then
      Boxes.AddRange(FSecondPageSelection.Rectangles(Start,Finish));
    Result:=Boxes.ToArray;
  finally Boxes.Free; end;
end;

function TfrmBuiltinReader.TextCharacterAt(X,Y: Integer): Integer;
begin
  Result:=-1; if not FReady or Assigned(FPDF) or (FNext<=CurrentPosition) then Exit;
  PreparePageSelection;
  if (TextPageCount=2) and (X>=TextPageWidth+TextPageGap div 2) then
  begin
    if Assigned(FSecondPageSelection) then Result:=FSecondPageSelection.CharacterAt(X,Y);
  end
  else Result:=FPageSelection.CharacterAt(X,Y);
end;

function TfrmBuiltinReader.TextLinkTargetAt(X,Y: Integer): Integer;
var Index, Candidate, Target: Integer;
begin
  Result:=-1;
  if not FReady or not Assigned(FDocument) or Assigned(FPDF) or FInspect then Exit;
  if not FDocument.HasLinks then Exit;
  Index:=TextCharacterAt(X,Y);
  if Index<0 then Exit;
  // RichEdit returns the nearest character even in a margin or a blank line.
  // Its nearest insertion position may be after the glyph under the pointer.
  // Check both sides, but require the point to be on actual painted link text.
  for var Offset in [0,1] do
  begin
    if Index<Offset then Continue;
    Candidate:=ReaderCharacterStart(FRichEdit,Index-Offset);
    if not FDocument.LinkTargetAt(Candidate,Target) then Continue;
    for var Box in TextSelectionRectangles(Candidate,Candidate+1) do
      if PtInRect(Box,Point(X,Y)) then Exit(Target);
  end;
end;

procedure TfrmBuiltinReader.SelectWordAt(X,Y: Integer);
var Index, Candidate, Next, Start, Count: Integer;
begin
  if not FReady or not FSelectionEnabled then Exit;
  if Assigned(FPDF) then
  begin
    FPDFSelectionAnchor:=-1; FPDFSelectionEnd:=-1; FPDFSelectionRects:=nil;
    Index:=PDFCharacterAt(X,Y);
    if (Index>=0) and FPDF.TextWordRange(FPDFSelectionPage,Index,Start,Count) then
    begin FPDFSelectionAnchor:=Start; SelectPDFCharacter(Start+Count-1); end;
    FSurface.Invalidate; Exit;
  end;
  FTextSelectionStart:=-1; FTextSelectionEnd:=-1; FTextSelectionRects:=nil;
  Index:=TextCharacterAt(X,Y); if Index<0 then begin FSurface.Invalidate; Exit; end;
  // Hit testing returns a nearest caret even in a margin. Only select when
  // the pointer is on painted text, checking both sides of that caret.
  for var Offset in [0,1] do
  begin
    if Index<Offset then Continue;
    Candidate:=ReaderCharacterStart(FRichEdit,Index-Offset); if Candidate>=FNext then Continue;
    Next:=ReaderCharacterStart(FRichEdit,Candidate+1); if Next<=Candidate then Next:=Candidate+2;
    for var Box in TextSelectionRectangles(Candidate,Next) do
      if PtInRect(Box,Point(X,Y)) then
      begin
        if ReaderWordRange(FRichEdit,Candidate,Start,Count) then
          SelectText(Max(CurrentPosition,Start),Min(FNext,Start+Count)-Max(CurrentPosition,Start));
        FSurface.Invalidate; Exit;
      end;
  end;
  FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.UpdateTextSelection(X,Y: Integer);
var Index: Integer;
begin
  Index:=TextCharacterAt(X,Y); if (Index<0) or (FTextSelectionStart<0) then Exit;
  FTextSelectionEnd:=Index; FTextSelectionRects:=TextSelectionRectangles(FTextSelectionStart,FTextSelectionEnd);
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
var Point: TPoint;
begin
  Result:=-1;
  if not FPDFPageHasText or PageLoading or not Assigned(FPDF) then Exit;
  Point:=System.Types.Point(X-FPan.X,Y-FPan.Y);
  for var View in FPDFPageViews do
    if PtInRect(View.Bounds,Point) then
    begin
      if FPDFSelecting and (FPDFSelectionAnchor>=0) and (FPDFSelectionPage<>View.Page) then Exit;
      FPDFSelectionPage:=View.Page;
      Result:=FPDF.TextCharacterAt(View.Page,(Point.X-View.Bounds.Left)*View.Size.X/View.Bounds.Width,
        View.Size.Y-(Point.Y-View.Bounds.Top)*View.Size.Y/View.Bounds.Height,
        4*View.Size.X/View.Bounds.Width,4*View.Size.Y/View.Bounds.Height);
      Exit;
    end;
end;

procedure TfrmBuiltinReader.SelectPDFCharacter(Index: Integer);
var Start,Count: Integer;
begin
  if (Index<0) or (FPDFSelectionAnchor<0) then Exit;
  FPDFSelectionEnd:=Index; Start:=Min(Index,FPDFSelectionAnchor); Count:=Abs(Index-FPDFSelectionAnchor)+1;
  FPDFSelectionRects:=FPDF.TextRectangles(FPDFSelectionPage,Start,Count); FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.SelectText(Start, Count: Integer);
begin
  if Assigned(FPDF) then begin SelectPDFText(Start,Count); Exit; end;
  if not FReady or not FSelectionEnabled then Exit;
  FTextSelectionStart:=EnsureRange(Start,CurrentPosition,FNext);
  FTextSelectionEnd:=Min(FNext,FTextSelectionStart+Min(Max(0,Count),FNext-FTextSelectionStart));
  PreparePageSelection; FTextSelectionRects:=TextSelectionRectangles(FTextSelectionStart,FTextSelectionEnd);
  FSurface.Invalidate;
end;

procedure TfrmBuiltinReader.SelectPDFText(Start, Count: Integer);
begin
  if not FPDFPageHasText or (Start<0) or (Count<=0) then Exit;
  FPDFSelectionPage:=FPage; FPDFSelectionAnchor:=Start; SelectPDFCharacter(Start+Count-1);
end;

function TfrmBuiltinReader.PDFSelectedText: string;
begin
  Result:='';
  if not FPDFPageHasText or (FPDFSelectionAnchor<0) or (FPDFSelectionEnd<0) then Exit;
  Result:=FPDF.TextRange(FPDFSelectionPage,Min(FPDFSelectionAnchor,FPDFSelectionEnd),Abs(FPDFSelectionAnchor-FPDFSelectionEnd)+1);
end;

function TfrmBuiltinReader.PageText: string;
begin
  Result:=''; if not FReady then Exit;
  if Assigned(FPDF) then
  begin
    if FPDFPageHasText and not PageLoading then
      for var View in FPDFPageViews do
      begin
        if Result<>'' then Result:=Result+#13#10+#13#10;
        Result:=Result+FPDF.TextRange(View.Page,0,MaxInt);
      end;
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
  FDictionaryItem.Enabled:=ReaderLookupText(SelectedText)<>'';
  FWebLookupItem.Enabled:=FDictionaryItem.Enabled;
  FGoogleItem.Enabled:=FWebLookupItem.Enabled; FYandexItem.Enabled:=FWebLookupItem.Enabled;
  FDictionaryItem.Hint:='Выделите слово или короткую фразу — до 512 знаков.';
  FWebLookupItem.Hint:=FDictionaryItem.Hint;
  FCopyPageItem.Enabled:=PageText<>'';
  FCopyAllItem.Visible:=not Assigned(FPDF); FCopyAllItem.Enabled:=FReady and (FLength>0);
  FCopyViewItem.Enabled:=FCopyPageItem.Enabled;
end;

function TfrmBuiltinReader.OpenLookupTarget(const Target, Parameters, WorkingDirectory: string): Boolean;
begin
  Result:=NativeInt(ShellExecute(Handle,'open',PChar(Target),PChar(Parameters),PChar(WorkingDirectory),SW_SHOWNORMAL))>32;
  if not Result then FStatus.Caption:='Не удалось открыть программу или браузер. Проверьте настройки.';
end;

function TfrmBuiltinReader.ChooseDictionaryExecutable: Boolean;
var Dialog: TFileOpenDialog;
begin
  Result:=False; Dialog:=TFileOpenDialog.Create(Self);
  try
    Dialog.Title:='Выберите программу GoldenDict или GoldenDict-ng';
    Dialog.Options:=Dialog.Options+[fdoFileMustExist,fdoPathMustExist];
    with Dialog.FileTypes.Add do begin DisplayName:='Программа словаря'; FileMask:='*.exe'; end;
    Dialog.FileName:=FDictionaryExecutable;
    if not Dialog.Execute(Handle) then Exit;
    if not FileExists(Dialog.FileName) then Exit;
    FDictionaryExecutable:=TPath.GetFullPath(Dialog.FileName); SaveSettings; Result:=True;
  finally Dialog.Free; end;
end;

procedure TfrmBuiltinReader.ConfigureDictionaryClick(Sender: TObject);
begin
  if ChooseDictionaryExecutable then FStatus.Caption:='Словарь выбран: '+ExtractFileName(FDictionaryExecutable);
end;

procedure TfrmBuiltinReader.DictionaryLookupClick(Sender: TObject);
var App, URL: string;
begin
  URL:=ReaderLookupURL(SelectedText,rltDictionary); if URL='' then Exit;
  App:=FindReaderDictionary(FDictionaryExecutable);
  if App='' then
  begin
    if not ChooseDictionaryExecutable then Exit;
    App:=FDictionaryExecutable;
  end;
  OpenLookupTarget(App,QuoteCommandLineArgument(URL),ExtractFileDir(App));
end;

procedure TfrmBuiltinReader.WebLookupClick(Sender: TObject);
var URL: string;
begin
  if (Sender<>FGoogleItem) and (Sender<>FYandexItem) then Exit;
  URL:=ReaderLookupURL(SelectedText,TReaderLookupTarget(TMenuItem(Sender).Tag));
  if URL<>'' then OpenLookupTarget(URL,'','');
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
    NoteButton:=TReaderPaletteButton.Create(Dialog); NoteButton.Parent:=Footer; NoteButton.Align:=alLeft; NoteButton.Width:=250;
    NoteButton.Caption:='Заметка с выделенной цитатой…'; NoteButton.OnClick:=QuoteNoteClick;
    CloseButton:=TReaderPaletteButton.Create(Dialog); CloseButton.Parent:=Footer; CloseButton.Align:=alRight; CloseButton.Width:=120;
    CloseButton.Height:=32; CloseButton.Caption:='Закрыть'; CloseButton.ModalResult:=mrOk; CloseButton.Cancel:=True;
    Dialog.ActiveControl:=Memo; ApplyWindowPalette(Dialog);
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
begin Result:=ReaderThemeBackground(FTheme); end;

function TfrmBuiltinReader.ThemeText: TColor;
begin Result:=ReaderThemeText(FTheme); end;

procedure TfrmBuiltinReader.SetTheme(Index: Integer);
begin
  Index:=EnsureRange(Index,0,5);
  if Index=FTheme then begin RefreshWindowTheme; Exit; end;
  FTheme:=Index; FThemes.ItemIndex:=Index; FNight:=Index>=4;
  RefreshWindowTheme; FTypographyDirty:=True; InvalidateLayout;
end;

procedure TfrmBuiltinReader.RefreshWindowTheme;
begin
  ApplyWindowPalette(Self);
end;

procedure TfrmBuiltinReader.ApplyWindowPalette(Form: TCustomForm);
begin
  ApplyReaderPalette(Form,ThemeBackground,ThemeText,FNight);
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
type
  TReaderNoteEditor = class(TForm)
  private
    FStore: TReaderAnnotations;
    FNote, FOriginal: TReaderAnnotation;
    FTitle: TEdit;
    FText, FLatest, FQuote: TMemo;
    FRecovery: TPanel;
    FMessage, FDraftLabel: TLabel;
    FSave, FReload, FCopy: TButton;
    FCopyAfterConflict, FSaved, FLayoutUpdating: Boolean;
    function Draft: TReaderAnnotation;
    procedure ShowRecovery(const Text: string);
    procedure UpdateDraftLayout;
    procedure SaveClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure ReloadClick(Sender: TObject);
    procedure ConfirmClose(Sender: TObject; var CanClose: Boolean);
  protected
    procedure Resize; override;
    procedure ChangeScale(M,D: Integer; IsDpiChange: Boolean); override;
  public
    procedure ScaleForPPI(NewPPI: Integer); override;
    constructor CreateFor(Reader: TCustomForm; Store: TReaderAnnotations; const Note: TReaderAnnotation);
  end;

constructor TReaderNoteEditor.CreateFor(Reader: TCustomForm; Store: TReaderAnnotations; const Note: TReaderAnnotation);
var Header, Footer, Body: TPanel; Button: TButton; LabelText: TLabel;
begin
  inherited CreateNew(Reader); FStore:=Store; FNote:=Note; FOriginal:=Note; Name:='ReaderNoteEditor';
  OnCloseQuery:=ConfirmClose;
  Caption:='Заметка к книге'; Position:=poOwnerFormCenter; BorderStyle:=bsSizeable; PopupMode:=pmExplicit;
  if Assigned(Screen.ActiveCustomForm) then PopupParent:=Screen.ActiveCustomForm else PopupParent:=Reader;
  ClientWidth:=650; ClientHeight:=520; Constraints.MinWidth:=470; Constraints.MinHeight:=430;
  Font.Name:='Segoe UI'; Font.Size:=10;
  Header:=TPanel.Create(Self); Header.Parent:=Self; Header.Align:=alTop; Header.Height:=108; Header.BevelOuter:=bvNone;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Header; LabelText.AutoSize:=False; LabelText.SetBounds(12,8,626,36);
  LabelText.WordWrap:=True; LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.Caption:=Note.BookTitle+' · '+Note.Place;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Header; LabelText.Caption:='Название (необязательно)'; LabelText.SetBounds(12,48,626,20);
  FTitle:=TEdit.Create(Self); FTitle.Name:='NoteEditorTitle'; FTitle.Parent:=Header; FTitle.SetBounds(12,72,626,26);
  FTitle.Anchors:=[akLeft,akTop,akRight]; FTitle.TextHint:='Название заметки'; FTitle.MaxLength:=256; FTitle.Text:=Note.Title;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom; Footer.Height:=48; Footer.BevelOuter:=bvNone;
  FSave:=TReaderPaletteButton.Create(Self); FSave.Name:='NoteEditorSave'; FSave.Parent:=Footer; FSave.SetBounds(280,8,240,30);
  FSave.Anchors:=[akRight,akBottom]; FSave.Caption:='Сохранить'; FSave.OnClick:=SaveClick; FSave.Default:=True;
  Button:=TReaderPaletteButton.Create(Self); Button.Name:='NoteEditorCancel'; Button.Parent:=Footer; Button.SetBounds(528,8,110,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Отмена'; Button.ModalResult:=mrCancel; Button.Cancel:=True;
  Body:=TPanel.Create(Self); Body.Parent:=Self; Body.Align:=alClient; Body.BevelOuter:=bvNone;
  FRecovery:=TPanel.Create(Self); FRecovery.Name:='NoteConflictActions'; FRecovery.Caption:=''; FRecovery.Parent:=Body;
  FRecovery.Align:=alTop; FRecovery.Height:=114; FRecovery.BevelOuter:=bvNone; FRecovery.Visible:=False;
  FMessage:=TLabel.Create(Self); FMessage.Name:='NoteConflictMessage'; FMessage.Parent:=FRecovery;
  FMessage.SetBounds(12,8,626,68); FMessage.AutoSize:=False; FMessage.WordWrap:=True;
  FMessage.Caption:=''; FMessage.ShowAccelChar:=False; FMessage.ShowHint:=True; FMessage.Anchors:=[akLeft,akTop];
  FCopy:=TReaderPaletteButton.Create(Self); FCopy.Name:='NoteDraftCopy'; FCopy.Parent:=FRecovery;
  FCopy.SetBounds(12,76,238,30); FCopy.Caption:='Сохранить копию текста…'; FCopy.OnClick:=CopyClick;
  FReload:=TReaderPaletteButton.Create(Self); FReload.Name:='NoteReload'; FReload.Parent:=FRecovery;
  FReload.SetBounds(258,76,182,30); FReload.Caption:='Перечитать записи'; FReload.OnClick:=ReloadClick;
  FDraftLabel:=TLabel.Create(Self); FDraftLabel.Name:='NoteDraftLabel'; FDraftLabel.Parent:=Body;
  FDraftLabel.AutoSize:=False; FDraftLabel.Align:=alTop; FDraftLabel.AlignWithMargins:=True;
  FDraftLabel.Margins.SetBounds(12,4,12,4); FDraftLabel.ShowAccelChar:=False;
  FDraftLabel.Height:=24; FDraftLabel.Caption:='Ваши мысли — черновик остаётся здесь';
  FLatest:=TMemo.Create(Self); FLatest.Name:='NoteLatest'; FLatest.Parent:=Body; FLatest.Align:=alBottom;
  FLatest.Height:=120; FLatest.ReadOnly:=True; FLatest.ScrollBars:=ssVertical; FLatest.Visible:=False;
  FQuote:=TMemo.Create(Self); FQuote.Parent:=Body; FQuote.Align:=alBottom; FQuote.Height:=80;
  FQuote.Text:='Цитата: '+Note.Quote; FQuote.ReadOnly:=True; FQuote.ScrollBars:=ssVertical; FQuote.Visible:=Note.Quote<>'';
  FText:=TMemo.Create(Self); FText.Name:='NoteEditorText'; FText.Parent:=Body; FText.Align:=alClient; FText.ScrollBars:=ssVertical;
  FText.TextHint:='Ваши мысли об этом месте книги…'; FText.MaxLength:=16384; FText.Text:=Note.Text;
  ApplyMHLControlTheme(Self);
  if Reader is TfrmBuiltinReader then TfrmBuiltinReader(Reader).ApplyWindowPalette(Self);
  UpdateDraftLayout; ActiveControl:=FText;
end;

function TReaderNoteEditor.Draft: TReaderAnnotation;
begin Result:=FNote; Result.Title:=Trim(FTitle.Text); Result.Text:=FText.Text; end;

procedure TReaderNoteEditor.UpdateDraftLayout;
var Available, TextWidth, MessageHeight, ButtonHeight, ButtonTop: Integer; Bounds: TRect; Body: TWinControl;
  function S(Value: Integer): Integer;
  begin
    // The fixed-height draft label follows actual VCL scaling, including
    // explicit ScaleForPPI while CurrentPPI still describes the monitor.
    Result:=MulDiv(Value,FDraftLabel.Height,24);
  end;
begin
  if (csDestroying in ComponentState) or FLayoutUpdating then Exit;
  if not Assigned(FText) or not Assigned(FLatest) or not Assigned(FDraftLabel) then Exit;
  if not Assigned(FText.Parent) then Exit;
  FLayoutUpdating:=True; Body:=FText.Parent; Body.DisableAlign; FRecovery.DisableAlign;
  try
    FDraftLabel.Margins.SetBounds(S(12),S(4),S(12),S(4));
    if FRecovery.Visible then
    begin
      // Hidden panels can have a different anchor base. Derive every width
      // from the current client area rather than stretching an old label.
      FRecovery.Width:=Body.ClientWidth; FRecovery.Top:=0;
      TextWidth:=Max(S(80),FRecovery.ClientWidth-2*S(12));
      Canvas.Font.Assign(FMessage.Font); Bounds:=Rect(0,0,TextWidth,0);
      DrawText(Canvas.Handle,PChar(FMessage.Caption),Length(FMessage.Caption),Bounds,
        DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      MessageHeight:=Max(Canvas.TextHeight('Mg'),Bounds.Height);
      FMessage.SetBounds(S(12),S(8),TextWidth,MessageHeight); FMessage.Hint:=FMessage.Caption;
      ButtonHeight:=Max(S(30),Canvas.TextHeight('Mg')+S(12));
      ButtonTop:=FMessage.Top+FMessage.Height+S(8);
      FCopy.SetBounds(S(12),ButtonTop,S(238),ButtonHeight);
      FReload.SetBounds(FCopy.Left+FCopy.Width+S(8),ButtonTop,S(182),ButtonHeight);
      if FReload.Left+FReload.Width>FRecovery.ClientWidth-S(12) then
        FReload.SetBounds(S(12),ButtonTop+ButtonHeight+S(8),S(182),ButtonHeight);
      FRecovery.Height:=FReload.Top+FReload.Height+S(8);
    end;
    if FRecovery.Visible then FDraftLabel.Top:=FRecovery.Height+FDraftLabel.Margins.Top;
    if FLatest.Visible then
    begin
      Available:=Body.ClientHeight-FDraftLabel.Height-FDraftLabel.Margins.Top-FDraftLabel.Margins.Bottom;
      if FRecovery.Visible then Dec(Available,FRecovery.Height);
      if FQuote.Visible then Dec(Available,FQuote.Height);
      // Saved text can scroll; keep the live draft editable at minimum size.
      FLatest.Height:=Max(S(24),Min(S(120),Available-S(64)));
    end;
  finally
    FRecovery.EnableAlign; Body.EnableAlign; FLayoutUpdating:=False;
  end;
end;

procedure TReaderNoteEditor.Resize;
begin inherited; UpdateDraftLayout; end;

procedure TReaderNoteEditor.ChangeScale(M,D: Integer; IsDpiChange: Boolean);
begin inherited; UpdateDraftLayout; end;

procedure TReaderNoteEditor.ScaleForPPI(NewPPI: Integer);
begin inherited; UpdateDraftLayout; end;

procedure TReaderNoteEditor.ShowRecovery(const Text: string);
var Work: TRect;
begin
  FMessage.Caption:=Text; FRecovery.Visible:=True;
  // The quote remains in FNote and its text copy. Give the live draft and
  // read-only saved revision room on short/high-DPI monitors.
  FQuote.Visible:=False; Work:=Monitor.WorkareaRect;
  Height:=Min(Max(Height,MulDiv(720,FDraftLabel.Height,24)),Work.Height-20);
  SetBounds(EnsureRange(Left,Work.Left,Max(Work.Left,Work.Right-Width)),
    EnsureRange(Top,Work.Top,Max(Work.Top,Work.Bottom-Height)),Width,Height);
  UpdateDraftLayout;
end;

procedure TReaderNoteEditor.SaveClick(Sender: TObject);
begin
  FNote:=Draft;
  try
    FNote.ID:=FStore.Put(FNote); FSaved:=True; ModalResult:=mrOk;
  except
    on E: EReaderAnnotationConflict do
    begin FSave.Enabled:=False; ShowRecovery(E.Message+sLineBreak+'Черновик не закрыт. Перечитайте записи перед следующим сохранением.'); end;
    on E: Exception do ShowRecovery('Не удалось сохранить. Черновик остаётся в полях.'+sLineBreak+E.Message);
  end;
end;

procedure TReaderNoteEditor.ConfirmClose(Sender: TObject; var CanClose: Boolean);
begin
  if (ModalResult=mrOk) and not FSaved then
  begin SaveClick(nil); CanClose:=FSaved; if not CanClose then ModalResult:=mrNone; end;
end;

procedure TReaderNoteEditor.CopyClick(Sender: TObject);
var Dialog: TFileSaveDialog;
begin
  Dialog:=TFileSaveDialog.Create(Self);
  try
    Dialog.Title:='Сохранить копию черновика заметки'; Dialog.DefaultExtension:='txt';
    with Dialog.FileTypes.Add do begin DisplayName:='Текст UTF-8 (*.txt)'; FileMask:='*.txt'; end;
    Dialog.FileName:='Черновик заметки.txt'; Dialog.Options:=Dialog.Options+[fdoOverWritePrompt,fdoPathMustExist,fdoStrictFileTypes];
    if Dialog.Execute(Handle) then
      try
        SaveReaderAnnotationDraft(Draft,Dialog.FileName);
        ShowRecovery('Копия черновика сохранена: '+Dialog.FileName);
      except on E: Exception do ShowRecovery('Копия не сохранена. Черновик остаётся в полях.'+sLineBreak+E.Message); end;
  finally Dialog.Free; end;
end;

procedure TReaderNoteEditor.ReloadClick(Sender: TObject);
var Current, SavedDraft: TReaderAnnotation; Exists: Boolean;
begin
  SavedDraft:=Draft; Current:=Default(TReaderAnnotation);
  try
    FStore.Reload; Exists:=(FOriginal.ID<>'') and FStore.Find(FOriginal.ID,Current);
    if FOriginal.ID<>'' then
    begin
      FLatest.Visible:=True;
      if Exists then FLatest.Text:='Сохранённая версия (только чтение):'+sLineBreak+ReaderAnnotationsText(TArray<TReaderAnnotation>.Create(Current),False)
      else FLatest.Text:='Прежняя заметка удалена в другом окне. Ваш черновик остаётся выше.';
      FCopyAfterConflict:=FCopyAfterConflict or not Exists or not ReaderAnnotationsEqual(Current,FOriginal);
    end;
    FNote:=SavedDraft;
    if FCopyAfterConflict then
    begin
      FNote.ID:=''; FNote.Created:=''; FSave.Caption:='Сохранить новой заметкой';
      ShowRecovery('Записи перечитаны. Черновик остаётся выше, сохранённая версия — ниже. Кнопка «Сохранить новой заметкой» создаст отдельную запись; прежняя не изменится.');
    end
    else ShowRecovery('Записи перечитаны. Эта заметка не менялась в другом окне; ваш черновик можно сохранить.');
    FSave.Enabled:=True;
  except on E: Exception do ShowRecovery('Не удалось перечитать записи. Черновик и прежний список сохранены.'+sLineBreak+E.Message); end;
end;

function EditAndSaveReaderNote(Owner: TCustomForm; Store: TReaderAnnotations; var Note: TReaderAnnotation): Boolean;
var Dialog: TReaderNoteEditor;
begin
  Dialog:=TReaderNoteEditor.CreateFor(Owner,Store,Note);
  try Result:=(Dialog.ShowModal=mrOk) and Dialog.FSaved; if Result then Note:=Dialog.FNote;
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

function ReaderBookmarkMatches(Ini: TMemIniFile; const Note: TReaderAnnotation;
  ExpectedCount: Integer = -1): Boolean;
var Section: string; Count, Index: Integer;
begin
  Result:=False; Section:='Bookmarks.'+Note.BookID;
  Count:=EnsureRange(Ini.ReadInteger(Section,'Count',0),0,100);
  if (ExpectedCount>=0) and (Count<>ExpectedCount) then Exit;
  if not TryStrToInt(Note.ID,Index) then Exit;
  if (Index<0) or (Index>=Count) then Exit;
  Result:=(Ini.ReadInteger(Section,'Position'+Note.ID,-1)=Note.Position) and
    (Ini.ReadString(Section,'Title'+Note.ID,'Закладка '+IntToStr(Index+1)).Replace('&&','&')=Note.Title) and
    (Ini.ReadString(Section,'Created'+Note.ID,'')=Note.Created);
end;

function ReaderBookmarkRemoval(const SettingsFile: string;
  const Notes: TArray<TReaderAnnotation>): TMemIniFile;
var Selected, Books: TDictionary<string,Boolean>; Section, Key: string; Count, Index, Kept: Integer;
begin
  Result:=nil; if Length(Notes)=0 then Exit;
  Selected:=TDictionary<string,Boolean>.Create; Books:=TDictionary<string,Boolean>.Create;
  try
    Result:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8); Result.AutoSave:=False;
    try
      for var Note in Notes do
      begin
        if not ReaderBookmarkMatches(Result,Note) then
          raise EReaderAnnotationConflict.Create('Закладки изменились в другом окне. Перечитайте список перед удалением.');
        Selected.TryAdd(Note.BookID+#9+Note.ID,True); Books.TryAdd(Note.BookID,True);
      end;
      for var BookID in Books.Keys do
      begin
        Section:='Bookmarks.'+BookID; Count:=EnsureRange(Result.ReadInteger(Section,'Count',0),0,100); Kept:=0;
        for Index:=0 to Count-1 do
        begin
          if Selected.ContainsKey(BookID+#9+IntToStr(Index)) then Continue;
          if Kept<>Index then
            for Key in TArray<string>.Create('Title','Position','EndPosition','PageQuote','Created','Place','PageText') do
              if Result.ValueExists(Section,Key+IntToStr(Index)) then
                Result.WriteString(Section,Key+IntToStr(Kept),Result.ReadString(Section,Key+IntToStr(Index),''))
              else Result.DeleteKey(Section,Key+IntToStr(Kept));
          Inc(Kept);
        end;
        for Index:=Kept to Count-1 do
          for Key in TArray<string>.Create('Title','Position','EndPosition','PageQuote','Created','Place','PageText') do
            Result.DeleteKey(Section,Key+IntToStr(Index));
        if Kept=0 then Result.EraseSection(Section) else Result.WriteInteger(Section,'Count',Kept);
      end;
    except FreeAndNil(Result); raise; end;
  finally Books.Free; Selected.Free; end;
end;

constructor TReaderSavedDialog.CreateFor(Reader: TfrmBuiltinReader);
begin
  inherited CreateNew(Reader); FReader:=Reader; FSettingsFile:=Reader.FSettingsFile;
  FCurrentIdentity:=Reader.FIdentity; FCurrentTitle:=Reader.FBookTitle; BuildUI;
end;

constructor TReaderSavedDialog.CreateProfile(AOwner: TComponent; const SettingsFile: string);
begin inherited CreateNew(AOwner); FSettingsFile:=SettingsFile; BuildUI; end;

procedure TReaderSavedDialog.BuildUI;
var Row, Footer, Body, Scope, SearchRow: TPanel; Button: TButton; Item: TMenuItem;
  procedure AddButton(const Name, Text: string; Width: Integer; Handler: TNotifyEvent);
  begin
    Button:=TReaderPaletteButton.Create(Self); Button.Name:=Name; Button.Parent:=Row; Button.Align:=alLeft; Button.Left:=MaxInt;
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
  AddButton('NotesAdd','Добавить заметку…',140,AddSelected); FAdd:=Button;
  AddButton('NotesEdit','Изменить…',94,EditSelected);
  AddButton('NotesDelete','Удалить',74,DeleteSelected);
  AddButton('NotesDeleteAll','Удалить показанные…',164,DeleteAll); FDeleteVisible:=Button;
  AddButton('NotesExport','Экспорт…',104,ExportMenu); FExport:=Button;
  AddButton('NotesRefresh','Перечитать',106,RefreshClick);
  FExports:=TPopupMenu.Create(Self); FExports.Name:='NotesExportMenu';
  Item:=TMenuItem.Create(Self); Item.Name:='ExportVisibleNotes';
  Item.Caption:='Экспорт показанных записей…'; Item.Tag:=2; Item.OnClick:=ExportSelected; FExports.Items.Add(Item);
  Item:=TMenuItem.Create(Self); Item.Name:='ExportBookNotes';
  Item.Caption:='Экспорт закладок и заметок выбранной книги…'; Item.Tag:=0; Item.OnClick:=ExportSelected; FExports.Items.Add(Item);
  Item:=TMenuItem.Create(Self); Item.Name:='ExportAllNotes';
  Item.Caption:='Экспорт закладок и заметок всех книг…'; Item.Tag:=1; Item.OnClick:=ExportSelected; FExports.Items.Add(Item);
  Scope:=TPanel.Create(Self); Scope.Parent:=Self; Scope.Align:=alTop; Scope.Top:=Row.Height; Scope.Height:=36; Scope.BevelOuter:=bvNone;
  FBooks:=TReaderPaletteCombo.Create(Self); FBooks.Name:='NotesBooks'; FBooks.Parent:=Scope; FBooks.SetBounds(8,4,ClientWidth-270,26);
  FBooks.Anchors:=[akLeft,akTop,akRight]; FBooks.Style:=csDropDownList; FBooks.OnChange:=BooksChanged;
  FShowNotes:=TReaderPaletteCheckBox.Create(Self); FShowNotes.Name:='NotesShowNotes'; FShowNotes.Parent:=Scope;
  FShowNotes.SetBounds(ClientWidth-250,4,112,26); FShowNotes.Anchors:=[akTop,akRight];
  FShowNotes.Caption:='Заметки'; FShowNotes.Checked:=True; FShowNotes.OnClick:=KindChanged;
  FShowBookmarks:=TReaderPaletteCheckBox.Create(Self); FShowBookmarks.Name:='NotesShowBookmarks'; FShowBookmarks.Parent:=Scope;
  FShowBookmarks.SetBounds(ClientWidth-130,4,122,26); FShowBookmarks.Anchors:=[akTop,akRight];
  FShowBookmarks.Caption:='Закладки'; FShowBookmarks.Checked:=True; FShowBookmarks.OnClick:=KindChanged;
  SearchRow:=TPanel.Create(Self); SearchRow.Parent:=Self; SearchRow.Align:=alTop; SearchRow.Top:=Row.Height+Scope.Height;
  SearchRow.Height:=38; SearchRow.BevelOuter:=bvNone;
  FSearch:=TEdit.Create(Self); FSearch.Name:='NotesSearch'; FSearch.Parent:=SearchRow;
  FSearch.Text:=''; // Named VCL edits otherwise inherit their component name as text.
  FSearch.SetBounds(8,4,ClientWidth-120,28); FSearch.Anchors:=[akLeft,akTop,akRight];
  FSearch.TextHint:='Поиск по книге и тексту, цитате, названию и месту'; FSearch.ShowHint:=True;
  FSearch.Hint:='Фрагмент без учёта регистра. Буквы е и ё различаются. Идентификаторы записей не меняются.';
  FSearch.OnChange:=SearchChanged;
  Button:=TReaderPaletteButton.Create(Self); Button.Name:='NotesClearSearch'; Button.Parent:=SearchRow;
  Button.SetBounds(ClientWidth-104,4,96,28); Button.Anchors:=[akTop,akRight]; Button.Caption:='Очистить'; Button.OnClick:=ClearSearch;
  FSearchTimer:=TTimer.Create(Self); FSearchTimer.Enabled:=False; FSearchTimer.Interval:=150; FSearchTimer.OnTimer:=SearchTick;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom; Footer.Height:=62; Footer.BevelOuter:=bvNone;
  FResultStatus:=TLabel.Create(Self); FResultStatus.Name:='NotesResultStatus'; FResultStatus.Parent:=Footer;
  FResultStatus.SetBounds(8,4,ClientWidth-272,54); FResultStatus.AutoSize:=False; FResultStatus.WordWrap:=True;
  FResultStatus.Anchors:=[akLeft,akTop,akRight];
  Button:=TReaderPaletteButton.Create(Self); Button.Parent:=Footer; Button.SetBounds(ClientWidth-248,6,132,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Открыть книгу'; Button.OnClick:=OpenSelected;
  Button:=TReaderPaletteButton.Create(Self); Button.Parent:=Footer; Button.SetBounds(ClientWidth-108,6,100,30);
  Button.Anchors:=[akRight,akBottom]; Button.Caption:='Закрыть'; Button.ModalResult:=mrCancel; Button.Cancel:=True;
  Body:=TPanel.Create(Self); Body.Parent:=Self; Body.Align:=alClient; Body.BevelOuter:=bvNone;
  FContext:=TMemo.Create(Self); FContext.Parent:=Body; FContext.Align:=alBottom; FContext.Height:=155;
  FContext.ReadOnly:=True; FContext.ScrollBars:=ssVertical;
  FList:=TListView.Create(Self); FList.Name:='NotesList'; FList.Parent:=Body; FList.Align:=alClient; FList.ViewStyle:=vsReport;
  FList.ReadOnly:=True; FList.RowSelect:=True; FList.HideSelection:=False; FList.OwnerData:=True; FList.OnData:=ItemData;
  with FList.Columns.Add do begin Caption:='Вид'; Width:=80; end;
  with FList.Columns.Add do begin Caption:='Название'; Width:=235; end;
  with FList.Columns.Add do begin Caption:='Место в книге'; Width:=175; end;
  with FList.Columns.Add do begin Caption:='Книга'; Width:=250; end;
  with FList.Columns.Add do begin Caption:='Добавлено'; Width:=280; end;
  FList.OnSelectItem:=SelectItem; FList.OnDblClick:=OpenSelected;
  RebuildBooks;
  if FCurrentIdentity<>'' then FBooks.ItemIndex:=FBookIDs.IndexOf(FCurrentIdentity);
  Reload; ApplyMHLControlTheme(Self);
  if Assigned(FReader) then FReader.ApplyWindowPalette(Self);
  ActiveControl:=FList;
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
begin if Assigned(FSearchTimer) then FSearchTimer.Enabled:=False; FBookIDs.Free; FStore.Free; inherited; end;

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
begin FSearchTimer.Enabled:=False; ApplyFilter; end;

procedure TReaderSavedDialog.SearchChanged(Sender: TObject);
begin
  FSearchTimer.Enabled:=False; FSearchTimer.Enabled:=True;
  FResultStatus.Caption:='Поиск… Действия будут учитывать новый текст поиска.';
end;

procedure TReaderSavedDialog.SearchTick(Sender: TObject);
begin FlushSearch; end;

procedure TReaderSavedDialog.ClearSearch(Sender: TObject);
begin FSearch.Text:=''; FlushSearch; FSearch.SetFocus; end;

procedure TReaderSavedDialog.RefreshClick(Sender: TObject);
begin
  try FStore.Reload; RebuildBooks; Reload;
  except on E: Exception do MessageDlg('Не удалось перечитать записи. Прежний список сохранён.'+sLineBreak+E.Message,mtError,[mbOK],0); end;
end;

procedure TReaderSavedDialog.FlushSearch;
begin
  // Reading/exporting an unchanged snapshot must keep the selected row and
  // scroll position. Rebuild only when a new text query is pending.
  if not FSearchTimer.Enabled then Exit;
  FSearchTimer.Enabled:=False; ApplyFilter;
end;

function TReaderSavedDialog.RowValue(Item: TListItem): Integer;
begin
  Result:=0;
  if Assigned(Item) and (Item.Index>=0) and (Item.Index<Length(FVisibleRows)) then Result:=FVisibleRows[Item.Index];
end;

function TReaderSavedDialog.ScopeDescription: string;
begin
  if SelectedBookID='' then Result:='все книги' else Result:='книга «'+FBooks.Text+'»';
  if Trim(FSearch.Text)<>'' then Result:=Result+'; поиск «'+Trim(FSearch.Text)+'»';
  if not FShowNotes.Checked then Result:=Result+'; только закладки';
  if not FShowBookmarks.Checked then Result:=Result+'; только заметки';
end;

procedure TReaderSavedDialog.ApplyFilter;
var Rows: TList<Integer>; Available: Integer;
begin
  Rows:=TList<Integer>.Create; Available:=0;
  try
    if FShowNotes.Checked then
    begin
      Inc(Available,Length(FNotes));
      for var I:=0 to High(FNotes) do if ReaderAnnotationMatches(FNotes[I],FSearch.Text) then Rows.Add(I+1);
    end;
    if FShowBookmarks.Checked then
    begin
      Inc(Available,Length(FBookmarkRows));
      for var I:=0 to High(FBookmarkRows) do if ReaderAnnotationMatches(FBookmarkRows[I],FSearch.Text) then Rows.Add(-I-1);
    end;
    FList.Items.BeginUpdate;
    try
      FList.Items.Count:=0; FVisibleRows:=Rows.ToArray; FContext.Clear;
      FList.Items.Count:=Length(FVisibleRows);
      if FList.Items.Count>0 then begin FList.Items[0].Selected:=True; FList.Items[0].Focused:=True; end;
    finally FList.Items.EndUpdate; end;
    FDeleteVisible.Enabled:=Length(FVisibleRows)>0;
    FResultStatus.Caption:=Format('Показано %d из %d. Удаление показанных и их экспорт учитывают книгу, поиск и галочки.',[Length(FVisibleRows),Available]);
  finally Rows.Free; end;
end;

procedure TReaderSavedDialog.ItemData(Sender: TObject; Item: TListItem);
var Value: Integer; Note: TReaderAnnotation;
begin
  Value:=RowValue(Item); Item.Data:=Pointer(NativeInt(Value)); if Value=0 then Exit;
  if Value>0 then begin Note:=FNotes[Value-1]; Item.Caption:='Заметка'; end
  else begin Note:=FBookmarkRows[-Value-1]; Item.Caption:='Закладка'; end;
  Item.SubItems.Clear;
  if Value>0 then Item.SubItems.Add(ReaderAnnotationDisplayTitle(Note)) else Item.SubItems.Add(Note.Title);
  Item.SubItems.Add(Note.Place); Item.SubItems.Add(Note.BookTitle);
  if Note.Created='' then Item.SubItems.Add('Не сохранено в старой версии')
  else Item.SubItems.Add(ReaderAnnotationLocalTime(Note.Created));
end;

procedure TReaderSavedDialog.Reload;
var Identity: string; Note: TReaderAnnotation;
begin
  FSearchTimer.Enabled:=False; Identity:=SelectedBookID; FNotes:=FStore.Items(Identity);
  if Identity='' then Caption:='Закладки и заметки — все книги'
  else Caption:='Закладки и заметки — '+FBooks.Text;
  FAdd.Enabled:=Assigned(FReader) and (Identity=FCurrentIdentity);
  FBookmarkRows:=SavedReaderBookmarks(FSettingsFile,Identity);
  for var I:=0 to High(FBookmarkRows) do
    if Assigned(FReader) and (FBookmarkRows[I].BookID=FCurrentIdentity) then
    begin
      Note:=FBookmarkRows[I]; Note.BookTitle:=FCurrentTitle;
      if Assigned(FReader.FPDF) then Note.Place:='Страница '+IntToStr(Note.Position+1)+' · '+Note.Place
      else Note.Place:=IntToStr(Round(Note.Position*100/Max(1,FReader.FLength)))+'% · '+Note.Place;
      if Note.Quote='' then Note.Quote:=FReader.BookmarkContext(StrToIntDef(Note.ID,-1));
      FBookmarkRows[I]:=Note;
    end;
  ApplyFilter;
end;

function TReaderSavedDialog.VisibleItems: TArray<TReaderAnnotation>;
var Note: TReaderAnnotation; I, Value: Integer;
begin
  FlushSearch; SetLength(Result,Length(FVisibleRows));
  for I:=0 to High(FVisibleRows) do
  begin
    Value:=FVisibleRows[I];
    if Value>0 then Note:=FNotes[Value-1]
    else begin Note:=FBookmarkRows[-Value-1]; Note.Title:='Закладка: '+Note.Title; end;
    Result[I]:=Note;
  end;
end;

procedure TReaderSavedDialog.SelectItem(Sender: TObject; Item: TListItem; Selected: Boolean);
var Index: Integer;
begin
  if not Selected then Exit; Index:=RowValue(Item)-1; FContext.Clear;
  if (Index>=0) and (Index<Length(FNotes)) then
  begin
    FContext.Text:=FNotes[Index].Text+sLineBreak+sLineBreak+ReaderAnnotationLocalTime(FNotes[Index].Created);
    if FNotes[Index].Quote<>'' then FContext.Text:=FContext.Text+sLineBreak+sLineBreak+'Цитата: '+FNotes[Index].Quote;
  end
  else if RowValue(Item)<0 then
  begin
    var Note:=FBookmarkRows[-RowValue(Item)-1];
    FContext.Text:=Note.Title+sLineBreak+sLineBreak+ReaderAnnotationLocalTime(Note.Created)+sLineBreak+sLineBreak+Note.Quote;
  end;
end;

procedure TReaderSavedDialog.OpenSelected(Sender: TObject);
var Index: Integer;
begin
  if FSearchTimer.Enabled then begin FlushSearch; Exit; end;
  if not Assigned(FList.Selected) then Exit; Index:=RowValue(FList.Selected); if Index=0 then Exit;
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
var Index, BookmarkCount: Integer; Note: TReaderAnnotation; Ini: TMemIniFile; Title: string;
begin
  if FSearchTimer.Enabled then begin FlushSearch; Exit; end;
  if not Assigned(FList.Selected) then Exit; Index:=RowValue(FList.Selected); if Index=0 then Exit;
  if Index>0 then
  begin
    Note:=FNotes[Index-1];
    EditAndSaveReaderNote(Self,FStore,Note);
    if Assigned(FReader) then FReader.ReloadAnnotations; RebuildBooks; Reload;
  end
  else
  begin
    // Bookmark IDs are positional. Capture the displayed binding before the
    // modal editor, then validate it against the same fresh INI we will save.
    Note:=FBookmarkRows[-Index-1]; Title:=Note.Title; BookmarkCount:=0;
    for var Saved in FBookmarkRows do if Saved.BookID=Note.BookID then Inc(BookmarkCount);
    if not InputQuery('Название закладки','Название:',Title) or (Title.Trim='') then Exit;
    try
      Ini:=TMemIniFile.Create(FSettingsFile,TEncoding.UTF8);
      try
        if not ReaderBookmarkMatches(Ini,Note,BookmarkCount) then
          raise EReaderAnnotationConflict.Create('Закладки изменились в другом окне. Перечитайте список перед переименованием.');
        Ini.WriteString('Bookmarks.'+Note.BookID,'Title'+Note.ID,Copy(Title.Trim,1,256).Replace('&','&&'));
        SaveMemIniFileAtomically(Ini);
      finally Ini.Free; end;
    except
      on E: EReaderAnnotationConflict do
      begin MessageDlg(E.Message,mtWarning,[mbOK],0); Exit; end;
      on E: Exception do
      begin MessageDlg('Не удалось переименовать закладку.'+sLineBreak+E.Message,mtError,[mbOK],0); Exit; end;
    end;
    Reload;
  end;
end;

procedure TReaderSavedDialog.DeleteSelected(Sender: TObject);
var Index: Integer; Ini: TMemIniFile; Note: TReaderAnnotation;
begin
  if FSearchTimer.Enabled then begin FlushSearch; Exit; end;
  if not Assigned(FList.Selected) then Exit;
  Index:=RowValue(FList.Selected); if Index=0 then Exit;
  if Index>0 then Note:=FNotes[Index-1] else Note:=FBookmarkRows[-Index-1];
  if MessageDlg('Удалить выбранную запись «'+ReaderAnnotationDisplayTitle(Note)+'»?',mtConfirmation,[mbYes,mbNo],0)<>mrYes then Exit;
  try
    if Index>0 then FStore.Remove(Note.ID)
    else
    begin
      Ini:=ReaderBookmarkRemoval(FSettingsFile,TArray<TReaderAnnotation>.Create(Note));
      try SaveMemIniFileAtomically(Ini); finally Ini.Free; end;
    end;
  except on E: Exception do
    begin MessageDlg('Не удалось удалить запись. Перечитайте список перед повтором.'+sLineBreak+E.Message,mtError,[mbOK],0); Exit; end;
  end;
  if Assigned(FReader) then begin FReader.ReloadAnnotations; FReader.RenderPage; end;
  RebuildBooks; Reload;
end;

procedure TReaderSavedDialog.AddSelected(Sender: TObject);
begin
  if not Assigned(FReader) then Exit;
  FReader.NotesClick(Sender); FreeAndNil(FStore); FStore:=TReaderAnnotations.Create(FSettingsFile); RebuildBooks; Reload;
end;

procedure TReaderSavedDialog.DeleteAll(Sender: TObject);
var IDs: TList<string>; Bookmarks: TList<TReaderAnnotation>; Ini: TMemIniFile; Scope: string;
  Count: Integer;
begin
  FlushSearch; Count:=Length(FVisibleRows); if Count=0 then Exit;
  Scope:=ScopeDescription;
  IDs:=TList<string>.Create; Bookmarks:=TList<TReaderAnnotation>.Create; Ini:=nil;
  try
    // Capture exact IDs before the confirmation. Hidden rows and a previous
    // selection never become part of this destructive operation.
    for var Value in FVisibleRows do
      if Value>0 then IDs.Add(FNotes[Value-1].ID) else Bookmarks.Add(FBookmarkRows[-Value-1]);
    if MessageDlg(Format('Удалить только показанные записи? Записей: %d.'+sLineBreak+'Область: %s.'+sLineBreak+
      'Скрытые поиском и другими фильтрами записи останутся.',[Count,Scope]),mtConfirmation,[mbYes,mbNo],0)<>mrYes then Exit;
    try
      // Check positional bookmark bindings before changing either store.
      Ini:=ReaderBookmarkRemoval(FSettingsFile,Bookmarks.ToArray);
      FStore.RemoveMany(IDs.ToArray);
      if Assigned(Ini) then SaveMemIniFileAtomically(Ini);
    except on E: Exception do
      begin
        MessageDlg('Удаление не завершено. Часть подтверждённых записей могла быть удалена; скрытые записи не затрагивались.'+
          sLineBreak+'Перечитайте список перед повтором.'+sLineBreak+E.Message,mtError,[mbOK],0);
        RebuildBooks; Reload; Exit;
      end;
    end;
    if Assigned(FReader) then FReader.ReloadAnnotations;
    RebuildBooks; Reload;
  finally Ini.Free; Bookmarks.Free; IDs.Free; end;
end;

procedure TReaderSavedDialog.ExportMenu(Sender: TObject);
var Point: TPoint; Item: TMenuItem;
begin
  FlushSearch;
  Item:=FindComponent('ExportVisibleNotes') as TMenuItem; Item.Enabled:=Length(FVisibleRows)>0;
  Item.Caption:=Format('Экспорт показанных записей (%d)…',[Length(FVisibleRows)]);
  Item:=FindComponent('ExportBookNotes') as TMenuItem; Item.Enabled:=SelectedBookID<>'';
  Item.Caption:='Экспорт выбранной книги без поиска…';
  Item:=FindComponent('ExportAllNotes') as TMenuItem; Item.Caption:='Экспорт всех книг без поиска…';
  Point:=FExport.ClientToScreen(System.Types.Point(0,FExport.Height)); FExports.Popup(Point.X,Point.Y);
end;

procedure TReaderSavedDialog.ExportSelected(Sender: TObject);
var Identity, Scope: string; AllBooks: Boolean; Items: TList<TReaderAnnotation>;
begin
  FlushSearch;
  if TComponent(Sender).Tag=2 then
  begin ExportReaderAnnotationItems(Self,VisibleItems,'Показанные записи: '+ScopeDescription); Exit; end;
  AllBooks:=TComponent(Sender).Tag=1; Identity:=SelectedBookID;
  if AllBooks then Identity:='';
  if FShowNotes.Checked and FShowBookmarks.Checked then Scope:='Закладки и заметки'
  else if FShowBookmarks.Checked then Scope:='Закладки' else Scope:='Заметки';
  if AllBooks then Scope:=Scope+' всех книг без текстового поиска'
  else Scope:=Scope+' книги «'+FBooks.Text+'» без текстового поиска';
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

function CreateReaderNotesDialog(Owner: TComponent; const SettingsFile: string): TCustomForm;
begin Result:=TReaderSavedDialog.CreateProfile(Owner,SettingsFile); end;

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
  if Assigned(FPDF) then
  begin
    Notes:=nil;
    for var View in FPDFPageViews do Notes:=Concat(Notes,FAnnotationIndex.QueryPage(View.Page));
  end
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
        Rectangles:=FPDF.TextRectangles(Notes[I].Position,Notes[I].RangeStart,Notes[I].RangeEnd-Notes[I].RangeStart);
        FVisibleAnnotations[I].Rectangles:=PDFViewRectangles(Notes[I].Position,Rectangles);
      end
      else if not Notes[I].RangeIsPageText then
      begin
        PreparePageSelection; First:=Max(CurrentPosition,Notes[I].RangeStart); Last:=Min(FNext,Notes[I].RangeEnd);
        FVisibleAnnotations[I].Rectangles:=TextSelectionRectangles(First,Last);
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
  if not Assigned(FPDF) then
  begin
    if TextLinkTargetAt(X,Y)>=0 then
    begin
      FSurface.Cursor:=crHandPoint;
      if Hint='' then Hint:='Перейти по ссылке в книге. Текст ссылки можно выделить перетаскиванием.';
    end
    else if FSelectionEnabled then FSurface.Cursor:=crIBeam else FSurface.Cursor:=crDefault;
  end;
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
    EditAndSaveReaderNote(Self,Store,Note); ReloadAnnotations;
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
      Result.RangeIsPageText:=True; Result.Position:=FPDFSelectionPage;
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
    begin if Length(FPDFPageViews)=1 then begin Result.RangeIsPageText:=True; Result.RangeStart:=0; Result.RangeEnd:=Length(Quote); end; end
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
    if not EditAndSaveReaderNote(Self,Store,Note) then Exit;
    ReloadAnnotations;
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
    Formats:=TReaderPaletteCombo.Create(StyleDialog); Formats.Parent:=StyleDialog; Formats.SetBounds(12,92,386,26);
    Formats.Style:=csDropDownList; Formats.Items.Add('Документ Word (DOCX)'); Formats.Items.Add('Документ HTML');
    Formats.Items.Add('Обычный текст (UTF-8)'); Formats.ItemIndex:=0;
    Styles:=TReaderPaletteCombo.Create(StyleDialog); Styles.Name:='ExportStyle'; Styles.Parent:=StyleDialog; Styles.SetBounds(12,130,386,26);
    Styles.Style:=csDropDownList; Styles.Items.Add('Строгий — компактный отчёт с разделителями');
    Styles.Items.Add('Классический — книжные заголовки и цитаты'); Styles.Items.Add('Современный — карточки с полями');
    Styles.Items.Add('Бумага — дневник с полями для размышлений'); Styles.ItemIndex:=1; Formats.OnChange:=TReaderExportOptionsDialog(StyleDialog).FormatChanged;
    Button:=TReaderPaletteButton.Create(StyleDialog); Button.Parent:=StyleDialog; Button.SetBounds(166,198,112,30);
    Button.Caption:='Продолжить'; Button.ModalResult:=mrOk; Button.Default:=True;
    Button:=TReaderPaletteButton.Create(StyleDialog); Button.Parent:=StyleDialog; Button.SetBounds(286,198,112,30);
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
  if FInterfaceHidden then
  begin InterfaceClick(nil); FSearchPanel.Visible:=True; end
  else FSearchPanel.Visible:=not FSearchPanel.Visible;
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
    if RepeatQuery and (FPDFQuery=FSearchQuery) and (FPDFMatchPage>=FPage) and (FPDFMatchPage<FPage+Length(FPDFPageViews)) then
    begin
      FSearchPage:=FPDFMatchPage;
      if Backward then
      begin
        FSearchStart:=FPDFMatchIndex-1;
        if FPDFMatchIndex=0 then
        begin FSearchPage:=(FPDFMatchPage+FPDF.PageCount-1) mod FPDF.PageCount; FSearchStart:=-1; end;
      end
      else FSearchStart:=FPDFMatchIndex+1;
    end;
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
      if (FSearchPage>=FPage) and (FSearchPage<FPage+Length(FPDFPageViews)) then RenderPage else NavigateTo(FSearchPage);
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
var Dialog: TForm; FontBox, SizeBox, SpacingBox, MarginBox, WidthBox, ZoomBox, InitialBox, LayoutBox, TurnBox, AppearanceBox: TComboBox; FontNames: TStringList; LabelText: TLabel; Button: TButton; FormattingBox, NotesBox, InitialCheck, HoldCheck, SelectionCheck: TCheckBox; TitleBox, SubtitleBox: TColorBox; I: Integer;
  procedure AddLabel(const Text: string; Top: Integer);
  begin LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.SetBounds(16,Top,100,22); LabelText.Caption:=Text; end;
  function Choice(Top: Integer): TComboBox;
  begin Result:=TReaderPaletteCombo.Create(Dialog); Result.Parent:=Dialog; Result.SetBounds(118,Top,216,26); Result.Style:=csOwnerDrawFixed; end;
begin
  if Assigned(FPDF) then
  begin
    Dialog:=TForm.CreateNew(Self);
    try
      Dialog.Caption:='Вид страниц'; Dialog.BorderStyle:=bsDialog; Dialog.Position:=poOwnerFormCenter;
      Dialog.ClientWidth:=350; Dialog.ClientHeight:=316; Dialog.Font.Assign(Font);
      AddLabel('Приближение, %',20); ZoomBox:=Choice(16);
      for I:=12 to 30 do ZoomBox.Items.Add(IntToStr(I*10));
      ZoomBox.ItemIndex:=ZoomBox.Items.IndexOf(IntToStr(FInspectionPercent));
      AddLabel('Страниц',58); LayoutBox:=Choice(54); LayoutBox.Name:='cbReaderPageLayout';
      LayoutBox.Items.Text:='Одна страница'+#13+'Две страницы'+#13+'Автоматически по ширине';
      LayoutBox.ItemIndex:=Ord(FPageLayout);
      AddLabel('Перелистывать',96); TurnBox:=Choice(92); TurnBox.Name:='cbReaderPageTurn';
      TurnBox.Items.Text:='Парами страниц'+#13+'Со сдвигом на одну'; TurnBox.ItemIndex:=Ord(FPageTurn);
      AddLabel('Стиль страниц',134); AppearanceBox:=Choice(130); AppearanceBox.Name:='cbReaderPageAppearance';
      AppearanceBox.Items.Text:='Плоские страницы'+#13+'Объёмная книга'; AppearanceBox.ItemIndex:=Ord(FPageAppearance);
      LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.AutoSize:=False; LabelText.SetBounds(16,166,318,32);
      LabelText.WordWrap:=True; LabelText.Caption:='Для сканов и комиксов. На странице с текстом мышь выделяет текст для копирования.';
      HoldCheck:=TReaderPaletteCheckBox.Create(Dialog); HoldCheck.Parent:=Dialog; HoldCheck.SetBounds(16,202,320,28);
      HoldCheck.Caption:='Приближение при удержании'; HoldCheck.Checked:=FInspectionHold;
      HoldCheck.ShowHint:=True; HoldCheck.Hint:='Отпускание кнопки возвращает прежний масштаб. Без галочки возвращает повторный щелчок.';
      SelectionCheck:=TReaderPaletteCheckBox.Create(Dialog); SelectionCheck.Parent:=Dialog; SelectionCheck.SetBounds(16,232,320,28);
      SelectionCheck.Caption:='Выделять текст мышью'; SelectionCheck.Checked:=FSelectionEnabled;
      Button:=TReaderPaletteButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(156,278,86,26); Button.Caption:='Применить'; Button.Default:=True; Button.ModalResult:=mrOk;
      Button:=TReaderPaletteButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(248,278,86,26); Button.Caption:='Отмена'; Button.Cancel:=True; Button.ModalResult:=mrCancel;
      ApplyReaderPalette(Dialog,ThemeBackground,ThemeText,FNight);
      if Dialog.ShowModal=mrOk then begin SetInspectionPercent(StrToIntDef(ZoomBox.Text,150)); SetInspectionHold(HoldCheck.Checked); SetSelectionEnabled(SelectionCheck.Checked); SetPageAppearance(TReaderPageAppearance(EnsureRange(AppearanceBox.ItemIndex,0,1))); FPageTurn:=TReaderPageTurn(EnsureRange(TurnBox.ItemIndex,0,1)); SetPageLayout(TReaderPageLayout(EnsureRange(LayoutBox.ItemIndex,0,2))); InvalidateLayout; end;
    finally Dialog.Free; end;
    Exit;
  end;
  Dialog:=TForm.CreateNew(Self); FontNames:=TStringList.Create;
  try
    Dialog.Caption:='Текст и оформление'; Dialog.BorderStyle:=bsDialog; Dialog.Position:=poOwnerFormCenter;
    Dialog.ClientWidth:=350; Dialog.ClientHeight:=543; Dialog.Font.Assign(Font);
    AddLabel('Шрифт / размер',20); FontBox:=Choice(16); FontBox.Width:=160;
    ReaderFontChoices(FontNames,FontBox.Items,FFontName); FontBox.ItemIndex:=FontNames.IndexOf(FFontName);
    SizeBox:=TReaderPaletteCombo.Create(Dialog); SizeBox.Parent:=Dialog; SizeBox.SetBounds(286,16,48,26); SizeBox.Style:=csOwnerDrawFixed;
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
    AddLabel('Страниц',172); LayoutBox:=Choice(168); LayoutBox.Name:='cbReaderPageLayout';
    LayoutBox.Items.Text:='Одна страница'+#13+'Две страницы'+#13+'Автоматически по ширине';
    LayoutBox.ItemIndex:=Ord(FPageLayout);
    LayoutBox.ShowHint:=True; LayoutBox.Hint:='Одна или две страницы. В узком окне остаётся одна страница; ширина выше задаёт предел для каждой страницы.';
    AddLabel('Перелистывать',210); TurnBox:=Choice(206); TurnBox.Name:='cbReaderPageTurn';
    TurnBox.Items.Text:='Парами страниц'+#13+'Со сдвигом на одну'; TurnBox.ItemIndex:=Ord(FPageTurn);
    FormattingBox:=TReaderPaletteCheckBox.Create(Dialog); FormattingBox.Parent:=Dialog; FormattingBox.SetBounds(16,242,320,26);
    FormattingBox.Caption:='Оформление книги: заголовки, стихи, цитаты'; FormattingBox.Checked:=FBookFormatting;
    NotesBox:=TReaderPaletteCheckBox.Create(Dialog); NotesBox.Parent:=Dialog; NotesBox.SetBounds(16,272,320,26);
    NotesBox.Caption:='Показывать сноски этой страницы внизу'; NotesBox.Checked:=FShowFootnotes;
    InitialCheck:=TReaderPaletteCheckBox.Create(Dialog); InitialCheck.Parent:=Dialog; InitialCheck.SetBounds(16,302,320,26);
    InitialCheck.Caption:='Выделять первые буквы абзацев'; InitialCheck.Checked:=FInitialsMode<>rimNone;
    AddLabel('Где выделять',336); InitialBox:=Choice(332);
    InitialBox.Items.Text:='В начале главы'+#13+'В каждом абзаце';
    InitialBox.ItemIndex:=Max(0,Ord(FInitialsMode)-1);
    AddLabel('Заголовки',372); TitleBox:=TReaderPaletteColorBox.Create(Dialog); TitleBox.Parent:=Dialog; TitleBox.SetBounds(118,368,216,26);
    TitleBox.Style:=[cbStandardColors,cbIncludeDefault,cbCustomColor]; TitleBox.Selected:=FHeadingColors[Ord(FNight),0];
    AddLabel('Подзаголовки',406); SubtitleBox:=TReaderPaletteColorBox.Create(Dialog); SubtitleBox.Parent:=Dialog; SubtitleBox.SetBounds(118,402,216,26);
    SubtitleBox.Style:=TitleBox.Style; SubtitleBox.Selected:=FHeadingColors[Ord(FNight),1];
    ConfigureReaderColorBox(TitleBox,FHeadingColors[Ord(FNight),0]);
    ConfigureReaderColorBox(SubtitleBox,FHeadingColors[Ord(FNight),1]);
    AddLabel('Стиль страниц',472); AppearanceBox:=Choice(468); AppearanceBox.Name:='cbReaderPageAppearance';
    AppearanceBox.Items.Text:='Плоские страницы'+#13+'Объёмная книга'; AppearanceBox.ItemIndex:=Ord(FPageAppearance);
    SelectionCheck:=TReaderPaletteCheckBox.Create(Dialog); SelectionCheck.Parent:=Dialog; SelectionCheck.SetBounds(16,432,320,28);
    SelectionCheck.Caption:='Выделять текст мышью'; SelectionCheck.Checked:=FSelectionEnabled;
    TitleBox.ShowHint:=True; TitleBox.Hint:='Цвета сохраняются для каждой темы. В тёмной теме слишком тёмные оттенки подсветляются.';
    SubtitleBox.ShowHint:=True; SubtitleBox.Hint:=TitleBox.Hint;
    Button:=TReaderPaletteButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(156,511,86,26); Button.Caption:='Применить'; Button.Default:=True; Button.ModalResult:=mrOk;
    Button:=TReaderPaletteButton.Create(Dialog); Button.Parent:=Dialog; Button.SetBounds(248,511,86,26); Button.Caption:='Отмена'; Button.Cancel:=True; Button.ModalResult:=mrCancel;
    ApplyReaderPalette(Dialog,ThemeBackground,ThemeText,FNight);
    if Dialog.ShowModal=mrOk then
    begin
      SetPageAppearance(TReaderPageAppearance(EnsureRange(AppearanceBox.ItemIndex,0,1)));
      FPageLayout:=TReaderPageLayout(EnsureRange(LayoutBox.ItemIndex,0,2));
      FPageTurn:=TReaderPageTurn(EnsureRange(TurnBox.ItemIndex,0,1));
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
  FProgressLine.Canvas.Brush.Color:=ReaderBlendColor(ThemeBackground,ThemeText,28);
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

procedure TfrmBuiltinReader.InterfaceClick(Sender: TObject);
begin
  DisableAlign;
  try
    if not FInterfaceHidden then
    begin
      FInterfaceHidden:=True;
      FInterfaceMenu:=Menu; Menu:=nil;
      FInterfaceSearch:=FSearchPanel.Visible;
      FTop.Visible:=False; FBottom.Visible:=False;
      FSearchPanel.Visible:=False; FFontOffer.Visible:=False;
      FInterfaceReturn.Visible:=True;
    end
    else
    begin
      Menu:=FInterfaceMenu; FInterfaceMenu:=nil;
      FTop.Visible:=True; FBottom.Visible:=True;
      FSearchPanel.Visible:=FInterfaceSearch;
      FFontOffer.Visible:=(FMissingFonts.Count>0) and not FFontOfferDeclined;
      FInterfaceReturn.Visible:=False; FInterfaceHidden:=False;
    end;
  finally EnableAlign; end;
  if Assigned(FOnInterfaceModeChanged) then FOnInterfaceModeChanged(Self);
  RefreshWindowTheme; FSurface.SetFocus;
end;

procedure TfrmBuiltinReader.FullScreenClick(Sender: TObject);
begin
  if not FFullScreen then
  begin
    if not Assigned(FOnFullScreenModeChanged) then
    begin
      FFullScreenPlacement:=Default(TWindowPlacement);
      FFullScreenPlacement.length:=SizeOf(FFullScreenPlacement);
      if not GetWindowPlacement(Handle,@FFullScreenPlacement) then RaiseLastOSError;
      FFullScreenBorder:=BorderStyle;
      if WindowState=wsNormal then FNormalBounds:=BoundsRect else FNormalBounds:=FRestoredBounds;
    end;
    FFullScreen:=True;
    if not Assigned(FOnFullScreenModeChanged) then
    begin BorderStyle:=bsNone; WindowState:=wsMaximized; end;
    FFullScreenButton.Hint:='Вернуться к обычному окну (F11)';
  end
  else
  begin
    if not Assigned(FOnFullScreenModeChanged) then
    begin
      WindowState:=wsNormal; BorderStyle:=FFullScreenBorder;
      if not SetWindowPlacement(Handle,@FFullScreenPlacement) then RaiseLastOSError;
    end;
    FFullScreen:=False; FFullScreenButton.Hint:='На весь экран (F11)';
  end;
  if Assigned(FOnFullScreenModeChanged) then FOnFullScreenModeChanged(Self);
  RefreshWindowTheme; FSurface.SetFocus;
end;

procedure TfrmBuiltinReader.ToggleInterface;
begin InterfaceClick(nil); end;

procedure TfrmBuiltinReader.ToggleFullScreen;
begin FullScreenClick(nil); end;

procedure TfrmBuiltinReader.KeyReader(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key=VK_F11) and (Shift=[]) then
  begin FullScreenClick(nil); Key:=0; Exit; end;
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
    VK_ESCAPE: if FInterfaceHidden then InterfaceClick(nil)
      else if FFullScreen then FullScreenClick(nil) else Close;
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
      FDictionaryExecutable:=Ini.ReadString('Reader','DictionaryExecutable','');
      FLinePercent:=EnsureRange(Ini.ReadInteger('Reader','LinePercent',110),100,180);
      FMargin:=EnsureRange(Ini.ReadInteger('Reader','Margin',32),12,80);
      FPageLayout:=TReaderPageLayout(EnsureRange(Ini.ReadInteger('Reader','PageLayout',0),0,2));
      FPageTurn:=TReaderPageTurn(EnsureRange(Ini.ReadInteger('Reader','PageTurn',0),0,1));
      FPageAppearance:=TReaderPageAppearance(EnsureRange(Ini.ReadInteger('Reader','PageAppearance',0),0,1));
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
      // Reading has its own palette, including when launched by the catalogue.
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
  RefreshWindowTheme; Message.Result:=0;
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
    Ini.WriteString('Reader','DictionaryExecutable',FDictionaryExecutable);
    Ini.WriteBool('Reader','BookFormatting',FBookFormatting);
    Ini.WriteBool('Reader','ShowFootnotes',FShowFootnotes); Ini.WriteBool('Reader','NumberChapters',FNumberChapters);
    Ini.WriteBool('Reader','DecorativeInitials',FDecorativeInitials);
    Ini.WriteInteger('Reader','InitialsMode',Ord(FInitialsMode));
    for I:=0 to 1 do for J:=0 to 1 do Ini.WriteInteger('Reader',Format('HeadingColor%d_%d',[I,J]),FHeadingColors[I,J]);
    Ini.WriteInteger('Reader','PageLayout',Ord(FPageLayout));
    Ini.WriteInteger('Reader','PageTurn',Ord(FPageTurn));
    Ini.WriteInteger('Reader','PageAppearance',Ord(FPageAppearance));
    Ini.WriteInteger('Reader','MaxTextWidth',FMaxTextWidth);
    Ini.WriteInteger('Reader','InspectionPercent',FInspectionPercent);
    Ini.WriteBool('Reader','InspectionHold',FInspectionHold);
    Ini.WriteBool('Reader','SelectionEnabled',FSelectionEnabled);
    if FInspect then Ini.WriteInteger('Reader','PDFZoom',FInspectZoom) else Ini.WriteInteger('Reader','PDFZoom',FZoom);
    Ini.WriteBool('Reader','Night',FNight);
    Ini.WriteInteger('Reader','Theme',FTheme);
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
  SettingsFile, PDFLibrary: string; const OnProgress: TProc<Integer>; const OnOpenNote: TProc<TReaderAnnotation>;
  const OnMissingComponent: TProc<string>);
var Form: TfrmBuiltinReader; Requested: TReaderAnnotation; Required: string;
begin
  Requested:=Default(TReaderAnnotation); Form:=TfrmBuiltinReader.Create(Owner);
  try
    Form.OpenBook(FileName,BookTitle,Identity,SettingsFile,PDFLibrary,OnProgress); Form.ShowModal;
    Requested:=Form.FRequestedNote; Required:=Form.RequiredComponent;
  finally Form.Free; end;
  // Release the reader, its worker and the loaded document before opening an
  // optional-component dialog. No modal prompt originates from a worker.
  if Required<>'' then
  begin
    if Assigned(OnMissingComponent) then OnMissingComponent(Required)
    else raise EMHLComponentRequired.Create(Required,'Для иллюстраций этой книги нужен компонент '+Required+'.');
    Exit;
  end;
  if (Requested.ID<>'') and Assigned(OnOpenNote) then OnOpenNote(Requested);
end;

end.
