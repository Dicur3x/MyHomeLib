(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov     nrymanov@gmail.com
  * Created             19.02.2010
  * Description         набор функций для получения информации из файлов в формате fb2
  *
  * $Id: unit_FB2Utils.pas 1064 2011-09-02 11:33:04Z eg_ $
  *
  * History
  * NickR 19.02.2010    создан
  *       07.05.2010    Формат обложки определяется более точно (не на основании расширения).
  *
  ****************************************************************************** *)

unit unit_FB2Utils;

interface

uses
  Classes, System.SysUtils,
  Graphics,
  fictionbook_21;

type
  TFB2ImageVisitor = reference to procedure(const Name: string; Stream: TStream);
  TFB2PublisherSeriesItem = record
    Title: string;
    Number: Integer;
  end;
  TFB2PublisherSeries = TArray<TFB2PublisherSeriesItem>;

function LoadFB2Description(Stream: TStream; IncludeCover: Boolean = True): IXMLFictionBook;
procedure VisitFB2Images(Stream: TStream; const Visitor: TFB2ImageVisitor;
  const Canceled: TFunc<Boolean> = nil);

function GetBookCoverStream(book: IXMLFictionBook): TStream;
function GetBookCover(book: IXMLFictionBook): TGraphic;
function CreateGraphicFromStream(const ImageStream: TStream; const MaxDecodedBytes: Int64 = 256*1024*1024): TGraphic;
function GetBookAnnotation(book: IXMLFictionBook): string;
function GetBookPublisherSeries(book: IXMLFictionBook): string;
function GetBookPublisherSeriesData(book: IXMLFictionBook): TFB2PublisherSeries;
function GetBookInfo(book: IXMLFictionBook): string;
function FormatName(const LastName: string; const FirstName: string; const MiddleName: string; const nickName: string = ''; onlyInitials: Boolean = False): string;

{ TODO -oNickR -cRefactoring : доделать эту функцию. Для этого необходимо вынести определение TBookRecord в доступное место }
// procedure GetBookInfo(book: IXMLFictionBook; var R: TBookRecord);

const
  dlmtr = ': ';

resourcestring
rstrFileInfo = 'Информация о файле';
   rstrFolder = 'Папка';
   rstrFile = 'Файл';
   rstrSize = 'Размер';
   rstrAdded = 'Добавленный';
   rstrGeneralInfo = 'Общая информация';
   rstrSrclInfo = 'Информация об источнике';
   rstrTitle = 'Название';
   rstrAuthors = 'Автор(ы)';
   rstrSingleSeries = 'Серия';
   rstrGenre = 'Жанр';
   rstrKeywords = 'Ключевые слова';
   rstrDate = 'Дата';
   rstrBookLanguage = 'Язык книги';
   rstrSourceLanguage = 'Язык оригинала';
   rstrTranslators = 'Переводчик(и)';
   rstrPublisherInfo = 'Издательская информация';
   rstrPublisher = 'Издательство';
   rstrCity = 'Город';
   rstrYear = 'Год';
   rstrISBN = 'ISBN';
   rstrOCRInfo = 'Информация о документе (OCR)';
   rstrProgram = 'Программа';
   rstrID = 'ID';
   rstrVersion = 'Версия';
   rstrSource = 'Источник';
   rstrSourceAuthor = 'Автор источника';
   rstrHistory = 'История';

implementation

uses
  Windows,
  ActiveX,
  UrlMon,
  unit_MHLHelpers,
  GIFImg,
  jpeg,
  pngimage,
  unit_WebPCompat, unit_ImageBounds, unit_FB2MetadataRecovery, System.RegularExpressions,
  System.NetEncoding, System.Math, Xml.XMLDoc, Xml.XMLIntf;


function LoadFB2Description(Stream: TStream; IncludeCover: Boolean): IXMLFictionBook;
var Recorded: TRecordedMetadataStream; Buffer: array[0..8191] of Byte;
  XML, Details, CoverID: string; Canceled: Boolean; Minimal: TStringStream;
  Book: IXMLFictionBook;
begin
  Result := nil;
  if not Assigned(Stream) then Exit;
  Stream.Position := 0;
  Recorded := TRecordedMetadataStream.Create(Stream,16*1024*1024);
  try
    Recorded.Read(Buffer,SizeOf(Buffer));
    if not RecoverMetadataPrefix(Recorded,16*1024*1024,64,nil,XML,Details,Canceled,True) then
      raise Exception.Create('Не удалось прочитать описание книги.');
  finally Recorded.Free; end;
  Minimal := TStringStream.Create(XML,TEncoding.UTF8);
  try Book := LoadFictionBook(Minimal); finally Minimal.Free; end;
  if IncludeCover and (Book.Description.Titleinfo.Coverpage.Count > 0) then
  begin
    CoverID := Book.Description.Titleinfo.Coverpage[0].xlinkHref;
    if CoverID.StartsWith('#') then
    begin
      Delete(CoverID,1,1);
      VisitFB2Images(Stream,
        procedure(const Name: string; Image: TStream)
        var Bytes: TBytes; Binary: IXMLBinary;
        begin
          if Name <> CoverID then Exit;
          if Book.Binary.Count > 0 then Exit;
          SetLength(Bytes,Image.Size); Image.Position := 0;
          if Length(Bytes)>0 then Image.ReadBuffer(Bytes[0],Length(Bytes));
          Binary := Book.Binary.Add; Binary.Id := Name;
          Binary.Text := TNetEncoding.Base64.EncodeBytesToString(Bytes);
        end);
    end;
  end;
  Result := Book;
end;

procedure VisitFB2Images(Stream: TStream; const Visitor: TFB2ImageVisitor;
  const Canceled: TFunc<Boolean>);
var Bytes, ImageBytes: TBytes; Text, Prefix, Fragment, Name: string;
  Doc: IXMLDocument; Binary: IXMLNode;
  At, TagEnd, NameEnd, CloseAt, CloseEnd, ColonAt, Pictures: Integer; TagName, LocalTag: string;
  Image: TBytesStream; I, Count: Integer; Encoding: TEncoding; OwnEncoding: Boolean; Header: TMatch;
begin
  if not Assigned(Stream) or not Assigned(Visitor) then Exit;
  if Stream.Size > 128*1024*1024 then raise Exception.Create('Книга слишком велика для галереи.');
  Stream.Position := 0; SetLength(Bytes,Stream.Size); I := 0;
  while I < Length(Bytes) do
  begin
    if Assigned(Canceled) and Canceled() then Exit;
    Count := Stream.Read(Bytes[I],Min(65536,Length(Bytes)-I));
    if Count=0 then raise EReadError.Create('Файл книги прочитан не полностью.');
    Inc(I,Count);
  end;
  // Image tags/base64 are ASCII in UTF-8 and all common single-byte FB2
  // encodings. Do not decode or parse the body, where broken Unicode may occur.
  if (Length(Bytes)>=2) and (Bytes[0]=$FF) and (Bytes[1]=$FE) then
    Text := TEncoding.Unicode.GetString(Bytes,2,Length(Bytes)-2)
  else if (Length(Bytes)>=2) and (Bytes[0]=$FE) and (Bytes[1]=$FF) then
    Text := TEncoding.BigEndianUnicode.GetString(Bytes,2,Length(Bytes)-2)
  else
  begin
    Encoding := TEncoding.UTF8; OwnEncoding := False; I := 0;
    if (Length(Bytes)>=3) and (Bytes[0]=$EF) and (Bytes[1]=$BB) and (Bytes[2]=$BF) then I := 3;
    Header := TRegEx.Match(TEncoding.ASCII.GetString(Bytes,0,Min(1024,Length(Bytes))),
      '^<\?xml\s+[^?]*\bencoding\s*=\s*(["''])([^"'']+)\1');
    if Header.Success then
      try Encoding := TEncoding.GetEncoding(Header.Groups[2].Value); OwnEncoding := True; except end;
    try Text := Encoding.GetString(Bytes,I,Length(Bytes)-I);
    finally if OwnEncoding then Encoding.Free; end;
  end;
  Bytes := nil;
  // Walk markup boundaries with fast string searches. A regular expression
  // over every character of a large body made an empty gallery need seconds.
  At := 1; Pictures := 0;
  repeat
    At := Pos('<',Text,At); if At=0 then Break;
    if Copy(Text,At,4)='<!--' then
    begin
      CloseAt := Pos('-->',Text,At+4); if CloseAt=0 then Break;
      At := CloseAt+3; Continue;
    end;
    if Copy(Text,At,9)='<![CDATA[' then
    begin
      CloseAt := Pos(']]>',Text,At+9); if CloseAt=0 then Break;
      At := CloseAt+3; Continue;
    end;
    if Assigned(Canceled) and Canceled() then Exit;
    NameEnd := At+1;
    while (NameEnd<=Length(Text)) and not CharInSet(Text[NameEnd],[' ',#9,#10,#13,'>','/']) do Inc(NameEnd);
    TagName := Copy(Text,At+1,NameEnd-At-1); LocalTag := TagName;
    ColonAt := Pos(':',LocalTag); if ColonAt>0 then Delete(LocalTag,1,ColonAt);
    TagEnd := Pos('>',Text,NameEnd); if TagEnd=0 then Break;
    if (LocalTag<>'binary') or (Text[TagEnd-1]='/') then begin At:=TagEnd+1; Continue; end;
    CloseAt := Pos('</'+TagName,Text,TagEnd+1);
    if (CloseAt=0) or (Pos('<',Text,TagEnd+1)<>CloseAt) then begin At:=TagEnd+1; Continue; end;
    CloseEnd := CloseAt+Length(TagName)+2;
    while (CloseEnd<=Length(Text)) and CharInSet(Text[CloseEnd],[' ',#9,#10,#13]) do Inc(CloseEnd);
    if (CloseEnd>Length(Text)) or (Text[CloseEnd]<>'>') then begin At:=TagEnd+1; Continue; end;
    Inc(Pictures); if Pictures>256 then Break;
    if CloseAt-TagEnd <= 16*1024*1024*4 div 3+1024 then
    begin
      Prefix := '';
      if ColonAt>0 then Prefix := ' xmlns:'+Copy(TagName,1,ColonAt-1)+'="'+TargetNamespace+'"';
      Fragment := '<FictionBook xmlns="'+TargetNamespace+'"'+Prefix+'>'+Copy(Text,At,CloseEnd-At+1)+'</FictionBook>';
      try
        Doc := LoadXMLData(Fragment); Binary := Doc.DocumentElement.ChildNodes[0];
        if Binary.HasAttribute('id') then Name := Binary.AttributeNodes['id'].Text else Name := IntToStr(Pictures);
        ImageBytes := TNetEncoding.Base64.DecodeStringToBytes(Binary.Text);
        Image := TBytesStream.Create(ImageBytes);
        try Visitor(Name,Image); finally Image.Free; end;
      except
        // Isolate malformed blocks; all other original images remain available.
      end;
      Binary := nil; Doc := nil;
    end;
    At := CloseEnd+1;
  until At>Length(Text);
end;

function InternalGetBookCoverStream(book: IXMLFictionBook): TStream;
var
  coverID: string;
  i: Integer;
  outStr: AnsiString;
begin
  Result := nil;

  if book.Description.Titleinfo.Coverpage.Count > 0 then
  begin
    coverID := book.Description.Titleinfo.Coverpage[0].xlinkHref;
    if Pos('#', coverID) = 1 then
    begin
      // это локальная ссылка (начинается с #)
      coverID := Copy(coverID, 2, MaxInt);

      for i := 0 to book.Binary.Count - 1 do
      begin
        if book.Binary[i].Id = coverID then
        begin
          outStr := DecodeBase64(AnsiString(book.Binary[i].Text));

          Result := TMemoryStream.Create;
          try
            Result.Write(PAnsiChar(outStr)^, Length(outStr));
          except
            FreeAndNil(Result);
          end;
          Break;
        end;
      end;
    end;
  end;
end;

function IsSupportedImageFormat(StreamFormat: TStreamFormat): Boolean;
begin
  Result := StreamFormat in [sfBitmap, sfGif, sfJPEGImage, sfMetafile, sfPngImage, fsIcon];
end;

function InternalCreateGraphic(StreamFormat: TStreamFormat): TGraphic;
begin
  Assert(IsSupportedImageFormat(StreamFormat));

  case StreamFormat of
    sfBitmap: Result := Graphics.TBitmap.Create;
    sfGif: Result := TGIFImage.Create;
    sfJPEGImage: Result := TJPEGImage.Create;
    //sfTiff: ;
    sfPngImage: Result := TPngImage.Create;
    sfMetafile: Result := Graphics.TMetafile.Create;
    fsIcon: Result := Graphics.TIcon.Create;
  else
    Assert(False);
    Result := nil;
  end;
end;

function GetBookCoverStream(book: IXMLFictionBook): TStream;
var
  StreamFormat: TStreamFormat;
  Converted: TStream;
begin
  Result := InternalGetBookCoverStream(book);
  if Assigned(Result) then
  begin
    try
      Converted := ConvertWebPStreamToPNG(Result);
      if Assigned(Converted) then
      begin
        Result.Free;
        Result := Converted;
      end;
    except
      FreeAndNil(Result);
      Exit;
    end;
    Result.Seek(0, soFromBeginning);
    StreamFormat := DetectStreamFormat(Result);
    if not IsSupportedImageFormat(StreamFormat) then
      FreeAndNil(Result);
  end;
end;

function CreateGraphicFromStream(const ImageStream: TStream; const MaxDecodedBytes: Int64): TGraphic;
var
  SavedPosition: Int64;
  StreamFormat: TStreamFormat;
  Converted, GraphicStream: TStream;
begin
  Result := nil;
  if not Assigned(ImageStream) then Exit;
  SavedPosition:=ImageStream.Position;
  if not ImageFitsMemory(ImageStream,MaxDecodedBytes) then
  begin
    // A metafile retains its bounded vector command stream, not a pixel grid.
    if ImageStream.Size>16*1024*1024 then Exit;
    try ImageStream.Position:=0; StreamFormat:=DetectStreamFormat(ImageStream);
    finally ImageStream.Position:=SavedPosition; end;
    if StreamFormat<>sfMetafile then Exit;
  end;
  Converted := nil;
  try
    try
      Converted := ConvertWebPStreamToPNG(ImageStream);
    except
      Exit;
    end;
    if Assigned(Converted) then
      GraphicStream := Converted
    else
      GraphicStream := ImageStream;
    GraphicStream.Position := 0;
    StreamFormat := DetectStreamFormat(GraphicStream);
    if not IsSupportedImageFormat(StreamFormat) then
      Exit;

    Result := InternalCreateGraphic(StreamFormat);
    if Assigned(Result) then
    try
      GraphicStream.Position := 0;
      Result.LoadFromStream(GraphicStream);
    except
      FreeAndNil(Result);
    end;
  finally
    Converted.Free;
    ImageStream.Position := SavedPosition;
  end;
end;

function GetBookCover(book: IXMLFictionBook): TGraphic;
var
  coverStream: TStream;
begin
  Result := nil;
  coverStream := InternalGetBookCoverStream(book);
  if Assigned(coverStream) then
  try
    Result := CreateGraphicFromStream(coverStream);
  finally
    coverStream.Free;
  end;
end;

function GetBookAnnotation(book: IXMLFictionBook): string;
var
  i: Integer;
  sl: TStringList;
begin
  Result := '';

  sl := TStringList.Create;
  try
    with book.Description.Titleinfo do
    begin
      for i := 0 to Annotation.p.Count - 1 do
        sl.Add(Annotation.p[i].OnlyText);
    end;

    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function GetBookPublisherSeriesData(book: IXMLFictionBook): TFB2PublisherSeries;
var
  Sequences: IXMLSequenceTypeList;
  I: Integer;

  procedure AppendSequence(const Sequence: IXMLSequenceType);
  var
    Title: string;
    Number, ChildIndex, ItemIndex: Integer;
  begin
    Title := Trim(Sequence.Name);
    if Title <> '' then
    begin
      // Read the optional attribute as text: broken catalogue numbers must
      // not raise a variant conversion error or hide the rest of the panel.
      Number := 0;
      if Sequence.HasAttribute('number') then
        if not TryStrToInt(Sequence.AttributeNodes['number'].Text, Number) or
           (Number < 0) then
          Number := 0;
      ItemIndex := Length(Result);
      SetLength(Result, ItemIndex + 1);
      Result[ItemIndex].Title := Title;
      Result[ItemIndex].Number := Number;
    end;
    for ChildIndex := 0 to Sequence.Count - 1 do
      AppendSequence(Sequence[ChildIndex]);
  end;

begin
  Result := nil;
  if not Assigned(book) then Exit;
  Sequences := book.Description.Publishinfo.Sequence;
  for I := 0 to Sequences.Count - 1 do
    AppendSequence(Sequences[I]);
end;

function GetBookPublisherSeries(book: IXMLFictionBook): string;
var
  Item: TFB2PublisherSeriesItem;
begin
  Result := '';
  for Item in GetBookPublisherSeriesData(book) do
  begin
    if Result <> '' then
      Result := Result + '; ';
    Result := Result + Item.Title;
    if Item.Number > 0 then
      Result := Result + ' (' + IntToStr(Item.Number) + ')';
  end;
end;

function GetBookInfo(book: IXMLFictionBook): string;
var
  i: Integer;
  sl: TStringList;
begin
  Result := '';

  sl := TStringList.Create;
  try

    with book.Description.Titleinfo do
    begin
      sl.Add(rstrYear + dlmtr + Date.Text);

      sl.Add('');
      sl.Add(rstrSingleSeries + dlmtr);
      for i := 0 to Sequence.Count - 1 do
        sl.Add(Sequence[i].Name);

      sl.Add('');
      sl.Add(rstrTranslators + dlmtr);
      for i := 0 to Translator.Count - 1 do
        with Translator[i] do
          sl.Add(LastName.Text + Firstname.Text + Middlename.Text + NickName.Text);
    end;
    sl.Add('');

    with book.Description.Publishinfo do
    begin
      sl.Add(rstrTitle + dlmtr + Bookname.Text);
      sl.Add(rstrPublisher + dlmtr + Publisher.Text);
      sl.Add(rstrCity + dlmtr + City.Text);
      sl.Add(rstrYear + dlmtr + Year);
      sl.Add(rstrISBN + dlmtr + Isbn.Text);
    end;

    with book.Description.Documentinfo do
    begin
      sl.Add('');
      sl.Add(rstrAuthors + dlmtr);
      for i := 0 to Author.Count - 1 do
        with Author[i] do
          sl.Add(LastName.Text + Firstname.Text + Middlename.Text + NickName.Text);

      sl.Add(rstrProgram + dlmtr + Programused.Text);
      sl.Add(rstrDate + dlmtr + Date.Text);
      sl.Add(rstrID + dlmtr + book.Description.Documentinfo.Id);
      sl.Add(rstrVersion + dlmtr + Version);

      sl.Add('');
      sl.Add(rstrSource + dlmtr);
      for i := 0 to Srcurl.Count - 1 do
      begin
        sl.Add('URL :' + Srcurl[i]);
      end;
      sl.Add(rstrSourceAuthor + dlmtr + Srcocr.Text);

      sl.Add('');
      sl.Add(rstrHistory + dlmtr);
      for i := 0 to History.p.Count - 1 do
        sl.Add(History.p[i].OnlyText);
    end;

    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function FormatName;
begin
  Result := LastName;

  if FirstName <> '' then
  begin
    if onlyInitials then
      Result := Result + ' ' + FirstName[1] + '.'
    else
      Result := Result + ' ' + FirstName;
  end;

  if MiddleName <> '' then
  begin
    if onlyInitials then
      Result := Result + ' ' + MiddleName[1] + '.'
    else
      Result := Result + ' ' + MiddleName;
  end;

  if nickName <> '' then
  begin
    if Result = '' then
      Result := nickName
    else
      Result := Result + '(' + nickName + ')';
  end;
end;

end.
