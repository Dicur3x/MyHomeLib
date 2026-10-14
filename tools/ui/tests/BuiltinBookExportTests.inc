// Native export integration regression. Include after Require is declared.
// Additional uses: Winapi.ActiveX, Winapi.ShlObj,
// frm_ExportToDeviceProgressForm, unit_ReaderDocument, unit_WorkerThread.

type
  TBBEExportCapture = class
  public
    Messages, Warnings: TStringList;
    constructor Create;
    destructor Destroy; override;
    function Message(const Text: string; Flags: Longint): Integer;
    procedure Warning(const Text: string; Severity: TTeletypeSeverity);
  end;

  TBBEExportProgressForm = class(TExportToDeviceProgressForm)
  public
    procedure EmitWarning(const Text: string);
    procedure BeginFixtureWorker;
  end;

  EBBEInjectedCleanupFailure = class(Exception);

  TBBELogLifecycleWorker = class(TWorker)
  protected
    procedure WorkFunction; override;
  end;

constructor TBBEExportCapture.Create;
begin
  inherited;
  Messages := TStringList.Create;
  Warnings := TStringList.Create;
end;

destructor TBBEExportCapture.Destroy;
begin
  Warnings.Free;
  Messages.Free;
  inherited;
end;

function TBBEExportCapture.Message(const Text: string; Flags: Longint): Integer;
begin
  // Handle all worker questions in-process. No live modal dialog is allowed.
  Messages.Add(Text);
  if (Flags and $F) = MB_YESNO then Result := IDYES
  else Result := IDOK;
end;

procedure TBBEExportCapture.Warning(const Text: string;
  Severity: TTeletypeSeverity);
begin
  Warnings.Add(Text);
end;

procedure TBBEExportProgressForm.EmitWarning(const Text: string);
begin
  ShowTeletype(Text, tsWarning);
end;

procedure TBBEExportProgressForm.BeginFixtureWorker;
begin
  StartWorker;
end;

procedure TBBELogLifecycleWorker.WorkFunction;
begin
  Teletype('Примечание до освобождения окна.', tsWarning);
  SetComment('Проверка закрытия журнала');
  SetProgress(100);
end;

procedure BBECheckProgressCleanup(DPI: Integer);
var
  Form: TBBEExportProgressForm;
  Worker: TBBELogLifecycleWorker;
  BeforeForms: Integer;
  CanClose, ExpectedFailure: Boolean;
begin
  BeforeForms := Screen.FormCount;
  Form := TBBEExportProgressForm.Create(nil);
  try
    Form.ScaleForPPI(DPI);
    Form.EmitWarning('Предпросмотр без запущенного задания.');
    CanClose := False;
    Require(Assigned(Form.OnCloseQuery), 'Export preview has no close-query handler');
    Form.OnCloseQuery(Form, CanClose);
    Require(CanClose, 'No-worker export preview cannot close');
    Form.btnCancel.OnClick(Form.btnCancel);
  finally Form.Free; end;
  Require(Screen.FormCount = BeforeForms, 'No-worker export preview leaked a registered form');

  Worker := TBBELogLifecycleWorker.Create;
  try
    Form := TBBEExportProgressForm.Create(nil);
    try
      Form.WorkerThread := Worker;
      Form.EmitWarning('Окно с назначенным, но ещё не запущенным заданием.');
    finally Form.Free; end;
    Require(not Worker.Finished, 'Closing an unstarted export preview ran its assigned worker');
    Worker.Cancel;
  finally Worker.Free; end;
  Require(Screen.FormCount = BeforeForms, 'Unstarted export preview leaked a registered form');

  // Exercise the same exception-unwind path as a failed geometry assertion,
  // with a real worker and its synchronized callbacks bound to the form.
  Worker := TBBELogLifecycleWorker.Create;
  try
    ExpectedFailure := False;
    try
      Form := TBBEExportProgressForm.Create(nil);
      try
        Form.ScaleForPPI(DPI);
        Form.WorkerThread := Worker;
        Form.BeginFixtureWorker;
        Worker.WaitFor;
        Require(Worker.Finished and not Assigned(Worker.FatalException),
          'Export lifecycle worker did not complete cleanly');
        raise EBBEInjectedCleanupFailure.Create('Expected export fixture cleanup probe');
      finally Form.Free; end;
    except
      on E: EBBEInjectedCleanupFailure do ExpectedFailure := True;
    end;
    Require(ExpectedFailure, 'Export cleanup fixture did not exercise exception unwinding');
    Require(not Assigned(Worker.OnOpenProgress) and not Assigned(Worker.OnProgressHint) and
      not Assigned(Worker.OnProgress) and not Assigned(Worker.OnCloseProgress) and
      not Assigned(Worker.OnTeletype) and not Assigned(Worker.OnSetComment) and
      not Assigned(Worker.OnShowMessage), 'Export window leaves dangling worker callbacks');
    Require(Screen.FormCount = BeforeForms, 'Failed export fixture leaked a registered form');
  finally Worker.Free; end;
  Writeln('PASS export preview closes without a worker and exception cleanup detaches joined worker callbacks at dpi=', DPI);
end;

function BBEFileHash(const FileName: string): string;
begin
  Require(FileExists(FileName), 'Missing required export fixture: ' + FileName);
  Result := THashSHA2.GetHashStringFromFile(FileName);
end;

function BBEClipboardText: string;
begin
  for var Attempt := 0 to 29 do
    try Exit(Clipboard.AsText);
    except
      on E: EClipboardException do
        if Attempt = 29 then raise else Sleep(10);
    end;
  Result := '';
end;

function BBETextFingerprint(const Text: string): string;
begin
  Result := 'len=' + IntToStr(Length(Text)) + ' utf16=';
  for var I := 1 to Min(Length(Text), 40) do
    Result := Result + IntToHex(Ord(Text[I]), 4);
end;

procedure BBERequireReadableBook(const FileName, SourceFile: string;
  const RichFixture: Boolean = True);
var
  Document, Source: TReaderDocument;
  Zip: TZipFile;
  Bytes: TBytes;
begin
  Require(FileExists(FileName), 'Export produced no output: ' + FileName);
  if SameText(ExtractFileExt(FileName), '.epub') then
  begin
    Zip := TZipFile.Create;
    try
      Zip.Open(FileName, zmRead);
      Require((Zip.FileCount > 0) and (Zip.FileNames[0] = 'mimetype'),
        'EPUB mimetype is not the first ZIP member');
      Zip.Read('mimetype', Bytes);
      Require(TEncoding.ASCII.GetString(Bytes) = 'application/epub+zip',
        'EPUB has an invalid MIME type');
      Require(Zip.IndexOf('META-INF/container.xml') >= 0,
        'EPUB lacks its package locator');
    finally Zip.Free; end;
  end;
  Document := TReaderDocument.Create;
  Source := TReaderDocument.Create;
  try
    Source.Load(SourceFile);
    Document.Load(FileName);
    Require(Document.PlainText.Trim <> '', 'Converted book has no readable text');
    Require(Document.Title = Source.Title, 'Conversion lost the book title');
    Require(Document.Language = Source.Language, 'Conversion lost the language');
    if RichFixture then
    begin
      for var Text in TArray<string>.Create('жирный', 'курсив', 'Цитата',
        'Строка один', 'Строка два', 'Конец.') do
      begin
        Require(Source.PlainText.Contains(Text),
          'Required rich source fixture lacks: ' + Text);
        Require(Document.PlainText.Contains(Text),
          'Converted book lost prose/formatting content: ' + Text);
      end;
      Require(Document.ImageCount > 0, 'Converted rich book lost its image');
      Require(Document.FootnoteCount > 0, 'Converted rich book lost its footnote');
      Require(Length(Document.Chapters) >= 3,
        'Converted rich book lost its nested chapter hierarchy');
    end;
  finally Source.Free; Document.Free; end;
end;

procedure BBECheckProgressUI(const ArtifactRoot: string);
var
  Form: TBBEExportProgressForm;
  Memo: TMemo;
  Key: Word;
  Intersection: TRect;
  OriginalTheme: Boolean;
  LongMessage, SelectedText, PreviewText, ActualClipboard: string;
  HasTerminalLineBreak: Boolean;
  ClipboardSequenceBefore, ClipboardSequenceAfter, ClipboardOwnerPID: DWORD;
  Watch, WarningWatch: TStopwatch;
  MaxWarningMilliseconds, AppendMilliseconds: Int64;
  Png: TPngImage;
  Bitmap: TBitmap;
begin
  OriginalTheme := MHLThemeDark;
  try
    for var Dark in TArray<Boolean>.Create(False, True) do
    begin
      SetMHLTheme(Dark);
      for var DPI in TArray<Integer>.Create(96, 144, 192) do
      begin
        Form := TBBEExportProgressForm.Create(nil);
        try
          // This is a visual-only fixture. Disable the inherited OnShow that
          // starts an export, then render a real window before simulating DPI.
          Form.OnShow := nil;
          Form.Show;
          Form.ScaleForPPI(DPI);
          Form.EmitWarning('Текст журнала: русский, ї є ґ ў и English.');
          Memo := Form.FindComponent('ConversionNotes') as TMemo;
          Require(Assigned(Memo) and Memo.Visible and Memo.Enabled and Memo.ReadOnly,
            'Export journal is absent, disabled or editable');
          Writeln('CHECK export geometry dark=', Ord(Dark), ' requested_dpi=', DPI,
            ' form_ppi=', Form.CurrentPPI, ' font_ppi=', Form.Font.PixelsPerInch,
            ' client_w=', Form.ClientWidth, ' client_h=', Form.ClientHeight,
            ' memo_l=', Memo.Left, ' memo_t=', Memo.Top, ' memo_w=', Memo.Width,
            ' memo_h=', Memo.Height, ' memo_ppi=', Memo.CurrentPPI,
            ' cancel_t=', Form.btnCancel.Top, ' cancel_h=', Form.btnCancel.Height,
            ' progress_t=', Form.ProgressBar.Top, ' progress_h=', Form.ProgressBar.Height);
          Require(Memo.TabStop and (Memo.TabOrder < Form.btnCancel.TabOrder),
            'Export journal or Cancel is inaccessible by keyboard');
          Require(Form.btnCancel.Visible and Form.btnCancel.Enabled,
            'Export journal disables or hides Cancel');
          Require((Memo.Left >= 0) and (Memo.Top >= 0) and
            (Memo.Left + Memo.Width <= Form.ClientWidth) and
            (Memo.Top + Memo.Height <= Form.ClientHeight),
            'Export journal extends outside the client area at ' + IntToStr(DPI));
          Require((Form.btnCancel.Left >= 0) and (Form.btnCancel.Top >= 0) and
            (Form.btnCancel.Left + Form.btnCancel.Width <= Form.ClientWidth) and
            (Form.btnCancel.Top + Form.btnCancel.Height <= Form.ClientHeight),
            'Cancel extends outside the client area at ' + IntToStr(DPI));
          Require(not IntersectRect(Intersection, Memo.BoundsRect,
            Form.btnCancel.BoundsRect), 'Export journal covers Cancel at ' + IntToStr(DPI));
          Require(not IntersectRect(Intersection, Memo.BoundsRect,
            Form.ProgressBar.BoundsRect), 'Export journal covers progress at ' + IntToStr(DPI));
          Require(Memo.Height >= MulDiv(100, DPI, 96),
            Format('Export journal is too short: requested_dpi=%d form_ppi=%d font_ppi=%d memo_ppi=%d client_h=%d memo_t=%d memo_h=%d cancel_t=%d cancel_h=%d',
              [DPI, Form.CurrentPPI, Form.Font.PixelsPerInch, Memo.CurrentPPI,
               Form.ClientHeight, Memo.Top, Memo.Height, Form.btnCancel.Top, Form.btnCancel.Height]));
          Require(ColorToRGB(Memo.Font.Color) = ColorToRGB(MHLThemeText),
            'Dynamic journal has the wrong text theme color');
          if Dark then Require(ColorToRGB(Memo.Color) = RGB(30, 31, 34),
            'Dynamic journal remains light in the dark theme')
          else Require(ColorToRGB(Memo.Color) = ColorToRGB(clWindow),
            'Dynamic journal remains dark in the light theme');

          Require(Assigned(Memo.OnKeyDown), 'Journal lacks keyboard copy handling');
          Key := Ord('A'); Memo.OnKeyDown(Memo, Key, [ssCtrl]);
          Require((Key = 0) and (Memo.SelLength = Length(Memo.Text)),
            'Journal Ctrl+A does not select its text');
          Key := Ord('C'); Memo.OnKeyDown(Memo, Key, [ssCtrl]);
          Require((Key = 0) and (BBEClipboardText = Memo.Text),
            'Journal Ctrl+C does not copy its text');
          Require(Assigned(Memo.PopupMenu) and (Memo.PopupMenu.Items.Count = 2),
            'Journal has no useful copy menu');
          Memo.SelStart := 0; Memo.SelLength := 0;
          Memo.PopupMenu.OnPopup(Memo.PopupMenu);
          Require(not Memo.PopupMenu.Items[0].Enabled,
            'Copy selection stays enabled without selected text');
          Memo.PopupMenu.Items[1].Click;
          Require(BBEClipboardText = Memo.Text, 'Copy all loses journal text');
          Memo.SelStart := 0; Memo.SelLength := 10; SelectedText := Memo.SelText;
          Memo.PopupMenu.OnPopup(Memo.PopupMenu);
          Require(Memo.PopupMenu.Items[0].Enabled, 'Copy selection is disabled');
          ClipboardSequenceBefore := GetClipboardSequenceNumber;
          Memo.PopupMenu.Items[0].Click;
          ClipboardSequenceAfter := GetClipboardSequenceNumber;
          ActualClipboard := BBEClipboardText;
          ClipboardOwnerPID := 0;
          GetWindowThreadProcessId(GetClipboardOwner, @ClipboardOwnerPID);
          Writeln('CHECK export selection copy dark=', Ord(Dark), ' requested_dpi=', DPI,
            ' start=', Memo.SelStart, ' selected_length=', Memo.SelLength,
            ' expected_', BBETextFingerprint(SelectedText),
            ' actual_', BBETextFingerprint(ActualClipboard),
            ' selected_now_', BBETextFingerprint(Memo.SelText),
            ' clipboard_sequence_before=', ClipboardSequenceBefore,
            ' clipboard_sequence_after=', ClipboardSequenceAfter,
            ' clipboard_owner_pid=', ClipboardOwnerPID, ' test_pid=', GetCurrentProcessId);
          Require((Memo.SelStart = 0) and (Memo.SelLength = 10) and (Length(SelectedText) = 10),
            'Journal loses its ten-character selection while copying');
          Require(ActualClipboard = SelectedText,
            'Copy selection copies the wrong text: expected_' + BBETextFingerprint(SelectedText) +
            ' actual_' + BBETextFingerprint(ActualClipboard));

          LongMessage := '';
          for var I := 1 to 1000 do LongMessage := LongMessage +
            'Длинное примечание ' + IntToStr(I) + ': сохранённый исходный текст.' + sLineBreak;
          Watch := TStopwatch.StartNew;
          MaxWarningMilliseconds := 0;
          for var I := 1 to 20 do
          begin
            WarningWatch := TStopwatch.StartNew;
            Form.EmitWarning(LongMessage);
            WarningWatch.Stop;
            MaxWarningMilliseconds := Max(MaxWarningMilliseconds,
              WarningWatch.ElapsedMilliseconds);
          end;
          Watch.Stop;
          AppendMilliseconds := Watch.ElapsedMilliseconds;
          Writeln('CHECK export log dark=', Ord(Dark), ' dpi=', DPI,
            ' warnings=20 input_lines_each=1000 input_chars_each=', Length(LongMessage),
            ' bounded_ms=', AppendMilliseconds, ' max_warning_ms=', MaxWarningMilliseconds);
          Require(Watch.ElapsedMilliseconds < 5000,
            Format('Bounded export warning preview stalls the interface: dark=%d dpi=%d elapsed_ms=%d max_warning_ms=%d',
              [Ord(Dark), DPI, AppendMilliseconds, MaxWarningMilliseconds]));
          PreviewText := Memo.Text;
          HasTerminalLineBreak := False;
          if Length(PreviewText) > 0 then
            HasTerminalLineBreak := CharInSet(PreviewText[Length(PreviewText)], [#13, #10]);
          Writeln('CHECK export preview dark=', Ord(Dark), ' dpi=', DPI,
            ' native_lines=', Memo.Lines.Count, ' native_chars=', Length(PreviewText),
            ' terminal_line_break=', Ord(HasTerminalLineBreak), ' word_wrap=', Ord(Memo.WordWrap));
          Require(not Memo.WordWrap and (Memo.ScrollBars = ssBoth),
            'Bounded export journal wraps rows or cannot scroll a long line');
          Require(not HasTerminalLineBreak,
            'Bounded export journal adds a terminal empty line');
          Require((Memo.Lines.Count <= 200) and (Length(Memo.Text) <= 24000),
            Format('Export warning preview grows without bound: dark=%d dpi=%d native_lines=%d native_chars=%d',
              [Ord(Dark), DPI, Memo.Lines.Count, Length(Memo.Text)]));
          Require(Memo.Lines[0].Contains('Полный отчёт'),
            'Truncated preview does not explain where the full report is');
          Require(not IntersectRect(Intersection, Memo.BoundsRect,
            Form.btnCancel.BoundsRect), 'Long export warnings cover Cancel');

          Memo.SelStart := 0;
          Memo.SelLength := 0;
          SendMessage(Memo.Handle, EM_SCROLLCARET, 0, 0);
          Form.Repaint;
          Memo.Repaint;
          Application.ProcessMessages;
          Require(Form.Visible and Memo.Visible and Memo.HandleAllocated and
            IsWindowVisible(Memo.Handle), 'Export visual fixture is not rendered');
          Bitmap := Form.GetFormImage;
          Png := TPngImage.Create;
          try
            Png.Assign(Bitmap);
            Png.SaveToFile(TPath.Combine(ArtifactRoot,
              Format('export-log-dark-%d-dpi-%d.png', [Ord(Dark), DPI])));
          finally Png.Free; Bitmap.Free; end;
          Writeln('PASS export log dark=', Ord(Dark), ' dpi=', DPI,
            ' visible_lines=', Memo.Lines.Count, ' chars=', Length(Memo.Text),
            ' bounded_ms=', AppendMilliseconds, ' max_warning_ms=', MaxWarningMilliseconds);
        finally Form.Free; end;
        BBECheckProgressCleanup(DPI);
      end;
    end;
  finally SetMHLTheme(OriginalTheme); end;
end;

procedure TestBuiltinBookExport(Collection: IBookCollection);
type
  TFileSnapshot = record FileName, Hash: string; end;
var
  FixtureRoot, ArtifactRoot, TempRoot, ExistingTemp, ZipName, PdfName,
    CancelName, Target, PreviousHash, SavedFileTemplate, SavedFolderTemplate,
    SavedTempDir, SavedReadDir, ReaderSentinel, NotesSentinel, HistorySentinel, InitialGroups: string;
  SavedOverwrite, SavedWebP: Boolean;
  SavedMode: TExportMode;
  Books: TArray<TBookRecord>;
  Snapshots: TArray<TFileSnapshot>;
  Capture: TBBEExportCapture;
  Zip: TZipFile;
  Builder: TStringBuilder;
  InitialAuthors, InitialBooks, InitialSeries, Authors, Count, Series: Integer;
  DirectFB2, DirectEpub, ZipFB2, ZipEpub, RawPDF, WarningEpub, CancelFB2,
    MtpFB2, MtpEpub: Integer;
  HR: HRESULT;

  procedure Snapshot(const FileName: string);
  var I: Integer;
  begin
    I := Length(Snapshots); SetLength(Snapshots, I + 1);
    Snapshots[I].FileName := FileName;
    Snapshots[I].Hash := BBEFileHash(FileName);
  end;

  function RegisterBook(const Title, Folder, FileName, Extension: string): Integer;
  var Book, Stored: TBookRecord; I: Integer;
  begin
    Book.Clear;
    Book.Title := Title; Book.FileName := FileName; Book.FileExt := Extension;
    Book.Folder := Folder; Book.Lang := 'ru'; Book.Size := 100;
    Book.LibID := 'builtin-export-' + TGUID.NewGuid.ToString;
    Book.Date := EncodeDate(2026, 10, 13);
    TAuthorsHelper.Add(Book.Authors, 'Export fixture', 'Анна', '');
    Include(Book.BookProps, bpIsLocal);
    Result := Collection.InsertBook(Book, False, False);
    Require(Result > 0, 'Could not register export fixture ' + Title);
    Book.BookKey := CreateBookKey(Result, Collection.CollectionID);
    Collection.SetProgress(Book.BookKey, 17);
    Collection.SetRate(Book.BookKey, 3);
    Collection.SetAnnotation(Book.BookKey, 'Сохранённая аннотация ё ї є ґ ў.');
    Collection.SetReview(Book.BookKey, 'Сохранённая мысль читателя.');
    Collection.AddBookToGroup(Book.BookKey, FAVORITES_GROUP_ID);
    Collection.GetBookRecord(Book.BookKey, Stored, True);
    I := Length(Books); SetLength(Books, I + 1); Books[I] := Stored;
  end;

  function OutputFolder(const Name: string): string;
  begin
    Result := TPath.Combine(ArtifactRoot, Name); ForceDirectories(Result);
  end;

  procedure RunExport(BookID: Integer; Mode: TExportMode; ExplicitMode: Boolean;
    const Folder: string; UseShell: Boolean = False; CancelDuring: Boolean = False;
    CancelBefore: Boolean = False);
  var
    Worker: TExportToDeviceThread;
    Keys: TBookIdList;
    Item: IShellItem;
    Marshaled: IStream;
    Canceler: TThread;
    ComInitialized: Boolean;
  begin
    Capture.Messages.Clear; Capture.Warnings.Clear;
    SetLength(Keys, 1); Keys[0].BookKey := CreateBookKey(BookID, Collection.CollectionID);
    Worker := TExportToDeviceThread.Create; Canceler := nil; ComInitialized := False;
    try
      Worker.BookIdList := Keys; Worker.DeviceDir := Folder;
      Worker.ExportMode := Mode; Worker.ExplicitFormat := ExplicitMode;
      Worker.ExtractOnly := False; Worker.UseMTP := UseShell;
      Worker.OnShowMessage := Capture.Message; Worker.OnTeletype := Capture.Warning;
      if UseShell then
      begin
        HR := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
        ComInitialized := Succeeded(HR);
        Require(ComInitialized or (HR = RPC_E_CHANGED_MODE), 'Cannot initialize Shell fixture COM');
        Require(Succeeded(SHCreateItemFromParsingName(PChar(Folder), nil, IShellItem, Item)),
          'Cannot obtain filesystem Shell export destination');
        Require(Succeeded(CoMarshalInterThreadInterfaceInStream(IShellItem, Item, Marshaled)),
          'Cannot marshal Shell destination to export worker');
        Worker.MarshalStream := Marshaled;
      end;
      if CancelBefore then Worker.Canceled := True;
      Worker.Start;
      if CancelDuring then
      begin
        Canceler := TThread.CreateAnonymousThread(procedure
          begin Sleep(25); Worker.Cancel; end);
        Canceler.FreeOnTerminate := False; Canceler.Start;
      end;
      Worker.WaitFor;
      Require(Worker.Finished, 'Native export worker did not publish completion');
      if Assigned(Worker.FatalException) then
      begin
        if Worker.FatalException is Exception then
          raise Exception.Create('Native export worker failed: ' +
            Exception(Worker.FatalException).Message);
        Require(False, 'Native export worker has an unknown fatal exception');
      end;
      if CancelDuring or CancelBefore then
        Require(Worker.Canceled, 'Export cancellation was ignored');
      if Capture.Messages.Count > 0 then
        Writeln('TRACE export handled_messages=', Capture.Messages.Count,
          ' warning_events=', Capture.Warnings.Count);
    finally
      if Assigned(Canceler) then begin Canceler.WaitFor; Canceler.Free; end;
      Worker.Free; Marshaled := nil; Item := nil;
      if ComInitialized then CoUninitialize;
    end;
  end;

  function GroupSignature: string;
  var Iterator: IBookIterator; Book: TBookRecord; Entries: TStringList;
  begin
    Entries := TStringList.Create;
    try
      Entries.Sorted := True;
      Iterator := SystemDB.GetBookIterator(FAVORITES_GROUP_ID, Collection.CollectionID);
      while Iterator.Next(Book) do
        Entries.Add(IntToStr(Book.BookKey.DatabaseID) + ':' + IntToStr(Book.BookKey.BookID) +
          '|' + Book.LibID + '|' + Book.Title + '|' + IntToStr(Book.Rate) +
          '|' + IntToStr(Book.Progress) + '|' + Book.Annotation + '|' + Book.Review);
      Result := Entries.Text;
    finally Iterator := nil; Entries.Free; end;
  end;

  procedure RequireSourcesAndData;
  var Stored: TBookRecord;
  begin
    for var Saved in Snapshots do
      Require(BBEFileHash(Saved.FileName) = Saved.Hash,
        'Export changed protected source/profile/history file: ' + Saved.FileName);
    for var Before in Books do
    begin
      Collection.GetBookRecord(Before.BookKey, Stored, True);
      Require((Stored.BookKey.BookID = Before.BookKey.BookID) and
        (Stored.LibID = Before.LibID) and (Stored.Title = Before.Title) and
        (Stored.FileName = Before.FileName) and (Stored.FileExt = Before.FileExt) and
        (Stored.Folder = Before.Folder) and (Stored.Progress = Before.Progress) and
        (Stored.Rate = Before.Rate) and (Stored.Annotation = Before.Annotation) and
        (Stored.Review = Before.Review) and (Stored.BookProps = Before.BookProps),
        'Export changed catalog/user metadata: ' + Before.Title);
    end;
    Collection.GetStatistics(Authors, Count, Series);
    Require((Authors = InitialAuthors) and (Count = InitialBooks) and
      (Series = InitialSeries), 'Export changed the collection book/author/series counts');
    Require(GroupSignature = InitialGroups, 'Export changed favorite membership or saved group cards');
    Require((Settings.FileNameTemplate = '%t') and (Settings.FolderTemplate = '') and
      (Settings.TempDir = TempRoot) and (Settings.ReadDir = TempRoot) and not Settings.OverwriteFB2Info and
      not Settings.ConvertWebPToPNG and (Settings.ExportMode = SavedMode),
      'Export changed its active settings');
    Require(FileExists(TPath.Combine(ExistingTemp, 'keep.txt')),
      'Export cancellation deleted another owner temporary data');
    for var Folder in TDirectory.GetDirectories(TempRoot) do
      Require(SameFileName(Folder, ExistingTemp),
        'Export left its owned conversion or MTP temporary folder: ' + Folder);
  end;

begin
  Require(Assigned(Collection), 'Builtin export regression requires a collection');
  Require(SameFileName(ExcludeTrailingPathDelimiter(TPath.GetFullPath(Collection.CollectionRoot)),
    ExcludeTrailingPathDelimiter(TPath.GetFullPath(Settings.AppPath))),
    'Builtin export collection must use the isolated application root');
  Require(SameText(ExtractFileDrive(TPath.GetFullPath(Settings.AppPath)), 'G:'),
    'Builtin export tests and temporary files must run on G');
  Require(SameText(ExtractFileDrive(Settings.DataPath), 'G:') and
    SameText(ExtractFileDrive(Settings.WorkPath), 'G:'),
    'Builtin export profile files and reports must run on G');
  FixtureRoot := TPath.Combine(Settings.AppPath, 'conversion-fixtures');
  Snapshot(TPath.Combine(FixtureRoot, 'source.fb2'));
  Snapshot(TPath.Combine(FixtureRoot, 'source.epub'));
  Snapshot(TPath.Combine(FixtureRoot, 'warning.epub'));
  Snapshot(TPath.Combine(Settings.AppPath, 'tools\bookconvert\convert_book.py'));
  Snapshot(TPath.Combine(Settings.AppPath, 'tools\kindle\python\python.exe'));
  ArtifactRoot := TPath.Combine(Settings.AppPath, 'builtin-export-' + TGUID.NewGuid.ToString);
  TempRoot := TPath.Combine(ArtifactRoot, 'temp');
  ExistingTemp := TPath.Combine(TempRoot, 'keep-existing');
  ForceDirectories(ExistingTemp); TFile.WriteAllText(TPath.Combine(ExistingTemp, 'keep.txt'),
    'Another owner temporary data', TEncoding.UTF8);
  Snapshot(TPath.Combine(ExistingTemp, 'keep.txt'));
  ReaderSentinel := TPath.Combine(Settings.DataPath, 'export-preserved-reader.ini');
  NotesSentinel := TPath.Combine(Settings.DataPath, 'export-preserved-notes.json');
  HistorySentinel := TPath.Combine(Settings.DataPath, 'export-preserved-history.txt');
  TFile.WriteAllText(ReaderSentinel, '[Reader]' + sLineBreak + 'Font=PT Serif', TEncoding.UTF8);
  TFile.WriteAllText(NotesSentinel, '{"quote":"Исходная цитата","note":"Личная мысль"}', TEncoding.UTF8);
  TFile.WriteAllText(HistorySentinel, 'Книга / позиция 17 / 2026-10-13', TEncoding.UTF8);
  Snapshot(ReaderSentinel); Snapshot(NotesSentinel); Snapshot(HistorySentinel);
  for var FileName in TDirectory.GetFiles(Settings.DataPath, '*.ini') do
    if not SameFileName(FileName, ReaderSentinel) then Snapshot(FileName);

  SavedFileTemplate := Settings.FileNameTemplate; SavedFolderTemplate := Settings.FolderTemplate;
  SavedTempDir := Settings.TempDir; SavedReadDir := Settings.ReadDir;
  SavedOverwrite := Settings.OverwriteFB2Info;
  SavedWebP := Settings.ConvertWebPToPNG; SavedMode := Settings.ExportMode;
  Capture := TBBEExportCapture.Create;
  try
    Settings.FileNameTemplate := '%t'; Settings.FolderTemplate := '';
    Settings.TempDir := TempRoot; Settings.ReadDir := TempRoot;
    Settings.OverwriteFB2Info := False;
    Settings.ConvertWebPToPNG := False;

    ZipName := TPath.Combine(FixtureRoot, 'native-export-source.zip');
    Require(not FileExists(ZipName), 'Generated export ZIP fixture already exists');
    Zip := TZipFile.Create;
    try
      Zip.Open(ZipName, zmWrite);
      Zip.Add(TPath.Combine(FixtureRoot, 'source.fb2'), 'book.fb2', zcDeflate);
      Zip.Add(TPath.Combine(FixtureRoot, 'source.epub'), 'book.epub', zcDeflate);
    finally Zip.Free; end;
    Snapshot(ZipName);
    PdfName := TPath.Combine(FixtureRoot, 'native-copy.pdf');
    Require(not FileExists(PdfName), 'Generated PDF copy fixture already exists');
    TFile.WriteAllBytes(PdfName, TEncoding.UTF8.GetBytes('%PDF-1.4' + sLineBreak +
      'Raw-copy regression payload: no converter may relabel this file.'));
    Snapshot(PdfName);
    CancelName := TPath.Combine(FixtureRoot, 'native-cancel.fb2');
    Require(not FileExists(CancelName), 'Generated cancellation fixture already exists');
    Builder := TStringBuilder.Create;
    try
      Builder.Append('<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' +
        '<description><title-info><genre>unrecognised</genre><author><nickname>Fixture</nickname></author>' +
        '<book-title>Cancellation</book-title><lang>ru</lang></title-info><document-info><author><nickname>Fixture</nickname></author>' +
        '<date>2026-10-13</date><id>native-cancel</id><version>1</version></document-info></description><body><section>');
      for var I := 1 to 100000 do Builder.Append('<p>Отмена большого экспорта. Исходный текст, история и настройки должны сохраниться. ' + IntToStr(I) + '</p>');
      Builder.Append('</section></body></FictionBook>');
      TFile.WriteAllText(CancelName, Builder.ToString, TEncoding.UTF8);
    finally Builder.Free; end;
    Snapshot(CancelName);

    DirectFB2 := RegisterBook('DirectFB2', 'conversion-fixtures', 'source', '.fb2');
    DirectEpub := RegisterBook('DirectEPUB', 'conversion-fixtures', 'source', '.epub');
    ZipFB2 := RegisterBook('ZipFB2', 'conversion-fixtures\native-export-source.zip', 'book', '.fb2');
    ZipEpub := RegisterBook('ZipEPUB', 'conversion-fixtures\native-export-source.zip', 'book', '.epub');
    RawPDF := RegisterBook('RawPDF', 'conversion-fixtures', 'native-copy', '.pdf');
    WarningEpub := RegisterBook('WarningEPUB', 'conversion-fixtures', 'warning', '.epub');
    CancelFB2 := RegisterBook('CancelFB2', 'conversion-fixtures', 'native-cancel', '.fb2');
    MtpFB2 := RegisterBook('ShellFB2', 'conversion-fixtures', 'source', '.fb2');
    MtpEpub := RegisterBook('ShellEPUB', 'conversion-fixtures', 'source', '.epub');
    Collection.GetStatistics(InitialAuthors, InitialBooks, InitialSeries);
    InitialGroups := GroupSignature;

    Target := OutputFolder('direct-fb2-epub'); RunExport(DirectFB2, emEpub, True, Target);
    BBERequireReadableBook(TPath.Combine(Target, 'DirectFB2.epub'), TPath.Combine(FixtureRoot, 'source.fb2'));
    Target := OutputFolder('direct-epub-fb2'); RunExport(DirectEpub, emFB2, True, Target);
    BBERequireReadableBook(TPath.Combine(Target, 'DirectEPUB.fb2'), TPath.Combine(FixtureRoot, 'source.epub'));
    Target := OutputFolder('zip-fb2-epub'); RunExport(ZipFB2, emEpub, True, Target);
    BBERequireReadableBook(TPath.Combine(Target, 'ZipFB2.epub'), TPath.Combine(FixtureRoot, 'source.fb2'));
    Target := OutputFolder('zip-epub-fb2'); RunExport(ZipEpub, emFB2, True, Target);
    BBERequireReadableBook(TPath.Combine(Target, 'ZipEPUB.fb2'), TPath.Combine(FixtureRoot, 'source.epub'));
    RequireSourcesAndData;
    Writeln('PASS independent native FB2 to EPUB and EPUB to FB2 actions for direct and ZIP-contained books preserve readable chapters, images, notes and sources');

    Target := OutputFolder('same-fb2'); RunExport(DirectFB2, emFB2, True, Target);
    Require(BBEFileHash(TPath.Combine(Target, 'DirectFB2.fb2')) = BBEFileHash(TPath.Combine(FixtureRoot, 'source.fb2')),
      'Same-format FB2 export rewrites book bytes');
    Target := OutputFolder('same-epub'); RunExport(DirectEpub, emEpub, True, Target);
    Require(BBEFileHash(TPath.Combine(Target, 'DirectEPUB.epub')) = BBEFileHash(TPath.Combine(FixtureRoot, 'source.epub')),
      'Same-format EPUB export rewrites book bytes');
    Target := OutputFolder('collision');
    TFile.WriteAllText(TPath.Combine(Target, 'DirectFB2.epub'), 'Existing personal output', TEncoding.UTF8);
    PreviousHash := BBEFileHash(TPath.Combine(Target, 'DirectFB2.epub'));
    RunExport(DirectFB2, emEpub, True, Target);
    Require(BBEFileHash(TPath.Combine(Target, 'DirectFB2.epub')) = PreviousHash,
      'Conversion overwrote an existing output');
    BBERequireReadableBook(TPath.Combine(Target, 'DirectFB2 (1).epub'), TPath.Combine(FixtureRoot, 'source.fb2'));
    PreviousHash := BBEFileHash(TPath.Combine(Target, 'DirectFB2 (1).epub'));
    RunExport(DirectFB2, emEpub, True, Target);
    Require(BBEFileHash(TPath.Combine(Target, 'DirectFB2 (1).epub')) = PreviousHash,
      'Repeated conversion overwrote a previous conversion');
    BBERequireReadableBook(TPath.Combine(Target, 'DirectFB2 (2).epub'), TPath.Combine(FixtureRoot, 'source.fb2'));
    RequireSourcesAndData;
    Writeln('PASS native same-format exports retain exact bytes and repeated exports reserve numbered names without replacement');

    for var Mode in TArray<TExportMode>.Create(emFB2, emEpub) do
    begin
      Target := OutputFolder('ordinary-pdf-' + IntToStr(Ord(Mode)));
      RunExport(RawPDF, Mode, False, Target);
      Require(BBEFileHash(TPath.Combine(Target, 'RawPDF.pdf')) = BBEFileHash(PdfName),
        'Ordinary send-to-device does not preserve a raw PDF');
      Require(not FileExists(TPath.Combine(Target, 'RawPDF.fb2')) and
        not FileExists(TPath.Combine(Target, 'RawPDF.epub')), 'Raw PDF acquired a false extension');
      Target := OutputFolder('explicit-pdf-' + IntToStr(Ord(Mode)));
      RunExport(RawPDF, Mode, True, Target);
      Require(Length(TDirectory.GetFiles(Target)) = 0,
        'Unsupported explicit PDF conversion published a bogus file');
      Require((Capture.Messages.Count = 1) and
        Capture.Messages.Text.Contains('FB2') and Capture.Messages.Text.Contains('EPUB') and
        Capture.Messages.Text.Contains('PDF'), 'Unsupported conversion lacks a useful explanation');
    end;
    RequireSourcesAndData;
    Writeln('PASS ordinary PDF copying is unchanged and explicit FB2/EPUB export rejects unsupported sources without false files');
    for var MissingID in TArray<Integer>.Create(0, -DirectFB2) do
    begin
      Target := OutputFolder('missing-book-' + IntToStr(MissingID));
      RunExport(MissingID, emFB2, False, Target);
      Require(Length(TDirectory.GetFiles(Target, '*', TSearchOption.soAllDirectories)) = 0,
        'Missing user card exported a guessed positive catalogue book');
      Require(Capture.Messages.Text.Contains('временно отсутствует'),
        'Missing user card export lacks a useful explanation');
      RequireSourcesAndData;
    end;
    Writeln('PASS retained missing/zero book IDs never dereference catalogue rows or export another book');

    Target := OutputFolder('cancel-before');
    RunExport(DirectFB2, emEpub, True, Target, False, False, True);
    Require((Length(TDirectory.GetFiles(Target)) = 0) and (Capture.Messages.Count = 0),
      'Pre-cancelled worker wrote a file or showed a failure question');
    Target := OutputFolder('cancel-during');
    RunExport(CancelFB2, emEpub, True, Target, False, True);
    Require((Length(TDirectory.GetFiles(Target)) = 0) and (Capture.Messages.Count = 0),
      'In-flight cancellation published an output or showed a failure question');
    RequireSourcesAndData;
    Writeln('PASS cancelled native export workers preserve source/profile/history and remove only their owned temporary data');

    Target := OutputFolder('warnings'); RunExport(WarningEpub, emFB2, True, Target);
    BBERequireReadableBook(TPath.Combine(Target, 'WarningEPUB.fb2'), TPath.Combine(FixtureRoot, 'warning.epub'), False);
    Require((Capture.Warnings.Count > 0) and (Capture.Messages.Count = 1),
      'Conversion warnings were lost or presented once per warning');
    Require(FileExists(Settings.SystemFileName[sfExportErrorLog]), 'Export warning report was not saved');
    var Report := TFile.ReadAllText(Settings.SystemFileName[sfExportErrorLog], TEncoding.UTF8);
    Require(Report.Contains('WarningEPUB'), 'Saved export report lacks its book context');
    var WarningLines := TStringList.Create;
    try
      WarningLines.Text := Capture.Warnings.Text;
      for var Text in WarningLines do
        if Text.Trim <> '' then Require(Report.Contains(Text.Trim),
          'Saved export report does not contain the complete warning: ' + Text.Trim);
    finally WarningLines.Free; end;
    RequireSourcesAndData;
    Writeln('PASS native conversion warnings use the progress journal, complete saved report and one final summary');

    Target := OutputFolder('shell-filesystem');
    RunExport(MtpFB2, emEpub, True, Target, True);
    BBERequireReadableBook(TPath.Combine(Target, 'ShellFB2.epub'), TPath.Combine(FixtureRoot, 'source.fb2'));
    PreviousHash := BBEFileHash(TPath.Combine(Target, 'ShellFB2.epub'));
    RunExport(MtpFB2, emEpub, True, Target, True);
    Require(BBEFileHash(TPath.Combine(Target, 'ShellFB2.epub')) = PreviousHash,
      'Shell collision replaced an existing book');
    var ShellFiles := TDirectory.GetFiles(Target, '*.epub');
    Require(Length(ShellFiles) = 2, 'Shell did not create a distinct name on collision');
    for var FileName in ShellFiles do
      BBERequireReadableBook(FileName, TPath.Combine(FixtureRoot, 'source.fb2'));
    RunExport(MtpEpub, emFB2, True, Target, True);
    BBERequireReadableBook(TPath.Combine(Target, 'ShellEPUB.fb2'), TPath.Combine(FixtureRoot, 'source.epub'));
    RequireSourcesAndData;
    Writeln('PASS MTP export branch marshals its destination, converts both directions, retains collision files and cleans staging using a filesystem Shell fixture; no hardware MTP claim');

    BBECheckProgressUI(ArtifactRoot);
    RequireSourcesAndData;
    Writeln('PASS all native book-export sources, reader settings, notes, history and collection user metadata remain unchanged');
    Writeln('TRACE native export artifacts: ', ArtifactRoot);
  finally
    Capture.Free;
    Settings.FileNameTemplate := SavedFileTemplate; Settings.FolderTemplate := SavedFolderTemplate;
    Settings.TempDir := SavedTempDir; Settings.ReadDir := SavedReadDir;
    Settings.OverwriteFB2Info := SavedOverwrite;
    Settings.ConvertWebPToPNG := SavedWebP;
  end;
end;
