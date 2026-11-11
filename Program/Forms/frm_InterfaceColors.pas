unit frm_InterfaceColors;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Dialogs,
  Vcl.Graphics, unit_MHLThemePalette;

type
  TInterfaceColorsDialog = class(TForm)
  private
    FValues: TMHLThemePalettes;
    FTheme: TComboBox;
    FPreview: TPaintBox;
    FSwatches: array[TMHLPaletteRole] of TShape;
    FButtons: array[TMHLPaletteRole] of TButton;
    FPicker: TColorDialog;
    function Dark: Boolean;
    procedure UpdatePreview(Sender: TObject);
    procedure ChooseColor(Sender: TObject);
    procedure ResetColors(Sender: TObject);
    procedure PaintPreview(Sender: TObject);
  public
    constructor CreateFor(Owner: TCustomForm; const Values: TMHLThemePalettes;
      DarkTheme: Boolean);
    property Values: TMHLThemePalettes read FValues;
  end;

function EditInterfaceColors(Owner: TCustomForm; var Values: TMHLThemePalettes): Boolean;

implementation

uses Winapi.Windows, System.SysUtils, System.Types, Vcl.Controls, unit_MHLTheme;

const
  Labels: array[TMHLPaletteRole] of string = ('Фон окна', 'Фон списков и полей',
    'Основной текст', 'Ссылки и заголовки', 'Выделение в списке книг', 'Текст выделенной строки');

constructor TInterfaceColorsDialog.CreateFor(Owner: TCustomForm;
  const Values: TMHLThemePalettes; DarkTheme: Boolean);
var LabelControl: TLabel; Button: TButton; Y: Integer;
begin
  inherited CreateNew(Owner);
  Name:='InterfaceColorsDialog'; Caption:='Цвета каталогизатора';
  BorderStyle:=bsDialog; Position:=poOwnerFormCenter;
  PopupMode:=pmExplicit; PopupParent:=Owner;
  Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=520; ClientHeight:=458;
  FValues:=Values;
  LabelControl:=TLabel.Create(Self); LabelControl.Parent:=Self;
  LabelControl.SetBounds(16,20,68,20); LabelControl.Caption:='Оформление:';
  FTheme:=TComboBox.Create(Self); FTheme.Parent:=Self; FTheme.Name:='PaletteTheme';
  FTheme.SetBounds(116,16,388,26); FTheme.Style:=csDropDownList;
  FTheme.Items.Add('Светлая тема'); FTheme.Items.Add('Тёмная тема');
  FTheme.ItemIndex:=Ord(DarkTheme); FTheme.OnChange:=UpdatePreview;
  for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
  begin
    Y:=58+Ord(Role)*32;
    LabelControl:=TLabel.Create(Self); LabelControl.Parent:=Self;
    LabelControl.AutoSize:=False;
    LabelControl.SetBounds(16,Y+5,268,22); LabelControl.Caption:=Labels[Role];
    FSwatches[Role]:=TShape.Create(Self); FSwatches[Role].Parent:=Self;
    FSwatches[Role].SetBounds(294,Y+3,38,22);
    FSwatches[Role].Pen.Color:=clGray;
    FButtons[Role]:=TButton.Create(Self); FButtons[Role].Parent:=Self;
    FButtons[Role].Name:='PaletteColor'+IntToStr(Ord(Role));
    FButtons[Role].Tag:=Ord(Role); FButtons[Role].SetBounds(344,Y,160,28);
    FButtons[Role].Caption:='Выбрать цвет…'; FButtons[Role].OnClick:=ChooseColor;
    FButtons[Role].Hint:=Labels[Role]; FButtons[Role].ShowHint:=True;
  end;
  LabelControl:=TLabel.Create(Self); LabelControl.Parent:=Self;
  LabelControl.SetBounds(16,260,488,20); LabelControl.Caption:='Предпросмотр';
  FPreview:=TPaintBox.Create(Self); FPreview.Parent:=Self; FPreview.Name:='PalettePreview';
  FPreview.SetBounds(16,282,488,108); FPreview.OnPaint:=PaintPreview;
  LabelControl:=TLabel.Create(Self); LabelControl.Parent:=Self;
  LabelControl.SetBounds(16,396,488,18); LabelControl.AutoSize:=False;
  LabelControl.Caption:='Цвета книги при чтении настраиваются отдельно в читалке.';
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.Name:='PaletteReset';
  Button.SetBounds(16,420,200,28); Button.Caption:='Вернуть исходные цвета'; Button.OnClick:=ResetColors;
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.Name:='PaletteAccept';
  Button.SetBounds(296,420,96,28); Button.Caption:='ОК'; Button.ModalResult:=mrOk; Button.Default:=True;
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.Name:='PaletteCancel';
  Button.SetBounds(408,420,96,28); Button.Caption:='Отмена'; Button.ModalResult:=mrCancel; Button.Cancel:=True;
  FPicker:=TColorDialog.Create(Self); FPicker.Options:=[cdFullOpen,cdAnyColor];
  ApplyMHLControlTheme(Self);
  if Assigned(Owner) and (Owner.CurrentPPI<>CurrentPPI) then ScaleForPPI(Owner.CurrentPPI);
  UpdatePreview(nil);
end;

function TInterfaceColorsDialog.Dark: Boolean;
begin Result:=FTheme.ItemIndex=1; end;

procedure TInterfaceColorsDialog.UpdatePreview(Sender: TObject);
var Palette: TMHLThemePalette;
begin
  Palette:=ResolveMHLThemePalette(FValues[Dark],Dark);
  for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
    FSwatches[Role].Brush.Color:=Palette.Colors[Role];
  FPreview.Invalidate;
end;

procedure TInterfaceColorsDialog.ChooseColor(Sender: TObject);
var Role: TMHLPaletteRole; Palette: TMHLThemePalette;
begin
  Role:=TMHLPaletteRole(TButton(Sender).Tag);
  Palette:=ResolveMHLThemePalette(FValues[Dark],Dark);
  FPicker.Color:=Palette.Colors[Role];
  if not FPicker.Execute(Handle) then Exit;
  FValues[Dark].Colors[Role]:=ColorToRGB(FPicker.Color);
  UpdatePreview(nil);
end;

procedure TInterfaceColorsDialog.ResetColors(Sender: TObject);
begin FValues[Dark]:=EmptyMHLThemePalette; UpdatePreview(nil); end;

procedure TInterfaceColorsDialog.PaintPreview(Sender: TObject);
var Palette: TMHLThemePalette; R: TRect; Y, RowH, Pad: Integer;
begin
  Palette:=ResolveMHLThemePalette(FValues[Dark],Dark);
  FPreview.Canvas.Font.Assign(Font);
  Pad:=MulDiv(10,CurrentPPI,96); RowH:=MulDiv(24,CurrentPPI,96);
  with FPreview.Canvas do
  begin
    Brush.Color:=Palette.Colors[prWindow]; FillRect(FPreview.ClientRect);
    Font.Color:=Palette.Colors[prLink]; Font.Style:=[fsBold];
    TextOut(Pad,Pad,'Сведения о книге'); Font.Style:=[];
    Y:=Pad+RowH;
    R:=Rect(Pad,Y,FPreview.Width-Pad,Y+RowH*2);
    Brush.Color:=Palette.Colors[prField]; FillRect(R);
    Font.Color:=Palette.Colors[prText];
    TextOut(Pad*2,Y+2,'Автор — Название книги');
    Inc(R.Top,RowH); Brush.Color:=Palette.Colors[prSelection]; FillRect(R);
    Font.Color:=Palette.Colors[prSelectionText];
    TextOut(Pad*2,R.Top+2,'Выбранная книга');
  end;
end;

function EditInterfaceColors(Owner: TCustomForm; var Values: TMHLThemePalettes): Boolean;
var Dialog: TInterfaceColorsDialog;
begin
  Dialog:=TInterfaceColorsDialog.CreateFor(Owner,Values,MHLThemeDark);
  try
    Result:=Dialog.ShowModal=mrOk;
    if Result then Values:=Dialog.Values;
  finally Dialog.Free; end;
end;

end.
