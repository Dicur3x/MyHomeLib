type
  TArchiveFeedbackListAccess = class(TListBox);
  TArchiveFeedbackChooser = class
    Requested, DefaultMember, Failure: string;
    EmptySelection, SawDialog: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TArchiveFeedbackChooser.Tick(Sender: TObject);
var Dialog: TForm; Names: TListBox;
begin
  for var I:=0 to Screen.FormCount-1 do
  begin
    Dialog:=Screen.Forms[I];
    if not Dialog.Visible or ((Dialog.Caption<>'Какую книгу открыть?') and
      (Dialog.Caption<>'Какую книгу конвертировать?')) then Continue;
    TTimer(Sender).Enabled:=False; SawDialog:=True;
    for var Component in Dialog do
      if Component is TListBox then
      begin
        Names:=TListBox(Component);
        if Names.ItemIndex>=0 then DefaultMember:=Names.Items[Names.ItemIndex];
        Writeln('TRACE archive choice default=',DefaultMember,' requested=',Requested,' empty=',EmptySelection); Flush(Output);
        if EmptySelection then Names.ItemIndex:=-1
        else if Requested<>'' then Names.ItemIndex:=Names.Items.IndexOf(Requested);
        if not EmptySelection and (Names.ItemIndex<0) then Failure:='Requested member missing';
        TArchiveFeedbackListAccess(Names).DblClick;
        Writeln('TRACE archive double click modal=',Dialog.ModalResult,' class=',Names.ClassName); Flush(Output);
        if EmptySelection then
        begin
          if Dialog.ModalResult=mrOk then Failure:='Empty double click accepted';
          Dialog.ModalResult:=mrCancel;
        end
        else if Dialog.ModalResult<>mrOk then
        begin Failure:='Double click did not confirm'; Dialog.ModalResult:=mrCancel; end;
        Exit;
      end;
    Failure:='Archive list missing'; Dialog.ModalResult:=mrCancel; Exit;
  end;
end;

procedure TestArchiveOpenFeedback;
const XML='<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
  '<description><title-info><book-title>Основная книга</book-title><lang>ru</lang></title-info></description>'+
  '<body><section><title><p>Глава</p></title><p>Полная книга Ё.</p></section></body></FictionBook>';
  Companion='sardines:chocolate ice cream:pop corn:leeks:cottage cheese:olive oil:butter:tofu:';
var Root, FileName, Prepared, Hash: string; Zip: TZipFile; Stream: TBytesStream;
  Book: TBookRecord; Chooser: TArchiveFeedbackChooser; Timer: TTimer;
  Raster: TReaderRaster; Image: TBitmap; Chapters: TArray<TPDFChapter>; Colors: TArray<TColor>;
  procedure AddText(const Name, Text: string);
  begin
    Stream:=TBytesStream.Create(TEncoding.UTF8.GetBytes(Text));
    try Zip.Add(Stream,Name); finally Stream.Free; end;
  end;
  procedure Choose(const Member: string; Empty, Conversion: Boolean);
  begin
    Chooser.Requested:=Member; Chooser.EmptySelection:=Empty; Chooser.SawDialog:=False;
    Chooser.Failure:=''; Chooser.DefaultMember:=''; Timer.Enabled:=True;
    try
      if Conversion then Prepared:=PrepareConversionSource(Book,nil,'.epub')
      else Prepared:=PrepareReaderFile(Book,True);
    finally Timer.Enabled:=False; end;
    Require(Chooser.SawDialog and (Chooser.Failure=''),'Archive chooser: '+Chooser.Failure);
    Require(Chooser.DefaultMember='Основная книга.fb2','Archive initially selected an example text');
    if Empty then Require(Prepared='','Cancelled empty selection returned a book')
    else if Member='' then Require(TFile.ReadAllText(Prepared,TEncoding.UTF8)=XML,'Main book bytes changed')
    else Require(TFile.ReadAllText(Prepared,TEncoding.UTF8)=Companion,'Explicit companion selection changed bytes');
  end;
begin
  RequireIsolatedRegression;
  Writeln('TRACE archive feedback start'); Flush(Output);
  Root:=Settings.AppPath+'archive-open-feedback'; ForceDirectories(Root);
  FileName:=Root+'\bundle.zip'; Zip:=TZipFile.Create;
  try
    Zip.Open(FileName,zmWrite);
    AddText('Examples/Chapter 16/tobuy.txt',Companion);
    AddText('Основная книга.fb2',XML);
  finally Zip.Free; end;
  Hash:=UpdateSHA256(FileName);
  Book:=Default(TBookRecord); Book.NodeType:=ntBookInfo; Book.BookKey:=CreateBookKey(538,0);
  Book.CollectionRoot:=Root+'\'; Book.FileName:='bundle'; Book.FileExt:='.zip'; Book.Title:='Archive feedback';
  Include(Book.BookProps,bpIsLocal);
  Chooser:=TArchiveFeedbackChooser.Create; Timer:=TTimer.Create(nil);
  try
    Timer.Enabled:=False; Timer.Interval:=30; Timer.OnTimer:=Chooser.Tick;
    Choose('',False,False);
    Choose('Examples/Chapter 16/tobuy.txt',False,False);
    Choose('',True,False);
    Choose('',False,True);
  finally Timer.Free; Chooser.Free; end;
  Require(UpdateSHA256(FileName)=Hash,'Archive picker changed its source');
  Writeln('PASS archive picker prefers main document keeps companion text and double click confirms reading and conversion');

  FileName:=Root+'\comic.cbz'; Colors:=TArray<TColor>.Create(clRed,clLime,clBlue);
  Zip:=TZipFile.Create;
  try
    Zip.Open(FileName,zmWrite);
    // Deliberately out of order, Unicode, brackets and repeated base names.
    for var I in TArray<Integer>.Create(2,0,1) do
    begin
      Image:=TBitmap.Create; var PNG:=TPngImage.Create; var Buffer:=TMemoryStream.Create;
      try
        Image.SetSize(64,64); Image.Canvas.Brush.Color:=Colors[I]; Image.Canvas.FillRect(Rect(0,0,64,64));
        PNG.Assign(Image); PNG.SaveToStream(Buffer); Buffer.Position:=0;
        var Number:=IntToStr(I+1); if I=2 then Number:='10';
        Zip.Add(Buffer,'[Fansub] Токио/страница'+Number+'/page[1].png');
      finally Buffer.Free; PNG.Free; Image.Free; end;
    end;
    AddText('ComicInfo.xml','<ComicInfo/>');
  finally Zip.Free; end;
  Hash:=UpdateSHA256(FileName); Raster:=TReaderRaster.Create(FileName);
  try
    Require(Raster.PageCount=3,'Comic lost pages'); Chapters:=Raster.Chapters;
    Require(Chapters[0].Title.Contains('страница1/') and Chapters[1].Title.Contains('страница2/') and
      Chapters[2].Title.Contains('страница10/'),'Comic natural page order changed');
    for var I:=0 to 2 do
    begin
      Raster.PreparePage(I);
      Image:=Raster.Render(I,64,64);
      try Require(ColorToRGB(Image.Canvas.Pixels[32,32])=ColorToRGB(Colors[I]),
        'Comic read the wrong literal entry '+IntToStr(I));
      finally Image.Free; end;
    end;
  finally Raster.Free; end;
  Require(UpdateSHA256(FileName)=Hash,'Comic source changed');
  Writeln('PASS CBZ literal bracket Unicode duplicate base names natural order and all page pixels');
  FileName:=GetEnvironmentVariable('HLRU_REAL_CBZ_ARCHIVE');
  if FileName<>'' then
  begin
    // Read exactly the reported member. Never modify the user's collection.
    Zip:=TZipFile.Create;
    try
      Zip.Open(FileName,zmRead); var Data:TBytes; Zip.Read('812817.cbz',Data);
      FileName:=Root+'\812817.cbz'; TFile.WriteAllBytes(FileName,Data);
    finally Zip.Free; end;
    Hash:=UpdateSHA256(FileName); Raster:=TReaderRaster.Create(FileName,400);
    try
      Require(Raster.PageCount=159,'Reported Tokyo volume lost pages');
      for var I:=0 to Raster.PageCount-1 do
      begin
        Raster.PreparePage(I,False,400); var Size:=Raster.PageSize(I);
        Require((Size.X>0) and (Size.Y>0),'Reported comic page is empty');
        Image:=Raster.Render(I,80,100); Image.Free;
      end;
    finally Raster.Free; end;
    Require(UpdateSHA256(FileName)=Hash,'Reported comic input changed');
    Writeln('PASS real Tokyo Mew Mew 812817 all 159 pages decode and render with literal bracket paths');
  end;
end;
