(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors             Nick Rymanov     nrymanov@gmail.com
  * Created             05.10.2010
  * Description
  *
  * $Id: unit_treeController.pas 1098 2011-12-21 06:08:37Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_treeController;

interface

uses
  Types,
  Classes, SysUtils,
  Graphics,
  Generics.Collections,
  VirtualTrees,
  BookTreeView,
  pngimage,
  unit_Globals,
  unit_Interfaces;

type
  TTreeController = class
  private
    FSystemData: ISystemData;
    FCompareCount: Integer;
    FCancelCheck: TFunc<Boolean>;
    FCollectionTypes: TDictionary<Integer, COLLECTION_TYPE>;

    FStarImage: TPngImage;
    FEmptyStarImage: TPngImage;

    FRemoteReadImage: TPngImage;
    FRemoteReviewImage: TPngImage;
    FRemoteReadReviewImage: TPngImage;

    FLocalImage: TPngImage;
    FLocalReadImage: TPngImage;
    FLocalReviewImage: TPngImage;
    FLocalReadReviewImage: TPngImage;

    FBookStateImages: array[0 .. 7] of TPngImage;

  private
    function BooksGetColumnTag(const Sender: TBaseVirtualTree; const Column: Integer): Integer;
    function BooksGetColumnText(Tag: Integer; Data: PBookRecord): string;

    procedure GetNodeDataSize<T>(Sender: TBaseVirtualTree; var NodeDataSize: Integer);
    procedure FreeNodeData<T>(Sender: TBaseVirtualTree; Node: PVirtualNode);

    procedure AuthorsGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);

    procedure SeriesGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);

    procedure GenresGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);

    procedure GroupsGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);

    procedure BooksInitNode(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode; var InitialStates: TVirtualNodeInitStates);
    procedure BooksGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure BooksGetCellIsEmpty(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; var IsEmpty: Boolean);
    procedure BooksBeforeCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; CellPaintMode: TVTCellPaintMode; CellRect: TRect; var ContentRect: TRect);
    procedure BooksPaintText(Sender: TBaseVirtualTree; const TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType);
    procedure BooksAfterCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; CellRect: TRect);
    procedure BooksCompareNodes(Sender: TBaseVirtualTree; Node1, Node2: PVirtualNode; Column: TColumnIndex; var Result: Integer);

    procedure DownloadsLoadNode(Sender: TBaseVirtualTree; Node: PVirtualNode; Stream: TStream);
    procedure DownloadsGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure DownloadsPaintText(Sender: TBaseVirtualTree; const TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType);
    procedure DownloadsSaveNode(Sender: TBaseVirtualTree; Node: PVirtualNode; Stream: TStream);

  public
    property CancelCheck: TFunc<Boolean> read FCancelCheck write FCancelCheck;
    constructor Create(SystemData: ISystemData);
    destructor Destroy; override;

    procedure ConnectAuthorsTree(tree: TVirtualStringTree);
    procedure ConnectSeriesTree(tree: TVirtualStringTree);
    procedure ConnectGenresTree(tree: TVirtualStringTree);
    procedure ConnectGroupsTree(tree: TVirtualStringTree);
    procedure ConnectBooksTree(tree: TBookTree);
    procedure ConnectDownloadTree(tree: TBookTree);
  end;

implementation

uses unit_MHLTheme,
  Winapi.Windows,
  Math,
  StrUtils,
  Forms,
  unit_Consts,
  dm_user,
  unit_Helpers,
  unit_MHLHelpers,
  System.JSON, VirtualTrees.Types;

function DPIScale(Value: Integer): Integer; inline;
begin
  Result := MulDiv(Value, Screen.PixelsPerInch, 96);
end;

resourcestring
rstrSingleSeries = 'Серия: %s';
   rstrDownloadStateWaiting = 'Ожидание';
   rstrDownloadStateDownloading = 'Загрузка';
   rstrDownloadStateDone = 'Готово';
   rstrDownloadStateError = 'Ошибка';


const
  STATE_REMOTE   = $0;
  STATE_LOCAL    = $1;

  STATE_UNREAD   = $0;
  STATE_READ     = $2;

  STATE_NOREVIEW = $0;
  STATE_REVIEW   = $4;
constructor TTreeController.Create(SystemData: ISystemData);
begin
  inherited Create;

  FSystemData := SystemData;
  FCollectionTypes := TDictionary<Integer, COLLECTION_TYPE>.Create;

  FStarImage := CreateImageFromResource(TPngImage, 'smallStar') as TPngImage;
  FEmptyStarImage := CreateImageFromResource(TPngImage, 'smallStarEmpty') as TPngImage;

  FRemoteReviewImage := CreateImageFromResource(TPngImage, 'bookRemoteReview') as TPngImage;
  FRemoteReadImage := CreateImageFromResource(TPngImage, 'bookRemoteRead') as TPngImage;
  FRemoteReadReviewImage := CreateImageFromResource(TPngImage, 'bookRemoteReadReview') as TPngImage;

  FLocalImage := CreateImageFromResource(TPngImage, 'bookLocalUnread') as TPngImage;
  FLocalReadImage := CreateImageFromResource(TPngImage, 'bookLocalRead') as TPngImage;
  FLocalReviewImage := CreateImageFromResource(TPngImage, 'bookLocalReview') as TPngImage;
  FLocalReadReviewImage := CreateImageFromResource(TPngImage, 'bookLocalReadReview') as TPngImage;

  FBookStateImages[STATE_REMOTE or STATE_UNREAD or STATE_NOREVIEW] := nil;
  FBookStateImages[STATE_REMOTE or STATE_READ or STATE_NOREVIEW]   := FRemoteReadImage;
  FBookStateImages[STATE_REMOTE or STATE_UNREAD or STATE_REVIEW]   := FRemoteReviewImage;
  FBookStateImages[STATE_REMOTE or STATE_READ or STATE_REVIEW]     := FRemoteReadReviewImage;

  FBookStateImages[STATE_LOCAL or STATE_UNREAD or STATE_NOREVIEW]  := FLocalImage;
  FBookStateImages[STATE_LOCAL or STATE_READ or STATE_NOREVIEW]    := FLocalReadImage;
  FBookStateImages[STATE_LOCAL or STATE_UNREAD or STATE_REVIEW]    := FLocalReviewImage;
  FBookStateImages[STATE_LOCAL or STATE_READ or STATE_REVIEW]      := FLocalReadReviewImage;
end;

destructor TTreeController.Destroy;
begin
  FreeAndNil(FCollectionTypes);

  FreeAndNil(FRemoteReviewImage);
  FreeAndNil(FRemoteReadImage);
  FreeAndNil(FRemoteReadReviewImage);

  FreeAndNil(FLocalImage);
  FreeAndNil(FLocalReadImage);
  FreeAndNil(FLocalReviewImage);
  FreeAndNil(FLocalReadReviewImage);

  FreeAndNil(FStarImage);
  FreeAndNil(FEmptyStarImage);

  FSystemData := nil;

  inherited Destroy;
end;

procedure TTreeController.ConnectAuthorsTree(tree: TVirtualStringTree);
begin
  Assert(Assigned(tree));
  tree.OnGetNodeDataSize := GetNodeDataSize<TAuthorData>;
  tree.OnGetText := AuthorsGetText;
  tree.OnFreeNode := FreeNodeData<TAuthorData>;
end;

procedure TTreeController.ConnectSeriesTree(tree: TVirtualStringTree);
begin
  Assert(Assigned(tree));
  tree.OnGetNodeDataSize := GetNodeDataSize<TSeriesData>;
  tree.OnGetText := SeriesGetText;
  tree.OnFreeNode := FreeNodeData<TSeriesData>;
end;

procedure TTreeController.ConnectGenresTree(tree: TVirtualStringTree);
begin
  Assert(Assigned(tree));
  tree.OnGetNodeDataSize := GetNodeDataSize<TGenreData>;
  tree.OnGetText := GenresGetText;
  tree.OnFreeNode := FreeNodeData<TGenreData>;
end;

procedure TTreeController.ConnectGroupsTree(tree: TVirtualStringTree);
begin
  Assert(Assigned(tree));
  tree.OnGetNodeDataSize := GetNodeDataSize<TGroupData>;
  tree.OnGetText := GroupsGetText;
  tree.OnFreeNode := FreeNodeData<TGroupData>;
end;

procedure TTreeController.ConnectBooksTree(tree: TBookTree);
begin
  Assert(Assigned(tree));
  tree.OnGetNodeDataSize := GetNodeDataSize<TBookRecord>;
  tree.OnInitNode := BooksInitNode;
  tree.OnGetText := BooksGetText;
  tree.OnGetCellIsEmpty := BooksGetCellIsEmpty;
  tree.OnFreeNode := FreeNodeData<TBookRecord>;

  tree.OnBeforeCellPaint := BooksBeforeCellPaint;
  tree.OnPaintText := BooksPaintText;
  tree.OnAfterCellPaint := BooksAfterCellPaint;
  tree.OnCompareNodes := BooksCompareNodes;
end;

procedure TTreeController.ConnectDownloadTree(tree: TBookTree);
begin
  Assert(Assigned(tree));
  tree.OnGetNodeDataSize := GetNodeDataSize<TDownloadData>;
  tree.OnLoadNode := DownloadsLoadNode;
  tree.OnGetText := DownloadsGetText;
  tree.OnPaintText := DownloadsPaintText;
  tree.OnSaveNode := DownloadsSaveNode;
  tree.OnFreeNode := FreeNodeData<TDownloadData>;
end;

procedure TTreeController.GetNodeDataSize<T>(Sender: TBaseVirtualTree; var NodeDataSize: Integer);
begin
  NodeDataSize := SizeOf(T);
end;

procedure TTreeController.FreeNodeData<T>(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  Data: ^T;
begin
  Data := Sender.GetNodeData(Node);
  if Assigned(Data) then
    Finalize(Data^);
end;

procedure TTreeController.AuthorsGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var
  Data: PAuthorData;
begin
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));

  CellText := Data^.GetFullName;
end;

procedure TTreeController.SeriesGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var
  Data: PSeriesData;
begin
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));

  CellText := Data^.SeriesTitle;
end;

procedure TTreeController.GenresGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var
  Data: PGenreData;
begin
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));

  CellText := Data^.GenreAlias;
end;

procedure TTreeController.GroupsGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var
  Data: PGroupData;
begin
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));
  CellText := Data^.Text;
end;

procedure TTreeController.BooksInitNode(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode; var InitialStates: TVirtualNodeInitStates);
begin
  Node.CheckType := ctTriStateCheckBox;
  Sender.CheckState[Node] := csUncheckedNormal;
end;

function TTreeController.BooksGetColumnTag(const Sender: TBaseVirtualTree; const Column: Integer): Integer;
begin
  if Column < 0 then
    Result := -1
  else
    Result := (Sender as TBookTree).Header.Columns[Column].Tag;
end;

function TTreeController.BooksGetColumnText(Tag: Integer; Data: PBookRecord): string;
begin
  Assert(Assigned(Data));
  case Tag of
    COL_AUTHOR:
      Result := TAuthorsHelper.GetList(Data^.Authors);
    COL_TITLE:
      Result := Data^.Title;
    COL_SERIES:
      Result := Data^.Series;
    COL_PUBLISHER_SERIES:
      Result := TSeriesHelper.GetList(Data^.PublisherSeries);
    COL_PUBLISHER:
      Result := Data^.Publisher;
    COL_NO:
      Result := IfThen(Data^.SeqNumber = 0, '', IntToStr(Data^.SeqNumber));
    COL_SIZE:
      Result := GetFormattedSize(Data^.Size);
    COL_DATE:
      Result := DateToStr(Data^.Date);
    COL_GENRE:
      Result := TGenresHelper.GetList(Data^.Genres);
    COL_TYPE:
      Result := Data^.GetFileType;
    COL_LANG:
      Result := Data^.Lang;
    COL_COLLECTION:
      Result := Data^.CollectionName;
    COL_LIBID:
      Result := Data^.DisplayLibID;
  end;
end;

procedure TTreeController.BooksGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var
  Page: Integer;
  Data: PBookRecord;
  ColumnID: Integer;
begin
  Page := Sender.Tag;
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));

  ColumnID := BooksGetColumnTag(Sender, Column);
  CellText := '';
  if Settings.TreeModes[Page] = tmTree then
  begin
    case Data^.nodeType of
      ntAuthorInfo:
        begin
          if COL_TITLE = ColumnID then
              CellText := TAuthorsHelper.GetList(Data^.Authors);
        end;

      ntSeriesInfo:
        begin
          if COL_TITLE = ColumnID then
            CellText := Format(rstrSingleSeries, [Data^.Series]);
        end;

      ntBookInfo:
        begin
          CellText := BooksGetColumnText(ColumnID, Data);
        end;
    end
  end
  else
    CellText := BooksGetColumnText(ColumnID, Data);
  if (Page = PAGE_PUBLISHER_SERIES) and (ColumnID = COL_NO) and
     (Data^.nodeType = ntBookInfo) then
    CellText := IfThen(Data^.PublisherSeqNumber = 0, '', IntToStr(Data^.PublisherSeqNumber));
end;

procedure TTreeController.BooksGetCellIsEmpty(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; var IsEmpty: Boolean);
var
  Data: PBookRecord;
  ColumnID: Integer;
begin
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));

  ColumnID := BooksGetColumnTag(Sender, Column);

  case Data^.nodeType of
    ntAuthorInfo, ntSeriesInfo:
      IsEmpty := (COL_TITLE <> ColumnID);
    else
      IsEmpty := False;
  end;
end;

procedure TTreeController.BooksBeforeCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; CellPaintMode: TVTCellPaintMode; CellRect: TRect; var ContentRect: TRect);
var
  Data: PBookRecord;
  Color: TColor;
begin
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));

  if MHLThemeDark then
  begin
    case Data^.nodeType of
      ntAuthorInfo: Color:=RGB(43,45,48);
      ntSeriesInfo: Color:=RGB(38,40,43);
      else Color:=RGB(30,31,34);
    end;
    TargetCanvas.Brush.Color:=Color; TargetCanvas.FillRect(CellRect);
    Exit;
  end;

  Color := Settings.BGColor;
  case Data^.nodeType of
    ntAuthorInfo:
      Color := Settings.AuthorColor;

    ntSeriesInfo:
      Color := Settings.SeriesColor;

    ntBookInfo:
      begin
        if Data^.Series = '' then
          Color := Settings.BookColor
        else
          Color := Settings.SeriesBookColor;
      end;
  end;

  TargetCanvas.Brush.Color := Color;
  TargetCanvas.FillRect(CellRect);
end;

procedure TTreeController.BooksPaintText(Sender: TBaseVirtualTree; const TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType);
var
  Data: PBookRecord;
begin
  Data := Sender.GetNodeData(Node);
  if MHLThemeDark and not Sender.Selected[Node] then
  begin
    TargetCanvas.Font.Color:=MHLThemeText;
    if bpIsLocal in Data^.BookProps then TargetCanvas.Font.Color:=RGB(137,190,137);
    if bpIsDeleted in Data^.BookProps then TargetCanvas.Font.Color:=RGB(137,139,146);
  end;
  if Data^.nodeType <> ntBookInfo then
    TargetCanvas.Font.Style := [fsBold]
  else if not MHLThemeDark and not Sender.Selected[Node] then
  begin
    if (bpIsLocal in Data^.BookProps) then
      TargetCanvas.Font.Color := Settings.LocalColor;
    if (bpIsDeleted in Data^.BookProps) then
      TargetCanvas.Font.Color := Settings.DeletedColor;
  end;
end;

procedure TTreeController.BooksAfterCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; CellRect: TRect);
var
  Data: PBookRecord;
  ColumnID: Integer;

  procedure Stars(Value: Integer);
  var
    i: Integer;
    X, Y: Integer;
    w, h: Integer;
    Img: TPngImage;
  begin
    w := DPIScale(FStarImage.Width);
    h := DPIScale(FStarImage.Height);
    X := CellRect.Left + (CellRect.Right - CellRect.Left - w * 5) div 2;
    Y := CellRect.Top + (CellRect.Bottom - CellRect.Top - h) div 2;
    for i := 0 to 4 do
    begin
      if Value > i then
        Img := FStarImage
      else
        Img := FEmptyStarImage;
      TargetCanvas.StretchDraw(Rect(X, Y, X + w, Y + h), Img);
      Inc(X, w);
    end;
  end;

  procedure DrawState;
  var
    CollectionInfo: TCollectionInfo;
    CollectionType: COLLECTION_TYPE;
    BookState: Integer;
    StateImage: TPngImage;
    X, Y: Integer;
    w, h: Integer;
  begin
    if not FCollectionTypes.TryGetValue(Data^.BookKey.DatabaseID, CollectionType) then
    begin
      CollectionInfo := FSystemData.GetCollectionInfo(Data^.BookKey.DatabaseID);
      CollectionType := CollectionInfo.CollectionType;
      FCollectionTypes.Add(Data^.BookKey.DatabaseID, CollectionType);
    end;

    BookState := STATE_REMOTE or STATE_UNREAD or STATE_NOREVIEW;

    if (bpIsLocal in Data^.BookProps) or isLocalCollection(CollectionType) then
      BookState := BookState or STATE_LOCAL;

    if (Data^.Progress = 100) then
      BookState := BookState or STATE_READ;

    if (bpHasReview in Data^.BookProps) then
      BookState := BookState or STATE_REVIEW;

    if isLocalCollection(CollectionType) and (BookState = (STATE_LOCAL or STATE_UNREAD or STATE_NOREVIEW)) then
    begin
      Exit;
    end;

    StateImage := FBookStateImages[BookState];

    if Assigned(StateImage) then
    begin
      w := DPIScale(StateImage.Width);
      h := DPIScale(StateImage.Height);
      X := CellRect.Left + (CellRect.Right - CellRect.Left - w) div 2;
      Y := CellRect.Top + (CellRect.Bottom - CellRect.Top - h) div 2;
      TargetCanvas.StretchDraw(Rect(X, Y, X + w, Y + h), StateImage);
    end;
  end;

begin
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));

  if Data^.nodeType <> ntBookInfo then
    Exit;

  ColumnID := BooksGetColumnTag(Sender, Column);

  if (ColumnID = COL_STATE) then
    DrawState
  else if (ColumnID = COL_RATE) then
    Stars(Data^.Rate)
  else if (ColumnID = COL_LIBRATE) then
  begin
    if Data^.LibRate <= 5 then
      Stars(Data^.LibRate)
    else
      Stars(0);
  end;
end;

procedure TTreeController.BooksCompareNodes(Sender: TBaseVirtualTree; Node1, Node2: PVirtualNode; Column: TColumnIndex; var Result: Integer);
var
  Data1, Data2: PBookRecord;
  Number1, Number2: Integer; Tree: TBookTree; Key: TBookSortKey;
  function CompareColumn(Tag: Integer): Integer;
  begin
    Result := 0;
    case Tag of
      COL_AUTHOR:  Result := CompareStr(TAuthorsHelper.GetList(Data1^.Authors), TAuthorsHelper.GetList(Data2^.Authors));
      COL_TITLE:   Result := CompareStr(Data1^.Title, Data2^.Title);
      COL_PUBLISHER_SERIES: Result := CompareStr(TSeriesHelper.GetList(Data1^.PublisherSeries),TSeriesHelper.GetList(Data2^.PublisherSeries));
      COL_PUBLISHER: Result := CompareStr(Data1^.Publisher, Data2^.Publisher);
      COL_SERIES:  Result := CompareStr(Data1^.Series, Data2^.Series);
      COL_NO:      Result := CompareSeqNumber(Number1, Number2);
      COL_SIZE:    Result := CompareInt(Data1^.Size, Data2^.Size);
      COL_RATE:    Result := CompareInt(Data1^.Rate, Data2^.Rate);
      COL_GENRE:   Result := CompareStr(TGenresHelper.GetList(Data1^.Genres), TGenresHelper.GetList(Data2^.Genres));
      COL_DATE:    Result := CompareDate(Data1^.Date, Data2^.Date);
      COL_LANG:    Result := CompareStr(Data1^.Lang, Data2^.Lang);
      COL_LIBRATE: Result := CompareInt(Data1^.LibRate, Data2^.LibRate);
      COL_LIBID:   Result := CompareInt(StrToIntDef(Data1^.DisplayLibID, 0), StrToIntDef(Data2^.DisplayLibID, 0));
      COL_COLLECTION: Result := CompareStr(Data1^.CollectionName, Data2^.CollectionName);
      COL_TYPE:   Result := CompareStr(Data1^.GetFileType, Data2^.GetFileType);
    end;
  end;
begin
  Inc(FCompareCount);
  if Assigned(FCancelCheck) and ((FCompareCount and 4095)=0) and FCancelCheck() then Abort;
  Data1 := Sender.GetNodeData(Node1);
  Data2 := Sender.GetNodeData(Node2);
  Number1 := Data1^.SeqNumber;
  Number2 := Data2^.SeqNumber;
  if Sender.Tag = PAGE_PUBLISHER_SERIES then
  begin
    Number1 := Data1^.PublisherSeqNumber;
    Number2 := Data2^.PublisherSeqNumber;
  end;

  Tree := Sender as TBookTree;
  if (Settings.TreeModes[Sender.Tag] = tmFlat) and (Column = NoColumn) then
    Result := CompareInt(Data1^.ListOrder,Data2^.ListOrder)
  else if (Column >= 0) and (Length(Tree.SortKeys) > 0) then
  begin
    Result := 0;
    for Key in Tree.SortKeys do
    begin
      Result := CompareColumn(Key.Tag);
      // VirtualTrees reverses the complete comparator for the primary direction.
      if Key.Direction <> Tree.Header.SortDirection then Result := -Result;
      if Result <> 0 then Break;
    end;
    if Result = 0 then
    begin
      Result := CompareInt(Data1^.ListOrder,Data2^.ListOrder);
      if Tree.Header.SortDirection = sdDescending then Result := -Result;
    end;
  end
  else if NoColumn = Column then
  begin
    if Data1^.nodeType = Data2^.nodeType then
    begin
      Result := 0;
      if Data1^.nodeType = ntAuthorInfo then
        Result := CompareStr(TAuthorsHelper.GetList(Data1^.Authors), TAuthorsHelper.GetList(Data2^.Authors))
      else if Data1^.nodeType = ntSeriesInfo then
        Result := CompareStr(Data1^.Series, Data2^.Series)
      else
      begin
        Result := CompareSeqNumber(Number1, Number2);
        if Result = 0 then
          Result := CompareStr(Data1^.Title, Data2^.Title);
        if Result = 0 then
          Result := CompareStr(Data1^.Series, Data2^.Series);
      end;
    end
    else
      Result := Sign(Ord(Data1^.nodeType) - Ord(Data2^.nodeType));
  end
  else Result := CompareColumn(Tree.Header.Columns[Column].Tag);
end;

procedure TTreeController.DownloadsLoadNode(Sender: TBaseVirtualTree; Node: PVirtualNode; Stream: TStream);
var
  Data: PDownloadData;
  Parsed: TDownloadData;
  Start, FrameEnd: Int64;
  Header: TChunkHeader;
  RawState: Cardinal;
  Value: TJSONValue; Envelope: TJSONObject; Payload, RawURL: string;

  procedure ReadExact(var Buffer; Count: Integer);
  begin
    if (Count<0) or (Stream.Position<Start) or (Stream.Position>FrameEnd) or
      (Int64(Count)>FrameEnd-Stream.Position) then
      raise EReadError.Create('Повреждена запись очереди: поле выходит за границу записи.');
    Stream.ReadBuffer(Buffer,Count);
  end;

  function GetString: string;
  const MaxStringBytes=4*1024*1024;
  var Size, Units: Integer; Bytes: TBytes;
  begin
    ReadExact(Size,SizeOf(Size));
    if (Size<1) or (Size>MaxStringBytes) or (Int64(Size)>FrameEnd-Stream.Position) then
      raise EReadError.Create('Повреждена запись очереди: недопустимая длина строки.');
    SetLength(Bytes,Size); ReadExact(Bytes[0],Size);
    if Odd(Size) then
    begin
      // Old Unicode releases wrote only the first byte of the terminal NUL.
      if Bytes[Size-1]<>0 then raise EReadError.Create('Повреждён конец строки очереди.');
      Units:=(Size-1) div SizeOf(Char);
    end
    else
    begin
      if (Size<SizeOf(Char)) or (Bytes[Size-1]<>0) or (Bytes[Size-2]<>0) then
        raise EReadError.Create('Повреждён конец строки очереди.');
      Units:=(Size-SizeOf(Char)) div SizeOf(Char);
    end;
    if Units=0 then Result:='' else SetString(Result,PChar(@Bytes[0]),Units);
  end;

  function CompleteEnvelope(const Text: string): Boolean;
  var Trimmed: string; InString, Escaped: Boolean; Depth, Separators: Integer;
  begin
    Result:=False; Trimmed:=Text.Trim;
    if (Length(Trimmed)<2) or (Trimmed[1]<>'{') or (Trimmed[Length(Trimmed)]<>'}') then Exit;
    InString:=False; Escaped:=False; Depth:=0; Separators:=0;
    for var I:=1 to Length(Trimmed) do
    begin
      var C:=Trimmed[I];
      if InString then
      begin
        if Ord(C)<32 then Exit;
        if Escaped then Escaped:=False
        else if C='\' then Escaped:=True
        else if C='"' then InString:=False;
      end
      else
      begin
        if C='"' then InString:=True
        else if CharInSet(C,['{','[']) then
        begin Inc(Depth); if Depth>8 then Exit; end
        else if CharInSet(C,['}',']']) then
        begin
          Dec(Depth); if (Depth<0) or ((Depth=0) and (I<>Length(Trimmed))) then Exit;
        end
        else if CharInSet(C,[':',',']) then
        begin Inc(Separators); if Separators>5 then Exit; end;
      end;
    end;
    Result:=not InString and not Escaped and (Depth=0);
  end;

begin
  Assert(Assigned(Sender));
  Assert(Assigned(Node));
  Assert(Assigned(Stream));

  Data := Sender.GetNodeData(Node);
  Start:=Stream.Position; FrameEnd:=Stream.Size;
  if Start<>0 then
  begin
    if Start<SizeOf(Header) then raise EReadError.Create('Повреждена граница записи очереди.');
    Stream.Position:=Start-SizeOf(Header);
    try Stream.ReadBuffer(Header,SizeOf(Header)); finally Stream.Position:=Start; end;
    if (Header.ChunkType<>UserChunk) or (Header.ChunkSize<0) or
      (Int64(Header.ChunkSize)>Stream.Size-Start) then
      raise EReadError.Create('Повреждена граница записи очереди.');
    FrameEnd:=Start+Int64(Header.ChunkSize);
  end;
  Parsed:=Default(TDownloadData);
  ReadExact(Parsed.BookKey,SizeOf(Parsed.BookKey));
  Parsed.Title:=GetString; Parsed.Author:=GetString;
  ReadExact(Parsed.Size,SizeOf(Parsed.Size));
  Parsed.FileName:=GetString; Parsed.URL:=GetString;
  // Preserve the legacy stream's field layout. Only this existing string
  // carries a versioned optional envelope; it is never a network address.
  if Parsed.URL.StartsWith('#MHL-download-identity-') then
  begin
    Parsed.HasExpectedIdentity:=True; RawURL:=Parsed.URL;
    Payload := Copy(Parsed.URL, Length('#MHL-download-identity-v1#') + 1, MaxInt);
    Value := nil;
    try
      if Parsed.URL.StartsWith('#MHL-download-identity-v1#') and
        (Length(Payload)<=1048576) and CompleteEnvelope(Payload) then
        Value:=TJSONObject.ParseJSONValue(Payload);
      if Value is TJSONObject then
      begin
        Envelope := TJSONObject(Value);
        if (Envelope.Count=3) and Assigned(Envelope.GetValue('url')) and (Envelope.GetValue('url') is TJSONString) and
          Assigned(Envelope.GetValue('libid')) and (Envelope.GetValue('libid') is TJSONString) and
          Assigned(Envelope.GetValue('physical')) and (Envelope.GetValue('physical') is TJSONString) then
        begin
          Parsed.URL := Envelope.GetValue('url').Value;
          Parsed.ExpectedLibID := Envelope.GetValue('libid').Value;
          Parsed.ExpectedPhysicalIdentity := Envelope.GetValue('physical').Value;
        end;
      end;
    except
      // Retain malformed/future raw data verbatim while failing identity proof.
      Parsed.URL:=RawURL; Parsed.ExpectedLibID := ''; Parsed.ExpectedPhysicalIdentity := '';
    end;
    Value.Free;
  end;

  RawState:=0; ReadExact(RawState,SizeOf(TDownloadState));
  if RawState>Ord(High(TDownloadState)) then raise EReadError.Create('Повреждено состояние книги в очереди.');
  Parsed.State:=TDownloadState(RawState);
  if Stream.Position<>FrameEnd then raise EReadError.Create('В записи очереди остались неизвестные данные.');
  Data^:=Parsed;
end;

procedure TTreeController.DownloadsGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
const
  States: array [TDownloadState] of string = (rstrDownloadStateWaiting, rstrDownloadStateDownloading, rstrDownloadStateDone, rstrDownloadStateError);
var
  Data: PDownloadData;
begin
  Data := Sender.GetNodeData(Node);
  Assert(Assigned(Data));
  case Column of
    0: CellText := Data^.Author;
    1: CellText := Data^.Title;
    2: CellText := GetFormattedSize(Data^.Size);
    3: CellText := States[Data^.State];
  end;
end;

procedure TTreeController.DownloadsPaintText(Sender: TBaseVirtualTree; const TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType);
var
  Data: PDownloadData;
begin
  Data := Sender.GetNodeData(Node);
  if Assigned(Data) and not Sender.Selected[Node] then
    case Data.State of
      dsRun: TargetCanvas.Font.Color := clGreen;
      dsError: TargetCanvas.Font.Color := clRed;
    end;
end;

procedure TTreeController.DownloadsSaveNode(Sender: TBaseVirtualTree; Node: PVirtualNode; Stream: TStream);
var
  Data: PDownloadData;
  Size: Integer;
  Envelope: TJSONObject;

  procedure WriteString(const S: string);
  const MaxStringBytes=4*1024*1024;
  var Bytes: Int64; Zero: Word;
  begin
    Bytes:=Int64(Length(S))*SizeOf(Char);
    if Bytes+SizeOf(Char)>MaxStringBytes then raise EWriteError.Create('Строка очереди превышает допустимый размер.');
    Size:=Integer(Bytes)+SizeOf(Char); Zero:=0;
    Stream.WriteBuffer(Size,SizeOf(Size));
    if Bytes>0 then Stream.WriteBuffer(PChar(S)^,Integer(Bytes));
    Stream.WriteBuffer(Zero,SizeOf(Zero));
  end;

begin
  Assert(Assigned(Sender));
  Assert(Assigned(Node));
  Assert(Assigned(Stream));

  Data := Sender.GetNodeData(Node);

  if not Assigned(Data) then
    Exit;

  if (Ord(Data^.State)<Ord(Low(TDownloadState))) or (Ord(Data^.State)>Ord(High(TDownloadState))) then
    raise EWriteError.Create('Недопустимое состояние книги в очереди.');

  Stream.WriteBuffer(Data^.BookKey, SizeOf(Data^.BookKey));

  WriteString(Data^.Title);
  WriteString(Data^.Author);

  Stream.WriteBuffer(Data^.Size, SizeOf(Data^.Size));

  WriteString(Data^.FileName);
  if Data^.HasExpectedIdentity and (Data^.ExpectedLibID='') and (Data^.ExpectedPhysicalIdentity='') and
    Data^.URL.StartsWith('#MHL-download-identity-') then
    WriteString(Data^.URL)
  else if Data^.HasExpectedIdentity then
  begin
    Envelope := TJSONObject.Create;
    try
      Envelope.AddPair('url', Data^.URL);
      Envelope.AddPair('libid', Data^.ExpectedLibID);
      Envelope.AddPair('physical', Data^.ExpectedPhysicalIdentity);
      WriteString('#MHL-download-identity-v1#' + Envelope.ToJSON);
    finally Envelope.Free; end;
  end
  else WriteString(Data^.URL);

  Stream.WriteBuffer(Data^.State, SizeOf(Data^.State));
end;

end.
