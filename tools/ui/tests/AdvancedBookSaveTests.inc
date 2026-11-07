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
          Require(string(Formats.Items.Text).Contains('Markdown'),'Mixed FB2, EPUB and DOCX have no Markdown choice');
          var Index:=-1;
          for var J:=0 to Formats.Items.Count-1 do
            if string(Formats.Items[J]).Contains('KEPUB') then begin Index:=J; Break; end;
          Require(Index>=0,'Mixed FB2, EPUB and DOCX have no common KEPUB choice');
          Require(string(Formats.Items.Text).Contains('EPUB 2'),'Mixed FB2, EPUB and DOCX have no EPUB 2 choice');
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
            Require(not ChooseBookSendOptions(1,Root,emEpub,Unused,False,[Books[2]]),
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
  Books:=[FileBook(Root+'source.fb2'),FileBook(Root+'source.epub'),FileBook(Root+'source.docx')];
  for var Book in Books do SourceHashes:=SourceHashes+[UpdateSHA256(Book.GetBookFileName)];
  Require(BookSaveTargetExtension('.epub',emKepub,False,False)='.kepub.epub','Missing Kobo compound extension');
  for var Item in BookSaveChoices(['.sqlite','.fb2'],True) do
    Require(not (Item.Mode in BOOK_SAVE_ADVANCED_MODES),'Unsupported source can reach an advanced writer');
  for var Item in BookSaveChoices(['.pdf'],True) do
    Require(Item.Mode<>emAdvancedPDF,'An all-PDF selection offers duplicate output');
  var HasEpub3:=False;
  for var Item in BookSaveChoices(['.fb2','.epub','.docx'],True) do
    if Item.Mode=emEpub3 then HasEpub3:=True;
  Require(HasEpub3,'Mixed FB2, EPUB and DOCX cannot choose EPUB 3');
  var MarkdownChoices:=BookSaveChoices(['.md','.markdown'],True);
  Require(MarkdownChoices[0].KeepOriginal and MarkdownChoices[0].Caption.Contains('Markdown'),
    'Markdown source copy is not labeled');
  for var Item in MarkdownChoices do
    Require(Item.Mode<>emMarkdown,'An all-Markdown selection offers duplicate output');
  var EmptyRuntime:=Root+'without-modules';
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[0].GetBookFileName,'.fb2',False,nil,'.kepub.epub','kepub');
  Require(String.Join(',',Required)='BookProcessing,FB2Export','FB2 requests an unrelated Kobo module');
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[1].GetBookFileName,'.epub',False,nil,'.kepub.epub','kepub');
  Require(String.Join(',',Required)='BookProcessing,KoboExport','EPUB requests an unrelated FB2 writer');
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[0].GetBookFileName,'.fb2',False,nil,'.pdf','pdf');
  Require(String.Join(',',Required)='BookProcessing,FB2Export','FB2 to PDF must use only fb2cng');
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[1].GetBookFileName,'.epub',False,nil,'.pdf','pdf');
  Require(String.Join(',',Required)='BookProcessing,EpubPdfExport','EPUB to PDF must use only the EPUB writer');
  Required:=MissingBookConversionComponents(EmptyRuntime,Books[2].GetBookFileName,'.docx',False,nil,'.pdf','pdf');
  Require(String.Join(',',Required)='BookProcessing,EpubPdfExport','DOCX requested an unrelated module');
  for var Index in [1,2] do
  begin
    Required:=MissingBookConversionComponents(EmptyRuntime,Books[Index].GetBookFileName,Books[Index].FileExt,False,nil,'.epub','epub3');
    Require(String.Join(',',Required)='BookProcessing','Direct EPUB 3 requested an unrelated writer');
    Required:=MissingBookConversionComponents(EmptyRuntime,Books[Index].GetBookFileName,Books[Index].FileExt,False,nil,'.epub','epub2');
    Require(String.Join(',',Required)='BookProcessing','Direct EPUB 2 requested an unrelated writer');
  end;
  for var Index in [0,1,2] do
  begin
    Required:=MissingBookConversionComponents(EmptyRuntime,Books[Index].GetBookFileName,Books[Index].FileExt,False,nil,'.md','md');
    var Expected:='BookProcessing';
    if Index=0 then Expected:=Expected+',FB2Export';
    Require(String.Join(',',Required)=Expected,'Markdown requested the wrong modules');
  end;
  Required:=MissingBookConversionComponents(EmptyRuntime,'','.djvu',False,nil,'.kepub.epub','kepub');
  Require(String.Join(',',Required)='BookProcessing,KoboExport,DjVuLibre','DjVu did not request its source reader and Kobo writer');
  var Capability:=TPath.Combine(Settings.AppPath,'tools/bookconvert/ADVANCED_EXPORT_API.txt');
  var CurrentAPI:=TFile.ReadAllBytes(Capability);
  try
    TFile.WriteAllText(Capability,'4',TEncoding.ASCII);
    Required:=MissingBookConversionComponents(Settings.AppPath,Books[1].GetBookFileName,'.epub',False,nil,'.epub','epub2');
    Require(String.Join(',',Required)='BookProcessing','An old engine was accepted for explicit EPUB 2');
    TFile.WriteAllText(Capability,'3',TEncoding.ASCII);
    Required:=MissingBookConversionComponents(Settings.AppPath,Books[1].GetBookFileName,'.epub',False,nil,'.epub','epub3');
    Require(String.Join(',',Required)='BookProcessing','An old engine was accepted for explicit EPUB 3');
    TFile.WriteAllText(Capability,'2',TEncoding.ASCII);
    Required:=MissingBookConversionComponents(Settings.AppPath,Books[1].GetBookFileName,'.epub',False,nil,'.md','md');
    Require(String.Join(',',Required)='BookProcessing','An old engine was accepted for EPUB to Markdown');
    TFile.WriteAllText(Capability,'1',TEncoding.ASCII);
    Required:=MissingBookConversionComponents(Settings.AppPath,Books[2].GetBookFileName,'.docx',False,nil,'.kepub.epub','kepub');
    Require(String.Join(',',Required)='BookProcessing','An old engine was accepted for DOCX to KEPUB');
    Required:=MissingBookConversionComponents(Settings.AppPath,Books[1].GetBookFileName,'.epub',False,nil,'.kepub.epub','kepub');
    Require(Length(Required)=0,'An old engine was unnecessarily upgraded for direct EPUB to KEPUB');
  finally TFile.WriteAllBytes(Capability,CurrentAPI); end;
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

  var Originals:=Books;
  var OriginalHashes:=SourceHashes;
  var MarkdownPath:=Root+'source.markdown';
  TFile.WriteAllText(MarkdownPath,'# Markdown input'+sLineBreak+'Keep all bytes.',TEncoding.UTF8);
  for var Mode in [emKepub,emMarkdown,emAdvancedPDF,emEpub3,emEpub2] do
  begin
    Books:=Originals;
    SourceHashes:=OriginalHashes;
    if Mode=emMarkdown then
    begin
      Books:=Books+[FileBook(MarkdownPath)];
      SourceHashes:=SourceHashes+[UpdateSHA256(MarkdownPath)];
    end;
    if Mode=emAdvancedPDF then
    begin
      var OriginalPDF:=FileBook(Root+'source.pdf');
      Books:=Books+[OriginalPDF];
      SourceHashes:=SourceHashes+[UpdateSHA256(OriginalPDF.GetBookFileName)];
    end;
    var Extension:=BookSaveTargetExtension('.epub',Mode,False,False);
    Options.Mode:=Mode;
    Options.Folder:=Root+'copies'+Extension;
    if Mode=emEpub2 then Options.Folder:=Root+'copies-epub2';
    Choice:=Default(TBookSaveChoice); Choice.Mode:=Mode;
    EstimateThread:=TBookSendEstimateThread.Create(Books,Choice,Settings.AppPath,Settings.TempPath);
    try
      Revision:=-1; Complete:=False; Deadline:=GetTickCount64+180000; EstimateThread.Start;
      repeat
        Application.ProcessMessages; EstimateThread.Poll(Revision,Estimates,Status,Complete);
        Require(GetTickCount64<Deadline,'Advanced estimate timed out: '+Status);
        if not Complete then Sleep(10);
      until Complete;
      Require(Length(Estimates)=Length(Books),'Advanced estimate lost a book');
      if Mode in [emAdvancedPDF,emMarkdown] then
        Require(Estimates[High(Estimates)].ImagesUnchanged,'Existing output format was not estimated as an original copy');
      for var Item in Estimates do
      begin
        Require(Item.Completed and (Item.ErrorText=''),Status+' '+Item.ErrorText);
        for var Quality:=0 to 3 do Require(Item.Options.OutputBytes[0,Quality]>0,'Advanced estimate missed an image choice');
      end;
    finally EstimateThread.Free; end;

    Probe:=TUnifiedSendProbe.Create;
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.Enabled:=False;
    Probe.Timer.OnTimer:=Probe.Tick; Probe.Messages:=TStringList.Create;
    Probe.SavedModal:=Application.OnModalBegin; Application.OnModalBegin:=Probe.ModalBegin;
    try
      Probe.Deadline:=GetTickCount64+120000; Probe.Timer.Enabled:=True;
      try Results:=SaveFileBooks(Books,Options,Required);
      finally Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
      Require((Length(Required)=0) and (Probe.Failure='') and (Length(Results)=Length(Books)),
        'Advanced save did not finish: '+Probe.Failure+String.Join(', ',Required));
      for var Item in Results do Require(Item.State=besSucceeded,Item.ErrorText);
      if Mode in [emAdvancedPDF,emMarkdown] then
        Require(UpdateSHA256(Results[High(Results)].OutputFile)=SourceHashes[High(SourceHashes)],
          'Mixed export changed a book in the selected format');
      Require(not SameFileName(Results[0].OutputFile,Results[1].OutputFile),'Collision lost one advanced output');
      for var I:=0 to High(Results) do
      begin
        Require(Results[I].OutputFile.EndsWith(BookSaveTargetExtension(Books[I].FileExt,Mode,False,False),True),
          'Collision or save lost the expected extension');
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
        if (Mode=emMarkdown) and (I<High(Results)) then
        begin
          var Markdown:=TFile.ReadAllText(Results[I].OutputFile,TEncoding.UTF8);
          Require(Markdown.Contains('# ') and Markdown.Contains('data:image/'),
            'Markdown has no headings or embedded illustration');
        end;
      end;
      Require(Length(TDirectory.GetFiles(Options.Folder))=Length(Books),'Advanced export left extra files');
    finally
      Application.OnModalBegin:=Probe.SavedModal;
      Probe.Timer.Free; Probe.Messages.Free; Probe.Free;
    end;
  end;
  Writeln('PASS advanced save compact choices restored review mixed Kobo and PDF estimates output collisions and source hashes'); Flush(Output);
  Writeln('PASS mixed Markdown save estimates modules images and byte-identical source copy'); Flush(Output);
  Writeln('PASS mixed EPUB 3 save estimates modules and original source hashes'); Flush(Output);
  Writeln('PASS mixed EPUB 2 save estimates modules and original source hashes'); Flush(Output);
end;
