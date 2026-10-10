program BuiltinReaderAudit;
{$APPTYPE CONSOLE}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}

uses NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  System.Diagnostics, System.Hash, System.IniFiles, Winapi.Windows, Winapi.Messages, Winapi.ActiveX,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.Graphics, System.Types, unit_ReaderDocument, unit_ReaderPDF, frm_BuiltinReader,
  unit_ReaderFormats, unit_Globals, unit_ReaderCache, unit_BookCache, dm_user;

procedure Require(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;

procedure WaitReady(Form: TfrmBuiltinReader);
var Watch: TStopwatch;
begin
  Watch:=TStopwatch.StartNew;
  while not Form.LoadFinished and (Watch.ElapsedMilliseconds<15000) do
  begin Application.ProcessMessages; CheckSynchronize(5); end;
  Require(Form.Ready,'Reader not ready: '+Form.ReaderStatus.Caption);
end;

function ChapterSelector(Control: TWinControl): TComboBox;
var I: Integer;
begin
  Result:=nil;
  for I:=0 to Control.ControlCount-1 do
  begin
    if (Control.Controls[I] is TComboBox) and (Control.Controls[I].Hint='Содержание книги') then Exit(TComboBox(Control.Controls[I]));
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
  Key: Word;
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
      Require(Pos('Найдено',Reader.ReaderStatus.Caption)>0,'PDF UI search missing');
      B.SetSize(A.Width,A.Height); Reader.ReadingSurface.PaintTo(B.Canvas.Handle,0,0); B.SaveToFile('oct10-pdf-highlight.bmp');
      Require(THashSHA2.GetHashStringFromFile('oct10-pdf-before.bmp')<>
        THashSHA2.GetHashStringFromFile('oct10-pdf-highlight.bmp'),'PDF highlights invisible');
      Reader.FindText('absent');
      while Reader.SearchRunning do begin Application.ProcessMessages; CheckSynchronize(5); end;
      Require(Pos('не найден',Reader.ReaderStatus.Caption)>0,'PDF no-result not reported');
      Reader.Close;
    finally B.Free; A.Free; Reader.Free; end;
    Writeln('PASS PDF search word/case/previous/all and centered fitted-page drag');
  finally DMUser.Free; DMUser:=nil; end;
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
      if ParamStr(1)='oct10-reader' then AuditOctoberReader
      else if ParamStr(1)='document-spacing' then AuditDocumentSpacing
      else if ParamStr(1)='pdf-current-page-search' then AuditPDFSearch
      else AuditNavigation(ParamStr(1));
      Writeln('PASS experimental built-in reader native regressions');
      CoUninitialize; Halt(0);
    end;
    if FileExists(ExtractFilePath(ParamStr(0))+'reader-preview.txt') then
    begin
      Name:=Trim(TFile.ReadAllText(ExtractFilePath(ParamStr(0))+'reader-preview.txt',TEncoding.UTF8));
      Name:=ExtractFilePath(ParamStr(0))+ExtractFileName(Name);
      Writeln('PREVIEW create'); Flush(Output);
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
      if Cycle=72 then begin GdiFlush; GDIInitial:=GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS); LogReaderWindows; end;
      Writeln('PROFILE reader lifecycle cycle=',Cycle,' GDI=',GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS),
        ' USER=',GetGuiResources(GetCurrentProcess,GR_USEROBJECTS),' forms=',Screen.FormCount);
    end;
    GdiFlush;
    Require(Screen.FormCount=FormsInitial,'Closing reader leaked its hidden formatting form');
    Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=GDIInitial+2,'Repeated reader opens leaked GDI objects');
    LogReaderWindows;
    Require(GetGuiResources(GetCurrentProcess,GR_USEROBJECTS)<=Cardinal(UserInitial+2),'Repeated reader opens leaked window objects');
    Writeln('PASS 384 repeated illustrated reader opens release forms; extended lifecycle keeps GDI and USER bounded');
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
