unit unit_CollectionPackingPublisher;

interface

uses System.SysUtils, System.Classes, SQLiteWrap, unit_Globals;

type
  TPackingPublisherState = record
    Book:TBookRecord;
    Root:string;
    PendingPayload:Boolean;
  end;

procedure CaptureInitialPackingPublishers(DB:TSQLiteDatabase; const Root:string;
  const Check:TProc; const Progress:TProc<Int64,Int64>);
procedure StorePackingPublisher(DB:TSQLiteDatabase; Book:TBookRecord;
  const Root:string; PayloadAvailable:Boolean);
function ReadPackingPublisher(DB:TSQLiteDatabase; BookID:Integer;
  out State:TPackingPublisherState):Boolean;

implementation

uses System.IOUtils;

const PublisherTable='HomeLibrePackingPublishers';

procedure EnsureSchema(DB:TSQLiteDatabase);
begin
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[PublisherTable])<>0 then Exit;
  DB.ExecSQL('CREATE TABLE IF NOT EXISTS '+PublisherTable+'('+
    'BookID INTEGER PRIMARY KEY,Folder TEXT NOT NULL,FileName TEXT NOT NULL,Ext TEXT NOT NULL,'+
    'InsideNo INTEGER NOT NULL,BookSize INTEGER NOT NULL,UpdateDate TEXT,Title TEXT NOT NULL,'+
    'Lang TEXT NOT NULL,IsDeleted INTEGER NOT NULL,LibID TEXT NOT NULL,Root TEXT NOT NULL,'+
    'PendingPayload INTEGER NOT NULL)');
end;

function ReadPackingPublisher(DB:TSQLiteDatabase; BookID:Integer;
  out State:TPackingPublisherState):Boolean;
var Q:TSQLiteQuery;
begin
  State:=Default(TPackingPublisherState); Result:=False;
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[PublisherTable])=0 then Exit;
  Q:=DB.NewQuery('SELECT BookID,Folder,FileName,Ext,InsideNo,BookSize,UpdateDate,Title,Lang,IsDeleted,LibID,Root,PendingPayload '+
    'FROM '+PublisherTable+' WHERE BookID=?',[BookID]);
  try
    Q.Open; if Q.Eof then Exit;
    State.Book.BookKey.BookID:=Q.FieldAsInt(0); State.Book.Folder:=Q.FieldAsString(1);
    State.Book.FileName:=Q.FieldAsString(2); State.Book.FileExt:=Q.FieldAsString(3);
    State.Book.InsideNo:=Q.FieldAsInt(4); State.Book.Size:=Q.FieldAsInt(5); State.Book.Date:=Q.FieldAsDateTime(6);
    State.Book.Title:=Q.FieldAsString(7); State.Book.Lang:=Q.FieldAsString(8);
    if Q.FieldAsBoolean(9) then Include(State.Book.BookProps,bpIsDeleted);
    State.Book.LibID:=Q.FieldAsString(10); State.Root:=Q.FieldAsString(11);
    State.Book.CollectionRoot:=State.Root; State.PendingPayload:=Q.FieldAsBoolean(12); Result:=True;
  finally Q.Free; end;
end;

procedure Put(DB:TSQLiteDatabase; const Book:TBookRecord; const Root:string; Pending:Boolean);
var StoredRoot:string; Q:TSQLiteQuery;
begin
  StoredRoot:=''; if TPath.IsPathRooted(Book.Folder) then StoredRoot:=Root;
  Q:=DB.NewQuery('INSERT OR REPLACE INTO '+PublisherTable+' VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
    [Book.BookKey.BookID,Book.Folder,Book.FileName,Book.FileExt,Book.InsideNo,Book.Size,'',
     Book.Title,Book.Lang,bpIsDeleted in Book.BookProps,Book.LibID,StoredRoot,Pending]);
  try Q.SetParam(6,Book.Date); Q.ExecSQL; finally Q.Free; end;
end;

procedure StorePackingPublisher(DB:TSQLiteDatabase; Book:TBookRecord;
  const Root:string; PayloadAvailable:Boolean);
var Previous:TPackingPublisherState; Known,Pending:Boolean;
begin
  if not DB.InTransaction or (Book.BookKey.BookID<=0) then
    raise EInvalidOperation.Create('Сведения исходного индекса требуют активной транзакции и номера книги.');
  EnsureSchema(DB); Known:=ReadPackingPublisher(DB,Book.BookKey.BookID,Previous);
  Pending:=not PayloadAvailable and (not Known or Previous.PendingPayload or
    (Previous.Book.Size<>Book.Size) or (Previous.Book.Date<>Book.Date) or
    not SameText(Previous.Book.FileName,Book.FileName) or not SameText(Previous.Book.FileExt,Book.FileExt));
  Put(DB,Book,Root,Pending);
end;

procedure CaptureInitialPackingPublishers(DB:TSQLiteDatabase; const Root:string;
  const Check:TProc; const Progress:TProc<Int64,Int64>);
var Q:TSQLiteQuery; Book:TBookRecord; Done,Total:Int64;
begin
  // A legacy packed catalogue has already lost its original index sizes.
  // Do not invent publisher metadata from those physical packed locators.
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibPackingOrigins''')<>0 then Exit;
  Total:=DB.QuerySingleInt('SELECT count(*) FROM Books'); Done:=0;
  if Assigned(Progress) then Progress(0,Total);
  EnsureSchema(DB);
  DB.BeginQueryBatch;
  Q:=nil;
  try
    Q:=DB.NewQuery('SELECT b.BookID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.BookSize,b.UpdateDate,b.Title,b.Lang,b.IsDeleted,b.LibID '+
      'FROM Books b WHERE NOT EXISTS(SELECT 1 FROM '+PublisherTable+' p WHERE p.BookID=b.BookID)');
    DB.Start;
    try
      Q.Open;
      while not Q.Eof do
      begin
        if Assigned(Check) then Check;
        Book:=Default(TBookRecord); Book.BookKey.BookID:=Q.FieldAsInt(0); Book.Folder:=Q.FieldAsString(1);
        Book.FileName:=Q.FieldAsString(2); Book.FileExt:=Q.FieldAsString(3); Book.InsideNo:=Q.FieldAsInt(4);
        Book.Size:=Q.FieldAsInt(5); if not Q.FieldIsNull(6) then Book.Date:=Q.FieldAsDateTime(6);
        Book.Title:=Q.FieldAsString(7);
        Book.Lang:=Q.FieldAsString(8); if Q.FieldAsBoolean(9) then Include(Book.BookProps,bpIsDeleted);
        Book.LibID:=Q.FieldAsString(10); Put(DB,Book,Root,False);
        Inc(Done); if Assigned(Progress) and (Done mod 1000=0) then Progress(Done,Total);
        Q.Next;
      end;
      if Assigned(Check) then Check; DB.Commit;
    except DB.Rollback; raise; end;
    if Assigned(Progress) then Progress(Done,Total);
  finally Q.Free; DB.EndQueryBatch; end;
end;

end.
