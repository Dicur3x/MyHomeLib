type
  TKindleSavePreferenceProbe = class
    Timer: TTimer;
    Expected, Failure: string;
    Checked: Boolean;
    Deadline: UInt64;
    procedure Tick(Sender: TObject);
  end;

procedure TKindleSavePreferenceProbe.Tick(Sender: TObject);
begin
  Require(GetTickCount64<Deadline,'Device format preference dialog did not appear');
  for var I:=Screen.FormCount-1 downto 0 do
    if (Screen.Forms[I] is TBookSendOptionsForm) and Screen.Forms[I].Visible then
    begin
      Timer.Enabled:=False; Checked:=True;
      try
        Require(string(TComboBox(Screen.Forms[I].FindComponent('SendFormat')).Text).Contains(Expected),
          'Save As ignored the configured device format: '+Expected);
      except on E:Exception do Failure:=E.Message; end;
      Screen.Forms[I].ModalResult:=mrCancel; Exit;
    end;
end;

procedure TestKindleBookSaving;
var Root, Required, Status: string; SavedEncoding: TTXTEncoding; Books: TArray<TBookRecord>;
  Hashes: TArray<string>; Options: TBookSendOptions; Results: TBookExportResults;
  Probe: TUnifiedSendProbe; Choice: TBookSaveChoice; Thread: TBookSendEstimateThread;
  Items: TBookSaveEstimateItems; Revision: Integer; Complete: Boolean; Deadline: UInt64;
  SavedShowMain: Boolean; Copies: TArray<TBookRecord>; CopyHashes: TArray<string>;
  ActualSizes: array[0..1,0..BOOK_QUALITY_NONE] of Int64;
  procedure Run(Mode: TExportMode; const Quality, Name: string; Keep: Boolean = False;
    Collision: TBookNameCollision = bncKeepBoth);
  begin
    Options:=Default(TBookSendOptions); Options.Folder:=TPath.Combine(Root,Name);
    ForceDirectories(Options.Folder); Options.Mode:=Mode; Options.KeepSourceFormat:=Keep;
    Options.ExplicitFormat:=not Keep; Options.ImageQuality:=Quality;
    Options.NameCollision:=Collision; Options.FileNameTemplate:='%t';
    Probe.Deadline:=GetTickCount64+120000; Probe.Messages.Clear; Probe.Worker:=nil;
    Probe.Timer.Enabled:=True;
    try Results:=SaveFileBooks(Books,Options,Required);
    finally Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
    Require((Required='') and (Probe.Failure=''),Name+': '+Required+Probe.Failure);
    Require(Length(Results)=Length(Books),Name+': lost per-book results');
    for var I:=0 to High(Results) do
      Require(Results[I].State=besSucceeded,Name+': '+Results[I].ErrorText+Probe.Messages.Text);
  end;
  procedure CheckKindle(const FileName: string; Mode: TExportMode);
  var Bytes: TBytes; Offset, Version: Cardinal;
    function BigEndian(Index: Integer): Cardinal;
    begin
      Require((Index>=0) and (Index+4<=Length(Bytes)),'Truncated Kindle header');
      Result:=(Cardinal(Bytes[Index]) shl 24) or (Cardinal(Bytes[Index+1]) shl 16) or
        (Cardinal(Bytes[Index+2]) shl 8) or Bytes[Index+3];
    end;
  begin
    Require(SameText(ExtractFileExt(FileName),BookSaveTargetExtension('.fb2',Mode,False,False)),
      'Kindle saving published the wrong extension');
    Bytes:=TFile.ReadAllBytes(FileName);
    Require((Length(Bytes)>100) and (TEncoding.ASCII.GetString(Bytes,60,8)='BOOKMOBI'),
      'Kindle output is an EPUB or a broken Palm container');
    Offset:=BigEndian(78); Version:=BigEndian(Offset+36);
    Require(((Mode=emMobi) and (Version=6)) or ((Mode=emAZW3) and (Version=8)),
      'Kindle output has the wrong MOBI7/KF8 identity');
  end;
  procedure PreferenceCases;
  var ChoiceProbe: TKindleSavePreferenceProbe; SavedMode: TExportMode; Cancelled: TBookSendOptions;
    SavedKeepSourceFormat: Boolean;
  begin
    SavedMode:=Settings.ExportMode;
    SavedKeepSourceFormat:=Settings.SaveAsKeepSourceFormat;
    ChoiceProbe:=TKindleSavePreferenceProbe.Create;
    ChoiceProbe.Timer:=TTimer.Create(nil); ChoiceProbe.Timer.Enabled:=False;
    ChoiceProbe.Timer.Interval:=50; ChoiceProbe.Timer.OnTimer:=ChoiceProbe.Tick;
    try
      Settings.SaveAsKeepSourceFormat:=False;
      for var Mode in [emTxt,emMobi,emAZW3] do
      begin
        Settings.ExportMode:=Mode;
        case Mode of
          emTxt: ChoiceProbe.Expected:='TXT'; emMobi: ChoiceProbe.Expected:='MOBI';
          emAZW3: ChoiceProbe.Expected:='AZW3';
        end;
        ChoiceProbe.Checked:=False; ChoiceProbe.Failure:='';
        ChoiceProbe.Deadline:=GetTickCount64+10000; ChoiceProbe.Timer.Enabled:=True;
        Require(not ChooseBookSendOptions(Length(Books),Root,Settings.ExportMode,Cancelled,False,Books),
          'Device preference review saved without approval');
        Require(ChoiceProbe.Checked and (ChoiceProbe.Failure=''),ChoiceProbe.Failure);
      end;
      Writeln('PASS TXT MOBI AZW3 device format preferences preselect the actual mixed Save As dialog; cancellation creates no file'); Flush(Output);
    finally
      Settings.ExportMode:=SavedMode;
      Settings.SaveAsKeepSourceFormat:=SavedKeepSourceFormat;
      ChoiceProbe.Timer.Free; ChoiceProbe.Free;
    end;
  end;
  procedure CollisionCases;
  var PreviousBooks: TArray<TBookRecord>; First, Kept, Before: string;
  begin
    PreviousBooks:=Books; Books:=[Books[0]];
    try
      for var Mode in [emMobi,emAZW3] do
      begin
        var Name:='collision-'+IntToStr(Ord(Mode));
        Run(Mode,'original',Name); First:=Results[0].OutputFile;
        TFile.WriteAllText(First,'Previous owned saved copy',TEncoding.UTF8);
        Before:=UpdateSHA256(First);
        Run(Mode,'original',Name); Kept:=Results[0].OutputFile;
        Require(not SameFileName(First,Kept) and (UpdateSHA256(First)=Before),
          'Keep both replaced an existing Kindle file');
        CheckKindle(Kept,Mode);
        Run(Mode,'original',Name,False,bncReplace);
        Require(SameFileName(Results[0].OutputFile,First) and (UpdateSHA256(First)<>Before),
          'Explicit replace silently renamed a Kindle file');
        CheckKindle(First,Mode); CheckKindle(Kept,Mode);
      end;
      Writeln('PASS native MOBI AZW3 keep-both preserves old bytes and explicit replace keeps the chosen filename'); Flush(Output);
    finally Books:=PreviousBooks; end;
  end;
  procedure InstallerCases;
  var Target, Folder, ID, Version, Archive, Job, First, BeforeHash: string;
    Feed: TJSONValue; Entries: TJSONArray; Files: TUpdateFiles;
    Refused: Boolean; Missing: TArray<string>;
  begin
    Folder:=Settings.AppPath+'kindle-save-packages';
    Target:=Settings.AppPath+'kindle-install-target'; ForceDirectories(Target);
    TFile.WriteAllText(TPath.Combine(Target,'HomeLibRu.exe'),'Owned fixture target; never executed');
    ForceDirectories(TPath.Combine(Target,'Data'));
    TFile.WriteAllText(TPath.Combine(Target,'Data/private.txt'),'unchanged personal data');
    Missing:=MissingBookConversionComponents(Target,Books[0].GetBookFileName,'.fb2',False,nil,'.azw3');
    Require((Length(Missing)=2) and (Missing[0]='BookProcessing') and (Missing[1]='KindleExport'),
      'Kindle output did not aggregate exactly the two missing components');
    Feed:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8));
    try
      Require((Feed is TJSONObject) and Feed.TryGetValue<TJSONArray>('components',Entries),'Missing Kindle installation feed');
      for ID in TArray<string>.Create('BookProcessing','KindleExport') do
      begin
        Version:=''; Archive:='';
        for var Entry in Entries do
          if (Entry.GetValue<string>('id')=ID) and (Entry.GetValue<string>('platform')=ProgramUpdatePlatform) then
          begin Version:=Entry.GetValue<string>('version'); Archive:=TPath.Combine(Folder,Entry.GetValue<string>('archive')); end;
        Require((Version<>'') and FileExists(Archive),'Missing actual independent package '+ID);
        Job:=Settings.AppPath+'HomeLibRu-update-'+TGUID.NewGuid.ToString;
        try
          Files:=PrepareProgramUpdate(Archive,UpdateSHA256(Archive),ALREADER_FIXED_TAG,ProgramUpdatePlatform,Job,True,ID,Version);
          Require(Length(Files)>0,'Empty Kindle installation package');
          First:=TPath.Combine(Target,StringReplace(Files[0].Name,'/',PathDelim,[rfReplaceAll]));
          ForceDirectories(ExtractFileDir(First)); TFile.WriteAllText(First,'Previous owned component bytes');
          BeforeHash:=UpdateSHA256(First); Refused:=False;
          try InstallProgramUpdate(Job,Target,nil,1);
          except on E:Exception do Refused:=E.Message='Имитированная ошибка установки'; end;
          Require(Refused and (UpdateSHA256(First)=BeforeHash),'Kindle installation failure lost existing bytes');
        finally CleanProgramUpdate(Job); end;
        Job:=Settings.AppPath+'HomeLibRu-update-'+TGUID.NewGuid.ToString;
        try
          Files:=PrepareProgramUpdate(Archive,UpdateSHA256(Archive),ALREADER_FIXED_TAG,ProgramUpdatePlatform,Job,True,ID,Version);
          InstallProgramUpdate(Job,Target);
          Require(not ComponentNeedsRepair(Target,ID),'Installed Kindle component fails readiness: '+ID);
          for var Info in Files do
            Require(UpdateSHA256(TPath.Combine(Target,StringReplace(Info.Name,'/',PathDelim,[rfReplaceAll])))=Info.SHA256,
              'Installed Kindle component differs from its manifest');
        finally CleanProgramUpdate(Job); end;
        Missing:=MissingBookConversionComponents(Target,Books[0].GetBookFileName,'.fb2',False,nil,'.mobi');
        if ID='BookProcessing' then
          Require((Length(Missing)=1) and (Missing[0]='KindleExport'),'Base processing bundled an unwanted writer or lost its requirement')
        else Require(Length(Missing)=0,'Installing the writer did not satisfy the original operation');
      end;
      for var Unrelated in ['office','doc','xps','kindle','pdfium','djvu','images'] do
        Require(not DirectoryExists(TPath.Combine(Target,'tools/'+Unrelated)),
          'Kindle installation bundled an unrelated module: '+Unrelated);
      Require(TFile.ReadAllText(TPath.Combine(Target,'Data/private.txt'))='unchanged personal data',
        'Kindle installation modified personal data');
      Writeln('PASS native independent Kindle packages aggregate requirements install verify all hashes roll back failures and preserve personal data'); Flush(Output);
    finally Feed.Free; end;
  end;
  procedure RasterCases;
  var Inputs: string; PreviousBooks: TArray<TBookRecord>; RasterHashes: TArray<string>;
  begin
    Inputs:=Settings.AppPath+'mixed-save-inputs';
    if not DirectoryExists(Inputs) then Exit;
    PreviousBooks:=Books;
    try
      var Mislabelled:=TPath.Combine(Inputs,'pdf-with-wrong-extension.fb2');
      TFile.Copy(TPath.Combine(Inputs,'source.pdf'),Mislabelled,False);
      Books:=[FileBook(Mislabelled),FileBook(TPath.Combine(Inputs,'source.djvu')),
        FileBook(TPath.Combine(Inputs,'scan.pdf')),FileBook(TPath.Combine(Inputs,'scan.djvu'))];
      Require(BookSaveKnownExtension(Books[0])='.pdf','A strong PDF signature lost to its wrong FB2 extension');
      SetLength(RasterHashes,Length(Books));
      for var I:=0 to High(Books) do RasterHashes[I]:=UpdateSHA256(Books[I].GetBookFileName);
      for var Mode in [emMobi,emAZW3] do
        for var Quality:=0 to 2 do
        begin
          Run(Mode,BOOK_IMAGE_PROFILES[Quality],'raster-'+IntToStr(Ord(Mode))+'-'+BOOK_IMAGE_PROFILES[Quality]);
          for var I:=0 to High(Results) do CheckKindle(Results[I].OutputFile,Mode);
        end;
      Choice:=Default(TBookSaveChoice); Choice.Mode:=emAZW3;
      Thread:=TBookSendEstimateThread.Create(Books,Choice,Settings.AppPath,Settings.TempPath);
      try
        Revision:=-1; Complete:=False; Deadline:=GetTickCount64+240000; Thread.Start;
        repeat
          Application.ProcessMessages; Thread.Poll(Revision,Items,Status,Complete);
          if GetTickCount64>Deadline then begin Thread.Terminate; raise Exception.Create('Raster Kindle estimate timeout: '+Status); end;
          if not Complete then Sleep(10);
        until Complete;
        Require(Length(Items)=Length(Books),'Raster Kindle estimate lost books');
        for var I:=0 to High(Items) do
        begin
          Require(Items[I].Completed and (Items[I].ErrorText=''),Status+' '+Items[I].ErrorText);
          for var Layout:=0 to 2 do
            for var Quality:=0 to 2 do
              Require(Items[I].Options.OutputBytes[Layout,Quality]>0,'A scan layout/image mode has no Kindle estimate');
          Require(Items[I].Options.OutputBytes[0,BOOK_QUALITY_NONE]=0,'Image-only scans invent a readable no-images export');
          Require(UpdateSHA256(Books[I].GetBookFileName)=RasterHashes[I],'Raster Kindle export changed its source');
        end;
      finally Thread.Free; end;
      Writeln('PASS native PDF DjVu and scan-only sources to MOBI AZW3 three image modes and scan layout estimates'); Flush(Output);
    finally Books:=PreviousBooks; end;
  end;
begin
  RequireIsolatedRegression;
  Require(not DirectoryExists(Settings.AppPath+'tools/office') and
    not DirectoryExists(Settings.AppPath+'tools/kindle') and
    not DirectoryExists(Settings.AppPath+'tools/doc'),
    'Text-to-Kindle fixture contains unrelated format modules');
  if not DirectoryExists(Settings.AppPath+'mixed-save-inputs') then
    Require(not DirectoryExists(Settings.AppPath+'tools/pdfium') and
      not DirectoryExists(Settings.AppPath+'tools/djvu'),'Basic text scenario includes unused raster readers');
  Root:=Settings.AppPath+'kindle-save-fixtures';
  TestBookSaveContinuation;
  Books:=[FileBook(TPath.Combine(Root,'source.fb2')),FileBook(TPath.Combine(Root,'source.epub'))];
  SetLength(Hashes,Length(Books));
  for var I:=0 to High(Books) do Hashes[I]:=UpdateSHA256(Books[I].GetBookFileName);
  InstallerCases;
  Probe:=TUnifiedSendProbe.Create; Probe.Messages:=TStringList.Create;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False; Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
  Probe.SavedModal:=Application.OnModalBegin; Application.OnModalBegin:=Probe.ModalBegin;
  SavedShowMain:=Application.ShowMainForm; Application.ShowMainForm:=False;
  SavedEncoding:=Settings.TXTEncoding;
  try
    Settings.TXTEncoding:=enUTF8;
    PreferenceCases;
    Run(emTxt,'original','text');
    for var I:=0 to High(Results) do
    begin
      Require(SameText(ExtractFileExt(Results[I].OutputFile),'.txt'),'Text export has wrong extension');
      var Text:=TFile.ReadAllText(Results[I].OutputFile,TEncoding.UTF8);
      Require(Text.Contains('Ёжик читает книгу') and Text.Contains('Последний абзац'),
        'FB2/EPUB text export lost Unicode or the final chapter');
    end;
    Writeln('PASS native mixed FB2 EPUB to Unicode TXT without unrelated readers'); Flush(Output);
    for var Mode in [emMobi,emAZW3] do
    begin
      for var Quality:=0 to High(BOOK_IMAGE_PROFILES) do
      begin
        Run(Mode,BOOK_IMAGE_PROFILES[Quality],IntToStr(Ord(Mode))+'-'+BOOK_IMAGE_PROFILES[Quality]);
        for var I:=0 to High(Results) do
        begin
          CheckKindle(Results[I].OutputFile,Mode);
          ActualSizes[I,Quality]:=TFile.GetSize(Results[I].OutputFile);
        end;
        if Quality=0 then
          for var I:=0 to High(Results) do
          begin
            Copies:=Copies+[FileBook(Results[I].OutputFile)];
            CopyHashes:=CopyHashes+[UpdateSHA256(Results[I].OutputFile)];
          end;
      end;
      Choice:=Default(TBookSaveChoice); Choice.Mode:=Mode;
      Thread:=TBookSendEstimateThread.Create(Books,Choice,Settings.AppPath,Settings.TempPath);
      try
        Revision:=-1; Complete:=False; Deadline:=GetTickCount64+120000; Thread.Start;
        repeat
          Application.ProcessMessages; Thread.Poll(Revision,Items,Status,Complete);
          if GetTickCount64>Deadline then begin Thread.Terminate; raise Exception.Create('Kindle estimate timeout: '+Status); end;
          if not Complete then Sleep(10);
        until Complete;
        Require(Length(Items)=Length(Books),'Kindle estimate lost books');
        for var I:=0 to High(Items) do
        begin
          Require(Items[I].Completed and (Items[I].ErrorText=''),Status+' '+Items[I].ErrorText);
          for var Quality:=0 to High(BOOK_IMAGE_PROFILES) do
            Require((Items[I].Options.OutputBytes[0,Quality]>0) and
              (Abs(Items[I].Options.OutputBytes[0,Quality]-ActualSizes[I,Quality])<=2048),
              'Kindle size estimate differs from actual output by more than metadata tolerance');
        end;
      finally Thread.Free; end;
      Writeln('PASS native Kindle mode ',Ord(Mode),' mixed FB2 EPUB four image choices actual containers and output estimates'); Flush(Output);
    end;
    for var I:=0 to High(Books) do
      Require(UpdateSHA256(Books[I].GetBookFileName)=Hashes[I],'Kindle saving changed an original book');
    CollisionCases;
    RasterCases;
    Require(RenameFile(Settings.AppPath+'tools/kindle-export',Settings.AppPath+'tools/kindle-export-off'),
      'Cannot hide isolated Kindle writer for copy-only check');
    Require(RenameFile(Settings.AppPath+'tools/bookconvert',Settings.AppPath+'tools/bookconvert-off'),
      'Cannot hide isolated conversion runtime for copy-only check');
    Books:=Copies; Run(emFB2,'original','kindle-originals',True);
    for var I:=0 to High(Results) do
      Require(UpdateSHA256(Results[I].OutputFile)=CopyHashes[I],'Copying an existing Kindle file changed its bytes');
    Writeln('PASS native existing MOBI AZW3 copy byte exact without conversion modules'); Flush(Output);
  finally
    Settings.TXTEncoding:=SavedEncoding; Application.ShowMainForm:=SavedShowMain;
    Application.OnModalBegin:=Probe.SavedModal; Probe.Timer.Free; Probe.Messages.Free; Probe.Free;
  end;
  Writeln('PASS native Kindle Save As real output estimates image modes and unchanged originals'); Flush(Output);
end;
