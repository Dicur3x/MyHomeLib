unit unit_BookSendOptions;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, ShlObj, unit_Globals;

type
  TBookSendOptions = record
    Folder: string;
    ShellItem: IShellItem;
    UseMTP, ExplicitFormat, KeepSourceFormat: Boolean;
    Mode: TExportMode;
    ImageQuality: string;
    ScriptIndex: Integer;
  end;

  TBookSendOptionsForm = class(TForm)
  private
    FShellItem: IShellItem;
    FDestination: TEdit;
    FFormat, FImages: TComboBox;
    FNote: TLabel;
    FLastFormat: Integer;
    FScriptMap: TArray<Integer>;
    procedure Browse(Sender: TObject);
    procedure Changed(Sender: TObject);
    procedure Send(Sender: TObject);
  public
    procedure ScaleForPPI(NewPPI: Integer); override;
    constructor Create(AOwner: TComponent); override;
  end;

function ChooseBookSendOptions(BookCount: Integer; const InitialFolder: string;
  DefaultMode: TExportMode; out Options: TBookSendOptions;
  AllowScripts: Boolean = True): Boolean;

implementation

uses System.SysUtils, System.IOUtils, Winapi.Windows, Winapi.ActiveX,
  Vcl.Controls, Vcl.ExtCtrls, Vcl.Dialogs, Vcl.Graphics, unit_Helpers, unit_MHLTheme, dm_user;

const
  Modes: array[1..7] of TExportMode = (emFB2, emFB2Zip, emEpub, emTxt, emLrf, emPDF, emMobi);
  Qualities: array[0..4] of string = ('ask','original','balanced','economy','none');

constructor TBookSendOptionsForm.Create(AOwner: TComponent);
var Content: TPanel; Footer: TPanel; LabelControl: TLabel; Button: TButton;
  function AddLabel(const Text: string; Y: Integer): TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=Content; Result.Caption:=Text;
    Result.AutoSize:=False; Result.WordWrap:=True; Result.ShowAccelChar:=False;
    Result.SetBounds(20,Y,600,34); Result.Anchors:=[akLeft,akTop,akRight];
  end;
begin
  inherited CreateNew(AOwner);
  Name:='BookSendOptions'; Caption:='Сохранить как';
  Position:=poMainFormCenter; BorderStyle:=bsSizeable;
  Font.Name:='Segoe UI'; Font.Size:=9; ClientWidth:=660; ClientHeight:=420;
  Constraints.MinWidth:=660+Width-ClientWidth;
  Constraints.MinHeight:=420+Height-ClientHeight;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom;
  Footer.BevelOuter:=bvNone; Footer.Height:=56;
  Content:=TPanel.Create(Self); Content.Parent:=Self; Content.Align:=alClient; Content.BevelOuter:=bvNone;
  AddLabel('Куда сохранить: папка компьютера, облачной синхронизации или подключённой читалки.',16);
  FDestination:=TEdit.Create(Self); FDestination.Parent:=Content; FDestination.Name:='SendDestination';
  FDestination.SetBounds(20,55,490,25); FDestination.Anchors:=[akLeft,akTop,akRight]; FDestination.ReadOnly:=True;
  FDestination.ShowHint:=True;
  Button:=TButton.Create(Self); Button.Parent:=Content; Button.Caption:='Выбрать…';
  Button.SetBounds(520,54,120,28); Button.Anchors:=[akTop,akRight]; Button.OnClick:=Browse;
  AddLabel('Формат копии:',100);
  FFormat:=TComboBox.Create(Self); FFormat.Parent:=Content; FFormat.Name:='SendFormat'; FFormat.Style:=csDropDownList;
  FFormat.SetBounds(20,127,620,25); FFormat.Anchors:=[akLeft,akTop,akRight];
  FFormat.Items.Add('Сохранить формат книги');
  FFormat.Items.Add('FB2'); FFormat.Items.Add('FB2 в ZIP'); FFormat.Items.Add('EPUB');
  FFormat.Items.Add('TXT — только текст'); FFormat.Items.Add('LRF — внешний конвертер');
  FFormat.Items.Add('PDF — внешний конвертер'); FFormat.Items.Add('MOBI — внешний конвертер');
  for var I:=0 to Settings.Scripts.Count-1 do if not Settings.Scripts[I].Standalone then
  begin
    FFormat.Items.Add('Сценарий: '+Settings.Scripts[I].Title); FScriptMap:=FScriptMap+[I];
  end;
  FFormat.ItemIndex:=1; FFormat.OnChange:=Changed;
  AddLabel('Изображения:',174);
  FImages:=TComboBox.Create(Self); FImages.Parent:=Content; FImages.Name:='SendImages'; FImages.Style:=csDropDownList;
  FImages.SetBounds(20,201,620,25); FImages.Anchors:=[akLeft,akTop,akRight];
  FImages.Items.Add('Выбрать с оценкой размера для каждой книги');
  FImages.Items.Add('Как есть — не изменять изображения');
  FImages.Items.Add('Сбалансированный');
  FImages.Items.Add('Экономный'); FImages.Items.Add('Без изображений'); FImages.ItemIndex:=0;
  FImages.OnChange:=Changed;
  FNote:=AddLabel('',247); FNote.Height:=64;
  LabelControl:=AddLabel('Параметры применяются к сохраняемой копии. Книги в коллекции остаются в исходном виде.',318);
  LabelControl.Font.Color:=clGrayText;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.Name:='SendBooks'; Button.Caption:='Сохранить';
  Button.SetBounds(390,13,120,30); Button.Anchors:=[akTop,akRight]; Button.Default:=True; Button.OnClick:=Send;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.Name:='CancelSending'; Button.Caption:='Отмена';
  Button.SetBounds(520,13,120,30); Button.Anchors:=[akTop,akRight]; Button.Cancel:=True; Button.ModalResult:=mrCancel;
  FLastFormat:=-1; ApplyMHLControlTheme(Self); Changed(nil);
end;

procedure TBookSendOptionsForm.ScaleForPPI(NewPPI: Integer);
var OldPPI, W, H: Integer;
begin
  OldPPI:=PixelsPerInch; W:=ClientWidth; H:=ClientHeight;
  inherited;
  if (OldPPI>0) and (NewPPI<>OldPPI) then
  begin ClientWidth:=MulDiv(W,NewPPI,OldPPI); ClientHeight:=MulDiv(H,NewPPI,OldPPI); end;
end;

procedure TBookSendOptionsForm.Browse(Sender: TObject);
var Folder: string; Item: IShellItem;
begin
  Folder:=FDestination.Text;
  if not GetFolderShellItem(Handle,'Куда сохранить книги',Folder,Item) then Exit;
  FShellItem:=Item; FDestination.Text:=Folder; FDestination.Hint:=Folder;
end;

procedure TBookSendOptionsForm.Changed(Sender: TObject);
begin
  FImages.Enabled:=FFormat.ItemIndex in [0,1,2,3];
  if FLastFormat<>FFormat.ItemIndex then
  begin
    if FFormat.ItemIndex=0 then FImages.ItemIndex:=1;
    FLastFormat:=FFormat.ItemIndex;
  end;
  if (FFormat.ItemIndex=0) and (FImages.ItemIndex=1) then FNote.Caption:='Книга сохранится в исходном формате без изменения изображений.'
  else if FFormat.ItemIndex=0 then FNote.Caption:='Формат книги сохраняется. Изменение изображений в исходном формате поддерживается для FB2 и EPUB. Для других форматов программа объяснит ограничение и не подменит формат.'
  else if FFormat.ItemIndex=4 then FNote.Caption:='TXT содержит только текст, без иллюстраций и оформления.'
  else if FFormat.ItemIndex>7 then FNote.Caption:='Книги обрабатываются выбранным личным сценарием. Его параметры задаются в настройках сценариев.'
  else if FFormat.ItemIndex>4 then FNote.Caption:='Нужен установленный внешний конвертер. Книга будет подготовлена в FB2; обработка изображений доступна при сохранении в FB2 или EPUB.'
  else if FImages.ItemIndex=0 then FNote.Caption:='Перед записью книги с изображениями появится выбор качества с примерным размером. Для сканов там же можно настроить разделение разворотов.'
  else if FImages.ItemIndex=4 then FNote.Caption:='Вместо иллюстраций останется пометка «Изображение не включено в эту копию». Для книг, состоящих только из сканов, нужен распознанный текст.'
  else FNote.Caption:='Выбранное качество применяется ко всем отмеченным книгам. Небольшие изображения не увеличиваются.';
end;

procedure TBookSendOptionsForm.Send(Sender: TObject);
begin
  if Trim(FDestination.Text)='' then begin Browse(nil); if Trim(FDestination.Text)='' then Exit; end;
  if IsShellPath(FDestination.Text) then
  begin
    if not Assigned(FShellItem) and Failed(SHCreateItemFromParsingName(PChar(FDestination.Text),nil,IShellItem,FShellItem)) then
    begin MessageDlg('Устройство недоступно. Подключите его и выберите папку снова.',mtInformation,[mbOK],0); Exit; end;
  end
  else if not TPath.IsPathRooted(FDestination.Text) then
  begin MessageDlg('Выберите папку, в которую нужно сохранить книги.',mtInformation,[mbOK],0); Exit; end;
  ModalResult:=mrOk;
end;

function ChooseBookSendOptions(BookCount: Integer; const InitialFolder: string;
  DefaultMode: TExportMode; out Options: TBookSendOptions; AllowScripts: Boolean): Boolean;
var Dialog: TBookSendOptionsForm;
begin
  Result:=False; Options:=Default(TBookSendOptions);
  Dialog:=TBookSendOptionsForm.Create(Application);
  try
    if not AllowScripts then
    begin
      while Dialog.FFormat.Items.Count>8 do Dialog.FFormat.Items.Delete(8);
      Dialog.FScriptMap:=nil;
    end;
    Dialog.Caption:=Format('Сохранить как · книг: %d',[BookCount]);
    Dialog.FDestination.Text:=InitialFolder; Dialog.FDestination.Hint:=InitialFolder;
    Dialog.FFormat.ItemIndex:=0;
    if DefaultMode<>emFB2 then
      for var I:=Low(Modes) to High(Modes) do if Modes[I]=DefaultMode then Dialog.FFormat.ItemIndex:=I;
    for var I:=0 to High(Dialog.FScriptMap) do
      if Dialog.FScriptMap[I]=Settings.DefaultScript-1 then Dialog.FFormat.ItemIndex:=8+I;
    Dialog.Changed(nil);
    if Dialog.ShowModal<>mrOk then Exit;
    Options.Folder:=Dialog.FDestination.Text; Options.ShellItem:=Dialog.FShellItem;
    Options.UseMTP:=IsShellPath(Options.Folder);
    Options.ExplicitFormat:=Dialog.FFormat.ItemIndex in [1..7]; Options.ScriptIndex:=-1;
    if Dialog.FFormat.ItemIndex>7 then Options.ScriptIndex:=Dialog.FScriptMap[Dialog.FFormat.ItemIndex-8];
    Options.KeepSourceFormat:=Dialog.FFormat.ItemIndex=0;
    Options.Mode:=emFB2; Options.ImageQuality:='original';
    if Options.ExplicitFormat then Options.Mode:=Modes[Dialog.FFormat.ItemIndex];
    if Dialog.FImages.Enabled then Options.ImageQuality:=Qualities[Dialog.FImages.ItemIndex];
    Result:=True;
  finally Dialog.Free; end;
end;

end.
