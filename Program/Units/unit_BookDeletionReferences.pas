unit unit_BookDeletionReferences;

interface

uses unit_Interfaces, unit_ArchiveDeletionQueue, System.SysUtils;

procedure CheckArchiveDeletionReferences(const User: ISystemData;
  const Tasks: TArray<TArchiveDeletionTask>; const Cancelled: TFunc<Boolean>);

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.Generics.Collections, SQLiteWrap,
  unit_Globals, unit_BookDeletionBinding, unit_BookDeletionInventory,
  unit_ZipMemberDeletion, unit_MHLArchiveHelpers;

type
  TCheckedArchive = class
    Task: TArchiveDeletionTask;
    Binding: TBookDeletionBinding;
    SelectedIDs: TDictionary<Integer,Byte>;
    RemovedNames, RetainedNames: TDictionary<string,Byte>;
    constructor Create(const Value: TArchiveDeletionTask);
    destructor Destroy; override;
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
  for var Book in Binding.ExpectedBooks do SelectedIDs.Add(Book.BookKey.BookID,0);
  // Refuse even a case-insensitive conflict. The ordinary reader can use a
  // case-insensitive filename or basename when a source supplied one.
  for var Name in Task.Members do RemovedNames.AddOrSetValue(LowerCase(NormalName(Name)),0);
end;

destructor TCheckedArchive.Destroy;
begin
  RetainedNames.Free; RemovedNames.Free; SelectedIDs.Free;
  inherited;
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

procedure CheckArchiveDeletionReferences(const User:ISystemData;
  const Tasks:TArray<TArchiveDeletionTask>; const Cancelled:TFunc<Boolean>);
var Targets:TObjectDictionary<string,TCheckedArchive>; Paths:TDictionary<string,string>;
  Collections:ICollectionInfoIterator; Info:TCollectionInfo; InventoryChars:Int64;

  procedure CheckRows(Database:TSQLiteDatabase; const SQL,DefaultRoot:string; CID:Integer; HasRoot:Boolean);
  var Query:TSQLiteQuery; Book:TBookRecord; Path,Key,LastFolder,LastRoot,LastKey:string;
    Format:TBookFormat; Target:TCheckedArchive; CachedFolder:Boolean;
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
        if HasRoot then Book.CollectionRoot:=Query.FieldAsString(4)
        else Book.CollectionRoot:=DefaultRoot;
        Book.FileName:=Query.FieldAsString(2); Book.FileExt:=Query.FieldAsString(3);
        var Container:=TPath.Combine(Book.CollectionRoot,Book.Folder);
        Format:=Book.GetBookFormat(Container);
        if Format in [bfFb2Archive,bfRawArchive,bfFbd] then
        begin
          if (Format<>bfFbd) and CachedFolder and (LastFolder=Book.Folder) and
            (LastRoot=Book.CollectionRoot) then Key:=LastKey
          else
          begin
            Path:=ExpandFileName(Book.GetBookFileName);
            if not Paths.TryGetValue(Path,Key) then
            begin
              try Key:=Copy(ArchiveDeletionSourceIdentity(Path),1,25);
              except on E:EOSError do
                if E.ErrorCode in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND,ERROR_NOT_READY] then Key:=''
                else raise;
              end;
              // Cache each distinct source, not each row in a large catalogue.
              if Paths.Count<65536 then Paths.Add(Path,Key);
            end;
            if Format<>bfFbd then
            begin
              CachedFolder:=True; LastFolder:=Book.Folder;
              LastRoot:=Book.CollectionRoot; LastKey:=Key;
            end;
          end;
          if Targets.TryGetValue(Key,Target) and not
            ((CID=Target.Binding.CollectionID) and Target.SelectedIDs.ContainsKey(Book.BookKey.BookID)) then
          begin
            Target.LoadInventory(Cancelled,InventoryChars);
            if (Format=bfFbd) or
              not Target.RetainedNames.ContainsKey(NormalName(Book.FileName+Book.FileExt)) then
              raise EInOutError.CreateFmt('Книга из этого архива ещё нужна другой записи или её файл нельзя определить точно: %s. Архив не изменён.',
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
  InventoryChars:=0;
  try
    for var Task in Tasks do
      Targets.Add(Copy(Task.SourceIdentity,1,25),TCheckedArchive.Create(Task));
    Collections:=User.GetCollectionInfoIterator;
    while Collections.Next(Info) do
    begin
      if Assigned(Cancelled) and Cancelled() then Abort;
      if not FileExists(Info.DBFileName) then Continue;
      // Read only source fields. Do not load the book lists, alter another
      // collection's schema or read any book payload while finding references.
      var DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
      try
        CheckRows(DB,'SELECT BookID,Folder,FileName,Ext FROM Books ORDER BY Folder',
          Info.GetRootPath,Info.ID,False);
        if DB.QuerySingleInt('SELECT COUNT(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')>0 then
          CheckRows(DB,'SELECT BookID,Folder,FileName,Ext,Root FROM CatalogBookCopies',
            '',Info.ID,True);
      finally DB.Free; end;
    end;
  finally Paths.Free; Targets.Free; end;
end;

end.
