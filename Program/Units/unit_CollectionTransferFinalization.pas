unit unit_CollectionTransferFinalization;

interface

uses System.SysUtils, System.JSON, System.Generics.Collections, SQLiteWrap,
  unit_CollectionTransferJournal, unit_CollectionTransferPublication, unit_CollectionTransferLayout,
  unit_CollectionTransferCompletion;

type
  // Durable roots/settings phase. The operation remains pending until cache,
  // live-reader/job coordination and the complete move controller finish.
  TCollectionTransferFinalization=class
  private
    FJournal:TCollectionTransferJournal;
    FSession:TTransferPublicationSession;
    FLayout:TCollectionTransferLayout;
    FPersonal:TSQLiteDatabase;
    FDatabases:TArray<TTransferPublicationDatabase>;
    FPlan:TJSONObject;
    FCacheGuard:TObject;
    FCompletion:TTransferCompletionWriter;
    FSources:TDictionary<Integer,string>;
    FCancelled:TFunc<Boolean>;
    FOperation,FReviewSHA,FIntentSHA,FState,FSelectedKey:string;
    function Meta(const Name:string):string;
    function Stop:Boolean;
    procedure Point(const Stage:string);
    procedure CheckRegistration;
    procedure BuildPlan;
    procedure ReadPlan;
    procedure ValidatePlan;
    procedure CheckRegistrations;
    function PlanDatabase(const Key:string):TJSONObject;
    function FinalSources(CID:Integer):string;
    procedure CheckSettings(const Participant:TTransferPublicationDatabase; RequireAfter:Boolean);
    procedure CheckGroups;
    procedure CheckInventory;
    procedure CheckMissingPaths;
    procedure ApplyCatalogue(const Participant:TTransferPublicationDatabase);
    procedure CheckRootSemantics(DB:TSQLiteDatabase; PersonalRows,Apply:Boolean);
    procedure RememberIntent;
  public
    constructor Create(Journal:TCollectionTransferJournal; Session:TTransferPublicationSession);
    destructor Destroy; override;
    class function HasIntent(Journal:TCollectionTransferJournal):Boolean; static;
    function ApplyRoots(const Cancelled:TFunc<Boolean> = nil):Boolean;
    function Complete(const ApplicationReady,Cancelled:TFunc<Boolean>):TTransferCompletionResult;
  end;

{$IFDEF MHL_TRANSFER_TEST}
var TransferFinalizationTestPoint:TProc<string>;
{$ENDIF}

implementation

uses System.Classes, System.Hash, System.IOUtils, Winapi.Windows, unit_Consts, unit_Globals,
  unit_Settings, dm_user, unit_BookCompressionReceipt, unit_ZipMemberDeletion, unit_CollectionTransferFinalRows,
  unit_CollectionTransferCachePreparation;

const IntentTable='HomeLibreTransferFinalization'; ReceiptTable='HomeLibreTransferFinalSettings';

function HasTable(DB:TSQLiteDatabase; const Name:string):Boolean;
begin Result:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[Name])=1; end;

function Setting(DB:TSQLiteDatabase; ID:Integer; out Present:Boolean):string;
begin
  Result:=''; Present:=False; if not HasTable(DB,'Settings') then Exit;
  var Q:=DB.NewQuery('SELECT SettingValue FROM Settings WHERE SettingID=?',[ID]);
  try Q.Open; Present:=not Q.Eof; if Present then Result:=Q.FieldAsString(0);
  finally Q.Free; end;
end;

procedure RequireMissing(const Path:string);
begin
  if GetFileAttributes(PChar(DeletionNativePath(Path)))<>INVALID_FILE_ATTRIBUTES then
    raise EReadError.Create('Появился отсутствовавший файл при завершении переноса: '+Path);
  var Code:=GetLastError;
  if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
end;

constructor TCollectionTransferFinalization.Create(Journal:TCollectionTransferJournal; Session:TTransferPublicationSession);
begin
  inherited Create; FJournal:=Journal; FSession:=Session;
  if (Journal=nil) or (Session=nil) then raise EArgumentException.Create('Нет журнала или транзакций завершения переноса.');
  FLayout:=TCollectionTransferLayout.Create(Journal.Review);
  FSources:=TDictionary<Integer,string>.Create; FOperation:=Meta('directory');
  FReviewSHA:=Journal.ReviewSHA256; FSelectedKey:=Meta('catalogue_key');
end;

destructor TCollectionTransferFinalization.Destroy;
begin FCacheGuard.Free; FPlan.Free; FSources.Free; FLayout.Free; inherited; end;

function TCollectionTransferFinalization.Meta(const Name:string):string;
begin Result:=FJournal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=?',[Name]); end;

function TCollectionTransferFinalization.Stop:Boolean;
begin
  Result:=False;
  if Assigned(FCancelled) and FCancelled() then raise EAbort.Create('Завершение переноса остановлено; журнал сохранён.');
  FJournal.CheckSpace;
end;

procedure TCollectionTransferFinalization.Point(const Stage:string);
begin
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferFinalizationTestPoint) then TransferFinalizationTestPoint(Stage);
{$ENDIF}
  Stop;
end;

class function TCollectionTransferFinalization.HasIntent(Journal:TCollectionTransferJournal):Boolean;
begin
  var Path:=Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal''');
  var Key:=Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal_key''');
  var Lease:=AcquireCompressionDatabaseLease(Path,Key);
  var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Path),Journal.Directory);
  try
    Result:=HasTable(DB,IntentTable) and (DB.QuerySingleInt('SELECT count(*) FROM '+IntentTable+' WHERE Operation=?',
      [Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''directory''')])=1);
  finally DB.Free; Lease:=nil; end;
end;

procedure TCollectionTransferFinalization.CheckRegistration;
begin
  var Q:=FPersonal.NewQuery('SELECT Directory,ReviewSHA256,PersonalKey,WorkRoot,Destination,CollectionID,State '+
    'FROM HomeLibreTransferOperations WHERE Operation=?',[FOperation]);
  try
    Q.Open;
    if Q.Eof or (Q.FieldAsString(0)<>FJournal.Directory) or (Q.FieldAsString(1)<>FReviewSHA) or
      (Q.FieldAsString(2)<>Meta('personal_key')) or (Q.FieldAsString(3)<>Meta('work_root')) or
      (Q.FieldAsString(4)<>Meta('destination')) or (Q.FieldAsInt(5)<>StrToInt(Meta('collection'))) or
      (Q.FieldAsString(6)<>'pending') then raise EReadError.Create('Регистрация завершения переноса не совпала с журналом.');
  finally Q.Free; end;
end;

procedure TCollectionTransferFinalization.BuildPlan;
begin
  FPlan:=TJSONObject.Create;
  FPlan.AddPair('kind','HomeLibre final roots v1'); FPlan.AddPair('operation',FOperation);
  FPlan.AddPair('review',FReviewSHA); FPlan.AddPair('root',FLayout.RootDestination('collection'));
  var Databases:=TJSONArray.Create; FPlan.AddPair('databases',Databases);
  for var Participant in FDatabases do
  begin
    Stop;
    var Row:=TJSONObject.Create; Databases.AddElement(Row);
    Row.AddPair('key',Participant.Key); Row.AddPair('path',Participant.Path);
    var Present:Boolean; var Before:=Setting(Participant.Database,PROP_CATALOG_SOURCES,Present);
    var Frozen:=FJournal.Review.QuerySingleString('SELECT SourcesJSON FROM ReferenceRegistrations WHERE RegistrationID=?',
      [Participant.Registrations[0]]);
    if Before<>Frozen then raise EReadError.Create('Список источников изменился до завершения переноса.');
    Row.AddPair('source_before',Before); Row.AddPair('source_present',TJSONBool.Create(Present));
    Row.AddPair('source_after',FLayout.ProjectSources(Before,Participant.Key=FSelectedKey));
    Before:=Setting(Participant.Database,PROP_LIBRARY_UPDATE_SOURCES,Present);
    Row.AddPair('profile_before',Before); Row.AddPair('profile_present',TJSONBool.Create(Present));
    if Participant.Key=FSelectedKey then Row.AddPair('profile_after',FLayout.UpdateSettings(Before))
    else Row.AddPair('profile_after',Before);
  end;
  var Regs:=TJSONArray.Create; FPlan.AddPair('registrations',Regs);
  var Q:=FPersonal.NewQuery('SELECT DatabaseID,DBFileName,RootFolder,Code FROM Bases ORDER BY DatabaseID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      var Row:=TJSONObject.Create; Regs.AddElement(Row);
      Row.AddPair('id',TJSONNumber.Create(Q.FieldAsInt(0))); Row.AddPair('file',Q.FieldAsString(1));
      Row.AddPair('root',Q.FieldAsString(2)); Row.AddPair('code',TJSONNumber.Create(Q.FieldAsInt(3))); Q.Next;
    end;
  finally Q.Free; end;
  var Groups:=TJSONArray.Create; FPlan.AddPair('groups',Groups);
  FJournal.ForEachGroup(procedure(const Group:TTransferJournalGroup)
    begin
      Stop;
      var SHA:=FPersonal.QuerySingleString('SELECT ProofSHA256 FROM HomeLibreTransferGroupProofs WHERE Operation=? AND GroupID=?',[FOperation,Group.ID]);
      if Length(SHA)<>64 then raise EReadError.Create('Не все группы подтверждены перед завершением.');
      var Row:=TJSONObject.Create; Groups.AddElement(Row); Row.AddPair('id',TJSONNumber.Create(Group.ID)); Row.AddPair('sha',SHA);
    end);
  FIntentSHA:=THashSHA2.GetHashString(FPlan.ToJSON); FState:='intent';
end;

procedure TCollectionTransferFinalization.ReadPlan;
begin
  FPlan.Free; FPlan:=nil; FState:='';
  if not HasTable(FPersonal,IntentTable) then Exit;
  var Q:=FPersonal.NewQuery('SELECT ReviewSHA256,IntentJSON,IntentSHA256,State FROM '+IntentTable+' WHERE Operation=?',[FOperation]);
  try
    Q.Open; if Q.Eof then Exit;
    var Raw:=Q.FieldAsString(1);
    if (Q.FieldAsString(0)<>FReviewSHA) or (Length(Raw)>16*1024*1024) or
      (THashSHA2.GetHashString(Raw)<>Q.FieldAsString(2)) then raise EReadError.Create('Независимое намерение завершения изменено.');
    FIntentSHA:=Q.FieldAsString(2); FState:=Q.FieldAsString(3);
    FPlan:=TJSONObject.ParseJSONValue(Raw) as TJSONObject;
    if FPlan=nil then raise EReadError.Create('Не читается независимое намерение завершения.');
  finally Q.Free; end;
end;

function TCollectionTransferFinalization.PlanDatabase(const Key:string):TJSONObject;
begin
  Result:=nil;
  for var Value in FPlan.GetValue<TJSONArray>('databases') do
    if TJSONObject(Value).GetValue<string>('key')=Key then
    begin
      if Result<>nil then raise EReadError.Create('Повтор базы в намерении завершения.');
      Result:=TJSONObject(Value);
    end;
  if Result=nil then raise EReadError.Create('База пропущена в намерении завершения.');
end;

procedure TCollectionTransferFinalization.ValidatePlan;
begin
  if (FPlan.GetValue<string>('kind')<>'HomeLibre final roots v1') or
    (FPlan.GetValue<string>('operation')<>FOperation) or (FPlan.GetValue<string>('review')<>FReviewSHA) or
    (FPlan.GetValue<string>('root')<>FLayout.RootDestination('collection')) or
    not ((FState='intent') or (FState='roots-applied')) or
    (FPlan.GetValue<TJSONArray>('databases').Count<>Length(FDatabases)) then
    raise EReadError.Create('Намерение относится к другому завершению переноса.');
  FSources.Clear;
  for var Participant in FDatabases do
  begin
    var Row:=PlanDatabase(Participant.Key);
    var Before:=Row.GetValue<string>('source_before');
    if (Row.GetValue<string>('path')<>Participant.Path) or
      (Before<>FJournal.Review.QuerySingleString('SELECT SourcesJSON FROM ReferenceRegistrations WHERE RegistrationID=?',
        [Participant.Registrations[0]])) or
      (Row.GetValue<string>('source_after')<>FLayout.ProjectSources(Before,Participant.Key=FSelectedKey)) then
      raise EReadError.Create('Настройки источников не совпали с проверенным завершением.');
    Before:=Row.GetValue<string>('profile_before'); var After:=Before;
    if Participant.Key=FSelectedKey then After:=FLayout.UpdateSettings(Before);
    if Row.GetValue<string>('profile_after')<>After then raise EReadError.Create('Профиль обновления не совпал с проверенным завершением.');
    for var CID in Participant.Registrations do FSources.Add(CID,Row.GetValue<string>('source_after'));
  end;
  var Groups:=FPlan.GetValue<TJSONArray>('groups');
  if Groups.Count<>FJournal.GroupCount then raise EReadError.Create('Неполное намерение завершения групп.');
  var Seen:=TDictionary<Int64,Boolean>.Create;
  try
    for var Value in Groups do
    begin
      var Row:=TJSONObject(Value); var ID:=Row.GetValue<Int64>('id'); var SHA:=Row.GetValue<string>('sha');
      if Seen.ContainsKey(ID) or (Length(SHA)<>64) or
        (FJournal.Review.QuerySingleInt('SELECT count(*) FROM Groups WHERE ID=?',[ID])<>1) or
        (FPersonal.QuerySingleString('SELECT ProofSHA256 FROM HomeLibreTransferGroupProofs WHERE Operation=? AND GroupID=?',[FOperation,ID])<>SHA) then
        raise EReadError.Create('Подтверждения групп изменились после намерения завершения.');
      Seen.Add(ID,True);
    end;
  finally Seen.Free; end;
end;

function TCollectionTransferFinalization.FinalSources(CID:Integer):string;
begin
  if not FSources.TryGetValue(CID,Result) then raise EReadError.Create('Нет итоговых источников подключения.');
  if FCacheGuard<>nil then Result:=TCollectionTransferCachePreparation(FCacheGuard).AuthorizedSources(CID);
end;

procedure TCollectionTransferFinalization.CheckRegistrations;
begin
  var Regs:=FPlan.GetValue<TJSONArray>('registrations');
  if (Regs.Count<>FPersonal.QuerySingleInt('SELECT count(*) FROM Bases')) or
    (Regs.Count<>FJournal.Review.QuerySingleInt('SELECT count(*) FROM ReferenceRegistrations')) then
    raise EReadError.Create('Изменился список подключений при завершении.');
  var Seen:=TDictionary<Integer,Boolean>.Create;
  try
    for var Value in Regs do
    begin
      var Row:=TJSONObject(Value); var CID:=Row.GetValue<Integer>('id');
      if Seen.ContainsKey(CID) then raise EReadError.Create('Повтор подключения в намерении завершения.'); Seen.Add(CID,True);
      var Frozen:=FJournal.Review.NewQuery('SELECT RawRoot,Code,State,RawCatalogue FROM ReferenceRegistrations WHERE RegistrationID=?',[CID]);
      var Live:=FPersonal.NewQuery('SELECT DBFileName,RootFolder,Code FROM Bases WHERE DatabaseID=?',[CID]);
      try
        Frozen.Open; Live.Open;
        if Frozen.Eof or Live.Eof or (Row.GetValue<string>('root')<>Frozen.FieldAsString(0)) or
          (Row.GetValue<Integer>('code')<>Frozen.FieldAsInt(1)) or (Live.FieldAsString(0)<>Row.GetValue<string>('file')) or
          (Live.FieldAsInt(2)<>Row.GetValue<Integer>('code')) then raise EReadError.Create('Подключение изменилось при завершении переноса.');
        var ExpectedRoot:=Row.GetValue<string>('root');
        if (CID=StrToInt(Meta('collection'))) and (FState='roots-applied') then ExpectedRoot:=FLayout.RootDestination('collection');
        var RootMatches:=Live.FieldAsString(1)=ExpectedRoot;
        if not RootMatches then raise EReadError.Create('Корень подключения изменился при завершении переноса.');
        if Frozen.FieldAsString(2)='ready' then
        begin
          if CompressionFileKey(Settings.ExpandCollectionFileName(Live.FieldAsString(0)))<>
            CompressionFileKey(FJournal.EffectiveCatalogue(CID)) then raise EReadError.Create('Изменился файл подключённого каталога.');
        end
        else if Live.FieldAsString(0)<>Frozen.FieldAsString(3) then raise EReadError.Create('Изменился недоступный каталог.');
      finally Live.Free; Frozen.Free; end;
    end;
  finally Seen.Free; end;
end;

procedure TCollectionTransferFinalization.CheckSettings(const Participant:TTransferPublicationDatabase; RequireAfter:Boolean);
begin
  var Row:=PlanDatabase(Participant.Key); var Present:Boolean;
  var Source:=Setting(Participant.Database,PROP_CATALOG_SOURCES,Present);
  if Present<>Row.GetValue<Boolean>('source_present') then raise EReadError.Create('Изменился состав настроек источников.');
  var Expected:=Row.GetValue<string>('source_before'); if RequireAfter then Expected:=Row.GetValue<string>('source_after');
  if RequireAfter and (FCacheGuard<>nil) then Expected:=TCollectionTransferCachePreparation(FCacheGuard).AuthorizedSources(Participant.Registrations[0]);
  if Source<>Expected then raise EReadError.Create('Список источников изменился при завершении.');
  var Profile:=Setting(Participant.Database,PROP_LIBRARY_UPDATE_SOURCES,Present);
  if Present<>Row.GetValue<Boolean>('profile_present') then raise EReadError.Create('Изменился состав профилей обновления.');
  Expected:=Row.GetValue<string>('profile_before'); if RequireAfter then Expected:=Row.GetValue<string>('profile_after');
  if Profile<>Expected then raise EReadError.Create('Профиль обновления изменился при завершении.');
end;

procedure TCollectionTransferFinalization.CheckMissingPaths;
begin
  var Q:=FJournal.Review.NewQuery('SELECT Path FROM NegativePaths');
  try Q.Open; while not Q.Eof do begin Stop; RequireMissing(Q.FieldAsString(0)); Q.Next; end;
  finally Q.Free; end;
end;

procedure TCollectionTransferFinalization.CheckInventory;
begin
  for var Participant in FDatabases do if Participant.Key=FSelectedKey then
  begin
    if Participant.Database.QuerySingleInt('SELECT count(*) FROM Books')<>
      FJournal.Review.QuerySingleInt('SELECT count(*) FROM Bindings WHERE Kind=0') then
      raise EReadError.Create('Список книг изменился перед сменой корня.');
    var Copies:Int64:=0;
    if HasTable(Participant.Database,'CatalogBookCopies') then Copies:=Participant.Database.QuerySingleInt('SELECT count(*) FROM CatalogBookCopies');
    if Copies<>FJournal.Review.QuerySingleInt('SELECT count(*) FROM Bindings WHERE Kind=2') then
      raise EReadError.Create('Список физических копий изменился перед сменой корня.');
    var Q:=FJournal.Review.NewQuery('SELECT Kind,BookID,SourceKey,LibID,Folder,FileName,Ext,InsideNo,Root '+
      'FROM Bindings WHERE Kind IN (0,2) AND FileID IS NULL AND Source='''' ORDER BY ID');
    try
      Q.Open;
      while not Q.Eof do
      begin
        Stop;
        var SQL:='SELECT LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=?';
        if Q.FieldAsInt(0)=2 then SQL:='SELECT LibID,Folder,FileName,Ext,InsideNo FROM CatalogBookCopies WHERE SourceKey=?';
        var Live:=Participant.Database.NewQuery(SQL);
        try
          if Q.FieldAsInt(0)=2 then Live.SetParam(0,Q.FieldAsString(2)) else Live.SetParam(0,Q.FieldAsInt(1));
          Live.Open;
          if Live.Eof then raise EReadError.Create('Исчезла запись книги без файла перед сменой корня.');
          for var I:=0 to 4 do if Live.FieldAsString(I)<>Q.FieldAsString(I+3) then
            raise EReadError.Create('Изменился адрес записи без файла перед сменой корня.');
        finally Live.Free; end;
        Q.Next;
      end;
    finally Q.Free; end;
  end;
  if not HasTable(FPersonal,'HomeLibreTransferRemovalIntent') or
    (FPersonal.QuerySingleInt('SELECT count(*) FROM HomeLibreTransferRemovalIntent WHERE Operation=? AND '+
      '(ProtectionBound=1 OR State IN (''retained'',''missing'')) '+
      'AND State IN (''removed'',''missing'',''retained'',''pending'')',[FOperation])<>FJournal.FileCount) then
    raise EReadError.Create('Не все исходники обработаны перед завершением переноса.');
end;

procedure TCollectionTransferFinalization.CheckGroups;
begin
  FSession.RefreshFinalizationReferences(FinalSources,FLayout.RootDestination('collection'));
  for var Value in FPlan.GetValue<TJSONArray>('groups') do
  begin
    Stop; var Row:=TJSONObject(Value); var ID:=Row.GetValue<Int64>('id');
    var Prepared:=FJournal.RecoverPreparedGroup(ID,Row.GetValue<string>('sha'),Stop);
    try
      FSession.CheckFinalizationGroup(Prepared);
      if FCompletion<>nil then FCompletion.CheckGroup(FPersonal,Prepared,Row.GetValue<string>('sha'));
    finally Prepared.Free; end;
  end;
end;

procedure TCollectionTransferFinalization.RememberIntent;
begin
  var Raw:=FPlan.ToJSON;
  if Length(Raw)>16*1024*1024 then raise EWriteError.Create('Слишком большое намерение завершения переноса.');
  FPersonal.ExecSQL('CREATE TABLE IF NOT EXISTS '+IntentTable+'(Operation TEXT PRIMARY KEY,ReviewSHA256 TEXT NOT NULL,'+
    'IntentJSON TEXT NOT NULL,IntentSHA256 TEXT NOT NULL,State TEXT NOT NULL CHECK(State IN (''intent'',''roots-applied''))) WITHOUT ROWID');
  FPersonal.ExecSQL('INSERT INTO '+IntentTable+' VALUES(?,?,?, ?,''intent'')',[FOperation,FReviewSHA,Raw,FIntentSHA]);
  Point('finalization-before-intent-commit'); FPersonal.Commit; Point('finalization-intent-committed');
  FSession.ReopenFinalizationPersonal; ReadPlan;
end;

procedure TCollectionTransferFinalization.ApplyCatalogue(const Participant:TTransferPublicationDatabase);
begin
  Stop; var DB:=Participant.Database; var Marked:=False;
  if HasTable(DB,ReceiptTable) then
  begin
    var Q:=DB.NewQuery('SELECT ReviewSHA256,IntentSHA256,DatabaseKey FROM '+ReceiptTable+' WHERE Operation=?',[FOperation]);
    try
      Q.Open; Marked:=not Q.Eof;
      if Marked and ((Q.FieldAsString(0)<>FReviewSHA) or (Q.FieldAsString(1)<>FIntentSHA) or
        (Q.FieldAsString(2)<>Participant.Key)) then raise EReadError.Create('Квитанция итоговых настроек изменена.');
    finally Q.Free; end;
  end;
  CheckSettings(Participant,Marked);
  if Participant.Key=FSelectedKey then ApplyTransferFinalRows(DB,FPersonal,FJournal.Review,FOperation,FReviewSHA,FIntentSHA,
    False,Marked,Stop,FState='intent');
  if Marked then Exit;
  var Row:=PlanDatabase(Participant.Key);
  for var Kind in ['source','profile'] do
  begin
    var Before:=Row.GetValue<string>(Kind+'_before'); var After:=Row.GetValue<string>(Kind+'_after');
    if Before=After then Continue;
    var ID:=PROP_CATALOG_SOURCES; if Kind='profile' then ID:=PROP_LIBRARY_UPDATE_SOURCES;
    DB.ExecSQL('UPDATE Settings SET SettingValue=? WHERE SettingID=?',[After,ID]);
    if DB.LastChangedRows<>1 then raise EWriteError.Create('Не сохранены итоговые настройки.');
  end;
  DB.ExecSQL('CREATE TABLE IF NOT EXISTS '+ReceiptTable+'(Operation TEXT PRIMARY KEY,ReviewSHA256 TEXT NOT NULL,'+
    'IntentSHA256 TEXT NOT NULL,DatabaseKey TEXT NOT NULL) WITHOUT ROWID');
  DB.ExecSQL('INSERT INTO '+ReceiptTable+' VALUES(?,?,?,?)',[FOperation,FReviewSHA,FIntentSHA,Participant.Key]);
  var Version:=DB.QuerySingleInt('PRAGMA data_version'); Point('finalization-before-catalogue-commit');
  DB.Commit; Point('finalization-after-catalogue-commit'); DB.ExecSQL('BEGIN IMMEDIATE');
  if DB.QuerySingleInt('PRAGMA data_version')<>Version then
    raise EReadError.Create('Каталог изменился между этапами завершения. Повторите продолжение переноса.');
  CheckSettings(Participant,True);
end;

procedure TCollectionTransferFinalization.CheckRootSemantics(DB:TSQLiteDatabase; PersonalRows,Apply:Boolean);
begin
  var SQL:='SELECT BookID,LibID,Folder,FileName,Ext,InsideNo FROM Books';
  if PersonalRows then SQL:=SQL+' WHERE DatabaseID='+Meta('collection');
  var Q:=DB.NewQuery(SQL);
  try
    Q.Open;
    while not Q.Eof do
    begin
      Stop;
      if Q.FieldAsString(3)<>'' then
      begin
        var Before:=Default(TBookRecord); Before.CollectionRoot:=Meta('collection_root');
        Before.LibID:=Q.FieldAsString(1); Before.Folder:=Q.FieldAsString(2); Before.FileName:=Q.FieldAsString(3);
        Before.FileExt:=Q.FieldAsString(4); Before.InsideNo:=Q.FieldAsInt(5);
        var After:=Before; After.CollectionRoot:=FLayout.RootDestination('collection');
        var OldContainer:=TPath.Combine(Before.CollectionRoot,Before.Folder);
        var NewContainer:=TPath.Combine(After.CollectionRoot,After.Folder);
        var Format:=Before.GetBookFormat(OldContainer); var Logical:=ExpandFileName(Before.GetBookFileName(OldContainer));
        if (After.GetBookFormat(NewContainer)<>Format) or not SameFileName(Logical,ExpandFileName(After.GetBookFileName(NewContainer))) then
        begin
          if not PersonalRows or not Apply then raise EReadError.Create('Остался относительный адрес книги перед сменой корня.');
          After.Folder:=OldContainer;
          var Future:TTransferFutureLocator;
          if FLayout.TryMainFuture(Q.FieldAsInt(0),Future) then
          begin
            var Main:=FJournal.Review.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Bindings WHERE Kind=0 AND BookID=?',[Q.FieldAsInt(0)]);
            try
              Main.Open; var Matches:=not Main.Eof;
              if Matches then for var I:=0 to 4 do if Main.FieldAsString(I)<>Q.FieldAsString(I+1) then Matches:=False;
              if Matches then
              begin
                RequireMissing(Logical); RequireMissing(Future.Source);
                After.Folder:=Future.Folder; After.FileName:=Future.FileName; Logical:=Future.Source;
              end;
            finally Main.Free; end;
          end;
          NewContainer:=TPath.Combine(After.CollectionRoot,After.Folder);
          if After.GetBookFormat(NewContainer)<>Format then
          begin
            After.Folder:=''; After.FileName:=Logical;
            if Format<>bfFbd then SetLength(After.FileName,Length(After.FileName)-Length(After.FileExt));
            NewContainer:=TPath.Combine(After.CollectionRoot,After.Folder);
          end;
          if (After.GetBookFormat(NewContainer)<>Format) or not SameFileName(Logical,ExpandFileName(After.GetBookFileName(NewContainer))) then
            raise EReadError.Create('Не удалось сохранить личный адрес при смене корня.');
          DB.ExecSQL('UPDATE Books SET Folder=?,FileName=? WHERE BookID=? AND DatabaseID=?',
            [After.Folder,After.FileName,Q.FieldAsInt(0),StrToInt(Meta('collection'))]);
          if DB.LastChangedRows<>1 then raise EWriteError.Create('Не сохранён личный адрес при смене корня.');
        end;
      end;
      Q.Next;
    end;
  finally Q.Free; end;
end;

function TCollectionTransferFinalization.ApplyRoots(const Cancelled:TFunc<Boolean>):Boolean;
begin
  FCancelled:=Cancelled; Stop; FSession.BeginFinalization(Stop);
  try
    FPersonal:=FSession.FinalizationPersonal; FDatabases:=FSession.FinalizationDatabases;
    CheckRegistration; ReadPlan;
    if (FCompletion<>nil) and ((FPlan=nil) or (FState<>'roots-applied')) then
      raise EReadError.Create('Сначала требуется сохранить итоговые корни переноса.');
    if FPlan=nil then
    begin
      BuildPlan; ValidatePlan; CheckRegistrations; CheckInventory; CheckMissingPaths;
      for var Participant in FDatabases do CheckSettings(Participant,False);
      RememberIntent;
    end;
    ValidatePlan;
    FCacheGuard:=TCollectionTransferCachePreparation.OpenPublishedGuard(FJournal,FSession,FIntentSHA,Stop);
    if (FCompletion<>nil) and ((FCacheGuard=nil) or
      not TCollectionTransferCachePreparation(FCacheGuard).MetadataPublished) then
      raise EReadError.Create('Сначала требуется завершить публикацию источников переноса.');
    CheckRegistration; CheckRegistrations; CheckInventory; CheckMissingPaths; CheckGroups;
    for var Participant in FDatabases do ApplyCatalogue(Participant);
    if FState='roots-applied' then
    begin
      ApplyTransferFinalRows(FPersonal,FPersonal,FJournal.Review,FOperation,FReviewSHA,FIntentSHA,True,True,Stop);
      if FCompletion<>nil then
      begin
        FCompletion.Save(FPersonal,FIntentSHA); Point('completion-before-personal-commit'); FCompletion.BeforeCommit;
      end;
      FPersonal.Commit;
      if FCompletion<>nil then Point('completion-after-personal-commit');
      Result:=True; Exit;
    end;
    for var Participant in FDatabases do if Participant.Key=FSelectedKey then CheckRootSemantics(Participant.Database,False,False);
    ApplyTransferFinalRows(FPersonal,FPersonal,FJournal.Review,FOperation,FReviewSHA,FIntentSHA,True,False,Stop);
    CheckRootSemantics(FPersonal,True,True);
    FJournal.EnsureFinalRootDirectory;
    FPersonal.ExecSQL('UPDATE Bases SET RootFolder=? WHERE DatabaseID=?',[FLayout.RootDestination('collection'),StrToInt(Meta('collection'))]);
    if FPersonal.LastChangedRows<>1 then raise EWriteError.Create('Не сохранён итоговый корень коллекции.');
    FPersonal.ExecSQL('UPDATE '+IntentTable+' SET State=''roots-applied'' WHERE Operation=? AND IntentSHA256=?',[FOperation,FIntentSHA]);
    if FPersonal.LastChangedRows<>1 then raise EWriteError.Create('Не сохранён этап завершения корней.');
    Point('finalization-before-personal-commit'); FPersonal.Commit; Point('finalization-after-personal-commit'); Result:=True;
  finally FreeAndNil(FCacheGuard); FSession.EndFinalization; FCancelled:=nil; end;
end;

function TCollectionTransferFinalization.Complete(const ApplicationReady,Cancelled:TFunc<Boolean>):TTransferCompletionResult;
begin
  FCompletion:=TTransferCompletionWriter.Create(FJournal,ApplicationReady,Cancelled);
  try
    ApplyRoots(Cancelled); Result:=FCompletion.Outcome;
  finally FreeAndNil(FCompletion); end;
end;

end.
