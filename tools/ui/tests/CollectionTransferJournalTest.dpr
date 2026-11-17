program CollectionTransferJournalTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash,
  System.Generics.Collections, Winapi.Windows, NativeRegressionGuard, dm_user,
  SQLiteWrap, SQLite3, unit_Globals, unit_Consts, unit_ZipMemberDeletion,
  unit_CollectionTransferCatalogue, unit_CollectionTransferPlan,
  unit_CollectionTransferCopy, unit_CollectionTransferJournal, unit_CollectionTransferReferences, unit_CollectionTransferRegistry,
  unit_CollectionTransferOperation, unit_CollectionTransferCache, unit_CatalogSources, unit_CollectionTransferCacheSettings,
  unit_CollectionTransferCacheSnapshot,
  unit_CollectionTransferCachePreparation,
  unit_CollectionTransferCacheInstallation,
  unit_CollectionTransferSpace,
  unit_CollectionTransferCleanup, unit_CollectionTransferDrafts, unit_CollectionTransferForks, unit_BookCompressionPlanStore,
  unit_CollectionTransferReferenceFence,
  unit_CollectionTransferBindingDigest,
  unit_ReaderHistoryAliases, unit_ReaderCache,
  unit_CollectionMerge, unit_Interfaces, unit_LibraryUpdateReview, unit_SystemDatabase_SQLite,
  unit_CollectionTransferLayout, unit_CollectionTransferFinalRows, unit_CollectionTransferFinalization,
  unit_CollectionTransferHistory, unit_CollectionTransferLocations, unit_BookCompressionImages, unit_BookCompressionReceipt, unit_BookCompressionPlan;

function CleanupJSON(const Item:TTransferCleanupResult):TJSONObject;
begin
  Result:=TJSONObject.Create;
  Result.AddPair('files_removed',TJSONNumber.Create(Item.FilesRemoved));
  Result.AddPair('bytes_removed',TJSONNumber.Create(Item.BytesRemoved));
  Result.AddPair('directories_removed',TJSONNumber.Create(Item.DirectoriesRemoved));
  Result.AddPair('directories_missing',TJSONNumber.Create(Item.DirectoriesMissing));
  Result.AddPair('directories_retained',TJSONNumber.Create(Item.DirectoriesRetained));
  Result.AddPair('stopped',TJSONBool.Create(Item.Stopped)); Result.AddPair('warning',Item.Warning);
end;

procedure DisableFixtureTriggers(Context:TSQLite3Context; Count:Integer; Values:TSQLite3Value); cdecl;
begin SQLite3_Result_Int(Context,0); end;

procedure ProbeTransferTemporaryRouting(Journal:TCollectionTransferJournal; const Evidence:string);
begin
  var DB:=Journal.Review;
  if not SameFileName(IncludeTrailingPathDelimiter(DB.TemporaryDirectory),IncludeTrailingPathDelimiter(DeletionNativePath(Journal.Directory))) then
    raise EReadError.Create('Transfer review has no owned temporary directory');
  DB.ExecSQL('PRAGMA temp_store=FILE'); DB.ExecSQL('PRAGMA temp.cache_size=8');
  var Before:=DB.TemporaryFilesCreated;
  var Q:=DB.NewQuery('WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<9000) '+
    'SELECT x,randomblob(2048) AS Payload FROM n ORDER BY Payload');
  try
    Q.Open;
    var Bytes:Int64:=0;
    for var Path in TDirectory.GetFiles(DeletionNativePath(Journal.Directory),'sqlite-temp-*') do
    begin
      var Data:TWin32FileAttributeData;
      if not GetFileAttributesEx(PChar(Path),GetFileExInfoStandard,@Data) then RaiseLastOSError;
      Inc(Bytes,(Int64(Data.nFileSizeHigh) shl 32) or Data.nFileSizeLow);
    end;
    var Sum:Int64:=0;
    while not Q.Eof do begin Inc(Sum,Q.FieldAsInt(0)); Q.Next; end;
    if (Sum<>40504500) or (DB.TemporaryFilesCreated<=Before) or (Bytes<1024*1024) then
      raise EReadError.Create('Transfer review did not produce the expected physical temporary sort');
    var Row:=TJSONObject.Create;
    try
      Row.AddPair('directory',Journal.Directory); Row.AddPair('bytes',TJSONNumber.Create(Bytes));
      Row.AddPair('created',TJSONNumber.Create(DB.TemporaryFilesCreated-Before)); Row.AddPair('sum',TJSONNumber.Create(Sum));
      TFile.AppendAllText(Evidence,Row.ToJSON+sLineBreak,TEncoding.UTF8);
    finally Row.Free; end;
  finally Q.Free; end;
end;

function Owned(const Path:string):string;
begin
  Result:=ExpandFileName(Path);
  if not Result.StartsWith(IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))),True) then
    raise EReadError.Create('Journal fixture path is outside its owned runtime');
end;

function ReadJSON(const Path:string):TJSONObject;
begin
  Result:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Owned(Path),TEncoding.UTF8)) as TJSONObject;
  if Result=nil then raise EReadError.Create('Invalid fixture JSON');
end;

function HashFile(const Path:string):string;
begin
  var Stream:=TFileStream.Create(DeletionNativePath(Owned(Path)),fmOpenRead or fmShareDenyWrite);
  try Result:=THashSHA2.GetHashString(Stream); finally Stream.Free; end;
end;

function FixtureReaderNames(const Request:TJSONObject):TJSONArray;
begin
  Result:=TJSONArray.Create;
  var Personal:TSQLiteDatabase:=nil;
  var CID:=Request.GetValue<Integer>('reader_collection_id',7);
  var DB:TSQLiteDatabase:=nil; var Lookup:TReaderHistoryAliasLookup:=nil;
  try
    try
    Personal:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Owned(Request.GetValue<string>('personal'))));
    var Root:=Personal.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[CID]);
    var Catalogue:=Personal.QuerySingleString('SELECT DBFileName FROM Bases WHERE DatabaseID=?',[CID]);
    Root:=Owned(Settings.ExpandCollectionRoot(Root));
    DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Owned(Catalogue)));
    Lookup:=TReaderHistoryAliasLookup.Create(Personal);
    var Q:=DB.NewQuery('SELECT BookID,LibID,Folder,FileName,Ext,InsideNo FROM Books ORDER BY BookID');
    try Q.Open;
      while not Q.Eof do
      begin
        if Result.Count>=1000 then raise EReadError.Create('Reader fixture is not bounded');
        var Book:=Default(TBookRecord); Book.BookKey:=CreateBookKey(Q.FieldAsInt(0),CID);
        Book.CollectionRoot:=Root; Book.LibID:=Q.FieldAsString(1); Book.Folder:=Q.FieldAsString(2);
        Book.FileName:=Q.FieldAsString(3); Book.FileExt:=Q.FieldAsString(4); Book.InsideNo:=Q.FieldAsInt(5);
        var Current:=ReaderBaseHistoryName(Book,Request.GetValue<string>('reader_namespace',''));
        var Original:string; var Used:=Lookup.Find(Book,Current,Original); if not Used then Original:=Current;
        var Row:=TJSONObject.Create; Row.AddPair('book',TJSONNumber.Create(Book.BookKey.BookID));
        Row.AddPair('base',Current); Row.AddPair('history',Original); Row.AddPair('aliased',TJSONBool.Create(Used));
        Result.AddElement(Row); Q.Next;
      end;
    finally Q.Free; end;
    except Result.Free; raise; end;
  finally Lookup.Free; DB.Free; Personal.Free; end;
end;

procedure ProbeStreamLeases(const Path:string);
begin
  for var Suffix in ['',':HomeLibreNote'] do
    for var Access in [DWORD(GENERIC_WRITE),DWORD(Winapi.Windows._DELETE)] do
    begin
      var Handle:=CreateFile(PChar(DeletionNativePath(Owned(Path)+Suffix)),Access,
        FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
      if Handle<>INVALID_HANDLE_VALUE then
      begin CloseHandle(Handle); raise EReadError.Create('Prepared stream permits access '+IntToHex(Access,8)+': '+Path+Suffix); end;
      var Code:=GetLastError;
      if Code<>ERROR_SHARING_VIOLATION then RaiseLastOSError(Code);
    end;
end;

function NativeBookHash(const Catalogue,Root:string):string;
begin
  var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Owned(Catalogue)));
  try
    var Q:=DB.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=1');
    try
      Q.Open; if Q.Eof then raise EReadError.Create('No fixture book');
      var Book:=Default(TBookRecord); Book.CollectionRoot:=IncludeTrailingPathDelimiter(Owned(Root));
      Book.LibID:=Q.FieldAsString(0); Book.Folder:=Q.FieldAsString(1); Book.FileName:=Q.FieldAsString(2);
      Book.FileExt:=Q.FieldAsString(3); Book.InsideNo:=Q.FieldAsInt(4);
      var Stream:=Book.GetBookStream;
      try if Stream=nil then raise EReadError.Create('No native fixture stream'); Result:=THashSHA2.GetHashString(Stream);
      finally Stream.Free; end;
    finally Q.Free; end;
  finally DB.Free; end;
end;

function NativeCacheHit(const Catalogue,Personal,Root,Source:string):Boolean;
var Selected:TArray<TCompressionLocator>; Options:TCompressionPlanOptions;
begin
  var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Owned(Catalogue)));
  try
    var Q:=DB.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo,BookSize FROM Books WHERE BookID=1');
    try
      Q.Open; SetLength(Selected,1); Selected[0].Kind:=0; Selected[0].BookID:=1;
      Selected[0].LibID:=Q.FieldAsString(0); Selected[0].Folder:=Q.FieldAsString(1); Selected[0].FileName:=Q.FieldAsString(2);
      Selected[0].Extension:=Q.FieldAsString(3); Selected[0].InsideNo:=Q.FieldAsInt(4); Selected[0].OldSize:=Q.FieldAsInt(5);
    finally Q.Free; end;
  finally DB.Free; end;
  Options.CollectionID:=7; Options.Catalogue:=Owned(Catalogue); Options.Personal:=Owned(Personal);
  Options.CollectionRoot:=IncludeTrailingPathDelimiter(Owned(Root)); Options.BaseRoot:=Owned(Root); Options.BaseCatalogue:=Owned(Catalogue);
  var Plan:=TBookCompressionPlan.Create(Options,Selected,
    function(const Row:TCompressionLocator):string begin Result:=Owned(Source); end,
    function(const Path:string; const Row:TCompressionLocator):string begin Result:=Row.FileName+Row.Extension; end);
  try Result:=(Plan.Files.Count=1) and Plan.Files[0].AlreadyChecked('balanced',False,StringOfChar('a',64));
  finally Plan.Free; end;
end;

procedure ProbeVerificationLocks(Journal:TCollectionTransferJournal; Expected:Boolean; PersonalUnlocked:Boolean=False);
var Paths:TList<string>; Q:TSQLiteQuery;
begin
  Paths:=TList<string>.Create; Q:=nil;
  try
    Paths.Add(Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal'''));
    Q:=Journal.Review.NewQuery('SELECT RegistrationID FROM ReferenceRegistrations WHERE State=''ready'''); Q.Open;
    while not Q.Eof do
    begin
      var Path:=Journal.EffectiveCatalogue(Q.FieldAsInt(0));
      if not Paths.Contains(Path) then Paths.Add(Path); Q.Next;
    end;
    for var Path in Paths do
    begin
      var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Path)),False);
      try
        DB.SetTimeout(0); var Locked:=False;
        try DB.ExecSQL('BEGIN IMMEDIATE');
        except on E:ESQLiteException do
          if E.Message.ToLower.Contains('locked') or E.Message.ToLower.Contains('busy') then Locked:=True else raise;
        end;
        if DB.InTransaction then DB.Rollback;
        var Required:=Expected;
        if PersonalUnlocked and SameFileName(Path,Paths[0]) then Required:=False;
        if Locked<>Required then raise EReadError.Create('Unexpected verification writer-lock state');
      finally DB.Free; end;
    end;
  finally Q.Free; Paths.Free; end;
end;

var Request,Control,Output:TJSONObject; Capture:TCollectionTransferCatalogue; Plan:TCollectionTransferPlan;
    Journal:TCollectionTransferJournal; Registry:TCollectionTransferRegistry; Info:TCollectionInfo; ControlFile,Mode,Crash:string;
    Copies,PreparedFiles,IndexedApprovals,CopiedApprovals,ReadOnlyApprovals,SQLApprovalPolls:Integer; Stop,BetweenEdited,CompletionBusy:Boolean; Groups,HistoryHits:TJSONArray; IDs:TList<Int64>; HistoryRows,VerifiedRetained:Int64;
    Removed,Missing,RetainedSources,PendingSources,CachesPrepared,HeldPreparedCaches,PublishedCacheDatabases:Int64; RootsApplied:Boolean;
    IncompletePreparationHandle:THandle; DraftSnapshots:Integer;
begin
  SetTextCodePage(System.Output,CP_UTF8);
  try
    RequireIsolatedRegression; DMUser:=TDMUser.Create(nil);
    try
      if ParamCount<>2 then raise EArgumentException.Create('Expected request and result');
      Request:=ReadJSON(ParamStr(1)); Control:=nil; Output:=nil; Capture:=nil; Plan:=nil; Journal:=nil; Registry:=nil; IDs:=nil;
      try
        Mode:=Request.GetValue<string>('mode','create'); ControlFile:=Owned(Request.GetValue<string>('control'));
        Crash:=Request.GetValue<string>('crash',''); Copies:=0; PreparedFiles:=0; Stop:=False; BetweenEdited:=False; HistoryRows:=0; VerifiedRetained:=0; HistoryHits:=TJSONArray.Create;
        Removed:=0; Missing:=0; RetainedSources:=0; PendingSources:=0; CachesPrepared:=0; HeldPreparedCaches:=0; PublishedCacheDatabases:=0; RootsApplied:=False;
        CompletionBusy:=Request.GetValue<Boolean>('application_busy',False); IncompletePreparationHandle:=0;
        IndexedApprovals:=0; CopiedApprovals:=0;
        ReadOnlyApprovals:=0; SQLApprovalPolls:=0;
        DraftSnapshots:=0;
        TransferDraftTestPoint:=procedure(Stage,Directory:string)
          begin
            Writeln('TRACE draft ',Stage,' ',Directory);
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
          end;
        TransferForkDraftTestPoint:=procedure(Stage,Path:string; Done,Total:Integer)
          begin
            Owned(Path);
            if Stage='fork-draft-reserved' then Inc(DraftSnapshots);
            if Stage=Request.GetValue<string>('cancel_draft_snapshot_stage','') then Stop:=True;
            if (Stage<>Crash) or (DraftSnapshots<Request.GetValue<Integer>('crash_snapshot',1)) then Exit;
            if Request.GetValue<Boolean>('only_partial_snapshot',False) and ((Done<=0) or (Done>=Total)) then Exit;
            var Bytes:=TFile.GetSize(DeletionNativePath(Path));
            if Bytes<Request.GetValue<Int64>('draft_min_bytes',0) then Exit;
            var Evidence:=TJSONObject.Create;
            try
              Evidence.AddPair('stage',Stage); Evidence.AddPair('path',Path); Evidence.AddPair('bytes',TJSONNumber.Create(Bytes));
              Evidence.AddPair('done',TJSONNumber.Create(Done)); Evidence.AddPair('total',TJSONNumber.Create(Total));
              TFile.AppendAllText(Owned(TPath.Combine(ExtractFileDir(ControlFile),'fork-draft-events.jsonl')),
                Evidence.ToJSON+sLineBreak,TEncoding.UTF8);
            finally Evidence.Free; end;
            Writeln('CRASH ',Stage); Flush(System.Output); Halt(97);
          end;
        TransferApprovalTestPoint:=procedure(Indexed:Boolean)
          begin if Indexed then Inc(IndexedApprovals) else Inc(CopiedApprovals); end;
        TransferApprovalReadOnlyProbe:=procedure(DB:TSQLiteDatabase)
          begin
            var Refused:=False;
            try DB.ExecSQL('CREATE TABLE fixed_approval.HomeLibreWriteProbe(ID)');
            except on E:ESQLiteException do
              if E.Message.ToLower.Contains('readonly') then Refused:=True else raise;
            end;
            if not Refused then raise EReadError.Create('Frozen review attachment allowed writes');
            Inc(ReadOnlyApprovals);
          end;
        TransferApprovalSQLTestPoint:=procedure
          begin
            Inc(SQLApprovalPolls);
            if Request.GetValue<Boolean>('cancel_approval_sql',False) then
            begin Writeln('TRACE cancelling approval SQL'); Flush(System.Output); Stop:=True; end;
          end;
        if Mode='clean-drafts' then
        begin
          var RemovedDrafts:=TTransferDrafts.CleanAbandoned(Owned(Request.GetValue<string>('work')),
            function:Boolean begin Result:=Request.GetValue<Boolean>('cancel_draft_cleanup',False); end);
          Output:=TJSONObject.Create; Output.AddPair('status','PASS'); Output.AddPair('drafts_removed',TJSONNumber.Create(RemovedDrafts));
          Output.AddPair('plans_removed',TJSONNumber.Create(TCompressionPlanStore.CleanAbandoned(Owned(Request.GetValue<string>('work')))));
          TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8); Exit;
        end;
        if Mode='reader-names' then
        begin
          Output:=TJSONObject.Create; Output.AddPair('reader_names',FixtureReaderNames(Request));
          TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8); Exit;
        end;
        if Mode='binding-digest' then
        begin
          var Values:=Request.GetValue<TJSONArray>('binding_rows'); var Digest:=TTransferBindingDigest.Create;
          try
            for var Row in Values do Digest.AddRow(Row as TJSONArray);
            var LegacyJSON:=Values.ToJSON; var SHA:=Digest.Digest;
            if Digest.Digest<>SHA then raise EReadError.Create('Binding digest is not idempotent');
            var Refused:=False;
            try Digest.AddRow(Values); except on E:EInvalidOperation do Refused:=True; end;
            if not Refused then raise EReadError.Create('Finished binding digest accepted another row');
            Output:=TJSONObject.Create; Output.AddPair('status','PASS'); Output.AddPair('sha256',SHA);
            Output.AddPair('legacy_sha256',THashSHA2.GetHashString(LegacyJSON));
            Output.AddPair('bytes',TJSONNumber.Create(Length(TEncoding.UTF8.GetBytes(LegacyJSON))));
            if Length(LegacyJSON)<20000 then Output.AddPair('legacy_json',LegacyJSON);
            TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8); Exit;
          finally Digest.Free; end;
        end;
        TransferCleanupTestPoint:=procedure(Stage,Path:string)
          begin
            if Path.StartsWith('\\?\') then Owned(Copy(Path,5,MaxInt)) else Owned(Path);
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if Stage=Request.GetValue<string>('cancel_cleanup_stage','') then Stop:=True;
          end;
        if (Mode='cleanup-only') or (Mode='cleanup-queue') then
        begin
          Stop:=Request.GetValue<Boolean>('cleanup_cancel_immediately',False);
          var PersonalFile:=Owned(Request.GetValue<string>('personal'));
          var QueuedBefore:=Length(CompletedTransferCleanupQueue(PersonalFile));
          var Clean:TTransferCleanupResult;
          if Mode='cleanup-queue' then
          begin
            if Request.GetValue<Boolean>('cleanup_worker',False) then
            begin
              var Worker:=TTransferCleanupWorker.Create(PersonalFile);
              try
                Worker.Start; var Deadline:=GetTickCount64+60000;
                while not Worker.Done and (GetTickCount64<Deadline) do Sleep(10);
                if not Worker.Done then raise EReadError.Create('Background cleanup worker did not finish');
                Clean:=Worker.Outcome;
              finally Worker.Free; end;
            end
            else Clean:=CleanupRegisteredCompletedTransfers(PersonalFile,function:Boolean begin Result:=Stop; end);
          end
          else
          begin
            Control:=ReadJSON(ControlFile);
            Journal:=TCollectionTransferJournal.OpenCompletedForCleanup(Owned(Request.GetValue<string>('work')),
              Owned(Request.GetValue<string>('destination')),Owned(Control.GetValue<string>('directory')),
              Request.GetValue<string>('override_review_sha256',Control.GetValue<string>('review_sha256')),
              function:Boolean begin Result:=Stop; end);
            var Refused:=False;
            try Registry:=TCollectionTransferRegistry.Create(Journal); except on E:EReadError do Refused:=True; end;
            if not Refused then raise EReadError.Create('Cleanup journal accepted a publication registry');
            Clean:=Journal.CleanupCompletedCacheSnapshots(function:Boolean begin Result:=Stop; end);
          end;
          Output:=CleanupJSON(Clean);
          Output.AddPair('queued_before',TJSONNumber.Create(QueuedBefore));
          Output.AddPair('queued_after',TJSONNumber.Create(Length(CompletedTransferCleanupQueue(PersonalFile))));
          TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8); Exit;
        end;
        TransferFinalizationTestPoint:=procedure(Stage:string)
          begin
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if Request.GetValue<string>('cancel_finalization_stage','')=Stage then Stop:=True;
            if (Stage='completion-before-personal-commit') and Request.GetValue<Boolean>('busy_before_completion_commit',False) then
              CompletionBusy:=True;
            if (Stage='finalization-after-catalogue-commit') and Request.GetValue<Boolean>('edit_finalization_gap',False) then
            begin
              var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('catalogue'))));
              try DB.AddFunction('MHL_TRIGGERS_ON',0,DisableFixtureTriggers);
                DB.ExecSQL('UPDATE Books SET Title=''late finalization title'' WHERE BookID=1');
              finally DB.Free; end;
            end;
          end;
        TransferCacheSnapshotTestPoint:=procedure(Stage:string)
          begin
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if Stage=Request.GetValue<string>('cancel_cache_snapshot_stage','') then Stop:=True;
          end;
        TransferCachePreparationTestPoint:=procedure(Stage:string)
          begin
            if (Stage='cache-metadata-after-catalogue-commit') and Request.GetValue<Boolean>('edit_cache_metadata_gap',False) then
            begin
              var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('catalogue'))),False);
              try DB.AddFunction('MHL_TRIGGERS_ON',0,DisableFixtureTriggers);
                DB.ExecSQL('UPDATE Books SET Title=''late cache metadata title'' WHERE BookID=1');
              finally DB.Free; end;
            end;
            if (Stage='cache-preparation-job-ready') and Request.GetValue<Boolean>('probe_prepared_cache_guards',False) then
            begin
              var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Owned(Request.GetValue<string>('personal'))));
              try
                var Q:=DB.NewQuery('SELECT Directory FROM HomeLibreTransferCacheStages WHERE ReadySHA<>''''');
                try Q.Open; while not Q.Eof do
                  begin
                    var Path:=TPath.Combine(Owned(Q.FieldAsString(0)),'catalog.hlc2');
                    var Handle:=CreateFile(PChar(DeletionNativePath(Path)),GENERIC_WRITE,
                      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
                    if Handle<>INVALID_HANDLE_VALUE then
                    begin CloseHandle(Handle); raise EReadError.Create('Prepared cache is not held against writes'); end;
                    if GetLastError<>ERROR_SHARING_VIOLATION then RaiseLastOSError;
                    Inc(HeldPreparedCaches); Q.Next;
                  end;
                finally Q.Free; end;
              finally DB.Free; end;
            end;
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if Stage=Request.GetValue<string>('cancel_cache_preparation_stage','') then Stop:=True;
          end;
        TransferCacheInstallationTestPoint:=procedure(Stage:string)
          begin
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if Stage=Request.GetValue<string>('cancel_cache_installation_stage','') then Stop:=True;
          end;
        TransferReferenceTestPoint:=
          procedure(Stage:string)
          begin
            if (Stage='reference-row') and Request.GetValue<Boolean>('cancel_reference_scan',False) then Stop:=True;
            if (Stage='references-read') and (Request.GetValue<string>('change_reference_catalogue','')<>'') then
            begin
              var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('change_reference_catalogue'))));
              try
                DB.AddFunction('MHL_TRIGGERS_ON',0,DisableFixtureTriggers);
                DB.ExecSQL('UPDATE Books SET Folder=''changed-after-reference-scan.zip'' WHERE BookID=1');
              finally DB.Free; end;
            end;
          end;
        TransferRegistryTestPoint:=
          procedure(Stage,Operation:string; GroupID:Int64)
          begin
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if (Stage='registry-before-group-commit') and Request.GetValue<Boolean>('cancel_registry_commit',False) then Stop:=True;
          end;
        if Mode='discover' then
        begin
          Output:=TJSONObject.Create; var Pending:=TJSONArray.Create; Output.AddPair('operations',Pending);
          for var Item in RegisteredCollectionTransfers(Owned(Request.GetValue<string>('personal'))) do
          begin
            var Row:=TJSONObject.Create; Pending.AddElement(Row);
            Row.AddPair('operation',Item.Operation); Row.AddPair('directory',Item.Directory);
            Row.AddPair('review_sha256',Item.ReviewSHA256); Row.AddPair('collection',TJSONNumber.Create(Item.CollectionID));
          end;
          Output.AddPair('status','PASS'); TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8);
          Writeln('PASS read-only registered transfer discovery');
        end
        else
        begin
        if Mode='create' then
        begin
          Info.Clear; Info.ID:=7; Info.CollectionType:=CT_EXTERNAL_LOCAL_FB;
          Info.DBFileName:=Owned(Request.GetValue<string>('catalogue')); Info.RootFolder:=Owned(Request.GetValue<string>('root'));
          Capture:=TCollectionTransferCatalogue.Create(Info,Owned(Request.GetValue<string>('personal')),Owned(Request.GetValue<string>('work')));
          Plan:=Capture.BuildFilePlan(Owned(Request.GetValue<string>('destination')),Owned(Request.GetValue<string>('work')),
            StringToGUID('{A71B2224-0365-46A8-97E6-876445556001}'));
          TransferJournalTestPoint:=procedure(Stage,Directory:string; GroupID,FileID:Int64)
            begin
              if (Stage='preparation-before-review') and Request.GetValue<Boolean>('probe_active_draft_cleanup',False) then
                if TTransferDrafts.CleanAbandoned(Owned(Request.GetValue<string>('work')))<>0 then
                  raise EReadError.Create('Draft cleanup removed an active preparation');
              if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
                if (Stage='preparation-after-review') and Request.GetValue<Boolean>('legacy_approval_review',False) then
                begin
                  var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(TPath.Combine(Directory,'review.sqlite'))),False);
                  try DB.ExecSQL('DROP INDEX TransferApprovedLookup'); finally DB.Free; end;
                end;
              if Stage<>Request.GetValue<string>('cancel_preparation_stage','') then Exit;
              var Foreign:=Request.GetValue<string>('preparation_foreign','');
              var Review:=Owned(TPath.Combine(Directory,'review.sqlite'));
              if Foreign='file' then TFile.WriteAllText(Owned(TPath.Combine(Directory,'unrelated.txt')),'foreign preparation file',TEncoding.UTF8)
              else if Foreign='copies' then TFile.WriteAllText(Owned(TPath.Combine(Directory,'copies\unrelated.txt')),'foreign copies file',TEncoding.UTF8)
              else if Foreign='replacement' then
              begin
                var Incoming:=Owned(TPath.Combine(Directory,'incoming.txt'));
                TFile.WriteAllText(Incoming,'foreign replacement',TEncoding.UTF8);
                if not DeleteFile(PChar(Review)) or not MoveFile(PChar(Incoming),PChar(Review)) then RaiseLastOSError;
              end
              else if Foreign='hardlink' then
              begin
                if not CreateHardLink(PChar(Owned(TPath.Combine(Request.GetValue<string>('work'),'foreign-hardlink'))),PChar(Review),nil) then RaiseLastOSError;
              end
              else if Foreign='reader' then
              begin
                IncompletePreparationHandle:=CreateFile(PChar(Review),GENERIC_READ,FILE_SHARE_READ or FILE_SHARE_WRITE,
                  nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
                if IncompletePreparationHandle=INVALID_HANDLE_VALUE then begin IncompletePreparationHandle:=0; RaiseLastOSError; end;
              end;
              Stop:=True;
            end;
          Journal:=TCollectionTransferJournal.Create(Owned(Request.GetValue<string>('work')),Capture,Plan,
            function:Boolean begin Result:=Stop; end,Request.GetValue<Boolean>('space_preview',False));
          if Journal.IsPreview then
          begin
            Output:=TJSONObject.Create;
            Writeln('TRACE estimating transfer space'); Flush(System.Output);
            var Rows:=EstimateTransferSpace(Journal,Settings.DataPath,
              procedure begin if Request.GetValue<Boolean>('cancel_space',False) then Abort; end);
            var Budgets:=TJSONArray.Create; Output.AddPair('space',Budgets);
            Output.AddPair('preview_bindings',TJSONNumber.Create(Journal.Review.QuerySingleInt('SELECT count(*) FROM Bindings')));
            Output.AddPair('preview_references',TJSONNumber.Create(Journal.Review.QuerySingleInt('SELECT count(*) FROM RegisteredReferences')));
            Output.AddPair('preview_files',TJSONNumber.Create(Journal.Review.QuerySingleInt('SELECT count(*) FROM Files')));
            Output.AddPair('preview_review_bytes',TJSONNumber.Create(TFile.GetSize(DeletionNativePath(TPath.Combine(Journal.Directory,'review.sqlite')))));
            for var Budget in Rows do
            begin
              var Row:=TJSONObject.Create; Budgets.AddElement(Row); Row.AddPair('volume',Budget.Volume); Row.AddPair('key',Budget.Key);
              Row.AddPair('free',TJSONNumber.Create(Budget.Free)); Row.AddPair('books',TJSONNumber.Create(Budget.Books));
              Row.AddPair('working',TJSONNumber.Create(Budget.Working)); Row.AddPair('caches',TJSONNumber.Create(Budget.Caches));
              Row.AddPair('catalogues',TJSONNumber.Create(Budget.Catalogues)); Row.AddPair('reserve',TJSONNumber.Create(Budget.Reserve));
              Row.AddPair('required',TJSONNumber.Create(Budget.Required));
            end;
            var Refused:=False;
            try Registry:=TCollectionTransferRegistry.Create(Journal); except on E:EReadError do Refused:=True; end;
            if not Refused then raise EReadError.Create('Space preview can be registered as a move');
            Refused:=False;
            try var Prepared:=Journal.PrepareGroup(1); Prepared.Free; except on E:EReadError do Refused:=True; end;
            if not Refused then raise EReadError.Create('Space preview can prepare payloads');
            Refused:=False;
            try
              var Resumed:=TCollectionTransferJournal.Resume(Owned(Request.GetValue<string>('work')),
                Owned(Request.GetValue<string>('destination')),Journal.Directory,Journal.ReviewSHA256); Resumed.Free;
            except
              on E:EReadError do Refused:=True;
              on E:EOSError do if E.ErrorCode=ERROR_SHARING_VIOLATION then Refused:=True else raise;
            end;
            if not Refused then raise EReadError.Create('Space preview can be reopened as a move');
            var Directory:=Journal.Directory; FreeAndNil(Journal);
            if DirectoryExists(Directory) then raise EReadError.Create('Space review was not discarded');
            FreeAndNil(Plan); FreeAndNil(Capture);
            Output.AddPair('status','PASS'); TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8);
            Writeln('PASS volume space preview remains read-only refuses transfer and removes owned scratch'); Exit;
          end;
          Control:=TJSONObject.Create; Control.AddPair('directory',Journal.Directory);
          Control.AddPair('review_sha256',Journal.ReviewSHA256);
          TFile.WriteAllText(ControlFile,Control.ToJSON,TEncoding.UTF8);
          FreeAndNil(Plan); FreeAndNil(Capture);
        end
        else if Mode='registered' then
        begin
          Journal:=ResumeRegisteredCollectionTransfer(Owned(Request.GetValue<string>('personal')),Request.GetValue<string>('operation'));
          Control:=TJSONObject.Create; Control.AddPair('directory',Journal.Directory); Control.AddPair('review_sha256',Journal.ReviewSHA256);
        end
        else
        begin
          Control:=ReadJSON(ControlFile);
          Journal:=TCollectionTransferJournal.Resume(Owned(Request.GetValue<string>('work')),
            Owned(Request.GetValue<string>('destination')),Owned(Control.GetValue<string>('directory')),
            Request.GetValue<string>('override_review_sha256',Control.GetValue<string>('review_sha256')));
        end;
        if Request.GetValue<Boolean>('probe_transfer_temp',False) then
          ProbeTransferTemporaryRouting(Journal,Owned(TPath.Combine(ExtractFileDir(ControlFile),'temp-probe.jsonl')));
        Registry:=TCollectionTransferRegistry.Create(Journal);
        if Request.GetValue<Boolean>('register_operation',False) then Registry.RegisterOperation(function:Boolean begin Result:=Stop; end);
        var Wait:=Request.GetValue<string>('wait_for_release','');
        if Wait<>'' then
        begin
          Wait:=Owned(Wait); TFile.WriteAllText(Wait+'.waiting','ready',TEncoding.UTF8);
          var Started:=GetTickCount64;
          while not FileExists(Wait) do begin if GetTickCount64-Started>20000 then raise EAbort.Create('Fixture wait expired'); Sleep(25); end;
        end;
        TransferCopyTestPoint:=
          procedure(Stage,Directory:string)
          begin
            if Stage='copy-stream-start' then Inc(Copies);
            if 'file:'+Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if (Stage='source-protected') and Request.GetValue<Boolean>('probe_source_protection',False) then
            begin
              var Handle:=CreateFile(PChar(DeletionNativePath(Owned(Directory)+':HomeLibreNewStream')),GENERIC_WRITE,
                FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
              if Handle<>INVALID_HANDLE_VALUE then
              begin CloseHandle(Handle); raise EReadError.Create('Protected source allowed a new data stream'); end;
              var Code:=GetLastError;
              if Code<>ERROR_ACCESS_DENIED then RaiseLastOSError(Code);
            end;
            if (Stage=Request.GetValue<string>('cancel_source_stage','')) then Stop:=True;
          end;
        TransferJournalTestPoint:=
          procedure(Stage,Directory:string; GroupID,FileID:Int64)
          begin
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if (Stage='child-prepared') and Request.GetValue<Boolean>('cancel_after_file',False) then Stop:=True;
            if (Stage='fork-before-personal-commit') and Request.GetValue<Boolean>('cancel_fork_commit',False) then Stop:=True;
            if (Stage='locations-before-catalogue-commit') and Request.GetValue<Boolean>('cancel_location_commit',False) then Stop:=True;
            if (Stage='references-before-publication') and Request.GetValue<Boolean>('cancel_publication_fence',False) then Stop:=True;
            if (Stage='resources-before-commit') and Request.GetValue<Boolean>('cancel_resources',False) then Stop:=True;
            if (Stage='locations-before-verification') and Request.GetValue<Boolean>('probe_verification_locks',False) then
              ProbeVerificationLocks(Journal,True);
            if (Stage='removal-intent-committed') and Request.GetValue<Boolean>('probe_removal_gap_locks',False) then
              ProbeVerificationLocks(Journal,True,True);
            if (Stage='locations-after-catalogue-verification') and Request.GetValue<Boolean>('cancel_verification',False) then Stop:=True;
            if (Stage='resources-before-validation') and Request.GetValue<Boolean>('foreign_target_cover',False) then
            begin
              var Path:=Journal.Review.QuerySingleString('SELECT f.Destination FROM ImageSets i JOIN Files f ON f.ID=i.OwnerID '+
                'WHERE f.GroupID=? ORDER BY i.OwnerID LIMIT 1',[GroupID]);
              if Path<>'' then
              begin
                var Cover:=Owned(TPath.Combine(ExtractFileDir(Path),'covers\'+ChangeFileExt(ExtractFileName(Path),'.zip')));
                ForceDirectories(ExtractFileDir(Cover));
                if not FileExists(Cover) then TFile.WriteAllText(Cover,'foreign fixture cover',TEncoding.UTF8);
              end;
            end;
            var Edit:=Request.GetValue<string>('between_group_edit','');
            if not BetweenEdited and (Edit<>'') and (Stage=Request.GetValue<string>('edit_stage','locations-after-personal-commit')) then
            begin
              BetweenEdited:=True;
              if Edit='unknown-arrives' then
              begin
                var Path:=Owned(Journal.Review.QuerySingleString('SELECT Catalogue FROM ReferenceRegistrations WHERE RegistrationID=8'));
                ForceDirectories(ExtractFileDir(Path)); TFile.WriteAllText(Path,'new unavailable catalogue',TEncoding.UTF8);
              end
              else
              begin
                var Path:=Request.GetValue<string>('catalogue');
                if (Edit='personal-note') or (Edit='personal-reference') then Path:=Request.GetValue<string>('personal');
                var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Path)));
                try
                  DB.AddFunction('MHL_TRIGGERS_ON',0,DisableFixtureTriggers);
                  if Edit='personal-note' then DB.ExecSQL('UPDATE Books SET Annotation=''between archives'',Progress=92 WHERE BookID=1 AND DatabaseID=7')
                  else if Edit='title' then DB.ExecSQL('UPDATE Books SET Title=''between archives'',SearchTitle=''BETWEEN ARCHIVES'' WHERE BookID=1')
                  else if (Edit='new-reference') or (Edit='personal-reference') then
                  begin
                    var Q:=DB.NewQuery('PRAGMA table_info(Books)'); var Columns,Values:string;
                    try
                      Q.Open; Columns:=''; Values:='';
                      while not Q.Eof do
                      begin
                        var Column:='"'+StringReplace(Q.FieldAsString(1),'"','""',[rfReplaceAll])+'"';
                        if Columns<>'' then begin Columns:=Columns+','; Values:=Values+','; end;
                        Columns:=Columns+Column;
                        if Q.FieldAsString(1)='BookID' then Values:=Values+'991'
                        else if Q.FieldAsString(1)='Folder' then Values:=Values+QuotedStr(Owned(Request.GetValue<string>('new_reference_container')))
                        else Values:=Values+Column;
                        Q.Next;
                      end;
                    finally Q.Free; end;
                    DB.ExecSQL('INSERT INTO Books('+Columns+') SELECT '+Values+' FROM Books WHERE BookID=1');
                  end
                  else raise EArgumentException.Create('Unknown between-group fixture edit');
                finally DB.Free; end;
              end;
            end;
            if (Stage='references-before-publication') and (Request.GetValue<string>('wait_publication_fence','')<>'') then
            begin
              var Release:=Owned(Request.GetValue<string>('wait_publication_fence'));
              TFile.WriteAllText(Release+'.waiting','locked',TEncoding.UTF8);
              var Started:=GetTickCount64;
              while not FileExists(Release) do
              begin
                if GetTickCount64-Started>20000 then raise EAbort.Create('Publication fence fixture wait expired');
                Sleep(25);
              end;
            end;
          end;
        if Request.GetValue<Boolean>('complete_only',False) then
        begin
          var Done:=Journal.CompleteTransfer(
            function:Boolean begin Result:=not CompletionBusy; end,
            function:Boolean begin Result:=Stop; end);
          Output:=TJSONObject.Create;
          Output.AddPair('files',TJSONNumber.Create(Done.Files)); Output.AddPair('groups',TJSONNumber.Create(Done.Groups));
          Output.AddPair('bytes',TJSONNumber.Create(Done.Bytes)); Output.AddPair('removed',TJSONNumber.Create(Done.Removed));
          Output.AddPair('missing',TJSONNumber.Create(Done.Missing)); Output.AddPair('retained',TJSONNumber.Create(Done.Retained));
          Output.AddPair('completed_at',Done.CompletedAt);
          Output.AddPair('pending_operations',TJSONNumber.Create(Length(RegisteredCollectionTransfers(Owned(Request.GetValue<string>('personal'))))));
          TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8); Exit;
        end;
        if Request.GetValue<Boolean>('run_operation',False) then
        begin
          var Paths:=Journal.Review.NewQuery('SELECT Source,Destination FROM Files');
          try
            Paths.Open;
            while not Paths.Eof do begin Owned(Paths.FieldAsString(0)); Owned(Paths.FieldAsString(1)); Paths.Next; end;
          finally Paths.Free; end;
          var Operation:=TCollectionTransferOperation.Create(Journal);
          try
            var Handled:=Operation.Run(function:Boolean begin Result:=Stop; end,
              procedure(const Stage,Source:string; GroupsDone,GroupsTotal,Done,Total:Int64)
              begin
                if (Stage='Группа перенесена') and Request.GetValue<Boolean>('cancel_after_group',False) then Stop:=True;
                if (Stage='Группа перенесена') and (Crash='operation-group-handled') then
                begin Writeln('CRASH operation-group-handled'); Flush(System.Output); Halt(97); end;
              end,Request.GetValue<Boolean>('finalize_roots',False),Request.GetValue<Boolean>('prepare_source_caches',False),
              Request.GetValue<Boolean>('publish_cache_settings',False));
            RootsApplied:=Handled.RootsApplied;
            CachesPrepared:=Handled.CachesPrepared;
            PublishedCacheDatabases:=Handled.CacheDatabasesPublished;
            PreparedFiles:=Handled.FilesVerified; Removed:=Handled.Originals.Removed; Missing:=Handled.Originals.Missing;
            RetainedSources:=Handled.Originals.Retained; PendingSources:=Handled.Originals.Pending;
            if Handled.GroupsDone<>Handled.GroupsTotal then raise EReadError.Create('Operation omitted a reviewed group');
          finally Operation.Free; end;
        end
        else
        begin
        if Request.GetValue<Boolean>('cache_prepare_only',False) then
        begin
          var CacheRegistry:=TCollectionTransferRegistry.Create(Journal);
          try
            CacheRegistry.RegisterOperation(function:Boolean begin Result:=Stop; end);
            Journal.PublishCatalogueForks(function:Boolean begin Result:=Stop; end);
            CachesPrepared:=Journal.PrepareSourceCaches(function:Boolean begin Result:=Stop; end);
          finally CacheRegistry.Free; end;
        end;
        if Request.GetValue<Boolean>('publish_forks',False) or Request.GetValue<Boolean>('apply_locations',False) then
          Journal.PublishCatalogueForks(function:Boolean begin Result:=Stop; end);
        IDs:=TList<Int64>.Create;
        if Request.GetValue<Boolean>('prepare',False) then
        begin
          var Source:=Request.GetValue<string>('group_source','');
          if Source<>'' then
            IDs.Add(Journal.Review.QuerySingleInt('SELECT GroupID FROM Files WHERE Source=?',[Owned(Source)]))
          else Journal.ForEachGroup(procedure(const Group:TTransferJournalGroup) begin IDs.Add(Group.ID); end);
          for var ID in IDs do
          begin
            var Ready:TPreparedTransferGroup;
            if Request.GetValue<Boolean>('recover_registered_groups',False) then
              Ready:=Registry.RecoverGroup(ID,function:Boolean begin Result:=Stop; end)
            else if Request.GetValue<Boolean>('recover_groups',False) then
            begin
              var Proofs:=Control.GetValue<TJSONObject>('group_proofs',nil);
              if Proofs=nil then raise EReadError.Create('No independent fixture group proof');
              Ready:=Journal.RecoverPreparedGroup(ID,Request.GetValue<string>('override_group_proof',Proofs.GetValue<string>(IntToStr(ID))),
                function:Boolean begin Result:=Stop; end);
            end
            else Ready:=Journal.PrepareGroup(ID,function:Boolean begin Result:=Stop; end);
            try
              for var I:=0 to Ready.Count-1 do
              begin
                var Item:=Ready.CopyAt(I);
                if Request.GetValue<Boolean>('recover_groups',False) or Request.GetValue<Boolean>('recover_registered_groups',False) then
                begin
                  if Item.SourceHeld or (HashFile(Item.Destination)<>Item.SHA256) then raise EReadError.Create('Invalid recovered destination role');
                end
                else if HashFile(Item.Source)<>HashFile(Item.Destination) then raise EReadError.Create('Group payload mismatch');
                if Request.GetValue<Boolean>('probe_stream_leases',False) then
                begin ProbeStreamLeases(Item.Source); ProbeStreamLeases(Item.Destination); end;
                Inc(PreparedFiles);
              end;
              if Request.GetValue<Boolean>('apply_locations',False) then
              begin
                if Request.GetValue<Boolean>('register_groups',False) then
                  Registry.PublishPreparedGroup(Ready,function:Boolean begin Result:=Stop; end)
                else Journal.PublishGroupLocations(Ready,function:Boolean begin Result:=Stop; end);
              end;
              if Request.GetValue<Boolean>('verify_resources',False) and not Request.GetValue<Boolean>('apply_locations',False) then
                Journal.VerifyGroupResources(Ready,function:Boolean begin Result:=Stop; end);
              if Request.GetValue<Boolean>('register_groups',False) and not Request.GetValue<Boolean>('apply_locations',False) then
                Registry.RememberPreparedGroup(Ready,function:Boolean begin Result:=Stop; end);
              if Request.GetValue<Boolean>('seal_groups',False) then
              begin
                var SHA:=Journal.SealPreparedGroup(Ready,function:Boolean begin Result:=Stop; end);
                var Proofs:=Control.GetValue<TJSONObject>('group_proofs',nil);
                if Proofs=nil then begin Proofs:=TJSONObject.Create; Control.AddPair('group_proofs',Proofs); end;
                Proofs.RemovePair(IntToStr(ID)).Free; Proofs.AddPair(IntToStr(ID),SHA);
                TFile.WriteAllText(ControlFile,Control.ToJSON,TEncoding.UTF8);
              end;
              if Request.GetValue<Boolean>('verify_published',False) then
              begin
                Inc(VerifiedRetained,Registry.VerifyPublishedGroup(Ready,function:Boolean begin Result:=Stop; end));
                if Request.GetValue<Boolean>('probe_verification_locks',False) then ProbeVerificationLocks(Journal,False);
              end;
              if Request.GetValue<Boolean>('remove_sources',False) then
              begin
                for var I:=0 to Ready.Count-1 do
                begin Owned(Ready.CopyAt(I).Source); Owned(Ready.CopyAt(I).Destination); end;
                var Removal:=Registry.RemovePublishedGroup(Ready,function:Boolean begin Result:=Stop; end);
                Inc(Removed,Removal.Removed); Inc(Missing,Removal.Missing);
                Inc(RetainedSources,Removal.Retained); Inc(PendingSources,Removal.Pending);
                if Request.GetValue<Boolean>('probe_verification_locks',False) then ProbeVerificationLocks(Journal,False);
              end;
              if Request.GetValue<Boolean>('rebind_history',False) then
              begin
                var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('catalogue'))));
                try
                  DB.ExecSQL('PRAGMA synchronous=FULL'); DB.ExecSQL('BEGIN IMMEDIATE');
                  try
                    Inc(HistoryRows,RebindTransferHistory(DB,Journal.Review,Ready));
                    if Crash='history-before-commit' then begin Writeln('CRASH history-before-commit'); Flush(System.Output); Halt(97); end;
                    if Request.GetValue<Boolean>('rollback_history',False) then raise EAbort.Create('Fixture history rollback');
                    DB.ExecSQL('COMMIT');
                    if Crash='history-after-commit' then begin Writeln('CRASH history-after-commit'); Flush(System.Output); Halt(97); end;
                  except if DB.InTransaction then DB.Rollback; raise; end;
                finally DB.Free; end;
                for var I:=0 to Ready.Count-1 do
                begin
                  var Item:=TJSONObject.Create; HistoryHits.AddElement(Item); Item.AddPair('file_id',TJSONNumber.Create(Ready.FileID(I)));
                  Item.AddPair('hit',TJSONBool.Create(NativeCacheHit(Request.GetValue<string>('catalogue'),Request.GetValue<string>('personal'),
                    Request.GetValue<string>('root'),Ready.CopyAt(I).Destination)));
                end;
              end;
            finally Ready.Free; end;
          end;
        end;
        end;
        var InstalledCaches:Int64:=0;
        if Request.GetValue<Boolean>('install_cache_versions',False) then
          InstalledCaches:=Journal.InstallSourceCacheVersions(function:Boolean begin Result:=Stop; end);
        Output:=TJSONObject.Create; Groups:=TJSONArray.Create; Output.AddPair('groups',Groups);
        Output.AddPair('installed_caches',TJSONNumber.Create(InstalledCaches));
        Output.AddPair('published_cache_databases',TJSONNumber.Create(PublishedCacheDatabases));
        if Request.GetValue<Boolean>('read_reader_names',False) then Output.AddPair('reader_names',FixtureReaderNames(Request));
        if Request.GetValue<Boolean>('read_installed_caches',False) and ((InstalledCaches>0) or (PublishedCacheDatabases>0)) then
        begin
          var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Owned(Request.GetValue<string>('personal'))));
          try
            var Raw:=DB.QuerySingleString('SELECT IntentJSON FROM HomeLibreTransferCacheIntent WHERE Operation=?',[ExtractFileName(Journal.Directory)]);
            var Intent:=TJSONObject.ParseJSONValue(Raw) as TJSONObject;
            try
              var Hashes:=TJSONArray.Create; Output.AddPair('installed_book_hashes',Hashes);
              for var Value in Intent.GetValue<TJSONArray>('jobs') do
              begin
                var Job:=Value as TJSONObject; var Item:=TJSONObject.Create; Hashes.AddElement(Item);
                Item.AddPair('source',Job.GetValue<string>('source'));
                Item.AddPair('sha256',NativeBookHash(Owned(Job.GetValue<string>('after_file')),Job.GetValue<string>('after_root')));
              end;
            finally Intent.Free; end;
          finally DB.Free; end;
        end;
        Output.AddPair('history_rows',TJSONNumber.Create(HistoryRows)); Output.AddPair('history_hits',HistoryHits); HistoryHits:=nil;
        Output.AddPair('publication_scans',TJSONNumber.Create(Journal.PublicationScanCount));
        Output.AddPair('indexed_approval_snapshots',TJSONNumber.Create(IndexedApprovals));
        Output.AddPair('copied_approval_snapshots',TJSONNumber.Create(CopiedApprovals));
        Output.AddPair('readonly_approval_probes',TJSONNumber.Create(ReadOnlyApprovals));
        Output.AddPair('approval_sql_polls',TJSONNumber.Create(SQLApprovalPolls));
        Output.AddPair('verified_retained',TJSONNumber.Create(VerifiedRetained));
        Output.AddPair('removed_sources',TJSONNumber.Create(Removed));
        Output.AddPair('missing_sources',TJSONNumber.Create(Missing));
        Output.AddPair('retained_sources',TJSONNumber.Create(RetainedSources));
        Output.AddPair('pending_sources',TJSONNumber.Create(PendingSources));
        Output.AddPair('resource_validations',TJSONNumber.Create(Journal.ResourceValidationCount));
        Output.AddPair('roots_applied',TJSONBool.Create(RootsApplied));
        Output.AddPair('caches_prepared',TJSONNumber.Create(CachesPrepared));
        Output.AddPair('held_prepared_cache_checks',TJSONNumber.Create(HeldPreparedCaches));
        if Request.GetValue<Boolean>('final_rows',False) then
        begin
          // Isolated diagnostic for the row primitive only. The ordinary
          // This branch bypasses the separate production roots-intent controller.
          var FinalCat:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('catalogue'))),False);
          try
            var FinalPersonal:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('personal'))),False);
            try
              FinalCat.ExecSQL('PRAGMA synchronous=FULL'); FinalPersonal.ExecSQL('PRAGMA synchronous=FULL');
              FinalCat.ExecSQL('BEGIN IMMEDIATE'); FinalPersonal.ExecSQL('BEGIN IMMEDIATE');
              try
                var Checks:=0;
                var StopFinal:TFunc<Boolean>:=function:Boolean
                  begin Inc(Checks); Result:=(Request.GetValue<Integer>('final_rows_cancel_after',0)>0) and
                    (Checks>=Request.GetValue<Integer>('final_rows_cancel_after')); end;
                var IntentSHA:=THashSHA2.GetHashString('private final-row fixture v1:'+Journal.ReviewSHA256);
                var Verify:=Request.GetValue<Boolean>('verify_final_rows',False);
                var CatRows:=ApplyTransferFinalRows(FinalCat,FinalPersonal,Journal.Review,ExtractFileName(Journal.Directory),
                  Journal.ReviewSHA256,IntentSHA,False,Verify,StopFinal);
                var PersonalRows:=ApplyTransferFinalRows(FinalPersonal,FinalPersonal,Journal.Review,ExtractFileName(Journal.Directory),
                  Journal.ReviewSHA256,IntentSHA,True,Verify,StopFinal);
                Output.AddPair('final_future_rows',TJSONNumber.Create(CatRows.FutureRows+PersonalRows.FutureRows));
                Output.AddPair('final_copy_roots',TJSONNumber.Create(CatRows.CopyRoots));
                if Verify then begin FinalCat.Rollback; FinalPersonal.Rollback; end
                else begin FinalCat.Commit; FinalPersonal.Commit; end;
              except
                if FinalCat.InTransaction then FinalCat.Rollback;
                if FinalPersonal.InTransaction then FinalPersonal.Rollback;
                raise;
              end;
            finally FinalPersonal.Free; end;
          finally FinalCat.Free; end;
        end;
        if Request.GetValue<string>('cache_snapshot_job','')<>'' then
        begin
          var JobJSON:=Request.GetValue<string>('cache_snapshot_job'); var InputsJSON:=Request.GetValue<string>('cache_snapshot_inputs');
          var Binding:=Request.GetValue<string>('cache_snapshot_binding');
          var Job:=TJSONObject.ParseJSONValue(JobJSON) as TJSONObject;
          try Owned(Job.GetValue<string>('before_file')); Owned(Job.GetValue<string>('after_file'));
          if Request.GetValue<string>('backup_to_nonempty_target','')<>'' then
          begin
            var SourceDB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Owned(Job.GetValue<string>('before_file'))));
            try
              var TargetDB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('backup_to_nonempty_target'))),False);
              try SourceDB.BackupToEmpty(TargetDB); finally TargetDB.Free; end;
            finally SourceDB.Free; end;
            raise EReadError.Create('Nonempty backup destination was accepted');
          end;
          var InputCheck:=TJSONObject.ParseJSONValue(InputsJSON) as TJSONArray;
          try for var Value in InputCheck do begin Owned(TJSONObject(Value).GetValue<string>('source_file')); Owned(TJSONObject(Value).GetValue<string>('target_file')); end;
          finally InputCheck.Free; end;
          var Parent:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('cache_snapshot_parent'))),False);
          try
            Parent.ExecSQL('PRAGMA synchronous=FULL');
            Parent.ExecSQL('CREATE TABLE IF NOT EXISTS CacheSnapshotState(Context TEXT PRIMARY KEY,Directory TEXT,DirectoryKey TEXT,ReadySHA TEXT)');
            Parent.ExecSQL('CREATE TABLE IF NOT EXISTS CacheSnapshotOwnership(Context TEXT,Stage TEXT,Path TEXT,Data TEXT,PRIMARY KEY(Context,Stage,Path))');
            var Snapshot:TTransferCacheSnapshot:=nil;
            try
              if Request.GetValue<Boolean>('recover_cache_snapshot',False) then
              begin
                var Row:=Parent.NewQuery('SELECT Directory,DirectoryKey,ReadySHA FROM CacheSnapshotState WHERE Context=?',[Binding]);
                try
                  Row.Open; if Row.Eof then raise EReadError.Create('No independent cache snapshot state');
                  Snapshot:=TTransferCacheSnapshot.Recover(Journal.Review,Journal.ReviewSHA256,Journal.Directory,
                    Owned(Row.FieldAsString(0)),Row.FieldAsString(1),JobJSON,InputsJSON,Binding,Row.FieldAsString(2),
                    procedure begin if Stop then raise EAbort.Create('Fixture snapshot stop'); Journal.CheckSpace; end);
                finally Row.Free; end;
              end
              else Snapshot:=TTransferCacheSnapshot.CreateNew(Journal.Review,Journal.ReviewSHA256,Journal.Directory,
                JobJSON,InputsJSON,Binding,
                procedure(const Stage,DataJSON:string)
                begin
                  var Data:=TJSONObject.ParseJSONValue(DataJSON) as TJSONObject;
                  try
                    Owned(Data.GetValue<string>('directory')); Owned(Data.GetValue<string>('path'));
                    Parent.ExecSQL('BEGIN IMMEDIATE');
                    try
                      Parent.ExecSQL('INSERT OR REPLACE INTO CacheSnapshotOwnership VALUES(?,?,?,?)',
                        [Binding,Stage,Data.GetValue<string>('path'),DataJSON]);
                      if Stage='cache-directory-created' then Parent.ExecSQL('INSERT OR REPLACE INTO CacheSnapshotState VALUES(?,?,?,'''')',
                        [Binding,Data.GetValue<string>('directory'),Data.GetValue<string>('directory_key')]);
                      if Stage='cache-ready' then Parent.ExecSQL('UPDATE CacheSnapshotState SET ReadySHA=? WHERE Context=?',
                        [Data.GetValue<string>('key'),Binding]);
                      Parent.Commit;
                    except if Parent.InTransaction then Parent.Rollback; raise; end;
                    if (Stage='cache-backup-complete') and Request.GetValue<Boolean>('probe_cache_snapshot_writer',False) then
                    begin
                      var Other:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Job.GetValue<string>('before_file'))),False);
                      try
                        Other.SetTimeout(0); var Locked:=False;
                        try Other.ExecSQL('BEGIN IMMEDIATE');
                        except on E:ESQLiteException do if E.Message.ToLower.Contains('locked') or E.Message.ToLower.Contains('busy') then Locked:=True else raise; end;
                        if Other.InTransaction then Other.Rollback;
                        if not Locked then raise EReadError.Create('Snapshot source writer was not blocked');
                      finally Other.Free; end;
                    end;
                  finally Data.Free; end;
                end,
                procedure begin if Stop then raise EAbort.Create('Fixture snapshot stop'); Journal.CheckSpace; end);
              Snapshot.CheckUnchanged;
              Output.AddPair('snapshot_directory',Snapshot.Directory); Output.AddPair('snapshot_directory_key',Snapshot.DirectoryKey);
              Output.AddPair('snapshot_ready_sha256',Snapshot.ReadySHA); Output.AddPair('snapshot_proof',Snapshot.ProofJSON);
              Output.AddPair('snapshot_source_held',TJSONBool.Create(Snapshot.SourceHeld));
              if Request.GetValue<Boolean>('read_cache_snapshot',False) then
                Output.AddPair('snapshot_book_hash',NativeBookHash(TPath.Combine(Snapshot.Directory,'catalog.hlc2'),Job.GetValue<string>('after_root')));
            finally Snapshot.Free; end;
          finally Parent.Free; end;
          finally Job.Free; end;
        end;
        if Request.GetValue<Boolean>('cache_settings',False) then
        begin
          var StorePath:=Owned(Request.GetValue<string>('cache_settings_store'));
          if FileExists(StorePath) then raise EReadError.Create('Cache settings fixture store already exists');
          var Store:=TSQLiteDatabase.Create(DeletionNativePath(StorePath),False);
          try
            Store.ExecSQL('BEGIN IMMEDIATE');
            try
              var Calls:=0;
              var ReplayVersions:=TDictionary<string,string>.Create;
              try
              var VersionLookup:TFunc<string,string>:=nil;
              if Request.GetValue<string>('replay_cache_jobs','')<>'' then
              begin
                var Saved:=TJSONObject.ParseJSONValue(Request.GetValue<string>('replay_cache_jobs')) as TJSONArray;
                try
                  if (Saved=nil) or (Saved.Count>4096) then raise EReadError.Create('Invalid replay cache jobs');
                  for var Value in Saved do
                  begin
                    var Row:=Value as TJSONObject;
                    ReplayVersions.Add(Row.GetValue<string>('job'),Row.GetValue<string>('after_version'));
                  end;
                finally Saved.Free; end;
                VersionLookup:=function(Job:string):string
                  begin
                    if not ReplayVersions.TryGetValue(Job,Result) then raise EReadError.Create('Missing replay cache job');
                  end;
              end;
              var Model:=TTransferCacheSettingsPlan.Create(Journal.Review,Store,
                procedure
                begin
                  Inc(Calls);
                  if (Request.GetValue<Integer>('cancel_cache_settings_after',0)>0) and
                    (Calls>=Request.GetValue<Integer>('cancel_cache_settings_after')) then raise EAbort.Create('Fixture cache settings stop');
                end,VersionLookup);
              try
                var Before:=Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''sources_json''');
                Output.AddPair('cache_sources',Model.ProjectSources(Before,True));
                Output.AddPair('cache_history',Model.ProjectHistory(Request.GetValue<string>('cache_history',''),True));
                if Request.GetValue<Boolean>('cache_other_alias',False) then
                begin
                  Output.AddPair('cache_other_sources',Model.ProjectSources(Before,False));
                  Output.AddPair('cache_other_history',Model.ProjectHistory(Request.GetValue<string>('cache_history',''),False));
                end;
                Output.AddPair('cache_jobs',Model.Jobs); Output.AddPair('cache_inputs',Model.Inputs);
                Output.AddPair('cache_settings_checks',TJSONNumber.Create(Calls)); Store.Commit;
              finally Model.Free; end;
              finally ReplayVersions.Free; end;
            except if Store.InTransaction then Store.Rollback; raise; end;
          finally Store.Free; end;
        end;
        if Request.GetValue<string>('project_cache','')<>'' then
        begin
          var CachePath:=Owned(Request.GetValue<string>('project_cache'));
          var CacheRoot:=Owned(Request.GetValue<string>('cache_before_root'));
          var NewRoot:=Owned(Request.GetValue<string>('cache_after_root'));
          var CacheDB:=TSQLiteDatabase.Create(DeletionNativePath(CachePath),False);
          try
            CacheDB.ExecSQL('BEGIN IMMEDIATE');
            try
              var Calls:=0;
              var Projection:=ProjectTransferCache(Journal.Review,CacheDB,Request.GetValue<string>('cache_source_id','a'),
                Request.GetValue<string>('cache_namespace',''),CacheRoot,NewRoot,
                procedure
                begin
                  Inc(Calls);
                  if (Request.GetValue<Integer>('cancel_cache_after',0)>0) and
                    (Calls>=Request.GetValue<Integer>('cancel_cache_after')) then raise EAbort.Create('Fixture cache stop');
                end);
              if Crash='cache-before-commit' then begin Writeln('CRASH cache-before-commit'); Flush(System.Output); Halt(97); end;
              CacheDB.Commit;
              Output.AddPair('cache_examined',TJSONNumber.Create(Projection.Examined));
              Output.AddPair('cache_changed',TJSONNumber.Create(Projection.Changed));
              Output.AddPair('cache_source_keys',TJSONNumber.Create(Projection.SourceKeys));
              Output.AddPair('cache_review_keys',TJSONNumber.Create(Projection.ReviewKeys));
            except if CacheDB.InTransaction then CacheDB.Rollback; raise; end;
          finally CacheDB.Free; end;
          var Source:=Default(TCatalogSource); Source.ID:=Request.GetValue<string>('cache_source_id','a');
          Source.Name:='Private relocated cache'; Source.Root:=NewRoot;
          var CacheUser:ISystemData:=TSystemData_SQLite.Create(Owned(Request.GetValue<string>('cache_personal')));
          var Snapshot:=OpenCatalogSnapshot(Source,CachePath,CacheUser);
          var Entry:=Default(TMergeSource); Entry.ID:=Source.ID; Entry.Root:=Source.Root; Entry.Collection:=Snapshot;
          var Readback:=TJSONArray.Create; Output.AddPair('cache_readback',Readback);
          var Iterator:=Snapshot.GetPublisherSeriesIndexIterator; var Book:TBookRecord; var Series:string;
          while Iterator.Next(Book,Series) do
          begin
            var Row:=TJSONObject.Create; Readback.AddElement(Row); Row.AddPair('id',TJSONNumber.Create(Book.BookKey.BookID));
            Row.AddPair('key',MergeSourceKeyAtLocation(Entry,Book,TPath.Combine(Book.CollectionRoot,Book.Folder)));
            Row.AddPair('format',TJSONNumber.Create(Ord(Book.GetBookFormat(TPath.Combine(Book.CollectionRoot,Book.Folder)))));
            Row.AddPair('path',Book.GetBookFileName(TPath.Combine(Book.CollectionRoot,Book.Folder)));
            if Request.GetValue<Boolean>('cache_read_streams',False) then
            begin
              var Stream:=Book.GetBookStream;
              try if Stream=nil then raise EReadError.Create('Cache book has no native stream');
                Row.AddPair('sha256',THashSHA2.GetHashString(Stream));
              finally Stream.Free; end;
            end;
          end;
          Iterator:=nil; Entry.Collection:=nil; Snapshot:=nil;
        end;
        if Request.GetValue<Boolean>('final_layout',False) then
        begin
          var Layout:=TCollectionTransferLayout.Create(Journal.Review);
          try
            var Data:=TJSONObject.Create; Output.AddPair('final_layout',Data);
            var Roots:=TJSONArray.Create; Data.AddPair('roots',Roots);
            for var Root in Layout.Roots do
            begin
              var Row:=TJSONObject.Create; Roots.AddElement(Row); Row.AddPair('id',Root.ID);
              Row.AddPair('input',Root.Input); Row.AddPair('destination',Root.Destination);
              Row.AddPair('observed',TJSONBool.Create(Root.Observed));
            end;
            Data.AddPair('sources_json',Layout.SourceSettings);
            Data.AddPair('profiles_json',Layout.UpdateSettings(Request.GetValue<string>('layout_profiles','')));
            var Future:=TJSONArray.Create; Data.AddPair('future',Future);
            Layout.ForEachFutureLocator(
              procedure(const Locator:TTransferFutureLocator)
              begin
                var Row:=TJSONObject.Create; Future.AddElement(Row);
                Row.AddPair('binding',TJSONNumber.Create(Locator.BindingID)); Row.AddPair('kind',TJSONNumber.Create(Locator.Kind));
                Row.AddPair('book',TJSONNumber.Create(Locator.BookID)); Row.AddPair('key',Locator.SourceKey);
                Row.AddPair('source',Locator.Source); Row.AddPair('folder',Locator.Folder);
                Row.AddPair('filename',Locator.FileName); Row.AddPair('root',Locator.CopyRoot);
              end);
          finally Layout.Free; end;
        end;
        Journal.ForEachGroup(
          procedure(const Group:TTransferJournalGroup)
          begin
            var Row:=TJSONObject.Create; Row.AddPair('id',TJSONNumber.Create(Group.ID));
            Row.AddPair('files',TJSONNumber.Create(Group.Files)); Row.AddPair('bytes',TJSONNumber.Create(Group.Bytes));
            Row.AddPair('state',Group.State); Groups.AddElement(Row);
          end);
        Output.AddPair('status','PASS'); Output.AddPair('directory',Journal.Directory);
        Output.AddPair('review_sha256',Journal.ReviewSHA256); Output.AddPair('files',TJSONNumber.Create(Journal.FileCount));
        Output.AddPair('bindings',TJSONNumber.Create(Journal.Review.QuerySingleInt('SELECT count(*) FROM Bindings')));
        Output.AddPair('reference_conflicts',TJSONNumber.Create(TransferReferenceConflictCount(Journal.Review)));
        Output.AddPair('reference_issues',TJSONNumber.Create(Journal.Review.QuerySingleInt('SELECT count(*) FROM ReferenceIssues')));
        Output.AddPair('forks',TJSONNumber.Create(Journal.Review.QuerySingleInt('SELECT count(*) FROM CatalogueForks')));
        if Request.GetValue<Boolean>('history_witnesses',False) then
        begin
          var Witnesses:=TJSONArray.Create; Output.AddPair('history_witnesses',Witnesses);
          var Files:=Journal.Review.NewQuery('SELECT ID,Source,Identity FROM Files ORDER BY ID');
          try
            Files.Open;
            while not Files.Eof do
            begin
              var Source:=Files.FieldAsString(1); var Item:=TJSONObject.Create; Witnesses.AddElement(Item);
              Item.AddPair('file_id',TJSONNumber.Create(Files.FieldAsInt(0))); Item.AddPair('source',Source);
              Item.AddPair('identity',Files.FieldAsString(2)); Item.AddPair('sha256',HashFile(Source));
              Item.AddPair('stamp',CompressionImageStamp(Source));
              var Data:=CaptureCompressionImageSources(Source);
              try
                for var Value in Data do
                begin
                  var Path:=Value.GetValue<string>('path');
                  if Path<>'' then
                  begin
                    var Hash:=HashFile(Path); TJSONObject(Value).AddPair('source_sha256',Hash); TJSONObject(Value).AddPair('result_sha256',Hash);
                  end;
                end;
                if Data.Count>0 then Item.AddPair('images',Data.ToJSON) else Item.AddPair('images','');
              finally Data.Free; end;
              Files.Next;
            end;
          finally Files.Free; end;
        end;
        if Request.GetValue<Boolean>('read_fork_members',False) then
        begin
          Output.AddPair('keeper_native_sha256',NativeBookHash(Request.GetValue<string>('catalogue'),Request.GetValue<string>('root')));
          var Members:=Journal.Review.NewQuery('SELECT RegistrationID,Root FROM ReferenceRegistrations ORDER BY RegistrationID');
          var Native:TJSONArray:=TJSONArray.Create; Output.AddPair('native_fork_reads',Native);
          try
            Members.Open;
            while not Members.Eof do
            begin
              var Item:=TJSONObject.Create; Native.AddElement(Item); Item.AddPair('registration',TJSONNumber.Create(Members.FieldAsInt(0)));
              Item.AddPair('sha256',NativeBookHash(Journal.EffectiveCatalogue(Members.FieldAsInt(0)),Members.FieldAsString(1)));
              Members.Next;
            end;
          finally Members.Free; end;
        end;
        var Retained:=TJSONArray.Create; Output.AddPair('retained_files',Retained);
        var Files:=Journal.Review.NewQuery('SELECT ID FROM Files ORDER BY ID');
        try
          Files.Open;
          while not Files.Eof do
          begin
            var ID:=StrToInt64(Files.FieldAsString(0));
            if TransferReferenceRequiresRetention(Journal.Review,ID) then Retained.Add(ID);
            Files.Next;
          end;
        finally Files.Free; end;
        Output.AddPair('copy_streams',TJSONNumber.Create(Copies)); Output.AddPair('prepared_files',TJSONNumber.Create(PreparedFiles));
        Output.AddPair('pending_group',TJSONNumber.Create(Journal.PendingGroup));
        TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8);
        Writeln('PASS frozen transfer review and durable group preparation');
        end;
      finally
        TransferCopyTestPoint:=nil; TransferJournalTestPoint:=nil;
        TransferCleanupTestPoint:=nil;
        TransferApprovalTestPoint:=nil;
        TransferApprovalReadOnlyProbe:=nil; TransferApprovalSQLTestPoint:=nil;
        if IncompletePreparationHandle<>0 then CloseHandle(IncompletePreparationHandle);
        TransferReferenceTestPoint:=nil; TransferRegistryTestPoint:=nil; TransferFinalizationTestPoint:=nil;
        HistoryHits.Free; IDs.Free; Registry.Free; Journal.Free; Plan.Free; Capture.Free; Output.Free; Control.Free; Request.Free;
      end;
    finally FreeAndNil(DMUser); end;
  except on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end; end;
end.
