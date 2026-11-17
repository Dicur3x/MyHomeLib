procedure TestKfxCovers;
var Folder:string; Cases:TJSONArray; Entry:TJSONValue; Host:TForm;
  Panel:TInfoPanel; Preview:TBookInfoPreview; Image:TImage; Book:TBookRecord;
  Source:TStream; Data,Expected:TBytes; Deadline:UInt64; OriginalHash:string;
  procedure WaitPreview;
  begin
    Deadline:=GetTickCount64+35000;
    while Preview.Busy and (GetTickCount64<Deadline) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
    Require(not Preview.Busy,'KFX preview did not finish');
  end;
begin
  Folder:=Settings.AppPath+'cover-fixtures'+PathDelim;
  Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'kfx-preview.json',TEncoding.UTF8)) as TJSONArray;
  Host:=TForm.CreateNew(nil); Panel:=TInfoPanel.Create(Host); Panel.Parent:=Host; Panel.Align:=alClient;
  Host.SetBounds(70,80,850,450); Host.Show;
  Preview:=TBookInfoPreview.CreateFor(Host,Panel);
  try
    Image:=nil;
    for var I:=0 to Panel.ControlCount-1 do if Panel.Controls[I] is TImage then Image:=TImage(Panel.Controls[I]);
    Require(Assigned(Image),'KFX preview image control absent');
    for Entry in Cases do
    begin
      var Row:=TJSONObject(Entry); var Name:=Row.GetValue<string>('name');
      Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
      Book.FileName:=ChangeFileExt(Name,''); Book.FileExt:=ExtractFileExt(Name);
      Book.Folder:=Row.GetValue<string>('archive','');
      OriginalHash:=THashSHA2.GetHashStringFromFile(Book.GetBookFileName);
      var Rejected:=False; Data:=nil;
      Source:=OpenRawBookSource(Book);
      try
        Require(Source is TFileStream,'KFX preview has no local source lease');
        try Data:=ReadKfxBookCover(TFileStream(Source).FileName,FindExternalTool('boko.exe','kfx-export'));
        except on E:EReadError do Rejected:=True; end;
      finally Source.Free; end;
      Require(Rejected=Row.GetValue<Boolean>('error',False),'Unexpected KFX cover error: '+Name);
      if Row.GetValue<string>('expected','')<>'' then
      begin
        Expected:=TFile.ReadAllBytes(Folder+Row.GetValue<string>('expected'));
        Require((Length(Data)=Length(Expected)) and CompareMem(@Data[0],@Expected[0],Length(Data)),
          'KFX declared cover differs from independent resource: '+Name);
        Preview.Load(Book,True,False,False); WaitPreview;
        Require(Assigned(Image.Picture.Graphic) and (Image.Picture.Width=Row.GetValue<Integer>('width')) and
          (Image.Picture.Height=Row.GetValue<Integer>('height')),'KFX catalogue cover missing: '+Panel.PreviewStatusText);
      end
      else
      begin
        Require(Length(Data)=0,'Undeclared KFX image promoted to a cover: '+Name);
        Preview.Load(Book,True,False,False); WaitPreview;
        Require(not Assigned(Image.Picture.Graphic),'Previous cover survives missing/damaged KFX: '+Name);
      end;
      Require(THashSHA2.GetHashStringFromFile(Book.GetBookFileName)=OriginalHash,'KFX cover preview changed input');
      Writeln('PASS KFX declared cover ',Name); Flush(Output);
    end;
    try
      Data:=ReadKfxBookCover('absent.kfx','absent-tool.exe');
      Require(False,'KFX cover accepted missing module');
    except on E:EReadError do Writeln('PASS KFX missing module'); end;
    try
      Data:=ReadKfxBookCover('absent.kfx','absent-tool.exe',function:Boolean begin Result:=True; end);
      Require(False,'KFX cover ignored pre-cancellation');
    except on E:EAbort do Writeln('PASS KFX pre-cancellation'); end;
    var Started:=False; var SavedHeartbeat:=MHLExternalToolHeartbeat;
    MHLExternalToolHeartbeat:=procedure begin Started:=True; end;
    try
      try
        Data:=ReadKfxBookCover(Folder+TJSONObject(Cases.Items[0]).GetValue<string>('name'),
          FindExternalTool('boko.exe','kfx-export'),function:Boolean begin Result:=Started; end);
        Require(False,'KFX cover ignored active cancellation');
      except on E:EAbort do Require(Started,'KFX cancellation did not reach the active process'); end;
    finally MHLExternalToolHeartbeat:=SavedHeartbeat; end;
    Writeln('PASS KFX active cancellation');
  finally Preview.Free; Host.Free; Cases.Free; end;
end;
