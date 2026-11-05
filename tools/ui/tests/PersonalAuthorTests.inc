type
  TPersonalCancelBooks = class(TInterfacedObject, IBookIterator)
  private
    FIndex: Integer;
    FBeta, FGamma: TBookAuthors;
  public
    constructor Create;
    function Next(out Book: TBookRecord): Boolean;
    function RecordCount: Integer;
  end;

constructor TPersonalCancelBooks.Create;
begin
  inherited Create;
  TAuthorsHelper.Add(FBeta,'Beta','Alex',''); TAuthorsHelper.Add(FGamma,'Gamma','Alex','');
end;

function TPersonalCancelBooks.RecordCount: Integer;
begin Result:=500000; end;

function TPersonalCancelBooks.Next(out Book: TBookRecord): Boolean;
begin
  Result:=FIndex<RecordCount; if not Result then Exit;
  Inc(FIndex); Book.Clear; Book.NodeType:=ntBookInfo;
  Book.BookKey:=CreateBookKey(9000000+FIndex,Settings.ActiveCollection);
  Book.Title:='Проверка отмены на большом списке'; Book.Lang:='ru'; Book.FileExt:='.fb2';
  if Odd(FIndex) then Book.Authors:=FBeta else Book.Authors:=FGamma;
end;

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
  procedure CheckLargeCancel;
  var Languages: TComboBox; Tree: TBookTree; Canceller: TThread; CancelHandle: HWND;
    Trees: TArray<TBookTree>; Before: TArray<string>; Focus: PVirtualNode; IniHash: string;
    OriginalMode: TTreeMode; Reset: TMenuItem; Filters: TBookColumnFilters;
    Plan: TBookColumnFilterPlan; Rejected: Boolean; SavedPolicy: TPersonalAuthorFilterState;
    function Snapshot(A: TBookTree): string;
    var Node: PVirtualNode; Builder: TStringBuilder;
    begin
      Builder:=TStringBuilder.Create;
      try
        Builder.Append(NativeUInt(A.FocusedNode)).Append(':'); Node:=A.GetFirst;
        while Assigned(Node) do
        begin
          Builder.Append(Node.Index).Append(':').Append(Ord(A.IsFiltered[Node])).Append(':').
            Append(Ord(A.Selected[Node])).Append(':').Append(Ord(Node.CheckState)).Append(';');
          Node:=A.GetNext(Node);
        end;
        Result:=THashSHA2.GetHashString(Builder.ToString);
      finally Builder.Free; end;
    end;
    procedure RequireUnchanged;
    begin
      for var I:=0 to High(Trees) do Require(Snapshot(Trees[I])=Before[I],
        'Canceled personal filter changed rows, checks, selection or focus in view '+IntToStr(I));
    end;
  begin
    Writeln('TRACE personal large cancellation fixture setup'); Flush(Output);
    Reset:=TMenuItem(frmMain.FindComponent('miPersonalAuthors')).Items[4]; Reset.Click;
    if not ShowHidden.Checked then ShowHidden.Click;
    SelectAuthor('Beta'); RatingMenu.Items[2].Click; Reset.Click;
    ShowPage(PAGE_SEARCH); Tree:=frmMain.tvBooksSR;
    OriginalMode:=Settings.TreeModes[PAGE_SEARCH]; Settings.TreeModes[PAGE_SEARCH]:=tmFlat;
    Languages:=TComboBox.Create(nil);
    try
      Languages.Parent:=frmMain; Languages.Visible:=False; Languages.Items.Add('-'); Languages.ItemIndex:=0;
      frmMain.FillBooksTree(Tree,Languages,TPersonalCancelBooks.Create as IBookIterator,False,False,nil);
      Require(VisibleBooks(Tree)=500000,'Large cancellation fixture omitted rows');
      Focus:=Tree.GetFirst; Tree.FocusedNode:=Focus; Tree.Selected[Focus]:=True;
      Focus.CheckState:=csCheckedNormal; Tree.GetLast.CheckState:=csCheckedNormal;
      Trees:=TArray<TBookTree>.Create(frmMain.tvBooksA,frmMain.tvBooksS,frmMain.tvBooksG,
        Tree,frmMain.tvBooksF,PublisherView.Books);
      SetLength(Before,Length(Trees));
      for var I:=0 to High(Trees) do Before[I]:=Snapshot(Trees[I]);
      Filters:=TBookColumnFilters.ForTree(Tree); SavedPolicy:=GetPersonalAuthorFilterState;
      Plan:=Filters.PrepareApply(False);
      try
        Filters.SetValue(COL_TITLE,'=does-not-exist'); Rejected:=False;
        try Plan.CheckReady; except on E:EInvalidOp do Rejected:=True; end;
        Require(Rejected,'Prepared filter ignored changed column conditions'); Filters.SetValue(COL_TITLE,'');
      finally Plan.Free; end;
      Plan:=Filters.PrepareApply(False);
      try
        SetPersonalAuthorFilter(SavedPolicy.Entries,5,False,False); Rejected:=False;
        try Plan.CheckReady; except on E:EInvalidOp do Rejected:=True; end;
        Require(Rejected,'Prepared filter ignored a changed personal policy');
      finally
        SetPersonalAuthorFilter(SavedPolicy.Entries,SavedPolicy.MinimumRating,SavedPolicy.IncludeUnrated,SavedPolicy.ShowHidden);
        Plan.Free;
      end;
      RequireUnchanged;
      IniHash:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
      CancelHandle:=TButton(frmMain.FindComponent('BookListCancel')).Handle;
      Canceller:=TThread.CreateAnonymousThread(procedure
        begin
          Sleep(40);
          PostMessage(CancelHandle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(4,4));
          PostMessage(CancelHandle,WM_LBUTTONUP,0,MakeLParam(4,4));
        end);
      Canceller.FreeOnTerminate:=False;
      try Canceller.Start; Minimum.Items[4].Click; finally Canceller.WaitFor; Canceller.Free; end;
      Require(frmMain.BookListCancelled,'Large personal filtering completed without exercising the cancel path');
      RequireUnchanged;
      Require(Minimum.Items[0].Checked and not Minimum.Items[4].Checked and Unrated.Checked,
        'Cancel retained the new personal filter controls');
      Require(THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=IniHash,
        'Cancel persisted a personal filter that was never applied');
      Require(GetPersonalAuthorFilterState.MinimumRating=0,'Cancel did not restore the previously applied policy');
      Minimum.Items[4].Click;
      Require(not frmMain.BookListCancelled and Minimum.Items[4].Checked and (VisibleBooks(Tree)=250000),
        'Retry did not apply the author policy to all matching large-list rows');
      Reset.Click; Require(VisibleBooks(Tree)=500000,'Widening the policy lost canceled or filtered rows');
      Writeln('PASS personal author cancel preserves six loaded views and settings on 500000 rows; retry and widening succeed');
    finally
      Languages.Free; Settings.TreeModes[PAGE_SEARCH]:=OriginalMode; ApplySearch;
    end;
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
    Settings.RestoreBookViews:=rbvAutomatic; Settings.SaveSettings;
    var SI: TStartupInfo; var PI: TProcessInformation; var Command: string; var ExitCode: DWORD;
    SI:=Default(TStartupInfo); SI.cb:=SizeOf(SI); PI:=Default(TProcessInformation);
    Command:='"'+ParamStr(0)+'" personal-author-reopen'; UniqueString(Command);
    Require(CreateProcess(nil,PChar(Command),nil,nil,True,CREATE_NO_WINDOW,nil,PChar(Settings.AppPath),SI,PI),
      'Cannot start the personal author restart check');
    try
      var ChildWait:=WaitForSingleObject(PI.hProcess,30000);
      if ChildWait<>WAIT_OBJECT_0 then begin TerminateProcess(PI.hProcess,2); WaitForSingleObject(PI.hProcess,5000); end;
      Require(ChildWait=WAIT_OBJECT_0,'Personal author restart check timed out');
      Require(GetExitCodeProcess(PI.hProcess,ExitCode),'Cannot read personal author restart status');
      var Failure:=Settings.AppPath+'personal-author-reopen.error';
      var Detail:=''; if FileExists(Failure) then Detail:=TFile.ReadAllText(Failure,TEncoding.UTF8);
      Require(ExitCode=0,'Personal author restart check failed ('+IntToStr(ExitCode)+'): '+Detail);
    finally CloseHandle(PI.hThread); CloseHandle(PI.hProcess); end;
    var Proof:=Settings.AppPath+'personal-author-reimport.ok';
    Require(FileExists(Proof) and (StrToIntDef(Trim(TFile.ReadAllText(Proof,TEncoding.UTF8)),0)<>Integer(GetCurrentProcessId)),
      'The separate-process reimport proof is absent');
    Proof:=Settings.AppPath+'personal-author-transfer.ok';
    Require(FileExists(Proof) and (StrToIntDef(Trim(TFile.ReadAllText(Proof,TEncoding.UTF8)),0)<>Integer(GetCurrentProcessId)),
      'The separate-process general transfer menu proof is absent');
    CheckLargeCancel;
    Writeln('PASS personal author general user-data menus export import preserve existing preferences and cancel');
    Writeln('PASS personal author native full INPX reimport preserves rating hiding and matches new local IDs');
    Writeln('PASS personal author context scores hidden coauthors search favorites widening manager absent authors durable edits and DPI');
    Writeln('PASS personal author manager atomic group rating hide restore and clear retain selection');
    Writeln('PASS personal author hiding and reveal update loaded series genres groups and publisher series');
  finally Store.Free; end;
end;

procedure TestPersonalAuthorReimport(OriginalID: Integer);
var ID, FirstBetaID: Integer; IndexFile, IndexHash, ProfileFile: string;
  Worker: TManualUpdateThread; Store: TAuthorFavorites; Before, After: TAuthorPersonalEntry;
  ShowHidden: TMenuItem;
  procedure WriteIndex(Pass: Integer);
  var Zip: TZipFile; Data, Rows: string;
    function Row(const Author, Title, LibID: string): string;
    begin
      Result:=Author+',Alex:'+#4+'prose_contemporary:'+#4+Title+#4+LibID+#4+'128'+#4+
        LibID+#4+'0'+#4+'fb2'+#4+'2026-11-05'+#4+'ru'+#13#10;
    end;
  begin
    if Pass=1 then Rows:=Row('Alpha','Index Alpha','9201')+Row('Beta','Index Beta','9202')
    else Rows:=Row('Beta','Updated Beta','9202')+Row('Beta','New Beta','9203')+Row('Alpha','Updated Alpha','9201');
    Zip:=TZipFile.Create;
    try
      Zip.Open(IndexFile,zmWrite);
      Data:='AUTHOR;GENRE;TITLE;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG';
      Zip.Add(TEncoding.UTF8.GetBytes(Data),'structure.info');
      Zip.Add(TEncoding.UTF8.GetBytes(Rows),'books.inp');
    finally Zip.Free; end;
  end;
  function VisibleCount: Integer;
  var Node: PVirtualNode; Book: PBookRecord;
  begin
    Result:=0; Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Book:=frmMain.tvBooksSR.GetNodeData(Node);
      if (Book.NodeType=ntBookInfo) and not frmMain.tvBooksSR.IsEffectivelyFiltered[Node] then
      begin
        Inc(Result);
        Require((Length(Book.Authors)=1) and (Book.Authors[0].LastName='Beta'),
          'Reimported unrated author bypassed the restored filter');
        if Book.LibID='9202' then
          if FirstBetaID=0 then FirstBetaID:=Book.BookKey.BookID
          else Require(FirstBetaID<>Book.BookKey.BookID,'Full reimport did not exercise changed catalogue-local book IDs');
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
  end;
begin
  IndexFile:=Settings.AppPath+'personal-author-reimport.inpx';
  ProfileFile:=IncludeTrailingPathDelimiter(Settings.DataPath)+AUTHOR_FAVORITES_FILE_NAME;
  Store:=TAuthorFavorites.Create(ProfileFile);
  try
    Before:=Store.PersonalEntry('Beta','Alex',''); FirstBetaID:=0;
    ID:=SystemDB.CreateCollection('Personal reimport',Settings.AppPath,'personal-reimport.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    ChangeCollection(frmMain.miCollSelect.Items[0].Tag);
    ChangeCollection(OriginalID);
    ShowHidden:=frmMain.FindComponent('miPersonalAuthorShowHidden') as TMenuItem;
    for var Pass:=1 to 2 do
    begin
      WriteIndex(Pass); IndexHash:=THashSHA2.GetHashStringFromFile(IndexFile);
      Worker:=TManualUpdateThread.Create(ID,IndexFile,Pass=2,gtFb2);
      try Worker.Start; Worker.WaitFor;
        Require(Worker.Success and not Assigned(Worker.FatalException),'Personal author INPX update failed');
      finally Worker.Free; end;
      Require(THashSHA2.GetHashStringFromFile(IndexFile)=IndexHash,'INPX update changed the source index');
      ChangeCollection(ID); ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False);
      frmMain.cbDeleted.Checked:=True; frmMain.cbDeleted.OnClick(frmMain.cbDeleted);
      frmMain.cbCollapseMultiSeriesResults.Checked:=True; frmMain.DoApplyFilter(nil);
      Require(VisibleCount=Pass,'Personal author rules lost reimported or newly added books');
      ShowHidden.Click;
      Require(VisibleCount=0,'Hidden author became visible after INPX reimport');
      ShowHidden.Click;
      Store.Reload; After:=Store.PersonalEntry('Beta','Alex','');
      Require((After.Rating=Before.Rating) and (After.Hidden=Before.Hidden) and
        (After.UpdatedUTC=Before.UpdatedUTC),'INPX reimport rewrote independent author settings');
      ChangeCollection(OriginalID);
    end;
    TFile.WriteAllText(Settings.AppPath+'personal-author-reimport.ok',IntToStr(GetCurrentProcessId),TEncoding.UTF8);
  finally Store.Free; end;
end;

procedure TestPersonalAuthorUserDataMenu;
var Store: TAuthorFavorites; Data: TUserData; Driver: TSPTDialogDriver;
  FileName, CancelFile, ExportHash, ProfileHash: string; PreviousDialogs: Boolean;
  BeforeBeta: TAuthorPersonalEntry;
  function PreferenceSnapshot: string;
  var Rows: TStringList;
  begin
    Store.Reload; Rows:=TStringList.Create;
    try
      for var Entry in Store.Entries do Rows.Add('F:'+Entry.Key);
      for var Entry in Store.PersonalEntries do Rows.Add('P:'+Entry.Author.Key+':'+
        IntToStr(Entry.Rating)+':'+BoolToStr(Entry.Hidden,True)+':'+Entry.UpdatedUTC);
      Rows.Sort; Result:=THashSHA2.GetHashString(Rows.Text);
    finally Rows.Free; end;
  end;
  procedure ReloadMainProfile;
  var CloseManager: TThreadProcedure;
  begin
    CloseManager:=procedure
      var Manager: TfrmAuthorFavorites;
      begin
        Manager:=nil;
        for var I:=0 to Screen.FormCount-1 do
          if Screen.Forms[I] is TfrmAuthorFavorites then Manager:=TfrmAuthorFavorites(Screen.Forms[I]);
        Require(Assigned(Manager),'Author menu reload did not open the manager');
        TButton(Manager.FindComponent('btnCloseFavoriteAuthors')).Click;
      end;
    TThread.ForceQueue(nil,CloseManager);
    TMenuItem(frmMain.FindComponent('miAllFavoriteAuthors')).Click;
  end;
  procedure FileAction(Menu: TMenuItem; const Title, Path: string; Cancel: Boolean);
  begin
    Driver.Title:=Title; Driver.FileName:=Path; Driver.Cancel:=Cancel;
    Driver.Seen:=False; Driver.Failure:=''; Driver.Timer.Enabled:=True;
    try Menu.Click; finally Driver.Timer.Enabled:=False; end;
    Require(Driver.Seen and (Driver.Failure=''),'General user-data file picker did not complete: '+Driver.Failure);
  end;
  procedure CheckExport;
  var FavoriteFound, AbsentFound, BetaFound: Boolean;
  begin
    Data.Load(FileName); FavoriteFound:=False; AbsentFound:=False; BetaFound:=False;
    for var Entry in Data.FavoriteAuthors do
      if Entry.Key=AuthorFavoriteKey('Перенос','Отсутствующий','Автор') then FavoriteFound:=True;
    for var Entry in Data.PersonalAuthors do
    begin
      if Entry.Author.Key=AuthorFavoriteKey('Перенос','Отсутствующий','Автор') then
        AbsentFound:=(Entry.Rating=4) and Entry.Hidden;
      if Entry.Author.Key=AuthorFavoriteKey('Beta','Alex','') then BetaFound:=(Entry.Rating=5) and Entry.Hidden;
    end;
    Require(FavoriteFound and AbsentFound and BetaFound and (Data.Groups.Count>0),
      'General user-data export omitted personal authors, favorites or existing book groups');
  end;
begin
  FileName:=Settings.AppPath+'Личные авторы — перенос.mhlud2';
  CancelFile:=Settings.AppPath+'Личные авторы — отмена.mhlud2';
  Store:=TAuthorFavorites.Create(IncludeTrailingPathDelimiter(Settings.DataPath)+AUTHOR_FAVORITES_FILE_NAME);
  Data:=TUserData.Create; Driver:=TSPTDialogDriver.Create;
  PreviousDialogs:=Vcl.Dialogs.UseLatestCommonDialogs;
  try
    Vcl.Dialogs.UseLatestCommonDialogs:=False;
    Store.SetFavorite('Перенос','Отсутствующий','Автор',True);
    Store.SetPersonalRating('Перенос','Отсутствующий','Автор',4);
    Store.SetHidden('Перенос','Отсутствующий','Автор',True); ReloadMainProfile;
    ProfileHash:=PreferenceSnapshot;
    FileAction(frmMain.miExportUserData,'Экспорт пользовательских данных',CancelFile,True);
    Require(not FileExists(CancelFile) and (PreferenceSnapshot=ProfileHash),
      'Canceling general export created output or changed personal author settings');
    FileAction(frmMain.miExportUserData,'Экспорт пользовательских данных',FileName,False);
    CheckExport; ExportHash:=THashSHA2.GetHashStringFromFile(FileName);
    Store.SetFavorite('Перенос','Отсутствующий','Автор',False);
    Store.SetHidden('Перенос','Отсутствующий','Автор',False);
    Store.SetPersonalRating('Перенос','Отсутствующий','Автор',0);
    Store.SetPersonalRating('Beta','Alex','',2); Store.SetHidden('Beta','Alex','',False);
    Store.SetPersonalRating('Только здесь','Автор','',1); ReloadMainProfile;
    BeforeBeta:=Store.PersonalEntry('Beta','Alex','');
    ProfileHash:=PreferenceSnapshot;
    FileAction(frmMain.miImportUserData,'Импорт пользовательских данных',FileName,True);
    Require(PreferenceSnapshot=ProfileHash,
      'Canceling general import changed personal author settings');
    FileAction(frmMain.miImportUserData,'Импорт пользовательских данных',FileName,False);
    Store.Reload;
    Require(Store.IsFavorite('Перенос','Отсутствующий','Автор') and
      (Store.PersonalEntry('Перенос','Отсутствующий','Автор').Rating=4) and
      Store.PersonalEntry('Перенос','Отсутствующий','Автор').Hidden,
      'General import failed to restore an absent favorite, rating and hidden flag');
    Require((Store.PersonalEntry('Beta','Alex','').Rating=2) and
      not Store.PersonalEntry('Beta','Alex','').Hidden and
      (Store.PersonalEntry('Beta','Alex','').UpdatedUTC=BeforeBeta.UpdatedUTC) and
      (Store.PersonalEntry('Только здесь','Автор','').Rating=1),
      'General import overwrote existing personal author settings');
    Require(THashSHA2.GetHashStringFromFile(FileName)=ExportHash,'General import modified its portable source');
    TFile.WriteAllText(Settings.AppPath+'personal-author-transfer.ok',IntToStr(GetCurrentProcessId),TEncoding.UTF8);
  finally
    Vcl.Dialogs.UseLatestCommonDialogs:=PreviousDialogs;
    Driver.Free; Data.Free; Store.Free;
  end;
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
    try TestPersonalAuthorReimport(Settings.ActiveCollection); TestPersonalAuthorUserDataMenu;
    except on E:Exception do begin
      TFile.WriteAllText(Settings.AppPath+'personal-author-reopen.error',E.ClassName+': '+E.Message,TEncoding.UTF8);
      raise;
    end; end;
    Writeln('PASS personal author preference data and filters survive a fresh Main process'); Flush(Output);
  finally FreeAndNil(frmMain); FreeAndNil(dmImages); FinalizeMHLTheme; end;
end;
