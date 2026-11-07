type
  TGroupedDeletionProbe = class
    Timer:TTimer;
    Accept:Boolean;
    FileChoice,ExpectedCount,ExpectedCollections,Confirmations,Warnings:Integer;
    Failure,LastConfirmation:string;
    BeforeAccept:TProc;
    procedure Tick(Sender:TObject);
  end;

procedure TGroupedDeletionProbe.Tick(Sender:TObject);
begin
  for var I:=Screen.FormCount-1 downto 0 do
  begin
    var Dialog:=Screen.Forms[I];
    if not Dialog.Visible then Continue;
    if Dialog.Name='BookDeletionConfirmation' then
    begin
      try
        Inc(Confirmations);
        var Text:=GBIComponentText(Dialog); LastConfirmation:=Text;
        Require(Text.Contains('Выбрано книг: '+IntToStr(ExpectedCount)),
          'Group deletion omitted its exact unique book count');
        if ExpectedCollections>1 then
        begin
          Require(Text.Contains('коллекций: '+IntToStr(ExpectedCollections)),
            'Group deletion omitted its collection count');
          Require(Assigned(Dialog.FindComponent('DeleteCollectionTitle0')) and
            Assigned(Dialog.FindComponent('DeleteCollectionTitle1')),
            'Group deletion does not identify each source collection');
        end;
        var SafeDefault:=False;
        for var Component in Dialog do
        begin
          if (Component is TButton) and TButton(Component).Default then
            SafeDefault:=TButton(Component).ModalResult=mrNo;
          if (Component is TCheckBox) and TCheckBox(Component).Enabled and
            string(Component.Name).StartsWith('DeleteBookSourceFiles') and (FileChoice>=0) then
            TCheckBox(Component).Checked:=FileChoice=1;
        end;
        Require(SafeDefault,'Group deletion confirmation defaults to removal');
        if Accept and Assigned(BeforeAccept) then begin BeforeAccept(); BeforeAccept:=nil; end;
        if Accept then Dialog.ModalResult:=mrYes else Dialog.ModalResult:=mrNo;
      except
        on E:Exception do begin Failure:=E.Message; Dialog.ModalResult:=mrCancel; end;
      end;
      Exit;
    end;
    if Dialog.ClassName='TMessageForm' then
    begin
      Inc(Warnings); Failure:=GBIComponentText(Dialog); Dialog.ModalResult:=mrOk; Exit;
    end;
  end;
end;

procedure TestGroupedBookDeletion;
var Root:string; IDs:array[0..2] of Integer; Collections:array[0..2] of IBookCollection;
  Selected,Neighbours:array[0..2] of TBookRecord; Paths,Hashes:array[0..2] of string;
  GroupID:Integer; Probe:TGroupedDeletionProbe; SavedDelete,SavedSelection,SavedDialogs:Boolean;
  procedure Source(Index,CaseNo:Integer; Zipped:Boolean);
  var Book:TBookRecord; FileName:string;
    function Insert(const Name:string):TBookRecord;
    begin
      Book.Clear; Book.Title:=Format('Group case %d collection %d %s',[CaseNo,Index,Name]);
      Book.LibID:=Book.Title; Book.FileName:=Name; Book.FileExt:='.fb2'; Book.Lang:='ru';
      if Zipped then Book.Folder:=FileName else Book.FileName:=FileName+'-'+Name;
      Include(Book.BookProps,bpIsLocal); TAuthorsHelper.Add(Book.Authors,'Group author','','');
      TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
      var ID:=Collections[Index].InsertBook(Book,False,False);
      Collections[Index].GetBookRecord(CreateBookKey(ID,IDs[Index]),Result,False);
    end;
  begin
    FileName:=Format('group-%d-%d',[CaseNo,Index]); if Zipped then FileName:=FileName+'.zip';
    Selected[Index]:=Insert('chosen'); Neighbours[Index]:=Insert('neighbour');
    if Zipped then
    begin
      var Zip:=TZipFile.Create;
      try
        Zip.Open(Root+FileName,zmWrite);
        for var Name in ['chosen.fb2','neighbour.fb2'] do
        begin
          var Text:=TStringStream.Create('Owned '+Name+' — ё',TEncoding.UTF8);
          try Zip.Add(Text,Name); finally Text.Free; end;
        end;
      finally Zip.Free; end;
    end
    else
      for var Value in TArray<TBookRecord>.Create(Selected[Index],Neighbours[Index]) do
        TFile.WriteAllText(Value.GetBookFileName,'Owned '+Value.Title,TEncoding.UTF8);
    Paths[Index]:=Selected[Index].GetBookFileName;
    Hashes[Index]:=THashSHA2.GetHashStringFromFile(Paths[Index]);
    Collections[Index].SetReview(Neighbours[Index].BookKey,'Keep group neighbour note — ё');
    Collections[Index].AddBookToGroup(Selected[Index].BookKey,GroupID);
    Collections[Index].AddBookToGroup(Neighbours[Index].BookKey,GroupID);
  end;
  function Exists(const Book:TBookRecord):Boolean;
  var DB:TSQLiteDatabase;
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(Book.BookKey.DatabaseID).DBFileName);
    try Result:=DB.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[Book.BookKey.BookID])=1;
    finally DB.Free; end;
  end;
  procedure LoadGroup(const Indices:array of Integer);
  var Node,Focus:PVirtualNode; Data:PBookRecord; Count:Integer;
  begin
    ShowPage(PAGE_FAVORITES);
    FillGroupsList(frmMain.tvGroups,SystemDB.GetGroupIterator,GroupID);
    frmMain.tvGroupsChange(frmMain.tvGroups,frmMain.tvGroups.GetFirstSelected);
    Node:=frmMain.tvBooksF.GetFirst; Focus:=nil; Count:=0; frmMain.tvBooksF.ClearSelection;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvBooksF.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) then
      begin
        frmMain.tvBooksF.CheckState[Node]:=csUncheckedNormal;
        for var I in Indices do
          if Data^.BookKey.IsSameAs(Selected[I].BookKey) then
          begin frmMain.tvBooksF.CheckState[Node]:=csCheckedNormal; Inc(Count); end
          else if Data^.BookKey.IsSameAs(Neighbours[I].BookKey) then Focus:=Node;
      end;
      Node:=frmMain.tvBooksF.GetNext(Node);
    end;
    frmMain.tvBooksF.FocusedNode:=Focus;
    Require(Count=Length(Indices),'Ordinary group view did not load the selected source books');
    frmMain.acBookDelete.Update;
    Require(frmMain.N74.Visible and frmMain.tbtnDeleteBook.Visible,'Group view hides the ordinary deletion action');
    Require(string(frmMain.acBookDelete.Caption).Contains('исходных коллекций'),
      'Group deletion action can be confused with removing a group link');
  end;
  procedure Execute(Accept,OnlyFiles:Boolean; Count,CollectionCount:Integer; ExpectedWarnings:Integer=0);
  var Progress:TComponent; Started:UInt64;
  begin
    Probe.Accept:=Accept; Probe.ExpectedCount:=Count; Probe.ExpectedCollections:=CollectionCount;
    Probe.Confirmations:=0; Probe.Warnings:=0; Probe.Failure:=''; Probe.Timer.Enabled:=True;
    try
      if OnlyFiles then frmMain.miDeleteFilesClick(nil) else frmMain.N74.Click;
      Progress:=frmMain.FindComponent('BookDeletionProgress'); Started:=GetTickCount64;
      while Assigned(frmMain.FindComponent('BookDeletionProgress')) do
      begin
        Require(frmMain.Enabled,'Grouped deletion disabled the catalogue');
        Require(frmMain.FindComponent('BookDeletionProgress')=Progress,'One grouped operation replaced its progress window');
        Application.ProcessMessages;
        if GetTickCount64-Started>30000 then raise Exception.Create('Grouped Main deletion exceeded deadline');
        Sleep(5);
      end;
      Require(Probe.Confirmations=1,'Grouped deletion did not ask exactly once');
      Require(Probe.Warnings=ExpectedWarnings,'Unexpected grouped deletion warning: '+Probe.Failure);
      if ExpectedWarnings=0 then Require(Probe.Failure='',Probe.Failure);
    finally Probe.Timer.Enabled:=False; end;
  end;
  procedure Retained(Index:Integer; Zipped,Removed:Boolean);
  begin
    Require(Exists(Neighbours[Index]) and
      (Collections[Index].GetReview(Neighbours[Index].BookKey)='Keep group neighbour note — ё'),
      'Group operation lost a neighbouring row or note');
    if not Zipped or not Removed then
      Require(THashSHA2.GetHashStringFromFile(Paths[Index])=Hashes[Index],'Group operation changed a retained source')
    else
    begin
      var Zip:=TZipFile.Create;
      try
        Zip.Open(Paths[Index],zmRead); Require((Zip.FileCount=1) and (Zip.FileNames[0]='neighbour.fb2'),
          'Group operation changed the wrong archive member');
        var Data:TBytes; Zip.Read('neighbour.fb2',Data);
        Require(TEncoding.UTF8.GetString(Data)='Owned neighbour.fb2 — ё','Group operation damaged neighbour bytes');
      finally Zip.Free; end;
    end;
  end;
begin
  RequireIsolatedRegression; Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'group-deletion'); ForceDirectories(Root);
  Require(SystemDB.AddGroup('Owned group deletion'),'Cannot create isolated group');
  GroupID:=0; var Groups:=SystemDB.GetGroupIterator; var Group:TGroupData;
  while Groups.Next(Group) do if Group.Text='Owned group deletion' then GroupID:=Group.GroupID;
  Groups:=nil; Require(GroupID>0,'Isolated group is absent');
  for var I:=0 to 2 do
  begin
    var Kind:=CT_EXTERNAL_LOCAL_FB; if I=2 then Kind:=CT_EXTERNAL_ONLINE_FB;
    IDs[I]:=SystemDB.CreateCollection('Owned group source '+IntToStr(I),Root,Root+'catalog'+IntToStr(I)+'.hlc2',
      Kind,Settings.AppPath+'genres_fb2.glst');
    Collections[I]:=SystemDB.GetCollection(IDs[I]);
  end;
  SavedDelete:=Settings.DeleteFiles; SavedSelection:=Settings.SelectedIsChecked;
  SavedDialogs:=Vcl.Dialogs.UseLatestCommonDialogs;
  Probe:=TGroupedDeletionProbe.Create; Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=15; Probe.Timer.OnTimer:=Probe.Tick;
  try
    Settings.SelectedIsChecked:=False; Settings.DeleteFiles:=False;
    FreeAndNil(frmMain); Settings.ActiveCollection:=IDs[0]; Settings.ActivePage:=PAGE_FAVORITES;
    Application.CreateForm(TfrmMain,frmMain); Vcl.Dialogs.UseLatestCommonDialogs:=False;
    Source(0,1,False); Source(1,1,False); LoadGroup([0,1]); Probe.FileChoice:=1;
    Execute(False,False,2,2);
    Require(Exists(Selected[0]) and Exists(Selected[1]),'Cancel removed group records');
    Retained(0,False,False); Retained(1,False,False);
    Probe.FileChoice:=0; Execute(True,False,2,2);
    Require(not Exists(Selected[0]) and not Exists(Selected[1]),'Group record-only removal did not reach both source collections');
    Retained(0,False,False); Retained(1,False,False);
    SystemDB.ClearGroup(GroupID); Source(0,2,True); Source(1,2,True); LoadGroup([0,1]);
    Probe.FileChoice:=1; Execute(True,False,2,2);
    Require(not Exists(Selected[0]) and not Exists(Selected[1]),'Grouped archive removal left selected records');
    Retained(0,True,True); Retained(1,True,True);
    SystemDB.ClearGroup(GroupID); Source(0,3,True); Source(1,3,True); LoadGroup([0,1]);
    Execute(True,True,2,2);
    Require(Exists(Selected[0]) and Exists(Selected[1]),'Files-only grouped command removed catalogue records');
    for var I:=0 to 1 do
    begin
      var Stored:TBookRecord; Collections[I].GetBookRecord(Selected[I].BookKey,Stored,False);
      Require(not (bpIsLocal in Stored.BookProps),'Files-only grouped deletion retained local availability');
      Retained(I,True,True);
    end;
    SystemDB.ClearGroup(GroupID); Source(0,4,False); Source(2,4,False); LoadGroup([0,2]);
    Probe.FileChoice:=0; Execute(True,False,2,2);
    Require(not Exists(Selected[0]) and Exists(Selected[2]) and not FileExists(Paths[2]),
      'Mixed local/online group did not preserve the online record and explicit local file choice');
    Retained(0,False,False);
    Require(FileExists(Neighbours[2].GetBookFileName) and Exists(Neighbours[2]),'Online grouped removal touched an unmarked focused neighbour');
    SystemDB.ClearGroup(GroupID); Source(0,5,False); Source(1,5,False); LoadGroup([0,1]);
    Probe.BeforeAccept:=procedure
      begin var Changed:=Selected[1]; Changed.LibID:='replacement after prompt'; Collections[1].UpdateBook(Changed); end;
    Probe.FileChoice:=1; Execute(True,False,2,2,1);
    Require(Exists(Selected[0]) and Exists(Selected[1]),'Stale second source allowed partial first-collection deletion');
    Retained(0,False,False); Retained(1,False,False);
    Require(not Settings.DeleteFiles,'Grouped confirmation changed the global deletion preference');
    GroupID:=FAVORITES_GROUP_ID; Source(0,6,False); LoadGroup([0]); Probe.FileChoice:=0;
    Execute(True,False,1,1);
    Require(not Exists(Selected[0]),'Built-in Favorites did not use the source-collection deletion action');
    Retained(0,False,False);
    ShowPage(PAGE_AUTHORS); frmMain.acBookDelete.Update;
    Require(not string(frmMain.acBookDelete.Caption).Contains('исходных коллекций'),
      'Leaving Groups did not restore the ordinary delete caption');
    Writeln('PASS ordinary Groups deletion confirms source collections once and preserves cancel file choices online records neighbours and stale identities');
  finally
    Probe.Timer.Free; Probe.Free; Settings.DeleteFiles:=SavedDelete; Settings.SelectedIsChecked:=SavedSelection;
    Vcl.Dialogs.UseLatestCommonDialogs:=SavedDialogs;
    for var I:=0 to 2 do Collections[I]:=nil;
  end;
end;
