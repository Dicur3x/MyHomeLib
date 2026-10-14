// Fresh actual Search startup is measured before any fixture-issued scaling,
// realignment, focus or scrolling command; those could mask initial clipping.
var SLSProtectedPreferences: string; SLSOriginalDialogs: Boolean;

function SLSOtherPreferences: string;
begin
  Result:=Format('%s|%d|%d|%d|%d|%d|%d|%d|%s|%s|%s',[
    Settings.Locale,Ord(Settings.CheckUpdate),Ord(Settings.CheckExternalLibUpdate),
    Ord(Settings.AutoStartDwnld),Ord(Settings.OverwriteFB2Info),
    Ord(Settings.HideDeletedBooks),Settings.ActiveCollection,Settings.BookCacheLimitMB,
    Settings.TempDir,Settings.DeviceDir,Settings.ReadDir]);
end;

// Parent calls after its tiny catalog/preferences setup, BEFORE actual Main creation.
procedure PrepareSearchStartupLayout;
begin
  RequireIsolatedRegression;
  Require(Settings.AppPath.StartsWith('G:\',True),'Search startup fixture must use its private G profile');
  SLSProtectedPreferences:=SLSOtherPreferences;
  SLSOriginalDialogs:=Vcl.Dialogs.UseLatestCommonDialogs;
  Settings.ActivePage:=PAGE_SEARCH;
  Settings.WindowState:=Ord(wsNormal); Settings.FormWidth:=1150; Settings.FormHeight:=850;
  Settings.FormLeft:=0; Settings.FormTop:=0;
  Settings.ShowInfoPanel:=False; Settings.ShowBookCover:=False; Settings.ShowBookAnnotation:=False;
  Settings.BookSRCollapsed:=False; Settings.FileSRCollapsed:=False; Settings.OtherSRCollapsed:=False;
  Settings.TreeFontSize:=9; Settings.ShortFontSize:=9;
  Settings.ShowToolbar:=True; Settings.ShowStatusBar:=True;
  Settings.ShowRusBar:=True; Settings.ShowEngBar:=True; Settings.EditToolBarVisible:=False;
  Settings.DarkTheme:=False; Settings.WindowsDarkThemeOfferDismissed:=True;
  Settings.Splitters[3]:=250;
  Writeln('TRACE search startup prepared page3/normal1150x850/expanded/cover0/font9 before Main construction'); Flush(Output);
end;

function SLSRectText(const Value: TRect): string;
begin Result:=Format('[%d,%d,%d,%d]',[Value.Left,Value.Top,Value.Right,Value.Bottom]); end;

function SLSHasNativeOrigin(Control: TControl): Boolean;
var Parent: TWinControl;
begin
  if Control is TWinControl then Exit(TWinControl(Control).HandleAllocated);
  Parent:=Control.Parent; Result:=Assigned(Parent) and Parent.HandleAllocated;
end;

function SLSBoundsOnScreen(Control: TControl): TRect;
begin
  Require(Assigned(Control.Parent) and SLSHasNativeOrigin(Control.Parent),
    'Search viewport measurement would create a previously absent parent handle');
  Result.TopLeft:=Control.Parent.ClientToScreen(Control.BoundsRect.TopLeft);
  Result.BottomRight:=Control.Parent.ClientToScreen(Control.BoundsRect.BottomRight);
end;

function SLSClientOnScreen(Control: TWinControl): TRect;
begin
  Require(Control.HandleAllocated,'Search client measurement would create a previously absent handle');
  Result.TopLeft:=Control.ClientToScreen(Control.ClientRect.TopLeft);
  Result.BottomRight:=Control.ClientToScreen(Control.ClientRect.BottomRight);
end;

procedure SLSTraceGeometry(const Stage: string);
var Parent: TWinControl; Origin: TPoint; Header: TRect; FocusName: string;

  procedure TraceControl(Control: TControl);
  var Client: TRect;
  begin
    Writeln('TRACE search startup ',Stage,' control=',Control.Name,' class=',Control.ClassName,
      ' parent=',Control.Parent.Name,' visible=',Ord(Control.Visible),' bounds=',SLSRectText(Control.BoundsRect),
      ' native_origin_available=',Ord(SLSHasNativeOrigin(Control)));
    if SLSHasNativeOrigin(Control) and SLSHasNativeOrigin(Control.Parent) then
    begin
      Origin:=Control.ClientOrigin;
      Writeln('TRACE search startup ',Stage,' control=',Control.Name,
        ' screen_bounds=',SLSRectText(SLSBoundsOnScreen(Control)),' client_origin=',Origin.X,',',Origin.Y);
      if Control is TWinControl then
      begin
        Client:=TWinControl(Control).ClientRect;
        Writeln('TRACE search startup ',Stage,' control=',Control.Name,' client_rect=',SLSRectText(Client),
          ' screen_client=',SLSRectText(SLSClientOnScreen(TWinControl(Control))));
      end;
    end;
  end;

begin
  FocusName:='<nil>'; if Assigned(frmMain.ActiveControl) then FocusName:=frmMain.ActiveControl.Name;
  Writeln('TRACE search startup ',Stage,' main_visible=',Ord(frmMain.Visible),
    ' main_handle_allocated=',Ord(frmMain.HandleAllocated),' active_page=',frmMain.pgControl.ActivePage.Name,
    ' active_control=',FocusName,' main_bounds=',SLSRectText(frmMain.BoundsRect),
    ' current_ppi=',frmMain.CurrentPPI,' font_ppi=',frmMain.Font.PixelsPerInch,
    ' group_scroll_pos=',frmMain.SearchParams.VertScrollBar.Position,
    ' group_scroll_range=',frmMain.SearchParams.VertScrollBar.Range,
    ' group_scroll_visible=',Ord(frmMain.SearchParams.VertScrollBar.Visible),
    ' group_header_height=',frmMain.SearchParams.HeaderHeight,
    ' book_collapsed=',Ord(frmMain.ctpBook.Collapsed),' other_collapsed=',Ord(frmMain.ctpOther.Collapsed),
    ' file_collapsed=',Ord(frmMain.ctpFile.Collapsed));
  for var Control in TArray<TControl>.Create(frmMain.pnSearchView,frmMain.SearchParams,frmMain.ctpBook,
    frmMain.Label5,frmMain.edFFullName,frmMain.Label24,frmMain.edFTitle) do TraceControl(Control);
  Parent:=frmMain.SearchParams.Parent;
  while Assigned(Parent) do
  begin
    if Parent.HandleAllocated then
      Writeln('TRACE search startup ',Stage,' ancestor=',Parent.Name,' class=',Parent.ClassName,
        ' visible=',Ord(Parent.Visible),' screen_client=',SLSRectText(SLSClientOnScreen(Parent)));
    Parent:=Parent.Parent;
  end;
  if SLSHasNativeOrigin(frmMain.ctpBook) and SLSHasNativeOrigin(frmMain.ctpBook.Parent) then
  begin
    Header:=SLSBoundsOnScreen(frmMain.ctpBook);
    Header.Bottom:=Header.Top+frmMain.SearchParams.HeaderHeight;
    Writeln('TRACE search startup ',Stage,' book_header_screen=',SLSRectText(Header),
      ' caption=',frmMain.ctpBook.Caption);
  end;
  Flush(Output);
end;

// Parent invokes immediately after actual Application.CreateForm(Main) returns,
// before any explicit scaling, category collapse/expand, focus or scroll command.
procedure TestSearchStartupLayout;
var Viewport, ParentClient, Intersection, LabelBounds, InputBounds, HeaderBounds: TRect;
  Parent, InitialFocus: TWinControl; InitialPPI, UserScroll: Integer;

  function FullyInside(const Bounds, Container: TRect): Boolean;
  begin
    Result:=(Bounds.Width>0) and (Bounds.Height>0) and
      (Bounds.Left>=Container.Left) and (Bounds.Top>=Container.Top) and
      (Bounds.Right<=Container.Right) and (Bounds.Bottom<=Container.Bottom);
  end;

begin
  Require(Assigned(frmMain),'Search startup layout requires the real newly constructed Main');
  SLSTraceGeometry('after-construction-before-explicit-show');
  InitialPPI:=frmMain.CurrentPPI;
  frmMain.Show; Application.ProcessMessages;
  SLSTraceGeometry('after-show-and-messages');
  Require((frmMain.pgControl.ActivePage=frmMain.tsSearch) and (frmMain.WindowState=wsNormal),
    'Fresh Search startup did not restore its requested page/window state');
  Require((frmMain.Width=1150) and (frmMain.Height=850),'Fresh Search startup did not restore1150x850');
  Require(not frmMain.ctpBook.Collapsed and not frmMain.ctpFile.Collapsed and not frmMain.ctpOther.Collapsed,
    'Fresh Search startup unexpectedly collapsed a category');
  Require(frmMain.CurrentPPI=InitialPPI,'Startup fixture unexpectedly changed the monitor DPI');
  Require(frmMain.SearchParams.HandleAllocated and frmMain.ctpBook.HandleAllocated and frmMain.edFFullName.HandleAllocated,
    'Shown Search controls have no native viewport');
  Viewport:=SLSClientOnScreen(frmMain.SearchParams);
  Parent:=frmMain.SearchParams.Parent;
  while Assigned(Parent) do
  begin
    Require(Parent.HandleAllocated and Parent.Visible,'A shown Search viewport ancestor is hidden or unallocated');
    ParentClient:=SLSClientOnScreen(Parent);
    Require(IntersectRect(Intersection,Viewport,ParentClient),'The Search viewport is outside an ancestor client area');
    Viewport:=Intersection; Parent:=Parent.Parent;
  end;
  LabelBounds:=SLSBoundsOnScreen(frmMain.Label5); InputBounds:=SLSBoundsOnScreen(frmMain.edFFullName);
  HeaderBounds:=SLSBoundsOnScreen(frmMain.ctpBook); HeaderBounds.Bottom:=HeaderBounds.Top+frmMain.SearchParams.HeaderHeight;
  Writeln('TRACE search startup final_clipped_viewport=',SLSRectText(Viewport),
    ' header=',SLSRectText(HeaderBounds),' author_label=',SLSRectText(LabelBounds),
    ' author_input=',SLSRectText(InputBounds),' label_inside=',Ord(FullyInside(LabelBounds,Viewport)),
    ' input_inside=',Ord(FullyInside(InputBounds,Viewport)),' header_inside=',Ord(FullyInside(HeaderBounds,Viewport))); Flush(Output);
  Require(SLSOtherPreferences=SLSProtectedPreferences,'Startup layout fixture changed unrelated preferences');
  Require(Vcl.Dialogs.UseLatestCommonDialogs=SLSOriginalDialogs,'Startup layout fixture changed the common-dialog setting');
  Require(frmMain.SearchParams.VertScrollBar.Position=0,'Fresh Search starts scrolled away from its first category');
  Require(FullyInside(HeaderBounds,Viewport),'Fresh Search book-category header is clipped at initial top');
  Require(frmMain.Label5.Visible and FullyInside(LabelBounds,Viewport),'Fresh Search Author label is clipped at initial top');
  Require(frmMain.edFFullName.Visible and FullyInside(InputBounds,Viewport),'Fresh Search Author input is clipped at initial top');
  Require((frmMain.ctpBook.TabOrder=0) and (frmMain.ctpFile.TabOrder=1) and
    (frmMain.ctpOther.TabOrder=2),'Search keyboard order differs from its visible category order');
  Require(frmMain.ActiveControl=frmMain.edFFullName,'Fresh Search did not naturally focus its first Author input');
  Writeln('PASS search startup first category header, Author label and input are fully visible without scaling or scrolling'); Flush(Output);

  // Only AFTER the unmodified startup oracle, emulate deliberate lower-field
  // focus and scrolling. The ordinary view refresh must not force either back.
  InitialFocus:=frmMain.ActiveControl;
  try
    Require(frmMain.cbDate.CanFocus,'The lower Search Date field cannot receive deliberate user focus');
    frmMain.ActiveControl:=frmMain.cbDate; Application.ProcessMessages;
    frmMain.SearchParams.VertScrollBar.Position:=23; Application.ProcessMessages;
    UserScroll:=frmMain.SearchParams.VertScrollBar.Position;
    Require(UserScroll>0,'Search has no scrollable range for the manual-position oracle');
    frmMain.pgControlChange(nil); Application.ProcessMessages;
    SLSTraceGeometry('after-deliberate-date-focus-scroll-and-view-refresh');
    Require(frmMain.ActiveControl=frmMain.cbDate,'An ordinary Search refresh overwrote deliberate user focus');
    Require(frmMain.SearchParams.VertScrollBar.Position=UserScroll,
      'An ordinary Search refresh overwrote the deliberate scrollbar position');
    Require(SLSOtherPreferences=SLSProtectedPreferences,'Search focus/scrolling changed unrelated preferences');
    Writeln('PASS search startup fix preserves deliberate Date focus and scrolling during ordinary view refresh'); Flush(Output);
  finally
    frmMain.ActiveControl:=InitialFocus; Application.ProcessMessages;
    frmMain.SearchParams.VertScrollBar.Position:=0;
  end;
end;
