// Exercises the real menu action, modal choices, background timer and visible
// row refresh in the normal catalogue. All files belong to the guarded runtime.
type
  TCompressionCatalogueDriver = class
    Timer: TTimer;
    Mode, OriginalSHA, Source, BackupFolder: string;
    OptionsSeen, ReviewSeen, ResultSeen, DecisionSent: Boolean;
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
    if (Screen.Forms[I] is TfrmBookCompressionOptions) and Screen.Forms[I].Visible then
    begin
      var Form:=TfrmBookCompressionOptions(Screen.Forms[I]);
      if OptionsSeen then Exit;
      OptionsSeen:=True;
      TComboBox(Form.FindComponent('CompressionProfile')).ItemIndex:=2;
      TCheckBox(Form.FindComponent('CompressionGrayscale')).Checked:=True;
      TCheckBox(Form.FindComponent('CompressionReview')).Checked:=True;
      TEdit(Form.FindComponent('CompressionWorkFolder')).Text:=Settings.AppPath+'compression-work';
      TCheckBox(Form.FindComponent('CompressionBackup')).Checked:=True;
      TEdit(Form.FindComponent('CompressionBackupFolder')).Text:=BackupFolder;
      TButton(Form.FindComponent('CompressionStart')).Click;
      Exit;
    end;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionProgress) and Screen.Forms[I].Visible then
    begin
      var Form:=TfrmBookCompressionProgress(Screen.Forms[I]);
      if TButton(Form.FindComponent('CompressionApply')).Visible and not DecisionSent then
      begin
        // Browsing pumps VCL messages. Mark this decision before that pump so
        // the driver's own timer cannot enter the same review a second time.
        DecisionSent:=True;
        ReviewSeen:=True;
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
        if Mode='skip' then TButton(Form.FindComponent('CompressionSkip')).Click
        else if Mode='stop' then TButton(Form.FindComponent('CompressionStop')).Click
        else TButton(Form.FindComponent('CompressionApply')).Click;
      end;
      if TButton(Form.FindComponent('CompressionStop')).Caption='Закрыть' then
      begin
        ResultSeen:=True; Timer.Enabled:=False;
        var Note:string:=TLabel(Form.FindComponent('CompressionNote')).Caption;
        Require(not Note.Contains('Не удалось') and not Note.Contains('исходник'),
          'Compression result error: '+Note);
        TButton(Form.FindComponent('CompressionStop')).Click;
      end;
    end;
end;

procedure TestSelectedCompressionCatalogue(const Collection: IBookCollection;
  FirstID, SecondID: Integer);
var Driver:TCompressionCatalogueDriver; After:TBookRecord;
    OldSize, NewSize:Int64; Data:PBookRecord; Node:PVirtualNode;
    Action:TAction; Source, Cached, Mode, Registry:string;
    Options:TBookCompressionOperationOptions; Zip:TZipFile;
    Books:TArray<TBookRecord>; OriginalBody, OutputBody:TBytes; Started:UInt64;
begin
  Mode:=ParamStr(2);
  Require(MatchText(Mode,['apply','skip','stop']),'Expected apply, skip or stop');
  Source:=Settings.AppPath+'books\shared.zip';
  Require(FileExists(Source),'Missing isolated book archive');
  Driver:=TCompressionCatalogueDriver.Create;
  try
    Driver.Mode:=Mode; Driver.Source:=Source;
    Driver.OriginalSHA:=THashSHA2.GetHashStringFromFile(Source);
    Driver.BackupFolder:=Settings.AppPath+'originals'; ForceDirectories(Driver.BackupFolder);
    SetLength(Books,2); Zip:=TZipFile.Create;
    try
      Zip.Open(Source,zmRead);
      for var I:=0 to 1 do
      begin
        var ID:=FirstID; if I=1 then ID:=SecondID;
        Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Books[I],True);
        Books[I].Folder:='books\shared.zip'; Books[I].FileName:='one';
        if I=1 then Books[I].FileName:='two';
        Books[I].FileExt:='.fb2'; Books[I].InsideNo:=I;
        Books[I].Size:=Zip.FileInfo[Zip.IndexOf(Books[I].FileName+'.fb2')].UncompressedSize;
        Collection.UpdateBook(Books[I]);
      end;
      Zip.Read('one.fb2',OriginalBody);
    finally Zip.Free; end;
    Require(TryStoreReaderBookProgress(Collection,Books[0],37),'Cannot seed personal progress');
    Cached:=PrepareReaderFile(Books[0],True);
    Require(CompressionBodyHash(TFile.ReadAllBytes(Cached))=CompressionBodyHash(OriginalBody),
      'Initial Reader cache has wrong book');
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
        ((Data^.BookKey.BookID=FirstID) or (Data^.BookKey.BookID=SecondID)) then
      begin
        frmMain.tvBooksSR.CheckState[Node]:=csCheckedNormal;
        frmMain.tvBooksSR.FocusedNode:=Node;
        frmMain.tvBooksSR.Selected[Node]:=True; Inc(Selected);
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(Selected=2,'Select exactly two visible books');
    Options:=Default(TBookCompressionOperationOptions);
    Options.Profile:='economy'; Options.Grayscale:=True;
    Require(Length(ResolveSelectedCompressionTools(Settings.AppPath,Options))=0,'Incomplete private compression runtime');
    Action:=frmMain.FindComponent('acCompressSelectedBooks') as TAction;
    Require(Assigned(Action),'Normal compression command is missing');
    Action.Update; Require(Action.Enabled,'Normal compression command is disabled for selected books');
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Tick; Driver.Timer.Enabled:=True;
    Action.Execute;
    Started:=GetTickCount64;
    while not Driver.ResultSeen and (GetTickCount64-Started<45000) do
    begin Application.ProcessMessages; Sleep(10); end;
    Require(Driver.OptionsSeen and Driver.ReviewSeen and Driver.ResultSeen,
      'Normal catalogue compression did not reach options, review and result');
    var CurrentCollection:=SystemDB.GetCollection(Collection.CollectionID);
    CurrentCollection.GetBookRecord(Books[0].BookKey,After,False);
    ShowPage(PAGE_SEARCH);
    var VisibleBook:=False;
    Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvBooksSR.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) and
        (Data^.BookKey.BookID=FirstID) then
      begin
        VisibleBook:=True;
        Require(Data^.Size=After.Size,'Visible catalogue row kept the old size');
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(VisibleBook,'Applied search was lost after compression');
    NewSize:=TFile.GetSize(Source);
    if Mode='apply' then
    begin
      Require(NewSize<OldSize,'Confirmed compression did not shrink the archive');
      Cached:=PrepareReaderFile(After,True); OutputBody:=TFile.ReadAllBytes(Cached);
      Require(CompressionBodyHash(OriginalBody)<>CompressionBodyHash(OutputBody),
        'Reader reused stale original cache after image compression');
      Require(After.Size=Length(OutputBody),'Catalogue size was not refreshed');
      Require(Length(TDirectory.GetFiles(Driver.BackupFolder,'*.zip'))=1,'No persistent original backup');
      Zip:=TZipFile.Create;
      try
        Zip.Open(TDirectory.GetFiles(Driver.BackupFolder,'*.zip')[0],zmRead);
        Zip.Read('books/one.fb2',OutputBody);
        Require(CompressionBodyHash(OutputBody)=CompressionBodyHash(OriginalBody),'Backup lost original book bytes');
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
    LoadCompressionPreferences(Registry,'',Options);
    Require(Length(TBookCompressionJob.Pending(CompressionQueueRoot(Options)))=0,'Completed GUI action left a pending job');
    Writeln('PASS selected compression normal catalogue ',Mode,' preserves neighbors, personal progress, originals and refreshed Reader cache');
  finally Driver.Timer.Free; Driver.Free; end;
end;
