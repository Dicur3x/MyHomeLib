type
  TLegacyWorkspaceServer = class
    Payload: string;
    Downloads: Integer;
    Fail: Boolean;
    procedure Command(Context:TIdContext; Request:TIdHTTPRequestInfo; Response:TIdHTTPResponseInfo);
  end;
  TLegacyWorkspaceEvents = class
    Worker:TLibUpdateThread;
    CancelDownload,CancelImport:Boolean;
    Messages:TStringList;
    function Confirm(const Text:string; Flags:Longint):Integer;
    procedure Progress(Percent:Integer);
    procedure Log(const Text:string; Severity:TTeletypeSeverity);
  end;

procedure TLegacyWorkspaceServer.Command(Context:TIdContext; Request:TIdHTTPRequestInfo; Response:TIdHTTPResponseInfo);
begin
  Response.ResponseNo:=200;
  if Request.Document='/version.txt' then Response.ContentText:='20261119'
  else
  begin
    InterlockedIncrement(Downloads);
    if Fail then begin Response.ResponseNo:=404; Response.ContentText:='missing'; end
    else begin Response.ContentStream:=TFileStream.Create(Payload,fmOpenRead or fmShareDenyWrite); Response.FreeContentStream:=True; end;
  end;
end;

function TLegacyWorkspaceEvents.Confirm(const Text:string; Flags:Longint):Integer;
begin Result:=IDOK; if (Flags and $F)=MB_YESNO then Result:=IDYES; end;
procedure TLegacyWorkspaceEvents.Progress(Percent:Integer);
begin if CancelDownload and (Percent>0) then Worker.Cancel; end;
procedure TLegacyWorkspaceEvents.Log(const Text:string; Severity:TTeletypeSeverity);
begin
  Messages.Add(Text);
  if CancelImport and Text.Contains('Импорт данных в коллекцию:') then Worker.Cancel;
end;

procedure TestLegacyUpdateWorkspace;
var Folder,Root,Payload,LocalFile,Unused,OldDir,URL,Name,Configured,INIHash,BeforeFallback:string;
  Server:TIdHTTPServer; Probe:TLegacyWorkspaceServer; Events:TLegacyWorkspaceEvents;
  Worker:TLibUpdateThread; Catalog,Personal:TSQLiteDatabase;
  CID,SeedID,Requests:Integer; Collection:IBookCollection; Seed,Stored:TBookRecord;
  InputHash,UnusedHash,Rows,PersonalRows:string;

  procedure Configure(const CaseName,FileName:string; Remote:Boolean);
  begin
    Settings.Updates.Clear; Name:='Legacy '+CaseName;
    CID:=SystemDB.CreateCollection(Name,Folder,Folder+TGUID.NewGuid.ToString+'.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    Collection:=SystemDB.GetCollection(CID);
    Seed:=Default(TBookRecord); Seed.Title:='Сохранить исходную книгу'; Seed.LibID:='keep-seed';
    Seed.FileName:='seed'; Seed.FileExt:='.fb2'; Seed.Size:=100; Seed.Lang:='ru'; Seed.Date:=Now;
    TAuthorsHelper.Add(Seed.Authors,'Автор','Исходный','');
    TGenresHelper.Add(Seed.Genres,'','','prose_contemporary');
    SeedID:=Collection.InsertBook(Seed,False,False); Seed.BookKey:=CreateBookKey(SeedID,CID);
    Collection.SetRate(Seed.BookKey,4); Collection.SetProgress(Seed.BookKey,37);
    Collection.SetReview(Seed.BookKey,'Сохранить заметку ё'); Collection.SetAnnotation(Seed.BookKey,'Сохранить описание');
    Collection.AddBookToGroup(Seed.BookKey,FAVORITES_GROUP_ID); Collection:=nil;
    Settings.UpdateDir:=Root; Configured:=Settings.UpdateDir;
    Settings.Updates.Add(Name,URL,'version.txt',FileName,False,CT_EXTERNAL_LOCAL_FB);
    Require(Settings.Updates[0].CheckCodes(Name,CT_EXTERNAL_LOCAL_FB,CID),'Legacy fixture collection binding failed');
    if Remote then Settings.Updates.UpdateExternalVersions;
    Require(Settings.Updates[0].CheckVersion(IncludeTrailingPathDelimiter(Root),0),'Legacy fixture update not available');
    Settings.Updates.Add('Unselected local input','','','unused.inpx',False,CT_EXTERNAL_LOCAL_FB);
  end;

  procedure Run(CancelDownload,CancelImport:Boolean);
  begin
    Worker:=TLibUpdateThread.Create; Events.Worker:=Worker;
    Events.CancelDownload:=CancelDownload; Events.CancelImport:=CancelImport; Events.Messages.Clear;
    try
      Worker.OnShowMessage:=Events.Confirm; Worker.OnTeletype:=Events.Log; Worker.OnProgress:=Events.Progress;
      Worker.Start; Worker.WaitFor;
      Require(Worker.Finished and not Assigned(Worker.FatalException),'Actual legacy worker did not finish cleanly');
    finally
      Worker.OnShowMessage:=nil; Worker.OnTeletype:=nil; Worker.OnProgress:=nil;
    end;
  end;

  procedure CheckSeed;
  begin
    Collection:=SystemDB.GetCollection(CID,True);
    Collection.GetBookRecord(Seed.BookKey,Stored,True);
    Require((Stored.Title=Seed.Title) and (Stored.LibID=Seed.LibID) and (Stored.Rate=4) and
      (Stored.Progress=37) and (Stored.Review='Сохранить заметку ё') and (Stored.Annotation='Сохранить описание'),
      'Legacy worker changed seed identity or personal data'); Collection:=nil;
  end;

  procedure CheckFiles;
  begin
    Require(FileExists(Unused) and (THashSHA2.GetHashStringFromFile(Unused)=UnusedHash),
      'Legacy worker deleted or changed an unselected local package');
    Require(Settings.UpdateDir=Configured,'Legacy worker changed configured work folder');
    Require(THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=INIHash,'Legacy worker rewrote settings');
    Require(Length(TDirectory.GetDirectories(Root,'HomeLibre-index-*'))=0,'Legacy worker left its staging folder');
  end;

begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Legacy update tests require G:');
  // Only the isolated runtime's in-memory defaults; never save collections.ini.
  Settings.Updates.Clear;
  OldDir:=Settings.UpdateDir; Folder:=Settings.AppPath+'legacy-update-fixture\';
  Root:=Folder+'configured'; ForceDirectories(Root);
  Payload:=Folder+'publisher.inpx'; TOOIndex(Payload,'Новая книга','9101');
  LocalFile:=TPath.Combine(Root,'selected.inpx'); Unused:=TPath.Combine(Root,'unused.inpx');
  TFile.WriteAllText(Unused,'Never selected by the user',TEncoding.UTF8); UnusedHash:=THashSHA2.GetHashStringFromFile(Unused);
  INIHash:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
  Server:=TIdHTTPServer.Create(nil); Probe:=TLegacyWorkspaceServer.Create; Events:=TLegacyWorkspaceEvents.Create;
  Events.Messages:=TStringList.Create; Probe.Payload:=Payload;
  try
    Server.OnCommandGet:=Probe.Command; Server.Bindings.Add.IP:='127.0.0.1'; Server.Bindings[0].Port:=0; Server.Active:=True;
    URL:='http://127.0.0.1:'+IntToStr(Server.Bindings[0].Port);
    for var Mode in TArray<string>.Create('local-success','local-cancel','local-invalid','remote-success','remote-http-error','remote-invalid','remote-cancel') do
    begin
      var Remote:=Mode.StartsWith('remote'); Probe.Fail:=Mode='remote-http-error';
      if Mode.EndsWith('invalid') then TFile.WriteAllText(Payload,'Not an INPX archive',TEncoding.UTF8)
      else TOOIndex(Payload,'Новая книга','9101');
      if Remote then begin if FileExists(LocalFile) then TFile.Delete(LocalFile); end
      else TFile.Copy(Payload,LocalFile,True);
      InputHash:=THashSHA2.GetHashStringFromFile(Payload);
      Configure(Mode,'selected.inpx',Remote); Requests:=Probe.Downloads;
      Run(Mode='remote-cancel',Mode='local-cancel');
      try
        var Success:=Mode.EndsWith('success');
        Require(Worker.Success=Success,'Wrong legacy worker success for '+Mode+': '+Events.Messages.Text);
        Require(Worker.CommittedChanges=Success,'Wrong legacy commit for '+Mode);
        Require(TOOBookCount(SystemDB,CID)=1+Ord(Success),'Wrong legacy card count for '+Mode); CheckSeed;
        Require(THashSHA2.GetHashStringFromFile(Payload)=InputHash,'Legacy worker changed publisher input');
        if not Remote then Require(FileExists(LocalFile) and (THashSHA2.GetHashStringFromFile(LocalFile)=InputHash),
          'Legacy worker deleted or changed the selected local package: '+Mode);
        Require(Probe.Downloads-Requests=Ord(Remote),'Wrong actual legacy download request count');
        CheckFiles;
        Writeln('PASS actual legacy workspace ',Mode,' preserves seed personal data local inputs and removes owned staging'); Flush(Output);
      finally Worker.Free; end;
    end;
    Probe.Fail:=False; TOOIndex(Payload,'Новая книга','9101');
    for var Occupied in TArray<Boolean>.Create(False,True) do
    begin
      if FileExists(LocalFile) then TFile.Delete(LocalFile);
      Configure('unavailable-'+BoolToStr(Occupied,True),'selected.inpx',True); Requests:=Probe.Downloads;
      TFile.Move(Unused,Folder+'hold-unused.inpx'); TDirectory.Delete(Root,False);
      if Occupied then TFile.WriteAllText(Root,'Occupied configured path',TEncoding.UTF8);
      BeforeFallback:=string.Join(#0,TDirectory.GetDirectories(Settings.WorkPath,'HomeLibre-index-*'));
      Catalog:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(CID).DBFileName);
      Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
      try
        Rows:=ReaderAllCatalogRows(Catalog); PersonalRows:=ReaderAllCatalogRows(Personal);
        Run(False,False);
        try
          Require(not Worker.Success and not Worker.CommittedChanges and (Probe.Downloads=Requests),'Unavailable legacy workspace downloaded or committed');
          Require((ReaderAllCatalogRows(Catalog)=Rows) and (ReaderAllCatalogRows(Personal)=PersonalRows),'Unavailable legacy workspace changed rows/schema');
          Require(Events.Messages.Text.Contains(Root) and Events.Messages.Text.Contains('Папки/Устройства'),'Legacy workspace error lacks folder and recovery setting');
          Require(string.Join(#0,TDirectory.GetDirectories(Settings.WorkPath,'HomeLibre-index-*'))=BeforeFallback,'Unavailable legacy workspace used fallback');
          Require(Settings.UpdateDir=Configured,'Unavailable legacy workspace changed setting');
        finally Worker.Free; end;
      finally Catalog.Free; Personal.Free; end;
      if Occupied then begin Require(TFile.ReadAllText(Root,TEncoding.UTF8)='Occupied configured path','Legacy refusal altered occupying file'); TFile.Delete(Root); end
      else Require(not DirectoryExists(Root),'Legacy refusal recreated unavailable folder');
      ForceDirectories(Root); TFile.Move(Folder+'hold-unused.inpx',Unused);
      Run(False,False);
      try Require(Worker.Success and Worker.CommittedChanges,'Restored legacy workspace failed retry: '+Events.Messages.Text); CheckSeed; CheckFiles;
      finally Worker.Free; end;
      Writeln('PASS actual legacy workspace refuses missing or occupied root without HTTP rows settings or fallback changes and retries occupied=',Ord(Occupied)); Flush(Output);
    end;
  finally
    Server.Active:=False; Server.Free; Probe.Free; Events.Messages.Free; Events.Free;
    Settings.UpdateDir:=OldDir; Settings.Updates.Clear;
  end;
end;
