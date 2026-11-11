{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  System.Generics.Collections, Winapi.Windows, unit_BookCompressionPlan,
  unit_MHLArchiveHelpers
{$IFDEF HL_APPLICATION_PATHS}
  , unit_CollectionPacking, unit_Globals, unit_Settings, dm_user
{$ENDIF}
  ;

function Text(Obj:TJSONObject; const Name:string):string;
begin Result:=Obj.GetValue<string>(Name,''); end;

function Locator(Obj:TJSONObject):TCompressionLocator;
begin
  Result:=Default(TCompressionLocator);
  Result.Kind:=Obj.GetValue<Integer>('kind',0);
  Result.BookID:=Obj.GetValue<Integer>('id');
  Result.LibID:=Text(Obj,'lib_id'); Result.Folder:=Text(Obj,'folder');
  Result.FileName:=Text(Obj,'file_name'); Result.Extension:=Text(Obj,'ext');
  Result.InsideNo:=Obj.GetValue<Integer>('inside_no',0);
  Result.Root:=Text(Obj,'root'); Result.SourceKey:=Text(Obj,'source_key');
end;

var Data, Entry, Output, Request:TJSONObject; Selected:TArray<TCompressionLocator>;
    Options:TCompressionPlanOptions; Plan:TBookCompressionPlan;
    Archives:TObjectDictionary<string,TMHLZip>; Files:TJSONArray;
    Mode:string; Examined:Int64; Cancel:Boolean;
{$IFDEF HL_APPLICATION_PATHS}
    Info:TCollectionInfo; Books:TArray<TBookRecord>;
{$ENDIF}
begin
  try
    Data:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ParamStr(1),TEncoding.UTF8)) as TJSONObject;
    if Data=nil then raise EReadError.Create('Invalid fixture request');
    try
      Entry:=Data.GetValue<TJSONObject>('options');
      Options:=Default(TCompressionPlanOptions);
      Options.CollectionID:=Entry.GetValue<Integer>('collection_id');
      Options.Catalogue:=Text(Entry,'catalogue'); Options.Personal:=Text(Entry,'personal');
      Options.CollectionRoot:=Text(Entry,'root'); Options.BaseRoot:=Text(Entry,'base_root');
      Options.BaseCatalogue:=Text(Entry,'base_catalogue');
      var Rows:=Data.GetValue<TJSONArray>('selected');
      SetLength(Selected,Rows.Count);
      for var I:=0 to Rows.Count-1 do Selected[I]:=Locator(Rows.Items[I] as TJSONObject);
      Mode:=Text(Data,'mode'); Examined:=0; Cancel:=Mode='cancel';
{$IFDEF HL_APPLICATION_PATHS}
      ConfigureMHLHostProfile(TPath.GetDirectoryName(ParamStr(1)),'selection-test.ini','selection-test.dbs2');
      DMUser:=TDMUser.Create(nil);
{$ENDIF}
      Archives:=TObjectDictionary<string,TMHLZip>.Create([doOwnsValues]);
      try
{$IFDEF HL_APPLICATION_PATHS}
        Info:=Default(TCollectionInfo); Info.ID:=Options.CollectionID;
        Info.RootFolder:=Options.BaseRoot; Info.DBFileName:=Options.Catalogue;
        SetLength(Books,Length(Selected));
        for var I:=0 to High(Selected) do
        begin
          Books[I]:=Default(TBookRecord);
          Books[I].BookKey:=CreateBookKey(Selected[I].BookID,Data.GetValue<Integer>('selected_collection',Options.CollectionID));
          Books[I].LibID:=Selected[I].LibID; Books[I].Folder:=Selected[I].Folder;
          Books[I].FileName:=Selected[I].FileName; Books[I].FileExt:=Selected[I].Extension;
          Books[I].InsideNo:=Selected[I].InsideNo;
          Books[I].CollectionRoot:=Data.GetValue<string>('selected_root',Options.CollectionRoot);
        end;
        Plan:=BuildSelectedCompressionPlan(Info,Options.Personal,Books,
          function:Boolean begin Result:=Cancel; end,
          procedure(Done:Int64)
          begin Examined:=Done; if Mode='cancel-scan' then Cancel:=True; end);
{$ELSE}
        Plan:=TBookCompressionPlan.Create(Options,Selected,
          function(const Row:TCompressionLocator):string
          var Root, Container:string;
          begin
            Root:=Options.CollectionRoot; if Row.Root<>'' then Root:=Row.Root;
            Container:=TPath.Combine(Root,Row.Folder);
            if Row.Folder.EndsWith('\') or Row.Folder.EndsWith('/') then
              Result:=TPath.Combine(Container,Row.FileName)+Row.Extension
            else Result:=Container;
          end,
          function(const Source:string; const Row:TCompressionLocator):string
          var Archive:TMHLZip; Key:string;
          begin
            Result:='';
            if Row.Folder.EndsWith('\') or Row.Folder.EndsWith('/') then Exit;
            Key:=LowerCase(ExpandFileName(Source));
            if not Archives.TryGetValue(Key,Archive) then
            begin Archive:=TMHLZip.Create(Source,True); Archives.Add(Key,Archive); end;
            Result:=Archive.ResolveBookName(Row.FileName+Row.Extension,Row.InsideNo,True);
          end,
          function:Boolean begin Result:=Cancel; end,
          procedure(Done:Int64)
          begin Examined:=Done; if Mode='cancel-scan' then Cancel:=True; end);
{$ENDIF}
        try
          Archives.Clear;
          if Mode='change-source' then
          begin
            var Stream:=TFileStream.Create(Plan.Files[0].Source,fmOpenWrite or fmShareDenyWrite);
            try Stream.Size:=Stream.Size+1; finally Stream.Free; end;
          end;
          Output:=TJSONObject.Create; Files:=TJSONArray.Create;
          try
            Output.AddPair('files',Files); Output.AddPair('examined',TJSONNumber.Create(Examined));
            for var FilePlan in Plan.Files do
            begin
              Request:=FilePlan.CreateRequest(Text(Data,'workspace'),Text(Data,'report'),
                Text(Data,'seven_zip'),Text(Data,'tools_root'),Text(Data,'profile'),
                Data.GetValue<Boolean>('grayscale',False));
              Files.AddElement(Request);
            end;
            TFile.WriteAllText(ParamStr(2),Output.ToJSON,TEncoding.UTF8);
          finally Output.Free; end;
        finally Plan.Free; end;
      finally
        Archives.Free;
{$IFDEF HL_APPLICATION_PATHS}
        FreeAndNil(DMUser);
{$ENDIF}
      end;
    finally Data.Free; end;
  except
    on E:Exception do
    begin
      var Bytes:=TEncoding.UTF8.GetBytes(E.ClassName+': '+E.Message+sLineBreak);
      var Written:DWORD;
      WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),Bytes[0],Length(Bytes),Written,nil);
      Halt(1);
    end;
  end;
end.
