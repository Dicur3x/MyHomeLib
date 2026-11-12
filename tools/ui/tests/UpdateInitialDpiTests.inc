// Simulate the form font state used when Windows starts at a high system DPI.
// This changes only this isolated fixture process, never Windows display settings.
type
  TInitialDpiUpdateForm = class(TfrmProgramUpdate)
  private
    FFixturePPI: Integer;
  protected
    function GetCurrentPPI: Integer; override;
    procedure InitializeLogicalFont; override;
  public
    procedure ScaleAtFixturePPI(PPI: Integer);
  end;
  TLegacyDpiUpdateForm = class(TInitialDpiUpdateForm)
  protected
    procedure InitializeLogicalFont; override;
  end;

procedure TLegacyDpiUpdateForm.InitializeLogicalFont;
begin
  // Reproduce the former constructor: high-system-DPI font pixels are copied
  // into a form whose child-control geometry is still at logical 96 DPI.
  Font.PixelsPerInch:=Screen.MessageFont.PixelsPerInch;
  Font.Assign(Screen.MessageFont);
end;

function TInitialDpiUpdateForm.GetCurrentPPI: Integer;
begin
  if FFixturePPI=0 then Result:=inherited GetCurrentPPI else Result:=FFixturePPI;
end;

procedure TInitialDpiUpdateForm.ScaleAtFixturePPI(PPI: Integer);
begin
  // VCL normally reports the physical monitor's DPI. Keep this modeless test
  // on its real monitor while exercising the requested layout and font scale.
  FFixturePPI:=PPI;
  ScaleForPPI(PPI);
end;

procedure TInitialDpiUpdateForm.InitializeLogicalFont;
begin
  Font.PixelsPerInch:=Screen.MessageFont.PixelsPerInch;
  Font.Height:=Screen.MessageFont.Height;
  inherited;
end;

procedure TestUpdateInitialDPI;
var SavedMessagePPI: Integer; SavedMessage: TFont; SavedDark: Boolean;
    Dialog: TfrmProgramUpdate; Notes: TUpdateNotesView; View: TListView;
    Info: TProgramRelease; Expected, Checks: Integer; Widths: TBitmap;
begin
  SavedMessage:=TFont.Create; SavedMessage.Assign(Screen.MessageFont);
  SavedMessagePPI:=Screen.MessageFont.PixelsPerInch; SavedDark:=MHLThemeDark;
  Widths:=TBitmap.Create; Checks:=0;
  try
    Screen.MessageFont.PixelsPerInch:=216;
    Screen.MessageFont.Height:=-27;
    Dialog:=TLegacyDpiUpdateForm.Create(nil);
    try
      TLegacyDpiUpdateForm(Dialog).ScaleAtFixturePPI(216);
      Require(Abs(Dialog.Font.Height)>45,'Legacy startup font did not reproduce double scaling');
      Writeln('PASS legacy initial 225-percent font reproduces the reported double scaling');
    finally Dialog.Free; end;
    for var Dark in [False,True] do
      for var DPI in [96,144,192,216,240,288] do
      begin
        Screen.MessageFont.PixelsPerInch:=DPI;
        Screen.MessageFont.Height:=-MulDiv(9,DPI,72);
        SetMHLTheme(Dark);
        Dialog:=TInitialDpiUpdateForm.Create(nil);
        Dialog.Caption:='Обновление HomeLibre — проверка масштаба';
        try
          Info:=Default(TProgramRelease); Info.Tag:=PROGRAM_RELEASE_VERSION;
          Info.History:=PROGRAM_RELEASE_VERSION+#10+'## Проверка масштаба'+#10+'Текст обновления.';
          Dialog.SetCurrent(Info);
          Notes:=nil;
          for var Control in Dialog do
            if Control is TUpdateNotesView then Notes:=TUpdateNotesView(Control);
          Require(Assigned(Notes),'High-DPI updater notes missing');
          Notes.ZoomPercent:=100;
          TInitialDpiUpdateForm(Dialog).ScaleAtFixturePPI(DPI);
          Require(Dialog.CurrentPPI=DPI,Format('Updater fixture DPI changed: requested=%d actual=%d fontPPI=%d fontHeight=%d scaled=%d',
            [DPI,Dialog.CurrentPPI,Dialog.Font.PixelsPerInch,Dialog.Font.Height,Ord(Dialog.Scaled)]));
          Expected:=MulDiv(12,DPI,96);
          Require(Abs(Abs(Dialog.Font.Height)-Expected)<=1,
            Format('Updater initial font scaled twice at %d DPI: height=%d expected=%d',
              [DPI,Dialog.Font.Height,Expected]));
          View:=Dialog.FindComponent('UpdateComponents') as TListView;
          Require(Abs(Abs(View.Font.Height)-Expected)<=1,'Updater component list font scaled twice');
          Require(Abs(Notes.SectionHeader(0).Font.Size-12)<=1,'Updater release heading scaled twice');
          Require(Abs(Notes.SectionNotes(0).Font.Size-10)<=1,'Updater release text scaled twice');
          for var Control in Dialog do
            if Control is TButton then
            begin
              var Button:=TButton(Control);
              if not Button.Visible then Continue;
              Widths.Canvas.Font.Assign(Button.Font);
              Require(Button.Width>=Widths.Canvas.TextWidth(Button.Caption)+MulDiv(12,DPI,96),
                Format('Updater button caption clipped at %d DPI: %s width=%d text=%d',
                  [DPI,Button.Caption,Button.Width,Widths.Canvas.TextWidth(Button.Caption)]));
              Require(Button.BoundsRect.Right<=Dialog.ClientWidth,'Updater button outside client width');
            end;
          Inc(Checks);
          Writeln(Format('PASS initial updater DPI=%d dark=%d font-height=%d heading=%d',
            [DPI,Ord(Dark),Dialog.Font.Height,Notes.SectionHeader(0).Font.Size]));
        finally Dialog.Free; end;
      end;
    Require(Checks=12,'Missing initial DPI cases');
  finally
    Screen.MessageFont.PixelsPerInch:=SavedMessagePPI;
    Screen.MessageFont.Assign(SavedMessage);
    SavedMessage.Free; Widths.Free; SetMHLTheme(SavedDark);
  end;
end;
