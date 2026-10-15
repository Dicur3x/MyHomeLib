// Actual metadata fill form, Main command and Sources command. Disposable G profile.
// Uses frm_BookMetadataFill, unit_MetadataSyncTypes; include after MainLiveInputFavoriteTests.
type
  TMetadataUiControlAccess = class(TControl);

  TMetadataUiModalProbe = class
  public
    Timer: TTimer;
    Stage: Integer;
    AnnotationOnly: Boolean;
    Deadline: UInt64;
    procedure Tick(Sender: TObject);
  end;

type
  TMetadataWizardAccess = class(TNewCollectionWizard)
  public
    procedure StartPreparedCollection;
    procedure ShowUncommittedFinish;
  end;

  TMetadataWizardParamsAccess = class(TframeNCWFinish)
  public
    procedure Prepare(const Root, DatabaseFile, IndexFile: string; Online: Boolean = False);
  end;

  TMetadataWizardScenario = (mwsImportRequest, mwsNormalFinish, mwsCancel,
    mwsUncommittedFinish, mwsCreationFailure, mwsMissingCollection);

  TMetadataWizardProbe = class
  public
    Timer: TTimer;
    Scenario: TMetadataWizardScenario;
    Stage, CollectionID, MetadataWindows: Integer;
    Deadline, NextTrace: UInt64;
    Root, DatabaseFile, IndexFile: string;
    procedure Tick(Sender: TObject);
  end;

procedure TMetadataWizardAccess.StartPreparedCollection;
begin ShowPage(7); end;

procedure TMetadataWizardAccess.ShowUncommittedFinish;
begin ShowPage(8); end;

procedure TMetadataWizardParamsAccess.Prepare(const Root, DatabaseFile, IndexFile: string; Online: Boolean);
begin
  Require(Assigned(FPParams),'Actual Finish frame lacks its wizard parameter record');
  FPParams^.Operation:=otNew;
  if IndexFile<>'' then FPParams^.Operation:=otInpx;
  FPParams^.CollectionType:=ltExternalLocalFB;
  FPParams^.CollectionCode:=CT_EXTERNAL_LOCAL_FB;
  if Online then
  begin FPParams^.CollectionType:=ltExternalOnlineFB; FPParams^.CollectionCode:=CT_EXTERNAL_ONLINE_FB; end;
  FPParams^.CollectionRoot:=Root; FPParams^.CollectionFile:=DatabaseFile;
  FPParams^.INPXFile:=IndexFile;
  FPParams^.DisplayName:='Wizard metadata '+ChangeFileExt(ExtractFileName(ExcludeTrailingPathDelimiter(DatabaseFile)),'');
  FPParams^.FileTypes:=ftFB2; FPParams^.DefaultGenres:=True;
  FPParams^.GenreFile:=Settings.SystemFileName[sfGenresFB2]; FPParams^.AutoImport:=False;
end;

procedure TMetadataWizardProbe.Tick(Sender: TObject);
var Wizard: TNewCollectionWizard; Finish: TframeNCWFinish; Form: TfrmBookMetadataFill;
  Collection: IBookCollection; Iterator: IBookIterator; Book: TBookRecord;
begin
  if GetTickCount64>=NextTrace then
  begin
    Writeln('TRACE wizard tick scenario=',Ord(Scenario),' stage=',Stage,
      ' cid=',CollectionID,' active_cid=',Settings.ActiveCollection,' forms=',Screen.FormCount);
    for var I:=0 to Min(Screen.FormCount-1,7) do
    begin
      var ExistingWindow: HWND;
      ExistingWindow:=0;
      if Screen.Forms[I].HandleAllocated then ExistingWindow:=Screen.Forms[I].Handle;
      Writeln('TRACE wizard form class=',Screen.Forms[I].ClassName,' name=',Screen.Forms[I].Name,
        ' visible=',Ord(Screen.Forms[I].Visible),' modal=',Screen.Forms[I].ModalResult,
        ' hwnd=',NativeUInt(ExistingWindow));
    end;
    Flush(Output); NextTrace:=GetTickCount64+1000;
  end;
  Require(GetTickCount64<=Deadline,'Actual wizard metadata request exceeded30seconds scenario='+
    IntToStr(Ord(Scenario))+' stage='+IntToStr(Stage));
  if Stage=2 then
  begin
    for var I:=0 to Screen.FormCount-1 do
      if (Screen.Forms[I] is TfrmBookMetadataFill) and Screen.Forms[I].Visible then
      begin
        Form:=TfrmBookMetadataFill(Screen.Forms[I]); Inc(MetadataWindows);
        Require((Form.CollectionID=CollectionID) and (Settings.ActiveCollection=CollectionID),
          'Finish metadata request was routed to another active collection');
        Require(not Form.Busy and not TButton(Form.FindComponent('btnMetadataApply')).Enabled and
          (TLabel(Form.FindComponent('lblMetadataFillProgress')).Caption=''),
          'Finish metadata command scanned or enabled writes before explicit preview');
        Collection:=SystemDB.GetCollection(CollectionID); Iterator:=Collection.GetBookIterator(bmAll,True);
        Require(Iterator.Next(Book) and (Book.Title='Wizard imported book') and (Book.Publisher=''),
          'Imported catalog was changed by merely opening the Finish metadata dialog');
        Stage:=3; Timer.Enabled:=False;
        TButton(Form.FindComponent('btnMetadataClose')).Click;
        Exit;
      end;
    Exit;
  end;
  Wizard:=nil;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TNewCollectionWizard) and Screen.Forms[I].Visible then
    begin Wizard:=TNewCollectionWizard(Screen.Forms[I]); Break; end;
  if not Assigned(Wizard) then Exit;
  Finish:=TframeNCWFinish(Wizard.FindComponent('frameNCWFinish'));
  Require(Assigned(Finish) and Assigned(Finish.btnMetadataFill.OnClick),'Wizard Finish metadata action is absent');
  if Stage=0 then
  begin
    Require(not Wizard.RequestedMetadataFill and not Finish.btnMetadataFill.Enabled,
      'New wizard retained or enabled an uncommitted metadata request');
    if Scenario=mwsCancel then
    begin Stage:=3; Timer.Enabled:=False; Wizard.btnCancel.Click; Exit; end;
    if Scenario=mwsUncommittedFinish then
    begin
      TMetadataWizardAccess(Wizard).ShowUncommittedFinish;
      Finish.btnMetadataFill.OnClick(Finish.btnMetadataFill);
      Require(not Finish.btnMetadataFill.Enabled and not Wizard.RequestedMetadataFill and
        (Wizard.NewCollectionID<=0) and (Wizard.ModalResult=mrNone),
        'Uncommitted preview Finish page certified a metadata request');
      Stage:=3; Timer.Enabled:=False; Wizard.btnCancel.Click; Exit;
    end;
    var ActualIndex: string;
    ActualIndex:=''; if Scenario=mwsImportRequest then ActualIndex:=IndexFile;
    TMetadataWizardParamsAccess(Finish).Prepare(Root,DatabaseFile,ActualIndex);
    Stage:=1; Timer.Enabled:=False;
    Writeln('TRACE wizard start actual progress scenario=',Ord(Scenario),' file=',DatabaseFile,
      ' index=',ActualIndex); Flush(Output);
    try TMetadataWizardAccess(Wizard).StartPreparedCollection;
    finally Timer.Enabled:=True; end;
    Writeln('TRACE wizard progress returned scenario=',Ord(Scenario),
      ' success=',Ord(Wizard.OperationSucceeded),' committed=',Ord(Wizard.CommittedChanges),
      ' new_cid=',Wizard.NewCollectionID,' finish_visible=',Ord(Finish.Visible),
      ' finish_enabled=',Ord(Finish.btnMetadataFill.Enabled),' cancel_enabled=',Ord(Wizard.btnCancel.Enabled));
    Flush(Output);
    if not Wizard.CommittedChanges and (Wizard.NewCollectionID<=0) then
    begin
      var ProgressFrame:=TFrame(Wizard.FindComponent('frameNCWProgress'));
      Require(Assigned(ProgressFrame),'Actual wizard progress page is absent after creation');
      var ErrorLog:=TListView(ProgressFrame.FindComponent('errorLog'));
      Require(Assigned(ErrorLog),'Actual wizard progress journal is absent after creation');
      for var I:=Max(0,ErrorLog.Items.Count-16) to ErrorLog.Items.Count-1 do
        for var J:=0 to Min(ErrorLog.Items[I].SubItems.Count-1,3) do
          Writeln('TRACE wizard actual creation journal ',Copy(ErrorLog.Items[I].SubItems[J],1,700));
      Flush(Output);
      Require(Scenario=mwsCreationFailure,'Unexpected actual wizard collection creation failure; see bounded progress journal');
    end;
  end;
  if Stage<>1 then Exit;
  if Scenario=mwsCreationFailure then
  begin
    Require(not Wizard.OperationSucceeded and not Wizard.CommittedChanges and
      not Finish.Visible and not Finish.btnMetadataFill.Enabled,
      'Failed collection creation reached a usable metadata Finish action');
    Finish.btnMetadataFill.OnClick(Finish.btnMetadataFill);
    Require(not Wizard.RequestedMetadataFill,'Failed creation recorded a metadata request');
    Stage:=3; Timer.Enabled:=False; Wizard.btnCancel.Click; Exit;
  end;
  if not Finish.Visible then Exit;
  CollectionID:=Wizard.NewCollectionID;
  Require(Wizard.OperationSucceeded and Wizard.CommittedChanges and (CollectionID>0) and
    (SystemDB.FindFirstExistingCollectionID(CollectionID)=CollectionID),
    'Actual wizard Finish lacked its successful committed registered collection');
  Require(Finish.btnMetadataFill.Enabled and not Wizard.RequestedMetadataFill,
    'Successful local Finish hides its manual metadata choice or requests it automatically');
  if Scenario=mwsMissingCollection then
  begin
    SystemDB.DeleteCollection(CollectionID);
    Finish.btnMetadataFill.OnClick(Finish.btnMetadataFill);
    Require(not Finish.btnMetadataFill.Enabled and not Wizard.RequestedMetadataFill and
      (Wizard.ModalResult=mrNone),'Vanished Finish collection was accepted for metadata fill');
    Stage:=3; Timer.Enabled:=False; Wizard.btnCancel.Click; Exit;
  end;
  if Scenario=mwsNormalFinish then
  begin
    Require(not Wizard.RequestedMetadataFill,'Ordinary Finish enabled metadata fill without consent');
    Stage:=3; Timer.Enabled:=False;
    Writeln('TRACE wizard normal Finish click cid=',CollectionID,' close_enabled=',Ord(Wizard.btnCancel.Enabled)); Flush(Output);
    Wizard.btnCancel.Click;
    Writeln('TRACE wizard normal Finish returned modal=',Wizard.ModalResult); Flush(Output); Exit;
  end;
  Stage:=2; Finish.btnMetadataFill.Click;
  Require(Wizard.RequestedMetadataFill and (Wizard.ModalResult=mrOk),
    'Actual Finish metadata button did not record its explicit successful request');
end;

procedure TestMetadataWizardFinish(OriginalCID: Integer);
var Probe: TMetadataWizardProbe; Root, SourceFile, SourceHash, IndexFile, IndexHash, Before: string;
  OriginalPage, NormalCID, ImportedCID: Integer; Zip: TZipFile; Data: TBytes;
  Wizard: TMetadataWizardAccess; Finish: TframeNCWFinish; Collection: IBookCollection;
  Bitmap: TBitmap; OriginalTheme: Boolean; UserBefore: string;

  function ReadPersonalCards: string;
  var DB: TSQLiteDatabase; Query: TSQLiteQuery; TableName, Value: string;
  begin
    Result:=''; DB:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    try
      for TableName in TArray<string>.Create('Books','BookGroups','Groups') do
      begin
        Query:=DB.NewQuery('SELECT * FROM "'+TableName+'" ORDER BY rowid');
        try
          Query.Open; Result:=Result+TableName+#10;
          while not Query.Eof do
          begin
            for var I:=0 to Query.ColCount-1 do
            begin Value:=Query.FieldAsString(I); Result:=Result+IntToStr(Length(Value))+':'+Value; end;
            Result:=Result+#10; Query.Next;
          end;
        finally Query.Free; end;
      end;
    finally DB.Free; end;
  end;

  procedure SelectCollection(CID: Integer);
  var Item: TMenuItem;
  begin
    Item:=TMenuItem.Create(nil);
    try Item.Tag:=CID; frmMain.miActiveCollectionClick(Item); finally Item.Free; end;
  end;

  procedure Run(Scenario: TMetadataWizardScenario; const FileName: string);
  begin
    Probe.Stage:=0; Probe.CollectionID:=0; Probe.MetadataWindows:=0;
    Probe.Scenario:=Scenario; Probe.DatabaseFile:=FileName;
    Probe.Deadline:=GetTickCount64+30000; Probe.NextTrace:=0; Probe.Timer.Enabled:=True;
    Writeln('TRACE wizard scenario begin ',Ord(Scenario),' database=',FileName); Flush(Output);
    try frmMain.ShowNewCollectionWizard(nil); finally Probe.Timer.Enabled:=False; end;
    Writeln('TRACE wizard scenario end ',Ord(Scenario),' stage=',Probe.Stage,
      ' cid=',Probe.CollectionID,' metadata_windows=',Probe.MetadataWindows); Flush(Output);
    Require(Probe.Stage=3,'Actual Main wizard did not reach the expected terminal control action');
    Require(Probe.MetadataWindows=Ord(Scenario=mwsImportRequest),
      'Main opened an unsolicited metadata dialog or lost the explicit Finish request');
    for var I:=0 to Screen.FormCount-1 do
      Require(not (Screen.Forms[I] is TNewCollectionWizard) and not (Screen.Forms[I] is TfrmBookMetadataFill),
        'Wizard Finish metadata flow left an orphan form');
    Require((MLIReadCatalogData(OriginalCID)=Before) and (ReadPersonalCards=UserBefore),
      'Wizard Finish request changed the existing catalog or personal cards/groups');
    Require((THashSHA2.GetHashStringFromFile(SourceFile)=SourceHash) and
      (THashSHA2.GetHashStringFromFile(IndexFile)=IndexHash),'Wizard Finish flow rewrote its source FB2 or INPX');
  end;

  procedure CheckCaption(Control: TControl; Wrapped: Boolean; PPI: Integer);
  var R: TRect; Text: string; Flags: Cardinal; Margin: Integer;
  begin
    Margin:=0; if not Wrapped then Margin:=MulDiv(12,PPI,96);
    Text:=TMetadataUiControlAccess(Control).Caption;
    Bitmap.Canvas.Font.Assign(TMetadataUiControlAccess(Control).Font);
    R:=Rect(0,0,Control.Width-Margin,Control.Height);
    Flags:=DT_CALCRECT or DT_NOPREFIX;
    if Wrapped then Flags:=Flags or DT_WORDBREAK else Flags:=Flags or DT_SINGLELINE;
    Require((DrawText(Bitmap.Canvas.Handle,PChar(Text),Length(Text),R,Flags)>0) and
      (R.Width<=Control.Width-Margin) and (R.Height<=Control.Height),
      'Wizard Finish metadata caption is clipped at dpi='+IntToStr(PPI));
    Require((Control.Left>=0) and (Control.Top>=0) and
      (Control.BoundsRect.Right<=Control.Parent.ClientWidth) and
      (Control.BoundsRect.Bottom<=Control.Parent.ClientHeight),
      'Wizard Finish metadata control lies outside its parent');
  end;

begin
  RequireIsolatedRegression;
  OriginalPage:=frmMain.pgControl.ActivePageIndex; OriginalTheme:=MHLThemeDark;
  Before:=MLIReadCatalogData(OriginalCID); UserBefore:=ReadPersonalCards;
  Root:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'metadata-wizard-finish'));
  ForceDirectories(Root); SourceFile:=Root+'finish-book.fb2'; IndexFile:=Root+'finish.inpx';
  TFile.WriteAllText(SourceFile,'<?xml version="1.0" encoding="UTF-8"?>'+
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
    '<genre>prose_contemporary</genre><author><first-name>Автор</first-name><last-name>Тест</last-name></author>'+
    '<book-title>Wizard imported book</book-title><lang>ru</lang></title-info><publish-info>'+
    '<publisher>Издательство из файла</publisher></publish-info><document-info><author><nickname>fixture</nickname></author>'+
    '<date value="2026-10-15">2026-10-15</date><id>91001</id><version>1.0</version></document-info>'+
    '</description><body><section><p>Исходный текст ё 😀.</p></section></body></FictionBook>',TEncoding.UTF8);
  SourceHash:=THashSHA2.GetHashStringFromFile(SourceFile);
  Zip:=TZipFile.Create;
  try
    Zip.Open(IndexFile,zmWrite);
    Data:=TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG;FOLDER');
    Zip.Add(Data,'structure.info');
    Data:=TEncoding.UTF8.GetBytes('Тест,Автор:'#4'prose_contemporary:'#4'Wizard imported book'#4#4#4+
      'finish-book'#4+IntToStr(TFile.GetSize(SourceFile))+#4'91001'#4'0'#4'fb2'#4'2026-10-15'#4'ru'#4'.');
    Zip.Add(Data,'books.inp');
  finally Zip.Free; end;
  IndexHash:=THashSHA2.GetHashStringFromFile(IndexFile);
  Probe:=TMetadataWizardProbe.Create; Bitmap:=TBitmap.Create;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=10; Probe.Timer.OnTimer:=Probe.Tick; Probe.Root:=Root; Probe.IndexFile:=IndexFile;
  try
    Run(mwsImportRequest,Root+'imported.hlc2'); ImportedCID:=Probe.CollectionID;
    Writeln('PASS wizard successful INPX Finish opens only the requested exact collection metadata dialog without auto-preview or writes'); Flush(Output);
    Run(mwsNormalFinish,Root+'normal.hlc2'); NormalCID:=Probe.CollectionID;
    Run(mwsCancel,Root+'cancel.hlc2');
    Run(mwsUncommittedFinish,Root+'preview.hlc2');
    // Include the actual catalog extension: the normal filename helper turns
    // a bare directory ending in a separator into a valid '.hlc2' filename.
    // SQLite must instead fail opening this exact existing directory as a file.
    Require(ForceDirectories(Root+'cannot-create.hlc2') and
      DirectoryExists(Root+'cannot-create.hlc2') and not FileExists(Root+'cannot-create.hlc2'),
      'Negative wizard fixture is not an existing directory with the catalog extension');
    Run(mwsCreationFailure,Root+'cannot-create.hlc2');
    Require(DirectoryExists(Root+'cannot-create.hlc2'),
      'Failed wizard creation removed its pre-existing directory fixture');
    Run(mwsMissingCollection,Root+'removed.hlc2');
    Writeln('PASS wizard ordinary finish, cancel, uncommitted preview, creation failure and vanished collection never request or open metadata fill'); Flush(Output);
    SelectCollection(OriginalCID);
    Wizard:=TMetadataWizardAccess.Create(frmMain);
    try
      Finish:=TframeNCWFinish(Wizard.FindComponent('frameNCWFinish'));
      TMetadataWizardParamsAccess(Finish).Prepare(Root,Root+'guarded.hlc2','');
      Wizard.StartPreparedCollection;
      Require(Wizard.OperationSucceeded and Finish.btnMetadataFill.Enabled,'Guard fixture did not create a real successful local Finish');
      Collection:=SystemDB.GetCollection(Wizard.NewCollectionID);
      Collection.SetProperty(PROP_ROOTFOLDER,Root+'unavailable');
      Finish.btnMetadataFill.OnClick(Finish.btnMetadataFill);
      Require(not Finish.btnMetadataFill.Enabled and not Wizard.RequestedMetadataFill and
        (Wizard.ModalResult=mrNone),'Unavailable Finish root was accepted for metadata fill');
      Collection.SetProperty(PROP_ROOTFOLDER,Root); Collection:=nil;
    finally Wizard.Free; end;
    Wizard:=TMetadataWizardAccess.Create(frmMain);
    try
      Finish:=TframeNCWFinish(Wizard.FindComponent('frameNCWFinish'));
      TMetadataWizardParamsAccess(Finish).Prepare(Root,Root+'online.hlc2','',True);
      Wizard.StartPreparedCollection;
      Finish.btnMetadataFill.OnClick(Finish.btnMetadataFill);
      Require(Wizard.OperationSucceeded and not Finish.btnMetadataFill.Enabled and not Wizard.RequestedMetadataFill,
        'Online-only collection enabled local metadata fill');
    finally Wizard.Free; end;
    Writeln('PASS wizard metadata choice revalidates its registered local root and refuses unavailable or online-only targets'); Flush(Output);
    Wizard:=TMetadataWizardAccess.Create(frmMain);
    try
      Finish:=TframeNCWFinish(Wizard.FindComponent('frameNCWFinish'));
      TMetadataWizardParamsAccess(Finish).Prepare(Root,Root+'layout.hlc2','');
      Wizard.StartPreparedCollection; Wizard.Show; Application.ProcessMessages;
      for var Dark in TArray<Boolean>.Create(False,True) do
      begin
        CheckSynchronize(0); SetMHLTheme(Dark); CheckSynchronize(0);
        for var PPI in TArray<Integer>.Create(96,144,192) do
        begin
          Wizard.ScaleForPPI(PPI); Application.ProcessMessages;
          Require(Wizard.Font.PixelsPerInch=PPI,'Wizard Finish layout did not adopt requested DPI');
          CheckCaption(Finish.btnMetadataFill,False,PPI); CheckCaption(Finish.lblMetadataFill,True,PPI);
          Require(Finish.btnMetadataFill.BoundsRect.Bottom<=Finish.lblMetadataFill.Top,
            'Wizard Finish metadata button overlaps its explanation');
          Require(not Wizard.RequestedMetadataFill,'Wizard layout initiated a metadata request');
        end;
      end;
    finally CheckSynchronize(0); Wizard.Free; CheckSynchronize(0); end;
    Require((SystemDB.FindFirstExistingCollectionID(ImportedCID)=ImportedCID) and
      (SystemDB.FindFirstExistingCollectionID(NormalCID)=NormalCID),'Wizard non-fill choices removed successful collections');
    Require((MLIReadCatalogData(OriginalCID)=Before) and (ReadPersonalCards=UserBefore),
      'Wizard metadata gates changed the original catalog or personal cards/groups');
    Writeln('PASS wizard Finish metadata button and explanation fit six theme/DPI combinations without scanning'); Flush(Output);
  finally
    Probe.Timer.Enabled:=False; Probe.Timer.Free; Probe.Free; Bitmap.Free;
    CheckSynchronize(0); SetMHLTheme(OriginalTheme); CheckSynchronize(0); SelectCollection(OriginalCID); frmMain.pgControl.ActivePageIndex:=OriginalPage;
  end;
end;

function MetadataUiButton(Form: TfrmBookMetadataFill; const Name: string): TButton;
begin
  Result:=TButton(Form.FindComponent(Name));
  Require(Assigned(Result) and Assigned(Result.OnClick),'Metadata form action is absent: '+Name);
end;

procedure TestMetadataTiming;
var Timing: TMetadataTiming; Speed: Double; Remaining: Int64; Text: string;
begin
  Timing.Reset(0); Timing.Sample(0,1000,0); Timing.Sample(100,1000,5000);
  Require(not Timing.TryEstimate(5000,Speed,Remaining),'ETA guesses from an early startup burst');
  Timing.Reset(0); Timing.Sample(0,1000,0);
  for var I:=1 to 10 do Timing.Sample(I*20,1000,I*1000);
  Require(Timing.TryEstimate(10000,Speed,Remaining) and SameValue(Speed,20,0.001) and
    (Remaining=40),'ETA does not use completed counts and elapsed monotonic time');
  Require(not Timing.TryEstimate(20000,Speed,Remaining) and
    Timing.Description(20000,True).Contains('уточняется'),'A stalled source keeps a false ETA');
  Timing.Reset(0); Timing.Sample(0,100000,0);
  for var I:=1 to 40 do
    if I<=10 then Timing.Sample(I*1000,100000,I*1000)
    else Timing.Sample(10000+(I-10)*20,100000,I*1000);
  Require(Timing.TryEstimate(40000,Speed,Remaining) and SameValue(Speed,20,0.001) and
    (Remaining=4470),'ETA retains the fast cache phase after thirty seconds of slower archive reads');
  Timing.Sample(100000,100000,41000);
  Require(not Timing.TryEstimate(41000,Speed,Remaining) and
    Timing.Description(41000,True).Contains('Завершаем'),'ETA claims a countdown after all books were processed');
  Timing.Reset(50000); Timing.Sample(0,2000000,50000);
  for var I:=1 to 10 do Timing.Sample(I*20,2000000,50000+I*1000);
  Text:=Timing.Description(60000,True);
  Require(Text.Contains('книг/с') and Text.Contains('Осталось: примерно 27 ч'),
    'Long ETA wraps at twenty-four hours or loses the approximate label');
  Require(not Timing.Description(60000,False).Contains('Осталось'),
    'Canceled or finished operation keeps its old countdown');
  Timing.Reset(70000); Timing.Sample(0,0,70000);
  Require(not Timing.TryEstimate(80000,Speed,Remaining),'Unknown totals divide by zero or produce an ETA');
  Timing.Sample(100,1000,81000); Timing.Sample(10,1000,82000);
  Require(not Timing.TryEstimate(82000,Speed,Remaining),'Restarted progress inherits the previous operation rate');
  Writeln('PASS metadata ETA warmup, current speed, thirty-second adaptation, stalls, long durations and stage reset');
end;

procedure TestMetadataFillLayout(CID: Integer);
var Form: TfrmBookMetadataFill; Bitmap: TBitmap; Png: TPngImage;
  OriginalTheme: Boolean; Before, Artifacts: string;

  procedure CheckText(Control: TControl; WordWrap: Boolean; Margin: Integer = 0);
  var R: TRect; Flags: Cardinal; Caption: string;
  begin
    Caption:=TMetadataUiControlAccess(Control).Caption;
    Bitmap.Canvas.Font.Assign(TMetadataUiControlAccess(Control).Font);
    R:=Rect(0,0,Control.Width-Margin*2,Control.Height); Flags:=DT_CALCRECT or DT_NOPREFIX;
    if WordWrap then Flags:=Flags or DT_WORDBREAK else Flags:=Flags or DT_SINGLELINE;
    Require(DrawText(Bitmap.Canvas.Handle,PChar(Caption),Length(Caption),R,Flags)>0,
      'Metadata caption could not be measured: '+Control.Name);
    Require((R.Width<=Control.Width-Margin*2) and (R.Height<=Control.Height),
      'Metadata caption is clipped at dpi='+IntToStr(Form.Font.PixelsPerInch)+': '+Control.Name);
    Writeln('TRACE metadata bounds dpi=',Form.Font.PixelsPerInch,' dark=',Ord(MHLThemeDark),
      ' control=',Control.Name,' bounds=',Control.Left,',',Control.Top,' ',Control.Width,'x',Control.Height,
      ' parent=',Control.Parent.ClientWidth,'x',Control.Parent.ClientHeight,
      ' client=',Form.ClientWidth,'x',Form.ClientHeight); Flush(Output);
    Require((Control.Left>=0) and (Control.Top>=0) and
      (Control.BoundsRect.Right<=Control.Parent.ClientWidth) and
      (Control.BoundsRect.Bottom<=Control.Parent.ClientHeight),
      'Metadata control is outside its own layout panel: '+Control.Name);
  end;

  procedure CheckWindow(PPI: Integer; Minimum: Boolean);
  var Footer: TWinControl; R, Client: TRect; Buttons: array[0..3] of TButton;
  begin
    Footer:=MetadataUiButton(Form,'btnMetadataPreview').Parent;
    Client:=Rect(0,0,Form.ClientWidth,Form.ClientHeight);
    R:=Footer.BoundsRect;
    Require((R.Left>=0) and (R.Top>=0) and (R.Right<=Client.Right) and (R.Bottom<=Client.Bottom),
      'Metadata footer is outside the visible dialog client');
    Buttons[0]:=MetadataUiButton(Form,'btnMetadataPreview'); Buttons[1]:=MetadataUiButton(Form,'btnMetadataApply');
    Buttons[2]:=MetadataUiButton(Form,'btnMetadataStop'); Buttons[3]:=MetadataUiButton(Form,'btnMetadataClose');
    for var I:=0 to High(Buttons) do
    begin
      CheckText(Buttons[I],False,MulDiv(8,PPI,96));
      if I>0 then Require(Buttons[I-1].BoundsRect.Right<Buttons[I].Left,
        'Metadata footer buttons overlap at minimum width');
    end;
    var Timing:=TLabel(Form.FindComponent('lblMetadataFillTiming'));
    Require(Assigned(Timing) and (Timing.Parent=Footer) and
      (Timing.BoundsRect.Bottom<Buttons[0].Top),'ETA is hidden in the scrolling body or overlaps buttons');
    CheckText(TLabel(Form.FindComponent('lblMetadataFillReason')),True);
    for var Component in Form do
    begin
      if Component is TLabel then
      begin
        if TLabel(Component).Caption<>'' then CheckText(TLabel(Component),True);
      end
      else if Component is TCheckBox then CheckText(TCheckBox(Component),False,MulDiv(12,PPI,96));
    end;
    var Scope:=TLabel(Form.FindComponent('lblMetadataFillScope'));
    var Body:=Scope.Parent.Parent as TScrollBox;
    var ScopeTop:=Scope.ClientToScreen(Point(0,0)); var BodyTop:=Body.ClientToScreen(Point(0,0));
    Require((Body.VertScrollBar.Position=0) and (ScopeTop.Y>=BodyTop.Y) and
      (ScopeTop.Y+Scope.Height<=BodyTop.Y+Body.ClientHeight),
      'Initial metadata explanation is clipped by automatic scrolling');
    Require(not Form.Busy and not MetadataUiButton(Form,'btnMetadataApply').Enabled,
      'Metadata layout or Show started an implicit scan');
    var Shot:=Form.GetFormImage;
    try
      Png.Assign(Shot); Png.SaveToFile(TPath.Combine(Artifacts,
        'metadata-'+IntToStr(PPI)+'-dark-'+IntToStr(Ord(MHLThemeDark))+'-minimum-'+IntToStr(Ord(Minimum))+'.png'));
    finally Shot.Free; end;
  end;

begin
  RequireIsolatedRegression; OriginalTheme:=MHLThemeDark; Before:=MLIReadCatalogData(CID);
  Bitmap:=TBitmap.Create; Png:=TPngImage.Create; Form:=nil;
  Artifacts:=TPath.Combine(Settings.AppPath,'metadata-fill-layout'); ForceDirectories(Artifacts);
  try
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark);
      for var PPI in TArray<Integer>.Create(96,144,192) do
      begin
        Form:=TfrmBookMetadataFill.CreateForCollection(frmMain,CID);
        try
          Form.ScaleForPPI(PPI); Form.Show; Application.ProcessMessages;
          TLabel(Form.FindComponent('lblMetadataFillTiming')).Caption:=
            'Прошло: 123 ч 59 мин · 12345,6 книг/с · Осталось: примерно 999 ч 59 мин';
          Require(Form.Font.PixelsPerInch=PPI,'Metadata form did not adopt its requested native DPI');
          CheckWindow(PPI,False);
          Form.Width:=Form.Constraints.MinWidth; Form.Height:=Form.Constraints.MinHeight;
          Application.ProcessMessages; CheckWindow(PPI,True);
          Writeln('PASS metadata form captions/footer/defaults fit normal and minimum window dark=',Ord(Dark),' dpi=',PPI); Flush(Output);
        finally Form.Free; Form:=nil; end;
      end;
    end;
    Require(MLIReadCatalogData(CID)=Before,'Metadata layout checks changed catalog data');
  finally Form.Free; Png.Free; Bitmap.Free; SetMHLTheme(OriginalTheme); end;
end;

function MetadataUiField(Form: TfrmBookMetadataFill; Field: TMetadataSyncField): TCheckBox;
begin
  Result:=TCheckBox(Form.FindComponent('cbMetadataField'+IntToStr(Ord(Field))));
  Require(Assigned(Result) and Assigned(Result.OnClick),'Metadata form checkbox is absent');
end;

procedure MetadataUiWait(Form: TfrmBookMetadataFill);
var Start, NextTrace: UInt64; Synchronized: Integer;
begin
  Start:=GetTickCount64; NextTrace:=Start; Synchronized:=0;
  Writeln('TRACE metadata UI wait begin busy=',Ord(Form.Busy)); Flush(Output);
  while Form.Busy do
  begin
    Application.ProcessMessages;
    // This console native harness has not entered Application.Run. Service
    // queued Synchronize callbacks explicitly, as the normal VCL loop does.
    if CheckSynchronize(0) then Inc(Synchronized);
    if GetTickCount64>=NextTrace then
    begin
      Writeln('TRACE metadata UI wait elapsed=',GetTickCount64-Start,' busy=',Ord(Form.Busy),
        ' synchronized=',Synchronized,' comment=',TLabel(Form.FindComponent('lblMetadataFillProgress')).Caption,
        ' reason=',TLabel(Form.FindComponent('lblMetadataFillReason')).Caption); Flush(Output);
      NextTrace:=GetTickCount64+1000;
    end;
    Require(GetTickCount64-Start<30000,'Actual metadata UI operation exceeded30seconds');
    TThread.Sleep(1);
  end;
  Writeln('TRACE metadata UI wait completed elapsed=',GetTickCount64-Start,' synchronized=',Synchronized); Flush(Output);
end;

procedure TMetadataUiModalProbe.Tick(Sender: TObject);
var Form: TfrmBookMetadataFill;
begin
  Require(GetTickCount64<=Deadline,'Actual metadata modal command did not finish within30seconds');
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookMetadataFill) and Screen.Forms[I].Visible then
    begin
      Form:=TfrmBookMetadataFill(Screen.Forms[I]);
      case Stage of
        0:
        begin
          Require(not Form.Busy,'Opening the metadata command started an automatic scan');
          if AnnotationOnly then
            for var Field:=Low(TMetadataSyncField) to High(TMetadataSyncField) do
              MetadataUiField(Form,Field).Checked:=Field=msfAnnotation;
          MetadataUiButton(Form,'btnMetadataPreview').Click; Stage:=1;
        end;
        1: if not Form.Busy then
        begin
          Require(MetadataUiButton(Form,'btnMetadataApply').Enabled,'Actual metadata command did not prepare a valid nonempty plan');
          MetadataUiButton(Form,'btnMetadataApply').Click; Stage:=2;
        end;
        2: if not Form.Busy then
        begin
          Require(Form.CommittedChanges,'Actual metadata command did not publish durable changes');
          MetadataUiButton(Form,'btnMetadataClose').Click; Stage:=3; Timer.Enabled:=False;
        end;
      end;
      Exit;
    end;
end;

procedure TestMetadataFillUI(OriginalCID: Integer);
var CID: Integer; Collection: IBookCollection; IDs: array[0..2] of Integer;
  Files, Hashes: array[0..2] of string; Before: array[0..2] of TBookRecord;
  Book: TBookRecord; Form: TfrmBookMetadataFill; Sources: TfrmCatalogSources;
  Probe: TMetadataUiModalProbe; Folder, DataBefore: string; Item: TMenuItem;
  OriginalMode: TTreeMode; OriginalPage, GuardID: Integer;
  GuardFile, AlternateRoot, GuardBefore, GuardHash: string;

  procedure SelectCollection(Value: Integer);
  var Menu: TMenuItem;
  begin
    Menu:=TMenuItem.Create(nil);
    try Menu.Tag:=Value; frmMain.miActiveCollectionClick(Menu); finally Menu.Free; end;
  end;

  procedure ExpectProtected(Index: Integer);
  begin
    Book.Clear; Collection.GetBookRecord(CreateBookKey(IDs[Index],CID),Book,True);
    Require((Book.Title=Before[Index].Title) and (Book.LibID=Before[Index].LibID) and
      (Book.FileName=Before[Index].FileName) and (Book.FileExt=Before[Index].FileExt) and
      (Book.Folder=Before[Index].Folder) and (Book.InsideNo=Before[Index].InsideNo) and
      (Book.Size=Before[Index].Size) and (Book.Rate=Before[Index].Rate) and
      (Book.Progress=Before[Index].Progress) and (Book.Review=Before[Index].Review) and
      (Book.Lang=Before[Index].Lang) and (Book.Series=Before[Index].Series) and
      (TAuthorsHelper.GetList(Book.Authors)=TAuthorsHelper.GetList(Before[Index].Authors)) and
      (Book.KeyWords=Before[Index].KeyWords),'Metadata UI changed unrelated metadata or personal state');
    Require(THashSHA2.GetHashStringFromFile(Files[Index])=Hashes[Index],'Metadata UI changed an original FB2 source');
  end;

  procedure Preview(Form: TfrmBookMetadataFill);
  begin
    MetadataUiButton(Form,'btnMetadataPreview').Click;
    Require(Form.Busy and string(TLabel(Form.FindComponent('lblMetadataFillTiming')).Caption).Contains('Осталось'),
      'Actual metadata preview does not show its initial time estimate state');
    MetadataUiWait(Form);
    Require(string(TLabel(Form.FindComponent('lblMetadataFillTiming')).Caption).Contains('Прошло:') and
      not string(TLabel(Form.FindComponent('lblMetadataFillTiming')).Caption).Contains('Осталось'),
      'Actual metadata preview retains its countdown after completion');
  end;

begin
  RequireIsolatedRegression;
  TestMetadataTiming;
  OriginalMode:=Settings.TreeModes[PAGE_SEARCH]; OriginalPage:=frmMain.pgControl.ActivePageIndex;
  Folder:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'metadata-fill-ui-fixture')); ForceDirectories(Folder);
  CID:=SystemDB.CreateCollection('Metadata UI native',Folder,'metadata-fill-ui.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID);
  for var I:=0 to High(IDs) do
  begin
    IDs[I]:=AddBook(Collection,'Metadata UI '+IntToStr(I),'UI author','ru','Preserved cycle','prose_contemporary');
    Book.Clear; Collection.GetBookRecord(CreateBookKey(IDs[I],CID),Book,True);
    Book.KeyWords:='Preserved keywords';
    if I=1 then
    begin
      Book.Publisher:='Known publisher'; Book.City:='Known city'; Book.PubYear:=1991;
      Book.ISBN:='Known ISBN'; Book.Translators:='Known translator'; Book.Annotation:='Known annotation';
    end;
    Collection.UpdateBook(Book); Collection.SetRate(Book.BookKey,5); Collection.SetProgress(Book.BookKey,61);
    Collection.SetReview(Book.BookKey,'Личная заметка — сохранить ё');
    Book.Clear; Collection.GetBookRecord(CreateBookKey(IDs[I],CID),Book,True); Before[I]:=Book;
    Files[I]:=Book.GetBookFileName;
    TFile.WriteAllText(Files[I],'<?xml version="1.0" encoding="UTF-8"?>'+
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
      '<genre>prose_contemporary</genre><author><first-name>Source</first-name><last-name>Wrong author</last-name></author>'+
      '<book-title>Wrong source title must not enter catalog</book-title><annotation><p>Новая аннотация — ё, ї, ў.</p></annotation>'+
      '<translator><first-name>Мария</first-name><last-name>Переводова</last-name></translator><lang>uk</lang></title-info>'+
      '<publish-info><publisher>Ёжик &amp; Élan</publisher><city>Москва</city><year>2024</year><isbn>978-UI-2024</isbn></publish-info>'+
      '<document-info><author><nickname>fixture</nickname></author><date value="2026-10-14">2026-10-14</date>'+
      '<id>Metadata UI '+IntToStr(I)+'</id><version>1.0</version></document-info></description>'+
      '<body><section><p>Исходный текст книги остаётся неизменным.</p></section></body></FictionBook>',TEncoding.UTF8);
    Hashes[I]:=THashSHA2.GetHashStringFromFile(Files[I]);
  end;
  Probe:=TMetadataUiModalProbe.Create; Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=10; Probe.Timer.OnTimer:=Probe.Tick;
  try
    SelectCollection(CID); ShowPage(PAGE_SEARCH); Settings.TreeModes[PAGE_SEARCH]:=tmFlat;
    TBookColumnFilters.ForTree(frmMain.tvBooksSR).Clear; frmMain.DoClearFilter(False);
    frmMain.edFTitle.Text:='="Metadata UI 0"'; frmMain.DoApplyFilter(nil);
    ExpectTitles(frmMain.tvBooksSR,['Metadata UI 0']);
    var PublisherEdit:=TMHLButtonedEdit(frmMain.FindComponent('edFPublisher'));
    PublisherEdit.Text:='Unapplied metadata draft'; frmMain.edFTitle.Text:='Unapplied title draft';
    DataBefore:=MLIReadCatalogData(CID);
    Form:=TfrmBookMetadataFill.CreateForCollection(frmMain,CID);
    try
      Form.Show; Application.ProcessMessages;
      Require(not Form.Busy and not MetadataUiButton(Form,'btnMetadataApply').Enabled,
        'Metadata form auto-started or enabled fill before comparison');
      for var Field:=Low(TMetadataSyncField) to High(TMetadataSyncField) do
        Require(MetadataUiField(Form,Field).Checked=(Field in METADATA_SYNC_DEFAULT_FIELDS),
          'Metadata default field selection is incorrect');
      Require(string(TLabel(Form.FindComponent('lblMetadataAnnotationSize')).Caption).Contains('увеличить') and
        string(TLabel(Form.FindComponent('lblMetadataAnnotationSize')).Caption).Contains('пустые описания в каталоге'),
        'Annotation checkbox does not explain catalog size');
      Preview(Form); Require(MetadataUiButton(Form,'btnMetadataApply').Enabled,'Completed preview did not enable fill');
      Require(MLIReadCatalogData(CID)=DataBefore,'Actual metadata preview changed catalog data');
      MetadataUiField(Form,msfAnnotation).Checked:=True;
      Require(MetadataUiButton(Form,'btnMetadataApply').Enabled and not Form.Busy and
        string(TLabel(Form.FindComponent('lblMetadataFillReason')).Caption).Contains('Повторно читать книги не нужно'),
        'Changing fields discarded saved annotations or started another scan');
      Require(string(TLabel(Form.FindComponent('lblMetadataAnnotationSize')).Caption).Contains('описаний: 2') and
        string(TLabel(Form.FindComponent('lblMetadataAnnotationSize')).Caption).Contains('без повторного чтения книг') and
        string(TLabel(Form.FindComponent('lblMetadataAnnotationSize')).Caption).Contains('пустых описаний в каталоге') and
        string(TLabel(Form.FindComponent('lblMetadataAnnotationSize')).Caption).Contains('примерно') and
        (TLabel(Form.FindComponent('lblMetadataCount5')).Caption='2'),
        'Annotation preview lost its actual missing count or byte estimate');
      var Estimate:=TLabel(Form.FindComponent('lblMetadataAnnotationSize'));
      var EstimateBounds:=Rect(0,0,Estimate.Width,0);
      Form.Canvas.Font.Assign(Estimate.Font);
      DrawTextW(Form.Canvas.Handle,PChar(string(Estimate.Caption)),Length(Estimate.Caption),EstimateBounds,
        DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      Require(EstimateBounds.Height<=Estimate.Height,'Completed annotation estimate is clipped');
      Require(MLIReadCatalogData(CID)=DataBefore,'Opt-in annotation preview changed catalog data');
      Form.Close;
    finally Form.Free; end;
    Writeln('PASS actual metadata form defaults, explicit preview, annotation estimate and same-plan selection perform no catalog writes'); Flush(Output);

    Item:=TMenuItem(frmMain.FindComponent('miFillBookMetadata'));
    Require(Assigned(Item) and Item.Visible and Assigned(Item.Action),'Metadata fill command is not discoverable in Collection');
    Probe.Stage:=0; Probe.AnnotationOnly:=False; Probe.Deadline:=GetTickCount64+30000; Probe.Timer.Enabled:=True;
    try Item.Click; finally Probe.Timer.Enabled:=False; end;
    Require(Probe.Stage=3,'Actual Main metadata command did not finish its preview/apply/close flow');
    ExpectTitles(frmMain.tvBooksSR,['Metadata UI 0']);
    Require((PublisherEdit.Text='Unapplied metadata draft') and (frmMain.edFTitle.Text='Unapplied title draft'),
      'Main metadata refresh consumed unfinished Search controls');
    var Loaded:=PBookRecord(frmMain.tvBooksSR.GetNodeData(frmMain.tvBooksSR.GetFirst));
    Require(Assigned(Loaded) and (Loaded.Publisher='Ёжик & Élan') and (Loaded.Annotation=''),
      'Main metadata command failed to refresh committed fields or imported unselected annotation');
    for var I:=0 to High(IDs) do
    begin
      ExpectProtected(I);
      if I=1 then
        Require((Book.Publisher='Known publisher') and (Book.City='Known city') and (Book.PubYear=1991) and
          (Book.ISBN='Known ISBN') and (Book.Translators='Known translator') and (Book.Annotation='Known annotation'),
          'Metadata fill replaced known fields')
      else Require((Book.Publisher='Ёжик & Élan') and (Book.City='Москва') and (Book.PubYear=2024) and
        (Book.ISBN='978-UI-2024') and Book.Translators.Contains('Переводова') and (Book.Annotation=''),
        'Metadata fill omitted selected missing fields or imported annotation by default');
    end;
    Writeln('PASS actual Main metadata action fills only selected missing fields, preserves known/personal/source data and applied Search snapshot'); Flush(Output);

    Sources:=TfrmCatalogSources.CreateForCollection(frmMain,Collection);
    try
      var SourceButton:=TButton(Sources.FindComponent('btnFillBookMetadata'));
      Require(Assigned(SourceButton) and SourceButton.Enabled and Assigned(SourceButton.OnClick),
        'Existing local Sources target hides explicit metadata fill command');
      Probe.Stage:=0; Probe.AnnotationOnly:=True; Probe.Deadline:=GetTickCount64+30000; Probe.Timer.Enabled:=True;
      try SourceButton.Click; finally Probe.Timer.Enabled:=False; end;
      Require((Probe.Stage=3) and Sources.MetadataChanged and not Sources.CatalogChanged,
        'Sources metadata commit was lost or incorrectly marked as a source import');
      for var I:=0 to High(IDs) do
      begin
        ExpectProtected(I);
        if I=1 then Require(Book.Annotation='Known annotation','Annotation fill replaced existing text')
        else Require(Book.Annotation.Contains('Новая аннотация — ё, ї, ў.'),'Explicit annotation opt-in lost source text');
      end;
    finally Sources.Free; end;
    Writeln('PASS Sources target exposes independent explicit metadata action and preserves known annotations, file bytes and personal records'); Flush(Output);

    GuardID:=AddBook(Collection,'Metadata UI root guard','Root guard author','ru','','prose_contemporary');
    Book.Clear; Collection.GetBookRecord(CreateBookKey(GuardID,CID),Book,True);
    GuardFile:=Book.GetBookFileName; TFile.Copy(Files[0],GuardFile,False);
    GuardHash:=THashSHA2.GetHashStringFromFile(GuardFile); GuardBefore:=MLIReadCatalogData(CID);
    AlternateRoot:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'metadata-ui-alternate-root'));
    ForceDirectories(AlternateRoot);
    TFile.Copy(GuardFile,TPath.Combine(AlternateRoot,ExtractFileName(GuardFile)),False);
    Form:=TfrmBookMetadataFill.CreateForCollection(frmMain,CID);
    try
      Form.Show; Preview(Form);
      Require(MetadataUiButton(Form,'btnMetadataApply').Enabled,'Root guard did not prepare its actual missing-field plan');
      Collection.SetProperty(PROP_ROOTFOLDER,AlternateRoot);
      MetadataUiButton(Form,'btnMetadataApply').Click; MetadataUiWait(Form);
      Require(not Form.CommittedChanges and not MetadataUiButton(Form,'btnMetadataApply').Enabled and
        string(TLabel(Form.FindComponent('lblMetadataFillReason')).Caption).Contains('не завершено'),
        'Actual metadata UI certified or retained a plan after its collection root changed');
      Require(MLIReadCatalogData(CID)=GuardBefore,'Root-changed metadata plan partially filled catalog rows');
      Require(THashSHA2.GetHashStringFromFile(GuardFile)=GuardHash,
        'Root-changed metadata plan changed its original source');
    finally
      Collection.SetProperty(PROP_ROOTFOLDER,Folder); Form.Close; Form.Free;
    end;
    Writeln('PASS actual metadata UI rejects a changed collection root before writes and requires a new explicit comparison'); Flush(Output);
    TestMetadataWizardFinish(OriginalCID);
  finally
    Probe.Timer.Enabled:=False; Probe.Timer.Free; Probe.Free;
    Settings.TreeModes[PAGE_SEARCH]:=OriginalMode;
    SelectCollection(OriginalCID); frmMain.pgControl.ActivePageIndex:=OriginalPage;
  end;
end;
