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
  * $Id: frm_statistic.pas 840 2010-10-06 07:37:58Z nrymanov@gmail.com $
  *
  * History
  *
  ****************************************************************************** *)

unit frm_statistic;

interface

uses
  Classes,
  Controls,
  Forms,
  ComCtrls,
  StdCtrls,
  unit_Interfaces;

type
  TfrmStat = class(TForm)
    btnClose: TButton;
    lvInfo: TListView;

  protected
    procedure DoCreate; override;

  public
    procedure LoadCollectionInfo(const Collection: IBookCollection);
  end;

var
  frmStat: TfrmStat;

implementation

uses
  Variants,
  SysUtils,
  unit_Consts,
  unit_Helpers,
  unit_Localization, unit_CatalogSources, unit_Settings, SQLiteWrap, dm_user;

resourcestring
  rstrUnknown = 'unknown';

{$R *.dfm}

procedure TfrmStat.DoCreate;
begin
  inherited;
  Localize(Self);
  BorderStyle := bsSizeable;
  Font.Name := 'Segoe UI'; Font.Size := 9;
  Constraints.MinWidth := 660; Constraints.MinHeight := 360;
  ClientWidth := 720; ClientHeight := 420;
  lvInfo.DoubleBuffered := True;
end;

procedure TfrmStat.LoadCollectionInfo(const Collection: IBookCollection);
var
  vVersion: Variant;
  DataVersion: string;
  AuthorsCount: Integer;
  BooksCount: Integer;
  SeriesCount: Integer;
  Sources: TCatalogSources;
  Source: TCatalogSource; Item: TListItem; SourceGroup: TListGroup;
  DB: TSQLiteDatabase; Linked: Int64;
begin
  Assert(Assigned(Collection));

  Collection.GetStatistics(AuthorsCount, BooksCount, SeriesCount);

  vVersion := Collection.GetProperty(PROP_DATAVERSION);
  if VarIsEmpty(vVersion) then
    DataVersion := rstrUnknown
  else
    DataVersion := IntToStr(vVersion);

  //
  // Заполним данные
  //
  lvInfo.Items[0].SubItems[0] := Collection.GetProperty(PROP_DISPLAYNAME);
  lvInfo.Items[1].SubItems[0] := DateToStr(Collection.GetProperty(PROP_CREATIONDATE));
  lvInfo.Items[2].SubItems[0] := DataVersion;
  lvInfo.Items[3].SubItems[0] := Collection.GetProperty(PROP_NOTES);

  lvInfo.Items[4].SubItems[0] := IntToStr(AuthorsCount);
  lvInfo.Items[5].SubItems[0] := IntToStr(BooksCount);
  lvInfo.Items[6].SubItems[0] := IntToStr(SeriesCount);

  lvInfo.Items[3].Caption := 'Описание исходного INPX:';
  lvInfo.Items[5].Caption := 'Записей книг:';
  while lvInfo.Items.Count > 7 do lvInfo.Items.Delete(7);
  while lvInfo.Groups.Count > 2 do lvInfo.Groups.Delete(2);
  Item := lvInfo.Items.Add; Item.GroupID := 2;
  Item.Caption := 'Подсчёт:';
  Item.SubItems.Add('Каждая запись один раз, независимо от числа серий');
  Sources := LoadCatalogSources(Collection);
  if Length(Sources) > 0 then
  begin
    SourceGroup := lvInfo.Groups.Add;
    SourceGroup.Header := 'Дополнительные источники (' + IntToStr(Length(Sources)) + ')';
    SourceGroup.GroupID := 3;
    DB := TSQLiteDatabase.CreateReadOnly(Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE))));
    try
      for Source in Sources do
      begin
        Linked := DB.QuerySingleInt('SELECT COUNT(DISTINCT l.BookID) FROM CatalogSourceBooks l ' +
          'JOIN Books b ON b.BookID=l.BookID WHERE l.SourceKey>=? AND l.SourceKey<?',
          [Source.ID + ':', Source.ID + ';']);
        Item := lvInfo.Items.Add; Item.GroupID := 3; Item.Caption := Source.Name;
        Item.SubItems.Add(IntToStr(Linked) + ' связанных записей; ' + Source.Root);
      end;
    finally DB.Free; end;
    Item := lvInfo.Items.Add; Item.GroupID := 3; Item.Caption := 'Примечание:';
    Item.SubItems.Add('Связи источников могут пересекаться. Разные файлы одного произведения считаются отдельно.');
  end;

  lvInfo.AutosizeColumn(0);
  lvInfo.Columns[1].Width := 460;
end;

end.
