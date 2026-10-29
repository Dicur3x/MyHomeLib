procedure TestReaderLinkFeedback;
const NS='http://www.gribuser.ru/xml/fictionbook/2.0';
var Files:TArray<string>; Labels:TArray<string>; Text, Prefix, Source, EPUB, LabelText, BeforeHash:string;
  Doc:TReaderDocument; Reader:TfrmBuiltinReader; Painted:TBitmap; Links:TArray<TReaderTextLink>;
  Target, At, L,R,T,B,X,Y, ClickX, ClickY, Resolved:Integer; Started:UInt64; Zip:TZipFile; Part:TStringStream;
  procedure AddZip(const Name, Value:string);
  begin Part:=TStringStream.Create(Value,TEncoding.UTF8); try Zip.Add(Part,Name); finally Part.Free; end; end;
  procedure Wait;
  begin
    Started:=GetTickCount64;
    while not Reader.LoadFinished do
    begin Application.ProcessMessages; CheckSynchronize(2); Sleep(5); Require(GetTickCount64-Started<15000,'Reader link loading timed out'); end;
    Require(Reader.Ready,'Reader link fixture failed: '+Reader.ReaderStatus.Caption);
  end;
  procedure CheckDeclaredOutline;
  var Path, Navigation, ManifestText, SpineText, Hash:string; D:TReaderDocument;
  begin
    for var Variant:=0 to 2 do
    begin
      Path:=Settings.AppPath+'outline-'+IntToStr(Variant)+'.epub';
      if Variant=1 then
      begin
        ManifestText:='<item id="toc" href="nav.xhtml" properties="nav"/>'; SpineText:='';
        Navigation:='<html xmlns:epub="http://www.idpf.org/2007/ops"><body>'+
          '<nav epub:type="landmarks"><ol><li><a href="one.xhtml">WRONG_LANDMARK</a></li></ol></nav>'+
          '<nav epub:type="toc"><ol><li><a href="one.xhtml">FirstDeclared</a><ol>'+
          '<li><a href="one.xhtml#sub">SubDeclared</a></li></ol></li>'+
          '<li><a href="part+two.xhtml#%D1%91%D0%B6">SecondDeclared</a></li>'+
          '<li><a href="part+two.xhtml#%D1%91%D0%B6">DuplicateTarget</a></li>'+
          '<li><a href="https://example.invalid/book">External</a></li></ol></nav></body></html>';
      end
      else
      begin
        ManifestText:='<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'; SpineText:=' toc="toc"';
        Navigation:='<ncx><navMap><navPoint><navLabel><text>FirstDeclared</text></navLabel><content src="one.xhtml"/>'+
          '<navPoint><navLabel><text>SubDeclared</text></navLabel><content src="one.xhtml#sub"/></navPoint></navPoint>'+
          '<navPoint><navLabel><text>SecondDeclared</text></navLabel><content src="part+two.xhtml#%D1%91%D0%B6"/></navPoint></navMap></ncx>';
        if Variant=2 then Navigation:='<ncx><broken>';
      end;
      Zip:=TZipFile.Create;
      try
        Zip.Open(Path,zmWrite); AddZip('mimetype','application/epub+zip');
        AddZip('META-INF/container.xml','<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>');
        AddZip('OPS/book.opf','<package><manifest><item id="one" href="one.xhtml"/><item id="two" href="part+two.xhtml"/>'+
          ManifestText+'</manifest><spine'+SpineText+'><itemref idref="one"/><itemref idref="two"/></spine></package>');
        AddZip('OPS/one.xhtml','<html><body><h1>VisibleHeading</h1><p>FirstProse</p><p id="sub">SubProse</p></body></html>');
        AddZip('OPS/part+two.xhtml','<html><body><p id="ёж">LastProse</p></body></html>');
        if Variant=1 then AddZip('OPS/nav.xhtml',Navigation) else AddZip('OPS/toc.ncx',Navigation);
      finally Zip.Free; end;
      Hash:=UpdateSHA256(Path); D:=TReaderDocument.Create;
      try
        D.Load(Path); var Chapters:=D.Chapters;
        if Variant=2 then
          Require((Length(Chapters)=1) and (Chapters[0].Title='VisibleHeading') and (D.Warnings.Count>0),'Broken optional outline prevented fallback to visible headings')
        else
        begin
          Require(Length(Chapters)=3,'Declared EPUB navigation contains missing, duplicate or unrelated chapters');
          Require((Chapters[0].Title='FirstDeclared') and (Chapters[1].Title='SubDeclared') and (Chapters[2].Title='SecondDeclared'),'Publisher chapter labels were not retained');
          Require((Chapters[1].Depth=1) and (Chapters[2].Depth=0),'Declared EPUB chapter nesting changed');
          Require((Chapters[0].Position<Chapters[1].Position) and (Chapters[1].Position<Chapters[2].Position),'Declared EPUB chapters are not in reading order');
          Require(Copy(D.PlainText,Chapters[2].Position+1,Length('LastProse'))='LastProse','Unicode and plus-path outline target points at the wrong paragraph');
        end;
        Require(UpdateSHA256(Path)=Hash,'Outline reading changed the EPUB source');
      finally D.Free; end;
    end;
    Writeln('PASS EPUB NCX/nav outlines retain labels depth and literal targets with malformed-navigation fallback');
  end;
begin
  RequireIsolatedRegression;
  Source:=Settings.AppPath+'link-feedback.fb2'; EPUB:=Settings.AppPath+'link-feedback.epub';
  Text:=''; for var I:=1 to 65 do Text:=Text+'<p>Unchanged filler paragraph '+IntToStr(I)+'</p>';
  Prefix:=''; for var I:=1 to 30 do Prefix:=Prefix+'<p>Leading paragraph '+IntToStr(I)+'</p>';
  TFile.WriteAllText(Source,'<FictionBook xmlns="'+NS+'" xmlns:l="http://www.w3.org/1999/xlink">'+
    '<body><section>'+Prefix+'<title><p>Contents</p></title><p><a l:href="#chapter">OPEN_CHAPTER</a></p>'+
    '<p><a l:href="#missing">MISSING_TARGET</a> <a l:href="https://example.invalid/">EXTERNAL_LINK</a></p>'+
    '<p>Note <a l:href="#n" type="note">1</a></p>'+Text+'</section>'+
    '<section id="chapter"><title><p>CHAPTER_DESTINATION</p></title><p>Destination text survives.</p></section></body>'+
    '<body name="notes"><section id="n"><title><p>1</p></title><p>REAL_FOOTNOTE</p></section></body></FictionBook>',TEncoding.UTF8);
  Zip:=TZipFile.Create;
  try
    Zip.Open(EPUB,zmWrite); AddZip('mimetype','application/epub+zip');
    AddZip('META-INF/container.xml','<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>');
    AddZip('OPS/book.opf','<package><metadata><title>Links</title></metadata><manifest>'+
      '<item id="one" href="one.xhtml"/><item id="two" href="part+two.xhtml"/></manifest>'+
      '<spine><itemref idref="one"/><itemref idref="two"/></spine></package>');
    AddZip('OPS/one.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><body>'+Prefix+'<h1>Contents</h1>'+
      '<p><a href="part+two.xhtml#%D1%91%D0%B6">OPEN_CHAPTER</a></p>'+
      '<p><a href="missing.xhtml#x">MISSING_TARGET</a> <a href="https://example.invalid/">EXTERNAL_LINK</a></p>'+Text+'</body></html>');
    AddZip('OPS/part+two.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="ёж">CHAPTER_DESTINATION</h1>'+
      '<p>Destination text survives.</p><p><a href="one.xhtml">BACK_TO_START</a></p></body></html>');
  finally Zip.Free; end;
  CheckDeclaredOutline;
  Files:=[Source,EPUB]; Labels:=['OPEN_CHAPTER','OPEN_CHAPTER'];
  for var Name in ['HLRU_WIZARD_EPUB','HLRU_WIZARD_FB2'] do
  begin
    var Path:=GetEnvironmentVariable(Name);
    if Path<>'' then begin Require(FileExists(Path),'Actual Wizard fixture missing'); Files:=Files+[Path]; Labels:=Labels+['']; end;
  end;
  for var I:=0 to High(Files) do
  begin
    Source:=Files[I]; BeforeHash:=UpdateSHA256(Source); Doc:=TReaderDocument.Create;
    try
      Doc.Load(Source); Links:=Doc.Links; Resolved:=0;
      for var Link in Links do if Doc.LinkTargetAt(Link.Start,Target) then Inc(Resolved);
      if I<2 then
      begin
        Require(Resolved>=1,'No internal chapter target was retained');
        At:=Pos('OPEN_CHAPTER',Doc.PlainText)-1;
        Require(Doc.LinkTargetAt(At,Target) and (Target>At),'Ordinary chapter link did not resolve forward');
        Require(not Doc.LinkTargetAt(Pos('MISSING_TARGET',Doc.PlainText)-1,Target),'Broken link resolved to an arbitrary page');
        Require(not Doc.LinkTargetAt(Pos('EXTERNAL_LINK',Doc.PlainText)-1,Target),'External URL became an internal navigation action');
        if I=0 then
        begin
          Require((Doc.FootnoteCount=1) and Doc.FootnotesForRange(0,Doc.PlainText.Length).Contains('REAL_FOOTNOTE'),'Chapter links displaced real footnotes');
          for var Style in Doc.Styles do
            if (At>=Style.Start) and (At<Style.Start+Style.Count) then Require(Style.Kind<>rbFootnote,'Ordinary chapter label is styled as a superscript footnote');
        end;
        LabelText:=Labels[I];
      end
      else
      begin
        Require((Length(Links)>=35) and (Resolved=Length(Links)),'Actual Wizard contents has unresolved links');
        var Chapters:=Doc.Chapters;
        Require(Length(Chapters)=37,'Actual Wizard publisher outline has missing chapters');
        Require(Chapters[High(Chapters)].Title='Other Series by The Author','Actual Wizard afterword or author sections lost from chapter outline');
        LabelText:='Chapter 1 Walking and Wondering';
        At:=Pos(LabelText,Doc.PlainText)-1; Require(At>=0,'Actual Wizard chapter link label missing');
      end;
      Require(Doc.LinkTargetAt(At,Target),'Chosen reader navigation target missing');
      for var Layout in [rplSingle,rplDouble] do
      begin
        Reader:=TfrmBuiltinReader.Create(nil); Painted:=TBitmap.Create;
        try
          Reader.SetBounds(60,60,1100,760); Reader.Show;
          Reader.OpenBook(Source,'Links','link-'+IntToStr(I)+'-'+IntToStr(Ord(Layout)),Settings.AppPath+'link-reader.ini','pdfium.dll'); Wait;
          Reader.SetSelectionEnabled(True);
          Reader.SetPageLayout(Layout); Reader.SetTheme(4); Reader.SetHighlightColor(clLime);
          Reader.SetSearchOptions(True,False,False);
          Reader.FindText('__HLRU_no_link_query__'); Reader.GoToPosition(At); Reader.FindText(LabelText);
          Require(Reader.MatchPosition=At,'Link marker selected a different occurrence');
          if (Layout=rplDouble) and (I<2) then
          begin
            Reader.SetPageTurn(rptSliding); Reader.PreviousPage;
            Require(Reader.TextPosition<At,'Right-page link probe did not move back one page');
          end;
          var Position:=Reader.TextPosition;
          Painted.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
          Reader.ReadingSurface.PaintTo(Painted.Canvas.Handle,0,0);
          L:=Painted.Width; R:=-1; T:=Painted.Height; B:=-1;
          for Y:=0 to Painted.Height-1 do for X:=0 to Painted.Width-1 do
            if ColorToRGB(Painted.Canvas.Pixels[X,Y])=ColorToRGB(clLime) then
            begin L:=Min(L,X); R:=Max(R,X); T:=Min(T,Y); B:=Max(B,Y); end;
          Require((R>L) and (B>T),'Linked text was not painted at the expected range'); ClickX:=(L+R) div 2; ClickY:=(T+B) div 2;
          if (Layout=rplDouble) and (I<2) then Require(L>Painted.Width div 2,'Double-page link probe is not on the right page');
          Writeln('TRACE link source=',I,' layout=',Ord(Layout),' at=',At,' target=',Target,' pos=',Position,' marker=',L,',',T,'-',R,',',B); Flush(Output);
          Reader.ReadingSurface.Perform(WM_MOUSEMOVE,0,MakeLParam(ClickX,ClickY));
          Require(Reader.ReadingSurface.Cursor=crHandPoint,'Visible link has no navigation cursor');
          Reader.ReadingSurface.Perform(WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(0,ClickY));
          Reader.ReadingSurface.Perform(WM_LBUTTONUP,0,MakeLParam(0,ClickY));
          Require(Reader.TextPosition=Position,'A click in the margin followed the nearest link');
          Reader.ReadingSurface.Perform(WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(L,ClickY));
          Reader.ReadingSurface.Perform(WM_MOUSEMOVE,MK_LBUTTON,MakeLParam(R,ClickY));
          Reader.ReadingSurface.Perform(WM_LBUTTONUP,0,MakeLParam(R,ClickY));
          Require((Reader.TextPosition=Position) and (Reader.SelectedText<>''),'Dragging a link navigated instead of selecting its text');
          Reader.ReadingSurface.Perform(WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(ClickX,ClickY));
          Reader.ReadingSurface.Perform(WM_LBUTTONUP,0,MakeLParam(ClickX,ClickY));
          Require(Reader.TextPosition=Target,'Clicking the visible chapter link did not navigate to its target');
          Reader.GoToPosition(Position); Reader.SetSelectionEnabled(False);
          Reader.ReadingSurface.Perform(WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(ClickX,ClickY));
          Reader.ReadingSurface.Perform(WM_LBUTTONUP,0,MakeLParam(ClickX,ClickY));
          Require(Reader.TextPosition=Target,'Disabling text selection also disabled internal links');
          Reader.Close;
        finally Painted.Free; Reader.Free; end;
      end;
      if I>=2 then Writeln('PASS actual Wizard ',ExtractFileExt(Source),' all ',Resolved,' internal links resolve and chapter click opens its target');
    finally Doc.Free; end;
    Require(UpdateSHA256(Source)=BeforeHash,'Link navigation changed the source book');
  end;
  Writeln('PASS FB2 EPUB internal chapter links navigate by click preserve footnotes and dragging selection in single and double pages');
end;
