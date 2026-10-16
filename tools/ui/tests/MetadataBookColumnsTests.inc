// Include after AddBook / ShowPage / PublisherView / TFCTModalProbe.
// Every catalog row, group, layout and window belongs to the isolated runtime.
const
  MBCColumnTags: array[0..4] of Integer =
    (COL_PUBLISHER, COL_TRANSLATORS, COL_CITY, COL_PUBYEAR, COL_ISBN);
  MBCColumnCaptions: array[0..4] of string =
    ('Издательство', 'Переводчики', 'Город издания', 'Год издания', 'ISBN');
  MBCYears: array[0..3] of Integer = (9,10,2001,0);
  MBCPublishers: array[0..3] of string = ('Ёлка Пресс','елка пресс','Élan 中文','');
  MBCTranslators: array[0..3] of string = ('Ёжов Иван; 李明','ежов иван; 李明','Алексей 中文','');
  MBCCities: array[0..3] of string = ('Орёл','орел','東京','');
  MBCISBNs: array[0..3] of string = ('978-0-12-X','978-0-12-x','0-00-中文','');

function MBCColumn(Tree: TBookTree; Tag: Integer): Integer;
begin
  Result:=-1;
  for var I:=0 to Tree.Header.Columns.Count-1 do
    if Tree.Header.Columns[I].Tag=Tag then Exit(I);
end;

procedure MBCRefreshMenu;
begin
  // Main refreshes its private SetHeaderPopUp through the public tab event.
  // Every caller already selected its actual page with MBCActivate.
  frmMain.pgControlChange(nil);
end;

function MBCMenu(Tag: Integer): TMenuItem;
var Count: Integer;
begin
  Result:=nil; Count:=0;
  for var Item in frmMain.pmHeaders.Items do
    if Item.Tag=Tag then begin Result:=Item; Inc(Count); end;
  Require((Count=1) and Assigned(Result) and Assigned(Result.OnClick),
    'Metadata column must have exactly one working header menu ID '+IntToStr(Tag));
end;

procedure MBCActivate(Tree: TBookTree);
begin
  if Tree.Tag=PAGE_PUBLISHER_SERIES then
  begin frmMain.pgControl.ActivePage:=PublisherView.Tab; frmMain.pgControlChange(nil); end
  else ShowPage(Tree.Tag);
end;

procedure MBCEnsureColumns(Tree: TBookTree);
var Item: TMenuItem; Found: Boolean;
begin
  MBCActivate(Tree);
  for var Tag in MBCColumnTags do
  begin
    Found:=False;
    for var FilterTag in Tree.HeaderFilterTags do if FilterTag=Tag then Found:=True;
    Require(Found,'Metadata header has no standard filter affordance: '+IntToStr(Tag));
    MBCRefreshMenu; Item:=MBCMenu(Tag);
    if MBCColumn(Tree,Tag)<0 then Item.OnClick(Item);
    MBCRefreshMenu;
    Require(Item.Checked and (MBCColumn(Tree,Tag)>=0),
      'Metadata column menu did not reflect its visible state');
  end;
end;

procedure MBCFixtures(const Collection: IBookCollection; out IDs: TArray<Integer>; out GroupID: Integer);
var Book: TBookRecord; Groups: IGroupIterator; Group: TGroupData; GroupName: string;
begin
  SetLength(IDs,4);
  for var I:=0 to High(IDs) do
  begin
    Book:=Default(TBookRecord); Book.Title:='Сведения столбцы '+IntToStr(I);
    Book.LibID:='metadata-columns-'+IntToStr(I); Book.FileName:=Book.LibID;
    Book.FileExt:='.fb2'; Book.Lang:='ru'; if I=1 then Book.Lang:='en';
    Book.Size:=100; Book.Date:=EncodeDate(2020,1,1); Book.Series:='Цикл сведений';
    TAuthorsHelper.Add(Book.Authors,'Столбцы','Проверка','');
    TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
    Book.Publisher:=MBCPublishers[I]; Book.Translators:=MBCTranslators[I];
    Book.City:=MBCCities[I]; Book.PubYear:=MBCYears[I]; Book.ISBN:=MBCISBNs[I];
    IDs[I]:=Collection.InsertBook(Book,False,False);
    Require(IDs[I]>0,'Metadata column fixture was not inserted');
  end;
  GroupName:='Столбцы сведений '+TGUID.NewGuid.ToString;
  Require(SystemDB.AddGroup(GroupName),'Metadata column group was not created');
  GroupID:=MHL_INVALID_ID; Groups:=SystemDB.GetGroupIterator;
  while Groups.Next(Group) do if Group.Text=GroupName then GroupID:=Group.GroupID;
  Groups:=nil; Require(GroupID<>MHL_INVALID_ID,'Metadata column group is absent');
  for var ID in IDs do Collection.AddBookToGroup(CreateBookKey(ID,Collection.CollectionID),GroupID);
end;

procedure MBCFill(Tree: TBookTree; const Collection: IBookCollection; const IDs: TArray<Integer>; GroupID: Integer);
var Criteria: TBookSearchCriteria; Iterator: IBookIterator; ExpectedIDs: string;
begin
  TBookColumnFilters.ForTree(Tree).Clear; Tree.SortKeys:=nil; Tree.Header.SortColumn:=NoColumn;
  if Tree.Tag=PAGE_FAVORITES then Iterator:=SystemDB.GetBookIterator(GroupID,Collection.CollectionID)
  else
  begin
    Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1; Criteria.RestrictBookIDs:=True;
    Criteria.BookIDs:=Copy(IDs); Criteria.CollapseMultiSeriesResults:=True;
    Iterator:=Collection.Search(Criteria,False);
  end;
  ExpectedIDs:=''; for var ID in IDs do ExpectedIDs:=ExpectedIDs+IntToStr(ID)+',';
  Writeln('TRACE metadata fill tag=',Tree.Tag,' mode=',Ord(Settings.TreeModes[Tree.Tag]),
    ' expected_IDs=',ExpectedIDs); Flush(Output);
  frmMain.FillBooksTree(Tree,nil,Iterator,True,True,nil); Iterator:=nil;
end;

function MBCNode(Tree: TBookTree; ID: Integer): PVirtualNode;
var Book: PBookRecord;
begin
  Result:=Tree.GetFirst;
  while Assigned(Result) do
  begin
    Book:=Tree.GetNodeData(Result);
    if (Book.NodeType=ntBookInfo) and (Book.BookKey.BookID=ID) then Exit;
    Result:=Tree.GetNext(Result);
  end;
  raise Exception.Create('Metadata column row is absent: '+IntToStr(ID));
end;

procedure MBCAssertRows(Tree: TBookTree; const IDs: TArray<Integer>);
var Node: PVirtualNode; Book: PBookRecord; Count: Integer; Text, Expected, ActualIDs: string;
begin
  Count:=0; ActualIDs:=''; Node:=Tree.GetFirst;
  while Assigned(Node) do
  begin
    Book:=Tree.GetNodeData(Node);
    if Book.NodeType=ntBookInfo then begin Inc(Count); ActualIDs:=ActualIDs+IntToStr(Book.BookKey.BookID)+','; end;
    Node:=Tree.GetNext(Node);
  end;
  Writeln('TRACE metadata rows tag=',Tree.Tag,' mode=',Ord(Settings.TreeModes[Tree.Tag]),
    ' expected_count=4 actual_count=',Count,' actual_IDs=',ActualIDs); Flush(Output);
  Require(Count=4,'Metadata DAO/Main publication duplicated or lost rows');
  for var I:=0 to High(IDs) do
    for var Tag in MBCColumnTags do
    begin
      Expected:='';
      case Tag of
        COL_PUBLISHER: Expected:=MBCPublishers[I]; COL_TRANSLATORS: Expected:=MBCTranslators[I];
        COL_CITY: Expected:=MBCCities[I]; COL_ISBN: Expected:=MBCISBNs[I];
        COL_PUBYEAR: if MBCYears[I]<>0 then Expected:=IntToStr(MBCYears[I]);
      end;
      Text:='sentinel'; Tree.OnGetText(Tree,MBCNode(Tree,IDs[I]),MBCColumn(Tree,Tag),ttNormal,Text);
      if Text<>Expected then
      begin
        Book:=Tree.GetNodeData(MBCNode(Tree,IDs[I]));
        Writeln('TRACE metadata cell mismatch view=',Tree.Tag,' mode=',Ord(Settings.TreeModes[Tree.Tag]),
          ' BookID=',IDs[I],' column=',Tag,' expected=[',Expected,'] actual=[',Text,']',
          ' row_publisher=[',Book.Publisher,'] row_translators=[',Book.Translators,'] row_city=[',Book.City,
          '] row_year=',Book.PubYear,' row_ISBN=[',Book.ISBN,']'); Flush(Output);
      end;
      Require(Text=Expected,'Metadata column displays another field or a zero placeholder: '+IntToStr(Tag));
    end;
end;

procedure MBCAssertFilters(Tree: TBookTree);
var Filters: TBookColumnFilters; Names: TStringList;
begin
  Filters:=TBookColumnFilters.ForTree(Tree); Names:=TStringList.Create;
  try
    for var Tag in TArray<Integer>.Create(COL_PUBLISHER,COL_TRANSLATORS,COL_CITY,COL_ISBN) do
    begin
      Filters.Clear; Filters.SetValue(Tag,'=');
      Require(Filters.Apply(False)=1,'Empty metadata text cannot be filtered: '+IntToStr(Tag));
      Filters.Clear; Filters.GetOptions(Tag,Names);
      Require(Names.IndexOf('')>=0,'Missing metadata is absent from exact option values');
      Names.Clear; Names.Add(''); Filters.SetSelectedValues(Tag,Names);
      Require(Filters.Apply(False)=1,'Exact empty metadata selection was treated as clearing the filter');
    end;
    Filters.Clear; Filters.SetValue(COL_TRANSLATORS,'ЕЖОВ');
    Require(Filters.Apply(False)=2,'Translator filtering lost Unicode case or е/ё folding');
    Filters.SetCaseSensitive(COL_TRANSLATORS,True); Filters.SetValue(COL_TRANSLATORS,'=Ёжов Иван; 李明');
    Require(Filters.Apply(False)=1,'Exact Unicode translator filter selected a different spelling');
    Filters.Clear; Filters.SetValue(COL_CITY,'ОРЕЛ');
    Require(Filters.Apply(False)=2,'Publication city filtering lost Cyrillic case or е/ё folding');
    Filters.SetValue(COL_LANG,'=ru');
    Require(Filters.Apply(False)=1,'Publication metadata filters do not combine with ordinary columns');
    Filters.Clear; Filters.SetValue(COL_ISBN,'中文');
    Require(Filters.Apply(False)=1,'ISBN column filtering lost Unicode text');
    Filters.Clear; Filters.SetValue(COL_PUBYEAR,'num;6;9;10;0');
    Require(Filters.Apply(False)=2,'Publication year range is not numeric and inclusive');
    Filters.SetValue(COL_PUBYEAR,'num;5;10;10;0');
    Require(Filters.Apply(False)=1,'Missing publication year entered a numeric inequality as year zero');
    Filters.SetValue(COL_PUBYEAR,'num;7;10;10;0');
    Require(Filters.Apply(False)=2,'Missing publication year entered a numeric not-equal comparison');
    Filters.SetValue(COL_PUBYEAR,'num;8;0;0;0');
    Require(Filters.Apply(False)=1,'Missing publication year condition is incorrect');
    Filters.SetValue(COL_PUBYEAR,'num;9;0;0;0');
    Require(Filters.Apply(False)=3,'Present publication year condition is incorrect');
    Filters.Clear; Require(Filters.Apply(False)=4,'Clearing metadata filters did not restore every book');
  finally Names.Free; Filters.Clear; Filters.Apply(False); end;
end;

procedure MBCAssertSort(Tree: TBookTree; const IDs: TArray<Integer>);
var Compared: Integer; Node: PVirtualNode; Book: PBookRecord; Actual: TArray<Integer>;
begin
  Tree.SortKeys:=nil;
  for var Tag in TArray<Integer>.Create(COL_PUBLISHER,COL_TRANSLATORS,COL_CITY,COL_ISBN) do
  begin
    Compared:=0; Tree.OnCompareNodes(Tree,MBCNode(Tree,IDs[0]),MBCNode(Tree,IDs[2]),MBCColumn(Tree,Tag),Compared);
    case Tag of
      COL_PUBLISHER: Require(Sign(Compared)=Sign(CompareStr(MBCPublishers[0],MBCPublishers[2])),'Publisher sort changed');
      COL_TRANSLATORS: Require(Sign(Compared)=Sign(CompareStr(MBCTranslators[0],MBCTranslators[2])),'Translator sort compares another field');
      COL_CITY: Require(Sign(Compared)=Sign(CompareStr(MBCCities[0],MBCCities[2])),'City sort compares another field');
      COL_ISBN: Require(Sign(Compared)=Sign(CompareStr(MBCISBNs[0],MBCISBNs[2])),'ISBN sort compares another field');
    end;
  end;
  Tree.UpdateSortKey(COL_PUBYEAR); frmMain.SortLoadedBooks(Tree);
  Actual:=nil; Node:=Tree.GetFirst;
  while Assigned(Node) do
  begin
    Book:=Tree.GetNodeData(Node); if Book.NodeType=ntBookInfo then Actual:=Actual+[Book.PubYear];
    Node:=Tree.GetNext(Node);
  end;
  Require((Length(Actual)=4) and (Actual[0]=0) and (Actual[1]=9) and (Actual[2]=10) and (Actual[3]=2001),
    'Actual Main ascending year sorting is lexical or loses empty rows');
  Tree.UpdateSortKey(COL_PUBYEAR); frmMain.SortLoadedBooks(Tree);
  Actual:=nil; Node:=Tree.GetFirst;
  while Assigned(Node) do
  begin
    Book:=Tree.GetNodeData(Node); if Book.NodeType=ntBookInfo then Actual:=Actual+[Book.PubYear];
    Node:=Tree.GetNext(Node);
  end;
  Require((Length(Actual)=4) and (Actual[0]=2001) and (Actual[1]=10) and (Actual[2]=9) and (Actual[3]=0),
    'Actual Main descending year sorting did not reverse its numeric order');
  Tree.SortKeys:=nil; Tree.Header.SortColumn:=NoColumn;
end;

procedure MBCAssertLayout(Tree: TBookTree; const Section: string; Mode: TTreeMode);
var Saved, Reloaded: TColumns; Item: TMenuItem; Index, Position, Width: Integer;
begin
  Index:=MBCColumn(Tree,COL_PUBYEAR); Tree.Header.Columns[Index].Position:=1;
  Tree.Header.Columns[Index].Width:=137; Position:=Tree.Header.Columns[Index].Position;
  Width:=Tree.Header.Columns[Index].Width;
  MBCRefreshMenu; Item:=MBCMenu(COL_ISBN); Item.OnClick(Item); // Saves every actual Main view.
  Require(not Item.Checked and (MBCColumn(Tree,COL_ISBN)<0),'Metadata column did not hide through the standard menu');
  Reloaded:=TColumns.Create(Settings.SystemFileName[sfColumnsStore]); Saved:=TColumns.Create(Settings.AppPath+'metadata-column-roundtrip.ini');
  try
    Reloaded.Load(Section,Mode); Index:=-1;
    for var I:=0 to Reloaded.Count-1 do
    begin
      Require(Reloaded[I].Tag<>COL_ISBN,'Saved layout restored an explicitly hidden metadata column');
      if Reloaded[I].Tag=COL_PUBYEAR then Index:=I;
    end;
    Require((Index>=0) and (Reloaded[Index].Position=Position) and (Reloaded[Index].Width=Width) and
      (Reloaded[Index].Caption='Год издания'),'Fresh column store lost year ID, caption, order or width');
    Reloaded.SetColumns(Tree.Header.Columns); // The same reconstruction used by Main.SetColumns on startup.
    Require((MBCColumn(Tree,COL_ISBN)<0) and (Tree.Header.Columns[MBCColumn(Tree,COL_PUBYEAR)].Position=Position),
      'Main-style header reconstruction lost metadata visibility or ordering');
    Saved.GetColumns(Tree.Header.Columns); Saved.Save(Section); FreeAndNil(Saved);
    Saved:=TColumns.Create(Settings.AppPath+'metadata-column-roundtrip.ini'); Saved.Load(Section,Mode);
    Require(Saved.Count=Reloaded.Count,'Second fresh layout store duplicated or removed metadata IDs');
    MBCRefreshMenu; Require(not MBCMenu(COL_ISBN).Checked and MBCMenu(COL_PUBYEAR).Checked,
      'Actual header popup checkmarks disagree with the restored metadata layout');
    Item:=MBCMenu(COL_ISBN); Item.OnClick(Item);
  finally Saved.Free; Reloaded.Free; end;
end;

procedure MBCAssertEditors(Tree: TBookTree);
var Probe: TFCTModalProbe; Filters: TBookColumnFilters; SavedTheme: Boolean;
begin
  Filters:=TBookColumnFilters.ForTree(Tree); SavedTheme:=MHLThemeDark;
  try
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark); Filters.Clear;
      Probe:=TFCTModalProbe.Create('TFilterEditor','Фильтр: Год издания',
        procedure(Popup: TForm)
        var Mode: TComboBox; FromValue, ToValue: TEdit;
        begin
          Mode:=Popup.FindComponent('NumericFilterMode'+IntToStr(COL_PUBYEAR)) as TComboBox;
          FromValue:=Popup.FindComponent('NumericFilterFrom'+IntToStr(COL_PUBYEAR)) as TEdit;
          ToValue:=Popup.FindComponent('NumericFilterTo'+IntToStr(COL_PUBYEAR)) as TEdit;
          Require(Assigned(Mode) and Assigned(FromValue) and Assigned(ToValue) and (Mode.Items.Count=10),
            'Publication year lacks the standard numeric editor and missing/present choices');
          for var PPI in TArray<Integer>.Create(96,144,192) do
          begin
            Popup.ScaleForPPI(PPI); Require(Popup.Font.PixelsPerInch=PPI,'Numeric year editor lost VCL DPI');
            Require(FromValue.Left+FromValue.Width<=FromValue.Parent.ClientWidth,'Numeric year field is outside its parent');
          end;
          Mode.ItemIndex:=6; Mode.OnChange(Mode); FromValue.Text:='9'; ToValue.Text:='10'; Popup.ModalResult:=mrOk;
        end);
      try Require(EditBookColumnFilter(Tree,COL_PUBYEAR) and Probe.Completed and (Filters.Apply(False)=2),
        'Actual numeric year editor did not apply the inclusive numeric range'); finally Probe.Free; end;
      Probe:=TFCTModalProbe.Create('TFilterEditor','Фильтр: Год издания',
        procedure(Popup: TForm)
        var Mode: TComboBox; FromValue: TEdit;
        begin
          Mode:=Popup.FindComponent('NumericFilterMode'+IntToStr(COL_PUBYEAR)) as TComboBox;
          FromValue:=Popup.FindComponent('NumericFilterFrom'+IntToStr(COL_PUBYEAR)) as TEdit;
          Mode.ItemIndex:=8; Mode.OnChange(Mode);
          Require(not FromValue.Enabled,'Missing-year choice unnecessarily requires a numeric value'); Popup.ModalResult:=mrOk;
        end);
      try Require(EditBookColumnFilter(Tree,COL_PUBYEAR) and Probe.Completed and (Filters.Apply(False)=1),
        'Actual numeric year editor did not select an unspecified year'); finally Probe.Free; end;
      Probe:=TFCTModalProbe.Create('TFilterEditor','Фильтр: Год издания',
        procedure(Popup: TForm)
        begin TComboBox(Popup.FindComponent('NumericFilterMode'+IntToStr(COL_PUBYEAR))).ItemIndex:=9; Popup.ModalResult:=mrCancel; end);
      try Require(not EditBookColumnFilter(Tree,COL_PUBYEAR) and Probe.Completed and (Filters.Apply(False)=1),
        'Cancelling the year editor changed its applied condition'); finally Probe.Free; end;
      Filters.Clear; Filters.Apply(False);
      Probe:=TFCTModalProbe.Create('TListFilterEditor','Фильтр: Переводчики',
        procedure(Popup: TForm)
        var List: TVirtualStringTree; Node, EmptyNode: PVirtualNode; Text: string;
        begin
          List:=Popup.FindComponent('FilterOptionList') as TVirtualStringTree; EmptyNode:=nil;
          Require(Assigned(List),'Translator column lacks its standard checklist editor');
          TButton(Popup.FindComponent('ClearSelectionButton')).Click; Node:=List.GetFirst;
          while Assigned(Node) do
          begin
            Text:=''; List.OnGetText(List,Node,0,ttNormal,Text);
            if Text='(не указано)' then EmptyNode:=Node;
            Node:=List.GetNext(Node);
          end;
          Require(Assigned(EmptyNode),'Empty translator option has no readable name');
          List.CheckState[EmptyNode]:=csCheckedNormal; List.OnChecked(List,EmptyNode);
          Popup.ModalResult:=mrOk;
        end);
      try Require(EditBookColumnFilter(Tree,COL_TRANSLATORS) and Probe.Completed and (Filters.Apply(False)=1),
        'Actual translator checklist did not preserve an exact empty selection'); finally Probe.Free; end;
    end;
  finally Filters.Clear; Filters.Apply(False); SetMHLTheme(SavedTheme); end;
end;

function MBCNewGroup(const User: ISystemData; const Name: string): Integer;
var Groups: IGroupIterator; Group: TGroupData;
begin
  Require(User.AddGroup(Name),'Metadata DAO group fixture was not created');
  Result:=MHL_INVALID_ID; Groups:=User.GetGroupIterator;
  while Groups.Next(Group) do if Group.Text=Name then Result:=Group.GroupID;
  Require(Result<>MHL_INVALID_ID,'Metadata DAO group fixture is absent');
end;

procedure MBCRequirePersonal(const Actual, Expected: TBookRecord);
begin
  Require((Actual.Title=Expected.Title) and (Actual.LibID=Expected.LibID) and
    (Actual.BookKey.DatabaseID=Expected.BookKey.DatabaseID) and (Actual.Size=Expected.Size) and
    (Actual.InsideNo=Expected.InsideNo) and (Actual.Annotation=Expected.Annotation) and
    (Actual.Review=Expected.Review) and (Actual.Rate=Expected.Rate) and
    (Actual.Progress=Expected.Progress) and (Actual.KeyWords=Expected.KeyWords) and
    (ReaderBookPhysicalIdentity(Actual)=ReaderBookPhysicalIdentity(Expected)),
    'Publication projection changed the historical personal card or physical identity');
end;

procedure MBCRequirePublication(const Actual, Expected: TBookRecord);
begin
  Require((Actual.Publisher=Expected.Publisher) and (Actual.Translators=Expected.Translators) and
    (Actual.City=Expected.City) and (Actual.PubYear=Expected.PubYear) and (Actual.ISBN=Expected.ISBN),
    'Group publication projection does not match the current catalog');
end;

procedure MBCAssertFreshGroup(const Collection: IBookCollection; ID, GroupID: Integer);
var Delta: IBookMergeMetadataDeltaUpdater; Before, Changed, OriginalPersonal, Saved, Actual: TBookRecord;
  Iterator: IBookIterator; Found, Updated: Boolean; Count: Integer; Revision: string;

  procedure UpdateSource(const OldValue, NewValue: TBookRecord);
  begin
    Collection.BeginBulkOperation;
    try Delta.UpdateBookMetadataDelta(OldValue,NewValue,False); Collection.EndBulkOperation(True);
    except Collection.EndBulkOperation(False); raise; end;
  end;

begin
  Require(Supports(Collection,IBookMergeMetadataDeltaUpdater,Delta),'Metadata delta interface is absent');
  Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Before,True);
  OriginalPersonal.Clear; SystemDB.GetBookRecord(Before.BookKey,OriginalPersonal);
  SystemDB.SetAnnotation(Before.BookKey,'Личная аннотация: сохранять ё 中文');
  SystemDB.SetReview(Before.BookKey,'Мой отзыв о книге'); SystemDB.SetRate(Before.BookKey,4);
  SystemDB.SetProgress(Before.BookKey,37); Saved.Clear; SystemDB.GetBookRecord(Before.BookKey,Saved);
  Changed:=Before; Changed.Publisher:='Новый издатель после сканирования'; Changed.Translators:='Новый переводчик ё';
  Changed.City:='Новый город 中文'; Changed.PubYear:=2026; Changed.ISBN:='scan-ISBN-2026';
  Changed.Annotation:='Каталожная аннотация должна остаться отдельно от личной'; Updated:=False;
  try
    UpdateSource(Before,Changed); Updated:=True;
    Iterator:=SystemDB.GetBookIterator(GroupID,Collection.CollectionID);
    Require(Iterator.RecordCount=4,'Fresh group projection changed the existing strict row count');
    Revision:=SystemDB.GetDataRevision; Count:=0; Found:=False;
    while Iterator.Next(Actual) do
    begin
      Inc(Count);
      if Actual.BookKey.BookID=ID then
      begin Found:=True; MBCRequirePublication(Actual,Changed); MBCRequirePersonal(Actual,Saved); end;
    end;
    Iterator:=nil;
    Require(Found and (Count=4),'Fresh group projection lost an existing card');
    Actual.Clear; SystemDB.GetBookRecord(Before.BookKey,Actual); MBCRequirePersonal(Actual,Saved);
    Require(SystemDB.GetDataRevision=Revision,'Reading publication metadata wrote to personal cards');
    Writeln('PASS metadata groups read current catalog after metadata delta without replacing personal annotation review rating progress or identity');
  finally
    Iterator:=nil;
    if Updated then UpdateSource(Changed,Before);
    SystemDB.UpdateBook(OriginalPersonal);
  end;
end;

procedure MBCAssertGroupGuardsAndBatches;
const GuardIDs: array[0..3] of string = ('','0','replaced-original','missing-original');
var User: ISystemData; Collection: IBookCollection; DB: TSQLiteDatabase; Query: TSQLiteQuery;
  Root, UserFile, CatalogFile, OfflineFile, ProfileFile, Revision: string;
  CID, GroupID, OfflineGroup, BatchGroup, Count, Index, Searches: Integer;
  SavedCards: array[0..3] of TBookRecord; Book, Actual, Empty, OfflineSaved: TBookRecord;
  Iterator: IBookIterator; ExpectedOrder, ActualOrder: TList<Integer>; Lines: TStringList;
  Fields: TArray<string>; Started, Elapsed: UInt64; SavedHideDeleted, Moved: Boolean;
begin
  Root:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'metadata-group-projection'));
  ForceDirectories(Root); UserFile:=Root+'user.dbs2'; CatalogFile:=Root+'catalog.hlc2';
  OfflineFile:=CatalogFile+'.offline'; ProfileFile:=Root+'publication-batches.tsv';
  Require(not FileExists(UserFile) and not FileExists(CatalogFile),'Use a fresh metadata DAO fixture runtime');
  User:=nil; Collection:=nil; DB:=nil; Query:=nil; Iterator:=nil;
  ExpectedOrder:=TList<Integer>.Create; ActualOrder:=TList<Integer>.Create; Lines:=TStringList.Create;
  SavedHideDeleted:=Settings.HideDeletedBooks; Settings.HideDeletedBooks:=False; Moved:=False;
  try
    TSystemData_SQLite.CreateSystemTables(UserFile); User:=TSystemData_SQLite.Create(UserFile);
    CID:=User.CreateCollection('Metadata group projection',Root,CatalogFile,
      CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst'); Collection:=User.GetCollection(CID);
    GroupID:=MBCNewGroup(User,'Publication identity guards');
    for var I:=0 to High(SavedCards) do
    begin
      Book.Clear; Book.Title:='Foreign catalog '+IntToStr(I); Book.FileName:='foreign-'+IntToStr(I);
      Book.FileExt:='.fb2'; Book.Date:=EncodeDate(2020,1,1); Book.Size:=100;
      Book.LibID:=GuardIDs[I]; if I=2 then Book.LibID:='foreign-replacement';
      Book.Publisher:='FOREIGN'; Book.Translators:='FOREIGN'; Book.City:='FOREIGN'; Book.PubYear:=1999; Book.ISBN:='FOREIGN';
      if I<3 then Index:=Collection.InsertBook(Book,False,False) else Index:=999999;
      Book.Clear; Book.BookKey:=CreateBookKey(Index,CID); Book.Title:='Saved guard '+IntToStr(I);
      Book.LibID:=GuardIDs[I]; Book.FileName:='personal-'+IntToStr(I); Book.FileExt:='.fb2';
      Book.Annotation:='Личная аннотация '+IntToStr(I); Book.Review:='Личный отзыв '+IntToStr(I);
      Book.Rate:=4; Book.Progress:=37; Book.KeyWords:='личный ключ ё';
      User.AddBookToGroup(Book.BookKey,GroupID,Book);
      SavedCards[I].Clear; User.GetBookRecord(Book.BookKey,SavedCards[I]);
    end;
    Empty.Clear; Iterator:=User.GetBookIterator(GroupID,CID);
    Require(Iterator.RecordCount=4,'Identity guards changed saved group membership'); Count:=0;
    while Iterator.Next(Actual) do
    begin
      Inc(Count); Index:=-1;
      for var I:=0 to High(SavedCards) do if Actual.Title=SavedCards[I].Title then Index:=I;
      Require(Index>=0,'Identity guard returned another card');
      MBCRequirePublication(Actual,Empty); MBCRequirePersonal(Actual,SavedCards[Index]);
      if Index>=2 then Require(Actual.BookKey.BookID<0,'Missing or replaced stable ID was not safely detached');
    end;
    Iterator:=nil; Require(Count=4,'Identity guards lost saved cards');
    Writeln('PASS metadata groups keep empty zero replaced and missing LibID publication fields blank and preserve personal cards');

    Book.Clear; Book.Title:='Saved unavailable catalog'; Book.LibID:='offline-stable';
    Book.FileName:='offline-personal'; Book.FileExt:='.fb2'; Book.Annotation:='Личная офлайн аннотация';
    Book.Publisher:='OFFLINE catalog'; Index:=Collection.InsertBook(Book,False,False);
    Collection.GetBookRecord(CreateBookKey(Index,CID),Book,True);
    OfflineGroup:=MBCNewGroup(User,'Publication unavailable catalog'); User.AddBookToGroup(Book.BookKey,OfflineGroup,Book);
    OfflineSaved.Clear; User.GetBookRecord(Book.BookKey,OfflineSaved);
    User.ClearCollectionCache; Collection:=nil; TFile.Move(CatalogFile,OfflineFile); Moved:=True;
    try
      Iterator:=User.GetBookIterator(OfflineGroup,CID); Require(Iterator.RecordCount=1,'Offline group count changed');
      Require(Iterator.Next(Actual),'Offline publication projection lost its saved card');
      MBCRequirePersonal(Actual,OfflineSaved); MBCRequirePublication(Actual,Empty);
      Require(not Iterator.Next(Actual),'Offline publication projection duplicated its card'); Iterator:=nil;
      Require(not FileExists(CatalogFile),'Optional group metadata created a missing catalog file');
    finally Iterator:=nil; User.ClearCollectionCache; TFile.Move(OfflineFile,CatalogFile); Moved:=False; end;
    Writeln('PASS metadata groups return saved cards from an unavailable catalog without creating its missing file');

    Collection:=User.GetCollection(CID); BatchGroup:=MBCNewGroup(User,'Publication bounded batch');
    for var I:=1 to 129 do
    begin
      Book.Clear; Book.Title:='Batch card '+IntToStr(I); Book.LibID:='publication-batch-'+IntToStr(I);
      Book.FileName:=Book.LibID; Book.FileExt:='.fb2'; Book.Publisher:='Batch publisher'; Book.Size:=100;
      Index:=Collection.InsertBook(Book,False,False);
      Collection.AddBookToGroup(CreateBookKey(Index,CID),BatchGroup);
    end;
    // Capture the established iterator order, without imposing a new SQL sort.
    DB:=TSQLiteDatabase.CreateReadOnly(UserFile);
    Query:=DB.NewQuery('SELECT b.BookID FROM BookGroups bg INNER JOIN Books b ON bg.BookID=b.BookID AND bg.DatabaseID=b.DatabaseID '+
      'WHERE bg.GroupID=? AND bg.DatabaseID=?');
    Query.SetParam(0,BatchGroup); Query.SetParam(1,CID); Query.Open;
    while not Query.Eof do begin ExpectedOrder.Add(Query.FieldAsInt(0)); Query.Next; end;
    FreeAndNil(Query); FreeAndNil(DB);
    Iterator:=User.GetBookIterator(BatchGroup,CID); Require(Iterator.RecordCount=129,'Batch group count changed');
    Revision:=User.GetDataRevision; Started:=GetTickCount64; StartSQLiteProfile;
    try
      while Iterator.Next(Actual) do
      begin
        Require(Actual.Publisher='Batch publisher','A batch boundary lost current publication metadata');
        ActualOrder.Add(Actual.BookKey.BookID);
      end;
      SaveSQLiteProfile(ProfileFile);
    finally StopSQLiteProfile; end;
    Elapsed:=GetTickCount64-Started; Iterator:=nil;
    Require((ExpectedOrder.Count=129) and (ActualOrder.Count=129),'Batch iterator lost or duplicated a card');
    for var I:=0 to ExpectedOrder.Count-1 do Require(ExpectedOrder[I]=ActualOrder[I],'Batch projection changed group order');
    Require(User.GetDataRevision=Revision,'Batch projection wrote personal cards');
    Lines.LoadFromFile(ProfileFile,TEncoding.UTF8); Searches:=0;
    for var Line in Lines do
    begin
      Fields:=Line.Split([#9]);
      if (Length(Fields)>=5) and (Fields[1]='prepare') and
        Fields[4].StartsWith('INSERT INTO temp.MHLGenreMatches SELECT ') then Inc(Searches,StrToInt(Fields[2]));
    end;
    Writeln('PROFILE metadata group cards=',ActualOrder.Count,' batch=128 catalog_searches=',Searches,' elapsed_ms=',Elapsed);
    Require(Searches=2,'Publication projection performs catalog queries per card instead of bounded batches');
    Writeln('PASS metadata groups project 129 cards in two catalog searches preserving count order and read-only personal data'); Flush(Output);
  finally
    StopSQLiteProfile; Query.Free; DB.Free; Iterator:=nil;
    if Assigned(User) then User.ClearCollectionCache; Collection:=nil;
    if Moved and FileExists(OfflineFile) then TFile.Move(OfflineFile,CatalogFile);
    User:=nil; Lines.Free; ActualOrder.Free; ExpectedOrder.Free; Settings.HideDeletedBooks:=SavedHideDeleted;
  end;
end;

procedure TestMetadataBookColumns(const Collection: IBookCollection);
const Sections: array[0..5] of string = (SECTION_A_FLAT,SECTION_S_FLAT,SECTION_G_FLAT,
  SECTION_F_FLAT,SECTION_SR_FLAT,SECTION_PUBLISHER_S_FLAT);
  TreeSections: array[0..5] of string = (SECTION_A_TREE,SECTION_S_TREE,SECTION_G_TREE,
  SECTION_F_TREE,SECTION_SR_TREE,SECTION_PUBLISHER_S_FLAT);
var Trees: TArray<TBookTree>; IDs: TArray<Integer>; GroupID: Integer; Reopened: IBookCollection;
  Defaults: TColumns; SavedModes: array[0..5] of TTreeMode; Tree: TBookTree; SavedApp, SavedCatalog: Boolean;
begin
  RequireIsolatedRegression; SavedApp:=Settings.CheckUpdate; SavedCatalog:=Settings.CheckExternalLibUpdate;
  Settings.CheckUpdate:=False; Settings.CheckExternalLibUpdate:=False;
  Trees:=TArray<TBookTree>.Create(frmMain.tvBooksA,frmMain.tvBooksS,frmMain.tvBooksG,
    frmMain.tvBooksF,frmMain.tvBooksSR,PublisherView.Books);
  for var I:=0 to High(Trees) do SavedModes[I]:=Settings.TreeModes[Trees[I].Tag];
  Defaults:=TColumns.Create(Settings.AppPath+'metadata-columns-defaults.ini');
  try
    for var I:=0 to High(MBCColumnTags) do Require(string(MBCMenu(MBCColumnTags[I]).Caption)=MBCColumnCaptions[I],
      'Metadata header menu has an incorrect caption');
    for var Section in Sections do
    begin
      Defaults.Load(Section,tmFlat);
      for var I:=0 to Defaults.Count-1 do
        Require(not (Defaults[I].Tag in [COL_TRANSLATORS,COL_CITY,COL_PUBYEAR,COL_ISBN]),
          'New metadata columns changed the default visible layout');
    end;
    Writeln('PASS metadata columns actual header menus expose four new IDs once and preserve default layouts');
    MBCFixtures(Collection,IDs,GroupID);
    MBCAssertFreshGroup(Collection,IDs[0],GroupID);
    MBCAssertGroupGuardsAndBatches;
    Reopened:=TBookCollection_SQLite.Create(SystemDB.GetCollectionInfo(Collection.CollectionID),SystemDB);
    for var I:=0 to High(Trees) do
    begin
      Tree:=Trees[I]; Settings.TreeModes[Tree.Tag]:=tmFlat; MBCEnsureColumns(Tree);
      MBCFill(Tree,Reopened,IDs,GroupID); MBCAssertRows(Tree,IDs); MBCAssertFilters(Tree); MBCAssertSort(Tree,IDs);
      MBCAssertLayout(Tree,Sections[I],tmFlat);
      if Tree.Tag in [PAGE_AUTHORS,PAGE_GENRES,PAGE_FAVORITES,PAGE_SEARCH] then
      begin
        Settings.TreeModes[Tree.Tag]:=tmTree;
        MBCFill(Tree,Reopened,IDs,GroupID); MBCAssertRows(Tree,IDs); MBCAssertFilters(Tree);
        MBCAssertLayout(Tree,TreeSections[I],tmTree);
      end;
    end;
    Writeln('PASS metadata columns DAO-backed rows render publisher translators city year ISBN in all six book lists and groups');
    Writeln('PASS metadata columns numeric year order empty Unicode yo exact and combined filters on flat and grouped lists');
    Writeln('PASS metadata columns saved order width visibility survive fresh column stores and actual Main header reconstruction');
    Tree:=Trees[0]; Settings.TreeModes[Tree.Tag]:=tmFlat; MBCActivate(Tree); MBCFill(Tree,Collection,IDs,GroupID);
    MBCAssertEditors(Tree);
    Writeln('PASS metadata columns numeric and checklist editors apply cancel and missing-year choices in both themes'); Flush(Output);
  finally
    Reopened:=nil; Defaults.Free;
    for var I:=0 to High(Trees) do Settings.TreeModes[Trees[I].Tag]:=SavedModes[I];
    Settings.CheckUpdate:=SavedApp; Settings.CheckExternalLibUpdate:=SavedCatalog;
  end;
end;

type
  TMetadataColumnsVisualControl = class(TForm)
  public
    Finished: Boolean;
    procedure ThemeClicked(Sender: TObject);
    procedure DoneClicked(Sender: TObject);
    procedure Closing(Sender: TObject; var Action: TCloseAction);
  end;

procedure TMetadataColumnsVisualControl.ThemeClicked(Sender: TObject);
begin SetMHLTheme(TButton(Sender).Tag<>0); end;
procedure TMetadataColumnsVisualControl.DoneClicked(Sender: TObject);
begin Close; end;
procedure TMetadataColumnsVisualControl.Closing(Sender: TObject; var Action: TCloseAction);
begin Finished:=True; Action:=caHide; end;

procedure TestMetadataBookColumnsVisual(const Collection: IBookCollection);
var Tree: TBookTree; IDs: TArray<Integer>; GroupID: Integer; Control: TMetadataColumnsVisualControl;
  LabelControl: TLabel; Button: TButton; SavedTheme, SavedApp, SavedCatalog: Boolean; SavedCaption: string;
begin
  RequireIsolatedRegression; SavedTheme:=MHLThemeDark; SavedCaption:=frmMain.Caption;
  SavedApp:=Settings.CheckUpdate; SavedCatalog:=Settings.CheckExternalLibUpdate;
  Settings.CheckUpdate:=False; Settings.CheckExternalLibUpdate:=False; Control:=nil;
  try
    MBCFixtures(Collection,IDs,GroupID); Tree:=frmMain.tvBooksA; Settings.TreeModes[Tree.Tag]:=tmFlat;
    MBCEnsureColumns(Tree); MBCFill(Tree,Collection,IDs,GroupID);
    for var Item in frmMain.pmHeaders.Items do
      if (Item.Tag>=COL_TITLE) and (Item.Tag<=COL_ISBN) and
        not (Item.Tag in [COL_TITLE,COL_PUBLISHER,COL_TRANSLATORS,COL_CITY,COL_PUBYEAR,COL_ISBN]) and
        (MBCColumn(Tree,Item.Tag)>=0) then
      begin MBCRefreshMenu; Item.OnClick(Item); end;
    Tree.Header.Columns[MBCColumn(Tree,COL_TITLE)].Width:=180;
    for var I:=0 to High(MBCColumnTags) do
    begin
      Tree.Header.Columns[MBCColumn(Tree,MBCColumnTags[I])].Position:=I+2;
      Tree.Header.Columns[MBCColumn(Tree,MBCColumnTags[I])].Width:=180;
    end;
    Tree.Header.Columns[MBCColumn(Tree,COL_TRANSLATORS)].Width:=230;
    Tree.Header.Columns[MBCColumn(Tree,COL_PUBYEAR)].Width:=110;
    frmMain.Caption:='HomeLib Ru — колонки сведений, изолированный ручной стенд'; frmMain.Show;
    Control:=TMetadataColumnsVisualControl.CreateNew(nil); Control.Caption:='Колонки сведений — управление стендом';
    Control.BorderStyle:=bsToolWindow; Control.Position:=poDesigned;
    Control.SetBounds(Screen.WorkAreaRect.Left+24,Screen.WorkAreaRect.Top+24,460,150);
    Control.PopupParent:=frmMain; Control.PopupMode:=pmExplicit; Control.OnClose:=Control.Closing;
    LabelControl:=TLabel.Create(Control); LabelControl.Parent:=Control; LabelControl.AutoSize:=False;
    LabelControl.SetBounds(10,8,430,58); LabelControl.WordWrap:=True;
    LabelControl.Caption:='В главном окне: меню заголовков, перетаскивание и ширина столбцов, сортировка и фильтры. '+
      'Проверьте пустую строку и годы 9 / 10 / 2001. Завершение — кнопкой ниже; таймера закрытия нет.';
    for var I:=0 to 2 do
    begin
      Button:=TButton.Create(Control); Button.Parent:=Control; Button.SetBounds(10+I*145,76,135,30);
      if I<2 then
      begin
        if I=0 then Button.Caption:='Светлая тема' else Button.Caption:='Тёмная тема';
        Button.Tag:=I; Button.OnClick:=Control.ThemeClicked;
      end
      else begin Button.Caption:='Завершить осмотр'; Button.OnClick:=Control.DoneClicked; end;
    end;
    Control.Show; Writeln('VISUAL metadata columns: inspect actual Main; own control window switches light/dark and closes explicitly'); Flush(Output);
    repeat Application.ProcessMessages; CheckSynchronize(0); TThread.Sleep(10);
    until Control.Finished or Application.Terminated;
    Writeln('PASS metadata columns visual fixture closed explicitly'); Flush(Output);
  finally
    Control.Free; frmMain.Caption:=SavedCaption; frmMain.Hide; SetMHLTheme(SavedTheme);
    Settings.CheckUpdate:=SavedApp; Settings.CheckExternalLibUpdate:=SavedCatalog;
  end;
end;
