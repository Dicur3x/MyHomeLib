unit unit_ReaderFormats;

interface

// Content inspection uses a bounded prefix and never changes source files.
function DetectReaderExtension(const FileName: string): string;
function PrepareDetectedReaderFile(const FileName, Source: string): string;
function ReaderAvailability(const Extension: string): string;
function IsBuiltinReaderFormat(const Extension: string): Boolean;

implementation

uses System.SysUtils, System.Classes, System.IOUtils, System.Zip, System.Hash, System.Math,
  System.StrUtils, System.Generics.Collections, System.SyncObjs, Winapi.Windows, unit_BookCache, unit_ReaderOffice;

var FormatCache: TDictionary<string,string>; FormatCacheLock: TCriticalSection;

function InList(const Extension, Values: string): Boolean;
begin Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|',Values)>0; end;

function IsBuiltinReaderFormat(const Extension: string): Boolean;
begin
  Result:=InList(Extension,'|fb2|fb3|epub|pdf|txt|rtf|html|htm|xhtml|shtml|mht|mhtml|docx|odt|md|markdown|faq|wri|jpg|jpeg|png|gif|bmp|webp|tif|tiff|cbz|cbr|cb7|djvu|djv|dju|djm|djvm|');
end;

function ReaderAvailability(const Extension: string): string;
begin
  if IsBuiltinReaderFormat(Extension) then Exit('Можно читать во встроенной читалке');
  if InList(Extension,'|mobi|azw|azw3|prc|') then Exit('Встроенная читалка: после подготовки незашифрованной книги');
  if InList(Extension,'|djvu|djv|dju|djm|djvm|xps|oxps|chm|cbz|cbr|cb7|epub|pdf|') then Exit('Для чтения используйте SumatraPDF');
  if IsOfficeReaderFormat(Extension) then Exit('Встроенная читалка: подготовка PDF через установленный LibreOffice');
  if InList(Extension,'|rgo|') then Exit('RepliGo: нужен просмотрщик этого старого формата');
  if InList(Extension,'|ibk|') then Exit('ICE Book Reader: собственный формат библиотеки');
  if InList(Extension,'|zip|rar|7z|7zip|cab|tar|gz|gzip|bz2|xz|tgz|') then Exit('Архив: книга выбирается после распаковки');
  if InList(Extension,'|mp3|wav|ogg|m4b|') then Exit('Аудиофайл: открыть аудиоплеером');
  if InList(Extension,'|exe|com|msi|bat|cmd|ps1|apk|torrent|') then Exit('Этот файл не является форматом для чтения');
  Result:='Формат будет проверен по содержимому при открытии';
end;

function DetectReaderExtensionCore(const FileName: string): string;
var Stream: TFileStream; Bytes: TBytes; Prefix, Wide: string; Zip: TZipFile; N: Integer;
begin
  Result:=''; Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
  try
    SetLength(Bytes,Min(Stream.Size,131072));
    if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
  finally Stream.Free; end;
  if Length(Bytes)<4 then Exit;
  Prefix:=TEncoding.ANSI.GetString(Bytes,0,Min(Length(Bytes),4096));
  if Pos('%PDF-',Copy(Prefix,1,1024))>0 then Exit('.pdf');
  if Copy(Prefix,1,8)='AT&TFORM' then Exit('.djvu');
  if Copy(Prefix,1,5)='{\rtf' then Exit('.rtf');
  if (Bytes[0]=$31) and (Bytes[1]=$BE) or (Bytes[0]=$32) and (Bytes[1]=$BE) then Exit('.wri');
  if (Bytes[0]=$D0) and (Bytes[1]=$CF) and (Bytes[2]=$11) and (Bytes[3]=$E0) then
  begin
    Wide:=TEncoding.Unicode.GetString(Bytes,0,Length(Bytes) and not 1);
    if Pos('WordDocument',Wide)>0 then Exit('.doc');
    if Pos('PowerPoint Document',Wide)>0 then Exit('.ppt');
    if (Pos('Workbook',Wide)>0) or (Pos('Book',Wide)>0) then Exit('.xls');
    Exit;
  end;
  if (Copy(Prefix,1,2)='PK') then
  begin
    Zip:=TZipFile.Create;
    try
      try
        Zip.Open(FileName,zmRead);
        if Zip.IndexOf('META-INF/container.xml')>=0 then Exit('.epub');
        if Zip.IndexOf('word/document.xml')>=0 then Exit('.docx');
        if Zip.IndexOf('ppt/presentation.xml')>=0 then Exit('.pptx');
        if Zip.IndexOf('xl/workbook.xml')>=0 then Exit('.xlsx');
        if Zip.IndexOf('fb3/body.xml')>=0 then Exit('.fb3');
        if Zip.IndexOf('content.xml')>=0 then
        begin
          N:=Zip.IndexOf('mimetype');
          if (N>=0) and (Zip.FileInfo[N].UncompressedSize<1024) then
          begin
            Zip.Read(N,Bytes); Wide:=TEncoding.ASCII.GetString(Bytes);
            if Wide='application/vnd.oasis.opendocument.text' then Exit('.odt');
            if Wide='application/vnd.oasis.opendocument.presentation' then Exit('.odp');
            if Wide='application/vnd.oasis.opendocument.spreadsheet' then Exit('.ods');
          end;
        end;
        for N:=0 to Zip.FileCount-1 do if EndsText('.fdseq',Zip.FileNames[N]) then Exit('.xps');
      except
        // A malformed ZIP must reach its normal reader error, not be relabelled.
      end;
    finally Zip.Free; end;
    Exit('.zip');
  end;
  if Copy(Prefix,1,4)='MSCF' then Exit('.cab');
  if (Bytes[0]=$37) and (Bytes[1]=$7A) and (Bytes[2]=$BC) and (Bytes[3]=$AF) then Exit('.7z');
  if Copy(Prefix,1,4)='Rar!' then Exit('.rar');
  if (Bytes[0]=$89) and (Copy(Prefix,2,3)='PNG') then Exit('.png');
  if (Bytes[0]=$FF) and (Bytes[1]=$D8) then Exit('.jpg');
  if ((Bytes[0]=$49) and (Bytes[1]=$49) and (Bytes[2]=$2A) and (Bytes[3]=0)) or
    ((Bytes[0]=$4D) and (Bytes[1]=$4D) and (Bytes[2]=0) and (Bytes[3]=$2A)) then Exit('.tif');
  // Palm Database stores the MOBI type/creator at byte 60, independent of the filename.
  if Length(Bytes)>=68 then
    if TEncoding.ASCII.GetString(Bytes,60,8)='BOOKMOBI' then Exit('.mobi');
  if Copy(Prefix,1,3)='GIF' then Exit('.gif');
  if (Copy(Prefix,1,4)='RIFF') and (Copy(Prefix,9,4)='WEBP') then Exit('.webp');
  if (Bytes[0]=$FF) and (Bytes[1]=$FE) then Prefix:=TEncoding.Unicode.GetString(Bytes,2,Min(Length(Bytes)-2,4096) and not 1)
  else if (Bytes[0]=$FE) and (Bytes[1]=$FF) then Prefix:=TEncoding.BigEndianUnicode.GetString(Bytes,2,Min(Length(Bytes)-2,4096) and not 1);
  if ContainsText(Prefix,'<FictionBook') then Exit('.fb2');
  if ContainsText(Prefix,'MIME-Version:') and (ContainsText(Prefix,'multipart/') or ContainsText(Prefix,'text/html')) then Exit('.mht');
  if ContainsText(Prefix,'<html') or ContainsText(Prefix,'<!DOCTYPE html') then Exit('.html');
end;

function DetectReaderExtension(const FileName: string): string;
var Attributes: TWin32FileAttributeData; Key: string;
begin
  Key:='';
  if GetFileAttributesEx(PChar(FileName),GetFileExInfoStandard,@Attributes) then
    Key:=LowerCase(TPath.GetFullPath(FileName))+'|'+IntToStr(Attributes.nFileSizeHigh)+':'+
      IntToStr(Attributes.nFileSizeLow)+'|'+IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+
      IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
  if Key<>'' then
  begin
    FormatCacheLock.Enter;
    try if FormatCache.TryGetValue(Key,Result) then Exit;
    finally FormatCacheLock.Leave; end;
  end;
  Result:=DetectReaderExtensionCore(FileName);
  if Key<>'' then
  begin
    FormatCacheLock.Enter;
    try
      if FormatCache.Count>=512 then FormatCache.Clear;
      FormatCache.AddOrSetValue(Key,Result);
    finally FormatCacheLock.Leave; end;
  end;
end;

function PrepareDetectedReaderFile(const FileName, Source: string): string;
var Extension, Key, Stamp, StampFile, Temporary, TemporaryStamp: string; Writer: TBookCacheWrite;
  Attributes: TWin32FileAttributeData;
begin
  Result:=FileName; Extension:=DetectReaderExtension(FileName);
  if (Extension='') or SameText(Extension,ExtractFileExt(FileName)) then Exit;
  // Comic containers retain their dedicated reader identity.
  if (Extension='.zip') and InList(ExtractFileExt(FileName),'|cbz|fb3|epub|docx|odt|odp|ods|pptx|xlsx|apk|') then Exit;
  if (Extension='.rar') and SameText(ExtractFileExt(FileName),'.cbr') then Exit;
  if (Extension='.7z') and SameText(ExtractFileExt(FileName),'.cb7') then Exit;
  // Exact attributes keep rapid replacements distinct without reopening a cache-hit source.
  if not GetFileAttributesEx(PChar(FileName),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
  Stamp:='format-v2|'+LowerCase(TPath.GetFullPath(FileName))+'|'+
    IntToStr(Attributes.nFileSizeHigh)+':'+IntToStr(Attributes.nFileSizeLow)+'|'+
    IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
  Key:=Copy(THashSHA2.GetHashString(Stamp),1,40);
  Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-detected-'+Key+Extension));
  StampFile:=Result+'.source';
  if FileExists(Result) and FileExists(StampFile) and (TFile.ReadAllText(StampFile,TEncoding.UTF8)=Stamp) then
  begin RegisterBookCacheFile(Result,Source); Exit; end;
  ForceDirectories(ExtractFileDir(Result));
  Writer:=TBookCacheWrite.Create(Source);
  try
    Temporary:=Writer.TemporaryName(Result); TemporaryStamp:=Writer.TemporaryName(StampFile);
    TFile.Copy(FileName,Temporary,True); TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8);
    Writer.Publish(Temporary,Result,TemporaryStamp);
  finally Writer.Free; end;
end;

initialization
  FormatCache:=TDictionary<string,string>.Create;
  FormatCacheLock:=TCriticalSection.Create;
finalization
  FormatCacheLock.Free;
  FormatCache.Free;
end.
