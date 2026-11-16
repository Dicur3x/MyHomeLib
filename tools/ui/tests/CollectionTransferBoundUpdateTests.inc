  // Extend the existing real INPX/compression fixture through physical transfer.
  // Only the dedicated private marker enables this more expensive gate.
  procedure MoveBoundFixture;
  var Capture:TCollectionTransferCatalogue; FilePlan:TCollectionTransferPlan;
    Journal:TCollectionTransferJournal; Operation:TCollectionTransferOperation;
    Paths,ArchiveHashes,NewHashes:TDictionary<string,string>;
    NewExpected:TDictionary<string,Int64>; OriginalRoots:TArray<string>;
    Work,Destination:string; Book:TBookRecord;

    function PathKey(const Value:string):string;
    begin
      Result:=ExpandFileName(StringReplace(Value,'/','\',[rfReplaceAll]));
      if Result.StartsWith('\\?\') then Delete(Result,1,4);
      Result:=LowerCase(Result);
    end;

    function RelocatedKey(const Value:string):string;
    begin
      var Separator:=Pos(#1,Value); Require(Separator>1,'Missing bound payload identity');
      var OldPath:=PathKey(Copy(Value,1,Separator-1));
      Require(Paths.ContainsKey(OldPath),'Transferred review omitted a compressed archive');
      Result:=Paths[OldPath]+Copy(Value,Separator,MaxInt);
    end;
  begin
    RequireIsolatedRegression;
    Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Bound transfer fixture must use G:');
    OriginalRoots:=TArray<string>.Create(Sources[0].Root,Sources[1].Root);
    for var I:=0 to High(Originals) do
    begin
      Require(Find(IntToStr(1001+I),Book),'Missing transfer identity fixture');
      if BaselineBookIDs<>'' then BaselineBookIDs:=BaselineBookIDs+',';
      BaselineBookIDs:=BaselineBookIDs+IntToStr(Book.BookKey.BookID);
    end;
    TransferredKeysSHA:=CurrentIdentitySHA;
    var Choice:=TMenuItem.Create(nil);
    try Choice.Tag:=Originals[0].BookKey.DatabaseID; frmMain.miActiveCollectionClick(Choice);
    finally Choice.Free; end;
    Application.ProcessMessages; Target:=nil; SystemDB.ClearCollectionCache;
    Work:=Settings.AppPath+'bound-transfer-work'; Destination:=Settings.AppPath+'bound-consolidated';
    ForceDirectories(Work); ForceDirectories(Destination);
    Paths:=TDictionary<string,string>.Create; ArchiveHashes:=TDictionary<string,string>.Create;
    NewExpected:=TDictionary<string,Int64>.Create; NewHashes:=TDictionary<string,string>.Create;
    Journal:=nil; Capture:=nil; FilePlan:=nil;
    try
      Capture:=TCollectionTransferCatalogue.Create(SystemDB.GetCollectionInfo(ID),Settings.SystemFileName[sfSystemDB],Work);
      FilePlan:=Capture.BuildFilePlan(Destination,Work,TGUID.NewGuid);
      Journal:=TCollectionTransferJournal.Create(Work,Capture,FilePlan);
      FreeAndNil(FilePlan); FreeAndNil(Capture);
      var Query:=Journal.Review.NewQuery('SELECT Source,Destination FROM Files ORDER BY ID');
      try Query.Open;
        while not Query.Eof do
        begin
          var Source:=Query.FieldAsString(0); var NewPath:=Query.FieldAsString(1);
          Paths.Add(PathKey(Source),NewPath);
          ArchiveHashes.Add(PathKey(Source),THashSHA2.GetHashStringFromFile(Source)); Query.Next;
        end;
      finally Query.Free; end;
      Require(Paths.Count=2,'Bound transfer must cover two equally named compressed archives');
      Operation:=TCollectionTransferOperation.Create(Journal);
      try
        var State:=Operation.Run(nil,
          procedure(const Stage,Source:string; GroupsDone,GroupsTotal,Done,Total:Int64)
          begin Writeln('TRACE bound transfer ',Stage,' ',GroupsDone,'/',GroupsTotal,' ',Done,'/',Total); Flush(System.Output); end,
          True,True,True);
        Require(State.RootsApplied and (State.CacheDatabasesPublished>0) and
          (State.GroupsDone=State.GroupsTotal) and (State.Originals.Pending=0),
          'Bound transfer did not publish every root/source/history participant');
      finally Operation.Free; end;
      for var Pair in Paths do
      begin
        Require(THashSHA2.GetHashStringFromFile(Pair.Value)=ArchiveHashes[Pair.Key],
          'Transfer changed an already compressed archive');
        if not SameText(Pair.Key,PathKey(Pair.Value)) then
          Require(not FileExists(Pair.Key),'Exclusive bound original was not released');
      end;
      for var Pair in Expected do NewExpected.Add(RelocatedKey(Pair.Key),Pair.Value);
      for var Pair in Hashes do NewHashes.Add(RelocatedKey(Pair.Key),Pair.Value);
      FreeAndNil(Journal);
      Expected.Free; Expected:=NewExpected; NewExpected:=nil;
      Hashes.Free; Hashes:=NewHashes; NewHashes:=nil;
      SystemDB.ClearCollectionCache; Target:=SystemDB.GetCollection(ID,True);
      Sources:=LoadCatalogSources(Target); Require(Length(Sources)=2,'Transfer lost source bindings');
      Require(not SameText(Sources[0].Root,Sources[1].Root),'Equal archive names share a destination');
      CheckCopies(False);
      for var I:=0 to High(OriginalRoots) do
      begin
        Require(ExpandFileName(OriginalRoots[I]).StartsWith(Settings.AppPath,True),
          'Old source folder is outside the owned transfer fixture');
        TDirectory.Move(OriginalRoots[I],OriginalRoots[I]+'-offline');
        // The publisher may supply the next index in a new incoming folder.
        Sources[I].INPXFile:=TPath.Combine(Downloads,'source-'+IntToStr(I)+'.inpx');
      end;
      Profile.Location:=Downloads; Profile.IndexFile:=TPath.GetFileName(Sources[1].INPXFile);
      CheckCopies(False);
      Writeln('PASS actual bound transfer preserves compressed archive hashes book IDs source keys copies and personal fields with old roots offline');
    finally
      Journal.Free; FilePlan.Free; Capture.Free; Paths.Free; ArchiveHashes.Free; NewExpected.Free; NewHashes.Free;
    end;
  end;
