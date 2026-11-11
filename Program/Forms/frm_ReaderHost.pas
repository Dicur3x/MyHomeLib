unit frm_ReaderHost;

interface

uses System.Classes, System.SysUtils, Winapi.Messages, Vcl.Forms, Vcl.Controls, Vcl.Menus, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.ImgList, System.IniFiles, System.Generics.Collections, unit_Globals, frm_ProgramUpdate,
  System.Threading, unit_ReaderSession, unit_BookSaveContinuation,
  unit_ReaderAnnotations;

type
  TfrmReaderHost = class(TForm)
  private type
    TRecentBook = record
      FileName: string;
      Members: TArray<string>;
      Title, Author, Cover: string;
    end;
  private
    FRecent: TList<TRecentBook>;
    FCatalogueRecentSelection: Integer;
    FRecentView: TListBox;
    FHomeView: TForm;
    FHomeList: TListView;
    FHomeImages: TImageList;
    FHomeStatus: TLabel;
    FUseStartPage, FRecentMetadataPending: Boolean;
    FStatus: TLabel;
    FTimer: TTimer;
    FView: TCustomForm;
    FUpdates: TfrmProgramUpdate;
    FBook, FExportBook: TBookRecord;
    FCurrentFile, FNextFile, FPendingComponent: string;
    FPreparing, FDisplaying, FExitRequested: Boolean;
    FNextSession: string;
    FNoteTarget: TReaderAnnotation;
    FExpectedMembers, FOpenedMembers: TArray<string>;
    FArchiveAmbiguous, FOfferFollowingComic, FCanFollowComic, FNextVolumePending: Boolean;
    FFollowingComic: IFuture<string>;
    FSession: TReaderSessionRequest;
    FRestartRequest: TReaderSessionRequest;
    FRestartLease: TReaderSessionLease;
    FSessionReply: TReaderSessionReply;
    FSessionLease: TReaderSessionLease;
    FRestarting, FDirectLaunch: Boolean;
    FNextCleanupCheck: UInt64;
    FReaderClosedActive, FExitViaMenu, FHostCloseRequested: Boolean;
    FPreviousViewClose: TCloseEvent;
    FSaveContinuation: TBookSaveContinuation;
    FResumingSave: Boolean;
    procedure ResumeBookSave(var Message: TMessage); message WM_RESUME_BOOK_SAVE;
    procedure BeginSession(const RequestFile: string);
    procedure SendSessionState(const State: string; const ErrorText: string = '');
    procedure ConfirmSessionOpened;
    procedure FinishSession(const State: string);
    procedure InstallMenu(Form: TForm);
    procedure OpenClick(Sender: TObject);
    procedure HomeCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure HomeRecentClick(Sender: TObject);
    procedure HomeRecentKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ResizeHomeRecent(Sender: TObject);
    procedure SetStatus(const Value: string);
    procedure WMDropFiles(var Message: TWMDropFiles); message WM_DROPFILES;
    procedure OfferDroppedBook(Target: TCustomForm; var Message: TWMDropFiles);
    procedure RecentClick(Sender: TObject);
    procedure RecentViewClick(Sender: TObject);
    procedure RecentViewKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure NotesClick(Sender: TObject);
    procedure OpenNote(const Note: TReaderAnnotation);
    procedure QueueFile(const FileName: string; const Note: TReaderAnnotation;
      const ArchiveMembers: TArray<string>);
    procedure SaveClick(Sender: TObject);
    procedure ExitClick(Sender: TObject);
    procedure ComponentsClick(Sender: TObject);
    procedure FormatsClick(Sender: TObject);
    procedure AssociationsClick(Sender:TObject);
    procedure DiagnosticsClick(Sender: TObject);
    procedure CacheSettingsClick(Sender: TObject);
    procedure ToggleFollowingComic(Sender: TObject);
    procedure LookForFollowingBook;
    procedure OfferFollowingBook;
    function ConfirmBookOpen(Target: TCustomForm;
      const DialogName, Title, Prompt, BookCaption, CancelCaption: string): Boolean;
    procedure EnsureUpdates;
    procedure RestartForUpdate(Sender: TObject);
    procedure ComponentCancelled(Sender: TObject);
    procedure Tick(Sender: TObject);
    procedure BookViewClosing(Sender: TObject; var Action: TCloseAction);
    procedure CheckModuleCleanup(AfterReading: Boolean = False);
    procedure Prepare(const FileName: string);
    procedure Display(const FileName: string);
    procedure MissingComponent(const ID: string);
    procedure MissingComponents(const IDs: TArray<string>);
    procedure ReadRecent(Ini: TCustomIniFile);
    function RecentCaption(Index: Integer): string;
    procedure OpenRecent(Index: Integer);
    procedure CatalogueRecentClick(Sender: TObject);
    procedure RefreshRecentView;
    procedure RememberFile(const FileName: string; const Members: TArray<string>;
      const Title, Author, Cover: string);
    procedure SaveRestartState(const Identity, SettingsFile, OriginalMember: string);
    procedure ClearRestartState;
    procedure HostCloseQuery(Sender: TObject; var CanClose: Boolean);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure OpenInitialFile(const FileName: string);
    procedure OpenInitialSession(const RequestFile: string);
    procedure ShowStartPage;
    procedure OpenFile(const FileName: string);
  end;

var ReaderHost: TfrmReaderHost;

implementation

uses System.IOUtils, System.JSON, System.Math, System.NetEncoding, Vcl.Dialogs, Vcl.Imaging.jpeg,
  Vcl.Graphics, Winapi.Windows, Winapi.ShellAPI, unit_FileBooks, unit_Settings, unit_AtomicIniFile, unit_FileMutex,
  unit_ReaderCache, unit_ReaderDocument, unit_ReaderFormats, unit_ReaderRaster, unit_BookCache,
  unit_BookSendOptions, unit_BookExportResults, unit_ComponentUpdates,
  unit_ProgramUpdateInstaller, unit_Diagnostics, unit_MHLTheme, unit_MHLExternalTools, dm_user,
  frm_BuiltinReader, frm_StoryReader, frm_ReaderCacheSettings, unit_ReaderPalette,
  unit_ReaderRestartState, unit_ReaderNoteBooks, unit_ComponentUsage, unit_ComponentRemoval,
  frm_ComponentMaintenance, unit_ExplorerImport, frm_ReaderAssociations;

type
  TStandaloneBookReader = class(TfrmBuiltinReader)
  private
    procedure WMDropFiles(var Message: TWMDropFiles); message WM_DROPFILES;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;
  TStandaloneStoryReader = class(TfrmStoryReader)
  private
    procedure WMDropFiles(var Message: TWMDropFiles); message WM_DROPFILES;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

const
  MR_CATALOGUE_RECENT = 101;
  MR_CATALOGUE_NEXT_VOLUME = 102;

function ArchiveMembersJSON(const Members: TArray<string>): string;
var Entries: TJSONArray;
begin
  Entries:=TJSONArray.Create;
  try
    for var Member in Members do Entries.Add(Member);
    Result:=Entries.ToJSON;
  finally Entries.Free; end;
end;

function StandaloneHistory(const Book: TBookRecord; const Members: TArray<string>): string;
begin
  Result:=ReaderHistoryName(Book,'');
  if Length(Members)>0 then Result:=Result+#1+ReaderNoteIdentity(ArchiveMembersJSON(Members));
end;

function TryArchiveMembers(const JSON: string; out Members: TArray<string>): Boolean;
var Value: TJSONValue; Entries: TJSONArray;
begin
  Result:=False; Members:=nil;
  Value:=TJSONObject.ParseJSONValue(JSON);
  try
    if not (Value is TJSONArray) then Exit;
    Entries:=TJSONArray(Value);
    if Entries.Count>10 then Exit;
    SetLength(Members,Entries.Count);
    for var I:=0 to Entries.Count-1 do
    begin
      if not (Entries.Items[I] is TJSONString) then Exit;
      Members[I]:=Entries.Items[I].Value;
      if (Members[I]='') or (Pos(#0,Members[I])>0) then Exit;
    end;
    Result:=True;
  finally Value.Free; end;
end;

function FindStandaloneNoteSource(const SettingsFile, BookID: string;
  out FileName: string; out Members: TArray<string>): Boolean;
var Ini: TMemIniFile; Section: string;
begin
  Result:=False; FileName:=''; Members:=nil;
  Section:='Book.'+BookID;
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try
    FileName:=Ini.ReadString(Section,'StandaloneFile','');
    if (FileName='') or not TPath.IsPathRooted(FileName) or not FileExists(FileName) then Exit;
    if not TryArchiveMembers(Ini.ReadString(Section,'StandaloneArchive','[]'),Members) then Exit;
    var Book:=FileBook(FileName);
    Result:=(ReaderNoteIdentity(StandaloneHistory(Book,Members))=BookID) or
      (ReaderNoteIdentity(ReaderHistoryName(Book,''))=BookID);
  finally Ini.Free; end;
end;

procedure BindStandaloneNoteSource(const SettingsFile, FileName: string; const Book: TBookRecord;
  const Members: TArray<string>; Ambiguous: Boolean; var Identity: string);
var Ini: TMemIniFile; Section, Archive, OldArchive, MemberIdentity, MemberSection: string;
begin
  Section:='Book.'+ReaderNoteIdentity(Identity); Archive:=ArchiveMembersJSON(Members);
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try
    if Length(Members)>0 then
    begin
      // A previously unambiguous ZIP keeps its original history when other
      // books are added. New multi-book archives have separate histories.
      OldArchive:=Ini.ReadString(Section,'StandaloneArchive','');
      MemberIdentity:=StandaloneHistory(Book,Members);
      MemberSection:='Book.'+ReaderNoteIdentity(MemberIdentity);
      if (OldArchive<>Archive) and
        (Ambiguous or (OldArchive<>'') or Ini.ValueExists(MemberSection,'StandaloneFile')) then
      begin Identity:=MemberIdentity; Section:=MemberSection; end;
    end;
    if (Ini.ReadString(Section,'StandaloneFile','')=FileName) and
      (Ini.ReadString(Section,'StandaloneArchive','')=Archive) then Exit;
    Ini.WriteString(Section,'StandaloneFile',FileName);
    Ini.WriteString(Section,'StandaloneArchive',Archive);
    SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
end;
procedure TStandaloneBookReader.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW or WS_EX_ACCEPTFILES) and not WS_EX_TOOLWINDOW;
end;

procedure TStandaloneStoryReader.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW or WS_EX_ACCEPTFILES) and not WS_EX_TOOLWINDOW;
end;

procedure TStandaloneBookReader.WMDropFiles(var Message: TWMDropFiles);
begin
  TfrmReaderHost(Owner).OfferDroppedBook(Self,Message);
end;

procedure TStandaloneStoryReader.WMDropFiles(var Message: TWMDropFiles);
begin
  TfrmReaderHost(Owner).OfferDroppedBook(Self,Message);
end;

constructor TfrmReaderHost.Create(AOwner: TComponent);
var Intro: TLabel; OpenButton: TButton; Ini: TMemIniFile; Value, NoteFile: string;
begin
  inherited CreateNew(AOwner);
  ConfigureComponentUsage(Settings.AppPath);
  try for var MessageText in RecoverComponentRemovals(Settings.AppPath) do LogDiagnosticMessage('module-recovery',MessageText);
  except on E: Exception do LogDiagnosticError('module-recovery',E); end;
  ObserveInstalledOptionalComponents(Settings.AppPath,True);
  Name:='ReaderHost'; Caption:='HomeLibre Reader'; Position:=poScreenCenter;
  Icon.LoadFromResourceName(HInstance,'ZZ_HOME_LIBRE_READER_ICON');
  Font.Name:='Segoe UI'; Font.Size:=10; ClientWidth:=720; ClientHeight:=430;
  Constraints.MinWidth:=520; Constraints.MinHeight:=350;
  OnCloseQuery:=HostCloseQuery;
  FRecent:=TList<TRecentBook>.Create;
  Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
  try
    Value:=Ini.ReadString('ReaderSession','PendingFile','');
    if FileExists(Value) then FNextFile:=Value;
    Value:=Ini.ReadString('ReaderSession','PendingSession','');
    if FileExists(Value) then begin FNextSession:=Value; FNextFile:=''; end;
    Value:=Ini.ReadString('ReaderSession','PendingNoteBook','');
    if (FNextFile<>'') and (Value<>'') then
      try
        if FindStandaloneNoteSource(ResolveReaderSettingsFile(Settings.DataDir),Value,NoteFile,FExpectedMembers)
          and SameFileName(NoteFile,FNextFile) then
        begin
          FNoteTarget.BookID:=Value;
          FNoteTarget.Position:=Ini.ReadInteger('ReaderSession','PendingNotePosition',0);
        end
        else FExpectedMembers:=nil;
      except on E: Exception do
        begin FExpectedMembers:=nil; LogDiagnosticError('reader-note-resume',E); end; end;
    Ini.DeleteKey('ReaderSession','PendingFile');
    Ini.DeleteKey('ReaderSession','PendingSession');
    Ini.DeleteKey('ReaderSession','PendingNoteBook');
    Ini.DeleteKey('ReaderSession','PendingNotePosition'); SaveMemIniFileAtomically(Ini);
    ReadRecent(Ini);
    FOfferFollowingComic:=Ini.ReadBool('Reader','OfferFollowingComic',True);
  finally Ini.Free; end;
  Intro:=TLabel.Create(Self); Intro.Parent:=Self; Intro.AutoSize:=False;
  Intro.WordWrap:=True; Intro.SetBounds(24,28,672,64); Intro.Anchors:=[akLeft,akTop,akRight];
  Intro.Caption:='Откройте книгу с компьютера или перетащите файл в это окно. Настройки чтения, позиция, закладки и заметки сохраняются в профиле читалки.';
  OpenButton:=TButton.Create(Self); OpenButton.Parent:=Self; OpenButton.SetBounds(24,104,200,34);
  OpenButton.Caption:='Открыть книгу…'; OpenButton.OnClick:=OpenClick;
  FRecentView:=TListBox.Create(Self); FRecentView.Parent:=Self;
  FRecentView.SetBounds(24,158,672,208); FRecentView.Anchors:=[akLeft,akTop,akRight,akBottom];
  FRecentView.Name:='ReaderRecentBooks';
  RefreshRecentView; FRecentView.OnDblClick:=RecentViewClick;
  FRecentView.OnKeyDown:=RecentViewKeyDown;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Self; FStatus.AutoSize:=False; FStatus.WordWrap:=True;
  FStatus.SetBounds(24,380,672,40); FStatus.Anchors:=[akLeft,akRight,akBottom];
  FStatus.Caption:='Недавние книги — Enter или двойной щелчок для открытия.';
  InstallMenu(Self); ApplyMHLControlTheme(Self);
  FTimer:=TTimer.Create(Self); FTimer.Interval:=150; FTimer.OnTimer:=Tick;
  try TakeBookSaveContinuation(Settings.SettingsFileName,FSaveContinuation);
  except on E: Exception do begin LogDiagnosticError('reader-save-resume-load',E); FStatus.Caption:=E.Message; end; end;
end;

destructor TfrmReaderHost.Destroy;
begin
  if Assigned(FTimer) then FTimer.Enabled:=False;
  FHomeList:=nil; FHomeImages:=nil; FHomeStatus:=nil;
  FreeAndNil(FHomeView);
  CancelReaderPreparations(Self);
  if not FRestarting then ClearRestartState;
  if FRestarting then FreeAndNil(FSessionLease) else FinishSession('closed');
  // Hold the selected payload and its origin through cache-on-exit cleanup.
  // The helper starts after this process exits and acquires its own leases.
  FinishBookCacheSession;
  if FRestarting then
  begin
    RemoveReaderRestart(ExtractFileDir(Settings.SettingsFileName));
    FreeAndNil(FRestartLease);
    CleanupReaderRestartSession(ExtractFileDir(Settings.SettingsFileName),FSession.RequestFile);
  end;
  FUpdates.Free; FUpdates:=nil;
  FRecent.Free;
  inherited;
end;

procedure TfrmReaderHost.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // CreateNew does not set VCL's FCreatingMainForm flag. This host must be
  // its own taskbar window rather than a popup owned by the hidden app HWND.
  Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW or WS_EX_ACCEPTFILES) and not WS_EX_TOOLWINDOW;
end;

procedure TfrmReaderHost.InstallMenu(Form: TForm);
var Menu: TMainMenu; FileMenu, Item, RecentMenu, SettingsMenu, HelpMenu: TMenuItem;
  procedure Add(const Text: string; Shortcut: TShortCut; Action: TNotifyEvent);
  begin
    Item:=TMenuItem.Create(Menu); Item.Caption:=Text; Item.ShortCut:=Shortcut;
    Item.OnClick:=Action; FileMenu.Add(Item);
  end;
begin
  Menu:=TMainMenu.Create(Form); FileMenu:=TMenuItem.Create(Menu);
  FileMenu.Caption:='Файл'; Menu.Items.Add(FileMenu);
  Add('Открыть…',ShortCut(Ord('O'),[ssCtrl]),OpenClick);
  RecentMenu:=TMenuItem.Create(Menu); RecentMenu.Name:='ReaderRecentMenu';
  RecentMenu.Caption:='Недавние книги'; FileMenu.Add(RecentMenu);
  if FSession.Book.BookKey.BookID>0 then
  begin
    for var I:=0 to High(FSession.CatalogueRecent) do
    begin
      Item:=TMenuItem.Create(Menu);
      Item.Caption:=FSession.CatalogueRecent[I].Caption.Replace('&','&&');
      Item.Tag:=I+1; Item.OnClick:=CatalogueRecentClick; RecentMenu.Add(Item);
    end;
  end
  else
    for var I:=0 to FRecent.Count-1 do
    begin
      Item:=TMenuItem.Create(Menu); Item.Caption:=RecentCaption(I).Replace('&','&&');
      Item.Tag:=I; Item.OnClick:=RecentClick; RecentMenu.Add(Item);
    end;
  RecentMenu.Enabled:=RecentMenu.Count>0;
  RecentMenu.Visible:=Form<>FHomeView;
  if (Form=Self) or (Form=FHomeView) then
  begin
    Add('Закладки и заметки всех книг…',0,NotesClick);
    Item.Name:='ReaderAllNotesMenu';
  end;
  Add('Сохранить как…',ShortCut(Ord('S'),[ssCtrl,ssShift]),SaveClick);
  Item.Enabled:=Form<>FHomeView;
  Add('-',0,nil); Add('Закрыть читалку',ShortCut(VK_F4,[ssAlt]),ExitClick);
  SettingsMenu:=TMenuItem.Create(Menu); SettingsMenu.Caption:='Настройки'; Menu.Items.Add(SettingsMenu);
  Item:=TMenuItem.Create(Menu); Item.Caption:='Кэш книг…'; Item.OnClick:=CacheSettingsClick;
  SettingsMenu.Add(Item);
  if (Form is TfrmBuiltinReader) and (Form<>FHomeView) then
  begin
    Item:=TMenuItem.Create(Menu); Item.Name:='ReaderNavigationKeysMenu'; Item.Caption:='Клавиши чтения…';
    Item.OnClick:=TfrmBuiltinReader(Form).ConfigureNavigationKeys; SettingsMenu.Add(Item);
    TfrmBuiltinReader(Form).AddTextEncodingMenu(SettingsMenu);
    Item:=TMenuItem.Create(Menu); Item.Name:='ReaderOfferFollowingComic';
    Item.Caption:='Предлагать следующую главу или том'; Item.Checked:=FOfferFollowingComic;
    Item.OnClick:=ToggleFollowingComic; SettingsMenu.Add(Item);
  end;
  Item:=TMenuItem.Create(Menu); Item.Name:='ReaderAssociationsMenu'; Item.Caption:='Открытие файлов в Windows…';
  Item.OnClick:=AssociationsClick; SettingsMenu.Add(Item);
  Item:=TMenuItem.Create(Menu); Item.Name:='ReaderComponentsMenu'; Item.Caption:='Компоненты…';
  Item.OnClick:=ComponentsClick; SettingsMenu.Add(Item);
  HelpMenu:=TMenuItem.Create(Menu); HelpMenu.Caption:='Помощь'; Menu.Items.Add(HelpMenu);
  Item:=TMenuItem.Create(Menu); Item.Name:='ReaderFormatsHelp'; Item.Caption:='Форматы чтения…';
  Item.OnClick:=FormatsClick; HelpMenu.Add(Item);
  Item:=TMenuItem.Create(Menu); Item.Name:='ReaderDiagnostics'; Item.Caption:='Журнал ошибок…';
  Item.OnClick:=DiagnosticsClick; HelpMenu.Add(Item);
  Form.Menu:=Menu;
  if Form is TfrmBuiltinReader then TfrmBuiltinReader(Form).RefreshWindowTheme;
end;

procedure TfrmReaderHost.DiagnosticsClick(Sender: TObject);
begin
  if FView is TfrmBuiltinReader then
    ShowDiagnostics(FView,procedure(Dialog: TComponent)
      begin TfrmBuiltinReader(FView).ApplyWindowPalette(TCustomForm(Dialog)); end)
  else if Assigned(FView) then ShowDiagnostics(FView)
  else if Assigned(FHomeView) then
    ShowDiagnostics(FHomeView,procedure(Dialog: TComponent)
      begin TfrmBuiltinReader(FHomeView).ApplyWindowPalette(TCustomForm(Dialog)); end)
  else ShowDiagnostics(Self);
end;

procedure TfrmReaderHost.AssociationsClick(Sender:TObject);
var ParentForm:TCustomForm; Dialog:TReaderAssociationsForm;
begin
  ParentForm:=Self;
  if Assigned(FView) then ParentForm:=FView
  else if Assigned(FHomeView) then ParentForm:=FHomeView;
  Dialog:=TReaderAssociationsForm.Create(ParentForm);
  try
    if ParentForm is TfrmBuiltinReader then TfrmBuiltinReader(ParentForm).ApplyWindowPalette(Dialog)
    else ApplyMHLControlTheme(Dialog);
    Dialog.ShowModal;
  finally Dialog.Free; end;
end;

procedure TfrmReaderHost.FormatsClick(Sender: TObject);
const Formats =
  'Открываются без дополнительных модулей'+sLineBreak+
  'FB2, FB3, EPUB — электронные книги.'+sLineBreak+
  'DOCX, ODT — текстовые документы.'+sLineBreak+
  'TXT, FAQ, WRI, RTF, MD, MARKDOWN — текст и разметка.'+sLineBreak+
  'HTML, HTM, SHTML, XHTML, MHT, MHTML — веб-документы.'+sLineBreak+
  'JPG, JPEG, PNG, GIF, BMP — изображения. CBZ — комиксы с такими страницами.'+sLineBreak+sLineBreak+
  'Модули, которые читалка предложит при открытии'+sLineBreak+
  'SM — интерактивные книги с выбором ответов. Нужен BookProcessing.'+sLineBreak+
  'PDF — PDFium.'+sLineBreak+
  'DJVU, DJV, DJU, DJM, DJVM — DjVuLibre.'+sLineBreak+
  'XPS, OXPS — HomeLibXps и подготовка книг (BookProcessing).'+sLineBreak+
  'MOBI, AZW, AZW3, PRC — KindleUnpack и подготовка книг. Для отдельных старых книг также нужны кодеки calibre.'+sLineBreak+
  'DOC, DOT — DocSharp. PPT, PPS, POT, XLS, XLT — DocSharp и подготовка книг.'+sLineBreak+
  'DOCM, DOTX, DOTM, OTT, PPTX, PPTM, PPSX, PPSM, POTX, POTM, ODP, OTP, XLSX, XLSM, XLTX, XLTM, ODS, OTS — подготовка книг.'+sLineBreak+
  'WPS, WPD — libwps/libwpd и подготовка книг. Требуется 64-разрядная Windows.'+sLineBreak+
  'LIT, LRF — кодеки calibre и подготовка книг. IBK — данные ICE Book Reader и подготовка книг.'+sLineBreak+
  'CHM — 7-Zip и подготовка книг. PDB, RGO, JUTOH, PAGES, CR3, B1, TCR, RB, ABW, SXW, HA — подготовка книг.'+sLineBreak+
  'WEBP — libwebp. Для иллюстраций JPEG XL в книгах из сжатых коллекций нужен декодер JPEG XL.'+sLineBreak+
  'TIF, TIFF — встроенное чтение или подготовка книг, в зависимости от файла.'+sLineBreak+
  'CBR, CB7 — комиксы. Для некоторых архивов нужен 7-Zip. Для отдельных страниц TIFF нужна подготовка книг.'+sLineBreak+sLineBreak+
  'Из ZIP, FBZ, 7Z, 7ZIP, RAR, TAR, GZ, GZIP, TGZ, BZ2, XZ и CAB можно выбрать вложенную книгу. '+
  'Из APK можно открыть вложенную книгу поддерживаемого формата. Для некоторых способов сжатия читалка предложит 7-Zip.'+sLineBreak+sLineBreak+
  'Очень крупные FB2 и RTF могут потребовать подготовку книг. Поддержка редких форматов зависит от их варианта. '+
  'Встроенные обработчики обновляются вместе с читалкой. Модули обновляются в «Настройки → Компоненты».';
var Dialog: TForm; ParentForm: TCustomForm; Text: TMemo; CloseButton: TButton;
begin
  ParentForm:=FView;
  if not Assigned(ParentForm) then ParentForm:=FHomeView;
  if not Assigned(ParentForm) then ParentForm:=Self;
  Dialog:=TForm.CreateNew(ParentForm);
  try
    Dialog.Name:='ReaderFormatsDialog'; Dialog.Caption:='Форматы чтения';
    Dialog.PopupMode:=pmExplicit; Dialog.PopupParent:=ParentForm;
    Dialog.Position:=poOwnerFormCenter; Dialog.Font.Assign(ParentForm.Font);
    Dialog.ClientWidth:=650; Dialog.ClientHeight:=420;
    Dialog.Constraints.MinWidth:=460; Dialog.Constraints.MinHeight:=300;
    Text:=TMemo.Create(Dialog); Text.Parent:=Dialog; Text.Name:='ReaderFormatsText';
    Text.ReadOnly:=True; Text.ScrollBars:=ssVertical; Text.WordWrap:=True;
    Text.SetBounds(16,16,618,340); Text.Anchors:=[akLeft,akTop,akRight,akBottom];
    Text.Text:=Formats;
    CloseButton:=TReaderPaletteButton.Create(Dialog); CloseButton.Parent:=Dialog; CloseButton.Caption:='Закрыть';
    CloseButton.SetBounds(524,372,110,30); CloseButton.Anchors:=[akRight,akBottom];
    CloseButton.Default:=True; CloseButton.Cancel:=True; CloseButton.ModalResult:=mrOk;
    Dialog.ScaleForPPI(CurrentPPI);
    if ParentForm is TfrmBuiltinReader then TfrmBuiltinReader(ParentForm).ApplyWindowPalette(Dialog)
    else ApplyMHLControlTheme(Dialog);
    Dialog.ShowModal;
  finally Dialog.Free; end;
end;

procedure TfrmReaderHost.OpenClick(Sender: TObject);
var Dialog: TOpenDialog; ParentWindow: THandle;
begin
  if FPreparing then Exit;
  ParentWindow:=Handle;
  if Assigned(FView) then ParentWindow:=FView.Handle
  else if Assigned(FHomeView) then ParentWindow:=FHomeView.Handle;
  Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Title:='Открыть книгу'; Dialog.Filter:='Книги и документы|*.*';
    Dialog.Options:=[ofFileMustExist,ofPathMustExist,ofEnableSizing];
    if Dialog.Execute(ParentWindow) then OpenFile(Dialog.FileName);
  finally Dialog.Free; end;
end;

procedure TfrmReaderHost.WMDropFiles(var Message: TWMDropFiles);
begin
  OfferDroppedBook(Self,Message);
end;

procedure TfrmReaderHost.OfferDroppedBook(Target: TCustomForm; var Message: TWMDropFiles);
var Files: TArray<string>;
begin
  Message.Result:=0;
  try
    if FPreparing or FResumingSave or FExitRequested or FHostCloseRequested or FRestarting or
      (FNextFile<>'') or (FNextSession<>'') or not Target.Enabled then Exit;
    Files:=ReadDroppedImportFiles(Message.Drop);
  finally DragFinish(Message.Drop); end;
  if Length(Files)=0 then Exit;
  if (Length(Files)<>1) or not FileExists(Files[0]) then
  begin
    MessageDlg('Перетащите один файл книги или архива.',mtInformation,[mbOK],0);
    Exit;
  end;
  if ConfirmBookOpen(Target,'ReaderDroppedBookDialog','Открыть книгу',
    'Открыть этот файл в читалке?',ExtractFileName(Files[0]),'Отмена') and
    not FExitRequested and not FHostCloseRequested and not FRestarting then OpenFile(Files[0]);
end;

procedure TfrmReaderHost.OpenFile(const FileName: string);
begin
  QueueFile(FileName,Default(TReaderAnnotation),nil);
end;

procedure TfrmReaderHost.QueueFile(const FileName: string; const Note: TReaderAnnotation;
  const ArchiveMembers: TArray<string>);
begin
  FNextFile:=TPath.GetFullPath(FileName); FNextSession:=''; FPendingComponent:='';
  FNoteTarget:=Note; FExpectedMembers:=ArchiveMembers;
  if Assigned(FView) then begin FView.ModalResult:=mrRetry; FView.Close; end;
end;

procedure TfrmReaderHost.ShowStartPage;
var Reader: TStandaloneBookReader; Page, OpenArea: TPanel; Heading, DropHint: TLabel;
  OpenButton: TButton; Margin: Integer;
begin
  if FDirectLaunch or FExitRequested then Exit;
  FUseStartPage:=True;
  if not Assigned(FHomeView) then
  begin
    Reader:=TStandaloneBookReader.Create(Self);
    FHomeView:=Reader;
    Reader.Caption:='HomeLibre Reader';
    Reader.PopupMode:=pmNone; Reader.PopupParent:=nil;
    Reader.OnCloseQuery:=HomeCloseQuery;
    Reader.ShowInTaskBar:=True;
    Page:=Reader.CreateStartPage(ResolveReaderSettingsFile(Settings.DataDir));
    Margin:=16;
    Page.Padding.SetBounds(Margin,Margin,Margin,Margin);

    OpenArea:=TPanel.Create(Page); OpenArea.Parent:=Page; OpenArea.Align:=alTop;
    OpenArea.Name:='ReaderOpenArea'; OpenArea.Height:=82;
    OpenArea.BevelOuter:=bvLowered; OpenArea.ShowCaption:=False;
    OpenButton:=TReaderPaletteButton.Create(OpenArea); OpenButton.Parent:=OpenArea;
    OpenButton.Name:='ReaderOpenFile'; OpenButton.Caption:='Открыть книгу…';
    OpenButton.SetBounds(12,10,174,29); OpenButton.OnClick:=OpenClick;
    DropHint:=TLabel.Create(OpenArea); DropHint.Parent:=OpenArea; DropHint.Left:=12; DropHint.Top:=49;
    DropHint.Caption:='Или перетащите сюда книгу или архив';

    Heading:=TLabel.Create(Page); Heading.Parent:=Page; Heading.Align:=alTop;
    Heading.Top:=OpenArea.Height; Heading.AutoSize:=False; Heading.Height:=32; Heading.Layout:=tlCenter;
    Heading.Caption:='Недавние книги'; Heading.Font.Style:=[fsBold];

    FHomeStatus:=TLabel.Create(Page); FHomeStatus.Parent:=Page; FHomeStatus.Align:=alBottom;
    FHomeStatus.AutoSize:=False; FHomeStatus.Height:=28; FHomeStatus.Layout:=tlCenter;
    if FRecent.Count=0 then FHomeStatus.Caption:='Здесь появятся недавно открытые книги.'
    else FHomeStatus.Caption:='Открыть книгу — двойной щелчок или Enter.';
    FHomeList:=TListView.Create(Page); FHomeList.Parent:=Page; FHomeList.Align:=alClient;
    FHomeList.Name:='ReaderStartRecent'; FHomeList.ViewStyle:=vsReport;
    FHomeList.ReadOnly:=True; FHomeList.RowSelect:=True; FHomeList.HideSelection:=False;
    FHomeList.Columns.Add.Caption:='Книга'; FHomeList.Columns.Add.Caption:='Автор';
    FHomeImages:=TImageList.Create(Page); FHomeImages.Width:=42; FHomeImages.Height:=58;
    FHomeList.SmallImages:=FHomeImages;
    FHomeList.OnDblClick:=HomeRecentClick; FHomeList.OnKeyDown:=HomeRecentKeyDown;
    FHomeList.OnResize:=ResizeHomeRecent;
    InstallMenu(Reader);
    Reader.ApplyWindowPalette(Reader);
    FHomeList.Color:=Reader.Color;
    FHomeList.Font.Color:=Reader.Font.Color;
    Reader.ActiveControl:=FHomeList;
  end;
  RefreshRecentView;
  FHomeView.Show;
end;

procedure TfrmReaderHost.HomeCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:=False;
  Close;
end;

procedure TfrmReaderHost.HomeRecentClick(Sender: TObject);
begin
  if Assigned(FHomeList.Selected) then OpenRecent(FHomeList.Selected.Index);
end;

procedure TfrmReaderHost.HomeRecentKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key=VK_RETURN then begin Key:=0; HomeRecentClick(Sender); end;
end;

procedure TfrmReaderHost.ResizeHomeRecent(Sender: TObject);
var Width: Integer;
begin
  if not Assigned(FHomeList) then Exit;
  Width:=Max(0,FHomeList.ClientWidth-GetSystemMetrics(SM_CXVSCROLL)-4);
  FHomeList.Columns[0].Width:=Width*2 div 3;
  FHomeList.Columns[1].Width:=Width-FHomeList.Columns[0].Width;
end;

procedure TfrmReaderHost.SetStatus(const Value: string);
begin
  FStatus.Caption:=Value;
  if Assigned(FHomeStatus) then FHomeStatus.Caption:=Value;
end;

procedure TfrmReaderHost.OpenInitialFile(const FileName: string);
begin
  if (FileName<>'') or (FNextFile<>'') or (FNextSession<>'') then
  begin FDirectLaunch:=True; Application.ShowMainForm:=False; end;
  // The updater preserves the original command line, which may name a book
  // opened before the one that requested a component. Resume that pending
  // book first; explicit Open commands during ordinary use still replace it.
  if (FNextFile='') and (FNextSession='') and (FileName<>'') then OpenFile(FileName);
end;

procedure TfrmReaderHost.OpenInitialSession(const RequestFile: string);
begin
  if (RequestFile<>'') or (FNextSession<>'') then
  begin FDirectLaunch:=True; Application.ShowMainForm:=False; end;
  if (FNextFile='') and (FNextSession='') and (RequestFile<>'') then
    FNextSession:=TPath.GetFullPath(RequestFile);
end;

procedure TfrmReaderHost.SendSessionState(const State, ErrorText: string);
begin
  if FSession.ID='' then Exit;
  FSessionReply.State:=State; FSessionReply.ProcessID:=GetCurrentProcessId;
  FSessionReply.ErrorText:=ErrorText;
  try WriteReaderSessionReply(FSession,FSessionReply);
  except on E: Exception do LogDiagnosticError('reader-session-reply',E); end;
end;

procedure TfrmReaderHost.FinishSession(const State: string);
begin
  if (State='failed') or ((State='closed') and (FSessionReply.State='failed')) then
    SendSessionState('failed',FSessionReply.ErrorText)
  else SendSessionState(State);
  FreeAndNil(FSessionLease);
  CleanupReaderRestartSession(ExtractFileDir(Settings.SettingsFileName),FSession.RequestFile);
  FSession:=Default(TReaderSessionRequest); FSessionReply:=Default(TReaderSessionReply);
end;

procedure TfrmReaderHost.BeginSession(const RequestFile: string);
var Previous: TReaderSessionReply;
begin
  FinishSession('closed');
  try
    FSession:=LoadReaderSession(RequestFile);
    FSessionLease:=TReaderSessionLease.Create(FSession);
    FSessionReply.OriginProcessID:=GetCurrentProcessId;
    if TryReadReaderSessionReply(FSession,Previous) and (Previous.State='restarting') then
      if Previous.OriginProcessID<>0 then FSessionReply.OriginProcessID:=Previous.OriginProcessID
      else FSessionReply.OriginProcessID:=Previous.ProcessID;
    SendSessionState('opening'); Prepare(FSession.SourceFile);
  except
    on E: Exception do
    begin
      // A second process that failed to acquire the lease must not replace
      // the reply belonging to the reader that is already displaying it.
      if Assigned(FSessionLease) then SendSessionState('failed',E.Message);
      FreeAndNil(FSessionLease); FSession:=Default(TReaderSessionRequest);
      LogDiagnosticError('reader-session-open',E); MessageDlg(E.Message,mtError,[mbOK],0);
    end;
  end;
end;

procedure TfrmReaderHost.RecentClick(Sender: TObject);
begin OpenRecent(TMenuItem(Sender).Tag); end;

procedure TfrmReaderHost.CatalogueRecentClick(Sender: TObject);
begin
  if not Assigned(FView) then Exit;
  FCatalogueRecentSelection:=TMenuItem(Sender).Tag;
  FView.ModalResult:=MR_CATALOGUE_RECENT;
end;

procedure TfrmReaderHost.RecentViewClick(Sender: TObject);
begin OpenRecent(FRecentView.ItemIndex); end;

procedure TfrmReaderHost.RecentViewKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key<>VK_RETURN) or (Shift<>[]) or FPreparing then Exit;
  Key:=0; RecentViewClick(Sender);
end;

procedure TfrmReaderHost.NotesClick(Sender: TObject);
var Note: TReaderAnnotation; ParentForm: TCustomForm;
begin
  ParentForm:=FView;
  if not Assigned(ParentForm) then ParentForm:=FHomeView;
  if not Assigned(ParentForm) then ParentForm:=Self;
  if not FPreparing and BrowseReaderNotes(ParentForm,ResolveReaderSettingsFile(Settings.DataDir),Note) then
    OpenNote(Note);
end;

procedure TfrmReaderHost.OpenNote(const Note: TReaderAnnotation);
var FileName, SettingsFile: string; Members: TArray<string>;
begin
  SettingsFile:=ResolveReaderSettingsFile(Settings.DataDir);
  try
    if FindStandaloneNoteSource(SettingsFile,Note.BookID,FileName,Members) then
    begin QueueFile(FileName,Note,Members); Exit; end;
    // Old profiles only kept the last ten paths. Never guess a book by
    // title or use the shared identity of a loose multi-book archive.
    for var Recent in FRecent do
      if FileExists(Recent.FileName) and not IsReaderContainer(Recent.FileName) then
        try
          if ReaderNoteIdentity(StandaloneHistory(FileBook(Recent.FileName),nil))=Note.BookID then
          begin QueueFile(Recent.FileName,Note,nil); Exit; end;
        except on E: EStreamError do LogDiagnosticError('reader-note-source',E); end;
  except on E: Exception do LogDiagnosticError('reader-note-source',E); end;
  MessageDlg('Не удалось найти исходный файл для «'+Note.BookTitle+'». Проверьте, доступен ли файл.',mtInformation,[mbOK],0);
end;

procedure TfrmReaderHost.SaveClick(Sender: TObject);
var Options: TBookSendOptions; Results: TBookExportResults; Required: TArray<string>;
begin
  if FPreparing or (FCurrentFile='') or (FExportBook.FileName='') then Exit;
  try
    var Initial: PBookSendOptions:=nil; if FResumingSave then Initial:=@FSaveContinuation.Options;
    if not ChooseBookSendOptions(1,Settings.SyncExportDir,Settings.ExportMode,Options,False,[FExportBook],Initial) then
    begin
      if Options.RequiredComponent<>'' then
      begin
        StoreBookSaveContinuation(Settings.SettingsFileName,Options.RequiredComponent,Options,nil,FCurrentFile);
        EnsureUpdates; FUpdates.RequestComponents(Options.RequiredComponents,
          'Для оценки размера нужен дополнительный модуль. После установки вернёмся к сохранению книги.',True);
      end;
      Exit;
    end;
    Results:=SaveFileBook(FExportBook,Options,Required);
    if Length(Required)>0 then
    begin
      StoreBookSaveContinuation(Settings.SettingsFileName,Required[0],Options,nil,FCurrentFile);
      EnsureUpdates;
      FUpdates.RequestComponents(Required,'Для выбранного сохранения нужен дополнительный модуль. '+
        'После установки и перезапуска вернёмся к этим параметрам сохранения.',True);
    end
    else if (Length(Results)>0) and (Results[0].State=besSucceeded) then
      FStatus.Caption:='Сохранено: '+Results[0].OutputFile;
  except
    on E: Exception do
    begin LogDiagnosticError('reader-save-file',E); MessageDlg(E.Message,mtError,[mbOK],0); end;
  end;
end;

procedure TfrmReaderHost.ResumeBookSave(var Message: TMessage);
var Token: string;
begin
  if (FSaveContinuation.Token='') or not Assigned(FView) or FPreparing or FExitRequested then Exit;
  if not SameFileName(FSaveContinuation.SourceFile,FCurrentFile) then Exit;
  Token:=FSaveContinuation.Token; FResumingSave:=True;
  try SaveClick(nil);
  finally
    FResumingSave:=False; FSaveContinuation:=Default(TBookSaveContinuation);
    try ClearBookSaveContinuation(Settings.SettingsFileName,Token);
    except on E: Exception do LogDiagnosticError('reader-save-resume-clear',E); end;
  end;
end;

procedure TfrmReaderHost.ExitClick(Sender: TObject);
begin
  FExitRequested:=True; FExitViaMenu:=True;
  if Assigned(FView) then begin FView.ModalResult:=mrCancel; FView.Close; end else Close;
end;

procedure TfrmReaderHost.EnsureUpdates;
begin
  if Assigned(FUpdates) then Exit;
  FUpdates:=TfrmProgramUpdate.Create(Self);
  FUpdates.UseReaderComponents; FUpdates.OnRestart:=RestartForUpdate;
  FUpdates.OnComponentCancelled:=ComponentCancelled;
end;

procedure TfrmReaderHost.ComponentCancelled(Sender: TObject);
begin
  if FPendingComponent='' then Exit;
  FPendingComponent:=''; FinishSession('closed');
  if FDirectLaunch then
  begin
    // The file/session launcher is hidden while the component prompt is open.
    // Defer destruction until the prompt's cancellation handler has returned.
    FExitRequested:=True; PostMessage(Handle,WM_CLOSE,0,0);
  end
  else begin SetStatus('Открытие книги отменено.'); if FUseStartPage then ShowStartPage else Show; end;
end;

procedure TfrmReaderHost.RestartForUpdate(Sender: TObject);
var Ini: TMemIniFile;
begin
  Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
  try
    Ini.DeleteKey('ReaderSession','PendingFile'); Ini.DeleteKey('ReaderSession','PendingSession');
    Ini.DeleteKey('ReaderSession','PendingNoteBook'); Ini.DeleteKey('ReaderSession','PendingNotePosition');
    if FRestartRequest.ID<>'' then Ini.WriteString('ReaderSession','PendingSession',FRestartRequest.RequestFile)
    else if FSession.ID<>'' then Ini.WriteString('ReaderSession','PendingSession',FSession.RequestFile)
    else
    begin
      Ini.WriteString('ReaderSession','PendingFile',FCurrentFile);
      if FNoteTarget.BookID<>'' then
      begin
        Ini.WriteString('ReaderSession','PendingNoteBook',FNoteTarget.BookID);
        Ini.WriteInteger('ReaderSession','PendingNotePosition',FNoteTarget.Position);
      end;
    end;
    SaveMemIniFileAtomically(Ini);
    if not FUpdates.LaunchInstallation then
    begin
      Ini.DeleteKey('ReaderSession','PendingFile'); Ini.DeleteKey('ReaderSession','PendingSession');
      Ini.DeleteKey('ReaderSession','PendingNoteBook'); Ini.DeleteKey('ReaderSession','PendingNotePosition');
      SaveMemIniFileAtomically(Ini); Exit;
    end;
  finally Ini.Free; end;
  FRestarting:=True; SendSessionState('restarting');
  ExitClick(nil);
end;

procedure TfrmReaderHost.ComponentsClick(Sender: TObject);
begin
  EnsureUpdates;
  FUpdates.UseFullWindow;
  FUpdates.CheckComponents(False); FUpdates.Show;
end;

procedure TfrmReaderHost.CacheSettingsClick(Sender: TObject);
begin
  ConfigureReaderCache;
end;

procedure TfrmReaderHost.ToggleFollowingComic(Sender: TObject);
var Ini: TMemIniFile; Lock: TFileMutex;
begin
  Lock:=TFileMutex.Create(Settings.SettingsFileName);
  try
    for var Attempt:=1 to 10 do
    begin
      if Lock.TryAcquire then Break;
      Sleep(10);
    end;
    if not Lock.Acquired then raise EWriteError.Create('Настройки читалки заняты. Повторите попытку.');
    Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
    try
      Ini.WriteBool('Reader','OfferFollowingComic',not FOfferFollowingComic);
      SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
  finally Lock.Free; end;
  FOfferFollowingComic:=not FOfferFollowingComic;
  TMenuItem(Sender).Checked:=FOfferFollowingComic;
  if not FOfferFollowingComic then
  begin FFollowingComic:=nil; FNextVolumePending:=False; end;
  if (FCanFollowComic or (FSession.NextVolume.Book.Key.BookID>0)) and (FView is TfrmBuiltinReader) then
    if FOfferFollowingComic then TfrmBuiltinReader(FView).OnReadPastEnd:=LookForFollowingBook
    else TfrmBuiltinReader(FView).OnReadPastEnd:=nil;
end;

procedure TfrmReaderHost.LookForFollowingBook;
var Source: string;
begin
  if not FOfferFollowingComic then Exit;
  if FSession.NextVolume.Book.Key.BookID>0 then
  begin FNextVolumePending:=True; Exit; end;
  Source:=FCurrentFile;
  FFollowingComic:=TTask.Future<string>(
    function: string
    begin Result:=FindFollowingComicArchive(Source); end);
end;

procedure TfrmReaderHost.OfferFollowingBook;
var Work: IFuture<string>; FileName: string;
begin
  if not Assigned(FView) or not FOfferFollowingComic or FExitRequested or FHostCloseRequested or
    (Screen.ActiveCustomForm<>FView) then Exit;
  if FNextVolumePending then
  begin
    FNextVolumePending:=False;
    if ConfirmBookOpen(FView,'ReaderFollowingVolumeDialog','Следующий том',
      'Открыть следующий том серии?',FSession.NextVolume.Book.Caption,'Остаться') then
      FView.ModalResult:=MR_CATALOGUE_NEXT_VOLUME;
    Exit;
  end;
  if not Assigned(FFollowingComic) then Exit;
  if not (FFollowingComic.Status in [TTaskStatus.Completed,TTaskStatus.Exception,TTaskStatus.Canceled]) then Exit;
  Work:=FFollowingComic; FFollowingComic:=nil;
  if Work.Status=TTaskStatus.Canceled then Exit;
  try FileName:=Work.Value;
  except on E: Exception do begin LogDiagnosticError('reader-following-comic',E); Exit; end; end;
  if (FileName<>'') and ConfirmBookOpen(FView,'ReaderFollowingComicDialog','Следующая глава манги',
    'Открыть следующую главу?',ExtractFileName(FileName),'Остаться') then OpenFile(FileName);
end;

function TfrmReaderHost.ConfirmBookOpen(Target: TCustomForm;
  const DialogName, Title, Prompt, BookCaption, CancelCaption: string): Boolean;
var Dialog: TForm;
begin
  Dialog:=CreateMessageDialog(Prompt+sLineBreak+BookCaption,mtConfirmation,[mbYes,mbNo]);
  try
    Dialog.Name:=DialogName; Dialog.Caption:=Title;
    Dialog.PopupMode:=pmExplicit; Dialog.PopupParent:=Target;
    Dialog.Position:=poOwnerFormCenter;
    for var Component in Dialog do
      if Component is TButton then
        case TButton(Component).ModalResult of
          mrYes:
            begin TButton(Component).Caption:='Открыть'; TButton(Component).Default:=False; end;
          mrNo:
            begin
              TButton(Component).Caption:=CancelCaption;
              TButton(Component).Default:=True;
              TButton(Component).Cancel:=True;
              Dialog.ActiveControl:=TButton(Component);
            end;
        end;
    if Target is TfrmBuiltinReader then TfrmBuiltinReader(Target).ApplyWindowPalette(Dialog)
    else ApplyMHLControlTheme(Dialog);
    Result:=Dialog.ShowModal=mrYes;
  finally Dialog.Free; end;
end;

procedure TfrmReaderHost.MissingComponent(const ID: string);
begin MissingComponents(TArray<string>.Create(ID)); end;

procedure TfrmReaderHost.MissingComponents(const IDs: TArray<string>);
var Title, Titles: string;
begin
  if Length(IDs)=0 then Exit;
  Titles:='';
  for var ID in IDs do
  begin
    Title:=ID;
    for var Component in UPDATE_COMPONENTS do if Component.ID=ID then Title:=Component.Title;
    if Titles<>'' then Titles:=Titles+', '; Titles:=Titles+Title;
  end;
  FPendingComponent:=IDs[0]; SetStatus('Для этой книги нужны компоненты: '+Titles+'.');
  FSessionReply.RequiredComponent:=IDs[0]; SendSessionState('component_required');
  EnsureUpdates; FUpdates.RequestComponents(IDs,FStatus.Caption,True);
end;

procedure TfrmReaderHost.BookViewClosing(Sender: TObject; var Action: TCloseAction);
var PID: DWORD;
begin
  PID:=0; GetWindowThreadProcessId(GetForegroundWindow,PID);
  if Assigned(FPreviousViewClose) then FPreviousViewClose(Sender,Action);
  FReaderClosedActive:=(Action<>caNone) and (PID=GetCurrentProcessId);
end;

procedure TfrmReaderHost.CheckModuleCleanup(AfterReading: Boolean);
var Pending: TMsg;
begin
  if (FSessionReply.RequestedCatalogueRecent<>0) or FSessionReply.RequestedNextVolume or FRestarting or
    Application.Terminated or (GetSystemMetrics(SM_SHUTTINGDOWN)<>0) or
    FHostCloseRequested or (FExitRequested and not FExitViaMenu) or (FPendingComponent<>'') or
    (FNextFile<>'') or (FNextSession<>'') or (GetTickCount64<FNextCleanupCheck) then Exit;
  // The updater closes both the hidden host and its book. Do not open a new
  // modal window between those requests or delay releasing decoder files.
  if PeekMessage(Pending,Handle,WM_CLOSE,WM_CLOSE,PM_NOREMOVE) then Exit;
  if AfterReading then
  begin if not FReaderClosedActive or not Assigned(FView) then Exit; end
  else if not ComponentCleanupWindowReady(Self,FPreparing or FDisplaying or FResumingSave) then Exit;
  FNextCleanupCheck:=GetTickCount64+24*60*60*UInt64(1000);
  if AfterReading then
    OfferUnusedComponents(FView,Settings.AppPath,True,0,procedure(Dialog: TCustomForm)
      begin if FView is TfrmBuiltinReader then TfrmBuiltinReader(FView).ApplyWindowPalette(Dialog); end)
  else OfferUnusedComponents(Self,Settings.AppPath,True);
end;

procedure TfrmReaderHost.ConfirmSessionOpened;
var Title, Author, Cover: string;
begin
  if not Assigned(FView) then Exit;
  if (FView is TfrmBuiltinReader) and not TfrmBuiltinReader(FView).Ready then Exit;
  // A newer note can already be queued by the closing view.
  if FNextFile='' then FNoteTarget:=Default(TReaderAnnotation);
  if FRecentMetadataPending then
  begin
    if (FView is TfrmStoryReader) and not TfrmStoryReader(FView).Ready then Exit;
    FRecentMetadataPending:=False;
    Title:=FBook.Title; Author:=TAuthorsHelper.GetList(FBook.Authors); Cover:='';
    if FView is TfrmBuiltinReader then TfrmBuiltinReader(FView).RecentBookDetails(Title,Author,Cover);
    RememberFile(FCurrentFile,FOpenedMembers,Title,Author,Cover);
  end;
  if (FSession.ID='') or FSessionReply.Opened or (FSessionReply.State<>'displaying') then Exit;
  FSessionReply.Opened:=True;
  SendSessionState('displaying');
end;

procedure TfrmReaderHost.Tick(Sender: TObject);
var FileName: string;
begin
  if FPreparing and not ReaderPreparationsPending(Self) then FPreparing:=False;
  if FDisplaying then begin ConfirmSessionOpened; OfferFollowingBook; Exit; end;
  if FPreparing or FExitRequested then Exit;
  // Installation always restarts through the helper. Retrying a partially
  // installed module here would reopen the same prompt every timer tick.
  if FPendingComponent<>'' then Exit;
  if FNextSession<>'' then
  begin FileName:=FNextSession; FNextSession:=''; BeginSession(FileName); Exit; end;
  if FNextFile='' then
  begin
    // A direct launch has no launcher window to return to after an error or cancellation.
    if FDirectLaunch and not FRestarting and (Application.ModalLevel=0) then
    begin FinishSession('closed'); Close; end
    else CheckModuleCleanup;
    Exit;
  end;
  FileName:=FNextFile; FNextFile:=''; FinishSession('closed'); Prepare(FileName);
end;

procedure TfrmReaderHost.Prepare(const FileName: string);
var OnArchiveOpened: TProc<TReaderArchiveSelection>;
begin
  try
    FOpenedMembers:=nil; FArchiveAmbiguous:=False; OnArchiveOpened:=nil;
    if (FSession.ID<>'') and ReaderSessionSourceMatches(FSession,FileName) then FBook:=FSession.Book
    else FBook:=FileBook(FileName);
    FCurrentFile:=FileName;
    if FSession.OriginalSource<>'' then FCurrentFile:=FSession.OriginalSource;
    if FBook.Title='' then FBook.Title:=ExtractFileName(FileName);
    FExportBook:=Default(TBookRecord);
    if FSession.ID='' then OnArchiveOpened:=
      procedure(Selection: TReaderArchiveSelection)
      begin
        FOpenedMembers:=Selection.Opened; FArchiveAmbiguous:=Selection.Ambiguous;
        if FArchiveAmbiguous and (Length(FOpenedMembers)>0) then
          FBook.Title:=ChangeFileExt(ExtractFileName(FOpenedMembers[High(FOpenedMembers)].Replace('/','\')),'');
      end;
    FPreparing:=True; SetStatus('Открытие книги…');
    // First retain the selected original payload for Save As. Kindle and
    // Office preparation belongs only to the subsequent reading view.
    PrepareReaderFileInBackground(Self,FBook,True,
      procedure(Original: string)
      begin
        try
          if Original='' then
          begin FPreparing:=False; FinishSession('closed'); RefreshRecentView; Exit; end;
          FExportBook:=FileBook(ExistingBookCacheFile(Original)); FExportBook.Title:=FBook.Title;
          PrepareReaderFileInBackground(Self,FExportBook,True,
            procedure(Prepared: string)
            begin
              FPreparing:=False;
              if Prepared<>'' then Display(Prepared)
              else begin FinishSession('closed'); RefreshRecentView; end;
            end,
            False,True,True,
            nil,procedure(IDs:TArray<string>) begin FPreparing:=False; MissingComponents(IDs); end);
        except
          on E: Exception do
          begin
            FPreparing:=False; SendSessionState('failed',E.Message);
            LogDiagnosticError('reader-prepare-file',E); MessageDlg(E.Message,mtError,[mbOK],0);
          end;
        end;
      end,False,False,False,
      nil,procedure(IDs:TArray<string>) begin FPreparing:=False; MissingComponents(IDs); end,
      FExpectedMembers,OnArchiveOpened);
  except
    on E: Exception do
    begin
      FPreparing:=False; SendSessionState('failed',E.Message);
      LogDiagnosticError('reader-open-file',E); MessageDlg(E.Message,mtError,[mbOK],0);
    end;
  end;
end;

procedure TfrmReaderHost.Display(const FileName: string);
var Identity, SettingsFile, Required, Container, Member: string;
  ViewInput, ExportInput: TStream; WasVisible, Standalone: Boolean; StartPosition: Integer;
begin
  FDisplaying:=True; Required:=''; ViewInput:=nil; ExportInput:=nil; WasVisible:=Visible;
  try
   try
    // Keep the displayed payload and Save As input alive during explicit
    // cache cleanup, including after their short preparation pins expire.
    ViewInput:=OpenCachedBookFile(FileName);
    ExportInput:=OpenCachedBookFile(FExportBook.GetBookFileName);
    PinReaderCacheFile(FileName);
    Identity:=ReaderHistoryName(FBook,''); SettingsFile:=ResolveReaderSettingsFile(Settings.DataDir);
    Standalone:=(FSession.ID='') or ((FBook.BookKey.DatabaseID=0) and FBook.LibID.StartsWith('local-file:'));
    StartPosition:=-1;
    if FSession.ID<>'' then
    begin Identity:=FSession.HistoryIdentity; SettingsFile:=FSession.SettingsFile; end
    else
    begin
      if FNoteTarget.BookID<>'' then
      begin
        if (Length(FOpenedMembers)>0) and (Length(FExpectedMembers)=0) then
          raise EReadError.Create('В старой заметке не сохранено имя книги внутри архива.');
        if FNoteTarget.BookID<>ReaderNoteIdentity(Identity) then
          Identity:=StandaloneHistory(FBook,FOpenedMembers);
        if FNoteTarget.BookID<>ReaderNoteIdentity(Identity) then
          raise EReadError.Create('Содержимое исходного файла изменилось. Не удалось открыть место с заметкой.');
        StartPosition:=FNoteTarget.Position;
      end;
      FRecentMetadataPending:=True;
      if FNoteTarget.BookID='' then
        try BindStandaloneNoteSource(SettingsFile,FCurrentFile,FBook,FOpenedMembers,FArchiveAmbiguous,Identity);
        except on E: Exception do LogDiagnosticError('reader-note-source-save',E); end;
    end;
    if SameText(ExtractFileExt(FileName),'.sm') then
    begin
      Container:=''; if SameText(ExtractFileExt(FCurrentFile),'.zip') then Container:=FCurrentFile;
      Member:='';
      if FSession.OriginalSource<>'' then Member:=FSession.OriginalMember
      else if (Container<>'') and (FSession.ID<>'') then Member:=FBook.FileName+FBook.FileExt;
      FView:=TStandaloneStoryReader.CreateStory(Self,Settings.AppPath,FileName,FBook.Title,Identity,
        SettingsFile,Settings.AppPath+'tools\pdfium\pdfium.dll',Container,Member,ExtractFileDir(FCurrentFile));
    end
    else
    begin
      Required:=RequiredReaderComponent(Settings.AppPath,ExtractFileExt(FileName));
      if Required<>'' then begin MissingComponent(Required); Exit; end;
      if not ReaderSupportsReflow(FileName) and not SameText(ExtractFileExt(FileName),'.pdf') then
        raise Exception.Create('Не удалось подготовить этот формат для чтения.');
      if Assigned(FHomeView) then
      begin
        FView:=FHomeView; FHomeView:=nil;
        FHomeList:=nil; FHomeImages:=nil; FHomeStatus:=nil;
        TForm(FView).OnCloseQuery:=nil;
        TfrmBuiltinReader(FView).RemoveStartPage;
        TForm(FView).Menu.Free; TForm(FView).Menu:=nil;
      end
      else FView:=TStandaloneBookReader.Create(Self);
      FCanFollowComic:=Standalone and (Length(FOpenedMembers)=0) and (FSession.OriginalMember='') and
        (Pos('|'+LowerCase(ExtractFileExt(FileName))+'|','|.cbz|.cbr|.cb7|')>0);
      if (FCanFollowComic or (FSession.NextVolume.Book.Key.BookID>0)) and FOfferFollowingComic then
        TfrmBuiltinReader(FView).OnReadPastEnd:=LookForFollowingBook;
      if Standalone then TfrmBuiltinReader(FView).OnOpenNote:=
        procedure(Note: TReaderAnnotation) begin OpenNote(Note); end;
      TfrmBuiltinReader(FView).OpenBook(FileName,FBook.Title,Identity,SettingsFile,
        Settings.AppPath+'tools\pdfium\pdfium.dll',
        procedure(Progress: Integer)
        begin FSessionReply.HasProgress:=True; FSessionReply.Progress:=Progress; SendSessionState('displaying'); end,
        StartPosition);
    end;
    TForm(FView).PopupMode:=pmNone; TForm(FView).PopupParent:=nil;
    FView.Caption:='HomeLibre Reader — '+FBook.Title;
    SaveRestartState(Identity,SettingsFile,Member);
    InstallMenu(TForm(FView));
    RecordComponentUse('HomeLibReader');
    SendSessionState('displaying');
    // The book is the visible application while reading. Keeping the empty
    // launcher as its taskbar owner gives Alt+Tab/preview the wrong window.
    Hide;
    if Assigned(FHomeView) then FHomeView.Hide;
    FView.Hide;
    if FSaveContinuation.Token<>'' then PostMessage(Handle,WM_RESUME_BOOK_SAVE,0,0);
    FReaderClosedActive:=False; FPreviousViewClose:=TForm(FView).OnClose;
    TForm(FView).OnClose:=BookViewClosing;
    FCatalogueRecentSelection:=0;
    case FView.ShowModal of
      MR_CATALOGUE_RECENT: FSessionReply.RequestedCatalogueRecent:=FCatalogueRecentSelection;
      MR_CATALOGUE_NEXT_VOLUME: FSessionReply.RequestedNextVolume:=True;
    end;
    ConfirmSessionOpened;
    if FView is TfrmBuiltinReader then
    begin
      Required:=TfrmBuiltinReader(FView).RequiredComponent;
      FSessionReply.RequestedNote:=TfrmBuiltinReader(FView).RequestedNote;
    end;
    if Required='' then CheckModuleCleanup(True);
  except
    on E: EReaderComponentRequired do Required:=E.ComponentID;
    on E: EMHLComponentRequired do Required:=E.ComponentID;
    on E: Exception do
    begin
      SendSessionState('failed',E.Message);
      LogDiagnosticError('reader-display-file',E); MessageDlg(E.Message,mtError,[mbOK],0);
    end;
   end;
  finally
    FFollowingComic:=nil; FCanFollowComic:=False; FNextVolumePending:=False;
    FRecentMetadataPending:=False;
    FreeAndNil(FView);
    if not FRestarting then ClearRestartState;
    ExportInput.Free; ViewInput.Free; FDisplaying:=False;
    if FExitRequested then Close
    else if FUseStartPage and (FNextFile='') and (FNextSession='') then ShowStartPage
    else if WasVisible and not FDirectLaunch then Show;
  end;
  if Required<>'' then MissingComponent(Required)
  else if not FRestarting then
  begin
    FinishSession('closed');
    if FDirectLaunch and (FNextFile='') and (FNextSession='') then Close;
  end;
end;

procedure TfrmReaderHost.SaveRestartState(const Identity, SettingsFile, OriginalMember: string);
var Book: TBookRecord; Profile: string;
begin
  ClearRestartState; Profile:=ExtractFileDir(Settings.SettingsFileName);
  try
    Book:=FExportBook; Book.BookKey:=FBook.BookKey; Book.LibID:=FBook.LibID;
    Book.Title:=FBook.Title; Book.Lang:=FBook.Lang;
    FRestartRequest:=CreateReaderSession(ReaderRestartDirectory(Profile),Book,
      Identity,SettingsFile,FSession.RequirePersonalProgress,FCurrentFile,OriginalMember);
    FRestartLease:=TReaderSessionLease.Create(FRestartRequest);
    PublishReaderRestart(Profile,FRestartRequest.RequestFile);
  except
    on E: Exception do
    begin ClearRestartState; LogDiagnosticError('reader-restart-snapshot',E); end;
  end;
end;

procedure TfrmReaderHost.ClearRestartState;
var Profile: string;
begin
  Profile:=ExtractFileDir(Settings.SettingsFileName);
  RemoveReaderRestart(Profile); FreeAndNil(FRestartLease);
  CleanupReaderRestartSession(Profile,FRestartRequest.RequestFile);
  FRestartRequest:=Default(TReaderSessionRequest);
end;

procedure TfrmReaderHost.ReadRecent(Ini: TCustomIniFile);
var Entry: TRecentBook; Index: string;
begin
  FRecent.Clear;
  for var I:=0 to 9 do
  begin
    Index:=IntToStr(I);
    Entry.FileName:=Ini.ReadString('ReaderRecent','File'+Index,'');
    Entry.Title:=Ini.ReadString('ReaderRecent','Title'+Index,'');
    Entry.Author:=Ini.ReadString('ReaderRecent','Author'+Index,'');
    Entry.Cover:=Ini.ReadString('ReaderRecent','Cover'+Index,'');
    if Length(Entry.Cover)>16000 then Entry.Cover:='';
    if (Entry.FileName<>'') and TryArchiveMembers(
      Ini.ReadString('ReaderRecent','Members'+Index,'[]'),Entry.Members) then FRecent.Add(Entry);
  end;
end;

function TfrmReaderHost.RecentCaption(Index: Integer): string;
begin
  var Entry:=FRecent[Index];
  if Length(Entry.Members)=0 then Exit(Entry.FileName);
  Result:=Entry.Members[High(Entry.Members)]+' · '+ExtractFileName(Entry.FileName);
end;

procedure TfrmReaderHost.OpenRecent(Index: Integer);
begin
  if (Index<0) or (Index>=FRecent.Count) then Exit;
  var Entry:=FRecent[Index];
  QueueFile(Entry.FileName,Default(TReaderAnnotation),Entry.Members);
end;

procedure TfrmReaderHost.RefreshRecentView;
var Item: TListItem; Bitmap: Vcl.Graphics.TBitmap; Title: string; Picture: TJPEGImage; Stream: TBytesStream;
begin
  FRecentView.Items.BeginUpdate;
  try
    FRecentView.Clear;
    for var I:=0 to FRecent.Count-1 do FRecentView.Items.Add(RecentCaption(I));
  finally FRecentView.Items.EndUpdate; end;
  if not Assigned(FHomeList) then Exit;
  FHomeList.Items.BeginUpdate;
  try
    FHomeList.Items.Clear; FHomeImages.Clear;
    for var Entry in FRecent do
    begin
      Title:=Entry.Title;
      if Title='' then
      begin
        Title:=Entry.FileName;
        if Length(Entry.Members)>0 then Title:=Entry.Members[High(Entry.Members)];
        Title:=ChangeFileExt(ExtractFileName(Title.Replace('/','\')),'');
      end;
      Item:=FHomeList.Items.Add; Item.Caption:=Title; Item.SubItems.Add(Entry.Author);
      Bitmap:=Vcl.Graphics.TBitmap.Create;
      try
        Bitmap.SetSize(FHomeImages.Width,FHomeImages.Height);
        Bitmap.Canvas.Brush.Color:=FHomeList.Color;
        Bitmap.Canvas.FillRect(Bitmap.Canvas.ClipRect);
        if Entry.Cover<>'' then
          try
            Stream:=TBytesStream.Create(TNetEncoding.Base64.DecodeStringToBytes(Entry.Cover));
            try
              if Stream.Size<=12000 then
              begin
                Picture:=TJPEGImage.Create;
                try
                  Picture.LoadFromStream(Stream);
                  if (Picture.Width>0) and (Picture.Width<=78) and
                    (Picture.Height>0) and (Picture.Height<=108) then
                  begin
                    var Scale:=Min(Bitmap.Width/Picture.Width,Bitmap.Height/Picture.Height);
                    var W:=Max(1,Round(Picture.Width*Scale));
                    var H:=Max(1,Round(Picture.Height*Scale));
                    var X:=(Bitmap.Width-W) div 2; var Y:=(Bitmap.Height-H) div 2;
                    Bitmap.Canvas.StretchDraw(Rect(X,Y,X+W,Y+H),Picture);
                  end;
                finally Picture.Free; end;
              end;
            finally Stream.Free; end;
          except on E: Exception do LogDiagnosticError('reader-recent-cover',E); end;
        Item.ImageIndex:=FHomeImages.Add(Bitmap,nil);
      finally Bitmap.Free; end;
    end;
  finally FHomeList.Items.EndUpdate; end;
  ResizeHomeRecent(FHomeList);
  if FRecent.Count=0 then FHomeStatus.Caption:='Здесь появятся недавно открытые книги.'
  else FHomeStatus.Caption:='Двойной щелчок или Enter — открыть книгу.';
end;

procedure TfrmReaderHost.RememberFile(const FileName: string; const Members: TArray<string>;
  const Title, Author, Cover: string);
var PreviousMenu: TMainMenu; Ini: TMemIniFile; Lock: TFileMutex;
  Entry: TRecentBook; MembersJSON, Index: string;
begin
  try
    Lock:=TFileMutex.Create(Settings.SettingsFileName);
    try
      for var Attempt:=1 to 10 do
      begin
        if Lock.TryAcquire then Break;
        Sleep(10);
      end;
      if not Lock.Acquired then raise EWriteError.Create('Файл недавних книг занят.');
      Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
      try
        ReadRecent(Ini);
        MembersJSON:=ArchiveMembersJSON(Members);
        for var I:=FRecent.Count-1 downto 0 do
        begin
          Entry:=FRecent[I];
          if SameFileName(Entry.FileName,FileName) and ((Length(Entry.Members)=0) or
            (ArchiveMembersJSON(Entry.Members)=MembersJSON)) then FRecent.Delete(I);
        end;
        Entry.FileName:=FileName; Entry.Members:=Copy(Members);
        Entry.Title:=Copy(Title.Replace(#13,' ').Replace(#10,' '),1,512);
        Entry.Author:=Copy(Author.Replace(#13,' ').Replace(#10,' '),1,512);
        Entry.Cover:=Cover;
        FRecent.Insert(0,Entry);
        if FRecent.Count>10 then FRecent.Delete(FRecent.Count-1);
        Ini.EraseSection('ReaderRecent');
        for var I:=0 to FRecent.Count-1 do
        begin
          Index:=IntToStr(I); Entry:=FRecent[I];
          Ini.WriteString('ReaderRecent','File'+Index,Entry.FileName);
          if Entry.Title<>'' then Ini.WriteString('ReaderRecent','Title'+Index,Entry.Title);
          if Entry.Author<>'' then Ini.WriteString('ReaderRecent','Author'+Index,Entry.Author);
          if Entry.Cover<>'' then Ini.WriteString('ReaderRecent','Cover'+Index,Entry.Cover);
          if Length(Entry.Members)>0 then
            Ini.WriteString('ReaderRecent','Members'+Index,ArchiveMembersJSON(Entry.Members));
        end;
        SaveMemIniFileAtomically(Ini);
      finally Ini.Free; end;
    finally Lock.Free; end;
  except on E: Exception do LogDiagnosticError('reader-recent-save',E); end;
  RefreshRecentView;
  PreviousMenu:=Menu; Menu:=nil; PreviousMenu.Free; InstallMenu(Self);
end;

procedure TfrmReaderHost.HostCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:=not FDisplaying;
  if CanClose and DeferCloseForReaderPreparation(Self) then
  begin
    CanClose:=False;
    FExitRequested:=True;
    SetStatus('Отмена подготовки книги…');
  end;
  if not CanClose then FHostCloseRequested:=True;
end;

end.
