program CollectionTransferJournalTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash,
  System.Generics.Collections, Winapi.Windows, NativeRegressionGuard, dm_user,
  SQLiteWrap, SQLite3, unit_Globals, unit_Consts, unit_ZipMemberDeletion,
  unit_CollectionTransferCatalogue, unit_CollectionTransferPlan,
  unit_CollectionTransferCopy, unit_CollectionTransferJournal, unit_CollectionTransferReferences, unit_CollectionTransferRegistry,
  unit_CollectionTransferOperation,
  unit_CollectionTransferLayout, unit_CollectionTransferFinalRows, unit_CollectionTransferFinalization,
  unit_CollectionTransferHistory, unit_CollectionTransferLocations, unit_BookCompressionImages, unit_BookCompressionReceipt, unit_BookCompressionPlan;

procedure DisableFixtureTriggers(Context:TSQLite3Context; Count:Integer; Values:TSQLite3Value); cdecl;
begin SQLite3_Result_Int(Context,0); end;

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

procedure ProbeVerificationLocks(Journal:TCollectionTransferJournal; Expected:Boolean);
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
        if Locked<>Expected then raise EReadError.Create('Unexpected verification writer-lock state');
      finally DB.Free; end;
    end;
  finally Q.Free; Paths.Free; end;
end;

var Request,Control,Output:TJSONObject; Capture:TCollectionTransferCatalogue; Plan:TCollectionTransferPlan;
    Journal:TCollectionTransferJournal; Registry:TCollectionTransferRegistry; Info:TCollectionInfo; ControlFile,Mode,Crash:string;
    Copies,PreparedFiles:Integer; Stop,BetweenEdited:Boolean; Groups,HistoryHits:TJSONArray; IDs:TList<Int64>; HistoryRows,VerifiedRetained:Int64;
    Removed,Missing,RetainedSources,PendingSources:Int64; RootsApplied:Boolean;
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
        Removed:=0; Missing:=0; RetainedSources:=0; PendingSources:=0; RootsApplied:=False;
        TransferFinalizationTestPoint:=procedure(Stage:string)
          begin
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if Request.GetValue<string>('cancel_finalization_stage','')=Stage then Stop:=True;
            if (Stage='finalization-after-catalogue-commit') and Request.GetValue<Boolean>('edit_finalization_gap',False) then
            begin
              var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Request.GetValue<string>('catalogue'))));
              try DB.AddFunction('MHL_TRIGGERS_ON',0,DisableFixtureTriggers);
                DB.ExecSQL('UPDATE Books SET Title=''late finalization title'' WHERE BookID=1');
              finally DB.Free; end;
            end;
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
          Journal:=TCollectionTransferJournal.Create(Owned(Request.GetValue<string>('work')),Capture,Plan,
            function:Boolean begin Result:=Stop; end);
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
                if Edit='personal-note' then Path:=Request.GetValue<string>('personal');
                var DB:=TSQLiteDatabase.Create(DeletionNativePath(Owned(Path)));
                try
                  DB.AddFunction('MHL_TRIGGERS_ON',0,DisableFixtureTriggers);
                  if Edit='personal-note' then DB.ExecSQL('UPDATE Books SET Annotation=''between archives'',Progress=92 WHERE BookID=1 AND DatabaseID=7')
                  else if Edit='title' then DB.ExecSQL('UPDATE Books SET Title=''between archives'',SearchTitle=''BETWEEN ARCHIVES'' WHERE BookID=1')
                  else if Edit='new-reference' then
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
              end,Request.GetValue<Boolean>('finalize_roots',False));
            RootsApplied:=Handled.RootsApplied;
            PreparedFiles:=Handled.FilesVerified; Removed:=Handled.Originals.Removed; Missing:=Handled.Originals.Missing;
            RetainedSources:=Handled.Originals.Retained; PendingSources:=Handled.Originals.Pending;
            if Handled.GroupsDone<>Handled.GroupsTotal then raise EReadError.Create('Operation omitted a reviewed group');
          finally Operation.Free; end;
        end
        else
        begin
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
        Output:=TJSONObject.Create; Groups:=TJSONArray.Create; Output.AddPair('groups',Groups);
        Output.AddPair('history_rows',TJSONNumber.Create(HistoryRows)); Output.AddPair('history_hits',HistoryHits); HistoryHits:=nil;
        Output.AddPair('publication_scans',TJSONNumber.Create(Journal.PublicationScanCount));
        Output.AddPair('verified_retained',TJSONNumber.Create(VerifiedRetained));
        Output.AddPair('removed_sources',TJSONNumber.Create(Removed));
        Output.AddPair('missing_sources',TJSONNumber.Create(Missing));
        Output.AddPair('retained_sources',TJSONNumber.Create(RetainedSources));
        Output.AddPair('pending_sources',TJSONNumber.Create(PendingSources));
        Output.AddPair('resource_validations',TJSONNumber.Create(Journal.ResourceValidationCount));
        Output.AddPair('roots_applied',TJSONBool.Create(RootsApplied));
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
        TransferReferenceTestPoint:=nil; TransferRegistryTestPoint:=nil; TransferFinalizationTestPoint:=nil;
        HistoryHits.Free; IDs.Free; Registry.Free; Journal.Free; Plan.Free; Capture.Free; Output.Free; Control.Free; Request.Free;
      end;
    finally FreeAndNil(DMUser); end;
  except on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end; end;
end.
