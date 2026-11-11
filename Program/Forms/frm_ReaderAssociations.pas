unit frm_ReaderAssociations;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, unit_ReaderAssociations;

type TReaderAssociationsForm = class(TForm)
  private
    FGroups:array[TReaderAssociationGroup] of TCheckBox;
    FStatus:TLabel;
    FRemove:TButton;
    procedure SelectAll(Sender:TObject);
    procedure RegisterAndChoose(Sender:TObject);
    procedure RemoveRegistration(Sender:TObject);
  public
    constructor Create(AOwner:TComponent); override;
  end;

implementation

uses Winapi.Windows, Winapi.ShellAPI, System.SysUtils, Vcl.Controls, Vcl.Dialogs, Vcl.ExtCtrls;

constructor TReaderAssociationsForm.Create(AOwner:TComponent);
const Captions:array[TReaderAssociationGroup] of string =
  ('Книги, PDF и комиксы','Текстовые и офисные документы','Отдельные изображения','Обычные архивы с книгами');
var Intro:TLabel; Button:TButton; Body:TScrollBox; Footer:TPanel;
begin
  inherited CreateNew(AOwner); Name:='ReaderAssociationsForm'; Caption:='Открывать файлы в HomeLibre Reader';
  BorderStyle:=bsDialog; Position:=poOwnerFormCenter; PopupMode:=pmExplicit;
  if AOwner is TCustomForm then PopupParent:=TCustomForm(AOwner);
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=550; ClientHeight:=382;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom; Footer.Height:=52; Footer.BevelOuter:=bvNone;
  Body:=TScrollBox.Create(Self); Body.Parent:=Self; Body.Align:=alClient; Body.BorderStyle:=bsNone;
  Body.HorzScrollBar.Visible:=False; Body.VertScrollBar.Smooth:=True;
  Intro:=TLabel.Create(Self); Intro.Parent:=Body; Intro.AutoSize:=False; Intro.WordWrap:=True;
  Intro.SetBounds(16,14,518,58);
  Intro.Caption:='Выберите форматы. Читалка появится в списке приложений Windows. В открывшихся настройках назначьте её для нужных файлов.';
  for var Group:=Low(TReaderAssociationGroup) to High(TReaderAssociationGroup) do
  begin
    FGroups[Group]:=TCheckBox.Create(Self); FGroups[Group].Parent:=Body;
    FGroups[Group].SetBounds(20,82+Ord(Group)*29,410,25);
    FGroups[Group].Caption:=Captions[Group];
    FGroups[Group].Checked:=Group in [ragBooks,ragDocuments];
  end;
  Button:=TButton.Create(Self); Button.Parent:=Body; Button.Caption:='Все форматы';
  Button.SetBounds(404,82,130,28); Button.OnClick:=SelectAll;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Body; FStatus.AutoSize:=False; FStatus.WordWrap:=True;
  FStatus.SetBounds(16,210,518,62);
  FStatus.Caption:='Модули заранее не скачиваются. Если перенесёте папку читалки, выполните настройку ещё раз — путь обновится.';
  Button:=TButton.Create(Self); Button.Parent:=Body; Button.Name:='ReaderChooseDefaultApps';
  Button.Caption:='Настроить в Windows…'; Button.Default:=True;
  Button.SetBounds(16,284,255,32); Button.OnClick:=RegisterAndChoose;
  FRemove:=TButton.Create(Self); FRemove.Parent:=Body; FRemove.Caption:='Убрать из списка Windows';
  FRemove.SetBounds(283,284,251,32); FRemove.OnClick:=RemoveRegistration;
  FRemove.Enabled:=ReaderAssociationsRegistered(ParamStr(0));
  Button:=TButton.Create(Self); Button.Parent:=Body; Button.Caption:='Закрыть';
  Button.Parent:=Footer; Button.SetBounds(414,10,120,32); Button.Anchors:=[akTop,akRight]; Button.Cancel:=True; Button.ModalResult:=mrClose;
  if Assigned(PopupParent) then ScaleForPPI(PopupParent.CurrentPPI);
end;

procedure TReaderAssociationsForm.SelectAll(Sender:TObject);
begin for var Group:=Low(TReaderAssociationGroup) to High(TReaderAssociationGroup) do FGroups[Group].Checked:=True; end;

procedure TReaderAssociationsForm.RegisterAndChoose(Sender:TObject);
var Groups:TReaderAssociationGroups;
begin
  Groups:=[];
  for var Group:=Low(TReaderAssociationGroup) to High(TReaderAssociationGroup) do
    if FGroups[Group].Checked then Include(Groups,Group);
  try
    RegisterReaderAssociations(ParamStr(0),Groups); FRemove.Enabled:=True;
    if NativeInt(ShellExecute(Handle,'open',PChar(ReaderDefaultAppsURI),nil,nil,SW_SHOWNORMAL))<=32 then
      FStatus.Caption:='Читалка зарегистрирована. Откройте «Параметры Windows → Приложения → Приложения по умолчанию» и найдите HomeLibre Reader.'
    else FStatus.Caption:='В настройках Windows выберите HomeLibre Reader и нужные форматы. До вашего выбора прежние приложения остаются по умолчанию.';
  except on E:Exception do MessageDlg(E.Message,mtError,[mbOK],0); end;
end;

procedure TReaderAssociationsForm.RemoveRegistration(Sender:TObject);
begin
  try
    if UnregisterReaderAssociations(ParamStr(0)) then
    begin
      FRemove.Enabled:=False;
      FStatus.Caption:='Регистрация этой читалки удалена. Сами книги и программы сохранены. При необходимости выберите другое приложение в настройках Windows.';
    end;
  except on E:Exception do MessageDlg(E.Message,mtError,[mbOK],0); end;
end;

end.
