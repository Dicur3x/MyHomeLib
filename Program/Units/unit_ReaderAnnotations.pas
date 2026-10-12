unit unit_ReaderAnnotations;

interface

uses System.SysUtils;

type
  TReaderAnnotation = record
    ID, BookID, BookTitle, Title, Text, Quote, Place, Created: string;
    Position: Integer;
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

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.JSON, System.DateUtils,
  System.Generics.Collections, System.NetEncoding, System.Hash, System.Zip;

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
      Note.ID:=Row.GetValue<string>('id',''); Note.BookID:=Row.GetValue<string>('book','');
      Note.BookTitle:=Row.GetValue<string>('bookTitle',''); Note.Title:=Row.GetValue<string>('title','');
      Note.Text:=Row.GetValue<string>('text',''); Note.Quote:=Row.GetValue<string>('quote','');
      Note.Place:=Row.GetValue<string>('place',''); Note.Created:=Row.GetValue<string>('created','');
      Note.Position:=Row.GetValue<Integer>('position',-1);
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

function ReaderAnnotationsText(const Items: TArray<TReaderAnnotation>; HTML: Boolean; Style: Integer): string;
var Builder: TStringBuilder; Font, Background, Heading: string;
  function Escape(const Value: string): string;
  begin Result:=TNetEncoding.HTML.Encode(Value).Replace(#13#10,#10).Replace(#13,#10).Replace(#10,'<br>'); end;
begin
  Builder:=TStringBuilder.Create;
  try
    Font:='Georgia,serif'; Background:='#fffaf0'; Heading:='#594a70';
    case Style of
      0: begin Font:='Arial,sans-serif'; Background:='#fff'; Heading:='#252525'; end;
      2: begin Font:='Calibri,Arial,sans-serif'; Background:='#fff'; Heading:='#285e82'; end;
      3: begin Background:='#f5ecd9'; Heading:='#725739'; end;
    end;
    if HTML then Builder.Append('<!doctype html><html lang="ru"><meta charset="utf-8"><title>Закладки и заметки</title>'+ 
      '<style>body{font:18px/1.6 '+Font+';max-width:850px;margin:32px auto;padding:0 20px;color:#252525;background:'+Background+'}'+
      'article{border-top:1px solid #bbb;padding:20px 0}h2,h3{margin:.3em 0;color:'+Heading+'}small{color:#555}blockquote{border-left:3px solid #8299b0;padding-left:16px;margin-left:0}</style><h1>Закладки и заметки</h1>');
    for var Note in Items do
      if HTML then
      begin
        Builder.Append('<article><h2>'+Escape(Note.BookTitle)+'</h2><h3>'+Escape(Note.Title)+'</h3><small>'+Escape(Note.Place)+' · '+Escape(Note.Created)+'</small>');
        if Note.Quote<>'' then Builder.Append('<blockquote>'+Escape(Note.Quote)+'</blockquote>');
        if Note.Text<>'' then Builder.Append('<p>'+Escape(Note.Text)+'</p>');
        Builder.Append('</article>');
      end
      else
      begin
        Builder.AppendLine(Note.BookTitle).AppendLine(Note.Title).AppendLine(Note.Place+' · '+Note.Created);
        if Note.Quote<>'' then Builder.AppendLine('Цитата: '+Note.Quote);
        if Note.Text<>'' then Builder.AppendLine('Заметка: '+Note.Text);
        Builder.AppendLine;
      end;
    if HTML then Builder.Append('</html>'); Result:=Builder.ToString;
  finally Builder.Free; end;
end;

function ReaderAnnotationsDocx(const Items: TArray<TReaderAnnotation>; Style: Integer): TBytes;
var Zip: TZipFile; Stream: TMemoryStream; XML: TStringBuilder; Font, Background, Heading: string;
  function Escape(const Value: string): string;
  begin
    Result:='';
    for var C in Value do if (Ord(C)>=32) or CharInSet(C,[#9,#10,#13]) then Result:=Result+C;
    Result:=Result.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;');
  end;
  procedure AddPart(const Name, Text: string);
  begin Zip.Add(TEncoding.UTF8.GetBytes(Text),Name); end;
  procedure Paragraph(const Text, Name: string);
  begin
    for var Line in Text.Replace(#13#10,#10).Replace(#13,#10).Split([#10]) do
      XML.Append('<w:p><w:pPr><w:pStyle w:val="'+Name+'"/></w:pPr><w:r><w:t xml:space="preserve">'+Escape(Line)+'</w:t></w:r></w:p>');
  end;
begin
  Font:='Georgia'; Background:='FFFAF0'; Heading:='594A70';
  case Style of
    0: begin Font:='Arial'; Background:='FFFFFF'; Heading:='252525'; end;
    2: begin Font:='Calibri'; Background:='FFFFFF'; Heading:='285E82'; end;
    3: begin Background:='F5ECD9'; Heading:='725739'; end;
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
      '<w:pPr><w:spacing w:after="140" w:line="290" w:lineRule="auto"/></w:pPr>'+
      '<w:rPr><w:rFonts w:ascii="'+Font+'" w:hAnsi="'+Font+'" w:cs="'+Font+'"/><w:sz w:val="24"/><w:color w:val="252525"/></w:rPr></w:style>'+
      '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>'+
      '<w:pPr><w:keepNext/><w:spacing w:before="300" w:after="140"/><w:outlineLvl w:val="0"/></w:pPr>'+
      '<w:rPr><w:b/><w:sz w:val="36"/><w:color w:val="'+Heading+'"/></w:rPr></w:style>'+
      '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>'+
      '<w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="'+Heading+'"/></w:rPr></w:style>'+
      '<w:style w:type="paragraph" w:styleId="Context"><w:name w:val="Context"/><w:basedOn w:val="Normal"/>'+
      '<w:rPr><w:sz w:val="20"/><w:color w:val="555555"/></w:rPr></w:style>'+
      '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>'+
      '<w:pPr><w:ind w:left="360"/><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="8299B0"/></w:pBdr></w:pPr><w:rPr><w:i/></w:rPr></w:style></w:styles>');
    XML.Append('<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'+
      '<w:background w:color="'+Background+'"/><w:body>');
    Paragraph('Закладки и заметки','Heading1');
    for var Note in Items do
    begin
      Paragraph(Note.BookTitle,'Heading1'); Paragraph(Note.Title,'Heading2'); Paragraph(Note.Place+' · '+Note.Created,'Context');
      if Note.Quote<>'' then Paragraph(Note.Quote,'Quote');
      if Note.Text<>'' then Paragraph(Note.Text,'Normal');
    end;
    XML.Append('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr></w:body></w:document>');
    AddPart('word/document.xml',XML.ToString); Zip.Close;
    SetLength(Result,Stream.Size); Stream.Position:=0; if Length(Result)>0 then Stream.ReadBuffer(Result[0],Length(Result));
  finally Zip.Free; Stream.Free; XML.Free; end;
end;

end.
