procedure TestSqlCatalogueDownloads(const SystemData: ISystemData);
const Sources: array[0..1] of string = ('flibusta','librusec');
var
  Source, IndexPath, Prepared, SavedHash: string;
  CID, Count: Integer;
  Collection: IBookCollection;
  Importer: TImportInpxThread;
  Books: IBookIterator;
  Book, Current: TBookRecord;
  Downloader: TDownloader;
  Document: TReaderDocument;
  Downloaded: Boolean;
  Update: TManualUpdateThread;
  OriginalCopies: TDictionary<string, string>;

  procedure CheckGenres(const Value: TBookRecord);
  begin
    Require((Value.GenreCount=1) and (Value.Genres[0].FB2GenreCode='prose_classic') and
      (Value.Genres[0].GenreAlias='Классическая проза'),
      'SQL catalogue lost the source genre code or title');
  end;
begin
  RequireIsolatedRegression;
  Settings.UseIESettings:=False;
  Settings.ProxyType:=0;
  Settings.ErrorLog:=True;
  for Source in Sources do
  begin
    IndexPath:=TPath.Combine(Settings.AppPath,Source+'.inpx');
    Require(FileExists(IndexPath),'Missing explicit SQL download fixture');
    CID:=SystemData.CreateCollection('SQL '+Source,
      TPath.Combine(Settings.AppPath,Source+'-books'),
      Source+'-sql.hlc2',CT_EXTERNAL_ONLINE_NONFB,Settings.AppPath+'genres_nonfb2.glst');
    Importer:=TImportInpxThread.Create(CID,IndexPath,gtAny);
    try
      Importer.Start;
      Importer.WaitFor;
      Require(Importer.Success and Importer.CommittedChanges,'SQL index did not import');
    finally Importer.Free; end;
    Collection:=SystemData.GetCollection(CID);
    Require(VarToStr(Collection.GetProperty(PROP_URL))=
      IfThen(Source='flibusta','https://flibusta.is/','https://lib.rus.ec/'),
      'The generated index changed its source');
    Require(VarToStr(Collection.GetProperty(PROP_CONNECTIONSCRIPT)).Contains('GET %URL%b/%LIBID%/get'),
      'The generated index lost its download script');
    Require(VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY))=Source,
      'SQL catalogue lost its source namespace');
    OriginalCopies:=TDictionary<string,string>.Create;
    try
    Count:=0;
    Books:=Collection.GetBookIterator(bmAll,True);
    while Books.Next(Book) do
    begin
      CheckGenres(Book);
      OriginalCopies.Add(Book.LibID,'');
      Require(not (bpIsLocal in Book.BookProps),'A generated record was already marked downloaded');
      Downloader:=TDownloader.Create;
      try
        Downloader.IgnoreErrors:=True;
        Downloaded:=Downloader.Download(SystemData,Book.BookKey);
      finally Downloader.Free; end;
      Collection.GetBookRecord(Book.BookKey,Current,False);
      if Source='flibusta' then
        Require(Downloaded,'Public Flibusta fixture did not download: '+Book.LibID);
      if Downloaded then
      begin
        Require((bpIsLocal in Current.BookProps) and FileExists(Current.GetBookFileName),
          'Downloaded SQL book has no readable local file');
        SavedHash:=UpdateSHA256(Current.GetBookFileName);
        OriginalCopies[Book.LibID]:=SavedHash;
        Prepared:=PrepareReaderFile(Current,True,nil,False,True,True);
        Document:=TReaderDocument.Create;
        try
          Document.Load(Prepared);
          Require(Length(Document.PlainText)>100,'Downloaded SQL book has no text');
          Writeln('PASS SQL download ',Source,' ',Book.LibID,' ',Book.FileExt,
            ' text=',Length(Document.PlainText));
          Flush(Output);
        finally Document.Free; end;
        Downloader:=TDownloader.Create;
        try
          Downloader.IgnoreErrors:=True;
          Require(Downloader.Download(SystemData,Book.BookKey),'Second access lost the downloaded SQL book');
        finally Downloader.Free; end;
        Require(UpdateSHA256(Current.GetBookFileName)=SavedHash,'Second access changed the downloaded book');
      end
      else
      begin
        Require(not FileExists(Current.GetBookFileName) and not (bpIsLocal in Current.BookProps),
          'An HTML or failed response was marked downloaded');
        Writeln('PASS SQL source response withheld ',Source,' ',Book.LibID);
        Flush(Output);
      end;
      Inc(Count);
    end;
    Books:=nil;
    Require(Count=IfThen(Source='flibusta',2,1),'SQL download fixture record count changed');
    Update:=TManualUpdateThread.Create(CID,IndexPath,True,gtAny);
    try
      Update.Start;
      Update.WaitFor;
      Require(Update.Success and Update.CommittedChanges,'SQL full snapshot refresh failed');
    finally Update.Free; end;
    Books:=Collection.GetBookIterator(bmAll,True);
    Count:=0;
    while Books.Next(Book) do
    begin
      CheckGenres(Book);
      Require(OriginalCopies.ContainsKey(Book.LibID),'SQL refresh changed source book identifiers');
      Require((bpIsLocal in Book.BookProps)=(OriginalCopies[Book.LibID]<>''),
        'SQL refresh lost a downloaded book or accepted an HTML response');
      if bpIsLocal in Book.BookProps then
        Require(FileExists(Book.GetBookFileName) and
          (UpdateSHA256(Book.GetBookFileName)=OriginalCopies[Book.LibID]),
          'SQL refresh changed the downloaded copy');
      Inc(Count);
    end;
    Books:=nil;
    Require(Count=OriginalCopies.Count,'SQL refresh changed the number of books');
    Update:=TManualUpdateThread.Create(CID,TPath.Combine(Settings.AppPath,
      IfThen(Source='flibusta','librusec','flibusta')+'.inpx'),False,gtAny);
    try
      Update.Start;
      Update.WaitFor;
      Require(not Update.Success and not Update.CommittedChanges,
        'A different library SQL snapshot was applied to the collection');
    finally Update.Free; end;
    Require(VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY))=Source,
      'Rejected foreign SQL snapshot changed the source namespace');
    Books:=Collection.GetBookIterator(bmAll,True);
    Count:=0;
    while Books.Next(Book) do
    begin CheckGenres(Book); Inc(Count); end;
    Books:=nil;
    Require(Count=OriginalCopies.Count,'Rejected foreign SQL snapshot changed books');
    Writeln('PASS SQL genres and downloaded files survive refresh; foreign source rejected ',Source);
    Flush(Output);
    finally OriginalCopies.Free; end;
  end;
  Writeln('PASS generated SQL indexes use native downloads and reader preparation without extra format modules');
end;
