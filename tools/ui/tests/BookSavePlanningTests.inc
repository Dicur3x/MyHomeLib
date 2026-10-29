procedure WriteBookSavePlanChild;
var Options: TBookSendOptions; Books: TBookIdList;
begin
 try
  Options:=Default(TBookSendOptions); Options.Folder:=ExtractFilePath(ParamStr(2))+'saved';
  Options.Mode:=emEpub; Options.KeepFB2EPUB:=ParamStr(4)<>'host'; Options.ExplicitFormat:=True;
  Options.ZipEachBook:=True; Options.FileNameTemplate:='[%s - ][%n - ]%t';
  Options.FolderTemplate:='%f\[%s]'; Options.ImageQuality:='economy|auto|except=1,9-10';
  if ParamStr(3)='' then
  begin
    SetLength(Books,2);
    for var I:=0 to High(Books) do
    begin
      Books[I].BookKey:=CreateBookKey(101+I,1); Books[I].HasExpectedIdentity:=True;
      Books[I].ExpectedLibID:='lib-Ё-'+IntToStr(I); Books[I].ExpectedPhysicalIdentity:='archive|member-'+IntToStr(I);
    end;
  end;
  StoreBookSaveContinuation(ParamStr(2),'BookConverter',Options,Books,ParamStr(3));
  ArmBookSaveContinuation(ParamStr(2),'BookConverter');
 except
   on E: Exception do
   begin TFile.WriteAllText(ParamStr(2)+'.producer-error.txt',E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
 end;
end;

type
  TSaveHostResumeProbe = class
    Host: TfrmReaderHost;
    Probe: TUnifiedSendProbe;
    Timer: TTimer;
    Completed: Boolean;
    Failure: string;
    procedure Tick(Sender: TObject);
  end;

procedure TSaveHostResumeProbe.Tick(Sender: TObject);
var View: TfrmBuiltinReader;
begin
  View:=nil;
  for var I:=0 to Host.ComponentCount-1 do
    if Host.Components[I] is TfrmBuiltinReader then View:=TfrmBuiltinReader(Host.Components[I]);
  try
    Require(GetTickCount64<Probe.Deadline,'Reader host did not restore its Save As review');
    for var I:=0 to Screen.FormCount-1 do
      if (Screen.Forms[I] is TBookSendOptionsForm) and Screen.Forms[I].Visible then
      begin
        Require(Assigned(View) and View.Visible and not Host.Visible,
          'Restored save showed the empty launcher instead of the book');
        Require(TForm(Screen.Forms[I]).PopupParent=View,
          'Restored save dialog is not owned by the visible book');
        Probe.Tick(Sender); Exit;
      end;
    if Probe.Dialogs=0 then Exit;
    Require(Assigned(View),'Cancelling restored save closed the reading view');
    if not View.Ready or View.PageLoading then Exit;
    Require(View.BookText.Contains('HOST RESUME ORIGINAL TEXT'),
      'Reader host resumed saving a different book');
    Require((Probe.Dialogs=1) and (Probe.Failure=''),'Reader host repeated the restored review');
    Completed:=True;
  except
    on E: Exception do
    begin
      Failure:=E.ClassName+': '+E.Message;
      for var I:=0 to Screen.FormCount-1 do
        if Screen.Forms[I] is TBookSendOptionsForm then Screen.Forms[I].ModalResult:=mrCancel;
    end;
  end;
  Timer.Enabled:=False;
  if Assigned(View) then View.Close;
end;

procedure TestReaderSaveHostResume;
var Source, Hash, Command: string; Startup: TStartupInfo; Process: TProcessInformation;
  Code: Cardinal; Host: TfrmReaderHost; Driver: TSaveHostResumeProbe; Started: UInt64;
  SavedShowMain: Boolean;
begin
  RequireIsolatedRegression;
  Source:=Settings.AppPath+'host-resume.fb2';
  TFile.WriteAllText(Source,'<FictionBook><body><section><p>HOST RESUME ORIGINAL TEXT</p></section></body></FictionBook>',TEncoding.UTF8);
  Hash:=UpdateSHA256(Source);
  Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  Command:='"'+ParamStr(0)+'" save-plan-producer "'+Settings.SettingsFileName+'" "'+Source+'" host';
  UniqueString(Command);
  Require(CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
    PChar(Settings.AppPath),Startup,Process),'Cannot create the previous reader save process');
  try
    Require(WaitForSingleObject(Process.hProcess,15000)=WAIT_OBJECT_0,'Previous reader save process did not exit');
    Require(GetExitCodeProcess(Process.hProcess,Code) and (Code=0),'Previous reader save process failed');
  finally CloseHandle(Process.hThread); CloseHandle(Process.hProcess); end;
  SavedShowMain:=Application.ShowMainForm;
  Host:=TfrmReaderHost.Create(nil); Driver:=TSaveHostResumeProbe.Create;
  Driver.Host:=Host; Driver.Probe:=TUnifiedSendProbe.Create;
  try
    Driver.Probe.Initial:=Default(TBookSendOptions);
    Driver.Probe.Initial.Mode:=emEpub; Driver.Probe.Initial.ExplicitFormat:=True;
    Driver.Probe.Initial.ZipEachBook:=True;
    Driver.Probe.Initial.Folder:=ExtractFilePath(Settings.SettingsFileName)+'saved';
    Driver.Probe.Initial.FileNameTemplate:='[%s - ][%n - ]%t';
    Driver.Probe.Initial.FolderTemplate:='%f\[%s]';
    Driver.Probe.Initial.ImageQuality:='economy|auto|except=1,9-10';
    Driver.Probe.VerifyInitial:=True; Driver.Probe.Deadline:=GetTickCount64+20000;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Tick;
    Host.OpenInitialFile(Source); Host.Show; Started:=GetTickCount64;
    repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
    until Driver.Completed or (Driver.Failure<>'') or (GetTickCount64-Started>25000);
    Require(Driver.Completed and (Driver.Failure=''),'Reader Save As host integration failed: '+Driver.Failure);
    Require(not FileExists(BookSaveContinuationFile(Settings.SettingsFileName)),
      'Reader host did not clear the consumed save review');
    Require(not DirectoryExists(Driver.Probe.Initial.Folder),'Review cancellation created output');
    Require(UpdateSHA256(Source)=Hash,'Reader save continuation changed the source book');
    Writeln('PASS actual reader host consumes restarted Save As once, restores options over visible book, cancels without output and preserves source');
  finally
    Driver.Timer.Free; Driver.Probe.Free; Driver.Free; Host.Free;
    Application.ShowMainForm:=SavedShowMain;
  end;
end;

procedure TestBookSaveContinuation;
var Name, Source, Token: string; Plan: TBookSaveContinuation; Options: TBookSendOptions;
  Books: TBookIdList; Startup: TStartupInfo; Process: TProcessInformation; Command: string;
  Code: Cardinal;
  procedure Child(const SourceFile: string = '');
  begin
    Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
    Process:=Default(TProcessInformation);
    Command:='"'+ParamStr(0)+'" save-plan-producer "'+Name+'"';
    if SourceFile<>'' then Command:=Command+' "'+SourceFile+'"';
    UniqueString(Command);
    Require(CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
      PChar(Settings.AppPath),Startup,Process),'Cannot start save-plan producer');
    try
      Require(WaitForSingleObject(Process.hProcess,15000)=WAIT_OBJECT_0,'Save-plan producer did not exit');
      Require(GetExitCodeProcess(Process.hProcess,Code),'Cannot read producer exit code');
      if Code<>0 then
      begin
        var Details:='exit='+IntToStr(Code);
        if FileExists(Name+'.producer-error.txt') then Details:=TFile.ReadAllText(Name+'.producer-error.txt',TEncoding.UTF8);
        raise Exception.Create('Save-plan producer failed: '+Details);
      end;
    finally CloseHandle(Process.hThread); CloseHandle(Process.hProcess); end;
  end;
begin
  Name:=Settings.AppPath+'save-plan-test.ini';
  Options:=Default(TBookSendOptions); Options.Folder:=Settings.AppPath+'saved';
  Options.Mode:=emFB2; Options.FileNameTemplate:='%t'; Options.ImageQuality:='original';
  SetLength(Books,1); Books[0].BookKey:=CreateBookKey(7,1); Books[0].HasExpectedIdentity:=True;
  Books[0].ExpectedLibID:='original-7';
  StoreBookSaveContinuation(Name,'BookConverter',Options,Books);
  ArmBookSaveContinuation(Name,'PDFium');
  Require(not FileExists(BookSaveContinuationFile(Name)+'.ready'),'Unrelated update armed a save plan');
  ArmBookSaveContinuation(Name,'BookConverter');
  Require(not TakeBookSaveContinuation(Name,Plan),'A live originating process lost ownership of its save plan');
  Child;
  Require(TakeBookSaveContinuation(Name,Plan),'Successor cannot reopen a completed producer plan');
  Token:=Plan.Token;
  Require((Length(Plan.Books)=2) and (Plan.Books[1].ExpectedLibID='lib-Ё-1') and
    (Plan.Books[1].BookKey.BookID=102) and Plan.Books[1].HasExpectedIdentity,
    'Save restart lost the remaining books or their identities');
  Require(Plan.Options.KeepFB2EPUB and Plan.Options.ZipEachBook and
    (Plan.Options.Mode=emEpub) and (Plan.Options.FolderTemplate='%f\[%s]') and
    (Plan.Options.ImageQuality='economy|auto|except=1,9-10'),'Save restart lost source policy, ZIP, folders or image layout');
  Require(not TakeBookSaveContinuation(Name,Plan),'Save restart can be consumed twice');
  ClearBookSaveContinuation(Name,'wrong-token');
  Require(FileExists(BookSaveContinuationFile(Name)),'Old dialog removed a newer save plan');
  ClearBookSaveContinuation(Name,Token);
  Require(not FileExists(BookSaveContinuationFile(Name)),'Completed save plan was retained');
  Source:=Settings.AppPath+'plan-source.fb2'; TFile.WriteAllText(Source,'source',TEncoding.UTF8);
  Child(Source); TFile.AppendAllText(Source,' changed',TEncoding.UTF8);
  var Failed:=False;
  try TakeBookSaveContinuation(Name,Plan); except on E: Exception do Failed:=E.Message.Contains('изменился'); end;
  Require(Failed,'Restart silently accepted a changed source file');
  Require(not FileExists(BookSaveContinuationFile(Name)+'.ready'),'Invalid source left an endlessly repeating restart prompt');
  Child;
  var Lines:=TFile.ReadAllLines(BookSaveContinuationFile(Name),TEncoding.UTF8);
  var Header:=TJSONObject.ParseJSONValue(Lines[0]) as TJSONObject;
  try
    Header.RemovePair('count').Free; Header.AddPair('count',TJSONNumber.Create(2000000000));
    Lines[0]:=Header.ToJSON;
  finally Header.Free; end;
  TFile.WriteAllLines(BookSaveContinuationFile(Name),Lines,TEncoding.UTF8);
  Failed:=False;
  try TakeBookSaveContinuation(Name,Plan); except on E: Exception do Failed:=E.Message.Contains('число'); end;
  Require(Failed,'Untrusted row count can allocate an unbounded save plan');
  Writeln('PASS save continuation exact Unicode options remaining identities one consumer live owner stale source unrelated update and bounded count');
end;

procedure TestBookSaveEstimates;
const XML='<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
  '<description><title-info><book-title>Оценка Ё</book-title><lang>ru</lang></title-info></description>'+
  '<body><section><p>Полный текст для сохранения и проверки размера.</p></section></body></FictionBook>';
var Source, Opaque, Status: string; Books: TArray<TBookRecord>; Choice: TBookSaveChoice;
  Thread: TBookSendEstimateThread; Items: TBookSaveEstimateItems; Revision: Integer; Complete: Boolean;
  procedure WaitForEstimate;
  var Deadline: UInt64;
  begin
    Deadline:=GetTickCount64+45000; Revision:=-1; Complete:=False; Thread.Start;
    repeat
      Application.ProcessMessages; Thread.Poll(Revision,Items,Status,Complete);
      if GetTickCount64>Deadline then begin Thread.Terminate; raise Exception.Create('Save estimate did not finish: '+Status); end;
      if not Complete then Sleep(10);
    until Complete;
    Require(not Assigned(Thread.FatalException),'Size worker raised an unexpected error');
  end;
begin
  Source:=Settings.AppPath+'estimate-source.fb2'; Opaque:=Settings.AppPath+'estimate-source.pdf';
  TFile.WriteAllText(Source,XML,TEncoding.UTF8); TFile.WriteAllText(Opaque,'%PDF-1.4 copy-only',TEncoding.ASCII);
  Books:=[FileBook(Source),FileBook(Opaque)]; Choice:=BookSaveChoices(['fb2','pdf'])[0];
  Items:=KnownBookSaveEstimates(Books,Choice);
  Require((Items[0].Options.OutputBytes[0,0]=TFile.GetSize(Source)) and
    (Items[0].Options.OutputBytes[0,1]=0),'Initial FB2 estimate invents compressed output size');
  Require(Items[1].Options.OutputBytes[0,3]=TFile.GetSize(Opaque),'Opaque original does not show its known copy size');
  var Hash:=UpdateSHA256(Source);
  Thread:=TBookSendEstimateThread.Create(Books,Choice,Settings.AppPath,Settings.TempPath);
  try
    WaitForEstimate;
    Require((Length(Items)=2) and Items[0].Completed and (Items[0].ErrorText=''),Status+' '+Items[0].ErrorText);
    Require(Items[0].Options.OutputBytes[0,0]=TFile.GetSize(Source),'Estimate lost exact original FB2 size');
    for var Quality:=0 to 3 do
    begin
      Require(Items[0].Options.OutputBytes[0,Quality]>0,'A no-image text book has no mode estimate');
      Require(Items[0].Options.ZipOutputBytes[0,Quality]>0,'ZIP output is not estimated');
    end;
    Require((Items[1].ErrorText='') and (Items[1].Options.ZipOutputBytes[0,0]>0),'Native opaque ZIP estimate requested conversion');
  finally Thread.Free; end;
  Thread:=TBookSendEstimateThread.Create([Books[0]],Choice,Settings.AppPath+'no-converter\',Settings.TempPath);
  try
    WaitForEstimate;
    Require((Items[0].RequiredComponent='BookProcessing') and (Items[0].ErrorText<>''),
      'Unavailable size module was presented as a successful estimate');
  finally Thread.Free; end;
  Thread:=TBookSendEstimateThread.Create(Books,Choice,Settings.AppPath,Settings.TempPath);
  try Thread.Terminate; WaitForEstimate; Require(not Items[0].Completed,'Cancelled estimate reported completion');
  finally Thread.Free; end;
  Require(UpdateSHA256(Source)=Hash,'Size estimation changed source bytes');
  Writeln('PASS save estimate known bytes four modes native ZIP unavailable module cancellation and unchanged source');
end;

procedure TestRestoredSaveOptions;
var Probe: TUnifiedSendProbe; Options: TBookSendOptions;
begin
  Probe:=TUnifiedSendProbe.Create;
  try
    Probe.Initial:=Default(TBookSendOptions); Probe.Initial.Mode:=emEpub;
    Probe.Initial.KeepFB2EPUB:=True; Probe.Initial.ZipEachBook:=True;
    Probe.Initial.Folder:=Settings.AppPath+'restored destination ё';
    Probe.Initial.FileNameTemplate:='[%n - ]%t'; Probe.Initial.FolderTemplate:='%f\[%s]';
    Probe.Initial.ImageQuality:='economy|auto|except=1,9-10';
    Probe.VerifyInitial:=True; Probe.Deadline:=GetTickCount64+10000;
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
    Require(not ChooseBookSendOptions(2,'C:\wrong-fallback',emFB2,Options,True,
      [FileBook(Settings.AppPath+'estimate-source.fb2'),FileBook(Settings.AppPath+'estimate-source.pdf')],@Probe.Initial),
      'Cancelled restored options started a save');
    Require((Probe.Dialogs=1) and (Probe.Failure=''),'Restored save options did not appear');
    Probe.Initial.Mode:=emFB2Zip; Probe.Initial.KeepSourceFormat:=True; Probe.Initial.KeepFB2EPUB:=False;
    Probe.Initial.ZipEachBook:=False; Probe.Dialogs:=0; Probe.Deadline:=GetTickCount64+10000;
    Require(not ChooseBookSendOptions(1,'C:\wrong-fallback',emFB2,Options,True,
      [FileBook(Settings.AppPath+'estimate-source.fb2')],@Probe.Initial),
      'Cancelling the restored explicit FB2 ZIP choice started a save');
    Require((Probe.Dialogs=1) and (Probe.Failure=''),'Restored FB2 ZIP choice did not appear');
  finally Probe.Timer.Free; Probe.Free; end;
  Writeln('PASS restored Save As dialog keeps mixed policy image quality ZIP masks path and scan exclusions');
end;

procedure TestCompactSavePrompt;
var Server: TUpdateProposalServer; Dialog: TOptionalUpdateForm; Small: TForm; Started: UInt64;
  Releases: TComponentReleases; SavedDark: Boolean;
begin
  Server:=TUpdateProposalServer.Create; Dialog:=TOptionalUpdateForm.CreateForHead(Server.HeadURL);
  SavedDark:=MHLThemeDark;
  try
    Dialog.RequestComponent('DocSharp','Для сохранения выбранных книг нужен модуль DOC.',True);
    Started:=GetTickCount64;
    while not (Dialog.FindComponent('UpdateCheckComponents') as TButton).Enabled do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<10000,'Compact module check did not finish');
    end;
    Releases:=Default(TComponentReleases);
    for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do if UPDATE_COMPONENTS[I].ID='DocSharp' then
    begin
      Releases[I].ComponentID:='DocSharp'; Releases[I].ComponentVersion:='99.0';
      Releases[I].DownloadURL:='https://example.invalid/never-downloaded.zip';
      Releases[I].Size:=12345678; Releases[I].SHA256:=StringOfChar('a',64);
    end;
    Dialog.ComponentsReceived(Releases,True,''); Application.ProcessMessages;
    Small:=Dialog.FindComponent('OptionalComponentPrompt') as TForm;
    Require(Assigned(Small) and Small.Visible and not Dialog.Visible,'Operation exposed the full updater');
    Require((Dialog.DownloadID='') and TButton(Small.FindComponent('ComponentPromptDownload')).Enabled,
      'Compact prompt downloaded without a click or offers no action');
    Require(Pos('сохранения',TMemo(Small.FindComponent('ComponentPromptReason')).Text)>0,
      'Compact prompt lost the reason for the module');
    Require(Pos('DocSharp — модуль чтения DOC',TMemo(Small.FindComponent('ComponentPromptReason')).Text)>0,
      'Compact prompt omits the named source reader engine');
    Require(Assigned(Small.FindComponent('ComponentPromptBytes')) and
      (string(TLabel(Small.FindComponent('ComponentPromptBytes')).Caption)<>''),'Compact prompt omits download size');
    for var Dark in [False,True] do for var PPI in [96,144,192] do
    begin
      SetMHLTheme(Dark); Small.ScaleForPPI(PPI); Application.ProcessMessages;
      for var I:=0 to Small.ControlCount-1 do
      begin
        var Control:=Small.Controls[I]; if not Control.Visible then Continue;
        Require((Control.Left>=0) and (Control.Top>=0) and
          (Control.Left+Control.Width<=Small.ClientWidth) and
          (Control.Top+Control.Height<=Small.ClientHeight),'Compact prompt control is clipped');
      end;
    end;
    TButton(Small.FindComponent('ComponentPromptCancel')).Click; Application.ProcessMessages;
    Require(not Small.Visible and (Dialog.DownloadID=''),'Declining module prompt started a download');
    Dialog.UseFullWindow;
    Require(not Assigned(Dialog.FindComponent('OptionalComponentPrompt')),'Manual updater retained the compact prompt');
    Writeln('PASS compact save module prompt reason size explicit action cancel and hidden full updater at 96 144 192 DPI');
  finally SetMHLTheme(SavedDark); Dialog.Free; Server.Free; end;
end;

procedure TestRealMixedBookSaving;
var Root, Required, Status: string; Books: TArray<TBookRecord>; Hashes: TArray<string>;
  Options: TBookSendOptions; Results: TBookExportResults; Probe: TUnifiedSendProbe;
  Choice: TBookSaveChoice; Thread: TBookSendEstimateThread; Items: TBookSaveEstimateItems;
  Revision: Integer; Complete: Boolean; Deadline: UInt64;
  procedure Run(const Name: string; Mode: TExportMode; Keep, Prefer, Zipped: Boolean);
  var Expected, Target: string; Document: TReaderDocument; Archive: TZipFile; Bytes: TBytes;
  begin
    Options:=Default(TBookSendOptions); Options.Folder:=TPath.Combine(Root,Name);
    ForceDirectories(Options.Folder); Options.Mode:=Mode; Options.KeepSourceFormat:=Keep;
    Options.KeepFB2EPUB:=Prefer; Options.ExplicitFormat:=not Keep;
    Options.ImageQuality:='original'; Options.ZipEachBook:=Zipped;
    Probe.Deadline:=GetTickCount64+120000; Probe.Messages.Clear; Probe.Worker:=nil;
    Probe.Timer.Enabled:=True;
    try Results:=SaveFileBooks(Books,Options,Required);
    finally Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
    Require((Required='') and (Probe.Failure=''),Name+': '+Required+Probe.Failure);
    Require(Length(Results)=Length(Books),Name+': mixed results incomplete');
    for var I:=0 to High(Results) do
    begin
      Require(Results[I].State=besSucceeded,Name+': '+Results[I].ErrorText+Probe.Messages.Text);
      Expected:=BookSaveTargetExtension(Books[I].FileExt,Mode,Keep,Prefer);
      Target:=Results[I].OutputFile;
      if BookSaveZipsTarget(Expected,Mode,Zipped) then
      begin
        Archive:=TZipFile.Create;
        try
          Archive.Open(Target,zmRead);
          Require((Archive.FileCount=1) and SameText(ExtractFileExt(Archive.FileNames[0]),Expected),
            Name+': wrong format inside ZIP');
          Archive.Read(Archive.FileNames[0],Bytes);
        finally Archive.Free; end;
        Target:=TPath.Combine(Options.Folder,'check-'+IntToStr(I)+Expected);
        TFile.WriteAllBytes(Target,Bytes);
      end;
      Require(SameText(ExtractFileExt(Target),Expected),Name+': changed requested format');
      if SameText(Books[I].FileExt,Expected) then
        Require(UpdateSHA256(Target)=Hashes[I],Name+': matching format was converted unnecessarily');
      if (Expected='.fb2') or (Expected='.epub') then
      begin
        Document:=TReaderDocument.Create;
        try
          Document.Load(Target);
          Require((Length(Trim(Document.PlainText))>0) or (Document.ImageCount>0),Name+': empty result');
          if I<=1 then Require(Document.PlainText.Contains('Full text, final sentence. Ё, Україна, 中文.'),
            Name+': Unicode text was lost');
          // The guide's OCR page contains text only. It must remain readable;
          // the independent scan variant below must retain the entire image.
          if I=3 then Require(Document.PlainText.Contains('knowledge'),Name+': DjVu OCR text was lost')
          else Require(Document.ImageCount>0,Name+' '+Books[I].FileExt+': source illustration/page was lost');
        finally Document.Free; end;
      end;
      Require(UpdateSHA256(Books[I].GetBookFileName)=Hashes[I],Name+': changed source book');
    end;
    Writeln('PASS real mixed save ',Name,' FB2 EPUB PDF DjVu scan-PDF scan-DjVu'); Flush(Output);
  end;
begin
  Root:=Settings.AppPath+'mixed-save-inputs';
  Require(DirectoryExists(Root),'Real mixed conversion fixtures were not prepared');
  SetLength(Books,6); SetLength(Hashes,6);
  var Names:TArray<string>:=TArray<string>.Create('source.fb2','source.epub','source.pdf','source.djvu','scan.pdf','scan.djvu');
  for var I:=0 to High(Books) do
  begin Books[I]:=FileBook(TPath.Combine(Root,Names[I])); Hashes[I]:=UpdateSHA256(Books[I].GetBookFileName); end;
  Probe:=TUnifiedSendProbe.Create; Probe.Messages:=TStringList.Create;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
  Probe.SavedModal:=Application.OnModalBegin; Application.OnModalBegin:=Probe.ModalBegin;
  try
    Run('original',emFB2,True,False,False);
    Run('all-fb2',emFB2,False,False,False);
    Run('all-fb2-zip',emFB2Zip,False,False,False);
    Run('all-epub-legacy-zip-ignored',emEpub,False,False,True);
    Run('keep-fb2-epub-other-fb2',emFB2,False,True,False);
    Run('keep-epub-other-fb2-zip',emFB2Zip,False,True,False);
    Run('keep-fb2-epub-other-epub',emEpub,False,True,False);
  finally
    Application.OnModalBegin:=Probe.SavedModal; Probe.Timer.Free; Probe.Messages.Free; Probe.Free;
  end;
  Choice:=BookSaveChoices(['.fb2','.epub','.pdf','.djvu'])[3];
  Thread:=TBookSendEstimateThread.Create(Books,Choice,Settings.AppPath,Settings.TempPath);
  try
    Revision:=-1; Complete:=False; Deadline:=GetTickCount64+120000; Thread.Start;
    repeat
      Application.ProcessMessages; Thread.Poll(Revision,Items,Status,Complete);
      if GetTickCount64>Deadline then begin Thread.Terminate; raise Exception.Create('Mixed estimate timeout: '+Status); end;
      if not Complete then Sleep(10);
    until Complete;
    for var I:=0 to High(Items) do
    begin
      Require(Items[I].Completed and (Items[I].ErrorText=''),Names[I]+': '+Items[I].ErrorText);
      for var Q:=0 to 2 do
        Require((Items[I].Options.OutputBytes[0,Q]>0) and (Items[I].Options.ZipOutputBytes[0,Q]>0),
          Names[I]+': original/balanced/economy size was not estimated');
      if I<2 then Require(Items[I].Options.OutputBytes[0,3]>0,'Illustrated text has no no-images estimate');
      Require(UpdateSHA256(Books[I].GetBookFileName)=Hashes[I],'Mixed estimate changed its source');
    end;
    Writeln('PASS real illustrated and scan size estimates include all image modes and ZIP without source changes'); Flush(Output);
  finally Thread.Free; end;
end;

procedure TestBookSavePlanning;
var PreviousMask: string; PreviousSubfolders: Boolean; Reloaded: TMHLSettings;
begin
  RequireIsolatedRegression;
  Require(IsValidBookSaveFolderTemplate('%f\[%s]') and IsValidBookSaveFolderTemplate('') and
    not IsValidBookSaveFolderTemplate('..\%f') and not IsValidBookSaveFolderTemplate('C:\%f'),
    'Save folder template accepts an absolute or escaping path');
  TestBookSaveEstimates;
  TestBookSaveContinuation;
  TestRestoredSaveOptions;
  TestCompactSavePrompt;
  TestRealMixedBookSaving;
  PreviousMask:=Settings.SaveAsFolderTemplate; PreviousSubfolders:=Settings.SaveAsUseSubfolders;
  try
    Settings.SaveAsFolderTemplate:='%f\[%s]'; Settings.SaveAsUseSubfolders:=False; Settings.SaveSettings;
    Reloaded:=TMHLSettings.Create;
    try
      Reloaded.LoadSettings;
      Require(not Reloaded.SaveAsUseSubfolders and (Reloaded.SaveAsFolderTemplate='%f\[%s]'),
        'Flat save lost its remembered subfolder preset across settings reload');
    finally Reloaded.Free; end;
  finally
    Settings.SaveAsFolderTemplate:=PreviousMask; Settings.SaveAsUseSubfolders:=PreviousSubfolders;
    Settings.SaveSettings;
  end;
  Writeln('PASS flat save and editable subfolder preset persist independently of legacy export settings');
end;
