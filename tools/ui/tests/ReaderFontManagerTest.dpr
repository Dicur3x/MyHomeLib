program ReaderFontManagerTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses NativeRegressionGuard, System.SysUtils, System.Classes, System.Types,
  System.Math, System.IOUtils, System.IniFiles, Winapi.Windows, Winapi.Messages,
  Winapi.CommCtrl, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.Graphics, Vcl.ExtCtrls, Vcl.Imaging.pngimage,
  frm_ReaderFontManager, unit_ReaderFonts, unit_ReaderPalette, unit_ContextToolGuide;

procedure Require(Value:Boolean; const Detail:string);
begin if not Value then raise Exception.Create(Detail); end;

procedure ScaleNativeDialog(Dialog:TForm; NewPPI:Integer);
var BeforePPI,BeforeWidth,BeforeHeight:Integer; Anchors:TArray<TAnchors>;
begin
  // Scale the real native controls and outer window together. These are VCL
  // layout-scale checks, not a claim of a separate physical high-DPI monitor.
  Require(not Dialog.AutoScroll,'Whole-dialog scrolling interferes with font preview/list scrolling');
  BeforePPI:=Dialog.PixelsPerInch; BeforeWidth:=Dialog.ClientWidth; BeforeHeight:=Dialog.ClientHeight;
  if BeforePPI=NewPPI then Exit;
  SetLength(Anchors,Dialog.ControlCount);
  for var I:=0 to Dialog.ControlCount-1 do
  begin Anchors[I]:=Dialog.Controls[I].Anchors; Dialog.Controls[I].Anchors:=[akLeft,akTop]; end;
  try
    Dialog.ScaleForPPI(NewPPI);
    // The physical monitor remains at its real DPI. Supply the outer resize
    // normally supplied by Windows; retain the child bounds just scaled by VCL.
    Dialog.ClientWidth:=MulDiv(BeforeWidth,NewPPI,BeforePPI);
    Dialog.ClientHeight:=MulDiv(BeforeHeight,NewPPI,BeforePPI);
  finally
    for var I:=0 to Dialog.ControlCount-1 do Dialog.Controls[I].Anchors:=Anchors[I];
  end;
  Require(Dialog.Font.PixelsPerInch=NewPPI,'VCL layout font did not adopt the requested DPI');
  Dialog.Update;
end;

type
  TFontDialogProbe=class
    Timer:TTimer;
    DPI,Visits:Integer;
    Dark:Boolean;
    Profile,ChosenFamily:string;
    procedure Tick(Sender:TObject);
    procedure Fail(Sender:TObject; E:Exception);
    procedure CheckPreview(Dialog:TForm; const Prefix:string);
    procedure Snapshot(Dialog:TForm; const Suffix:string);
  end;

procedure TFontDialogProbe.Fail(Sender:TObject; E:Exception);
begin Writeln('FAIL ',E.ClassName,': ',E.Message); Flush(Output); ExitProcess(1); end;

procedure TFontDialogProbe.Snapshot(Dialog:TForm; const Suffix:string);
var Bitmap:TBitmap; Png:TPngImage;
begin
  if (DPI<>96) and (DPI<>144) and (DPI<>216) and (DPI<>288) then Exit;
  Bitmap:=Dialog.GetFormImage; Png:=TPngImage.Create;
  try
    Png.Assign(Bitmap);
    Png.SaveToFile(ExtractFilePath(ParamStr(0))+Format('fonts-%s-%d-dark-%d.png',[Suffix,DPI,Ord(Dark)]));
  finally Png.Free; Bitmap.Free; end;
end;

procedure TFontDialogProbe.CheckPreview(Dialog:TForm; const Prefix:string);
var Area:TPanel; Preview:TLabel; Bounds:TRect; DC:HDC; Saved,X:Integer; WheelPoint:TPoint;
  Raster:TBitmap; ThumbPixel:COLORREF;
begin
  Area:=Dialog.FindComponent(Prefix+'Area') as TPanel;
  Preview:=Area.FindComponent(Prefix) as TLabel;
  Require(Assigned(Area) and Assigned(Preview),'Missing scrollable font preview');
  Require(ColorToRGB(Area.Color)=ColorToRGB(Dialog.Color),'Preview area lost the reader palette');
  Preview.Font.Size:=48;
  // Resize invokes the production layout callback with the actual font metrics.
  Area.Width:=Area.Width-1; Area.Width:=Area.Width+1;
  DC:=GetDC(Area.Handle); Saved:=SaveDC(DC);
  try
    SelectObject(DC,Preview.Font.Handle); Bounds:=Rect(0,0,Preview.Width,0);
    DrawText(DC,PChar(Preview.Caption),Length(Preview.Caption),Bounds,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Require(Preview.Height>=Bounds.Height,'Font preview clips its measured last line');
  finally RestoreDC(DC,Saved); ReleaseDC(Area.Handle,DC); end;
  Require(Area.TabStop and (Preview.Height>Area.ClientHeight),'A large font sample has no vertical scrolling');
  Area.SetFocus;
  WheelPoint:=Area.ClientToScreen(Point(4,4));
  Area.Perform(WM_MOUSEWHEEL,MakeWParam(0,Word(SmallInt(-WHEEL_DELTA))),MakeLParam(WheelPoint.X,WheelPoint.Y));
  Require(Preview.Top<0,'The mouse wheel did not move the font sample');
  Area.Perform(WM_KEYDOWN,VK_END,0);
  Require((Preview.Top<0) and (Preview.Top+Preview.Height=Area.ClientHeight),
    'The final line of a large font sample cannot be reached with the keyboard');
  Area.Perform(WM_KEYDOWN,VK_HOME,0);
  Require(Preview.Top=0,'Home did not return to the first line');
  X:=Area.ClientWidth-MulDiv(6,Area.CurrentPPI,96);
  Raster:=TBitmap.Create;
  try
    Raster.SetSize(Area.ClientWidth,Area.ClientHeight);
    Area.PaintTo(Raster.Canvas,0,0);
    ThumbPixel:=GetPixel(Raster.Canvas.Handle,X,1);
    Require((ThumbPixel=ColorToRGB(ReaderBlendColor(Area.Color,Area.Font.Color,132))) or
      (ThumbPixel=ColorToRGB(ReaderBlendColor(Area.Color,Area.Font.Color,176))),
      'The preview thumb does not use the dialog palette');
    Require(GetPixel(Raster.Canvas.Handle,X,Area.ClientHeight-2)=ColorToRGB(ReaderBlendColor(Area.Color,Area.Font.Color,36)),
      'The preview track does not use the dialog palette');
  finally Raster.Free; end;
  Area.Perform(WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(X,1));
  Area.Perform(WM_MOUSEMOVE,MK_LBUTTON,MakeLParam(X,Area.ClientHeight-1));
  Area.Perform(WM_LBUTTONUP,0,MakeLParam(X,Area.ClientHeight-1));
  Require(Preview.Top+Preview.Height=Area.ClientHeight,'Dragging the thumb did not reach the final line');
  Area.Perform(WM_KEYDOWN,VK_HOME,0);
end;

procedure TFontDialogProbe.Tick(Sender:TObject);
var Dialog,Picker:TForm; List:TListView; Names:TListBox; Search:TEdit;
  Preview:TLabel; Header:HWND; Bounds:TRect; DC:HDC; Pixel:COLORREF;
  Selected,Longest:string; Maximum,Ink:Integer; Item:TListItem;
begin
  Timer.Enabled:=False;
  Dialog:=nil; Picker:=nil;
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible and (fsModal in Screen.Forms[I].FormState) then
      if Screen.Forms[I].Name='ReaderFontManager' then Dialog:=Screen.Forms[I]
      else if Screen.Forms[I].Name='ReaderWindowsFontsDialog' then Picker:=Screen.Forms[I];
  if Assigned(Picker) then
  begin
    ScaleNativeDialog(Picker,DPI);
    Require(Abs(Picker.Font.Size-9)<=1,Format('Picker font scaled twice: PPI=%d size=%d fontPPI=%d',
      [Picker.CurrentPPI,Picker.Font.Size,Picker.Font.PixelsPerInch]));
    Search:=Picker.FindComponent('ReaderWindowsFontSearch') as TEdit;
    Names:=Picker.FindComponent('ReaderWindowsFontResults') as TListBox;
    Require((Picker.BorderStyle=bsSizeable) and Assigned(Search) and Assigned(Names),
      'Windows font picker is not resizable/searchable');
    Require((ColorToRGB(Search.Color)=ColorToRGB(Picker.Color)) and
      (ColorToRGB(Names.Color)=ColorToRGB(Picker.Color)),'Windows font controls lost their reader colours');
    Require(Names.Count>0,'Windows fonts were not enumerated');
    Picker.Canvas.Font.Assign(Names.Font); Maximum:=0; Longest:='';
    for var Family in Names.Items do
      if Picker.Canvas.TextWidth(Family)>Maximum then
      begin Maximum:=Picker.Canvas.TextWidth(Family); Longest:=Family; end;
    Require(Names.ScrollWidth>=Maximum,'Horizontal extent clips a Windows font family name: '+Longest);
    Search.Text:='NoSuchHomeLibreFont-538246';
    Require((Names.Count=0) and not TButton(Picker.FindComponent('ReaderWindowsFontAdd')).Enabled,
      'Empty font search can still add a font');
    Preview:=Picker.FindComponent('ReaderWindowsFontPreviewArea').FindComponent('ReaderWindowsFontPreview') as TLabel;
    Require((Preview.Font.Name=Picker.Font.Name) and (Preview.Font.Size=Picker.Font.Size),
      'Empty search retained the decorative sample font');
    Search.Text:=ChosenFamily;
    Require(Names.Items.IndexOf(ChosenFamily)>=0,'Search did not find the chosen real Windows font');
    Names.ItemIndex:=Names.Items.IndexOf(ChosenFamily); Names.OnClick(Names);
    Snapshot(Picker,'windows'); CheckPreview(Picker,'ReaderWindowsFontPreview');
    var BeforeWidth:=Names.Width;
    Picker.ClientWidth:=Picker.ClientWidth+MulDiv(120,DPI,96);
    Require(Names.Width>BeforeWidth,'Enlarging the Windows picker does not widen the list');
    Picker.ClientHeight:=Picker.ClientHeight+MulDiv(80,DPI,96);
    Require(Search.Left+Search.Width<=Picker.ClientWidth,'Search field extends outside the enlarged picker');
    TButton(Picker.FindComponent('ReaderWindowsFontAdd')).Click;
    Exit;
  end;
  Require(Assigned(Dialog),'Expected the actual Reader font manager');
  ScaleNativeDialog(Dialog,DPI);
  Require(Abs(Dialog.Font.Size-9)<=1,'Font manager interface font scaled twice');
  var Help:=Dialog.FindComponent('ReaderFontsContextGuide') as TContextToolGuide;
  Require(Assigned(Help) and Help.HelpButton.Visible and
    (TControl(Dialog.FindComponent('ReaderFontsIntro')).BoundsRect.Right<=Help.HelpButton.Left),
    'Font manager help overlaps its introduction');
  Help.HelpButton.Click;
  var HelpWindow:=Help.FindComponent('ToolGuidePopupreaderfonts') as TForm;
  Require(HelpWindow.Visible and (HelpWindow.Color=Dialog.Color) and
    (HelpWindow.Font.Color=Dialog.Font.Color),'Font guide palette differs from the reader dialog');
  var Guide:=HelpWindow.FindComponent('ToolFirstUseGuide');
  Require(not TButton(Guide.FindComponent('GuideMore')).Visible,
    'Standalone fonts guide offered an unavailable help article');
  TButton(Guide.FindComponent('GuideToggle')).Click;
  Require(not HelpWindow.Visible,'Font guide did not close');
  List:=Dialog.FindComponent('ReaderFontLibrary') as TListView;
  Require(Assigned(List) and Assigned(List.Selected),'Font library is empty');
  Require(not TButton(Dialog.FindComponent('ReaderRemoveFont')).Enabled,
    'The default reading font can be removed');
  Header:=ListView_GetHeader(List.Handle); Require(Header<>0,'Font library has no native header');
  RedrawWindow(Header,nil,0,RDW_INVALIDATE or RDW_UPDATENOW);
  Snapshot(Dialog,'library');
  GetClientRect(Header,Bounds); DC:=GetDC(Header);
  try
    Pixel:=GetPixel(DC,Min(Bounds.Right-4,List.Columns[0].Width-8),Bounds.Height div 2);
    Require(Pixel=COLORREF(ColorToRGB(List.Color)),Format('Native font header uses another background: DPI=%d dark=%d pixel=%x expected=%x',
      [DPI,Ord(Dark),Pixel,ColorToRGB(List.Color)]));
    Pixel:=GetPixel(DC,Bounds.Right-4,Bounds.Height div 2);
    Require(Pixel=COLORREF(ColorToRGB(List.Color)),Format('Native header tail differs: DPI=%d dark=%d pixel=%x expected=%x width=%d height=%d columns=%d',
      [DPI,Ord(Dark),Pixel,ColorToRGB(List.Color),Bounds.Width,Bounds.Height,
       List.Columns[0].Width+List.Columns[1].Width+List.Columns[2].Width]));
    Ink:=0;
    for var Y:=3 to Bounds.Height-4 do
      for var X:=12 to Min(List.Columns[0].Width-12,Bounds.Right-12) do
      begin
        Pixel:=GetPixel(DC,X,Y);
        if (Pixel<>CLR_INVALID) and (Pixel=COLORREF(ColorToRGB(List.Font.Color))) then Inc(Ink);
      end;
    Require(Ink>5,'Native font table header has a background but no readable caption');
  finally ReleaseDC(Header,DC); end;
  CheckPreview(Dialog,'ReaderFontPreview');
  Timer.Enabled:=True;
  TButton(Dialog.FindComponent('ReaderAddWindowsFont')).Click;
  Require(not Timer.Enabled,'Windows font picker did not finish');
  Require(ReaderFontIsListed(Profile,ChosenFamily),'Chosen Windows font was not added to this Reader profile');
  Selected:='';
  for Item in List.Items do if SameText(Item.Caption,ChosenFamily) then begin Item.Selected:=True; Selected:=Item.Caption; end;
  Require(Selected<>'','Added Windows font is missing from the font manager');
  TButton(Dialog.FindComponent('ReaderRemoveFont')).Click;
  Require(not ReaderFontIsListed(Profile,ChosenFamily),'Removing a non-default font did not hide it');
  TButton(Dialog.FindComponent('ReaderRestoreFont')).Click;
  Require(ReaderFontIsListed(Profile,ChosenFamily),'An installed Windows font could not be restored without downloading');
  Inc(Visits); Dialog.ModalResult:=mrOk;
end;

var Owner:TForm; Probe:TFontDialogProbe; Selected,DefaultFamily:string; Ini:TMemIniFile;
begin
  SetTextCodePage(Output,65001); RequireIsolatedRegression;
  Application.Initialize; Probe:=TFontDialogProbe.Create; Owner:=TForm.CreateNew(nil);
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=80; Probe.Timer.OnTimer:=Probe.Tick; Application.OnException:=Probe.Fail;
  try
    PrepareReaderFonts; Owner.Caption:='HomeLibre private font-dialog fixture'; Owner.ShowInTaskBar:=True;
    Owner.Font.Name:='Segoe UI'; Owner.Font.Size:=9; Owner.Show;
    for var Dark in [False,True] do
      for var DPI in [96,144,192,216,288] do
      begin
        Probe.Dark:=Dark; Probe.DPI:=DPI;
        Probe.Profile:=ExtractFilePath(ParamStr(0))+Format('fonts-%d-%d.ini',[Ord(Dark),DPI]);
        DefaultFamily:=DefaultReaderFont(Probe.Profile);
        Probe.ChosenFamily:='Arial';
        if Screen.Fonts.IndexOf('GungsuhChe')>=0 then Probe.ChosenFamily:='GungsuhChe';
        if SameText(DefaultFamily,Probe.ChosenFamily) then Probe.ChosenFamily:='Times New Roman';
        Require(Screen.Fonts.IndexOf(Probe.ChosenFamily)>=0,'Required installed Windows font is absent');
        Ini:=TMemIniFile.Create(Probe.Profile,TEncoding.UTF8);
        try Ini.WriteString('FontUISentinel','Keep','Оставить ё'); Ini.UpdateFile; finally Ini.Free; end;
        if Dark then begin Owner.Color:=ReaderThemeBackground(5); Owner.Font.Color:=ReaderThemeText(5); end
        else begin Owner.Color:=ReaderThemeBackground(1); Owner.Font.Color:=ReaderThemeText(1); end;
        Selected:=DefaultFamily; Probe.Timer.Enabled:=True;
        ManageReaderFonts(Owner,Probe.Profile,Selected);
        Require(Selected=Probe.ChosenFamily,'The selected font was not returned to the Reader');
        Ini:=TMemIniFile.Create(Probe.Profile,TEncoding.UTF8);
        try Require(Ini.ReadString('FontUISentinel','Keep','')='Оставить ё','Font preferences overwrote unrelated settings');
        finally Ini.Free; end;
        Writeln(Format('PASS font dialogs DPI=%d dark=%d family=%s header search preview resize add remove restore',
          [DPI,Ord(Dark),Probe.ChosenFamily])); Flush(Output);
      end;
    Require(Probe.Visits=10,'Incomplete font-dialog cases');
    Writeln('PASS Reader font manager native UI regression');
  finally Probe.Timer.Free; Application.OnException:=nil; Owner.Free; Probe.Free; end;
end.
