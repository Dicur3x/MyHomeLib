// DPR uses: unit_InpLineReader. Only this wrapper-owned G runtime is used.
type
  TCatalogProcessMemory = record
    cb, PageFaultCount: DWORD;
    PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage,
    QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage,
    PagefileUsage, PeakPagefileUsage, PrivateUsage: NativeUInt;
  end;

function CatalogGetProcessMemoryInfo(Process: THandle; var Counters: TCatalogProcessMemory;
  Size: DWORD): BOOL; stdcall; external 'psapi.dll' name 'GetProcessMemoryInfo';

type
  TInpStreamingProbe = class
    Worker: TImportInpxThread;
    CancelAfterRows: Boolean;
    CanceledAfterRows: Boolean;
    procedure Comment(const Msg: string);
  end;

procedure TInpStreamingProbe.Comment(const Msg: string);
begin
  if CancelAfterRows and Msg.StartsWith('Добавлено ') then
  begin CanceledAfterRows := True; Worker.Cancel; end;
end;

procedure CPSWriteZip(const FileName, MemberName, Text: string; Encoding: TEncoding; BOM: Boolean);
var Archive: TZipFile; Input: TMemoryStream; Bytes, Preamble: TBytes;
begin
  Input := TMemoryStream.Create; Archive := TZipFile.Create;
  try
    if BOM then
    begin Preamble := Encoding.GetPreamble; if Length(Preamble) > 0 then Input.WriteBuffer(Preamble[0], Length(Preamble)); end;
    Bytes := Encoding.GetBytes(Text); if Length(Bytes) > 0 then Input.WriteBuffer(Bytes[0], Length(Bytes));
    Input.Position := 0;
    Archive.Open(FileName, zmWrite); Archive.Add(Input, MemberName, zcStored); Archive.Close;
  finally Archive.Free; Input.Free; end;
end;

function CPSBookRow(ID: Integer; const Sequence: string; Number: Integer; const Padding: string = ''): string;
begin
  Result := 'Автор,Имя,:'#4'prose_contemporary:'#4'Потоковая книга ё ' + IntToStr(ID) + #4 +
    Sequence + #4 + IntToStr(Number) + #4 + 'book' + IntToStr(ID) + #4'100'#4 +
    IntToStr(ID) + #4'0'#4'fb2'#4'2026-10-16'#4'ru'#4'4'#4 + Padding;
end;

procedure TestInpStreamingProposals;
var
  FileName, TempPath, Text, Line, SpoolPath, BeforeHash, BeforeReview: string;
  Archive: TMHLZip;
  Reader: TInpLineReader;
  Memory: TMemoryStream;
  OldLines, NewLines: TStringList;
  Encodings: array[0..3] of TEncoding;
  Data: TBytes;
  Collection: IBookCollection;
  DB: TSQLiteDatabase;
  CollectionID, A, Books, Series, ExpectedAuthors, ExpectedBooks, ExpectedSeries, Sentinel, First: Integer;
  Worker: TImportInpxThread;
  Probe: TInpStreamingProbe;
  Canceled, Rejected: Boolean;
  Builder: TStringBuilder;

  procedure RunImport(const Path: string; CancelRows, ExpectSuccess: Boolean);
  var ErrorText: string;
  begin
    Worker := TImportInpxThread.Create(CollectionID, Path, gtFb2);
    Probe := TInpStreamingProbe.Create;
    try
      Probe.Worker := Worker; Probe.CancelAfterRows := CancelRows;
      Worker.OnSetComment := Probe.Comment;
      Worker.Start; Worker.WaitFor;
      ErrorText := '';
      if Assigned(Worker.FatalException) then
        ErrorText := Exception(Worker.FatalException).ClassName + ': ' + Exception(Worker.FatalException).Message;
      if ExpectSuccess then
        Require(not Assigned(Worker.FatalException) and Worker.Success and Worker.CommittedChanges,
          'Actual streaming import failed to commit: ' + ErrorText)
      else
        Require(not Worker.Success and not Worker.CommittedChanges,
          'Failed or canceled streaming import committed changes');
      if CancelRows then Require(Probe.CanceledAfterRows and Worker.Canceled,
        'Cancellation did not occur after actual inserted rows')
      else if not ExpectSuccess then
        Require(UpperCase(ErrorText).Contains('CRC'), 'Corrupt fixture failed for a different reason: ' + ErrorText);
    finally Worker.Free; Probe.Free; end;
  end;

  procedure CheckRollback;
  begin
    Collection.GetStatistics(A, Books, Series);
    Require((A = ExpectedAuthors) and (Books = ExpectedBooks) and (Series = ExpectedSeries),
      'Streaming failure/cancellation left partial books/authors/series');
    Require((Collection.GetReview(CreateBookKey(Sentinel, CollectionID)) = BeforeReview) and
      (THashSHA2.GetHashStringFromFile(FileName) = BeforeHash),
      'Streaming failure changed source or personal review');
  end;

begin
  RequireIsolatedRegression;
  Require(ExpandFileName(Settings.AppPath).StartsWith('G:\', True), 'INP fixture must remain on G');
  TempPath := TPath.Combine(Settings.TempPath, 'inp-proposals-' + TGUID.NewGuid.ToString);
  ForceDirectories(TempPath);
  FileName := Settings.AppPath + 'inp-encoding.inpx';
  Text := 'Первая ё 日本語'#13#10#13#10'Вторая 😀'#10'Третья'#13'Последняя без LF';
  Encodings[0] := TEncoding.UTF8; Encodings[1] := TEncoding.UTF8;
  Encodings[2] := TEncoding.Unicode; Encodings[3] := TEncoding.BigEndianUnicode;
  OldLines := TStringList.Create; NewLines := TStringList.Create;
  try
    for var I := 0 to 3 do
    begin
      Writeln('TRACE proposal INP encoding case=', I, ' codepage=', Encodings[I].CodePage, ' stage=write-zip'); Flush(Output);
      CPSWriteZip(FileName, 'sample.inp', Text, Encodings[I], I <> 0);
      Writeln('TRACE proposal INP encoding case=', I, ' stage=open-archive'); Flush(Output);
      Archive := TMHLZip.Create(FileName, True);
      try
        if I < 2 then
        begin
          Memory := TMemoryStream.Create;
          try
            Archive.ExtractToStream(0, Memory); Memory.Position := 0;
            Writeln('TRACE proposal INP encoding case=', I, ' stage=old-string-list bytes=', Memory.Size); Flush(Output);
            OldLines.LoadFromStream(Memory, TEncoding.UTF8);
          finally Memory.Free; end;
        end
        else
        begin
          // The old production importer explicitly forced UTF-8 and rejects
          // these UTF-16 payloads. Their independent oracle is the exact
          // original Unicode text, not a claim of prior UTF-16 support.
          Writeln('TRACE proposal INP encoding case=', I, ' stage=exact-unicode-oracle'); Flush(Output);
          OldLines.Text := Text;
        end;
        Writeln('TRACE proposal INP encoding case=', I, ' stage=new-reader'); Flush(Output);
        Reader := TInpLineReader.Create(Archive, 0, TempPath);
        try
          NewLines.Clear;
          while Reader.ReadLine(Line) do
          begin
            NewLines.Add(Line);
            Require(Reader.LineNumber = NewLines.Count, 'Streaming row number is wrong');
          end;
          Require((NewLines.Text = OldLines.Text) and (NewLines.Count = 5) and
            (NewLines[1] = '') and (NewLines[4] = 'Последняя без LF'),
            'Streaming encoding/newline semantics differ from actual previous TStringList');
          Require(Reader.SpoolFileName = '', 'Tiny INP unexpectedly spooled to disk');
        finally Reader.Free; end;
        Writeln('TRACE proposal INP encoding case=', I, ' stage=cancel-reader'); Flush(Output);
        Canceled := False;
        Reader := TInpLineReader.Create(Archive, 0, TempPath,
          function: Boolean begin Result := Canceled; end);
        try
          Require(Reader.ReadLine(Line), 'Cancellation fixture has no first line');
          Canceled := True; Rejected := False;
          try Reader.ReadLine(Line); except on E: EAbort do Rejected := True; end;
          Require(Rejected, 'Reader ignored cancellation between lines');
        finally Reader.Free; end;
      finally Archive.Free; end;
    end;
  finally NewLines.Free; OldLines.Free; end;
  Writeln('PASS proposal INP reader matches legacy UTF8 and exact UTF16LE/BE Unicode, CR/LF/CRLF, empty rows and final no-LF lines');

  CollectionID := SystemDB.CreateCollection('INP streaming proposals', Settings.AppPath,
    'inp-proposals.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CollectionID);
  Sentinel := AddBook(Collection, 'Existing protected sentinel', 'Protected author', 'ru', '', '0.1');
  Collection.AddBookToGroup(CreateBookKey(Sentinel, CollectionID), FAVORITES_GROUP_ID);
  BeforeReview := 'Сохранённая личная заметка #ё';
  Collection.SetReview(CreateBookKey(Sentinel, CollectionID), BeforeReview);
  FileName := Settings.AppPath + 'inp-nonadjacent-series.inpx';
  CPSWriteZip(FileName, 'sample.inp', CPSBookRow(1, 'Первая серия', 2) + #13#10 +
    CPSBookRow(2, 'Третья серия', 4) + #10 + CPSBookRow(1, 'Вторая серия', 3), TEncoding.UTF8, True);
  BeforeHash := THashSHA2.GetHashStringFromFile(FileName);
  Writeln('TRACE proposal INP stage=actual-nonadjacent-series'); Flush(Output);
  RunImport(FileName, False, True);
  Collection.GetStatistics(ExpectedAuthors, ExpectedBooks, ExpectedSeries);
  Require(ExpectedBooks = 3, 'Nonadjacent series produced duplicate physical books');
  DB := TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(CollectionID).DBFileName);
  try First := DB.QuerySingleInt('SELECT BookID FROM Books WHERE LibID=?', ['1']);
  finally DB.Free; end;
  Require((First > 0) and (Length(Collection.GetBookSeries(CreateBookKey(First, CollectionID))) = 2),
    'Nonadjacent repeated row lost a series membership');
  CheckRollback;

  Builder := TStringBuilder.Create;
  try
    for var I := 3 to 202 do Builder.Append(CPSBookRow(I, 'Canceled series', I)).AppendLine;
    CPSWriteZip(Settings.AppPath + 'inp-cancel.inpx', 'sample.inp', Builder.ToString, TEncoding.UTF8, False);
  finally Builder.Free; end;
  Writeln('TRACE proposal INP stage=actual-cancel'); Flush(Output);
  RunImport(Settings.AppPath + 'inp-cancel.inpx', True, False);
  CheckRollback;

  CPSWriteZip(Settings.AppPath + 'inp-corrupt.inpx', 'sample.inp', CPSBookRow(999, 'Corrupt series', 1), TEncoding.UTF8, True);
  Data := TFile.ReadAllBytes(Settings.AppPath + 'inp-corrupt.inpx');
  // Stored ZIP has only one entry. Deliberately change both CRC claims, never
  // its payload; the actual production extraction must reject this archive.
  Data[14] := Data[14] xor 1;
  for var I := 0 to Length(Data) - 20 do
    if (Data[I] = $50) and (Data[I+1] = $4B) and (Data[I+2] = $01) and (Data[I+3] = $02) then
    begin Data[I+16] := Data[I+16] xor 1; Break; end;
  TFile.WriteAllBytes(Settings.AppPath + 'inp-corrupt.inpx', Data); Data := nil;
  Writeln('TRACE proposal INP stage=actual-corrupt-crc'); Flush(Output);
  RunImport(Settings.AppPath + 'inp-corrupt.inpx', False, False);
  CheckRollback;
  Writeln('PASS proposal actual INP worker preserves nonadjacent series, cancels after inserted rows and rolls back corrupted CRC');
end;

procedure TestInpStreamingMemory;
const Rows = 90000;
var
  RawPath, ZipPath, TempPath, Line, SpoolPath: string;
  Writer: TStreamWriter;
  Input: TFileStream;
  Zip: TZipFile;
  Archive: TMHLZip;
  Memory: TMemoryStream;
  Lines: TStringList;
  Reader: TInpLineReader;
  BeforeAllocated, OldAllocated, NewAllocated: Int64;
  OldMemory, NewMemory: TCatalogProcessMemory;
  OldMS, NewMS, Started: UInt64;
  InputSize, Checksum, OldChecksum: Int64;
  Count: Integer;
begin
  RequireIsolatedRegression;
  Require(ExpandFileName(Settings.AppPath).StartsWith('G:\', True), 'INP benchmark must remain on G');
  RawPath := Settings.AppPath + 'inp-memory-source.inp'; ZipPath := Settings.AppPath + 'inp-memory-source.inpx';
  TempPath := TPath.Combine(Settings.TempPath, 'inp-memory-' + TGUID.NewGuid.ToString);
  ForceDirectories(TempPath);
  Writer := TStreamWriter.Create(RawPath, False, TEncoding.UTF8, 65536);
  try
    for var I := 1 to Rows do
      Writer.WriteLine(CPSBookRow(I, 'Серия ё', 1, StringOfChar('x', 100)));
  finally Writer.Free; end;
  Input := TFileStream.Create(RawPath, fmOpenRead or fmShareDenyWrite);
  Zip := TZipFile.Create;
  try
    InputSize := Input.Size;
    Require(InputSize > INP_DISK_THRESHOLD, 'Memory fixture is too small to exercise spooling');
    Zip.Open(ZipPath, zmWrite); Zip.Add(Input, 'large.inp', zcDeflate); Zip.Close;
  finally Zip.Free; Input.Free; end;
  Archive := TMHLZip.Create(ZipPath, True);
  try
    BeforeAllocated := GetHeapStatus.TotalAllocated; Started := GetTickCount64;
    Memory := TMemoryStream.Create; Lines := TStringList.Create;
    try
      Archive.ExtractToStream(0, Memory); Memory.Position := 0;
      Lines.LoadFromStream(Memory, TEncoding.UTF8);
      OldAllocated := Int64(GetHeapStatus.TotalAllocated) - BeforeAllocated;
      FillChar(OldMemory, SizeOf(OldMemory), 0); OldMemory.cb := SizeOf(OldMemory);
      Require(CatalogGetProcessMemoryInfo(GetCurrentProcess, OldMemory, SizeOf(OldMemory)), 'Cannot read old-phase memory');
      Require(Lines.Count = Rows, 'Previous-reader benchmark lost rows');
      OldChecksum := 0; for Line in Lines do Inc(OldChecksum, Length(Line));
      OldMS := GetTickCount64 - Started;
    finally Lines.Free; Memory.Free; end;
    BeforeAllocated := GetHeapStatus.TotalAllocated; Started := GetTickCount64;
    Reader := TInpLineReader.Create(Archive, 0, TempPath);
    try
      SpoolPath := Reader.SpoolFileName;
      Require((SpoolPath <> '') and FileExists(SpoolPath), 'Large INP stayed entirely in memory');
      NewAllocated := Int64(GetHeapStatus.TotalAllocated) - BeforeAllocated;
      Count := 0; Checksum := 0;
      while Reader.ReadLine(Line) do begin Inc(Count); Inc(Checksum, Length(Line)); end;
      FillChar(NewMemory, SizeOf(NewMemory), 0); NewMemory.cb := SizeOf(NewMemory);
      Require(CatalogGetProcessMemoryInfo(GetCurrentProcess, NewMemory, SizeOf(NewMemory)), 'Cannot read new-phase memory');
      NewMS := GetTickCount64 - Started;
      Require((Count = Rows) and (Checksum = OldChecksum), 'Streaming benchmark changed rows/text');
    finally Reader.Free; end;
    Require(not FileExists(SpoolPath), 'Owned spool survived successful reader destruction');
    Writeln('PROFILE proposal inp memory rows=', Rows, ' bytes=', InputSize,
      ' old_heap_delta=', OldAllocated, ' stream_heap_delta=', NewAllocated,
      ' old_workingset=', OldMemory.WorkingSetSize, ' stream_workingset=', NewMemory.WorkingSetSize,
      ' old_private=', OldMemory.PrivateUsage, ' stream_private=', NewMemory.PrivateUsage,
      ' old_ms=', OldMS, ' stream_ms=', NewMS); Flush(Output);
    Require(OldAllocated > NewAllocated + InputSize,
      'Native allocation measurements did not confirm meaningful large-INP savings');
  finally Archive.Free; end;
  Writeln('PASS proposal INP large-member spool preserves 90000 Unicode rows and reduces native allocations with measured time/memory');
end;
