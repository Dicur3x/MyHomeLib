unit unit_LibrarySourceID;

interface

uses
  System.SysUtils;

const LOCAL_BOOK_ID_PREFIX = 'local:';
  LINKED_BOOK_ID_PREFIX = LOCAL_BOOK_ID_PREFIX + 'link:';

function NewLocalBookID(const KeepSource: Boolean = False): string;
function IsLocalBookID(const Value: string): Boolean;
function IsLinkedLocalBookID(const Value: string): Boolean;
function IsMixedLibraryIndex(const MemberNames: TArray<string>): Boolean;
function ScopedLibraryID(const MemberName, LibID: string): string;
function TryParseLibrarySourceID(const LibID: string;
  out SourceName, OriginalID: string): Boolean;

implementation

uses
  System.StrUtils;

function NewLocalBookID(const KeepSource: Boolean): string;
begin
  Result := LowerCase(Copy(TGUID.NewGuid.ToString,2,36));
  if KeepSource then Result := LINKED_BOOK_ID_PREFIX + Result
  else Result := LOCAL_BOOK_ID_PREFIX + Result;
end;

function HasLocalIDPrefix(const Value, Prefix: string): Boolean;
var I: Integer; C: Char;
begin
  Result := False;
  if (Length(Value)<>Length(Prefix)+36) or not StartsText(Prefix,Value) then Exit;
  for I:=1 to 36 do
  begin
    C := Value[Length(Prefix)+I];
    if I in [9,14,19,24] then
    begin
      if C<>'-' then Exit;
    end
    else if not CharInSet(C,['0'..'9','a'..'f','A'..'F']) then Exit;
  end;
  Result := True;
end;

function IsLocalBookID(const Value: string): Boolean;
begin
  Result := HasLocalIDPrefix(Value,LOCAL_BOOK_ID_PREFIX) or HasLocalIDPrefix(Value,LINKED_BOOK_ID_PREFIX);
end;

function IsLinkedLocalBookID(const Value: string): Boolean;
var Start: Integer;
begin
  Result := False;
  Start := Length(Value)-Length(LINKED_BOOK_ID_PREFIX)-36+1;
  if Start<1 then Exit;
  if (Start>1) and ((Value[Start-1]<>':') or not StartsText('merged:',Value)) then Exit;
  Result := HasLocalIDPrefix(Copy(Value,Start,MaxInt),LINKED_BOOK_ID_PREFIX);
end;

function MemberBaseName(const Name: string): string;
begin
  Result := ExtractFileName(StringReplace(Name, '/', '\', [rfReplaceAll]));
end;

function IsMixedLibraryIndex(const MemberNames: TArray<string>): Boolean;
var
  Name, BaseName: string;
  HasLibrusec, HasFlibusta: Boolean;
begin
  HasLibrusec := False;
  HasFlibusta := False;
  for Name in MemberNames do
  begin
    BaseName := MemberBaseName(Name);
    if not SameText(ExtractFileExt(BaseName), '.inp') then
      Continue;
    HasLibrusec := HasLibrusec or StartsText('fb2-', BaseName);
    HasFlibusta := HasFlibusta or StartsText('f.fb2-', BaseName);
  end;
  Result := HasLibrusec and HasFlibusta;
end;

function IsNumericID(const ID: string): Boolean;
var
  C: Char;
begin
  Result := ID <> '';
  for C in ID do
    if not CharInSet(C, ['0'..'9']) then
      Exit(False);
end;

function ScopedLibraryID(const MemberName, LibID: string): string;
var
  BaseName: string;
begin
  Result := LibID;
  if not IsNumericID(LibID) then
    Exit;
  BaseName := MemberBaseName(MemberName);
  if StartsText('fb2-', BaseName) then
    Result := 'librusec:' + LibID
  else if StartsText('f.fb2-', BaseName) or
    StartsText('d.fb2-', BaseName) then
    Result := 'flibusta:' + LibID;
end;

function TryParseLibrarySourceID(const LibID: string;
  out SourceName, OriginalID: string): Boolean;
var
  Separator: Integer;
begin
  SourceName := '';
  OriginalID := '';
  Separator := Pos(':', LibID);
  if Separator = 0 then
    Exit(False);
  SourceName := LowerCase(Copy(LibID, 1, Separator - 1));
  OriginalID := Copy(LibID, Separator + 1, MaxInt);
  Result := ((SourceName = 'librusec') or (SourceName = 'flibusta')) and
    IsNumericID(OriginalID);
  if not Result then
  begin
    SourceName := '';
    OriginalID := '';
  end;
end;

end.
