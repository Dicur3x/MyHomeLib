unit unit_MCP_Json;

interface

uses
  System.SysUtils,
  System.JSON,
  unit_MCP_Protocol;

function ArgStr(const Args: TJSONObject; const Name: string; const Default: string = ''): string;
function ArgInt(const Args: TJSONObject; const Name: string; Default: Integer): Integer;
function ArgBool(const Args: TJSONObject; const Name: string; Default: Boolean): Boolean;
function ArgIntClamped(const Args: TJSONObject; const Name: string;
  Default, Min, Max: Integer; out Clamped: Boolean): Integer;
function RequireInt(const Args: TJSONObject; const Name: string): Integer;

implementation

// Absent arguments take the default; present ones use the strict, non-defaulting
// GetValue<T>(Name), so a wrong-typed value raises invalid_params instead of
// silently becoming "no filter". The RTL still coerces "42" to Integer and
// numbers to String; only outright-incompatible values raise.
//
// An explicit JSON null counts as absent: GetValue(Name) returns a TJSONNull,
// not nil, and clients generated from JSON Schema emit null for unset optionals.
function IsAbsent(const Args: TJSONObject; const Name: string): Boolean;
var
  Value: TJSONValue;
begin
  if not Assigned(Args) then
    Exit(True);

  Value := Args.GetValue(Name);
  Result := (Value = nil) or (Value is TJSONNull);
end;

function ArgStr(const Args: TJSONObject; const Name: string; const Default: string): string;
begin
  if IsAbsent(Args, Name) then
    Exit(Default);
  try
    Result := Args.GetValue<string>(Name);
  except
    on E: EJSONException do
      raise EMcpToolError.Create('invalid_params',
        Format('Argument %s must be a string', [Name]));
  end;
end;

function ArgInt(const Args: TJSONObject; const Name: string; Default: Integer): Integer;
begin
  if IsAbsent(Args, Name) then
    Exit(Default);
  try
    Result := Args.GetValue<Integer>(Name);
  except
    on E: EJSONException do
      raise EMcpToolError.Create('invalid_params',
        Format('Argument %s must be an integer', [Name]));
  end;
end;

function ArgBool(const Args: TJSONObject; const Name: string; Default: Boolean): Boolean;
begin
  if IsAbsent(Args, Name) then
    Exit(Default);
  try
    Result := Args.GetValue<Boolean>(Name);
  except
    on E: EJSONException do
      raise EMcpToolError.Create('invalid_params',
        Format('Argument %s must be a boolean', [Name]));
  end;
end;

function ArgIntClamped(const Args: TJSONObject; const Name: string;
  Default, Min, Max: Integer; out Clamped: Boolean): Integer;
begin
  Result := ArgInt(Args, Name, Default);
  Clamped := False;

  if Result < Min then
  begin
    Result := Min;
    Clamped := True;
  end
  else if Result > Max then
  begin
    Result := Max;
    Clamped := True;
  end;
end;

function RequireInt(const Args: TJSONObject; const Name: string): Integer;
begin
  if IsAbsent(Args, Name) then
    raise EMcpToolError.Create('invalid_params',
      Format('Missing required argument: %s', [Name]));
  try
    Result := Args.GetValue<Integer>(Name);
  except
    on E: EJSONException do
      raise EMcpToolError.Create('invalid_params',
        Format('Argument %s must be an integer', [Name]));
  end;
end;

end.
