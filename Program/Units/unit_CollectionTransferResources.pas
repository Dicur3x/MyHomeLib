unit unit_CollectionTransferResources;

interface

uses System.SysUtils, SQLiteWrap, unit_CollectionTransferJournal;

type TTransferResourceValidation=record
  SHA256:string;
  Files,ImageSets,Resources:Integer;
end;

// Prepared leases keep all verified streams immutable. Native discovery at the
// new owner path must select exactly the mapped cover/image archives.
function ValidateTransferResources(Review:TSQLiteDatabase; Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean> = nil):TTransferResourceValidation;

implementation

uses System.Classes, System.JSON, System.Hash, System.Generics.Collections,
  unit_CollectionTransferCopy, unit_CollectionTransferPlan;

function ValidateTransferResources(Review:TSQLiteDatabase; Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>):TTransferResourceValidation;
var Copies:TDictionary<Int64,TTransferPreparedCopy>; Paths:TDictionary<string,Int64>;
  Q:TSQLiteQuery; Proof:TJSONArray;
  procedure Stop;
  begin
    if Assigned(Cancelled) and Cancelled() then raise EAbort.Create('Проверка ресурсов остановлена. Исходники сохранены.');
  end;
  function JSONPaths(const Text:string):TJSONArray;
  begin
    var Value:=TJSONObject.ParseJSONValue(Text);
    if not (Value is TJSONArray) then begin Value.Free; raise EReadError.Create('Повреждён список внешних картинок.'); end;
    Result:=TJSONArray(Value);
    for var Item in Result do
      if not (Item is TJSONString) then begin Result.Free; raise EReadError.Create('Неверный адрес внешних картинок.'); end;
  end;
begin
  Result:=Default(TTransferResourceValidation);
  if (Review=nil) or (Prepared=nil) or (Prepared.Count=0) or
    (Review.QuerySingleInt('SELECT count(*) FROM Files WHERE GroupID=?',[Prepared.ID])<>Prepared.Count) then
    raise EArgumentException.Create('Для ресурсов нужна полная проверенная группа.');
  Copies:=TDictionary<Int64,TTransferPreparedCopy>.Create; Paths:=TDictionary<string,Int64>.Create;
  Proof:=TJSONArray.Create; Q:=nil;
  try
    for var I:=0 to Prepared.Count-1 do Copies.Add(Prepared.FileID(I),Prepared.CopyAt(I));
    Q:=Review.NewQuery('SELECT ID,Source,Destination,Identity FROM Files WHERE GroupID=? ORDER BY ID',[Prepared.ID]); Q.Open;
    while not Q.Eof do
    begin
      Stop; var Item:TTransferPreparedCopy;
      if not Copies.TryGetValue(Q.FieldAsInt(0),Item) or (Item.Source<>Q.FieldAsString(1)) or
        (Item.Destination<>Q.FieldAsString(2)) then raise EReadError.Create('В проверенной группе другой файл.');
      Item.CheckUnchanged(Q.FieldAsString(3),Cancelled);
      Paths.Add(Item.Source,Q.FieldAsInt(0));
      var Row:=TJSONArray.Create; Proof.AddElement(Row);
      Row.Add(Q.FieldAsInt(0)); Row.Add(Item.Source); Row.Add(Item.Destination); Row.Add(Q.FieldAsString(3));
      Row.Add(Item.Identity); Row.Add(Item.SHA256); Row.Add(Item.StreamsJSON);
      Inc(Result.Files); Q.Next;
    end;
    FreeAndNil(Q);
    Q:=Review.NewQuery('SELECT i.OwnerID,i.PathsJSON FROM ImageSets i JOIN Files f ON f.ID=i.OwnerID WHERE f.GroupID=? ORDER BY i.OwnerID',[Prepared.ID]); Q.Open;
    while not Q.Eof do
    begin
      Stop; var Owner:=Copies[Q.FieldAsInt(0)]; var Old:=JSONPaths(Q.FieldAsString(1));
      var Fresh:TJSONArray:=nil;
      try
        if TransferImageSourcesSnapshot(Owner.Source)<>Q.FieldAsString(1) then
          raise EReadError.Create('Исходный набор внешних картинок изменился.');
        Fresh:=JSONPaths(TransferImageSourcesSnapshot(Owner.Destination));
        if Fresh.Count<>Old.Count then raise EReadError.Create('Новый путь меняет набор внешних картинок.');
        var Row:=TJSONArray.Create; Proof.AddElement(Row); Row.Add(Q.FieldAsInt(0));
        Row.Add(Old.ToJSON); Row.Add(Fresh.ToJSON);
        for var I:=0 to Old.Count-1 do
        begin
          Stop;
          if Old.Items[I].Value='' then
          begin
            if Fresh.Items[I].Value<>'' then raise EReadError.Create('По новому пути найдены посторонние картинки.');
            Continue;
          end;
          var ID:Int64;
          if (Fresh.Items[I].Value='') or not Paths.TryGetValue(Old.Items[I].Value,ID) or
            (Review.QuerySingleInt('SELECT count(*) FROM Edges WHERE OwnerID=? AND FileID=?',[Q.FieldAsInt(0),ID])<>1) then
            raise EReadError.Create('В группе нет нужного архива внешних картинок.');
          var Picture:=Copies[ID]; var Canonical,Identity:string; var Bytes:Int64;
          TransferReadFileState(Fresh.Items[I].Value,Canonical,Identity,Bytes);
          if (Canonical<>Picture.Destination) or (Identity<>Picture.Identity) then
            raise EReadError.Create('Новый путь книги использует другой архив картинок.');
          Row.Add(ID); Row.Add(Identity); Row.Add(Picture.SHA256); Inc(Result.Resources);
        end;
        Inc(Result.ImageSets);
      finally Fresh.Free; Old.Free; end;
      Q.Next;
    end;
    Stop; Result.SHA256:=THashSHA2.GetHashString(Proof.ToJSON);
  finally Q.Free; Proof.Free; Paths.Free; Copies.Free; end;
end;

end.
