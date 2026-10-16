unit unit_MHLTheme;

interface

uses Winapi.Windows, Winapi.Messages, Vcl.Controls, Vcl.Graphics;

const WM_MHL_APP_THEME = WM_APP + $42;

function MHLThemeDark: Boolean;
function TryMHLWindowsDarkTheme(out Dark: Boolean): Boolean;
function MHLShouldOfferWindowsDarkTheme(WindowsDark, AppDark, Dismissed: Boolean): Boolean;
function MHLThemeBackground: TColor;
function MHLThemeText: TColor;
function MHLThemeLink: TColor;
procedure SetMHLControlFontColor(Control: TControl; Color: TColor);
procedure ApplyMHLControlTheme(Control: TControl);
procedure SetMHLTheme(Dark: Boolean);

implementation

uses System.SysUtils, System.StrUtils, System.Classes, System.Types, System.Math, System.Win.Registry, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Themes, Vcl.Styles,
  VirtualTrees, VirtualTrees.Types, Vcl.ComCtrls, Winapi.RichEdit;

type TControlAccess = class(TControl);
  TTreeAccess = class(TCustomVirtualStringTree);

const DarkStyleName = 'Charcoal Dark Slate';
var DarkActive: Boolean;

type
  TThemeFormState = record
    Form: TCustomForm;
    Visible, Modal: Boolean;
  end;

  TThemeFocusSnapshot = class(TComponent)
  private
    FControl: TWinControl;
    FForm: TCustomForm;
    FWasForeground: Boolean;
    FModalLevel: Integer;
    FForms: TArray<TThemeFormState>;
    function NewInputForm(Form: TCustomForm): Boolean;
    procedure Trace(const Reason: string);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Capture;
    procedure Restore;
  end;

  TThemeToolbarPainter = class(TComponent)
  private
    FBar: TToolBar;
    FOriginalDraw: TTBCustomDrawEvent;
    FOriginalButton: TTBCustomDrawBtnEvent;
    FOriginalStyleElements: TStyleElements;
    procedure Draw(Sender: TToolBar; const Bounds: TRect; var DefaultDraw: Boolean);
    procedure DrawButton(Sender: TToolBar; Button: TToolButton; State: TCustomDrawState; var DefaultDraw: Boolean);
  public
    constructor CreateFor(Bar: TToolBar);
    procedure Apply;
  end;

constructor TThemeFocusSnapshot.Capture;
var I: Integer;
begin
  inherited Create(nil);
  FControl:=FindControl(Winapi.Windows.GetFocus);
  if not Assigned(FControl) then Exit;
  FForm:=GetParentForm(FControl);
  if not Assigned(FForm) then begin FControl:=nil; Exit; end;
  FWasForeground:=GetForegroundWindow=FForm.Handle;
  FModalLevel:=Application.ModalLevel;
  FControl.FreeNotification(Self); FForm.FreeNotification(Self);
  SetLength(FForms,Screen.FormCount);
  for I:=0 to High(FForms) do
  begin
    FForms[I].Form:=Screen.Forms[I];
    FForms[I].Visible:=Screen.Forms[I].Visible;
    FForms[I].Modal:=fsModal in Screen.Forms[I].FormState;
    Screen.Forms[I].FreeNotification(Self);
  end;
  Trace('captured');
end;

procedure TThemeFocusSnapshot.Notification(AComponent: TComponent; Operation: TOperation);
begin
  if Operation=opRemove then
  begin
    if AComponent=FControl then FControl:=nil;
    if AComponent=FForm then FForm:=nil;
    for var I:=0 to High(FForms) do
      if AComponent=FForms[I].Form then FForms[I].Form:=nil;
  end;
  inherited;
end;

function TThemeFocusSnapshot.NewInputForm(Form: TCustomForm): Boolean;
begin
  Result:=False;
  if not Assigned(Form) or (Form=FForm) then Exit;
  for var Previous in FForms do
    if Previous.Form=Form then
      Exit((not Previous.Visible and Form.Visible) or
        (not Previous.Modal and (fsModal in Form.FormState)));
  Result:=Form.Visible or (fsModal in Form.FormState);
end;

procedure TThemeFocusSnapshot.Trace(const Reason: string);
{$IFDEF MHL_SQL_PROFILE}
var SourceName, ActiveName: string;
{$ENDIF}
begin
{$IFDEF MHL_SQL_PROFILE}
  SourceName:='<nil>'; ActiveName:='<nil>';
  if Assigned(FForm) then SourceName:=FForm.ClassName+':'+FForm.Name;
  if Assigned(Screen.ActiveCustomForm) then ActiveName:=Screen.ActiveCustomForm.ClassName+':'+Screen.ActiveCustomForm.Name;
  Writeln('TRACE theme focus ',Reason,' source=',SourceName,' active=',ActiveName,
    ' was_foreground=',Ord(FWasForeground),' modal_before=',FModalLevel,' modal_now=',Application.ModalLevel,
    ' foreground=',GetForegroundWindow,' native_focus=',Winapi.Windows.GetFocus);
  for var Previous in FForms do if Assigned(Previous.Form) then
    Writeln('TRACE theme form ',Previous.Form.ClassName,':',Previous.Form.Name,
      ' before_visible=',Ord(Previous.Visible),' now_visible=',Ord(Previous.Form.Visible),
      ' before_modal=',Ord(Previous.Modal),' now_modal=',Ord(fsModal in Previous.Form.FormState));
  Flush(Output);
{$ENDIF}
end;

procedure TThemeFocusSnapshot.Restore;
begin
  // A background form must never activate merely because its style changed.
  if not FWasForeground then begin Trace('skip background'); Exit; end;
  if not Assigned(FControl) or not Assigned(FForm) then begin Trace('skip removed control/form'); Exit; end;
  if (csDestroying in FControl.ComponentState) or (csDestroying in FForm.ComponentState) or
    not FControl.CanFocus then begin Trace('skip cannot focus'); Exit; end;
  // Theme callbacks may intentionally open another form or a modal dialog.
  // Preserve that new input target rather than taking focus back from it.
  if Application.ModalLevel<>FModalLevel then begin Trace('skip changed modal level'); Exit; end;
  if NewInputForm(Screen.ActiveCustomForm) then begin Trace('skip new active input form'); Exit; end;
  for var I:=0 to Screen.FormCount-1 do
    if NewInputForm(Screen.Forms[I]) then begin Trace('skip newly visible/modal form'); Exit; end;
  // RecreateWnd can transiently activate an already existing form such as
  // Main. That is not a callback opening a new input surface; permit restoring
  // the original foreground form when no visibility/modal transition occurred.
  // A style switch recreates HWNDs. Retain the actual focused VCL component,
  // including a focused release button, after all form theme callbacks finish.
  // FreeNotification also covers a callback that removes/rebuilds that control.
  Trace('restoring');
  SetForegroundWindow(FForm.Handle);
  SetActiveWindow(FForm.Handle);
  FControl.SetFocus;
  Trace('restored');
end;

constructor TThemeToolbarPainter.CreateFor(Bar: TToolBar);
begin
  inherited Create(Bar); Name:='MHLToolbarPainter'; FBar:=Bar;
  FOriginalDraw:=Bar.OnCustomDraw; FOriginalButton:=Bar.OnCustomDrawButton;
  FOriginalStyleElements:=Bar.StyleElements;
  Bar.OnCustomDraw:=Draw; Bar.OnCustomDrawButton:=DrawButton;
end;

procedure TThemeToolbarPainter.Apply;
begin
  // The stock Charcoal toolbar paints every idle button as a raised grey tile.
  // Native custom drawing retains keyboard/menu/checked behavior and the icons.
  if DarkActive then FBar.StyleElements:=[] else FBar.StyleElements:=FOriginalStyleElements;
end;

procedure TThemeToolbarPainter.Draw(Sender: TToolBar; const Bounds: TRect; var DefaultDraw: Boolean);
begin
  if not DarkActive then begin if Assigned(FOriginalDraw) then FOriginalDraw(Sender,Bounds,DefaultDraw); Exit; end;
  Sender.Canvas.Brush.Color:=MHLThemeBackground; Sender.Canvas.FillRect(Bounds); DefaultDraw:=True;
end;

procedure TThemeToolbarPainter.DrawButton(Sender: TToolBar; Button: TToolButton; State: TCustomDrawState; var DefaultDraw: Boolean);
var R, Content, TextBounds: TRect; Color, Border, Foreground: TColor; Active, Hot, Pressed: Boolean;
  X, Y, ArrowWidth, Gap, Offset, Radius: Integer; Text: string;
begin
  if not DarkActive then begin if Assigned(FOriginalButton) then FOriginalButton(Sender,Button,State,DefaultDraw); Exit; end;
  DefaultDraw:=False; R:=Button.BoundsRect; Sender.Canvas.Brush.Color:=MHLThemeBackground; Sender.Canvas.FillRect(R);
  if Button.Style in [tbsSeparator,tbsDivider] then
  begin
    Sender.Canvas.Pen.Color:=RGB(71,74,79); X:=(R.Left+R.Right) div 2;
    Sender.Canvas.MoveTo(X,R.Top+7); Sender.Canvas.LineTo(X,R.Bottom-7); Exit;
  end;
  Active:=Button.Down; Hot:=cdsHot in State; Pressed:=cdsSelected in State;
  Color:=RGB(43,45,48); Border:=RGB(62,65,70); Foreground:=MHLThemeText;
  if Hot then begin Color:=RGB(62,68,79); Border:=RGB(106,126,154); end;
  if Active then begin Color:=RGB(43,76,119); Border:=RGB(112,173,239); Foreground:=RGB(239,245,255); end;
  if Pressed then begin Color:=RGB(29,49,78); Border:=RGB(145,191,243); end;
  if not Button.Enabled then Foreground:=RGB(115,120,129);
  InflateRect(R,-1,-1); Sender.Canvas.Brush.Color:=Color; Sender.Canvas.Pen.Color:=Border;
  Radius:=Max(3,MulDiv(5,Sender.CurrentPPI,96)); Sender.Canvas.RoundRect(R.Left,R.Top,R.Right,R.Bottom,Radius,Radius);
  if Active then
  begin
    Sender.Canvas.Pen.Color:=Border; Sender.Canvas.Pen.Width:=Max(2,MulDiv(3,Sender.CurrentPPI,96));
    Sender.Canvas.MoveTo(R.Left+4,R.Bottom-2); Sender.Canvas.LineTo(R.Right-4,R.Bottom-2); Sender.Canvas.Pen.Width:=1;
  end;
  Content:=R; ArrowWidth:=0; Gap:=MulDiv(4,Sender.CurrentPPI,96); Offset:=Ord(Pressed);
  if Button.Style=tbsDropDown then
  begin
    ArrowWidth:=MulDiv(14,Sender.CurrentPPI,96); Dec(Content.Right,ArrowWidth);
    X:=R.Right-ArrowWidth div 2-1; Y:=(R.Top+R.Bottom) div 2;
    Sender.Canvas.Brush.Color:=Foreground; Sender.Canvas.Pen.Color:=Foreground;
    Sender.Canvas.Polygon([Point(X-3,Y-1),Point(X+3,Y-1),Point(X,Y+2)]);
  end;
  Sender.Canvas.Font.Assign(Sender.Font); Sender.Canvas.Font.Color:=Foreground;
  if Sender.ShowCaptions then Text:=Button.Caption else Text:='';
  if Assigned(Sender.Images) and (Button.ImageIndex>=0) and (Button.ImageIndex<Sender.Images.Count) then
  begin
    X:=Content.Left+(Content.Width-Sender.Images.Width) div 2; Y:=Content.Top+(Content.Height-Sender.Images.Height) div 2;
    if (Text<>'') and Sender.List then X:=Content.Left+Gap;
    if (Text<>'') and not Sender.List then Y:=Content.Top+Gap;
    Sender.Images.Draw(Sender.Canvas,X+Offset,Y+Offset,Button.ImageIndex,Button.Enabled);
    if Sender.List then Content.Left:=X+Sender.Images.Width+Gap
    else if Text<>'' then Content.Top:=Y+Sender.Images.Height;
  end;
  if Text<>'' then
  begin
    TextBounds:=Content; OffsetRect(TextBounds,Offset,Offset); Sender.Canvas.Brush.Style:=bsClear;
    DrawText(Sender.Canvas.Handle,PChar(Text),Length(Text),TextBounds,DT_CENTER or DT_VCENTER or DT_SINGLELINE);
    Sender.Canvas.Brush.Style:=bsSolid;
  end;
end;

function MHLThemeDark: Boolean;
begin Result := DarkActive; end;

function TryMHLWindowsDarkTheme(out Dark: Boolean): Boolean;
var Registry: TRegistry;
begin
  Result:=False; Dark:=False;
  Registry:=TRegistry.Create(KEY_QUERY_VALUE);
  try
    Registry.RootKey:=HKEY_CURRENT_USER;
    try
      if Registry.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') and
        Registry.ValueExists('AppsUseLightTheme') then
      begin
        Dark:=Registry.ReadInteger('AppsUseLightTheme')=0;
        Result:=True;
      end;
    except
      // Missing or unsupported personalization settings should not interrupt startup.
      Result:=False;
    end;
  finally Registry.Free; end;
end;

function MHLShouldOfferWindowsDarkTheme(WindowsDark, AppDark, Dismissed: Boolean): Boolean;
begin Result:=WindowsDark and not AppDark and not Dismissed; end;

function MHLThemeBackground: TColor;
begin if DarkActive then Result:=RGB(43,45,48) else Result:=clBtnFace; end;

function MHLThemeText: TColor;
begin if DarkActive then Result:=RGB(205,208,214) else Result:=clWindowText; end;

function MHLThemeLink: TColor;
begin if DarkActive then Result:=RGB(114,167,232) else Result:=clHotLight; end;

procedure SetMHLControlFontColor(Control: TControl; Color: TColor);
var Tree: TTreeAccess; Options: TVTAutoOptions;
begin
  if (Control = nil) or (TControlAccess(Control).Font.Color = Color) then Exit;
  if Control is TCustomVirtualStringTree then
  begin
    // A colour notification is not a font-metric change. VirtualTree's
    // automatic font sizing would otherwise walk the loaded rows here.
    Tree := TTreeAccess(Control); Options := Tree.TreeOptions.AutoOptions;
    Tree.TreeOptions.AutoOptions := Options - [toAutoChangeScale];
    try TControlAccess(Control).Font.Color := Color;
    finally Tree.TreeOptions.AutoOptions := Options; end;
  end
  else TControlAccess(Control).Font.Color := Color;
end;

procedure ApplyMHLControlTheme(Control: TControl);
var I: Integer; Tree: TTreeAccess; Format: TCharFormat2; Rich: TCustomRichEdit; Painter: TComponent;
begin
  if Control=nil then Exit;
  // The reader owns its hidden formatting buffer and reapplies semantic colors.
  // Updating it after the reader's theme message would erase those colors.
  if (Control is TForm) and SameText(Control.Name,'ReaderFormattingHost') then Exit;
  // These panels display user-selected colours and are saved as preferences.
  if (Control is TPanel) and MatchText(Control.Name, [
    'pnCA','pnCS','pnASG','pnCT','pnBS','pnDefaultFontColor',
    'pnDownloadedFontColor','pnDeletedFontColor']) then Exit;
  if Control is TCustomRichEdit then
  begin
    // Changing RichEdit.Font reapplies the whole default font to its content,
    // destroying bold/italic runs, heading sizes and embedded font choices.
    Rich := TCustomRichEdit(Control);
    if Rich.HandleAllocated then
    begin
      FillChar(Format,SizeOf(Format),0); Format.cbSize := SizeOf(Format);
      Format.dwMask := CFM_COLOR; Format.crTextColor := ColorToRGB(MHLThemeText);
      SendMessage(Rich.Handle,EM_SETCHARFORMAT,SCF_ALL,LPARAM(@Format));
    end;
  end
  else
  begin
    SetMHLControlFontColor(Control, MHLThemeText);
    TControlAccess(Control).Font.Quality:=fqClearTypeNatural;
  end;
  if (Control is TCustomEdit) or (Control is TCustomListBox) or (Control is TCustomComboBox) then
  begin
    if DarkActive then TControlAccess(Control).Color:=RGB(30,31,34)
    else TControlAccess(Control).Color:=clWindow;
  end
  else TControlAccess(Control).Color:=MHLThemeBackground;
  if Control is TToolBar then
  begin
    Painter:=Control.FindComponent('MHLToolbarPainter');
    if not Assigned(Painter) then Painter:=TThemeToolbarPainter.CreateFor(TToolBar(Control));
    if Painter is TThemeToolbarPainter then TThemeToolbarPainter(Painter).Apply;
  end;
  if Control is TCustomVirtualStringTree then
  begin
    Tree:=TTreeAccess(Control);
    Tree.StyleElements:=Tree.StyleElements-[seClient,seFont];
    Tree.Header.Font.Color:=MHLThemeText;
    if DarkActive then
    begin
      Tree.Color:=RGB(30,31,34); SetMHLControlFontColor(Tree, MHLThemeText);
      Tree.Colors.FocusedSelectionColor:=RGB(33,66,131);
      Tree.Colors.UnfocusedSelectionColor:=RGB(53,69,97);
      Tree.Colors.SelectionTextColor:=RGB(221,225,234);
      Tree.Colors.GridLineColor:=RGB(49,51,55);
      Tree.Colors.TreeLineColor:=RGB(87,89,94);
    end
    else
    begin
      Tree.Color:=clWindow; SetMHLControlFontColor(Tree, clWindowText);
      Tree.Colors.FocusedSelectionColor:=clHighlight;
      Tree.Colors.UnfocusedSelectionColor:=clBtnFace;
      Tree.Colors.SelectionTextColor:=clHighlightText;
      Tree.Colors.GridLineColor:=clBtnFace; Tree.Colors.TreeLineColor:=clBtnShadow;
    end;
  end;
  if Control is TWinControl then
    for I:=0 to TWinControl(Control).ControlCount-1 do ApplyMHLControlTheme(TWinControl(Control).Controls[I]);
  Control.Invalidate;
end;

procedure SetMHLTheme(Dark: Boolean);
var I: Integer; WasDark: Boolean; Focus: TThemeFocusSnapshot;
begin
  // Modern Shell dialogs own their painting, including the address/search bar.
  // Leave them native in both themes; applying VCL's partial dialog skin breaks
  // that bar. Set this once with the theme, not while a modal owner is in use.
  TStyleManager.SystemHooks:=TStyleManager.SystemHooks-[shDialogs];
  WasDark:=DarkActive;
  if Dark=WasDark then Exit;
  if Dark then
  begin
    // The VCL can discover embedded styles before the first toggle. Reuse
    // that registration rather than loading a duplicate and retaining its handle.
    if not MatchText(DarkStyleName,TStyleManager.StyleNames) then
      TStyleManager.LoadFromResource(HInstance,'MHL_DARK_STYLE','VCLSTYLE');
  end;
  Focus:=TThemeFocusSnapshot.Capture;
  try
    DarkActive:=Dark;
    try
      if Dark then TStyleManager.SetStyle(DarkStyleName) else TStyleManager.SetStyle('Windows');
    except DarkActive:=WasDark; raise; end;
    for I:=0 to Screen.FormCount-1 do
    begin
      ApplyMHLControlTheme(Screen.Forms[I]);
      if Screen.Forms[I].HandleAllocated then
        SendMessage(Screen.Forms[I].Handle,WM_MHL_APP_THEME,Ord(Dark),0);
    end;
  finally
    try Focus.Restore; finally Focus.Free; end;
  end;
end;

end.
