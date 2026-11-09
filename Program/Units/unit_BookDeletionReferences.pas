unit unit_BookDeletionReferences;

interface

uses unit_Interfaces, unit_ArchiveDeletionQueue, unit_Globals, System.SysUtils;

procedure CheckArchiveDeletionReferences(const User: ISystemData;
  var Tasks: TArray<TArchiveDeletionTask>; const Cancelled: TFunc<Boolean>);
procedure CheckLooseDuplicateReferences(const User: ISystemData; CollectionID: Integer;
  const Removed: TArray<TBookRecord>; const Cancelled: TFunc<Boolean>);
procedure CheckLinkedLooseReferences(const User: ISystemData; const Removed: TArray<TBookRecord>;
  const Cancelled: TFunc<Boolean> = nil);

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.Generics.Collections, SQLiteWrap,
  unit_BookDeletionBinding, unit_BookDeletionInventory,
  unit_ZipMemberDeletion, unit_MHLArchiveHelpers, unit_FLibraryCompat;

type
  TCheckedArchive = class
    Task: TArchiveDeletionTask;
    Binding: TBookDeletionBinding;
    SelectedIDs: TDictionary<Integer,Byte>;
    SelectedCopies: TDictionary<string,Byte>;
    RemovedNames, RetainedNames: TDictionary<string,Byte>;
    constructor Create(const Value: TArchiveDeletionTask);
    destructor Destroy; override;
    function IsSelected(CollectionID, BookID: Integer; IsCopy: Boolean; const SourceKey: string): Boolean;
    procedure LoadInventory(const Cancelled: TFunc<Boolean>; var InventoryChars: Int64);
  end;

function NormalName(const Value:string):string;
begin Result:=Value.Replace('\','/'); end;

constructor TCheckedArchive.Create(const Value:TArchiveDeletionTask);
begin
  inherited Create;
  Task:=Value; Binding:=TBookDeletionBinding.Parse(Value.CatalogueBinding);
  SelectedIDs:=TDictionary<Integer,Byte>.Create;
  RemovedNames:=TDictionary<string,Byte>.Create;
  if Binding.RemovesCopies then
  begin
    SelectedCopies:=TDictionary<string,Byte>.Create;
    for var Key in Binding.SourceKeys do SelectedCopies.Add(Key,0);
  end
  else
    for var Book in Binding.ExpectedBooks do SelectedIDs.Add(Book.BookKey.BookID,0);
  // Refuse even a case-insensitive conflict. The ordinary reader can use a
  // case-insensitive filename or basename when a source supplied one.
  for var Name in Task.Members do RemovedNames.AddOrSetValue(LowerCase(NormalName(Name)),0);
end;

destructor TCheckedArchive.Destroy;
begin
  RetainedNames.Free; RemovedNames.Free; SelectedCopies.Free; SelectedIDs.Free;
  inherited;
end;

function TCheckedArchive.IsSelected(CollectionID, BookID: Integer; IsCopy: Boolean;
  const SourceKey: string): Boolean;
begin
  if CollectionID<>Binding.CollectionID then Exit(False);
  if Assigned(SelectedCopies) then Exit(IsCopy and SelectedCopies.ContainsKey(SourceKey));
  Result:=SelectedIDs.ContainsKey(BookID);
end;

procedure TCheckedArchive.LoadInventory(const Cancelled:TFunc<Boolean>; var InventoryChars:Int64);
begin
  if Assigned(RetainedNames) then Exit;
  RetainedNames:=TDictionary<string,Byte>.Create;
  for var Name in ReadBookDeletionInventory(Task.Archive,Task.SourceIdentity,Cancelled) do
  begin
    Inc(InventoryChars,Length(Name));
    if InventoryChars>8*1024*1024 then
      raise EReadError.Create('Слишком много имён в выбранных архивах. Удалите книги меньшими группами.');
    var Key:=NormalName(Name);
    if not RemovedNames.ContainsKey(LowerCase(Key)) then RetainedNames.AddOrSetValue(Key,0);
  end;
end;

function SourceKey(const Path: string): string;
begin
  try Result:=Copy(ArchiveDeletionSourceIdentity(Path),1,25);
  except on E:EOSError do
    if E.ErrorCode in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND,ERROR_NOT_READY] then Result:=''
    else raise;
  end;
end;

procedure CheckLinkedLooseReferences(const User: ISystemData; const Removed: TArray<TBookRecord>;
  const Cancelled: TFunc<Boolean>);
const LinkFilter = ' WHERE (LibID>=''local:link:'' AND LibID<''local:link;'') OR '+
    '(LibID>=''merged:'' AND LibID<''merged;'' AND LibID GLOB ''merged:*:local:link:*'')';
var Paths: TDictionary<string, string>; Sources: TDictionary<string, Byte>;
  Collections: ICollectionInfoIterator;
  Info: TCollectionInfo; LoadedSources: Boolean;

  procedure CheckRows(Database: TSQLiteDatabase; const TableName: string);
  var Query: TSQLiteQuery; Book: TBookRecord; Path, Identity: string;
  begin
    Query:=Database.NewQuery('SELECT LibID,Folder,FileName,Ext FROM '+TableName+LinkFilter);
    try
      Query.Open;
      while not Query.Eof do
      begin
        if Assigned(Cancelled) and Cancelled() then Abort;
        Book:=Default(TBookRecord);
        Book.LibID:=Query.FieldAsString(0); Book.Folder:=Query.FieldAsString(1);
        Book.FileName:=Query.FieldAsString(2); Book.FileExt:=Query.FieldAsString(3);
        if Book.IsLinkedSource then
        begin
          Path:=ExpandFileName(Book.GetBookFileName);
          if Paths.ContainsKey(LowerCase(Path)) then
            raise EInOutError.CreateFmt('Исходный файл используется записью-ссылкой: %s. Удаление не началось.',[Path]);
          if not LoadedSources then
          begin
            for var Candidate in Paths.Values do
            begin
              if Assigned(Cancelled) and Cancelled() then Abort;
              Identity:=SourceKey(Candidate);
              if Identity<>'' then Sources.AddOrSetValue(Identity,0);
            end;
            LoadedSources:=True;
          end;
          if (Sources.Count>0) and Sources.ContainsKey(SourceKey(Path)) then
            raise EInOutError.CreateFmt('На тот же файл указывает запись-ссылка: %s. Удаление не началось.',[Path]);
        end;
        Query.Next;
      end;
    finally Query.Free; end;
  end;

begin
  Paths:=TDictionary<string,string>.Create;
  Sources:=TDictionary<string,Byte>.Create;
  try
    for var Book in Removed do
      if not Book.IsLinkedSource then
      begin
        var Path:=ExpandFileName(Book.GetBookFileName);
        if not IsArchiveExt(Path) then Paths.AddOrSetValue(LowerCase(Path),Path);
      end;
    if Paths.Count=0 then Exit;
    LoadedSources:=False;
    Collections:=User.GetCollectionInfoIterator;
    while Collections.Next(Info) do
    begin
      if Assigned(Cancelled) and Cancelled() then Abort;
      if not FileExists(Info.DBFileName) then Continue;
      var DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
      try
        CheckRows(DB,'Books');
        if DB.QuerySingleInt('SELECT COUNT(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')>0 then
          CheckRows(DB,'CatalogBookCopies');
      finally DB.Free; end;
    end;
  finally Sources.Free; Paths.Free; end;
end;

procedure CheckLooseDuplicateReferences(const User: ISystemData; CollectionID: Integer;
  const Removed: TArray<TBookRecord>; const Cancelled: TFunc<Boolean>);
var Names, Sources: TDictionary<string,Byte>; Selected: TDictionary<Integer,Byte>;
  Collections: ICollectionInfoIterator; Info: TCollectionInfo;

  procedure CheckRows(DB: TSQLiteDatabase; const SQL: string; HasRoot: Boolean);
  var Query: TSQLiteQuery; Book: TBookRecord;
  begin
    Book:=Default(TBookRecord);
    Query:=DB.NewQuery(SQL);
    try
      Query.Open;
      while not Query.Eof do
      begin
        if Assigned(Cancelled) and Cancelled() then Abort;
        Book.FileName:=Query.FieldAsString(2);
        Book.FileExt:=Query.FieldAsString(3);
        // A private loose source cannot have a second filename. Only probe
        // registered records whose final filename can refer to our file.
        if Names.ContainsKey(UpperCase(ExtractFileName(Book.FileName+Book.FileExt))) and
          ((Info.ID<>CollectionID) or not Selected.ContainsKey(Query.FieldAsInt(0))) then
        begin
          Book.Folder:=Query.FieldAsString(1);
          if HasRoot then Book.CollectionRoot:=Query.FieldAsString(4) else Book.CollectionRoot:=Info.GetRootPath;
          if not IsArchiveExt(Book.GetBookFileName(TPath.Combine(Book.CollectionRoot,Book.Folder))) then
          begin
            var Path:=Book.GetBookFileName;
            if Sources.ContainsKey(SourceKey(Path)) then
              raise EInOutError.CreateFmt('Файл нужен другой записи: %s. Удаление не началось.',[Path]);
          end;
        end;
        Query.Next;
      end;
    finally Query.Free; end;
  end;

begin
  Names:=TDictionary<string,Byte>.Create;
  Sources:=TDictionary<string,Byte>.Create;
  Selected:=TDictionary<Integer,Byte>.Create;
  try
    for var Book in Removed do
    begin
      Selected.Add(Book.BookKey.BookID,0);
      var Path:=Book.GetBookFileName;
      if IsArchiveExt(Path) then Continue;
      var Key:=SourceKey(Path);
      if Key='' then raise EReadError.CreateFmt('Файл удаляемой копии недоступен: %s.',[Path]);
      Sources.AddOrSetValue(Key,0);
      Names.AddOrSetValue(UpperCase(ExtractFileName(Path)),0);
    end;
    if Names.Count=0 then Exit;
    Collections:=User.GetCollectionInfoIterator;
    while Collections.Next(Info) do
    begin
      if Assigned(Cancelled) and Cancelled() then Abort;
      if not FileExists(Info.DBFileName) then Continue;
      var DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
      try
        CheckRows(DB,'SELECT BookID,Folder,FileName,Ext FROM Books',False);
        if DB.QuerySingleInt('SELECT COUNT(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')>0 then
          CheckRows(DB,'SELECT BookID,Folder,FileName,Ext,Root FROM CatalogBookCopies',True);
      finally DB.Free; end;
    end;
  finally Selected.Free; Sources.Free; Names.Free; end;
end;

procedure CheckArchiveDeletionReferences(const User:ISystemData;
  var Tasks:TArray<TArchiveDeletionTask>; const Cancelled:TFunc<Boolean>);
var Targets:TObjectDictionary<string,TCheckedArchive>; Paths:TDictionary<string,string>;
  ImageOwners:TDictionary<string,string>; LooseNames:TDictionary<string,Byte>;
  Collections:ICollectionInfoIterator; Info:TCollectionInfo; InventoryChars:Int64;

  procedure CheckPictureOwners(const Path,Key:string);
  begin
    if ImageOwners.Count=0 then Exit;
    if ImageOwners.ContainsKey(Key) then ImageOwners[Key]:='';
    if (Key='') or not IsSevenZipArchive(Path) then Exit;
    for var ImagePath in FLibraryImageSourceFiles(Path) do
      if ImagePath<>'' then
      begin
        var ImageKey:string;
        try ImageKey:=SourceKey(ImagePath);
        except
          on E:Exception do
          begin
            // The original book can still be removed. Keep every optional
            // companion if the comparison cannot rule out a shared source.
            ImageOwners.Clear; Exit;
          end;
        end;
        var Owner:string;
        if ImageOwners.TryGetValue(ImageKey,Owner) and (Owner<>Key) then ImageOwners[ImageKey]:='';
      end;
  end;

  procedure CheckRows(Database:TSQLiteDatabase; const SQL,DefaultRoot:string; CID:Integer; HasRoot:Boolean);
  var Query:TSQLiteQuery; Book:TBookRecord; Path,Key,LastFolder,LastRoot,LastKey,CopyKey,Member:string;
    Format:TBookFormat; Target:TCheckedArchive; CachedFolder,WholeSource:Boolean;
  begin
    Book:=Default(TBookRecord); Book.BookKey.DatabaseID:=CID;
    CachedFolder:=False; LastKey:='';
    Query:=Database.NewQuery(SQL);
    try
      Query.Open;
      while not Query.Eof do
      begin
        if Assigned(Cancelled) and Cancelled() then Abort;
        Book.BookKey.BookID:=Query.FieldAsInt(0);
        Book.Folder:=Query.FieldAsString(1);
        Book.LibID:=Query.FieldAsString(4);
        if HasRoot then
        begin
          Book.CollectionRoot:=Query.FieldAsString(5);
          CopyKey:=Query.FieldAsString(6);
        end
        else Book.CollectionRoot:=DefaultRoot;
        Book.FileName:=Query.FieldAsString(2); Book.FileExt:=Query.FieldAsString(3);
        var Container:=TPath.Combine(Book.CollectionRoot,Book.Folder);
        Format:=Book.GetBookFormat(Container);
        WholeSource:=((Format=bfRaw) and IsArchiveExt(Book.FileExt)) or
          ((Format in [bfRaw,bfFb2]) and (Book.IsLinkedSource or
            ((LooseNames.Count>0) and LooseNames.ContainsKey(UpperCase(ExtractFileName(Book.FileName+Book.FileExt))))));
        if WholeSource or (Format in [bfFb2Archive,bfRawArchive,bfFbd]) then
        begin
          if not WholeSource and (Format<>bfFbd) and CachedFolder and (LastFolder=Book.Folder) and
            (LastRoot=Book.CollectionRoot) then Key:=LastKey
          else
          begin
            Path:=ExpandFileName(Book.GetBookFileName);
            if not Paths.TryGetValue(Path,Key) then
            begin
              Key:=SourceKey(Path);
              CheckPictureOwners(Path,Key);
              // Cache each distinct source, not each row in a large catalogue.
              if Paths.Count<65536 then Paths.Add(Path,Key);
            end;
            if not WholeSource and (Format<>bfFbd) then
            begin
              CachedFolder:=True; LastFolder:=Book.Folder;
              LastRoot:=Book.CollectionRoot; LastKey:=Key;
            end;
          end;
          if Targets.TryGetValue(Key,Target) and (Book.IsLinkedSource or not
            Target.IsSelected(CID,Book.BookKey.BookID,HasRoot,CopyKey)) then
          begin
            if not WholeSource and not Target.Task.WholeSource then
              Target.LoadInventory(Cancelled,InventoryChars);
            Member:=Book.FileName;
            if not SameText(ExtractFileExt(Member),Book.FileExt) then Member:=Member+Book.FileExt;
            if WholeSource or Target.Task.WholeSource or (Format=bfFbd) or
              not Target.RetainedNames.ContainsKey(NormalName(Member)) then
              raise EInOutError.CreateFmt('Файл ещё нужен другой записи или его нельзя определить точно: %s. Удаление не началось.',
                [ExtractFileName(Target.Task.Archive)]);
          end;
        end;
        Query.Next;
      end;
    finally Query.Free; end;
  end;

begin
  if Length(Tasks)=0 then Exit;
  Targets:=TObjectDictionary<string,TCheckedArchive>.Create([doOwnsValues]);
  Paths:=TDictionary<string,string>.Create;
  ImageOwners:=TDictionary<string,string>.Create;
  LooseNames:=TDictionary<string,Byte>.Create;
  InventoryChars:=0;
  try
    for var Task in Tasks do
    begin
      Targets.Add(Copy(Task.SourceIdentity,1,25),TCheckedArchive.Create(Task));
      if Task.WholeSource and not IsArchiveExt(Task.Archive) then
        LooseNames.AddOrSetValue(UpperCase(ExtractFileName(Task.Archive)),0);
      for var Image in Task.Companions do
      begin
        var ImageKey:=Copy(Image.SourceIdentity,1,25);
        // The same physical companion appearing twice is ambiguous, even
        // when both primary archives are part of this deletion batch.
        if ImageOwners.ContainsKey(ImageKey) then ImageOwners[ImageKey]:=''
        else ImageOwners.Add(ImageKey,Copy(Task.SourceIdentity,1,25));
      end;
    end;
    Collections:=User.GetCollectionInfoIterator;
    while Collections.Next(Info) do
    begin
      if Assigned(Cancelled) and Cancelled() then Abort;
      if not FileExists(Info.DBFileName) then Continue;
      // Read only source fields. Do not load the book lists, alter another
      // collection's schema or read any book payload while finding references.
      var DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
      try
        CheckRows(DB,'SELECT BookID,Folder,FileName,Ext,LibID FROM Books ORDER BY Folder',
          Info.GetRootPath,Info.ID,False);
        if DB.QuerySingleInt('SELECT COUNT(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')>0 then
          CheckRows(DB,'SELECT BookID,Folder,FileName,Ext,LibID,Root,SourceKey FROM CatalogBookCopies',
            '',Info.ID,True);
      finally DB.Free; end;
    end;
    for var I:=0 to High(Tasks) do
    begin
      var Count:=0;
      for var J:=0 to High(Tasks[I].Companions) do
      begin
        var Image:=Tasks[I].Companions[J];
        var Owner:string;
        if not ImageOwners.TryGetValue(Copy(Image.SourceIdentity,1,25),Owner) or (Owner='') then Continue;
        Tasks[I].Companions[Count]:=Image; Inc(Count);
      end;
      SetLength(Tasks[I].Companions,Count);
    end;
  finally LooseNames.Free; ImageOwners.Free; Paths.Free; Targets.Free; end;
end;

end.
