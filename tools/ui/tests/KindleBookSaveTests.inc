procedure TestKindleBookSaving;
const Profiles: array[0..3] of string = ('original','balanced','economy','none');
var Root, Required, Status: string; SavedEncoding: TTXTEncoding; Books: TArray<TBookRecord>;
  Hashes: TArray<string>; Options: TBookSendOptions; Results: TBookExportResults;
  Probe: TUnifiedSendProbe; Choice: TBookSaveChoice; Thread: TBookSendEstimateThread;
  Items: TBookSaveEstimateItems; Revision: Integer; Complete: Boolean; Deadline: UInt64;
  SavedShowMain: Boolean; Copies: TArray<TBookRecord>; CopyHashes: TArray<string>;
  ActualSizes: array[0..1,0..3] of Int64;
  procedure Run(Mode: TExportMode; const Quality, Name: string; Keep: Boolean = False);
  begin
    Options:=Default(TBookSendOptions); Options.Folder:=TPath.Combine(Root,Name);
    ForceDirectories(Options.Folder); Options.Mode:=Mode; Options.KeepSourceFormat:=Keep;
    Options.ExplicitFormat:=not Keep; Options.ImageQuality:=Quality;
    Options.NameCollision:=bncKeepBoth; Options.FileNameTemplate:='%t';
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
begin
  RequireIsolatedRegression;
  Require(not DirectoryExists(Settings.AppPath+'tools/office') and
    not DirectoryExists(Settings.AppPath+'tools/kindle') and
    not DirectoryExists(Settings.AppPath+'tools/doc') and
    not DirectoryExists(Settings.AppPath+'tools/pdfium') and
    not DirectoryExists(Settings.AppPath+'tools/djvu'),
    'Text-to-Kindle fixture contains unrelated format modules');
  Root:=Settings.AppPath+'kindle-save-fixtures';
  Books:=[FileBook(TPath.Combine(Root,'source.fb2')),FileBook(TPath.Combine(Root,'source.epub'))];
  SetLength(Hashes,Length(Books));
  for var I:=0 to High(Books) do Hashes[I]:=UpdateSHA256(Books[I].GetBookFileName);
  Probe:=TUnifiedSendProbe.Create; Probe.Messages:=TStringList.Create;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
  Probe.SavedModal:=Application.OnModalBegin; Application.OnModalBegin:=Probe.ModalBegin;
  SavedShowMain:=Application.ShowMainForm; Application.ShowMainForm:=False;
  SavedEncoding:=Settings.TXTEncoding;
  try
    Settings.TXTEncoding:=enUTF8;
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
      for var Quality:=0 to 3 do
      begin
        Run(Mode,Profiles[Quality],IntToStr(Ord(Mode))+'-'+Profiles[Quality]);
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
          for var Quality:=0 to 3 do
            Require((Items[I].Options.OutputBytes[0,Quality]>0) and
              (Abs(Items[I].Options.OutputBytes[0,Quality]-ActualSizes[I,Quality])<=2048),
              'Kindle size estimate differs from actual output by more than metadata tolerance');
        end;
      finally Thread.Free; end;
      Writeln('PASS native Kindle mode ',Ord(Mode),' mixed FB2 EPUB four image choices actual containers and output estimates'); Flush(Output);
    end;
    for var I:=0 to High(Books) do
      Require(UpdateSHA256(Books[I].GetBookFileName)=Hashes[I],'Kindle saving changed an original book');
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
