unit unit_CollectionTransferHistory;

interface

uses SQLiteWrap, unit_CollectionTransferJournal;

// Runs inside the caller's locator transaction. Original-key history remains
// available until source cleanup. Only verified prepared files grant new keys.
function RebindTransferHistory(DB,Review:TSQLiteDatabase; Prepared:TPreparedTransferGroup):Int64;

implementation

uses System.SysUtils, System.Classes, System.JSON, System.Hash, System.Generics.Collections,
  unit_BookCompressionImages, unit_BookCompressionReceipt, unit_CollectionTransferPlan;

function Ident(const Value:string):string;
begin Result:='"'+StringReplace(Value,'"','""',[rfReplaceAll])+'"'; end;

function HasTable(DB:TSQLiteDatabase; const Name:string):Boolean;
begin Result:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[Name])<>0; end;

function CopyRows(DB:TSQLiteDatabase; const Table,OldKey,NewKey,Where:string;
  Overrides:TDictionary<string,string>):Int64;
var Names,Values,Keys,Same:TStringList; Q:TSQLiteQuery;
begin
  Result:=0; if not HasTable(DB,Table) then Exit;
  Names:=TStringList.Create; Values:=TStringList.Create; Keys:=TStringList.Create; Same:=TStringList.Create;
  try
    Names.Delimiter:=','; Values.Delimiter:=',';
    Q:=DB.NewQuery('PRAGMA table_info('+Ident(Table)+')');
    try
      Q.Open;
      while not Q.Eof do
      begin
        var Name:=Q.FieldAsString(1); var Column:=Ident(Name); var Expression:='s.'+Column;
        if SameText(Name,'FileKey') then Expression:=QuotedStr(NewKey)
        else Overrides.TryGetValue(UpperCase(Name),Expression);
        // TryGetValue initializes its out argument on a miss.
        if Expression='' then Expression:='s.'+Column;
        Names.Add(Column); Values.Add(Expression); Same.Add('d.'+Column+' IS '+Expression);
        if Q.FieldAsInt(5)>0 then Keys.Add('d.'+Column+' IS '+Expression);
        Q.Next;
      end;
    finally Q.Free; end;
    if (Names.Count=0) or (Keys.Count=0) or (Names.IndexOf('"FileKey"')<0) then
      raise EReadError.Create('Неизвестная схема истории сжатия: '+Table);
    var Condition:='s."FileKey"='+QuotedStr(OldKey);
    if Where<>'' then Condition:=Condition+' AND ('+Where+')';
    var Join:=String.Join(' AND ',Keys.ToStringArray); var Equal:=String.Join(' AND ',Same.ToStringArray);
    if DB.QuerySingleInt('SELECT count(*) FROM '+Ident(Table)+' s JOIN '+Ident(Table)+' d ON '+Join+
      ' WHERE '+Condition+' AND NOT ('+Equal+')')<>0 then
      raise EReadError.Create('История сжатия в назначении противоречит проверенной копии: '+Table);
    DB.ExecSQL('INSERT OR IGNORE INTO '+Ident(Table)+'('+String.Join(',',Names.ToStringArray)+') SELECT '+
      String.Join(',',Values.ToStringArray)+' FROM '+Ident(Table)+' s WHERE '+Condition);
    Result:=DB.LastChangedRows;
  finally Same.Free; Keys.Free; Values.Free; Names.Free; end;
end;

function Images(Prepared:TPreparedTransferGroup; Index:Integer; out SourceData,TargetData:TJSONArray;
  out OldStamp,NewStamp,NewSnapshot:string):TDictionary<string,string>;
begin
  SourceData:=nil; TargetData:=nil; Result:=TDictionary<string,string>.Create;
  try
    SourceData:=CaptureCompressionImageSources(Prepared.CopyAt(Index).Source);
    TargetData:=CaptureCompressionImageSources(Prepared.CopyAt(Index).Destination);
    if SourceData.Count<>TargetData.Count then raise EReadError.Create('Копия изменила набор внешних изображений.');
    OldStamp:=''; NewStamp:=''; NewSnapshot:='';
    if SourceData.Count=0 then Exit;
    OldStamp:=THashSHA2.GetHashString(SourceData.ToJSON); NewStamp:=THashSHA2.GetHashString(TargetData.ToJSON);
    for var I:=0 to SourceData.Count-1 do
    begin
      var Before:=SourceData.Items[I] as TJSONObject; var After:=TargetData.Items[I] as TJSONObject;
      if Before.GetValue<string>('kind')<>After.GetValue<string>('kind') then raise EReadError.Create('Изменился вид внешних изображений.');
      var Source:=Before.GetValue<string>('path'); var Destination:=After.GetValue<string>('path');
      if (Source='') and (Destination='') then Continue;
      var Found:=False;
      for var J:=0 to Prepared.Count-1 do
        if SameFileName(Source,Prepared.CopyAt(J).Source) and SameFileName(Destination,Prepared.CopyAt(J).Destination) then
        begin
          Found:=True; Result.AddOrSetValue(Before.GetValue<string>('source_identity'),Prepared.CopyAt(J).SHA256);
          After.AddPair('source_sha256',Prepared.CopyAt(J).SHA256); After.AddPair('result_sha256',Prepared.CopyAt(J).SHA256);
          Break;
        end;
      if not Found then raise EReadError.Create('Для внешних изображений нет проверенной пары исходник/копия.');
    end;
    NewSnapshot:=TargetData.ToJSON;
  except
    Result.Free; SourceData.Free; SourceData:=nil; TargetData.Free; TargetData:=nil; raise;
  end;
end;

function ValidImageSet(const Text,Stamp:string; Current:TJSONArray; Verified:TDictionary<string,string>):Boolean;
var Data:TJSONValue; Identity:TJSONArray;
begin
  Result:=False; Data:=TJSONObject.ParseJSONValue(Text); Identity:=TJSONArray.Create;
  try
    if not (Data is TJSONArray) or (TJSONArray(Data).Count<>Current.Count) then Exit;
    for var I:=0 to Current.Count-1 do
    begin
      if not (TJSONArray(Data).Items[I] is TJSONObject) then Exit;
      var Item:=TJSONArray(Data).Items[I] as TJSONObject; var Actual:=Current.Items[I] as TJSONObject;
      var Kind:=Item.GetValue<string>('kind',''); var Path:=Item.GetValue<string>('path','');
      var State:=Item.GetValue<string>('source_identity','');
      if (Kind<>Actual.GetValue<string>('kind')) or (State<>Actual.GetValue<string>('source_identity')) or
        ((Path='')<>(Actual.GetValue<string>('path')='')) then Exit;
      if Path<>'' then
      begin
        var Hash:string;
        if not Verified.TryGetValue(State,Hash) or (CompressionFileKey(Path)<>Copy(State,1,25)) or
          not SameText(Item.GetValue<string>('source_sha256',''),Hash) or
          not SameText(Item.GetValue<string>('result_sha256',''),Hash) then Exit;
      end;
      var Row:=TJSONObject.Create; Identity.AddElement(Row); Row.AddPair('kind',Kind); Row.AddPair('path',Path); Row.AddPair('source_identity',State);
    end;
    Result:=SameText(THashSHA2.GetHashString(Identity.ToJSON),Stamp);
  finally Identity.Free; Data.Free; end;
end;

function RebindTransferHistory(DB,Review:TSQLiteDatabase; Prepared:TPreparedTransferGroup):Int64;
var Overrides,Verified:TDictionary<string,string>; SourceData,TargetData:TJSONArray;
  Stamps:TList<string>; Q:TSQLiteQuery; OldKey,NewKey,OldIdentity,NewIdentity,SHA,OldStamp,NewStamp,Snapshot:string;
begin
  Result:=0;
  if (DB=nil) or not DB.InTransaction or (Prepared=nil) then raise EArgumentException.Create('История переносится в транзакции расположений книг.');
  if (Prepared.Count=0) or (Review.QuerySingleInt('SELECT count(*) FROM Files WHERE GroupID=?',[Prepared.ID])<>Prepared.Count) then
    raise EReadError.Create('История требует полной проверенной группы файлов.');
  if not (HasTable(DB,'HomeLibreBookCompression') or HasTable(DB,'HomeLibreCompressionChecks') or
    HasTable(DB,'HomeLibreRestoredBookSizes') or HasTable(DB,'HomeLibreCompressionOutcomes')) then Exit;
  Overrides:=TDictionary<string,string>.Create;
  try
    for var I:=0 to Prepared.Count-1 do
    begin
      var FileID:=Prepared.FileID(I); var CopyFile:=Prepared.CopyAt(I);
      Q:=Review.NewQuery('SELECT Source,Destination,Identity,GroupID FROM Files WHERE ID=?',[FileID]);
      try
        Q.Open;
        if Q.Eof or (Q.FieldAsString(0)<>CopyFile.Source) or (Q.FieldAsString(1)<>CopyFile.Destination) or
          (Q.FieldAsInt(3)<>Prepared.ID) then raise EReadError.Create('Копия не относится к группе переноса истории.');
        OldIdentity:=Q.FieldAsString(2);
      finally Q.Free; end;
      OldKey:=UpperCase(Copy(OldIdentity,1,25)); NewIdentity:=CopyFile.Identity; NewKey:=UpperCase(Copy(NewIdentity,1,25)); SHA:=LowerCase(CopyFile.SHA256);
      if OldKey=NewKey then Continue;
      Overrides.Clear;
      Inc(Result,CopyRows(DB,'HomeLibreBookCompression',OldKey,NewKey,'',Overrides));
      Inc(Result,CopyRows(DB,'HomeLibreCompressionOutcomes',OldKey,NewKey,'',Overrides));
      Verified:=Images(Prepared,I,SourceData,TargetData,OldStamp,NewStamp,Snapshot); Stamps:=TList<string>.Create;
      try
        if SourceData.Count=0 then Stamps.Add('')
        else if Verified.Count=0 then Stamps.Add(OldStamp); // Explicitly empty image set.
        if HasTable(DB,'HomeLibreCompressionImageSets') then
        begin
          Q:=DB.NewQuery('SELECT Stamp,SourcesJSON FROM HomeLibreCompressionImageSets WHERE FileKey=?',[OldKey]);
          try
            Q.Open;
            while not Q.Eof do
            begin
              var Stamp:=Q.FieldAsString(0);
              if ValidImageSet(Q.FieldAsString(1),Stamp,SourceData,Verified) then
              begin
                if not Stamps.Contains(Stamp) then Stamps.Add(Stamp);
                Overrides.Clear; Overrides.Add('STAMP',QuotedStr(NewStamp)); Overrides.Add('SOURCESJSON',QuotedStr(Snapshot));
                Inc(Result,CopyRows(DB,'HomeLibreCompressionImageSets',OldKey,NewKey,'s.Stamp='+QuotedStr(Stamp),Overrides));
              end;
              Q.Next;
            end;
          finally Q.Free; end;
        end;
        // Restored sizes already used an identity/stamp witness in the source.
        // Preserve that strength, including older rows without image hashes.
        Overrides.Clear; Overrides.Add('SOURCEIDENTITY',QuotedStr(NewIdentity)); Overrides.Add('IMAGESTAMP',QuotedStr(NewStamp));
        var SourceMatch:='substr(s.SourceIdentity,1,43)='+QuotedStr(Copy(OldIdentity,1,43))+' AND lower(s.SourceSHA256)='+QuotedStr(SHA);
        Inc(Result,CopyRows(DB,'HomeLibreRestoredBookSizes',OldKey,NewKey,SourceMatch+' AND s.ImageStamp='+QuotedStr(OldStamp),Overrides));
        for var Stamp in Stamps do
          if Stamp<>OldStamp then
            Inc(Result,CopyRows(DB,'HomeLibreRestoredBookSizes',OldKey,NewKey,SourceMatch+' AND s.ImageStamp='+QuotedStr(Stamp),Overrides));
        if HasTable(DB,'HomeLibreCompressionChecks') and HasTable(DB,'HomeLibreCompressionDependencies') then
          for var Stamp in Stamps do
          begin
            var Match:='d.FileKey=s.FileKey AND d.Member=s.Member AND d.Profile=s.Profile AND '+
              'd.Grayscale=s.Grayscale AND d.EngineSHA256=s.EngineSHA256';
            Overrides.Clear; Overrides.Add('SOURCEIDENTITY',QuotedStr(NewIdentity));
            Inc(Result,CopyRows(DB,'HomeLibreCompressionChecks',OldKey,NewKey,
              SourceMatch+
              ' AND EXISTS(SELECT 1 FROM HomeLibreCompressionDependencies d WHERE '+Match+' AND d.Stamp='+QuotedStr(Stamp)+')',Overrides));
            Match:='c.FileKey=s.FileKey AND c.Member=s.Member AND c.Profile=s.Profile AND '+
              'c.Grayscale=s.Grayscale AND c.EngineSHA256=s.EngineSHA256';
            Overrides.Clear; Overrides.Add('STAMP',QuotedStr(NewStamp));
            Inc(Result,CopyRows(DB,'HomeLibreCompressionDependencies',OldKey,NewKey,
              's.Stamp='+QuotedStr(Stamp)+' AND EXISTS(SELECT 1 FROM HomeLibreCompressionChecks c WHERE '+Match+
              ' AND substr(c.SourceIdentity,1,43)='+QuotedStr(Copy(OldIdentity,1,43))+' AND lower(c.SourceSHA256)='+QuotedStr(SHA)+')',Overrides));
          end;
      finally Stamps.Free; Verified.Free; TargetData.Free; SourceData.Free; end;
    end;
  finally Overrides.Free; end;
end;

end.
