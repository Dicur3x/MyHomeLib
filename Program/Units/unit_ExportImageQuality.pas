unit unit_ExportImageQuality;

interface

uses unit_BookConversion;

function ChooseExportImageQuality(const Title: string; const Options: TBookImageQualityOptions;
  MultipleBooks: Boolean; out ApplyToAll: Boolean): string;

implementation

uses System.SysUtils, System.Classes, System.Math, Winapi.Windows, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.Dialogs, Vcl.ExtCtrls, unit_MHLTheme, dm_user;

type
  TExportImageQualityForm = class(TForm)
    procedure ScaleForPPI(NewPPI: Integer); override;
  end;
  TQualityScrollBox = class(TScrollBox)
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  end;
  TScanLayoutController = class
    Options: TBookImageQualityOptions;
    Choices: array[0..3] of TRadioButton;
    Layout: TComboBox;
    Exclusions: TEdit;
    Dialog: TForm;
    Content: TScrollBox;
    Reflowing: Boolean;
    procedure Change(Sender: TObject);
    procedure Save(Sender: TObject);
    procedure Reflow(Sender: TObject);
  end;

procedure TExportImageQualityForm.ScaleForPPI(NewPPI: Integer);
var OldPPI, W, H: Integer;
begin
  OldPPI:=PixelsPerInch; W:=ClientWidth; H:=ClientHeight;
  inherited;
  if (OldPPI>0) and (NewPPI<>OldPPI) then
  begin ClientWidth:=MulDiv(W,NewPPI,OldPPI); ClientHeight:=MulDiv(H,NewPPI,OldPPI); end;
end;

function TQualityScrollBox.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if VertScrollBar.Range>ClientHeight then
  begin VertScrollBar.Position:=VertScrollBar.Position-WheelDelta div WHEEL_DELTA*MulDiv(48,CurrentPPI,96); Result:=True; end
  else Result:=inherited;
end;

function QualitySizeCaption(Value: Int64): string;
begin
  if Value>=1024*1024 then Result:=FormatFloat('0.0',Value/1024/1024)+' МБ'
  else Result:=FormatFloat('0',Value/1024)+' КБ';
end;

procedure TScanLayoutController.Change(Sender: TObject);
var High, Balanced, Economy: Int64;
begin
  High:=Options.HighBytes; Balanced:=Options.BalancedBytes; Economy:=Options.EconomyBytes;
  if Assigned(Layout) and (Layout.ItemIndex=1) then
  begin High:=Options.AutoHighBytes; Balanced:=Options.AutoBalancedBytes; Economy:=Options.AutoEconomyBytes; end;
  if Assigned(Layout) and (Layout.ItemIndex=2) then
  begin High:=Options.SplitHighBytes; Balanced:=Options.SplitBalancedBytes; Economy:=Options.SplitEconomyBytes; end;
  Choices[0].Caption:='Высокое качество · ≈ '+QualitySizeCaption(High);
  Choices[1].Caption:='Сбалансированный · ≈ '+QualitySizeCaption(Balanced);
  Choices[2].Caption:='Экономный · ≈ '+QualitySizeCaption(Economy);
  Choices[3].Enabled:=(Options.NoImagesBytes>0) and not Options.ScanPages;
  if Choices[3].Enabled then Choices[3].Caption:='Без изображений · ≈ '+QualitySizeCaption(Options.NoImagesBytes)
  else Choices[3].Caption:='Без изображений — недоступно для сканов';
  if Assigned(Layout) then Layout.Enabled:=not Choices[3].Checked;
  if Assigned(Exclusions) then Exclusions.Enabled:=Assigned(Layout) and Layout.Enabled and (Layout.ItemIndex>0);
end;

procedure TScanLayoutController.Reflow(Sender: TObject);
var Y, Margin, Indent, H, W, SavedScroll: Integer; Bounds: TRect;
begin
  if Reflowing or not Assigned(Content) then Exit;
  Reflowing:=True;
  try
    Margin:=MulDiv(20,Dialog.PixelsPerInch,96); SavedScroll:=Content.VertScrollBar.Position;
    Content.VertScrollBar.Position:=0;
    // A scrollbar can change the available width. Measure once more afterwards
    // so text remains complete at fractional DPI and in a smaller window.
    for var Pass:=1 to 2 do
    begin
      Y:=MulDiv(16,Dialog.PixelsPerInch,96);
      for var I:=0 to Content.ControlCount-1 do
      begin
        var Control:=Content.Controls[I]; if not Control.Visible then Continue;
        Indent:=Margin;
        if (Control is TLabel) and (I>0) and (Content.Controls[I-1] is TRadioButton) then
          Inc(Indent,MulDiv(22,Dialog.PixelsPerInch,96));
        W:=Max(1,Content.ClientWidth-Indent-Margin);
        if Control is TLabel then
        begin
          var LabelControl:=TLabel(Control); LabelControl.AutoSize:=False; LabelControl.WordWrap:=True;
          Dialog.Canvas.Font.Assign(LabelControl.Font); Bounds:=Rect(0,0,W,0);
          DrawText(Dialog.Canvas.Handle,PChar(LabelControl.Caption),Length(LabelControl.Caption),Bounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
          H:=Bounds.Height+MulDiv(2,Dialog.PixelsPerInch,96);
        end
        else if (Control is TEdit) or (Control is TComboBox) then H:=MulDiv(25,Dialog.PixelsPerInch,96)
        else H:=MulDiv(24,Dialog.PixelsPerInch,96);
        if (Control is TRadioButton) or (Control is TCheckBox) then Inc(Y,MulDiv(8,Dialog.PixelsPerInch,96));
        Control.SetBounds(Indent,Y,W,H); Inc(Y,H+MulDiv(6,Dialog.PixelsPerInch,96));
      end;
      Content.VertScrollBar.Range:=Y+Margin;
    end;
    Content.VertScrollBar.Position:=SavedScroll;
  finally Reflowing:=False; end;
end;

procedure TScanLayoutController.Save(Sender: TObject);
begin
  if Assigned(Exclusions) and Exclusions.Enabled and not IsValidScanPageExclusions(Exclusions.Text) then
  begin
    MessageDlg('Укажите номера сканов через запятую или диапазон: 1, 2, 98-100. Допустимы номера от 1 до 5000.',mtInformation,[mbOK],0);
    Exclusions.SetFocus; Exit;
  end;
  Dialog.ModalResult:=mrOk;
end;

function ChooseExportImageQuality(const Title: string; const Options: TBookImageQualityOptions;
  MultipleBooks: Boolean; out ApplyToAll: Boolean): string;
var Dialog: TForm; Heading, NoteText, Detail: TLabel; Choices: array[0..3] of TRadioButton;
  AllBooks: TCheckBox; SaveButton, CancelButton: TButton; I: Integer;
  Layout: TComboBox; Controller: TScanLayoutController; Offset, Gap, BottomOffset: Integer;
  Content: TQualityScrollBox; Footer: TPanel;
begin
  Result:=''; ApplyToAll:=False;
  Dialog:=TExportImageQualityForm.CreateNew(Application);
  Controller:=TScanLayoutController.Create; Controller.Options:=Options; Controller.Dialog:=Dialog;
  Layout:=nil; Offset:=0; Gap:=68; BottomOffset:=0;
  try
    Dialog.Caption:='Качество изображений · '+Options.TargetFormat;
    Dialog.Position:=poMainFormCenter; Dialog.BorderStyle:=bsSizeable;
    Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=9; Dialog.ClientWidth:=640; Dialog.ClientHeight:=490;
    Dialog.Constraints.MinWidth:=640+Dialog.Width-Dialog.ClientWidth;
    Dialog.Constraints.MinHeight:=260+Dialog.Height-Dialog.ClientHeight;
    Footer:=TPanel.Create(Dialog); Footer.Parent:=Dialog; Footer.Align:=alBottom;
    Footer.BevelOuter:=bvNone; Footer.Height:=50;
    Content:=TQualityScrollBox.Create(Dialog); Content.Parent:=Dialog; Content.Align:=alClient;
    Controller.Content:=Content;
    Content.BorderStyle:=bsNone; Content.HorzScrollBar.Visible:=False; Content.VertScrollBar.Tracking:=True;
    Heading:=TLabel.Create(Dialog); Heading.Parent:=Content;
    Heading.SetBounds(20,16,580,45); Heading.AutoSize:=False; Heading.WordWrap:=True;
    Heading.Caption:='Выберите качество изображений для книги «'+Title+'».';
    Heading.ShowAccelChar:=False; Heading.Hint:=Title; Heading.ShowHint:=True;
    if Options.ScanPages then
    begin
      Offset:=140; Gap:=60; BottomOffset:=Offset-24; Dialog.ClientHeight:=630;
      Detail:=TLabel.Create(Dialog); Detail.Parent:=Content; Detail.SetBounds(20,72,580,18);
      Detail.Caption:='Страницы на сканах:';
      Layout:=TComboBox.Create(Dialog); Layout.Parent:=Content; Layout.Style:=csDropDownList;
      Layout.SetBounds(20,94,580,25);
      Layout.Items.Add('Не разделять — оставить сканы как в книге');
      Layout.Items.Add('Разделять автоматически — по сгибу или промежутку между страницами');
      Layout.Items.Add('Разделять строго по центру'); Layout.ItemIndex:=0;
      Detail:=TLabel.Create(Dialog); Detail.Parent:=Content; Detail.SetBounds(20,124,580,18);
      Detail.Caption:='Не разделять сканы № (например: 1, 2, 98-100):';
      Controller.Exclusions:=TEdit.Create(Dialog); Controller.Exclusions.Parent:=Content;
      Controller.Exclusions.SetBounds(20,145,580,25); Controller.Exclusions.MaxLength:=256;
      Controller.Exclusions.Hint:='Номера исходных сканов, начиная с 1. Например, горизонтальная обложка, вклейка или широкая таблица.';
      Controller.Exclusions.ShowHint:=True;
      Detail:=TLabel.Create(Dialog); Detail.Parent:=Content; Detail.AutoSize:=False; Detail.WordWrap:=True;
      Detail.SetBounds(20,175,580,30);
      Detail.Caption:='Автоматический режим ищет границу на каждом развороте. Если уверенной границы нет, скан остаётся целым. Вертикальные страницы не разделяются.';
      Controller.Layout:=Layout; Layout.OnChange:=Controller.Change;
    end;
    for I:=0 to 3 do
    begin
      Choices[I]:=TRadioButton.Create(Dialog); Choices[I].Parent:=Content;
      Choices[I].SetBounds(20,75+Offset+I*Gap,580,25); Choices[I].TabOrder:=I+2*Ord(Options.ScanPages);
      Controller.Choices[I]:=Choices[I]; Choices[I].OnClick:=Controller.Change;
      Detail:=TLabel.Create(Dialog); Detail.Parent:=Content;
      Detail.SetBounds(42,103+Offset+I*Gap,555,32); Detail.AutoSize:=False; Detail.WordWrap:=True;
      case I of
        0: begin
          Detail.Caption:='Максимум деталей. Разрешение страниц сохраняется.'; end;
        1: begin
          Detail.Caption:='Чёткие изображения с умеренным сжатием. Рекомендуется.'; end;
        2: begin
          Detail.Caption:='Компактные сканы для чтения. Текстовые страницы и цветные иллюстрации сжимаются по-разному.'; end;
        3: begin
          if Options.ScanPages or (Options.NoImagesBytes<=0) then
            Detail.Caption:='Изображения содержат сами страницы. Без них книга станет пустой; сначала нужно распознать текст.'
          else Detail.Caption:='Только текст, без обложки и иллюстраций. Подходит для слабых читалок.'; end;
      end;
    end;
    Choices[1].Checked:=True;
    Controller.Change(nil);
    NoteText:=TLabel.Create(Dialog); NoteText.Parent:=Content;
    NoteText.SetBounds(20,288+BottomOffset,580,42); NoteText.AutoSize:=False; NoteText.WordWrap:=True;
    NoteText.Caption:=Format('Примерный размер %s: оценка по %d из %d изображений. Итог может отличаться. Исходная книга сохранится.',
      [Options.TargetFormat,Options.SampleCount,Options.ImageCount]);
    if Options.SampleCount=0 then NoteText.Caption:='Картинки сохранятся без повторного сжатия. Можно удалить обложку и иллюстрации, выбрав «Без изображений». Исходная книга сохранится.';
    if Options.FirstSamples then NoteText.Caption:=Format('Примерный размер %s: оценка по первым %d сканам для %d страниц. Состав следующих страниц может отличаться. Исходная книга сохранится.',
      [Options.TargetFormat,Options.SampleCount,Options.ImageCount]);
    AllBooks:=TCheckBox.Create(Dialog); AllBooks.Parent:=Content;
    AllBooks.SetBounds(20,337+BottomOffset,580,22); AllBooks.Caption:='Использовать эти настройки для остальных выбранных книг';
    AllBooks.Visible:=MultipleBooks; AllBooks.Checked:=True;
    SaveButton:=TButton.Create(Dialog); SaveButton.Parent:=Dialog;
    SaveButton.SetBounds(340,10,155,28); SaveButton.Caption:='Сохранить книгу';
    SaveButton.OnClick:=Controller.Save; SaveButton.Default:=True;
    CancelButton:=TButton.Create(Dialog); CancelButton.Parent:=Dialog;
    CancelButton.SetBounds(507,10,113,28); CancelButton.Caption:='Отмена';
    CancelButton.ModalResult:=mrCancel; CancelButton.Cancel:=True;
    SaveButton.Parent:=Footer; CancelButton.Parent:=Footer;
    SaveButton.Anchors:=[akRight,akBottom]; CancelButton.Anchors:=[akRight,akBottom];
    for I:=0 to Content.ControlCount-1 do Content.Controls[I].Anchors:=[akLeft,akTop];
    Content.OnResize:=Controller.Reflow;
    if Settings.ExportImageQualityWidth>0 then Dialog.ClientWidth:=EnsureRange(Settings.ExportImageQualityWidth,640,2400);
    if Settings.ExportImageQualityHeight>0 then Dialog.ClientHeight:=EnsureRange(Settings.ExportImageQualityHeight,260,1800);
    Dialog.ScaleForPPI(Screen.PixelsPerInch);
    Dialog.Width:=Min(Dialog.Width,Screen.WorkAreaWidth); Dialog.Height:=Min(Dialog.Height,Screen.WorkAreaHeight);
    ApplyMHLControlTheme(Dialog);
    Controller.Reflow(nil);
    if Dialog.ShowModal<>mrOk then Exit;
    if Choices[3].Checked then Result:='none'
    else if Choices[0].Checked then Result:='high'
    else if Choices[2].Checked then Result:='economy' else Result:='balanced';
    if (Result<>'none') and Assigned(Layout) and (Layout.ItemIndex>0) then
    begin
      if Layout.ItemIndex=1 then Result:=Result+'|auto' else Result:=Result+'|split';
      if string(Controller.Exclusions.Text).Trim<>'' then Result:=Result+'|except='+string(Controller.Exclusions.Text).Trim;
    end;
    ApplyToAll:=MultipleBooks and AllBooks.Checked;
  finally
    if (Dialog.PixelsPerInch>0) and (Dialog.WindowState=wsNormal) then
    begin
      Settings.ExportImageQualityWidth:=MulDiv(Dialog.ClientWidth,96,Dialog.PixelsPerInch);
      Settings.ExportImageQualityHeight:=MulDiv(Dialog.ClientHeight,96,Dialog.PixelsPerInch);
    end;
    Controller.Free; Dialog.Free;
  end;
end;

end.
