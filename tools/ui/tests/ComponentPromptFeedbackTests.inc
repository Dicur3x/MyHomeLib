type
  TReaderFormatsHelpProbe = class
    Seen: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TReaderFormatsHelpProbe.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I].Name='ReaderFormatsDialog') and Screen.Forms[I].Visible then
    begin
      TTimer(Sender).Enabled:=False; Seen:=True;
      var Dialog:=TForm(Screen.Forms[I]);
      var Text:=TMemo(Dialog.FindComponent('ReaderFormatsText'));
      Require(Assigned(Text) and Text.ReadOnly and (Text.ScrollBars=ssVertical),
        'Reader format help is not readable and scrollable');
      var Contents:string:=Text.Text;
      Require(Contents.Contains('DOCX, ODT') and Contents.Contains('вместе с читалкой') and
        Contents.Contains('PDF — PDFium') and Contents.Contains('DJVM — DjVuLibre') and
        Contents.Contains('DOC, DOT — DocSharp') and Contents.Contains('WPS, WPD — libwps/libwpd'),
        'Reader help lost native formats, module dependencies or update ownership');
      for var PPI in [96,144,192] do
      begin
        Dialog.ScaleForPPI(PPI);
        for var Control in Dialog do
          if Control is TControl then
            Require((TControl(Control).Left>=0) and (TControl(Control).Top>=0) and
              (TControl(Control).Left+TControl(Control).Width<=Dialog.ClientWidth) and
              (TControl(Control).Top+TControl(Control).Height<=Dialog.ClientHeight), 'Reader format help is clipped');
      end;
      Dialog.ModalResult:=mrOk; Exit;
    end;
end;

type
  TReaderAppearanceProbe = class
    Reader: TfrmBuiltinReader;
    Appearance: TForm;
    SawColors: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TReaderAppearanceProbe.Tick(Sender: TObject);
var Timer: TTimer; Dialog: TForm; Colors: TButton;
begin
  Timer:=TTimer(Sender);
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible then
    begin
      Dialog:=Screen.Forms[I];
      if (Dialog.Name='ReaderAppearanceDialog') and not Assigned(Appearance) then
      begin
        Appearance:=Dialog;
        Require((GetWindow(Dialog.Handle,GW_OWNER)=Reader.Handle) and IsWindowVisible(Dialog.Handle),
          'Appearance is not owned by the active reading window');
        Colors:=Dialog.FindComponent('ReaderThemeColors') as TButton;
        Require(Assigned(Colors) and Colors.Visible,'Theme colors are missing from Appearance');
        Colors.Click;
        Require(SawColors,'Theme colors did not open from Appearance');
        Appearance.ModalResult:=mrCancel;
        Exit;
      end;
      if Dialog.Name='ReaderThemeColorsDialog' then
      begin
        Timer.Enabled:=False;
        Require(GetWindow(Dialog.Handle,GW_OWNER)=Appearance.Handle,'Theme colors lost their Appearance window');
        var ColorBox:=Dialog.FindComponent('ReaderThemeProgressColor') as TColorBox;
        Require(Assigned(ColorBox),'The theme does not offer a progress color');
        ColorBox.Selected:=clAqua;
        var HeadingBox:=Dialog.FindComponent('ReaderThemeHeadingColor') as TColorBox;
        var SubheadingBox:=Dialog.FindComponent('ReaderThemeSubheadingColor') as TColorBox;
        Require(Assigned(HeadingBox) and Assigned(SubheadingBox),'Heading colors are outside the theme palette');
        HeadingBox.Selected:=clBlue; SubheadingBox.Selected:=clTeal;
        SawColors:=True;
        Dialog.ModalResult:=mrOk;
        Exit;
      end;
    end;
end;

procedure CheckColoredNestedChapterProgress(Reader: TfrmBuiltinReader);
var Bar: TPaintBox; Chapters: TComboBox; Picture: TBitmap; DC: HDC; Saved: HGDIOBJ;
  Fill: COLORREF; Marks, Spacing, X, LastMark, MarkCount: Integer;
begin
  Reader.GoToPosition(Reader.TextLength-1);
  Require(Reader.ReadingProgress=1,'Progress test did not reach the end');
  Bar:=Reader.FindComponent('ReaderProgressLine') as TPaintBox;
  Picture:=TBitmap.Create;
  try
    Picture.SetSize(Bar.Width,Bar.Height);
    DC:=CreateCompatibleDC(0);
    Win32Check(DC<>0);
    try
      Saved:=SelectObject(DC,Picture.Handle);
      try
        Bar.Perform(WM_PAINT,WPARAM(DC),0);
        Fill:=GetPixel(DC,Bar.Width div 2,Bar.Height-2);
        Require(Fill=ColorToRGB(clAqua),'The chosen progress color was not painted');
        Chapters:=Reader.FindComponent('ReaderChapterSelector') as TComboBox;
        Marks:=0;
        for var I:=0 to Chapters.Items.Count-1 do
        begin
          X:=MulDiv(Bar.Width-1,NativeInt(Chapters.Items.Objects[I]),Reader.TextLength);
          if Chapters.Items[I].Contains('Глубокая подглава') then
            Require(GetPixel(DC,X,0)=Fill,'A deeper heading cluttered the progress bar')
          else if Chapters.Items[I].Contains('Первая глава') or Chapters.Items[I].Contains('Вторая глава') then
          begin
            Require((GetPixel(DC,X,0)<>Fill) and (GetPixel(DC,X,Bar.Height*3 div 4)=Fill),
              'A nested chapter marker is missing or hidden on the filled progress bar: '+Chapters.Items[I]);
            Inc(Marks);
          end;
        end;
        Require(Marks=2,'Progress fixture did not supply its two nested chapters');
        Spacing:=MulDiv(24,Reader.CurrentPPI,96);
        LastMark:=-Spacing; MarkCount:=0;
        for X:=0 to Bar.Width-1 do
          if (GetPixel(DC,X,0)<>Fill) and ((X=0) or (GetPixel(DC,X-1,0)=Fill)) then
          begin
            Require(X-LastMark>=Spacing,'Adjacent progress marks are too close');
            LastMark:=X; Inc(MarkCount);
          end;
        Require((Chapters.Items.Count>100) and (MarkCount>5) and (MarkCount<=32),
          'Dense chapter marks were not reduced to a readable number');
      finally SelectObject(DC,Saved); end;
    finally DeleteDC(DC); end;
  finally Picture.Free; end;
end;

type
  TReaderDeferredChoicesProbe = class(TReaderPaletteCombo);

  TReaderColorChoiceProbe = class(TReaderPaletteColorBox)
  protected
    function PickCustomColor: Boolean; override;
  public
    Accept: Boolean;
    Picks: Integer;
    procedure PickFromList;
    procedure PickWithEnter;
  end;

function TReaderColorChoiceProbe.PickCustomColor: Boolean;
begin
  Inc(Picks);
  if Accept then Items.Objects[0]:=TObject(NativeInt(RGB(12,34,56)));
  Result:=Accept;
end;

procedure TReaderColorChoiceProbe.PickFromList;
begin
  DropDown; ItemIndex:=0; CloseUp; Select;
end;

procedure TReaderColorChoiceProbe.PickWithEnter;
var Key: Char;
begin
  ItemIndex:=0;
  Key:=#13;
  KeyPress(Key);
  Require(Key=#0,'The custom color key also activated Apply');
end;

procedure CheckReaderColorChoices;
var Form: TForm; Box: TReaderColorChoiceProbe; Choices: TReaderDeferredChoicesProbe; Key: Word;
begin
  Form:=TForm.CreateNew(nil);
  try
    Box:=TReaderColorChoiceProbe.Create(Form); Box.Parent:=Form;
    Box.Configure(clDefault);
    Require((Box.Items.Count=18) and (Box.Selected=clDefault),'Reader palette lost its automatic color or includes system colors');
    Box.PickFromList;
    Require((Box.Picks=1) and (Box.Selected=clDefault),'Canceling a custom color lost the current palette choice');
    Box.Accept:=True;
    Box.PickWithEnter;
    Require((Box.Picks=2) and (Box.Selected=RGB(12,34,56)),'Keyboard could not apply a custom color');
    Box.Configure(clBlack);
    Require((Box.ItemIndex>0) and (Box.Selected=clBlack),'A standard color was confused with the custom entry');
    Box.Configure(RGB(45,67,89));
    Require((Box.ItemIndex=0) and (Box.Selected=RGB(45,67,89)),'The saved custom color was not selected');
    Choices:=TReaderDeferredChoicesProbe.Create(Form); Choices.Parent:=Form;
    Choices.SetDeferredChoices('100'+#13+'110'+#13+'120','115');
    Require((Choices.Items.Count=1) and (Choices.Text='115'),'The deferred list lost the current custom value');
    Key:=VK_DOWN; Choices.KeyDown(Key,[]);
    Require((Choices.Items.Count=4) and (Choices.Text='115'),'Keyboard did not load all of the saved numeric choices');
    Choices.DropDown;
    Require((Choices.Items.Count=4) and (Choices.Text='115'),'Opening the list duplicated or changed its selected value');
  finally Form.Free; end;
end;

procedure TestComponentPromptFeedback;
var Dialog: TReaderModuleForm; Prompt: TForm; Memo: TMemo; Started: UInt64;
  Purpose, Reason, Displayed: string; Host: TfrmReaderHost; Probe: TReaderFormatsHelpProbe;
  Timer: TTimer; SavedDark: Boolean;
begin
  CheckReaderColorChoices;
  RequireIsolatedRegression;
  for var ID in ['BookProcessing','ImageProcessing'] do
    for var Context in [False,True] do
    begin
      Dialog:=TReaderModuleForm.Create(nil); Dialog.RequestedID:=ID;
      try
        Purpose:=ComponentPurpose(ID); Reason:=Purpose;
        if Context then Reason:='Для выбранной книги нужен этот модуль.'+sLineBreak+Purpose.Replace(#13,'');
        Dialog.RequestComponent(ID,Reason,True); Started:=GetTickCount64;
        repeat
          Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
          Prompt:=TForm(Dialog.FindComponent('OptionalComponentPrompt'));
        until (Assigned(Prompt) and TButton(Prompt.FindComponent('ComponentPromptDownload')).Enabled) or
          (GetTickCount64-Started>5000);
        Require(Assigned(Prompt),'Compact module prompt absent');
        Memo:=TMemo(Prompt.FindComponent('ComponentPromptReason'));
        Displayed:=string(Memo.Text).Replace(#13,''); Purpose:=Purpose.Replace(#13,'');
        var Start:=Pos(Purpose,Displayed);
        Require((Start>0) and (PosEx(Purpose,Displayed,Start+Length(Purpose))=0),
          'Module description is absent or repeated: '+ID);
        if Context then Require(Displayed.Contains('Для выбранной книги'),'Description removed operation context');
        var Size:=string(TLabel(Prompt.FindComponent('ComponentPromptBytes')).Caption);
        Require(Size='Нужно скачать: 128 Б','Small download size rounded to zero: '+Size);
        Require(Displayed.Contains('128 Б') and not Displayed.Contains('0.0 МБ') and not Displayed.Contains('0,0 МБ'),
          'Description disagrees with the download size');
        Require((Dialog.Requests.Count=2) and (Dialog.DownloadID=''),
          'Prompt checked unrelated modules or downloaded without consent');
        TButton(Prompt.FindComponent('ComponentPromptCancel')).Click;
      finally Dialog.Free; end;
    end;
  Writeln('PASS component prompts show purpose once preserve context and agree on small download sizes');
  Dialog:=TReaderModuleForm.Create(nil); Dialog.RequestedID:='BookProcessing';
  try
    Dialog.UseReaderComponents;
    Dialog.RequestComponent('BookProcessing','Directly opened book needs a module.',True);
    Application.ProcessMessages;
    Prompt:=TForm(Dialog.FindComponent('OptionalComponentPrompt'));
    Require(Assigned(Prompt) and Prompt.Visible and IsWindowVisible(Prompt.Handle),
      'Standalone Reader component prompt is hidden');
    Require((GetWindow(Prompt.Handle,GW_OWNER)=0) and
      ((GetWindowLongPtr(Prompt.Handle,GWL_EXSTYLE) and WS_EX_APPWINDOW)<>0),
      'Standalone Reader prompt is owned by the hidden launcher');
    TButton(Prompt.FindComponent('ComponentPromptCancel')).Click;
  finally Dialog.Free; end;
  Writeln('PASS standalone Reader module prompt has its own visible taskbar window');
  Host:=TfrmReaderHost.Create(nil); Probe:=TReaderFormatsHelpProbe.Create; Timer:=TTimer.Create(nil);
  SavedDark:=MHLThemeDark;
  try
    Timer.Enabled:=False; Timer.Interval:=80; Timer.OnTimer:=Probe.Tick;
    var Components:=TMenuItem(Host.Menu.FindComponent('ReaderComponentsMenu'));
    Require(Assigned(Components) and Assigned(Components.OnClick) and
      Assigned(Components.Parent) and (Components.Parent.Caption='Настройки'),
      'Reader component menu is outside Settings');
    var Item:=TMenuItem(Host.Menu.FindComponent('ReaderFormatsHelp'));
    Require(Assigned(Item) and Assigned(Item.OnClick) and Assigned(Item.Parent) and
      (Item.Parent.Caption='Помощь'),'Reader format list is outside Help');
    for var Dark in [False,True] do
    begin
      SetMHLTheme(Dark); Probe.Seen:=False; Timer.Enabled:=True; Item.Click;
      Require(Probe.Seen,'Reader formats help did not open');
    end;
  finally SetMHLTheme(SavedDark); Timer.Free; Probe.Free; Host.Free; end;
  Writeln('PASS reader formats help names native handlers and external updates with scrollable light dark 96 144 192 DPI dialog');
  var AppearanceProbe:=TReaderAppearanceProbe.Create;
  Timer:=TTimer.Create(nil);
  try
    AppearanceProbe.Reader:=TfrmBuiltinReader.Create(nil);
    AppearanceProbe.Reader.Show;
    var BookFile:=Settings.AppPath+'appearance-reader.fb2';
    var ProfileFile:=Settings.AppPath+'appearance-reader.ini';
    var Text:=StringOfChar('а',320);
    var Chapters:='';
    for var I:=1 to 120 do
      Chapters:=Chapters+'<section><title><p>Глава '+IntToStr(I)+'</p></title><p>Текст.</p></section>';
    TFile.WriteAllText(BookFile,'<FictionBook><body><section><title><p>Часть</p></title><p>'+Text+
      '</p><section><title><p>Первая глава</p></title><p>'+Text+'</p>'+
      '<section><title><p>Глубокая подглава</p></title><p>'+Text+'</p></section></section>'+
      '<section><title><p>Вторая глава</p></title><p>'+Text+'</p></section>'+Chapters+
      '</section></body></FictionBook>',TEncoding.UTF8);
    AppearanceProbe.Reader.OpenBook(BookFile,'Проверка оформления','appearance-reader',ProfileFile,'');
    Started:=GetTickCount64;
    while not AppearanceProbe.Reader.LoadFinished and (GetTickCount64-Started<5000) do
    begin Application.ProcessMessages; CheckSynchronize(2); Sleep(5); end;
    Require(AppearanceProbe.Reader.Ready,'The appearance fixture book did not open');
    Timer.Enabled:=False; Timer.Interval:=80; Timer.OnTimer:=AppearanceProbe.Tick;
    Timer.Enabled:=True;
    TButton(AppearanceProbe.Reader.FindComponent('ReaderAppearance')).Click;
    Require(AppearanceProbe.SawColors and AppearanceProbe.Reader.ReadingSurface.Focused,
      'Closing Appearance did not return to the reading surface');
    CheckColoredNestedChapterProgress(AppearanceProbe.Reader);
    AppearanceProbe.Reader.Close;
    var SavedProfile:=TMemIniFile.Create(ProfileFile,TEncoding.UTF8);
    try
      Require(SavedProfile.ReadInteger('Reader','ThemeProgress'+IntToStr(AppearanceProbe.Reader.ThemeIndex),clDefault)=ColorToRGB(clAqua),
        'The progress color was not saved for the active theme');
      var Prefix:='HeadingColor'+IntToStr(Ord(AppearanceProbe.Reader.ThemeIndex>=4))+'_';
      Require((SavedProfile.ReadInteger('Reader',Prefix+'0',clDefault)=ColorToRGB(clBlue)) and
        (SavedProfile.ReadInteger('Reader',Prefix+'1',clDefault)=ColorToRGB(clTeal)),
        'Heading colors were not saved after accepting the theme palette');
    finally SavedProfile.Free; end;
  finally
    Timer.Free; AppearanceProbe.Reader.Free; AppearanceProbe.Free;
  end;
  Writeln('PASS appearance and theme colors stay owned by their visible reader windows');
  Writeln('PASS sparse chapter marks stay visible without crowding on the selected and saved progress color');
end;

procedure TestDjvuFirstUseFeedback;
var Dialog:TReaderModuleForm; Prompt:TForm; Started:UInt64;
  Size,ExpectedSize,Adapter,Archive,Hash,Job,Target:string;
  Server:TRepairServer; Worker:TRepairWorker; Info:TProgramRelease;
  procedure CheckExistingExtractor;
  var Root,App,Global:string; Variables,Saved:TArray<string>;
  begin
    Root:=Settings.AppPath+'extractor-discovery'; App:=Root+'\portable'; Global:=Root+'\system64\7-Zip\';
    ForceDirectories(App+'\tools\7zip'); ForceDirectories(Global);
    TFile.WriteAllText(App+'\tools\7zip\7z.exe','Owned incomplete executable marker; never run');
    TFile.WriteAllText(Global+'7z.exe','Owned executable marker; never run');
    TFile.WriteAllText(Global+'7z.dll','Owned library marker; never loaded');
    Variables:=TArray<string>.Create('ProgramFiles','ProgramFiles(x86)','ProgramW6432','PATH');
    SetLength(Saved,Length(Variables));
    for var I:=0 to High(Variables) do Saved[I]:=GetEnvironmentVariable(Variables[I]);
    try
      SetEnvironmentVariable('ProgramFiles',PChar(Root+'\empty32'));
      SetEnvironmentVariable('ProgramFiles(x86)',PChar(Root+'\empty32'));
      SetEnvironmentVariable('ProgramW6432',PChar(Root+'\system64')); SetEnvironmentVariable('PATH','');
      Require(SameFileName(FindFullSevenZip(App),Global+'7z.exe'),'Incomplete portable extractor hides full Windows installation');
      Require(SameFileName(FindExternalTool('7z.exe','7zip'),Global+'7z.exe'),'Ordinary archive lookup misses 64-bit Windows 7-Zip');
      TFile.WriteAllText(App+'\tools\7zip\7zz.exe','Owned standalone marker; never run');
      var Actual:=FindFullSevenZip(App);
      Require(SameFileName(Actual,App+'\tools\7zip\7zz.exe'),'Portable standalone extractor loses precedence: '+Actual);
    finally
      for var I:=0 to High(Variables) do SetEnvironmentVariable(PChar(Variables[I]),PChar(Saved[I]));
    end;
  end;
begin
  RequireIsolatedRegression;
  CheckExistingExtractor;
  Adapter:=GetEnvironmentVariable('HLRU_DJVU_READY_ADAPTER');
  Require(FileExists(Adapter),'Specify the pinned DjVu adapter ZIP');
  ExpectedSize:=Format('Нужно скачать: %.1f КБ',[(128+TFile.GetSize(Adapter))/1024]);
  Require(ComponentNeedsRepair(Settings.AppPath,'7-Zip'),'First-use fixture unexpectedly includes a private 7-Zip');
  Dialog:=TReaderModuleForm.Create(nil); Dialog.RequestedID:='DjVuLibre';
  try
    Dialog.RequestComponent('DjVuLibre','Для выбранной книги требуется чтение DjVu.',True);
    Started:=GetTickCount64;
    repeat
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Prompt:=TForm(Dialog.FindComponent('OptionalComponentPrompt'));
      Size:=''; if Assigned(Prompt) then Size:=TLabel(Prompt.FindComponent('ComponentPromptBytes')).Caption;
    until (Size=ExpectedSize) or (GetTickCount64-Started>5000);
    Require(Assigned(Prompt) and (Size=ExpectedSize),'DjVu first use did not find its ready package: '+Size);
    Require(string(TLabel(Prompt.FindComponent('ComponentPromptTitle')).Caption).Contains('DjVuLibre'),
      'DjVu first use diverted to a 7-Zip install');
    Require(string(TMemo(Prompt.FindComponent('ComponentPromptReason')).Text).Contains('Дополнительная установка 7-Zip не требуется'),
      'DjVu ready package source or extraction explanation absent');
    Require((Dialog.Requests.Count=2) and (Dialog.DownloadID=''),'DjVu queried unrelated modules or started itself');
    try TButton(Prompt.FindComponent('ComponentPromptDownload')).Click;
    except on E:Exception do if E.Message<>'OWN_READER_DOWNLOAD_OBSERVED' then raise; end;
    Require(Dialog.DownloadID='DjVuLibre','DjVu prompt downloaded a different component');
  finally Dialog.Free; end;
  Archive:=GetEnvironmentVariable('HLRU_DJVU_READY_PACKAGE');
  Require((Archive<>'') and FileExists(Archive),'Specify the owned ready DjVu package for native install validation');
  Hash:=UpdateSHA256(Archive); Job:=Settings.AppPath+'djvu-ready-job'; Target:=Settings.AppPath+'djvu-ready-target';
  ForceDirectories(Target); TFile.Copy(ParamStr(0),Target+'\HomeLibRu.exe');
  Info:=Default(TProgramRelease); Info.ComponentID:='DjVuLibre'; Info.ComponentVersion:='3.5.29';
  Info.Tag:=ALREADER_FIXED_TAG; Info.SHA256:=Hash; Info.Size:=TFile.GetSize(Archive);
  Info.DownloadURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+ExtractFileName(Archive);
  Server:=TRepairServer.Create; Worker:=nil;
  try
    Server.URLs.Add(Info.DownloadURL); Server.Files.Add(Archive);
    Server.URLs.Add('https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/HomeLibRu-DjVu-adapter-1.zip');
    Server.Files.Add(Adapter);
    Worker:=TRepairWorker.Create(0,Info,Job,Server); Worker.RuntimePath:=Target;
    Worker.Start; Started:=GetTickCount64;
    while not Worker.Finished do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<30000,'Ready DjVu preparation timed out');
    end;
    Worker.WaitFor;
    Require(Worker.Successful,'Ready DjVu download and adapter verification failed: '+Worker.ErrorText);
    Require((Server.Requests=2) and (Server.Failure=''),'Ready DjVu requested unrelated components');
  finally
    if Assigned(Worker) then begin Worker.Terminate; Worker.WaitFor; Worker.Free; end;
    Server.Free;
  end;
  InstallProgramUpdate(Job,Target);
  Require(not ComponentNeedsRepair(Target,'DjVuLibre'),'Ready DjVu package did not install completely');
  Require(not FileExists(Target+'\tools\7zip\7z.exe'),'Ready DjVu install added unrelated 7-Zip');
  Require(FileExists(Target+'\tools\djvu\djvulibre-3.5.29.tar.gz') and
    FileExists(Target+'\tools\djvu\COPYING.txt'),'Ready DjVu lost corresponding source or license');
  Require(UpdateSHA256(Archive)=Hash,'DjVu validation changed the input archive');
  Writeln('PASS DjVu first use downloads its ready verified package without another 7-Zip install');
end;
