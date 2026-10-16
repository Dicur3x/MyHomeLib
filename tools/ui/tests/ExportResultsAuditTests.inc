// Actual Main -> modal form -> production worker -> guarded mark application.
// All files and rows belong to this process's isolated G: runtime.
type
  TExportResultsProbe = class
  public
    SavedModal, SavedShow: TNotifyEvent;
    SavedProgress: unit_Events.TProgressEvent;
    SavedClose: unit_Events.TProgressCloseEvent;
    Worker: TExportToDeviceThread;
    Results: TBookExportResults;
    Messages: TStringList;
    Seen, CancelBefore, CancelAfterFirst, ReplaceAfterSuccess, Replaced: Boolean;
    ReplacementID: Integer;
    OriginalLibID: string;
    procedure ModalBegin(Sender: TObject);
    procedure Shown(Sender: TObject);
    procedure Progress(Percent: Integer);
    procedure Finished;
    function Message(const Text: string; Flags: Longint): Integer;
  end;

procedure TExportResultsProbe.ModalBegin(Sender: TObject);
begin
  if Assigned(SavedModal) then SavedModal(Sender);
  for var I := 0 to Screen.FormCount - 1 do
    if (Screen.Forms[I] is TExportToDeviceProgressForm) and
      (TExportToDeviceProgressForm(Screen.Forms[I]).WorkerThread is TExportToDeviceThread) then
    begin
      Require(not Seen, 'Export results gate unexpectedly opened a second worker');
      Seen := True;
      Worker := TExportToDeviceThread(TExportToDeviceProgressForm(Screen.Forms[I]).WorkerThread);
      Require(Worker.Suspended, 'Export results modal observation arrived after worker start');
      Require(Length(Worker.BookIdList) = 3, 'Actual Main snapshot included a hidden marked book');
      for var Book in Worker.BookIdList do
        Require(Book.HasExpectedIdentity and (Book.ExpectedPhysicalIdentity <> ''),
          'Actual Main omitted identity from its export snapshot');
      SavedShow := Screen.Forms[I].OnShow;
      Screen.Forms[I].OnShow := Shown;
      Exit;
    end;
end;

type
  TSearchProposalVisualClose = class
    Done: Boolean;
    procedure Close(Sender: TObject);
  end;

procedure TSearchProposalVisualClose.Close(Sender: TObject);
begin Done := True; end;

procedure TestMainSearchProposalsVisual(const Collection: IBookCollection);
var CloseProbe: TSearchProposalVisualClose; Button: TButton;
  SavedTheme, SavedAppCheck, SavedCatalogCheck: Boolean; Started: UInt64;
begin
  RequireIsolatedRegression;
  AddBook(Collection, 'Visual I LIKE SQL 100% _ "кавычки" ё', 'Visual search', 'ru', '', '0.1');
  AddBook(Collection, 'Visual обычная книга', 'Visual search', 'ru', '', '0.1');
  SavedTheme := MHLThemeDark; SavedAppCheck := Settings.CheckUpdate;
  SavedCatalogCheck := Settings.CheckExternalLibUpdate;
  Settings.CheckUpdate := False; Settings.CheckExternalLibUpdate := False;
  CloseProbe := TSearchProposalVisualClose.Create; Button := nil;
  try
    Button := TButton.Create(frmMain); Button.Parent := frmMain;
    Button.Name := 'FinishSearchVisualInspection'; Button.Align := alBottom;
    Button.Height := 32; Button.Caption := 'Завершить осмотр этого оформления';
    Button.OnClick := CloseProbe.Close;
    for var Dark in TArray<Boolean>.Create(False, True) do
    begin
      CloseProbe.Done := False;
      SetMHLTheme(Dark); frmMain.Hide; frmMain.WindowState := wsNormal;
      if Dark then frmMain.ScaleForPPI(192) else frmMain.ScaleForPPI(96);
      frmMain.Width := Min(MulDiv(1150, frmMain.Font.PixelsPerInch, 96), Screen.WorkAreaWidth - 60);
      frmMain.Height := Min(MulDiv(850, frmMain.Font.PixelsPerInch, 96), Screen.WorkAreaHeight - 60);
      frmMain.Left := Screen.WorkAreaLeft + 30; frmMain.Top := Screen.WorkAreaTop + 20;
      ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False); frmMain.edFTitle.Text := 'LIKE';
      frmMain.Show; frmMain.DoApplyFilter(nil); Application.ProcessMessages;
      Writeln('VISUAL Main search proposals dark=', Ord(Dark), ' VCL_PPI=', frmMain.Font.PixelsPerInch,
        ' real search; finish with the bottom inspection button'); Flush(Output);
      Started := GetTickCount64;
      while not CloseProbe.Done and frmMain.Visible and (GetTickCount64 - Started < 900000) do
      begin Application.ProcessMessages; CheckSynchronize(0); Sleep(10); end;
      Require(CloseProbe.Done, 'Main search visual inspection was not explicitly completed');
      frmMain.Hide;
    end;
    Writeln('PASS Main search proposals visual fixtures explicitly inspected in both themes'); Flush(Output);
  finally
    Button.Free; CloseProbe.Free; SetMHLTheme(SavedTheme);
    Settings.CheckUpdate := SavedAppCheck; Settings.CheckExternalLibUpdate := SavedCatalogCheck;
  end;
end;

procedure TExportResultsProbe.Shown(Sender: TObject);
begin
  if CancelBefore then Worker.Canceled := True;
  if Assigned(SavedShow) then SavedShow(Sender);
  // The worker is blocked in its initial Synchronize until this event returns.
  SavedProgress := Worker.OnProgress;
  SavedClose := Worker.OnCloseProgress;
  Worker.OnProgress := Progress;
  Worker.OnCloseProgress := Finished;
  Worker.OnShowMessage := Message;
end;

procedure TExportResultsProbe.Progress(Percent: Integer);
var Node: PVirtualNode; Book: PBookRecord;
begin
  if Assigned(SavedProgress) then SavedProgress(Percent);
  // This callback runs inside the worker's Synchronize: its result array is
  // stable while the UI inspects it and requests an ordinary cancellation.
  if CancelAfterFirst and (SuccessfulBookExportCount(Worker.Results) = 1) then Worker.Cancel;
  if ReplaceAfterSuccess and not Replaced and (Percent = 100) then
  begin
    Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Book := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Book) and (Book^.BookKey.BookID = ReplacementID) then
      begin
        OriginalLibID := Book^.LibID;
        Book^.LibID := 'replacement-must-retain-mark';
        Replaced := True;
        Break;
      end;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
  end;
end;

procedure TExportResultsProbe.Finished;
begin
  Results := Worker.Results;
  if Assigned(SavedClose) then SavedClose;
end;

function TExportResultsProbe.Message(const Text: string; Flags: Longint): Integer;
begin
  Messages.Add(Text);
  if (Flags and $F) = MB_YESNO then Result := IDYES else Result := IDOK;
end;

procedure TestExportResultsAudit;
var Root, Destination, SourceA, SourceB, SourceC, SourceD: string;
  HashA, HashB, HashC, HashD, SavedDevice, SavedFolder, SavedFile: string;
  CID, PreviousCID, A, B, C, Hidden, ScriptIndex, Count, Kept: Integer;
  Collection: IBookCollection; Book: TBookRecord;
  Menu, ExportItem: TMenuItem; Probe: TExportResultsProbe;
  SavedPrompt, SavedOverwrite, SavedSelected: Boolean; SavedMode: TExportMode;
  Node: PVirtualNode; Row: PBookRecord;
  Plan: TBookExportScriptPlan;

  function RegisterBook(const Title, FileName: string): Integer;
  begin
    Book.Clear; Book.Title := Title; Book.FileName := FileName; Book.FileExt := '.txt';
    Book.LibID := TGUID.NewGuid.ToString; Book.Lang := 'ru'; Book.Size := 100;
    Book.Date := EncodeDate(2026, 10, 16);
    TAuthorsHelper.Add(Book.Authors, 'Result fixture', 'Own', '');
    TGenresHelper.Add(Book.Genres, '', '', 'prose_contemporary');
    Include(Book.BookProps, bpIsLocal);
    Result := Collection.InsertBook(Book, False, False);
    Require(Result > 0, 'Cannot insert the owned export result fixture');
  end;

  procedure SelectBooks;
  var All: TToolButton; Author: PVirtualNode;
  begin
    ShowPage(PAGE_AUTHORS); All := nil;
    for var I := 0 to frmMain.tbarAuthorsRus.ButtonCount - 1 do
      if frmMain.tbarAuthorsRus.Buttons[I].Caption = '*' then All := frmMain.tbarAuthorsRus.Buttons[I];
    Require(Assigned(All) and Assigned(All.OnClick), 'Actual Main all-authors action is missing');
    All.OnClick(All); Author := frmMain.tvAuthors.GetFirst;
    Require(Assigned(Author), 'Export result fixture author is not visible');
    frmMain.tvAuthors.FocusedNode := Author; frmMain.tvAuthorsChange(frmMain.tvAuthors, Author);
    frmMain.tvBooksA.ClearSelection;
    Count := 0; Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Row := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Row) and (Row^.NodeType = ntBookInfo) then
      begin
        frmMain.tvBooksA.CheckState[Node] := csCheckedNormal;
        frmMain.tvBooksA.IsFiltered[Node] := Row^.BookKey.BookID = Hidden;
        Inc(Count);
      end;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
    Require(Count = 4, 'Export result fixture lost one of its four ordinary rows');
  end;

  procedure CheckSourceHashes;
  begin
    Require((THashSHA2.GetHashStringFromFile(SourceA) = HashA) and
      (THashSHA2.GetHashStringFromFile(SourceC) = HashC) and
      (THashSHA2.GetHashStringFromFile(SourceD) = HashD), 'Export result gate changed a source');
    if HashB = '' then Require(not FileExists(SourceB), 'Export unexpectedly created the missing source')
    else Require(THashSHA2.GetHashStringFromFile(SourceB) = HashB, 'Export changed source B');
  end;

  procedure CheckMarks(External: Boolean);
  var Expected: TCheckState; Found: Integer;
  begin
    Kept := 0; Found := 0; Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Row := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Row) and (Row^.NodeType = ntBookInfo) then
      begin
        Expected := csCheckedNormal;
        if not External then
          for var Item in Probe.Results do
            if Item.Book.BookKey.IsSameAs(Row^.BookKey) and (Item.State = besSucceeded) and
              (Item.Book.ExpectedLibID = Row^.LibID) then Expected := csUncheckedNormal;
        Require(frmMain.tvBooksA.CheckState[Node] = Expected,
          'Actual Main removed an unfinished/foreign mark or retained a completed ordinary export');
        if Expected = csCheckedNormal then Inc(Kept);
        Inc(Found);
      end;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
    Require(Found = 4, 'Export completion changed its row set');
    CheckSourceHashes;
  end;

  procedure Run(const Name: string; CancelBefore, CancelAfter, Replace, External: Boolean;
    ExpectedFiles, ExpectedSuccesses: Integer);
  var OutputFiles: TArray<string>;
  begin
    SelectBooks; Destination := TPath.Combine(Root, Name); ForceDirectories(Destination);
    Settings.DeviceDir := Destination;
    Probe.Seen := False; Probe.Results := nil; Probe.Messages.Clear;
    Probe.CancelBefore := CancelBefore; Probe.CancelAfterFirst := CancelAfter;
    Probe.ReplaceAfterSuccess := Replace; Probe.Replaced := False; Probe.ReplacementID := A;
    ExportItem.Tag := 900;
    if External then ExportItem.Tag := 901 + ScriptIndex;
    frmMain.SendToDeviceExecute(ExportItem);
    Probe.Worker := nil;
    Require(Probe.Seen and (Length(Probe.Results) = 3), 'Actual Main export did not return its per-book results');
    OutputFiles := TDirectory.GetFiles(Destination, '*', TSearchOption.soAllDirectories);
    Require(Length(OutputFiles) = ExpectedFiles, 'Export result scenario wrote an unexpected number of files');
    Require(SuccessfulBookExportCount(Probe.Results) = ExpectedSuccesses, 'Per-book successes disagree with actual output');
    for var Item in Probe.Results do
      if Item.State = besSucceeded then
      begin
        Require(FileExists(Item.OutputFile), 'Acknowledged export output does not exist');
        Collection.GetBookRecord(Item.Book.BookKey, Book, True);
        Require(THashSHA2.GetHashStringFromFile(Item.OutputFile) =
          THashSHA2.GetHashStringFromFile(Book.GetBookFileName), 'Acknowledged ordinary export changed its bytes');
      end;
    if External then
    begin
      Require(not AllBooksPreparedForScript(Probe.Results), 'Incomplete preparation was reported as a complete script batch');
      Require(string(frmMain.spStatus.Caption).Contains('Инструмент не запущен'), 'Main did not explain that the failed script preparation was retained');
      Require(Settings.Scripts[ScriptIndex].TMPParams = '', 'Incomplete preparation retained stale substituted arguments');
    end;
    if Replace then Require(Probe.Replaced, 'Export result race did not replace a row before mark application');
    CheckMarks(External);
    if Replace then
    begin
      Node := frmMain.tvBooksA.GetFirst;
      while Assigned(Node) do
      begin
        Row := frmMain.tvBooksA.GetNodeData(Node);
        if Assigned(Row) and (Row^.BookKey.BookID = A) then Row^.LibID := Probe.OriginalLibID;
        Node := frmMain.tvBooksA.GetNext(Node);
      end;
    end;
    Writeln('PASS export results Main ', Name, ' files=', Length(OutputFiles),
      ' succeeded=', SuccessfulBookExportCount(Probe.Results), ' retained_marks=', Kept);
    Flush(Output);
  end;

begin
  RequireIsolatedRegression;
  Require(ExpandFileName(Settings.AppPath).StartsWith('G:\', True), 'Export results must use the owned G fixture');
  Plan := PrepareBookExportScript('tool.exe', '--book "%FILENAME%" %FOLDER G:\Own ё% %NFT%',
    'G:\Default', 'G:\Temp\', 'original');
  Require((Plan.Destination = 'G:\Own ё') and (Plan.FolderTemplate = '') and
    Plan.Parameters.Contains('--book "%FILENAME%"') and not Plan.Parameters.Contains('%FOLDER'),
    'Export plan did not isolate the folder token after another placeholder');
  try
    PrepareBookExportScript('%COPY%', '%FOLDER broken', 'G:\Default', 'G:\Temp\', 'original');
    Require(False, 'Export plan silently accepted a missing closing folder delimiter');
  except on E: EArgumentException do ; end;
  Require((ResolveBookExportMode(854, emFB2, False) = emEpub) and
    (ResolveBookExportMode(900, emTxt, False) = emFB2) and
    (ResolveBookExportMode(900, emTxt, True) = emTxt), 'Extracted export format rules changed');
  Writeln('PASS export results independent plan validates folder tokens and preserves explicit/default format rules');

  Root := IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath, 'export-results-' + TGUID.NewGuid.ToString));
  ForceDirectories(Root);
  CID := SystemDB.CreateCollection('Export results audit', Root, TPath.Combine(Root, 'catalog.hlc2'),
    CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID);
  SourceA := Root + 'file-a.txt'; SourceB := Root + 'file-b.txt';
  SourceC := Root + 'file-c.txt'; SourceD := Root + 'file-hidden.txt';
  TFile.WriteAllText(SourceA, 'ORIGINAL_A ё ї ў', TEncoding.UTF8);
  TFile.WriteAllText(SourceC, 'ORIGINAL_C ё ї ў', TEncoding.UTF8);
  TFile.WriteAllText(SourceD, 'HIDDEN_ORIGINAL ё', TEncoding.UTF8);
  HashA := THashSHA2.GetHashStringFromFile(SourceA); HashC := THashSHA2.GetHashStringFromFile(SourceC);
  HashD := THashSHA2.GetHashStringFromFile(SourceD);
  A := RegisterBook('A success', 'file-a'); B := RegisterBook('B missing', 'file-b');
  C := RegisterBook('C success', 'file-c'); Hidden := RegisterBook('D hidden', 'file-hidden');
  PreviousCID := Settings.ActiveCollection; SavedDevice := Settings.DeviceDir;
  SavedFolder := Settings.FolderTemplate; SavedFile := Settings.FileNameTemplate;
  SavedPrompt := Settings.PromptDevicePath; SavedOverwrite := Settings.OverwriteFB2Info;
  SavedSelected := Settings.SelectedIsChecked; SavedMode := Settings.ExportMode;
  Menu := TMenuItem.Create(nil); ExportItem := TMenuItem.Create(nil); Probe := TExportResultsProbe.Create;
  Probe.Messages := TStringList.Create; Probe.SavedModal := Application.OnModalBegin;
  ScriptIndex := Settings.Scripts.Count;
  try
    Settings.Scripts.Add('Never launch on incomplete preparation', Root + 'missing-tool.exe', '%NFT% "%FILENAME%"');
    Settings.PromptDevicePath := False; Settings.OverwriteFB2Info := False;
    Settings.SelectedIsChecked := False; Settings.ExportMode := emFB2;
    Settings.FolderTemplate := ''; Settings.FileNameTemplate := '%t';
    Menu.Tag := CID; frmMain.miActiveCollectionClick(Menu);
    Application.OnModalBegin := Probe.ModalBegin;
    Run('partial-failure', False, False, False, False, 2, 2);
    Require(Probe.Messages.Text.Contains('не удалось экспортировать'), 'Partial export did not report its failed book');
    Run('external-preparation-failure', False, False, False, True, 0, 0);
    TFile.WriteAllText(SourceB, 'ORIGINAL_B ё', TEncoding.UTF8);
    HashB := THashSHA2.GetHashStringFromFile(SourceB);
    Run('cancel-after-first', False, True, False, False, 1, 1);
    Run('cancel-before-start', True, False, False, False, 0, 0);
    Run('complete', False, False, False, False, 3, 3);
    Run('replaced-after-copy', False, False, True, False, 3, 3);
    Writeln('PASS export results all six actual Main scenarios preserve sources, hidden marks and retryable selection');
  finally
    Application.OnModalBegin := Probe.SavedModal;
    while Settings.Scripts.Count > ScriptIndex do Settings.Scripts.Delete(Settings.Scripts.Count - 1);
    Probe.Messages.Free; Probe.Free; ExportItem.Free;
    Menu.Tag := PreviousCID; frmMain.miActiveCollectionClick(Menu); Menu.Free;
    Settings.DeviceDir := SavedDevice; Settings.FolderTemplate := SavedFolder;
    Settings.FileNameTemplate := SavedFile; Settings.PromptDevicePath := SavedPrompt;
    Settings.OverwriteFB2Info := SavedOverwrite; Settings.SelectedIsChecked := SavedSelected;
    Settings.ExportMode := SavedMode;
  end;
end;
