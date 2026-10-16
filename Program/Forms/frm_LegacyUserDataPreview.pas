unit frm_LegacyUserDataPreview;

interface

uses System.Classes, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls,
  Vcl.ComCtrls, unit_LegacyUserDataPreview, unit_UserData, unit_Interfaces;

type
  TfrmLegacyUserDataPreview = class(TForm)
  private
    FPreview: TLegacyUserDataPreview;
    FList: TListView;
    FTarget: TComboBox;
    FImport: TButton;
    FSummary, FInstruction: TLabel;
    FLoading: Boolean;
    procedure ListData(Sender: TObject; Item: TListItem);
    procedure ListSelected(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure TargetChanged(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure LayoutColumns(Sender: TObject);
  public
    constructor CreatePreview(AOwner: TComponent; Preview: TLegacyUserDataPreview;
      const SystemData: ISystemData);
    property MappingList: TListView read FList;
    property TargetEdit: TComboBox read FTarget;
    property ImportButton: TButton read FImport;
    property Summary: TLabel read FSummary;
  end;

function ShowLegacyUserDataImportPreview(const FileName: string; var Data: TUserData;
  const SystemData: ISystemData; Owner: TComponent = nil): Boolean;

implementation

uses System.SysUtils, Winapi.Windows, unit_Globals, unit_MHLTheme, unit_Errors;

constructor TfrmLegacyUserDataPreview.CreatePreview(AOwner: TComponent;
  Preview: TLegacyUserDataPreview; const SystemData: ISystemData);
var
  Buttons, Editor: TPanel;
  Cancel: TButton;
  LabelText: TLabel;
  Names: TStringList;
  Groups: IGroupIterator;
  Group: TGroupData;
begin
  inherited CreateNew(AOwner);
  Name := 'LegacyUserDataPreview';
  Caption := 'Предпросмотр переноса личных данных';
  Position := poOwnerFormCenter;
  BorderStyle := bsSizeable;
  Font.Name := 'Segoe UI'; Font.Size := 9;
  ClientWidth := 720; ClientHeight := 560;
  Constraints.MinWidth := 520; Constraints.MinHeight := 440;
  Padding.Left := 12; Padding.Right := 12; Padding.Top := 12;
  FPreview := Preview;
  FSummary := TLabel.Create(Self);
  FSummary.Parent := Self; FSummary.Align := alTop;
  FSummary.WordWrap := True; FSummary.AutoSize := True;
  FSummary.Caption := Format('Оценок: %d. Отметок прогресса: %d. Отзывов: %d.' + sLineBreak +
    'Групп в файле: %d. Записей в группах: %d. Требуют выбора: %d.',
    [Preview.RatingCount, Preview.ProgressCount, Preview.ReviewCount,
     Preview.GroupCount, Preview.GroupBookCount, Preview.MappingCount]);
  FSummary.Hint := Preview.FileName; FSummary.ShowHint := True;
  FInstruction := TLabel.Create(Self);
  FInstruction.Parent := Self; FInstruction.Align := alTop;
  FInstruction.WordWrap := True; FInstruction.AutoSize := True;
  FInstruction.Caption := 'Данные добавятся или обновятся в выбранной коллекции. ' +
    'Нулевые оценки/прогресс и пустые отзывы сохранят прежние значения. ' +
    'Для каждой неоднозначной группы выберите строку и укажите существующую или новую группу ниже. ' +
    'До нажатия «Импортировать» библиотека не меняется.';
  Buttons := TPanel.Create(Self);
  Buttons.Parent := Self; Buttons.Align := alBottom; Buttons.Height := 52;
  Buttons.BevelOuter := bvNone;
  Cancel := TButton.Create(Self);
  Cancel.Parent := Buttons; Cancel.Align := alRight; Cancel.Width := 110;
  Cancel.AlignWithMargins := True; Cancel.Margins.Top := 10; Cancel.Margins.Bottom := 10;
  Cancel.Caption := 'Отмена'; Cancel.Cancel := True; Cancel.ModalResult := mrCancel;
  FImport := TButton.Create(Self);
  FImport.Name := 'LegacyImportConfirm';
  FImport.Parent := Buttons; FImport.Align := alRight; FImport.Width := 140;
  FImport.AlignWithMargins := True; FImport.Margins.Top := 10; FImport.Margins.Bottom := 10;
  FImport.Caption := 'Импортировать'; FImport.Default := True; FImport.OnClick := ImportClick;
  FImport.Enabled := Preview.Ready;
  Editor := TPanel.Create(Self);
  Editor.Parent := Self; Editor.Align := alBottom; Editor.Height := 76; Editor.BevelOuter := bvNone;
  LabelText := TLabel.Create(Self); LabelText.Parent := Editor; LabelText.Align := alTop;
  LabelText.Caption := 'Импортировать выбранную строку в группу (можно ввести новое название):';
  LabelText.AutoSize := False; LabelText.Height := 36; LabelText.WordWrap := True;
  FTarget := TComboBox.Create(Self); FTarget.Name := 'LegacyImportGroupTarget';
  FTarget.Parent := Editor; FTarget.Align := alTop; FTarget.Style := csDropDown;
  FTarget.ItemIndex := -1; FTarget.Text := ''; FTarget.Enabled := False;
  FTarget.Hint := 'Выберите строку в списке, затем выберите или введите название группы.';
  FTarget.ShowHint := True;
  Names := TStringList.Create;
  try
    Names.Sorted := True; Names.Duplicates := dupIgnore; Names.CaseSensitive := True;
    Preview.GetGroupNames(Names);
    if Assigned(SystemData) then
    begin
      Groups := SystemData.GetGroupIterator;
      while Groups.Next(Group) do Names.Add(Group.Text);
    end;
    FTarget.Items.Assign(Names);
  finally Names.Free; end;
  // VCL may initialize editable text from the component Name. An unselected
  // mapping must show no invented target, including after filling its items.
  FTarget.ItemIndex := -1; FTarget.Text := '';
  FTarget.OnChange := TargetChanged;
  FList := TListView.Create(Self); FList.Name := 'LegacyImportGroupMappings';
  FList.Parent := Self; FList.Align := alClient; FList.ViewStyle := vsReport;
  FList.ReadOnly := True; FList.RowSelect := True; FList.HideSelection := False;
  FList.OwnerData := True; FList.OnData := ListData; FList.OnSelectItem := ListSelected;
  FList.Columns.Add.Caption := 'Группа в файле';
  FList.Columns.Add.Caption := 'Книг';
  FList.Columns.Add.Caption := 'Импортировать в';
  FList.Items.Count := Preview.MappingCount;
  FList.OnResize := LayoutColumns;
  if Preview.MappingCount = 0 then
    FInstruction.Caption := FInstruction.Caption + sLineBreak + 'Неоднозначных групп нет. Можно выполнить перенос.';
  if Screen.PixelsPerInch <> PixelsPerInch then ScaleForPPI(Screen.PixelsPerInch);
  LayoutColumns(nil);
  ApplyMHLControlTheme(Self);
end;

procedure TfrmLegacyUserDataPreview.LayoutColumns(Sender: TObject);
var UnitWidth: Integer;
begin
  if not Assigned(FList) or (FList.Columns.Count <> 3) then Exit;
  UnitWidth := MulDiv(70, CurrentPPI, 96);
  FList.Columns[0].Width := (FList.ClientWidth - UnitWidth - MulDiv(24, CurrentPPI, 96)) div 2;
  FList.Columns[1].Width := UnitWidth;
  FList.Columns[2].Width := FList.Columns[0].Width;
end;

procedure TfrmLegacyUserDataPreview.ListData(Sender: TObject; Item: TListItem);
var Mapping: TLegacyGroupMapping;
begin
  if (Item.Index < 0) or (Item.Index >= FPreview.MappingCount) then Exit;
  Mapping := FPreview.Mappings[Item.Index];
  Item.Caption := Mapping.DisplayName;
  Item.SubItems.Clear;
  Item.SubItems.Add(IntToStr(Mapping.BookIDs.Count));
  if Mapping.TargetName = '' then Item.SubItems.Add('Выберите группу')
  else Item.SubItems.Add(Mapping.TargetName);
end;

procedure TfrmLegacyUserDataPreview.ListSelected(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if not Selected then Exit;
  FLoading := True;
  try FTarget.Text := FPreview.Mappings[Item.Index].TargetName;
  finally FLoading := False; end;
  FTarget.Enabled := True;
end;

procedure TfrmLegacyUserDataPreview.TargetChanged(Sender: TObject);
begin
  if FLoading or not Assigned(FList) or not Assigned(FList.Selected) then Exit;
  FPreview.SetTarget(FList.Selected.Index, FTarget.Text);
  FList.Invalidate;
  FImport.Enabled := FPreview.Ready;
end;

procedure TfrmLegacyUserDataPreview.ImportClick(Sender: TObject);
begin
  if not FPreview.Ready then Exit;
  try
    FPreview.ValidateSource;
    ModalResult := mrOk;
  except on E: Exception do MHLShowError(E.Message); end;
end;

function ShowLegacyUserDataImportPreview(const FileName: string; var Data: TUserData;
  const SystemData: ISystemData; Owner: TComponent = nil): Boolean;
var Preview: TLegacyUserDataPreview; Dialog: TfrmLegacyUserDataPreview;
begin
  Result := False;
  Preview := TLegacyUserDataPreview.Create(FileName);
  try
    Dialog := TfrmLegacyUserDataPreview.CreatePreview(Owner, Preview, SystemData);
    try
      if Dialog.ShowModal <> mrOk then Exit;
      Preview.AppendTo(Data);
      Result := True;
    finally Dialog.Free; end;
  finally Preview.Free; end;
end;

end.
