unit unit_CollectionTransferCache;

interface

uses System.SysUtils, SQLiteWrap;

type TTransferCacheProjection=record Examined,Changed,SourceKeys,ReviewKeys:Int64; end;

// Rewrite only a caller-owned unpublished cache clone in its transaction.
// Each attempt starts from the immutable baseline, never a partly projected copy.
// This projects metadata from the frozen review; it grants no payload access,
// source deletion or permission to publish the clone to a collection.
function ProjectTransferCache(Review,Cache:TSQLiteDatabase;
  const SourceID,Namespace,BeforeRoot,AfterRoot:string; const Check:TProc=nil):TTransferCacheProjection;

implementation

uses System.Classes, System.IOUtils, System.Generics.Collections, SQLite3, unit_Globals, unit_CollectionMerge,
  unit_CollectionTransferLayout, unit_LibraryUpdateIdentity;

procedure EnableCacheTriggers(Context:TSQLite3Context; Count:Integer; Values:TSQLite3Value); cdecl;
begin SQLite3_Result_Int(Context,1); end;

function Normal(const Path:string):string;
begin Result:=LowerCase(ExpandFileName(Path.Replace('/','\'))); end;

function ProjectTransferCache(Review,Cache:TSQLiteDatabase;
  const SourceID,Namespace,BeforeRoot,AfterRoot:string; const Check:TProc):TTransferCacheProjection;
type TRootAlias=record Input,Canonical:string; end;
var Layout:TCollectionTransferLayout; Roots:TList<TRootAlias>;
    Rows,Put,Find,Keys,ReviewKeys,Publishers,SaveKey,SaveReviewKey,SavePublisher:TSQLiteQuery;
    Merge:TMergeSource; AddPath:TProc<string,string,string>; TempCreated:Boolean; Operation:string;
  procedure Poll;
  begin if Assigned(Check) then Check; end;
  function Saved(Query:TSQLiteQuery; ID:Integer; const DefaultValue:string):string;
  begin
    Result:=DefaultValue; Query.Reset; Query.SetParam(0,ID); Query.Open;
    if not Query.Eof then
    begin Result:=Query.FieldAsString(0); if Result='' then raise EReadError.Create('Пустой исходный ключ кэша.'); end;
  end;
  procedure Save(Query:TSQLiteQuery; ID:Integer; const Value:string);
  begin Query.Reset; Query.SetParam(0,ID); Query.SetParam(1,Value); Query.ExecSQL; end;
  procedure Locate(var Book:TBookRecord; const Path,Root:string; Format:TBookFormat);
  begin
    Book.CollectionRoot:=IncludeTrailingPathDelimiter(Root);
    if Format in [bfFb2Archive,bfRawArchive] then Book.Folder:=Path
    else
    begin
      Book.Folder:=IncludeTrailingPathDelimiter(ExtractFileDir(Path)); Book.FileName:=ExtractFileName(Path);
      if Format<>bfFbd then
      begin
        if not Book.FileName.EndsWith(Book.FileExt,True) then raise EReadError.Create('Изменилось расширение книги в кэше.');
        SetLength(Book.FileName,Length(Book.FileName)-Length(Book.FileExt));
      end;
      if Book.GetBookFormat(TPath.Combine(Book.CollectionRoot,Book.Folder))<>Format then
      begin
        Book.Folder:=''; Book.FileName:=Path;
        if Format<>bfFbd then SetLength(Book.FileName,Length(Book.FileName)-Length(Book.FileExt));
      end;
    end;
    var Container:=TPath.Combine(Book.CollectionRoot,Book.Folder);
    if (Book.GetBookFormat(Container)<>Format) or not SameFileName(ExpandFileName(Book.GetBookFileName(Container)),Path) then
      raise EReadError.Create('Новый адрес меняет способ чтения книги из кэша.');
  end;
begin
  Result:=Default(TTransferCacheProjection);
  if (Review=nil) or (Cache=nil) or not Cache.InTransaction or (SourceID='') or
    (BeforeRoot='') or (AfterRoot='') or not TPath.IsPathRooted(BeforeRoot) or not TPath.IsPathRooted(AfterRoot) then
    raise EArgumentException.Create('Нужна транзакция собственной копии кэша и исходные папки источника.');
  Layout:=nil; Roots:=nil; Rows:=nil; Put:=nil; Find:=nil; Keys:=nil; ReviewKeys:=nil; Publishers:=nil;
  SaveKey:=nil; SaveReviewKey:=nil; SavePublisher:=nil;
  TempCreated:=False;
  try
    Layout:=TCollectionTransferLayout.Create(Review); Roots:=TList<TRootAlias>.Create;
    Operation:=Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''directory''');
    if Operation='' then raise EReadError.Create('Нет операции переноса для кэша.');
    Cache.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibreTransferCacheProjections('+
      'Operation TEXT NOT NULL,SourceID TEXT NOT NULL,BeforeRoot TEXT NOT NULL,AfterRoot TEXT NOT NULL,PRIMARY KEY(Operation,SourceID)) WITHOUT ROWID');
    if Cache.QuerySingleInt('SELECT count(*) FROM HomeLibreTransferCacheProjections WHERE Operation=? AND SourceID=?',[Operation,SourceID])<>0 then
      raise EReadError.Create('Для повторной подготовки нужна новая копия исходного кэша.');
    // SQLiteWrap defaults TEMP tables to memory. Keep this indexed scratch
    // table on the owned clone's selected work volume, even for large sources.
    Cache.ExecSQL('CREATE TABLE HomeLibreTransferCachePaths(Path TEXT PRIMARY KEY,Destination TEXT NOT NULL,KeyContainer TEXT NOT NULL) WITHOUT ROWID');
    TempCreated:=True;
    Put:=Cache.NewQuery('INSERT INTO HomeLibreTransferCachePaths VALUES(?,?,?)');
    Find:=Cache.NewQuery('SELECT Destination,KeyContainer FROM HomeLibreTransferCachePaths WHERE Path=?');
    AddPath:=procedure(Path,Destination,KeyContainer:string)
  begin
    if Assigned(Check) then Check; Find.Reset; Find.SetParam(0,Normal(Path)); Find.Open;
    if not Find.Eof then
    begin
      if not SameFileName(Find.FieldAsString(0),Destination) or
        not SameFileName(Find.FieldAsString(1),KeyContainer) then
        raise EReadError.Create('Неоднозначный адрес книги в кэше источника: '+Path);
      Exit;
    end;
    Put.Reset; Put.SetParam(0,Normal(Path)); Put.SetParam(1,Destination); Put.SetParam(2,KeyContainer); Put.ExecSQL;
  end;

    Rows:=Review.NewQuery('SELECT InputPath,CanonicalPath FROM Roots WHERE CanonicalPath IS NOT NULL'); Rows.Open;
    while not Rows.Eof do
    begin
      var Alias:TRootAlias; Alias.Input:=IncludeTrailingPathDelimiter(ExpandFileName(Rows.FieldAsString(0)));
      Alias.Canonical:=IncludeTrailingPathDelimiter(ExpandFileName(Rows.FieldAsString(1))); Roots.Add(Alias); Rows.Next;
    end;
    FreeAndNil(Rows);
    Rows:=Review.NewQuery('SELECT Source,Destination FROM Files ORDER BY ID'); Rows.Open;
    while not Rows.Eof do
    begin
      var Source:=Rows.FieldAsString(0); var Destination:=Rows.FieldAsString(1);
      AddPath(Source,Destination,Source);
      for var Alias in Roots do
        if Source.StartsWith(Alias.Canonical,True) then
        begin
          var Logical:=Alias.Input+Copy(Source,Length(Alias.Canonical)+1,MaxInt);
          AddPath(Logical,Destination,Logical);
        end;
      Rows.Next;
    end;
    FreeAndNil(Rows);
    // ZIP-to-7z fallback is authorized only by an absent logical path captured
    // in this review, never by probing a name which another writer may reuse.
    Rows:=Review.NewQuery('SELECT b.Source,f.Destination FROM Bindings b JOIN Files f ON f.ID=b.FileID ORDER BY b.ID'); Rows.Open;
    while not Rows.Eof do begin AddPath(Rows.FieldAsString(0),Rows.FieldAsString(1),Rows.FieldAsString(0)); Rows.Next; end;
    FreeAndNil(Rows);
    Rows:=Review.NewQuery('SELECT Path FROM NegativePaths ORDER BY Path'); Rows.Open;
    while not Rows.Eof do
    begin
      Poll; var Path:=Rows.FieldAsString(0);
      if SameText(ExtractFileExt(Path),'.zip') then
      begin
        var Alternate:=ChangeFileExt(Path,'.7z'); Find.Reset; Find.SetParam(0,Normal(Alternate)); Find.Open;
        if not Find.Eof then
        begin var Destination:=Find.FieldAsString(0); var KeyContainer:=Find.FieldAsString(1); AddPath(Path,Destination,KeyContainer); end;
      end;
      Rows.Next;
    end;
    FreeAndNil(Rows);
    Layout.ForEachFutureLocator(
      procedure(const Locator:TTransferFutureLocator)
      begin
        var Path:=Review.QuerySingleString('SELECT Source FROM Bindings WHERE ID=?',[Locator.BindingID]);
        AddPath(Path,Locator.Source,Path);
      end);
    Cache.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateSourceKeys(BookID INTEGER PRIMARY KEY,SourceKey TEXT NOT NULL)');
    Cache.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateReviewKeys(BookID INTEGER PRIMARY KEY,Key TEXT NOT NULL)');
    Cache.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdatePublisherLocations(BookID INTEGER PRIMARY KEY,Location TEXT NOT NULL)');
    Keys:=Cache.NewQuery('SELECT SourceKey FROM LibraryUpdateSourceKeys WHERE BookID=?');
    ReviewKeys:=Cache.NewQuery('SELECT Key FROM LibraryUpdateReviewKeys WHERE BookID=?');
    Publishers:=Cache.NewQuery('SELECT Location FROM LibraryUpdatePublisherLocations WHERE BookID=?');
    SaveKey:=Cache.NewQuery('INSERT OR REPLACE INTO LibraryUpdateSourceKeys VALUES(?,?)');
    SaveReviewKey:=Cache.NewQuery('INSERT OR REPLACE INTO LibraryUpdateReviewKeys VALUES(?,?)');
    SavePublisher:=Cache.NewQuery('INSERT OR REPLACE INTO LibraryUpdatePublisherLocations VALUES(?,?)');
    Cache.AddFunction('MHL_TRIGGERS_ON',0,EnableCacheTriggers);
    FreeAndNil(Put); Put:=Cache.NewQuery('UPDATE Books SET Folder=?,FileName=? WHERE BookID=?');
    Rows:=Cache.NewQuery('SELECT BookID,LibID,Folder,FileName,Ext,InsideNo FROM Books ORDER BY BookID'); Rows.Open;
    while not Rows.Eof do
    begin
      Poll; Inc(Result.Examined);
      var Before:=Default(TBookRecord); Before.BookKey.BookID:=Rows.FieldAsInt(0);
      Before.CollectionRoot:=IncludeTrailingPathDelimiter(BeforeRoot); Before.LibID:=Rows.FieldAsString(1);
      Before.Folder:=Rows.FieldAsString(2); Before.FileName:=Rows.FieldAsString(3);
      Before.FileExt:=Rows.FieldAsString(4); Before.InsideNo:=Rows.FieldAsInt(5);
      if Before.FileName<>'' then
      begin
        var Container:=TPath.Combine(Before.CollectionRoot,Before.Folder); var Format:=Before.GetBookFormat(Container);
        var Path:=ExpandFileName(Before.GetBookFileName(Container)); var Destination:=Path;
        Find.Reset; Find.SetParam(0,Normal(Path)); Find.Open;
        if not Find.Eof then
        begin
          Destination:=Find.FieldAsString(0);
          if Format in [bfFb2Archive,bfRawArchive] then Container:=Find.FieldAsString(1);
        end;
        var After:=Before; After.CollectionRoot:=IncludeTrailingPathDelimiter(AfterRoot);
        if not SameFileName(ExpandFileName(After.GetBookFileName(TPath.Combine(After.CollectionRoot,After.Folder))),Destination) then
          Locate(After,Destination,AfterRoot,Format);
        Merge:=Default(TMergeSource); Merge.ID:=SourceID; Merge.Root:=BeforeRoot;
        var Expected:=Saved(Keys,Before.BookKey.BookID,MergeSourceKeyAtLocation(Merge,Before,Container));
        if not Expected.StartsWith(SourceID+':file:',True) then
          raise EReadError.Create('Сохранённый ключ относится к другому источнику.');
        Merge.Root:=AfterRoot;
        var Generated:=MergeSourceKeyAtLocation(Merge,After,TPath.Combine(After.CollectionRoot,After.Folder));
        if Expected<>Generated then
        begin
          Save(SaveKey,Before.BookKey.BookID,Expected); Inc(Result.SourceKeys);
        end;
        Expected:=Saved(ReviewKeys,Before.BookKey.BookID,LibraryUpdateBookKey(Before,Namespace,BeforeRoot));
        Generated:=LibraryUpdateBookKey(After,Namespace,AfterRoot);
        if Expected<>Generated then
        begin
          Save(SaveReviewKey,Before.BookKey.BookID,Expected); Inc(Result.ReviewKeys);
        end;
        // Keep the publisher's address even when ordinary relative rows now
        // need an absolute locator outside their source's relocated root.
        Expected:=Saved(Publishers,Before.BookKey.BookID,LibraryLegacyPublisherLocation(Before));
        Save(SavePublisher,Before.BookKey.BookID,Expected);
        if (After.Folder<>Before.Folder) or (After.FileName<>Before.FileName) then
        begin
          Put.Reset; Put.SetParam(0,After.Folder); Put.SetParam(1,After.FileName); Put.SetParam(2,Before.BookKey.BookID); Put.ExecSQL;
          Inc(Result.Changed);
        end;
      end;
      Rows.Next;
    end;
    Poll;
    Cache.ExecSQL('INSERT INTO HomeLibreTransferCacheProjections VALUES(?,?,?,?)',[Operation,SourceID,BeforeRoot,AfterRoot]);
  finally
    AddPath:=nil; SavePublisher.Free; SaveReviewKey.Free; SaveKey.Free;
    Publishers.Free; ReviewKeys.Free; Keys.Free; Rows.Free; Find.Free; Put.Free; Roots.Free; Layout.Free;
    if TempCreated then Cache.ExecSQL('DROP TABLE HomeLibreTransferCachePaths');
  end;
end;

end.
