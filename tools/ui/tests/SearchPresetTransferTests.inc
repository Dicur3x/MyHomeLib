// Actual preset-menu actions and file dialogs, plus independent storage oracles.
// Run against the isolated main form and its current One collection.
type
  TSPTDialogDriver = class
  public
    Timer: TTimer;
    Title, FileName, Failure: string;
    Cancel, Seen: Boolean;
    BeforeAccept: TProc;
    constructor Create;
    destructor Destroy; override;
    procedure Tick(Sender: TObject);
  end;

constructor TSPTDialogDriver.Create;
begin
  inherited Create; Timer:=TTimer.Create(nil); Timer.Interval:=25; Timer.Enabled:=False; Timer.OnTimer:=Tick;
end;

destructor TSPTDialogDriver.Destroy;
begin Timer.Free; inherited; end;

procedure TSPTDialogDriver.Tick(Sender: TObject);
var Window, Next, Edit, Combo: HWND; PID: DWORD; Caption, ClassName: array[0..511] of Char;
begin
  Window:=GetTopWindow(0);
  while Window<>0 do
  begin
    Next:=GetWindow(Window,GW_HWNDNEXT); PID:=0; GetWindowThreadProcessId(Window,@PID);
    if (PID=GetCurrentProcessId) and IsWindowVisible(Window) and
      (GetClassName(Window,ClassName,Length(ClassName))>0) and (string(PChar(@ClassName[0]))='#32770') then
    begin
      GetWindowText(Window,Caption,Length(Caption));
      if string(PChar(@Caption[0]))=Title then
      begin
        Seen:=True; Timer.Enabled:=False;
        try
          if Assigned(BeforeAccept) then BeforeAccept();
          if Cancel then begin PostMessage(Window,WM_COMMAND,IDCANCEL,0); Exit; end;
          // Classic Explorer filename controls: edt1 or the edit of cmb13.
          Edit:=GetDlgItem(Window,$0480);
          if Edit=0 then
          begin
            Combo:=GetDlgItem(Window,$047C);
            if Combo<>0 then
            begin
              Edit:=HWND(SendMessage(Combo,WM_USER+7,0,0)); // CBEM_GETEDITCONTROL
              if Edit=0 then Edit:=FindWindowEx(Combo,0,'Edit',nil);
            end;
          end;
          if Edit=0 then raise Exception.Create('The controlled file picker filename edit is absent');
          if not SetWindowText(Edit,PChar(FileName)) then RaiseLastOSError;
          PostMessage(Window,WM_COMMAND,IDOK,0);
        except
          on E: Exception do begin Failure:=E.ClassName+': '+E.Message; PostMessage(Window,WM_COMMAND,IDCANCEL,0); end;
        end;
        Exit;
      end;
    end;
    Window:=Next;
  end;
end;

procedure TestSearchPresetTransfer(const One: IBookCollection; OneID: Integer);
var
  Root, InternalFile, SourceXML, LegacyFile, LegacyCXML, SelectedXML, AllXML, CancelXML: string;
  Name, LongAuthors, RawField, BeforeData, BeforeProfile, BeforeSource, BeforeDisk, DraftAuthors, DraftTitle: string;
  Source, Target, Reopened: TSearchPresets; Preset, OldObject: TSearchPreset;
  Driver: TSPTDialogDriver; OldDialogs: Boolean; OldPPI: Integer; OldAttributes: DWORD;
  MenuImport, MenuSelected, MenuAll: TMenuItem; MenuButton: TButton; Publisher: TMHLButtonedEdit;
  Failure, OldTheme: Boolean; Locked: TFileStream; Imported: Integer;

  function StorageSnapshot(Presets: TSearchPresets): string;
  var Names: TStringList; Builder: TStringBuilder;
  begin
    Names:=TStringList.Create; Builder:=TStringBuilder.Create;
    try
      Builder.Append(Presets.Count).Append(#13);
      for var Entry in Presets do
      begin
        Builder.Append(Length(Entry.DisplayName)).Append(':').Append(Entry.DisplayName).Append(#13);
        Names.Clear; for var Field in Entry do Names.Add(Field.Key); Names.Sort;
        for var Key in Names do
          Builder.Append(Length(Key)).Append(':').Append(Key).Append(':').Append(Length(Entry[Key])).Append(':').Append(Entry[Key]).Append(#13);
      end;
      Result:=THashSHA2.GetHashString(Builder.ToString);
    finally Builder.Free; Names.Free; end;
  end;

  function DataSnapshot: string;
  var DB: TSQLiteDatabase; Rows: TSQLiteQuery; Builder: TStringBuilder;
  begin
    Builder:=TStringBuilder.Create;
    try
      for var FileName in TArray<string>.Create(SystemDB.GetCollectionInfo(OneID).DBFileName,Settings.SystemFileName[sfSystemDB]) do
      begin
        DB:=TSQLiteDatabase.CreateReadOnly(FileName);
        try
          Rows:=DB.NewQuery('SELECT type,name,sql FROM sqlite_master WHERE type IN (''table'',''index'',''trigger'') ORDER BY type,name');
          try
            Rows.Open;
            while not Rows.Eof do
            begin
              for var C:=0 to Rows.ColCount-1 do
                Builder.Append(Length(Rows.FieldAsString(C))).Append(':').Append(Rows.FieldAsString(C));
              Builder.Append(#13); Rows.Next;
            end;
          finally Rows.Free; end;
          Rows:=DB.NewQuery('SELECT BookID,quote(LibID),quote(Title),Rate,Progress,hex(Annotation),hex(Review),IsDeleted,IsLocal FROM Books ORDER BY BookID');
          try
            Rows.Open;
            while not Rows.Eof do
            begin
              for var C:=0 to Rows.ColCount-1 do
                Builder.Append(Length(Rows.FieldAsString(C))).Append(':').Append(Rows.FieldAsString(C));
              Builder.Append(#13); Rows.Next;
            end;
          finally Rows.Free; end;
          if SameFileName(FileName,Settings.SystemFileName[sfSystemDB]) then
          begin
            for var Query in TArray<string>.Create(
              'SELECT GroupID,quote(GroupName),AllowDelete FROM Groups ORDER BY GroupID',
              'SELECT BookID,DatabaseID,GroupID FROM BookGroups ORDER BY GroupID,DatabaseID,BookID') do
            begin
              Rows:=DB.NewQuery(Query);
              try
                Rows.Open;
                while not Rows.Eof do
                begin
                  for var C:=0 to Rows.ColCount-1 do
                    Builder.Append(Length(Rows.FieldAsString(C))).Append(':').Append(Rows.FieldAsString(C));
                  Builder.Append(#13); Rows.Next;
                end;
              finally Rows.Free; end;
            end;
          end;
        finally DB.Free; end;
      end;
      Result:=THashSHA2.GetHashString(Builder.ToString);
    finally Builder.Free; end;
  end;

  procedure Reopen;
  begin FreeAndNil(Reopened); Reopened:=TSearchPresets.Create; Reopened.Load(InternalFile); end;

  procedure SelectPreset(const Value: string);
  begin frmMain.cbPresetName.Text:=Value; frmMain.cbPresetNameSelect(nil); end;

  procedure CheckProtected;
  begin
    Require(DataSnapshot=BeforeData,'Preset transfer changed schema, catalog or saved personal book fields');
    Require(THashSHA2.GetHashStringFromFile(SourceXML)=BeforeSource,'Preset import rewrote the source XML');
    if BeforeProfile='' then Require(not FileExists(Settings.SettingsFileName),'Preset transfer unexpectedly created a main profile')
    else Require(THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=BeforeProfile,'Preset transfer changed main settings/history profile');
    Require(Length(TDirectory.GetFiles(Settings.WorkPath,'*.homelib-*.tmp'))=0,'Preset transfer left an owned publication temporary file');
  end;

  procedure Action(Menu: TMenuItem; const DialogTitle, FileName: string; Cancel: Boolean; BeforeAccept: TProc=nil);
  begin
    Require(Assigned(Menu) and Assigned(Menu.OnClick),'Preset transfer menu action is absent');
    Driver.Title:=DialogTitle; Driver.FileName:=FileName; Driver.Cancel:=Cancel;
    Driver.BeforeAccept:=BeforeAccept; Driver.Seen:=False; Driver.Failure:=''; Driver.Timer.Enabled:=True;
    Writeln('TRACE preset transfer actual menu=',Menu.Name,' dialog=',DialogTitle,' cancel=',BoolToStr(Cancel,True)); Flush(Output);
    try Menu.OnClick(Menu); finally Driver.Timer.Enabled:=False; Driver.BeforeAccept:=nil; end;
    Require(Driver.Seen and (Driver.Failure=''),'Actual preset file-picker action was not exercised: '+Driver.Failure);
  end;

  procedure InvalidLoad(const FileName: string; Friendly: Boolean);
  var Previous: string;
  begin
    Previous:=StorageSnapshot(Target); OldObject:=Target.GetPreset('Protected'); Failure:=False;
    try Target.Load(FileName);
    except
      on E: EAccessViolation do raise;
      on E: Exception do begin Failure:=True; if Friendly then Require(E.Message.Contains('пресет'),'Invalid preset lacked a useful error'); end;
    end;
    Require(Failure and (StorageSnapshot(Target)=Previous) and (Target.GetPreset('Protected')=OldObject),
      'Failed load partially imported an earlier valid entry or replaced old in-memory objects');
  end;

begin
  RequireIsolatedRegression; Require(Assigned(frmMain) and (One.CollectionID=OneID),'Preset transfer requires isolated current collection');
  InternalFile:=Settings.SystemFileName[sfPresets];
  Require(not FileExists(InternalFile) and (frmMain.cbPresetName.Items.Count=0),'Preset transfer requires a new profile');
  Publisher:=frmMain.FindComponent('edFPublisher') as TMHLButtonedEdit;
  Require(Assigned(Publisher) and (Publisher.Text=''),
    'Fresh publisher search field contains its component name as an unexpected criterion');
  Root:=TPath.Combine(Settings.AppPath,'preset-transfer-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  SourceXML:=TPath.Combine(Root,'Авторы — перенос.xml'); LegacyFile:=TPath.Combine(Root,'legacy.cxml2');
  LegacyCXML:=TPath.Combine(Root,'legacy.cxml'); SelectedXML:=TPath.Combine(Root,'selected.xml');
  AllXML:=TPath.Combine(Root,'all.xml'); CancelXML:=TPath.Combine(Root,'canceled.xml');
  Name:='Импорт авторов — ё, ї, ў, 中文'; RawField:='  & <граница> ]]> 中文 '+#$D83D+#$DE00+'  ';
  LongAuthors:='="IMPORT AUTHOR A ALEX" OR ="IMPORT AUTHOR B ALEX"';
  for var I:=1 to 220 do LongAuthors:=LongAuthors+' OR ="UNRELATED '+StringOfChar('x',70)+IntToStr(I)+'"';
  Require(Length(LongAuthors)>18000,'Author-list fixture is not long');
  Source:=TSearchPresets.Create; Target:=TSearchPresets.Create; Reopened:=nil; Driver:=TSPTDialogDriver.Create; Locked:=nil;
  OldDialogs:=Vcl.Dialogs.UseLatestCommonDialogs; OldPPI:=frmMain.Font.PixelsPerInch; OldTheme:=MHLThemeDark;
  try
    // Source export uses the same legacy schema, with Unicode and a CDATA end
    // marker that previously made an unreadable file. Expected values are literal.
    Preset:=Source.GetPreset(Name); Preset.AddOrSetValue(SF_AUTHORS,LongAuthors);
    Preset.AddOrSetValue(SF_TITLE,'LIKE "PRESET IMPORT%"'); Preset.AddOrSetValue(SF_PUBLISHER,'="Издательство ё"');
    Preset.AddOrSetValue(SF_LANG,'-1'); Preset.AddOrSetValue(SF_DATE,'-1'); Preset.AddOrSetValue(SF_LIBRATE,'-1');
    Preset.AddOrSetValue(SF_DELETED,BoolToStr(Settings.HideDeletedBooks));
    Preset.AddOrSetValue(SF_FAVORITE_AUTHORS,'False'); Preset.AddOrSetValue('Unknown preserved field',RawField);
    Source.Save(SourceXML); Source.Save(LegacyFile); Source.Save(LegacyCXML);
    var ReadableXML:=TFile.ReadAllText(SourceXML,TEncoding.UTF8);
    Require(ReadableXML.Contains('</Field>'+#13#10), 'Editable preset XML has no line break after a field');
    Require(not ReadableXML.Contains('</Field><Field'), 'Editable preset fields share one line');
    for var FileName in TArray<string>.Create(SourceXML,LegacyFile,LegacyCXML) do
    begin
      Target.Clear; Target.Load(FileName);
      Require((Target.Count=1) and (StorageSnapshot(Target)=StorageSnapshot(Source)),
        'Editable XML/legacy compressed reopen lost authors, query, Unicode or CDATA characters');
    end;
    Writeln('PASS preset transfer editable XML and legacy cxml2-cxml preserve long author expressions, Unicode, special characters and unknown fields');

    Target.Clear; Target.GetPreset('Protected').AddOrSetValue(SF_AUTHORS,'Exact protected authors');
    var Invalid:=TPath.Combine(Root,'missing-name.xml');
    TFile.WriteAllText(Invalid,'<Presets><Preset displayName="Protected"><Field displayName="Authors">Changed</Field></Preset>'+
      '<Preset><Field displayName="Authors">Partial</Field></Preset></Presets>',TEncoding.UTF8);
    InvalidLoad(Invalid,True);
    Invalid:=TPath.Combine(Root,'missing-field-name.xml');
    TFile.WriteAllText(Invalid,'<Presets><Preset displayName="Protected"><Field displayName="Authors">Changed</Field></Preset>'+
      '<Preset displayName="Partial"><Field>Bad key</Field></Preset></Presets>',TEncoding.UTF8); InvalidLoad(Invalid,True);
    Invalid:=TPath.Combine(Root,'wrong-root.xml'); TFile.WriteAllText(Invalid,'<UserData/>',TEncoding.UTF8); InvalidLoad(Invalid,True);
    Invalid:=TPath.Combine(Root,'broken.xml'); TFile.WriteAllText(Invalid,'<Presets><Preset',TEncoding.UTF8); InvalidLoad(Invalid,False);
    Invalid:=TPath.Combine(Root,'blocked-dtd.xml');
    TFile.WriteAllText(Invalid,'<!DOCTYPE Presets SYSTEM "file:///not-a-preset.dtd"><Presets/>',TEncoding.UTF8); InvalidLoad(Invalid,False);
    Writeln('PASS preset transfer validates the entire input before merge, malformed names-fields-roots-XML-DTD leave old memory objects unchanged');

    // Catalog rows are deliberately different: both author OR branches must
    // work after actual menu import/selection/Apply, publisher remains a criterion.
    for var I:=0 to 2 do
    begin
      var AuthorName:='IMPORT AUTHOR A'; if I=1 then AuthorName:='IMPORT AUTHOR B' else if I=2 then AuthorName:='UNWANTED AUTHOR';
      var ID:=AddBook(One,'PRESET IMPORT '+IntToStr(I),AuthorName,'ru','','0.1');
      var Book: TBookRecord; One.GetBookRecord(CreateBookKey(ID,OneID),Book,True);
      // The shared AddBook fixture stores LastName plus FirstName='Alex'.
      // Exact author expressions must match that full name, not only its surname.
      Require((Length(Book.Authors)=1) and (Book.Authors[0].GetFullName=AuthorName+' Alex'),
        'Preset transfer fixture full author differs from the literal exact-author expression');
      Book.Publisher:='Издательство ё'; One.UpdateBook(Book);
    end;
    // An untouched publisher must not silently constrain an explicit LIKE title search.
    var QueryMode:=frmMain.FindComponent('SearchQueryModeControl') as TSearchQueryModeControl;
    Require(Assigned(QueryMode),'Preset transfer search query-mode control is missing');
    QueryMode.Mode:=sqmExpression;
    frmMain.edFFullName.Text:=''; frmMain.edFTitle.Text:='LIKE "PRESET IMPORT%"';
    Require(Publisher.Text='','Fixture setup unexpectedly filled the untouched publisher field');
    Writeln('TRACE preset transfer untouched publisher explicit LIKE title Apply'); Flush(Output);
    frmMain.DoApplyFilter(nil); ExpectTitles(frmMain.tvBooksSR,['PRESET IMPORT 0','PRESET IMPORT 1','PRESET IMPORT 2']);
    frmMain.DoClearFilter(True);
    Require(QueryMode.Mode=sqmText,'Clear retained the preset-transfer expression mode');
    frmMain.cbPresetName.Text:=Name; frmMain.edFFullName.Text:='Protected old author filter'; frmMain.edFTitle.Text:='Protected old title';
    frmMain.SaveSearchPreset(nil); Reopen;
    Require((Reopened.Count=1) and (Reopened.GetPreset(Name).Items[SF_PUBLISHER]=''),
      'First saved preset contains a component-name publisher criterion');
    BeforeData:=DataSnapshot; BeforeSource:=THashSHA2.GetHashStringFromFile(SourceXML);
    BeforeProfile:=''; if FileExists(Settings.SettingsFileName) then BeforeProfile:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
    MenuImport:=frmMain.FindComponent('miSearchPresetImport') as TMenuItem;
    MenuSelected:=frmMain.FindComponent('miSearchPresetExport') as TMenuItem;
    MenuAll:=frmMain.FindComponent('miSearchPresetExportAll') as TMenuItem;
    MenuButton:=frmMain.FindComponent('btnSearchPresetTransfer') as TButton;
    Publisher:=frmMain.FindComponent('edFPublisher') as TMHLButtonedEdit;
    Require(Assigned(Publisher) and Assigned(MenuButton),'Preset transfer menu or publisher search input is absent');
    Vcl.Dialogs.UseLatestCommonDialogs:=False;
    DraftAuthors:='Unapplied draft author'; DraftTitle:='Unapplied draft title';
    frmMain.edFFullName.Text:=DraftAuthors; frmMain.edFTitle.Text:=DraftTitle;
    var BeforeName:=frmMain.cbPresetName.Text;
    Action(MenuImport,'Импорт пресетов поиска',SourceXML,False);
    Require((frmMain.edFFullName.Text=DraftAuthors) and (frmMain.edFTitle.Text=DraftTitle) and
      (frmMain.cbPresetName.Text=BeforeName),'Import erased or applied unsaved search fields/name');
    Reopen; Require(Reopened.Count=2,'Import did not add one colliding name as a separate preset');
    Require((Reopened.GetPreset(Name).Items[SF_AUTHORS]='Protected old author filter') and
      (Reopened.GetPreset(Name+' (2)').Items[SF_AUTHORS]=LongAuthors),'Name collision overwrote old authors or lost imported authors');
    Require(Reopened.GetPreset(Name+' (2)').Items['Unknown preserved field']=RawField,'Import dropped an unknown field');
    ExpectTitles(frmMain.tvBooksSR,[]); CheckProtected;
    SelectPreset(Name+' (2)');
    Require(QueryMode.Mode=sqmLegacy,'Selecting an imported old preset did not restore legacy query mode');
    Require((frmMain.edFFullName.Text=LongAuthors) and (Publisher.Text='="Издательство ё"'),
      'Selecting an imported preset lost author/publisher criteria');
    ExpectTitles(frmMain.tvBooksSR,[]);
    Writeln('TRACE preset transfer Apply collection=',One.CollectionID,' authors_length=',Length(frmMain.edFFullName.Text),
      ' authors_prefix=',Copy(frmMain.edFFullName.Text,1,80),' title=',frmMain.edFTitle.Text,
      ' publisher=',Publisher.Text,' lang=',frmMain.cbLang.Text,' date=',frmMain.cbDate.Text,
      ' rate=',frmMain.cbLibRate.Text,' downloaded=',frmMain.cbDownloaded.ItemIndex,
      ' deleted=',BoolToStr(Settings.HideDeletedBooks,True),' readed=',BoolToStr(frmMain.cbReaded.Checked,True)); Flush(Output);
    frmMain.DoApplyFilter(nil);
    ExpectTitles(frmMain.tvBooksSR,['PRESET IMPORT 0','PRESET IMPORT 1']); CheckProtected;
    Writeln('PASS preset transfer actual import menu keeps draft and old names, imported long author OR and publisher criteria apply to the correct books');

    // The real selected-export action snapshots before its file picker. Change
    // the current selection while the dialog is open; exported data stays chosen.
    Action(MenuSelected,'Экспорт пресетов поиска',SelectedXML,False,
      procedure begin frmMain.cbPresetName.Text:=Name; end);
    Target.Clear; Target.Load(SelectedXML);
    Require((Target.Count=1) and (Target.GetPreset(Name+' (2)').Items[SF_AUTHORS]=LongAuthors),
      'Selected export used a changed modal selection or unsaved edit');
    Action(MenuAll,'Экспорт пресетов поиска',AllXML,False);
    Target.Clear; Target.Load(AllXML); Reopen;
    Require(StorageSnapshot(Target)=StorageSnapshot(Reopened),'Export-all lost a preset or changed its fields'); CheckProtected;
    BeforeDisk:=THashSHA2.GetHashStringFromFile(InternalFile);
    Action(MenuImport,'Импорт пресетов поиска',SourceXML,True);
    Action(MenuSelected,'Экспорт пресетов поиска',CancelXML,True);
    Require(not FileExists(CancelXML) and (THashSHA2.GetHashStringFromFile(InternalFile)=BeforeDisk),
      'Canceled import/export wrote an output or changed internal presets');
    Writeln('PASS preset transfer actual selected-all export snapshots and file-dialog cancellation preserve names, fields and internal data');

    // Direct file APIs are the same transaction called by the menu actions.
    Failure:=False; try frmMain.ImportSearchPresetsFromFile(Invalid); except on E: Exception do Failure:=True; end;
    Require(Failure and (THashSHA2.GetHashStringFromFile(InternalFile)=BeforeDisk),'Bad import replaced the last complete disk file');
    Locked:=TFileStream.Create(InternalFile,fmOpenRead or fmShareExclusive);
    try Failure:=False; try frmMain.ImportSearchPresetsFromFile(SourceXML); except on E: Exception do Failure:=True; end;
      Require(Failure,'Locked import unexpectedly succeeded'); finally FreeAndNil(Locked); end;
    Require(THashSHA2.GetHashStringFromFile(InternalFile)=BeforeDisk,'Locked import truncated presets');
    OldAttributes:=GetFileAttributes(PChar(InternalFile)); Require(OldAttributes<>INVALID_FILE_ATTRIBUTES,'Preset attributes missing');
    Require(SetFileAttributes(PChar(InternalFile),OldAttributes or FILE_ATTRIBUTE_READONLY),'Could not mark presets read-only');
    try Failure:=False; try frmMain.ImportSearchPresetsFromFile(SourceXML); except on E: Exception do Failure:=True; end;
      Require(Failure and (THashSHA2.GetHashStringFromFile(InternalFile)=BeforeDisk),'Read-only import changed the prior file');
    finally Require(SetFileAttributes(PChar(InternalFile),OldAttributes),'Could not restore preset attributes'); end;
    Failure:=False; try frmMain.ExportSearchPresetsToFile(InternalFile,False); except on E: Exception do Failure:=True; end;
    Require(Failure and (THashSHA2.GetHashStringFromFile(InternalFile)=BeforeDisk),'Selected export overwrote the internal preset store');
    Imported:=frmMain.ImportSearchPresetsFromFile(LegacyFile); Reopen;
    Require((Imported=1) and (Reopened.Count=3) and (Reopened.GetPreset(Name+' (3)').Items[SF_AUTHORS]=LongAuthors),
      'Legacy import or repeated-name suffix failed'); CheckProtected;
    Writeln('PASS preset transfer legacy import, invalid-locked-readonly failures and self-export guard preserve old disk, memory and source data');

    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark);
      for var PPI in TArray<Integer>.Create(96,144,192) do
      begin
      frmMain.ScaleForPPI(PPI); Application.ProcessMessages;
      Require((MenuButton.Parent=frmMain.cbPresetName.Parent) and
        (MenuButton.Left>=frmMain.cbPresetName.Left+frmMain.cbPresetName.Width) and
        (MenuButton.Left+MenuButton.Width<=frmMain.btnSavePreset.Left) and
        (MenuButton.Top+MenuButton.Height<=MenuButton.Parent.ClientHeight),
        'Compact preset menu overlaps the combo/buttons or increases the row at DPI '+IntToStr(PPI));
      end;
    end;
    frmMain.ScaleForPPI(OldPPI); SetMHLTheme(OldTheme); CheckProtected;
    Writeln('PASS preset transfer compact menu stays inside existing preset row at96-144-192DPI in both themes without widening search');
  finally
    Locked.Free; Driver.Free; Vcl.Dialogs.UseLatestCommonDialogs:=OldDialogs; SetMHLTheme(OldTheme);
    Reopened.Free; Target.Free; Source.Free;
  end;
end;
