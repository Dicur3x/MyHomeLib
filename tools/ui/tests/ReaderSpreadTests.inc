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
    Require(Reader.ReadingSurface.Top=0,'Hidden full-screen controls still reserve reading space');
    var RestoreMenu:=Reader.FindComponent('ReaderSelectionMenu') as TPopupMenu;
    RestoreMenu.OnPopup(RestoreMenu);
    Require((RestoreMenu.Items[0].Name='ReaderRestoreInterfaceMenu') and RestoreMenu.Items[0].Visible,
      'The reader context menu cannot bring back the interface');
    RestoreMenu.Items[0].Click; Application.ProcessMessages;
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
    IfThen(I=1,'<a l:href="#note1" type="note">[1]</a>','')+'</p>';
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
    for var Layout in [rplSingle,rplContinuous] do
    begin
      Reader.SetPageLayout(Layout); Reader.SetShowFootnotes(False);
      Reader.GoToPosition(0); Settle;
      var SearchButton:=Reader.FindComponent('ReaderSearch') as TButton;
      SearchButton.Click; Settle;
      Reader.SetHighlightColor(clLime);
      Reader.SetSearchOptions(False,False,False);
      Reader.FindText('[1]'); Settle;
      Require((Reader.HighlightCount=1) and (Reader.VisibleFootnotes=''),
        'The footnote probe needs a highlighted marker and no footer');
      Capture;
      var Hint: THintInfo;
      var Found:=False;
      for var Y:=0 to Min(Image.Height-1,370) do
      begin
        for var X:=0 to Image.Width-1 do
          if ColorToRGB(Image.Canvas.Pixels[X,Y])=ColorToRGB(clLime) then
          begin
            Hint:=Default(THintInfo); Hint.CursorPos:=Point(X,Y); Hint.HintMaxWidth:=Reader.ClientWidth;
            Reader.ReadingSurface.Perform(CM_HINTSHOW,0,LPARAM(@Hint));
            if Hint.HintStr.Contains('Сноска разворота') then begin Found:=True; Break; end;
          end;
        if Found then Break;
      end;
      Require(Found,'Hovering the marker did not show its note in layout '+IntToStr(Ord(Layout)));
      Hint.HintStr:=''; Hint.CursorPos.X:=0;
      Reader.ReadingSurface.Perform(CM_HINTSHOW,0,LPARAM(@Hint));
      Require(Hint.HintStr='','A margin unexpectedly showed the nearest footnote');
      if Layout=rplSingle then SearchButton.Click
      else
      begin
        Reader.ReadingSurface.SetFocus;
        var Key: Word:=VK_ESCAPE;
        Reader.OnKeyDown(Reader,Key,[]);
        Require(Key=0,'Escape did not close the visible search panel');
      end;
      Settle;
      Require((Reader.HighlightCount=0) and (Reader.MatchPosition<0) and
        not TPanel(Reader.FindComponent('ReaderSearchPanel')).Visible,
        'Closing the search left its text highlight');
      var Percent:=TLabel(Reader.FindComponent('ReaderReadingPercent'));
      Require(Percent.Visible and string(Percent.Caption).EndsWith('%'),'Reading percentage is missing');
    end;
    Reader.SetShowFootnotes(True);
    Writeln('PASS reading percent, cleared search and hover footnotes without footer in both reading modes');
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

type
  TContinuousScrollSurface = class(TReaderSurface);
  TLiveAppearanceProbe = class
    Reader: TfrmBuiltinReader;
    Watch: TStopwatch;
    OpenMS: Int64;
    procedure Tick(Sender: TObject);
  end;

procedure TLiveAppearanceProbe.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
  begin
    var Dialog:=Screen.Forms[I];
    if (Dialog.Name<>'ReaderAppearanceDialog') or not Dialog.Visible then Continue;
    if GetWindow(Dialog.Handle,GW_OWNER)=Reader.Handle then OpenMS:=Watch.ElapsedMilliseconds;
    TTimer(Sender).Enabled:=False;
    Dialog.ModalResult:=mrOk;
    Exit;
  end;
end;

procedure TestReaderLiveFeedback;
var Reader: TfrmBuiltinReader; BookFile, SourceHash: string; Probe: TLiveAppearanceProbe; Timer: TTimer;
  Watch, Frame: TStopwatch;
  OpenMS, ColdOpenMS, MaxPumpUS: Int64;
  Before, ForwardPosition, Frames, Last: Integer;
  function Scroll(Direction, Pulses: Integer): Integer;
  var Deadline, SendAt, Started: UInt64; Sent: Integer; Current: Integer;
  begin
    Started:=GetTickCount64; Deadline:=Started+UInt64(Pulses)*52+420;
    SendAt:=Started; Sent:=0; Result:=0; Last:=Reader.TextPosition;
    repeat
      if (Sent<Pulses) and (GetTickCount64>=SendAt) then
      begin
        TContinuousScrollSurface(Reader.ReadingSurface).DoMouseWheel([],Direction*WHEEL_DELTA,Point(0,0));
        Inc(Sent); Inc(SendAt,52);
      end;
      Frame:=TStopwatch.StartNew;
      Application.ProcessMessages;
      Frame.Stop;
      MaxPumpUS:=Max(MaxPumpUS,Frame.ElapsedTicks*1000000 div TStopwatch.Frequency);
      Current:=Reader.TextPosition;
      if Current<>Last then begin Inc(Result); Last:=Current; end;
      Sleep(2);
    until GetTickCount64>=Deadline;
  end;
begin
  RequireIsolatedRegression;
  BookFile:=GetEnvironmentVariable('HLRU_TEST_LIVE_READER_BOOK');
  Require(FileExists(BookFile),'Real reader fixture not supplied');
  SourceHash:=THashSHA2.GetHashStringFromFile(BookFile);
  Reader:=TfrmBuiltinReader.Create(nil);
  Probe:=TLiveAppearanceProbe.Create;
  Timer:=TTimer.Create(nil);
  try
    Probe.Reader:=Reader;
    Timer.Enabled:=False; Timer.Interval:=16; Timer.OnTimer:=Probe.Tick;
    Reader.Width:=1000; Reader.Height:=800;
    Reader.Show;
    Reader.OpenBook(BookFile,'Инженер Петра Великого','live-reader-feedback',Settings.AppPath+'feedback-reader.ini','');
    Watch:=TStopwatch.StartNew;
    while not Reader.LoadFinished and (Watch.ElapsedMilliseconds<30000) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
    Require(Reader.Ready,'Real reader fixture did not open: '+Reader.ReaderStatus.Caption);
    Writeln('PROFILE real FB2 ready ms=',Watch.ElapsedMilliseconds);
    ColdOpenMS:=0;
    for var Attempt:=1 to 2 do
    begin
      Probe.OpenMS:=-1;
      Reader.ReadingSurface.SetFocus;
      Probe.Watch:=TStopwatch.StartNew;
      Timer.Enabled:=True;
      (Reader.FindComponent('ReaderAppearance') as TButton).Click;
      OpenMS:=Probe.OpenMS;
      Require(OpenMS>=0,'Appearance did not display over the real book');
      Require(Reader.ActiveControl=Reader.ReadingSurface,'Appearance did not return focus after Apply');
      if Attempt=1 then ColdOpenMS:=OpenMS;
      Watch:=TStopwatch.StartNew;
      repeat Application.ProcessMessages; Sleep(5); until Watch.ElapsedMilliseconds>=350;
    end;
    Reader.SetPageLayout(rplContinuous);
    Reader.GoToPosition(300000);
    Before:=Reader.TextPosition; MaxPumpUS:=0;
    Frames:=Scroll(-1,45); ForwardPosition:=Reader.TextPosition;
    Require((Frames>45) and (ForwardPosition>Before),'Real book did not scroll forward in intermediate frames');
    Writeln('PROFILE real reader appearance cold_ms=',ColdOpenMS,' warm_ms=',OpenMS,
      ' forward_frames=',Frames,' max_pump_us=',MaxPumpUS);
    MaxPumpUS:=0;
    Frames:=Scroll(1,32);
    Require((Frames>32) and (Reader.TextPosition<ForwardPosition),'Real book did not scroll backward in intermediate frames');
    Writeln('PROFILE real reader backward_frames=',Frames,' max_pump_us=',MaxPumpUS);
    Reader.Close;
  finally Timer.Free; Probe.Free; Reader.Free; end;
  Require(THashSHA2.GetHashStringFromFile(BookFile)=SourceHash,'Real reader test changed the source');
  Writeln('PASS real FB2 appearance and continuous scrolling');
end;

type
  TRasterScaleDialogProbe = class
    Timer: TTimer;
    Expected, Choose: Integer;
    Accept, Seen: Boolean;
    Failure: string;
    procedure Tick(Sender: TObject);
  end;

procedure TRasterScaleDialogProbe.Tick(Sender: TObject);
var Dialog: TCustomForm; Scale, Zoom, Layout: TComboBox; Hold: TCheckBox;
begin
  for var I:=0 to Screen.FormCount-1 do
  begin
    Dialog:=Screen.Forms[I];
    if (Dialog.Name<>'ReaderAppearanceDialog') or not Dialog.Visible then Continue;
    Timer.Enabled:=False; Seen:=True;
    try
      Scale:=Dialog.FindComponent('ReaderRasterScale') as TComboBox;
      Zoom:=Dialog.FindComponent('ReaderInspectionPercent') as TComboBox;
      Layout:=Dialog.FindComponent('cbReaderPageLayout') as TComboBox;
      Hold:=Dialog.FindComponent('ReaderInspectionHold') as TCheckBox;
      Require(Assigned(Scale) and Assigned(Zoom) and Assigned(Layout) and Assigned(Hold),
        'Image scale dialog lacks independent permanent and temporary controls');
      Require(Scale.Enabled and (Scale.ItemIndex=Expected) and (Scale.Items[1]='Исходный (100%)') and
        not Zoom.Enabled and (Zoom.Text='200') and not Hold.Enabled,
        'Continuous image layout does not distinguish source scale from temporary 200 percent');
      Layout.ItemIndex:=Ord(rplSingle); Layout.OnChange(Layout);
      Require(not Scale.Enabled and Zoom.Enabled and Hold.Enabled,'Paged layout exposes the wrong zoom controls');
      Layout.ItemIndex:=Ord(rplContinuous); Layout.OnChange(Layout);
      Require(Scale.Enabled and not Zoom.Enabled and not Hold.Enabled,'Switching back did not restore image scale');
      Scale.ItemIndex:=Choose;
      if Accept then Dialog.ModalResult:=mrOk else Dialog.ModalResult:=mrCancel;
    except on E: Exception do
      begin Failure:=E.Message; Dialog.ModalResult:=mrCancel; end;
    end;
    Exit;
  end;
end;

type
  TReaderNavigationProbe = class
    Timer: TTimer;
    Mode: Integer;
    Seen: Boolean;
    Failure: string;
    procedure Tick(Sender: TObject);
  end;

procedure TReaderNavigationProbe.Tick(Sender: TObject);
var Dialog: TCustomForm; Previous, ScreenUp, ScreenDown: TComboBox; Save, Reset: TButton;
begin
  for var I:=0 to Screen.FormCount-1 do
  begin
    Dialog:=Screen.Forms[I];
    if (Dialog.Name<>'ReaderNavigationDialog') or not Dialog.Visible then Continue;
    Timer.Enabled:=False; Seen:=True;
    try
      Previous:=Dialog.FindComponent('ReaderKeyPrevious') as TComboBox;
      ScreenUp:=Dialog.FindComponent('ReaderKeyScreenUp') as TComboBox;
      ScreenDown:=Dialog.FindComponent('ReaderKeyScreenDown') as TComboBox;
      Save:=Dialog.FindComponent('ReaderKeysSave') as TButton;
      Reset:=Dialog.FindComponent('ReaderKeysReset') as TButton;
      if Mode=0 then
      begin
        Require((ScreenUp.Text='Page Up') and (ScreenDown.Text='Page Down'),
          'Existing reader profile did not get default navigation keys');
        ScreenUp.ItemIndex:=ScreenUp.Items.IndexOf('A');
        ScreenDown.ItemIndex:=ScreenDown.Items.IndexOf('D');
        Previous.ItemIndex:=Previous.Items.IndexOf('D');
        Save.Click;
        Require(Dialog.ModalResult=mrNone,'The navigation dialog accepted conflicting keys');
        Previous.ItemIndex:=Previous.Items.IndexOf('Без клавиши');
        Save.Click;
      end
      else
      begin
        Require((ScreenUp.Text='A') and (ScreenDown.Text='D') and (Previous.ItemIndex=0),
          'Navigation selections were lost after reopening the reader');
        Reset.Click;
        Require((ScreenUp.Text='Page Up') and (ScreenDown.Text='Page Down') and (Previous.ItemIndex>0),
          'The navigation dialog did not restore the default choices');
        if Mode=1 then (Dialog.FindComponent('ReaderKeysCancel') as TButton).Click
        else Save.Click;
      end;
      Require(Dialog.ModalResult<>mrNone,'The navigation dialog did not finish');
    except on E: Exception do
      begin Failure:=E.Message; Dialog.ModalResult:=mrCancel; end;
    end;
    Exit;
  end;
end;

procedure TestReaderContinuousScrolling;
var Reader: TfrmBuiltinReader; FileName, Extension, Original: string;
  Watch: TStopwatch; Position, Frames, LastTop, Steps, I: Integer;
  Raster: Boolean;
  procedure Pump(Milliseconds: Integer);
  var Wait: TStopwatch;
  begin
    Wait:=TStopwatch.StartNew;
    repeat
      Application.ProcessMessages;
      CheckSynchronize(5);
      Sleep(8);
    until Wait.ElapsedMilliseconds>=Milliseconds;
  end;
  procedure PressArrow(Direction: Word; Count: Integer);
  begin
    Require(Reader.ReadingSurface.Focused,'The reading surface did not receive focus');
    for var Index:=1 to Count do
    begin
      Win32Check(PostMessage(Reader.ReadingSurface.Handle,WM_KEYDOWN,Direction,1));
      Win32Check(PostMessage(Reader.ReadingSurface.Handle,WM_KEYUP,Direction,-1073741823));
    end;
    Application.ProcessMessages;
    Require(Reader.ReadingSurface.Focused,'Reader navigation moved focus away from the book');
  end;
  procedure CheckNavigationDialog(Mode: Integer);
  var Probe: TReaderNavigationProbe; Menu: TPopupMenu; Item: TMenuItem;
  begin
    Probe:=TReaderNavigationProbe.Create;
    try
      Probe.Mode:=Mode;
      Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=30; Probe.Timer.OnTimer:=Probe.Tick;
      Menu:=Reader.FindComponent('ReaderSelectionMenu') as TPopupMenu;
      Menu.OnPopup(Menu);
      Item:=Menu.FindComponent('ReaderNavigationKeysContext') as TMenuItem;
      Require(Assigned(Item) and Item.Visible,'Reader navigation settings are absent from the fallback menu');
      Item.Click;
      Require(Probe.Seen and (Probe.Failure=''),'Navigation settings failed: '+Probe.Failure);
      Reader.ReadingSurface.SetFocus;
    finally Probe.Timer.Free; Probe.Free; end;
  end;
  procedure CheckScaleDialog(Expected, Choose: Integer; Accept: Boolean);
  var Probe: TRasterScaleDialogProbe;
  begin
    Probe:=TRasterScaleDialogProbe.Create;
    try
      Probe.Expected:=Expected; Probe.Choose:=Choose; Probe.Accept:=Accept;
      Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=30; Probe.Timer.OnTimer:=Probe.Tick;
      TButton(Reader.FindComponent('ReaderAppearance')).Click;
      Require(Probe.Seen and (Probe.Failure=''),'Image scale dialog failed: '+Probe.Failure);
      Require(Reader.InspectionPercent=200,'Changing image scale changed temporary zoom');
    finally Probe.Timer.Free; Probe.Free; end;
  end;
begin
  RequireIsolatedRegression;
  for Extension in TArray<string>.Create('pdf','djvu','cbz','tiff','epub','txt','rtf') do
  begin
    FileName:=Settings.AppPath+'reader-spread.'+Extension;
    Original:=THashSHA2.GetHashStringFromFile(FileName);
    Raster:=(Extension='pdf') or (Extension='djvu') or (Extension='cbz') or (Extension='tiff');
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.OpenBook(FileName,Extension,Extension,Settings.AppPath+'scroll-'+Extension+'.ini',
        Settings.AppPath+'tools\pdfium\pdfium.dll');
      Reader.Show;
      Watch:=TStopwatch.StartNew;
      while (not Reader.Ready or Reader.PageLoading) and (Watch.ElapsedMilliseconds<20000) do Pump(30);
      Require(Reader.Ready and not Reader.PageLoading,Extension+' did not open');
      Reader.ReadingSurface.SetFocus;
      Reader.SetPageLayout(rplSingle);
      TContinuousScrollSurface(Reader.ReadingSurface).DoMouseWheel([],-WHEEL_DELTA,Point(0,0));
      Watch:=TStopwatch.StartNew;
      while (Reader.TextPosition=0) and (Watch.ElapsedMilliseconds<10000) do Pump(30);
      Position:=Reader.TextPosition;
      Require(Position>0,Extension+' wheel did not turn the page in paged mode');
      PressArrow(VK_LEFT,1);
      Watch:=TStopwatch.StartNew;
      while (Reader.TextPosition<>0) and (Watch.ElapsedMilliseconds<5000) do Pump(20);
      Require(Reader.TextPosition=0,Extension+' Left key did not turn a page back');
      PressArrow(VK_RIGHT,1);
      Watch:=TStopwatch.StartNew;
      while (Reader.TextPosition=0) and (Watch.ElapsedMilliseconds<5000) do Pump(20);
      Require(Reader.TextPosition=Position,Extension+' Right key did not turn a page forward');
      PressArrow(VK_PRIOR,1);
      Watch:=TStopwatch.StartNew;
      while (Reader.TextPosition<>0) and (Watch.ElapsedMilliseconds<5000) do Pump(20);
      Require(Reader.TextPosition=0,Extension+' Page Up stopped working');
      PressArrow(VK_NEXT,1);
      Watch:=TStopwatch.StartNew;
      while (Reader.TextPosition=0) and (Watch.ElapsedMilliseconds<5000) do Pump(20);
      Require(Reader.TextPosition=Position,Extension+' Page Down stopped working');
      Reader.SetPageLayout(rplContinuous);
      Reader.GoToPosition(0);
      Watch:=TStopwatch.StartNew;
      while ((Reader.TextPosition<>0) or (Reader.PageRasterSize.Y<2*Reader.ReadingSurface.ClientHeight)) and
        (Watch.ElapsedMilliseconds<15000) do Pump(30);
      Require((Reader.TextPosition=0) and (Reader.PageRasterSize.Y>=2*Reader.ReadingSurface.ClientHeight),
        Extension+' did not prepare the adjacent content');
      Pump(180);
      TContinuousScrollSurface(Reader.ReadingSurface).DoMouseWheel([],-WHEEL_DELTA,Point(0,0));
      if Raster then
      begin
        Frames:=0;
        LastTop:=0;
        for I:=1 to 40 do
        begin
          Pump(18);
          if Reader.PDFPan.Y<LastTop then
          begin
            LastTop:=Reader.PDFPan.Y;
            Inc(Frames);
          end;
          if (I>24) and (Frames>=3) then Break;
        end;
        Require((Reader.TextPosition=0) and (Frames>=3),
          Format('%s wheel drew %d intermediate frames before turning', [Extension,Frames]));
        Steps:=Reader.ReadingSurface.ClientHeight;
        if Extension='cbz' then Steps:=Reader.PageRasterSize.Y div 2;
        Steps:=Steps div Max(1,MulDiv(30,Reader.CurrentPPI,96))+4;
        PressArrow(VK_DOWN,Steps);
        Watch:=TStopwatch.StartNew;
        while ((Reader.TextPosition=0) or (Reader.PDFPan.Y=0)) and (Watch.ElapsedMilliseconds<5000) do Pump(30);
        Require((Reader.TextPosition=1) and (Reader.PDFPan.Y<0),Format(
          '%s boundary failed: page=%d top=%d strip=%d viewport=%d (%s)',
          [Extension,Reader.TextPosition,Reader.PDFPan.Y,Reader.PageRasterSize.Y,
           Reader.ReadingSurface.ClientHeight,Reader.ReaderStatus.Caption]));
        PressArrow(VK_UP,Steps);
        Watch:=TStopwatch.StartNew;
        while (Reader.TextPosition>0) and (Watch.ElapsedMilliseconds<5000) do Pump(30);
        Require(Reader.TextPosition=0,Extension+' could not scroll backwards');
        if Extension='cbz' then
        begin
          Reader.GoToPosition(4);
          Watch:=TStopwatch.StartNew;
          while ((Reader.TextPosition<>4) or Reader.PageLoading) and (Watch.ElapsedMilliseconds<5000) do Pump(20);
          Require(Reader.TextPosition=4,'Could not seek before the uncached backward scroll');
          TContinuousScrollSurface(Reader.ReadingSurface).DoMouseWheel([],WHEEL_DELTA,Point(0,0));
          Watch:=TStopwatch.StartNew;
          while (Reader.TextPosition<>3) and (Watch.ElapsedMilliseconds<5000) do Pump(20);
          Pump(380);
          Require((Reader.TextPosition=3) and (Reader.PDFPan.Y<-(Reader.ReadingSurface.ClientHeight div 4)),
            'Backward scroll after seeking lost its remainder when the previous page loaded');
        end;
        Writeln('PASS smooth fixed-layout wheel and arrows: ',Extension,', intermediate frames=',Frames);
      end
      else
      begin
        Pump(500);
        Require((Reader.TextPosition>0) and (Reader.TextPosition<Position),
          Extension+' wheel jumped a page or did not scroll');
        Writeln('PASS smooth flowing-text wheel: ',Extension);
      end;
      Reader.Close;
    finally Reader.Free; end;
    Require(THashSHA2.GetHashStringFromFile(FileName)=Original,Extension+' source changed');
  end;
  FileName:=Settings.AppPath+'reader-tall.cbz';
  Original:=THashSHA2.GetHashStringFromFile(FileName);
  var Profile:=Settings.AppPath+'scroll-tall-comic.ini';
  var ImageArchive:=Default(TBookRecord);
  ImageArchive.CollectionRoot:=Settings.AppPath; ImageArchive.FileName:='scanned-document';
  ImageArchive.FileExt:='.zip'; ImageArchive.LibID:='scanned-document'; ImageArchive.BookProps:=[bpIsLocal];
  TFile.Copy(FileName,ImageArchive.GetBookFileName);
  var PreparedImages:=PrepareReaderFile(ImageArchive,True);
  Require(SameText(ExtractFileExt(PreparedImages),'.cbz') and
    (THashSHA2.GetHashStringFromFile(PreparedImages)=Original),'Image-only ZIP lost its original page set');
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.OpenBook(FileName,'Tall comic','reader-tall',Profile,'');
    Reader.Show;
    Reader.Width:=1150; Reader.Height:=720;
    Pump(220);
    Watch:=TStopwatch.StartNew;
    while not Reader.Ready and (Watch.ElapsedMilliseconds<20000) do Pump(30);
    Require(Reader.Ready,'Tall comic failed to open');
    Reader.ReadingSurface.SetFocus;
    Reader.SetPageLayout(rplContinuous);
    var FitWidth:=Reader.ReadingSurface.ClientWidth-MulDiv(24,Reader.CurrentPPI,96);
    var FirstPageHeight:=MulDiv(18000,FitWidth,900);
    Watch:=TStopwatch.StartNew;
    while (Reader.PageRasterSize.Y<=FirstPageHeight+MulDiv(12,Reader.CurrentPPI,96)) and
      (Watch.ElapsedMilliseconds<20000) do Pump(30);
    Require((Reader.PageRasterSize.X=FitWidth) and
      (Reader.PageRasterSize.Y>FirstPageHeight+MulDiv(12,Reader.CurrentPPI,96)),
      'Tall comic did not fit the width or prepare its next page');
    Require(Int64(Reader.PageRasterSize.X)*Reader.PageRasterSize.Y>25000000,
      'Fixture does not exercise a strip too large for the old bitmap');
    var ScreenHeight:=Reader.ReadingSurface.ClientHeight;
    var FirstTop:=Reader.PDFPan.Y;
    PressArrow(VK_NEXT,1);
    Require((Reader.TextPosition=0) and (Reader.PDFPan.Y=FirstTop-ScreenHeight),
      'Page Down skipped a long image or failed to move one screen immediately');
    PressArrow(VK_PRIOR,1);
    Require((Reader.TextPosition=0) and (Reader.PDFPan.Y=FirstTop),
      'Page Up did not immediately return one screen on the same image');
    Reader.GoToPosition(1);
    Watch:=TStopwatch.StartNew;
    while ((Reader.TextPosition<>1) or Reader.PageLoading) and
      (Watch.ElapsedMilliseconds<10000) do Pump(20);
    Require(Reader.TextPosition=1,'Cannot position the test at the next image');
    var SecondTop:=Reader.PDFPan.Y;
    var SeamTop:=FirstTop-FirstPageHeight-MulDiv(12,Reader.CurrentPPI,96)+ScreenHeight;
    PressArrow(VK_PRIOR,1);
    Watch:=TStopwatch.StartNew;
    while ((Reader.TextPosition<>0) or (Reader.PDFPan.Y<>SeamTop)) and
      (Watch.ElapsedMilliseconds<10000) do Pump(20);
    Require((Reader.TextPosition=0) and (Reader.PDFPan.Y=SeamTop),
      'Page Up across images lost part of the preceding screen');
    PressArrow(VK_NEXT,1);
    Watch:=TStopwatch.StartNew;
    while ((Reader.TextPosition<>1) or (Reader.PDFPan.Y<>SecondTop)) and
      (Watch.ElapsedMilliseconds<10000) do Pump(20);
    Require((Reader.TextPosition=1) and (Reader.PDFPan.Y=SecondTop),
      'Page Down across images did not return to the next image boundary');
    Writeln('PASS Page Up and Page Down move one screen immediately within and across long images');
    Reader.GoToPosition(0);
    Watch:=TStopwatch.StartNew;
    while ((Reader.TextPosition<>0) or Reader.PageLoading) and
      (Watch.ElapsedMilliseconds<10000) do Pump(20);
    Require((Reader.TextPosition=0) and (Reader.PDFPan.Y=FirstTop),'Cannot reset after testing screen navigation');
    var Capture:=Vcl.Graphics.TBitmap.Create;
    try
      Capture.SetSize(Reader.ReadingSurface.ClientWidth,Reader.ReadingSurface.ClientHeight);
      Reader.ReadingSurface.PaintTo(Capture.Canvas.Handle,0,0);
      Require(ColorToRGB(Capture.Canvas.Pixels[Reader.PDFPan.X+5,30])=RGB(36,70,150),
        'Tall page pixels did not fill the reading width');
      PressArrow(VK_DOWN,(FirstPageHeight-Reader.ReadingSurface.ClientHeight div 2) div
        Max(1,MulDiv(30,Reader.CurrentPPI,96)));
      Watch:=TStopwatch.StartNew;
      while (Reader.PDFPan.Y>-(FirstPageHeight-Reader.ReadingSurface.ClientHeight)) and
        (Watch.ElapsedMilliseconds<12000) do Pump(20);
      Pump(650);
      Reader.ReadingSurface.PaintTo(Capture.Canvas.Handle,0,0);
      var CenterX:=Capture.Width div 2;
      Require((Reader.TextPosition=0) and (ColorToRGB(Capture.Canvas.Pixels[CenterX,30])=RGB(146,95,80))
        and (ColorToRGB(Capture.Canvas.Pixels[CenterX,Capture.Height-30])=RGB(66,70,150)),
        'Scrolling across a tall page boundary skipped pixels or the neighbour');
    finally Capture.Free; end;
    PressArrow(VK_DOWN,Reader.ReadingSurface.ClientHeight div Max(1,MulDiv(30,Reader.CurrentPPI,96))+4);
    Watch:=TStopwatch.StartNew;
    while (Reader.TextPosition=0) and (Watch.ElapsedMilliseconds<5000) do Pump(30);
    Require(Reader.TextPosition=1,'Tall comic could not advance to the preloaded page');
    Pump(600);
    Position:=Reader.PDFPan.Y;
    Require(Position<0,'Tall comic lost the scroll remainder on the next page');
    PressArrow(VK_UP,(-Position+Reader.ReadingSurface.ClientHeight div 2) div
      Max(1,MulDiv(30,Reader.CurrentPPI,96)));
    Watch:=TStopwatch.StartNew;
    while (Reader.TextPosition<>0) and (Watch.ElapsedMilliseconds<10000) do Pump(20);
    Pump(650);
    Require((Reader.TextPosition=0) and
      (Reader.PDFPan.Y<-(FirstPageHeight-Reader.ReadingSurface.ClientHeight)),
      'Going backwards skipped the bottom part of the previous tall page');
    PressArrow(VK_DOWN,Reader.ReadingSurface.ClientHeight div Max(1,MulDiv(30,Reader.CurrentPPI,96))+4);
    Watch:=TStopwatch.StartNew;
    while (Reader.TextPosition<>1) and (Watch.ElapsedMilliseconds<5000) do Pump(20);
    Pump(650);
    Require(Reader.TextPosition=1,'The tall comic could not be opened past the boundary again');
    Position:=Reader.PDFPan.Y;
    CheckNavigationDialog(0);
    Reader.Close;
  finally Reader.Free; end;

  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.OpenBook(PreparedImages,'Scanned document','reader-tall',Profile,'');
    Reader.Show;
    Reader.Width:=1150; Reader.Height:=720;
    Pump(220);
    Watch:=TStopwatch.StartNew;
    while ((not Reader.Ready) or (Reader.TextPosition<>1) or (Reader.PDFPan.Y=0)) and
      (Watch.ElapsedMilliseconds<20000) do Pump(30);
    Require((Reader.PageLayout=rplContinuous) and (Reader.TextPosition=1) and
      (Abs(Reader.PDFPan.Y-Position)<12),'Tall comic did not restore the scroll position');
    Reader.SetPageLayout(rplSingle);
    Require(Reader.PageRasterSize.X<Reader.ReadingSurface.ClientWidth div 3,
      'Paged comic did not restore whole-page fitting');
    Reader.SetPageLayout(rplContinuous);
    Reader.GoToPosition(0);
    Watch:=TStopwatch.StartNew;
    while (Reader.TextPosition<>0) and (Watch.ElapsedMilliseconds<10000) do Pump(20);
    CheckNavigationDialog(1);
    var CustomScreenHeight:=Reader.ReadingSurface.ClientHeight;
    var OriginalTop:=Reader.PDFPan.Y;
    PressArrow(VK_NEXT,1);
    Require(Reader.PDFPan.Y=OriginalTop,'A replaced key still ran its previous command');
    PressArrow(Ord('D'),1);
    Require(Reader.PDFPan.Y=OriginalTop-CustomScreenHeight,'Custom key did not move one screen');
    PressArrow(Ord('A'),1);
    Require(Reader.PDFPan.Y=OriginalTop,'Custom key did not move one screen back');
    CheckNavigationDialog(2);
    PressArrow(VK_NEXT,1);
    Require(Reader.PDFPan.Y=OriginalTop-CustomScreenHeight,'Default navigation did not return after saving');
    PressArrow(VK_PRIOR,1);
    Require(Reader.PDFPan.Y=OriginalTop,'Restored default key did not move one screen back');
    Writeln('PASS customizable reader navigation, conflicts, cancellation, persistence and reset');
    var ScaleMenu:=Reader.FindComponent('ReaderSelectionMenu') as TPopupMenu;
    var OriginalButton:=Reader.FindComponent('ReaderOriginalRasterButton') as TButton;
    var FitButton:=Reader.FindComponent('ReaderFitPage') as TButton;
    var FullScreenItem:=ScaleMenu.FindComponent('ReaderFullScreenMenu') as TMenuItem;
    Reader.ToggleInterface;
    ScaleMenu.OnPopup(ScaleMenu);
    Require(Assigned(FullScreenItem) and (FullScreenItem.Caption='На весь экран'),
      'The context menu cannot enter fullscreen with the interface hidden');
    FullScreenItem.Click;
    ScaleMenu.OnPopup(ScaleMenu);
    Require(Reader.FullScreenMode and Reader.InterfaceHidden and
      (FullScreenItem.Caption='Выйти из полноэкранного режима'),
      'Fullscreen context command changed interface visibility or lacked an exit');
    FullScreenItem.Click;
    Require(not Reader.FullScreenMode and Reader.InterfaceHidden,'Context command did not restore window mode');
    Reader.ToggleInterface;
    ScaleMenu.OnPopup(ScaleMenu);
    Require((ScaleMenu.Items[1].Name='ReaderOriginalRasterScale') and ScaleMenu.Items[1].Visible,
      'The comic has no original-scale command');
    ScaleMenu.Items[1].Click;
    Watch:=TStopwatch.StartNew;
    while ((Reader.PageRasterSize.X<>900) or (Reader.PageRasterSize.Y<30000)) and
      (Watch.ElapsedMilliseconds<15000) do Pump(30);
    Require((Reader.PageRasterSize.X=900) and (Reader.PageRasterSize.Y>=30000),
      'The tall comic was not rendered at its original 900-pixel width');
    Reader.SetInspectionPercent(200);
    CheckScaleDialog(1,0,False);
    Require(Reader.PageRasterSize.X=900,'Cancel changed the original image scale');
    CheckScaleDialog(1,0,True);
    var FitWidth:=Reader.ReadingSurface.ClientWidth-MulDiv(24,Reader.CurrentPPI,96);
    Watch:=TStopwatch.StartNew;
    while (Reader.PageRasterSize.X<>FitWidth) and (Watch.ElapsedMilliseconds<15000) do Pump(30);
    Require(Reader.PageRasterSize.X=FitWidth,'Fit-to-width choice did not resize the image');
    Require(Assigned(OriginalButton) and OriginalButton.Visible and OriginalButton.Enabled and
      Assigned(FitButton) and (OriginalButton.Top=FitButton.Top) and (OriginalButton.Left>FitButton.Left),
      'Original scale button is missing beside the fitted-scale button');
    OriginalButton.Click;
    Watch:=TStopwatch.StartNew;
    while (Reader.PageRasterSize.X<>900) and (Watch.ElapsedMilliseconds<15000) do Pump(30);
    Require(Reader.PageRasterSize.X=900,'Toolbar 100 percent button did not select original size');
    FitButton.Click;
    Watch:=TStopwatch.StartNew;
    while (Reader.PageRasterSize.X<>FitWidth) and (Watch.ElapsedMilliseconds<15000) do Pump(30);
    Require(Reader.PageRasterSize.X=FitWidth,'Toolbar fit button did not restore fitted size');
    Writeln('PASS comic toolbar and hidden interface context menu provide scale and fullscreen');
    CheckScaleDialog(0,1,True);
    Watch:=TStopwatch.StartNew;
    while (Reader.PageRasterSize.X<>900) and (Watch.ElapsedMilliseconds<15000) do Pump(30);
    Require(Reader.PageRasterSize.X=900,'Original image scale from View did not render at 100 percent');
    Reader.Close;
    Watch:=TStopwatch.StartNew;
    while Reader.Visible and (Watch.ElapsedMilliseconds<10000) do Pump(30);
    Require(not Reader.Visible,'Image reader did not finish closing after background preparation');
  finally Reader.Free; end;
  var SavedScale:=TMemIniFile.Create(Profile,TEncoding.UTF8);
  try
    Require(SavedScale.ReadBool('Book.'+Copy(THashSHA2.GetHashString('reader-tall'),1,40),'OriginalRasterScale',False) and
      (SavedScale.ReadInteger('Reader','InspectionPercent',0)=200),
      'Image scale and temporary zoom did not save independently');
  finally SavedScale.Free; end;
  Require(THashSHA2.GetHashStringFromFile(FileName)=Original,'Tall comic source changed');
  Require(THashSHA2.GetHashStringFromFile(ImageArchive.GetBookFileName)=Original,'Scanned document archive changed');
  Writeln('PASS image-only ZIP opens as pages and View sets original or fitted scale independently of temporary zoom');
  Writeln('PASS tall comic viewport fits width, draws both sides of a boundary and restores the scroll position');
  Writeln('PASS continuous scrolling preserves ordinary wheel paging and advances in intermediate frames');
end;
