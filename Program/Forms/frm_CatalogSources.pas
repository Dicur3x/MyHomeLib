unit frm_CatalogSources;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  unit_Interfaces, unit_CatalogSources, unit_CollectionMerge, unit_WorkerThread;

type
  TfrmCatalogSources = class(TForm)
  private
    FTarget: IBookCollection;
    FSources: TCatalogSources;
    FPlan: TCollectionMergePlan;
    FList: TListView;
    FReport: TMemo;
    FApply, FRefresh, FRoot, FIndexFile: TButton;
    FChanged: Boolean;
    FLastReportFile: string;
    function Button(ParentPanel: TPanel; const Caption: string; Left, Width: Integer;
      Handler: TNotifyEvent): TButton;
    procedure InvalidatePreview;
    procedure RebuildList(Index: Integer);
    procedure AddINPX(Sender: TObject);
    procedure AddCollection(Sender: TObject);
    procedure MoveSource(Sender: TObject);
    procedure DisconnectSource(Sender: TObject);
    procedure ChooseRoot(Sender: TObject);
    procedure ChooseIndexFile(Sender: TObject);
    procedure RefreshSource(Sender: TObject);
    procedure Preview(Sender: TObject);
    procedure Apply(Sender: TObject);
    procedure SaveReport(Sender: TObject);
    procedure Selected(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure RunWorker(Worker: TWorker; const Caption: string);
    procedure Save;
  public
    constructor CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
    destructor Destroy; override;
    property CatalogChanged: Boolean read FChanged;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Variants, Vcl.Controls, Vcl.Graphics,
  Vcl.Dialogs, Vcl.FileCtrl, unit_Consts, unit_Settings, unit_Globals,
  frm_ImportProgressFormEx, dm_user;

constructor TfrmCatalogSources.CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
var Panel: TPanel; LabelText: TLabel; B: TButton;
begin
  inherited CreateNew(AOwner);
  FTarget := Collection; FSources := LoadCatalogSources(FTarget);
  Caption := 'Источники коллекции — ' + FTarget.CollectionDisplayName;
  Font.Name := 'Segoe UI'; Font.Size := 9; Position := poOwnerFormCenter;
  BorderStyle := bsSizeable; ClientWidth := 820; ClientHeight := 650;
  Constraints.MinWidth := 836; Constraints.MinHeight := 540;
  Panel := TPanel.Create(Self); Panel.Parent := Self; Panel.SetBounds(0,0,ClientWidth,54); Panel.Align := alTop;
  Panel.Height := 54; Panel.BevelOuter := bvNone;
  LabelText := TLabel.Create(Self); LabelText.Parent := Panel; LabelText.AutoSize := False;
  LabelText.SetBounds(12,8,796,42); LabelText.Anchors := [akLeft,akTop,akRight];
  LabelText.WordWrap := True;
  LabelText.Caption := 'Приоритет источников — сверху вниз. Сначала обновите нужный INPX, затем выполните предпросмотр.' + #13#10 +
    'Применение сохраняет резервные копии каталогов и групп. Исходные книги и названия серий не изменяются.';
  FList := TListView.Create(Self); FList.Parent := Self; FList.SetBounds(0,54,ClientWidth,176); FList.Align := alTop;
  FList.Height := 176; FList.ViewStyle := vsReport; FList.ReadOnly := True;
  FList.RowSelect := True; FList.HideSelection := False; FList.DoubleBuffered := True;
  FList.Columns.Add.Caption := 'Источник'; FList.Columns[0].Width := 220;
  FList.Columns.Add.Caption := 'Папка книг'; FList.Columns[1].Width := 220;
  FList.Columns.Add.Caption := 'Индекс / каталог'; FList.Columns[2].Width := 340;
  FList.OnSelectItem := Selected;
  Panel := TPanel.Create(Self); Panel.Parent := Self; Panel.SetBounds(0,230,ClientWidth,78); Panel.Align := alTop;
  Panel.Height := 78; Panel.BevelOuter := bvNone;
  Button(Panel,'Добавить INPX...',12,148,AddINPX);
  Button(Panel,'Добавить коллекцию...',166,178,AddCollection);
  B := Button(Panel,'Выше',350,68,MoveSource); B.Tag := -1;
  B := Button(Panel,'Ниже',424,68,MoveSource); B.Tag := 1;
  Button(Panel,'Отключить источник',498,158,DisconnectSource);
  FIndexFile := Button(Panel,'Файл INPX...',662,146,ChooseIndexFile);
  FRoot := Button(Panel,'Папка книг...',12,148,ChooseRoot); FRoot.Top := 44;
  FRefresh := Button(Panel,'Обновить выбранный INPX',166,226,RefreshSource); FRefresh.Top := 44;
  B := Button(Panel,'Предпросмотр объединения',398,258,Preview); B.Top := 44;
  Panel := TPanel.Create(Self); Panel.Parent := Self; Panel.Align := alBottom;
  Panel.Height := 48; Panel.BevelOuter := bvNone;
  FApply := Button(Panel,'Применить объединение',12,216,Apply); FApply.Enabled := False;
  Button(Panel,'Сохранить отчёт...',234,158,SaveReport);
  B := Button(Panel,'Закрыть',708,100,nil); B.Anchors := [akTop,akRight]; B.ModalResult := mrClose; B.Cancel := True;
  FReport := TMemo.Create(Self); FReport.Parent := Self; FReport.Align := alClient;
  FReport.AlignWithMargins := True; FReport.Margins.Left := 12; FReport.Margins.Right := 12;
  FReport.ReadOnly := True; FReport.ScrollBars := ssBoth; FReport.WordWrap := False;
  FReport.Lines.Text := 'Добавьте локальную коллекцию или несколько INPX с разными папками книг.' + #13#10 +
    'Каждый INPX обновляется отдельно. Совпадение книг определяется по файлу, а не по числовому LIBID.' + #13#10 +
    'Отключение источника и исчезновение книги из нового INPX не удаляют уже добавленные книги.';
  RebuildList(0);
end;

destructor TfrmCatalogSources.Destroy;
begin FPlan.Free; inherited; end;

function TfrmCatalogSources.Button(ParentPanel: TPanel; const Caption: string; Left, Width: Integer;
  Handler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self); Result.Parent := ParentPanel;
  Result.Caption := Caption; Result.SetBounds(Left,8,Width,28); Result.OnClick := Handler;
end;

procedure TfrmCatalogSources.InvalidatePreview;
begin FreeAndNil(FPlan); FApply.Enabled := False; end;

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
    end;
    if (Index >= 0) and (Index < FList.Items.Count) then FList.Items[Index].Selected := True;
  finally FList.Items.EndUpdate; end;
  FRefresh.Enabled := Assigned(FList.Selected) and FSources[FList.ItemIndex].IsINPX;
  FRoot.Enabled := FRefresh.Enabled; FIndexFile.Enabled := FRefresh.Enabled;
end;

procedure TfrmCatalogSources.Selected(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if Selected then
  begin FRefresh.Enabled := FSources[Item.Index].IsINPX; FRoot.Enabled := FRefresh.Enabled; FIndexFile.Enabled := FRefresh.Enabled; end;
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
var Index, I: Integer;
begin
  Index := FList.ItemIndex; if Index < 0 then Exit;
  InvalidatePreview;
  for I := Index to High(FSources)-1 do FSources[I] := FSources[I+1];
  SetLength(FSources,Length(FSources)-1); Save; RebuildList(Index);
  FReport.Lines.Text := 'Источник отключён. Уже добавленные книги сохранены.';
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
  finally Worker.Free; end;
end;

procedure TfrmCatalogSources.Preview(Sender: TObject);
var Worker: TCatalogMergeWorker;
begin
  InvalidatePreview; FLastReportFile := ''; Worker := TCatalogMergeWorker.CreatePreview(FTarget.CollectionID, FSources);
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
