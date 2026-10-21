procedure TestCollectionBackupRestore;
var ID, OtherID, B, OtherBook, NewID, GroupID, Calls: Integer;
  C, Other, Restored: IBookCollection; Book: TBookRecord; Plan: TCollectionBackupPlan;
  Folder, FileName, Dest, SysFile, Stamp, Extra, MovedRoot, RacePath: string; DB: TSQLiteDatabase; Failed: Boolean;
  Dialog: TfrmCollectionBackup; Button: TButton; NameEdit, RootEdit: TEdit; Report: TMemo;
  function ReadValue(const SQL: string): string;
  var Store: TSQLiteDatabase;
  begin
    Store:=TSQLiteDatabase.CreateReadOnly(SysFile);
    try Result:=Store.QuerySingleString(SQL); finally Store.Free; end;
  end;
  function PersistentStamp: string;
  begin
    Result:=ReadValue('SELECT group_concat(DatabaseID||BaseName||DBFileName) FROM (SELECT * FROM Bases ORDER BY DatabaseID)')+
      ReadValue('SELECT group_concat(GroupID||GroupName||hex(Notes)) FROM (SELECT * FROM Groups ORDER BY GroupID)')+
      ReadValue('SELECT count(*)||'':''||sum(BookID) FROM Books')+
      ReadValue('SELECT count(*)||'':''||sum(BookID)||'':''||sum(DatabaseID)||'':''||sum(GroupID) FROM BookGroups');
  end;
begin
  ID:=SystemDB.CreateCollection('Snapshot original',Settings.AppPath,'snapshot-original.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  OtherID:=SystemDB.CreateCollection('Snapshot unrelated',Settings.AppPath,'snapshot-unrelated.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  C:=SystemDB.GetCollection(ID); Other:=SystemDB.GetCollection(OtherID);
  B:=AddBook(C,'Before merge','Автор','ru','Серия','');
  OtherBook:=AddBook(Other,'Unrelated','Other','en','','');
  FileName:=Settings.ExpandCollectionFileName(VarToStr(C.GetProperty(PROP_DATAFILE)));
  SysFile:=Settings.SystemFileName[sfSystemDB];
  C.GetBookRecord(CreateBookKey(B,ID),Book,True);
  SystemDB.AddGroup('Snapshot group');
  DB:=TSQLiteDatabase.Create(SysFile);
  try GroupID:=DB.QuerySingleInt('SELECT GroupID FROM Groups WHERE GroupName=?',['Snapshot group']);
  finally DB.Free; end;
  SystemDB.AddBookToGroup(Book.BookKey,GroupID,Book);
  SystemDB.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID,Book);
  C.SetRate(Book.BookKey,4); C.SetProgress(Book.BookKey,37);
  DB:=TSQLiteDatabase.Create(SysFile);
  try
    DB.ExecSQL('UPDATE Books SET Review=X''00FF80810042'', Annotation=X''41000042'' WHERE DatabaseID=?',[ID]);
    DB.ExecSQL('UPDATE Groups SET Notes=X''0100FF80'' WHERE GroupID=?',[GroupID]);
    DB.ExecSQL('UPDATE Groups SET Notes=X''0B00A1'' WHERE GroupID=?',[FAVORITES_GROUP_ID]);
  finally DB.Free; end;
  Folder:=TPath.Combine(Settings.AppPath,'snapshot-backup'); ForceDirectories(Folder);
  BackupCollectionFile(FileName,TPath.Combine(Folder,'destination.hlc2'));
  BackupCollectionFile(SysFile,TPath.Combine(Folder,'system.hlc2'));
  Extra:=ReadValue('SELECT hex(ExtraInfo) FROM Books WHERE DatabaseID='+IntToStr(ID));
  TFile.WriteAllText(TPath.Combine(Folder,'restore-paths.txt'),'Коллекция: '+FileName+#13#10+
    'Группы и настройки: '+SysFile,TEncoding.UTF8);
  // Change live state after the backup; restoring may only create new rows.
  AddBook(C,'After merge','Автор','ru','','');
  DB:=TSQLiteDatabase.Create(SysFile);
  try
    DB.ExecSQL('UPDATE Groups SET Notes=X''AABB'' WHERE GroupID=?',[GroupID]);
    DB.ExecSQL('UPDATE Groups SET Notes=X''CCDD'' WHERE GroupID=?',[FAVORITES_GROUP_ID]);
  finally DB.Free; end;
  Stamp:=SystemDB.GetDataRevision;
  Plan:=TCollectionBackupPlan.Create(Folder);
  try
    Plan.Preview;
    Require(Plan.Ready and Plan.Report.Text.Contains('Записей книг: 1'),'Backup preview lost the saved state');
    Require(SystemDB.GetDataRevision=Stamp,'Read-only backup preview changed current system data');
    Dest:=TPath.Combine(Settings.DataPath,'snapshot-restored.hlc2');
    MovedRoot:=TPath.Combine(Settings.AppPath,'moved-books'); Plan.Root:=MovedRoot;
    NewID:=Plan.RestoreAsNew(SystemDB,Dest,'Snapshot restored');
    Restored:=SystemDB.GetCollection(NewID);
    DB:=TSQLiteDatabase.CreateReadOnly(Dest);
    try Require(DB.QuerySingleInt('SELECT count(*) FROM Books')=1,'Restored catalog contains post-backup books'); finally DB.Free; end;
    Restored.GetBookRecord(CreateBookKey(B,NewID),Book,True);
    Require((Book.Rate=4) and (Book.Progress=37),'Restored personal rating/progress differs');
    Require(ReadValue('SELECT hex(Review)||hex(Annotation) FROM Books WHERE DatabaseID='+IntToStr(NewID))=
      '00FF8081004241000042','Restoration recoded raw personal BLOBs');
    Require(ReadValue('SELECT hex(ExtraInfo) FROM Books WHERE DatabaseID='+IntToStr(NewID))=Extra,
      'Restoration changed author/genre/series card data');
    Require(ReadValue('SELECT hex(Notes) FROM Groups WHERE GroupID='+IntToStr(GroupID))='AABB',
      'Restoration overwrote live group notes');
    Require(ReadValue('SELECT count(*) FROM Groups g JOIN BookGroups b USING(GroupID) WHERE hex(g.Notes)=''0100FF80'' AND b.DatabaseID='+IntToStr(NewID))=
      '1','Historical group notes were discarded');
    Require(ReadValue('SELECT count(*) FROM BookGroups WHERE GroupID=1 AND DatabaseID='+IntToStr(NewID))='1',
      'Restoration lost the built-in favourites membership');
    Require(ReadValue('SELECT hex(Notes) FROM Groups WHERE GroupID=1')='CCDD',
      'Restoration overwrote current built-in group notes');
    Require(ReadValue('SELECT count(*) FROM Groups g JOIN BookGroups b USING(GroupID) WHERE hex(g.Notes)=''0B00A1'' AND b.DatabaseID='+IntToStr(NewID))='1',
      'Restoration discarded historical built-in group notes');
    Require(SameFileName(ExcludeTrailingPathDelimiter(ReadValue('SELECT Folder FROM Books WHERE DatabaseID='+IntToStr(NewID))),MovedRoot),
      'Relocated snapshot kept the old path in personal/group cards');
    Require(ReadValue('SELECT count(*) FROM Books WHERE DatabaseID='+IntToStr(ID))='1',
      'Restoration changed original personal cards');
    Other.GetBookRecord(CreateBookKey(OtherBook,OtherID),Book,True);
    Require(Book.Title='Unrelated','Restoration changed another collection');
    // A failure after registration must roll the entire system transaction back.
    Stamp:=PersistentStamp; Failed:=False;
    try Plan.RestoreAsNew(SystemDB,TPath.Combine(Settings.DataPath,'snapshot-failed.hlc2'),'Snapshot restored');
    except on E: Exception do Failed:=True; end;
    Require(Failed and not FileExists(TPath.Combine(Settings.DataPath,'snapshot-failed.hlc2')),
      'Failed restoration left an orphan file');
    Require(PersistentStamp=Stamp,'Failed restoration changed live system data');
    Calls:=0; Failed:=False;
    try Plan.RestoreAsNew(SystemDB,TPath.Combine(Settings.DataPath,'snapshot-cancel.hlc2'),'Snapshot cancelled',
      function: Boolean begin Inc(Calls); Result:=Calls>=5; end);
    except on E: EAbort do Failed:=True; end;
    Require(Failed and not FileExists(TPath.Combine(Settings.DataPath,'snapshot-cancel.hlc2')),
      'Cancelled snapshot left an orphan file');
    Require(PersistentStamp=Stamp,'Cancellation after registration left persistent personal data');
    RacePath:=TPath.Combine(Settings.DataPath,'snapshot-race.hlc2'); Failed:=False;
    try Plan.RestoreAsNew(SystemDB,RacePath,'Snapshot race',nil,
      procedure(Done,Total: Integer)
      begin if not FileExists(RacePath) then TFile.WriteAllText(RacePath,'Existing file must survive',TEncoding.UTF8); end);
    except on E: Exception do Failed:=True; end;
    Require(Failed and (TFile.ReadAllText(RacePath,TEncoding.UTF8)='Existing file must survive'),
      'Destination race overwrote or removed a file the restore operation did not create');
    Failed:=False;
    try Plan.RestoreAsNew(SystemDB,FileName,'Overwrite original'); except on E: Exception do Failed:=True; end;
    Require(Failed,'Snapshot allowed replacing the original catalog');
    Calls:=0; Failed:=False;
    try Plan.Preview(function: Boolean begin Inc(Calls); Result:=True; end);
    except on E: EAbort do Failed:=True; end;
    Require(Failed and not Plan.Ready and not Assigned(SQLiteCancelCallback),
      'Cancelled preview retained a dangling SQLite callback or apply permission');
  finally Plan.Free; end;
  Dialog:=TfrmCollectionBackup.Create(nil);
  try
    Require(((Dialog.FindComponent('edRestoredCollectionName') as TEdit).Text='') and
      ((Dialog.FindComponent('edRestoredBooksRoot') as TEdit).Text=''),
      'Restore fields display component names before a validated preview');
    Dialog.AddFolder(Folder); Dialog.Show; Application.ProcessMessages;
    Button:=Dialog.FindComponent('btnRestoreBackup') as TButton;
    Require(not Button.Enabled,'Restoration is enabled before preview');
    (Dialog.FindComponent('btnCheckBackup') as TButton).Click;
    NameEdit:=Dialog.FindComponent('edRestoredCollectionName') as TEdit;
    RootEdit:=Dialog.FindComponent('edRestoredBooksRoot') as TEdit;
    Report:=Dialog.FindComponent('mmBackupPreview') as TMemo;
    Require(Button.Enabled and NameEdit.Enabled and RootEdit.Enabled and
      (Pos('Записей книг: 1',Report.Text)>0),'Restore UI preview did not publish the validated snapshot');
    for var PPI in [96,144,192,96] do
    begin
      Dialog.ScaleForPPI(PPI); Application.ProcessMessages;
      Writeln('PROFILE snapshot dpi=',PPI,' actual=',Dialog.CurrentPPI,' client=',Dialog.ClientWidth,'x',Dialog.ClientHeight,
        ' min=',Dialog.Constraints.MinWidth,'x',Dialog.Constraints.MinHeight);
      Require((NameEdit.Left+NameEdit.Width<=NameEdit.Parent.ClientWidth) and
        (RootEdit.Top+RootEdit.Height<Button.Top) and (Report.Height>50),
        'Restore preview or fields overlap at scaled DPI');
      Require((Abs(Dialog.ClientWidth-MulDiv(760,PPI,96))<=4) and
        (Abs(Dialog.ClientHeight-MulDiv(570,PPI,96))<=4),
        'Restore window size compounded across DPI transitions');
    end;
    if (GetEnvironmentVariable('HLRU_FEEDBACK529_VISUAL')='1') or
      (GetEnvironmentVariable('HLRU_FEEDBACK529_VISUAL')='backup') then
    begin
      Dialog.ScaleForPPI(96);
      Writeln('PROFILE snapshot return dpi=',Dialog.CurrentPPI,' client=',Dialog.ClientWidth,'x',Dialog.ClientHeight);
      Dialog.Hide; Dialog.ShowModal;
    end;
  finally Dialog.Free; end;
  Writeln('PASS snapshot restore creates an isolated catalog, preserves raw cards and group notes, rolls back failures and cancellation');
end;
