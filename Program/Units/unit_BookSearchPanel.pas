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

implementation

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
