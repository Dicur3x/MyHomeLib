unit unit_LibraryUpdateInventory;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, unit_Globals;

type
  TLibraryUpdateInventory = class
  private type
    TArchive = class
      Entries, Basenames: TDictionary<string,Integer>;
      constructor Create(const FileName: string; const Check: TProc);
      destructor Destroy; override;
    end;
  private
    FArchives: TObjectDictionary<string,TArchive>;
    FLeases: TObjectList<TFileStream>;
    FLeased: TDictionary<string,Boolean>;
    FCheck: TProc;
    procedure Lease(const FileName: string);
  public
    constructor Create(const Check: TProc);
    destructor Destroy; override;
    // Header/name verification only; never reads all book payloads or writes
    // their archives. Duplicate names are ambiguous, not ordinal fallbacks.
    function Resolve(var Book: TBookRecord; const DownloadRoot: string;
      PreferNew: Boolean; out Reason: string): Boolean;
  end;

implementation

uses System.IOUtils, unit_MHLArchiveHelpers;

function NativeName(const Value: string): string;
begin
  Result:=TPath.GetFullPath(Value);
  if Result.StartsWith('\\?\') then Exit;
  if Result.StartsWith('\\') then Result:='\\?\UNC\'+Result.Substring(2)
  else Result:='\\?\'+Result;
end;

constructor TLibraryUpdateInventory.TArchive.Create(const FileName: string; const Check: TProc);
var Zip: TMHLZip; Name, Base: string;
  procedure Add(Map: TDictionary<string,Integer>; const Key: string; Index: Integer);
  begin if Map.ContainsKey(Key) then Map[Key]:=-1 else Map.Add(Key,Index); end;
begin
  inherited Create;
  Entries:=TDictionary<string,Integer>.Create; Basenames:=TDictionary<string,Integer>.Create;
  Zip:=TMHLZip.Create(FileName,True,False,function:Boolean begin Check; Result:=False; end);
  try
    for var I:=0 to Zip.FileCount-1 do
    begin
      Check;
      Name:=LowerCase(Zip.FileNames[I].Replace('\','/'));
      if Name.EndsWith('/') then Continue;
      Base:=Name.Substring(Name.LastIndexOf('/')+1);
      Add(Entries,Name,I); Add(Basenames,Base,I);
    end;
  finally Zip.Free; end;
end;

destructor TLibraryUpdateInventory.TArchive.Destroy;
begin Entries.Free; Basenames.Free; inherited; end;

constructor TLibraryUpdateInventory.Create(const Check: TProc);
begin
  inherited Create; FCheck:=Check;
  FArchives:=TObjectDictionary<string,TArchive>.Create([doOwnsValues]);
  FLeases:=TObjectList<TFileStream>.Create(True); FLeased:=TDictionary<string,Boolean>.Create;
end;

destructor TLibraryUpdateInventory.Destroy;
begin FArchives.Free; FLeases.Free; FLeased.Free; inherited; end;

procedure TLibraryUpdateInventory.Lease(const FileName: string);
var Key: string;
begin
  Key:=UpperCase(TPath.GetFullPath(FileName));
  if FLeased.ContainsKey(Key) then Exit;
  FLeases.Add(TFileStream.Create(NativeName(FileName),fmOpenRead or fmShareDenyWrite));
  FLeased.Add(Key,True);
end;

function TLibraryUpdateInventory.Resolve(var Book: TBookRecord; const DownloadRoot: string;
  PreferNew: Boolean; out Reason: string): Boolean;
var Candidate: TBookRecord; Old, NewPath, Path, Container, Wanted, Key: string;
  Archive: TArchive; Index: Integer;
begin
  Result:=False; Reason:=''; FCheck;
  Old:=Book.GetBookFileName; Path:=Old; Container:=Book.GetBookContainer;
  if (DownloadRoot<>'') and not TPath.IsPathRooted(Book.Folder) then
  begin
    Candidate:=Book; Candidate.CollectionRoot:=IncludeTrailingPathDelimiter(DownloadRoot);
    NewPath:=Candidate.GetBookFileName;
    if FileExists(NewPath) and (PreferNew or not FileExists(Old)) then
    begin Path:=NewPath; Container:=Candidate.GetBookContainer; end;
  end;
  if not FileExists(Path) then begin Reason:='Файл не найден: '+Path; Exit; end;
  Lease(Path);
  if Book.GetBookFormat(Container) in [bfFb2Archive,bfRawArchive] then
  begin
    Key:=UpperCase(TPath.GetFullPath(Container));
    if not FArchives.TryGetValue(Key,Archive) then
    begin
      if FArchives.Count>=8 then FArchives.Clear;
      Archive:=TArchive.Create(Container,FCheck); FArchives.Add(Key,Archive);
    end;
    Wanted:=Book.FileName;
    if not SameText(ExtractFileExt(Wanted),Book.FileExt) then Wanted:=Wanted+Book.FileExt;
    Wanted:=LowerCase(Wanted.Replace('\','/'));
    if not Archive.Entries.TryGetValue(Wanted,Index) then
    begin
      Wanted:=Wanted.Substring(Wanted.LastIndexOf('/')+1);
      if not Archive.Basenames.TryGetValue(Wanted,Index) then
      begin Reason:='В архиве нет книги: '+Path+' | '+Wanted; Exit; end;
    end;
    if Index<0 then begin Reason:='Неоднозначное имя книги в архиве: '+Path+' | '+Wanted; Exit; end;
    Book.Folder:=Container; Book.InsideNo:=Index;
  end
  else Book.Folder:=IncludeTrailingPathDelimiter(Container);
  Result:=True;
end;

end.
