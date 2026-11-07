type
  TSelectorDeletionProbe = class(TGroupedDeletionProbe)
    SavedModal:TNotifyEvent;
    CancelPreparation:Boolean;
    Preparations:Integer;
    procedure ModalBegin(Sender:TObject);
  end;

procedure TSelectorDeletionProbe.ModalBegin(Sender:TObject);
begin
  if Assigned(SavedModal) then SavedModal(Sender);
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Name='BookDeletionSelection' then
    begin
      Inc(Preparations);
      if CancelPreparation then
        TButton(Screen.Forms[I].FindComponent('btnCancel')).Click;
      Exit;
    end;
end;

procedure TestSelectorBookDeletion;
var Root:string; CID,OtherID,OnlineID:Integer; C,Other,Online:IBookCollection;
  A,B,Joint,Keep,Foreign,CycleBook,CycleOther,Imprint,SameCycle,LocalOnline,RemoteOnline:TBookRecord;
  Probe:TSelectorDeletionProbe; Menu:TMenuItem; SavedHide,SavedDelete,SavedDialogs:Boolean;
  function Add(const Collection:IBookCollection; const Token,Author,Series,Lang:string;
    Local,Deleted:Boolean; const SecondAuthor:string=''; const Folder:string=''; const Member:string=''):TBookRecord;
  var Book:TBookRecord; ID:Integer;
  begin
    Book.Clear; Book.Title:=Token; Book.LibID:=Token; Book.FileName:=Token;
    Book.FileExt:='.fb2'; Book.Folder:=Folder; Book.Series:=Series; Book.Lang:=Lang;
    if Member<>'' then Book.FileName:=Member;
    if Local then Include(Book.BookProps,bpIsLocal);
    if Deleted then Include(Book.BookProps,bpIsDeleted);
    TAuthorsHelper.Add(Book.Authors,Author,'','');
    if SecondAuthor<>'' then TAuthorsHelper.Add(Book.Authors,SecondAuthor,'','');
    TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
    ID:=Collection.InsertBook(Book,False,False);
    Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Result,False);
    if Folder='' then TFile.WriteAllText(Result.GetBookFileName,'Owned selector source '+Token,TEncoding.UTF8);
  end;
  function Scalar(const Collection:IBookCollection; const SQL:string; const Values:array of const):Integer;
  var DB:TSQLiteDatabase;
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(Collection.CollectionID).DBFileName);
    try Result:=DB.QuerySingleInt(SQL,Values); finally DB.Free; end;
  end;
  function Exists(const Collection:IBookCollection; const Book:TBookRecord):Boolean;
  begin Result:=Scalar(Collection,'SELECT count(*) FROM Books WHERE BookID=?',[Book.BookKey.BookID])=1; end;
  procedure SelectAuthors(const Collection:IBookCollection; const Names:array of string);
  var Node:PVirtualNode; Data:PAuthorData; Found:Integer;
  begin
    ShowPage(PAGE_AUTHORS);
    FillAuthorTree(frmMain.tvAuthors,Collection.GetAuthorIterator(amAll),
      Scalar(Collection,'SELECT AuthorID FROM Authors WHERE LastName=?',[Names[0]]));
    frmMain.tvAuthors.ClearSelection; Found:=0; Node:=frmMain.tvAuthors.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvAuthors.GetNodeData(Node);
      for var Name in Names do if Assigned(Data) and (Data^.LastName=Name) then
      begin frmMain.tvAuthors.Selected[Node]:=True; Inc(Found); end;
      Node:=frmMain.tvAuthors.GetNext(Node);
    end;
    Require(Found=Length(Names),'Cannot select exact fixture authors');
  end;
  procedure SelectSeries(Publisher:Boolean; const Name:string);
  begin
    if Publisher then
    begin
      frmMain.pgControl.ActivePage:=PublisherView.Tab;
      FillSeriesTree(PublisherView.SeriesTree,C.GetPublisherSeriesIterator,
        Scalar(C,'SELECT SeriesID FROM PublisherSeries WHERE SeriesTitle=?',[Name]));
    end
    else
    begin
      ShowPage(PAGE_SERIES);
      FillSeriesTree(frmMain.tvSeries,C.GetSeriesIterator(smAll),
        Scalar(C,'SELECT SeriesID FROM Series WHERE SeriesTitle=?',[Name]));
    end;
  end;
  procedure Execute(const Scope:string; Count,ExpectedConfirmations,ExpectedWarnings:Integer;
    Accept,Files:Boolean);
  var Started:UInt64; Progress:TComponent;
  begin
    Application.ProcessMessages;
    frmMain.pmAuthorPopup(frmMain.pmAuthor);
    Require(Menu.Visible and Menu.Enabled,'Selector context menu did not expose the command');
    Probe.ExpectedCount:=Count; Probe.ExpectedCollections:=1; Probe.Accept:=Accept; Probe.FileChoice:=Ord(Files);
    Probe.Confirmations:=0; Probe.Warnings:=0; Probe.Preparations:=0; Probe.Failure:=''; Probe.LastConfirmation:='';
    Vcl.Dialogs.UseLatestCommonDialogs:=False; Probe.Timer.Enabled:=True;
    try
      Menu.Click; Progress:=frmMain.FindComponent('BookDeletionProgress'); Started:=GetTickCount64;
      while Assigned(frmMain.FindComponent('BookDeletionProgress')) do
      begin
        Require(frmMain.Enabled and (frmMain.FindComponent('BookDeletionProgress')=Progress),
          'Selector deletion did not use one non-blocking progress window');
        Application.ProcessMessages;
        if GetTickCount64-Started>30000 then raise Exception.Create('Selector deletion exceeded deadline');
        Sleep(5);
      end;
      Require((Probe.Preparations=1) and (Probe.Confirmations=ExpectedConfirmations) and
        (Probe.Warnings=ExpectedWarnings),'Unexpected selector deletion flow: '+Probe.Failure);
      if Scope<>'' then Require(Probe.LastConfirmation.Contains(Scope),'Confirmation omitted author or series scope');
      if ExpectedWarnings=0 then Require(Probe.Failure='',Probe.Failure);
    finally Probe.Timer.Enabled:=False; end;
  end;
begin
  RequireIsolatedRegression; Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'selector-deletion'); ForceDirectories(Root);
  CID:=SystemDB.CreateCollection('Selector safety local',Root,Root+'local.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  OtherID:=SystemDB.CreateCollection('Selector safety foreign',Root,Root+'foreign.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  OnlineID:=SystemDB.CreateCollection('Selector safety online',Root,Root+'online.hlc2',CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst');
  C:=SystemDB.GetCollection(CID); Other:=SystemDB.GetCollection(OtherID); Online:=SystemDB.GetCollection(OnlineID);
  A:=Add(C,'author-a-ru','Scope Author A','','ru',True,False);
  B:=Add(C,'author-b-en','Scope Author A','','en',True,False);
  Joint:=Add(C,'author-joint-hidden','Scope Author A','','ru',False,True,'Scope Author B');
  Keep:=Add(C,'keep-other-author','Scope Other','','ru',True,False);
  Foreign:=Add(Other,'keep-other-collection','Scope Author A','','ru',True,False);
  Require(A.BookKey.BookID=Foreign.BookKey.BookID,'Fixture lacks same ID in another collection');
  var Zip:=TZipFile.Create;
  try
    Zip.Open(Root+'selector-cycle.zip',zmWrite);
    for var Name in ['chosen.fb2','neighbour.fb2'] do
    begin
      var Text:=TStringStream.Create('Owned '+Name+' — ё',TEncoding.UTF8);
      try Zip.Add(Text,Name); finally Text.Free; end;
    end;
  finally Zip.Free; end;
  CycleBook:=Add(C,'cycle-selected','Scope Other','Scope Cycle','ru',True,False,'','selector-cycle.zip','chosen');
  CycleOther:=Add(C,'cycle-neighbour','Scope Other','Scope Other Cycle','ru',True,False,'','selector-cycle.zip','neighbour');
  C.SetReview(CycleOther.BookKey,'Keep cycle note — ё');
  Imprint:=Add(C,'imprint-selected','Scope Other','Different cycle','ru',True,False);
  SameCycle:=Add(C,'imprint-name-as-cycle','Scope Other','Scope Imprint','ru',True,False);
  var Series:TBookSeries; TSeriesHelper.Add(Series,0,'Scope Imprint',1,True); C.SetBookPublisherSeries(Imprint.BookKey,Series);
  LocalOnline:=Add(Online,'online-downloaded','Scope Online Author','','ru',True,False);
  RemoteOnline:=Add(Online,'online-unavailable','Scope Online Author','','en',False,False);
  // The intentionally unavailable record has no downloaded file, although
  // its catalogue locator is stable and can be used by the reader later.
  TFile.Delete(RemoteOnline.GetBookFileName);
  Online.SetReview(LocalOnline.BookKey,'Keep online note — ё');
  var SourceHash:=THashSHA2.GetHashStringFromFile(A.GetBookFileName);
  var ZipHash:=THashSHA2.GetHashStringFromFile(CycleBook.GetBookFileName);
  SavedHide:=Settings.HideDeletedBooks; SavedDelete:=Settings.DeleteFiles; SavedDialogs:=Vcl.Dialogs.UseLatestCommonDialogs;
  Probe:=TSelectorDeletionProbe.Create; Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=15; Probe.Timer.OnTimer:=Probe.Tick;
  Probe.SavedModal:=Application.OnModalBegin;
  try
    Settings.HideDeletedBooks:=True; Settings.DeleteFiles:=False;
    FreeAndNil(frmMain); Settings.ActiveCollection:=CID; Settings.ActivePage:=PAGE_AUTHORS;
    Application.CreateForm(TfrmMain,frmMain); Application.OnModalBegin:=Probe.ModalBegin;
    Menu:=TMenuItem(frmMain.FindComponent('miDeleteSelectorBooks')); Require(Assigned(Menu),'Selector action is missing');
    SelectAuthors(C,['Scope Author A']); Probe.CancelPreparation:=True;
    Execute('',0,0,0,True,True); Probe.CancelPreparation:=False;
    Require(Exists(C,A) and Exists(C,B) and Exists(C,Joint),'Preparation cancel changed records');
    Execute('включая соавторство',3,1,0,False,True);
    Require(Exists(C,A) and Exists(C,B) and Exists(C,Joint),'Confirmation cancel changed records');
    var Data:=PAuthorData(frmMain.tvAuthors.GetNodeData(frmMain.tvAuthors.GetFirstSelected));
    var Name:=Data^.LastName; Data^.LastName:='A stale selector name';
    try Execute('',0,0,1,True,True); finally Data^.LastName:=Name; end;
    Require(Exists(C,A) and Exists(C,B) and Exists(C,Joint),'Stale selector name removed books');
    Execute('Фильтры списка не ограничивают выбор',3,1,0,True,False);
    Require(not Exists(C,A) and not Exists(C,B) and not Exists(C,Joint) and Exists(C,Keep) and Exists(Other,Foreign),
      'Author removal lost hidden/other-language books, deduplication or source scope');
    Require(THashSHA2.GetHashStringFromFile(A.GetBookFileName)=SourceHash,'Author record-only choice changed a file');
    SelectSeries(False,'Scope Cycle');
    Probe.BeforeAccept:=procedure
      begin C.SetReview(Keep.BookKey,'Concurrent catalogue edit'); end;
    Execute('Серии: Scope Cycle',1,1,1,True,True);
    Require(Exists(C,CycleBook) and (THashSHA2.GetHashStringFromFile(CycleBook.GetBookFileName)=ZipHash),
      'Catalogue revision change while confirming did not abort the plan');
    Execute('Серии: Scope Cycle',1,1,0,True,True);
    Require(not Exists(C,CycleBook) and Exists(C,CycleOther) and
      (C.GetReview(CycleOther.BookKey)='Keep cycle note — ё'),'Series removal lost the wrong row or note');
    Zip:=TZipFile.Create;
    try
      Zip.Open(CycleOther.GetBookFileName,zmRead); Require((Zip.FileCount=1) and (Zip.FileNames[0]='neighbour.fb2'),
        'Series deletion changed an unselected archive entry');
      var DataBytes:TBytes; Zip.Read('neighbour.fb2',DataBytes);
      Require(TEncoding.UTF8.GetString(DataBytes)='Owned neighbour.fb2 — ё','Series deletion changed neighbour bytes');
    finally Zip.Free; end;
    SelectSeries(True,'Scope Imprint'); Execute('Книжные серии: Scope Imprint',1,1,0,True,False);
    Require(not Exists(C,Imprint) and Exists(C,SameCycle),'Publisher series deletion was confused with a same-name cycle');
    ShowPage(PAGE_GENRES); frmMain.pmAuthorPopup(frmMain.pmAuthor);
    Require(not Menu.Visible,'Genre selector exposes unrelated deletion command');
    ChangeCollection(OnlineID); SelectAuthors(Online,['Scope Online Author']);
    Execute('Только загруженные книги',1,1,0,True,False);
    Require(Exists(Online,LocalOnline) and Exists(Online,RemoteOnline) and not FileExists(LocalOnline.GetBookFileName) and
      (Online.GetReview(LocalOnline.BookKey)='Keep online note — ё'),'Online selector deletion lost a record or note');
    Require(Settings.HideDeletedBooks and not Settings.DeleteFiles,'Selector operation changed view or file preferences');
    Writeln('PASS selector menu deletion covers authors all languages coauthors series publisher scopes online downloads and cancellation');
  finally
    Application.OnModalBegin:=Probe.SavedModal; Probe.Timer.Free; Probe.Free;
    Settings.HideDeletedBooks:=SavedHide; Settings.DeleteFiles:=SavedDelete; Vcl.Dialogs.UseLatestCommonDialogs:=SavedDialogs;
    Online:=nil; Other:=nil; C:=nil;
  end;
end;
