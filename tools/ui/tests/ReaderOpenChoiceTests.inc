type
  TReaderOpenChoiceDriver = class
    Timer: TTimer;
    Reader: TfrmBuiltinReader;
    ExpectedTheme: Integer;
    Accept, Seen: Boolean;
    Error: string;
    procedure Respond(Sender: TObject);
  end;

procedure TReaderOpenChoiceDriver.Respond(Sender: TObject);
var Dialog: TCustomForm; List: TListBox; Remember: TCheckBox;
begin
  Dialog:=nil;
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Caption='Где открыть книгу?' then
      begin Dialog:=Screen.Forms[I]; Break; end;
  if not Assigned(Dialog) then Exit;
  Timer.Enabled:=False; Seen:=True; List:=nil; Remember:=nil;
  Writeln('TRACE reader choice timer found modal'); Flush(Output);
  try
    Require((Reader.ThemeIndex=ExpectedTheme) and
      (Reader.Color=ReaderThemeBackground(ExpectedTheme)),
      'Open-book choice changed the independent reading theme');
    Require(Dialog.Color=MHLThemeBackground,
      'Open-book choice inherited reader or system colours instead of catalogue colours');
    Require(Dialog.Font.Color=MHLThemeText,'Open-book choice text has the wrong palette');
    for var I:=0 to Dialog.ControlCount-1 do
    begin
      if Dialog.Controls[I] is TListBox then List:=TListBox(Dialog.Controls[I]);
      if Dialog.Controls[I] is TCheckBox then Remember:=TCheckBox(Dialog.Controls[I]);
    end;
    Require(Assigned(List) and Assigned(Remember),'Open-book choice controls are missing');
    Require((List.Items.Count>0) and (List.Items[0]='HomeLibre Reader'),
      'Open-book choice lost the available reader');
    Require(List.Font.Color=MHLThemeText,'Open-book choice list text is unreadable');
    if MHLThemeDark then Require(List.Color=RGB(30,31,34),'Dark catalogue choice list is white')
    else Require(List.Color=clWindow,'Light catalogue choice list retained dark reader colours');
    List.ItemIndex:=0; Remember.Checked:=Accept;
    if Accept then Dialog.ModalResult:=mrOk else Dialog.ModalResult:=mrCancel;
  except
    on E: Exception do begin Error:=E.Message; Dialog.ModalResult:=mrCancel; end;
  end;
end;

procedure TestReaderOpenChoice;
var Driver: TReaderOpenChoiceDriver; Reader: TfrmBuiltinReader; Host: TfrmReaderHost;
  SavedDark, Builtin, Accepted: Boolean; Path, Choice: string; Ini: TMemIniFile;
begin
  RequireIsolatedRegression; SavedDark:=MHLThemeDark;
  Driver:=TReaderOpenChoiceDriver.Create; Reader:=nil; Host:=nil;
  try
    Reader:=TfrmBuiltinReader.Create(nil); Driver.Reader:=Reader;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Respond;
    for var Dark in [False,True] do
    begin
      if Dark then Driver.ExpectedTheme:=1 else Driver.ExpectedTheme:=4;
      Reader.SetTheme(Driver.ExpectedTheme); SetMHLTheme(Dark);
      Require(Reader.ThemeIndex=Driver.ExpectedTheme,'Catalogue theme changed reading theme');
      Host:=TfrmReaderHost.Create(nil);
      try
        Require(Host.Color=MHLThemeBackground,'Open-book launcher does not use catalogue palette');
        for var Confirm in [False,True] do
        begin
          Driver.Accept:=Confirm; Driver.Seen:=False; Driver.Error:=''; Driver.Timer.Enabled:=True;
          Writeln('TRACE reader choice show catalogue_dark=',Ord(Dark),' accept=',Ord(Confirm)); Flush(Output);
          Accepted:=ChooseBookReader(nil,'test.fb2','.fb2',Builtin,Path,True);
          Driver.Timer.Enabled:=False;
          Require(Driver.Error='',Driver.Error);
          Require(Driver.Seen and (Accepted=Confirm),'Reader choice ignored accept or cancel');
          if Confirm then Require(Builtin and (Path=''),'Reader choice did not choose HomeLibre Reader');
          Ini:=TMemIniFile.Create(Settings.DataDir+'reader.ini',TEncoding.UTF8);
          try Choice:=Ini.ReadString('OpenWith','.fb2',''); finally Ini.Free; end;
          if Confirm then Require(Choice='@builtin','Reader choice was not remembered')
          else if not Dark then Require(Choice='','Cancel changed the remembered reader');
          Require((MHLThemeDark=Dark) and (Reader.ThemeIndex=Driver.ExpectedTheme),
            'Choosing a reader changed catalogue or reading theme');
        end;
      finally FreeAndNil(Host); end;
    end;
    Writeln('PASS catalogue open-book choice keeps catalogue colours while reading theme stays independent; accept cancel and remembered choice work');
  finally
    Driver.Timer.Free; Driver.Free; Host.Free; Reader.Free; SetMHLTheme(SavedDark);
  end;
end;

procedure TestEpubLineBreakRepair;
const RepairWarning = 'Исправлены теги переноса строки в EPUB для чтения.';
  SectionBody = '<h1>Chapter</h1><p>Before%sAfter</p><p><![CDATA[Literal <br>]]></p>'+
    '<!-- comment <br> --><p title="A > B">Last paragraph</p><img src="pixel.png"/>';
  Pixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg==';
var Folder, Original, Reference: string;

  procedure WriteBook(const FileName, Body: string);
  var Zip: TZipFile;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(FileName,zmWrite);
      Zip.Add(TEncoding.ASCII.GetBytes('application/epub+zip'),'mimetype',zcStored);
      Zip.Add(TEncoding.UTF8.GetBytes('<container><rootfiles><rootfile full-path="book.opf"/>'+
        '</rootfiles></container>'),'META-INF/container.xml');
      Zip.Add(TEncoding.UTF8.GetBytes('<package><metadata><title>EPUB line breaks</title></metadata>'+
        '<manifest><item id="section" href="chapter.html" media-type="application/xhtml+xml"/>'+
        '<item id="picture" href="pixel.png" media-type="image/png"/></manifest>'+
        '<spine><itemref idref="section"/></spine></package>'),'book.opf');
      Zip.Add(TEncoding.UTF8.GetBytes('<html xmlns="http://www.w3.org/1999/xhtml"><body>'+
        Body+'</body></html>'),'chapter.html');
      Zip.Add(TNetEncoding.Base64.DecodeStringToBytes(Pixel),'pixel.png');
    finally Zip.Free; end;
  end;

  procedure CheckPair(const Source, Control: string; RealBook: Boolean);
  var Actual, Expected: TReaderDocument; Reader: TfrmBuiltinReader;
    Hash: string; ActualChapters, ExpectedChapters: TArray<TReaderChapter>;
    Started: UInt64; WarningCount: Integer;
  begin
    Hash:=THashSHA2.GetHashStringFromFile(Source);
    Actual:=TReaderDocument.Create; Expected:=TReaderDocument.Create;
    try
      Actual.Load(Source); Expected.Load(Control);
      Require((Actual.Title=Expected.Title) and (Actual.PlainText=Expected.PlainText) and
        (Actual.ImageCount=Expected.ImageCount) and (Actual.RTF=Expected.RTF),
        'EPUB repair changed content, formatting, or pictures');
      ActualChapters:=Actual.Chapters; ExpectedChapters:=Expected.Chapters;
      Require(Length(ActualChapters)=Length(ExpectedChapters),'EPUB repair changed the chapter count');
      for var Index:=0 to High(ActualChapters) do
        Require((ActualChapters[Index].Title=ExpectedChapters[Index].Title) and
          (ActualChapters[Index].Position=ExpectedChapters[Index].Position) and
          (ActualChapters[Index].Depth=ExpectedChapters[Index].Depth),'EPUB repair changed navigation');
      WarningCount:=0;
      for var Warning in Actual.Warnings do
        if Warning=RepairWarning then Inc(WarningCount);
      Require((WarningCount=1) and (Expected.Warnings.IndexOf(RepairWarning)<0),
        'EPUB repair did not distinguish corrected and valid input');
      if not RealBook then
        Require(Actual.PlainText.Contains('Literal <br>') and (Actual.ImageCount=1),
          'EPUB repair changed literal CDATA or lost an inline image')
      else
      begin
        Require((Actual.PlainText.Length>100000) and (Length(ActualChapters)>100),
          Format('Reported EPUB fixture has only %d characters and %d chapters',
          [Actual.PlainText.Length,Length(ActualChapters)]));
        Reader:=TfrmBuiltinReader.Create(nil);
        try
          Reader.OpenBook(Source,Actual.Title,'epub-break-repair','','',nil);
          Reader.HandleNeeded;
          Started:=GetTickCount64;
          while not Reader.LoadFinished and (GetTickCount64-Started<30000) do
          begin Application.ProcessMessages; CheckSynchronize(5); Sleep(10); end;
          Require(Reader.Ready and (Reader.BookText.Length>100000),
            'The reading window did not present the repaired EPUB');
        finally Reader.Free; end;
        Writeln('PASS reported EPUB opens in reader, chapters=',Length(ActualChapters),
          ' images=',Actual.ImageCount,' text=',Actual.PlainText.Length,' sha256=',Hash);
      end;
      Require(THashSHA2.GetHashStringFromFile(Source)=Hash,'EPUB repair changed the source archive');
    finally Expected.Free; Actual.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Original:=TPath.Combine(Settings.AppPath,'epub-open-break.epub');
  Reference:=TPath.Combine(Settings.AppPath,'epub-closed-break.epub');
  WriteBook(Original,Format(SectionBody,['<br>']));
  WriteBook(Reference,Format(SectionBody,['<br/>']));
  CheckPair(Original,Reference,False);
  Writeln('PASS EPUB line break repair preserves contents and leaves valid markup unchanged');
  Folder:=GetEnvironmentVariable('HOMELIB_TEST_EPUB_LINE_BREAK_PAIR');
  if Folder<>'' then CheckPair(TPath.Combine(Folder,'source.epub'),TPath.Combine(Folder,'control.epub'),True);
end;

procedure TestExternalEpubPrompt(const Collection: IBookCollection);
var Book: TBookRecord; Key: TBookKey; Tree: TBookTree;
  Action: TAction; Prompt: TCustomForm; Reason: TMemo; Header: TLabel;
  Path, Digest, DisplayedReason: string; Deadline: UInt64;
begin
  RequireIsolatedRegression;
  var Reader:=Settings.Readers.Find('.epub');
  Require(Assigned(Reader) and (MissingExternalReaderComponent(Settings.AppPath,Reader.Path)='SumatraPDF'),
    'Clean EPUB profile did not assign the absent external SumatraPDF');
  Key:=CreateBookKey(AddBook(Collection,'external-epub-prompt','Fixture','ru','','0.1'),Collection.CollectionID);
  Collection.GetBookRecord(Key,Book,True);
  Book.FileExt:='.epub'; Collection.UpdateBook(Book);
  Path:=Book.GetBookFileName;
  TFile.Copy(TPath.Combine(Settings.AppPath,'epub-closed-break.epub'),Path);
  Digest:=UpdateSHA256(Path);
  Tree:=frmMain.tvBooksSR;
  ShowPage(PAGE_SEARCH);
  frmMain.FillBooksTree(Tree,nil,Collection.GetBookIterator(bmAll,False),False,False,@Key);
  Tree.FocusedNode:=Tree.GetFirstSelected;
  Require(Assigned(Tree.FocusedNode),'External EPUB prompt lost its selected catalogue book');
  Action:=frmMain.FindComponent('acReadExternal') as TAction;
  Require(Assigned(Action) and Assigned(Action.OnExecute),'External reader command is missing');
  Prompt:=nil; Reason:=nil;
  try
    Action.OnExecute(Action);
    Deadline:=GetTickCount64+10000;
    repeat
      Application.ProcessMessages; CheckSynchronize(5);
      for var I:=0 to Screen.FormCount-1 do
        if Screen.Forms[I].Visible and (Screen.Forms[I].Name='OptionalComponentPrompt') then
        begin
          Prompt:=Screen.Forms[I];
          Reason:=Prompt.FindComponent('ComponentPromptReason') as TMemo;
          Break;
        end;
    until Assigned(Reason) or (GetTickCount64>=Deadline);
    Require(Assigned(Reason),'Catalogue did not show the external reader installation prompt');
    Header:=Prompt.FindComponent('ComponentPromptTitle') as TLabel;
    Require(Assigned(Header),'External EPUB installation prompt has no title');
    Require(string(Header.Caption).Contains('PDF, EPUB и DjVu'),
      'SumatraPDF title does not include EPUB: '+Header.Caption);
    DisplayedReason:=Reason.Text;
    Require(DisplayedReason.Contains('Для внешнего открытия EPUB выбрана программа SumatraPDF.') and
      DisplayedReason.Contains('«Выбрать читалку…»') and DisplayedReason.Contains('«Настройки → Типы файлов»'),
      'External EPUB installation prompt lost its format, reader, or alternative');
  finally
    if Assigned(Prompt) then Prompt.Close;
  end;
  Require(UpdateSHA256(Path)=Digest,'External reading prompt changed the EPUB source');
  Writeln('PASS clean catalogue external EPUB command explains the SumatraPDF assignment and alternatives');
end;
