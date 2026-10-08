unit unit_BookColumnFilters;

interface

uses System.Classes, System.SysUtils, System.Generics.Collections,
  VirtualTrees, BookTreeView, unit_Globals;

type
  TBookColumnFilters = class(TComponent)
  private
    FTree: TBookTree;
    FValues: TDictionary<Integer, string>;
    function TextFor(Tag: Integer; const Book: TBookRecord): string;
    function Matches(const Book: TBookRecord): Boolean;
    function GetCount: Integer;
  public
    constructor CreateFor(Tree: TBookTree);
    destructor Destroy; override;
    class function ForTree(Tree: TBookTree): TBookColumnFilters; static;
    procedure SetValue(Tag: Integer; const Value: string);
    function Value(Tag: Integer): string;
    procedure Clear;
    function Apply(SelectBook: Boolean = True): Integer;
    property Count: Integer read GetCount;
  end;

function EditBookColumnFilters(Tree: TBookTree): Boolean;

implementation

uses System.StrUtils, System.DateUtils, System.Math, Vcl.Forms,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, unit_Consts, unit_MHLHelpers;

const
  ColumnTags: array[0..12] of Integer = (COL_AUTHOR, COL_TITLE, COL_SERIES,
    COL_NO, COL_GENRE, COL_SIZE, COL_RATE, COL_DATE, COL_TYPE,
    COL_COLLECTION, COL_LANG, COL_LIBRATE, COL_LIBID);
  ColumnNames: array[0..12] of string = ('Автор', 'Название', 'Серия', '№',
    'Жанр', 'Размер', 'Моя оценка', 'Добавлено', 'Тип', 'Коллекция',
    'Язык', 'Оценка библиотеки', 'ID в библиотеке');

constructor TBookColumnFilters.CreateFor(Tree: TBookTree);
begin
  inherited Create(Tree);
  FTree := Tree;
  FValues := TDictionary<Integer, string>.Create;
end;

destructor TBookColumnFilters.Destroy;
begin
  FValues.Free;
  inherited;
end;

class function TBookColumnFilters.ForTree(Tree: TBookTree): TBookColumnFilters;
var Component: TComponent;
begin
  for Component in Tree do
    if Component is TBookColumnFilters then Exit(TBookColumnFilters(Component));
  Result := TBookColumnFilters.CreateFor(Tree);
end;

procedure TBookColumnFilters.SetValue(Tag: Integer; const Value: string);
begin
  if Value.Trim = '' then FValues.Remove(Tag)
  else FValues.AddOrSetValue(Tag, LowerCase(Value.Trim));
end;

function TBookColumnFilters.Value(Tag: Integer): string;
begin
  if not FValues.TryGetValue(Tag, Result) then Result := '';
end;

function TBookColumnFilters.GetCount: Integer;
begin
  Result := FValues.Count;
end;

procedure TBookColumnFilters.Clear;
begin
  FValues.Clear;
end;

function TBookColumnFilters.TextFor(Tag: Integer; const Book: TBookRecord): string;
var Number: Integer;
begin
  Result := '';
  case Tag of
    COL_AUTHOR: Result := TAuthorsHelper.GetList(Book.Authors);
    COL_TITLE: Result := Book.Title;
    COL_SERIES: Result := Book.Series;
    COL_NO:
      begin
        if FTree.Tag = PAGE_PUBLISHER_SERIES then Number := Book.PublisherSeqNumber
        else Number := Book.SeqNumber;
        if Number <> 0 then Result := IntToStr(Number);
      end;
    COL_GENRE: Result := TGenresHelper.GetList(Book.Genres);
    COL_SIZE: Result := GetFormattedSize(Book.Size);
    COL_RATE: Result := IntToStr(Book.Rate);
    COL_DATE: Result := DateToStr(Book.Date) + ' ' + FormatDateTime('yyyy-mm-dd', Book.Date);
    COL_TYPE: Result := Book.GetFileType;
    COL_COLLECTION: Result := Book.CollectionName;
    COL_LANG: Result := Book.Lang;
    COL_LIBRATE: Result := IntToStr(Book.LibRate);
    COL_LIBID: Result := Book.LibID;
  end;
end;

function TBookColumnFilters.Matches(const Book: TBookRecord): Boolean;
var Pair: TPair<Integer, string>;
begin
  for Pair in FValues do
    if Pos(Pair.Value, LowerCase(TextFor(Pair.Key, Book))) = 0 then Exit(False);
  Result := True;
end;

function TBookColumnFilters.Apply(SelectBook: Boolean): Integer;
var Node, Parent, FirstBook: PVirtualNode; Book: PBookRecord; Match: Boolean;
begin
  Result := 0;
  FirstBook := nil;
  FTree.BeginUpdate;
  try
    Node := FTree.GetFirst;
    while Assigned(Node) do
    begin
      Book := FTree.GetNodeData(Node);
      Match := Assigned(Book) and (Book.NodeType = ntBookInfo) and Matches(Book^);
      FTree.IsFiltered[Node] := not Match;
      if Match then
      begin
        Inc(Result);
        if not Assigned(FirstBook) then FirstBook := Node;
      end
      else
      begin
        FTree.Selected[Node] := False;
        Node.CheckState := csUncheckedNormal;
      end;
      Node := FTree.GetNext(Node);
    end;
    // Reveal only groups which contain matching books, including collapsed groups.
    Node := FTree.GetFirst;
    while Assigned(Node) do
    begin
      Book := FTree.GetNodeData(Node);
      if Assigned(Book) and (Book.NodeType = ntBookInfo) and not FTree.IsFiltered[Node] then
      begin
        Parent := Node.Parent;
        while Assigned(Parent) and (Parent <> FTree.RootNode) do
        begin FTree.IsFiltered[Parent] := False; Parent := Parent.Parent; end;
      end;
      Node := FTree.GetNext(Node);
    end;
    if SelectBook and (not Assigned(FTree.FocusedNode) or FTree.IsEffectivelyFiltered[FTree.FocusedNode]) then
    begin
      FTree.ClearSelection;
      FTree.FocusedNode := FirstBook;
      if Assigned(FirstBook) then
      begin
        FTree.Selected[FirstBook] := True;
        FTree.FullyVisible[FirstBook] := True;
      end;
    end;
  finally FTree.EndUpdate; end;
end;

function EditBookColumnFilters(Tree: TBookTree): Boolean;
var Dialog: TForm; Scroll: TScrollBox; Description: TLabel; Footer: TPanel;
  ApplyButton, CancelButton: TButton; Edits: TObjectList<TEdit>; Edit: TEdit;
  LabelControl: TLabel; I: Integer; Filters: TBookColumnFilters;
begin
  Filters := TBookColumnFilters.ForTree(Tree);
  Dialog := TForm.CreateNew(nil);
  Edits := TObjectList<TEdit>.Create(False);
  try
    Dialog.Caption := 'Фильтры столбцов';
    Dialog.Position := poMainFormCenter;
    Dialog.ClientWidth := 620;
    Dialog.ClientHeight := 540;
    Dialog.Constraints.MinWidth := 450;
    Dialog.Constraints.MinHeight := 330;
    Dialog.Font.Name := 'Segoe UI';
    Dialog.Font.Size := 9;
    Dialog.DoubleBuffered := True;
    Description := TLabel.Create(Dialog);
    Description.Parent := Dialog;
    Description.Align := alTop;
    Description.AutoSize := False;
    Description.Height := 58;
    Description.WordWrap := True;
    Description.Caption := 'Часть текста без учёта регистра. Несколько полей — все условия одновременно.' +
      sLineBreak + 'Пустое поле снимает фильтр. Дата: например, 2026-10 или 08.10.2026.';
    Footer := TPanel.Create(Dialog);
    Footer.Parent := Dialog;
    Footer.Align := alBottom;
    Footer.Height := 48;
    Footer.BevelOuter := bvNone;
    ApplyButton := TButton.Create(Dialog);
    ApplyButton.Parent := Footer;
    ApplyButton.SetBounds(370, 8, 110, 30);
    ApplyButton.Anchors := [akRight, akTop];
    ApplyButton.Caption := 'Применить';
    ApplyButton.Default := True;
    ApplyButton.ModalResult := mrOk;
    CancelButton := TButton.Create(Dialog);
    CancelButton.Parent := Footer;
    CancelButton.SetBounds(490, 8, 110, 30);
    CancelButton.Anchors := [akRight, akTop];
    CancelButton.Caption := 'Отмена';
    CancelButton.Cancel := True;
    CancelButton.ModalResult := mrCancel;
    Scroll := TScrollBox.Create(Dialog);
    Scroll.Parent := Dialog;
    Scroll.Align := alClient;
    Scroll.BorderStyle := bsNone;
    for I := Low(ColumnTags) to High(ColumnTags) do
    begin
      LabelControl := TLabel.Create(Dialog);
      LabelControl.Parent := Scroll;
      LabelControl.SetBounds(12, I * 32 + 6, 155, 20);
      LabelControl.Caption := ColumnNames[I];
      Edit := TEdit.Create(Dialog);
      Edit.Parent := Scroll;
      Edit.SetBounds(175, I * 32 + 2, Scroll.ClientWidth - 200, 25);
      Edit.Anchors := [akLeft, akTop, akRight];
      Edit.Text := Filters.Value(ColumnTags[I]);
      Edits.Add(Edit);
    end;
    Dialog.ScaleForPPI(Tree.CurrentPPI);
    Result := Dialog.ShowModal = mrOk;
    if Result then
      for I := Low(ColumnTags) to High(ColumnTags) do Filters.SetValue(ColumnTags[I], Edits[I].Text);
  finally Edits.Free; Dialog.Free; end;
end;

end.
