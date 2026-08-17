(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  *                     Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             12.02.2010
  * Description
  *
  * $Id: unit_ImportInpxThread.pas 1144 2014-03-26 05:22:37Z ENikS $
  *
  * History
  * NickR 02.03.2010    Код переформатирован
  * NickR 02.09.2010    INPX больше не распаковывается на диск для обработки. Вся работа происходит в памяти.
  *
  ****************************************************************************** *)

unit unit_ImportInpxThread;

interface

uses
  Windows,
  Classes,
  unit_WorkerThread,
  unit_CollectionWorkerThread,
  unit_Globals,
  unit_Interfaces;

type
  TFields = (
    flNone,
    flAuthor,
    flTitle,
    flSeries,
    flSerNo,
    flGenre,
    flLibID,
    flInsideNo,
    flFile,
    flFolder,
    flExt,
    flSize,
    flLang,
    flDate,
    flCode,
    flDeleted,
    flRate,
    flURI,
    flLibRate,
    flKeyWords
  );

  TFieldDescr = record
    Code: string;
    FType: TFields;
  end;

  TImportInpxThreadBase = class(TCollectionWorker)
  protected
    FGenresType: TGenresType;

    FFields: array of TFields;
    FUseStoredFolder: Boolean;
    //
    // False (по умолчанию) — collection.info из архива применяется к коллекции.
    // True — свойства коллекции не изменяются: файл может быть чужим, и его
    // URL со скриптом подключения стер бы настройки пользователя.
    //
    FKeepCollectionProps: Boolean;

  protected
    procedure GetFields(const StructureInfo: string);
    procedure ParseData(const input: string; const OnlineCollection: Boolean;
      var R: TBookRecord; Params: TStringList);
    procedure Import(const INPXFileName: string; CheckFiles: Boolean; BookCollection: IBookCollection);
  end;

  TImportInpxThread = class(TImportInpxThreadBase)
  protected
    FInpxFileName: string;

  protected
    procedure WorkFunction; override;

  public
    constructor Create(const CollectionID: Integer; const INPXFileName: string; GenresType: TGenresType);
  end;

implementation

uses
  SysUtils,
  IOUtils,
  ComCtrls,
  unit_MHLArchiveHelpers,
  unit_Consts,
  unit_Helpers,
  unit_Errors,
  dm_user;

resourcestring
   rstrProcessingFile = 'Обработка файла %s';
   rstrAddedBooks = 'Добавлено %u книг';
   rstrErrorInpStructure = 'Ошибка обработки inp. Файл %s, строка %u';
   rstrDBErrorInp = 'Ошибка импорта в базу данных. Файл %s, строка %u';
   rstrUpdatingDB = 'Обновление базы данных. Подождите...';
   rstrInvalidFormat = 'Неверный формат файла INPX!';

const
  FieldsDescr: array [1 .. 20] of TFieldDescr = (
    (Code: 'AUTHOR';   FType: flAuthor),
    (Code: 'TITLE';    FType: flTitle),
    (Code: 'SERIES';   FType: flSeries),
    (Code: 'SERNO';    FType: flSerNo),
    (Code: 'GENRE';    FType: flGenre),
    (Code: 'LIBID';    FType: flLibID),
    (Code: 'INSNO';    FType: flInsideNo),
    (Code: 'FILE';     FType: flFile),
    (Code: 'FOLDER';   FType: flFolder),
    (Code: 'EXT';      FType: flExt),
    (Code: 'SIZE';     FType: flSize),
    (Code: 'LANG';     FType: flLang),
    (Code: 'DATE';     FType: flDate),
    (Code: 'CODE';     FType: flCode),
    (Code: 'DEL';      FType: flDeleted),
    (Code: 'RATE';     FType: flRate),
    (Code: 'URI';      FType: flURI),
    (Code: 'LIBRATE';  FType: flLibRate),
    (Code: 'KEYWORDS'; FType: flKeyWords),
    (Code: 'URL';      FType: flURI)
  );

  DEFAULTSTRUCTURE = 'AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG;LIBRATE;KEYWORDS';

{ TImportInpxThread }

function ExtractStrings(Content: PChar; const Separator: Char; Strings: TStrings): Integer;
var
  Head, Tail: PChar;
  EOS: Boolean;
  Item: string;
begin
  Result := 0;
  if (Content = nil) or (Content^ = #0) or (Strings = nil) then
    Exit;
  Tail := Content;

  Strings.BeginUpdate;
  try
    repeat
      Head := Tail;
      while not CharInSet(Tail^, [Separator, #0]) do
        Tail := StrNextChar(Tail);

      EOS := Tail^ = #0;
      if {(Head <> Tail) and} (Head^ <> #0) then
      begin
        SetString(Item, Head, Tail - Head);
        Strings.Add(Item);

        Inc(Result);
      end;
      Tail := StrNextChar(Tail);
    until EOS;
  finally
    Strings.EndUpdate;
  end;
end;

procedure TImportInpxThreadBase.ParseData(const input: string;
  const OnlineCollection: Boolean; var R: TBookRecord; Params: TStringList);
var
  i: Integer;
  AuthorList: string;
  strLastName: string;
  strFirstName: string;
  strMidName: string;
  GenreList: string;
  s: string;
  mm, dd, yy: word;
  pStart, pCur, pItemStart, pSub, pSubStart: PChar;

  Max: Integer;
begin
  R.Clear;
  Params.Clear;
  ExtractStrings(PChar(input), INPX_FIELD_DELIMITER, Params);

    // -- костыль
    if Params.Count <= High(FFields) then
      Max := Params.Count - 1
    else
      Max := High(FFields);
    // --

    for i := 0 to Max do
    begin
      case FFields[i] of
        flAuthor:
          begin // Список авторов
            AuthorList := Params[i];
            pStart := PChar(AuthorList);
            pCur := pStart;
            while pCur^ <> #0 do
            begin
              // Find the end of this author entry (delimited by INPX_ITEM_DELIMITER)
              pItemStart := pCur;
              while (pCur^ <> #0) and (pCur^ <> INPX_ITEM_DELIMITER) do
                Inc(pCur);

              if pCur > pItemStart then
              begin
                // Parse author sub-fields (LastName,FirstName,MiddleName)
                pSub := pItemStart;

                // LastName
                pSubStart := pSub;
                while (pSub < pCur) and (pSub^ <> INPX_SUBITEM_DELIMITER) do
                  Inc(pSub);
                SetString(strLastName, pSubStart, pSub - pSubStart);
                if (pSub < pCur) then Inc(pSub);

                // FirstName
                pSubStart := pSub;
                while (pSub < pCur) and (pSub^ <> INPX_SUBITEM_DELIMITER) do
                  Inc(pSub);
                SetString(strFirstName, pSubStart, pSub - pSubStart);
                if (pSub < pCur) then Inc(pSub);

                // MiddleName (rest until item delimiter)
                SetString(strMidName, pSub, pCur - pSub);

                TAuthorsHelper.Add(R.Authors, strLastName, strFirstName, strMidName);
              end;

              if pCur^ <> #0 then
                Inc(pCur); // skip delimiter
            end;
          end;

        flGenre:
          begin // Список жанров
            GenreList := Params[i];
            pStart := PChar(GenreList);
            pCur := pStart;
            while pCur^ <> #0 do
            begin
              pItemStart := pCur;
              while (pCur^ <> #0) and (pCur^ <> INPX_ITEM_DELIMITER) do
                Inc(pCur);

              if pCur > pItemStart then
              begin
                SetString(s, pItemStart, pCur - pItemStart);
                if FGenresType = gtFb2 then
                  TGenresHelper.Add(R.Genres, '', '', s)
                else
                  TGenresHelper.Add(R.Genres, s, '', '');
              end;

              if pCur^ <> #0 then
                Inc(pCur);
            end;
          end;

        flTitle:
          R.Title := Params[i]; // Название

        flSeries:
          R.Series := Params[i]; // Серия

        flSerNo:
          R.SeqNumber := StrToIntDef(Params[i], 0); // Номер внутри серии

        flFile:
          R.FileName := CheckSymbols(Trim(Params[i])); // Имя файла

        flExt:
          begin
            s := Trim(Params[i]);
            if (s <> '') and (s[1] <> '.') then
              Insert('.', s, 1);
            R.FileExt := s;
          end;

        flSize:
          R.Size := StrToIntDef(Params[i], 0); // Размер

        flLibID: R.LibID := Params[i]; // внутр. номер   ИСПОЛЬЗУЕТСЯ ВО ВСЕХ КОЛЛЕКЦИЯХ!

        flDeleted:
          begin
            if Params[i] = '1' then // удалена
              Include(R.BookProps, bpIsDeleted)
            else
              Exclude(R.BookProps, bpIsDeleted);
          end;

        flDate:
          begin // дата
            if Params[i] <> '' then
            begin
              yy := StrToInt(Copy(Params[i], 1, 4));
              mm := StrToInt(Copy(Params[i], 6, 2));
              dd := StrToInt(Copy(Params[i], 9, 2));
              R.Date := EncodeDate(yy, mm, dd);
            end
            else
              R.Date := EncodeDate(1970, 1, 1);
          end;

        flInsideNo:
          R.InsideNo := StrToIntDef(Params[i], 0); // номер в архиве

        flFolder:
          R.Folder := Params[i]; // папка

        flLibRate:
          R.LibRate := StrToIntDef(Params[i], 0); // внешний рейтинг

        flRate:
          R.Rate := StrToIntDef(Params[i], 0);

        flLang:
          R.Lang := Params[i]; // язык

        flKeyWords:
          R.KeyWords := Params[i]; // ключевые слова

        flURI:
          Assert(False, 'Not supported anymore');
          ///R.URI := slParams[i]; // ключевые слова
      end; // case, for
    end;

  R.Normalize;
end;

procedure TImportInpxThreadBase.GetFields(const StructureInfo: string);
var
  sl: TStringList;
  i: Integer;

  function FindType(const s: string): TFields;
  var
    F: TFieldDescr;
  begin
    for F in FieldsDescr do
      if SameText(F.Code, Trim(s)) then
      begin
        Result := F.FType;
        Exit;
      end;
    Result := flNone;
  end;

begin
  sl := TStringList.Create;
  try
    sl.Delimiter := ';';
    sl.StrictDelimiter := True;
    sl.DelimitedText := StructureInfo;

    SetLength(FFields, sl.Count);
    for i := 0 to sl.Count - 1 do
    begin
      FFields[i] := FindType(sl[i]);
      FUseStoredFolder := FUseStoredFolder or (FFields[i] = flFolder);
    end;
  finally
    sl.Free;
  end;
end;

procedure TImportInpxThreadBase.Import(const INPXFileName: string; CheckFiles: Boolean; BookCollection: IBookCollection);
type
  TInpEntry = record
    Name: string;
    Size: Integer;
  end;
var
  CollectionRoot: string;
  BookList: TStringList;
  i: Integer;
  j: Integer;
  R: TBookRecord;
  filesProcessed: Integer;
  CurrentFile: string;
  IsOnline: Boolean;
  inpStream: TMemoryStream;
  StructureInfo: string;
  header: TINPXHeader;
  strVersion: string;
  strCollection: string;
  Zip: TMHLZip;
  collectionCode: Integer;
  InpEntries: TArray<TInpEntry>;
  EntryCount: Integer;
  TotalBytes: Int64;
  BytesDone: Int64;
  Params: TStringList;
  Cache: TImportCache;

  function EntryBaseName(const EntryName: string): string;
  begin
    Result := ExtractFileName(StringReplace(EntryName, '/', '\', [rfReplaceAll]));
  end;

begin
  filesProcessed := 0;
  SetProgress(0);
  collectionCode := BookCollection.CollectionCode;

  IsOnline := isOnlineCollection(collectionCode);
  CollectionRoot := BookCollection.GetProperty(PROP_ROOTFOLDER);

  SetLength(FFields, 0);
  FUseStoredFolder := False;
  Zip := nil;
  inpStream := nil;
  Params := nil;
  Cache := nil;

  BookCollection.StartBatchUpdate;
  try
    Params := TStringList.Create;
    Cache := TImportCache.Create;
    Zip := TMHLZip.Create(INPXFileName, True);
    if Zip.Find(STRUCTUREINFO_FILENAME) then
      StructureInfo := Zip.ExtractToString(STRUCTUREINFO_FILENAME)
    else
      StructureInfo := DEFAULTSTRUCTURE;

    GetFields(StructureInfo);

    //
    // Предыдущий проход: собираем .inp-члены архива и их распакованные
    // размеры. Размер находится в центральном каталоге zip, чтение ничего не
    // стоит, а учитывать прогресс байтами точнее, чем количеством членов: строки
    // .inp почти одинаковой длины, а сами члены очень разные по объему.
    //
    // Заодно это устраняет старый недостаток обхода: TMHLZip.FindNext не проверяет
    // расширение, поэтому старый цикл, пропустив последний .inp, передавал
    // в ParseData файлы version.info и collection.info и засорял журнал ошибок.
    //
    SetLength(InpEntries, Zip.FileCount);
    EntryCount := 0;
    TotalBytes := 0;
    for i := 0 to Zip.FileCount - 1 do
    begin
      CurrentFile := Zip.FileNames[i];
      if not SameText(ExtractFileExt(CurrentFile), INP_EXTENSION) then
        Continue;
      if not IsOnline and SameText(EntryBaseName(CurrentFile), EXTRA_INP_FILENAME) then
        Continue;

      InpEntries[EntryCount].Name := CurrentFile;
      InpEntries[EntryCount].Size := Zip.FileSizes[i];
      Inc(TotalBytes, InpEntries[EntryCount].Size);
      Inc(EntryCount);
    end;
    SetLength(InpEntries, EntryCount);

    //
    // TWorker.OpenProgress открывает операцию с Total = 0, и TProgressEngine
    // устанавливает стиль бегущей строки pbstMarquee. Пока стиль marquee, Position не виден -
    // именно из-за этого диалог обновления показывал бесконечную «бегущую дорожку»
    // вместо прогресса.
    //
    if TotalBytes > 0 then
      SetProgressHint(pbstNormal, pbsNormal);

    BytesDone := 0;
    for i := 0 to High(InpEntries) do
    begin
      CurrentFile := InpEntries[i].Name;

      Teletype(Format(rstrProcessingFile, [CurrentFile]), tsInfo);

      BookList := TStringList.Create;
      try
        try
          inpStream := TMemoryStream.Create;
          Zip.ExtractToStream(CurrentFile, inpStream);
          inpStream.Seek(0, soBeginning);
          BookList.LoadFromStream(inpStream, TEncoding.UTF8);
        finally
          FreeAndNil(inpStream);
        end;

        for j := 0 to BookList.Count - 1 do
        begin
          try
            ParseData(BookList[j], IsOnline, R, Params);
            if IsOnline then
            begin

              if 0 = (CONTENT_NONFB and collectionCode) then
                R.Folder := R.GenerateLocation + FB2ZIP_EXTENSION;  // И\Иванов Иван\1234 Просто книга.fb2.zip
              // Сохраним отметку о существовании файла
              if FileExists(TPath.Combine(CollectionRoot, R.Folder)) then
                Include(R.BookProps, bpIsLocal)
              else
                Exclude(R.BookProps, bpIsLocal);
            end
            else
            begin
              Include(R.BookProps, bpIsLocal);
              if not FUseStoredFolder then
              begin
                // 98058-98693.inp -> 98058-98693.zip
                R.Folder := ChangeFileExt(CurrentFile, ZIP_EXTENSION);
                //
                R.InsideNo := j;
              end
            end;

            try
              if BookCollection.InsertBook(R, CheckFiles, False, Cache) <> 0 then
                Inc(filesProcessed);
            except
              on E: Exception do
                raise EDBError.Create(E.Message);
            end;

          except
            on E: EConvertError do
              Teletype(Format(rstrErrorInpStructure, [CurrentFile, j + 1]), tsError);
            on E: EDBError do
            begin
              Teletype(Format(rstrDBErrorInp, [CurrentFile, j + 1]), tsError);
              // A malformed source row can be skipped, but a database failure
              // means the transaction itself is no longer trustworthy.
              raise;
            end;
            on E: Exception do
            begin
              Teletype(E.Message, tsError);
              raise;
            end;
          end;

          //
          // Продвигаем полосу на каждой разобранной строке, а не на каждой сотой
          // *вставленной* книге: инкрементальное обновление, где почти всё уже есть
          // в коллекции, иначе стоит на месте. SetProgress сам отсекает вызовы
          // Synchronize, пока целое число процентов не изменилось.
          //
          if TotalBytes > 0 then
            SetProgress(Integer(
              (BytesDone + Round(InpEntries[i].Size * ((j + 1) / BookList.Count))) * 100 div TotalBytes));

          if (j mod ProcessedItemThreshold) = 0 then
          begin
            SetComment(Format(rstrAddedBooks, [filesProcessed]));

            if Canceled then
              Break;
          end;
        end;
      finally
        FreeAndNil(BookList);
      end;

      Inc(BytesDone, InpEntries[i].Size);
      if Canceled then
        Break;
    end;

    if Canceled then
      Exit;

    Teletype(Format(rstrAddedBooks, [filesProcessed]), tsInfo);
    FProgressEngine.BeginOperation(-1, rstrUpdatingDB, '');
    try
      // Read archive metadata only when this import is allowed to replace the
      // current collection connection settings.
      if not FKeepCollectionProps and Zip.Find(COLLECTIONINFO_FILENAME) then
      begin
        strCollection := Zip.ExtractToString(Zip.LastName);
        header.ParseString(strCollection);
        BookCollection.SetProperty(PROP_NOTES, header.Notes);
        BookCollection.SetProperty(PROP_URL, header.URL);
        BookCollection.SetProperty(PROP_CONNECTIONSCRIPT, header.Script);
      end;

      if Zip.Find(VERINFO_FILENAME) then
      begin
        strVersion := Trim(Zip.ExtractToString(Zip.LastName));
        BookCollection.SetProperty(PROP_DATAVERSION,
          StrToIntDef(strVersion, UNVERSIONED_COLLECTION));
      end;

      BookCollection.AfterBatchUpdate;
    finally
      FProgressEngine.EndOperation;
    end;
  finally
    FreeAndNil(Zip);
    FreeAndNil(inpStream);
    FreeAndNil(Cache);
    FreeAndNil(Params);
    BookCollection.FinishBatchUpdate;
  end;
end;

constructor TImportInpxThread.Create(const CollectionID: Integer; const INPXFileName: string; GenresType: TGenresType);
begin
  inherited Create(CollectionID);
  FInpxFileName := INPXFileName;
  FGenresType := GenresType;
end;

procedure TImportInpxThread.WorkFunction;
begin
  Assert(Assigned(FCollection));

  FCollection.BeginBulkOperation;
  try
    Import(FInpxFileName, False, FCollection);
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
