unit unit_BookCompressionBackup;

interface

uses System.SysUtils, System.Classes;

type
  // A persistent backup contains selected original books, not their whole
  // container. Keep the read lease through the first source replacement.
  TCompressionOriginalBackup = class
  private
    FFileName, FSHA256: string;
    FStream: TFileStream;
    procedure Validate(const ReceiptJSON: string; const Cancelled: TFunc<Boolean>);
  public
    destructor Destroy; override;
    class function Publish(const PreparedJSON, ReceiptJSON, PayloadRoot, Destination: string;
      const Cancelled: TFunc<Boolean>): TCompressionOriginalBackup; static;
    class function OpenExisting(const ReferenceJSON, ReceiptJSON: string;
      const Cancelled: TFunc<Boolean>): TCompressionOriginalBackup; static;
    function ReferenceJSON: string;
    property FileName: string read FFileName;
  end;

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, System.Hash, System.Zip,
  System.Generics.Collections, unit_ZipMemberDeletion, unit_CollectionSpace;

procedure CheckStop(const Cancelled: TFunc<Boolean>);
begin if Assigned(Cancelled) and Cancelled() then Abort; end;

function ObjectFromJSON(const Text: string): TJSONObject;
var Value: TJSONValue;
begin
  Value:=TJSONObject.ParseJSONValue(Text);
  if not (Value is TJSONObject) then
  begin Value.Free; raise EReadError.Create('Не удалось прочитать сведения об оригиналах книг.'); end;
  Result:=TJSONObject(Value);
end;

function StreamDigest(Stream: TStream; const Cancelled: TFunc<Boolean>): string;
var Hash: THashSHA2; Buffer: TBytes; Count: Integer;
begin
  Hash:=THashSHA2.Create; SetLength(Buffer,1024*1024);
  repeat
    CheckStop(Cancelled); Count:=Stream.Read(Buffer[0],Length(Buffer));
    if Count>0 then Hash.Update(Buffer,Count);
  until Count=0;
  Result:=Hash.HashAsString;
end;

procedure TCompressionOriginalBackup.Validate(const ReceiptJSON: string;
  const Cancelled: TFunc<Boolean>);
var Receipt, Manifest: TJSONObject; Zip: TZipFile; Raw: TBytes;
    Expected, Names: TDictionary<string,string>; ManifestIndex: Integer;
    Body: TStream; Header: TZipHeader; Info: TByHandleFileInformation;
begin
  if not GetFileInformationByHandle(FStream.Handle,Info) then RaiseLastOSError;
  if (Info.nNumberOfLinks<>1) or
    (Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY)<>0) then
    raise EReadError.Create('Файл с оригиналами заменён ссылкой или папкой.');
  FStream.Position:=0;
  if StreamDigest(FStream,Cancelled)<>FSHA256 then
    raise EReadError.Create('Контрольная сумма сохранённых оригиналов не совпала.');
  Receipt:=ObjectFromJSON(ReceiptJSON); Zip:=TZipFile.Create;
  Expected:=TDictionary<string,string>.Create; Names:=TDictionary<string,string>.Create;
  Manifest:=nil;
  try
    for var Value in Receipt.GetValue<TJSONArray>('payloads') do
    begin
      var Item:=Value as TJSONObject;
      Expected.Add(Item.GetValue<string>('member'),Item.GetValue<string>('input_sha256'));
    end;
    if (Expected.Count=0) or (Expected.Count>100000) then
      raise EReadError.Create('Некорректный список оригиналов книг.');
    FStream.Position:=0; Zip.Open(FStream,zmRead); ManifestIndex:=-1;
    if Zip.FileCount<>Expected.Count+1 then
      raise EReadError.Create('Сохранённый ZIP содержит другой набор оригиналов.');
    for var I:=0 to Zip.FileCount-1 do
    begin
      var Name:=Zip.FileNames[I];
      Names.Add(Name,IntToStr(I));
      if Name='HomeLibre-originals.json' then ManifestIndex:=I;
    end;
    if (ManifestIndex<0) or (Zip.FileInfo[ManifestIndex].UncompressedSize>16*1024*1024) then
      raise EReadError.Create('Нет проверенного описания сохранённых оригиналов.');
    Zip.Read(ManifestIndex,Raw);
    Manifest:=ObjectFromJSON(TEncoding.UTF8.GetString(Raw));
    if (Manifest.GetValue<Integer>('version')<>1) or
      (Manifest.GetValue<string>('kind')<>'HomeLibre selected book originals') or
      (Manifest.GetValue<string>('source')<>Receipt.GetValue<string>('source')) or
      (Manifest.GetValue<string>('source_sha256')<>Receipt.GetValue<string>('source_sha256')) then
      raise EReadError.Create('Оригиналы относятся к другой операции сжатия.');
    if Manifest.GetValue<TJSONArray>('books').Count<>Expected.Count then
      raise EReadError.Create('Список сохранённых книг не совпал с выбранным.');
    for var Value in Manifest.GetValue<TJSONArray>('books') do
    begin
      CheckStop(Cancelled);
      var Item:=Value as TJSONObject;
      var Member:=Item.GetValue<string>('member');
      var Name:=Item.GetValue<string>('file');
      var Bytes:=Item.GetValue<Int64>('bytes');
      var FileMember:=Member;
      if FileMember='' then FileMember:=ExtractFileName(Receipt.GetValue<string>('source'));
      var ExpectedHash:string;
      if not Expected.TryGetValue(Member,ExpectedHash) or
        (Name<>'books/'+FileMember) or (Item.GetValue<string>('sha256')<>ExpectedHash) or
        not Names.ContainsKey(Name) or (Bytes<0) or (Bytes>Int64(512)*1024*1024) then
        raise EReadError.Create('Сохранён не тот оригинал выбранной книги.');
      Zip.Read(StrToInt(Names[Name]),Body,Header);
      try
        if (StreamDigest(Body,Cancelled)<>ExpectedHash) or (Body.Position<>Bytes) then
          raise EReadError.Create('Не прошла проверка содержимого оригинала книги.');
      finally Body.Free; end;
      Expected.Remove(Member);
    end;
    if Expected.Count<>0 then raise EReadError.Create('Сохранены не все выбранные оригиналы.');
  finally
    Manifest.Free; Names.Free; Expected.Free; Zip.Free; Receipt.Free;
  end;
end;

class function TCompressionOriginalBackup.OpenExisting(const ReferenceJSON, ReceiptJSON: string;
  const Cancelled: TFunc<Boolean>): TCompressionOriginalBackup;
var Reference: TJSONObject;
begin
  Result:=TCompressionOriginalBackup.Create;
  try
    Reference:=ObjectFromJSON(ReferenceJSON);
    try
      Result.FFileName:=Reference.GetValue<string>('path');
      Result.FSHA256:=Reference.GetValue<string>('sha256');
      if not TPath.IsPathRooted(Result.FFileName) or (Length(Result.FSHA256)<>64) then
        raise EReadError.Create('Неверный путь сохранённых оригиналов.');
      Result.FStream:=TFileStream.Create(DeletionNativePath(Result.FFileName),fmOpenRead or fmShareDenyWrite);
      if (Result.FStream.Size<=0) or (Result.FStream.Size<>Reference.GetValue<Int64>('bytes')) then
        raise EReadError.Create('Размер сохранённых оригиналов изменился.');
    finally Reference.Free; end;
    Result.Validate(ReceiptJSON,Cancelled);
  except Result.Free; raise; end;
end;

function TCompressionOriginalBackup.ReferenceJSON: string;
var Value: TJSONObject;
begin
  Value:=TJSONObject.Create;
  try
    Value.AddPair('path',FFileName); Value.AddPair('sha256',FSHA256);
    Value.AddPair('bytes',TJSONNumber.Create(FStream.Size));
    Result:=Value.ToJSON;
  finally Value.Free; end;
end;

class function TCompressionOriginalBackup.Publish(const PreparedJSON, ReceiptJSON,
  PayloadRoot, Destination: string; const Cancelled: TFunc<Boolean>): TCompressionOriginalBackup;
var Prepared, Reference: TJSONObject; Source: TCompressionOriginalBackup;
    Temporary, Target, Token: string; Handle: THandle; Output: THandleStream;
    Buffer: TBytes; Count: Integer; Owned: Boolean; FreeBytes: Int64;
begin
  Result:=nil; Source:=nil; Handle:=INVALID_HANDLE_VALUE; Owned:=False;
  Prepared:=ObjectFromJSON(PreparedJSON);
  try
    var Path:=Prepared.GetValue<string>('path');
    if (Path<>TPath.Combine(PayloadRoot,'original-books.zip')) or
      not TPath.IsPathRooted(Destination) or not DirectoryExists(DeletionNativePath(Destination)) then
      raise EArgumentException.Create('Выберите существующую папку для оригиналов книг.');
    Source:=OpenExisting(PreparedJSON,ReceiptJSON,Cancelled);
    FreeBytes:=CollectionDiskFree(Destination);
    if (FreeBytes>=0) and (FreeBytes<Source.FStream.Size+Int64(16)*1024*1024) then
      raise EWriteError.Create('В папке оригиналов не хватает свободного места. Книги не изменены.');
    Token:=GUIDToString(TGUID.NewGuid);
    Target:=TPath.Combine(Destination,'HomeLibre-originals-'+FormatDateTime('yyyymmdd-hhnnss',Now)+'-'+Token+'.zip');
    Temporary:=TPath.Combine(Destination,'.HomeLibre-originals-'+Token+'.tmp');
    Handle:=CreateFile(PChar(DeletionNativePath(Temporary)),GENERIC_WRITE,0,nil,CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT,0);
    if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
    Owned:=True;
    Output:=THandleStream.Create(Handle);
    try
      Source.FStream.Position:=0; SetLength(Buffer,1024*1024);
      repeat
        CheckStop(Cancelled); Count:=Source.FStream.Read(Buffer[0],Length(Buffer));
        if Count>0 then Output.WriteBuffer(Buffer[0],Count);
      until Count=0;
      if not FlushFileBuffers(Handle) then RaiseLastOSError;
    finally Output.Free; CloseHandle(Handle); Handle:=INVALID_HANDLE_VALUE; end;
    // Verify the destination bytes, not merely the source of the copy.
    Reference:=ObjectFromJSON(Source.ReferenceJSON);
    try
      Reference.RemovePair('path').Free; Reference.AddPair('path',Temporary);
      Result:=OpenExisting(Reference.ToJSON,ReceiptJSON,Cancelled);
    finally Reference.Free; end;
    // Release before the rename; immediately reacquire the verified backup.
    Result.Free; Result:=nil; CheckStop(Cancelled);
    if not MoveFileEx(PChar(DeletionNativePath(Temporary)),PChar(DeletionNativePath(Target)),
      MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
    Owned:=False;
    Reference:=ObjectFromJSON(Source.ReferenceJSON);
    try
      Reference.RemovePair('path').Free; Reference.AddPair('path',Target);
      Result:=OpenExisting(Reference.ToJSON,ReceiptJSON,Cancelled);
    finally Reference.Free; end;
  finally
    if Handle<>INVALID_HANDLE_VALUE then CloseHandle(Handle);
    if Owned then Winapi.Windows.DeleteFile(PChar(DeletionNativePath(Temporary)));
    Source.Free; Prepared.Free;
  end;
end;

destructor TCompressionOriginalBackup.Destroy;
begin FStream.Free; inherited; end;

end.
