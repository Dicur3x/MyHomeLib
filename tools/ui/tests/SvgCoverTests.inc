procedure TestSvgCovers;
var Folder,Tool,Status,Name,OriginalHash:string; Cases:TJSONArray; Entry:TJSONValue;
  Data:TBytes; Stream:TStream; Host:TForm; Panel:TInfoPanel; Preview:TBookInfoPreview;
  Picture:TImage; Book:TBookRecord; Bitmap:TBitmap; Deadline:UInt64;
  procedure WaitPreview;
  begin
    Deadline:=GetTickCount64+35000;
    while Preview.Busy and (GetTickCount64<Deadline) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
    Require(not Preview.Busy,'SVG preview did not finish');
  end;
  procedure CheckSamples(const Item:TJSONObject; Image:TGraphic);
  var Actual:TColor; Values:TJSONArray; X,Y:Integer;
  begin
    Require(Assigned(Image),'SVG preview has no image');
    Bitmap:=TBitmap.Create;
    try
      Bitmap.PixelFormat:=pf32bit; Bitmap.SetSize(Image.Width,Image.Height);
      Bitmap.Canvas.Brush.Color:=clWhite; Bitmap.Canvas.FillRect(Rect(0,0,Bitmap.Width,Bitmap.Height));
      Bitmap.Canvas.Draw(0,0,Image);
      for var Sample in Item.GetValue<TJSONArray>('samples') do
      begin
        var Point:=TJSONObject(Sample);
        X:=Round(Point.GetValue<Double>('x')*(Bitmap.Width-1));
        Y:=Round(Point.GetValue<Double>('y')*(Bitmap.Height-1));
        Actual:=ColorToRGB(Bitmap.Canvas.Pixels[X,Y]); Values:=Point.GetValue<TJSONArray>('rgb');
        Require((Abs(Integer(GetRValue(Actual))-Values.Items[0].GetValue<Integer>)<=12) and
          (Abs(Integer(GetGValue(Actual))-Values.Items[1].GetValue<Integer>)<=12) and
          (Abs(Integer(GetBValue(Actual))-Values.Items[2].GetValue<Integer>)<=12),
          Format('SVG composite differs: %s at %d,%d RGB=%d,%d,%d',
            [Name,X,Y,GetRValue(Actual),GetGValue(Actual),GetBValue(Actual)]));
      end;
      if Item.GetValue<Boolean>('text',False) then
      begin
        var Ink:=0;
        for Y:=Bitmap.Height div 3 to 2*Bitmap.Height div 3 do
          for X:=Bitmap.Width div 10 to 9*Bitmap.Width div 10 do
            if ColorToRGB(Bitmap.Canvas.Pixels[X,Y])<>clWhite then Inc(Ink);
        Require(Ink>100,'SVG text disappeared');
      end;
    finally Bitmap.Free; end;
  end;
begin
  Folder:=Settings.AppPath+'cover-fixtures'+PathDelim;
  Tool:=FindExternalTool('resvg.exe','kfx-export');
  Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'svg-preview.json',TEncoding.UTF8)) as TJSONArray;
  Host:=TForm.CreateNew(nil); Panel:=TInfoPanel.Create(Host); Panel.Parent:=Host; Panel.Align:=alClient;
  Host.SetBounds(70,80,850,450); Host.Show; Preview:=TBookInfoPreview.CreateFor(Host,Panel);
  try
    Picture:=nil;
    for var I:=0 to Panel.ControlCount-1 do if Panel.Controls[I] is TImage then Picture:=TImage(Panel.Controls[I]);
    Require(Assigned(Picture),'SVG catalogue image absent');
    for Entry in Cases do
    begin
      var Item:=TJSONObject(Entry); Name:=Item.GetValue<string>('name');
      OriginalHash:=THashSHA2.GetHashStringFromFile(Folder+Name);
      var Temps:=TDirectory.GetDirectories(Settings.TempDir,'homelibre-svg-cover-*');
      Stream:=TFileStream.Create(Folder+Name,fmOpenRead or fmShareDenyNone);
      try
        Stream.Position:=3;
        Data:=ReadPackageBookCover(Stream,ExtractFileExt(Name),Status,nil,function(Bytes:TBytes):TBytes
          begin Result:=RenderSvgBookCover(Bytes,Tool,Settings.TempDir); end);
        Require(Stream.Position=3,'SVG cover moved caller stream');
      finally Stream.Free; end;
      Require((Length(Data)>0)=Item.GetValue<Boolean>('cover'),'SVG result differs from fixture: '+Name+' '+Status);
      if Length(Data)>0 then
      begin
        var Graphic:=CreatePackageCoverGraphic(Data,64*1024*1024);
        try CheckSamples(Item,Graphic); finally Graphic.Free; end;
      end;
      Book:=Default(TBookRecord); Book.CollectionRoot:=Folder;
      Book.FileName:=ChangeFileExt(Name,''); Book.FileExt:=ExtractFileExt(Name);
      Preview.Load(Book,True,False,False); WaitPreview;
      if Item.GetValue<Boolean>('cover') then CheckSamples(Item,Picture.Picture.Graphic)
      else Require(not Assigned(Picture.Picture.Graphic) and (Panel.PreviewStatusText<>''),
        'SVG failure retained an old cover or has no explanation');
      Require(Length(TDirectory.GetDirectories(Settings.TempDir,'homelibre-svg-cover-*'))=Length(Temps),
        'SVG preview left temporary directories');
      Require(THashSHA2.GetHashStringFromFile(Folder+Name)=OriginalHash,'SVG preview changed source');
      Writeln('PASS static SVG composite ',Name); Flush(Output);
    end;
    var Drawing:=TFile.ReadAllBytes(Folder+'drawing.svg');
    try
      Data:=RenderSvgBookCover(Drawing,'absent-resvg.exe',Settings.TempDir);
      Require(False,'SVG accepted missing renderer');
    except on E:EReadError do Writeln('PASS SVG missing renderer'); end;
    try
      Data:=RenderSvgBookCover(Drawing,Tool,Settings.TempDir,function:Boolean begin Result:=True; end);
      Require(False,'SVG ignored pre-cancellation');
    except on E:EAbort do Writeln('PASS SVG pre-cancellation'); end;
    var Started:=False; var SavedHeartbeat:=MHLExternalToolHeartbeat;
    MHLExternalToolHeartbeat:=procedure begin Started:=True; end;
    try
      try
        Data:=RenderSvgBookCover(Drawing,Tool,Settings.TempDir,function:Boolean begin Result:=Started; end);
        Require(False,'SVG ignored active cancellation');
      except on E:EAbort do Require(Started,'SVG cancellation did not reach active renderer'); end;
    finally MHLExternalToolHeartbeat:=SavedHeartbeat; end;
    Require(Length(TDirectory.GetDirectories(Settings.TempDir,'homelibre-svg-cover-*'))=0,
      'Canceled SVG renderer left temporary directories');
    Writeln('PASS SVG active cancellation and cleanup');
  finally Preview.Free; Host.Free; Cases.Free; end;
end;
