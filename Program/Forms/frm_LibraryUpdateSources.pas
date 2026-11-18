unit frm_LibraryUpdateSources;

interface

uses System.Classes, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  unit_Interfaces, unit_CatalogSources, unit_LibraryUpdateSources, unit_LibraryUpdateFetch,
  unit_LibraryUpdateReview, unit_LibraryUpdateContinuation,
  frm_CatalogSources, unit_ContextToolGuide;

type
  TfrmLibraryUpdateSourceEditor = class(TSourceDialogForm)
  private
    FSource: TLibraryUpdateSource;
    FCatalogSources: TCatalogSources;
    FName, FLocation, FIndex, FVersion, FBooks, FPreviousIndex: TEdit;
    FTarget: TComboBox;
    FFull, FEnabled: TCheckBox;
    procedure BrowseLocation(Sender: TObject);
    procedure BrowseBooks(Sender: TObject);
    procedure BrowseIndex(Sender: TObject);
    procedure BrowsePreviousIndex(Sender: TObject);
    procedure Accept(Sender: TObject);
  public
    constructor CreateForSource(AOwner: TComponent; const Source: TLibraryUpdateSource;
      const CatalogSources: TCatalogSources; AllowPreviousIndex: Boolean = False);
    function EditedSource: TLibraryUpdateSource;
    property Source: TLibraryUpdateSource read FSource;
  end;

  TfrmLibraryUpdateSources = class(TSourceDialogForm)
  private
    FCollection: IBookCollection;
    FSources: TLibraryUpdateSources;
    FBody: TSourceScrollBox;
    FHeader, FFooter: TPanel;
    FToolGuide: TContextToolGuide;
    FIntro, FReport: TLabel;
    FList: TListView;
    FButtons: TArray<TButton>;
    FPrepared: TStagedLibraryIndex;
    FReview: TLibraryUpdateReview;
    FSelectedIndex: Integer;
    FRebuilding, FLayoutBusy, FAllowPreviousIndex: Boolean;
    FCommitted: Boolean;
    FPublishedCollectionID: Integer;
    FBeforeApply: TNotifyEvent;
    FAllowModuleRestart,FResumed,FPreferNewOnResume:Boolean;
    FPendingRestart:ILibraryUpdateRestart;
    FRestartComponents:TArray<string>;
    procedure Rebuild(Index: Integer);
    procedure Selected(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure AddSource(Sender: TObject);
    procedure EditSource(Sender: TObject);
    procedure RemoveSource(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure CheckClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure CopyReport(Sender: TObject);
    procedure CopyNeeded(Sender: TObject);
    procedure SaveMissing(Sender: TObject);
    procedure InvalidatePrepared;
    procedure UpdateApplyAction;
    procedure FetchAndReview(const Restart:ILibraryUpdateRestart);
    procedure ReviewIndex(const Proof:TLibraryUpdateRestartRequest; var Previous:TStagedLibraryIndex);
    procedure Layout;
    procedure Resize; override;
    procedure SetReport(const Text: string);
    function GetSources: TLibraryUpdateSources;
    function SelectionIndex: Integer;
    procedure DoShow; override;
    procedure DoHide; override;
  public
    constructor CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
    destructor Destroy; override;
    procedure AppendSource(const Source: TLibraryUpdateSource);
    procedure ReplaceSource(Index: Integer; const Source: TLibraryUpdateSource);
    procedure ImportFile(const FileName: string);
    procedure ExportFile(const FileName: string);
    procedure SaveSources;
    procedure CheckSource;
    procedure RestoreRestart(const Restart:ILibraryUpdateRestart);
    procedure ApplyReviewed(PreferNewRoot: Boolean);
    procedure SelectProfile(const ID: string);
    property Sources: TLibraryUpdateSources read GetSources;
    property Prepared: TStagedLibraryIndex read FPrepared;
    property Review: TLibraryUpdateReview read FReview;
    property Committed: Boolean read FCommitted;
    property PublishedCollectionID: Integer read FPublishedCollectionID;
    property BeforeApply: TNotifyEvent read FBeforeApply write FBeforeApply;
    property AllowModuleRestart:Boolean read FAllowModuleRestart write FAllowModuleRestart;
    property PendingRestart:ILibraryUpdateRestart read FPendingRestart;
    property RestartComponents:TArray<string> read FRestartComponents;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Math, System.Variants, System.Net.HttpClient,
  Winapi.Windows, Vcl.Dialogs, Vcl.FileCtrl, Vcl.Clipbrd,
  unit_Consts, unit_Settings, unit_WorkerThread, unit_CollectionWorkerThread, unit_MHLHttpClient, dm_user,
  frm_ImportProgressFormEx, unit_CollectionPacking, unit_CatalogComponents;

procedure FitWindow(Form: TCustomForm);
var Area: TRect;
begin
  Area:=Form.Monitor.WorkareaRect;
  Form.Width:=Min(Form.Width,Area.Width-24); Form.Height:=Min(Form.Height,Area.Height-48);
end;

constructor TfrmLibraryUpdateSourceEditor.CreateForSource(AOwner: TComponent;
  const Source: TLibraryUpdateSource; const CatalogSources: TCatalogSources; AllowPreviousIndex: Boolean);
var Body: TSourceScrollBox; Footer: TPanel; B: TButton; L: TLabel; Y: Integer;
  function Edit(const Caption, Name, Text: string): TEdit;
  begin
    L:=TLabel.Create(Self); L.Parent:=Body; L.AutoSize:=False; L.WordWrap:=True;
    L.SetBounds(12,Y,712,36); L.Anchors:=[akLeft,akTop,akRight]; L.Caption:=Caption;
    Result:=TEdit.Create(Self); Result.Parent:=Body; Result.Name:=Name;
    Result.SetBounds(12,Y+38,600,26); Result.Anchors:=[akLeft,akTop,akRight]; Result.Text:=Text;
    Inc(Y,78);
  end;
  procedure BrowseButton(Top: Integer; Handler: TNotifyEvent);
  begin
    B:=TButton.Create(Self); B.Parent:=Body; B.SetBounds(624,Top,100,27);
    B.Caption:='Выбрать…'; B.Anchors:=[akTop,akRight]; B.OnClick:=Handler;
  end;
begin
  inherited CreateNew(AOwner); FSource:=Source; FCatalogSources:=CatalogSources;
  Caption:='Источник обновлений'; Font.Name:='Segoe UI'; Font.Size:=9;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Position:=poOwnerFormCenter;
  ClientWidth:=740; ClientHeight:=580; Constraints.MinWidth:=480; Constraints.MinHeight:=280;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom; Footer.Height:=48; Footer.BevelOuter:=bvNone;
  B:=TButton.Create(Self); B.Parent:=Footer; B.Name:='btnAcceptUpdateSource'; B.Caption:='Готово';
  B.SetBounds(476,9,120,30); B.Anchors:=[akTop,akRight]; B.Default:=True; B.OnClick:=Accept;
  B:=TButton.Create(Self); B.Parent:=Footer; B.Caption:='Отмена'; B.SetBounds(608,9,120,30);
  B.Anchors:=[akTop,akRight]; B.Cancel:=True; B.ModalResult:=mrCancel;
  Body:=TSourceScrollBox.Create(Self); Body.Parent:=Self; Body.Align:=alClient;
  Body.BorderStyle:=bsNone; Body.HorzScrollBar.Visible:=False;
  Y:=12; FName:=Edit('Название для списка источников','edUpdateSourceName',Source.Name);
  FLocation:=Edit('Папка с новым индексом или адрес папки на сервере (HTTP/HTTPS)',
    'edUpdateSourceLocation',Source.Location); BrowseButton(FLocation.Top,BrowseLocation);
  FIndex:=Edit('Имя файла индекса: INPX, Metabib или прежний пакет обновления',
    'edUpdateSourceIndex',Source.IndexFile); BrowseButton(FIndex.Top,BrowseIndex);
  FVersion:=Edit('Файл с номером версии, если он предусмотрен источником (необязательно)',
    'edUpdateSourceVersion',Source.VersionFile);
  FBooks:=Edit('Папка с архивами книг (пусто — сохранить текущую папку)',
    'edUpdateSourceBooks',Source.BooksRoot); BrowseButton(FBooks.Top,BrowseBooks);
  if AllowPreviousIndex then
  begin
    FPreviousIndex:=Edit('Прежний полный INPX, по которому создавалась сжатая коллекция',
      'edUpdateSourcePreviousIndex',Source.PreviousIndexFile);
    BrowseButton(FPreviousIndex.Top,BrowsePreviousIndex);
  end;
  L:=TLabel.Create(Self); L.Parent:=Body; L.AutoSize:=False; L.WordWrap:=True;
  L.SetBounds(12,Y,712,36); L.Anchors:=[akLeft,akTop,akRight]; L.Caption:='Что обновлять в этой коллекции';
  FTarget:=TComboBox.Create(Self); FTarget.Parent:=Body; FTarget.Name:='cbUpdateSourceTarget';
  FTarget.SetBounds(12,Y+38,712,26); FTarget.Anchors:=[akLeft,akTop,akRight]; FTarget.Style:=csDropDownList;
  FTarget.Items.Add('Текущую коллекцию целиком'); FTarget.ItemIndex:=0;
  if Source.CatalogSourceID<>'' then FTarget.ItemIndex:=-1;
  for var I:=0 to High(FCatalogSources) do
  begin
    FTarget.Items.Add(FCatalogSources[I].Name);
    if SameText(Source.CatalogSourceID,FCatalogSources[I].ID) then FTarget.ItemIndex:=I+1;
  end;
  Inc(Y,78);
  FFull:=TCheckBox.Create(Self); FFull.Parent:=Body; FFull.Name:='cbUpdateSourceFull';
  FFull.SetBounds(12,Y,712,24); FFull.Caption:='Полный список книг'; FFull.Checked:=Source.Full;
  FFull.Anchors:=[akLeft,akTop,akRight]; Inc(Y,30);
  FEnabled:=TCheckBox.Create(Self); FEnabled.Parent:=Body; FEnabled.Name:='cbUpdateSourceEnabled';
  FEnabled.SetBounds(12,Y,712,24); FEnabled.Caption:='Источник включён'; FEnabled.Checked:=Source.Enabled;
  FEnabled.Anchors:=[akLeft,akTop,akRight]; Inc(Y,34);
  L:=TLabel.Create(Self); L.Parent:=Body; L.AutoSize:=False; L.WordWrap:=True;
  L.SetBounds(12,Y,712,70); L.Anchors:=[akLeft,akTop,akRight];
  L.Caption:='Для объединённой коллекции выберите конкретный источник. Metabib всегда содержит полный снимок. '+
    'Добавочный режим предназначен для прежних пакетов обновления. Архивы книг загружаются отдельно от индекса.';
  ScaleForPPI(Screen.PixelsPerInch); FitWindow(Self);
end;

procedure TfrmLibraryUpdateSourceEditor.BrowseLocation(Sender: TObject);
var Folder: string;
begin Folder:=FLocation.Text; if SelectDirectory('Папка с новым индексом','',Folder,[sdNewUI,sdShowEdit]) then FLocation.Text:=Folder; end;

procedure TfrmLibraryUpdateSourceEditor.BrowseBooks(Sender: TObject);
var Folder: string;
begin Folder:=FBooks.Text; if SelectDirectory('Папка с архивами книг','',Folder,[sdNewUI,sdShowEdit]) then FBooks.Text:=Folder; end;

procedure TfrmLibraryUpdateSourceEditor.BrowseIndex(Sender: TObject);
var Dialog: TOpenDialog;
begin
  Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Title:='Выберите новый индекс'; Dialog.Filter:='Индексы и пакеты|*.inpx;*.jsonl;*.zst;*.gz;*.zip|Все файлы|*.*';
    Dialog.Options:=[ofFileMustExist,ofPathMustExist,ofEnableSizing];
    if Dialog.Execute then
    begin FLocation.Text:=TPath.GetDirectoryName(Dialog.FileName); FIndex.Text:=TPath.GetFileName(Dialog.FileName); end;
  finally Dialog.Free; end;
end;

procedure TfrmLibraryUpdateSourceEditor.BrowsePreviousIndex(Sender: TObject);
var Dialog:TOpenDialog;
begin
  Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Title:='Выберите прежний полный INPX';
    Dialog.FileName:=FPreviousIndex.Text;
    Dialog.Filter:='Индекс книг INPX|*.inpx';
    Dialog.Options:=[ofFileMustExist,ofPathMustExist,ofEnableSizing];
    if Dialog.Execute then FPreviousIndex.Text:=Dialog.FileName;
  finally Dialog.Free; end;
end;

function TfrmLibraryUpdateSourceEditor.EditedSource: TLibraryUpdateSource;
begin
  Result:=FSource; Result.Name:=Trim(FName.Text); Result.Location:=Trim(FLocation.Text);
  Result.IndexFile:=Trim(FIndex.Text); Result.VersionFile:=Trim(FVersion.Text); Result.BooksRoot:=Trim(FBooks.Text);
  if Assigned(FPreviousIndex) then Result.PreviousIndexFile:=Trim(FPreviousIndex.Text);
  Result.Full:=FFull.Checked; Result.Enabled:=FEnabled.Checked;
  if FTarget.ItemIndex=0 then Result.CatalogSourceID:=''
  else if FTarget.ItemIndex>0 then Result.CatalogSourceID:=FCatalogSources[FTarget.ItemIndex-1].ID
  else if Result.Enabled then raise EArgumentException.Create('Выберите источник этой коллекции или отключите запись.');
  Result.Validate;
end;

procedure TfrmLibraryUpdateSourceEditor.Accept(Sender: TObject);
begin
  try FSource:=EditedSource; ModalResult:=mrOk;
  except on E:Exception do MessageDlg(E.Message,mtError,[mbOK],0); end;
end;

type
  TFetchIndexWorker = class(TWorker)
  private
    FSource: TLibraryUpdateSource;
    FPrepared,FPrevious:TStagedLibraryIndex;
    FRestart:ILibraryUpdateRestart;
    FError: string;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(const Source: TLibraryUpdateSource; const Restart:ILibraryUpdateRestart);
    destructor Destroy; override;
    function TakePrepared: TStagedLibraryIndex;
    function TakePrevious:TStagedLibraryIndex;
  end;

constructor TFetchIndexWorker.Create(const Source: TLibraryUpdateSource; const Restart:ILibraryUpdateRestart);
begin inherited Create; FSource:=Source; FRestart:=Restart; end;

destructor TFetchIndexWorker.Destroy;
begin FPrevious.Free; FPrepared.Free; inherited; end;

function TFetchIndexWorker.TakePrepared: TStagedLibraryIndex;
begin Result:=FPrepared; FPrepared:=nil; end;

function TFetchIndexWorker.TakePrevious:TStagedLibraryIndex;
begin Result:=FPrevious; FPrevious:=nil; end;

procedure TFetchIndexWorker.WorkFunction;
var HTTP: THTTPClient; LastUpdate: UInt64; WorkRoot:string; Check:TProc;
begin
  HTTP:=nil; LastUpdate:=0;
  try
    try
      SetComment('Получение служебной копии индекса');
      Check:=procedure begin if Canceled then raise EAbort.Create('Получение индекса отменено.'); end;
      if Assigned(FRestart) then
      begin
        SetComment('Проверка сохранённых копий индексов');
        FPrepared:=FRestart.OpenIndex(False,Check);
        FPrevious:=FRestart.OpenIndex(True,Check);
        Exit;
      end;
      WorkRoot:=Settings.LibraryUpdateWorkPath;
      if FSource.IsRemote then HTTP:=CreateHTTPClientUpdate;
      FPrepared:=TStagedLibraryIndex.Fetch(FSource,WorkRoot,HTTP,
        Check,
        procedure(Done,Total:Int64)
        begin
          if (GetTickCount64-LastUpdate<200) and (Done<>Total) then Exit;
          LastUpdate:=GetTickCount64;
          if Total>0 then SetProgress(Round(100*Done/Total));
          SetComment(Format('Получено: %.2f МБ',[Done/1048576]));
        end);
    except on E:Exception do FError:=E.Message; end;
  finally HTTP.Free; end;
end;

constructor TfrmLibraryUpdateSources.CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
var B: TButton;
  procedure Button(const Name, Caption: string; Handler: TNotifyEvent);
  begin
    B:=TButton.Create(Self); B.Parent:=FFooter; B.Name:=Name; B.Caption:=Caption;
    B.OnClick:=Handler; FButtons:=FButtons+[B];
  end;
begin
  inherited CreateNew(AOwner); FCollection:=Collection; FSelectedIndex:=-1;
  FSources:=ReadLibraryUpdateSources(VarToStr(Collection.GetProperty(PROP_LIBRARY_UPDATE_SOURCES)));
  FAllowPreviousIndex:=(Length(LoadCatalogSources(Collection))=0) and
    (LegacyPackingSourceRoot(Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE))))<>'');
  Caption:='Источники обновлений — '+Collection.CollectionDisplayName;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=900; ClientHeight:=580; Constraints.MinWidth:=480; Constraints.MinHeight:=280;
  Position:=poOwnerFormCenter;
  FFooter:=TPanel.Create(Self); FFooter.Parent:=Self; FFooter.Align:=alBottom; FFooter.BevelOuter:=bvNone;
  FBody:=TSourceScrollBox.Create(Self); FBody.Parent:=Self; FBody.Align:=alClient;
  FBody.BorderStyle:=bsNone; FBody.HorzScrollBar.Visible:=False;
  FHeader:=TPanel.Create(Self); FHeader.Parent:=FBody; FHeader.SetBounds(0,0,900,90); FHeader.Align:=alTop;
  FHeader.BevelOuter:=bvNone;
  FIntro:=TLabel.Create(Self); FIntro.Parent:=FHeader; FIntro.AutoSize:=False; FIntro.WordWrap:=True;
  FIntro.Name:='UpdateSourcesIntro';
  FIntro.Caption:='Задайте, где искать новый список книг: на сервере или в локальной/сетевой папке. '+
    'Архивы книг скачиваются отдельно. Настройки сохраняются для этой коллекции и сохраняют привязку при её переименовании.';
  FToolGuide:=TContextToolGuide.CreateForTool(Self,FHeader,'library-update-sources','Как обновить библиотеку',
    'Укажите новый индекс и папку, куда вы докачали книжные архивы.',
    'Нажмите «Добавить…» и выберите папку или сервер с индексом. Если объединены несколько библиотек, выберите нужный источник.'+sLineBreak+
    'Нажмите «Проверить обновление». Кнопка «Копировать список» даст точные имена недостающих архивов. После докачки повторите проверку.'+sLineBreak+
    '«Применить обновление…» откроет план. Просмотрите его и подтвердите запись в каталог.'+sLineBreak+
    'Если у вас есть collections.ini, нажмите «Импорт настроек…», проверьте пути и включите нужные записи.',
    113,'sources');
  FToolGuide.Name:='UpdateSourcesContextGuide';
  FToolGuide.HelpButton.Name:='btnUpdateSourcesHelp';
  FToolGuide.HelpButton.Hint:='Как обновить библиотеку';
  FList:=TListView.Create(Self); FList.Parent:=FBody; FList.SetBounds(0,90,900,210); FList.Align:=alTop;
  FList.Name:='lvLibraryUpdateSources'; FList.ViewStyle:=vsReport; FList.ReadOnly:=True;
  FList.RowSelect:=True; FList.HideSelection:=False; FList.OnSelectItem:=Selected;
  FList.Columns.Add.Caption:='Включён'; FList.Columns[0].Width:=80;
  FList.Columns.Add.Caption:='Название'; FList.Columns[1].Width:=190;
  FList.Columns.Add.Caption:='Папка или сервер'; FList.Columns[2].Width:=300;
  FList.Columns.Add.Caption:='Индекс'; FList.Columns[3].Width:=280;
  FReport:=TLabel.Create(Self); FReport.Parent:=FBody; FReport.AutoSize:=False; FReport.WordWrap:=True;
  FReport.SetBounds(0,300,900,140); FReport.Align:=alTop; FReport.Name:='lblUpdateSourceReport';
  Button('btnAddUpdateSource','Добавить…',AddSource); Button('btnEditUpdateSource','Изменить…',EditSource);
  Button('btnRemoveUpdateSource','Убрать из списка',RemoveSource);
  Button('btnImportUpdateSources','Импорт настроек…',ImportClick);
  Button('btnExportUpdateSources','Экспорт настроек…',ExportClick);
  Button('btnCheckUpdateSource','Проверить обновление',CheckClick);
  Button('btnApplyUpdateSource','Применить обновление…',ApplyClick); B.Enabled:=False;
  Button('btnSaveUpdateSources','Сохранить',SaveClick);
  Button('btnCopyUpdateSourceReport','Копировать отчёт',CopyReport);
  Button('btnCopyNeededUpdateArchives','Копировать список',CopyNeeded);
  Button('btnSaveMissingUpdateBooks','Сохранить пропуски…',SaveMissing); B.Enabled:=False;
  Button('btnCloseUpdateSources','Закрыть',nil); B.Cancel:=True; B.ModalResult:=mrCancel;
  SetReport('Добавьте источник или выберите его в списке и нажмите «Проверить обновление».');
  Rebuild(0); ScaleForPPI(Screen.PixelsPerInch); FitWindow(Self); Layout;
end;

destructor TfrmLibraryUpdateSources.Destroy;
begin InvalidatePrepared; inherited; end;

procedure TfrmLibraryUpdateSources.InvalidatePrepared;
begin FResumed:=False; FreeAndNil(FReview); FreeAndNil(FPrepared); UpdateApplyAction; end;

procedure TfrmLibraryUpdateSources.UpdateApplyAction;
var Button: TComponent;
begin
  Button:=FindComponent('btnApplyUpdateSource');
  if Button is TButton then TButton(Button).Enabled:=Assigned(FReview) and FReview.Ready and not FReview.Applied;
  Button:=FindComponent('btnCopyNeededUpdateArchives');
  if Button is TButton then TButton(Button).Enabled:=Assigned(FReview) and FReview.Ready and
    (FReview.NeededArchives.Count>0);
  Button:=FindComponent('btnSaveMissingUpdateBooks');
  if Button is TButton then TButton(Button).Enabled:=Assigned(FReview) and
    FReview.MissingReportReady and (FReview.MissingBooks>0);
end;

function TfrmLibraryUpdateSources.GetSources: TLibraryUpdateSources;
begin Result:=Copy(FSources); end;

function TfrmLibraryUpdateSources.SelectionIndex: Integer;
begin
  Result:=FList.ItemIndex;
  if Result<0 then Result:=FSelectedIndex;
  if (Result<0) or (Result>=Length(FSources)) then Exit(-1);
  FSelectedIndex:=Result;
  FList.ItemIndex:=Result; FList.Items[Result].Selected:=True;
end;

procedure TfrmLibraryUpdateSources.DoShow;
begin
  inherited;
  SelectionIndex;
  if not FResumed then FToolGuide.FirstUse;
end;

procedure TfrmLibraryUpdateSources.DoHide;
begin
  if Assigned(FToolGuide) then FToolGuide.Hide;
  inherited;
end;

procedure TfrmLibraryUpdateSources.Layout;
var DPI, Gap, Width, Height, PerRow, Rows, I: Integer; R: TRect;
begin
  if FLayoutBusy or not Assigned(FReport) then Exit;
  FLayoutBusy:=True;
  try
    DPI:=Max(96,Font.PixelsPerInch); Gap:=MulDiv(10,DPI,96);
    Width:=MulDiv(146,DPI,96); Height:=MulDiv(32,DPI,96);
    for I:=0 to High(FButtons) do
    begin
      Canvas.Font.Assign(FButtons[I].Font);
      Width:=Max(Width,Canvas.TextWidth(FButtons[I].Caption)+2*Gap);
    end;
    PerRow:=Max(1,(ClientWidth-Gap) div (Width+Gap)); Rows:=(Length(FButtons)+PerRow-1) div PerRow;
    FFooter.Height:=Rows*(Height+Gap)+Gap;
    for I:=0 to High(FButtons) do FButtons[I].SetBounds(Gap+(I mod PerRow)*(Width+Gap),
      Gap+(I div PerRow)*(Height+Gap),Width,Height);
    FIntro.SetBounds(Gap,Gap,Max(1,FHeader.ClientWidth-6*Gap),MulDiv(64,DPI,96));
    Canvas.Font.Assign(FReport.Font); R:=Rect(0,0,Max(1,FBody.ClientWidth),0);
    DrawText(Canvas.Handle,PChar(FReport.Caption),Length(FReport.Caption),R,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FReport.Height:=Max(MulDiv(100,DPI,96),R.Height+2*Gap);
  finally FLayoutBusy:=False; end;
end;

procedure TfrmLibraryUpdateSources.Resize;
begin inherited; Layout; end;

procedure TfrmLibraryUpdateSources.SetReport(const Text: string);
begin FReport.Caption:=Text; UpdateApplyAction; Layout; end;

procedure TfrmLibraryUpdateSources.Rebuild(Index: Integer);
begin
  FRebuilding:=True; FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for var Source in FSources do
    begin
      var Item:=FList.Items.Add;
      if Source.Enabled then Item.Caption:='Да' else Item.Caption:='Нет';
      Item.SubItems.Add(Source.Name); Item.SubItems.Add(Source.Location); Item.SubItems.Add(Source.IndexFile);
    end;
    if Length(FSources)>0 then
    begin
      FSelectedIndex:=EnsureRange(Index,0,High(FSources));
      FList.ItemIndex:=FSelectedIndex; FList.Items[FSelectedIndex].Selected:=True;
    end
    else FSelectedIndex:=-1;
  finally FList.Items.EndUpdate; FRebuilding:=False; end;
end;

procedure TfrmLibraryUpdateSources.Selected(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if not FRebuilding and Selected and (Item.Index<>FSelectedIndex) then
  begin FSelectedIndex:=Item.Index; InvalidatePrepared; end;
end;

procedure TfrmLibraryUpdateSources.AppendSource(const Source: TLibraryUpdateSource);
begin Source.Validate; InvalidatePrepared; FSources:=FSources+[Source]; Rebuild(High(FSources)); end;

procedure TfrmLibraryUpdateSources.ReplaceSource(Index: Integer; const Source: TLibraryUpdateSource);
begin
  if (Index<0) or (Index>=Length(FSources)) then raise EArgumentOutOfRangeException.Create('Index');
  Source.Validate;
  if Source.ID<>FSources[Index].ID then raise EArgumentException.Create('Идентификатор редактируемой записи изменён.');
  InvalidatePrepared; FSources[Index]:=Source; Rebuild(Index);
end;

procedure TfrmLibraryUpdateSources.AddSource(Sender: TObject);
var Editor: TfrmLibraryUpdateSourceEditor; Source: TLibraryUpdateSource;
begin
  Source:=TLibraryUpdateSource.NewSource; Source.Name:='Новый источник';
  Source.Location:=Settings.UpdateURL;
  if Source.Location='' then Source.Location:=VarToStr(FCollection.GetProperty(PROP_ROOTFOLDER));
  Editor:=TfrmLibraryUpdateSourceEditor.CreateForSource(Self,Source,LoadCatalogSources(FCollection),FAllowPreviousIndex);
  try if Editor.ShowModal=mrOk then AppendSource(Editor.Source); finally Editor.Free; end;
end;

procedure TfrmLibraryUpdateSources.EditSource(Sender: TObject);
var Editor: TfrmLibraryUpdateSourceEditor; Index: Integer;
begin
  Index:=SelectionIndex; if Index<0 then Exit;
  Editor:=TfrmLibraryUpdateSourceEditor.CreateForSource(Self,FSources[Index],LoadCatalogSources(FCollection),FAllowPreviousIndex);
  try if Editor.ShowModal=mrOk then ReplaceSource(Index,Editor.Source); finally Editor.Free; end;
end;

procedure TfrmLibraryUpdateSources.RemoveSource(Sender: TObject);
var Index: Integer;
begin
  Index:=SelectionIndex; if Index<0 then Exit;
  InvalidatePrepared; Delete(FSources,Index,1); Rebuild(Index);
  SetReport('Запись убрана из этого списка. Нажмите «Сохранить», чтобы сохранить настройки.');
end;

procedure TfrmLibraryUpdateSources.ImportFile(const FileName: string);
var Text, Warnings, DefaultLocation: string;
begin
  if TFile.GetSize(FileName)>1024*1024 then raise EReadError.Create('Файл настроек превышает 1 МБ.');
  Text:=TFile.ReadAllText(FileName,TEncoding.UTF8);
  if SameText(TPath.GetExtension(FileName),'.json') then FSources:=ReadLibraryUpdateSources(Text)
  else
  begin
    DefaultLocation:=Settings.UpdateURL; if DefaultLocation='' then DefaultLocation:=TPath.GetDirectoryName(FileName);
    FSources:=ImportLegacyUpdateSources(Text,DefaultLocation,Warnings);
  end;
  for var I:=0 to High(FSources) do FSources[I].Enabled:=False;
  InvalidatePrepared; Rebuild(0);
  SetReport(Format('Прочитано источников: %d. Импортированные записи отключены: выберите нужные, проверьте привязку '+
    'к этой коллекции и включите их через «Изменить». Затем нажмите «Сохранить».',[Length(FSources)])+sLineBreak+Warnings);
end;

procedure TfrmLibraryUpdateSources.ExportFile(const FileName: string);
var Text: string;
begin
  if SameText(TPath.GetExtension(FileName),'.ini') then Text:=ExportLegacyUpdateSources(FSources)
  else Text:=WriteLibraryUpdateSources(FSources);
  TFile.WriteAllText(FileName,Text,TEncoding.UTF8);
  SetReport('Настройки экспортированы. Старые версии читают первые шесть полей INI и не учитывают новые привязки и флаг включения.');
end;

procedure TfrmLibraryUpdateSources.SaveSources;
var Sources: TCatalogSources; Found: Boolean; Text: string;
begin
  Text:=WriteLibraryUpdateSources(FSources); Sources:=LoadCatalogSources(FCollection);
  for var Source in FSources do
    if Source.Enabled and (Source.CatalogSourceID<>'') then
    begin
      Found:=False;
      for var Target in Sources do if SameText(Source.CatalogSourceID,Target.ID) then Found:=True;
      if not Found then raise EArgumentException.Create('У включённой записи не найден источник этой коллекции: '+Source.Name);
    end;
  FCollection.BeginBulkOperation;
  try FCollection.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,Text); FCollection.EndBulkOperation(True);
  except FCollection.EndBulkOperation(False); raise; end;
  SetReport('Настройки сохранены для этой коллекции. Проверка файла получает отдельную служебную копию индекса.');
end;

procedure TfrmLibraryUpdateSources.CheckSource;
begin FetchAndReview(nil); end;

procedure TfrmLibraryUpdateSources.RestoreRestart(const Restart:ILibraryUpdateRestart);
var Proof:TLibraryUpdateRestartRequest;
begin
  Proof:=Restart.Request;
  FSources:=Copy(Proof.Profiles);
  SelectProfile(Proof.SourceID);
  FetchAndReview(Restart);
  FResumed:=True;
  FPreferNewOnResume:=Proof.PreferNewRoot;
  SetReport('Обновление после установки модулей. Проверьте результат и нажмите «Применить обновление».'+
    sLineBreak+sLineBreak+FReview.Summary);
end;

procedure TfrmLibraryUpdateSources.FetchAndReview(const Restart:ILibraryUpdateRestart);
var Worker: TFetchIndexWorker; Progress: TImportProgressFormEx; Index: Integer;
  Proof:TLibraryUpdateRestartRequest; Previous:TStagedLibraryIndex;
begin
  Index:=SelectionIndex; if Index<0 then raise EArgumentException.Create('Выберите источник для проверки.');
  InvalidatePrepared;
  Proof:=Default(TLibraryUpdateRestartRequest);
  if Assigned(Restart) then Proof:=Restart.Request;
  Previous:=nil;
  Worker:=TFetchIndexWorker.Create(FSources[Index],Restart);
  try
    Progress:=TImportProgressFormEx.Create(Self);
    try
      Progress.Caption:='Проверка файла обновления'; Progress.WorkerThread:=Worker; Progress.CloseOnTimer:=True;
      Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self; Progress.Timer.Interval:=1;
      Progress.ShowModal; Worker.WaitFor;
      if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
      if Worker.FError<>'' then raise EReadError.Create(Worker.FError);
      FPrepared:=Worker.TakePrepared;
      if not Assigned(FPrepared) then raise EReadError.Create('Проверка файла не завершена.');
      SetReport(Format('Получен индекс: %s%sРазмер: %.2f МБ.%sИсходный файл сохранён. Подготовлена служебная копия для проверки содержимого.',
        [FSources[Index].IndexFile,sLineBreak,TFile.GetSize(FPrepared.FileName)/1048576,sLineBreak]));
      Previous:=Worker.TakePrevious;
    finally Progress.Free; end;
  finally Worker.Free; end;
  try
    try
      if not EnsureCatalogReaderComponent(Self,FPrepared.FileName) then
        raise EAbort.Create('Проверка отменена. Для этого индекса требуется модуль Zstandard.');
      ReviewIndex(Proof,Previous);
    except
      InvalidatePrepared;
      raise;
    end;
  finally Previous.Free; end;
end;

procedure TfrmLibraryUpdateSources.ReviewIndex(const Proof:TLibraryUpdateRestartRequest; var Previous:TStagedLibraryIndex);
var Worker: TCollectionWorker; Progress: TImportProgressFormEx;
begin
  FReview:=TLibraryUpdateReview.Create(FSources[SelectionIndex],FPrepared);
  try
    FReview.SetSourceProfiles(FSources);
    if Proof.CatalogDigest<>'' then FReview.RestoreRestartProof(Proof,Previous);
    Worker:=CreateLibraryReviewWorker(FCollection.CollectionID,FReview);
    try
      Progress:=TImportProgressFormEx.Create(Self);
      try
        Progress.Caption:='Проверка книг и архивов обновления'; Progress.WorkerThread:=Worker;
        Progress.CloseOnTimer:=True; Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self; Progress.Timer.Interval:=1;
        Progress.ShowModal; Worker.WaitFor;
        if Assigned(Worker.FatalException) then raise EReadError.Create(Exception(Worker.FatalException).Message);
        if not Worker.Success or not FReview.Ready then raise EReadError.Create('Проверка обновления не завершена.');
        SetReport(FReview.Summary);
      finally Progress.Free; end;
    finally Worker.Free; end;
  except FreeAndNil(FReview); raise; end;
end;

procedure TfrmLibraryUpdateSources.ImportClick(Sender: TObject);
var Dialog: TOpenDialog;
begin
  Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Filter:='Настройки источников|*.ini;*.json'; Dialog.Options:=[ofFileMustExist,ofPathMustExist,ofEnableSizing];
    if Dialog.Execute then try ImportFile(Dialog.FileName); except on E:Exception do SetReport(E.Message); end;
  finally Dialog.Free; end;
end;

procedure TfrmLibraryUpdateSources.ExportClick(Sender: TObject);
var Dialog: TSaveDialog;
begin
  Dialog:=TSaveDialog.Create(Self);
  try
    Dialog.Filter:='Настройки HomeLibre (*.json)|*.json|Прежний collections.ini (*.ini)|*.ini';
    Dialog.DefaultExt:='json'; Dialog.FileName:='library-update-sources.json'; Dialog.Options:=[ofOverwritePrompt,ofEnableSizing];
    if Dialog.Execute then try ExportFile(Dialog.FileName); except on E:Exception do SetReport(E.Message); end;
  finally Dialog.Free; end;
end;

procedure TfrmLibraryUpdateSources.SaveClick(Sender: TObject);
begin try SaveSources; except on E:Exception do SetReport(E.Message); end; end;

procedure TfrmLibraryUpdateSources.CheckClick(Sender: TObject);
begin try CheckSource; except on E:Exception do SetReport(E.Message); end; end;

procedure TfrmLibraryUpdateSources.CopyReport(Sender: TObject);
begin Clipboard.AsText:=FReport.Caption; end;

procedure TfrmLibraryUpdateSources.SelectProfile(const ID: string);
begin
  for var I:=0 to High(FSources) do
    if SameText(FSources[I].ID,ID) then begin Rebuild(I); Exit; end;
end;

procedure TfrmLibraryUpdateSources.ApplyReviewed(PreferNewRoot: Boolean);
var Worker: TCollectionWorker; Progress: TImportProgressFormEx; Succeeded: Boolean; Failure, Details, Missing: string; LineEnd: Integer;
begin
  if not Assigned(FReview) or not FReview.Ready or FReview.Applied then raise EReadError.Create('Сначала проверьте обновление.');
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  Worker:=CreateLibraryApplyWorker(FCollection.CollectionID,FReview,PreferNewRoot,FAllowModuleRestart);
  try
    Progress:=TImportProgressFormEx.Create(Self);
    try
      Progress.Caption:='Обновление библиотеки'; Progress.WorkerThread:=Worker;
      Progress.CloseOnTimer:=True; Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self; Progress.Timer.Interval:=1;
      Progress.ShowModal; Worker.WaitFor;
      if Assigned(FReview.PendingRestart) then
      begin
        FPendingRestart:=FReview.PendingRestart;
        FRestartComponents:=Copy(FReview.MissingComponents);
        ModalResult:=mrOk;
        Exit;
      end;
      if Worker.CommittedChanges then FCommitted:=True;
      Succeeded:=Worker.Success;
      if Assigned(Worker.FatalException) then Failure:=Exception(Worker.FatalException).Message;
      if Worker.CommittedChanges then
      begin
        FPublishedCollectionID:=FReview.PublishedCollectionID;
        if FPublishedCollectionID>0 then
        begin
          FCollection:=SystemDB.GetCollection(FPublishedCollectionID,True);
          Caption:='Источники обновлений — '+FCollection.CollectionDisplayName;
        end
        else FCollection:=SystemDB.GetCollection(FCollection.CollectionID,True);
      end;
    finally Progress.Free; end;
  finally Worker.Free; end;
  Missing:=FReview.MissingDetails;
  if Missing<>'' then Missing:=sLineBreak+sLineBreak+Missing;
  if Failure<>'' then
  begin
    if FReview.RecoveryPending then SetReport('Сохранение обновления требует восстановления. Перезапустите программу. '+
      Failure+sLineBreak+FReview.RecoveryError+Missing)
    else if FReview.Applied then SetReport('Каталог уже обновлён. Завершение потребовало внимания: '+Failure+Missing)
    else SetReport('Обновление не применено: '+Failure+Missing);
    Exit;
  end;
  if Succeeded then
  begin
    Details:=FReview.ApplySummary; LineEnd:=Pos(sLineBreak,Details);
    if LineEnd>0 then Delete(Details,1,LineEnd+Length(sLineBreak)-1);
    if FPublishedCollectionID>0 then
      SetReport('Создана обновлённая упакованная коллекция. Она откроется после закрытия окна.'+
        sLineBreak+Details+Missing)
    else SetReport('Обновление применено. Сохранены настройки источника и его новый индекс. '+
      'Сами книги и архивы не менялись.'+sLineBreak+Details+Missing);
  end
  else SetReport('Обновление отменено. Текущий каталог не изменён.'+Missing);
end;

procedure TfrmLibraryUpdateSources.ApplyClick(Sender: TObject);
var PreferNew: Boolean; Choice: Integer;
begin
  try
    PreferNew:=FResumed and FPreferNewOnResume;
    if not FResumed and Assigned(FReview) and (FReview.AmbiguousArchives.Count>0) then
    begin
      Choice:=MessageDlg('Одноимённые архивы есть в прежней папке и папке докачки.'+sLineBreak+
        'Использовать версии из папки докачки?'+sLineBreak+'«Нет» — использовать прежние файлы.',
        mtConfirmation,[mbYes,mbNo,mbCancel],0);
      if Choice=mrCancel then Exit;
      PreferNew:=Choice=mrYes;
    end;
    ApplyReviewed(PreferNew);
  except on E:Exception do SetReport(E.Message); end;
end;

procedure TfrmLibraryUpdateSources.CopyNeeded(Sender: TObject);
begin
  if Assigned(FReview) and FReview.Ready and (FReview.NeededArchives.Count>0) then
    Clipboard.AsText:=FReview.NeededArchives.Text;
end;

procedure TfrmLibraryUpdateSources.SaveMissing(Sender: TObject);
var Dialog: TSaveDialog;
begin
  if not Assigned(FReview) or not FReview.MissingReportReady or (FReview.MissingBooks=0) then Exit;
  Dialog:=TSaveDialog.Create(Self);
  try
    Dialog.Title:='Сохранить полный список пропущенных книг';
    Dialog.DefaultExt:='txt'; Dialog.Filter:='Текстовые файлы (*.txt)|*.txt';
    Dialog.FileName:='HomeLibre-пропущенные-книги.txt';
    Dialog.Options:=Dialog.Options+[ofOverwritePrompt,ofPathMustExist];
    if Dialog.Execute then
      try
        FReview.SaveMissingReport(Dialog.FileName);
        SetReport(string(FReport.Caption)+sLineBreak+'Полный список сохранён: '+Dialog.FileName);
      except on E:Exception do SetReport('Не удалось сохранить список: '+E.Message+sLineBreak+FReview.MissingDetails); end;
  finally Dialog.Free; end;
end;

end.
