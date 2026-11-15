program CollectionTransferPlanTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  NativeRegressionGuard, unit_CollectionTransferPlan;

function OwnedPath(const Value: string): string;
begin
  Result:=ExpandFileName(Value);
  if not Result.StartsWith(IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))),True) then
    raise EReadError.Create('Transfer fixture path is outside its owned runtime');
end;

var Data,Output,Item:TJSONObject; Plan:TCollectionTransferPlan;
    Roots:TArray<TCollectionTransferRoot>; Inputs,Files,Mappings:TJSONArray;
    Visited,CancelAfter,Repeats:Integer;
begin
  try
    RequireIsolatedRegression;
    if ParamCount<>2 then raise EArgumentException.Create('Expected request and output');
    Data:=TJSONObject.ParseJSONValue(TFile.ReadAllText(OwnedPath(ParamStr(1)),TEncoding.UTF8)) as TJSONObject;
    if Data=nil then raise EReadError.Create('Invalid transfer fixture request');
    try
      var RootList:=Data.GetValue<TJSONArray>('roots'); SetLength(Roots,RootList.Count);
      for var I:=0 to RootList.Count-1 do
      begin
        Item:=RootList.Items[I] as TJSONObject;
        Roots[I].ID:=Item.GetValue<string>('id'); Roots[I].Path:=OwnedPath(Item.GetValue<string>('path'));
      end;
      Inputs:=Data.GetValue<TJSONArray>('inputs'); Visited:=0;
      CancelAfter:=Data.GetValue<Integer>('cancel_after',-1);
      Repeats:=Data.GetValue<Integer>('repeats',1);
      if (Repeats<1) or (Repeats>100000) then raise EArgumentException.Create('Invalid fixture repeat count');
      Plan:=TCollectionTransferPlan.Create(OwnedPath(Data.GetValue<string>('destination')),
        OwnedPath(Data.GetValue<string>('work')),Roots,
        procedure(const Visit:TCollectionTransferVisitor)
        var Input:TCollectionTransferInput;
        begin
          for var RepeatIndex:=1 to Repeats do
            for var Value in Inputs do
            begin
              var Entry:=Value as TJSONObject;
              Input.RootID:=Entry.GetValue<string>('root');
              Input.FileName:=OwnedPath(Entry.GetValue<string>('file'));
              Visit(Input); Inc(Visited);
            end;
        end,
        StringToGUID(Data.GetValue<string>('operation')),
        function:Boolean
        begin Result:=(CancelAfter>=0) and (Visited>=CancelAfter); end);
      try
        var Mutation:=Data.GetValue<string>('mutate_source','');
        if Mutation<>'' then TFile.AppendAllText(OwnedPath(Mutation),'changed-by-owned-fixture',TEncoding.UTF8);
        var Appeared:=Data.GetValue<string>('create_source','');
        if Appeared<>'' then
        begin
          Appeared:=OwnedPath(Appeared); ForceDirectories(ExtractFileDir(Appeared));
          TFile.WriteAllText(Appeared,'newly appeared fixture sidecar',TEncoding.UTF8);
        end;
        if Data.GetValue<Boolean>('occupy_destination',False) then
        begin
          var Created:=False;
          Plan.ForEachFile(
            procedure(const Entry:TCollectionTransferFile)
            begin
              if Entry.KeepInPlace or Created then Exit;
              var Path:=OwnedPath(Entry.Destination); ForceDirectories(ExtractFileDir(Path));
              TFile.WriteAllText(Path,'foreign fixture file after preview',TEncoding.UTF8); Created:=True;
            end);
        end;
        Plan.CheckUnchanged;
        Output:=TJSONObject.Create;
        try
          Output.AddPair('files',TJSONNumber.Create(Plan.FileCount));
          Output.AddPair('copy_files',TJSONNumber.Create(Plan.CopyFileCount));
          Output.AddPair('copy_bytes',TJSONNumber.Create(Plan.CopyBytes));
          Output.AddPair('examined',TJSONNumber.Create(Plan.Examined));
          Output.AddPair('content_root',Plan.ContentRoot);
          Mappings:=TJSONArray.Create; Output.AddPair('roots',Mappings);
          for var Root in Roots do
          begin
            Item:=TJSONObject.Create; Mappings.AddElement(Item);
            Item.AddPair('id',Root.ID); Item.AddPair('destination',Plan.RootDestination(Root.ID));
          end;
          Files:=TJSONArray.Create; Output.AddPair('entries',Files);
          Plan.ForEachFile(
            procedure(const Entry:TCollectionTransferFile)
            begin
              var Row:=TJSONObject.Create; Files.AddElement(Row);
              Row.AddPair('source',Entry.Source); Row.AddPair('destination',Entry.Destination);
              Row.AddPair('bytes',TJSONNumber.Create(Entry.Bytes));
              Row.AddPair('keep',TJSONBool.Create(Entry.KeepInPlace));
              Row.AddPair('external_images',TJSONBool.Create(Entry.ExternalImages));
              Row.AddPair('identity',Entry.Identity);
            end);
          TFile.WriteAllText(OwnedPath(ParamStr(2)),Output.ToJSON,TEncoding.UTF8);
        finally Output.Free; end;
      finally Plan.Free; end;
    finally Data.Free; end;
    Writeln('PASS read-only collection transfer plan');
  except
    on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end;
  end;
end.
