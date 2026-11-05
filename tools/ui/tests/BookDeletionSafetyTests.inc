type
  TBookDeletionDialogProbe = class
    Timer: TTimer;
    Accept: Boolean;
    Confirmations, Warnings: Integer;
    ExpectedCount, ExpectedArchives: Integer;
    Failure, LastConfirmation: string;
    BeforeAccept: TProc;
    procedure Tick(Sender: TObject);
  end;

procedure TBookDeletionDialogProbe.Tick(Sender: TObject);
var Form: TForm; Text: string; DefaultNo: Boolean;
begin
  for var I := Screen.FormCount - 1 downto 0 do
  begin
    Form := Screen.Forms[I];
    if not Form.Visible or (Form.ClassName <> 'TMessageForm') then Continue;
    Text := GBIComponentText(Form);
    try
      if Text.Contains('Выбрано книг:') then
      begin
        Inc(Confirmations); LastConfirmation := Text;
        Require(Text.Contains('Коллекция: Delete safety'), 'Deletion omitted its collection');
        Require(Text.Contains('Выбрано книг: '+IntToStr(ExpectedCount)), 'Deletion counted repeated series rows as separate books');
        if ExpectedArchives > 0 then
          Require(Text.Contains('Книг в архивах: '+IntToStr(ExpectedArchives)) and
            Text.Contains('ZIP и 7z не удаляются'), 'Deletion hid its archive-preservation policy');
        DefaultNo := False;
        for var J := 0 to Form.ComponentCount - 1 do
          if Form.Components[J] is TButton then
            if TButton(Form.Components[J]).Default then
              DefaultNo := TButton(Form.Components[J]).ModalResult = mrNo;
        Require(DefaultNo, 'Destructive confirmation must default to No');
        if Accept and Assigned(BeforeAccept) then begin BeforeAccept(); BeforeAccept := nil; end;
        if Accept then Form.ModalResult := mrYes else Form.ModalResult := mrNo;
      end
      else if Text.Contains('Не удалось полностью обработать книг:') then
      begin Inc(Warnings); Form.ModalResult := mrOk; end
      else raise Exception.Create('Unexpected deletion dialog: '+Text);
    except
      on E: Exception do begin Failure := E.Message; Form.ModalResult := mrCancel; end;
    end;
    Exit;
  end;
end;

procedure TestBookDeletionSafety;
var PrivateID, OnlineID, ExternalID, RawID, ArchiveID, OtherID, PrivateFBD, FailID, GoodID,
  SevenID, LegacyID, NeighbourID, Count: Integer;
  Collection: IBookCollection; Probe: TBookDeletionDialogProbe;
  Root, RawPath, ArchivePath, BeforeRaw, BeforeArchive, OldTemp, OldTmp: string;
  SavedDelete, SavedSelection, SavedDialogs: Boolean; Book, Other: TBookRecord;
  Tree: TBookTree; DB: TSQLiteDatabase; Locked: TFileStream;

  function XML(const Title: string): string;
  begin Result := '<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
    '<description><title-info><book-title>'+Title+'</book-title><lang>ru</lang></title-info></description>'+
    '<body><section><p>Книга для проверки удаления — ё.</p></section></body></FictionBook>'; end;

  procedure WriteZip(const Name: string);
  var Zip: TZipFile; Stream: TBytesStream;
  begin
    Zip := TZipFile.Create;
    try
      Zip.Open(Name,zmWrite);
      for var Entry in ['chosen.fb2','unselected.fb2'] do
      begin
        Stream := TBytesStream.Create(TEncoding.UTF8.GetBytes(XML(Entry)));
        try Zip.Add(Stream,Entry); finally Stream.Free; end;
      end;
    finally Zip.Free; end;
  end;

  function Insert(const Title, Folder, FileName, Ext: string): Integer;
  begin
    Book.Clear; Book.Title := Title; Book.Folder := Folder; Book.FileName := FileName;
    Book.FileExt := Ext; Book.LibID := Title; Book.Lang := 'ru'; Book.Size := 100;
    Book.Series := 'Delete series'; Book.Publisher := 'Delete publisher';
    Include(Book.BookProps,bpIsLocal); TAuthorsHelper.Add(Book.Authors,'Delete author','Alex','');
    TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
    Result := Collection.InsertBook(Book,False,False); Require(Result>0,'Deletion fixture insert failed');
  end;

  function Exists(ID: Integer): Boolean;
  var Query: TSQLiteDatabase;
  begin
    Query := TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(Collection.CollectionID).DBFileName);
    try Result := Query.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE BookID='+IntToStr(ID))=1;
    finally Query.Free; end;
  end;

  function Local(ID: Integer): Boolean;
  var Stored: TBookRecord;
  begin Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Stored,False);
    Result := bpIsLocal in Stored.BookProps; end;

  procedure AddRow(ID: Integer; Checked: Boolean; Parent: PVirtualNode = nil);
  var Node: PVirtualNode; Data: PBookRecord;
  begin
    Node := Tree.AddChild(Parent); Data := Tree.GetNodeData(Node);
    Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Data^,False);
    if Checked then Tree.CheckState[Node] := csCheckedNormal;
  end;

  procedure Rows(const IDs: array of Integer; Page: Integer = PAGE_SEARCH);
  var Header: PVirtualNode; Data: PBookRecord;
  begin
    if Page = PAGE_PUBLISHER_SERIES then frmMain.pgControl.ActivePage := PublisherView.Tab
    else ShowPage(Page);
    case Page of
      PAGE_AUTHORS: Tree := frmMain.tvBooksA;
      PAGE_SERIES: Tree := frmMain.tvBooksS;
      PAGE_GENRES: Tree := frmMain.tvBooksG;
      PAGE_PUBLISHER_SERIES: Tree := PublisherView.Books;
      else Tree := frmMain.tvBooksSR;
    end;
    Tree.Clear; Header := Tree.AddChild(nil); Data := Tree.GetNodeData(Header);
    Data^.Clear; Data^.nodeType := ntSeriesInfo; Data^.Title := 'Delete series';
    for var ID in IDs do AddRow(ID,True,Header);
    if Length(IDs)>0 then AddRow(IDs[0],True); // Same book can appear in several series.
    Tree.FocusedNode := nil;
  end;

  procedure Execute(Accept, OnlyFiles: Boolean; Count, Archives: Integer; ExpectedWarnings: Integer = 0);
  begin
    // Main initialization restores native common dialogs. Select the VCL
    // message form only after constructing Main so its real text is inspectable.
    Vcl.Dialogs.UseLatestCommonDialogs := False;
    Probe.Accept := Accept; Probe.ExpectedCount := Count; Probe.ExpectedArchives := Archives;
    Probe.Confirmations := 0; Probe.Warnings := 0; Probe.Failure := '';
    Probe.Timer.Enabled := True;
    Trace('delete safety invoking Main action');
    try
      if OnlyFiles then frmMain.miDeleteFilesClick(nil) else frmMain.DeleteBookExecute(nil);
    finally Probe.Timer.Enabled := False; end;
    Require(Probe.Failure='',Probe.Failure);
    Require(Probe.Confirmations=1,'Deletion did not ask exactly once per batch');
    Require(Probe.Warnings=ExpectedWarnings,'Deletion did not aggregate failures into one warning');
  end;

  procedure Sources(const Tag: string);
  begin
    RawPath := Root+Tag+'.fb2'; ArchivePath := Root+Tag+'.zip';
    TFile.WriteAllText(RawPath,XML(Tag),TEncoding.UTF8); WriteZip(ArchivePath);
    RawID := Insert(Tag+' raw','',Tag,'.fb2');
    ArchiveID := Insert(Tag+' archived',Tag+'.zip','chosen','.fb2');
    OtherID := Insert(Tag+' unselected',Tag+'.zip','unselected','.fb2');
    Collection.SetReview(CreateBookKey(OtherID,Collection.CollectionID),'Сохранённая заметка — ё');
    BeforeRaw := THashSHA2.GetHashStringFromFile(RawPath);
    BeforeArchive := THashSHA2.GetHashStringFromFile(ArchivePath);
  end;

  procedure ProtectedArchive;
  var Zip: TZipFile; Bytes: TBytes;
  begin
    Require(THashSHA2.GetHashStringFromFile(ArchivePath)=BeforeArchive,'Deletion changed or removed the shared archive');
    Require(Exists(OtherID) and (Collection.GetReview(CreateBookKey(OtherID,Collection.CollectionID))='Сохранённая заметка — ё'),
      'Deletion damaged another book or its personal note');
    Zip := TZipFile.Create;
    try Zip.Open(ArchivePath,zmRead); Zip.Read('unselected.fb2',Bytes);
      Require(TEncoding.UTF8.GetString(Bytes)=XML('unselected.fb2'),'Other archive member is no longer readable');
    finally Zip.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Trace('delete safety create private fixtures');
  Root := Settings.AppPath+'book-delete-source\'; ForceDirectories(Root);
  PrivateID := SystemDB.CreateCollection('Delete safety private',Root,'delete-private.hlc2',CT_PRIVATE_FB,Settings.AppPath+'genres_fb2.glst');
  OnlineID := SystemDB.CreateCollection('Delete safety online',Root,'delete-online.hlc2',CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst');
  ExternalID := SystemDB.CreateCollection('Delete safety external FB2',Root,'delete-external.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  SavedDelete := Settings.DeleteFiles; SavedSelection := Settings.SelectedIsChecked;
  SavedDialogs := Vcl.Dialogs.UseLatestCommonDialogs;
  OldTemp := GetEnvironmentVariable('TEMP'); OldTmp := GetEnvironmentVariable('TMP');
  ForceDirectories(Root+'logs'); SetEnvironmentVariable('TEMP',PChar(Root+'logs')); SetEnvironmentVariable('TMP',PChar(Root+'logs'));
  Probe := TBookDeletionDialogProbe.Create; Probe.Timer := TTimer.Create(nil);
  Probe.Timer.Enabled := False; Probe.Timer.Interval := 15; Probe.Timer.OnTimer := Probe.Tick;
  try
    Settings.SelectedIsChecked := True; Vcl.Dialogs.UseLatestCommonDialogs := False;
    Settings.ShowInfoPanel := False; Settings.ShowBookCover := False; Settings.ShowBookAnnotation := False;
    Trace('delete safety replace isolated Main');
    FreeAndNil(frmMain); Settings.ActiveCollection := PrivateID; Settings.ActivePage := PAGE_SEARCH;
    Application.CreateForm(TfrmMain,frmMain); Collection := SystemDB.GetCollection(PrivateID);

    Trace('delete safety cancellation');
    Settings.DeleteFiles := True; Sources('cancel'); Trace('delete safety source files ready'); Rows([RawID,ArchiveID]); Trace('delete safety selection ready'); Execute(False,False,2,1);
    Require(Exists(RawID) and Exists(ArchiveID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw),'Canceled deletion changed the book'); ProtectedArchive;
    Settings.DeleteFiles := False; Rows([RawID,ArchiveID]); Execute(True,False,2,0);
    Require(not Exists(RawID) and not Exists(ArchiveID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw),'Record-only deletion changed files'); ProtectedArchive;

    Trace('delete safety records and source files');
    Settings.DeleteFiles := True; Sources('delete-files');
    WriteZip(Root+'private-book.zip'); PrivateFBD := Insert('private FBD','','private-book.zip','.fb2');
    Rows([RawID,ArchiveID,PrivateFBD]); Execute(True,False,3,2);
    Require(not Exists(RawID) and not Exists(ArchiveID) and not Exists(PrivateFBD) and not FileExists(RawPath) and FileExists(Root+'private-book.zip'),
      'Deletion failed to distinguish the raw book and private/shared archives'); ProtectedArchive;

    // Valid two-member 7z made by 7-Zip and independently tested before
    // embedding. Preservation/fallback checks require no installed decoder.
    TFile.WriteAllBytes(Root+'fallback.7z',TNetEncoding.Base64.DecodeStringToBytes(
      'N3q8ryccAASkdbxdnQAAAAAAAAAhAAAAAAAAAObLj+dPd25lZCBjaG9zZW4gYm9va093bmVkIHByb3RlY3RlZCBuZWlnaGJvdXJpbmcgYm9vawAAgTMHrjGZZ562gPIalnBnsCPEi+eGNCu7DSNRYELXNgsyAM33hSbO+pghYazfJwTN+wZppJl14obMIKq07QZm6Z4euNEvjySl4Wvysd1OiLu31MyKy4dm5buX25eqzGELLrs2FzwPqjJgFwYyAQlrAAcLAQABIwMBAQVdABAAAAyAhgoBCrGfBgAA'));
    SevenID := Insert('7z source','fallback.7z','chosen','.fb2');
    LegacyID := Insert('legacy ZIP alias','fallback.zip','chosen','.fb2');
    NeighbourID := Insert('7z unselected','fallback.7z','unselected','.fb2');
    Collection.GetBookRecord(CreateBookKey(LegacyID,PrivateID),Book,False);
    Require(SameFileName(Book.GetBookFileName,Root+'fallback.7z'),'Legacy fixture did not resolve ZIP to existing 7z');
    BeforeRaw := THashSHA2.GetHashStringFromFile(Root+'fallback.7z');
    Rows([SevenID,LegacyID]); Execute(True,False,2,2);
    Require(not Exists(SevenID) and not Exists(LegacyID) and Exists(NeighbourID) and Local(NeighbourID) and
      (THashSHA2.GetHashStringFromFile(Root+'fallback.7z')=BeforeRaw),'Deletion removed a 7z or its legacy ZIP fallback neighbour');

    for var Page in [PAGE_AUTHORS,PAGE_SERIES,PAGE_GENRES,PAGE_SEARCH,PAGE_PUBLISHER_SERIES] do
    begin
      Sources('view-'+IntToStr(Page)); Rows([RawID,ArchiveID],Page); Execute(True,True,2,1);
      Require(Exists(RawID) and Exists(ArchiveID) and not Local(RawID) and Local(ArchiveID) and not FileExists(RawPath),
        'Files-only deletion lost records or marked an unchanged archive unavailable'); ProtectedArchive;
      Sources('records-view-'+IntToStr(Page)); Rows([RawID,ArchiveID],Page); Execute(True,False,2,1);
      Require(not Exists(RawID) and not Exists(ArchiveID) and not FileExists(RawPath),
        'Record deletion from this view did not commit unique selected books'); ProtectedArchive;
    end;

    Trace('delete safety database failure');
    Sources('rejected-write'); FailID := RawID;
    TFile.WriteAllText(Root+'successful.fb2',XML('successful'),TEncoding.UTF8);
    GoodID := Insert('successful','','successful','.fb2');
    DB := TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(PrivateID).DBFileName);
    try DB.ExecSQL('CREATE TRIGGER RejectDelete BEFORE DELETE ON Books WHEN OLD.BookID='+IntToStr(FailID)+
      ' BEGIN SELECT RAISE(ABORT,''owned deletion write fault''); END'); finally DB.Free; end;
    Rows([FailID,GoodID]); Execute(True,False,2,0,1);
    Require(Exists(FailID) and not Exists(GoodID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw) and not FileExists(Root+'successful.fb2'),
      'A failed database deletion removed its source or prevented independent successful books'); ProtectedArchive;

    Trace('delete safety locked and changed sources');
    Sources('locked-file'); Rows([RawID]); Locked := TFileStream.Create(RawPath,fmOpenRead or fmShareExclusive);
    try Execute(True,True,1,0,1); finally Locked.Free; end;
    Require(Exists(RawID) and Local(RawID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw),'Busy file was lost or falsely marked removed');

    Sources('changed-source'); Rows([RawID]);
    TFile.WriteAllText(Root+'replacement.fb2',XML('replacement'),TEncoding.UTF8);
    Probe.BeforeAccept := procedure
      begin
        Collection.GetBookRecord(CreateBookKey(RawID,Collection.CollectionID),Other,False);
        Other.FileName := 'replacement'; Collection.UpdateBook(Other);
      end;
    Execute(True,False,1,0,1);
    Require(Exists(RawID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw) and FileExists(Root+'replacement.fb2'),
      'Changed source identity deleted the original or replacement file'); ProtectedArchive;
    Require(TFile.ReadAllText(DiagnosticLogFile,TEncoding.UTF8).Contains('book-delete'),'Deletion failures were not recorded in the diagnostic log');

    for var Ext in ['.pdf','.djvu','.doc'] do
    begin
      // File operations must not load a format decoder. These are opaque
      // filename/path fixtures, not claims of PDF/DjVu/DOC content parsing.
      RawPath := Root+'opaque'+Ext; TFile.WriteAllText(RawPath,'Owned opaque source',TEncoding.UTF8);
      RawID := Insert('opaque '+Ext,'','opaque',Ext); Rows([RawID]); Execute(True,True,1,0);
      Require(Exists(RawID) and not Local(RawID) and not FileExists(RawPath),'Files-only deletion mishandled a non-FB2 extension');
    end;

    Sources('filtered-selection'); Rows([ArchiveID]);
    var Node := Tree.GetFirst;
    while Assigned(Node) do begin Include(Node.States,vsFiltered); Node := Tree.GetNext(Node); end;
    Probe.Confirmations := 0; Probe.Accept := False; Probe.Timer.Enabled := True;
    try frmMain.DeleteBookExecute(nil); finally Probe.Timer.Enabled := False; end;
    Require((Probe.Confirmations=0) and Exists(ArchiveID),'Filtered checked rows were treated as an active deletion selection'); ProtectedArchive;

    Sources('applied-search'); ShowPage(PAGE_SEARCH);
    frmMain.edFTitle.Text := 'applied-search'; frmMain.DoApplyFilter(nil); Tree := frmMain.tvBooksSR;
    Count := 0; Node := Tree.GetFirst; Tree.ClearSelection; Tree.FocusedNode := nil;
    while Assigned(Node) do
    begin
      var Data := PBookRecord(Tree.GetNodeData(Node));
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) then
      begin Inc(Count); if (Data^.BookKey.BookID=RawID) or (Data^.BookKey.BookID=ArchiveID) then Tree.CheckState[Node] := csCheckedNormal; end;
      Node := Tree.GetNext(Node);
    end;
    Require(Count=3,'Actual applied search did not load three source books');
    frmMain.edFTitle.Text := 'Unsaved deletion search draft'; Settings.DeleteFiles := False;
    Execute(True,False,2,0); Count := 0; Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      var Data := PBookRecord(Tree.GetNodeData(Node));
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) then
      begin Inc(Count); Require(Data^.BookKey.BookID=OtherID,'Refreshed applied search kept a removed book'); end;
      Node := Tree.GetNext(Node);
    end;
    Require((Count=1) and (frmMain.edFTitle.Text='Unsaved deletion search draft'),'Deletion lost the applied search or overwritten its unsaved draft');
    Require(THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw,'Record-only applied search deletion changed the source'); ProtectedArchive;

    Trace('delete safety external local FB2 loose files');
    FreeAndNil(frmMain); Settings.ActiveCollection := ExternalID; Settings.ActivePage := PAGE_SEARCH;
    Application.CreateForm(TfrmMain,frmMain); Collection := SystemDB.GetCollection(ExternalID);
    var LooseFolder := 'Обновление 2026-11-05\Автор с пробелом\';
    ForceDirectories(Root+LooseFolder);
    var UnselectedPath := Root+LooseFolder+'Соседняя книга.fb2';
    TFile.WriteAllText(UnselectedPath,XML('Не выбранная книга'),TEncoding.UTF8);
    var NeighbourHash := THashSHA2.GetHashStringFromFile(UnselectedPath);
    for var Page in [PAGE_AUTHORS,PAGE_SERIES,PAGE_GENRES,PAGE_SEARCH,PAGE_PUBLISHER_SERIES] do
      for var DeleteSource in [False,True] do
      begin
        Settings.DeleteFiles := DeleteSource;
        var LooseName := 'Книга ё '+IntToStr(Page)+' '+BoolToStr(DeleteSource,True);
        RawPath := Root+LooseFolder+LooseName+'.fb2';
        TFile.WriteAllText(RawPath,XML(LooseName),TEncoding.UTF8);
        BeforeRaw := THashSHA2.GetHashStringFromFile(RawPath);
        RawID := Insert(LooseName,LooseFolder,LooseName,'.fb2');
        Rows([RawID],Page);
        Execute(True,False,1,0);
        Require(not Exists(RawID),'External local deletion kept the selected catalogue record');
        if DeleteSource then
          Require(not FileExists(RawPath),'Enabled Delete files setting was ignored in an external local FB2 collection')
        else
          Require(THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw,'Disabled Delete files setting still changed the loose source');
        Require(THashSHA2.GetHashStringFromFile(UnselectedPath)=NeighbourHash,'Loose file deletion changed an unselected neighbouring file');
      end;
    Writeln('PASS external local FB2 deletion honours the file setting in five views and Unicode update folders'); Flush(Output);

    Trace('delete safety online catalog');
    FreeAndNil(frmMain); Settings.ActiveCollection := OnlineID; Settings.ActivePage := PAGE_SEARCH;
    Application.CreateForm(TfrmMain,frmMain); Collection := SystemDB.GetCollection(OnlineID);
    Sources('online'); Collection.SetRate(CreateBookKey(RawID,OnlineID),4); Collection.SetProgress(CreateBookKey(RawID,OnlineID),23);
    Rows([RawID,ArchiveID]); Execute(True,False,2,1);
    Require(Exists(RawID) and Exists(ArchiveID) and not Local(RawID) and Local(ArchiveID) and not FileExists(RawPath),
      'Online deletion removed catalog records or cleared the retained archive status'); ProtectedArchive;
    Collection.GetBookRecord(CreateBookKey(RawID,OnlineID),Book,False);
    Require((Book.Rate=4) and (Book.Progress=23),'Online file removal lost personal rating or reading progress');
    RawID := Insert('already absent archive','already-absent.zip','chosen','.fb2');
    Rows([RawID]); Execute(True,False,1,1);
    Require(Exists(RawID) and not Local(RawID),'An already absent archive kept a false downloaded flag');
    Writeln('PASS deletion confirmations unique books cancel records files shared archives five views online failures identity and protected neighbours'); Flush(Output);
  finally
    Probe.Timer.Free; Probe.Free; Settings.DeleteFiles := SavedDelete; Settings.SelectedIsChecked := SavedSelection;
    Vcl.Dialogs.UseLatestCommonDialogs := SavedDialogs;
    SetEnvironmentVariable('TEMP',PChar(OldTemp)); SetEnvironmentVariable('TMP',PChar(OldTmp));
  end;
end;
