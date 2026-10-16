unit unit_BookExportResults;

interface

uses unit_Globals;

type
  TBookExportState = (besPending, besPrepared, besSucceeded, besFailed, besCanceled);

  TBookExportResult = record
    Book: TBookIdStruct;
    State: TBookExportState;
    OutputFile, ErrorText: string;
  end;

  TBookExportResults = TArray<TBookExportResult>;

function PendingBookExportResults(const Books: TBookIdList): TBookExportResults;
function AllBooksPreparedForScript(const Results: TBookExportResults): Boolean;
function SuccessfulBookExportCount(const Results: TBookExportResults): Integer;

implementation

function PendingBookExportResults(const Books: TBookIdList): TBookExportResults;
begin
  SetLength(Result, Length(Books));
  for var I := 0 to High(Books) do
  begin
    Result[I] := Default(TBookExportResult);
    Result[I].Book := Books[I];
  end;
end;

function AllBooksPreparedForScript(const Results: TBookExportResults): Boolean;
begin
  Result := Length(Results) > 0;
  for var Item in Results do
    if Item.State <> besPrepared then Exit(False);
end;

function SuccessfulBookExportCount(const Results: TBookExportResults): Integer;
begin
  Result := 0;
  for var Item in Results do
    if Item.State = besSucceeded then Inc(Result);
end;

end.
