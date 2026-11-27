type
  TChapterPageSettingsProbe = class
    Layout: TReaderPageLayout;
    Chapters, Subchapters, EnlargeCover, Valid: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TChapterPageSettingsProbe.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
  begin
    var Dialog:=Screen.Forms[I];
    if (Dialog.Name<>'ReaderAppearanceDialog') or not Dialog.Visible then Continue;
    var LayoutBox:=Dialog.FindComponent('cbReaderPageLayout') as TComboBox;
    var ChapterBox:=Dialog.FindComponent('ReaderChapterNewPage') as TCheckBox;
    var SubchapterBox:=Dialog.FindComponent('ReaderSubchapterNewPage') as TCheckBox;
    var CoverBox:=Dialog.FindComponent('ReaderEnlargeOpeningCover') as TCheckBox;
    TTimer(Sender).Enabled:=False;
    if (LayoutBox=nil) or (ChapterBox=nil) or (SubchapterBox=nil) or (CoverBox=nil) then
    begin Dialog.ModalResult:=mrCancel; Exit; end;
    LayoutBox.ItemIndex:=Ord(rplSingle);
    LayoutBox.OnChange(LayoutBox);
    ChapterBox.Checked:=Chapters;
    SubchapterBox.Checked:=Subchapters;
    CoverBox.Checked:=EnlargeCover;
    LayoutBox.ItemIndex:=Ord(Layout);
    LayoutBox.OnChange(LayoutBox);
    Valid:=(ChapterBox.Enabled=(Layout<>rplContinuous)) and (SubchapterBox.Enabled=ChapterBox.Enabled)
      and (CoverBox.Enabled=ChapterBox.Enabled);
    Dialog.ModalResult:=mrOk;
    Exit;
  end;
end;

procedure AuditChapterPages;
const FileName='chapter-pagination.fb2';
  SettingsName='chapter-pagination.ini';
  CoverFile='opening-cover-size.fb2';
  CoverSettings='opening-cover-size.ini';
  CoverImage='iVBORw0KGgoAAAANSUhEUgAAABgAAAAkCAIAAAAcrW15AAAANUlEQVR4nO3QoQEAMAjEwKf77wwjpAKByA0Qkep0NryVSgz9cDbzEfMR8xHzEfMR8xG792gA7IsCRrhG5qUAAAAASUVORK5CYII=';
  Book='<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
    '<book-title>Chapter pages fixture</book-title></title-info></description><body>'+
    '<section><title><p>Chapter Alpha</p></title><p>Opening paragraph.</p>'+
      '<section><title><p>Subheading One</p></title><p>First subsection text.</p></section>'+
      '<section><title><p>Subheading Two</p></title><p>Second subsection text.</p></section>'+
    '</section><section><title><p>Chapter Beta</p></title><p>Last paragraph.</p></section></body></FictionBook>';
var Reader: TfrmBuiltinReader; Hash, OriginalText: string; PageStart, ChapterBeta, SubheadingOne: Integer;
  Deadline: UInt64; Package: TZipFile; RegularCover, LargeCover: TRect;
  procedure Add(const Name, Content: string);
  begin
    Package.Add(TEncoding.UTF8.GetBytes(Content),Name);
  end;
  procedure Apply(const Layout: TReaderPageLayout; Chapters, Subchapters: Boolean; EnlargeCover: Boolean = False);
  var Probe: TChapterPageSettingsProbe; Timer: TTimer;
  begin
    Probe:=TChapterPageSettingsProbe.Create; Timer:=TTimer.Create(nil);
    try
      Probe.Layout:=Layout; Probe.Chapters:=Chapters; Probe.Subchapters:=Subchapters; Probe.EnlargeCover:=EnlargeCover;
      Timer.Interval:=20; Timer.OnTimer:=Probe.Tick; Timer.Enabled:=True;
      (Reader.FindComponent('ReaderAppearance') as TButton).Click;
      Require(Probe.Valid,'The chapter options did not follow the reading mode');
    finally Timer.Free; Probe.Free; end;
    Reader.GoToPosition(0);
  end;
  function VisibleCover: TRect;
  var Bitmap: TBitmap; X,Y: Integer; PaintDeadline: UInt64;
  begin
    PaintDeadline:=GetTickCount64+2000;
    while (Reader.PageRasterSize<>Point(Reader.ReadingSurface.ClientWidth,Reader.ReadingSurface.ClientHeight)) and
      (GetTickCount64<PaintDeadline) do
    begin Application.ProcessMessages; Sleep(10); end;
    Require(Reader.PageRasterSize=Point(Reader.ReadingSurface.ClientWidth,Reader.ReadingSurface.ClientHeight),
      'The page was not redrawn after the navigation panel changed size');
    Bitmap:=TBitmap.Create;
    try
      Bitmap.SetSize(Reader.ReadingSurface.ClientWidth,Reader.ReadingSurface.ClientHeight);
      Reader.ReadingSurface.PaintTo(Bitmap.Canvas.Handle,0,0);
      Result:=Rect(Bitmap.Width,Bitmap.Height,0,0);
      Y:=0;
      while Y<Bitmap.Height do
      begin
        X:=0;
        while X<Bitmap.Width do
        begin
          if Bitmap.Canvas.Pixels[X,Y]=clFuchsia then
          begin
            Result.Left:=Min(Result.Left,X); Result.Top:=Min(Result.Top,Y);
            Result.Right:=Max(Result.Right,X+1); Result.Bottom:=Max(Result.Bottom,Y+1);
          end;
          Inc(X,3);
        end;
        Inc(Y,3);
      end;
      Require(not Result.IsEmpty,'The front cover is missing');
      Require((Abs(Result.Left+Result.Right-Bitmap.Width)<8) and
        (Abs(Result.Top+Result.Bottom-Bitmap.Height)<8),Format('The cover is not centered on its page: (%d,%d,%d,%d) vs %d x %d, text %s',
          [Result.Left,Result.Top,Result.Right,Result.Bottom,Bitmap.Width,Bitmap.Height,QuotedStr(Reader.PageText)]));
      Require(Abs(Result.Width*3-Result.Height*2)<20,'The cover aspect ratio changed');
    finally Bitmap.Free; end;
  end;
  procedure Contains(const Present, Absent: string);
  var Text: string;
  begin
    Text:=Reader.PageText;
    Require((Pos(Present,Text)>0) and ((Absent='') or (Pos(Absent,Text)=0)),
      'Unexpected page at '+IntToStr(Reader.TextPosition)+': '+Text);
  end;
begin
  TFile.WriteAllText(FileName,Book,TEncoding.UTF8); Hash:=THashSHA2.GetHashStringFromFile(FileName);
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.SetBounds(30,30,980,720); Reader.Show;
    Reader.OpenBook(FileName,'Chapter pages','chapter-pages',SettingsName,'');
    WaitReady(Reader); Reader.SetPageLayout(rplSingle);
    Reader.SetBounds(30,30,990,850);
    Reader.SetTypography('Arial',100,12);
    Reader.ChangeSize(-6);
    OriginalText:=Reader.BookText;
    SubheadingOne:=OriginalText.IndexOf('Subheading One'); ChapterBeta:=OriginalText.IndexOf('Chapter Beta');
    Require((SubheadingOne>0) and (ChapterBeta>SubheadingOne),'Fixture chapter positions are missing');
    Writeln('CHECK default flowing chapters');
    Contains('Chapter Beta','');

    Writeln('CHECK main chapters only');
    Apply(rplSingle,True,False);
    Contains('Subheading Two','Chapter Beta');
    Reader.NextPage; Contains('Chapter Beta','');
    Require(Reader.TextPosition=ChapterBeta,'A chapter must begin at the next page start');
    Reader.PreviousPage; Require(Reader.TextPosition=0,'Previous page must return to the chapter pair');

    Writeln('CHECK subchapters only');
    Apply(rplSingle,False,True);
    Contains('Chapter Alpha','Subheading One');
    Reader.NextPage; Contains('Subheading One','Subheading Two');
    Require(Reader.TextPosition=SubheadingOne,'A subchapter must begin at the next page start');
    Reader.NextPage; Contains('Chapter Beta','');

    Writeln('CHECK both and global pagination');
    Apply(rplSingle,True,True);
    Contains('Chapter Alpha','Subheading One');
    Reader.NextPage; Contains('Subheading One','Subheading Two');
    Reader.NextPage; Contains('Subheading Two','Chapter Beta');
    Reader.NextPage; Contains('Chapter Beta','');
    Reader.RequestGlobalPages; Deadline:=GetTickCount64+10000;
    while not Reader.GlobalPaginationReady and (GetTickCount64<Deadline) do
    begin Application.ProcessMessages; Sleep(10); end;
    Require(Reader.GlobalPaginationReady and (Reader.GlobalPageAt(ChapterBeta)=4),'Global pagination missed chapter boundaries');
    for var I:=0 to Reader.ChapterCount-1 do
      if Reader.ChapterTitle(I).Contains('Chapter Beta') then begin Reader.GoToChapter(I); Break; end;
    Contains('Chapter Beta','');
    PageStart:=Reader.TextPosition;
    Reader.PreviousPage; Contains('Subheading Two','Chapter Beta');
    Reader.NextPage; Require(Reader.TextPosition=PageStart,'Previous and next must share chapter boundaries');

    Apply(rplDouble,True,True);
    Require(Reader.VisiblePageCount=2,'The two-page layout was not active');
    Contains('Subheading One','Subheading Two');
    Reader.NextPage; Contains('Chapter Beta','');
    Apply(rplContinuous,True,True); Contains('Chapter Beta','');
    Apply(rplSingle,True,True); Contains('Chapter Alpha','Subheading One');
    Require(Reader.BookText=OriginalText,'Pagination must preserve the entire book text');
    Reader.Close;
  finally Reader.Free; end;

  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook(FileName,'Chapter pages restored','chapter-pages',SettingsName,'',nil,0);
    WaitReady(Reader); Contains('Chapter Alpha','Subheading One');
    Reader.NextPage; Contains('Subheading One','Subheading Two');
    Require(THashSHA2.GetHashStringFromFile(FileName)=Hash,'Pagination must leave the source file intact');
    Reader.Close;
  finally Reader.Free; end;

  Package:=TZipFile.Create;
  try
    Package.Open('chapter-pagination.epub',zmWrite);
    Add('META-INF/container.xml','<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>');
    Add('OPS/book.opf','<package><metadata><title>Ordered chapters</title></metadata><manifest>'+
      '<item id="main" href="main.xhtml"/><item id="nav" href="nav.xhtml" properties="nav"/>'+
      '</manifest><spine><itemref idref="main"/></spine></package>');
    Add('OPS/nav.xhtml','<html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>'+
      '<li><a href="main.xhtml#b">Chapter Beta</a></li>'+
      '<li><a href="main.xhtml#a">Chapter Alpha</a><ol><li><a href="main.xhtml#sub">Subheading One</a></li></ol></li>'+
      '<li><a href="main.xhtml#b">Last chapter again</a></li></ol></nav></body></html>');
    Add('OPS/main.xhtml','<html><body><h1 id="a">Chapter Alpha</h1><p>Opening paragraph.</p>'+
      '<h2 id="sub">Subheading One</h2><p>Subsection text.</p>'+
      '<h1 id="b">Chapter Beta</h1><p>Last paragraph.</p></body></html>');
  finally Package.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('chapter-pagination.epub','EPUB chapter pages','chapter-pages-epub',SettingsName,'',nil,0);
    WaitReady(Reader); Contains('Chapter Alpha','Subheading One');
    Reader.NextPage; Contains('Subheading One','Chapter Beta');
    Reader.NextPage; Contains('Chapter Beta','');
    PageStart:=Reader.TextPosition;
    Reader.NextPage; Require(Reader.TextPosition=PageStart,'A repeated EPUB target must not add a page');
    Reader.Close;
  finally Reader.Free; end;

  TFile.WriteAllText('chapter-pagination.txt','Text only.'+#13#10#13#10+'Second paragraph.',TEncoding.UTF8);
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('chapter-pagination.txt','Plain text','chapter-pages-text',SettingsName,'',nil,0);
    WaitReady(Reader); Contains('Second paragraph.','');
    Require(Reader.ChapterCount=0,'Chapter page breaks must not invent chapters for plain text');
    Reader.Close;
  finally Reader.Free; end;

  TFile.WriteAllText(CoverFile,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '+
    'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Cover size</book-title>'+
    '<coverpage><image l:href="#cover"/></coverpage></title-info></description>'+
    '<body><section><p>Text starts on the next page.</p></section></body>'+
    '<binary id="cover" content-type="image/png">'+CoverImage+'</binary></FictionBook>',TEncoding.UTF8);
  Hash:=THashSHA2.GetHashStringFromFile(CoverFile);
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook(CoverFile,'Cover size','cover-pagination',CoverSettings,'',nil,0);
    WaitReady(Reader); Reader.SetPageLayout(rplSingle); Reader.SetPageAppearance(rpaFlat);
    RegularCover:=VisibleCover;
    Require(not ContainsText(Reader.PageText,'Text starts'),'The cover shares its page with book text');
    Apply(rplSingle,False,False,True);
    LargeCover:=VisibleCover;
    Require((LargeCover.Width>RegularCover.Width*3) and (LargeCover.Height>RegularCover.Height*3),
      'The requested large cover did not expand');
    Reader.NextPage; Contains('Text starts on the next page','');
    Reader.PreviousPage; Require(VisibleCover=LargeCover,'Returning to the cover changed its size');
    Reader.Close;
  finally Reader.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook(CoverFile,'Cover size restored','cover-pagination',CoverSettings,'',nil,0);
    WaitReady(Reader); Reader.SetPageLayout(rplSingle); Reader.SetPageAppearance(rpaFlat);
    Require(VisibleCover.Width>RegularCover.Width*3,'The large cover setting was not saved');
    Require(THashSHA2.GetHashStringFromFile(CoverFile)=Hash,'Reader cover preferences changed the source file');
    Reader.Close;
  finally Reader.Free; end;
  Package:=TZipFile.Create;
  try
    Package.Open('opening-cover-size.epub',zmWrite);
    Add('META-INF/container.xml','<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>');
    Add('book.opf','<package><manifest><item id="open" href="open.xhtml"/>'+
      '<item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>'+
      '</manifest><spine><itemref idref="open"/></spine></package>');
    Package.Add(TNetEncoding.Base64.DecodeStringToBytes(CoverImage),'cover.png');
    Add('open.xhtml','<html><body><div><img src="cover.png"/></div>'+
      '<h1>Opening chapter</h1><p>Text starts on the next page.</p></body></html>');
  finally Package.Free; end;
  Hash:=THashSHA2.GetHashStringFromFile('opening-cover-size.epub');
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show;
    Reader.OpenBook('opening-cover-size.epub','EPUB cover','cover-epub','cover-epub.ini','',nil,0);
    WaitReady(Reader); Reader.SetPageLayout(rplSingle); Reader.SetPageAppearance(rpaFlat);
    RegularCover:=VisibleCover;
    Require(not ContainsText(Reader.PageText,'Opening chapter'),'EPUB text started on the cover page');
    Apply(rplSingle,True,True,True);
    LargeCover:=VisibleCover;
    Require((LargeCover.Width>RegularCover.Width*3) and (LargeCover.Height>RegularCover.Height*3),
      'The requested large EPUB cover did not expand');
    Reader.NextPage; Contains('Text starts on the next page','');
    Reader.PreviousPage; Require(VisibleCover=LargeCover,'Returning to the EPUB cover changed its size');
    Require(THashSHA2.GetHashStringFromFile('opening-cover-size.epub')=Hash,'The reader changed the source EPUB');
    Reader.Close;
  finally Reader.Free; end;
  Writeln('PASS normal and expanded EPUB covers are centered with chapter breaks enabled');
  Writeln('PASS independently configurable chapter and subchapter page breaks, spread, scroll, page index and profile');
  Writeln('PASS normal and expanded covers are centered, retain their aspect ratio and occupy a separate page');
end;
