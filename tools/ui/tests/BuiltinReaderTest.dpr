program BuiltinReaderTest;
{$APPTYPE CONSOLE}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}

uses NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  System.Diagnostics, System.Character, System.Math, System.StrUtils, System.Hash, System.IniFiles, System.SyncObjs, System.Zip, System.Generics.Collections, Winapi.Windows, Winapi.Messages, Winapi.ActiveX, Winapi.RichEdit,
  Vcl.ExtCtrls, Vcl.Menus, Vcl.ComCtrls, Vcl.Clipbrd, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.Graphics, System.Types, unit_ReaderDocument, unit_ReaderPDF, unit_ReaderCSS, unit_ReaderAnnotations, frm_BuiltinReader,
  unit_ReaderFonts, unit_ReaderFontDownloads, unit_ReaderFormats, unit_ReaderRaster, unit_ReaderDOC, unit_ReaderPageSelection, unit_ReaderRichEdit, unit_ReaderOffice, unit_Globals, unit_ReaderCache, unit_BookCache, dm_user, unit_MHLTheme;

procedure Require(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;

function ReadClipboardText: string;
var Attempt: Integer;
begin
  for Attempt:=0 to 49 do
    try Result:=Clipboard.AsText; Exit;
    except on E: EClipboardException do
      if Attempt<49 then Sleep(20) else raise;
    end;
end;

procedure AuditReaderColorBox;
const Values: array[0..5] of TColor = (clDefault,clBlack,clRed,clGreen,clBlue,$123456);
var Dialog: TForm; Box: TColorBox; Value: TColor; I, DefaultIndex: Integer;
begin
  Dialog:=TForm.Create(nil);
  try
    Box:=TColorBox.Create(Dialog); Box.Parent:=Dialog;
    Dialog.Show; Application.ProcessMessages;
    for Value in Values do
    begin
      ConfigureReaderColorBox(Box,Value);
      Require(Box.Items.Count=18,'Reader palette contains unrelated system colors');
      Require(Box.Selected=Value,'Localized reader color selector changed its value');
      DefaultIndex:=-1;
      for I:=1 to Box.Items.Count-1 do if Box.Colors[I]=clDefault then DefaultIndex:=I;
      Require(DefaultIndex>0,'Reader colors have no automatic choice');
      Require(Box.Items[DefaultIndex]='Автоматически (по теме)','Automatic color caption is missing');
      if Value=clDefault then Require(Box.ItemIndex=DefaultIndex,'Default color displays custom item');
      if Value=TColor($123456) then Require(Box.ItemIndex=0,'Custom color is not preserved');
    end;
    Dialog.Close;
  finally Dialog.Free; end;
  Writeln('PASS localized reader color selector retains default, standard and custom values');
end;

procedure WaitReady(Form: TfrmBuiltinReader);
var Watch: TStopwatch;
begin
  Watch:=TStopwatch.StartNew;
  while not Form.LoadFinished and (Watch.ElapsedMilliseconds<15000) do
  begin Application.ProcessMessages; CheckSynchronize(5); end;
  Require(Form.Ready,'Reader not ready: '+Form.ReaderStatus.Caption);
end;

procedure WaitPage(Form: TfrmBuiltinReader);
var Watch: TStopwatch;
begin
  Watch:=TStopwatch.StartNew;
  while Form.PageLoading and (Watch.ElapsedMilliseconds<35000) do
  begin Application.ProcessMessages; CheckSynchronize(5); end;
  Require(not Form.PageLoading,'Page decoder did not finish');
  Require(Pos('Не удалось',Form.ReaderStatus.Caption)=0,'Page decoder failed: '+Form.ReaderStatus.Caption);
end;

procedure DrainReaderCleanup;
var Before: Cardinal;
begin
  Before:=GetGuiResources(GetCurrentProcess,GR_USEROBJECTS);
  // Destroyed controls and text services can post deferred cleanup. Observe
  // idle resources after processing those messages; keep the same +2 budget.
  for var I:=1 to 50 do begin Sleep(10); Application.ProcessMessages; end;
  GdiFlush;
  Writeln('PROFILE idle cleanup USER before=',Before,' after=',GetGuiResources(GetCurrentProcess,GR_USEROBJECTS));
end;

procedure AuditRasterReader;
var Reader: TfrmBuiltinReader; Name: string; Size,Pan: TPoint; Key: Word; Progress: Integer; Watch: TStopwatch;
  procedure Inspect;
  begin
    Size:=Reader.PageRasterSize; Pan:=Reader.PDFPan;
    Reader.ToggleInspection(Pan.X+Size.X div 2,Pan.Y+Size.Y div 2);
    Require(Reader.Inspecting and (Reader.PDFZoom>=150),'Click did not enter inspection');
    Reader.MoveInspection(20,20); Require(Reader.PDFPan<>Pan,'Inspection did not follow mouse');
    Key:=VK_ESCAPE; Reader.OnKeyDown(Reader,Key,[]);
    Require((Key=0) and not Reader.Inspecting,'Esc did not leave inspection');
    Require((Reader.PDFZoom=100) and (Reader.PageRasterSize=Size) and (Reader.PDFPan=Pan),'Inspection did not restore exact view');
  end;
begin
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  for Name in ['sample.pdf','pages.cbz','pages.cb7','pages.tiff','page.png','large-page.tiff'] do
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook(Name,Name,Name,'raster-test.ini','pdfium.dll'); WaitReady(Reader); WaitPage(Reader);
      Require((Reader.PageRasterSize.X>0) and (Reader.PageRasterSize.Y>0),'Visual file has no page');
      Inspect;
      if Name<>'sample.pdf' then
      begin Reader.FindText('anything'); Require(not Reader.SearchRunning,'Image-only document started text scan'); end;
      if (Name='pages.cbz') or (Name='pages.cb7') or (Name='pages.tiff') then
      begin
        Require(Reader.TextLength=3,'Page count incorrect');
        Require(ColorToRGB(Reader.PageBackground)=ColorToRGB(clRed),'First page order or colour incorrect');
        Reader.NextPage; WaitPage(Reader);
        Require((Reader.TextPosition=1) and (ColorToRGB(Reader.PageBackground)=ColorToRGB(clLime)),
          Format('Second page order or colour incorrect: page=%d colour=%x status=%s',[Reader.TextPosition,ColorToRGB(Reader.PageBackground),Reader.ReaderStatus.Caption]));
        Reader.SetTheme(5); Require(ColorToRGB(Reader.PageBackground)=ColorToRGB(clLime),'Dark theme inverted comic colours');
        Reader.NextPage; Reader.PreviousPage; Reader.NextPage; WaitPage(Reader);
        Require((Reader.TextPosition=2) and (ColorToRGB(Reader.PageBackground)=ColorToRGB(clBlue)),
          Format('Fast page requests lost latest target: page=%d colour=%x status=%s',[Reader.TextPosition,ColorToRGB(Reader.PageBackground),Reader.ReaderStatus.Caption]));
        Reader.AddBookmark; Reader.PreviousPage; WaitPage(Reader); Reader.GoToBookmark(0); WaitPage(Reader);
        Require(Reader.TextPosition=2,'Raster bookmark did not restore page');
        Reader.SetTheme(0);
      end;
      Reader.Close;
    finally Reader.Free; end;
    Writeln('PASS raster view, click inspection and page navigation: ',Name);
  end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('broken-page.cbz','Damaged comic page','broken-page.cbz','raster-test.ini','pdfium.dll'); WaitReady(Reader);
    Reader.NextPage; Reader.PreviousPage;
    Require(Pos('Открытие страницы',Reader.ReaderStatus.Caption)=0,'Returning to visible page leaves a stale opening status');
    WaitPage(Reader);
    Require(Reader.TextPosition=0,'Cancelled page decode replaced the visible page');
    Reader.NextPage; Reader.PreviousPage; WaitPage(Reader);
    Require(Pos('Не удалось',Reader.ReaderStatus.Caption)=0,'Cancelled foreground decode replaces good-page status with an error');
    Reader.NextPage; Watch:=TStopwatch.StartNew;
    while Reader.PageLoading and (Watch.ElapsedMilliseconds<35000) do
    begin Application.ProcessMessages; CheckSynchronize(5); end;
    Require(not Reader.PageLoading and (Pos('Не удалось',Reader.ReaderStatus.Caption)>0),'Damaged comic page has no clear error');
    Require(Reader.TextPosition=0,'Damaged comic page replaced the last valid page');
    Reader.NextPage; WaitPage(Reader);
    Require((Reader.TextPosition=2) and (ColorToRGB(Reader.PageBackground)=ColorToRGB(clBlue)),'Cannot navigate past a damaged page');
    Reader.PreviousPage; Reader.PreviousPage; WaitPage(Reader);
    Require(Reader.TextPosition=0,'Cannot return past a damaged page');
    Reader.NextPage; Reader.Close;
  finally Reader.Free; end;
  Writeln('PASS damaged comic page reports failure, permits navigation and closes during decode');
  Progress:=-1; Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('pages.cbz','Saved comic page','pages.cbz','raster-test.ini','pdfium.dll',
      procedure(Value: Integer) begin Progress:=Value; end);
    WaitReady(Reader); WaitPage(Reader);
    Require(Reader.TextPosition=2,'Reopening comic lost saved page'); Reader.Close;
    Require(Progress=-1,'Restoring comic page changed catalog progress');
  finally Reader.Free; end;
  for Name in TDirectory.GetFiles('raster-real','*',TSearchOption.soTopDirectoryOnly) do
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook(Name,Name,Name,'raster-real.ini','pdfium.dll'); WaitReady(Reader); WaitPage(Reader);
      Require(Reader.TextLength>0,'Real visual book has no pages'); Inspect;
      if Reader.TextLength>1 then begin Reader.NextPage; WaitPage(Reader); Require(Reader.TextPosition=1,'Real book did not turn page'); end;
      Reader.Close;
    finally Reader.Free; end;
    Writeln('PASS real archive visual book: ',Name);
  end;
end;

procedure AuditDjvuQuality;
var Pages: TReaderRaster; Name, Hash: string; Small, Large: TPoint;
  Bitmap: TBitmap; Reader: TfrmBuiltinReader; Watch: TStopwatch;
begin
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  for Name in TDirectory.GetFiles('raster-real','*.djvu') do
  begin
    Hash:=THashSHA2.GetHashStringFromFile(Name);
    Pages:=TReaderRaster.Create(Name,1200);
    try
      Small:=Pages.PageSize(0);
      Require((Small.X<=1200) and (Small.Y<=1200),'Initial DjVu resolution ignores requested limit');
      Require(not Pages.IsPageCached(0,4000),'Low-resolution cache claims full detail');
      Bitmap:=Pages.Render(0,600,600);
      try
        Pages.PreparePage(0,True,4000); Large:=Pages.PageSize(0);
        Require(Pages.IsPageCached(0,4000),'Quality upgrade did not replace cached page');
        Require((Large.X>=Small.X) and (Large.Y>=Small.Y),'Quality upgrade reduced detail');
        Require(Abs(Double(Small.X)/Small.Y-Double(Large.X)/Large.Y)<0.003,
          'Quality upgrade crops or changes page aspect ratio');
        Require((Bitmap.Width=600) and (Bitmap.Height=600),'Quality upgrade invalidates displayed bitmap');
        if Pages.PageCount>1 then
        begin
          Pages.PreparePage(1,True,1200);
          Pages.PreparePage(0,True,4000);
          Require(Pages.IsPageCached(0,4000) and Pages.IsPageCached(1,1200),'Neighbour prefetch evicts current page');
        end;
      finally Bitmap.Free; end;
    finally Pages.Free; end;
    Require(Hash=THashSHA2.GetHashStringFromFile(Name),'DjVu quality changes source file');
    Writeln('PASS DjVu adaptive resolution, cache replacement, aspect ratio and retained visible page: ',Name);
  end;
  if FileExists('invalid-djvu-real.djvu') then
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook('invalid-djvu-real.djvu','Invalid DjVu','invalid-djvu-real','invalid-djvu.ini','pdfium.dll');
      Watch:=TStopwatch.StartNew;
      while not Reader.LoadFinished and (Watch.ElapsedMilliseconds<35000) do
      begin Application.ProcessMessages; CheckSynchronize(5); end;
      Require(Reader.LoadFinished and not Reader.Ready and (Pos('DjVu',Reader.ReaderStatus.Caption)>0),
        'Invalid real DjVu leaves reader hanging or loses error');
      Reader.Close;
    finally Reader.Free; end;
    Writeln('PASS invalid real DjVu reports decoder error and closes cleanly');
  end;
  DMUser.Free; DMUser:=nil;
end;

procedure AuditReleasePagination;
var Reader: TfrmBuiltinReader; Files: TStringList; Name, Hash: string;
  Watch: TStopwatch; LoadMS, MaxMS, TotalMS, Count, I, Position: Int64;
  procedure Add(const FileName: string);
  begin if FileExists(FileName) then Files.Add(FileName); end;
begin
  Application.CreateForm(TDMUser,DMUser); DMUser.Init; Files:=TStringList.Create;
  try
    for Name in ['sample.fb2','sample-webp.fb2','sample.epub','sample.txt','sample.rtf','sample.docx',
      'sample.odt','sample.fb3','mime.mht','mime-qp.mhtml','write.wri','legacy.html','sample.pdf',
      'pages.cbz','pages.cb7','pages.tiff','page.png','large-page.tiff'] do Add(Name);
    for Name in TDirectory.GetFiles('raster-real','*') do Add(Name);
    for Name in Files do
    begin
      Hash:=THashSHA2.GetHashStringFromFile(Name); Reader:=TfrmBuiltinReader.Create(nil);
      try
        Watch:=TStopwatch.StartNew; Reader.Show;
        Reader.OpenBook(Name,Name,'pagination-'+Name,'pagination.ini','pdfium.dll'); WaitReady(Reader); WaitPage(Reader);
        LoadMS:=Watch.ElapsedMilliseconds; MaxMS:=0; TotalMS:=0; Count:=0;
        for I:=1 to 20 do
        begin
          Position:=Reader.TextPosition; Watch:=TStopwatch.StartNew;
          Reader.NextPage; WaitPage(Reader);
          if Reader.TextPosition=Position then Break;
          Inc(Count); Inc(TotalMS,Watch.ElapsedMilliseconds);
          if Watch.ElapsedMilliseconds>MaxMS then MaxMS:=Watch.ElapsedMilliseconds;
        end;
        for I:=1 to Count do
        begin
          Watch:=TStopwatch.StartNew; Reader.PreviousPage; WaitPage(Reader);
          Inc(TotalMS,Watch.ElapsedMilliseconds);
          if Watch.ElapsedMilliseconds>MaxMS then MaxMS:=Watch.ElapsedMilliseconds;
        end;
        if Count>0 then Require(Reader.TextPosition=0,'Page backwards did not restore start: '+Name);
        Reader.Close;
        Writeln('PROFILE pagination file=',Name,' load_ms=',LoadMS,' moves=',Count*2,
          ' total_ms=',TotalMS,' max_ms=',MaxMS);
      finally Reader.Free; end;
      Require(THashSHA2.GetHashStringFromFile(Name)=Hash,'Page viewing changed source: '+Name); Flush(Output);
    end;
    Writeln('PASS release pagination across text, PDF, comic, TIFF, image and actual archive DjVu/CBR/CBZ files');
  finally Files.Free; DMUser.Free; DMUser:=nil; end;
end;

procedure AuditLoadingPreferences;
var Reader: TfrmBuiltinReader; Ini: TMemIniFile; Section: string;
begin
  Section:='Book.'+Copy(THashSHA2.GetHashString('loading-preferences'),1,40);
  Ini:=TMemIniFile.Create('loading-preferences.ini',TEncoding.UTF8);
  try
    Ini.WriteInteger('Reader','FontSize',14); Ini.WriteInteger('Reader','Theme',0);
    Ini.WriteString('Reader','FontName','Georgia'); Ini.WriteInteger('Reader','LinePercent',110);
    Ini.WriteInteger('Reader','Margin',32); Ini.WriteInteger(Section,'Position',123); Ini.UpdateFile;
  finally Ini.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('sample.fb2','Loading preferences','loading-preferences','loading-preferences.ini','pdfium.dll');
    Require(not Reader.Ready,'Preference fixture already loaded');
    Reader.SetTheme(4); Reader.ChangeSize(2); Reader.SetTypography('Arial',140,48);
    Reader.SetHighlightColor(clLime); Reader.SetSearchOptions(True,True,True);
    WaitReady(Reader);
    Require((Reader.ThemeIndex=4) and (Reader.ReaderFontSize=16),'Background load reset chosen theme or font size');
    Require((Reader.ReaderFontName='Arial') and (Reader.ReaderLinePercent=140) and (Reader.ReaderMargin=48),'Background load reset text preferences');
    Require(Reader.HighlightColor=clLime,'Background load reset highlight color');
    Require(Reader.TextPosition=123,'Preserving preferences lost saved book position');
    Reader.Close;
  finally Reader.Free; end;
  Ini:=TMemIniFile.Create('loading-preferences.ini',TEncoding.UTF8);
  try
    Require(Ini.ReadBool('Reader','SearchCase',False) and Ini.ReadBool('Reader','SearchWord',False) and
      Ini.ReadBool('Reader','SearchAll',False),'Background load reset search preferences');
    Require(Ini.ReadInteger(Section,'Position',-1)=123,'Closing reader lost restored position');
  finally Ini.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('sample.fb2','Preferences restored','loading-preferences','loading-preferences.ini','pdfium.dll'); WaitReady(Reader);
    Require((Reader.ThemeIndex=4) and (Reader.ReaderFontSize=16) and (Reader.TextPosition=123),'Preferences did not survive reopening');
    Reader.Close;
  finally Reader.Free; end;
  Writeln('PASS preferences changed during background load persist with saved book position');
end;

function ChapterSelector(Control: TWinControl): TComboBox;
var I: Integer;
begin
  Result:=nil;
  for I:=0 to Control.ControlCount-1 do
  begin
    if (Control.Controls[I] is TComboBox) and (Control.Controls[I].Name='ReaderChapterSelector') then Exit(TComboBox(Control.Controls[I]));
    if Control.Controls[I] is TWinControl then
    begin
      Result:=ChapterSelector(TWinControl(Control.Controls[I]));
      if Assigned(Result) then Exit;
    end;
  end;
end;

function LogReaderWindow(Window: HWND; Param: LPARAM): BOOL; stdcall;
var ProcessID: DWORD; ClassName: array[0..255] of Char;
begin
  Result:=True;
  GetWindowThreadProcessId(Window,@ProcessID);
  if ProcessID<>GetCurrentProcessId then Exit;
  GetClassName(Window,ClassName,Length(ClassName));
  Writeln('WINDOW ',IntToHex(NativeUInt(Window)), ' ',string(ClassName));
end;

procedure LogReaderWindows;
begin
  EnumWindows(@LogReaderWindow,0);
end;

procedure AuditNavigation(const TestCase: string);
var Reader: TfrmBuiltinReader; Progress: Integer; Key: Word; InitialSize: Integer;
  procedure Wheel(Delta: Integer; Control: Boolean);
  var Flags: Cardinal;
  begin
    Flags:=0; if Control then Flags:=MK_CONTROL;
    Reader.ReadingSurface.Perform(WM_MOUSEWHEEL,
      WPARAM((Cardinal(Word(Delta)) shl 16) or Flags),0);
  end;
begin
  Progress:=-1; Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show;
    Reader.OpenBook('sample.fb2',TestCase,TestCase,'reader-navigation.ini','pdfium.dll',
      procedure(Value: Integer) begin Progress:=Value; end);
    if TestCase='loading-navigation' then
    begin
      Require(not Reader.Ready,'Loading-key fixture already ready');
      Key:=VK_END; Reader.OnKeyDown(Reader,Key,[]);
      Key:=VK_HOME; Reader.OnKeyDown(Reader,Key,[]);
    end;
    WaitReady(Reader);
    if TestCase='same-position-navigation' then
    begin
      Key:=VK_HOME; Reader.OnKeyDown(Reader,Key,[]);
      Key:=VK_HOME; Reader.OnKeyDown(Reader,Key,[]);
    end;
    if TestCase='precision-wheel' then
    begin
      InitialSize:=Reader.ReaderFontSize;
      Wheel(0,True); Require(Reader.ReaderFontSize=InitialSize,'Zero wheel changed text size');
      Wheel(30,True); Wheel(30,True); Wheel(30,True);
      Require(Reader.ReaderFontSize=InitialSize,'Partial Ctrl wheel changed text size early');
      Wheel(30,True); Require(Reader.ReaderFontSize=InitialSize+1,'Precision Ctrl wheel did not accumulate one step');
      Wheel(60,False); Wheel(60,True);
      Require(Reader.ReaderFontSize=InitialSize+1,'Page-wheel remainder leaked into text zoom');
      Wheel(60,True); Require(Reader.ReaderFontSize=InitialSize+2,'Second precision Ctrl wheel step lost');
      Wheel(-120,True); Require(Reader.ReaderFontSize=InitialSize+1,'Reverse Ctrl wheel did not reduce size');
    end;
    Reader.Close;
    Require(Progress=-1,'Navigation without a page move changed catalog reading progress: '+TestCase);
  finally Reader.Free; end;
  Writeln('PASS ',TestCase);
end;

procedure AuditDocumentSpacing;
var Document: TReaderDocument;
begin
  Document:=TReaderDocument.Create;
  try
    Document.Load('spacing.odt');
    Require(Pos('A   B'+#9+'C',Document.PlainText)>0,'ODT explicit spaces or tab lost');
    Require(Pos('D E',Document.PlainText)>0,'Default ODT space lost');
    Document.Load('spacing.docx');
    Require(Pos('A  B'+#9+'C',Document.PlainText)>0,'DOCX preserved spaces or tab lost');
  finally Document.Free; end;
  Writeln('PASS document-spacing');
end;

procedure AuditPDFSearch;
var Reader: TfrmBuiltinReader; Ini: TMemIniFile; Before, After: TBitmap;
  Progress: Integer; Watch: TStopwatch;
begin
  Ini:=TMemIniFile.Create('reader-pdf-search.ini',TEncoding.UTF8);
  try
    Ini.WriteInteger('Book.'+Copy(THashSHA2.GetHashString('pdf-search-current'),1,40),'Position',1);
    Ini.UpdateFile;
  finally Ini.Free; end;
  Progress:=-1; Reader:=TfrmBuiltinReader.Create(nil); Before:=TBitmap.Create; After:=TBitmap.Create;
  try
    Reader.Show;
    Reader.OpenBook('sample.pdf','Current-page PDF search','pdf-search-current','reader-pdf-search.ini','pdfium.dll',
      procedure(Value: Integer) begin Progress:=Value; end);
    WaitReady(Reader); Require(Reader.TextPosition=1,'PDF search fixture did not restore page');
    Before.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
    Reader.ReadingSurface.PaintTo(Before.Canvas.Handle,0,0); Before.SaveToFile('pdf-search-before.bmp');
    Reader.FindText('Needle'); Watch:=TStopwatch.StartNew;
    while Reader.SearchRunning and (Watch.ElapsedMilliseconds<5000) do
    begin Application.ProcessMessages; CheckSynchronize(5); end;
    Require(not Reader.SearchRunning,'PDF current-page search timed out');
    Require(Pos('Найдено',Reader.ReaderStatus.Caption)>0,'PDF current-page match not found');
    After.SetSize(Before.Width,Before.Height);
    Reader.ReadingSurface.PaintTo(After.Canvas.Handle,0,0); After.SaveToFile('pdf-search-after.bmp');
    Require(THashSHA2.GetHashStringFromFile('pdf-search-before.bmp')<>
      THashSHA2.GetHashStringFromFile('pdf-search-after.bmp'),'PDF current-page search did not redraw its highlight');
    Reader.Close; Require(Progress=-1,'PDF current-page search changed progress without page movement');
  finally After.Free; Before.Free; Reader.Free; end;
  Writeln('PASS pdf-current-page-search');
end;

procedure AuditOctoberReader;
var Doc: TReaderDocument; Reader: TfrmBuiltinReader; PDF: TReaderPDF;
  Match, Previous: TPDFMatch; Matches: TArray<TPDFMatch>; I, P: Integer;
  Size, Pan: TPoint; Book: TBookRecord; Name, Hash: string; A, B: TBitmap;
  Key: Word; Watch: TStopwatch;
begin
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    Book:=Default(TBookRecord);
    for Name in ['.mht','.rgo','.ppt','.wri','.cab','.mp3'] do
    begin Book.FileExt:=Name; Require(Book.GetFileType=Copy(Name,2,MaxInt),'Legitimate extension hidden: '+Name); end;
    Book.FileName:='test'; Book.FileExt:='.325949';
    Require(Book.GetFileType='Некорректный тип','Numeric type leaked into types');
    Book.FileExt:='.Long_invalid_book_name_2011';
    Require(Book.GetFileType='Некорректный тип','Malformed title leaked into types');
    for Name in ['numeric.325949','alias.epup','alias.fb','mime.mht','write.wri','sample.fb3'] do
      Require(DetectReaderExtension(Name)<>'','Signature missing: '+Name);
    Require(DetectReaderExtension('numeric.325949')='.pdf','Numeric PDF not recognized');
    Require(DetectReaderExtension('alias.epup')='.epub','EPUB typo not recognized');
    Require(DetectReaderExtension('alias.fb')='.fb2','FB alias not recognized');
    Require(DetectReaderExtension('fake.pdf')='','Fake PDF trusted by extension');
    Hash:=THashSHA2.GetHashStringFromFile('numeric.325949');
    Name:=PrepareDetectedReaderFile('numeric.325949','test-source');
    Require((ExtractFileExt(Name)='.pdf') and FileExists(Name),'Detected readable copy absent');
    Require(THashSHA2.GetHashStringFromFile(Name)=Hash,'Detected copy changed contents');
    Require(THashSHA2.GetHashStringFromFile('numeric.325949')=Hash,'Source altered by detection');
    Require(PrepareDetectedReaderFile('numeric.325949','test-source')=Name,'Detected copy not reused');
    Require(IsReaderArchive('comic.cbz') and IsReaderArchive('comic.cbr') and
      not IsReaderArchive('book.fb2'),'Archive command capability wrong');
    Writeln('PASS extension visibility, signature detection, unchanged originals, cache reuse');
    Doc:=TReaderDocument.Create;
    try
      for Name in ['mime.mht','mime-qp.mhtml'] do
      begin
        Doc.Load(Name); Require(Pos('Русский текст',Doc.PlainText)>0,'MHTML encoding lost: '+Name);
        Require(Doc.ImageCount=1,'MHTML CID image missing: '+Name);
        Require(Pos('script-secret',Doc.PlainText)=0,'MHTML script entered text');
      end;
      Doc.Load('write.wri'); Require(Pos('Текст Windows Write',Doc.PlainText)>0,'Write decoding lost text');
      Require(Doc.Warnings.Count>0,'Write limitations hidden');
      Doc.Load('sample.fb3'); Require(Pos('Текст FB3',Doc.PlainText)>0,'FB3 body missing');
      Doc.Load('legacy.html'); Require(Pos('Русский HTML',Doc.PlainText)>0,'HTML charset ignored');
      Require(Pos('script-secret',Doc.PlainText)=0,'HTML script entered text');
    finally Doc.Free; end;
    Writeln('PASS MHTML base64/quoted printable, embedded images, WRI, FB3, HTML charset');
    Reader:=TfrmBuiltinReader.Create(nil); A:=TBitmap.Create; B:=TBitmap.Create;
    try
      Reader.Show; Reader.OpenBook('search.txt','Search','oct10-text','oct10-reader.ini','pdfium.dll'); WaitReady(Reader);
      Reader.SetSearchOptions(False,True,True); Reader.FindText('needle');
      Require(Reader.MatchPosition=0,'Case-insensitive whole word first match wrong');
      Require(Reader.HighlightCount=3,'All whole word text matches not highlighted');
      P:=Reader.MatchPosition; Reader.FindText('needle'); Require(Reader.MatchPosition>P,'Find next stayed at first match');
      Reader.FindText('needle',True); Require(Reader.MatchPosition=P,'Find previous did not return to first');
      Reader.SetSearchOptions(True,True,False); Reader.FindText('needle');
      Require((Reader.MatchPosition>0) and (Reader.HighlightCount=1),'Case sensitive search incorrect');
      Reader.SetSearchOptions(False,True,False); Reader.FindText('need');
      Require(Reader.MatchPosition=-1,'Whole word matched a prefix');
      Reader.SetSearchOptions(False,False,True); Reader.FindText('needle');
      Require(Reader.HighlightCount=4,'Substring all matching missed needled');
      Reader.SetHighlightColor(clLime); Require(Reader.HighlightColor=clLime,'Custom highlight color rejected');
      for I:=0 to 5 do begin Reader.SetTheme(I); Require(Reader.ThemeIndex=I,'Theme index rejected'); end;
      Require(Reader.HighlightCount>0,'Theme switch erased highlights');
      A.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
      Reader.ReadingSurface.PaintTo(A.Canvas.Handle,0,0); A.SaveToFile('oct10-night.bmp');
      Reader.Close;
    finally B.Free; A.Free; Reader.Free; end;
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook('search.txt','Search restored','oct10-text','oct10-reader.ini','pdfium.dll'); WaitReady(Reader);
      Require((Reader.ThemeIndex=5) and (Reader.HighlightColor=clLime),'Theme/highlight preference not persisted'); Reader.Close;
    finally Reader.Free; end;
    Writeln('PASS text search next/previous, word/case/all, six themes, color/settings persistence');
    PDF:=TReaderPDF.Create('pdfium.dll','search.pdf');
    try
      Require(PDF.FindOnPage(0,'needle',0,Match,False,True),'PDF case-insensitive search missing');
      Require(PDF.FindOnPage(0,'needle',Match.Index+Match.Count,Previous,False,True),'PDF next match absent');
      Require(PDF.FindOnPage(0,'needle',Previous.Index-1,Previous,False,True,True) and (Previous.Index=Match.Index),'PDF reverse did not return to first');
      Matches:=PDF.FindAllOnPage(0,'needle',False,True); Require(Length(Matches)=3,'PDF all whole-word matches wrong');
      Require(Length(PDF.FindAllOnPage(0,'needle',True,True))=1,'PDF case-sensitive matches wrong');
      Require(Length(PDF.FindAllOnPage(0,'need',False,True))=0,'PDF word matched prefix');
    finally PDF.Free; end;
    Reader:=TfrmBuiltinReader.Create(nil); A:=TBitmap.Create; B:=TBitmap.Create;
    try
      Reader.Show; Reader.OpenBook('search.pdf','PDF fit','oct10-pdf','oct10-pdf.ini','pdfium.dll'); WaitReady(Reader);
      Size:=Reader.PageRasterSize; Pan:=Reader.PDFPan;
      Require(Pan.X=(Reader.ReadingSurface.ClientWidth-Size.X) div 2,'Fit PDF not centered');
      Reader.ReadingSurface.Perform(WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(120,120));
      Reader.ReadingSurface.Perform(WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(40,40));
      Reader.ReadingSurface.Perform(WM_LBUTTONUP,0,MAKELPARAM(40,40));
      Require(Reader.PDFPan=Pan,'Fit PDF jumped while dragging');
      A.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
      Reader.ReadingSurface.PaintTo(A.Canvas.Handle,0,0); A.SaveToFile('oct10-pdf-before.bmp');
      Reader.SetSearchOptions(False,True,True); Reader.FindText('needle');
      while Reader.SearchRunning do begin Application.ProcessMessages; CheckSynchronize(5); end;
      Require(Pos('Найдено',Reader.ReaderStatus.Caption)>0,'PDF UI search missing: '+Reader.ReaderStatus.Caption);
      B.SetSize(A.Width,A.Height); Reader.ReadingSurface.PaintTo(B.Canvas.Handle,0,0); B.SaveToFile('oct10-pdf-highlight.bmp');
      Require(THashSHA2.GetHashStringFromFile('oct10-pdf-before.bmp')<>
        THashSHA2.GetHashStringFromFile('oct10-pdf-highlight.bmp'),'PDF highlights invisible');
      Reader.Width:=Reader.Width+10;
      Watch:=TStopwatch.StartNew;
      while Watch.ElapsedMilliseconds<150 do begin Application.ProcessMessages; CheckSynchronize(5); end;
      Require(Pos('Найдено',Reader.ReaderStatus.Caption)>0,'PDF resize erased search status');
      Reader.FindText('absent');
      while Reader.SearchRunning do begin Application.ProcessMessages; CheckSynchronize(5); end;
      Require(Pos('не найден',Reader.ReaderStatus.Caption)>0,'PDF no-result not reported');
      Reader.Close;
    finally B.Free; A.Free; Reader.Free; end;
    Writeln('PASS PDF search word/case/previous/all and centered fitted-page drag');
  finally DMUser.Free; DMUser:=nil; end;
end;

function ReaderFormattingBuffer(Reader: TfrmBuiltinReader): TRichEdit;
var I: Integer;
begin
  for I:=0 to Reader.ComponentCount-1 do
    if Reader.Components[I] is TRichEdit then Exit(TRichEdit(Reader.Components[I]));
  raise Exception.Create('Native reader formatting buffer is absent');
end;

procedure SelectReaderWord(Reader: TfrmBuiltinReader; const Text: string);
var Buffer: TRichEdit; Position: Integer;
begin
  Buffer:=ReaderFormattingBuffer(Reader); Position:=Pos(Text,Reader.BookText);
  Require(Position>0,'Formatting sample is absent: '+Text);
  Buffer.SelStart:=Position-1; Buffer.SelLength:=Length(Text);
end;

procedure CheckInlineStyles(Reader: TfrmBuiltinReader);
var Buffer: TRichEdit;
begin
  Buffer:=ReaderFormattingBuffer(Reader);
  SelectReaderWord(Reader,'bold'); Require(fsBold in Buffer.SelAttributes.Style,'Source bold run was lost');
  SelectReaderWord(Reader,'italic'); Require(fsItalic in Buffer.SelAttributes.Style,'Source italic run was lost');
  SelectReaderWord(Reader,'Regular'); Require(Buffer.SelAttributes.Style=[],'Inline style leaked into ordinary text');
  Buffer.SelLength:=0;
end;

procedure AuditFullNoteCopy;
var Document: TReaderDocument; Reader: TfrmBuiltinReader; Key: Word;
begin
  TFile.WriteAllText('long-note.fb2','<FictionBook xmlns:l="http://www.w3.org/1999/xlink">'+
    '<body><section><p>Reference <a type="note" l:href="#n">[1]</a>.</p></section></body>'+
    '<body name="notes"><section id="n"><p>'+StringOfChar('a',40000)+
    'FULL_NOTE_END</p></section></body></FictionBook>',TEncoding.UTF8);
  Document:=TReaderDocument.Create;
  try
    Document.Load('long-note.fb2');
    Require(Length(Document.FootnotesForRange(0,MaxInt))=32768,'Page footnotes lost their bounded display');
    Require(Document.FootnotesForRange(0,MaxInt,0).EndsWith('FULL_NOTE_END'),'Full note text was truncated');
  finally Document.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('long-note.fb2','Long note','long-note','long-note.ini','pdfium.dll'); WaitReady(Reader);
    Require(Reader.AllBookText.EndsWith('FULL_NOTE_END'),'Full book copy truncated a long footnote');
    Reader.Close;
  finally Reader.Free; end;
  Writeln('PASS full book copying retains long footnotes while the page display stays bounded');
end;

procedure AuditFootnotes;
var Document: TReaderDocument; Reader: TfrmBuiltinReader; Key: Word; Before: string; Name: string;
begin
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    for Name in ['footnotes.fb2','footnotes.epub'] do
    begin
      Before:=THashSHA2.GetHashStringFromFile(Name);
      Document:=TReaderDocument.Create;
      try
        Document.Load(Name);
        Require(Document.FootnoteCount=4,'Expected resolved references, including repeated/cross-file/encoded note: '+Name);
        Require(Document.PlainText.Contains('Reference [1] and repeated [1].'),'Spaces around inline markup were removed: '+Name);
        Require(Document.PlainText.Contains('Regular bold and italic text.'),'Inline formatting spacing was removed: '+Name);
        Require(Document.FootnotesForRange(0,Length(Document.PlainText)).Contains('First note content'), 'Footnote body missing: '+Name);
        Require(Document.FootnotesForRange(0,Length(Document.PlainText)).Contains('Second note content'), 'Second footnote missing: '+Name);
      finally Document.Free; end;
      Reader:=TfrmBuiltinReader.Create(nil);
      try
        Reader.Show; Reader.OpenBook(Name,'Footnotes',Name,'footnotes.ini','pdfium.dll'); WaitReady(Reader);
        Require(Reader.ShowFootnotes and Reader.VisibleFootnotes.Contains('First note content'),'Current page note not visible: '+Name);
        CheckInlineStyles(Reader);
        Require(not Reader.VisibleFootnotes.Contains('Second note content'),'Unreferenced page note is displayed too early');
        Reader.SetTheme(4); Reader.ChangeSize(1); Reader.FindText('Reference'); CheckInlineStyles(Reader);
        Require(Reader.VisibleFootnotes.Contains('First note content'),'Theme/font/search loses current footnote');
        Reader.SetShowFootnotes(False); Require(Reader.VisibleFootnotes='','Footnotes toggle is ignored');
        Reader.SetShowFootnotes(True); Require(Reader.VisibleFootnotes.Contains('First note content'),'Footnotes cannot be restored');
        Reader.FindText('Second reference');
        Require(Reader.VisibleFootnotes.Contains('Second note content'),Format('Page navigation did not update footnotes: %s pos=%d len=%d page=%s notes=%s',[Name,Reader.TextPosition,Length(Reader.PageText),Reader.PageText,Reader.VisibleFootnotes]));
        Reader.SetTheme(1); Reader.SetBounds(0,0,1100,780); CheckInlineStyles(Reader); Reader.Close;
      finally Reader.Free; end;
      Reader:=TfrmBuiltinReader.Create(nil);
      try
        Reader.Show; Reader.OpenBook(Name,'Footnotes restored',Name,'footnotes.ini','pdfium.dll'); WaitReady(Reader);
        Require(Reader.BookFormatting,'Reopening disabled book formatting'); CheckInlineStyles(Reader); Reader.Close;
      finally Reader.Free; end;
      Require(Before=THashSHA2.GetHashStringFromFile(Name),'Reader rewrote source book');
    end;
    AuditFullNoteCopy;
    Writeln('PASS FB2/EPUB current-page footnotes, non-linear EPUB resources, repeated references, theme/font/search/toggle and unchanged source');
  finally DMUser.Free; DMUser:=nil; end;
end;

procedure AuditMultilingualFonts;
const Samples: array[0..20] of string = ('Русский ё','Ελληνικά','Tiếng Việt','Հայերեն','עברית',
  'العربية','हिन्दी','বাংলা','ગુજરાતી','ಕನ್ನಡ','தமிழ்','తెలుగు','മലയാളം',
  'ไทย','ქართული','བོད','မြန်မာ','日本語','中文','한국어','አማርኛ');
var Reader: TfrmBuiltinReader; Buffer: TRichEdit; XML, Text, FontName, Effective: string;
  I: Integer; DC: HDC; Font, Previous: HGDIOBJ; Glyph: Word; Para: TParaFormat2; Watch: TStopwatch;
begin
  XML:='<FictionBook><description><title-info><book-title>Multilingual</book-title></title-info></description><body><section>';
  for Text in Samples do XML:=XML+'<p><strong>'+Text+'</strong> <emphasis>'+Text+'</emphasis></p>';
  XML:=XML+'</section></body></FictionBook>'; TFile.WriteAllText('multilingual.fb2',XML,TEncoding.UTF8);
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Watch:=TStopwatch.StartNew; Reader.Show;
    Reader.OpenBook('multilingual.fb2','Multilingual','multilingual','multilingual.ini','pdfium.dll'); WaitReady(Reader);
    Buffer:=ReaderFormattingBuffer(Reader);
    for FontName in ['PT Serif','PT Sans','Noto Serif','Noto Sans'] do
    begin
      Reader.SetTypography(FontName,110,32);
      for I:=0 to High(Samples) do
      begin
        Text:=Samples[I]; SelectReaderWord(Reader,Text); Effective:=Buffer.SelAttributes.Name;
        Require(fsBold in Buffer.SelAttributes.Style,'Multilingual fallback lost source bold: '+Text);
        Require(Screen.Fonts.IndexOf(Effective)>=0,'Multilingual font not registered: '+Effective);
        DC:=CreateCompatibleDC(0); Font:=CreateFontW(-20,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,
          OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,DEFAULT_QUALITY,DEFAULT_PITCH,PChar(Effective));
        try
          Previous:=SelectObject(DC,Font);
          try
            Require(GetGlyphIndicesW(DC,PChar(Text),1,@Glyph,GGI_MARK_NONEXISTING_GLYPHS)<>GDI_ERROR,'Glyph lookup failed');
            Require((Glyph<>0) and (Glyph<>$FFFF),'Missing bundled glyph: '+Text+' / '+Effective);
          finally SelectObject(DC,Previous); end;
        finally DeleteObject(Font); DeleteDC(DC); end;
        if I in [4,5] then
        begin
          FillChar(Para,SizeOf(Para),0); Para.cbSize:=SizeOf(Para);
          SendMessage(Buffer.Handle,EM_GETPARAFORMAT,0,LPARAM(@Para));
          Require((Para.wReserved and PFE_RTLPARA)<>0,'RTL paragraph direction was not retained: '+Text);
        end;
        Require(Reader.AllBookText.Contains(Text),'Unicode copying lost multilingual text: '+Text);
      end;
      Reader.SetTheme(4); Reader.ChangeSize(1); Reader.SetTheme(1);
    end;
    Writeln('PASS four bundled reading choices, 21 language samples, native glyphs, inline emphasis, RTL direction and Unicode copy; elapsed_ms=',Watch.ElapsedMilliseconds);
    Reader.Close;
  finally Reader.Free; end;
end;

procedure AuditOptionalFonts;
var Reader: TfrmBuiltinReader; Offer: TPanel; Download, Later: TButton; LabelText: TLabel;
  Watch: TStopwatch; Position: Integer; Source, Cache: string;
  procedure FindOffer;
  begin
    Offer:=Reader.FindComponent('ReaderLanguageFonts') as TPanel;
    Require(Assigned(Offer),'Language font offer was not created');
    Download:=nil; Later:=nil; LabelText:=nil;
    for var I:=0 to Offer.ControlCount-1 do
      if Offer.Controls[I] is TButton then
      begin
        var B:=TButton(Offer.Controls[I]);
        if B.Caption='Скачать' then Download:=B else if B.Caption='Позже' then Later:=B;
      end
      else if Offer.Controls[I] is TLabel then LabelText:=TLabel(Offer.Controls[I]);
    Require(Assigned(Download) and Assigned(Later) and Assigned(LabelText),'Font offer buttons or explanation are missing');
  end;
begin
  Cache:=ReaderFontCachePath;
  Require(not ReaderFontFamilyCached('Noto Serif Bengali'),'Test needs an incomplete isolated font cache');
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('basic-fonts.txt','Basic languages','basic-fonts','font-offer.ini','pdfium.dll'); WaitReady(Reader);
    Reader.SetTypography('PT Serif',110,32); Application.ProcessMessages; FindOffer;
    Require(not Offer.Visible,'RU EN UK BE book incorrectly requests a font download');
    Reader.Close;
  finally Reader.Free; end;
  if EnsureReaderFont('Noto Serif Armenian') then
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook('existing-fonts.txt','Windows font','existing-fonts','font-offer.ini','pdfium.dll'); WaitReady(Reader);
      Reader.SetTypography('PT Serif',110,32); Application.ProcessMessages; FindOffer;
      Require(not Offer.Visible,'Font already available in Windows incorrectly requests a download'); Reader.Close;
    finally Reader.Free; end;
    Writeln('PASS an already available Windows script font does not request a download');
  end;
  // Production opens a fresh reader form for each book, with its own loader.
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('optional-fonts.txt','Bengali','optional-fonts','font-offer.ini','pdfium.dll'); WaitReady(Reader);
    Require(Pos('বাংলা',Reader.AllBookText)>0,'Optional-font fixture lost its Bengali text');
    Require(Screen.Fonts.IndexOf('Noto Serif Bengali')<0,'Missing-font fixture is already installed in Windows');
    FindOffer;
    Reader.SetTypography('PT Serif',110,32); Application.ProcessMessages;
    Require(Offer.Visible and (Pos('бенгальского',LabelText.Caption)>0) and ((Pos('КБ',LabelText.Caption)>0) or (Pos('МБ',LabelText.Caption)>0)),
      'Missing-script offer has no language, size or visible controls: '+LabelText.Caption);
    for var I:=1 to 10 do begin Reader.NextPage; Application.ProcessMessages; end;
    Require(not ReaderFontFamilyCached('Noto Serif Bengali'),'Painting downloaded fonts without consent');
    Require(Length(TDirectory.GetFiles(Cache,'*.ttf',TSearchOption.soAllDirectories))=1,'Reading or page turns downloaded font files');
    Later.Click; Application.ProcessMessages; Require(not Offer.Visible,'Later did not dismiss the offer');
    Reader.PreviousPage; Application.ProcessMessages; Require(not Offer.Visible,'Dismissed offer returns on every page');
    Reader.Close;
  finally Reader.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('optional-fonts.txt','Bengali','optional-fonts','font-offer.ini','pdfium.dll'); WaitReady(Reader);
    Reader.SetTypography('PT Serif',110,32); Application.ProcessMessages; FindOffer;
    Require(Offer.Visible,'A later book opening cannot retry the font offer');
    Source:=Reader.AllBookText;
    Reader.NextPage; Position:=Reader.TextPosition; Reader.SetTheme(4); Application.ProcessMessages;
    Require(Offer.Color<>clWhite,'Language offer ignores dark reader theme');
    Download.Click; Watch:=TStopwatch.StartNew;
    while Offer.Visible and (Watch.ElapsedMilliseconds<60000) do
    begin Sleep(10); Application.ProcessMessages; CheckSynchronize(1); end;
    Require(not Offer.Visible,'Explicit font download did not complete: '+LabelText.Caption);
    Require(ReaderFontFamilyCached('Noto Serif Bengali'),'Complete verified family was not cached');
    Require(Reader.TextPosition=Position,'Font completion changed the reading position');
    Require(Reader.AllBookText=Source,'Font completion changed book text');
    Require(Screen.Fonts.IndexOf('Noto Serif Bengali')>=0,'Downloaded font was not privately registered');
    Reader.Close;
  finally Reader.Free; end;
  Writeln('PASS optional fonts require explicit download, skip basic languages, retain position and text, retry after Later and cache a complete family');
end;

procedure AuditUnspacedHistory;
var Reader: TfrmBuiltinReader; Position: Integer; Name: string;
begin
  for Name in ['nospace.txt','nospace-emoji.txt'] do
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook(Name,Name,'history-'+Name,'history.ini','pdfium.dll'); WaitReady(Reader);
      Reader.FindText('БЕЗПРОБЕЛОВКОНЕЦ'); Position:=Reader.TextPosition;
      Require(Position=20000,'Unspaced search lost its UTF-16 offset');
      Reader.PreviousPage;
      Require(Reader.TextPosition<Position,'Previous page cannot leave unspaced paragraph');
      Position:=Reader.TextPosition; Reader.NextPage;
      Require(Reader.TextPosition>Position,'Cached successor cannot be reached at the short final tail');
      Reader.Close;
    finally Reader.Free; end;
  end;
  Writeln('PASS unspaced Unicode previous/next history with bundled fallback fonts');
end;

procedure AuditInitialMarks;
var Document: TReaderDocument; Range: TReaderStyledRange; InitialCount: Integer;
  Reader: TfrmBuiltinReader; Buffer: TRichEdit; InitialSize: Integer; ExpectedCounts: TArray<Integer>;
begin
  Document:=TReaderDocument.Create;
  try
    Document.Load('initial-marks.fb2'); InitialCount:=0; ExpectedCounts:=TArray<Integer>.Create(2,2,3,1);
    for Range in Document.Styles do if Range.Kind in [rbInitial,rbParagraphInitial] then
    begin
      Require((InitialCount<Length(ExpectedCounts)) and (Range.Count=ExpectedCounts[InitialCount]),'Decorative initial separates its combining accent');
      Inc(InitialCount);
    end;
    Require(InitialCount=4,'Initial-mark fixture loses prose paragraphs');
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook('initial-marks.fb2','Initial marks','initial-marks','initial-marks.ini','pdfium.dll'); WaitReady(Reader);
      Reader.SetInitialsMode(rimParagraph); Buffer:=ReaderFormattingBuffer(Reader);
      for Range in Document.Styles do if Range.Kind in [rbInitial,rbParagraphInitial] then
      begin
        Buffer.SelStart:=Range.Start; Buffer.SelLength:=1; InitialSize:=Buffer.SelAttributes.Size;
        Require(InitialSize>Reader.ReaderFontSize,'Decorative initial has ordinary size');
        for var I:=1 to Range.Count-1 do
        begin
          Buffer.SelStart:=Range.Start+I; Buffer.SelLength:=1;
          Require(Buffer.SelAttributes.Size=InitialSize,'Combining mark has different native size');
        end;
        Buffer.SelStart:=Range.Start+Range.Count; Buffer.SelLength:=1;
        Require(Buffer.SelAttributes.Size=Reader.ReaderFontSize,'Initial decoration consumes the next ordinary letter');
      end;
      Require(Reader.BookText.StartsWith(Document.PlainText.TrimRight([#13])),'Initial grouping changes copyable Unicode');
    finally Reader.Free; end;
  finally Document.Free; end;
  Writeln('PASS decorative initials keep Cyrillic/Latin combining accents at one size and leave the following letter and copied text unchanged');
end;

procedure AuditNamedStyleText;
const Expected = 'До важные слова ё после.'+#13+'Слово другое.';
var Document: TReaderDocument; Reader: TfrmBuiltinReader; Key: Word;
begin
  Document:=TReaderDocument.Create;
  try
    Document.Load('named-style.fb2');
    Require(Document.PlainText.TrimRight([#13])=Expected,'FB2 named style drops text or separating whitespace');
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook('named-style.fb2','Named style','named-style','named-style.ini','pdfium.dll'); WaitReady(Reader);
      Require(Reader.BookText.TrimRight([#13])=Expected,'Native reader loses named-style text');
      Key:=Ord('C'); Reader.OnKeyDown(Reader,Key,[ssCtrl,ssShift]);
      Require(ReadClipboardText.TrimRight([#13,#10]).Replace(#13#10,#13)=Expected,'Copied named-style prose changed');
    finally Reader.Free; end;
    Document.Load('css-style.xhtml');
    Require(Document.PlainText.TrimRight([#13])='Visible prose.','HTML CSS or script content leaks into reading text');
  finally Document.Free; end;
  Writeln('PASS FB2 named styles preserve exact Unicode prose and separating whitespace while HTML CSS and scripts stay hidden');
end;

procedure AuditHeadingLevels;
var Name: string; Document: TReaderDocument; Range: TReaderStyledRange;
  HasMain, HasSub: Boolean; Reader: TfrmBuiltinReader; Buffer: TRichEdit;
  MainSize: Integer; Paragraph: TParaFormat2;
begin
  for Name in TArray<string>.Create('hierarchy.fb2','hierarchy.xhtml','hierarchy-fallback.html','hierarchy.docx','hierarchy.odt','hierarchy.epub') do
  begin
    Document:=TReaderDocument.Create;
    try
      Document.Load(Name); HasMain:=False; HasSub:=False;
      for Range in Document.Styles do
      begin
        if (Range.Kind=rbTitle) and (Trim(Copy(Document.PlainText,Range.Start+1,Range.Count))='Main heading') then HasMain:=True;
        if (Range.Kind=rbSubtitle) and (Trim(Copy(Document.PlainText,Range.Start+1,Range.Count))='Sub heading') then HasSub:=True;
      end;
      Require(HasMain and HasSub,'Heading hierarchy lost in '+Name);
      Require(Document.PlainText.Contains('Body paragraph.') and Document.PlainText.Contains('Nested paragraph.'),'Paragraph text lost in '+Name);
      if not MatchText(ExtractFileExt(Name),['.docx','.odt']) then
        Require(Document.PlainText.Contains('Alpha'+#9+'Beta'),'Table cells merged in '+Name);
    finally Document.Free; end;
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook(Name,Name,Name,'hierarchy-reader.ini','pdfium.dll'); WaitReady(Reader);
      Reader.SetTheme(0); Reader.SetHeadingColor(clPurple); Reader.SetHeadingColor(clBlue,True);
      SelectReaderWord(Reader,'Main heading'); Buffer:=ReaderFormattingBuffer(Reader);
      MainSize:=Buffer.SelAttributes.Size;
      Require(ColorToRGB(Buffer.SelAttributes.Color)=ColorToRGB(clPurple),'Main heading color lost in '+Name);
      FillChar(Paragraph,SizeOf(Paragraph),0); Paragraph.cbSize:=SizeOf(Paragraph);
      SendMessage(Buffer.Handle,EM_GETPARAFORMAT,0,LPARAM(@Paragraph));
      Require(Paragraph.wAlignment=PFA_CENTER,'Main heading alignment lost in '+Name);
      SelectReaderWord(Reader,'Sub heading');
      Require(ColorToRGB(Buffer.SelAttributes.Color)=ColorToRGB(clBlue),'Subtitle color lost in '+Name);
      Require((Buffer.SelAttributes.Size>MainSize div 2) and (Buffer.SelAttributes.Size<MainSize),'Subtitle size lost in '+Name);
      FillChar(Paragraph,SizeOf(Paragraph),0); Paragraph.cbSize:=SizeOf(Paragraph);
      SendMessage(Buffer.Handle,EM_GETPARAFORMAT,0,LPARAM(@Paragraph));
      Require(Paragraph.wAlignment=PFA_CENTER,'Subtitle alignment lost in '+Name);
      Require(Reader.BookText.Contains('Body paragraph.') and Reader.BookText.Contains('Nested paragraph.'),'Native copy text lost in '+Name);
    finally Reader.Free; end;
  end;
  Writeln('PASS heading hierarchy, colors, alignment and copyable table-cell boundaries in FB2, XHTML, fallback HTML, DOCX, ODT and EPUB');
end;

procedure AuditClipboardContention(Reader: TfrmBuiltinReader);
var Locked: TEvent; Worker: TThread; Key: Word;
begin
  Locked:=TEvent.Create(nil,True,False,'');
  Worker:=TThread.CreateAnonymousThread(
    procedure
    begin
      // Another desktop app can briefly own the clipboard before this fixture.
      // First acquire it, then deliberately hold it for the reader-copy check.
      for var Attempt:=0 to 99 do
      begin
        if OpenClipboard(0) then
        begin
          try Locked.SetEvent; Sleep(80); finally CloseClipboard; end;
          Exit;
        end;
        Sleep(5);
      end;
    end);
  Worker.FreeOnTerminate:=False;
  try
    Worker.Start; Require(Locked.WaitFor(1000)=wrSignaled,'Clipboard contention fixture failed');
    Key:=Ord('C'); Reader.OnKeyDown(Reader,Key,[ssCtrl]);
    Worker.WaitFor;
    Require(ReadClipboardText=Reader.PageText,'Transient clipboard contention lost copied text');
  finally Worker.WaitFor; Worker.Free; Locked.Free; end;
  Writeln('PASS copying retries transient clipboard contention');
end;

procedure AuditOctoberElevenReader;
var Reader: TfrmBuiltinReader; Document: TReaderDocument; Range: TReaderStyledRange;
  Key: Word; Pan,Size: TPoint; Ini: TMemIniFile; A,B: TBitmap; HasTitle,HasQuote,HasPoem: Boolean;
  CappedEnd, WideEnd: Integer;
  procedure CheckBlockStyles;
  var Buffer: TRichEdit; BodySize, TitleSize: Integer; BodyColor: TColor; Paragraph: TParaFormat2;
  begin
    Reader.GoToPosition(0);
    Buffer:=ReaderFormattingBuffer(Reader);
    SelectReaderWord(Reader,'длинный абзац'); BodySize:=Buffer.SelAttributes.Size; BodyColor:=Buffer.SelAttributes.Color;
    SelectReaderWord(Reader,'Оглавление'); TitleSize:=Buffer.SelAttributes.Size;
    Require((TitleSize>BodySize) and (fsBold in Buffer.SelAttributes.Style),'Title no longer differs from body text');
    Require(Buffer.SelAttributes.Color<>BodyColor,'Title lost its readable theme color');
    FillChar(Paragraph,SizeOf(Paragraph),0); Paragraph.cbSize:=SizeOf(Paragraph);
    SendMessage(Buffer.Handle,EM_GETPARAFORMAT,0,LPARAM(@Paragraph));
    Require(Paragraph.wAlignment=PFA_CENTER,'Title paragraph is no longer centered');
    SelectReaderWord(Reader,'Подзаголовок');
    Require((Buffer.SelAttributes.Size>BodySize) and (Buffer.SelAttributes.Size<TitleSize),'Title/subtitle hierarchy was lost');
    SelectReaderWord(Reader,'Цитата с оформлением'); Require(fsItalic in Buffer.SelAttributes.Style,'Epigraph lost its italic style');
    SelectReaderWord(Reader,'Первая строка стиха');
    FillChar(Paragraph,SizeOf(Paragraph),0); Paragraph.cbSize:=SizeOf(Paragraph);
    SendMessage(Buffer.Handle,EM_GETPARAFORMAT,0,LPARAM(@Paragraph));
    Require((Paragraph.wAlignment=PFA_LEFT) and (Paragraph.dxStartIndent>0),'Verse lost its alignment or indentation');
    Require(Reader.BookText.Contains('Первая строка стиха'+#13+'Вторая строка стиха'),'Verse lines were concatenated');
    Buffer.SelLength:=0;
  end;
  procedure GoStart;
  begin
    Reader.ReadingSurface.SetFocus; Key:=VK_HOME; Reader.OnKeyDown(Reader,Key,[]);
    Require(Reader.TextPosition=0,'Home did not return to the beginning');
  end;
begin
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  var ProfileDir:=TPath.Combine(GetCurrentDir,'profile-path-check');
  var OldProfile:=ProfileDir+'reader.ini';
  var OldContents:='[Reader]'+#13#10+'FontName=Georgia'+#13#10+'[Book.saved]'+#13#10+'Position=6086'+#13#10+'Bookmarks=12,34';
  TFile.WriteAllText(OldProfile,OldContents,TEncoding.UTF8);
  var NewProfile:=ResolveReaderSettingsFile(ProfileDir);
  Require(NewProfile=TPath.Combine(ProfileDir,'reader.ini'),'Reader profile path still omits separator');
  Require(TFile.ReadAllText(NewProfile,TEncoding.UTF8)=OldContents,'Reader migration loses preferences, positions or bookmarks');
  Require(TFile.ReadAllText(OldProfile,TEncoding.UTF8)=OldContents,'Reader migration changed original profile');
  TFile.WriteAllText(NewProfile,'updated canonical profile',TEncoding.UTF8);
  Require(ResolveReaderSettingsFile(ProfileDir)=NewProfile,'Canonical profile is not preferred');
  Require(TFile.ReadAllText(NewProfile,TEncoding.UTF8)='updated canonical profile','Legacy profile overwrote new settings');
  Require(ResolveReaderSettingsFile(IncludeTrailingPathDelimiter(ProfileDir))=NewProfile,'Profile path depends on trailing separator');
  var BlockedDir:=TPath.Combine(GetCurrentDir,'blocked-profile-path');
  ForceDirectories(TPath.Combine(BlockedDir,'reader.ini'));
  TFile.WriteAllText(BlockedDir+'reader.ini',OldContents,TEncoding.UTF8);
  Require(ResolveReaderSettingsFile(BlockedDir)=BlockedDir+'reader.ini','Failed migration cannot reopen original profile');
  Require(Length(TDirectory.GetFiles(BlockedDir,'*.migrating-*'))=0,'Failed migration left partial profile');
  Require(TFile.ReadAllText(BlockedDir+'reader.ini',TEncoding.UTF8)=OldContents,'Failed migration damaged original settings');
  Writeln('PASS reader profile migration preserves original preferences, bookmarks and positions, respects newer settings and recovers from failed copy');
  AuditMultilingualFonts;
  AuditHeadingLevels;
  AuditInitialMarks;
  AuditNamedStyleText;
  Document:=TReaderDocument.Create;
  try
    Document.Load('unmarked.fb2');
    var InferredCount:=0;
    for Range in Document.Styles do if Range.Kind=rbSubtitle then
    begin
      Inc(InferredCount);
      Require(Copy(Document.PlainText,Range.Start+1,Range.Count)='ВСТРЕЧА С КАРОЛИНКОЙ','Unmarked heading inference changed ordinary prose or verse');
    end;
    Require(InferredCount=1,'Short unmarked FB2 heading was not recognized');
    Writeln('PASS conservative unmarked FB2 headings exclude dialogue, long prose and verse');
    Document.Load('styled.fb2');
    Require((Document.ImageCount=1) and (Pos(#$FFFC,Document.PlainText)<Pos('Оглавление',Document.PlainText)),'FB2 cover is not before body');
    Require(Document.PlainText.Contains('Первое название'+#13+'Второе название'),'Title paragraphs concatenated');
    HasTitle:=False; HasQuote:=False; HasPoem:=False;
    for Range in Document.Styles do
    begin
      Require((Range.Count>0) and (Range.Start+Range.Count<=Length(Document.PlainText)),'Semantic range outside document');
      if Range.Kind=rbTitle then HasTitle:=True;
      if Range.Kind=rbEpigraph then HasQuote:=True;
      if Range.Kind=rbPoem then HasPoem:=True;
    end;
    Require(HasTitle and HasQuote and HasPoem,'Semantic formatting ranges missing');
  finally Document.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil); A:=TBitmap.Create; B:=TBitmap.Create;
  try
    Reader.Show; Reader.OpenBook('styled.fb2','Styled','oct11-styled','oct11-reader.ini','pdfium.dll'); WaitReady(Reader);
    Require(Reader.BookFormatting,'Book formatting is disabled by default'); CheckBlockStyles;
    Reader.GoToChapter(0); A.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
    Reader.ReadingSurface.PaintTo(A.Canvas.Handle,0,0); A.SaveToFile('oct11-styled-on.bmp');
    Reader.SetBookFormatting(False); B.SetSize(A.Width,A.Height); Reader.ReadingSurface.PaintTo(B.Canvas.Handle,0,0); B.SaveToFile('oct11-styled-off.bmp');
    Require(THashSHA2.GetHashStringFromFile('oct11-styled-on.bmp')<>THashSHA2.GetHashStringFromFile('oct11-styled-off.bmp'),'Formatting toggle does not change presentation');
    Reader.SetBookFormatting(True); CheckBlockStyles;
    Require((Screen.Fonts.IndexOf('PT Serif')>=0) and (Screen.Fonts.IndexOf('PT Sans')>=0),'Bundled free font families were not loaded privately');
    for var FontName in ['PT Serif','PT Sans','Noto Serif','Noto Sans','Georgia','Segoe UI'] do
    begin
      Reader.SetTypography(FontName,110,32); CheckBlockStyles;
      SelectReaderWord(Reader,'длинный абзац');
      Require(ReaderFormattingBuffer(Reader).SelAttributes.Name=FontName,'Reader silently substituted chosen font '+FontName);
    end;
    Reader.SetTypography('Georgia',110,32);
    Require(not Reader.DecorativeInitials,'Fresh profile unexpectedly decorates initial letters');
    Reader.SetHeadingColor(clGreen); Reader.SetHeadingColor(clPurple,True);
    SelectReaderWord(Reader,'Оглавление');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(clGreen),'Custom heading color ignored');
    SelectReaderWord(Reader,'Подзаголовок');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(clPurple),'Custom subtitle color ignored');
    Reader.SetDecorativeInitials(True);
    var InitialStart:=Pos('Это длинный абзац',Reader.BookText)-1;
    var InitialBuffer:=ReaderFormattingBuffer(Reader);
    InitialBuffer.SelStart:=InitialStart; InitialBuffer.SelLength:=1;
    var InitialSize:=InitialBuffer.SelAttributes.Size;
    InitialBuffer.SelStart:=InitialStart+1; InitialBuffer.SelLength:=1;
    Require(InitialSize>InitialBuffer.SelAttributes.Size,Format('Initial letter is not emphasized: offset=%d initial=%d following=%d',[InitialStart,InitialSize,InitialBuffer.SelAttributes.Size]));
    Reader.SetDecorativeInitials(False); InitialBuffer.SelStart:=InitialStart; InitialBuffer.SelLength:=2;
    Require(InitialBuffer.SelAttributes.Size<InitialSize,'Disabling initials leaves enlarged letter');
    Reader.SetInitialsMode(rimParagraph);
    var ParagraphDocument:=TReaderDocument.Create;
    try
      ParagraphDocument.Load('styled.fb2');
      var ParagraphInitialCount:=0;
      for Range in ParagraphDocument.Styles do
        if Range.Kind=rbParagraphInitial then
        begin
          Inc(ParagraphInitialCount);
          Reader.GoToPosition(Range.Start);
          InitialBuffer.SelStart:=Range.Start; InitialBuffer.SelLength:=1;
          Require(InitialBuffer.SelAttributes.Size>Reader.ReaderFontSize,'Paragraph initial is not enlarged');
          InitialBuffer.SelStart:=Range.Start+1; InitialBuffer.SelLength:=1;
          Require(InitialBuffer.SelAttributes.Size=Reader.ReaderFontSize,'Initial-letter formatting leaks into paragraph');
        end;
      Require(ParagraphInitialCount>5,'Paragraph initial ranges are missing');
      Reader.SetBookFormatting(False);
      for Range in ParagraphDocument.Styles do
        if Range.Kind in [rbInitial,rbParagraphInitial] then
        begin
          Reader.GoToPosition(Range.Start);
          InitialBuffer.SelStart:=Range.Start; InitialBuffer.SelLength:=1;
          Require(InitialBuffer.SelAttributes.Size>Reader.ReaderFontSize,'Disabling book formatting suppressed independently enabled initials');
        end;
      Reader.SetInitialsMode(rimNone); Reader.GoToPosition(InitialStart);
      InitialBuffer.SelStart:=InitialStart; InitialBuffer.SelLength:=1;
      Require(InitialBuffer.SelAttributes.Size=Reader.ReaderFontSize,'Disabled plain-mode initial remains enlarged');
      Reader.SetBookFormatting(True); Reader.SetInitialsMode(rimParagraph);
      Writeln('PASS paragraph initials remain independent of book formatting');
      Reader.SetInitialsMode(rimChapter);
      for Range in ParagraphDocument.Styles do
        if Range.Kind=rbParagraphInitial then
        begin
          InitialBuffer.SelStart:=Range.Start; InitialBuffer.SelLength:=1;
          Require(InitialBuffer.SelAttributes.Size=Reader.ReaderFontSize,'Chapter mode decorates ordinary paragraph');
        end;
    finally ParagraphDocument.Free; end;
    Reader.SetInitialsMode(rimParagraph);
    GoStart; Reader.NextPage;
    Require((Reader.PageText<>'') and (Length(Reader.PageText)<Length(Reader.AllBookText)),'Page copying includes the whole book');
    Key:=Ord('C'); Reader.OnKeyDown(Reader,Key,[ssCtrl]);
    Require((Key=0) and (ReadClipboardText=Reader.PageText),'Ctrl+C did not copy current text page');
    AuditClipboardContention(Reader);
    Key:=Ord('C'); Reader.OnKeyDown(Reader,Key,[ssCtrl,ssShift]);
    Require((Key=0) and (ReadClipboardText=Reader.AllBookText),'Ctrl+Shift+C did not copy the book');
    Require(not ReadClipboardText.Contains(#$FFFC),'Copied text contains image placeholders');
    Reader.SetTheme(4); CheckBlockStyles;
    Reader.SetHeadingColor(clPurple); Reader.SetHeadingColor(clBlue,True);
    for var RawColor in TArray<TColor>.Create(clBlack,clPurple,clBlue,clNavy,clGreen,clRed,clYellow,clAqua) do
      Require(ReaderColorContrast(ReadableReaderColor(RawColor,$002B2927),$002B2927)>=4.5,'Dark heading color lacks readable contrast');
    SelectReaderWord(Reader,'Оглавление');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(ReadableReaderColor(clPurple,$002B2927)),'Dark purple was not adapted for page background');

    var ColorReader:=TfrmBuiltinReader.Create(nil);
    try
      ColorReader.Show; ColorReader.OpenBook('colors.fb2','Colors','oct12-colors','oct12-colors.ini','pdfium.dll'); WaitReady(ColorReader);
      ColorReader.SetTheme(4); ColorReader.SetHeadingColor(clPurple); ColorReader.SetHeadingColor(clBlue,True);
      A.SetSize(ColorReader.ReadingSurface.Width,ColorReader.ReadingSurface.Height);
      ColorReader.ReadingSurface.PaintTo(A.Canvas.Handle,0,0); A.SaveToFile('oct12-heading-colors.bmp');
      SetMHLTheme(True); ColorReader.SetBounds(0,0,1200,800);
      A.SetSize(ColorReader.ReadingSurface.Width,ColorReader.ReadingSurface.Height);
      ColorReader.ReadingSurface.PaintTo(A.Canvas.Handle,0,0); A.SaveToFile('oct12-heading-colors-app-theme.bmp');
      SelectReaderWord(ColorReader,'Цвет заголовка');
      Require(ColorToRGB(ReaderFormattingBuffer(ColorReader).SelAttributes.Color)=ColorToRGB(ReadableReaderColor(clPurple,$002B2927)),'App theme erased rendered purple heading');
      SelectReaderWord(ColorReader,'Цвет подзаголовка');
      Require(ColorToRGB(ReaderFormattingBuffer(ColorReader).SelAttributes.Color)=ColorToRGB(ReadableReaderColor(clBlue,$002B2927)),'App theme erased rendered blue subtitle');
      ColorReader.Close;
    finally ColorReader.Free; end;
    Reader.SetHeadingColor(clYellow); Reader.SetHeadingColor(clAqua,True);
    Reader.SetTheme(1); SelectReaderWord(Reader,'Оглавление');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(clGreen),'Dark heading color overwrote light setting');
    Reader.SetTheme(4); SelectReaderWord(Reader,'Оглавление');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(clYellow),'Dark heading color did not return');
    SetMHLTheme(True); Reader.SetTheme(4);
    Require(Reader.PictureCount=1,'App theme switch lost the cover image');
    Reader.SetHeadingColor(clYellow); Reader.SetHeadingColor(clAqua,True);
    Reader.NextPage; CheckBlockStyles;
    SelectReaderWord(Reader,'Оглавление');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(clYellow),'App theme erased reader heading color');
    SelectReaderWord(Reader,'Подзаголовок');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(clAqua),'App theme erased reader subtitle color');
    SetMHLTheme(False); Reader.SetTheme(4);
    Reader.ChangeSize(2); CheckBlockStyles; Reader.FindText('Цитата'); CheckBlockStyles;
    Reader.SetBounds(0,0,1200,800); Reader.SetTypography('Georgia',130,48); CheckBlockStyles; Reader.Close;
  finally Reader.Free; B.Free; A.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('styled.fb2','Styled restored','oct11-styled','oct11-reader.ini','pdfium.dll'); WaitReady(Reader);
    Require(Reader.BookFormatting,'Reopening lost default book formatting'); CheckBlockStyles;
    Require(Reader.DecorativeInitials,'Reopening lost initial-letter preference');
    Require(Reader.InitialsMode=rimParagraph,'Reopening lost paragraph initial mode');
    SelectReaderWord(Reader,'Оглавление');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(clYellow),'Reopening lost dark heading color');
    Reader.SetTheme(1); SelectReaderWord(Reader,'Оглавление');
    Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(clGreen),'Reopening lost light heading color'); Reader.Close;
    Writeln('PASS configurable light/dark heading colors, optional initial letters and page/book Unicode copying persist through formatting, search and reopen');
  finally Reader.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('sample.txt','Text width','oct11-width','oct11-width.ini','pdfium.dll'); WaitReady(Reader);
    Require(Reader.MaxTextWidth=960,'Fresh text width is not limited to 960 pixels');
    Reader.SetBounds(0,0,2000,800); Reader.SetMaxTextWidth(960); GoStart; Reader.NextPage; CappedEnd:=Reader.TextPosition;
    Reader.SetBounds(0,0,2400,800); Reader.SetMaxTextWidth(960); GoStart; Reader.NextPage;
    Require(Reader.TextPosition=CappedEnd,'Capped text width changes on a wider screen');
    Reader.SetMaxTextWidth(0); GoStart; Reader.NextPage; WideEnd:=Reader.TextPosition;
    Require(WideEnd>CappedEnd,'Full-width text preference has no effect');
    Reader.SetMaxTextWidth(320); GoStart; Reader.NextPage;
    Require(Reader.TextPosition<CappedEnd,'Narrow text preference has no effect'); Reader.Close;
  finally Reader.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('sample.txt','Text width restored','oct11-width','oct11-width.ini','pdfium.dll'); WaitReady(Reader);
    Require(Reader.MaxTextWidth=320,'Text width did not survive reopening'); Reader.Close;
  finally Reader.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('sample.pdf','Mixed PDF','oct11-pdf','oct11-reader.ini','pdfium.dll'); WaitReady(Reader);
    Require(not Reader.PDFPageHasText,'Image-only PDF page wrongly marked as text');
    Require(Reader.PageText='','Scanned PDF exposes invented text');
    Require(Reader.InspectionPercent=150,'Fresh inspection zoom is not 150 percent');
    Size:=Reader.PageRasterSize; Pan:=Reader.PDFPan;
    Reader.ToggleInspection(Pan.X+Size.X div 2,Pan.Y+Size.Y div 2);
    Require(Reader.Inspecting and (Reader.PDFZoom=150),'Default click inspection is not 150 percent'); Reader.EndInspection;
    Reader.SetInspectionPercent(120); Size:=Reader.PageRasterSize; Pan:=Reader.PDFPan;
    Reader.ToggleInspection(Pan.X+Size.X div 2,Pan.Y+Size.Y div 2);
    Require(Reader.Inspecting and (Reader.PDFZoom=120),'120 percent inspection ignored'); Reader.EndInspection;
    Reader.SetInspectionPercent(300); Reader.ToggleInspection(Pan.X+Size.X div 2,Pan.Y+Size.Y div 2);
    Require(Reader.Inspecting and (Reader.PDFZoom=300),'300 percent inspection ignored'); Reader.EndInspection;
    Require((Reader.PDFZoom=100) and (Reader.PDFPan=Pan) and (Reader.PageRasterSize=Size),'Inspection did not restore fitted page');
    Reader.NextPage; WaitPage(Reader); Require(Reader.PDFPageHasText,'Copyable PDF page not detected');
    Reader.SelectPDFText(0,6); Require(Reader.PDFSelectedText='Needle','PDF selection text incorrect');
    Key:=Ord('C'); Reader.OnKeyDown(Reader,Key,[ssCtrl]); Require((Key=0) and (ReadClipboardText='Needle'),'Ctrl+C did not copy selected PDF text');
    Reader.NextPage; Require(Reader.PDFSelectedText='','Pending PDF navigation retained selection'); WaitPage(Reader); Require(not Reader.PDFPageHasText and (Reader.PDFSelectedText=''),'PDF selection leaked to another page');
    Reader.ChangeSize(5); Require(Reader.PDFZoom=150,'Manual PDF zoom incorrect'); Reader.Close;
  finally Reader.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('search.pdf','Different PDF','oct11-other-pdf','oct11-reader.ini','pdfium.dll'); WaitReady(Reader);
    Require((Reader.PDFZoom=100) and (Reader.InspectionPercent=300),'New PDF inherits cropped zoom or loses inspection preference'); Reader.Close;
  finally Reader.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('sample.pdf','Mixed PDF restored','oct11-pdf','oct11-reader.ini','pdfium.dll'); WaitReady(Reader);
    Require(Reader.PDFZoom=150,'Reopening the same PDF lost its zoom'); Reader.Close;
  finally Reader.Free; end;
  Writeln('PASS cover, semantic formatting, title paragraph breaks, capped text width, PDF copying, configurable inspection and per-book zoom');
  if TFile.Exists('formatting-real.fb2') then
  begin
    var OriginalHash:=THashSHA2.GetHashStringFromFile('formatting-real.fb2');
    Reader:=TfrmBuiltinReader.Create(nil); Document:=TReaderDocument.Create; A:=TBitmap.Create;
    try
      Document.Load('formatting-real.fb2');
      Reader.Show; Reader.OpenBook('formatting-real.fb2','Real formatting','oct12-real','oct12-real.ini','pdfium.dll'); WaitReady(Reader);
      Reader.SetTheme(4); Reader.SetHeadingColor(clPurple); Reader.SetHeadingColor(clBlue,True); Reader.SetInitialsMode(rimParagraph);
      var RenderedText:=Reader.BookText;
      // RichEdit omits its terminal paragraph marker from the text range.
      Require((RenderedText=Document.PlainText) or (RenderedText+#13=Document.PlainText),'Real FB2 text changed during rendering');
      var ActualParagraphs:=0;
      for Range in Document.Styles do
      begin
        if Range.Kind in [rbTitle,rbSubtitle] then
        begin
          var ExpectedColor:=clPurple; if Range.Kind=rbSubtitle then ExpectedColor:=clBlue;
          ReaderFormattingBuffer(Reader).SelStart:=Range.Start; ReaderFormattingBuffer(Reader).SelLength:=Range.Count;
          Require(ColorToRGB(ReaderFormattingBuffer(Reader).SelAttributes.Color)=ColorToRGB(ReadableReaderColor(ExpectedColor,$002B2927)),'Real heading color lost');
        end;
        if Range.Kind in [rbInitial,rbParagraphInitial] then
        begin
          Inc(ActualParagraphs); ReaderFormattingBuffer(Reader).SelStart:=Range.Start; ReaderFormattingBuffer(Reader).SelLength:=1;
          Require(ReaderFormattingBuffer(Reader).SelAttributes.Size>Reader.ReaderFontSize,'Real paragraph initial lost');
        end;
      end;
      Require(ActualParagraphs>10,'Real paragraph fixture does not exercise ordinary paragraphs');
      A.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
      Reader.ReadingSurface.PaintTo(A.Canvas.Handle,0,0); A.SaveToFile('oct12-real-formatting.bmp');
      Reader.NextPage; Reader.PreviousPage; Reader.ChangeSize(1); Reader.FindText('Каролинка');
      Reader.Close;
      Require(THashSHA2.GetHashStringFromFile('formatting-real.fb2')=OriginalHash,'Real FB2 source changed');
      Writeln('PASS real FB2 preserves text and semantic colors, decorates each ordinary paragraph and stays readable through navigation/search');
    finally A.Free; Document.Free; Reader.Free; end;
  end;
  DMUser.Free; DMUser:=nil;
end;

procedure AuditRealFormats;
var Name, Extension, Prepared, Hash: string; Doc: TReaderDocument; PDF: TReaderPDF; Watch: TStopwatch;
begin
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    for Name in TDirectory.GetFiles('formats') do
    begin
      Hash:=THashSHA2.GetHashStringFromFile(Name); Watch:=TStopwatch.StartNew;
      Extension:=DetectReaderExtension(Name); Prepared:=PrepareDetectedReaderFile(Name,Name);
      Require(Extension<>'','Real file not recognized '+ExtractFileName(Name));
      if Extension='.pdf' then
      begin
        PDF:=TReaderPDF.Create('pdfium.dll',Prepared);
        try Require(PDF.PageCount>0,'Real PDF has no pages');
          Writeln('REAL ',ExtractFileName(Name),' detected=',Extension,' pages=',PDF.PageCount,' ms=',Watch.ElapsedMilliseconds);
        finally PDF.Free; end;
      end
      else
      begin
        Require(IsBuiltinReaderFormat(Extension),'Unexpected unsupported fixture '+Extension);
        Doc:=TReaderDocument.Create;
        try Doc.Load(Prepared); Require(Length(Doc.PlainText)>100,'Real document lost text '+ExtractFileName(Name));
          Writeln('REAL ',ExtractFileName(Name),' detected=',Extension,' chars=',Length(Doc.PlainText),' ms=',Watch.ElapsedMilliseconds);
        finally Doc.Free; end;
      end;
      Require(THashSHA2.GetHashStringFromFile(Name)=Hash,'Real fixture changed'); Flush(Output);
    end;
    Writeln('PASS real archive MHT/WRI/FB2 aliases and mislabeled PDF contents');
  finally DMUser.Free; DMUser:=nil; end;
end;

type
  TReaderMessageProbe = class
    Original: TWndMethod;
    FormatMS, StyleMS, StreamMS, SelectMS, LengthMS: Int64;
    Formats, Styles: Integer;
    procedure Message(var Value: TMessage);
  end;

procedure TReaderMessageProbe.Message(var Value: TMessage);
var Watch: TStopwatch;
begin
  Watch:=TStopwatch.StartNew; Original(Value);
  case Value.Msg of
    EM_FORMATRANGE: begin Inc(FormatMS,Watch.ElapsedTicks); Inc(Formats); end;
    EM_SETCHARFORMAT, EM_SETPARAFORMAT: begin Inc(StyleMS,Watch.ElapsedTicks); Inc(Styles); end;
    EM_STREAMIN: Inc(StreamMS,Watch.ElapsedTicks);
    EM_EXSETSEL, EM_SETSEL, EM_SCROLLCARET: Inc(SelectMS,Watch.ElapsedTicks);
    EM_GETTEXTLENGTHEX, WM_GETTEXTLENGTH: Inc(LengthMS,Watch.ElapsedTicks);
  end;
end;

procedure AuditSelectionContrast;
var Reader: TfrmBuiltinReader; Before, After: TBitmap; Theme: Integer; Prefix: string; GDI, RedrawGDI, UserBaseline, WarmUserPeak: Cardinal; FormsBaseline: Integer;
begin
  GDI:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS);
  Reader:=TfrmBuiltinReader.Create(nil); Before:=TBitmap.Create; After:=TBitmap.Create;
  try
    Reader.Show; Reader.OpenBook('search.pdf','Selection contrast','selection-contrast','selection-contrast.ini','pdfium.dll'); WaitReady(Reader);
    for Theme in [0,4] do
    begin
      Reader.SetTheme(Theme); WaitPage(Reader);
      Prefix:='selection-contrast-'+IntToStr(Theme);
      Reader.SetSelectionEnabled(False); Reader.SetSelectionEnabled(True);
      Before.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
      Reader.ReadingSurface.PaintTo(Before.Canvas.Handle,0,0); Before.SaveToFile(Prefix+'-before.bmp');
      Reader.SelectPDFText(0,28);
      Require(Reader.PDFSelectedText='Needle needle NEEDLE needled','PDF selected quote changed');
      After.SetSize(Before.Width,Before.Height);
      Reader.ReadingSurface.PaintTo(After.Canvas.Handle,0,0); After.SaveToFile(Prefix+'-after.bmp');
      RedrawGDI:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS);
      for var I:=1 to 80 do
      begin
        Reader.SelectPDFText(0,28); Reader.ReadingSurface.PaintTo(After.Canvas.Handle,0,0);
        Require(Reader.PDFSelectedText='Needle needle NEEDLE needled','Repeated selection corrupted PDF text');
      end;
      Writeln('PROFILE selection theme=',Theme,' GDI before=',RedrawGDI,' after=',GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS));
      Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=RedrawGDI,'PDF repeated selection redraws leaked drawing objects');
    end;
    Reader.Close;
  finally After.Free; Before.Free; Reader.Free; end;
  DrainReaderCleanup;
  Writeln('PROFILE selection closed GDI before=',GDI,' after=',GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS));
  GdiFlush;
  // VCL retains process-wide fonts on first use. Compare subsequent complete
  // reader lifecycles after that initialization, as well as every redraw loop.
  GDI:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS);
  UserBaseline:=GetGuiResources(GetCurrentProcess,GR_USEROBJECTS); WarmUserPeak:=UserBaseline; FormsBaseline:=Screen.FormCount; LogReaderWindows;
  for var Round:=1 to 384 do
  begin
    Reader:=TfrmBuiltinReader.Create(nil); After:=TBitmap.Create;
    try
      Reader.Show; Reader.OpenBook('search.pdf','Selection contrast','selection-contrast','selection-contrast.ini','pdfium.dll'); WaitReady(Reader);
      for Theme in [0,4] do
      begin
        Reader.SetTheme(Theme); WaitPage(Reader);
        After.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
        Reader.SelectPDFText(0,28); Reader.ReadingSurface.PaintTo(After.Canvas.Handle,0,0);
        Require(Reader.PDFSelectedText='Needle needle NEEDLE needled','Reopened PDF selection lost quote');
      end;
      Reader.Close;
    finally After.Free; Reader.Free; end;
    Application.ProcessMessages;
    if Round<=288 then WarmUserPeak:=Max(WarmUserPeak,GetGuiResources(GetCurrentProcess,GR_USEROBJECTS));
    if Round=288 then
    begin
      DrainReaderCleanup;
      Require(GetGuiResources(GetCurrentProcess,GR_USEROBJECTS)<=UserBaseline+64,'PDF reader window warm-up exceeded bounded cache budget');
      GDI:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS);
      // IME/message-window cache release can lower an instantaneous sample.
      // Use the maximum CLOSED-reader sample during warm-up as the bound;
      // the following 96 complete opens must not grow beyond that +2 budget.
      UserBaseline:=WarmUserPeak; LogReaderWindows;
      Writeln('PROFILE selection warm USER high-water=',UserBaseline);
    end;
    Require(Screen.FormCount=FormsBaseline,'PDF reader left an orphan form');
    if (Round mod 16)=0 then
      Writeln('PROFILE selection lifecycle=',Round,' GDI=',GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS),' USER=',GetGuiResources(GetCurrentProcess,GR_USEROBJECTS));
  end;
  DrainReaderCleanup;
  Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=GDI+2,'PDF selection reader lifecycle leaked drawing objects');
  LogReaderWindows;
  Require(GetGuiResources(GetCurrentProcess,GR_USEROBJECTS)<=UserBaseline+2,'PDF selection reader lifecycle leaked windows');
  Writeln('PASS PDF selection contrast images, exact quote and repeated light/dark redraw resource cleanup');
end;

procedure AuditContentsAndProgress;
var Reader: TfrmBuiltinReader; Key: Word; XML: string; Before: Cardinal;
begin
  XML:='<FictionBook><body><title><p>Книга</p></title><section><title><p>Самолёт и лесной сурок</p></title>'+
    '<p>'+StringOfChar('А',6000)+'</p><section><title><p>Барби</p></title><p>Подраздел</p></section></section>'+
    '<section><title><p>2. Уже с номером</p></title><p>Конец книги.</p></section></body></FictionBook>';
  TFile.WriteAllText('contents-progress.fb2',XML,TEncoding.UTF8);
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('contents-progress.fb2','Contents','contents','contents.ini','pdfium.dll'); WaitReady(Reader);
    Require(Reader.ChapterTitle(0)='Книга','Book title acquired a chapter number');
    Require(Reader.ChapterTitle(1)='Самолёт и лесной сурок','Mixed author numbering acquired artificial conflicting ordinals');
    Require(Reader.ChapterTitle(2).Contains('Самолёт и лесной сурок › 1. Барби'),'Nested chapter loses its parent or number');
    Require(Reader.ChapterTitle(3)='2. Уже с номером','Existing chapter number was duplicated');
    Reader.SetNumberChapters(False); Require(Reader.ChapterTitle(2).Contains(' › Барби'),'Disabling generated numbers changed author title');
    Reader.SetNumberChapters(True);
    Require(Reader.ReadingProgress=0,'Progress starts after the beginning of the book');
    Before:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS);
    TThread.ForceQueue(nil,
      procedure
      var Popup: TForm; C: TComponent; Outline: TTreeView; Search: TEdit;
      begin
        Popup:=Screen.ActiveForm; Outline:=nil; Search:=nil;
        Require((Popup.Caption='Оглавление') and (Popup.BorderStyle=bsSizeable),'Contents is not a resizable dialog');
        for C in Popup do
        begin if C is TTreeView then Outline:=TTreeView(C); if C is TEdit then Search:=TEdit(C); end;
        Require(Assigned(Outline) and Assigned(Search) and (Outline.Items.Count=4),'Contents tree or search is missing');
        Require((Outline.Items[2].Parent=Outline.Items[1]) and (Outline.Items[1].Parent=Outline.Items[0]),'Contents chapters lost their real hierarchy');
        for var N in Outline.Items do Require(not string(N.Text).Contains(' › '),'Contents repeats the complete parent path on each row');
        for var DPI in TArray<Integer>.Create(96,120,144,192) do
        begin
          Popup.ScaleForPPI(DPI); Popup.ClientWidth:=MulDiv(520,DPI,96); Popup.ClientHeight:=MulDiv(540,DPI,96);
          for var Control in Popup do if Control is TButton then
          begin
            var B:=TButton(Control);
            Require((B.Left>=0) and (B.Top>=0) and (B.Left+B.Width<=B.Parent.ClientWidth) and
              (B.Top+B.Height<=B.Parent.ClientHeight),'Contents button is cropped at '+IntToStr(DPI)+' DPI');
          end;
          var Height:=Outline.Height; Popup.ClientHeight:=Popup.ClientHeight+MulDiv(100,DPI,96);
          Require(Outline.Height>Height,'Contents window growth did not enlarge its chapter tree');
        end;
        Search.Text:='барби'; Require((Outline.Items.Count=3) and Assigned(Outline.Selected) and string(Outline.Selected.Text).Contains('Барби'),'Contents search lost its chapter or parent context');
        Require(Outline.Selected.Parent.Expanded,'Search leaves the matching chapter collapsed');
        Popup.ModalResult:=mrOk;
      end);
    Key:=Ord('T'); Reader.OnKeyDown(Reader,Key,[ssCtrl]);
    Require(Reader.PageText.Contains('Барби') and (Reader.TextPosition>0),'Contents selection did not navigate to the chapter');
    var Selector:=ChapterSelector(Reader);
    Require(Assigned(Selector),'Chapter header is missing');
    Require(Selector.Hint=Reader.ChapterTitle(Selector.ItemIndex),'Compact chapter header lost full parent context');
    for var OpenMessage in TArray<Integer>.Create(CB_SHOWDROPDOWN,WM_LBUTTONDOWN,WM_KEYDOWN) do
    begin
      TThread.ForceQueue(nil,
        procedure
        var Popup: TForm; Tree: TTreeView;
        begin
          Popup:=Screen.ActiveForm; Tree:=nil;
          for var C in Popup do if C is TTreeView then Tree:=TTreeView(C);
          Require((Popup.Caption='Оглавление') and Assigned(Tree),'Chapter header still opens a flat native list');
          Require((Tree.Items.Count=4) and Assigned(Tree.Selected) and (NativeInt(Tree.Selected.Data)=Selector.ItemIndex),'Header tree lost current chapter');
          Popup.ModalResult:=mrCancel;
        end);
      if OpenMessage=WM_KEYDOWN then Selector.Perform(OpenMessage,VK_F4,0)
      else Selector.Perform(OpenMessage,1,0);
      Require(not Selector.DroppedDown,'A native flat dropdown appeared after the tree closed');
    end;
    Writeln('PASS chapter header mouse arrow and F4 open the same hierarchy with current branch and full context');
    Require(Reader.ReadingProgress>0,'Progress did not follow chapter navigation');
    Reader.GoToPosition(Reader.TextLength-1); Require(Reader.ReadingProgress=1,'Final page does not complete progress');
    Reader.GoToPosition(0); Require(Reader.ReadingProgress=0,'Returning to the beginning leaves stale progress');
    Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=Before+12,'Contents/progress leaks drawing resources');
    Writeln('PASS spacious resizable contents, chapter ordinals and hierarchy, Cyrillic search, accurate navigation and lightweight progress');
  finally Reader.Free; end;
end;

  function NoteDialogButton(Form: TForm; const Caption: string): TButton;
  begin
    Result:=nil;
    for var C in Form do if (C is TButton) and (TButton(C).Caption=Caption) then Exit(TButton(C));
    Require(False,'Note dialog button missing: '+Caption);
  end;
  procedure CheckNoteDialogButtons(Form: TForm; Width,Height: Integer);
  begin
    for var DPI in TArray<Integer>.Create(96,120,144,192) do
    begin
      Form.ScaleForPPI(DPI); Form.ClientWidth:=MulDiv(Width,DPI,96); Form.ClientHeight:=MulDiv(Height,DPI,96);
      Application.ProcessMessages;
      for var C in Form do if C is TButton then
      begin
        var B:=TButton(C);
        Require((B.Left>=0) and (B.Top>=0) and (B.Left+B.Width<=B.Parent.ClientWidth) and
          (B.Top+B.Height<=B.Parent.ClientHeight),'Note/export dialog button clipped at '+IntToStr(DPI));
      end;
    end;
    Form.ScaleForPPI(96); Form.ClientWidth:=Width; Form.ClientHeight:=Height;
  end;
  procedure FillNoteDialogEditor(Parent: TCustomForm; Editing, Quote: Boolean);
  begin
    var Editor:=Screen.ActiveForm; var TextBox: TMemo:=nil; var TitleBox: TEdit:=nil; var Quoted:=False;
    Require((Editor.Caption='Заметка к книге') and (Editor.PopupParent=Parent),'Note editor has incorrect nested window ownership');
    for var C in Editor do
    begin
      if (C is TMemo) and not TMemo(C).ReadOnly then TextBox:=TMemo(C);
      if (C is TEdit) and not (C is TMemo) then TitleBox:=TEdit(C);
      if (C is TMemo) and TMemo(C).ReadOnly and TMemo(C).Visible then Quoted:=string(TMemo(C).Text).Contains('Needle');
    end;
    Require(Assigned(TextBox) and Assigned(TitleBox),'Note input fields missing');
    Require(Quoted=Quote,'Selected PDF quote was not attached to note');
    if Editing then Require((TitleBox.Text='Моя мысль — ё') and string(TextBox.Text).Contains('Вторая строка'),'Reopening note lost input');
    CheckNoteDialogButtons(Editor,610,440);
    var Save:=NoteDialogButton(Editor,'Сохранить');
    Require(Save.Parent.Top+Save.Parent.Height=Editor.ClientHeight,'Save row is above note/quote text');
    if Editing then begin TitleBox.Text:='Новая мысль'; TextBox.Text:=TextBox.Text+sLineBreak+'Изменено'; end
    else begin TitleBox.Text:='Моя мысль — ё'; TextBox.Text:='Первая строка'+sLineBreak+'Вторая строка'; end;
    Editor.ModalResult:=mrOk;
  end;
procedure AuditDirectDOC;
var Source, Hash, Prepared, Cached, Expected, Actual, Stage: string;
  Watch: TStopwatch; Reader: TfrmBuiltinReader; Document: TReaderDocument;
  Worker: TThread; Done: TEvent; ErrorText: string; LongestDispatch: Int64;
  function Compact(const Text: string): string;
  var Builder: TStringBuilder; Ch: Char;
  begin
    Builder:=TStringBuilder.Create;
    try
      for Ch in Text do if not TCharacter.IsWhiteSpace(Ch) and (Ord(Ch)>=32) then Builder.Append(Ch);
      Result:=Builder.ToString;
    finally Builder.Free; end;
  end;
begin
  Require(FindDirectDOCReader<>'','Bundled DOC helper is unavailable');
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  Source:='doc-fixture.doc'; Hash:=THashSHA2.GetHashStringFromFile(Source);
  Done:=TEvent.Create(nil,True,False,''); Prepared:=''; ErrorText:=''; LongestDispatch:=0;
  Worker:=TThread.CreateAnonymousThread(
    procedure
    begin
      try
        try Prepared:=PrepareOfficeReaderFile(Source,Source);
        except on E: Exception do ErrorText:=E.Message; end;
      finally Done.SetEvent; end;
    end);
  Worker.FreeOnTerminate:=False;
  try
    Watch:=TStopwatch.StartNew; Worker.Start;
    while Done.WaitFor(0)<>wrSignaled do
    begin
      var Tick:=TStopwatch.StartNew; Application.ProcessMessages; CheckSynchronize(1);
      LongestDispatch:=Max(LongestDispatch,Tick.ElapsedMilliseconds);
      if Watch.ElapsedMilliseconds>35000 then begin Worker.Terminate; raise Exception.Create('DOC preparation did not finish'); end;
    end;
    Worker.WaitFor; Require(ErrorText='','Direct DOC conversion failed: '+ErrorText);
    Require(FileExists(Prepared) and SameText(ExtractFileExt(Prepared),'.docx'),'DOC did not use the reflow reader');
    Writeln('PROFILE direct DOC first_prepare_ms=',Watch.ElapsedMilliseconds,' max_ui_dispatch_ms=',LongestDispatch); Flush(Output);
    Require(LongestDispatch<150,'DOC helper freezes main UI');
  finally Worker.Terminate; Worker.WaitFor; Worker.Free; Done.Free; end;
  Stage:=''; Watch:=TStopwatch.StartNew;
  Cached:=PrepareOfficeReaderFile(Source,Source,procedure(Value: string) begin Stage:=Value; end);
  Require((Cached=Prepared) and Stage.Contains('из кэша'),'Repeated DOC preparation did not use the cache');
  Require(Watch.ElapsedMilliseconds<500,'Cached DOC repeats conversion');
  Writeln('PROFILE direct DOC cached_prepare_ms=',Watch.ElapsedMilliseconds);
  Expected:=Compact(TFile.ReadAllText('doc-expected.txt',TEncoding.UTF8));
  Document:=TReaderDocument.Create;
  try
    Document.Load(Prepared); Actual:=Compact(Document.PlainText);
    Require(Actual=Expected,'DOC conversion changed body text compared with independent reference');
  finally Document.Free; end;
  Document:=TReaderDocument.Create;
  try
    Document.Load(PrepareOfficeReaderFile('styled-fixture.doc','styled-fixture.doc'));
    Require((Length(Document.Chapters)=2) and (Document.Chapters[0].Title='Глава первая — Ёжик') and
      (Document.Chapters[1].Depth=1),'DOC heading hierarchy was lost');
    Require((Document.ImageCount=1) and (Document.SkippedImages=0),'DOC picture was lost: '+Document.Warnings.Text);
    Require(Document.PlainText.Contains('Беларуская мова, Русский текст, English.') and
      Document.PlainText.Contains('Текст после картинки — конец.'),'DOC text around image or Unicode was lost');
    Require(string(Document.RTF).Contains('\b ') and string(Document.RTF).Contains('\i '),'DOC emphasis was lost');
  finally Document.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Watch:=TStopwatch.StartNew;
    Reader.OpenBook(Prepared,'Палыновы вецер','direct-doc','direct-doc.ini','pdfium.dll'); WaitReady(Reader);
    Require(Compact(Reader.BookText)=Expected,'Native DOC reading lost Unicode text');
    Writeln('PROFILE direct DOC reader_open_ms=',Watch.ElapsedMilliseconds);
    for var I:=1 to 20 do
    begin
      var Position:=Reader.TextPosition; Reader.NextPage;
      Require(Reader.Visible and Reader.Ready and (Reader.TextPosition>Position),'DOC paging failed or hid reader');
    end;
    Reader.SetTheme(4); Reader.SetTheme(0); Reader.FindText('ПАЛЫНОВЫ');
    Require(Reader.MatchPosition>=0,'DOC Unicode search failed');
    Require(Compact(Reader.BookText)=Expected,'DOC navigation/theme changed source text');
    Reader.Close;
  finally Reader.Free; end;
  try
    PrepareDirectDOC(Source,Source,nil,function: Boolean begin Result:=True; end);
    raise Exception.Create('Canceled DOC preparation succeeded');
  except on E: EAbort do ; end;
  TFile.WriteAllText('bad-doc.doc',StringOfChar('X',1024),TEncoding.UTF8);
  try
    PrepareDirectDOC('bad-doc.doc','bad-doc.doc');
    raise Exception.Create('Broken DOC preparation succeeded');
  except on E: Exception do Require(E.Message.Contains('Не удалось прочитать DOC'),'Broken DOC did not produce a useful message: '+E.Message); end;
  Require(Hash=THashSHA2.GetHashStringFromFile(Source),'DOC original was changed');
  Writeln('PASS bundled DOC reads exact Unicode body without Office, caches, searches, pages, cancels and preserves originals');
end;

procedure AuditRealTextSelection;
var Reader: TfrmBuiltinReader; Painted: TBitmap; Surface: TWinControl;
  FileName, BeforeHash, Text, Query: string; Left, Right, Top, Bottom, X,Y, Start, Finish: Integer; Key: Word;
begin
  for FileName in ['selection-real.fb2','selection-real.epub','selection-real.txt','selection-unicode.txt'] do
  begin
    BeforeHash:=THashSHA2.GetHashStringFromFile(FileName);
    Reader:=TfrmBuiltinReader.Create(nil); Painted:=TBitmap.Create;
    try
      Reader.Show; Reader.OpenBook(FileName,FileName,FileName,'selection-real.ini','pdfium.dll'); WaitReady(Reader);
      Require(Reader.SelectionEnabled,'Text selection is disabled by default: '+FileName);
      Reader.SetTypography('Georgia',110,32); Reader.SetMaxTextWidth(960);
      Text:=Reader.BookText;
      if FileName='selection-unicode.txt' then Query:='😀'
      else
      begin
        Start:=Min(1000,Length(Text)); Query:='';
        while Start<Length(Text) do
        begin
          while (Start<Length(Text)) and not TCharacter.IsLetter(Text[Start]) do Inc(Start);
          Finish:=Start; while (Finish<=Length(Text)) and TCharacter.IsLetter(Text[Finish]) do Inc(Finish);
          if Finish-Start>=6 then begin Query:=Copy(Text,Start,Finish-Start); Break; end;
          Start:=Finish+1;
        end;
      end;
      Require(Query<>'','No bounded readable word in fixture: '+FileName);
      for var Theme in [1,4] do
      begin
        Reader.SetTheme(Theme); Reader.SetHighlightColor(clLime); Reader.SetSearchOptions(True,False,False); Reader.FindText(Query);
        Require(Reader.MatchPosition>=0,'Selection query is absent: '+FileName);
        Surface:=Reader.ReadingSurface; Painted.SetSize(Surface.Width,Surface.Height);
        Surface.PaintTo(Painted.Canvas.Handle,0,0);
        Left:=Surface.Width; Right:=-1; Top:=Surface.Height; Bottom:=-1;
        for Y:=0 to Surface.Height-1 do for X:=0 to Surface.Width-1 do
          if ColorToRGB(Painted.Canvas.Pixels[X,Y])=ColorToRGB(clLime) then
          begin Left:=Min(Left,X); Right:=Max(Right,X); Top:=Min(Top,Y); Bottom:=Max(Bottom,Y); end;
        Require((Right>Left) and (Bottom>Top),'Search marker is absent from displayed page: '+FileName);
        SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(Left-1,(Top+Bottom) div 2));
        SendMessage(Surface.Handle,WM_MOUSEMOVE,MK_LBUTTON,MakeLParam(Right+1,(Top+Bottom) div 2));
        SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(Right+1,(Top+Bottom) div 2));
        Require(Reader.SelectedText=Query,'Visible quote differs from mouse selection: '+FileName+' expected=['+Query+'] got=['+Reader.SelectedText+']');
        Key:=Ord('C'); Reader.OnKeyDown(Reader,Key,[ssCtrl]);
        Require(ReadClipboardText=Query,'Copy changed selected Unicode: '+FileName);
        Require(Reader.BookText=Text,'Selection or theme changed original text: '+FileName);
        Reader.NextPage; Require(Reader.SelectedText='','Selection leaked to next page: '+FileName);
      end;
      Reader.Close;
    finally Painted.Free; Reader.Free; end;
    Require(BeforeHash=THashSHA2.GetHashStringFromFile(FileName),'Selection changed source file: '+FileName);
  end;
  Writeln('PASS real FB2 EPUB TXT and emoji quotes match visible mouse selection in both themes and copy exact Unicode');
end;

procedure AuditSelectionGeometry;
var Host: TForm; Source: TRichEdit; Hit: TReaderPageSelection; Stream: TStringStream;
  Bitmap: Vcl.Graphics.TBitmap; Range: TFormatRange; Selection: TCharRange; Style: TCharFormat2;
  Text: string; Start, Finish, Mark, DPI, X,Y, Left, Top, Right, Bottom, Index: Integer;
  Bounds: TRect;
begin
  Host:=TForm.CreateNew(nil); Source:=TRichEdit.Create(Host); Hit:=nil; Bitmap:=Vcl.Graphics.TBitmap.Create;
  try
    Source.Parent:=Host; Source.Visible:=False; Source.StyleElements:=[];
    Text:='{\rtf1\ansi\deff0{\fonttbl{\f0 Georgia;}}\pard\qj\fi600\f0\fs28 ';
    for var WordIndex:=0 to 499 do Text:=Text+Format('word%.4d ',[WordIndex]);
    Text:=Text+'\par}'; Stream:=TStringStream.Create(Text,TEncoding.ASCII);
    try ReaderLoadRTF(Source,Stream); finally Stream.Free; end;
    Hit:=TReaderPageSelection.Create(Host,Host); Start:=0;
    for var PageIndex:=0 to 2 do
    begin
      Bitmap.SetSize(720,260); Bitmap.PixelFormat:=pf32bit;
      DPI:=GetDeviceCaps(Bitmap.Canvas.Handle,LOGPIXELSY); Bounds:=Rect(32,20,688,240);
      FillChar(Style,SizeOf(Style),0); Style.cbSize:=SizeOf(Style);
      Style.dwMask:=CFM_COLOR; Style.dwEffects:=CFE_AUTOCOLOR;
      SendMessage(Source.Handle,EM_SETCHARFORMAT,SCF_ALL,LPARAM(@Style));
      FillChar(Range,SizeOf(Range),0); Range.hdc:=Bitmap.Canvas.Handle; Range.hdcTarget:=Range.hdc;
      Range.rcPage:=Rect(0,0,MulDiv(Bitmap.Width,1440,DPI),MulDiv(Bitmap.Height,1440,DPI));
      Range.rc:=Rect(MulDiv(Bounds.Left,1440,DPI),MulDiv(Bounds.Top,1440,DPI),
        MulDiv(Bounds.Right,1440,DPI),MulDiv(Bounds.Bottom,1440,DPI));
      Range.chrg.cpMin:=Start; Range.chrg.cpMax:=-1;
      Bitmap.Canvas.Lock;
      try
        Range.hdc:=Bitmap.Canvas.Handle; Range.hdcTarget:=Range.hdc;
        Finish:=SendMessage(Source.Handle,EM_FORMATRANGE,0,LPARAM(@Range));
        SendMessage(Source.Handle,EM_FORMATRANGE,0,0);
      finally Bitmap.Canvas.Unlock; end;
      Require(Finish>Start+100,'Selection geometry fixture has too little visible text');
      // Native renderer provides an independent marker for a visible character,
      // including the first continued line and the last justified line.
      for var ProbeIndex:=0 to 1 do
      begin
        if ProbeIndex=0 then Mark:=Start+6 else Mark:=Finish-12;
        if ReaderTextRange(Source,Mark,1)=' ' then Inc(Mark);
        Selection.cpMin:=Mark; Selection.cpMax:=Mark+1;
        SendMessage(Source.Handle,EM_EXSETSEL,0,LPARAM(@Selection));
        Style.dwEffects:=0; Style.crTextColor:=RGB(0,255,0);
        SendMessage(Source.Handle,EM_SETCHARFORMAT,SCF_SELECTION,LPARAM(@Style));
        Bitmap.Canvas.Brush.Color:=clWhite; Bitmap.Canvas.FillRect(Rect(0,0,720,260));
        Range.chrg.cpMin:=Start; Range.chrg.cpMax:=Finish;
        Bitmap.Canvas.Lock;
        try
          Range.hdc:=Bitmap.Canvas.Handle; Range.hdcTarget:=Range.hdc;
          Range.rc:=Rect(MulDiv(Bounds.Left,1440,DPI),MulDiv(Bounds.Top,1440,DPI),
            MulDiv(Bounds.Right,1440,DPI),MulDiv(Bounds.Bottom,1440,DPI));
          SendMessage(Source.Handle,EM_FORMATRANGE,1,LPARAM(@Range)); SendMessage(Source.Handle,EM_FORMATRANGE,0,0);
        finally Bitmap.Canvas.Unlock; end;
        Left:=720; Right:=-1; Top:=260; Bottom:=-1;
        for Y:=Bounds.Top to Bounds.Bottom-1 do for X:=Bounds.Left to Bounds.Right-1 do
          if ColorToRGB(Bitmap.Canvas.Pixels[X,Y])=RGB(0,255,0) then
          begin Left:=Min(Left,X); Right:=Max(Right,X); Top:=Min(Top,Y); Bottom:=Max(Bottom,Y); end;
        Bitmap.SaveToFile(Format('selection-geometry-%d-%d.bmp',[PageIndex,ProbeIndex]));
        Require((Right>Left) and (Bottom>Top),'Native marker was not painted');
        Hit.Prepare(Source,Start,Finish-Start,720,260,DPI,Bounds);
        Index:=Hit.CharacterAt((Left+Right) div 2,(Top+Bottom) div 2);
        Writeln('TRACE selection geometry page=',PageIndex,' probe=',ProbeIndex,' start=',Start,
          ' mark=',Mark,' hit=',Index,' native=',Left,',',Top,'..',Right,',',Bottom);
        Bitmap.SaveToFile(Format('selection-geometry-%d-%d.bmp',[PageIndex,ProbeIndex]));
        Require((Index=Mark) or (Index=Mark+1),'Mouse hit test disagrees with the visible native character');
        Style.dwEffects:=CFE_AUTOCOLOR;
        SendMessage(Source.Handle,EM_SETCHARFORMAT,SCF_SELECTION,LPARAM(@Style));
      end;
      Start:=Finish; Hit.Clear;
    end;
  finally Hit.Free; Bitmap.Free; Host.Free; end;
  Writeln('PASS text selection matches visible continued and justified native page lines');
end;

procedure AuditFailedReaderCleanup;
var Reader: TfrmBuiltinReader; Watch: TStopwatch;
begin
  TFile.WriteAllText('failed-reader.fb2','<FictionBook><body><p>broken',TEncoding.UTF8);
  for var Attempt:=1 to 8 do
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook('failed-reader.fb2','Failed input','failed-reader','failed-reader.ini','pdfium.dll');
      Watch:=TStopwatch.StartNew;
      while not Reader.LoadFinished and (Watch.ElapsedMilliseconds<5000) do
      begin Application.ProcessMessages; CheckSynchronize(1); end;
      Require(Reader.LoadFinished and not Reader.Ready,'Malformed book has no controlled failure');
      Reader.Close;
    finally Reader.Free; end;
    Application.ProcessMessages; CheckSynchronize(1);
  end;
  Writeln('PASS failed reader loads close cleanly and do not leave callbacks to freed forms');
end;

procedure AuditDirectTextSelection;
var Reader: TfrmBuiltinReader; Surface: TWinControl; Key: Word; Fixture: string; I: Integer;
begin
  Fixture:='<FictionBook><body><section><title><p>Заголовок</p></title><p>Цитата для заметки. Следующее предложение.</p>';
  for I:=1 to 30 do Fixture:=Fixture+'<p>Вторая строка текста. '+StringOfChar('Т',200)+'</p>';
  TFile.WriteAllText('direct-selection.fb2',Fixture+'</section></body></FictionBook>',TEncoding.UTF8);
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('direct-selection.fb2','Выделение','direct-selection','direct-selection.ini','pdfium.dll'); WaitReady(Reader);
    Surface:=Reader.ReadingSurface;
    // Select a visible line by real mouse messages, then use the normal copy command.
    var Painted:=TBitmap.Create;
    try
      Painted.SetSize(Surface.Width,Surface.Height); Surface.PaintTo(Painted.Canvas.Handle,0,0); Painted.SaveToFile('direct-selection-before.bmp');
    finally Painted.Free; end;
    SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(56,170));
    SendMessage(Surface.Handle,WM_MOUSEMOVE,MK_LBUTTON,MakeLParam(244,170));
    SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(244,170));
    Require(Reader.SelectedText<>'','Direct FB2 mouse selection is empty');
    Require(Reader.SelectedText.StartsWith('Цитата для заметки.'),'Mouse selected a different visible line: '+Reader.SelectedText);
    Key:=Ord('C'); Reader.OnKeyDown(Reader,Key,[ssCtrl]);
    Require(ReadClipboardText=Reader.SelectedText,'Ctrl+C copied page instead of selected FB2 quote');
    Require(Reader.SelectedText.Length<Reader.PageText.Length,'Direct selection copied whole page');
    Reader.NextPage; Require(Reader.SelectedText='','Text selection leaked into another page');
    Reader.Close;
  finally Reader.Free; end;
  Writeln('PASS direct FB2 mouse selection copies chosen text and clears on page changes');
end;

procedure AuditFeedbackPDF;
var PDF: TReaderPDF; Bitmap: TBitmap; Color: TColor; Count, I: Integer;
  Reader: TfrmBuiltinReader; Surface: TWinControl; Size, Pan: TPoint; Watch: TStopwatch; X,Y: Integer; Step: string;
begin
  PDF:=TReaderPDF.Create('pdfium.dll','sample.pdf');
  try
    Bitmap:=PDF.Render(1,640,800);
    try Color:=Bitmap.Canvas.Pixels[100,150]; Bitmap.Canvas.Pixels[100,150]:=clRed;
    finally Bitmap.Free; end;
    Count:=PDF.NativeRenderCount;
    for I:=1 to 12 do
    begin
      Bitmap:=PDF.Render(1,640,800);
      try Require(Bitmap.Canvas.Pixels[100,150]=Color,'PDF cache was modified by displayed bitmap');
      finally Bitmap.Free; end;
    end;
    Require(PDF.NativeRenderCount=Count,'Same PDF page was decoded on every redraw');
    Bitmap:=PDF.Render(1,640,800,True);
    try Require(ColorToRGB(Bitmap.Canvas.Pixels[20,20])=$00222222,'PDF cache confused light and dark rasters');
    finally Bitmap.Free; end;
    if FileExists('feedback-sky.pdf') then
    begin
      PDF.Free; PDF:=nil; PDF:=TReaderPDF.Create('pdfium.dll','feedback-sky.pdf');
      Bitmap:=PDF.Render(21,746,1100); Bitmap.Free; Count:=PDF.NativeRenderCount;
      Watch:=TStopwatch.StartNew;
      for I:=1 to 12 do begin Bitmap:=PDF.Render(21,746,1100); Bitmap.Free; end;
      Require(PDF.NativeRenderCount=Count,'Actual scanned PDF raster was not reused');
      Require(Watch.ElapsedMilliseconds<1000,'Cached scanned PDF still blocks repeated page display');
      Writeln('PROFILE real scanned PDF 12 cached redraws_ms=',Watch.ElapsedMilliseconds);
    end;
  finally PDF.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    try
    Step:='open scan';
    Reader.Show; Reader.OpenBook('sample.pdf','Удержание масштаба','hold-feedback','hold-feedback.ini','pdfium.dll'); WaitReady(Reader);
    Require(Reader.InspectionHold and Reader.SelectionEnabled,'New reader preferences are not enabled by default');
    Surface:=Reader.ReadingSurface; Size:=Reader.PageRasterSize; Pan:=Reader.PDFPan;
    X:=Pan.X+Size.X div 2; Y:=Pan.Y+Size.Y div 2;
    Step:='press scan';
    SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(X,Y));
    Require(Reader.Inspecting,'Holding mouse did not zoom scanned page: '+Reader.ReaderStatus.Caption);
    Step:='release outside';
    SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(Surface.ClientWidth+20,Surface.ClientHeight+20));
    Require(not Reader.Inspecting and (Reader.PageRasterSize=Size) and (Reader.PDFPan=Pan),'Release outside reader did not restore exact view');
    Step:='press before losing capture';
    SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(X,Y));
    Step:='lose capture';
    SendMessage(Surface.Handle,WM_CAPTURECHANGED,0,0);
    Require(not Reader.Inspecting,'Lost mouse capture left held zoom active');
    Step:='two-click inspection';
    Reader.SetInspectionHold(False);
    SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(X,Y));
    SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(X,Y));
    Require(Reader.Inspecting,'Optional two-click zoom ended on release');
    SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(X,Y));
    SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(X,Y));
    Require(not Reader.Inspecting,'Optional second click did not restore view'); Reader.Close;
    except on E: Exception do raise Exception.Create(Step+': '+E.ClassName+': '+E.Message); end;
  finally Reader.Free; end;
  Writeln('PASS PDF raster cache isolation, theme keys, hold/release, lost capture and two-click inspection');
end;

procedure AuditAsyncPDF;
var Reader: TfrmBuiltinReader; Watch, Pump: TStopwatch; Maximum, OpenMS, JumpMS, I: Int64;
  procedure FinishPage;
  var Started: TStopwatch;
  begin
    Started:=TStopwatch.StartNew;
    repeat
      Pump:=TStopwatch.StartNew; Application.ProcessMessages;
      Maximum:=Max(Maximum,Pump.ElapsedMilliseconds); CheckSynchronize(2);
      Require(Started.ElapsedMilliseconds<15000,'Asynchronous PDF page never completed');
    until Reader.LoadFinished and not Reader.PageLoading;
    Require(not string(Reader.ReaderStatus.Caption).Contains('Не удалось'),'PDF page error: '+Reader.ReaderStatus.Caption);
    Require(Reader.Visible,'Reader disappeared during page preparation');
  end;
begin
  if not FileExists('feedback-sky.pdf') then Exit;
  Reader:=TfrmBuiltinReader.Create(nil); Maximum:=0;
  try
    Reader.Show; Watch:=TStopwatch.StartNew;
    Reader.OpenBook('feedback-sky.pdf','Фоновый PDF','async-pdf','async-pdf.ini','pdfium.dll');
    OpenMS:=Watch.ElapsedMilliseconds;
    Require(Reader.PageLoading,'Actual scanned PDF still renders synchronously');
    FinishPage; Require(Reader.PageRasterSize.X>0,'Initial PDF page is empty');
    Watch:=TStopwatch.StartNew; Reader.GoToPosition(21); JumpMS:=Watch.ElapsedMilliseconds;
    Require(JumpMS<150,'Requesting an uncached PDF page blocks the UI'); FinishPage;
    Require(Reader.TextPosition=21,'Random PDF jump opened the wrong page');
    // Keep only the latest requested destination while a previous decode finishes.
    for I:=2 to 17 do Reader.GoToPosition(I);
    FinishPage; Require(Reader.TextPosition=17,'Rapid PDF navigation lost the final destination');
    Reader.SetTheme(4); FinishPage;
    Reader.SetTheme(0); FinishPage;
    Require(Maximum<150,'PDF decoding still blocks message processing: '+IntToStr(Maximum));
    Reader.GoToPosition(24); Watch:=TStopwatch.StartNew; Reader.Close; FreeAndNil(Reader);
    Require(Watch.ElapsedMilliseconds<1000,'Closing during PDF decoding did not cancel promptly');
    Writeln('PROFILE async scanned PDF open_request_ms=',OpenMS,' jump_request_ms=',JumpMS,' max_ui_dispatch_ms=',Maximum);
  finally Reader.Free; end;
  Writeln('PASS async PDF responsive UI, uncached jumps, final destination, themes and cancellation');
end;

procedure AuditNoteDialogs;
var Reader: TfrmBuiltinReader; Store: TReaderAnnotations; Notes: TArray<TReaderAnnotation>;
  Ini: TMemIniFile;
begin
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('contents-progress.fb2','Заметки GUI','note-dialog','note-dialog.ini','pdfium.dll'); WaitReady(Reader);
    Reader.AddBookmark;
    TThread.ForceQueue(nil,
      procedure
      begin
        var Manager:=Screen.ActiveForm;
        Require(string(Manager.Caption).StartsWith('Закладки и заметки'),'Notes manager missing');
        CheckNoteDialogButtons(Manager,760,510);
        var Go:=NoteDialogButton(Manager,'Перейти'); Require(Go.Parent.Top+Go.Parent.Height=Manager.ClientHeight,'Manager actions are above note preview');
        TThread.ForceQueue(nil,procedure begin FillNoteDialogEditor(Manager,False,False); end);
        NoteDialogButton(Manager,'Добавить заметку…').OnClick(nil);
        TThread.ForceQueue(nil,procedure begin FillNoteDialogEditor(Manager,True,False); end);
        NoteDialogButton(Manager,'Изменить…').OnClick(nil);
        TThread.ForceQueue(nil,
          procedure
          var Formats,Styles: TComboBox; Tip: TLabel; R: TRect;
          begin
            var Exporter:=Screen.ActiveForm; Formats:=nil; Styles:=nil; Tip:=nil;
            Require((Exporter.Caption='Оформление экспорта') and (Exporter.PopupParent=Manager),'Export dialog has incorrect nested ownership');
            for var C in Exporter do
            begin
              if C is TComboBox then if TComboBox(C).Items.Count=3 then Formats:=TComboBox(C) else Styles:=TComboBox(C);
              if (C is TLabel) and TLabel(C).WordWrap then Tip:=TLabel(C);
            end;
            Require(Assigned(Formats) and Assigned(Styles) and Assigned(Tip),'Export fields or explanation missing');
            CheckNoteDialogButtons(Exporter,410,216);
            R:=Rect(0,0,Tip.Width,0); Exporter.Canvas.Font.Assign(Tip.Font);
            DrawText(Exporter.Canvas.Handle,PChar(Tip.Caption),Length(Tip.Caption),R,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
            Require((Tip.Width>=380) and (R.Height<=Tip.Height),'Export explanation was collapsed or clipped');
            Formats.ItemIndex:=2; Formats.OnChange(Formats); Require(not Styles.Enabled,'TXT incorrectly offers visual style');
            Formats.ItemIndex:=0; Formats.OnChange(Formats); Require(Styles.Enabled,'DOCX styles unavailable');
            Formats.ItemIndex:=1; Formats.OnChange(Formats); Require(Styles.Enabled and (Styles.Items.Count=4),'HTML styles unavailable');
            Exporter.ModalResult:=mrCancel;
          end);
        NoteDialogButton(Manager,'Экспорт заметок…').OnClick(NoteDialogButton(Manager,'Экспорт заметок…'));
        Manager.ModalResult:=mrCancel;
      end);
    NoteDialogButton(Reader,'Заметки').OnClick(nil); Reader.Close;
  finally Reader.Free; end;
  Store:=TReaderAnnotations.Create('note-dialog.ini');
  try Notes:=Store.Items; Require((Length(Notes)=1) and (Notes[0].Title='Новая мысль') and Notes[0].Text.Contains('Изменено'),'Note GUI edits did not persist'); finally Store.Free; end;
  Ini:=TMemIniFile.Create('note-dialog.ini',TEncoding.UTF8);
  try Require(Ini.ReadInteger('Bookmarks.'+Notes[0].BookID,'Count',0)=1,'Note GUI changed existing bookmark'); finally Ini.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('sample.pdf','PDF цитата','note-pdf','note-dialog.ini','pdfium.dll'); WaitReady(Reader);
    Reader.NextPage; WaitPage(Reader); Reader.SelectPDFText(0,6);
    TThread.ForceQueue(nil,procedure begin FillNoteDialogEditor(Reader,False,True); end);
    var Add: TMenuItem:=nil;
    for var I:=0 to TPaintBox(Reader.ReadingSurface).PopupMenu.Items.Count-1 do
      if TPaintBox(Reader.ReadingSurface).PopupMenu.Items[I].Caption='Добавить заметку…' then Add:=TPaintBox(Reader.ReadingSurface).PopupMenu.Items[I];
    Require(Assigned(Add),'Reader note context command missing'); Add.OnClick(Add); Reader.Close;
  finally Reader.Free; end;
  Store:=TReaderAnnotations.Create('note-dialog.ini');
  try
    Notes:=Store.Items; Require((Length(Notes)=2) and (Notes[1].Quote='Needle') and (Notes[0].BookID<>Notes[1].BookID),'PDF quote note overwrote another book');
  finally Store.Free; end;
  Writeln('PASS note dialog input, edit/reopen, selected PDF quote, bookmark preservation, nested ownership, bottom actions, unclipped export explanation, four styles and TXT disabling at 96-192 DPI');
end;

procedure AuditReaderNavigationAndNotes;
var Reader: TfrmBuiltinReader; Store, Stale: TReaderAnnotations; Note: TReaderAnnotation;
  ID, OtherID, Hash, Exported: string; Items: TArray<TReaderAnnotation>; Ini: TMemIniFile;
  Watch: TStopwatch; Bar: TPaintBox; C: TComponent; Starts: TList<Integer>; Zip: TZipFile; Bytes: TBytes;
begin
  ForceDirectories(ExpandFileName('notes-test')); TFile.WriteAllText('notes-test/profile.ini','[Unrelated]'+sLineBreak+'Value=Keep me',TEncoding.UTF8);
  Hash:=THashSHA2.GetHashStringFromFile('notes-test/profile.ini');
  Store:=TReaderAnnotations.Create('notes-test/profile.ini');
  try
    Note:=Default(TReaderAnnotation); Note.BookID:='one'; Note.BookTitle:='Книга <ёж> & café';
    Note.Title:='Мысль & заголовок'; Note.Text:='Первая строка'+sLineBreak+'Вторая строка 🌿';
    Note.Quote:='<script>alert(1)</script> цитата'; Note.Place:='Страница 12 · 42%'; Note.Position:=1200;
    ID:=Store.Put(Note); Note.BookID:='two'; Note.BookTitle:='Другой том'; Note.Position:=20; OtherID:=Store.Put(Note);
    Require(TFile.Exists('notes-test/reader-notes.json.bak'),'Previous notes revision was not backed up');
    Require(Length(Store.Items)=2,'Adding a different book erased another note');
  finally Store.Free; end;
  Store:=TReaderAnnotations.Create('notes-test/profile.ini'); Stale:=TReaderAnnotations.Create('notes-test/profile.ini');
  try
    Items:=Store.Items('one'); Require((Length(Items)=1) and (Items[0].ID=ID) and Items[0].Text.Contains('🌿'),'Unicode notes or book identity lost after reopen');
    Note:=Items[0]; Note.Text:=Note.Text+sLineBreak+'Изменено'; Store.Put(Note);
    var Rejected:=False; try Stale.Put(Note); except on E: Exception do Rejected:=E.Message.Contains('другом окне'); end;
    Require(Rejected,'Concurrent notes update overwrote newer revision');
    Require(THashSHA2.GetHashStringFromFile('notes-test/profile.ini')=Hash,'Notes altered reading settings or old bookmarks');
    for var Style:=0 to 3 do
    begin
      Exported:=ReaderAnnotationsText(Store.Items,True,Style);
      Require(Exported.Contains('&lt;script&gt;') and not Exported.Contains('<script>'),'HTML export executed note content');
      Require(Exported.Contains('Книга') and Exported.Contains('Изменено'),'HTML export omitted notes/context');
      TFile.WriteAllText('notes-style-'+IntToStr(Style)+'.html',Exported,TEncoding.UTF8);
      TFile.WriteAllBytes('notes-style-'+IntToStr(Style)+'.docx',ReaderAnnotationsDocx(Store.Items,Style));
      Zip:=TZipFile.Create;
      try
        Zip.Open('notes-style-'+IntToStr(Style)+'.docx',zmRead); Zip.Read('word/document.xml',Bytes);
        Exported:=TEncoding.UTF8.GetString(Bytes);
        Require(Exported.Contains('Изменено') and Exported.Contains('&lt;script&gt;') and Exported.Contains('🌿'),'DOCX lost Unicode thoughts, quote or escaped contents');
        Require(Zip.FileCount=5,'DOCX package omitted content or style relationships');
      finally Zip.Free; end;
    end;
    Store.Remove(ID); Require((Length(Store.Items)=1) and (Store.Items[0].ID=OtherID),'Deleting one note lost another book');
  finally Stale.Free; Store.Free; end;
  TFile.Move('notes-test/reader-notes.json','notes-test/removed.json');
  var BackupHash:=THashSHA2.GetHashStringFromFile('notes-test/reader-notes.json.bak');
  var MissingRejected:=False;
  try Store:=TReaderAnnotations.Create('notes-test/profile.ini'); Store.Free; except MissingRejected:=True; end;
  Require(MissingRejected and not TFile.Exists('notes-test/reader-notes.json') and
    (BackupHash=THashSHA2.GetHashStringFromFile('notes-test/reader-notes.json.bak')),'Missing main notes file silently replaced recoverable records');
  TFile.Move('notes-test/removed.json','notes-test/reader-notes.json');
  Bytes:=TEncoding.UTF8.GetBytes('{"version":1,"notes":[{"id":"utf","book":"one","position":0,"title":"x"}]}');
  for var I:=0 to High(Bytes) do if Bytes[I]=Ord('x') then Bytes[I]:=$FF;
  TFile.WriteAllBytes('notes-test/reader-notes.json',Bytes);
  var UTF8Hash:=THashSHA2.GetHashStringFromFile('notes-test/reader-notes.json');
  var UTF8Rejected:=False;
  try Store:=TReaderAnnotations.Create('notes-test/profile.ini'); Store.Free; except UTF8Rejected:=True; end;
  Require(UTF8Rejected and (UTF8Hash=THashSHA2.GetHashStringFromFile('notes-test/reader-notes.json')),'Damaged UTF8 notes were decoded and overwritten');
  TFile.WriteAllText('notes-test/reader-notes.json','{"version":1,"notes":[BROKEN',TEncoding.UTF8);
  Hash:=THashSHA2.GetHashStringFromFile('notes-test/reader-notes.json');
  var Rejected:=False; try Store:=TReaderAnnotations.Create('notes-test/profile.ini'); Store.Free; except Rejected:=True; end;
  Require(Rejected and (Hash=THashSHA2.GetHashStringFromFile('notes-test/reader-notes.json')),'Damaged notes were overwritten');
  Reader:=TfrmBuiltinReader.Create(nil); Starts:=TList<Integer>.Create;
  try
    Reader.Show; Reader.OpenBook('contents-progress.fb2','Contents','notes-navigation','notes-nav.ini','pdfium.dll'); WaitReady(Reader);
    Reader.GoToPosition(0); Starts.Add(0);
    while Reader.ReadingProgress<1 do
    begin
      var Before:=Reader.TextPosition; Reader.NextPage;
      if Reader.TextPosition=Before then Break; Starts.Add(Reader.TextPosition);
    end;
    Reader.RequestGlobalPages; Watch:=TStopwatch.StartNew;
    while not Reader.GlobalPaginationReady and (Watch.ElapsedMilliseconds<20000) do begin Application.ProcessMessages; CheckSynchronize(1); end;
    Require(Reader.GlobalPaginationReady,'Global pagination did not complete through idle chunks');
    for var I:=0 to Starts.Count-1 do Require(Reader.GlobalPageAt(Starts[I])=I+1,'Global page count reset at chapter boundary');
    Reader.GoToPosition(0); Bar:=nil; for C in Reader do if C is TPaintBox then Bar:=TPaintBox(C);
    Require(Assigned(Bar) and (Bar.Height>=14) and Assigned(Bar.OnMouseDown) and Assigned(Bar.OnMouseMove) and Assigned(Bar.OnMouseUp),'Progress bar has no click/drag navigation');
    Bar.OnMouseDown(Bar,mbLeft,[],Bar.Width div 2,2); Require(Abs(Reader.TextPosition-Reader.TextLength div 2)<Reader.TextLength div 50,'Progress click missed midpoint');
    var At:=Reader.TextPosition; Watch:=TStopwatch.StartNew;
    for var I:=1 to 300 do Bar.OnMouseMove(Bar,[ssLeft],MulDiv(Bar.Width,I,300),2);
    Require((Reader.TextPosition=At) and (Watch.ElapsedMilliseconds<100),'Each drag move performed costly pagination');
    Bar.OnMouseUp(Bar,mbLeft,[],Bar.Width-1,2); Require(Reader.ReadingProgress=1,'Progress release did not navigate to selected end');
    Bar.OnMouseDown(Bar,mbLeft,[],0,2); Bar.OnMouseUp(Bar,mbLeft,[],0,2); Require(Reader.TextPosition=0,'Progress did not return to beginning');
    Reader.AddBookmark; Items:=Reader.AnnotationItems(False); Require((Length(Items)=1) and Items[0].Title.StartsWith('Закладка:'),'Export omitted pre-existing bookmark representation');
    Reader.Close;
  finally Starts.Free; Reader.Free; end;
  Writeln('PASS Unicode notes durable atomic backup, all books, edit/delete isolation, concurrent/corrupt file protection, HTML/DOCX four styles, bookmark export, global page index and throttled progress drag');
end;

procedure AuditEPUBStyles;
var CSS: TReaderCSS; Reader: TfrmBuiltinReader; Buffer: TRichEdit; BeforeHash, Text: string; Doc: TReaderDocument;
begin
  CSS:=TReaderCSS.Create;
  try
    CSS.Add('p.center {font-weight:bold; text-align:center} p {font-weight:normal} .small {font-size:75%}');
    Require(CSS.RTF('p','center','','').Contains('\b ') and CSS.RTF('p','center','','').Contains('\qc '),'CSS tag/class specificity lost heading emphasis or alignment');
    Require(CSS.FontPercent('span','small','','',120)=90,'CSS percentage lost parent relative size');
    CSS.Add('.center {font-weight:normal!important}');
    Require(CSS.RTF('p','center','','font-weight:bold').Contains('\b0 '),'CSS important rule did not override inline normal priority');
    Require(CSS.RTF('p','center','','font-weight:bold!important').Contains('\b '),'Inline important priority was lost');
    CSS.Clear; Require(CSS.RTF('p','center','','')='','Old spine styles leaked into another section');
    Text:=''; for var I:=1 to 4096 do Text:=Text+'.a,';
    CSS.Add(Text+'.late{font-weight:bold}');
    Require(CSS.RTF('p','late','','')='','Comma selector list bypassed bounded stylesheet rule count');
    CSS.Clear;
  finally CSS.Free; end;
  BeforeHash:=THashSHA2.GetHashStringFromFile('css-style.epub'); Doc:=TReaderDocument.Create;
  try
    Doc.Load('css-style.epub'); Text:=Doc.PlainText;
    Require(Text.Contains('малый курсив') and Text.Contains('обычный жирный текст.'),'EPUB styles dropped text or separating whitespace');
    Require(not Text.Contains('font-weight') and not Text.Contains('margin-bottom'),'EPUB stylesheet code entered reading text');
    Require(Length(Doc.Chapters)=1,'CSS styling added fake chapters');
  finally Doc.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('css-style.epub','Styled EPUB','styled-css','styled-css.ini','pdfium.dll'); WaitReady(Reader);
    Reader.SetTheme(1); Reader.ChangeSize(20-Reader.ReaderFontSize); Reader.SetHeadingColor(clPurple);
    Buffer:=ReaderFormattingBuffer(Reader);
    SelectReaderWord(Reader,'Центр'); Require((fsBold in Buffer.SelAttributes.Style) and (Buffer.Paragraph.Alignment=taCenter),'Linked EPUB CSS did not center and emphasize its paragraph');
    SelectReaderWord(Reader,'малый курсив'); Require((fsItalic in Buffer.SelAttributes.Style) and (Buffer.SelAttributes.Size=15),'EPUB relative font size or italic did not reach native rendering');
    SelectReaderWord(Reader,'Правый абзац'); Require((fsItalic in Buffer.SelAttributes.Style) and (Buffer.Paragraph.Alignment=taRightJustify),'Embedded/inline EPUB CSS lost right alignment or italic');
    SelectReaderWord(Reader,'обычный'); Require(not (fsBold in Buffer.SelAttributes.Style),'Later stylesheet rule did not restore ordinary text');
    SelectReaderWord(Reader,'жирный'); Require(fsBold in Buffer.SelAttributes.Style,'Inline EPUB emphasis was ignored');
    SelectReaderWord(Reader,'Цветной заголовок'); Require((Buffer.SelAttributes.Size=30) and (ColorToRGB(Buffer.SelAttributes.Color)=ColorToRGB(clPurple)),'Relative heading size erased the reader heading color');
    Reader.ChangeSize(4); SelectReaderWord(Reader,'малый курсив'); Require(Buffer.SelAttributes.Size=18,'EPUB size differences did not follow reader font changes');
    Reader.SetTheme(4); Reader.SetHeadingColor(clPurple); SelectReaderWord(Reader,'Цветной заголовок');
    Require(ColorToRGB(Buffer.SelAttributes.Color)=ColorToRGB(ReadableReaderColor(clPurple,$002B2927)),'EPUB CSS erased the selected dark heading color');
    Require(Reader.BookText.TrimEnd([#13,#10])=Text.TrimEnd([#13,#10]),'Rendered EPUB styles altered copied text'); Reader.Close;
  finally Reader.Free; end;
  Require(BeforeHash=THashSHA2.GetHashStringFromFile('css-style.epub'),'CSS rendering rewrote source EPUB');
  Writeln('PASS EPUB linked/embedded/inline CSS cascade, emphasis, alignment and relative sizes preserve body font, light/dark heading colors, Unicode copy and source');
end;

procedure AuditSearchResults;
var Reader: TfrmBuiltinReader; Owner: TForm; BeforePosition, First: Integer;
  procedure ChooseResult(const Query: string; Minimum, Index: Integer; CancelImmediately: Boolean = False);
  begin
    TThread.ForceQueue(nil,
      procedure
      var Popup: TForm; List: TListView; Stop: TButton; C: TComponent; Watch: TStopwatch;
      begin
        Popup:=Screen.ActiveForm; List:=nil; Stop:=nil;
        Require((Popup.Caption='Результаты поиска') and (Popup.BorderStyle=bsSizeable),'Search results dialog is missing or cannot resize');
        for C in Popup do
        begin
          if C is TListView then List:=TListView(C);
          if (C is TButton) and (TButton(C).Caption='Остановить поиск') then Stop:=TButton(C);
        end;
        Require(Assigned(List) and Assigned(Stop) and List.OwnerData,'Search does not use a bounded virtual results list');
        if CancelImmediately then begin Popup.ModalResult:=mrCancel; Exit; end;
        Watch:=TStopwatch.StartNew;
        while Stop.Enabled and (Watch.ElapsedMilliseconds<5000) do
        begin Application.ProcessMessages; CheckSynchronize(1); end;
        Require(not Stop.Enabled,'Find all did not finish responsively');
        Require(List.Items.Count>=Minimum,'Find all lost matches: '+IntToStr(List.Items.Count));
        for var DPI in TArray<Integer>.Create(96,120,144,192) do
        begin
          Popup.ScaleForPPI(DPI); Popup.ClientWidth:=MulDiv(520,DPI,96); Popup.ClientHeight:=MulDiv(400,DPI,96);
          for C in Popup do if C is TButton then
          begin
            var B:=TButton(C); Require((B.Left>=0) and (B.Top>=0) and
              (B.Left+B.Width<=B.Parent.ClientWidth) and (B.Top+B.Height<=B.Parent.ClientHeight),
              'Search results button is clipped at '+IntToStr(DPI)+' DPI');
          end;
        end;
        List.Items[Index].Selected:=True; List.OnData(List,List.Items[Index]);
        Require((List.Items[Index].SubItems.Count=3) and string(List.Items[Index].SubItems[2]).ToLower.Contains(Query.ToLower),
          'Search results lost surrounding text or Unicode query');
        Popup.ModalResult:=mrOk;
      end);
    Reader.ShowSearchResults(Query);
  end;
begin
  Owner:=TForm.CreateNew(nil); Reader:=TfrmBuiltinReader.Create(Owner);
  try
    Owner.Show; Reader.Show; Reader.OpenBook('search.txt','Find all','results','results.ini','pdfium.dll'); WaitReady(Reader);
    Require((Reader.PopupMode=pmExplicit) and (GetWindow(Reader.Handle,GW_OWNER)=Owner.Handle),
      'Reader native window is not owned by the main form');
    Reader.SetSearchOptions(False,False,False); ChooseResult('needle',4,1);
    Require((Reader.MatchPosition=7) and (Reader.HighlightCount=1),'Chosen result did not navigate and highlight its exact match');
    First:=Reader.MatchPosition; Reader.FindText('needle'); Require(Reader.MatchPosition>First,'Find next after results did not advance');
    Reader.FindText('needle',True); Require(Reader.MatchPosition=First,'Find previous after results missed chosen result');
    BeforePosition:=Reader.TextPosition; ChooseResult('absent',0,0,True);
    Require(Reader.Visible and (Reader.TextPosition=BeforePosition),'Closing results hid the reader or moved the reading position');
    Reader.Close;
  finally Reader.Free; Owner.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook('search.pdf','PDF results','results-pdf','results-pdf.ini','pdfium.dll'); WaitReady(Reader);
    Reader.SetSearchOptions(False,True,False); ChooseResult('needle',3,1);
    Reader.FindText('needle'); var Watch:=TStopwatch.StartNew;
    while Reader.SearchRunning and (Watch.ElapsedMilliseconds<5000) do begin Application.ProcessMessages; CheckSynchronize(1); end;
    Require(Reader.Visible and not Reader.SearchRunning and string(Reader.ReaderStatus.Caption).Contains('Найдено'),
      'PDF next search after results lost its reader or failed'); Reader.Close;
  finally Reader.Free; end;
  Writeln('PASS responsive virtual find-all context and selected text/PDF matches, next/previous, cancellation, native owner and 96-192 DPI');
end;

procedure AuditRealEPUB;
var Reader: TfrmBuiltinReader; Doc: TReaderDocument; FileName, BeforeHash, Text, Query: string;
  Watch: TStopwatch; LoadMS, MovesMS, MaxMS, SearchMS: Int64; Position, Moves, Start, Finish, Cases, ExpectedImages: Integer;
begin
  SetMHLTheme(False); Cases:=0;
  for FileName in TDirectory.GetFiles('.', 'real-epub-*.epub') do
  begin
    Inc(Cases); Require(Cases<=20,'Real EPUB fixture count exceeds bounded regression');
    BeforeHash:=THashSHA2.GetHashStringFromFile(FileName); Doc:=TReaderDocument.Create;
    try
      Doc.Load(FileName); Text:=Doc.PlainText; ExpectedImages:=Doc.ImageCount;
      // EM_GETTEXTRANGE exposes an OLE image as a space. It still occupies
      // one UTF-16 position; assert the actual OLE count independently below.
      Text:=Text.Replace(#$FFFC,' ');
      Require(Length(Text)>10000,'Real EPUB lost most of its body');
      Require(Length(Doc.Chapters)>0,'Real EPUB heading hierarchy is absent');
      Writeln('PROFILE real-epub ',ExtractFileName(FileName),' chars=',Length(Text),' chapters=',Length(Doc.Chapters),
        ' images=',Doc.ImageCount,' styles=',Length(Doc.Styles),' notes=',Doc.FootnoteCount); Flush(Output);
    finally Doc.Free; end;
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Watch:=TStopwatch.StartNew;
      Reader.OpenBook(FileName,ExtractFileName(FileName),'real-'+ExtractFileName(FileName),'real-epub.ini','pdfium.dll'); WaitReady(Reader);
      LoadMS:=Watch.ElapsedMilliseconds; Reader.SetTypography('Georgia',110,32); Reader.SetMaxTextWidth(960);
      if Reader.BookText.TrimEnd([#13,#10])<>Text.TrimEnd([#13,#10]) then
      begin TFile.WriteAllText('epub-expected.txt',Text,TEncoding.UTF8); TFile.WriteAllText('epub-observed.txt',Reader.BookText,TEncoding.UTF8); end;
      Require(Reader.PictureCount=ExpectedImages,'EPUB rendering dropped a supported source illustration');
      Require(Reader.BookText.TrimEnd([#13,#10])=Text.TrimEnd([#13,#10]),'EPUB rendering changed its exact Unicode body');
      MovesMS:=0; MaxMS:=0; Moves:=0;
      for var I:=1 to 40 do
      begin
        Position:=Reader.TextPosition; Watch:=TStopwatch.StartNew; Reader.NextPage; Application.ProcessMessages; CheckSynchronize(1);
        if Reader.TextPosition=Position then Break;
        Require(Reader.TextPosition>Position,'EPUB pagination moved backwards');
        Inc(Moves); Inc(MovesMS,Watch.ElapsedMilliseconds); MaxMS:=Max(MaxMS,Watch.ElapsedMilliseconds);
        Require(Reader.Ready and Reader.Visible,'EPUB pagination hid or reset the reader');
      end;
      Require(Moves>=10,'Real EPUB cannot page through its body');
      Start:=Min(1000,Length(Text));
      while (Start<=Length(Text)) and not TCharacter.IsLetter(Text[Start]) do Inc(Start);
      Finish:=Start; while (Finish<=Length(Text)) and TCharacter.IsLetter(Text[Finish]) do Inc(Finish);
      Query:=Copy(Text,Start,Finish-Start); Require(Query<>'','EPUB contains no searchable prose');
      Watch:=TStopwatch.StartNew; Reader.FindText(Query); SearchMS:=Watch.ElapsedMilliseconds;
      Require(Reader.MatchPosition>=0,'Real EPUB prose search found no match');
      Reader.FindText(Query); Reader.ReadingSurface.Perform(WM_MOUSEWHEEL,WPARAM(Integer(-120) shl 16),0); Application.ProcessMessages;
      Require(Reader.Visible and Reader.Ready,'EPUB next search/wheel hid its window');
      Reader.SetTheme(4); Reader.SetHeadingColor(clPurple); Reader.SetTheme(1);
      Require(Reader.BookText.TrimEnd([#13,#10])=Text.TrimEnd([#13,#10]),'EPUB theme/search/pagination changed copyable text');
      Writeln('PROFILE real-epub ',ExtractFileName(FileName),' load_ms=',LoadMS,' moves=',Moves,' moves_ms=',MovesMS,' max_ms=',MaxMS,' search_ms=',SearchMS); Flush(Output);
      Reader.Close;
    finally Reader.Free; end;
    Require(BeforeHash=THashSHA2.GetHashStringFromFile(FileName),'Real EPUB source was rewritten');
  end;
  Require(Cases=5,'The selected five real EPUB fixtures were not all exercised');
  Writeln('PASS five real EPUB books keep headings, local styles, images and exact Unicode text through opening, page turns, search, wheel and themes');
end;

procedure AuditLargeBook;
var Reader: TfrmBuiltinReader; Doc: TReaderDocument; Ini: TMemIniFile;
  Probe: TReaderMessageProbe; Buffer: TRichEdit; Watch: TStopwatch;
  I, Position, FirstMatch, SecondMatch, BizarroPosition: Integer; TotalMS, MaxMS, LoadMS: Int64; Notes, Text, BeforeHash, Query: string;
  EmptyPanel, SavedDark: Boolean; RTF: UTF8String;
begin
  Application.CreateForm(TDMUser,DMUser); DMUser.Init; SetMHLTheme(False);
  BeforeHash:=THashSHA2.GetHashStringFromFile('formatting-real.fb2');
  Doc:=TReaderDocument.Create;
  try
    Watch:=TStopwatch.StartNew; Doc.Load('formatting-real.fb2');
    Writeln('PROFILE large-book parse_ms=',Watch.ElapsedMilliseconds,' chars=',Length(Doc.PlainText),
      ' styles=',Length(Doc.Styles),' chapters=',Length(Doc.Chapters),' notes=',Doc.FootnoteCount); Flush(Output);
    BizarroPosition:=-1;
    for var Range in Doc.Styles do if Range.Kind=rbFootnote then
    begin
      Notes:=Doc.FootnotesForRange(Range.Start,Range.Start+Range.Count);
      if Notes.Contains('Мир Бизарро') then
      begin
        Require(Notes.StartsWith('6. Мир Бизарро'), 'Real note 6 separates its label from the body');
        Require(not Notes.Contains(#13#10), 'Single real note still contains paragraph breaks');
        BizarroPosition:=Range.Start; Break;
      end;
    end;
    Watch:=TStopwatch.StartNew; RTF:=Doc.RTF(960,1000);
    Writeln('PROFILE large-book presentation_ms=',Watch.ElapsedMilliseconds,' bytes=',Length(RTF)); RTF:=''; Flush(Output);
  finally Doc.Free; end;
  Ini:=TMemIniFile.Create('large-book.ini',TEncoding.UTF8);
  try
    Ini.WriteString('Reader','FontName','Georgia'); Ini.WriteInteger('Reader','FontSize',20);
    Ini.WriteInteger('Reader','InitialsMode',2); Ini.WriteInteger('Reader','Theme',4);
    Ini.WriteInteger('Reader','Width',1135); Ini.WriteInteger('Reader','Height',1139); Ini.UpdateFile;
  finally Ini.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil); Probe:=TReaderMessageProbe.Create;
  try
    Buffer:=ReaderFormattingBuffer(Reader); Probe.Original:=Buffer.WindowProc; Buffer.WindowProc:=Probe.Message;
    Watch:=TStopwatch.StartNew; Reader.Show;
    Reader.OpenBook('formatting-real.fb2','Under the Dome','large-real','large-book.ini','pdfium.dll'); WaitReady(Reader);
    LoadMS:=Watch.ElapsedMilliseconds; SavedDark:=Reader.ThemeIndex>=4;
    Require(Probe.Styles<1000,'Opening the novel eagerly restyled thousands of off-screen paragraphs');
    Writeln('PROFILE large-book load_ms=',LoadMS,' format_ms=',Round(Probe.FormatMS*1000/TStopwatch.Frequency),' style_ms=',Round(Probe.StyleMS*1000/TStopwatch.Frequency),
      ' stream_ms=',Round(Probe.StreamMS*1000/TStopwatch.Frequency),' select_ms=',Round(Probe.SelectMS*1000/TStopwatch.Frequency),' length_ms=',Round(Probe.LengthMS*1000/TStopwatch.Frequency),' format_calls=',Probe.Formats,' style_calls=',Probe.Styles); Flush(Output);
    Watch:=TStopwatch.StartNew; Sleep(180); Application.ProcessMessages; CheckSynchronize(1);
    Writeln('PROFILE large-book deferred_layout_ms=',Watch.ElapsedMilliseconds); Flush(Output);
    Text:=Reader.BookText; TotalMS:=0; MaxMS:=0; EmptyPanel:=False;
    for I:=1 to 40 do
    begin
      Position:=Reader.TextPosition; Watch:=TStopwatch.StartNew; Reader.NextPage; Application.ProcessMessages; CheckSynchronize(1);
      Require(Reader.TextPosition>Position,'Large real book did not advance');
      Inc(TotalMS,Watch.ElapsedMilliseconds); MaxMS:=Max(MaxMS,Watch.ElapsedMilliseconds);
      for var J:=0 to Reader.ComponentCount-1 do
        if (Reader.Components[J] is TMemo) and TMemo(Reader.Components[J]).Visible and
          TMemo(Reader.Components[J]).Parent.Visible and (TMemo(Reader.Components[J]).Text='') then EmptyPanel:=True;
    end;
    Writeln('PROFILE large-book moves=40 total_ms=',TotalMS,' max_ms=',MaxMS,
      ' cumulative_format_ms=',Round(Probe.FormatMS*1000/TStopwatch.Frequency),' cumulative_style_ms=',Round(Probe.StyleMS*1000/TStopwatch.Frequency),' select_ms=',Round(Probe.SelectMS*1000/TStopwatch.Frequency)); Flush(Output);
    TotalMS:=0; MaxMS:=0;
    for I:=1 to 40 do
    begin
      Watch:=TStopwatch.StartNew; Reader.SeekProgress(((I*37) mod 100)/100);
      Application.ProcessMessages; CheckSynchronize(1);
      Require(Reader.Ready and Reader.Visible and (Reader.PageText<>''),'Random progress jump hid the large reader');
      Inc(TotalMS,Watch.ElapsedMilliseconds); MaxMS:=Max(MaxMS,Watch.ElapsedMilliseconds);
    end;
    Writeln('PROFILE large-book random_jumps=40 total_ms=',TotalMS,' max_ms=',MaxMS); Flush(Output);
    Require(MaxMS<500,'Random jump blocks more than half a second');
    Reader.GoToPosition(0); Reader.SetSearchOptions(False,False,False);
    Query:='привет'; if not Text.ToLower.Contains(Query) then Query:='і';
    Watch:=TStopwatch.StartNew; Reader.FindText(Query); FirstMatch:=Reader.MatchPosition;
    Require(FirstMatch>=0,'Real-book greeting search found no first match');
    Writeln('PROFILE greeting first_ms=',Watch.ElapsedMilliseconds,' position=',FirstMatch); Flush(Output);
    Watch:=TStopwatch.StartNew; Reader.FindText(Query); SecondMatch:=Reader.MatchPosition;
    Require(SecondMatch>FirstMatch,'Real-book greeting next did not advance');
    Writeln('PROFILE greeting next_ms=',Watch.ElapsedMilliseconds,' position=',SecondMatch); Flush(Output);
    Reader.FindText(Query,True); Require(Reader.MatchPosition=FirstMatch,'Real-book previous search missed first match');
    TotalMS:=0; MaxMS:=0;
    for I:=1 to 40 do
    begin
      Watch:=TStopwatch.StartNew; Reader.FindText(Query);
      Application.ProcessMessages; CheckSynchronize(1);
      Require(Reader.Ready and Reader.Visible,'Search hid or reset the real-book reader');
      Require(Reader.HighlightCount>0,'Real-book search result has no highlight');
      Inc(TotalMS,Watch.ElapsedMilliseconds); MaxMS:=Max(MaxMS,Watch.ElapsedMilliseconds);
    end;
    Writeln('PROFILE greeting next_moves=40 total_ms=',TotalMS,' max_ms=',MaxMS); Flush(Output);
    Reader.ReadingSurface.Perform(WM_MOUSEWHEEL,WPARAM(Integer(-120) shl 16),0);
    Application.ProcessMessages; Require(Reader.Ready and Reader.Visible,'Wheel after search hid or reset the reader');
    if BizarroPosition>=0 then
    begin
      Reader.GoToPosition(BizarroPosition);
      Require(Reader.VisibleFootnotes.StartsWith('6. Мир Бизарро'), 'Real note 6 is absent from its referenced page');
      Writeln('PASS real Bizarro footnote has compact number and text on one line');
    end;
    Reader.FindText('Мир Бизарро');
    // Notes are intentionally excluded from normal book search. Read their display via a body reference.
    Reader.FindText('Бизарро'); Notes:=Reader.VisibleFootnotes;
    Writeln('OBSERVED saved_dark_on_light=',SavedDark,' empty_notes_panel=',EmptyPanel); Flush(Output);
    Require(Reader.BookText=Text,'Pagination changed large book text');
    Reader.Close;
    Require(not EmptyPanel,'Empty footnote panel still occupies reading space');
    Require(not SavedDark,'Saved dark reader theme overrides current light app theme');
    Writeln('PASS real large FB2 opening, 40 page turns, unchanged text, adaptive footnotes and app theme');
  finally
    Buffer.WindowProc:=Probe.Original; Probe.Free; Reader.Free; DMUser.Free; DMUser:=nil;
  end;
  Require(BeforeHash=THashSHA2.GetHashStringFromFile('formatting-real.fb2'),'Large book source was rewritten');
end;

var Doc: TReaderDocument; Form: TfrmBuiltinReader; Name, BeforeHash, Identity: string;
  Ini: TMemIniFile; Position, Progress: Integer; Watch: TStopwatch;
  PDF: TReaderPDF; Bitmap: Vcl.Graphics.TBitmap; PDFMatch: TPDFMatch; Raster: TPoint; CancelChecks: Integer; GDIInitial: Cardinal;
  Chapters: TComboBox; Encoded: UTF8String; RTFBytes: TBytes;
  Cycle, UserInitial, FormsInitial: Integer;
begin
  RequireIsolatedRegression;
  CoInitialize(nil);
  try
    Application.Initialize;
    if ParamCount>0 then
    begin
      if ParamStr(1)='reader-colors' then AuditReaderColorBox
      else if ParamStr(1)='optional-fonts' then AuditOptionalFonts
      else if ParamStr(1)='footnotes' then AuditFootnotes
      else if ParamStr(1)='large-book' then AuditLargeBook
      else if ParamStr(1)='real-epub' then AuditRealEPUB
      else if ParamStr(1)='doc-reader' then AuditDirectDOC
      else if ParamStr(1)='text-selection' then AuditRealTextSelection
      else if ParamStr(1)='selection-geometry' then begin AuditFailedReaderCleanup; AuditSelectionGeometry; end
      else if ParamStr(1)='selection-contrast' then AuditSelectionContrast
      else if ParamStr(1)='unspaced-history' then AuditUnspacedHistory
      else if ParamStr(1)='reader-note-ui' then begin AuditNoteDialogs; AuditDirectTextSelection; end
      else if ParamStr(1)='feedback16-reader' then begin AuditDirectTextSelection; AuditFeedbackPDF; AuditAsyncPDF; end
      else if ParamStr(1)='reader-additions' then begin AuditContentsAndProgress; AuditReaderNavigationAndNotes; end
      else if ParamStr(1)='oct11-reader' then begin AuditOctoberElevenReader; AuditContentsAndProgress; AuditSearchResults; AuditEPUBStyles; AuditReaderNavigationAndNotes; end
      else if ParamStr(1)='oct10-reader' then AuditOctoberReader
      else if ParamStr(1)='raster-reader' then AuditRasterReader
      else if ParamStr(1)='release-pagination' then AuditReleasePagination
      else if ParamStr(1)='djvu-quality' then AuditDjvuQuality
      else if ParamStr(1)='loading-preferences' then AuditLoadingPreferences
      else if ParamStr(1)='real-formats' then AuditRealFormats
      else if ParamStr(1)='document-spacing' then AuditDocumentSpacing
      else if ParamStr(1)='pdf-current-page-search' then AuditPDFSearch
      else if (ParamStr(1)='loading-navigation') or (ParamStr(1)='same-position-navigation') or (ParamStr(1)='precision-wheel') then AuditNavigation(ParamStr(1))
      else raise Exception.Create('Unknown regression case: '+ParamStr(1));
      Writeln('PASS experimental built-in reader native regressions');
      CoUninitialize; Halt(0);
    end;
    if FileExists(ExtractFilePath(ParamStr(0))+'reader-preview.txt') then
    begin
      Name:=Trim(TFile.ReadAllText(ExtractFilePath(ParamStr(0))+'reader-preview.txt',TEncoding.UTF8));
      Name:=ExtractFilePath(ParamStr(0))+ExtractFileName(Name);
      Writeln('PREVIEW create'); Flush(Output);
      Application.CreateForm(TDMUser,DMUser); DMUser.Init;
      Application.MainFormOnTaskBar:=True;
      Application.CreateForm(TfrmBuiltinReader,Form);
      Writeln('PREVIEW open'); Flush(Output);
      Form.Show;
      Form.OpenBook(Name,'Проверка читалки','preview-'+Name,
        ExtractFilePath(ParamStr(0))+'reader-preview.ini',ExtractFilePath(ParamStr(0))+'pdfium.dll');
      Writeln('PREVIEW run'); Flush(Output);
      Application.Run;
      CoUninitialize; Halt(0);
    end;
    AuditLoadingPreferences;
    Doc:=TReaderDocument.Create;
    try
      Doc.Load('sample.fb2');
      Require(Doc.ImageCount=1,'FB2 image not loaded');
      Require(Length(Doc.Chapters)>=2,'FB2 table of contents missing');
      Require(Pos('Первая глава',Doc.PlainText)>0,'FB2 Cyrillic text lost');
      Require(Pos('Текст второй главы',Doc.PlainText)>0,'FB2 body missing');
      Require(Pos('\u',string(Doc.RTF))>0,'RTF Unicode escape missing');
      Doc.Load('sample.fb2');
      Encoded:=Doc.RTF; SetLength(RTFBytes,Length(Encoded));
      if Length(Encoded)>0 then Move(Encoded[1],RTFBytes[0],Length(Encoded));
      TFile.WriteAllBytes('generated-image.rtf',RTFBytes);
      Require(Doc.ImageCount=1,'Reusing document duplicated illustrations');
    finally Doc.Free; end;
    Doc:=TReaderDocument.Create;
    try
      Doc.Load('sample.epub');
      Require(Pos('Первая по spine',Doc.PlainText)<Pos('Вторая по spine',Doc.PlainText),'EPUB spine order changed');
      Require(Doc.ImageCount=1,'EPUB illustration missing');
      Require(Pos('🌍',Doc.PlainText)>0,'EPUB Unicode surrogate pair lost');
    finally Doc.Free; end;
    Doc:=TReaderDocument.Create;
    try
      Doc.Load('sample-equivalent-png.fb2'); Encoded:=Doc.RTF;
      Doc.Load('sample-webp.fb2');
      Require((Doc.ImageCount=1) and (Doc.SkippedImages=0),'LightLib WebP with JPEG metadata was not decoded');
      Require(Doc.RTF=Encoded,'Lossless WebP display changed pixels compared with equivalent PNG');
    finally Doc.Free; end;
    Writeln('PASS LightLib WebP is decoded by bytes and preserves identical presentation pixels');
    Require(ReaderDecodeText(TBytes.Create($CF,$F0,$E8,$E2,$E5,$F2))='Привет','Windows-1251 decode failed');
    Require(ReaderDecodeText(TBytes.Create($EF,$BB,$BF))='','UTF8 BOM-only file failed');
    Doc:=TReaderDocument.Create;
    try
      Doc.Load('literal.xhtml');
      Require(Pos('Литерал &nbsp; &mdash;',Doc.PlainText)>0,'HTML entities changed literal CDATA text');
      Require(Pos('Разрыв'+#160+'строки',Doc.PlainText)>0,'XHTML entity outside CDATA was not decoded');
      Doc.Load('literal-dtd.xhtml');
      Require(Pos('<!DOCTYPE html> обычный текст',Doc.PlainText)>0,'DOCTYPE literal in CDATA changed');
      Doc.Load('encoding-attribute.xhtml');
      Require(Pos('Русский текст с эмодзи 🌍',Doc.PlainText)>0,'A content attribute changed XML character encoding');
    finally Doc.Free; end;
    Writeln('PASS XML preserves literal CDATA and uses only declaration encoding');
    AuditNavigation('loading-navigation');
    AuditNavigation('same-position-navigation');
    AuditNavigation('precision-wheel');
    AuditDocumentSpacing;
    AuditPDFSearch;
    Doc:=TReaderDocument.Create;
    try
      Doc.Load('rtf-escapes.txt'); Encoded:=Doc.RTF;
      Require(Pos('A\\\{\}\tab \par \u1055?',string(Encoded))>0,'TXT RTF escaping changed');
      Require(Pos('\u128?\u-32768?\u-1?',string(Encoded))>0,'TXT RTF signed UTF16 boundary changed');
      Require(Pos('\u-10180?\u-8435?',string(Encoded))>0,'TXT RTF surrogate pair changed');
      Doc.ReleaseUnusedBuffers;
      Require(Pos('\u-32768?',string(Encoded))>0,'TXT native stream buffer was released too soon');
      Doc.Load('sample.fb2'); Require(Doc.ImageCount=1,'Reload retained stale TXT buffer');
    finally Doc.Free; end;
    Writeln('PASS TXT escapes controls, Unicode boundaries and surrogate pairs');

    Doc:=TReaderDocument.Create;
    try Doc.Load('emoji.txt'); Require(Pos('\u-10180',string(Doc.RTF))>0,'RTF emoji high surrogate incorrect');
    finally Doc.Free; end;
    Doc:=TReaderDocument.Create;
    try
      Doc.Load('duplicate-image.fb2');
      Require((Doc.ImageCount=1) and (Pos('\picw160\pich100',string(Doc.RTF))>0),'Duplicate ID selected smaller raster');
      Doc.Load('missing-images.fb2');
      Require((Doc.SkippedImages=25) and (Doc.Warnings.Count=20),'Skipped image count limited to warning samples');
    finally Doc.Free; end;
    for Name in ['sample.docx','sample.odt'] do
    begin
      Doc:=TReaderDocument.Create;
      try
        Doc.Load(Name); Require(Doc.ImageCount=1,'Package image not loaded: '+Name);
        Require(Length(Doc.Chapters)>=2,'Package contents not loaded: '+Name);
        Require(Pos('Первая глава',Doc.PlainText)>0,'Package Unicode text missing: '+Name);
      finally Doc.Free; end;
    end;
    Doc:=TReaderDocument.Create;
    try
      Doc.Load('remote-assets.epub');
      Require((Doc.ImageCount=1) and (Pos('Первая по spine',Doc.PlainText)>0),
        'An unused remote EPUB resource prevented offline text reading');
    finally Doc.Free; end;
    Writeln('PASS EPUB remote assets do not block local reading');
    Writeln('PASS read-only FB2 and EPUB preserve Unicode, body order, formatting, images and contents');
    Flush(Output);
    for Name in ['sample.fb2','sample-webp.fb2','text-only.fb2','sample.epub','sample.docx','sample.odt','sample.txt','sample.rtf'] do
    begin
      BeforeHash:=THashSHA2.GetHashStringFromFile(Name); Identity:='reader-test-'+Name;
      Form:=TfrmBuiltinReader.Create(nil);
      try
        Form.Show; Watch:=TStopwatch.StartNew;
        Form.OpenBook(Name,Name,Identity,'reader-test.ini','pdfium.dll'); WaitReady(Form);
        Writeln('PROFILE reader ',Name,' load_ms=',Watch.ElapsedMilliseconds,' chars=',Form.TextLength);
        Require(Form.TextLength>5000,'Fixture reader lost text');
        if Name='text-only.fb2' then Require((Form.PictureCount=0) and (Pos('Текст второй главы',Form.BookText)>0),'Image-free FB2 lost its text');
        if (Name='sample.fb2') or (Name='sample-webp.fb2') or (Name='sample.epub') or (Name='sample.docx') or (Name='sample.odt') then
        begin
          Require(Form.PictureCount=1,'Native reader lost inline raster illustration');
          Form.GoToChapter(1);
          Require(Pos('Вторая',Copy(Form.BookText,Form.TextPosition+1,30))=1,'Contents position differs from native text after inline image');
          Form.GoToChapter(0);
        end;
        if Name='sample.epub' then
        begin
          Require(Pos('Первая по spine',Form.BookText)>0,'Native EPUB display lost its first heading');
          Require(Pos('Вторая по spine',Form.BookText)>0,'Native EPUB display lost its second heading');
          Require(Pos('🌍',Form.BookText)>0,'Native EPUB display lost its Unicode emoji');
        end;
        if Name='sample.docx' then
        begin
          Chapters:=ChapterSelector(Form); Require(Assigned(Chapters),'Chapter selector missing');
          Chapters.SetFocus; Chapters.DroppedDown:=True; Chapters.ItemIndex:=1;
          Chapters.OnChange(Chapters);
          Require(Chapters.Focused and Chapters.DroppedDown,'Changing chapter closed the selector before confirmation');
          Require(Pos('Вторая',Copy(Form.BookText,Form.TextPosition+1,30))=1,'Selector did not navigate to chapter');
          Chapters.DroppedDown:=False; Form.GoToChapter(0);
          Writeln('PASS chapter selection keeps native combo focus and dropdown');
        end;
        Position:=Form.TextPosition; Watch:=TStopwatch.StartNew;
        Form.NextPage;
        Require(Form.TextPosition>Position,'Next page did not move');
        Writeln('PROFILE reader ',Name,' next_page_ms=',Watch.ElapsedMilliseconds);
        Form.PreviousPage; Require(Form.TextPosition=Position,'Previous page lost exact page');
        Form.ReadingSurface.Perform(WM_MOUSEWHEEL,WPARAM(Cardinal(Word(SmallInt(-120))) shl 16),0);
        Require(Form.TextPosition>Position,'Mouse wheel did not turn page');
        Position:=Form.TextPosition;
        Form.SetTypography('Arial',130,48);
        Require((Form.ReaderFontName='Arial') and (Form.ReaderLinePercent=130) and (Form.ReaderMargin=48),'Typography settings not applied');
        Require(Form.TextPosition=Position,'Typography change lost reading position');
        Form.ToggleNight;
        Require(ColorToRGB(Form.PageBackground)=$00222222,'Night page remained white');
        Require(Form.TextPosition=Position,'Night mode lost reading position');
        Form.ToggleNight;
        Require(ColorToRGB(Form.PageBackground)=$00F4F7FB,'Day page background not restored');
        Form.ChangeSize(1); Require(Form.ReaderFontSize=15,'Font size did not change');
        Require(Form.TextPosition=Position,'Font change lost reading position');
        Form.AddBookmark; Form.NextPage; Form.GoToBookmark(0);
        Require(Form.TextPosition=Position,'Bookmark navigation lost exact position');
        Form.SetBounds(80,100,760,560); Application.ProcessMessages; Form.Close;
      finally Form.Free; end;
      Require(THashSHA2.GetHashStringFromFile(Name)=BeforeHash,'Source book changed');
      Form:=TfrmBuiltinReader.Create(nil);
      try
        Form.Show; Form.OpenBook(Name,Name,Identity,'reader-test.ini','pdfium.dll'); WaitReady(Form);
        Require(Form.TextPosition=Position,'Reading position not restored');
        Require(Form.ReaderFontSize=15,'Font size not restored');
        Require((Form.ReaderFontName='Arial') and (Form.ReaderLinePercent=130) and (Form.ReaderMargin=48),'Typography not restored');
        Require((Form.Width=760) and (Form.Height=560),'Window size not restored'); Form.Close;
      finally Form.Free; end;
      // Keep each fixture independent when testing the default font above.
      Ini:=TMemIniFile.Create('reader-test.ini',TEncoding.UTF8);
      try Ini.WriteInteger('Reader','FontSize',14); Ini.UpdateFile; finally Ini.Free; end;
    end;
    for Name in ['sample.fb2','sample-webp.fb2','sample.epub','generated-image.rtf'] do
    begin
      Form:=TfrmBuiltinReader.Create(nil);
      try
        Form.OpenBook(Name,Name,'open-before-show-'+Name,'reader-test.ini','pdfium.dll');
        Form.Show; WaitReady(Form);
        Require(Form.PictureCount=1,'Opening before showing the form lost its illustration');
        Form.SetBounds(70,80,640,440); Application.ProcessMessages;
        Form.SetTypography('Georgia',110,48);
        Require(Form.PictureCount=1,'Window resize lost illustration after opening before show');
        Form.Perform(WM_KEYDOWN,VK_F11,0); Form.Perform(WM_KEYDOWN,VK_F11,0);
        Require(Form.PictureCount=1,'Fullscreen lost illustration');
        Form.Close;
      finally Form.Free; end;
    end;
    Writeln('PASS pictures survive opening before show, resize and fullscreen');
    Application.ProcessMessages; GdiFlush;
    GDIInitial:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS);
    UserInitial:=GetGuiResources(GetCurrentProcess,GR_USEROBJECTS);
    FormsInitial:=Screen.FormCount;
    Writeln('PROFILE reader lifecycle initial GDI=',GDIInitial,' USER=',UserInitial,' forms=',FormsInitial);
    LogReaderWindows;
    for Cycle:=1 to 384 do
    begin
      case Cycle mod 3 of
        0: Name:='sample.fb2';
        1: Name:='sample.epub';
        2: Name:='generated-image.rtf';
      end;
      Form:=TfrmBuiltinReader.Create(nil);
      try
        Form.OpenBook(Name,Name,'cycle-'+Name,'reader-test.ini','pdfium.dll');
        Form.Show; WaitReady(Form);
        Require(Form.PictureCount=1,'Repeated opening lost its illustration');
        Form.SetBounds(60,70,640,440); Form.SetTypography('Georgia',110,32);
        Form.NextPage; Form.PreviousPage; Form.Close;
      finally Form.Free; end;
      Application.ProcessMessages;
      // Log the initial phase separately; check bounded objects after the extended lifecycle loop.
      if Cycle=288 then
      begin
        DrainReaderCleanup; GdiFlush; GDIInitial:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS);
        // Windows/VCL initializes bounded IME and message-window caches during
        // the first opens. Measure 96 further opens after 288 warm-up cycles;
        // a short final batch can confuse delayed system initialization with a leak.
        Require(GetGuiResources(GetCurrentProcess,GR_USEROBJECTS)<=Cardinal(UserInitial+64),'Reader window warm-up exceeded budget');
        UserInitial:=GetGuiResources(GetCurrentProcess,GR_USEROBJECTS); LogReaderWindows;
      end;
      Writeln('PROFILE reader lifecycle cycle=',Cycle,' GDI=',GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS),
        ' USER=',GetGuiResources(GetCurrentProcess,GR_USEROBJECTS),' forms=',Screen.FormCount);
    end;
    DrainReaderCleanup; GdiFlush;
    Require(Screen.FormCount=FormsInitial,'Closing reader leaked its hidden formatting form');
    Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=GDIInitial+2,'Repeated reader opens leaked GDI objects');
    LogReaderWindows;
    Require(GetGuiResources(GetCurrentProcess,GR_USEROBJECTS)<=Cardinal(UserInitial+2),'Repeated reader opens leaked window objects');
    Writeln('PASS 384 repeated illustrated reader opens release forms; last batch of 96 keeps GDI and USER bounded');
    Form:=TfrmBuiltinReader.Create(nil);
    try
      Form.Show; Form.OpenBook('sample.fb2','Find','find','reader-test.ini','pdfium.dll'); WaitReady(Form);
      Watch:=TStopwatch.StartNew; Form.FindText('текст второй главы');
      Require(Pos('Текст второй главы',Copy(Form.BookText,Form.TextPosition+1,40))=1,'Unicode native search position wrong after image');
      Writeln('PROFILE native text search_ms=',Watch.ElapsedMilliseconds);
      Form.FindText('ПЕРВАЯ ГЛАВА');
      Require(Pos('Первая глава',Copy(Form.BookText,Form.TextPosition+1,40))=1,'Native search failed case-insensitive wrap');
      Position:=Form.TextPosition; Form.FindText('DefinitelyAbsentQuery');
      Require((Form.TextPosition=Position) and (Form.ReaderStatus.Caption='Текст не найден.'),'Absent search moved reading position'); Form.Close;
    finally Form.Free; end;
    Writeln('PASS native reflow reader turns pages and wheel, preserves position through font changes and restores window and font');
    Flush(Output);
    Form:=TfrmBuiltinReader.Create(nil);
    try
      Form.Show; Form.SetBounds(60,60,520,360);
      Form.OpenBook('large-image.fb2','Tall picture','large-image','reader-test.ini','pdfium.dll'); WaitReady(Form);
      Form.SetBounds(60,60,520,360); Application.ProcessMessages;
      Form.SetTypography('Georgia',110,48);
      Require(Form.PictureCount=1,'Tall image missing after viewport change');
      Position:=Form.TextPosition; Form.NextPage;
      Require(Form.TextPosition>Position,'Tall picture prevents reading next page'); Form.Close;
    finally Form.Free; end;
    Writeln('PASS tall inline image fits small reader window and does not prevent pagination');
    PDF:=TReaderPDF.Create('pdfium.dll','sample.pdf');
    try
      Require(PDF.PageCount=3,'PDF page count incorrect'); Watch:=TStopwatch.StartNew;
      Require(Length(PDF.Chapters)=2,'PDF outline missing');
      Require(PDF.Chapters[1].Page=2,'PDF outline destination changed');
      Require(PDF.FindOnPage(1,'Needle',0,PDFMatch),'PDF text match missing');
      Require((PDFMatch.Index>=0) and (PDFMatch.Count=6) and (Length(PDFMatch.Rects)>0),'PDF text match boxes missing');
      Require(not PDF.FindOnPage(0,'Needle',0,PDFMatch),'PDF text match falsely found on scan page');
      Bitmap:=PDF.Render(1,640,800);
      try
        Require(Bitmap.Width=640,'PDF bitmap width incorrect');
        Require(ColorToRGB(Bitmap.Canvas.Pixels[100,150])=$00CC6666,'PDF upper image color or orientation changed');
        Require(ColorToRGB(Bitmap.Canvas.Pixels[100,710])=$00FFFFFF,'PDF bottom margin orientation changed');
      finally Bitmap.Free; end;
      Writeln('PROFILE PDF render_ms=',Watch.ElapsedMilliseconds);
      Bitmap:=PDF.Render(1,640,800,True);
      try Require(ColorToRGB(Bitmap.Canvas.Pixels[20,20])=$00222222,'PDF night paper remained white');
      finally Bitmap.Free; end;
      GDIInitial:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS);
      for Position:=1 to 30 do
      begin
        Bitmap:=PDF.Render(Position mod 3,320,480,Position mod 2=1);
        try Bitmap.Canvas.Rectangle(10,10,30,30); finally Bitmap.Free; end;
      end;
      GdiFlush;
      Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=GDIInitial+2,'Repeated PDF renders leaked GDI handles');
      Writeln('PASS PDF raster orientation, colors and repeated render handle cleanup');
    finally PDF.Free; end;
    BeforeHash:=THashSHA2.GetHashStringFromFile('sample.pdf'); Progress:=-1;
    Form:=TfrmBuiltinReader.Create(nil);
    try
      Form.Show; Form.OpenBook('sample.pdf','PDF','reader-pdf','reader-test.ini','pdfium.dll',
        procedure(Value: Integer) begin Progress:=Value; end);
      Require(Form.Ready and (Form.TextLength=3),'PDF form not ready');
      Require(Form.ChapterCount=2,'PDF form lost contents');
      Form.GoToChapter(1); Require(Form.TextPosition=2,'PDF contents navigation failed');
      Form.GoToChapter(0); Require(Form.TextPosition=0,'PDF contents navigation to first page failed');
      Form.FindText('Needle'); Watch:=TStopwatch.StartNew;
      while Form.SearchRunning and (Watch.ElapsedMilliseconds<5000) do Application.ProcessMessages;
      Require(not Form.SearchRunning and (Form.TextPosition=1),'PDF progressive text search failed');
      Form.FindText('absent'); Form.StopSearch; Require(not Form.SearchRunning,'PDF search cancellation failed');
      Form.PreviousPage;
      Form.NextPage; Require(Form.TextPosition=1,'PDF next page failed');
      Form.ChangeSize(1); Require(Form.PDFZoom=110,'PDF zoom failed');
      Require(Form.TextPosition=1,'PDF zoom lost page');
      Form.ToggleNight; Require(ColorToRGB(Form.PageBackground)=$00222222,'PDF form night page remained white');
      Form.ToggleNight; Require(ColorToRGB(Form.PageBackground)=$00FFFFFF,'PDF form day page not restored');
      Form.SetBounds(0,0,4096,2160); Form.ChangeSize(20); Raster:=Form.PageRasterSize;
      Require((Form.PDFZoom=300) and (Int64(Raster.X)*Raster.Y<=25000000),'High PDF zoom exceeds page raster budget');
      Require(Form.TextPosition=1,'High PDF zoom changed page');
      Writeln('PASS PDF 4K viewport at 300% raster=',Raster.X,'x',Raster.Y);
      Form.SetBounds(80,100,760,560); Form.Close;
      Require(Progress=67,'PDF reading progress incorrect');
    finally Form.Free; end;
    Require(THashSHA2.GetHashStringFromFile('sample.pdf')=BeforeHash,'PDF source changed');
    Writeln('PASS PDF uses separate page zoom, text search with boxes, outline navigation and cancellation; preserves progress and source');
    for Name in ['broken.fb2','internal-dtd.fb2'] do
    begin
      Form:=TfrmBuiltinReader.Create(nil);
      try
        Form.Show; Form.OpenBook(Name,Name,'bad-'+Name,'reader-test.ini','pdfium.dll');
        Watch:=TStopwatch.StartNew;
        while not Form.LoadFinished and (Watch.ElapsedMilliseconds<5000) do
        begin Application.ProcessMessages; CheckSynchronize(5); end;
        Require(Form.LoadFinished and not Form.Ready,'Malformed XML did not fail safely'); Form.Close;
      finally Form.Free; end;
    end;
    Form:=TfrmBuiltinReader.Create(nil);
    try Form.Show; Form.OpenBook('empty.txt','Empty','empty','reader-test.ini','pdfium.dll'); WaitReady(Form); Form.Close;
    finally Form.Free; end;
    PDF:=nil;
    try
      try PDF:=TReaderPDF.Create('pdfium.dll','broken.pdf'); Require(False,'Broken PDF accepted');
      except on E: Exception do Require(Pos('PDF',E.Message)>0,'Unexpected malformed PDF error'); end;
    finally PDF.Free; end;
    Progress:=-1; Form:=TfrmBuiltinReader.Create(nil);
    try
      Form.Show; Form.OpenBook('sample.fb2','No move','no-move','reader-test.ini','pdfium.dll',
        procedure(Value: Integer) begin Progress:=Value; end); WaitReady(Form); Form.Close;
      Require(Progress=-1,'Opening without reading reset existing progress');
    finally Form.Free; end;
    Writeln('PASS malformed XML, forbidden internal DTD and PDF fail safely; empty text and Unicode emoji supported; unopened progress preserved');
    Form:=TfrmBuiltinReader.Create(nil);
    try Form.Show; Form.OpenBook('sample.fb2','Cancel','cancel-load','reader-test.ini','pdfium.dll'); Form.Close;
    finally Form.Free; end;
    Writeln('PASS closing experimental reader during background load is safe');
    Form:=TfrmBuiltinReader.Create(nil);
    try
      Form.Show; Form.OpenBook('nospace.txt','No spaces','nospace','reader-test.ini','pdfium.dll'); WaitReady(Form);
      Form.FindText('БЕЗПРОБЕЛОВКОНЕЦ'); Position:=Form.TextPosition;
      Require(Position=20000,'Unspaced Unicode search lost its character offset');
      Form.PreviousPage;
      Require(Form.TextPosition<Position,'Previous page cannot leave an unspaced paragraph');
      Position:=Form.TextPosition; Form.NextPage;
      Require(Form.TextPosition>Position,'Unspaced Unicode page cannot advance');
      Form.Close;
    finally Form.Free; end;
    Writeln('PASS previous page moves through long unspaced Unicode paragraphs');
    Form:=TfrmBuiltinReader.Create(nil);
    try
      Form.Show; Form.OpenBook('nospace-emoji.txt','No spaces emoji','nospace-emoji','reader-test.ini','pdfium.dll'); WaitReady(Form);
      Form.FindText('БЕЗПРОБЕЛОВКОНЕЦ'); Position:=Form.TextPosition;
      Require(Position=20000,'Unspaced emoji search lost its UTF-16 offset');
      Form.PreviousPage;
      Require(Form.TextPosition<Position,'Previous page cannot leave an unspaced emoji paragraph');
      Name:=Form.BookText;
      Require(not ((Ord(Name[Form.TextPosition+1])>=$DC00) and
        (Ord(Name[Form.TextPosition+1])<=$DFFF)),'Previous page splits a Unicode surrogate pair');
      Form.Close;
    finally Form.Free; end;
    Writeln('PASS unspaced emoji pagination preserves Unicode surrogate pairs');
    Doc:=TReaderDocument.Create; CancelChecks:=0;
    try
      try
        Doc.Load('cancel-large.txt',function: Boolean
          begin Inc(CancelChecks); Result:=CancelChecks>=5; end);
        Require(False,'Large TXT ignored cancellation during RTF encoding');
      except on E: EAbort do Require(CancelChecks>=5,'Cancellation was not polled'); end;
    finally Doc.Free; end;
    Writeln('PASS large TXT conversion polls cancellation');
    Ini:=TMemIniFile.Create('reader-placement.ini',TEncoding.UTF8);
    try
      Ini.WriteInteger('Reader','Left',80); Ini.WriteInteger('Reader','Top',100);
      Ini.WriteInteger('Reader','Width',760); Ini.WriteInteger('Reader','Height',560); Ini.UpdateFile;
    finally Ini.Free; end;
    Form:=TfrmBuiltinReader.Create(nil);
    try
      // The real main window opens the book before ShowModal.
      Form.OpenBook('sample.txt','Placement','placement','reader-placement.ini','pdfium.dll');
      Form.Show; WaitReady(Form);
      Require(Form.ReadingSurface.Focused,'Reading surface is not focused at first show');
      Position:=Form.TextPosition;
      SendMessage(Form.ReadingSurface.Handle,WM_KEYDOWN,VK_NEXT,0); Application.ProcessMessages;
      Require(Form.TextPosition>Position,'First focused PageDown did not turn page');
      Require((Form.Left=80) and (Form.Top=100),'Reader opened before Show did not restore its saved position');
      Require((Form.Width=760) and (Form.Height=560),'Reader opened before Show did not restore its saved size');
      Form.SetBounds(96,112,780,580); Application.ProcessMessages;
      Form.WindowState:=wsMaximized; Application.ProcessMessages;
      SendMessage(Form.Handle,WM_KEYDOWN,VK_F11,0); Application.ProcessMessages;
      SendMessage(Form.Handle,WM_KEYDOWN,VK_F11,0); Application.ProcessMessages;
      Require(Form.WindowState=wsMaximized,'Leaving fullscreen lost maximized state');
      Form.WindowState:=wsMinimized; Application.ProcessMessages; Form.Close;
    finally Form.Free; end;
    Ini:=TMemIniFile.Create('reader-placement.ini',TEncoding.UTF8);
    try
      Require((Ini.ReadInteger('Reader','Width',0)=780) and
        (Ini.ReadInteger('Reader','Height',0)=580),'Maximized or minimized reader overwrote normal window size');
      Require((Ini.ReadInteger('Reader','Left',0)=96) and
        (Ini.ReadInteger('Reader','Top',0)=112),'Maximized or minimized reader overwrote normal window position');
    finally Ini.Free; end;
    Writeln('PASS reader opened before Show restores position and saves normal bounds through move, maximize, fullscreen and minimize');
    Writeln('PASS experimental built-in reader native regressions');
  except
    on E: Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); Flush(Output); Halt(1); end;
  end;
  CoUninitialize;
end.
