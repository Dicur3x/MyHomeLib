procedure TestVisibleLibrarySearch(const Collection: IBookCollection);
var Criteria, Restricted: TBookSearchCriteria; Iterator: IBookIterator;
  Book: TBookRecord; IDs: TArray<Integer>; Before, After: TStringList;
  function Snapshot(const Value: TBookSearchCriteria; Memos: Boolean): TStringList;
  var Rows, Count: Integer;
  begin
    Result:=TStringList.Create;
    try
      Iterator:=Collection.Search(Value,Memos); Rows:=Iterator.RecordCount; Count:=0;
      while Iterator.Next(Book) do
      begin
        Require(not (bpIsDeleted in Book.BookProps),'Hidden-library search returned a deleted book');
        Result.Add(IntToStr(Book.BookKey.BookID)+'|'+IntToStr(Book.SeriesID)+'|'+IntToStr(Book.SeqNumber)+'|'+
          Book.Title+'|'+Book.LibID+'|'+Book.CollectionName+'|'+TAuthorsHelper.GetList(Book.Authors)+'|'+
          TGenresHelper.GetList(Book.Genres)+'|'+TSeriesHelper.GetList(Book.PublisherSeries)+'|'+
          Book.Annotation+'|'+Book.Review+'|'+Book.FileName+'|'+Book.FileExt);
        Inc(Count);
      end;
      Require(Rows=Count,'Hidden-library count disagrees with expanded result rows');
      Iterator:=nil;
    except Result.Free; raise; end;
  end;
begin
  Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1; Criteria.Deleted:=True;
  Iterator:=Collection.GetBookIterator(bmAll,False);
  while Iterator.Next(Book) do IDs:=IDs+TArray<Integer>.Create(Book.BookKey.BookID);
  Iterator:=nil;
  for var Collapsed in [False,True] do
    for var Memos in [False,True] do
    begin
      Criteria.CollapseMultiSeriesResults:=Collapsed;
      Restricted:=Criteria; Restricted.RestrictBookIDs:=True; Restricted.BookIDs:=IDs;
      Before:=Snapshot(Restricted,Memos);
      try
        After:=Snapshot(Criteria,Memos);
        try Require(Before.Text=After.Text,'Direct hidden-library search differs from materialized search metadata/order');
        finally After.Free; end;
      finally Before.Free; end;
    end;
  Writeln('PASS direct hidden-library search matches materialized counts, series expansion, authors, genres, source names and memos'); Flush(Output);
end;

procedure TestDiagnosticsAndCacheAge(const Collection: IBookCollection);
var OriginalTemp, OriginalTmp, Root, OldLog, RecentLog, Foreign, Report, Text,
  A, B, C, Origin: string; Search: TSearchRec; Zip: TZipFile; Row: TJSONValue;
  Threads: array[0..3] of TThread; Thread: TThread; Stream: TStream;
  Writer: TFileStream; Configuration: TfrmSettings; CopySettings: TMHLSettings;
  procedure TestImageQualityChoice;
  var Source, Target, Hash: string; Chosen: Boolean; Warnings: TStringList;
    Document: TReaderDocument; Estimate: Int64; Canceled: Boolean;
  begin
    Source:=Settings.AppPath+'quality-scan.png'; Hash:=UpdateSHA256(Source);
    Warnings:=TStringList.Create;
    try
      for var Extension in ['.fb2','.epub'] do
      begin
        Chosen:=False; Estimate:=0; Target:=Settings.AppPath+'quality-result'+Extension;
        ConvertBasicBook(Settings.AppPath,Settings.TempPath,Source,'.png',Target,nil,Warnings,nil,
          'Fine print','','',False,nil,'ask',
          function(const Options: TBookImageQualityOptions): string
          begin
            Require((Options.ImageCount=1) and (Options.SampleCount=1),'Native quality chooser lost image estimates');
            Require((Options.HighBytes>=Options.BalancedBytes) and (Options.BalancedBytes>=Options.EconomyBytes),
              'Native image estimates are not ordered by size');
            Chosen:=True; Estimate:=Options.EconomyBytes; Result:='economy';
          end);
        Require(Chosen and (Abs(TFile.GetSize(Target)-Estimate)<4096),'Native export size estimate differs from the selected single-page book');
        Document:=TReaderDocument.Create;
        try Document.Load(Target); Require(Document.ImageCount=1,'Native reader lost an optimized image');
        finally Document.Free; end;
        TFile.Delete(Target);
      end;
      Canceled:=False;
      try
        ConvertBasicBook(Settings.AppPath,Settings.TempPath,Source,'.png',Target,nil,Warnings,nil,'','','',False,nil,'ask',
          function(const Options: TBookImageQualityOptions): string begin Result:=''; end);
      except on E: EAbort do Canceled:=True; end;
      Require(Canceled and not FileExists(Target),'Canceling quality selection published a book');
      Require(SameText(UpdateSHA256(Source),Hash),'Quality selection changed the source image');
    finally Warnings.Free; end;
    Writeln('PASS native image quality estimates, FB2/EPUB exports, reader reopening and cancellation preserve the source'); Flush(Output);
  end;
  procedure TestImageQualitySnapshotSharing;
  var Name, MessageText: string; Locked: THandle; Options: TBookImageQualityOptions;
  begin
    Name:=Settings.AppPath+'quality-options-sharing.json';
    TFile.WriteAllText(Name,'{"sizes":{"high":5000,"balanced":4000,"economy":3000},"images":1,"sampled":1,"format":"FB2"}',TEncoding.UTF8);
    Require(TryReadBookImageQualityOptions(Name,Options) and (Options.EconomyBytes=3000),'Native quality snapshot was not decoded');
    Locked:=CreateFile(PChar(Name),GENERIC_READ,0,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    Require(Locked<>INVALID_HANDLE_VALUE,'Cannot create exclusive quality snapshot fixture');
    try Require(not TryReadBookImageQualityOptions(Name,Options),'Locked quality snapshot did not defer reading');
    finally CloseHandle(Locked); end;
    Locked:=CreateFile(PChar(Name),GENERIC_READ,FILE_SHARE_READ,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    Require(Locked<>INVALID_HANDLE_VALUE,'Cannot create shared quality snapshot fixture');
    try Require(TryReadBookImageQualityOptions(Name,Options) and (Options.ImageCount=1),'A second read-only viewer blocked quality estimates');
    finally CloseHandle(Locked); end;
    Require(TryReadBookImageQualityOptions(Name,Options) and (Options.TargetFormat='FB2'),'Quality snapshot did not recover after releasing its lock');
    TFile.WriteAllText(Name,StringOfChar('x',4097),TEncoding.UTF8); MessageText:='';
    try TryReadBookImageQualityOptions(Name,Options); except on E: Exception do MessageText:=E.Message; end;
    Require(MessageText.Contains('большой'),'Oversized quality snapshot was accepted or silently retried');
    TFile.WriteAllText(Name,'{"images":1}',TEncoding.UTF8); MessageText:='';
    try TryReadBookImageQualityOptions(Name,Options); except on E: Exception do MessageText:=E.Message; end;
    Require(MessageText.Contains('Некорректная'),'Invalid complete quality snapshot was accepted or silently retried');
    TFile.Delete(Name);
    Writeln('PASS native quality snapshot tolerates exclusive and shared readers, recovers after lock release and rejects invalid complete records'); Flush(Output);
  end;
  procedure TestNativeTiffFrames;
  var Book: TBookRecord; Source,Prepared,Hash: string; Document: TReaderDocument;
  begin
    RequireIsolatedRegression;
    for var Extension in ['.tiff','.cbz'] do
    begin
      Source:=Settings.AppPath+'native-pages'+Extension; Hash:=UpdateSHA256(Source);
      Book.Clear; Book.NodeType:=ntBookInfo; Book.BookKey:=CreateBookKey(534,900534);
      Book.CollectionRoot:=ExtractFilePath(Source); Book.FileName:=TPath.GetFileNameWithoutExtension(Source);
      Book.FileExt:=Extension; Book.Title:='TIFF frames';
      Prepared:=PrepareReaderFile(Book,True,nil,False,True,True);
      Require(SameText(ExtractFileExt(Prepared),'.epub'),'Multi-frame TIFF did not use complete reader preparation');
      Document:=TReaderDocument.Create;
      try
        Document.Load(Prepared);
        Require((Document.ImageCount=2) and Document.PlainText.Contains('Страница 2'),'Native reader lost later TIFF frames');
      finally Document.Free; end;
      Require(SameText(UpdateSHA256(Source),Hash),'Native TIFF preparation changed the source');
    end;
    Writeln('PASS native TIFF and TIFF comic keep every frame through ordinary reader preparation without changing source files'); Flush(Output);
  end;
  procedure CacheFile(const Name: string; Size: Integer);
  begin
    Writer:=TFileStream.Create(Name,fmCreate);
    try Writer.Size:=Size; finally Writer.Free; end;
    RegisterBookCacheFile(Name,Origin);
  end;
begin
  TestImageQualitySnapshotSharing;
  TestVisibleLibrarySearch(Collection);
  TestImageQualityChoice;
  TestNativeTiffFrames;
  Require(Settings.BookCachePolicy=bcpSize,'Existing cache default changed');
  Require(Settings.BookCacheKeepDays=7,'New age policy default is not seven days');
  Settings.ClearBookCacheOnExit:=False; ClearBookCache; ForceDirectories(BookCachePath);
  Origin:=TPath.Combine(Settings.AppPath,'original-age.txt');
  TFile.WriteAllText(Origin,'original unchanged',TEncoding.UTF8);
  A:=TPath.Combine(BookCachePath,'homelib-age-a.epub');
  B:=TPath.Combine(BookCachePath,'homelib-age-b.epub');
  C:=TPath.Combine(BookCachePath,'homelib-age-c.epub');
  Settings.BookCacheLimitMB:=8; CacheFile(A,100); CacheFile(B,100); CacheFile(C,2*1024*1024);
  TFile.SetLastWriteTimeUtc(A,TTimeZone.Local.ToUniversalTime(Now)-8);
  TFile.SetLastWriteTimeUtc(B,TTimeZone.Local.ToUniversalTime(Now)-8);
  Stream:=OpenCachedBookFile(A); Stream.Free;
  Settings.BookCacheLimitMB:=1; Settings.BookCachePolicy:=bcpAge;
  RefreshBookCache(True); TrimBookCache;
  Require(FileExists(A) and not FileExists(B) and FileExists(C),'Age policy lost refreshed/large files or retained an expired file');
  Require(not FileExists(B+'.origin'),'Expired cache metadata survived');
  Settings.BookCachePolicy:=bcpSizeAndAge; TrimBookCache;
  Require(not FileExists(C),'Combined cache policy ignored size');
  Require(TFile.ReadAllText(Origin,TEncoding.UTF8)='original unchanged','Age cleanup changed original');
  Configuration:=TfrmSettings.Create(nil);
  try
    Configuration.LoadSetting;
    TComboBox(Configuration.FindComponent('cbBookCachePolicy')).ItemIndex:=1;
    TComboBox(Configuration.FindComponent('cbBookCachePolicy')).OnChange(nil);
    Require(not TEdit(Configuration.FindComponent('edBookCacheLimit')).Enabled,'Age-only limit is still enabled');
    Require(TEdit(Configuration.FindComponent('edBookCacheDays')).Enabled,'Age days cannot be edited');
    TEdit(Configuration.FindComponent('edBookCacheDays')).Text:='14'; Configuration.SaveSettings;
  finally Configuration.Free; end;
  Settings.SaveSettings; CopySettings:=TMHLSettings.Create;
  try
    CopySettings.LoadSettings;
    Require((CopySettings.BookCachePolicy=bcpAge) and (CopySettings.BookCacheKeepDays=14),'Cache age settings did not persist');
  finally CopySettings.Free; end;
  Writeln('PASS cache age expires unused files, refreshes on read, preserves originals and retains fresh large files; combined size and settings persist'); Flush(Output);

  OriginalTemp:=GetEnvironmentVariable('TEMP'); OriginalTmp:=GetEnvironmentVariable('TMP');
  Root:=TPath.Combine(Settings.AppPath,'diagnostic-test-temp'); ForceDirectories(Root);
  SetEnvironmentVariable('TEMP',PChar(Root)); SetEnvironmentVariable('TMP',PChar(Root));
  Writeln('TRACE diagnostics begin ticks=',GetTickCount64); Flush(Output);
  try
    Require(SameFileName(DiagnosticLogDirectory,TPath.Combine(Root,'HomeLibRu-Logs')),'Diagnostics test escaped its isolated temp root');
    ForceDirectories(DiagnosticLogDirectory);
    OldLog:=TPath.Combine(DiagnosticLogDirectory,'HomeLibRu-'+FormatDateTime('yyyy-mm-dd',Now-7)+'.log');
    RecentLog:=TPath.Combine(DiagnosticLogDirectory,'HomeLibRu-'+FormatDateTime('yyyy-mm-dd',Now-6)+'.log');
    Foreign:=TPath.Combine(DiagnosticLogDirectory,'personal-note.txt');
    TFile.WriteAllText(OldLog,'expired',TEncoding.UTF8); TFile.WriteAllText(RecentLog,'{}',TEncoding.UTF8);
    TFile.WriteAllText(Foreign,'keep',TEncoding.UTF8); PruneDiagnosticLogs;
    Writeln('TRACE diagnostics pruned ticks=',GetTickCount64); Flush(Output);
    Require(not FileExists(OldLog) and FileExists(RecentLog) and FileExists(Foreign),'Seven-day log cleanup lost foreign/recent files or kept an expired log');
    Text:=SanitizeDiagnosticText('Ошибка C:\Users\private\book.fb2 https://example.com/book?token=secret token=private-value');
    Require(not Text.Contains('private') and not Text.Contains('example.com') and not Text.Contains('secret'),'Diagnostic privacy redaction failed');
    Writeln('TRACE diagnostics sanitized ticks=',GetTickCount64); Flush(Output);
    for var I:=0 to High(Threads) do
    begin
      Threads[I]:=TThread.CreateAnonymousThread(procedure
        begin for var N:=1 to 50 do LogDiagnosticMessage('concurrent-test','Сообщение '+IntToStr(N)); end);
      Threads[I].FreeOnTerminate:=False; Threads[I].Start;
    end;
    for Thread in Threads do begin Thread.WaitFor; Thread.Free; end;
    Writeln('TRACE diagnostics concurrent writes ticks=',GetTickCount64); Flush(Output);
    for Text in TFile.ReadAllLines(DiagnosticLogFile,TEncoding.UTF8) do
    begin
      Row:=TJSONObject.ParseJSONValue(Text);
      try Require(Row is TJSONObject,'Concurrent diagnostics produced invalid JSON'); finally Row.Free; end;
    end;
    for var I:=1 to 600 do LogDiagnosticMessage('bounded-test',StringOfChar('x',4096));
    Writeln('TRACE diagnostics cap ticks=',GetTickCount64); Flush(Output);
    Require(TFile.GetSize(DiagnosticLogFile)<=2*1024*1024,'Daily diagnostic cap exceeded');
    Report:=TPath.Combine(Root,'report.zip'); SaveDiagnosticReport(Report);
    Zip:=TZipFile.Create;
    try
      Zip.Open(Report,zmRead);
      Require((Zip.FileCount=3) and (Zip.IndexOf('HomeLibRu-info.txt')>=0),'Report omitted retained logs or included foreign files');
    finally Zip.Free; end;
    Text:=''; try SaveDiagnosticReport(Report); except on E: EWriteError do Text:=E.Message; end;
    Require(Text<>'','Existing diagnostic report overwritten');
    Require(FindFirst(TPath.Combine(Root,'HomeLibRu-report-*.tmp'),faAnyFile,Search)<>0,'Report staging temporary survived');
    Writeln('PASS seven-day bounded Unicode diagnostics redact paths and secrets, preserve foreign files and save a complete ZIP report under concurrent writes'); Flush(Output);
  finally
    SetEnvironmentVariable('TEMP',PChar(OriginalTemp)); SetEnvironmentVariable('TMP',PChar(OriginalTmp));
  end;
end;

type TQualityLayoutProbe = class
  DesiredPPI: Integer;
  ExpectedWidth, ExpectedHeight: Integer;
  AutoClose: Boolean;
  Timer: TTimer;
  ErrorText: string;
  procedure Tick(Sender: TObject);
end;

procedure TQualityLayoutProbe.Tick(Sender: TObject);
var Dialog: TForm; RadioCount: Integer; Content: TScrollBox; SaveButton: TButton; NoImages: TRadioButton;
  SavedHeight, SavedWidth: Integer;
  procedure Inspect(Parent: TWinControl);
  var Bounds: TRect; Limit: Integer; Flags: Cardinal;
  begin
    Limit:=Parent.ClientHeight;
    if (Parent is TScrollBox) and (TScrollBox(Parent).VertScrollBar.Range>Limit) then
      Limit:=TScrollBox(Parent).VertScrollBar.Range;
    for var I:=0 to Parent.ControlCount-1 do
    begin
      var Control:=Parent.Controls[I];
      if not Control.Visible then Continue;
      Require((Control.Left>=0) and (Control.Top>=0) and
        (Control.Left+Control.Width<=Parent.ClientWidth) and (Control.Top+Control.Height<=Limit),
        Format('Quality %s [%d,%d %dx%d] exceeds parent %dx%d at %d PPI',[Control.ClassName,Control.Left,Control.Top,Control.Width,Control.Height,Parent.ClientWidth,Limit,DesiredPPI]));
      if Control is TLabel then
      begin
        var Text:=TLabel(Control); Dialog.Canvas.Font.Assign(Text.Font);
        Bounds:=Rect(0,0,Text.Width,Text.Height); Flags:=DT_CALCRECT or DT_NOPREFIX;
        if Text.WordWrap then Flags:=Flags or DT_WORDBREAK else Flags:=Flags or DT_SINGLELINE;
        DrawText(Dialog.Canvas.Handle,PChar(Text.Caption),Length(Text.Caption),Bounds,Flags);
        Require(Bounds.Height<=Text.Height,Format('Quality label %s needs %d pixels, has %d at %d PPI',[Copy(Text.Caption,1,100),Bounds.Height,Text.Height,DesiredPPI]));
      end;
      if Control is TRadioButton then
      begin
        Inc(RadioCount); var Radio:=TRadioButton(Control); Dialog.Canvas.Font.Assign(Radio.Font);
        Require(Dialog.Canvas.TextWidth(Radio.Caption)+MulDiv(24,DesiredPPI,96)<=Radio.Width,'Quality size caption is clipped');
        if string(Radio.Caption).StartsWith('Сбалансированный') then Require(Radio.Checked,'Balanced is not the default choice');
        if string(Radio.Caption).StartsWith('Без изображений') then NoImages:=Radio;
      end;
      if Control is TScrollBox then Content:=TScrollBox(Control);
      if (Control is TButton) and (TButton(Control).Caption='Сохранить книгу') then SaveButton:=TButton(Control);
      if Control is TWinControl then Inspect(TWinControl(Control));
    end;
  end;
begin
  Dialog:=nil;
  for var I:=Screen.FormCount-1 downto 0 do
    if Screen.Forms[I].Visible and string(Screen.Forms[I].Caption).StartsWith('Качество изображений') then
    begin Dialog:=Screen.Forms[I]; Break; end;
  if not Assigned(Dialog) then Exit;
  Timer.Enabled:=False;
  try
    if ExpectedWidth>0 then
    begin
      Require(Abs(MulDiv(Dialog.ClientWidth,96,Dialog.PixelsPerInch)-ExpectedWidth)<=1,'Quality window width was not restored');
      Require(Abs(MulDiv(Dialog.ClientHeight,96,Dialog.PixelsPerInch)-ExpectedHeight)<=1,'Quality window height was not restored');
    end;
    Dialog.ScaleForPPI(DesiredPPI);
    Dialog.Left:=Screen.WorkAreaLeft+(Screen.WorkAreaWidth-Dialog.Width) div 2;
    Dialog.Top:=Screen.WorkAreaTop+(Screen.WorkAreaHeight-Dialog.Height) div 2;
    Content:=nil; SaveButton:=nil; NoImages:=nil; RadioCount:=0; Inspect(Dialog);
    Require(RadioCount=4,'Quality dialog lost a profile');
    Require(Assigned(NoImages) and (NoImages.Enabled=(DesiredPPI=96)),'Text-only choice was unavailable for prose or enabled for scans');
    Require(Dialog.BorderStyle=bsSizeable,'Quality dialog cannot be resized');
    Require(MulDiv(Abs(Dialog.Font.Height),96,Dialog.PixelsPerInch)<=14,'Quality font exceeds the standard interface size');
    Require(Assigned(Content) and Assigned(SaveButton),'Quality scrolling area or fixed save button is absent');
    SavedHeight:=Dialog.ClientHeight; SavedWidth:=Dialog.ClientWidth;
    Dialog.ClientWidth:=SavedWidth+MulDiv(80,DesiredPPI,96);
    Dialog.ClientHeight:=MulDiv(260,DesiredPPI,96);
    Require(Content.VertScrollBar.Range>Content.ClientHeight,'Small quality window has no vertical scrolling');
    Require(SaveButton.Parent.Top+SaveButton.Top+SaveButton.Height<=Dialog.ClientHeight,'Save button moved outside a small quality window');
    Dialog.ClientWidth:=SavedWidth; Dialog.ClientHeight:=SavedHeight;
    RadioCount:=0; Inspect(Dialog);
    for var I:=0 to Content.ControlCount-1 do
      if Content.Controls[I] is TComboBox then Require(TComboBox(Content.Controls[I]).ItemIndex=0,'Scan splitting is not optional by default');
    Writeln('PASS image quality layout ppi=',DesiredPPI,' dark=',MHLThemeDark); Flush(Output);
    if AutoClose then
    begin
      if DesiredPPI=96 then NoImages.Perform(BM_CLICK,0,0);
      SaveButton.Click;
    end;
  except
    on E: Exception do begin ErrorText:=E.Message; Writeln('LAYOUT ',ErrorText); Flush(Output); Dialog.ModalResult:=mrCancel; end;
  end;
end;

procedure TestImageQualityDialog;
var Options: TBookImageQualityOptions; Probe: TQualityLayoutProbe; Choice: string;
  AllBooks, SavedDark: Boolean;
begin
  Probe:=TQualityLayoutProbe.Create;
  Probe.Timer:=TTimer.Create(nil); SavedDark:=MHLThemeDark;
  try
    Probe.Timer.Enabled:=False; Probe.Timer.Interval:=300; Probe.Timer.OnTimer:=Probe.Tick;
    Probe.AutoClose:=not SameText(ParamStr(2),'visual');
    Options:=Default(TBookImageQualityOptions); Options.ImageCount:=98; Options.SampleCount:=9;
    for var PPI in [96,144,192] do
    begin
      SetMHLTheme(PPI=192); Options.TargetFormat:='FB2';
      Options.HighBytes:=106536959; Options.BalancedBytes:=50000000; Options.EconomyBytes:=21004655;
      if PPI=192 then
      begin
        Options.TargetFormat:='EPUB'; Options.HighBytes:=79595885;
        Options.BalancedBytes:=35000000; Options.EconomyBytes:=15412018;
      end;
      Options.ScanPages:=PPI>=144; Options.FirstSamples:=Options.ScanPages;
      Options.NoImagesBytes:=0; if not Options.ScanPages then Options.NoImagesBytes:=14000;
      Options.SplitHighBytes:=Options.HighBytes+1000000; Options.SplitBalancedBytes:=Options.BalancedBytes-1000000; Options.SplitEconomyBytes:=Options.EconomyBytes-2000000;
      Options.AutoHighBytes:=Options.SplitHighBytes; Options.AutoBalancedBytes:=Options.SplitBalancedBytes; Options.AutoEconomyBytes:=Options.SplitEconomyBytes;
      Probe.ExpectedWidth:=Settings.ExportImageQualityWidth; Probe.ExpectedHeight:=Settings.ExportImageQualityHeight;
      Probe.DesiredPPI:=PPI; Probe.ErrorText:=''; Probe.Timer.Enabled:=True;
      Choice:=ChooseExportImageQuality('Проверка интерфейса — Доброе утро, имя прилагательное — проверка мелкого текста, цветных иллюстраций и примерного размера книги',
        Options,PPI<>144,AllBooks);
      Require(Probe.ErrorText='',Probe.ErrorText);
      if Probe.AutoClose and (PPI=96) then Require(Choice='none','Text-only radio did not reach the export result');
      Require((Choice='none') or (Choice='high') or (Choice='balanced') or (Choice='economy') or (Choice='high|split') or (Choice='balanced|split') or (Choice='economy|split') or
        (Choice='high|auto') or (Choice='balanced|auto') or (Choice='economy|auto'),'Quality dialog canceled unexpectedly');
      Require((Settings.ExportImageQualityWidth>0) and (Settings.ExportImageQualityHeight>0),'Quality dialog size was not saved');
      Require(AllBooks=(PPI<>144),'Batch quality checkbox did not preserve its visible state');
      Writeln('PASS image quality dialog choice=',Choice,' format=',Options.TargetFormat,' ppi=',PPI); Flush(Output);
    end;
  finally Probe.Timer.Free; Probe.Free; SetMHLTheme(SavedDark); end;
end;
