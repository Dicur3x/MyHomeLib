program BookCompressionOperationTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash,
  Winapi.Windows, unit_BookCompressionPlan, unit_BookCompressionOperation,
  unit_BookCompressionJob, unit_BookCompressionRuntime, unit_ZipMemberDeletion, unit_CollectionPacking, unit_Globals, unit_Settings, dm_user,
  SQLiteWrap, unit_BookCompressionIndex;

function Text(Obj:TJSONObject; const Name:string):string;
begin Result:=Obj.GetValue<string>(Name,''); end;

function Digest(const FileName:string):string;
var Stream:TFileStream;
begin
  Stream:=TFileStream.Create(DeletionNativePath(FileName),fmOpenRead or fmShareDenyWrite);
  try Result:=THashSHA2.GetHashString(Stream); finally Stream.Free; end;
end;

var Data, Entry, Output:TJSONObject; Info:TCollectionInfo;
    Books:TArray<TBookRecord>; Options:TBookCompressionOperationOptions;
    Operation:TBookCompressionOperation; State:TBookCompressionOperationStatus;
    Mode, BeforeReview, AllowedSource:string; Started, TimeLimit:UInt64;
    SeenReview, Disposed, SourceGuardVerified:Boolean;
begin
  try
    Data:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ParamStr(1),TEncoding.UTF8)) as TJSONObject;
    if Data=nil then raise EReadError.Create('Invalid operation fixture request');
    try
      Entry:=Data.GetValue<TJSONObject>('options');
      Info:=Default(TCollectionInfo); Info.ID:=Entry.GetValue<Integer>('collection_id');
      Info.RootFolder:=Text(Entry,'base_root'); Info.DBFileName:=Text(Entry,'catalogue');
      var Rows:=Data.GetValue<TJSONArray>('selected');
      SetLength(Books,Rows.Count);
      for var I:=0 to Rows.Count-1 do
      begin
        var Row:=Rows.Items[I] as TJSONObject;
        Books[I]:=Default(TBookRecord);
        Books[I].BookKey:=CreateBookKey(Row.GetValue<Integer>('id'),Info.ID);
        Books[I].LibID:=Text(Row,'lib_id'); Books[I].Folder:=Text(Row,'folder');
        Books[I].FileName:=Text(Row,'file_name'); Books[I].FileExt:=Text(Row,'ext');
        Books[I].InsideNo:=Row.GetValue<Integer>('inside_no',0);
        Books[I].CollectionRoot:=Text(Entry,'root');
      end;
      Options:=Default(TBookCompressionOperationOptions);
      Options.WorkRoot:=Text(Data,'work_root'); Options.Python:=Text(Data,'python');
      Options.QueueName:=Text(Data,'queue_name');
      Options.Script:=Text(Data,'script'); Options.SevenZip:=Text(Data,'seven_zip');
      Options.ToolsRoot:=Text(Data,'tools_root'); Options.Profile:=Text(Data,'profile');
      Options.Grayscale:=Data.GetValue<Boolean>('grayscale',False);
      Options.EstimateFirst:=Data.GetValue<Boolean>('estimate_first',False);
      Options.OnlyNew:=Data.GetValue<Boolean>('only_new',False);
      Options.BackupOriginals:=Data.GetValue<Boolean>('backup_originals',False);
      Options.BackupFolder:=Text(Data,'backup_folder');
      Mode:=Text(Data,'operation_mode'); Options.ReviewResults:=Mode.StartsWith('review') or Mode.StartsWith('dispose');
      AllowedSource:=Text(Data,'allowed_source');
      if (AllowedSource<>'') and ((Mode<>'review-apply') or
        Data.GetValue<Boolean>('whole',False) or Options.EstimateFirst) then
        raise EArgumentException.Create('An allowed test source requires reviewed selected compression.');
      TimeLimit:=Data.GetValue<UInt64>('timeout_ms',30000);
      if (TimeLimit<1000) or (TimeLimit>300000) then
        raise EArgumentException.Create('Invalid bounded operation test timeout');
      ConfigureMHLHostProfile(TPath.GetDirectoryName(ParamStr(1)),'operation-test.ini','operation-test.dbs2');
      if Mode='book-stream' then
      begin
        if Length(Books)<>1 then raise EReadError.Create('Select exactly one reading fixture');
        DMUser:=TDMUser.Create(nil);
        var Stream:TStream:=nil;
        try
          Stream:=Books[0].GetBookStream;
          if Stream=nil then raise EReadError.Create('The selected book cannot be restored');
          var Name:=TPath.Combine(ExtractFileDir(ParamStr(1)),'restored-book.bin');
          var Target:=TFileStream.Create(Name,fmCreate);
          try Stream.Position:=0; Target.CopyFrom(Stream,Stream.Size); finally Target.Free; end;
          Output:=TJSONObject.Create;
          try
            Output.AddPair('error',''); Output.AddPair('warning',''); Output.AddPair('book_stream',Name);
            Output.AddPair('book_size',TJSONNumber.Create(Stream.Size));
            TFile.WriteAllText(ParamStr(2),Output.ToJSON,TEncoding.UTF8);
          finally Output.Free; end;
        finally Stream.Free; FreeAndNil(DMUser); end;
        Exit;
      end;
      if Mode.StartsWith('index-') then
      begin
        var DB:=TSQLiteDatabase.Create(Info.DBFileName);
        try
          DB.Start;
          CaptureCompressionIndexSizes(DB,Info.RootFolder,'LibID');
          DB.ExecSQL('UPDATE Books SET BookID=BookID+1000,BookSize=999');
          if Mode='index-after-image-change' then
          begin
            var Image:=TPath.Combine(Info.RootFolder,'covers\books.zip');
            var Changed:=TFileStream.Create(Image,fmOpenReadWrite);
            try
              Changed.Position:=Changed.Size;
              var ByteValue:Byte:=1; Changed.WriteBuffer(ByteValue,1);
            finally Changed.Free; end;
          end;
          if Text(Data,'index_folder')<>'' then
            DB.ExecSQL('UPDATE Books SET Folder=?',[Text(Data,'index_folder')]);
          RestoreCompressionIndexSizes(DB,Info.RootFolder,'LibID');
          var Size:=DB.QuerySingleInt('SELECT BookSize FROM Books WHERE LibID=''flibusta:101''');
          DB.Commit;
          Output:=TJSONObject.Create;
          try
            Output.AddPair('error',''); Output.AddPair('warning','');
            Output.AddPair('index_size',TJSONNumber.Create(Size));
            TFile.WriteAllText(ParamStr(2),Output.ToJSON,TEncoding.UTF8);
          finally Output.Free; end;
        finally DB.Free; end;
        Exit;
      end;
      if Mode='resolve-tools' then
      begin
        Output:=TJSONObject.Create;
        try
          var Missing:=TJSONArray.Create;
          for var ID in ResolveSelectedCompressionTools(Text(Data,'app_path'),Options) do Missing.Add(ID);
          Output.AddPair('missing',Missing);
          TFile.WriteAllText(ParamStr(2),Output.ToJSON,TEncoding.UTF8);
        finally Output.Free; end;
        Exit;
      end;
      DMUser:=TDMUser.Create(nil);
      try
{$IFDEF MHL_COMPRESSION_TEST}
        CompressionOperationTestFault:=nil;
        if Text(Data,'fault_at')<>'' then CompressionOperationTestFault:=procedure(Stage:string)
          begin
            if (Text(Data,'fault_at')<>'') and (Stage=Text(Data,'fault_at')) then
            begin
              Writeln('TRACE terminated at ',Stage); Flush(System.Output);
              if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
            end;
          end;
{$ENDIF}
        if Mode='recover' then Operation:=TBookCompressionOperation.Recover(Options)
        else Operation:=TBookCompressionOperation.Create(Options,
          function(const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>):TBookCompressionPlan
          begin
            if Data.GetValue<Boolean>('whole',False) then
              Result:=BuildCollectionCompressionPlan(Info,Text(Entry,'personal'),Options.WorkRoot,Cancelled,Progress)
            else Result:=BuildSelectedCompressionPlan(Info,Text(Entry,'personal'),Books,Cancelled,Progress);
          end);
        try
          if Mode='stop-before' then Operation.RequestStop;
          Started:=GetTickCount64; SeenReview:=False; BeforeReview:=''; Disposed:=False;
          SourceGuardVerified:=False;
          Operation.Start;
          repeat
            State:=Operation.Status;
            if State.AwaitingReview then
            begin
              if (AllowedSource<>'') and not State.AwaitingEstimate then
              begin
                if not SameFileName(ExpandFileName(State.Source),ExpandFileName(AllowedSource)) then
                  raise EReadError.Create('Refusing write outside the allowed test source.');
                SourceGuardVerified:=True;
              end;
              if not SeenReview then
              begin
                if not State.AwaitingEstimate then BeforeReview:=Digest(State.Source);
                if Mode='review-backup-missing' then
                  if not RemoveDirectory(PChar(Options.BackupFolder)) then RaiseLastOSError;
                if Mode='review-backup-corrupt' then
                begin
                  var Prepared:=TJSONObject.ParseJSONValue(TFile.ReadAllText(DeletionNativePath(State.ReportFile),TEncoding.UTF8)) as TJSONObject;
                  try
                    var Backup:=Prepared.GetValue<TJSONObject>('originals').GetValue<string>('path');
                    var Stream:=TFileStream.Create(DeletionNativePath(Backup),fmOpenReadWrite);
                    var Damage:UInt32:=$FFFF0000;
                    try Stream.Position:=45; Stream.WriteBuffer(Damage,SizeOf(Damage)); finally Stream.Free; end;
                  finally Prepared.Free; end;
                end;
              end;
              SeenReview:=True;
              if Mode='review-crash' then
              begin
                Writeln('TRACE terminated before compression approval'); Flush(System.Output);
                if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
              end;
              if (Mode='review-skip') or ((Mode='estimate-only') and State.AwaitingEstimate) then Operation.Approve(crSkip)
              else if Mode='review-stop' then Operation.RequestStop
              else if Mode='review-all' then Operation.Approve(crApplyRemaining)
              else if Mode='dispose-at-review' then
              begin FreeAndNil(Operation); Disposed:=True; Break; end
              else Operation.Approve(crApply);
            end;
            if Mode='stop-producer' then
              if State.Stage='slow-worker' then Operation.RequestStop;
            if (Mode='crash-producer') and (State.Stage='scratch-ready') then
            begin
              Writeln('TRACE terminated during compression preparation'); Flush(System.Output);
              if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
            end;
            if State.Finished then Break;
            if GetTickCount64-Started>TimeLimit then
              raise Exception.Create('Operation fixture timed out: '+State.Stage+' '+State.Member);
            Sleep(10);
          until False;
          if Assigned(Operation) then Operation.WaitFor;
          Output:=TJSONObject.Create;
          try
            Output.AddPair('disposed',TJSONBool.Create(Disposed));
            Output.AddPair('review_seen',TJSONBool.Create(SeenReview));
            Output.AddPair('before_review_sha256',BeforeReview);
            if Assigned(Operation) then
            begin
              var PendingBefore:=Length(TBookCompressionJob.Pending(Operation.QueueRoot));
              if Data.GetValue<Boolean>('acknowledge',True) then Operation.AcknowledgeCompletedJobs;
              State:=Operation.Status;
              Output.AddPair('error',State.Error); Output.AddPair('warning',State.Warning);
              Output.AddPair('stage',State.Stage); Output.AddPair('pending_job',State.PendingJob);
              Output.AddPair('finished',TJSONBool.Create(State.Finished));
              Output.AddPair('stopping',TJSONBool.Create(State.Stopping));
              Output.AddPair('savings_known',TJSONBool.Create(State.SavingsKnown));
              Output.AddPair('files_done',TJSONNumber.Create(State.FilesDone));
              Output.AddPair('files_total',TJSONNumber.Create(State.FilesTotal));
              Output.AddPair('books_done',TJSONNumber.Create(State.BooksDone));
              Output.AddPair('books_total',TJSONNumber.Create(State.BooksTotal));
              Output.AddPair('changed_files',TJSONNumber.Create(State.ChangedFiles));
              Output.AddPair('allowed_source_verified',TJSONBool.Create(SourceGuardVerified));
              Output.AddPair('unchanged_files',TJSONNumber.Create(State.UnchangedFiles));
              Output.AddPair('skipped_files',TJSONNumber.Create(State.SkippedFiles));
              Output.AddPair('previously_processed_books',TJSONNumber.Create(State.PreviouslyProcessedBooks));
              Output.AddPair('saved_bytes',TJSONNumber.Create(State.SavedBytes));
              Output.AddPair('estimate_only',TJSONBool.Create(State.EstimateOnly));
              Output.AddPair('estimate_input_bytes',TJSONNumber.Create(State.EstimateInputBytes));
              Output.AddPair('estimate_known_input_bytes',TJSONNumber.Create(State.EstimateKnownInputBytes));
              Output.AddPair('estimate_output_bytes',TJSONNumber.Create(State.EstimateOutputBytes));
              Output.AddPair('estimate_archive_bytes',TJSONNumber.Create(State.EstimateArchiveBytes));
              Output.AddPair('estimate_unknown_books',TJSONNumber.Create(State.EstimateUnknownBooks));
              Output.AddPair('backup_files',TJSONNumber.Create(State.BackupFiles));
              Output.AddPair('discarded_preparations',TJSONNumber.Create(State.DiscardedPreparations));
              Output.AddPair('backup_folder',State.BackupFolder);
              Output.AddPair('pending_before_ack',TJSONNumber.Create(PendingBefore));
              Output.AddPair('pending_after_ack',TJSONNumber.Create(Length(TBookCompressionJob.Pending(Operation.QueueRoot))));
            end;
            TFile.WriteAllText(ParamStr(2),Output.ToJSON,TEncoding.UTF8);
          finally Output.Free; end;
        finally Operation.Free; end;
      finally FreeAndNil(DMUser); end;
    finally Data.Free; end;
  except on E:Exception do
    begin
      var Bytes:=TEncoding.UTF8.GetBytes(E.ClassName+': '+E.Message+sLineBreak); var Written:DWORD;
      WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),Bytes[0],Length(Bytes),Written,nil); Halt(1);
    end;
  end;
end.
