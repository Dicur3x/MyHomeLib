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
  ActnList, System.Actions, frm_AuthorInformation, unit_ReviewParser;

type
  TReviewDownloadThread = class;
  TBookTextSource = (btsReviews, btsSiteAnnotation, btsFileAnnotation);

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
    pnAnnotationSources: TPanel;
    lblAnnotationState: TLabel;
    btnAnnotationFile: TButton;
    btnAnnotationSite: TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure mmReviewChange(Sender: TObject);
    procedure btnLoadReviewClick(Sender: TObject);
    procedure btnClearReviewClick(Sender: TObject);
    procedure btnAnnotationFileClick(Sender: TObject);
    procedure btnAnnotationSiteClick(Sender: TObject);
    procedure acCopyValueExecute(Sender: TObject);
    procedure acCopyValueUpdate(Sender: TObject);

  private
    FUrl: string;
    FReviewChanged: Boolean;
    FWorker: TReviewDownloadThread;
    FReviewStatus: TLabel;
    FReviewTimer: TTimer;
    FAuthorTab: TTabSheet;
    FAuthorInformation: TAuthorInformationPanel;
    FReviewReadOnly, FAnnotationReadOnly, FHasFileSource: Boolean;
    FAnnotationBook: TBookRecord;
    FFileAnnotation: string;
    FInfoNotify, FFileNotify: TWndMethod;
    procedure StartBookTextRequest(Source: TBookTextSource);
    function RequestStatus: TLabel;
    procedure RefreshAnnotationButtons;
    procedure FinishDownload(Sender: TObject);
    procedure ReviewProgress(Sender: TObject);
    procedure PageChanged(Sender: TObject);
    procedure InfoNotify(var Message: TMessage);
    procedure FileNotify(var Message: TMessage);
    function DrawInfoGroup(var Message: TMessage; List: TListView): Boolean;
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
    procedure ConfigureDescription(const Book: TBookRecord; Editable, HasLocalSource: Boolean);

    procedure FillBookInfo(bookInfo: TBookRecord; bookStream: TStream);

    property Review: string read GetReview write SetReview;
    property Annotation: string read GetAnnotation write SetAnnotation;
    property ReviewChanged: Boolean read FReviewChanged write FReviewChanged;
    property URL: string read FUrl write FUrl;
  end;

  TReviewDownloadThread = class(TThread)
  private
    FUrl: string;
    FParser: TReviewParser;
    FBook: TBookRecord;
    FSource: TBookTextSource;
    procedure ReadFileAnnotation;
  protected
    procedure Execute; override;
  public
    Review, Annotation: TStringList;
    ErrorText: string;
    constructor Create(const URL: string; Source: TBookTextSource = btsReviews);
    constructor CreateFromFile(const Book: TBookRecord);
    destructor Destroy; override;
    procedure Cancel;
    property Parser: TReviewParser read FParser;
    property Source: TBookTextSource read FSource;
    function Cancelled: Boolean;
  end;

procedure DownloadReview(Form: TfrmBookDetails; const URL: string);

var
  frmBookDetails: TfrmBookDetails;

implementation

uses
  Clipbrd,
  FictionBook_21,
  unit_Helpers,
  StrUtils,
  unit_MHLHelpers,
  unit_FB2Utils,
  unit_Localization, Winapi.CommCtrl, unit_MHLTheme, Winapi.ActiveX, System.Win.ComObj,
  unit_PublisherSeriesSource, unit_PackageBookMetadata, unit_FB2PublisherMetadataReader;


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
  FReviewTimer := TTimer.Create(Self); FReviewTimer.Enabled := False;
  FReviewTimer.Interval := 200; FReviewTimer.OnTimer := ReviewProgress;
  tsReview.Caption := 'Отзывы';
  lvFileInfo.ShowColumnHeaders := False;
  lvInfo.ShowColumnHeaders := False;
  lvInfo.StyleElements := []; lvFileInfo.StyleElements := [];
  if MHLThemeDark then
  begin ApplyMHLControlTheme(lvInfo); ApplyMHLControlTheme(lvFileInfo); end;
  FInfoNotify := tsInfo.WindowProc; tsInfo.WindowProc := InfoNotify;
  FFileNotify := tsFileInfo.WindowProc; tsFileInfo.WindowProc := FileNotify;
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
  if Assigned(FReviewTimer) then FReviewTimer.Enabled := False;
  if Assigned(FInfoNotify) then tsInfo.WindowProc := FInfoNotify;
  if Assigned(FFileNotify) then tsFileInfo.WindowProc := FFileNotify;
  // The worker owns its lists and HTTP client; it never retains the form.
  // Detaching the callback makes closing during a request immediate and safe.
  if Assigned(FWorker) then
  begin FWorker.Cancel; FWorker.OnTerminate := nil; FWorker := nil; end;
  inherited;
end;

procedure TfrmBookDetails.AllowOnlineReview(const URL: string);
begin
  FUrl := URL;
  pnReviewButtons.Visible := True;
  btnLoadReview.Enabled := IsLibraryReviewURL(URL);
  RefreshAnnotationButtons;
  if not btnLoadReview.Enabled then
    FReviewStatus.Caption := 'Для этой книги нет адреса отзывов на сайте источника.';
end;

procedure TfrmBookDetails.ConfigureDescription(const Book: TBookRecord; Editable, HasLocalSource: Boolean);
begin
  FAnnotationBook := Book;
  FHasFileSource := HasLocalSource;
  mmoAnnotation.ReadOnly := not Editable;
  if not Editable then lblAnnotationState.Caption := 'Описание доступно только для чтения.';
  RefreshAnnotationButtons;
end;

procedure TfrmBookDetails.RefreshAnnotationButtons;
begin
  btnAnnotationFile.Enabled := not mmoAnnotation.ReadOnly and FHasFileSource;
  btnAnnotationSite.Enabled := not mmoAnnotation.ReadOnly and IsLibraryReviewURL(FUrl);
  btnAnnotationFile.Caption := 'Из файла';
  btnAnnotationSite.Caption := 'С сайта';
  if Assigned(FWorker) and (FWorker.Source <> btsReviews) then
    if FWorker.Source = btsFileAnnotation then
    begin btnAnnotationFile.Enabled := True; btnAnnotationFile.Caption := 'Отменить'; end
    else
    begin btnAnnotationSite.Enabled := True; btnAnnotationSite.Caption := 'Отменить'; end;
end;

function TfrmBookDetails.RequestStatus: TLabel;
begin
  if Assigned(FWorker) and (FWorker.Source <> btsReviews) then Result := lblAnnotationState
  else Result := FReviewStatus;
end;

procedure TfrmBookDetails.Download;
begin
  StartBookTextRequest(btsReviews);
end;

procedure TfrmBookDetails.StartBookTextRequest(Source: TBookTextSource);
begin
  if Assigned(FWorker) then Exit;
  if Source = btsFileAnnotation then
  begin
    if mmoAnnotation.ReadOnly or not FHasFileSource then Exit;
    if FFileAnnotation <> '' then
    begin
      mmoAnnotation.Lines.Text := FFileAnnotation;
      lblAnnotationState.Caption := 'Описание взято из файла. Его можно отредактировать.';
      Exit;
    end;
    FWorker := TReviewDownloadThread.CreateFromFile(FAnnotationBook);
  end
  else
  begin
    if not IsLibraryReviewURL(FUrl) or ((Source=btsSiteAnnotation) and mmoAnnotation.ReadOnly) then Exit;
    FWorker := TReviewDownloadThread.Create(FUrl, Source);
  end;
  FReviewReadOnly := mmReview.ReadOnly; FAnnotationReadOnly := mmoAnnotation.ReadOnly;
  mmReview.ReadOnly := True; mmoAnnotation.ReadOnly := True;
  btnLoadReview.Caption := 'Отменить'; btnClearReview.Enabled := False;
  case Source of
    btsReviews: FReviewStatus.Caption := 'Загрузка отзывов с сайта коллекции…';
    btsSiteAnnotation: lblAnnotationState.Caption := 'Загрузка описания с сайта…';
    btsFileAnnotation: lblAnnotationState.Caption := 'Чтение описания из файла…';
  end;
  RefreshAnnotationButtons;
  FReviewTimer.Enabled := True;
  FWorker.OnTerminate := FinishDownload; FWorker.Start;
end;

procedure TfrmBookDetails.ReviewProgress(Sender: TObject);
begin
  if not Assigned(FWorker) or not Assigned(FWorker.Parser) then Exit;
  FWorker.Parser.CheckDeadline;
  if FWorker.Parser.Cancelled then Exit;
  case FWorker.Parser.Phase of
    2: RequestStatus.Caption := 'Повторный запрос к сайту (2 из 2). Сохранённый текст пока не меняется.';
    3: RequestStatus.Caption := 'Сайт временно не ответил. Через секунду повторим запрос один раз.';
  end;
end;

procedure TfrmBookDetails.FinishDownload(Sender: TObject);
var Worker: TReviewDownloadThread; Status: TLabel;
begin
  FReviewTimer.Enabled := False;
  Status := RequestStatus;
  Worker := FWorker; FWorker := nil;
  if Worker.Cancelled then
  begin
    if Assigned(Worker.Parser) and (Worker.Parser.Expired <> 0) then
      Status.Caption := 'Сайт не ответил вовремя. Сохранённый текст оставлен. Попробуйте позже.'
    else Status.Caption := 'Загрузка отменена. Сохранённый текст оставлен.';
  end
  else if Worker.ErrorText <> '' then
  begin
    if Worker.Source = btsReviews then Status.Caption := 'Не удалось загрузить отзывы. '
    else Status.Caption := 'Не удалось получить описание. ';
    Status.Caption := Status.Caption + Worker.ErrorText + ' Сохранённый текст оставлен.';
  end
  else if Worker.Source = btsReviews then
  begin
    if Worker.Review.Count > 0 then
      if FReviewReadOnly then Review := Worker.Review.Text
      else mmReview.Lines := Worker.Review;
    if not FAnnotationReadOnly and (Annotation.Trim = '') and (Worker.Annotation.Count > 0) then
      mmoAnnotation.Lines := Worker.Annotation;
    if Worker.Review.Count = 0 then
      Status.Caption := 'На странице книги нет отзывов. Сохранённый текст оставлен.'
    else Status.Caption := 'Отзывы загружены с сайта коллекции.';
  end
  else if Worker.Annotation.Count = 0 then
  begin
    if Worker.Source = btsFileAnnotation then Status.Caption := 'В файле нет описания.'
    else Status.Caption := 'На сайте нет описания этой книги.';
  end
  else
  begin
    mmoAnnotation.Lines := Worker.Annotation;
    if Worker.Source = btsFileAnnotation then
      Status.Caption := 'Описание взято из файла. Его можно отредактировать.'
    else Status.Caption := 'Описание взято с сайта. Его можно отредактировать.';
  end;
  mmReview.ReadOnly := FReviewReadOnly; mmoAnnotation.ReadOnly := FAnnotationReadOnly;
  btnLoadReview.Enabled := IsLibraryReviewURL(FUrl); btnClearReview.Enabled := True;
  btnLoadReview.Caption := 'Повторить';
  RefreshAnnotationButtons;
end;

function TfrmBookDetails.DrawInfoGroup(var Message: TMessage; List: TListView): Boolean;
var Draw: PNMLVCustomDraw; Bounds: TRect; Group: TListGroup; I, Saved: Integer;
  Background: HBRUSH;
begin
  Result := False;
  if not MHLThemeDark or (Message.Msg <> WM_NOTIFY) then Exit;
  Draw := PNMLVCustomDraw(Message.LParam);
  if (Draw = nil) or (Draw.nmcd.hdr.code <> NM_CUSTOMDRAW) or
    (Draw.nmcd.hdr.hwndFrom <> List.Handle) or
    (Draw.nmcd.dwDrawStage <> CDDS_PREPAINT) or (Draw.dwItemType <> LVCDI_GROUP) then Exit;
  Group := nil;
  for I := 0 to List.Groups.Count - 1 do
    if List.Groups[I].GroupID = Integer(Draw.nmcd.dwItemSpec) then begin Group := List.Groups[I]; Break; end;
  if Group = nil then Exit;
  // Group captions retain native light-theme blue under a VCL dark style.
  // Draw just the header; native item rendering and accessibility stay intact.
  Bounds := Rect(0,LVGGR_HEADER,0,0);
  if SendMessage(List.Handle,LVM_GETGROUPRECT,Group.GroupID,LPARAM(@Bounds))=0 then Exit;
  Saved := SaveDC(Draw.nmcd.hdc);
  Background := CreateSolidBrush(ColorToRGB(List.Color));
  try
    FillRect(Draw.nmcd.hdc, Bounds, Background);
    SelectObject(Draw.nmcd.hdc, List.Font.Handle);
    SetTextColor(Draw.nmcd.hdc, ColorToRGB(MHLThemeLink)); SetBkMode(Draw.nmcd.hdc, TRANSPARENT);
    InflateRect(Bounds, -MulDiv(6,List.CurrentPPI,96), 0);
    DrawText(Draw.nmcd.hdc, PChar(Group.Header), Length(Group.Header), Bounds,
      DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
  finally DeleteObject(Background); RestoreDC(Draw.nmcd.hdc, Saved); end;
  Message.Result := CDRF_SKIPDEFAULT; Result := True;
end;

procedure TfrmBookDetails.InfoNotify(var Message: TMessage);
begin
  if DrawInfoGroup(Message,lvInfo) then Exit;
  FInfoNotify(Message);
  if MHLThemeDark and (Message.Msg=WM_NOTIFY) and
    (PNMHdr(Message.LParam)^.code=NM_CUSTOMDRAW) and
    (PNMLVCustomDraw(Message.LParam)^.nmcd.dwDrawStage=CDDS_PREPAINT) then
    Message.Result := Message.Result or CDRF_NOTIFYITEMDRAW;
end;

procedure TfrmBookDetails.FileNotify(var Message: TMessage);
begin
  if DrawInfoGroup(Message,lvFileInfo) then Exit;
  FFileNotify(Message);
  if MHLThemeDark and (Message.Msg=WM_NOTIFY) and
    (PNMHdr(Message.LParam)^.code=NM_CUSTOMDRAW) and
    (PNMLVCustomDraw(Message.LParam)^.nmcd.dwDrawStage=CDDS_PREPAINT) then
    Message.Result := Message.Result or CDRF_NOTIFYITEMDRAW;
end;

procedure TfrmBookDetails.FormShow(Sender: TObject);
begin
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
  if Assigned(FWorker) then
  begin
    FWorker.Cancel;
    btnLoadReview.Enabled := False;
    RequestStatus.Caption := 'Отмена запроса… Сохранённый текст не меняется.';
  end
  else Download;
end;

procedure TfrmBookDetails.btnAnnotationFileClick(Sender: TObject);
begin
  if Assigned(FWorker) then
  begin btnAnnotationFile.Enabled := False; btnLoadReviewClick(Sender); end
  else StartBookTextRequest(btsFileAnnotation);
end;

procedure TfrmBookDetails.btnAnnotationSiteClick(Sender: TObject);
begin
  if Assigned(FWorker) then
  begin btnAnnotationSite.Enabled := False; btnLoadReviewClick(Sender); end
  else StartBookTextRequest(btsSiteAnnotation);
end;

procedure TfrmBookDetails.SetAnnotation(const Value: string);
begin
  mmoAnnotation.OnChange := nil;
  try mmoAnnotation.Lines.Text := Value;
  finally mmoAnnotation.OnChange := mmReviewChange; end;
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
  lblTitle.Caption := bookInfo.Title;
  lblAuthors.Caption := bookInfo.Authors[0].GetFullName;
  lvFileInfo.Items.Clear; lvFileInfo.Groups.Clear;

  with lvFileInfo.Groups.Add do
  begin
    Header := rstrFileInfo;
    AddItem(lvFileInfo, rstrFolder, bookInfo.Folder, GroupID);
    AddItem(lvFileInfo, rstrFile, bookInfo.FileName, GroupID);
    AddItem(lvFileInfo, rstrSize, GetFormattedSize(bookInfo.Size, True), GroupID);
    AddItem(lvFileInfo, rstrAdded, DateToStr(bookInfo.Date), GroupID);
  end;

  if Trim(bookInfo.KeyWords) <> '' then
    with lvFileInfo.Groups.Add do
    begin
      Header := 'Каталог';
      AddItem(lvFileInfo, rstrKeywords, bookInfo.KeyWords, GroupID);
    end;

  // Метаданные из каталога metabib показываем только при их наличии, чтобы книги
  // из INPX/FB2 не получали пустую группу.
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


  if not Assigned(bookStream) or (bookStream.Size = 0) then
  begin
    tsInfo.TabVisible := False;
    Exit;
  end;

  try
    book := LoadFB2Description(bookStream);
    FFileAnnotation := GetBookAnnotation(book);

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

      for i := 0 to Sequence.Count - 1 do
      begin
        AddItem(lvInfo, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name, GroupID);
      end;

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

    with book.Description.Publishinfo, lvInfo.Groups.Add do
    begin
      Header := rstrPublisherInfo;

      AddItem(lvInfo, rstrTitle, Bookname.Text, GroupID);

      AddItem(lvInfo, rstrPublisher, Publisher.Text, GroupID);
      AddItem(lvInfo, rstrCity, City.Text, GroupID);
      AddItem(lvInfo, rstrYear, Year, GroupID);
      AddItem(lvInfo, rstrISBN, Isbn.Text, GroupID);

      for i := 0 to Sequence.Count - 1 do
      begin
        AddItem(lvInfo, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name, GroupID);
      end;
    end;

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

    with book.Description.Titleinfo do
    begin
      for i := 0 to Annotation.p.Count - 1 do
        mmShort.Lines.Add(Annotation.p[i].OnlyText);
    end;
    mmShort.Visible := (mmShort.Lines.Text <> '');
  except
    Assert(False);
  end;
end;

constructor TReviewDownloadThread.Create(const URL: string; Source: TBookTextSource);
begin
  inherited Create(True); FreeOnTerminate := True; FUrl := URL; FSource := Source;
  FParser := TReviewParser.Create;
  Review := TStringList.Create; Annotation := TStringList.Create;
end;

constructor TReviewDownloadThread.CreateFromFile(const Book: TBookRecord);
begin
  inherited Create(True); FreeOnTerminate := True;
  FBook := Book; FSource := btsFileAnnotation;
  Annotation := TStringList.Create;
end;

destructor TReviewDownloadThread.Destroy;
begin
  FParser.Free; Review.Free; Annotation.Free; inherited;
end;

procedure TReviewDownloadThread.Cancel;
begin
  Terminate;
  if Assigned(FParser) then FParser.Cancel;
end;

function TReviewDownloadThread.Cancelled: Boolean;
begin
  Result := Terminated or (Assigned(FParser) and FParser.Cancelled);
end;

procedure TReviewDownloadThread.ReadFileAnnotation;
var Source: TPublisherSeriesSource; Reader: TFB2PublisherMetadataReader;
  Stream: TStream; Extension, Details: string; Metadata: TFB2CatalogMetadata;
  Status: TFB2MetadataStatus; HR: HRESULT; Stop: TFunc<Boolean>;
begin
  HR := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  OleCheck(HR);
  try
    Stop := function: Boolean begin Result := Terminated; end;
    Source := TPublisherSeriesSource.Create(Stop);
    try
      Stream := Source.OpenCatalogMetadata(FBook, Extension);
      if not Assigned(Stream) then Exit;
      try
        if IsMetadataPackage(Extension) then
          Status := ReadPackageMetadata(Stream, Extension, Metadata, Details, True, Stop)
        else
        begin
          Reader := TFB2PublisherMetadataReader.Create;
          try Status := Reader.ReadCatalogMetadata(Stream, Metadata, Details, True, Stop);
          finally Reader.Free; end;
        end;
        if Status = fmsComplete then Annotation.Text := Metadata.Annotation
        else if Status <> fmsCanceled then raise EReadError.Create(Details);
      finally Stream.Free; end;
    finally Source.Free; end;
  finally CoUninitialize; end;
end;

procedure TReviewDownloadThread.Execute;
begin
  try
    if FSource = btsFileAnnotation then ReadFileAnnotation
    else FParser.Parse(FUrl, Review, Annotation);
  except on E: Exception do ErrorText := E.Message; end;
end;

procedure DownloadReview(Form: TfrmBookDetails; const URL: string);
begin
  Form.AllowOnlineReview(URL); Form.Download;
end;

end.
