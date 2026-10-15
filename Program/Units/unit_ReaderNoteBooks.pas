unit unit_ReaderNoteBooks;

interface

uses System.SysUtils, unit_Globals, unit_Interfaces, unit_ReaderAnnotations;

function ReaderNoteIdentity(const Identity: string): string;
procedure RegisterReaderNoteBook(const SettingsFile: string; const Book: TBookRecord;
  const LibraryNamespace: string);
function FindReaderNoteBook(const User: ISystemData; const SettingsFile: string;
  const Note: TReaderAnnotation; PreferredCollection: Integer; out Book: TBookRecord): Boolean;
function ReaderNoteBookIDs(const User: ISystemData; const SettingsFile: string;
  CollectionID: Integer): TArray<Integer>;

implementation

uses System.IniFiles, System.Hash, System.Variants, System.Generics.Collections,
  unit_ReaderCache, unit_AtomicIniFile, unit_Consts;

function ReaderNoteIdentity(const Identity: string): string;
begin Result:=Copy(THashSHA2.GetHashString(Identity),1,40); end;

function NamespaceFor(const Collection: IBookCollection): string;
begin Result:=VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)); end;

procedure RegisterReaderNoteBook(const SettingsFile: string; const Book: TBookRecord;
  const LibraryNamespace: string);
var Ini: TMemIniFile; Section, Physical: string;
begin
  if (SettingsFile='') or (Book.BookKey.BookID<=0) then Exit;
  Section:='Book.'+ReaderNoteIdentity(ReaderHistoryName(Book,LibraryNamespace));
  Physical:=ReaderBookPhysicalIdentity(Book);
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try
    if (Ini.ReadInteger(Section,'CollectionID',-1)=Book.BookKey.DatabaseID) and
      (Ini.ReadInteger(Section,'CatalogBookID',-1)=Book.BookKey.BookID) and
      (Ini.ReadString(Section,'LibID','')=Book.LibID) and
      (Ini.ReadString(Section,'PhysicalIdentity','')=Physical) and
      (Ini.ReadString(Section,'Title','')=Book.Title) then Exit;
    Ini.WriteInteger(Section,'CollectionID',Book.BookKey.DatabaseID);
    Ini.WriteInteger(Section,'CatalogBookID',Book.BookKey.BookID);
    Ini.WriteString(Section,'LibID',Book.LibID);
    Ini.WriteString(Section,'PhysicalIdentity',Physical);
    Ini.WriteString(Section,'Title',Book.Title);
    SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
end;

function Matches(const Book: TBookRecord; const Identity, Namespace: string): Boolean;
begin
  Result:=(Book.BookKey.BookID>0) and
    (ReaderNoteIdentity(ReaderHistoryName(Book,Namespace))=Identity);
end;

function FindReaderNoteBook(const User: ISystemData; const SettingsFile: string;
  const Note: TReaderAnnotation; PreferredCollection: Integer; out Book: TBookRecord): Boolean;
var Ini: TMemIniFile; BoundCID, BoundID: Integer; Section: string;
  Collections: ICollectionInfoIterator; Info: TCollectionInfo;
  function InCollection(CID: Integer; UseBinding: Boolean): Boolean;
  var Collection: IBookCollection; Candidate: TBookRecord; Criteria: TBookSearchCriteria;
    Iterator: IBookIterator; Namespace: string; ResolvedID: Integer;
  begin
    Result:=False;
    try
      Collection:=User.GetCollection(CID); Namespace:=NamespaceFor(Collection);
      if UseBinding and (CID=BoundCID) and (BoundID>0) then
      begin
        try
          ResolvedID:=Collection.ResolveBookID(Ini.ReadString(Section,'LibID',''),BoundID);
          if ResolvedID>0 then
          begin
            Collection.GetBookRecord(CreateBookKey(ResolvedID,CID),Candidate,False);
            if Matches(Candidate,Note.BookID,Namespace) and
              ReaderBookMatchesExpectedIdentity(Ini.ReadString(Section,'LibID',''),
                Ini.ReadString(Section,'PhysicalIdentity',''),Candidate,Namespace) then
            begin Book:=Candidate; Exit(True); end;
          end;
        except
          on E: EOutOfMemory do raise;
          on E: EAccessViolation do raise;
          on E: Exception do ; // Continue with indexed legacy lookup.
        end;
      end;
      // Old notes have only their original title and reader identity. The
      // title narrows candidates via the existing index; the identity decides.
      // Never open an arbitrary book just because its title is the same.
      if Note.BookTitle='' then Exit;
      Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1;
      Criteria.ExactTitle:=Note.BookTitle; Criteria.CollapseMultiSeriesResults:=True;
      Iterator:=Collection.Search(Criteria,False);
      while Iterator.Next(Candidate) do
        if Matches(Candidate,Note.BookID,Namespace) then begin Book:=Candidate; Exit(True); end;
    except
      // A disconnected collection must not hide notes or prevent trying others.
      on E: EOutOfMemory do raise;
      on E: EAccessViolation do raise;
      on E: Exception do Result:=False;
    end;
  end;
begin
  Result:=False; Book:=Default(TBookRecord);
  if not Assigned(User) or (Note.BookID='') then Exit;
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try
    Section:='Book.'+Note.BookID;
    BoundCID:=Ini.ReadInteger(Section,'CollectionID',-1);
    BoundID:=Ini.ReadInteger(Section,'CatalogBookID',-1);
    if PreferredCollection>=0 then
      if InCollection(PreferredCollection,True) then Exit(True);
    if (BoundCID>=0) and (BoundCID<>PreferredCollection) then
      if InCollection(BoundCID,True) then Exit(True);
    Collections:=User.GetCollectionInfoIterator;
    while Collections.Next(Info) do
      if (Info.ID<>PreferredCollection) and (Info.ID<>BoundCID) and InCollection(Info.ID,False) then Exit(True);
  finally Ini.Free; end;
end;

function ReaderNoteBookIDs(const User: ISystemData; const SettingsFile: string;
  CollectionID: Integer): TArray<Integer>;
var Store: TReaderAnnotations; Ini: TMemIniFile; Notes: TArray<TReaderAnnotation>;
  Pending: TDictionary<string,TReaderAnnotation>; Candidates, Found: TDictionary<Integer,Boolean>;
  Collection: IBookCollection; Iterator: IBookIterator; Criteria: TBookSearchCriteria;
  Book: TBookRecord; Identity, Section, Namespace: string; Note: TReaderAnnotation; CID, ID: Integer;
begin
  Result:=nil; if not Assigned(User) then Exit;
  Store:=nil; Ini:=nil; Pending:=nil; Candidates:=nil; Found:=nil;
  try
    Store:=TReaderAnnotations.Create(SettingsFile); Notes:=Store.Items;
    if Length(Notes)=0 then Exit;
    Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
    Pending:=TDictionary<string,TReaderAnnotation>.Create;
    Candidates:=TDictionary<Integer,Boolean>.Create; Found:=TDictionary<Integer,Boolean>.Create;
    Notes:=Store.Items; Collection:=User.GetCollection(CollectionID); Namespace:=NamespaceFor(Collection);
    for Note in Notes do
    begin
      Pending.TryAdd(Note.BookID,Note); Section:='Book.'+Note.BookID;
      CID:=Ini.ReadInteger(Section,'CollectionID',-1); ID:=Ini.ReadInteger(Section,'CatalogBookID',-1);
      if (CID=CollectionID) and (ID>0) then Candidates.TryAdd(ID,True);
    end;
    if Candidates.Count>0 then
    begin
      Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1;
      Criteria.RestrictBookIDs:=True; Criteria.BookIDs:=Candidates.Keys.ToArray;
      Criteria.CollapseMultiSeriesResults:=True; Iterator:=Collection.Search(Criteria,False);
      while Iterator.Next(Book) do
      begin
        Identity:=ReaderNoteIdentity(ReaderHistoryName(Book,Namespace));
        if Pending.ContainsKey(Identity) then
        begin Found.TryAdd(Book.BookKey.BookID,True); Pending.Remove(Identity); end;
      end;
    end;
    // Reimports may replace numeric catalog IDs and rename titles while
    // retaining the stable library identity. Resolve only unmatched bindings.
    Candidates.Clear;
    for Note in Pending.Values do
    begin
      Section:='Book.'+Note.BookID;
      if Ini.ReadInteger(Section,'CollectionID',-1)<>CollectionID then Continue;
      ID:=Collection.ResolveBookID(Ini.ReadString(Section,'LibID',''),
        Ini.ReadInteger(Section,'CatalogBookID',-1));
      if ID>0 then Candidates.TryAdd(ID,True);
    end;
    if Candidates.Count>0 then
    begin
      Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1;
      Criteria.RestrictBookIDs:=True; Criteria.BookIDs:=Candidates.Keys.ToArray;
      Criteria.CollapseMultiSeriesResults:=True; Iterator:=Collection.Search(Criteria,False);
      while Iterator.Next(Book) do
      begin
        Identity:=ReaderNoteIdentity(ReaderHistoryName(Book,Namespace));
        if Pending.ContainsKey(Identity) then
        begin Found.TryAdd(Book.BookKey.BookID,True); Pending.Remove(Identity); end;
      end;
    end;
    for Note in Pending.Values do
    begin
      if Note.BookTitle='' then Continue;
      Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1;
      Criteria.ExactTitle:=Note.BookTitle; Criteria.CollapseMultiSeriesResults:=True;
      Iterator:=Collection.Search(Criteria,False);
      while Iterator.Next(Book) do
        if Matches(Book,Note.BookID,Namespace) then Found.TryAdd(Book.BookKey.BookID,True);
    end;
    Result:=Found.Keys.ToArray;
  finally Found.Free; Candidates.Free; Pending.Free; Ini.Free; Store.Free; end;
end;

end.
