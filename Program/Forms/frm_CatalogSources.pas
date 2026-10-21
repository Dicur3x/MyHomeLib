unit frm_CatalogSources;

interface

uses System.Classes, System.Types, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  unit_Interfaces, unit_CatalogSources, unit_CollectionMerge, unit_WorkerThread, unit_SeriesAliases;

type
  TCatalogWorkflowState = (cwsNeedsPreview, cwsChecking, cwsReady, cwsApplying, cwsDone, cwsFailed);

  TSourceDialogForm = class(TForm)
  private
    FLayoutPPI: Integer;
  public
    procedure ScaleForPPI(NewPPI: Integer); override;
  end;

  TSourceScrollBox = class(TScrollBox)
  private
    FWheelRemainder: Integer;
  protected
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    function ScrollWheel(WheelDelta: Integer): Boolean;
  end;

  TfrmCatalogSources = class(TSourceDialogForm)
  private
    FTarget: IBookCollection;
    FBody: TSourceScrollBox;
    FHeader, FActions, FOptions: TPanel;
    FIntroTitle, FIntroHelp, FTargetLabel, FLibraryHelp: TLabel;
    FSources: TCatalogSources;
    FPlan: TCollectionMergePlan;
    FList: TListView;
    FReport: TMemo;
    FApply, FRefresh, FRoot, FIndexFile, FUp, FDown, FDisconnect, FLibrary, FPreview, FMetadataFill,
      FSaveReport, FClose, FSeriesButton, FDuplicates: TButton;
    FDetails, FPolicyHelp, FSpace, FAllSources, FWorkflowTitle, FWorkflowDetails, FSeriesScope: TLabel;
    FPreviewRevision: Integer;
    FBusy, FSeriesLayoutBusy: Boolean;
    FWorkflowState: TCatalogWorkflowState;
    FPolicy, FTargetLibrary: TComboBox;
    FChanged: Boolean;
    FMetadataChanged: Boolean;
    FDuplicatesRequested: Boolean;
    FLastReportFile: string;
    FLayoutFile: string;
    FHasShown: Boolean;
    FNormalWidth96, FNormalHeight96: Integer;
    procedure DoShow; override;
    function Button(ParentPanel: TPanel; const Caption: string; Left, Width: Integer;
      Handler: TNotifyEvent): TButton;
    procedure InvalidatePreview(const Reason: string = '');
    procedure SetWorkflowState(State: TCatalogWorkflowState; const Details: string);
    procedure RebuildList(Index: Integer);
    procedure UpdateSelection;
    procedure UpdatePolicyHelp;
    procedure UpdateSpaceEstimate;
    procedure AddINPX(Sender: TObject);
    procedure AddCollection(Sender: TObject);
    procedure MoveSource(Sender: TObject);
    procedure DisconnectSource(Sender: TObject);
    procedure ChooseRoot(Sender: TObject);
    procedure ChooseIndexFile(Sender: TObject);
    procedure RefreshSource(Sender: TObject);
    procedure Preview(Sender: TObject);
    procedure Apply(Sender: TObject);
    procedure LayoutSeriesScope;
    procedure LayoutBodyText;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure Resize; override;
    procedure PreviewSeriesAliases(Sender: TObject);
    procedure ReviewDuplicates(Sender: TObject);
    procedure FillBookMetadata(Sender: TObject);
    procedure SaveReport(Sender: TObject);
    procedure Selected(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure RunWorker(Worker: TWorker; const Caption: string; OwnerWindow: TCustomForm = nil);
    procedure Save;
    procedure PolicyChanged(Sender: TObject);
    procedure ChooseLibrary(Sender: TObject);
  public
    constructor CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
    destructor Destroy; override;
    property CatalogChanged: Boolean read FChanged;
    property MetadataChanged: Boolean read FMetadataChanged;
    property DuplicatesRequested: Boolean read FDuplicatesRequested;
  end;

type
  TfrmSeriesAliasReview = class(TSourceDialogForm)
  private
    FSourceDialog: TfrmCatalogSources;
    FPlan: TSeriesAliasPlan;
    FReport: TMemo;
    FSummary: TLabel;
    FCheck, FApply: TButton;
    FFinished: Boolean;
    procedure ApplyAliases(Sender: TObject);
  public
    constructor CreateFor(SourceDialog: TfrmCatalogSources);
    destructor Destroy; override;
    procedure PreviewAliases(Sender: TObject);
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Variants, Winapi.Windows, Vcl.Graphics,
  Vcl.Dialogs, Vcl.FileCtrl, unit_Consts, unit_Settings, unit_Globals,
  frm_ImportProgressFormEx, unit_BookCache, dm_user, unit_CollectionSpace, System.Math, frm_BookMetadataFill,
  System.IniFiles, unit_AtomicIniFile;

function TSourceScrollBox.ScrollWheel(WheelDelta: Integer): Boolean;
var Lines: Cardinal; Step, Delta: Integer;
begin
  Result:=VertScrollBar.Range>ClientHeight;
  if not Result then Exit;
  Lines:=3; SystemParametersInfo(SPI_GETWHEELSCROLLLINES,0,@Lines,0);
  if Lines=WHEEL_PAGESCROLL then Step:=ClientHeight
  else Step:=Integer(Min(Lines,100))*Max(1,Abs(Font.Height));
  Inc(FWheelRemainder,WheelDelta*Step);
  Delta:=FWheelRemainder div WHEEL_DELTA; FWheelRemainder:=FWheelRemainder mod WHEEL_DELTA;
  VertScrollBar.Position:=VertScrollBar.Position-Delta;
end;

function TSourceScrollBox.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if (Shift*[ssCtrl,ssShift]=[]) and ScrollWheel(WheelDelta) then Exit(True);
  Result:=inherited;
end;

function TfrmCatalogSources.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if Assigned(FBody) and (Shift*[ssCtrl,ssShift]=[]) and
    FBody.ClientRect.Contains(FBody.ScreenToClient(MousePos)) and FBody.ScrollWheel(WheelDelta) then Exit(True);
  Result:=inherited;
end;

procedure TSourceDialogForm.ScaleForPPI(NewPPI: Integer);
var OldPPI, NewWidth, NewHeight, MinWidth, MinHeight: Integer;
begin
  // CurrentPPI describes the native window's monitor, which may remain at 96
  // during explicit layout scaling. Remember the last applied layout scale so
  // 96 -> 144 -> 192 does not multiply the window size by 1.5 and then by 2.
  OldPPI:=FLayoutPPI;
  if OldPPI=0 then OldPPI:=96;
  if (OldPPI<=0) or (NewPPI<=0) or (OldPPI=NewPPI) then
  begin inherited; Exit; end;
  // Runtime forms have no streamed design size. Scale the window as well as
  // its controls; otherwise an initially hidden window keeps its old width.
  NewWidth:=MulDiv(ClientWidth,NewPPI,OldPPI);
  NewHeight:=MulDiv(ClientHeight,NewPPI,OldPPI);
  MinWidth:=MulDiv(Constraints.MinWidth,NewPPI,OldPPI);
  MinHeight:=MulDiv(Constraints.MinHeight,NewPPI,OldPPI);
  FLayoutPPI:=NewPPI;
  DisableAlign;
  try
    inherited;
    Constraints.MinWidth:=MinWidth; Constraints.MinHeight:=MinHeight;
    ClientWidth:=NewWidth; ClientHeight:=NewHeight;
  finally EnableAlign; end;
end;

constructor TfrmCatalogSources.CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
var Panel, Footer: TPanel; LabelText: TLabel; B: TButton; Body: TScrollBox; WorkArea: TRect; Ini: TMemIniFile;
  function LabelAt(AParent: TPanel; const Text: string; X,Y,W,H: Integer): TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=AParent; Result.AutoSize:=False;
    Result.SetBounds(X,Y,W,H); Result.WordWrap:=True; Result.Caption:=Text;
    if W<200 then Result.Anchors:=[akLeft,akTop]
    else Result.Anchors:=[akLeft,akTop,akRight];
  end;
begin
  inherited CreateNew(AOwner);
  FTarget:=Collection; FSources:=LoadCatalogSources(FTarget);
  Caption:='Источники коллекции — '+FTarget.CollectionDisplayName;
  PixelsPerInch:=96; Font.PixelsPerInch:=96;
  Font.Name:='Segoe UI'; Font.Size:=9; Position:=poOwnerFormCenter;
  BorderStyle:=bsSizeable; ClientWidth:=960; ClientHeight:=872;
  Constraints.MinWidth:=720; Constraints.MinHeight:=460;
  DisableAlign;
  try
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.SetBounds(0,ClientHeight-116,ClientWidth,116);
  Footer.Align:=alBottom; Footer.BevelOuter:=bvNone;
  FBody:=TSourceScrollBox.Create(Self); Body:=FBody; Body.Parent:=Self; Body.Align:=alClient;
  Body.Name:='sbCatalogSources';
  Body.BorderStyle:=bsNone; Body.HorzScrollBar.Visible:=False;
  Panel:=TPanel.Create(Self); Panel.Parent:=Body; Panel.SetBounds(0,0,ClientWidth,108); Panel.Align:=alTop; Panel.BevelOuter:=bvNone;
  FHeader:=Panel;
  LabelText:=LabelAt(Panel,'Добавить книги в текущую коллекцию',12,9,936,22);
  FIntroTitle:=LabelText;
  LabelText.Font.Style:=[fsBold]; LabelText.Font.Size:=11;
  FIntroHelp:=LabelAt(Panel,'INPX — список книг; папка книг — место, где лежат сами файлы и архивы. Можно подключить несколько библиотек, включая смешанные каталоги Флибусты и Либрусека.',12,36,936,34);
  FAllSources:=LabelAt(Panel,'',12,76,936,28); FAllSources.Font.Style:=[fsBold];
  FList:=TListView.Create(Self); FList.Parent:=Body; FList.SetBounds(0,76,ClientWidth,166); FList.Align:=alTop;
  FList.Name:='lvCatalogSources'; FList.ViewStyle:=vsReport; FList.ReadOnly:=True; FList.RowSelect:=True;
  FList.HideSelection:=False; FList.DoubleBuffered:=True; FList.ShowHint:=True;
  FList.Hint:='В объединении участвует весь список. Выделение строки нужно только для изменения одного источника. Порядок сверху вниз задаёт приоритет копий.';
  FList.Columns.Add.Caption:='Источник'; FList.Columns[0].Width:=175;
  FList.Columns.Add.Caption:='Папка с книгами'; FList.Columns[1].Width:=230;
  FList.Columns.Add.Caption:='Файл каталога'; FList.Columns[2].Width:=240;
  FList.Columns.Add.Caption:='Библиотека'; FList.Columns[3].Width:=145;
  FList.Columns.Add.Caption:='Состояние'; FList.Columns[4].Width:=150;
  FList.OnSelectItem:=Selected;
  Panel:=TPanel.Create(Self); Panel.Parent:=Body; Panel.SetBounds(0,242,ClientWidth,158); Panel.Align:=alTop; Panel.BevelOuter:=bvNone;
  FActions:=Panel;
  Button(Panel,'Добавить INPX…',12,148,AddINPX);
  Button(Panel,'Добавить коллекцию…',166,182,AddCollection);
  FUp:=Button(Panel,'↑',366,38,MoveSource); FUp.Tag:=-1;
  FDown:=Button(Panel,'↓',410,38,MoveSource); FDown.Tag:=1;
  FDisconnect:=Button(Panel,'Отключить источник',468,174,DisconnectSource);
  FDisconnect.Hint:='Убирает источник из списка и его ненужный кэш. Книги, уже добавленные в эту коллекцию, сохраняются.'; FDisconnect.ShowHint:=True;
  FRoot:=Button(Panel,'Изменить папку книг…',12,204,ChooseRoot); FRoot.Top:=44;
  FIndexFile:=Button(Panel,'Заменить файл INPX…',222,204,ChooseIndexFile); FIndexFile.Top:=44;
  FLibrary:=Button(Panel,'Библиотека источника…',432,210,ChooseLibrary); FLibrary.Top:=44;
  FRefresh:=Button(Panel,'Перечитать выбранный INPX',12,238,RefreshSource); FRefresh.Top:=80;
  FRefresh.Hint:='Перечитывает выбранный INPX в отдельный каталог источника. Текущая коллекция пока не меняется.'; FRefresh.ShowHint:=True;
  FDetails:=LabelAt(Panel,'',12,118,936,36);
  Panel:=TPanel.Create(Self); Panel.Parent:=Body; Panel.SetBounds(0,400,ClientWidth,198); Panel.Align:=alTop; Panel.BevelOuter:=bvNone;
  FOptions:=Panel;
  LabelAt(Panel,'Повторные книги:',12,10,142,20);
  FPolicy:=TComboBox.Create(Self); FPolicy.Parent:=Panel; FPolicy.Style:=csDropDownList;
  FPolicy.Name:='cbMergeDuplicatePolicy'; FPolicy.SetBounds(158,6,790,26); FPolicy.Anchors:=[akLeft,akTop,akRight];
  FPolicy.Items.Add('Сохранить все разные копии');
  FPolicy.Items.Add('Одна запись — предпочитать источник выше в списке');
  FPolicy.Items.Add('Одна запись — предпочитать меньший файл');
  FPolicy.ItemIndex:=0; FPolicy.OnChange:=PolicyChanged;
  FPolicyHelp:=LabelAt(Panel,'',158,36,790,42);
  FTargetLabel:=LabelAt(Panel,'Текущая коллекция:',12,86,142,20);
  FTargetLibrary:=TComboBox.Create(Self); FTargetLibrary.Parent:=Panel; FTargetLibrary.Style:=csDropDownList;
  FTargetLibrary.Name:='cbMergeLibrary'; FTargetLibrary.SetBounds(158,82,342,26);
  FTargetLibrary.Items.Add('Определять библиотеку по каждой книге');
  FTargetLibrary.Items.Add('Только Флибуста'); FTargetLibrary.Items.Add('Только Либрусек');
  FTargetLibrary.Items.Add('Флибуста + Либрусек (смешанная)'); FTargetLibrary.ItemIndex:=0;
  if SameText(VarToStr(FTarget.GetProperty(PROP_SOURCE_LIBRARY)),'flibusta') then FTargetLibrary.ItemIndex:=1;
  if SameText(VarToStr(FTarget.GetProperty(PROP_SOURCE_LIBRARY)),'librusec') then FTargetLibrary.ItemIndex:=2;
  if SameText(VarToStr(FTarget.GetProperty(PROP_SOURCE_LIBRARY)),'mixed') then FTargetLibrary.ItemIndex:=3;
  FTargetLibrary.OnChange:=PolicyChanged;
  FLibraryHelp:=LabelAt(Panel,'Если происхождение номера книги неизвестно, разные копии остаются отдельными.',158,112,790,30);
  FSpace:=LabelAt(Panel,'',12,142,936,52);
  FSpace.Name:='lblSourceSpace';
  Panel:=Footer;
  FWorkflowTitle:=LabelAt(Panel,'',12,6,184,36); FWorkflowTitle.Font.Style:=[fsBold];
  FWorkflowTitle.Name:='lblSourceWorkflowState'; FWorkflowTitle.Anchors:=[akLeft,akTop];
  FWorkflowDetails:=LabelAt(Panel,'',208,6,740,36); FWorkflowDetails.Name:='lblSourceWorkflowDetails';
  FPreview:=Button(Panel,'1. Проверить все источники',12,252,Preview);
  FPreview.Name:='btnCheckSources'; FPreview.Top:=48;
  FPreview.Hint:='Проверяет весь список с текущими настройками. Книги текущей коллекции пока не меняются.'; FPreview.ShowHint:=True;
  FApply:=Button(Panel,'2. Добавить книги в коллекцию',276,252,Apply);
  FApply.Name:='btnApplySources'; FApply.Top:=48; FApply.Enabled:=False;
  FApply.Hint:='Доступно после проверки всех источников с текущими настройками.'; FApply.ShowHint:=True;
  B:=Button(Panel,'Сохранить отчёт…',540,158,SaveReport); B.Top:=48; FSaveReport:=B;
  B:=Button(Panel,'Объединить названия серий…',12,252,PreviewSeriesAliases); B.Top:=82;
  B.Name:='btnSeriesNames'; B.Hint:='Проверяет серии уже добавленных книг текущей коллекции. Источники из списка не импортирует.'; B.ShowHint:=True; FSeriesButton:=B;
  FDuplicates:=Button(Panel,'Объединить повторы книг…',540,252,ReviewDuplicates); FDuplicates.Top:=82;
  FDuplicates.Name:='btnBookDuplicates'; FDuplicates.ShowHint:=True;
  FDuplicates.Hint:='Открыть сравнение повторных записей уже добавленных книг. Изменения выполняются только после выбора и подтверждения; файлы сохраняются.';
  FMetadataFill:=Button(Panel,'Заполнить сведения из книг…',276,252,FillBookMetadata); FMetadataFill.Top:=82;
  FMetadataFill.Name:='btnFillBookMetadata'; FMetadataFill.ShowHint:=True;
  FMetadataFill.Hint:='Заполнить выбранные недостающие сведения уже добавленных местных книг этой коллекции. Проверка запускается только по вашей команде.';
  FSeriesScope:=LabelAt(Panel,'Эти команды обрабатывают сведения уже добавленных книг. Источники не импортируют.',540,82,408,30);
  FSeriesScope.Name:='lblSeriesNamesScope';
  B:=Button(Panel,'Закрыть',848,100,nil); B.Top:=48; B.Anchors:=[akTop,akRight]; B.ModalResult:=mrClose; B.Cancel:=True; FClose:=B;
  FReport:=TMemo.Create(Self); FReport.Parent:=Body; FReport.Top:=MaxInt; FReport.Align:=alTop; FReport.Height:=156;
  FReport.AlignWithMargins:=True; FReport.Margins.Left:=12; FReport.Margins.Right:=12;
  FReport.Name:='mmSourcesReport'; FReport.ReadOnly:=True; FReport.ScrollBars:=ssVertical; FReport.WordWrap:=True;
  FReport.Lines.Text:='Здесь появится результат проверки: сколько книг добавится, какие копии будут объединены и есть ли конфликты.'+#13#10+#13#10+
    'Уже импортированные книги учитываются: совпадение файла связывает их с источником. Текущие книги, оценки и прочитанное сохраняются.'+#13#10+
    'Для всех строк со статусом «Список подготовлен» повторно читать INPX не нужно. Нажмите «1. Проверить все источники», затем «2. Добавить книги в коллекцию». В проверке участвует весь список, независимо от выделения.'+#13#10+
    'Размер файла не гарантирует качество: если предпочитаете полные иллюстрации, поставьте нужный источник выше и выберите соответствующий режим.'+#13#10+
    'В смешанном каталоге номера Флибусты и Либрусека проверяются отдельно. Одинаковый номер в разных библиотеках не объединяет книги.';
  finally EnableAlign; end;
  UpdatePolicyHelp; RebuildList(0);
  SetWorkflowState(cwsNeedsPreview,'Сначала выберите режим повторных книг, затем нажмите «1. Проверить все источники».');
  ScaleForPPI(Screen.PixelsPerInch);
  FLayoutFile:=Settings.DataPath+'catalog-sources-window.ini';
  Ini:=TMemIniFile.Create(FLayoutFile,TEncoding.UTF8);
  try
    ClientWidth:=MulDiv(EnsureRange(Ini.ReadInteger('Window','ClientWidth96',860),704,4000),CurrentPPI,96);
    ClientHeight:=MulDiv(EnsureRange(Ini.ReadInteger('Window','ClientHeight96',760),420,3000),CurrentPPI,96);
  finally Ini.Free; end;
  WorkArea:=Monitor.WorkareaRect;
  Width:=Min(Width,Max(Constraints.MinWidth,WorkArea.Width-24));
  Height:=Min(Height,Max(Constraints.MinHeight,WorkArea.Height-48));
  FNormalWidth96:=MulDiv(ClientWidth,96,CurrentPPI); FNormalHeight96:=MulDiv(ClientHeight,96,CurrentPPI);
  LayoutSeriesScope;
end;

destructor TfrmCatalogSources.Destroy;
var Ini: TMemIniFile;
begin
  if FHasShown and (FLayoutFile<>'') then
  try
    Ini:=TMemIniFile.Create(FLayoutFile,TEncoding.UTF8);
    try
      Ini.WriteInteger('Window','ClientWidth96',FNormalWidth96);
      Ini.WriteInteger('Window','ClientHeight96',FNormalHeight96);
      SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
  except
    // Window geometry is optional; a read-only profile keeps its old layout.
  end;
  FPlan.Free; inherited;
end;

procedure TfrmCatalogSources.DoShow;
begin FHasShown:=True; inherited; LayoutSeriesScope; end;

procedure TfrmCatalogSources.Resize;
begin
  inherited; LayoutSeriesScope;
  if FHasShown and (WindowState=wsNormal) and (CurrentPPI>0) then
  begin FNormalWidth96:=MulDiv(ClientWidth,96,CurrentPPI); FNormalHeight96:=MulDiv(ClientHeight,96,CurrentPPI); end;
end;

procedure TfrmCatalogSources.LayoutSeriesScope;
var R: TRect; PPI, Gap, ColumnWidth, RowHeight, HeaderHeight: Integer; Footer: TWinControl; Text: string;
begin
  if FSeriesLayoutBusy or not Assigned(FSeriesScope) or not Assigned(FClose) then Exit;
  FSeriesLayoutBusy:=True;
  try
    PPI:=Max(96,Font.PixelsPerInch); Footer:=FSeriesScope.Parent;
    // VCL may rescale constraints again when a hidden runtime form is shown.
    // Derive them from design units, never from previously scaled values.
    Constraints.MinWidth:=MulDiv(720,PPI,96);
    Constraints.MinHeight:=MulDiv(460,PPI,96);
    FWorkflowDetails.Width:=Max(MulDiv(100,PPI,96),Footer.ClientWidth-FWorkflowDetails.Left-MulDiv(12,PPI,96));
    Canvas.Font.Assign(FWorkflowDetails.Font); Text:=FWorkflowDetails.Caption;
    R:=Rect(0,0,FWorkflowDetails.Width,0);
    DrawTextW(Canvas.Handle,PChar(Text),Length(Text),R,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FWorkflowDetails.Height:=Max(MulDiv(36,PPI,96),R.Height);
    HeaderHeight:=Max(MulDiv(48,PPI,96),FWorkflowDetails.Top+FWorkflowDetails.Height+MulDiv(6,PPI,96));
    if ClientWidth<MulDiv(950,PPI,96) then
    begin
      Gap:=MulDiv(12,PPI,96); RowHeight:=MulDiv(28,PPI,96);
      ColumnWidth:=(Footer.ClientWidth-4*Gap) div 3;
      FPreview.SetBounds(Gap,HeaderHeight,ColumnWidth,RowHeight);
      FApply.SetBounds(2*Gap+ColumnWidth,FPreview.Top,ColumnWidth,RowHeight);
      FSaveReport.SetBounds(3*Gap+2*ColumnWidth,FPreview.Top,ColumnWidth,RowHeight);
      FSeriesButton.SetBounds(Gap,FPreview.Top+MulDiv(34,PPI,96),ColumnWidth,RowHeight);
      FDuplicates.SetBounds(FApply.Left,FSeriesButton.Top,ColumnWidth,RowHeight);
      FMetadataFill.SetBounds(FSaveReport.Left,FSeriesButton.Top,ColumnWidth,RowHeight);
      FClose.SetBounds(FSaveReport.Left,FSeriesButton.Top+MulDiv(34,PPI,96),ColumnWidth,RowHeight);
      FSeriesScope.SetBounds(Gap,FClose.Top,2*ColumnWidth+Gap,MulDiv(30,PPI,96));
    end
    else
    begin
      FPreview.SetBounds(MulDiv(12,PPI,96),HeaderHeight,MulDiv(252,PPI,96),MulDiv(28,PPI,96));
      FApply.SetBounds(MulDiv(276,PPI,96),FPreview.Top,FPreview.Width,FPreview.Height);
      FSaveReport.SetBounds(MulDiv(540,PPI,96),FPreview.Top,MulDiv(158,PPI,96),FPreview.Height);
      FSeriesButton.SetBounds(FPreview.Left,FPreview.Top+MulDiv(34,PPI,96),FPreview.Width,FPreview.Height);
      FDuplicates.SetBounds(FApply.Left,FSeriesButton.Top,FPreview.Width,FPreview.Height);
      FMetadataFill.SetBounds(FSaveReport.Left,FSeriesButton.Top,FPreview.Width,FPreview.Height);
      FClose.SetBounds(Footer.ClientWidth-MulDiv(112,PPI,96),FPreview.Top,MulDiv(100,PPI,96),FPreview.Height);
      FSeriesScope.SetBounds(FPreview.Left,FSeriesButton.Top+MulDiv(34,PPI,96),Footer.ClientWidth-MulDiv(24,PPI,96),MulDiv(30,PPI,96));
    end;
    Canvas.Font.Assign(FSeriesScope.Font); Text:=FSeriesScope.Caption;
    R:=Rect(0,0,FSeriesScope.Width,0);
    DrawTextW(Canvas.Handle,PChar(Text),Length(Text),R,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FSeriesScope.Height:=Max(MulDiv(30,PPI,96),R.Height);
    Footer.Height:=Max(MulDiv(116,PPI,96),FSeriesScope.Top+FSeriesScope.Height+MulDiv(4,PPI,96));
    LayoutBodyText;
  finally FSeriesLayoutBusy:=False; end;
end;

procedure TfrmCatalogSources.LayoutBodyText;
var PPI, SavedPosition: Integer;
  procedure Fit(LabelControl: TLabel; Minimum: Integer);
  var R: TRect; Text: string;
  begin
    Canvas.Font.Assign(LabelControl.Font); Text:=LabelControl.Caption;
    R:=Rect(0,0,LabelControl.Width,0);
    DrawTextW(Canvas.Handle,PChar(Text),Length(Text),R,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    LabelControl.Height:=Max(MulDiv(Minimum,PPI,96),R.Height);
  end;
begin
  if not Assigned(FBody) or not Assigned(FSpace) or not Assigned(FIntroTitle) then Exit;
  PPI:=Max(96,Font.PixelsPerInch); SavedPosition:=FBody.VertScrollBar.Position;
  FBody.DisableAlign;
  try
    // Reflow from design heights rather than growing on every resize. Keep
    // enough height in each aligned section for the actual wrapped text.
    Fit(FIntroTitle,22);
    FIntroHelp.Top:=FIntroTitle.Top+FIntroTitle.Height+MulDiv(6,PPI,96); Fit(FIntroHelp,34);
    FAllSources.Top:=FIntroHelp.Top+FIntroHelp.Height+MulDiv(6,PPI,96); Fit(FAllSources,28);
    FHeader.Height:=FAllSources.Top+FAllSources.Height+MulDiv(4,PPI,96);
    Fit(FDetails,36); FActions.Height:=FDetails.Top+FDetails.Height+MulDiv(4,PPI,96);
    Fit(FPolicyHelp,42);
    FTargetLabel.Top:=Max(MulDiv(86,PPI,96),FPolicyHelp.Top+FPolicyHelp.Height+MulDiv(8,PPI,96)); Fit(FTargetLabel,20);
    FTargetLibrary.Top:=FTargetLabel.Top-MulDiv(4,PPI,96);
    FLibraryHelp.Top:=Max(FTargetLibrary.Top+FTargetLibrary.Height,FTargetLabel.Top+FTargetLabel.Height)+MulDiv(4,PPI,96);
    Fit(FLibraryHelp,30);
    FSpace.Top:=FLibraryHelp.Top+FLibraryHelp.Height+MulDiv(4,PPI,96); Fit(FSpace,52);
    FOptions.Height:=FSpace.Top+FSpace.Height+MulDiv(10,PPI,96);
  finally FBody.EnableAlign; end;
  FBody.VertScrollBar.Position:=SavedPosition;
end;

function TfrmCatalogSources.Button(ParentPanel: TPanel; const Caption: string; Left, Width: Integer;
  Handler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self); Result.Parent := ParentPanel;
  Result.Caption := Caption; Result.SetBounds(Left,8,Width,28); Result.OnClick := Handler;
end;

procedure TfrmCatalogSources.SetWorkflowState(State: TCatalogWorkflowState; const Details: string);
begin
  FWorkflowState:=State;
  case State of
    cwsNeedsPreview: FWorkflowTitle.Caption:='Нужна проверка';
    cwsChecking: FWorkflowTitle.Caption:='Проверяем источники';
    cwsReady: FWorkflowTitle.Caption:='Можно добавить книги';
    cwsApplying: FWorkflowTitle.Caption:='Добавляем книги';
    cwsDone: FWorkflowTitle.Caption:='Книги добавлены';
    cwsFailed: FWorkflowTitle.Caption:='Операция не завершена';
  end;
  FWorkflowDetails.Caption:=Details;
  LayoutSeriesScope;
  FPreview.Default:=not FBusy and (State<>cwsReady);
  FApply.Default:=not FBusy and (State=cwsReady) and FApply.Enabled;
end;

procedure TfrmCatalogSources.InvalidatePreview(const Reason: string);
var Explanation: string;
begin
  Inc(FPreviewRevision); FreeAndNil(FPlan); FApply.Enabled:=False;
  FApply.Caption:='2. Добавить книги в коллекцию';
  Explanation:=Reason;
  if Explanation='' then Explanation:='Перед добавлением нужна проверка с текущими настройками.';
  SetWorkflowState(cwsNeedsPreview,Explanation+' Нажмите «1. Проверить все источники».');
  UpdateSpaceEstimate;
end;

procedure TfrmCatalogSources.Save;
begin SaveCatalogSources(FTarget, FSources); end;

procedure TfrmCatalogSources.RebuildList(Index: Integer);
var Source: TCatalogSource; Item: TListItem;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for Source in FSources do
    begin
      Item := FList.Items.Add; Item.Caption := Source.Name; Item.SubItems.Add(Source.Root);
      if Source.IsINPX then Item.SubItems.Add(Source.INPXFile) else Item.SubItems.Add(Source.CollectionFile);
      if SameText(Source.LibraryNamespace,'flibusta') then Item.SubItems.Add('Флибуста')
      else if SameText(Source.LibraryNamespace,'librusec') then Item.SubItems.Add('Либрусек')
      else if SameText(Source.LibraryNamespace,'mixed') then Item.SubItems.Add('Флибуста + Либрусек')
      else Item.SubItems.Add('По каждой книге');
      if not DirectoryExists(Source.Root) then Item.SubItems.Add('Нет папки книг')
      else if Source.IsINPX then
      begin
        if not FileExists(Source.INPXFile) then Item.SubItems.Add('INPX не найден')
        else
          try
            if FileExists(Source.CacheFile) then Item.SubItems.Add('Список подготовлен')
            else Item.SubItems.Add('Нужно обновить список');
          except on E: Exception do Item.SubItems.Add('Повреждена запись источника'); end;
      end
      else if not FileExists(Settings.ExpandCollectionFileName(Source.CollectionFile)) then Item.SubItems.Add('Каталог не найден')
      else Item.SubItems.Add('Локальная коллекция');
    end;
    if (Index >= 0) and (Index < FList.Items.Count) then FList.Items[Index].Selected := True;
  finally FList.Items.EndUpdate; end;
  FAllSources.Caption:=Format('Участвуют все источники в списке: %d. Выделять их вместе не нужно.',[Length(FSources)]);
  UpdateSelection; UpdateSpaceEstimate;
end;

procedure TfrmCatalogSources.UpdateSpaceEstimate;
var Source: TCatalogSource; One, Growth: TCollectionSpaceEstimate;
  FileName, TargetFile, SystemFile: string; NewSnapshots, Temporary, Existing: Int64;
begin
  if not Assigned(FSpace) then Exit;
  Growth:=Default(TCollectionSpaceEstimate); Growth.Known:=True;
  NewSnapshots:=0; Temporary:=0;
  for Source in FSources do
  begin
    One:=Default(TCollectionSpaceEstimate);
    try
    if Source.IsINPX then
    begin
      FileName:=Source.CacheFile;
      if FileExists(FileName) then One:=EstimateCatalogBytes(FileName)
      else
      begin
        One:=EstimateCatalogBytes(Source.INPXFile);
        if One.Known then Inc(NewSnapshots,One.HighBytes);
      end;
    end
    else FileName:=Settings.ExpandCollectionFileName(Source.CollectionFile);
    if not Source.IsINPX then One:=EstimateCatalogBytes(FileName);
    except on Error: Exception do One:=Default(TCollectionSpaceEstimate); end;
    Growth.Known:=Growth.Known and One.Known;
    Inc(Growth.LowBytes,One.LowBytes); Inc(Growth.HighBytes,One.HighBytes);
  end;
  if Assigned(FPlan) and (FPlan.Total>0) then
  begin
    Growth.LowBytes:=Round(Growth.LowBytes*(FPlan.NewBooks/Double(FPlan.Total)));
    Growth.HighBytes:=Round(Growth.HighBytes*(FPlan.NewBooks/Double(FPlan.Total)));
    // Existing copies still add locations and metadata links, even with no new cards.
    Inc(Growth.HighBytes,Int64(FPlan.Total)*512);
  end;
  Inc(Growth.LowBytes,NewSnapshots); Inc(Growth.HighBytes,NewSnapshots);
  TargetFile:=Settings.ExpandCollectionFileName(VarToStr(FTarget.GetProperty(PROP_DATAFILE)));
  Existing:=0; if FileExists(TargetFile) then Existing:=TFile.GetSize(TargetFile);
  // Reserve only the destination and personal-store snapshots. Source
  // catalogs are read-only and are no longer copied into each merge backup.
  Temporary:=Existing+Growth.HighBytes;
  if FileExists(TargetFile+'-wal') then Inc(Temporary,TFile.GetSize(TargetFile+'-wal'));
  SystemFile:=Settings.SystemFileName[sfSystemDB];
  if FileExists(SystemFile) then Inc(Temporary,TFile.GetSize(SystemFile));
  if FileExists(SystemFile+'-wal') then Inc(Temporary,TFile.GetSize(SystemFile+'-wal'));
  FSpace.Caption:=CollectionSpaceText(Growth,Temporary,CollectionDiskFree(Settings.DataPath))+#13#10+
    'Оценка приблизительная. Архивы книг остаются в исходных папках; уже импортированные книги учитываются после проверки.';
  LayoutSeriesScope;
end;

procedure TfrmCatalogSources.UpdateSelection;
var Index: Integer; Source: TCatalogSource;
begin
  Index:=FList.ItemIndex;
  FRefresh.Enabled:=(Index>=0) and (Index<Length(FSources));
  FRoot.Enabled:=FRefresh.Enabled; FIndexFile.Enabled:=FRefresh.Enabled;
  FLibrary.Enabled:=FRefresh.Enabled; FDisconnect.Enabled:=FRefresh.Enabled;
  FUp.Enabled:=Index>0; FDown.Enabled:=(Index>=0) and (Index<High(FSources));
  FPreview.Enabled:=(Length(FSources)>0) and not FBusy;
  if Assigned(FMetadataFill) then FMetadataFill.Enabled:=not FBusy;
  if Assigned(FDuplicates) then FDuplicates.Enabled:=not FBusy;
  if not FRefresh.Enabled then begin FDetails.Caption:='Выберите источник в списке, чтобы изменить его настройки.'; Exit; end;
  Source:=FSources[Index]; FRefresh.Enabled:=Source.IsINPX;
  FRoot.Enabled:=Source.IsINPX; FIndexFile.Enabled:=Source.IsINPX;
  if Source.IsINPX then FDetails.Caption:='Изменение одного источника: '+Source.Name+'. Если список подготовлен, сразу проверяйте все источники.'
  else FDetails.Caption:='Выбрана локальная коллекция: '+Source.Name+'. Её папка и каталог настраиваются в свойствах самой коллекции.';
end;

procedure TfrmCatalogSources.Selected(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if Assigned(FDetails) then UpdateSelection;
end;

procedure TfrmCatalogSources.UpdatePolicyHelp;
begin
  case FPolicy.ItemIndex of
    0: FPolicyHelp.Caption:='Книги из разных файлов остаются отдельными. Повторное подключение того же файла не создаёт новую запись.';
    1: FPolicyHelp.Caption:='Проверенные копии одной книги показываются одной записью. Для чтения выбирается источник выше в списке; все пути к копиям сохраняются.';
    2: FPolicyHelp.Caption:='Проверенные копии одной книги показываются одной записью. Для чтения выбирается меньший файл; это экономит место в кэше, но не гарантирует качество.';
  end;
end;

procedure TfrmCatalogSources.AddINPX(Sender: TObject);
var Dialog: TOpenDialog; Source: TCatalogSource; Root: string; I: Integer;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := 'Выберите индекс INPX'; Dialog.Filter := 'Индекс INPX (*.inpx)|*.inpx';
    Dialog.Options := [ofFileMustExist,ofPathMustExist,ofEnableSizing];
    if not Dialog.Execute then Exit;
    for I := 0 to High(FSources) do
      if SameFileName(FSources[I].INPXFile, Dialog.FileName) then
      begin RebuildList(I); Exit; end;
    Root := ExtractFilePath(Dialog.FileName);
    if not SelectDirectory('Папка с архивами книг этого источника', '', Root, [sdNewUI,sdShowEdit]) then Exit;
    Source.ID := TCatalogSource.NewID; Source.Name := ChangeFileExt(ExtractFileName(Dialog.FileName),'');
    Source.INPXFile := TPath.GetFullPath(Dialog.FileName); Source.Root := TPath.GetFullPath(Root);
    Source.CollectionID := INVALID_COLLECTION_ID;
    InvalidatePreview('Добавлен источник.'); SetLength(FSources,Length(FSources)+1); FSources[High(FSources)] := Source;
    Save; RebuildList(High(FSources));
    RefreshSource(nil);
  finally Dialog.Free; end;
end;

procedure TfrmCatalogSources.AddCollection(Sender: TObject);
var Dialog: TForm; List: TListBox; OK: TButton; Iterator: ICollectionInfoIterator;
  Info: TCollectionInfo; Infos: TArray<TCollectionInfo>; Source: TCatalogSource; N, I: Integer;
begin
  Dialog := TForm.CreateNew(Self);
  try
    Dialog.Caption := 'Локальная коллекция для объединения'; Dialog.Position := poOwnerFormCenter;
    Dialog.Font.Assign(Font); Dialog.ClientWidth := 460; Dialog.ClientHeight := 330; Dialog.BorderStyle := bsDialog;
    List := TListBox.Create(Dialog); List.Parent := Dialog; List.SetBounds(12,12,436,258);
    Iterator := SystemDB.GetCollectionInfoIterator;
    while Iterator.Next(Info) do
      if (Info.ID <> FTarget.CollectionID) and not isOnlineCollection(Info.CollectionType) then
      begin
        N := Length(Infos); SetLength(Infos,N+1); Infos[N] := Info; List.Items.Add(Info.DisplayName);
      end;
    OK := TButton.Create(Dialog); OK.Parent := Dialog; OK.SetBounds(236,288,100,28);
    OK.Caption := 'Добавить'; OK.ModalResult := mrOk; OK.Default := True;
    OK := TButton.Create(Dialog); OK.Parent := Dialog; OK.SetBounds(348,288,100,28);
    OK.Caption := 'Отмена'; OK.ModalResult := mrCancel; OK.Cancel := True;
    if List.Items.Count > 0 then List.ItemIndex := 0;
    if (Dialog.ShowModal <> mrOk) or (List.ItemIndex < 0) then Exit;
    Info := Infos[List.ItemIndex];
    for I := 0 to High(FSources) do if FSources[I].CollectionID = Info.ID then begin RebuildList(I); Exit; end;
    Source.ID := TCatalogSource.NewID; Source.Name := Info.DisplayName;
    Source.CollectionID := Info.ID; Source.CollectionFile := Info.DBFileName; Source.Root := Info.RootFolder;
    InvalidatePreview('Добавлен источник.'); SetLength(FSources,Length(FSources)+1); FSources[High(FSources)] := Source;
    Save; RebuildList(High(FSources));
  finally Dialog.Free; end;
end;

procedure TfrmCatalogSources.MoveSource(Sender: TObject);
var FromIndex, ToIndex: Integer; Source: TCatalogSource;
begin
  FromIndex := FList.ItemIndex; ToIndex := FromIndex + TButton(Sender).Tag;
  if (FromIndex < 0) or (ToIndex < 0) or (ToIndex >= Length(FSources)) then Exit;
  InvalidatePreview('Изменён порядок источников.'); Source := FSources[FromIndex]; FSources[FromIndex] := FSources[ToIndex]; FSources[ToIndex] := Source;
  Save; RebuildList(ToIndex);
end;

procedure TfrmCatalogSources.DisconnectSource(Sender: TObject);
var Index, I: Integer; RemovedRoot: string; RetainedRoots: TArray<string>;
  Iterator: ICollectionInfoIterator; Info: TCollectionInfo; Others: TCatalogSources; Source: TCatalogSource;
  procedure KeepRoot(const Root: string);
  begin SetLength(RetainedRoots,Length(RetainedRoots)+1); RetainedRoots[High(RetainedRoots)]:=Root; end;
begin
  Index := FList.ItemIndex; if Index < 0 then Exit;
  InvalidatePreview('Источник отключён.'); RemovedRoot:=FSources[Index].Root;
  for I := Index to High(FSources)-1 do FSources[I] := FSources[I+1];
  SetLength(FSources,Length(FSources)-1); Save; RebuildList(Index);
  SetLength(RetainedRoots,Length(FSources));
  for I:=0 to High(FSources) do RetainedRoots[I]:=FSources[I].Root;
  Iterator:=SystemDB.GetCollectionInfoIterator;
  while Iterator.Next(Info) do
    if Info.ID<>FTarget.CollectionID then
    begin
      KeepRoot(Info.RootFolder);
      Others:=LoadCatalogSources(SystemDB.GetCollection(Info.ID));
      for Source in Others do KeepRoot(Source.Root);
    end;
  RemoveBookCacheSource(RemovedRoot,RetainedRoots);
  FReport.Lines.Text := 'Источник отключён. Его кэш очищен; общие файлы других подключённых источников сохранены. Уже добавленные книги сохранены.';
end;

procedure TfrmCatalogSources.ChooseRoot(Sender: TObject);
var Root: string; Index: Integer;
begin
  Index := FList.ItemIndex; if (Index < 0) or not FSources[Index].IsINPX then Exit;
  Root := FSources[Index].Root;
  if not SelectDirectory('Папка книг выбранного источника', '', Root, [sdNewUI,sdShowEdit]) then Exit;
  InvalidatePreview('Изменена папка книг источника.'); FSources[Index].Root := TPath.GetFullPath(Root); Save; RebuildList(Index);
end;

procedure TfrmCatalogSources.ChooseIndexFile(Sender: TObject);
var Dialog: TOpenDialog; Index: Integer;
begin
  Index := FList.ItemIndex; if (Index < 0) or not FSources[Index].IsINPX then Exit;
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := 'Новый INPX выбранного источника'; Dialog.Filter := 'Индекс INPX (*.inpx)|*.inpx';
    Dialog.Options := [ofFileMustExist,ofPathMustExist,ofEnableSizing];
    Dialog.InitialDir := ExtractFilePath(FSources[Index].INPXFile);
    if not Dialog.Execute then Exit;
    InvalidatePreview('Выбран другой файл INPX.'); FSources[Index].INPXFile := TPath.GetFullPath(Dialog.FileName);
    Save; RebuildList(Index);
    FReport.Lines.Text := 'Файл индекса изменён. Обновите выбранный источник, затем выполните предпросмотр.';
  finally Dialog.Free; end;
end;

procedure TfrmCatalogSources.RunWorker(Worker: TWorker; const Caption: string; OwnerWindow: TCustomForm);
var Progress: TImportProgressFormEx;
begin
  if not Assigned(OwnerWindow) then OwnerWindow:=Self;
  Progress := TImportProgressFormEx.Create(OwnerWindow);
  try
    Progress.Caption := Caption; Progress.WorkerThread := Worker; Progress.CloseOnTimer := True;
    Progress.PopupMode:=pmExplicit; Progress.PopupParent:=OwnerWindow;
    Progress.Timer.Interval:=1;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
  finally Progress.Free; end;
end;

procedure TfrmCatalogSources.RefreshSource(Sender: TObject);
var Worker: TCatalogRefreshWorker; Index: Integer;
begin
  Index := FList.ItemIndex; if (Index < 0) or not FSources[Index].IsINPX then Exit;
  InvalidatePreview('Список выбранного источника перечитывается.'); Worker := TCatalogRefreshWorker.Create(FSources[Index]);
  try
    RunWorker(Worker,'Обновление источника — ' + FSources[Index].Name);
    if Worker.Success then FReport.Lines.Text := 'Источник обновлён. Выполните предпросмотр объединения.'
    else FReport.Lines.Text := Worker.Error;
  finally Worker.Free; RebuildList(Index); end;
end;

procedure TfrmCatalogSources.Preview(Sender: TObject);
var Worker: TCatalogMergeWorker; Revision: Integer;
begin
  if FBusy or (Length(FSources)=0) then Exit;
  InvalidatePreview; Revision:=FPreviewRevision; FLastReportFile:=''; FBusy:=True; UpdateSelection;
  SetWorkflowState(cwsChecking,'Проверяем все источники с выбранным режимом. Текущая коллекция пока не меняется.');
  Worker:=nil;
  try
    try
      Worker:=TCatalogMergeWorker.CreatePreview(FTarget.CollectionID,FSources,TCollectionMergePolicy(FPolicy.ItemIndex));
      RunWorker(Worker,'Проверка источников коллекции');
      if Revision<>FPreviewRevision then
      begin
        FReport.Lines.Text:='Настройки изменились во время проверки. Этот результат не используется для добавления книг.';
        SetWorkflowState(cwsNeedsPreview,'Настройки изменились во время проверки. Нажмите «1. Проверить все источники» ещё раз.');
      end
      else if Worker.Success then
      begin
        FPlan:=Worker.TakePlan; FReport.Lines.Assign(FPlan.Report); FApply.Enabled:=True;
        SetWorkflowState(cwsReady,Format('Все источники проверены: %d. Новых книг: %d, совпадений: %d. Нажмите «2. Добавить книги в коллекцию».',
          [Length(FSources),FPlan.NewBooks,FPlan.Duplicates]));
      end
      else
      begin
        if Worker.Error='' then FReport.Lines.Text:='Проверка отменена. Коллекция не изменена.'
        else FReport.Lines.Text:=Worker.Error;
        SetWorkflowState(cwsFailed,'Проверка не завершена. Причина в отчёте. После исправления нажмите «1. Проверить все источники».'); end;
    except
      on E: Exception do
      begin FReport.Lines.Text:=E.Message;
        SetWorkflowState(cwsFailed,'Проверка не завершена. Причина в отчёте. После исправления повторите проверку.'); end;
    end;
  finally
    Worker.Free; FBusy:=False; UpdateSelection; UpdateSpaceEstimate;
    SetWorkflowState(FWorkflowState,FWorkflowDetails.Caption);
  end;
end;

procedure TfrmCatalogSources.Apply(Sender: TObject);
var Worker: TCatalogMergeWorker; Backup: string; Plan: TCollectionMergePlan; Succeeded: Boolean;
begin
  if FBusy then Exit;
  if not Assigned(FPlan) then
  begin SetWorkflowState(cwsNeedsPreview,'Параметры ещё не проверены. Нажмите «1. Проверить все источники», затем добавьте книги.'); Exit; end;
  // The running worker owns a borrowed pointer. Keep it local so invalidation
  // of the dialog cannot free a plan while its background operation uses it.
  Plan:=FPlan; FPlan:=nil; FBusy:=True; FApply.Enabled:=False; UpdateSelection; Succeeded:=False;
  SetWorkflowState(cwsApplying,'Добавляем книги по результату последней проверки. Дождитесь завершения операции.');
  Backup:=''; Worker:=nil;
  try
    try
      Backup:=TPath.Combine(Settings.DataPath,'Backups\merge-'+FormatDateTime('yyyymmdd-hhnnss',Now)+'-'+TCatalogSource.NewID);
      Worker:=TCatalogMergeWorker.CreateApply(Plan,Backup);
      RunWorker(Worker,'Объединение коллекции');
      if FileExists(TPath.Combine(Backup,'preview.txt')) then FLastReportFile:=TPath.Combine(Backup,'preview.txt');
      Succeeded:=Worker.Success;
      if Succeeded then
      begin FChanged:=True; FReport.Lines.Add(''); FReport.Lines.Add('Объединение завершено.');
        FReport.Lines.Add('Резервные копии и отчёт: '+Backup); end
      else FReport.Lines.Add(Worker.Error+#13#10+'Папка операции: '+Backup);
    except on E: Exception do FReport.Lines.Add(E.Message+#13#10+'Папка операции: '+Backup); end;
  finally Worker.Free; Plan.Free; FBusy:=False; InvalidatePreview; UpdateSelection; end;
  if Succeeded then SetWorkflowState(cwsDone,'Результат и резервная копия указаны в отчёте. Для другого режима сначала повторите проверку.')
  else SetWorkflowState(cwsFailed,'Добавление не завершено. Подробности в отчёте. Перед следующей попыткой повторите проверку.');
end;

procedure TfrmCatalogSources.PreviewSeriesAliases(Sender: TObject);
var Review: TfrmSeriesAliasReview;
begin
  Review:=TfrmSeriesAliasReview.CreateFor(Self);
  try Review.ShowModal; finally Review.Free; end;
end;

procedure TfrmCatalogSources.ReviewDuplicates(Sender: TObject);
begin
  if FBusy then Exit;
  // Reopen the active collection in the main form before reviewing its records.
  // An import or metadata operation may have changed it while this dialog was open.
  FDuplicatesRequested:=True;
  ModalResult:=mrOk;
end;

procedure TfrmCatalogSources.FillBookMetadata(Sender: TObject);
var Changed: Boolean;
begin
  if FBusy then Exit;
  FBusy:=True; Changed:=False; UpdateSelection;
  try Changed:=FillMissingBookMetadata(Self,FTarget.CollectionID);
  finally FBusy:=False; UpdateSelection; end;
  if Changed then
  begin
    FMetadataChanged:=True;
    InvalidatePreview('Недостающие сведения книг текущей коллекции заполнены.');
    UpdateSpaceEstimate;
  end;
end;

constructor TfrmSeriesAliasReview.CreateFor(SourceDialog: TfrmCatalogSources);
var Header, Footer: TPanel; B: TButton; WorkArea: TRect;
begin
  inherited CreateNew(SourceDialog); FSourceDialog:=SourceDialog;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  Caption:='Объединить названия серий — '+SourceDialog.FTarget.CollectionDisplayName;
  Position:=poOwnerFormCenter; BorderStyle:=bsSizeable; ClientWidth:=820; ClientHeight:=560;
  Constraints.MinWidth:=700; Constraints.MinHeight:=380;
  PopupMode:=pmExplicit; PopupParent:=SourceDialog;
  Header:=TPanel.Create(Self); Header.Parent:=Self; Header.Align:=alTop; Header.Height:=100; Header.BevelOuter:=bvNone;
  FSummary:=TLabel.Create(Self); FSummary.Parent:=Header; FSummary.AutoSize:=False;
  FSummary.SetBounds(12,10,796,80); FSummary.Anchors:=[akLeft,akTop,akRight]; FSummary.WordWrap:=True;
  FSummary.Caption:='Проверяем серии уже существующей коллекции. Повторно импортировать источники не нужно.';
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.SetBounds(0,ClientHeight-48,ClientWidth,48);
  Footer.Align:=alBottom; Footer.BevelOuter:=bvNone;
  FCheck:=TButton.Create(Self); FCheck.Parent:=Footer; FCheck.SetBounds(12,10,150,28);
  FCheck.Caption:='Проверить ещё раз'; FCheck.OnClick:=PreviewAliases;
  FApply:=TButton.Create(Self); FApply.Parent:=Footer; FApply.SetBounds(174,10,310,28);
  FApply.Caption:='Объединить найденные серии'; FApply.Enabled:=False; FApply.OnClick:=ApplyAliases;
  B:=TButton.Create(Self); B.Parent:=Footer; B.SetBounds(708,10,100,28); B.Anchors:=[akTop,akRight];
  B.Caption:='Закрыть'; B.Cancel:=True; B.ModalResult:=mrClose;
  FReport:=TMemo.Create(Self); FReport.Parent:=Self; FReport.Align:=alClient; FReport.ReadOnly:=True;
  FReport.AlignWithMargins:=True; FReport.Margins.SetBounds(12,0,12,0);
  FReport.ScrollBars:=ssVertical; FReport.WordWrap:=True;
  OnShow:=PreviewAliases; ScaleForPPI(Screen.PixelsPerInch);
  WorkArea:=Monitor.WorkareaRect; Height:=Min(Height,Max(Constraints.MinHeight,WorkArea.Height-48));
end;

destructor TfrmSeriesAliasReview.Destroy;
begin FPlan.Free; inherited; end;

procedure TfrmSeriesAliasReview.PreviewAliases(Sender: TObject);
var Worker: TSeriesAliasWorker;
begin
  OnShow:=nil; FreeAndNil(FPlan); FApply.Enabled:=False; FCheck.Enabled:=False; FFinished:=False;
  Worker:=TSeriesAliasWorker.CreatePreview(FSourceDialog.FTarget.CollectionID);
  try
    FSourceDialog.RunWorker(Worker,'Проверка названий серий',Self);
    if Worker.Success then
    begin
      FPlan:=Worker.TakePlan; FReport.Lines.Assign(FPlan.Report);
      if FPlan.Count>0 then
      begin
        FSummary.Caption:=Format('Найдено пар серий: %s. Ниже показано «старое название → единое название». '+
          'Для применения нажмите «Объединить». Книги и личные данные сохраняются; перед изменением создаётся резервная копия.',[FormatFloat('#,##0',FPlan.Count)]);
        FApply.Caption:=Format('Объединить %s пар серий',[FormatFloat('#,##0',FPlan.Count)]); FApply.Enabled:=True;
      end
      else begin FSummary.Caption:='Проверка завершена: подходящих пар не найдено. Коллекция не изменена.';
        FReport.Lines.Add('Похожие, но разные названия и серии разных авторов автоматически не объединяются.'); end;
    end
    else begin FSummary.Caption:='Проверка не завершена. Коллекция не изменена.'; FReport.Lines.Text:=Worker.Error; end;
  finally Worker.Free; FCheck.Enabled:=True; end;
end;

procedure TfrmSeriesAliasReview.ApplyAliases(Sender: TObject);
var Worker: TSeriesAliasWorker; Backup: string;
begin
  if not Assigned(FPlan) or (FPlan.Count=0) or FFinished then Exit;
  FApply.Enabled:=False; FCheck.Enabled:=False;
  Backup:=TPath.Combine(Settings.DataPath,'Backups\series-'+FormatDateTime('yyyymmdd-hhnnss',Now)+'-'+TCatalogSource.NewID);
  Worker:=TSeriesAliasWorker.CreateApply(FPlan,Backup);
  try
    FSourceDialog.RunWorker(Worker,'Объединение названий серий',Self);
    if Worker.Success then
    begin
      FFinished:=True; FSourceDialog.FChanged:=True; FSourceDialog.InvalidatePreview('Названия серий текущей коллекции изменены.');
      FSourceDialog.FLastReportFile:=TPath.Combine(Backup,'series.txt');
      FSummary.Caption:=Format('Готово: объединено %s пар серий. Закройте это окно и окно источников, чтобы обновить список серий.',[FormatFloat('#,##0',FPlan.Count)]);
      FReport.Lines.Add(''); FReport.Lines.Add('Резервная копия и полный отчёт: '+Backup);
      FSourceDialog.FReport.Lines.Text:=FSummary.Caption+sLineBreak+'Резервная копия и полный отчёт: '+Backup;
    end
    else begin FSummary.Caption:='Объединение не завершено. Подробности ниже.';
      FReport.Lines.Add(Worker.Error+sLineBreak+'Папка операции: '+Backup); FApply.Enabled:=True; end;
  finally Worker.Free; FCheck.Enabled:=True; end;
end;

procedure TfrmCatalogSources.PolicyChanged(Sender: TObject);
const Names: array[0..3] of string = ('','flibusta','librusec','mixed');
begin
  if Sender=FTargetLibrary then InvalidatePreview('Изменена библиотека номеров текущей коллекции.')
  else InvalidatePreview('Изменён режим повторных книг.');
  if Sender = FTargetLibrary then FTarget.SetProperty(PROP_SOURCE_LIBRARY, Names[FTargetLibrary.ItemIndex]);
  UpdatePolicyHelp;
  FReport.Lines.Text := 'Настройки изменены. Нажмите «1. Проверить все источники», чтобы увидеть, что добавится или объединится. Для совпадающих номеров книг важно знать библиотеку источника. ' +
    'ID смешанных индексов уже содержат библиотеку. Качество выбирайте порядком источников: больший размер сам по себе его не гарантирует.';
end;

procedure TfrmCatalogSources.ChooseLibrary(Sender: TObject);
const Names: array[0..3] of string = ('','flibusta','librusec','mixed');
var Dialog: TForm; Choice: TComboBox; B: TButton; LabelText: TLabel; Index: Integer;
begin
  Index := FList.ItemIndex; if Index < 0 then Exit;
  Dialog := TForm.CreateNew(Self);
  try
    Dialog.Caption := 'Библиотека источника — ' + FSources[Index].Name;
    Dialog.Font.Assign(Font); Dialog.Position := poOwnerFormCenter; Dialog.BorderStyle := bsDialog;
    Dialog.ClientWidth := 470; Dialog.ClientHeight := 190;
    LabelText := TLabel.Create(Dialog); LabelText.Parent := Dialog; LabelText.SetBounds(12,10,446,68);
    LabelText.AutoSize := False; LabelText.WordWrap := True;
    LabelText.Caption := 'Укажите, откуда книги этого источника. В смешанном каталоге используются отдельные номера каждой библиотеки. Книги с простыми номерами без указания библиотеки не объединяются по номеру.';
    Choice := TComboBox.Create(Dialog); Choice.Parent := Dialog; Choice.Style := csDropDownList;
    Choice.SetBounds(12,88,446,26); Choice.Items.Assign(FTargetLibrary.Items); Choice.ItemIndex := 0;
    if SameText(FSources[Index].LibraryNamespace,'flibusta') then Choice.ItemIndex := 1;
    if SameText(FSources[Index].LibraryNamespace,'librusec') then Choice.ItemIndex := 2;
    if SameText(FSources[Index].LibraryNamespace,'mixed') then Choice.ItemIndex := 3;
    B := TButton.Create(Dialog); B.Parent := Dialog; B.SetBounds(246,142,100,28);
    B.Caption := 'Выбрать'; B.ModalResult := mrOk; B.Default := True;
    B := TButton.Create(Dialog); B.Parent := Dialog; B.SetBounds(358,142,100,28);
    B.Caption := 'Отмена'; B.ModalResult := mrCancel; B.Cancel := True;
    if Dialog.ShowModal <> mrOk then Exit;
    InvalidatePreview('Изменена библиотека источника.'); FSources[Index].LibraryNamespace := Names[Choice.ItemIndex]; Save; RebuildList(Index);
  finally Dialog.Free; end;
end;

procedure TfrmCatalogSources.SaveReport(Sender: TObject);
var Dialog: TSaveDialog;
begin
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Filter := 'Текстовый отчёт (*.txt)|*.txt'; Dialog.DefaultExt := 'txt'; Dialog.FileName := 'Объединение коллекции.txt';
    Dialog.Options := [ofOverwritePrompt,ofPathMustExist,ofEnableSizing];
    if Dialog.Execute then
      if Assigned(FPlan) then TFile.Copy(FPlan.FullReportFile,Dialog.FileName,True)
      else if FileExists(FLastReportFile) then TFile.Copy(FLastReportFile,Dialog.FileName,True)
      else FReport.Lines.SaveToFile(Dialog.FileName,TEncoding.UTF8);
  finally Dialog.Free; end;
end;

end.
