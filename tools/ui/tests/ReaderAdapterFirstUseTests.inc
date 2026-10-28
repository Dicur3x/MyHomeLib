// Controlled vendor repacks, genuine pinned HomeLib helper ZIPs and the real
// download/preparation/install path. Only HTTP transport stays on loopback.
procedure TestFirstUseReaderAdapter(const Fixture, Runtime: string; Index: TJSONObject;
  const ID: string; Corrupt, Cancel: Boolean);
var Info: TProgramRelease; Server: TRepairServer; Worker: TRepairWorker;
  AdapterName, AdapterFile, DownloadJob, PrimaryName: string;
  Bytes: TBytes; Started: UInt64; DownloadSize: Int64;
  procedure Route(const URL, Name: string);
  begin Server.URLs.Add(URL); Server.Files.Add(TPath.Combine(Fixture,Name)); end;
begin
  Info:=Default(TProgramRelease); Info.ComponentID:=ID; Info.OfficialComponent:=True;
  Server:=TRepairServer.Create; Worker:=nil;
  DownloadJob:=Settings.AppPath+'HomeLibRu-update-minimum-'+ID+'-'+IntToStr(Ord(Corrupt))+'-'+IntToStr(Ord(Cancel));
  try
    if ID='DocSharp' then
    begin
      Info.ComponentVersion:=Index.GetValue<string>('doc_version');
      Info.DownloadURL:=Index.GetValue<string>('doc_url'); PrimaryName:='doc.nupkg';
      Info.SecondaryURL:=Index.GetValue<string>('common_url');
      Info.SecondarySize:=TFile.GetSize(TPath.Combine(Fixture,'common.nupkg'));
      Info.AdditionalURLs:=TArray<string>.Create(Index.GetValue<string>('ppt_url'),Index.GetValue<string>('xls_url'));
      Info.AdditionalSizes:=TArray<Int64>.Create(TFile.GetSize(TPath.Combine(Fixture,'ppt.nupkg')),
        TFile.GetSize(TPath.Combine(Fixture,'xls.nupkg')));
      Info.Size:=TFile.GetSize(TPath.Combine(Fixture,PrimaryName))+Info.SecondarySize+
        Info.AdditionalSizes[0]+Info.AdditionalSizes[1];
      Route(Info.SecondaryURL,'common.nupkg');
      Route(Info.AdditionalURLs[0],'ppt.nupkg'); Route(Info.AdditionalURLs[1],'xls.nupkg');
    end
    else
    begin
      Info.ComponentVersion:='3.5.29'; PrimaryName:='djvu.zip';
      Info.DownloadURL:='https://master.dl.sourceforge.net/project/djvu/DjVuLibre_Windows/'+
        '3.5.29%2B4.12/DjVuLibre-3.5.29_DjView-4.12_Setup.exe?viasf=1';
      Info.SecondaryURL:='https://master.dl.sourceforge.net/project/djvu/DjVuLibre/3.5.29/djvulibre-3.5.29.tar.gz?viasf=1';
      Info.SecondarySize:=TFile.GetSize(TPath.Combine(Fixture,'djvu-source.tar.gz'));
      Info.Size:=TFile.GetSize(TPath.Combine(Fixture,PrimaryName))+Info.SecondarySize;
      Route(Info.SecondaryURL,'djvu-source.tar.gz');
    end;
    Route(Info.DownloadURL,PrimaryName);
    AdapterName:=Index.GetValue<string>(ID+'_adapter'); AdapterFile:=TPath.Combine(Fixture,AdapterName);
    DownloadSize:=Info.Size+TFile.GetSize(AdapterFile);
    ConfigureReaderAdapterDownload(Info,Runtime);
    Require((Info.ReaderAdapterSize=TFile.GetSize(AdapterFile)) and (Info.Size=DownloadSize),
      'First-use component download omits the optional helper size');
    ConfigureReaderAdapterDownload(Info,Runtime);
    Require(Info.Size=DownloadSize,'Repeated component configuration adds helper size twice');
    if Corrupt then
    begin
      Bytes:=TFile.ReadAllBytes(AdapterFile); Bytes[High(Bytes)]:=Bytes[High(Bytes)] xor 1;
      AdapterFile:=DownloadJob+'-bad.zip'; TFile.WriteAllBytes(AdapterFile,Bytes);
    end;
    Server.URLs.Add('https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+AdapterName);
    Server.Files.Add(AdapterFile);
    Worker:=TRepairWorker.Create(0,Info,DownloadJob,Server); Worker.RuntimePath:=Runtime;
    if Cancel then Worker.Terminate;
    Worker.Start; Started:=GetTickCount64;
    while not Worker.Finished do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<60000,'First-use optional helper installation timed out');
    end;
    Worker.WaitFor;
    if Corrupt or Cancel then
    begin
      Require(not Worker.Successful,'Untrusted or cancelled helper download succeeded');
      // TThread may skip Execute entirely when cancelled before Start.
      if Cancel then Require((Server.Requests=0) and not DirectoryExists(DownloadJob),
        'Cancelled helper began a transfer or prepared files')
      else Require(Worker.ErrorText.Contains('контрольная сумма'),'Corrupt helper was not rejected by its production pin');
      Require(ComponentNeedsRepair(Runtime,ID),'Failed preparation modified installed component');
      Require(not FileExists(TPath.Combine(DownloadJob,'payload/tools/doc/HomeLibDoc.exe')),
        'Untrusted helper entered the prepared payload');
    end
    else
    begin
      Require(Worker.Successful,'First-use download failed: '+Worker.ErrorText);
      Require(Server.Failure='','First-use component made an unexpected request: '+Server.Failure);
      Require(Server.Requests=3+Length(Info.AdditionalURLs),'First-use component skipped or repeated an archive');
      VerifyPreparedProgramUpdate(DownloadJob,Info.ComponentVersion,ProgramUpdatePlatform);
      InstallProgramUpdate(DownloadJob,Runtime);
      Require(not ComponentNeedsRepair(Runtime,ID),'First-use component remains incomplete after installation: '+ID);
      var Recheck:=Info; ConfigureReaderAdapterDownload(Recheck,Runtime);
      Require((Recheck.ReaderAdapterSize=0) and (Recheck.Size=DownloadSize-TFile.GetSize(AdapterFile)),
        'Installed helper is downloaded again unnecessarily');
    end;
    Writeln('PASS optional adapter first use ',ID,' corrupt=',Ord(Corrupt),' cancel=',Ord(Cancel)); Flush(Output);
  finally
    if Assigned(Worker) then begin Worker.Terminate; Worker.WaitFor; Worker.Free; end;
    Server.Free; CleanProgramUpdate(DownloadJob);
  end;
end;
