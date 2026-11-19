(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             25.07.2026
  * Description         Выбор файла для ручного обновления коллекции
  *
  ****************************************************************************** *)

unit frm_UpdateFromFile;

interface

uses
  Windows,
  Messages,
  SysUtils,
  Variants,
  Classes,
  Graphics,
  Controls,
  Forms,
  Dialogs,
  StdCtrls, unit_ContextToolGuide;

type
  TdlgUpdateFromFile = class(TForm)
    lblFile: TLabel;
    lblWarning: TLabel;
    edFile: TEdit;
    btnBrowse: TButton;
    cbFull: TCheckBox;
    btnOk: TButton;
    btnCancel: TButton;
    procedure FormCreate(Sender: TObject);
    procedure btnBrowseClick(Sender: TObject);
    procedure edFileChange(Sender: TObject);
  private
    FToolGuide:TContextToolGuide;
  protected
    procedure DoCreate; override;
    procedure DoShow; override;
    procedure DoHide; override;
  end;

var
  dlgUpdateFromFile: TdlgUpdateFromFile;

function AskUpdateFile(out AFileName: string; out AFull: Boolean): Boolean;

implementation

uses
  unit_Helpers,
  unit_Localization;

{$R *.dfm}

resourcestring
   rstrUpdateFromFileCaption = 'Обновление коллекции из файла';
   rstrUpdateFileLabel = 'Файл обновления (*.inpx, *.zip, *.jsonl, *.jsonl.zst):';
   rstrBrowseCaption = 'Обзор...';
   rstrFullReimportCaption = 'Полный переимпорт (очистить коллекцию)';
   rstrFullReimportWarning = 'Коллекция будет очищена и заново заполнена данными из выбранного ' +
     'файла. Данные пользователя (статус прочтения, оценки и группы) будут сохранены и ' +
     'восстановлены. Без этой опции записи из файла только добавляются в коллекцию.';
   rstrOkCaption = 'OK';
   rstrCancelCaption = 'Отмена';

procedure TdlgUpdateFromFile.DoCreate;
begin
  inherited;
  Localize(Self);
  FToolGuide:=TContextToolGuide.CreateForTool(Self,Self,'update-from-file','Как обновить каталог из файла',
    'Скачайте новый индекс вашей библиотеки. Если появились новые архивы книг, докачайте их отдельно и положите в папку источника.',
    'Для обычного пополнения оставьте «Полный переимпорт» выключенным. Выбирайте его только с полным индексом, если нужно пересобрать список книг по этому файлу.'+#13#10+#13#10+
    'Индекс содержит записи каталога. Чтобы открыть книгу после обновления, HomeLibre должен видеть сам файл книги или архив с ней.',
    HelpContext,'');
  FToolGuide.Name:='UpdateFileContextGuide';
  FToolGuide.HelpButton.SetBounds(ClientWidth-40,5,28,24);
end;

procedure TdlgUpdateFromFile.DoShow;
begin
  inherited;
  FToolGuide.FirstUse;
end;

procedure TdlgUpdateFromFile.DoHide;
begin
  if Assigned(FToolGuide) then FToolGuide.Hide;
  inherited;
end;

procedure TdlgUpdateFromFile.FormCreate(Sender: TObject);
begin
  Caption := rstrUpdateFromFileCaption;
  lblFile.Caption := rstrUpdateFileLabel;
  btnBrowse.Caption := rstrBrowseCaption;
  cbFull.Caption := rstrFullReimportCaption;
  lblWarning.Caption := rstrFullReimportWarning;
  btnOk.Caption := rstrOkCaption;
  btnCancel.Caption := rstrCancelCaption;
end;

procedure TdlgUpdateFromFile.btnBrowseClick(Sender: TObject);
var
  FileName: string;
begin
  if GetFileName(fnOpenUpdate, FileName) then
    edFile.Text := FileName;
end;

procedure TdlgUpdateFromFile.edFileChange(Sender: TObject);
begin
  btnOk.Enabled := (edFile.Text <> '') and FileExists(edFile.Text);
end;

function AskUpdateFile(out AFileName: string; out AFull: Boolean): Boolean;
var
  Dlg: TdlgUpdateFromFile;
begin
  AFileName := '';
  AFull := False;

  Dlg := TdlgUpdateFromFile.Create(Application);
  try
    Result := (mrOk = Dlg.ShowModal);
    if Result then
    begin
      AFileName := Dlg.edFile.Text;
      AFull := Dlg.cbFull.Checked;
    end;
  finally
    Dlg.Free;
  end;
end;

end.
