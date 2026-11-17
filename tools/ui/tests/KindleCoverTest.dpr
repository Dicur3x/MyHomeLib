program KindleCoverTest;
{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  NativeRegressionGuard, unit_KindleBookCover;

type
  TCoverInput=class(TFileStream)
    BytesRead:Int64;
    Forbidden:TJSONArray;
    function Read(var Buffer; Count:Longint):Longint; override;
  end;

function TCoverInput.Read(var Buffer; Count:Longint):Longint;
begin
  if Assigned(Forbidden) then
    for var Value in Forbidden do
    begin
      var Range:=Value as TJSONArray;
      if (Position<Range.Items[1].GetValue<Int64>) and
        (Position+Count>Range.Items[0].GetValue<Int64>) then
        raise Exception.Create('Cover reader touched a text record');
    end;
  Result:=inherited Read(Buffer,Count); Inc(BytesRead,Result);
end;

var Root,Folder,Status:string; Cases:TJSONArray; Results:TJSONArray; Output:TJSONObject;
  Stream:TCoverInput; Data,Expected:TBytes; Checks:Integer; Aborted:Boolean;
begin
  try
    RequireIsolatedRegression; Root:=ExtractFilePath(ParamStr(0)); Folder:=Root+'cover-fixtures\';
    Cases:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'kindle-cases.json',TEncoding.UTF8)) as TJSONArray;
    Results:=TJSONArray.Create;
    try
      for var Value in Cases do
      begin
        var Item:=Value as TJSONObject;
        Stream:=TCoverInput.Create(Folder+Item.GetValue<string>('name'),fmOpenRead or fmShareDenyWrite);
        try
          Item.TryGetValue<TJSONArray>('forbidden',Stream.Forbidden);
          Stream.Position:=3; Checks:=0; Aborted:=False; Data:=nil; Status:='';
          try
            Data:=ReadKindleBookCover(Stream,Status,function:Boolean
              begin
                Inc(Checks); var Limit:=Item.GetValue<Int64>('cancel_bytes',0);
                Result:=Item.GetValue<Boolean>('cancel',False) and
                  (((Limit=0) and (Checks>=3)) or ((Limit>0) and (Stream.BytesRead>=Limit)));
              end);
          except on E:EAbort do Aborted:=True; end;
          if Stream.Position<>3 then raise Exception.Create('Caller position changed');
          if Aborted<>Item.GetValue<Boolean>('cancel',False) then raise Exception.Create('Wrong cancellation result');
          if not Aborted then
          begin
            if Item.GetValue<Boolean>('cover',False) then
            begin
              Expected:=TFile.ReadAllBytes(Folder+Item.GetValue<string>('expected'));
              if (Length(Data)<>Length(Expected)) or not CompareMem(Pointer(Data),Pointer(Expected),Length(Data)) then
                raise Exception.Create('Wrong Kindle cover: '+Item.GetValue<string>('name')+' '+Status);
            end
            else if (Length(Data)<>0) or (Status='') then raise Exception.Create('Missing unavailable-cover explanation');
            var Substring:=Item.GetValue<string>('status','');
            if (Substring<>'') and not Status.Contains(Substring) then raise Exception.Create('Wrong cover status');
          end;
          if Stream.BytesRead>Item.GetValue<Int64>('max_read',18*1024*1024) then
            raise Exception.Create('Cover reader read too much');
          var Row:=TJSONObject.Create; Results.AddElement(Row);
          Row.AddPair('name',Item.GetValue<string>('name')); Row.AddPair('read_bytes',TJSONNumber.Create(Stream.BytesRead));
          Row.AddPair('status',Status); Row.AddPair('cover_bytes',TJSONNumber.Create(Length(Data)));
          Row.AddPair('canceled',TJSONBool.Create(Aborted));
          Writeln('PASS Kindle cover ',Item.GetValue<string>('name')); Flush(System.Output);
        finally Stream.Free; end;
      end;
      Output:=TJSONObject.Create;
      try
        Output.AddPair('status','PASS'); Output.AddPair('cases',Results); Results:=nil;
        TFile.WriteAllText(Root+'kindle-result.json',Output.ToJSON,TEncoding.UTF8);
      finally Output.Free; end;
    finally Results.Free; Cases.Free; end;
  except on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end; end;
end.
