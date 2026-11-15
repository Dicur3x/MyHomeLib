function FLibraryRecoveryStrings(const Values:TDictionary<string,string>):TJSONArray;
begin
  Result:=TJSONArray.Create;
  for var Pair in Values do
  begin var Item:=TJSONObject.Create; Result.AddElement(Item);
    Item.AddPair('key',Pair.Key); Item.AddPair('value',Pair.Value); end;
end;

function FLibraryRecoverySizes(const Values:TDictionary<string,Int64>):TJSONArray;
begin
  Result:=TJSONArray.Create;
  for var Pair in Values do
  begin var Item:=TJSONObject.Create; Result.AddElement(Item);
    Item.AddPair('key',Pair.Key); Item.AddPair('value',TJSONNumber.Create(Pair.Value)); end;
end;

procedure RestoreFLibraryRecoveryStrings(Values:TDictionary<string,string>; Data:TJSONArray);
begin
  for var Item in Data do Values.Add(Item.GetValue<string>('key'),Item.GetValue<string>('value'));
end;

procedure TestReviewedFLibraryRecoveryStartup;
var Proof,Manifest:TJSONObject; Collection:IBookCollection;
begin
  RequireIsolatedRegression;
  Proof:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'library-update-recovery-state.json',TEncoding.UTF8)) as TJSONObject;
  Manifest:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'packing-flibrary-epub\manifest.json',TEncoding.UTF8)) as TJSONObject;
  try
    Require(Assigned(Proof) and Assigned(Manifest),'Missing FLibrary startup recovery evidence');
    Collection:=SystemDB.GetCollection(Proof.GetValue<Integer>('collection'),True);
    TestReviewedFLibraryCompression(Collection,Manifest,Proof.GetValue<string>('source_root'));
  finally Manifest.Free; Proof.Free; end;
end;
