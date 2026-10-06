unit unit_MCP_DownloadSelfTest;

interface

// Called only after the guarded disposable fixture bootstrap.
procedure RunDownloadSelfTestMode(const Port: Integer);

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  Vcl.Forms,
  unit_Globals,
  unit_Consts,
  unit_Interfaces,
  unit_Downloader,
  unit_Messages,
  unit_MCP_Transport,
  dm_user;

type
  TDownloadMessageForm = class(TForm)
  private
    procedure LocalStatusChanged(var Message: TLocalStatusChangedMessage);
      message WM_MHL_CHANGELOCALSTATUS;
  public
    Notifications: Integer;
    LastStatus: TBookLocalStatus;
    constructor Create(AOwner: TComponent); override;
  end;

constructor TDownloadMessageForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
end;

procedure TDownloadMessageForm.LocalStatusChanged(var Message: TLocalStatusChangedMessage);
begin
  try
    LastStatus := Message.Params^;
    Inc(Notifications);
  finally
    Dispose(Message.Params);
  end;
  Message.Result := 0;
end;

procedure CheckMessageLayout;
var
  Native: TMessage;
  Status: TLocalStatusChangedMessage;
begin
  // Fail before dereferencing a malformed pointer in the real window test.
  if (SizeOf(Status) <> SizeOf(Native)) or
    (NativeUInt(@Status.Unused) - NativeUInt(@Status) <>
      NativeUInt(@Native.WParam) - NativeUInt(@Native)) or
    (NativeUInt(@Status.Params) - NativeUInt(@Status) <>
      NativeUInt(@Native.LParam) - NativeUInt(@Native)) or
    (NativeUInt(@Status.Result) - NativeUInt(@Status) <>
      NativeUInt(@Native.Result) - NativeUInt(@Native)) or
    (SizeOf(Status.Result) <> SizeOf(Native.Result)) then
    raise Exception.Create('Local-status message layout does not match TMessage');
end;

procedure RunDownloadSelfTestMode(const Port: Integer);
var
  Collection: IBookCollection;
  OnlineCollection: IBookCollection;
  OnlineCollectionID, BeforeClear: Integer;
  Report: TJSONObject;
  Cases: TJSONArray;
  Transport: TMcpTransport;
  Receiver: TDownloadMessageForm;

  procedure SaveReturnedStream(const Stream: TStream; const FileName: string);
  var
    Destination: TFileStream;
  begin
    if not Assigned(Stream) then
      raise Exception.Create('Downloaded archive returned no book stream');
    try
      Stream.Position := 0;
      Destination := TFileStream.Create(FileName, fmCreate);
      try
        Destination.CopyFrom(Stream, 0);
      finally
        Destination.Free;
      end;
    finally
      Stream.Free;
    end;
  end;

  procedure DownloadCase(const Name, Script: string; const Archive: Boolean);
  var
    TargetCollection: IBookCollection;
    Book: TBookRecord;
    Key: TBookKey;
    Downloader: TDownloader;
    Item: TJSONObject;
    Downloaded: Boolean;
    Before: Integer;
    StreamFile, DescriptorFile: string;
  begin
    if Archive then TargetCollection := OnlineCollection
    else TargetCollection := Collection;
    Book.Clear;
    Book.Title := Name;
    Book.FileName := Name;
    Book.FileExt := FB2_EXTENSION;
    Book.Folder := 'downloads\';
    if Archive then
      Book.Folder := TPath.Combine(Book.Folder, Name + FB2ZIP_EXTENSION);
    Book.LibID := '854807';
    Book.Date := EncodeDate(2026, 9, 25);
    Key := CreateBookKey(TargetCollection.InsertBook(Book, False, False),
      TargetCollection.CollectionID);
    TargetCollection.SetProperty(PROP_CONNECTIONSCRIPT, Script);
    Downloader := TDownloader.Create;
    try
      Downloader.IgnoreErrors := True;
      Before := Receiver.Notifications;
      Downloaded := Downloader.Download(SystemDB, Key);
      Application.ProcessMessages;
    finally
      Downloader.Free;
    end;
    TargetCollection.GetBookRecord(Key, Book, False);
    Item := TJSONObject.Create;
    Cases.AddElement(Item);
    Item.AddPair('name', Name);
    Item.AddPair('downloaded', TJSONBool.Create(Downloaded));
    Item.AddPair('local', TJSONBool.Create(bpIsLocal in Book.BookProps));
    Item.AddPair('notified', TJSONBool.Create(
      (Receiver.Notifications = Before + 1) and
      (Receiver.LastStatus.BookKey.BookID = Key.BookID) and
      (Receiver.LastStatus.BookKey.DatabaseID = Key.DatabaseID) and
      Receiver.LastStatus.LocalStatus));
    Item.AddPair('path', Book.GetBookFileName);
    Item.AddPair('archive', TJSONBool.Create(Archive));
    if Archive and Downloaded then
    begin
      if Book.GetBookFormat <> bfFb2Archive then
        raise Exception.Create('Online ZIP fixture did not exercise bfFb2Archive');
      // The server member deliberately differs from the catalog file name.
      // INSNO=0 must keep working for ordinary Deflate downloads.
      StreamFile := TPath.Combine(Book.CollectionRoot, Name + '-extracted.fb2');
      DescriptorFile := TPath.Combine(Book.CollectionRoot, Name + '-descriptor.fb2');
      SaveReturnedStream(Book.GetBookStream, StreamFile);
      SaveReturnedStream(Book.GetBookDescriptorStream(False), DescriptorFile);
      Item.AddPair('stream_path', StreamFile);
      Item.AddPair('descriptor_path', DescriptorFile);
    end;
  end;

begin
  CheckMessageLayout;
  Application.CreateForm(TDownloadMessageForm, Receiver);
  try
    // Allocate a real, hidden VCL main window for the production PostMessage path.
    Receiver.HandleNeeded;
    Collection := SystemDB.GetCollection(1);
    Collection.SetProperty(PROP_URL, Format('http://127.0.0.1:%d/', [Port]));
    OnlineCollectionID := SystemDB.CreateCollection('Disposable online ZIP download',
      Collection.CollectionRoot, 'download-online.hlc2', CT_EXTERNAL_ONLINE_FB,
      Settings.AppPath + 'genres_fb2.glst');
    OnlineCollection := SystemDB.GetCollection(OnlineCollectionID);
    OnlineCollection.SetProperty(PROP_URL, Format('http://127.0.0.1:%d/', [Port]));
    Report := TJSONObject.Create;
    try
      Cases := TJSONArray.Create;
      Report.AddPair('cases', Cases);
      Report.AddPair('webp_default_enabled', TJSONBool.Create(Settings.ConvertWebPToPNG));
      DownloadCase('get', 'GET %URL%b/%LIBID%/get' + sLineBreak + 'CHECK', False);
      DownloadCase('post', 'ADD token value+with%literal' + sLineBreak +
        'POST %URL%post/%LIBID%/get' + sLineBreak + 'CHECK', False);
      // The attached collection.info from issue #8, with only its host replaced.
      DownloadCase('redirect', 'POST %URL%b/%LIBID%/get' + sLineBreak +
        'GET %RESURL%' + sLineBreak + 'CHECK', False);
      DownloadCase('encoded', 'GET %URL%encoded/a%2Fb%20c' +
        '?token=x%2By%26z&literal=%252F&plus=a+b' + sLineBreak + 'CHECK', False);
      DownloadCase('unicode', 'GET %URL%unicode/' + #$041A#$043D#$0438#$0433#$0430 +
        ' 1.fb2' + sLineBreak + 'CHECK', False);
      DownloadCase('archive-get', 'GET %URL%zip/b/%LIBID%/get' + sLineBreak + 'CHECK', True);
      DownloadCase('archive-redirect', 'POST %URL%zip-redirect/b/%LIBID%/get' + sLineBreak +
        'GET %RESURL%' + sLineBreak + 'CHECK', True);
      BeforeClear := Receiver.Notifications;
      BookLocalStatusChanged(CreateBookKey(123, 456), False);
      Application.ProcessMessages;
      Report.AddPair('clear_status_notified', TJSONBool.Create(
        (Receiver.Notifications = BeforeClear + 1) and
        (Receiver.LastStatus.BookKey.BookID = 123) and
        (Receiver.LastStatus.BookKey.DatabaseID = 456) and
        not Receiver.LastStatus.LocalStatus));
      Transport := TMcpTransport.Create;
      try
        Transport.WriteMessage(Report.ToJSON);
      finally
        Transport.Free;
      end;
    finally
      Report.Free;
    end;
  finally
    Receiver.Free;
  end;
end;

end.
