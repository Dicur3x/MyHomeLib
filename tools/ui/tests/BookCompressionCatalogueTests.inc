// Exercises the real menu action, modal choices, background timer and visible
// row refresh in the normal catalogue. All files belong to the guarded runtime.
type
  TCompressionCatalogueDriver = class
    Timer: TTimer;
    Mode, OriginalSHA, Source, BackupFolder: string;
    ProfileIndex: Integer;
    Grayscale: Boolean;
    InspectComparison, EstimateFirst, EstimateSeen: Boolean;
    InspectionDeadline: UInt64;
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
      if OptionsSeen then Exit;
      OptionsSeen:=True;
      TComboBox(Form.FindComponent('CompressionProfile')).ItemIndex:=ProfileIndex;
      TCheckBox(Form.FindComponent('CompressionGrayscale')).Checked:=Grayscale;
      TCheckBox(Form.FindComponent('CompressionReview')).Checked:=True;
      TEdit(Form.FindComponent('CompressionWorkFolder')).Text:=Settings.AppPath+'compression-work';
      TCheckBox(Form.FindComponent('CompressionBackup')).Checked:=True;
      TEdit(Form.FindComponent('CompressionBackupFolder')).Text:=BackupFolder;
      if EstimateFirst then TButton(Form.FindComponent('CompressionEstimate')).Click
      else TButton(Form.FindComponent('CompressionStart')).Click;
      Exit;
    end;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionProgress) and Screen.Forms[I].Visible then
    begin
      var Form:=TfrmBookCompressionProgress(Screen.Forms[I]);
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
        Writeln('TRACE compression result ',TLabel(Form.FindComponent('CompressionStage')).Caption,' · ',Note); Flush(Output);
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
    Books:TArray<TBookRecord>; OriginalBody, OutputBody:TBytes; Started, Timeout:UInt64;
    Members:TArray<string>; Config:TJSONObject;
begin
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
      Driver.Grayscale:=Config.GetValue<Boolean>('grayscale',True);
      Driver.InspectComparison:=Config.GetValue<Boolean>('inspect_comparison',False);
      Driver.EstimateFirst:=Config.GetValue<Boolean>('estimate_first',False);
      Timeout:=Config.GetValue<UInt64>('timeout_ms',45000);
      Require((Timeout>=1000) and (Timeout<=300000),'Invalid bounded fixture timeout');
    end;
    Driver.Mode:=Mode; Driver.Source:=Source;
    if Mode='estimate' then Driver.EstimateFirst:=True;
    Driver.OriginalSHA:=THashSHA2.GetHashStringFromFile(Source);
    Driver.BackupFolder:=Settings.AppPath+'originals'; ForceDirectories(Driver.BackupFolder);
    SetLength(Books,2); Zip:=TZipFile.Create;
    try
      Zip.Open(Source,zmRead);
      for var I:=0 to 1 do
      begin
        var ID:=FirstID; if I=1 then ID:=SecondID;
        Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Books[I],True);
        Require((ExtractFileName(Members[I])=Members[I]) and (Zip.IndexOf(Members[I])>=0),'Missing exact selected fixture member');
        Books[I].Folder:='books\shared.zip'; Books[I].FileName:=ChangeFileExt(Members[I],'');
        Books[I].FileExt:=ExtractFileExt(Members[I]); Books[I].InsideNo:=I;
        Books[I].Size:=Zip.FileInfo[Zip.IndexOf(Members[I])].UncompressedSize;
        Collection.UpdateBook(Books[I]);
      end;
      Zip.Read(Members[0],OriginalBody);
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
    Options.Profile:='economy'; Options.Grayscale:=Driver.Grayscale;
    Require(Length(ResolveSelectedCompressionTools(Settings.AppPath,Options))=0,'Incomplete private compression runtime');
    Action:=frmMain.FindComponent('acCompressSelectedBooks') as TAction;
    Require(Assigned(Action),'Normal compression command is missing');
    Action.Update; Require(Action.Enabled,'Normal compression command is disabled for selected books');
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Tick; Driver.Timer.Enabled:=True;
    Action.Execute;
    Started:=GetTickCount64;
    while not Driver.ResultSeen and (GetTickCount64-Started<Timeout) do
    begin Application.ProcessMessages; Sleep(10); end;
    Require(Driver.OptionsSeen and Driver.ReviewSeen and Driver.ResultSeen and
      ((Mode='estimate') or Driver.ComparisonSeen) and (not Driver.EstimateFirst or Driver.EstimateSeen),
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
        Zip.Read('books/'+Members[0],OutputBody);
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
  finally Config.Free; Driver.Timer.Free; Driver.Free; end;
end;
