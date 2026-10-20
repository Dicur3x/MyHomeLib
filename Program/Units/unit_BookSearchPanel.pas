unit unit_BookSearchPanel;

interface

uses Vcl.StdCtrls, unit_Globals;

type
  // UI references belong to the form. This adapter owns no windows and has
  // no dependency on Main, asynchronous favourites or database connections.
  TBookSearchControls = record
    Author, Series, Publisher, Translators, City, PubYear, ISBN: TCustomEdit;
    Annotation, Genre, Title, FileName, Folder, FileExt, Keyword: TCustomEdit;
    Language, Downloaded, LibRate, AddedDate: TComboBox;
    FavoriteAuthors, NotesOnly, Readed, CollapseSeries: TCheckBox;
  end;

function ReadBookSearchPanel(const Fields: TBookSearchControls;
  QueryMode: TSearchQueryMode; HideDeleted: Boolean): TBookSearchCriteria;
function SameBookSearchCriteria(const A, B: TBookSearchCriteria): Boolean;

implementation

function SameBookSearchCriteria(const A, B: TBookSearchCriteria): Boolean;
  function SameIDs(const X, Y: TArray<Integer>): Boolean;
  begin
    if Length(X) <> Length(Y) then Exit(False);
    for var I := 0 to High(X) do if X[I] <> Y[I] then Exit(False);
    Result := True;
  end;
  function SameNames(const X, Y: TArray<string>): Boolean;
  begin
    if Length(X) <> Length(Y) then Exit(False);
    for var I := 0 to High(X) do if X[I] <> Y[I] then Exit(False);
    Result := True;
  end;
begin
  Result := (A.QueryMode = B.QueryMode) and (A.FullName = B.FullName) and
    (A.Publisher = B.Publisher) and (A.Translators = B.Translators) and
    (A.City = B.City) and (A.PubYear = B.PubYear) and (A.ISBN = B.ISBN) and
    (A.ExactTitle = B.ExactTitle) and SameNames(A.ExactTitles, B.ExactTitles) and
    SameNames(A.LibraryIDs, B.LibraryIDs) and (A.NotesOnly = B.NotesOnly) and
    SameIDs(A.NoteBookIDs, B.NoteBookIDs) and
    (A.FavoriteAuthorsOnly = B.FavoriteAuthorsOnly) and
    SameIDs(A.FavoriteAuthorIDs, B.FavoriteAuthorIDs) and
    (A.RestrictBookIDs = B.RestrictBookIDs) and SameIDs(A.BookIDs, B.BookIDs) and
    (A.Series = B.Series) and (A.Annotation = B.Annotation) and (A.Genre = B.Genre) and
    (A.Title = B.Title) and (A.FileName = B.FileName) and (A.Folder = B.Folder) and
    (A.FileExt = B.FileExt) and (A.Lang = B.Lang) and (A.KeyWord = B.KeyWord) and
    (A.Deleted = B.Deleted) and (A.LibRate = B.LibRate) and (A.Readed = B.Readed) and
    (A.DownloadedIdx = B.DownloadedIdx) and (A.DateIdx = B.DateIdx) and
    (A.DateText = B.DateText) and
    (A.CollapseMultiSeriesResults = B.CollapseMultiSeriesResults);
end;

function ReadBookSearchPanel(const Fields: TBookSearchControls;
  QueryMode: TSearchQueryMode; HideDeleted: Boolean): TBookSearchCriteria;
begin
  Result := Default(TBookSearchCriteria);
  Result.QueryMode := QueryMode;
  Result.FullName := Fields.Author.Text;
  Result.FavoriteAuthorsOnly := Fields.FavoriteAuthors.Checked;
  Result.Series := Fields.Series.Text;
  Result.Publisher := Fields.Publisher.Text;
  Result.Translators := Fields.Translators.Text;
  Result.City := Fields.City.Text;
  Result.PubYear := Fields.PubYear.Text;
  Result.ISBN := Fields.ISBN.Text;
  Result.NotesOnly := Fields.NotesOnly.Checked;
  Result.Annotation := Fields.Annotation.Text;
  Result.Genre := Fields.Genre.Hint;
  Result.Title := Fields.Title.Text;
  Result.FileName := Fields.FileName.Text;
  Result.Folder := Fields.Folder.Text;
  Result.FileExt := Fields.FileExt.Text;
  Result.Lang := Fields.Language.Text;
  Result.Keyword := Fields.Keyword.Text;
  Result.DownloadedIdx := Fields.Downloaded.ItemIndex;
  Result.Deleted := HideDeleted;
  Result.LibRate := Fields.LibRate.Text;
  Result.Readed := Fields.Readed.Checked;
  Result.CollapseMultiSeriesResults := Fields.CollapseSeries.Checked;
  Result.DateIdx := Fields.AddedDate.ItemIndex;
  if Result.DateIdx = -1 then Result.DateText := Fields.AddedDate.Text;
end;

end.
