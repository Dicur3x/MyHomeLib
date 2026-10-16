// Actual Main layout with oversized saved/dragged info panels in all six views.
procedure TestCompactBookViews;
var Infos: TArray<TInfoPanel>; Trees: TArray<TBookTree>;
  View: TPublisherSeriesView; OldBounds: TRect; OldPage: Integer;
  OriginalTheme, Dark, OriginalInfo, OriginalDismissed: Boolean;
  DPI, I, Cases, WindowHeight, Rows: Integer;
begin
  RequireIsolatedRegression;
  View:=PublisherView;
  Infos:=TArray<TInfoPanel>.Create(frmMain.ipnlAuthors,frmMain.ipnlSeries,
    View.Info,frmMain.ipnlGenres,frmMain.ipnlSearch,frmMain.ipnlFavorites);
  Trees:=TArray<TBookTree>.Create(frmMain.tvBooksA,frmMain.tvBooksS,
    View.Books,frmMain.tvBooksG,frmMain.tvBooksSR,frmMain.tvBooksF);
  OldBounds:=frmMain.BoundsRect; OldPage:=frmMain.pgControl.ActivePageIndex;
  OriginalTheme:=MHLThemeDark; OriginalInfo:=Settings.ShowInfoPanel;
  OriginalDismissed:=Settings.WindowsDarkThemeOfferDismissed; Cases:=0;
  try
    if not Settings.ShowInfoPanel then frmMain.ShowBookInfoPanelExecute(nil);
    Settings.WindowsDarkThemeOfferDismissed:=False;
    frmMain.WindowState:=wsNormal;
    frmMain.Show; frmMain.BringToFront; Application.ProcessMessages;
    for Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark);
      frmMain.UpdateWindowsThemeOffer(True);
      for DPI in TArray<Integer>.Create(96,144,192) do
      begin
        frmMain.ScaleForPPI(DPI);
        for WindowHeight in TArray<Integer>.Create(600,680) do
        begin
        Rows:=3;
        frmMain.SetBounds(0,0,MulDiv(800,DPI,96),MulDiv(WindowHeight,DPI,96));
        for I:=0 to High(Infos) do
        begin
          case I of
            0: frmMain.pgControl.ActivePage:=frmMain.tsByAuthor;
            1: frmMain.pgControl.ActivePage:=frmMain.tsBySerie;
            2: frmMain.pgControl.ActivePage:=View.Tab;
            3: frmMain.pgControl.ActivePage:=frmMain.tsByGenre;
            4: frmMain.pgControl.ActivePage:=frmMain.tsSearch;
            5: frmMain.pgControl.ActivePage:=frmMain.tsByGroup;
          end;
          frmMain.pgControlChange(nil);
          // The public height/OnResize route also covers a splitter drag.
          Infos[I].Height:=MulDiv(1000,DPI,96);
          Application.ProcessMessages;
          Writeln('TRACE compact view=',I,' dark=',Ord(Dark),' dpi=',DPI,
            ' window=',frmMain.Height,' parent=',Infos[I].Parent.ClientHeight,
            ' tree=',Trees[I].ClientHeight,' header=',Trees[I].Header.Height,
            ' row=',Trees[I].DefaultNodeHeight,' info=',Infos[I].Height,
            ' minimum=',Infos[I].Constraints.MinHeight);
          Flush(Output);
          Require(IsWindowVisible(Trees[I].Handle),'Compact fixture did not show its actual native book tree');
          // VST puts its header in WM_NCCALCSIZE: native ClientHeight already
          // excludes the header, frame and visible horizontal scrollbar.
          Require(Trees[I].ClientHeight>=Rows*Trees[I].DefaultNodeHeight,
            Format('Compact view lost its complete book rows: view=%d dark=%d dpi=%d height=%d',
              [I,Ord(Dark),DPI,Trees[I].ClientHeight]));
          Require((Trees[I].BoundsRect.Bottom<=Infos[I].Top) and
            (Infos[I].Height>=Infos[I].Constraints.MinHeight),
            'Compact book rows overlap the info panel or violate its minimum');
          Inc(Cases);
        end;
        end;
      end;
    end;
    Writeln('PASS compact book views keep complete rows at minimum and normal height cases=',Cases);
    Flush(Output);
  finally
    Settings.WindowsDarkThemeOfferDismissed:=OriginalDismissed;
    SetMHLTheme(OriginalTheme);
    frmMain.ScaleForPPI(96);
    frmMain.BoundsRect:=OldBounds;
    frmMain.pgControl.ActivePageIndex:=OldPage;
    frmMain.pgControlChange(nil);
    if Settings.ShowInfoPanel<>OriginalInfo then frmMain.ShowBookInfoPanelExecute(nil);
  end;
end;
