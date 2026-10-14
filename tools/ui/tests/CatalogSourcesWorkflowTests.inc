// Native pre5.19 workflow gate. Only private G catalog previews; no merge Apply.
type
  TCatalogWorkflowMutation = class
    Policy: TComboBox;
    Previous: TNotifyEvent;
    Pending, Changed: Boolean;
    procedure ModalBegin(Sender: TObject);
  end;

procedure TCatalogWorkflowMutation.ModalBegin(Sender: TObject);
begin
  if Assigned(Previous) then Previous(Sender);
  if Pending then
  begin
    Pending:=False; Policy.ItemIndex:=2;
    if Assigned(Policy.OnChange) then Policy.OnChange(Policy);
    Changed:=True;
  end;
end;

procedure TestCatalogSourcesWorkflow;
var Root: string; Target, SourceOne, SourceTwo: IBookCollection;
  TargetID, SourceIDOne, SourceIDTwo, BookID: Integer; Sources: TCatalogSources; Book: TBookRecord;
  Dialog: TfrmCatalogSources; Review: TfrmSeriesAliasReview;
  Policy, LibraryChoice: TComboBox; CheckButton, ApplyButton, SeriesButton: TButton;
  StateLabel, DetailsLabel, ScopeLabel: TLabel; Driver: TCatalogWorkflowMutation;
  TargetDB, OneDB, TwoDB: TSQLiteDatabase; BeforeTarget, BeforeOne, BeforeTwo, SettingsHash: string;

  function Component(const Name: string): TComponent;
  begin
    Result:=Dialog.FindComponent(Name);
    Require(Assigned(Result),'Catalog sources workflow control missing: '+Name);
  end;

  procedure Snapshot;
  begin
    BeforeTarget:=ReaderAllCatalogRows(TargetDB);
    BeforeOne:=ReaderAllCatalogRows(OneDB); BeforeTwo:=ReaderAllCatalogRows(TwoDB);
  end;

  procedure Untouched(const Context: string);
  begin
    Require((ReaderAllCatalogRows(TargetDB)=BeforeTarget) and
      (ReaderAllCatalogRows(OneDB)=BeforeOne) and (ReaderAllCatalogRows(TwoDB)=BeforeTwo),
      Context+': preview/workflow changed protected target/source rows or schema');
    if SettingsHash<>'' then Require(THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=SettingsHash,
      Context+': workflow changed the active settings/profile');
    Require(not Target.InBulkOperation,Context+': preview left a target transaction open');
  end;

  procedure Ready(const Context: string);
  begin
    CheckButton.OnClick(CheckButton);
    Require(ApplyButton.Enabled and not CheckButton.Default and ApplyButton.Default,
      Context+': successful current preview did not enable exactly the add step');
    Require(string(StateLabel.Caption).Contains('Можно добавить') and
      string(DetailsLabel.Caption).Contains('Все источники проверены: 2'),Context+': ready summary is not visible');
  end;

begin
  RequireIsolatedRegression;
  Require(TPath.GetFullPath(Settings.AppPath).StartsWith('G:\',True),'Source workflow gate must stay in private G');
  Root:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'catalog-workflow-'+TGUID.NewGuid.ToString));
  ForceDirectories(Root); SettingsHash:='';
  if FileExists(Settings.SettingsFileName) then SettingsHash:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
  TargetID:=SystemDB.CreateCollection('Workflow target',Root,TPath.Combine(Root,'target.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  SourceIDOne:=SystemDB.CreateCollection('Workflow source one',Root,TPath.Combine(Root,'one.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  SourceIDTwo:=SystemDB.CreateCollection('Workflow source two',Root,TPath.Combine(Root,'two.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Target:=SystemDB.GetCollection(TargetID); SourceOne:=SystemDB.GetCollection(SourceIDOne); SourceTwo:=SystemDB.GetCollection(SourceIDTwo);
  Target.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
  SourceOne.SetProperty(PROP_SOURCE_LIBRARY,'flibusta'); SourceTwo.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
  BookID:=AddBook(SourceOne,'Workflow original one','Автор ё','ru','Серия','prose_contemporary');
  SourceOne.GetBookRecord(CreateBookKey(BookID,SourceIDOne),Book,True);
  Book.LibID:='flibusta:101'; SourceOne.UpdateBook(Book);
  BookID:=AddBook(SourceTwo,'Workflow original two','Автор ї','uk','Серия','prose_contemporary');
  SourceTwo.GetBookRecord(CreateBookKey(BookID,SourceIDTwo),Book,True);
  Book.LibID:='flibusta:102'; SourceTwo.UpdateBook(Book);
  SetLength(Sources,2);
  Sources[0].ID:=TCatalogSource.NewID; Sources[0].Name:='Workflow source one'; Sources[0].Root:=Root;
  Sources[0].CollectionID:=SourceIDOne; Sources[0].CollectionFile:=SystemDB.GetCollectionInfo(SourceIDOne).DBFileName;
  Sources[0].LibraryNamespace:='flibusta';
  Sources[1].ID:=TCatalogSource.NewID; Sources[1].Name:='Workflow source two'; Sources[1].Root:=Root;
  Sources[1].CollectionID:=SourceIDTwo; Sources[1].CollectionFile:=SystemDB.GetCollectionInfo(SourceIDTwo).DBFileName;
  Sources[1].LibraryNamespace:='flibusta'; SaveCatalogSources(Target,Sources);
  TargetDB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(TargetID).DBFileName);
  OneDB:=TSQLiteDatabase.Create(Sources[0].CollectionFile); TwoDB:=TSQLiteDatabase.Create(Sources[1].CollectionFile);
  Dialog:=nil; Driver:=nil;
  try
    Dialog:=TfrmCatalogSources.CreateForCollection(frmMain,Target);
    Policy:=TComboBox(Component('cbMergeDuplicatePolicy')); LibraryChoice:=TComboBox(Component('cbMergeLibrary'));
    CheckButton:=TButton(Component('btnCheckSources')); ApplyButton:=TButton(Component('btnApplySources'));
    SeriesButton:=TButton(Component('btnSeriesNames'));
    StateLabel:=TLabel(Component('lblSourceWorkflowState')); DetailsLabel:=TLabel(Component('lblSourceWorkflowDetails'));
    ScopeLabel:=TLabel(Component('lblSeriesNamesScope'));
    Require((CheckButton.Parent=ApplyButton.Parent) and (CheckButton.Top=ApplyButton.Top) and
      (CheckButton.Left+CheckButton.Width<ApplyButton.Left),'Check and add steps are not adjacent or overlap');
    Require(not ApplyButton.Enabled and CheckButton.Enabled and CheckButton.Default,
      'Initial workflow offers adding before checking or hides the next step');
    Require(string(ScopeLabel.Caption).Contains('уже добавленных') and
      SeriesButton.Hint.Contains('не импортирует'),'Series action does not explain its existing-collection-only scope');
    Snapshot; Ready('Initial all-source preview'); Untouched('Initial all-source preview');

    Policy.ItemIndex:=1; Policy.OnChange(Policy);
    Require(not ApplyButton.Enabled and CheckButton.Enabled and CheckButton.Default,
      'Changing duplicate mode retained stale Apply or made rechecking unavailable');
    Require(string(DetailsLabel.Caption).Contains('Изменён режим повторных книг') and
      string(DetailsLabel.Caption).Contains('Проверить все источники'),'Invalidation omits the reason or concrete next step');
    Require((LibraryChoice.ItemIndex=1) and (VarToStr(Target.GetProperty(PROP_SOURCE_LIBRARY))='flibusta'),
      'Duplicate mode unexpectedly changed the target library choice');
    ApplyButton.OnClick(ApplyButton); Untouched('Disabled/stale Apply handler');
    Ready('Changed duplicate mode recheck'); Untouched('Changed duplicate mode recheck');
    Writeln('PASS catalog source mode changes show why Apply is disabled and keep one adjacent available recheck step without writes'); Flush(Output);

    LibraryChoice.ItemIndex:=0; LibraryChoice.OnChange(LibraryChoice);
    Require(not ApplyButton.Enabled and string(DetailsLabel.Caption).Contains('библиотека номеров'),
      'Target per-book library change retained the old preview or omitted its cause');
    Require(VarToStr(Target.GetProperty(PROP_SOURCE_LIBRARY))='', 'Per-book library selection was not retained');
    Snapshot; Ready('Per-book target namespace recheck'); Untouched('Per-book target namespace recheck');

    Driver:=TCatalogWorkflowMutation.Create; Driver.Policy:=Policy; Driver.Previous:=Application.OnModalBegin; Driver.Pending:=True;
    Application.OnModalBegin:=Driver.ModalBegin;
    try CheckButton.OnClick(CheckButton);
    finally Application.OnModalBegin:=Driver.Previous; end;
    Require(Driver.Changed,'During-preview revision regression did not mutate the real policy callback');
    Require(not ApplyButton.Enabled and CheckButton.Enabled and CheckButton.Default and
      string(DetailsLabel.Caption).Contains('во время проверки'),
      'A finished old-policy worker re-enabled stale Apply after callback invalidation');
    Untouched('During-preview policy mutation'); Ready('Fresh preview after interleaved change'); Untouched('Fresh preview after interleaved change');
    Writeln('PASS target namespace changes and interleaved worker policy changes invalidate old previews; fresh recheck restores the next step'); Flush(Output);

    Review:=TfrmSeriesAliasReview.CreateFor(Dialog);
    try Review.PreviewAliases(nil);
      Require(not FeedbackButton(Review,'Объединить').Enabled,'Empty target series review offers a write');
      Require(ApplyButton.Enabled,'Read-only series review invalidates the independent source preview');
    finally Review.Free; end; Untouched('Existing target-only series review');
    CheckSourceDialogLayout(Dialog);
    Dialog.Height:=Dialog.Constraints.MinHeight; Application.ProcessMessages;
    Require((CheckButton.Top+CheckButton.Height<=CheckButton.Parent.ClientHeight) and
      (ApplyButton.Top+ApplyButton.Height<=ApplyButton.Parent.ClientHeight) and
      (ScopeLabel.Top+ScopeLabel.Height<=ScopeLabel.Parent.ClientHeight),
      'Persistent workflow or series scope goes outside the short-window footer');
    Writeln('PASS target-only series scope stays separate from source imports; state/check/add controls fit native DPI and short-window footer'); Flush(Output);
  finally
    Driver.Free; Dialog.Free; TwoDB.Free; OneDB.Free; TargetDB.Free;
    SourceTwo:=nil; SourceOne:=nil; Target:=nil;
  end;
end;
