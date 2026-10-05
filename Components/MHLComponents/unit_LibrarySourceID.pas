unit unit_LibrarySourceID;

interface

uses
  System.SysUtils;

function IsMixedLibraryIndex(const MemberNames: TArray<string>): Boolean;
function ScopedLibraryID(const MemberName, LibID: string): string;
function TryParseLibrarySourceID(const LibID: string;
  out SourceName, OriginalID: string): Boolean;

implementation

uses
  System.StrUtils;

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
