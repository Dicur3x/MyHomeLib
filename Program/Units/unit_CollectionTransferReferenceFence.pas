unit unit_CollectionTransferReferenceFence;

interface

uses System.SysUtils, System.Classes, SQLiteWrap, unit_CollectionTransferJournal, unit_BookCompressionPlanStore;

type TTransferReferenceSnapshot=class
  private
    FReview:TSQLiteDatabase;
    FStore:TCompressionPlanStore;
    FIndexedApproval:Boolean;
    FApprovalLease:TFileStream;
    FSqlCancelled:Boolean;
    FSqlError:string;
    FPreviousSqlCancel:TSQLiteCancelCallback;
    FCancelled:TFunc<Boolean>;
    procedure Stop;
    function PollSQL:Boolean;
    procedure Changed;
  public
    // Caller holds writer transactions on personal and every ready catalogue.
    constructor Create(Review:TSQLiteDatabase; const PersonalFile,WorkRoot:string;
      const EffectiveCatalogue:TFunc<Integer,string>; const ExtraTargets:TProc<TSQLiteDatabase>;
      const Cancelled:TFunc<Boolean>; const FinalSources:TFunc<Integer,string> = nil; const FinalRoot:string = '');
    destructor Destroy; override;
    procedure CheckGroup(Prepared:TPreparedTransferGroup);
    function RetainedFiles(Prepared:TPreparedTransferGroup):TArray<Int64>;
end;

function ExpandTransferRetention(Review:TSQLiteDatabase; GroupID:Int64; const Seeds:TArray<Int64>):TArray<Int64>;

procedure CheckTransferPublicationReferences(Review:TSQLiteDatabase;
  const PersonalFile,WorkRoot:string; Prepared:TPreparedTransferGroup;
  const EffectiveCatalogue:TFunc<Integer,string>; const Cancelled:TFunc<Boolean>);

{$IFDEF MHL_TRANSFER_TEST}
var TransferApprovalTestPoint:TProc<Boolean>;
    TransferApprovalReadOnlyProbe:TProc<TSQLiteDatabase>;
    TransferApprovalSQLTestPoint:TProc;
{$ENDIF}

implementation

uses System.IOUtils, System.Generics.Collections, unit_CollectionTransferReferences, unit_BookCompressionReceipt,
  unit_ZipMemberDeletion;

function FrozenReviewURI(Review:TSQLiteDatabase; out Path:string):string;
begin
  Result:=''; Path:=''; var Q:=Review.NewQuery('PRAGMA database_list');
  try Q.Open; while not Q.Eof do
    begin if Q.FieldAsString(1)='main' then begin Path:=Q.FieldAsString(2); Break; end; Q.Next; end;
  finally Q.Free; end;
  if Path.StartsWith('\\?\') then Delete(Path,1,4);
  // Preserve the previous projection for UNC/very long work paths. No URI
  // authority or host long-path assumptions are introduced for those callers.
  if (Length(ExtractFileDrive(Path))<>2) or (Length(Path)>=240) then Exit;
  var URI:='file:/'; var Raw:=TEncoding.UTF8.GetBytes(StringReplace(Path,'\','/',[rfReplaceAll]));
  for var B in Raw do
    if CharInSet(Char(B),['a'..'z','A'..'Z','0'..'9','/',':','-','_','.','~']) then URI:=URI+Char(B)
    else URI:=URI+'%'+IntToHex(B,2);
  Result:=URI+'?mode=ro&immutable=1';
end;

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

function TTransferReferenceSnapshot.PollSQL:Boolean;
begin
  Result:=False;
  try
{$IFDEF MHL_TRANSFER_TEST}
    if Assigned(TransferApprovalSQLTestPoint) then TransferApprovalSQLTestPoint;
{$ENDIF}
    Stop;
    if Assigned(FPreviousSqlCancel) and FPreviousSqlCancel() then FSqlCancelled:=True;
    Result:=FSqlCancelled;
  except
    on E:EAbort do begin FSqlCancelled:=True; Result:=True; end;
    on E:Exception do begin FSqlError:=E.Message; Result:=True; end;
  end;
end;

procedure TTransferReferenceSnapshot.Changed;
begin
  raise EReadError.Create('Ссылки на переносимые файлы или подключения изменились. '+
    'Нужен новый план переноса; исходные книги сохранены.');
end;

constructor TTransferReferenceSnapshot.Create(Review:TSQLiteDatabase;
  const PersonalFile,WorkRoot:string; const EffectiveCatalogue:TFunc<Integer,string>;
  const ExtraTargets:TProc<TSQLiteDatabase>; const Cancelled:TFunc<Boolean>;
  const FinalSources:TFunc<Integer,string>; const FinalRoot:string);
var Fresh,Q,Found:TSQLiteQuery; DB:TSQLiteDatabase;
begin
  inherited Create; FReview:=Review; FCancelled:=Cancelled;
  if (Review=nil) or not Assigned(EffectiveCatalogue) then
    raise EArgumentException.Create('Нужна проверенная группа для повторной проверки ссылок.');
  FStore:=TCompressionPlanStore.Create(WorkRoot,True); Fresh:=nil; Q:=nil; Found:=nil;
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
      if Found.Eof then Changed;
      var RootMatches:=Fresh.FieldAsString(1)=Found.FieldAsString(0);
      if (FinalRoot<>'') and (Fresh.FieldAsInt(0)=StrToInt(FReview.QuerySingleString('SELECT Value FROM Context WHERE Name=''collection'''))) then
        RootMatches:=RootMatches or (Fresh.FieldAsString(1)=FinalRoot);
      var SourcesMatch:=Fresh.FieldAsString(4)=Found.FieldAsString(3);
      if Assigned(FinalSources) and (Fresh.FieldAsString(3)='ready') then
        SourcesMatch:=SourcesMatch or (Fresh.FieldAsString(4)=FinalSources(Fresh.FieldAsInt(0)));
      if not RootMatches or (Fresh.FieldAsInt(2)<>Found.FieldAsInt(1)) or
        (Fresh.FieldAsString(3)<>Found.FieldAsString(2)) or not SourcesMatch then Changed;
      if (Fresh.FieldAsString(3)='ready') and
        (Fresh.FieldAsString(5)<>CompressionFileKey(EffectiveCatalogue(Fresh.FieldAsInt(0)))) then Changed;
      if (Fresh.FieldAsString(3)<>'ready') and (Fresh.FieldAsString(6)<>Found.FieldAsString(4)) then Changed;
      FreeAndNil(Found); Fresh.Next;
    end;
    FreeAndNil(Fresh);
    // New immutable reviews already index these exact keys. Old reviews retain
    // the original disk-backed projection; no mutable source is cached here.
    FIndexedApproval:=FReview.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''index'' AND name=''TransferApprovedLookup''')=1;
    var ApprovalPath:string; var URI:='';
    if FIndexedApproval then URI:=FrozenReviewURI(FReview,ApprovalPath);
    FIndexedApproval:=FIndexedApproval and (URI<>'');
    if FIndexedApproval then
    begin
      // The caller supplies the sealed review. Hold it against writes/rename
      // for the entire read-only attachment, independently of SQLite handles.
      FApprovalLease:=TFileStream.Create(DeletionNativePath(ApprovalPath),fmOpenRead or fmShareDenyWrite);
      DB.ExecSQL('ATTACH DATABASE ? AS fixed_approval',[URI]);
{$IFDEF MHL_TRANSFER_TEST}
      if Assigned(TransferApprovalReadOnlyProbe) then TransferApprovalReadOnlyProbe(DB);
{$ENDIF}
    end;
{$IFDEF MHL_TRANSFER_TEST}
    if Assigned(TransferApprovalTestPoint) then TransferApprovalTestPoint(FIndexedApproval);
{$ENDIF}
    if not FIndexedApproval then
    begin
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
    end;
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
var DB:TSQLiteDatabase; Table:string;
begin
  if Prepared=nil then raise EArgumentException.Create('Не указана проверенная группа.');
  DB:=FStore.DB;
  if FIndexedApproval then Table:='fixed_approval.RegisteredReferences' else Table:='Approved';
  FSqlCancelled:=False; FSqlError:=''; FPreviousSqlCancel:=SQLiteCancelCallback; SQLiteCancelCallback:=PollSQL;
  try
    try
      Stop;
      // New personal cards for an already reviewed main book are reconciled by
      // ApplyTransferLocations in the locked personal transaction.
      if DB.QuerySingleInt('SELECT count(*) FROM RegisteredReferences r JOIN Files f ON f.ID=r.FileID WHERE f.GroupID=? AND NOT EXISTS '+
        '(SELECT 1 FROM '+Table+' a WHERE a.RegistrationID=r.RegistrationID AND a.Kind=r.Kind AND a.BookID=r.BookID '+
        'AND a.SourceKey=r.SourceKey AND a.FileID=r.FileID AND a.RetainReason=r.RetainReason AND a.Resource=r.Resource AND a.Owner=r.Owner) '+
        'AND NOT(r.Kind=1 AND r.Resource=0 AND r.RetainReason='''' AND EXISTS(SELECT 1 FROM '+Table+' a WHERE '+
        'a.RegistrationID=r.RegistrationID AND a.Kind=0 AND a.BookID=r.BookID AND a.FileID=r.FileID AND a.Resource=0 AND a.RetainReason=''''))',
        [Prepared.ID])<>0 then Changed;
      Stop;
      // A disappeared non-personal reference must still prevent publication.
      if DB.QuerySingleInt('SELECT count(*) FROM '+Table+' a JOIN Files f ON f.ID=a.FileID WHERE f.GroupID=? AND a.Kind<>1 AND NOT EXISTS '+
        '(SELECT 1 FROM RegisteredReferences r WHERE r.RegistrationID=a.RegistrationID AND r.Kind=a.Kind '+
        'AND r.BookID=a.BookID AND r.SourceKey=a.SourceKey AND r.FileID=a.FileID AND r.Resource=a.Resource)',[Prepared.ID])<>0 then Changed;
      Stop;
    except
      if FSqlError<>'' then raise EReadError.Create(FSqlError);
      if FSqlCancelled then raise EAbort.Create('Проверка новых ссылок остановлена. Исходные книги сохранены.');
      raise;
    end;
  finally SQLiteCancelCallback:=FPreviousSqlCancel; FPreviousSqlCancel:=nil; end;
end;

destructor TTransferReferenceSnapshot.Destroy;
begin FStore.Free; FApprovalLease.Free; inherited; end;

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
