unit unit_SeriesAliasMatching;

interface

uses System.SysUtils, SQLiteWrap, unit_CollectionMerge;

type
  TSeriesAliasCandidate = record
    ID, Rank: Integer;
    Title, Key: string;
    Tag: Char;
  end;

function SeriesAliasCandidate(ID: Integer; const Title: string): TSeriesAliasCandidate;
function SeriesHaveSameBook(DB: TSQLiteDatabase; LeftID, RightID: Integer;
  const LibraryNamespace: string; const Canceled: TMergeCanceled): Boolean;
function SeriesHaveSameAuthor(DB: TSQLiteDatabase; LeftID, RightID: Integer): Boolean;

implementation

uses System.Generics.Collections, System.Character, unit_LibrarySourceID;

function SeriesAliasCandidate(ID: Integer; const Title: string): TSeriesAliasCandidate;
const MixedLabel = '[межавторский цикл]';
var Name, Suffix: string; Size: Integer;
begin
  Result:=Default(TSeriesAliasCandidate); Result.ID:=ID; Result.Title:=Title;
  Name:=Trim(Title);
  for Size in [5,3] do
  begin
    Suffix:=LowerCase(Copy(Name,Length(Name)-Size+1,Size));
    if ((Size=5) and ((Suffix='[[a]]') or (Suffix='[[p]]') or (Suffix='[[m]]'))) or
      ((Size=3) and ((Suffix='[a]') or (Suffix='[p]') or (Suffix='[m]'))) then
    begin
      Result.Tag:=Suffix[(Size+1) div 2];
      Name:=Trim(Copy(Name,1,Length(Name)-Size)); Result.Rank:=10; Break;
    end;
  end;
  // Only this explicit catalog label is equivalent to parentheses. Author
  // names such as [Гром] and other meaningful bracketed names stay distinct.
  if TCharacter.ToLower(Name).EndsWith(MixedLabel) then
  begin
    Name:=TrimRight(Copy(Name,1,Length(Name)-Length(MixedLabel)))+' (Межавторский цикл)';
    Inc(Result.Rank);
  end;
  Result.Key:=TCharacter.ToLower(Name);
end;

function SeriesHaveSameAuthor(DB: TSQLiteDatabase; LeftID, RightID: Integer): Boolean;
begin
  Result:=DB.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM Series_List x '+
    'JOIN Author_List a ON a.BookID=x.BookID JOIN Author_List b ON b.AuthorID=a.AuthorID '+
    'JOIN Series_List y ON y.BookID=b.BookID WHERE x.SeriesID=? AND y.SeriesID=?)',
    [LeftID,RightID])<>0;
end;

function SeriesHaveSameBook(DB: TSQLiteDatabase; LeftID, RightID: Integer;
  const LibraryNamespace: string; const Canceled: TMergeCanceled): Boolean;
const
  ChunkRows=4096;
  SQL='SELECT b.BookID,b.LibID,b.Title,b.Lang,b.Ext,b.Folder,a.AuthorID,b.IsDeleted,b.BookSize '+
    'FROM Series_List s JOIN Books b ON b.BookID=s.BookID '+
    'LEFT JOIN Author_List a ON a.BookID=b.BookID WHERE s.SeriesID=?';
var Left, Right: TSQLiteQuery; Keys: TDictionary<string,Boolean>;
  Rows, Swap: Integer;

  procedure CheckCanceled;
  begin if Assigned(Canceled) and Canceled() then Abort; end;

  function RowKeys(Query: TSQLiteQuery): TArray<string>;
  var ID, Namespace, Original, Title, Tail: string; P: Integer;
  begin
    Result:=['record:'+IntToStr(Query.FieldAsInt(0))];
    // Placeholders are not proof of equal works. A shared actual BookID above
    // still proves that the two series already reference the very same record.
    if (Query.FieldAsInt(7)<>0) or (Query.FieldAsInt(8)<=0) then Exit;
    Tail:=#1+LowerCase(Trim(Query.FieldAsString(3)))+#1+LowerCase(Query.FieldAsString(4));
    ID:=Query.FieldAsString(1);
    if ID.StartsWith('merged:',True) then
    begin
      Delete(ID,1,7); P:=Pos(':',ID);
      if P=0 then ID:='' else Delete(ID,1,P);
    end;
    if not TryParseLibrarySourceID(ID,Namespace,Original) then
    begin
      ID:=ScopedLibraryID(Query.FieldAsString(5),ID);
      if not TryParseLibrarySourceID(ID,Namespace,Original) then
      begin
        ID:=LowerCase(Trim(LibraryNamespace))+':'+ID;
        TryParseLibrarySourceID(ID,Namespace,Original);
      end;
    end;
    if Namespace<>'' then Result:=Result+['library:'+Namespace+':'+Original+Tail];
    // Equal title and catalog author also identify overlap across libraries,
    // whose numeric IDs are unrelated. A bare title or author is insufficient.
    Title:=TCharacter.ToLower(Trim(Query.FieldAsString(2)));
    if (Length(Title)>3) and (Title<>'без названия') and (Query.FieldAsInt(6)>0) then
      Result:=Result+['title:'+Title+Tail+#1+IntToStr(Query.FieldAsInt(6))];
  end;

begin
  Result:=False; CheckCanceled;
  if DB.QuerySingleInt('SELECT COUNT(*) FROM Series_List WHERE SeriesID=?',[LeftID])>
    DB.QuerySingleInt('SELECT COUNT(*) FROM Series_List WHERE SeriesID=?',[RightID]) then
  begin Swap:=LeftID; LeftID:=RightID; RightID:=Swap; end;
  Keys:=TDictionary<string,Boolean>.Create; Left:=nil; Right:=nil;
  try
    Left:=DB.NewQuery(SQL); Right:=DB.NewQuery(SQL);
    Left.SetParam(0,LeftID); Left.Open;
    while not Left.Eof do
    begin
      // Bounded independently of catalog/series size, including on x86. Only
      // matching series are visited; the whole book table is never loaded.
      Keys.Clear; Rows:=0;
      while not Left.Eof and (Rows<ChunkRows) do
      begin
        if Rows mod 64=0 then CheckCanceled;
        for var Key in RowKeys(Left) do Keys.AddOrSetValue(Key,True);
        Left.Next; Inc(Rows);
      end;
      Right.Reset; Right.SetParam(0,RightID); Right.Open; Rows:=0;
      while not Right.Eof do
      begin
        if Rows mod 64=0 then CheckCanceled;
        for var Key in RowKeys(Right) do if Keys.ContainsKey(Key) then Exit(True);
        Right.Next; Inc(Rows);
      end;
    end;
  finally Right.Free; Left.Free; Keys.Free; end;
end;

end.
