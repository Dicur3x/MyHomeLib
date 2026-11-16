unit unit_CollectionTransferFinalRows;

interface

uses System.SysUtils, SQLiteWrap;

type TTransferFinalRowsResult=record FutureRows,CopyRoots:Int64; end;

// The finalization controller must own writer transactions, a verified frozen
// review, published-group proofs and independent finalization intent. This
// primitive only applies/verifies reviewed unavailable locators and copy roots;
// it cannot authorize source removal, change default roots or complete a move.
function ApplyTransferFinalRows(DB,Personal,Review:TSQLiteDatabase;
  const Operation,ReviewSHA,IntentSHA:string; PersonalRows:Boolean;
  VerifyOnly:Boolean=False; const Cancelled:TFunc<Boolean> = nil;
  RecoverReaderAliases:Boolean=False):TTransferFinalRowsResult;

implementation

uses System.Classes, System.Hash, System.JSON, System.IOUtils, Winapi.Windows, SQLite3, unit_Globals,
  unit_CollectionTransferLayout, unit_BookCompressionReceipt, unit_ZipMemberDeletion, unit_Settings, dm_user,
  unit_ReaderHistoryAliases;

const ReceiptTable='HomeLibreTransferFinalRows';

procedure EnableLocatorTriggers(Context:TSQLite3Context; Count:Integer; Values:TSQLite3Value); cdecl;
begin SQLite3_Result_Int(Context,1); end;

function DatabaseKey(DB:TSQLiteDatabase):string;
begin
  var Q:=DB.NewQuery('PRAGMA database_list');
  try
    Q.Open;
    while not Q.Eof do
    begin
      if Q.FieldAsString(1)='main' then Exit(CompressionFileKey(Q.FieldAsString(2)));
      Q.Next;
    end;
    raise EReadError.Create('Не определена база итоговых адресов.');
  finally Q.Free; end;
end;

procedure CheckCancelled(const Cancelled:TFunc<Boolean>);
  begin
    if Assigned(Cancelled) and Cancelled() then
      raise EAbort.Create('Сохранение итоговых адресов остановлено.');
  end;

procedure Missing(const Path:string);
  begin
    if GetFileAttributes(PChar(DeletionNativePath(Path)))<>INVALID_FILE_ATTRIBUTES then
      raise EReadError.Create('Появился файл по отсутствовавшему адресу: '+Path);
    var Code:=GetLastError;
    if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
  end;

procedure BindFinalRow(var Hash:THashSHA2; const Values:array of string);
  begin
    var Row:=TJSONArray.Create;
    try
      for var Value in Values do Row.Add(Value);
      var Bytes:=TEncoding.UTF8.GetBytes(Row.ToJSON+#10); Hash.Update(Bytes,Length(Bytes));
    finally Row.Free; end;
  end;

function ApplyTransferFinalRows(DB,Personal,Review:TSQLiteDatabase;
  const Operation,ReviewSHA,IntentSHA:string; PersonalRows,VerifyOnly:Boolean;
  const Cancelled:TFunc<Boolean>; RecoverReaderAliases:Boolean):TTransferFinalRowsResult;
var Layout:TCollectionTransferLayout; Live,Bindings:TSQLiteQuery; Hash:THashSHA2;
    CID:Integer; Marked:Boolean; ActualKey,BindingSHA:string; Outcome:TTransferFinalRowsResult;
    ReaderAliases:TReaderHistoryAliasWriter;
begin
  Outcome:=Default(TTransferFinalRowsResult); Layout:=nil; Live:=nil; Bindings:=nil; ReaderAliases:=nil;
  if (DB=nil) or (Personal=nil) or (Review=nil) or not DB.InTransaction or not Personal.InTransaction or
    (Operation='') or (Length(ReviewSHA)<>64) or (Length(IntentSHA)<>64) then
    raise EArgumentException.Create('Нужна привязанная транзакция итоговых адресов.');
  CheckCancelled(Cancelled);
  if Operation<>Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''directory''') then
    raise EReadError.Create('Итоговые адреса относятся к другой операции.');
  if RecoverReaderAliases and (Personal.QuerySingleInt('SELECT count(*) FROM HomeLibreTransferFinalization '+
    'WHERE Operation=? AND ReviewSHA256=? AND IntentSHA256=? AND State=''intent''',[Operation,ReviewSHA,IntentSHA])<>1) then
    raise EReadError.Create('Нет независимого незавершённого намерения для восстановления истории чтения.');
  ActualKey:=DatabaseKey(DB);
  var PersonalKey:=Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal_key''');
  if (DatabaseKey(Personal)<>PersonalKey) or (PersonalRows<>(ActualKey=PersonalKey)) or
    (not PersonalRows and (ActualKey<>Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''catalogue_key'''))) then
    raise EReadError.Create('Выбрана другая база итоговых адресов.');
  CID:=StrToInt(Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''collection'''));
  var Receipt:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[ReceiptTable])=1;
  Marked:=Receipt and (DB.QuerySingleInt('SELECT count(*) FROM '+ReceiptTable+' WHERE Operation=?',[Operation])=1);
  if VerifyOnly and not Marked then raise EReadError.Create('Нет квитанции итоговых адресов.');
  Hash:=THashSHA2.Create;
  try
    ReaderAliases:=TReaderHistoryAliasWriter.Create(Personal,Operation,ReviewSHA);
    Layout:=TCollectionTransferLayout.Create(Review);
    if not VerifyOnly then DB.AddFunction('MHL_TRIGGERS_ON',0,EnableLocatorTriggers);
    Layout.ForEachFutureLocator(
      procedure(const Locator:TTransferFutureLocator)
      begin
        CheckCancelled(Cancelled);
        if ((Locator.Kind=1)<>PersonalRows) then Exit;
        Bindings:=Review.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo,Root,Source FROM Bindings WHERE ID=?',
          [Locator.BindingID]);
        try
          Bindings.Open;
          if Bindings.Eof then raise EReadError.Create('Нет исходного отсутствующего адреса.');
          Missing(Bindings.FieldAsString(6)); Missing(Locator.Source);
          BindFinalRow(Hash,['future',IntToStr(Locator.BindingID),IntToStr(Locator.Kind),IntToStr(Locator.BookID),Locator.SourceKey,
            Bindings.FieldAsString(0),Bindings.FieldAsString(1),Bindings.FieldAsString(2),Bindings.FieldAsString(3),
            Bindings.FieldAsString(4),Bindings.FieldAsString(5),Locator.Source,Locator.Folder,Locator.FileName,Locator.CopyRoot]);
          var Table:='Books'; var Where:='BookID=?';
          if Locator.Kind=2 then begin Table:='CatalogBookCopies'; Where:='SourceKey=?'; end;
          if PersonalRows then Where:=Where+' AND DatabaseID=?';
          Live:=DB.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM '+Table+' WHERE '+Where);
          if Locator.Kind=2 then Live.SetParam(0,Locator.SourceKey) else Live.SetParam(0,Locator.BookID);
          if PersonalRows then Live.SetParam(1,CID);
          Live.Open;
          if Live.Eof then
          begin
            if not PersonalRows then raise EReadError.Create('Отсутствующая запись книги удалена после проверки.');
            Exit; // Deleted personal cards are never recreated.
          end;
          var OldLocation:=(Live.FieldAsString(1)=Bindings.FieldAsString(1)) and
            (Live.FieldAsString(2)=Bindings.FieldAsString(2));
          var NewLocation:=(Live.FieldAsString(1)=Locator.Folder) and (Live.FieldAsString(2)=Locator.FileName);
          if (Live.FieldAsString(0)<>Bindings.FieldAsString(0)) or
            (Live.FieldAsString(3)<>Bindings.FieldAsString(3)) or (Live.FieldAsInt(4)<>Bindings.FieldAsInt(4)) or
            not (OldLocation or NewLocation) or ((Marked or VerifyOnly) and not NewLocation) then
            raise EReadError.Create('Отсутствующая книга изменилась перед сохранением итогового адреса.');
          FreeAndNil(Live);
          var ReaderBefore:=Default(TBookRecord); ReaderBefore.BookKey:=CreateBookKey(Locator.BookID,CID);
          ReaderBefore.LibID:=Bindings.FieldAsString(0); ReaderBefore.Folder:=Bindings.FieldAsString(1);
          ReaderBefore.FileName:=Bindings.FieldAsString(2); ReaderBefore.FileExt:=Bindings.FieldAsString(3);
          ReaderBefore.InsideNo:=Bindings.FieldAsInt(4);
          ReaderBefore.CollectionRoot:=Settings.ExpandCollectionRoot(Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''collection_root'''));
          if (Locator.Kind=2) and (Bindings.FieldAsString(5)<>'') then
            ReaderBefore.CollectionRoot:=Settings.ExpandCollectionRoot(Bindings.FieldAsString(5));
          var ReaderAfter:=ReaderBefore; ReaderAfter.Folder:=Locator.Folder; ReaderAfter.FileName:=Locator.FileName;
          ReaderAfter.CollectionRoot:=Layout.RootDestination('collection');
          if (Locator.Kind=2) and (Locator.CopyRoot<>'') then ReaderAfter.CollectionRoot:=Settings.ExpandCollectionRoot(Locator.CopyRoot);
          var ReaderBinding:=ReaderAliases.RecordMove(ReaderBefore,ReaderAfter,VerifyOnly and not RecoverReaderAliases);
          if ReaderBinding<>'' then BindFinalRow(Hash,['reader-history',ReaderBinding]);
          if not NewLocation then
          begin
            Live:=DB.NewQuery('UPDATE '+Table+' SET Folder=?,FileName=? WHERE '+Where);
            Live.SetParam(0,Locator.Folder); Live.SetParam(1,Locator.FileName);
            if Locator.Kind=2 then Live.SetParam(2,Locator.SourceKey) else Live.SetParam(2,Locator.BookID);
            if PersonalRows then Live.SetParam(3,CID);
            Live.ExecSQL;
            if DB.LastChangedRows<>1 then raise EWriteError.Create('Не сохранён итоговый адрес отсутствующей книги.');
            Inc(Outcome.FutureRows);
          end;
        finally FreeAndNil(Live); FreeAndNil(Bindings); end;
      end);
    if not PersonalRows then
    begin
      Bindings:=Review.NewQuery('SELECT BookID,SourceKey,LibID,Ext,InsideNo,Root FROM Bindings WHERE Kind=2 AND Root<>'''' ORDER BY ID');
      Bindings.Open;
      while not Bindings.Eof do
      begin
        CheckCancelled(Cancelled);
        var Before:=Bindings.FieldAsString(5);
        var After:=Layout.RelocatePath(Settings.ExpandCollectionRoot(Before));
        BindFinalRow(Hash,['copy-root',Bindings.FieldAsString(0),Bindings.FieldAsString(1),Bindings.FieldAsString(2),
          Bindings.FieldAsString(3),Bindings.FieldAsString(4),Before,After]);
        Live:=DB.NewQuery('SELECT BookID,LibID,Ext,InsideNo,Root,Folder,FileName FROM CatalogBookCopies WHERE SourceKey=?',[Bindings.FieldAsString(1)]);
        Live.Open;
        if Live.Eof or (Live.FieldAsInt(0)<>Bindings.FieldAsInt(0)) or
          (Live.FieldAsString(1)<>Bindings.FieldAsString(2)) or (Live.FieldAsString(2)<>Bindings.FieldAsString(3)) or
          (Live.FieldAsInt(3)<>Bindings.FieldAsInt(4)) or
          not ((Live.FieldAsString(4)=Before) or (Live.FieldAsString(4)=After)) or
          ((Marked or VerifyOnly) and (Live.FieldAsString(4)<>After)) then
          raise EReadError.Create('Дополнительная копия изменилась перед сохранением итоговой папки.');
        var Changed:=Live.FieldAsString(4)<>After;
        if Changed and (Live.FieldAsString(6)<>'') then
        begin
          // Root publication must not silently move an unpublished/retained
          // relative locator. Published and future locators are already absolute.
          var OldBook:=Default(TBookRecord); OldBook.CollectionRoot:=Settings.ExpandCollectionRoot(Live.FieldAsString(4));
          OldBook.BookKey:=CreateBookKey(Bindings.FieldAsInt(0),CID);
          OldBook.LibID:=Live.FieldAsString(1); OldBook.FileExt:=Live.FieldAsString(2); OldBook.InsideNo:=Live.FieldAsInt(3);
          OldBook.Folder:=Live.FieldAsString(5); OldBook.FileName:=Live.FieldAsString(6);
          var NewBook:=OldBook; NewBook.CollectionRoot:=After;
          var OldContainer:=TPath.Combine(OldBook.CollectionRoot,OldBook.Folder);
          var NewContainer:=TPath.Combine(NewBook.CollectionRoot,NewBook.Folder);
          if (OldBook.GetBookFormat(OldContainer)<>NewBook.GetBookFormat(NewContainer)) or
            not SameFileName(ExpandFileName(OldBook.GetBookFileName(OldContainer)),ExpandFileName(NewBook.GetBookFileName(NewContainer))) then
            raise EReadError.Create('Нельзя менять итоговую папку копии с несохранённым адресом книги.');
          var ReaderBinding:=ReaderAliases.RecordMove(OldBook,NewBook,VerifyOnly and not RecoverReaderAliases);
          if ReaderBinding<>'' then BindFinalRow(Hash,['reader-history',ReaderBinding]);
        end;
        FreeAndNil(Live);
        if Changed then
        begin
          DB.ExecSQL('UPDATE CatalogBookCopies SET Root=? WHERE SourceKey=?',[After,Bindings.FieldAsString(1)]);
          if DB.LastChangedRows<>1 then raise EWriteError.Create('Не сохранена итоговая папка дополнительной копии.');
          Inc(Outcome.CopyRoots);
        end;
        Bindings.Next;
      end;
      FreeAndNil(Bindings);
    end;
    BindingSHA:=Hash.HashAsString;
    if Marked then
    begin
      Live:=DB.NewQuery('SELECT ReviewSHA256,IntentSHA256,DatabaseKey,BindingSHA256 FROM '+ReceiptTable+' WHERE Operation=?',[Operation]);
      Live.Open;
      if Live.Eof or (Live.FieldAsString(0)<>ReviewSHA) or (Live.FieldAsString(1)<>IntentSHA) or
        (Live.FieldAsString(2)<>ActualKey) or (Live.FieldAsString(3)<>BindingSHA) then
        raise EReadError.Create('Квитанция итоговых адресов не совпала с проверенным намерением.');
      FreeAndNil(Live);
    end
    else if not VerifyOnly then
    begin
      DB.ExecSQL('CREATE TABLE IF NOT EXISTS '+ReceiptTable+'(Operation TEXT PRIMARY KEY,ReviewSHA256 TEXT NOT NULL,'+
        'IntentSHA256 TEXT NOT NULL,DatabaseKey TEXT NOT NULL,BindingSHA256 TEXT NOT NULL) WITHOUT ROWID');
      DB.ExecSQL('INSERT INTO '+ReceiptTable+' VALUES(?,?,?,?,?)',[Operation,ReviewSHA,IntentSHA,ActualKey,BindingSHA]);
    end;
    CheckCancelled(Cancelled); Result:=Outcome;
  finally ReaderAliases.Free; Live.Free; Bindings.Free; Layout.Free; end;
end;

end.
