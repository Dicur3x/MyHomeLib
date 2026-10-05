unit unit_MCP_SearchDateSelfTest;

interface

uses
  unit_Globals,
  unit_Interfaces;

procedure CheckSearchDatePeriods(const SystemData: ISystemData;
  const Collection: IBookCollection; const BookIDs: TArray<Integer>;
  const RootFolder: string; out CheckCount: Integer;
  out ReportedPresetsChecked: Boolean);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  unit_Consts,
  unit_SearchPresets;

// Real collection searches exercise production SQL and persisted combo indices.
// Only the six throwaway books change, inside a transaction that is rolled back.
procedure CheckSearchDatePeriods(const SystemData: ISystemData;
  const Collection: IBookCollection; const BookIDs: TArray<Integer>;
  const RootFolder: string; out CheckCount: Integer;
  out ReportedPresetsChecked: Boolean);
const
  PRESET_NAMES: array[0..2] of string = ('сегодня', 'за 3 дня', 'за неделю');
var
  Original: array[0..5] of TBookRecord;
  Book: TBookRecord;
  Today, Cutoff: TDateTime;
  I, Period: Integer;
  Criteria: TBookSearchCriteria;
  Presets: TSearchPresets;
  Preset: TSearchPreset;
  Value, RoundTripFile, ReportedFile: string;

  procedure CheckBooks(const LabelText: string; const Expected: array of Integer);
  var
    Iterator: IBookIterator;
    Row: TBookRecord;
    Found: Boolean;
    Count, J: Integer;
  begin
    Iterator := Collection.Search(Criteria, False);
    if Iterator.RecordCount <> Length(Expected) then
      raise Exception.CreateFmt('Date search %s: count %d, expected %d',
        [LabelText, Iterator.RecordCount, Length(Expected)]);
    Count := 0;
    while Iterator.Next(Row) do
    begin
      Found := False;
      for J := Low(Expected) to High(Expected) do
        Found := Found or (Row.BookKey.BookID = Expected[J]);
      if not Found then
        raise Exception.CreateFmt('Date search %s: unexpected book %d',
          [LabelText, Row.BookKey.BookID]);
      Inc(Count);
    end;
    if Count <> Length(Expected) then
      raise Exception.Create('Date search iterator count differs from its rows');
    Inc(CheckCount);
  end;

  procedure PrepareBoundaryBooks(const DateIndex: Integer);
  var
    J: Integer;
  begin
    // The cutoff day is excluded; the following day and today are included.
    case DateIndex of
      0: Cutoff := Today - 1;
      1: Cutoff := Today - 3;
      2: Cutoff := Today - 7;
      3: Cutoff := Today - 14;
      4: Cutoff := IncMonth(Today, -1);
      5: Cutoff := IncMonth(Today, -3);
    else
      raise Exception.Create('Unexpected date period in test');
    end;
    for J := 0 to High(Original) do
    begin
      Book := Original[J];
      Book.Lang := 'ru';
      case J of
        0: Book.Date := Cutoff + 1;
        1: Book.Date := Cutoff;
        2, 5: Book.Date := Today;
        3: Book.Date := Cutoff - 1;
        4: Book.Date := EncodeDate(2000, 1, 1);
      end;
      Collection.UpdateBook(Book);
    end;
    Criteria := Default(TBookSearchCriteria);
    Criteria.DateIdx := DateIndex;
    Criteria.CollapseMultiSeriesResults := True;
  end;

begin
  CheckCount := 0;
  ReportedPresetsChecked := False;
  Today := Date;
  if Length(BookIDs) <> Length(Original) then
    raise Exception.Create('Date search test requires the six fixture books');
  for I := 0 to High(Original) do
    Collection.GetBookRecord(CreateBookKey(BookIDs[I], Collection.CollectionID),
      Original[I], True);
  RoundTripFile := TPath.Combine(RootFolder, 'search-date-roundtrip.cxml2');
  ReportedFile := TPath.Combine(ExtractFilePath(ParamStr(0)), 'search-date-reported.cxml2');
  Presets := TSearchPresets.Create;
  try
    // Date remains the existing zero-based index; no preset migration is needed.
    for I := 0 to 5 do
      Presets.GetPreset('period-' + IntToStr(I)).AddOrSetValue(SF_DATE, IntToStr(I));
    Presets.Save(RoundTripFile);
    Presets.Clear;
    Presets.Load(RoundTripFile);
    Collection.BeginBulkOperation;
    try
      for Period := 0 to 5 do
      begin
        PrepareBoundaryBooks(Period);
        CheckBooks('without preset ' + IntToStr(Period), [BookIDs[0], BookIDs[2], BookIDs[5]]);
        Preset := Presets.GetPreset('period-' + IntToStr(Period));
        if not Preset.TryGetValue(SF_DATE, Value) or (Value <> IntToStr(Period)) then
          raise Exception.Create('Date index changed during preset save/load');
        Criteria.DateIdx := StrToInt(Value);
        CheckBooks('saved preset ' + IntToStr(Period), [BookIDs[0], BookIDs[2], BookIDs[5]]);
      end;

      // The reporter's exact compressed file is supplied by the Node wrapper.
      // Ordinary --make-fixture still tests all six periods without this file.
      if TFile.Exists(ReportedFile) then
      begin
        Presets.Clear;
        Presets.Load(ReportedFile);
        if Presets.Count <> Length(PRESET_NAMES) then
          raise Exception.Create('Reported date preset fixture has changed');
        for Period := Low(PRESET_NAMES) to High(PRESET_NAMES) do
        begin
          PrepareBoundaryBooks(Period);
          Preset := Presets.GetPreset(PRESET_NAMES[Period]);
          if not Preset.TryGetValue(SF_DATE, Value) or (Value <> IntToStr(Period)) then
            raise Exception.Create('Reported preset date index was not preserved');
          Criteria.DateIdx := StrToInt(Value);
          if not Preset.TryGetValue(SF_LANG, Value) or (Value <> '21') then
            raise Exception.Create('Reported language preset was not preserved');
          // cbLang index 21 is ru in the current form and in the attached preset.
          Criteria.Lang := 'ru';
          if not Preset.TryGetValue(SF_DELETED, Value) then
            raise Exception.Create('Reported deleted-book flag is missing');
          Criteria.Deleted := Value = '1';
          CheckBooks('reported preset ' + PRESET_NAMES[Period],
            [BookIDs[0], BookIDs[2], BookIDs[5]]);
        end;
        ReportedPresetsChecked := True;
      end;

      // Editable dates keep their existing SQL-style text behavior as well.
      PrepareBoundaryBooks(5);
      Criteria.DateIdx := -1;
      Criteria.DateText := '= "' + FormatDateTime('yyyy-mm-dd', Today) + '"';
      CheckBooks('custom date text', [BookIDs[2], BookIDs[5]]);
      Criteria.DateText := '';
      Criteria.Lang := 'ru';
      CheckBooks('empty date does not filter',
        [BookIDs[0], BookIDs[1], BookIDs[2], BookIDs[3], BookIDs[4], BookIDs[5]]);
      if Date <> Today then
        raise Exception.Create('Date search test crossed midnight; run it again');
    finally
      Collection.EndBulkOperation(False);
      // UpdateBook also refreshes the system cache; restore its original values.
      for I := 0 to High(Original) do
        SystemData.UpdateBook(Original[I]);
    end;
  finally
    Presets.Free;
    if TFile.Exists(RoundTripFile) then
      TFile.Delete(RoundTripFile);
  end;
end;

end.
