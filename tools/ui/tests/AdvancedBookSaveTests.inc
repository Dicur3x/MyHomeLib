type
  TAdvancedSaveDialogProbe = class
    Timer: TTimer;
    Checked, Restored, TestRuntime, WaitingForRuntime, RuntimePromptSeen: Boolean;
    Failure: string;
    Deadline: UInt64;
    procedure Tick(Sender: TObject);
  end;

procedure TAdvancedSaveDialogProbe.Tick(Sender: TObject);
begin
  if WaitingForRuntime then
  begin
    var Prompt:=FindWindow('#32770','Сохранение EPUB в PDF');
    if (Prompt<>0) and (GetWindowThreadProcessId(Prompt,nil)=GetCurrentThreadId) then
    begin
      RuntimePromptSeen:=True; PostMessage(Prompt,WM_COMMAND,IDCANCEL,0);
    end;
    if (Prompt=0) and (GetTickCount64>=Deadline) then
    begin
      var Active:=GetActiveWindow;
      if (Active<>0) and (GetWindowThreadProcessId(Active,nil)=GetCurrentThreadId) then
        PostMessage(Active,WM_CLOSE,0,0);
    end;
    Exit;
  end;
  for var I:=Screen.FormCount-1 downto 0 do
    if (Screen.Forms[I] is TBookSendOptionsForm) and Screen.Forms[I].Visible then
    begin
      Timer.Enabled:=False;
      var Dialog:=Screen.Forms[I];
      try
        var Formats:=TComboBox(Dialog.FindComponent('SendFormat'));
        var Extras:=TCheckBox(Dialog.FindComponent('SaveMoreFormats'));
        var Preview:=TLabel(Dialog.FindComponent('SaveNamePreview'));
        Require(Assigned(Extras),'Save As did not create the additional-format control');
        if TestRuntime then
        begin
          if not Extras.Checked then Extras.Perform(BM_CLICK,0,0);
          var Index:=-1;
          for var J:=0 to Formats.Items.Count-1 do
            if string(Formats.Items[J]).Contains(' PDF') then begin Index:=J; Break; end;
          Require(Index>=0,'EPUB has no PDF choice');
          Formats.ItemIndex:=Index; Formats.OnChange(Formats);
          var Destination:=TEdit(Dialog.FindComponent('SendDestination'));
          var SavedPath:=Destination.Text;
          WaitingForRuntime:=True; Timer.Enabled:=True;
          try
            for var Name in ['EstimateSaveSize','SendBooks'] do
            begin
              RuntimePromptSeen:=False; Deadline:=GetTickCount64+5000;
              TButton(Dialog.FindComponent(Name)).Perform(BM_CLICK,0,0);
              Require(RuntimePromptSeen,'Missing WebView2 did not prompt from '+Name);
              Require((Dialog.ModalResult=mrNone) and (Formats.ItemIndex=Index) and (Destination.Text=SavedPath),
                'Declining WebView2 changed the open Save As dialog');
            end;
          finally WaitingForRuntime:=False; Timer.Enabled:=False; end;
          Checked:=True; Dialog.ModalResult:=mrCancel; Exit;
        end
        else if Restored then
          Require(Extras.Checked and string(Formats.Text).Contains('KEPUB'),'Review lost the restored writer')
        else
        begin
          Require(not Extras.Checked and not string(Formats.Items.Text).Contains('KEPUB'),
            'Additional formats appeared in the ordinary list');
          Extras.Perform(BM_CLICK,0,0);
          Require(string(Formats.Items.Text).Contains(' PDF'),'Mixed FB2 and EPUB have no PDF choice');
          var Index:=-1;
          for var J:=0 to Formats.Items.Count-1 do
            if string(Formats.Items[J]).Contains('KEPUB') then begin Index:=J; Break; end;
          Require(Index>=0,'Mixed FB2 and EPUB have no common KEPUB choice');
          Require(not string(Formats.Items.Text).Contains('EPUB 2'),'FB2-only writer offered for mixed EPUB input');
          Formats.ItemIndex:=Index; Formats.OnChange(Formats);
        end;
        Require(string(Preview.Caption).EndsWith('.kepub.epub'),'Preview did not retain the full Kobo extension');
        Checked:=True;
      except on E:Exception do Failure:=E.Message; end;
      Dialog.ModalResult:=mrCancel;
      Exit;
    end;
  Require(GetTickCount64<Deadline,'Advanced Save As dialog did not open');
end;

procedure TestAdvancedBookSaving;
var Root, Status: string; Books: TArray<TBookRecord>; Options, Unused: TBookSendOptions;
  Results: TBookExportResults; Required: TArray<string>; SourceHashes: TArray<string>;
  Choice: TBookSaveChoice; Estimates: TBookSaveEstimateItems; EstimateThread: TBookSendEstimateThread;
  Probe: TUnifiedSendProbe; Review: TAdvancedSaveDialogProbe; Revision: Integer;
  Deadline: UInt64; Complete: Boolean;
  procedure CheckWebViewPrompt;
  var RegistryRoot: HKEY; Disposition: DWORD; ID: TGUID; Key, Bootstrapper: string;
  begin
    Bootstrapper:=GetEnvironmentVariable('HOMELIB_TEST_WEBVIEW2_BOOTSTRAPPER');
    if Bootstrapper<>'' then
    begin
      VerifyWebView2BootstrapperSignature(Bootstrapper);
      var Corrupted:=TFile.ReadAllBytes(Bootstrapper);
      Corrupted[4096]:=Corrupted[4096] xor 1;
      var Tampered:=TPath.Combine(Root,'invalid-webview2-installer.exe');
      TFile.WriteAllBytes(Tampered,Corrupted);
      var Rejected:=False;
      try VerifyWebView2BootstrapperSignature(Tampered);
      except on E:Exception do Rejected:=True; end;
      Require(Rejected,'A modified WebView2 installer was accepted');
    end;
    CreateGUID(ID); Key:='Software\HomeLibreNativeWebView2-'+GUIDToString(ID);
    Require(RegCreateKeyEx(HKEY_CURRENT_USER,PChar(Key),0,nil,REG_OPTION_VOLATILE,KEY_ALL_ACCESS,
      nil,RegistryRoot,@Disposition)=ERROR_SUCCESS,'Cannot prepare a private registry fixture');
    try
      Require(Disposition=REG_CREATED_NEW_KEY,'Registry fixture must be new');
      Require(RegOverridePredefKey(HKEY_CURRENT_USER,RegistryRoot)=ERROR_SUCCESS,'Cannot isolate user registry');
      try
        Require(RegOverridePredefKey(HKEY_LOCAL_MACHINE,RegistryRoot)=ERROR_SUCCESS,'Cannot isolate machine registry');
        try
          Require(not WebView2RuntimeInstalled,'Empty registry reported WebView2 installed');
          Review:=TAdvancedSaveDialogProbe.Create;
          try
            Review.TestRuntime:=True; Review.Deadline:=GetTickCount64+5000;
            Review.Timer:=TTimer.Create(nil); Review.Timer.Interval:=60; Review.Timer.OnTimer:=Review.Tick;
            Require(not ChooseBookSendOptions(1,Root,emEpub,Unused,False,[Books[1]]),
              'Declining the prerequisite started a save');
            Require(Review.Checked and (Review.Failure=''),Review.Failure);
          finally Review.Timer.Free; Review.Free; end;
        finally RegOverridePredefKey(HKEY_LOCAL_MACHINE,0); end;
      finally RegOverridePredefKey(HKEY_CURRENT_USER,0); end;
    finally
      RegCloseKey(RegistryRoot);
      if Disposition=REG_CREATED_NEW_KEY then
        Require(RegDeleteKey(HKEY_CURRENT_USER,PChar(Key))=ERROR_SUCCESS,'Cannot delete the private registry fixture');
    end;
    Require(Length(TDirectory.GetDirectories(Settings.TempPath,'HomeLibre-WebView2-*'))=0,
      'Declining WebView2 downloaded a bootstrapper');
    Writeln('PASS missing WebView2 prompt preserves estimate and save settings when declined'); Flush(Output);
  end;
  procedure InstallEpubPdf;
  const ID = 'EpubPdfExport';
  var Packages, Metadata, Feed, Archive, Job: string; Info: TProgramRelease;
  begin
    Require(IsOptionalComponent(ID) and not ComponentNotificationEnabled(ID,''),
      'EPUB PDF is not optional');
    var Missing:=MissingBookConversionComponents(Settings.AppPath,Books[1].GetBookFileName,
      '.epub',False,nil,'.pdf','pdf');
    Require(String.Join(',',Missing)=ID,'Installed EPUB prerequisites requested an unrelated module');
    Packages:=GetEnvironmentVariable('HOMELIB_FORMAT_COMPONENT_PACKAGES');
    Metadata:=TFile.ReadAllText(TPath.Combine(Packages,'local-mirror-release.json'),TEncoding.UTF8);
    Feed:=TFile.ReadAllText(TPath.Combine(Packages,COMPONENT_FEED_NAME),TEncoding.UTF8);
    Require(ParseComponentMirror(Metadata,Feed,ID,'',Info),'EPUB PDF entry rejected by the native feed parser');
    Archive:=TPath.Combine(Packages,ComponentVersionedArchiveName(ID,Info.ComponentVersion,ProgramUpdatePlatform));
    Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-epub-pdf');
    var MainFile:=TPath.Combine(Settings.AppPath,'HomeLibRu.exe');
    if not FileExists(MainFile) then TFile.Copy(ParamStr(0),MainFile);
    var MainHash:=UpdateSHA256(MainFile);
    try
      PrepareProgramUpdate(Archive,Info.SHA256,Info.Tag,ProgramUpdatePlatform,Job,True,ID,Info.ComponentVersion);
      VerifyPreparedProgramUpdate(Job,Info.Tag,ProgramUpdatePlatform);
      InstallProgramUpdate(Job,Settings.AppPath);
      Require((InstalledComponentVersion(Settings.AppPath,ID)=Info.ComponentVersion) and
        not ComponentNeedsRepair(Settings.AppPath,ID),'Installed EPUB PDF package failed identity verification');
      Require((UpdateSHA256(MainFile)=MainHash) and
        not DirectoryExists(TPath.Combine(Settings.AppPath,'tools/pdfium')),
        'EPUB PDF installation changed the application or installed the PDF reader');
    finally CleanProgramUpdate(Job); end;
  end;
  procedure CheckContinuation;
  var Name, Command: string; Startup: TStartupInfo; Process: TProcessInformation;
    Code: Cardinal; Plan: TBookSaveContinuation;
  begin
    Name:=TPath.Combine(Root,'advanced-save-plan.ini');
    Command:='"'+ParamStr(0)+'" save-plan-producer "'+Name+'" --target='+IntToStr(Ord(emKepub));
    UniqueString(Command);
    Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup); Process:=Default(TProcessInformation);
    Require(CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
      PChar(Settings.AppPath),Startup,Process),'Could not start advanced save plan producer');
    try
      Require(WaitForSingleObject(Process.hProcess,15000)=WAIT_OBJECT_0,'Advanced save plan producer did not exit');
      Require(GetExitCodeProcess(Process.hProcess,Code) and (Code=0),'Advanced save plan producer failed');
    finally CloseHandle(Process.hThread); CloseHandle(Process.hProcess); end;
    Require(TakeBookSaveContinuation(Name,Plan),'Could not restore the advanced save plan after process exit');
    Require((Plan.Options.Mode=emKepub) and Plan.Options.ExplicitFormat and (Plan.Options.ImageQuality='economy') and
      (Plan.RequiredComponent='KoboExport') and (Length(Plan.Books)=2),'Advanced continuation changed format, module or books');
    var Token:=Plan.Token;
    Require(not TakeBookSaveContinuation(Name,Plan),'Advanced save plan ran twice');
    ClearBookSaveContinuation(Name,Token);
  end;
begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath+'kindle-save-fixtures'+PathDelim;
  Books:=[FileBook(Root+'source.fb2'),FileBook(Root+'source.epub')];
  SourceHashes:=[UpdateSHA256(Books[0].GetBookFileName),UpdateSHA256(Books[1].GetBookFileName)];
  Require(BookSaveTargetExtension('.epub',emKepub,False,False)='.kepub.epub','Missing Kobo compound extension');
  for var Item in BookSaveChoices(['.pdf','.fb2'],True) do
    Require(not (Item.Mode in BOOK_SAVE_ADVANCED_MODES),'Unsupported source can reach an advanced writer');
  var EmptyRuntime:=Root+'without-modules';
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[0].GetBookFileName,'.fb2',False,nil,'.kepub.epub','kepub');
  Require(String.Join(',',Required)='BookProcessing,FB2Export','FB2 requests an unrelated Kobo module');
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[1].GetBookFileName,'.epub',False,nil,'.kepub.epub','kepub');
  Require(String.Join(',',Required)='BookProcessing,KoboExport','EPUB requests an unrelated FB2 writer');
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[0].GetBookFileName,'.fb2',False,nil,'.pdf','pdf');
  Require(String.Join(',',Required)='BookProcessing,FB2Export','FB2 to PDF must use only fb2cng');
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[1].GetBookFileName,'.epub',False,nil,'.pdf','pdf');
  Require(String.Join(',',Required)='BookProcessing,EpubPdfExport','EPUB to PDF must use only the EPUB writer');
  CheckContinuation;
  InstallEpubPdf;
  CheckWebViewPrompt;

  Options:=Default(TBookSendOptions); Options.Mode:=emKepub; Options.ExplicitFormat:=True;
  Options.FileNameTemplate:='%t'; Options.ImageQuality:='original'; Options.NameCollision:=bncKeepBoth;
  Options.Folder:=Root+'kobo-copies'; ForceDirectories(Options.Folder);
  Review:=TAdvancedSaveDialogProbe.Create;
  Review.Timer:=TTimer.Create(nil); Review.Timer.Interval:=50; Review.Timer.Enabled:=False; Review.Timer.OnTimer:=Review.Tick;
  try
    for var Restored in [False,True] do
    begin
      Review.Restored:=Restored; Review.Checked:=False; Review.Deadline:=GetTickCount64+15000; Review.Timer.Enabled:=True;
      var Initial: PBookSendOptions:=nil; if Restored then Initial:=@Options;
      Require(not ChooseBookSendOptions(Length(Books),Options.Folder,emFB2,Unused,False,Books,Initial),
        'Canceled advanced review reported an approved save');
      Require(Review.Checked and (Review.Failure=''),Review.Failure);
    end;
  finally Review.Timer.Free; Review.Free; end;

  for var Mode in [emKepub,emAdvancedPDF] do
  begin
    var Extension:=BookSaveTargetExtension('.epub',Mode,False,False);
    Options.Mode:=Mode;
    Options.Folder:=Root+'copies'+Extension;
    Choice:=Default(TBookSaveChoice); Choice.Mode:=Mode;
    EstimateThread:=TBookSendEstimateThread.Create(Books,Choice,Settings.AppPath,Settings.TempPath);
    try
      Revision:=-1; Complete:=False; Deadline:=GetTickCount64+180000; EstimateThread.Start;
      repeat
        Application.ProcessMessages; EstimateThread.Poll(Revision,Estimates,Status,Complete);
        Require(GetTickCount64<Deadline,'Advanced estimate timed out: '+Status);
        if not Complete then Sleep(10);
      until Complete;
      Require(Length(Estimates)=2,'Advanced estimate lost a book');
      for var Item in Estimates do
      begin
        Require(Item.Completed and (Item.ErrorText=''),Status+' '+Item.ErrorText);
        for var Quality:=0 to 3 do Require(Item.Options.OutputBytes[0,Quality]>0,'Advanced estimate missed an image choice');
      end;
    finally EstimateThread.Free; end;

    Probe:=TUnifiedSendProbe.Create;
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.Enabled:=False;
    Probe.Timer.OnTimer:=Probe.Tick; Probe.Messages:=TStringList.Create;
    try
      Probe.Deadline:=GetTickCount64+120000; Probe.Timer.Enabled:=True;
      Results:=SaveFileBooks(Books,Options,Required);
      Require((Length(Required)=0) and (Probe.Failure='') and (Length(Results)=2),
        'Advanced save did not finish: '+Probe.Failure+String.Join(', ',Required));
      Require(SuccessfulBookExportCount(Results)=2,Results[0].ErrorText+' '+Results[1].ErrorText);
      Require(not SameFileName(Results[0].OutputFile,Results[1].OutputFile),'Collision lost one advanced output');
      for var I:=0 to High(Results) do
      begin
        Require(Results[I].OutputFile.EndsWith(Extension,True),'Collision or save lost the expected extension');
        var Size:=TFile.GetSize(Results[I].OutputFile);
        Require(Abs(Size-Estimates[I].Options.OutputBytes[0,0])<=512,'Estimate did not measure the written format');
        Require(UpdateSHA256(Books[I].GetBookFileName)=SourceHashes[I],'Advanced save modified a source');
        if Mode=emAdvancedPDF then
        begin
          var FileStream:=TFileStream.Create(Results[I].OutputFile,fmOpenRead or fmShareDenyWrite);
          try
            var Signature: AnsiString;
            SetLength(Signature,5);
            FileStream.ReadBuffer(Signature[1],Length(Signature));
            Require(Signature='%PDF-','Advanced output has no PDF signature');
          finally FileStream.Free; end;
        end;
      end;
      Require(Length(TDirectory.GetFiles(Options.Folder))=2,'Advanced export left extra files');
    finally Probe.Timer.Free; Probe.Messages.Free; Probe.Free; end;
  end;
  Writeln('PASS advanced save compact choices restored review mixed Kobo and PDF estimates output collisions and source hashes'); Flush(Output);
end;
