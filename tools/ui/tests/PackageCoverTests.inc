procedure TestPackageCovers;
var Cases:TJSONArray; Item:TJSONValue; C:TJSONObject; Stream:TFileStream;
  Data,Expected:TBytes; Status,Root,Name:string; Checks:Integer;
begin
  Root:=Settings.AppPath+'cover-fixtures'+PathDelim;
  Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Root+'cases.json',TEncoding.UTF8)) as TJSONArray;
  try
    for Item in Cases do
    begin
      C:=TJSONObject(Item); Name:=C.GetValue<string>('name');
      Stream:=TFileStream.Create(Root+Name,fmOpenRead or fmShareDenyWrite);
      try
        Stream.Position:=3;
        Data:=ReadPackageBookCover(Stream,ExtractFileExt(Name),Status);
        Require(Stream.Position=3,'Cover read moved caller stream: '+Name);
        if C.GetValue<Boolean>('cover') then
        begin
          Expected:=TFile.ReadAllBytes(Root+C.GetValue<string>('expected'));
          Require((Length(Data)=Length(Expected)) and
            CompareMem(Pointer(Data),Pointer(Expected),Length(Data)),'Wrong cover bytes: '+Name+' '+Status);
          Require(Status='','Successful cover retains error: '+Name+' '+Status);
        end
        else Require((Length(Data)=0) and (Status<>''),'Missing cover explanation: '+Name);
      finally Stream.Free; end;
      Writeln('PASS package cover ',Name); Flush(Output);
    end;
    Stream:=TFileStream.Create(Root+'epub3.epub',fmOpenRead or fmShareDenyWrite);
    try
      Checks:=0;
      try
        Data:=ReadPackageBookCover(Stream,'.epub',Status,function:Boolean
          begin Inc(Checks); Result:=Checks>=3; end);
        Require(False,'Cover cancellation was ignored');
      except on E:EAbort do Require(Stream.Position=0,'Canceled cover moved caller stream'); end;
    finally Stream.Free; end;
    Writeln('PASS package cancellation');
  finally Cases.Free; end;
end;

procedure TestPackagePreview;
var Host:TForm; Panel:TInfoPanel; Preview:TBookInfoPreview; Book:TBookRecord;
  Image:TImage; OriginalHash,Folder:string; Started,Deadline:UInt64;
  Cases:TJSONArray; Item:TJSONValue; Expected:TStream; Graphic:TGraphic;
  procedure WaitPreview;
  begin
    Deadline:=GetTickCount64+15000;
    while Preview.Busy and (GetTickCount64<Deadline) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
    Require(not Preview.Busy,'Package preview did not finish');
  end;
  procedure ReadCover(const Source,Member:string; Width:Integer);
  begin
    Panel.Clear; Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
    if Member='' then
    begin Book.FileName:=ChangeFileExt(Source,''); Book.FileExt:=ExtractFileExt(Source); end
    else
    begin Book.Folder:=Source; Book.FileName:=ChangeFileExt(Member,''); Book.FileExt:=ExtractFileExt(Member); end;
    OriginalHash:=THashSHA2.GetHashStringFromFile(Folder+Source);
    Started:=GetTickCount64; Preview.Load(Book,True,False,False);
    Require(GetTickCount64-Started<100,'Package cover blocks selection'); WaitPreview;
    Require(Assigned(Image.Picture.Graphic) and (Image.Picture.Width=Width),
      'Package preview missing: '+Source+' '+Panel.PreviewStatusText);
    Require(THashSHA2.GetHashStringFromFile(Folder+Source)=OriginalHash,'Preview changed source');
    Writeln('PASS catalogue cover ',Source,' ',Member); Flush(Output);
  end;
begin
  Folder:=Settings.AppPath+'cover-fixtures'+PathDelim;
  Host:=TForm.CreateNew(nil); Panel:=TInfoPanel.Create(Host); Panel.Parent:=Host;
  Host.SetBounds(70,80,850,450); Panel.Align:=alClient; Host.Show;
  Preview:=TBookInfoPreview.CreateFor(Host,Panel);
  try
    Image:=nil;
    for var I:=0 to Panel.ControlCount-1 do if Panel.Controls[I] is TImage then Image:=TImage(Panel.Controls[I]);
    Require(Assigned(Image),'Cover image control absent');
    ReadCover('epub2.epub','',24); ReadCover('guide.epub','',24);
    ReadCover('word.docx','',24); ReadCover('open.odt','',24);
    ReadCover('outer.zip','books/epub3.epub',24);
    if TFile.Exists(Folder+'outer.7z') then ReadCover('outer.7z','books/epub3.epub',24);
    ReadCover('original.fb2','',24);
    Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'real-preview.json',TEncoding.UTF8)) as TJSONArray;
    try
      for Item in Cases do
      begin
        Expected:=TFileStream.Create(Folder+TJSONObject(Item).GetValue<string>('expected'),fmOpenRead);
        try Graphic:=CreateGraphicFromStream(Expected,64*1024*1024); finally Expected.Free; end;
        try
          Require(Assigned(Graphic),'Real cover cannot be decoded');
          ReadCover(TJSONObject(Item).GetValue<string>('name'),'',Graphic.Width);
        finally Graphic.Free; end;
      end;
    finally Cases.Free; end;
    // Switch while the previous reader is running: only the latest result may land.
    Book.FileName:='epub3'; Book.FileExt:='.epub'; Book.Folder:='';
    Preview.Load(Book,True,False,False); Sleep(120); Application.ProcessMessages;
    Book.FileName:='second'; Preview.Load(Book,True,False,False); WaitPreview;
    Require(Assigned(Image.Picture.Graphic) and (Image.Picture.Width=48),'Stale package cover replaced latest selection');
    Writeln('PASS latest package cover wins');
    Book.FileName:='absent'; Preview.Load(Book,True,False,False); WaitPreview;
    Require(not Assigned(Image.Picture.Graphic),'Previous cover survived a book without cover');
    Writeln('PASS book without cover clears previous image');
    Book.FileName:='badcrc'; Preview.Load(Book,True,False,False); WaitPreview;
    Require(not Assigned(Image.Picture.Graphic) and (Panel.PreviewStatusText<>''),'Damaged cover retained or unexplained');
    Writeln('PASS damaged cover reports status without stale image');
  finally Preview.Free; Host.Free; end;
end;
