procedure TestReaderSpread;
var Reader: TfrmBuiltinReader; FileName, Profile, XML, Original, Page: string;
  First, Last, Saved, RightInk, LeftInk: Integer; BaselineGDI, BaselineUSER: Cardinal; Image: TBitmap;
  procedure CheckHiddenInterface(const Kind: string);
  var Toolbar, Footer, Search: TPanel; Restore, HideButton, FullButton: TButton;
    Bounds, OriginalBounds: TRect; Position: Integer; Key: Word; Menu: TMainMenu; Started: UInt64;
  begin
    Toolbar:=Reader.FindComponent('ReaderToolbar') as TPanel;
    Footer:=Reader.FindComponent('ReaderFooter') as TPanel;
    Search:=Reader.FindComponent('ReaderSearchPanel') as TPanel;
    Restore:=Reader.FindComponent('ReaderShowInterface') as TButton;
    HideButton:=Reader.FindComponent('ReaderHideInterface') as TButton;
    FullButton:=Reader.FindComponent('ReaderFullScreen') as TButton;
    Menu:=Reader.Menu; Position:=Reader.TextPosition; OriginalBounds:=Reader.BoundsRect;
    Require(Reader.WindowState=wsNormal,Kind+' interface test must start in a normal window');
    Reader.SetBounds(OriginalBounds.Left,OriginalBounds.Top,640,400); Application.ProcessMessages;
    Bounds:=Reader.BoundsRect;
    for var ByButton in [False,True] do
    begin
      Search.Visible:=ByButton;
      HideButton.Click;
      Application.ProcessMessages;
      Require(Reader.InterfaceHidden and not Reader.FullScreenMode and
        (Reader.WindowState=wsNormal) and (Reader.BoundsRect=Bounds) and
        (Reader.BorderStyle=bsSizeable) and (GetMenu(Reader.Handle)=0) and
        not Toolbar.Visible and not Footer.Visible and not Search.Visible and Restore.Visible,
        Kind+' hiding interface changed the small window or left reader panels visible');
      Require(Reader.ReadingSurface.Top=Restore.Top+Restore.Height,
        Kind+' hidden interface leaves an empty toolbar gap above the book');
      if not ByButton then
      begin
        Reader.SetBounds(Bounds.Left+7,Bounds.Top+5,Bounds.Width+31,Bounds.Height+19);
        Application.ProcessMessages; Bounds:=Reader.BoundsRect;
      end;
      if ByButton then begin Key:=VK_ESCAPE; Reader.OnKeyDown(Reader,Key,[]); end
      else Restore.Click;
      Application.ProcessMessages;
      Require(not Reader.InterfaceHidden and not Reader.FullScreenMode and
        (Reader.WindowState=wsNormal) and (Reader.BorderStyle=bsSizeable) and (Reader.Menu=Menu) and
        (GetMenu(Reader.Handle)=Menu.Handle) and Toolbar.Visible and Footer.Visible and
        (Search.Visible=ByButton) and not Restore.Visible and (Reader.BoundsRect=Bounds),
        Kind+' showing interface lost menu search or the resized small window');
      Require(Reader.TextPosition=Position,Kind+' interface visibility changed the reading position');
      Search.Visible:=False;
    end;
    FullButton.Click; Application.ProcessMessages;
    Require(Reader.FullScreenMode and not Reader.InterfaceHidden and
      (Reader.BorderStyle=bsNone) and Toolbar.Visible and Footer.Visible and (Reader.Menu=Menu),
      Kind+' separate full screen command unexpectedly hid the interface');
    HideButton.Click; Application.ProcessMessages;
    Require(Reader.FullScreenMode and Reader.InterfaceHidden and not Toolbar.Visible,
      Kind+' full screen and hidden interface cannot be combined');
    Restore.Click; Application.ProcessMessages;
    Require(Reader.FullScreenMode and not Reader.InterfaceHidden and Toolbar.Visible,
      Kind+' showing interface unexpectedly exited full screen');
    Key:=VK_F11; Reader.OnKeyDown(Reader,Key,[]); Application.ProcessMessages;
    Require((Key=0) and not Reader.FullScreenMode and not Reader.InterfaceHidden and
      (Reader.BorderStyle=bsSizeable) and (Reader.BoundsRect=Bounds),
      Kind+' F11 did not restore the original small window');
    HideButton.Click; FullButton.Click; Application.ProcessMessages;
    Key:=VK_F11; Reader.OnKeyDown(Reader,Key,[]); Application.ProcessMessages;
    Require(Reader.InterfaceHidden and not Reader.FullScreenMode and (Reader.BoundsRect=Bounds),
      Kind+' exiting full screen changed independent hidden interface state');
    Restore.Click; Reader.BoundsRect:=OriginalBounds;
    Started:=GetTickCount64;
    while Reader.PageLoading and (GetTickCount64-Started<20000) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
    Require(not Reader.PageLoading,Kind+' interface modes did not finish restoring the reading view');
    Writeln('PASS '+Kind+' interface button hides all chrome and restores from top button or Escape without losing reading state');
    Writeln('PASS '+Kind+' small-window interface visibility and full screen are independent, resizable and reversible');
  end;
  procedure CheckAppearance(const Kind: string);
  var Bitmap, Flat: TBitmap; Stream: TBytesStream; FlatHash, Text: string;
    Position, Changed: Integer; Size: TPoint; Watch: TStopwatch; AppDark: Boolean;
    A,B: PRGBQuad; Menu: TMainMenu; Item: TMenuItem; Info: TMenuItemInfo;
    procedure CheckMenuPainting;
    var MenuImage: TBitmap; ItemBounds: TRect; Matches, Count: Integer;
      NativeItem: TMenuItemInfo; Draw: TDrawItemStruct;
    begin
      Require(GetMenu(Reader.Handle)=Reader.Menu.Handle,'Reader uses a different native menu');
      Require(GetMenuItemRect(Reader.Handle,Reader.Menu.Handle,0,ItemBounds),
        'Cannot locate the visible reader menu');
      NativeItem:=Default(TMenuItemInfo); NativeItem.cbSize:=SizeOf(NativeItem);
      NativeItem.fMask:=MIIM_ID;
      Require(GetMenuItemInfo(Reader.Menu.Handle,0,True,NativeItem),'Cannot find the native menu command');
      MenuImage:=TBitmap.Create;
      try
        MenuImage.SetSize(ItemBounds.Width,ItemBounds.Height);
        MenuImage.Canvas.Brush.Color:=clFuchsia; MenuImage.Canvas.FillRect(MenuImage.Canvas.ClipRect);
        Draw:=Default(TDrawItemStruct); Draw.CtlType:=ODT_MENU;
        Draw.itemID:=NativeItem.wID; Draw.itemAction:=ODA_DRAWENTIRE;
        Draw.hwndItem:=Reader.Menu.Handle; Draw.hDC:=MenuImage.Canvas.Handle;
        Draw.rcItem:=Rect(0,0,MenuImage.Width,MenuImage.Height);
        // Exercise Windows' owner-draw notification through the real form.
        // WM_PRINT/PrintWindow do not render its themed non-client menu.
        Reader.Perform(WM_DRAWITEM,0,LPARAM(@Draw));
        Matches:=0; Count:=0;
        for var Y:=2 to MenuImage.Height-3 do
          for var X:=2 to MenuImage.Width-3 do
          begin
            Inc(Count);
            if ColorToRGB(MenuImage.Canvas.Pixels[X,Y])=ColorToRGB(Reader.Color) then Inc(Matches);
          end;
        Require((Count>0) and (Matches>Count div 2),
          Format('Reader native menu draw notification ignored the palette: %d of %d pixels match',[Matches,Count]));
      finally MenuImage.Free; end;
    end;
    function Snapshot: string;
    begin
      Bitmap.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
      Reader.ReadingSurface.PaintTo(Bitmap.Canvas.Handle,0,0);
      Stream.Clear; Bitmap.SaveToStream(Stream);
      Stream.Position:=0; Result:=THashSHA2.GetHashString(Stream);
    end;
  begin
    Bitmap:=TBitmap.Create; Bitmap.PixelFormat:=pf32bit; Flat:=TBitmap.Create;
    Stream:=TBytesStream.Create; AppDark:=MHLThemeDark;
    try
      if not Assigned(Reader.Menu) then
      begin
        Menu:=TMainMenu.Create(Reader); Item:=TMenuItem.Create(Menu);
        Item.Caption:='Файл'; Menu.Items.Add(Item);
        Item:=TMenuItem.Create(Menu); Item.Caption:='Открыть'; Menu.Items[0].Add(Item);
        Reader.Menu:=Menu; Reader.RefreshWindowTheme;
      end;
      Position:=Reader.TextPosition;
      for var Theme in [0,1,2,3,4,5] do
      begin
        Reader.SetTheme(Theme); Watch:=TStopwatch.StartNew;
        while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do
        begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
        Require(not Reader.PageLoading,Kind+' appearance theme did not finish');
        Require(MHLThemeDark=AppDark,Kind+' reader palette changed the catalogue theme');
        var SelectedPaper:=Reader.PageBackground;
        Reader.Perform(WM_APP+$42,Ord(not AppDark),0);
        Require(Reader.PageBackground=SelectedPaper,
          Kind+' catalogue theme message replaced the chosen reading palette');
        Info:=Default(TMenuItemInfo); Info.cbSize:=SizeOf(Info); Info.fMask:=MIIM_FTYPE;
        Require(GetMenuItemInfo(Reader.Menu.Handle,0,True,Info) and
          (Info.fType and MFT_OWNERDRAW<>0) and Reader.Menu.OwnerDraw and
          Assigned(Reader.Menu.Items[0].OnDrawItem),
          Format('%s native menu ignored the reader palette painter (flags=%x owner=%s draw=%s)',
            [Kind,Info.fType,BoolToStr(Reader.Menu.OwnerDraw,True),
             BoolToStr(Assigned(Reader.Menu.Items[0].OnDrawItem),True)]));
        if Kind='FB2' then CheckMenuPainting;
        Require((TPanel(Reader.FindComponent('ReaderToolbar')).Color=Reader.Color) and
          (TPanel(Reader.FindComponent('ReaderFooter')).Color=Reader.Color) and
          (TComboBox(Reader.FindComponent('ReaderThemeSelector')).Color=Reader.Color) and
          (Reader.ReaderStatus.Font.Color=Reader.Font.Color),
          Kind+' selected theme did not reach the complete reader window');
        Require((TPanel(Reader.FindComponent('ReaderToolbar')).Caption='') and
          (TPanel(Reader.FindComponent('ReaderFooter')).Caption=''),
          Kind+' reader displays an internal panel name');
        Reader.SetPageAppearance(rpaFlat); FlatHash:=Snapshot;
        Flat.Assign(Bitmap); Flat.PixelFormat:=pf32bit;
        Size:=Reader.PageRasterSize; Text:=Reader.PageText;
        Reader.SetPageAppearance(rpaBook);
        Require(Snapshot<>FlatHash,Kind+' book decoration is invisible');
        Changed:=0;
        for var Y:=0 to Bitmap.Height-1 do
        begin
          A:=Flat.ScanLine[Y]; B:=Bitmap.ScanLine[Y];
          for var X:=0 to Bitmap.Width-1 do
          begin
            if Abs(Integer(A.rgbRed)-B.rgbRed)+Abs(Integer(A.rgbGreen)-B.rgbGreen)+
              Abs(Integer(A.rgbBlue)-B.rgbBlue)>=24 then Inc(Changed);
            Inc(A); Inc(B);
          end;
        end;
        Require(Changed>Bitmap.Width*Bitmap.Height div 100,
          Format('%s theme %d book edges affect %d of %d visible pixels (raster %dx%d)',
            [Kind,Theme,Changed,Bitmap.Width*Bitmap.Height,Size.X,Size.Y]));
        Require((Reader.TextPosition=Position) and (Reader.PageText=Text) and
          (Reader.PageRasterSize=Size) and not Reader.PageLoading,
          Kind+' decoration changed content, coordinates or triggered a reload');
        Reader.SetPageAppearance(rpaFlat);
        Require(Snapshot=FlatHash,Kind+' flat appearance did not restore exact pixels');
      end;
      Reader.SetTheme(0); Reader.SetPageAppearance(rpaBook);
      if not Kind.Contains('single page') then CheckHiddenInterface(Kind);
      Writeln('PASS '+Kind+' visible reversible book edges and complete window palette across all six themes without reflow or catalogue changes');
    finally Stream.Free; Flat.Free; Bitmap.Free; end;
  end;
  procedure CheckBookThickness(const Kind: string);
  var Early, Late: TBitmap; Position, LeftChanges, RightChanges: Integer;
    Watch: TStopwatch;
    procedure CaptureAt(Fraction: Double; Target: TBitmap);
    begin
      Reader.SeekProgress(Fraction); Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require(not Reader.PageLoading,Kind+' progress preview did not finish');
      Target.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
      Reader.ReadingSurface.PaintTo(Target.Canvas.Handle,0,0);
    end;
  begin
    Position:=Reader.TextPosition; Early:=TBitmap.Create; Late:=TBitmap.Create;
    try
      Reader.SetTheme(1); Reader.SetPageAppearance(rpaBook);
      CaptureAt(0.05,Early); CaptureAt(0.90,Late);
      LeftChanges:=0; RightChanges:=0;
      for var Y:=30 to Early.Height-50 do
        for var X:=2 to 28 do
        begin
          if Early.Canvas.Pixels[X,Y]<>Late.Canvas.Pixels[X,Y] then Inc(LeftChanges);
          if Early.Canvas.Pixels[Early.Width-1-X,Y]<>Late.Canvas.Pixels[Late.Width-1-X,Y] then Inc(RightChanges);
        end;
      Require((LeftChanges>Early.Height) and (RightChanges>Early.Height),
        Format('%s book thickness does not move between outer page blocks (%d / %d)',[Kind,LeftChanges,RightChanges]));
      // Repainting a volume should remain a cheap overlay, without reloading
      // or repaginating the source on every frame.
      Watch:=TStopwatch.StartNew;
      for var I:=1 to 20 do Reader.ReadingSurface.PaintTo(Late.Canvas.Handle,0,0);
      Require(Watch.ElapsedMilliseconds<3000,Kind+' book decoration repaints too slowly');
      Writeln(Format('PASS %s page-block thickness follows reading progress; 20 repaints %d ms',
        [Kind,Watch.ElapsedMilliseconds]));
    finally
      Reader.GoToPosition(Position); Reader.SetTheme(0); Early.Free; Late.Free;
    end;
  end;
  procedure CheckFixed(const Source, Kind: string);
  var BookHash: string; Watch: TStopwatch;
    Scale: Double; X,Y,EndX: Integer; Draft: TReaderAnnotation;
  begin
    BookHash:=THashSHA2.GetHashStringFromFile(Source);
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.OpenBook(Source,Kind,Kind,Settings.AppPath+Kind+'-spread.ini',Settings.AppPath+'tools\pdfium\pdfium.dll');
      Reader.Show; Reader.SetBounds(40,40,1200,740);
      Watch:=TStopwatch.StartNew;
      while (not Reader.Ready or Reader.PageLoading) and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require(Reader.Ready and not Reader.PageLoading,Kind+' initial load failed: '+Reader.ReaderStatus.Caption);
      Reader.SetPageLayout(rplDouble); Reader.SetInspectionPercent(300);
      Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require(not Reader.PageLoading,Kind+' spread did not finish decoding');
      Require((Reader.VisiblePageCount=2) and (Reader.TextPosition=0) and (Reader.PageTurn=rptSpread),Kind+' default spread differs');
      CheckAppearance(Kind);
      Reader.SetPageLayout(rplSingle); Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require(not Reader.PageLoading,Kind+' single page did not finish decoding');
      CheckAppearance(Kind+' single page');
      Reader.SetPageLayout(rplDouble); Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require(not Reader.PageLoading,Kind+' spread did not return after appearance check');
      if Kind='PDF' then
      begin
        Require(Reader.PageText.Contains('Spread page 1') and Reader.PageText.Contains('Spread page 2'),'PDF spread omits a page text layer');
        begin
          Scale:=Reader.PageRasterSize.Y/750;
          X:=Reader.PDFPan.X+Round(500*Scale)+MulDiv(24,Reader.CurrentPPI,96)+Round(52*Scale);
          EndX:=X+Round(74*Scale);
          Y:=Reader.PDFPan.Y+Round(62*Scale);
          Reader.ReadingSurface.Perform(WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(X,Y));
          Reader.ReadingSurface.Perform(WM_MOUSEMOVE,MK_LBUTTON,MakeLParam(EndX,Y));
          Reader.ReadingSurface.Perform(WM_LBUTTONUP,0,MakeLParam(EndX,Y));
          Require(Reader.PDFSelectedText.Contains('Spread'),'Right PDF page cannot select text');
          Draft:=Reader.AnnotationDraft(Reader.PDFSelectedText);
          Require((Draft.Position=1) and Draft.RangeIsPageText,'Right PDF quote was attached to the left page');
          Reader.FindText('Spread page 2'); Watch:=TStopwatch.StartNew;
          while Reader.SearchRunning and (Watch.ElapsedMilliseconds<10000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
          Require((Reader.TextPosition=0) and not Reader.SearchRunning,'Search cannot highlight the visible right page');
        end;
      end;
      Reader.NextPage; Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require((not Reader.PageLoading) and (Reader.TextPosition=2),Kind+' does not turn by a pair: '+IntToStr(Reader.TextPosition)+' '+Reader.ReaderStatus.Caption);
      Reader.PreviousPage; Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require(Reader.TextPosition=0,Kind+' previous pair differs');
      Reader.SetPageTurn(rptSliding); Reader.NextPage; Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require((not Reader.PageLoading) and (Reader.TextPosition=1),Kind+' does not slide the right page to the left');
      Reader.PreviousPage; Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Require(Reader.TextPosition=0,Kind+' previous sliding page differs');
      Reader.GoToPosition(Reader.TextLength-1); Watch:=TStopwatch.StartNew;
      while Reader.PageLoading and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
      Reader.NextPage; Require(Reader.TextPosition=Reader.TextLength-1,Kind+' odd final page repeats');
      Reader.SetTheme(4); Require(Reader.TextPosition=Reader.TextLength-1,Kind+' theme loses the visible page');
      Reader.Close;
    finally Reader.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Source)=BookHash,Kind+' source was modified');
    Writeln('PASS '+Kind+' pair and sliding spread, async cache, odd ending and protected source');
  end;
  function Normalized(const Value: string): string;
  begin Result:=Value.Replace(#$FFFC,'').Replace(#13#10,#10).Replace(#13,#10).Replace(#10,#13#10).Trim; end;
  procedure Settle;
  var Watch: TStopwatch;
  begin
    Watch:=TStopwatch.StartNew;
    repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(10);
    until (Watch.ElapsedMilliseconds>250) and Reader.Ready and not Reader.PageLoading or (Watch.ElapsedMilliseconds>10000);
    Require(Reader.Ready and not Reader.PageLoading,'Spread reader failed to load: '+Reader.ReaderStatus.Caption);
  end;
  procedure CheckText(const Extension: string);
  var First, PairEnd: Integer;
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.SetBounds(40,40,1200,740);
      Reader.OpenBook(Settings.AppPath+'reader-spread.'+Extension,Extension,Extension,Settings.AppPath+Extension+'-spread.ini',''); Settle;
      Reader.SetPageLayout(rplDouble); Reader.SetPageTurn(rptSpread); First:=Reader.TextPosition;
      var Text:=Reader.PageText; Reader.NextPage; PairEnd:=Reader.TextPosition;
      Require((PairEnd>First) and (Text=Normalized(Reader.BookText.Substring(First,PairEnd-First))),Extension+' spread loses continuous text');
      Reader.PreviousPage; Require(Reader.TextPosition=First,Extension+' previous spread changed');
      Reader.SetPageTurn(rptSliding); Reader.NextPage;
      Require((Reader.TextPosition>First) and (Reader.TextPosition<PairEnd),Extension+' sliding step differs');
      Reader.Close;
    finally Reader.Free; end;
    Writeln('PASS '+Extension+' text spread shares continuous pair and sliding navigation');
  end;
  procedure Capture;
  begin
    Image.SetSize(Reader.ReadingSurface.ClientWidth,Reader.ReadingSurface.ClientHeight);
    Reader.ReadingSurface.PaintTo(Image.Canvas.Handle,0,0);
  end;
  function Ink(Left, Right: Integer; SelectionOnly: Boolean): Integer;
  var Color, Background: TColor;
  begin
    Result:=0; Background:=ColorToRGB(Reader.PageBackground);
    for var Y:=30 to Image.Height-30 do
      for var X:=Left to Right do
      begin
        Color:=ColorToRGB(Image.Canvas.Pixels[X,Y]);
        if SelectionOnly then
        begin if (GetBValue(Color)>GetRValue(Color)+15) and (GetBValue(Color)>GetGValue(Color)+5) then Inc(Result); end
        else if Color<>Background then Inc(Result);
      end;
  end;
begin
  FileName:=Settings.AppPath+'reader-spread.fb2'; Profile:=Settings.AppPath+'reader-spread.ini';
  XML:='<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>'+
    '<book-title>Разворот</book-title></title-info></description><body><section><title><p>Разворот</p></title>';
  for var I:=1 to 260 do XML:=XML+'<p>'+IntToStr(I)+'. Текст двух страниц: ё, ї, ў. '+
    'Последовательность абзацев, выделение и закладки сохраняются при перелистывании.'+
    IfThen(I=1,'<a l:href="#note1" type="note">1</a>','')+'</p>';
  XML:=XML+'</section></body><body name="notes"><section id="note1"><title><p>1</p></title>'+
    '<p>Сноска разворота.</p></section></body></FictionBook>';
  TFile.WriteAllText(FileName,XML,TEncoding.UTF8); Original:=THashSHA2.GetHashStringFromFile(FileName);
  Reader:=TfrmBuiltinReader.Create(nil); Image:=TBitmap.Create;
  try
    Reader.OpenBook(FileName,'Разворот','spread',Profile,'pdfium.dll'); Reader.Show; Settle;
    Reader.SetBounds(40,40,1200,740); Settle; Reader.SetShowFootnotes(False);
    Reader.SetPageLayout(rplDouble); Reader.GoToPosition(0); Settle;
    Require(Reader.VisiblePageCount=2,'Explicit spread did not show two pages');
    Capture; LeftInk:=Ink(60,Image.Width div 2-50,False); RightInk:=Ink(Image.Width div 2+60,Image.Width-50,False);
    Require((LeftInk>100) and (RightInk>100),'Spread does not draw text on both pages');
    CheckAppearance('FB2'); CheckBookThickness('FB2 spread');
    Reader.SetPageLayout(rplSingle); Settle; CheckAppearance('FB2 single page'); CheckBookThickness('FB2 single page');
    Reader.SetPageLayout(rplDouble); Settle;
    First:=Reader.TextPosition; Page:=Reader.PageText; Reader.NextPage; Last:=Reader.TextPosition;
    Require((Last>First) and (Page=Normalized(Reader.BookText.Substring(First,Last-First))),
      'Spread navigation skips or repeats text');
    Reader.PreviousPage; Require(Reader.TextPosition=First,'Previous spread lost its start');
    Reader.SelectText(First+(Last-First)*3 div 4,45); Capture;
    Require((Reader.SelectedText<>'') and (Ink(Image.Width div 2+60,Image.Width-50,True)>50),
      'Selection on the right page is missing or drawn on the left');
    Reader.SetPageTurn(rptSliding); Reader.GoToPosition(0); Reader.NextPage;
    Require((Reader.TextPosition>0) and (Reader.TextPosition<Last),'Text spread does not slide by a single page');
    First:=Reader.TextPosition; Reader.NextPage; Reader.PreviousPage;
    Require(Reader.TextPosition=First,'Text sliding previous page lost its boundary');
    Reader.SetPageTurn(rptSpread); Reader.GoToPosition(0);
    for var I:=1 to 4 do
    begin
      First:=Reader.TextPosition; Page:=Reader.PageText; Reader.NextPage; Last:=Reader.TextPosition;
      Require(Page=Normalized(Reader.BookText.Substring(First,Last-First)),'Later spread lost source text');
    end;
    Saved:=Reader.TextPosition; Reader.AddBookmark('Разворот');
    Reader.SetPageLayout(rplSingle); Require((Reader.TextPosition=Saved) and (Reader.VisiblePageCount=1),'Single-page switch changed position');
    Reader.SetPageLayout(rplAutomatic); Settle;
    Require((Reader.VisiblePageCount=2) and (Reader.TextPosition=Saved),'Automatic wide spread changed position');
    Reader.Width:=700; Settle;
    Require((Reader.VisiblePageCount=1) and (Reader.TextPosition=Saved),'Automatic narrow window lost its position');
    Reader.Width:=1200; Settle; Require(Reader.VisiblePageCount=2,'Automatic spread did not return');
    Reader.NextPage; Reader.GoToBookmark(0); Require(Reader.TextPosition=Saved,'Bookmark moved after reflow');
    Reader.GoToPosition(0); Reader.SetShowFootnotes(True); Settle;
    Require(Reader.VisibleFootnotes.Contains('Сноска разворота'),'Spread lost a visible footnote');
    Reader.SetPageLayout(rplDouble); Reader.GoToPosition(Saved); Reader.Close;
  finally Reader.Free; Image.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.OpenBook(FileName,'Разворот','spread',Profile,'pdfium.dll'); Reader.Show; Settle;
    Require((Reader.PageLayout=rplDouble) and (Reader.PageAppearance=rpaBook) and (Reader.TextPosition=Saved),'Spread mode, appearance or position did not survive reopening');
    Reader.GoToPosition(Reader.TextLength-1); First:=Reader.TextPosition; Reader.NextPage;
    Require((Reader.TextPosition=First) and (Reader.ReadingProgress=1),'Last spread repeats the ending');
    Reader.Close;
  finally Reader.Free; end;
  Require(THashSHA2.GetHashStringFromFile(FileName)=Original,'Spread modified the source book');
  CheckFixed(Settings.AppPath+'reader-spread.pdf','PDF');
  CheckFixed(Settings.AppPath+'reader-spread.cbz','CBZ');
  CheckFixed(Settings.AppPath+'reader-spread.tiff','TIFF');
  CheckFixed(Settings.AppPath+'reader-spread.djvu','DjVu');
  CheckText('txt'); CheckText('rtf'); CheckText('epub');
  DrainFailedReaderIdleCleanup('spread-warm');
  BaselineGDI:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS); BaselineUSER:=ReaderApplicationUSERCount;
  for var I:=1 to 3 do CheckText('txt');
  CheckFixed(Settings.AppPath+'reader-spread.cbz','CBZ repeat');
  DrainFailedReaderIdleCleanup('spread-repeated',BaselineGDI+4,BaselineUSER+4);
  Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=BaselineGDI+4,'Spread readers leak GDI resources');
  Require(ReaderApplicationUSERCount<=BaselineUSER+4,'Spread readers leak USER resources');
  Writeln('PASS repeated two-page readers retain the original +4 GDI/USER resource budgets');
  Writeln('PASS reader spread draws both pages, preserves continuous text, right-page selection, navigation, adaptive resize, footnotes, bookmarks and saved mode');
end;
