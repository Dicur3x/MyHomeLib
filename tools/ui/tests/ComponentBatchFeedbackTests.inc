// One explicit operation may need several independently versioned modules.
type
  TBatchFeedbackWorker = class(TComponentUpdateThread)
  public Expected: TComponentReleases; Asked: TStrings; FailID: string;
  protected
    function FetchText(const URL: string): string; override;
    function FetchMirrorRelease(const ID, Version: string; out Info: TProgramRelease): Boolean; override;
  end;
  TBatchFeedbackForm = class(TRepairForm)
  public Expected: TComponentReleases; Asked: TStringList; FailID: string;
    constructor CreateForBatch(Server: TRepairServer);
    destructor Destroy; override;
  protected function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
  end;

function TBatchFeedbackWorker.FetchText(const URL:string):string;
begin raise Exception.Create('Owned unavailable module'); end;

function TBatchFeedbackWorker.FetchMirrorRelease(const ID, Version: string; out Info: TProgramRelease): Boolean;
begin
  System.TMonitor.Enter(Asked);
  try Asked.Add(ID); finally System.TMonitor.Exit(Asked); end;
  if ID=FailID then raise Exception.Create('Owned unavailable module');
  for var Entry in Expected do if Entry.ComponentID=ID then begin Info:=Entry; Exit(True); end;
  raise Exception.Create('Unexpected component in explicit operation: '+ID);
end;

constructor TBatchFeedbackForm.CreateForBatch(Server: TRepairServer);
begin inherited CreateForServer(Server); Asked:=TStringList.Create; OnRestart:=RepairRestartRequested; end;
destructor TBatchFeedbackForm.Destroy;
begin inherited; Asked.Free; end;
function TBatchFeedbackForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
var Worker: TBatchFeedbackWorker;
begin
  Worker:=TBatchFeedbackWorker.Create(Window,CreateHTTPClientGlobal,PROGRAM_RELEASES_API,'');
  Worker.Expected:=Expected; Worker.Asked:=Asked; Worker.FailID:=FailID; Result:=Worker;
end;

procedure TestComponentBatchFeedback;
var Server:TRepairServer; Dialog:TBatchFeedbackForm; Prompt:TForm; Primary:TButton;
  Expected:TComponentReleases; Started:UInt64; Total:Int64; Base,Archive,Job,Target,Ready:string; Root:TJSONObject;
  procedure WaitForCaption(const Caption:string);
  begin
    Started:=GetTickCount64;
    repeat
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Prompt:=TForm(Dialog.FindComponent('OptionalComponentPrompt')); Primary:=nil;
      if Assigned(Prompt) then Primary:=TButton(Prompt.FindComponent('ComponentPromptDownload'));
    until (Assigned(Primary) and Primary.Enabled and (Primary.Caption=Caption)) or (GetTickCount64-Started>30000);
    Require(Assigned(Primary) and Primary.Enabled and (Primary.Caption=Caption),'Batch prompt did not reach '+Caption+'; actual='+IfThen(Assigned(Primary),Primary.Caption,'absent')+'; reason='+IfThen(Assigned(Prompt),TMemo(Prompt.FindComponent('ComponentPromptReason')).Text,'absent'));
  end;
begin
  RequireIsolatedRegression;
  Base:=GetEnvironmentVariable('HLRU_BATCH_PACKAGES'); Require(DirectoryExists(Base),'Specify verified independent module fixtures');
  Expected:=Default(TComponentReleases); Total:=0; Server:=TRepairServer.Create; Dialog:=nil;
  try
    for var ID in TArray<string>.Create('BookProcessing','ImageProcessing') do
      for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do if UPDATE_COMPONENTS[I].ID=ID then
      begin
        Archive:=TPath.Combine(Base,ComponentVersionedArchiveName(ID,'2.7.0.1105',ProgramUpdatePlatform));
        Require(FileExists(Archive),'Missing actual independent package '+ID);
        Expected[I].ComponentID:=ID; Expected[I].ComponentVersion:='2.7.0.1105'; Expected[I].Tag:=ALREADER_FIXED_TAG;
        Expected[I].SHA256:=UpdateSHA256(Archive); Expected[I].Size:=TFile.GetSize(Archive); Inc(Total,Expected[I].Size);
        Expected[I].DownloadURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+ExtractFileName(Archive);
        Server.URLs.Add(Expected[I].DownloadURL); Server.Files.Add(Archive);
      end;
    Dialog:=TBatchFeedbackForm.CreateForBatch(Server); Dialog.Expected:=Expected;
    Dialog.RequestComponents(TArray<string>.Create('BookProcessing','ImageProcessing','BookProcessing'),
      'Для выбранной операции нужны два модуля.',True);
    WaitForCaption('Скачать компоненты');
    Require((Dialog.Asked.Count=2) and (Dialog.Asked.IndexOf('BookProcessing')>=0) and
      (Dialog.Asked.IndexOf('ImageProcessing')>=0),'Batch checked unrelated or duplicate modules');
    Require((Server.Requests=0) and
      (TLabel(Prompt.FindComponent('ComponentPromptBytes')).Caption='Нужно скачать: '+Format('%.1f МБ',[Total/1024/1024])),
      'Batch started without consent or did not total its package sizes');
    TButton(Prompt.FindComponent('ComponentPromptCancel')).Click;
    Require((Server.Requests=0) and not Dialog.PendingInstall,'Cancel began downloading or installing an operation batch');
    Dialog.RequestComponents(TArray<string>.Create('BookProcessing','ImageProcessing'),'Повторный явный запрос',True);
    WaitForCaption('Скачать компоненты');
    Primary.Click; WaitForCaption('Установить и перезапустить');
    Require((Server.Requests=2) and (Server.Failure=''),'Batch downloaded extra format modules');
    Ready:=TPath.Combine(ProgramUpdateCache(Settings.AppPath),'ready.json');
    Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Ready,TEncoding.UTF8)) as TJSONObject;
    try
      Require(Root.GetValue<string>('component')='batch','Separate modules did not form one install transaction');
      Job:=Root.GetValue<string>('job');
    finally Root.Free; end;
    Require(PreparedIncludesComponent(Job,'BookProcessing') and PreparedIncludesComponent(Job,'ImageProcessing') and
      not PreparedIncludesComponent(Job,'Kindle') and not PreparedIncludesComponent(Job,'LegacyOffice') and
      not PreparedIncludesComponent(Job,'XPS'),'Batch payload contains the wrong components');
    TFile.Copy(ParamStr(0),Settings.AppPath+'HomeLibRuUpdater.exe');
    Primary.Click;
    Require(Dialog.PendingInstall and (Dialog.Restarts=1) and Dialog.WillInstallComponent('BookProcessing') and
      Dialog.WillInstallComponent('ImageProcessing'),'Batch needs more than one restart or loses its component identities');
    Dialog.CancelInstallation;
    Target:=Settings.AppPath+'batch-installed'; ForceDirectories(Target);
    TFile.Copy(ParamStr(0),Target+'\HomeLibRu.exe'); TFile.WriteAllText(Target+'\private.txt','Owned private file');
    InstallProgramUpdate(Job,Target);
    Require(not ComponentNeedsRepair(Target,'BookProcessing') and not ComponentNeedsRepair(Target,'ImageProcessing'),
      'Combined independent module install remains incomplete');
    Require(TFile.ReadAllText(Target+'\private.txt')='Owned private file','Combined install changed a private file');
    for var Name in TArray<string>.Create('kindle','office','xps','doc','djvu','pdfium') do
      Require(not DirectoryExists(Target+'\tools\'+Name),'Combined install added unrelated '+Name);
    Dialog.Free; Dialog:=nil;
    Dialog:=TBatchFeedbackForm.CreateForBatch(Server); Dialog.Expected:=Expected; Dialog.FailID:='ImageProcessing';
    Dialog.RequestComponents(TArray<string>.Create('BookProcessing','ImageProcessing'),'Owned metadata failure',True);
    WaitForCaption('Повторить проверку');
    Require(Server.Requests=2,'A partial metadata result began downloading the available component');
    Require(string(TMemo(Prompt.FindComponent('ComponentPromptReason')).Text).Contains('Не удалось проверить ImageProcessing'),
      'Batch hides the unavailable requested module: '+TMemo(Prompt.FindComponent('ComponentPromptReason')).Text);
    for var I:=0 to Server.Files.Count-1 do
      for var Info in Expected do if (Info.DownloadURL=Server.URLs[I]) then
        Require(UpdateSHA256(Server.Files[I])=Info.SHA256,'Batch test changed its input archive');
  finally Dialog.Free; Server.Free; end;
  Writeln('PASS explicit operation batches only its known missing modules, validates both real packages and uses one restart');
end;
