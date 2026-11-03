// A whole-book DIB presentation exceeded the 256 MiB bound even though the
// JPEG sources were small. Exercise the actual native picture importer too:
// a compact RTF that silently drops pictures would not fix the book.
type
  TFailingReaderRTFStream = class(TMemoryStream)
    function Read(var Buffer; Count: Longint): Longint; override;
  end;

function TFailingReaderRTFStream.Read(var Buffer; Count: Longint): Longint;
begin
  raise EReadError.Create('Deliberate isolated RTF input failure');
end;

procedure AuditRTFImportFailure;
var Host: TForm; Edit: TRichEdit; Stream: TFailingReaderRTFStream;
  OptionsBefore: LRESULT; Failed: Boolean;
begin
  RequireIsolatedRegression;
  Host:=TForm.CreateNew(nil); Edit:=TRichEdit.Create(Host);
  Stream:=TFailingReaderRTFStream.Create;
  try
    Edit.Parent:=Host; Edit.Visible:=False; Edit.Font.Charset:=DEFAULT_CHARSET;
    OptionsBefore:=SendMessage(Edit.Handle,EM_GETLANGOPTIONS,0,0); Failed:=False;
    try ReaderLoadRTF(Edit,Stream); except on E: EStreamError do Failed:=True; end;
    Require(Failed,'Failed RTF input was accepted');
    Require(SendMessage(Edit.Handle,EM_GETLANGOPTIONS,0,0)=OptionsBefore,
      'Failed RTF import did not restore language options');
    Writeln('PASS failed RTF input restores native language options'); Flush(Output);
  finally Stream.Free; Host.Free; end;
end;

function ComparableNativePictureText(const Value: string): string;
begin
  // RichEdit exposes U+2028 as the one-character manual-break code U+000B.
  // Normalize only that native representation and the final paragraph end.
  // Spaces before colour emoji are source text too: never discard them here.
  Result:=Value.TrimEnd([#13,#10]).Replace(#$2028,#11);
end;

function NativeUnicodeVariant(const Value: string; GroupSpecial: Boolean): string;
var B: TStringBuilder; M: TMatch; Start: Integer; Pattern: string;
begin
  Pattern:='(?<!\\)\\u(-?\d+)\?';
  if GroupSpecial then Pattern:='(?<!\\)\\u(8239|9785|9786)\?';
  B:=TStringBuilder.Create(Length(Value)); Start:=1;
  try
    for M in TRegEx.Matches(Value,Pattern) do
    begin
      B.Append(Copy(Value,Start,M.Index-Start));
      if GroupSpecial then B.Append('{\uc0');
      B.Append('\u').Append(M.Groups[1].Value).Append(' ');
      if GroupSpecial then B.Append('}');
      Start:=M.Index+M.Length;
    end;
    B.Append(Copy(Value,Start,MaxInt)); Result:=B.ToString;
  finally B.Free; end;
end;

// Diagnostic variants import the identical retained RTF, not a rebuilt book.
procedure AuditNativeUnicodeImport;
var Latin: TEncoding; Bytes, RoundTrip: TBytes; Original, Data, Expected, Actual, LabelText: string;
  Host: TForm; Edit: TRichEdit; Ole: IInterface; Stream: TBytesStream; Mode, At, Charset: Integer; OptionsBefore: LRESULT;
begin
  RequireIsolatedRegression;
  Charset:=StrToIntDef(GetEnvironmentVariable('MHL_NATIVE_PROBE_CHARSET'),-1);
  Require((Charset>=-1) and (Charset<=255),'Invalid diagnostic charset');
  Latin:=TEncoding.GetEncoding(28591);
  try
    Bytes:=TFile.ReadAllBytes('picture-mismatch.rtf'); Original:=Latin.GetString(Bytes);
    RoundTrip:=Latin.GetBytes(Original);
    Require((Length(Bytes)=Length(RoundTrip)) and CompareMem(@Bytes[0],@RoundTrip[0],Length(Bytes)),
      'Diagnostic byte mapping changed the retained RTF');
    Expected:=ComparableNativePictureText(TFile.ReadAllText('picture-expected.txt',TEncoding.UTF8));
    for Mode:=0 to 5 do
    begin
      Data:=Original; LabelText:='original';
      case Mode of
        1: begin
          LabelText:='no-ansi-fallback';
          Data:=NativeUnicodeVariant(Data,False);
          Data:=Data.Replace('\uc1','\uc0');
        end;
        2: begin
          LabelText:='isolated-special-unicode';
          Data:=NativeUnicodeVariant(Data,True);
        end;
        3: begin LabelText:='explicit-cyrillic-charset';
          Data:=Data.Replace('{\f0 Georgia;}','{\f0\fnil\fcharset204 Georgia;}'); end;
        4: begin LabelText:='neutral-language'; Data:=Data.Replace('\uc1\f0','\uc1\lang1024\f0'); end;
        5: LabelText:='auto-font-disabled';
      end;
      Host:=TForm.CreateNew(nil); Edit:=TRichEdit.Create(Host);
      try
        Edit.Parent:=Host; Edit.Visible:=False;
        if Charset>=0 then Edit.Font.Charset:=Byte(Charset);
        Ole:=AttachReaderPictures(Edit);
        if Mode=5 then SendMessage(Edit.Handle,EM_SETLANGOPTIONS,0,
          SendMessage(Edit.Handle,EM_GETLANGOPTIONS,0,0) and not IMF_AUTOFONT);
        Stream:=TBytesStream.Create(Latin.GetBytes(Data));
        OptionsBefore:=SendMessage(Edit.Handle,EM_GETLANGOPTIONS,0,0);
        try ReaderLoadRTF(Edit,Stream); finally Stream.Free; end;
        Require(SendMessage(Edit.Handle,EM_GETLANGOPTIONS,0,0)=OptionsBefore,
          'RTF import changed the native language options');
        Actual:=ComparableNativePictureText(ReaderTextRange(Edit,0,ReaderTextLength(Edit))).Replace(#$FFFC,' ');
        At:=1;
        while (At<=Length(Expected)) and (At<=Length(Actual)) and (Expected[At]=Actual[At]) do Inc(At);
        Writeln('UNICODE_PROBE ',LabelText,' exact=',Actual=Expected,' expected=',Length(Expected),
          ' actual=',Length(Actual),' first_difference=',At,' pictures=',ReaderPictureCount(Edit),
          ' charset=',Edit.Font.Charset,' language_options=',SendMessage(Edit.Handle,EM_GETLANGOPTIONS,0,0)); Flush(Output);
        Require(Actual=Expected,'Unicode native import lost source text: '+LabelText);
      finally Ole:=nil; Host.Free; end;
    end;
  finally Latin.Free; end;
end;

procedure AuditCompressedJPEGPictures;
var Doc: TReaderDocument; Reader: TfrmBuiltinReader; Encoded: UTF8String;
  Name, Text, BeforeHash, Actual: string; Images, Position, FirstPicture: Integer; Buffer: TRichEdit;
  Painted: TBitmap; Cases, Loads, FontSize: Integer; Memory: TProcessMemoryCounters; Kind, ReferenceText: string;
  Watch: TStopwatch; UntilTick: UInt64;
  ReferenceHost: TForm; Reference: TRichEdit; ReferenceOle: IInterface; ReferenceStream: TMemoryStream;
begin
  RequireIsolatedRegression; Cases:=0; AuditRTFImportFailure;
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
          Reference.Font.Charset:=DEFAULT_CHARSET;
          ReferenceOle:=AttachReaderPictures(Reference);
          ReferenceStream:=TMemoryStream.Create;
          try
            ReferenceStream.WriteBuffer(Encoded[1],Length(Encoded)); ReferenceStream.Position:=0;
            Writeln('OBSERVED native import fingerprint ',Name,' rtf_sha256=',THashSHA2.GetHashString(ReferenceStream),
              ' default_font=',Reference.Font.Name,' charset=',Reference.Font.Charset,
              ' language_options=',SendMessage(Reference.Handle,EM_GETLANGOPTIONS,0,0)); Flush(Output);
            ReferenceStream.Position:=0;
            var OptionsBefore:=SendMessage(Reference.Handle,EM_GETLANGOPTIONS,0,0);
            ReaderLoadRTF(Reference,ReferenceStream);
            Require(SendMessage(Reference.Handle,EM_GETLANGOPTIONS,0,0)=OptionsBefore,
              'Illustrated import changed the native language options');
          finally ReferenceStream.Free; end;
          ReferenceText:=ReaderTextRange(Reference,0,ReaderTextLength(Reference));
          Writeln('OBSERVED independent native import ',Name,' chars=',Length(ReferenceText),
            ' semantic_match=',ReferenceText.TrimEnd([#13,#10])=Text.TrimEnd([#13,#10])); Flush(Output);
          if ComparableNativePictureText(ReferenceText)<>ComparableNativePictureText(Text) then
          begin
            var Expected:=ComparableNativePictureText(Text);
            var Imported:=ComparableNativePictureText(ReferenceText);
            var At:=1;
            while (At<=Length(Expected)) and (At<=Length(Imported)) and (Expected[At]=Imported[At]) do Inc(At);
            var WindowText: string;
            var WindowLength:=SendMessage(Reference.Handle,WM_GETTEXTLENGTH,0,0);
            SetLength(WindowText,WindowLength+1);
            var WindowCopied:=SendMessage(Reference.Handle,WM_GETTEXT,WindowLength+1,LPARAM(PChar(WindowText)));
            SetLength(WindowText,WindowCopied);
            WindowText:=WindowText.Replace(#13#10,#13).Replace(#$FFFC,' ');
            Writeln('OBSERVED WM_GETTEXT ',Name,' chars=',Length(WindowText),
              ' expected_match=',ComparableNativePictureText(WindowText)=Expected,
              ' unicode_window=',IsWindowUnicode(Reference.Handle));
            var DebugRTF:=TMemoryStream.Create;
            try
              DebugRTF.WriteBuffer(Encoded[1],Length(Encoded));
              DebugRTF.SaveToFile('picture-mismatch.rtf');
            finally DebugRTF.Free; end;
            TFile.WriteAllText('picture-expected.txt',Expected,TEncoding.UTF8);
            TFile.WriteAllText('picture-imported.txt',Imported,TEncoding.UTF8);
            TFile.WriteAllText('picture-window.txt',WindowText,TEncoding.UTF8);
            Writeln('OBSERVED independent mismatch ',Name,' expected_chars=',Length(Expected),
              ' imported_chars=',Length(Imported),' at=',At); Flush(Output);
            Writeln('OBSERVED expected context: ',Copy(Expected,Max(1,At-32),72));
            Writeln('OBSERVED imported context: ',Copy(Imported,Max(1,At-32),72));
            if At<=Length(Expected) then Writeln('OBSERVED expected code=',Ord(Expected[At]));
            if At<=Length(Imported) then Writeln('OBSERVED imported code=',Ord(Imported[At]));
            Flush(Output);
          end;
          Require(ComparableNativePictureText(ReferenceText)=ComparableNativePictureText(Text),
            'Independent native import changed source text');
        finally ReferenceOle:=nil; ReferenceHost.Free; end;
        Encoded:='';
      finally Doc.Free; end;
      Reader:=TfrmBuiltinReader.Create(nil);
      try
        Reader.Show; Buffer:=ReaderFormattingBuffer(Reader); Buffer.Font.Charset:=DEFAULT_CHARSET;
        Reader.OpenBook(Name,'JPEG stress',Name,'jpeg-reader.ini','pdfium.dll'); WaitReady(Reader);
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
        // Native import may consume the known emoji-padding space above.
        // Select the picture by the native OLE position, rather than seeking
        // a source-text offset that may now point just after the picture.
        var PicturePositions:=ReaderPicturePositions(Buffer);
        Require(Length(PicturePositions)=Images,'Native picture position inventory is incomplete');
        Writeln('OBSERVED picture seek coordinates ',Name,' source_first=',FirstPicture,
          ' native_first=',PicturePositions[0]); Flush(Output);
        FirstPicture:=PicturePositions[0];
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
          Require(Reader.Ready and ((Reader.PageText<>'') or (Reader.DecodedPictureCount>0)),'View change lost the readable page');
          Require(ReaderPictureCount(Buffer)=Images,'View change lost picture objects');
          if Action=2 then Require(Reader.ReaderFontSize=FontSize+1,'Font size did not increase');
          if Action=3 then Require(Reader.ReaderFontSize=FontSize-1,'Font size did not decrease');
          Require(Reader.BookText=Text,'View change altered native book text');
        end;
        Writeln('PASS bounded picture reflow and font resize without whole-book import: ',Name);
        Position:=Reader.TextPosition; Reader.NextPage; Application.ProcessMessages;
        Require(Reader.TextPosition>Position,'JPEG page cannot be turned');
        Reader.SeekProgress(0.9); Application.ProcessMessages;
        Require(Reader.Ready and ((Reader.PageText<>'') or (Reader.DecodedPictureCount>0)),'Late illustrated pages are unavailable');
        Require(Reader.DecodedPictureCount<32,'Paging retained off-page illustrations');
        Require(Reader.BookText.TrimEnd([#13,#10])=Text.TrimEnd([#13,#10]),'Picture replacement moved source text positions');
        if Name<>'jpeg-real.fb2' then
        begin
          Kind:='jpeg'; if ExtractFileExt(Name)='.epub' then Kind:='png';
          for var Theme in TArray<Integer>.Create(0,4) do
          begin
            Reader.SetTheme(Theme); Reader.GoToPosition(FirstPicture); Application.ProcessMessages;
            // Palette/toolbar changes may still have an ordinary resize
            // message pending. Wait for the requested picture, then inspect
            // actual pixels below; a permanently blank page still fails.
            var PictureWatch:=TStopwatch.StartNew;
            while (Reader.DecodedPictureCount=0) and (PictureWatch.ElapsedMilliseconds<1000) do
            begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
            Writeln('OBSERVED picture target ',Name,' theme=',Theme,' target=',FirstPicture,
              ' current=',Reader.TextPosition,' decoded=',Reader.DecodedPictureCount,' page_chars=',Length(Reader.PageText)); Flush(Output);
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
          Require(Reader.Ready and ((Reader.PageText<>'') or (Reader.DecodedPictureCount>0)),'Illustrated spread is unavailable');
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
