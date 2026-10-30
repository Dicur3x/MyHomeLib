type
  TLookupReader = class(TfrmBuiltinReader)
  public
    OpenedTarget, OpenedParameters, OpenedDirectory: string;
    OpenCount: Integer;
    function LaunchDictionaryProbe: Boolean;
  protected
    function OpenLookupTarget(const Target, Parameters, WorkingDirectory: string): Boolean; override;
  end;

function TLookupReader.OpenLookupTarget(const Target, Parameters, WorkingDirectory: string): Boolean;
begin
  Inc(OpenCount); OpenedTarget:=Target; OpenedParameters:=Parameters;
  OpenedDirectory:=WorkingDirectory; Result:=True;
end;

function TLookupReader.LaunchDictionaryProbe: Boolean;
begin Result:=inherited OpenLookupTarget(OpenedTarget,OpenedParameters,OpenedDirectory); end;

procedure AuditReaderLookup;
var Reader: TLookupReader; Ini: TMemIniFile; Dictionary, Web, Google, Yandex: TMenuItem;
  Popup: TPopupMenu; App, FileName, Query, Expected, BeforeHash: string; Watch: TStopwatch; Position: Integer;
begin
  Query:='Привет café 😀 / # & ? + " \ --help';
  for var Target in [rltDictionary,rltGoogle,rltYandex] do
  begin
    Expected:=ReaderLookupURL(Query,Target);
    Require(Expected<> '','Unicode lookup URL missing');
    if Target=rltDictionary then Expected:=Copy(Expected,Length('goldendict:///')+1,MaxInt)
    else Expected:=Copy(Expected,Pos('=',Expected)+1,MaxInt);
    Require(TNetEncoding.URL.Decode(Expected)=Query,'Lookup UTF-8/URI punctuation changed');
    Require((Pos(' ',Expected)=0) and (Pos('#',Expected)=0) and (Pos('&',Expected)=0),
      'Selected text became URL structure or another argument');
    Require(ReaderLookupURL(StringOfChar('x',513),Target)='','Long selection was silently truncated or sent');
    Require(ReaderLookupURL(#13#10#9,Target)='','Blank selection was sent');
  end;
  Require(ReaderLookupText('  café'+#13#10+#9+'Привет  ')='café Привет','Whitespace normalization changed text');
  Require(ReaderLookupURL('--help',rltDictionary)='goldendict:///--help','Dictionary word became command option');
  Writeln('PASS lookup keeps Unicode punctuation and flag-like words as one encoded query without truncation');
  App:=TPath.Combine(GetCurrentDir,'Словарь [test]\goldendict.exe');
  ForceDirectories(ExtractFileDir(App)); TFile.Copy(ParamStr(0),App,True);
  Require(FindReaderDictionary('"'+App+'"')=App,'Explicit dictionary path with spaces/brackets was not used');
  Ini:=TMemIniFile.Create('lookup.ini',TEncoding.UTF8);
  try Ini.WriteString('Reader','DictionaryExecutable',App); Ini.UpdateFile; finally Ini.Free; end;
  for FileName in ['words.txt','words.pdf'] do
  begin
    BeforeHash:=THashSHA2.GetHashStringFromFile(FileName); Reader:=TLookupReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook(FileName,'Lookup',FileName,'lookup.ini','pdfium.dll'); WaitReady(Reader);
      Dictionary:=Reader.FindComponent('ReaderDictionaryLookup') as TMenuItem;
      Web:=Reader.FindComponent('ReaderWebLookup') as TMenuItem;
      Google:=Reader.FindComponent('ReaderGoogleLookup') as TMenuItem;
      Yandex:=Reader.FindComponent('ReaderYandexLookup') as TMenuItem;
      Require(Assigned(Dictionary) and Assigned(Web) and Assigned(Google) and Assigned(Yandex),'Lookup menu is incomplete');
      Require((Web.Count=2) and (Google.Parent=Web) and (Yandex.Parent=Web) and
        (Google.Caption='Google') and (Yandex.Caption='Яндекс'),'Web engines are not two explicit submenu choices');
      Require(Dictionary.Parent<>Web,'Dictionary was conflated with web search');
      Popup:=Dictionary.GetParentMenu as TPopupMenu; Popup.OnPopup(Popup);
      Require(not Dictionary.Enabled and not Web.Enabled,'Lookup without selection should be disabled');
      Dictionary.OnClick(Dictionary); Google.OnClick(Google); Yandex.OnClick(Yandex);
      Require(Reader.OpenCount=0,'Blank lookup opened an application');
      Reader.SetSelectionEnabled(True);
      if FileName='words.pdf' then begin Reader.SelectPDFText(0,6); Query:='Needle'; end
      else begin Query:='Привет'; Position:=Pos(Query,Reader.BookText)-1; Reader.SelectText(Position,Length(Query)); end;
      Require(Reader.SelectedText=Query,'Lookup fixture selected different text');
      for var Theme in [1,4] do
      begin
        Reader.SetTheme(Theme); WaitPage(Reader);
        if FileName='words.pdf' then Reader.SelectPDFText(0,6) else Reader.SelectText(Position,Length(Query));
        Popup.OnPopup(Popup); Require(Dictionary.Enabled and Web.Enabled,'Selected lookup is unavailable');
        Google.OnClick(Google);
        Require((Reader.OpenedTarget=ReaderLookupURL(Query,rltGoogle)) and (Reader.OpenedParameters=''),
          'Google menu sent another query or executable argument');
        Yandex.OnClick(Yandex);
        Require((Reader.OpenedTarget=ReaderLookupURL(Query,rltYandex)) and (Reader.OpenedParameters=''),
          'Yandex menu sent another query or executable argument');
        Dictionary.OnClick(Dictionary);
        Expected:=QuoteCommandLineArgument(ReaderLookupURL(Query,rltDictionary));
        Require((Reader.OpenedTarget=App) and (Reader.OpenedParameters=Expected) and
          (Reader.OpenedDirectory=ExtractFileDir(App)),'Dictionary menu lost selected app or exact query');
        Require(Reader.SelectedText=Query,'Lookup changed text selection');
      end;
      if FileName='words.txt' then
      begin
        Require(Reader.LaunchDictionaryProbe,'Actual dictionary process could not start');
        Watch:=TStopwatch.StartNew;
        while not FileExists(ExtractFileDir(App)+'\received.txt') and (Watch.ElapsedMilliseconds<10000) do
        begin Application.ProcessMessages; CheckSynchronize(5); end;
        Require(FileExists(ExtractFileDir(App)+'\received.txt'),'Dictionary child did not receive the URI');
        Require(TFile.ReadAllText(ExtractFileDir(App)+'\received.txt',TEncoding.UTF8)=
          '1'+#10+ReaderLookupURL(Query,rltDictionary),'Windows split or changed the dictionary argument');
      end;
      Reader.Close;
    finally Reader.Free; end;
    Require(THashSHA2.GetHashStringFromFile(FileName)=BeforeHash,'Lookup modified book bytes');
  end;
  Writeln('PASS context lookup has separate dictionary and Google/Yandex submenu in text and PDF light/dark themes');
  Writeln('PASS configured dictionary survives reopening and Windows receives one exact URI argument');
end;
