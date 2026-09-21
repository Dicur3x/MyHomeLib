(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             14.04.2010
  * Description         Панель информации о книге
  *
  * $Id: BookInfoPanel.pas 1166 2014-05-22 03:09:17Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit BookInfoPanel;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.CommCtrl,
  System.Types,
  Controls,
  Forms,
  Graphics,
  Classes,
  StdCtrls,
  ComCtrls,
  ExtCtrls,
  SysUtils,
  Math,
  Clipbrd,
  Menus,
  FictionBook_21,
  StrUtils,
  unit_MHLHelpers,
  unit_FB2Utils,
  MHLLinkLabel;

type
  TInfoPanel = class(TPanel)
  private
    FCover: TImage;
    FInfoViewport: TScrollBox;
    FInfoPanel: TPanel;
    FTitle: TLabel;
    FAuthors: TMHLLinkLabel;
    FSerieLabel: TLabel;
    FSeries: TMHLLinkLabel;
    FPublisherSerieLabel: TLabel;
    FPublisherSeries: TLabel;
    FPublisherSeriesLinks: TMHLLinkLabel;
    FGenreLabel: TLabel;
    FGenres: TMHLLinkLabel;
    FAnnotation: TMemo;
    FFb2Info: TListView;

    FOnAuthorLinkClicked: TSysLinkEvent;
    FOnGenreLinkClicked: TSysLinkEvent;
    FOnSeriesLinkClicked: TSysLinkEvent;
    FOnPublisherSeriesLinkClicked: TSysLinkEvent;
    FMenu: TPopupMenu;

    FInfoPriority: Boolean;
    FUpdatingLayout: Boolean;

    function GetShowCover: boolean;
    procedure SetShowCover(const Value: boolean);

    function GetShowAnnotation: Boolean;
    procedure SetShowAnnotation(const Value: Boolean);

    procedure UpdateLinkTexts;

    procedure OnLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure OnAnnotationClicked(Sender: TObject);
    procedure SetInfoPriority(const Value: Boolean);
    procedure CopyToClipboard(Sender: TObject);
    procedure LayoutControls;
    procedure InfoPanelResize(Sender: TObject);
    procedure CMFontChanged(var Message: TMessage); message CM_FONTCHANGED;

  protected
    procedure CreateWnd; override;
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;

  public
    constructor Create(AOwner: TComponent); override;

    procedure SetBookInfo(
      const BookTitle: string;
      const Autors: string;
      const Series: string;
      const Genres: string
    );

    procedure SetBookCover(
      BookCover: TGraphic
      );

    procedure SetPublisherSeries(const Value: string);
    procedure SetPublisherSeriesLinks(const Value: string);

    procedure SetFb2Info(
      book: IXMLFictionBook;
      const Folder: string = '';
      const FileName: string = ''
      );


    procedure SetBookAnnotation(
      book: IXMLFictionBook
      );

    procedure Clear;

  published
    property ShowCover: Boolean read GetShowCover write SetShowCover default True;
    property ShowAnnotation: Boolean read GetShowAnnotation write SetShowAnnotation default True;
    property InfoPriority: Boolean read FInfoPriority write SetInfoPriority default False;

    property OnAuthorLinkClicked: TSysLinkEvent read FOnAuthorLinkClicked write FOnAuthorLinkClicked;
    property OnSeriesLinkClicked: TSysLinkEvent read FOnSeriesLinkClicked write FOnSeriesLinkClicked;
    property OnPublisherSeriesLinkClicked: TSysLinkEvent read FOnPublisherSeriesLinkClicked write FOnPublisherSeriesLinkClicked;
    property OnGenreLinkClicked: TSysLinkEvent read FOnGenreLinkClicked write FOnGenreLinkClicked;
  end;

implementation

type
  TPublisherSeriesLinkLabel = class(TMHLLinkLabel)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

resourcestring
  rstrSerieLabel = 'Серия:';
  rstrPublisherSeriesLabel = 'Книжные серии:';
  rstrGenreLabel = 'Жанр(ы):';
  rstrNoAnnotationHint = 'Аннотация отсутствует';
  rsrtCopyLabel = 'Копировать';
  rsrtFiledLabel = 'Поле';
  rsrtValueLabel = 'Значение';

const
  PanelPadding = 10;  // inset of the content from the panel's rounded border
  CoverGap = 12;      // gap between the cover and the info column
  RowSpacing = 5;     // leading added to the text height of an info row
  AnnotationGap = 8;  // gap between the last info row and the annotation
  LabelColumn = 70;   // width of the "Серия:"/"Жанр(ы):" caption column

function GetCoverWidth(Height: Integer): Integer;
begin
  Result := Height * 2 div 3;
end;

procedure TPublisherSeriesLinkLabel.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := Params.Style or $00000004; // LWS_NOPREFIX: literal ampersands in titles.
end;

procedure TInfoPanel.CopyToClipboard(Sender: TObject);
begin
  Clipboard.AsText := FFb2Info.Selected.SubItems[0];
end;

constructor TInfoPanel.Create(AOwner: TComponent);
var
  Item: TMenuItem;
begin
  inherited Create(AOwner);

  FMenu := TPopupMenu.Create(Self);
  Item := TMenuItem.Create(Self);
  Item.Caption := rsrtCopyLabel;
  Item.ShortCut := TextToShortCut('Ctrl+C'); //ShortCut(43,[ssCtrl]) ;
  Item.OnClick :=  CopyToClipboard;
  FMenu.Items.Add(Item);

  SetBounds(0, 0, 500, 200);

  BevelOuter := bvNone;

  // Keep the aligned children away from the panel edge. Margins are honoured
  // by TWinControl.AlignControls and do not require a third-party panel.
  FCover := TImage.Create(Self);
  FCover.Parent := Self;
  FCover.SetBounds(0, 0, GetCoverWidth(200), 200);
  FCover.Align := alLeft;
  FCover.AlignWithMargins := True;
  FCover.Margins.SetBounds(PanelPadding, PanelPadding, 0, PanelPadding);
  FCover.Center := True;
  FCover.Proportional := True;
  FCover.Stretch := True;

  FInfoViewport := TScrollBox.Create(Self);
  FInfoViewport.Parent := Self;
  FInfoViewport.Align := alClient;
  FInfoViewport.AlignWithMargins := True;
  FInfoViewport.Margins.SetBounds(CoverGap, PanelPadding, PanelPadding, PanelPadding);
  FInfoViewport.BorderStyle := bsNone;
  FInfoViewport.ParentColor := True;
  FInfoViewport.HorzScrollBar.Visible := False;
  FInfoViewport.VertScrollBar.Tracking := True;
  FInfoViewport.VertScrollBar.Smooth := True;
  FInfoPanel := TPanel.Create(Self);
  FInfoPanel.Parent := FInfoViewport;
  FInfoPanel.Align := alTop;
  FInfoPanel.Height := 200;
  FInfoPanel.BevelOuter := bvNone;
  FInfoPanel.ParentColor := True;

  FTitle := TLabel.Create(FInfoPanel);
  FTitle.Parent := FInfoPanel;
  FTitle.Anchors := [akLeft, akTop, akRight];
  FTitle.AutoSize := False;
  FTitle.Font.Style := [fsBold];

  FAuthors := TMHLLinkLabel.Create(FInfoPanel);
  FAuthors.AutoSize := False;
  FAuthors.Parent := FInfoPanel;
  // SysLink's visual-style flag ignores the chosen font and always draws at theme size.
  FAuthors.UseVisualStyle := False;
  FAuthors.OnLinkClick := OnLinkClicked;

  FSerieLabel := TLabel.Create(FInfoPanel);
  FSerieLabel.Parent := FInfoPanel;
  FSerieLabel.Caption := rstrSerieLabel;
  FSerieLabel.AutoSize := False;
  FSerieLabel.Font.Style := [fsBold];

  FSeries := TMHLLinkLabel.Create(FInfoPanel);
  FSeries.AutoSize := False;
  FSeries.Parent := FInfoPanel;
  FSeries.UseVisualStyle := False;
  FSeries.OnLinkClick := OnLinkClicked;

  FPublisherSerieLabel := TLabel.Create(FInfoPanel);
  FPublisherSerieLabel.Parent := FInfoPanel;
  FPublisherSerieLabel.Caption := rstrPublisherSeriesLabel;
  FPublisherSerieLabel.AutoSize := False;
  FPublisherSerieLabel.Font.Style := [fsBold];
  FPublisherSerieLabel.Visible := False;

  FPublisherSeries := TLabel.Create(FInfoPanel);
  FPublisherSeries.Parent := FInfoPanel;
  FPublisherSeries.AutoSize := False;
  FPublisherSeries.WordWrap := True;
  FPublisherSeries.ShowAccelChar := False;
  FPublisherSeries.Visible := False;
  FPublisherSeriesLinks := TPublisherSeriesLinkLabel.Create(FInfoPanel);
  FPublisherSeriesLinks.Parent := FInfoPanel;
  FPublisherSeriesLinks.AutoSize := False;
  FPublisherSeriesLinks.UseVisualStyle := False;
  FPublisherSeriesLinks.Visible := False;
  FPublisherSeriesLinks.OnLinkClick := OnLinkClicked;

  FGenreLabel := TLabel.Create(FInfoPanel);
  FGenreLabel.Parent := FInfoPanel;
  FGenreLabel.Caption := rstrGenreLabel;
  FGenreLabel.AutoSize := False;
  FGenreLabel.Font.Style := [fsBold];

  FGenres := TMHLLinkLabel.Create(FInfoPanel);
  FGenres.AutoSize := False;
  FGenres.Parent := FInfoPanel;
  FGenres.UseVisualStyle := False;
  FGenres.OnLinkClick := OnLinkClicked;

  FAnnotation := TMemo.Create(FInfoPanel);
  FAnnotation.Parent := FInfoPanel;
  FAnnotation.Anchors := [akLeft, akTop, akRight, akBottom];
  // No sunken frame inside the panel's own rounded border, and follow the
  // panel's background so the annotation reads as part of the panel.
  FAnnotation.BorderStyle := bsNone;
  FAnnotation.ParentColor := True;
  FAnnotation.ReadOnly := True;
  FAnnotation.TextHint := rstrNoAnnotationHint;
  FAnnotation.ScrollBars := ssVertical;
  FAnnotation.OnDblClick := OnAnnotationClicked;
  FAnnotation.Visible := not FInfoPriority;

  FFb2Info := TListView.Create(FInfoPanel);

  with FFb2Info do
  begin
    Parent := FInfoPanel;
    BorderStyle := bsNone;
    ParentColor := True;
    with Columns.Add do begin
      Caption := rsrtFiledLabel;
      Width := 175;
    end;
    with Columns.Add do begin
      Caption := rsrtValueLabel;
      AutoSize := True;
    end;
    ColumnClick := False;
    GroupView := True;
    ReadOnly := True;
    RowSelect := True;
    TabOrder := 0;
    ViewStyle := vsReport;
    Anchors := [akLeft, akTop, akRight, akBottom];
    OnDblClick := OnAnnotationClicked;
    Visible := FInfoPriority;
    PopupMenu := FMenu;
  end;


  //       300 200
  //0,  0, 300,  20
  //0, 20, 300,  20
  //0, 40,  60,  20 | 60, 40, 140, 20
  //0, 60,  60,  20 | 60, 60, 140, 20
  //0, 80, 300, 120

  if csDesigning in ComponentState then
  begin
    FTitle.Caption := 'Название книги';
    FAuthors.Caption := '<a>Автор книги</a> <a>Автор книги</a>';
    FSeries.Caption := '<a>Название серии</a>';
    FGenres.Caption := '<a>Название жанра</a> <a>Название жанра</a> <a>Название жанра</a>';
  end;

  FTitle.SetBounds(0, 0, 300, 20);
  FAuthors.SetBounds(0, 20, 300, 20);
  FSerieLabel.SetBounds(0, 40, 70, 20);  FSeries.SetBounds(70, 40, 140, 20);
  FGenreLabel.SetBounds(0, 60, 70, 20);  FGenres.SetBounds(70, 60, 140, 20);
  FAnnotation.SetBounds(0, 80, 300, 120);
  FFb2Info.SetBounds(0, 80, 300, 120);

  Constraints.MinHeight := 150;
  FInfoPanel.OnResize := InfoPanelResize;
  FInfoViewport.OnResize := InfoPanelResize;
  LayoutControls;
end;

procedure TInfoPanel.SetBookAnnotation;
var
  i: Integer;
begin
  FAnnotation.Clear;
  FAnnotation.Visible := not FInfoPriority;


  // ---------------------------------------------
  if (book = nil) then
    Exit;

  try
    with book.Description.Titleinfo do
      for i := 0 to Annotation.p.Count - 1 do
        FAnnotation.Lines.Add(Annotation.p[i].OnlyText);

    FAnnotation.SelStart := 0;
    FAnnotation.SelLength := 0;
  except
    //
  end;
end;

procedure TInfoPanel.Resize;
begin
  if Assigned(FCover) then
    FCover.Width := GetCoverWidth(FCover.Height);
  LayoutControls;
  inherited;
end;

procedure TInfoPanel.CreateWnd;
begin
  inherited;
  LayoutControls;
end;

procedure TInfoPanel.InfoPanelResize(Sender: TObject);
begin
  LayoutControls;
end;

procedure TInfoPanel.CMFontChanged(var Message: TMessage);
begin
  inherited;
  LayoutControls;
end;

procedure TInfoPanel.LayoutControls;
var
  RowH, LinkH, Gap, LblW, W, H, Y, DetailH: Integer;
  TextRect: TRect;

  function LinkHeight(Link: TMHLLinkLabel; AvailableWidth: Integer): Integer;
  var
    IdealSize: TSize;
  begin
    Result := RowH;
    if HandleAllocated and (AvailableWidth > 0) and (Link.Caption <> '') then
    begin
      SendMessage(Link.Handle, WM_SETFONT, WPARAM(Link.Font.Handle), 0);
      IdealSize.cx := 0;
      IdealSize.cy := 0;
      SendMessage(Link.Handle, LM_GETIDEALSIZE, AvailableWidth, LPARAM(@IdealSize));
      Result := Max(RowH, IdealSize.cy + MulDiv(RowSpacing, CurrentPPI, 96));
    end;
  end;

begin
  if FUpdatingLayout or not Assigned(FFb2Info) or not Assigned(Parent) then
    Exit;

  W := FInfoPanel.ClientWidth;
  H := FInfoViewport.ClientHeight;
  if (W <= 0) or (H <= 0) then
    Exit;

  FUpdatingLayout := True;
  try
    // Bold captions do not inherit the parent font after Font.Style is set.
    FTitle.Font.Assign(FInfoPanel.Font);
    FTitle.Font.Style := [fsBold];
    FSerieLabel.Font.Assign(FInfoPanel.Font);
    FSerieLabel.Font.Style := [fsBold];
    FGenreLabel.Font.Assign(FInfoPanel.Font);
    FGenreLabel.Font.Style := [fsBold];
    FPublisherSerieLabel.Font.Assign(FInfoPanel.Font);
    FPublisherSerieLabel.Font.Style := [fsBold];

    Canvas.Font := FTitle.Font;
    RowH := Canvas.TextHeight('Wg') + MulDiv(RowSpacing, CurrentPPI, 96);
    Gap := MulDiv(AnnotationGap, CurrentPPI, 96);
    LblW := Max(MulDiv(LabelColumn, CurrentPPI, 96),
      Max(Canvas.TextWidth(FSerieLabel.Caption), Canvas.TextWidth(FGenreLabel.Caption)) + Gap);
    if FPublisherSerieLabel.Visible then
      LblW := Max(LblW, Canvas.TextWidth(FPublisherSerieLabel.Caption) + Gap);
    LblW := Min(LblW, W);

    Y := 0;
    FTitle.SetBounds(0, Y, W, RowH);
    Inc(Y, RowH);
    LinkH := LinkHeight(FAuthors, W);
    FAuthors.SetBounds(0, Y, W, LinkH);
    Inc(Y, LinkH);
    LinkH := LinkHeight(FSeries, W - LblW);
    FSerieLabel.SetBounds(0, Y, LblW, RowH);
    FSeries.SetBounds(LblW, Y, W - LblW, LinkH);
    Inc(Y, LinkH);
    if FPublisherSeriesLinks.Visible then
    begin
      LinkH := LinkHeight(FPublisherSeriesLinks, W - LblW);
      FPublisherSerieLabel.SetBounds(0, Y, LblW, RowH);
      FPublisherSeriesLinks.SetBounds(LblW, Y, W - LblW, LinkH);
      Inc(Y, LinkH);
    end
    else if FPublisherSeries.Visible then
    begin
      Canvas.Font := FPublisherSeries.Font;
      TextRect := Rect(0, 0, Max(1, W - LblW), 0);
      DrawText(Canvas.Handle, PChar(FPublisherSeries.Caption), Length(FPublisherSeries.Caption),
        TextRect, DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      LinkH := Max(RowH, TextRect.Height + MulDiv(RowSpacing, CurrentPPI, 96));
      FPublisherSerieLabel.SetBounds(0, Y, LblW, RowH);
      FPublisherSeries.SetBounds(LblW, Y, W - LblW, LinkH);
      Inc(Y, LinkH);
    end;
    LinkH := LinkHeight(FGenres, W - LblW);
    FGenreLabel.SetBounds(0, Y, LblW, RowH);
    FGenres.SetBounds(LblW, Y, W - LblW, LinkH);
    Inc(Y, LinkH + Gap);
    // Even a very short panel must not leave the old annotation over the links.
    DetailH := Max(0, H - Y);
    if (DetailH = 0) and (FAnnotation.Visible or FFb2Info.Visible) then
      DetailH := MulDiv(80, CurrentPPI, 96);
    FInfoPanel.Height := Y + DetailH;
    FAnnotation.SetBounds(0, Y, W, DetailH);
    FFb2Info.SetBounds(0, Y, W, DetailH);
  finally
    FUpdatingLayout := False;
  end;
  // A vertical scrollbar changes the available wrapping width once it appears.
  if FInfoPanel.ClientWidth <> W then LayoutControls;
end;

procedure TInfoPanel.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  LayoutControls;
end;

procedure TInfoPanel.OnAnnotationClicked(Sender: TObject);
begin
  FFb2Info.Visible := not FFb2Info.Visible;
  FAnnotation.Visible := not FAnnotation.Visible;
end;

procedure TInfoPanel.OnLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
begin
  if Sender = FAuthors then
  begin
    if Assigned(FOnAuthorLinkClicked) then
      FOnAuthorLinkClicked(Self, Link, LinkType);
  end
  else if Sender = FSeries then
  begin
    if Assigned(FOnSeriesLinkClicked) then
      FOnSeriesLinkClicked(Self, Link, LinkType);
  end
  else if Sender = FGenres then
  begin
    if Assigned(FOnGenreLinkClicked) then
      FOnGenreLinkClicked(Self, Link, LinkType);
  end
  else if Sender = FPublisherSeriesLinks then
  begin
    if Assigned(FOnPublisherSeriesLinkClicked) then
      FOnPublisherSeriesLinkClicked(Self, Link, LinkType);
  end
  else
    Assert(False);
end;

procedure TInfoPanel.SetBookInfo(
  const BookTitle: string;
  const Autors: string;
  const Series: string;
  const Genres: string
);
begin
  FInfoViewport.VertScrollBar.Position := 0;
  FTitle.Caption := BookTitle;
  FAuthors.Caption := Autors;
  // SysLink supports anchor tags; explicit line breaks must be plain CRLF.
  FSeries.Caption := StringReplace(Series, '<br>', sLineBreak, [rfReplaceAll, rfIgnoreCase]);
  FGenres.Caption := Genres;
  SetPublisherSeries('');
end;

procedure TInfoPanel.SetPublisherSeries(const Value: string);
begin
  FPublisherSeriesLinks.Caption := '';
  FPublisherSeriesLinks.Visible := False;
  FPublisherSeries.Caption := Trim(Value);
  FPublisherSeries.Visible := FPublisherSeries.Caption <> '';
  FPublisherSerieLabel.Visible := FPublisherSeries.Visible;
  LayoutControls;
end;

procedure TInfoPanel.SetPublisherSeriesLinks(const Value: string);
begin
  FPublisherSeries.Caption := '';
  FPublisherSeries.Visible := False;
  FPublisherSeriesLinks.Caption := StringReplace(Trim(Value), '<br>', sLineBreak, [rfReplaceAll, rfIgnoreCase]);
  FPublisherSeriesLinks.Visible := FPublisherSeriesLinks.Caption <> '';
  FPublisherSerieLabel.Visible := FPublisherSeriesLinks.Visible;
  LayoutControls;
end;


procedure TInfoPanel.SetFb2Info(book: IXMLFictionBook; const Folder, FileName: string);
var
  i: integer;
  tmpStr: string;

  procedure AddItem(listView: TListView; const Field: string; const Value: string; GroupID: integer = -1);
  var
    item: TListItem;
  begin
    if Trim(Value) <> '' then
    begin
      item := listView.Items.Add;
      item.Caption := Field;
      item.SubItems.Add(Value);
      item.GroupID := GroupID;
    end;
  end;

begin

  ffb2info.Clear;
  FFb2Info.Visible := FInfoPriority;

  with ffb2Info.Groups.Add do
  begin
    Header := rstrFileInfo;
    AddItem(ffb2Info, rstrFolder, Folder, GroupID);
    AddItem(ffb2Info, rstrFile, FileName, GroupID);
  end;

  // ---------------------------------------------
  if (book = nil) then   Exit;

  // ---------------------------------------------
  try
    with book.Description.Titleinfo, ffb2info.Groups.Add do
    begin
      Header := rstrGeneralInfo;

      AddItem(ffb2info, rstrTitle, Booktitle.Text, GroupID);

      for i := 0 to Author.Count - 1 do
      begin
        with Author[i] do
          tmpStr := FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(ffb2info, IfThen(i = 0, rstrAuthors), tmpStr, GroupID);
      end;

      for i := 0 to Sequence.Count - 1 do
      begin
        AddItem(ffb2info, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name + ' ' + IntToStr(Sequence[i].Number), GroupID);
      end;

      { TODO -oNickR -cUsability : показывать алиасы вместо внутренних имен }
      for i := 0 to Genre.Count - 1 do
      begin
        AddItem(ffb2info, IfThen(i = 0, rstrGenre), Genre[i], GroupID);
      end;

      AddItem(ffb2info, rstrKeywords, Keywords.Text, GroupID);
      AddItem(ffb2info, rstrDate, Date.Text, GroupID);
      AddItem(ffb2info, rstrBookLanguage, Lang, GroupID);
      AddItem(ffb2info, rstrSourceLanguage, Srclang, GroupID);

      for i := 0 to Translator.Count - 1 do
      begin
        with Translator[i] do
          tmpStr := FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(ffb2info, IfThen(i = 0, rstrTranslators), tmpStr, GroupID);
      end;
    end; //with
  except
    //
  end;

  // ---------------------------------------------
  try
    with book.Description.Srctitleinfo, ffb2info.Groups.Add do
    begin
      Header := rstrSrclInfo;

      AddItem(ffb2info, rstrTitle, Booktitle.Text, GroupID);

      for i := 0 to Author.Count - 1 do
      begin
        with Author[i] do
          tmpStr := FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(ffb2info, IfThen(i = 0, rstrAuthors), tmpStr, GroupID);
      end;

      for i := 0 to Sequence.Count - 1 do
      begin
        AddItem(ffb2info, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name + ' ' + IntToStr(Sequence[i].Number), GroupID);
      end;

      AddItem(ffb2info, rstrKeywords, Keywords.Text, GroupID);
      AddItem(ffb2info, rstrDate, Date.Text, GroupID);
      AddItem(ffb2info, rstrBookLanguage, Lang, GroupID);
      AddItem(ffb2info, rstrSourceLanguage, Srclang, GroupID);
    end; //with
  except
    //
  end;

  // ---------------------------------------------
  try
    with book.Description.Publishinfo, ffb2info.Groups.Add do
    begin
      Header := rstrPublisherInfo;

      AddItem(ffb2info, rstrTitle, Bookname.Text, GroupID);

      AddItem(ffb2info, rstrPublisher, Publisher.Text, GroupID);
      AddItem(ffb2info, rstrCity, City.Text, GroupID);
      AddItem(ffb2info, rstrYear, Year, GroupID);
      AddItem(ffb2info, rstrISBN, Isbn.Text, GroupID);

      { TODO -oNickR -cUsability : показывать номер в серии }
      for i := 0 to Sequence.Count - 1 do
        AddItem(ffb2info, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name + ' ' + IntToStr(Sequence[i].Number), GroupID);
    end; //with
  except
    //
  end;

  // ---------------------------------------------
  try
    with book.Description.Documentinfo, ffb2info.Groups.Add do
    begin
      Header := rstrOCRInfo;
      for i := 0 to Author.Count - 1 do
      begin
        with Author[i] do
          tmpStr := FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(ffb2info, IfThen(i = 0, rstrAuthors), tmpStr, GroupID);
      end;

      AddItem(ffb2info, rstrProgram, Programused.Text, GroupID);
      AddItem(ffb2info, rstrDate, Date.Text, GroupID);
      AddItem(ffb2info, rstrID, book.Description.Documentinfo.Id, GroupID);
      AddItem(ffb2info, rstrVersion, Version, GroupID);

      for i := 0 to Srcurl.Count - 1 do
        AddItem(ffb2info, IfThen(i = 0, rstrSource), Srcurl[i], GroupID);

      AddItem(ffb2info, rstrSourceAuthor, Srcocr.Text, GroupID);

      for i := 0 to History.p.Count - 1 do
        AddItem(ffb2info, IfThen(i = 0, rstrHistory), History.p[i].OnlyText, GroupID);
    end; //with
  except
    //
  end;

end;

procedure TInfoPanel.SetInfoPriority(const Value: Boolean);
begin
  FInfoPriority := Value;

  FFb2Info.Visible := FInfoPriority;
  FAnnotation.Visible := not FInfoPriority;
end;

procedure TInfoPanel.SetBookCover(
  BookCover: TGraphic
  );
begin
  FCover.Picture.Assign(BookCover);
end;


procedure TInfoPanel.Clear;
begin
  FInfoViewport.VertScrollBar.Position := 0;
  FTitle.Caption := '';
  FAuthors.Caption := '';
  FSeries.Caption := '';
  FGenres.Caption := '';
  FAnnotation.Lines.Clear;
  FFb2Info.Items.Clear;
  FCover.Picture.Assign(nil);
  SetPublisherSeries('');
end;


function TInfoPanel.GetShowAnnotation: Boolean;
begin
  Result := FAnnotation.Visible;
end;

procedure TInfoPanel.SetShowAnnotation(const Value: Boolean);
begin
  if GetShowAnnotation <> Value then
  begin
    FAnnotation.Visible := Value;
    if Value then
      Constraints.MinHeight := 150
    else
      Constraints.MinHeight := 80;
  end;
end;

function TInfoPanel.GetShowCover: boolean;
begin
  Result := FCover.Visible;
end;

procedure TInfoPanel.SetShowCover(const Value: boolean);
begin
  if GetShowCover <> Value then
  begin
    FCover.Visible := Value;
    UpdateLinkTexts;
  end;
end;

procedure TInfoPanel.UpdateLinkTexts;
begin
  //
  // TODO : задача этого метода превратить обрезанные линки в "Link Link и пр.", т е убрать невлезающие и добавить " и пр."
  //
end;

end.
