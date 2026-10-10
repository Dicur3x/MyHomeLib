unit unit_BookMetadataCache;

interface
uses System.Classes, unit_Globals, unit_BookCache;
function ResolveArchivedBook(const Book: TBookRecord): TBookRecord;
function OpenBookMetadataSource(const Book: TBookRecord): TStream;
function OpenBookImageSource(const Book: TBookRecord): TStream;
function OpenRawBookSource(const Book: TBookRecord; const Writer: TBookCacheWrite = nil): TStream;

implementation
uses System.SysUtils, System.IOUtils, System.Hash, Winapi.Windows,
  unit_Settings, dm_user, unit_MHLArchiveHelpers, unit_Consts, unit_FB2Utils, FictionBook_21;

var CacheLock, PrefixLock: TObject;

function CacheName(const Book: TBookRecord): string;
var Source, Key, Ext: string; Attributes: TWin32FileAttributeData;

begin
  Source := Book.GetBookFileName;
  if not (Book.GetBookFormat in [bfFb2Archive,bfRawArchive]) then Exit(Source);
  if not GetFileAttributesEx(PChar(Source),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
  Key := Source+'|'+Book.FileName+Book.FileExt+'|'+IntToStr(Book.InsideNo)+'|'+
    IntToStr(Attributes.nFileSizeHigh)+':'+IntToStr(Attributes.nFileSizeLow)+'|'+
    IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
  Ext := '.'+Book.GetFileType;
  if (Pos(' ',Ext)>0) or (Length(Ext)>11) then Ext := '.book';
  Result := ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-metadata-'+Copy(THashSHA2.GetHashString(Key),1,40)+Ext));
end;

function CachedSource(const Book: TBookRecord; Writer: TBookCacheWrite = nil): string;
var Pending: string; Input: TStream; Output: TFileStream; OwnWriter: Boolean;
begin
  Result := CacheName(Book);
  if not (Book.GetBookFormat in [bfFb2Archive,bfRawArchive]) then Exit;
  TMonitor.Enter(CacheLock);
  try
    if FileExists(Result) then Exit;
    OwnWriter:=Writer=nil; if OwnWriter then Writer:=TBookCacheWrite.Create(Book.GetBookFileName);
    Input:=nil;
    try
      ForceDirectories(BookCachePath); Pending:=Writer.TemporaryName(Result);
      Input := Book.GetBookStream(True,False);
      if not Assigned(Input) then raise EFileNotFoundException.Create('Файл книги недоступен.');
      Output := TFileStream.Create(Pending,fmCreate);
      try Input.Position := 0; Output.CopyFrom(Input,0); finally Output.Free; end;
      Writer.Publish(Pending,Result);
    finally Input.Free; if OwnWriter then Writer.Free; end;
  finally TMonitor.Exit(CacheLock); end;
end;

function ArchivedDescription(const Book: TBookRecord): TStream;
var Raw, PrefixFile, XML, Pending: string; Archive: TMHLZip; Prefix: TMemoryStream;
  Document: IXMLFictionBook; Limit: Integer; Complete: Boolean; Writer: TBookCacheWrite;
begin
  Raw := CacheName(Book);
  if FileExists(Raw) then Exit(OpenCachedBookFile(Raw));
  PrefixFile := ExistingBookCacheFile(Raw+'.description.xml');
  if FileExists(PrefixFile) then Exit(OpenCachedBookFile(PrefixFile));
  TMonitor.Enter(PrefixLock);
  try
    if not FileExists(PrefixFile) then
    begin
      Writer:=TBookCacheWrite.Create(Book.GetBookFileName);
      Archive := nil; Prefix := nil;
      try
        Archive:=TMHLZip.Create(Book.GetBookFileName,True); Prefix:=TMemoryStream.Create;
        Limit := 64*1024; Complete := False;
        repeat
          Archive.ExtractBookPrefix(Book.FileName+Book.FileExt,Book.InsideNo,Limit,Prefix);
          try Document := LoadFB2Description(Prefix,False); Complete := True;
          except
            if (Prefix.Size<Limit) or (Limit>=16*1024*1024) then raise;
            Limit := Limit*4;
          end;
        until Complete;
        // A designated cover needs its binary block, usually stored at EOF.
        // Only those books require full extraction; a text-only description
        // remains a small, separate cache and is never mistaken for book bytes.
        if Document.Description.Titleinfo.Coverpage.Count>0 then
          Exit(OpenCachedBookFile(CachedSource(Book,Writer)));
        XML := Document.XML;
        ForceDirectories(BookCachePath); Pending:=Writer.TemporaryName(PrefixFile);
        try
          TFile.WriteAllText(Pending,XML,TEncoding.UTF8);
          Writer.Publish(Pending,PrefixFile);
        finally if FileExists(Pending) then System.SysUtils.DeleteFile(Pending); end;
      finally Document := nil; Prefix.Free; Archive.Free; Writer.Free; end;
    end;
    Result := OpenCachedBookFile(PrefixFile);
  finally TMonitor.Exit(PrefixLock); end;
end;

function ArchiveDescriptor(const Archive: TMHLZip; const Preferred: string;
  const AllowSingleBook: Boolean): TStream;
var I, Selected, Matching, Descriptors, DescriptorIndex, Readers, Fb2Index: Integer;
  Name, Key, Base: string;
  function Normalized(const Value: string): string;
  begin Result:=StringReplace(Value,'\','/',[rfReplaceAll]); end;
  function ReadingFormat(const Ext: string): Boolean;
  begin
    Result:=(Ext='.fb2') or (Ext='.pdf') or (Ext='.epub') or (Ext='.djvu') or (Ext='.djv') or
      (Ext='.mobi') or (Ext='.azw') or (Ext='.azw3') or (Ext='.rtf') or (Ext='.txt') or
      (Ext='.doc') or (Ext='.docx') or (Ext='.htm') or (Ext='.html') or (Ext='.xhtml') or
      (Ext='.odt') or (Ext='.chm');
  end;
begin
  Result:=nil; Selected:=-1; Matching:=0; Descriptors:=0; DescriptorIndex:=-1;
  Readers:=0; Fb2Index:=-1; Key:=Normalized(Preferred); Base:=Copy(Key,LastDelimiter('/\',Key)+1,MaxInt);
  for I:=0 to Archive.FileCount-1 do
  begin
    Name:=Normalized(Archive.FileNames[I]);
    if SameText(Name,Key) then Selected:=I;
    if SameText(ExtractFileExt(Name),FBD_EXTENSION) then
    begin
      Inc(Descriptors); DescriptorIndex:=I;
      if SameText(Copy(Name,LastDelimiter('/\',Name)+1,MaxInt),Base) then
      begin Inc(Matching); if Selected<0 then Selected:=I; end;
    end;
    if ReadingFormat(LowerCase(ExtractFileExt(Name))) then
    begin Inc(Readers); if SameText(ExtractFileExt(Name),FB2_EXTENSION) then Fb2Index:=I; end;
  end;
  // Exact paths outrank basename fallback, even with duplicate names in folders.
  for I:=0 to Archive.FileCount-1 do
    if SameText(Normalized(Archive.FileNames[I]),Key) then
    begin Selected:=I; Matching:=1; Break; end;
  if Matching>1 then Selected:=-1;
  // A descriptor without a matching name is safe only for a single-book archive.
  if (Selected<0) and AllowSingleBook and (Readers<=1) and (Descriptors=1) then Selected:=DescriptorIndex;
  if (Selected<0) and AllowSingleBook and (Readers=1) and (Descriptors=0) then Selected:=Fb2Index;
  if Selected<0 then Exit;
  Result:=TMemoryStream.Create;
  try Archive.ExtractToStream(Selected,Result);
  except FreeAndNil(Result); raise; end;
end;

function DescriptorFromArchive(const Source, Preferred: string): TStream;
var Archive: TMHLZip;
begin
  Archive:=TMHLZip.Create(Source,True);
  try Result:=ArchiveDescriptor(Archive,Preferred,True); finally Archive.Free; end;
end;

function ResolveArchivedBook(const Book: TBookRecord): TBookRecord;
var Archive: TMHLZip; Member: string; Format: TBookFormat;
begin
  Result:=Book; Format:=Book.GetBookFormat;
  if (Format=bfRawArchive) or ((Format=bfFb2Archive) and
    ((Book.GetFileType='Неизвестен') or not SameText(Book.FileExt,'.'+Book.GetFileType))) then
  begin
    Archive:=TMHLZip.Create(Book.GetBookFileName,True);
    try Member:=Archive.ResolveBookName(Book.FileName+Book.FileExt,Book.InsideNo);
    finally Archive.Free; end;
    Result.FileExt:=LowerCase(ExtractFileExt(Member));
    Result.FileName:=Copy(Member,1,Length(Member)-Length(Result.FileExt));
  end;
end;

function OpenBookMetadataSource(const Book: TBookRecord): TStream;
var Source, Sidecar: string; Format: TBookFormat; Archive: TMHLZip; Corrected: TBookRecord;
begin
  Result:=nil; Corrected:=ResolveArchivedBook(Book);
  if (Corrected.FileName<>Book.FileName) or (Corrected.FileExt<>Book.FileExt) then
    Exit(OpenBookMetadataSource(Corrected));
  Format:=Book.GetBookFormat;
  if Format = bfFb2Archive then Exit(ArchivedDescription(Book));
  if Format = bfFb2 then Exit(OpenCachedBookFile(CachedSource(Book)));
  if Format = bfRawArchive then
  begin
    // FBD next to a PDF in the outer archive: do not unpack the large PDF.
    if not IsArchiveExt(Book.FileName+Book.FileExt) then
    begin
      Archive := TMHLZip.Create(Book.GetBookFileName,True);
      try
        Result:=ArchiveDescriptor(Archive,Book.FileName+FBD_EXTENSION,False);
      finally Archive.Free; end;
      Exit;
    end;
  end;
  Source := CachedSource(Book);
  if IsArchiveExt(Source) then
    Result := DescriptorFromArchive(Source,Book.FileName+FBD_EXTENSION)
  else
  begin
    Sidecar := ChangeFileExt(Source,FBD_EXTENSION);
    if FileExists(Sidecar) then Result := TFileStream.Create(Sidecar,fmOpenRead or fmShareDenyWrite);
  end;
end;

function OpenBookImageSource(const Book: TBookRecord): TStream;
var Corrected: TBookRecord;
begin
  Corrected:=ResolveArchivedBook(Book);
  if (Corrected.FileName<>Book.FileName) or (Corrected.FileExt<>Book.FileExt) then
    Exit(OpenBookImageSource(Corrected));
  // FLibrary keeps illustrations in companion image archives; preserve its
  // reconstruction. Ordinary FB2 is shared with the metadata reader as-is.
  if (Book.GetBookFormat = bfFb2Archive) and IsSevenZipArchive(Book.GetBookFileName) then
    Result := Book.GetBookStream(True)
  else if SameText(Book.FileExt,FB2_EXTENSION) or SameText(Book.FileExt,'.epub') then
    Result := OpenCachedBookFile(CachedSource(Book))
  else Result := OpenBookMetadataSource(Book);
end;

function OpenRawBookSource(const Book: TBookRecord; const Writer: TBookCacheWrite): TStream;
begin
  Result := OpenCachedBookFile(CachedSource(Book,Writer));
end;

initialization
  CacheLock := TObject.Create; PrefixLock := TObject.Create;
finalization
  PrefixLock.Free; CacheLock.Free;
end.
