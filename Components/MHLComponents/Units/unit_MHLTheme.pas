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
procedure ApplyMHLControlTheme(Control: TControl);
procedure SetMHLTheme(Dark: Boolean);

implementation

uses System.SysUtils, System.StrUtils, System.Win.Registry, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Themes, Vcl.Styles,
  VirtualTrees, Vcl.ComCtrls, Winapi.RichEdit;

type TControlAccess = class(TControl);
  TTreeAccess = class(TCustomVirtualStringTree);

const DarkStyleName = 'Charcoal Dark Slate';
var DarkActive: Boolean;

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

procedure ApplyMHLControlTheme(Control: TControl);
var I: Integer; Tree: TTreeAccess; Format: TCharFormat2; Rich: TCustomRichEdit;
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
    TControlAccess(Control).Font.Color:=MHLThemeText;
    TControlAccess(Control).Font.Quality:=fqClearTypeNatural;
  end;
  if (Control is TCustomEdit) or (Control is TCustomListBox) or (Control is TCustomComboBox) then
  begin
    if DarkActive then TControlAccess(Control).Color:=RGB(30,31,34)
    else TControlAccess(Control).Color:=clWindow;
  end
  else TControlAccess(Control).Color:=MHLThemeBackground;
  if Control is TCustomVirtualStringTree then
  begin
    Tree:=TTreeAccess(Control);
    Tree.StyleElements:=Tree.StyleElements-[seClient,seFont];
    Tree.Header.Font.Color:=MHLThemeText;
    if DarkActive then
    begin
      Tree.Color:=RGB(30,31,34); Tree.Font.Color:=MHLThemeText;
      Tree.Colors.FocusedSelectionColor:=RGB(33,66,131);
      Tree.Colors.UnfocusedSelectionColor:=RGB(53,69,97);
      Tree.Colors.SelectionTextColor:=RGB(221,225,234);
      Tree.Colors.GridLineColor:=RGB(49,51,55);
      Tree.Colors.TreeLineColor:=RGB(87,89,94);
    end
    else
    begin
      Tree.Color:=clWindow; Tree.Font.Color:=clWindowText;
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
var I: Integer; WasDark: Boolean;
begin
  WasDark:=DarkActive;
  if Dark then
  begin
    // The VCL can discover embedded styles before the first toggle. Reuse
    // that registration rather than loading a duplicate and retaining its handle.
    if not MatchText(DarkStyleName,TStyleManager.StyleNames) then
      TStyleManager.LoadFromResource(HInstance,'MHL_DARK_STYLE','VCLSTYLE');
  end;
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
end;

end.
