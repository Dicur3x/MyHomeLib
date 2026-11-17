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

procedure TestKindlePreview;
var Host:TForm; Panel:TInfoPanel; Preview:TBookInfoPreview; Image:TImage;
  Folder,Name:string; Cases:TJSONArray; Book:TBookRecord; Deadline:UInt64;
begin
  Folder:=Settings.AppPath+'cover-fixtures\kindle\';
  Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'kindle-ui.json',TEncoding.UTF8)) as TJSONArray;
  Host:=TForm.CreateNew(nil); Panel:=TInfoPanel.Create(Host); Panel.Parent:=Host;
  Host.SetBounds(80,90,850,450); Panel.Align:=alClient; Host.Show;
  Preview:=TBookInfoPreview.CreateFor(Host,Panel);
  try
    Image:=nil;
    for var I:=0 to Panel.ControlCount-1 do if Panel.Controls[I] is TImage then Image:=TImage(Panel.Controls[I]);
    Require(Assigned(Image),'Kindle cover control missing');
    for var Value in Cases do
    begin
      var Item:=Value as TJSONObject; Name:=Item.GetValue<string>('name');
      Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
      Book.FileName:=ChangeFileExt(Name,''); Book.FileExt:=ExtractFileExt(Name);
      var Member:=Item.GetValue<string>('member','');
      if Member<>'' then
      begin Book.Folder:=Name; Book.FileName:=ChangeFileExt(Member,''); Book.FileExt:=ExtractFileExt(Member); end;
      var Started:=GetTickCount64; Preview.Load(Book,True,False,False);
      Require(GetTickCount64-Started<100,'Kindle cover blocks catalogue selection');
      Deadline:=GetTickCount64+15000;
      while Preview.Busy and (GetTickCount64<Deadline) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
      Require(not Preview.Busy,'Kindle cover preview timeout');
      if Item.GetValue<Boolean>('cover') then
      begin
        Require(Assigned(Image.Picture.Graphic),'Missing Kindle cover '+Name+' '+Panel.PreviewStatusText);
        Require((Image.Picture.Width=Item.GetValue<Integer>('width')) and
          (Image.Picture.Height=Item.GetValue<Integer>('height')),'Wrong Kindle cover dimensions');
        var Bitmap:=TBitmap.Create;
        try
          Bitmap.Assign(Image.Picture.Graphic);
          var Pixel:=ColorToRGB(Bitmap.Canvas.Pixels[Bitmap.Width div 2,Bitmap.Height div 2]);
          var Color:=Item.GetValue<TJSONArray>('color');
          Require((Abs(Integer(GetRValue(Pixel))-Color.Items[0].GetValue<Integer>)<=8) and
            (Abs(Integer(GetGValue(Pixel))-Color.Items[1].GetValue<Integer>)<=8) and
            (Abs(Integer(GetBValue(Pixel))-Color.Items[2].GetValue<Integer>)<=8),'Wrong Kindle cover pixels');
        finally Bitmap.Free; end;
      end
      else Require(not Assigned(Image.Picture.Graphic) and (Panel.PreviewStatusText<>''),
        'Undeclared/damaged Kindle cover selected an image');
      var Note:=Item.GetValue<string>('status','');
      if Note<>'' then Require(Panel.PreviewStatusText.Contains(Note),'Kindle thumbnail status missing');
      Writeln('PASS catalogue Kindle ',Name); Flush(Output);
    end;
    Require(not DirectoryExists(Settings.AppPath+'tools\kindle') and
      not DirectoryExists(Settings.AppPath+'tools\bookconvert'),'Preview needed whole-book converter');
  finally Preview.Free; Host.Free; Cases.Free; end;
end;

procedure TestXpsPreview;
var Host:TForm; Panel:TInfoPanel; Preview:TBookInfoPreview; Image:TImage;
  Folder, Hash, Tool:string; Book:TBookRecord; Bitmap:TBitmap; Deadline:UInt64;
  procedure WaitPreview;
  begin
    Deadline:=GetTickCount64+35000;
    while Preview.Busy and (GetTickCount64<Deadline) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
    Require(not Preview.Busy,'XPS preview did not finish');
  end;
  procedure SelectBook(const Name,Member:string);
  begin
    Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
    Book.FileName:=ChangeFileExt(Name,''); Book.FileExt:=ExtractFileExt(Name);
    if Member<>'' then
    begin Book.Folder:=Name; Book.FileName:=ChangeFileExt(Member,''); Book.FileExt:=ExtractFileExt(Member); end;
    Preview.Load(Book,True,False,False);
  end;
  procedure CheckCover(const Name,Member:string);
  begin
    Hash:=THashSHA2.GetHashStringFromFile(Folder+Name);
    var Started:=GetTickCount64; SelectBook(Name,Member);
    Require(GetTickCount64-Started<100,'XPS selection blocks the catalogue'); WaitPreview;
    Require(Assigned(Image.Picture.Graphic),'No XPS preview: '+Panel.PreviewStatusText);
    Require((Image.Picture.Width=450) and (Image.Picture.Height=600),'Wrong XPS cover dimensions');
    Bitmap:=TBitmap.Create;
    try
      Bitmap.Assign(Image.Picture.Graphic);
      Require(ColorToRGB(Bitmap.Canvas.Pixels[225,300])=RGB(32,80,176),'Wrong XPS page or pixels');
    finally Bitmap.Free; end;
    Require(Panel.PreviewStatusText.Contains('Предпросмотр первой страницы'),
      'First XPS page presented as a declared cover');
    Require(Hash=THashSHA2.GetHashStringFromFile(Folder+Name),'XPS source changed');
    Writeln('PASS catalogue XPS ',Name,' ',Member); Flush(Output);
  end;
begin
  Folder:=Settings.AppPath+'cover-fixtures'+PathDelim;
  Tool:=Settings.AppPath+'tools\xps\HomeLibXps.exe';
  Require(FileExists(Tool),'Private XPS helper missing');
  Host:=TForm.CreateNew(nil); Panel:=TInfoPanel.Create(Host); Panel.Parent:=Host;
  Host.SetBounds(80,90,850,450); Panel.Align:=alClient; Host.Show;
  Preview:=TBookInfoPreview.CreateFor(Host,Panel);
  try
    Image:=nil;
    for var I:=0 to Panel.ControlCount-1 do if Panel.Controls[I] is TImage then Image:=TImage(Panel.Controls[I]);
    Require(Assigned(Image),'Cover control missing');
    CheckCover('first-page.xps',''); CheckCover('xps-wrapper.zip','books/first-page.xps');
    CheckCover('first-page.oxps',''); CheckCover('xps-wrapper.zip','books/first-page.oxps');
    SelectBook('first-page.xps',''); SelectBook('broken.xps',''); WaitPreview;
    Require(not Assigned(Image.Picture.Graphic) and (Panel.PreviewStatusText<>''),
      'Broken XPS retained the previous selection cover');
    Writeln('PASS latest XPS selection and damaged input');
    TFile.Move(Tool,Tool+'.disabled');
    try
      SelectBook('first-page.xps',''); WaitPreview;
      Require(not Assigned(Image.Picture.Graphic) and Panel.PreviewStatusText.Contains('модуль'),
        'Missing XPS helper is not explained');
    finally TFile.Move(Tool+'.disabled',Tool); end;
    Writeln('PASS missing optional XPS module');
    Require(Length(TDirectory.GetDirectories(Settings.TempDir,'homelibre-xps-cover-*'))=0,
      'Catalogue preview retained XPS output');
  finally Preview.Free; Host.Free; end;
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
  var Direct:TStream; DirectGraphic:TGraphic;
  begin
    Panel.Clear; Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
    if Member='' then
    begin Book.FileName:=ChangeFileExt(Source,''); Book.FileExt:=ExtractFileExt(Source); end
    else
    begin Book.Folder:=Source; Book.FileName:=ChangeFileExt(Member,''); Book.FileExt:=ExtractFileExt(Member); end;
    if Source.StartsWith('flibrary/') then
    begin
      Direct:=Book.GetBookPreviewCoverStream;
      Require(Assigned(Direct),'Missing direct FLibrary side cover: '+Book.GetBookFileName+' member='+Member);
      try DirectGraphic:=CreateGraphicFromStream(Direct,64*1024*1024); finally Direct.Free; end;
      try Require(Assigned(DirectGraphic),'Undecodable direct FLibrary side cover: '+Member);
      finally DirectGraphic.Free; end;
    end;
    OriginalHash:=THashSHA2.GetHashStringFromFile(Folder+Source);
    Started:=GetTickCount64; Preview.Load(Book,True,False,False);
    Require(GetTickCount64-Started<100,'Package cover blocks selection'); WaitPreview;
    Require(Assigned(Image.Picture.Graphic) and (Image.Picture.Width=Width),
      Format('Package preview missing: %s member=%s width=%d expected=%d %s',
        [Source,Member,Image.Picture.Width,Width,Panel.PreviewStatusText]));
    Require(THashSHA2.GetHashStringFromFile(Folder+Source)=OriginalHash,'Preview changed source');
    Writeln('PASS catalogue cover ',Source,' ',Member); Flush(Output);
  end;
  procedure ReadFBDPackage(const Source:string; Width:Integer);
  var Raw:TStream; Zip:TZipFile;
  begin
    Panel.Clear; Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
    Book.FileName:=Source; Book.FileExt:='.epub';
    Require(Book.GetBookFormat=bfFbd,'Expected legacy FBD package locator');
    OriginalHash:=THashSHA2.GetHashStringFromFile(Folder+Source);
    Preview.Load(Book,True,False,False); WaitPreview;
    if Width>0 then Require(Assigned(Image.Picture.Graphic) and (Image.Picture.Width=Width),
      'FBD wrapper payload/cover selection failed: '+Source+' '+Panel.PreviewStatusText)
    else Require(not Assigned(Image.Picture.Graphic) and (Panel.PreviewStatusText<>''),
      'Ambiguous FBD wrapper selected an arbitrary payload');
    if Width>0 then
    begin
      Raw:=OpenBookImageSource(Book); Zip:=TZipFile.Create;
      try
        Zip.Open(Raw,zmRead);
        Require(Zip.IndexOf('META-INF/container.xml')>=0,'Image provider returned outer FBD ZIP instead of EPUB');
      finally Zip.Free; Raw.Free; end;
    end;
    Require(OriginalHash=THashSHA2.GetHashStringFromFile(Folder+Source),'FBD wrapper modified');
    Writeln('PASS FBD package ',Source); Flush(Output);
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
    ReadFBDPackage('fbd-covered.zip',48); ReadFBDPackage('fbd-no-cover.zip',24);
    ReadFBDPackage('fbd-descriptor-first.zip',24); ReadFBDPackage('fbd-ambiguous.zip',0);
    Book:=Default(TBookRecord); Book.CollectionRoot:=Folder; Book.FileName:='fbd-html.zip'; Book.FileExt:='.html';
    Expected:=OpenRawBookSource(Book);
    try
      var Bundle:=TZipFile.Create;
      try
        Bundle.Open(Expected,zmRead);
        Require((Bundle.IndexOf('book.html')>=0) and (Bundle.IndexOf('images/page.png')>=0),
          'FBD HTML wrapper lost linked resources');
      finally Bundle.Free; end;
    finally Expected.Free; end;
    Writeln('PASS FBD HTML keeps its resource bundle');
    Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'real-preview.json',TEncoding.UTF8)) as TJSONArray;
    try
      for Item in Cases do
      begin
        Expected:=TFileStream.Create(Folder+TJSONObject(Item).GetValue<string>('expected'),fmOpenRead);
        try Graphic:=CreateGraphicFromStream(Expected,64*1024*1024); finally Expected.Free; end;
        try
          Require(Assigned(Graphic),'Real cover cannot be decoded');
          ReadCover(TJSONObject(Item).GetValue<string>('name'),
            TJSONObject(Item).GetValue<string>('member',''),Graphic.Width);
          if TJSONObject(Item).GetValue<Boolean>('sidecar',False) then
          begin
            var Pixels:=TBitmap.Create;
            try
              Pixels.Assign(Image.Picture.Graphic);
              for var Sample in TJSONObject(Item).GetValue<TJSONArray>('samples') do
              begin
                var PointColor:=ColorToRGB(Pixels.Canvas.Pixels[TJSONObject(Sample).GetValue<Integer>('x'),TJSONObject(Sample).GetValue<Integer>('y')]);
                var RGBValues:=TJSONObject(Sample).GetValue<TJSONArray>('rgb');
                Require((Abs(Integer(GetRValue(PointColor))-RGBValues.Items[0].GetValue<Integer>)<=10) and
                  (Abs(Integer(GetGValue(PointColor))-RGBValues.Items[1].GetValue<Integer>)<=10) and
                  (Abs(Integer(GetBValue(PointColor))-RGBValues.Items[2].GetValue<Integer>)<=10),
                  'Real sidecar cover pixels differ from the independent reference');
              end;
            finally Pixels.Free; end;
            Require(Length(TDirectory.GetFiles(BookCachePath,'homelib-metadata-*.fb2'))=0,
              'Sidecar cover unnecessarily extracted the whole FB2');
            Writeln('PASS sidecar cover avoids full FB2 extraction');
          end;
          if TJSONObject(Item).GetValue<Boolean>('cancel_jxl',False) then
          begin
            var BeforeTemps:=TDirectory.GetFiles(Settings.TempDir);
            var DecoderStarted:=False; var SavedHeartbeat:=MHLExternalToolHeartbeat;
            MHLExternalToolHeartbeat:=procedure begin DecoderStarted:=True; end;
            try
              try
                Expected:=Book.GetBookPreviewCoverStream(function:Boolean begin Result:=DecoderStarted; end);
                Expected.Free; Require(False,'JPEG XL cover ignored cancellation');
              except on E:EAbort do Require(DecoderStarted,'Cancellation did not reach the active JPEG XL decoder'); end;
            finally MHLExternalToolHeartbeat:=SavedHeartbeat; end;
            Require(Length(TDirectory.GetFiles(Settings.TempDir))=Length(BeforeTemps),
              'Canceled JPEG XL cover left temporary files');
            Writeln('PASS JPEG XL cover cancels its active decoder and cleans working files');
          end;
        finally Graphic.Free; end;
      end;
    finally Cases.Free; end;
    for var Stem in TArray<string>.Create('oversized-cover','forged-cover') do
      if FileExists(Folder+'flibrary/'+Stem+'.7z') then
      begin
        Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
        Book.Folder:='flibrary/'+Stem+'.7z'; Book.FileName:='too-large'; Book.FileExt:='.fb2';
        Expected:=nil; var Rejected:=False;
        try
          try Expected:=Book.GetBookPreviewCoverStream; Rejected:=not Assigned(Expected);
          except on E:EReadError do Rejected:=True; end;
        finally Expected.Free; end;
        Require(Rejected,'Oversized or forged sidecar cover was accepted');
        Writeln('PASS sidecar rejects ',Stem);
      end;
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

procedure TestRasterPreview;
var Host:TForm; Panel:TInfoPanel; Preview:TBookInfoPreview; Book:TBookRecord;
  Image:TImage; Cases:TJSONArray; Item:TJSONValue; C:TJSONObject; Bitmap:TBitmap;
  Folder,Name,Hash:string; Started,Deadline:UInt64; Pixel:Cardinal; Expected:TJSONArray;
begin
  Folder:=Settings.AppPath+'cover-fixtures'+PathDelim;
  Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'raster-cases.json',TEncoding.UTF8)) as TJSONArray;
  Host:=TForm.CreateNew(nil); Panel:=TInfoPanel.Create(Host); Panel.Parent:=Host;
  Host.SetBounds(80,90,850,450); Panel.Align:=alClient; Host.Show;
  Preview:=TBookInfoPreview.CreateFor(Host,Panel);
  try
    Image:=nil;
    for var I:=0 to Panel.ControlCount-1 do if Panel.Controls[I] is TImage then Image:=TImage(Panel.Controls[I]);
    Require(Assigned(Image),'Raster cover control absent');
    for Item in Cases do
    begin
      C:=TJSONObject(Item); Name:=C.GetValue<string>('name');
      Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
      Book.FileName:=ChangeFileExt(Name,''); Book.FileExt:=ExtractFileExt(Name);
      if C.GetValue<string>('member','')<>'' then
      begin
        Book.Folder:=Name; Book.FileName:=ChangeFileExt(C.GetValue<string>('member'),'');
        Book.FileExt:=ExtractFileExt(C.GetValue<string>('member'));
      end;
      Hash:=THashSHA2.GetHashStringFromFile(Folder+Name);
      Started:=GetTickCount64; Preview.Load(Book,True,Name='sidecar-damaged.png',False);
      Require(GetTickCount64-Started<100,'Raster preview blocks selection');
      Deadline:=GetTickCount64+20000;
      while Preview.Busy and (GetTickCount64<Deadline) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
      Require(not Preview.Busy,'Raster preview timeout: '+Name);
      if C.GetValue<Boolean>('cover') then
      begin
        Require(Image.Picture.Graphic is TBitmap,'Missing raster preview: '+Name+' '+Panel.PreviewStatusText);
        Bitmap:=TBitmap(Image.Picture.Graphic);
        Require((Abs(Bitmap.Width-C.GetValue<Integer>('width'))<=C.GetValue<Integer>('dimension_tolerance',0)) and (Abs(Bitmap.Height-C.GetValue<Integer>('height'))<=C.GetValue<Integer>('dimension_tolerance',0)),
          'Wrong raster preview dimensions: '+Name);
        if C.GetValue<Boolean>('check_color',True) then
        begin
        Pixel:=ColorToRGB(Bitmap.Canvas.Pixels[Bitmap.Width div 2,Bitmap.Height div 2]);
        Expected:=C.GetValue<TJSONArray>('color');
        Require((Abs(Integer(GetRValue(Pixel))-Expected.Items[0].GetValue<Integer>)<=8) and
          (Abs(Integer(GetGValue(Pixel))-Expected.Items[1].GetValue<Integer>)<=8) and
          (Abs(Integer(GetBValue(Pixel))-Expected.Items[2].GetValue<Integer>)<=8),
          'Wrong first page: '+Name+' pixel='+IntToHex(Pixel,8));
        end;
        if C.TryGetValue<TJSONArray>('top_color',Expected) then
        begin
          Pixel:=ColorToRGB(Bitmap.Canvas.Pixels[Bitmap.Width div 2,1]);
          Require(Pixel=RGB(Expected.Items[0].GetValue<Integer>,Expected.Items[1].GetValue<Integer>,Expected.Items[2].GetValue<Integer>),
            'Raster preview is vertically flipped at top');
          Expected:=C.GetValue<TJSONArray>('bottom_color');
          Pixel:=ColorToRGB(Bitmap.Canvas.Pixels[Bitmap.Width div 2,Bitmap.Height-2]);
          Require(Pixel=RGB(Expected.Items[0].GetValue<Integer>,Expected.Items[1].GetValue<Integer>,Expected.Items[2].GetValue<Integer>),
            'Raster preview is vertically flipped at bottom');
        end;
        Require(Panel.PreviewStatusText.Contains('Предпросмотр первой страницы'),
          'First-page preview is presented as an embedded cover');
      end
      else Require(not Assigned(Image.Picture.Graphic) and (Panel.PreviewStatusText<>''),
        'Non-comic archive or damaged image got a stale preview: '+Name);
      if Name='sidecar-damaged.png' then Require(Panel.PreviewStatusText.Contains('описание файла'),'Broken sidecar explanation lost');
      Require(Hash=THashSHA2.GetHashStringFromFile(Folder+Name),'Raster preview changed source');
      Writeln('PASS raster catalogue ',Name); Flush(Output);
    end;
    for var Cached in TDirectory.GetFiles(BookCachePath,'homelib-metadata-*.cbz') do
    begin
      var Data:=TFileStream.Create(Cached,fmOpenRead or fmShareDenyNone);
      try Require(Data.Size>0,'Failed empty extraction poisoned the completed cache'); finally Data.Free; end;
    end;
    Writeln('PASS empty payload leaves no completed zero-byte cache');
    for var Source in TDirectory.GetFiles(Folder,'*.pdf') do
    begin
      var Exclusive:=TFileStream.Create(Source,fmOpenRead or fmShareExclusive);
      Exclusive.Free;
    end;
    Writeln('PASS PDF previews release their source handles');
    // Teardown must not leave a background worker holding its source open.
    Book.FileName:='comic'; Book.FileExt:='.cbz'; Preview.Load(Book,True,False,False);
    Sleep(120); Application.ProcessMessages; FreeAndNil(Preview);
    var Source:=TFileStream.Create(Folder+'comic.cbz',fmOpenRead or fmShareExclusive);
    Source.Free; Writeln('PASS raster preview teardown releases source');
  finally Preview.Free; Host.Free; Cases.Free; end;
end;
