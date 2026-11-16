unit unit_CollectionTransferReferenceFence;

interface

uses System.SysUtils, SQLiteWrap, unit_CollectionTransferJournal, unit_BookCompressionPlanStore;

type TTransferReferenceSnapshot=class
  private
    FReview:TSQLiteDatabase;
    FStore:TCompressionPlanStore;
    FCancelled:TFunc<Boolean>;
    procedure Stop;
    procedure Changed;
  public
    // Caller holds writer transactions on personal and every ready catalogue.
    constructor Create(Review:TSQLiteDatabase; const PersonalFile,WorkRoot:string;
      const EffectiveCatalogue:TFunc<Integer,string>; const ExtraTargets:TProc<TSQLiteDatabase>;
      const Cancelled:TFunc<Boolean>);
    destructor Destroy; override;
    procedure CheckGroup(Prepared:TPreparedTransferGroup);
    function RetainedFiles(Prepared:TPreparedTransferGroup):TArray<Int64>;
end;

function ExpandTransferRetention(Review:TSQLiteDatabase; GroupID:Int64; const Seeds:TArray<Int64>):TArray<Int64>;

procedure CheckTransferPublicationReferences(Review:TSQLiteDatabase;
  const PersonalFile,WorkRoot:string; Prepared:TPreparedTransferGroup;
  const EffectiveCatalogue:TFunc<Integer,string>; const Cancelled:TFunc<Boolean>);

implementation

uses System.Classes, System.Generics.Collections, unit_CollectionTransferReferences, unit_BookCompressionReceipt;

function ExpandTransferRetention(Review:TSQLiteDatabase; GroupID:Int64; const Seeds:TArray<Int64>):TArray<Int64>;
var Kept:TDictionary<Int64,Boolean>; Q:TSQLiteQuery; Changed:Boolean;
begin
  Kept:=TDictionary<Int64,Boolean>.Create; Q:=nil;
  try
    for var ID in Seeds do Kept.AddOrSetValue(ID,True);
    repeat
      Changed:=False;
      Q:=Review.NewQuery('SELECT e.OwnerID,e.FileID FROM Edges e JOIN Files f ON f.ID=e.OwnerID WHERE f.GroupID=?',[GroupID]); Q.Open;
      while not Q.Eof do
      begin
        if Kept.ContainsKey(Q.FieldAsInt(0)) and not Kept.ContainsKey(Q.FieldAsInt(1)) then
        begin Kept.Add(Q.FieldAsInt(1),True); Changed:=True; end;
        Q.Next;
      end;
      FreeAndNil(Q);
    until not Changed;
    Result:=Kept.Keys.ToArray;
  finally Q.Free; Kept.Free; end;
end;

function TTransferReferenceSnapshot.RetainedFiles(Prepared:TPreparedTransferGroup):TArray<Int64>;
var Seeds:TList<Int64>;
begin
  Seeds:=TList<Int64>.Create;
  try
    for var I:=0 to Prepared.Count-1 do
      if TransferReferenceRequiresRetention(FStore.DB,Prepared.FileID(I)) or
        (FReview.QuerySingleInt('SELECT KeepInPlace FROM Files WHERE ID=?',[Prepared.FileID(I)])<>0) then
        Seeds.Add(Prepared.FileID(I));
    Result:=ExpandTransferRetention(FReview,Prepared.ID,Seeds.ToArray);
  finally Seeds.Free; end;
end;

procedure TTransferReferenceSnapshot.Stop;
begin
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Проверка новых ссылок остановлена. Исходные книги сохранены.');
end;

procedure TTransferReferenceSnapshot.Changed;
begin
  raise EReadError.Create('Ссылки на переносимые файлы или подключения изменились. '+
    'Нужен новый план переноса; исходные книги сохранены.');
end;

constructor TTransferReferenceSnapshot.Create(Review:TSQLiteDatabase;
  const PersonalFile,WorkRoot:string; const EffectiveCatalogue:TFunc<Integer,string>;
  const ExtraTargets:TProc<TSQLiteDatabase>; const Cancelled:TFunc<Boolean>);
var Fresh,Q,Found:TSQLiteQuery; DB:TSQLiteDatabase;
begin
  inherited Create; FReview:=Review; FCancelled:=Cancelled;
  if (Review=nil) or not Assigned(EffectiveCatalogue) then
    raise EArgumentException.Create('Нужна проверенная группа для повторной проверки ссылок.');
  FStore:=TCompressionPlanStore.Create(WorkRoot); Fresh:=nil; Q:=nil; Found:=nil;
  try
    DB:=FStore.DB; DB.ExecSQL('BEGIN');
    DB.ExecSQL('CREATE TABLE Context(Name TEXT PRIMARY KEY,Value TEXT) WITHOUT ROWID');
    Q:=FReview.NewQuery('SELECT Name,Value FROM Context'); Q.Open;
    while not Q.Eof do begin DB.ExecSQL('INSERT INTO Context VALUES(?,?)',[Q.FieldAsString(0),Q.FieldAsString(1)]); Q.Next; end;
    FreeAndNil(Q);
    DB.ExecSQL('DELETE FROM Context WHERE Name=''reference_rows''');
    DB.ExecSQL('CREATE TABLE Files(ID INTEGER PRIMARY KEY,Identity TEXT,GroupID INTEGER)');
    Q:=FReview.NewQuery('SELECT ID,Identity,GroupID FROM Files'); Q.Open;
    while not Q.Eof do
    begin
      Stop; DB.ExecSQL('INSERT INTO Files VALUES(?,?,?)',[Q.FieldAsInt(0),Q.FieldAsString(1),Q.FieldAsInt(2)]); Q.Next;
    end;
    FreeAndNil(Q);
    DB.ExecSQL('CREATE INDEX PublicationFilesGroup ON Files(GroupID,ID)');
    DB.ExecSQL('CREATE TABLE Edges(OwnerID INTEGER,FileID INTEGER,PRIMARY KEY(OwnerID,FileID)) WITHOUT ROWID');
    Q:=FReview.NewQuery('SELECT OwnerID,FileID FROM Edges'); Q.Open;
    while not Q.Eof do begin DB.ExecSQL('INSERT OR IGNORE INTO Edges VALUES(?,?)',[Q.FieldAsInt(0),Q.FieldAsInt(1)]); Q.Next; end;
    FreeAndNil(Q);
    CaptureTransferReferences(DB,PersonalFile,Cancelled,nil,ExtraTargets);
    if TransferReferenceConflictCount(DB)<>0 then Changed;
    if DB.QuerySingleInt('SELECT count(*) FROM ReferenceRegistrations')<>
      FReview.QuerySingleInt('SELECT count(*) FROM ReferenceRegistrations') then Changed;
    Fresh:=DB.NewQuery('SELECT RegistrationID,RawRoot,Code,State,SourcesJSON,CatalogueKey,RawCatalogue FROM ReferenceRegistrations'); Fresh.Open;
    while not Fresh.Eof do
    begin
      Stop;
      Found:=FReview.NewQuery('SELECT RawRoot,Code,State,SourcesJSON,RawCatalogue FROM ReferenceRegistrations WHERE RegistrationID=?',[Fresh.FieldAsInt(0)]); Found.Open;
      if Found.Eof or (Fresh.FieldAsString(1)<>Found.FieldAsString(0)) or
        (Fresh.FieldAsInt(2)<>Found.FieldAsInt(1)) or (Fresh.FieldAsString(3)<>Found.FieldAsString(2)) or
        (Fresh.FieldAsString(4)<>Found.FieldAsString(3)) then Changed;
      if (Fresh.FieldAsString(3)='ready') and
        (Fresh.FieldAsString(5)<>CompressionFileKey(EffectiveCatalogue(Fresh.FieldAsInt(0)))) then Changed;
      if (Fresh.FieldAsString(3)<>'ready') and (Fresh.FieldAsString(6)<>Found.FieldAsString(4)) then Changed;
      FreeAndNil(Found); Fresh.Next;
    end;
    FreeAndNil(Fresh);
    // Disk-backed approved keys avoid a per-live-row scan of the frozen list.
    DB.ExecSQL('CREATE TABLE Approved(RegistrationID INTEGER,Kind INTEGER,BookID INTEGER,SourceKey TEXT,FileID INTEGER,'+
      'RetainReason TEXT,Resource INTEGER,Owner TEXT,PRIMARY KEY(RegistrationID,Kind,BookID,SourceKey,FileID,Resource,Owner,RetainReason)) WITHOUT ROWID');
    Q:=FReview.NewQuery('SELECT r.RegistrationID,r.Kind,r.BookID,r.SourceKey,r.FileID,r.RetainReason,r.Resource,r.Owner '+
      'FROM RegisteredReferences r JOIN Files f ON f.ID=r.FileID'); Q.Open;
    while not Q.Eof do
    begin
      Stop; DB.ExecSQL('INSERT OR IGNORE INTO Approved VALUES(?,?,?,?,?,?,?,?)',
        [Q.FieldAsInt(0),Q.FieldAsInt(1),Q.FieldAsInt(2),Q.FieldAsString(3),Q.FieldAsInt(4),Q.FieldAsString(5),Q.FieldAsInt(6),Q.FieldAsString(7)]);
      Q.Next;
    end;
    FreeAndNil(Q);
    DB.ExecSQL('CREATE INDEX PublicationApprovedFile ON Approved(FileID)');
    Fresh:=DB.NewQuery('SELECT RegistrationID,Path,Reason FROM ReferenceIssues'); Fresh.Open;
    while not Fresh.Eof do
    begin
      Stop;
      if FReview.QuerySingleInt('SELECT count(*) FROM ReferenceIssues WHERE RegistrationID=? AND Path=? AND Reason=?',
        [Fresh.FieldAsInt(0),Fresh.FieldAsString(1),Fresh.FieldAsString(2)])=0 then Changed;
      Fresh.Next;
    end;
    Stop; DB.Commit;
    DB.ExecSQL('CREATE INDEX PublicationReferenceRow ON RegisteredReferences(RegistrationID,Kind,BookID,SourceKey,FileID,Resource)');
  finally Found.Free; Q.Free; Fresh.Free; end;
end;

procedure TTransferReferenceSnapshot.CheckGroup(Prepared:TPreparedTransferGroup);
var Fresh:TSQLiteQuery; DB:TSQLiteDatabase;
begin
  if Prepared=nil then raise EArgumentException.Create('Не указана проверенная группа.');
  DB:=FStore.DB; Fresh:=nil;
  try
    Fresh:=DB.NewQuery('SELECT r.RegistrationID,r.Kind,r.BookID,r.SourceKey,r.FileID,r.RetainReason,r.Resource,r.Owner '+
      'FROM RegisteredReferences r JOIN Files f ON f.ID=r.FileID WHERE f.GroupID=?',[Prepared.ID]); Fresh.Open;
    while not Fresh.Eof do
    begin
      Stop;
      var Count:=DB.QuerySingleInt('SELECT count(*) FROM Approved WHERE RegistrationID=? AND Kind=? AND BookID=? AND SourceKey=? '+
        'AND FileID=? AND RetainReason=? AND Resource=? AND Owner=?',
        [Fresh.FieldAsInt(0),Fresh.FieldAsInt(1),Fresh.FieldAsInt(2),Fresh.FieldAsString(3),Fresh.FieldAsInt(4),
         Fresh.FieldAsString(5),Fresh.FieldAsInt(6),Fresh.FieldAsString(7)]);
      // New personal cards for an already reviewed main book are reconciled by
      // ApplyTransferLocations in the locked personal transaction.
      if (Count=0) and (Fresh.FieldAsInt(1)=1) and (Fresh.FieldAsInt(6)=0) and (Fresh.FieldAsString(5)='') then
        Count:=DB.QuerySingleInt('SELECT count(*) FROM Approved WHERE RegistrationID=? AND Kind=0 AND BookID=? '+
          'AND FileID=? AND Resource=0 AND RetainReason=''''',
          [Fresh.FieldAsInt(0),Fresh.FieldAsInt(2),Fresh.FieldAsInt(4)]);
      if Count=0 then Changed;
      Fresh.Next;
    end;
    FreeAndNil(Fresh);
    // A disappeared non-personal reference can mean that its row now points
    // elsewhere or an archive became unavailable; neither permits publication.
    if DB.QuerySingleInt('SELECT count(*) FROM Approved a JOIN Files f ON f.ID=a.FileID WHERE f.GroupID=? AND a.Kind<>1 AND NOT EXISTS '+
      '(SELECT 1 FROM RegisteredReferences r WHERE r.RegistrationID=a.RegistrationID AND r.Kind=a.Kind '+
      'AND r.BookID=a.BookID AND r.SourceKey=a.SourceKey AND r.FileID=a.FileID AND r.Resource=a.Resource)',[Prepared.ID])<>0 then Changed;
    Stop;
  finally Fresh.Free; end;
end;

destructor TTransferReferenceSnapshot.Destroy;
begin FStore.Free; inherited; end;

procedure CheckTransferPublicationReferences(Review:TSQLiteDatabase;
  const PersonalFile,WorkRoot:string; Prepared:TPreparedTransferGroup;
  const EffectiveCatalogue:TFunc<Integer,string>; const Cancelled:TFunc<Boolean>);
begin
  var Snapshot:=TTransferReferenceSnapshot.Create(Review,PersonalFile,WorkRoot,EffectiveCatalogue,
    procedure(Targets:TSQLiteDatabase)
    begin
      for var I:=0 to Prepared.Count-1 do
        Targets.ExecSQL('INSERT OR IGNORE INTO ReferenceTargets VALUES(?,?)',
          [Copy(Prepared.CopyAt(I).Identity,1,25),Prepared.FileID(I)]);
    end,Cancelled);
  try Snapshot.CheckGroup(Prepared); finally Snapshot.Free; end;
end;

end.
