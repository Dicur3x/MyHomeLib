// A whole-book DIB presentation exceeded the 256 MiB bound even though the
// JPEG sources were small. Exercise the actual native picture importer too:
// a compact RTF that silently drops pictures would not fix the book.
function ComparableNativePictureText(const Value: string): string;
begin
  // Independent native import also absorbs optional ASCII padding before
  // this colour-emoji sequence. Do not mistake that existing importer
  // behaviour for text deleted by deferred picture replacement.
  Result:=Value.TrimEnd([#13,#10]).Replace(' '+#$2764+#$FE0F,#$2764+#$FE0F);
end;

procedure AuditCompressedJPEGPictures;
var Doc: TReaderDocument; Reader: TfrmBuiltinReader; Encoded: UTF8String;
  Name, Text, BeforeHash, Actual: string; Images, Position, FirstPicture: Integer; Buffer: TRichEdit;
  Painted: TBitmap; Cases, Loads, FontSize: Integer; Memory: TProcessMemoryCounters; Kind, ReferenceText: string;
  Watch: TStopwatch; UntilTick: UInt64;
  ReferenceHost: TForm; Reference: TRichEdit; ReferenceOle: IInterface; ReferenceStream: TMemoryStream;
begin
  RequireIsolatedRegression; Cases:=0;
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    for Name in TArray<string>.Create('jpeg-repeated.fb2','png-repeated.epub','jpeg-real.fb2') do
    begin
      if not FileExists(Name) then Continue;
      BeforeHash:=THashSHA2.GetHashStringFromFile(Name);
      Doc:=TReaderDocument.Create;
      try
        Doc.Load(Name); Images:=Doc.ImageCount;
        // EM_GETTEXTRANGE represents each native picture by one space. The
        // semantic source uses U+FFFC; their UTF-16 positions must still match.
        Text:=Doc.PlainText; FirstPicture:=Pos(#$FFFC,Text)-1; Text:=Text.Replace(#$FFFC,' ');
        Require((Images>=200) and (Doc.SkippedImages=0),'JPEG stress input lost illustrations');
        Encoded:=Doc.RTF(500,500,True);
        Require(Length(Encoded)<64*1024*1024,'Bounded JPEG pictures inflated the presentation');
        Writeln('OBSERVED compressed JPEG ',Name,' images=',Images,' rtf_bytes=',Length(Encoded)); Flush(Output);
        ReferenceHost:=TForm.CreateNew(nil); Reference:=TRichEdit.Create(ReferenceHost);
        try
          Reference.Parent:=ReferenceHost; Reference.Visible:=False;
          ReferenceOle:=AttachReaderPictures(Reference);
          ReferenceStream:=TMemoryStream.Create;
          try
            ReferenceStream.WriteBuffer(Encoded[1],Length(Encoded)); ReferenceStream.Position:=0;
            ReaderLoadRTF(Reference,ReferenceStream);
          finally ReferenceStream.Free; end;
          ReferenceText:=ReaderTextRange(Reference,0,ReaderTextLength(Reference));
          Writeln('OBSERVED independent native import ',Name,' chars=',Length(ReferenceText),
            ' semantic_match=',ReferenceText.TrimEnd([#13,#10])=Text.TrimEnd([#13,#10])); Flush(Output);
          Require(ComparableNativePictureText(ReferenceText)=ComparableNativePictureText(Text),
            'Independent native import lost source content beyond known colour-emoji padding');
        finally ReferenceOle:=nil; ReferenceHost.Free; end;
        Encoded:='';
      finally Doc.Free; end;
      Reader:=TfrmBuiltinReader.Create(nil);
      try
        Reader.Show; Reader.OpenBook(Name,'JPEG stress',Name,'jpeg-reader.ini','pdfium.dll'); WaitReady(Reader);
        Buffer:=ReaderFormattingBuffer(Reader);
        FillChar(Memory,SizeOf(Memory),0); Memory.cb:=SizeOf(Memory);
        Require(GetProcessMemoryInfo(GetCurrentProcess,@Memory,SizeOf(Memory)),'Cannot observe native reader memory');
        Writeln('OBSERVED visible JPEG ',Name,' decoded=',Reader.DecodedPictureCount,
          ' commit_bytes=',Memory.PagefileUsage,' peak_working_set=',Memory.PeakWorkingSetSize); Flush(Output);
        Require(Memory.PagefileUsage<384*1024*1024,'Illustrated reader still keeps whole-book decoded rasters');
        Require(Reader.DecodedPictureCount<32,'Off-page illustrations remained decoded');
        Require(ReaderPictureCount(Buffer)=Images,'Native RTF import silently lost JPEG pictures');
        Actual:=Reader.BookText;
        if ComparableNativePictureText(Actual)<>ComparableNativePictureText(Text) then
        begin
          Position:=1;
          while (Position<=Length(Actual)) and (Position<=Length(Text)) and (Actual[Position]=Text[Position]) do Inc(Position);
          Writeln('OBSERVED text lengths source=',Length(Text),' native=',Length(Actual),' mismatch=',Position);
          if Position<=Length(Actual) then Writeln('OBSERVED native code=',Ord(Actual[Position]));
          if Position<=Length(Text) then Writeln('OBSERVED source code=',Ord(Text[Position])); Flush(Output);
        end;
        Require(ComparableNativePictureText(Actual)=ComparableNativePictureText(Text),'JPEG import changed source text');
        Text:=Actual;
        Loads:=Reader.PresentationLoads;
        Reader.SeekProgress(0.5); Application.ProcessMessages;
        for var Action:=0 to 3 do
        begin
          FontSize:=Reader.ReaderFontSize; Watch:=TStopwatch.StartNew;
          case Action of
            0,1: Reader.ToggleInterface;
            2: Reader.ChangeSize(1);
            3: Reader.ChangeSize(-1);
          end;
          // Pump the ordinary deferred resize timer, including its work in
          // the observed interaction time rather than timing only the click.
          UntilTick:=GetTickCount64+300;
          repeat Application.ProcessMessages; Sleep(5); until GetTickCount64>=UntilTick;
          Writeln('OBSERVED illustrated reflow ',Name,' action=',Action,
            ' elapsed_ms=',Watch.ElapsedMilliseconds,' imports=',Reader.PresentationLoads); Flush(Output);
          Require(Watch.ElapsedMilliseconds<5000,'Reader view change blocks for more than five seconds');
          Require(Reader.PresentationLoads=Loads,'Reader view change reparsed the entire book');
          Require(Reader.Ready and (Reader.PageText<>''),'View change lost the readable page');
          Require(ReaderPictureCount(Buffer)=Images,'View change lost picture objects');
          if Action=2 then Require(Reader.ReaderFontSize=FontSize+1,'Font size did not increase');
          if Action=3 then Require(Reader.ReaderFontSize=FontSize-1,'Font size did not decrease');
          Require(Reader.BookText=Text,'View change altered native book text');
        end;
        Writeln('PASS bounded picture reflow and font resize without whole-book import: ',Name);
        Position:=Reader.TextPosition; Reader.NextPage; Application.ProcessMessages;
        Require(Reader.TextPosition>Position,'JPEG page cannot be turned');
        Reader.SeekProgress(0.9); Application.ProcessMessages;
        Require(Reader.Ready and (Reader.PageText<>''),'Late illustrated pages are unavailable');
        Require(Reader.DecodedPictureCount<32,'Paging retained off-page illustrations');
        Require(Reader.BookText.TrimEnd([#13,#10])=Text.TrimEnd([#13,#10]),'Picture replacement moved source text positions');
        if Name<>'jpeg-real.fb2' then
        begin
          Kind:='jpeg'; if ExtractFileExt(Name)='.epub' then Kind:='png';
          for var Theme in TArray<Integer>.Create(0,4) do
          begin
            Reader.SetTheme(Theme); Reader.GoToPosition(FirstPicture); Application.ProcessMessages;
            Require(Reader.DecodedPictureCount>0,'The requested illustrated page has no decoded picture');
            Painted:=TBitmap.Create;
            try
              Painted.SetSize(Reader.ReadingSurface.ClientWidth,Reader.ReadingSurface.ClientHeight);
              Reader.ReadingSurface.PaintTo(Painted.Canvas.Handle,0,0);
              Painted.SaveToFile(Kind+'-render-'+IntToStr(Theme)+'.bmp');
            finally Painted.Free; end;
            Require(ReaderPictureCount(Buffer)=Images,'Changing theme dropped JPEG objects');
            SelectReaderWord(Reader,'JPEG');
            Require(Buffer.SelText='JPEG','Illustrated text is no longer selectable');
          end;
        end;
        Reader.SetBounds(Reader.Left,Reader.Top,1120,800); Reader.SetPageLayout(rplDouble);
        for var Step:=0 to 9 do
        begin
          Reader.SeekProgress(Step/10.0); Application.ProcessMessages;
          Require(Reader.Ready and (Reader.PageText<>''),'Illustrated spread is unavailable');
          Require((Reader.DecodedPictureCount<32) and (ReaderPictureCount(Buffer)=Images),
            'Spread navigation retained off-page rasters or lost objects');
        end;
        FillChar(Memory,SizeOf(Memory),0); Memory.cb:=SizeOf(Memory);
        Require(GetProcessMemoryInfo(GetCurrentProcess,@Memory,SizeOf(Memory)),'Cannot observe post-navigation memory');
        Writeln('OBSERVED after spread navigation ',Name,' decoded=',Reader.DecodedPictureCount,
          ' commit_bytes=',Memory.PagefileUsage); Flush(Output);
        Require(Memory.PagefileUsage<384*1024*1024,'Picture navigation accumulated decoded pages');
        Reader.Close;
      finally Reader.Free; end;
      Require(THashSHA2.GetHashStringFromFile(Name)=BeforeHash,'Reading JPEG pictures rewrote the book');
      Inc(Cases);
    end;
    Require(Cases>0,'JPEG regression fixture is absent');
    Writeln('PASS bounded compressed JPEG books preserve all native pictures, exact text, navigation and source bytes cases=',Cases);
  finally DMUser.Free; DMUser:=nil; end;
end;
