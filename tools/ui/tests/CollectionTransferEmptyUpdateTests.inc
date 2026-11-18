  procedure TestTransferredEmptyIDs;
  const Names:array[0..3] of string=('empty','zero','opaque','arrived');
    LibraryIDs:array[0..3] of string=('','0','file:opaque','');
  var HistoryMode:Integer; Histories:array[0..2] of string; ReaderFiles:TDictionary<string,string>;
    BoundMode,Arrived,Corrected,Excluded:Boolean; StoredIDs:array[0..2] of Integer;
    StoredLibs:array[0..2] of string; MoveRoot,Work,OldArchiveHash,ProfileID:string;
    Capture:TCollectionTransferCatalogue; FilePlan:TCollectionTransferPlan;
    Journal:TCollectionTransferJournal; Operation:TCollectionTransferOperation;

    procedure WriteEmptyIndex;
    var Z:TZipFile; OldRows,NewRows,Row,Title:string;
    begin
      Z:=TZipFile.Create;
      try
        OldRows:=''; NewRows:='';
        for var I:=0 to IfThen(Arrived,3,2) do
        begin
          Title:='Index '+Names[I]; if Corrected then Title:=Title+' corrected';
          Row:='Author,Test:'#4'prose_contemporary:'#4+Title+#4#4#4+Names[I]+#4+
            Length(TEncoding.UTF8.GetBytes(XML(Names[I]))).ToString+#4+LibraryIDs[I]+
            #4'0'#4'fb2'#4'2026-11-18'#4'ru'+sLineBreak;
          if I=3 then NewRows:=NewRows+Row else OldRows:=OldRows+Row;
        end;
        Z.Open(IndexName,zmWrite);
        Z.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
        Z.Add(TEncoding.UTF8.GetBytes('20261118'),'version.info');
        Z.Add(TEncoding.UTF8.GetBytes(OldRows),'books.inp');
        if Arrived then Z.Add(TEncoding.UTF8.GetBytes(NewRows),'new.inp');
      finally Z.Free; end;
    end;
    function FindName(const Name:string; out Item:TBookRecord):Boolean;
    begin
      var It:=Target.GetBookIterator(bmAll,True); Result:=False;
      while It.Next(Item) do if Item.FileName=Name then Exit(True);
    end;
    procedure CheckBooks(CaptureIDs:Boolean);
    var Item,Personal:TBookRecord; Count:Integer;
    begin
      Target:=SystemDB.GetCollection(ID,True); var It:=Target.GetBookIterator(bmAll,True); Count:=0;
      while It.Next(Item) do Inc(Count); It:=nil;
      Require(Count=IfThen(Arrived,4,3)-Ord(Excluded),Format('Empty-ID update created/lost cards: %d bound=%s',[Count,BoolToStr(BoundMode,True)]));
      for var I:=0 to IfThen(Arrived,3,2) do
      begin
        if Excluded and (I=0) then
        begin Require(not FindName(Names[I],Item),'Deleted empty-ID card returned'); Continue; end;
        Require(FindName(Names[I],Item),'Missing transferred identity '+Names[I]);
        RequireBody(Item,Names[I]);
        if I<3 then
        begin
          if CaptureIDs then
          begin StoredIDs[I]:=Item.BookKey.BookID; StoredLibs[I]:=Item.LibID; end
          else
          begin
            Require((Item.BookKey.BookID=StoredIDs[I]) and (Item.LibID=StoredLibs[I]),'Empty-ID update replaced a retained identity');
            SystemDB.GetBookRecord(Item.BookKey,Personal);
            Require((Personal.Progress=37) and (Item.Rate=4) and (Personal.Review='Empty-ID note '+Names[I]) and
              (Item.Annotation='Empty-ID annotation '+Names[I]),'Empty-ID update lost personal data');
            Require(Item.GetBookFileName.Contains(MoveRoot),'Empty-ID update reverted a transferred locator');
            Require(ReaderHistoryName(Item,'')=Histories[I],'Transfer lost the saved history-name representation');
          end;
        end
        else Require(Item.GetBookFileName.Contains(DownloadRoot),'Empty-ID arrival lost the download root');
        var Title:='Index '+Names[I]; if Corrected then Title:=Title+' corrected';
        Require(Item.Title=Title,'Empty-ID update did not retain/apply metadata for '+Names[I]+': '+Item.Title);
      end;
      if not CaptureIDs then
      begin
        var Favourites:=SystemDB.GetBookIterator(FAVORITES_GROUP_ID,ID); Count:=0;
        while Favourites.Next(Item) do
        begin Inc(Count); Require(Item.FileName<>'arrived','New download became an old favourite'); end;
        Favourites:=nil; Require(Count=3-Ord(Excluded),'Empty-ID update changed favourite membership');
      end;
    end;
    procedure ReviewAndApply;
    begin
      OpenReview;
      try
        Require(Review.MissingBooks=0,'Transferred empty-ID update incorrectly requests old archives: '+Review.MissingDetails);
        Apply(True); CheckBooks(False);
      finally CloseReview; end;
    end;
  begin
    RequireIsolatedRegression;
    Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Empty-ID transfer tests require G:');
    for var CaseNo:=0 to 5 do
    begin
      BoundMode:=CaseNo>=3; HistoryMode:=CaseNo mod 3; Arrived:=False; Corrected:=False; Excluded:=False;
      Root:=Settings.AppPath+'empty-transfer-'+IntToStr(CaseNo); ForceDirectories(Root);
      OldRoot:=Root+'\old'; DownloadRoot:=Root+'\downloads'; IndexName:=Root+'\publisher.inpx';
      Archive(OldRoot,'books.zip',['empty','zero','opaque']); Archive(DownloadRoot,'new.zip',['arrived']);
      WriteEmptyIndex; SetLength(Sources,1); Sources[0]:=Default(TCatalogSource);
      Sources[0].ID:=TCatalogSource.NewID; Sources[0].Name:='Empty-ID source'; Sources[0].Root:=OldRoot;
      Sources[0].INPXFile:=IndexName; Sources[0].LibraryNamespace:='flibusta';
      Refresh:=TCatalogRefreshWorker.Create(Sources[0]);
      try Refresh.Start; Refresh.WaitFor; Require(Refresh.Success,'Empty-ID initial INPX import: '+Refresh.Error); Sources[0]:=Refresh.Source;
      finally Refresh.Free; end;
      if BoundMode then
      begin
        ID:=SystemDB.CreateCollection('Bound empty-ID transfer '+IntToStr(CaseNo),OldRoot,Root+'\target.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
        Target:=SystemDB.GetCollection(ID); SaveCatalogSources(Target,Sources);
        Merge:=TCatalogMergeWorker.CreatePreview(ID,Sources,mpSourcePriority);
        try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Empty-ID initial merge: '+Merge.Error); Plan:=Merge.TakePlan;
        finally Merge.Free; end;
        try Merge:=TCatalogMergeWorker.CreateApply(Plan,Root+'\merge-backup');
          try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Empty-ID initial merge apply: '+Merge.Error);
          finally Merge.Free; end;
        finally Plan.Free; Plan:=nil; end;
      end
      else
      begin
        TFile.Copy(Sources[0].CacheFile,Root+'\target.hlc2',False);
        ID:=SystemDB.RegisterCollection(Root+'\target.hlc2','Whole empty-ID transfer '+IntToStr(CaseNo),OldRoot);
      end;
      Target:=SystemDB.GetCollection(ID,True); Target.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
      Profile:=TLibraryUpdateSource.NewSource; ProfileID:=Profile.ID; Profile.Name:='Empty-ID updater';
      Profile.Location:=Root; Profile.IndexFile:='publisher.inpx'; Profile.BooksRoot:=OldRoot;
      if BoundMode then Profile.CatalogSourceID:=Sources[0].ID;
      Target.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,WriteLibraryUpdateSources(TArray<TLibraryUpdateSource>.Create(Profile)));
      CheckBooks(True);
      for var I:=0 to 2 do
      begin
        Require(FindName(Names[I],Book),'Cannot seed empty-ID personal fields');
        Target.SetRate(Book.BookKey,4); Target.SetProgress(Book.BookKey,37);
        Target.SetReview(Book.BookKey,'Empty-ID note '+Names[I]); Target.SetAnnotation(Book.BookKey,'Empty-ID annotation '+Names[I]);
        Target.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID);
      end;
      var ReaderSettings:=ResolveReaderSettingsFile(Settings.DataDir);
      ReaderFiles:=TDictionary<string,string>.Create;
      for var I:=0 to 2 do
      begin
        Require(FindName(Names[I],Book),'Missing history fixture');
        var Personal:=Default(TBookRecord); SystemDB.GetBookRecord(Book.BookKey,Personal);
        Histories[I]:=ReaderHistoryName(Book,'');
        RegisterReaderNoteBook(ReaderSettings,Personal,''); // Metadata alone is not another saved history.
        if HistoryMode=1 then
        begin
          var Ini:=TMemIniFile.Create(ReaderSettings,TEncoding.UTF8);
          try
            var Key:=ReaderNoteIdentity(Histories[I]);
            Ini.WriteInteger('Book.'+Key,'Position',100+I);
            Ini.WriteInteger('Bookmarks.'+Key,'Count',1); Ini.WriteInteger('Bookmarks.'+Key,'Position0',100+I);
            Ini.UpdateFile;
          finally Ini.Free; end;
        end
        else if HistoryMode=2 then
        begin
          Histories[I]:=ReaderHistoryName(Personal,'');
          var Notes:=TReaderAnnotations.Create(ReaderSettings);
          try
            var Note:=Default(TReaderAnnotation); Note.BookID:=ReaderNoteIdentity(Histories[I]);
            Note.BookTitle:=Book.Title; Note.Title:='Personal-path note'; Note.Text:='Keep the personal history representation';
            Note.Position:=I+1; Note.Created:=DateToISO8601(Now,False); Notes.Put(Note);
          finally Notes.Free; end;
        end;
      end;
      for var FileName in TArray<string>.Create(ReaderSettings,TPath.Combine(ExtractFileDir(ReaderSettings),'reader-notes.json')) do
        if FileExists(FileName) then ReaderFiles.Add(FileName,THashSHA2.GetHashStringFromFile(FileName));
      OldArchiveHash:=THashSHA2.GetHashStringFromFile(OldRoot+'\books.zip');
      Target:=nil; SystemDB.ClearCollectionCache;
      Work:=Root+'\transfer-work'; MoveRoot:=Root+'\moved'; ForceDirectories(Work); ForceDirectories(MoveRoot);
      Capture:=nil; FilePlan:=nil; Journal:=nil;
      try
        Capture:=TCollectionTransferCatalogue.Create(SystemDB.GetCollectionInfo(ID),Settings.SystemFileName[sfSystemDB],Work);
        FilePlan:=Capture.BuildFilePlan(MoveRoot,Work,TGUID.NewGuid);
        Journal:=TCollectionTransferJournal.Create(Work,Capture,FilePlan); FreeAndNil(FilePlan); FreeAndNil(Capture);
        Operation:=TCollectionTransferOperation.Create(Journal);
        try
          var State:=Operation.Run(nil,nil,True,True,True);
          Require(State.RootsApplied and (State.GroupsDone=State.GroupsTotal) and (State.Originals.Pending=0),'Empty-ID transfer incomplete');
        finally Operation.Free; end;
      finally Journal.Free; FilePlan.Free; Capture.Free; end;
      Target:=SystemDB.GetCollection(ID,True); CheckBooks(False);
      Require(FindName('empty',Book) and (THashSHA2.GetHashStringFromFile(Book.GetBookFileName)=OldArchiveHash),
        'Empty-ID transfer changed archive bytes');
      Require(not FileExists(OldRoot+'\books.zip'),'Exclusive empty-ID original was not released');
      TDirectory.Move(OldRoot,OldRoot+'-offline');
      var Saved:=ReadLibraryUpdateSources(VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_SOURCES)));
      Require((Length(Saved)=1) and (Saved[0].ID=ProfileID) and (Saved[0].LocalFile=IndexName),
        'Empty-ID transfer lost its update profile');
      Profile:=Saved[0]; Profile.BooksRoot:=DownloadRoot;
      Arrived:=True; Corrected:=True; WriteEmptyIndex;
      ReviewAndApply; ReviewAndApply; Profile.Full:=False; ReviewAndApply;
      Writeln('PASS transferred empty zero and opaque identities survive full repeated append INPX with original root offline bound=',BoolToStr(BoundMode,True));
      Require(FindName('empty',Book),'Missing empty-ID exclusion fixture'); Target.DeleteBook(Book.BookKey); Excluded:=True;
      Profile.Full:=True; ReviewAndApply; Profile.Full:=False; ReviewAndApply;
      Writeln('PASS deleted transferred empty-ID card stays excluded without losing the new download or personal fields bound=',BoolToStr(BoundMode,True),' history=',HistoryMode);
      for var Pair in ReaderFiles do Require(THashSHA2.GetHashStringFromFile(Pair.Key)=Pair.Value,'Transfer/update rewrote reader settings or notes');
      ReaderFiles.Free; ReaderFiles:=nil;
    end;
  end;
