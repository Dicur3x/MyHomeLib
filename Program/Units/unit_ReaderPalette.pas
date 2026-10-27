unit unit_ReaderPalette;

interface

uses Winapi.Windows, Winapi.Messages, System.Classes, System.Types, Vcl.Controls,
  Vcl.StdCtrls, Vcl.Forms, Vcl.Graphics, Vcl.ExtCtrls;

type
  // Native button behaviour/accessibility, with colours scoped to this reader.
  TReaderPaletteButton = class(TButton)
  private
    FHot: Boolean;
    procedure DrawItem(var Message: TWMDrawItem); message CN_DRAWITEM;
    procedure MouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure MouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure SetButtonStyle(ADefault: Boolean); override;
  public constructor Create(AOwner: TComponent); override;
  end;
  TReaderPaletteCombo = class(TComboBox)
  protected
    procedure DrawItem(Index: Integer; Rect: TRect; State: TOwnerDrawState); override;
    procedure WndProc(var Message: TMessage); override;
  public constructor Create(AOwner: TComponent); override;
  end;

  TReaderPaletteCheckBox = class(TCheckBox)
  protected
    procedure WndProc(var Message: TMessage); override;
  public constructor Create(AOwner: TComponent); override;
  end;
  TReaderPaletteColorBox = class(TColorBox)
  protected
    procedure DrawItem(Index: Integer; Rect: TRect; State: TOwnerDrawState); override;
    procedure WndProc(var Message: TMessage); override;
  public constructor Create(AOwner: TComponent); override;
  end;

function ReaderThemeBackground(Index: Integer): TColor;
function ReaderThemeText(Index: Integer): TColor;
function ReaderBlendColor(Background, Foreground: TColor; Amount: Integer): TColor;
procedure ApplyReaderPalette(Form: TCustomForm; Background, Foreground: TColor; Dark: Boolean);

implementation

uses System.SysUtils, System.Math, Vcl.Menus, Vcl.ComCtrls, Winapi.Dwmapi;

type TControlAccess = class(TControl);
  TReaderMenuPalette = class(TComponent)
  private
    FForm: TCustomForm;
    FBrush: TBrush;
    procedure Draw(Sender: TObject; Canvas: TCanvas; ARect: TRect; Selected: Boolean);
    procedure Measure(Sender: TObject; Canvas: TCanvas; var Width, Height: Integer);
  public
    constructor CreateFor(Form: TCustomForm);
    destructor Destroy; override;
    procedure Apply;
  end;

function ReaderBlendColor(Background, Foreground: TColor; Amount: Integer): TColor;
var B,F: Cardinal;
begin
  B:=ColorToRGB(Background); F:=ColorToRGB(Foreground); Amount:=EnsureRange(Amount,0,255);
  Result:=RGB((GetRValue(B)*(255-Amount)+GetRValue(F)*Amount) div 255,
    (GetGValue(B)*(255-Amount)+GetGValue(F)*Amount) div 255,
    (GetBValue(B)*(255-Amount)+GetBValue(F)*Amount) div 255);
end;

function ReaderThemeBackground(Index: Integer): TColor;
const Colors: array[0..5] of TColor = ($00F4F7FB,$00DDECF5,$00C5DBEC,$00E4E4E4,$002B2927,$00222222);
begin Result:=Colors[EnsureRange(Index,0,5)]; end;

function ReaderThemeText(Index: Integer): TColor;
const Colors: array[0..5] of TColor = ($00202020,$002E343A,$00353B44,$00252525,$00B8C3CE,$00DCE1E8);
begin Result:=Colors[EnsureRange(Index,0,5)]; end;

constructor TReaderPaletteButton.Create(AOwner: TComponent);
begin inherited; StyleName:='Windows'; StyleElements:=[]; end;

procedure TReaderPaletteButton.CreateParams(var Params: TCreateParams);
begin inherited; Params.Style:=(Params.Style and not $F) or BS_OWNERDRAW; end;

procedure TReaderPaletteButton.SetButtonStyle(ADefault: Boolean);
begin Invalidate; end;

procedure TReaderPaletteButton.MouseEnter(var Message: TMessage);
begin inherited; FHot:=True; Invalidate; end;

procedure TReaderPaletteButton.MouseLeave(var Message: TMessage);
begin inherited; FHot:=False; Invalidate; end;

procedure TReaderPaletteButton.DrawItem(var Message: TWMDrawItem);
var Canvas: TCanvas; R, TextRect: TRect; Selected: Boolean; Ink: TColor;
begin
  Canvas:=TCanvas.Create;
  try
    Canvas.Handle:=Message.DrawItemStruct.hDC; R:=Message.DrawItemStruct.rcItem;
    Selected:=Message.DrawItemStruct.itemState and ODS_SELECTED<>0;
    Canvas.Brush.Color:=Color;
    if Selected then Canvas.Brush.Color:=ReaderBlendColor(Color,Font.Color,30)
    else if FHot then Canvas.Brush.Color:=ReaderBlendColor(Color,Font.Color,16);
    Canvas.FillRect(R); Canvas.Pen.Color:=ReaderBlendColor(Color,Font.Color,70);
    InflateRect(R,-2,-2); Canvas.RoundRect(R,5,5); Canvas.Font.Assign(Font);
    Ink:=Font.Color; if not Enabled then Ink:=ReaderBlendColor(Color,Ink,110);
    Canvas.Font.Color:=Ink; Canvas.Brush.Style:=bsClear; TextRect:=R;
    InflateRect(TextRect,-2,-1); if Selected then OffsetRect(TextRect,1,1);
    DrawText(Canvas.Handle,PChar(Caption),Length(Caption),TextRect,
      DT_SINGLELINE or DT_CENTER or DT_VCENTER or DT_END_ELLIPSIS);
    if (Message.DrawItemStruct.itemState and ODS_FOCUS<>0) and
      (Message.DrawItemStruct.itemState and $0100 {ODS_NOFOCUSRECT}=0) then
    begin InflateRect(R,-3,-3); Canvas.DrawFocusRect(R); end;
    Message.Result:=1;
  finally Canvas.Handle:=0; Canvas.Free; end;
end;

constructor TReaderPaletteCombo.Create(AOwner: TComponent);
begin inherited; StyleName:='Windows'; StyleElements:=[]; Style:=csOwnerDrawFixed; end;

procedure TReaderPaletteCombo.DrawItem(Index: Integer; Rect: TRect; State: TOwnerDrawState);
var Text: string;
begin
  if Assigned(OnDrawItem) then begin inherited; Exit; end;
  Canvas.Brush.Color:=Color; Canvas.Font.Assign(Font);
  if (odSelected in State) and not (odComboBoxEdit in State) then
    Canvas.Brush.Color:=ReaderBlendColor(Color,Font.Color,36);
  Canvas.FillRect(Rect); Inc(Rect.Left,5); Dec(Rect.Right,5); Text:='';
  if (Index>=0) and (Index<Items.Count) then Text:=Items[Index];
  DrawText(Canvas.Handle,PChar(Text),Length(Text),Rect,DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
end;

procedure PaintReaderComboChrome(Control: TWinControl; var Message: TMessage);
var Canvas: TCanvas; DC: HDC; R, Arrow: TRect; MidX, MidY, Size: Integer;
  Background, Foreground: TColor;
begin
  if not Control.HandleAllocated or
    ((Message.Msg<>WM_PAINT) and (Message.Msg<>WM_PRINT) and (Message.Msg<>WM_PRINTCLIENT)) then Exit;
  DC:=0; Canvas:=TCanvas.Create;
  try
    if Message.Msg=WM_PAINT then DC:=GetDC(Control.Handle) else DC:=HDC(Message.WParam);
    if DC=0 then Exit;
    Background:=TControlAccess(Control).Color; Foreground:=TControlAccess(Control).Font.Color;
    Canvas.Handle:=DC; R:=Control.ClientRect;
    // Cover the complete native bevel, retaining a single quiet outline.
    Canvas.Brush.Color:=Background; Canvas.FrameRect(R); InflateRect(R,-1,-1);
    Canvas.FrameRect(R); Canvas.Brush.Style:=bsClear;
    Canvas.Pen.Color:=ReaderBlendColor(Background,Foreground,65); Canvas.Rectangle(R);
    Arrow:=Rect(Max(2,R.Right-MulDiv(20,Control.CurrentPPI,96)),R.Top+1,R.Right-1,R.Bottom-1);
    Canvas.Brush.Style:=bsSolid; Canvas.Brush.Color:=Background; Canvas.FillRect(Arrow);
    Canvas.Brush.Color:=Foreground; Canvas.Pen.Color:=Foreground;
    MidX:=(Arrow.Left+Arrow.Right) div 2; MidY:=(Arrow.Top+Arrow.Bottom) div 2;
    Size:=Max(2,MulDiv(3,Control.CurrentPPI,96));
    Canvas.Polygon([Point(MidX-Size,MidY-1),Point(MidX+Size,MidY-1),Point(MidX,MidY+Size-1)]);
  finally
    Canvas.Handle:=0; Canvas.Free;
    if (Message.Msg=WM_PAINT) and (DC<>0) then ReleaseDC(Control.Handle,DC);
  end;
end;

procedure TReaderPaletteCombo.WndProc(var Message: TMessage);
begin inherited; PaintReaderComboChrome(Self,Message); end;

constructor TReaderPaletteCheckBox.Create(AOwner: TComponent);
begin inherited; StyleName:='Windows'; StyleElements:=[]; end;

procedure TReaderPaletteCheckBox.WndProc(var Message: TMessage);
var Canvas: TCanvas; DC: HDC; Paint: TPaintStruct; R, Box: TRect;
  Size, Pad: Integer; Ink: TColor;
begin
  if (Message.Msg<>WM_PAINT) and (Message.Msg<>WM_PRINTCLIENT) then
  begin
    inherited;
    if Message.Msg=BM_SETCHECK then Invalidate;
    Exit;
  end;
  // Keep the native checkbox class, state, keyboard and accessibility.
  // Only painting is local: themed Windows checkbox text ignores Font.Color.
  if Message.Msg=WM_PAINT then DC:=BeginPaint(Handle,Paint) else DC:=HDC(Message.WParam);
  if DC=0 then Exit;
  Canvas:=TCanvas.Create;
  try
    Canvas.Handle:=DC; Canvas.Brush.Color:=Color; R:=ClientRect; Canvas.FillRect(R);
    Canvas.Font.Assign(Font); Ink:=Font.Color;
    if not Enabled then Ink:=ReaderBlendColor(Color,Ink,110);
    Canvas.Font.Color:=Ink;
    Size:=Max(13,MulDiv(14,CurrentPPI,96)); Pad:=MulDiv(7,CurrentPPI,96);
    Box:=Rect(1,(Height-Size) div 2,Size+1,(Height+Size) div 2);
    if Alignment=taLeftJustify then OffsetRect(Box,Width-Size-2,0);
    Canvas.Pen.Color:=ReaderBlendColor(Color,Ink,135);
    Canvas.Brush.Color:=ReaderBlendColor(Color,Ink,10); Canvas.RoundRect(Box,3,3);
    if State<>cbUnchecked then
    begin
      Canvas.Pen.Color:=Ink; Canvas.Pen.Width:=Max(1,MulDiv(2,CurrentPPI,96));
      if State=cbGrayed then
      begin
        Canvas.MoveTo(Box.Left+3,Box.CenterPoint.Y); Canvas.LineTo(Box.Right-3,Box.CenterPoint.Y);
      end
      else
      begin
        Canvas.MoveTo(Box.Left+3,Box.CenterPoint.Y);
        Canvas.LineTo(Box.Left+Size div 2-1,Box.Bottom-4);
        Canvas.LineTo(Box.Right-3,Box.Top+3);
      end;
    end;
    if Alignment=taLeftJustify then R.Right:=Box.Left-Pad else R.Left:=Box.Right+Pad;
    Canvas.Brush.Style:=bsClear;
    DrawText(Canvas.Handle,PChar(Caption),Length(Caption),R,DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS);
    if Focused and (Perform(WM_QUERYUISTATE,0,0) and UISF_HIDEFOCUS=0) then
    begin InflateRect(R,-1,-3); Canvas.DrawFocusRect(R); end;
    Message.Result:=0;
  finally
    Canvas.Handle:=0; Canvas.Free;
    if Message.Msg=WM_PAINT then EndPaint(Handle,Paint);
  end;
end;

constructor TReaderPaletteColorBox.Create(AOwner: TComponent);
begin inherited; StyleName:='Windows'; StyleElements:=[]; end;

procedure TReaderPaletteColorBox.DrawItem(Index: Integer; Rect: TRect; State: TOwnerDrawState);
var Swatch: TRect; Value: TColor; Text: string;
begin
  Canvas.Font.Assign(Font); Canvas.Brush.Color:=Color;
  if (odSelected in State) and not (odComboBoxEdit in State) then
    Canvas.Brush.Color:=ReaderBlendColor(Color,Font.Color,36);
  Canvas.FillRect(Rect);
  if (Index<0) or (Index>=Items.Count) then Exit;
  Swatch:=Rect; InflateRect(Swatch,-4,-4); Swatch.Right:=Swatch.Left+Swatch.Height;
  Value:=Colors[Index];
  if Value=clDefault then Value:=Font.Color else if Value=clNone then Value:=Color;
  Canvas.Brush.Color:=Value; Canvas.Pen.Color:=ReaderBlendColor(Color,Font.Color,100);
  Canvas.Rectangle(Swatch); Rect.Left:=Swatch.Right+7;
  Canvas.Brush.Style:=bsClear; Text:=Items[Index];
  DrawText(Canvas.Handle,PChar(Text),Length(Text),Rect,DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
end;

procedure TReaderPaletteColorBox.WndProc(var Message: TMessage);
begin inherited; PaintReaderComboChrome(Self,Message); end;

constructor TReaderMenuPalette.CreateFor(Form: TCustomForm);
begin inherited Create(Form); Name:='ReaderMenuPalette'; FForm:=Form; FBrush:=TBrush.Create; end;
destructor TReaderMenuPalette.Destroy;
begin FBrush.Free; inherited; end;

procedure TReaderMenuPalette.Draw(Sender: TObject; Canvas: TCanvas; ARect: TRect; Selected: Boolean);
var Item: TMenuItem; Text, Keys: string; KeysRect: TRect; Popup: Boolean; X,Y: Integer;
begin
  Item:=TMenuItem(Sender); Canvas.Font.Assign(TControlAccess(FForm).Font);
  Popup:=Assigned(Item.Parent) and Assigned(Item.Parent.Parent);
  Canvas.Brush.Style:=bsSolid;
  Canvas.Brush.Color:=TControlAccess(FForm).Color;
  if Selected then Canvas.Brush.Color:=ReaderBlendColor(Canvas.Brush.Color,Canvas.Font.Color,32);
  Canvas.FillRect(ARect);
  if not Item.Enabled then Canvas.Font.Color:=ReaderBlendColor(Canvas.Brush.Color,Canvas.Font.Color,110);
  if Item.IsLine then
  begin
    Canvas.Pen.Color:=ReaderBlendColor(Canvas.Brush.Color,Canvas.Font.Color,60);
    Canvas.MoveTo(ARect.Left+8,ARect.CenterPoint.Y); Canvas.LineTo(ARect.Right-8,ARect.CenterPoint.Y); Exit;
  end;
  if Popup then
  begin
    X:=ARect.Left+11; Y:=ARect.CenterPoint.Y;
    Canvas.Pen.Color:=Canvas.Font.Color; Canvas.Brush.Color:=Canvas.Font.Color;
    if Item.Checked then
      if Item.RadioItem then Canvas.Ellipse(X-2,Y-2,X+3,Y+3)
      else begin Canvas.MoveTo(X-4,Y); Canvas.LineTo(X-1,Y+3); Canvas.LineTo(X+4,Y-3); end;
    if Item.Count>0 then
    begin X:=ARect.Right-9; Canvas.Polygon([Point(X-2,Y-4),Point(X+2,Y),Point(X-2,Y+4)]); end;
    Inc(ARect.Left,14); Dec(ARect.Right,12);
  end;
  Text:=Item.Caption; InflateRect(ARect,-10,0); Canvas.Brush.Style:=bsClear;
  if Item.ShortCut<>0 then
  begin
    Keys:=ShortCutToText(Item.ShortCut); KeysRect:=ARect;
    DrawText(Canvas.Handle,PChar(Keys),Length(Keys),KeysRect,DT_SINGLELINE or DT_VCENTER or DT_RIGHT or DT_NOPREFIX);
    Dec(ARect.Right,Canvas.TextWidth(Keys)+20);
  end;
  DrawText(Canvas.Handle,PChar(Text),Length(Text),ARect,DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS);
end;

procedure TReaderMenuPalette.Measure(Sender: TObject; Canvas: TCanvas; var Width, Height: Integer);
begin
  Canvas.Font.Assign(TControlAccess(FForm).Font);
  Width:=Canvas.TextWidth(StripHotkey(TMenuItem(Sender).Caption))+20;
  if Assigned(TMenuItem(Sender).Parent) and Assigned(TMenuItem(Sender).Parent.Parent) then Inc(Width,26);
  if TMenuItem(Sender).ShortCut<>0 then
    Inc(Width,Canvas.TextWidth(ShortCutToText(TMenuItem(Sender).ShortCut))+20);
  Height:=Canvas.TextHeight('Ag')+10;
  if TMenuItem(Sender).IsLine then Height:=8;
end;

procedure TReaderMenuPalette.Apply;
var Info: TMenuInfo;
  procedure Hook(Item: TMenuItem);
  begin
    Item.OnDrawItem:=Draw; Item.OnMeasureItem:=Measure;
    for var I:=0 to Item.Count-1 do Hook(Item[I]);
  end;
  procedure ApplyNativeItems(Menu: HMENU);
  var Item: TMenuItemInfo; Child: HMENU;
  begin
    // VCL may keep the existing native menu bar when OwnerDraw changes.
    // Set the documented native flag too, so it sends the draw callbacks.
    for var I:=0 to GetMenuItemCount(Menu)-1 do
    begin
      Item:=Default(TMenuItemInfo); Item.cbSize:=SizeOf(Item); Item.fMask:=MIIM_FTYPE;
      if GetMenuItemInfo(Menu,I,True,Item) and (Item.fType and MFT_OWNERDRAW=0) then
      begin Item.fType:=Item.fType or MFT_OWNERDRAW; SetMenuItemInfo(Menu,I,True,Item); end;
      Child:=GetSubMenu(Menu,I); if Child<>0 then ApplyNativeItems(Child);
    end;
  end;
begin
  if not Assigned(TForm(FForm).Menu) then Exit;
  Hook(TForm(FForm).Menu.Items); TForm(FForm).Menu.OwnerDraw:=True;
  ApplyNativeItems(TForm(FForm).Menu.Handle);
  FBrush.Color:=TControlAccess(FForm).Color;
  Info:=Default(TMenuInfo); Info.cbSize:=SizeOf(Info);
  Info.fMask:=MIM_BACKGROUND or MIM_APPLYTOSUBMENUS; Info.hbrBack:=FBrush.Handle;
  SetMenuInfo(TForm(FForm).Menu.Handle,Info); if FForm.HandleAllocated then DrawMenuBar(FForm.Handle);
end;

procedure ApplyReaderPalette(Form: TCustomForm; Background, Foreground: TColor; Dark: Boolean);
var Painter: TComponent; Value: Cardinal; IsDark: BOOL;
  procedure Apply(Control: TControl);
  begin
    if (Control is TCustomRichEdit) or SameText(Control.Name,'ReaderFormattingHost') then Exit;
    // A local native style prevents the catalogue's global VCL style from
    // painting this paper/sepia/dark palette with unrelated stock colours.
    TControlAccess(Control).StyleName:='Windows';
    Control.StyleElements:=[]; TControlAccess(Control).Color:=Background;
    TControlAccess(Control).Font.Color:=Foreground;
    if Control is TWinControl then
      for var I:=0 to TWinControl(Control).ControlCount-1 do Apply(TWinControl(Control).Controls[I]);
    Control.Invalidate;
  end;
begin
  Apply(Form);
  Painter:=Form.FindComponent('ReaderMenuPalette');
  if not Assigned(Painter) then Painter:=TReaderMenuPalette.CreateFor(Form);
  TReaderMenuPalette(Painter).Apply;
  if Form.HandleAllocated then
  begin
    IsDark:=Dark; DwmSetWindowAttribute(Form.Handle,20,@IsDark,SizeOf(IsDark));
    Value:=ColorToRGB(Background); DwmSetWindowAttribute(Form.Handle,35,@Value,SizeOf(Value));
    Value:=ColorToRGB(Foreground); DwmSetWindowAttribute(Form.Handle,36,@Value,SizeOf(Value));
  end;
end;

end.
