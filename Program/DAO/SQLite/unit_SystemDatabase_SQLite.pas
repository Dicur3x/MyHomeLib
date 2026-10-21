
(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           eg
  * Created             04.09.2010
  * Description
  *
  * $Id: unit_SystemDatabase_SQLite.pas 1131 2013-12-04 10:12:58Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_SystemDatabase_SQLite;

interface

uses
  Windows,
  SysUtils,
  Generics.Collections,
  unit_SystemDatabase_Abstract,
  SQLiteWrap,
  unit_UserData,
  unit_Interfaces,
  unit_CollectionBackup,
  unit_Globals,
  unit_Consts;

type
  TSystemData_SQLite = class(TSystemData, ISystemData, ISystemBookPresence, IBookIdentityProgressWriter, IBookIdentityPersonalWriter, IMetadataCollectionRootGuard, IAtomicLegacyUserDataImporter, ISnapshotCollectionRestorer)
  strict private
  type
    TBookIteratorImpl = class(TInterfacedObject, IBookIterator)
    public
      constructor Create(User: TSystemData_SQLite; const GroupID: Integer; const DatabaseID: Integer);
      destructor Destroy; override;

    protected
      function Next(out BookRecord: TBookRecord): Boolean;
      function RecordCount: Integer;

    private
      FUser: TSystemData_SQLite;
      FBooks: TSQLiteQuery;
      FCount: TSQLiteQuery;
      FBatch: TArray<TBookRecord>;
      FBatchIndex: Integer;

      procedure PrepareData(const GroupID: Integer; const DatabaseID: Integer);
      procedure LoadBatch;
    end;

    TGroupIteratorImpl = class(TInterfacedObject, IGroupIterator)
    public
      constructor Create(User: TSystemData_SQLite);
      destructor Destroy; override;

    protected
      function Next(out Group: TGroupData): Boolean;
      function RecordCount: Integer;

    private
      FUser: TSystemData_SQLite;
      FGroups: TSQLiteQuery;
      FCount: TSQLiteQuery;

      procedure PrepareData;
    end;

    TCollectionInfoIteratorImpl = class(TInterfacedObject, ICollectionInfoIterator)
    public
      constructor Create(User: TSystemData_SQLite);
      destructor Destroy; override;

    protected
      function Next(out CollectionInfo: TCollectionInfo): Boolean;
      function RecordCount: Integer;

    private
      FUser: TSystemData_SQLite;
      FBases: TSQLiteQuery;
      FCount: TSQLiteQuery;

      procedure PrepareData;
    end;

  protected
    FMetadataRootGuard: Boolean;
    function InternalCreateCollection(const CollectionID: Integer): IBookCollection; override;
    procedure PrepareCollectionPath(var CollectionRoot: string; var CollectionFile: string);

  public
    class procedure CreateSystemTables(const DBUserFile: string);

  public
    constructor Create(const DBUserFile: string);
    destructor Destroy; override;

  protected
    function CreateCollection(
      const DisplayName: string;
      const RootFolder: string;
      const DBFileName: string;
      CollectionType: COLLECTION_TYPE;
      const GenresFileName: string
    ): Integer;

    function RegisterCollection(
      const DBFileName: string;
      const DisplayName: string;
      const RootFolder: string
    ): Integer;

    procedure DeleteCollection(const CollectionID: Integer; const RemoveFromDisk: Boolean = True);

    function HasCollectionWithProp(PropID: TPropertyID; const Value: string; IgnoreID: Integer = INVALID_COLLECTION_ID): Boolean;

    procedure SetProperty(const CollectionID: Integer; const PropID: TPropertyID; const Value: Variant);
    function GetProperty(const CollectionID: Integer; const PropID: TPropertyID): Variant;

    function GetCollectionInfo(const CollectionID: Integer): TCollectionInfo;


    function ActivateGroup(const ID: Integer): Boolean;

    procedure GetBookRecord(const BookKey: TBookKey; var BookRecord: TBookRecord);
    procedure DeleteBook(const BookKey: TBookKey);
    procedure UpdateBook(const BookRecord: TBookRecord);

    procedure SetExtra(const BookKey: TBookKey; extra: TBookExtra);
    procedure SetRate(const BookKey: TBookKey; Rate: Integer);
    procedure SetProgress(const BookKey: TBookKey; Progress: Integer);
    function TrySetIdentityProgress(const Expected: TBookRecord; Progress: Integer;
      const Matches: TBookIdentityPredicate): Boolean;
    function TrySetIdentityPersonal(const Expected: TBookRecord;
      const Fields: TBookPersonalFields; const Matches: TBookIdentityPredicate;
      RequirePersonal: Boolean = False): TBookIdentityWriteResult;
    function GetReview(const BookKey: TBookKey): string;
    function SetReview(const BookKey: TBookKey; const Review: string): Integer;
    function GetAnnotation(const BookKey: TBookKey): string;
    procedure SetAnnotation(const BookKey: TBookKey; const Annotation: string);
    procedure SetLocal(const BookKey: TBookKey; Value: Boolean);
    procedure SetFileName(const BookKey: TBookKey; const FileName: string);
    procedure SetBookSeriesID(const BookKey: TBookKey; const SeriesID: Integer);
    procedure SetFolder(const BookKey: TBookKey; const Folder: string);

    function AddGroup(const GroupName: string; const AllowDelete: Boolean = True): Boolean;
    function GetGroup(const GroupID: Integer): TGroupData;
    function RenameGroup(GroupID: Integer; const NewName: string): Boolean;
    procedure ClearGroup(GroupID: Integer);
    procedure DeleteGroup(GroupID: Integer);

    procedure AddBookToGroup(const BookKey: TBookKey; GroupID: Integer; const BookRecord: TBookRecord);
    procedure CopyBookToGroup(const BookKey: TBookKey; SourceGroupID: Integer; TargetGroupID: Integer; MoveBook: Boolean);
    procedure DeleteFromGroup(const BookKey: TBookKey; GroupID: Integer);
    procedure CleanCollectionBooks(const DatabaseID: Integer);
    function RemapCollectionBookIDs(const DatabaseID: Integer; const RemoveMissing: Boolean = False): Integer;

    function StoredBookIDs(const CollectionID: Integer): TArray<Integer>;
    function GetDataRevision: string;
    procedure BeginMetadataRootGuard;
    procedure EndMetadataRootGuard;
    procedure BeginDataUpdate;
    procedure EndDataUpdate(Commit: Boolean);
    function RegisterSnapshotCollection(const CatalogFile, DisplayName, Root, SourceRoot: string;
      Source: TSQLiteDatabase; SourceID: Integer;
      const Canceled: TSnapshotCanceled): Integer;
    procedure ImportUserData(data: TUserData);
    procedure ImportLegacyUserData(CollectionID: Integer; Data: TUserData;
      const Notify: TGUIUpdateExtraProc);

    procedure ChangeBookSeriesID(const OldSeriesID: Integer; const NewSeriesID: Integer; const DatabaseID: Integer);

    function GetBookIterator(const GroupID: Integer; const DatabaseID: Integer = INVALID_COLLECTION_ID): IBookIterator; override;
    function GetGroupIterator: IGroupIterator; override;
    function GetCollectionInfoIterator: ICollectionInfoIterator; override;

    procedure RemoveUnusedBooks;

  private
    FDatabase: TSQLiteDatabase;

    procedure InternalClearGroup(GroupID: Integer; RemoveGroup: Boolean);
    function InternalFindGroup(GroupID: Integer): Boolean; inline;
  end;

implementation

uses
  Classes,
  Variants,
  IOUtils,
  SQLite3,
  unit_Logger,
  unit_SQLiteUtils,
  unit_Database_SQLite,
  dm_user,
  unit_Helpers,
  unit_Errors;

resourcestring
  rstrInvalidCollection = 'Файл %s не является коллекцией.';
  rstrFailedToMountDB = 'Ошибка загрузки файла коллекции %s';

class procedure TSystemData_SQLite.CreateSystemTables(const DBUserFile: string);
var
  ADatabase: TSQLiteDatabase;
  StringList: TStringList;
  StructureDDL: string;
  SystemData: ISystemData;
begin
  ADatabase := TSQLiteDatabase.Create(DBUserFile);
  try
    StringList := ReadResourceAsStringList('CreateSystemDB_SQLite');
    try
      ADatabase.Start;
      try
        for StructureDDL in StringList do
        begin
          if Trim(StructureDDL) <> '' then
            ADatabase.ExecSQL(StructureDDL);
        end;
        ADatabase.Commit;
      except
        try ADatabase.Rollback; except end; // preserve the original exception
        raise;
      end;
    finally
      FreeAndNil(StringList);
    end;
  finally
    FreeAndNil(ADatabase);
  end;

  SystemData := TSystemData_SQLite.Create(DBUserFile);
  SystemData.AddGroup(rstrFavoritesGroupName, False);
  SystemData.AddGroup(rstrToReadGroupName, False);
end;


constructor TSystemData_SQLite.TBookIteratorImpl.Create(User: TSystemData_SQLite; const GroupID: Integer; const DatabaseID: Integer);
begin
  inherited Create;

  Assert(Assigned(User));

  FUser := User;

  PrepareData(GroupID, DatabaseID);
end;

destructor TSystemData_SQLite.TBookIteratorImpl.Destroy;
begin
  FBatch:=nil;
  FreeAndNil(FBooks);
  FreeAndNil(FCount);

  inherited Destroy;
end;

function TSystemData_SQLite.TBookIteratorImpl.Next(out BookRecord: TBookRecord): Boolean;
begin
  if FBatchIndex>=Length(FBatch) then LoadBatch;
  Result:=FBatchIndex<Length(FBatch);
  if Result then
  begin
    BookRecord:=FBatch[FBatchIndex]; Inc(FBatchIndex);
  end;
end;

procedure TSystemData_SQLite.TBookIteratorImpl.LoadBatch;
const BatchSize=128;
var IDs: TObjectDictionary<Integer,TList<Integer>>; Pair: TPair<Integer,TList<Integer>>;
  List: TList<Integer>; Count, I: Integer; Collection: IBookCollection;
  Iterator: IBookIterator; Criteria: TBookSearchCriteria; Current: TBookRecord; Info: TCollectionInfo;
begin
  FBatch:=nil; FBatchIndex:=0; SetLength(FBatch,BatchSize); Count:=0;
  IDs:=TObjectDictionary<Integer,TList<Integer>>.Create([doOwnsValues]);
  try
    // Preserve the personal iterator's count/order and bound both memory and
    // catalog work. No catalog query is added for each individual saved card.
    while (Count<BatchSize) and not FBooks.Eof do
    begin
      FBatch[Count].Clear;
      FUser.GetBookRecord(CreateBookKey(FBooks.FieldAsInt(0),FBooks.FieldAsInt(1)),FBatch[Count]);
      if (FBatch[Count].BookKey.BookID>0) and (FBatch[Count].LibID<>'') and
        (FBatch[Count].LibID<>'0') then
      begin
        if not IDs.TryGetValue(FBatch[Count].BookKey.DatabaseID,List) then
        begin List:=TList<Integer>.Create; IDs.Add(FBatch[Count].BookKey.DatabaseID,List); end;
        List.Add(FBatch[Count].BookKey.BookID);
      end;
      Inc(Count); FBooks.Next;
    end;
    SetLength(FBatch,Count);
    for Pair in IDs do
    begin
      Collection:=nil; Iterator:=nil;
      try
        Info:=FUser.GetCollectionInfo(Pair.Key);
        if not FileExists(Info.DBFileName) then Continue;
        Collection:=(FUser as ISystemData).GetCollection(Pair.Key,False);
        Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1;
        Criteria.RestrictBookIDs:=True; Criteria.BookIDs:=Pair.Value.ToArray;
        Criteria.CollapseMultiSeriesResults:=True;
        Iterator:=Collection.Search(Criteria,False);
        while Iterator.Next(Current) do
          for I:=0 to High(FBatch) do
            if (FBatch[I].BookKey.DatabaseID=Pair.Key) and
              (FBatch[I].BookKey.BookID=Current.BookKey.BookID) and
              (FBatch[I].LibID<>'') and (FBatch[I].LibID=Current.LibID) then
            begin
              // Only current publication metadata is projected. Saved personal
              // annotation/review/rating/progress and physical identity remain
              // exactly the historical card, including missing/replaced books.
              FBatch[I].Publisher:=Current.Publisher; FBatch[I].Translators:=Current.Translators;
              FBatch[I].City:=Current.City; FBatch[I].PubYear:=Current.PubYear; FBatch[I].ISBN:=Current.ISBN;
            end;
      except
        on E: EAbort do raise;
        on E: EOutOfMemory do raise;
        // An unavailable catalog must not prevent reading its saved cards.
        on E: Exception do begin end;
      end;
      Iterator:=nil; Collection:=nil;
    end;
  finally IDs.Free; end;
end;

function TSystemData_SQLite.TBookIteratorImpl.RecordCount: Integer;
begin
  Assert(Assigned(FCount), 'Calling RecordCount more than once!');

  FCount.Open;
  Result := FCount.FieldAsInt(0);
  FreeAndNil(FCount);
end;

procedure TSystemData_SQLite.TBookIteratorImpl.PrepareData(const GroupID: Integer; const DatabaseID: Integer);
const
  SQL_DATABASES = 'SELECT DISTINCT DatabaseID FROM BookGroups WHERE GroupID = ? ';
var
  sqlCount: string;
  sqlRows: string;
  dbIDs: TList<Integer>;
  query: TSQLiteQuery;
  i: Integer;
begin
  // Перед построением списка приводим BookID к текущей нумерации коллекции:
  // после полного переимпорта сохранённые в группе BookID указывают на чужие книги.
  dbIDs := TList<Integer>.Create;
  try
    if DatabaseID <> INVALID_COLLECTION_ID then
      dbIDs.Add(DatabaseID)
    else
    begin
      query := FUser.FDatabase.NewQuery(SQL_DATABASES);
      try
        query.SetParam(0, GroupID);
        query.Open;
        while not query.Eof do
        begin
          dbIDs.Add(query.FieldAsInt(0));
          query.Next;
        end;
      finally
        FreeAndNil(query);
      end;
    end;

    for i := 0 to dbIDs.Count - 1 do
      FUser.RemapCollectionBookIDs(dbIDs[i]);
  finally
    FreeAndNil(dbIDs);
  end;

  sqlCount := 'SELECT COUNT(*) FROM BookGroups bg INNER JOIN Books b ON bg.BookID = b.BookID AND bg.DatabaseID = b.DatabaseID ' +
    ' WHERE bg.GroupID = ? ';
  sqlRows := 'SELECT b.BookID, b.DatabaseID FROM BookGroups bg INNER JOIN Books b ON bg.BookID = b.BookID AND bg.DatabaseID = b.DatabaseID ' +
    ' WHERE bg.GroupID = ? ';
  if (DatabaseID <> INVALID_COLLECTION_ID) then
  begin
    sqlCount := sqlCount + ' AND bg.DatabaseID = ? ';
    sqlRows := sqlRows + ' AND bg.DatabaseID = ? ';
  end;

  if Settings.HideDeletedBooks then
  begin
    // Apply the same predicate to count and rows; membership is preserved.
    sqlCount := sqlCount + ' AND b.IsDeleted = 0 ';
    sqlRows := sqlRows + ' AND b.IsDeleted = 0 ';
  end;

  FCount := FUser.FDatabase.NewQuery(sqlCount);
  FCount.SetParam(0, GroupID);
  if (DatabaseID <> INVALID_COLLECTION_ID) then
    FCount.SetParam(1, DatabaseID);

  FBooks := FUser.FDatabase.NewQuery(sqlRows);
  FBooks.SetParam(0, GroupID);
  if (DatabaseID <> INVALID_COLLECTION_ID) then
    FBooks.SetParam(1, DatabaseID);
  FBooks.Open;
end;


constructor TSystemData_SQLite.TGroupIteratorImpl.Create(User: TSystemData_SQLite);
begin
  inherited Create;

  Assert(Assigned(User));

  FUser := User;

  PrepareData;
end;

destructor TSystemData_SQLite.TGroupIteratorImpl.Destroy;
begin
  FreeAndNil(FGroups);
  FreeAndNil(FCount);

  inherited Destroy;
end;

function TSystemData_SQLite.TGroupIteratorImpl.Next(out Group: TGroupData): Boolean;
begin
  Result := not FGroups.Eof;

  if Result then
  begin
    Group.GroupID := FGroups.FieldAsInt(0);
    Group.Text := FGroups.FieldAsString(1);
    Group.CanDelete := FGroups.FieldAsBoolean(2);
    FGroups.Next;
  end;
end;

function TSystemData_SQLite.TGroupIteratorImpl.RecordCount: Integer;
begin
  Assert(Assigned(FCount), 'Calling RecordCount more than once!');

  FCount.Open;
  Result := FCount.FieldAsInt(0);
  FreeAndNil(FCount);
end;

procedure TSystemData_SQLite.TGroupIteratorImpl.PrepareData;
const
  SQL_COUNT = 'SELECT COUNT(*) FROM Groups ';
  SQL_ROWS = 'SELECT g.GroupID, g.GroupName, g.AllowDelete FROM Groups g ';
begin
  FCount := FUser.FDatabase.NewQuery(SQL_COUNT);

  FGroups := FUser.FDatabase.NewQuery(SQL_ROWS);
  FGroups.Open;
end;


constructor TSystemData_SQLite.TCollectionInfoIteratorImpl.Create(User: TSystemData_SQLite);
begin
  inherited Create;

  Assert(Assigned(User));

  FUser := User;

  PrepareData;
end;

destructor TSystemData_SQLite.TCollectionInfoIteratorImpl.Destroy;
begin
  FreeAndNil(FBases);
  FreeAndNil(FCount);

  inherited Destroy;
end;

function TSystemData_SQLite.TCollectionInfoIteratorImpl.Next(out CollectionInfo: TCollectionInfo): Boolean;
begin
  Result := not FBases.Eof;

  if Result then
  begin
    CollectionInfo := FUser.GetCollectionInfo(FBases.FieldAsInt(0));
    FBases.Next;
  end;
end;

function TSystemData_SQLite.TCollectionInfoIteratorImpl.RecordCount: Integer;
begin
  Assert(Assigned(FCount), 'Calling RecordCount more than once!');

  FCount.Open;
  Result := FCount.FieldAsInt(0);
  FreeAndNil(FCount);
end;

procedure TSystemData_SQLite.TCollectionInfoIteratorImpl.PrepareData;
const
  SQL_COUNT = 'SELECT COUNT(*) FROM Bases b ';
  SQL_ROWS = 'SELECT b.DatabaseID FROM Bases b ';
begin
  FCount := FUser.FDatabase.NewQuery(SQL_COUNT);

  FBases := FUser.FDatabase.NewQuery(SQL_ROWS);
  FBases.Open;
end;


constructor TSystemData_SQLite.Create(const DBUserFile: string);
begin
  inherited Create;

  Assert(FileExists(DBUserFile));
  FDatabase := TSQLiteDatabase.Create(DBUserFile);
end;

destructor TSystemData_SQLite.Destroy;
begin
  FreeAndNil(FDatabase);
  inherited Destroy;
end;

function TSystemData_SQLite.GetCollectionInfo(const CollectionID: Integer): TCollectionInfo;
const
  SQL_SELECT = 'SELECT ' +
    'bs.BaseName, bs.RootFolder, bs.DBFileName, bs.Code, '   +
    'bs.DataVersion, bs.Notes, bs.LibUser, bs.LibPassword, ' +
    'bs.URL, bs.ConnectionScript ' +
    'FROM Bases bs WHERE bs.DatabaseID = ?';
var
  query: TSQLiteQuery;
begin

  query := FDatabase.NewQuery(SQL_SELECT);
  try
    query.SetParam(0, CollectionID);
    query.Open;
    if not query.Eof then
    begin
      Result.Clear;
      Result.ID := CollectionID;
      Result.DisplayName := query.FieldAsString(0);

      Result.RootFolder := Settings.ExpandCollectionRoot(query.FieldAsString(1));
      Result.DBFileName := Settings.ExpandCollectionFileName(query.FieldAsString(2));

      Result.CollectionType := query.FieldAsInt(3);

      if query.FieldIsNull(4) then
        Result.DataVersion := UNVERSIONED_COLLECTION
      else
        Result.DataVersion := query.FieldAsInt(4);

      Result.Notes := query.FieldAsString(5);
      Result.User := query.FieldAsString(6);
      Result.Password := query.FieldAsString(7);
      Result.URL := query.FieldAsString(8);
      Result.Script := query.FieldAsBlobString(9);
    end;
  finally
    FreeAndNil(query);
  end;
end;

function TSystemData_SQLite.HasCollectionWithProp(PropID: TPropertyID; const Value: string; IgnoreID: Integer): Boolean;
var
  CollectionInfoIterator: ICollectionInfoIterator;
  CollectionInfo: TCollectionInfo;
  Match: Boolean;
  searchValue: string;
begin
  CollectionInfoIterator := GetCollectionInfoIterator;

  Result := False;

  case PropID of
  PROP_ROOTFOLDER:
    searchValue := Settings.ExpandCollectionRoot(Value);

  PROP_DATAFILE:
    searchValue := Settings.ExpandCollectionFileName(Value);

  else
    searchValue := Value;
  end;

  while (CollectionInfoIterator.Next(CollectionInfo)) do
  begin
    case PropID of
    PROP_DISPLAYNAME:
      Match := (CollectionInfo.DisplayName = searchValue);

    PROP_DATAFILE:
      Match := (CollectionInfo.DBFileName = searchValue);

    PROP_ROOTFOLDER:
      Match := (CollectionInfo.RootFolder = searchValue);

    else
      raise ENotSupportedException.CreateFmt('Property %d is not searchable', [PropID]);
    end;

    if Match and ((IgnoreID = INVALID_COLLECTION_ID) or (IgnoreID <> CollectionInfo.ID)) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function FieldByPropID(const PropID: TPropertyID): string;
begin
  Assert(isSystemProp(PropID));

  case PropID of
    PROP_ID:               Result := 'DatabaseID';
    PROP_DATAFILE:         Result := 'DBFileName';
    PROP_CODE:             Result := 'Code';
    PROP_DISPLAYNAME:      Result := 'BaseName';
    PROP_ROOTFOLDER:       Result := 'RootFolder';
    PROP_LIBUSER:          Result := 'LibUser';
    PROP_LIBPASSWORD:      Result := 'LibPassword';
    PROP_URL:              Result := 'URL';
    PROP_CONNECTIONSCRIPT: Result := 'ConnectionScript';
    PROP_DATAVERSION:      Result := 'DataVersion';
  else
    raise ENotSupportedException.CreateFmt('No column mapped for property %d', [PropID]);
  end;
end;

procedure TSystemData_SQLite.SetProperty(const CollectionID: Integer; const PropID: TPropertyID; const Value: Variant);
const
  SQL_UPDATE = 'UPDATE Bases SET %s = ? WHERE DatabaseID = ?';
var
  FieldName: string;
  query: TSQLiteQuery;
  vValue: Variant;
begin
  Assert(CollectionID <> INVALID_COLLECTION_ID);
  Assert(isSystemProp(PropID));

  vValue := Value;

  case PropID of
    PROP_ID,
    PROP_DATAFILE,
    PROP_CODE:
      raise ENotSupportedException.CreateFmt('Property %d is read-only', [PropID]);
    PROP_ROOTFOLDER:
      // RootFolder is resolved against WorkPath by ExpandCollectionRoot,
      // unlike the catalog filename which is relative to DataPath.
      vValue := ExtractRelativePath(Settings.WorkPath, vValue);
  end;

  FieldName := FieldByPropID(PropID);

  query := FDatabase.NewQuery(Format(SQL_UPDATE, [FieldName]));
  try
    case propertyType(PropID) of
      PROP_TYPE_INTEGER:  query.SetParam(0, Integer(vValue));
      PROP_TYPE_DATETIME: query.SetParam(0, TDateTime(vValue));
      PROP_TYPE_BOOLEAN:  query.SetParam(0, Boolean(vValue));
      PROP_TYPE_STRING:   query.SetParam(0, string(vValue));
    end;

    query.SetParam(1, CollectionID);

    query.ExecSQL;
  finally
    query.Free;
  end;
end;

function TSystemData_SQLite.GetProperty(const CollectionID: Integer; const PropID: TPropertyID): Variant;
const
  SQL = 'SELECT %s FROM Bases WHERE DatabaseID = ?';
var
  FieldName: string;
  query: TSQLiteQuery;
begin
  Assert(CollectionID <> INVALID_COLLECTION_ID);
  Assert(isSystemProp(PropID));

  FieldName := FieldByPropID(PropID);
  query := FDatabase.NewQuery(Format(SQL, [FieldName]));
  try
    query.SetParam(0, CollectionID);

    query.Open;
    if not query.Eof then
    begin
      case propertyType(PropID) of
        PROP_TYPE_INTEGER:  Result := query.FieldAsInt(0);
        PROP_TYPE_DATETIME: Result := query.FieldAsDateTime(0);
        PROP_TYPE_BOOLEAN:  Result := query.FieldAsBoolean(0);
        PROP_TYPE_STRING:   Result := query.FieldAsString(0);
      end;
    end;
  finally
    query.Free;
  end;

  if not VarIsEmpty(Result) then
  begin
    if PROP_DATAFILE = PropID then
      Result := Settings.ExpandCollectionFileName(Result)
  end;
end;

procedure TSystemData_SQLite.DeleteCollection(const CollectionID: Integer; const RemoveFromDisk: Boolean = True);
const
  DELETE_BASES_QUERY = 'DELETE FROM Bases WHERE DatabaseID = ? ';
var
  info: TCollectionInfo;
  DBFileName: string;
begin
  info := GetCollectionInfo(CollectionID);
  DBFileName := info.DBFileName;

  FCollectionCache.Remove(CollectionID);

  FDatabase.ExecSQL(DELETE_BASES_QUERY, [CollectionID]);

  if RemoveFromDisk then
    DeleteFile(DBFileName);
end;

function TSystemData_SQLite.CreateCollection(
  const DisplayName: string;
  const RootFolder: string;
  const DBFileName: string;
  CollectionType: COLLECTION_TYPE;
  const GenresFileName: string
  ): Integer;
const
  SQL_INSERT =
    'INSERT INTO Bases (BaseName, RootFolder, DBFileName, CreationDate, Code) ' +
    'VALUES(?, ?, ?, ?, ?)';
var
  absDBFileName: string;
  storedRoot: string;
  storedFileName: string;
  query: TSQLiteQuery;
begin
  absDBFileName := Settings.ExpandCollectionFileName(DBFileName);

  TBookCollection_SQLite.CreateCollection(Self, absDBFileName, CollectionType, GenresFileName);

  try
    storedFileName := DBFileName;
    storedRoot := RootFolder;
    PrepareCollectionPath(storedRoot, storedFileName);

    query := FDatabase.NewQuery(SQL_INSERT);
    try
      query.SetParam(0, DisplayName);
      query.SetParam(1, storedRoot);
      query.SetParam(2, storedFileName);
      query.SetParam(3, Now);
      query.SetParam(4, CollectionType);

      query.ExecSQL;

      Result := FDatabase.LastInsertRowID;
    finally
      FreeAndNil(query);
    end;
  except
    DeleteFile(absDBFileName);
    raise;
  end;
end;

function TSystemData_SQLite.RegisterCollection(
  const DBFileName: string;
  const DisplayName: string;
  const RootFolder: string
  ): Integer;
const
  SQL_INSERT =
    'INSERT INTO Bases (BaseName, RootFolder, DBFileName, CreationDate, Code) ' +
    'VALUES(?, ?, ?, ?, ?)';
var
  absFileName: string;
  storedRoot: string;
  storedFileName: string;
  CollectionType: COLLECTION_TYPE;
  query: TSQLiteQuery;
begin
  absFileName := Settings.ExpandCollectionFileName(DBFileName);

  if TBookCollection_SQLite.IsValidCollection(absFileName, CollectionType) then
  begin
    storedRoot := RootFolder;
    storedFileName := DBFileName;
    PrepareCollectionPath(storedRoot, storedFileName);

    query := FDatabase.NewQuery(SQL_INSERT);
    try
      query.SetParam(0, DisplayName);
      query.SetParam(1, storedRoot);
      query.SetParam(2, storedFileName);
      query.SetParam(3, Now);
      query.SetParam(4, CollectionType);

      query.ExecSQL;

      Result := FDatabase.LastInsertRowID;

    finally
      FreeAndNil(query);
    end;
  end
  else
  begin
    raise Exception.CreateFmt(rstrInvalidCollection, [DBFileName]);
  end;
end;

function TSystemData_SQLite.InternalCreateCollection(const CollectionID: Integer): IBookCollection;
var
  CollectionInfo: TCollectionInfo;
begin
  CollectionInfo := GetCollectionInfo(CollectionID);
  if CollectionInfo.ID <> INVALID_COLLECTION_ID then
  begin
    try
      Result := TBookCollection_SQLite.Create(CollectionInfo, Self);
    except
      raise EDBError.CreateFmt(rstrFailedToMountDB, [CollectionInfo.DBFileName]);
    end;
    Exit;
  end;

  raise EDBError.CreateFmt('Collection %d not found', [CollectionID]);
end;

function TSystemData_SQLite.ActivateGroup(const ID: Integer): Boolean;
const
  SQL_SELECT = 'SELECT GroupID FROM Groups WHERE GroupID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_SELECT);
  try
    query.SetParam(0, ID);
    query.Open;
    Result := not query.Eof;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.GetBookRecord(const BookKey: TBookKey; var BookRecord: TBookRecord);
const
  SQL_SELECT = 'SELECT ' +
    'LibID, Title, SeriesID, SeqNumber, UpdateDate, ' +
    'LibRate, Lang, Folder, FileName, InsideNo, ' +
    'Ext, BookSize, IsLocal, IsDeleted, ' +
    'KeyWords, Rate, Progress, Annotation, Review, ' +
    'ExtraInfo ' +
    'FROM Books WHERE BookID = ? AND DatabaseID = ? ';
var
  stream: TStream;
  reader: TReader;
  author: TAuthorData;
  genre: TGenreData;
  query: TSQLiteQuery;
  collectionInfo: TCollectionInfo;
begin
  query := FDatabase.NewQuery(SQL_SELECT);
  try
    query.SetParam(0, BookKey.BookID);
    query.SetParam(1, BookKey.DatabaseID);
    query.Open;
    Assert(not query.Eof);

    BookRecord.NodeType := ntBookInfo;
    BookRecord.BookKey := BookKey;
    BookRecord.LibID := query.FieldAsString(0);
    BookRecord.Title := query.FieldAsString(1);
    if query.FieldIsNull(2) then
    begin
      BookRecord.SeriesID := NO_SERIES_ID;
      BookRecord.SeqNumber := 0;
    end
    else
    begin
      BookRecord.SeriesID := query.FieldAsInt(2);
      BookRecord.SeqNumber := query.FieldAsInt(3);
    end;
    BookRecord.Date := query.FieldAsDateTime(4);
    BookRecord.LibRate := query.FieldAsInt(5);
    BookRecord.Lang := query.FieldAsString(6);
    BookRecord.Folder := query.FieldAsString(7);
    BookRecord.FileName := query.FieldAsString(8);
    BookRecord.InsideNo := query.FieldAsInt(9);
    BookRecord.FileExt := query.FieldAsString(10);
    BookRecord.Size := query.FieldAsInt(11);
    if query.FieldAsBoolean(12) then
      Include(BookRecord.BookProps, bpIsLocal)
    else
      Exclude(BookRecord.BookProps, bpIsLocal);
    if query.FieldAsBoolean(13) then
      Include(BookRecord.BookProps, bpIsDeleted)
    else
      Exclude(BookRecord.BookProps, bpIsDeleted);
    BookRecord.KeyWords := query.FieldAsString(14);
    BookRecord.Rate := query.FieldAsInt(15);
    BookRecord.Progress := query.FieldAsInt(16);
    BookRecord.Annotation := query.FieldAsBlobString(17);
    BookRecord.Review := query.FieldAsBlobString(18);
    if BookRecord.Review <> '' then
      Include(BookRecord.BookProps, bpHasReview)
    else
      Exclude(BookRecord.BookProps, bpHasReview);

    stream := query.FieldAsBlob(19);
    try
      reader := TReader.Create(stream, 4096);
      try
        BookRecord.Series := reader.ReadString;
        if BookRecord.SeriesID = NO_SERIES_ID then
          BookRecord.Series := NO_SERIES_TITLE;

        BookRecord.Authors:=nil;
        reader.ReadListBegin;
        while not reader.EndOfList do
        begin
          // не полагаемся на порядок вычисления аргументов, т к важен порядок чтения строк
          Author.LastName := reader.ReadString;
          Author.FirstName := reader.ReadString;
          Author.MiddleName := reader.ReadString;
          Author.AuthorID := reader.ReadInteger;

          TAuthorsHelper.Add(
            BookRecord.Authors,
            Author.LastName,
            Author.FirstName,
            Author.MiddleName,
            Author.AuthorID
          );
        end;
        reader.ReadListEnd;

        BookRecord.Genres:=nil;
        reader.ReadListBegin;
        while not reader.EndOfList do
        begin
          Genre.GenreCode := reader.ReadString;
          Genre.FB2GenreCode := reader.ReadString;
          Genre.GenreAlias := reader.ReadString;

          TGenresHelper.Add(
            BookRecord.Genres,
            Genre.GenreCode,
            Genre.GenreAlias,
            Genre.FB2GenreCode
          );
        end;
        reader.ReadListEnd;
      finally
        reader.Free;
      end;
    finally
      Stream.Free;
    end;
  finally
    FreeAndNil(query);
  end;

  try
    collectionInfo := GetCollectionInfo(BookRecord.BookKey.DatabaseID);
    // Please notice that the collection for a book in a group might not match ActiveCollection
    // Need to use values from tblBases instead
    BookRecord.CollectionName := collectionInfo.DisplayName;
    BookRecord.CollectionRoot := collectionInfo.GetRootPath;
  except
    BookRecord.CollectionName := rstrUnknownCollection;
    BookRecord.CollectionRoot := '';
    Assert(False);
  end;
end;

procedure TSystemData_SQLite.DeleteBook(const BookKey: TBookKey);
const
  SQL_DELETE_FROM_BOOK_GROUPS: string = 'DELETE FROM BookGroups WHERE BookID = ? AND DatabaseID = ? ';
  SQL_DELETE_FROM_BOOKS: string = 'DELETE FROM Books WHERE BookID = ? AND DatabaseID = ? ';
var
  OwnTransaction: Boolean;
begin
  OwnTransaction := not FDatabase.InTransaction;
  if OwnTransaction then
    FDatabase.Start;
  try
    FDatabase.ExecSQL(SQL_DELETE_FROM_BOOK_GROUPS, [BookKey.BookID, BookKey.DatabaseID]);
    FDatabase.ExecSQL(SQL_DELETE_FROM_BOOKS, [BookKey.BookID, BookKey.DatabaseID]);
    if OwnTransaction then
      FDatabase.Commit;
  except
    if OwnTransaction and FDatabase.InTransaction then
      FDatabase.Rollback;
    raise;
  end;
end;

procedure TSystemData_SQLite.UpdateBook(const BookRecord: TBookRecord);
const
  SQL_UPDATE = 'UPDATE Books ' +
    'SET LibID = ?, Title = ?, SeriesID = ?, SeqNumber = ?, UpdateDate = ?, ' +
    'LibRate = ?, Lang = ?, Folder = ?, FileName = ?, InsideNo = ?, ' +
    'Ext = ?, BookSize = ?, IsLocal = ?, IsDeleted = ?, ' +
    'KeyWords = ?, Rate = ?, Progress = ?, Annotation = ?, Review = ?, ' +
    'ExtraInfo = ? ' +
    'WHERE BookID = ? AND DatabaseID = ? ';
var
  stream: TStream;
  writer: TWriter;
  author: TAuthorData;
  genre: TGenreData;
  query: TSQLiteQuery;
  collectionInfo: TCollectionInfo;
begin
  collectionInfo := GetCollectionInfo(BookRecord.BookKey.DatabaseID);

  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetParam(0, BookRecord.LibID);
    query.SetParam(1, BookRecord.Title);
    query.SetParam(2, BookRecord.SeriesID);
    query.SetParam(3, BookRecord.SeqNumber);
    query.SetParam(4, BookRecord.Date);
    query.SetParam(5, BookRecord.LibRate);
    query.SetParam(6, BookRecord.Lang);
    query.SetParam(7, TPath.Combine(collectionInfo.RootFolder, BookRecord.Folder));
    query.SetParam(8, BookRecord.FileName);
    query.SetParam(9, BookRecord.InsideNo);
    query.SetParam(10, BookRecord.FileExt);
    query.SetParam(11, BookRecord.Size);
    query.SetParam(12, bpIsLocal in BookRecord.BookProps);
    query.SetParam(13, bpIsDeleted in BookRecord.BookProps);
    query.SetParam(14, BookRecord.KeyWords);
    query.SetParam(15, BookRecord.Rate);
    query.SetParam(16, BookRecord.Progress);
    query.SetBlobParam(17, BookRecord.Annotation);
    query.SetBlobParam(18, BookRecord.Review);

    stream := TMemoryStream.Create;
    try
      writer := TWriter.Create(stream, 4096);
      try
        writer.WriteString(BookRecord.Series);

        writer.WriteListBegin;
        for Author in BookRecord.Authors do
        begin
          writer.WriteString(Author.LastName);
          writer.WriteString(Author.FirstName);
          writer.WriteString(Author.MiddleName);
          writer.WriteInteger(Author.AuthorID);
        end;
        writer.WriteListEnd;

        writer.WriteListBegin;
        for genre in BookRecord.Genres do
        begin
          writer.WriteString(genre.GenreCode);
          writer.WriteString(genre.FB2GenreCode);
          writer.WriteString(genre.GenreAlias);
        end;
        writer.WriteListEnd;
      finally
        FreeAndNil(writer);
      end;
      query.SetBlobParam(19, stream);
    finally
      stream.Free;
    end;

    query.SetParam(20, BookRecord.BookKey.BookID);
    query.SetParam(21, BookRecord.BookKey.DatabaseID);

    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.SetExtra(const BookKey: TBookKey; extra: TBookExtra);
const
  SQL_UPDATE = 'UPDATE Books SET Rate = CASE WHEN ? = 0 THEN Rate ELSE ? END, '
    + 'Progress = CASE WHEN ? = 0 THEN Progress ELSE ? END, '
    + 'Review = CASE WHEN ? THEN ? ELSE Review END WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  // Imported rows are partial: old .mhlud stores rating, progress and review
  // in separate sections. Match the catalog importer instead of clearing
  // earlier imported values (or existing personal data) in the system copy.
  if (extra.Rating = 0) and (extra.Progress = 0) and (extra.Review = '') then Exit;
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetParam(0, extra.Rating);
    query.SetParam(1, extra.Rating);
    query.SetParam(2, extra.Progress);
    query.SetParam(3, extra.Progress);
    query.SetParam(4, extra.Review <> '');
    query.SetBlobParam(5, extra.Review);
    query.SetParam(6, BookKey.BookID);
    query.SetParam(7, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.SetRate(const BookKey: TBookKey; Rate: Integer);
const
  SQL_UPDATE = 'UPDATE Books Set Rate = ? WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetParam(0, Rate);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

function TSystemData_SQLite.TrySetIdentityProgress(const Expected: TBookRecord;
  Progress: Integer; const Matches: TBookIdentityPredicate): Boolean;
var Changed: TBookRecord;
begin
  Changed := Expected; Changed.Progress := Progress;
  Result := TrySetIdentityPersonal(Changed, [bpfProgress], Matches) = biwSaved;
end;

function TSystemData_SQLite.TrySetIdentityPersonal(const Expected: TBookRecord;
  const Fields: TBookPersonalFields; const Matches: TBookIdentityPredicate;
  RequirePersonal: Boolean): TBookIdentityWriteResult;
const Columns: array[TBookPersonalField] of string = ('Rate','Progress','Review','Annotation','IsLocal');
var Savepoint, SQL: string; Started: Boolean; Query: TSQLiteQuery; Current: TBookRecord;
  Field: TBookPersonalField; ParameterIndex: Integer;
begin
  Result := biwUnavailable; Started := False;
  if (Expected.BookKey.BookID = 0) or (Expected.BookKey.DatabaseID <= 0) or not Assigned(Matches) or
    (Fields = []) or ((bpfProgress in Fields) and ((Expected.Progress < 0) or (Expected.Progress > 100))) or
    ((bpfRate in Fields) and ((Expected.Rate < 0) or (Expected.Rate > 5))) then Exit;
  // A separate store cannot durably synchronize an uncommitted outer batch.
  // The reader keeps its own position/notes and retries after that operation.
  if FDatabase.InTransaction then Exit;
  Savepoint := 'mhl_identity_personal_' + StringReplace(StringReplace(StringReplace(
    TGUID.NewGuid.ToString, '{', '', [rfReplaceAll]), '}', '', [rfReplaceAll]), '-', '', [rfReplaceAll]);
  try
    FDatabase.Start(Savepoint); Started := True;
    Query := FDatabase.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=? AND DatabaseID=?');
    try
      Query.SetParam(0, Expected.BookKey.BookID); Query.SetParam(1, Expected.BookKey.DatabaseID); Query.Open;
      Current := Default(TBookRecord);
      if not Query.Eof then
      begin
        Current.BookKey := Expected.BookKey; Current.NodeType := ntBookInfo;
        Current.LibID := Query.FieldAsString(0); Current.Folder := Query.FieldAsString(1);
        Current.FileName := Query.FieldAsString(2); Current.FileExt := Query.FieldAsString(3);
        Current.InsideNo := Query.FieldAsInt(4); Current.CollectionRoot := GetCollectionInfo(Expected.BookKey.DatabaseID).GetRootPath;
      end;
    finally Query.Free; end;
    if not Current.BookKey.IsSameAs(Expected.BookKey) then
    begin
      FDatabase.Rollback(Savepoint); FDatabase.Commit(Savepoint); Started := False;
      Exit(biwNoCard);
    end;
    if not Matches(Current) then
    begin
      FDatabase.Rollback(Savepoint); FDatabase.Commit(Savepoint); Started := False;
      Exit(biwMismatch);
    end;
    SQL := '';
    for Field := Low(TBookPersonalField) to High(TBookPersonalField) do
      if Field in Fields then
      begin if SQL <> '' then SQL := SQL + ','; SQL := SQL + Columns[Field] + '=?'; end;
    Query := FDatabase.NewQuery('UPDATE Books SET ' + SQL + ' WHERE BookID=? AND DatabaseID=?');
    try
      ParameterIndex := 0;
      for Field := Low(TBookPersonalField) to High(TBookPersonalField) do
        if Field in Fields then
        begin
          case Field of
            bpfRate: Query.SetParam(ParameterIndex, Expected.Rate);
            bpfProgress: Query.SetParam(ParameterIndex, Expected.Progress);
            bpfReview: Query.SetBlobParam(ParameterIndex, Expected.Review);
            bpfAnnotation: Query.SetBlobParam(ParameterIndex, Expected.Annotation);
            bpfIsLocal: Query.SetParam(ParameterIndex, bpIsLocal in Expected.BookProps);
          end;
          Inc(ParameterIndex);
        end;
      Query.SetParam(ParameterIndex, Expected.BookKey.BookID); Query.SetParam(ParameterIndex + 1, Expected.BookKey.DatabaseID); Query.ExecSQL;
      if FDatabase.LastChangedRows <> 1 then raise Exception.Create('Identity personal update was not applied.');
    finally Query.Free; end;
    FDatabase.Commit(Savepoint); Started := False; Result := biwSaved;
  except
    if Started and FDatabase.InTransaction then
      try FDatabase.Rollback(Savepoint); FDatabase.Commit(Savepoint); except end;
    Result := biwUnavailable;
  end;
end;

procedure TSystemData_SQLite.SetProgress(const BookKey: TBookKey; Progress: Integer);
const
  SQL_UPDATE = 'UPDATE Books Set Progress = ? WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetParam(0, Progress);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

function TSystemData_SQLite.GetReview(const BookKey: TBookKey): string;
const
  SQL_SELECT = 'SELECT Review FROM Books WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_SELECT);
  try
    query.SetParam(0, BookKey.BookID);
    query.SetParam(1, BookKey.DatabaseID);
    query.Open;
    if not query.Eof  then
      Result := query.FieldAsBlobString(0)
    else
      Result := '';
  finally
    FreeAndNil(query);
  end;
end;

function TSystemData_SQLite.SetReview(const BookKey: TBookKey; const Review: string): Integer;
const
  SQL_UPDATE = 'UPDATE Books Set Review = ? WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetBlobParam(0, Review);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;

    if Review <> '' then
      Result := 1
    else
      Result := 0;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.SetLocal(const BookKey: TBookKey; Value: Boolean);
const
  SQL_UPDATE = 'UPDATE Books SET IsLocal = ? WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetParam(0, Value);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.SetFileName(const BookKey: TBookKey; const FileName: string);
const
  SQL_UPDATE = 'UPDATE Books SET FileName = ? WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetParam(0, FileName);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.SetAnnotation(const BookKey: TBookKey;
  const Annotation: string);
const
  SQL_UPDATE = 'UPDATE Books Set Annotation = ? WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetBlobParam(0, Annotation);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.SetBookSeriesID(const BookKey: TBookKey; const SeriesID: Integer);
const
  SQL_UPDATE = 'UPDATE Books SET SeriesID = ? WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    if NO_SERIES_ID = SeriesID then
      query.SetNullParam(0)
    else
      query.SetParam(0, SeriesID);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.SetFolder(const BookKey: TBookKey; const Folder: string);
const
  SQL_UPDATE = 'UPDATE Books SET Folder = ? WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_UPDATE);
  try
    query.SetParam(0, Folder);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

// Result: true if added
function TSystemData_SQLite.AddGroup(const GroupName: string; const AllowDelete: Boolean = True): Boolean;
const
  SQL_SELECT = 'SELECT g.GroupID FROM Groups g WHERE g.GroupName = ? LIMIT 1 ';
  SQL_INSERT = 'INSERT INTO Groups (GroupName, AllowDelete) SELECT ?, ? ';
var
  Query: TSQLiteQuery;
begin
  Query := FDatabase.NewQuery(SQL_SELECT);
  try
    Query.SetParam(0, GroupName);
    Query.Open;
    Result := Query.Eof;
  finally
    FreeAndNil(Query);
  end;

  if Result then
  begin
    Query := FDatabase.NewQuery(SQL_INSERT);
    try
      Query.SetParam(0, GroupName);
      Query.SetParam(1, AllowDelete);
      Query.ExecSQL;
    finally
      FreeAndNil(Query);
    end;
  end;
end;

function TSystemData_SQLite.RenameGroup(GroupID: Integer; const NewName: string): Boolean;
const
  SQL = 'UPDATE Groups SET GroupName = ? WHERE GroupID = ? ';
var
  query: TSQLiteQuery;
begin
  Result := False;
  if InternalFindGroup(GroupID) then
  begin
    query := FDatabase.NewQuery(SQL);
    try
      query.SetParam(0, NewName);
      query.SetParam(1, GroupID);
      query.ExecSQL;
      Result := True;
    finally
      FreeAndNil(query);
    end;
  end;
end;

procedure TSystemData_SQLite.DeleteGroup(GroupID: Integer);
begin
  InternalClearGroup(GroupID, True);
end;

procedure TSystemData_SQLite.ClearGroup(GroupID: Integer);
begin
  InternalClearGroup(GroupID, False);
end;

function TSystemData_SQLite.GetGroup(const GroupID: Integer): TGroupData;
const
  SQL = 'SELECT g.GroupName, g.AllowDelete FROM Groups g WHERE g.GroupID = ? ';
var
  query: TSQLiteQuery;
begin
  Result.GroupID := MHL_INVALID_ID;
  Result.Text := '';
  Result.CanDelete := False;

  query := FDatabase.NewQuery(SQL);
  try
    query.SetParam(0, GroupID);
    query.Open;

    if not query.Eof then
    begin
      Result.GroupID := GroupID;
      Result.Text := query.FieldAsString(0);
      Result.CanDelete := query.FieldAsBoolean(1);
    end;
  finally
    FreeAndNil(Query);
  end;
end;

procedure TSystemData_SQLite.AddBookToGroup(
  const BookKey: TBookKey;
  GroupID: Integer;
  const BookRecord: TBookRecord
);
const
  SQL_SELECT = 'SELECT Count(*) FROM Books WHERE BookID = ? AND DatabaseID = ? ';
  SQL_INSERT = 'INSERT INTO BOOKS (' +
    'LibID, Title, SeriesID, SeqNumber, UpdateDate, ' +
    'LibRate, Lang, Folder, FileName, InsideNo, ' +
    'Ext, BookSize, IsLocal, IsDeleted, ' +
    'KeyWords, Rate, Progress, Annotation, Review, ' +
    'ExtraInfo, BookID, DatabaseID ) ' +
    'SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? ';

var
  stream: TStream;
  writer: TWriter;
  author: TAuthorData;
  genre: TGenreData;
  query: TSQLiteQuery;
  exists: Boolean;
  collectionInfo: TCollectionInfo;
begin
  collectionInfo := GetCollectionInfo(BookKey.DatabaseID);

  query := FDatabase.NewQuery(SQL_SELECT);
  try
    query.SetParam(0, BookKey.BookID);
    query.SetParam(1, BookKey.DatabaseID);
    query.Open;
    exists := query.FieldAsInt(0) <> 0;
  finally
    FreeAndNil(query);
  end;

  if not exists then
  begin
    query := FDatabase.NewQuery(SQL_INSERT);
    try
      query.SetParam(0, BookRecord.LibID);
      query.SetParam(1, BookRecord.Title);
      query.SetParam(2, BookRecord.SeriesID);
      query.SetParam(3, BookRecord.SeqNumber);
      query.SetParam(4, BookRecord.Date);
      query.SetParam(5, BookRecord.LibRate);
      query.SetParam(6, BookRecord.Lang);
      query.SetParam(7, TPath.Combine(collectionInfo.RootFolder, BookRecord.Folder));
      query.SetParam(8, BookRecord.FileName);
      query.SetParam(9, BookRecord.InsideNo);
      query.SetParam(10, BookRecord.FileExt);
      query.SetParam(11, BookRecord.Size);
      query.SetParam(12, bpIsLocal in BookRecord.BookProps);
      query.SetParam(13, bpIsDeleted in BookRecord.BookProps);
      query.SetParam(14, BookRecord.KeyWords);
      query.SetParam(15, BookRecord.Rate);
      query.SetParam(16, BookRecord.Progress);
      if BookRecord.Annotation = '' then
        query.SetNullParam(17)
      else
        query.SetParam(17, BookRecord.Annotation);
      if BookRecord.Review = '' then
        query.SetNullParam(18)
      else
        query.SetBlobParam(18, BookRecord.Review);

      stream := TMemoryStream.Create;
      try
        writer := TWriter.Create(stream, 4096);
        try
          writer.WriteString(BookRecord.Series);

          writer.WriteListBegin;
          for Author in BookRecord.Authors do
          begin
            writer.WriteString(Author.LastName);
            writer.WriteString(Author.FirstName);
            writer.WriteString(Author.MiddleName);
            writer.WriteInteger(Author.AuthorID);
          end;
          writer.WriteListEnd;

          writer.WriteListBegin;
          for genre in BookRecord.Genres do
          begin
            writer.WriteString(genre.GenreCode);
            writer.WriteString(genre.FB2GenreCode);
            writer.WriteString(genre.GenreAlias);
          end;
          writer.WriteListEnd;
        finally
          FreeAndNil(writer);
        end;
        query.SetBlobParam(19, stream);
      finally
        stream.Free;
      end;

      query.SetParam(20, BookKey.BookID);
      query.SetParam(21, BookKey.DatabaseID);

      query.ExecSQL;
    finally
      FreeAndNil(query);
    end;
  end;

  CopyBookToGroup(BookKey, 0, GroupID, False);
end;

// NOTE: этот метод не удаляет неиспользуемые книги !!! После его вызова обязательно нужно вызвать RemoveUnusedBooks
procedure TSystemData_SQLite.DeleteFromGroup(const BookKey: TBookKey; GroupID: Integer);
const
  SQL_DELETE_BOOKGROUPS = 'DELETE FROM BookGroups WHERE BookID = ? AND GroupID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_DELETE_BOOKGROUPS);
  try
    query.SetParam(0, BookKey.BookID);
    query.SetParam(1, GroupID);
    query.SetParam(2, BookKey.DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.RemoveUnusedBooks;
const
  SQL: string =
      'DELETE FROM Books WHERE NOT EXISTS( ' +
      ' SELECT 1 FROM BookGroups g ' +
      ' WHERE g.BookID = Books.BookID AND g.DatabaseID = Books.DatabaseID ' +
      ')';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL);
  try
    query.ExecSQL;
  finally
    FreeAndNil(Query);
  end;
end;

procedure TSystemData_SQLite.CleanCollectionBooks(const DatabaseID: Integer);
const
  SQL_DELETE_BOOKGROUPS = 'DELETE FROM BookGroups WHERE DatabaseID = ?';
  SQL_DELETE_BOOKS = 'DELETE FROM Books WHERE DatabaseID = ?';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_DELETE_BOOKGROUPS);
  try
    query.SetParam(0, DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;

  query := FDatabase.NewQuery(SQL_DELETE_BOOKS);
  try
    query.SetParam(0, DatabaseID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;
end;

// Книги в группах хранятся по (BookID, DatabaseID), но BookID в коллекции - это
// AUTOINCREMENT: при полном переимпорте коллекции он переприсваивается, и сохранённые
// в группах BookID начинают указывать на совершенно другие книги. В списке группы при
// этом видно закэшированное (правильное) название, а любая операция над книгой
// (экспорт, чтение, скачивание) обращается к коллекции по устаревшему BookID
// и получает чужую книгу.
// Сверяем по LibID - он при переимпорте не меняется - и приводим BookID к текущей
// нумерации коллекции.
function TSystemData_SQLite.RemapCollectionBookIDs(const DatabaseID: Integer; const RemoveMissing: Boolean): Integer;
const
  SAVEPOINT_NAME = 'mhl_system_book_remap';
  SQL_SELECT_BOOKS = 'SELECT BookID, LibID, IsDeleted FROM Books WHERE DatabaseID = ? ORDER BY BookID';
  SQL_GROUP_COUNTS = 'SELECT BookID, COUNT(*) FROM BookGroups WHERE DatabaseID = ? GROUP BY BookID';
  SQL_MOVE_GROUPS = 'UPDATE BookGroups SET BookID = ? WHERE BookID = ? AND DatabaseID = ?';
  SQL_MOVE_BOOK = 'UPDATE Books SET BookID = ? WHERE BookID = ? AND DatabaseID = ?';
  SQL_RESTORE_BOOK = 'UPDATE Books SET BookID = ?, IsDeleted = ? WHERE BookID = ? AND DatabaseID = ?';
  SQL_MARK_MISSING = 'UPDATE Books SET IsDeleted = 1 WHERE BookID = ? AND DatabaseID = ?';
type
  TRemapItem = record
    OldID, NewID, TemporaryID, GroupCount: Integer;
    Verified, IsDeleted, RestoreDeleted, ResolvedDeleted: Boolean;
  end;
var
  Collection: IBookCollection;
  Query: TSQLiteQuery;
  Items: TList<TRemapItem>;
  Occupants, Targets, GroupCounts: TDictionary<Integer,Integer>;
  Item, Occupant: TRemapItem;
  Book: TBookRecord;
  LibID: string;
  SmallestID, PrivateID, RawID, RawCount: Int64;
  I, OtherIndex, Count, MoveCount, ChangedCount: Integer;

  function Moves(const Value: TRemapItem): Boolean;
  begin
    Result := Value.Verified and (((Value.NewID > 0) and (Value.NewID <> Value.OldID)) or
      ((Value.NewID <= 0) and (Value.OldID >= 0)));
  end;

  function Changes(const Value: TRemapItem): Boolean;
  begin
    Result := Moves(Value) or (Value.Verified and (Value.NewID <= 0) and
      not Value.IsDeleted);
  end;

  procedure CheckAffected(Expected: Integer; const TableName: string);
  begin
    if FDatabase.LastChangedRows <> Expected then
      raise Exception.CreateFmt('Не удалось безопасно перенести записи %s коллекции %d. Изменения отменены.',
        [TableName, DatabaseID]);
  end;

  procedure MoveRows(const Value: TRemapItem; FromID, ToID: Integer; RestoreFlag: Boolean);
  begin
    if Value.GroupCount > 0 then
    begin
      FDatabase.ExecSQL(SQL_MOVE_GROUPS, [ToID, FromID, DatabaseID]);
      CheckAffected(Value.GroupCount, 'групп');
    end;
    if RestoreFlag then
      FDatabase.ExecSQL(SQL_RESTORE_BOOK, [ToID, Value.ResolvedDeleted, FromID, DatabaseID])
    else FDatabase.ExecSQL(SQL_MOVE_BOOK, [ToID, FromID, DatabaseID]);
    CheckAffected(1, 'книг');
  end;

begin
  Result := 0;
  // RemoveMissing is retained for API compatibility. A verified missing LibID
  // must always detach from a reusable catalog key, never delete the card.
  // An unavailable catalog cannot establish identity. Keep the saved cards.
  Collection := nil;
  try
    if not FileExists(GetCollectionInfo(DatabaseID).DBFileName) then Exit;
    Collection := GetCollection(DatabaseID, False);
  except
    on E: EAbort do raise;
    on E: EOutOfMemory do raise;
    on E: Exception do Exit;
  end;
  if not Assigned(Collection) then Exit;

  Items := TList<TRemapItem>.Create;
  Occupants := TDictionary<Integer,Integer>.Create;
  Targets := TDictionary<Integer,Integer>.Create;
  GroupCounts := TDictionary<Integer,Integer>.Create;
  try
    // A savepoint is atomic both alone and inside an existing data update.
    // Planning stays in the same system-database snapshot as the writes.
    FDatabase.Start(SAVEPOINT_NAME);
    try
      SmallestID := 0; MoveCount := 0; ChangedCount := 0;
      Query := FDatabase.NewQuery(SQL_SELECT_BOOKS);
      try
        Query.SetParam(0, DatabaseID); Query.Open;
        while not Query.Eof do
        begin
          Item := Default(TRemapItem); RawID := Query.FieldAsInt(0);
          if (RawID < Low(Integer)) or (RawID > High(Integer)) then
            raise Exception.Create('Номер сохранённой книги выходит за допустимый диапазон. Изменения отменены.');
          Item.OldID := Integer(RawID); Item.NewID := Item.OldID;
          if RawID < SmallestID then SmallestID := RawID;
          Item.IsDeleted := Query.FieldAsBoolean(2); LibID := Query.FieldAsString(1);
          // Empty/local identities cannot be safely inferred from a catalog ID.
          Item.Verified := (LibID <> '') and (LibID <> '0');
          if Item.Verified then
          begin
            Item.NewID := Collection.ResolveBookID(LibID, Item.OldID);
            if Item.NewID > 0 then
            begin
              if Targets.TryGetValue(Item.NewID, OtherIndex) then
                raise Exception.CreateFmt('Несколько сохранённых карточек (%d и %d) указывают на одну книгу %d коллекции %d. Данные сохранены; устраните неоднозначность перед обновлением.',
                  [Items[OtherIndex].OldID, Item.OldID, Item.NewID, DatabaseID]);
              Targets.Add(Item.NewID, Items.Count);
              Item.RestoreDeleted := Item.OldID < 0;
              if Item.RestoreDeleted then
              begin
                Collection.GetBookRecord(CreateBookKey(Item.NewID, DatabaseID), Book, False);
                Item.ResolvedDeleted := bpIsDeleted in Book.BookProps;
              end;
            end;
          end;
          Occupants.Add(Item.OldID, Items.Count); Items.Add(Item); Query.Next;
        end;
      finally Query.Free; end;

      Query := FDatabase.NewQuery(SQL_GROUP_COUNTS);
      try
        Query.SetParam(0, DatabaseID); Query.Open;
        while not Query.Eof do
        begin
          RawID := Query.FieldAsInt(0);
          if (RawID < Low(Integer)) or (RawID > High(Integer)) then
            raise Exception.Create('Номер книги в группе выходит за допустимый диапазон. Изменения отменены.');
          RawCount := Query.FieldAsInt(1);
          if (RawCount < 0) or (RawCount > High(Integer)) then
            raise Exception.Create('Количество связей книги выходит за допустимый диапазон. Изменения отменены.');
          GroupCounts.Add(Integer(RawID), Integer(RawCount));
          if RawID < SmallestID then SmallestID := RawID;
          Query.Next;
        end;
      finally Query.Free; end;

      for I := 0 to Items.Count - 1 do
      begin
        Item := Items[I];
        if GroupCounts.TryGetValue(Item.OldID, Count) then Item.GroupCount := Count;
        if Moves(Item) then
        begin
          Inc(MoveCount);
          if Item.NewID > 0 then
          begin
            if Occupants.TryGetValue(Item.NewID, OtherIndex) then
            begin
              Occupant := Items[OtherIndex];
              if not Moves(Occupant) then
                raise Exception.CreateFmt('Номер %d коллекции %d занят другой сохранённой карточкой. Данные сохранены; переназначение отменено.',
                  [Item.NewID, DatabaseID]);
            end
            else if GroupCounts.ContainsKey(Item.NewID) then
              raise Exception.CreateFmt('Номер %d коллекции %d уже используется группой без карточки книги. Переназначение отменено.',
                [Item.NewID, DatabaseID]);
          end;
        end;
        if Changes(Item) then Inc(ChangedCount);
        Items[I] := Item;
      end;

      PrivateID := SmallestID - 1;
      if (MoveCount > 0) and (PrivateID - MoveCount + 1 < Low(Integer)) then
        raise Exception.Create('Недостаточно свободных служебных номеров для безопасного переназначения. Данные сохранены.');
      for I := 0 to Items.Count - 1 do
      begin
        Item := Items[I];
        if Moves(Item) then
        begin
          Item.TemporaryID := Integer(PrivateID); Dec(PrivateID); Items[I] := Item;
        end;
      end;

      // Vacate every old key before installing any final key: swaps and cycles
      // never collide, and no review/blob/group is merged or discarded.
      for Item in Items do
        if Moves(Item) then MoveRows(Item, Item.OldID, Item.TemporaryID, False);
      for Item in Items do
        if Moves(Item) and (Item.NewID > 0) then
          MoveRows(Item, Item.TemporaryID, Item.NewID, Item.RestoreDeleted)
        else if Changes(Item) then
        begin
          if Moves(Item) then Count := Item.TemporaryID else Count := Item.OldID;
          // Missing books retain their full card and memberships on a private
          // negative key. Repeated checks leave that key and its blobs alone;
          // a later LibID match restores the current positive catalog key.
          FDatabase.ExecSQL(SQL_MARK_MISSING, [Count, DatabaseID]); CheckAffected(1, 'книг');
        end;
      FDatabase.Commit(SAVEPOINT_NAME); Result := ChangedCount;
    except
      // A trigger using RAISE(ROLLBACK) may already have removed the savepoint.
      if FDatabase.InTransaction then
      begin FDatabase.Rollback(SAVEPOINT_NAME); FDatabase.Commit(SAVEPOINT_NAME); end;
      raise;
    end;
  finally GroupCounts.Free; Targets.Free; Occupants.Free; Items.Free; end;
end;

procedure TSystemData_SQLite.CopyBookToGroup(
  const BookKey: TBookKey;
  SourceGroupID: Integer;
  TargetGroupID: Integer;
  MoveBook: Boolean
);
const
  SQL_SELECT = 'SELECT BookID FROM BookGroups WHERE GroupID = ? AND BookID = ? AND DatabaseID = ? ';
  SQL_MOVE = 'UPDATE BookGroups SET GroupID = ? WHERE GroupID = ? AND BookID = ? AND DatabaseID = ? ';
  SQL_ADD = 'INSERT INTO BookGroups (GroupID, BookID, DatabaseID) SELECT ?, ?, ? ';
var
  query: TSQLiteQuery;
  foundTarget: Boolean;
  foundSource: Boolean;
begin
  query := FDatabase.NewQuery(SQL_SELECT);
  try
    query.SetParam(0, TargetGroupID);
    query.SetParam(1, BookKey.BookID);
    query.SetParam(2, BookKey.DatabaseID);
    query.Open;
    foundTarget := not query.Eof;
  finally
    FreeAndNil(query);
  end;

  if foundTarget then
    Exit;

  if MoveBook then
  begin
    query := FDatabase.NewQuery(SQL_SELECT);
    try
      query.SetParam(0, SourceGroupID);
      query.SetParam(1, BookKey.BookID);
      query.SetParam(2, BookKey.DatabaseID);
      query.Open;
      foundSource := not query.Eof;
    finally
      FreeAndNil(query);
    end;

    if foundSource then
    begin
      query := FDatabase.NewQuery(SQL_MOVE);
      try
        query.SetParam(0, TargetGroupID);
        query.SetParam(1, SourceGroupID);
        query.SetParam(2, BookKey.BookID);
        query.SetParam(3, BookKey.DatabaseID);
        query.ExecSQL;
      finally
        FreeAndnil(query);
      end;
    end;
  end
  else
  begin
    query := FDatabase.NewQuery(SQL_ADD);
    try
      query.SetParam(0, TargetGroupID);
      query.SetParam(1, BookKey.BookID);
      query.SetParam(2, BookKey.DatabaseID);
      query.ExecSQL;
    finally
      FreeAndnil(query);
    end;
  end;
end;

function TSystemData_SQLite.GetDataRevision: string;
begin
  Result := IntToStr(FDatabase.QuerySingleInt('PRAGMA data_version')) + ':' +
    IntToStr(FDatabase.QuerySingleInt('SELECT total_changes()'));
end;

procedure TSystemData_SQLite.BeginMetadataRootGuard;
begin
  if FMetadataRootGuard or FDatabase.InTransaction then
    raise EInvalidOperation.Create('Другая операция меняет данные коллекций; повторите позже');
  // The connection already has a bounded SQLite busy timeout. No rows are
  // written, and ordinary readers remain available while this reservation is
  // held. Always acquire SystemDB before the catalog transaction.
  FDatabase.Start('', 'IMMEDIATE'); FMetadataRootGuard := True;
end;

procedure TSystemData_SQLite.EndMetadataRootGuard;
begin
  if not FMetadataRootGuard then raise EInvalidOperation.Create('Нет защиты папки коллекции');
  try
    if FDatabase.InTransaction then FDatabase.Rollback;
  finally FMetadataRootGuard := False; end;
end;

procedure TSystemData_SQLite.BeginDataUpdate;
begin
  FDatabase.Start;
  FDatabase.BeginQueryBatch;
end;

function TSystemData_SQLite.StoredBookIDs(const CollectionID: Integer): TArray<Integer>;
var Query: TSQLiteQuery; IDs: TList<Integer>;
begin
  IDs := TList<Integer>.Create;
  try
    Query := FDatabase.NewQuery('SELECT BookID FROM Books WHERE DatabaseID=?');
    try
      Query.SetParam(0, CollectionID); Query.Open;
      while not Query.Eof do
      begin IDs.Add(Query.FieldAsInt(0)); Query.Next; end;
      Result := IDs.ToArray;
    finally Query.Free; end;
  finally IDs.Free; end;
end;

procedure TSystemData_SQLite.EndDataUpdate(Commit: Boolean);
begin
  try
    if Commit then FDatabase.Commit
    else if FDatabase.InTransaction then FDatabase.Rollback;
  finally FDatabase.EndQueryBatch; end;
end;

procedure TSystemData_SQLite.ImportLegacyUserData(CollectionID: Integer; Data: TUserData;
  const Notify: TGUIUpdateExtraProc);
var Catalog: IBookCollection; CatalogFile: string; Query: TSQLiteQuery;
  Extra: TBookExtra; Group: TBookGroup; GroupBook: TGroupBook;
  Key: TBookKey; Book: TBookRecord; I: Integer;
  Notifications: TList<TPair<TBookKey,TBookExtra>>;
  Notification: TPair<TBookKey,TBookExtra>; OldGroupIDs: TArray<Integer>;
  function Resolve(Info: TBookInfo; out BookKey: TBookKey): Boolean;
  var Q: TSQLiteQuery;
  begin
    if Info.LibID='' then
      Q:=FDatabase.NewQuery('SELECT BookID FROM LegacyImportCatalog.Books WHERE BookID=?',[Info.BookID])
    else Q:=FDatabase.NewQuery('SELECT BookID FROM LegacyImportCatalog.Books WHERE LibID=?',[Info.LibID]);
    try
      Q.Open; Result:=not Q.Eof and (Q.FieldAsInt(0)>0);
      if Result then BookKey:=CreateBookKey(Q.FieldAsInt(0),CollectionID);
    finally Q.Free; end;
  end;
begin
  if not Assigned(Data) then raise EArgumentNilException.Create('Data');
  if FDatabase.InTransaction then
    raise EInvalidOperation.Create('Другая операция меняет данные; повторите импорт позже.');
  CatalogFile:=GetCollectionInfo(CollectionID).DBFileName;
  if not FileExists(CatalogFile) then raise EFileNotFoundException.Create(CatalogFile);
  Catalog:=GetCollection(CollectionID,False);
  Notifications:=TList<TPair<TBookKey,TBookExtra>>.Create;
  try
    SetLength(OldGroupIDs,Data.Groups.Count);
    for I:=0 to Data.Groups.Count-1 do OldGroupIDs[I]:=Data.Groups[I].GroupID;
    // One SQLite connection owns both writes and the commit. Separate
    // catalog/system transactions leave partial imports on the second error.
    FDatabase.ExecSQL('ATTACH DATABASE ? AS LegacyImportCatalog',[CatalogFile]);
    try
      FDatabase.Start('', 'IMMEDIATE');
      FDatabase.BeginQueryBatch;
      try
        try
          for Extra in Data.Extras do
            if Resolve(Extra,Key) then
            begin
              if (Extra.Rating<>0) or (Extra.Progress<>0) or (Extra.Review<>'') then
              begin
                Query:=FDatabase.NewQuery('UPDATE LegacyImportCatalog.Books SET '+
                  'Rate=CASE WHEN ?=0 THEN Rate ELSE ? END, '+
                  'Progress=CASE WHEN ?=0 THEN Progress ELSE ? END, '+
                  'Review=CASE WHEN ? THEN ? ELSE Review END WHERE BookID=?');
                try
                  Query.SetParam(0,Extra.Rating); Query.SetParam(1,Extra.Rating);
                  Query.SetParam(2,Extra.Progress); Query.SetParam(3,Extra.Progress);
                  Query.SetParam(4,Extra.Review<>''); Query.SetBlobParam(5,Trim(Extra.Review));
                  Query.SetParam(6,Key.BookID); Query.ExecSQL;
                finally Query.Free; end;
              end;
              SetExtra(Key,Extra);
              Notifications.Add(TPair<TBookKey,TBookExtra>.Create(Key,Extra));
            end;
          ImportUserData(Data);
          for Group in Data.Groups do
            for GroupBook in Group do
              if Resolve(GroupBook,Key) then
              begin
                Catalog.GetBookRecord(Key,Book,True);
                Query:=FDatabase.NewQuery('SELECT Rate,Progress,Review FROM LegacyImportCatalog.Books WHERE BookID=?',[Key.BookID]);
                try
                  Query.Open; Book.Rate:=Query.FieldAsInt(0); Book.Progress:=Query.FieldAsInt(1);
                  Book.Review:=Query.FieldAsBlobString(2);
                finally Query.Free; end;
                AddBookToGroup(Key,Group.GroupID,Book);
              end;
          FDatabase.Commit;
        except
          if FDatabase.InTransaction then FDatabase.Rollback;
          for I:=0 to Data.Groups.Count-1 do Data.Groups[I].GroupID:=OldGroupIDs[I];
          raise;
        end;
      finally FDatabase.EndQueryBatch; end;
    finally FDatabase.ExecSQL('DETACH DATABASE LegacyImportCatalog'); end;
    if Assigned(Notify) then
      for Notification in Notifications do Notify(Notification.Key,Notification.Value);
  finally Notifications.Free; end;
end;

function TSystemData_SQLite.RegisterSnapshotCollection(const CatalogFile, DisplayName, Root, SourceRoot: string;
  Source: TSQLiteDatabase; SourceID: Integer; const Canceled: TSnapshotCanceled): Integer;
const
  Columns='BookID,DatabaseID,LibID,Title,SeriesID,SeqNumber,UpdateDate,LibRate,Lang,Folder,FileName,'+
    'InsideNo,Ext,BookSize,IsLocal,IsDeleted,KeyWords,Rate,Progress,Annotation,Review,ExtraInfo';
var Q, Insert: TSQLiteQuery; Groups, ExtraGroups: TDictionary<Integer,Integer>; GroupID, NewID, I, N: Integer;
  GroupName, RestoredName, StoredRoot, Folder, Prefix: string; Blob: TStream;
  procedure CheckCanceled;
  begin if Assigned(Canceled) and Canceled() then Abort; end;
  function HistoricalGroup: Integer;
  var WriteGroup: TSQLiteQuery;
  begin
    RestoredName:=GroupName; N:=0;
    while True do
    begin
      CheckCanceled;
      Result:=FDatabase.QuerySingleInt('SELECT GroupID FROM Groups WHERE GroupName=? AND AllowDelete=1 '+
        'AND hex(Notes)=? AND (Notes IS NULL)=?',[RestoredName,Q.FieldAsString(4),Q.FieldIsNull(3)]);
      if Result<>0 then Exit;
      if FDatabase.QuerySingleInt('SELECT count(*) FROM Groups WHERE GroupName=?',[RestoredName])=0 then Break;
      Inc(N); RestoredName:=GroupName+' (восстановлено '+IntToStr(N)+')';
    end;
    WriteGroup:=FDatabase.NewQuery('INSERT INTO Groups(GroupName,AllowDelete,Notes) VALUES(?,1,?)');
    try
      WriteGroup.SetParam(0,RestoredName);
      if Q.FieldIsNull(3) then WriteGroup.SetNullParam(1)
      else begin Blob:=Q.FieldAsBlob(3); try WriteGroup.SetBlobParam(1,Blob); finally Blob.Free; end; end;
      WriteGroup.ExecSQL; Result:=FDatabase.LastInsertRowID;
    finally WriteGroup.Free; end;
  end;
begin
  if not Assigned(Source) or (SourceID<=0) then raise EArgumentException.Create('Нет исходной коллекции.');
  if FDatabase.InTransaction then raise EInvalidOperation.Create('Другая операция меняет данные. Повторите позже.');
  CheckCanceled; Result:=INVALID_COLLECTION_ID;
  Groups:=TDictionary<Integer,Integer>.Create; ExtraGroups:=nil;
  try
    ExtraGroups:=TDictionary<Integer,Integer>.Create;
    FDatabase.Start('', 'IMMEDIATE'); FDatabase.BeginQueryBatch;
    try
    try
      // Registration and every personal row commit together. No existing
      // collection, book card or group note is overwritten.
      Result:=RegisterCollection(CatalogFile,DisplayName,Root);
      StoredRoot:=Source.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[SourceID]);
      Q:=Source.NewQuery('SELECT '+Columns+' FROM Books WHERE DatabaseID=?',[SourceID]);
      try
        Insert:=FDatabase.NewQuery('INSERT INTO Books('+Columns+') VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)');
        try
          Q.Open;
          while not Q.Eof do
          begin
            CheckCanceled; Insert.Reset;
            for I:=0 to 21 do
              if I=1 then Insert.SetParam(I,Result)
              else if Q.FieldIsNull(I) then Insert.SetNullParam(I)
              else if (I=9) and not SameFileName(Root,SourceRoot) then
              begin
                Folder:=Q.FieldAsString(I); Prefix:=IncludeTrailingPathDelimiter(SourceRoot);
                if SameFileName(ExcludeTrailingPathDelimiter(Folder),ExcludeTrailingPathDelimiter(SourceRoot)) then Folder:=Root
                else
                begin
                if not Folder.StartsWith(Prefix,True) and not TPath.IsPathRooted(StoredRoot) then
                  Prefix:=IncludeTrailingPathDelimiter(StoredRoot);
                if Folder.StartsWith(Prefix,True) then Folder:=TPath.Combine(Root,Copy(Folder,Length(Prefix)+1,MaxInt));
                end;
                Insert.SetParam(I,Folder);
              end
              else if I>=19 then
              begin
                Blob:=Q.FieldAsBlob(I);
                try Insert.SetBlobParam(I,Blob); finally Blob.Free; end;
              end
              else if I in [0,4,5,7,11,13,14,15,17,18] then Insert.SetParam(I,Q.FieldAsInt(I))
              else Insert.SetParam(I,Q.FieldAsString(I));
            Insert.ExecSQL; Q.Next;
          end;
        finally Insert.Free; end;
      finally Q.Free; end;
      Q:=Source.NewQuery('SELECT GroupID,GroupName,AllowDelete,Notes,hex(Notes) FROM Groups '+
        'WHERE GroupID IN (SELECT GroupID FROM BookGroups WHERE DatabaseID=?)',[SourceID]);
      try
        Q.Open;
        while not Q.Eof do
        begin
          CheckCanceled; GroupID:=Q.FieldAsInt(0); GroupName:=Q.FieldAsString(1);
          if not Q.FieldAsBoolean(2) then
          begin
            NewID:=FDatabase.QuerySingleInt('SELECT GroupID FROM Groups WHERE GroupID=? AND AllowDelete=0',[GroupID]);
            if NewID=0 then raise Exception.Create('Не найдена системная группа резервной копии.');
            // Keep the built-in membership (e.g. favourites), and keep changed
            // historical notes in an additional named group without replacing
            // the current global notes shared by other collections.
            if not Q.FieldIsNull(3) and (Q.FieldAsString(4)<>'') and
              (FDatabase.QuerySingleString('SELECT hex(Notes) FROM Groups WHERE GroupID=?',[NewID])<>Q.FieldAsString(4)) then
              ExtraGroups.Add(GroupID,HistoricalGroup);
          end
          else NewID:=HistoricalGroup;
          Groups.Add(GroupID,NewID); Q.Next;
        end;
      finally Q.Free; end;
      Q:=Source.NewQuery('SELECT BookID,GroupID FROM BookGroups WHERE DatabaseID=?',[SourceID]);
      try
        Insert:=FDatabase.NewQuery('INSERT INTO BookGroups(BookID,DatabaseID,GroupID) VALUES(?,?,?)');
        try
          Q.Open;
          while not Q.Eof do
          begin
            CheckCanceled;
            if not Groups.TryGetValue(Q.FieldAsInt(1),NewID) then raise Exception.Create('Повреждена связь книги с группой.');
            Insert.Reset; Insert.SetParam(0,Q.FieldAsInt(0)); Insert.SetParam(1,Result); Insert.SetParam(2,NewID);
            Insert.ExecSQL;
            if ExtraGroups.TryGetValue(Q.FieldAsInt(1),NewID) then
            begin
              Insert.Reset; Insert.SetParam(0,Q.FieldAsInt(0)); Insert.SetParam(1,Result); Insert.SetParam(2,NewID);
              Insert.ExecSQL;
            end;
            Q.Next;
          end;
        finally Insert.Free; end;
      finally Q.Free; end;
      CheckCanceled; FDatabase.Commit;
    except
      if FDatabase.InTransaction then FDatabase.Rollback;
      raise;
    end;
    finally FDatabase.EndQueryBatch; end;
  finally ExtraGroups.Free; Groups.Free; end;
end;

procedure TSystemData_SQLite.ImportUserData(data: TUserData);
const
  SQL_SELECT = 'SELECT GroupID FROM Groups WHERE GroupName = ? ';
  SQL_INSERT = 'INSERT INTO Groups (GroupName, AllowDelete) SELECT ?, ? ';
var
  group: TBookGroup;
  querySelect: TSQLiteQuery;
  queryInsert: TSQLiteQuery;

begin
  Assert(Assigned(data));

  querySelect := FDatabase.NewQuery(SQL_SELECT);
  try
    queryInsert := FDatabase.NewQuery(SQL_INSERT);
    try
      for group in data.Groups do
      begin
        querySelect.Reset;
        querySelect.SetParam(0, group.GroupName);
        querySelect.Open;
        if not querySelect.Eof then
          group.GroupID := querySelect.FieldAsInt(0)
        else
        begin
          queryInsert.Reset;
          queryInsert.SetParam(0, group.GroupName);
          queryInsert.SetParam(1, True);
          queryInsert.ExecSQL;
          group.GroupID := FDatabase.LastInsertRowID;
        end;
      end;

    finally
      FreeAndNil(queryInsert);
    end;
  finally
    FreeAndNil(querySelect);
  end;
end;

procedure TSystemData_SQLite.ChangeBookSeriesID(const OldSeriesID: Integer; const NewSeriesID: Integer; const DatabaseID: Integer);
const
  UPDATE_SQL = 'UPDATE Books SET SeriesID = ? WHERE DatabaseID = ? AND SeriesID = ? ';
var
  query: TSQLiteQuery;
begin
  if OldSeriesID <> NewSeriesID then
  begin
    query := FDatabase.NewQuery(UPDATE_SQL);
    try
      if NO_SERIES_ID = NewSeriesID then
        query.SetNullParam(0)
      else
        query.SetParam(0, NewSeriesID);

      query.SetParam(1, DatabaseID);

      if NO_SERIES_ID = OldSeriesID then
        query.SetNullParam(2)
      else
        query.SetParam(2, OldSeriesID);
      query.ExecSQL;
    finally
      FreeAndNil(query);
    end;
  end;
end;

function TSystemData_SQLite.GetAnnotation(const BookKey: TBookKey): string;
const
  SQL_SELECT = 'SELECT Annotation FROM Books WHERE BookID = ? AND DatabaseID = ? ';
var
  query: TSQLiteQuery;
begin
  Result := '';
  query := FDatabase.NewQuery(SQL_SELECT);
  try
    query.SetParam(0, BookKey.BookID);
    query.SetParam(1, BookKey.DatabaseID);
    query.Open;
    if not query.Eof then
      Result := query.FieldAsBlobString(0);
  finally
    query.Free;
  end;
end;

function TSystemData_SQLite.GetBookIterator(const GroupID: Integer; const DatabaseID: Integer = INVALID_COLLECTION_ID): IBookIterator;
begin
  Result := TBookIteratorImpl.Create(Self, GroupID, DatabaseID);
end;

function TSystemData_SQLite.GetGroupIterator: IGroupIterator;
begin
  Result := TGroupIteratorImpl.Create(Self);
end;

function TSystemData_SQLite.GetCollectionInfoIterator: ICollectionInfoIterator;
begin
  Result := TCollectionInfoIteratorImpl.Create(Self);
end;

procedure TSystemData_SQLite.InternalClearGroup(GroupID: Integer; RemoveGroup: Boolean);
const
  SQL_DELETE_BOOKGROUPS = 'DELETE FROM BookGroups WHERE GroupID = ? ';
  SQL_DELETE_GROUPS = 'DELETE FROM Groups WHERE GroupID = ? AND AllowDelete = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL_DELETE_BOOKGROUPS);
  try
    query.SetParam(0, GroupID);
    query.ExecSQL;
  finally
    FreeAndNil(query);
  end;

  RemoveUnusedBooks;

  if RemoveGroup then
  begin
    query := FDatabase.NewQuery(SQL_DELETE_GROUPS);
    try
      query.SetParam(0, GroupID);
      query.SetParam(1, True); // Delete only if AllowDelete is true
      query.ExecSQL;
    finally
      FreeAndNil(query);
    end;
  end;
end;

function TSystemData_SQLite.InternalFindGroup(GroupID: Integer): Boolean;
const
  SQL = 'SELECT GroupID FROM Groups WHERE GroupID = ? ';
var
  query: TSQLiteQuery;
begin
  query := FDatabase.NewQuery(SQL);
  try
    query.SetParam(0, GroupID);
    query.Open;
    Result := not query.Eof;
  finally
    FreeAndNil(query);
  end;
end;

procedure TSystemData_SQLite.PrepareCollectionPath(var CollectionRoot, CollectionFile: string);
begin
  CollectionRoot := Settings.ExpandCollectionRoot(CollectionRoot);
  CollectionFile := Settings.ExpandCollectionFileName(CollectionFile);




  //
  CollectionRoot := ExtractRelativePath(Settings.WorkPath, CollectionRoot);
  CollectionFile := ExtractRelativePath(Settings.DataPath, CollectionFile);
end;

end.
