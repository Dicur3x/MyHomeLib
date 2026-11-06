{ HomeLibre. Original project copyright (C) 2008-2026 Oleksiy Penkov. }
unit frm_OPDS;

interface

uses
  System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, unit_Globals, unit_OPDSServer;

type
  TfrmOPDS = class(TForm)
  private
    FServer: THomeLibOPDSServer;
    FCollection: TCollectionInfo;
    FCollectionLabel, FStatus, FPublicLabel, FCertLabel, FKeyLabel, FAddressLabel: TLabel;
    FPort, FAddress, FPublicBase, FHostname, FCertificate, FPrivateKey: TEdit;
    FHosts, FMode: TComboBox;
    FLAN: TCheckBox;
    FStart, FStop, FCopy, FHide, FCertButton, FKeyButton: TButton;
    FMonitor: TTimer;
    FOnNeedTlsComponent: TNotifyEvent;
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure HostChange(Sender: TObject);
    procedure HideClick(Sender: TObject);
    procedure ChoosePEM(Sender: TObject);
    procedure CheckTransport(Sender: TObject);
    procedure RefreshControls;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetCollection(const Collection: TCollectionInfo);
    procedure StopServer;
    property OnNeedTlsComponent: TNotifyEvent read FOnNeedTlsComponent write FOnNeedTlsComponent;
  end;

implementation

uses
  Winapi.Windows, System.SysUtils, System.StrUtils, System.IOUtils, Vcl.Controls, Vcl.Dialogs, Vcl.Clipbrd,
  IdStack, IdGlobal, dm_user, unit_FormatComponents, unit_ComponentUsage;

const
  MODE_HTTP = 0;
  MODE_PROXY = 1;
  MODE_TLS = 2;

constructor TfrmOPDS.Create(AOwner: TComponent);
var
  TextLabel: TLabel;
  Addresses: TIdStackLocalAddressList;
  I: Integer;
begin
  inherited CreateNew(AOwner);
  Caption := 'Каталог для читалки (OPDS)';
  BorderStyle := bsDialog;
  Position := poMainFormCenter;
  ClientWidth := 690;
  ClientHeight := 372;
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
    'Компьютер и HomeLibre должны оставаться включёнными.';
  FLAN := TCheckBox.Create(Self);
  FLAN.Parent := Self;
  FLAN.SetBounds(16, 91, 301, 24);
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
  TextLabel.Caption := 'Подключение:';
  FMode := TComboBox.Create(Self);
  FMode.Parent := Self;
  FMode.SetBounds(324, 124, 347, 26);
  FMode.Style := csDropDownList;
  FMode.Items.Add('Обычный HTTP');
  FMode.Items.Add('Внешний HTTPS-сервер');
  FMode.Items.Add('HTTPS с сертификатом');
  FMode.ItemIndex := MODE_HTTP;
  FMode.OnChange := HostChange;
  FHosts := TComboBox.Create(Self);
  FHosts.Parent := Self;
  FHosts.SetBounds(324, 90, 347, 26);
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
  FPublicLabel := TLabel.Create(Self);
  FPublicLabel.Parent := Self;
  FPublicLabel.SetBounds(16, 166, 655, 20);
  FPublicBase := TEdit.Create(Self);
  FPublicBase.Parent := Self;
  FPublicBase.SetBounds(16, 188, 655, 26);
  FPublicBase.TextHint := 'https://books.example.org/library';
  FHostname := TEdit.Create(Self);
  FHostname.Parent := Self;
  FHostname.SetBounds(16, 188, 655, 26);
  FHostname.Text := 'localhost';
  FCertLabel := TLabel.Create(Self);
  FCertLabel.Parent := Self;
  FCertLabel.SetBounds(16, 223, 655, 20);
  FCertLabel.Caption := 'Сертификат и цепочка (PEM):';
  FCertificate := TEdit.Create(Self);
  FCertificate.Parent := Self;
  FCertificate.SetBounds(16, 245, 524, 26);
  FCertButton := TButton.Create(Self);
  FCertButton.Parent := Self;
  FCertButton.SetBounds(551, 244, 120, 27);
  FCertButton.Caption := 'Выбрать…';
  FCertButton.OnClick := ChoosePEM;
  FKeyLabel := TLabel.Create(Self);
  FKeyLabel.Parent := Self;
  FKeyLabel.SetBounds(16, 280, 655, 20);
  FKeyLabel.Caption := 'Закрытый ключ (PEM):';
  FPrivateKey := TEdit.Create(Self);
  FPrivateKey.Parent := Self;
  FPrivateKey.SetBounds(16, 302, 524, 26);
  FKeyButton := TButton.Create(Self);
  FKeyButton.Parent := Self;
  FKeyButton.SetBounds(551, 301, 120, 27);
  FKeyButton.Caption := 'Выбрать…';
  FKeyButton.OnClick := ChoosePEM;
  FAddressLabel := TLabel.Create(Self);
  FAddressLabel.Parent := Self;
  FAddressLabel.Caption := 'Адрес каталога для читалки:';
  FAddress := TEdit.Create(Self);
  FAddress.Parent := Self;
  FAddress.SetBounds(16, 247, 655, 26);
  FAddress.ReadOnly := True;
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.SetBounds(16, 286, 655, 20);
  FStatus.AutoSize := False;
  FStart := TButton.Create(Self);
  FStart.Parent := Self;
  FStart.SetBounds(16, 323, 115, 30);
  FStart.Caption := 'Запустить';
  FStart.OnClick := StartClick;
  FStop := TButton.Create(Self);
  FStop.Parent := Self;
  FStop.SetBounds(140, 323, 115, 30);
  FStop.Caption := 'Остановить';
  FStop.OnClick := StopClick;
  FCopy := TButton.Create(Self);
  FCopy.Parent := Self;
  FCopy.SetBounds(265, 323, 175, 30);
  FCopy.Caption := 'Копировать адрес';
  FCopy.OnClick := CopyClick;
  FHide := TButton.Create(Self);
  FHide.Parent := Self;
  FHide.SetBounds(556, 323, 115, 30);
  FHide.Caption := 'Скрыть';
  FHide.Cancel := True;
  FHide.OnClick := HideClick;
  FMonitor := TTimer.Create(Self);
  FMonitor.Enabled := False;
  FMonitor.Interval := 1000;
  FMonitor.OnTimer := CheckTransport;
  RefreshControls;
end;

destructor TfrmOPDS.Destroy;
begin
  if Assigned(FMonitor) then FMonitor.Enabled := False;
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
var Running, UseTLS, UseProxy: Boolean; Base: Integer;
begin
  Running := FServer.Active;
  UseTLS := FMode.ItemIndex = MODE_TLS;
  UseProxy := FMode.ItemIndex = MODE_PROXY;
  FStart.Enabled := not Running;
  FStop.Enabled := Running;
  FCopy.Enabled := Running;
  FPort.Enabled := not Running;
  FMode.Enabled := not Running;
  FLAN.Enabled := not Running and not UseProxy;
  FHosts.Enabled := FLAN.Checked and (FMode.ItemIndex = MODE_HTTP);
  FPublicLabel.Visible := UseTLS or UseProxy;
  if UseTLS then FPublicLabel.Caption := 'Имя компьютера или IPv4-адрес из сертификата:'
  else FPublicLabel.Caption := 'Адрес внешнего HTTPS-сервера:';
  FPublicBase.Visible := UseProxy;
  FHostname.Visible := UseTLS;
  FPublicBase.Enabled := not Running;
  FHostname.Enabled := not Running;
  for var Control in TArray<TControl>.Create(FCertLabel, FKeyLabel, FCertificate, FPrivateKey,
    FCertButton, FKeyButton) do
  begin
    Control.Visible := UseTLS;
    Control.Enabled := not Running;
  end;
  if UseTLS then Base := 340
  else if UseProxy then Base := 223
  else Base := 166;
  Base := MulDiv(Base, CurrentPPI, 96);
  FAddressLabel.Left := FAddress.Left;
  FAddressLabel.Top := Base;
  FAddress.Top := Base + MulDiv(24, CurrentPPI, 96);
  FStatus.Top := Base + MulDiv(63, CurrentPPI, 96);
  for var Button in TArray<TButton>.Create(FStart, FStop, FCopy, FHide) do
    Button.Top := Base + MulDiv(100, CurrentPPI, 96);
  ClientHeight := Base + MulDiv(149, CurrentPPI, 96);
  FMonitor.Enabled := Running and UseTLS;
  if Running then
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
  Tool: string;
begin
  try
    if not TryStrToInt(FPort.Text, Port) then
      raise Exception.Create('Укажите числовой порт от 1024 до 65535.');
    case FMode.ItemIndex of
      MODE_PROXY:
        begin
          if Trim(FPublicBase.Text) = '' then raise EArgumentException.Create('Укажите адрес внешнего HTTPS-сервера.');
          FServer.Start(FCollection, Port, False, FPublicBase.Text);
        end;
      MODE_TLS:
        begin
          if (Trim(FCertificate.Text) = '') or (Trim(FPrivateKey.Text) = '') then
            raise EArgumentException.Create('Выберите сертификат и закрытый ключ.');
          if FormatComponentVersion(Settings.AppPath, 'OPDSTls') = '' then
          begin
            if Assigned(FOnNeedTlsComponent) then FOnNeedTlsComponent(Self);
            Exit;
          end;
          Tool := TPath.Combine(Settings.AppPath, FormatComponentFile('OPDSTls'));
          FServer.StartHTTPS(FCollection, Port, FLAN.Checked, FHostname.Text,
            TPath.GetFullPath(Trim(FCertificate.Text)), TPath.GetFullPath(Trim(FPrivateKey.Text)), Tool);
          RecordComponentUse('OPDSTls');
        end;
    else
      FServer.Start(FCollection, Port, FLAN.Checked);
    end;
    RefreshControls;
  except
    on E: Exception do
      MessageDlg('Не удалось запустить каталог.' + sLineBreak + E.Message,
        mtError, [mbOK], 0);
  end;
end;

procedure TfrmOPDS.ChoosePEM(Sender: TObject);
var Dialog: TOpenDialog; Field: TEdit;
begin
  if Sender = FCertButton then Field := FCertificate else Field := FPrivateKey;
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'Файлы PEM (*.pem;*.crt;*.key)|*.pem;*.crt;*.key|Все файлы (*.*)|*.*';
    Dialog.Options := [ofFileMustExist, ofPathMustExist, ofEnableSizing];
    Dialog.FileName := Field.Text;
    if Dialog.Execute then Field.Text := Dialog.FileName;
  finally
    Dialog.Free;
  end;
end;

procedure TfrmOPDS.CheckTransport(Sender: TObject);
begin
  if FServer.Active then Exit;
  StopServer;
  FStatus.Caption := 'Модуль HTTPS завершился. Запустите каталог повторно.';
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
