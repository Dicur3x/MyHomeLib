// Include after ReaderCopyIdentityTests/SystemBookRemapTests/AddBook.
// Requires unit_CollectionMetadataSync, unit_MetadataSyncTypes,
// unit_FB2PublisherMetadataReader, unit_PublisherSeriesSource, System.Zip.
// All books, sources, plans and private databases belong to this G-only fixture.
procedure TestCollectionMetadataSync;
var User: ISystemData; Collection, Reopened: IBookCollection;
  Provider: IBookMetadataFillWriter; DB, Personal: TSQLiteDatabase;
  Reader: TFB2PublisherMetadataReader; Plan: TCollectionMetadataPlan;
  Contender, OrdinaryReader: TSQLiteDatabase; Stopwatch: TStopwatch; Blocked: Boolean;
  ContenderError, RootDuring: string; ContenderAttempts: Integer;
  Counts, Applied: TMetadataSyncCounts; Book, Expected, Values: TBookRecord;
  Parsed: TFB2CatalogMetadata; Status: TFB2MetadataStatus; ErrorText: string;
  WorkRoot, UserFile, CatalogFile, BeforeRows, BeforePersonal, ProtectedRows: string;
  ID, I, CreatedID, Calls: Integer; IDs: array[0..4] of Integer;
  Files, Hashes: array[0..4] of string; RootBefore, RawRootBefore: string;
  Updated: TMetadataSyncFields; Failed, Stop: Boolean; Zip: TZipFile;
  ChunkIDs: TArray<Integer>; Field: TMetadataSyncField;
  TraceCount, SnapshotCount: Integer;
  procedure Trace(const Stage: string);
  begin
    if TraceCount>=180 then Exit;
    Inc(TraceCount); Writeln('TRACE metadata sync ',GetTickCount64,' ',Stage); Flush(Output);
  end;

  function XML(const Publish: string; Annotation: Boolean = True): string;
  begin
    Result := '<?xml version="1.0" encoding="utf-8"?>'+
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description>'+
      '<title-info><book-title>Do not replace catalog title</book-title>'+
      '<author><last-name>Do not replace author</last-name></author><lang>uk</lang>'+
      '<sequence name="Do not replace primary cycle" number="88"/>'+
      '<translator><first-name>Имя</first-name><last-name>Человек</last-name></translator>';
    if Annotation then Result := Result+'<annotation><p>Мысль &amp; контекст <emphasis>ё 😀</emphasis></p><p>Вторая строка.</p></annotation>';
    Result := Result+'</title-info><publish-info>'+Publish+'</publish-info></description>'+
      '<body><this deliberately invalid body is not metadata';
  end;

  function Publication: string;
  begin Result := '<publisher>Издательство Ёжик</publisher><city>Киев</city><year>2025</year><isbn>978-fixture</isbn>'; end;

  function CatalogSnapshot(ExceptMetadata: Boolean = False): string;
  var Query, Columns: TSQLiteQuery; SQL, Name, TableName: string;
  begin
    Inc(SnapshotCount); Trace('catalog snapshot '+IntToStr(SnapshotCount)+' begin, omitmetadata='+BoolToStr(ExceptMetadata,True));
    Result := ''; Query := DB.NewQuery('SELECT name,sql FROM sqlite_master WHERE type IN (''table'',''index'',''trigger'') ORDER BY name');
    try
      Query.Open;
      while not Query.Eof do
      begin
        TableName := Query.FieldAsString(0);
        Result := Result+#1+TableName+#2+Query.FieldAsString(1); Query.Next;
      end;
    finally Query.Free; end;
    Trace('catalog snapshot schema done');
    Query := DB.NewQuery('SELECT name FROM sqlite_master WHERE type=''table'' ORDER BY name');
    try
      Query.Open;
      while not Query.Eof do
      begin
        TableName := Query.FieldAsString(0);
        if SnapshotCount<=2 then Trace('snapshot table '+TableName);
        if ExceptMetadata and SameText(TableName,'Books') then
        begin
          SQL := ''; Columns := DB.NewQuery('PRAGMA table_info(Books)');
          try
            Columns.Open;
            while not Columns.Eof do
            begin
              Name := Columns.FieldAsString(1);
              if not (SameText(Name,'Publisher') or SameText(Name,'City') or SameText(Name,'PubYear') or
                SameText(Name,'ISBN') or SameText(Name,'Translators') or SameText(Name,'Annotation') or SameText(Name,'SearchAnnotation')) then
              begin
                if SQL <> '' then SQL := SQL+'||char(31)||';
                SQL := SQL+'typeof("'+Name+'")||char(30)||hex(CAST("'+Name+'" AS BLOB))';
              end;
              Columns.Next;
            end;
          finally Columns.Free; end;
          Result := Result+SBRRows(DB,'SELECT '+SQL+' FROM Books ORDER BY 1');
        end else Result := Result+SBRTable(DB,TableName);
        Query.Next;
      end;
    finally Query.Free; end;
    Trace('catalog snapshot done');
  end;

  procedure ExpectSame(const LabelText: string);
  begin
    Require(CatalogSnapshot = BeforeRows,LabelText+': catalog or schema changed');
    Require(SBRExact(Personal) = BeforePersonal,LabelText+': personal cards/groups/raw BLOBs changed');
  end;

  procedure FillValues;
  begin
    Values := Default(TBookRecord); Values.Publisher := 'Издательство Ёжик'; Values.City := 'Киев';
    Values.PubYear := 2025; Values.ISBN := '978-fixture'; Values.Translators := 'Человек Имя';
    Values.Annotation := 'Мысль & контекст ё 😀'+#13#10+'Вторая строка.';
  end;

  procedure Parse(const Text: string; Want: TFB2MetadataStatus; Annotation: Boolean);
  var Input: TStringStream;
  begin
    Input := TStringStream.Create(Text,TEncoding.UTF8);
    try Status := Reader.ReadCatalogMetadata(Input,Parsed,ErrorText,Annotation);
      Require(Status=Want,'Catalog metadata parser status '+IntToStr(Ord(Status))+': '+ErrorText);
      if Want<>fmsComplete then Require((Parsed.Publisher='') and (Parsed.City='') and
        (Parsed.PubYear=0) and (Parsed.ISBN='') and (Parsed.Translators='') and (Parsed.Annotation=''),
        'Incomplete catalog metadata leaked partial/stale values');
    finally Input.Free; end;
  end;

  procedure ResetEmpty(BookID: Integer);
  begin
    DB.ExecSQL('UPDATE Books SET Publisher='''',City='''',PubYear=0,ISBN='''',Translators='''',Annotation='''' WHERE BookID=?',[BookID]);
  end;

  procedure Preview(const Fields: TMetadataSyncFields);
  begin
    Trace('preview setup begin'); FreeAndNil(Plan); BeforeRows := CatalogSnapshot;
    Trace('preview system snapshot begin'); BeforePersonal := SBRExact(Personal);
    Trace('preview core begin fields='+IntToStr(Ord(msfAnnotation in Fields)));
    Plan := PreviewCollectionMetadata(Collection,Fields,Counts,nil,
      procedure(Checked,Total:Int64)
      begin
        if (Checked<=6) or (Checked mod 100=0) then
        begin Writeln('TRACE metadata core progress ',GetTickCount64,' checked=',Checked,' total=',Total); Flush(Output); end;
      end);
    Trace('preview core returned checked='+IntToStr(Counts.BooksChecked)+' planned='+IntToStr(Counts.BooksPlanned)+' failed='+IntToStr(Counts.BooksFailed));
    Require(Assigned(Plan),'Preview did not return a completed plan');
    Require((Plan.CollectionID=ID) and (Plan.Fields=Fields),'Preview plan lost its options/collection');
    ExpectSame('Read-only preview'); Trace('preview oracle done');
  end;

  procedure RequireSinglePublisherPlan(const LabelText: string);
  var Rows: TStringList; Value: TJSONValue; Obj: TJSONObject;
  begin
    Require((Counts.BooksPlanned=1) and (Counts.FieldCounts[msfPublisher]=1) and
      (Counts.BooksFailed=1),LabelText+': missing publisher plan prerequisite was not reached');
    Rows:=TStringList.Create; Value:=nil;
    try
      Rows.LoadFromFile(Plan.StorageFileName,TEncoding.UTF8);
      Require(Rows.Count=1,LabelText+': publisher plan does not contain exactly one source row');
      Value:=TJSONObject.ParseJSONValue(Rows[0]);
      Require(Value is TJSONObject,LabelText+': publisher source row is not JSON');
      Obj:=TJSONObject(Value);
      Require((Obj.GetValue<Integer>('id')=IDs[0]) and
        (Obj.GetValue<string>('lib')=Expected.LibID) and
        (Obj.GetValue<string>('file')=Expected.FileName) and
        (Obj.GetValue<string>('source')<>''),LabelText+': publisher plan targets a different book/source');
    finally Value.Free; Rows.Free; end;
  end;

  procedure ExpectRejected(const LabelText: string);
  begin
    BeforeRows := CatalogSnapshot; BeforePersonal := SBRExact(Personal); FillValues;
    Require(Provider.FillEmptyMetadata(Expected,Values,METADATA_SYNC_DEFAULT_FIELDS,
      function: Boolean begin Result:=True; end,Updated)=mfrIdentityChanged,
      LabelText+': stale identity accepted');
    Require(Updated=[],'Rejected identity claimed updated fields'); ExpectSame(LabelText);
  end;

begin
  TraceCount:=0; SnapshotCount:=0;
  Trace('start');
  Require(SameText(Copy(ExpandFileName(Settings.AppPath),1,3),'G:\'),'Metadata sync requires isolated G runtime');
  WorkRoot := IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'metadata-sync-'+TGUID.NewGuid.ToString));
  ForceDirectories(WorkRoot); UserFile:=WorkRoot+'personal.dbs2';
  TSystemData_SQLite.CreateSystemTables(UserFile); User:=TSystemData_SQLite.Create(UserFile);
  Plan:=nil; DB:=nil; Personal:=nil; Reader:=TFB2PublisherMetadataReader.Create;
  try
    Parse(XML(Publication),fmsComplete,True); FillValues;
    Require((Parsed.Publisher=Values.Publisher) and (Parsed.City=Values.City) and
      (Parsed.PubYear=2025) and (Parsed.ISBN=Values.ISBN) and
      (Parsed.Translators=Values.Translators) and (Parsed.Annotation=Values.Annotation),
      'Bounded parser did not capture exact publication/translator/annotation metadata');
    Parse(XML(Publication),fmsComplete,False); Require(Parsed.Annotation='','Annotation OFF still captured text');
    Parse('<FictionBook><description><title-info/><publish-info><publisher>Partial',fmsInvalid,True);
    Parse(XML('<publisher xmlns="urn:foreign">Foreign</publisher><city>Safe</city><year>not-a-year</year>'),fmsComplete,False);
    Require((Parsed.Publisher='') and (Parsed.City='Safe') and (Parsed.PubYear=0),'Namespace/invalid-year metadata leaked');
    Parse(XML('<city>'+StringOfChar('x',4097)+'</city>'),fmsInvalid,False);
    Parse(XML('<publisher>Same</publisher><city>First</city><city>Second</city>'),fmsInvalid,False);
    Parse(StringReplace(XML(Publication),'<annotation>','<annotation>'+StringOfChar('x',65537),[]),fmsInvalid,True);
    Writeln('PASS strict complete bounded metadata, namespaces, annotation OFF and parser state reset');

    Trace('create private collection');
    ID:=User.CreateCollection('Metadata fill only',WorkRoot,WorkRoot+'catalog.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    Collection:=User.GetCollection(ID); CatalogFile:=User.GetCollectionInfo(ID).DBFileName;
    DB:=TSQLiteDatabase.Create(CatalogFile); Personal:=TSQLiteDatabase.Create(UserFile);
    DB.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Require(Supports(Collection,IBookMetadataFillWriter,Provider),'SQLite metadata capability missing');
    for I:=0 to High(IDs) do
    begin
      Trace('insert book '+IntToStr(I));
      IDs[I]:=AddBook(Collection,'Sync source '+IntToStr(I),'Preserved author','ru','Preserved primary','prose_contemporary');
      Collection.GetBookRecord(CreateBookKey(IDs[I],ID),Book,True);
      Book.KeyWords:='Preserve keywords'; Book.Rate:=4; Book.Progress:=61; Book.Review:='Личная мысль 😀';
      if I=1 then
      begin Book.Publisher:='Known publisher'; Book.City:='Known city'; Book.PubYear:=1999;
        Book.ISBN:='Known ISBN'; Book.Translators:='Known translators'; Book.Annotation:='Personal existing annotation'; end;
      if I=2 then begin Book.Folder:='archive.zip'; Book.FileName:='inside'; Book.InsideNo:=0; end;
      Collection.UpdateBook(Book); Collection.AddBookSeries(IDs[I],'Preserved secondary',7);
      User.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID,Book); Files[I]:=Book.GetBookFileName;
    end;
    TFile.WriteAllText(Files[0],XML(Publication),TEncoding.UTF8);
    TFile.WriteAllText(Files[1],XML(Publication),TEncoding.UTF8);
    Zip:=TZipFile.Create;
    try Zip.Open(Files[2],zmWrite);
      // Catalog InsideNo=0 is deliberately stale. Name 'inside.fb2' must win,
      // or the foreign publisher/annotation would be written onto this book.
      Zip.Add(TEncoding.UTF8.GetBytes(XML('<publisher>FOREIGN WRONG BOOK</publisher>')),'foreign.fb2',zcStored);
      Zip.Add(TEncoding.UTF8.GetBytes(XML(Publication)),'inside.fb2',zcStored);
    finally Zip.Free; end;
    TFile.WriteAllText(Files[3],'<FictionBook><description><title-info/><publish-info><publisher>Partial',TEncoding.UTF8);
    TFile.WriteAllText(Files[4],'<FictionBook><description><title-info/></description></FictionBook>',TEncoding.UTF8);
    for I:=0 to High(Files) do Hashes[I]:=THashSHA2.GetHashStringFromFile(Files[I]);
    Trace('book files ready; ZIP missing-name descriptor begin');
    Collection.GetBookRecord(CreateBookKey(IDs[2],ID),Book,False);
    var DescriptorSource:=TPublisherSeriesSource.Create(nil);
    try
      var BadLocator:=Book; BadLocator.FileName:='absent'; Failed:=False;
      try var WrongStream:=DescriptorSource.OpenDescriptor(BadLocator); WrongStream.Free;
      except on E: Exception do Failed:=True; end;
      Require(Failed,'Missing ZIP name accepted a foreign ordinal');
    finally DescriptorSource.Free; end;
    Trace('missing-name descriptor done; duplicate descriptor begin');
    var DuplicateArchive:=WorkRoot+'duplicate.zip'; Zip:=TZipFile.Create;
    try Zip.Open(DuplicateArchive,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes(XML(Publication)),'same.fb2',zcStored);
      Zip.Add(TEncoding.UTF8.GetBytes(XML('<publisher>Foreign duplicate</publisher>')),'SAME.FB2',zcStored);
    finally Zip.Free; end;
    Book.Folder:='duplicate.zip'; Book.FileName:='same'; DescriptorSource:=TPublisherSeriesSource.Create(nil);
    try Failed:=False;
      try var WrongStream:=DescriptorSource.OpenDescriptor(Book); WrongStream.Free;
      except on E: Exception do Failed:=True; end;
      Require(Failed,'Ambiguous ZIP member accepted legacy ordinal');
    finally DescriptorSource.Free; end;
    Trace('duplicate descriptor done; single descriptor begin');
    var SingleArchive:=WorkRoot+'single-foreign.zip'; Zip:=TZipFile.Create;
    try Zip.Open(SingleArchive,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes(XML('<publisher>Single foreign</publisher>')),'foreign.fb2',zcStored);
    finally Zip.Free; end;
    Book.Folder:='single-foreign.zip'; Book.FileName:='missing'; DescriptorSource:=TPublisherSeriesSource.Create(nil);
    try Failed:=False;
      try var WrongStream:=DescriptorSource.OpenDescriptor(Book,False); WrongStream.Free;
      except on E: Exception do Failed:=True; end;
      Require(Failed,'Single-member archive guessed a foreign filename');
    finally DescriptorSource.Free; end;
    // Simulate method98 central/local headers only; the false-helper boundary
    // must reject this before attempting any decompression or tool discovery.
    Trace('single descriptor done; PPMd descriptor begin');
    var PPMdArchive:=WorkRoot+'metadata-ppmd.zip'; Zip:=TZipFile.Create;
    try Zip.Open(PPMdArchive,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes(XML(Publication)),'inside.fb2',zcStored);
    finally Zip.Free; end;
    var PPMdBytes:=TFile.ReadAllBytes(PPMdArchive);
    for var At:=0 to Length(PPMdBytes)-12 do
      if (PPMdBytes[At]=$50) and (PPMdBytes[At+1]=$4B) then
      begin
        if (PPMdBytes[At+2]=$03) and (PPMdBytes[At+3]=$04) then
        begin PPMdBytes[At+8]:=98; PPMdBytes[At+9]:=0; end;
        if (PPMdBytes[At+2]=$01) and (PPMdBytes[At+3]=$02) then
        begin PPMdBytes[At+10]:=98; PPMdBytes[At+11]:=0; end;
      end;
    TFile.WriteAllBytes(PPMdArchive,PPMdBytes);
    Book.Folder:='metadata-ppmd.zip'; Book.FileName:='inside'; DescriptorSource:=TPublisherSeriesSource.Create(nil);
    try Failed:=False;
      try var WrongStream:=DescriptorSource.OpenDescriptor(Book,False); WrongStream.Free;
      except on E: Exception do Failed:=True; end;
      Require(Failed,'Invalid synthetic PPMd payload was accepted as complete metadata');
    finally DescriptorSource.Free; end;
    Trace('PPMd descriptor done; protected snapshot begin');
    var MissingBatch:=Provider.ReadMetadataBatch(0,100);
    Require((Length(MissingBatch)=5) and (Trim(MissingBatch[1].Publisher)<>'') and
      (Trim(MissingBatch[1].City)<>'') and (MissingBatch[1].PubYear=1999) and
      (Trim(MissingBatch[1].ISBN)<>'') and (Trim(MissingBatch[1].Translators)<>'') and
      (Trim(MissingBatch[1].Annotation)<>''),'Source-only metadata batch misclassified a known nonempty field');
    Collection.GetBookRecord(CreateBookKey(IDs[1],ID),Expected,True); FillValues;
    BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal);
    Require(Provider.FillEmptyMetadata(Expected,Values,METADATA_SYNC_DEFAULT_FIELDS+[msfAnnotation],
      function: Boolean begin Result:=True; end,Updated)=mfrUnchanged,
      'Known-only metadata writer claimed a change or falsely failed');
    Require(Updated=[],'Known-only writer emitted updated fields'); ExpectSame('Known nonempty metadata');
    ProtectedRows:=CatalogSnapshot(True); Trace('protected snapshot done');
    // The catalog already has all selected values. A missing source must not
    // be opened or reported as a failure solely to rediscover those values.
    TFile.Move(Files[1],Files[1]+'.held');
    try Preview(METADATA_SYNC_DEFAULT_FIELDS);
    finally TFile.Move(Files[1]+'.held',Files[1]); end;
    Writeln('PASS metadata preview skips complete selected fields without opening unavailable book sources');
    Require((Counts.BooksTotal=5) and (Counts.BooksChecked=5) and (Counts.BooksPlanned=2) and
      (Counts.BooksFailed=1) and (Counts.AnnotationBytes=0),'Default preview counts differ from actual missing fields');
    Require((Length(Counts.ErrorExamples)=1) and Counts.ErrorExamples[0].Contains('#') and
      (Counts.ErrorCounts[mrfInvalidMetadata]=1),'Metadata errors lost reason counters or source examples');
    for Field:=msfPublisher to msfTranslators do Require(Counts.FieldCounts[Field]=2,'Default field count incorrect');
    Require(Counts.FieldCounts[msfAnnotation]=0,'Annotation opted in implicitly'); BeforePersonal:=SBRExact(Personal);
    Trace('apply default begin');
    Require(ApplyCollectionMetadata(Collection,Plan,Applied) and (Applied.BooksPlanned=2), 'Default Apply did not commit exact planned books');
    Trace('apply default returned committed='+IntToStr(Applied.BooksPlanned));
    Require((CatalogSnapshot(True)=ProtectedRows) and (SBRExact(Personal)=BeforePersonal),
      'Metadata sync changed any unrelated catalog field/relation/user card');
    for I:=0 to 2 do
    begin
      Collection.GetBookRecord(CreateBookKey(IDs[I],ID),Book,True);
      if I=1 then Require((Book.Publisher='Known publisher') and (Book.City='Known city') and
        (Book.PubYear=1999) and (Book.ISBN='Known ISBN') and (Book.Translators='Known translators') and
        (Book.Annotation='Personal existing annotation'),'Nonempty data overwritten')
      else Require((Book.Publisher=Values.Publisher) and (Book.City=Values.City) and (Book.PubYear=2025) and
        (Book.ISBN=Values.ISBN) and (Book.Translators=Values.Translators) and (Book.Annotation=''),
        'Default filled fields or disabled annotation incorrect');
    end;
    Preview(METADATA_SYNC_DEFAULT_FIELDS); Require(Counts.BooksPlanned=0,'Repeat default preview was not idempotent');
    BeforeRows:=CatalogSnapshot; Require(ApplyCollectionMetadata(Collection,Plan,Applied) and (Applied.BooksPlanned=0),'Empty repeat Apply differs');
    ExpectSame('Repeat Apply');
    Preview([msfAnnotation]); Require((Counts.BooksPlanned=2) and (Counts.AnnotationBytes>0),'Annotation opt-in preview incorrect');
    Require(ApplyCollectionMetadata(Collection,Plan,Applied) and (Applied.BooksPlanned=2),'Opt-in annotation Apply failed');
    Collection.GetBookRecord(CreateBookKey(IDs[0],ID),Book,True); Require(Book.Annotation=Values.Annotation,'Annotation plain context changed');
    Require(DB.QuerySingleString('SELECT SearchAnnotation FROM Books WHERE BookID=?',[IDs[0]])<>'','Annotation search value was not maintained');
    Require(SBRExact(Personal)=BeforePersonal,'Opt-in annotation changed personal cards');
    Reopened:=User.GetCollection(ID,True); Reopened.GetBookRecord(CreateBookKey(IDs[2],ID),Book,True);
    Require((Book.Publisher=Values.Publisher) and (Book.Annotation=Values.Annotation),'Filled data lost after reopen'); Reopened:=nil;
    Writeln('PASS real FB2/ZIP read-only preview, default/annotation fill-only, unrelated fields/personal BLOBs, idempotent reopen');

    Trace('stale-identity and rollback section begin');
    ResetEmpty(IDs[0]); Collection.GetBookRecord(CreateBookKey(IDs[0],ID),Expected,True);
    DB.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=?',['replacement-B',IDs[0]]); ExpectRejected('Reused positive ID');
    DB.ExecSQL('UPDATE Books SET LibID=?,FileName=? WHERE BookID=?',[Expected.LibID,'moved-physical',IDs[0]]); ExpectRejected('Changed physical locator');
    DB.ExecSQL('UPDATE Books SET FileName=? WHERE BookID=?',[Expected.FileName,IDs[0]]);
    RootBefore:=Provider.MetadataCollectionRoot;
    RawRootBefore:=Personal.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[ID]);
    Require(SameText(RawRootBefore,ExtractRelativePath(Settings.WorkPath,RootBefore)),
      'Created collection root does not use its documented WorkPath-relative storage');
    User.SetProperty(ID,PROP_ROOTFOLDER,WorkRoot+'different');
    try
      Require(SameText(Personal.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[ID]),
        ExtractRelativePath(Settings.WorkPath,WorkRoot+'different')),
        'Changed collection root used DataPath-relative storage');
      Require(SameText(ExcludeTrailingPathDelimiter(ExpandFileName(Provider.MetadataCollectionRoot)),
        ExcludeTrailingPathDelimiter(ExpandFileName(WorkRoot+'different'))),
        'Changed collection root did not resolve back to the requested directory');
      ExpectRejected('Changed collection root');
    finally User.SetProperty(ID,PROP_ROOTFOLDER,RootBefore); end;
    Require(Personal.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[ID])=RawRootBefore,
      'Restoring a collection root changed its exact raw stored relative path');
    Require(SameText(ExcludeTrailingPathDelimiter(ExpandFileName(Provider.MetadataCollectionRoot)),
      ExcludeTrailingPathDelimiter(ExpandFileName(RootBefore))),
      'Restored collection root no longer resolves to its actual source directory');
    Reopened:=User.GetCollection(ID,True);
    try
      Reopened.GetBookRecord(CreateBookKey(IDs[0],ID),Book,True);
      Require(SameText(TPath.GetFullPath(Book.GetBookFileName),TPath.GetFullPath(Files[0])) and
        FileExists(Book.GetBookFileName),'Reopened root roundtrip lost the original physical source');
    finally Reopened:=nil; end;
    Trace('root roundtrip raw/resolved/reopen/source verified');
    Preview([msfPublisher]); RequireSinglePublisherPlan('Physical source change');
    TFile.WriteAllText(Files[0],XML('<publisher>Changed source</publisher>'),TEncoding.UTF8);
    BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal);
    Require(ApplyCollectionMetadata(Collection,Plan,Applied) and (Applied.BooksPlanned=0) and
      (Applied.BooksSkipped=1),'Physical source change was not rejected'); ExpectSame('Source changed after preview');
    TFile.WriteAllText(Files[0],XML(Publication),TEncoding.UTF8); Hashes[0]:=THashSHA2.GetHashStringFromFile(Files[0]);
    Preview([msfPublisher]); RequireSinglePublisherPlan('Late nonempty field');
    DB.ExecSQL('UPDATE Books SET Publisher=''Saved after preview'' WHERE BookID=?',[IDs[0]]);
    BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal);
    Require(ApplyCollectionMetadata(Collection,Plan,Applied) and (Applied.BooksPlanned=0),'Late nonempty field overwritten'); ExpectSame('Late nonempty value');
    ResetEmpty(IDs[0]); Collection.GetBookRecord(CreateBookKey(IDs[0],ID),Expected,True); FillValues;
    BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal);
    Require(Provider.FillEmptyMetadata(Expected,Values,METADATA_SYNC_DEFAULT_FIELDS,
      function: Boolean begin Result:=False; end,Updated)=mfrIdentityChanged,'False source CAS accepted'); ExpectSame('False source guard');
    Provider.BeginMetadataFillBatch;
    try Require(Provider.FillEmptyMetadata(Expected,Values,METADATA_SYNC_DEFAULT_FIELDS,
      function: Boolean begin Result:=True; end,Updated)=mfrChanged,'Nested fill did not execute');
    finally Provider.EndMetadataFillBatch(False); end;
    ExpectSame('Explicit outer rollback');
    Trace('trigger section begin');
    for var FailureMode in TArray<string>.Create('ABORT','IGNORE','ROLLBACK') do
    begin
      if FailureMode='IGNORE' then
        DB.ExecSQL('CREATE TRIGGER FixtureMetadataFailure BEFORE UPDATE OF City ON Books BEGIN SELECT RAISE(IGNORE); END')
      else DB.ExecSQL('CREATE TRIGGER FixtureMetadataFailure BEFORE UPDATE OF City ON Books BEGIN SELECT RAISE('+FailureMode+',''fixture failure''); END');
      BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal); Failed:=False;
      try Provider.FillEmptyMetadata(Expected,Values,METADATA_SYNC_DEFAULT_FIELDS,
        function: Boolean begin Result:=True; end,Updated); except on E: Exception do Failed:=True; end;
      Require(Failed,'Trigger '+FailureMode+' falsely claimed save'); ExpectSame('Atomic '+FailureMode);
      DB.ExecSQL('DROP TRIGGER FixtureMetadataFailure');
    end;
    Trace('root guard contender begin');
    // A competing real SystemDB connection must not move the root between
    // the row CAS and catalog COMMIT. Normal independent reads still work.
    BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal);
    Contender:=TSQLiteDatabase.Create(UserFile); OrdinaryReader:=TSQLiteDatabase.CreateReadOnly(UserFile);
    try
      // The independent contender owns its timeout. The general writer
      // constructor defaults to 10 seconds, longer than this gate's deadline.
      Writeln('TRACE metadata root contender default_busy_ms=',Contender.QuerySingleInt('PRAGMA busy_timeout'));
      Contender.SetTimeout(250);
      Require(Contender.QuerySingleInt('PRAGMA busy_timeout')=250,'Private contender timeout was not configured');
      Blocked:=False; ContenderError:=''; ContenderAttempts:=0; Stopwatch:=TStopwatch.StartNew;
      Flush(Output);
      Require(Provider.FillEmptyMetadata(Expected,Values,[msfPublisher],
        function: Boolean
        begin
          Require(OrdinaryReader.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[ID])<>'',
            'Root reservation blocked ordinary user-data reads');
          Inc(ContenderAttempts);
          RootDuring:=OrdinaryReader.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[ID]);
          Writeln('TRACE metadata root before attempt=',ContenderAttempts,' elapsed_ms=',Stopwatch.ElapsedMilliseconds,
            ' rawroot=',RootDuring); Flush(Output);
          try Contender.ExecSQL('UPDATE Bases SET RootFolder=? WHERE DatabaseID=?',[WorkRoot+'concurrent',ID]);
          except
            on E: ESQLiteException do
            begin
              ContenderError:=E.ClassName+': '+E.Message;
              Blocked:=ContainsText(E.Message,'locked') or ContainsText(E.Message,'busy');
            end;
          end;
          Writeln('TRACE metadata root after attempt=',ContenderAttempts,' blocked=',Blocked,
            ' elapsed_ms=',Stopwatch.ElapsedMilliseconds,' exception=',ContenderError,
            ' current_rawroot=',OrdinaryReader.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[ID]));
          Flush(Output);
          Require(OrdinaryReader.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[ID])=RootDuring,
            'Concurrent contender changed the reserved root before commit');
          Result:=Blocked;
        end,Updated)=mfrChanged,'Root guard prevented legitimate safe fill');
      Writeln('TRACE metadata root committed elapsed_ms=',Stopwatch.ElapsedMilliseconds,' blocked=',Blocked,
        ' attempts=',ContenderAttempts,' resolved=',Provider.MetadataCollectionRoot); Flush(Output);
      Require(Blocked and (ContenderAttempts>0) and (Stopwatch.ElapsedMilliseconds<5000),
        'Concurrent root writer was accepted or wait was unbounded: '+IntToStr(Stopwatch.ElapsedMilliseconds)+'ms '+ContenderError);
      Require(SBRExact(Personal)=BeforePersonal,'Root guard changed SystemDB rows or let another root commit');
      Require(Provider.MetadataCollectionRoot=RootBefore,'Concurrent root escaped the reservation');
      // The reservation is released once the catalog fill completed. This
      // acquires an independent write transaction without changing any row.
      Contender.Start('', 'IMMEDIATE');
      try Require(Contender.InTransaction,'Root guard left the independent writer unavailable');
      finally Contender.Rollback; end;
      Require(SBRExact(Personal)=BeforePersonal,'Root release probe changed SystemDB rows');
    finally OrdinaryReader.Free; Contender.Free; end;
    ResetEmpty(IDs[0]);
    // Already active SystemDB transactions are retained rather than rolled back.
    User.BeginDataUpdate;
    try
      BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal); Failed:=False;
      try Provider.FillEmptyMetadata(Expected,Values,[msfPublisher],
        function: Boolean begin Result:=True; end,Updated);
      except on E: Exception do Failed:=True; end;
      Require(Failed,'Existing SystemDB transaction was silently joined'); ExpectSame('Existing SystemDB transaction');
    finally User.EndDataUpdate(False); end;
    Preview([msfPublisher]);
    TFile.AppendAllText(Plan.StorageFileName,'{}'+#10,TEncoding.UTF8);
    BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal); Failed:=False;
    try ApplyCollectionMetadata(Collection,Plan,Applied); except on E: Exception do Failed:=True; end;
    Require(Failed and (Applied.BooksPlanned=0),'Tampered plan was applied or claimed a commit'); ExpectSame('Tampered spool');
    Writeln('PASS stale ID/path/root/source/late edits fail closed; ABORT/IGNORE/ROLLBACK and outer rollback preserve exact rows');

    BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal); FreeAndNil(Plan);
    Plan:=PreviewCollectionMetadata(Collection,METADATA_SYNC_DEFAULT_FIELDS,Counts,
      function: Boolean begin Result:=True; end);
    Require(Plan=nil,'Canceled preview produced usable plan'); ExpectSame('Canceled preview');
    Trace('205-book cancellation setup begin');
    SetLength(ChunkIDs,205);
    for I:=0 to High(ChunkIDs) do
    begin
      CreatedID:=AddBook(Collection,'Chunk '+IntToStr(I),'Own author','ru','','prose_contemporary'); ChunkIDs[I]:=CreatedID;
      Collection.GetBookRecord(CreateBookKey(CreatedID,ID),Book,False);
      TFile.WriteAllText(Book.GetBookFileName,XML('<publisher>Chunk publisher</publisher>',False),TEncoding.UTF8);
    end;
    Trace('205-book setup done; cancellation preview begin');
    Preview([msfPublisher]); BeforeRows:=CatalogSnapshot; BeforePersonal:=SBRExact(Personal);
    // The callback reads the writer's own transaction. It becomes canceled
    // only after the last row in the first chunk was updated, before COMMIT.
    // A separate connection could not see this uncommitted marker.
    var ProbeKey:=CreateBookKey(ChunkIDs[98],ID);
    Require(not ApplyCollectionMetadata(Collection,Plan,Applied,
      function: Boolean
      var Probe: TBookRecord;
      begin
        Collection.GetBookRecord(ProbeKey,Probe,False);
        Result:=Probe.Publisher='Chunk publisher';
      end),'Last-row cancellation falsely completed');
    Require((Applied.BooksPlanned=0) and (Applied.BooksFailed=0),
      'Cancellation immediately before COMMIT retained partial chunk or became an error');
    ExpectSame('Cancel immediately before COMMIT');
    Stop:=False; Calls:=0; BeforePersonal:=SBRExact(Personal);
    Require(not ApplyCollectionMetadata(Collection,Plan,Applied,
      function: Boolean begin Result:=Stop; end,
      procedure(Checked,Total:Int64) begin Inc(Calls); if Checked>=100 then Stop:=True; end),
      'Cancellation reported full completion');
    Require((Applied.BooksPlanned=100) and (Calls=1),'Cancellation retained incomplete chunk or lost committed count');
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE Publisher=''Chunk publisher''')=99,
      'Cancel changed more rows than its committed first chunk');
    Require(SBRExact(Personal)=BeforePersonal,'Chunk cancellation changed personal records');
    Writeln('PASS canceled preview writes nothing; cancellation retains exactly the first durable chunk');
    for I:=0 to High(Files) do Require(THashSHA2.GetHashStringFromFile(Files[I])=Hashes[I], 'Metadata sync rewrote source book/archive');
  finally
    Trace('cleanup begin');
    Plan.Free; Reader.Free; Provider:=nil; Reopened:=nil;
    DB.Free; Personal.Free; Collection:=nil; User:=nil;
  end;
end;
