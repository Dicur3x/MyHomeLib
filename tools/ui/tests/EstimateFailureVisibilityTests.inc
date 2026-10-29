type
  TEstimateFailureVisibilityProbe = class
    Timer: TTimer;
    Failure: string;
    DPI, Stage: Integer;
    Deadline: UInt64;
    ReportSeen, Completed: Boolean;
    Books: TArray<TBookRecord>;
    procedure Tick(Sender: TObject);
  end;

procedure TEstimateFailureVisibilityProbe.Tick(Sender: TObject);
begin
  try
    Require(GetTickCount64<Deadline,'Estimate failure visibility timed out');
    for var I:=Screen.FormCount-1 downto 0 do
    begin
      var Dialog:=Screen.Forms[I]; if not Dialog.Visible then Continue;
      if Dialog.Name='BookSaveEstimateReport' then
      begin
        if ReportSeen then Exit;
        if Dialog.CurrentPPI<>DPI then Dialog.ScaleForPPI(DPI);
        var Memo:=TMemo(Dialog.FindComponent('EstimateReportText'));
        var ReportText: string:=Memo.Text;
        Require(Memo.ReadOnly and Memo.WordWrap,'Estimate report cannot be read without horizontal scrolling');
        for var Book in Books do
          Require(ReportText.Contains(Book.Title),'Estimate report omitted a failed book: '+Book.Title);
        Require(ReportText.Contains('Причина:') and ReportText.Contains('не определён'),
          'Estimate report omitted the actual reason');
        Require(ReportText.Contains('не результат сохранения'),'Estimate failures are presented as failed saves');
        for var Name in ['CopyEstimateReport','SaveEstimateReport','CloseEstimateReport'] do
        begin
          var Button:=TButton(Dialog.FindComponent(Name));
          Require(Button.Visible and Button.Enabled and (Button.Left>=0) and
            (Button.Left+Button.Width<=Button.Parent.ClientWidth) and
            (Button.Top+Button.Height<=Button.Parent.ClientHeight),'Estimate report button is clipped: '+Name);
        end;
        ReportSeen:=True;
        // Optional human visual review of the actual light/dark report windows.
        if (DPI<>96) or (GetEnvironmentVariable('HOMELIB_TEST_ESTIMATE_VISUAL')<>'1') then
          Dialog.ModalResult:=mrClose;
        Exit;
      end;
      if Dialog.Name<>'BookSendOptions' then Continue;
      if Dialog.CurrentPPI<>DPI then Dialog.ScaleForPPI(DPI);
      var Calculate:=TButton(Dialog.FindComponent('EstimateSaveSize'));
      var ReportButton:=TButton(Dialog.FindComponent('ShowSaveEstimateReport'));
      if Stage=0 then
      begin
        Require(not ReportButton.Visible,'Unrequested estimates created a report action');
        Stage:=1; Calculate.Click; Exit;
      end;
      if Stage=1 then
      begin
        if not TComboBox(Dialog.FindComponent('SendFormat')).Enabled then Exit;
        var Status: string:=TLabel(Dialog.FindComponent('SaveEstimateStatus')).Caption;
        Require(Status.Contains('22 из 22'),'Batch estimate summary omitted the failed count: '+Status);
        Require(not Status.Contains('не определён'),'Batch estimate summary still shows only the first reason');
        var List:=TListView(Dialog.FindComponent('SaveBookSizes'));
        Require(List.Visible and (List.Items.Count=22) and (List.Columns.Count=4),
          'Failed estimate books/reasons are not present in the table');
        for var N:=0 to List.Items.Count-1 do
        begin
          var Row:=List.Items[N]; List.OnData(List,Row);
          Require((Row.Caption=Books[N].Title) and (Row.SubItems.Count=3) and
            Row.SubItems[2].Contains('не определён'),'A failed book still requires hovering to see its reason');
        end;
        Require(ReportButton.Visible and ReportButton.Enabled,'Complete estimate report is unavailable');
        Stage:=2; ReportButton.Click;
        Require(ReportSeen,'Estimate report did not open');
        // A different target format invalidates both the estimates and report.
        var Formats:=TComboBox(Dialog.FindComponent('SendFormat'));
        Require(Formats.Items.Count>1,'Cannot exercise changed target format');
        Formats.ItemIndex:=1; Formats.OnChange(Formats);
        Require(not ReportButton.Visible and
          (Pos('22 из 22',TLabel(Dialog.FindComponent('SaveEstimateStatus')).Caption)=0),
          'Changing format leaves an old failure report or summary');
        Completed:=True; Timer.Enabled:=False; Dialog.ModalResult:=mrCancel; Exit;
      end;
    end;
  except
    on E: Exception do
    begin
      Failure:=E.Message; Timer.Enabled:=False;
      for var I:=Screen.FormCount-1 downto 0 do
        if (Screen.Forms[I].Name='BookSendOptions') or (Screen.Forms[I].Name='BookSaveEstimateReport') then
          Screen.Forms[I].ModalResult:=mrCancel;
    end;
  end;
end;

procedure TestEstimateFailureVisibility;
var Books: TArray<TBookRecord>; Items: TBookSaveEstimateItems; Plan: TBookSaveChoice;
  Report, Name, BeforeHash: string; Options: TBookSendOptions; SavedDark: Boolean;
  Probe: TEstimateFailureVisibilityProbe; Failed: Boolean;
begin
  RequireIsolatedRegression; SetLength(Books,22); SetLength(Items,22);
  Plan:=Default(TBookSaveChoice); Plan.Mode:=emFB2Zip;
  for var I:=0 to High(Books) do
  begin
    Books[I].Clear; Books[I].Title:='Книга без оценки '+IntToStr(I+1)+' — Ё, Україна, 中文';
    Books[I].BookKey:=CreateBookKey(8000+I,73); Books[I].LibID:='source-'+IntToStr(I);
    Books[I].FileExt:='.fb2'; Books[I].NodeType:=ntBookInfo;
    Items[I]:=Default(TBookSaveEstimateItem); Items[I].SourceExtension:='.fb2';
    Items[I].TargetExtension:='.fb2'; Items[I].Completed:=True;
    Items[I].ErrorText:='Полная причина '+IntToStr(I+1)+sLineBreak+string.Create('я',600);
  end;
  Items[0].Options.OutputBytes[0,0]:=4096; Items[0].Options.ZipOutputBytes[0,0]:=1024;
  Items[0].RequiredComponents:=TArray<string>.Create('BookProcessing','ImageProcessing');
  Require(BookEstimateResultText(Items[0],1024).StartsWith('Размер известен'),
    'A known original copy size is hidden by unavailable other image modes');
  Report:=BookEstimateReport(Books,Items,Plan,0,0,'Оценка завершена');
  for var I:=0 to High(Books) do
    Require(Report.Contains(Books[I].Title) and Report.Contains('Полная причина '+IntToStr(I+1)+sLineBreak+string.Create('я',600)),
      'Report truncates or omits an affected book/reason');
  Require(Report.Contains('BookID: 8000') and Report.Contains('source-21') and
    Report.Contains('BookProcessing, ImageProcessing') and Report.Contains('Как есть: ≈ '+BookEstimateSizeText(1024)),
    'Report omits identity, required components or selected ZIP size');
  Name:=Settings.AppPath+'estimate-errors.txt'; TFile.WriteAllText(Name,'Previous report',TEncoding.UTF8);
  BeforeHash:=UpdateSHA256(Name); Failed:=False;
  try SaveBookEstimateReport(Name,Report); except on E: Exception do Failed:=True; end;
  Require(Failed and (UpdateSHA256(Name)=BeforeHash),'Report overwrote an existing file without permission');
  SaveBookEstimateReport(Name,Report,True);
  Require(TFile.ReadAllText(Name,TEncoding.UTF8)=Report,'Saved UTF-8 estimate report loses full reasons or titles');
  Require(Length(TDirectory.GetFiles(Settings.AppPath,'.homelib-book-*.tmp'))=0,'Report left staging payloads');
  Writeln('PASS complete estimate report preserves every failed book full reason identity required modules partial known sizes and atomic UTF8 save');
  SavedDark:=MHLThemeDark;
  try
    for var Dark in [False,True] do
      for var DPI in [96,144,192] do
      begin
        SetMHLTheme(Dark); Probe:=TEstimateFailureVisibilityProbe.Create;
        Probe.Books:=Books; Probe.DPI:=DPI; Probe.Deadline:=GetTickCount64+30000;
        if GetEnvironmentVariable('HOMELIB_TEST_ESTIMATE_VISUAL')='1' then
          Probe.Deadline:=GetTickCount64+120000;
        Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=30; Probe.Timer.OnTimer:=Probe.Tick;
        try
          Require(not ChooseBookSendOptions(Length(Books),Settings.AppPath,emFB2,Options,False,Books),
            'Canceled estimate review unexpectedly saved books');
          Require(Probe.Completed and (Probe.Failure=''),'Estimate visibility review failed: '+Probe.Failure);
        finally Probe.Timer.Free; Probe.Free; end;
      end;
  finally SetMHLTheme(SavedDark); end;
  Writeln('PASS real batch estimate shows all 22 failures without hovering opens full report resets changed format and remains usable light dark 96 144 192 DPI');
end;
