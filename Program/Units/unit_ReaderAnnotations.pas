unit unit_ReaderAnnotations;

interface

uses System.SysUtils, System.Generics.Collections;

type
  TReaderAnnotation = record
    ID, BookID, BookTitle, Title, Text, Quote, Place, Created: string;
    Position: Integer;
    // UTF-16 character offsets, [RangeStart, RangeEnd). Zero/zero is no range.
    // For page text Position remains the zero-based PDF/DjVu page number.
    RangeStart, RangeEnd: Integer;
    RangeIsPageText: Boolean;
  end;
  TReaderAnnotationIndex = class
  private
    type
      TInterval = record
        NoteIndex, Left, Right: Integer;
        First, Last, MaxEnd: Int64;
        HasRange: Boolean;
      end;
      TBucket = class
      private
        FPending: TList<TInterval>;
        FNodes: TArray<TInterval>;
        FRoot: Integer;
        function Balance(First, Last: Integer): Integer;
        procedure Collect(Node: Integer; First, Last: Int64; RangesOnly: Boolean;
          Hits: TList<Integer>; var Visited: Integer);
      public
        constructor Create;
        destructor Destroy; override;
        procedure Add(NoteIndex: Integer; First, Last: Int64; HasRange: Boolean);
        procedure Build;
        procedure Query(First, Last: Int64; RangesOnly: Boolean;
          Hits: TList<Integer>; var Visited: Integer);
        procedure All(Hits: TList<Integer>);
      end;
  private
    FNotes: TArray<TReaderAnnotation>;
    FText: TBucket;
    FPages: TObjectDictionary<Integer,TBucket>;
    FPagePoints: TObjectDictionary<Integer,TList<Integer>>;
    FLastVisitedNodes: Integer;
    function Results(Hits: TList<Integer>): TArray<TReaderAnnotation>;
    function Find(First, Last: Integer; PageText: Boolean; Page: Integer;
      RangesOnly: Boolean): TArray<TReaderAnnotation>;
  public
    constructor Create(const Notes: TArray<TReaderAnnotation>);
    destructor Destroy; override;
    function Query(First, LastExclusive: Integer; PageText: Boolean = False;
      Page: Integer = -1): TArray<TReaderAnnotation>;
    function QueryPage(Page: Integer): TArray<TReaderAnnotation>;
    function HitTest(CharacterPosition: Integer; PageText: Boolean = False;
      Page: Integer = -1): TArray<TReaderAnnotation>;
    property LastVisitedNodes: Integer read FLastVisitedNodes;
  end;
  TReaderAnnotations = class
  private
    FFileName, FLoadedHash: string;
    FItems: TArray<TReaderAnnotation>;
    procedure Load;
    procedure Save;
  public
    constructor Create(const SettingsFile: string);
    function Items(const BookID: string = ''): TArray<TReaderAnnotation>;
    function Put(const Note: TReaderAnnotation): string;
    procedure Remove(const ID: string);
  end;

function ReaderAnnotationsText(const Items: TArray<TReaderAnnotation>; HTML: Boolean; Style: Integer = 1): string;
function ReaderAnnotationsDocx(const Items: TArray<TReaderAnnotation>; Style: Integer = 1): TBytes;
function ReaderAnnotationHasRange(const Note: TReaderAnnotation): Boolean;
function ReaderAnnotationDisplayTitle(const Note: TReaderAnnotation): string;

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.JSON, System.DateUtils,
  System.Generics.Defaults, System.NetEncoding, System.Hash, System.Zip;

function ReaderAnnotationHasRange(const Note: TReaderAnnotation): Boolean;
begin Result:=(Note.RangeStart>=0) and (Note.RangeEnd>Note.RangeStart); end;

function ReaderAnnotationDisplayTitle(const Note: TReaderAnnotation): string;
begin
  if Note.Title.Trim='' then Result:='—' else Result:=Note.Title;
end;

function AnnotationContextText(const Note: TReaderAnnotation): string;
begin
  if Note.Place.Trim='' then Result:=Note.Created
  else if Note.Created.Trim='' then Result:=Note.Place
  else Result:=Note.Place+' · '+Note.Created;
end;

constructor TReaderAnnotationIndex.TBucket.Create;
begin inherited Create; FPending:=TList<TInterval>.Create; FRoot:=-1; end;

destructor TReaderAnnotationIndex.TBucket.Destroy;
begin FPending.Free; inherited; end;

procedure TReaderAnnotationIndex.TBucket.Add(NoteIndex: Integer; First, Last: Int64; HasRange: Boolean);
var Entry: TInterval;
begin
  Entry:=Default(TInterval); Entry.NoteIndex:=NoteIndex;
  Entry.First:=First; Entry.Last:=Last; Entry.MaxEnd:=Last;
  Entry.Left:=-1; Entry.Right:=-1; Entry.HasRange:=HasRange; FPending.Add(Entry);
end;

function TReaderAnnotationIndex.TBucket.Balance(First, Last: Integer): Integer;
var Entry: TInterval;
begin
  if First>Last then Exit(-1);
  Result:=First+(Last-First) div 2; Entry:=FNodes[Result];
  Entry.Left:=Balance(First,Result-1); Entry.Right:=Balance(Result+1,Last);
  if (Entry.Left>=0) and (FNodes[Entry.Left].MaxEnd>Entry.MaxEnd) then Entry.MaxEnd:=FNodes[Entry.Left].MaxEnd;
  if (Entry.Right>=0) and (FNodes[Entry.Right].MaxEnd>Entry.MaxEnd) then Entry.MaxEnd:=FNodes[Entry.Right].MaxEnd;
  FNodes[Result]:=Entry;
end;

procedure TReaderAnnotationIndex.TBucket.Build;
begin
  FNodes:=FPending.ToArray; FPending.Clear;
  TArray.Sort<TInterval>(FNodes,TComparer<TInterval>.Construct(
    function(const A,B: TInterval): Integer
    begin
      if A.First<B.First then Exit(-1); if A.First>B.First then Exit(1);
      if A.NoteIndex<B.NoteIndex then Exit(-1); if A.NoteIndex>B.NoteIndex then Exit(1); Result:=0;
    end));
  FRoot:=Balance(0,High(FNodes));
end;

procedure TReaderAnnotationIndex.TBucket.Collect(Node: Integer; First, Last: Int64;
  RangesOnly: Boolean; Hits: TList<Integer>; var Visited: Integer);
var Entry: TInterval;
begin
  if Node<0 then Exit; Inc(Visited); Entry:=FNodes[Node];
  if Entry.MaxEnd<=First then Exit;
  Collect(Entry.Left,First,Last,RangesOnly,Hits,Visited);
  if (Entry.First<Last) and (Entry.Last>First) and (not RangesOnly or Entry.HasRange) then Hits.Add(Entry.NoteIndex);
  if Entry.First<Last then Collect(Entry.Right,First,Last,RangesOnly,Hits,Visited);
end;

procedure TReaderAnnotationIndex.TBucket.Query(First, Last: Int64; RangesOnly: Boolean;
  Hits: TList<Integer>; var Visited: Integer);
begin Collect(FRoot,First,Last,RangesOnly,Hits,Visited); end;

procedure TReaderAnnotationIndex.TBucket.All(Hits: TList<Integer>);
begin for var Node in FNodes do Hits.Add(Node.NoteIndex); end;

constructor TReaderAnnotationIndex.Create(const Notes: TArray<TReaderAnnotation>);
var Bucket: TBucket; Points: TList<Integer>; Note: TReaderAnnotation;
begin
  inherited Create; FNotes:=Copy(Notes); FText:=TBucket.Create;
  FPages:=TObjectDictionary<Integer,TBucket>.Create([doOwnsValues]);
  FPagePoints:=TObjectDictionary<Integer,TList<Integer>>.Create([doOwnsValues]);
  for var I:=0 to High(FNotes) do
  begin
    Note:=FNotes[I];
    if ReaderAnnotationHasRange(Note) then
    begin
      if Note.RangeIsPageText then
      begin
        if Note.Position<0 then Continue;
        if not FPages.TryGetValue(Note.Position,Bucket) then
        begin Bucket:=TBucket.Create; FPages.Add(Note.Position,Bucket); end;
        Bucket.Add(I,Note.RangeStart,Note.RangeEnd,True);
      end
      else FText.Add(I,Note.RangeStart,Note.RangeEnd,True);
    end
    else if Note.Position>=0 then
    begin
      FText.Add(I,Note.Position,Int64(Note.Position)+1,False);
      // Legacy notes have no format flag: the caller knows the current book.
      if not FPagePoints.TryGetValue(Note.Position,Points) then
      begin Points:=TList<Integer>.Create; FPagePoints.Add(Note.Position,Points); end;
      Points.Add(I);
    end;
  end;
  FText.Build; for Bucket in FPages.Values do Bucket.Build;
end;

destructor TReaderAnnotationIndex.Destroy;
begin FPagePoints.Free; FPages.Free; FText.Free; inherited; end;

function TReaderAnnotationIndex.Results(Hits: TList<Integer>): TArray<TReaderAnnotation>;
var Order: TArray<Integer>;
begin
  Order:=Hits.ToArray; TArray.Sort<Integer>(Order); SetLength(Result,Length(Order));
  for var I:=0 to High(Order) do Result[I]:=FNotes[Order[I]];
end;

function TReaderAnnotationIndex.Find(First, Last: Integer; PageText: Boolean;
  Page: Integer; RangesOnly: Boolean): TArray<TReaderAnnotation>;
var Hits: TList<Integer>; Bucket: TBucket; Points: TList<Integer>;
begin
  Result:=nil; FLastVisitedNodes:=0;
  if (First<0) or (Last<=First) or (PageText and (Page<0)) then Exit;
  Hits:=TList<Integer>.Create;
  try
    if PageText then
    begin
      if FPages.TryGetValue(Page,Bucket) then Bucket.Query(First,Last,RangesOnly,Hits,FLastVisitedNodes);
      if not RangesOnly and FPagePoints.TryGetValue(Page,Points) then Hits.AddRange(Points);
    end
    else FText.Query(First,Last,RangesOnly,Hits,FLastVisitedNodes);
    Result:=Results(Hits);
  finally Hits.Free; end;
end;

function TReaderAnnotationIndex.Query(First, LastExclusive: Integer; PageText: Boolean;
  Page: Integer): TArray<TReaderAnnotation>;
begin Result:=Find(First,LastExclusive,PageText,Page,False); end;

function TReaderAnnotationIndex.QueryPage(Page: Integer): TArray<TReaderAnnotation>;
var Hits: TList<Integer>; Bucket: TBucket; Points: TList<Integer>;
begin
  Result:=nil; FLastVisitedNodes:=0; if Page<0 then Exit;
  Hits:=TList<Integer>.Create;
  try
    if FPages.TryGetValue(Page,Bucket) then Bucket.All(Hits);
    if FPagePoints.TryGetValue(Page,Points) then Hits.AddRange(Points);
    Result:=Results(Hits);
  finally Hits.Free; end;
end;

function TReaderAnnotationIndex.HitTest(CharacterPosition: Integer; PageText: Boolean;
  Page: Integer): TArray<TReaderAnnotation>;
begin
  if (CharacterPosition<0) or (CharacterPosition=MaxInt) then
  begin FLastVisitedNodes:=0; Exit(nil); end;
  Result:=Find(CharacterPosition,CharacterPosition+1,PageText,Page,True);
end;

function AnnotationHash(const Bytes: TBytes): string;
var Hash: THashSHA2;
begin
  Hash:=THashSHA2.Create(THashSHA2.TSHA2Version.SHA256); Hash.Update(Bytes); Result:=Hash.HashAsString;
end;

constructor TReaderAnnotations.Create(const SettingsFile: string);
begin
  inherited Create;
  if SettingsFile='' then raise Exception.Create('Не задана папка заметок.');
  FFileName:=TPath.Combine(ExtractFilePath(ExpandFileName(SettingsFile.Replace('/','\'))),'reader-notes.json'); Load;
end;

procedure TReaderAnnotations.Load;
var JSON: TJSONValue; Obj, Row: TJSONObject; Rows: TJSONArray; Note: TReaderAnnotation;
  List: TList<TReaderAnnotation>; IDs: TDictionary<string,Boolean>; Bytes: TBytes;
  First, Last, PageText: TJSONValue;
  function RangeNumber(Value: TJSONValue): Integer;
  begin
    if not (Value is TJSONNumber) then
      raise Exception.Create('Повреждён диапазон заметки. Исходный файл не изменён.');
    if not TryStrToInt(Value.Value,Result) then
      raise Exception.Create('Повреждён диапазон заметки. Исходный файл не изменён.');
    if Result<0 then
      raise Exception.Create('Повреждён диапазон заметки. Исходный файл не изменён.');
  end;
begin
  if not TFile.Exists(FFileName) then
  begin
    if TFile.Exists(FFileName+'.bak') then raise Exception.Create('Основной файл заметок не найден. Предыдущие записи сохранены в reader-notes.json.bak; пустой файл поверх них не создаётся.');
    Exit;
  end;
  if TFile.GetSize(FFileName)>64*1024*1024 then raise Exception.Create('Файл заметок слишком велик; исходный файл сохранён.');
  Bytes:=TFile.ReadAllBytes(FFileName);
  if Length(Bytes)>64*1024*1024 then raise Exception.Create('Файл заметок слишком велик; исходный файл сохранён.');
  if (Length(Bytes)>0) and (MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,PAnsiChar(@Bytes[0]),Length(Bytes),nil,0)=0) then
    raise Exception.Create('Повреждена кодировка заметок. Исходный файл не изменён.');
  JSON:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes).TrimStart([#$FEFF]));
  List:=TList<TReaderAnnotation>.Create; IDs:=TDictionary<string,Boolean>.Create;
  try
    if not (JSON is TJSONObject) then raise Exception.Create('Не удалось прочитать заметки. Исходный файл не изменён.');
    Obj:=TJSONObject(JSON);
    if Obj.GetValue<Integer>('version',0)<>1 then raise Exception.Create('Неизвестная версия файла заметок. Исходный файл не изменён.');
    if not (Obj.GetValue('notes') is TJSONArray) then raise Exception.Create('Повреждён список заметок. Исходный файл не изменён.');
    Rows:=TJSONArray(Obj.GetValue('notes'));
    if Rows.Count>10000 then raise Exception.Create('В файле слишком много заметок; исходный файл сохранён.');
    for var Value in Rows do
    begin
      if not (Value is TJSONObject) then raise Exception.Create('Повреждена заметка. Исходный файл не изменён.');
      Row:=TJSONObject(Value);
      Note:=Default(TReaderAnnotation);
      Note.ID:=Row.GetValue<string>('id',''); Note.BookID:=Row.GetValue<string>('book','');
      Note.BookTitle:=Row.GetValue<string>('bookTitle',''); Note.Title:=Row.GetValue<string>('title','');
      Note.Text:=Row.GetValue<string>('text',''); Note.Quote:=Row.GetValue<string>('quote','');
      Note.Place:=Row.GetValue<string>('place',''); Note.Created:=Row.GetValue<string>('created','');
      Note.Position:=Row.GetValue<Integer>('position',-1);
      First:=Row.GetValue('rangeStart'); Last:=Row.GetValue('rangeEnd'); PageText:=Row.GetValue('rangeIsPageText');
      if Assigned(First) or Assigned(Last) or Assigned(PageText) then
      begin
        Note.RangeStart:=RangeNumber(First); Note.RangeEnd:=RangeNumber(Last);
        if Note.RangeEnd<=Note.RangeStart then
          raise Exception.Create('Повреждён диапазон заметки. Исходный файл не изменён.');
        if Assigned(PageText) then
        begin
          if not (PageText is TJSONBool) then
            raise Exception.Create('Повреждён тип диапазона заметки. Исходный файл не изменён.');
          Note.RangeIsPageText:=TJSONBool(PageText).AsBoolean;
        end;
      end;
      if (Note.ID='') or (Note.BookID='') or (Note.Position<0) or IDs.ContainsKey(Note.ID) then
        raise Exception.Create('Некорректная заметка. Исходный файл не изменён.');
      IDs.Add(Note.ID,True); List.Add(Note);
    end;
    FItems:=List.ToArray; FLoadedHash:=AnnotationHash(Bytes);
  finally IDs.Free; List.Free; JSON.Free; end;
end;

procedure TReaderAnnotations.Save;
var JSON, Row: TJSONObject; Rows: TJSONArray; Temporary: string; Stream: TFileStream; Bytes: TBytes; Lock: THandle; Error: Cardinal;
begin
  ForceDirectories(ExtractFilePath(FFileName));
  Lock:=CreateFile(PChar(FFileName+'.lock'),GENERIC_READ or GENERIC_WRITE,0,nil,OPEN_ALWAYS,FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE,0);
  if Lock=INVALID_HANDLE_VALUE then raise Exception.Create('Заметки сейчас сохраняются в другом окне. Повторите сохранение.');
  try
  if TFile.Exists(FFileName) then
  begin
    if (FLoadedHash='') or (THashSHA2.GetHashStringFromFile(FFileName)<>FLoadedHash) then
      raise Exception.Create('Заметки были изменены в другом окне. Закройте и снова откройте список; исходный файл сохранён.');
  end
  else if FLoadedHash<>'' then raise Exception.Create('Файл заметок перемещён. Исходные записи в памяти сохранены.');
  JSON:=TJSONObject.Create; Temporary:=FFileName+'.new-'+TGUID.NewGuid.ToString;
  try
    JSON.AddPair('version',TJSONNumber.Create(1)); Rows:=TJSONArray.Create; JSON.AddPair('notes',Rows);
    for var Note in FItems do
    begin
      Row:=TJSONObject.Create; Rows.AddElement(Row);
      Row.AddPair('id',Note.ID); Row.AddPair('book',Note.BookID); Row.AddPair('bookTitle',Note.BookTitle);
      Row.AddPair('title',Note.Title); Row.AddPair('text',Note.Text); Row.AddPair('quote',Note.Quote);
      Row.AddPair('place',Note.Place); Row.AddPair('created',Note.Created);
      Row.AddPair('position',TJSONNumber.Create(Note.Position));
      if ReaderAnnotationHasRange(Note) then
      begin
        Row.AddPair('rangeStart',TJSONNumber.Create(Note.RangeStart));
        Row.AddPair('rangeEnd',TJSONNumber.Create(Note.RangeEnd));
        Row.AddPair('rangeIsPageText',TJSONBool.Create(Note.RangeIsPageText));
      end;
    end;
    Bytes:=TEncoding.UTF8.GetBytes(JSON.ToJSON);
    if Length(Bytes)>64*1024*1024 then raise Exception.Create('Заметки не сохранены: файл превысит 64 МБ.');
    ForceDirectories(ExtractFilePath(FFileName));
    Stream:=TFileStream.Create(Temporary,fmCreate);
    try
      if Length(Bytes)>0 then Stream.WriteBuffer(Bytes[0],Length(Bytes));
      if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError;
    finally Stream.Free; end;
    // Publish a flushed complete document. Retain the previous good revision.
    if TFile.Exists(FFileName) then
    begin
      if not ReplaceFile(PChar(FFileName),PChar(Temporary),PChar(FFileName+'.bak'),0,nil,nil) then
      begin
        Error:=GetLastError;
        // ReplaceFile can leave the old revision under its backup name after
        // a partial rename failure. Restore only when the destination is absent.
        if not TFile.Exists(FFileName) and TFile.Exists(FFileName+'.bak') then
          MoveFileEx(PChar(FFileName+'.bak'),PChar(FFileName),MOVEFILE_WRITE_THROUGH);
        RaiseLastOSError(Error);
      end;
    end
    else if not MoveFileEx(PChar(Temporary),PChar(FFileName),MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
    FLoadedHash:=AnnotationHash(Bytes);
  finally
    JSON.Free;
    if TFile.Exists(Temporary) then TFile.Delete(Temporary);
  end;
  finally CloseHandle(Lock); end;
end;

function TReaderAnnotations.Items(const BookID: string): TArray<TReaderAnnotation>;
var List: TList<TReaderAnnotation>;
begin
  List:=TList<TReaderAnnotation>.Create;
  try
    for var Note in FItems do if (BookID='') or (Note.BookID=BookID) then List.Add(Note);
    Result:=List.ToArray;
  finally List.Free; end;
end;

function TReaderAnnotations.Put(const Note: TReaderAnnotation): string;
var Entry: TReaderAnnotation; Index: Integer; Old: TArray<TReaderAnnotation>;
begin
  if (Note.BookID='') or (Note.Position<0) or (Length(Note.Title)>256) or
    (Length(Note.Text)>16384) or (Length(Note.Quote)>8192) then
    raise Exception.Create('Название: до 256 знаков, мысль: до 16 384, цитата: до 8192.');
  if ((Note.RangeStart<>0) or (Note.RangeEnd<>0)) and not ReaderAnnotationHasRange(Note) then
    raise Exception.Create('Некорректный диапазон заметки. Изменения не сохранены.');
  if (Note.Text.Trim='') and (Note.Title.Trim='') then raise Exception.Create('Добавьте название или текст заметки.');
  Entry:=Note; Index:=-1;
  if Entry.ID<>'' then for var I:=0 to High(FItems) do if FItems[I].ID=Entry.ID then begin Index:=I; Break; end;
  if (Entry.ID<>'') and (Index<0) then raise Exception.Create('Эта заметка больше не найдена.');
  if (Index>=0) and (FItems[Index].BookID<>Entry.BookID) then raise Exception.Create('Заметка относится к другой книге.');
  if (Index<0) and (Length(FItems)>=10000) then raise Exception.Create('Сохранено 10 000 заметок. Экспортируйте записи перед удалением.');
  if Entry.ID='' then Entry.ID:=TGUID.NewGuid.ToString;
  if Entry.Created='' then Entry.Created:=DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True);
  Old:=Copy(FItems);
  try
    if Index<0 then begin Index:=Length(FItems); SetLength(FItems,Index+1); end;
    FItems[Index]:=Entry; Save;
  except FItems:=Old; raise; end;
  Result:=Entry.ID;
end;

procedure TReaderAnnotations.Remove(const ID: string);
var Old: TArray<TReaderAnnotation>; At: Integer;
begin
  At:=-1; for var I:=0 to High(FItems) do if FItems[I].ID=ID then begin At:=I; Break; end;
  if At<0 then Exit;
  Old:=Copy(FItems);
  try
    for var I:=At to High(FItems)-1 do FItems[I]:=FItems[I+1];
    SetLength(FItems,Length(FItems)-1); Save;
  except FItems:=Old; raise; end;
end;

type
  TAnnotationExportStyle = record
    Font, Background, Heading, Accent, BodyCSS, NoteCSS, HeadingCSS, QuoteCSS: string;
    Margin, ParagraphAfter, LineSpacing: Integer;
    CenterHeadings, ContextRight, Cards, PaperBorder: Boolean;
  end;

function AnnotationExportStyle(Style: Integer): TAnnotationExportStyle;
begin
  Result:=Default(TAnnotationExportStyle);
  Result.Font:='Georgia'; Result.Background:='FFFAF0'; Result.Heading:='594A70'; Result.Accent:='8299B0';
  Result.Margin:=1440; Result.ParagraphAfter:=180; Result.LineSpacing:=340;
  Result.CenterHeadings:=True; Result.ContextRight:=True;
  Result.BodyCSS:='max-width:760px;margin:40px auto;padding:0 28px;line-height:1.75';
  Result.NoteCSS:='margin:28px 0;padding:24px 0;border-bottom:3px double #b8ada0';
  Result.HeadingCSS:='text-align:center;margin:.5em 0';
  Result.QuoteCSS:='margin:18px 28px;padding:8px 18px;border-left:2px solid #8299b0;font-style:italic';
  case Style of
    0:
      begin
        Result.Font:='Arial'; Result.Background:='FFFFFF'; Result.Heading:='252525';
        Result.Margin:=1134; Result.ParagraphAfter:=100; Result.LineSpacing:=270;
        Result.CenterHeadings:=False; Result.ContextRight:=False;
        Result.BodyCSS:='max-width:900px;margin:24px auto;padding:0 20px;line-height:1.4';
        Result.NoteCSS:='padding:16px 0;border-bottom:1px solid #bbb';
        Result.HeadingCSS:='text-align:left;margin:.2em 0';
        Result.QuoteCSS:='margin:12px 0;padding:8px 12px;border-left:2px solid #777';
      end;
    2:
      begin
        Result.Font:='Calibri'; Result.Background:='FFFFFF'; Result.Heading:='285E82'; Result.Accent:='285E82';
        Result.Margin:=1080; Result.ParagraphAfter:=140; Result.LineSpacing:=300; Result.Cards:=True;
        Result.CenterHeadings:=False; Result.ContextRight:=False;
        Result.BodyCSS:='max-width:860px;margin:32px auto;padding:0 24px;line-height:1.6';
        Result.NoteCSS:='margin:24px 0;padding:24px;border:1px solid #d7e3eb;border-left:6px solid #285e82;border-radius:8px;background:#fafcfe';
        Result.HeadingCSS:='text-align:left;margin:.3em 0';
        Result.QuoteCSS:='margin:16px 0;padding:12px 18px;background:#eaf2f7;border-left:3px solid #285e82';
      end;
    3:
      begin
        Result.Background:='F5ECD9'; Result.Heading:='725739'; Result.Accent:='967B56';
        Result.Margin:=1361; Result.ParagraphAfter:=220; Result.LineSpacing:=360; Result.PaperBorder:=True;
        Result.CenterHeadings:=False; Result.ContextRight:=True;
        Result.BodyCSS:='max-width:780px;margin:36px auto;padding:24px 36px;border:1px solid #c7b99f;line-height:1.8';
        Result.NoteCSS:='margin:22px 0;padding:20px 18px;border-bottom:1px dashed #aa9676;background:#fffaf0';
        Result.HeadingCSS:='text-align:left;margin:.4em 0';
        Result.QuoteCSS:='margin:16px 20px;padding:12px 16px;border-top:1px solid #aa9676;border-bottom:1px solid #aa9676;font-style:italic';
      end;
  end;
end;

function ReaderAnnotationsText(const Items: TArray<TReaderAnnotation>; HTML: Boolean; Style: Integer): string;
var Builder: TStringBuilder; Layout: TAnnotationExportStyle;
  function Escape(const Value: string): string;
  begin Result:=TNetEncoding.HTML.Encode(Value).Replace(#13#10,#10).Replace(#13,#10).Replace(#10,'<br>'); end;
begin
  Builder:=TStringBuilder.Create;
  try
    Layout:=AnnotationExportStyle(Style);
    if HTML then Builder.Append('<!doctype html><html lang="ru"><meta charset="utf-8"><title>Закладки и заметки</title>'+
      '<style>body{font-family:'+Layout.Font+';font-size:18px;color:#252525;background:#'+Layout.Background+';'+Layout.BodyCSS+'}'+
      'article{'+Layout.NoteCSS+'}h2,h3{color:#'+Layout.Heading+';'+Layout.HeadingCSS+'}'+
      'small{display:block;color:#555}blockquote{'+Layout.QuoteCSS+'}.thought{white-space:normal}'+
      '@media print{body{max-width:none;margin:0}article{break-inside:avoid}}</style><h1>Закладки и заметки</h1>');
    for var Note in Items do
      if HTML then
      begin
        Builder.Append('<article><header><h2>'+Escape(Note.BookTitle)+'</h2><h3>'+
          Escape(ReaderAnnotationDisplayTitle(Note))+'</h3><small>'+
          Escape(AnnotationContextText(Note))+'</small></header>');
        if Note.Quote<>'' then Builder.Append('<blockquote>'+Escape(Note.Quote)+'</blockquote>');
        if Note.Text<>'' then Builder.Append('<p class="thought">'+Escape(Note.Text)+'</p>');
        Builder.Append('</article>');
      end
      else
      begin
        Builder.AppendLine(Note.BookTitle).AppendLine(ReaderAnnotationDisplayTitle(Note)).AppendLine(AnnotationContextText(Note));
        if Note.Quote<>'' then Builder.AppendLine('Цитата: '+Note.Quote);
        if Note.Text<>'' then Builder.AppendLine('Заметка: '+Note.Text);
        Builder.AppendLine;
      end;
    if HTML then Builder.Append('</html>'); Result:=Builder.ToString;
  finally Builder.Free; end;
end;

function ReaderAnnotationsDocx(const Items: TArray<TReaderAnnotation>; Style: Integer): TBytes;
var Zip: TZipFile; Stream: TMemoryStream; XML: TStringBuilder; Layout: TAnnotationExportStyle;
  HeadingAlignment, ContextAlignment, PaperProperties, SectionBorder: string;
  function Escape(const Value: string): string;
  begin
    Result:='';
    for var C in Value do if (Ord(C)>=32) or CharInSet(C,[#9,#10,#13]) then Result:=Result+C;
    Result:=Result.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;');
  end;
  procedure AddPart(const Name, Text: string);
  begin Zip.Add(TEncoding.UTF8.GetBytes(Text),Name); end;
  procedure Paragraph(const Text, Name: string; KeepLines: Boolean=False);
  var Pagination: string;
  begin
    Pagination:=''; if KeepLines then Pagination:='<w:keepLines/>';
    for var Line in Text.Replace(#13#10,#10).Replace(#13,#10).Split([#10]) do
      XML.Append('<w:p><w:pPr><w:pStyle w:val="'+Name+'"/>'+Pagination+'</w:pPr><w:r><w:t xml:space="preserve">'+Escape(Line)+'</w:t></w:r></w:p>');
  end;
begin
  Layout:=AnnotationExportStyle(Style); HeadingAlignment:=''; ContextAlignment:=''; PaperProperties:=''; SectionBorder:='';
  if Layout.CenterHeadings then HeadingAlignment:='<w:jc w:val="center"/>';
  if Layout.ContextRight then ContextAlignment:='<w:jc w:val="right"/>';
  if Layout.PaperBorder then
  begin
    PaperProperties:='<w:shd w:val="clear" w:color="auto" w:fill="'+Layout.Background+'"/>';
    SectionBorder:='<w:pgBorders w:offsetFrom="text">'+
      '<w:top w:val="single" w:sz="6" w:space="12" w:color="'+Layout.Accent+'"/>'+
      '<w:left w:val="single" w:sz="6" w:space="12" w:color="'+Layout.Accent+'"/>'+
      '<w:bottom w:val="single" w:sz="6" w:space="12" w:color="'+Layout.Accent+'"/>'+
      '<w:right w:val="single" w:sz="6" w:space="12" w:color="'+Layout.Accent+'"/></w:pgBorders>';
  end;
  Zip:=TZipFile.Create; Stream:=TMemoryStream.Create; XML:=TStringBuilder.Create;
  try
    Zip.Open(Stream,zmWrite);
    AddPart('[Content_Types].xml','<?xml version="1.0" encoding="UTF-8"?>'+
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'+
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'+
      '<Default Extension="xml" ContentType="application/xml"/>'+
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'+
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>');
    AddPart('_rels/.rels','<?xml version="1.0" encoding="UTF-8"?>'+
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>');
    AddPart('word/_rels/document.xml.rels','<?xml version="1.0" encoding="UTF-8"?>'+
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>');
    AddPart('word/styles.xml','<?xml version="1.0" encoding="UTF-8"?>'+
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'+
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/>'+
      '<w:pPr><w:widowControl/>'+PaperProperties+'<w:spacing w:after="'+IntToStr(Layout.ParagraphAfter)+'" w:line="'+IntToStr(Layout.LineSpacing)+'" w:lineRule="auto"/></w:pPr>'+
      '<w:rPr><w:rFonts w:ascii="'+Layout.Font+'" w:hAnsi="'+Layout.Font+'" w:cs="'+Layout.Font+'"/><w:sz w:val="24"/><w:color w:val="252525"/></w:rPr></w:style>'+
      '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>'+
      '<w:pPr><w:keepNext/><w:spacing w:before="300" w:after="140"/>'+HeadingAlignment+'<w:outlineLvl w:val="0"/></w:pPr>'+
      '<w:rPr><w:b/><w:sz w:val="36"/><w:color w:val="'+Layout.Heading+'"/></w:rPr></w:style>'+
      '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>'+
      '<w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="'+Layout.Heading+'"/></w:rPr></w:style>'+
      '<w:style w:type="paragraph" w:styleId="Context"><w:name w:val="Context"/><w:basedOn w:val="Normal"/>'+
      '<w:pPr><w:keepNext/>'+ContextAlignment+'</w:pPr><w:rPr><w:sz w:val="20"/><w:color w:val="555555"/></w:rPr></w:style>'+
      '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>'+
      '<w:pPr><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="'+Layout.Accent+'"/></w:pBdr><w:ind w:left="360" w:right="180"/></w:pPr><w:rPr><w:i/></w:rPr></w:style></w:styles>');
    XML.Append('<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'+
      '<w:background w:color="'+Layout.Background+'"/><w:body>');
    Paragraph('Закладки и заметки','Heading1');
    for var Note in Items do
    begin
      if Layout.Cards then
        XML.Append('<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>'+
          '<w:tblBorders><w:top w:val="single" w:sz="4" w:color="D7E3EB"/>'+
          '<w:left w:val="single" w:sz="20" w:color="'+Layout.Accent+'"/>'+
          '<w:bottom w:val="single" w:sz="4" w:color="D7E3EB"/>'+
          '<w:right w:val="single" w:sz="4" w:color="D7E3EB"/></w:tblBorders>'+
          '<w:tblCellMar><w:top w:w="240" w:type="dxa"/><w:left w:w="240" w:type="dxa"/>'+
          '<w:bottom w:w="240" w:type="dxa"/><w:right w:w="240" w:type="dxa"/></w:tblCellMar>'+
          '</w:tblPr><w:tblGrid><w:gridCol w:w="9000"/></w:tblGrid><w:tr><w:tc>'+
          '<w:tcPr><w:tcW w:w="9000" w:type="dxa"/><w:shd w:val="clear" w:color="auto" w:fill="FAFCFE"/></w:tcPr>');
      Paragraph(Note.BookTitle,'Heading1'); Paragraph(ReaderAnnotationDisplayTitle(Note),'Heading2');
      Paragraph(AnnotationContextText(Note),'Context');
      // Only short quotes stay together; long quotations may span pages.
      if Note.Quote<>'' then Paragraph(Note.Quote,'Quote',Length(Note.Quote)<=400);
      if Note.Text<>'' then Paragraph(Note.Text,'Normal');
      if Layout.Cards then XML.Append('</w:tc></w:tr></w:tbl><w:p/>');
    end;
    XML.Append('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="'+IntToStr(Layout.Margin)+
      '" w:right="'+IntToStr(Layout.Margin)+'" w:bottom="'+IntToStr(Layout.Margin)+'" w:left="'+IntToStr(Layout.Margin)+'"/>'+
      SectionBorder+'</w:sectPr></w:body></w:document>');
    AddPart('word/document.xml',XML.ToString); Zip.Close;
    SetLength(Result,Stream.Size); Stream.Position:=0; if Length(Result)>0 then Stream.ReadBuffer(Result[0],Length(Result));
  finally Zip.Free; Stream.Free; XML.Free; end;
end;
end.
