unit unit_BookCompressionPlan;

interface

uses System.SysUtils, System.JSON, System.Generics.Collections, SQLiteWrap;

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
  // legacy ZIP-to-7z fallback in a worker with no VCL/database connection.
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
  public
    constructor Create(const Source: string; Template: TJSONObject);
    destructor Destroy; override;
    procedure CheckSource;
    function CreateRequest(const Workspace, ReportFile, SevenZip, ToolsRoot,
      Profile: string; Grayscale: Boolean): TJSONObject;
    function ReceiptTemplate: string;
    function MemberCount: Integer;
    function RowCount: Integer;
    property Source: string read FSource;
    property FileKey: string read FFileKey;
  end;

  // Captures all matching main/personal/copy rows in one read-only scan.
  // Each physical archive is a single work item, regardless of the number of
  // selected books and catalogue aliases inside it. No whole database copy.
  TBookCompressionPlan = class
  private
    FFiles: TObjectList<TCompressionFilePlan>;
    FOptions: TCompressionPlanOptions;
    FCatalogueKey, FPersonalKey: string;
  public
    constructor Create(const Options: TCompressionPlanOptions;
      const Selected: TArray<TCompressionLocator>;
      const SourceFor: TCompressionSourceResolver;
      const MemberFor: TCompressionMemberResolver;
      const Cancelled: TFunc<Boolean> = nil;
      const Progress: TProc<Int64> = nil);
    destructor Destroy; override;
    property Files: TObjectList<TCompressionFilePlan> read FFiles;
  end;

implementation

uses System.IOUtils, System.Classes, unit_BookCompressionReceipt,
  unit_ZipMemberDeletion;

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
  function NewTemplate: TJSONObject;
  begin
    Result:=TJSONObject.Create;
    Result.AddPair('schema',TJSONNumber.Create(1));
    Result.AddPair('kind','HomeLibre book compression');
    Result.AddPair('collection_id',TJSONNumber.Create(FOptions.CollectionID));
    Result.AddPair('catalogue',FOptions.Catalogue);
    Result.AddPair('personal',FOptions.Personal);
    Result.AddPair('catalogue_key',FCatalogueKey);
    Result.AddPair('personal_key',FPersonalKey);
    Result.AddPair('base_root',FOptions.BaseRoot);
    Result.AddPair('base_catalogue',FOptions.BaseCatalogue);
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
          if not ByPath.TryGetValue(LowerCase(Path),Target) then
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
              ByPath.Add(LowerCase(Path),Target);
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
      ByPath.AddOrSetValue(LowerCase(Source),FilePlan);
      FilePlan.AddMember(Member,Row.Extension);
    end;
    Done:=0;
    Scan(Catalogue,'SELECT '+Columns+' FROM Books',0);
    Scan(Personal,'SELECT '+Columns+' FROM Books WHERE DatabaseID='+IntToStr(FOptions.CollectionID),1);
    if Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')<>0 then
      Scan(Catalogue,'SELECT '+Columns+',Root,SourceKey FROM CatalogBookCopies',2);
    for FilePlan in FFiles do
    begin
      CheckCancel; FilePlan.CheckSource;
      if FilePlan.RowCount=0 then raise EReadError.Create('В каталоге не осталось выбранных книг.');
      if Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibreBookCompression''')<>0 then
      begin
        Query:=Catalogue.NewQuery('SELECT Member,ProfileSHA256,OutputSHA256 FROM HomeLibreBookCompression WHERE FileKey=?',
          [FilePlan.FileKey]);
        Query.Open;
        while not Query.Eof do
        begin
          var Previous:=TJSONObject.Create;
          Previous.AddPair('profile_sha256',Query.FieldAsString(1));
          Previous.AddPair('output_sha256',Query.FieldAsString(2));
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

destructor TBookCompressionPlan.Destroy;
begin FFiles.Free; inherited; end;

end.
