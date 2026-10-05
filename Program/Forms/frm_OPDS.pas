{ HomeLib Ru. Original project copyright (C) 2008-2026 Oleksiy Penkov. }
unit frm_OPDS;

interface

uses
  System.Classes, Vcl.Forms, Vcl.StdCtrls, unit_Globals, unit_OPDSServer;

type
  TfrmOPDS = class(TForm)
  private
    FServer: THomeLibOPDSServer;
    FCollection: TCollectionInfo;
    FCollectionLabel, FStatus: TLabel;
    FPort, FAddress: TEdit;
    FHosts: TComboBox;
    FLAN: TCheckBox;
    FStart, FStop, FCopy: TButton;
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure HostChange(Sender: TObject);
    procedure HideClick(Sender: TObject);
    procedure RefreshControls;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetCollection(const Collection: TCollectionInfo);
    procedure StopServer;
  end;

implementation

uses
  System.SysUtils, System.StrUtils, Vcl.Controls, Vcl.Dialogs, Vcl.Clipbrd,
  IdStack, IdGlobal;

constructor TfrmOPDS.Create(AOwner: TComponent);
var
  TextLabel: TLabel;
  CloseButton: TButton;
  Addresses: TIdStackLocalAddressList;
  I: Integer;
begin
  inherited CreateNew(AOwner);
  Caption := 'Каталог для читалки (OPDS)';
  BorderStyle := bsDialog;
  Position := poMainFormCenter;
  ClientWidth := 690;
  ClientHeight := 315;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  FServer := THomeLibOPDSServer.Create;
  FCollectionLabel := TLabel.Create(Self);
  FCollectionLabel.Parent := Self;
  FCollectionLabel.SetBounds(16, 16, 655, 22);
  FCollectionLabel.AutoSize := False;
  TextLabel := TLabel.Create(Self);
  TextLabel.Parent := Self;
  TextLabel.SetBounds(16, 43, 655, 45);
  TextLabel.AutoSize := False;
  TextLabel.WordWrap := True;
  TextLabel.Caption := 'Добавьте адрес каталога в читалку, чтобы искать и скачивать книги. ' +
    'Компьютер и HomeLib Ru должны оставаться включёнными.';
  FLAN := TCheckBox.Create(Self);
  FLAN.Parent := Self;
  FLAN.SetBounds(16, 91, 490, 24);
  FLAN.Caption := 'Доступ с устройств домашней сети';
  FLAN.OnClick := HostChange;
  TextLabel := TLabel.Create(Self);
  TextLabel.Parent := Self;
  TextLabel.SetBounds(16, 128, 60, 20);
  TextLabel.Caption := 'Порт:';
  FPort := TEdit.Create(Self);
  FPort.Parent := Self;
  FPort.SetBounds(75, 124, 75, 26);
  FPort.Text := '8090';
  TextLabel := TLabel.Create(Self);
  TextLabel.Parent := Self;
  TextLabel.SetBounds(175, 128, 145, 20);
  TextLabel.Caption := 'Адрес компьютера:';
  FHosts := TComboBox.Create(Self);
  FHosts.Parent := Self;
  FHosts.SetBounds(324, 124, 190, 26);
  FHosts.Style := csDropDownList;
  FHosts.Items.Add('127.0.0.1');
  Addresses := TIdStackLocalAddressList.Create;
  try
    GStack.GetLocalAddressList(Addresses);
    for I := 0 to Addresses.Count - 1 do
      if (Addresses[I].IPVersion = Id_IPv4) and
        not StartsStr('127.', Addresses[I].IPAddress) and
        (FHosts.Items.IndexOf(Addresses[I].IPAddress) < 0) then
        FHosts.Items.Add(Addresses[I].IPAddress);
  finally
    Addresses.Free;
  end;
  FHosts.ItemIndex := 0;
  FHosts.OnChange := HostChange;
  TextLabel := TLabel.Create(Self);
  TextLabel.Parent := Self;
  TextLabel.SetBounds(16, 166, 655, 20);
  TextLabel.Caption := 'Адрес каталога для читалки:';
  FAddress := TEdit.Create(Self);
  FAddress.Parent := Self;
  FAddress.SetBounds(16, 190, 655, 26);
  FAddress.ReadOnly := True;
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.SetBounds(16, 229, 655, 20);
  FStatus.AutoSize := False;
  FStart := TButton.Create(Self);
  FStart.Parent := Self;
  FStart.SetBounds(16, 266, 115, 30);
  FStart.Caption := 'Запустить';
  FStart.OnClick := StartClick;
  FStop := TButton.Create(Self);
  FStop.Parent := Self;
  FStop.SetBounds(140, 266, 115, 30);
  FStop.Caption := 'Остановить';
  FStop.OnClick := StopClick;
  FCopy := TButton.Create(Self);
  FCopy.Parent := Self;
  FCopy.SetBounds(265, 266, 175, 30);
  FCopy.Caption := 'Копировать адрес';
  FCopy.OnClick := CopyClick;
  CloseButton := TButton.Create(Self);
  CloseButton.Parent := Self;
  CloseButton.SetBounds(556, 266, 115, 30);
  CloseButton.Caption := 'Скрыть';
  CloseButton.Cancel := True;
  CloseButton.OnClick := HideClick;
  RefreshControls;
end;

destructor TfrmOPDS.Destroy;
begin
  FServer.Free;
  inherited Destroy;
end;

procedure TfrmOPDS.SetCollection(const Collection: TCollectionInfo);
begin
  if FServer.Active then Exit;
  FCollection := Collection;
  FCollectionLabel.Caption := 'Коллекция: ' + FCollection.DisplayName;
end;

procedure TfrmOPDS.RefreshControls;
begin
  FStart.Enabled := not FServer.Active;
  FStop.Enabled := FServer.Active;
  FCopy.Enabled := FServer.Active;
  FPort.Enabled := not FServer.Active;
  FLAN.Enabled := not FServer.Active;
  FHosts.Enabled := FLAN.Checked;
  if FServer.Active then
  begin
    FAddress.Text := FServer.CatalogURL(FHosts.Text);
    FStatus.Caption := 'Каталог работает. Кнопка «Скрыть» оставляет его включённым.';
  end
  else
  begin
    FAddress.Clear;
    FStatus.Caption := 'Каталог остановлен.';
  end;
end;

procedure TfrmOPDS.StartClick(Sender: TObject);
var
  Port: Integer;
begin
  try
    if not TryStrToInt(FPort.Text, Port) then
      raise Exception.Create('Укажите числовой порт от 1024 до 65535.');
    FServer.Start(FCollection, Port, FLAN.Checked);
    RefreshControls;
  except
    on E: Exception do
      MessageDlg('Не удалось запустить каталог.' + sLineBreak + E.Message,
        mtError, [mbOK], 0);
  end;
end;

procedure TfrmOPDS.StopServer;
begin
  FServer.Stop;
  RefreshControls;
end;

procedure TfrmOPDS.StopClick(Sender: TObject);
begin
  StopServer;
end;

procedure TfrmOPDS.CopyClick(Sender: TObject);
begin
  if FServer.Active then Clipboard.AsText := FAddress.Text;
end;

procedure TfrmOPDS.HostChange(Sender: TObject);
begin
  if not FLAN.Checked then FHosts.ItemIndex := 0
  else if (FHosts.ItemIndex = 0) and (FHosts.Items.Count > 1) then FHosts.ItemIndex := 1;
  RefreshControls;
end;

procedure TfrmOPDS.HideClick(Sender: TObject);
begin
  Hide;
end;

end.
