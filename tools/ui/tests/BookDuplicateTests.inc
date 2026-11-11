procedure TestBookDuplicatePreview;
var C: IBookCollection; CID, A, B, D, GroupID, Calls: Integer; Book, Other: TBookRecord;
  DB: TSQLiteDatabase; Plan: TBookDuplicatePlan; Name, ReaderFile, Before: string;
  Values: TArray<TDuplicateBook>; Page: TArray<TDuplicateGroup>; Failed: Boolean;
  Dialog: TfrmBookDuplicates; GroupsList, CopiesList: TListView;
  Prefer: TButton; SelectGroup: TCheckBox;
  procedure Identity(ID: Integer; const Value: string);
  begin DB.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=?',[Value,ID]); end;
begin
  Book:=Default(TBookRecord); Book.Title:='Заголовок'; Book.Size:=100; Book.Lang:='ru'; Book.FileExt:='.fb2';
  Book.LibID:='merged:old:merged:new:flibusta:42';
  Other:=Book; Other.LibID:='flibusta:42'; Other.Title:='Заголовок [litres]'; Other.Size:=300;
  Require(DuplicateCandidateKey(Book,'mixed')=DuplicateCandidateKey(Other,'mixed'),
    'Nested merge wrappers or source title variants conceal a duplicate candidate');
  Other.LibID:='librusec:42';
  Require(DuplicateCandidateKey(Book,'mixed')<>DuplicateCandidateKey(Other,'mixed'),'Library ID collision grouped unrelated books');
  Other:=Book; Other.Lang:='en';
  Require(DuplicateCandidateKey(Book,'mixed')<>DuplicateCandidateKey(Other,'mixed'),'Duplicate candidate mixed languages');
  Other:=Book; Other.FileExt:='.epub';
  Require(DuplicateCandidateKey(Book,'mixed')<>DuplicateCandidateKey(Other,'mixed'),'Duplicate candidate mixed formats');
  Book.LibID:='42'; Book.Folder:='f.fb2-40-50.7z';
  Require(DuplicateCandidateKey(Book,'mixed').StartsWith('flibusta:42'),'Archive namespace was not inferred');
  Book.Folder:=''; Require(DuplicateCandidateKey(Book,'mixed')='','Unscoped mixed-library ID was accepted');
  Book.LibID:='flibusta:0'; Require(DuplicateCandidateKey(Book,'flibusta')='','Zero ID grouped placeholders');
  Book.LibID:='flibusta:42'; Book.Size:=0;
  Require(DuplicateCandidateKey(Book,'flibusta')='','Empty file grouped as an actual book');
  Book.Size:=100; Include(Book.BookProps,bpIsDeleted);
  Require(DuplicateCandidateKey(Book,'flibusta')='','Deleted placeholder grouped as an actual book');

  CID:=SystemDB.CreateCollection('Duplicate preview',Settings.AppPath,'duplicates-preview.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  C:=SystemDB.GetCollection(CID);
  A:=AddBook(C,'Одна книга','Автор','ru','Серия','');
  B:=AddBook(C,'Одна книга [litres]','Автор','ru','Другая серия','');
  D:=AddBook(C,'Другая библиотека','Автор','ru','','');
  Name:=Settings.ExpandCollectionFileName(VarToStr(C.GetProperty(PROP_DATAFILE)));
  ReaderFile:=TPath.Combine(Settings.AppPath,'duplicate-reader\reader.ini'); ForceDirectories(ExtractFilePath(ReaderFile));
  DB:=TSQLiteDatabase.Create(Name);
  try
    Identity(A,'flibusta:42'); Identity(B,'merged:source:flibusta:42'); Identity(D,'librusec:42');
  finally DB.Free; end;
  C.SetRate(CreateBookKey(B,CID),5);
  Before:=THashSHA2.GetHashStringFromFile(Name);
  Plan:=TBookDuplicatePlan.Create(Name,Settings.AppPath,'mixed',Settings.SystemFileName[sfSystemDB],ReaderFile,CID,Settings.WorkPath);
  try
    Plan.Preview;
    Require(Plan.Ready and (Plan.GroupCount=1) and (Plan.Scanned=3),'Duplicate preview count differs');
    Page:=Plan.Groups(0,50); GroupID:=Page[0].ID;
    Require((Length(Page)=1) and (Page[0].Count=2) and not Page[0].Selected and (Plan.SelectedCount=0),
      'Duplicate preview preselected destructive changes');
    Values:=Plan.Books(GroupID);
    Require((Length(Values)=2) and (Values[0].Book.BookKey.BookID=A) and
      not Values[0].HasPersonalData and Values[1].HasPersonalData,'Duplicate preview missed a personal card');
    Failed:=False;
    try Plan.Choose(GroupID,A,True); except on E: EInvalidOperation do Failed:=True; end;
    Require(Failed and (Plan.SelectedCount=0),'Preview allows removing a personal-data owner');
    Plan.Choose(GroupID,B,True); Require(Plan.SelectedCount=1,'Preferred duplicate was not retained');
    Plan.Choose(GroupID,B,False); Require(Plan.SelectedCount=0,'Duplicate group deselection did not persist');
    Require(Length(Plan.Groups(50,50))=0,'Duplicate paging repeated earlier groups');
    Failed:=False;
    try Plan.Groups(0,101); except on E: EArgumentOutOfRangeException do Failed:=True; end;
    Require(Failed,'Unbounded duplicate page request was accepted');
    Require(THashSHA2.GetHashStringFromFile(Name)=Before,'Read-only duplicate preview changed the catalog');
    Calls:=0; Failed:=False;
    try
      Plan.Preview(function: Boolean begin Inc(Calls); Result:=True; end);
    except on E: EAbort do Failed:=True; end;
    Require(Failed and not Plan.Ready and not Assigned(SQLiteCancelCallback),'Canceled duplicate scan retained a ready plan or callback');
    Plan.Preview;
    Require(Plan.Ready and (Plan.SelectedCount=0),'Duplicate preview could not restart after cancellation');
    // Snapshot reads remain consistent even when another connection changes metadata.
    DB:=TSQLiteDatabase.Create(Name);
    try DB.ExecSQL('UPDATE Books SET BookSize=? WHERE BookID=?',[200,A]); finally DB.Free; end;
    Values:=Plan.Books(GroupID);
    Require(Values[0].Book.Size=100,'Preview changed under the user while reviewing copies');
    TFile.WriteAllText(ReaderFile,'[Book.binding]'+#13#10+'CollectionID='+IntToStr(CID)+#13#10+
      'CatalogBookID='+IntToStr(A),TEncoding.UTF8);
    Plan.Preview; Values:=Plan.Books(Plan.Groups(0,1)[0].ID);
    Require(Values[0].HasPersonalData and Values[1].HasPersonalData,'Reader binding was not protected');
    Failed:=False;
    try Plan.Choose(Plan.Groups(0,1)[0].ID,B,True); except on E: EInvalidOperation do Failed:=True; end;
    Require(Failed and (Plan.SelectedCount=0),'Conflicting personal-data owners can be consolidated');
    Dialog:=TfrmBookDuplicates.CreateForCollection(frmMain,C);
    try
      Require(not Dialog.Plan.Ready and (Dialog.Plan.Scanned=0),'Duplicate window scanned a catalog during construction');
      Dialog.Plan.Preview; Dialog.Show; Dialog.RenderPage; Application.ProcessMessages;
      GroupsList:=Dialog.FindComponent('lvDuplicateGroups') as TListView;
      CopiesList:=Dialog.FindComponent('lvDuplicateCopies') as TListView;
      Require((GroupsList.Items.Count=1) and (CopiesList.Items.Count=2),'Duplicate window did not render the chosen page and copies');
      Require((CopiesList.Columns.Count=7) and (CopiesList.Columns[1].Caption='Источник') and
        (CopiesList.Columns[5].Caption='Файл / архив') and (CopiesList.Columns[6].Caption='Автор') and
        CopiesList.Items[0].SubItems[2].Contains('КБ'),
        'Duplicate comparison hides source, author or readable size');
      CopiesList.Items[1].Selected:=True;
      Prefer:=Dialog.FindComponent('btnPreferDuplicateCopy') as TButton;
      Prefer.OnClick(Prefer);
      Require((CopiesList.Items[1].Caption='Основная') and (CopiesList.Items[0].Caption='—'),
        'Preferred duplicate has no persistent visible marker');
      CopiesList.Items[0].Selected:=True;
      Require((Dialog.FindComponent('mmDuplicateCopyDetails') as TMemo).Lines[0]='Основная запись: '+IntToStr(B),
        'Selecting another copy concealed the preferred book identity');
      SelectGroup:=Dialog.FindComponent('cbSelectDuplicateGroup') as TCheckBox;
      SelectGroup.Checked:=True;
      Require(Dialog.Plan.SelectedCount=1,'Duplicate window lost preferred copy or explicit selection');
      Require((CopiesList.Items[1].Caption='Основная') and (CopiesList.Items[0].Caption='К удалению'),
        'Review rows did not show which file would be removed');
      for var PPI in [96,144,192,96] do
      begin
        Dialog.ScaleForPPI(PPI); Application.ProcessMessages;
        Require((GroupsList.Width>100) and (CopiesList.Height>50) and
          (SelectGroup.Top+SelectGroup.Height<=SelectGroup.Parent.ClientHeight),
          'Duplicate layout clips copy controls at '+IntToStr(PPI));
      end;
      CheckSourceDialogLayout(Dialog);
      Require((Dialog.ClientWidth=1040) and (Dialog.ClientHeight=640),'Duplicate dialog scale did not return to its original dimensions');
      if GetEnvironmentVariable('HLRU_FEEDBACK529_VISUAL')='duplicates' then begin Dialog.Hide; Dialog.ShowModal; end;
    finally Dialog.Free; end;
    TFile.WriteAllText(TPath.Combine(ExtractFilePath(ReaderFile),'reader-notes.json'),'{broken',TEncoding.UTF8);
    Failed:=False;
    try Plan.Preview; except on E: Exception do Failed:=True; end;
    Require(Failed and not Plan.Ready,'Corrupt reader notes were treated as an empty store');
  finally Plan.Free; end;
  Writeln('PASS duplicate preview: scoped identity, snapshot, personal protection, explicit choice, paging, cancellation and read-only catalog');
end;

procedure TestBookDuplicateSourcePreference;
var C: IBookCollection; DB: TSQLiteDatabase; Plan: TBookDuplicatePlan;
  CID, BaseID, Preferred, PersonalPreferred, ManualID, ManualGroup, BookmarkID, ThirdID, Calls: Integer;
  Name, ReaderFile, Before: string; Failed: Boolean;
  BookmarkBook: TBookRecord; Ini: TMemIniFile;
  Dialog: TfrmBookDuplicates; ChoosePriority, MoveUp: TButton;
  Unmarked: TCheckBox; GroupsList: TListView; PriorityList: TListBox; PriorityForm: TForm;
  function AddCopy(const Identity, SourceID: string; Rate: Integer = 0): Integer;
  begin
    Result:=AddBook(C,'Книга '+Identity,'Автор','ru','','');
    DB.ExecSQL('UPDATE Books SET LibID=?,Rate=? WHERE BookID=?',
      [IfThen(SourceID='','flibusta:'+Identity,'merged:'+SourceID+':flibusta:'+Identity),Rate,Result]);
  end;
begin
  CID:=SystemDB.CreateCollection('Base source',Settings.AppPath,'source-duplicates.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  C:=SystemDB.GetCollection(CID);
  C.SetProperty(PROP_CATALOG_SOURCES,'[{"id":"preferred","name":"Источник ''Б''"},'+
    '{"id":"third","name":"Third source"},{"id":"same-base","name":"Base source"}]');
  Name:=Settings.ExpandCollectionFileName(VarToStr(C.GetProperty(PROP_DATAFILE)));
  DB:=TSQLiteDatabase.Create(Name);
  try
    BaseID:=AddCopy('1',''); Preferred:=AddCopy('1','preferred');
    AddCopy('2','preferred'); AddCopy('2','preferred');
    AddCopy('3',''); AddCopy('3','preferred'); AddCopy('3','preferred');
    AddCopy('4','',5); AddCopy('4','preferred');
    AddCopy('5',''); PersonalPreferred:=AddCopy('5','preferred',5);
    AddCopy('6','unknown'); AddCopy('6','preferred');
    ManualID:=AddCopy('7',''); AddCopy('7','preferred');
    BookmarkID:=AddCopy('8',''); AddCopy('8','preferred');
    AddCopy('9',''); AddCopy('9','preferred'); ThirdID:=AddCopy('9','third');
    AddCopy('10',''); AddCopy('10','preferred'); AddCopy('10','same-base');
  finally DB.Free; end;
  ReaderFile:=TPath.Combine(Settings.AppPath,'source-duplicate-reader\reader.ini');
  ForceDirectories(ExtractFilePath(ReaderFile));
  C.GetBookRecord(CreateBookKey(BookmarkID,CID),BookmarkBook,False);
  Ini:=TMemIniFile.Create(ReaderFile,TEncoding.UTF8);
  try
    Ini.WriteString('Bookmarks.'+ReaderNoteIdentity(ReaderHistoryName(BookmarkBook,'mixed')),'Positions','0');
    Ini.UpdateFile;
  finally Ini.Free; end;
  Before:=THashSHA2.GetHashStringFromFile(Name);
  Plan:=TBookDuplicatePlan.Create(Name,Settings.AppPath,'mixed',Settings.SystemFileName[sfSystemDB],ReaderFile,CID,Settings.WorkPath);
  try
    Plan.Preview; Require(Plan.GroupCount=10,'Source preference fixture lost candidate groups');
    Require(Length(Plan.Sources)=3,'Source preference includes an unknown source or loses one of the three known sources');
    ManualGroup:=0;
    for var Group in Plan.Groups(0,50) do
      if Group.KeepID=ManualID then ManualGroup:=Group.ID;
    Require(ManualGroup<>0,'Missing manual source group'); Plan.Choose(ManualGroup,ManualID,True);
    Require(Plan.SelectSource('Источник ''Б''')=2,'Source rule accepted an ambiguous, same-source, unknown or protected group');
    Require(Plan.SelectedCount=3,'Source rule replaced manual selections');
    for var Group in Plan.Groups(0,50) do
      if Group.Selected then
        Require((Group.KeepID=Preferred) or (Group.KeepID=PersonalPreferred) or
          ((Group.ID=ManualGroup) and (Group.KeepID=ManualID)), 'Source rule kept the wrong copy');
    Require(Plan.SelectSource('Источник ''Б''')=0,'Repeating source selection replaced existing choices');
    Plan.ClearSelection; Require(Plan.SelectedCount=0,'Clear selection left marked groups');
    Calls:=0; Failed:=False;
    try Plan.SelectSource('Источник ''Б''',function: Boolean begin Inc(Calls); Result:=True; end);
    except on E: EAbort do Failed:=True; end;
    Require(Failed and (Calls>0) and (Plan.SelectedCount=0) and not Assigned(SQLiteCancelCallback),
      'Canceled source preference changed choices or retained its cancellation callback');
    Require(Plan.SelectSource('Источник ''Б''')=3,'Source preference failed to restart after cancellation');
    Plan.ClearSelection;
    Require(Plan.SelectSourcePriority(['Источник ''Б''','Base source'])=3,
      'Ranked source selection accepted a group with an unranked source');
    Plan.ClearSelection;
    Plan.Choose(ManualGroup,ManualID,True);
    Calls:=0; Failed:=False;
    try Plan.SelectSourcePriority(['Third source','Источник ''Б''','Base source'],
      function: Boolean begin Inc(Calls); Result:=Calls>=2; end);
    except on E: Exception do Failed:=True; end;
    Require(Failed and (Plan.SelectedCount=1) and not Assigned(SQLiteCancelCallback),
      'Canceling ranked selection changed manual choices or retained the cancellation callback');
    Require(Plan.SelectSourcePriority(['Third source','Источник ''Б''','Base source'])=3,
      'Ranked source selection did not add the safe triple and pairs');
    Require((Plan.SelectedCount=4) and (Plan.SelectedRemovedCount=5) and (Length(Plan.Groups(0,50,True))=6),
      'Ranked source selection or unmarked filter returned incorrect counts');
    for var Group in Plan.Groups(0,50) do
      if Group.Selected then
        Require((Group.KeepID=ThirdID) or (Group.KeepID=Preferred) or (Group.KeepID=PersonalPreferred) or
          ((Group.ID=ManualGroup) and (Group.KeepID=ManualID)),'Ranked source selection kept the wrong copy');
    for var Group in Plan.Groups(0,50) do
      if Group.KeepID=ThirdID then Plan.Choose(Group.ID,Group.KeepID,False);
    Require(Plan.SelectSourcePriority(['Base source','Third source','Источник ''Б'''])=3,
      'Changing priority did not recalculate automatic choices and exclusions');
    var BaseSelected:=False;
    for var Group in Plan.Groups(0,50) do
    begin
      if Group.KeepID=BaseID then BaseSelected:=Group.Selected;
      if Group.KeepID=ThirdID then Require(not Group.Selected,'Explicitly unmarked group was selected again');
      Require(Group.KeepID<>PersonalPreferred,'A newly excluded automatic choice was left in place');
    end;
    Require(BaseSelected and (Plan.SelectedCount=4) and (Plan.SelectedRemovedCount=4),
      'Changing priority did not keep the new first source and preserve manual marks');
    Require(THashSHA2.GetHashStringFromFile(Name)=Before,'Source selection modified the source catalog');
  finally Plan.Free; end;
  Dialog:=TfrmBookDuplicates.CreateForCollection(frmMain,C);
  try
    Dialog.Plan.Preview; Dialog.Show; Dialog.RenderPage;
    ChoosePriority:=Dialog.FindComponent('btnSelectDuplicateSource') as TButton;
    Unmarked:=Dialog.FindComponent('cbUnmarkedDuplicateGroups') as TCheckBox;
    GroupsList:=Dialog.FindComponent('lvDuplicateGroups') as TListView;
    Require(ChoosePriority.Enabled and Unmarked.Visible,'Ranked source controls are unavailable');
    TThread.ForceQueue(nil,
      procedure
      begin
        PriorityForm:=Screen.ActiveForm;
        if Assigned(PriorityForm) and (PriorityForm.Name='DuplicateSourcePriorityForm') then
        begin
          PriorityList:=PriorityForm.FindComponent('lbDuplicateSourcePriority') as TListBox;
          MoveUp:=PriorityForm.FindComponent('btnRaiseDuplicateSourcePriority') as TButton;
          PriorityList.ItemIndex:=PriorityList.Items.IndexOf('Third source');
          MoveUp.Click;
          PriorityForm.ModalResult:=mrOk;
        end
        else if Assigned(PriorityForm) then PriorityForm.ModalResult:=mrCancel;
      end);
    ChoosePriority.Click;
    Require((Dialog.Plan.SelectedCount>0) and (Length(Dialog.Plan.Groups(0,50,True))<10),
      'Ranked source dialog did not apply the chosen source order');
    Failed:=True;
    for var Group in Dialog.Plan.Groups(0,50) do
      if Group.Selected and (Group.KeepID=ThirdID) then Failed:=False;
    Require(not Failed,'Moving the third source to the top did not keep its book');
    Unmarked.Checked:=True;
    Require(GroupsList.Items.Count=10-Dialog.Plan.SelectedCount,'Unmarked checkbox did not filter the displayed groups');
  finally Dialog.Free; end;
  Dialog:=TfrmBookDuplicates.CreateForCollection(frmMain,C);
  try
    Dialog.Plan.Preview; Dialog.RenderPage;
    var TopSource:='';
    TThread.ForceQueue(nil,
      procedure
      begin
        PriorityForm:=Screen.ActiveForm;
        if Assigned(PriorityForm) and (PriorityForm.Name='DuplicateSourcePriorityForm') then
        begin
          PriorityList:=PriorityForm.FindComponent('lbDuplicateSourcePriority') as TListBox;
          TopSource:=PriorityList.Items[0];
        end;
        if Assigned(PriorityForm) then PriorityForm.ModalResult:=mrCancel;
      end);
    TButton(Dialog.FindComponent('btnSelectDuplicateSource')).Click;
    Require(TopSource='Third source','Source priority was not restored when reopening the same collection');
  finally Dialog.Free; end;
  Writeln('PASS duplicate source preference: bulk choice, unique preferred copy, same-source and unknown exclusions, protected data, manual choices, cancellation and read-only catalog');
end;

type
  TDuplicateMemoryCounters = record
    Size, Faults: DWORD;
    PeakWorkingSet, WorkingSet, PeakPagedPool, PagedPool, PeakNonpagedPool,
      NonpagedPool, Pagefile, PeakPagefile, PrivateUsage: NativeUInt;
  end;

function DuplicateProcessMemoryInfo(Process: THandle; var Counters: TDuplicateMemoryCounters;
  Size: DWORD): LongBool; stdcall; external 'psapi.dll' name 'GetProcessMemoryInfo';

function DuplicatePrivateBytes: Int64;
var Counters: TDuplicateMemoryCounters;
begin
  Counters:=Default(TDuplicateMemoryCounters); Counters.Size:=SizeOf(Counters);
  if not DuplicateProcessMemoryInfo(GetCurrentProcess,Counters,SizeOf(Counters)) then RaiseLastOSError;
  Result:=Counters.PrivateUsage;
end;

procedure DuplicateFixtureTriggersOff(Context: TSQLite3Context; Count: Integer; Args: TSQLite3Value); cdecl;
begin SQLite3_Result_Int(Context,0); end;

procedure CheckLargeLinkedDuplicatePreview(Plan: TBookDuplicatePlan; CID: Integer; const BoundaryKey: string);
var Baseline, Peak: Int64; Watch: TStopwatch; Page: TArray<TDuplicateGroup>;
  Checked, Staged: Integer; LastMark, AliasBatched: Boolean;
begin
  Baseline:=DuplicatePrivateBytes; Peak:=Baseline; Watch:=TStopwatch.StartNew;
  Plan.PreviewLinked(nil,procedure(Current,Total: Integer) begin Peak:=Max(Peak,DuplicatePrivateBytes); end);
  Watch.Stop; Peak:=Max(Peak,DuplicatePrivateBytes);
  Require(Plan.Ready and Plan.LinkedMode and (Plan.Scanned=100001) and (Plan.GroupCount=100000),
    'Large linked preview dropped or repeated source rows');
  Page:=Plan.Groups(99950,50);
  Require((Length(Page)=50) and (Page[49].KeepID=100000),'Large linked preview lost its last page');
  Plan.ChooseCopy('large:100000',True);
  Require((Plan.SelectSource('Large source')=99999) and
    (Plan.SelectedRemovedCount=100000) and (Plan.SelectSource('Large source')=0),
    'Bulk linked selection missed part of the source or lost the existing manual choice');
  Checked:=0; Staged:=0; LastMark:=False; AliasBatched:=False;
  Plan.PrepareLinkedBatches(SystemDB.GetCollectionInfo(CID),nil,
    procedure(Current,Total: Integer)
    begin Checked:=Current; end);
  for var I:=1 to 100 do
  begin
    var Binding:=Plan.LinkedDeletionBatch(I);
    if Binding.CollectionID=0 then Break;
    var Keys:=Binding.SourceKeys;
    Require((Length(Keys)>0) and (Length(Keys)<=LINKED_DUPLICATE_BATCH_SIZE),
      'The linked preview produced an unbounded batch');
    Inc(Staged,Length(Keys));
    for var Key in Keys do LastMark:=LastMark or (Key='large:100000');
    if MatchStr('legacy-boundary-alias',Keys) then
    begin
      Require(MatchStr(BoundaryKey,Keys),'Aliases of a single file were split at a batch boundary');
      AliasBatched:=True;
    end;
  end;
  Require((Checked=100000) and (Staged=100001) and LastMark and AliasBatched,
    'Linked batches did not retain the entire marked source and its alias');
  Require((Peak-Baseline<96*Int64(1024)*1024) and (Watch.ElapsedMilliseconds<60000),
    'Large linked preview exceeded its memory or time budget');
  Writeln('PROFILE linked duplicate scan rows=',Plan.Scanned,' groups=',Plan.GroupCount,
    ' ms=',Watch.ElapsedMilliseconds,' private_growth_bytes=',Peak-Baseline);
  Writeln('PASS large linked preview pages 100000 copies and prepares a bounded batch without losing manual marks');
end;

procedure TestBookDuplicateLargePreview;
var C: IBookCollection; CID: Integer; Name, ReaderFile, Before, BoundaryKey: string;
  DB: TSQLiteDatabase; Plan: TBookDuplicatePlan; Watch: TStopwatch;
  Baseline, Peak: Int64; Page: TArray<TDuplicateGroup>; Cancel, Failed: Boolean;
begin
  CID:=SystemDB.CreateCollection('Large duplicate preview',Settings.AppPath,'duplicates-large.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  C:=SystemDB.GetCollection(CID);
  Name:=Settings.ExpandCollectionFileName(VarToStr(C.GetProperty(PROP_DATAFILE)));
  DB:=TSQLiteDatabase.Create(Name);
  try
    // Synthetic source-only records need no generated search or series data.
    DB.AddFunction('MHL_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.ExecSQL('WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000) '+
      'INSERT INTO Books(LibID,Title,UpdateDate,FileName,InsideNo,Lang,Ext,BookSize) '+
      'SELECT ''flibusta:''||((x+1)/2),''Candidate ''||((x+1)/2),''2026-10-21'',''file''||x,0,''ru'',''.fb2'',100 FROM n');
    DB.ExecSQL('INSERT INTO CatalogBookCopies(SourceKey,BookID,SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID) '+
      'SELECT ''large:''||BookID,BookID,''Large source'',?,''extra.zip'',''copy''||BookID,Ext,0,BookSize,LibID FROM Books',
      [Settings.AppPath]);
    BoundaryKey:=DB.QuerySingleString('SELECT SourceKey FROM CatalogBookCopies ORDER BY SourceKey LIMIT 1 OFFSET ?',
      [LINKED_DUPLICATE_BATCH_SIZE-1]);
    DB.ExecSQL('INSERT INTO CatalogBookCopies(SourceKey,BookID,SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID) '+
      'SELECT ''legacy-boundary-alias'',BookID,''Legacy catalogue name'',?,Root||Folder,FileName,Ext,InsideNo,BookSize,LibID '+
      'FROM CatalogBookCopies WHERE SourceKey=?',[Settings.AppPath+'legacy\',BoundaryKey]);
  finally DB.Free; end;
  ReaderFile:=TPath.Combine(Settings.AppPath,'large-duplicate-reader\reader.ini'); ForceDirectories(ExtractFilePath(ReaderFile));
  Before:=THashSHA2.GetHashStringFromFile(Name);
  Plan:=TBookDuplicatePlan.Create(Name,Settings.AppPath,'mixed',Settings.SystemFileName[sfSystemDB],ReaderFile,CID,Settings.WorkPath);
  try
    Baseline:=DuplicatePrivateBytes; Peak:=Baseline; Watch:=TStopwatch.StartNew;
    Plan.Preview(nil,procedure(Current,Total: Integer) begin Peak:=Max(Peak,DuplicatePrivateBytes); end);
    Watch.Stop; Peak:=Max(Peak,DuplicatePrivateBytes);
    Require(Plan.Ready and (Plan.Scanned=100000) and (Plan.GroupCount=50000),
      'Large duplicate preview dropped or repeated candidate pairs');
    Page:=Plan.Groups(49950,50);
    Require((Length(Page)=50) and (Page[49].KeepID=99999) and (Plan.SelectedCount=0),
      'Large duplicate paging loaded the wrong rows or preselected changes');
    Require(Peak-Baseline<64*Int64(1024)*1024,'Duplicate scan exceeded the 64 MiB growth allowance for 100000 records');
    Require(Watch.ElapsedMilliseconds<60000,'Duplicate scan took more than a minute on the synthetic 100000-record fixture');
    Writeln('PROFILE duplicate scan rows=',Plan.Scanned,' groups=',Plan.GroupCount,
      ' ms=',Watch.ElapsedMilliseconds,' private_growth_bytes=',Peak-Baseline);
    Cancel:=False; Failed:=False;
    try
      Plan.Preview(function: Boolean begin Result:=Cancel; end,
        procedure(Current,Total: Integer) begin if Current>=4096 then Cancel:=True; end);
    except on E: Exception do if Cancel then Failed:=True else raise; end;
    Require(Failed and not Plan.Ready and not Assigned(SQLiteCancelCallback),
      'Mid-scan cancellation retained a ready plan or a thread callback');
    CheckLargeLinkedDuplicatePreview(Plan,CID,BoundaryKey);
    Require(THashSHA2.GetHashStringFromFile(Name)=Before,'Large read-only scan changed the source database');
  finally Plan.Free; end;
  // Path mismatches must be rejected before the first source record is read.
  Plan:=TBookDuplicatePlan.Create(Name,TPath.Combine(Settings.AppPath,'changed-root'),'mixed',
    Settings.SystemFileName[sfSystemDB],ReaderFile,CID,Settings.WorkPath);
  try
    Failed:=False;
    try Plan.Preview; except on E: EInvalidOperation do Failed:=True; end;
    Require(Failed and not Plan.Ready and (Plan.Scanned=0),'Changed root was not rejected before a large catalog scan');
  finally Plan.Free; end;
  Writeln('PASS duplicate large preview: 100000 rows, bounded private memory, paging, early root guard and mid-scan cancellation');
end;

procedure TestBookDuplicateApply;
var C, Restored: IBookCollection; CID, A, B, Other, GroupID, RestoredID: Integer;
  Book: TBookRecord; Series: TBookSeries; Plan: TBookDuplicatePlan; Backup: TCollectionBackupPlan;
  DB: TSQLiteDatabase; Name, ReaderFile, Folder, FileA, FileB, HashA, HashB, PersonalBefore: string;
  Failed, Cancel: Boolean;
  function Value(const SQL: string; Personal: Boolean=False): string;
  var Store: TSQLiteDatabase;
  begin
    if Personal then Store:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB])
    else Store:=TSQLiteDatabase.CreateReadOnly(Name);
    try Result:=Store.QuerySingleString(SQL); finally Store.Free; end;
  end;
  function NewPlan: TBookDuplicatePlan;
  begin
    Result:=TBookDuplicatePlan.Create(Name,Settings.AppPath,'mixed',Settings.SystemFileName[sfSystemDB],ReaderFile,CID,Settings.WorkPath);
    try
      Result.Preview; GroupID:=Result.Groups(0,1)[0].ID; Result.Choose(GroupID,B,True);
    except Result.Free; raise; end;
  end;
begin
  CID:=SystemDB.CreateCollection('Duplicate apply',Settings.AppPath,'duplicates-apply.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]); C:=SystemDB.GetCollection(CID);
  A:=AddBook(C,'Duplicate source A','Author A','ru','Cycle A','prose_contemporary');
  B:=AddBook(C,'Duplicate source B','Author B','ru','Cycle B','');
  Other:=AddBook(C,'Unrelated copy','Other','en','','');
  Name:=Settings.ExpandCollectionFileName(VarToStr(C.GetProperty(PROP_DATAFILE)));
  ReaderFile:=TPath.Combine(Settings.AppPath,'duplicate-apply-reader\reader.ini'); ForceDirectories(ExtractFilePath(ReaderFile));
  DB:=TSQLiteDatabase.Create(Name);
  try
    DB.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=?',['flibusta:4242',A]);
    DB.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=?',['merged:source:flibusta:4242',B]);
  finally DB.Free; end;
  C.GetBookRecord(CreateBookKey(A,CID),Book,True); FileA:=Book.GetBookFileName;
  TFile.WriteAllText(FileA,'SOURCE A keeps its own illustrations',TEncoding.UTF8);
  C.SetCatalogBookCopy('source_a:file','Source A',Book); C.SetCatalogBookID('source_a:file',A);
  C.GetBookRecord(CreateBookKey(B,CID),Book,True); FileB:=Book.GetBookFileName;
  TFile.WriteAllText(FileB,'SOURCE B preferred unchanged file',TEncoding.UTF8);
  C.SetCatalogBookCopy('source_b:file','Source B',Book);
  // Equivalent primary paths must not create another physical copy.
  DB:=TSQLiteDatabase.Create(Name);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.ExecSQL('UPDATE Books SET Folder=? WHERE BookID=?',[TPath.Combine(Book.CollectionRoot,Book.Folder),B]);
  finally DB.Free; end;
  C.SetCatalogBookID('source_b:file',B); C.SetRate(Book.BookKey,4); C.SetProgress(Book.BookKey,38);
  SystemDB.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID,Book);
  Series:=nil; TSeriesHelper.Add(Series,0,'Publisher A',2,False);
  C.SetBookPublisherSeries(CreateBookKey(A,CID),Series);
  Series:=nil; TSeriesHelper.Add(Series,0,'Publisher B',3,False);
  C.SetBookPublisherSeries(CreateBookKey(B,CID),Series);
  DB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
  try DB.ExecSQL('UPDATE Books SET Review=X''00FF810042'', Annotation=X''41004200'' WHERE DatabaseID=?',[CID]);
  finally DB.Free; end;
  PersonalBefore:=Value('SELECT hex(Review)||hex(Annotation)||hex(ExtraInfo)||Rate||Progress FROM Books WHERE DatabaseID='+IntToStr(CID),True);
  HashA:=THashSHA2.GetHashStringFromFile(FileA); HashB:=THashSHA2.GetHashStringFromFile(FileB);
  // A committed change after preview must reject the selected old rows.
  Plan:=NewPlan;
  try
    DB:=TSQLiteDatabase.Create(Name);
    try DB.ExecSQL('UPDATE Books SET BookSize=101 WHERE BookID=?',[A]); finally DB.Free; end;
    Failed:=False;
    try Plan.Apply(TPath.Combine(Settings.AppPath,'duplicate-stale-backup'));
    except on E: EInvalidOperation do Failed:=True; end;
    Require(Failed and not Plan.Committed and (Value('SELECT count(*) FROM Books')='3'),
      'Stale duplicate preview changed the catalog');
  finally Plan.Free; end;
  // Cancel after the first actual DELETE; all metadata and links must roll back.
  Plan:=NewPlan; Cancel:=False;
  try
    Failed:=False;
    try
      Plan.Apply(TPath.Combine(Settings.AppPath,'duplicate-canceled-backup'),
        function: Boolean begin Result:=Cancel; end,
        procedure(const Stage: string; Current,Total: Integer)
        begin if (Stage='Объединение выбранных записей') and (Current=1) then Cancel:=True; end);
    except on E: EAbort do Failed:=True; end;
    Require(Failed and not Plan.Committed and (Value('SELECT count(*) FROM Books')='3'),
      'Canceled duplicate consolidation partially committed book deletion');
    Require(Value('SELECT BookID FROM CatalogSourceBooks WHERE SourceKey=''source_a:file''')=IntToStr(A),
      'Canceled consolidation retained a remapped source link');
    Require(Value('SELECT count(*) FROM Series_List WHERE BookID='+IntToStr(B))='1',
      'Canceled consolidation retained copied series memberships');
  finally Plan.Free; end;
  // The note writer and reader.ini writer use different locks.
  for var LockNotes in [False,True] do
  begin
    TFile.WriteAllText(ReaderFile,'[Reader]'+#13#10+'FontSize=20',TEncoding.UTF8);
    Plan:=NewPlan;
    try
      var LockFile:=ReaderFile;
      if LockNotes then LockFile:=TPath.Combine(ExtractFilePath(ReaderFile),'reader-notes.json.lock');
      var Handle:=CreateFile(PChar(LockFile),GENERIC_READ or GENERIC_WRITE,0,nil,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
      Require(Handle<>INVALID_HANDLE_VALUE,'Could not create fixture reader writer lock');
      try
        Failed:=False;
        try Plan.Apply(TPath.Combine(Settings.AppPath,'duplicate-writer-conflict-'+BoolToStr(LockNotes,True)));
        except on E: EInvalidOperation do Failed:=True; end;
        Require(Failed and not Plan.Committed and (Value('SELECT count(*) FROM Books')='3'),
          'Concurrent reader writer did not prevent consolidation');
      finally CloseHandle(Handle); end;
    finally Plan.Free; end;
  end;
  // A new personal card arriving after preview is also a hard conflict.
  Plan:=NewPlan;
  try
    C.SetRate(CreateBookKey(A,CID),2); Failed:=False;
    try Plan.Apply(TPath.Combine(Settings.AppPath,'duplicate-personal-conflict'));
    except on E: EInvalidOperation do Failed:=True; end;
    Require(Failed and not Plan.Committed and (Value('SELECT count(*) FROM Books')='3'),
      'Consolidation erased a new personal-data owner');
  finally Plan.Free; end;
  // Remove this deliberately created fixture card only; no user profile data.
  DB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
  try DB.ExecSQL('DELETE FROM Books WHERE DatabaseID=? AND BookID=?',[CID,A]); finally DB.Free; end;
  DB:=TSQLiteDatabase.Create(Name);
  try DB.ExecSQL('UPDATE Books SET Rate=0 WHERE BookID=?',[A]); finally DB.Free; end;
  Plan:=NewPlan; Folder:=TPath.Combine(Settings.AppPath,'duplicate-completed-backup');
  try
    Plan.Apply(Folder);
    Require(ReadCollectionBackupInfo(Folder).HasCreatedAt and
      (ReadCollectionBackupInfo(Folder).Operation=cboBooks),'Duplicate backup did not record its creation operation/date');
    Require(Plan.Committed and (Plan.Removed=1) and not Plan.Ready,'Consolidation did not publish durable completion');
    Require((Value('SELECT count(*) FROM Books')='2') and
      (Value('SELECT count(*) FROM Books WHERE BookID='+IntToStr(B))='1') and
      (Value('SELECT count(*) FROM Books WHERE BookID='+IntToStr(Other))='1'),
      'Consolidation removed a preferred or unrelated record');
    Require(Value('SELECT count(*) FROM CatalogSourceBooks WHERE BookID='+IntToStr(B))='2',
      'Consolidation lost future INPX source mappings');
    Require(Value('SELECT count(*) FROM CatalogBookCopies WHERE BookID='+IntToStr(B))='2',
      'Consolidation lost a physical copy location or duplicated an equivalent path');
    Require(Value('SELECT SourceName FROM CatalogPreferredSource WHERE BookID='+IntToStr(B))='Source B',
      'Preferred source label does not match the chosen physical copy');
    Require((C.GetCatalogBookID('source_a:file')=B) and (C.GetCatalogBookID('source_b:file')=B),
      'Future source refresh cannot resolve the consolidated record');
    Require((Value('SELECT count(*) FROM Series_List WHERE BookID='+IntToStr(B))='2') and
      (Value('SELECT count(*) FROM PublisherSeries_List WHERE BookID='+IntToStr(B))='2') and
      (Value('SELECT count(*) FROM Author_List WHERE BookID='+IntToStr(B))='2'),
      'Consolidation lost author or series relations');
    Require(Value('SELECT hex(Review)||hex(Annotation)||hex(ExtraInfo)||Rate||Progress FROM Books WHERE DatabaseID='+IntToStr(CID),True)=PersonalBefore,
      'Consolidation changed raw personal cards');
    Require(Value('SELECT count(*) FROM BookGroups WHERE DatabaseID='+IntToStr(CID)+' AND BookID='+IntToStr(B),True)='1',
      'Consolidation lost favourites membership');
    Require((THashSHA2.GetHashStringFromFile(FileA)=HashA) and (THashSHA2.GetHashStringFromFile(FileB)=HashB),
      'Consolidation changed or deleted an original book file');
    Require(Value('PRAGMA integrity_check')='ok','Consolidated catalog failed integrity check');
    Failed:=False;
    try Plan.Apply(TPath.Combine(Settings.AppPath,'duplicate-repeated-backup'));
    except on E: EInvalidOperation do Failed:=True; end;
    Require(Failed,'A committed duplicate plan can be applied twice');
  finally Plan.Free; end;
  Backup:=TCollectionBackupPlan.Create(Folder);
  try
    Backup.Preview;
    RestoredID:=Backup.RestoreAsNew(SystemDB,TPath.Combine(Settings.DataPath,'duplicate-undo.hlc2'),'Duplicate before consolidation');
    Restored:=SystemDB.GetCollection(RestoredID);
    DB:=TSQLiteDatabase.CreateReadOnly(Settings.ExpandCollectionFileName(VarToStr(Restored.GetProperty(PROP_DATAFILE))));
    try Require(DB.QuerySingleInt('SELECT count(*) FROM Books')=3,'Consolidation backup did not restore the previous catalog');
    finally DB.Free; end;
  finally Backup.Free; end;
  Writeln('PASS duplicate apply: preferred ID, raw personal cards, source links, all copies and relations, stale preview, rollback, files and recoverable backup');
end;

type
  TDuplicateFilePromptProbe = class
    Accept: Boolean;
    Count: Integer;
    DefaultNo: Boolean;
    PriorityFirst, AlsoShown: string;
    procedure Tick(Sender: TObject);
  end;

procedure TDuplicateFilePromptProbe.Tick(Sender: TObject);
begin
  for var I:=Screen.FormCount-1 downto 0 do
  begin
    var Dialog:=Screen.Forms[I];
    if not Dialog.Visible then Continue;
    if (PriorityFirst<>'') and (Dialog.FindComponent('lbDuplicateSourcePriority') is TListBox) then
    begin
      var Sources:=TListBox(Dialog.FindComponent('lbDuplicateSourcePriority'));
      var PreferredIndex:=Sources.Items.IndexOf(PriorityFirst);
      if not Assigned(Dialog.FindComponent('IncludeLinkedDuplicateFiles')) and (PreferredIndex>=0) and
        ((AlsoShown='') or (Sources.Items.IndexOf(AlsoShown)>=0)) then
      begin
        Sources.Items.Move(PreferredIndex,0);
        Dialog.ModalResult:=mrOk;
        PriorityFirst:='';
      end
      else Dialog.ModalResult:=mrCancel;
      Exit;
    end;
    if Dialog.ClassName<>'TMessageForm' then Continue;
    Inc(Count);
    for var Component in Dialog do
      if (Component is TButton) and TButton(Component).Default then
        DefaultNo:=TButton(Component).ModalResult=mrNo;
    if Accept then Dialog.ModalResult:=mrYes else Dialog.ModalResult:=mrNo;
    Exit;
  end;
end;

function RunLinkedCopyTestOperation(Operation: TBookDeletionOperation; const Kind: string): TBookDeletionOperationStatus;
begin
  Operation.Start;
  var Started:=GetTickCount64;
  while not Operation.Status.Finished do
  begin
    Require(GetTickCount64-Started<25000,'Linked deletion exceeded deadline: '+Kind);
    if Operation.Status.AwaitingArchiveConfirmation then Operation.RequestStop;
    Sleep(5);
  end;
  Operation.WaitFor;
  Result:=Operation.Status;
end;

procedure RunLinkedCopyTestSQL(const FileName, SQL: string);
begin
  var DB:=TSQLiteDatabase.Create(FileName);
  try DB.ExecSQL(SQL); finally DB.Free; end;
end;

procedure TestDuplicateFileRemoval;
var Root: string;
  DialogProbe: TDuplicateFilePromptProbe;
  Timer: TTimer;
  SavedDialogs: Boolean;

  procedure CaseCheck(const Kind, ExpectedError: string);
  var Collection, Other: IBookCollection;
    CID: Integer;
    Keep, Lose, AliasBook, BlockedKeep, BlockedLose, Third: TBookRecord;
    Form: TfrmBookDuplicates;
    Operation: TBookDeletionOperation;
    Target, TargetHash, KeepHash, Stage, SolidHash, SolidArchive, PairFolder, PreferredFile: string;
    Zip: TZipFile;
    Started: UInt64;

    function Add(const C: IBookCollection; const Title, ID, Folder, Stem: string): TBookRecord;
    var Book: TBookRecord;
    begin
      Book.Clear;
      Book.Title:=Title; Book.LibID:=ID; Book.Folder:=Folder; Book.FileName:=Stem;
      Book.FileExt:='.fb2'; Book.Size:=42; Book.Lang:='ru';
      TAuthorsHelper.Add(Book.Authors,'Duplicate test','','');
      TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
      Include(Book.BookProps,bpIsLocal);
      var NewID:=C.InsertBook(Book,False,False);
      C.GetBookRecord(CreateBookKey(NewID,C.CollectionID),Result,False);
    end;

    function CountRows(const Book: TBookRecord): Int64;
    var DB: TSQLiteDatabase;
    begin
      DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(Book.BookKey.DatabaseID).DBFileName);
      try Result:=DB.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[Book.BookKey.BookID]);
      finally DB.Free; end;
    end;

    procedure CheckLargeSolidArchive;
    begin
      var Entries:=ReadBookDeletionInventory(SolidArchive,ArchiveDeletionSourceIdentity(SolidArchive));
      for var I:=0 to High(Entries) do Entries[I]:=Entries[I].Replace('\','/');
      Require((UpdateSHA256(SolidArchive)<>SolidHash) and
        MatchStr('unselected/keep.fb2',Entries) and not MatchStr('selected/one.fb2',Entries),
        'Large 7z kept the selected member or lost its neighbour');
    end;

  begin
    Stage:=IncludeTrailingPathDelimiter(Root+Kind); ForceDirectories(Stage);
    PairFolder:='pair.zip';
    PreferredFile:=Stage+'preferred.fb2';
    if Kind='mixed-priority-lower' then
    begin
      ForceDirectories(Stage+'old');
      ForceDirectories(Stage+'preferred');
      PairFolder:='old\pair.zip';
      PreferredFile:=Stage+'preferred\preferred.fb2';
    end;
    CID:=SystemDB.CreateCollection('Duplicate files '+Kind,Stage,Stage+'books.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    Collection:=SystemDB.GetCollection(CID);
    Collection.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
    if (Kind='archive') or (Kind='batched') or Kind.StartsWith('mixed-promotion') or (Kind='mixed-priority-lower') then
    begin
      Keep:=Add(Collection,'Keep duplicate','flibusta:9001',PairFolder,'keep');
      Lose:=Add(Collection,'Remove duplicate','merged:test:flibusta:9001',PairFolder,'lose');
      Zip:=TZipFile.Create;
      try
        Zip.Open(Stage+PairFolder,zmWrite);
        for var Member in ['keep.fb2','lose.fb2','neighbour.fb2'] do
        begin
          var Text:=TStringStream.Create('Owned '+Member,TEncoding.UTF8);
          try Zip.Add(Text,Member); finally Text.Free; end;
        end;
      finally Zip.Free; end;
    end
    else
    begin
      Keep:=Add(Collection,'Keep duplicate','flibusta:9001','','keep');
      if Kind='alias' then
        Lose:=Add(Collection,'Remove duplicate','merged:test:flibusta:9001','','keep')
      else Lose:=Add(Collection,'Remove duplicate','merged:test:flibusta:9001','','lose');
      if Kind<>'missing' then TFile.WriteAllText(Keep.GetBookFileName,'Keep original bytes',TEncoding.UTF8);
      TFile.WriteAllText(Lose.GetBookFileName,'Selected temporary copy',TEncoding.UTF8);
    end;
    if Kind='priority-three' then
    begin
      Third:=Add(Collection,'Third source duplicate','merged:third:flibusta:9001','','third');
      Collection.SetCatalogBookPreferredSource(Keep.BookKey,'Keep source');
      Collection.SetCatalogBookPreferredSource(Lose.BookKey,'First redundant source');
      Collection.SetCatalogBookPreferredSource(Third.BookKey,'Second redundant source');
      TFile.WriteAllText(Third.GetBookFileName,'Second redundant file',TEncoding.UTF8);
    end;
    if Kind.StartsWith('mixed-promotion') or (Kind='mixed-priority-lower') then
    begin
      Collection.SetCatalogBookPreferredSource(Keep.BookKey,'Previous source');
      if Kind='mixed-priority-lower' then Collection.SetCatalogBookPreferredSource(Lose.BookKey,'Shared source')
      else Collection.SetCatalogBookPreferredSource(Lose.BookKey,'Redundant source');
      AliasBook:=Keep;
      if Kind<>'mixed-promotion' then AliasBook:=Lose;
      var PrimarySource:='Previous source';
      if Kind<>'mixed-promotion' then PrimarySource:='Redundant source';
      if Kind='mixed-priority-lower' then
      begin
        PrimarySource:='Shared source';
        AliasBook.CollectionRoot:=Stage+'old\';
        AliasBook.Folder:='pair.zip';
      end;
      Collection.SetCatalogBookCopy('mixed-old',PrimarySource,AliasBook);
      if Kind='mixed-priority-lower' then
      begin
        var Stale:=AliasBook;
        Stale.CollectionRoot:=Stage+'preferred\';
        Stale.Folder:=Stage+'old\pair.zip';
        Collection.SetCatalogBookCopy('mixed-old-legacy','Legacy catalogue name',Stale);
      end;
      AliasBook.Folder:=''; AliasBook.FileName:='preferred';
      if Kind='mixed-priority-lower' then
      begin
        AliasBook.CollectionRoot:=Stage+'preferred\';
        Collection.SetCatalogBookCopy('mixed-new','Shared source',AliasBook);
        var Stale:=AliasBook;
        Stale.CollectionRoot:=Stage+'old\';
        Stale.Folder:=Stage+'preferred\';
        Collection.SetCatalogBookCopy('mixed-new-legacy','Shared source',Stale);
      end
      else Collection.SetCatalogBookCopy('mixed-new','Preferred source',AliasBook);
      TFile.WriteAllText(PreferredFile,'Preferred original bytes',TEncoding.UTF8);
    end;
    Target:=Lose.GetBookFileName;
    TargetHash:=THashSHA2.GetHashStringFromFile(Target);
    if FileExists(Keep.GetBookFileName) then KeepHash:=THashSHA2.GetHashStringFromFile(Keep.GetBookFileName);
    if Kind='shared' then
    begin
      var OtherID:=SystemDB.CreateCollection('Shared duplicate reference',Stage,Stage+'other.hlc2',
        CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
      Other:=SystemDB.GetCollection(OtherID);
      AliasBook:=Add(Other,'Unselected shared file','flibusta:9002','','lose');
    end;
    if Kind = 'large-archive' then
    begin
      BlockedKeep := Add(Collection, 'Retain primary', 'flibusta:9010', '', 'retained-solid-primary');
      BlockedLose := Add(Collection, 'Large solid duplicate', 'merged:test:flibusta:9010', 'first.7z', 'selected/one');
      TFile.WriteAllText(BlockedKeep.GetBookFileName, 'Retain primary', TEncoding.UTF8);
      TFile.Copy(Settings.AppPath + 'sevenzip-delete-plan\solid-limit.7z', BlockedLose.GetBookFileName);
      SolidArchive:=BlockedLose.GetBookFileName;
      SolidHash := UpdateSHA256(SolidArchive);
    end;
    if Kind = 'large-linked' then
    begin
      BlockedKeep := Add(Collection, 'Retain primary', 'flibusta:9010', '', 'retained-linked-primary');
      BlockedLose := Add(Collection, 'Retain attached files', 'merged:test:flibusta:9010', '', 'retained-linked-book');
      for var Book in TArray<TBookRecord>.Create(BlockedKeep, BlockedLose) do
        TFile.WriteAllText(Book.GetBookFileName, 'Retained ' + Book.Title, TEncoding.UTF8);
      AliasBook := BlockedLose;
      AliasBook.Folder := 'attached.7z';
      AliasBook.FileName := 'selected/one';
      Collection.SetCatalogBookCopy('approved-solid', 'Selected source', AliasBook);
      SolidArchive := AliasBook.GetBookFileName;
      TFile.Copy(Settings.AppPath + 'sevenzip-delete-plan\solid-limit.7z', SolidArchive);
      SolidHash := UpdateSHA256(SolidArchive);
    end;
    if Kind='alternate' then
    begin
      AliasBook:=Lose; AliasBook.FileName:='alternate';
      Collection.SetCatalogBookCopy('duplicate-test-alternate','Alternate source',AliasBook);
    end;
    if Kind='combined' then
    begin
      AliasBook:=Lose; AliasBook.FileName:='approved-alt';
      Collection.SetCatalogBookCopy('approved-alt','Approved source',AliasBook);
      TFile.WriteAllText(AliasBook.GetBookFileName,'Approved alternative',TEncoding.UTF8);
      BlockedKeep:=Add(Collection,'Keep second book','flibusta:9010','','blocked-keep');
      BlockedLose:=Add(Collection,'Keep unresolved duplicate','merged:test:flibusta:9010','','blocked-lose');
      AliasBook:=BlockedLose; AliasBook.FileName:='unmarked-alt';
      Collection.SetCatalogBookCopy('unmarked-alt','Separate source',AliasBook);
      for var Name in ['blocked-keep.fb2','blocked-lose.fb2','unmarked-alt.fb2'] do
        TFile.WriteAllText(Stage+Name,'Retain '+Name,TEncoding.UTF8);
    end;
    if Kind='mixed-priority-lower' then
    begin
      Collection.SetReview(Lose.BookKey,'Keep this note');
      SystemDB.AddBookToGroup(Lose.BookKey,FAVORITES_GROUP_ID,Lose);
    end
    else
    begin
      Collection.SetReview(Keep.BookKey,'Keep this note');
      if Kind='mixed-promotion' then SystemDB.AddBookToGroup(Keep.BookKey,FAVORITES_GROUP_ID,Keep);
    end;
    Form:=TfrmBookDuplicates.CreateForCollection(frmMain,Collection);
    try
      if (Kind='combined') or (Kind='large-linked') then
      begin
        TButton(Form.FindComponent('btnFindBookDuplicates')).Click;
        Require(Form.Plan.GroupCount=2,'Combined fixture lost an ordinary duplicate group');
        for var Group in Form.Plan.Groups(0,10) do
        begin
          var KeepID:=Group.KeepID;
          for var Book in Form.Plan.Books(Group.ID) do
            if (Book.Book.BookKey.BookID=Keep.BookKey.BookID) or
               (Book.Book.BookKey.BookID=BlockedKeep.BookKey.BookID) then KeepID:=Book.Book.BookKey.BookID;
          Form.Plan.Choose(Group.ID,KeepID,True);
        end;
        Require(not TComboBox(Form.FindComponent('cbDuplicateResultKind')).Visible and
          not TButton(Form.FindComponent('btnDuplicateDetails')).Visible,'Unified list exposed technical result modes');
        if Kind = 'large-linked' then Form.LinkedPlan.ChooseCopy('approved-solid', True)
        else Form.LinkedPlan.ChooseCopy('approved-alt',True);
      end
      else if Kind='mixed-priority-lower' then
      begin
        TButton(Form.FindComponent('btnFindBookDuplicates')).Click;
        DialogProbe.PriorityFirst:='Shared source · '+UpperCase(Stage+'preferred');
        DialogProbe.AlsoShown:='Shared source · '+UpperCase(Stage+'old');
        Timer.Enabled:=True;
        try TButton(Form.FindComponent('btnSelectDuplicateSource')).Click; finally Timer.Enabled:=False; end;
        Require((DialogProbe.PriorityFirst='') and (Form.Plan.GroupCount=1) and
          (Form.Plan.Groups(0,1)[0].KeepID=Lose.BookKey.BookID) and (Form.Plan.SelectedRemovedCount=1),
          'Source-priority dialog did not distinguish same-name source folders');
        TButton(Form.FindComponent('btnFindBookDuplicates')).Click;
        Require((Form.Plan.Groups(0,1)[0].KeepID=Lose.BookKey.BookID) and (Form.Plan.SelectedRemovedCount=1),
          'A fresh scan did not apply the saved folder priority');
      end
      else if Kind.StartsWith('mixed-promotion') then
      begin
        TButton(Form.FindComponent('btnFindBookDuplicates')).Click;
        Require((Form.Plan.GroupCount=1) and
          (Form.Plan.SelectSourcePriority(['Previous source','Redundant source'])=1),
          'Could not rank the two cards');
        Require(Form.LinkedPlan.SelectSourcePriority(['Preferred source','Previous source','Redundant source'],nil,True)=1,
          'Could not stage the preferred linked file');
      end
      else if Kind='priority-three' then
      begin
        TButton(Form.FindComponent('btnFindBookDuplicates')).Click;
        Require((Form.Plan.GroupCount=1) and
          (Form.Plan.SelectSourcePriority(['Keep source','First redundant source','Second redundant source'])=1) and
          (Form.Plan.SelectedRemovedCount=2),'Could not rank all three distinct sources');
      end
      else if Kind = 'large-archive' then
      begin
        Form.Plan.Preview;
        Require(Form.Plan.GroupCount = 2, 'Unsupported archive fixture missed a duplicate group');
        for var Group in Form.Plan.Groups(0, 2) do
          for var Book in Form.Plan.Books(Group.ID) do
            if (Book.Book.BookKey.BookID = Keep.BookKey.BookID) or
              (Book.Book.BookKey.BookID = BlockedKeep.BookKey.BookID) then
              Form.Plan.Choose(Group.ID, Book.Book.BookKey.BookID, True);
      end
      else
      begin
        Form.Plan.Preview;
        Require(Form.Plan.GroupCount=1,'Fixture did not find one duplicate group: '+Kind);
        Form.Plan.Choose(Form.Plan.Groups(0,1)[0].ID,Keep.BookKey.BookID,True);
      end;
      Form.RenderPage;
      var Button:=TButton(Form.FindComponent('btnDeleteDuplicateFiles'));
      Require(Assigned(Button) and Button.Enabled,'Duplicate file action is unavailable');
      if (Kind='archive') or (Kind='batched') or (Kind='combined') then
      begin
        DialogProbe.Accept:=False; DialogProbe.Count:=0; DialogProbe.DefaultNo:=False;
        Timer.Enabled:=True;
        try Button.Click; finally Timer.Enabled:=False; end;
        Require((DialogProbe.Count=1) and DialogProbe.DefaultNo and
          not Assigned(Form.TakeDeletionOperation(Settings.SystemFileName[sfSystemDB],Stage+'deletion-journal')) and
          (THashSHA2.GetHashStringFromFile(Target)=TargetHash),
          'Cancelling duplicate file deletion changed a source or accepted a plan');
      end;
      if Kind='stale' then Collection.SetReview(Lose.BookKey,'New personal data after preview');
      if Kind='personal' then Collection.SetRate(Lose.BookKey,3);
      DialogProbe.Accept:=True; DialogProbe.Count:=0;
      Timer.Enabled:=True;
      try Button.Click; finally Timer.Enabled:=False; end;
      Operation:=Form.TakeDeletionOperation(Settings.SystemFileName[sfSystemDB],Stage+'deletion-journal');
      Require((DialogProbe.Count=1) and Assigned(Operation),'Expected one explicit destructive prompt: '+Kind);
    finally Form.Free; end;
    try
      Operation.Start;
      Started:=GetTickCount64;
      while not Operation.Status.Finished do
      begin
        Require(GetTickCount64-Started<20000,'Duplicate file removal exceeded deadline: '+Kind);
        Sleep(5);
      end;
      Operation.WaitFor;
      var State:=Operation.Status;
      if (Kind='alternate') or (Kind='stale') or (Kind='personal') then
      begin
        Require((State.Error='') and (State.SkippedDuplicates=1) and not State.CatalogueChanged and
          (CountRows(Lose)=1) and (THashSHA2.GetHashStringFromFile(Target)=TargetHash),
          'An unapproved or changed group was not skipped safely: '+Kind+' '+State.Error);
        Exit;
      end;
      if Kind = 'large-linked' then
      begin
        Require((State.Error='') and (State.PendingJournal='') and (State.SkippedDuplicates=0) and
          (State.CompletedBooks=2) and (State.CompletedCopies=1) and
          (CountRows(BlockedKeep)=1) and (CountRows(BlockedLose)=0) and
          not FileExists(BlockedLose.GetBookFileName) and not FileExists(Target),
          'Large linked 7z and its duplicate card were not both removed: '+State.Error);
        CheckLargeSolidArchive;
        Writeln('PASS duplicate cleanup removes a linked member of a large solid 7z and its duplicate card');
        Exit;
      end;
      if Kind = 'large-archive' then
      begin
        Require((State.Error='') and (State.PendingJournal='') and (State.SkippedDuplicates=0) and
          (State.CompletedBooks=2) and (CountRows(BlockedKeep)=1) and (CountRows(BlockedLose)=0) and
          not FileExists(Target),'Large solid 7z stopped the following duplicate removal: '+State.Error);
        CheckLargeSolidArchive;
        Writeln('PASS duplicate cleanup removes a member of a large solid 7z and continues with the next file');
        Exit;
      end;
      if Kind='priority-three' then
      begin
        Require((State.Error='') and (State.CompletedBooks=2) and (State.SkippedDuplicates=0) and
          (CountRows(Keep)=1) and (CountRows(Lose)=0) and (CountRows(Third)=0) and
          (Collection.GetReview(Keep.BookKey)='Keep this note') and
          not FileExists(Target) and not FileExists(Third.GetBookFileName) and
          (THashSHA2.GetHashStringFromFile(Keep.GetBookFileName)=KeepHash),
          'Three-source cleanup did not preserve exactly the preferred book: '+State.Error);
        Writeln('PASS one background cleanup physically removes both lower-priority source files and keeps the preferred card');
        Exit;
      end;
      if Kind='combined' then
      begin
        Require((State.Error='') and (State.SelectedDuplicates=3) and (State.CompletedBooks=1) and
          (State.CompletedCopies=1) and (State.SkippedDuplicates=1) and (State.DuplicateBatch=2) and
          (Length(State.SkippedDuplicateDetails)=3) and State.DuplicateSkipReport.Contains('выбраны не все файлы этой книги'),
          'Combined cleanup did not complete both lists and skip the unresolved group: '+State.Error);
        Require(not FileExists(Stage+'approved-alt.fb2') and (CountRows(BlockedKeep)=1) and
          (CountRows(BlockedLose)=1),'Combined cleanup lost an unapproved card or retained an approved copy');
        for var Name in ['blocked-keep.fb2','blocked-lose.fb2','unmarked-alt.fb2'] do
          Require(TFile.ReadAllText(Stage+Name,TEncoding.UTF8)='Retain '+Name,'Combined cleanup changed an unselected file');
        Writeln('PASS one confirmation removes files from both lists and skips groups with unapproved files');
      end;
      if (Kind='mixed-promotion') or (Kind='mixed-priority-lower') then
      begin
        if Kind='mixed-priority-lower' then
        begin
          AliasBook:=Keep; Keep:=Lose; Lose:=AliasBook;
        end;
        Require((State.Error='') and (State.CompletedCopies=1) and (State.CompletedBooks=1) and
          (State.SkippedDuplicates=0) and (State.PendingJournal='') and
          (CountRows(Keep)=1) and (CountRows(Lose)=0) and
          (Collection.GetReview(Keep.BookKey)='Keep this note'),
          'Mixed promotion and deletion did not finish: '+State.Error);
        Collection.GetBookRecord(Keep.BookKey,Keep,False);
        Require(SameFileName(Keep.GetBookFileName,PreferredFile) and
          (TFile.ReadAllText(Keep.GetBookFileName,TEncoding.UTF8)='Preferred original bytes'),
          'Retained card no longer opens the preferred source');
        if Kind='mixed-priority-lower' then
        begin
          var References:=Collection.GetCatalogBookCopies(Keep.BookKey);
          Require(Length(References)=2,'Removed a retained alias or left an alias to a deleted ZIP member');
          for var Reference in References do
            Require(SameFileName(Reference.GetBookFileName,PreferredFile),'A catalogue alias points at a removed file');
        end;
        var Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
        try
          Require(Personal.QuerySingleString('SELECT FileName FROM Books WHERE BookID=? AND DatabaseID=?',
            [Keep.BookKey.BookID,CID])='preferred','Favourite retained the old path');
        finally Personal.Free; end;
        Zip:=TZipFile.Create;
        try
          Zip.Open(Target,zmRead);
          Require((Zip.FileCount=1) and (Zip.FileNames[0]='neighbour.fb2'),
            'Mixed deletion retained a redundant archive member or removed its neighbour');
          var Data:TBytes;
          Zip.Read('neighbour.fb2',Data);
          Require(TEncoding.UTF8.GetString(Data)='Owned neighbour.fb2','Neighbour payload changed');
        finally Zip.Free; end;
        Writeln('PASS mixed cleanup promotes the preferred file and removes both lower-priority files');
        Exit;
      end;
      if ExpectedError<>'' then
      begin
        Require(State.Error.Contains(ExpectedError) and not State.CatalogueChanged and (CountRows(Lose)=1) and
          (THashSHA2.GetHashStringFromFile(Target)=TargetHash),
          'Duplicate file removal did not reject '+Kind+' before mutation: '+State.Error);
        if FileExists(Keep.GetBookFileName) then
          Require(THashSHA2.GetHashStringFromFile(Keep.GetBookFileName)=KeepHash,'Rejection changed the retained copy');
        if Kind='shared' then Require(CountRows(AliasBook)=1,'Rejection removed another collection record');
        Exit;
      end;
      Require((State.Error='') and (State.CompletedBooks=1) and (CountRows(Lose)=0) and (CountRows(Keep)=1) and
        (Collection.GetReview(Keep.BookKey)='Keep this note') and (State.PendingJournal=''),
        'Duplicate file deletion failed to finish coherently: '+Kind+' '+State.Error);
      if Kind='batched' then
        Require((State.DuplicateBatch=1) and (State.SelectedDuplicates=1),'Background duplicate progress is incomplete');
      if (Kind='archive') or (Kind='batched') then
      begin
        Zip:=TZipFile.Create;
        try
          Zip.Open(Target,zmRead);
          Require((Zip.FileCount=2) and (Zip.FileNames[0]='keep.fb2') and (Zip.FileNames[1]='neighbour.fb2'),
            'Shared ZIP lost a retained member or kept the selected file');
          for var Name in Zip.FileNames do
          begin
            var Data:TBytes; Zip.Read(Name,Data);
            Require(TEncoding.UTF8.GetString(Data)='Owned '+Name,'Shared ZIP changed an unselected payload');
          end;
        finally Zip.Free; end;
      end
      else Require(not FileExists(Target) and (THashSHA2.GetHashStringFromFile(Keep.GetBookFileName)=KeepHash),
        'Loose deletion removed the wrong file');
    finally Operation.Free; end;
  end;

  procedure CheckLinkedCopies(const Kind: string);
  var Collection: IBookCollection; Info: TCollectionInfo; Operation: TBookDeletionOperation;
    Primary, Member, Loose, Neighbour: TBookRecord; Stage, Archive, ArchiveHash, LoosePath, LooseHash, MemberKey, NeighbourKey: string;
    Zip: TZipFile; CID, BID: Integer;

  begin
    Stage:=IncludeTrailingPathDelimiter(Root+'linked-'+Kind);
    ForceDirectories(Stage);
    CID:=SystemDB.CreateCollection('Linked duplicate files '+Kind,Stage,Stage+'books.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    Collection:=SystemDB.GetCollection(CID); Info:=SystemDB.GetCollectionInfo(CID);
    Primary.Clear; Primary.Title:='Merged book'; Primary.LibID:='flibusta:9011';
    Primary.Folder:='linked.zip'; Primary.FileName:='keep'; Primary.FileExt:='.fb2';
    Primary.Size:=42; Primary.Lang:='ru'; Include(Primary.BookProps,bpIsLocal);
    TAuthorsHelper.Add(Primary.Authors,'Duplicate test','','');
    TGenresHelper.Add(Primary.Genres,'','','prose_contemporary');
    BID:=Collection.InsertBook(Primary,False,False);
    Collection.GetBookRecord(CreateBookKey(BID,CID),Primary,False);
    Collection.SetReview(Primary.BookKey,'Keep merged card and note');
    SystemDB.AddBookToGroup(Primary.BookKey,FAVORITES_GROUP_ID,Primary);
    Member:=Primary; Member.FileName:='extra';
    Loose:=Primary; Loose.Folder:=''; Loose.FileName:='standalone';
    Neighbour:=Primary; Neighbour.FileName:='neighbour';
    MemberKey:='test:member'; NeighbourKey:='test:neighbour';
    Collection.SetCatalogBookCopy('test:primary','Kept source',Primary);
    if Kind='ok' then
    begin
      // Same display name across two roots and two registered IDs on one root.
      Loose.CollectionRoot:=IncludeTrailingPathDelimiter(Stage+'another-root');
      ForceDirectories(Loose.CollectionRoot);
      MemberKey:=MemberKey+':file:'+StringOfChar('1',64);
      NeighbourKey:=NeighbourKey+':file:'+StringOfChar('2',64);
      Collection.SetCatalogBookCopy('test:loose','Archive copy',Loose);
      Collection.SetCatalogBookCopy(NeighbourKey,'Archive copy',Neighbour);
    end
    else
    begin
      Collection.SetCatalogBookCopy('test:loose','Loose copy',Loose);
      if Kind<>'priority' then Collection.SetCatalogBookCopy(NeighbourKey,'Unselected source',Neighbour);
    end;
    Collection.SetCatalogBookCopy(MemberKey,'Archive copy',Member);
    if Kind='priority' then
    begin
      var AliasBook:=Member;
      AliasBook.CollectionRoot:=Stage+'legacy\';
      AliasBook.Folder:=Member.GetBookFileName;
      Collection.SetCatalogBookCopy('test:member-alias','Legacy catalogue name',AliasBook);
    end;
    if Kind='shared' then Collection.SetCatalogBookCopy('test:alias','Shared source',Loose);
    Archive:=Primary.GetBookFileName; LoosePath:=Loose.GetBookFileName;
    Zip:=TZipFile.Create;
    try
      Zip.Open(Archive,zmWrite);
      for var Name in ['keep.fb2','extra.fb2','neighbour.fb2'] do
        if (Kind<>'missing-primary') or (Name<>'keep.fb2') then
        begin
          var Data:=TStringStream.Create('Original '+Name,TEncoding.UTF8);
          try Zip.Add(Data,Name); finally Data.Free; end;
        end;
    finally Zip.Free; end;
    TFile.WriteAllText(LoosePath,'Original separate copy',TEncoding.UTF8);
    ArchiveHash:=THashSHA2.GetHashStringFromFile(Archive);
    LooseHash:=THashSHA2.GetHashStringFromFile(LoosePath);
    var Selection:=Default(TDuplicateFileDeletion);
    if Kind='ok' then
    begin
      var Form:=TfrmBookDuplicates.CreateForCollection(frmMain,Collection);
      try
        TButton(Form.FindComponent('btnFindBookDuplicates')).Click;
        Require(Form.Plan.LinkedMode and (Form.Plan.GroupCount=1) and
          not TButton(Form.FindComponent('btnApplyBookDuplicates')).Enabled,
          'Linked-only family offered a redundant catalogue merge');
        var Copies:=TListView(Form.FindComponent('lvDuplicateCopies'));
        Require(not Copies.Checkboxes and (Copies.Items.Count=4) and (Copies.Items[0].Caption='Основная'),
          'Unified family hid a physical copy or its retained marker');
        Require(not TComboBox(Form.FindComponent('cbDuplicateResultKind')).Visible and
          not TButton(Form.FindComponent('btnDuplicateDetails')).Visible,
          'Unified family still requires technical result modes');
        var Mark:=TCheckBox(Form.FindComponent('cbSelectDuplicateGroup'));
        Mark.Checked:=True; Mark.OnClick(Mark);
        Require((Form.Plan.SelectedRemovedCount=3) and (Copies.Items[1].Caption='К удалению') and
          (Copies.Items[2].Caption='К удалению') and (Copies.Items[3].Caption='К удалению'),
          'One family action did not select all other physical copies');
        TButton(Form.FindComponent('btnClearDuplicateSelection')).Click;
        Require(Form.Plan.SelectedRemovedCount=0,'Unified clear left selected physical copies');
        // Independently retain the partial-selection recovery fixture. The
        // ordinary UI now offers one retained file and the whole family.
        Form.LinkedPlan.ChooseCopy(MemberKey,True);
        Form.LinkedPlan.ChooseCopy('test:loose',True);
        Form.RenderPage;
        var DeleteButton:=TButton(Form.FindComponent('btnDeleteDuplicateFiles'));
        DialogProbe.Accept:=False; DialogProbe.Count:=0; DialogProbe.DefaultNo:=False;
        Timer.Enabled:=True;
        try DeleteButton.Click; finally Timer.Enabled:=False; end;
        Require((DialogProbe.Count=1) and DialogProbe.DefaultNo and
          not Assigned(Form.TakeDeletionOperation(Settings.SystemFileName[sfSystemDB],Stage+'journal')),
          'Declining linked deletion accepted a binding');
        DialogProbe.Accept:=True; DialogProbe.Count:=0;
        Timer.Enabled:=True;
        try DeleteButton.Click; finally Timer.Enabled:=False; end;
        Operation:=Form.TakeDeletionOperation(Settings.SystemFileName[sfSystemDB],Stage+'journal');
        Require((DialogProbe.Count=1) and Assigned(Operation),'Normal duplicate dialog did not prepare the linked file selection');
        Writeln('PASS unified duplicate dialog shows all physical copies and selects the family with one confirmation');
      finally Form.Free; end;
    end
    else if Kind='priority' then
    begin
      var Plan:=TBookDuplicatePlan.Create(Info.DBFileName,Info.GetRootPath,'flibusta',
        Settings.SystemFileName[sfSystemDB],Stage+'reader',CID);
      var NoRegularPlan:TBookDuplicatePlan:=nil;
      try
        Plan.PreviewLinked;
        Require(Plan.SelectSourcePriority(['Loose copy','Kept source','Archive copy'],nil,True)=2,
          'Could not stage both files from lower-priority sources');
        var Copies:=Plan.Books(BID);
        Require((Copies[0].CopyKey='') and (Copies[0].Book.GetBookFileName=LoosePath),
          'The preview did not designate the preferred file');
        Require(THashSHA2.GetHashStringFromFile(Archive)=ArchiveHash,'Preview changed archive bytes');
        Operation:=TBookDeletionOperation.CreateDuplicateCleanup(NoRegularPlan,Plan,CID,
          Settings.SystemFileName[sfSystemDB],Stage+'journal');
      finally Plan.Free; end;
    end
    else
    begin
      Selection.Removed:=TBookDeletionBinding.CaptureCopies(Info,[Member,Loose],[Primary,Primary],['test:member','test:loose']);
      Operation:=TBookDeletionOperation.CreateDuplicateRemoval(Selection,Settings.SystemFileName[sfSystemDB],Stage+'journal');
    end;
    try
      Operation.ReviewArchives:=Kind='cancel';
      if Kind='resume' then
        RunLinkedCopyTestSQL(Info.DBFileName,'CREATE TRIGGER OwnedLinkedCopyFailure BEFORE DELETE ON CatalogBookCopies '+
          'WHEN OLD.SourceKey=''test:loose'' BEGIN SELECT RAISE(ABORT,''owned linked copy failure''); END');
      var State:=RunLinkedCopyTestOperation(Operation,Kind);
      var Completed:=State.CompletedCopies;
      if Kind='priority' then
      begin
        Require((State.Error='') and (Completed=2) and (State.PendingJournal='') and (State.CompletedBooks=0),
          'Preferred linked cleanup did not finish: '+State.Error);
        Collection.GetBookRecord(CreateBookKey(BID,CID),Primary,False);
        Require((Primary.GetBookFileName=LoosePath) and
          (Length(Collection.GetCatalogBookCopies(Primary.BookKey))=1) and
          (Collection.GetReview(Primary.BookKey)='Keep merged card and note') and
          (THashSHA2.GetHashStringFromFile(LoosePath)=LooseHash),
          'Preferred file, single card, or personal note was lost');
        Zip:=TZipFile.Create;
        try
          Zip.Open(Archive,zmRead);
          Require((Zip.FileCount=1) and (Zip.FileNames[0]='neighbour.fb2'),
            'Lower-priority cleanup removed the wrong ZIP members');
          var Payload:TBytes; Zip.Read('neighbour.fb2',Payload);
          Require(TEncoding.UTF8.GetString(Payload)='Original neighbour.fb2','Neighbour changed');
        finally Zip.Free; end;
        Writeln('PASS priority replaces the main file of a linked card and removes both lower-ranked copies');
        Exit;
      end;
      if Kind='resume' then
      begin
        Require(State.Error.Contains('owned linked copy failure') and (State.CompletedCopies=1) and
          (State.PendingJournal<>'') and (THashSHA2.GetHashStringFromFile(LoosePath)=LooseHash),
          'Linked failure did not retain the uncommitted file and its recovery receipt: '+State.Error);
        RunLinkedCopyTestSQL(Info.DBFileName,'DROP TRIGGER OwnedLinkedCopyFailure');
        FreeAndNil(Operation);
        Operation:=TBookDeletionOperation.Recover(Settings.SystemFileName[sfSystemDB],Stage+'journal');
        State:=RunLinkedCopyTestOperation(Operation,Kind);
        Require(State.CompletedCopies=1,'Recovery repeated the completed archive or missed the pending copy: '+State.Error);
        Inc(Completed,State.CompletedCopies);
        Writeln('PASS linked duplicate recovery resumes the exact pending file after a catalogue write failure');
      end;
      if (Kind='ok') or (Kind='resume') then
      begin
        Require((State.Error='') and (State.PendingJournal='') and (Completed=2) and
          (State.CompletedBooks=0) and (Length(Collection.GetCatalogBookCopies(Primary.BookKey))=2) and
          not FileExists(LoosePath),'Linked copy deletion did not complete both exact files: '+State.Error);
        Zip:=TZipFile.Create;
        try
          Zip.Open(Archive,zmRead);
          Require((Zip.FileCount=2) and (Zip.FileNames[0]='keep.fb2') and (Zip.FileNames[1]='neighbour.fb2'),
            'Linked deletion changed the archive beyond the selected member');
          for var Name in Zip.FileNames do
          begin
            var Data:TBytes; Zip.Read(Name,Data);
            Require(TEncoding.UTF8.GetString(Data)='Original '+Name,'Linked deletion changed retained bytes');
          end;
        finally Zip.Free; end;
      end
      else
      begin
        if Kind='shared' then Require(State.Error.Contains('Файл ещё нужен другой записи'),'Unselected alias was not protected: '+State.Error);
        if Kind='missing-primary' then Require(State.Error.Contains('точный путь книги'),'Missing primary was not protected: '+State.Error);
        if Kind='cancel' then Require(State.Stopping and (State.Error=''),'Cancellation did not stop linked deletion');
        Require((State.CompletedCopies=0) and not State.CatalogueChanged and (State.PendingJournal='') and
          (THashSHA2.GetHashStringFromFile(Archive)=ArchiveHash) and (THashSHA2.GetHashStringFromFile(LoosePath)=LooseHash),
          'Rejected linked copy deletion changed a file, count or catalogue: '+Kind);
      end;
      Collection.GetBookRecord(CreateBookKey(BID,CID),Primary,False);
      Require((Primary.BookKey.BookID=BID) and (Primary.FileName='keep') and
        (Collection.GetReview(Primary.BookKey)='Keep merged card and note'),'Linked deletion changed the merged card');
    finally Operation.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath+'duplicate-file-removal\'; ForceDirectories(Root);
  DialogProbe:=TDuplicateFilePromptProbe.Create;
  Timer:=TTimer.Create(nil); Timer.Enabled:=False; Timer.Interval:=10; Timer.OnTimer:=DialogProbe.Tick;
  SavedDialogs:=Vcl.Dialogs.UseLatestCommonDialogs;
  Vcl.Dialogs.UseLatestCommonDialogs:=False;
  try
    CaseCheck('archive','');
    CaseCheck('batched','');
    CaseCheck('priority-three','');
    CaseCheck('mixed-promotion','');
    CaseCheck('mixed-promotion-conflict','выбраны разные сохраняемые копии');
    CaseCheck('mixed-priority-lower','');
    CaseCheck('combined','');
    CaseCheck('large-archive','');
    CaseCheck('large-linked','');
    CaseCheck('loose','');
    CaseCheck('missing','сохраняемой копии недоступен');
    CaseCheck('alias','указывают на один файл');
    CaseCheck('shared','Файл нужен другой записи');
    CaseCheck('personal','');
    CaseCheck('alternate','');
    CaseCheck('stale','');
    Writeln('PASS duplicate file removal explicit confirmation retains exact books and rejects missing, shared, protected and stale sources');
    for var Kind in ['ok','priority','shared','missing-primary','cancel','resume'] do CheckLinkedCopies(Kind);
    Writeln('PASS linked duplicate deletion removes loose and archived files, protects the main card and unselected sources, and cancels before writing');
  finally Vcl.Dialogs.UseLatestCommonDialogs:=SavedDialogs; Timer.Free; DialogProbe.Free; end;
end;

procedure TestLargeOrdinaryDuplicateBatches;
const DuplicateCount = 100003;
var C: IBookCollection; DB: TSQLiteDatabase; Plan: TBookDuplicatePlan;
  Info: TCollectionInfo; Cursor: TDuplicateDeletionCursor; Batch: TDuplicateFileDeletion;
  CID, Total, BatchCount, ProgressCount: Integer; Root, ReaderFile, PreviousArchive, Before: string;
  Cancel, Failed: Boolean; Watch: TStopwatch;
begin
  Root:=TPath.Combine(Settings.AppPath,'ordinary-large-delete');
  ForceDirectories(Root);
  CID:=SystemDB.CreateCollection('Large ordinary duplicate removal',Root,TPath.Combine(Root,'books.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  C:=SystemDB.GetCollection(CID);
  Info:=SystemDB.GetCollectionInfo(CID);
  DB:=TSQLiteDatabase.Create(Info.DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.ExecSQL('WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?) '+
      'INSERT INTO Books(LibID,Title,Folder,UpdateDate,FileName,InsideNo,Lang,Ext,BookSize) '+
      'SELECT ''flibusta:''||((x+1)/2),''Candidate ''||((x+1)/2),'+
      'CASE WHEN x%2=0 THEN ''batch-''||((x/2-1)/4500)||''.7z'' ELSE ''preferred.7z'' END,'+
      '''2026-10-21'',''file''||x,0,''ru'',''.fb2'',100 FROM n',[2*DuplicateCount]);
    DB.ExecSQL('INSERT INTO CatalogPreferredSource(BookID,SourceName) '+
      'SELECT BookID,CASE WHEN BookID%2=0 THEN ''Remove'' ELSE ''Keep'' END FROM Books');
  finally DB.Free; end;
  ReaderFile:=TPath.Combine(Root,'reader.ini');
  Before:=THashSHA2.GetHashStringFromFile(Info.DBFileName);
  Plan:=TBookDuplicatePlan.Create(Info.DBFileName,Root,'flibusta',Settings.SystemFileName[sfSystemDB],
    ReaderFile,CID,Settings.WorkPath);
  try
    Plan.Preview;
    Require(Plan.SelectSourcePriority(['Keep','Remove'])=DuplicateCount,'Fixture lost marked duplicate pairs');
    Failed:=False; Cancel:=False;
    try
      Plan.PrepareDeletionBatches(Info,function: Boolean begin Result:=Cancel; end,
        procedure(Current,Total: Integer) begin Cancel:=Current>=256; end);
    except on E: Exception do if Cancel then Failed:=True else raise; end;
    Require(Failed and not Assigned(SQLiteCancelCallback),'Canceled large deletion staging did not roll back');
    ProgressCount:=0;
    Watch:=TStopwatch.StartNew;
    Plan.PrepareDeletionBatches(Info,nil,procedure(Current,Total: Integer) begin ProgressCount:=Current; end);
    Total:=0; BatchCount:=0; PreviousArchive:=''; Cursor:=Default(TDuplicateDeletionCursor);
    repeat
      Batch:=Plan.NextDeletionBatch(Info,Cursor,nil);
      if Batch.Removed.CollectionID=0 then Break;
      var Removed:=Batch.Removed.ExpectedBooks;
      var Retained:=Batch.Retained.ExpectedBooks;
      Require((Length(Removed)>0) and (Length(Removed)<=DUPLICATE_FILE_BATCH_SIZE) and
        (Length(Removed)=Length(Retained)), 'Large removal returned an invalid batch');
      Require(Removed[0].Folder<>PreviousArchive,'An archive that fits in one batch was split');
      for var I:=0 to High(Removed) do
        Require((Removed[I].BookKey.BookID mod 2=0) and (Removed[I].BookKey.BookID=Retained[I].BookKey.BookID+1),
          'Large removal staged the wrong pair');
      PreviousArchive:=Removed[High(Removed)].Folder;
      Inc(Total,Length(Removed)); Inc(BatchCount);
    until False;
    Require((Total=DuplicateCount) and (ProgressCount=DuplicateCount) and (BatchCount>1) and
      (THashSHA2.GetHashStringFromFile(Info.DBFileName)=Before),
      'Large duplicate staging lost rows or changed the source catalogue');
    Writeln('PROFILE ordinary duplicate staging rows=',Total,' batches=',BatchCount,' ms=',Watch.ElapsedMilliseconds);
    Writeln('PASS over 100000 duplicate removals are staged in bounded archive batches without mutating the source');
  finally Plan.Free; end;
end;

procedure TestLinkedDuplicateMassRemoval;
const CopyCount = LINKED_DUPLICATE_BATCH_SIZE + 2;
  FullCount = 2500;
  Neighbours = 100;
var Root, KeptArchive, FullArchive, SharedArchive, KeptHash: string;
  Collection: IBookCollection; Info: TCollectionInfo; DB: TSQLiteDatabase;
  Plan, NoRegularPlan: TBookDuplicatePlan;
  Operation: TBookDeletionOperation; State: TBookDeletionOperationStatus;
  Zip: TZipFile; CID: Integer; Started: UInt64; Primary: TBookRecord;
  InitialBytes, FreedBytes: Int64;

  procedure AddMember(Archive: TZipFile; const Name: string);
  var Data: TStringStream;
  begin
    Data:=TStringStream.Create('Original bytes of '+Name,TEncoding.UTF8);
    try Archive.Add(Data,Name); finally Data.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'linked-mass');
  ForceDirectories(Root);
  CID:=SystemDB.CreateCollection('Linked mass deletion',Root,Root+'mass.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Collection:=SystemDB.GetCollection(CID); Info:=SystemDB.GetCollectionInfo(CID);
  DB:=TSQLiteDatabase.Create(Info.DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.ExecSQL('WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?) '+
      'INSERT INTO Books(BookID,LibID,Title,UpdateDate,Folder,FileName,InsideNo,Lang,Ext,BookSize,IsLocal) '+
      'SELECT x,''flibusta:''||x,''Mass book ''||x,''2026-11-09'',''main.zip'',''keep''||x,0,''ru'',''.fb2'',100,1 FROM n',[CopyCount]);
    DB.ExecSQL('INSERT INTO CatalogBookCopies(SourceKey,BookID,SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID) '+
      'SELECT ''mass:''||BookID,BookID,''Mass source'',?,CASE WHEN BookID<=? THEN ''full.zip'' '+
      'WHEN BookID<? THEN ''shared.zip'' ELSE '''' END,''extra''||BookID,Ext,0,BookSize,LibID FROM Books',
      [Root,FullCount,CopyCount]);
    DB.ExecSQL('INSERT INTO CatalogSourceBooks SELECT SourceKey,BookID FROM CatalogBookCopies');
    DB.ExecSQL('INSERT INTO CatalogBookCopies(SourceKey,BookID,SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID) '+
      'SELECT ''other:''||BookID,BookID,''Another source'',?,''shared.zip'',''neighbour''||BookID,Ext,0,BookSize,LibID '+
      'FROM Books WHERE BookID<=?',[Root,Neighbours]);
  finally DB.Free; end;
  Collection.GetBookRecord(CreateBookKey(1,CID),Primary,False);
  Collection.SetReview(Primary.BookKey,'Keep the review after bulk deletion');
  SystemDB.AddBookToGroup(Primary.BookKey,FAVORITES_GROUP_ID,Primary);
  KeptArchive:=Root+'main.zip'; FullArchive:=Root+'full.zip'; SharedArchive:=Root+'shared.zip';
  Zip:=TZipFile.Create;
  try
    Zip.Open(KeptArchive,zmWrite);
    for var I:=1 to CopyCount do AddMember(Zip,'keep'+IntToStr(I)+'.fb2');
    Zip.Close; Zip.Open(FullArchive,zmWrite);
    for var I:=1 to FullCount do AddMember(Zip,'extra'+IntToStr(I)+'.fb2');
    Zip.Close; Zip.Open(SharedArchive,zmWrite);
    for var I:=FullCount+1 to CopyCount-1 do
    begin
      AddMember(Zip,'extra'+IntToStr(I)+'.fb2');
      if I<=FullCount+Neighbours then AddMember(Zip,'neighbour'+IntToStr(I-FullCount)+'.fb2');
    end;
  finally Zip.Free; end;
  TFile.WriteAllText(Root+'extra'+IntToStr(CopyCount)+'.fb2','Original loose book',TEncoding.UTF8);
  InitialBytes:=TFile.GetSize(FullArchive)+TFile.GetSize(SharedArchive)+
    TFile.GetSize(Root+'extra'+IntToStr(CopyCount)+'.fb2');
  KeptHash:=THashSHA2.GetHashStringFromFile(KeptArchive);
  Plan:=TBookDuplicatePlan.Create(Info.DBFileName,Root,'flibusta',Settings.SystemFileName[sfSystemDB],
    Root+'reader.ini',CID,Settings.WorkPath);
  try
    Plan.PreviewLinked;
    Require(Plan.SelectSource('Mass source')=CopyCount,'Could not mark the complete mass source');
    NoRegularPlan:=nil;
    Operation:=TBookDeletionOperation.CreateDuplicateCleanup(NoRegularPlan,Plan,CID,Settings.SystemFileName[sfSystemDB],Root+'journal');
  finally Plan.Free; end;
  try
    Started:=GetTickCount64;
    Operation.Start;
    while not Operation.Status.Finished do
    begin
      State:=Operation.Status;
      Require(GetTickCount64-Started<150000,'Mass linked deletion exceeded its deadline: '+State.Stage);
      Sleep(20);
    end;
    Operation.WaitFor; State:=Operation.Status;
    Require((State.Error='') and (State.CleanupWarning='') and (State.PendingJournal='') and
      (State.CompletedBooks=0) and (State.CompletedCopies=CopyCount) and (State.DuplicateBatch=2),'Mass linked deletion failed: '+State.Error);
    FreedBytes:=0;
    for var Volume in State.SpaceByVolume do
    begin
      Inc(FreedBytes,Volume.ReleasedBytes);
      Require(Volume.UnmeasuredFiles=0,'Mass deletion did not measure a completed source');
    end;
    Require((Length(State.SpaceByVolume)=1) and
      (FreedBytes=InitialBytes-TFile.GetSize(SharedArchive)),
      'Mass deletion savings differ from the actual three source files');
    var IndependentSnapshot:=Operation.Status;
    Inc(IndependentSnapshot.SpaceByVolume[0].ReleasedBytes);
    Require(Operation.Status.SpaceByVolume[0].ReleasedBytes=State.SpaceByVolume[0].ReleasedBytes,
      'A returned progress snapshot can change the worker totals');
    Writeln('PASS cumulative deletion space matches actual ZIP and loose files across batches with independent snapshots');
    Writeln('PROFILE linked file deletion copies=',State.CompletedCopies,' ms=',GetTickCount64-Started);
  finally Operation.Free; end;
  Require(not FileExists(FullArchive) and not FileExists(Root+'extra'+IntToStr(CopyCount)+'.fb2') and
    (THashSHA2.GetHashStringFromFile(KeptArchive)=KeptHash),'Mass deletion left a whole source or changed the primary archive');
  Zip:=TZipFile.Create;
  try
    Zip.Open(SharedArchive,zmRead);
    Require(Zip.FileCount=Neighbours,'Mass deletion left extra entries or removed retained members');
    for var I:=0 to Neighbours-1 do
    begin
      var Name:='neighbour'+IntToStr(I+1)+'.fb2';
      var Data:TBytes; Zip.Read(I,Data);
      Require((Zip.FileNames[I]=Name) and (TEncoding.UTF8.GetString(Data)='Original bytes of '+Name),
        'Mass deletion changed an unselected ZIP member');
    end;
  finally Zip.Free; end;
  DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
  try
    Require((DB.QuerySingleInt('SELECT count(*) FROM Books')=CopyCount) and
      (DB.QuerySingleInt('SELECT count(*) FROM CatalogBookCopies WHERE SourceName=''Another source''')=Neighbours) and
      (DB.QuerySingleInt('SELECT count(*) FROM CatalogBookCopies')=Neighbours) and
      (DB.QuerySingleInt('SELECT count(*) FROM CatalogSourceBooks')=CopyCount) and
      (Collection.GetReview(Primary.BookKey)='Keep the review after bulk deletion'),
      'Mass deletion lost a main card, its review, or the other source');
  finally DB.Free; end;
  Writeln('PASS mass linked deletion removes 5002 copies across two ZIPs and a loose file while retaining primary cards and unselected bytes');
  TestLargeOrdinaryDuplicateBatches;
end;

// Optional audit of an explicitly supplied catalog. No collection DAO and no
// Apply call are used: catalog, registration and reader files are read-only.
procedure TestBookDuplicateReadOnlyCatalog(const CatalogFile: string; Linked: Boolean = False);
var Registration, Catalog: TSQLiteDatabase; Plan: TBookDuplicatePlan;
  SystemFile, WorkRoot, Root, Namespace, ReaderFile: string; CID: Integer;
  Watch: TStopwatch; Baseline, Peak: Int64;
begin
  SystemFile:=TPath.Combine(ExtractFilePath(CatalogFile),'user.dbs2');
  WorkRoot:=ExtractFileDir(ExcludeTrailingPathDelimiter(ExtractFilePath(CatalogFile)));
  ReaderFile:=TPath.Combine(ExtractFilePath(CatalogFile),'reader.ini');
  CID:=StrToInt(GetEnvironmentVariable('HLRU_DUPLICATE_READONLY_CID'));
  Registration:=TSQLiteDatabase.CreateReadOnly(SystemFile);
  try
    Require(Registration.QuerySingleInt('PRAGMA query_only')=1,'Read-only audit registration is writable');
    Root:=Registration.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[CID]);
    if not TPath.IsPathRooted(Root) then Root:=TPath.Combine(WorkRoot,Root);
  finally Registration.Free; end;
  Catalog:=TSQLiteDatabase.CreateReadOnly(CatalogFile);
  try
    Require(Catalog.QuerySingleInt('PRAGMA query_only')=1,'Read-only audit catalog is writable');
    Namespace:=Catalog.QuerySingleString('SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_SOURCE_LIBRARY]);
  finally Catalog.Free; end;
  Plan:=TBookDuplicatePlan.Create(CatalogFile,Root,Namespace,SystemFile,ReaderFile,CID,WorkRoot);
  try
    Baseline:=DuplicatePrivateBytes; Peak:=Baseline; Watch:=TStopwatch.StartNew;
    if Linked then
      Plan.PreviewLinked(nil,procedure(Current,Total: Integer) begin Peak:=Max(Peak,DuplicatePrivateBytes); end)
    else Plan.Preview(nil,procedure(Current,Total: Integer) begin Peak:=Max(Peak,DuplicatePrivateBytes); end);
    Watch.Stop; Peak:=Max(Peak,DuplicatePrivateBytes);
    Require(Plan.Ready and (Plan.SelectedCount=0) and not Plan.Committed,'Read-only preview changed catalog state');
    if Plan.GroupCount>0 then
    begin
      Require(Length(Plan.Groups(0,50))>0,'Large catalog first page is empty');
      Require(Length(Plan.Groups(((Plan.GroupCount-1) div 50)*50,50))>0,'Large catalog last page is empty');
    end;
    if Linked then
    begin
      var Chosen:=''; var Count:=0;
      for var Name in Plan.Sources do
        if Name.StartsWith('fb2_local · ') then
        begin
          Inc(Count);
          if Chosen='' then Chosen:=Name;
        end;
      Require(Count>=2,'Actual catalogue did not separate the repeated fb2_local source names');
      var Selected:=Plan.SelectSource(Chosen);
      Require(Selected>=LINKED_DUPLICATE_BATCH_SIZE,'Actual catalogue could not stage a full linked batch');
      var Info:=Default(TCollectionInfo);
      Info.ID:=CID; Info.DBFileName:=CatalogFile; Info.RootFolder:=Root; Info.CollectionType:=CT_EXTERNAL_LOCAL_FB;
      var Staged:=0;
      Plan.PrepareLinkedBatches(Info,nil,procedure(Current,Total: Integer) begin Staged:=Current; end);
      var Copies:=Plan.LinkedDeletionBatch(1).ExpectedBooks;
      Require((Staged=Selected) and (Length(Copies)>0) and (Length(Copies)<=LINKED_DUPLICATE_BATCH_SIZE),
        'Actual linked batches did not bind the entire selection in bounded batches');
      var ChosenRoot:=ExcludeTrailingPathDelimiter(Copies[0].CollectionRoot);
      Require(Chosen.Contains(ChosenRoot),'The batch does not belong to the displayed source root');
      for var Book in Copies do
        Require(SameFileName(ExcludeTrailingPathDelimiter(Book.CollectionRoot),ChosenRoot),
          'An identically named source from a different path entered the selected batch');
      Writeln('PROFILE readonly linked duplicate scan rows=',Plan.Scanned,' groups=',Plan.GroupCount,
        ' ms=',Watch.ElapsedMilliseconds,' sampled_private_growth_bytes=',Peak-Baseline,' matching_sources=',Count);
      Writeln('PASS actual read-only catalogue distinguishes fb2_local sources and stages the entire selection from one root');
      Exit;
    end;
    Writeln('PROFILE readonly duplicate scan rows=',Plan.Scanned,' groups=',Plan.GroupCount,
      ' ms=',Watch.ElapsedMilliseconds,' sampled_private_growth_bytes=',Peak-Baseline);
    Writeln('PASS read-only catalog duplicate preview; no selected groups and no Apply');
  finally Plan.Free; end;
end;

procedure TestUnifiedDuplicateFamilies;
var C:IBookCollection; Info:TCollectionInfo; DB:TSQLiteDatabase;
  Regular,Linked:TBookDuplicatePlan; View:TUnifiedDuplicateView;
  A,B,D,CID,GID:Integer; Book:TBookRecord;
  Form:TfrmBookDuplicates; GroupsList,CopiesList:TListView; Image:TBitmap; PNG:TPngImage;
begin
  RequireIsolatedRegression;
  CID:=SystemDB.CreateCollection('Unified copies',Settings.AppPath,'unified-copies.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  C:=SystemDB.GetCollection(CID); Info:=SystemDB.GetCollectionInfo(CID);
  A:=AddBook(C,'Book 42','Author','ru','','');
  B:=AddBook(C,'Book 42 other','Author','ru','','');
  D:=AddBook(C,'Book 77','Author','ru','','');
  DB:=TSQLiteDatabase.Create(Info.DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    for var ID in TArray<Integer>.Create(A,B,D) do
    begin
      DB.ExecSQL('UPDATE Books SET LibID=?,FileName=?,Folder='''' WHERE BookID=?',
        ['flibusta:'+IntToStr(42+Ord(ID=D)*35),'main'+IntToStr(ID),ID]);
      DB.ExecSQL('INSERT INTO CatalogPreferredSource VALUES(?,?)',[ID,'Source '+IntToStr(ID)]);
    end;
  finally DB.Free; end;
  C.GetBookRecord(CreateBookKey(B,CID),Book,False);
  C.SetCatalogBookCopy('original42','Source '+IntToStr(B),Book); Book.FileName:='alternative42';
  C.SetCatalogBookCopy('alternative42','Preferred source',Book);
  C.GetBookRecord(CreateBookKey(D,CID),Book,False);
  C.SetCatalogBookCopy('original77','Source '+IntToStr(D),Book); Book.FileName:='alternative77';
  C.SetCatalogBookCopy('alternative77','Another source',Book);
  Regular:=TBookDuplicatePlan.Create(Info.DBFileName,Info.GetRootPath,'flibusta',
    Settings.SystemFileName[sfSystemDB],Settings.AppPath+'unified-reader.ini',CID,Settings.WorkPath);
  Linked:=TBookDuplicatePlan.Create(Info.DBFileName,Info.GetRootPath,'flibusta',
    Settings.SystemFileName[sfSystemDB],Settings.AppPath+'unified-reader.ini',CID,Settings.WorkPath);
  View:=TUnifiedDuplicateView.Create(Regular,Linked);
  try
    Regular.Preview; Linked.PreviewLinked; Regular.AlignPrioritySources(Linked); View.Build;
    Require((View.GroupCount=2) and (View.SelectedCount=0),'Unified list double-counted a family or preselected deletion');
    var Page:=View.Groups(0,50); GID:=Page[0].ID;
    Require((Length(Page)=2) and (Page[0].Count=3) and (Page[1].Count=2) and
      (Length(View.Groups(2,50))=0),'Unified paging hid a card or a retained file');
    var Copies:=View.Books(GID); var Preferred:=-1;
    for var I:=0 to High(Copies) do if Copies[I].Value.CopyKey='alternative42' then Preferred:=I;
    Require(Preferred>=0,'Unified list hid a previously merged physical file');
    View.Choose(GID,Preferred,True); Copies:=View.Books(GID);
    var Kept:=0; var Selected:=0;
    for var Entry in Copies do
    begin
      if Entry.Kept then begin Inc(Kept); Require(Entry.Value.Book.FileName='alternative42','Wrong manual physical copy retained'); end;
      if Entry.Selected then Inc(Selected);
    end;
    Require((Kept=1) and (Selected=2) and (View.SelectedCount=1) and (View.GroupCount(True)=1),
      'Unified manual choice did not mark the other two physical copies exactly');
    View.Choose(GID,-1,False);
    Require((View.SelectedCount=0) and (View.GroupCount(True)=2),'Unified unmark did not include linked copies');
    View.Choose(Page[1].ID,1,True);
    Require((View.SelectedCount=1) and (View.Groups(0,50)[1].SelectedCopies=1),
      'Linked-only family cannot keep the alternative and select the former primary');
    View.Choose(Page[1].ID,1,True);
    Copies:=View.Books(Page[1].ID);
    Require(Copies[0].Kept and (Copies[0].Value.Book.FileName='main'+IntToStr(D)),
      'Choosing the former primary did not reverse its planned promotion');
    Regular.ClearSelection; Linked.ClearSelection; View.RefreshMarks;
    Require(View.SelectedCount=0,'Clear selection left hidden file marks');
    Writeln('PASS one duplicate family combines cards and physical copies, manual preference and reversible marking');
  finally View.Free; Linked.Free; Regular.Free; end;
  Form:=TfrmBookDuplicates.CreateForCollection(frmMain,C);
  try
    Form.Show;
    TButton(Form.FindComponent('btnFindBookDuplicates')).Click;
    GroupsList:=TListView(Form.FindComponent('lvDuplicateGroups'));
    CopiesList:=TListView(Form.FindComponent('lvDuplicateCopies'));
    Require((GroupsList.Items.Count=2) and (CopiesList.Items.Count=3) and
      not TComboBox(Form.FindComponent('cbDuplicateResultKind')).Visible and
      not TButton(Form.FindComponent('btnDuplicateDetails')).Visible,
      'The normal window still splits physical copies into technical modes');
    var KeepIndex:=-1;
    for var I:=0 to CopiesList.Items.Count-1 do
      if CopiesList.Items[I].SubItems[0].Contains('Preferred source') then KeepIndex:=I;
    Require(KeepIndex>=0,'Previously merged copy is absent from the normal family');
    CopiesList.Items[KeepIndex].Selected:=True;
    TButton(Form.FindComponent('btnPreferDuplicateCopy')).Click;
    var Mark:=TCheckBox(Form.FindComponent('cbSelectDuplicateGroup'));
    Mark.Checked:=True; Mark.OnClick(Mark);
    var KeepCount:=0; var MarkCount:=0;
    for var Item in CopiesList.Items do
    begin
      if Item.Caption='Основная' then
      begin Inc(KeepCount); Require(Item.SubItems[0].Contains('Preferred source'),'The UI retained another physical source'); end;
      if Item.Caption='К удалению' then Inc(MarkCount);
    end;
    for var I:=0 to CopiesList.Items.Count-1 do
      for var J:=I+1 to CopiesList.Items.Count-1 do
        Require(CopiesList.Items[I].SubItems[4]<>CopiesList.Items[J].SubItems[4],
          'Choosing a retained file changed the displayed path of another copy');
    Require((KeepCount=1) and (MarkCount=2) and
      TButton(Form.FindComponent('btnApplyBookDuplicates')).Enabled and
      TButton(Form.FindComponent('btnDeleteDuplicateFiles')).Enabled,
      'Unified UI choice did not preserve both catalogue-only and physical actions');
    if GetEnvironmentVariable('HOMELIB_UNIFIED_PREVIEW')<>'' then
    begin
      Image:=TBitmap.Create; PNG:=TPngImage.Create;
      try
        Image.SetSize(Form.Width,Form.Height); Form.PaintTo(Image.Canvas,0,0); PNG.Assign(Image);
        PNG.SaveToFile(GetEnvironmentVariable('HOMELIB_UNIFIED_PREVIEW'));
      finally PNG.Free; Image.Free; end;
    end;
    TButton(Form.FindComponent('btnClearDuplicateSelection')).Click;
    Require((Form.Plan.SelectedCount=0) and (Form.LinkedPlan.SelectedCount=0),
      'Unified clear left hidden marked files in another kind of result');
    Writeln('PASS unified window retains one chosen source and exposes both physical and catalogue-only cleanup');
  finally Form.Free; end;
end;
