// Real private collection databases, including reopen and the full index-import
// table reset. No compression worker or source book is needed for this layer.
procedure TestCompressionPreferences(const One, Two: IBookCollection);
var Registry, Original, Warning, Root, BeforeRegistry: string;
    Choice, Other, Loaded: TBookCompressionOperationOptions;
    Reopened: IBookCollection; Rejected: Boolean; Previous: Integer;
    Dialog: TfrmBookCompressionOptions; LabelControl: TLabel;
begin
  Root:=TPath.Combine(Settings.AppPath,'preference-fixture');
  Registry:=TPath.Combine(Root,'compression-work.ini');
  ForceDirectories(Root);
  Choice:=Default(TBookCompressionOperationOptions);
  LoadCompressionPreferences(Registry,TPath.Combine(Root,'old-work'),Choice);
  Choice.Profile:='maximum'; Choice.Grayscale:=True; Choice.ReviewResults:=False;
  Choice.BackupOriginals:=True; Choice.BackupFolder:=TPath.Combine(Root,'originals');
  RememberCompressionWork(Registry,Choice);
  Warning:=LoadCollectionCompressionPreferences(Registry,TPath.Combine(Root,'one-work'),One,Loaded);
  Require((Warning='') and (Loaded.Profile='balanced') and not Loaded.Grayscale and
    Loaded.ReviewResults and not Loaded.BackupOriginals and (Loaded.BackupFolder=''),
    'New collection inherited another collection''s lossy/grayscale/backup preference');
  Require(Loaded.QueueName=Choice.QueueName,'Collection choice replaced the application recovery identity');
  Require(VarIsEmpty(One.GetProperty(PROP_COMPRESSION_PREFERENCES)),
    'Reading choices created a collection preference without confirmation');

  Choice:=Loaded; Choice.Profile:='economy'; Choice.Grayscale:=True;
  Choice.ReviewResults:=False; Choice.BackupOriginals:=True;
  Choice.BackupFolder:=TPath.Combine(Root,'one-originals');
  Choice.WorkRoot:=TPath.Combine(Root,'one-work'); Choice.EstimateFirst:=True;
  Choice.Python:='not-a-persisted-tool'; Choice.Script:='not-a-persisted-script';
  RememberCollectionCompressionWork(Registry,One,Choice);
  Original:=VarToStr(One.GetProperty(PROP_COMPRESSION_PREFERENCES));
  Require((Original<>'') and not Original.Contains('not-a-persisted') and
    not Original.Contains('estimate') and not Original.Contains(Choice.QueueName),
    'Collection preference persisted commands, an automatic start or a foreign queue');
  Warning:=LoadCollectionCompressionPreferences(Registry,TPath.Combine(Root,'two-work'),Two,Other);
  Require((Warning='') and (Other.Profile='balanced') and not Other.Grayscale and
    Other.ReviewResults and not Other.BackupOriginals,'Unsaved second collection inherited first choices');
  Other.Profile:='original'; Other.WorkRoot:=TPath.Combine(Root,'two-work');
  RememberCollectionCompressionWork(Registry,Two,Other);
  Warning:=LoadCollectionCompressionPreferences(Registry,'',One,Loaded);
  Require((Warning='') and (Loaded.Profile='economy') and Loaded.Grayscale and not Loaded.ReviewResults and
    Loaded.BackupOriginals and (Loaded.BackupFolder=Choice.BackupFolder) and
    (Loaded.WorkRoot=Choice.WorkRoot) and not Loaded.EstimateFirst,
    'Second collection overwrote the first collection''s choices');
  Require((Loaded.QueueName=Other.QueueName) and (Length(CompressionWorkRoots(Registry))=3),
    'Per-collection choices lost shared recovery roots');

  Reopened:=SystemDB.GetCollection(One.CollectionID,True);
  Reopened.SetProperty(PROP_DISPLAYNAME,'Renamed private preference fixture');
  Reopened.SetProperty(PROP_ROOTFOLDER,TPath.Combine(Root,'relocated-books'));
  Warning:=LoadCollectionCompressionPreferences(Registry,'',Reopened,Loaded);
  Require((Warning='') and (Loaded.Profile='economy') and Loaded.Grayscale and
    (VarToStr(Reopened.GetProperty(PROP_COMPRESSION_PREFERENCES))=Original),
    'Reopen, collection rename or root relocation lost its own choice');
  Require(not DirectoryExists(Choice.WorkRoot) and not DirectoryExists(Choice.BackupFolder),
    'Remembering preferences created source or backup payload folders');

  // The actual full INPX reimport resets book tables. It must retain Settings.
  Two.BeginBulkOperation;
  try
    Previous:=Two.StartCatalogUpdateTracking(True);
    Two.TruncateTablesBeforeImport;
    Two.FinishCatalogUpdateTracking(True,Previous);
  except Two.EndBulkOperation(False); raise; end;
  Two.EndBulkOperation;
  Reopened:=SystemDB.GetCollection(Two.CollectionID,True);
  Warning:=LoadCollectionCompressionPreferences(Registry,'',Reopened,Loaded);
  Require((Warning='') and (Loaded.Profile='original') and not Loaded.Grayscale and
    (Loaded.WorkRoot=Other.WorkRoot),'Index reimport reset retained compression settings');

  BeforeRegistry:=TFile.ReadAllText(Registry,TEncoding.UTF8);
  Reopened.BeginBulkOperation;
  try
    Rejected:=False;
    try RememberCollectionCompressionWork(Registry,Reopened,Choice);
    except on E:EInvalidOperation do Rejected:=True; end;
    Require(Rejected,'Preferences entered a live import transaction');
  finally Reopened.EndBulkOperation(False); end;
  Require(TFile.ReadAllText(Registry,TEncoding.UTF8)=BeforeRegistry,
    'Rejected concurrent import changed the recovery registry');

  for var Invalid in TArray<string>.Create('broken', '[]', '{"version":2}',
    '{"version":"1"}', Original.Replace('"grayscale":true','"grayscale":"false"'),
    Original.Replace('"economy"','"unknown"'), Original.Replace(Choice.WorkRoot.Replace('\','\\'),'relative-work')) do
  begin
    Require(Invalid<>Original,'Malformed fixture did not change the preference');
    One.SetProperty(PROP_COMPRESSION_PREFERENCES,Invalid);
    Warning:=LoadCollectionCompressionPreferences(Registry,'',One,Loaded);
    Require((Warning<>'') and (Loaded.Profile='balanced') and not Loaded.Grayscale and
      Loaded.ReviewResults and not Loaded.BackupOriginals,
      'Damaged preference did not return an explicit warning and safe dialog choices');
  end;
  One.SetProperty(PROP_COMPRESSION_PREFERENCES,Original);
  Choice.Profile:='unknown'; Rejected:=False;
  try RememberCollectionCompressionWork(Registry,One,Choice);
  except on E:EArgumentException do Rejected:=True; end;
  Require(Rejected and (VarToStr(One.GetProperty(PROP_COMPRESSION_PREFERENCES))=Original),
    'Rejected choice destroyed an existing collection preference');
  Require(TFile.ReadAllText(Registry,TEncoding.UTF8)=BeforeRegistry,
    'Invalid choices changed the recovery registry');
  for var PPI in [96,144,192,288] do
  begin
    Dialog:=TfrmBookCompressionOptions.CreateOptions(nil,0,Loaded);
    try
      Dialog.HandleNeeded; Dialog.ScaleForPPI(PPI);
      LabelControl:=TLabel(Dialog.FindComponent('CompressionProfileLabel'));
      Dialog.Canvas.Font:=LabelControl.Font;
      Require(Dialog.Canvas.TextWidth(LabelControl.Caption)<=LabelControl.Width,
        'Per-collection explanation clipped at '+IntToStr(PPI)+' DPI');
    finally Dialog.Free; end;
  end;
  Writeln('PASS compression preferences: independent collections, explicit consent, reopen, rename, relocation, full import reset, recovery roots, malformed data and rejected writes');
end;
