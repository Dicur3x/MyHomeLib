unit frm_CatalogSources;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  unit_Interfaces, unit_CatalogSources, unit_CollectionMerge, unit_WorkerThread, unit_SeriesAliases;

type
  TfrmCatalogSources = class(TForm)
  private
    FTarget: IBookCollection;
    FSources: TCatalogSources;
    FPlan: TCollectionMergePlan;
    FSeriesPlan: TSeriesAliasPlan;
    FList: TListView;
    FReport: TMemo;
    FApply, FRefresh, FRoot, FIndexFile, FUp, FDown, FDisconnect, FLibrary, FPreview: TButton;
    FDetails, FPolicyHelp: TLabel;
    FPolicy, FTargetLibrary: TComboBox;
    FChanged: Boolean;
    FLastReportFile: string;
    function Button(ParentPanel: TPanel; const Caption: string; Left, Width: Integer;
      Handler: TNotifyEvent): TButton;
    procedure InvalidatePreview;
    procedure RebuildList(Index: Integer);
    procedure UpdateSelection;
    procedure UpdatePolicyHelp;
    procedure AddINPX(Sender: TObject);
    procedure AddCollection(Sender: TObject);
    procedure MoveSource(Sender: TObject);
    procedure DisconnectSource(Sender: TObject);
    procedure ChooseRoot(Sender: TObject);
    procedure ChooseIndexFile(Sender: TObject);
    procedure RefreshSource(Sender: TObject);
    procedure Preview(Sender: TObject);
    procedure Apply(Sender: TObject);
    procedure PreviewSeriesAliases(Sender: TObject);
    procedure ApplySeriesAliases;
    procedure SaveReport(Sender: TObject);
    procedure Selected(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure RunWorker(Worker: TWorker; const Caption: string);
    procedure Save;
    procedure PolicyChanged(Sender: TObject);
    procedure ChooseLibrary(Sender: TObject);
  public
    constructor CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
    destructor Destroy; override;
    property CatalogChanged: Boolean read FChanged;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Variants, Vcl.Controls, Vcl.Graphics,
  Vcl.Dialogs, Vcl.FileCtrl, unit_Consts, unit_Settings, unit_Globals,
  frm_ImportProgressFormEx, unit_BookCache, dm_user;

constructor TfrmCatalogSources.CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
var Panel: TPanel; LabelText: TLabel; B: TButton;
  function LabelAt(AParent: TPanel; const Text: string; X,Y,W,H: Integer): TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=AParent; Result.AutoSize:=False;
    Result.SetBounds(X,Y,W,H); Result.WordWrap:=True; Result.Caption:=Text;
    Result.Anchors:=[akLeft,akTop,akRight];
  end;
begin
  inherited CreateNew(AOwner);
  FTarget:=Collection; FSources:=LoadCatalogSources(FTarget);
  Caption:='Источники коллекции — '+FTarget.CollectionDisplayName;
  Font.Name:='Segoe UI'; Font.Size:=9; Position:=poOwnerFormCenter;
  BorderStyle:=bsSizeable; ClientWidth:=960; ClientHeight:=760;
  Constraints.MinWidth:=976; Constraints.MinHeight:=740;
  DisableAlign;
  try
  Panel:=TPanel.Create(Self); Panel.Parent:=Self; Panel.SetBounds(0,0,ClientWidth,76); Panel.Align:=alTop; Panel.BevelOuter:=bvNone;
  LabelText:=LabelAt(Panel,'Из каких каталогов собрать эту коллекцию',12,9,936,22);
  LabelText.Font.Style:=[fsBold]; LabelText.Font.Size:=11;
  LabelAt(Panel,'INPX — список книг; папка книг — место, где лежат сами файлы и архивы. Можно подключить несколько библиотек, включая смешанные каталоги Флибусты и Либрусека.',12,36,936,34);
  FList:=TListView.Create(Self); FList.Parent:=Self; FList.SetBounds(0,76,ClientWidth,166); FList.Align:=alTop;
  FList.ViewStyle:=vsReport; FList.ReadOnly:=True; FList.RowSelect:=True;
  FList.HideSelection:=False; FList.DoubleBuffered:=True; FList.ShowHint:=True;
  FList.Hint:='Каждая строка — отдельный источник. Для режима «Предпочитать источник» порядок сверху вниз задаёт приоритет.';
  FList.Columns.Add.Caption:='Источник'; FList.Columns[0].Width:=175;
  FList.Columns.Add.Caption:='Папка с книгами'; FList.Columns[1].Width:=230;
  FList.Columns.Add.Caption:='Файл каталога'; FList.Columns[2].Width:=240;
  FList.Columns.Add.Caption:='Библиотека'; FList.Columns[3].Width:=145;
  FList.Columns.Add.Caption:='Состояние'; FList.Columns[4].Width:=150;
  FList.OnSelectItem:=Selected;
  Panel:=TPanel.Create(Self); Panel.Parent:=Self; Panel.SetBounds(0,242,ClientWidth,158); Panel.Align:=alTop; Panel.BevelOuter:=bvNone;
  Button(Panel,'Добавить INPX…',12,148,AddINPX);
  Button(Panel,'Добавить коллекцию…',166,182,AddCollection);
  FUp:=Button(Panel,'↑',366,38,MoveSource); FUp.Tag:=-1;
  FDown:=Button(Panel,'↓',410,38,MoveSource); FDown.Tag:=1;
  FDisconnect:=Button(Panel,'Отключить источник',468,174,DisconnectSource);
  FDisconnect.Hint:='Убирает источник из списка и его ненужный кэш. Книги, уже добавленные в эту коллекцию, сохраняются.'; FDisconnect.ShowHint:=True;
  FRoot:=Button(Panel,'Изменить папку книг…',12,204,ChooseRoot); FRoot.Top:=44;
  FIndexFile:=Button(Panel,'Заменить файл INPX…',222,204,ChooseIndexFile); FIndexFile.Top:=44;
  FLibrary:=Button(Panel,'Библиотека источника…',432,210,ChooseLibrary); FLibrary.Top:=44;
  FRefresh:=Button(Panel,'1. Обновить список книг',12,238,RefreshSource); FRefresh.Top:=80;
  FRefresh.Hint:='Перечитывает выбранный INPX в отдельный каталог источника. Текущая коллекция пока не меняется.'; FRefresh.ShowHint:=True;
  FPreview:=Button(Panel,'2. Проверить объединение',264,252,Preview); FPreview.Top:=80;
  FDetails:=LabelAt(Panel,'',12,118,936,36);
  Panel:=TPanel.Create(Self); Panel.Parent:=Self; Panel.SetBounds(0,400,ClientWidth,136); Panel.Align:=alTop; Panel.BevelOuter:=bvNone;
  LabelAt(Panel,'Повторные книги:',12,10,142,20);
  FPolicy:=TComboBox.Create(Self); FPolicy.Parent:=Panel; FPolicy.Style:=csDropDownList;
  FPolicy.SetBounds(158,6,790,26); FPolicy.Anchors:=[akLeft,akTop,akRight];
  FPolicy.Items.Add('Сохранить все разные копии');
  FPolicy.Items.Add('Одна запись — предпочитать источник выше в списке');
  FPolicy.Items.Add('Одна запись — предпочитать меньший файл');
  FPolicy.ItemIndex:=0; FPolicy.OnChange:=PolicyChanged;
  FPolicyHelp:=LabelAt(Panel,'',158,36,790,42);
  LabelAt(Panel,'Текущая коллекция:',12,86,142,20);
  FTargetLibrary:=TComboBox.Create(Self); FTargetLibrary.Parent:=Panel; FTargetLibrary.Style:=csDropDownList;
  FTargetLibrary.SetBounds(158,82,342,26);
  FTargetLibrary.Items.Add('Определять библиотеку по каждой книге');
  FTargetLibrary.Items.Add('Только Флибуста'); FTargetLibrary.Items.Add('Только Либрусек');
  FTargetLibrary.Items.Add('Флибуста + Либрусек (смешанная)'); FTargetLibrary.ItemIndex:=0;
  if SameText(VarToStr(FTarget.GetProperty(PROP_SOURCE_LIBRARY)),'flibusta') then FTargetLibrary.ItemIndex:=1;
  if SameText(VarToStr(FTarget.GetProperty(PROP_SOURCE_LIBRARY)),'librusec') then FTargetLibrary.ItemIndex:=2;
  if SameText(VarToStr(FTarget.GetProperty(PROP_SOURCE_LIBRARY)),'mixed') then FTargetLibrary.ItemIndex:=3;
  FTargetLibrary.OnChange:=PolicyChanged;
  LabelAt(Panel,'Если происхождение номера книги неизвестно, разные копии остаются отдельными.',158,112,790,20);
  Panel:=TPanel.Create(Self); Panel.Parent:=Self;
  // Establish the final parent width before anchoring the right-hand button.
  Panel.SetBounds(0,ClientHeight-48,ClientWidth,48); Panel.Align:=alBottom; Panel.BevelOuter:=bvNone;
  FApply:=Button(Panel,'3. Применить объединение',12,238,Apply); FApply.Enabled:=False;
  Button(Panel,'Сохранить отчёт…',264,158,SaveReport);
  Button(Panel,'Проверить дубли серий…',436,232,PreviewSeriesAliases);
  B:=Button(Panel,'Закрыть',848,100,nil); B.Anchors:=[akTop,akRight]; B.ModalResult:=mrClose; B.Cancel:=True;
  FReport:=TMemo.Create(Self); FReport.Parent:=Self; FReport.Align:=alClient;
  FReport.AlignWithMargins:=True; FReport.Margins.Left:=12; FReport.Margins.Right:=12;
  FReport.ReadOnly:=True; FReport.ScrollBars:=ssBoth; FReport.WordWrap:=True;
  FReport.Lines.Text:='Здесь появится результат проверки: сколько книг добавится, какие копии будут объединены и есть ли конфликты.'+#13#10+#13#10+
    'Добавление источника само по себе не объединяет книги. Для INPX сначала обновите список, затем проверьте результат и примените его.'+#13#10+
    'Размер файла не гарантирует качество: если предпочитаете полные иллюстрации, поставьте нужный источник выше и выберите соответствующий режим.'+#13#10+
    'В смешанном каталоге номера Флибусты и Либрусека проверяются отдельно. Одинаковый номер в разных библиотеках не объединяет книги.';
  finally EnableAlign; end;
  UpdatePolicyHelp; RebuildList(0);
end;

destructor TfrmCatalogSources.Destroy;
begin FSeriesPlan.Free; FPlan.Free; inherited; end;

function TfrmCatalogSources.Button(ParentPanel: TPanel; const Caption: string; Left, Width: Integer;
  Handler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self); Result.Parent := ParentPanel;
  Result.Caption := Caption; Result.SetBounds(Left,8,Width,28); Result.OnClick := Handler;
end;

procedure TfrmCatalogSources.InvalidatePreview;
begin
  FreeAndNil(FSeriesPlan); FreeAndNil(FPlan); FApply.Enabled := False;
  FApply.Caption := '3. Применить объединение';
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
  UpdateSelection;
end;

procedure TfrmCatalogSources.UpdateSelection;
var Index: Integer; Source: TCatalogSource;
begin
  Index:=FList.ItemIndex;
  FRefresh.Enabled:=(Index>=0) and (Index<Length(FSources));
  FRoot.Enabled:=FRefresh.Enabled; FIndexFile.Enabled:=FRefresh.Enabled;
  FLibrary.Enabled:=FRefresh.Enabled; FDisconnect.Enabled:=FRefresh.Enabled;
  FUp.Enabled:=Index>0; FDown.Enabled:=(Index>=0) and (Index<High(FSources));
  FPreview.Enabled:=Length(FSources)>0;
  if not FRefresh.Enabled then begin FDetails.Caption:='Выберите источник в списке, чтобы изменить его настройки.'; Exit; end;
  Source:=FSources[Index]; FRefresh.Enabled:=Source.IsINPX;
  FRoot.Enabled:=Source.IsINPX; FIndexFile.Enabled:=Source.IsINPX;
  if Source.IsINPX then FDetails.Caption:='Выбран: '+Source.Name+'. Обновление перечитывает только этот INPX; для изменения коллекции нужны проверка и применение.'
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
    InvalidatePreview; SetLength(FSources,Length(FSources)+1); FSources[High(FSources)] := Source;
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
    InvalidatePreview; SetLength(FSources,Length(FSources)+1); FSources[High(FSources)] := Source;
    Save; RebuildList(High(FSources));
  finally Dialog.Free; end;
end;

procedure TfrmCatalogSources.MoveSource(Sender: TObject);
var FromIndex, ToIndex: Integer; Source: TCatalogSource;
begin
  FromIndex := FList.ItemIndex; ToIndex := FromIndex + TButton(Sender).Tag;
  if (FromIndex < 0) or (ToIndex < 0) or (ToIndex >= Length(FSources)) then Exit;
  InvalidatePreview; Source := FSources[FromIndex]; FSources[FromIndex] := FSources[ToIndex]; FSources[ToIndex] := Source;
  Save; RebuildList(ToIndex);
end;

procedure TfrmCatalogSources.DisconnectSource(Sender: TObject);
var Index, I: Integer; RemovedRoot: string; RetainedRoots: TArray<string>;
  Iterator: ICollectionInfoIterator; Info: TCollectionInfo; Others: TCatalogSources; Source: TCatalogSource;
  procedure KeepRoot(const Root: string);
  begin SetLength(RetainedRoots,Length(RetainedRoots)+1); RetainedRoots[High(RetainedRoots)]:=Root; end;
begin
  Index := FList.ItemIndex; if Index < 0 then Exit;
  InvalidatePreview; RemovedRoot:=FSources[Index].Root;
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
  InvalidatePreview; FSources[Index].Root := TPath.GetFullPath(Root); Save; RebuildList(Index);
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
    InvalidatePreview; FSources[Index].INPXFile := TPath.GetFullPath(Dialog.FileName);
    Save; RebuildList(Index);
    FReport.Lines.Text := 'Файл индекса изменён. Обновите выбранный источник, затем выполните предпросмотр.';
  finally Dialog.Free; end;
end;

procedure TfrmCatalogSources.RunWorker(Worker: TWorker; const Caption: string);
var Progress: TImportProgressFormEx;
begin
  Progress := TImportProgressFormEx.Create(Self);
  try
    Progress.Caption := Caption; Progress.WorkerThread := Worker; Progress.CloseOnTimer := True;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
  finally Progress.Free; end;
end;

procedure TfrmCatalogSources.RefreshSource(Sender: TObject);
var Worker: TCatalogRefreshWorker; Index: Integer;
begin
  Index := FList.ItemIndex; if (Index < 0) or not FSources[Index].IsINPX then Exit;
  InvalidatePreview; Worker := TCatalogRefreshWorker.Create(FSources[Index]);
  try
    RunWorker(Worker,'Обновление источника — ' + FSources[Index].Name);
    if Worker.Success then FReport.Lines.Text := 'Источник обновлён. Выполните предпросмотр объединения.'
    else FReport.Lines.Text := Worker.Error;
  finally Worker.Free; RebuildList(Index); end;
end;

procedure TfrmCatalogSources.Preview(Sender: TObject);
var Worker: TCatalogMergeWorker;
begin
  InvalidatePreview; FLastReportFile := '';
  Worker := TCatalogMergeWorker.CreatePreview(FTarget.CollectionID, FSources,
    TCollectionMergePolicy(FPolicy.ItemIndex));
  try
    RunWorker(Worker,'Предпросмотр объединения');
    if Worker.Success then
    begin FPlan := Worker.TakePlan; FReport.Lines.Assign(FPlan.Report); FApply.Enabled := True; end
    else FReport.Lines.Text := Worker.Error;
  finally Worker.Free; end;
end;

procedure TfrmCatalogSources.Apply(Sender: TObject);
var Worker: TCatalogMergeWorker; Backup: string;
begin
  if Assigned(FSeriesPlan) then begin ApplySeriesAliases; Exit; end;
  if not Assigned(FPlan) then Exit;
  Backup := TPath.Combine(Settings.DataPath,'Backups\merge-' + FormatDateTime('yyyymmdd-hhnnss',Now) + '-' + TCatalogSource.NewID);
  Worker := TCatalogMergeWorker.CreateApply(FPlan, Backup);
  try
    RunWorker(Worker,'Объединение коллекции');
    if FileExists(TPath.Combine(Backup,'preview.txt')) then FLastReportFile := TPath.Combine(Backup,'preview.txt');
    if Worker.Success then
    begin
      FChanged := True; FReport.Lines.Add(''); FReport.Lines.Add('Объединение завершено.');
      FReport.Lines.Add('Резервные копии и отчёт: ' + Backup);
    end
    else FReport.Lines.Add(Worker.Error + #13#10 + 'Папка операции: ' + Backup);
  finally Worker.Free; InvalidatePreview; end;
end;

procedure TfrmCatalogSources.PreviewSeriesAliases(Sender: TObject);
var Worker: TSeriesAliasWorker;
begin
  InvalidatePreview; Worker := TSeriesAliasWorker.CreatePreview(FTarget.CollectionID);
  try
    RunWorker(Worker,'Дубли названий серий');
    if Worker.Success then
    begin
      FSeriesPlan := Worker.TakePlan; FReport.Lines.Assign(FSeriesPlan.Report);
      FApply.Caption := 'Объединить серии'; FApply.Enabled := FSeriesPlan.Count > 0;
    end
    else FReport.Lines.Text := Worker.Error;
  finally Worker.Free; end;
end;

procedure TfrmCatalogSources.ApplySeriesAliases;
var Worker: TSeriesAliasWorker; Backup: string;
begin
  Backup := TPath.Combine(Settings.DataPath,'Backups\series-' +
    FormatDateTime('yyyymmdd-hhnnss',Now) + '-' + TCatalogSource.NewID);
  Worker := TSeriesAliasWorker.CreateApply(FSeriesPlan,Backup);
  try
    RunWorker(Worker,'Объединение названий серий');
    FLastReportFile := TPath.Combine(Backup,'series.txt');
    if Worker.Success then
    begin FChanged := True; FReport.Lines.Add('Серии объединены. Резервные копии и полный отчёт: '+Backup); end
    else FReport.Lines.Add(Worker.Error+#13#10+'Папка операции: '+Backup);
  finally Worker.Free; InvalidatePreview; end;
end;

procedure TfrmCatalogSources.PolicyChanged(Sender: TObject);
const Names: array[0..3] of string = ('','flibusta','librusec','mixed');
begin
  InvalidatePreview;
  if Sender = FTargetLibrary then FTarget.SetProperty(PROP_SOURCE_LIBRARY, Names[FTargetLibrary.ItemIndex]);
  UpdatePolicyHelp;
  FReport.Lines.Text := 'Режим изменён. Выполните новый предпросмотр. Для объединения ID укажите исходную библиотеку каждого источника кнопкой «Библиотека источника…». ' +
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
    InvalidatePreview; FSources[Index].LibraryNamespace := Names[Choice.ItemIndex]; Save; RebuildList(Index);
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
      else if Assigned(FSeriesPlan) then FReport.Lines.SaveToFile(Dialog.FileName,TEncoding.UTF8)
      else if FileExists(FLastReportFile) then TFile.Copy(FLastReportFile,Dialog.FileName,True)
      else FReport.Lines.SaveToFile(Dialog.FileName,TEncoding.UTF8);
  finally Dialog.Free; end;
end;

end.
