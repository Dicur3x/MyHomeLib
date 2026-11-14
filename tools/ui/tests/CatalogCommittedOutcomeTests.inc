procedure TestCatalogCommittedOutcome;
{$IFDEF MHL_COMPRESSION_TEST}
var Root, ArchivePath, ArchiveHash, Phase, Report: string;
  Target, Source: IBookCollection; Sources: TCatalogSources;
  TargetID, SourceID, Count: Integer; Book: TBookRecord; Books: IBookIterator;
  Dialog: TfrmCatalogSources; Committed, Seen: Boolean;
begin
  RequireIsolatedRegression;
  for Phase in TArray<string>.Create('normal','before-commit','catalogue-committed','stores-committed') do
  begin
    Root:=TPath.Combine(Settings.AppPath,'merge-outcome-'+Phase); ForceDirectories(Root);
    ArchivePath:=TPath.Combine(Root,'books.zip');
    var Zip:=TZipFile.Create;
    try
      Zip.Open(ArchivePath,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>Keep source</p></section></body></FictionBook>'),'531.fb2');
    finally Zip.Free; end;
    ArchiveHash:=THashSHA2.GetHashStringFromFile(ArchivePath);
    TargetID:=SystemDB.CreateCollection('Outcome target '+Phase,Root,TPath.Combine(Root,'target.hlc2'),
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    SourceID:=SystemDB.CreateCollection('Outcome source '+Phase,Root,TPath.Combine(Root,'source.hlc2'),
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    Target:=SystemDB.GetCollection(TargetID); Source:=SystemDB.GetCollection(SourceID);
    Target.SetProperty(PROP_SOURCE_LIBRARY,'flibusta'); Source.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
    Book:=Default(TBookRecord); Book.LibID:='531'; Book.FileName:='531'; Book.FileExt:='.fb2';
    Book.Folder:='books.zip'; Book.Title:='Outcome preserved book'; Book.Size:=100; Book.Lang:='ru';
    Source.InsertBook(Book,False,False);
    SetLength(Sources,1); Sources[0]:=Default(TCatalogSource);
    Sources[0].ID:=TCatalogSource.NewID; Sources[0].Name:='Outcome source'; Sources[0].Root:=Root;
    Sources[0].CollectionID:=SourceID; Sources[0].CollectionFile:=SystemDB.GetCollectionInfo(SourceID).DBFileName;
    Sources[0].LibraryNamespace:='flibusta'; SaveCatalogSources(Target,Sources);
    Dialog:=TfrmCatalogSources.CreateForCollection(frmMain,Target); Seen:=False;
    try
      Dialog.Show; Application.ProcessMessages;
      TButton(Dialog.FindComponent('btnCheckSources')).Click;
      Require(TButton(Dialog.FindComponent('btnApplySources')).Enabled,'Outcome fixture did not prepare the actual merge');
      MergeApplyTestPoint:=procedure(Stage:string) begin
        if (Phase<>'normal') and (Stage=Phase) then
        begin Seen:=True; raise EWriteError.Create('outcome-error-'+Phase); end;
      end;
      try TButton(Dialog.FindComponent('btnApplySources')).Click;
      finally MergeApplyTestPoint:=nil; end;
      Committed:=(Phase='normal') or (Phase='stores-committed');
      Require((Seen=(Phase<>'normal')) and (Dialog.CatalogChanged=Committed),
        'Source dialog lost the durable outcome at '+Phase);
      Report:=TMemo(Dialog.FindComponent('mmSourcesReport')).Lines.Text;
      if Phase='stores-committed' then
      begin
        Require(string(TLabel(Dialog.FindComponent('lblSourceWorkflowState')).Caption).Contains('требуется внимание') and
          string(TLabel(Dialog.FindComponent('lblSourceWorkflowDetails')).Caption).Contains('Каталог уже изменён') and
          Report.Contains('outcome-error-'+Phase),'Saved merge error is reported as an unchanged catalogue');
      end
      else if Phase<>'normal' then Require(Report.Contains('outcome-error-'+Phase),'Merge rollback error was hidden');
      Require(not TButton(Dialog.FindComponent('btnApplySources')).Enabled,
        'Completed or failed merge retained a stale apply plan');
    finally MergeApplyTestPoint:=nil; Dialog.Free; end;
    Target:=SystemDB.GetCollection(TargetID,True); Books:=Target.GetBookIterator(bmAll,True); Count:=0;
    while Books.Next(Book) do begin Inc(Count); Require(Book.Title='Outcome preserved book','Outcome merge changed the source title'); end;
    Books:=nil;
    if Committed then Require(Count=1,'Saved merge result disappeared') else Require(Count=0,'Failed merge was not rolled back');
    Require(THashSHA2.GetHashStringFromFile(ArchivePath)=ArchiveHash,'Outcome test changed its book archive');
    Writeln('PASS catalog merge window durable outcome '+Phase);
  end;
  Writeln('PASS catalog source window distinguishes rolled-back merges from committed errors and signals main-view refresh');
end;
{$ELSE}
begin raise EInvalidOperation.Create('Merge outcome diagnostics require the guarded test build.'); end;
{$ENDIF}
