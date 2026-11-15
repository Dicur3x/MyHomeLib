program CollectionTransferJournalTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash,
  System.Generics.Collections, Winapi.Windows, NativeRegressionGuard, dm_user,
  SQLiteWrap, unit_Globals, unit_Consts, unit_ZipMemberDeletion,
  unit_CollectionTransferCatalogue, unit_CollectionTransferPlan,
  unit_CollectionTransferCopy, unit_CollectionTransferJournal;

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

var Request,Control,Output:TJSONObject; Capture:TCollectionTransferCatalogue; Plan:TCollectionTransferPlan;
    Journal:TCollectionTransferJournal; Info:TCollectionInfo; ControlFile,Mode,Crash:string;
    Copies,PreparedFiles:Integer; Stop:Boolean; Groups:TJSONArray; IDs:TList<Int64>;
begin
  SetTextCodePage(System.Output,CP_UTF8);
  try
    RequireIsolatedRegression; DMUser:=TDMUser.Create(nil);
    try
      if ParamCount<>2 then raise EArgumentException.Create('Expected request and result');
      Request:=ReadJSON(ParamStr(1)); Control:=nil; Output:=nil; Capture:=nil; Plan:=nil; Journal:=nil; IDs:=nil;
      try
        Mode:=Request.GetValue<string>('mode','create'); ControlFile:=Owned(Request.GetValue<string>('control'));
        Crash:=Request.GetValue<string>('crash',''); Copies:=0; PreparedFiles:=0; Stop:=False;
        if Mode='create' then
        begin
          Info.Clear; Info.ID:=7; Info.CollectionType:=CT_EXTERNAL_LOCAL_FB;
          Info.DBFileName:=Owned(Request.GetValue<string>('catalogue')); Info.RootFolder:=Owned(Request.GetValue<string>('root'));
          Capture:=TCollectionTransferCatalogue.Create(Info,Owned(Request.GetValue<string>('personal')),Owned(Request.GetValue<string>('work')));
          Plan:=Capture.BuildFilePlan(Owned(Request.GetValue<string>('destination')),Owned(Request.GetValue<string>('work')),
            StringToGUID('{A71B2224-0365-46A8-97E6-876445556001}'));
          Journal:=TCollectionTransferJournal.Create(Owned(Request.GetValue<string>('work')),Capture,Plan);
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
          end;
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
            finally Ready.Free; end;
          end;
        end;
        Output:=TJSONObject.Create; Groups:=TJSONArray.Create; Output.AddPair('groups',Groups);
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
        Output.AddPair('copy_streams',TJSONNumber.Create(Copies)); Output.AddPair('prepared_files',TJSONNumber.Create(PreparedFiles));
        Output.AddPair('pending_group',TJSONNumber.Create(Journal.PendingGroup));
        TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8);
        Writeln('PASS frozen transfer review and durable group preparation');
      finally
        TransferCopyTestPoint:=nil; TransferJournalTestPoint:=nil;
        IDs.Free; Journal.Free; Plan.Free; Capture.Free; Output.Free; Control.Free; Request.Free;
      end;
    finally FreeAndNil(DMUser); end;
  except on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end; end;
end.
