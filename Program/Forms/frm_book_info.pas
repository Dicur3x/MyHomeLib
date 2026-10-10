(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors Oleksiy Penkov   oleksiy.penkov@gmail.com
  *         Nick Rymanov     nrymanov@gmail.com
  * Created
  * Description
  *
  * $Id: frm_book_info.pas 1164 2014-05-03 08:47:22Z koreec $
  *
  * History
  * NickR 02.03.2010    Код переформатирован
  *                     Отдельная закладка для свойств файла
  *
  ****************************************************************************** *)

unit frm_book_info;

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
  xmldom,
  XMLIntf,
  msxmldom,
  XMLDoc,
  ExtCtrls,
  StdCtrls,
  ComCtrls,
  unit_Globals,
  Menus,
  ActnList, System.Actions, frm_AuthorInformation;

type
  TReviewDownloadThread = class;

  TfrmBookDetails = class(TForm)
    pcBookInfo: TPageControl;
    tsInfo: TTabSheet;
    tsReview: TTabSheet;
    mmShort: TMemo;
    imgCover: TImage;
    pnButtons: TPanel;
    btnClose: TButton;
    btnLoadReview: TButton;
    mmReview: TMemo;
    btnClearReview: TButton;
    pnTitle: TPanel;
    lblAuthors: TLabel;
    lvInfo: TListView;
    lblTitle: TLabel;
    pnReviewButtons: TPanel;
    tsFileInfo: TTabSheet;
    lvFileInfo: TListView;
    pmBookInfo: TPopupMenu;
    alBookInfo: TActionList;
    acCopyValue: TAction;
    miCopyValue: TMenuItem;
    tsAnnotation: TTabSheet;
    mmoAnnotation: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure mmReviewChange(Sender: TObject);
    procedure btnLoadReviewClick(Sender: TObject);
    procedure btnClearReviewClick(Sender: TObject);
    procedure acCopyValueExecute(Sender: TObject);
    procedure acCopyValueUpdate(Sender: TObject);

  private
    FUrl: string;
    FReviewChanged: Boolean;
    FWorker: TReviewDownloadThread;
    FReviewStatus: TLabel;
    FAuthorTab: TTabSheet;
    FAuthorInformation: TAuthorInformationPanel;
    FReviewReadOnly, FAnnotationReadOnly: Boolean;
    procedure FinishDownload(Sender: TObject);
    procedure PageChanged(Sender: TObject);
    function GetReview: string;
    procedure SetReview(const Value: string);
    function GetAnnotation: string;
    procedure SetAnnotation(const Value: string);

  protected
    procedure DoCreate; override;

  public
    destructor Destroy; override;
    property AuthorInformation: TAuthorInformationPanel read FAuthorInformation;
    property AuthorTab: TTabSheet read FAuthorTab;
    property ReviewStatus: TLabel read FReviewStatus;
    property Downloading: TReviewDownloadThread read FWorker;
    procedure AllowOnlineReview(const URL: string);
    procedure Download;

    procedure FillBookInfo(bookInfo: TBookRecord; bookStream: TStream);

    property Review: string read GetReview write SetReview;
    property Annotation: string read GetAnnotation write SetAnnotation;
    property ReviewChanged: Boolean read FReviewChanged write FReviewChanged;
    property URL: string read FUrl write FUrl;
  end;

  TReviewDownloadThread = class(TThread)
  private
    FUrl: string;
  protected
    procedure Execute; override;
  public
    Review, Annotation: TStringList;
    ErrorText: string;
    constructor Create(const URL: string);
    destructor Destroy; override;
  end;

procedure DownloadReview(Form: TfrmBookDetails; const URL: string);

var
  frmBookDetails: TfrmBookDetails;

implementation

uses
  Clipbrd,
  FictionBook_21,
  unit_Helpers,
  unit_ReviewParser,
  StrUtils,
  unit_MHLHelpers,
  unit_FB2Utils,
  unit_Localization;


{$R *.dfm}

procedure TfrmBookDetails.DoCreate;
begin
  inherited;
  Localize(Self);
end;

procedure TfrmBookDetails.FormCreate(Sender: TObject);
begin
  Font.Name := 'Segoe UI'; Font.Size := 9; DoubleBuffered := True;
  BorderStyle := bsSizeable; ClientWidth := 720; ClientHeight := 520;
  Constraints.MinWidth := 640; Constraints.MinHeight := 440;
  FAuthorTab := TTabSheet.Create(Self); FAuthorTab.PageControl := pcBookInfo;
  FAuthorTab.Caption := 'Об авторе';
  FAuthorInformation := TAuthorInformationPanel.Create(Self);
  FAuthorInformation.Parent := FAuthorTab; FAuthorInformation.Align := alClient;
  pcBookInfo.OnChange := PageChanged;
  FReviewStatus := TLabel.Create(Self); FReviewStatus.Parent := tsReview;
  FReviewStatus.AutoSize := False; FReviewStatus.Align := alTop;
  FReviewStatus.WordWrap := True; FReviewStatus.Height := 38;
  FReviewStatus.AlignWithMargins := True; FReviewStatus.Margins.Left := 8;
  FReviewStatus.Caption := 'Сохранённые отзывы. Загрузка с сайта выполняется по кнопке.';
  tsReview.Caption := 'Отзывы';
  lvFileInfo.ShowColumnHeaders := False;
  lvInfo.ShowColumnHeaders := False;
  FReviewChanged := False;

end;

procedure TfrmBookDetails.acCopyValueExecute(Sender: TObject);
begin
  if pcBookInfo.ActivePage = tsFileInfo then
  begin
    Assert(Assigned(lvFileInfo.Selected));
    Clipboard.AsText := lvFileInfo.Selected.SubItems[0];
  end
  else if pcBookInfo.ActivePage = tsInfo then
  begin
    Assert(Assigned(lvInfo.Selected));
    Clipboard.AsText := lvInfo.Selected.SubItems[0];
  end;
end;

procedure TfrmBookDetails.acCopyValueUpdate(Sender: TObject);
begin
  if pcBookInfo.ActivePage = tsFileInfo then
  begin
    acCopyValue.Enabled := Assigned(lvFileInfo.Selected);
  end
  else if pcBookInfo.ActivePage = tsInfo then
  begin
    acCopyValue.Enabled := Assigned(lvInfo.Selected);
  end
  else
    acCopyValue.Enabled := False;
end;

procedure TfrmBookDetails.PageChanged(Sender: TObject);
begin
  if pcBookInfo.ActivePage = FAuthorTab then FAuthorInformation.Activate;
end;

destructor TfrmBookDetails.Destroy;
begin
  // The worker owns its lists and HTTP client; it never retains the form.
  // Detaching the callback makes closing during a request immediate and safe.
  if Assigned(FWorker) then
  begin FWorker.OnTerminate := nil; FWorker.Terminate; FWorker := nil; end;
  inherited;
end;

procedure TfrmBookDetails.AllowOnlineReview(const URL: string);
begin
  FUrl := URL;
  pnReviewButtons.Visible := True;
  btnLoadReview.Enabled := IsLibraryReviewURL(URL);
  if not btnLoadReview.Enabled then
    FReviewStatus.Caption := 'Для этой книги нет адреса отзывов на сайте источника.';
end;

procedure TfrmBookDetails.Download;
begin
  if Assigned(FWorker) or not IsLibraryReviewURL(FUrl) then Exit;
  btnLoadReview.Enabled := False; btnClearReview.Enabled := False;
  FReviewReadOnly := mmReview.ReadOnly; FAnnotationReadOnly := mmoAnnotation.ReadOnly;
  mmReview.ReadOnly := True; mmoAnnotation.ReadOnly := True;
  FReviewStatus.Caption := 'Загрузка отзывов с сайта коллекции...';
  FWorker := TReviewDownloadThread.Create(FUrl);
  FWorker.OnTerminate := FinishDownload; FWorker.Start;
end;

procedure TfrmBookDetails.FinishDownload(Sender: TObject);
var Worker: TReviewDownloadThread;
begin
  Worker := FWorker; FWorker := nil;
  if Worker.ErrorText <> '' then
    FReviewStatus.Caption := 'Не удалось загрузить отзывы: ' + Worker.ErrorText
  else
  begin
    if Worker.Review.Count > 0 then mmReview.Lines := Worker.Review;
    if Worker.Annotation.Count > 0 then mmoAnnotation.Lines := Worker.Annotation;
    if Worker.Review.Count = 0 then
      FReviewStatus.Caption := 'На странице книги нет отзывов. Сохранённый текст оставлен.'
    else FReviewStatus.Caption := 'Отзывы загружены с сайта коллекции.';
  end;
  mmReview.ReadOnly := FReviewReadOnly; mmoAnnotation.ReadOnly := FAnnotationReadOnly;
  btnLoadReview.Enabled := True; btnClearReview.Enabled := True;
end;

procedure TfrmBookDetails.FormShow(Sender: TObject);
begin
  // TODO перенести под конец заполнения ?
  lvFileInfo.AutosizeColumn(0);
  lvFileInfo.AutosizeColumn(1);
  lvInfo.AutosizeColumn(0);
  lvInfo.AutosizeColumn(1);
end;

function TfrmBookDetails.GetAnnotation: string;
begin
  Result := mmoAnnotation.Lines.Text;
end;

function TfrmBookDetails.GetReview: string;
begin
  Result := mmReview.Lines.Text;
end;

procedure TfrmBookDetails.mmReviewChange(Sender: TObject);
begin
  FReviewChanged := True;
end;

procedure TfrmBookDetails.btnClearReviewClick(Sender: TObject);
begin
  mmReview.Clear;
  FReviewChanged := True;
end;

procedure TfrmBookDetails.btnLoadReviewClick(Sender: TObject);
begin
  Download;
end;

procedure TfrmBookDetails.SetAnnotation(const Value: string);
begin
  mmoAnnotation.Lines.Text := Value;
end;

procedure TfrmBookDetails.SetReview(const Value: string);
begin
  // Showing a saved review is not an edit.
  mmReview.OnChange := nil;
  try mmReview.Lines.Text := Value;
  finally mmReview.OnChange := mmReviewChange; end;
end;

procedure TfrmBookDetails.FillBookInfo(bookInfo: TBookRecord; bookStream: TStream);
var
  book: IXMLFictionBook;
  i: integer;
  imgBookCover: TGraphic;
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
  //
  // Покажем информацию из TBookRecord
  //
  lblTitle.Caption := bookInfo.Title;
  lblAuthors.Caption := bookInfo.Authors[0].GetFullName;

  with lvFileInfo.Groups.Add do
  begin
    Header := rstrFileInfo;
    AddItem(lvFileInfo, rstrFolder, bookInfo.Folder, GroupID);
    AddItem(lvFileInfo, rstrFile, bookInfo.FileName, GroupID);
    AddItem(lvFileInfo, rstrSize, GetFormattedSize(bookInfo.Size, True), GroupID);
    AddItem(lvFileInfo, rstrAdded, DateToStr(bookInfo.Date), GroupID);
  end;

  //
  // Метаданные из каталога metabib показываем только при их наличии, чтобы книги
  // из INPX/FB2 не получали пустую группу.
  //
  if (bookInfo.Translators <> '') or (bookInfo.Publisher <> '') or
    (bookInfo.City <> '') or (bookInfo.PubYear <> 0) or (bookInfo.ISBN <> '') then
  begin
    with lvFileInfo.Groups.Add do
    begin
      Header := rstrPublisherInfo;
      AddItem(lvFileInfo, rstrTranslators, bookInfo.Translators, GroupID);
      AddItem(lvFileInfo, rstrPublisher, bookInfo.Publisher, GroupID);
      AddItem(lvFileInfo, rstrCity, bookInfo.City, GroupID);
      if bookInfo.PubYear <> 0 then
        AddItem(lvFileInfo, rstrYear, IntToStr(bookInfo.PubYear), GroupID);
      AddItem(lvFileInfo, rstrISBN, bookInfo.ISBN, GroupID);
    end;
  end;

  { TODO -oNickR -cUsability : для онлайн коллекций необходимо показывать следующие поля }
  // libID: string;    ???
  // LibRate: Integer;  ???
  // URI: string;       ???

  //
  // Покажем информацию из книги
  // TODO : здесь на самом деле нужно более общее решение. Может со временем мы научимся вытаскивать инфу из pdf и других форматов
  //
  if not Assigned(bookStream) or (bookStream.Size = 0) then
  begin
    tsInfo.TabVisible := False;
    Exit;
  end;

  // FS.SaveToFile('C:\temp\book.xml');
  try
    book := LoadFB2Description(bookStream);

    //
    // покажем обложку (если есть)
    //
    imgBookCover := GetBookCover(book);
    if Assigned(imgBookCover) then
    begin
      try
        imgCover.Picture.Assign(imgBookCover);
        imgCover.Visible := True;
      finally
        imgBookCover.Free;
      end;
    end
    else
      imgCover.Visible := False;

    // ---------------------------------------------
    with book.Description.Titleinfo, lvInfo.Groups.Add do
    begin
      Header := rstrGeneralInfo;

      AddItem(lvInfo, rstrTitle, Booktitle.Text, GroupID);

      for i := 0 to Author.Count - 1 do
      begin
        with Author[i] do
          tmpStr := TAuthorData.FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(lvInfo, IfThen(i = 0, rstrAuthors), tmpStr, GroupID);
      end;

      { TODO -oNickR -cUsability : показывать номер в серии }
      for i := 0 to Sequence.Count - 1 do
      begin
        AddItem(lvInfo, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name, GroupID);
      end;

      { TODO -oNickR -cUsability : показывать алиасы вместо внутренних имен }
      for i := 0 to Genre.Count - 1 do
      begin
        AddItem(lvInfo, IfThen(i = 0, rstrGenre), Genre[i], GroupID);
      end;

      AddItem(lvInfo, rstrKeywords, Keywords.Text, GroupID);
      AddItem(lvInfo, rstrDate, Date.Text, GroupID);
      AddItem(lvInfo, rstrBookLanguage, Lang, GroupID);
      AddItem(lvInfo, rstrSourceLanguage, Srclang, GroupID);

      for i := 0 to Translator.Count - 1 do
      begin
        with Translator[i] do
          tmpStr := TAuthorData.FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(lvInfo, IfThen(i = 0, rstrTranslators), tmpStr, GroupID);
      end;
    end;

    // ---------------------------------------------
    with book.Description.Publishinfo, lvInfo.Groups.Add do
    begin
      Header := rstrPublisherInfo;

      AddItem(lvInfo, rstrTitle, Bookname.Text, GroupID);

      AddItem(lvInfo, rstrPublisher, Publisher.Text, GroupID);
      AddItem(lvInfo, rstrCity, City.Text, GroupID);
      AddItem(lvInfo, rstrYear, Year, GroupID);
      AddItem(lvInfo, rstrISBN, Isbn.Text, GroupID);

      { TODO -oNickR -cUsability : показывать номер в серии }
      for i := 0 to Sequence.Count - 1 do
      begin
        AddItem(lvInfo, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name, GroupID);
      end;
    end;

    // ---------------------------------------------
    with book.Description.Documentinfo, lvInfo.Groups.Add do
    begin
      Header := rstrOCRInfo;
      for i := 0 to Author.Count - 1 do
      begin
        with Author[i] do
          tmpStr := TAuthorData.FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(lvInfo, IfThen(i = 0, rstrAuthors), tmpStr, GroupID);
      end;

      AddItem(lvInfo, rstrProgram, Programused.Text, GroupID);
      AddItem(lvInfo, rstrDate, Date.Text, GroupID);
      AddItem(lvInfo, rstrID, book.Description.Documentinfo.Id, GroupID);
      AddItem(lvInfo, rstrVersion, Version, GroupID);

      for i := 0 to Srcurl.Count - 1 do
      begin
        AddItem(lvInfo, IfThen(i = 0, rstrSource), Srcurl[i], GroupID);
      end;
      AddItem(lvInfo, rstrSourceAuthor, Srcocr.Text, GroupID);

      for i := 0 to History.p.Count - 1 do
        AddItem(lvInfo, IfThen(i = 0, rstrHistory), History.p[i].OnlyText, GroupID);
    end;

    // ---------------------------------------------
    { TODO -oNickR -cUsability : может стоит добавлять параграфы как есть? }
    with book.Description.Titleinfo do
    begin
      for i := 0 to Annotation.p.Count - 1 do
        mmShort.Lines.Add(Annotation.p[i].OnlyText);
    end;
    mmShort.Visible := (mmShort.Lines.Text <> '');
  except
    //
    Assert(False);
  end;
end;

constructor TReviewDownloadThread.Create(const URL: string);
begin
  inherited Create(True); FreeOnTerminate := True; FUrl := URL;
  Review := TStringList.Create; Annotation := TStringList.Create;
end;

destructor TReviewDownloadThread.Destroy;
begin
  Review.Free; Annotation.Free; inherited;
end;

procedure TReviewDownloadThread.Execute;
var Parser: TReviewParser;
begin
  try
    Parser := TReviewParser.Create;
    try Parser.Parse(FUrl, Review, Annotation); finally Parser.Free; end;
  except on E: Exception do ErrorText := E.Message; end;
end;

procedure DownloadReview(Form: TfrmBookDetails; const URL: string);
begin
  Form.AllowOnlineReview(URL); Form.Download;
end;

end.
