// All writes stay inside the isolated native regression runtime on G:.
procedure TestRefactorTransactions;
var Root, NewGroup, FailureSQL: string; CID, ID, Calls: Integer;
  Collection: IBookCollection; Books: array[0..1] of TBookRecord;
  Book: TBookRecord; Data: TUserData; DB, CatalogDB: TSQLiteDatabase;
  Failed: Boolean; Revision: string; Restorer: ICatalogUserDataRestorer;
begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'refactor-import-'+TGUID.NewGuid.ToString);
  ForceDirectories(Root);
  CID:=SystemDB.CreateCollection('Atomic legacy fixture',Root,Root+'catalog.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID);
  for var I:=0 to 1 do
  begin
    Book.Clear; Book.Title:='Atomic import '+IntToStr(I); Book.LibID:='atomic-'+IntToStr(I);
    Book.FileName:='source'+IntToStr(I); Book.FileExt:='.fb2'; Book.Lang:='ru';
    Book.Rate:=1; Book.Progress:=11; Book.Review:='Old review ё';
    TAuthorsHelper.Add(Book.Authors,'Own','Fixture','');
    ID:=Collection.InsertBook(Book,False,False);
    Collection.GetBookRecord(CreateBookKey(ID,CID),Books[I],True);
    SystemDB.AddBookToGroup(Books[I].BookKey,1,Books[I]);
  end;
  Data:=TUserData.Create; DB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
  CatalogDB:=TSQLiteDatabase.Create(Root+'catalog.hlc2');
  try
    for var I:=0 to 1 do Data.Extras.AddExtra(Books[I].BookKey.BookID,Books[I].LibID,4+I,80+I,'Imported review ё');
    NewGroup:='Atomic group '+TGUID.NewGuid.ToString;
    Data.Groups.AddGroup(0,NewGroup).AddBook(Books[0].BookKey.BookID,Books[0].LibID);
    for var Failure:=0 to 2 do
    begin
      case Failure of
        0: FailureSQL:='CREATE TRIGGER OwnImportAbort BEFORE UPDATE OF Rate ON Books WHEN NEW.DatabaseID='+IntToStr(CID)+
          ' AND NEW.BookID='+IntToStr(Books[1].BookKey.BookID)+' BEGIN SELECT RAISE(ABORT,''own system failure''); END';
        1: FailureSQL:='CREATE TRIGGER OwnImportAbort BEFORE INSERT ON Groups WHEN NEW.GroupName='+QuotedStr(NewGroup)+
          ' BEGIN SELECT RAISE(ABORT,''own group failure''); END';
        2: FailureSQL:='CREATE TRIGGER OwnImportAbort BEFORE UPDATE OF Rate ON Books WHEN NEW.BookID='+IntToStr(Books[1].BookKey.BookID)+
          ' BEGIN SELECT RAISE(ABORT,''own catalog failure''); END';
      end;
      if Failure=2 then CatalogDB.ExecSQL(FailureSQL) else DB.ExecSQL(FailureSQL);
      Calls:=0; Failed:=False;
      try
        Collection.ImportUserData(Data,procedure(const Key: TBookKey; Extra: TBookExtra) begin Inc(Calls); end);
      except on E: ESQLiteException do Failed:=True; end;
      Require(Failed and (Calls=0),'Failed import notified UI or did not propagate its real SQL error');
      for var I:=0 to 1 do
      begin
        Collection.GetBookRecord(Books[I].BookKey,Book,True);
        Require((Book.Rate=1) and (Book.Progress=11) and (Book.Review=Books[I].Review),
          'Failed import left partial catalog data');
        Require(DB.QuerySingleInt('SELECT Rate FROM Books WHERE DatabaseID=? AND BookID=?',
          [CID,Book.BookKey.BookID])=1,'Failed import left partial personal data');
      end;
      Require((DB.QuerySingleInt('SELECT COUNT(*) FROM Groups WHERE GroupName=?',[NewGroup])=0) and
        (Data.Groups[0].GroupID=0),'Failed import left a group or changed retry mappings');
      if Failure=2 then CatalogDB.ExecSQL('DROP TRIGGER OwnImportAbort') else DB.ExecSQL('DROP TRIGGER OwnImportAbort');
    end;
    Calls:=0;
    Collection.ImportUserData(Data,procedure(const Key: TBookKey; Extra: TBookExtra) begin Inc(Calls); end);
    Require((Calls=2) and (Data.Groups[0].GroupID>0),'Successful atomic import did not commit mappings and notifications');
    for var I:=0 to 1 do
    begin
      Collection.GetBookRecord(Books[I].BookKey,Book,True);
      Require((Book.Rate=4+I) and (Book.Progress=80+I) and (Book.Review='Imported review ё'),
        'Successful atomic import lost partial fields');
    end;
    Require(Supports(Collection,ICatalogUserDataRestorer,Restorer),'Catalog restore interface is missing');
    CatalogDB.ExecSQL('UPDATE Books SET Rate=2 WHERE BookID=?',[Books[0].BookKey.BookID]);
    DB.ExecSQL('CREATE TRIGGER OwnBulkRestoreAbort BEFORE UPDATE ON Books BEGIN SELECT RAISE(ABORT,''bulk restore touched system cards''); END');
    try
      Revision:=SystemDB.GetDataRevision;
      Collection.BeginBulkOperation;
      try
        Restorer.RestoreCatalogUserData(Data);
        Collection.GetBookRecord(Books[0].BookKey,Book,True);
        Require((Book.Rate=4) and (Book.Progress=80) and (Book.Review='Imported review ё'),
          'Bulk restore did not use its existing catalog transaction');
      finally Collection.EndBulkOperation(False); end;
      Require((CatalogDB.QuerySingleInt('SELECT Rate FROM Books WHERE BookID=?',[Books[0].BookKey.BookID])=2) and
        (SystemDB.GetDataRevision=Revision),'Canceled bulk restore changed durable catalog or personal data');
      Writeln('PASS refactor bulk catalog restore rolls back without touching system cards before remapping');
    finally DB.ExecSQL('DROP TRIGGER OwnBulkRestoreAbort'); Restorer:=nil; end;
    Data.Extras.Clear; Data.Groups.Clear;
    Data.Extras.AddExtra(Books[0].BookKey.BookID,Books[0].LibID,0,0,'');
    CatalogDB.ExecSQL('CREATE TRIGGER OwnNoopAbort BEFORE UPDATE ON Books BEGIN SELECT RAISE(ABORT,''empty import wrote catalog''); END');
    DB.ExecSQL('CREATE TRIGGER OwnNoopAbort BEFORE UPDATE ON Books BEGIN SELECT RAISE(ABORT,''empty import wrote personal data''); END');
    try
      Revision:=SystemDB.GetDataRevision;
      Collection.ImportUserData(Data,nil);
      Require(Revision=SystemDB.GetDataRevision,'Empty legacy fields changed the personal-data revision');
    finally
      CatalogDB.ExecSQL('DROP TRIGGER OwnNoopAbort'); DB.ExecSQL('DROP TRIGGER OwnNoopAbort');
    end;
    Writeln('PASS refactor import rolls back catalog personal rows and groups on three actual SQL failures; notifies only after commit');
  finally CatalogDB.Free; DB.Free; Data.Free; end;
end;

procedure TestRefactorNoteLookup;
var Root, Profile, Identity, SavedCatalog, ProfileHash, NotesHash: string;
  CID, ID: Integer; Collection: IBookCollection; Book, Found: TBookRecord;
  JSON, Row: TJSONObject; Rows: TJSONArray; Ini: TMemIniFile;
  IDs: TArray<Integer>; Note: TReaderAnnotation; Started: TStopwatch; Calls: Integer; Fields: TArray<string>;
begin
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'refactor-notes-'+TGUID.NewGuid.ToString);
  ForceDirectories(Root); Profile:=Root+'reader.ini';
  CID:=SystemDB.CreateCollection('Batch notes fixture',Root,Root+'catalog.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst'); Collection:=SystemDB.GetCollection(CID);
  Book.Clear; Book.Title:='Quoted O''Reilly ё'; Book.LibID:='stable-own-note';
  Book.FileName:='source'; Book.FileExt:='.fb2'; Book.Lang:='ru';
  TAuthorsHelper.Add(Book.Authors,'Own','Fixture','');
  ID:=Collection.InsertBook(Book,False,False); Collection.GetBookRecord(CreateBookKey(ID,CID),Book,False);
  Identity:=ReaderNoteIdentity(ReaderHistoryName(Book,''));
  JSON:=TJSONObject.Create; Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
  try
    JSON.AddPair('version',TJSONNumber.Create(1)); Rows:=TJSONArray.Create; JSON.AddPair('notes',Rows);
    for var I:=0 to 9999 do
    begin
      Row:=TJSONObject.Create; Rows.AddElement(Row); Row.AddPair('id',IntToStr(I));
      if I=0 then Row.AddPair('book',Identity) else Row.AddPair('book','missing-'+IntToStr(I));
      if Odd(I) then Row.AddPair('bookTitle','Missing O''Reilly ё '+IntToStr(I))
      else Row.AddPair('bookTitle',Book.Title);
      Row.AddPair('text','Own note');
      Row.AddPair('position',TJSONNumber.Create(0));
      if I=0 then SavedCatalog:=Identity else SavedCatalog:='missing-'+IntToStr(I);
      Ini.WriteInteger('Book.'+SavedCatalog,'CollectionID',CID);
      Ini.WriteInteger('Book.'+SavedCatalog,'CatalogBookID',100000+I);
      Ini.WriteString('Book.'+SavedCatalog,'LibID','missing-lib-'+IntToStr(I));
    end;
    Ini.UpdateFile; TFile.WriteAllText(Root+'reader-notes.json',JSON.ToJSON,TEncoding.UTF8);
  finally Ini.Free; JSON.Free; end;
  ProfileHash:=THashSHA2.GetHashStringFromFile(Profile); NotesHash:=THashSHA2.GetHashStringFromFile(Root+'reader-notes.json');
  StartSQLiteProfile; Started:=TStopwatch.StartNew;
  IDs:=ReaderNoteBookIDs(SystemDB,Profile,CID); Started.Stop;
  SaveSQLiteProfile(Root+'lookup.tsv'); StopSQLiteProfile;
  Calls:=0;
  for var Line in TFile.ReadAllLines(Root+'lookup.tsv',TEncoding.UTF8) do
  begin
    Fields:=Line.Split([#9]);
    if Length(Fields)>=3 then Inc(Calls,StrToIntDef(Fields[2],0));
  end;
  Require((Calls>0) and (Calls<4000),'Notes-only lookup resumed per-note SQL work');
  Require((Length(IDs)=1) and (IDs[0]=ID),'Batched title fallback lost exact identity or expanded duplicate titles');
  Require(Started.ElapsedMilliseconds<10000,'10000 note catalog lookup exceeded ten seconds');
  Writeln('PROFILE refactor note_lookup records=10000 sql_operations=',Calls,' elapsed_ms=',Started.ElapsedMilliseconds,' sql=',Root+'lookup.tsv');
  Collection:=nil; SystemDB.ClearCollectionCache;
  SavedCatalog:=Root+'catalog.offline'; Require(RenameFile(Root+'catalog.hlc2',SavedCatalog),'Cannot detach own catalog');
  try
    IDs:=ReaderNoteBookIDs(SystemDB,Profile,CID); Require(Length(IDs)=0,'Missing catalog returned note IDs');
    Note:=Default(TReaderAnnotation); Note.BookID:=Identity; Note.BookTitle:=Book.Title;
    Require(not FindReaderNoteBook(SystemDB,Profile,Note,CID,Found),'Missing catalog found an unrelated book');
    Require(not FileExists(Root+'catalog.hlc2'),'Note lookup recreated a missing catalog');
    Require((THashSHA2.GetHashStringFromFile(Profile)=ProfileHash) and
      (THashSHA2.GetHashStringFromFile(Root+'reader-notes.json')=NotesHash),'Read-only lookup changed notes or bindings');
  finally Require(RenameFile(SavedCatalog,Root+'catalog.hlc2'),'Cannot restore own offline catalog'); end;
  Writeln('PASS refactor batched notes retain exact identities and quoted titles; missing catalogs and note bytes remain unchanged');
end;

procedure RefactorSlowConverter;
var SI: TStartupInfo; PI: TProcessInformation; Command: string;
begin
  Require(TPath.GetFullPath(ParamStr(2)).StartsWith('G:\',True),'Child fixture must stay on G:');
  TFile.WriteAllText(ParamStr(2),IntToStr(GetCurrentProcessId),TEncoding.UTF8);
  if ParamStr(1)='refactor-slow-converter' then
  begin
    FillChar(SI,SizeOf(SI),0); SI.cb:=SizeOf(SI);
    Command:='"'+ParamStr(0)+'" refactor-slow-leaf "'+ParamStr(2)+'.leaf"'; UniqueString(Command);
    if not CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,nil,SI,PI) then RaiseLastOSError;
    CloseHandle(PI.hProcess); CloseHandle(PI.hThread);
  end;
  Sleep(60000);
end;

procedure TestRefactorConverterCancel;
var PIDFile: string; Started: TStopwatch; ExitCode: Cardinal; Process: THandle; PID: DWORD; Success: Boolean;
begin
  PIDFile:=Settings.AppPath+'own-converter-'+TGUID.NewGuid.ToString+'.pid'; Started:=TStopwatch.StartNew;
  Success:=ExecAndWait(ParamStr(0),'refactor-slow-converter "'+PIDFile+'"',SW_HIDE,ExitCode,
    function: Boolean begin Result:=FileExists(PIDFile+'.leaf') or (Started.ElapsedMilliseconds>3000); end);
  Started.Stop;
  Require(not Success and (ExitCode=ERROR_CANCELLED) and (Started.ElapsedMilliseconds<4000),
    'Legacy converter did not acknowledge cancellation promptly');
  for var Name in [PIDFile,PIDFile+'.leaf'] do
  begin
    Require(FileExists(Name),'Actual converter child never started');
    PID:=StrToInt(Trim(TFile.ReadAllText(Name,TEncoding.UTF8)));
    Process:=OpenProcess(SYNCHRONIZE,False,PID);
    if Process<>0 then
      try Require(WaitForSingleObject(Process,1000)=WAIT_OBJECT_0,'Canceled converter left a descendant running');
      finally CloseHandle(Process); end;
  end;
  Writeln('PASS refactor legacy converter cancellation terminates actual child tree elapsed_ms=',Started.ElapsedMilliseconds);
end;

procedure TestRefactorZIP;
var Root, Destination, Source, Document, Stale, Digest: string; CID, ID: Integer;
  Book: TBookRecord; Collection: IBookCollection; Worker: TExportToDeviceThread;
  Item: IShellItem; Marshaled: IStream; Capture: TMTPTextExportCapture;
  Keys: TBookIdList; Results: TBookExportResults; Files: TArray<string>;
  Zip: TZipFile; SavedFolder, SavedName: string; SavedOverwrite: Boolean;
begin
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'refactor-zip-'+TGUID.NewGuid.ToString);
  Destination:=Root+'device'; ForceDirectories(Destination);
  Source:=Root+'source.fb2';
  Document:='<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
    '<description><title-info><book-title>Own ZIP</book-title><lang>ru</lang></title-info></description>'+
    '<body><section><p>Exact ZIP payload ё</p></section></body></FictionBook>';
  TFile.WriteAllText(Source,Document,TEncoding.UTF8);
  CID:=SystemDB.CreateCollection('ZIP collision fixture',Root,Root+'catalog.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst'); Collection:=SystemDB.GetCollection(CID);
  Book.Clear; Book.Title:='own-zip-'+TGUID.NewGuid.ToString; Book.LibID:=Book.Title;
  Book.FileName:='source'; Book.FileExt:='.fb2'; Book.Lang:='ru'; Include(Book.BookProps,bpIsLocal);
  TAuthorsHelper.Add(Book.Authors,'Own','Fixture',''); ID:=Collection.InsertBook(Book,False,False);
  Collection.GetBookRecord(CreateBookKey(ID,CID),Book,False);
  SetLength(Keys,1); Keys[0]:=Default(TBookIdStruct); Keys[0].BookKey:=Book.BookKey;
  Keys[0].HasExpectedIdentity:=True; Keys[0].ExpectedLibID:=Book.LibID;
  Keys[0].ExpectedPhysicalIdentity:=ReaderBookPhysicalIdentity(Book);
  SavedFolder:=Settings.FolderTemplate; SavedName:=Settings.FileNameTemplate; SavedOverwrite:=Settings.OverwriteFB2Info;
  Settings.FolderTemplate:=''; Settings.FileNameTemplate:='%t'; Settings.OverwriteFB2Info:=False;
  Capture:=TMTPTextExportCapture.Create; Capture.Messages:=TStringList.Create; Worker:=nil;
  Stale:=TPath.Combine(Settings.TempPath,Book.Title+'.fb2.zip');
  Require(not FileExists(Stale),'Own ZIP sentinel already exists');
  TFile.WriteAllText(Stale,'Old unrelated ZIP must stay byte-identical',TEncoding.UTF8);
  Digest:=THashSHA2.GetHashStringFromFile(Stale);
  try
    Require(Succeeded(SHCreateItemFromParsingName(PChar(Destination),nil,IShellItem,Item)),'Cannot get own shell folder');
    Require(Succeeded(CoMarshalInterThreadInterfaceInStream(IShellItem,Item,Marshaled)),'Cannot marshal own shell folder');
    Worker:=TExportToDeviceThread.Create; Worker.DeviceDir:=Destination; Worker.BookIdList:=Keys;
    Worker.ExportMode:=emFB2Zip; Worker.UseMTP:=True; Worker.MarshalStream:=Marshaled;
    Worker.OnShowMessage:=Capture.Message; Worker.Start; Worker.WaitFor; Results:=Worker.Results;
    Require(not Assigned(Worker.FatalException),'ZIP collision worker raised an exception'); FreeAndNil(Worker);
    Files:=TDirectory.GetFiles(Destination);
    Require((Length(Results)=1) and (Results[0].State=besSucceeded) and (Length(Files)=1) and
      (ExtractFileName(Files[0])=Book.Title+' (1).fb2.zip') and
      (ExtractFileName(Results[0].OutputFile)=ExtractFileName(Files[0])),
      'MTP copied or reported the old ZIP instead of its collision-selected output');
    Zip:=TZipFile.Create;
    try
      Zip.Open(Files[0],zmRead); Require(Zip.FileCount=1,'New ZIP is empty or has stale members');
      var Bytes: TBytes; Zip.Read(Zip.FileNames[0],Bytes);
      Require(TEncoding.UTF8.GetString(Bytes).Contains('Exact ZIP payload ё'),'MTP copied wrong ZIP bytes');
    finally Zip.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Stale)=Digest,'ZIP collision removed or rewrote the old archive');
    Marshaled:=nil; Item:=nil;
    // A directory at the archive name makes the real constructor fail.
    ForceDirectories(Root+'fail\'+Book.Title+'.fb2.zip');
    Worker:=TExportToDeviceThread.Create; Worker.DeviceDir:=Root+'fail'; Worker.BookIdList:=Keys;
    Worker.ExportMode:=emFB2Zip; Worker.OnShowMessage:=Capture.Message;
    Worker.Start; Worker.WaitFor; Results:=Worker.Results;
    Require(not Assigned(Worker.FatalException) and (Results[0].State=besFailed),
      'ZIP constructor failure accessed an uninitialized archiver or reported success');
    Require(DirectoryExists(Root+'fail\'+Book.Title+'.fb2.zip'),'Failed ZIP creation removed another object');
    Writeln('PASS refactor ZIP collision sends and reports exact new archive; old bytes survive actual constructor failure');
  finally
    Worker.Free; Marshaled:=nil; Item:=nil; TFile.Delete(Stale);
    Capture.Messages.Free; Capture.Free; Settings.FolderTemplate:=SavedFolder;
    Settings.FileNameTemplate:=SavedName; Settings.OverwriteFB2Info:=SavedOverwrite;
  end;
end;

type
  TRefactorSlowHTTP = class
    Requested: TEvent;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  end;

procedure TRefactorSlowHTTP.Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
begin
  Response.ContentLength:=4096*256; Response.ContentType:='application/x-fictionbook+xml';
  Response.WriteHeader;
  try
    for var I:=1 to 256 do
    begin
      Context.Connection.IOHandler.Write(StringOfChar('X',4096)); Requested.SetEvent; Sleep(20);
    end;
  except on E: Exception do ; end; // Expected peer disconnect after cancellation.
end;

procedure TestRefactorPreDownloadCancel;
var Root: string; CID, ID: Integer; Collection: IBookCollection; Book: TBookRecord;
  HTTP: TIdHTTPServer; Handler: TRefactorSlowHTTP; Worker: TDownloadBooksThread;
  Keys: TBookIdList; Started: TStopwatch; Capture: TMTPTextExportCapture;
begin
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'refactor-download-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  CID:=SystemDB.CreateCollection('Pre-download cancel fixture',Root,Root+'catalog.hlc2',
    CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst'); Collection:=SystemDB.GetCollection(CID);
  Book.Clear; Book.Title:='Own cancellation'; Book.LibID:='cancel-own';
  Book.FileName:='own-payload'; Book.FileExt:='.fb2'; Book.Lang:='ru';
  TAuthorsHelper.Add(Book.Authors,'Own','Fixture',''); ID:=Collection.InsertBook(Book,False,False);
  Collection.GetBookRecord(CreateBookKey(ID,CID),Book,False);
  SetLength(Keys,1); Keys[0]:=Default(TBookIdStruct); Keys[0].BookKey:=Book.BookKey;
  Keys[0].HasExpectedIdentity:=True; Keys[0].ExpectedLibID:=Book.LibID;
  Keys[0].ExpectedPhysicalIdentity:=ReaderBookPhysicalIdentity(Book);
  HTTP:=TIdHTTPServer.Create(nil); Handler:=TRefactorSlowHTTP.Create;
  Handler.Requested:=TEvent.Create(nil,True,False,''); Capture:=TMTPTextExportCapture.Create;
  Capture.Messages:=TStringList.Create; Worker:=nil;
  try
    HTTP.Bindings.Add.IP:='127.0.0.1'; HTTP.Bindings[0].Port:=0;
    HTTP.OnCommandGet:=Handler.Command; HTTP.OnCommandOther:=Handler.Command; HTTP.Active:=True;
    Collection.SetProperty(PROP_URL,'http://127.0.0.1:'+IntToStr(HTTP.Bindings[0].Port)+'/');
    for var Kind:=0 to 2 do
    begin
      Handler.Requested.ResetEvent; Capture.Messages.Clear;
      if Kind=2 then Collection.SetProperty(PROP_CONNECTIONSCRIPT,'POST %URL%body'+sLineBreak+'CHECK')
      else Collection.SetProperty(PROP_CONNECTIONSCRIPT,'GET %URL%body'+sLineBreak+'CHECK');
      Worker:=TDownloadBooksThread.Create; Worker.BookIdList:=Keys; Worker.OnShowMessage:=Capture.Message;
      if Kind=0 then Worker.Cancel;
      Worker.Start; Started:=TStopwatch.StartNew;
      if Kind>0 then
      begin
        while (Handler.Requested.WaitFor(0)<>wrSignaled) and not Worker.Finished and (Started.ElapsedMilliseconds<4000) do
        begin CheckSynchronize(5); Sleep(1); end;
        Require(Handler.Requested.WaitFor(0)=wrSignaled,'Actual pre-download worker never received loopback response');
        Started:=TStopwatch.StartNew; Worker.Cancel;
      end;
      while not Worker.Finished and (Started.ElapsedMilliseconds<4000) do begin CheckSynchronize(5); Sleep(1); end;
      Writeln('TRACE refactor predownload result kind=',Kind,' elapsed_ms=',Started.ElapsedMilliseconds,
        ' finished=',Ord(Worker.Finished),' canceled=',Ord(Worker.Canceled),' messages=',Capture.Messages.Text);
      Require(Worker.Finished and Worker.Canceled and not Assigned(Worker.FatalException) and
        (Capture.Messages.Count=0),'Pre-download cancellation hung, reset its flag or displayed an error');
      Worker.WaitFor; FreeAndNil(Worker);
      Require(not FileExists(Book.GetBookFileName),'Canceled download published partial book');
      if Kind=0 then Require(Handler.Requested.WaitFor(0)<>wrSignaled,'Canceled before start still made HTTP request');
      Writeln('TRACE refactor predownload cancel kind=',Kind,' elapsed_ms=',Started.ElapsedMilliseconds);
    end;
    Writeln('PASS refactor preliminary download cancellation survives pre-start GET and silent-progress POST responses');
  finally
    if Assigned(Worker) then begin Worker.Cancel; Worker.WaitFor; Worker.Free; end;
    HTTP.Active:=False; HTTP.Free; Handler.Requested.Free; Handler.Free; Capture.Messages.Free; Capture.Free;
  end;
end;

procedure TestRefactorLinkMarkup;
var Link: TMHLLinkLabel; Size: TSize;
begin
  Link:=TMHLLinkLabel.Create(nil);
  try
    for var Text in TArray<string>.Create('', '<', '<a', '<a href=', '<a>text<',
      '<a>text</', '<a>text</a', '<A HREF="1">Ёж 😀</A>') do
    begin
      Size:=Link.GetIdealSize(Text);
      Require((Size.cx>=0) and (Size.cy>=0),'Malformed optional link markup corrupted dimensions');
    end;
  finally Link.Free; end;
  Writeln('PASS refactor incomplete link markup measures without out-of-bounds reads');
end;

procedure TestRefactorInfoDPI;
var Panels: TArray<TInfoPanel>; OriginalPPI, SavedHeight, Expected: Integer; Watch: TStopwatch; WasVisible, ShowInfo: Boolean;
begin
  Panels:=[frmMain.ipnlAuthors,frmMain.ipnlSeries,frmMain.ipnlGenres,
    frmMain.ipnlSearch,frmMain.ipnlFavorites,PublisherView.Info];
  OriginalPPI:=frmMain.Font.PixelsPerInch; SavedHeight:=frmMain.ipnlAuthors.Height;
  WasVisible:=frmMain.Visible;
  ShowInfo:=Settings.ShowInfoPanel;
  try
    frmMain.Show; Application.ProcessMessages;
    if not Settings.ShowInfoPanel then frmMain.ShowBookInfoPanelExecute(nil);
    frmMain.ScaleForPPI(96); frmMain.ipnlAuthors.Height:=180;
    // A hidden control may have no HWND and therefore no native resize event.
    // Invoke the same synchronization handler used by the actual splitter.
    frmMain.InfoPanelResize(frmMain.ipnlAuthors);
    for var DPI in TArray<Integer>.Create(144,192,96) do
    begin
      Watch:=TStopwatch.StartNew; frmMain.ScaleForPPI(DPI); Watch.Stop;
      Expected:=MulDiv(180,DPI,96);
      for var Panel in Panels do
      begin
        Writeln('TRACE refactor dpi panel=',Panel.Name,' font_ppi=',Panel.Font.PixelsPerInch,
          ' height=',Panel.Height,' expected=',Expected,' visible=',Ord(Panel.Visible));
        Require((Panel.Font.PixelsPerInch=DPI) and (Abs(Panel.Height-Expected)<=2),
          'DPI pass compounded synchronized information-panel heights');
      end;
      Writeln('PROFILE refactor main_dpi target=',DPI,' height=',Expected,' elapsed_ms=',Watch.ElapsedMilliseconds);
      Require(Watch.ElapsedMilliseconds<5000,'Main DPI transition exceeded five seconds');
    end;
    Writeln('PASS refactor full Main DPI pass scales all six information panels once with stable heights');
  finally
    frmMain.ScaleForPPI(OriginalPPI); frmMain.ipnlAuthors.Height:=SavedHeight;
    frmMain.InfoPanelResize(frmMain.ipnlAuthors);
    if Settings.ShowInfoPanel<>ShowInfo then frmMain.ShowBookInfoPanelExecute(nil);
    if not WasVisible then frmMain.Hide;
  end;
end;

procedure TestRefactorAudit;
begin
  TestRefactorLinkMarkup;
  TestRefactorTransactions;
  TestRefactorNoteLookup;
  TestRefactorConverterCancel;
  TestRefactorZIP;
  TestRefactorPreDownloadCancel;
  TestRefactorInfoDPI;
end;
