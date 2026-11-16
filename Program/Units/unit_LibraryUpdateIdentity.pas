unit unit_LibraryUpdateIdentity;

interface

uses unit_Globals;

function LibraryUpdateBookKey(const Book:TBookRecord; const Namespace,Root:string):string;
function LibraryPublisherLocation(const Book:TBookRecord):string;
function LibraryLegacyPublisherLocation(const Book:TBookRecord):string;

implementation

uses System.SysUtils, System.IOUtils, System.Hash, unit_Consts, unit_LibrarySourceID, unit_MHLArchiveHelpers;

function LibraryUpdateBookKey(const Book: TBookRecord; const Namespace, Root: string): string;
var ID, Source, Original, Folder: string; P: Integer; Numeric: Boolean;
begin
  ID:=Book.LibID; Source:=LowerCase(Trim(Namespace));
  if ID.StartsWith('merged:',True) then
  begin Delete(ID,1,7); P:=Pos(':',ID); if P>0 then Delete(ID,1,P); end;
  if TryParseLibrarySourceID(ID,Source,Original) then ID:=Original
  else
  begin
    Source:=LowerCase(Trim(Namespace)); Numeric:=ID<>'';
    for var C in ID do Numeric:=Numeric and CharInSet(C,['0'..'9']);
    if not Numeric or ((Source<>'flibusta') and (Source<>'librusec')) then Source:='';
  end;
  if Source<>'' then Folder:='id:'+Source+#1+ID
  else if ID<>'' then Folder:='source-id:'+ID
  else
  begin
    Folder:=Book.Folder;
    if TPath.IsPathRooted(Folder) then
      Folder:=ExtractRelativePath(IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)),TPath.GetFullPath(Folder));
    Folder:='file:'+LowerCase(Folder.Replace('/','\'))+#1+ID;
  end;
  // Preserve separate artifacts sharing a library ID; unknown libraries match
  // only their physical relative locator, never a guessed display-name identity.
  Result:=THashSHA2.GetHashString(Folder+#1+LowerCase(Book.FileName)+#1+LowerCase(Book.FileExt));
end;

function IndexLocation(const Book: TBookRecord): string;
begin
  if IsArchiveExt(Book.Folder) then Result:=Book.Folder
  else Result:=TPath.Combine(Book.Folder,Book.FileName)+Book.FileExt;
end;

function LibraryPublisherLocation(const Book: TBookRecord): string;
begin Result:=LowerCase(IndexLocation(Book).Replace('/','\')); end;

function LibraryLegacyPublisherLocation(const Book:TBookRecord):string;
var Folder:string;
begin
  Result:=LibraryPublisherLocation(Book);
  if not IsArchiveExt(Book.Folder) then Exit;
  Folder:=Book.Folder;
  if TPath.IsPathRooted(Folder) then
  begin
    Folder:=ExtractRelativePath(IncludeTrailingPathDelimiter(TPath.GetFullPath(Book.CollectionRoot)),TPath.GetFullPath(Folder));
    // An older snapshot has no publisher locator for an external download
    // root. Do not guess its relative directory from the basename alone.
    if TPath.IsPathRooted(Folder) or (Folder='..') or Folder.StartsWith('..\') then Exit;
  end;
  if SameText(ExtractFileExt(Folder),SEVENZIP_EXTENSION) then Folder:=ChangeFileExt(Folder,ZIP_EXTENSION);
  Result:=LowerCase(Folder.Replace('/','\'));
end;

end.
