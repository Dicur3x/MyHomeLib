program CollectionTransferJournalTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash,
  System.Generics.Collections, Winapi.Windows, NativeRegressionGuard, dm_user,
  SQLiteWrap, SQLite3, unit_Globals, unit_Consts, unit_ZipMemberDeletion,
  unit_CollectionTransferCatalogue, unit_CollectionTransferPlan,
  unit_CollectionTransferCopy, unit_CollectionTransferJournal, unit_CollectionTransferReferences,
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

var Request,Control,Output:TJSONObject; Capture:TCollectionTransferCatalogue; Plan:TCollectionTransferPlan;
    Journal:TCollectionTransferJournal; Info:TCollectionInfo; ControlFile,Mode,Crash:string;
    Copies,PreparedFiles:Integer; Stop:Boolean; Groups,HistoryHits:TJSONArray; IDs:TList<Int64>; HistoryRows:Int64;
begin
  SetTextCodePage(System.Output,CP_UTF8);
  try
    RequireIsolatedRegression; DMUser:=TDMUser.Create(nil);
    try
      if ParamCount<>2 then raise EArgumentException.Create('Expected request and result');
      Request:=ReadJSON(ParamStr(1)); Control:=nil; Output:=nil; Capture:=nil; Plan:=nil; Journal:=nil; IDs:=nil;
      try
        Mode:=Request.GetValue<string>('mode','create'); ControlFile:=Owned(Request.GetValue<string>('control'));
        Crash:=Request.GetValue<string>('crash',''); Copies:=0; PreparedFiles:=0; Stop:=False; HistoryRows:=0; HistoryHits:=TJSONArray.Create;
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
        else
        begin
          Control:=ReadJSON(ControlFile);
          Journal:=TCollectionTransferJournal.Resume(Owned(Request.GetValue<string>('work')),
            Owned(Request.GetValue<string>('destination')),Owned(Control.GetValue<string>('directory')),
            Request.GetValue<string>('override_review_sha256',Control.GetValue<string>('review_sha256')));
        end;
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
          end;
        TransferJournalTestPoint:=
          procedure(Stage,Directory:string; GroupID,FileID:Int64)
          begin
            if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
            if (Stage='child-prepared') and Request.GetValue<Boolean>('cancel_after_file',False) then Stop:=True;
            if (Stage='fork-before-personal-commit') and Request.GetValue<Boolean>('cancel_fork_commit',False) then Stop:=True;
            if (Stage='locations-before-catalogue-commit') and Request.GetValue<Boolean>('cancel_location_commit',False) then Stop:=True;
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
            var Ready:=Journal.PrepareGroup(ID,function:Boolean begin Result:=Stop; end);
            try
              for var I:=0 to Ready.Count-1 do
              begin
                var Item:=Ready.CopyAt(I);
                if HashFile(Item.Source)<>HashFile(Item.Destination) then raise EReadError.Create('Group payload mismatch');
                Inc(PreparedFiles);
              end;
              if Request.GetValue<Boolean>('apply_locations',False) then
                Journal.PublishGroupLocations(Ready,function:Boolean begin Result:=Stop; end);
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
        Output:=TJSONObject.Create; Groups:=TJSONArray.Create; Output.AddPair('groups',Groups);
        Output.AddPair('history_rows',TJSONNumber.Create(HistoryRows)); Output.AddPair('history_hits',HistoryHits); HistoryHits:=nil;
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
      finally
        TransferCopyTestPoint:=nil; TransferJournalTestPoint:=nil;
        TransferReferenceTestPoint:=nil;
        HistoryHits.Free; IDs.Free; Journal.Free; Plan.Free; Capture.Free; Output.Free; Control.Free; Request.Free;
      end;
    finally FreeAndNil(DMUser); end;
  except on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end; end;
end.
