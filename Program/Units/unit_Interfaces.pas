(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           eg_
  *                     Nick Rymanov (nrymanov@gmail.com)
  * Created             03.09.2010
  * Description
  *
  * $Id: unit_Interfaces.pas 1131 2013-12-04 10:12:58Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_Interfaces;

interface

uses
  Classes, System.SysUtils,
  unit_Globals,
  unit_Consts,
  unit_UserData,
  unit_MetadataSyncTypes;

type
  TBookIdentityPredicate = reference to function(const Current: TBookRecord): Boolean;
  TBookPersonalField = (bpfRate, bpfProgress, bpfReview, bpfAnnotation, bpfIsLocal);
  TBookPersonalFields = set of TBookPersonalField;
  TBookIdentityWriteResult = (biwUnavailable, biwNoCard, biwMismatch, biwSaved);

  // Update selected personal fields on a proved current row. The other fields,
  // reviews and binary card payload remain untouched.
  IBookIdentityPersonalWriter = interface
    ['{F8819C6B-BBCB-4658-B455-4D7B988A43F2}']
    function TrySetIdentityPersonal(const Expected: TBookRecord;
      const Fields: TBookPersonalFields; const Matches: TBookIdentityPredicate;
      RequirePersonal: Boolean = False): TBookIdentityWriteResult;
  end;

  // Progress is allowed only when the identity still matches inside the
  // writer's own transaction. Unsupported/busy/unavailable writers fail closed.
  IBookIdentityProgressWriter = interface
    ['{4B934550-DBE3-498E-A04C-2440C45B867D}']
    function TrySetIdentityProgress(const Expected: TBookRecord; Progress: Integer;
      const Matches: TBookIdentityPredicate): Boolean;
  end;

  // Optional snapshot of existing user cards; merges never create absent cards.
  ISystemBookPresence = interface
    ['{D4977BE5-9C8F-44F0-A21C-CC7D46B79BD7}']
    function StoredBookIDs(const CollectionID: Integer): TArray<Integer>;
  end;

  // Sequential, read-only relations for an immutable catalogue. Book IDs must
  // be requested in nondecreasing order; no whole-catalogue relation cache.
  IBookSeriesReadStream = interface
    function ReadBook(BookID: Integer): TBookSeries;
  end;

  // Within a bulk transaction, merge updates metadata with already resolved
  // author/genre memberships, retaining existing cycle identities.
  IBookMergeMetadataUpdater = interface
    ['{943BD756-A71C-42B3-B7A9-A06186B2B63B}']
    procedure UpdateBookPreservingSeries(BookRecord: TBookRecord);
  end;

  // A validated merge already holds the previous metadata. Update only
  // changed columns, preserving the independent memberships and user cards.
  IBookMergeMetadataDeltaUpdater = interface
    ['{82BA3C11-97A7-48A9-B910-72831452CFC8}']
    procedure UpdateBookMetadataDelta(const Before: TBookRecord; BookRecord: TBookRecord; UpdateUserCard: Boolean = True);
  end;

  // Capture the pre-merge file provenance once, without replacing original
  // metadata with the preferred source selected by a later or repeated merge.
  IBookMergeOriginalCopyRecorder = interface
    ['{6C1B3BCC-45D2-490D-B9B6-1F5E4A8F7914}']
    procedure CaptureOriginalCopyIfMissing(const SourceKey, SourceName: string; const Book: TBookRecord);
  end;

  IBookSeriesStreamProvider = interface
    ['{C4621D4C-322A-4CBF-86C1-41B6BB0348E6}']
    function OpenBookSeriesReadStream: IBookSeriesReadStream;
  end;

  IIterator<T: record> = interface
    function Next(out v: T): Boolean;
    function RecordCount: Integer;
  end;

  IObjectIterator<T: TPersistent> = interface
    function Next(v: T): Boolean;
    function RecordCount: Integer;
  end;

  IInterfaceIterator<T: IInterface> = interface
    function Next(out v: T): Boolean;
    function RecordCount: Integer;
  end;

  IBookIterator = IIterator<TBookRecord>;
  IAuthorIterator = IIterator<TAuthorData>;
  IGenreIterator = IIterator<TGenreData>;
  ISeriesIterator = IIterator<TSeriesData>;
  IGroupIterator = IIterator<TGroupData>;
  ICollectionInfoIterator = IIterator<TCollectionInfo>;

  // Apply the usual author-browser visibility filters to a cached, indexed
  // set of favorite IDs. Empty favorites deliberately return no authors.
  IAuthorFavoriteCollectionView = interface
    ['{67760201-7A8D-46B1-A7CF-8A2EA662EC56}']
    function GetFavoriteAuthorIterator(const AuthorIDs: TArray<Integer>): IAuthorIterator;
  end;

  IPublisherSeriesIndexIterator = interface
    // Book contains source fields only, without authors, genres or memo data.
    function Next(out Book: TBookRecord; out IndexedSourceKey: string): Boolean;
    function RecordCount: Integer;
  end;

  // A short read-only SystemDB reservation prevents a concurrent collection
  // root change while catalog metadata is committed. Acquire before catalog
  // transactions; release by rollback. Existing transactions fail closed.
  IMetadataCollectionRootGuard = interface
    ['{49D2BDB5-964C-4583-9246-11F40D6A241B}']
    procedure BeginMetadataRootGuard;
    procedure EndMetadataRootGuard;
  end;

  // Additive capability: bounded source-only reads, and empty-only writes.
  // No personal card, relations, index completion marker or schema is changed.
  IBookMetadataFillWriter = interface
    ['{FFEFDF02-B767-4504-922C-39D617AEF4CD}']
    procedure BeginMetadataFillBatch;
    procedure EndMetadataFillBatch(Commit: Boolean);
    function MetadataCollectionRoot: string;
    function MetadataBookCount: Int64;
    function ReadMetadataBatch(AfterBookID, Limit: Integer): TArray<TBookRecord>;
    function FillEmptyMetadata(const Expected, Values: TBookRecord;
      const Fields: TMetadataSyncFields; const SourceStillMatches: TFunc<Boolean>;
      out Updated: TMetadataSyncFields): TMetadataFillResult;
  end;

  TGUIUpdateExtraProc = reference to procedure(
    const BookKey: TBookKey;
    extra: TBookExtra
  );

  IBookCollection = interface;

  ISystemData = interface
    ['{3896E4C6-8E2F-42F3-9FB2-91753258E9B7}']


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

    function HasCollections: Boolean;
    function HasCollectionWithProp(PropID: TPropertyID; const Value: string; IgnoreID: Integer = INVALID_COLLECTION_ID): Boolean;
    function FindFirstExistingCollectionID(const PreferredID: Integer): Integer;

    procedure SetProperty(const CollectionID: Integer; const PropID: TPropertyID; const Value: Variant);
    function GetProperty(const CollectionID: Integer; const PropID: TPropertyID): Variant;

    function GetCollectionInfo(const CollectionID: Integer): TCollectionInfo;

    function GetCollection(const CollectionID: Integer; const RefreshCache: Boolean = False): IBookCollection;

    function ActivateGroup(const ID: Integer): Boolean;

    procedure GetBookRecord(const BookKey: TBookKey; var BookRecord: TBookRecord);
    procedure DeleteBook(const BookKey: TBookKey);
    procedure UpdateBook(const BookRecord: TBookRecord);

    procedure SetExtra(const BookKey: TBookKey; extra: TBookExtra);
    procedure SetRate(const BookKey: TBookKey; Rate: Integer);
    procedure SetProgress(const BookKey: TBookKey; Progress: Integer);

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
    // Привести BookID книг в группах к текущей нумерации коллекции (сверка по LibID).
    // Вызывается после переимпорта коллекции и при построении списка группы.
    // Отсутствующие книги со стабильным LibID сохраняются как недоступные;
    // личные карточки, заметки и членство в группах не удаляются.
    // RemoveMissing сохранён для совместимости существующих вызовов.
    // Возвращает количество исправленных записей.
    function RemapCollectionBookIDs(const DatabaseID: Integer; const RemoveMissing: Boolean = False): Integer;

    procedure ImportUserData(data: TUserData);
    procedure ExportUserData(data: TUserData; const DatabaseID: Integer);

    procedure ChangeBookSeriesID(const OldSeriesID: Integer; const NewSeriesID: Integer; const DatabaseID: Integer);

    function GetBookIterator(const GroupID: Integer; const DatabaseID: Integer = INVALID_COLLECTION_ID): IBookIterator;
    function GetGroupIterator: IGroupIterator;
    function GetCollectionInfoIterator: ICollectionInfoIterator;

    function GetDataRevision: string;
    procedure BeginDataUpdate;
    procedure EndDataUpdate(Commit: Boolean);
    procedure ClearCollectionCache;
    procedure RemoveUnusedBooks;
  end;

  IBookCollection = interface
    ['{B1BB5762-2942-48C3-90E3-3154405EC01B}']

    function GetAuthorIterator(const Mode: TAuthorIteratorMode; const FilterValue: PFilterValue = nil): IAuthorIterator;
    function GetGenreIterator(const Mode: TGenreIteratorMode; const FilterValue: PFilterValue = nil): IGenreIterator;
    function GetSeriesIterator(const Mode: TSeriesIteratorMode): ISeriesIterator;
    function GetPublisherSeriesIterator(const FilterText: string = '';
      const GenreCode: string = ''): ISeriesIterator;
    function GetPublisherSeriesIndexIterator: IPublisherSeriesIndexIterator;
    function GetBookIterator(const Mode: TBookIteratorMode; const LoadMemos: Boolean; const FilterValue: PFilterValue = nil): IBookIterator;
    function Search(const SearchCriteria: TBookSearchCriteria; const LoadMemos: Boolean): IBookIterator;



    procedure UpdateAuthor(Author : PAuthorData);
    function InsertBook(BookRecord: TBookRecord; const CheckFileName: Boolean;
      const FullCheck: Boolean): Integer; overload;
    function InsertBook(BookRecord: TBookRecord; const CheckFileName: Boolean;
      const FullCheck: Boolean; Cache: TImportCache): Integer; overload;
    procedure GetBookRecord(const BookKey: TBookKey; out BookRecord: TBookRecord; const LoadMemos: Boolean);
    function GetBookSeries(const BookKey: TBookKey): TBookSeries;
    function GetBookPublisherSeries(const BookKey: TBookKey): TBookSeries;
    procedure SetBookPublisherSeries(const BookKey: TBookKey; const Series: TBookSeries);
    // Atomically store complete series (including empty), fill a missing
    // publisher and certify the source. Production indexing supplies its
    // captured book identity so reused IDs or moved roots cannot be certified.
    procedure CompletePublisherSeriesIndex(const BookKey: TBookKey;
      const Series: TBookSeries; const SourceKey: string; const Publisher: string = '';
      const ExpectedBook: PBookRecord = nil);
    procedure AddBookSeries(const BookID: Integer; const SeriesTitle: string;
      const SeqNumber: Integer; Cache: TImportCache = nil);
    // Проверить/восстановить BookID книги по стабильному LibID:
    // BookID переприсваивается при полном переимпорте коллекции, LibID - нет.
    // Возвращает CurrentBookID, если он всё ещё указывает на книгу с этим LibID,
    // иначе - актуальный BookID (0, если книги в коллекции нет).
    function ResolveBookID(const LibID: string; const CurrentBookID: Integer): Integer;
    function GetCatalogRevision: string;
    procedure RestoreCollectionBackup(const FileName: string);
    function GetCatalogBookID(const SourceKey: string): Integer;
    procedure SetCatalogBookID(const SourceKey: string; BookID: Integer);
    procedure SetCatalogBookCopy(const SourceKey, SourceName: string; const Book: TBookRecord);
    procedure SetCatalogBookPreferredSource(const BookKey: TBookKey; const SourceName: string);
    function GetCatalogBookCopies(const BookKey: TBookKey): TArray<TBookRecord>;
    procedure UpdateBook(BookRecord: TBookRecord);
    procedure DeleteBook(const BookKey: TBookKey);
    procedure AddBookToGroup(const BookKey: TBookKey; const GroupID: Integer);


    function GetReview(const BookKey: TBookKey): string;

    function SetReview(const BookKey: TBookKey; const Review: string): Integer;
    procedure SetAnnotation(const BookKey: TBookKey; const Annotation: string);
    procedure SetProgress(const BookKey: TBookKey; const Progress: Integer);
    procedure SetRate(const BookKey: TBookKey; const Rate: Integer);
    procedure SetLocal(const BookKey: TBookKey; const AState: Boolean);
    procedure SetFolder(const BookKey: TBookKey; const Folder: string);
    procedure SetFileName(const BookKey: TBookKey; const FileName: string);
    procedure SetSeriesID(const BookKey: TBookKey; const SeriesID: Integer);

    function EnsureAuthor(const Author: TAuthorData): TAuthorData;
    procedure SetBookAuthors(const BookID: Integer; const Authors: TBookAuthors; Replace: Boolean);
    procedure SetBookGenres(const BookID: Integer; const Genres: TBookGenres; Replace: Boolean);

    function FindOrCreateSeries(const Title: string): Integer;
    procedure SetSeriesTitle(const SeriesID: Integer; const NewSeriesTitle: string);
    procedure ChangeBookSeriesID(const OldSeriesID: Integer; const NewSeriesID: Integer; const DatabaseID: Integer);

    function CollectionID: Integer;
    function CollectionCode: COLLECTION_TYPE;
    function CollectionRoot: string;
    function CollectionDisplayName: string;
    function CollectionURL: string;

    // Ссылка на книгу на сайте библиотеки. Формат зависит от привязки
    // конкретной библиотеки, поэтому его формирует сама коллекция, а не интерфейс.
    function GetViewURL(const LibID: string): string;
    function GetEditURL(const LibID: string): string;

    procedure SetProperty(const PropID: TPropertyID; const Value: Variant);
    function GetProperty(const PropID: TPropertyID): Variant;
    procedure UpdateProperies;

    procedure ImportUserData(data: TUserData; guiUpdateCallback: TGUIUpdateExtraProc);
    procedure ExportUserData(data: TUserData);

    function CheckFileInCollection(const FileName: string; const FullNameSearch: Boolean; const ZipFolder: Boolean): Boolean;

    procedure BeginBulkOperation;
    function InBulkOperation: Boolean;
    procedure EndBulkOperation(Commit: Boolean = True);

    procedure CompactDatabase;
    function CheckDatabase: string;

    function GetTopGenreAlias(const FB2Code: string): string;
    procedure ReloadGenres(const FileName: string);
    procedure LoadGenres(const GenresFileName: string);
    function EnsureGenre(const FB2Code, Alias, Category: string): TGenreData;

    procedure GetStatistics(out AuthorsCount: Integer; out BooksCount: Integer; out SeriesCount: Integer);

    procedure TruncateTablesBeforeImport;

    procedure StartBatchUpdate;
    procedure AfterBatchUpdate;
    procedure FinishBatchUpdate;

    procedure VerifyCurrentCollection(const DatabaseID: Integer);

    procedure SetHideDeleted(const HideDeleted: Boolean);
    function GetHideDeleted: Boolean;
    procedure SetShowLocalOnly(const ShowLocalOnly: Boolean);
    function GetShowLocalOnly: Boolean;
    procedure SetSeriesFilterType(const SeriesFilterType: string);
    function GetSeriesFilterType: string;
    procedure SetAuthorFilterType(const AuthorFilterType: string);
    function GetAuthorFilterType: string;
  end;

{$IFDEF USELOGGER}
  ILogger = interface
    ['{E0BE38F4-2911-4FD7-8CA2-B6E3981BBFC0}']
    procedure Log(const logMessage: string; const extraInfo: string);
  end;

  IIntervalLogger = interface(ILogger)
    ['{F1E77E3D-7D8C-421D-9647-8E11B9105271}']
    procedure Restart(const extraInfo: string);
  end;

  IScopeLogger = interface(ILogger)
    ['{B3497AEA-D495-4425-8C1A-24EBA789E3DE}']
  end;
{$ENDIF}

  IParamsParser<T> = interface
    function CheckLiteral(const literalValue: string): Boolean;
    function CheckParam(const paramName: string): Boolean;
    function GetValue(const params: T; const paramName: string): string;
  end;

implementation

end.
