// Real isolated payloads through the native SaveFileBooks worker. Output
// content is inspected by a separate Python oracle; native success is not
// treated as independent proof of complete book content.
type
  TCollectionExportProgressProbe = class
    SeenWriting, SeenMarquee, SeenFalse98: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TCollectionExportProgressProbe.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TExportToDeviceProgressForm) and Screen.Forms[I].Visible then
    begin
      var Form:=TExportToDeviceProgressForm(Screen.Forms[I]);
      if not string(Form.txtComment.Caption).Contains('Запись книги') then Continue;
      SeenWriting:=True;
      if Form.ProgressBar.Style=pbstMarquee then SeenMarquee:=True;
      if (Form.ProgressBar.Style=pbstNormal) and (Form.ProgressBar.Position=98) then SeenFalse98:=True;
    end;
end;

procedure TestCollectionNativeExports;
var Root, SourcesRoot, SourceName, SourceHash, Required, ModeName: string;
  Cases: TJSONArray; Report: TJSONObject; Rows: TJSONArray; Row: TJSONObject;
  Book: TBookRecord; Options: TBookSendOptions; Results: TBookExportResults;
  Probe: TUnifiedSendProbe; SavedEncoding: TTXTEncoding; Failures: Integer;
  Archive: TZipFile; ModeNames: TArray<string>; RequestedModes: TJSONArray;
  Mode: TExportMode;
  ProgressProbe: TCollectionExportProgressProbe; ProgressTimer: TTimer;
begin
  Root:=TPath.Combine(Settings.AppPath,'native-export-matrix');
  SourcesRoot:=IncludeTrailingPathDelimiter(TPath.GetFullPath(TPath.Combine(Root,'sources')));
  Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Root,'cases.json'),TEncoding.UTF8)) as TJSONArray;
  Require(Assigned(Cases) and (Cases.Count>0),'No real native export cases were prepared');
  Report:=TJSONObject.Create; Rows:=TJSONArray.Create; Report.AddPair('operations',Rows);
  Probe:=TUnifiedSendProbe.Create; Probe.Messages:=TStringList.Create;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False; Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
  Probe.SavedModal:=Application.OnModalBegin; Application.OnModalBegin:=Probe.ModalBegin;
  ProgressProbe:=TCollectionExportProgressProbe.Create;
  ProgressTimer:=TTimer.Create(nil); ProgressTimer.Enabled:=False;
  ProgressTimer.Interval:=20; ProgressTimer.OnTimer:=ProgressProbe.Tick;
  SavedEncoding:=Settings.TXTEncoding; Failures:=0;
  try
    Settings.TXTEncoding:=enUTF8;
    for var Value in Cases do
    begin
      var Item:=Value as TJSONObject;
      SourceName:=TPath.GetFullPath(Item.GetValue<string>('path'));
      Require(SameText(Copy(SourceName,1,Length(SourcesRoot)),SourcesRoot),
        'Native matrix source must stay inside its owned fixture');
      SourceHash:=Item.GetValue<string>('sha256');
      Require(UpdateSHA256(SourceName)=SourceHash,'Real native source differs from its inventory');
      Book:=FileBook(SourceName); Book.Title:='case-'+Item.GetValue<string>('id');
      ModeNames:=TArray<string>.Create('txt','fb2zip','original');
      RequestedModes:=Item.GetValue('outputs') as TJSONArray;
      if Assigned(RequestedModes) then
      begin
        Require(RequestedModes.Count>0,'Native matrix requires at least one requested output');
        ModeNames:=nil;
        for var RequestedMode in RequestedModes do ModeNames:=ModeNames+[RequestedMode.Value];
      end;
      for var RequestedName in ModeNames do
      begin
        ModeName:=RequestedName;
        if ModeName='txt' then Mode:=emTxt
        else if ModeName='fb2zip' then Mode:=emFB2Zip
        else if (ModeName='original') or (ModeName='fb2') then Mode:=emFB2
        else if ModeName='epub' then Mode:=emEpub
        else if ModeName='mobi' then Mode:=emMobi
        else if ModeName='azw3' then Mode:=emAZW3
        else if ModeName='epub2' then Mode:=emEpub2
        else if ModeName='epub3' then Mode:=emEpub3
        else if ModeName='kepub' then Mode:=emKepub
        else if ModeName='kfx' then Mode:=emKfx
        else if ModeName='azw8' then Mode:=emAzw8
        else if ModeName='pdf' then Mode:=emAdvancedPDF
        else if ModeName='md' then Mode:=emMarkdown
        else raise Exception.Create('Unknown native matrix output: '+ModeName);
        Row:=TJSONObject.Create; Rows.AddElement(Row);
        Row.AddPair('id',Item.GetValue<string>('id'));
        Row.AddPair('detected',Item.GetValue<string>('detected'));
        Row.AddPair('mode',ModeName);
        try
          Options:=Default(TBookSendOptions); Options.Mode:=Mode;
          Options.KeepSourceFormat:=ModeName='original'; Options.ExplicitFormat:=not Options.KeepSourceFormat;
          Options.Folder:=TPath.Combine(Root,Item.GetValue<string>('id')+'-'+ModeName);
          ForceDirectories(Options.Folder); Options.FileNameTemplate:='%t';
          Options.NameCollision:=bncKeepBoth; Options.ImageQuality:='original';
          Probe.Deadline:=GetTickCount64+360000; Probe.Failure:='';
          Probe.Messages.Clear; Probe.Worker:=nil; Probe.Timer.Enabled:=True;
          ProgressProbe.SeenWriting:=False; ProgressProbe.SeenMarquee:=False; ProgressProbe.SeenFalse98:=False;
          ProgressTimer.Enabled:=True;
          try Results:=SaveFileBooks([Book],Options,Required);
          finally ProgressTimer.Enabled:=False; Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
          Require((Required='') and (Probe.Failure=''),ModeName+': '+Required+Probe.Failure);
          Require(Length(Results)=1,'Native matrix lost its per-book result');
          Require(Results[0].State=besSucceeded,Results[0].ErrorText+Probe.Messages.Text);
          Require(FileExists(Results[0].OutputFile),'Native matrix published no output');
          Row.AddPair('writer_phase_seen',TJSONBool.Create(ProgressProbe.SeenWriting));
          Row.AddPair('writer_marquee_seen',TJSONBool.Create(ProgressProbe.SeenMarquee));
          Row.AddPair('writer_false_98_seen',TJSONBool.Create(ProgressProbe.SeenFalse98));
          if Item.GetValue<Boolean>('expect_writer_marquee',False) then
            Require(ProgressProbe.SeenWriting and ProgressProbe.SeenMarquee and not ProgressProbe.SeenFalse98,
              'Unmeasured writer must show activity instead of an invented 98 percent');
          Row.AddPair('output',Results[0].OutputFile);
          Row.AddPair('sha256',UpdateSHA256(Results[0].OutputFile));
          if ModeName='original' then
            Require(UpdateSHA256(Results[0].OutputFile)=SourceHash,'Unchanged-source save changed its bytes')
          else if ModeName='txt' then
          begin
            Require(SameText(ExtractFileExt(Results[0].OutputFile),'.txt'),'Native text output has the wrong extension');
            Require(TFile.ReadAllText(Results[0].OutputFile,TEncoding.UTF8).Trim<>'','Native text output is empty');
          end
          else if ModeName='fb2zip' then
          begin
            Require(SameText(ExtractFileExt(Results[0].OutputFile),'.zip'),'Native FB2.ZIP has the wrong extension');
            Archive:=TZipFile.Create;
            try
              Archive.Open(Results[0].OutputFile,zmRead);
              Require((Archive.FileCount=1) and SameText(ExtractFileExt(Archive.FileNames[0]),'.fb2'),
                'Native FB2.ZIP must contain exactly one FB2 book');
            finally Archive.Free; end;
          end
          else
            Require(Results[0].OutputFile.EndsWith(
              BookSaveTargetExtension(Book.FileExt,Mode,False,False),True),
              'Native matrix output has the wrong target extension');
          Require(UpdateSHA256(SourceName)=SourceHash,'Native saving changed its real input');
          Row.AddPair('status','PASS_NATIVE');
          Writeln('PASS native real export ',Item.GetValue<string>('detected'),' ',ModeName); Flush(Output);
        except
          on E:Exception do
          begin
            Inc(Failures); Row.AddPair('status','FAIL'); Row.AddPair('error',E.ClassName+': '+E.Message);
            Writeln('FAIL native real export ',Item.GetValue<string>('detected'),' ',ModeName,': ',E.Message); Flush(Output);
          end;
        end;
        TFile.WriteAllText(TPath.Combine(Root,'native-results.json'),Report.ToJSON,TEncoding.UTF8);
        Require(UpdateSHA256(SourceName)=SourceHash,'Real source changed even after a failed native save');
      end;
    end;
    Require(Failures=0,Format('Native real export matrix has %d failures',[Failures]));
  finally
    Settings.TXTEncoding:=SavedEncoding; Application.OnModalBegin:=Probe.SavedModal;
    ProgressTimer.Free; ProgressProbe.Free;
    Probe.Timer.Free; Probe.Messages.Free; Probe.Free; Report.Free; Cases.Free;
  end;
end;
