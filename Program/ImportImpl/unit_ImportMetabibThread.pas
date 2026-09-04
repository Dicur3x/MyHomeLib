(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             22.08.2026
  * Description         Импорт каталога metabib (jsonl / jsonl.zst / jsonl.gz /
  *                     zip) в коллекцию. Повторяет структуру unit_ImportInpxThread.
  *
  ****************************************************************************** *)

unit unit_ImportMetabibThread;

interface

uses
  Windows,
  unit_WorkerThread,
  unit_CollectionWorkerThread,
  unit_Globals,
  unit_Interfaces,
  unit_MetabibReader;

type
  TImportMetabibThreadBase = class(TCollectionWorker)
  protected
    FGenresType: TGenresType;

    procedure MapBook(const MB: TMetabibBook; var R: TBookRecord);
    procedure Import(const DatasetFileName: string; CheckFiles: Boolean;
      BookCollection: IBookCollection);
  end;

  TImportMetabibThread = class(TImportMetabibThreadBase)
  protected
    FDatasetFileName: string;
    procedure WorkFunction; override;

  public
    constructor Create(const CollectionID: Integer; const DatasetFileName: string;
      GenresType: TGenresType);
  end;

implementation

uses
  Classes,
  SysUtils,
  IOUtils,
  ComCtrls,
  unit_Consts,
  unit_Errors,
  dm_user;

resourcestring
  rstrMbProcessingFile = 'Импорт каталога metabib %s (%s, %u записей)';
  rstrMbAddedBooks = 'Добавлено книг: %u';
  rstrMbBadLine = 'Ошибка структуры каталога. Строка %u';
  rstrMbDBError = 'Ошибка базы данных при импорте книги. Строка %u';
  rstrMbSkippedNoFile = 'Пропущено записей без файла в архивах: %u';
  rstrMbSkippedBadLines = 'Пропущено ошибочных строк: %u';
  rstrMbUpdatingDB = 'Обновление базы данных. Пожалуйста, подождите...';

{ TImportMetabibThreadBase }

//
// Переносит разобранную запись metabib в TBookRecord.
// Расположение (Folder/IsLocal для онлайн-ветки) дополняет Import:
// оно зависит от типа коллекции.
//
procedure TImportMetabibThreadBase.MapBook(const MB: TMetabibBook; var R: TBookRecord);
var
  i: Integer;
  s: string;

  function PersonLastName(const Person: TMetabibPerson): string;
  begin
    Result := Person.LastName;
    if Result = '' then
      Result := Person.NickName;
  end;

  function PersonDisplayName(const Person: TMetabibPerson): string;
  begin
    Result := Trim(Person.LastName + ' ' + Person.FirstName + ' ' +
      Person.MiddleName);
    if Result = '' then
      Result := Person.NickName;
  end;
begin
  R.Clear;

  R.Title := MB.Title;
  if R.Title = '' then
    R.Title := MB.BookName;

  for i := 0 to High(MB.Authors) do
    TAuthorsHelper.Add(R.Authors, PersonLastName(MB.Authors[i]), MB.Authors[i].FirstName,
      MB.Authors[i].MiddleName);

  for i := 0 to High(MB.Genres) do
    if FGenresType = gtFb2 then
      TGenresHelper.Add(R.Genres, '', '', MB.Genres[i])
    else
      TGenresHelper.Add(R.Genres, MB.Genres[i], '', '');

  if MB.SeriesName <> '' then
  begin
    R.Series := MB.SeriesName;
    R.SeqNumber := MB.SeriesNo;
  end;

  R.Lang := LowerCase(Copy(MB.Lang, 1, 2));
  R.Annotation := MB.Annotation;
  R.KeyWords := MB.Keywords;
  R.LibRate := Round(MB.RatingAvg);

  if MB.Deleted then
    Include(R.BookProps, bpIsDeleted)
  else
    Exclude(R.BookProps, bpIsDeleted);

  if MB.Stamp <> 0 then
    R.Date := MB.Stamp
  else
    R.Date := Date; // дата импорта согласно спецификации

  if MB.BookID > 0 then
    R.LibID := IntToStr(MB.BookID);

  // ---- новые поля
  s := '';
  for i := 0 to High(MB.Translators) do
  begin
    if s <> '' then
      s := s + ', ';
    s := s + PersonDisplayName(MB.Translators[i]);
  end;
  R.Translators := s;
  R.Publisher := MB.Publisher;
  R.City := MB.City;
  R.PubYear := MB.PubYear;
  R.ISBN := MB.ISBN;

  R.Normalize; // автор/жанр/название по умолчанию, как при импорте INPX
end;

procedure TImportMetabibThreadBase.Import(const DatasetFileName: string;
  CheckFiles: Boolean; BookCollection: IBookCollection);
var
  Reader: TMetabibReader;
  MB: TMetabibBook;
  R: TBookRecord;
  IsOnline: Boolean;
  collectionCode: Integer;
  CollectionRoot: string;
  ArcName: string;
  idx, added, skippedNoFile, badLines: Integer;
  InsertedBookID: Integer;
  SequenceIndex: Integer;
  Skip: Boolean;
  Cache: TImportCache;
begin
  SetProgress(0);
  collectionCode := BookCollection.CollectionCode;
  IsOnline := isOnlineCollection(collectionCode);
  CollectionRoot := BookCollection.GetProperty(PROP_ROOTFOLDER);

  idx := 0;
  added := 0;
  skippedNoFile := 0;
  badLines := 0;

  Reader := nil;
  Cache := nil;
  BookCollection.StartBatchUpdate;
  try
    Cache := TImportCache.Create;
    Reader := TMetabibReader.Create(DatasetFileName);

    Teletype(Format(rstrMbProcessingFile,
      [ExtractFileName(DatasetFileName), Reader.LibraryName,
      Cardinal(Reader.RecordCount)]), tsInfo);

    if Reader.RecordCount > 0 then
      SetProgressHint(pbstNormal, pbsNormal); // иначе полоса останется в режиме marquee

    while True do
    begin
      case Reader.ReadNext(MB) of
        mrEof:
          Break;

        mrBadLine:
          begin
            Inc(badLines);
            Teletype(Format(rstrMbBadLine, [Cardinal(Reader.LineNo)]), tsError);
          end;

        mrOk:
          try
            MapBook(MB, R);
            Skip := False;

            if IsOnline then
            begin
              //
              // Онлайн-коллекция: файл ещё не загружен, LibID — ключ
              // загрузки. Записи без book_id загрузить невозможно.
              //
              if MB.BookID <= 0 then
              begin
                Inc(skippedNoFile);
                Skip := True;
              end
              else
              begin
                R.FileName := IntToStr(MB.BookID);
                R.FileExt := FB2_EXTENSION;
                R.InsideNo := 0;
                R.Size := MB.UncompressedSize;
                if 0 = (CONTENT_NONFB and collectionCode) then
                  R.Folder := R.GenerateLocation + FB2ZIP_EXTENSION;
                if FileExists(TPath.Combine(CollectionRoot, R.Folder)) then
                  Include(R.BookProps, bpIsLocal)
                else
                  Exclude(R.BookProps, bpIsLocal);
              end;
            end
            else
            begin
              //
              // Локальная коллекция: без артефакта записи не на что ссылаться.
              //
              ArcName := '';
              if MB.HasArtifact then
                ArcName := Reader.ArchiveName(MB.ArchiveID);
              // Имя архива из каталога не должно быть путём: защита от обхода папок
              if (not MB.HasArtifact) or (ArcName = '') or (MB.EntryName = '') or
                (Pos('\', ArcName) > 0) or (Pos('/', ArcName) > 0) or (Pos('..', ArcName) > 0) then
              begin
                Inc(skippedNoFile);
                Skip := True;
              end
              else
              begin
                R.Folder := ArcName;
                R.FileName := TPath.GetFileNameWithoutExtension(MB.EntryName);
                R.FileExt := ExtractFileExt(MB.EntryName);
                if R.FileExt = '' then
                  R.FileExt := FB2_EXTENSION;
                R.InsideNo := MB.EntryIndex;
                R.Size := MB.UncompressedSize;
                Include(R.BookProps, bpIsLocal);
                if R.LibID = '' then
                  R.LibID := R.FileName;
              end;
            end;

            if not Skip then
              try
                InsertedBookID := BookCollection.InsertBook(
                  R, CheckFiles, False, Cache
                );
                if InsertedBookID <> 0 then
                begin
                  for SequenceIndex := 1 to High(MB.Sequences) do
                    BookCollection.AddBookSeries(
                      InsertedBookID,
                      MB.Sequences[SequenceIndex].Name,
                      MB.Sequences[SequenceIndex].Number,
                      Cache
                    );
                  Inc(added);
                end;
              except
                on E: Exception do
                  raise EDBError.Create(E.Message);
              end;
          except
            on E: EDBError do
            begin
              Teletype(Format(rstrMbDBError, [Cardinal(Reader.LineNo)]), tsError);
              // После ошибки базы транзакцию нельзя считать целостной.
              raise;
            end;
            on E: Exception do
              Teletype(E.Message, tsError);
          end;
      end;

      Inc(idx);
      if Reader.RecordCount > 0 then
        SetProgress(idx * 100 div Reader.RecordCount);

      if (idx mod ProcessedItemThreshold) = 0 then
      begin
        SetComment(Format(rstrMbAddedBooks, [Cardinal(added)]));
        if Canceled then
          Break;
      end;
    end;

    if Canceled then
      Exit;

    Teletype(Format(rstrMbAddedBooks, [Cardinal(added)]), tsInfo);
    if skippedNoFile > 0 then
      Teletype(Format(rstrMbSkippedNoFile, [Cardinal(skippedNoFile)]), tsWarning);
    if badLines > 0 then
      Teletype(Format(rstrMbSkippedBadLines, [Cardinal(badLines)]), tsWarning);

    FProgressEngine.BeginOperation(-1, rstrMbUpdatingDB, '');
    try
      BookCollection.AfterBatchUpdate;
    finally
      FProgressEngine.EndOperation;
    end;
  finally
    FreeAndNil(Reader);
    FreeAndNil(Cache);
    BookCollection.FinishBatchUpdate;
  end;
end;

{ TImportMetabibThread }

constructor TImportMetabibThread.Create(const CollectionID: Integer;
  const DatasetFileName: string; GenresType: TGenresType);
begin
  inherited Create(CollectionID);
  FDatasetFileName := DatasetFileName;
  FGenresType := GenresType;
end;

procedure TImportMetabibThread.WorkFunction;
begin
  Assert(Assigned(FCollection));

  FCollection.BeginBulkOperation;
  try
    Import(FDatasetFileName, False, FCollection);
    if Canceled then
      FCollection.EndBulkOperation(False)
    else
      FCollection.EndBulkOperation(True);
  except
    on E: Exception do
    begin
      Teletype(E.Message, tsError);
      FCollection.EndBulkOperation(False);
      raise;
    end;
  end;
end;

end.
