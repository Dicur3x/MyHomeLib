// The wrapper stages an owned copy. Never register the user's original here.
procedure BenchmarkActualCatalogue;
var
  FileName: string;
  CID, Expected, Seen, Kind, Trial, Trials: Integer;
  Started, Elapsed, PhaseStarted: UInt64;
  CPUStarted, CPUElapsed: UInt64;
  DB: TSQLiteDatabase;
  Collection: IBookCollection;
  Criteria: TBookSearchCriteria;
  Filter: TFilterValue;
  Factory: TFunc<IBookIterator>;
  Node: PVirtualNode;
  ProfileOnly, StartupOnly, InterfaceOnly, SampleOnly, RecordTransfer: Boolean;
  function ProcessCPUMilliseconds: UInt64;
  var Created, Exited, Kernel, User: TFileTime;
  begin
    Win32Check(GetProcessTimes(GetCurrentProcess,Created,Exited,Kernel,User));
    Result := ((UInt64(Kernel.dwHighDateTime) shl 32) + Kernel.dwLowDateTime +
      (UInt64(User.dwHighDateTime) shl 32) + User.dwLowDateTime) div 10000;
  end;
  procedure CheckAlphabet(Bar: TToolBar; const Alphabet: string);
  var Index: Integer; PreviousRight: Integer; Button: TToolButton;
  begin
    Require(Bar.ButtonCount=Length(Alphabet),'Streamed alphabet count differs from the shared constants');
    PreviousRight:=0;
    for Index:=0 to Length(Alphabet)-1 do
    begin
      Button:=Bar.Buttons[Index];
      Require((Button.Caption=Alphabet[Index+1]) and Assigned(Button.OnClick) and
        (Button.ImageIndex=-1),'Streamed alphabet lost a letter or its action');
      Require((Button.Left>=PreviousRight) and (Button.Width>0) and
        (Button.Top+Button.Height<=Bar.ClientHeight),Format('Streamed alphabet geometry %s[%d]: left=%d previous=%d width=%d top=%d height=%d client=%d ppi=%d', [Bar.Name,Index,Button.Left,PreviousRight,Button.Width,Button.Top,Button.Height,Bar.ClientHeight,frmMain.CurrentPPI]));
      PreviousRight:=Button.Left+Button.Width;
    end;
  end;
  procedure ClickLetter(Bar: TToolBar; Index: Integer);
  begin Bar.Buttons[Index].OnClick(Bar.Buttons[Index]); end;
  procedure CheckTreeMetrics(Tree: TCustomVirtualStringTree; HasHeader: Boolean);
  var Height: Integer;
  begin
    TVirtualStringTree(Tree).Canvas.Font.Assign(Tree.Font);
    Height := TVirtualStringTree(Tree).Canvas.TextHeight('Щ');
    Require(TVirtualStringTree(Tree).DefaultNodeHeight >= Height,
      Format('%s row=%d text=%d ppi=%d font=%d/%d', [Tree.Name,
        TVirtualStringTree(Tree).DefaultNodeHeight, Height, frmMain.CurrentPPI,
        Tree.Font.Size, Tree.Font.PixelsPerInch]));
    if HasHeader then
    begin
      TVirtualStringTree(Tree).Canvas.Font.Assign(Tree.Header.Font);
      Require(Tree.Header.Height >= TVirtualStringTree(Tree).Canvas.TextHeight('Щ'),
        Format('%s header=%d text=%d ppi=%d font=%d/%d header-font=%d/%d',
          [Tree.Name, Tree.Header.Height, TVirtualStringTree(Tree).Canvas.TextHeight('Щ'),
           frmMain.CurrentPPI, Tree.Font.Size, Tree.Font.PixelsPerInch,
           Tree.Header.Font.Size, Tree.Header.Font.PixelsPerInch]));
    end;
  end;
begin
  RecordTransfer:=ParamStr(2)='record-transfer';
  Trials:=3;
  if RecordTransfer then
  begin
    {$IFNDEF MHL_SQL_PROFILE}
    raise Exception.Create('Record transfer comparison requires the GUI Performance build');
    {$ENDIF}
    Trials:=8;
  end;
  SampleOnly:=ParamStr(2)='sample';
  InterfaceOnly:=ParamStr(2).StartsWith('ui');
  StartupOnly:=ParamStr(2).StartsWith('startup') or InterfaceOnly;
  ProfileOnly:=(ParamStr(2)='profile') or StartupOnly or SampleOnly;
  if InterfaceOnly then
  begin
    Writeln('ACTUAL startup ui_fixture=1');
    CID := SystemDB.CreateCollection('Startup interface fixture',Settings.AppPath,
      'startup-ui.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    Collection := SystemDB.GetCollection(CID);
    AddBook(Collection,'Startup UI book','Author','ru','Series','0.1');
    Collection := nil;
  end
  else
  begin
    FileName := Settings.AppPath + 'performance-copy.hlc2';
    Require(FileExists(FileName), 'Owned catalogue copy is required');
    CID := SystemDB.RegisterCollection(FileName, 'Actual catalogue performance',
      Settings.AppPath + 'absent-books\');
  end;
  Settings.ActiveCollection := CID; Settings.ActivePage := PAGE_AUTHORS;
  Settings.HideDeletedBooks := True;
  Settings.ShowInfoPanel := False; Settings.ShowBookCover := False;
  Settings.ShowBookAnnotation := False; Settings.CheckUpdate := False;
  if ProfileOnly then StartSQLiteProfile(not SampleOnly);
  TfrmMain.DeferInitialCollection := True;
  {$IFDEF MHL_SQL_PROFILE}
  TfrmMain.UseLegacyStartupForProfile := (ParamStr(2)='startup-late') or
    (ParamStr(2)='ui-legacy');
  {$ENDIF}
  CPUStarted := ProcessCPUMilliseconds;
  Started := GetTickCount64;
  PhaseStarted := GetTickCount64;
  Application.CreateForm(TdmImages, dmImages);
  Writeln('ACTUAL startup images_create_ms=',GetTickCount64-PhaseStarted); Flush(Output);
  PhaseStarted := GetTickCount64;
  dmImages.ApplyThemeIcons;
  Writeln('ACTUAL startup icons_load_ms=',GetTickCount64-PhaseStarted); Flush(Output);
  PhaseStarted := GetTickCount64;
  Application.CreateForm(TfrmMain, frmMain);
  Writeln('ACTUAL startup main_create_ms=',GetTickCount64-PhaseStarted); Flush(Output);
  PhaseStarted := GetTickCount64;
  frmMain.Show; frmMain.Update;
  Writeln('ACTUAL startup show_ms=',GetTickCount64-PhaseStarted); Flush(Output);
  Writeln('ACTUAL startup visible_ms=',GetTickCount64-Started); Flush(Output);
  Require(frmMain.StartupLoading, 'Actual startup must use the distributed deferred loading path');
  frmMain.StartInitialCollectionLoad;
  while frmMain.StartupLoading and (GetTickCount64-Started < 180000) do
  begin Application.ProcessMessages; CheckSynchronize(0); Sleep(1); end;
  Require(not frmMain.StartupLoading, 'Actual catalogue startup did not finish');
  Writeln('ACTUAL startup ready_ms=',GetTickCount64-Started); Flush(Output);
  Writeln('ACTUAL startup cpu_ms=',ProcessCPUMilliseconds-CPUStarted); Flush(Output);
  Writeln('PASS actual catalogue uses the distributed deferred startup path');
  if ProfileOnly then
  begin SaveSQLiteProfile(Settings.AppPath+'actual-startup-profile.tsv'); StopSQLiteProfile; end;
  if InterfaceOnly then
  begin
    Require(frmMain.pgControl.OwnerDraw and frmMain.pgControl.DoubleBuffered and
      Assigned(frmMain.pgControl.OnDrawTab),'Streamed navigation tabs lost their drawing handler or buffering');
    CheckAlphabet(frmMain.tbarAuthorsRus,ALPHA_FILTER_ALL+ALPHA_FILTER_NON_ALPHA+CYRILLIC_ALPHABET);
    CheckAlphabet(frmMain.tbarAuthorsEng,ALPHA_FILTER_ALL+ALPHA_FILTER_NON_ALPHA+LATIN_ALPHABET);
    CheckAlphabet(frmMain.tbarSeriesRus,ALPHA_FILTER_ALL+ALPHA_FILTER_NON_ALPHA+CYRILLIC_ALPHABET);
    CheckAlphabet(frmMain.tbarSeriesEng,ALPHA_FILTER_ALL+ALPHA_FILTER_NON_ALPHA+LATIN_ALPHABET);
    var OriginalPPI:=frmMain.CurrentPPI;
    var OriginalTheme:=MHLThemeDark;
    try
      for var Dark:=0 to 1 do
      begin
        Settings.DarkTheme:=Dark<>0; SetMHLTheme(Dark<>0);
        for var PPI in [96,144,192] do
        begin
          var PreviousPPI:=frmMain.CurrentPPI;
          frmMain.ScaleForPPI(PPI); frmMain.FormAfterMonitorDpiChanged(nil,PreviousPPI,PPI);
          CheckAlphabet(frmMain.tbarAuthorsRus,ALPHA_FILTER_ALL+ALPHA_FILTER_NON_ALPHA+CYRILLIC_ALPHABET);
          CheckAlphabet(frmMain.tbarAuthorsEng,ALPHA_FILTER_ALL+ALPHA_FILTER_NON_ALPHA+LATIN_ALPHABET);
          CheckAlphabet(frmMain.tbarSeriesRus,ALPHA_FILTER_ALL+ALPHA_FILTER_NON_ALPHA+CYRILLIC_ALPHABET);
          CheckAlphabet(frmMain.tbarSeriesEng,ALPHA_FILTER_ALL+ALPHA_FILTER_NON_ALPHA+LATIN_ALPHABET);
          Require(frmMain.pgControl.OwnerDraw and Assigned(frmMain.pgControl.OnDrawTab),
            'Scaling or theme switching lost navigation drawing');
          for var Tree in TArray<TCustomVirtualStringTree>.Create(frmMain.tvAuthors,
            frmMain.tvSeries, frmMain.tvGenres, frmMain.tvGroups,
            PublisherView.SeriesTree) do CheckTreeMetrics(Tree,False);
          for var Tree in TArray<TCustomVirtualStringTree>.Create(frmMain.tvBooksA,
            frmMain.tvBooksS, frmMain.tvBooksG, frmMain.tvBooksSR, frmMain.tvBooksF,
            PublisherView.Books, frmMain.tvDownloadList) do CheckTreeMetrics(Tree,True);
          Writeln('PASS streamed alphabet theme=',Dark,' ppi=',PPI);
          Writeln('PASS tree text and headers fit theme=',Dark,' ppi=',PPI);
        end;
      end;
    finally
      frmMain.ScaleForPPI(OriginalPPI); Settings.DarkTheme:=OriginalTheme; SetMHLTheme(OriginalTheme);
    end;
    ClickLetter(frmMain.tbarAuthorsEng,2);
    Require(frmMain.tvAuthors.RootNodeCount=1,'Streamed Author A action does not find the fixture');
    ClickLetter(frmMain.tbarAuthorsEng,27);
    Require(frmMain.tvAuthors.RootNodeCount=0,'Streamed Author Z action retained an unrelated author');
    ClickLetter(frmMain.tbarAuthorsEng,0);
    Require(frmMain.tvAuthors.RootNodeCount=1,'Streamed Author all action failed');
    ShowPage(PAGE_SERIES);
    ClickLetter(frmMain.tbarSeriesEng,20);
    Require(frmMain.tvSeries.RootNodeCount=1,'Streamed Series S action does not find the fixture');
    ClickLetter(frmMain.tbarSeriesEng,27);
    Require(frmMain.tvSeries.RootNodeCount=0,'Streamed Series Z action retained an unrelated series');
    ClickLetter(frmMain.tbarSeriesEng,0);
    Require(frmMain.tvSeries.RootNodeCount=1,'Streamed Series all action failed');
    Writeln('PASS streamed alphabets preserve exact letters order geometry and real author series filter actions');
  end;
  if StartupOnly then
  begin Writeln('PASS actual catalogue startup phase profile completed'); Exit; end;
  Collection := SystemDB.GetCollection(CID);
  Collection.SetHideDeleted(True); Collection.SetShowLocalOnly(False);
  DB := TSQLiteDatabase.CreateReadOnly(FileName);
  try
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books') > 1000000,
      'Actual benchmark requires the full merged catalogue');
    ShowPage(PAGE_SEARCH);
    Settings.TreeModes[PAGE_SEARCH] := tmFlat;
    Factory := function: IBookIterator
      begin
        case Kind of
          0,1: Result := Collection.Search(Criteria,False);
          2: Result := Collection.GetBookIterator(bmByAuthor,False,@Filter);
          3: Result := Collection.GetBookIterator(bmBySeries,False,@Filter);
          4: Result := Collection.GetBookIterator(bmByPublisherSeries,False,@Filter);
        else raise Exception.Create('Unknown actual catalogue query'); end;
      end;
    for Kind := 0 to 4 do
    begin
      Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
      Criteria.Deleted := True; Criteria.CollapseMultiSeriesResults := True;
      Filter := Default(TFilterValue); Expected := -1;
      case Kind of
        0: Expected := DB.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE IsDeleted=0');
        1: begin Criteria.QueryMode := sqmText; Criteria.Title := 'привет';
          Expected:=DB.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE IsDeleted=0 AND SearchTitle GLOB ''*ПРИВ[ЕЁ]Т*'''); end;
        2: begin
          Filter.ValueInt := DB.QuerySingleInt('SELECT AuthorID FROM Author_List GROUP BY AuthorID ORDER BY COUNT(*) DESC LIMIT 1');
          Expected := DB.QuerySingleInt('SELECT COUNT(DISTINCT b.BookID) FROM Books b JOIN Author_List l ON l.BookID=b.BookID WHERE b.IsDeleted=0 AND l.AuthorID=?',[Filter.ValueInt]);
        end;
        3: begin
          Filter.ValueInt := DB.QuerySingleInt('SELECT SeriesID FROM Books WHERE SeriesID>0 GROUP BY SeriesID ORDER BY COUNT(*) DESC LIMIT 1');
          Expected:=DB.QuerySingleInt('SELECT COUNT(DISTINCT b.BookID) FROM Books b JOIN Series_List sl ON sl.BookID=b.BookID WHERE b.IsDeleted=0 AND sl.SeriesID=?',[Filter.ValueInt]);
        end;
        4: begin
          Filter.ValueInt := DB.QuerySingleInt('SELECT SeriesID FROM PublisherSeries_List GROUP BY SeriesID ORDER BY COUNT(*) DESC LIMIT 1');
          Expected:=DB.QuerySingleInt('SELECT COUNT(DISTINCT b.BookID) FROM Books b JOIN PublisherSeries_List sl ON sl.BookID=b.BookID WHERE b.IsDeleted=0 AND sl.SeriesID=?',[Filter.ValueInt]);
        end;
      end;
      for Trial := 1 to Trials do
      begin
        {$IFDEF MHL_SQL_PROFILE}
        // Warm same-process ABBA/BAAB; reference is exactly the former record
        // assignment, while all query/tree/validation paths stay identical.
        TfrmMain.CopyBookRecordsForProfile:=RecordTransfer and (Trial in [1,4,6,7]);
        {$ENDIF}
        if ProfileOnly then StartSQLiteProfile(not SampleOnly,SampleOnly);
        if Kind=0 then
        begin
          frmMain.DoClearFilter(False); frmMain.cbDeleted.Checked := True;
          frmMain.cbDeleted.OnClick(frmMain.cbDeleted);
          frmMain.cbCollapseMultiSeriesResults.Checked := True;
          CPUStarted := ProcessCPUMilliseconds;
          Started := GetTickCount64; frmMain.DoApplyFilter(nil);
        end
        else
        begin
          CPUStarted := ProcessCPUMilliseconds;
          Started := GetTickCount64;
          frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Factory,True,True,nil);
        end;
        Elapsed := GetTickCount64-Started;
        CPUElapsed := ProcessCPUMilliseconds-CPUStarted;
        if ProfileOnly then
        begin SaveSQLiteProfile(Settings.AppPath+'actual-book-list-profile.tsv'); StopSQLiteProfile; end;
        Require(not frmMain.BookListCancelled,'Actual catalogue query was cancelled');
        Seen := 0; Node := frmMain.tvBooksSR.GetFirst;
        while Assigned(Node) do
        begin
          var Book := PBookRecord(frmMain.tvBooksSR.GetNodeData(Node));
          Require((Book.NodeType=ntBookInfo) and not (bpIsDeleted in Book.BookProps),
            'Actual catalogue produced a blank, grouped or deleted book row');
          Inc(Seen); Node := frmMain.tvBooksSR.GetNext(Node);
        end;
        if Expected>=0 then Require(Seen=Expected,'Actual catalogue row count differs from independent SQL');
        Require((Kind=0) or (Seen>0),'Actual catalogue selective query returned no books');
        Writeln('ACTUAL query=',Kind,' trial=',Trial,' ms=',Elapsed,' rows=',Seen,
          ' cpu_ms=',CPUElapsed); Flush(Output);
        if RecordTransfer then
        begin
          {$IFDEF MHL_SQL_PROFILE}
          Writeln('TRANSFER copy=',Ord(TfrmMain.CopyBookRecordsForProfile),
            ' trial=',Trial,' ms=',Elapsed,' rows=',Seen); Flush(Output);
          {$ENDIF}
        end;
        if ProfileOnly then Break;
      end;
      if ProfileOnly or RecordTransfer then Break;
    end;
  finally
    {$IFDEF MHL_SQL_PROFILE}TfrmMain.CopyBookRecordsForProfile:=False;{$ENDIF}
    StopSQLiteProfile; DB.Free;
  end;
  if RecordTransfer then Writeln('PASS same-binary full catalogue record ownership transfer comparison preserves all row counts')
  else if SampleOnly then Writeln('PASS actual catalogue sampled iterator profile completed')
  else if ProfileOnly then Writeln('PASS actual catalogue startup and full-list profile completed')
  else Writeln('PASS actual catalogue startup empty hide-deleted title author series publisher queries completed');
end;
