unit frm_ReaderHost;

interface

uses System.Classes, System.SysUtils, Winapi.Messages, Vcl.Forms, Vcl.Controls, Vcl.Menus, Vcl.StdCtrls,
  Vcl.ExtCtrls, unit_Globals, frm_ProgramUpdate, unit_ReaderSession, unit_BookSaveContinuation;

type
  TfrmReaderHost = class(TForm)
  private
    FRecent: TStringList;
    FRecentView: TListBox;
    FStatus: TLabel;
    FTimer: TTimer;
    FView: TCustomForm;
    FUpdates: TfrmProgramUpdate;
    FBook, FExportBook: TBookRecord;
    FCurrentFile, FNextFile, FPendingComponent: string;
    FPreparing, FDisplaying, FExitRequested: Boolean;
    FNextSession: string;
    FSession: TReaderSessionRequest;
    FSessionReply: TReaderSessionReply;
    FSessionLease: TReaderSessionLease;
    FRestarting, FDirectLaunch: Boolean;
    FSaveContinuation: TBookSaveContinuation;
    FResumingSave: Boolean;
    procedure ResumeBookSave(var Message: TMessage); message WM_RESUME_BOOK_SAVE;
    procedure BeginSession(const RequestFile: string);
    procedure SendSessionState(const State: string; const ErrorText: string = '');
    procedure FinishSession(const State: string);
    procedure InstallMenu(Form: TForm);
    procedure OpenClick(Sender: TObject);
    procedure RecentClick(Sender: TObject);
    procedure RecentViewClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure ExitClick(Sender: TObject);
    procedure ComponentsClick(Sender: TObject);
    procedure FormatsClick(Sender: TObject);
    procedure CacheSettingsClick(Sender: TObject);
    procedure EnsureUpdates;
    procedure RestartForUpdate(Sender: TObject);
    procedure Tick(Sender: TObject);
    procedure Prepare(const FileName: string);
    procedure Display(const FileName: string);
    procedure MissingComponent(const ID: string);
    procedure RememberFile(const FileName: string);
    procedure SaveRecent;
    procedure HostCloseQuery(Sender: TObject; var CanClose: Boolean);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure OpenInitialFile(const FileName: string);
    procedure OpenInitialSession(const RequestFile: string);
    procedure OpenFile(const FileName: string);
  end;

var ReaderHost: TfrmReaderHost;

implementation

uses System.IOUtils, System.IniFiles, System.Math, Vcl.Dialogs,
  Vcl.Graphics, Winapi.Windows, unit_FileBooks, unit_Settings, unit_AtomicIniFile,
  unit_ReaderCache, unit_ReaderDocument, unit_ReaderFormats, unit_BookCache,
  unit_BookSendOptions, unit_BookExportResults, unit_ComponentUpdates,
  unit_ProgramUpdateInstaller, unit_Diagnostics, unit_MHLTheme, unit_MHLExternalTools, dm_user,
  frm_BuiltinReader, frm_StoryReader, frm_ReaderCacheSettings, unit_ReaderPalette;

type
  TStandaloneBookReader = class(TfrmBuiltinReader)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;
  TStandaloneStoryReader = class(TfrmStoryReader)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

procedure TStandaloneBookReader.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW) and not WS_EX_TOOLWINDOW;
end;

procedure TStandaloneStoryReader.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW) and not WS_EX_TOOLWINDOW;
end;

constructor TfrmReaderHost.Create(AOwner: TComponent);
var Intro: TLabel; OpenButton: TButton; Ini: TMemIniFile; Value: string;
begin
  inherited CreateNew(AOwner);
  Name:='ReaderHost'; Caption:='HomeLib Reader'; Position:=poScreenCenter;
  Font.Name:='Segoe UI'; Font.Size:=10; ClientWidth:=720; ClientHeight:=430;
  Constraints.MinWidth:=520; Constraints.MinHeight:=350;
  OnCloseQuery:=HostCloseQuery;
  FRecent:=TStringList.Create;
  Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
  try
    Value:=Ini.ReadString('ReaderSession','PendingFile','');
    if FileExists(Value) then FNextFile:=Value;
    Value:=Ini.ReadString('ReaderSession','PendingSession','');
    if FileExists(Value) then begin FNextSession:=Value; FNextFile:=''; end;
    Ini.DeleteKey('ReaderSession','PendingFile');
    Ini.DeleteKey('ReaderSession','PendingSession'); SaveMemIniFileAtomically(Ini);
    for var I:=0 to 9 do
    begin
      Value:=Ini.ReadString('ReaderRecent','File'+IntToStr(I),'');
      if Value<>'' then FRecent.Add(Value);
    end;
  finally Ini.Free; end;
  Intro:=TLabel.Create(Self); Intro.Parent:=Self; Intro.AutoSize:=False;
  Intro.WordWrap:=True; Intro.SetBounds(24,28,672,64); Intro.Anchors:=[akLeft,akTop,akRight];
  Intro.Caption:='Откройте книгу с компьютера. Настройки чтения, позиция, закладки и заметки сохраняются в профиле читалки.';
  OpenButton:=TButton.Create(Self); OpenButton.Parent:=Self; OpenButton.SetBounds(24,104,200,34);
  OpenButton.Caption:='Открыть книгу…'; OpenButton.OnClick:=OpenClick;
  FRecentView:=TListBox.Create(Self); FRecentView.Parent:=Self;
  FRecentView.SetBounds(24,158,672,208); FRecentView.Anchors:=[akLeft,akTop,akRight,akBottom];
  FRecentView.Items.Assign(FRecent); FRecentView.OnDblClick:=RecentViewClick;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Self; FStatus.AutoSize:=False; FStatus.WordWrap:=True;
  FStatus.SetBounds(24,380,672,40); FStatus.Anchors:=[akLeft,akRight,akBottom];
  FStatus.Caption:='Недавние книги — двойной щелчок для открытия.';
  InstallMenu(Self); ApplyMHLControlTheme(Self);
  FTimer:=TTimer.Create(Self); FTimer.Interval:=150; FTimer.OnTimer:=Tick;
  try TakeBookSaveContinuation(Settings.SettingsFileName,FSaveContinuation);
  except on E: Exception do begin LogDiagnosticError('reader-save-resume-load',E); FStatus.Caption:=E.Message; end; end;
end;

destructor TfrmReaderHost.Destroy;
begin
  if Assigned(FTimer) then FTimer.Enabled:=False;
  CancelReaderPreparations(Self);
  if FRestarting then FreeAndNil(FSessionLease) else FinishSession('closed');
  FinishBookCacheSession;
  FUpdates.Free; FUpdates:=nil;
  if Assigned(FRecent) then begin SaveRecent; FRecent.Free; end;
  inherited;
end;

procedure TfrmReaderHost.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // CreateNew does not set VCL's FCreatingMainForm flag. This host must be
  // its own taskbar window rather than a popup owned by the hidden app HWND.
  Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW) and not WS_EX_TOOLWINDOW;
end;

procedure TfrmReaderHost.InstallMenu(Form: TForm);
var Menu: TMainMenu; FileMenu, Item, RecentMenu, SettingsMenu: TMenuItem;
  procedure Add(const Text: string; Shortcut: TShortCut; Action: TNotifyEvent);
  begin
    Item:=TMenuItem.Create(Menu); Item.Caption:=Text; Item.ShortCut:=Shortcut;
    Item.OnClick:=Action; FileMenu.Add(Item);
  end;
begin
  Menu:=TMainMenu.Create(Form); FileMenu:=TMenuItem.Create(Menu);
  FileMenu.Caption:='Файл'; Menu.Items.Add(FileMenu);
  Add('Открыть…',ShortCut(Ord('O'),[ssCtrl]),OpenClick);
  RecentMenu:=TMenuItem.Create(Menu); RecentMenu.Caption:='Недавние книги'; FileMenu.Add(RecentMenu);
  for var I:=0 to FRecent.Count-1 do
  begin
    Item:=TMenuItem.Create(Menu); Item.Caption:=FRecent[I].Replace('&','&&');
    Item.Tag:=I; Item.OnClick:=RecentClick; RecentMenu.Add(Item);
  end;
  RecentMenu.Enabled:=FRecent.Count>0;
  Add('Сохранить как…',ShortCut(Ord('S'),[ssCtrl,ssShift]),SaveClick);
  Add('-',0,nil); Add('Закрыть читалку',ShortCut(VK_F4,[ssAlt]),ExitClick);
  SettingsMenu:=TMenuItem.Create(Menu); SettingsMenu.Caption:='Настройки'; Menu.Items.Add(SettingsMenu);
  Item:=TMenuItem.Create(Menu); Item.Caption:='Кэш книг…'; Item.OnClick:=CacheSettingsClick;
  SettingsMenu.Add(Item);
  Item:=TMenuItem.Create(Menu); Item.Name:='ReaderFormatsHelp'; Item.Caption:='Форматы чтения…'; Item.OnClick:=FormatsClick;
  SettingsMenu.Add(Item);
  Item:=TMenuItem.Create(Menu); Item.Caption:='Компоненты…'; Item.OnClick:=ComponentsClick;
  Menu.Items.Add(Item); Form.Menu:=Menu;
  if Form is TfrmBuiltinReader then TfrmBuiltinReader(Form).RefreshWindowTheme;
end;

procedure TfrmReaderHost.FormatsClick(Sender: TObject);
var Dialog: TForm; Text: TMemo; CloseButton: TButton;
begin
  Dialog:=TForm.CreateNew(Self);
  try
    Dialog.Name:='ReaderFormatsDialog'; Dialog.Caption:='Форматы и обновления читалки';
    Dialog.Position:=poMainFormCenter; Dialog.Font.Assign(Font);
    Dialog.ClientWidth:=650; Dialog.ClientHeight:=420;
    Dialog.Constraints.MinWidth:=460; Dialog.Constraints.MinHeight:=300;
    Text:=TMemo.Create(Dialog); Text.Parent:=Dialog; Text.Name:='ReaderFormatsText';
    Text.ReadOnly:=True; Text.ScrollBars:=ssVertical; Text.WordWrap:=True;
    Text.SetBounds(16,16,618,340); Text.Anchors:=[akLeft,akTop,akRight,akBottom];
    Text.Text:=ComponentPurpose('HomeLibReader');
    CloseButton:=TReaderPaletteButton.Create(Dialog); CloseButton.Parent:=Dialog; CloseButton.Caption:='Закрыть';
    CloseButton.SetBounds(524,372,110,30); CloseButton.Anchors:=[akRight,akBottom];
    CloseButton.Default:=True; CloseButton.Cancel:=True; CloseButton.ModalResult:=mrOk;
    Dialog.ScaleForPPI(CurrentPPI);
    if FView is TfrmBuiltinReader then TfrmBuiltinReader(FView).ApplyWindowPalette(Dialog)
    else ApplyMHLControlTheme(Dialog);
    Dialog.ShowModal;
  finally Dialog.Free; end;
end;

procedure TfrmReaderHost.OpenClick(Sender: TObject);
var Dialog: TOpenDialog; ParentWindow: THandle;
begin
  if FPreparing then Exit;
  ParentWindow:=Handle; if Assigned(FView) then ParentWindow:=FView.Handle;
  Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Title:='Открыть книгу'; Dialog.Filter:='Книги и документы|*.*';
    Dialog.Options:=[ofFileMustExist,ofPathMustExist,ofEnableSizing];
    if Dialog.Execute(ParentWindow) then OpenFile(Dialog.FileName);
  finally Dialog.Free; end;
end;

procedure TfrmReaderHost.OpenFile(const FileName: string);
begin
  FNextFile:=TPath.GetFullPath(FileName); FNextSession:=''; FPendingComponent:='';
  if Assigned(FView) then begin FView.ModalResult:=mrRetry; FView.Close; end;
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
begin
  var Index:=TMenuItem(Sender).Tag;
  if (Index>=0) and (Index<FRecent.Count) then OpenFile(FRecent[Index]);
end;

procedure TfrmReaderHost.RecentViewClick(Sender: TObject);
begin
  if FRecentView.ItemIndex>=0 then OpenFile(FRecentView.Items[FRecentView.ItemIndex]);
end;

procedure TfrmReaderHost.SaveClick(Sender: TObject);
var Options: TBookSendOptions; Results: TBookExportResults; Required: string;
begin
  if FPreparing or (FCurrentFile='') or (FExportBook.FileName='') then Exit;
  try
    var Initial: PBookSendOptions:=nil; if FResumingSave then Initial:=@FSaveContinuation.Options;
    if not ChooseBookSendOptions(1,Settings.SyncExportDir,emEpub,Options,False,[FExportBook],Initial) then
    begin
      if Options.RequiredComponent<>'' then
      begin
        StoreBookSaveContinuation(Settings.SettingsFileName,Options.RequiredComponent,Options,nil,FCurrentFile);
        EnsureUpdates; FUpdates.RequestComponent(Options.RequiredComponent,
          'Для оценки размера нужен дополнительный модуль. После установки вернёмся к сохранению книги.',True);
      end;
      Exit;
    end;
    Results:=SaveFileBook(FExportBook,Options,Required);
    if Required<>'' then
    begin
      StoreBookSaveContinuation(Settings.SettingsFileName,Required,Options,nil,FCurrentFile);
      EnsureUpdates;
      FUpdates.RequestComponent(Required,'Для выбранного сохранения нужен дополнительный модуль. '+
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
  FExitRequested:=True;
  if Assigned(FView) then begin FView.ModalResult:=mrCancel; FView.Close; end else Close;
end;

procedure TfrmReaderHost.EnsureUpdates;
begin
  if Assigned(FUpdates) then Exit;
  FUpdates:=TfrmProgramUpdate.Create(Self);
  FUpdates.UseReaderComponents; FUpdates.OnRestart:=RestartForUpdate;
end;

procedure TfrmReaderHost.RestartForUpdate(Sender: TObject);
var Ini: TMemIniFile;
begin
  Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
  try
    Ini.DeleteKey('ReaderSession','PendingFile'); Ini.DeleteKey('ReaderSession','PendingSession');
    if FSession.ID<>'' then Ini.WriteString('ReaderSession','PendingSession',FSession.RequestFile)
    else Ini.WriteString('ReaderSession','PendingFile',FCurrentFile);
    SaveMemIniFileAtomically(Ini);
    if not FUpdates.LaunchInstallation then
    begin
      Ini.DeleteKey('ReaderSession','PendingFile'); Ini.DeleteKey('ReaderSession','PendingSession');
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

procedure TfrmReaderHost.MissingComponent(const ID: string);
var Title: string;
begin
  Title:=ID;
  for var Component in UPDATE_COMPONENTS do if Component.ID=ID then Title:=Component.Title;
  FPendingComponent:=ID; FStatus.Caption:='Для этой книги нужен компонент «'+Title+'».';
  FSessionReply.RequiredComponent:=ID; SendSessionState('component_required');
  EnsureUpdates;
  FUpdates.RequestComponent(ID,FStatus.Caption,True);
end;

procedure TfrmReaderHost.Tick(Sender: TObject);
var FileName: string;
begin
  if FPreparing and not ReaderPreparationsPending(Self) then FPreparing:=False;
  if FPreparing or FDisplaying then Exit;
  // Installation always restarts through the helper. Retrying a partially
  // installed module here would reopen the same prompt every timer tick.
  if FPendingComponent<>'' then Exit;
  if FNextSession<>'' then
  begin FileName:=FNextSession; FNextSession:=''; BeginSession(FileName); Exit; end;
  if FNextFile='' then Exit;
  FileName:=FNextFile; FNextFile:=''; FinishSession('closed'); Prepare(FileName);
end;

procedure TfrmReaderHost.Prepare(const FileName: string);
begin
  try
    if (FSession.ID<>'') and ReaderSessionSourceMatches(FSession,FileName) then FBook:=FSession.Book
    else FBook:=FileBook(FileName);
    FCurrentFile:=FileName;
    if FBook.Title='' then FBook.Title:=ExtractFileName(FileName);
    FExportBook:=Default(TBookRecord);
    FPreparing:=True; FStatus.Caption:='Открытие книги…';
    // First retain the selected original payload for Save As. Kindle and
    // Office preparation belongs only to the subsequent reading view.
    PrepareReaderFileInBackground(Self,FBook,True,
      procedure(Original: string)
      begin
        try
          if Original='' then begin FPreparing:=False; FinishSession('closed'); Exit; end;
          FExportBook:=FileBook(ExistingBookCacheFile(Original)); FExportBook.Title:=FBook.Title;
          PrepareReaderFileInBackground(Self,FExportBook,True,
            procedure(Prepared: string)
            begin
              FPreparing:=False;
              if Prepared<>'' then Display(Prepared) else FinishSession('closed');
            end,
            False,True,True,
            procedure(ID: string) begin FPreparing:=False; MissingComponent(ID); end);
        except
          on E: Exception do
          begin
            FPreparing:=False; SendSessionState('failed',E.Message);
            LogDiagnosticError('reader-prepare-file',E); MessageDlg(E.Message,mtError,[mbOK],0);
          end;
        end;
      end,False,False,False,
      procedure(ID: string) begin FPreparing:=False; MissingComponent(ID); end);
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
  ViewInput, ExportInput: TStream; WasVisible: Boolean;
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
    if FSession.ID<>'' then
    begin Identity:=FSession.HistoryIdentity; SettingsFile:=FSession.SettingsFile; end
    else RememberFile(FCurrentFile);
    if SameText(ExtractFileExt(FileName),'.sm') then
    begin
      Container:=''; if SameText(ExtractFileExt(FCurrentFile),'.zip') then Container:=FCurrentFile;
      Member:=''; if (Container<>'') and (FSession.ID<>'') then Member:=FBook.FileName+FBook.FileExt;
      FView:=TStandaloneStoryReader.CreateStory(Self,Settings.AppPath,FileName,FBook.Title,Identity,
        SettingsFile,Settings.AppPath+'tools\pdfium\pdfium.dll',Container,Member,ExtractFileDir(FCurrentFile));
    end
    else
    begin
      Required:=RequiredReaderComponent(Settings.AppPath,ExtractFileExt(FileName));
      if Required<>'' then begin MissingComponent(Required); Exit; end;
      if not ReaderSupportsReflow(FileName) and not SameText(ExtractFileExt(FileName),'.pdf') then
        raise Exception.Create('Не удалось подготовить этот формат для чтения.');
      FView:=TStandaloneBookReader.Create(Self);
      TfrmBuiltinReader(FView).OpenBook(FileName,FBook.Title,Identity,SettingsFile,
        Settings.AppPath+'tools\pdfium\pdfium.dll',
        procedure(Progress: Integer)
        begin FSessionReply.HasProgress:=True; FSessionReply.Progress:=Progress; SendSessionState('displaying'); end);
    end;
    TForm(FView).PopupMode:=pmNone; TForm(FView).PopupParent:=nil;
    FView.Caption:='HomeLib Reader — '+FBook.Title;
    InstallMenu(TForm(FView));
    SendSessionState('displaying');
    // The book is the visible application while reading. Keeping the empty
    // launcher as its taskbar owner gives Alt+Tab/preview the wrong window.
    Hide;
    if FSaveContinuation.Token<>'' then PostMessage(Handle,WM_RESUME_BOOK_SAVE,0,0);
    FView.ShowModal;
    if FView is TfrmBuiltinReader then
    begin
      Required:=TfrmBuiltinReader(FView).RequiredComponent;
      FSessionReply.RequestedNote:=TfrmBuiltinReader(FView).RequestedNote;
    end;
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
    FreeAndNil(FView); ExportInput.Free; ViewInput.Free; FDisplaying:=False;
    if FExitRequested then Close
    else if WasVisible and not FDirectLaunch then Show;
  end;
  if Required<>'' then MissingComponent(Required)
  else if not FRestarting then
  begin
    FinishSession('closed');
    if FDirectLaunch and (FNextFile='') and (FNextSession='') then Close;
  end;
end;

procedure TfrmReaderHost.RememberFile(const FileName: string);
var PreviousMenu: TMainMenu;
begin
  for var I:=FRecent.Count-1 downto 0 do if SameFileName(FRecent[I],FileName) then FRecent.Delete(I);
  FRecent.Insert(0,FileName); while FRecent.Count>10 do FRecent.Delete(FRecent.Count-1);
  FRecentView.Items.Assign(FRecent); SaveRecent;
  PreviousMenu:=Menu; Menu:=nil; PreviousMenu.Free; InstallMenu(Self);
end;

procedure TfrmReaderHost.SaveRecent;
var Ini: TMemIniFile;
begin
  Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
  try
    Ini.EraseSection('ReaderRecent');
    for var I:=0 to FRecent.Count-1 do Ini.WriteString('ReaderRecent','File'+IntToStr(I),FRecent[I]);
    SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
end;

procedure TfrmReaderHost.HostCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:=not FDisplaying;
  if CanClose then CancelReaderPreparations(Self);
end;

end.
