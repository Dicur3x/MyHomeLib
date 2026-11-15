program CollectionTransferCatalogueTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash, System.Generics.Collections, Winapi.Windows,
  NativeRegressionGuard, SQLiteWrap, unit_Globals, unit_Consts, dm_user,
  unit_CollectionTransferCatalogue, unit_CollectionTransferPlan, unit_CollectionTransferCopy;

function Owned(const Path:string):string;
begin
  Result:=ExpandFileName(Path);
  if not Result.StartsWith(IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))),True) then
    raise EReadError.Create('Fixture path outside owned runtime');
end;

var Request,Output:TJSONObject; Info:TCollectionInfo; Capture:TCollectionTransferCatalogue;
  Plan:TCollectionTransferPlan; Rows,Files:TJSONArray; Stop,ChangedInScan:Boolean; Limit,Seen:Integer;
  Prepared:TObjectList<TTransferPreparedCopy>; Destinations:TDictionary<string,string>; NativeReadCount:Integer;
begin
  SetTextCodePage(System.Output,CP_UTF8);
  try
    RequireIsolatedRegression;
    DMUser:=TDMUser.Create(nil);
    try
    if ParamCount<>2 then raise EArgumentException.Create('Expected request and result');
    Request:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Owned(ParamStr(1)),TEncoding.UTF8)) as TJSONObject;
    if Request=nil then raise EReadError.Create('Invalid request');
    Capture:=nil; Plan:=nil; Output:=nil; Prepared:=nil; Destinations:=nil;
    try
      Info.Clear; Info.ID:=7; Info.CollectionType:=CT_EXTERNAL_LOCAL_FB;
      Info.DBFileName:=Owned(Request.GetValue<string>('catalogue')); Info.RootFolder:=Owned(Request.GetValue<string>('root'));
      Stop:=False; ChangedInScan:=False; Seen:=0; Limit:=Request.GetValue<Integer>('limit_bindings',256);
      Capture:=TCollectionTransferCatalogue.Create(Info,Owned(Request.GetValue<string>('personal')),
        Owned(Request.GetValue<string>('work')),
        function:Boolean begin Result:=Stop; end,
        procedure(Done:Int64)
        begin
          if Request.GetValue<Boolean>('cancel',False) then Stop:=True;
          if (Done>=4096) and not ChangedInScan and Request.GetValue<Boolean>('personal_during_scan',False) then
          begin
            var DB:=TSQLiteDatabase.Create(Owned(Request.GetValue<string>('personal')));
            try DB.ExecSQL('UPDATE Books SET Rate=4 WHERE DatabaseID=7'); finally DB.Free; end;
            ChangedInScan:=True;
          end;
        end);
      var Change:=Request.GetValue<string>('change','');
      if (Change='catalogue') or (Change='personal') or (Change='registration') then
      begin
        var Database:=Info.DBFileName;
        if Change<>'catalogue' then Database:=Owned(Request.GetValue<string>('personal'));
        var DB:=TSQLiteDatabase.Create(Database);
        try
          if Change='catalogue' then DB.ExecSQL('UPDATE Books SET LibID=LibID||''changed'' WHERE BookID=1')
          else if Change='personal' then DB.ExecSQL('UPDATE Books SET Rate=4 WHERE DatabaseID=7')
          else DB.ExecSQL('UPDATE Bases SET RootFolder=RootFolder||''changed'' WHERE DatabaseID=7');
        finally DB.Free; end;
      end
      else if (Change='arrived') or (Change='payload') then
        TFile.WriteAllText(Owned(Request.GetValue<string>('change_path')),'controlled fixture mutation',TEncoding.UTF8);
      Capture.CheckUnchanged;
      Output:=TJSONObject.Create; Rows:=TJSONArray.Create; Output.AddPair('bindings',Rows);
      Files:=TJSONArray.Create; Output.AddPair('files',Files);
      Capture.ForEachBinding(
        procedure(const Binding:TTransferCatalogueBinding)
        begin
          Inc(Seen); if Seen>Limit then Exit;
          var Row:=Binding.Locator.AsJSON('');
          Row.AddPair('binding',TJSONNumber.Create(Binding.ID)); Row.AddPair('source',Binding.Source);
          Row.AddPair('canonical',Binding.CanonicalSource); Row.AddPair('root_id',Binding.RootID);
          Row.AddPair('state',TJSONNumber.Create(Ord(Binding.State))); Row.AddPair('reason',Binding.Reason);
          Rows.AddElement(Row);
        end);
      if Request.GetValue<Boolean>('plan',True) then
      begin
        Plan:=Capture.BuildFilePlan(Owned(Request.GetValue<string>('destination')),
          Owned(Request.GetValue<string>('work')),StringToGUID('{5216C75E-1013-42D3-A12A-C287600B401F}'));
        if Request.GetValue<Boolean>('prepare_copies',False) then
        begin
          if Plan.FileCount>8 then raise EReadError.Create('Native copy fixture is limited to eight private files');
          Prepared:=TObjectList<TTransferPreparedCopy>.Create;
          Destinations:=TDictionary<string,string>.Create;
        end;
        Plan.CheckUnchanged;
        Plan.ForEachFile(
          procedure(const Entry:TCollectionTransferFile)
          begin
            var Row:=TJSONObject.Create; Row.AddPair('source',Entry.Source); Row.AddPair('destination',Entry.Destination);
            Row.AddPair('keep',TJSONBool.Create(Entry.KeepInPlace)); Row.AddPair('images',TJSONBool.Create(Entry.ExternalImages));
            Files.AddElement(Row);
            if Prepared<>nil then
            begin
              var Job:=TCollectionTransferCopy.CreateNew(Owned(Request.GetValue<string>('work')),
                Owned(Request.GetValue<string>('destination')),Entry);
              try Prepared.Add(Job.Prepare); finally Job.Free; end;
              Destinations.Add(Entry.Source,Entry.Destination);
            end;
          end);
        if Request.GetValue<string>('change_after_copy','')<>'' then
        begin
          var ChangedPath:=Owned(Request.GetValue<string>('change_after_copy'));
          ForceDirectories(ExtractFilePath(ChangedPath));
          TFile.WriteAllText(ChangedPath,'new private sidecar',TEncoding.UTF8);
        end;
        if Prepared=nil then Plan.CheckUnchanged else Plan.CheckInputsUnchanged;
        Output.AddPair('copy_bytes',TJSONNumber.Create(Plan.CopyBytes));
        if Prepared<>nil then
        begin
          NativeReadCount:=0;
          Capture.ForEachBinding(
            procedure(const Binding:TTransferCatalogueBinding)
            var BeforeBook,AfterBook:TBookRecord; Target,BeforeHash,AfterHash:string; Stream:TStream;
            begin
              if Binding.State<>tbsAvailable then Exit;
              BeforeBook:=Default(TBookRecord); BeforeBook.CollectionRoot:=Info.GetRootPath;
              if Binding.Locator.Root<>'' then BeforeBook.CollectionRoot:=IncludeTrailingPathDelimiter(Binding.Locator.Root);
              BeforeBook.LibID:=Binding.Locator.LibID; BeforeBook.Folder:=Binding.Locator.Folder;
              BeforeBook.FileName:=Binding.Locator.FileName; BeforeBook.FileExt:=Binding.Locator.Extension;
              BeforeBook.InsideNo:=Binding.Locator.InsideNo; AfterBook:=BeforeBook;
              Target:=Destinations[Binding.CanonicalSource];
              case BeforeBook.GetBookFormat of
                bfFb2Archive,bfRawArchive: AfterBook.Folder:=Target;
                bfFbd: begin AfterBook.Folder:=ExtractFilePath(Target); AfterBook.FileName:=ExtractFileName(Target); end;
              else
                AfterBook.Folder:=ExtractFilePath(Target); AfterBook.FileName:=ExtractFileName(Target);
                if AfterBook.FileExt<>'' then
                  Delete(AfterBook.FileName,Length(AfterBook.FileName)-Length(AfterBook.FileExt)+1,Length(AfterBook.FileExt));
              end;
              Stream:=BeforeBook.GetBookStream(True,False);
              try if Stream=nil then raise EReadError.Create('Source book stream missing'); BeforeHash:=THashSHA2.GetHashString(Stream);
              finally Stream.Free; end;
              Stream:=AfterBook.GetBookStream(True,False);
              try if Stream=nil then raise EReadError.Create('Copied book stream missing'); AfterHash:=THashSHA2.GetHashString(Stream);
              finally Stream.Free; end;
              if BeforeHash<>AfterHash then raise EReadError.Create('Native book payload changed after copying');
              Inc(NativeReadCount);
            end);
          Output.AddPair('native_read_pairs',TJSONNumber.Create(NativeReadCount));
          Output.AddPair('prepared_files',TJSONNumber.Create(Prepared.Count));
        end;
      end;
      Output.AddPair('status','PASS'); Output.AddPair('rows',TJSONNumber.Create(Capture.RowCount));
      Output.AddPair('available',TJSONNumber.Create(Capture.Count(tbsAvailable)));
      Output.AddPair('missing',TJSONNumber.Create(Capture.Count(tbsMissing)));
      Output.AddPair('metadata_only',TJSONNumber.Create(Capture.Count(tbsMetadataOnly)));
      Output.AddPair('candidates',TJSONNumber.Create(Capture.CandidateCount));
      Output.AddPair('sources_json',Capture.SourcesJSON);
      TFile.WriteAllText(Owned(ParamStr(2)),Output.ToJSON,TEncoding.UTF8);
      Writeln('PASS native catalogue transfer capture');
    finally Destinations.Free; Prepared.Free; Output.Free; Plan.Free; Capture.Free; Request.Free; end;
    finally FreeAndNil(DMUser); end;
  except on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end; end;
end.
