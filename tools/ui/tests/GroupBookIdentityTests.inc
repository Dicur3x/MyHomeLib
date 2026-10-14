// Native Main wiring gate. Include after AddBook/ShowPage/Require.
// Uses already required by the native harness: unit_ReaderCache,
// unit_ReaderAnnotations, unit_ExportToDeviceThread, unit_WorkerThread.
// Every catalog/source/output belongs to this isolated G: runtime.

type
  TGBIBookTreeAccess = class(TBookTree);

  TGBIMainDriver = class
  private
    procedure HandleDialogs;
    procedure HandleReader;
    procedure HandleReview;
  public
    Timer: TTimer;
    Messages, Unexpected: TStringList;
    Collection: IBookCollection;
    Replacement: TBookRecord;
    ExpectedText, Failure: string;
    ExpectedReview, ExpectedAnnotation, ReviewText, AnnotationText: string;
    ReviewEditing, ReviewFinished, CorruptBeforeReviewSave: Boolean;
    ExpectReadOnly: Boolean;
    DraftRetryExpected, DraftRetrySeen: Boolean;
    ReviewAttempt: Integer;
    DraftFaultPath, DraftPreservedFolder: string;
    ForeignSystemCard: TBookRecord;
    Started: UInt64;
    LastReaderProgress: Integer;
    Reading, Finished, ReplaceDuringRead: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Tick(Sender: TObject);
    procedure BeginRead(ReplaceRow: Boolean);
    function HasMessage(const Fragment: string): Boolean;
  end;

  TGBIWorkerCapture = class
  public
    Text: TStringList;
    function Message(const Value: string; Flags: Longint): Integer;
    procedure Warning(const Value: string; Severity: TTeletypeSeverity);
  end;

function GBIComponentText(Component: TComponent): string;
begin
  Result := '';
  if Component is TLabel then Result := TLabel(Component).Caption
  else if Component is TStaticText then Result := TStaticText(Component).Caption
  else if Component is TCustomEdit then Result := TCustomEdit(Component).Text;
  for var I := 0 to Component.ComponentCount - 1 do
    Result := Result + ' ' + GBIComponentText(Component.Components[I]);
end;

function GBINativeChildText(Window: HWND; Value: LPARAM): BOOL; stdcall;
var Buffer: array[0..8191] of Char; ClassName: array[0..255] of Char;
  Count: Integer; Text: string;
begin
  Count := GetWindowText(Window, Buffer, Length(Buffer));
  if Count > 0 then
  begin
    SetString(Text, PChar(@Buffer[0]), Count);
    if Pos(#0, Text) > 0 then
    begin
      // Native icon/DirectUI controls do not necessarily expose text through
      // WM_GETTEXT. Keep bounded control metadata instead of a misleading NUL.
      GetClassName(Window, ClassName, Length(ClassName));
      Text := Format('[native nontext class=%s style=%s returned=%d unicode=%d]',
        [string(PChar(@ClassName[0])), IntToHex(GetWindowLong(Window, GWL_STYLE), 8),
         Count, Ord(IsWindowUnicode(Window))]);
    end;
    TStrings(Pointer(Value)).Add(Text);
  end;
  Result := True;
end;

function GBIKnownMessage(const Text: string): Boolean;
begin
  Result := Text.Contains('Пропущено книг из группы') or
    Text.Contains('больше не совпадает с каталогом') or
    Text.Contains('Ни одна книга не выбрана') or Text.Contains('ReviewDrafts') or
    Text.Contains('Книга больше не совпадает с сохранённой записью') or
    Text.Contains('Некоторые книги из группы больше не совпадают с каталогом. ' +
      'Записи, заметки и отметки выбора сохранены; скачивание для них пропущено.') or
    Text.Contains('Не удалось сохранить отзыв и черновик. Текст остался в редакторе.');
end;

function GBINormalizeMemoText(const Text: string): string;
begin
  // TMemo.Lines.Text appends one terminal CRLF. Compare the actual memo
  // content while retaining every internal line and all non-newline spaces.
  Result := Text.TrimRight([#13, #10]);
end;

procedure GBICloseNativeDialog(Window: HWND; ResultID: Integer);
var Button: HWND;
begin
  Button := GetDlgItem(Window, ResultID);
  if Button <> 0 then SendMessage(Button, BM_CLICK, 0, 0)
  else
  begin
    // TaskDialog buttons may be hosted by DirectUI; classic MessageBox
    // ignores this message and is handled by its normal command below.
    SendMessage(Window, WM_USER + 102, ResultID, 0); // TDM_CLICK_BUTTON
    if IsWindow(Window) and IsWindowVisible(Window) then
      SendMessage(Window, WM_COMMAND, ResultID, 0);
  end;
end;

constructor TGBIMainDriver.Create;
begin
  inherited;
  Messages := TStringList.Create;
  Unexpected := TStringList.Create;
  Timer := TTimer.Create(nil);
  Timer.Enabled := False;
  Timer.Interval := 15;
  Timer.OnTimer := Tick;
  Timer.Enabled := True;
end;

destructor TGBIMainDriver.Destroy;
begin
  Timer.Enabled := False;
  Timer.OnTimer := nil;
  Timer.Free;
  Unexpected.Free;
  Messages.Free;
  inherited;
end;

function TGBIMainDriver.HasMessage(const Fragment: string): Boolean;
begin
  Result := Messages.Text.Contains(Fragment);
end;

procedure TGBIMainDriver.HandleDialogs;
var Window, Next: HWND; PID: DWORD; ClassName: array[0..255] of Char;
  Text: string; Parts: TStringList;
begin
  // Accept only the expected informative dialogs of this private test process.
  // Unexpected editor/file/error windows are canceled and fail the gate later.
  for var I := Screen.FormCount - 1 downto 0 do
  begin
    var Form := Screen.Forms[I];
    if Form.Visible and (Form.ClassName = 'TMessageForm') then
    begin
      Text := GBIComponentText(Form);
      if GBIKnownMessage(Text) then
      begin Messages.Add(Text); Form.ModalResult := mrOk; end
      else begin Unexpected.Add('Unexpected VCL message: ' + Text); Form.ModalResult := mrCancel; end;
    end
    else if Form.Visible and Form.ClassName.StartsWith('TfrmEditBook') then
    begin
      Unexpected.Add('A mismatched saved group card opened the book editor');
      Form.ModalResult := mrCancel;
    end;
  end;
  Window := GetTopWindow(0);
  while Window <> 0 do
  begin
    Next := GetWindow(Window, GW_HWNDNEXT);
    PID := 0; GetWindowThreadProcessId(Window, @PID);
    if (PID = GetCurrentProcessId) and IsWindowVisible(Window) and
      (GetClassName(Window, ClassName, Length(ClassName)) > 0) and
      (string(PChar(@ClassName[0])) = '#32770') then
    begin
      Parts := TStringList.Create;
      try
        EnumChildWindows(Window, @GBINativeChildText, LPARAM(Pointer(Parts)));
        Text := Parts.Text;
        if GBIKnownMessage(Text) then
        begin
          Messages.Add(Text);
          GBICloseNativeDialog(Window, IDOK);
        end
        else
        begin
          Unexpected.Add('Unexpected native dialog: ' + Text);
          GBICloseNativeDialog(Window, IDCANCEL);
        end;
      finally Parts.Free; end;
    end;
    Window := Next;
  end;
end;

procedure TGBIMainDriver.HandleReview;
begin
  if not ReviewEditing then Exit;
  for var I := 0 to Screen.FormCount - 1 do
    if (Screen.Forms[I] is TfrmBookDetails) and Screen.Forms[I].Visible then
    begin
      var Details := TfrmBookDetails(Screen.Forms[I]);
      try
        if DraftRetryExpected and (ReviewAttempt > 0) then
        begin
          Require((Details.Review = ReviewText) and (Details.Annotation = AnnotationText),
            'Draft write failure discarded the actual reopened dialog input');
          Require(FileExists(DraftFaultPath) and not DirectoryExists(DraftFaultPath),
            'Draft write failure fixture did not keep its ordinary-file blocker');
          Require(TFile.ReadAllText(DraftFaultPath, TEncoding.UTF8) = 'Private G fixture draft blocker',
            'Draft retry blocker was replaced unexpectedly');
          TFile.Delete(DraftFaultPath);
          if DirectoryExists(DraftPreservedFolder) then
            TDirectory.Move(DraftPreservedFolder, DraftFaultPath)
          else ForceDirectories(DraftFaultPath);
          DraftRetrySeen := True;
          ReviewEditing := False; ReviewFinished := True;
          Details.ModalResult := mrOk;
          Exit;
        end;
        Require(Details.mmReview.ReadOnly = ExpectReadOnly,
          'Main information review editing mode differs from its selected collection context');
        Require(GBINormalizeMemoText(Details.Review) = GBINormalizeMemoText(ExpectedReview),
          'Main information loaded a foreign catalog review into saved group A');
        Require(GBINormalizeMemoText(Details.Annotation) = GBINormalizeMemoText(ExpectedAnnotation),
          'Main information loaded a foreign catalog annotation into saved group A');
        Details.Review := ReviewText; Details.Annotation := AnnotationText; Details.ReviewChanged := True;
        ReviewText := Details.Review; AnnotationText := Details.Annotation;
        if CorruptBeforeReviewSave then SystemDB.UpdateBook(ForeignSystemCard);
        Inc(ReviewAttempt);
        ReviewEditing := DraftRetryExpected;
        ReviewFinished := not DraftRetryExpected;
        Details.ModalResult := mrOk;
      except
        on E: Exception do
        begin
          Failure := E.ClassName + ': ' + E.Message;
          ReviewEditing := False; ReviewFinished := True;
          Details.ReviewChanged := False; Details.ModalResult := mrCancel;
        end;
      end;
      Exit;
    end;
end;

procedure TGBIMainDriver.BeginRead(ReplaceRow: Boolean);
begin
  Reading := True; Finished := False; ReplaceDuringRead := ReplaceRow;
  LastReaderProgress := -1;
  Failure := ''; Started := GetTickCount64;
end;

procedure TGBIMainDriver.HandleReader;
var Reader: TfrmBuiltinReader; NewID, PreviousPosition: Integer;
begin
  if not Reading then Exit;
  for var I := 0 to Screen.FormCount - 1 do
    if Screen.Forms[I] is TfrmBuiltinReader then
    begin
      Reader := TfrmBuiltinReader(Screen.Forms[I]);
      try
        if GetTickCount64 - Started > 15000 then
          raise Exception.Create('Main group reader exceeded its private-fixture deadline');
        if not Reader.Ready then Exit;
        Require(Reader.BookText.Contains(ExpectedText), 'Main group reader opened a foreign book');
        Reader.SetBounds(80, 80, 640, 440);
        if ReplaceDuringRead then
        begin
          Collection.BeginBulkOperation;
          try
            // This is the real full-reimport table replacement path. The user
            // system-card/group remains outside the replaced catalog tables.
            Collection.TruncateTablesBeforeImport;
            NewID := Collection.InsertBook(Replacement, False, False);
            Require(NewID = Replacement.BookKey.BookID, 'Full reimport did not reuse the positive catalog ID');
            Collection.EndBulkOperation(True);
          except Collection.EndBulkOperation(False); raise; end;
        end;
        PreviousPosition := Reader.TextPosition;
        Reader.SeekProgress(0.63);
        Require((Reader.TextPosition > 0) and (Reader.TextPosition <> PreviousPosition),
          'Main group reader did not move before its save callback');
        Reader.AddBookmark;
        // This public value uses the same end-of-book rule as SaveSettings:
        // the final displayed text page saves 100%, even when its start is earlier.
        LastReaderProgress := EnsureRange(Round(Reader.ReadingProgress * 100), 0, 100);
        Reading := False; Finished := True;
        Reader.Close;
      except
        on E: Exception do
        begin
          Failure := E.ClassName + ': ' + E.Message;
          Reading := False; Finished := True;
          Reader.Close;
        end;
      end;
      Exit;
    end;
end;

procedure TGBIMainDriver.Tick(Sender: TObject);
begin
  HandleReview;
  HandleDialogs;
  HandleReader;
end;

function TGBIWorkerCapture.Message(const Value: string; Flags: Longint): Integer;
begin Text.Add(Value); if (Flags and $F) = MB_YESNO then Result := IDYES else Result := IDOK; end;

procedure TGBIWorkerCapture.Warning(const Value: string; Severity: TTeletypeSeverity);
begin Text.Add(Value); end;

type
  TGBILoopbackDownload = class
  private
    HTTP: TIdHTTPServer;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  public
    Requested, Released: TEvent;
    Payload: TBytes;
    RequestCount: Integer;
    Failure, LastDocument, URL: string;
    constructor Create(const Body: string; PauseResponse: Boolean);
    destructor Destroy; override;
  end;

constructor TGBILoopbackDownload.Create(const Body: string; PauseResponse: Boolean);
begin
  inherited Create;
  Requested := TEvent.Create(nil, True, False, '');
  Released := TEvent.Create(nil, True, not PauseResponse, '');
  Payload := TEncoding.UTF8.GetBytes(Body);
  HTTP := TIdHTTPServer.Create(nil);
  HTTP.KeepAlive := False; HTTP.MaxConnections := 1;
  HTTP.OnCommandGet := Command;
  HTTP.Bindings.Clear;
  with HTTP.Bindings.Add do begin IP := '127.0.0.1'; Port := 0; end;
  HTTP.Active := True;
  URL := Format('http://127.0.0.1:%d/', [HTTP.Bindings[0].Port]);
  Require(HTTP.Bindings[0].Port > 0, 'Download fixture did not acquire an ephemeral loopback port');
end;

destructor TGBILoopbackDownload.Destroy;
begin
  if Assigned(Released) then Released.SetEvent;
  if Assigned(HTTP) then begin HTTP.Active := False; HTTP.Free; end;
  Released.Free; Requested.Free;
  inherited;
end;

procedure TGBILoopbackDownload.Command(Context: TIdContext; Request: TIdHTTPRequestInfo;
  Response: TIdHTTPResponseInfo);
var Body: TMemoryStream;
begin
  InterlockedIncrement(RequestCount);
  LastDocument := Request.Document;
  Requested.SetEvent;
  if Released.WaitFor(15000) <> wrSignaled then
  begin
    Failure := 'Loopback response was not released before its fixture deadline';
    Response.ResponseNo := 408; Exit;
  end;
  if Request.Document <> '/payload-original-A' then
  begin
    Failure := 'Downloader requested an unexpected or foreign loopback route';
    Response.ResponseNo := 404; Exit;
  end;
  Body := TMemoryStream.Create;
  try
    if Length(Payload) > 0 then Body.WriteBuffer(Payload[0], Length(Payload));
    Body.Position := 0;
    Response.ContentType := 'application/x-fictionbook+xml';
    Response.ContentStream := Body; Response.FreeContentStream := True;
    Body := nil;
  finally Body.Free; end;
end;

type
  TGBIDownloadDialogProbe = class
  public
    Hook: HHOOK;
    UIThread: DWORD;
    LastDialog: HWND;
    Capturing, ExpectRejection: Boolean;
    DiagnosticPath, Failure: string;
    Messages, Unexpected: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Capture(Window: HWND);
  end;

var GBIActiveDownloadProbe: TGBIDownloadDialogProbe;

function GBIDownloadNativeHook(Code: Integer; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  Result:=CallNextHookEx(0,Code,WParam,LParam);
  if (Code=HCBT_ACTIVATE) and Assigned(GBIActiveDownloadProbe) then
    try GBIActiveDownloadProbe.Capture(HWND(WParam));
    except on E: Exception do
      GBIActiveDownloadProbe.Failure:=E.ClassName+': '+E.Message; end;
end;

constructor TGBIDownloadDialogProbe.Create;
begin
  inherited;
  Messages:=TStringList.Create; Unexpected:=TStringList.Create;
  UIThread:=GetCurrentThreadId;
end;

destructor TGBIDownloadDialogProbe.Destroy;
begin Unexpected.Free; Messages.Free; inherited; end;

procedure TGBIDownloadDialogProbe.Capture(Window: HWND);
var ClassName: array[0..255] of Char; PID, ThreadID: DWORD;
  Parts: TStringList; Text, Diagnostic: string; Button: HWND;
begin
  PID:=0; ThreadID:=GetWindowThreadProcessId(Window,@PID);
  if Capturing or (Window=LastDialog) or (PID<>GetCurrentProcessId) or (ThreadID<>UIThread) or
    (GetClassName(Window,ClassName,Length(ClassName))=0) or
    (string(PChar(@ClassName[0]))<>'#32770') then Exit;
  Capturing:=True; LastDialog:=Window; Parts:=TStringList.Create;
  try
    EnumChildWindows(Window,@GBINativeChildText,LPARAM(Pointer(Parts)));
    Text:=Parts.Text; Button:=GetDlgItem(Window,IDOK);
    Diagnostic:=Format('TRACE saved download native dialog before closure thread=%d OK=%d Cancel=%d text=%s',
      [ThreadID,Ord(Button<>0),Ord(GetDlgItem(Window,IDCANCEL)<>0),Copy(Text,1,6000)]);
    Writeln(Diagnostic); Flush(Output);
    TFile.AppendAllText(DiagnosticPath,Diagnostic+sLineBreak,TEncoding.UTF8);
    if ExpectRejection and Text.Contains('Книга больше не совпадает с сохранённой записью. ' +
      'Загрузка и отметка «скачано» не выполнены; добавьте нужную книгу в очередь заново.') and
      (Button<>0) and (GetDlgItem(Window,IDCANCEL)=0) then
    begin
      Messages.Add(Text);
      Require(PostMessage(Button,BM_CLICK,0,0),'Cannot post the expected native download rejection OK click');
    end
    else Unexpected.Add('Unexpected saved download native dialog: '+Text);
  finally Parts.Free; Capturing:=False; end;
end;

procedure TestSavedDownloadIdentity(const CaseName: string = '');
var OldActive: Integer; Menu: TMenuItem; QueueStream: TMemoryStream;
  OriginalAutoStart, OriginalErrorLog: Boolean; View: IDownloadView;

  procedure RunCase(const Name: string; ReplaceBefore, ReplaceDuring, LegacyQueue: Boolean;
    PostedCompletion: Boolean = False);
  var Folder, Body, PathA, PathB, ForeignHash: string; CID, ID: Integer;
    Collection: IBookCollection; A, B, Stored: TBookRecord;
    GroupNode, Node, QueueNode, CatalogNode: PVirtualNode; Group: PGroupData; Book: PBookRecord;
    Queue: PDownloadData; Item: TDownloadItem; Keys: TBookIdList;
    HTTP: TGBILoopbackDownload; Worker: TDownloadBooksThread; Downloader: TDownloader;
    DialogProbe: TGBIDownloadDialogProbe; WorkerStarted: Boolean;
    Started: UInt64;

    procedure ReplaceCatalog;
    begin
      Collection.BeginBulkOperation;
      try
        Collection.TruncateTablesBeforeImport;
        Require(Collection.InsertBook(B, False, False) = A.BookKey.BookID,
          'Download fixture full reimport did not reuse the authorized key');
        Collection.EndBulkOperation(True);
      except Collection.EndBulkOperation(False); raise; end;
    end;

    procedure CheckPersonalAndForeign;
    begin
      SystemDB.GetBookRecord(A.BookKey, Stored);
      Require((Stored.LibID = A.LibID) and (Stored.Title = A.Title) and (Stored.Date = A.Date) and
        (Stored.FileName = A.FileName) and (Stored.Rate = 4) and (Stored.Progress = 37) and
        (Stored.Review = A.Review) and (Stored.Annotation = A.Annotation),
        'Download race changed original A personal identity/marks/text');
      if ReplaceBefore or ReplaceDuring or PostedCompletion then
      begin
        Require((bpIsLocal in Stored.BookProps) = PostedCompletion,
          'Download commit outcome changed saved A local state incorrectly');
        Collection.GetBookRecord(A.BookKey, Stored, True);
        Require((Stored.Title = B.Title) and (Stored.FileName = B.FileName) and (Stored.Date = B.Date) and
          (Stored.Rate = 2) and (Stored.Progress = 7) and (Stored.Review = B.Review) and
          (Stored.Annotation = B.Annotation) and not (bpIsLocal in Stored.BookProps),
          'Download race wrote local/marks/text into replacement B');
      end
      else
      begin
        Require(bpIsLocal in Stored.BookProps, 'Matching download did not mark saved own A local');
        Collection.GetBookRecord(A.BookKey, Stored, True);
        Require((Stored.FileName = A.FileName) and (bpIsLocal in Stored.BookProps),
          'Matching download did not mark the proven source A local');
      end;
      Require(THashSHA2.GetHashStringFromFile(PathB) = ForeignHash,
        'Download identity handling overwrote the foreign B physical file');
    end;

  begin
    Require(TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount = 0,
      'Download identity fixture requires an empty isolated queue');
    Folder := IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,
      'saved-download-' + Name + '-' + TGUID.NewGuid.ToString));
    ForceDirectories(Folder);
    CID := SystemDB.CreateCollection('Saved download ' + Name, Folder,
      TPath.Combine(Folder, 'catalog.hlc2'), CT_EXTERNAL_ONLINE_FB, Settings.AppPath + 'genres_fb2.glst');
    Collection := SystemDB.GetCollection(CID);
    Collection.SetProperty(PROP_SOURCE_LIBRARY, '');
    Body := '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>' +
      'DOWNLOAD_OWN_A ё, ї, ў ' + StringOfChar('я', 2000) + '</p></section></body></FictionBook>';
    PathA := TPath.Combine(Folder, 'original-A.fb2'); PathB := TPath.Combine(Folder, 'foreign-B.fb2');
    TFile.WriteAllText(PathB, 'Foreign B source must remain exact — ё, ї, ў', TEncoding.UTF8);
    ForeignHash := THashSHA2.GetHashStringFromFile(PathB);
    A.Clear; A.Title := 'Authorized original download A ' + Name; A.FileName := 'original-A';
    A.FileExt := '.fb2'; A.LibID := '42'; A.Lang := 'ru'; A.Size := Length(TEncoding.UTF8.GetBytes(Body));
    A.Rate := 4; A.Progress := 37; A.Review := 'Own download review A'; A.Annotation := 'Own annotation A';
    TAuthorsHelper.Add(A.Authors, 'Download identity', 'Own', '');
    TGenresHelper.Add(A.Genres, '', '', 'prose_contemporary');
    ID := Collection.InsertBook(A, False, False); Require(ID = 1, 'Fresh download fixture did not allocate ID1');
    Collection.GetBookRecord(CreateBookKey(ID, CID), A, True);
    Collection.AddBookToGroup(A.BookKey, FAVORITES_GROUP_ID);
    SystemDB.GetBookRecord(A.BookKey, A);
    B := A; B.Title := 'Foreign replacement download B'; B.FileName := 'foreign-B';
    B.Date := EncodeDate(2025, 1, 7);
    B.Rate := 2; B.Progress := 7; B.Review := 'Foreign B review'; B.Annotation := 'Foreign B annotation';
    HTTP := nil; Worker := nil; Downloader := nil; DialogProbe:=nil; WorkerStarted:=False;
    try
      HTTP := TGBILoopbackDownload.Create(Body, ReplaceDuring);
      Collection.SetProperty(PROP_URL, HTTP.URL);
      Collection.SetProperty(PROP_CONNECTIONSCRIPT, 'GET %URL%payload-original-A' + sLineBreak + 'CHECK');
      Menu.Tag := CID; frmMain.miActiveCollectionClick(Menu);
      CatalogNode := nil;
      if PostedCompletion then
      begin
        ShowPage(PAGE_AUTHORS);
        var AllAuthors: TToolButton := nil;
        for var I := 0 to frmMain.tbarAuthorsRus.ButtonCount - 1 do
          if frmMain.tbarAuthorsRus.Buttons[I].Caption = '*' then
          begin AllAuthors := frmMain.tbarAuthorsRus.Buttons[I]; Break; end;
        Require(Assigned(AllAuthors) and Assigned(AllAuthors.OnClick),
          'Posted completion fixture has no real Main all-author action');
        AllAuthors.OnClick(AllAuthors);
        var AuthorNode := frmMain.tvAuthors.GetFirst;
        Require(Assigned(AuthorNode), 'Posted completion fixture has no author view');
        frmMain.tvAuthors.FocusedNode := AuthorNode;
        frmMain.tvAuthorsChange(frmMain.tvAuthors, AuthorNode);
        CatalogNode := frmMain.tvBooksA.GetFirst;
        while Assigned(CatalogNode) do
        begin
          Book := frmMain.tvBooksA.GetNodeData(CatalogNode);
          if Assigned(Book) and (Book^.NodeType = ntBookInfo) and Book^.BookKey.IsSameAs(A.BookKey) then Break;
          CatalogNode := frmMain.tvBooksA.GetNext(CatalogNode);
        end;
        Require(Assigned(CatalogNode), 'Posted completion fixture cannot locate the real catalog tree row');
      end;
      ShowPage(PAGE_FAVORITES);
      GroupNode := frmMain.tvGroups.GetFirst;
      while Assigned(GroupNode) do
      begin
        Group := frmMain.tvGroups.GetNodeData(GroupNode);
        if Assigned(Group) and (Group^.GroupID = FAVORITES_GROUP_ID) then Break;
        GroupNode := frmMain.tvGroups.GetNext(GroupNode);
      end;
      Require(Assigned(GroupNode), 'Download fixture cannot select the saved Favorites group');
      frmMain.tvGroups.FocusedNode := GroupNode; frmMain.tvGroupsChange(frmMain.tvGroups, GroupNode);
      frmMain.cbLangSelectF.ItemIndex := 0;
      if Assigned(frmMain.cbLangSelectF.OnChange) then frmMain.cbLangSelectF.OnChange(frmMain.cbLangSelectF);
      Node := frmMain.tvBooksF.GetFirst;
      while Assigned(Node) do
      begin
        Book := frmMain.tvBooksF.GetNodeData(Node);
        if Assigned(Book) and (Book^.NodeType = ntBookInfo) and Book^.BookKey.IsSameAs(A.BookKey) then Break;
        Node := frmMain.tvBooksF.GetNext(Node);
      end;
      Require(Assigned(Node), 'Download fixture saved group A is absent');
      var ClearNode := frmMain.tvBooksF.GetFirst;
      while Assigned(ClearNode) do
      begin
        frmMain.tvBooksF.CheckState[ClearNode] := csUncheckedNormal;
        ClearNode := frmMain.tvBooksF.GetNext(ClearNode);
      end;
      frmMain.tvBooksF.FocusedNode := Node; frmMain.tvBooksF.CheckState[Node] := csCheckedNormal;
      frmMain.Add2DownloadListExecute(nil);
      Require(TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount = 1,
        'Main did not enqueue the positively proven original A');
      QueueNode := frmMain.tvDownloadList.GetFirst; Queue := frmMain.tvDownloadList.GetNodeData(QueueNode);
      Require(Queue^.HasExpectedIdentity and (Queue^.ExpectedLibID = A.LibID) and
        (Queue^.ExpectedPhysicalIdentity = ReaderBookPhysicalIdentity(A)),
        'Main queue dropped its selection identity proof');
      if LegacyQueue then
      begin
        Queue^.HasExpectedIdentity := False; Queue^.ExpectedLibID := ''; Queue^.ExpectedPhysicalIdentity := '';
      end;
      var QueueURL := Queue^.URL;
      QueueStream.Clear; frmMain.tvDownloadList.SaveToStream(QueueStream);
      frmMain.tvDownloadList.Clear;
      QueueStream.Position := 0; frmMain.tvDownloadList.LoadFromStream(QueueStream);
      QueueNode := frmMain.tvDownloadList.GetFirst; Queue := frmMain.tvDownloadList.GetNodeData(QueueNode);
      Require(Assigned(Queue) and Queue^.BookKey.IsSameAs(A.BookKey) and (Queue^.Title = A.Title) and
        (Queue^.FileName = PathA) and (Queue^.URL = QueueURL) and
        (Queue^.HasExpectedIdentity = not LegacyQueue),
        'Queue persistence discarded or changed an original or legacy item');
      Require(View.SelectNextDownload(Item) and Item.BookKey.IsSameAs(A.BookKey) and
        Item.Expected.HasExpectedIdentity and
        (Item.Expected.ExpectedPhysicalIdentity = ReaderBookPhysicalIdentity(A)),
        'Reloaded Main queue did not pass exact original physical proof to its worker');
      if not LegacyQueue then Require(Item.Expected.ExpectedLibID = A.LibID,
        'Reloaded queue lost the original library-scoped proof field');
      SetLength(Keys, 1); Keys[0] := Item.Expected;
      if PostedCompletion then
      begin
        // Synchronous actual downloader posts the completion to Main without
        // dispatching it yet. Replace the catalog before that notification is read.
        Downloader := TDownloader.Create; Downloader.IgnoreErrors := True;
        Require(Downloader.Download(SystemDB, Item.BookKey, @Item.Expected),
          'Posted completion fixture did not safely commit original A download');
        ReplaceCatalog;
        Collection.GetBookRecord(A.BookKey, Stored, True);
        Book := frmMain.tvBooksA.GetNodeData(CatalogNode);
        // Model the catalog view having refreshed B during this interval. Use
        // its actual DAO record in the already initialized real Main tree row.
        Book^ := Stored;
        Require((Book^.Title = B.Title) and not (bpIsLocal in Book^.BookProps),
          'Posted completion fixture did not install the fresh catalog B view');
        Application.ProcessMessages; CheckSynchronize(0);
        Require((Book^.Title = B.Title) and not (bpIsLocal in Book^.BookProps),
          'Delayed completion notification marked the foreign catalog B tree row local');
        Book := frmMain.tvBooksF.GetNodeData(Node);
        Require((Book^.Title = A.Title) and (bpIsLocal in Book^.BookProps),
          'Delayed completion notification failed to refresh only the proven personal A tree row');
        Require((HTTP.RequestCount = 1) and (HTTP.Failure = '') and FileExists(PathA) and
          (TEncoding.UTF8.GetString(TFile.ReadAllBytes(PathA)) = Body),
          'Committed original A response was lost during delayed Main notification');
        CheckPersonalAndForeign;
        View.CompleteCurrentDownload(False);
        Writeln('PASS saved download identity posted-completion current B view stays nonlocal; own A card/view retains committed local state');
        Flush(Output); Exit;
      end;
      if ReplaceBefore then
      begin
        ReplaceCatalog;
        Downloader := TDownloader.Create; Downloader.IgnoreErrors := True;
        Require(not Downloader.Download(SystemDB, Item.BookKey, @Item.Expected),
          'Direct downloader authorized a stale selection proof');
        Require((HTTP.RequestCount = 0) and not FileExists(PathA),
          'Stale proof reached network or published a file before rejection');
      end;
      Worker := TDownloadBooksThread.Create; Worker.BookIdList := Keys;
      DialogProbe:=TGBIDownloadDialogProbe.Create;
      DialogProbe.ExpectRejection:=ReplaceBefore or ReplaceDuring;
      DialogProbe.DiagnosticPath:=TPath.Combine(Folder,'native-identity-dialog.txt');
      Require(not Assigned(GBIActiveDownloadProbe),'A native download dialog fixture is already active');
      GBIActiveDownloadProbe:=DialogProbe;
      DialogProbe.Hook:=SetWindowsHookEx(WH_CBT,@GBIDownloadNativeHook,0,DialogProbe.UIThread);
      Require(DialogProbe.Hook<>0,'Cannot install the current-UI-thread download dialog fixture');
      Writeln('TRACE saved download identity ',Name,' before actual worker Start'); Flush(Output);
      Started := GetTickCount64; Worker.Start; WorkerStarted:=True;
      if ReplaceDuring then
      begin
        while (HTTP.Requested.WaitFor(0) <> wrSignaled) and not Worker.Finished and
          (GetTickCount64 - Started < 10000) do
        begin Application.ProcessMessages; CheckSynchronize(0); Sleep(5); end;
        Require(HTTP.Requested.WaitFor(0) = wrSignaled,
          'Authorized download did not reach the paused loopback response');
        Require((HTTP.LastDocument = '/payload-original-A') and not FileExists(PathA),
          'Download requested foreign B or published before the paused response');
        Writeln('TRACE saved download identity ',Name,' paused original response observed; replacing catalog'); Flush(Output);
        ReplaceCatalog; HTTP.Released.SetEvent;
      end;
      Worker.WaitFor;
      Writeln('TRACE saved download identity ',Name,' actual worker joined expected_dialogs=',DialogProbe.Messages.Count,
        ' unexpected_dialogs=',DialogProbe.Unexpected.Count); Flush(Output);
      Require(Worker.Finished and not Assigned(Worker.FatalException), 'Identity-aware download worker did not finish cleanly');
      Require((DialogProbe.Failure='') and (DialogProbe.Unexpected.Count=0),
        'Saved download native message probe failed: '+DialogProbe.Failure+' '+DialogProbe.Unexpected.Text);
      Require(DialogProbe.Messages.Count=Ord(ReplaceBefore or ReplaceDuring),
        'Actual saved download rejection did not show its exact expected native explanation once');
      var ResultKeys := Worker.BookIdList;
      Require((Length(ResultKeys) = 1) and (ResultKeys[0].Res = not (ReplaceBefore or ReplaceDuring)),
        'Download worker result does not reflect its identity commit outcome');
      Require(HTTP.Failure = '', 'Download loopback fixture failed: ' + HTTP.Failure);
      if ReplaceBefore then Require((HTTP.RequestCount = 0) and not FileExists(PathA),
        'Immediate worker lost its stale proof and reached network or copied a foreign file')
      else
      begin
        Require((HTTP.RequestCount = 1) and FileExists(PathA),
          'Authorized transfer did not publish the original A response');
        var DownloadedBytes := TFile.ReadAllBytes(PathA);
        Require((Length(DownloadedBytes) = Length(HTTP.Payload)) and
          CompareMem(@DownloadedBytes[0], @HTTP.Payload[0], Length(DownloadedBytes)),
          'Authorized transfer did not retain the exact original A response bytes');
      end;
      CheckPersonalAndForeign;
      View.CompleteCurrentDownload(ResultKeys[0].Res);
      if ReplaceBefore or ReplaceDuring then
      begin
        Require(TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount = 1,
          'Failed identity commit silently removed its saved queue item');
        Queue := frmMain.tvDownloadList.GetNodeData(frmMain.tvDownloadList.GetFirst);
        Require((Queue^.State = dsError) and (Queue^.Title = A.Title) and Queue^.BookKey.IsSameAs(A.BookKey),
          'Failed download changed its original queue title/key or lost the error state');
      end;
      Writeln('PASS saved download identity ', Name,
        ' Main proof+queue reopen; actual worker; loopback requests=', HTTP.RequestCount,
        '; source/personal local flags and marks preserved'); Flush(Output);
    finally
      if Assigned(HTTP) then HTTP.Released.SetEvent;
      if Assigned(Worker) then begin if WorkerStarted then Worker.WaitFor; Worker.Free; end;
      if Assigned(DialogProbe) then
      begin
        if DialogProbe.Hook<>0 then UnhookWindowsHookEx(DialogProbe.Hook);
        if GBIActiveDownloadProbe=DialogProbe then GBIActiveDownloadProbe:=nil;
        DialogProbe.Free;
      end;
      Downloader.Free; HTTP.Free;
      // Only this fixture's item is present. Finish it while its cursor is valid.
      if TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount > 0 then View.CompleteCurrentDownload(True);
    end;
  end;

begin
  RequireIsolatedRegression;
  Require((CaseName = '') or MatchText(CaseName,
    ['matching', 'before-worker', 'during-response', 'legacy-matching', 'legacy-replacement', 'posted-completion']),
    'Unknown isolated saved-download identity subcase: ' + CaseName);
  Require(ExpandFileName(Settings.AppPath).StartsWith('G:\', True), 'Download fixture must remain on G');
  OldActive := Settings.ActiveCollection;
  View := frmMain as IDownloadView;
  OriginalAutoStart := Settings.AutoStartDwnld; OriginalErrorLog := Settings.ErrorLog;
  Menu := TMenuItem.Create(nil); QueueStream := TMemoryStream.Create;
  try
    Settings.AutoStartDwnld := False; Settings.ErrorLog := False;
    if (CaseName = '') or SameText(CaseName, 'matching') then RunCase('matching', False, False, False);
    if (CaseName = '') or SameText(CaseName, 'before-worker') then RunCase('before-worker', True, False, False);
    if (CaseName = '') or SameText(CaseName, 'during-response') then RunCase('during-response', False, True, False);
    if (CaseName = '') or SameText(CaseName, 'legacy-matching') then RunCase('legacy-matching', False, False, True);
    if (CaseName = '') or SameText(CaseName, 'legacy-replacement') then RunCase('legacy-replacement', True, False, True);
    if (CaseName = '') or SameText(CaseName, 'posted-completion') then RunCase('posted-completion', False, False, False, True);
  finally
    Menu.Tag := OldActive; frmMain.miActiveCollectionClick(Menu);
    QueueStream.Free; Menu.Free;
    Settings.AutoStartDwnld := OriginalAutoStart; Settings.ErrorLog := OriginalErrorLog;
  end;
end;

type
  TGBIManagerView = class(TInterfacedObject, IDownloadView)
  private
    FView: IDownloadView;
    FTimer: TTimer;
    procedure PauseDuringInterval(Sender: TObject);
  public
    Manager: TDownloadManagerThread;
    CancelSelection, SelectionCount, SuccessfulCount, FailedCount, CancelCount: Integer;
    PauseInInterval: Boolean;
    SelectedAt, PausedAt: UInt64;
    constructor Create(const View: IDownloadView);
    destructor Destroy; override;
    function SelectNextDownload(out Item: TDownloadItem): Boolean;
    procedure CompleteCurrentDownload(Success: Boolean);
    procedure CancelCurrentDownload;
    function IsMainFormVisible: Boolean;
    procedure ShowDownloadInfo(const Author, Title: string);
    procedure ShowDownloadState(const State: string);
    procedure ShowDownloadProgress(Position: Integer);
    procedure ResetDownloadState;
    procedure SetTrayHint(const Hint: string);
    procedure SetDownloadRunning(Running: Boolean);
    procedure SetQueueControlsEnabled(Enabled: Boolean);
    function AskIgnoreDownloadErrors: Integer;
  end;

constructor TGBIManagerView.Create(const View: IDownloadView);
begin
  inherited Create;
  FView := View;
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False; FTimer.Interval := 150;
  FTimer.OnTimer := PauseDuringInterval;
end;

destructor TGBIManagerView.Destroy;
begin
  FTimer.Free;
  inherited;
end;

procedure TGBIManagerView.PauseDuringInterval(Sender: TObject);
begin
  FTimer.Enabled := False;
  PausedAt := GetTickCount64;
  Manager.Stop;
end;

function TGBIManagerView.SelectNextDownload(out Item: TDownloadItem): Boolean;
begin
  Result := FView.SelectNextDownload(Item);
  if Result then begin Inc(SelectionCount); SelectedAt := GetTickCount64; end;
end;

procedure TGBIManagerView.CompleteCurrentDownload(Success: Boolean);
begin
  if Success then Inc(SuccessfulCount) else Inc(FailedCount);
  FView.CompleteCurrentDownload(Success);
end;

procedure TGBIManagerView.CancelCurrentDownload;
begin
  Inc(CancelCount); FView.CancelCurrentDownload;
end;

function TGBIManagerView.IsMainFormVisible: Boolean;
begin Result := FView.IsMainFormVisible; end;

procedure TGBIManagerView.ShowDownloadInfo(const Author, Title: string);
begin FView.ShowDownloadInfo(Author, Title); end;

procedure TGBIManagerView.ShowDownloadState(const State: string);
begin FView.ShowDownloadState(State); end;

procedure TGBIManagerView.ShowDownloadProgress(Position: Integer);
begin FView.ShowDownloadProgress(Position); end;

procedure TGBIManagerView.ResetDownloadState;
begin FView.ResetDownloadState; end;

procedure TGBIManagerView.SetTrayHint(const Hint: string);
begin FView.SetTrayHint(Hint); end;

procedure TGBIManagerView.SetDownloadRunning(Running: Boolean);
begin
  FView.SetDownloadRunning(Running);
  if not Running then Exit;
  if (CancelSelection > 0) and (SelectionCount = CancelSelection) then
  begin
    PausedAt := GetTickCount64;
    Manager.Stop;
  end
  else if PauseInInterval then
    FTimer.Enabled := True;
end;

procedure TGBIManagerView.SetQueueControlsEnabled(Enabled: Boolean);
begin FView.SetQueueControlsEnabled(Enabled); end;

function TGBIManagerView.AskIgnoreDownloadErrors: Integer;
begin
  // A fixture never lets an unexpected retry question block its process.
  Inc(FailedCount); Result := IDCANCEL;
end;

procedure TestQueuedDownloadCancellation(const CaseName: string = '');
var OldActive, OldInterval: Integer; OldAutoStart, OldErrorLog: Boolean;
  Menu: TMenuItem; View: IDownloadView; QueueStream: TMemoryStream;

  procedure RunCase(const Name: string);
  var Folder, Body: string; CID: Integer; Collection: IBookCollection;
    Books, FrozenBooks: array[0..1] of TBookRecord; Stored: TBookRecord;
    FrozenQueue: array[0..1] of TDownloadData;
    Paths, QueueURLs: array[0..1] of string; ExistingHash: string;
    HTTP: TGBILoopbackDownload; Manager: TDownloadManagerThread;
    Adapter: TGBIManagerView; AdapterRef: IDownloadView;
    Node, GroupNode: PVirtualNode; Group: PGroupData; Book: PBookRecord;
    Queue: PDownloadData; Started: UInt64; ExpectedDone, ExpectedRemaining: Integer;

    function SameAuthors(const Actual, Expected: TBookAuthors): Boolean;
    begin
      if Length(Actual)<>Length(Expected) then Exit(False);
      for var I:=0 to High(Expected) do
        if (Actual[I].AuthorID<>Expected[I].AuthorID) or (Actual[I].LastName<>Expected[I].LastName) or
          (Actual[I].FirstName<>Expected[I].FirstName) or (Actual[I].MiddleName<>Expected[I].MiddleName) then Exit(False);
      Result:=True;
    end;

    function QueueRecordJSON(const Value: TDownloadData): TJSONObject;

      procedure AddText(const Field, Text: string);
      var Escaped: string; N: Integer;
      begin
        // Diagnostics must remain writable even if an old UTF-16 loader
        // produced a dangling surrogate or an unexpected terminal code unit.
        // Preserve the exact UTF-16 units in a bounded ASCII representation.
        N:=Min(1000,Length(Text)); Escaped:='';
        for var J:=1 to N do
          if (Ord(Text[J])<32) or (Ord(Text[J])>126) then
            Escaped:=Escaped+'\u'+IntToHex(Ord(Text[J]),4)
          else Escaped:=Escaped+Text[J];
        Result.AddPair(Field+'_utf16_units',TJSONNumber.Create(Length(Text)));
        Result.AddPair(Field+'_utf16',Escaped);
        if N<Length(Text) then Result.AddPair(Field+'_truncated','true');
      end;

    begin
      Result:=TJSONObject.Create;
      Result.AddPair('collection_id',TJSONNumber.Create(Value.BookKey.DatabaseID));
      Result.AddPair('book_id',TJSONNumber.Create(Int64(Value.BookKey.BookID)));
      Result.AddPair('size',TJSONNumber.Create(Int64(Value.Size)));
      Result.AddPair('state',TJSONNumber.Create(Ord(Value.State)));
      Result.AddPair('has_expected_identity',TJSONBool.Create(Value.HasExpectedIdentity));
      AddText('title',Value.Title); AddText('author',Value.Author);
      AddText('filename',Value.FileName); AddText('url',Value.URL);
      AddText('expected_libid',Value.ExpectedLibID);
      AddText('expected_physical',Value.ExpectedPhysicalIdentity);
    end;

    procedure TraceQueue(const Stage: string);
    var Dump: TJSONObject; Items: TJSONArray; Current: PVirtualNode; Data: PDownloadData;
      Diagnostic: string; Count: Integer;
    begin
      Dump:=TJSONObject.Create;
      try
        Dump.AddPair('stage',Stage);
        Dump.AddPair('native_count',TJSONNumber.Create(TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount));
        Items:=TJSONArray.Create; Dump.AddPair('items',Items);
        Current:=frmMain.tvDownloadList.GetFirst; Count:=0;
        while Assigned(Current) and (Count<4) do
        begin
          Data:=frmMain.tvDownloadList.GetNodeData(Current);
          if Assigned(Data) then Items.AddElement(QueueRecordJSON(Data^));
          Inc(Count); Current:=frmMain.tvDownloadList.GetNext(Current);
        end;
        if Assigned(Current) then Dump.AddPair('extra_items_truncated','true');
        Diagnostic:=Dump.ToJSON;
        Writeln('DIAG queue manager ',Name,' ',Diagnostic); Flush(Output);
        TFile.AppendAllText(TPath.Combine(Folder,'queue-field-diagnostics.jsonl'),Diagnostic+sLineBreak,TEncoding.UTF8);
      finally Dump.Free; end;
    end;

    procedure SaveQueueArtifact(const Stage: string);
    var Path: string;
    begin
      Path:=TPath.Combine(Folder,'queue-'+Stage+'.sav');
      QueueStream.SaveToFile(Path);
      Writeln('DIAG queue manager ',Name,' serialization=',Path,' bytes=',QueueStream.Size,
        ' sha256=',THashSHA2.GetHashStringFromFile(Path)); Flush(Output);
    end;

    procedure TraceQueueMatches(const Actual: PDownloadData; Index: Integer; ExpectedState: TDownloadState);
    var Expected: TDownloadData; Dump, Matches: TJSONObject; Diagnostic: string;
    begin
      Expected:=FrozenQueue[Index]; Expected.State:=ExpectedState;
      Dump:=TJSONObject.Create;
      try
        Dump.AddPair('stage','assert-reloaded'); Dump.AddPair('expected_index',TJSONNumber.Create(Index));
        Dump.AddPair('expected',QueueRecordJSON(Expected));
        if Assigned(Actual) then
        begin
          Dump.AddPair('actual',QueueRecordJSON(Actual^));
          Matches:=TJSONObject.Create; Dump.AddPair('matches',Matches);
          Matches.AddPair('key',TJSONBool.Create(Actual^.BookKey.IsSameAs(Expected.BookKey)));
          Matches.AddPair('title',TJSONBool.Create(Actual^.Title=Expected.Title));
          Matches.AddPair('author',TJSONBool.Create(Actual^.Author=Expected.Author));
          Matches.AddPair('size',TJSONBool.Create(Actual^.Size=Expected.Size));
          Matches.AddPair('filename',TJSONBool.Create(Actual^.FileName=Expected.FileName));
          Matches.AddPair('url',TJSONBool.Create(Actual^.URL=Expected.URL));
          Matches.AddPair('has_expected_identity',TJSONBool.Create(Actual^.HasExpectedIdentity));
          Matches.AddPair('expected_libid',TJSONBool.Create(Actual^.ExpectedLibID=Expected.ExpectedLibID));
          Matches.AddPair('expected_physical',TJSONBool.Create(Actual^.ExpectedPhysicalIdentity=Expected.ExpectedPhysicalIdentity));
          Matches.AddPair('state',TJSONBool.Create(Actual^.State=Expected.State));
        end;
        Diagnostic:=Dump.ToJSON;
        Writeln('DIAG queue manager ',Name,' ',Diagnostic); Flush(Output);
        TFile.AppendAllText(TPath.Combine(Folder,'queue-field-diagnostics.jsonl'),Diagnostic+sLineBreak,TEncoding.UTF8);
      finally Dump.Free; end;
    end;

    procedure EmptyOwnQueue;
    var Item: TDownloadItem;
    begin
      // Main owns a cursor into its current tree. Remove through that
      // interface before reload so it can never point at a freed old node.
      while TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount > 0 do
      begin
        Require(View.SelectNextDownload(Item), 'Cannot clean up the isolated fixture queue');
        View.CompleteCurrentDownload(True);
      end;
    end;
  begin
    Require(TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount = 0,
      'Manager cancellation fixture requires an empty isolated Main queue');
    Folder := IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,
      'queue-manager-' + Name + '-' + TGUID.NewGuid.ToString));
    ForceDirectories(Folder);
    CID := SystemDB.CreateCollection('Queue manager ' + Name, Folder,
      TPath.Combine(Folder, 'catalog.hlc2'), CT_EXTERNAL_ONLINE_FB, Settings.AppPath + 'genres_fb2.glst');
    Collection := SystemDB.GetCollection(CID);
    Collection.SetProperty(PROP_SOURCE_LIBRARY, '');
    Body := '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>' +
      'QUEUE_MANAGER_OWN ё, ї, ў ' + StringOfChar('я', 2000) + '</p></section></body></FictionBook>';
    for var I := 0 to High(Books) do
    begin
      Books[I].Clear; Books[I].Title := Format('Queue manager own %d %s', [I, Name]);
      Books[I].FileName := 'own-' + IntToStr(I); Books[I].FileExt := '.fb2';
      Books[I].LibID := IntToStr(42 + I); Books[I].Lang := 'ru';
      Books[I].Date := EncodeDate(2026, 10, 13);
      Books[I].Size := Length(TEncoding.UTF8.GetBytes(Body));
      Books[I].Rate := 4; Books[I].Progress := 37;
      Books[I].Review := 'Protected queue review ' + IntToStr(I);
      Books[I].Annotation := 'Protected queue annotation ' + IntToStr(I);
      TAuthorsHelper.Add(Books[I].Authors, 'Queue manager', 'Own', '');
      TGenresHelper.Add(Books[I].Genres, '', '', 'prose_contemporary');
      var ID := Collection.InsertBook(Books[I], False, False);
      Require(ID = I + 1, 'Fresh manager fixture did not allocate expected distinct IDs');
      Collection.GetBookRecord(CreateBookKey(ID, CID), Books[I], True);
      Require((Length(Books[I].Authors)=1) and (TAuthorsHelper.GetList(Books[I].Authors)='Queue manager Own'),
        'Manager fixture source did not store its exact single author');
      Collection.AddBookToGroup(Books[I].BookKey, FAVORITES_GROUP_ID);
      var SavedKey:=Books[I].BookKey;
      var PersonalSnapshot:=Default(TBookRecord);
      SystemDB.GetBookRecord(SavedKey,PersonalSnapshot);
      Require(SameAuthors(PersonalSnapshot.Authors,Books[I].Authors),
        'Fresh manager personal snapshot changed or duplicated the source author');
      Books[I]:=PersonalSnapshot;
      FrozenBooks[I]:=Books[I];
      FrozenBooks[I].Authors:=Copy(Books[I].Authors,0,Length(Books[I].Authors));
      FrozenBooks[I].Genres:=Copy(Books[I].Genres,0,Length(Books[I].Genres));
      Paths[I] := TPath.Combine(Folder, Books[I].FileName + Books[I].FileExt);
    end;
    ExistingHash := '';
    if Name = 'cancel-during-interval' then
    begin
      // The old code called Download after its interrupted sleep. An already
      // valid file then bypassed HTTP and still incorrectly set IsLocal.
      TFile.WriteAllBytes(Paths[0], TEncoding.UTF8.GetBytes(Body));
      ExistingHash := THashSHA2.GetHashStringFromFile(Paths[0]);
    end;
    HTTP := nil; Manager := nil; Adapter := nil; AdapterRef := nil;
    try
      HTTP := TGBILoopbackDownload.Create(Body, False);
      Collection.SetProperty(PROP_URL, HTTP.URL);
      Collection.SetProperty(PROP_CONNECTIONSCRIPT, 'GET %URL%payload-original-A' + sLineBreak + 'CHECK');
      Menu.Tag := CID; frmMain.miActiveCollectionClick(Menu);
      ShowPage(PAGE_FAVORITES);
      GroupNode := frmMain.tvGroups.GetFirst;
      while Assigned(GroupNode) do
      begin
        Group := frmMain.tvGroups.GetNodeData(GroupNode);
        if Assigned(Group) and (Group^.GroupID = FAVORITES_GROUP_ID) then Break;
        GroupNode := frmMain.tvGroups.GetNext(GroupNode);
      end;
      Require(Assigned(GroupNode), 'Manager fixture cannot find the real Main Favorites group');
      frmMain.tvGroups.FocusedNode := GroupNode; frmMain.tvGroupsChange(frmMain.tvGroups, GroupNode);
      frmMain.cbLangSelectF.ItemIndex := 0;
      if Assigned(frmMain.cbLangSelectF.OnChange) then frmMain.cbLangSelectF.OnChange(frmMain.cbLangSelectF);
      Node := frmMain.tvBooksF.GetFirst;
      while Assigned(Node) do
      begin
        Book := frmMain.tvBooksF.GetNodeData(Node);
        if Assigned(Book) and (Book^.NodeType = ntBookInfo) and
          (Book^.BookKey.IsSameAs(Books[0].BookKey) or Book^.BookKey.IsSameAs(Books[1].BookKey)) then
          frmMain.tvBooksF.CheckState[Node] := csCheckedNormal
        else frmMain.tvBooksF.CheckState[Node] := csUncheckedNormal;
        Node := frmMain.tvBooksF.GetNext(Node);
      end;
      frmMain.Add2DownloadListExecute(nil);
      Require(TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount = 2,
        'Actual Main selection did not enqueue both own books');
      // Establish A-before-B independently of the saved Favorites sort order.
      Node := frmMain.tvDownloadList.GetFirst;
      while Assigned(Node) do
      begin
        Queue := frmMain.tvDownloadList.GetNodeData(Node);
        if Assigned(Queue) and Queue^.BookKey.IsSameAs(Books[0].BookKey) then Break;
        Node := frmMain.tvDownloadList.GetNext(Node);
      end;
      Require(Assigned(Node), 'Manager fixture cannot locate own A queue record');
      if Node <> frmMain.tvDownloadList.GetFirst then
        frmMain.tvDownloadList.MoveTo(Node, frmMain.tvDownloadList.GetFirst, amInsertBefore, False);
      Node := frmMain.tvDownloadList.GetFirst;
      Queue := frmMain.tvDownloadList.GetNodeData(Node);
      Require(Assigned(Queue) and Queue^.BookKey.IsSameAs(Books[0].BookKey),
        'Manager fixture Main queue order is not original A followed by B');
      for var I := 0 to High(Books) do
      begin
        Require(Assigned(Node), 'Manager fixture initial queue is incomplete');
        Queue := frmMain.tvDownloadList.GetNodeData(Node);
        Require(Assigned(Queue) and Queue^.BookKey.IsSameAs(Books[I].BookKey),
          'Manager fixture initial queue contains a foreign or reordered book');
        Require((Queue^.Title=FrozenBooks[I].Title) and
          (Queue^.Author=TAuthorsHelper.GetList(FrozenBooks[I].Authors)) and
          (Queue^.Size=FrozenBooks[I].Size) and (Queue^.FileName=Paths[I]) and
          Queue^.HasExpectedIdentity and (Queue^.ExpectedLibID=FrozenBooks[I].LibID) and
          (Queue^.ExpectedPhysicalIdentity=ReaderBookPhysicalIdentity(FrozenBooks[I])) and (Queue^.State=dsWait),
          'Initial real Main queue differs from the immutable full original book snapshot');
        FrozenQueue[I]:=Queue^;
        QueueURLs[I] := Queue^.URL;
        Node := frmMain.tvDownloadList.GetNext(Node);
      end;
      TraceQueue('before-initial-save');
      QueueStream.Clear; frmMain.tvDownloadList.SaveToStream(QueueStream);
      SaveQueueArtifact('initial');
      frmMain.tvDownloadList.Clear; QueueStream.Position := 0;
      frmMain.tvDownloadList.LoadFromStream(QueueStream);
      TraceQueue('after-initial-load');
      Adapter := TGBIManagerView.Create(View); AdapterRef := Adapter;
      Manager := TDownloadManagerThread.Create(AdapterRef); Adapter.Manager := Manager;
      if Name = 'cancel-before-loop' then Adapter.CancelSelection := 1;
      if Name = 'cancel-after-success' then Adapter.CancelSelection := 2;
      Adapter.PauseInInterval := Name = 'cancel-during-interval';
      if Adapter.PauseInInterval then Settings.DwnldInterval := 2000 else Settings.DwnldInterval := 0;
      Started := GetTickCount64; Manager.Start;
      while not Manager.Finished and (GetTickCount64 - Started < 15000) do
      begin Application.ProcessMessages; CheckSynchronize(0); Sleep(5); end;
      Require(Manager.Finished, 'Actual queue manager did not stop at its bounded fixture deadline');
      Manager.WaitFor;
      TraceQueue('after-manager');
      Require(not Assigned(Manager.FatalException), 'Actual queue manager failed with a thread exception');
      ExpectedDone := 0;
      if Name = 'cancel-after-success' then ExpectedDone := 1;
      if Name = 'matching-count' then ExpectedDone := 2;
      ExpectedRemaining := 2 - ExpectedDone;
      Require((Manager.ProcessedCount = ExpectedDone) and (Adapter.SuccessfulCount = ExpectedDone) and
        (Adapter.FailedCount = 0), 'Queue manager counted an unattempted, canceled, or duplicate completion');
      Require((HTTP.RequestCount = ExpectedDone) and (HTTP.Failure = ''),
        'Canceled queue selection reached HTTP or a matching transfer was counted incorrectly');
      Require(TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount = ExpectedRemaining,
        'Canceled or unattempted book disappeared from the real Main queue');
      Require(Adapter.CancelCount = Ord(Name <> 'matching-count'),
        'Queue cancellation callback was lost or reported twice');
      if Adapter.PauseInInterval then Require((Adapter.PausedAt - Adapter.SelectedAt >= 100) and
        (Adapter.PausedAt - Adapter.SelectedAt < 2000), 'Pause was not injected inside the download interval');
      for var I := 0 to High(Books) do
      begin
        for var Personal := 0 to 1 do
        begin
          Stored:=Default(TBookRecord);
          if Personal = 0 then Collection.GetBookRecord(Books[I].BookKey, Stored, True)
          else SystemDB.GetBookRecord(Books[I].BookKey, Stored);
          Require(SameAuthors(Stored.Authors,FrozenBooks[I].Authors),
            'Actual catalog/personal author list changed or grew during queue cancellation');
          Require((Stored.Title = Books[I].Title) and (Stored.LibID = Books[I].LibID) and
            (Stored.FileName = Books[I].FileName) and (Stored.Date = Books[I].Date) and
            (Stored.Rate = 4) and (Stored.Progress = 37) and (Stored.Review = Books[I].Review) and
            (Stored.Annotation = Books[I].Annotation) and ((bpIsLocal in Stored.BookProps) = (I < ExpectedDone)),
            'Pause changed source/personal identity, marks, text, or local state of an unattempted book');
        end;
        if I < ExpectedDone then Require(FileExists(Paths[I]) and
          (TEncoding.UTF8.GetString(TFile.ReadAllBytes(Paths[I])) = Body),
          'Successful manager transfer did not preserve the exact own payload')
        else if (I = 0) and (ExistingHash <> '') then
          Require(THashSHA2.GetHashStringFromFile(Paths[I]) = ExistingHash,
            'Pause changed the existing valid file before a new request')
        else Require(not FileExists(Paths[I]), 'Pause published a file for an unattempted book');
      end;
      // Persist and reopen the remaining real queue; canceled B must retain
      // its exact original key, URL, display text, state and compact proof.
      TraceQueue('before-retained-save');
      QueueStream.Clear; frmMain.tvDownloadList.SaveToStream(QueueStream);
      SaveQueueArtifact('retained');
      EmptyOwnQueue; QueueStream.Position := 0;
      frmMain.tvDownloadList.LoadFromStream(QueueStream);
      TraceQueue('after-retained-load');
      Node := frmMain.tvDownloadList.GetFirst;
      for var I := ExpectedDone to High(Books) do
      begin
        Require(Assigned(Node), 'Queue reopen lost a canceled or later unattempted item');
        Queue := frmMain.tvDownloadList.GetNodeData(Node);
        var ExpectedState := dsWait;
        if I = ExpectedDone then ExpectedState := dsError;
        TraceQueueMatches(Queue,I,ExpectedState);
        Require(Assigned(Queue) and Queue^.BookKey.IsSameAs(Books[I].BookKey) and
          (Queue^.Title = Books[I].Title) and (Queue^.Author = FrozenQueue[I].Author) and
          (Queue^.Size = Books[I].Size) and (Queue^.FileName = Paths[I]) and (Queue^.URL = QueueURLs[I]) and
          Queue^.HasExpectedIdentity and (Queue^.ExpectedLibID = Books[I].LibID) and
          (Queue^.ExpectedPhysicalIdentity = ReaderBookPhysicalIdentity(Books[I])) and
          (Queue^.State = ExpectedState),
          'Queue reopen changed canceled book identity/proof/text or a later waiting item');
        Node := frmMain.tvDownloadList.GetNext(Node);
      end;
      Require(not Assigned(Node), 'Queue reopen added an unexpected extra book');
      Writeln('PASS queued download manager ', Name, ' processed=', Manager.ProcessedCount,
        ' http=', HTTP.RequestCount, ' retained=', ExpectedRemaining,
        '; real Main queue reopen, exact source/personal data and IsLocal guarded'); Flush(Output);
    finally
      if Assigned(Manager) then begin Manager.TerminateNow; Manager.WaitFor; Manager.Free; end;
      if Assigned(Adapter) then Adapter.Manager := nil;
      AdapterRef := nil; HTTP.Free;
      EmptyOwnQueue;
    end;
  end;

begin
  RequireIsolatedRegression;
  Require((CaseName = '') or MatchText(CaseName,
    ['cancel-before-loop', 'cancel-after-success', 'cancel-during-interval', 'matching-count']),
    'Unknown queue manager cancellation subcase: ' + CaseName);
  Require(ExpandFileName(Settings.AppPath).StartsWith('G:\', True), 'Queue fixture must remain on G');
  OldActive := Settings.ActiveCollection; OldInterval := Settings.DwnldInterval;
  OldAutoStart := Settings.AutoStartDwnld; OldErrorLog := Settings.ErrorLog;
  View := frmMain as IDownloadView;
  Menu := TMenuItem.Create(nil); QueueStream := TMemoryStream.Create;
  try
    Settings.AutoStartDwnld := False; Settings.ErrorLog := False;
    if (CaseName = '') or SameText(CaseName, 'cancel-before-loop') then RunCase('cancel-before-loop');
    if (CaseName = '') or SameText(CaseName, 'cancel-after-success') then RunCase('cancel-after-success');
    if (CaseName = '') or SameText(CaseName, 'cancel-during-interval') then RunCase('cancel-during-interval');
    if (CaseName = '') or SameText(CaseName, 'matching-count') then RunCase('matching-count');
  finally
    Menu.Tag := OldActive; frmMain.miActiveCollectionClick(Menu);
    QueueStream.Free; Menu.Free;
    Settings.DwnldInterval := OldInterval;
    Settings.AutoStartDwnld := OldAutoStart; Settings.ErrorLog := OldErrorLog;
  end;
end;

procedure TestGroupBookIdentity(const Subcase: string = '');
var
  Driver: TGBIMainDriver;
  MenuItem, ExportItem: TMenuItem;
  PreviousCID: Integer;
  SavedLatestCommonDialogs: Boolean;
  SavedDevice, SavedFileTemplate, SavedFolderTemplate, SavedReadDir, SavedInpxURL: string;
  SavedPrompt, SavedAutoStart, SavedOverwrite, SavedBuiltin, SavedHideDeleted: Boolean;
  ProtectedNotes: TArray<TReaderAnnotation>;

  procedure RunScenario(const LabelText, StableID: string; TrustedReplacement: Boolean);
  var
    Folder, CatalogFile, SourceA, SourceB, HashA, HashB, MarkerA, MarkerB, Stage: string;
    CID, AID, QueueCount, ExpectedRate, ExpectedProgress: Integer;
    Collection: IBookCollection;
    Seed, Saved, Current, Stored: TBookRecord;
    Node: PVirtualNode; Data: PBookRecord;
    GroupNode: PVirtualNode; GroupData: PGroupData;
    ReaderFile, NotesFile, IdentityA, IdentityB, LegacyIdentity, NoteID, NotesHash: string;
    Ini: TMemIniFile; Notes: TReaderAnnotations; Note, LegacyNote: TReaderAnnotation;

    procedure Trace(const Value: string; const Path: string = '');
    var Text: string;
    begin
      Stage := Value;
      Text := 'TRACE group identity ' + LabelText + ' stage=' + Stage + ' path=' + Path;
      Writeln(Text); Flush(Output);
      TFile.AppendAllText(TPath.Combine(Folder, 'stage-diagnostics.txt'), Text + sLineBreak, TEncoding.UTF8);
    end;

    procedure PreflightDescription(const Path, ExpectedID: string);
    var Stream: TFileStream; Recorded: TRecordedMetadataStream;
      Buffer: array[0..8191] of Byte; Count: Integer;
      XML, Details, Diagnostic: string; WasCanceled, Recovered: Boolean;
      WideCount: Integer; StrictError: DWORD;
    begin
      Trace('description-preflight', Path);
      Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
      try
        Count := Stream.Read(Buffer, SizeOf(Buffer));
        Diagnostic := Format('source=%s bytes=%d first-chunk=%d trailing=', [Path, Stream.Size, Count]);
        for var I := Max(0, Count - 12) to Count - 1 do Diagnostic := Diagnostic + IntToHex(Buffer[I], 2) + ' ';
        SetLastError(0);
        WideCount := MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
          PAnsiChar(@Buffer[0]), Count, nil, 0);
        StrictError := GetLastError;
        if WideCount > 0 then
          Diagnostic := Diagnostic + sLineBreak + 'strict-first-chunk=UTF8-valid'
        else
          Diagnostic := Diagnostic + Format('%sstrict-first-chunk=UTF8-invalid error=%d',
            [sLineBreak, StrictError]);
        Stream.Position := 0;
        Recorded := TRecordedMetadataStream.Create(Stream, 16*1024*1024);
        try
          Recorded.Read(Buffer, SizeOf(Buffer));
          try
            Recovered := RecoverMetadataPrefix(Recorded, 16*1024*1024, 64, nil, XML, Details, WasCanceled, True);
            Diagnostic := Diagnostic + Format('%srecovered=%d canceled=%d xml-chars=%d captured=%d details=%s',
              [sLineBreak, Ord(Recovered), Ord(WasCanceled), Length(XML), Recorded.Captured.Size, Details]);
          except on E: Exception do
            Diagnostic := Diagnostic + sLineBreak + 'recovery-exception=' + E.ClassName + ': ' + E.Message; end;
        finally Recorded.Free; end;
        TFile.WriteAllText(TPath.Combine(Folder, 'description-diagnostics.txt'), Diagnostic, TEncoding.UTF8);
        Writeln('DIAG description ', Diagnostic); Flush(Output);
        Stream.Position := 0;
        try
          var Metadata := LoadFB2Description(Stream, False);
          Require((Metadata.Description.Documentinfo.Id = ExpectedID) and
            (Metadata.Description.Documentinfo.Version = '1.0') and
            (Metadata.Description.Publishinfo.Year = ''),
            'Group fixture required document metadata or optional missing publish-info failed its actual parser preflight');
        except
          on E: Exception do
          begin
            Trace('description-preflight-failed ' + E.ClassName + ': ' + E.Message, Path);
            raise;
          end;
        end;
      finally Stream.Free; end;
      Trace('description-preflight-passed', Path);
    end;

    function BookBody(const Marker: string): string;
    begin
      Result := '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">' +
        '<description><title-info><genre>prose_contemporary</genre><author><first-name>Own</first-name>' +
        '<last-name>Identity author</last-name></author><book-title>Private identity fixture</book-title>' +
        '<lang>ru</lang></title-info><document-info><author><first-name>Own</first-name>' +
        '<last-name>Identity author</last-name></author><program-used>Native identity fixture</program-used>' +
        '<date value="2026-10-13">2026-10-13</date><id>' + Marker + '</id><version>1.0</version>' +
        '</document-info></description><body><section><title><p>Private fixture</p></title>';
      for var I := 1 to 240 do Result := Result + '<p>' + Marker +
        ' Проверка сохранения страницы и заметок. Текст собственной небольшой книги. ' + IntToStr(I) + '</p>';
      Result := Result + '</section></body></FictionBook>';
    end;

    procedure SelectSavedCard;
    begin
      ShowPage(PAGE_FAVORITES);
      GroupNode := frmMain.tvGroups.GetFirst;
      while Assigned(GroupNode) do
      begin
        GroupData := frmMain.tvGroups.GetNodeData(GroupNode);
        if Assigned(GroupData) and (GroupData^.GroupID = FAVORITES_GROUP_ID) then Break;
        GroupNode := frmMain.tvGroups.GetNext(GroupNode);
      end;
      Require(Assigned(GroupNode), 'Native Main has no real Favorites group');
      frmMain.tvGroups.ClearSelection;
      frmMain.tvGroups.Selected[GroupNode] := True; frmMain.tvGroups.FocusedNode := GroupNode;
      frmMain.tvGroupsChange(frmMain.tvGroups, GroupNode);
      frmMain.cbLangSelectF.ItemIndex := 0;
      if Assigned(frmMain.cbLangSelectF.OnChange) then frmMain.cbLangSelectF.OnChange(frmMain.cbLangSelectF);
      Node := frmMain.tvBooksF.GetFirst;
      while Assigned(Node) do
      begin
        Data := frmMain.tvBooksF.GetNodeData(Node);
        if Assigned(Data) and (Data^.NodeType = ntBookInfo) and
          Data^.BookKey.IsSameAs(Saved.BookKey) then Break;
        Node := frmMain.tvBooksF.GetNext(Node);
      end;
      Require(Assigned(Node), 'Saved real group card disappeared after catalog replacement');
      frmMain.tvBooksF.ClearSelection;
      frmMain.tvBooksF.Selected[Node] := True; frmMain.tvBooksF.FocusedNode := Node;
      frmMain.tvBooksF.CheckState[Node] := csCheckedNormal;
      frmMain.tvBooksTreeChange(frmMain.tvBooksF, Node);
      Require(Data^.Title = Saved.Title, 'Main replaced a saved group title with the reused catalog row');
    end;

    procedure CheckProtected(ExpectedProgress: Integer);
    begin
      SystemDB.GetBookRecord(Saved.BookKey, Stored);
      Require((Stored.Title = Saved.Title) and (Stored.LibID = Saved.LibID) and (Stored.Date = Saved.Date) and
        (Stored.Rate = ExpectedRate) and (Stored.Progress = ExpectedProgress) and
        (Stored.Review = Saved.Review) and (Stored.Annotation = Saved.Annotation),
        'Group identity checks changed saved marks, review, annotation or book identity');
      Require((THashSHA2.GetHashStringFromFile(SourceA) = HashA) and
        (THashSHA2.GetHashStringFromFile(SourceB) = HashB), 'Main/worker identity checks rewrote source books');
      Require(THashSHA2.GetHashStringFromFile(NotesFile) = NotesHash,
        'Main group reading/export altered the saved notes document');
      Notes := TReaderAnnotations.Create(ReaderFile);
      try
        var Entries := Notes.Items(IdentityA);
        Require((Length(Entries) = 1) and (Entries[0].ID = NoteID) and
          (Entries[0].Text = Note.Text) and (Entries[0].Quote = Note.Quote),
          'Saved group note/quote lost its original reader identity');
      finally Notes.Free; end;
    end;

    procedure CheckForeignCatalog;
    begin
      Collection.GetBookRecord(Saved.BookKey, Stored, True);
      Require((Stored.Title = Current.Title) and (Stored.LibID = Current.LibID) and (Stored.Date = Current.Date) and
        (Stored.FileName = Current.FileName) and (Stored.Rate = 2) and (Stored.Progress = 7) and
        (Stored.Review = Current.Review) and (Stored.Annotation = Current.Annotation),
        'A saved group personal operation changed the foreign replacement catalog book');
    end;

    procedure MainReview(const ReviewValue, AnnotationValue: string; CorruptSystemCard: Boolean;
      RetryDraftFault: Boolean = False; ReadOnlyContext: Boolean = False);
    begin
      Trace('Main-review corrupt=' + IntToStr(Ord(CorruptSystemCard)) +
        ' readonly=' + IntToStr(Ord(ReadOnlyContext)), Saved.GetBookFileName);
      Driver.ExpectedReview := Saved.Review; Driver.ExpectedAnnotation := Saved.Annotation;
      Driver.ReviewText := ReviewValue; Driver.AnnotationText := AnnotationValue;
      Driver.CorruptBeforeReviewSave := CorruptSystemCard;
      Driver.ExpectReadOnly := ReadOnlyContext;
      Driver.DraftRetryExpected := RetryDraftFault; Driver.DraftRetrySeen := False; Driver.ReviewAttempt := 0;
      Driver.ForeignSystemCard := Current;
      Driver.ReviewFinished := False; Driver.ReviewEditing := True; Driver.Failure := '';
      frmMain.ShowBookInfo(nil);
      Require(Driver.ReviewFinished and (Driver.Failure = ''), 'Main review fixture failed: ' + Driver.Failure);
      if RetryDraftFault then Require(Driver.DraftRetrySeen,
        'Draft write fault did not reopen the actual dialog with its input retained');
      CheckForeignCatalog;
    end;

    procedure ReadViaMain(ReplaceRow: Boolean);
    var Action: TAction;
    begin
      Trace('Main-read replace=' + IntToStr(Ord(ReplaceRow)), Saved.GetBookFileName);
      Ini := TMemIniFile.Create(ReaderFile, TEncoding.UTF8);
      try Ini.WriteInteger('Book.' + IdentityA, 'Position', 10); Ini.UpdateFile;
      finally Ini.Free; end;
      Driver.Collection := Collection; Driver.Replacement := Current; Driver.ExpectedText := MarkerA;
      Driver.BeginRead(ReplaceRow);
      Action := frmMain.FindComponent('acReadBuiltin') as TAction;
      Require(Assigned(Action), 'Native Main built-in read action is absent');
      Action.Update; Require(Action.Enabled, 'Saved exact physical book cannot be read in Main');
      Action.Execute;
      while not Driver.Finished and (GetTickCount64 - Driver.Started < 20000) do
      begin Application.ProcessMessages; CheckSynchronize(0); Sleep(5); end;
      Require(Driver.Finished and (Driver.Failure = ''), 'Main group read failed: ' + Driver.Failure);
      Ini := TMemIniFile.Create(ReaderFile, TEncoding.UTF8);
      try
        Require((Ini.ReadString('Book.' + IdentityA, 'Title', '') = Saved.Title) and
          (Ini.ReadInteger('Book.' + IdentityA, 'Position', 0) > 0),
          'Main did not save the original group book position/title in reader.ini');
        Require(Ini.ReadString('GroupIdentitySentinel', 'Keep', '') = 'Своя настройка ё',
          'Main reader save discarded an unrelated settings section');
        Require(Ini.ReadInteger('Bookmarks.' + IdentityA, 'Count', 0) > 0,
          'Main group read lost the original book bookmarks');
        if IdentityB <> IdentityA then
          Require(not Ini.SectionExists('Book.' + IdentityB), 'Main reader saved the position under foreign book B');
        if LegacyIdentity <> '' then
        begin
          Require((Ini.ReadString('Book.' + LegacyIdentity, 'Title', '') = 'Legacy ambiguous raw numeric history') and
            (Ini.ReadInteger('Book.' + LegacyIdentity, 'Position', 0) = 4242) and
            (Ini.ReadInteger('Bookmarks.' + LegacyIdentity, 'Count', 0) = 1) and
            (Ini.ReadString('Bookmarks.' + LegacyIdentity, 'Title0', '') = 'Keep legacy numeric bookmark'),
            'Main contextual history changed existing ambiguous raw numeric history/bookmarks');
        end;
      finally Ini.Free; end;
    end;

    procedure MainExport(const SubFolder: string; ExpectSource: string);
    var Destination: string; Files: TArray<string>;
    begin
      Trace('Main-export ' + SubFolder, ExpectSource);
      Destination := TPath.Combine(Folder, SubFolder); ForceDirectories(Destination);
      Settings.DeviceDir := Destination; Driver.Messages.Clear;
      SelectSavedCard;
      frmMain.SendToDeviceExecute(ExportItem);
      Files := TDirectory.GetFiles(Destination, '*', TSearchOption.soAllDirectories);
      if ExpectSource = '' then
      begin
        Require(Length(Files) = 0, 'Main export opened/copied foreign book B under a reused ID');
        Require(frmMain.tvBooksF.CheckState[Node] in [csCheckedNormal, csCheckedPressed],
          'Skipped mismatched group book lost its selected checkbox');
        Writeln('DIAG unsafe group export messages=', Copy(Driver.Messages.Text, 1, 3000),
          ' unexpected=', Copy(Driver.Unexpected.Text, 1, 3000)); Flush(Output);
        TFile.WriteAllText(TPath.Combine(Folder, 'dialog-diagnostics.txt'),
          'Messages:' + sLineBreak + Copy(Driver.Messages.Text, 1, 6000) + sLineBreak +
          'Unexpected:' + sLineBreak + Copy(Driver.Unexpected.Text, 1, 6000), TEncoding.UTF8);
        Require(Driver.HasMessage('Пропущено книг из группы'),
          'Main skipped the unsafe group export without an explanation; messages=' +
          Copy(Driver.Messages.Text, 1, 3000) + '; unexpected=' + Copy(Driver.Unexpected.Text, 1, 3000));
      end
      else
      begin
        Require((Length(Files) = 1) and
          (THashSHA2.GetHashStringFromFile(Files[0]) = THashSHA2.GetHashStringFromFile(ExpectSource)),
          'Main rejected or changed a positively proven group export');
      end;
    end;

    procedure ExpectedWorkerExport;
    var Worker: TExportToDeviceThread; Capture: TGBIWorkerCapture; Keys: TBookIdList;
      Destination: string; Files: TArray<string>;
    begin
      Trace('worker-after-selection-proof', Current.GetBookFileName);
      Destination := TPath.Combine(Folder, 'worker-after-selection-proof'); ForceDirectories(Destination);
      SetLength(Keys, 1); Keys[0] := Default(TBookIdStruct); Keys[0].BookKey := Saved.BookKey;
      Keys[0].HasExpectedIdentity := True; Keys[0].ExpectedLibID := Saved.LibID;
      Keys[0].ExpectedPhysicalIdentity := ReaderBookPhysicalIdentity(Saved);
      Worker := TExportToDeviceThread.Create; Capture := TGBIWorkerCapture.Create;
      Capture.Text := TStringList.Create;
      try
        Worker.BookIdList := Keys; Worker.DeviceDir := Destination;
        Worker.ExportMode := emFB2; Worker.ExplicitFormat := True;
        Worker.OnShowMessage := Capture.Message; Worker.OnTeletype := Capture.Warning;
        Worker.Start; Worker.WaitFor;
        Require(Worker.Finished and not Assigned(Worker.FatalException), 'Identity-aware export worker did not finish');
        Files := TDirectory.GetFiles(Destination, '*', TSearchOption.soAllDirectories);
        if TrustedReplacement then
          Require((Length(Files) = 1) and (THashSHA2.GetHashStringFromFile(Files[0]) = HashB),
            'Worker rejected a verified stable identity after physical metadata changed')
        else
        begin
          Require((Length(Files) = 0) and Capture.Text.Text.Contains('больше не совпадает с каталогом'),
            'Worker used a stale selection proof to read a different replacement book');
        end;
      finally
        Worker.OnShowMessage := nil; Worker.OnTeletype := nil; Worker.Free;
        Capture.Text.Free; Capture.Free;
      end;
    end;

  begin
    ExpectedRate := 4; ExpectedProgress := 37;
    Folder := IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,
      'group-book-identity-' + LabelText + '-' + TGUID.NewGuid.ToString));
    ForceDirectories(Folder);
    Trace('setup', Folder);
    CID := SystemDB.CreateCollection('Group identity ' + LabelText, Folder,
      TPath.Combine(Folder, 'catalog.hlc2'), CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
    Collection := SystemDB.GetCollection(CID); Collection.SetProperty(PROP_SOURCE_LIBRARY, '');
    MarkerA := 'GROUP_ORIGINAL_A_' + LabelText; MarkerB := 'GROUP_FOREIGN_B_' + LabelText;
    if TrustedReplacement then MarkerB := MarkerA;
    SourceA := TPath.Combine(Folder, 'physical-A.fb2'); SourceB := TPath.Combine(Folder, 'physical-B.fb2');
    TFile.WriteAllText(SourceA, BookBody(MarkerA), TEncoding.UTF8);
    TFile.WriteAllText(SourceB, BookBody(MarkerB), TEncoding.UTF8);
    PreflightDescription(SourceA, MarkerA);
    Trace('catalog-import', SourceA);
    HashA := THashSHA2.GetHashStringFromFile(SourceA); HashB := THashSHA2.GetHashStringFromFile(SourceB);
    Seed.Clear; Seed.Title := 'Saved original A ' + LabelText; Seed.FileName := 'physical-A'; Seed.FileExt := '.fb2';
    Seed.LibID := StableID; Seed.Lang := 'ru'; Seed.Size := 100; Seed.Date := EncodeDate(2026, 10, 13);
    Seed.Rate := 4; Seed.Progress := 37; Seed.Review := 'Своя мысль A: не терять ё, ї, ў';
    Seed.Annotation := 'Сохранённая аннотация A'; Include(Seed.BookProps, bpIsLocal);
    TAuthorsHelper.Add(Seed.Authors, 'Identity author', 'Own', '');
    TGenresHelper.Add(Seed.Genres, '', '', 'prose_contemporary');
    AID := Collection.InsertBook(Seed, False, False); Require(AID = 1, 'Fresh group fixture did not allocate ID1');
    Collection.GetBookRecord(CreateBookKey(AID, CID), Seed, True);
    Collection.AddBookToGroup(Seed.BookKey, FAVORITES_GROUP_ID);
    SystemDB.GetBookRecord(Seed.BookKey, Saved);
    Require(ReaderBookMatchesCatalog(Collection, Saved), 'Exact saved physical card lacks positive catalog proof');
    Require(FileExists(Saved.GetBookFileName), 'Saved group physical path does not locate original A');

    Current := Seed; Current.Title := 'Replacement B ' + LabelText; Current.FileName := 'physical-B';
    Current.Date := EncodeDate(2025, 1, 7);
    Current.Rate := 2; Current.Progress := 7; Current.Review := 'Foreign B review'; Current.Annotation := 'Foreign B annotation';
    if not TrustedReplacement and (StableID <> '42') then Current.LibID := '';
    IdentityA := Copy(THashSHA2.GetHashString(ReaderHistoryName(Saved,
      VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)))), 1, 40);
    IdentityB := Copy(THashSHA2.GetHashString(ReaderHistoryName(Current,
      VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)))), 1, 40);
    LegacyIdentity := '';
    if StableID = '42' then
    begin
      Require(ReaderCopyName(Saved) = ReaderCopyName(Current), 'Raw numeric history fixture does not reproduce the old shared ID');
      Require(IdentityA <> IdentityB, 'Contextual unknown numeric history still aliases physically different books');
      LegacyIdentity := Copy(THashSHA2.GetHashString(ReaderCopyName(Saved)), 1, 40);
      Require((IdentityA <> LegacyIdentity) and (IdentityB <> LegacyIdentity),
        'Contextual unknown numeric history reused the ambiguous legacy history section');
    end;
    if TrustedReplacement then
      Require((IdentityA = IdentityB) and
        (IdentityA = Copy(THashSHA2.GetHashString(ReaderCopyName(Saved)), 1, 40)),
        'Trusted Flibusta history lost compatibility with its existing stable identity');
    ReaderFile := ResolveReaderSettingsFile(Settings.DataDir); NotesFile := TPath.Combine(Settings.DataDir, 'reader-notes.json');
    Ini := TMemIniFile.Create(ReaderFile, TEncoding.UTF8);
    try
      Ini.WriteString('GroupIdentitySentinel', 'Keep', 'Своя настройка ё');
      Ini.WriteString('Book.' + IdentityA, 'Title', Saved.Title); Ini.WriteInteger('Book.' + IdentityA, 'Position', 10);
      Ini.WriteInteger('Bookmarks.' + IdentityA, 'Count', 1); Ini.WriteInteger('Bookmarks.' + IdentityA, 'Position0', 10);
      Ini.WriteString('Bookmarks.' + IdentityA, 'Title0', 'Сохранённая закладка A');
      if LegacyIdentity <> '' then
      begin
        Ini.WriteString('Book.' + LegacyIdentity, 'Title', 'Legacy ambiguous raw numeric history');
        Ini.WriteInteger('Book.' + LegacyIdentity, 'Position', 4242);
        Ini.WriteInteger('Bookmarks.' + LegacyIdentity, 'Count', 1);
        Ini.WriteInteger('Bookmarks.' + LegacyIdentity, 'Position0', 4242);
        Ini.WriteString('Bookmarks.' + LegacyIdentity, 'Title0', 'Keep legacy numeric bookmark');
      end;
      Ini.UpdateFile;
    finally Ini.Free; end;
    Notes := TReaderAnnotations.Create(ReaderFile);
    try
      Note := Default(TReaderAnnotation); Note.BookID := IdentityA; Note.BookTitle := Saved.Title;
      Note.Title := 'Мысль A'; Note.Text := 'Не терять заметку о собственной книге A';
      Note.Quote := 'Своя цитата A'; Note.Place := 'Страница собственной книги'; Note.Position := 10;
      NoteID := Notes.Put(Note);
      Note.ID := NoteID;
      SetLength(ProtectedNotes, Length(ProtectedNotes) + 1);
      ProtectedNotes[High(ProtectedNotes)] := Note;
      if LegacyIdentity <> '' then
      begin
        LegacyNote := Default(TReaderAnnotation); LegacyNote.BookID := LegacyIdentity;
        LegacyNote.BookTitle := 'Legacy ambiguous raw numeric history';
        LegacyNote.Text := 'Keep legacy numeric note — ё, ї, ў'; LegacyNote.Quote := 'Keep legacy numeric quote';
        LegacyNote.Position := 4242; LegacyNote.ID := Notes.Put(LegacyNote);
        SetLength(ProtectedNotes, Length(ProtectedNotes) + 1);
        ProtectedNotes[High(ProtectedNotes)] := LegacyNote;
      end;
    finally Notes.Free; end;
    NotesHash := THashSHA2.GetHashStringFromFile(NotesFile);

    MenuItem.Tag := CID; frmMain.miActiveCollectionClick(MenuItem);
    Trace('initial-positive-actions', Saved.GetBookFileName);
    MainExport('proven-same-physical', SourceA);
    SelectSavedCard; ReadViaMain(False);
    Collection.GetBookRecord(Saved.BookKey, Stored, True);
    Require((Stored.Progress = Driver.LastReaderProgress) and (Stored.Progress > 0) and
      (Stored.Progress <> 37), 'Main positive same-physical callback did not persist its exact progress');
    CheckProtected(Driver.LastReaderProgress);
    Collection.SetProgress(Saved.BookKey, 37); CheckProtected(37);
    SelectSavedCard; ReadViaMain(True);
    Collection.GetBookRecord(Saved.BookKey, Stored, True);
    if TrustedReplacement then
    begin
      Require((Stored.Progress = Driver.LastReaderProgress) and (Stored.Progress > 0) and
        (Stored.Progress <> 7), 'Main trusted stable callback rejected the same logical book or changed its progress');
      CheckProtected(Driver.LastReaderProgress);
      MainExport('proven-stable-after-reimport', SourceB);
    end
    else
    begin
      Require(Stored.Progress = 7, 'Late Main reader callback overwrote foreign replacement B progress');
      Require(not ReaderBookMatchesCatalog(Collection, Saved), 'Unknown saved identity authorized unrelated replacement B');
      ExpectedProgress := Driver.LastReaderProgress;
      CheckProtected(ExpectedProgress);
      MainExport('unsafe-after-reimport', '');
      SelectSavedCard; Driver.Messages.Clear; frmMain.EditBookExecute(nil);
      Require(Driver.HasMessage('больше не совпадает с каталогом'), 'Main editor did not explain its group identity guard');
      SystemDB.SetLocal(Saved.BookKey, False);
      SelectSavedCard;
      QueueCount := TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount;
      frmMain.Add2DownloadListExecute(nil);
      Require(TGBIBookTreeAccess(frmMain.tvDownloadList).RootNodeCount = QueueCount,
        'Main queued a foreign download from a reused saved group ID');
      Require(frmMain.tvBooksF.CheckState[Node] in [csCheckedNormal, csCheckedPressed],
        'Main download rejection removed the unsafe saved group selection mark');
      SystemDB.SetLocal(Saved.BookKey, True);
      SelectSavedCard; ReadViaMain(False);
      Collection.GetBookRecord(Saved.BookKey, Stored, True);
      Require(Stored.Progress = 7, 'Reading existing saved A after replacement wrote progress into B');
      ExpectedProgress := Driver.LastReaderProgress;
      CheckProtected(ExpectedProgress);
      SelectSavedCard;
      frmMain.BookSetRateExecute(frmMain.acBookSetRate5);
      ExpectedRate := 5; CheckForeignCatalog; CheckProtected(ExpectedProgress);
      SelectSavedCard; frmMain.MarkAsReadedExecute(nil);
      ExpectedProgress := 100; CheckForeignCatalog; CheckProtected(ExpectedProgress);
      SelectSavedCard;
      MainReview('Свой новый отзыв A' + sLineBreak + 'Вторая строка ё, ї, ў',
        'Своя новая аннотация A', False);
      SystemDB.GetBookRecord(Saved.BookKey, Stored);
      Require((GBINormalizeMemoText(Stored.Review) = GBINormalizeMemoText(Driver.ReviewText)) and
        (GBINormalizeMemoText(Stored.Annotation) = GBINormalizeMemoText(Driver.AnnotationText)),
        'Main group review/annotation edits were not saved on personal card A');
      Saved.Review := Stored.Review; Saved.Annotation := Stored.Annotation;
      CheckProtected(ExpectedProgress);
      SelectSavedCard;
      var DraftFolder := TPath.Combine(Settings.DataDir, 'ReviewDrafts');
      var DraftCount := 0;
      if DirectoryExists(DraftFolder) then DraftCount := Length(TDirectory.GetFiles(DraftFolder, '*.txt'));
      MainReview('Несохранённый отзыв A' + sLineBreak + 'Черновик нужно сохранить точно',
        'Несохранённая аннотация A — ё, ї, ў', True);
      Require(DirectoryExists(DraftFolder), 'Rejected group review did not create its durable draft folder');
      var DraftFiles := TDirectory.GetFiles(DraftFolder, '*.txt');
      Require(Length(DraftFiles) = DraftCount + 1, 'Rejected group review did not retain a new durable draft');
      var FoundDraft := False;
      for var Draft in DraftFiles do
      begin
        var DraftText := TFile.ReadAllText(Draft, TEncoding.UTF8);
        if DraftText.Contains(Driver.ReviewText) and DraftText.Contains(Driver.AnnotationText) and
          DraftText.Contains(Saved.Title) then FoundDraft := True;
      end;
      Require(FoundDraft, 'Rejected Main review draft lost its book title, exact review or annotation');
      SystemDB.GetBookRecord(Saved.BookKey, Stored);
      Require((Stored.Title = Current.Title) and (Stored.Review = Current.Review) and
        (Stored.Annotation = Current.Annotation) and (Stored.Rate = Current.Rate) and
        (Stored.Progress = Current.Progress), 'Rejected review mutated a mismatched system card');
      // Undo only this fixture's deliberately corrupted user card. The draft
      // remains durable and the replacement catalog has never been edited.
      Saved.Rate := ExpectedRate; Saved.Progress := ExpectedProgress;
      SystemDB.UpdateBook(Saved);
      CheckForeignCatalog; CheckProtected(ExpectedProgress);
      SelectSavedCard;
      var PreservedDraftFolder := DraftFolder + '-fixture-preserved-' + TGUID.NewGuid.ToString;
      var PriorDrafts := TDirectory.GetFiles(DraftFolder, '*.txt');
      var PriorDraftHashes := TStringList.Create;
      try
        for var PriorDraft in PriorDrafts do PriorDraftHashes.Add(
          ExtractFileName(PriorDraft) + '=' + THashSHA2.GetHashStringFromFile(PriorDraft));
        Require(IncludeTrailingPathDelimiter(ExpandFileName(DraftFolder)).StartsWith(
          IncludeTrailingPathDelimiter(ExpandFileName(Settings.AppPath)), True),
          'Draft fault paths must stay inside the private G runtime');
        TDirectory.Move(DraftFolder, PreservedDraftFolder);
        TFile.WriteAllText(DraftFolder, 'Private G fixture draft blocker', TEncoding.UTF8);
        Driver.DraftFaultPath := DraftFolder; Driver.DraftPreservedFolder := PreservedDraftFolder;
        try
          MainReview('Отзыв A после ошибки сохранения' + sLineBreak + 'Точный текст повторной попытки',
            'Аннотация A после ошибки сохранения — ё, ї, ў', True, True);
          var RetriedDrafts := TDirectory.GetFiles(DraftFolder, '*.txt');
          Require(Length(RetriedDrafts) = Length(PriorDrafts) + 1,
            'Successful draft retry lost older drafts or created duplicate new drafts');
          var RetryFound := False;
          for var RetriedDraft in RetriedDrafts do
          begin
            var RetriedText := TFile.ReadAllText(RetriedDraft, TEncoding.UTF8);
            if RetriedText.Contains(Driver.ReviewText) and RetriedText.Contains(Driver.AnnotationText) and
              RetriedText.Contains(Saved.Title) then RetryFound := True;
          end;
          Require(RetryFound, 'Retried durable draft lost exact review/annotation input');
          for var I := 0 to PriorDraftHashes.Count - 1 do
            Require(THashSHA2.GetHashStringFromFile(TPath.Combine(DraftFolder, PriorDraftHashes.Names[I])) =
              PriorDraftHashes.ValueFromIndex[I], 'Draft retry changed a prior draft');
          SystemDB.GetBookRecord(Saved.BookKey, Stored);
          Require((Stored.Title = Current.Title) and (Stored.Review = Current.Review) and
            (Stored.Annotation = Current.Annotation), 'Retried rejected review wrote into the mismatched system card');
          CheckForeignCatalog;
        finally
          Driver.DraftRetryExpected := False;
          // Restore the deliberately injected path fault even when a gate
          // assertion fails. Existing drafts are moved back, never deleted.
          if FileExists(DraftFolder) and not DirectoryExists(DraftFolder) then
          begin
            Require(TFile.ReadAllText(DraftFolder, TEncoding.UTF8) = 'Private G fixture draft blocker',
              'Refusing to remove an unexpected draft path file');
            TFile.Delete(DraftFolder);
          end;
          if DirectoryExists(PreservedDraftFolder) and not DirectoryExists(DraftFolder) then
            TDirectory.Move(PreservedDraftFolder, DraftFolder);
          SystemDB.UpdateBook(Saved);
        end;
        CheckForeignCatalog; CheckProtected(ExpectedProgress);
      finally PriorDraftHashes.Free; end;
      // Keep a positive saved group card selected while another collection is
      // active. A late programmatic memo update must respect the real readonly
      // UI state and retain its text, without writing to either A or B.
      MenuItem.Tag := PreviousCID; frmMain.miActiveCollectionClick(MenuItem);
      SelectSavedCard;
      var ReadOnlyDraftCount := Length(TDirectory.GetFiles(DraftFolder, '*.txt'));
      MainReview('Поздний отзыв в режиме только чтения A' + sLineBreak + 'Не записывать его в чужую книгу',
        'Поздняя аннотация только чтения A', False, False, True);
      var ReadOnlyDrafts := TDirectory.GetFiles(DraftFolder, '*.txt');
      Require(Length(ReadOnlyDrafts) = ReadOnlyDraftCount + 1,
        'Readonly late review change did not retain exactly one durable draft');
      var ReadOnlyDraftFound := False;
      for var Draft in ReadOnlyDrafts do
      begin
        var Text := TFile.ReadAllText(Draft, TEncoding.UTF8);
        if Text.Contains(Driver.ReviewText) and Text.Contains(Driver.AnnotationText) and
          Text.Contains(Saved.Title) then ReadOnlyDraftFound := True;
      end;
      Require(ReadOnlyDraftFound, 'Readonly review draft lost the late memo input');
      CheckForeignCatalog; CheckProtected(ExpectedProgress);
      MenuItem.Tag := CID; frmMain.miActiveCollectionClick(MenuItem);
    end;
    ExpectedWorkerExport;
    TFile.WriteAllText(TPath.Combine(Folder, 'dialog-diagnostics.txt'),
      'Messages:' + sLineBreak + Copy(Driver.Messages.Text, 1, 6000) + sLineBreak +
      'Unexpected:' + sLineBreak + Copy(Driver.Unexpected.Text, 1, 6000), TEncoding.UTF8);
    Require(Driver.Unexpected.Count = 0, 'Unexpected Main fixture dialogs: ' + Driver.Unexpected.Text);
    CatalogFile := SystemDB.GetCollectionInfo(CID).DBFileName;
    Writeln('PASS Main saved group identity ', LabelText, ' trusted=', Ord(TrustedReplacement),
      ' guards selection/export/edit/download and late callbacks; original physical reading, notes and marks retained; catalog=', CatalogFile);
  end;

begin
  RequireIsolatedRegression;
  Require((Subcase = '') or MatchText(Subcase,
    ['empty', 'zero', 'trusted', 'rawunknown', 'download-matching', 'download-before-worker',
     'download-during-response', 'download-legacy-matching', 'download-legacy-replacement',
     'download-posted-completion', 'manager-cancel-before-loop', 'manager-cancel-after-success',
     'manager-cancel-during-interval', 'manager-matching-count']), 'Unknown isolated Main identity subcase: ' + Subcase);
  Require(SameText(Copy(ExpandFileName(Settings.AppPath), 1, 3), 'G:\'),
    'Group identity fixture must run on its isolated G: runtime');
  PreviousCID := Settings.ActiveCollection;
  SavedDevice := Settings.DeviceDir; SavedPrompt := Settings.PromptDevicePath;
  SavedFileTemplate := Settings.FileNameTemplate; SavedFolderTemplate := Settings.FolderTemplate;
  SavedReadDir := Settings.ReadDir; SavedInpxURL := Settings.InpxURL;
  SavedAutoStart := Settings.AutoStartDwnld; SavedOverwrite := Settings.OverwriteFB2Info;
  SavedBuiltin := Settings.UseBuiltinReaderByDefault; SavedHideDeleted := Settings.HideDeletedBooks;
  SavedLatestCommonDialogs := Vcl.Dialogs.UseLatestCommonDialogs;
  Driver := TGBIMainDriver.Create; MenuItem := TMenuItem.Create(nil); ExportItem := TMenuItem.Create(nil);
  try
    // Exercise the actual Main MessageDlg calls with the VCL message form.
    // Its ordinary label exposes the real content to this in-process fixture;
    // native TaskDialog's DirectUI content is not available via GetWindowText.
    // Production dialog behavior and every message/content assertion stay intact.
    Vcl.Dialogs.UseLatestCommonDialogs := False;
    Settings.PromptDevicePath := False; Settings.AutoStartDwnld := False;
    Settings.FileNameTemplate := '%t'; Settings.FolderTemplate := '';
    Settings.OverwriteFB2Info := False; Settings.UseBuiltinReaderByDefault := True;
    Settings.HideDeletedBooks := False; Settings.InpxURL := 'http://127.0.0.1:9/';
    Settings.ReadDir := TPath.Combine(Settings.AppPath, 'group-identity-reading-cache');
    ExportItem.Tag := 850;
    // Each separately launched subcase still proves preservation of existing
    // notes belonging to another book, not just its newly inserted own note.
    var ExistingNotes := TReaderAnnotations.Create(ResolveReaderSettingsFile(Settings.DataDir));
    try
      var ExistingNote := Default(TReaderAnnotation);
      ExistingNote.BookID := 'unrelated-before-identity-fixture-' + TGUID.NewGuid.ToString;
      ExistingNote.BookTitle := 'Existing unrelated book'; ExistingNote.Position := 321;
      ExistingNote.Text := 'Existing unrelated thought — ё, ї, ў'; ExistingNote.Quote := 'Keep unrelated original quote';
      ExistingNote.ID := ExistingNotes.Put(ExistingNote);
      SetLength(ProtectedNotes, 1); ProtectedNotes[0] := ExistingNote;
    finally ExistingNotes.Free; end;
    if (Subcase = '') or SameText(Subcase, 'empty') then RunScenario('empty', '', False);
    if (Subcase = '') or SameText(Subcase, 'zero') then RunScenario('zero', '0', False);
    if (Subcase = '') or SameText(Subcase, 'rawunknown') then RunScenario('rawunknown', '42', False);
    if (Subcase = '') or SameText(Subcase, 'trusted') then RunScenario('trusted', 'flibusta:42', True);
    if (Subcase = '') or Subcase.StartsWith('download-', True) then
    begin
      var TimerWasEnabled:=Driver.Timer.Enabled;
      Driver.Timer.Enabled:=False;
      try
        if Subcase = '' then TestSavedDownloadIdentity
        else TestSavedDownloadIdentity(Copy(Subcase, Length('download-') + 1, MaxInt));
      finally Driver.Timer.Enabled:=TimerWasEnabled; end;
    end;
    if Subcase = '' then TestQueuedDownloadCancellation
    else if Subcase.StartsWith('manager-', True) then
      TestQueuedDownloadCancellation(Copy(Subcase, Length('manager-') + 1, MaxInt));
    var AllNotes := TReaderAnnotations.Create(ResolveReaderSettingsFile(Settings.DataDir));
    try
      for var Expected in ProtectedNotes do
      begin
        var Found := False;
        for var Actual in AllNotes.Items(Expected.BookID) do
          if Actual.ID = Expected.ID then
          begin
            Found := True;
            Require((Actual.Text = Expected.Text) and (Actual.Quote = Expected.Quote) and
              (Actual.BookTitle = Expected.BookTitle), 'A later group scenario overwrote an earlier saved note');
          end;
        Require(Found, 'A later group scenario deleted an earlier saved note');
      end;
    finally AllNotes.Free; end;
  finally
    Driver.Free; ExportItem.Free;
    Vcl.Dialogs.UseLatestCommonDialogs := SavedLatestCommonDialogs;
    MenuItem.Tag := PreviousCID; frmMain.miActiveCollectionClick(MenuItem); MenuItem.Free;
    Settings.DeviceDir := SavedDevice; Settings.PromptDevicePath := SavedPrompt;
    Settings.FileNameTemplate := SavedFileTemplate; Settings.FolderTemplate := SavedFolderTemplate;
    Settings.ReadDir := SavedReadDir; Settings.InpxURL := SavedInpxURL;
    Settings.AutoStartDwnld := SavedAutoStart; Settings.OverwriteFB2Info := SavedOverwrite;
    Settings.UseBuiltinReaderByDefault := SavedBuiltin; Settings.HideDeletedBooks := SavedHideDeleted;
  end;
end;
