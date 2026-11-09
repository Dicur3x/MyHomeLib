(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors Oleksiy Penkov   oleksiy.penkov@gmail.com
  *         Nick Rymanov     nrymanov@gmail.com
  * Created                  20.08.2008
  * Description              
  *
  * $Id: frm_search.pas 854 2010-10-08 13:43:19Z eg_ $
  *
  * History
  *
  ****************************************************************************** *)

unit frm_search;

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
  StdCtrls,
  Mask,
  ExtCtrls,
  MHLSimplePanel,
  unit_Globals,
  unit_Events;

type
  TfrmBookSearch = class(TForm)
    RzPanel1: TMHLSimplePanel;
    Label1: TLabel;
    edText: TEdit;
    lblResult: TLabel;
    btnFind: TButton;
    btnClose: TButton;
    procedure edTextChange(Sender: TObject);
    procedure FindClick(Sender: TObject);

  private
    FFound: Boolean;
    FOnLocateBook: TOnLocateBookEvent;

  protected
    procedure DoCreate; override;

  public
    property OnLocateBook: TOnLocateBookEvent read FOnLocateBook write FOnLocateBook;

  end;

implementation

uses
  unit_Localization, unit_MHLTheme;

{$R *.dfm}

procedure TfrmBookSearch.DoCreate;
begin
  inherited;
  Localize(Self);
  ApplyMHLControlTheme(Self);
end;

procedure TfrmBookSearch.edTextChange(Sender: TObject);
begin
  FFound := False;
  lblResult.Caption := '';
  btnFind.Caption := 'Найти';
  btnFind.Enabled := Trim(edText.Text)<>'';
end;

procedure TfrmBookSearch.FindClick(Sender: TObject);
begin
  if not Assigned(FOnLocateBook) or (Trim(edText.Text)='') then Exit;
  FFound := FOnLocateBook(edText.Text, FFound);
  if FFound then
  begin
    lblResult.Caption := 'Книга выделена в списке.';
    btnFind.Caption := 'Найти дальше';
  end
  else
    lblResult.Caption := 'Совпадений нет. Для поиска по всей коллекции откройте «Поиск книг».';
end;

end.
