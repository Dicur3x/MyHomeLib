procedure TestSyncFolderExportSettings;
var Saved, Device, Destination: string; Reloaded: TMHLSettings; Count: Integer;
begin
  Saved:=Settings.SyncExportDir; Device:=Settings.DeviceDir;
  Destination:=TPath.Combine(Settings.AppPath,'Mock sync folder ё'); ForceDirectories(Destination);
  try
    Settings.SyncExportDir:=Destination; Settings.SaveSettings;
    Reloaded:=TMHLSettings.Create;
    try
      Reloaded.LoadSettings;
      Require((Reloaded.SyncExportDir=Destination) and (Reloaded.DeviceDir=Device),
        'Sync export folder did not survive settings reload independently of the device folder');
    finally Reloaded.Free; end;
    for var Menu in TArray<TMenuItem>.Create(frmMain.pmiScripts,frmMain.mmiScripts,frmMain.pmScripts.Items) do
    begin
      Count:=0;
      for var I:=0 to Menu.Count-1 do
        if Menu.Items[I].Tag=795 then
        begin
          Inc(Count); Require(Assigned(Menu.Items[I].OnClick) and Menu.Items[I].Visible,
            'Sync folder command is not available in a book export menu');
        end;
      Require(Count=1,'Sync export menu lost or duplicated its dedicated command');
    end;
  finally Settings.SyncExportDir:=Saved; Settings.SaveSettings; end;
  Writeln('PASS sync export destination persists independently of device settings and is available in all book export menus');
end;

procedure WaitCollectionStatistics(Form: TfrmStat);
var Watch: TStopwatch;
begin
  Watch:=TStopwatch.StartNew;
  while Form.Loading and (Watch.ElapsedMilliseconds<10000) do
  begin Application.ProcessMessages; Sleep(5); end;
  Require(not Form.Loading,'Background statistics did not finish');
end;

procedure TestFeedback529ReaderAndStatistics(const Collection: IBookCollection);
const
  PalettePNG='iVBORw0KGgoAAAANSUhEUgAAAAIAAAACAgMAAAAP2OW3AAAADFBMVEUAAAD/AAAAgAAAAADNQItPAAAAAXRSTlMAQObYZgAAAAxJREFUeJxjEGAqAAAAqACDNRuXvwAAAABJRU5ErkJggg==';
var Form: TfrmStat; Watch: TStopwatch; A,B,S: Integer; Detail: TMemo;
  Doc: TReaderDocument; Chapters: TArray<TReaderChapter>; Name, XML, SavedNotes: string;
  Stream: TBytesStream; Graphic: TGraphic; Bitmap: TBitmap;
  RTF: AnsiString; Offset: Integer; Worker: TCollectionStatisticsWorker;
begin
  Name:=TPath.Combine(Settings.AppPath,'feedback529-headings.fb2');
  XML:='<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>'+
    '<book-title>Оглавление и прозрачная палитра</book-title></title-info></description><body>'+
    '<section><title><p>1</p><p>Бекас</p></title><p>Первая глава</p><image l:href="#palette"/></section>'+
    '<section><title><p>Ду<emphasis>пель</emphasis>шнеп</p></title><p>Вторая глава</p></section></body>'+
    '<binary id="palette" content-type="image/png">'+PalettePNG+'</binary></FictionBook>';
  TFile.WriteAllText(Name,XML,TEncoding.UTF8);
  Doc:=TReaderDocument.Create;
  try
    Doc.Load(Name); Chapters:=Doc.Chapters;
    Require((Length(Chapters)=2) and (Chapters[0].Title='1 Бекас') and
      (Chapters[1].Title='Дупельшнеп'),'Block heading boundaries or inline emphasis lost');
    Require(Doc.ImageCount=1,'Indexed transparent PNG was skipped');
    RTF:=AnsiString(Doc.RTF(600,800));
    Offset:=Pos(AnsiString('\bin56 '),RTF);
    Require(Offset>0,'Small indexed PNG did not produce the expected bounded DIB');
    Inc(Offset,Length('\bin56 ')+40);
    Require((Byte(RTF[Offset])=0) and (Byte(RTF[Offset+1])=128) and
      (Byte(RTF[Offset+2])=0),'DIB green foreground pixel differs');
    Require((Byte(RTF[Offset+3])=255) and (Byte(RTF[Offset+4])=255) and
      (Byte(RTF[Offset+5])=255),'DIB transparent background became black');
  finally Doc.Free; end;
  Stream:=TBytesStream.Create(TNetEncoding.Base64.DecodeStringToBytes(PalettePNG));
  Graphic:=nil; Bitmap:=TBitmap.Create;
  try
    Graphic:=CreateGraphicFromStream(Stream); Require(Assigned(Graphic),'Gallery PNG decoder failed');
    Bitmap.PixelFormat:=pf24bit; Bitmap.SetSize(2,2);
    Bitmap.Canvas.Brush.Color:=clWhite; Bitmap.Canvas.FillRect(Rect(0,0,2,2));
    Bitmap.Canvas.StretchDraw(Rect(0,0,2,2),Graphic);
    Require(ColorToRGB(Bitmap.Canvas.Pixels[0,0])=ColorToRGB(clWhite),'Gallery transparency became black');
    Require(ColorToRGB(Bitmap.Canvas.Pixels[1,0])=ColorToRGB(clRed),'Gallery foreground pixel differs');
  finally Bitmap.Free; Graphic.Free; Stream.Free; end;
  Writeln('PASS feedback529 block chapter boundaries, inline labels and transparent palette pixels');
  TestFeedback529JXL(Collection);

  Collection.GetStatistics(A,B,S);
  SavedNotes:=VarToStr(Collection.GetProperty(PROP_NOTES));
  Collection.SetProperty(PROP_NOTES,'Длинное примечание: '+StringOfChar('Я',1800));
  Form:=TfrmStat.Create(nil);
  try
    Watch:=TStopwatch.StartNew; Form.LoadCollectionInfo(Collection);
    Require(Watch.ElapsedMilliseconds<1000,'Statistics blocked before the form could appear');
    Require(Form.Loading and (Form.lvInfo.Items[5].SubItems[0]='Подсчёт…'),
      'Statistics counted synchronously before the first timer');
    Form.Show; WaitCollectionStatistics(Form);
    Require((Form.lvInfo.Items[4].SubItems[0]=IntToStr(A)) and
      (Form.lvInfo.Items[5].SubItems[0]=IntToStr(B)) and
      (Form.lvInfo.Items[6].SubItems[0]=IntToStr(S)),'Background counts differ from independent oracle');
    Detail:=Form.FindComponent('mmStatisticDetails') as TMemo;
    Require(Assigned(Detail) and Detail.ReadOnly and Detail.WordWrap,'Full statistics detail panel missing');
    Form.lvInfo.Selected:=Form.lvInfo.Items[3]; Application.ProcessMessages;
    Require(Pos(StringOfChar('Я',1800),Detail.Text)>0,'Full long statistics value was truncated');
    for var PPI in [96,144,192] do
    begin
      Form.ScaleForPPI(PPI); Application.ProcessMessages;
      Require((Detail.Top>=Form.lvInfo.Top+Form.lvInfo.Height) and
        (Detail.Top+Detail.Height<=Form.btnClose.Top),'Statistics details overlap list or close button');
    end;
    if GetEnvironmentVariable('HLRU_FEEDBACK529_VISUAL')='1' then
    begin
      Form.ScaleForPPI(96); Form.Hide; Form.ShowModal;
    end;
    Form.LoadCollectionInfo(Collection); Form.Hide;
    Watch:=TStopwatch.StartNew; FreeAndNil(Form);
    Require(Watch.ElapsedMilliseconds<1000,'Early statistics close waited for an uncancelled query');
  finally Form.Free; Collection.SetProperty(PROP_NOTES,SavedNotes); end;
  Worker:=TCollectionStatisticsWorker.Create(Settings.AppPath+'missing-statistics.hlc2',nil);
  try
    Worker.Start; Worker.WaitFor;
    Require(Worker.Done and (Worker.Error<>''),'Statistics worker did not publish a read-only open failure');
  finally Worker.Free; end;
  Writeln('PASS feedback529 asynchronous statistics, exact counts, full text, DPI and early close');
  TestFeedback529Series;
  TestCollectionBackupDescriptions;
  TestCollectionBackupRestore;
  TestCollectionBackupCleanup;
  TestSyncFolderExportSettings;
  TestBookDuplicatePreview;
  TestBookDuplicateApply;
  TestBookDuplicateLargePreview;
  if GetEnvironmentVariable('HLRU_DUPLICATE_READONLY_CATALOG')<>'' then
    TestBookDuplicateReadOnlyCatalog(GetEnvironmentVariable('HLRU_DUPLICATE_READONLY_CATALOG'));
  if GetEnvironmentVariable('HLRU_FEEDBACK529_CATALOG')<>'' then
    TestFeedback529DesktopSeries(GetEnvironmentVariable('HLRU_FEEDBACK529_CATALOG'));
end;
