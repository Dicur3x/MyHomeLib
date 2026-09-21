unit unit_PublisherSeriesView;

interface

uses
  Winapi.Windows, System.Classes, Vcl.Controls, Vcl.ComCtrls, Vcl.StdCtrls, Vcl.ExtCtrls,
  VirtualTrees, BookTreeView, BookInfoPanel, MHLSimplePanel, MHLSplitter,
  unit_ColorTabs;

type
  TPublisherSeriesView = class(TComponent)
  public
    Tab: unit_ColorTabs.TTabSheet;
    Sidebar: TMHLSimplePanel;
    SeriesTree: TVirtualStringTree;
    Books: TBookTree;
    Info: TInfoPanel;
    InfoSplitter: TMHLSplitter;
    Language: TComboBox;
    Search: TEdit;
    ClearSearch: TButton;
    IndexButton: TButton;
    Title, Total: TLabel;
    SearchTimer: TTimer;
    constructor CreateView(AOwner: TComponent; Pages: TPageControl;
      SeriesTemplate: TVirtualStringTree; BooksTemplate: TBookTree;
      const ViewTag: Integer);
  end;

implementation

constructor TPublisherSeriesView.CreateView(AOwner: TComponent;
  Pages: TPageControl; SeriesTemplate: TVirtualStringTree;
  BooksTemplate: TBookTree; const ViewTag: Integer);
var
  SearchPanel, BooksPanel, TitlePanel: TMHLSimplePanel;
  Splitter: TMHLSplitter;
  SearchLabel, LangLabel: TLabel;

  function Scale(Value: Integer): Integer;
  begin
    Result := MulDiv(Value, Pages.CurrentPPI, 96);
  end;
begin
  inherited Create(AOwner);
  Tab := unit_ColorTabs.TTabSheet.Create(Self);
  Tab.PageControl := Pages;
  Tab.Caption := 'Книжные серии';
  Tab.Tag := ViewTag;

  Sidebar := TMHLSimplePanel.Create(Self);
  Sidebar.Parent := Tab;
  Sidebar.Align := alLeft;
  Sidebar.Width := Scale(250);
  SearchPanel := TMHLSimplePanel.Create(Self);
  SearchPanel.Parent := Sidebar;
  SearchPanel.Align := alTop;
  SearchPanel.Height := Scale(30);
  SearchLabel := TLabel.Create(Self);
  SearchLabel.Parent := SearchPanel;
  SearchLabel.Align := alLeft;
  SearchLabel.Layout := tlCenter;
  SearchLabel.Caption := 'Поиск: ';
  ClearSearch := TButton.Create(Self);
  ClearSearch.Parent := SearchPanel;
  ClearSearch.Align := alRight;
  ClearSearch.Width := Scale(28);
  ClearSearch.Caption := 'X';
  ClearSearch.Hint := 'Очистить поиск';
  ClearSearch.ShowHint := True;
  Search := TEdit.Create(Self);
  Search.Parent := SearchPanel;
  Search.Align := alClient;
  Search.Hint := 'Название издательской серии';
  Search.ShowHint := True;
  IndexButton := TButton.Create(Self);
  IndexButton.Parent := Sidebar;
  IndexButton.Align := alBottom;
  IndexButton.Height := Scale(30);
  IndexButton.Caption := 'Заполнить из книг...';
  SeriesTree := TVirtualStringTree.Create(Self);
  SeriesTree.Parent := Sidebar;
  SeriesTree.Align := alClient;
  SeriesTree.TreeOptions.Assign(SeriesTemplate.TreeOptions);
  SeriesTree.Header.Assign(SeriesTemplate.Header);
  SeriesTree.DefaultNodeHeight := SeriesTemplate.DefaultNodeHeight;
  SeriesTree.ChangeDelay := SeriesTemplate.ChangeDelay;
  SeriesTree.Font.Assign(SeriesTemplate.Font);

  Splitter := TMHLSplitter.Create(Self);
  Splitter.Parent := Tab;
  Splitter.Left := Sidebar.Width;
  Splitter.Align := alLeft;
  Splitter.ResizeControl := Sidebar;
  Splitter.MinSize := Scale(160);
  Splitter.Width := Scale(3);
  BooksPanel := TMHLSimplePanel.Create(Self);
  BooksPanel.Parent := Tab;
  BooksPanel.Align := alClient;
  TitlePanel := TMHLSimplePanel.Create(Self);
  TitlePanel.Parent := BooksPanel;
  TitlePanel.Align := alTop;
  TitlePanel.Height := Scale(28);
  Language := TComboBox.Create(Self);
  Language.Parent := TitlePanel;
  Language.Align := alRight;
  Language.Width := Scale(64);
  Language.Style := csDropDownList;
  Language.Tag := ViewTag;
  Language.Items.Add('-');
  Language.ItemIndex := 0;
  LangLabel := TLabel.Create(Self);
  LangLabel.Parent := TitlePanel;
  LangLabel.Align := alRight;
  LangLabel.Layout := tlCenter;
  LangLabel.Caption := 'Язык: ';
  Total := TLabel.Create(Self);
  Total.Parent := TitlePanel;
  Total.Align := alRight;
  Total.AlignWithMargins := True;
  Total.Margins.SetBounds(Scale(6), 0, Scale(6), 0);
  Total.Layout := tlCenter;
  Title := TLabel.Create(Self);
  Title.Parent := TitlePanel;
  Title.Align := alClient;
  Title.AutoSize := False;
  Title.ShowAccelChar := False;
  Title.EllipsisPosition := epEndEllipsis;
  Title.Layout := tlCenter;

  Info := TInfoPanel.Create(Self);
  Info.Parent := BooksPanel;
  Info.Align := alBottom;
  InfoSplitter := TMHLSplitter.Create(Self);
  InfoSplitter.Parent := BooksPanel;
  InfoSplitter.Align := alBottom;
  InfoSplitter.Height := Scale(3);
  InfoSplitter.Cursor := crVSplit;
  InfoSplitter.ResizeControl := Info;
  InfoSplitter.MinSize := Scale(80);
  Books := TBookTree.Create(Self);
  Books.Parent := BooksPanel;
  Books.Align := alClient;
  Books.Tag := ViewTag;
  Books.TreeOptions.Assign(BooksTemplate.TreeOptions);
  Books.Header.Assign(BooksTemplate.Header);
  Books.DefaultNodeHeight := BooksTemplate.DefaultNodeHeight;
  Books.ChangeDelay := BooksTemplate.ChangeDelay;
  Books.Font.Assign(BooksTemplate.Font);
  Books.Images := BooksTemplate.Images;
  Books.PopupMenu := BooksTemplate.PopupMenu;
  Books.OnChange := BooksTemplate.OnChange;
  Books.OnDblClick := BooksTemplate.OnDblClick;
  Books.OnHeaderClick := BooksTemplate.OnHeaderClick;
  Books.OnKeyDown := BooksTemplate.OnKeyDown;
  Books.OnMouseUp := BooksTemplate.OnMouseUp;
  InfoSplitter.Top := Info.Top - InfoSplitter.Height;
  SearchTimer := TTimer.Create(Self);
  SearchTimer.Enabled := False;
  SearchTimer.Interval := 300;
end;

end.
