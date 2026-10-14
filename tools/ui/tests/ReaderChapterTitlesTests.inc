// Strict native oracle for the minimal chapter-list publication optimization.
// Expected Dome hash was captured from the unmodified native reader, not rebuilt
// with the production numbering algorithm. All fixture output stays private.
function RTChapterSelector(Reader: TfrmBuiltinReader): TComboBox;
begin
  Result:=Reader.FindComponent('ReaderChapterSelector') as TComboBox;
  Require(Assigned(Result),'Actual native chapter selector is absent');
  Require(Result.Items.Count=Reader.ChapterCount,'Native chapter selector count changed');
end;

function RTChapterSnapshot(Reader: TfrmBuiltinReader; IncludeLabels: Boolean): string;
var Chapters: TComboBox; Builder: TStringBuilder;
begin
  Chapters:=RTChapterSelector(Reader); Builder:=TStringBuilder.Create;
  try
    Builder.Append(Chapters.Items.Count).Append(':').Append(Chapters.ItemIndex).Append(#13);
    for var I:=0 to Chapters.Items.Count-1 do
    begin
      Require(Chapters.Items[I]=Reader.ChapterTitle(I),'Displayed chapter label differs from navigation label');
      Builder.Append(I).Append(':').Append(NativeInt(Chapters.Items.Objects[I])).Append(':');
      if IncludeLabels then Builder.Append(Chapters.Items[I]);
      Builder.Append(#13);
    end;
    Result:=Builder.ToString;
  finally Builder.Free; end;
end;

procedure RTCValidateUnnumberedLabels(Reader: TfrmBuiltinReader; Numbered: Boolean);
var Expected: TArray<string>;
begin
  if Numbered then
    Expected:=TArray<string>.Create(
      '1. Первая часть',
      '1. Первая часть › 1. Самолёт и лесной сурок',
      '1. Первая часть › 1. Самолёт и лесной сурок › III. Уже пронумеровано',
      '1. Первая часть › 1. Самолёт и лесной сурок › Глубокая мысль',
      '1. Первая часть › 2. Барби',
      'Chapter 2. Вторая часть',
      'Chapter 2. Вторая часть › 1. Финал',
      'Chapter 2. Вторая часть › 2. Название — Ёж, ї, ў',
      'Примечание')
  else
    Expected:=TArray<string>.Create(
      '1. Первая часть',
      '1. Первая часть › Самолёт и лесной сурок',
      '1. Первая часть › Самолёт и лесной сурок › III. Уже пронумеровано',
      '1. Первая часть › Самолёт и лесной сурок › Глубокая мысль',
      '1. Первая часть › Барби',
      'Chapter 2. Вторая часть',
      'Chapter 2. Вторая часть › Финал',
      'Chapter 2. Вторая часть › Название — Ёж, ї, ў',
      'Примечание');
  Require(Reader.ChapterCount=Length(Expected),'Unnumbered fixture chapter count differs from independent expected labels');
  for var I:=0 to High(Expected) do
    Require(Reader.ChapterTitle(I)=Expected[I],
      Format('Unnumbered fixture exact label %d numbered=%d differs: %s',[I,Ord(Numbered),Reader.ChapterTitle(I)]));
end;

procedure TestReaderChapterTitles;
const
  DomeSourceSHA='a42f763723f50f4f38ff67a833008d18ce58ef1320155a95c0f7a826bbd59f2d';
  // Original GUI64 baseline: every native label/position and selected chapter
  // after navigating to BookText.Length*4 div 5, with the exact fixture below.
  DomeOriginalNativeSHA='030af43615ec680b6c55f860fb5b71b2d137f71b1a38f705ef49fae9ff01b05b';
  UnnumberedXML=
    '<FictionBook><description><title-info><book-title>Unnumbered nested contents oracle</book-title><lang>ru</lang></title-i' +
    'nfo></description><body><section><title><p>1. Первая часть</p></title><p>Явный номер основной части сохранён.</p><sectio' +
    'n><title><p>Самолёт и лесной сурок</p></title><p>Подраздел без номера. Текст с <strong>важной мыслью</strong>.</p><secti' +
    'on><title><p>III. Уже пронумеровано</p></title><p>Римская нумерация на другом уровне сохранена.</p></section><section><t' +
    'itle><p>Глубокая мысль</p></title><p>Этот уровень содержит явно пронумерованную соседнюю главу.</p></section></section><' +
    'section><title><p>Барби</p></title><p>Второй подраздел без номера.</p></section></section><section><title><p>Chapter 2. ' +
    'Вторая часть</p></title><p>Исходное название второй части.</p><section><title><p>Финал</p></title><p>Счётчик подразделов' +
    ' начинается заново.</p></section><section><title><p>Название — Ёж, ї, ў</p></title><p>Последний подраздел со <a href="#n' +
    '">сноской</a>.</p></section></section></body><body name="notes"><section id="n"><title><p>Примечание</p></title><p>Полны' +
    'й текст примечания сохранён.</p></section></body></FictionBook>';
var Root, Tiny, Dome, ProfileFile, ProfileHash: string; BeforeForms: Integer;

  procedure CheckProtectedProfile;
  begin
    if ProfileHash<>'' then
      Require(THashSHA2.GetHashStringFromFile(ProfileFile)=ProfileHash,
        'Chapter-list fixture changed the main preferences/profile bytes');
  end;

  procedure CheckBook(const Source, Stem: string; TinyFixture: Boolean);
  var Reader: TfrmBuiltinReader; Ini: TMemIniFile; IniName, SourceHash: string;
    Watch: TStopwatch; Numbered, Unnumbered, Positions, Text: string;
  begin
    SourceHash:=THashSHA2.GetHashStringFromFile(Source);
    IniName:=TPath.Combine(Root,Stem+'-reader.ini');
    Ini:=TMemIniFile.Create(IniName,TEncoding.UTF8);
    try
      Ini.WriteString('Reader','FontName','Georgia'); Ini.WriteInteger('Reader','FontSize',20);
      Ini.WriteInteger('Reader','InitialsMode',2); Ini.WriteInteger('Reader','Theme',1);
      Ini.WriteBool('Reader','AppThemeDark',False); Ini.WriteBool('Reader','NumberChapters',True);
      Ini.WriteInteger('Reader','Width',1135); Ini.WriteInteger('Reader','Height',1139);
      Ini.WriteString('UnknownSection','Protected','Exact metadata — ё, ї, ў');
      Ini.UpdateFile;
    finally Ini.Free; end;
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Watch:=TStopwatch.StartNew;
      Reader.OpenBook(Source,'Chapter-title preservation','experiment',IniName,'');
      while not Reader.LoadFinished and (Watch.ElapsedMilliseconds<30000) do
      begin Application.ProcessMessages; CheckSynchronize(1); Sleep(1); end;
      Require(Reader.Ready and Reader.LoadFinished,'Chapter-list reader failed: '+Reader.ReaderStatus.Caption);
      // Same last navigation position as the frozen native baseline; timers
      // may finish layout but must not supply a different expected title table.
      Sleep(180); Application.ProcessMessages; CheckSynchronize(1);
      Text:=Reader.BookText;
      Reader.GoToPosition(Length(Text)*4 div 5); Application.ProcessMessages; CheckSynchronize(1);
      Positions:=RTChapterSnapshot(Reader,False);
      Numbered:=RTChapterSnapshot(Reader,True);
      if TinyFixture then RTCValidateUnnumberedLabels(Reader,True)
      else
      begin
        Require(Reader.ChapterCount=614,'Dome native chapter count differs from frozen original');
        Writeln('TRACE chapter frozen oracle chars=',Length(Text),' selected=',RTChapterSelector(Reader).ItemIndex,
          ' actual_sha=',THashSHA2.GetHashString(Numbered)); Flush(Output);
        Require(THashSHA2.GetHashString(Numbered)=DomeOriginalNativeSHA,
          'Dome native labels/positions/order/selected chapter differ from frozen original');
      end;
      Reader.SetNumberChapters(False);
      Require(RTChapterSnapshot(Reader,False)=Positions,'Disabling numbers changed chapter positions/order/selection');
      Unnumbered:=RTChapterSnapshot(Reader,True);
      if TinyFixture then
      begin
        RTCValidateUnnumberedLabels(Reader,False);
        Require(Unnumbered<>Numbered,'Tiny fixture did not exercise actual automatic numbering');
      end
      else Require(Unnumbered=Numbered,'Dome existing chapter numbers were changed by disabling added numbers');
      Reader.SetNumberChapters(True);
      Require(RTChapterSnapshot(Reader,True)=Numbered,'Re-enabling numbers changed exact labels/positions/order/selection');
      if TinyFixture then RTCValidateUnnumberedLabels(Reader,True);
      Require(Reader.BookText=Text,'Chapter numbering changed full native book text');
      TFile.WriteAllText(TPath.Combine(Root,Stem+'-verified-numbered-chapters.txt'),Numbered,TEncoding.UTF8);
      TFile.WriteAllText(TPath.Combine(Root,Stem+'-verified-unnumbered-chapters.txt'),Unnumbered,TEncoding.UTF8);
      Reader.Close;
    finally Reader.Free; end;
    Ini:=TMemIniFile.Create(IniName,TEncoding.UTF8);
    try Require(Ini.ReadString('UnknownSection','Protected','')='Exact metadata — ё, ї, ў',
      'Chapter-list reader save changed unknown metadata'); finally Ini.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Source)=SourceHash,'Chapter-list fixture changed source book bytes');
    Require(Screen.FormCount=BeforeForms,'Chapter-list fixture left an orphan reader/form');
    CheckProtectedProfile;
  end;

begin
  RequireIsolatedRegression;
  Root:=TPath.Combine(Settings.AppPath,'reader-chapters-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  Require(SameText(ExtractFileDrive(TPath.GetFullPath(Root)),'G:'),'Chapter-title fixture must remain on G');
  Tiny:=TPath.Combine(Root,'unnumbered.fb2');
  TFile.WriteAllText(Tiny,UnnumberedXML,TEncoding.UTF8);
  Dome:=TPath.Combine(Settings.AppPath,'reader-dome.fb2');
  Require(FileExists(Dome),'Real Dome reader fixture is absent');
  Require(THashSHA2.GetHashStringFromFile(Dome)=DomeSourceSHA,'Dome source differs from the frozen native baseline fixture');
  ProfileFile:=Settings.SettingsFileName; ProfileHash:='';
  if FileExists(ProfileFile) then ProfileHash:=THashSHA2.GetHashStringFromFile(ProfileFile);
  BeforeForms:=Screen.FormCount;
  CheckBook(Tiny,'tiny',True);
  Writeln('PASS chapter titles exact nine independent mixed-level labels, numbering toggle, position objects and selected chapter');
  CheckBook(Dome,'dome',False);
  Writeln('PASS chapter titles all614 Dome labels and native positions match frozen original reader SHA, text and source/profile unchanged');
end;
