// Diagnostic only. Compare resetting an out record with the established Clear.
// The compiler must release managed out fields before the proposed zeroing.
procedure BenchmarkBookOutputReset;
const Iterations = 2000000;
var Seed, Former, Candidate: TBookRecord; Trial, Index: Integer;
  BeforeTicks, AfterTicks, BeforeCPU, AfterCPU: UInt64;

  procedure ResetFormer(out Value: TBookRecord);
  begin Value.Clear; end;

  procedure ResetCandidate(out Value: TBookRecord);
  begin
    FillChar(Value, SizeOf(Value), 0);
    Value.nodeType := ntBookInfo;
    Value.BookKey.Clear;
    Value.SeriesID := NO_SERIES_ID;
    Value.Series := NO_SERIES_TITLE;
    Value.RootGenre.Clear;
  end;

  function SameEmptyFields(const Left, Right: TBookRecord): Boolean;
  begin
    // Record padding has no defined value. Compare every declared field;
    // all three managed arrays must be empty after the established Clear.
    Result := (Left.nodeType = Right.nodeType) and Left.BookKey.IsSameAs(Right.BookKey) and
      (Left.ListOrder = Right.ListOrder) and (Left.SeriesID = Right.SeriesID) and
      (Left.Title = Right.Title) and (Left.Series = Right.Series) and
      (Length(Left.Genres) = 0) and (Length(Right.Genres) = 0) and
      (Length(Left.Authors) = 0) and (Length(Right.Authors) = 0) and
      (Left.CollectionName = Right.CollectionName) and (Left.Lang = Right.Lang) and
      (Left.Size = Right.Size) and (Left.Rate = Right.Rate) and
      (Left.SeqNumber = Right.SeqNumber) and (Left.Progress = Right.Progress) and
      (Left.LibRate = Right.LibRate) and (Left.BookProps = Right.BookProps) and
      (Left.Date = Right.Date) and (Left.FileExt = Right.FileExt) and
      (Left.FileName = Right.FileName) and (Left.LibID = Right.LibID) and
      (Left.Folder = Right.Folder) and (Left.InsideNo = Right.InsideNo) and
      (Left.RootGenre.GenreCode = Right.RootGenre.GenreCode) and
      (Left.RootGenre.ParentCode = Right.RootGenre.ParentCode) and
      (Left.RootGenre.FB2GenreCode = Right.RootGenre.FB2GenreCode) and
      (Left.RootGenre.GenreAlias = Right.RootGenre.GenreAlias) and
      (Left.KeyWords = Right.KeyWords) and (Left.CollectionRoot = Right.CollectionRoot) and
      (Left.Annotation = Right.Annotation) and (Left.Review = Right.Review) and
      (Left.Translators = Right.Translators) and (Left.Publisher = Right.Publisher) and
      (Left.City = Right.City) and (Left.PubYear = Right.PubYear) and
      (Left.ISBN = Right.ISBN) and (Length(Left.PublisherSeries) = 0) and
      (Length(Right.PublisherSeries) = 0) and
      (Left.PublisherSeriesKnown = Right.PublisherSeriesKnown) and
      (Left.PublisherSeqNumber = Right.PublisherSeqNumber);
  end;

  function Measure(Current: Boolean; out Cycles: UInt64): UInt64;
  var Watch: TStopwatch; StartedCycles: UInt64; I: Integer;
    Value: TBookRecord; Checksum: Int64;
  begin
    Checksum := 0;
    if not QueryThreadCycleTime(GetCurrentThread, StartedCycles) then RaiseLastOSError;
    Watch := TStopwatch.StartNew;
    if Current then
      for I := 1 to Iterations do
      begin ResetCandidate(Value); Inc(Checksum, Value.BookKey.BookID + Ord(Value.nodeType)); end
    else
      for I := 1 to Iterations do
      begin ResetFormer(Value); Inc(Checksum, Value.BookKey.BookID + Ord(Value.nodeType)); end;
    Result := Watch.ElapsedTicks;
    if not QueryThreadCycleTime(GetCurrentThread, Cycles) then RaiseLastOSError;
    Dec(Cycles, StartedCycles);
    Require(Checksum = Iterations * (MHL_INVALID_ID + Ord(ntBookInfo)), 'Record reset checksum differs');
  end;
begin
  {$IFNDEF MHL_RELEASE_PERFORMANCE}
  raise Exception.Create('Record reset diagnosis requires the GUI Performance build');
  {$ENDIF}
  Seed := Default(TBookRecord);
  Seed.nodeType := ntSeriesInfo;
  Seed.BookKey := CreateBookKey(123, 456); Seed.ListOrder := 789;
  Seed.SeriesID := 222; Seed.SeqNumber := 8; Seed.Size := 123456;
  Seed.Date := 45678.125; Seed.Rate := 4; Seed.Progress := 71; Seed.LibRate := 3;
  Seed.BookProps := [bpIsDeleted, bpIsLocal, bpHasReview];
  Seed.InsideNo := 33; Seed.PubYear := 2025; Seed.PublisherSeqNumber := 44;
  Seed.PublisherSeriesKnown := True;
  Seed.Title := 'Title Unicode'; Seed.Series := 'Series'; Seed.Lang := 'ru';
  Seed.FileExt := '.fb2'; Seed.FileName := 'Book'; Seed.LibID := '123';
  Seed.Folder := 'folder'; Seed.CollectionName := 'collection'; Seed.CollectionRoot := 'root';
  Seed.Annotation := 'annotation'; Seed.Review := 'review'; Seed.KeyWords := 'keywords';
  Seed.Translators := 'translator'; Seed.Publisher := 'publisher'; Seed.City := 'city'; Seed.ISBN := 'isbn';
  Seed.RootGenre.GenreCode := '0.1'; Seed.RootGenre.GenreAlias := 'Genre';
  Seed.RootGenre.ParentCode := '0'; Seed.RootGenre.FB2GenreCode := 'sf';
  SetLength(Seed.Authors, 2); Seed.Authors[0].LastName := 'First author';
  Seed.Authors[1].LastName := 'Second author';
  SetLength(Seed.Genres, 1); Seed.Genres[0] := Seed.RootGenre;
  TSeriesHelper.Add(Seed.PublisherSeries, 9, 'Publisher series', 2, False);
  for Index := 0 to 1023 do
  begin
    Former := Seed; Candidate := Seed;
    ResetFormer(Former); ResetCandidate(Candidate);
    Require(SameEmptyFields(Former, Candidate), 'Out record reset differs from established Clear');
    Require((Length(Seed.Authors) = 2) and (Seed.Authors[1].LastName = 'Second author') and
      (Length(Seed.Genres) = 1) and (Seed.Genres[0].GenreAlias = 'Genre') and
      (Seed.Title = 'Title Unicode') and (Length(Seed.PublisherSeries) = 1),
      'Reset damaged retained strings or nested arrays');
  end;
  Writeln('PASS diagnostic out reset preserves every established field and retained nested arrays'); Flush(Output);
  Measure(False, BeforeCPU); Measure(True, AfterCPU);
  for Trial := 0 to 6 do
  begin
    if Odd(Trial) then
    begin AfterTicks := Measure(True, AfterCPU); BeforeTicks := Measure(False, BeforeCPU); end
    else
    begin BeforeTicks := Measure(False, BeforeCPU); AfterTicks := Measure(True, AfterCPU); end;
    Writeln('RESETBENCH trial=', Trial, ' iterations=', Iterations, ' frequency=', TStopwatch.Frequency,
      ' before_ticks=', BeforeTicks, ' after_ticks=', AfterTicks,
      ' before_cycles=', BeforeCPU, ' after_cycles=', AfterCPU); Flush(Output);
  end;
  Writeln('PASS diagnostic managed out record reset comparison completed'); Flush(Output);
end;
