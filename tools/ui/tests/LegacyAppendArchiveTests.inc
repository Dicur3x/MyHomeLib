type
  TLegacyFileUpdateDriver = class
    Visits: Integer;
    procedure Tick(Sender: TObject);
  end;

procedure TLegacyFileUpdateDriver.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TImportProgressFormEx) and (fsModal in Screen.Forms[I].FormState) then
    begin
      var Form:=TImportProgressFormEx(Screen.Forms[I]);
      if (Form.WorkerThread is TManualUpdateThread) and Form.WorkerThread.Finished and
        (Form.btnCancel.Caption='Закрыть') then
      begin
        Inc(Visits);
        Form.btnCancel.Click;
      end;
    end;
end;

procedure TestLegacyAppendArchive(MixedPaths: Boolean);
const
  Folders: array[0..9] of string = ('base.zip','bridge.zip','split.zip','',
    'add-empty.zip','add-zero.zip','different\base.zip','split.7z','bridge.7z','bridge.7z');
  Members: array[0..9] of string = ('same','bridge','same','same','same','same','same','same','bridge-new','bridge');
  LibIDs: array[0..9] of string = ('','legacy','0','','','0','legacy','0','','legacy');
  AliasRow = 9;
  FirstNew = 4;
var
  Root, UpdatePath, OriginalPath, Bodies, FirstState: string;
  CollectionID: Integer;
  Collection: IBookCollection;
  Book: TBookRecord;
  CardIDs: array[0..8] of Integer;
  Driver: TLegacyFileUpdateDriver;
  Timer: TTimer;

  function BookTitle(Index: Integer): string;
  begin
    Result:='Append fixture '+IntToStr(Index);
  end;

  function IndexFolder(Index: Integer; Update: Boolean): string;
  begin
    Result:=Folders[Index];
    if MixedPaths and (((Index=0) and not Update) or (Update and (Index in [1,2,AliasRow]))) then
      Result:=TPath.Combine(Root,Result);
  end;

  procedure CreateArchive(Index: Integer);
  var Path, Work: string; Zip:TZipFile; Sink:TMemoryStream; Files:TArray<string>;
  begin
    Path:=TPath.Combine(Root,Folders[Index]);
    ForceDirectories(ExtractFileDir(Path));
    if SameText(ExtractFileExt(Path),'.zip') then
    begin
      Zip:=TZipFile.Create;
      try
        Zip.Open(Path,zmWrite);
        Zip.Add(TEncoding.UTF8.GetBytes(BookTitle(Index)),Members[Index]+'.txt');
      finally Zip.Free; end;
    end
    else
    begin
      Work:=TPath.Combine(Root,'source-'+IntToStr(Index));
      ForceDirectories(Work);
      Files:=TArray<string>.Create('a','-t7z','-mx=0','-y',Path);
      if Index=AliasRow then
      begin
        var NewMember:=TPath.Combine(Work,Members[AliasRow-1]+'.txt');
        TFile.WriteAllText(NewMember,BookTitle(AliasRow-1),TEncoding.UTF8);
        Files:=Files+[NewMember];
      end;
      var MainMember:=TPath.Combine(Work,Members[Index]+'.txt');
      if Index=AliasRow then TFile.WriteAllText(MainMember,BookTitle(1),TEncoding.UTF8)
      else TFile.WriteAllText(MainMember,BookTitle(Index),TEncoding.UTF8);
      Files:=Files+[MainMember];
      Sink:=TMemoryStream.Create;
      try RunExternalToolToStream(Settings.AppPath+'tools\7zip\7za.exe',Files,Sink);
      finally Sink.Free; end;
    end;
  end;

  procedure WriteIndex(const Path: string; Update: Boolean);
  var Zip:TZipFile; Row:string; Inside:Integer;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(Path,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG;FOLDER;INSNO'),
        'structure.info');
      for var I:=0 to High(Folders) do
      begin
        if (I=3) or ((I>=FirstNew) and not Update) then Continue;
        Inside:=0;
        if I in [1,AliasRow] then Inside:=1;
        Row:='Author,Test:'#4'prose_contemporary:'#4+BookTitle(I)+#4#4#4+Members[I]+#4+
          '100'#4+LibIDs[I]+#4'0'#4'txt'#4'2026-11-18'#4'ru'#4+IndexFolder(I,Update)+#4+IntToStr(Inside)+sLineBreak;
        Zip.Add(TEncoding.UTF8.GetBytes(Row),'page-'+IntToStr(I)+'.inp');
      end;
    finally Zip.Free; end;
  end;

  procedure Apply;
  var Committed,ShowNew:Boolean;
  begin
    Timer.Enabled:=True;
    try
      Require(ApplyPreparedCollectionUpdate(CollectionID,UpdatePath,Settings.AppPath+'append-update.log',False,
        Committed,ShowNew) and Committed and not ShowNew,'The normal file-update dialog did not apply the index');
    finally Timer.Enabled:=False; end;
  end;

  function ProtectedFiles: string;
  begin
    Result:=THashSHA2.GetHashStringFromFile(UpdatePath)+THashSHA2.GetHashStringFromFile(OriginalPath);
    for var I in TArray<Integer>.Create(0,2,4,5,6,7,AliasRow) do
      Result:=Result+THashSHA2.GetHashStringFromFile(TPath.Combine(Root,Folders[I]));
    Result:=Result+THashSHA2.GetHashStringFromFile(TPath.Combine(Root,'same.txt'));
  end;

  procedure Verify(ExpectedNew: Integer);
  var DB:TSQLiteDatabase; Data:IBookIterator; Stream:TStream; Bytes:TBytes;
    Count,Index:Integer;
  begin
    Collection:=SystemDB.GetCollection(CollectionID,True);
    Count:=0; Data:=Collection.GetBookIterator(bmAll,True);
    while Data.Next(Book) do
    begin
      Index:=-1;
      for var Candidate:=0 to High(CardIDs) do
        if Book.Title=BookTitle(Candidate) then begin Index:=Candidate; Break; end;
      Require(Index>=0,'A previously indexed physical member was inserted again: '+Book.Title);
      Inc(Count);
      if CardIDs[Index]=0 then CardIDs[Index]:=Book.BookKey.BookID
      else Require(CardIDs[Index]=Book.BookKey.BookID,'A duplicate replaced or copied a stable card: '+Book.Title);
      Require((Book.Folder=IndexFolder(Index,Index>=FirstNew)) and (Book.FileName=Members[Index]) and
        ((Index=3) or (Book.LibID=LibIDs[Index])),'Incorrect archived or local locator: '+Book.Title);
      Stream:=Book.GetBookStream(True,False);
      Require(Assigned(Stream),'Unreadable indexed book: '+Book.Title);
      try
        SetLength(Bytes,Stream.Size); Stream.ReadBuffer(Bytes,Length(Bytes));
        var Actual:=TEncoding.UTF8.GetString(Bytes).TrimLeft([#$FEFF]);
        Require(Actual=Book.Title,'Wrong physical book chosen for '+Book.Title);
      finally Stream.Free; end;
      if Index in [0,3] then
        Require((Book.Rate=4) and (Book.Progress=40+Index) and
          (Collection.GetReview(Book.BookKey)='Private review '+Book.Title),'Personal data changed for '+Book.Title);
    end;
    Data:=nil;
    Require(Count=Length(CardIDs),'Different archives with the same member name lost entries: '+IntToStr(Count));
    DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(CollectionID).DBFileName);
    try
      Require(DB.QuerySingleInt('SELECT count(*) FROM LastInpxBooks')=ExpectedNew,
        'The latest update list reports the wrong count');
      if ExpectedNew>0 then FirstState:=SBRTable(DB,'Books')
      else Require(SBRTable(DB,'Books')=FirstState,'Reapplying the same index changed book data');
    finally DB.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Legacy append tests require G:');
  FillChar(CardIDs,SizeOf(CardIDs),0);
  Root:=Settings.AppPath+'legacy-append-archives'; ForceDirectories(Root);
  OriginalPath:=TPath.Combine(Root,'original.inpx'); UpdatePath:=TPath.Combine(Root,'append.inpx');
  for var I in TArray<Integer>.Create(0,2,4,5,6,7,AliasRow) do CreateArchive(I);
  TFile.WriteAllText(TPath.Combine(Root,'same.txt'),BookTitle(3),TEncoding.UTF8);
  WriteIndex(OriginalPath,False); WriteIndex(UpdatePath,True); Bodies:=ProtectedFiles;
  CollectionID:=SystemDB.CreateCollection('Legacy append archive fixture',Root,TPath.Combine(Root,'catalog.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  var Importer:=TImportInpxThread.Create(CollectionID,OriginalPath,gtFb2);
  try TOORun(Importer); Require(Importer.Success,'Cannot create the original INPX collection'); finally Importer.Free; end;
  Collection:=SystemDB.GetCollection(CollectionID,True);
  var Existing:=Collection.GetBookIterator(bmAll,False);
  while Existing.Next(Book) do
    for var I:=0 to 2 do
      if Book.Title=BookTitle(I) then CardIDs[I]:=Book.BookKey.BookID;
  Existing:=nil;
  for var I:=0 to 2 do Require(CardIDs[I]>0,'Original anchor card not found: '+BookTitle(I));
  Book:=Default(TBookRecord); Book.Title:=BookTitle(3); Book.LibID:=NewLocalBookID;
  Book.FileName:='same'; Book.FileExt:='.txt'; Book.Lang:='ru'; Book.Date:=Now; Book.Size:=100;
  Include(Book.BookProps,bpIsLocal);
  TAuthorsHelper.Add(Book.Authors,'Author','Local',''); TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
  CardIDs[3]:=Collection.InsertBook(Book,False,False);
  Require(CardIDs[3]>0,'The local card was not created');
  for var I in TArray<Integer>.Create(0,3) do
  begin
    var Key:=CreateBookKey(CardIDs[I],CollectionID);
    Collection.SetRate(Key,4); Collection.SetProgress(Key,40+I);
    Collection.SetReview(Key,'Private review '+BookTitle(I));
  end;
  Driver:=TLegacyFileUpdateDriver.Create; Timer:=TTimer.Create(nil);
  try
    Timer.Enabled:=False; Timer.Interval:=5; Timer.OnTimer:=Driver.Tick;
    Apply; Verify(5);
    Apply; Verify(0);
    Require(Driver.Visits=2,'Did not exercise both real file-update dialogs');
    Require(ProtectedFiles=Bodies,'A source archive or index was modified');
  finally Timer.Free; Driver.Free; end;
  if MixedPaths then
    Writeln('PASS legacy file append matches absolute and relative archive paths in both directions');
  Writeln('PASS legacy file append distinguishes ZIP and 7z members, retains the resolved alias, and repeats cleanly');
  Flush(Output);
end;
