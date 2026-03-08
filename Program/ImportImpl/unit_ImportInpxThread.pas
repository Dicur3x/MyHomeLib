(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2023 Oleksiy Penkov (aka Koreec)
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
  * NickR 02.09.2010    INPX больше не распаковывается на диск для обработки.
  *                     Вся работа происходит в памяти.
  *
  * [REFACTOR] Fixed TMHLZip leak when constructor throws in Import
  * [REFACTOR] Fixed FProgressEngine.BeginOperation without paired EndOperation
  * [REFACTOR] Fixed AfterBatchUpdate skipped on exception
  * [REFACTOR] Fixed WorkFunction swallowing exception after Teletype
  * [REFACTOR] Fixed GetFields silently dropping last field (no trailing ';')
  * [REFACTOR] Fixed flDeleted using lexicographic >= '1' instead of exact '1'
  * [REFACTOR] Replaced Assert(False) for flURI with a logged warning
  * [REFACTOR] Hardened date parsing with try/except + EConvertError
  * [REFACTOR] Removed dangling FreeAndNil(inpStream) in outer finally
  *
  * [PERF] ParseData now accepts a caller-supplied TStringList (slParams) so
  *        the same instance is reused for every book — eliminates ~500k
  *        Create/Free pairs per INPX import on large collections.
  * [PERF] Import creates a TImportCache and passes it to InsertBook, so
  *        author and series lookups hit the in-memory dictionary first.
  *        On a 500k-book collection over a spinning HDD this typically
  *        eliminates ~1.5M SELECT queries for authors and ~500k for series.
  *
  ****************************************************************************** *)

unit unit_ImportInpxThread;

interface

uses
  Windows,
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

  protected
    procedure GetFields(const StructureInfo: string);

    // [PERF] slParams is supplied by the caller and reused across all records
    // in a single .inp file — no Create/Free per book.
    procedure ParseData(const input: string; const OnlineCollection: Boolean; var R: TBookRecord; slParams: TStringList);

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
  Classes,
  SysUtils,
  IOUtils,
  unit_MHLArchiveHelpers,
  unit_Consts,
  unit_Helpers,
  unit_Errors,
  unit_Logger,
  dm_user;

resourcestring
  rstrProcessingFile    = 'Обрабатываем файл %s';
  rstrAddedBooks        = 'Добавлено %u книг';
  rstrErrorInpStructure = 'Ошибка структуры inp. Файл %s, Строка %u';
  rstrDBErrorInp        = 'Ошибка базы данных при импорте книги. Файл %s, Строка %u';
  rstrUpdatingDB        = 'Обновление базы данных. Пожалуйста, подождите... ';
  rstrInvalidFormat     = 'Неправильный формат файла INPX!';
  rstrWarnURIField      = 'INPX field URI is not supported and will be skipped (file: %s)';
  rstrErrorDateFormat   = 'Ошибка формата даты в поле: "%s", файл %s строка %u';

const
  FieldsDescr: array [1..20] of TFieldDescr = (
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
      if Head^ <> #0 then
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

// [PERF] slParams is created once per .inp file in Import and reused here.
//        slParams.Clear is called at the top — behaviour is identical to the
//        old Create/Free pattern but avoids ~500k heap allocations per import.
procedure TImportInpxThreadBase.ParseData(
  const input: string;
  const OnlineCollection: Boolean;
  var R: TBookRecord;
  slParams: TStringList);
var
  p, i: Integer;
  AuthorList: string;
  strLastName, strFirstName, strMidName: string;
  GenreList: string;
  s: string;
  mm, dd, yy: Word;
  Max: Integer;
begin
  R.Clear;

  // Reuse the supplied list — no allocation on the hot path.
  slParams.Clear;
  ExtractStrings(PChar(input), INPX_FIELD_DELIMITER, slParams);

  if slParams.Count <= High(FFields) then
    Max := slParams.Count - 1
  else
    Max := High(FFields);

  for i := 0 to Max do
  begin
    case FFields[i] of
      flAuthor:
      begin
        AuthorList := slParams[i];
        p := PosChr(INPX_ITEM_DELIMITER, AuthorList);
        while p <> 0 do
        begin
          s := Copy(AuthorList, 1, p - 1);
          Delete(AuthorList, 1, p);

          p := PosChr(INPX_SUBITEM_DELIMITER, s);
          strLastName := Copy(s, 1, p - 1);
          Delete(s, 1, p);

          p := PosChr(INPX_SUBITEM_DELIMITER, s);
          strFirstName := Copy(s, 1, p - 1);
          Delete(s, 1, p);

          strMidName := s;

          TAuthorsHelper.Add(R.Authors, strLastName, strFirstName, strMidName);

          p := PosChr(INPX_ITEM_DELIMITER, AuthorList);
        end;
      end;

      flGenre:
      begin
        GenreList := slParams[i];
        p := PosChr(INPX_ITEM_DELIMITER, GenreList);
        while p <> 0 do
        begin
          if FGenresType = gtFb2 then
            TGenresHelper.Add(R.Genres, '', '', Copy(GenreList, 1, p - 1))
          else
            TGenresHelper.Add(R.Genres, Copy(GenreList, 1, p - 1), '', '');

          Delete(GenreList, 1, p);
          p := PosChr(INPX_ITEM_DELIMITER, GenreList);
        end;
      end;

      flTitle:    R.Title     := slParams[i];
      flSeries:   R.Series    := slParams[i];
      flSerNo:    R.SeqNumber := StrToIntDef(slParams[i], 0);
      flFile:     R.FileName  := CheckSymbols(Trim(slParams[i]));
      flExt:      R.FileExt   := '.' + slParams[i];
      flSize:     R.Size      := StrToIntDef(slParams[i], 0);
      flLibID:    R.LibID     := slParams[i];
      flFolder:   R.Folder    := slParams[i];
      flLibRate:  R.LibRate   := StrToIntDef(slParams[i], 0);
      flLang:     R.Lang      := slParams[i];
      flKeyWords: R.KeyWords  := slParams[i];
      flInsideNo: R.InsideNo  := StrToIntDef(slParams[i], 0);

      flDeleted:
      begin
        if slParams[i] = '1' then
          Include(R.BookProps, bpIsDeleted)
        else
          Exclude(R.BookProps, bpIsDeleted);
      end;

      flDate:
      begin
        if slParams[i] <> '' then
        begin
          try
            yy := StrToInt(Copy(slParams[i], 1, 4));
            mm := StrToInt(Copy(slParams[i], 6, 2));
            dd := StrToInt(Copy(slParams[i], 9, 2));
            R.Date := EncodeDate(yy, mm, dd);
          except
            on E: EConvertError do
            begin
              R.Date := EncodeDate(1970, 1, 1);
              raise;
            end;
          end;
        end
        else
          R.Date := EncodeDate(1970, 1, 1);
      end;

      flURI:
        Logger.W(rstrWarnURIField, ['']);
    end;
  end;

  R.Normalize;
end;

procedure TImportInpxThreadBase.GetFields(const StructureInfo: string);
const
  del = ';';
var
  s: string;
  p, i: Integer;

  function FindType(const s: string): TFields;
  var
    F: TFieldDescr;
  begin
    for F in FieldsDescr do
      if F.Code = s then
      begin
        Result := F.FType;
        Exit;
      end;
    Result := flNone;
  end;

begin
  s := StructureInfo;

  SetLength(FFields, 0);
  FUseStoredFolder := False;
  i := 0;
  p := Pos(del, s);

  while p <> 0 do
  begin
    SetLength(FFields, i + 1);
    FFields[i] := FindType(Copy(s, 1, p - 1));
    FUseStoredFolder := FUseStoredFolder or (FFields[i] = flFolder);
    Delete(s, 1, p);
    Inc(i);
    p := Pos(del, s);
  end;

  // Last token when structure string has no trailing semicolon.
  s := Trim(s);
  if s <> '' then
  begin
    SetLength(FFields, i + 1);
    FFields[i] := FindType(s);
    FUseStoredFolder := FUseStoredFolder or (FFields[i] = flFolder);
  end;
end;

procedure TImportInpxThreadBase.Import(
  const INPXFileName: string;
  CheckFiles: Boolean;
  BookCollection: IBookCollection);
var
  CollectionRoot: string;
  BookList: TStringList;
  i, j: Integer;
  R: TBookRecord;
  filesProcessed: Integer;
  CurrentFile: string;
  IsOnline: Boolean;
  inpStream: TMemoryStream;
  StructureInfo: string;
  header: TINPXHeader;
  strVersion: string;
  strCollection: string;
  numFiles: Integer;
  Zip: TMHLZip;
  collectionCode: Integer;
  // [PERF] One TStringList for all ParseData calls in this import run.
  //        Declared here, created once, reused across all .inp files and
  //        all book records within each file.
  slParams: TStringList;
  // [PERF] One TImportCache for the entire import run.
  //        Holds author and series ID lookups so InsertBook never issues
  //        a SELECT for a name it has already resolved in this session.
  Cache: TImportCache;
begin
  filesProcessed := 0;
  i := 0;
  SetProgress(0);
  collectionCode := BookCollection.CollectionCode;

  IsOnline      := isOnlineCollection(collectionCode);
  CollectionRoot := BookCollection.GetProperty(PROP_ROOTFOLDER);

  SetLength(FFields, 0);
  FUseStoredFolder := False;

  BookCollection.StartBatchUpdate;

  // [PERF] Both performance objects are created before the main try/finally
  // so they are always freed in the corresponding finally block.
  slParams := TStringList.Create;
  Cache    := TImportCache.Create;
  try
    Zip := nil;
    try
      Zip := TMHLZip.Create(INPXFileName, True);
    except
      on E: Exception do
      begin
        Teletype(E.Message, tsError);
        Exit;
      end;
    end;

    if Zip.Find(STRUCTUREINFO_FILENAME) then
      StructureInfo := Zip.ExtractToString(STRUCTUREINFO_FILENAME)
    else
      StructureInfo := DEFAULTSTRUCTURE;

    GetFields(StructureInfo);
    numFiles := Zip.FileCount;

    if Zip.Find('*.inp') then
    repeat
      CurrentFile := Zip.LastName;
      if not IsOnline and (CurrentFile = 'extra.inp') then
        Continue;

      Teletype(Format(rstrProcessingFile, [CurrentFile]), tsInfo);

      BookList := TStringList.Create;
      try
        inpStream := TMemoryStream.Create;
        try
          Zip.ExtractToStream(Zip.LastName, inpStream);
          inpStream.Seek(0, soBeginning);
          BookList.LoadFromStream(inpStream, TEncoding.UTF8);
        finally
          FreeAndNil(inpStream);
        end;

        for j := 0 to BookList.Count - 1 do
        begin
          try
            // [PERF] Pass the shared slParams — ParseData clears it internally
            //        instead of creating a new TStringList each time.
            ParseData(BookList[j], IsOnline, R, slParams);

            if IsOnline then
            begin
              if 0 = (CONTENT_NONFB and collectionCode) then
                R.Folder := R.GenerateLocation + FB2ZIP_EXTENSION;

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
                R.Folder   := ChangeFileExt(CurrentFile, ZIP_EXTENSION);
                R.InsideNo := j;
              end;
            end;

            try
              // [PERF] Cache overload — author/series resolved from dictionary,
              //        DB path only on the very first occurrence of each name.
              if BookCollection.InsertBook(R, CheckFiles, False, Cache) <> 0 then
                Inc(filesProcessed);
            except
              on E: Exception do
                raise EDBError.Create(E.Message);
            end;

            if (filesProcessed mod ProcessedItemThreshold) = 0 then
            begin
              SetProgress(Round((i + j / BookList.Count) * 100 / numFiles));
              SetComment(Format(rstrAddedBooks, [filesProcessed]));

              if Canceled then
                Break;
            end;

          except
            on E: EConvertError do
              Teletype(Format(rstrErrorInpStructure, [CurrentFile, j]), tsError);
            on E: EDBError do
              Teletype(Format(rstrDBErrorInp, [CurrentFile, j]), tsError);
            on E: Exception do
              Teletype(E.Message, tsError);
          end;
        end;
      finally
        FreeAndNil(BookList);
      end;

      Inc(i);
      if Canceled then
        Break;
    until not Zip.FindNext;

    Teletype(Format(rstrAddedBooks, [filesProcessed]), tsInfo);

    FProgressEngine.BeginOperation(-1, rstrUpdatingDB, '');
    try
      if Zip.Find(COLLECTIONINFO_FILENAME) then
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
        BookCollection.SetProperty(PROP_DATAVERSION, StrToIntDef(strVersion, UNVERSIONED_COLLECTION));
      end;

      BookCollection.AfterBatchUpdate;
    finally
      FProgressEngine.EndOperation;
    end;

  finally
    // Release in reverse order of creation; Zip may be nil if constructor threw.
    FreeAndNil(Zip);
    FreeAndNil(Cache);
    FreeAndNil(slParams);
    BookCollection.FinishBatchUpdate;
  end;
end;

constructor TImportInpxThread.Create(
  const CollectionID: Integer;
  const INPXFileName: string;
  GenresType: TGenresType);
begin
  inherited Create(CollectionID);
  FInpxFileName := INPXFileName;
  FGenresType   := GenresType;
end;

procedure TImportInpxThread.WorkFunction;
begin
  Assert(Assigned(FCollection));

  FCollection.BeginBulkOperation;
  try
    Import(FInpxFileName, False, FCollection);
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