procedure AuditWordSelection;
var Reader: TfrmBuiltinReader; Painted: TBitmap; Surface: TWinControl;
  FileName, Query, BeforeHash, Text: string; Right, Top, Bottom, Left, Row, ClickX, ClickY: Integer;
  Key: Word; Watch: TStopwatch;
  procedure LocateWord;
  var X,Y: Integer;
    function IsMarker(Color: TColor): Boolean;
    var RGB: COLORREF;
    begin
      RGB:=ColorToRGB(Color);
      if FileName='words.pdf' then
        Result:=(GetGValue(RGB)>GetRValue(RGB)+40) and (GetGValue(RGB)>GetBValue(RGB)+40)
      else Result:=RGB=ColorToRGB(clLime);
    end;
  begin
    Painted.SetSize(Surface.Width,Surface.Height); Surface.PaintTo(Painted.Canvas.Handle,0,0);
    Right:=-1; Top:=-1;
    for Y:=0 to Surface.Height-1 do for X:=0 to Surface.Width-1 do
      if (X>Right) and IsMarker(Painted.Canvas.Pixels[X,Y]) then
      begin Right:=X; Top:=Y; end;
    Require((Right>=0) and (Top>=0),'Visible search marker absent for double-click: '+FileName+' / '+Query);
    Bottom:=Top;
    while (Bottom+1<Surface.Height) and
      IsMarker(Painted.Canvas.Pixels[Right,Bottom+1]) do Inc(Bottom);
    Row:=(Top+Bottom) div 2; Left:=Right;
    for X:=Max(0,Right-200) to Right do
      if IsMarker(Painted.Canvas.Pixels[X,Row]) then begin Left:=X; Break; end;
    ClickX:=(Left+Right) div 2; ClickY:=Row;
  end;
  procedure DoubleClick(X,Y: Integer);
  begin
    SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(X,Y));
    SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(X,Y));
    if FileName='words.pdf' then
    begin Writeln('TRACE PDF point=',X,',',Y,' first-click text=[',Reader.SelectedText,']'); Flush(Output); end;
    SendMessage(Surface.Handle,WM_LBUTTONDBLCLK,MK_LBUTTON,MakeLParam(X,Y));
    SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(X,Y));
  end;
begin
  for FileName in ['words.fb2','words.epub','words.txt','words.pdf'] do
  begin
    BeforeHash:=THashSHA2.GetHashStringFromFile(FileName);
    Reader:=TfrmBuiltinReader.Create(nil); Painted:=TBitmap.Create;
    try
      Reader.SetBounds(60,60,1040,760); Reader.Show;
      Reader.OpenBook(FileName,'Word selection',FileName,'words.ini','pdfium.dll'); WaitReady(Reader);
      Reader.SetTypography('Georgia',110,24); Reader.SetPageAppearance(rpaFlat); Reader.SetMaxTextWidth(960);
      Surface:=Reader.ReadingSurface; Text:=Reader.BookText;
      for var Layout in [rplSingle,rplDouble] do
      begin
        Reader.SetPageLayout(Layout); WaitPage(Reader);
        for var Theme in [1,4] do
        begin
          Reader.SetTheme(Theme); Reader.SetHighlightColor(clLime); Reader.SetSearchOptions(True,False,True);
          for Query in ['Привет','café','😀','Needle'] do
          begin
            if (FileName='words.pdf')<>(Query='Needle') then Continue;
            Reader.SetSelectionEnabled(False); Reader.SetSelectionEnabled(True); Reader.FindText(Query);
            Watch:=TStopwatch.StartNew;
            while (Reader.PageLoading or Reader.SearchRunning) and (Watch.ElapsedMilliseconds<10000) do
            begin Application.ProcessMessages; CheckSynchronize(5); end;
            Require(not Reader.PageLoading and not Reader.SearchRunning and
              (Pos('Найдено',Reader.ReaderStatus.Caption)>0),'Word search did not finish: '+FileName);
            LocateWord;
            if FileName='words.pdf' then
            begin Writeln('TRACE PDF word layout=',Ord(Layout),' theme=',Theme,' bounds=',Left,',',Top,'..',Right,',',Bottom); Flush(Output); end;
            if Layout=rplDouble then
              Require(ClickX>Surface.Width div 2,'Double-click did not exercise the right text page');
            DoubleClick(ClickX,ClickY);
            Require(Reader.SelectedText=Query,'Double-click did not select visible word: '+FileName+
              ' expected=['+Query+'] got=['+Reader.SelectedText+']');
            Key:=Ord('C'); Reader.OnKeyDown(Reader,Key,[ssCtrl]);
            Require(ReadClipboardText=Query,'Double-click copied different Unicode text');
            if FileName<>'words.pdf' then
            begin
              SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(Left-1,ClickY));
              SendMessage(Surface.Handle,WM_MOUSEMOVE,MK_LBUTTON,MakeLParam(Right+1,ClickY));
              SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(Right+1,ClickY));
              Require(Reader.SelectedText=Query,'Double-click change broke ordinary mouse drag selection');
              DoubleClick(0,Surface.Height-1);
              Require(Reader.SelectedText='','Double-click in a blank margin selected hidden/nearest text');
            end;
            Reader.SetSelectionEnabled(False); DoubleClick(ClickX,ClickY);
            Require(Reader.SelectedText='','Disabled mouse selection was ignored by double-click');
            Reader.SetSelectionEnabled(True);
            Require(Reader.BookText=Text,'Word selection changed the loaded book text');
          end;
        end;
      end;
      Reader.Close;
    finally Painted.Free; Reader.Free; end;
    Require(THashSHA2.GetHashStringFromFile(FileName)=BeforeHash,'Word selection changed original book bytes');
    Writeln('PASS double-click selects exact visible Unicode word and copies it in both layouts and themes: '+FileName);
  end;
  Writeln('PASS double-click respects selection switch margins ordinary dragging and unchanged sources');
end;
