type
  TCompressionResumeReviewProbe = class
    Seen: Boolean;
    Scope: TCompressionResumeScope;
    procedure Tick(Sender:TObject);
  end;

procedure TCompressionResumeReviewProbe.Tick(Sender:TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionOptions) and Screen.Forms[I].Visible then
    begin
      Require(not Seen,'Compression review opened twice'); Seen:=True;
      var Dialog:=TfrmBookCompressionOptions(Screen.Forms[I]);
      var Options:=Dialog.SelectedOptions;
      Require(Pos('после установки компонентов',Dialog.Caption)>0,'Restart review has no continuation context');
      Require((Options.Profile='maximum') and Options.Grayscale and not Options.ReviewResults and
        Options.BackupOriginals and Options.EstimateFirst and (Options.OnlyNew=(Scope=crsNew)) and
        SameFileName(Options.WorkRoot,Settings.AppPath+'resume-work') and
        SameFileName(Options.BackupFolder,Settings.AppPath+'resume-backup-ё'),
        'Restart review lost an explicitly selected compression option');
      Require((Scope<>crsSelected) or (Pos('1',Dialog.Caption)>0),'Restart lost its exact selected count');
      TButton(Dialog.FindComponent('CompressionCancel')).Click;
    end;
end;

procedure TestCompressionResumeReviewChild;
var Probe:TCompressionResumeReviewProbe; Timer:TTimer; Started:UInt64; Report:string;
begin
  RequireIsolatedRegression;
  Report:=Settings.AppPath+'compression-review-'+ParamStr(2)+'.txt';
  try
    TfrmMain.DeferInitialCollection:=True; Settings.EnableSort:=False;
    Application.CreateForm(TdmImages,dmImages); dmImages.ApplyThemeIcons;
    Probe:=TCompressionResumeReviewProbe.Create; Timer:=TTimer.Create(nil);
    try
      Probe.Scope:=TCompressionResumeScope(StrToInt(ParamStr(2)));
      Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
      Application.CreateForm(TfrmMain,frmMain);
      frmSplash.Hide; frmMain.Show; frmMain.StartInitialCollectionLoad;
      Started:=GetTickCount64;
      repeat
        Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
        Require(GetTickCount64-Started<45000,'Normal startup did not restore compression settings');
      until Probe.Seen and not frmMain.StartupLoading;
      Require(not DirectoryExists(Settings.AppPath+'resume-work'),
        'Canceling resumed settings started compression');
      TFile.WriteAllText(Report,'PASS restored compression settings canceled before preparation',TEncoding.UTF8);
    finally
      Timer.Free; Probe.Free; FreeAndNil(frmMain); FreeAndNil(dmImages);
    end;
  except on E:Exception do
    begin TFile.WriteAllText(Report,'FAIL '+E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
  end;
end;

procedure TestCompressionContinuation;
var Collection,Other:IBookCollection; SourceID,BookID:Integer; Book:TBookRecord;
    Identity:TCollectionPackingRequest; Options:TBookCompressionOperationOptions;
    Request,Taken:TBookCompressionContinuation; Argument,SourceFile,Original,Hash,Plan,Command:string;
    Startup:TStartupInfo; Process:TProcessInformation; Started:UInt64; Code:Cardinal;
  procedure Rejected(const Action:TProc; const Message:string);
  var Failed:Boolean;
  begin
    Failed:=False; try Action(); except on E:Exception do Failed:=True; end;
    Require(Failed,Message);
  end;
  procedure BadPlan(const Before,After:string);
  begin
    Argument:=StoreCompressionContinuation(Settings.SettingsFileName,Request);
    var Value:=TFile.ReadAllText(Plan,TEncoding.UTF8);
    Require(Value.Contains(Before),'Malformed fixture selector was not found');
    TFile.WriteAllText(Plan,Value.Replace(Before,After),TEncoding.UTF8);
    Rejected(procedure begin TakeCompressionContinuation(Settings.SettingsFileName,Argument,Taken); end,
      'Malformed compression continuation was accepted');
    Require(not TakeCompressionContinuation(Settings.SettingsFileName,Argument,Taken),'Malformed continuation was replayed');
  end;
begin
  RequireIsolatedRegression;
  ForceDirectories(Settings.AppPath+'resume-source');
  SourceFile:=Settings.AppPath+'resume-source\source.fb2';
  Original:='<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>Do not change this source.</p></section></body></FictionBook>';
  TFile.WriteAllText(SourceFile,Original,TEncoding.UTF8); Hash:=UpdateSHA256(SourceFile);
  SourceID:=SystemDB.CreateCollection('Compression continuation',Settings.AppPath+'resume-source',
    'compression-continuation.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(SourceID);
  BookID:=AddBook(Collection,'Resume book','Author','en','','prose_contemporary');
  Collection.GetBookRecord(CreateBookKey(BookID,SourceID),Book,True);
  Book.LibID:='resume-ё'; Book.FileName:='source'; Book.FileExt:='.fb2'; Collection.UpdateBook(Book);
  Identity:=Default(TCollectionPackingRequest); Identity.SourceID:=SourceID;
  Identity.SourceRoot:=Collection.CollectionRoot;
  Identity.CatalogFile:=Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE)));
  Options:=Default(TBookCompressionOperationOptions); Options.Profile:='maximum';
  Options.Grayscale:=True; Options.ReviewResults:=False; Options.EstimateFirst:=True;
  Options.WorkRoot:=Settings.AppPath+'resume-work'; Options.BackupOriginals:=True;
  Options.BackupFolder:=Settings.AppPath+'resume-backup-ё'; ForceDirectories(Options.BackupFolder);
  Request:=CaptureCompressionContinuation(Identity,crsSelected,Options,[Book]);
  Plan:=TPath.GetFullPath(Settings.SettingsFileName)+'.pending-compression.jsonl';
  Argument:=StoreCompressionContinuation(Settings.SettingsFileName,Request);
  Require(not TakeCompressionContinuation(Settings.SettingsFileName,
    BOOK_COMPRESSION_RESUME_SWITCH+TGUID.NewGuid.ToString,Taken),'Unrelated token consumed compression settings');
  Require(TakeCompressionContinuation(Settings.SettingsFileName,Argument,Taken) and
    (Taken.Scope=crsSelected) and (Length(Taken.Books)=1) and (Taken.Options.QueueName<>''),
    'Exact compression request was not restored');
  Require(not TakeCompressionContinuation(Settings.SettingsFileName,Argument,Taken),'Compression request was consumed twice');
  Require(Length(ResolveCompressionContinuationBooks(Request,Collection))=1,'Selected identity was not retained');
  Book.LibID:='reused-ID'; Collection.UpdateBook(Book);
  Rejected(procedure begin ResolveCompressionContinuationBooks(Request,Collection); end,'Reused catalogue ID was accepted');
  Book.LibID:='resume-ё'; Collection.UpdateBook(Book);
  TFile.AppendAllText(SourceFile,'changed',TEncoding.UTF8);
  Rejected(procedure begin ResolveCompressionContinuationBooks(Request,Collection); end,'Changed source archive was accepted');
  TFile.WriteAllText(SourceFile,Original,TEncoding.UTF8);
  Request:=CaptureCompressionContinuation(Identity,crsSelected,Options,[Book]);
  Other:=SystemDB.GetCollection(SystemDB.CreateCollection('Other compression source',Settings.AppPath+'resume-source',
    'compression-other.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst'));
  Rejected(procedure begin ResolveCompressionContinuationBooks(Request,Other); end,'Another collection was accepted');
  BadPlan('"review":false','"review":"false"');
  BadPlan('"count":1','"count":-1');
  BadPlan('"count":1','"count":999999999');
  BadPlan('"profile":"maximum"','"profile":"unrecognized"');
  Writeln('PASS compression continuation rejects replay, wrong token, collection or reused book, changed archive and malformed choices');
  Settings.ActiveCollection:=SourceID; Settings.ActivePage:=PAGE_AUTHORS; Settings.SaveSettings;
  for var Scope:=Low(TCompressionResumeScope) to High(TCompressionResumeScope) do
  begin
    if Scope=crsSelected then Request:=CaptureCompressionContinuation(Identity,Scope,Options,[Book])
    else Request:=CaptureCompressionContinuation(Identity,Scope,Options,nil);
    Argument:=StoreCompressionContinuation(Settings.SettingsFileName,Request);
    Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
    Command:='"'+ParamStr(0)+'" compression-resume-review-child '+IntToStr(Ord(Scope))+' "'+Argument+'"';
    UniqueString(Command);
    Require(CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
      PChar(Settings.AppPath),Startup,Process),'Cannot start compression review successor');
    try
      Started:=GetTickCount64;
      repeat
        Application.ProcessMessages; CheckSynchronize(2); Sleep(10);
        Require(GetTickCount64-Started<60000,'Compression review successor did not finish');
      until WaitForSingleObject(Process.hProcess,0)=WAIT_OBJECT_0;
      Require(GetExitCodeProcess(Process.hProcess,Code) and (Code=0),
        'Compression review successor failed: '+TFile.ReadAllText(Settings.AppPath+'compression-review-'+IntToStr(Ord(Scope))+'.txt',TEncoding.UTF8));
    finally CloseHandle(Process.hThread); CloseHandle(Process.hProcess); end;
    Require(not TakeCompressionContinuation(Settings.SettingsFileName,Argument,Taken),
      'Canceled settings remain available for another compression restart');
    Require((UpdateSHA256(SourceFile)=Hash) and not DirectoryExists(Options.WorkRoot),
      'Canceled compression review changed its source or created a work queue');
    Writeln('PASS normal startup restored and canceled compression scope ',Ord(Scope));
  end;
  Writeln('PASS compression continuation restores exact selected, collection and new-book options through actual main-window startup');
end;
