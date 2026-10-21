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
      CopiesList.Items[1].Selected:=True;
      Prefer:=Dialog.FindComponent('btnPreferDuplicateCopy') as TButton;
      Prefer.OnClick(Prefer);
      Require(CopiesList.Items[1].Caption.Contains('★') and not CopiesList.Items[0].Caption.Contains('★'),
        'Preferred duplicate has no persistent visible marker');
      CopiesList.Items[0].Selected:=True;
      Require((Dialog.FindComponent('mmDuplicateCopyDetails') as TMemo).Lines[0]='Основная запись: '+IntToStr(B),
        'Selecting another copy concealed the preferred book identity');
      SelectGroup:=Dialog.FindComponent('cbSelectDuplicateGroup') as TCheckBox;
      SelectGroup.Checked:=True;
      Require(Dialog.Plan.SelectedCount=1,'Duplicate window lost preferred copy or explicit selection');
      for var PPI in [96,144,192,96] do
      begin
        Dialog.ScaleForPPI(PPI); Application.ProcessMessages;
        Require((GroupsList.Width>100) and (CopiesList.Height>50) and
          (SelectGroup.Top+SelectGroup.Height<=SelectGroup.Parent.ClientHeight),
          'Duplicate layout clips copy controls at '+IntToStr(PPI));
      end;
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
    Require(Plan.Committed and (Plan.Removed=1) and not Plan.Ready,'Consolidation did not publish durable completion');
    Require((Value('SELECT count(*) FROM Books')='2') and
      (Value('SELECT count(*) FROM Books WHERE BookID='+IntToStr(B))='1') and
      (Value('SELECT count(*) FROM Books WHERE BookID='+IntToStr(Other))='1'),
      'Consolidation removed a preferred or unrelated record');
    Require(Value('SELECT count(*) FROM CatalogSourceBooks WHERE BookID='+IntToStr(B))='2',
      'Consolidation lost future INPX source mappings');
    Require(Value('SELECT count(*) FROM CatalogBookCopies WHERE BookID='+IntToStr(B))='2',
      'Consolidation lost a physical copy location');
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
