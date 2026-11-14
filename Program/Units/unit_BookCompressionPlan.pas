unit unit_BookCompressionPlan;

interface

uses System.SysUtils, System.JSON, System.Generics.Collections, SQLiteWrap,
  unit_BookCompressionPlanStore;

type
  TCompressionLocator = record
    Kind, BookID, InsideNo: Integer;
    LibID, Folder, FileName, Extension, Root, SourceKey: string;
    OldSize: Int64;
    function SameBook(const Other: TCompressionLocator): Boolean;
    function AsJSON(const Member: string): TJSONObject;
  end;

  TCompressionPlanOptions = record
    CollectionID: Integer;
    Catalogue, Personal, CollectionRoot, BaseRoot, BaseCatalogue: string;
  end;

  // The application supplies its existing book-path/member resolver. Keeping
  // it separate avoids a second interpretation of linked books, FBD and the
  // legacy ZIP-to-7z fallback without borrowing UI-owned database connections.
  TCompressionSourceResolver = reference to function(const Row: TCompressionLocator): string;
  TCompressionMemberResolver = reference to function(const Source: string;
    const Row: TCompressionLocator): string;

  TCompressionFilePlan = class
  private
    FSource, FFileKey, FSourceIdentity: string;
    FMembers, FPrevious: TJSONObject;
    FRows: TJSONArray;
    FTemplate: TJSONObject;
    procedure AddMember(const Member, Extension: string);
    procedure AddRow(const Row: TCompressionLocator; const Member: string);
    procedure AddFuturePersonalRows;
  public
    constructor Create(const Source: string; Template: TJSONObject);
    destructor Destroy; override;
    procedure CheckSource;
    function AlreadyChecked(const Profile: string; Grayscale: Boolean; const EngineSHA256: string;
      const Cancelled: TFunc<Boolean> = nil; const Progress: TProc<Int64,Int64> = nil): Boolean;
    function CreateRequest(const Workspace, ReportFile, SevenZip, ToolsRoot,
      Profile: string; Grayscale: Boolean): TJSONObject;
    function ReceiptTemplate: string;
    function MemberCount: Integer;
    function RowCount: Integer;
    property Source: string read FSource;
    property FileKey: string read FFileKey;
    property SourceIdentity: string read FSourceIdentity;
  end;

  // Captures all matching main/personal/copy rows in one read-only scan.
  // Each physical archive is a single work item, regardless of the number of
  // selected books and catalogue aliases inside it. No whole database copy.
  TBookCompressionPlan = class
  private
    FFiles: TObjectList<TCompressionFilePlan>;
    FOptions: TCompressionPlanOptions;
    FCatalogueKey, FPersonalKey: string;
    FStore: TCompressionPlanStore;
    FCancelled: TFunc<Boolean>;
    FWarning: string;
    FSkippedRows: Int64;
    FPreviouslyProcessedBooks: Int64;
    function NewTemplate: TJSONObject;
    procedure CompleteFile(FilePlan: TCompressionFilePlan);
    procedure CheckCancelled;
  public
    constructor Create(const Options: TCompressionPlanOptions;
      const Selected: TArray<TCompressionLocator>;
      const SourceFor: TCompressionSourceResolver;
      const MemberFor: TCompressionMemberResolver;
      const Cancelled: TFunc<Boolean> = nil;
      const Progress: TProc<Int64> = nil);
    constructor CreateCollection(const Options: TCompressionPlanOptions; const WorkRoot: string;
      const SourceFor: TCompressionSourceResolver; const MemberFor: TCompressionMemberResolver;
      const Cancelled: TFunc<Boolean> = nil; const Progress: TProc<Int64> = nil);
    destructor Destroy; override;
    function FileCount: Int64;
    function BookCount: Int64;
    procedure ForEachFile(const Visit: TProc<TCompressionFilePlan>);
    procedure SelectUnprocessed(const Profile: string; Grayscale: Boolean;
      const EngineSHA256: string; const Progress: TProc<Int64,Int64> = nil);
    property Files: TObjectList<TCompressionFilePlan> read FFiles;
    property Warning: string read FWarning;
    property SkippedRows: Int64 read FSkippedRows;
    property PreviouslyProcessedBooks: Int64 read FPreviouslyProcessedBooks;
  end;

implementation

uses System.IOUtils, System.Classes, System.Hash, unit_BookCompressionReceipt,
  unit_ZipMemberDeletion, unit_BookCompressionImages;

function TCompressionLocator.SameBook(const Other: TCompressionLocator): Boolean;
begin
  Result:=(Kind=Other.Kind) and (BookID=Other.BookID) and (LibID=Other.LibID) and
    (Folder=Other.Folder) and (FileName=Other.FileName) and
    (Extension=Other.Extension) and (InsideNo=Other.InsideNo) and
    (Root=Other.Root) and (SourceKey=Other.SourceKey);
end;

function TCompressionLocator.AsJSON(const Member: string): TJSONObject;
begin
  Result:=TJSONObject.Create;
  Result.AddPair('kind',TJSONNumber.Create(Kind));
  Result.AddPair('id',TJSONNumber.Create(BookID));
  Result.AddPair('lib_id',LibID); Result.AddPair('folder',Folder);
  Result.AddPair('file_name',FileName); Result.AddPair('ext',Extension);
  Result.AddPair('inside_no',TJSONNumber.Create(InsideNo));
  Result.AddPair('old_size',TJSONNumber.Create(OldSize));
  Result.AddPair('root',Root); Result.AddPair('source_key',SourceKey);
  Result.AddPair('member',Member);
  Result.AddPair('required',TJSONBool.Create(Kind<>1));
end;

constructor TCompressionFilePlan.Create(const Source: string; Template: TJSONObject);
begin
  inherited Create;
  FTemplate:=Template;
  FSource:=ExpandFileName(Source);
  FSourceIdentity:=ArchiveDeletionSourceIdentity(FSource);
  FFileKey:=CompressionFileKey(FSource);
  FMembers:=TJSONObject.Create; FPrevious:=TJSONObject.Create;
  FRows:=TJSONArray.Create;
  FTemplate.AddPair('source',FSource);
  FTemplate.AddPair('source_file_key',FFileKey);
end;

destructor TCompressionFilePlan.Destroy;
begin
  FTemplate.Free; FRows.Free; FMembers.Free; FPrevious.Free;
  inherited;
end;

procedure TCompressionFilePlan.CheckSource;
begin
  if ArchiveDeletionSourceIdentity(FSource)<>FSourceIdentity then
    raise EReadError.Create('Файл книги изменился после выбора. Начните сжатие заново: '+FSource);
end;

function TCompressionFilePlan.AlreadyChecked(const Profile: string; Grayscale: Boolean; const EngineSHA256: string;
  const Cancelled: TFunc<Boolean>; const Progress: TProc<Int64,Int64>): Boolean;
var DB: TSQLiteDatabase; Query: TSQLiteQuery; Source: TFileStream;
    Expected, ImageStamp, ImageSnapshot: string; Hash: THashSHA2; Bytes: TBytes; Count: Integer;
begin
  Result:=False; CheckSource;
  if CompressionFileKey(FTemplate.GetValue<string>('catalogue'))<>
    FTemplate.GetValue<string>('catalogue_key') then
    raise EReadError.Create('Каталог изменился после выбора книг. Повторите сжатие.');
  DB:=TSQLiteDatabase.CreateReadOnly(FTemplate.GetValue<string>('catalogue'));
  try
    if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND '+
      'name=''HomeLibreCompressionChecks''')=0 then Exit;
    Expected:=''; ImageStamp:=CompressionImageStamp(FSource); ImageSnapshot:='';
    if (ImageStamp<>'') and (DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' '+
      'AND name=''HomeLibreCompressionDependencies''')=0) then Exit;
    if ImageStamp<>'' then
    begin
      if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' '+
        'AND name=''HomeLibreCompressionImageSets''')=0 then Exit;
      ImageSnapshot:=DB.QuerySingleString('SELECT SourcesJSON FROM HomeLibreCompressionImageSets WHERE FileKey=? AND Stamp=?',
        [UpperCase(FFileKey),ImageStamp]);
      if ImageSnapshot='' then Exit;
    end;
    for var Pair in FMembers do
    begin
      if Assigned(Cancelled) and Cancelled() then Abort;
      if (ImageStamp<>'') and (DB.QuerySingleInt('SELECT count(*) FROM HomeLibreCompressionDependencies '+
        'WHERE FileKey=? AND Member=? AND Profile=? AND Grayscale=? AND EngineSHA256=? AND Stamp=?',
        [UpperCase(FFileKey),Pair.JsonString.Value,LowerCase(Profile),Ord(Grayscale),EngineSHA256,ImageStamp])<>1) then Exit;
      Query:=DB.NewQuery('SELECT SourceIdentity,SourceSHA256 FROM HomeLibreCompressionChecks '+
        'WHERE FileKey=? AND Member=? AND Profile=? AND Grayscale=? AND EngineSHA256=?',
        [UpperCase(FFileKey),Pair.JsonString.Value,LowerCase(Profile),Ord(Grayscale),EngineSHA256]);
      try
        Query.Open;
        // Size/key changes cannot be a hit. Timestamp-only changes still use
        // the checksum below, which can prove that no payload changed.
        if Query.Eof or (Copy(Query.FieldAsString(0),1,43)<>Copy(FSourceIdentity,1,43)) then Exit;
        if Expected='' then Expected:=Query.FieldAsString(1)
        else if Expected<>Query.FieldAsString(1) then Exit;
      finally Query.Free; end;
    end;
  finally DB.Free; end;
  if (FMembers.Count=0) or (Length(Expected)<>64) then Exit;
  // A restored timestamp or same-sized changed archive must not yield a hit.
  // This reads packed bytes only, without extraction, re-encoding or writes.
  Source:=TFileStream.Create(DeletionNativePath(FSource),fmOpenRead or fmShareDenyWrite);
  try
    CheckSource; Hash:=THashSHA2.Create; SetLength(Bytes,1024*1024);
    repeat
      if Assigned(Cancelled) and Cancelled() then Abort;
      Count:=Source.Read(Bytes[0],Length(Bytes));
      if Count>0 then Hash.Update(Bytes[0],Count);
      if Assigned(Progress) then Progress(Source.Position,Source.Size);
    until Count=0;
    CheckSource;
    if CompressionFileKey(FTemplate.GetValue<string>('catalogue'))<>
      FTemplate.GetValue<string>('catalogue_key') then
      raise EReadError.Create('Каталог изменился после выбора книг. Повторите сжатие.');
    Result:=SameText(Hash.HashAsString,Expected);
    if Result and (ImageStamp<>'') then
      Result:=CompressionImageSnapshotMatches(FSource,ImageSnapshot,True);
  finally Source.Free; end;
end;

procedure TCompressionFilePlan.AddMember(const Member, Extension: string);
begin
  // Hints can differ between aliases. The producer detects the actual format
  // from content, and never changes an archive member's spelling or extension.
  if FMembers.GetValue(Member)=nil then FMembers.AddPair(Member,Extension);
end;

procedure TCompressionFilePlan.AddRow(const Row: TCompressionLocator; const Member: string);
begin
  if FRows.Count>=100000 then
    raise EReadError.Create('Слишком много записей относится к одному файлу сжатия.');
  FRows.AddElement(Row.AsJSON(Member));
end;

procedure TCompressionFilePlan.AddFuturePersonalRows;
var Seen:TDictionary<Integer,Byte>; Row, Mirror:TJSONObject; ID, Count:Integer;
begin
  // Opening/annotating a book while the producer runs can create its first
  // personal card. Include an optional primary locator without copying any
  // notes, so the receipt can update its size while retaining the new data.
  Seen:=TDictionary<Integer,Byte>.Create;
  try
    for var Value in FRows do
    begin
      Row:=TJSONObject(Value);
      if Row.GetValue<Integer>('kind')=1 then Seen.AddOrSetValue(Row.GetValue<Integer>('id'),0);
    end;
    Count:=FRows.Count;
    for var I:=0 to Count-1 do
    begin
      Row:=TJSONObject(FRows.Items[I]); ID:=Row.GetValue<Integer>('id');
      if (Row.GetValue<Integer>('kind')<>0) or Seen.ContainsKey(ID) then Continue;
      if FRows.Count>=100000 then raise EReadError.Create('Слишком много записей относится к одному файлу сжатия.');
      Mirror:=TJSONObject(Row.Clone);
      Mirror.RemovePair('kind').Free; Mirror.AddPair('kind',TJSONNumber.Create(1));
      Mirror.RemovePair('required').Free; Mirror.AddPair('required',TJSONBool.Create(False));
      FRows.AddElement(Mirror); Seen.Add(ID,0);
    end;
  finally Seen.Free; end;
end;

function TCompressionFilePlan.ReceiptTemplate: string;
var Data: TJSONObject;
begin
  Data:=TJSONObject(FTemplate.Clone);
  try Data.AddPair('rows',TJSONArray(FRows.Clone)); Result:=Data.ToJSON;
  finally Data.Free; end;
end;

function TCompressionFilePlan.CreateRequest(const Workspace, ReportFile, SevenZip,
  ToolsRoot, Profile: string; Grayscale: Boolean): TJSONObject;
begin
  CheckSource;
  Result:=TJSONObject.Create;
  try
    Result.AddPair('version',TJSONNumber.Create(1));
    Result.AddPair('source',FSource);
    Result.AddPair('members',TJSONObject(FMembers.Clone));
    Result.AddPair('workspace',ExpandFileName(Workspace));
    Result.AddPair('report',ExpandFileName(ReportFile));
    Result.AddPair('seven_zip',ExpandFileName(SevenZip));
    Result.AddPair('tools_root',ExpandFileName(ToolsRoot));
    Result.AddPair('profile',Profile);
    Result.AddPair('grayscale',TJSONBool.Create(Grayscale));
    Result.AddPair('previous',TJSONObject(FPrevious.Clone));
    Result.AddPair('receipt_template',TJSONObject.ParseJSONValue(ReceiptTemplate));
  except Result.Free; raise; end;
end;

function TCompressionFilePlan.MemberCount: Integer;
begin Result:=FMembers.Count; end;

function TCompressionFilePlan.RowCount: Integer;
begin Result:=FRows.Count; end;

function ReadLocator(Query: TSQLiteQuery; Kind: Integer): TCompressionLocator;
begin
  Result:=Default(TCompressionLocator);
  Result.Kind:=Kind; Result.BookID:=Query.FieldAsInt(0);
  Result.LibID:=Query.FieldAsString(1); Result.Folder:=Query.FieldAsString(2);
  Result.FileName:=Query.FieldAsString(3); Result.Extension:=Query.FieldAsString(4);
  Result.InsideNo:=Query.FieldAsInt(5); Result.OldSize:=Query.FieldAsInt(6);
  if Kind=2 then
  begin Result.Root:=Query.FieldAsString(7); Result.SourceKey:=Query.FieldAsString(8); end;
  if (Result.BookID<=0) or (Result.OldSize<0) then
    raise EReadError.Create('Некорректная запись книги при подготовке сжатия.');
end;

function TBookCompressionPlan.NewTemplate:TJSONObject;
begin
  Result:=TJSONObject.Create;
  Result.AddPair('schema',TJSONNumber.Create(1));
  Result.AddPair('kind','HomeLibre book compression');
  Result.AddPair('collection_id',TJSONNumber.Create(FOptions.CollectionID));
  Result.AddPair('catalogue',FOptions.Catalogue); Result.AddPair('personal',FOptions.Personal);
  Result.AddPair('catalogue_key',FCatalogueKey); Result.AddPair('personal_key',FPersonalKey);
  Result.AddPair('base_root',FOptions.BaseRoot); Result.AddPair('base_catalogue',FOptions.BaseCatalogue);
end;

procedure TBookCompressionPlan.CheckCancelled;
begin
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Сжатие остановлено. Исходные книги не изменены.');
end;

function CompressionLedgerSQL(DB:TSQLiteDatabase):string;
begin
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND '+
    'name=''HomeLibreCompressionOutcomes''')<>0 then
    Result:='SELECT h.Member,h.ProfileSHA256,h.OutputSHA256,coalesce(o.RetryOriginal,0) '+
      'FROM HomeLibreBookCompression h LEFT JOIN HomeLibreCompressionOutcomes o ON '+
      'o.FileKey=h.FileKey AND o.Member=h.Member AND o.ProfileSHA256=h.ProfileSHA256 '+
      'AND o.OutputSHA256=h.OutputSHA256 WHERE h.FileKey=?'
  else Result:='SELECT Member,ProfileSHA256,OutputSHA256,0 FROM HomeLibreBookCompression WHERE FileKey=?';
end;

procedure TBookCompressionPlan.CompleteFile(FilePlan:TCompressionFilePlan);
var Catalogue:TSQLiteDatabase; Query:TSQLiteQuery;
begin
  CheckCancelled; FilePlan.CheckSource; FilePlan.AddFuturePersonalRows;
  if FilePlan.RowCount=0 then raise EReadError.Create('В каталоге не осталось выбранных книг.');
  Catalogue:=TSQLiteDatabase.CreateReadOnly(FOptions.Catalogue);
  try
    if Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibreBookCompression''')=0 then Exit;
    Query:=Catalogue.NewQuery(CompressionLedgerSQL(Catalogue),
      [FilePlan.FileKey]);
    try
      Query.Open;
      while not Query.Eof do
      begin
        CheckCancelled;
        var Previous:=TJSONObject.Create;
        Previous.AddPair('profile_sha256',Query.FieldAsString(1));
        Previous.AddPair('output_sha256',Query.FieldAsString(2));
        Previous.AddPair('retry_original',TJSONBool.Create(Query.FieldAsInt(3)<>0));
        FilePlan.FPrevious.AddPair(Query.FieldAsString(0),Previous);
        Query.Next;
      end;
    finally Query.Free; end;
  finally Catalogue.Free; end;
end;

constructor TBookCompressionPlan.Create(const Options: TCompressionPlanOptions;
  const Selected: TArray<TCompressionLocator>;
  const SourceFor: TCompressionSourceResolver;
  const MemberFor: TCompressionMemberResolver;
  const Cancelled: TFunc<Boolean>; const Progress: TProc<Int64>);
const Columns='BookID,LibID,Folder,FileName,Ext,InsideNo,BookSize';
var Catalogue, Personal: TSQLiteDatabase; Query: TSQLiteQuery;
    ByKey, ByPath: TDictionary<string,TCompressionFilePlan>;
    Names, Seen: TDictionary<string,Byte>;
    Row: TCompressionLocator; Source, Member, Key: string;
    FilePlan: TCompressionFilePlan; Done: Int64;
  procedure CheckCancel;
  begin
    if Assigned(Cancelled) and Cancelled() then
      raise EAbort.Create('Сжатие остановлено. Исходные книги не изменены.');
  end;
  procedure Scan(DB: TSQLiteDatabase; const SQL: string; Kind: Integer);
  var Q: TSQLiteQuery; Locator: TCompressionLocator; Path, Physical, Exact: string;
      Target: TCompressionFilePlan;
  begin
    Q:=DB.NewQuery(SQL);
    try
      Q.Open;
      while not Q.Eof do
      begin
        CheckCancel; Inc(Done);
        if Assigned(Progress) and (Done mod 1024=0) then Progress(Done);
        Locator:=ReadLocator(Q,Kind);
        if Locator.FileName<>'' then
        begin
          Path:=ExpandFileName(SourceFor(Locator));
          if not ByPath.TryGetValue(Path,Target) then
          begin
            Target:=nil;
            // Only a same-name path can be another route through a junction
            // to one of these ordinary (non-hardlinked) source files. Do not
            // open a million unrelated loose books just to match aliases.
            if Names.ContainsKey(LowerCase(ExtractFileName(Path))) and FileExists(Path) then
            begin
              Physical:=LowerCase(CompressionFileKey(Path));
              ByKey.TryGetValue(Physical,Target);
            end;
            // Cache archive paths, not every unrelated loose-book path.
            if Names.ContainsKey(LowerCase(ExtractFileName(Path))) then
              ByPath.Add(Path,Target);
          end;
          if Assigned(Target) then
          begin
            Exact:=MemberFor(Path,Locator);
            if Target.FMembers.GetValue(Exact)<>nil then Target.AddRow(Locator,Exact);
          end;
        end;
        Q.Next;
      end;
    finally Q.Free; end;
  end;
begin
  inherited Create;
  FCancelled:=Cancelled;
  FFiles:=TObjectList<TCompressionFilePlan>.Create(True);
  if (Options.CollectionID<=0) or (Length(Selected)=0) or
    not Assigned(SourceFor) or not Assigned(MemberFor) or
    (Options.BaseCatalogue='') then
    raise EArgumentException.Create('Нужно выбрать локальные книги для сжатия.');
  FOptions:=Options;
  FOptions.Catalogue:=ExpandFileName(Options.Catalogue);
  FOptions.Personal:=ExpandFileName(Options.Personal);
  FCatalogueKey:=CompressionFileKey(FOptions.Catalogue);
  FPersonalKey:=CompressionFileKey(FOptions.Personal);
  if SameText(FCatalogueKey,FPersonalKey) then
    raise EReadError.Create('Каталог и личные данные должны храниться в разных базах.');
  Catalogue:=nil; Personal:=nil; Query:=nil;
  ByKey:=TDictionary<string,TCompressionFilePlan>.Create;
  ByPath:=TDictionary<string,TCompressionFilePlan>.Create;
  Names:=TDictionary<string,Byte>.Create; Seen:=TDictionary<string,Byte>.Create;
  try
    CheckCancel;
    Catalogue:=TSQLiteDatabase.CreateReadOnly(FOptions.Catalogue);
    Personal:=TSQLiteDatabase.CreateReadOnly(FOptions.Personal);
    Catalogue.ExecSQL('BEGIN'); Personal.ExecSQL('BEGIN');
    Query:=Personal.NewQuery('SELECT RootFolder,DBFileName FROM Bases WHERE DatabaseID=?',
      [FOptions.CollectionID]);
    Query.Open;
    if Query.Eof or (Query.FieldAsString(0)<>FOptions.BaseRoot) or
      (Query.FieldAsString(1)<>FOptions.BaseCatalogue) then
      raise EReadError.Create('Подключение коллекции изменилось. Выберите книги заново.');
    FreeAndNil(Query);
    for var Expected in Selected do
    begin
      CheckCancel;
      if Expected.Kind<>0 then
        raise EReadError.Create('Выбор должен относиться к основным книгам каталога.');
      Query:=Catalogue.NewQuery('SELECT '+Columns+' FROM Books WHERE BookID=?',[Expected.BookID]);
      Query.Open;
      if Query.Eof then raise EReadError.Create('Выбранной книги больше нет в каталоге.');
      Row:=ReadLocator(Query,0); FreeAndNil(Query);
      if not Row.SameBook(Expected) then
        raise EReadError.Create('Выбранная книга изменилась. Выберите её заново.');
      Key:=IntToStr(Row.BookID);
      if Seen.ContainsKey(Key) then Continue;
      Seen.Add(Key,0);
      Source:=ExpandFileName(SourceFor(Row));
      Member:=MemberFor(Source,Row);
      Key:=LowerCase(CompressionFileKey(Source));
      if not ByKey.TryGetValue(Key,FilePlan) then
      begin
        FilePlan:=TCompressionFilePlan.Create(Source,NewTemplate);
        FFiles.Add(FilePlan); ByKey.Add(Key,FilePlan);
        Names.AddOrSetValue(LowerCase(ExtractFileName(Source)),0);
      end;
      ByPath.AddOrSetValue(Source,FilePlan);
      FilePlan.AddMember(Member,Row.Extension);
    end;
    Done:=0;
    Scan(Personal,'SELECT '+Columns+' FROM Books WHERE DatabaseID='+IntToStr(FOptions.CollectionID),1);
    // Release the personal read transaction before the potentially long main
    // catalogue scan. Reader bookmarks/notes must not wait on that scan.
    FreeAndNil(Personal);
    Scan(Catalogue,'SELECT '+Columns+' FROM Books',0);
    if Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')<>0 then
      Scan(Catalogue,'SELECT '+Columns+',Root,SourceKey FROM CatalogBookCopies',2);
    for FilePlan in FFiles do
    begin
      CheckCancel; FilePlan.CheckSource; FilePlan.AddFuturePersonalRows;
      if FilePlan.RowCount=0 then raise EReadError.Create('В каталоге не осталось выбранных книг.');
      if Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibreBookCompression''')<>0 then
      begin
        Query:=Catalogue.NewQuery(CompressionLedgerSQL(Catalogue),
          [FilePlan.FileKey]);
        Query.Open;
        while not Query.Eof do
        begin
          var Previous:=TJSONObject.Create;
          Previous.AddPair('profile_sha256',Query.FieldAsString(1));
          Previous.AddPair('output_sha256',Query.FieldAsString(2));
          Previous.AddPair('retry_original',TJSONBool.Create(Query.FieldAsInt(3)<>0));
          FilePlan.FPrevious.AddPair(Query.FieldAsString(0),Previous);
          Query.Next;
        end;
        FreeAndNil(Query);
      end;
    end;
    if (CompressionFileKey(FOptions.Catalogue)<>FCatalogueKey) or
      (CompressionFileKey(FOptions.Personal)<>FPersonalKey) then
      raise EReadError.Create('База коллекции заменена во время подготовки сжатия.');
    if Assigned(Progress) then Progress(Done);
  finally
    Query.Free; Personal.Free; Catalogue.Free;
    Seen.Free; Names.Free; ByPath.Free; ByKey.Free;
  end;
end;

constructor TBookCompressionPlan.CreateCollection(const Options:TCompressionPlanOptions;
  const WorkRoot:string; const SourceFor:TCompressionSourceResolver;
  const MemberFor:TCompressionMemberResolver; const Cancelled:TFunc<Boolean>;
  const Progress:TProc<Int64>);
const Columns='BookID,LibID,Folder,FileName,Ext,InsideNo,BookSize';
var Catalogue,Personal:TSQLiteDatabase; Query,Paths,Rows:TSQLiteQuery;
    Cache:TDictionary<string,Int64>; Done,Pending:Int64; Examples:Integer;
  procedure ReportProgress;
  begin
    CheckCancelled;
    if Assigned(Progress) and (Done mod 1024=0) then Progress(Done);
  end;
  procedure Skipped(const Where,Reason:string; Count:Int64=1);
  var DisplayWhere:string;
  begin
    Inc(FSkippedRows,Count);
    if Examples<8 then
    begin
      // Keep the complete archive filename at the end of a long Windows path.
      // The examples remain bounded, including paths from malformed records.
      DisplayWhere:=Where;
      if Length(DisplayWhere)>320 then
        DisplayWhere:=Copy(Where,1,32)+'…'+Copy(Where,Length(Where)-286,287);
      Inc(Examples); FWarning:=FWarning+sLineBreak+DisplayWhere+': '+Copy(Reason,1,200);
    end;
  end;
  procedure FlushChunk;
  begin
    Inc(Pending);
    if Pending>=5000 then
    begin FStore.DB.ExecSQL('COMMIT'); FStore.DB.ExecSQL('BEGIN'); Pending:=0; end;
  end;
  procedure Scan(DB:TSQLiteDatabase; const SQL:string; Kind:Integer);
  var Q:TSQLiteQuery; Row:TCompressionLocator; Source,Key:string; CandidateID:Int64;
      Valid:Boolean;
  begin
    Q:=DB.NewQuery(SQL);
    try
      Q.Open;
      while not Q.Eof do
      begin
        Inc(Done); ReportProgress; Valid:=False;
        try
          Row:=ReadLocator(Q,Kind);
          if Row.FileName<>'' then
          begin
            Source:=SourceFor(Row);
            if Source='' then raise EReadError.Create('Не указан путь книги.');
            Source:=ExpandFileName(StringReplace(Source,'/','\',[rfReplaceAll]));
            // Keep spelling until physical identity is available: Windows
            // directories can explicitly be case-sensitive.
            Key:=Source; Valid:=True;
          end
          else if Kind<>1 then Skipped('Запись '+IntToStr(Row.BookID),'Не указано имя файла.');
        except
          on E:EAbort do raise;
          on E:Exception do
          begin
            if (E is EExternalException) or (E is EOutOfMemory) then raise;
            if Kind<>1 then Skipped('Запись '+IntToStr(Q.FieldAsInt(0)),E.Message);
          end;
        end;
        if Valid then
        begin
          if not Cache.TryGetValue(Key,CandidateID) then
          begin
            FStore.DB.ExecSQL('INSERT INTO Candidates(PathKey,Source,Active) VALUES(?,?,?) '+
              'ON CONFLICT(PathKey) DO UPDATE SET Active=max(Active,excluded.Active)',
              [Key,Source,Ord(Kind<>1)]);
            CandidateID:=FStore.DB.QuerySingleInt('SELECT ID FROM Candidates WHERE PathKey=?',[Key]);
            if Cache.Count>=4096 then Cache.Clear;
            Cache.Add(Key,CandidateID);
          end;
          FStore.DB.ExecSQL('INSERT INTO Locators(CandidateID,Kind,BookID,LibID,Folder,FileName,Ext,'+
            'InsideNo,BookSize,Root,SourceKey) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
            [CandidateID,Row.Kind,Row.BookID,Row.LibID,Row.Folder,Row.FileName,Row.Extension,
             Row.InsideNo,Row.OldSize,Row.Root,Row.SourceKey]);
          FlushChunk;
        end;
        Q.Next;
      end;
    finally Q.Free; end;
  end;
begin
  inherited Create; FFiles:=TObjectList<TCompressionFilePlan>.Create(True);
  FCancelled:=Cancelled;
  if (Options.CollectionID<=0) or not Assigned(SourceFor) or not Assigned(MemberFor) or
    (Options.BaseCatalogue='') then raise EArgumentException.Create('Нужна подключённая коллекция для сжатия.');
  FOptions:=Options; FOptions.Catalogue:=ExpandFileName(Options.Catalogue);
  FOptions.Personal:=ExpandFileName(Options.Personal);
  FCatalogueKey:=CompressionFileKey(FOptions.Catalogue); FPersonalKey:=CompressionFileKey(FOptions.Personal);
  if SameText(FCatalogueKey,FPersonalKey) then raise EReadError.Create('Каталог и личные данные должны храниться в разных базах.');
  Catalogue:=nil; Personal:=nil; Query:=nil; Paths:=nil; Rows:=nil;
  Cache:=TDictionary<string,Int64>.Create;
  try
    CheckCancelled;
    FStore:=TCompressionPlanStore.Create(WorkRoot);
    Catalogue:=TSQLiteDatabase.CreateReadOnly(FOptions.Catalogue);
    Personal:=TSQLiteDatabase.CreateReadOnly(FOptions.Personal);
    Query:=Personal.NewQuery('SELECT RootFolder,DBFileName FROM Bases WHERE DatabaseID=?',[FOptions.CollectionID]);
    Query.Open;
    if Query.Eof or (Query.FieldAsString(0)<>FOptions.BaseRoot) or
      (Query.FieldAsString(1)<>FOptions.BaseCatalogue) then
      raise EReadError.Create('Подключение коллекции изменилось. Начните сжатие заново.');
    FreeAndNil(Query);
    Done:=0; Pending:=0; Examples:=0;
    FStore.DB.ExecSQL('BEGIN');
    Scan(Catalogue,'SELECT '+Columns+' FROM Books',0);
    if Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')<>0 then
      Scan(Catalogue,'SELECT C.BookID,C.LibID,C.Folder,C.FileName,C.Ext,C.InsideNo,C.BookSize,C.Root,C.SourceKey '+
        'FROM CatalogBookCopies C WHERE EXISTS(SELECT 1 FROM Books B WHERE B.BookID=C.BookID)',2);
    Scan(Personal,'SELECT '+Columns+' FROM Books WHERE DatabaseID='+IntToStr(FOptions.CollectionID),1);
    FreeAndNil(Personal); FreeAndNil(Catalogue); Cache.Clear;
    FStore.DB.ExecSQL('COMMIT'); FStore.DB.ExecSQL('BEGIN'); Pending:=0;
    // Source and member resolution is grouped by candidate path. The adapter
    // needs only one archive inventory at a time, even for millions of rows.
    Paths:=FStore.DB.NewQuery('SELECT ID,Source,Active FROM Candidates ORDER BY Active DESC,ID');
    Paths.Open;
    while not Paths.Eof do
    begin
      CheckCancelled;
      var CandidateID:=Paths.FieldAsInt(0); var Source:=Paths.FieldAsString(1);
      var Active:=Paths.FieldAsBoolean(2); var Identity,Key,Failure:string;
      Identity:=''; Key:=''; Failure:='';
      if FileExists(DeletionNativePath(Source)) then
        try
          Identity:=ArchiveDeletionSourceIdentity(Source); Key:=Copy(Identity,1,25);
        except
          on E:EAbort do raise;
          on E:Exception do
          begin
            if (E is EExternalException) or (E is EOutOfMemory) then raise;
            Failure:=E.Message;
          end;
        end
      else Failure:='Файл не найден.';
      if Identity='' then
      begin
        if Active then
          Skipped(Source,Failure,FStore.DB.QuerySingleInt('SELECT count(*) FROM Locators WHERE CandidateID=? AND Kind<>1',[CandidateID]));
      end
      else
      begin
        if Active then FStore.DB.ExecSQL('INSERT OR IGNORE INTO Sources(Source,FileKey,Identity) VALUES(?,?,?)',[Source,Key,Identity]);
        Query:=FStore.DB.NewQuery('SELECT ID,Identity FROM Sources WHERE FileKey=?',[Key]); Query.Open;
        var FileID:Int64:=0;
        if not Query.Eof then
        begin
          FileID:=Query.FieldAsInt(0);
          if Query.FieldAsString(1)<>Identity then raise EReadError.Create('Файл изменился при подготовке плана: '+Source);
        end;
        FreeAndNil(Query);
        if FileID<>0 then
        begin
          Rows:=FStore.DB.NewQuery('SELECT '+Columns+',Root,SourceKey,Kind,rowid FROM Locators WHERE CandidateID=? ORDER BY rowid',[CandidateID]);
          Rows.Open;
          while not Rows.Eof do
          begin
            Inc(Done); ReportProgress;
            var Kind:=Integer(Rows.FieldAsInt(9)); var Row:=ReadLocator(Rows,Kind);
            var Exact:string; var Valid:=False;
            try Exact:=MemberFor(Source,Row); Valid:=True;
            except
              on E:EAbort do raise;
              on E:Exception do
              begin
                if (E is EExternalException) or (E is EOutOfMemory) then raise;
                if Kind<>1 then Skipped(Source+' / '+Row.FileName+Row.Extension,E.Message);
              end;
            end;
            if Valid then
            begin
              if Kind<>1 then FStore.DB.ExecSQL('INSERT OR IGNORE INTO Members VALUES(?,?,?)',[FileID,Exact,Row.Extension]);
              FStore.DB.ExecSQL('UPDATE Locators SET FileID=?,Member=? WHERE rowid=?',[FileID,Exact,Rows.FieldAsInt(10)]);
              FlushChunk;
            end;
            Rows.Next;
          end;
          FreeAndNil(Rows);
        end;
      end;
      Paths.Next;
    end;
    FreeAndNil(Paths); FStore.DB.ExecSQL('COMMIT');
    if (CompressionFileKey(FOptions.Catalogue)<>FCatalogueKey) or
      (CompressionFileKey(FOptions.Personal)<>FPersonalKey) then
      raise EReadError.Create('База коллекции заменена при подготовке сжатия.');
    if FSkippedRows>0 then FWarning:=Format('Некоторые локальные файлы недоступны; пропущено записей: %d. Первые причины:',[FSkippedRows])+FWarning;
    FStore.Seal;
    if Assigned(Progress) then Progress(Done);
  finally
    Rows.Free; Paths.Free; Query.Free; Personal.Free; Catalogue.Free; Cache.Free;
  end;
end;

procedure TBookCompressionPlan.SelectUnprocessed(const Profile:string; Grayscale:Boolean;
  const EngineSHA256:string; const Progress:TProc<Int64,Int64>);
var Catalogue:TSQLiteDatabase; Sources,Checks:TSQLiteQuery; Source:TFileStream;
    Done,Total:Int64; ImageStamp:string; HasImageChecks:Boolean;
begin
  if FStore=nil then
    raise EInvalidOperation.Create('Для поиска новых книг нужен план текущей коллекции.');
  CheckCancelled;
  if CompressionFileKey(FOptions.Catalogue)<>FCatalogueKey then
    raise EReadError.Create('Каталог изменился после выбора книг. Повторите сжатие.');
  Catalogue:=TSQLiteDatabase.CreateReadOnly(FOptions.Catalogue);
  try
    if Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' '+
      'AND name=''HomeLibreCompressionChecks''')=0 then Exit;
    HasImageChecks:=Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' '+
      'AND name=''HomeLibreCompressionDependencies''')<>0;
    // Candidate selection is a metadata pass, not an integrity scan of every
    // packed byte in a multi-terabyte library. Full collection compression
    // keeps AlreadyChecked's SHA-256 check; selected candidates still undergo
    // all existing content/identity checks before any physical replacement.
    FStore.Edit(
      procedure(DB:TSQLiteDatabase)
      begin
        Sources:=DB.NewQuery('SELECT ID,Source,FileKey,Identity FROM Sources ORDER BY ID');
        try
          Total:=DB.QuerySingleInt('SELECT count(*) FROM Sources'); Done:=0;
          Sources.Open;
          while not Sources.Eof do
          begin
            CheckCancelled;
            Source:=TFileStream.Create(DeletionNativePath(Sources.FieldAsString(1)),fmOpenRead or fmShareDenyWrite);
            try
              if ArchiveDeletionSourceIdentity(Sources.FieldAsString(1))<>Sources.FieldAsString(3) then
                raise EReadError.Create('Файл изменился при поиске новых книг: '+Sources.FieldAsString(1));
              ImageStamp:=CompressionImageStamp(Sources.FieldAsString(1));
              Checks:=Catalogue.NewQuery('SELECT Member FROM HomeLibreCompressionChecks WHERE '+
                'FileKey=? AND Profile=? AND Grayscale=? AND EngineSHA256=? AND SourceIdentity=?',
                [UpperCase(Sources.FieldAsString(2)),Profile,Ord(Grayscale),EngineSHA256,Sources.FieldAsString(3)]);
              try
                Checks.Open;
                while not Checks.Eof do
                begin
                  CheckCancelled;
                  if ImageStamp<>'' then
                  begin
                    if not HasImageChecks then begin Checks.Next; Continue; end;
                    if Catalogue.QuerySingleInt('SELECT count(*) FROM HomeLibreCompressionDependencies '+
                      'WHERE FileKey=? AND Member=? AND Profile=? AND Grayscale=? AND EngineSHA256=? AND Stamp=?',
                      [UpperCase(Sources.FieldAsString(2)),Checks.FieldAsString(0),Profile,Ord(Grayscale),EngineSHA256,ImageStamp])<>1 then
                    begin Checks.Next; Continue; end;
                  end;
                  DB.ExecSQL('DELETE FROM Members WHERE FileID=? AND Member=?',
                    [Sources.FieldAsInt(0),Checks.FieldAsString(0)]);
                  Inc(FPreviouslyProcessedBooks,DB.QuerySingleInt('SELECT changes()'));
                  Checks.Next;
                end;
              finally Checks.Free; end;
            finally Source.Free; end;
            Inc(Done);
            if Assigned(Progress) then Progress(Done,Total);
            Sources.Next;
          end;
          CheckCancelled;
          if CompressionFileKey(FOptions.Catalogue)<>FCatalogueKey then
            raise EReadError.Create('Каталог заменён при поиске новых книг. Повторите сжатие.');
        finally Sources.Free; end;
      end);
  finally Catalogue.Free; end;
end;

function TBookCompressionPlan.FileCount:Int64;
begin
  if FStore=nil then Exit(FFiles.Count);
  Result:=FStore.DB.QuerySingleInt('SELECT count(*) FROM Sources S WHERE EXISTS(SELECT 1 FROM Members M WHERE M.FileID=S.ID)');
end;

function TBookCompressionPlan.BookCount:Int64;
begin
  Result:=0;
  if FStore<>nil then Exit(FStore.DB.QuerySingleInt('SELECT count(*) FROM Members'));
  for var FilePlan in FFiles do Inc(Result,FilePlan.MemberCount);
end;

procedure TBookCompressionPlan.ForEachFile(const Visit:TProc<TCompressionFilePlan>);
var Sources,Query:TSQLiteQuery; FilePlan:TCompressionFilePlan;
begin
  if not Assigned(Visit) then raise EArgumentException.Create('Не задан обработчик файлов плана сжатия.');
  if FStore=nil then
  begin for FilePlan in FFiles do begin CheckCancelled; Visit(FilePlan); end; Exit; end;
  Sources:=FStore.DB.NewQuery('SELECT S.ID,S.Source,S.Identity FROM Sources S '+
    'WHERE EXISTS(SELECT 1 FROM Members M WHERE M.FileID=S.ID) ORDER BY S.ID');
  try
    Sources.Open;
    while not Sources.Eof do
    begin
      CheckCancelled;
      var FileID:=Sources.FieldAsInt(0);
      FilePlan:=TCompressionFilePlan.Create(Sources.FieldAsString(1),NewTemplate);
      try
        if FilePlan.FSourceIdentity<>Sources.FieldAsString(2) then
          raise EReadError.Create('Файл изменился после подготовки плана: '+FilePlan.Source);
        Query:=FStore.DB.NewQuery('SELECT Member,Ext FROM Members WHERE FileID=? ORDER BY Member',[FileID]);
        try
          Query.Open;
          while not Query.Eof do
          begin CheckCancelled; FilePlan.AddMember(Query.FieldAsString(0),Query.FieldAsString(1)); Query.Next; end;
        finally Query.Free; end;
        Query:=FStore.DB.NewQuery('SELECT '+
          'L.BookID,L.LibID,L.Folder,L.FileName,L.Ext,L.InsideNo,L.BookSize,L.Root,L.SourceKey,L.Kind,L.Member '+
          'FROM Locators L WHERE L.FileID=? AND EXISTS(SELECT 1 FROM Members M WHERE M.FileID=L.FileID AND M.Member=L.Member) ORDER BY L.rowid',[FileID]);
        try
          Query.Open;
          while not Query.Eof do
          begin
            CheckCancelled;
            FilePlan.AddRow(ReadLocator(Query,Integer(Query.FieldAsInt(9))),Query.FieldAsString(10));
            Query.Next;
          end;
        finally Query.Free; end;
        CompleteFile(FilePlan); Visit(FilePlan);
      finally FilePlan.Free; end;
      Sources.Next;
    end;
  finally Sources.Free; end;
end;

destructor TBookCompressionPlan.Destroy;
begin FStore.Free; FFiles.Free; inherited; end;

end.
