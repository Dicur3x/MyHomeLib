unit unit_CollectionTransferBindingDigest;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Hash;

type
  // Byte-identical to SHA256(TJSONArray.ToJSON), without retaining all rows.
  TTransferBindingDigest=class
  private
    FHash:THashSHA2;
    FBuffer:TBytes;
    FUsed:Integer;
    FRows:Int64;
    FFinished:Boolean;
    FResult:string;
    procedure Append(const Data:TBytes);
    procedure Flush;
  public
    constructor Create;
    // Borrows a completed row. Its caller retains ownership.
    procedure AddRow(Row:TJSONArray);
    function Digest:string;
  end;

implementation

constructor TTransferBindingDigest.Create;
begin
  inherited Create; FHash:=THashSHA2.Create; SetLength(FBuffer,64*1024);
  Append(TEncoding.UTF8.GetBytes('['));
end;

procedure TTransferBindingDigest.Flush;
begin
  if FUsed>0 then FHash.Update(FBuffer,FUsed);
  FUsed:=0;
end;

procedure TTransferBindingDigest.Append(const Data:TBytes);
begin
  if FFinished then raise EInvalidOperation.Create('Подтверждение расположений уже завершено.');
  if Length(Data)=0 then Exit;
  if Length(Data)>=Length(FBuffer) then
  begin Flush; FHash.Update(Data,Length(Data)); end
  else
  begin
    if FUsed+Length(Data)>Length(FBuffer) then Flush;
    Move(Data[0],FBuffer[FUsed],Length(Data)); Inc(FUsed,Length(Data));
  end;
end;

procedure TTransferBindingDigest.AddRow(Row:TJSONArray);
begin
  if Row=nil then raise EArgumentNilException.Create('Row');
  if FRows>0 then Append(TEncoding.UTF8.GetBytes(','));
  Append(TEncoding.UTF8.GetBytes(Row.ToJSON)); Inc(FRows);
end;

function TTransferBindingDigest.Digest:string;
begin
  if not FFinished then
  begin
    Append(TEncoding.UTF8.GetBytes(']')); Flush;
    FResult:=FHash.HashAsString; FFinished:=True;
  end;
  Result:=FResult;
end;

end.
