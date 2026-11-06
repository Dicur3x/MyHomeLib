{ HomeLibre. Original project copyright (C) 2008-2026 Oleksiy Penkov.
  A manually started, read-only OPDS 1.2 catalog for one local collection. }
unit unit_OPDSServer;

interface

uses
  System.Classes, System.SysUtils, unit_Globals, SQLiteWrap,
  IdHTTPServer, IdCustomHTTPServer, IdContext, unit_OPDSTlsTransport;

type
  THomeLibOPDSServer = class
  private
    FHTTP: TIdHTTPServer;
    FTls: TOPDSTlsTransport;
    FCollection: TCollectionInfo;
    FPrefix, FExternalBase, FLinkBase: string;
    FPort: Integer;
    FUpdated: string;
    procedure Command(AContext: TIdContext; ARequest: TIdHTTPRequestInfo;
      AResponse: TIdHTTPResponseInfo);
    procedure Connected(AContext: TIdContext);
    function FeedStart(const Title, Route, Kind: string): string;
    function RootFeed: string;
    function NavigationFeed(DB: TSQLiteDatabase; const Route: string;
      const Page: Integer): string;
    function BooksFeed(DB: TSQLiteDatabase; const Route, Search, Filter: string;
      const Page: Integer): string;
    function ReadBook(DB: TSQLiteDatabase; const BookID: Integer): TBookRecord;
    function GetActive: Boolean;
    procedure StartHTTP(const Collection: TCollectionInfo; Port: Integer;
      AllowLAN: Boolean; const ExternalBase: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(const Collection: TCollectionInfo; const Port: Integer;
      const AllowLAN: Boolean; const ExternalBase: string = '');
    procedure StartHTTPS(const Collection: TCollectionInfo; Port: Integer; AllowLAN: Boolean;
      const Hostname, Certificate, PrivateKey, Tool: string);
    procedure Stop;
    function CatalogURL(const Host: string): string;
    property Active: Boolean read GetActive;
  end;

function OPDSXmlEscape(const Value: string): string;

implementation

uses
  System.DateUtils, System.NetEncoding, System.StrUtils, System.RegularExpressions,
  IdGlobal, unit_Consts, unit_Errors;

const
  PAGE_SIZE = 50;
  NAV_TYPE = 'application/atom+xml;profile=opds-catalog;kind=navigation';
  BOOK_TYPE = 'application/atom+xml;profile=opds-catalog;kind=acquisition';

function OPDSXmlEscape(const Value: string): string;
var
  C: Char;
begin
  Result := '';
  for C in Value do
    case C of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&apos;';
      #9, #10, #13: Result := Result + C;
    else
      if (Ord(C) >= 32) and (Ord(C) < $FFFE) then Result := Result + C;
    end;
end;

function Link(const Rel, Href, Mime: string): string;
begin
  Result := '<link rel="' + Rel + '" href="' + OPDSXmlEscape(Href) +
    '" type="' + Mime + '"/>';
end;

function DownloadExtension(const Ext: string): string;
var
  C: Char;
begin
  Result := LowerCase(Ext);
  if (Result <> '') and (Result[1] <> '.') then Result := '.' + Result;
  if (Length(Result) < 2) or (Length(Result) > 12) or (Result[1] <> '.') then Exit('.bin');
  for C in Copy(Result, 2, MaxInt) do
    if not CharInSet(C, ['a'..'z', '0'..'9']) then Exit('.bin');
end;

function DownloadMime(const Ext: string): string;
begin
  Result := 'application/octet-stream';
  case IndexStr(DownloadExtension(Ext), ['.fb2', '.epub', '.pdf', '.txt']) of
    0: Result := 'application/x-fictionbook+xml';
    1: Result := 'application/epub+zip';
    2: Result := 'application/pdf';
    3: Result := 'text/plain';
  end;
end;

function Entry(const ID, Title, Updated, Href, Mime: string): string;
begin
  Result := '<entry><id>' + OPDSXmlEscape(ID) + '</id><title>' +
    OPDSXmlEscape(Title) + '</title><updated>' + Updated + '</updated>' +
    '<content type="text">' + OPDSXmlEscape(Title) + '</content>' +
    Link('subsection', Href, Mime) + '</entry>';
end;

constructor THomeLibOPDSServer.Create;
begin
  inherited Create;
  FHTTP := TIdHTTPServer.Create(nil);
  FHTTP.MaxConnections := 8;
  FHTTP.KeepAlive := False;
  FHTTP.OnConnect := Connected;
  FHTTP.OnCommandGet := Command;
  FHTTP.OnCommandOther := Command;
end;

destructor THomeLibOPDSServer.Destroy;
begin
  Stop;
  FHTTP.Free;
  inherited Destroy;
end;

procedure THomeLibOPDSServer.Connected(AContext: TIdContext);
begin
  AContext.Connection.IOHandler.ReadTimeout := 10000;
end;

function THomeLibOPDSServer.GetActive: Boolean;
begin
  Result := FHTTP.Active and (not Assigned(FTls) or FTls.Active);
end;

function CheckedExternalBase(const Value: string): string;
var Match: TMatch; Port: Integer; Part: string;
begin
  Result := Trim(Value);
  if Result = '' then Exit;
  if Length(Result)>1024 then
    raise EArgumentException.Create('Адрес внешнего сервера слишком длинный.');
  if Result.EndsWith('/') then SetLength(Result, Length(Result)-1);
  Match := TRegEx.Match(Result,
    '\Ahttps://[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*(?::([0-9]{1,5}))?((?:/[a-z0-9._~-]+)*)\z',
    [roIgnoreCase]);
  if not Match.Success then
    raise EArgumentException.Create('Укажите адрес HTTPS внешнего сервера, например https://books.example.org/library.');
  if Match.Groups[1].Value <> '' then
  begin
    Port := StrToInt(Match.Groups[1].Value);
    if (Port < 1) or (Port > 65535) then
      raise EArgumentException.Create('Порт в адресе внешнего сервера должен быть от 1 до 65535.');
  end;
  for Part in Match.Groups[2].Value.Split(['/']) do
    if (Part = '.') or (Part = '..') then
      raise EArgumentException.Create('Адрес внешнего сервера должен содержать путь без «.» и «..».');
end;

procedure THomeLibOPDSServer.Start(const Collection: TCollectionInfo;
  const Port: Integer; const AllowLAN: Boolean; const ExternalBase: string);
begin
  Stop;
  if (Port < 1024) or (Port > 65535) then
    raise EArgumentException.Create('Укажите порт от 1024 до 65535.');
  StartHTTP(Collection, Port, AllowLAN, ExternalBase);
end;

procedure THomeLibOPDSServer.StartHTTPS(const Collection: TCollectionInfo;
  Port: Integer; AllowLAN: Boolean; const Hostname, Certificate, PrivateKey, Tool: string);
var PublicBase: string;
begin
  Stop;
  if (Port < 1024) or (Port > 65535) then
    raise EArgumentException.Create('Укажите порт от 1024 до 65535.');
  PublicBase := CheckedExternalBase('https://' + Trim(Hostname) + ':' + Port.ToString);
  try
    StartHTTP(Collection, 0, False, PublicBase);
    if FPort = Port then
    begin
      FHTTP.Active := False;
      StartHTTP(Collection, 0, False, PublicBase);
    end;
    FTls := TOPDSTlsTransport.Create(Tool, FPrefix, Trim(Hostname), Certificate, PrivateKey,
      Port, FPort, AllowLAN);
  except
    Stop;
    raise;
  end;
end;

procedure THomeLibOPDSServer.StartHTTP(const Collection: TCollectionInfo;
  Port: Integer; AllowLAN: Boolean; const ExternalBase: string);
var
  DB: TSQLiteDatabase;
  Key: TGUID;
begin
  if isOnlineCollection(Collection.CollectionType) then
    raise Exception.Create('Каталог для читалки доступен для локальных коллекций. Выберите коллекцию с книгами на диске.');
  FExternalBase := CheckedExternalBase(ExternalBase);
  if AllowLAN and (FExternalBase <> '') then
    raise EArgumentException.Create('В режиме внешнего HTTPS-сервера HomeLibre принимает подключения только с этого компьютера.');
  if not FileExists(Collection.DBFileName) then
    raise Exception.Create('Файл выбранной коллекции не найден.');
  DB := TSQLiteDatabase.CreateReadOnly(Collection.DBFileName);
  try
    DB.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE BookID < 0');
  finally
    DB.Free;
  end;
  FCollection := Collection;
  FPort := Port;
  CreateGUID(Key);
  FPrefix := '/' + LowerCase(StringReplace(StringReplace(
    GUIDToString(Key), '{', '', []), '}', '', [])) + '/opds';
  FLinkBase := FExternalBase + FPrefix;
  FUpdated := DateToISO8601(Now, False);
  FHTTP.Bindings.Clear;
  with FHTTP.Bindings.Add do
  begin
    IPVersion := Id_IPv4;
    if AllowLAN then IP := '0.0.0.0' else IP := '127.0.0.1';
    Port := FPort;
  end;
  FHTTP.Active := True;
  FPort := FHTTP.Bindings[0].Port;
end;

procedure THomeLibOPDSServer.Stop;
begin
  FreeAndNil(FTls);
  if Assigned(FHTTP) then FHTTP.Active := False;
end;

function THomeLibOPDSServer.CatalogURL(const Host: string): string;
begin
  if FExternalBase <> '' then Exit(FLinkBase);
  Result := 'http://' + Host + ':' + IntToStr(FPort) + FPrefix;
end;

function THomeLibOPDSServer.FeedStart(const Title, Route, Kind: string): string;
begin
  Result := '<?xml version="1.0" encoding="utf-8"?>' +
    '<feed xmlns="http://www.w3.org/2005/Atom" ' +
    'xmlns:dc="http://purl.org/dc/terms/">' +
    '<id>urn:homelibru:collection:' + IntToStr(FCollection.ID) + ':' +
    OPDSXmlEscape(Route) + '</id><title>' + OPDSXmlEscape(Title) +
    '</title><updated>' + FUpdated + '</updated>' +
    '<author><name>HomeLibre</name></author>' +
    Link('self', FLinkBase + Route, Kind) + Link('start', FLinkBase, NAV_TYPE) +
    Link('search', FLinkBase + '/search.xml', 'application/opensearchdescription+xml');
end;

function THomeLibOPDSServer.RootFeed: string;
begin
  Result := FeedStart(FCollection.DisplayName, '', NAV_TYPE) +
    Entry('urn:homelibru:books', 'Все книги', FUpdated, FLinkBase + '/books', BOOK_TYPE) +
    Entry('urn:homelibru:authors', 'Авторы', FUpdated, FLinkBase + '/authors', NAV_TYPE) +
    Entry('urn:homelibru:genres', 'Жанры', FUpdated, FLinkBase + '/genres', NAV_TYPE) +
    Entry('urn:homelibru:series', 'Книжные серии', FUpdated, FLinkBase + '/series', NAV_TYPE) +
    '</feed>';
end;

function THomeLibOPDSServer.NavigationFeed(DB: TSQLiteDatabase;
  const Route: string; const Page: Integer): string;
var
  SQL, Title, Target, Name, ID: string;
  Q: TSQLiteQuery;
  Count: Integer;
begin
  if Route = '/authors' then
  begin
    Title := 'Авторы'; Target := '/author';
    SQL := 'SELECT a.AuthorID, trim(a.LastName || '' '' || coalesce(a.FirstName, '''') || ' +
      ''' '' || coalesce(a.MiddleName, '''')) FROM Authors a WHERE EXISTS ' +
      '(SELECT 1 FROM Author_List l JOIN Books b ON b.BookID=l.BookID ' +
      'WHERE l.AuthorID=a.AuthorID AND b.IsDeleted=0) ORDER BY a.LastName, a.FirstName, a.AuthorID';
  end
  else if Route = '/genres' then
  begin
    Title := 'Жанры'; Target := '/genre';
    SQL := 'SELECT g.GenreCode, g.GenreAlias FROM Genres g WHERE EXISTS ' +
      '(SELECT 1 FROM Genre_List l JOIN Books b ON b.BookID=l.BookID ' +
      'WHERE l.GenreCode=g.GenreCode AND b.IsDeleted=0) ORDER BY g.GenreAlias, g.GenreCode';
  end
  else
  begin
    Title := 'Книжные серии'; Target := '/cycle';
    SQL := 'SELECT s.SeriesID, s.SeriesTitle FROM Series s WHERE EXISTS ' +
      '(SELECT 1 FROM Series_List l JOIN Books b ON b.BookID=l.BookID ' +
      'WHERE l.SeriesID=s.SeriesID AND b.IsDeleted=0) ORDER BY s.SeriesTitle, s.SeriesID';
  end;
  SQL := SQL + ' LIMIT ? OFFSET ?';
  Result := FeedStart(Title, Route + '?page=' + IntToStr(Page), NAV_TYPE);
  Q := DB.NewQuery(SQL, [PAGE_SIZE + 1, Page * PAGE_SIZE]);
  try
    Q.Open;
    Count := 0;
    while not Q.Eof and (Count < PAGE_SIZE) do
    begin
      ID := Q.FieldAsString(0); Name := Q.FieldAsString(1);
      Result := Result + Entry('urn:homelibru:' + Target + ':' + ID,
        Name, FUpdated, FLinkBase + Target + '?id=' +
        TNetEncoding.URL.EncodeQuery(ID), BOOK_TYPE);
      Inc(Count); Q.Next;
    end;
    if not Q.Eof then
      Result := Result + Link('next', FLinkBase + Route + '?page=' + IntToStr(Page + 1), NAV_TYPE);
  finally
    Q.Free;
  end;
  if Page > 0 then
    Result := Result + Link('previous', FLinkBase + Route + '?page=' + IntToStr(Page - 1), NAV_TYPE);
  Result := Result + '</feed>';
end;

function THomeLibOPDSServer.BooksFeed(DB: TSQLiteDatabase;
  const Route, Search, Filter: string; const Page: Integer): string;
var
  SQL, Condition, Params, Title, ID, Mime, AuthorName: string;
  Q, Authors: TSQLiteQuery;
  Count: Integer;
begin
  Title := 'Все книги'; Condition := ''; Params := '';
  if Route = '/author' then
  begin
    Title := 'Книги автора';
    Condition := ' AND EXISTS (SELECT 1 FROM Author_List l WHERE l.BookID=b.BookID AND l.AuthorID=?)';
  end
  else if Route = '/genre' then
  begin
    Title := 'Книги жанра';
    Condition := ' AND EXISTS (SELECT 1 FROM Genre_List l WHERE l.BookID=b.BookID AND l.GenreCode=?)';
  end
  else if Route = '/cycle' then
  begin
    Title := 'Книги серии';
    Condition := ' AND EXISTS (SELECT 1 FROM Series_List l WHERE l.BookID=b.BookID AND l.SeriesID=?)';
  end
  else if Search <> '' then
  begin
    Title := 'Поиск: ' + Search;
    Condition := ' AND (instr(b.SearchTitle, ?)>0 OR EXISTS ' +
      '(SELECT 1 FROM Author_List l JOIN Authors a ON a.AuthorID=l.AuthorID ' +
      'WHERE l.BookID=b.BookID AND instr(a.SearchName, ?)>0))';
    Params := 'q=' + TNetEncoding.URL.EncodeQuery(Search) + '&';
  end;
  if Route <> '/books' then
    Params := 'id=' + TNetEncoding.URL.EncodeQuery(Filter) + '&';
  SQL := 'SELECT b.BookID, b.Title, b.Ext, b.Lang FROM Books b WHERE b.IsDeleted=0' +
    Condition + ' ORDER BY b.BookID DESC LIMIT ? OFFSET ?';
  if Route <> '/books' then
    Q := DB.NewQuery(SQL, [Filter, PAGE_SIZE + 1, Page * PAGE_SIZE])
  else if Search <> '' then
    Q := DB.NewQuery(SQL, [Search.ToUpper, Search.ToUpper, PAGE_SIZE + 1, Page * PAGE_SIZE])
  else
    Q := DB.NewQuery(SQL, [PAGE_SIZE + 1, Page * PAGE_SIZE]);
  Result := FeedStart(Title, Route + '?' + Params + 'page=' + IntToStr(Page), BOOK_TYPE);
  Authors := nil;
  try
    Q.Open;
    Count := 0;
    Authors := DB.NewQuery('SELECT trim(a.LastName || '' '' || coalesce(a.FirstName, '''') || ' +
      ''' '' || coalesce(a.MiddleName, '''')) FROM Authors a ' +
      'JOIN Author_List l ON l.AuthorID=a.AuthorID WHERE l.BookID=? ORDER BY a.AuthorID');
    while not Q.Eof and (Count < PAGE_SIZE) do
    begin
      ID := Q.FieldAsString(0);
      Mime := DownloadMime(Q.FieldAsString(2));
      Result := Result + '<entry><id>urn:homelibru:collection:' +
        IntToStr(FCollection.ID) + ':book:' + ID + '</id><title>' +
        OPDSXmlEscape(Q.FieldAsString(1)) + '</title><updated>' + FUpdated + '</updated>' +
        '<content type="text">' + OPDSXmlEscape(Q.FieldAsString(1)) + '</content>';
      Authors.Reset; Authors.SetParam(0, StrToInt(ID)); Authors.Open;
      while not Authors.Eof do
      begin
        AuthorName := Authors.FieldAsString(0);
        Result := Result + '<author><name>' + OPDSXmlEscape(AuthorName) + '</name></author>';
        Authors.Next;
      end;
      Result := Result + '<dc:language>' + OPDSXmlEscape(Q.FieldAsString(3)) + '</dc:language>' +
        Link('http://opds-spec.org/acquisition', FLinkBase + '/book/' + ID +
          DownloadExtension(Q.FieldAsString(2)), Mime) + '</entry>';
      Inc(Count); Q.Next;
    end;
    if not Q.Eof then
      Result := Result + Link('next', FLinkBase + Route + '?' + Params + 'page=' + IntToStr(Page + 1), BOOK_TYPE);
  finally
    Authors.Free; Q.Free;
  end;
  if Page > 0 then
    Result := Result + Link('previous', FLinkBase + Route + '?' + Params + 'page=' + IntToStr(Page - 1), BOOK_TYPE);
  Result := Result + '</feed>';
end;

function THomeLibOPDSServer.ReadBook(DB: TSQLiteDatabase;
  const BookID: Integer): TBookRecord;
var
  Q: TSQLiteQuery;
begin
  Result.Clear;
  Q := DB.NewQuery('SELECT Title, Folder, FileName, Ext, InsideNo, LibID FROM Books ' +
    'WHERE BookID=? AND IsDeleted=0', [BookID]);
  try
    Q.Open;
    if Q.Eof then Exit;
    Result.BookKey.BookID := BookID;
    Result.BookKey.DatabaseID := FCollection.ID;
    Result.Title := Q.FieldAsString(0);
    Result.Folder := Q.FieldAsString(1);
    Result.FileName := Q.FieldAsString(2);
    Result.FileExt := Q.FieldAsString(3);
    Result.InsideNo := Q.FieldAsInt(4);
    Result.LibID := Q.FieldAsString(5);
    Result.CollectionRoot := FCollection.GetRootPath;
  finally
    Q.Free;
  end;
end;

procedure THomeLibOPDSServer.Command(AContext: TIdContext;
  ARequest: TIdHTTPRequestInfo; AResponse: TIdHTTPResponseInfo);
var
  Route, Search, Filter, Body, BookPath, RequestedExt: string;
  Page, BookID, DotPosition: Integer;
  C: Char;
  DB: TSQLiteDatabase;
  Book: TBookRecord;
  Stream: TStream;
begin
  AResponse.ContentType := 'text/plain';
  AResponse.CharSet := 'utf-8';
  AResponse.CustomHeaders.Values['Cache-Control'] := 'no-store';
  AResponse.CustomHeaders.Values['X-Content-Type-Options'] := 'nosniff';
  AResponse.CloseConnection := True;
  if not SameText(ARequest.Command, 'GET') and not SameText(ARequest.Command, 'HEAD') then
  begin
    AResponse.ResponseNo := 405;
    AResponse.CustomHeaders.Values['Allow'] := 'GET, HEAD';
    AResponse.ContentText := 'Допустимы только GET и HEAD.'; Exit;
  end;
  if not ((ARequest.Document = FPrefix) or StartsStr(FPrefix + '/', ARequest.Document)) then
  begin
    AResponse.ResponseNo := 404; Exit;
  end;
  Route := Copy(ARequest.Document, Length(FPrefix) + 1, MaxInt);
  if Route = '/' then Route := '';
  Page := 0;
  if (ARequest.Params.Values['page'] <> '') and
    not TryStrToInt(ARequest.Params.Values['page'], Page) then
  begin
    AResponse.ResponseNo := 400; Exit;
  end;
  if (Page < 0) or (Page > 1000000) then
  begin
    AResponse.ResponseNo := 400; Exit;
  end;
  Search := Trim(ARequest.Params.Values['q']);
  Filter := ARequest.Params.Values['id'];
  if (Length(Search) > 200) or (Length(Filter) > 100) then
  begin
    AResponse.ResponseNo := 400; Exit;
  end;
  DB := nil;
  try
   try
    if Route = '' then
    begin
      Body := RootFeed; AResponse.ContentType := NAV_TYPE;
    end
    else if Route = '/search.xml' then
    begin
      Body := '<?xml version="1.0" encoding="utf-8"?>' +
        '<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">' +
        '<ShortName>HomeLibre</ShortName><Description>Поиск по названию и автору</Description>' +
        '<InputEncoding>UTF-8</InputEncoding><Url type="' + BOOK_TYPE + '" template="' +
        OPDSXmlEscape(CatalogURL(AContext.Connection.Socket.Binding.IP) +
        '/books?q={searchTerms}') + '"/></OpenSearchDescription>';
      AResponse.ContentType := 'application/opensearchdescription+xml';
    end
    else
    begin
      DB := TSQLiteDatabase.CreateReadOnly(FCollection.DBFileName);
      DB.ExecSQL('BEGIN');
      if (Route = '/authors') or (Route = '/genres') or (Route = '/series') then
      begin
        Body := NavigationFeed(DB, Route, Page); AResponse.ContentType := NAV_TYPE;
      end
      else if (Route = '/books') or (Route = '/author') or (Route = '/genre') or (Route = '/cycle') then
      begin
        Body := BooksFeed(DB, Route, Search, Filter, Page); AResponse.ContentType := BOOK_TYPE;
      end
      else if StartsStr('/book/', Route) then
      begin
        BookPath := Copy(Route, 7, MaxInt);
        RequestedExt := '';
        DotPosition := Pos('.', BookPath);
        if DotPosition > 0 then
        begin
          RequestedExt := Copy(BookPath, DotPosition, MaxInt);
          Delete(BookPath, DotPosition, MaxInt);
          if DownloadExtension(RequestedExt) <> LowerCase(RequestedExt) then
          begin
            AResponse.ResponseNo := 404; Exit;
          end;
        end;
        // The route contains only a decimal ID and its real format suffix.
        for C in BookPath do
          if not CharInSet(C, ['0'..'9']) then
          begin
            AResponse.ResponseNo := 404; Exit;
          end;
        if not TryStrToInt(BookPath, BookID) or (BookID <= 0) then
        begin
          AResponse.ResponseNo := 404; Exit;
        end;
        Book := ReadBook(DB, BookID);
        if (Book.BookKey.BookID <= 0) or ((RequestedExt <> '') and
          not SameText(RequestedExt, DownloadExtension(Book.FileExt))) then
        begin
          AResponse.ResponseNo := 404; Exit;
        end;
        Stream := Book.GetBookStream;
        if not Assigned(Stream) then
        begin
          AResponse.ResponseNo := 404; Exit;
        end;
        Stream.Position := 0;
        // The stream retains its own XML/text encoding and may be binary.
        AResponse.ContentType := DownloadMime(Book.FileExt);
        AResponse.CharSet := '';
        AResponse.CustomHeaders.Values['Content-Disposition'] :=
          'attachment; filename="book-' + IntToStr(BookID) + DownloadExtension(Book.FileExt) + '"';
        AResponse.FreeContentStream := True;
        AResponse.ContentStream := Stream;
        AResponse.ContentLength := Stream.Size;
        Exit;
      end
      else
      begin
        AResponse.ResponseNo := 404; Exit;
      end;
    end;
    AResponse.ContentStream := TStringStream.Create(Body, TEncoding.UTF8);
    AResponse.FreeContentStream := True;
    AResponse.ContentLength := AResponse.ContentStream.Size;
  except
    on E: EBookNotFound do
    begin
      AResponse.ResponseNo := 404;
      AResponse.ContentText := 'Файл книги не найден.';
    end;
    on E: Exception do
    begin
      AResponse.ResponseNo := 503;
      AResponse.ContentText := 'Не удалось прочитать коллекцию или книгу. Повторите попытку позже.';
    end;
  end;
   finally
    DB.Free;
   end;
end;

end.
