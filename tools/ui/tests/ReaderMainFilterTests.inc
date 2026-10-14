// Real Main reader path and native sole-selection ordering. Private G only.
// Include after TestListPerformance and the shared native assertion helpers.
type
  TRMFMainReaderDriver = class
  public
    Timer: TTimer;
    Probe: TActionScanProbe;
    Active, Finished: Boolean;
    Started, PageStarted: UInt64;
    PageIndex, CheckedVisits, IdleCycles: Integer;
    OpenMS, MaxPageMS, TotalPageMS, IdleMS: Int64;
    VisibleMS, BeforeVisibleIdleMS, LoadingIdleMS, PagingIdleMS: Int64;
    InitialPosition, MaxPreparations, MaxBusyPreviews: Integer;
    LastStatus: string;
    Title, Failure, TextHash: string;
    constructor Create;
    destructor Destroy; override;
    procedure UpdateAllActions;
    procedure Tick(Sender: TObject);
    procedure BeginRead(const BookTitle: string);
  end;

procedure RMFTaskCounts(out Preparations, BusyPreviews, Readers: Integer);
begin
  Preparations:=0; BusyPreviews:=0; Readers:=0;
  for var I:=0 to frmMain.ComponentCount-1 do
  begin
    var Component:=frmMain.Components[I];
    if Component.ClassName='TReaderPreparation' then Inc(Preparations);
    if (Component is TBookInfoPreview) and TBookInfoPreview(Component).Busy then Inc(BusyPreviews);
  end;
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I] is TfrmBuiltinReader then Inc(Readers);
end;

constructor TRMFMainReaderDriver.Create;
begin
  inherited;
  Timer:=TTimer.Create(nil); Timer.Interval:=10; Timer.Enabled:=False; Timer.OnTimer:=Tick;
  Probe:=TActionScanProbe.Create;
end;

destructor TRMFMainReaderDriver.Destroy;
begin Timer.Free; Probe.Free; inherited; end;

procedure TRMFMainReaderDriver.UpdateAllActions;
var Before: Integer; Start: UInt64;
begin
  Before:=Probe.Visits; Start:=GetTickCount64;
  for var I:=0 to frmMain.Actions.ActionCount-1 do
    try frmMain.Actions.Actions[I].Update;
    except
      on E: Exception do
      begin
        Writeln('DIAGNOSTIC actual Main action=',frmMain.Actions.Actions[I].Name,
          ' active_collection=',Settings.ActiveCollection,' error=',E.ClassName,': ',E.Message);
        Flush(Output); raise;
      end;
    end;
  Inc(CheckedVisits,Probe.Visits-Before); Inc(IdleCycles);
  Inc(IdleMS,Int64(GetTickCount64-Start));
end;

procedure TRMFMainReaderDriver.BeginRead(const BookTitle: string);
begin
  Title:=BookTitle; Failure:=''; TextHash:=''; Finished:=False; Active:=True;
  CheckedVisits:=0; IdleCycles:=0; OpenMS:=-1; MaxPageMS:=0; TotalPageMS:=0; IdleMS:=0;
  VisibleMS:=-1; BeforeVisibleIdleMS:=0; LoadingIdleMS:=0; PagingIdleMS:=0;
  InitialPosition:=-1; MaxPreparations:=0; MaxBusyPreviews:=0; LastStatus:='';
  PageIndex:=0; Started:=GetTickCount64; PageStarted:=0;
  Timer.Enabled:=True;
end;

procedure TRMFMainReaderDriver.Tick(Sender: TObject);
var Reader: TfrmBuiltinReader; Elapsed, BeforeIdle: Int64;
  Preparations, BusyPreviews, Readers: Integer;
begin
  if not Active then Exit;
  Reader:=nil;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBuiltinReader) and Screen.Forms[I].Visible then
    begin Reader:=TfrmBuiltinReader(Screen.Forms[I]); Break; end;
  try
    RMFTaskCounts(Preparations,BusyPreviews,Readers);
    MaxPreparations:=Max(MaxPreparations,Preparations); MaxBusyPreviews:=Max(MaxBusyPreviews,BusyPreviews);
    if Assigned(Reader) and (VisibleMS<0) then
    begin
      VisibleMS:=GetTickCount64-Started;
      Writeln('PROFILE actual Main reader visible_ms=',VisibleMS,' preparations=',Preparations,
        ' busy_previews=',BusyPreviews,' load_finished=',Ord(Reader.LoadFinished),
        ' ready=',Ord(Reader.Ready),' bounds=',Reader.Left,',',Reader.Top,',',Reader.Width,',',Reader.Height);
      Flush(Output);
    end;
    if Assigned(Reader) and (Reader.ReaderStatus.Caption<>LastStatus) then
    begin
      LastStatus:=Reader.ReaderStatus.Caption;
      Writeln('PROFILE actual Main reader status_ms=',GetTickCount64-Started,' status=',LastStatus,
        ' load_finished=',Ord(Reader.LoadFinished),' ready=',Ord(Reader.Ready)); Flush(Output);
    end;
    BeforeIdle:=IdleMS;
    UpdateAllActions;
    if not Assigned(Reader) then Inc(BeforeVisibleIdleMS,IdleMS-BeforeIdle)
    else if PageIndex=0 then Inc(LoadingIdleMS,IdleMS-BeforeIdle)
    else Inc(PagingIdleMS,IdleMS-BeforeIdle);
    Require(GetTickCount64-Started<20000,'Actual Main reader exceeded native opening/paging deadline');
    if not Assigned(Reader) then Exit;
    Require(string(Reader.Caption).Contains(Title),'Actual Main action opened a different selected book');
    Require(not string(Reader.ReaderStatus.Caption).StartsWith('Не удалось'),'Actual Main reader failed: '+Reader.ReaderStatus.Caption);
    if not Reader.Ready or Reader.PageLoading then Exit;
    if PageIndex=0 then
    begin
      OpenMS:=GetTickCount64-Started;
      InitialPosition:=Reader.TextPosition;
      Require(InitialPosition=0,'Actual Main filter trial did not open the identical initial text position');
      Require(Reader.BookText.Length>10000,'Actual Main reader has no large FB2 body');
      TextHash:=THashSHA2.GetHashString(Reader.BookText);
      PageIndex:=1; PageStarted:=GetTickCount64; Reader.NextPage; Exit;
    end;
    Elapsed:=GetTickCount64-PageStarted;
    MaxPageMS:=Max(MaxPageMS,Elapsed); Inc(TotalPageMS,Elapsed);
    Require(Elapsed<1500,'Actual Main reader page turn blocks for seconds');
    if PageIndex<5 then
    begin Inc(PageIndex); PageStarted:=GetTickCount64; Reader.NextPage; Exit; end;
    Require(Reader.Visible,'Actual Main paging hid/closed the reader');
    Active:=False; Finished:=True; Timer.Enabled:=False; Reader.Close;
  except
    on E: Exception do
    begin
      Failure:=E.ClassName+': '+E.Message; Active:=False; Finished:=True; Timer.Enabled:=False;
      if Assigned(Reader) then Reader.Close;
    end;
  end;
end;

function RMFOldNextSelected(Tree: TBaseVirtualTree; Node: PVirtualNode; ChildrenAbove: Boolean): PVirtualNode;
begin
  Result:=nil;
  if Tree.SelectedCount=0 then Exit;
  if not Assigned(Node) or (Node=Tree.RootNode) then Result:=Tree.GetFirstNoInit(ChildrenAbove)
  else Result:=Tree.GetNextNoInit(Node,ChildrenAbove);
  while Assigned(Result) and not (vsSelected in Result.States) do Result:=Tree.GetNextNoInit(Result,ChildrenAbove);
end;

function RMFOldSortedSelection(Tree: TBaseVirtualTree; Resolve: Boolean): TNodeArray;
var Node, Parent: PVirtualNode; Included: Boolean;
begin
  Result:=nil; Node:=Tree.GetFirstNoInit;
  while Assigned(Node) do
  begin
    if vsSelected in Node.States then
    begin
      Included:=True;
      if Resolve then
      begin
        Parent:=Node.Parent;
        while Assigned(Parent) and (Parent<>Tree.RootNode) do
        begin if vsSelected in Parent.States then begin Included:=False; Break; end; Parent:=Parent.Parent; end;
      end;
      if Included then begin SetLength(Result,Length(Result)+1); Result[High(Result)]:=Node; end;
    end;
    Node:=Tree.GetNextNoInit(Node);
  end;
end;

type
  TRMFSelectionTree = class(TBookTree)
  public property OnRemoveFromSelection; end;
  TRMFDirtySelectionProbe = class
  public
    Events, InitCalls: Integer;
    Failure: string;
    AddDuringRemove: PVirtualNode;
    procedure Removed(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure Initialized(Sender: TBaseVirtualTree; Parent, Node: PVirtualNode; var InitialStates: TVirtualNodeInitStates);
  end;

procedure TRMFDirtySelectionProbe.Removed(Sender: TBaseVirtualTree; Node: PVirtualNode);
var Expected, Actual: TNodeArray; Added: PVirtualNode;
begin
  Inc(Events);
  try
    // This event runs after the removed pointer is tagged, before packing
    // and sometimes before its node has been disconnected/freed.
    for var ChildrenAbove in TArray<Boolean>.Create(False,True) do
      Require(Sender.GetFirstSelected(ChildrenAbove)=RMFOldNextSelected(Sender,nil,ChildrenAbove),
        'Remove-selection callback dereferenced a dirty pointer or changed sole selection');
    for var Resolve in TArray<Boolean>.Create(False,True) do
    begin
      Expected:=RMFOldSortedSelection(Sender,Resolve); Actual:=Sender.GetSortedSelection(Resolve);
      Require(Length(Expected)=Length(Actual),'Remove-selection callback changed sorted count');
      for var I:=0 to High(Expected) do Require(Expected[I]=Actual[I],'Remove-selection callback changed sorted order');
    end;
    if Assigned(AddDuringRemove) then
    begin
      Added:=AddDuringRemove; AddDuringRemove:=nil;
      Sender.Selected[Added]:=True;
      Expected:=RMFOldSortedSelection(Sender,False); Actual:=Sender.GetSortedSelection(False);
      Require(Length(Expected)=Length(Actual),'Reentrant add changed live selected count');
      for var I:=0 to High(Expected) do Require(Expected[I]=Actual[I],'Reentrant add changed selection identities');
    end;
  except on E: Exception do Failure:=E.ClassName+': '+E.Message; end;
end;

procedure TRMFDirtySelectionProbe.Initialized(Sender: TBaseVirtualTree; Parent, Node: PVirtualNode;
  var InitialStates: TVirtualNodeInitStates);
begin Inc(InitCalls); end;

procedure TestNativeSingleSelectionOrder;
var Tree: TRMFSelectionTree; ParentOne, ChildOne, ChildTwo, ParentTwo, Removed, Survivor: PVirtualNode;
  Dirty: TRMFDirtySelectionProbe;
  Expected, Actual, PointerSorted: TNodeArray; ExpectedNode, ActualNode, SwapNode: PVirtualNode;

  procedure Compare(const Scenario: string);
  begin
    for var ChildrenAbove in TArray<Boolean>.Create(False,True) do
    begin
      Tree.TreeOptions.PaintOptions:=Tree.TreeOptions.PaintOptions-[toChildrenAbove];
      if ChildrenAbove then Tree.TreeOptions.PaintOptions:=Tree.TreeOptions.PaintOptions+[toChildrenAbove];
      ExpectedNode:=RMFOldNextSelected(Tree,nil,ChildrenAbove); ActualNode:=Tree.GetFirstSelected(ChildrenAbove);
      Require(ActualNode=ExpectedNode,Scenario+': first selection logical order changed');
      Require(Tree.GetNextSelected(Tree.RootNode,ChildrenAbove)=ExpectedNode,Scenario+': root selection lookup changed');
      while Assigned(ExpectedNode) do
      begin
        ExpectedNode:=RMFOldNextSelected(Tree,ExpectedNode,ChildrenAbove);
        ActualNode:=Tree.GetNextSelected(ActualNode,ChildrenAbove);
        Require(ActualNode=ExpectedNode,Scenario+': next-selection traversal changed');
      end;
      Require(Tree.GetNextSelected(ParentOne,ChildrenAbove)=RMFOldNextSelected(Tree,ParentOne,ChildrenAbove),
        Scenario+': starting from another node changed traversal');
    end;
    for var Resolve in TArray<Boolean>.Create(False,True) do
    begin
      Expected:=RMFOldSortedSelection(Tree,Resolve); Actual:=Tree.GetSortedSelection(Resolve);
      if Length(Actual)<>Length(Expected) then
      begin
        Writeln('DIAGNOSTIC selection scenario=',Scenario,' resolve=',Ord(Resolve),
          ' selected_count=',Tree.SelectedCount,' expected_count=',Length(Expected),' actual_count=',Length(Actual));
        for var I:=0 to High(Expected) do Writeln('DIAGNOSTIC expected node=',IntToHex(NativeUInt(Expected[I]),SizeOf(Pointer)*2));
        for var I:=0 to High(Actual) do Writeln('DIAGNOSTIC actual node=',IntToHex(NativeUInt(Actual[I]),SizeOf(Pointer)*2));
        Flush(Output);
      end;
      Require(Length(Actual)=Length(Expected),Scenario+': sorted/resolved selection count changed');
      for var I:=0 to High(Expected) do Require(Actual[I]=Expected[I],Scenario+': sorted/resolved selection order changed');
    end;
  end;

  procedure RebuildMutationCase;
  begin
    Tree.OnRemoveFromSelection:=nil; Tree.OnInitNode:=nil; Tree.Clear;
    ParentOne:=Tree.AddChild(nil); ChildOne:=Tree.AddChild(nil);
    ChildTwo:=Tree.AddChild(nil); ParentTwo:=Tree.AddChild(nil);
    Tree.GetNodeData(ParentOne); Tree.GetNodeData(ChildOne); Tree.GetNodeData(ChildTwo); Tree.GetNodeData(ParentTwo);
    PointerSorted:=TNodeArray.Create(ChildOne,ChildTwo,ParentTwo);
    for var I:=0 to High(PointerSorted)-1 do
      for var J:=I+1 to High(PointerSorted) do
        if NativeUInt(PointerSorted[I])>NativeUInt(PointerSorted[J]) then
        begin SwapNode:=PointerSorted[I]; PointerSorted[I]:=PointerSorted[J]; PointerSorted[J]:=SwapNode; end;
    Dirty.Events:=0; Dirty.Failure:=''; Dirty.AddDuringRemove:=nil;
    Tree.OnRemoveFromSelection:=Dirty.Removed;
  end;

begin
  Tree:=TRMFSelectionTree.Create(nil); Dirty:=TRMFDirtySelectionProbe.Create;
  try
    Tree.Parent:=frmMain; Tree.Visible:=False; Tree.NodeDataSize:=SizeOf(Integer);
    ParentOne:=Tree.AddChild(nil); ChildOne:=Tree.AddChild(ParentOne); ChildTwo:=Tree.AddChild(ParentOne);
    ParentTwo:=Tree.AddChild(nil);
    Tree.GetNodeData(ParentOne); Tree.GetNodeData(ChildOne); Tree.GetNodeData(ChildTwo); Tree.GetNodeData(ParentTwo);
    Tree.ClearSelection; Compare('Zero selection');
    Tree.Selected[ChildTwo]:=True; Tree.FocusedNode:=ChildTwo; Compare('One focused selection');
    Tree.FocusedNode:=nil; Compare('One selection with no focus');
    Tree.FocusedNode:=ParentTwo; Compare('One selection with another unselected focus');
    Tree.IsFiltered[ChildTwo]:=True;
    Require(Tree.SelectedCount=1,'Hidden sole-selection fixture unexpectedly lost its selected state');
    Compare('One hidden selection'); Tree.IsFiltered[ChildTwo]:=False;
    Tree.Selected[ParentOne]:=True; Tree.Selected[ChildOne]:=True; Tree.Selected[ParentTwo]:=True;
    Compare('Multiple parent/child/sibling selections');
    Tree.Selected[ChildTwo]:=False; Tree.Selected[ChildOne]:=False; Tree.Selected[ParentOne]:=False;
    Compare('Selection array after removals');
    Tree.ClearSelection; Compare('Cleared selection');
    // The selection array is pointer-sorted. Remove its lowest-address slot
    // during BeginUpdate: count becomes one while slot zero stays tagged.
    Removed:=ChildOne; Survivor:=ParentTwo;
    if NativeUInt(Removed)>NativeUInt(Survivor) then begin Removed:=ParentTwo; Survivor:=ChildOne; end;
    Tree.Selected[Removed]:=True; Tree.Selected[Survivor]:=True;
    Tree.OnRemoveFromSelection:=Dirty.Removed;
    Tree.BeginUpdate;
    try
      Tree.DeleteNode(Removed);
      Require(Tree.SelectedCount=1,'Locked deletion did not leave a sole survivor');
      Require((Dirty.Events=1) and (Dirty.Failure=''),'Dirty remove-selection event failed: '+Dirty.Failure);
      Require(Tree.GetFirstSelected=Survivor,'Locked deletion returned freed/tagged selected pointer');
      Compare('Locked deletion before selection packing');
    finally Tree.EndUpdate; end;
    Require((Tree.SelectedCount=1) and Tree.Selected[Survivor],
      'Selection packing lost the remaining live selected node');
    Require(Tree.GetFirstSelected=Survivor,'Selection packing changed the live survivor identity');
    Compare('Locked deletion after selection packing');
    // GetSortedSelection keeps its no-init contract; GetFirstSelected keeps
    // the existing InitNode call even on its new direct sole-selection path.
    Tree.OnInitNode:=Dirty.Initialized; Dirty.InitCalls:=0;
    Survivor.States:=Survivor.States-[vsInitialized];
    Actual:=Tree.GetSortedSelection(False);
    Require((Length(Actual)=1) and (Actual[0]=Survivor) and (Dirty.InitCalls=0) and
      not (vsInitialized in Survivor.States),'Sorted sole selection unexpectedly initialized a node');
    Require(Tree.GetFirstSelected=Survivor,'First sole selection changed during native node initialization');
    Require((Dirty.InitCalls=1) and (vsInitialized in Survivor.States),'First sole selection skipped/repeated required InitNode');
    Require((Tree.GetFirstSelected(True)=Survivor) and (Dirty.InitCalls=1),'Repeated sole selection initialized again');
    Tree.BeginUpdate;
    try
      Tree.Clear;
      Require((Tree.GetFirstSelected=nil) and (Length(Tree.GetSortedSelection(False))=0),'Locked clear retained deleted selection pointers');
    finally Tree.EndUpdate; end;
    Require(Dirty.Failure='','Clear remove-selection callback failed: '+Dirty.Failure);
    ParentOne:=Tree.AddChild(nil); ParentTwo:=Tree.AddChild(nil);
    Tree.GetNodeData(ParentOne); Tree.GetNodeData(ParentTwo); Tree.Selected[ParentTwo]:=True;
    Compare('Clear/rebuild after old selected nodes freed');
    // Repeated removals must search the entire pointer-sorted physical array,
    // not its shrinking live prefix. All assertions use independent traversal.
    RebuildMutationCase;
    for var Item in PointerSorted do Tree.Selected[Item]:=True;
    Survivor:=PointerSorted[2]; Tree.BeginUpdate;
    try
      Tree.DeleteNode(PointerSorted[0]); Tree.DeleteNode(PointerSorted[1]);
      Require((Tree.SelectedCount=1) and Tree.Selected[Survivor], 'Repeated locked deletion lost live selected identity');
      Compare('Two locked deletions before packing');
    finally Tree.EndUpdate; end;
    Require((Tree.SelectedCount=1) and Tree.Selected[Survivor], 'Repeated locked deletion packing lost survivor');
    Require(Dirty.Failure='','Repeated deletion callback failed: '+Dirty.Failure);
    Compare('Two locked deletions after packing');

    RebuildMutationCase;
    Tree.Selected[PointerSorted[0]]:=True; Tree.Selected[PointerSorted[2]]:=True;
    Survivor:=PointerSorted[2]; Tree.BeginUpdate;
    try
      Tree.DeleteNode(PointerSorted[0]); Tree.Selected[PointerSorted[1]]:=True;
      Require((Tree.SelectedCount=2) and Tree.Selected[Survivor] and Tree.Selected[PointerSorted[1]],
        'Locked deletion followed by addition lost either live identity');
      Compare('Locked deletion and addition before packing');
    finally Tree.EndUpdate; end;
    Require((Tree.SelectedCount=2) and Tree.Selected[Survivor] and Tree.Selected[PointerSorted[1]],
      'Locked deletion and addition packing lost a selected node');
    Require(Dirty.Failure='','Deletion/addition callback failed: '+Dirty.Failure);
    Compare('Locked deletion and addition after packing');

    RebuildMutationCase;
    for var Item in PointerSorted do Tree.Selected[Item]:=True;
    Survivor:=PointerSorted[2]; Tree.BeginUpdate;
    try
      Tree.DeleteNode(PointerSorted[0]); Tree.Selected[PointerSorted[1]]:=False;
      Require((Tree.SelectedCount=1) and Tree.Selected[Survivor] and not Tree.Selected[PointerSorted[1]],
        'Locked deletion followed by public deselection lost its remaining identity');
      Compare('Locked deletion and deselection before packing');
    finally Tree.EndUpdate; end;
    Require((Tree.SelectedCount=1) and Tree.Selected[Survivor], 'Deletion/deselection packing lost survivor');
    Require(Dirty.Failure='','Deletion/deselection callback failed: '+Dirty.Failure);
    Compare('Locked deletion and deselection after packing');

    RebuildMutationCase;
    Tree.Selected[PointerSorted[0]]:=True; Tree.Selected[PointerSorted[2]]:=True;
    Tree.BeginUpdate;
    try
      Tree.InvertSelection(False);
      Require((Tree.SelectedCount=2) and Tree.Selected[ParentOne] and Tree.Selected[PointerSorted[1]] and
        not Tree.Selected[PointerSorted[0]] and not Tree.Selected[PointerSorted[2]],
        'Inverting selection did not preserve the exact complement of the live rows');
      Compare('Inverted mixed selection before packing');
    finally Tree.EndUpdate; end;
    Require(Dirty.Failure='','Inverted selection callback failed: '+Dirty.Failure);
    Compare('Inverted mixed selection after packing');

    RebuildMutationCase;
    Tree.Selected[PointerSorted[0]]:=True; Tree.Selected[PointerSorted[2]]:=True;
    Dirty.AddDuringRemove:=PointerSorted[1]; Survivor:=PointerSorted[2]; Tree.BeginUpdate;
    try
      Tree.DeleteNode(PointerSorted[0]);
      Require((Dirty.Events=1) and (Dirty.Failure=''), 'Reentrant deletion/add callback failed: '+Dirty.Failure);
      Require((Tree.SelectedCount=2) and Tree.Selected[Survivor] and Tree.Selected[PointerSorted[1]],
        'Reentrant deletion/add callback lost live selected identities');
      Compare('Reentrant deletion/add before packing');
    finally Tree.EndUpdate; end;
    Compare('Reentrant deletion/add after packing');

    RebuildMutationCase;
    Tree.Selected[PointerSorted[0]]:=True; Tree.Selected[PointerSorted[2]]:=True;
    Dirty.AddDuringRemove:=PointerSorted[1];
    Tree.ClearSelection;
    Require((Dirty.Failure='') and (Dirty.Events=3), 'Reentrant clear/add callback did not keep each removal consistent: '+Dirty.Failure);
    Require((Tree.SelectedCount=0) and not Tree.Selected[PointerSorted[0]] and
      not Tree.Selected[PointerSorted[1]] and not Tree.Selected[PointerSorted[2]],
      'Clear selection left an orphaned row after a reentrant selection callback');
    Compare('Reentrant clear/add after clearing');
  finally
    Tree.OnRemoveFromSelection:=nil; Tree.OnInitNode:=nil; Dirty.Free; Tree.Free;
  end;
  Writeln('PASS native sole/multiple selections retain old hidden/focus/children-above/resolved/next/dirty-delete-add-unselect-invert/reentrant-clear/init semantics');
end;

procedure TestReaderMainWithColumnFilter;
var Collection: IBookCollection; Book: TBookRecord; Root, Source, SourceHash, BodyHash, IniHash: string;
  CID, BID, Trial, OriginalRows, BeforeTail: Integer; Node, Tail: PVirtualNode; Data: PBookRecord;
  Filters: TBookColumnFilters; Allowed: TStringList; ReadAction: TAction; Driver: TRMFMainReaderDriver;
  OpenTimes, PageTotals: array[0..1] of Int64; Start, IdleElapsed, OriginalLookupElapsed: UInt64;
  SavedSource, ReaderFile, ReaderSection: string;
  SourceDB: TSQLiteDatabase; Languages: TComboBox; Item: TMenuItem;

  function OtherReaderKeys(Ini: TMemIniFile): string;
  var Sections, Values, Snapshot: TStringList;
  begin
    Sections:=TStringList.Create; Values:=TStringList.Create; Snapshot:=TStringList.Create;
    try
      Snapshot.CaseSensitive:=True; Ini.ReadSections(Sections);
      for var Section in Sections do
      begin
        Values.Clear; Ini.ReadSectionValues(Section,Values);
        for var I:=0 to Values.Count-1 do
          if not (SameText(Section,ReaderSection) and SameText(Values.Names[I],'Position')) then
            Snapshot.Add(Section+#0+Values[I]);
      end;
      Snapshot.Sort; Result:=Snapshot.Text;
    finally Snapshot.Free; Values.Free; Sections.Free; end;
  end;

  procedure ResetInitialPosition;
  var Ini: TMemIniFile; BeforeKeys: string;
  begin
    Require(TPath.GetFullPath(ReaderFile).StartsWith('G:\',True),
      'Reader position reset must remain in the isolated G profile');
    Ini:=TMemIniFile.Create(ReaderFile,TEncoding.UTF8);
    try
      BeforeKeys:=OtherReaderKeys(Ini);
      Ini.WriteInteger(ReaderSection,'Position',0);
      SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
    Ini:=TMemIniFile.Create(ReaderFile,TEncoding.UTF8);
    try
      Require((Ini.ReadInteger(ReaderSection,'Position',-1)=0) and (OtherReaderKeys(Ini)=BeforeKeys),
        'Isolated position reset changed another reader setting, history entry or bookmark');
      Writeln('PROFILE actual Main reader initial_position=0 other_ini_keys_sha256=',
        THashSHA2.GetHashString(BeforeKeys)); Flush(Output);
    finally Ini.Free; end;
  end;
begin
  RequireIsolatedRegression;
  TestNativeSingleSelectionOrder;
  TestListPerformance;
  Require(FileExists('reader-dome.fb2'),'Actual Main filter test requires private Under Dome FB2');
  Require(TPath.GetFullPath('reader-dome.fb2').StartsWith('G:\',True),'Reader fixture source must stay on private G');
  Root:=TPath.Combine(Settings.AppPath,'reader-main-filter-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  // The all-types-except-FB2 report still needs a visible copy of the same
  // physical FB2. The supported original_fb2 alias reproduces that case.
  Source:=TPath.Combine(Root,'under-dome.original_fb2'); TFile.Copy('reader-dome.fb2',Source,False);
  SourceHash:=THashSHA2.GetHashStringFromFile(Source); IniHash:='';
  if FileExists(Settings.AppPath+'myhomelib2.ini') then IniHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'myhomelib2.ini');
  Writeln('TRACE actual Main reader fixture create private collection'); Flush(Output);
  CID:=SystemDB.CreateCollection('Actual Main filtered reader',Root,TPath.Combine(Root,'catalog.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID); BID:=AddBook(Collection,'Tail Under Dome','Private author','ru','','prose_contemporary');
  Writeln('TRACE actual Main reader fixture initial record cid=',CID,' bid=',BID); Flush(Output);
  Collection.GetBookRecord(CreateBookKey(BID,CID),Book,True);
  Book.CollectionRoot:=Root; Book.Folder:=''; Book.FileName:='under-dome'; Book.FileExt:='.original_fb2';
  Book.LibID:=''; Include(Book.BookProps,bpIsLocal); Book.Size:=TFile.GetSize(Source); Collection.UpdateBook(Book);
  // An input field of the out record aliases BookRecord.Clear in the DAO.
  // Keep the real catalogue key independent of the record being reloaded.
  Writeln('TRACE actual Main reader fixture updated record cid=',CID,' bid=',BID); Flush(Output);
  Collection.GetBookRecord(CreateBookKey(BID,CID),Book,True);
  var ExpectedReload:=Book;
  Writeln('TRACE actual Main reader fixture aliased record cid=',CID,' bid=',BID); Flush(Output);
  Collection.GetBookRecord(Book.BookKey,Book,True);
  ReaderRequireSameReload(ExpectedReload,Book,'Actual Main source aliased reload');
  ReaderFile:=ResolveReaderSettingsFile(Settings.DataDir);
  ReaderSection:='Book.'+Copy(THashSHA2.GetHashString(ReaderHistoryName(Book,
    VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)))),1,40);
  Collection.AddBookToGroup(CreateBookKey(BID,CID),FAVORITES_GROUP_ID);
  Writeln('TRACE actual Main reader fixture activate owned collection cid=',CID); Flush(Output);
  Item:=TMenuItem.Create(nil);
  try Item.Tag:=CID; frmMain.miActiveCollectionClick(Item); finally Item.Free; end;
  Require(Settings.ActiveCollection=CID,'Actual Main fixture did not activate its own catalogue');
  SourceDB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(CID).DBFileName);
  SavedSource:=SourceDB.QuerySingleString('SELECT hex(LibID)||hex(Folder)||hex(FileName)||hex(Ext)||hex(Review)||hex(Annotation) FROM Books WHERE BookID=?',[BID]);
  Filters:=TBookColumnFilters.ForTree(frmMain.tvBooksSR); Allowed:=TStringList.Create; Driver:=TRMFMainReaderDriver.Create;
  Languages:=TComboBox.Create(nil);
  BodyHash:=''; Tail:=nil; OriginalRows:=0; BeforeTail:=0;
  try
    Languages.Parent:=frmMain; Languages.Visible:=False; Languages.Items.Add('-'); Languages.ItemIndex:=0;
    frmMain.pgControl.ActivePage:=frmMain.tsSearch; frmMain.pgControlChange(nil);
    Writeln('TRACE actual Main reader fixture build 50K owned-CID rows cid=',CID); Flush(Output);
    frmMain.FillBooksTree(frmMain.tvBooksSR,Languages,TProfileBooks.Create as IBookIterator,True,True,nil);
    Filters.Clear; Filters.Apply(False);
    Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvBooksSR.GetNodeData(Node);
      if Assigned(Data) and (Data.NodeType=ntBookInfo) then
      begin
        Require(Data.BookKey.DatabaseID=CID,'Large reader profile row belongs to a foreign catalogue');
        Inc(OriginalRows); Tail:=Node;
        if Data.BookKey.BookID mod 100=0 then Data.FileExt:='.pdf' else Data.FileExt:='.fb2';
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require((OriginalRows=50000) and Assigned(Tail),'Actual Main reader did not retain 50K underlying books');
    Data:=frmMain.tvBooksSR.GetNodeData(Tail); Data^:=Book;
    Require(Data.BookKey.IsSameAs(CreateBookKey(BID,CID)),'Actual Main tail lost its real catalogue identity');
    Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) and (Node<>Tail) do begin Inc(BeforeTail); Node:=frmMain.tvBooksSR.GetNext(Node); end;
    Require(BeforeTail>=49000,'Reader test selected an early row and would miss hidden-row scans');
    Allowed.Add('pdf'); Allowed.Add(Book.GetFileType); for var I:=1 to 48 do Allowed.Add('format'+IntToStr(I));
    ReadAction:=TAction(frmMain.FindComponent('acReadBuiltin')); Require(Assigned(ReadAction),'Actual built-in reader Main action missing');
    Writeln('TRACE actual Main reader fixture ready tail cid=',CID,' bid=',BID,' preceding_nodes=',BeforeTail); Flush(Output);
    frmMain.Show; frmMain.pgControl.ActivePage:=frmMain.tsSearch;
    TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=Driver.Probe.Checked;
    for Trial:=0 to 1 do
    begin
      Writeln('TRACE actual Main reader trial=',Trial,' filtering then selecting real tail'); Flush(Output);
      Filters.Clear; if Trial=1 then Filters.SetSelectedValues(COL_TYPE,Allowed);
      Filters.Apply(False); frmMain.tvBooksSR.ClearSelection;
      frmMain.tvBooksSR.Selected[Tail]:=True; frmMain.tvBooksSR.FocusedNode:=Tail;
      Require(frmMain.tvBooksSR.GetFirstSelected=Tail,'Tail sole-selection oracle mismatch');
      Require(not frmMain.tvBooksSR.IsEffectivelyFiltered[Tail],'Same FB2 alias is invisible under all-types-except-FB2');
      Driver.CheckedVisits:=0; Driver.IdleCycles:=0; Driver.IdleMS:=0; Driver.Probe.Visits:=0;
      Start:=GetTickCount64;
      for var I:=1 to 120 do Driver.UpdateAllActions;
      IdleElapsed:=GetTickCount64-Start;
      Require(Driver.CheckedVisits=0,'Whole Main action list scans checked rows for a sole tail selection');
      Require(IdleElapsed<1500,'Whole Main action list repeatedly traverses hidden tail rows');
      // Compare the old iterator on the same late selection. This reports the
      // former scan cost separately without changing the production iterator.
      Start:=GetTickCount64;
      for var I:=1 to 120 do Require(RMFOldNextSelected(frmMain.tvBooksSR,nil,False)=Tail,'Old selection oracle mismatch');
      OriginalLookupElapsed:=GetTickCount64-Start;
      Writeln('PROFILE actual Main tail filter=',Trial,' underlying_books=',OriginalRows,' preceding_nodes=',BeforeTail,
        ' all_action_updates_ms=',IdleElapsed,' old_120_pointer_walks_ms=',OriginalLookupElapsed,' checked_visits=',Driver.CheckedVisits);
      Require(ReadAction.Enabled,'Actual Main built-in reader action disabled for selected FB2 alias');
      ResetInitialPosition;
      var Preparations, BusyPreviews, Readers: Integer;
      RMFTaskCounts(Preparations,BusyPreviews,Readers);
      Writeln('PROFILE actual Main reader before open filter=',Trial,' preparations=',Preparations,
        ' busy_previews=',BusyPreviews,' reader_forms=',Readers); Flush(Output);
      Require((Preparations=0) and (Readers=0),'Reader trial overlaps a preceding preparation or modal reader');
      Driver.BeginRead(Book.Title); Require(ReadAction.Execute,'Actual Main reader action did not execute');
      // Main's preparation starts asynchronously; its callback opens the real
      // modal reader when ready. Pump the same UI until that modal has closed.
      while not Driver.Finished and (GetTickCount64-Driver.Started<20000) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(2); end;
      Require(Driver.Finished and (Driver.Failure=''),'Actual Main modal reader failed: '+Driver.Failure);
      RMFTaskCounts(Preparations,BusyPreviews,Readers);
      Writeln('PROFILE actual Main reader after close filter=',Trial,' preparations=',Preparations,
        ' busy_previews=',BusyPreviews,' reader_forms=',Readers); Flush(Output);
      Require((Preparations=0) and (Readers=0),'Actual Main reader did not release its preparation/modal before the next trial');
      Require((Driver.PageIndex=5) and (Driver.OpenMS>=0),'Actual Main modal did not complete five page turns');
      Require(Driver.CheckedVisits=0,'Whole Main actions scan the catalog while real modal reader is open');
      if Trial=0 then BodyHash:=Driver.TextHash else Require(Driver.TextHash=BodyHash,'Filter altered the opened physical FB2 content');
      OpenTimes[Trial]:=Driver.OpenMS; PageTotals[Trial]:=Driver.TotalPageMS;
      Writeln('PROFILE actual Main reader filter=',Trial,' file=under-dome.original_fb2 open_ms=',Driver.OpenMS,
        ' visible_ms=',Driver.VisibleMS,' visible_to_ready_ms=',Driver.OpenMS-Driver.VisibleMS,
        ' initial_position=',Driver.InitialPosition,' max_preparations=',Driver.MaxPreparations,
        ' max_busy_previews=',Driver.MaxBusyPreviews,' before_visible_idle_ms=',Driver.BeforeVisibleIdleMS,
        ' loading_idle_ms=',Driver.LoadingIdleMS,' paging_idle_ms=',Driver.PagingIdleMS,
        ' max_page_ms=',Driver.MaxPageMS,' total_page_ms=',Driver.TotalPageMS,' all_idle_cycles=',Driver.IdleCycles,' all_idle_ms=',Driver.IdleMS);
    end;
    Require(OpenTimes[1]<OpenTimes[0]+1500,'Type filter adds seconds to actual Main reader opening');
    Require(PageTotals[1]<PageTotals[0]+5*150,'Type filter delays actual Main page changes');
    Require(THashSHA2.GetHashStringFromFile(Source)=SourceHash,'Actual Main reader changed original FB2 bytes');
    Require(SourceDB.QuerySingleString('SELECT hex(LibID)||hex(Folder)||hex(FileName)||hex(Ext)||hex(Review)||hex(Annotation) FROM Books WHERE BookID=?',[BID])=SavedSource,
      'Actual Main reader rewrote source identity or personal memo BLOBs');
    if IniHash<>'' then Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'myhomelib2.ini')=IniHash,'Actual Main reader changed program/profile settings');
    Writeln('PASS actual Main modal opens and pages identical Under Dome content at a 50K tail selection, with filter off/on and complete idle actions');
  finally
    Driver.Timer.Enabled:=False; TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=nil;
    CancelReaderPreparations(frmMain);
    Filters.Clear; Filters.Apply(False); Driver.Free; Allowed.Free; Languages.Free; SourceDB.Free; Collection:=nil; frmMain.Hide;
  end;
  Flush(Output);
end;
