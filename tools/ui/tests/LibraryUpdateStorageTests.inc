procedure TestLibraryUpdateStorage;
var Seen:array[0..2] of Boolean; Opened:Integer; Roots:TStringList;
  PreviousTemp,PreviousTmp:string;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Storage fixture requires G:');
  for var I:=0 to 2 do Seen[I]:=False;
  Opened:=0; Roots:=TStringList.Create;
  PreviousTemp:=GetEnvironmentVariable('TEMP'); PreviousTmp:=GetEnvironmentVariable('TMP');
  LibraryUpdateTestDatabase:=procedure(DB:TSQLiteDatabase)
    var Folder,FileName,SourceHash:string; Slot,OldCache,OldTempCache:Integer;
      Rows:TSQLiteQuery; Count:Integer; Sum,Bytes:Int64;
    begin
      Inc(Opened); Folder:=DB.TemporaryDirectory;
      Require((Folder<>'') and (DB.QuerySingleInt('PRAGMA temp_store')=1),
        'Review database did not select its connection-local disk storage');
      if Folder.StartsWith('\\?\') then Folder:=Folder.Substring(4);
      Require(Folder.StartsWith(Settings.AppPath,True) and
        ExtractFileName(ExcludeTrailingPathDelimiter(Folder)).StartsWith('HomeLibre-index-'),
        'Review anonymous storage escaped its held index folder');
      if Roots.IndexOf(Folder)<0 then Roots.Add(Folder);
      FileName:=DB.QuerySingleString('SELECT file FROM pragma_database_list WHERE name=''main''');
      Slot:=-1;
      if DB.QuerySingleInt('PRAGMA query_only')<>0 then Slot:=0
      else if ExtractFileName(FileName).StartsWith('comparison-') then
        if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''ReviewRows''')=0 then Slot:=1 else Slot:=2;
      if (Slot<0) or Seen[Slot] then Exit;
      Seen[Slot]:=True; SourceHash:='';
      if Slot=0 then SourceHash:=THashSHA2.GetHashStringFromFile(FileName);
      OldCache:=DB.QuerySingleInt('PRAGMA cache_size');
      OldTempCache:=DB.QuerySingleInt('PRAGMA temp.cache_size');
      DB.ExecSQL('PRAGMA cache_size=-512'); DB.ExecSQL('PRAGMA temp.cache_size=8');
      Rows:=nil;
      try
        Rows:=DB.NewQuery('WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<9000) '+
          'SELECT x,zeroblob(2048) AS p FROM n ORDER BY p,x DESC');
        Rows.Open; Count:=0; Sum:=0; Bytes:=0;
        Require((DB.TemporaryFilesCreated>0) and
          (Length(TDirectory.GetFiles(Folder,'sqlite-temp-*'))>0),'Actual review sort did not reach its routed disk');
        for var Name in TDirectory.GetFiles(Folder,'sqlite-temp-*') do Inc(Bytes,TFile.GetSize(Name));
        Require(Bytes>0,'Observed review temporary files are empty');
        while not Rows.Eof do
        begin
          Require(Rows.FieldAsInt(0)=9000-Count,'Routed sort changed its ordering');
          Inc(Sum,Rows.FieldAsInt(0)); Inc(Count); Rows.Next;
        end;
        Require((Count=9000) and (Sum=40504500),'Routed review sort lost data');
        Require(Length(TDirectory.GetFiles(PreviousTemp,'etilqs_*'))=0,'Review fell back to process TEMP');
        Writeln('PASS actual review temporary sort slot=',Slot,' bytes=',Bytes,' readonly=',Ord(Slot=0)); Flush(Output);
      finally
        Rows.Free; DB.ExecSQL('PRAGMA cache_size='+IntToStr(OldCache));
        DB.ExecSQL('PRAGMA temp.cache_size='+IntToStr(OldTempCache));
      end;
      if Slot=0 then Require(THashSHA2.GetHashStringFromFile(FileName)=SourceHash,
        'Read-only review sort changed its source database');
    end;
  try
    TestLibraryUpdateApplication;
    Require(Seen[0] and Seen[1] and Seen[2] and (Opened>=3),'Review storage phases were not all observed');
    for var Folder in Roots do Require(not TDirectory.Exists(Folder),'A closed review retained its held work folder');
    Require((GetEnvironmentVariable('TEMP')=PreviousTemp) and (GetEnvironmentVariable('TMP')=PreviousTmp),
      'Review routing changed the process temporary environment');
    Writeln('PASS reviewed update matrix uses connection-local disk storage opens=',Opened,
      ' folders=',Roots.Count,' with closed work folders and unchanged process TEMP'); Flush(Output);
  finally LibraryUpdateTestDatabase:=nil; Roots.Free; end;
end;

procedure TestLibraryUpdateStorageFull;
var Root,Source,Input,ArchiveHash,IndexHash,Rows,PersonalRows,Folder:string;
  ID:Integer; Target:IBookCollection; Book:TBookRecord; Zip:TZipFile;
  Profile:TLibraryUpdateSource; Stage:TStagedLibraryIndex; Review:TLibraryUpdateReview;
  Worker:TCollectionWorker; Catalogue,Personal:TSQLiteDatabase; FaultSeen:Boolean;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Storage-full fixture requires G:');
  Root:=Settings.AppPath+'review-storage-full'; ForceDirectories(Root);
  Source:=TPath.Combine(Root,'books.zip'); Input:=TPath.Combine(Root,'update.inpx');
  Zip:=TZipFile.Create;
  try
    Zip.Open(Source,zmWrite);
    for var Name in ['old.fb2','new.fb2'] do Zip.Add(TEncoding.UTF8.GetBytes(
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>'+Name+
      '</p></section></body></FictionBook>'),Name);
  finally Zip.Free; end;
  Zip:=TZipFile.Create;
  try
    Zip.Open(Input,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
    Zip.Add(TEncoding.UTF8.GetBytes('20261118'),'version.info');
    Zip.Add(TEncoding.UTF8.GetBytes('Author,Test:'#4'prose_contemporary:'#4'New book'#4#4#4'new'#4'100'#4'9001'#4'0'#4'fb2'#4'2026-11-18'#4'ru'+sLineBreak),'books.inp');
  finally Zip.Free; end;
  ID:=SystemDB.CreateCollection('Owned storage full',Root,TPath.Combine(Root,'target.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Target:=SystemDB.GetCollection(ID); Book.Clear; Book.Title:='Protected old'; Book.LibID:='old';
  Book.Folder:='books.zip'; Book.FileName:='old'; Book.FileExt:='.fb2'; Book.Lang:='ru';
  Include(Book.BookProps,bpIsLocal); TAuthorsHelper.Add(Book.Authors,'Protected','Author','');
  Book.BookKey:=CreateBookKey(Target.InsertBook(Book,False,False),ID);
  Target.SetRate(Book.BookKey,4); Target.SetProgress(Book.BookKey,37);
  Target.SetReview(Book.BookKey,'Protected storage failure note');
  Catalogue:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(ID).DBFileName);
  Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
  Stage:=nil; Review:=nil; Worker:=nil; FaultSeen:=False;
  try
    Rows:=ReaderAllCatalogRows(Catalogue); PersonalRows:=ReaderAllCatalogRows(Personal);
    ArchiveHash:=THashSHA2.GetHashStringFromFile(Source); IndexHash:=THashSHA2.GetHashStringFromFile(Input);
    Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Storage failure';
    Profile.Location:=Root; Profile.IndexFile:='update.inpx'; Profile.BooksRoot:=Root;
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil); Folder:=Stage.Folder;
    Review:=TLibraryUpdateReview.Create(Profile,Stage);
    LibraryUpdateTestDatabase:=procedure(DB:TSQLiteDatabase)
      begin
        var Name:=DB.QuerySingleString('SELECT file FROM pragma_database_list WHERE name=''main''');
        if not ExtractFileName(Name).StartsWith('comparison-') then Exit;
        Require(not FaultSeen,'Storage failure injection repeated'); FaultSeen:=True;
        var Pages:=DB.QuerySingleInt('PRAGMA page_count');
        DB.QuerySingleInt('PRAGMA max_page_count='+IntToStr(Pages+1));
      end;
    Worker:=CreateLibraryReviewWorker(ID,Review); Worker.Start; Worker.WaitFor;
    Require(FaultSeen and Assigned(Worker.FatalException) and not Worker.Success and
      not Worker.CommittedChanges and not Review.Ready,'Real SQLITE_FULL did not stop the review');
    Require(Exception(Worker.FatalException).Message.ToLower.Contains('full'),
      'Unexpected review storage error: '+Exception(Worker.FatalException).Message);
    Require((ReaderAllCatalogRows(Catalogue)=Rows) and (ReaderAllCatalogRows(Personal)=PersonalRows),
      'Failed review changed target or personal rows/schema');
    Require((THashSHA2.GetHashStringFromFile(Source)=ArchiveHash) and
      (THashSHA2.GetHashStringFromFile(Input)=IndexHash),'Failed review changed its archive or index');
    FreeAndNil(Worker); LibraryUpdateTestDatabase:=nil; FreeAndNil(Review); FreeAndNil(Stage);
    Require(not TDirectory.Exists(Folder),'Failed review retained its work folder');
    Writeln('PASS real comparison SQLITE_FULL stops before application preserves every target personal row archive and index and removes work'); Flush(Output);
  finally
    LibraryUpdateTestDatabase:=nil; Worker.Free; Review.Free; Stage.Free; Personal.Free; Catalogue.Free;
  end;
end;
