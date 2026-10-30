procedure AuditReaderBookSkin;
var Reader: TfrmBuiltinReader; Flat, Book, Early, Late: TBitmap;
  FileName, Text, Hash: string; Position, SelectedAt, LeftChanges, RightChanges: Integer;
  Size: TPoint; Skin: TReaderBookSkin; Paper: TColor; Pages: TArray<TRect>;
  function RasterHash(Bitmap: TBitmap): string;
  var Stream: TMemoryStream;
  begin
    Stream:=TMemoryStream.Create;
    try Bitmap.SaveToStream(Stream); Stream.Position:=0; Result:=THashSHA2.GetHashString(Stream);
    finally Stream.Free; end;
  end;
  procedure Capture(Bitmap: TBitmap);
  begin
    Bitmap.PixelFormat:=pf32bit;
    Bitmap.SetSize(Reader.ReadingSurface.Width,Reader.ReadingSurface.Height);
    Reader.ReadingSurface.PaintTo(Bitmap.Canvas.Handle,0,0);
  end;
begin
  Flat:=TBitmap.Create; Book:=TBitmap.Create; Early:=TBitmap.Create; Late:=TBitmap.Create;
  Skin:=TReaderBookSkin.Create;
  try
    // Fixed geometry independent of fonts: the full top edge stays horizontal
    // at normal/high DPI, with no opaque cover drawn across the page interior.
    for var PPI in [96,144,192] do
    begin
      Book.SetSize(MulDiv(1000,PPI,96),MulDiv(620,PPI,96));
      Paper:=RGB(245,235,215); Book.Canvas.Brush.Color:=Paper;
      Book.Canvas.FillRect(Rect(0,0,Book.Width,Book.Height));
      SetLength(Pages,2);
      Pages[0]:=Rect(MulDiv(24,PPI,96),MulDiv(8,PPI,96),Book.Width div 2,Book.Height-MulDiv(25,PPI,96));
      Pages[1]:=Rect(Book.Width div 2,Pages[0].Top,Book.Width-Pages[0].Left,Pages[0].Bottom);
      Skin.Paint(Book.Canvas,Rect(0,0,Book.Width,Book.Height),Pages,Paper,False,True,PPI,0.35);
      for var X:=Pages[0].Left to Pages[0].Right-2 do
        Require(Book.Canvas.Pixels[X,Pages[0].Top]=Book.Canvas.Pixels[Pages[0].Left,Pages[0].Top],
          'Book front top edge is skewed at DPI '+PPI.ToString);
      Require(Book.Canvas.Pixels[Pages[0].Left+Pages[0].Width div 2,Pages[0].Top+30]=Paper,
        'Cover or leaves overwrite the middle of the front page');
    end;
    Writeln('PASS book front edges remain straight at 96/144/192 DPI without opaque content masks');
    for FileName in ['words.fb2','words.pdf'] do
    begin
      Reader:=TfrmBuiltinReader.Create(nil);
      try
        Reader.SetBounds(40,40,1200,800); Reader.Show;
        Reader.OpenBook(FileName,'Книга с мягким сгибом',FileName,'volume-'+FileName+'.ini','pdfium.dll');
        WaitReady(Reader); Reader.SetTypography('Georgia',118,36); Reader.SetMaxTextWidth(960);
        Reader.SetSelectionEnabled(True);
        for var Layout in [rplSingle,rplDouble] do
        begin
          Reader.SetPageLayout(Layout); WaitPage(Reader);
          for var Theme:=0 to 5 do
          begin
            Reader.SetTheme(Theme); WaitPage(Reader); Reader.SetPageAppearance(rpaFlat);
            SelectedAt:=Pos('Привет',Reader.BookText)-1;
            if FileName='words.pdf' then Reader.SelectPDFText(0,6)
            else Reader.SelectText(SelectedAt,6);
            Capture(Flat); Hash:=RasterHash(Flat); Position:=Reader.TextPosition;
            Text:=Reader.SelectedText; Size:=Reader.PageRasterSize;
            Require(Text<>'','Book appearance test has no actual selected text');
            Reader.SetPageAppearance(rpaBook); Capture(Book);
            Require(RasterHash(Book)<>Hash,'Book material is invisible');
            Require((Reader.TextPosition=Position) and (Reader.SelectedText=Text) and
              (Reader.PageRasterSize=Size) and not Reader.PageLoading,
              'Book skin reflows, reloads or moves the selected text');
            if (FileName='words.fb2') and (Theme in [1,4]) then
              Book.SaveToFile(Format('book-appearance-%d-%d.bmp',[Ord(Layout),Theme]));
            Reader.SetPageAppearance(rpaFlat); Capture(Book);
            Require(RasterHash(Book)=Hash,'Flat appearance failed to restore exact pixels');
          end;
          Writeln('PASS '+FileName+' layout '+Ord(Layout).ToString+
            ' reversible material in six themes retains selection coordinates and pagination');
        end;
        if FileName='words.fb2' then
        begin
          Reader.SetTheme(1); Reader.SetPageAppearance(rpaBook); Reader.SetPageLayout(rplDouble); WaitPage(Reader);
          Reader.SeekProgress(0.05); WaitPage(Reader); Capture(Early);
          Reader.SeekProgress(0.90); WaitPage(Reader); Capture(Late);
          LeftChanges:=0; RightChanges:=0;
          for var Y:=30 to Early.Height-50 do for var X:=2 to 28 do
          begin
            if Early.Canvas.Pixels[X,Y]<>Late.Canvas.Pixels[X,Y] then Inc(LeftChanges);
            if Early.Canvas.Pixels[Early.Width-1-X,Y]<>Late.Canvas.Pixels[Late.Width-1-X,Y] then Inc(RightChanges);
          end;
          Require((LeftChanges>Early.Height) and (RightChanges>Early.Height),
            'Reading progress does not shift the exposed page blocks');
          Writeln('PASS exposed page thickness moves from right to left with reading progress');
          Reader.SetBounds(40,40,520,460); Reader.SetPageLayout(rplAutomatic); WaitPage(Reader);
          Capture(Book); Require(Reader.PageText<>'','Narrow automatic book lost content');
          Book.SaveToFile('book-appearance-narrow.bmp');
        end;
      finally Reader.Free; end;
    end;
  finally Skin.Free; Late.Free; Early.Free; Book.Free; Flat.Free; end;
end;
