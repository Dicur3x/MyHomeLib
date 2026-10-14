// Publisher search and aligned annotation regression; isolated main form required.
// Additional uses: MHLButtonedEdit. No new runtime dependency.

procedure TestPublisherSearch(const One: IBookCollection; OneID: Integer);
var
  Edit: TMHLButtonedEdit;
  Menu: TMenuItem;
  IDs: array[0..5] of Integer;
  I, OriginalPPI: Integer;
  BeforeData, PresetHash: string;
  Reopened: TSearchPresets;

  function DataSnapshot: string;
  var DB: TSQLiteDatabase; Rows: TSQLiteQuery;
  begin
    Result := '';
    DB := TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(OneID).DBFileName);
    try
      Rows := DB.NewQuery('SELECT BookID,quote(LibID),quote(Title),quote(Publisher),quote(Ext),' +
        'Rate,Progress,hex(Review),IsDeleted,IsLocal,BookSize FROM Books ORDER BY BookID');
      try
        Rows.Open;
        while not Rows.Eof do
        begin
          for var Column := 0 to Rows.ColCount - 1 do
          begin
            var Value := Rows.FieldAsString(Column);
            Result := Result + IntToStr(Length(Value)) + ':' + Value;
          end;
          Result := Result + #10;
          Rows.Next;
        end;
      finally Rows.Free; end;
    finally DB.Free; end;
  end;

  function AddPublisherBook(const Title, Publisher, Extension: string): Integer;
  var Book: TBookRecord;
  begin
    Result := AddBook(One, Title, 'Publisher oracle', 'ru', '', '0.1');
    One.GetBookRecord(CreateBookKey(Result, OneID), Book, True);
    Book.Publisher := Publisher;
    Book.FileExt := Extension;
    One.UpdateBook(Book);
  end;

  procedure ExpectSearch(const Value: string; const Expected: array of string);
  var Criteria: TBookSearchCriteria; Iterator: IBookIterator; Book: TBookRecord;
    Actual, Wanted: TStringList;
  begin
    Criteria := Default(TBookSearchCriteria);
    Criteria.DateIdx := -1;
    Criteria.CollapseMultiSeriesResults := True;
    Criteria.Publisher := Value;
    Iterator := One.Search(Criteria, False);
    Actual := TStringList.Create;
    Wanted := TStringList.Create;
    try
      Require(Iterator.RecordCount = Length(Expected), 'Publisher search count differs from expected books');
      while Iterator.Next(Book) do Actual.Add(Book.Title);
      for var Title in Expected do Wanted.Add(Title);
      Actual.Sort;
      Wanted.Sort;
      Require(Actual.Text = Wanted.Text,
        'Publisher query mismatch for ' + Value + ': ' + Actual.CommaText);
    finally Wanted.Free; Actual.Free; end;
  end;

  function PublisherColumn(Tree: TBookTree): Integer;
  begin
    Result := -1;
    for var Index := 0 to Tree.Header.Columns.Count - 1 do
      if Tree.Header.Columns[Index].Tag = COL_PUBLISHER then Exit(Index);
  end;

  procedure CheckAnnotationLayout;
  var Body: TWinControl;
  begin
    Body := frmMain.edFAnnotation.Parent;
    Require((frmMain.Label7.Align = alTop) and (frmMain.edFAnnotation.Align = alTop),
      'Annotation caption and edit are not in the aligned reading order');
    Require((frmMain.Label7.Top + frmMain.Label7.Height <= frmMain.edFAnnotation.Top) and
      (frmMain.edFAnnotation.Top + frmMain.edFAnnotation.Height +
       frmMain.edFAnnotation.Margins.Bottom <= Body.ClientHeight - Body.Padding.Bottom),
      'Annotation is covered, clipped or outside its expanded panel at ' + IntToStr(frmMain.CurrentPPI));
    Require((frmMain.edFSeries.Top + frmMain.edFSeries.Height < Edit.Top) and
      (Edit.Top + Edit.Height < frmMain.edFGenre.Top),
      'Publisher field is out of the intended series/publisher/genre reading order');
  end;

begin
  RequireIsolatedRegression;
  Require(One.CollectionID = OneID, 'Publisher regression requires the isolated current collection');
  Edit := TMHLButtonedEdit(frmMain.FindComponent('edFPublisher'));
  Require(Assigned(Edit) and (Edit.Parent = frmMain.edFSeries.Parent) and
    Assigned(Edit.OnKeyDown) and Assigned(Edit.OnRightButtonClick),
    'Publisher search field is missing its layout, Enter or expression editor');
  Require(Edit.Hint.Contains('каталоге') and Edit.Hint.Contains('INPX'),
    'Publisher field does not explain unavailable catalog metadata');
  IDs[0] := AddPublisherBook('Publisher Cyrillic FB2', 'Ёжик Press', '.fb2');
  IDs[1] := AddPublisherBook('Publisher Cyrillic EPUB', 'еЖиК pReSs', '.epub');
  IDs[2] := AddPublisherBook('Publisher accented DOCX', 'ÉLAN Éditions', '.docx');
  IDs[3] := AddPublisherBook('Publisher apostrophe PDF', 'O''Reilly Media', '.pdf');
  IDs[4] := AddPublisherBook('Publisher prefix TXT', 'Ежик Press — серия', '.txt');
  IDs[5] := AddPublisherBook('Publisher absent DjVu', '', '.djvu');
  One.SetReview(CreateBookKey(IDs[0], OneID), 'Издательство не должно менять мою заметку ё');
  One.SetRate(CreateBookKey(IDs[0], OneID), 5);
  One.SetProgress(CreateBookKey(IDs[0], OneID), 63);
  BeforeData := DataSnapshot;

  // Independent result oracle across Unicode case, ё/е, exact and partial forms.
  ExpectSearch('еЖиК pReSs', ['Publisher Cyrillic FB2', 'Publisher Cyrillic EPUB', 'Publisher prefix TXT']);
  ExpectSearch('="ёжИК press"', ['Publisher Cyrillic FB2', 'Publisher Cyrillic EPUB']);
  ExpectSearch('="éLaN éditions"', ['Publisher accented DOCX']);
  ExpectSearch('="O''Reilly Media"', ['Publisher apostrophe PDF']);
  ExpectSearch('UNKNOWN PUBLISHER', []);
  Require(DataSnapshot = BeforeData, 'Publisher search changed catalog or personal data');
  Writeln('PASS publisher queries preserve Unicode case, ё/е and exact matches for FB2, EPUB, DOCX, PDF and TXT metadata');

  ShowPage(PAGE_SEARCH);
  frmMain.DoClearFilter(False);
  StartSQLiteProfile;
  Edit.Text := '="ёжИК press"';
  SaveSQLiteProfile(Settings.AppPath + 'publisher-search-typing.tsv');
  StopSQLiteProfile;
  {$IFDEF MHL_SQL_PROFILE}
  Require(not TFile.ReadAllText(Settings.AppPath + 'publisher-search-typing.tsv').Contains('MHLGenreMatches'),
    'Typing the publisher condition started a catalog query before Apply');
  {$ENDIF}
  ExpectTitles(frmMain.tvBooksSR, []);
  frmMain.DoApplyFilter(nil);
  ExpectTitles(frmMain.tvBooksSR, ['Publisher Cyrillic FB2', 'Publisher Cyrillic EPUB']);
  Edit.Text := 'Unapplied publisher draft';
  frmMain.HideDeletedBooksExecute(nil);
  ExpectTitles(frmMain.tvBooksSR, ['Publisher Cyrillic FB2', 'Publisher Cyrillic EPUB']);
  Require(Edit.Text = 'Unapplied publisher draft', 'Deletion toggle erased or applied a publisher draft');
  frmMain.DoApplyFilter(nil);
  ExpectTitles(frmMain.tvBooksSR, []);
  Writeln('PASS publisher input waits for Apply and is part of the applied snapshot without consuming later drafts');

  Edit.Text := '="éLaN éditions"';
  frmMain.cbPresetName.Text := 'Издательство — точное';
  frmMain.SaveSearchPreset(nil);
  PresetHash := THashSHA2.GetHashStringFromFile(Settings.SystemFileName[sfPresets]);
  Reopened := TSearchPresets.Create;
  try
    Reopened.Load(Settings.SystemFileName[sfPresets]);
    Require(Reopened.GetPreset('Издательство — точное').Items[SF_PUBLISHER] = Edit.Text,
      'Publisher preset lost its typed Unicode expression after compressed XML reopen');
  finally Reopened.Free; end;
  frmMain.DoClearFilter(False);
  Require(Edit.Text = '', 'Clear did not reset the publisher condition');
  frmMain.cbPresetName.Text := 'Издательство — точное';
  frmMain.cbPresetNameSelect(nil);
  Require(Edit.Text = '="éLaN éditions"', 'Selecting the publisher preset lost its expression');
  ExpectTitles(frmMain.tvBooksSR, []);
  frmMain.DoApplyFilter(nil);
  ExpectTitles(frmMain.tvBooksSR, ['Publisher accented DOCX']);
  Require(THashSHA2.GetHashStringFromFile(Settings.SystemFileName[sfPresets]) = PresetHash,
    'Publisher preset selection rewrote stored bytes');
  Writeln('PASS publisher presets preserve typed expressions across save/clear/select/reopen without automatic search');

  Menu := TMenuItem(frmMain.FindComponent('miColumnPublisher'));
  Require(Assigned(Menu) and (Menu.Tag = COL_PUBLISHER) and Assigned(Menu.OnClick),
    'Publisher column is absent from the header menu');
  var HadColumn := PublisherColumn(frmMain.tvBooksSR) >= 0;
  Require(Menu.Checked = HadColumn, 'Publisher header menu disagrees with the current view');
  Menu.OnClick(Menu);
  Require((PublisherColumn(frmMain.tvBooksSR) >= 0) <> HadColumn, 'Publisher column menu cannot toggle visibility');
  Menu.OnClick(Menu);
  Require((PublisherColumn(frmMain.tvBooksSR) >= 0) = HadColumn,
    'Publisher column toggle did not restore the original layout');
  Writeln('PASS publisher header toggle preserves each saved column layout');

  OriginalPPI := frmMain.CurrentPPI;
  frmMain.ctpBook.Collapsed := False;
  for I in [96, 144, 192] do
  begin
    frmMain.ScaleForPPI(I);
    frmMain.FormAfterMonitorDpiChanged(nil, OriginalPPI, I);
    CheckAnnotationLayout;
    frmMain.ctpBook.Collapsed := True;
    frmMain.FormAfterMonitorDpiChanged(nil, I, I);
    Require(frmMain.ctpBook.Collapsed, 'Search layout automatically opened a user-collapsed category');
    frmMain.ctpBook.Collapsed := False;
    CheckAnnotationLayout;
  end;
  frmMain.Label7.Font.Size := 24;
  frmMain.FormAfterMonitorDpiChanged(nil, frmMain.CurrentPPI, frmMain.CurrentPPI);
  CheckAnnotationLayout;
  Require(DataSnapshot = BeforeData, 'Search layout/preset/column operations changed source or personal data');
  Writeln('PASS expanded annotation remains visible at 100%, 150% and 200% and larger caption fonts while collapsed sections stay collapsed');
end;
