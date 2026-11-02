procedure TestComponentUsage;
var Folder: string; Time: TDateTime; IDs, Unused: TArray<string>; Rejected: Boolean;
begin
  RequireIsolatedRegression; Folder:=Settings.AppPath+'usage-clock-fixture'; ForceDirectories(Folder);
  Time:=EncodeDate(2026,1,1); IDs:=TArray<string>.Create('DjVuLibre','WebP');
  var Launches:=Folder+'\launches'; ForceDirectories(Launches); ConfigureComponentUsage(Launches);
  try
    RecordComponentToolUse(Launches+'\tools\python\python.exe',['--version']);
    RecordComponentToolUse(Launches+'\Readers\AlReader\AlReader2.exe',['--help']);
    Require((ComponentLastUse(Launches,'BookProcessing')=0) and
      (ComponentLastUse(Launches,'AlReader')=0),'Version/help check was recorded as reading');
    RecordComponentToolUse(Launches+'\tools\python\python.exe',['-I','convert_book.py']);
    RecordComponentToolUse(Launches+'\tools\webp\libwebp.dll');
    RecordComponentToolUse(Launches+'\libzstd.dll');
    RecordComponentToolUse(Launches+'\Readers\SumatraPDF\SumatraPDF.exe');
    Require((ComponentLastUse(Launches,'BookProcessing')>0) and (ComponentLastUse(Launches,'WebP')>0) and
      (ComponentLastUse(Launches,'Zstandard')>0) and (ComponentLastUse(Launches,'SumatraPDF')>0),
      'Actual helper/codec/external reader use missing');
    var Ledger:=Launches+'\tools\component-state\usage.json';
    var SavedLedger:=TFile.ReadAllBytes(Ledger); TFile.Delete(Ledger);
    try
      for var I:=1 to 1000 do RecordComponentUse('WebP');
      Require(not FileExists(Ledger),'Repeated image decoding reopened/rebuilt usage metadata for every image');
    finally TFile.WriteAllBytes(Ledger,SavedLedger); end;
    RecordComponentToolUse(Folder+'\outside\tools\office\HomeLibOffice.exe');
    Require(ComponentLastUse(Launches,'LegacyOffice')=0,'Another installation contaminated usage');
    RecordBookConversionUse('.lrf','.azw3');
    Require((ComponentLastUse(Launches,'LegacyBooks')>0) and (ComponentLastUse(Launches,'KindleExport')>0) and
      (ComponentLastUse(Launches,'PDFium')=0),'Preparation recorded unrelated decoders or missed the Kindle writer');
  finally ConfigureComponentUsage(Settings.AppPath); end;
  ObserveInstalledComponents(Folder,IDs,Time); ConfigureComponentUsage(Folder);
  try
    Require(ComponentLastUse(Folder,'DjVuLibre')=0,'Discovery was counted as actual use');
    Require(not ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+29),'Old installation was offered before one month of observation');
    RecordComponentInstallation(Folder,'WebP',Time+29);
    Require(ComponentLastUse(Folder,'WebP')=0,'Module update was counted as actual use');
    RecordComponentUse('DjVuLibre',Time+29);
    Require(ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+30) and (Length(Unused)=1) and
      (Unused[0]='WebP'),'Module update reset observation or first offer ignored real recent use');
    Require(not ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+30),'Two instances could reserve the same monthly offer');
    Require(not ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+40),'Declined offer repeated within a month');
    Require(ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+62) and (Length(Unused)=2),'Deferred combined monthly offer did not return');
    SetComponentCleanupSuppressed(Folder,True);
    Require(ComponentCleanupSuppressed(Folder) and not ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+110),'Permanent suppression ignored');
    SetComponentCleanupSuppressed(Folder,False); RecordComponentInstallation(Folder,'WebP',Time+110,True);
    Require(ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+110) and (Length(Unused)=1) and
      (Unused[0]='DjVuLibre'),'Fresh reinstallation was immediately offered for deletion');
    ObserveInstalledComponents(Folder,IDs,Time+200);
    Require(ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+200) and (Length(Unused)=2),'Inventory refresh reset the age of unused components');
    Require(not ReserveUnusedComponentOffer(Folder,nil,Unused,Time+300),'Removed modules remained in monthly offer');
    var A:=TThread.CreateAnonymousThread(procedure begin RecordComponentUse('DjVuLibre',Time+301); end);
    var B:=TThread.CreateAnonymousThread(procedure begin RecordComponentUse('WebP',Time+301); end);
    A.FreeOnTerminate:=False; B.FreeOnTerminate:=False;
    try A.Start; B.Start; A.WaitFor; B.WaitFor;
    finally A.Free; B.Free; end;
    Require((Abs(ComponentLastUse(Folder,'DjVuLibre')-(Time+301))<1/86400) and
      (Abs(ComponentLastUse(Folder,'WebP')-(Time+301))<1/86400),'Concurrent use records overwrote each other');
    A:=TThread.CreateAnonymousThread(procedure
      begin for var I:=1 to 32 do RecordComponentInstallation(Folder+'\','DjVuLibre',Time+400+I); end);
    B:=TThread.CreateAnonymousThread(procedure
      begin for var I:=1 to 32 do RecordComponentUse('WebP',Time+400+I); end);
    A.FreeOnTerminate:=False; B.FreeOnTerminate:=False;
    try A.Start; B.Start; A.WaitFor; B.WaitFor;
    finally A.Free; B.Free; end;
    Require(Abs(ComponentLastUse(Folder,'WebP')-(Time+432))<1/86400,'Trailing path separator split the usage write lock');
    var State:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'\tools\component-state\usage.json',TEncoding.UTF8));
    try Require(State.GetValue<string>('modules.DjVuLibre.firstSeenUtc')=DateToISO8601(Time,True),'Concurrent updates reset the observation start');
    finally State.Free; end;
    var Name:=Folder+'\tools\component-state\usage.json';
    TFile.WriteAllText(Name,'preserved corrupt metadata',TEncoding.UTF8);
    RecordComponentUse('WebP',Time+400); Rejected:=False;
    try ReserveUnusedComponentOffer(Folder,IDs,Unused,Time+400); except on E: Exception do Rejected:=True; end;
    Require(Rejected and (TFile.ReadAllText(Name,TEncoding.UTF8)='preserved corrupt metadata'),'Corrupt usage data was overwritten or used for deletion offers');
  finally ConfigureComponentUsage(Settings.AppPath); end;
  Writeln('PASS component actual-use records monthly combined offer postponement permanent suppression reinstallation age concurrency and corrupt-state preservation');
end;
