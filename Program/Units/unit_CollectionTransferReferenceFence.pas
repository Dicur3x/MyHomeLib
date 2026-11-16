unit unit_CollectionTransferReferenceFence;

interface

uses System.SysUtils, SQLiteWrap, unit_CollectionTransferJournal;

// Caller holds BEGIN IMMEDIATE on personal and all reviewed ready catalogues.
// Re-scan current references before publishing any archive locator. This is not
// a source-removal authorization; another live session is needed before unlink.
procedure CheckTransferPublicationReferences(Review:TSQLiteDatabase;
  const PersonalFile,WorkRoot:string; Prepared:TPreparedTransferGroup;
  const EffectiveCatalogue:TFunc<Integer,string>; const Cancelled:TFunc<Boolean>);

implementation

uses System.Classes, unit_BookCompressionPlanStore, unit_CollectionTransferReferences,
  unit_BookCompressionReceipt;

procedure CheckTransferPublicationReferences(Review:TSQLiteDatabase;
  const PersonalFile,WorkRoot:string; Prepared:TPreparedTransferGroup;
  const EffectiveCatalogue:TFunc<Integer,string>; const Cancelled:TFunc<Boolean>);
var Store:TCompressionPlanStore; Fresh,Q,Found:TSQLiteQuery; DB:TSQLiteDatabase;
  procedure Stop;
  begin
    if Assigned(Cancelled) and Cancelled() then
      raise EAbort.Create('Проверка новых ссылок остановлена. Исходные книги сохранены.');
  end;
  procedure Changed;
  begin
    raise EReadError.Create('Ссылки на переносимые файлы или подключения изменились. '+
      'Нужен новый план переноса; исходные книги сохранены.');
  end;
begin
  if (Review=nil) or (Prepared=nil) or not Assigned(EffectiveCatalogue) then
    raise EArgumentException.Create('Нужна проверенная группа для повторной проверки ссылок.');
  Store:=TCompressionPlanStore.Create(WorkRoot); Fresh:=nil; Q:=nil; Found:=nil;
  try
    DB:=Store.DB; DB.ExecSQL('BEGIN');
    DB.ExecSQL('CREATE TABLE Context(Name TEXT PRIMARY KEY,Value TEXT) WITHOUT ROWID');
    Q:=Review.NewQuery('SELECT Name,Value FROM Context'); Q.Open;
    while not Q.Eof do begin DB.ExecSQL('INSERT INTO Context VALUES(?,?)',[Q.FieldAsString(0),Q.FieldAsString(1)]); Q.Next; end;
    FreeAndNil(Q);
    DB.ExecSQL('DELETE FROM Context WHERE Name=''reference_rows''');
    DB.ExecSQL('CREATE TABLE Files(ID INTEGER PRIMARY KEY,Identity TEXT,GroupID INTEGER)');
    Q:=Review.NewQuery('SELECT ID,Identity,GroupID FROM Files'); Q.Open;
    while not Q.Eof do
    begin
      Stop; DB.ExecSQL('INSERT INTO Files VALUES(?,?,?)',[Q.FieldAsInt(0),Q.FieldAsString(1),Q.FieldAsInt(2)]); Q.Next;
    end;
    FreeAndNil(Q);
    DB.ExecSQL('CREATE TABLE Edges(OwnerID INTEGER,FileID INTEGER,PRIMARY KEY(OwnerID,FileID)) WITHOUT ROWID');
    Q:=Review.NewQuery('SELECT OwnerID,FileID FROM Edges'); Q.Open;
    while not Q.Eof do begin DB.ExecSQL('INSERT OR IGNORE INTO Edges VALUES(?,?)',[Q.FieldAsInt(0),Q.FieldAsInt(1)]); Q.Next; end;
    FreeAndNil(Q);
    CaptureTransferReferences(DB,PersonalFile,Cancelled,nil,
      procedure(Targets:TSQLiteDatabase)
      begin
        // Already published rows resolve to the copied file's new physical ID.
        // Only complete, leased and verified copies can introduce that alias.
        for var I:=0 to Prepared.Count-1 do
          Targets.ExecSQL('INSERT OR IGNORE INTO ReferenceTargets VALUES(?,?)',
            [Copy(Prepared.CopyAt(I).Identity,1,25),Prepared.FileID(I)]);
      end);
    if TransferReferenceConflictCount(DB)<>0 then Changed;
    if DB.QuerySingleInt('SELECT count(*) FROM ReferenceRegistrations')<>
      Review.QuerySingleInt('SELECT count(*) FROM ReferenceRegistrations') then Changed;
    Fresh:=DB.NewQuery('SELECT RegistrationID,RawRoot,Code,State,SourcesJSON,CatalogueKey,RawCatalogue FROM ReferenceRegistrations'); Fresh.Open;
    while not Fresh.Eof do
    begin
      Stop;
      Found:=Review.NewQuery('SELECT RawRoot,Code,State,SourcesJSON,RawCatalogue FROM ReferenceRegistrations WHERE RegistrationID=?',[Fresh.FieldAsInt(0)]); Found.Open;
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
    Q:=Review.NewQuery('SELECT r.RegistrationID,r.Kind,r.BookID,r.SourceKey,r.FileID,r.RetainReason,r.Resource,r.Owner '+
      'FROM RegisteredReferences r JOIN Files f ON f.ID=r.FileID WHERE f.GroupID=?',[Prepared.ID]); Q.Open;
    while not Q.Eof do
    begin
      Stop; DB.ExecSQL('INSERT OR IGNORE INTO Approved VALUES(?,?,?,?,?,?,?,?)',
        [Q.FieldAsInt(0),Q.FieldAsInt(1),Q.FieldAsInt(2),Q.FieldAsString(3),Q.FieldAsInt(4),Q.FieldAsString(5),Q.FieldAsInt(6),Q.FieldAsString(7)]);
      Q.Next;
    end;
    FreeAndNil(Q);
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
    DB.ExecSQL('CREATE INDEX PublicationReferenceRow ON RegisteredReferences(RegistrationID,Kind,BookID,SourceKey,FileID,Resource)');
    // A disappeared non-personal reference can mean that its row now points
    // elsewhere or an archive became unavailable; neither permits publication.
    if DB.QuerySingleInt('SELECT count(*) FROM Approved a WHERE a.Kind<>1 AND NOT EXISTS '+
      '(SELECT 1 FROM RegisteredReferences r WHERE r.RegistrationID=a.RegistrationID AND r.Kind=a.Kind '+
      'AND r.BookID=a.BookID AND r.SourceKey=a.SourceKey AND r.FileID=a.FileID AND r.Resource=a.Resource)')<>0 then Changed;
    Fresh:=DB.NewQuery('SELECT RegistrationID,Path,Reason FROM ReferenceIssues'); Fresh.Open;
    while not Fresh.Eof do
    begin
      Stop;
      if Review.QuerySingleInt('SELECT count(*) FROM ReferenceIssues WHERE RegistrationID=? AND Path=? AND Reason=?',
        [Fresh.FieldAsInt(0),Fresh.FieldAsString(1),Fresh.FieldAsString(2)])=0 then Changed;
      Fresh.Next;
    end;
    Stop; DB.Commit;
  finally Found.Free; Q.Free; Fresh.Free; Store.Free; end;
end;

end.
