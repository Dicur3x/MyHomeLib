unit unit_ReaderFormats;

interface

// Content inspection uses a bounded prefix and never changes source files.
function DetectReaderExtension(const FileName: string): string;
function PrepareDetectedReaderFile(const FileName, Source: string): string;
function ReaderAvailability(const Extension: string): string;
function IsBuiltinReaderFormat(const Extension: string): Boolean;
function IsLegacyReaderFormat(const Extension: string): Boolean;

implementation

uses System.SysUtils, System.Classes, System.IOUtils, System.Zip, System.Hash, System.Math,
  System.StrUtils, System.RegularExpressions, System.Generics.Collections, System.SyncObjs, Winapi.Windows, unit_BookCache, unit_ReaderOffice;

var FormatCache: TDictionary<string,string>; FormatCacheLock: TCriticalSection;

function InList(const Extension, Values: string): Boolean;
begin Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|',Values)>0; end;

function IsLegacyReaderFormat(const Extension: string): Boolean;
begin
  Result:=InList(Extension,'|chm|lit|lrf|pdb|tcr|rb|abw|sxw|xps|ha|');
end;

function IsBuiltinReaderFormat(const Extension: string): Boolean;
begin
  Result:=IsLegacyReaderFormat(Extension) or InList(Extension,'|fb2|fb3|epub|pdf|txt|rtf|html|htm|xhtml|shtml|mht|mhtml|docx|odt|md|markdown|faq|wri|jpg|jpeg|png|gif|bmp|webp|tif|tiff|cbz|cbr|cb7|djvu|djv|dju|djm|djvm|');
end;

function ReaderAvailability(const Extension: string): string;
begin
  if IsBuiltinReaderFormat(Extension) then Exit('Можно читать во встроенной читалке');
  if InList(Extension,'|mobi|azw|azw3|prc|') then Exit('Встроенная читалка: после подготовки книги');
  if InList(Extension,'|djvu|djv|dju|djm|djvm|xps|oxps|chm|cbz|cbr|cb7|epub|pdf|') then Exit('Для чтения используйте SumatraPDF');
  if InList(Extension,'|doc|dot|') then Exit('Можно читать во встроенной читалке');
  if IsOfficeReaderFormat(Extension) then Exit('Можно читать во встроенной читалке (адаптация документа)');
  if InList(Extension,'|rgo|') then Exit('RepliGo: нужен просмотрщик этого старого формата');
  if InList(Extension,'|ibk|') then Exit('ICE Book Reader: собственный формат библиотеки');
  if InList(Extension,'|sqlite|db|') then Exit('База данных каталога: тексты книг хранятся отдельно');
  if InList(Extension,'|jutoh|') then Exit('Проект редактора Jutoh: используйте экспорт книги из Jutoh');
  if InList(Extension,'|cr3|') then Exit('Кэш CoolReader: для открытия нужен исходный файл книги');
  if InList(Extension,'|jap|') then Exit('Набор рамок JAP: нужны связанные изображения или исходная книга');
  if InList(Extension,'|sm|') then Exit('Исходник интерактивной истории AXMA: требуется её проигрыватель');
  if InList(Extension,'|b1|') then Exit('Архив B1: сначала извлеките файл книги');
  if InList(Extension,'|zip|rar|7z|7zip|cab|tar|gz|gzip|bz2|xz|tgz|') then Exit('Архив: книга выбирается после распаковки');
  if InList(Extension,'|mp3|wav|ogg|m4b|') then Exit('Аудиофайл: открыть аудиоплеером');
  if InList(Extension,'|exe|com|msi|bat|cmd|ps1|apk|torrent|') then Exit('Этот файл не является форматом для чтения');
  Result:='Формат будет проверен по содержимому при открытии';
end;

function DetectCompoundOffice(const FileName: string; const Header: TBytes): string;
var Input: TFileStream; SectorBytes, Entries, Count, DirectorySector, DIFSector,
  Next, NameBytes, FATIndex, FATEntry: Cardinal; Data, FATData: TBytes;
  FAT, Visited: TList<Cardinal>; Name: string;
  function U32(const Bytes: TBytes; Offset: Integer): Cardinal;
  begin
    Result:=Cardinal(Bytes[Offset]) or Cardinal(Bytes[Offset+1]) shl 8 or
      Cardinal(Bytes[Offset+2]) shl 16 or Cardinal(Bytes[Offset+3]) shl 24;
  end;
  function Sector(Index: Cardinal): TBytes;
  var Offset: UInt64;
  begin
    Result:=nil;Offset:=(UInt64(Index)+1)*SectorBytes;
    if (Index>=$FFFFFFFA) or (Offset+SectorBytes>UInt64(Input.Size)) then Exit;
    Input.Position:=Offset;SetLength(Result,SectorBytes);Input.ReadBuffer(Result[0],SectorBytes);
  end;
begin
  Result:='';if Length(Header)<512 then Exit;
  if (Header[28]<>$FE) or (Header[29]<>$FF) or (Header[31]<>0) or not (Header[30] in [9,12]) then Exit;
  SectorBytes:=Cardinal(1) shl Header[30];Entries:=SectorBytes div 4;
  Count:=U32(Header,44);if (Count=0) or (Count>4096) or (U32(Header,72)>32) then Exit;
  FAT:=TList<Cardinal>.Create;Visited:=TList<Cardinal>.Create;
  Input:=nil;
  try
    Input:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
    for var I:=0 to 108 do
    begin Next:=U32(Header,76+I*4);if (Next<$FFFFFFFA) and (Cardinal(FAT.Count)<Count) then FAT.Add(Next);end;
    DIFSector:=U32(Header,68);
    while Cardinal(FAT.Count)<Count do
    begin
      if (Visited.Count>=32) or Visited.Contains(DIFSector) then Exit;
      Visited.Add(DIFSector);Data:=Sector(DIFSector);if Length(Data)=0 then Exit;
      for var I:=0 to Integer(Entries)-2 do
      begin Next:=U32(Data,I*4);if (Next<$FFFFFFFA) and (Cardinal(FAT.Count)<Count) then FAT.Add(Next);end;
      DIFSector:=U32(Data,SectorBytes-4);
    end;
    Visited.Clear;DirectorySector:=U32(Header,48);
    // Directory streams can be far beyond the bounded file prefix. Follow
    // only their FAT chain; ordinary document content is never scanned.
    while (DirectorySector<$FFFFFFFA) and (Visited.Count<256) do
    begin
      if Visited.Contains(DirectorySector) then Exit;Visited.Add(DirectorySector);
      Data:=Sector(DirectorySector);if Length(Data)=0 then Exit;
      for var I:=0 to Integer(SectorBytes div 128)-1 do
      begin
        NameBytes:=Data[I*128+64]+Cardinal(Data[I*128+65])*256;
        if (Data[I*128+66]=2) and (NameBytes>=2) and (NameBytes<=64) and (NameBytes mod 2=0) then
        begin
          Name:=TEncoding.Unicode.GetString(Data,I*128,NameBytes-2);
          if SameText(Name,'WordDocument') then Exit('.doc');
          if SameText(Name,'PowerPoint Document') then Exit('.ppt');
          if SameText(Name,'Workbook') or SameText(Name,'Book') then Exit('.xls');
        end;
      end;
      FATIndex:=DirectorySector div Entries;FATEntry:=DirectorySector mod Entries;
      if FATIndex>=Cardinal(FAT.Count) then Exit;
      FATData:=Sector(FAT[Integer(FATIndex)]);if Length(FATData)=0 then Exit;
      DirectorySector:=U32(FATData,FATEntry*4);
    end;
  finally Input.Free;Visited.Free;FAT.Free;end;
end;

function DetectReaderExtensionCore(const FileName: string): string;
var Stream: TFileStream; Bytes: TBytes; Prefix, Wide: string; Zip: TZipFile; N: Integer;
  function TextFormat: string;
  var B: Byte; C: Char; Text, Extension: string; Visible: Boolean;
  begin
    Result:=''; Visible:=False;
    if Length(Bytes)=0 then Exit;
    if (Length(Bytes)>=2) and (((Bytes[0]=$FF) and (Bytes[1]=$FE)) or ((Bytes[0]=$FE) and (Bytes[1]=$FF))) then
    begin
      if Bytes[0]=$FF then Text:=TEncoding.Unicode.GetString(Bytes,2,(Length(Bytes)-2) and not 1)
      else Text:=TEncoding.BigEndianUnicode.GetString(Bytes,2,(Length(Bytes)-2) and not 1);
      for C in Text do
      begin
        if ((Ord(C)<32) and not CharInSet(C,[#9,#10,#12,#13])) or (Ord(C)=127) then Exit;
        if Ord(C)>32 then Visible:=True;
      end;
    end
    else
      for B in Bytes do
      begin
        if ((B<32) and not (B in [9,10,12,13])) or (B=127) then Exit;
        if B>32 then Visible:=True;
      end;
    if not Visible then Exit;
    Extension:=LowerCase(ExtractFileExt(FileName));
    if InList(Extension,'|txt|text|faq|md|markdown|') then Result:=Extension
    else Result:='.txt';
  end;
begin
  Result:=''; Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
  try
    SetLength(Bytes,Min(Stream.Size,131072));
    if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
  finally Stream.Free; end;
  if Length(Bytes)<4 then
  begin
    if (Length(Bytes)>=2) and (Bytes[0]=$FF) and (Bytes[1]=$D8) then Exit('.jpg');
    Result:=TextFormat; Exit;
  end;
  Prefix:=TEncoding.ANSI.GetString(Bytes,0,Min(Length(Bytes),4096));
  if Copy(Prefix,1,8)='AT&TFORM' then Exit('.djvu');
  if Copy(Prefix,1,16)='SQLite format 3'+#0 then
  begin
    if SameText(ExtractFileExt(FileName),'.jutoh') then Exit('.jutoh');
    Exit('.sqlite');
  end;
  if Copy(Prefix,1,16)='ICEContainer 1.0' then Exit('.ibk');
  if Prefix.StartsWith('CoolReader 3 Cache File ') then Exit('.cr3');
  if Prefix.StartsWith(#13+'JAP-Frame-Set1') then Exit('.jap');
  if Prefix.StartsWith('ASMJS[::]') then Exit('.sm');
  if Copy(Prefix,1,5)='b1:as' then Exit('.b1');
  if (Length(Bytes)>=21) and (Copy(Prefix,1,2)='HA') and (Bytes[2]+Cardinal(Bytes[3])*256>0) and (Bytes[2]+Cardinal(Bytes[3])*256<=20000) and (Bytes[4] shr 4<=2) and ((Bytes[4] and 15) in [0,1,2,14,15]) then Exit('.ha');
  if Copy(Prefix,1,4)='ITSF' then Exit('.chm');
  if Copy(Prefix,1,8)='ITOLITLS' then Exit('.lit');
  if (Bytes[0]=$B0) and (Bytes[1]=$0C) and (Bytes[2]=$B0) and (Bytes[3]=$0C) then Exit('.rb');
  if Copy(Prefix,1,9)='!!8-Bit!!' then Exit('.tcr');
  if (Length(Bytes)>=8) and (Bytes[0]=Ord('L')) and (Bytes[1]=0) and
    (Bytes[2]=Ord('R')) and (Bytes[3]=0) and (Bytes[4]=Ord('F')) and (Bytes[5]=0) then Exit('.lrf');
  if Copy(Prefix,1,5)='{\rtf' then Exit('.rtf');
  if (Bytes[0]=$31) and (Bytes[1]=$BE) or (Bytes[0]=$32) and (Bytes[1]=$BE) then Exit('.wri');
  if (Bytes[0]=$D0) and (Bytes[1]=$CF) and (Bytes[2]=$11) and (Bytes[3]=$E0) then
  begin
    Exit(DetectCompoundOffice(FileName,Bytes));
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
            if Wide='application/vnd.sun.xml.writer' then Exit('.sxw');
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
  if (Bytes[0]=$1F) and (Bytes[1]=$8B) then Exit('.gz');
  if Copy(Prefix,1,3)='BZh' then Exit('.bz2');
  if (Length(Bytes)>=6) and (Bytes[0]=$FD) and (Copy(Prefix,2,5)='7zXZ'+#0) then Exit('.xz');
  if (Length(Bytes)>=262) and (TEncoding.ASCII.GetString(Bytes,257,5)='ustar') then Exit('.tar');
  if (Length(Bytes)>=14) and (Copy(Prefix,1,2)='BM') then Exit('.bmp');
  if Copy(Prefix,1,3)='ID3' then Exit('.mp3');
  if Copy(Prefix,1,4)='OggS' then Exit('.ogg');
  if (Copy(Prefix,1,4)='RIFF') and (Copy(Prefix,9,4)='WAVE') then Exit('.wav');
  if (Bytes[0]=$37) and (Bytes[1]=$7A) and (Bytes[2]=$BC) and (Bytes[3]=$AF) then Exit('.7z');
  if Copy(Prefix,1,4)='Rar!' then Exit('.rar');
  if (Bytes[0]=$89) and (Copy(Prefix,2,3)='PNG') then Exit('.png');
  if (Bytes[0]=$FF) and (Bytes[1]=$D8) then Exit('.jpg');
  if ((Bytes[0]=$49) and (Bytes[1]=$49) and (Bytes[2]=$2A) and (Bytes[3]=0)) or
    ((Bytes[0]=$4D) and (Bytes[1]=$4D) and (Bytes[2]=0) and (Bytes[3]=$2A)) then Exit('.tif');
  // Palm Database stores the MOBI type/creator at byte 60, independent of the filename.
  if Length(Bytes)>=68 then
  begin
    Wide:=TEncoding.ASCII.GetString(Bytes,60,8);
    if Wide='BOOKMOBI' then Exit('.mobi');
    if Wide='.rgoCERI' then Exit('.rgo');
    if (Wide='TEXtREAd') or (Wide='zTXTGPlm') or (Wide='SDocSilX') or (Wide='PNRdPPrs') then Exit('.pdb');
  end;
  if Copy(Prefix,1,3)='GIF' then Exit('.gif');
  if (Copy(Prefix,1,4)='RIFF') and (Copy(Prefix,9,4)='WEBP') then Exit('.webp');
  if Copy(Prefix,1,2)='MZ' then Exit('.exe');
  // Strong container signatures win over a PDF header embedded in a stored
  // ZIP member or another format. Allow leading PDF transport bytes last.
  if Pos('%PDF-',Copy(Prefix,1,1024))>0 then Exit('.pdf');
  if (Bytes[0]=$FF) and (Bytes[1]=$FE) then Prefix:=TEncoding.Unicode.GetString(Bytes,2,Min(Length(Bytes)-2,4096) and not 1)
  else if (Bytes[0]=$FE) and (Bytes[1]=$FF) then Prefix:=TEncoding.BigEndianUnicode.GetString(Bytes,2,Min(Length(Bytes)-2,4096) and not 1);
  if TRegEx.IsMatch(Prefix,'<([A-Za-z_][\w.-]*:)?FictionBook(\s|>)',[roIgnoreCase]) then Exit('.fb2');
  if TRegEx.IsMatch(Prefix,'<([A-Za-z_][\w.-]*:)?abiword(\s|>)',[roIgnoreCase]) then Exit('.abw');
  if ContainsText(Prefix,'MIME-Version:') and (ContainsText(Prefix,'multipart/') or ContainsText(Prefix,'text/html')) then Exit('.mht');
  if ContainsText(Prefix,'<html') or ContainsText(Prefix,'<!DOCTYPE html') or
    TRegEx.IsMatch(Prefix,'<(body|p|div|section|h[1-6])(\s|>)',[roIgnoreCase]) then Exit('.html');
  if Prefix.TrimLeft.StartsWith('<') then
  begin
    if InList(ExtractFileExt(FileName),'|html|htm|xhtml|shtml|') then Exit('.html');
    Exit('.xml');
  end;
  Result:=TextFormat;
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
var InputName, Extension, Key, Stamp, StampFile, Temporary, TemporaryStamp: string;
  Writer: TBookCacheWrite; Input, Target: TStream; KeepResult: Boolean;
begin
  InputName:=ExistingBookCacheFile(FileName); Result:=InputName; KeepResult:=False;
  Input:=OpenCachedBookFile(InputName);
  try
    Extension:=DetectReaderExtension(InputName);
    if (Extension='') or SameText(Extension,ExtractFileExt(InputName)) then
    begin KeepResult:=True; Exit; end;
    // Comic containers retain their dedicated reader identity.
    if (Extension='.zip') and InList(ExtractFileExt(InputName),'|cbz|fb3|epub|docx|odt|odp|ods|pptx|xlsx|apk|') then
    begin KeepResult:=True; Exit; end;
    if (Extension='.rar') and SameText(ExtractFileExt(InputName),'.cbr') then
    begin KeepResult:=True; Exit; end;
    if (Extension='.7z') and SameText(ExtractFileExt(InputName),'.cb7') then
    begin KeepResult:=True; Exit; end;
    // Stable dependency/content identity ignores only the owned cache's LRU Touch.
    Stamp:='format-v4|'+BookCacheInputStamp(InputName,Source);
    Key:=Copy(THashSHA2.GetHashString(Stamp),1,40);
    Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-detected-'+Key+Extension));
    StampFile:=Result+'.source';
    if FileExists(Result) and FileExists(StampFile) and (TFile.ReadAllText(StampFile,TEncoding.UTF8)=Stamp) then
    begin RegisterBookCacheFile(Result,Source); KeepResult:=True; Exit; end;
    ForceDirectories(ExtractFileDir(Result));
    Writer:=TBookCacheWrite.Create(Source);
    try
      Temporary:=Writer.TemporaryName(Result); TemporaryStamp:=Writer.TemporaryName(StampFile);
      Target:=TFileStream.Create(Temporary,fmCreate);
      try Input.Position:=0; Target.CopyFrom(Input,0); finally Target.Free; end;
      TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8); Writer.Publish(Temporary,Result,TemporaryStamp);
      KeepResult:=True;
    finally Writer.Free; end;
  finally
    // Releasing a managed input can immediately trim the cache. Protect the
    // completed result first, including unchanged-format and warm paths.
    if KeepResult then PinReaderCacheFile(Result);
    Input.Free;
  end;
end;

initialization
  FormatCache:=TDictionary<string,string>.Create;
  FormatCacheLock:=TCriticalSection.Create;
finalization
  FormatCacheLock.Free;
  FormatCache.Free;
end.
