// Exercises the real menu action, modal choices, background timer and visible
// row refresh in the normal catalogue. All files belong to the guarded runtime.

procedure ArmCompressionRecoveryCrash(const Fault, ReportFile: string); forward;
function CompressionBodyHash(const Body:TBytes):string; forward;
procedure TestCancelledCompressionRefresh(const Collection:IBookCollection;
  const PreviousBooks:TArray<TBookRecord>); forward;

{$I CompressionCopyIndexTests.inc}

procedure TestCompressionIndexBoundaries;
var Root,Source,Identity,Member,Key,Digest:string; DB:TSQLiteDatabase; Zip:TZipFile; Body:TBytes;
  procedure Seed(Archived:Boolean);
  begin
    DB.ExecSQL('DELETE FROM Books'); DB.ExecSQL('DELETE FROM HomeLibreBookCompression');
    DB.ExecSQL('DELETE FROM HomeLibreCompressionChecks');
    Source:=Root+'one.txt'; Member:='';
    if Archived then
    begin
      Source:=Root+'one.zip'; Member:='one.txt'; Zip:=TZipFile.Create;
      try Zip.Open(Source,zmWrite); Zip.Add(Body,Member); finally Zip.Free; end;
    end
    else TFile.WriteAllBytes(Source,Body);
    Identity:=ArchiveDeletionSourceIdentity(Source); Key:=UpperCase(Copy(Identity,1,25));
    Digest:=CompressionBodyHash(Body);
    DB.ExecSQL('INSERT INTO Books VALUES(1,''same-library-id'',?,''one'',''.txt'',0,?)',
      [IfThen(Archived,'one.zip',''),Length(Body)]);
    DB.ExecSQL('INSERT INTO HomeLibreBookCompression VALUES(?,?,?,?,?)',
      [Key,Member,Length(Body),Digest,CompressionBodyHash(TEncoding.UTF8.GetBytes('Original book before compression'))]);
    DB.ExecSQL('INSERT INTO HomeLibreCompressionChecks VALUES(?,?,?,?)',[Key,Member,Identity,Digest]);
  end;
  procedure BeginRefresh;
  begin CaptureCompressionIndexSizes(DB,Root,'LibID'); DB.ExecSQL('UPDATE Books SET BookSize=999,BookID=101'); end;
  procedure FinishRefresh(Expected:Integer; const Name:string);
  begin
    RestoreCompressionIndexSizes(DB,Root,'LibID');
    Require(DB.QuerySingleInt('SELECT BookSize FROM Books')=Expected,'Compressed size boundary failed: '+Name);
    Require(DB.QuerySingleInt('SELECT count(*) FROM sqlite_temp_master WHERE name LIKE ''InpxCompress%''')=0,
      'Compression size snapshots leaked after '+Name);
  end;
begin
  Root:=Settings.AppPath+'compression-index-boundaries\'; ForceDirectories(Root);
  Body:=TEncoding.UTF8.GetBytes('A verified compressed book.');
  DB:=TSQLiteDatabase.Create(Root+'index.sqlite');
  try
    DB.ExecSQL('CREATE TABLE Books(BookID INTEGER PRIMARY KEY,LibID TEXT,Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER)');
    DB.ExecSQL('CREATE TABLE HomeLibreBookCompression(FileKey TEXT,Member TEXT,BookSize INTEGER,OutputSHA256 TEXT,InputSHA256 TEXT)');
    DB.ExecSQL('CREATE TABLE HomeLibreCompressionChecks(FileKey TEXT,Member TEXT,SourceIdentity TEXT,PayloadSHA256 TEXT)');
    Seed(False); BeginRefresh; FinishRefresh(Length(Body),'standalone file and renumbered ID');
    Seed(True); BeginRefresh; FinishRefresh(Length(Body),'archive member and renumbered ID');
    Seed(True); BeginRefresh; DB.ExecSQL('UPDATE Books SET Folder=''.\one.zip''');
    FinishRefresh(Length(Body),'same physical archive through another locator spelling');
    Seed(False); BeginRefresh; TFile.AppendAllText(Source,'changed',TEncoding.UTF8);
    FinishRefresh(999,'source changed during import');
    Seed(False); TFile.AppendAllText(Source,'changed',TEncoding.UTF8); BeginRefresh;
    FinishRefresh(999,'stale proof before import');
    Seed(False); BeginRefresh; DB.ExecSQL('UPDATE Books SET Folder=''another-folder\''');
    FinishRefresh(999,'reused library ID at another path');
    Seed(True); TFile.Copy(Source,Root+'another.zip',True);
    DB.ExecSQL('UPDATE Books SET Folder=''another.zip'''); BeginRefresh;
    FinishRefresh(999,'same member in another physical archive');
    Seed(False); DB.ExecSQL('UPDATE HomeLibreCompressionChecks SET PayloadSHA256=''different''');
    BeginRefresh; FinishRefresh(999,'no matching payload proof');
    Seed(True); DB.ExecSQL('UPDATE HomeLibreBookCompression SET BookSize=-1');
    BeginRefresh; FinishRefresh(999,'unknown restored size must not replace publisher size');
    Seed(True); DB.ExecSQL('UPDATE HomeLibreBookCompression SET InputSHA256=OutputSHA256');
    BeginRefresh; FinishRefresh(999,'legacy unchanged inspection is not a measured restored size');
    Seed(False); DB.Start;
    CaptureCompressionIndexSizes(DB,Root,'LibID'); DB.ExecSQL('DELETE FROM Books'); DB.Rollback;
    Require(DB.QuerySingleInt('SELECT BookSize FROM Books')=Length(Body),'Canceled index import changed book size');
    Require(DB.QuerySingleInt('SELECT count(*) FROM sqlite_temp_master WHERE name LIKE ''InpxCompress%''')=0,
      'Canceled index import leaked compression snapshots');
    Writeln('PASS eleven compressed-size boundaries preserve physical identity and rollback');
  finally DB.Free; end;
end;

procedure CheckCompressionSizesAfterFullInpx(const Collection:IBookCollection;
  const Books:TArray<TBookRecord>);
var Archive:TZipFile; Input, Row, Name, SourceHash:string; Worker:TManualUpdateThread;
    Reader:TSQLiteDatabase; Reloaded:IBookCollection; Book, Personal:TBookRecord;
    Expected:TArray<Int64>;
begin
  Input:=Settings.AppPath+'compression-refresh.inpx'; Name:=''; SetLength(Expected,Length(Books));
  Reloaded:=SystemDB.GetCollection(Collection.CollectionID,True);
  for var I:=0 to High(Books) do
  begin
    Reloaded.GetBookRecord(Books[I].BookKey,Book,False); Expected[I]:=Book.Size;
    Require(Book.Size<Books[I].Size,'Compression fixture did not reduce its selected book');
    Row:='Автор,Тест:'#4'prose_contemporary:'#4+Book.Title+#4#4#4+Book.FileName+#4+
      IntToStr(Books[I].Size)+#4+Book.LibID+#4'0'#4'fb2'#4'2026-11-14'#4'ru';
    Name:=Name+Row+sLineBreak;
  end;
  Archive:=TZipFile.Create;
  try
    Archive.Open(Input,zmWrite);
    Archive.Add(TEncoding.UTF8.GetBytes(Name),'books/shared.inp');
    Archive.Add(TEncoding.UTF8.GetBytes('20261114'),'version.info');
  finally Archive.Free; end;
  SourceHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'books\shared.zip');
  Worker:=TManualUpdateThread.Create(Collection.CollectionID,Input,True,gtFb2);
  try
    Worker.Start; Worker.WaitFor;
    Require(Worker.Success and Worker.CommittedChanges,'Actual full INPX update failed; see worker diagnostics');
  finally Worker.Free; end;
  Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'books\shared.zip')=SourceHash,
    'Index refresh changed the compressed physical archive');
  Reloaded:=SystemDB.GetCollection(Collection.CollectionID,True);
  Reader:=TSQLiteDatabase.CreateReadOnly(Reloaded.GetProperty(PROP_DATAFILE));
  try
    for var I:=0 to High(Books) do
    begin
      var ID:=Reader.QuerySingleInt('SELECT BookID FROM Books WHERE LibID=?',[Books[I].LibID]);
      Require(ID>0,'Full refresh lost the selected compressed book');
      Reloaded.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Book,False);
      Require(Book.Size=Expected[I],Format('Full INPX replaced compressed size %d with index size %d; folder "%s" -> "%s"',
        [Expected[I],Book.Size,Books[I].Folder,Book.Folder]));
      if I=0 then
      begin
        SystemDB.GetBookRecord(Book.BookKey,Personal);
        Require(Personal.Progress=37,'Full INPX update lost reading progress');
      end;
    end;
  finally Reader.Free; end;
  Writeln('PASS actual full INPX refresh keeps verified compressed sizes and personal progress');
  TestCompressionIndexBoundaries; TestCompressionCopyIndexBoundaries;
end;

type
  TCompressionCatalogueDriver = class
    Timer: TTimer;
    Mode, OriginalSHA, Source, BackupFolder, RecoveryFault, RecoveryIssues, ResultNote: string;
    ProfileIndex, ExpectedBooks: Integer;
    ExpectedMembers:TArray<string>;
    Grayscale, CancelOptions, InspectWorkPicker: Boolean;
    WorkPickerInitial, WorkPickerExpected:string;
    InspectComparison, EstimateFirst, EstimateSeen, Whole, OnlyNew: Boolean;
    ProducerStageSeen, EstimateStageSeen: Boolean;
    InspectionDeadline, Started: UInt64;
    LastStage: string;
    OptionsSeen, ReviewSeen, ResultSeen, DecisionSent, ComparisonSeen: Boolean;
    procedure Tick(Sender: TObject);
  end;

function CompressionBodyHash(const Body:TBytes):string;
var Hash:THashSHA2;
begin
  Hash:=THashSHA2.Create; Hash.Update(Body); Result:=Hash.HashAsString;
end;

procedure TCompressionCatalogueDriver.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionCompare) and Screen.Forms[I].Visible then
    begin
      var Form:=TfrmBookCompressionCompare(Screen.Forms[I]);
      if InspectComparison then
      begin
        if InspectionDeadline=0 then
        begin InspectionDeadline:=GetTickCount64+40000; Writeln('TRACE comparison visible for visual inspection'); Flush(Output); end;
        if GetTickCount64<InspectionDeadline then Exit;
      end;
      Require(not TCheckBox(Form.FindComponent('ComparisonFit')).Checked,'Comparison must start at actual 100 percent');
      var Before:=TImage(Form.FindComponent('ComparisonBeforeImage'));
      var Choices:=TComboBox(Form.FindComponent('ComparisonImages'));
      for var Member in ExpectedMembers do
      begin
        var Found:=False;
        for var J:=0 to Choices.Items.Count-1 do
          if Choices.Items[J].StartsWith(Member+' · ') then
          begin
            Choices.ItemIndex:=J; Choices.OnChange(Choices);
            Require(Assigned(Before.Picture.Graphic) and
              Assigned(TImage(Form.FindComponent('ComparisonAfterImage')).Picture.Graphic),
              'Comparison failed to decode selected book: '+Member);
            Found:=True; Break;
          end;
        Require(Found,'Comparison omitted an illustrated selected book: '+Member);
      end;
      Choices.ItemIndex:=0; Choices.OnChange(Choices);
      Require((Before.Picture.Graphic=nil) or (Before.Width=Before.Picture.Width),'Comparison changed original pixel size');
      if Grayscale then Require(Assigned(Before.Picture.Graphic),'Original preview failed to decode');
      for var Dark in [False,True] do
      begin
        SetMHLTheme(Dark); ApplyMHLControlTheme(Form);
        Require(Form.Color=MHLThemeBackground,'Comparison theme differs from catalogue');
        for var PPI in [96,144,192,288] do
        begin
          Form.ScaleForPPI(PPI);
          var Close:=TButton(Form.FindComponent('ComparisonClose'));
          Require((Close.Left>=0) and (Close.Top>=0) and (Close.Left+Close.Width<=Form.ClientWidth) and
            (Close.Top+Close.Height<=Form.ClientHeight),'Comparison close button clipped after scaling');
          Require((Before.Picture.Graphic=nil) or (Before.Width=Before.Picture.Width),'100 percent changed when DPI changed');
        end;
      end;
      ComparisonSeen:=True;
      TButton(Form.FindComponent('ComparisonClose')).Click;
      Exit;
    end;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionOptions) and Screen.Forms[I].Visible then
    begin
      var Form:=TfrmBookCompressionOptions(Screen.Forms[I]);
      if not OptionsSeen then begin Writeln('TRACE compression options ms=',GetTickCount64-Started); Flush(Output); end;
      if OptionsSeen then Exit;
      OptionsSeen:=True;
      if OnlyNew then Require(Form.Caption='Сжать новые книги','New-books command lost its distinct choices')
      else if Whole then Require(Form.Caption='Сжать текущую коллекцию','Whole collection opens the old copy wizard');
      if OnlyNew then
      begin
        Require(TComboBox(Form.FindComponent('CompressionProfile')).ItemIndex=ProfileIndex,'Offer lost saved quality');
        Require(TCheckBox(Form.FindComponent('CompressionGrayscale')).Checked=Grayscale,'Offer lost saved grayscale');
      end;
      if CancelOptions then
      begin
        if WorkPickerExpected<>'' then
          Require(TEdit(Form.FindComponent('CompressionWorkFolder')).Text=WorkPickerExpected,
            'Reopened compression options lost the folder selected through Windows');
        TButton(Form.FindComponent('CompressionCancel')).Click; Exit;
      end;
      TComboBox(Form.FindComponent('CompressionProfile')).ItemIndex:=ProfileIndex;
      TCheckBox(Form.FindComponent('CompressionGrayscale')).Checked:=Grayscale;
      TCheckBox(Form.FindComponent('CompressionReview')).Checked:=True;
      if InspectWorkPicker then TEdit(Form.FindComponent('CompressionWorkFolder')).Text:=WorkPickerInitial
      else TEdit(Form.FindComponent('CompressionWorkFolder')).Text:=Settings.AppPath+'compression-work';
      TCheckBox(Form.FindComponent('CompressionBackup')).Checked:=True;
      TEdit(Form.FindComponent('CompressionBackupFolder')).Text:=BackupFolder;
      if InspectWorkPicker then
      begin Writeln('TRACE actual work-folder picker ready; choose ',ExtractFileDir(WorkPickerExpected)); Flush(Output); Exit; end;
      if EstimateFirst then TButton(Form.FindComponent('CompressionEstimate')).Click
      else TButton(Form.FindComponent('CompressionStart')).Click;
      Exit;
    end;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionProgress) and Screen.Forms[I].Visible then
    begin
      var Form:=TfrmBookCompressionProgress(Screen.Forms[I]);
      var Stage:=TLabel(Form.FindComponent('CompressionStage')).Caption;
      if Stage='Подготавливаем выбранную книгу' then ProducerStageSeen:=True;
      if Stage='Оцениваем выбранную книгу' then EstimateStageSeen:=True;
      if Stage<>LastStage then
      begin LastStage:=Stage; Writeln('TRACE compression ms=',GetTickCount64-Started,' stage=',Stage); Flush(Output); end;
      if TButton(Form.FindComponent('CompressionApply')).Visible and
        (TButton(Form.FindComponent('CompressionApply')).Caption='Начать сжатие') then
      begin
        if EstimateSeen then Exit;
        EstimateSeen:=True; ReviewSeen:=True;
        Require(THashSHA2.GetHashStringFromFile(Source)=OriginalSHA,'Estimate changed original archive');
        Require(Length(TDirectory.GetFiles(BackupFolder,'*.zip'))=0,'Estimate published a backup');
        Require(not TButton(Form.FindComponent('CompressionApplyAll')).Visible,'Estimate applies later quality choices implicitly');
        Require(Pos('до внешней упаковки',TLabel(Form.FindComponent('CompressionNote')).Caption)>0,
          'Estimate confused payload sizes with disk savings');
        if Mode='estimate' then TButton(Form.FindComponent('CompressionSkip')).Click
        else TButton(Form.FindComponent('CompressionApply')).Click;
        Exit;
      end;
      if TButton(Form.FindComponent('CompressionApply')).Visible and not DecisionSent then
      begin
        // Browsing pumps VCL messages. Mark this decision before that pump so
        // the driver's own timer cannot enter the same review a second time.
        DecisionSent:=True;
        ReviewSeen:=True;
        if RecoveryFault<>'' then
        begin
          var Reports:=TDirectory.GetFiles(Settings.AppPath+'compression-work','report.json',TSearchOption.soAllDirectories);
          Require(Length(Reports)=1,'Expected one actual producer report before crash');
          ArmCompressionRecoveryCrash(RecoveryFault,Reports[0]);
          TButton(Form.FindComponent('CompressionApply')).Click;
          Exit;
        end;
        Require(THashSHA2.GetHashStringFromFile(Source)=OriginalSHA,'Review changed the original before approval');
        Require(Length(TDirectory.GetFiles(BackupFolder,'*.zip'))=0,'Skipped review already published a backup');
        // Browsing remains available while the background operation waits.
        ShowPage(PAGE_AUTHORS);
        Application.ProcessMessages;
        Require(frmMain.Enabled,'Catalogue blocked during background compression review');
        var FormsBefore:=Screen.FormCount;
        frmMain.ImportSelectedBookUpdate(frmMain.acImportSelectedBook);
        Require(not frmMain.acImportSelectedBook.Enabled,'Import still enabled during compression');
        frmMain.UpdateCollectionFromFileExecute(nil);
        frmMain.ShowCollectionSettingsExecute(nil);
        frmMain.EditBookExecute(nil);
        frmMain.CompactDataBaseExecute(nil);
        frmMain.ImportFb2Execute(nil);
        frmMain.ImportFBDExecute(nil);
        frmMain.ImportNonFB2Execute(nil);
        frmMain.DeleteCollectionExecute(nil);
        Require(Screen.FormCount=FormsBefore,'Concurrent catalogue edit opened a second workflow');
        Require(THashSHA2.GetHashStringFromFile(Source)=OriginalSHA,'Concurrent action changed compressed books');
        var Compare:=TButton(Form.FindComponent('CompressionCompare'));
        if Compare.Visible then Compare.Click;
        Require(ComparisonSeen,'Quality comparison was unavailable for the illustrated test books');
        if Mode='skip' then TButton(Form.FindComponent('CompressionSkip')).Click
        else if Mode='stop' then TButton(Form.FindComponent('CompressionStop')).Click
        else TButton(Form.FindComponent('CompressionApply')).Click;
      end;
      if TButton(Form.FindComponent('CompressionStop')).Caption='Закрыть' then
      begin
        ResultSeen:=True; Timer.Enabled:=False;
        var Note:string:=TLabel(Form.FindComponent('CompressionNote')).Caption;
        ResultNote:=Note;
        Writeln('TRACE compression result ',TLabel(Form.FindComponent('CompressionStage')).Caption,' · ',Note); Flush(Output);
        Require(not Note.Contains('Не удалось') and not Note.Contains('исходник'),
          'Compression result error: '+Note);
        if Mode='recovery' then
        begin
          if Pos('Книги: 0 из 0',TLabel(Form.FindComponent('CompressionCounts')).Caption)>0 then
            RecoveryIssues:=RecoveryIssues+'Recovery shows zero-of-zero books. ';
          if Pos('Освобождено: 0',frmMain.StatusMessage)>0 then
            RecoveryIssues:=RecoveryIssues+'Recovery reports an unmeasured zero saving. ';
        end;
        if OnlyNew then
        begin
          Require(Pos('Новых книг',TLabel(Form.FindComponent('CompressionStage')).Caption)>0,
            'Unchanged collection did not finish with a clear no-arrivals result');
          Require(Note.Contains('Ранее проверено книг с этими настройками: '+IntToStr(ExpectedBooks)+'.'),
            'Already processed books disappeared from the result');
        end;
        TButton(Form.FindComponent('CompressionStop')).Click;
      end;
    end;
end;

procedure TestLegacyCompressionHistoryCatalogue(const Collection:IBookCollection; FirstID,SecondID:Integer);
var Config,Item:TJSONObject; Driver:TCompressionCatalogueDriver; DB:TSQLiteDatabase;
    Books:TArray<TBookRecord>; Source,OriginalSHA,Path,Key,Cached,Catalogue:string;
    Started:UInt64; Node:PVirtualNode; Data:PBookRecord; Selected:Integer; Action:TAction;
begin
  Config:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'legacy-compression-fixture.json',TEncoding.UTF8)) as TJSONObject;
  Require(Assigned(Config),'Invalid old compression fixture');
  Driver:=TCompressionCatalogueDriver.Create;
  try
    Catalogue:=Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE)));
    Require(SameFileName(ExtractFilePath(Catalogue),Settings.AppPath),
      'Old payload witnesses must be beside their real registered catalogue');
    DB:=TSQLiteDatabase.Create(Catalogue);
    try
      Require(DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''HomeLibreBookCompression''')=0,
        'Old catalogue already has native compression receipts');
      DB.ExecSQL('CREATE TABLE HomeLibPackingState(Key TEXT PRIMARY KEY,Value TEXT NOT NULL)');
      for var Pair in Config.GetValue<TJSONObject>('state') do
        DB.ExecSQL('INSERT INTO HomeLibPackingState VALUES(?,?)',[Pair.JsonString.Value,Pair.JsonValue.Value]);
    finally DB.Free; end;
    SetLength(Books,2);
    for var I:=0 to 1 do
    begin
      Item:=Config.GetValue<TJSONArray>('books').Items[I] as TJSONObject;
      var ID:=FirstID; if I=1 then ID:=SecondID;
      Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Books[I],True);
      Books[I].Folder:=Item.GetValue<string>('folder'); Books[I].FileName:=Item.GetValue<string>('filename');
      Books[I].FileExt:=Item.GetValue<string>('ext'); Books[I].InsideNo:=Item.GetValue<Integer>('inside_no');
      Path:=TPath.GetFullPath(Settings.AppPath+Item.GetValue<string>('decoded'));
      Require(Path.StartsWith(Settings.AppPath,True) and FileExists(Path),'Missing private decoded old book');
      Books[I].Size:=TFile.GetSize(Path); Collection.UpdateBook(Books[I]);
    end;
    Source:=Books[0].GetBookFileName;
    Require(Source=Books[1].GetBookFileName,'Old fixture must share one real PPMd archive');
    OriginalSHA:=THashSHA2.GetHashStringFromFile(Source);
    Require(TryStoreReaderBookProgress(Collection,Books[0],37),'Cannot seed old collection reading progress');
    Cached:=PrepareReaderFile(Books[0],True);
    Item:=Config.GetValue<TJSONArray>('books').Items[0] as TJSONObject;
    Require(THashSHA2.GetHashStringFromFile(Cached)=Item.GetValue<string>('sha256'),'Reader could not read old PPMd output');
    Settings.TreeModes[PAGE_SEARCH]:=tmFlat; ShowPage(PAGE_SEARCH);
    frmMain.btnClearFilterEdits.Click; frmMain.acApplyPreset.Execute;
    Selected:=0; Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvBooksSR.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) and
        ((Data^.BookKey.BookID=FirstID) or (Data^.BookKey.BookID=SecondID)) then
      begin
        frmMain.tvBooksSR.CheckState[Node]:=csCheckedNormal; frmMain.tvBooksSR.FocusedNode:=Node;
        frmMain.tvBooksSR.Selected[Node]:=True; Inc(Selected);
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(Selected=2,'Select both legacy book formats in the actual catalogue');
    Driver.Mode:='apply'; Driver.Source:=Source; Driver.OriginalSHA:=OriginalSHA;
    Driver.ProfileIndex:=3; Driver.Grayscale:=False;
    Driver.BackupFolder:=Settings.AppPath+'originals'; ForceDirectories(Driver.BackupFolder);
    Driver.Started:=GetTickCount64;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Tick; Driver.Timer.Enabled:=True;
    Action:=frmMain.FindComponent('acCompressSelectedBooks') as TAction;
    Require(Assigned(Action),'Missing normal selected-book command');
    Action.Update; Require(Action.Enabled,'Normal command disabled for an old compressed catalogue');
    Action.Execute; Started:=GetTickCount64;
    while not Driver.ResultSeen and (GetTickCount64-Started<90000) do begin Application.ProcessMessages; Sleep(10); end;
    Require(Driver.OptionsSeen and Driver.ResultSeen and not Driver.ReviewSeen,
      'Verified old books were proposed for another lossy pass: '+Driver.LastStage);
    Require(THashSHA2.GetHashStringFromFile(Source)=OriginalSHA,'Migration rewrote the old archive');
    Require(Length(TDirectory.GetFiles(Driver.BackupFolder,'*.zip'))=0,'Unchanged old books created an unnecessary backup');
    DB:=TSQLiteDatabase.CreateReadOnly(Catalogue);
    try
      Key:=UpperCase(Copy(ArchiveDeletionSourceIdentity(Source),1,25));
      for var I:=0 to 1 do
      begin
        Item:=Config.GetValue<TJSONArray>('books').Items[I] as TJSONObject;
        Require(DB.QuerySingleInt('SELECT count(*) FROM HomeLibreBookCompression WHERE FileKey=? AND Member=? AND OutputSHA256=?',
          [Key,Books[I].FileName+Books[I].FileExt,Item.GetValue<string>('sha256')])=1,'Old member did not acquire a verified native receipt');
        Require(DB.QuerySingleInt('SELECT count(*) FROM HomeLibreCompressionOutcomes WHERE FileKey=? AND Member=? AND RetryOriginal=0',
          [Key,Books[I].FileName+Books[I].FileExt])=1,'Old format was not recognized as an already optimized book');
      end;
      Require(DB.QuerySingleInt('SELECT count(*) FROM HomeLibreCompressedImages')>=1,'Old raster history did not reach native storage');
    finally DB.Free; end;
    var Personal:TBookRecord; SystemDB.GetBookRecord(Books[0].BookKey,Personal);
    Require(Personal.Progress=37,'Migrating old image history changed personal progress');
    Writeln('PASS normal catalogue migrated legacy FB2 EPUB history without rewriting archive');
  finally Driver.Timer.Free; Driver.Free; Config.Free; end;
end;

procedure TestSelectedCompressionCatalogue(const Collection: IBookCollection;
  FirstID, SecondID: Integer);
const Profiles:array[0..3] of string=('original','balanced','economy','maximum');
var Driver:TCompressionCatalogueDriver; After:TBookRecord;
    OldSize, NewSize:Int64; Data:PBookRecord; Node:PVirtualNode;
    Action:TAction; Source, Cached, Mode, Registry:string;
    Options:TBookCompressionOperationOptions; Zip:TZipFile;
    Books:TArray<TBookRecord>; OriginalBody, OutputBody:TBytes; Started, Timeout:UInt64;
    Members:TArray<string>; IDs:TArray<Integer>; OriginalBodies:TArray<TBytes>; Config:TJSONObject;
    MemberList:TJSONArray;
  function SelectedBookIndex(ID:Integer):Integer;
  begin
    Result:=-1;
    for var I:=0 to High(IDs) do if IDs[I]=ID then Exit(I);
  end;
begin
  if FileExists(Settings.AppPath+'legacy-compression-fixture.json') then
    TestLegacyCompressionHistoryCatalogue(Collection,FirstID,SecondID);
  Mode:=ParamStr(2);
  Require(MatchText(Mode,['apply','skip','stop','estimate']),'Expected apply, skip, stop or estimate');
  Source:=Settings.AppPath+'books\shared.zip';
  Require(FileExists(Source),'Missing isolated book archive');
  Driver:=TCompressionCatalogueDriver.Create;
  Config:=nil;
  try
    Members:=TArray<string>.Create('one.fb2','two.fb2'); Timeout:=45000;
    Driver.ProfileIndex:=2; Driver.Grayscale:=True;
    if FileExists(Settings.AppPath+'compression-fixture.json') then
    begin
      Config:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'compression-fixture.json',TEncoding.UTF8)) as TJSONObject;
      Require(Assigned(Config),'Invalid isolated compression fixture');
      Members[0]:=Config.GetValue<string>('first','one.fb2');
      Members[1]:=Config.GetValue<string>('second','two.fb2');
      if Config.TryGetValue<TJSONArray>('members',MemberList) then
      begin
        Require(InRange(MemberList.Count,2,10),'Expected two to ten selected test books');
        SetLength(Members,MemberList.Count);
        for var I:=0 to MemberList.Count-1 do Members[I]:=MemberList.Items[I].Value;
      end;
      Driver.Grayscale:=Config.GetValue<Boolean>('grayscale',True);
      Driver.ProfileIndex:=Config.GetValue<Integer>('profile_index',2);
      Require(InRange(Driver.ProfileIndex,0,3),'Invalid fixture compression profile');
      Driver.InspectComparison:=Config.GetValue<Boolean>('inspect_comparison',False);
      Driver.InspectWorkPicker:=Config.GetValue<Boolean>('inspect_work_picker',False);
      Driver.WorkPickerInitial:=Config.GetValue<string>('work_picker_initial','');
      Driver.WorkPickerExpected:=Config.GetValue<string>('work_picker_expected','');
      Driver.EstimateFirst:=Config.GetValue<Boolean>('estimate_first',False);
      Driver.Whole:=Config.GetValue<Boolean>('whole',False);
      Driver.RecoveryFault:=Config.GetValue<string>('recovery_fault','');
      Timeout:=Config.GetValue<UInt64>('timeout_ms',45000);
      Require((Timeout>=1000) and (Timeout<=300000),'Invalid bounded fixture timeout');
    end;
    Driver.Mode:=Mode; Driver.Source:=Source;
    if Mode='estimate' then Driver.EstimateFirst:=True;
    Driver.OriginalSHA:=THashSHA2.GetHashStringFromFile(Source);
    Driver.BackupFolder:=Settings.AppPath+'originals'; ForceDirectories(Driver.BackupFolder);
    Driver.ExpectedBooks:=Length(Members); Driver.ExpectedMembers:=Copy(Members);
    SetLength(Books,Length(Members)); SetLength(IDs,Length(Members));
    SetLength(OriginalBodies,Length(Members));
    IDs[0]:=FirstID; IDs[1]:=SecondID;
    for var I:=2 to High(IDs) do
      IDs[I]:=AddBook(Collection,'Compression selected '+IntToStr(I),'Alpha','ru','','prose_contemporary');
    Zip:=TZipFile.Create;
    try
      Zip.Open(Source,zmRead);
      for var I:=0 to High(Books) do
      begin
        Collection.GetBookRecord(CreateBookKey(IDs[I],Collection.CollectionID),Books[I],True);
        Require((ExtractFileName(Members[I])=Members[I]) and (Zip.IndexOf(Members[I])>=0),'Missing exact selected fixture member');
        Books[I].Folder:='books\shared.zip'; Books[I].FileName:=ChangeFileExt(Members[I],'');
        Books[I].FileExt:=ExtractFileExt(Members[I]); Books[I].InsideNo:=I;
        Books[I].Size:=Zip.FileInfo[Zip.IndexOf(Members[I])].UncompressedSize;
        if FileExists(Settings.AppPath+'compression-refresh.marker') or
          FileExists(Settings.AppPath+'reviewed-compression.marker') then
          Books[I].LibID:='compression-refresh-'+IntToStr(I+1);
        Collection.UpdateBook(Books[I]);
        Zip.Read(Members[I],OriginalBodies[I]);
      end;
      OriginalBody:=OriginalBodies[0];
    finally Zip.Free; end;
    Require(TryStoreReaderBookProgress(Collection,Books[0],37),'Cannot seed personal progress');
    for var I:=0 to High(Books) do
    begin
      Cached:=PrepareReaderFile(Books[I],True);
      Require(CompressionBodyHash(TFile.ReadAllBytes(Cached))=CompressionBodyHash(OriginalBodies[I]),
        'Initial Reader cache has wrong book: '+Members[I]);
    end;
    if Assigned(Config) and Config.GetValue<Boolean>('repeat_offer',False) then
    begin
      Require(VarToStr(Collection.GetProperty(PROP_COMPRESSION_PREFERENCES))='',
        'Fresh offer fixture already has compression preferences');
      frmMain.QueueCollectionCompressionOffer(Collection.CollectionID);
      var InitialOffer:=frmMain.FindComponent('pnCompressionOffer') as TPanel;
      Require(not Assigned(InitialOffer) or not InitialOffer.Visible,'Fresh collection was offered another collection''s compression');
    end;
    OldSize:=TFile.GetSize(Source);
    Settings.TreeModes[PAGE_SEARCH]:=tmFlat;
    ShowPage(PAGE_SEARCH);
    frmMain.btnClearFilterEdits.Click;
    frmMain.acApplyPreset.Execute;
    var Selected:=0; Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvBooksSR.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) and
        (SelectedBookIndex(Data^.BookKey.BookID)>=0) then
      begin
        frmMain.tvBooksSR.CheckState[Node]:=csCheckedNormal;
        frmMain.tvBooksSR.FocusedNode:=Node;
        frmMain.tvBooksSR.Selected[Node]:=True; Inc(Selected);
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(Selected=Length(Books),'Select every requested visible book');
    Options:=Default(TBookCompressionOperationOptions);
    Options.Profile:=Profiles[Driver.ProfileIndex]; Options.Grayscale:=Driver.Grayscale;
    Require(Length(ResolveSelectedCompressionTools(Settings.AppPath,Options))=0,'Incomplete private compression runtime');
    Action:=frmMain.FindComponent('acCompressSelectedBooks') as TAction;
    Require(Assigned(Action),'Normal compression command is missing');
    Action.Update; Require(Action.Enabled,'Normal compression command is disabled for selected books');
    Driver.Started:=GetTickCount64;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Tick; Driver.Timer.Enabled:=True;
    if Driver.Whole then
    begin
      var Menu:=frmMain.FindComponent('miPackCollection') as TMenuItem;
      Require(Assigned(Menu),'Whole collection compression command is missing');
      Menu.Click;
    end
    else Action.Execute;
    Started:=GetTickCount64;
    while not Driver.ResultSeen and (GetTickCount64-Started<Timeout) do
    begin Application.ProcessMessages; Sleep(10); end;
    Require(Driver.OptionsSeen and Driver.ReviewSeen and Driver.ResultSeen and
      ((Mode='estimate') or Driver.ComparisonSeen) and (not Driver.EstimateFirst or Driver.EstimateSeen),
      'Normal catalogue compression did not reach options, review and result; last stage: '+Driver.LastStage);
    // Real illustrated books keep producer stages visible long enough for the
    // GUI timer. Tiny fixtures may complete between two timer ticks.
    if Members[1]='two.epub' then
      Require(((Mode='estimate') or Driver.ProducerStageSeen) and
        (not Driver.EstimateFirst or Driver.EstimateStageSeen),
        'Russian worker stages were lost or decoded incorrectly');
    var CurrentCollection:=SystemDB.GetCollection(Collection.CollectionID);
    ShowPage(PAGE_SEARCH);
    var VisibleBooks:=0;
    Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvBooksSR.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) then
      begin
        var SelectedIndex:=SelectedBookIndex(Data^.BookKey.BookID);
        if SelectedIndex>=0 then
        begin
          Inc(VisibleBooks);
          CurrentCollection.GetBookRecord(Books[SelectedIndex].BookKey,After,False);
          Require(Data^.Size=After.Size,'Visible catalogue row kept the old size: '+Members[SelectedIndex]);
        end;
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(VisibleBooks=Length(Books),'Applied search lost a selected book after compression');
    NewSize:=TFile.GetSize(Source);
    if Mode='apply' then
    begin
      Require(NewSize<OldSize,'Confirmed compression did not shrink the archive');
      for var I:=0 to High(Books) do
      begin
        CurrentCollection.GetBookRecord(Books[I].BookKey,After,False);
        Cached:=PrepareReaderFile(After,True); OutputBody:=TFile.ReadAllBytes(Cached);
        Require(CompressionBodyHash(OriginalBodies[I])<>CompressionBodyHash(OutputBody),
          'Reader reused stale original cache after image compression: '+Members[I]);
        Require((After.Size=Length(OutputBody)) and (After.Size<Books[I].Size),
          'Catalogue size was not refreshed: '+Members[I]);
      end;
      Require(Length(TDirectory.GetFiles(Driver.BackupFolder,'*.zip'))=1,'No persistent original backup');
      Zip:=TZipFile.Create;
      try
        Zip.Open(TDirectory.GetFiles(Driver.BackupFolder,'*.zip')[0],zmRead);
        for var I:=0 to High(Books) do
        begin
          Zip.Read('books/'+Members[I],OutputBody);
          Require(CompressionBodyHash(OutputBody)=CompressionBodyHash(OriginalBodies[I]),
            'Backup lost original book bytes: '+Members[I]);
        end;
      finally Zip.Free; end;
    end
    else
    begin
      Require(THashSHA2.GetHashStringFromFile(Source)=Driver.OriginalSHA,'Skip or stop changed a book');
      Require(Length(TDirectory.GetFiles(Driver.BackupFolder,'*.zip'))=0,'Skip or stop left a persistent backup');
    end;
    var Personal:TBookRecord;
    SystemDB.GetBookRecord(Books[0].BookKey,Personal);
    Require(Personal.Progress=37,'Compression lost personal reading progress');
    Registry:=TPath.Combine(Settings.DataPath,'compression-work.ini');
    Options:=Default(TBookCompressionOperationOptions);
    Require(LoadCollectionCompressionPreferences(Registry,'',CurrentCollection,Options)='',
      'Normal catalogue command did not save valid collection-specific choices');
    Require((Options.Profile=Profiles[Driver.ProfileIndex]) and (Options.Grayscale=Driver.Grayscale) and
      Options.ReviewResults and Options.BackupOriginals and (Options.BackupFolder=Driver.BackupFolder),
      'Normal catalogue command lost its own selected compression choices');
    Require(Length(TBookCompressionJob.Pending(CompressionQueueRoot(Options)))=0,'Completed GUI action left a pending job');
    if Driver.InspectWorkPicker then
    begin
      Require(Options.WorkRoot=Driver.WorkPickerExpected,'Compression ignored the folder selected through Windows');
      var SavedRegistry:=TFile.ReadAllText(Registry,TEncoding.UTF8);
      var SavedPreference:=VarToStr(CurrentCollection.GetProperty(PROP_COMPRESSION_PREFERENCES));
      var SavedSource:=THashSHA2.GetHashStringFromFile(Source);
      Driver.OptionsSeen:=False; Driver.CancelOptions:=True; Driver.Timer.Enabled:=True;
      Action.Update; Require(Action.Enabled,'Cannot reopen normal compression options'); Action.Execute;
      Driver.Timer.Enabled:=False;
      Require(Driver.OptionsSeen,'Normal menu did not reopen its saved folder');
      Require((TFile.ReadAllText(Registry,TEncoding.UTF8)=SavedRegistry) and
        (VarToStr(CurrentCollection.GetProperty(PROP_COMPRESSION_PREFERENCES))=SavedPreference),
        'Canceling the reopened options changed remembered settings');
      Require(THashSHA2.GetHashStringFromFile(Source)=SavedSource,'Reopening options changed compressed books');
      Writeln('PASS Windows folder selection drives actual compression and survives normal menu reopen without writes on cancel');
    end;
    if FileExists(Settings.AppPath+'compression-refresh.marker') then
    begin
      Require(Mode='apply','Index-refresh case requires applied compression');
      CheckCompressionSizesAfterFullInpx(CurrentCollection,Books);
    end;
    if Assigned(Config) and (Config.GetValue<Boolean>('repeat_new',False) or Config.GetValue<Boolean>('repeat_offer',False)) then
    begin
      Require(Mode='apply','Repeat-new scenario requires an initial applied compression');
      var CompressedSHA:=THashSHA2.GetHashStringFromFile(Source);
      Driver.OnlyNew:=True; Driver.Whole:=True;
      Driver.OptionsSeen:=False; Driver.ReviewSeen:=False; Driver.ResultSeen:=False;
      Driver.DecisionSent:=False; Driver.ProducerStageSeen:=False; Driver.OriginalSHA:=CompressedSHA;
      Driver.Timer.Enabled:=True; Driver.Started:=GetTickCount64;
      var Menu:=frmMain.FindComponent('miCompressNewBooks') as TMenuItem;
      Require(Assigned(Menu),'New-books compression is missing from the normal menu');
      if Config.GetValue<Boolean>('repeat_offer',False) then
      begin
        var FormsBefore:=Screen.FormCount;
        var Choice:=VarToStr(CurrentCollection.GetProperty(PROP_COMPRESSION_PREFERENCES));
        CurrentCollection.SetProperty(PROP_COMPRESSION_PREFERENCES,'broken');
        frmMain.QueueCollectionCompressionOffer(CurrentCollection.CollectionID);
        var Offer:=frmMain.FindComponent('pnCompressionOffer') as TPanel;
        Require(not Assigned(Offer) or not Offer.Visible,'Malformed compression preferences opened an offer');
        CurrentCollection.SetProperty(PROP_COMPRESSION_PREFERENCES,Choice);
        CurrentCollection.BeginBulkOperation;
        try
          frmMain.QueueCollectionCompressionOffer(CurrentCollection.CollectionID);
          Require(not Assigned(Offer) or not Offer.Visible,'Live import transaction opened an offer');
        finally CurrentCollection.EndBulkOperation(False); end;
        for var RepeatIndex:=1 to 3 do frmMain.QueueCollectionCompressionOffer(CurrentCollection.CollectionID);
        Offer:=frmMain.FindComponent('pnCompressionOffer') as TPanel;
        Require(Assigned(Offer) and Offer.Visible and frmMain.Enabled,'Committed arrivals have no nonmodal offer');
        Require(Screen.FormCount=FormsBefore,'Offer opened another window without permission');
        var Apply:=frmMain.FindComponent('btnCompressArrivals') as TButton;
        var Later:=frmMain.FindComponent('btnCompressArrivalsLater') as TButton;
        var Explanation:=frmMain.FindComponent('lblCompressionOffer') as TLabel;
        var OriginalPPI:=frmMain.CurrentPPI; var OriginalWidth:=frmMain.Width; var OriginalHeight:=frmMain.Height;
        var WasDark:=MHLThemeDark;
        try
          for var Dark in [False,True] do
          begin
            Writeln('TRACE arrival theme ms=',GetTickCount64-Driver.Started,' dark=',Dark); Flush(Output);
            SetMHLTheme(Dark); ApplyMHLControlTheme(frmMain);
            for var PPI in [96,144,192,216,288] do
            begin
              Writeln('TRACE arrival scale begin ms=',GetTickCount64-Driver.Started,' ppi=',PPI); Flush(Output);
              frmMain.ScaleForPPI(PPI); frmMain.ClientWidth:=MulDiv(720,PPI,96);
              Writeln('TRACE arrival scale end ms=',GetTickCount64-Driver.Started,' ppi=',PPI); Flush(Output);
              Require((Apply.Left>=Explanation.BoundsRect.Right) and (Later.Left>=Apply.BoundsRect.Right) and
                (Later.BoundsRect.Right<=Offer.ClientWidth) and (Apply.BoundsRect.Bottom<=Offer.ClientHeight),
                'Arrival offer controls overlap or clip at '+IntToStr(PPI)+' DPI');
              var TextBounds:=Rect(0,0,Explanation.Width,0); Explanation.Canvas.Font.Assign(Explanation.Font);
              DrawText(Explanation.Canvas.Handle,PChar(Explanation.Caption),-1,TextBounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
              Require(TextBounds.Height<=Explanation.Height,'Arrival offer explanation clipped');
              Require(Explanation.Font.Color=MHLThemeText,'Arrival offer did not follow the catalogue theme');
            end;
          end;
        finally
          frmMain.ScaleForPPI(OriginalPPI); frmMain.Width:=OriginalWidth; frmMain.Height:=OriginalHeight;
          SetMHLTheme(WasDark); ApplyMHLControlTheme(frmMain); frmMain.RefreshCollectionCompressionOffer;
        end;
        Later.Click; frmMain.RefreshCollectionCompressionOffer;
        Require(not Offer.Visible,'Later reopened an unsolicited compression offer');
        Require(THashSHA2.GetHashStringFromFile(Source)=CompressedSHA,'Later changed books');
        frmMain.QueueCollectionCompressionOffer(CurrentCollection.CollectionID);
        Driver.CancelOptions:=True; Apply.Click;
        Require(Driver.OptionsSeen and Offer.Visible and not Driver.ProducerStageSeen,'Canceling options started work or lost the offer');
        Require(THashSHA2.GetHashStringFromFile(Source)=CompressedSHA,'Canceling arrival options changed books');
        Driver.CancelOptions:=False; Driver.OptionsSeen:=False; Driver.Started:=GetTickCount64;
        Apply.Click;
        Require(not Offer.Visible,'Accepted compression offer stayed visible');
      end
      else Menu.Click;
      Started:=GetTickCount64;
      while not Driver.ResultSeen and (GetTickCount64-Started<Timeout) do
      begin Application.ProcessMessages; Sleep(10); end;
      Require(Driver.OptionsSeen and Driver.ResultSeen and not Driver.ReviewSeen and not Driver.ProducerStageSeen,
        'No-arrivals menu command repeated preparation or failed to finish; last stage: '+Driver.LastStage);
      Require(THashSHA2.GetHashStringFromFile(Source)=CompressedSHA,'No-arrivals command changed compressed books');
      Require(Length(TDirectory.GetFiles(Driver.BackupFolder,'*.zip'))=1,'No-arrivals command added an unnecessary backup');
      SystemDB.GetBookRecord(Books[0].BookKey,Personal);
      Require(Personal.Progress=37,'No-arrivals command changed personal progress');
      Writeln('PASS normal new-books menu preserved the compressed archive and did not run the producer');
    end;
    if FileExists(Settings.AppPath+'compression-refresh.marker') or
      FileExists(Settings.AppPath+'reviewed-compression.marker') then
      TestReviewedCompressedCatalogue(CurrentCollection,Books,OriginalBody,Options);
    if FileExists(Settings.AppPath+'bound-compression.marker') then
      TestReviewedBoundCompression(Books,Driver.BackupFolder,Options);
    if FileExists(Settings.AppPath+'compression-refresh-cancel.marker') then
      TestCancelledCompressionRefresh(CurrentCollection,Books);
    Writeln('PASS selected compression normal catalogue ',Mode,' preserves neighbors, personal progress, originals and refreshed Reader cache');
  finally Config.Free; Driver.Timer.Free; Driver.Free; end;
end;

{$I CompressionRefreshTests.inc}
