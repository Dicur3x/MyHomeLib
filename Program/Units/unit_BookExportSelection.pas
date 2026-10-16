unit unit_BookExportSelection;

interface

uses BookTreeView, VirtualTrees.Types, unit_Globals, unit_BookExportResults;

type
  TExportNodePredicate = reference to function(Node: PVirtualNode; Book: PBookRecord): Boolean;
  TExportBookPredicate = reference to function(const Book: TBookRecord): Boolean;

function BuildBookSelectionSnapshot(Tree: TBookTree;
  const IsSelected: TExportNodePredicate; const Accept: TExportBookPredicate;
  Uncheck: Boolean; out Skipped: Integer): TBookIdList;
procedure ApplySuccessfulExportMarks(Tree: TBookTree; const Results: TBookExportResults);

implementation

uses System.SysUtils, System.Generics.Collections, unit_ReaderCache;

function BuildBookSelectionSnapshot(Tree: TBookTree;
  const IsSelected: TExportNodePredicate; const Accept: TExportBookPredicate;
  Uncheck: Boolean; out Skipped: Integer): TBookIdList;
var Node: PVirtualNode; Book: PBookRecord; Count, Capacity: Integer;
begin
  Result := nil; Skipped := 0; Count := 0; Capacity := 0;
  if not Assigned(Tree) then raise EArgumentNilException.Create('Tree');
  if not Assigned(IsSelected) then raise EArgumentNilException.Create('IsSelected');
  Node := Tree.GetFirst;
  while Assigned(Node) do
  begin
    Book := Tree.GetNodeData(Node);
    if Assigned(Book) and IsSelected(Node, Book) then
    begin
      if Assigned(Accept) and not Accept(Book^) then Inc(Skipped)
      else
      begin
        if Count = Capacity then
        begin
          if Capacity = 0 then Capacity := 32 else Capacity := Capacity * 2;
          SetLength(Result, Capacity);
        end;
        Result[Count] := Default(TBookIdStruct);
        Result[Count].BookKey := Book^.BookKey;
        Result[Count].HasExpectedIdentity := True;
        Result[Count].ExpectedLibID := Book^.LibID;
        Result[Count].ExpectedPhysicalIdentity := ReaderBookPhysicalIdentity(Book^);
        Inc(Count);
        if Uncheck then Tree.CheckState[Node] := csUncheckedNormal;
      end;
    end;
    Node := Tree.GetNext(Node);
  end;
  SetLength(Result, Count);
end;

procedure ApplySuccessfulExportMarks(Tree: TBookTree; const Results: TBookExportResults);
var Indices: TDictionary<UInt64, Integer>; Node: PVirtualNode;
  Book: PBookRecord; Index: Integer;
  function Key(const Value: TBookKey): UInt64;
  begin
    Result := (UInt64(Cardinal(Value.DatabaseID)) shl 32) or Cardinal(Value.BookID);
  end;
begin
  if not Assigned(Tree) or (SuccessfulBookExportCount(Results) = 0) then Exit;
  Indices := TDictionary<UInt64, Integer>.Create;
  try
    for var I := 0 to High(Results) do
      if (Results[I].State = besSucceeded) and Results[I].Book.HasExpectedIdentity then
        Indices.AddOrSetValue(Key(Results[I].Book.BookKey), I);
    Tree.BeginUpdate;
    try
      Node := Tree.GetFirst;
      while Assigned(Node) do
      begin
        Book := Tree.GetNodeData(Node);
        if Assigned(Book) and (Book^.NodeType = ntBookInfo) and
          (Node^.CheckState = csCheckedNormal) and
          Indices.TryGetValue(Key(Book^.BookKey), Index) and
          (Book^.LibID = Results[Index].Book.ExpectedLibID) and
          (ReaderBookPhysicalIdentity(Book^) = Results[Index].Book.ExpectedPhysicalIdentity) then
          Tree.CheckState[Node] := csUncheckedNormal;
        Node := Tree.GetNext(Node);
      end;
    finally Tree.EndUpdate; end;
  finally Indices.Free; end;
end;

end.
