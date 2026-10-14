// Native favorite views must use cached IDs and indexed catalog metadata.
procedure TestAuthorFavoriteDAO(const Collection: IBookCollection);
var
  View: IAuthorFavoriteCollectionView;
  Criteria: TBookSearchCriteria;
  Books: IBookIterator;
  Authors: IAuthorIterator;
  Book: TBookRecord;
  Author: TAuthorData;
  FavoriteID, OtherID, DeletedID, AuthorID: Integer;
  CatalogFile, OriginalHash, SystemHash: string;
  Actual, Expected: TStringList;
  DB: TSQLiteDatabase;
  Plan: TSQLiteQuery;
  PlanText: string;

  procedure ExpectBooks(const Titles: array of string);
  begin
    Actual.Clear; Expected.Clear;
    Books := Collection.Search(Criteria, False);
    Require(Books.RecordCount = Length(Titles), 'Favorite search has an incorrect count');
    while Books.Next(Book) do Actual.Add(Book.Title);
    Books := nil;
    for var Title in Titles do Expected.Add(Title);
    Actual.Sort; Expected.Sort;
    Require(Actual.Text = Expected.Text, 'Favorite search broadened or lost its restrictions');
  end;
begin
  RequireIsolatedRegression;
  Require(Supports(Collection, IAuthorFavoriteCollectionView, View), 'Indexed favorite author view is absent');
  FavoriteID := AddBook(Collection, 'Favorite visible', 'Favorite oracle', 'ru', '', '0.1');
  OtherID := AddBook(Collection, 'Other visible', 'Other oracle', 'uk', '', '0.1');
  DeletedID := AddBook(Collection, 'Favorite deleted', 'Favorite oracle', 'ru', '', '0.1', True);
  Collection.GetBookRecord(CreateBookKey(FavoriteID, Collection.CollectionID), Book, False);
  AuthorID := Book.Authors[0].AuthorID;
  CatalogFile := SystemDB.GetCollectionInfo(Collection.CollectionID).DBFileName;
  OriginalHash := THashSHA2.GetHashStringFromFile(CatalogFile);
  SystemHash := THashSHA2.GetHashStringFromFile(Settings.SystemFileName[sfSystemDB]);
  Actual := TStringList.Create; Expected := TStringList.Create;
  try
    Criteria := Default(TBookSearchCriteria);
    Criteria.DateIdx := -1;
    Criteria.CollapseMultiSeriesResults := True;
    Criteria.FavoriteAuthorsOnly := True;
    ExpectBooks([]);
    Criteria.FavoriteAuthorIDs := [0, -1, AuthorID, AuthorID];
    Criteria.Deleted := True;
    ExpectBooks(['Favorite visible']);
    Criteria.Deleted := False;
    ExpectBooks(['Favorite visible', 'Favorite deleted']);
    Criteria.Lang := '="uk"'; ExpectBooks([]);
    Criteria.Lang := '="ru"';
    Criteria.RestrictBookIDs := True;
    Criteria.BookIDs := [OtherID, FavoriteID, FavoriteID];
    ExpectBooks(['Favorite visible']);
    Criteria.BookIDs := nil; ExpectBooks([]);
    Criteria.BookIDs := [DeletedID]; ExpectBooks(['Favorite deleted']);
    Criteria.FullName := 'Other oracle'; ExpectBooks([]);
    Authors := View.GetFavoriteAuthorIterator(nil);
    Require((Authors.RecordCount = 0) and not Authors.Next(Author),
      'Empty favorites opened the full author catalog');
    Authors := View.GetFavoriteAuthorIterator([AuthorID, AuthorID, 0, -1]);
    Require((Authors.RecordCount = 1) and Authors.Next(Author) and
      (Author.AuthorID = AuthorID) and not Authors.Next(Author),
      'Favorite authors are duplicated or do not match captured IDs');
    Authors := nil;
    DB := TSQLiteDatabase.CreateReadOnly(CatalogFile);
    try
      Plan := DB.NewQuery('EXPLAIN QUERY PLAN SELECT DISTINCT BookID FROM Author_List ' +
        'INDEXED BY IXAuthorList_AuthorID_BookID WHERE AuthorID IN (' + IntToStr(AuthorID) + ')');
      try
        Plan.Open; PlanText := '';
        while not Plan.Eof do begin PlanText := PlanText + Plan.FieldAsString(3); Plan.Next; end;
        Require(PlanText.Contains('SEARCH') and PlanText.Contains('IXAuthorList_AuthorID_BookID'),
          'Favorite-book restriction scans the catalog instead of its author index');
      finally Plan.Free; end;
    finally DB.Free; end;
    Require(THashSHA2.GetHashStringFromFile(CatalogFile) = OriginalHash,
      'Favorite views changed catalog bytes');
    Require(THashSHA2.GetHashStringFromFile(Settings.SystemFileName[sfSystemDB]) = SystemHash,
      'Favorite views changed personal history or book records');
    Writeln('PASS favorite DAO intersects author, book, language, deletion and draft IDs using catalog indexes without data writes');
  finally Expected.Free; Actual.Free; end;
end;
