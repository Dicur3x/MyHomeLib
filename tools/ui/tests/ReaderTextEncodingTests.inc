procedure TestReaderTextEncoding;
const
  Identity = 'native reader text encoding';
  TextMarker = 'Текст в кодировке DOS, ёлка и чай.';
  FB2Marker = 'Глава с неверной кодировкой';
var
  Folder, TextFileName, FB2FileName, HTMLFileName, UnicodeFileName, Profile, Section, Body, OriginalTextHash,
    OriginalFB2Hash, OldText: string;
  OldPosition: Integer;
  Reader: TfrmBuiltinReader;
  Document: TReaderDocument;
  Ini: TMemIniFile;
  EncodingMenu: TMenuItem;

  procedure WriteEncoded(const Name, Value: string; CodePage: Integer);
  var Encoding: TEncoding;
  begin
    Encoding:=TEncoding.GetEncoding(CodePage);
    try TFile.WriteAllBytes(Name,Encoding.GetBytes(Value)); finally Encoding.Free; end;
  end;

  procedure WaitLoaded;
  var Deadline: UInt64;
  begin
    Deadline:=GetTickCount64+15000;
    repeat
      CheckSynchronize(5);
      Application.ProcessMessages;
    until Reader.LoadFinished or (GetTickCount64>Deadline);
    Require(Reader.LoadFinished,'Reader encoding operation timed out');
  end;

  procedure Open(const Name, BookID: string);
  var Popup: TPopupMenu;
  begin
    Reader:=TfrmBuiltinReader.Create(nil);
    Reader.OpenBook(Name,'Encoding fixture',BookID,Profile,'',nil);
    WaitLoaded;
    Popup:=Reader.FindComponent('ReaderSelectionMenu') as TPopupMenu;
    EncodingMenu:=Popup.Items.Find('Кодировка текста');
    Require(Assigned(EncodingMenu) and EncodingMenu.Visible,'Reader encoding menu unavailable for '+ExtractFileExt(Name));
  end;

  procedure Choose(Encoding: TReaderTextEncoding);
  var Popup: TPopupMenu;
  begin
    Popup:=Reader.FindComponent('ReaderSelectionMenu') as TPopupMenu;
    Popup.OnPopup(Popup);
    Require(EncodingMenu.Items[Ord(Encoding)].Enabled,'Reader encoding menu item is disabled');
    EncodingMenu.Items[Ord(Encoding)].Click;
    Require(not Reader.LoadFinished,'Reader encoding menu did not start a new load');
    WaitLoaded;
    Popup.OnPopup(Popup);
  end;

  function StoredEncoding: Integer;
  begin
    Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
    try Result:=Ini.ReadInteger(Section,'TextEncoding',-1); finally Ini.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Folder:=ExtractFilePath(ParamStr(0));
  TextFileName:=Folder+'manual-encoding.txt';
  FB2FileName:=Folder+'manual-encoding.fb2';
  HTMLFileName:=Folder+'manual-encoding.html';
  UnicodeFileName:=Folder+'manual-encoding-unicode.txt';
  Profile:=Folder+'manual-encoding.ini';
  Section:='Book.'+Copy(THashSHA2.GetHashString(Identity),1,40);
  Body:='';
  for var I:=1 to 160 do Body:=Body+IntToStr(I)+' '+TextMarker+#13#10;
  WriteEncoded(TextFileName,Body,866);
  OriginalTextHash:=THashSHA2.GetHashStringFromFile(TextFileName);
  Require(not ReaderSupportsTextEncoding('sample.epub') and not ReaderSupportsTextEncoding('sample.pdf'),
    'Reader offers a manual encoding for a container or raster book');
  Reader:=nil;
  try
    Open(TextFileName,Identity);
    Require(Reader.Ready and not Reader.BookText.Contains(TextMarker),'Fixture did not reproduce wrong automatic decoding');
    Reader.GoToPosition(730);
    OldPosition:=Reader.TextPosition;
    Require(OldPosition>0,'Fixture did not move into the book');
    Choose(rteCP866);
    Require(Reader.Ready and Reader.BookText.Contains(TextMarker),'DOS encoding did not fix the book');
    Require((Reader.TextPosition=OldPosition) and EncodingMenu.Items[Ord(rteCP866)].Checked,
      'Changing a same-length encoding lost the reading position or menu selection');
    Require(StoredEncoding=Ord(rteCP866),'Chosen encoding did not persist');
    OldText:=Reader.BookText;
    Choose(rteUTF8);
    Require(Reader.Ready and (Reader.BookText=OldText) and (Reader.TextPosition=OldPosition) and
      (StoredEncoding=Ord(rteCP866)) and EncodingMenu.Items[Ord(rteCP866)].Checked,
      'Invalid UTF-8 replaced the current view or its persisted setting');
    FreeAndNil(Reader);
    Open(TextFileName,'another identity');
    Require(Reader.Ready and not Reader.BookText.Contains(TextMarker),'Encoding leaked into another book');
    FreeAndNil(Reader);
    Open(TextFileName,Identity);
    Require(Reader.Ready and Reader.BookText.Contains(TextMarker) and (Reader.TextPosition=OldPosition),
      'Reopening the same book lost the encoding or position');
    Choose(rteAutomatic);
    Require(Reader.Ready and not Reader.BookText.Contains(TextMarker) and (StoredEncoding=-1) and
      EncodingMenu.Items[Ord(rteAutomatic)].Checked,'Automatic encoding did not reset the saved override');
    FreeAndNil(Reader);

    WriteEncoded(FB2FileName,'<?xml version="1.0" encoding="does-not-exist"?>'+
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section>'+
      '<title><p>'+FB2Marker+'</p></title><p>'+TextMarker+'</p></section></body></FictionBook>',20866);
    OriginalFB2Hash:=THashSHA2.GetHashStringFromFile(FB2FileName);
    Open(FB2FileName,'FB2 recovery');
    Require(not Reader.Ready,'Invalid declaration did not reproduce the initial opening failure');
    Choose(rteKOI8R);
    Require(Reader.Ready and Reader.BookText.Contains(TextMarker) and
      (Reader.ChapterCount=1) and Reader.ChapterTitle(0).Contains(FB2Marker),
      'Manual FB2 encoding failed to recover the text and chapter');
    FreeAndNil(Reader);
    Require((THashSHA2.GetHashStringFromFile(TextFileName)=OriginalTextHash) and
      (THashSHA2.GetHashStringFromFile(FB2FileName)=OriginalFB2Hash),'Reading rewrote a source file');

    Document:=TReaderDocument.Create;
    try
      WriteEncoded(HTMLFileName,'<html><head><meta charset="windows-1251"></head>'+
        '<body><p>'+TextMarker+'<br>Ещё текст</body></html>',866);
      Document.Load(HTMLFileName,nil,rteCP866);
      Require(Document.PlainText.Contains(TextMarker),'Tolerant HTML renderer ignored the chosen encoding');
    finally Document.Free; end;
    Document:=TReaderDocument.Create;
    try
      TFile.WriteAllText(UnicodeFileName,TextMarker,TEncoding.BigEndianUnicode);
      Document.Load(UnicodeFileName,nil,rteUTF16BE);
      Require(Document.PlainText=TextMarker,'Manual UTF-16 BE exposed the BOM or changed the text');
    finally Document.Free; end;
  finally Reader.Free; end;
  Writeln('PASS reader text encoding selection, recovery, position and persistence');
end;
