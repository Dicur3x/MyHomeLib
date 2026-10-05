program OPDSServerTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Zip,
  Winapi.Windows, Winapi.ActiveX, Vcl.Forms, IdHTTP,
  SQLiteWrap, SQLite3, unit_Globals, unit_Consts, dm_user,
  unit_OPDSServer in '..\Units\unit_OPDSServer.pas';

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then raise Exception.Create(MessageText);
end;

type
  TTestTcpRow = record
    State, LocalAddress, LocalPort, RemoteAddress, RemotePort: DWORD;
  end;
  PTestTcpRow = ^TTestTcpRow;

function TestGetTcpTable(Table: Pointer; var Size: DWORD; Ordered: BOOL): DWORD;
  stdcall; external 'iphlpapi.dll' name 'GetTcpTable';

procedure CheckWildcardListener(const Port: Integer);
var
  Buffer: TBytes;
  Size, Status, Count, I, Attempt, HostPort: DWORD;
  Row: PTestTcpRow;
begin
  Size := 0;
  Status := TestGetTcpTable(nil, Size, False);
  Require(Status = ERROR_INSUFFICIENT_BUFFER, 'Cannot query the IPv4 TCP table');
  for Attempt := 0 to 2 do
  begin
    Require((Size >= SizeOf(DWORD)) and (Size <= 1024 * 1024), 'Unexpected IPv4 TCP table size');
    SetLength(Buffer, Size);
    Status := TestGetTcpTable(@Buffer[0], Size, False);
    if Status <> ERROR_INSUFFICIENT_BUFFER then Break;
  end;
  Require(Status = ERROR_SUCCESS, 'Cannot read the IPv4 TCP table');
  Count := PDWORD(@Buffer[0])^;
  Require(Count <= (Size - SizeOf(DWORD)) div SizeOf(TTestTcpRow), 'Invalid IPv4 TCP table rows');
  if Count > 0 then
    for I := 0 to Count - 1 do
    begin
      Row := PTestTcpRow(PByte(@Buffer[0]) + SizeOf(DWORD) + I * SizeOf(TTestTcpRow));
      HostPort := ((Row.LocalPort and $FF) shl 8) or ((Row.LocalPort shr 8) and $FF);
      // MIB_TCP_STATE_LISTEN = 2. The port was reserved as unused by the runner.
      if (Row.State = 2) and (Row.LocalAddress = 0) and (HostPort = DWORD(Port)) then Exit;
    end;
  raise Exception.Create('AllowLAN did not bind an IPv4 wildcard listener');
end;

procedure CheckOnlineStartRejected(const Server: THomeLibOPDSServer;
  const Collection: TCollectionInfo; const Port: Integer);
var
  OnlineCollection: TCollectionInfo;
  Rejected: Boolean;
begin
  OnlineCollection := Collection;
  OnlineCollection.CollectionType := CT_EXTERNAL_ONLINE_FB;
  Require(isOnlineCollection(OnlineCollection.CollectionType), 'Online fixture flag is invalid');
  Rejected := False;
  try
    Server.Start(OnlineCollection, Port, False);
  except
    on E: Exception do
    begin
      Require((Pos('локальных коллекций', E.Message) > 0) and
        (Pos('книгами на диске', E.Message) > 0), 'Online rejection did not explain the local-only requirement');
      Rejected := True;
    end;
  end;
  Require(Rejected, 'OPDS accepted an online collection');
  Require(not Server.Active, 'Failed online Start left the OPDS server active');
end;

procedure CheckLANLoopback(const Server: THomeLibOPDSServer;
  const Collection: TCollectionInfo; const Port: Integer);
var
  Client: TIdHTTP;
  Body: string;
begin
  Server.Start(Collection, Port, True);
  try
    Require(Server.Active, 'LAN smoke server did not start');
    CheckWildcardListener(Port);
    Client := TIdHTTP.Create(nil);
    try
      Client.ConnectTimeout := 3000;
      Client.ReadTimeout := 3000;
      Body := Client.Get(Server.CatalogURL('127.0.0.1'));
      Require((Client.ResponseCode = 200) and
        (Pos('xmlns="http://www.w3.org/2005/Atom"', Body) > 0) and
        (Pos('HomeLib Ru', Body) > 0), 'Loopback request to the LAN listener failed');
    finally
      Client.Free;
    end;
    // Rejecting an online Start also has to stop an existing local listener.
    CheckOnlineStartRejected(Server, Collection, Port);
  finally
    Server.Stop;
  end;
  Require(not Server.Active, 'LAN smoke listener stayed active after Stop');
end;

procedure GuardFixture(const DBFileName, RootFolder: string; const Port: Integer);
var
  ExeRoot, TempRoot: string;
begin
  Require((ParamCount = 7) and (ParamStr(1) = 'server') and
    (ParamStr(5) = 'uselocaldata') and (ParamStr(6) = 'user') and
    (ParamStr(7) = 'mcpfixture'),
    'OPDSServerTest requires server <db> <root> <port> uselocaldata user mcpfixture');
  ExeRoot := ExcludeTrailingPathDelimiter(TPath.GetFullPath(ExtractFilePath(ParamStr(0))));
  TempRoot := ExcludeTrailingPathDelimiter(TPath.GetFullPath(TPath.GetTempPath));
  Require(SameText(ExtractFileDir(ExeRoot), TempRoot) and
    ExtractFileName(ExeRoot).StartsWith('homelib-opds-test-'),
    'OPDSServerTest refuses to run outside its throwaway temp directory');
  Require(SameText(TPath.GetFullPath(RootFolder), TPath.Combine(ExeRoot, 'mcpfixture')),
    'OPDSServerTest refuses an unrelated collection root');
  Require(SameText(TPath.GetFullPath(DBFileName), TPath.Combine(RootFolder, 'mcpfixture.hlc2')),
    'OPDSServerTest refuses an unrelated collection database');
  Require((Port >= 1024) and (Port <= 65535), 'Invalid test server port');
  Require(TFile.Exists(DBFileName) and TFile.Exists(TPath.Combine(ExeRoot, 'uselocaltemp')),
    'Fixture database and isolated temporary-path marker are required');
end;

procedure TestTriggersOn(pCtx: TSQLite3Context; nArgs: Integer; Args: TSQLite3Value); cdecl;
begin
  SQLite3_Result_Int(pCtx, 1);
end;

procedure TestFullAuthorName(pCtx: TSQLite3Context; nArgs: Integer; Args: TSQLite3Value); cdecl;
var
  LastName, FirstName, MiddleName, Name: string;
begin
  LastName := SQLite3_Value_text16(Args^); Inc(Args);
  FirstName := SQLite3_Value_text16(Args^); Inc(Args);
  MiddleName := SQLite3_Value_text16(Args^);
  Name := TAuthorData.FormatName(LastName, FirstName, MiddleName);
  if nArgs = 4 then Name := Name.ToUpper;
  SQLite3_Result_Text16(pCtx, PWideChar(Name), -1, SQLITE_TRANSIENT);
end;

procedure AddPaginationBooks(const DBFileName, RootFolder: string);
var
  DB: TSQLiteDatabase;
  Zip: TZipFile;
  AuthorID, DeletedAuthorID, EmptyAuthorID, CycleID, SecondaryCycleID: Integer;
  BookID, I: Integer;
  Title, BaseName, GenreCode, FB2, FileExt, FilePath: string;
begin
  // This writer runs before the OPDS server starts, only after the strict guard.
  DB := TSQLiteDatabase.Create(DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON', 0, TestTriggersOn);
    DB.AddFunction('MHL_FULLNAME', 3, TestFullAuthorName);
    DB.AddFunction('MHL_FULLNAME', 4, TestFullAuthorName);
    Require(DB.QuerySingleInt('SELECT count(*) FROM Books') = 6, 'Expected the fresh six-book MCP fixture');
    Require(DB.QuerySingleInt('SELECT max(BookID) FROM Books') = 6, 'Unexpected original fixture IDs');
    DB.ExecSQL('UPDATE Books SET BookSize=? WHERE BookID=3',
      [Length(TFile.ReadAllBytes(TPath.Combine(RootFolder, 'books\book3.fb2')))]);
    AuthorID := DB.QuerySingleInt('SELECT min(AuthorID) FROM Author_List WHERE BookID=1');
    GenreCode := DB.QuerySingleString('SELECT min(GenreCode) FROM Genre_List WHERE BookID=1');
    DB.ExecSQL('INSERT INTO Series(SeriesTitle) VALUES(?)', ['OPDS общий цикл']);
    CycleID := DB.QuerySingleInt('SELECT last_insert_rowid()');
    DB.ExecSQL('INSERT INTO Series(SeriesTitle) VALUES(?)', ['OPDS дополнительный цикл']);
    SecondaryCycleID := DB.QuerySingleInt('SELECT last_insert_rowid()');
    DB.ExecSQL('INSERT INTO Authors(LastName,FirstName,MiddleName) VALUES(?,?,?)',
      ['OPDS автор без книг', '', '']);
    EmptyAuthorID := DB.QuerySingleInt('SELECT last_insert_rowid()');
    DB.ExecSQL('INSERT INTO Authors(LastName,FirstName,MiddleName) VALUES(?,?,?)',
      ['OPDS удалённый автор', '', '']);
    DeletedAuthorID := DB.QuerySingleInt('SELECT last_insert_rowid()');
    DB.ExecSQL('INSERT INTO Author_List(AuthorID,BookID) VALUES(?,6)', [DeletedAuthorID]);
    Require(EmptyAuthorID <> DeletedAuthorID, 'Fixture author IDs must differ');
    DB.Start;
    try
      for I := 1 to 100 do
      begin
        BaseName := Format('opds%.3d', [I]);
        Title := Format('OPDS pagination %.3d', [I]);
        if I = 1 then Title := 'Проверка & <тег> "кавычки" 100%_+ 😀'
        else if I = 2 then Title := 'Книга плюс+процент%_'
        else if I = 3 then Title := 'OPDS invalid ' + #1 + #$FFFE + #$FFFF + ' characters';
        FB2 := '<?xml version="1.0" encoding="utf-8"?>' +
          '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' +
          '<description><title-info><book-title>' + OPDSXmlEscape(Title) +
          '</book-title></title-info></description><body><section><p>OPDS test ' +
          IntToStr(I) + '</p></section></body></FictionBook>';
        FileExt := '.fb2';
        case I of
          97: FileExt := '.epub';
          98: FileExt := '.pdf';
          99: FileExt := '.txt';
          100: FileExt := '.bin';
        end;
        FilePath := TPath.Combine(RootFolder, 'books\' + BaseName + FileExt);
        if I < 97 then TFile.WriteAllText(FilePath, FB2, TEncoding.UTF8)
        else Require(TFile.Exists(FilePath), 'Expected the prepared format fixture: ' + FileExt);
        DB.ExecSQL('INSERT INTO Books(BookID,LibID,Title,SeriesID,SeqNumber,UpdateDate,LibRate,' +
          'Lang,Folder,FileName,InsideNo,Ext,BookSize,IsLocal,IsDeleted) ' +
          'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [I + 6, BaseName, Title, CycleID, I, '2026-10-01', 0, 'ru', 'books\',
           BaseName, 0, FileExt, Length(TFile.ReadAllBytes(FilePath)), 1, 0]);
        BookID := DB.QuerySingleInt('SELECT last_insert_rowid()');
        Require(BookID = I + 6, 'Unexpected pagination book ID');
        DB.ExecSQL('INSERT INTO Author_List(AuthorID,BookID) VALUES(?,?)', [AuthorID, BookID]);
        DB.ExecSQL('INSERT INTO Genre_List(GenreCode,BookID) VALUES(?,?)', [GenreCode, BookID]);
        DB.ExecSQL('INSERT OR REPLACE INTO Series_List(BookID,SeriesID,SeqNumber,IsPrimary,OrdNum) ' +
          'VALUES(?,?,?,1,0)', [BookID, CycleID, I]);
        DB.ExecSQL('INSERT INTO Series_List(BookID,SeriesID,SeqNumber,IsPrimary,OrdNum) ' +
          'VALUES(?,?,?,0,1)', [BookID, SecondaryCycleID, I]);
      end;
      DB.Commit;
    except
      DB.Rollback;
      raise;
    end;
    Require(DB.QuerySingleInt('SELECT count(*) FROM Books WHERE IsDeleted=0') = 105,
      'Expected 105 visible physical books');
    // One existing fixture book is served from an ordinary deflated ZIP.
    Zip := TZipFile.Create;
    try
      Zip.Open(TPath.Combine(RootFolder, 'opds-fb2.zip'), zmWrite);
      Zip.Add(TPath.Combine(RootFolder, 'books\book4.fb2'), 'book4.fb2', zcDeflate);
    finally
      Zip.Free;
    end;
    DB.ExecSQL('UPDATE Books SET Folder=?,InsideNo=0 WHERE BookID=4', ['opds-fb2.zip']);
    DB.QuerySingleInt('PRAGMA wal_checkpoint(TRUNCATE)');
  finally
    DB.Free;
  end;
end;

procedure CheckReadOnly(const DBFileName: string);
var
  DB: TSQLiteDatabase;
  Refused: Boolean;
begin
  DB := TSQLiteDatabase.CreateReadOnly(DBFileName);
  try
    Refused := False;
    try
      DB.ExecSQL('UPDATE Books SET UpdateDate=UpdateDate WHERE BookID=1');
    except
      on E: ESQLiteException do Refused := Pos('readonly', LowerCase(E.Message)) > 0;
    end;
    Require(Refused, 'Read-only database accepted an UPDATE');
    Require(DB.QuerySingleInt('SELECT count(*) FROM Books') = 106,
      'Read-only database cannot read fixture rows');
  finally
    DB.Free;
  end;
end;

var
  DBFileName, RootFolder, StopLine: string;
  Port: Integer;
  Collection: TCollectionInfo;
  Server: THomeLibOPDSServer;
  Ready: TJSONObject;
begin
  try
    Require(ParamCount = 7, 'Usage: OPDSServerTest server <db> <root> <port> uselocaldata user mcpfixture');
    DBFileName := TPath.GetFullPath(ParamStr(2));
    RootFolder := TPath.GetFullPath(ParamStr(3));
    Require(TryStrToInt(ParamStr(4), Port), 'Invalid server port');
    GuardFixture(DBFileName, RootFolder, Port);
    CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
    try
      Application.Initialize;
      DMUser := TDMUser.Create(nil);
      try
        DMUser.Settings.LoadSettings;
        Require(SameText(ExcludeTrailingPathDelimiter(DMUser.Settings.TempDir),
          TPath.Combine(ExtractFilePath(ParamStr(0)), '$tmp')), 'Temporary path escaped sandbox');
        TDirectory.CreateDirectory(DMUser.Settings.TempDir);
        AddPaginationBooks(DBFileName, RootFolder);
        CheckReadOnly(DBFileName);
        Collection.Clear;
        Collection.ID := 1;
        Collection.DisplayName := 'OPDS & <каталог> "проверка"';
        Collection.RootFolder := RootFolder;
        Collection.DBFileName := DBFileName;
        Collection.CollectionType := CONTENT_FB or LIBRARY_PRIVATE or LOCATION_LOCAL;
        Server := THomeLibOPDSServer.Create;
        try
          CheckOnlineStartRejected(Server, Collection, Port);
          CheckLANLoopback(Server, Collection, Port);
          Server.Start(Collection, Port, False);
          Ready := TJSONObject.Create;
          try
            Ready.AddPair('url', Server.CatalogURL('127.0.0.1'));
            Ready.AddPair('visible_books', TJSONNumber.Create(105));
            Ready.AddPair('read_only_checked', TJSONBool.Create(True));
            Ready.AddPair('online_start_rejected', TJSONBool.Create(True));
            Ready.AddPair('online_start_reject_checks', TJSONNumber.Create(2));
            Ready.AddPair('lan_loopback_checked', TJSONBool.Create(True));
            Writeln(Ready.ToJSON);
            Flush(Output);
          finally
            Ready.Free;
          end;
          Readln(StopLine);
          Require(StopLine = 'stop', 'Expected stop on standard input');
          Server.Stop;
          Require(not Server.Active, 'OPDS server stayed active after Stop');
          Writeln('{"stopped":true}');
        finally
          Server.Free;
        end;
      finally
        FreeAndNil(DMUser);
      end;
    finally
      CoUninitialize;
    end;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.Message);
      ExitCode := 1;
    end;
  end;
end.
