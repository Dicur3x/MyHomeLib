unit unit_CollectionTransferLocations;

interface

uses System.SysUtils, SQLiteWrap, unit_CollectionTransferJournal;

type TTransferLocationResult=record Rows,Retained,History:Int64; end;

// Caller owns one database transaction and retains the complete prepared group.
// Registration IDs must enumerate this database's participating registrations.
function ApplyTransferLocations(DB,Personal,Review:TSQLiteDatabase; Prepared:TPreparedTransferGroup;
  const Operation,ReviewSHA:string; const Registrations:TArray<Integer>; PersonalRows:Boolean;
  VerifyOnly:Boolean=False; ReconcileOnly:Boolean=False; Finalizing:Boolean=False):TTransferLocationResult;

implementation

uses System.Classes, System.IOUtils, System.JSON, System.Hash, System.StrUtils, System.Generics.Collections,
  SQLite3, unit_Globals, unit_Settings, dm_user, unit_CollectionTransferPlan, unit_CollectionTransferHistory,
  unit_BookCompressionReceipt, unit_CollectionTransferLayout, unit_ReaderHistoryAliases;

procedure EnableLocatorTriggers(Context:TSQLite3Context; Count:Integer; Values:TSQLite3Value); cdecl;
begin SQLite3_Result_Int(Context,1); end;

function DatabaseKey(DB:TSQLiteDatabase):string;
begin
  var Q:=DB.NewQuery('PRAGMA database_list');
  try
    Q.Open; Result:='';
    while not Q.Eof do begin if Q.FieldAsString(1)='main' then Exit(CompressionFileKey(Q.FieldAsString(2))); Q.Next; end;
  finally Q.Free; end;
end;

procedure Project(const Original:TBookRecord; const Source,Destination:string; out Folder,FileName:string;
  RequireSource:Boolean=True);
var Canonical,Identity:string; Bytes:Int64;
begin
  var Before:=Original;
  // Archive fallback changes ZIP to 7z, not the native locator kind. Use the
  // frozen logical container to reconstruct that kind without probing old names.
  var Container:=TPath.Combine(Before.CollectionRoot,Before.Folder);
  if RequireSource then Container:=Before.GetBookContainer;
  var Format:=Before.GetBookFormat(Container);
  if RequireSource then
  begin
    TransferReadFileState(Before.GetBookFileName(Container),Canonical,Identity,Bytes);
    if not SameFileName(Canonical,Source) and not SameFileName(Canonical,Destination) then
      raise EReadError.Create('Запись книги больше не относится к проверенному файлу.');
  end;
  var After:=Before;
  if Format in [bfFb2Archive,bfRawArchive] then After.Folder:=Destination
  else
  begin
    After.Folder:=IncludeTrailingPathDelimiter(ExtractFileDir(Destination));
    After.FileName:=ExtractFileName(Destination);
    if Format<>bfFbd then
    begin
      if not After.FileName.EndsWith(After.FileExt,True) then raise EReadError.Create('Расширение копии книги изменилось.');
      SetLength(After.FileName,Length(After.FileName)-Length(After.FileExt));
    end;
    if After.GetBookFormat<>Format then
    begin
      // Older linked locators can carry an absolute filename and a relative
      // folder. Preserve that native format rather than toggling FBD/raw mode.
      After.Folder:=''; After.FileName:=Destination;
      if Format<>bfFbd then SetLength(After.FileName,Length(After.FileName)-Length(After.FileExt));
    end;
  end;
  if After.GetBookFormat<>Format then raise EReadError.Create('Новый адрес меняет способ чтения книги.');
  TransferReadFileState(After.GetBookFileName,Canonical,Identity,Bytes);
  if not SameFileName(Canonical,Destination) then raise EReadError.Create('Новый адрес книги не ведёт к проверенной копии.');
  Folder:=After.Folder; FileName:=After.FileName;
end;

function FrozenPersonalCopy(Review:TSQLiteDatabase; Prepared:TPreparedTransferGroup;
  CID,BookID:Integer; const Book:TBookRecord):Integer;
begin
  Result:=-1;
  var Q:=Review.NewQuery('SELECT r.FileID,r.Folder,r.FileName,r.Ext,r.InsideNo,r.LibID '+
    'FROM RegisteredReferences r JOIN Files f ON f.ID=r.FileID WHERE r.RegistrationID=? AND r.Kind=0 AND '+
    'r.BookID=? AND r.Resource=0 AND r.RetainReason='''' AND f.GroupID=?',[CID,BookID,Prepared.ID]);
  try
    Q.Open;
    while not Q.Eof do
    begin
      var Original:=Default(TBookRecord); Original.CollectionRoot:=Book.CollectionRoot;
      Original.Folder:=Q.FieldAsString(1); Original.FileName:=Q.FieldAsString(2); Original.FileExt:=Q.FieldAsString(3);
      Original.InsideNo:=Q.FieldAsInt(4); Original.LibID:=Q.FieldAsString(5);
      var Container:=TPath.Combine(Book.CollectionRoot,Book.Folder);
      var Logical:=ExpandFileName(Book.GetBookFileName(Container));
      var OriginalContainer:=TPath.Combine(Original.CollectionRoot,Original.Folder);
      var OldLogical:=ExpandFileName(Original.GetBookFileName(OriginalContainer));
      if (Book.FileName=Original.FileName) and (Book.FileExt=Original.FileExt) and (Book.InsideNo=Original.InsideNo) and
        (Book.GetBookFormat(Container)=Original.GetBookFormat(OriginalContainer)) then
        for var I:=0 to Prepared.Count-1 do
          if (Prepared.FileID(I)=Q.FieldAsInt(0)) and
            (SameFileName(Logical,OldLogical) or SameFileName(Logical,Prepared.CopyAt(I).Source)) then
          begin
            if (Result>=0) and (Result<>I) then raise EReadError.Create('Неоднозначная новая личная запись переноса.');
            Result:=I;
          end;
      Q.Next;
    end;
  finally Q.Free; end;
end;

procedure NewPersonalRows(DB,Review:TSQLiteDatabase; Prepared:TPreparedTransferGroup;
  const Registrations:TArray<Integer>; Seen:TDictionary<string,Boolean>; var Changed,Retained:Int64;
  VerifyOnly,ReconcileOnly:Boolean; ReaderAliases:TReaderHistoryAliasWriter);
var Candidates,Live,Root:TSQLiteQuery; Canonical,Identity,Folder,FileName:string; Bytes:Int64;
begin
  for var CID in Registrations do
  begin
    Root:=DB.NewQuery('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[CID]);
    var CollectionRoot:='';
    try Root.Open; if Root.Eof then raise EReadError.Create('Личное подключение исчезло.');
      CollectionRoot:=Settings.ExpandCollectionRoot(Root.FieldAsString(0));
    finally Root.Free; end;
    // Indexed BookID lookups cover cards created after the review without
    // rescanning every catalogue or restoring an earlier personal snapshot.
    Candidates:=Review.NewQuery('SELECT DISTINCT r.BookID FROM RegisteredReferences r JOIN Files f ON f.ID=r.FileID '+
      'WHERE r.RegistrationID=? AND f.GroupID=? AND r.Resource=0',[CID,Prepared.ID]);
    try
      Candidates.Open;
      while not Candidates.Eof do
      begin
        var BookID:=Candidates.FieldAsInt(0); var Key:=IntToStr(CID)+':1:'+IntToStr(BookID)+':';
        if Seen.ContainsKey(Key) then begin Candidates.Next; Continue; end;
        Live:=DB.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=? AND DatabaseID=?',[BookID,CID]);
        var Book:=Default(TBookRecord); var Exists:=False;
        try
          Live.Open; Exists:=not Live.Eof;
          if Exists then
          begin
            Book.CollectionRoot:=CollectionRoot; Book.LibID:=Live.FieldAsString(0); Book.Folder:=Live.FieldAsString(1);
            Book.FileName:=Live.FieldAsString(2); Book.FileExt:=Live.FieldAsString(3); Book.InsideNo:=Live.FieldAsInt(4);
          end;
        finally Live.Free; end;
        if Exists and (Book.FileName<>'') then
        begin
          var Available:=True;
          var Missing:=False;
          try TransferReadFileState(Book.GetBookFileName,Canonical,Identity,Bytes);
          except
            on E:EOSError do begin if not (E.ErrorCode in [2,3]) then raise; Available:=False; Missing:=True; end;
            on E:EReadError do Available:=False; // Unsupported aliases keep their original locator.
          end;
          var Selected:=-1;
          if Missing and ReconcileOnly then Selected:=FrozenPersonalCopy(Review,Prepared,CID,BookID,Book);
          if Available then
            for var I:=0 to Prepared.Count-1 do
              if (SameFileName(Canonical,Prepared.CopyAt(I).Destination) and (Identity=Prepared.CopyAt(I).Identity)) or
                (SameFileName(Canonical,Prepared.CopyAt(I).Source) and
                  (Identity=Review.QuerySingleString('SELECT Identity FROM Files WHERE ID=?',[Prepared.FileID(I)]))) then
              begin Selected:=I; Break; end;
          if Selected<0 then
          begin
            if (VerifyOnly or ReconcileOnly) and
              (not Available or (FrozenPersonalCopy(Review,Prepared,CID,BookID,Book)>=0)) then Inc(Retained);
          end
          else
              begin
                var Item:=Prepared.CopyAt(Selected);
                if VerifyOnly and not SameFileName(Canonical,Item.Destination) then
                  raise EReadError.Create('Новая личная запись ещё ссылается на исходный файл.');
                Project(Book,Item.Source,Item.Destination,Folder,FileName,not (VerifyOnly or ReconcileOnly));
                Book.BookKey:=CreateBookKey(BookID,CID);
                var AfterBook:=Book; AfterBook.Folder:=Folder; AfterBook.FileName:=FileName;
                ReaderAliases.RecordMove(Book,AfterBook,VerifyOnly);
                if (Folder<>Book.Folder) or (FileName<>Book.FileName) then
                begin
                  if VerifyOnly then raise EReadError.Create('Новый личный адрес книги не совпал с проверенной копией.');
                  DB.ExecSQL('UPDATE Books SET Folder=?,FileName=? WHERE BookID=? AND DatabaseID=?',[Folder,FileName,BookID,CID]);
                  if DB.LastChangedRows<>1 then raise EWriteError.Create('Не удалось обновить новый личный адрес книги.');
                  Inc(Changed);
                end;
              end;
        end;
        Candidates.Next;
      end;
    finally Candidates.Free; end;
  end;
end;

function ApplyTransferLocations(DB,Personal,Review:TSQLiteDatabase; Prepared:TPreparedTransferGroup;
  const Operation,ReviewSHA:string; const Registrations:TArray<Integer>; PersonalRows:Boolean;
  VerifyOnly,ReconcileOnly,Finalizing:Boolean):TTransferLocationResult;
var R,Rows,Live,Marker:TSQLiteQuery; Allowed,Seen,Unsafe:TDictionary<string,Boolean>; Bind:TJSONArray;
    FinalLayout:TCollectionTransferLayout; ReaderAliases:TReaderHistoryAliasWriter;
begin
  Result:=Default(TTransferLocationResult); R:=nil; Rows:=nil; Live:=nil; Marker:=nil; FinalLayout:=nil; ReaderAliases:=nil;
  if (DB=nil) or not DB.InTransaction or (Prepared=nil) or (Length(Registrations)=0) or
    (Length(ReviewSHA)<>64) or (Operation='') then raise EArgumentException.Create('Нужна привязанная транзакция расположений.');
  var ActualKey:=DatabaseKey(DB); var PersonalKey:=Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal_key''');
  if (DatabaseKey(Personal)<>PersonalKey) or (PersonalRows<>(ActualKey=PersonalKey)) then
    raise EReadError.Create('Транзакция относится к другой базе данных.');
  Allowed:=TDictionary<string,Boolean>.Create; Seen:=TDictionary<string,Boolean>.Create;
  Unsafe:=TDictionary<string,Boolean>.Create; Bind:=TJSONArray.Create;
  try
    ReaderAliases:=TReaderHistoryAliasWriter.Create(Personal,Operation,ReviewSHA);
    if Finalizing then FinalLayout:=TCollectionTransferLayout.Create(Review);
    if not VerifyOnly then DB.AddFunction('MHL_TRIGGERS_ON',0,EnableLocatorTriggers);
    for var CID in Registrations do
    begin
      R:=Personal.NewQuery('SELECT DBFileName,RootFolder,Code FROM Bases WHERE DatabaseID=?',[CID]); R.Open;
      var Frozen:=Review.NewQuery('SELECT RawRoot,Code FROM ReferenceRegistrations WHERE RegistrationID=?',[CID]);
      try
        Frozen.Open;
        var RootMatches:=not R.Eof and not Frozen.Eof and (R.FieldAsString(1)=Frozen.FieldAsString(0));
        if Finalizing and (CID=StrToInt(Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''collection'''))) and not R.Eof then
        begin
          RootMatches:=RootMatches or (R.FieldAsString(1)=FinalLayout.RootDestination('collection'));
        end;
        if R.Eof or Frozen.Eof or not RootMatches or
          (R.FieldAsInt(2)<>Frozen.FieldAsInt(1)) or
          (not PersonalRows and (CompressionFileKey(Settings.ExpandCollectionFileName(R.FieldAsString(0)))<>ActualKey)) then
          raise EReadError.Create('Подключение изменилось перед сохранением адресов.');
      finally Frozen.Free; end;
      Allowed.AddOrSetValue(IntToStr(CID),True); FreeAndNil(R);
    end;
    if not PersonalRows then
    begin
      R:=Personal.NewQuery('SELECT DatabaseID,DBFileName FROM Bases'); R.Open;
      while not R.Eof do
      begin
        var Key:='';
        try Key:=CompressionFileKey(Settings.ExpandCollectionFileName(R.FieldAsString(1)));
        except on E:EOSError do begin if not (E.ErrorCode in [2,3]) then raise; end; end;
        if (Key=ActualKey) and not Allowed.ContainsKey(IntToStr(R.FieldAsInt(0))) then
          raise EReadError.Create('Не перечислены все подключения общего каталога.');
        R.Next;
      end;
      FreeAndNil(R);
    end;
    R:=Review.NewQuery('SELECT r.RegistrationID,r.Kind,r.BookID,r.SourceKey FROM RegisteredReferences r JOIN Files f ON f.ID=r.FileID '+
      'WHERE f.GroupID=? AND r.RetainReason<>'''' AND r.Resource=0',[Prepared.ID]); R.Open;
    while not R.Eof do
    begin
      if Allowed.ContainsKey(IntToStr(R.FieldAsInt(0))) and ((R.FieldAsInt(1)=1)=PersonalRows) then
      begin
        var Key:=IntToStr(R.FieldAsInt(1))+':'+IntToStr(R.FieldAsInt(2))+':'+R.FieldAsString(3);
        if PersonalRows then Key:=IntToStr(R.FieldAsInt(0))+':'+Key;
        Unsafe.AddOrSetValue(Key,True);
      end;
      R.Next;
    end;
    FreeAndNil(R);
    Rows:=Review.NewQuery('SELECT r.RegistrationID,r.Kind,r.BookID,r.SourceKey,r.LibID,r.Folder,r.FileName,r.Ext,r.InsideNo,'+
      'r.CopyRoot,r.FileID,r.RetainReason,c.Root,c.RawRoot FROM RegisteredReferences r JOIN Files f ON f.ID=r.FileID '+
      'JOIN ReferenceRegistrations c ON c.RegistrationID=r.RegistrationID WHERE f.GroupID=? AND r.Resource=0 ORDER BY r.ID',[Prepared.ID]);
    Rows.Open;
    while not Rows.Eof do
    begin
      var CID:=Rows.FieldAsInt(0); var Kind:=Rows.FieldAsInt(1);
      if not Allowed.ContainsKey(IntToStr(CID)) or ((Kind=1)<>PersonalRows) then begin Rows.Next; Continue; end;
      var Key:=IntToStr(Kind)+':'+IntToStr(Rows.FieldAsInt(2))+':'+Rows.FieldAsString(3);
      if PersonalRows then Key:=IntToStr(CID)+':'+Key;
      if Seen.ContainsKey(Key) then begin Rows.Next; Continue; end;
      Seen.Add(Key,True);
      if Unsafe.ContainsKey(Key) then begin Inc(Result.Retained); Rows.Next; Continue; end;
      var CopyIndex:=-1;
      for var I:=0 to Prepared.Count-1 do if Prepared.FileID(I)=Rows.FieldAsInt(10) then begin CopyIndex:=I; Break; end;
      if CopyIndex<0 then raise EReadError.Create('Для записи нет полной проверенной копии.');
      var Item:=Prepared.CopyAt(CopyIndex); var Original:=Default(TBookRecord);
      Original.CollectionRoot:=Rows.FieldAsString(12); Original.LibID:=Rows.FieldAsString(4); Original.Folder:=Rows.FieldAsString(5);
      Original.FileName:=Rows.FieldAsString(6); Original.FileExt:=Rows.FieldAsString(7); Original.InsideNo:=Rows.FieldAsInt(8);
      if (Kind=2) and (Rows.FieldAsString(9)<>'') then Original.CollectionRoot:=Settings.ExpandCollectionRoot(Rows.FieldAsString(9));
      var Folder,FileName:string; Project(Original,Item.Source,Item.Destination,Folder,FileName,not (VerifyOnly or ReconcileOnly));
      var Row:=TJSONArray.Create; Bind.AddElement(Row);
      Row.Add(Key); Row.Add(Original.LibID); Row.Add(Original.Folder); Row.Add(Original.FileName); Row.Add(Original.FileExt);
      Row.Add(Original.InsideNo); Row.Add(Rows.FieldAsString(9)); Row.Add(Folder); Row.Add(FileName); Row.Add(Item.Identity); Row.Add(Item.SHA256);
      var Table:='Books'; var Where:='BookID=?';
      if Kind=2 then begin Table:='CatalogBookCopies'; Where:='SourceKey=?'; end;
      if PersonalRows then Where:=Where+' AND DatabaseID=?';
      Live:=DB.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo'+
        IfThen(Kind=2,',Root,BookID','')+' FROM '+Table+' WHERE '+Where);
      if Kind=2 then Live.SetParam(0,Rows.FieldAsString(3)) else Live.SetParam(0,Rows.FieldAsInt(2));
      if PersonalRows then Live.SetParam(1,CID);
      Live.Open;
      if Live.Eof then
      begin
        FreeAndNil(Live); if not PersonalRows then raise EReadError.Create('Запись книги удалена после проверки.');
        Rows.Next; Continue;
      end;
      var OldLocation:=(Live.FieldAsString(1)=Original.Folder) and (Live.FieldAsString(2)=Original.FileName);
      var NewLocation:=(Live.FieldAsString(1)=Folder) and (Live.FieldAsString(2)=FileName);
      var CopyRootMatches:=True;
      if Kind=2 then
      begin
        CopyRootMatches:=Live.FieldAsString(5)=Rows.FieldAsString(9);
        if Finalizing and (ActualKey=Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''catalogue_key''')) and
          (Rows.FieldAsString(9)<>'') then
        begin
          CopyRootMatches:=CopyRootMatches or
            (Live.FieldAsString(5)=FinalLayout.RelocatePath(Settings.ExpandCollectionRoot(Rows.FieldAsString(9))));
        end;
      end;
      if (Live.FieldAsString(0)<>Original.LibID) or (Live.FieldAsString(3)<>Original.FileExt) or
        (Live.FieldAsInt(4)<>Original.InsideNo) or not (OldLocation or NewLocation) or
        ((Kind=2) and (not CopyRootMatches or (Live.FieldAsInt(6)<>Rows.FieldAsInt(2)))) then
        raise EReadError.Create('Расположение или номер книги изменились перед сохранением.');
      FreeAndNil(Live);
      if VerifyOnly and not NewLocation then raise EReadError.Create('Новый адрес книги ещё не сохранён.');
      if ReconcileOnly and not PersonalRows and not NewLocation then
        raise EReadError.Create('Сохранённый адрес каталога изменился после публикации группы.');
      var ReaderBefore:=Original; ReaderBefore.BookKey:=CreateBookKey(Rows.FieldAsInt(2),CID);
      if (Kind<>2) or (Rows.FieldAsString(9)='') then
        ReaderBefore.CollectionRoot:=Settings.ExpandCollectionRoot(Rows.FieldAsString(13));
      var ReaderAfter:=ReaderBefore; ReaderAfter.Folder:=Folder; ReaderAfter.FileName:=FileName;
      var ReaderBinding:=ReaderAliases.RecordMove(ReaderBefore,ReaderAfter,VerifyOnly or ReconcileOnly);
      if ReaderBinding<>'' then Row.Add('reader-history:'+ReaderBinding);
      if not NewLocation then
      begin
        Live:=DB.NewQuery('UPDATE '+Table+' SET Folder=?,FileName=? WHERE '+Where);
        Live.SetParam(0,Folder); Live.SetParam(1,FileName);
        if Kind=2 then Live.SetParam(2,Rows.FieldAsString(3)) else Live.SetParam(2,Rows.FieldAsInt(2));
        if PersonalRows then Live.SetParam(3,CID);
        Live.ExecSQL; if DB.LastChangedRows<>1 then raise EWriteError.Create('Не удалось сохранить адрес книги.');
        FreeAndNil(Live); Inc(Result.Rows);
      end;
      Rows.Next;
    end;
    FreeAndNil(Rows);
    if PersonalRows then NewPersonalRows(DB,Review,Prepared,Registrations,Seen,Result.Rows,Result.Retained,VerifyOnly,ReconcileOnly,ReaderAliases);
    var BindingSHA:=THashSHA2.GetHashString(Bind.ToJSON);
    if VerifyOnly or ReconcileOnly then
    begin
      if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibreTransferLocations''')<>1 then
        raise EReadError.Create('Нет квитанции сохранённых адресов переноса.');
    end
    else DB.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibreTransferLocations(Operation TEXT,GroupID INTEGER,ReviewSHA256 TEXT,BindingSHA256 TEXT,'+
      'PRIMARY KEY(Operation,GroupID)) WITHOUT ROWID');
    Marker:=DB.NewQuery('SELECT ReviewSHA256,BindingSHA256 FROM HomeLibreTransferLocations WHERE Operation=? AND GroupID=?',[Operation,Prepared.ID]); Marker.Open;
    if (VerifyOnly or ReconcileOnly) and Marker.Eof then raise EReadError.Create('Нет квитанции сохранённых адресов этой группы.');
    if not Marker.Eof and ((Marker.FieldAsString(0)<>ReviewSHA) or (Marker.FieldAsString(1)<>BindingSHA)) then
      raise EReadError.Create('Квитанция расположений относится к другой проверке.');
    FreeAndNil(Marker);
    if not VerifyOnly then
    begin
      if not PersonalRows and not ReconcileOnly then Result.History:=RebindTransferHistory(DB,Review,Prepared);
      DB.ExecSQL('INSERT OR IGNORE INTO HomeLibreTransferLocations VALUES(?,?,?,?)',[Operation,Prepared.ID,ReviewSHA,BindingSHA]);
    end;
  finally ReaderAliases.Free; FinalLayout.Free; Marker.Free; Live.Free; Rows.Free; R.Free; Bind.Free; Unsafe.Free; Seen.Free; Allowed.Free; end;
end;

end.
