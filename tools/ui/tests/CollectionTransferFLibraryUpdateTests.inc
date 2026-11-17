  // A private opt-in fixture composes the existing sidecar/update checks with
  // the complete physical transfer. The original fixture stays registered.
  procedure MoveFLibraryFixture;
  var Capture:TCollectionTransferCatalogue; Plan:TCollectionTransferPlan;
    Journal:TCollectionTransferJournal; Operation:TCollectionTransferOperation;
    Paths,NewFiles,NewExpected,NewRaw,Untouched:TDictionary<string,string>;
    NewSizes:TDictionary<string,Int64>; OldRoots:TArray<string>; Work,Destination,Before:string;

    function PathKey(const Value:string):string;
    begin
      Result:=ExpandFileName(StringReplace(Value,'/','\',[rfReplaceAll]));
      if Result.StartsWith('\\?\') then Delete(Result,1,4);
      Result:=LowerCase(Result);
    end;
    function Relocated(const Value:string):string;
    begin
      var Separator:=Pos(#0,Value); Require(Separator>1,'Missing sidecar payload identity');
      var Key:=PathKey(Copy(Value,1,Separator-1));
      Require(Paths.ContainsKey(Key),'Transfer omitted a sidecar book archive');
      Result:=Paths[Key]+Copy(Value,Separator,MaxInt);
    end;
    function StableState(ArchiveFiles:TDictionary<string,string>):string;
    var DB:TSQLiteDatabase; Text:TStringBuilder;
    begin
      DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(TargetID).DBFileName);
      Text:=TStringBuilder.Create;
      try
        var Keys:='';
        for var Pair in ArchiveFiles do
        begin
          if Keys<>'' then Keys:=Keys+',';
          Keys:=Keys+QuotedStr(UpperCase(Copy(ArchiveDeletionSourceIdentity(Pair.Key),1,25)));
        end;
        Require(Keys<>'','Missing physical history keys');
        for var SQL in TArray<string>.Create(
          'SELECT BookID,LibID FROM Books ORDER BY 1,2',
          'SELECT BookID,SourceKey FROM CatalogSourceBooks ORDER BY 1,2',
          'SELECT BookID,SourceKey FROM CatalogBookCopies ORDER BY 1,2',
          'SELECT Member,ProfileSHA256,InputSHA256,OutputSHA256,BookSize FROM HomeLibreBookCompression ORDER BY 1,2,3,4,5',
          'SELECT Member,Profile,Grayscale,EngineSHA256,SourceSHA256,PayloadSHA256 FROM HomeLibreCompressionChecks ORDER BY 1,2,3,4,5,6',
          'SELECT Member,PayloadSHA256,BookSize,FullInputSHA256,FullOutputSHA256,SourceSHA256 FROM HomeLibreRestoredBookSizes ORDER BY 1,2,3,4,5,6',
          'SELECT Member,Profile,Grayscale,EngineSHA256 FROM HomeLibreCompressionDependencies ORDER BY 1,2,3,4') do
        begin
          Text.Append(SQL).Append(#0); var Filtered:=SQL;
          if Pos('FROM HomeLibre',SQL)>0 then
            Filtered:=StringReplace(SQL,' ORDER BY',' WHERE FileKey IN ('+Keys+') ORDER BY',[]);
          var Q:=DB.NewQuery(Filtered);
          try Q.Open;
            while not Q.Eof do
            begin
              for var I:=0 to Q.ColCount-1 do
              begin var Value:=Q.FieldAsString(I); Text.Append(Length(Value)).Append(':').Append(Value); end;
              Text.Append(#10); Q.Next;
            end;
          finally Q.Free; end;
        end;
        Result:=THashSHA2.GetHashString(Text.ToString);
      finally Text.Free; DB.Free; end;
    end;
  begin
    RequireIsolatedRegression;
    Require(Bound and not StartupMode and (CrashPhase=''),'Sidecar transfer requires a fresh bound fixture');
    Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Sidecar transfer must use G:');
    OldRoots:=TArray<string>.Create(PreferredRoot,SecondRoot);
    Current.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,WriteLibraryUpdateSources(Profiles));
    Before:=StableState(Files); Current:=nil; SystemDB.ClearCollectionCache;
    Work:=Settings.AppPath+'sidecar-transfer-work'; Destination:=Settings.AppPath+'sidecar-consolidated';
    ForceDirectories(Work); ForceDirectories(Destination);
    Paths:=TDictionary<string,string>.Create; NewFiles:=TDictionary<string,string>.Create;
    NewExpected:=TDictionary<string,string>.Create; NewRaw:=TDictionary<string,string>.Create;
    NewSizes:=TDictionary<string,Int64>.Create; Untouched:=TDictionary<string,string>.Create;
    Journal:=nil; Capture:=nil; Plan:=nil;
    try
      for var FileName in TDirectory.GetFiles(SourceRoot,'*',TSearchOption.soAllDirectories) do
        Untouched.Add(FileName,UpdateSHA256(FileName));
      Capture:=TCollectionTransferCatalogue.Create(SystemDB.GetCollectionInfo(TargetID),Settings.SystemFileName[sfSystemDB],Work);
      Plan:=Capture.BuildFilePlan(Destination,Work,TGUID.NewGuid);
      Journal:=TCollectionTransferJournal.Create(Work,Capture,Plan);
      FreeAndNil(Plan); FreeAndNil(Capture);
      var Q:=Journal.Review.NewQuery('SELECT Source,Destination FROM Files ORDER BY ID');
      try Q.Open;
        while not Q.Eof do begin Paths.Add(PathKey(Q.FieldAsString(0)),Q.FieldAsString(1)); Q.Next; end;
      finally Q.Free; end;
      Require((Paths.Count=Files.Count) and (Paths.Count=16),'Sidecar transfer must include all sixteen book/cover/image archives');
      for var Pair in Files do
      begin
        Require(Paths.ContainsKey(PathKey(Pair.Key)),'Transfer omitted an external cover/image archive');
        NewFiles.Add(Paths[PathKey(Pair.Key)],Pair.Value);
      end;
      for var Pair in Expected do NewExpected.Add(Relocated(Pair.Key),Pair.Value);
      for var Pair in Raw do NewRaw.Add(Relocated(Pair.Key),Pair.Value);
      for var Pair in Sizes do NewSizes.Add(Relocated(Pair.Key),Pair.Value);
      Operation:=TCollectionTransferOperation.Create(Journal);
      try
        var State:=Operation.Run(nil,
          procedure(const Stage,Source:string; GroupsDone,GroupsTotal,Done,Total:Int64)
          begin Writeln('TRACE sidecar transfer ',Stage,' ',GroupsDone,'/',GroupsTotal,' ',Done,'/',Total); Flush(System.Output); end,
          True,True,True);
        Require(State.RootsApplied and (State.CacheDatabasesPublished=2) and
          (State.GroupsDone=State.GroupsTotal) and (State.Originals.Pending=0),'Sidecar transfer did not finish all participants');
      finally Operation.Free; end;
      for var Pair in Files do
      begin
        Require(UpdateSHA256(Paths[PathKey(Pair.Key)])=Pair.Value,'Transfer changed a compressed sidecar archive');
        Require(not FileExists(Pair.Key),'Exclusive sidecar original was not released');
      end;
      for var Pair in Untouched do Require(UpdateSHA256(Pair.Key)=Pair.Value,'Transfer changed the independently registered original fixture');
      Require(StableState(NewFiles)=Before,'Transfer changed book/source/copy IDs or stable compression witnesses for current physical files');
      FreeAndNil(Journal);
      Files.Free; Files:=NewFiles; NewFiles:=nil;
      Expected.Free; Expected:=NewExpected; NewExpected:=nil;
      Raw.Free; Raw:=NewRaw; NewRaw:=nil; Sizes.Free; Sizes:=NewSizes; NewSizes:=nil;
      SystemDB.ClearCollectionCache; Current:=SystemDB.GetCollection(TargetID,True);
      Sources:=LoadCatalogSources(Current); Require(Length(Sources)=2,'Sidecar transfer lost source bindings');
      PreferredRoot:=Sources[0].Root; SecondRoot:=Sources[1].Root;
      Require(not SameText(PreferredRoot,SecondRoot),'Same-named sidecar sources share a destination');
      var Saved:=ReadLibraryUpdateSources(VarToStr(Current.GetProperty(PROP_LIBRARY_UPDATE_SOURCES)));
      Require(Length(Saved)=Length(Profiles),'Transfer lost independent update profiles');
      for var I:=0 to High(Profiles) do
      begin
        Require((Saved[I].ID=Profiles[I].ID) and (Saved[I].CatalogSourceID=Profiles[I].CatalogSourceID) and
          (Saved[I].LocalFile=Profiles[I].LocalFile) and SameText(Saved[I].BooksRoot,Sources[I].Root),
          'Transfer lost an update profile identity/index or mapped its wrong source root');
        Require(ExpandFileName(OldRoots[I]).StartsWith(Settings.AppPath,True),'Old sidecar source is outside the private fixture');
        TDirectory.Move(OldRoots[I],OldRoots[I]+'-offline');
      end;
      Profiles:=Saved; ForceDirectories(Downloads);
      for var I:=0 to High(Profiles) do Profiles[I].BooksRoot:=Downloads;
      History:=HistoryStamp; CheckBooks(False); Compress(True,0,8);
      Writeln('PASS FLibrary physical transfer preserves all sixteen archive hashes stable identities compression witnesses and independent update profiles with old roots offline');
    finally
      Journal.Free; Plan.Free; Capture.Free; Paths.Free; NewFiles.Free; NewExpected.Free; NewRaw.Free; NewSizes.Free; Untouched.Free;
    end;
  end;
