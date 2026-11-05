procedure TestPersonalAuthorUI(const Collection: IBookCollection);
var
  Store: TAuthorFavorites;
  RatingMenu, Minimum, ShowHidden, Unrated, Hide: TMenuItem;
  Joint: TBookRecord;
  PublisherSeries: TBookSeries;
  JointID: Integer;
  CloseManager: TThreadProcedure;
  ManagerSeen: Boolean;
  SourceHash: string;
  procedure CheckCoauthorRules;
  var Entries: TArray<TAuthorPersonalEntry>; Authors: TBookAuthors;
  begin
    SetLength(Entries,2);
    Entries[0].Author.LastName:='Alpha'; Entries[0].Author.FirstName:='Alex';
    Entries[0].Author.Key:=AuthorFavoriteKey('Alpha','Alex',''); Entries[0].Rating:=4;
    Entries[1].Author.LastName:='Beta'; Entries[1].Author.FirstName:='Alex';
    Entries[1].Author.Key:=AuthorFavoriteKey('Beta','Alex',''); Entries[1].Rating:=2;
    try
      SetPersonalAuthorFilter(Entries,4,True,True);
      TAuthorsHelper.Add(Authors,'Beta','Alex',''); TAuthorsHelper.Add(Authors,'Unknown','','');
      Require(not PersonalBookVisible(Authors),'Unrated coauthor bypassed an explicitly low rating');
      TAuthorsHelper.Add(Authors,'Alpha','Alex','');
      Require(PersonalBookVisible(Authors),'Highest personal coauthor score was ignored');
      Require(PersonalBookVisible(nil),'Include unrated omitted an authorless book');
      SetPersonalAuthorFilter(Entries,4,False,True);
      Require(not PersonalBookVisible(nil),'Authorless book bypassed the unrated switch');
      Entries[0].Hidden:=True; SetPersonalAuthorFilter(Entries,4,False,False);
      Require(not PersonalBookVisible(Authors),'High-rated hidden author bypassed hiding');
    finally SetPersonalAuthorFilter(nil,0,True,False); end;
  end;
  function VisibleBooks(Tree: TBookTree): Integer;
  var Node: PVirtualNode; Book: PBookRecord;
  begin
    Result:=0; Node:=Tree.GetFirst;
    while Assigned(Node) do
    begin
      Book:=Tree.GetNodeData(Node);
      if (Book.NodeType=ntBookInfo) and not Tree.IsEffectivelyFiltered[Node] then Inc(Result);
      Node:=Tree.GetNext(Node);
    end;
  end;
  procedure SelectAuthor(const LastName: string);
  var Node: PVirtualNode; Author: PAuthorData;
  begin
    ShowPage(PAGE_AUTHORS);
    frmMain.tbarAuthorsRus.Buttons[0].OnClick(frmMain.tbarAuthorsRus.Buttons[0]);
    Node:=frmMain.tvAuthors.GetFirst;
    while Assigned(Node) do
    begin
      Author:=frmMain.tvAuthors.GetNodeData(Node);
      if Author.LastName=LastName then
      begin
        frmMain.tvAuthors.ClearSelection;
        frmMain.tvAuthors.Selected[Node]:=True; frmMain.tvAuthors.FocusedNode:=Node;
        frmMain.tvAuthorsChange(frmMain.tvAuthors,Node);
        frmMain.pmAuthorPopup(nil);
        Exit;
      end;
      Node:=frmMain.tvAuthors.GetNext(Node);
    end;
    Require(False,'Personal author selector cannot select '+LastName);
  end;
  procedure CheckOtherViews(SeriesCount, GenreCount, GroupCount, PublisherCount: Integer);
  begin
    Require(VisibleBooks(frmMain.tvBooksS)=SeriesCount,'Personal author policy is inconsistent in series');
    Require(VisibleBooks(frmMain.tvBooksG)=GenreCount,Format('Personal author policy in genres: %d, expected %d',
      [VisibleBooks(frmMain.tvBooksG),GenreCount]));
    Require(VisibleBooks(frmMain.tvBooksF)=GroupCount,'Personal author policy is inconsistent in groups');
    Require(VisibleBooks(PublisherView.Books)=PublisherCount,'Personal author policy is inconsistent in publisher series');
  end;
  procedure ApplySearch;
  begin
    ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False);
    frmMain.cbDeleted.Checked:=True; frmMain.cbDeleted.OnClick(frmMain.cbDeleted);
    frmMain.cbCollapseMultiSeriesResults.Checked:=True; frmMain.DoApplyFilter(nil);
  end;
begin
  RequireIsolatedRegression;
  CheckCoauthorRules;
  RatingMenu:=frmMain.FindComponent('miPersonalAuthorRating') as TMenuItem;
  Minimum:=frmMain.FindComponent('miPersonalAuthorMinimum') as TMenuItem;
  ShowHidden:=frmMain.FindComponent('miPersonalAuthorShowHidden') as TMenuItem;
  Unrated:=frmMain.FindComponent('miPersonalAuthorUnrated') as TMenuItem;
  Hide:=frmMain.FindComponent('miPersonalAuthorHidden') as TMenuItem;
  Require(Assigned(RatingMenu) and Assigned(Minimum) and Assigned(ShowHidden),'Personal author commands are absent');
  JointID:=AddBook(Collection,'Personal joint','Beta','ru','Alpha series','prose_contemporary');
  Collection.GetBookRecord(CreateBookKey(JointID,Collection.CollectionID),Joint,True);
  TAuthorsHelper.Add(Joint.Authors,'Alpha','Alex',''); Collection.UpdateBook(Joint);
  TSeriesHelper.Add(PublisherSeries,0,'Personal publisher',1,True);
  Collection.SetBookPublisherSeries(Joint.BookKey,PublisherSeries);
  ChangeCollection(frmMain.miCollSelect.Items[0].Tag);
  ChangeCollection(Collection.CollectionID);
  SelectAuthor('Alpha'); RatingMenu.Items[4].Click;
  SelectAuthor('Beta'); RatingMenu.Items[2].Click;
  ApplySearch; Require(VisibleBooks(frmMain.tvBooksSR)=7,'Unconfigured rating changed the initial search');
  ShowPage(PAGE_FAVORITES);
  frmMain.cbLangSelectF.ItemIndex:=0; frmMain.cbLangSelectF.OnChange(frmMain.cbLangSelectF);
  Require(VisibleBooks(frmMain.tvBooksF)=2,'Personal group fixture is empty before hiding');
  ShowPage(PAGE_SERIES);
  frmMain.cbLangSelectS.ItemIndex:=0; frmMain.cbLangSelectS.OnChange(frmMain.cbLangSelectS);
  SelectAuthor('Alpha');
  Require(Length(Joint.Genres)=1,'Personal genre fixture has no mapped genre');
  frmMain.ipnlAuthors.OnGenreLinkClicked(frmMain.ipnlAuthors,Joint.Genres[0].GenreCode,Low(TSysLinkType));
  frmMain.cbLangSelectG.ItemIndex:=0; frmMain.cbLangSelectG.OnChange(frmMain.cbLangSelectG);
  frmMain.pgControl.ActivePage:=PublisherView.Tab; frmMain.pgControlChange(nil);
  PublisherView.Language.ItemIndex:=0; PublisherView.Language.OnChange(PublisherView.Language);
  CheckOtherViews(3,4,2,1);
  SelectAuthor('Alpha'); Hide.Click;
  CheckOtherViews(0,0,0,0);
  ApplySearch;
  Require(VisibleBooks(frmMain.tvBooksSR)=3,'Hiding an author retained their own or coauthored book');
  Require(Pos('мои авторы',frmMain.lblTotalBooksFL.Caption)>0,'Hidden-author filtering has no persistent result indicator');
  ShowPage(PAGE_FAVORITES);
  Require(VisibleBooks(frmMain.tvBooksF)=0,'Favorite books bypassed hidden-author filtering');
  ShowHidden.Click; ApplySearch;
  Require(VisibleBooks(frmMain.tvBooksSR)=7,'Show hidden failed to reconsider previously hidden rows');
  CheckOtherViews(3,4,2,1);
  Minimum.Items[4].Click;
  Require(VisibleBooks(frmMain.tvBooksSR)=5,'Author threshold mishandled a high-rated coauthor or an unrated author');
  Unrated.Click;
  Require(VisibleBooks(frmMain.tvBooksSR)=4,'Excluding unrated authors lost a rated coauthored book');
  ShowHidden.Click;
  Require(VisibleBooks(frmMain.tvBooksSR)=0,'Hidden coauthor did not override the personal rating');
  Minimum.Items[0].Click; Unrated.Click;
  Store:=TAuthorFavorites.Create(IncludeTrailingPathDelimiter(Settings.DataPath)+AUTHOR_FAVORITES_FILE_NAME);
  try
    Store.SetPersonalRating('Absent','Author','',5); Store.SetHidden('Absent','Author','',True);
    SourceHash:=THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(Collection.CollectionID).DBFileName);
    ManagerSeen:=False;
    CloseManager:=procedure
      var Form: TfrmAuthorFavorites; List: TListView; Search: TEdit;
        Category, Rating: TComboBox; Hidden: TCheckBox; Found, OldDark: Boolean;
      begin
        Form:=nil;
        for var I:=0 to Screen.FormCount-1 do
          if Screen.Forms[I] is TfrmAuthorFavorites then Form:=TfrmAuthorFavorites(Screen.Forms[I]);
        Require(Assigned(Form),'My authors manager did not open');
        Category:=Form.FindComponent('cbPersonalAuthorCategory') as TComboBox;
        List:=Form.FindComponent('lvAllFavoriteAuthors') as TListView;
        Search:=Form.FindComponent('edAllFavoriteAuthorsSearch') as TEdit;
        Rating:=Form.FindComponent('cbPersonalAuthorRating') as TComboBox;
        Hidden:=Form.FindComponent('cbPersonalAuthorHidden') as TCheckBox;
        Category.ItemIndex:=3; Category.OnChange(Category); Search.Text:='Absent';
        Require(List.Items.Count=1,'Manager omitted an author absent from all collections');
        List.Items[0].Selected:=True;
        Require(Rating.Enabled and Hidden.Enabled,'Manager cannot edit an absent author');
        Rating.ItemIndex:=3; Rating.OnChange(Rating);
        Search.Text:='Absent'; List.Items[0].Selected:=True;
        Hidden.Checked:=False; Hidden.OnClick(Hidden);
        Search.Text:='Alpha'; Found:=False;
        for var Row in List.Items do
          if Row.Caption='Alpha Alex' then begin Row.Selected:=True; Found:=True; end;
        Require(Found,'Hidden real author cannot be restored in the global manager');
        Hidden.Checked:=False; Hidden.OnClick(Hidden);
        OldDark:=MHLThemeDark;
        try
          for var Dark in [False,True] do
          begin
            SetMHLTheme(Dark); ApplyMHLControlTheme(Form);
            for var DPI in [96,144,192] do
            begin
              Form.ScaleForPPI(DPI);
              Require((Rating.Top+Rating.Height<=List.Top) and
                (Hidden.Left+Hidden.Width<=Form.ClientWidth) and (List.Height>0),
                'Personal author editor overlaps the result list at DPI '+IntToStr(DPI));
              if DPI=96 then
              begin
                var Bitmap:=Form.GetFormImage; var Png:=TPngImage.Create;
                try Png.Assign(Bitmap); Png.SaveToFile(Settings.AppPath+'personal-authors-dark-'+IntToStr(Ord(Dark))+'.png');
                finally Png.Free; Bitmap.Free; end;
              end;
            end;
          end;
        finally SetMHLTheme(OldDark); end;
        ManagerSeen:=True; TButton(Form.FindComponent('btnCloseFavoriteAuthors')).Click;
      end;
    TThread.ForceQueue(nil,CloseManager);
    var Menu:=frmMain.FindComponent('miAllFavoriteAuthors') as TMenuItem; Menu.Click;
    Require(ManagerSeen,'My authors manager callback did not complete');
    Store.Reload;
    Require((Store.PersonalEntry('Absent','Author','').Rating=3) and
      not Store.PersonalEntry('Absent','Author','').Hidden,'Absent author edits were not durable');
    ApplySearch; Require(VisibleBooks(frmMain.tvBooksSR)=7,'Restoring author visibility did not restore the complete result');
    ManagerSeen:=False;
    CloseManager:=procedure
      var Form: TfrmAuthorFavorites; List: TListView; Category, Rating: TComboBox; Hidden: TCheckBox;
      begin
        Form:=nil;
        for var I:=0 to Screen.FormCount-1 do
          if Screen.Forms[I] is TfrmAuthorFavorites then Form:=TfrmAuthorFavorites(Screen.Forms[I]);
        Require(Assigned(Form),'Batch manager did not open');
        Category:=Form.FindComponent('cbPersonalAuthorCategory') as TComboBox;
        List:=Form.FindComponent('lvAllFavoriteAuthors') as TListView;
        Rating:=Form.FindComponent('cbPersonalAuthorRating') as TComboBox;
        Hidden:=Form.FindComponent('cbPersonalAuthorHidden') as TCheckBox;
        Category.ItemIndex:=3; Category.OnChange(Category);
        Require(List.Items.Count=3,'Batch manager lost personal authors');
        for var Row in List.Items do Row.Selected:=True;
        Require(Rating.Enabled and Hidden.Enabled and (Rating.ItemIndex=-1),
          'Batch editor cannot represent different ratings');
        Rating.ItemIndex:=4; Rating.OnChange(Rating);
        Require(List.SelCount=3,'Batch rating discarded the selection');
        Hidden.Checked:=True; Store.Reload;
        for var Entry in Store.PersonalEntries do
          Require((Entry.Rating=4) and Entry.Hidden,'Batch visibility overwrote a rating');
        Require((List.SelCount=3) and (Length(Store.PersonalEntries)=3),'Batch visibility lost selected authors');
        Hidden.Checked:=False;
        Rating.ItemIndex:=0; Rating.OnChange(Rating);
        Store.Reload;
        Require((Length(Store.PersonalEntries)=0) and (List.Items.Count=0),
          'Batch unhide and clear failed to remove personal settings');
        ManagerSeen:=True; TButton(Form.FindComponent('btnCloseFavoriteAuthors')).Click;
      end;
    TThread.ForceQueue(nil,CloseManager); Menu.Click;
    Require(ManagerSeen,'Batch manager callback did not complete');
    ApplySearch; Require(VisibleBooks(frmMain.tvBooksSR)=7,'Batch reset did not restore unfiltered search');
    Require(THashSHA2.GetHashStringFromFile(SystemDB.GetCollectionInfo(Collection.CollectionID).DBFileName)=SourceHash,
      'Author preference commands changed the collection');
    Store.SetPersonalRating('Beta','Alex','',5); Store.SetHidden('Beta','Alex','',True);
    Minimum.Items[4].Click; ShowHidden.Click; Unrated.Click;
    Settings.SaveSettings;
    var SI: TStartupInfo; var PI: TProcessInformation; var Command: string; var ExitCode: DWORD;
    SI:=Default(TStartupInfo); SI.cb:=SizeOf(SI); PI:=Default(TProcessInformation);
    Command:='"'+ParamStr(0)+'" personal-author-reopen'; UniqueString(Command);
    Require(CreateProcess(nil,PChar(Command),nil,nil,True,CREATE_NO_WINDOW,nil,PChar(Settings.AppPath),SI,PI),
      'Cannot start the personal author restart check');
    try
      Require(WaitForSingleObject(PI.hProcess,30000)=WAIT_OBJECT_0,'Personal author restart check timed out');
      Require(GetExitCodeProcess(PI.hProcess,ExitCode) and (ExitCode=0),'Personal author restart check failed');
    finally CloseHandle(PI.hThread); CloseHandle(PI.hProcess); end;
    Writeln('PASS personal author context scores hidden coauthors search favorites widening manager absent authors durable edits and DPI');
    Writeln('PASS personal author manager atomic group rating hide restore and clear retain selection');
    Writeln('PASS personal author hiding and reveal update loaded series genres groups and publisher series');
  finally Store.Free; end;
end;

procedure TestPersonalAuthorReopen;
var Store: TAuthorFavorites; Minimum, ShowHidden, Unrated: TMenuItem; Count: Integer;
  Node: PVirtualNode; Book: PBookRecord;
begin
  Application.CreateForm(TdmImages,dmImages); dmImages.ApplyThemeIcons;
  Application.CreateForm(TfrmMain,frmMain);
  try
    Minimum:=frmMain.FindComponent('miPersonalAuthorMinimum') as TMenuItem;
    ShowHidden:=frmMain.FindComponent('miPersonalAuthorShowHidden') as TMenuItem;
    Unrated:=frmMain.FindComponent('miPersonalAuthorUnrated') as TMenuItem;
    Require(Minimum.Items[4].Checked and ShowHidden.Checked and not Unrated.Checked,
      'Personal author filter switches were lost in a fresh process');
    Store:=TAuthorFavorites.Create(IncludeTrailingPathDelimiter(Settings.DataPath)+AUTHOR_FAVORITES_FILE_NAME);
    try Require((Store.PersonalEntry('Beta','Alex','').Rating=5) and Store.PersonalEntry('Beta','Alex','').Hidden,
      'Author personal data were lost after restart'); finally Store.Free; end;
    ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False);
    frmMain.cbDeleted.Checked:=True; frmMain.cbDeleted.OnClick(frmMain.cbDeleted);
    frmMain.cbCollapseMultiSeriesResults.Checked:=True; frmMain.DoApplyFilter(nil);
    Count:=0; Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Book:=frmMain.tvBooksSR.GetNodeData(Node);
      if (Book.NodeType=ntBookInfo) and not frmMain.tvBooksSR.IsEffectivelyFiltered[Node] then Inc(Count);
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(Count=3,'Restored author policy failed to apply to a fresh search');
    Writeln('PASS personal author preference data and filters survive a fresh Main process'); Flush(Output);
  finally FreeAndNil(frmMain); FreeAndNil(dmImages); FinalizeMHLTheme; end;
end;
