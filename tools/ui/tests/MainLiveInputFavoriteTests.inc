// Actual Main input, favorite affordances and color-only loaded-list regressions.
// Include after AddBook and TProfileBooks; extra uses: VirtualTrees.BaseTree.
// Parent runs each procedure in its own guarded G profile/native mode.
type
  TMLIToolbarAccess = class(TToolBar);
  TMLIMainWindowAccess = class(TfrmMain);

  TMLIFavoritePumpProbe = class
  public
    QueueReadyCount, QueueProgressCount, UpdateReadyCount, DestroyCount: Integer;
    InitialWindow, LastReadyWindow, UpdateReadyWindow: HWND;
    LastGeneration: NativeInt;
    LastReadyToken: NativeUInt;
  end;

  TMLIInputProbe = class
  public
    Edit: TCustomEdit;
    Loading: Boolean;
    TimerCalls, TimerCallsDuringLoad: Integer;
    DuringText: string;
    procedure TimerTick(Sender: TObject);
  end;

  TMLIInjectedBooks = class(TInterfacedObject, IBookIterator)
  private
    FIndex: Integer;
    FBook: TBookRecord;
    FProbe: TMLIInputProbe;
  public
    constructor Create(const Book: TBookRecord; Probe: TMLIInputProbe);
    function Next(out Book: TBookRecord): Boolean;
    function RecordCount: Integer;
  end;

  TMLIMetricBooks = class(TInterfacedObject, IBookIterator)
  private
    FBooks: TArray<TBookRecord>;
    FIndex: Integer;
  public
    constructor Create(const Books: TArray<TBookRecord>);
    function Next(out Book: TBookRecord): Boolean;
    function RecordCount: Integer;
  end;

  TMLIMenuProgressProbe = class
  public
    Timer: TTimer;
    ExpectedCaption, Failure, ChoiceExtension: string;
    Deadline: UInt64;
    procedure Tick(Sender: TObject);
    function MessageReceived(const Text: string; Flags: Longint = MB_OK): Integer;
  end;

  TMLIPublisherProgressProbe = class
  public
    Timer: TTimer;
    Failure: string;
    Deadline: UInt64;
    procedure Tick(Sender: TObject);
  end;

  TMLIThemeNodeProbe = class
  public
    Original: TVTInitNodeEvent;
    Visits, ReinitVisits: Integer;
    TraceCalls: Boolean;
    procedure InitNode(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode;
      var States: TVirtualNodeInitStates);
  end;

  TMLIToolbarForwardProbe = class
  public
    DrawCalls, ButtonCalls: Integer;
    procedure Draw(Sender: TToolBar; const Bounds: TRect; var DefaultDraw: Boolean);
    procedure DrawButton(Sender: TToolBar; Button: TToolButton;
      State: TCustomDrawState; var DefaultDraw: Boolean);
  end;

  TMLIToolbarNativeProbe = class
  public
    OriginalDraw: TTBCustomDrawEvent;
    OriginalButton: TTBCustomDrawBtnEvent;
    ExpectedDC: HDC;
    TargetButton: TToolButton;
    DrawCalls, ButtonCalls: Integer;
    procedure Draw(Sender: TToolBar; const Bounds: TRect; var DefaultDraw: Boolean);
    procedure DrawButton(Sender: TToolBar; Button: TToolButton;
      State: TCustomDrawState; var DefaultDraw: Boolean);
  end;

var
  MLIFavoriteQueueHookHandle, MLIFavoriteWindowHookHandle: HHOOK;
  MLIFavoriteQueueProbe: TMLIFavoritePumpProbe;

function MLIFavoriteQueueHook(Code: Integer; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
var Item: PMsg; Probe: TMLIFavoritePumpProbe;
begin
  if (Code >= 0) and (WParam = PM_REMOVE) and Assigned(MLIFavoriteQueueProbe) then
  begin
    Item:=PMsg(LParam); Probe:=MLIFavoriteQueueProbe;
    if Item.message=WM_PROGRAM_UPDATE_CHECKED then
    begin
      Inc(Probe.UpdateReadyCount); Probe.UpdateReadyWindow:=Item.hwnd;
      Writeln('TRACE update producer queued hwnd=',NativeUInt(Item.hwnd),' count=',Probe.UpdateReadyCount); Flush(Output);
    end;
    if (Item.message=WM_AUTHOR_FAVORITES_READY) or (Item.message=WM_AUTHOR_FAVORITES_PROGRESS) then
    begin
      if Item.wParam<>0 then
        if Item.message=WM_AUTHOR_FAVORITES_READY then
        begin
          Inc(Probe.QueueReadyCount); Probe.LastReadyWindow:=Item.hwnd;
          Probe.LastReadyToken:=Item.wParam; Probe.LastGeneration:=Item.lParam;
        end
        else Inc(Probe.QueueProgressCount);
      if Probe.QueueReadyCount+Probe.QueueProgressCount<=32 then
      begin
        Writeln('TRACE favorite queued hwnd=',NativeUInt(Item.hwnd),' initial=',NativeUInt(Probe.InitialWindow),
          ' message=',Item.message,' token=',NativeUInt(Item.wParam),' generation=',NativeInt(Item.lParam)); Flush(Output);
      end;
    end;
  end;
  Result:=CallNextHookEx(MLIFavoriteQueueHookHandle,Code,WParam,LParam);
end;

function MLIFavoriteWindowHook(Code: Integer; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  if (Code=HCBT_DESTROYWND) and Assigned(MLIFavoriteQueueProbe) and
    (HWND(WParam)=MLIFavoriteQueueProbe.InitialWindow) then
  begin
    Inc(MLIFavoriteQueueProbe.DestroyCount);
    Writeln('TRACE favorite main HWND destroyed initial=',NativeUInt(WParam)); Flush(Output);
  end;
  Result:=CallNextHookEx(MLIFavoriteWindowHookHandle,Code,WParam,LParam);
end;

procedure TMLIInputProbe.TimerTick(Sender: TObject);
begin
  Inc(TimerCalls);
  if Loading then Inc(TimerCallsDuringLoad);
end;

constructor TMLIInjectedBooks.Create(const Book: TBookRecord; Probe: TMLIInputProbe);
begin inherited Create; FBook:=Book; FProbe:=Probe; end;

function TMLIInjectedBooks.RecordCount: Integer;
begin Result:=600; end;

function TMLIInjectedBooks.Next(out Book: TBookRecord): Boolean;
begin
  Result:=FIndex<RecordCount; if not Result then Exit;
  Inc(FIndex); Book:=FBook;
  if FIndex=1 then
  begin
    // An untyped Ord('т') is an ANSI ordinal in this Delphi compiler ($F2).
    // Queue the actual Unicode WM_CHAR codepoint on the Unicode edit window.
    Require(IsWindowUnicode(FProbe.Edit.Handle),'Locate input is not a Unicode native window');
    Require(PostMessageW(FProbe.Edit.Handle,WM_CHAR,$0442,1), 'Unable to queue native Cyrillic input');
    // PollBookListCancel intentionally throttles to16ms. Complete one interval
    // before its first actual poll; do not pump any messages in this fixture.
    TThread.Sleep(20);
  end
  else if FIndex=2 then FProbe.DuringText:=FProbe.Edit.Text;
end;

constructor TMLIMetricBooks.Create(const Books: TArray<TBookRecord>);
begin inherited Create; FBooks:=Copy(Books); end;

function TMLIMetricBooks.Next(out Book: TBookRecord): Boolean;
begin
  Result:=FIndex<Length(FBooks);
  if Result then begin Book:=FBooks[FIndex]; Inc(FIndex); end;
end;

function TMLIMetricBooks.RecordCount: Integer;
begin Result:=Length(FBooks); end;

procedure TMLIThemeNodeProbe.InitNode(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode;
  var States: TVirtualNodeInitStates);
type TCaptureStack = function(Skip, Count: Cardinal; Frames: Pointer; Hash: Pointer): Word; stdcall;
var Capture: TCaptureStack; Frames: array[0..9] of Pointer; Count, I: Integer; Address: NativeUInt;
begin
  Inc(Visits);
  if ivsReInit in States then Inc(ReinitVisits);
  if TraceCalls and (Visits<=3) then
  begin
    Writeln('TRACE theme node init visit=',Visits,' reinit=',Ord(ivsReInit in States),
      ' tree=',Sender.Name,' nodeheight=',Node.NodeHeight,' default=',TBookTree(Sender).DefaultNodeHeight); Flush(Output);
    if Visits=1 then
    begin
      Capture:=TCaptureStack(GetProcAddress(GetModuleHandleW('kernel32.dll'),'RtlCaptureStackBackTrace'));
      if Assigned(Capture) then
      begin
        Count:=Capture(1,Length(Frames),@Frames[0],nil);
        for I:=0 to Count-1 do
        begin
          Address:=NativeUInt(Frames[I]);
          if (Address>=NativeUInt(HInstance)) and (Address-NativeUInt(HInstance)<$4000000) then
            Writeln('TRACE theme node caller RVA ',IntToHex(Address-NativeUInt(HInstance),8));
        end;
        Flush(Output);
      end;
    end;
  end;
  if Assigned(Original) then Original(Sender,ParentNode,Node,States);
end;

function MLIReadCatalogData(CID: Integer): string;
var DB: TSQLiteDatabase; Q: TSQLiteQuery;
begin
  Result:=''; DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(CID).DBFileName);
  try
    for var TableName in TArray<string>.Create('Books','Authors','Author_List','Series','Series_List','Genre_List') do
    begin
      Q:=DB.NewQuery('SELECT * FROM "'+TableName+'" ORDER BY rowid');
      try
        Q.Open; Result:=Result+TableName+#10;
        while not Q.Eof do
        begin
          for var I:=0 to Q.ColCount-1 do
          begin
            var Value:=Q.FieldAsString(I); Result:=Result+IntToStr(Length(Value))+':'+Value;
          end;
          Result:=Result+#10; Q.Next;
        end;
      finally Q.Free; end;
    end;
  finally DB.Free; end;
end;

function MLIHasAuthorIndicator(Tree: TBookTree): Boolean;
begin
  Result:=False;
  for var Tag in Tree.HeaderFilteredTags do if Tag=COL_AUTHOR then Exit(True);
end;

function MLIHeaderBluePixels(Tree: TBookTree): Integer;
var Bitmap: TBitmap; Png: TPngImage; L,R: TDimension; Column: Integer; Artifacts: string;
begin
  Column:=-1;
  for var I:=0 to Tree.Header.Columns.Count-1 do
    if Tree.Header.Columns[I].Tag=COL_AUTHOR then Column:=I;
  Require(Column>=0,'Author column is absent from the native header oracle');
  Tree.Header.Columns.GetColumnBounds(Column,L,R);
  Bitmap:=TBitmap.Create;
  try
    Bitmap.PixelFormat:=pf32bit; Bitmap.SetSize(Tree.Width,Tree.Height);
    Bitmap.Canvas.Brush.Color:=clFuchsia; Bitmap.Canvas.FillRect(Rect(0,0,Bitmap.Width,Bitmap.Height));
    Require(GetObjectType(Bitmap.Canvas.Handle)=OBJ_MEMDC,'Native header capture has no valid memory DC');
    // VirtualTrees paints its nonclient header in WM_PRINT, not client WM_PAINT
    // used by generic TWinControl.PaintTo (BaseTree.WMPrint is the native path).
    SendMessageW(Tree.Handle,WM_PRINT,WPARAM(Bitmap.Canvas.Handle),PRF_NONCLIENT or PRF_CLIENT or PRF_ERASEBKGND);
    Require(GetObjectType(Bitmap.Canvas.Handle)=OBJ_MEMDC,'Native header printing invalidated its target DC');
    Require(ColorToRGB(Bitmap.Canvas.Pixels[Max(0,L+2),Tree.Header.Height div 2])<>ColorToRGB(clFuchsia),
      'Native header printing did not paint the author column surface');
    Result:=0;
    for var Y:=Max(0,Tree.Header.Height div 2-8) to Min(Bitmap.Height-1,Tree.Header.Height div 2+8) do
      for var X:=Max(0,R-27) to Min(Bitmap.Width-1,R-10) do
        if ColorToRGB(Bitmap.Canvas.Pixels[X,Y])=RGB(43,91,143) then Inc(Result);
    Artifacts:=TPath.Combine(Settings.AppPath,'favorite-funnel-pixels'); ForceDirectories(Artifacts);
    Png:=TPngImage.Create;
    try
      Png.Assign(Bitmap); Png.SaveToFile(TPath.Combine(Artifacts,'funnel-dark-'+IntToStr(Ord(MHLThemeDark))+
        '-active-'+IntToStr(Ord(MLIHasAuthorIndicator(Tree)))+'.png'));
    finally Png.Free; end;
    Writeln('TRACE author funnel pixels active=',Ord(MLIHasAuthorIndicator(Tree)),' dark=',Ord(MHLThemeDark),
      ' count=',Result,' column=',Column,' bounds=',L,',',R,' tree=',Tree.Width,'x',Tree.Height,
      ' headerheight=',Tree.Header.Height,' ppi=',Tree.Font.PixelsPerInch,
      ' visible=',Ord(Tree.Visible),' tags=',Length(Tree.HeaderFilteredTags)); Flush(Output);
  finally Bitmap.Free; end;
end;

procedure TestMainLiveLocateInput(const One: IBookCollection; OneID: Integer);
var Book: TBookRecord; BookID: Integer; Publisher: TPublisherSeriesView;
  Series: TBookSeries; OriginalPage, OriginalMode: Integer; Before: string;

  procedure RunInput(Edit: TCustomEdit; Timer: TTimer; const Context: string);
  var Probe: TMLIInputProbe; Iterator: IBookIterator; SavedTimer: TNotifyEvent;
  begin
    Probe:=TMLIInputProbe.Create; SavedTimer:=Timer.OnTimer;
    try
      Timer.Enabled:=False; Probe.Edit:=Edit; Edit.Text:='дос'; frmMain.ActiveControl:=Edit;
      // Focus can AutoSelect the text; place the insertion caret afterwards.
      Edit.SelStart:=Length(Edit.Text); Edit.SelLength:=0;
      Require((Edit.Text='дос') and (Edit.SelStart=3) and (Edit.SelLength=0),
        'Native locate input did not start with an insertion caret after its complete prefix');
      Writeln('TRACE native input ',Context,' unicode=',Ord(IsWindowUnicode(Edit.Handle)),
        ' queued=0442 caret=',Edit.SelStart,' selected=',Edit.SelLength); Flush(Output);
      Timer.OnTimer:=Probe.TimerTick; Probe.Loading:=True;
      Iterator:=TMLIInjectedBooks.Create(Book,Probe);
      frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Iterator,False,False,nil);
      Probe.Loading:=False;
      Writeln('TRACE native input result ',Context,' during=',Probe.DuringText,' final=',Edit.Text,
        ' caret=',Edit.SelStart,' selected=',Edit.SelLength); Flush(Output);
      Require((Probe.DuringText='дост') and (Edit.Text='дост'),
        'Native input was lost while loading '+Context+': during='+Probe.DuringText+' final='+Edit.Text);
      Require((Probe.TimerCallsDuringLoad=0) and not frmMain.BookListCancelled,
        'Typing re-entered a timer or cancelled the active '+Context+' query');
      Require(frmMain.tvBooksSR.TotalCount=600,'Typing replaced or interrupted the current book list');
      Require(Timer.Enabled,'The complete new input was not scheduled for the next locate query');
      TThread.Sleep(Timer.Interval+30); Application.ProcessMessages;
      Require(Probe.TimerCalls>0,'Deferred locate timer did not resume after '+Context+' loading');
      Writeln('PASS native '+Context+' preserves Cyrillic input during loading and defers its next query'); Flush(Output);
    finally
      Probe.Loading:=False; Timer.Enabled:=False; Timer.OnTimer:=SavedTimer;
      Iterator:=nil; Probe.Free;
    end;
  end;

begin
  RequireIsolatedRegression; Require(Settings.ActiveCollection=OneID,'Live-input fixture has wrong collection');
  OriginalPage:=frmMain.pgControl.ActivePageIndex; OriginalMode:=Ord(Settings.TreeModes[PAGE_SEARCH]);
  BookID:=AddBook(One,'Live-input Dost','Достоевский','ru','Достоинство','prose_contemporary');
  One.GetBookRecord(CreateBookKey(BookID,OneID),Book,False);
  TSeriesHelper.Add(Series,0,'Достойные книги',1,False); One.SetBookPublisherSeries(Book.BookKey,Series);
  Before:=MLIReadCatalogData(OneID); Publisher:=nil;
  for var Component in frmMain do if Component is TPublisherSeriesView then Publisher:=TPublisherSeriesView(Component);
  Require(Assigned(Publisher),'Live-input publisher series view is absent');
  try
    Settings.TreeModes[PAGE_SEARCH]:=tmFlat; TBookColumnFilters.ForTree(frmMain.tvBooksSR).Clear;
    frmMain.pgControl.ActivePage:=frmMain.tsByAuthor; frmMain.pgControlChange(nil);
    RunInput(frmMain.edLocateAuthor,frmMain.tmrSearchA,'author locate');
    frmMain.tmrSearchATimer(nil);
    var Author: PAuthorData:=frmMain.tvAuthors.GetNodeData(frmMain.tvAuthors.GetFirstSelected);
    Require(Assigned(Author) and (Author.LastName='Достоевский'),'Resumed author query ignored the last typed letter');
    frmMain.pgControl.ActivePage:=frmMain.tsBySerie; frmMain.pgControlChange(nil);
    RunInput(frmMain.edLocateSeries,frmMain.tmrSearchS,'series locate'); frmMain.tmrSearchSTimer(nil);
    var FoundSeries: PSeriesData:=frmMain.tvSeries.GetNodeData(frmMain.tvSeries.GetFirstSelected);
    Require(Assigned(FoundSeries) and (FoundSeries.SeriesTitle='Достоинство'),'Resumed series query ignored the last typed letter');
    frmMain.pgControl.ActivePage:=Publisher.Tab; frmMain.pgControlChange(nil);
    RunInput(Publisher.Search,Publisher.SearchTimer,'publisher series locate');
    Publisher.SearchTimer.OnTimer(Publisher.SearchTimer);
    FoundSeries:=Publisher.SeriesTree.GetNodeData(Publisher.SeriesTree.GetFirstSelected);
    Require(Assigned(FoundSeries) and (FoundSeries.SeriesTitle='Достойные книги'),'Resumed publisher query ignored complete input');
    Require(MLIReadCatalogData(OneID)=Before,'Live locate changed catalog contents or personal book fields');
    Writeln('PASS latest complete author, series and publisher criteria resume without catalog mutations'); Flush(Output);
  finally
    Settings.TreeModes[PAGE_SEARCH]:=TTreeMode(OriginalMode);
    frmMain.pgControl.ActivePageIndex:=OriginalPage;
  end;
end;

procedure TestFavoriteAuthorAffordances(const One: IBookCollection; OneID: Integer);
var SearchCheck: TCheckBox; Heart, NewButton: TButton; StopItem, ViewedItem: TMenuItem;
  OriginalTheme: Boolean; InitialCatalog, Profile: string; AlphaNode, BetaNode: PVirtualNode;
  Data: PAuthorData; Filters: TBookColumnFilters; Pump: TMLIFavoritePumpProbe;

  procedure ResolveAuthorRows;
  var Node: PVirtualNode;
  begin
    AlphaNode:=nil; BetaNode:=nil; Node:=frmMain.tvAuthors.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvAuthors.GetNodeData(Node);
      if Data.LastName='Alpha' then AlphaNode:=Node else if Data.LastName='Beta' then BetaNode:=Node;
      Node:=frmMain.tvAuthors.GetNext(Node);
    end;
    Require(Assigned(AlphaNode) and Assigned(BetaNode),'Favorite affordance fixture lost its current author rows');
  end;

  procedure AttachPump;
  begin
    // Finish already queued VCL style recreation before observing the worker.
    // The separate CBT observer does not replace the style's WindowProc chain.
    Application.ProcessMessages; CheckSynchronize(0);
    Require((MLIFavoriteQueueHookHandle=0) and (MLIFavoriteWindowHookHandle=0),
      'Favorite fixture has a stale own-thread observer');
    Pump.InitialWindow:=frmMain.Handle; Pump.QueueReadyCount:=0; Pump.QueueProgressCount:=0;
    Pump.LastReadyWindow:=0; Pump.LastReadyToken:=0; Pump.LastGeneration:=0; Pump.DestroyCount:=0;
    MLIFavoriteQueueProbe:=Pump;
    MLIFavoriteQueueHookHandle:=SetWindowsHookExW(WH_GETMESSAGE,MLIFavoriteQueueHook,0,GetCurrentThreadID);
    Require(MLIFavoriteQueueHookHandle<>0,'Cannot observe the favorite fixture message queue');
    MLIFavoriteWindowHookHandle:=SetWindowsHookExW(WH_CBT,MLIFavoriteWindowHook,0,GetCurrentThreadID);
    Require(MLIFavoriteWindowHookHandle<>0,'Cannot observe own Main window recreation');
    Writeln('TRACE favorite observer attached hwnd=',NativeUInt(Pump.InitialWindow)); Flush(Output);
  end;

  procedure DetachPump;
  begin
    if MLIFavoriteQueueHookHandle<>0 then
    begin UnhookWindowsHookEx(MLIFavoriteQueueHookHandle); MLIFavoriteQueueHookHandle:=0; end;
    if MLIFavoriteWindowHookHandle<>0 then
    begin UnhookWindowsHookEx(MLIFavoriteWindowHookHandle); MLIFavoriteWindowHookHandle:=0; end;
    MLIFavoriteQueueProbe:=nil;
  end;

  procedure WaitReady;
  var Start, NextTrace: UInt64;
  begin
    Start:=GetTickCount64; NextTrace:=Start;
    while StopItem.Enabled do
    begin
      Application.ProcessMessages; CheckSynchronize(0);
      if GetTickCount64>=NextTrace then
      begin
        Writeln('TRACE favorite wait elapsed=',GetTickCount64-Start,' ready=',Pump.QueueReadyCount,
          ' progress=',Pump.QueueProgressCount,' generation=',Pump.LastGeneration,
          ' stop=',Ord(StopItem.Enabled),' status=',frmMain.spStatus.Caption,
          ' hwnd=',NativeUInt(frmMain.Handle),' initial=',NativeUInt(Pump.InitialWindow),
          ' queued=',Pump.QueueReadyCount,'/',Pump.QueueProgressCount,' destroyed=',Pump.DestroyCount); Flush(Output);
        NextTrace:=GetTickCount64+1000;
      end;
      Require(GetTickCount64-Start<10000,'Favorite affordance refresh timed out');
      TThread.Sleep(1);
    end;
    Application.ProcessMessages; CheckSynchronize(0);
    Writeln('TRACE favorite wait complete elapsed=',GetTickCount64-Start,' ready=',Pump.QueueReadyCount,
      ' progress=',Pump.QueueProgressCount,' status=',frmMain.spStatus.Caption); Flush(Output);
    Require((Pump.QueueReadyCount>0) and (Pump.LastReadyToken<>0) and (Pump.LastGeneration>0),
      'Favorite refresh did not deliver its actual worker/token/generation completion');
    Require((Pump.LastReadyWindow<>Pump.InitialWindow) and IsWindow(Pump.LastReadyWindow),
      'Favorite completion still targets the recyclable Main window');
  end;

  procedure TestUpdateProducer(Target: HWND);
  var Server: TGBILoopbackDownload; Worker: TProgramUpdateThread; Started: UInt64; Body: string;
  begin
    // Exercise the real producer and Main's notifier without changing its
    // immutable public API URL or fabricating Main's private worker pointer.
    Require(IsWindow(Target),'Update producer has no surviving Main notifier');
    Body:='[{"tag_name":"2.7.0_pre5.999","draft":false,"body":"Owned loopback release",'+
      '"assets":[{"name":"HomeLibRu.zip"},{"name":"HomeLibRu_x64.zip"}]}]';
    Server:=TGBILoopbackDownload.Create(Body,True); Worker:=nil;
    try
      Require(Server.URL.StartsWith('http://127.0.0.1:'),'Update producer fixture must remain loopback only');
      Pump.InitialWindow:=frmMain.Handle; Pump.DestroyCount:=0;
      Pump.UpdateReadyCount:=0; Pump.UpdateReadyWindow:=0;
      Worker:=TProgramUpdateThread.Create(Target,THTTPClient.Create,Server.URL+'payload-original-A','');
      Worker.Start; Started:=GetTickCount64;
      while Server.Requested.WaitFor(0)<>wrSignaled do
      begin
        Application.ProcessMessages; CheckSynchronize(0); TThread.Sleep(1);
        Require(GetTickCount64-Started<10000,'Actual update producer did not request its own loopback route');
      end;
      TMLIMainWindowAccess(frmMain).RecreateWnd;
      Require(Pump.DestroyCount>0,'Update producer fixture did not recreate the actual Main window');
      Server.Released.SetEvent;
      while Pump.UpdateReadyCount=0 do
      begin
        Application.ProcessMessages; CheckSynchronize(0); TThread.Sleep(1);
        Require(GetTickCount64-Started<10000,'Actual update producer lost completion across Main recreation');
      end;
      Worker.WaitFor;
      Require(Worker.Successful and (Worker.ReleaseInfo.Tag='2.7.0_pre5.999'),
        'Actual loopback update producer did not parse its release');
      Require((Pump.UpdateReadyCount=1) and (Pump.UpdateReadyWindow=Target) and IsWindow(Target) and
        (Server.RequestCount=1) and (Server.Failure=''),
        'Update producer did not deliver exactly once through the surviving Main notifier');
      Writeln('PASS actual update-check producer delivers through stable Main notifier after HWND recreation using only loopback'); Flush(Output);
    finally
      Server.Released.SetEvent;
      if Assigned(Worker) then begin Worker.Terminate; Worker.WaitFor; Worker.Free; end;
      Server.Free;
    end;
  end;

  function HeartPixels(Node: PVirtualNode): Integer;
  var Bitmap: TBitmap; Background: TColor; Cell, Content: TRect; Text: string;
  begin
    Bitmap:=TBitmap.Create;
    try
      Bitmap.PixelFormat:=pf32bit; Bitmap.SetSize(180,32); Bitmap.Canvas.Font.Assign(frmMain.tvAuthors.Font);
      Background:=clWindow; if vsSelected in Node.States then Background:=clHighlight;
      if MHLThemeDark and not (vsSelected in Node.States) then Background:=RGB(30,31,34);
      Bitmap.Canvas.Brush.Color:=Background; Bitmap.Canvas.FillRect(Rect(0,0,180,32));
      Cell:=Rect(0,0,180,32); Content:=Cell;
      Require(Assigned(frmMain.tvAuthors.OnBeforeCellPaint) and Assigned(frmMain.tvAuthors.OnAfterCellPaint),
        'Favorite heart has no independent native paint hooks');
      frmMain.tvAuthors.OnBeforeCellPaint(frmMain.tvAuthors,Bitmap.Canvas,Node,NoColumn,cpmPaint,Cell,Content);
      Require(Content.Left>=18,'Favorite heart can overlap the author name');
      frmMain.tvAuthors.OnAfterCellPaint(frmMain.tvAuthors,Bitmap.Canvas,Node,NoColumn,Cell);
      Result:=0;
      for var Y:=0 to 31 do for var X:=0 to 17 do
        if ColorToRGB(Bitmap.Canvas.Pixels[X,Y])<>ColorToRGB(Background) then Inc(Result);
      Data:=frmMain.tvAuthors.GetNodeData(Node); Text:='';
      frmMain.tvAuthors.OnGetText(frmMain.tvAuthors,Node,NoColumn,ttNormal,Text);
      Require(Text.StartsWith(Data.GetFullName) and not Text.StartsWith('♥'),
        'Painting the favorite heart changed author fullname/copy text');
    finally Bitmap.Free; end;
  end;

begin
  RequireIsolatedRegression; Require(Settings.ActiveCollection=OneID,'Favorite affordance fixture collection mismatch');
  SearchCheck:=frmMain.FindComponent('cbSearchFavoriteAuthorsOnly') as TCheckBox;
  Heart:=frmMain.FindComponent('btnFavoriteSelectedAuthor') as TButton;
  NewButton:=frmMain.FindComponent('btnFavoriteAuthorNew') as TButton;
  StopItem:=frmMain.FindComponent('miFavoriteAuthorStop') as TMenuItem;
  ViewedItem:=frmMain.FindComponent('miFavoriteAuthorViewed') as TMenuItem;
  Require(Assigned(SearchCheck) and Assigned(Heart) and Assigned(NewButton) and Assigned(StopItem) and Assigned(ViewedItem),
    'Favorite affordance controls are absent');
  OriginalTheme:=MHLThemeDark; Profile:=Settings.AppPath+'favorite-indicator-draft.tsv';
  Pump:=TMLIFavoritePumpProbe.Create;
  try
    frmMain.pgControl.ActivePage:=frmMain.tsSearch; frmMain.pgControlChange(nil); frmMain.DoClearFilter(False);
    Filters:=TBookColumnFilters.ForTree(frmMain.tvBooksSR); Filters.Clear;
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark); SearchCheck.Checked:=False; frmMain.SetBookListTotals(frmMain.tvBooksSR,0,0);
      Require(not MLIHasAuthorIndicator(frmMain.tvBooksSR) and (MLIHeaderBluePixels(frmMain.tvBooksSR)=0),
        'Inactive author filter is drawn blue');
      StartSQLiteProfile;
      SearchCheck.Checked:=True;
      var ActiveIndicator:=MLIHasAuthorIndicator(frmMain.tvBooksSR);
      var BluePixels:=MLIHeaderBluePixels(frmMain.tvBooksSR);
      Writeln('TRACE favorite draft checked=',Ord(SearchCheck.Checked),' click=',Ord(Assigned(SearchCheck.OnClick)),
        ' active=',Ord(ActiveIndicator),' pixels=',BluePixels); Flush(Output);
      Require(ActiveIndicator and (BluePixels>15),
        'Favorite Search draft did not immediately draw its author funnel blue');
      SearchCheck.Checked:=False;
      Require(not MLIHasAuthorIndicator(frmMain.tvBooksSR) and (MLIHeaderBluePixels(frmMain.tvBooksSR)=0),
        'Turning off the favorite Search draft retained the blue author funnel');
      Filters.FavoriteAuthorsOnly:=True; frmMain.SetBookListTotals(frmMain.tvBooksSR,0,0);
      SearchCheck.Checked:=True; SearchCheck.Checked:=False;
      Require(MLIHasAuthorIndicator(frmMain.tvBooksSR),'Unchecking draft erased the independently active author column filter');
      Filters.FavoriteAuthorsOnly:=False; Filters.SetValue(COL_AUTHOR,'Alpha'); frmMain.SetBookListTotals(frmMain.tvBooksSR,0,0);
      SearchCheck.Checked:=True; SearchCheck.Checked:=False;
      Require(MLIHasAuthorIndicator(frmMain.tvBooksSR),'Unchecking draft erased an ordinary author column value');
      Filters.Clear; frmMain.SetBookListTotals(frmMain.tvBooksSR,0,0);
      SaveSQLiteProfile(Profile); StopSQLiteProfile;
      {$IFDEF MHL_SQL_PROFILE}
      var Queries:=TStringList.Create;
      try Queries.LoadFromFile(Profile); Require(Queries.Count=1,'Draft favorite indicators queried the catalog before Apply');
      finally Queries.Free; end;
      {$ENDIF}
      Require(frmMain.tvBooksSR.TotalCount=0,'Favorite visual state unexpectedly applied a query');
      Writeln('PASS favorite author funnel actual pixels dark=',Ord(Dark),' toggle without queries and preserve independent column conditions'); Flush(Output);
    end;
    frmMain.pgControl.ActivePage:=frmMain.tsByAuthor; frmMain.pgControlChange(nil);
    // Alphabet buttons belong to the toolbar, not Main.Components.
    for var I:=0 to frmMain.tbarAuthorsRus.ButtonCount-1 do
      if (frmMain.tbarAuthorsRus.Buttons[I].Caption='*') and
        Assigned(frmMain.tbarAuthorsRus.Buttons[I].OnClick) then
        frmMain.tbarAuthorsRus.Buttons[I].OnClick(frmMain.tbarAuthorsRus.Buttons[I]);
    ResolveAuthorRows;
    frmMain.tvAuthors.ClearSelection; frmMain.tvAuthors.Selected[AlphaNode]:=True;
    frmMain.tvAuthors.FocusedNode:=AlphaNode; frmMain.tvAuthorsChange(frmMain.tvAuthors,AlphaNode);
    InitialCatalog:=MLIReadCatalogData(OneID);
    AttachPump;
    try
      Heart.Click;
      Require(StopItem.Enabled,'Actual favorite baseline worker did not start');
      // Recreate the real Main HWND while that worker owns its baseline. Its
      // completion must survive even if the previous HWND has queued messages.
      TMLIMainWindowAccess(frmMain).RecreateWnd;
      Require(Pump.DestroyCount>0,'Favorite lifecycle fixture did not recreate the actual Main window');
      WaitReady;
      Writeln('PASS favorite worker completion survives actual Main HWND recreation with its token and generation'); Flush(Output);
      TestUpdateProducer(Pump.LastReadyWindow);
    finally DetachPump; end;
    ResolveAuthorRows;
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark);
      Require((HeartPixels(AlphaNode)>0) and (HeartPixels(BetaNode)=0),
        'Favorite author heart is missing or also painted on an unmarked author');
    end;
    Require(MLIReadCatalogData(OneID)=InitialCatalog,'Favorite heart/baseline mutated catalog or personal fields');
    var NewID:=AddBook(One,'Alpha affordance new','Alpha','ru','','prose_contemporary');
    AttachPump;
    try frmMain.NotifyFavoriteCatalogChanged(TArray<Integer>.Create(OneID)); WaitReady;
    finally DetachPump; end;
    // Refresh can replace cached row pointers. Resolve the current selected Alpha again.
    AlphaNode:=frmMain.tvAuthors.GetFirstSelected;
    Require(NewButton.Enabled and (NewButton.Caption='+1'),'New favorite book badge did not appear');
    NewButton.Click;
    Require((NewButton.Caption='✓ 1') and (fsBold in NewButton.Font.Style) and
      NewButton.Hint.Contains('Показаны только новые'),'Only-new state has no distinct active affordance');
    var Shown: PBookRecord:=frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.GetFirstSelected);
    Require(Assigned(Shown) and (Shown.BookKey.BookID=NewID) and (frmMain.tvBooksA.TotalCount=1),
      'Active only-new affordance does not correspond to the displayed books');
    ViewedItem.Click;
    Require((NewButton.Caption='✓ 0') and (fsBold in NewButton.Font.Style) and (frmMain.tvBooksA.TotalCount=0),
      'Empty only-new view lost its active affordance');
    NewButton.Click;
    Require(not (fsBold in NewButton.Font.Style) and (NewButton.Caption='Новые') and (frmMain.tvBooksA.TotalCount>1),
      'Returning to all books retained a stale only-new affordance');
    Writeln('PASS favorite hearts paint independently of names and new-only state reflects actual books including zero results'); Flush(Output);
  finally
    DetachPump; Pump.Free;
    StopSQLiteProfile; SearchCheck.Checked:=False; SetMHLTheme(OriginalTheme);
  end;
end;

procedure TestLoadedListThemeMetrics;
var Probe: TMLIThemeNodeProbe; ThemeButton: TToolButton; Tree: TBookTree;
  OriginalTheme, OriginalInfo: Boolean; OriginalMode: TTreeMode;
  Focus, Top, Checked: PVirtualNode; Caret: Integer; Signature, Profile: string;

  procedure TraceMetrics(const Stage: string; Toggle: Integer);
  var Measure: TBitmap;
  begin
    Measure:=TBitmap.Create;
    try
      Measure.Canvas.Font.Assign(Tree.Font);
      Writeln('TRACE theme metrics ',Stage,' toggle=',Toggle,' visits=',Probe.Visits,' reinits=',Probe.ReinitVisits,
        ' dark=',Ord(MHLThemeDark),' font=',Tree.Font.Name,' size=',Tree.Font.Size,' height=',Tree.Font.Height,
        ' ppi=',Tree.Font.PixelsPerInch,' quality=',Ord(Tree.Font.Quality),' default=',Tree.DefaultNodeHeight,
        ' nativeText=',Measure.Canvas.TextHeight('Tg'),' customText=',Measure.Canvas.TextHeight('Щ'),
        ' canvasFont=',Tree.Canvas.Font.Name,' canvasSize=',Tree.Canvas.Font.Size,
        ' autoScale=',Ord(toAutoChangeScale in Tree.TreeOptions.AutoOptions)); Flush(Output);
    finally Measure.Free; end;
  end;

begin
  RequireIsolatedRegression; Tree:=frmMain.tvBooksSR; ThemeButton:=nil;
  for var Component in frmMain do
    if (Component is TToolButton) and (TToolButton(Component).ImageIndex=25) and
      Assigned(TToolButton(Component).OnClick) then ThemeButton:=TToolButton(Component);
  Require(Assigned(ThemeButton),'Actual Main theme action is absent');
  OriginalTheme:=MHLThemeDark; OriginalInfo:=Settings.ShowInfoPanel;
  OriginalMode:=Settings.TreeModes[PAGE_SEARCH]; Probe:=TMLIThemeNodeProbe.Create;
  Profile:=Settings.AppPath+'theme-color-only-large-list.tsv';
  try
    frmMain.pgControl.ActivePage:=frmMain.tsSearch; frmMain.pgControlChange(nil);
    Settings.ShowInfoPanel:=False; Settings.TreeModes[PAGE_SEARCH]:=tmFlat;
    TBookColumnFilters.ForTree(Tree).Clear;
    // Warm the existing font/row metrics before populating the stress list.
    if MHLThemeDark then ThemeButton.OnClick(ThemeButton);
    ThemeButton.OnClick(ThemeButton); ThemeButton.OnClick(ThemeButton);
    frmMain.FillBooksTree(Tree,nil,TProfileBooks.Create as IBookIterator,False,False,nil);
    Require(Tree.TotalCount=50000,'Theme stress list is incomplete');
    Checked:=Tree.GetFirst; Tree.CheckState[Checked]:=csCheckedNormal;
    Focus:=Tree.FocusedNode; Top:=Tree.TopNode;
    frmMain.edFTitle.Text:='Draft caret ё'; frmMain.ActiveControl:=frmMain.edFTitle;
    frmMain.edFTitle.SelStart:=3; frmMain.edFTitle.SelLength:=0; Caret:=frmMain.edFTitle.SelStart;
    Signature:=Tree.ContentToText(tstAll,#9); Probe.Original:=Tree.OnInitNode; Tree.OnInitNode:=Probe.InitNode;
    Probe.Visits:=0; Probe.ReinitVisits:=0; Probe.TraceCalls:=True; StartSQLiteProfile;
    for var Toggle:=1 to 4 do
    begin
      TraceMetrics('before',Toggle);
      ThemeButton.OnClick(ThemeButton);
      TraceMetrics('after',Toggle);
      Require(Probe.Visits=0,'Color-only theme change reinitialized a loaded book row');
      Require((Tree.FocusedNode=Focus) and (Tree.TopNode=Top) and (Tree.CheckState[Checked]=csCheckedNormal),
        'Color-only theme change lost book focus, scroll position or checked state');
      Require((frmMain.edFTitle.Text='Draft caret ё') and (frmMain.edFTitle.SelStart=Caret),
        'Theme toggle lost typed Search text or caret');
    end;
    SaveSQLiteProfile(Profile); StopSQLiteProfile;
    {$IFDEF MHL_SQL_PROFILE}
    var Queries:=TStringList.Create;
    try Queries.LoadFromFile(Profile); Require(Queries.Count=1,'Color-only theme toggle queried book data');
    finally Queries.Free; end;
    {$ENDIF}
    Require((Tree.TotalCount=50000) and (Tree.ContentToText(tstAll,#9)=Signature),
      'Theme toggle changed or removed loaded book metadata');
    Writeln('PASS actual Main color-only theme toggles on 50000 books avoid node reinitialization and SQL, preserve check/focus/scroll/caret/data'); Flush(Output);
  finally
    StopSQLiteProfile; Tree.OnInitNode:=Probe.Original; Probe.Free;
    if MHLThemeDark<>OriginalTheme then ThemeButton.OnClick(ThemeButton);
    Settings.ShowInfoPanel:=OriginalInfo; Settings.TreeModes[PAGE_SEARCH]:=OriginalMode;
  end;
end;

function TMLIMenuProgressProbe.MessageReceived(const Text: string; Flags: Longint): Integer;
begin
  if Text.StartsWith('Во время экспорта возникли ошибки') then Failure:=Text;
  Writeln('TRACE conversion report ',Text.Replace(#13,' ').Replace(#10,' ')); Flush(Output);
  Result:=IDOK;
end;

procedure TMLIMenuProgressProbe.Tick(Sender: TObject);
var Form: TExportToDeviceProgressForm;
begin
  if GetTickCount64>Deadline then
  begin
    Timer.Enabled:=False; Require(False,'Actual converter menu progress did not finish within15seconds');
  end;
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible and (string(Screen.Forms[I].Caption)='Какую книгу конвертировать?') then
    begin
      var Choice:=Screen.Forms[I];
      for var Component in Choice do if Component is TListBox then
      begin
        var Names:=TListBox(Component); var Found:=-1;
        for var J:=0 to Names.Items.Count-1 do
          if SameText(ExtractFileExt(Names.Items[J]),ChoiceExtension) then Found:=J;
        if Found<0 then
        begin Failure:='Conversion chooser lost the supported '+ChoiceExtension+' candidate'; Choice.ModalResult:=mrCancel; Exit; end;
        Names.ItemIndex:=Found;
      end;
      Choice.ModalResult:=mrOk; Exit;
    end;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TExportToDeviceProgressForm) and
      (string(Screen.Forms[I].Caption)=ExpectedCaption) and Screen.Forms[I].Visible then
    begin
      Form:=TExportToDeviceProgressForm(Screen.Forms[I]);
      if Assigned(Form.WorkerThread) then Form.WorkerThread.OnShowMessage:=MessageReceived;
      if Assigned(Form.WorkerThread) and Form.WorkerThread.Finished then
      begin
        if Form.WorkerThread.FatalException is Exception then
          Failure:=Exception(Form.WorkerThread.FatalException).Message;
        Form.ModalResult:=mrOk; Timer.Enabled:=False; Exit;
      end;
    end;
end;

procedure TestMainBuiltinConversionMenus(OriginalCID: Integer);
var RawCID: Integer; Raw: IBookCollection; Book: TBookRecord; Item: TMenuItem;
  Probe: TMLIMenuProgressProbe; SourceFile, OriginalHash, Target, PreviousDevice,
    PreviousFolderTemplate, PreviousFileTemplate: string;
  OriginalPrompt, OriginalRewrite, OriginalMixed: Boolean;
  OriginalMode: TTreeMode; OriginalPage: Integer;

  function MenuEntry(Parent: TMenuItem; Tag: Integer): TMenuItem;
  begin
    Result:=nil;
    for var Child in Parent do if Child.Tag=Tag then Result:=Child;
    Require(Assigned(Result) and Result.Visible and Assigned(Result.OnClick),
      'Built-in converter is missing from actual book menu tag='+IntToStr(Tag));
  end;

begin
  RequireIsolatedRegression;
  Require(Settings.Scripts.Count=0,'Converter discovery regression requires zero personal scripts');
  PreviousDevice:=Settings.DeviceDir; PreviousFolderTemplate:=Settings.FolderTemplate;
  PreviousFileTemplate:=Settings.FileNameTemplate; OriginalPrompt:=Settings.PromptDevicePath;
  OriginalRewrite:=Settings.OverwriteFB2Info; OriginalMixed:=Settings.AllowMixed;
  OriginalMode:=Settings.TreeModes[PAGE_SEARCH]; OriginalPage:=frmMain.pgControl.ActivePageIndex;
  SourceFile:=Settings.AppPath+'conversion-menu-source.fb2';
  TFile.WriteAllText(SourceFile,'<?xml version="1.0" encoding="UTF-8"?>'+
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
    '<genre>prose_contemporary</genre><author><first-name>Тест</first-name><last-name>Меню</last-name></author>'+
    '<book-title>Проверка меню конвертера</book-title><lang>ru</lang></title-info><document-info>'+
    '<author><nickname>fixture</nickname></author><date value="2026-10-14">2026-10-14</date>'+
    '<id>MENU_NATIVE_FB2</id><version>1.0</version></document-info></description><body><section>'+
    '<title><p>Глава</p></title><p>Живой фрагмент — ё, ї, ў. Не потерять текст.</p></section></body></FictionBook>',TEncoding.UTF8);
  OriginalHash:=THashSHA2.GetHashStringFromFile(SourceFile);
  RawCID:=SystemDB.CreateCollection('Raw menu discovery',Settings.AppPath,'menu-discovery-raw.hlc2',
    CT_EXTERNAL_LOCAL_NONFB,Settings.AppPath+'genres_fb2.glst');
  Raw:=SystemDB.GetCollection(RawCID);
  Book.Clear; Book.NodeType:=ntBookInfo; Book.Title:='Проверка меню конвертера';
  Book.FileName:='conversion-menu-source'; Book.FileExt:='.fb2'; Book.Lang:='ru'; Book.LibID:='MENU_NATIVE_FB2';
  Book.Size:=Integer(TFile.GetSize(SourceFile)); Book.Date:=EncodeDate(2026,10,14);
  TAuthorsHelper.Add(Book.Authors,'Меню','Тест','');
  Book.BookKey:=CreateBookKey(Raw.InsertBook(Book,False,False),RawCID);
  Probe:=TMLIMenuProgressProbe.Create; Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=10; Probe.Timer.OnTimer:=Probe.Tick;
  try
    Item:=TMenuItem.Create(nil);
    try Item.Tag:=RawCID; frmMain.miActiveCollectionClick(Item); finally Item.Free; end;
    Settings.AllowMixed:=False;
    Require(frmMain.pmiScripts.Visible and frmMain.mmiScripts.Visible and
      frmMain.pmiScripts.Caption.Contains('Конвертировать') and (frmMain.pmiScripts.Count=2),
      'Zero-script raw collection hides the converter submenu');
    // Source-dependent visibility is resolved when the actual menu opens.
    frmMain.pgControl.ActivePage:=frmMain.tsSearch; frmMain.pgControlChange(nil);
    Settings.TreeModes[PAGE_SEARCH]:=tmFlat; TBookColumnFilters.ForTree(frmMain.tvBooksSR).Clear;
    frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Raw.GetBookIterator(bmAll,False),False,False,@Book.BookKey);
    Settings.PromptDevicePath:=False; Settings.OverwriteFB2Info:=False;
    Settings.FolderTemplate:=''; Settings.FileNameTemplate:='%t';
    for var Ext in TArray<string>.Create('.lit','.lrf') do
    begin
      Book.FileExt:=Ext; Raw.UpdateBook(Book);
      frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Raw.GetBookIterator(bmAll,False),False,False,@Book.BookKey);
      frmMain.pmMain.OnPopup(frmMain.pmMain);
      Require(not frmMain.pmiScripts.Visible and not frmMain.mmiScripts.Visible,
        'Unsupported input offers conversion: '+Ext);
    end;
    Writeln('PASS conversion menu hides unsupported LIT LRF inputs');
    for var Ext in TArray<string>.Create('.pdf','.djvu','.mht','.chm','.pdb','.wri','.tcr','.123456',
      '.docm','.dotx','.dotm','.ott','.ppt','.pps','.pot','.pptx','.pptm','.ppsx','.ppsm','.potx','.potm',
      '.xls','.xlt','.xlsx','.xlsm','.xltx','.xltm','.ods','.ots','.odp','.otp','.wps','.wpd') do
    begin
      Book.FileExt:=Ext; Raw.UpdateBook(Book);
      frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Raw.GetBookIterator(bmAll,False),False,False,@Book.BookKey);
      frmMain.pmMain.OnPopup(frmMain.pmMain); MenuEntry(frmMain.pmiScripts,850); MenuEntry(frmMain.pmiScripts,854);
    end;
    Writeln('PASS conversion menu offers new text containers and deferred PDF/DjVu text-layer validation');
    for var Tag in TArray<Integer>.Create(854,850) do
    begin
      Book.FileExt:='.fb2'; if Tag=850 then Book.FileExt:='.epub';
      Raw.UpdateBook(Book);
      frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Raw.GetBookIterator(bmAll,False),False,False,@Book.BookKey);
      frmMain.pmMain.OnPopup(frmMain.pmMain);
      MenuEntry(frmMain.pmiScripts,Tag); MenuEntry(frmMain.mmiScripts,Tag);
      for var Entry in frmMain.pmiScripts do
        if Entry.Tag=(1704-Tag) then Require(not Entry.Visible,'Same-format conversion is visible');
      Target:=TPath.Combine(Settings.AppPath,'converter-menu-out-'+IntToStr(Tag)); ForceDirectories(Target);
      Settings.DeviceDir:=Target;
      Probe.Failure:=''; Probe.ExpectedCaption:='Экспорт в FB2';
      if Tag=854 then Probe.ExpectedCaption:='Экспорт в EPUB';
      Probe.Deadline:=GetTickCount64+15000; Probe.Timer.Enabled:=True;
      MenuEntry(frmMain.pmiScripts,Tag).Click; Probe.Timer.Enabled:=False;
      Require(Probe.Failure='','Actual converter menu worker failed: '+Probe.Failure);
      var Extension:='.fb2'; if Tag=854 then Extension:='.epub';
      var Outputs:=TDirectory.GetFiles(Target,'*'+Extension,TSearchOption.soAllDirectories);
      Require(Length(Outputs)=1,'Actual converter menu did not produce exactly one '+Extension+' book');
      if Tag=854 then TFile.Copy(Outputs[0],ChangeFileExt(SourceFile,'.epub'),False);
      var Document:=TReaderDocument.Create;
      try
        Document.Load(Outputs[0]);
        Require(Document.PlainText.Contains('Живой фрагмент — ё, ї, ў. Не потерять текст.'),
          'Actual converter menu output lost Unicode book contents');
      finally Document.Free; end;
      Require(THashSHA2.GetHashStringFromFile(SourceFile)=OriginalHash,
        'Actual converter menu overwrote original book contents');
      Writeln('PASS zero-script raw collection actual context menu converts to ',Extension,
        ' with Unicode contents and unchanged source'); Flush(Output);
    end;
    for var SourceName in TArray<string>.Create('convert-fb2.zip','convert-fb2.7z','convert-epub.zip') do
    begin
      TFile.Copy(Settings.AppPath+'metadata-archive-fixtures\'+SourceName,Settings.AppPath+SourceName,False);
      Book.FileName:=ChangeFileExt(SourceName,''); Book.FileExt:=ExtractFileExt(SourceName);
      Raw.UpdateBook(Book);
      frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Raw.GetBookIterator(bmAll,False),False,False,@Book.BookKey);
      frmMain.pmMain.OnPopup(frmMain.pmMain); MenuEntry(frmMain.pmiScripts,850); MenuEntry(frmMain.pmiScripts,854);
      Target:=Settings.AppPath+'archive-out-'+SourceName; ForceDirectories(Target); Settings.DeviceDir:=Target;
      var Tag:=854; var Extension:='.epub';
      Probe.ChoiceExtension:='.fb2';
      if SourceName='convert-epub.zip' then begin Tag:=850; Extension:='.fb2'; end;
      if SourceName='convert-epub.zip' then Probe.ChoiceExtension:='.epub';
      Probe.Failure:=''; Probe.ExpectedCaption:='Экспорт в '+UpperCase(Copy(Extension,2,MaxInt));
      Probe.Deadline:=GetTickCount64+15000; Probe.Timer.Enabled:=True;
      MenuEntry(frmMain.pmiScripts,Tag).Click; Probe.Timer.Enabled:=False;
      Require(Probe.Failure='','Archive converter failed: '+Probe.Failure);
      var Outputs:=TDirectory.GetFiles(Target,'*'+Extension,TSearchOption.soAllDirectories);
      Require(Length(Outputs)=1,'Archive conversion did not detect the actual FB2/EPUB input');
      var Document:=TReaderDocument.Create;
      try Document.Load(Outputs[0]); Require(Document.PlainText.Contains('English'),'Archive conversion lost book text');
      finally Document.Free; end;
      Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+SourceName)=
        THashSHA2.GetHashStringFromFile(Settings.AppPath+'metadata-archive-fixtures\'+SourceName),'Archive conversion changed the original archive');
      Writeln('PASS archive conversion ',SourceName,' selects supported contents, derives target and preserves source');
    end;
    for var SourceName in TArray<string>.Create('text-input.txt','text-input.html','text-input.rtf','text-input.docx','text-input.odt','text-input.doc','text-input.zip',
      'text-input.fb3','text-input.md','kindle-1342.mobi','kindle-1342.azw3',
      'text-input.pdf','text-input.123456','text-input.djvu','text-input.chm','text-input.mht','text-input.tcr','text-input.pdb','text-input.wri','numeric-input.zip') do
    begin
      TFile.Copy(Settings.AppPath+'metadata-archive-fixtures\'+SourceName,Settings.AppPath+SourceName,False);
      Book.FileName:=ChangeFileExt(SourceName,''); Book.FileExt:=ExtractFileExt(SourceName); Raw.UpdateBook(Book);
      frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Raw.GetBookIterator(bmAll,False),False,False,@Book.BookKey);
      frmMain.pmMain.OnPopup(frmMain.pmMain); MenuEntry(frmMain.pmiScripts,850); MenuEntry(frmMain.pmiScripts,854);
      var SourceHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+SourceName);
      Probe.ChoiceExtension:='.txt';
      for var Tag in TArray<Integer>.Create(850,854) do
      begin
        var Extension:='.fb2'; if Tag=854 then Extension:='.epub';
        Target:=Settings.AppPath+'text-out-'+SourceName+IntToStr(Tag); ForceDirectories(Target); Settings.DeviceDir:=Target;
        Probe.Failure:=''; Probe.ExpectedCaption:='Экспорт в '+UpperCase(Copy(Extension,2,MaxInt));
        Probe.Deadline:=GetTickCount64+30000; Probe.Timer.Enabled:=True;
        MenuEntry(frmMain.pmiScripts,Tag).Click; Probe.Timer.Enabled:=False;
        Require(Probe.Failure='','Text converter worker failed: '+SourceName+' '+Probe.Failure);
        var Outputs:=TDirectory.GetFiles(Target,'*'+Extension,TSearchOption.soAllDirectories);
        Require(Length(Outputs)=1,'Text converter did not publish one result: '+SourceName);
        if SourceName.StartsWith('kindle-') then
          Require(TFile.GetSize(Outputs[0])>100000,'Kindle converter published an unexpectedly empty book')
        else
        begin
          var Document:=TReaderDocument.Create;
          try Document.Load(Outputs[0]);
            if not MatchText(SourceName,['text-input.doc','text-input.djvu','text-input.chm','text-input.mht']) then Require(Document.PlainText.Contains('English'),'Text converter lost Unicode/English contents: '+SourceName)
            else Require(Length(Document.PlainText)>10,'DOC converter produced empty body');
          finally Document.Free; end;
        end;
        Require(SourceHash=THashSHA2.GetHashStringFromFile(Settings.AppPath+SourceName),'Text converter changed source');
        Writeln('PASS actual text conversion ',SourceName,' to ',Extension,' preserves contents and source'); Flush(Output);
      end;
    end;

  finally
    Probe.Timer.Enabled:=False; Probe.Timer.Free; Probe.Free;
    Settings.DeviceDir:=PreviousDevice; Settings.FolderTemplate:=PreviousFolderTemplate;
    Settings.FileNameTemplate:=PreviousFileTemplate; Settings.PromptDevicePath:=OriginalPrompt;
    Settings.OverwriteFB2Info:=OriginalRewrite; Settings.AllowMixed:=OriginalMixed;
    Settings.TreeModes[PAGE_SEARCH]:=OriginalMode;
    Item:=TMenuItem.Create(nil);
    try Item.Tag:=OriginalCID; frmMain.miActiveCollectionClick(Item); finally Item.Free; end;
    frmMain.pgControl.ActivePageIndex:=OriginalPage;
  end;
end;

procedure TMLIPublisherProgressProbe.Tick(Sender: TObject);
var Form: TImportProgressFormEx;
begin
  Require(GetTickCount64<=Deadline,'Actual publisher index progress did not finish within15seconds');
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TImportProgressFormEx) and Screen.Forms[I].Visible and
       (string(Screen.Forms[I].Caption)='Заполнение издательств и книжных серий') then
    begin
      Form:=TImportProgressFormEx(Screen.Forms[I]);
      if Assigned(Form.WorkerThread) and Form.WorkerThread.Finished then
      begin
        if Form.WorkerThread.FatalException is Exception then
          Failure:=Exception(Form.WorkerThread.FatalException).Message;
        Form.ModalResult:=mrOk; Timer.Enabled:=False; Exit;
      end;
    end;
end;

procedure TestMainPublisherIndexCache(OriginalCID: Integer);
const OldPublisher=''; NewPublisher='Ёжик & Élan UI';
var Collection: IBookCollection; CID: Integer; IDs: array[0..1] of Integer;
  Files, Hashes: array[0..1] of string; Book: TBookRecord; Series: TBookSeries;
  Publisher: TPublisherSeriesView; Edit: TMHLButtonedEdit; Filters: TBookColumnFilters;
  Names: TStringList; Probe: TMLIPublisherProgressProbe; NodeProbe: TMLIThemeNodeProbe;
  AuthorFirst, SearchFirst: PVirtualNode; OriginalPage: Integer;
  OriginalSearchMode, OriginalAuthorMode: TTreeMode; Folder, Before: string;
  NodeHooked: Boolean;

  procedure SelectCollection(Value: Integer);
  var Item: TMenuItem;
  begin
    Item:=TMenuItem.Create(nil);
    try Item.Tag:=Value; frmMain.miActiveCollectionClick(Item); finally Item.Free; end;
  end;

  function FirstBook(Tree: TBookTree): PBookRecord;
  var Node: PVirtualNode;
  begin
    Result:=nil; Node:=Tree.GetFirst;
    while Assigned(Node) do
    begin
      Result:=Tree.GetNodeData(Node);
      if Assigned(Result) and (Result.NodeType=ntBookInfo) then Exit;
      Node:=Tree.GetNext(Node);
    end;
    Result:=nil;
  end;

  procedure ExpectPublishers(Tree: TBookTree; const Expected: string; Count: Integer);
  var Node: PVirtualNode; Data: PBookRecord; Actual: Integer;
  begin
    Actual:=0; Node:=Tree.GetFirst;
    while Assigned(Node) do
    begin
      Data:=Tree.GetNodeData(Node);
      if Assigned(Data) and (Data.NodeType=ntBookInfo) then
      begin
        Inc(Actual); Require(Data.Publisher=Expected,'Loaded publisher row still has stale metadata: '+Data.Title);
      end;
      Node:=Tree.GetNext(Node);
    end;
    Require(Actual=Count,'Publisher index refreshed an incorrect number of loaded book rows');
  end;

  procedure IndexNow;
  begin
    Probe.Failure:=''; Probe.Deadline:=GetTickCount64+15000; Probe.Timer.Enabled:=True;
    try Publisher.IndexButton.Click; finally Probe.Timer.Enabled:=False; end;
    Require(Probe.Failure='','Actual publisher index worker failed: '+Probe.Failure);
  end;

begin
  RequireIsolatedRegression;
  OriginalPage:=frmMain.pgControl.ActivePageIndex;
  OriginalSearchMode:=Settings.TreeModes[PAGE_SEARCH]; OriginalAuthorMode:=Settings.TreeModes[PAGE_AUTHORS];
  Folder:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'main-publisher-index-fixture'));
  ForceDirectories(Folder);
  CID:=SystemDB.CreateCollection('Main publisher index cache',Folder,'main-publisher-index.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID);
  for var I:=0 to High(IDs) do
  begin
    IDs[I]:=AddBook(Collection,'Cache index '+IntToStr(I),'Index author','ru','','prose_contemporary');
    Book.Clear; Collection.GetBookRecord(CreateBookKey(IDs[I],CID),Book,True);
    Book.Publisher:=OldPublisher; Collection.UpdateBook(Book);
    Files[I]:=Book.GetBookFileName;
    TFile.WriteAllText(Files[I],'<?xml version="1.0" encoding="UTF-8"?>'+
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description>'+
      '<title-info><book-title>Source title must stay out of catalog</book-title></title-info>'+
      '<publish-info><publisher>Ёжик &amp; Élan UI</publisher>'+
      '<sequence name="Издательская серия UI" number="'+IntToStr(I+1)+'"/>'+
      '</publish-info></description><body><section><p>Текст не меняется ё.</p></section></body></FictionBook>',TEncoding.UTF8);
    Hashes[I]:=THashSHA2.GetHashStringFromFile(Files[I]);
  end;
  Series:=nil; TSeriesHelper.Add(Series,0,'Старая издательская серия UI',1,False);
  Collection.SetBookPublisherSeries(CreateBookKey(IDs[0],CID),Series);
  Publisher:=nil;
  for var Component in frmMain do if Component is TPublisherSeriesView then Publisher:=TPublisherSeriesView(Component);
  Require(Assigned(Publisher),'Actual publisher index button is absent');
  Edit:=TMHLButtonedEdit(frmMain.FindComponent('edFPublisher'));
  Require(Assigned(Edit),'Actual publisher Search criterion is absent');
  Names:=TStringList.Create; Probe:=TMLIPublisherProgressProbe.Create;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False; Probe.Timer.Interval:=10; Probe.Timer.OnTimer:=Probe.Tick;
  NodeProbe:=TMLIThemeNodeProbe.Create; NodeHooked:=False;
  try
    SelectCollection(CID); Settings.TreeModes[PAGE_SEARCH]:=tmFlat; Settings.TreeModes[PAGE_AUTHORS]:=tmFlat;
    Publisher.FullScan.Checked:=False;
    ShowPage(PAGE_AUTHORS); frmMain.edLocateAuthor.Text:='Index author'; frmMain.tmrSearchATimer(nil);
    var Author:=PAuthorData(frmMain.tvAuthors.GetNodeData(frmMain.tvAuthors.GetFirstSelected));
    Require(Assigned(Author) and (Author.LastName='Index author'),'Publisher fixture did not select its actual author');
    ExpectPublishers(frmMain.tvBooksA,OldPublisher,2); AuthorFirst:=frmMain.tvBooksA.GetFirst;
    ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False);
    TBookColumnFilters.ForTree(frmMain.tvBooksSR).Clear;
    var QueryMode:=frmMain.FindComponent('SearchQueryModeControl') as TSearchQueryModeControl;
    Require(Assigned(QueryMode),'Publisher index search query-mode control is missing');
    QueryMode.Mode:=sqmExpression;
    frmMain.edFTitle.Text:='="Cache index 0"'; frmMain.DoApplyFilter(nil);
    ExpectTitles(frmMain.tvBooksSR,['Cache index 0']); ExpectPublishers(frmMain.tvBooksSR,OldPublisher,1);
    Filters:=TBookColumnFilters.ForTree(frmMain.tvBooksSR);
    Filters.GetOptions(COL_PUBLISHER,Names);
    Require(Names.Count=0,'Publisher fixture failed to warm empty loaded filter options');
    Edit.Text:='Unapplied publisher draft'; frmMain.edFTitle.Text:='Unapplied title draft';
    IndexNow;
    ExpectTitles(frmMain.tvBooksSR,['Cache index 0']); ExpectPublishers(frmMain.tvBooksSR,NewPublisher,1);
    Require((Edit.Text='Unapplied publisher draft') and (frmMain.edFTitle.Text='Unapplied title draft'),
      'Metadata refresh consumed or erased unfinished Search controls');
    Names.Clear; Filters.GetOptions(COL_PUBLISHER,Names);
    Require((Names.Count=1) and (Names[0]=NewPublisher),'Publisher column options retained the pre-index loaded cache');
    var Column:=-1;
    for var I:=0 to frmMain.tvBooksSR.Header.Columns.Count-1 do
      if frmMain.tvBooksSR.Header.Columns[I].Tag=COL_PUBLISHER then Column:=I;
    if Column<0 then
    begin
      var Menu:=TMenuItem(frmMain.FindComponent('miColumnPublisher')); Require(Assigned(Menu),'Publisher column menu is absent');
      Menu.Click;
      for var I:=0 to frmMain.tvBooksSR.Header.Columns.Count-1 do
        if frmMain.tvBooksSR.Header.Columns[I].Tag=COL_PUBLISHER then Column:=I;
    end;
    Require(Column>=0,'Publisher column did not become available after metadata refresh');
    var Text:=''; frmMain.tvBooksSR.OnGetText(frmMain.tvBooksSR,frmMain.tvBooksSR.GetFirst,Column,ttNormal,Text);
    Require(Text=NewPublisher,'Actual publisher column still displays pre-index metadata');
    var InactiveBook:=FirstBook(frmMain.tvBooksA);
    Require(Assigned(InactiveBook),'Publisher refresh discarded the inactive author book list');
    Require((frmMain.tvBooksA.GetFirst=AuthorFirst) and (InactiveBook.Publisher=OldPublisher),
      'Publisher index eagerly rebuilt an inactive author book list');
    Writeln('PASS actual publisher index refreshes active rows, column and filter cache from applied Search snapshot without consuming drafts or rebuilding inactive books'); Flush(Output);

    ShowPage(PAGE_AUTHORS); ExpectPublishers(frmMain.tvBooksA,NewPublisher,2);
    frmMain.pgControl.ActivePage:=Publisher.Tab; frmMain.pgControlChange(nil);
    var SeriesData:=PSeriesData(Publisher.SeriesTree.GetNodeData(Publisher.SeriesTree.GetFirstSelected));
    Require(Assigned(SeriesData) and (SeriesData.SeriesTitle='Издательская серия UI'),
      'Lazy publisher selector did not reflect committed metadata');
    ExpectPublishers(Publisher.Books,NewPublisher,2);
    Writeln('PASS inactive author books and publisher series reload new metadata only when opened'); Flush(Output);

    ShowPage(PAGE_SEARCH); ExpectTitles(frmMain.tvBooksSR,['Cache index 0']);
    SearchFirst:=frmMain.tvBooksSR.GetFirst; Before:=MLIReadCatalogData(CID);
    NodeProbe.Original:=frmMain.tvBooksSR.OnInitNode; frmMain.tvBooksSR.OnInitNode:=NodeProbe.InitNode; NodeHooked:=True;
    NodeProbe.Visits:=0; IndexNow;
    Require((NodeProbe.Visits=0) and (frmMain.tvBooksSR.GetFirst=SearchFirst),
      'A zero-commit cached publisher pass rebuilt the current book list');
    Require((Edit.Text='Unapplied publisher draft') and (frmMain.edFTitle.Text='Unapplied title draft'),
      'A cached publisher pass consumed unfinished Search controls');
    Require(MLIReadCatalogData(CID)=Before,'A cached publisher pass changed stored catalog data');
    for var I:=0 to High(Files) do Require(THashSHA2.GetHashStringFromFile(Files[I])=Hashes[I],
      'Actual publisher index changed an original FB2 source');
    Writeln('PASS zero-commit cached publisher index keeps node identity, drafts and stored/source bytes unchanged'); Flush(Output);
  finally
    Probe.Timer.Enabled:=False; Probe.Timer.Free; Probe.Free; Names.Free;
    if NodeHooked then frmMain.tvBooksSR.OnInitNode:=NodeProbe.Original;
    NodeProbe.Free; Settings.TreeModes[PAGE_SEARCH]:=OriginalSearchMode;
    Settings.TreeModes[PAGE_AUTHORS]:=OriginalAuthorMode;
    SelectCollection(OriginalCID); frmMain.pgControl.ActivePageIndex:=OriginalPage;
  end;
end;

procedure TMLIToolbarForwardProbe.Draw(Sender: TToolBar; const Bounds: TRect; var DefaultDraw: Boolean);
begin
  Inc(DrawCalls); DefaultDraw:=False;
  Sender.Canvas.Brush.Color:=RGB(12,134,201); Sender.Canvas.FillRect(Bounds);
end;

procedure TMLIToolbarForwardProbe.DrawButton(Sender: TToolBar; Button: TToolButton;
  State: TCustomDrawState; var DefaultDraw: Boolean);
begin
  Inc(ButtonCalls); DefaultDraw:=False;
  Sender.Canvas.Brush.Color:=RGB(91,17,121); Sender.Canvas.FillRect(Button.BoundsRect);
end;

procedure TMLIToolbarNativeProbe.Draw(Sender: TToolBar; const Bounds: TRect; var DefaultDraw: Boolean);
var DC: HDC; Clip: TRect; Viewport, WindowOrigin: TPoint;
begin
  Inc(DrawCalls);
  if DrawCalls=1 then
  begin
    DC:=Sender.Canvas.Handle; Clip:=Default(TRect); Viewport:=Default(TPoint); WindowOrigin:=Default(TPoint);
    GetClipBox(DC,Clip); GetViewportOrgEx(DC,Viewport); GetWindowOrgEx(DC,WindowOrigin);
    Writeln('TRACE native toolbar HDC draw expected=',NativeUInt(ExpectedDC),' type=',GetObjectType(ExpectedDC),
      ' actual=',NativeUInt(DC),' type=',GetObjectType(DC),' window=',NativeUInt(WindowFromDC(DC)),
      ' bitmap=',NativeUInt(GetCurrentObject(DC,OBJ_BITMAP)),
      ' expectedbitmap=',NativeUInt(GetCurrentObject(ExpectedDC,OBJ_BITMAP)),
      ' viewport=',Viewport.X,',',Viewport.Y,' origin=',WindowOrigin.X,',',WindowOrigin.Y,
      ' clip=',Clip.Left,',',Clip.Top,',',Clip.Right,',',Clip.Bottom); Flush(Output);
  end;
  if Assigned(OriginalDraw) then OriginalDraw(Sender,Bounds,DefaultDraw);
end;

procedure TMLIToolbarNativeProbe.DrawButton(Sender: TToolBar; Button: TToolButton;
  State: TCustomDrawState; var DefaultDraw: Boolean);
begin
  Inc(ButtonCalls);
  if (ButtonCalls=1) or (Button=TargetButton) then
  begin
    Writeln('TRACE native toolbar HDC button=',Button.Name,' expected=',NativeUInt(ExpectedDC),
      ' actual=',NativeUInt(Sender.Canvas.Handle),' type=',GetObjectType(Sender.Canvas.Handle),
      ' window=',NativeUInt(WindowFromDC(Sender.Canvas.Handle)),
      ' bitmap=',NativeUInt(GetCurrentObject(Sender.Canvas.Handle,OBJ_BITMAP)),
      ' expectedbitmap=',NativeUInt(GetCurrentObject(ExpectedDC,OBJ_BITMAP)),
      ' bounds=',Button.Left,',',Button.Top,' ',Button.Width,'x',Button.Height); Flush(Output);
  end;
  if Assigned(OriginalButton) then OriginalButton(Sender,Button,State,DefaultDraw);
end;

procedure MLIPaintToolbarCanvas(Bar: TToolBar; Bitmap: TBitmap; const Paint: TProc<TToolBar>);
var DC: HDC; Image: HBITMAP; Previous: HGDIOBJ; Target: TToolBar;
begin
  // TControlCanvas may release an assigned DC when Handle is detached. Never
  // transfer the separately owned TBitmap.Canvas DC into a control canvas.
  Require(GetObjectType(Bitmap.Canvas.Handle)=OBJ_MEMDC,'Toolbar output bitmap has no valid independent DC');
  DC:=CreateCompatibleDC(Bitmap.Canvas.Handle); Image:=0; Previous:=0; Target:=nil;
  Require(DC<>0,'Unable to create owned toolbar callback DC');
  try
    // Manual callbacks use an equivalent owned sender. Never mutate the real
    // Main toolbar's cached TControlCanvas before its independent native paint.
    Target:=TToolBar.Create(nil); Target.Align:=alNone; Target.Visible:=False;
    Target.Parent:=Bar.Parent;
    TMLIToolbarAccess(Target).ChangeScale(Bar.CurrentPPI,Target.CurrentPPI,True);
    Target.Font.Assign(Bar.Font); Target.Images:=Bar.Images;
    Target.ShowCaptions:=Bar.ShowCaptions; Target.List:=Bar.List;
    Target.SetBounds(0,0,Bar.Width,Bar.Height);
    Image:=CreateCompatibleBitmap(Bitmap.Canvas.Handle,Bitmap.Width,Bitmap.Height);
    Require(Image<>0,'Unable to create owned toolbar callback bitmap');
    Previous:=SelectObject(DC,Image);
    Require((Previous<>0) and (NativeInt(Previous)<>-1),'Unable to select owned toolbar callback bitmap');
    Require(BitBlt(DC,0,0,Bitmap.Width,Bitmap.Height,Bitmap.Canvas.Handle,0,0,SRCCOPY),
      'Unable to initialise toolbar callback target');
    Target.Canvas.Handle:=DC;
    try
      Paint(Target);
      Require(GetObjectType(DC)=OBJ_MEMDC,'Toolbar callback invalidated its active DC');
      Require(BitBlt(Bitmap.Canvas.Handle,0,0,Bitmap.Width,Bitmap.Height,DC,0,0,SRCCOPY),
        'Unable to retain actual toolbar callback pixels');
    finally
      if (Previous<>0) and (NativeInt(Previous)<>-1) and (GetObjectType(DC)=OBJ_MEMDC) then
        SelectObject(DC,Previous);
      Target.Canvas.Handle:=0;
    end;
  finally
    Target.Free;
    if GetObjectType(DC)=OBJ_MEMDC then DeleteDC(DC);
    if Image<>0 then DeleteObject(Image);
  end;
  Require(GetObjectType(Bitmap.Canvas.Handle)=OBJ_MEMDC,'Toolbar callback borrowed or destroyed its output bitmap DC');
end;

procedure TestMainTreeMetricChanges;
var Tree: TBookTree; Source: PVirtualNode; Data: PBookRecord; Books: TArray<TBookRecord>;
  FontBefore: TFont; OriginalInfo: Boolean; OriginalMode: TTreeMode; OriginalPage: Integer;
  OriginalPPI, OriginalWidth, OriginalHeight, TargetPPI: Integer;
  DefaultBefore, NodeBefore, DpiDefaultBefore, DpiNodeBefore: Cardinal;
  OptionsBefore: TVTAutoOptions; CatalogBefore, CardsBefore: string;

  function ReadCards: string;
  var Database: TSQLiteDatabase; Query: TSQLiteQuery; TableName, Value: string; I: Integer;
  begin
    Result:=''; Database:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    try
      for TableName in TArray<string>.Create('Books','BookGroups','Groups') do
      begin
        Query:=Database.NewQuery('SELECT * FROM "'+TableName+'" ORDER BY rowid');
        try
          Query.Open; Result:=Result+TableName+#10;
          while not Query.Eof do
          begin
            for I:=0 to Query.ColCount-1 do
            begin Value:=Query.FieldAsString(I); Result:=Result+IntToStr(Length(Value))+':'+Value; end;
            Result:=Result+#10; Query.Next;
          end;
        finally Query.Free; end;
      end;
    finally Database.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Tree:=frmMain.tvBooksSR;
  Source:=frmMain.tvBooksA.GetFirst;
  while Assigned(Source) and (Length(Books)<3) do
  begin
    Data:=frmMain.tvBooksA.GetNodeData(Source);
    if Assigned(Data) and (Data.nodeType=ntBookInfo) then
    begin SetLength(Books,Length(Books)+1); Books[High(Books)]:=Data^; end;
    Source:=frmMain.tvBooksA.GetNext(Source);
  end;
  Require(Length(Books)=3,'Main font/DPI fixture lacks three real catalog books');
  CatalogBefore:=MLIReadCatalogData(Settings.ActiveCollection); CardsBefore:=ReadCards;
  OriginalInfo:=Settings.ShowInfoPanel; OriginalMode:=Settings.TreeModes[PAGE_SEARCH];
  OriginalPage:=frmMain.pgControl.ActivePageIndex; OriginalPPI:=frmMain.Font.PixelsPerInch;
  OriginalWidth:=frmMain.Width; OriginalHeight:=frmMain.Height;
  FontBefore:=TFont.Create; FontBefore.Assign(Tree.Font); OptionsBefore:=Tree.TreeOptions.AutoOptions;
  try
    Settings.ShowInfoPanel:=False; Settings.TreeModes[PAGE_SEARCH]:=tmFlat;
    frmMain.pgControl.ActivePage:=frmMain.tsSearch; frmMain.pgControlChange(nil);
    frmMain.FillBooksTree(Tree,nil,TMLIMetricBooks.Create(Books) as IBookIterator,False,False,nil);
    Require(Tree.TotalCount=3,'Main font/DPI positive fixture is incomplete');
    Require(toAutoChangeScale in OptionsBefore,'Main no longer supports automatic real font changes');
    DefaultBefore:=Tree.DefaultNodeHeight; NodeBefore:=Tree.GetFirst.NodeHeight;
    SetMHLControlFontColor(Tree,RGB(91,73,151));
    Require((Tree.DefaultNodeHeight=DefaultBefore) and (Tree.GetFirst.NodeHeight=NodeBefore) and
      (Tree.TreeOptions.AutoOptions=OptionsBefore),'Color helper resized actual rows or altered their auto options');
    Tree.Font.Size:=FontBefore.Size+2;
    Require((Tree.DefaultNodeHeight>DefaultBefore) and (Tree.GetFirst.NodeHeight>NodeBefore) and
      (Tree.TreeOptions.AutoOptions=OptionsBefore),'Real chosen font growth no longer resizes actual Main rows');
    Tree.Font.Assign(FontBefore);
    Require((Tree.Font.Size=FontBefore.Size) and (Tree.Font.Height=FontBefore.Height) and
      (Tree.TreeOptions.AutoOptions=OptionsBefore),'Restoring the chosen font lost its metrics or automatic resizing');
    DpiDefaultBefore:=Tree.DefaultNodeHeight; DpiNodeBefore:=Tree.GetFirst.NodeHeight;
    TargetPPI:=144; if OriginalPPI>=TargetPPI then TargetPPI:=MulDiv(OriginalPPI,3,2);
    frmMain.ScaleForPPI(TargetPPI); frmMain.FormAfterMonitorDpiChanged(nil,OriginalPPI,TargetPPI);
    Require((Tree.Font.PixelsPerInch=TargetPPI) and (Tree.DefaultNodeHeight>DpiDefaultBefore) and
      (Tree.GetFirst.NodeHeight>DpiNodeBefore) and (Tree.TreeOptions.AutoOptions=OptionsBefore),
      'Actual Main DPI growth no longer scales row fonts and native row heights');
    frmMain.ScaleForPPI(OriginalPPI); frmMain.FormAfterMonitorDpiChanged(nil,TargetPPI,OriginalPPI);
    Require((Tree.Font.PixelsPerInch=OriginalPPI) and (Tree.DefaultNodeHeight=DpiDefaultBefore) and
      (Tree.GetFirst.NodeHeight=DpiNodeBefore) and (Tree.TreeOptions.AutoOptions=OptionsBefore),
      'Actual Main DPI return did not restore row metrics and original automatic options');
    Require((MLIReadCatalogData(Settings.ActiveCollection)=CatalogBefore) and (ReadCards=CardsBefore),
      'Font/DPI control changes modified catalog metadata or personal book/group cards');
    Writeln('PASS actual Main three-row font and DPI growth restores automatic options without catalog or personal card changes'); Flush(Output);
  finally
    frmMain.ScaleForPPI(OriginalPPI); frmMain.FormAfterMonitorDpiChanged(nil,frmMain.CurrentPPI,OriginalPPI);
    frmMain.Width:=OriginalWidth; frmMain.Height:=OriginalHeight;
    Tree.Font.Assign(FontBefore); FontBefore.Free;
    Settings.ShowInfoPanel:=OriginalInfo; Settings.TreeModes[PAGE_SEARCH]:=OriginalMode;
    frmMain.pgControl.ActivePageIndex:=OriginalPage;
  end;
end;

procedure TestMainThemeToolbarStates;
var Bar, ForwardBar: TToolBar; Button, ForwardButton, ThemeButton: TToolButton;
  Forward: TMLIToolbarForwardProbe; Bitmap: TBitmap; Png: TPngImage;
  Native: TMLIToolbarNativeProbe;
  OriginalTheme, OriginalDown, OriginalEnabled, OriginalOfferDismissed: Boolean; OriginalAction: TBasicAction;
  OriginalPPI, OriginalWidth, OriginalHeight: Integer;
  MainStyles, ForwardStyles: TStyleElements; SavedDraw, SavedButtonDraw: TMethod;
  CatalogBefore, Artifacts: string;

  procedure CheckColumnResetOrder;
    procedure Check(Tree: TBookTree; LanguageLabel: TLabel; Combo: TComboBox);
    var Filters: TBookColumnFilters; SavedValue: string; Reset: TButton;
    begin
      Filters:=TBookColumnFilters.ForTree(Tree); SavedValue:=Filters.Value(COL_TITLE);
      try
        // Showing after hiding must reinsert the action before the language
        // group, including after the parent was scaled or resized while hidden.
        for var Pass:=1 to 2 do
        begin
          Filters.SetValue(COL_TITLE,''); frmMain.SetBookListTotals(Tree,0,0);
          Filters.SetValue(COL_TITLE,'fixture'); frmMain.SetBookListTotals(Tree,0,0);
          Reset:=nil;
          for var I:=0 to Combo.Parent.ControlCount-1 do
            if (Combo.Parent.Controls[I] is TButton) and
              Assigned(TButton(Combo.Parent.Controls[I]).OnClick) then
              Reset:=TButton(Combo.Parent.Controls[I]);
          Require(Assigned(Reset) and Reset.Visible,'Column reset action is absent');
          Require((Reset.BoundsRect.Right<=LanguageLabel.Left) and
            (LanguageLabel.BoundsRect.Right<=Combo.Left),
            'Column reset action splits the language label and selector');
        end;
      finally
        Filters.SetValue(COL_TITLE,SavedValue); frmMain.SetBookListTotals(Tree,0,0);
      end;
    end;
  begin
    Check(frmMain.tvBooksA,frmMain.lblLang,frmMain.cbLangSelectA);
    Check(frmMain.tvBooksS,frmMain.lbl1,frmMain.cbLangSelectS);
    Check(frmMain.tvBooksG,frmMain.lbl2,frmMain.cbLangSelectG);
    Check(frmMain.tvBooksF,frmMain.lbl3,frmMain.cbLangSelectF);
    for var Component in frmMain do
      if Component is TPublisherSeriesView then
      begin
        var View:=TPublisherSeriesView(Component);
        for var I:=0 to View.Language.Parent.ControlCount-1 do
          if (View.Language.Parent.Controls[I] is TLabel) and
            (View.Language.Parent.Controls[I]<>View.Total) and
            (View.Language.Parent.Controls[I]<>View.Title) then
            Check(View.Books,TLabel(View.Language.Parent.Controls[I]),View.Language);
      end;
    Writeln('PASS reset action precedes language label and selector across book tabs dpi=',
      frmMain.Font.PixelsPerInch,' dark=',Ord(MHLThemeDark)); Flush(Output);
  end;

  procedure CheckWindowsThemeOffer(PPI: Integer);
  var Offer, Content: TPanel; Text: TLabel; Apply, Dismiss: TButton;
    Gap, Padding: Integer; TextBounds: TRect; Capture: TBitmap;
  begin
    Require(not MHLThemeDark,'Theme suggestion geometry must use the light application theme');
    Settings.WindowsDarkThemeOfferDismissed:=False;
    for var LogicalWidth in TArray<Integer>.Create(1200,800) do
    begin
      frmMain.Width:=MulDiv(LogicalWidth,PPI,96);
      frmMain.UpdateWindowsThemeOffer(True); Application.ProcessMessages;
      Offer:=TPanel(frmMain.FindComponent('pnWindowsThemeOffer'));
      Content:=TPanel(frmMain.FindComponent('pnWindowsThemeOfferContent'));
      Text:=TLabel(frmMain.FindComponent('lblWindowsThemeOffer'));
      Apply:=TButton(frmMain.FindComponent('btnApplyWindowsTheme'));
      Dismiss:=TButton(frmMain.FindComponent('btnDismissWindowsTheme'));
      Gap:=MulDiv(8,PPI,96); Padding:=MulDiv(12,PPI,96);
      Require(Offer.Visible and (Content.Parent=Offer) and (Text.Parent=Content) and
        (Apply.Parent=Content) and (Dismiss.Parent=Content),'Theme suggestion is not one visible action group');
      Require((Content.Left>=0) and (Content.BoundsRect.Right=Offer.ClientWidth-Padding) and
        (Content.Top>=0) and (Content.BoundsRect.Bottom<=Offer.ClientHeight),
        'Theme suggestion group is clipped or no longer aligned to the right');
      Require((Text.Left=0) and (Apply.Left-Text.BoundsRect.Right=Gap) and
        (Dismiss.Left-Apply.BoundsRect.Right=Gap) and (Dismiss.BoundsRect.Right=Content.ClientWidth),
        'Theme suggestion text and buttons are separated or overlap');
      if LogicalWidth=1200 then Require(Content.Left>MulDiv(100,PPI,96),
        'Theme suggestion still begins at the left edge of a wide window');
      Text.Canvas.Font.Assign(Text.Font); TextBounds:=Rect(0,0,Text.Width,0);
      DrawText(Text.Canvas.Handle,PChar(Text.Caption),-1,TextBounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      Require((Text.Height>=TextBounds.Height) and
        (Apply.Width>=Text.Canvas.TextWidth(Apply.Caption)+2*Padding) and
        (Apply.Top>=0) and (Apply.BoundsRect.Bottom<=Content.ClientHeight) and
        (Dismiss.Top>=0) and (Dismiss.BoundsRect.Bottom<=Content.ClientHeight),
        'Theme suggestion caption or button text is clipped after window or DPI changes');
      Capture:=TBitmap.Create;
      try
        Capture.PixelFormat:=pf32bit; Capture.SetSize(Offer.ClientWidth,Offer.ClientHeight);
        Capture.Canvas.Lock;
        try Offer.PaintTo(Capture.Canvas.Handle,0,0); finally Capture.Canvas.Unlock; end;
        Png.Assign(Capture); Png.SaveToFile(TPath.Combine(Artifacts,
          'theme-offer-'+IntToStr(PPI)+'-'+IntToStr(LogicalWidth)+'.png'));
      finally Capture.Free; end;
      Writeln('PASS Windows theme suggestion grouped at right with adjacent unclipped text and actions dpi=',PPI,
        ' logical_width=',LogicalWidth); Flush(Output);
    end;
    Dismiss.Click; frmMain.UpdateWindowsThemeOffer(True);
    Require(Settings.WindowsDarkThemeOfferDismissed and not Offer.Visible,
      'Grouped theme suggestion lost its dismissal behavior');
    frmMain.UpdateWindowsThemeOffer(False); frmMain.UpdateWindowsThemeOffer(True);
    Require(Offer.Visible,'Grouped theme suggestion did not return for a new Windows dark-theme cycle');
    Apply.Click; Application.ProcessMessages;
    Require(MHLThemeDark and Settings.DarkTheme and not Offer.Visible,
      'Grouped theme suggestion did not apply the dark application theme');
    ThemeButton.OnClick(ThemeButton); Application.ProcessMessages;
    Require(not MHLThemeDark,'Grouped suggestion fixture did not restore the light theme');
  end;

  procedure CheckNativePair;
  var R: TRect; IdleColor, ActiveColor, ActiveLine: TColor;
    procedure Capture(const Name: string; Down: Boolean; out Color, Underline: TColor);
    var CaptureBitmap: TBitmap; TargetDC: HDC;
    begin
      CaptureBitmap:=TBitmap.Create;
      try
        CaptureBitmap.PixelFormat:=pf32bit;
        Button.Enabled:=True; Button.Down:=Down;
        SendMessage(Bar.Handle,TB_SETHOTITEM,WPARAM(NativeInt(-1)),0);
        CaptureBitmap.SetSize(Bar.ClientWidth,Bar.ClientHeight); CaptureBitmap.Canvas.Brush.Color:=clFuchsia;
        CaptureBitmap.Canvas.FillRect(Rect(0,0,CaptureBitmap.Width,CaptureBitmap.Height));
        Native.DrawCalls:=0; Native.ButtonCalls:=0;
        // PaintTo requires a locked canvas: HWND painting can evict an unlocked
        // cached bitmap DC. See Vcl.Controls.TWinControl.PaintTo documentation.
        CaptureBitmap.Canvas.Lock;
        try
          TargetDC:=CaptureBitmap.Canvas.Handle;
          Require(GetObjectType(TargetDC)=OBJ_MEMDC,'Native toolbar target DC is invalid before painting');
          Native.ExpectedDC:=TargetDC; Native.TargetButton:=Button;
          Bar.PaintTo(TargetDC,0,0);
          Writeln('TRACE native toolbar target DC before/after valid=1/',Ord(GetObjectType(TargetDC)=OBJ_MEMDC)); Flush(Output);
          Require(GetObjectType(TargetDC)=OBJ_MEMDC,'Actual native toolbar painting destroyed its independent target DC');
        finally CaptureBitmap.Canvas.Unlock; end;
        Require((Native.DrawCalls>0) and (Native.ButtonCalls>0),
          'Actual native toolbar painting did not invoke its registered custom draw notifications');
        R:=Button.BoundsRect;
        Require((R.Left>=0) and (R.Top>=0) and (R.Right<=CaptureBitmap.Width) and (R.Bottom<=CaptureBitmap.Height),
          'Native toolbar state button is outside the captured surface');
        Color:=ColorToRGB(CaptureBitmap.Canvas.Pixels[(R.Left+R.Right) div 2,R.Top+3]);
        Underline:=ColorToRGB(CaptureBitmap.Canvas.Pixels[(R.Left+R.Right) div 2,R.Bottom-3]);
        Png.Assign(CaptureBitmap); Png.SaveToFile(TPath.Combine(Artifacts,
          'toolbar-'+IntToStr(Bar.Font.PixelsPerInch)+'-native-'+Name+'.png'));
        Writeln('TRACE native toolbar dpi=',Bar.Font.PixelsPerInch,' state=',Name,
          ' draw=',Native.DrawCalls,' button=',Native.ButtonCalls,' surface=',IntToHex(Color,6),
          ' underline=',IntToHex(Underline,6)); Flush(Output);
      finally CaptureBitmap.Free; end;
    end;
  begin
    Native.OriginalDraw:=Bar.OnCustomDraw; Native.OriginalButton:=Bar.OnCustomDrawButton;
    Bar.OnCustomDraw:=Native.Draw; Bar.OnCustomDrawButton:=Native.DrawButton;
    try
      Capture('idle',False,IdleColor,ActiveLine);
      Capture('checked',True,ActiveColor,ActiveLine);
      Require(IdleColor=ColorToRGB(MHLThemeBackground),'Actual native idle toolbar still looks raised or pressed');
      Require((ActiveColor<>IdleColor) and (GetBValue(ActiveColor)>GetRValue(ActiveColor)) and
        (ActiveLine<>ActiveColor),'Actual native checked toolbar lost its blue active surface or underline');
    finally Bar.OnCustomDraw:=Native.OriginalDraw; Bar.OnCustomDrawButton:=Native.OriginalButton; end;
  end;

  function DrawState(const Name: string; Down, Enabled: Boolean; State: TCustomDrawState;
    out FillColor, UnderlineColor: TColor): string;
  var DefaultDraw: Boolean; R: TRect; FileName: string;
  begin
    Button.Enabled:=Enabled; Button.Down:=Down; R:=Button.BoundsRect;
    Require((R.Width>=16) and (R.Height>=20),'Actual Main toolbar button has no usable native bounds');
    Bitmap.SetSize(Max(Bar.ClientWidth,R.Right+2),Max(Bar.ClientHeight,R.Bottom+2));
    Bitmap.Canvas.Brush.Color:=clFuchsia; Bitmap.Canvas.FillRect(Rect(0,0,Bitmap.Width,Bitmap.Height));
    // Exercise registered production callbacks with a disjoint owned DC.
    MLIPaintToolbarCanvas(Bar,Bitmap,
      procedure(Target: TToolBar)
      begin
        DefaultDraw:=True; Bar.OnCustomDraw(Target,Bar.ClientRect,DefaultDraw);
        DefaultDraw:=True; Bar.OnCustomDrawButton(Target,Button,State,DefaultDraw);
        Require(not DefaultDraw,'Dark toolbar callback delegated button painting to the stock raised style');
      end);
    FillColor:=ColorToRGB(Bitmap.Canvas.Pixels[(R.Left+R.Right) div 2,R.Top+3]);
    UnderlineColor:=ColorToRGB(Bitmap.Canvas.Pixels[(R.Left+R.Right) div 2,R.Bottom-3]);
    FileName:=TPath.Combine(Artifacts,'toolbar-'+IntToStr(Bar.Font.PixelsPerInch)+'-'+Name+'.png');
    Png.Assign(Bitmap); Png.SaveToFile(FileName); Result:=THashSHA2.GetHashStringFromFile(FileName);
  end;

  procedure CheckForwarding(Expected: Boolean);
  var DefaultDraw: Boolean;
  begin
    Bitmap.SetSize(Max(ForwardBar.Width,ForwardButton.BoundsRect.Right+2),Max(ForwardBar.Height,ForwardButton.BoundsRect.Bottom+2));
    Forward.DrawCalls:=0; Forward.ButtonCalls:=0;
    MLIPaintToolbarCanvas(ForwardBar,Bitmap,
      procedure(Target: TToolBar)
      begin
        DefaultDraw:=True; ForwardBar.OnCustomDraw(Target,ForwardBar.ClientRect,DefaultDraw);
        Require(not DefaultDraw or not Expected,'Light toolbar lost the original whole-bar drawing result');
        DefaultDraw:=True; ForwardBar.OnCustomDrawButton(Target,ForwardButton,[],DefaultDraw);
        Require(not DefaultDraw,'Toolbar button callback lost its custom painting result');
      end);
    if Expected then
    begin
      Require((Forward.DrawCalls=1) and (Forward.ButtonCalls=1),'Light toolbar did not forward both original callbacks exactly once');
      var R:=ForwardButton.BoundsRect;
      Require(ColorToRGB(Bitmap.Canvas.Pixels[(R.Left+R.Right) div 2,(R.Top+R.Bottom) div 2])=RGB(91,17,121),
        'Light toolbar did not preserve the original custom button pixels');
    end
    else Require((Forward.DrawCalls=0) and (Forward.ButtonCalls=0),
      'Dark toolbar unexpectedly ran light-only callbacks');
  end;

begin
  RequireIsolatedRegression;
  OriginalTheme:=MHLThemeDark; OriginalPPI:=frmMain.Font.PixelsPerInch;
  OriginalOfferDismissed:=Settings.WindowsDarkThemeOfferDismissed;
  OriginalWidth:=frmMain.Width; OriginalHeight:=frmMain.Height;
  CatalogBefore:=MLIReadCatalogData(Settings.ActiveCollection);
  Bar:=frmMain.tlbrMain; Button:=frmMain.tbtnShowDeleted; ThemeButton:=nil;
  for var Component in frmMain do
    if (Component is TToolButton) and (TToolButton(Component).ImageIndex=25) and
      Assigned(TToolButton(Component).OnClick) then ThemeButton:=TToolButton(Component);
  Require(Assigned(ThemeButton),'Actual Main application theme button is absent');
  OriginalAction:=Button.Action; OriginalDown:=Button.Down; OriginalEnabled:=Button.Enabled;
  Forward:=TMLIToolbarForwardProbe.Create; Native:=TMLIToolbarNativeProbe.Create;
  ForwardBar:=nil; Bitmap:=TBitmap.Create; Png:=TPngImage.Create;
  Artifacts:=TPath.Combine(Settings.AppPath,'theme-toolbar-states'); ForceDirectories(Artifacts);
  try
    if MHLThemeDark then ThemeButton.OnClick(ThemeButton);
    MainStyles:=Bar.StyleElements;
    ForwardBar:=TToolBar.Create(frmMain); ForwardBar.Parent:=frmMain; ForwardBar.Visible:=False;
    ForwardBar.SetBounds(0,0,120,48); ForwardBar.StyleElements:=[seFont,seBorder];
    ForwardBar.ButtonHeight:=40; ForwardBar.ButtonWidth:=32;
    ForwardBar.OnCustomDraw:=Forward.Draw; ForwardBar.OnCustomDrawButton:=Forward.DrawButton;
    ForwardButton:=TToolButton.Create(ForwardBar); ForwardButton.Parent:=ForwardBar;
    ForwardButton.Caption:='Fixture'; ForwardStyles:=ForwardBar.StyleElements;
    Button.Action:=nil; Bitmap.PixelFormat:=pf32bit;
    for var PPI in TArray<Integer>.Create(96,144,192) do
    begin
      frmMain.ScaleForPPI(PPI); frmMain.FormAfterMonitorDpiChanged(nil,frmMain.CurrentPPI,PPI);
      Require(Bar.Font.PixelsPerInch=PPI,'Toolbar did not adopt the requested native DPI');
      CheckWindowsThemeOffer(PPI);
      CheckColumnResetOrder;
      ThemeButton.OnClick(ThemeButton);
      CheckColumnResetOrder;
      Require(MHLThemeDark and (Bar.StyleElements=[]) and (ForwardBar.StyleElements=[]),
        'Dark toolbar still applies the stock VCL raised button style');
      Require(Assigned(Bar.OnCustomDraw) and Assigned(Bar.OnCustomDrawButton),
        'Actual Main toolbar lacks native custom drawing callbacks');
      SavedDraw:=TMethod(Bar.OnCustomDraw); SavedButtonDraw:=TMethod(Bar.OnCustomDrawButton);
      var Normal, Checked, Disabled, Hover, Pressed, HoverChecked: TColor;
      var NormalLine, CheckedLine, DisabledLine, HoverLine, PressedLine, HoverCheckedLine: TColor;
      var NormalHash:=DrawState('normal',False,True,[],Normal,NormalLine);
      var CheckedHash:=DrawState('checked',True,True,[],Checked,CheckedLine);
      var DisabledHash:=DrawState('disabled',False,False,[cdsDisabled],Disabled,DisabledLine);
      var HoverHash:=DrawState('hover',False,True,[cdsHot],Hover,HoverLine);
      var PressedHash:=DrawState('pressed',False,True,[cdsSelected],Pressed,PressedLine);
      DrawState('hover-checked',True,True,[cdsHot],HoverChecked,HoverCheckedLine);
      Require(Normal=ColorToRGB(MHLThemeBackground),'Idle toolbar button looks filled or pressed instead of matching its surface');
      Require((Checked<>Normal) and (GetBValue(Checked)>GetRValue(Checked)) and (CheckedLine<>Checked),
        'Checked toolbar button lacks a distinct blue active surface and underline');
      Require((Hover<>Normal) and (Pressed<>Normal) and (Pressed<>Hover) and (Pressed<>Checked),
        'Hover, pressed and checked toolbar states cannot be distinguished');
      Require((Disabled=Normal) and (DisabledHash<>NormalHash),'Disabled toolbar button looks active or keeps its enabled icon');
      Require((CheckedHash<>NormalHash) and (HoverHash<>NormalHash) and (PressedHash<>HoverHash),
        'Actual toolbar state pixel images are indistinguishable');
      Require((HoverChecked=Checked) and (HoverCheckedLine=CheckedLine),'Hover erased the active checked indicator');
      CheckNativePair;
      CheckForwarding(False);
      Button.Down:=OriginalDown; Button.Enabled:=OriginalEnabled;
      ThemeButton.OnClick(ThemeButton);
      Require(not MHLThemeDark and (Bar.StyleElements=MainStyles) and (ForwardBar.StyleElements=ForwardStyles),
        'Light restoration lost the original toolbar style elements');
      Require((TMethod(Bar.OnCustomDraw).Code=SavedDraw.Code) and (TMethod(Bar.OnCustomDraw).Data=SavedDraw.Data) and
        (TMethod(Bar.OnCustomDrawButton).Code=SavedButtonDraw.Code) and (TMethod(Bar.OnCustomDrawButton).Data=SavedButtonDraw.Data),
        'Theme toggling duplicated or disconnected toolbar callback ownership');
      CheckForwarding(True);
      var DefaultDraw:=True;
      MLIPaintToolbarCanvas(Bar,Bitmap,
        procedure(Target: TToolBar) begin Bar.OnCustomDrawButton(Target,Button,[],DefaultDraw); end);
      Require(DefaultDraw,'Actual light Main toolbar failed to restore normal native button drawing');
      Writeln('PASS actual Main toolbar normal/checked/disabled/hover/pressed pixels and light callback/style restoration dpi=',PPI); Flush(Output);
    end;
    Require(MLIReadCatalogData(Settings.ActiveCollection)=CatalogBefore,'Toolbar state testing changed catalog or personal book data');
  finally
    Button.Action:=OriginalAction; Button.Down:=OriginalDown; Button.Enabled:=OriginalEnabled;
    ForwardBar.Free; Forward.Free; Native.Free; Png.Free; Bitmap.Free;
    frmMain.ScaleForPPI(OriginalPPI); frmMain.FormAfterMonitorDpiChanged(nil,frmMain.CurrentPPI,OriginalPPI);
    frmMain.Width:=OriginalWidth; frmMain.Height:=OriginalHeight;
    if MHLThemeDark<>OriginalTheme then ThemeButton.OnClick(ThemeButton);
    Settings.WindowsDarkThemeOfferDismissed:=OriginalOfferDismissed;
    frmMain.UpdateWindowsThemeOffer(False);
    Settings.WindowsDarkThemeOfferDismissed:=OriginalOfferDismissed;
    Settings.SaveSettings;
  end;
  Require((frmMain.Font.PixelsPerInch=OriginalPPI) and (frmMain.Width=OriginalWidth) and
    (frmMain.Height=OriginalHeight) and (MHLThemeDark=OriginalTheme),'Toolbar fixture did not restore Main DPI, dimensions and theme');
  Writeln('PASS Main toolbar state matrix restores original theme, DPI and window without catalog changes'); Flush(Output);
  TestMainTreeMetricChanges;
end;
