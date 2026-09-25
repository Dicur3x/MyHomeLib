unit unit_MCP_DownloadSelfTest;

interface

// Called only after the guarded disposable fixture bootstrap.
procedure RunDownloadSelfTestMode(const Port: Integer);

implementation

uses
  System.SysUtils,
  System.JSON,
  unit_Globals,
  unit_Consts,
  unit_Interfaces,
  unit_Downloader,
  unit_MCP_Transport,
  dm_user;

procedure RunDownloadSelfTestMode(const Port: Integer);
var
  Collection: IBookCollection;
  Report: TJSONObject;
  Cases: TJSONArray;
  Transport: TMcpTransport;

  procedure DownloadCase(const Name, Script: string);
  var
    Book: TBookRecord;
    Key: TBookKey;
    Downloader: TDownloader;
    Item: TJSONObject;
    Downloaded: Boolean;
  begin
    Book.Clear;
    Book.Title := Name;
    Book.FileName := Name;
    Book.FileExt := FB2_EXTENSION;
    Book.Folder := 'downloads\';
    Book.LibID := '854807';
    Book.Date := EncodeDate(2026, 9, 25);
    Key := CreateBookKey(Collection.InsertBook(Book, False, False), 1);
    Collection.SetProperty(PROP_CONNECTIONSCRIPT, Script);
    Downloader := TDownloader.Create;
    try
      Downloader.IgnoreErrors := True;
      Downloaded := Downloader.Download(SystemDB, Key);
    finally
      Downloader.Free;
    end;
    Collection.GetBookRecord(Key, Book, False);
    Item := TJSONObject.Create;
    Item.AddPair('name', Name);
    Item.AddPair('downloaded', TJSONBool.Create(Downloaded));
    Item.AddPair('local', TJSONBool.Create(bpIsLocal in Book.BookProps));
    Item.AddPair('path', Book.GetBookFileName);
    Cases.AddElement(Item);
  end;

begin
  Collection := SystemDB.GetCollection(1);
  Collection.SetProperty(PROP_URL, Format('http://127.0.0.1:%d/', [Port]));
  Report := TJSONObject.Create;
  try
    Cases := TJSONArray.Create;
    Report.AddPair('cases', Cases);
    DownloadCase('get', 'GET %URL%b/%LIBID%/get' + sLineBreak + 'CHECK');
    DownloadCase('post', 'ADD token value+with%literal' + sLineBreak +
      'POST %URL%post/%LIBID%/get' + sLineBreak + 'CHECK');
    // The attached collection.info from issue #8, with only its host replaced.
    DownloadCase('redirect', 'POST %URL%b/%LIBID%/get' + sLineBreak +
      'GET %RESURL%' + sLineBreak + 'CHECK');
    DownloadCase('encoded', 'GET %URL%encoded/a%2Fb%20c' +
      '?token=x%2By%26z&literal=%252F&plus=a+b' + sLineBreak + 'CHECK');
    DownloadCase('unicode', 'GET %URL%unicode/' + #$041A#$043D#$0438#$0433#$0430 +
      ' 1.fb2' + sLineBreak + 'CHECK');
    Transport := TMcpTransport.Create;
    try
      Transport.WriteMessage(Report.ToJSON);
    finally
      Transport.Free;
    end;
  finally
    Report.Free;
  end;
end;

end.
