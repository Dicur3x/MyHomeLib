// Native fixed-footer regression. Requires BookInfoPanel, unit_BookGallery,
// unit_MHLTheme, VCL controls/graphics/pngimage, IOUtils/Hash/Math/Diagnostics.
// Include in CollectionViewsTest; entry point TestInfoPanelFooter, mode book-preview-layout.
type
  TInfoFooterControlAccess = class(TControl);
  TInfoFooterPanelAccess = class(TInfoPanel);

  TInfoFooterMessageProbe = class
  private
    FControl: TControl;
    FPrevious: TWndMethod;
    FDescription: string;
    procedure WindowMessage(var Message: TMessage);
  public
    Active: Boolean;
    Counts, Ticks: array[0..7] of Int64;
    PaintCounts, PaintTicks: array[0..5] of Int64;
    SizeBoundsChanges: Integer;
    LastSizeBounds: TRect;
    constructor CreateFor(Control: TControl; const Description: string);
    destructor Destroy; override;
    procedure Dump;
  end;

  TInfoFooterClickProbe = class
    Clicks: Integer;
    ActiveLayout: Boolean;
    LayoutStarts, LayoutTicks, LayoutCounts: array[TInfoPanelLayoutStage] of Int64;
    procedure Clicked(Sender: TObject);
    procedure LayoutStage(Sender: TObject; Stage: TInfoPanelLayoutStage; Starting: Boolean);
    procedure DumpLayout;
  end;

constructor TInfoFooterMessageProbe.CreateFor(Control: TControl; const Description: string);
begin
  inherited Create;
  FControl:=Control; FDescription:=Description;
  FPrevious:=TInfoFooterControlAccess(FControl).WindowProc;
  TInfoFooterControlAccess(FControl).WindowProc:=WindowMessage;
end;

destructor TInfoFooterMessageProbe.Destroy;
begin
  Active:=False;
  TInfoFooterControlAccess(FControl).WindowProc:=FPrevious;
  inherited;
end;

procedure TInfoFooterMessageProbe.WindowMessage(var Message: TMessage);
var Stage, PaintStage: Integer; Started, Elapsed: Int64; SizeBounds: TRect;
begin
  if not Active then begin FPrevious(Message); Exit; end;
  case Message.Msg of
    WM_SETFONT, CM_FONTCHANGED, CM_PARENTFONTCHANGED: Stage:=0;
    LM_GETIDEALSIZE: Stage:=1;
    WM_SETTEXT, CM_TEXTCHANGED: Stage:=2;
    WM_WINDOWPOSCHANGING, WM_WINDOWPOSCHANGED, CM_VISIBLECHANGED, CM_SHOWINGCHANGED: Stage:=3;
    WM_SIZE: Stage:=4;
    WM_PAINT, WM_ERASEBKGND, WM_NCPAINT: Stage:=5;
    WM_SETREDRAW: Stage:=6;
  else Stage:=7;
  end;
  if (Message.Msg=WM_SIZE) and (FControl is TWinControl) and
    TWinControl(FControl).HandleAllocated then
  begin
    GetWindowRect(TWinControl(FControl).Handle,SizeBounds);
    // VCL/style hooks can dispatch WM_SIZE twice for the same outer bounds.
    // Count actual native extents, independently of duplicate notifications.
    if (SizeBoundsChanges=0) or (SizeBounds.Width<>LastSizeBounds.Width) or
      (SizeBounds.Height<>LastSizeBounds.Height) then Inc(SizeBoundsChanges);
    LastSizeBounds:=SizeBounds;
  end;
  // Keep client paint (real invalidation versus supplied print/background DC)
  // separate from nonclient styled scrollbars and explicit print messages.
  // Durations remain inclusive; a parent can dispatch a child synchronously.
  PaintStage:=-1;
  case Message.Msg of
    WM_PAINT: if Message.WParam=0 then PaintStage:=0 else PaintStage:=1;
    WM_ERASEBKGND: PaintStage:=2;
    WM_NCPAINT: PaintStage:=3;
    WM_PRINTCLIENT: PaintStage:=4;
    WM_PRINT: PaintStage:=5;
  end;
  Started:=TStopwatch.GetTimeStamp;
  try FPrevious(Message);
  finally
    Elapsed:=TStopwatch.GetTimeStamp-Started;
    Inc(Counts[Stage]); Inc(Ticks[Stage],Elapsed);
    if PaintStage>=0 then begin Inc(PaintCounts[PaintStage]); Inc(PaintTicks[PaintStage],Elapsed); end;
  end;
end;

procedure TInfoFooterMessageProbe.Dump;
var Total: Int64; I: Integer;
begin
  Total:=0;
  for I:=Low(Ticks) to High(Ticks) do Inc(Total,Ticks[I]);
  Writeln('TRACE footer window inclusive ',FDescription,' total_ms=',Total*1000 div TStopwatch.Frequency,
    ' font=',Counts[0],'/',Ticks[0]*1000 div TStopwatch.Frequency,
    ' ideal=',Counts[1],'/',Ticks[1]*1000 div TStopwatch.Frequency,
    ' text=',Counts[2],'/',Ticks[2]*1000 div TStopwatch.Frequency,
    ' position=',Counts[3],'/',Ticks[3]*1000 div TStopwatch.Frequency,
    ' size=',Counts[4],'/',Ticks[4]*1000 div TStopwatch.Frequency,
    ' paint=',Counts[5],'/',Ticks[5]*1000 div TStopwatch.Frequency,
    ' redraw=',Counts[6],'/',Ticks[6]*1000 div TStopwatch.Frequency,
    ' other=',Counts[7],'/',Ticks[7]*1000 div TStopwatch.Frequency);
  Total:=0;
  for I:=Low(PaintCounts) to High(PaintCounts) do Inc(Total,PaintCounts[I]);
  if Total>0 then
    Writeln('TRACE footer paint dispatch ',FDescription,
      ' client_zero=',PaintCounts[0],'/',PaintTicks[0]*1000 div TStopwatch.Frequency,
      ' client_dc=',PaintCounts[1],'/',PaintTicks[1]*1000 div TStopwatch.Frequency,
      ' erase=',PaintCounts[2],'/',PaintTicks[2]*1000 div TStopwatch.Frequency,
      ' nonclient=',PaintCounts[3],'/',PaintTicks[3]*1000 div TStopwatch.Frequency,
      ' printclient=',PaintCounts[4],'/',PaintTicks[4]*1000 div TStopwatch.Frequency,
      ' print=',PaintCounts[5],'/',PaintTicks[5]*1000 div TStopwatch.Frequency);
end;

procedure InfoFooterHookControls(Control: TControl; Profiles: TObjectList<TInfoFooterMessageProbe>);
var I: Integer;
begin
  Profiles.Add(TInfoFooterMessageProbe.CreateFor(Control,
    IntToStr(Profiles.Count)+':'+Control.ClassName));
  if Control is TWinControl then
    for I:=0 to TWinControl(Control).ControlCount-1 do
      InfoFooterHookControls(TWinControl(Control).Controls[I],Profiles);
end;

procedure TInfoFooterClickProbe.Clicked(Sender: TObject);
begin
  Require(Sender is TButton, 'Footer click has an unexpected sender');
  Inc(Clicks);
end;

procedure TInfoFooterClickProbe.LayoutStage(Sender: TObject;
  Stage: TInfoPanelLayoutStage; Starting: Boolean);
begin
  if not ActiveLayout then Exit;
  if Starting then
  begin
    Inc(LayoutCounts[Stage]); LayoutStarts[Stage]:=TStopwatch.GetTimeStamp;
  end
  else Inc(LayoutTicks[Stage],TStopwatch.GetTimeStamp-LayoutStarts[Stage]);
end;

procedure TInfoFooterClickProbe.DumpLayout;
const Names: array[TInfoPanelLayoutStage] of string = ('suspend_redraw',
  'flush_texts','restore_align','flush_visibility','layout','footer',
  'layout_pass','links','detail','pass_align','restore_redraw');
var Stage: TInfoPanelLayoutStage;
begin
  for Stage:=Low(TInfoPanelLayoutStage) to High(TInfoPanelLayoutStage) do
    Writeln('TRACE footer layout inclusive stage=',Names[Stage],
      ' count=',LayoutCounts[Stage],
      ' ms=',LayoutTicks[Stage]*1000 div TStopwatch.Frequency);
end;

function InfoFooterViewport(Panel: TInfoPanel): TScrollBox;
var I: Integer;
begin
  Result := nil;
  for I := 0 to Panel.ControlCount - 1 do
    if Panel.Controls[I] is TScrollBox then Exit(TScrollBox(Panel.Controls[I]));
end;

function InfoFooterContent(Viewport: TScrollBox): TWinControl;
var I: Integer;
begin
  Result := nil;
  for I := 0 to Viewport.ControlCount - 1 do
    if Viewport.Controls[I] is TPanel then Exit(TWinControl(Viewport.Controls[I]));
end;

procedure TestInfoPanelFooter;
const
  FB2 = '<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' +
    '<description><title-info><book-title>Проверка панели ё</book-title></title-info></description>' +
    '<body><section><p>Immutable owned preview fixture.</p></section></body></FictionBook>';
var
  Host: TForm;
  Panel: TInfoPanel;
  Viewport: TScrollBox;
  Content: TWinControl;
  Cover: TImage;
  Annotation: TMemo;
  AnnotationBefore: string;
  Probe: TInfoFooterClickProbe;
  Profiles: TObjectList<TInfoFooterMessageProbe>;
  Profile: TInfoFooterMessageProbe;
  Bitmap, Snapshot: TBitmap;
  Png: TPngImage;
  Root, SourceFile, SourceHash, SettingsHash, LongAnnotation, Context: string;
  OriginalTheme, Dark: Boolean;
  DPI, I, J, OriginalFontSize, SavedScroll, VisibleHeight, HiddenHeight: Integer;
  FooterRect, BeforeScrollRect: TRect;
  Started: TStopwatch;
  TraceCycling: Boolean;
  FillTicks: array[0..6] of Int64;
  PhaseStart, NowTicks, CheckTicks, ScrollTicks: Int64;
  CyclingMS: Int64;
  CompletedCases, SlowCases: Integer;
  PerformanceSummary, SlowSummary: string;

  procedure FillPhase(Stage: Integer);
  begin
    if not TraceCycling then Exit;
    NowTicks := TStopwatch.GetTimeStamp;
    Inc(FillTicks[Stage], NowTicks - PhaseStart);
    PhaseStart := NowTicks;
  end;

  procedure TraceCycle(Index: Integer);
  var K: Integer; FillTotal: Int64;
  begin
    FillTotal := 0;
    for K := Low(FillTicks) to High(FillTicks) do Inc(FillTotal, FillTicks[K]);
    Writeln('TRACE footer cycle dark=', Ord(Dark), ' dpi=', DPI, ' count=', Index,
      ' total_ms=', Started.ElapsedMilliseconds,
      ' fill_ms=', FillTotal * 1000 div TStopwatch.Frequency,
      ' check_ms=', CheckTicks * 1000 div TStopwatch.Frequency,
      ' scroll_ms=', ScrollTicks * 1000 div TStopwatch.Frequency);
    Writeln('TRACE footer fill phases begin_ms=', FillTicks[0] * 1000 div TStopwatch.Frequency,
      ' clear_ms=', FillTicks[1] * 1000 div TStopwatch.Frequency,
      ' labels_ms=', FillTicks[2] * 1000 div TStopwatch.Frequency,
      ' annotation_ms=', FillTicks[3] * 1000 div TStopwatch.Frequency,
      ' cover_ms=', FillTicks[4] * 1000 div TStopwatch.Frequency,
      ' action_ms=', FillTicks[5] * 1000 div TStopwatch.Frequency,
      ' endupdate_ms=', FillTicks[6] * 1000 div TStopwatch.Frequency);
    Flush(Output);
  end;

  procedure CheckFooter(const Scenario: string; Click: Boolean = True);
  var
    Button, GalleryButton: TButton;
    Ancestor: TWinControl;
    ButtonRect, ClipRect, CaptionRect: TRect;
    CaptionHeight: Integer;
    P: TPoint;
    OldClicks, K: Integer;
    Hit: HWND;
    LinkControl: TWinControl;
    LinkFont: TFont;
    Ideal: TSize;
    Detail: TControl;
  begin
    Button := Panel.DetailsButton;
    Context := Format('%s dark=%d dpi=%d client=%dx%d font=%d scroll=%d',
      [Scenario, Ord(Dark), DPI, Panel.ClientWidth, Panel.ClientHeight,
       Panel.Font.Size, Viewport.VertScrollBar.Position]);
    if Panel.Gallery.Visible then
    begin
      GalleryButton:=TButton(Panel.Gallery.FindComponent('GalleryToggle'));
      Require(Assigned(GalleryButton),Context+': gallery action missing');
      Bitmap.Canvas.Font.Assign(GalleryButton.Font);
      Require((GalleryButton.Font.PixelsPerInch=Panel.Font.PixelsPerInch) and
        (GalleryButton.Height>=MulDiv(28,DPI,96)) and
        (GalleryButton.Height>=Bitmap.Canvas.TextHeight('Wg')+MulDiv(8,DPI,96)) and
        (GalleryButton.Width>=Min(Panel.Gallery.ClientWidth,MulDiv(220,DPI,96))) and
        (GalleryButton.BoundsRect.Bottom<=Panel.Gallery.ClientHeight),
        Context+': gallery button retained monitor dimensions or clipped its scaled caption');
    end;
    Require(Button.Visible and Button.Enabled and IsWindowVisible(Button.Handle),
      Context + ': information action is not visibly enabled');
    Require(IsWindowVisible(Viewport.Handle) and IsWindowVisible(Content.Handle),
      Context + ': redraw restoration left a native metadata ancestor hidden');
    Require(not Viewport.AutoScroll and not Viewport.HorzScrollBar.Visible and
      (Viewport.ControlCount=1) and (Viewport.Controls[0]=Content),
      Context+': private viewport no longer has its explicit single-content range contract');
    Require((Viewport.VertScrollBar.Range=Content.Height) and
      (Content.Top=-Viewport.VertScrollBar.Position),
      Context+': final metadata scroll range or native content translation is stale');
    for K:=0 to Content.ControlCount-1 do
      if (Content.Controls[K] is TWinControl) and TWinControl(Content.Controls[K]).HandleAllocated then
        Require(IsWindowVisible(TWinControl(Content.Controls[K]).Handle)=Content.Controls[K].Visible,
          Context+': final native/logical visibility differs for '+Content.Controls[K].ClassName);
    // Hidden detail bounds may wait until display, but every public/native
    // switch must immediately provide a complete usable current viewport.
    for K:=0 to Content.ControlCount-1 do
    begin
      Detail:=Content.Controls[K];
      if Detail.Visible and ((Detail is TMemo) or (Detail is TListView)) then
        Require((Detail.Left=0) and (Detail.Width=Content.ClientWidth) and
          (Detail.Top>=0) and (Detail.Height>=0) and
          (Detail.Top+Detail.Height<=Content.ClientHeight),
          Context+': visible detail view kept stale deferred bounds');
    end;
    Require(Button.Parent = Panel, Context + ': action still scrolls with metadata');
    Require(GetWindowRect(Button.Handle, ButtonRect), Context + ': native button rectangle missing');
    Ancestor := Button.Parent;
    while Assigned(Ancestor) do
    begin
      ClipRect.TopLeft := Ancestor.ClientToScreen(Point(0, 0));
      ClipRect.BottomRight := Ancestor.ClientToScreen(Point(Ancestor.ClientWidth, Ancestor.ClientHeight));
      Require((ButtonRect.Left >= ClipRect.Left) and (ButtonRect.Top >= ClipRect.Top) and
        (ButtonRect.Right <= ClipRect.Right) and (ButtonRect.Bottom <= ClipRect.Bottom),
        Context + ': native information button is clipped by ' + Ancestor.ClassName +
        Format(' button=%d,%d,%d,%d clip=%d,%d,%d,%d',
          [ButtonRect.Left, ButtonRect.Top, ButtonRect.Right, ButtonRect.Bottom,
           ClipRect.Left, ClipRect.Top, ClipRect.Right, ClipRect.Bottom]));
      Ancestor := Ancestor.Parent;
    end;
    Require((Button.Left = Viewport.Left) and
      (Button.Left + Button.Width <= Viewport.Left + Viewport.Width) and
      (Viewport.Top + Viewport.Height <= Button.Top - MulDiv(8, DPI, 96)),
      Context + ': metadata viewport overlaps the fixed footer');
    Require(Button.Height >= MulDiv(32, DPI, 96), Context + ': footer target is too short at this DPI');
    Bitmap.Canvas.Font.Assign(Button.Font);
    Require((Button.Height >= Bitmap.Canvas.TextHeight('Wg') + MulDiv(8, DPI, 96)) and
      (Button.Width >= Bitmap.Canvas.TextWidth(Button.Caption) + MulDiv(16, DPI, 96)),
      Context + ': actual caption font is clipped');
    CaptionRect := Rect(0, 0, Button.Width - MulDiv(16, DPI, 96), 0);
    CaptionHeight := DrawText(Bitmap.Canvas.Handle, PChar(Button.Caption), Length(Button.Caption),
      CaptionRect, DT_CALCRECT or DT_SINGLELINE or DT_NOPREFIX);
    Require((CaptionHeight > 0) and (CaptionRect.Width <= Button.Width - MulDiv(16, DPI, 96)) and
      (CaptionRect.Height <= Button.Height - MulDiv(8, DPI, 96)),
      Context + ': native DrawText caption dimensions exceed the button');
    // Probe native child hit testing at all four corners and centre. A button
    // hidden by the scroll box could still pass a direct programmatic Click.
    for K := 0 to 4 do
    begin
      case K of
        0: P := Point(1, 1);
        1: P := Point(Button.Width - 2, 1);
        2: P := Point(1, Button.Height - 2);
        3: P := Point(Button.Width - 2, Button.Height - 2);
      else P := Point(Button.Width div 2, Button.Height div 2);
      end;
      P := Panel.ScreenToClient(Button.ClientToScreen(P));
      Hit := ChildWindowFromPointEx(Panel.Handle, P, CWP_SKIPINVISIBLE or CWP_SKIPDISABLED);
      Require(Hit = Button.Handle, Context + ': native button hit target is obscured');
    end;
    if Click then
    begin
      // The optimized layout must still refresh native link fonts and full
      // wrapped link heights after theme/DPI/font changes.
      for K := 0 to Content.ControlCount - 1 do
      begin
        if (Content.Controls[K] is TLabel) and Content.Controls[K].Visible and
          (fsBold in TLabel(Content.Controls[K]).Font.Style) then
          Require(TLabel(Content.Controls[K]).Font.Size=Panel.Font.Size,
            Context+': caption retained a stale logical font size');
        if (Content.Controls[K] is TWinControl) and
          ContainsText(Content.Controls[K].ClassName,'LinkLabel') and Content.Controls[K].Visible then
        begin
          LinkControl:=TWinControl(Content.Controls[K]);
          LinkFont:=TInfoFooterControlAccess(LinkControl).Font;
          Require((LinkFont.Size=Panel.Font.Size) and
            (HFONT(SendMessage(LinkControl.Handle,WM_GETFONT,0,0))=LinkFont.Handle),
            Context+': native link font does not match the chosen font');
          Ideal.cx:=0; Ideal.cy:=0;
          SendMessage(LinkControl.Handle,LM_GETIDEALSIZE,LinkControl.Width,LPARAM(@Ideal));
          Require((Ideal.cy<=LinkControl.Height) and
            (LinkControl.Top+LinkControl.Height<=Content.ClientHeight),
            Context+': optimized layout clipped a native wrapped link');
        end;
      end;
      OldClicks := Probe.Clicks;
      SendMessage(Button.Handle, BM_CLICK, 0, 0);
      Require(Probe.Clicks = OldClicks + 1, Context + ': native information click did not fire exactly once');
    end;
  end;

  procedure FillBook(Index: Integer; WithCover, HideCover, LongText: Boolean);
  begin
    if TraceCycling then PhaseStart := TStopwatch.GetTimeStamp;
    Panel.BeginUpdate;
    FillPhase(0);
    try
      Panel.Clear;
      FillPhase(1);
      Panel.SetBookInfo('Книга № ' + IntToStr(Index),
        '<a href="101">Автор ё</a>', '<a href="201">Серия (1)</a>', '<a href="sf">Фантастика</a>');
      Panel.SetReadingSupport('Можно читать во встроенной читалке');
      FillPhase(2);
      if LongText then
      begin
        Panel.SetBookAnnotationText(LongAnnotation);
        Panel.SetPreviewStatus('Дополнительные сведения книги с длинным описанием.');
        Panel.SetPublisherSeries('Основная издательская серия; ещё одна длинная серия для проверки переноса строки.');
      end
      else if Index mod 2 = 0 then Panel.SetBookAnnotationText('Короткая аннотация.')
      else Panel.SetBookAnnotationText('');
      FillPhase(3);
      if WithCover then Panel.SetBookCover(Bitmap) else Panel.SetBookCover(nil);
      Panel.ShowCover := not HideCover;
      FillPhase(4);
      Panel.DetailsButton.OnClick := Probe.Clicked;
      Panel.DetailsButton.Visible := True;
      FillPhase(5);
    finally Panel.EndUpdate; FillPhase(6); end;
  end;

  procedure CheckScroll(const Scenario: string);
  var Position: Integer;
  begin
    Require(Viewport.VertScrollBar.Range > Viewport.ClientHeight,
      Scenario + ': long metadata is not reachable through scrolling');
    GetWindowRect(Panel.DetailsButton.Handle, BeforeScrollRect);
    for Position in TArray<Integer>.Create(Viewport.VertScrollBar.Range,
      Viewport.VertScrollBar.Range div 2, 0) do
    begin
      Viewport.VertScrollBar.Position := Position;
      Application.ProcessMessages;
      CheckFooter(Scenario + ' scrolling');
      GetWindowRect(Panel.DetailsButton.Handle, FooterRect);
      Require(EqualRect(BeforeScrollRect, FooterRect), Scenario + ': scrolling moved the action');
    end;
  end;

  procedure DrainFooterCallbacks;
  var Pass: Integer;
  begin
    // CheckSynchronize services a snapshot. A style-engine removal callback can
    // ForceQueue another callback; drain that next snapshot before freeing the
    // current engine during a theme switch, including assertion unwinding.
    for Pass:=1 to 64 do if not CheckSynchronize(0) then Exit;
    raise Exception.Create('Footer VCL callback queue did not drain within64 snapshots');
  end;

  procedure CheckViewportBrush;
  var Reference: TScrollBox; WasVisible: Boolean; OldText: string;
    Expected, Actual: COLORREF;
    function Pixel(Control: TWinControl): COLORREF;
    var DC: HDC;
    begin
      RedrawWindow(Control.Handle,nil,0,RDW_INVALIDATE or RDW_ERASE or RDW_UPDATENOW);
      DC:=GetDC(Control.Handle);
      Require(DC<>0,'Viewport brush comparison lacks a real native DC');
      try Result:=GetPixel(DC,Max(0,Control.ClientWidth div 2),Max(0,Control.ClientHeight div 2));
      finally ReleaseDC(Control.Handle,DC); end;
      Require(Result<>CLR_INVALID,'Viewport brush comparison read outside its native client');
    end;
  begin
    Reference:=TScrollBox.Create(Host); WasVisible:=Content.Visible; OldText:=Annotation.Text;
    try
      Reference.Visible:=False; Reference.Parent:=Host;
      Reference.BorderStyle:=bsNone; Reference.StyleElements:=Viewport.StyleElements;
      Reference.Color:=Viewport.Color; Reference.HorzScrollBar.Visible:=False;
      Reference.SetBounds(MulDiv(8,DPI,96),Host.ClientHeight-MulDiv(40,DPI,96),
        MulDiv(80,DPI,96),MulDiv(24,DPI,96));
      Reference.Show; Content.Visible:=False; Application.ProcessMessages;
      Expected:=Pixel(Reference); Actual:=Pixel(Viewport);
      Require(Expected=Actual,'Optimized viewport client brush differs from the real stock ScrollBox style');
      Require(Annotation.Text=OldText,'Viewport brush comparison changed the retained annotation');
      Writeln('PASS viewport native client brush matches stock scroll box dark=',Ord(Dark),' dpi=',DPI);
      Flush(Output);
    finally
      Content.Visible:=WasVisible; Reference.Free;
      RedrawWindow(Panel.Handle,nil,0,RDW_INVALIDATE or RDW_ERASE or RDW_ALLCHILDREN or RDW_UPDATENOW);
      DrainFooterCallbacks;
    end;
  end;

  procedure CheckFocusReachability;
  var K, Attempts: Integer; Link: TWinControl; Target, Client, Intersection, Action: TRect;
    SavedText: string; MemoReached: Boolean;
    procedure CheckFocused(Control: TWinControl; const Description: string);
    begin
      Require(GetFocus=Control.Handle,Description+': native focus was not acquired');
      GetWindowRect(Control.Handle,Target);
      Client.TopLeft:=Viewport.ClientToScreen(Point(0,0));
      Client.BottomRight:=Viewport.ClientToScreen(Point(Viewport.ClientWidth,Viewport.ClientHeight));
      Require(IntersectRect(Intersection,Target,Client) and
        (Intersection.Height>=Min(Target.Height,Client.Height)),
        Description+': focused content remains hidden outside the metadata viewport');
      Require((Annotation.Text=SavedText) and not Viewport.AutoScroll,
        Description+': focus changed text or re-enabled redundant automatic range scans');
      GetWindowRect(Panel.DetailsButton.Handle,Target);
      Require(EqualRect(Target,Action),Description+': content focus moved the fixed action');
    end;
  begin
    FillBook(21,False,True,True); SavedText:=Annotation.Text;
    Viewport.VertScrollBar.Position:=0;
    GetWindowRect(Panel.DetailsButton.Handle,Action);
    Link:=nil;
    for K:=0 to Content.ControlCount-1 do
      if (Content.Controls[K] is TWinControl) and
        ContainsText(Content.Controls[K].ClassName,'LinkLabel') then
      begin Link:=TWinControl(Content.Controls[K]); Break; end;
    Require(Assigned(Link) and Link.CanFocus and Annotation.CanFocus,
      'Focus fixture lacks the actual keyboard-focusable author/memo controls');
    GetWindowRect(Annotation.Handle,Target);
    Client.BottomRight:=Viewport.ClientToScreen(Point(Viewport.ClientWidth,Viewport.ClientHeight));
    Require(Target.Top>=Client.BottomRight.Y,
      'Focus fixture did not begin with the annotation outside the viewport');
    Panel.DetailsButton.SetFocus;
    MemoReached:=False;
    for Attempts:=1 to Content.ControlCount+4 do
    begin
      // The actual form dialog-key route chooses its next tab-stop and performs
      // the installed VCL ancestor AutoScrollInView calls, not a direct scroll.
      Host.Perform(CM_DIALOGKEY,VK_TAB,0); Application.ProcessMessages;
      if GetFocus=Annotation.Handle then begin MemoReached:=True; Break; end;
    end;
    Require(MemoReached,'Tab navigation did not reach the real read-only annotation');
    CheckFocused(Annotation,'Tab focus to offscreen read-only annotation');
    Panel.DetailsButton.SetFocus;
    Viewport.VertScrollBar.Position:=Viewport.VertScrollBar.Range;
    Link.SetFocus; Application.ProcessMessages;
    CheckFocused(Link,'Focus to offscreen author link');
    Panel.DetailsButton.SetFocus;
    Viewport.VertScrollBar.Position:=0;
    CheckFooter('manual range after real keyboard focus');
    Writeln('PASS manual metadata range preserves actual Tab/memo/link focus scrolling dark=',Ord(Dark),' dpi=',DPI);
    Flush(Output);
  end;

  procedure CheckRangeClamp;
  var PreviousHeight, PreviousPosition: Integer; SavedText: string;
  begin
    PreviousHeight:=Panel.Height;
    try
      FillBook(20,False,True,True);
      SavedText:=Annotation.Text;
      Viewport.VertScrollBar.Position:=Viewport.VertScrollBar.Range;
      PreviousPosition:=Viewport.VertScrollBar.Position;
      Require(PreviousPosition>0,'Range-clamp fixture lacks an actual overflow position');
      CheckFooter('manual range before enlarged viewport');
      Panel.Height:=MulDiv(460,DPI,96);
      Application.ProcessMessages;
      Require((Viewport.VertScrollBar.Range<=Viewport.ClientHeight) and
        (Viewport.VertScrollBar.Position=0) and (Content.Top=0),
        'Enlarging the viewport failed to clamp its former nonzero scroll position');
      Require(Annotation.Text=SavedText,'Updating the explicit scroll range changed annotation text');
      CheckFooter('manual range after enlarged viewport');
      Writeln('PASS manual metadata extent keeps stock scrolling and clamps after viewport growth dark=',Ord(Dark),' dpi=',DPI);
      Flush(Output);
    finally
      Panel.Height:=PreviousHeight;
    end;
  end;

  procedure CheckOpaqueBackdrop;
  var P: TPoint; K, Y, OldPosition: Integer; Occupied, Found: Boolean;
    Expected, Actual: array[0..7] of COLORREF;
    SavedAnnotation, SavedStatus: string; Native: TRect;
    procedure Capture(var Pixels: array of COLORREF);
    var DC: HDC; N: Integer;
    begin
      // This explicit paint is a visual-equivalence oracle before the timing
      // loop, separate from CheckFinalNativePaint's production-invalidations gate.
      RedrawWindow(Panel.Handle,nil,0,
        RDW_INVALIDATE or RDW_ERASE or RDW_ALLCHILDREN or RDW_UPDATENOW);
      DC:=GetDC(Content.Handle);
      Require(DC<>0,'Opaque backdrop lacks its actual native client DC');
      try
        for N:=0 to High(Pixels) do
        begin
          Pixels[N]:=GetPixel(DC,P.X+N,P.Y);
          Require(Pixels[N]<>CLR_INVALID,'Opaque backdrop pixel is outside the native client');
        end;
      finally ReleaseDC(Content.Handle,DC); end;
    end;
  begin
    SavedAnnotation:=Annotation.Text; SavedStatus:=Panel.PreviewStatusText;
    OldPosition:=Viewport.VertScrollBar.Position;
    try
      // Find a genuine uncovered metadata gap rather than sampling a label or
      // memo background, whose own paint could hide a changed parent colour.
      P.X:=Max(0,(Content.ClientWidth-8) div 2); Found:=False;
      for Y:=0 to Max(0,Annotation.Top-1) do
      begin
        P.Y:=Y; Occupied:=False;
        for K:=0 to Content.ControlCount-1 do
          if Content.Controls[K].Visible and PtInRect(Content.Controls[K].BoundsRect,P) then
          begin Occupied:=True; Break; end;
        if not Occupied then begin Found:=True; Break; end;
      end;
      Require(Found,'Opaque backdrop oracle found no uncovered metadata gap');
      Viewport.VertScrollBar.Position:=Max(0,P.Y-Viewport.ClientHeight div 2);
      Application.ProcessMessages;
      Require(GetWindowRect(Viewport.Handle,Native) and
        PtInRect(Native,Content.ClientToScreen(P)),
        'Opaque backdrop sample is not actually visible inside the viewport');
      TPanel(Content).ParentBackground:=True;
      Capture(Expected);
      TPanel(Content).ParentBackground:=False;
      Capture(Actual);
      for K:=0 to High(Expected) do
        Require(Expected[K]=Actual[K],
          'Opaque metadata background changed its actual light/dark native colour');
      Require((Annotation.Text=SavedAnnotation) and (Panel.PreviewStatusText=SavedStatus),
        'Opaque background comparison changed the retained book text');
      Writeln('PASS opaque metadata backdrop matches legacy parent background dark=',Ord(Dark),' dpi=',DPI);
      Flush(Output);
    finally
      TPanel(Content).ParentBackground:=False;
      Viewport.VertScrollBar.Position:=OldPosition;
    end;
  end;

  procedure CheckFinalNativePaint;
  const PaintedText='Видимый текст после пакета ё 😀';
  var Before, After: TBitmap; DC: HDC; R: TRect; X,Y,Changed,W,H: Integer;
    LeftPixel,RightPixel: PCardinal; SavedText: string;
    procedure Capture(Target: TBitmap);
    begin
      Target.PixelFormat:=pf32bit; Target.SetSize(W,H);
      DC:=GetDC(Annotation.Handle);
      Require(DC<>0,'Native annotation paint capture lacks its actual client DC');
      try Require(BitBlt(Target.Canvas.Handle,0,0,W,H,DC,0,0,SRCCOPY),
        'Native annotation paint capture failed');
      finally ReleaseDC(Annotation.Handle,DC); end;
    end;
  begin
    SavedText:=Annotation.Text;
    Before:=TBitmap.Create; After:=TBitmap.Create;
    try
      W:=Min(MulDiv(300,DPI,96),Annotation.ClientWidth-2*GetSystemMetrics(SM_CXVSCROLL));
      H:=Min(MulDiv(60,DPI,96),Annotation.ClientHeight);
      Require((W>=32) and (H>=24),'Native paint oracle lacks a visible useful annotation area');
      Panel.SetBookAnnotationText('');
      RedrawWindow(Panel.Handle,nil,0,RDW_INVALIDATE or RDW_ERASE or RDW_FRAME or RDW_ALLCHILDREN or RDW_UPDATENOW);
      Capture(Before);
      Panel.BeginUpdate;
      try
        Panel.SetBookAnnotationText(PaintedText);
        InvalidateRect(Viewport.Handle,nil,True);
        UpdateWindow(Viewport.Handle);
        Require(not GetUpdateRect(Viewport.Handle,R,False),
          'Deferred viewport paint leaves a repeating invalid update region');
        InvalidateRect(Annotation.Handle,nil,True);
        UpdateWindow(Annotation.Handle);
        Require(not GetUpdateRect(Annotation.Handle,R,False),
          'Deferred annotation paint leaves a repeating invalid update region');
      finally Panel.EndUpdate; end;
      // Flush only regions invalidated by the actual production EndUpdate.
      // Creating a new invalidation here would mask a missing final redraw.
      RedrawWindow(Panel.Handle,nil,0,RDW_ALLCHILDREN or RDW_UPDATENOW);
      Capture(After);
      Changed:=0;
      for Y:=0 to H-1 do
      begin
        LeftPixel:=Before.ScanLine[Y]; RightPixel:=After.ScanLine[Y];
        for X:=0 to W-1 do
        begin
          if (LeftPixel^ and $00FFFFFF)<>(RightPixel^ and $00FFFFFF) then Inc(Changed);
          Inc(LeftPixel); Inc(RightPixel);
        end;
      end;
      Require((Annotation.Text=PaintedText) and (Changed>8),
        'Outer EndUpdate retained stale actual native annotation pixels/text');
      Writeln('TRACE footer native final paint dark=',Ord(Dark),' dpi=',DPI,' changed_pixels=',Changed);
      Flush(Output);
      Panel.SetBookAnnotationText(SavedText);
      RedrawWindow(Panel.Handle,nil,0,RDW_INVALIDATE or RDW_ERASE or RDW_FRAME or RDW_ALLCHILDREN or RDW_UPDATENOW);
    finally After.Free; Before.Free; end;
  end;

  procedure CheckBatchedTextAndVisibility;
  const
    FinalAnnotation='Итоговая мысль ё 😀'+#13#10+'Вторая строка.';
    FinalAuthor='<a href="101">Итоговый автор ё</a>';
  var I, OldAuthorHeight, OldAuthorWidth, FinalAuthorHeight: Integer; Author: TWinControl; Items: TListView; Text, ActualAuthor, ActualAnnotation, LongAuthor: string;
    XMLStream: TStringStream; XMLBook: IXMLFictionBook;
    procedure TraceText(const LabelText, Actual, Expected: string);
    var K: Integer; ActualHex, ExpectedHex: string;
    begin
      ActualHex:=''; ExpectedHex:='';
      for K:=1 to Min(Length(Actual),200) do ActualHex:=ActualHex+IntToHex(Ord(Actual[K]),4);
      for K:=1 to Min(Length(Expected),200) do ExpectedHex:=ExpectedHex+IntToHex(Ord(Expected[K]),4);
      Writeln('TRACE footer nested ',LabelText,' actual_len=',Length(Actual),' expected_len=',Length(Expected),
        ' actual_utf16=',ActualHex,' expected_utf16=',ExpectedHex); Flush(Output);
    end;
    function WindowText(Control: TWinControl): string;
    var Capacity, Copied, K: Integer;
    begin
      // nMaxCount includes the UTF-16 terminator; the Pascal result does not.
      // SysLink's WM_GETTEXT may report that terminal unit in its count. Bound
      // the copied text to the buffer and remove only an actual terminal NUL,
      // never whitespace, CRLF, a surrogate, or another visible character.
      Capacity:=GetWindowTextLength(Control.Handle)+1;
      SetLength(Result,Capacity);
      Copied:=GetWindowText(Control.Handle,PChar(Result),Capacity);
      Copied:=Min(Max(0,Copied),Capacity-1);
      for K:=1 to Copied do
        if Result[K]=#0 then begin Copied:=K-1; Break; end;
      SetLength(Result,Copied);
    end;
  begin
    Author:=nil; Items:=nil;
    for I:=0 to Content.ControlCount-1 do
    begin
      if (Content.Controls[I] is TWinControl) and
        ContainsText(Content.Controls[I].ClassName,'LinkLabel') and
        ContainsText(WindowText(TWinControl(Content.Controls[I])),'href="101"') then
        Author:=TWinControl(Content.Controls[I]);
      if Content.Controls[I] is TListView then Items:=TListView(Content.Controls[I]);
    end;
    Require(Assigned(Author) and Assigned(Items),'Batch test lacks actual author/structured controls');
    Require(WindowText(Author)='<a href="101">Автор ё</a>',
      'Bounded native text helper changed the existing unbatched author markup');
    Panel.SetBookInfo('Unbatched UTF16 control',
      '  <a href="101">Вне пакета ё 😀</a>  ','<a href="201">Новая серия</a>','<a href="sf">Фантастика</a>');
    Require(WindowText(Author)='  <a href="101">Вне пакета ё 😀</a>  ',
      'Bounded native text helper trimmed whitespace or changed unbatched Unicode');
    Panel.BeginUpdate;
    try
      Panel.Clear;
      Require(not Panel.DetailsButton.Visible,'Batched Clear did not update logical action visibility');
      Panel.BeginUpdate;
      try
        Panel.SetBookInfo('Итоговое название',FinalAuthor,'<a href="201">Новая серия</a>','<a href="sf">Фантастика</a>');
        Panel.SetBookAnnotationText('Intermediate annotation must not survive');
        Panel.SetBookAnnotationText(FinalAnnotation);
        Panel.SetPreviewStatus('Итоговое состояние');
        Require(Panel.PreviewStatusText='Итоговое состояние','Batched public status getter is stale');
        Panel.DetailsButton.Visible:=True;
        Require(Panel.DetailsButton.Visible,'Nested batch lost final logical action visibility');
      finally Panel.EndUpdate; end;
    finally Panel.EndUpdate; end;
    ActualAuthor:=WindowText(Author); ActualAnnotation:=Annotation.Text;
    TraceText('author',ActualAuthor,FinalAuthor);
    TraceText('annotation',ActualAnnotation,FinalAnnotation);
    Require((ActualAuthor=FinalAuthor) and (ActualAnnotation=FinalAnnotation),
      'Nested book update lost final native author/annotation text');
    CheckFooter('nested batch final text and visibility');
    Panel.BeginUpdate;
    try Panel.InfoPriority:=True;
    finally Panel.EndUpdate; end;
    Require(not IsWindowVisible(Annotation.Handle) and IsWindowVisible(Items.Handle),
      'Outer redraw restoration showed the annotation hidden by a batch');
    CheckFooter('batch switches to structured information');
    Panel.BeginUpdate;
    try Panel.InfoPriority:=False;
    finally Panel.EndUpdate; end;
    Require(IsWindowVisible(Annotation.Handle) and not IsWindowVisible(Items.Handle) and
      (Annotation.Text=FinalAnnotation),
      'Outer redraw restoration lost the restored annotation or hidden structured state');
    CheckFooter('batch restores annotation');
    CheckViewportBrush;
    CheckOpaqueBackdrop;
    CheckFinalNativePaint;
    // Reuse the same wrapping width while changing only the exact link text.
    // A width-only height cache would incorrectly retain the single-line row.
    FinalAuthorHeight:=Author.Height;
    Panel.BeginUpdate;
    try
      Panel.SetBookInfo('Same-width full-row baseline',
        '<a href="101">'+StringOfChar('W',500)+'</a>',
        '<a href="201">Новая серия</a>','<a href="sf">Фантастика</a>');
    finally Panel.EndUpdate; end;
    OldAuthorHeight:=Author.Height; OldAuthorWidth:=Author.Width;
    Require(OldAuthorWidth=Content.ClientWidth,'Same-width cache baseline must fill its available row');
    LongAuthor:='';
    for I:=1 to 200 do LongAuthor:=LongAuthor+'Автор ё ';
    Panel.BeginUpdate;
    try
      Panel.SetBookInfo('Same-width link cache change',
        '<a href="101">'+LongAuthor+'</a>',
        '<a href="201">Новая серия</a>','<a href="sf">Фантастика</a>');
    finally Panel.EndUpdate; end;
    CheckFooter('same-width changed author caption');
    Writeln('TRACE footer same-width author old=',OldAuthorWidth,'x',OldAuthorHeight,
      ' new=',Author.Width,'x',Author.Height,' client=',Content.ClientWidth);
    Require((Author.Width=OldAuthorWidth) and (Author.Height>OldAuthorHeight),
      'Changed author text reused a stale height at the same wrapping width');
    Panel.BeginUpdate;
    try Panel.SetBookInfo('Итоговое название',FinalAuthor,
      '<a href="201">Новая серия</a>','<a href="sf">Фантастика</a>');
    finally Panel.EndUpdate; end;
    Require(Author.Height=FinalAuthorHeight,
      'Restoring author text did not restore its exact native row height');
    CheckFooter('same-width author caption restored');

    Text:=StringReplace(FB2,'</book-title>',
      '</book-title><annotation><p>XML первая строка ё</p><p>XML вторая строка.</p></annotation>',[]);
    XMLStream:=TStringStream.Create(Text,TEncoding.UTF8);
    try XMLBook:=FictionBook_21.LoadFictionBook(XMLStream);
      Panel.BeginUpdate;
      try
        Panel.Clear;
        Panel.SetBookInfo('XML final title',FinalAuthor,'<a href="201">Новая серия</a>','<a href="sf">Фантастика</a>');
        Panel.SetBookAnnotation(XMLBook);
        Panel.DetailsButton.Visible:=True;
      finally Panel.EndUpdate; end;
      Require((Annotation.Lines.Count=2) and (Annotation.Lines[0]='XML первая строка ё') and
        (Annotation.Lines[1]='XML вторая строка.'),'Queued Clear overwrote XML annotation paragraphs');
    finally XMLBook:=nil; XMLStream.Free; end;
    CheckFooter('batched XML description');

    Items.Items.Add.Caption:='Retained temporary visible metadata';
    Panel.BeginUpdate;
    try Panel.Clear;
    finally Panel.EndUpdate; end;
    Require(not Panel.DetailsButton.Visible and not IsWindowVisible(Panel.DetailsButton.Handle) and
      (WindowText(Author)='') and (Annotation.Text='') and (Items.Items.Count=0) and
      (Panel.PreviewStatusText=''),'Clear-only batch left stale native text/action/items');
    FillBook(4,False,False,False);
    CheckFooter('clear-only batch refill');
  end;

  procedure CheckSingleViewportResize;
  var Sizes: TInfoFooterMessageProbe; OldBounds: TRect;
    OldFontSize, ShortWidth: Integer; OldCaption: string;
  begin
    OldBounds:=Panel.BoundsRect; OldFontSize:=Panel.Font.Size;
    OldCaption:=Panel.DetailsButton.Caption;
    try
      Panel.Font.Size:=14;
      Panel.SetBounds(OldBounds.Left,OldBounds.Top,MulDiv(460,DPI,96),MulDiv(460,DPI,96));
      FillBook(23,True,True,True);
      Panel.DetailsButton.Visible:=False;
      Panel.DetailsButton.Caption:='Информация о выбранной книге';
      Sizes:=TInfoFooterMessageProbe.CreateFor(Viewport,'batch viewport');
      try
        Sizes.Active:=True;
        Panel.BeginUpdate;
        try
          Panel.ShowCover:=True;
          Panel.DetailsButton.Visible:=True;
        finally Panel.EndUpdate; end;
        Sizes.Active:=False;
        Require(Sizes.SizeBoundsChanges=1,
          'Book batch resized the native viewport through intermediate cover/footer bounds: '+
          IntToStr(Sizes.SizeBoundsChanges));
      finally Sizes.Free; end;
      CheckFooter('single final viewport resize');
      Panel.DetailsButton.Caption:='Книга';
      ShortWidth:=Panel.DetailsButton.Width;
      Panel.DetailsButton.Caption:='Информация о выбранной книге';
      Require(Panel.DetailsButton.Width>ShortWidth,
        'Visible action caption changed without updating its reserved width');
      CheckFooter('visible action caption changed without resize');
      Require(Annotation.Text=LongAnnotation,
        'Preparing final cover/footer bounds changed the retained annotation');
      Writeln('PASS book batch applies one final native viewport size dark=',Ord(Dark),' dpi=',DPI);
      Flush(Output);
    finally
      Panel.DetailsButton.Caption:=OldCaption;
      Panel.Font.Size:=OldFontSize;
      Panel.BoundsRect:=OldBounds;
    end;
  end;

  procedure WaitGallery;
  var Start: UInt64;
  begin
    Start := GetTickCount64;
    while Panel.Gallery.Loading and (GetTickCount64 - Start < 10000) do
    begin Application.ProcessMessages; CheckSynchronize(10); end;
    Require(not Panel.Gallery.Loading, 'Footer fixture gallery failed to finish');
  end;

begin
  RequireIsolatedRegression;
  TraceCycling := False; CompletedCases := 0; SlowCases := 0;
  PerformanceSummary := ''; SlowSummary := '';
  Require(TPath.GetFullPath(Settings.AppPath).StartsWith('G:\', True), 'Footer gate must stay in private G');
  Root := TPath.Combine(Settings.AppPath, 'book-preview-layout-' + TGUID.NewGuid.ToString);
  ForceDirectories(Root);
  SourceFile := TPath.Combine(Root, 'preview-source.fb2');
  TFile.WriteAllText(SourceFile, FB2, TEncoding.UTF8);
  SourceHash := THashSHA2.GetHashStringFromFile(SourceFile);
  SettingsHash := '';
  if FileExists(Settings.SettingsFileName) then
    SettingsHash := THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
  LongAnnotation := '';
  for I := 1 to 120 do LongAnnotation := LongAnnotation + 'Строка аннотации № ' + IntToStr(I) + ' — ё, ї, ў.' + sLineBreak;
  OriginalTheme := MHLThemeDark;
  Bitmap := TBitmap.Create;
  try
    Bitmap.SetSize(64, 96);
    Bitmap.Canvas.Brush.Color := clNavy;
    Bitmap.Canvas.FillRect(Rect(0, 0, 64, 96));
    for Dark in TArray<Boolean>.Create(False, True) do
    begin
      // Flush deferred style-engine updates while their dictionary still lives.
      // A later theme teardown must not strand an old ForceQueue callback.
      DrainFooterCallbacks;
      SetMHLTheme(Dark);
      DrainFooterCallbacks;
      for DPI in TArray<Integer>.Create(96, 144, 192) do
      begin
        Host := TForm.CreateNew(nil);
        Profiles := nil;
        Probe := TInfoFooterClickProbe.Create;
        try
          Host.Caption := 'HomeLib Ru — проверка панели книги';
          Host.AutoScroll := False;
          Host.Font.Name := 'Segoe UI';
          Host.Font.Size := 9;
          Host.SetBounds(60, 60, 840, 560);
          Panel := TInfoPanel.Create(Host);
          Panel.Parent := Host;
          Panel.SetBounds(8, 8, 790, 150);
          Viewport := InfoFooterViewport(Panel);
          Require(Assigned(Viewport), 'Footer fixture lacks the real scrolling viewport');
          Content := InfoFooterContent(Viewport);
          Require(Assigned(Content), 'Footer fixture lacks the real metadata content');
          Require(not TPanel(Content).ParentBackground and
            (csOpaque in TInfoFooterControlAccess(Content).ControlStyle),
            'Solid metadata content lost its opaque native background contract');
          Cover := nil;
          for I := 0 to Panel.ControlCount - 1 do
            if Panel.Controls[I] is TImage then Cover := TImage(Panel.Controls[I]);
          Require(Assigned(Cover), 'Footer fixture lacks the real cover image');
          Annotation := nil;
          for I := 0 to Content.ControlCount - 1 do
            if Content.Controls[I] is TMemo then Annotation := TMemo(Content.Controls[I]);
          Require(Assigned(Annotation), 'Footer fixture lacks the real annotation control');
          Host.ScaleForPPI(DPI);
          Host.ClientWidth := MulDiv(820, DPI, 96);
          Host.ClientHeight := MulDiv(520, DPI, 96);
          Panel.SetBounds(MulDiv(8, DPI, 96), MulDiv(8, DPI, 96),
            MulDiv(790, DPI, 96), MulDiv(150, DPI, 96));
          ApplyMHLControlTheme(Host);
          Host.Show;
          Application.ProcessMessages;
          Panel.SetBookAnnotationText('Cached annotation ё');
          Annotation.Text:='External native text';
          Panel.SetBookAnnotationText('Cached annotation ё');
          Require(Annotation.Text='Cached annotation ё','Annotation cache ignored external Text replacement');
          Annotation.Lines.Text:='External line replacement';
          Panel.SetBookAnnotationText('Cached annotation ё');
          Require(Annotation.Text='Cached annotation ё','Annotation cache ignored external Lines replacement');
          Annotation.Perform(CM_RECREATEWND,0,0);
          Panel.SetBookAnnotationText('Cached annotation ё');
          Require(Annotation.Text='Cached annotation ё','Annotation cache lost native handle restoration');
          Writeln('PASS annotation text cache preserves external Text Lines and native handle restoration dark=',Ord(Dark),' dpi=',DPI);
          FillBook(1, False, False, False);
          CheckFooter('minimum-height/no annotation/no cover');
          CheckScroll('minimum-height/no annotation');
          FillBook(2, False, True, False);
          CheckFooter('minimum-height/short annotation/cover hidden');
          AnnotationBefore := Annotation.Lines.Text;
          Panel.ShowAnnotation := False;
          Require(Panel.Constraints.MinHeight >= MulDiv(80, DPI, 96),
            'Compact preview minimum height lost its actual DPI scaling');
          Panel.Height := Panel.Constraints.MinHeight;
          CheckFooter('compact actual annotation hidden/minimum constraint');
          Require(Viewport.ClientHeight >= MulDiv(20, DPI, 96),
            'Compact hidden annotation leaves no useful metadata viewport');
          Require(Annotation.Lines.Text = AnnotationBefore,
            'Hiding annotation changed the retained annotation text');
          Panel.ShowAnnotation := True;
          Require((Panel.Constraints.MinHeight >= MulDiv(150, DPI, 96)) and
            (Annotation.Lines.Text = AnnotationBefore),
            'Restoring annotation lost scaled minimum height or text');
          Panel.Height := MulDiv(230, DPI, 96);
          FillBook(3, True, False, True);
          CheckFooter('long annotation/cover');
          CheckScroll('long annotation/cover');
          Panel.Width := MulDiv(460, DPI, 96);
          CheckFooter('narrow preview');
          Panel.InfoPriority := True;
          CheckFooter('structured information');
          Panel.InfoPriority := False;
          CheckFooter('annotation restored');
          OriginalFontSize := Panel.Font.Size;
          Panel.Font.Size := OriginalFontSize + 5;
          CheckFooter('larger actual font');
          Panel.Font.Size := OriginalFontSize;
          Panel.Height := MulDiv(460, DPI, 96);
          CheckFooter('height increased');
          Panel.Font.Size := 14;
          CheckFooter('combined tall/narrow/cover/font14');
          Require(Panel.ShowCover and Cover.Visible and Assigned(Cover.Picture.Graphic) and
            Cover.Proportional and Cover.Center and Cover.Stretch,
            'Combined capacity case hid or distorted the cover');
          Require((Cover.Height = Panel.ClientHeight - Cover.Margins.Top - Cover.Margins.Bottom) and
            (Cover.Width < Cover.Height * 2 div 3),
            'Combined capacity case changed cover height or did not reserve actual caption capacity');
          Panel.Font.Size := OriginalFontSize;
          CheckFooter('combined capacity restored font');
          // The public visibility setter must immediately restore useful text
          // height even without a subsequent book-selection/layout callback.
          VisibleHeight := Viewport.Height;
          Panel.DetailsButton.Visible := False;
          HiddenHeight := Viewport.Height;
          Require(HiddenHeight > VisibleHeight, 'Hidden footer failed to restore the text viewport');
          Panel.DetailsButton.Visible := True;
          Require(Viewport.Height = VisibleHeight, 'Visible footer did not restore its exact reservation');
          CheckFooter('public visibility setter');
          CheckBatchedTextAndVisibility;
          CheckSingleViewportResize;
          Panel.Height := MulDiv(150, DPI, 96);
          Panel.Width := MulDiv(790, DPI, 96);
          Panel.Gallery.PreviewSettingsFile := TPath.Combine(Root, 'gallery-window.ini');
          Panel.Gallery.SetBook('footer-' + IntToStr(Ord(Dark)) + '-' + IntToStr(DPI), '.fb2',
            function: TStream
            begin Result := TFileStream.Create(SourceFile, fmOpenRead or fmShareDenyWrite); end);
          CheckFooter('gallery collapsed');
          Panel.Gallery.Expanded := True;
          WaitGallery;
          Require(Panel.Gallery.Expanded, 'Gallery did not expand');
          CheckFooter('gallery expanded');
          CheckScroll('gallery expanded');
          SavedScroll := Viewport.VertScrollBar.Range div 2;
          Viewport.VertScrollBar.Position := SavedScroll;
          Panel.Gallery.Expanded := False;
          CheckFooter('gallery collapsed after scroll');
          CheckRangeClamp;
          CheckFocusReachability;
          Profiles:=TObjectList<TInfoFooterMessageProbe>.Create(True);
          var ProfileMessages:=True;
          {$IFDEF MHL_RELEASE_PERFORMANCE}
          // Keep the original diagnostic run available as the "profile" subcase.
          // Release measurements use native controls without test-only WndProc
          // timers. The same 100 transitions, geometry checks and 5s guard run.
          ProfileMessages:=ParamStr(2)='profile';
          {$ENDIF}
          if ProfileMessages then
          begin
            InfoFooterHookControls(Panel,Profiles);
            for Profile in Profiles do Profile.Active:=True;
            TInfoFooterPanelAccess(Panel).LayoutProfile:=Probe.LayoutStage;
            Probe.ActiveLayout:=True;
          end;
          Writeln('PROFILE footer observation_hooks=',Ord(ProfileMessages));
          FillChar(FillTicks, SizeOf(FillTicks), 0);
          CheckTicks := 0; ScrollTicks := 0; TraceCycling := True;
          Writeln('TRACE footer cycling start dark=', Ord(Dark), ' dpi=', DPI);
          Flush(Output);
          Started := TStopwatch.StartNew;
          for J := 1 to 100 do
          begin
            FillBook(J, J mod 3 = 0, J mod 4 = 0, J mod 5 = 0);
            PhaseStart := TStopwatch.GetTimeStamp;
            Require(Viewport.VertScrollBar.Position = 0, 'New book failed to reset only its metadata scroll');
            CheckFooter('fast book selection ' + IntToStr(J), False);
            Inc(CheckTicks, TStopwatch.GetTimeStamp - PhaseStart);
            PhaseStart := TStopwatch.GetTimeStamp;
            Viewport.VertScrollBar.Position := Viewport.VertScrollBar.Range;
            Inc(ScrollTicks, TStopwatch.GetTimeStamp - PhaseStart);
            if (J = 1) or (J mod 25 = 0) then TraceCycle(J);
          end;
          Started.Stop;
          TraceCycling := False;
          for Profile in Profiles do Profile.Active:=False;
          Probe.ActiveLayout:=False;
          TInfoFooterPanelAccess(Panel).LayoutProfile:=nil;
          TraceCycle(100);
          // Inclusive parent/child timings are diagnostic, not additive: one
          // native paint/layout message can synchronously dispatch another.
          for Profile in Profiles do Profile.Dump;
          Probe.DumpLayout;
          Flush(Output);
          FreeAndNil(Profiles);
          CyclingMS := Started.ElapsedMilliseconds;
          PerformanceSummary := PerformanceSummary + Format(' dark=%d dpi=%d cycling_ms=%d;',
            [Ord(Dark), DPI, CyclingMS]);
          // Preserve the original strict <5000 ms predicate, but defer only
          // its failure until every theme/DPI geometry scenario has finished.
          if CyclingMS >= 5000 then
          begin
            Inc(SlowCases);
            SlowSummary := SlowSummary + Format(' dark=%d dpi=%d: %d ms;',
              [Ord(Dark), DPI, CyclingMS]);
          end;
          CheckFooter('after fast selection cycle');
          Panel.Clear;
          Require(not Panel.DetailsButton.Visible and (Viewport.VertScrollBar.Position = 0),
            'Clear retained an action for an unselected book or a stale scroll position');
          FillBook(101, False, False, False);
          CheckFooter('clear/refill');
          Snapshot := Host.GetFormImage;
          Png := TPngImage.Create;
          try
            Png.Assign(Snapshot);
            Png.SaveToFile(TPath.Combine(Root, Format('footer-dark-%d-dpi-%d.png', [Ord(Dark), DPI])));
          finally Png.Free; Snapshot.Free; end;
          Inc(CompletedCases);
          Writeln('PASS fixed information footer dark=', Ord(Dark), ' dpi=', DPI,
            ' clicks=', Probe.Clicks, ' cycling_ms=', CyclingMS,
            ' geometry_only=1 speed_budget_exceeded=', Ord(CyclingMS >= 5000));
          Flush(Output);
        finally
          Profiles.Free;
          // Keep the probe and current style engine alive through pending VCL
          // callbacks, then drain component-removal notifications before switch.
          Writeln('TRACE footer teardown before callback drain dark=',Ord(Dark),' dpi=',DPI); Flush(Output);
          DrainFooterCallbacks;
          Writeln('TRACE footer teardown before host free'); Flush(Output);
          Host.Free; Probe.Free;
          Writeln('TRACE footer teardown before final callback drain'); Flush(Output);
          DrainFooterCallbacks;
          Writeln('TRACE footer teardown complete'); Flush(Output);
        end;
      end;
    end;
    Require(THashSHA2.GetHashStringFromFile(SourceFile) = SourceHash, 'Preview layout changed source book bytes');
    if SettingsHash <> '' then
      Require(THashSHA2.GetHashStringFromFile(Settings.SettingsFileName) = SettingsHash,
        'Preview layout changed active settings/profile');
    Writeln('PASS source bytes/profile preserved; short/long/cover/gallery/scroll/DPI/native click/cycling checked');
    Flush(Output);
  finally
    try
      Writeln('TRACE footer restore theme before drain'); Flush(Output);
      DrainFooterCallbacks;
      SetMHLTheme(OriginalTheme);
      DrainFooterCallbacks;
      Writeln('TRACE footer restore theme complete'); Flush(Output);
    finally Bitmap.Free; end;
  end;
  // This marker appears only after the complete strict geometry/profile
  // sweep and teardown. An early assertion cannot be mistaken for six cases.
  Require(CompletedCases = 6, 'Footer geometry sweep did not complete all six theme/DPI cases');
  Writeln('GEOMETRY_SWEEP_COMPLETE fixed information footer cases=', CompletedCases,
    ' speed_budget_exceeded=', SlowCases, ' strict_budget_ms=5000');
  Writeln('PROFILE footer cycling summary', PerformanceSummary);
  Flush(Output);
  Require(SlowCases = 0, 'Footer layout made 100 book selections unexpectedly slow: ' + SlowSummary);
end;
