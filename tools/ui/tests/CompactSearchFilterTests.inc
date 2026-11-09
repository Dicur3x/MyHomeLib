type
  TCurrentListSearchProbe = class
    Failure: string;
    procedure Tick(Sender: TObject);
  end;

procedure TCurrentListSearchProbe.Tick(Sender: TObject);
var Dialog: TfrmBookSearch; Previous: PVirtualNode;
begin
  for var Index:=0 to Screen.FormCount-1 do
  begin
    if not (Screen.Forms[Index] is TfrmBookSearch) then Continue;
    Dialog:=TfrmBookSearch(Screen.Forms[Index]);
    if not Dialog.Visible then Continue;
    TTimer(Sender).Enabled:=False;
    try
      Dialog.edText.Text:=' ha R ';
      Dialog.Perform(CM_DIALOGKEY,VK_RETURN,0);
      Previous:=frmMain.tvBooksSR.FocusedNode;
      Require(Assigned(Previous) and (Dialog.ModalResult=mrNone) and
        (Dialog.btnFind.Caption='Найти дальше'),'Enter did not find a partial title and leave the dialog open');
      Dialog.edText.Text:='сжать';
      Dialog.Perform(CM_DIALOGKEY,VK_RETURN,0);
      Require((Dialog.ModalResult=mrNone) and (frmMain.tvBooksSR.FocusedNode=Previous) and
        (Pos('Совпадений нет',Dialog.lblResult.Caption)>0),'No-match search did not explain the result and preserve selection');
      Failure:='';
    except on E: Exception do Failure:=E.Message; end;
    Dialog.btnClose.Click;
    Exit;
  end;
end;

procedure TestCompactSearchFilters;
var More: TButton; Publisher: TMHLButtonedEdit; OldBounds: TRect;
  OldPage, DPI, Width, Height, Cases, PosBefore, OriginalPPI: Integer;
  OldDark, Dark, OldMore, OldBook, OldOther, OldFile: Boolean;
  DBFile, DBHash: string; Reopened: TMHLSettings; Started: UInt64;
  LocateProbe: TCurrentListSearchProbe; LocateTimer: TTimer;

  function ScreenBounds(Control: TControl): TRect;
  begin
    Result.TopLeft:=Control.Parent.ClientToScreen(Control.BoundsRect.TopLeft);
    Result.BottomRight:=Control.Parent.ClientToScreen(Control.BoundsRect.BottomRight);
  end;

  function Inside(Control: TControl; Container: TWinControl): Boolean;
  var R,C: TRect;
  begin
    R:=ScreenBounds(Control);
    C.TopLeft:=Container.ClientToScreen(Point(0,0));
    C.BottomRight:=Container.ClientToScreen(Point(Container.ClientWidth,Container.ClientHeight));
    Result:=Control.Visible and (R.Width>0) and (R.Height>0) and
      (R.Left>=C.Left) and (R.Top>=C.Top) and (R.Right<=C.Right) and (R.Bottom<=C.Bottom);
  end;

  procedure SetMore(Value: Boolean);
  begin
    if Settings.SearchMoreExpanded<>Value then More.Click;
  end;

begin
  RequireIsolatedRegression;
  More:=frmMain.FindComponent('SearchMoreFiltersButton') as TButton;
  Publisher:=frmMain.FindComponent('edFPublisher') as TMHLButtonedEdit;
  Require(Assigned(More) and Assigned(Publisher),'Compact search controls missing');
  OldBounds:=frmMain.BoundsRect; OriginalPPI:=frmMain.CurrentPPI;
  OldPage:=frmMain.pgControl.ActivePageIndex; OldDark:=MHLThemeDark;
  OldMore:=Settings.SearchMoreExpanded; OldBook:=frmMain.ctpBook.Collapsed;
  OldOther:=frmMain.ctpOther.Collapsed; OldFile:=frmMain.ctpFile.Collapsed;
  DBFile:=SystemDB.GetCollectionInfo(Settings.ActiveCollection).DBFileName;
  DBHash:=THashSHA2.GetHashStringFromFile(DBFile); Cases:=0;
  try
    ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False);
    frmMain.WindowState:=wsNormal; frmMain.Show;
    frmMain.ctpBook.Collapsed:=False; frmMain.ctpOther.Collapsed:=False;
    frmMain.ctpFile.Collapsed:=False; SetMore(False);
    for Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark);
      for DPI in TArray<Integer>.Create(96,144,192) do
      begin
        frmMain.ScaleForPPI(DPI);
        for Width in TArray<Integer>.Create(800,1150) do
          for Height in TArray<Integer>.Create(600,800) do
          begin
            frmMain.SetBounds(0,0,MulDiv(Width,DPI,96),MulDiv(Height,DPI,96));
            frmMain.SearchParams.VertScrollBar.Position:=0; Application.ProcessMessages;
            Require(Inside(frmMain.edFFullName,frmMain.SearchParams) and
              Inside(frmMain.edFTitle,frmMain.SearchParams) and
              Inside(frmMain.cbCollapseMultiSeriesResults,frmMain.SearchParams),
              'Common Author/Title/series-collapse filter is clipped on a small screen');
            Require(Inside(frmMain.btnApplyFilter,frmMain.pnSearchView) and
              Inside(frmMain.btnClearFilterEdits,frmMain.pnSearchView),
              'Apply/Clear are outside the small Search sidebar');
            Require(Inside(frmMain.tbtnCatalogSearch,frmMain.tlbrMain),
              'Catalog search button is clipped on the main toolbar');
            Require(frmMain.btnApplyFilter.BoundsRect.Right<=frmMain.btnClearFilterEdits.Left,
              'Search action buttons overlap');
            Require((frmMain.ctpBook.Top<frmMain.ctpOther.Top) and
              (frmMain.ctpOther.Top<frmMain.ctpFile.Top),
              'File details moved ahead of the common location filters');
            if Height=800 then
              Require(Inside(frmMain.cbDeleted,frmMain.SearchParams),
                'Deletion filter is hidden behind the expanded file metadata section');
            Require(not Publisher.Visible and not Publisher.CanFocus,
              'Collapsed extra input can take keyboard focus');
            Inc(Cases);
          end;
      end;
    end;
    Require(Cases=24,'Missing compact search scale/width/height/theme combinations');
    Writeln('PASS compact search common filters and pinned actions fit small windows cases=',Cases);
    Flush(Output);

    SetMHLTheme(False); frmMain.ScaleForPPI(96); frmMain.SetBounds(0,0,1000,760);
    ShowPage(PAGE_AUTHORS);
    frmMain.ctpBook.Collapsed:=True;
    frmMain.edFTitle.Text:='previous search';
    frmMain.tbtnCatalogSearch.Click;
    Require((frmMain.pgControl.ActivePage=frmMain.tsSearch) and not frmMain.ctpBook.Collapsed and
      (frmMain.ActiveControl=frmMain.edFTitle) and (frmMain.edFTitle.SelText='previous search'),
      'Toolbar search does not open the catalog title field');
    frmMain.edFTitle.Text:='Alpha ru';
    frmMain.DoApplyFilter(nil);
    ExpectTitles(frmMain.tvBooksSR,['Alpha ru']);
    Require((frmMain.miFastBookSearch.ShortCut=VK_F3) and
      (frmMain.miFastBookSearch.Parent=frmMain.miBook),'F3 is missing from the Book menu');
    Require((frmMain.miAddToGroup.Caption='Добавить в группу') and
      (frmMain.miCollSelect.Caption='Выбрать коллекцию') and
      (Pos('программы и компонентов',frmMain.acHelpCheckUpdates.Caption)>0) and
      (Pos('онлайн-коллекций',frmMain.acToolsUpdateOnlineCollections.Caption)>0),
      'Catalog menus confuse collections, book groups or update targets');
    LocateProbe:=TCurrentListSearchProbe.Create;
    LocateTimer:=TTimer.Create(nil);
    try
      LocateProbe.Failure:='Current-list search dialog did not open';
      LocateTimer.Interval:=30;
      LocateTimer.OnTimer:=LocateProbe.Tick;
      frmMain.miFastBookSearch.Click;
      Require(LocateProbe.Failure='',LocateProbe.Failure);
    finally
      LocateTimer.Free;
      LocateProbe.Free;
    end;
    frmMain.DoClearFilter(False);
    Writeln('PASS toolbar opens catalog title search and F3 keeps no-match feedback visible');
    Flush(Output);
    frmMain.SearchParams.VertScrollBar.Position:=0;
    Publisher.Text:='There is no publisher with this fixture name';
    Require((Pos('(1)',More.Caption)>0),'Filled hidden conditions have no visible count');
    frmMain.DoApplyFilter(nil); ExpectTitles(frmMain.tvBooksSR,[]);
    SetMore(True); Require(Publisher.Visible and Publisher.CanFocus,'Expanded publisher cannot receive input');
    Require((frmMain.ctpBook.BoundsRect.Bottom<=frmMain.ctpOther.Top) and
      (frmMain.ctpOther.BoundsRect.Bottom<=frmMain.ctpFile.Top),
      'Expanding extra fields overlaps the following search categories');
    frmMain.DoApplyFilter(nil); ExpectTitles(frmMain.tvBooksSR,[]);
    SetMore(False);
    Require(Publisher.Text='There is no publisher with this fixture name',
      'Collapsing extra fields erased its search condition');
    frmMain.DoApplyFilter(nil); ExpectTitles(frmMain.tvBooksSR,[]);
    frmMain.DoClearFilter(False);
    Require((Pos('(1)',More.Caption)=0),'Clear left a stale extra-field count');
    Writeln('PASS collapsed extra conditions remain applied and visible by count without changing query semantics');

    // Actual VCL Tab traversal must include the collapsed category header.
    frmMain.ctpFile.Collapsed:=True;
    frmMain.ActiveControl:=More;
    for var I:=1 to 100 do
    begin
      frmMain.Perform(CM_DIALOGKEY,VK_TAB,0); Application.ProcessMessages;
      if frmMain.ActiveControl=frmMain.ctpFile then Break;
    end;
    Require(frmMain.ActiveControl=frmMain.ctpFile,'Tab cannot reach collapsed File header');
    frmMain.ctpFile.Perform(CN_KEYDOWN,VK_SPACE,0);
    Application.ProcessMessages;
    Require(not frmMain.ctpFile.Collapsed and frmMain.edFFile.CanFocus,
      'Space did not reveal the collapsed File search inputs');
    SetMore(True); frmMain.ActiveControl:=More;
    for var I:=1 to 100 do
    begin
      frmMain.Perform(CM_DIALOGKEY,VK_TAB,0); Application.ProcessMessages;
      if frmMain.ActiveControl=Publisher then Break;
    end;
    Require(frmMain.ActiveControl=Publisher,'Tab cannot enter expanded extra fields');
    frmMain.SearchParams.VertScrollBar.Position:=0;
    PosBefore:=frmMain.SearchParams.VertScrollBar.Position;
    frmMain.SearchParams.Perform(WM_MOUSEWHEEL,WPARAM(MakeLong(0,Word(SmallInt(-120)))),0);
    Application.ProcessMessages;
    Require(frmMain.SearchParams.VertScrollBar.Position>PosBefore,'Wheel does not scroll overflowed search fields');
    Writeln('PASS compact search reaches extra fields and collapsed headers by Tab Space and wheel');

    for var State in TArray<Boolean>.Create(False,True) do
    begin
      SetMore(State); Settings.SaveSettings;
      Reopened:=TMHLSettings.Create;
      try
        Require(SameFileName(Reopened.SettingsFileName,Settings.SettingsFileName),
          'Reopened search settings escaped the isolated profile');
        Reopened.LoadSettings;
        Require(Reopened.SearchMoreExpanded=State,'More-field state did not survive settings reopen');
      finally Reopened.Free; end;
    end;
    Require(THashSHA2.GetHashStringFromFile(DBFile)=DBHash,'Search layout changed the source collection');
    Writeln('PASS extra-field expansion persists and compact search leaves catalogue bytes unchanged');
    Flush(Output);
    if FileExists(Settings.AppPath+'search-compact-visual.flag') then
    begin
      SetMore(False); SetMHLTheme(False); frmMain.ScaleForPPI(96);
      frmMain.SetBounds(40,40,1000,760); frmMain.SearchParams.VertScrollBar.Position:=0;
      frmMain.ShowInTaskBar:=True; frmMain.Show; frmMain.BringToFront;
      Started:=GetTickCount64;
      Writeln('TRACE compact search visual ready'); Flush(Output);
      while frmMain.Visible and (GetTickCount64-Started<600000) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(20); end;
    end;
  finally
    frmMain.DoClearFilter(False); SetMore(OldMore);
    frmMain.ctpBook.Collapsed:=OldBook; frmMain.ctpOther.Collapsed:=OldOther;
    frmMain.ctpFile.Collapsed:=OldFile;
    SetMHLTheme(OldDark); frmMain.ScaleForPPI(OriginalPPI); frmMain.BoundsRect:=OldBounds;
    frmMain.pgControl.ActivePageIndex:=OldPage; frmMain.pgControlChange(nil);
  end;
end;
