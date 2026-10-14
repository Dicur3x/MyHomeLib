// Include after GroupBookIdentityTests.inc. Exercises actual Main ordinary-row
// snapshot wiring, not a separately assembled approximation of the export keys.
// Uses the existing native harness units and only its isolated GUID G: files.

type
  TOBEIModalProbe = class
  public
    SavedModalBegin: TNotifyEvent;
    Collection: IBookCollection;
    Authorized, Replacement: TBookRecord;
    ReplaceBeforeWorker, Seen: Boolean;
    Failure: string;
    Keys: TBookIdList;
    DialogDriver: TGBIMainDriver;
    DialogHook: HHOOK;
    LastDialog: HWND;
    CapturingDialog: Boolean;
    DiagnosticPath: string;
    procedure CaptureNativeDialog(Window: HWND);
    procedure ModalBegin(Sender: TObject);
  end;

var OBEIActiveProbe: TOBEIModalProbe;

function OBEINativeDialogHook(Code: Integer; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  Result := CallNextHookEx(0, Code, WParam, LParam);
  if (Code = HCBT_ACTIVATE) and Assigned(OBEIActiveProbe) then
    try
      OBEIActiveProbe.CaptureNativeDialog(HWND(WParam));
    except
      on E: Exception do OBEIActiveProbe.Failure := 'Native dialog probe: ' + E.ClassName + ': ' + E.Message;
    end;
end;

procedure TOBEIModalProbe.CaptureNativeDialog(Window: HWND);
var ClassName: array[0..255] of Char; PID: DWORD;
  Parts: TStringList; Text, Diagnostic: string; ResultID: Integer;
begin
  PID := 0; GetWindowThreadProcessId(Window, @PID);
  if (PID <> GetCurrentProcessId) or (Window = LastDialog) or
    (GetClassName(Window, ClassName, Length(ClassName)) = 0) or
    (string(PChar(@ClassName[0])) <> '#32770') or CapturingDialog then Exit;
  LastDialog := Window;
  CapturingDialog := True;
  Parts := TStringList.Create;
  try
    EnumChildWindows(Window, @GBINativeChildText, LPARAM(Pointer(Parts)));
    Text := Parts.Text;
    Diagnostic := Format('TRACE ordinary native dialog before closure thread=%d timerEnabled=%d timerInterval=%d OK=%d Cancel=%d text=%s',
      [GetCurrentThreadId, Ord(DialogDriver.Timer.Enabled), DialogDriver.Timer.Interval,
       Ord(GetDlgItem(Window, IDOK) <> 0), Ord(GetDlgItem(Window, IDCANCEL) <> 0), Copy(Text, 1, 6000)]);
    Writeln(Diagnostic); Flush(Output);
    // Capture owns this native notification. Do not let the generic timer
    // handler reenter its message loop or dismiss an unexpected native alert.
    DialogDriver.Timer.Enabled := False;
    TFile.AppendAllText(DiagnosticPath, Diagnostic + sLineBreak, TEncoding.UTF8);
    if ReplaceBeforeWorker and Text.Contains('Книга из группы больше не совпадает с каталогом. ' +
      'Её запись и заметки сохранены; экспорт пропущен.') and
      (GetDlgItem(Window, IDOK) <> 0) and (GetDlgItem(Window, IDCANCEL) = 0) then
    begin
      DialogDriver.Messages.Add(Text);
      ResultID := IDOK;
    end
    else
    begin
      DialogDriver.Unexpected.Add('Unexpected ordinary native dialog: ' + Text);
      Exit;
    end;
    // The dialog is activating inside Application.MessageBox's own message
    // loop. Queue its ordinary button command, without waiting for WM_TIMER
    // dispatch inside a nested TThread.Synchronize callback.
    Require(PostMessage(GetDlgItem(Window, ResultID), BM_CLICK, 0, 0),
      'Cannot post the ordinary fixture native dialog button command');
  finally Parts.Free; CapturingDialog := False; end;
end;

procedure TOBEIModalProbe.ModalBegin(Sender: TObject);
begin
  if Assigned(SavedModalBegin) then SavedModalBegin(Sender);
  if Seen then Exit;
  for var I := 0 to Screen.FormCount - 1 do
    if (Screen.Forms[I] is TExportToDeviceProgressForm) and
      (TExportToDeviceProgressForm(Screen.Forms[I]).WorkerThread is TExportToDeviceThread) then
    begin
      Seen := True;
      try
        Writeln('TRACE ordinary modal snapshot before worker Start'); Flush(Output);
        var Worker := TExportToDeviceThread(TExportToDeviceProgressForm(Screen.Forms[I]).WorkerThread);
        Require(Worker.Suspended and not Worker.Finished,
          'Ordinary modal snapshot hook ran after the actual export worker started');
        Keys := Worker.BookIdList;
        Keys := Copy(Keys, 0, Length(Keys));
        Require((Length(Keys) = 1) and Keys[0].BookKey.IsSameAs(Authorized.BookKey) and
          Keys[0].HasExpectedIdentity and (Keys[0].ExpectedLibID = Authorized.LibID) and
          (Keys[0].ExpectedPhysicalIdentity = ReaderBookPhysicalIdentity(Authorized)),
          'Actual Main ordinary export worker did not receive its complete selection identity snapshot');
        if ReplaceBeforeWorker then
        begin
          Collection.BeginBulkOperation;
          try
            Collection.TruncateTablesBeforeImport;
            Require(Collection.InsertBook(Replacement, False, False) = Authorized.BookKey.BookID,
              'Ordinary selection race did not reuse the catalog ID');
            Collection.EndBulkOperation(True);
          except Collection.EndBulkOperation(False); raise; end;
          Writeln('TRACE ordinary full reimport committed before worker Start'); Flush(Output);
        end;
      except
        on E: Exception do Failure := E.ClassName + ': ' + E.Message;
      end;
      Exit;
    end;
end;

procedure TestOrdinaryBookExportIdentity;
var Root, SourceA, SourceB, HashA, HashB, Destination: string;
  CID, ID, PreviousCID: Integer; Collection: IBookCollection;
  A, B, Stored, Personal: TBookRecord;
  Node, AuthorNode: PVirtualNode; Row: PBookRecord;
  Menu, ExportItem: TMenuItem; Probe: TOBEIModalProbe;
  DialogDriver: TGBIMainDriver;
  OldDevice, OldFileTemplate, OldFolderTemplate: string;
  OldPrompt, OldOverwrite, OldSelectedIsChecked: Boolean;
  OldLatestCommonDialogs: Boolean;

  procedure SelectOrdinaryA;
  var AllButton: TToolButton;
  begin
    ShowPage(PAGE_AUTHORS);
    AllButton := nil;
    for var I := 0 to frmMain.tbarAuthorsRus.ButtonCount - 1 do
      if frmMain.tbarAuthorsRus.Buttons[I].Caption = '*' then
      begin AllButton := frmMain.tbarAuthorsRus.Buttons[I]; Break; end;
    Require(Assigned(AllButton) and Assigned(AllButton.OnClick),
      'Ordinary export fixture has no real Main all-author action');
    // Use the actual toolbar event so a persisted initial letter never hides
    // this fixture's author. No Main search/filter internals are bypassed.
    AllButton.OnClick(AllButton);
    AuthorNode := frmMain.tvAuthors.GetFirst;
    Require(Assigned(AuthorNode), 'Ordinary export fixture has no author');
    frmMain.tvAuthors.FocusedNode := AuthorNode;
    frmMain.tvAuthorsChange(frmMain.tvAuthors, AuthorNode);
    Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Row := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Row) and (Row^.NodeType = ntBookInfo) and Row^.BookKey.IsSameAs(A.BookKey) then Break;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
    Require(Assigned(Node) and (Row^.Title = A.Title), 'Ordinary export fixture cannot select original A');
    frmMain.tvBooksA.ClearSelection;
    frmMain.tvBooksA.Selected[Node] := True; frmMain.tvBooksA.FocusedNode := Node;
    frmMain.tvBooksA.CheckState[Node] := csCheckedNormal;
  end;

  procedure CheckProtected;
  begin
    Require((THashSHA2.GetHashStringFromFile(SourceA) = HashA) and
      (THashSHA2.GetHashStringFromFile(SourceB) = HashB), 'Ordinary export race changed source bytes');
    SystemDB.GetBookRecord(A.BookKey, Personal);
    Require((Personal.Title = A.Title) and (Personal.LibID = A.LibID) and
      (Personal.FileName = A.FileName) and (Personal.Date = A.Date) and
      (Personal.Rate = A.Rate) and (Personal.Progress = A.Progress) and
      (Personal.Review = A.Review) and (Personal.Annotation = A.Annotation),
      'Ordinary export race changed the saved original personal card');
    Collection.GetBookRecord(A.BookKey, Stored, True);
    if Probe.ReplaceBeforeWorker then
      Require((Stored.Title = B.Title) and (Stored.FileName = B.FileName) and
        (Stored.LibID = B.LibID) and (Stored.Date = B.Date) and
        (Stored.Rate = B.Rate) and (Stored.Progress = B.Progress) and
        (Stored.Review = B.Review) and (Stored.Annotation = B.Annotation),
        'Rejected ordinary export changed the reused foreign catalog row')
    else
      Require((Stored.Title = A.Title) and (Stored.FileName = A.FileName) and
        (Stored.Rate = A.Rate) and (Stored.Progress = A.Progress),
        'Positive ordinary export changed the authorized catalog row');
  end;

  procedure ExportOrdinary(const Name: string; ReplaceBeforeWorker: Boolean);
  var Files: TArray<string>; TimerWasEnabled: Boolean;
  begin
    Writeln('TRACE ordinary export ', Name, ' selecting'); Flush(Output);
    SelectOrdinaryA;
    Destination := TPath.Combine(Root, Name); ForceDirectories(Destination);
    Settings.DeviceDir := Destination;
    Probe.Seen := False; Probe.Failure := ''; Probe.ReplaceBeforeWorker := ReplaceBeforeWorker;
    Probe.Keys := nil;
    DialogDriver.Messages.Clear; DialogDriver.Unexpected.Clear;
    Probe.LastDialog := 0;
    Probe.DiagnosticPath := TPath.Combine(Root, Name + '-native-dialog-trace.txt');
    Writeln('TRACE ordinary dialog driver enabled=', Ord(DialogDriver.Timer.Enabled),
      ' interval=', DialogDriver.Timer.Interval, ' thread=', GetCurrentThreadId); Flush(Output);
    Writeln('TRACE ordinary export ', Name, ' invoking actual Main action'); Flush(Output);
    Require(not Assigned(OBEIActiveProbe), 'An ordinary native dialog probe is already active');
    TimerWasEnabled := DialogDriver.Timer.Enabled;
    OBEIActiveProbe := Probe;
    Probe.DialogHook := SetWindowsHookEx(WH_CBT, @OBEINativeDialogHook, 0, GetCurrentThreadId);
    try
      Require(Probe.DialogHook <> 0, 'Cannot install the current-thread ordinary native dialog probe');
      frmMain.SendToDeviceExecute(ExportItem);
    finally
      if Probe.DialogHook <> 0 then UnhookWindowsHookEx(Probe.DialogHook);
      Probe.DialogHook := 0; OBEIActiveProbe := nil;
      DialogDriver.Timer.Enabled := TimerWasEnabled;
    end;
    Writeln('TRACE ordinary export ', Name, ' actual Main action returned'); Flush(Output);
    TFile.WriteAllText(TPath.Combine(Root, Name + '-dialog-diagnostics.txt'),
      'Messages:' + sLineBreak + Copy(DialogDriver.Messages.Text, 1, 6000) + sLineBreak +
      'Unexpected:' + sLineBreak + Copy(DialogDriver.Unexpected.Text, 1, 6000), TEncoding.UTF8);
    Require(DialogDriver.Unexpected.Count = 0,
      'Unexpected ordinary export dialog: ' + Copy(DialogDriver.Unexpected.Text, 1, 3000));
    Require(Probe.Seen and (Probe.Failure = ''),
      'Actual Main ordinary export modal snapshot gate failed: ' + Probe.Failure);
    Files := TDirectory.GetFiles(Destination, '*', TSearchOption.soAllDirectories);
    if ReplaceBeforeWorker then
    begin
      Require(Length(Files) = 0, 'Actual Main ordinary selection exported foreign B after positive ID reuse');
      Require(DialogDriver.HasMessage('больше не совпадает с каталогом'),
        'Actual Main ordinary worker identity rejection did not explain its failed export');
    end
    else
      Require((Length(Files) = 1) and (THashSHA2.GetHashStringFromFile(Files[0]) = HashA),
        'Actual Main positively proven ordinary export lost or changed its original bytes');
    CheckProtected;
    Writeln('PASS ordinary Main export identity ', Name,
      ' actual worker snapshot verified; original/user marks retained; copied=', Length(Files)); Flush(Output);
  end;

begin
  RequireIsolatedRegression;
  Require(ExpandFileName(Settings.AppPath).StartsWith('G:\', True),
    'Ordinary export identity fixture must remain on its isolated G: runtime');
  Root := IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,
    'ordinary-export-identity-' + TGUID.NewGuid.ToString)); ForceDirectories(Root);
  CID := SystemDB.CreateCollection('Ordinary export identity', Root,
    TPath.Combine(Root, 'catalog.hlc2'), CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID); Collection.SetProperty(PROP_SOURCE_LIBRARY, '');
  SourceA := TPath.Combine(Root, 'ordinary-A.fb2'); SourceB := TPath.Combine(Root, 'ordinary-B.fb2');
  var Description := '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description>' +
    '<title-info><genre>prose_contemporary</genre><author><first-name>Own</first-name><last-name>Ordinary</last-name>' +
    '</author><book-title>Own fixture</book-title><lang>ru</lang></title-info>' +
    '<document-info><author><nickname>Native fixture</nickname></author><date value="2026-10-13">2026-10-13</date>' +
    '<id>ordinary-fixture</id><version>1.0</version></document-info></description><body><section><p>';
  TFile.WriteAllText(SourceA, Description + 'ORDINARY_ORIGINAL_A ё, ї, ў</p></section></body></FictionBook>', TEncoding.UTF8);
  TFile.WriteAllText(SourceB, Description + 'ORDINARY_FOREIGN_B ё, ї, ў</p></section></body></FictionBook>', TEncoding.UTF8);
  HashA := THashSHA2.GetHashStringFromFile(SourceA); HashB := THashSHA2.GetHashStringFromFile(SourceB);
  A.Clear; A.Title := 'Ordinary original A'; A.FileName := 'ordinary-A'; A.FileExt := '.fb2';
  A.LibID := '42'; A.Date := EncodeDate(2026, 10, 13); A.Lang := 'ru';
  A.Rate := 4; A.Progress := 37; A.Review := 'Original ordinary review'; A.Annotation := 'Original ordinary annotation';
  Include(A.BookProps, bpIsLocal);
  TAuthorsHelper.Add(A.Authors, 'Ordinary', 'Own', ''); TGenresHelper.Add(A.Genres, '', '', 'prose_contemporary');
  ID := Collection.InsertBook(A, False, False); Require(ID = 1, 'Fresh ordinary fixture did not allocate ID1');
  Collection.GetBookRecord(CreateBookKey(ID, CID), A, True);
  Collection.AddBookToGroup(A.BookKey, FAVORITES_GROUP_ID);
  B := A; B.Title := 'Ordinary foreign B'; B.FileName := 'ordinary-B'; B.Date := EncodeDate(2025, 1, 7);
  B.Rate := 2; B.Progress := 7; B.Review := 'Foreign ordinary review'; B.Annotation := 'Foreign ordinary annotation';
  PreviousCID := Settings.ActiveCollection;
  OldDevice := Settings.DeviceDir; OldPrompt := Settings.PromptDevicePath;
  OldFileTemplate := Settings.FileNameTemplate; OldFolderTemplate := Settings.FolderTemplate;
  OldOverwrite := Settings.OverwriteFB2Info; OldSelectedIsChecked := Settings.SelectedIsChecked;
  OldLatestCommonDialogs := Vcl.Dialogs.UseLatestCommonDialogs;
  Menu := TMenuItem.Create(nil); ExportItem := TMenuItem.Create(nil); Probe := TOBEIModalProbe.Create;
  Probe.SavedModalBegin := Application.OnModalBegin;
  DialogDriver := TGBIMainDriver.Create;
  Probe.DialogDriver := DialogDriver;
  try
    Vcl.Dialogs.UseLatestCommonDialogs := False;
    Settings.PromptDevicePath := False; Settings.OverwriteFB2Info := False;
    Settings.FileNameTemplate := '%t'; Settings.FolderTemplate := ''; Settings.SelectedIsChecked := True;
    Menu.Tag := CID; frmMain.miActiveCollectionClick(Menu); ExportItem.Tag := 850;
    Probe.Collection := Collection; Probe.Authorized := A; Probe.Replacement := B;
    Application.OnModalBegin := Probe.ModalBegin;
    ExportOrdinary('matching', False);
    ExportOrdinary('replaced-before-worker', True);
  finally
    Application.OnModalBegin := Probe.SavedModalBegin;
    DialogDriver.Free;
    Vcl.Dialogs.UseLatestCommonDialogs := OldLatestCommonDialogs;
    Probe.Free; ExportItem.Free;
    Menu.Tag := PreviousCID; frmMain.miActiveCollectionClick(Menu); Menu.Free;
    Settings.DeviceDir := OldDevice; Settings.PromptDevicePath := OldPrompt;
    Settings.FileNameTemplate := OldFileTemplate; Settings.FolderTemplate := OldFolderTemplate;
    Settings.OverwriteFB2Info := OldOverwrite; Settings.SelectedIsChecked := OldSelectedIsChecked;
  end;
end;
