procedure TestHistoryCacheWriteSafety;
var Root, Target, Previous, Foreign: string; Held: THandle;
begin
  RequireIsolatedRegression;
  Root:=TPath.Combine(Settings.AppPath,'history-cache-write-audit'); ForceDirectories(Root);
  Target:=TPath.Combine(Root,'history.txt'); Previous:='Previous complete history'; Foreign:='Another writer owns this temporary';
  TFile.WriteAllText(Target,Previous,TEncoding.UTF8);
  TFile.WriteAllText(Target+'.new',Foreign,TEncoding.UTF8);
  Held:=CreateFile(PChar(Target),GENERIC_READ,FILE_SHARE_READ,nil,OPEN_EXISTING,0,0);
  Require(Held<>INVALID_HANDLE_VALUE,'Cannot lock the private history fixture');
  try
    WriteUpdateHistory(Target,'Replacement that must fail while target is locked');
    Require(ReadUpdateHistory(Target)=Previous,'Locked cache lost previous history');
    Require(ReadUpdateHistory(Target+'.new')=Foreign,'History writer overwrote another temporary file');
    Require(Length(TDirectory.GetFiles(Root))=2,'Failed history write left its temporary behind');
  finally CloseHandle(Held); end;
  TFile.SetAttributes(Target,[TFileAttribute.faReadOnly]);
  try
    WriteUpdateHistory(Target,'Replacement that must fail on a read-only cache');
    Require(ReadUpdateHistory(Target)=Previous,'Read-only cache lost previous history');
    Require(Length(TDirectory.GetFiles(Root))=2,'Read-only history write left a temporary behind');
  finally TFile.SetAttributes(Target,[]); end;
  WriteUpdateHistory(Target,'Новая история: ё, ї, ў 😀');
  Require(ReadUpdateHistory(Target)='Новая история: ё, ї, ў 😀','Unicode history replacement was corrupted');
  WriteUpdateHistory(Target,'');
  Require(ReadUpdateHistory(Target)='Новая история: ё, ї, ў 😀','Empty response erased useful history');
  Require(ReadUpdateHistory(Target+'.new')=Foreign,'Successful history write touched a foreign temporary');
  Writeln('PASS update history cache preserves locked/read-only/empty histories and foreign temporaries, cleans failed writes and saves Unicode');
end;

procedure TestUpdateNotesPaging;
var Host: TForm; View: TUpdateNotesView; More: TButton; Text, NewText: string;
  FirstBody: TRichEdit; SavedTheme: Boolean;
begin
  SavedTheme:=MHLThemeDark;
  try
    for var Dark in [False,True] do
    for var DPI in [96,144,192] do
    begin
      SetMHLTheme(Dark); Host:=TForm.CreateNew(nil);
      try
        Host.ClientWidth:=620; Host.ClientHeight:=420;
        View:=TUpdateNotesView.Create(Host); View.Parent:=Host; View.Align:=alClient;
        Text:='';
        for var I:=10 downto 1 do Text:=Text+'HomeLib Ru 2.7.0_pre5.'+IntToStr(100+I)+sLineBreak+
          '- Owned paging notes '+IntToStr(I)+sLineBreak;
        View.Load(Text); Host.ScaleForPPI(DPI);
        More:=View.FindComponent('UpdateNotesMore') as TButton;
        Require((View.SectionCount=3) and Assigned(More) and More.Visible and More.TabStop and
          (More.Caption='Показать ещё 3'),'History did not initially create exactly three releases');
        FirstBody:=View.SectionNotes(0); View.SetExpanded(1,True);
        More.Click;
        Require((View.SectionCount=6) and (View.SectionNotes(0)=FirstBody) and View.IsExpanded(1),
          'First history batch recreated existing notes or lost expanded state');
        Require(string(View.SectionNotes(3).Text).Contains('notes 7'),'History paging skipped or duplicated a release');
        View.Load(Text);
        Require(View.SectionCount=6,'Identical history reset its loaded batches');
        View.Load(Text+sLineBreak+'Refreshed final release.');
        Require((View.SectionCount=6) and View.IsExpanded(1),'History refresh lost loaded batches');
        for var Zoom in [80,100,200] do
        begin
          View.ZoomPercent:=Zoom;
          Require((More.Width>0) and (More.Height>=MulDiv(30,DPI,96)),
            'History paging action collapsed at a supported zoom or DPI');
        end;
        More.Click;
        Require((View.SectionCount=9) and (More.Caption='Показать ещё 1'),
          'Second history batch was not exactly three releases');
        More.Click;
        Require((View.SectionCount=10) and not More.Visible and not More.TabStop and
          string(View.SectionNotes(9).Text).Contains('notes 1') and
          string(View.SectionNotes(9).Text).Contains('Refreshed final release.'),
          'Final history batch lost its text or retained an empty action');
        More.Click; Require(View.SectionCount=10,'Completed history grew beyond its end');
        NewText:='SQLite 3.54.1'+sLineBreak+'Other component.';
        View.Load(NewText);
        Require((View.SectionCount=1) and not More.Visible and
          string(View.SectionNotes(0).Text).Contains('Other component.'),'Component switch retained another history');
        View.Load(Text); Require((View.SectionCount=3) and More.Visible,
          'Switching back eagerly recreated the complete history');
        View.Load('HomeLibre 3.0 release'+sLineBreak+'Stable notes.'+sLineBreak+
          'HomeLibre 3.0 beta 1'+sLineBreak+'Beta notes.'+sLineBreak+
          'HomeLib Ru 2.7.0_pre5.37'+sLineBreak+'Legacy notes.');
        Require((View.SectionCount=3) and not More.Visible and
          string(View.SectionHeader(0).Caption).Contains('HomeLibre 3.0 release') and
          string(View.SectionNotes(1).Text).Contains('Beta notes.') and
          string(View.SectionNotes(2).Text).Contains('Legacy notes.'),
          'HomeLibre beta/release headings lost sections or previous HomeLib Ru history');
      finally Host.Free; end;
    end;
  finally SetMHLTheme(SavedTheme); end;
  Writeln('PASS update history loads 3 then 3 then 3 then the remainder, preserves existing notes, refresh and expansion, hides completed action in both themes at 96/144/192 DPI');
end;

procedure TestPost525UpdateDetails;
const News = 'NEW IN VERSION 3.5.30'#10'------------------------'#10'- source only'#10#10+
  'NEW IN VERSION 3.5.29'#10'------------------------'#10'- latest fixes'#10#10+
  'NEW IN VERSION 3.5.28'#10'------------------------'#10'- previous fixes'#10#10+
  'NEW IN VERSION 3.5.26'#10'------------------------'#10'- older fixes';
  WindowsFiles = '<tr><a href="/projects/djvu/files/DjVuLibre_Windows/3.5.29%2B4.12/">3.5.29</a>'+
  '<td headers="files_date_h"><abbr title="2025-07-14 02:04:29 UTC">2025-07-14</abbr></td></tr>'+
  '<tr><a href="/projects/djvu/files/DjVuLibre_Windows/3.5.28+4.12/">3.5.28</a>'+
  '<td headers="files_date_h"><abbr title="2020-11-20 18:54:04 UTC">2020-11-20</abbr></td></tr>';
var Info, Untouched: TProgramRelease; Components: TComponentReleases;
  Popup: TfrmProgramUpdate; Notes: TUpdateNotesView; Selector: TListView;
  Count, Comparison: Integer; Dark: Boolean;
  procedure Display(const ID, Version, Expected: string);
  begin Require(ComponentDisplayVersion(ID,Version)=Expected,ID+' display '+Version); end;
begin
  TestHistoryCacheWriteSafety;
  TestUpdateNotesPaging;
  Count:=0;
  for var Control in frmMain do if Control is TfrmProgramUpdate then Inc(Count);
  Require(Count=0,'Ordinary startup constructs the hidden updater');
  Display('SQLite','3.54.1.0','3.54.1'); Display('SQLite','3.54.0.0','3.54.0');
  Display('SumatraPDF','3.6.1.0','3.6.1'); Display('SumatraPDF','3.6.0.0','3.6');
  Display('SumatraPDF','3.6.1.2','3.6.1.2'); Display('DocSharp','0.21.0.0','0.21.0');
  Display('7-Zip','26.4.0.0','26.04'); Display('7-Zip','26.04','26.04');
  Display('7-Zip','26.5.0.0','26.05');
  Display('7-Zip','26.4.0.1','26.4.0.1'); Display('7-Zip','bad','bad');
  Display('7-Zip','26.65536.0.0','26.65536.0.0');
  Display('AlReader','2.5.1009.25','2.5.1009.25');
  Require(CompareComponentVersions('26.04','26.4.0.0',Comparison) and (Comparison=0),
    'Display spelling broke version equality');
  Info:=Default(TProgramRelease); Info.ComponentID:='DjVuLibre'; Info.ComponentVersion:='3.5.29';
  Require(ParseDjVuHistory(News,WindowsFiles,Info),'DjVu NEWS was not parsed');
  Require((Info.PublishedAt='2025-07-14') and Info.History.Contains('3.5.29 — 14.07.2025') and
    Info.History.Contains('3.5.28 — 20.11.2020'),'DjVu Windows dates were lost');
  Require(not Info.History.Contains('3.5.30'),'Source-only version is offered as Windows history');
  Require(Info.History.Contains('Дата Windows-пакета не опубликована'),'Unknown date was invented');
  Require(ComponentChanges(Info,'3.5.28').Contains('latest fixes') and
    not ComponentChanges(Info,'3.5.28').Contains('previous fixes'),'DjVu changes ignore installed version');
  Untouched:=Info;
  Require(not ParseDjVuHistory('<html>Error</html>',WindowsFiles,Info) and
    (Info.History=Untouched.History),'Invalid NEWS overwrites useful history');
  Require(ParseDjVuHistory(News,WindowsFiles.Replace('2025-07-14','2025-02-31'),Info) and
    (Info.PublishedAt=''),'Invalid calendar date is displayed');
  Require(ParseDjVuHistory(News,WindowsFiles,Info),'Cannot restore valid NEWS');
  Dark:=MHLThemeDark;
  try
    for var Theme in [False,True] do
    begin
      SetMHLTheme(Theme); Popup:=CreateTestProgramUpdate;
      try
        Notes:=nil; Selector:=nil;
        for var Index:=0 to Popup.ControlCount-1 do
        begin
          if Popup.Controls[Index] is TUpdateNotesView then Notes:=TUpdateNotesView(Popup.Controls[Index]);
          if Popup.Controls[Index] is TListView then Selector:=TListView(Popup.Controls[Index]);
        end;
        Require(Assigned(Notes) and Assigned(Selector),'Updater controls absent');
        Require(Selector.Items[1].SubItems[0]='3.54.1','SQLite table still has file-version zeros');
        Require(Selector.Items[3].SubItems[0]='3.6.1','Sumatra table still has file-version zeros');
        Require(Selector.Items[5].SubItems[0]='26.05','7-Zip table lost leading zero');
        Components:=Default(TComponentReleases); Components[3]:=Info;
        Popup.ComponentsReceived(Components,True,'');
        Selector.Items[4].Selected:=True; Selector.ItemFocused:=Selector.Items[4];
        Selector.OnSelectItem(Selector,Selector.Items[4],True);
        for var DPI in [96,144,192] do
        begin
          Popup.ScaleForPPI(DPI);
          for var Zoom in [80,100,200] do
          begin
            Notes.ZoomPercent:=Zoom;
            Require((Notes.SectionCount=3) and Notes.IsExpanded(0) and not Notes.IsExpanded(1),
              'DjVu versions are merged or previous versions expanded');
            Require((Pos('14.07.2025',Notes.SectionHeader(0).Caption)>0) and
              (Pos('20.11.2020',Notes.SectionHeader(1).Caption)>0),'DjVu dates missing in actual controls');
            Require((Pos('latest fixes',Notes.SectionNotes(0).Text)>0) and
              (Pos('previous fixes',Notes.SectionNotes(0).Text)=0),'Next release body leaked into current');
          end;
        end;
        if ParamStr(2)='visual' then
        begin
          Popup.ScaleForPPI(96); Notes.ZoomPercent:=100; Popup.Width:=980; Popup.Height:=780;
          var VisualHistory:=Info.History;
          for var Older:=25 downto 22 do VisualHistory:=VisualHistory+sLineBreak+sLineBreak+
            'DjVuLibre 3.5.'+IntToStr(Older)+sLineBreak+'- Additional owned history fixture.';
          Notes.Load(VisualHistory);
          Popup.Show;
          while Popup.Visible do begin Application.ProcessMessages; CheckSynchronize(0); Sleep(10); end;
        end;
      finally Popup.Free; end;
    end;
  finally SetMHLTheme(Dark); end;
  Writeln('PASS lazy startup, author version display, DjVu date parsing and separate versions in both themes at 96/144/192 DPI');
end;
