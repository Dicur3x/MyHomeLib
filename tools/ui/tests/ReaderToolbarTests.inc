procedure AuditReaderToolbar;
const WindowWidths: array[0..2] of Integer = (640,820,1280);
var Reader: TfrmBuiltinReader; Toolbar, Row: TPanel; Button: TReaderPaletteButton;
  Bitmap: TBitmap; FileName, Name: string; R, Overlap, InitialBounds: TRect;
  Position: Integer; Key: Word; Controls: TList<TControl>;
begin
  if FileExists('reader-toolbar-preview.flag') then
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook('words.fb2','HomeLibre — оформление чтения','toolbar-preview','toolbar-preview.ini','pdfium.dll');
      WaitReady(Reader); Reader.SetBounds(80,80,640,680);
      Reader.SetTypography('Georgia',118,36); Reader.SetPageLayout(rplDouble);
      Reader.SetPageAppearance(rpaBook); Reader.SetTheme(1); WaitPage(Reader);
      Reader.ShowInTaskBar:=True; Reader.Hide; Reader.Show; Reader.BringToFront;
      var Started:=GetTickCount64;
      while Reader.Visible and (GetTickCount64-Started<180000) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(20); end;
      Writeln('PASS interactive toolbar preview');
    finally Reader.Free; end;
    Exit;
  end;
  Controls:=TList<TControl>.Create; Bitmap:=TBitmap.Create;
  try
    for FileName in ['words.fb2','words.pdf'] do
    begin
      Reader:=TfrmBuiltinReader.Create(nil);
      try
        Reader.Show; Reader.OpenBook(FileName,'Панель чтения',FileName,'toolbar-'+FileName+'.ini','pdfium.dll');
        WaitReady(Reader); Toolbar:=Reader.FindComponent('ReaderToolbar') as TPanel;
        Row:=TPanel(TControl(Reader.FindComponent('ReaderSavedItems')).Parent);
        for var PPI in [96,144,192] do
        begin
          for var Width in WindowWidths do
          begin
            for var Theme in [1,4] do
            begin
              // Apply the real monitor's theme/handle changes before forcing
              // each synthetic DPI; pumping after ScaleForPPI would let Windows
              // restore the actual monitor DPI instead of testing this value.
              Reader.ScaleForPPI(96); Reader.SetTheme(Theme); Application.ProcessMessages;
              Reader.SetBounds(40,40,Width,680);
              Reader.ScaleForPPI(PPI);
              Require(Reader.Font.PixelsPerInch=PPI,Format('Synthetic font scale not applied: %d/%d',[PPI,Reader.Font.PixelsPerInch])); Controls.Clear;
              for Name in ['ReaderPrevious','ReaderNext','ReaderSmaller','ReaderLarger',
                'ReaderThemeSelector','ReaderAddBookmark','ReaderAddNote','ReaderSavedItems',
                'ReaderAppearance','ReaderSearch','ReaderFitPage'] do
              begin
                var Control:=Reader.FindComponent(Name) as TControl;
                Require(Assigned(Control),'Named toolbar control absent: '+Name);
                if not Control.Visible then Continue;
                R:=Control.BoundsRect;
                Require((R.Left>=0) and (R.Top>=0) and (R.Right<=Row.ClientWidth) and
                  (R.Bottom<=Row.ClientHeight),'Toolbar clipped: '+Name+' DPI '+PPI.ToString+' width '+Width.ToString);
                for var Other in Controls do Require(not IntersectRect(Overlap,R,Other.BoundsRect),
                  'Toolbar controls overlap: '+Name+' / '+Other.Name);
                Controls.Add(Control);
                if Control is TReaderPaletteButton then
                begin
                  Button:=TReaderPaletteButton(Control);
                  Require(Button.Toolbar,'Toolbar reverted to an unrelated dialog button style');
                  Require(Button.ShowHint and (Button.Hint<>''),'Toolbar action has no explanation: '+Name);
                  if not Button.IconOnly then
                  begin
                    Bitmap.Canvas.Font.Assign(Button.Font);
                    var Needed:=Bitmap.Canvas.TextWidth(Button.Caption)+MulDiv(12,PPI,96);
                    if Button.Icon<>rciNone then Inc(Needed,MulDiv(27,PPI,96));
                    Require(Needed<=Button.Width,Format('Toolbar caption clipped: %s needs %d has %d DPI %d/%d width %d font %d',[Name,Needed,Button.Width,PPI,Reader.CurrentPPI,Width,Button.Font.Size]));
                  end;
                end;
              end;
              Require(Controls.Count>=10,'Toolbar unexpectedly hides primary commands');
              Require(Reader.ReadingSurface.Top>=Toolbar.Top+Toolbar.Height,Format('Book overlaps wrapped controls: surface %d toolbar %d+%d row %d DPI %d/%d width %d',[Reader.ReadingSurface.Top,Toolbar.Top,Toolbar.Height,Row.Height,PPI,Reader.CurrentPPI,Width]));
            end;
          end;
        end;
        Writeln('PASS '+FileName+' all toolbar commands fit without overlap at 640/820/1280 and 96/144/192 DPI in paper/night palettes');
        Reader.ScaleForPPI(96); Reader.SetBounds(40,40,640,480); WaitPage(Reader);
        Position:=Reader.TextPosition; InitialBounds:=Reader.BoundsRect;
        TButton(Reader.FindComponent('ReaderHideInterface')).Click; Application.ProcessMessages;
        Require(Reader.InterfaceHidden and not Reader.FullScreenMode and (Reader.BoundsRect=InitialBounds),
          'Hide interface changed window size or entered full screen');
        TButton(Reader.FindComponent('ReaderShowInterface')).Click; Application.ProcessMessages;
        Require(not Reader.InterfaceHidden and (Reader.TextPosition=Position),'Interface restore lost position');
        TButton(Reader.FindComponent('ReaderFullScreen')).Click; Application.ProcessMessages;
        Require(Reader.FullScreenMode and not Reader.InterfaceHidden,'Full screen unexpectedly hides controls');
        Key:=VK_F11; Reader.OnKeyDown(Reader,Key,[]); Application.ProcessMessages;
        Require(not Reader.FullScreenMode and not Reader.InterfaceHidden and (Reader.BoundsRect=InitialBounds),
          'F11 did not restore the resized window');
        Writeln('PASS '+FileName+' hide/show remains independent from full screen and F11');
      finally Reader.Free; end;
    end;
  finally Bitmap.Free; Controls.Free; end;
end;
