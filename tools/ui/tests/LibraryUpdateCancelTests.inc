{$IFDEF MHL_COMPRESSION_TEST}
type
  TLibraryCancelProbe = class
    Worker: TCollectionWorker;
    Phase: string;
    Fail, Seen, Confirmed: Boolean;
    function Confirm(const Text: string; Flags: Longint): Integer;
    function AlwaysCancel: Boolean;
    procedure Point(const Stage: string);
  end;

function TLibraryCancelProbe.Confirm(const Text: string; Flags: Longint): Integer;
begin
  Require(Text.Contains('Применить обновление') and ((Flags and MB_DEFBUTTON2)<>0),
    'Cancellation test skipped the prepared confirmation');
  Confirmed:=True; Result:=IDYES;
end;

function TLibraryCancelProbe.AlwaysCancel: Boolean;
begin Result:=True; end;

procedure TLibraryCancelProbe.Point(const Stage: string);
begin
  if Seen or (Stage<>Phase) then Exit;
  Seen:=True;
  if (Stage='commit-start') or (Stage='catalogue-committed') or (Stage='stores-committed') then
    Require(not Assigned(SQLiteCancelCallback),'Final commit still accepts SQLite interruption');
  Worker.Cancel;
  if Fail then
  begin
    SQLiteCancelCallback:=AlwaysCancel;
    raise EWriteError.Create('cancellation-restore-test');
  end;
end;
{$ENDIF}

procedure TestLibraryUpdateCancellation;
{$IFDEF MHL_COMPRESSION_TEST}
var Root, ArchivePath, ArchiveHash, OriginalID, CacheHash, TargetToken, PersonalToken, PreviousToken: string;
  Target: IBookCollection; Source: TCatalogSources; Profile: TLibraryUpdateSource;
  Stage: TStagedLibraryIndex; Review: TLibraryUpdateReview; Worker: TCollectionWorker;
  Refresh: TCatalogRefreshWorker; Merge: TCatalogMergeWorker; Plan: TCollectionMergePlan;
  Probe: TLibraryCancelProbe; Book, Original: TBookRecord; History: TCatalogSource;
  ID, Count, PreviousID: Integer; Books: IBookIterator; Bound, Committed, Fail: Boolean;
  Witness: ISystemCatalogCommitWitness;
  procedure Index(const Name: string; Updated: Boolean);
  var Zip: TZipFile; Rows: string;
  begin
    Rows:='Author,Test:'#4'prose_contemporary:'#4;
    if Updated then Rows:=Rows+'Updated 401' else Rows:=Rows+'Original 401';
    Rows:=Rows+#4#4#4'401'#4'100'#4'401'#4'0'#4'fb2'#4'2026-11-15'#4'ru'+sLineBreak;
    if Updated then Rows:=Rows+'Author,Test:'#4'prose_contemporary:'#4'New 402'#4#4#4'402'#4'100'#4'402'#4'0'#4'fb2'#4'2026-11-15'#4'ru'+sLineBreak;
    Zip:=TZipFile.Create;
    try
      Zip.Open(Name,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Zip.Add(TEncoding.UTF8.GetBytes(Rows),'books.inp');
      Zip.Add(TEncoding.UTF8.GetBytes('20261115'),'version.info');
    finally Zip.Free; end;
  end;
begin
  Require(Supports(SystemDB,ISystemCatalogCommitWitness,Witness),'Personal store has no commit witnesses');
  PreviousID:=0; PreviousToken:='';
  for Bound in TArray<Boolean>.Create(False,True) do
    for var Phase in TArray<string>.Create('rows-written','before-commit','commit-start','catalogue-committed','stores-committed','late-error') do
    begin
      Root:=TPath.Combine(Settings.AppPath,'cancel-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
      ArchivePath:=TPath.Combine(Root,'books.zip');
      var Zip:=TZipFile.Create;
      try
        Zip.Open(ArchivePath,zmWrite);
        for var Number in TArray<string>.Create('401','402') do
          Zip.Add(TEncoding.UTF8.GetBytes('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>'+Number+'</p></section></body></FictionBook>'),Number+'.fb2');
      finally Zip.Free; end;
      ArchiveHash:=THashSHA2.GetHashStringFromFile(ArchivePath);
      Index(TPath.Combine(Root,'old.inpx'),False); Index(TPath.Combine(Root,'new.inpx'),True);
      ID:=SystemDB.CreateCollection('Cancel '+BoolToStr(Bound,True)+' '+Phase,Root,TPath.Combine(Root,'target.hlc2'),CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
      Target:=SystemDB.GetCollection(ID); SetLength(Source,0); CacheHash:='';
      if Bound then
      begin
        SetLength(Source,1); Source[0]:=Default(TCatalogSource);
        Source[0].ID:=TCatalogSource.NewID; Source[0].Name:='Bound source'; Source[0].Root:=Root;
        Source[0].INPXFile:=TPath.Combine(Root,'old.inpx'); Source[0].LibraryNamespace:='flibusta';
        Refresh:=TCatalogRefreshWorker.Create(Source[0]);
        try Refresh.Start; Refresh.WaitFor; Require(Refresh.Success,'Cancel source preparation: '+Refresh.Error);
        finally Refresh.Free; end;
        CacheHash:=THashSHA2.GetHashStringFromFile(Source[0].CacheFile); SaveCatalogSources(Target,Source);
        Merge:=TCatalogMergeWorker.CreatePreview(ID,Source,mpSourcePriority);
        try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Cancel merge preview: '+Merge.Error); Plan:=Merge.TakePlan;
        finally Merge.Free; end;
        try
          Merge:=TCatalogMergeWorker.CreateApply(Plan,TPath.Combine(Root,'baseline-backup'));
          try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Cancel baseline merge: '+Merge.Error);
          finally Merge.Free; end;
        finally Plan.Free; end;
        Target:=SystemDB.GetCollection(ID,True);
      end
      else
      begin
        Book:=Default(TBookRecord); Book.LibID:='401'; Book.FileName:='401'; Book.FileExt:='.fb2';
        Book.Folder:='books.zip'; Book.Title:='Original 401'; Book.Lang:='ru'; Book.Size:=100;
        Target.InsertBook(Book,False,False);
      end;
      Books:=Target.GetBookIterator(bmAll,True); Require(Books.Next(Original),'Cancel baseline missing'); Books:=nil;
      OriginalID:=Original.LibID;
      Target.SetRate(Original.BookKey,4); Target.SetProgress(Original.BookKey,31);
      Target.SetReview(Original.BookKey,'Original review'); Target.SetAnnotation(Original.BookKey,'Original annotation');
      Target.AddBookToGroup(Original.BookKey,FAVORITES_GROUP_ID);
      for var PropID in TArray<Integer>.Create(PROP_CREATIONDATE,PROP_LIBRARY_UPDATE_TRANSACTION) do
      begin
        var Value:=Target.GetProperty(PropID);
        if PropID=PROP_LIBRARY_UPDATE_TRANSACTION then
          Require(VarIsEmpty(Value),'Missing catalogue property reused the preceding property value');
      end;
      for var CandidateID in TArray<Integer>.Create(ID,High(Integer)) do
      begin
        var Value:=SystemDB.GetProperty(CandidateID,PROP_DISPLAYNAME);
        if CandidateID=High(Integer) then
          Require(VarIsEmpty(Value),'Missing system property reused the preceding collection value');
      end;
      Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Cancellation update'; Profile.Location:=Root; Profile.IndexFile:='new.inpx';
      if Bound then Profile.CatalogSourceID:=Source[0].ID;
      Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil); Review:=TLibraryUpdateReview.Create(Profile,Stage);
      try
        Worker:=CreateLibraryReviewWorker(ID,Review);
        try Worker.Start; Worker.WaitFor;
          Require(not Assigned(Worker.FatalException) and Worker.Success,'Cancel fixture review failed');
        finally Worker.Free; end;
        Probe:=TLibraryCancelProbe.Create;
        try
          Fail:=Phase='late-error'; Probe.Fail:=Fail;
          if Fail then
            if Bound then Probe.Phase:='catalogue-committed' else Probe.Phase:='stores-committed'
          else Probe.Phase:=Phase;
          Committed:=(Phase='commit-start') or (Phase='catalogue-committed') or (Phase='stores-committed') or (Fail and not Bound);
          Worker:=CreateLibraryApplyWorker(ID,Review,False); Probe.Worker:=Worker;
          LibraryUpdateTestPoint:=procedure(Value:string) begin Probe.Point(Value); end;
          MergeApplyTestPoint:=LibraryUpdateTestPoint;
          try
            Worker.OnShowMessage:=Probe.Confirm; Worker.Start; Worker.WaitFor;
            Require(Probe.Confirmed and Probe.Seen and Worker.Canceled,'Cancellation point was not reached: '+Phase);
            Require(Worker.CommittedChanges=Committed,'Wrong committed state at '+Phase);
            Require(Worker.Success=(Committed and not Fail),'Wrong success state at '+Phase);
            if Fail then Require(Assigned(Worker.FatalException) and Exception(Worker.FatalException).Message.Contains('cancellation-restore-test'),
              'Injected interruption error was hidden');
          finally LibraryUpdateTestPoint:=nil; MergeApplyTestPoint:=nil; Worker.Free; end;
        finally Probe.Free; end;
        Target:=SystemDB.GetCollection(ID,True);
        TargetToken:=VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_TRANSACTION));
        PersonalToken:=Witness.CatalogCommitWitness(ID);
        if Committed then
          Require((Review.OperationID<>'') and (TargetToken=Review.OperationID) and (PersonalToken=Review.OperationID),
            'Committed update did not publish matching catalogue/personal witnesses at '+Phase)
        else if (TargetToken<>'') or (PersonalToken<>'') then
        begin
          var Raw:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(ID).DBFileName);
          try
            var Query:=Raw.NewQuery('SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_LIBRARY_UPDATE_TRANSACTION]);
            try
              Query.Open; var Stored:='(no row)'; if not Query.Eof then Stored:=Query.FieldAsString(0);
              Require(False,Format('Rollback witness at %s bound=%s ID=%d target="%s" personal="%s" raw="%s" current="%s"',
                [Phase,BoolToStr(Bound,True),ID,TargetToken,PersonalToken,Stored,Review.OperationID]));
            finally Query.Free; end;
          finally Raw.Free; end;
        end;
        if PreviousID>0 then Require(Witness.CatalogCommitWitness(PreviousID)=PreviousToken,
          'An update replaced another collection''s commit witness');
        PreviousID:=ID; PreviousToken:=PersonalToken;
        Books:=Target.GetBookIterator(bmAll,True); Count:=0;
        while Books.Next(Book) do
        begin
          Inc(Count);
          if Book.LibID=OriginalID then
          begin
            Require((Book.Rate=4) and (Book.Progress=31) and (Book.Review='Original review') and (Book.Annotation='Original annotation'),
              'Cancellation changed personal data at '+Phase);
            if Committed then Require(Book.Title='Updated 401','Late stop left old metadata')
            else Require(Book.Title='Original 401','Stopped transaction kept new metadata');
          end;
        end;
        Books:=nil;
        if Committed then Require(Count=2,'Completed update lost its new book') else Require(Count=1,'Canceled update retained a new book');
        Require(LoadLibraryUpdateHistory(Target,Profile,History)=Committed,'History does not match the actual commit');
        if Committed then Require(FileExists(History.CacheFile),'Published baseline was removed after a late stop/error');
        Books:=SystemDB.GetBookIterator(FAVORITES_GROUP_ID,ID);
        Require(Books.Next(Book) and (Book.LibID=OriginalID) and not Books.Next(Book),'Cancellation lost favourite membership'); Books:=nil;
        Require(THashSHA2.GetHashStringFromFile(ArchivePath)=ArchiveHash,'Update cancellation changed a book archive');
        if Bound then Require(THashSHA2.GetHashStringFromFile(Source[0].CacheFile)=CacheHash,'Cancellation overwrote the previous source baseline');
        Writeln('PASS update cancellation bound='+BoolToStr(Bound,True)+' phase='+Phase);
      finally Review.Free; Stage.Free; end;
    end;
  Writeln('PASS reviewed update cancellation rolls back before commit, finishes late saves, protects rollback and retains published baselines after post-commit errors');
  Writeln('PASS reviewed update commit witnesses are paired with catalogue and personal transactions, roll back on early errors and remain isolated by collection');
  Writeln('PASS missing catalogue and system properties return empty instead of reusing a previous value');
end;
{$ELSE}
begin raise EInvalidOperation.Create('Cancellation diagnostics require the guarded test build.'); end;
{$ENDIF}
