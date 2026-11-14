unit unit_BookCompressionIndex;

interface

uses SQLiteWrap;

// Keep physical sizes across a full index rebuild, inside its existing
// transaction. A library ID alone is never a physical-file witness.
procedure CaptureCompressionIndexSizes(DB:TSQLiteDatabase; const Root,IdentitySQL:string);
procedure RestoreCompressionIndexSizes(DB:TSQLiteDatabase; const Root,IdentitySQL:string);

implementation

uses System.SysUtils, System.Classes, System.Generics.Collections,
  unit_Globals, unit_ZipMemberDeletion;

procedure CaptureCompressionIndexSizes(DB:TSQLiteDatabase; const Root,IdentitySQL:string);
var Query,Proof:TSQLiteQuery; Book:TBookRecord; Source,Actual,Key:string;
    Sources:TDictionary<string,string>;
begin
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressedSizes');
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressionSources');
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressionWitness');
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressionRestores');
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND '+
    'name IN (''HomeLibreBookCompression'',''HomeLibreCompressionChecks'')')<>2 then Exit;
  DB.ExecSQL('CREATE TEMP TABLE InpxCompressedSizes(Identity TEXT NOT NULL,Folder TEXT NOT NULL,'+
    'FileName TEXT NOT NULL,Ext TEXT NOT NULL,FileKey TEXT NOT NULL,BookSize INTEGER NOT NULL,'+
    'PRIMARY KEY(Identity,Folder,FileName,Ext)) WITHOUT ROWID');
  DB.ExecSQL('CREATE TEMP TABLE InpxCompressionSources(FileKey TEXT PRIMARY KEY,Source TEXT NOT NULL,'+
    'SourceIdentity TEXT NOT NULL) WITHOUT ROWID');
  DB.ExecSQL('CREATE TEMP TABLE InpxCompressionWitness AS SELECT DISTINCT '+
    'h.FileKey,h.Member,h.BookSize,c.SourceIdentity FROM HomeLibreBookCompression h '+
    'JOIN HomeLibreCompressionChecks c ON c.FileKey=h.FileKey AND c.Member=h.Member '+
    'AND c.PayloadSHA256=h.OutputSHA256 WHERE h.BookSize>0');
  DB.ExecSQL('CREATE INDEX temp.InpxCompressionWitnessFile ON InpxCompressionWitness(FileKey,SourceIdentity,Member)');
  DB.ExecSQL('CREATE INDEX temp.InpxCompressionWitnessMember ON InpxCompressionWitness(Member)');
  DB.ExecSQL('CREATE INDEX temp.InpxCompressionWitnessSize ON InpxCompressionWitness(BookSize) WHERE Member=''''');
  Sources:=TDictionary<string,string>.Create;
  Query:=nil; Proof:=nil;
  try
    // The empty member names a standalone file, not an archive member. Its
    // old size narrows candidates; the physical key/identity below is still
    // mandatory, so equal-sized unrelated books cannot borrow its witness.
    Query:=DB.NewQuery('SELECT '+IdentitySQL+',Folder,FileName,Ext,InsideNo FROM Books '+
      'WHERE FileName||coalesce(Ext,'''') IN (SELECT Member FROM temp.InpxCompressionWitness WHERE Member<>'''') '+
      'OR BookSize IN (SELECT BookSize FROM temp.InpxCompressionWitness WHERE Member='''')');
    Proof:=DB.NewQuery('SELECT FileKey,BookSize FROM temp.InpxCompressionWitness '+
      'WHERE FileKey=? AND SourceIdentity=? AND (Member=? OR Member='''') LIMIT 1');
    Query.Open;
    while not Query.Eof do
    begin
      Book:=Default(TBookRecord); Book.CollectionRoot:=Root;
      Book.Folder:=Query.FieldAsString(1); Book.FileName:=Query.FieldAsString(2);
      Book.FileExt:=Query.FieldAsString(3); Book.InsideNo:=Query.FieldAsInt(4);
      Source:=''; Actual:='';
      try
        Source:=Book.GetBookFileName;
        if not Sources.TryGetValue(Source,Actual) then
        begin
          Actual:=ArchiveDeletionSourceIdentity(Source);
          Sources.Add(Source,Actual);
        end;
      except
        on E:EOSError do Actual:='';
        on E:EFOpenError do Actual:='';
        on E:EReadError do Actual:='';
      end;
      if (Source<>'') and not Sources.ContainsKey(Source) then Sources.Add(Source,Actual);
      if Actual<>'' then
      begin
        Proof.Reset; Proof.SetParam(0,UpperCase(Copy(Actual,1,25)));
        Proof.SetParam(1,Actual); Proof.SetParam(2,Book.FileName+Book.FileExt); Proof.Open;
        if not Proof.Eof then
        begin
          Key:=Proof.FieldAsString(0);
          DB.ExecSQL('INSERT OR IGNORE INTO temp.InpxCompressionSources VALUES(?,?,?)',[Key,Source,Actual]);
          DB.ExecSQL('INSERT OR REPLACE INTO temp.InpxCompressedSizes VALUES(?,?,?,?,?,?)',
            [Query.FieldAsString(0),Book.Folder,Book.FileName,Book.FileExt,Key,Proof.FieldAsInt(1)]);
        end;
      end;
      Query.Next;
    end;
  finally Proof.Free; Query.Free; Sources.Free; end;
  DB.ExecSQL('CREATE INDEX temp.InpxCompressedSizesMember ON InpxCompressedSizes(Identity,FileName,Ext)');
  {$IFDEF MHL_COMPRESSION_TEST}
  Writeln('TRACE compressed size snapshots=',DB.QuerySingleInt('SELECT count(*) FROM temp.InpxCompressedSizes'));
  {$ENDIF}
  DB.ExecSQL('DROP TABLE temp.InpxCompressionWitness');
end;

procedure RestoreCompressionIndexSizes(DB:TSQLiteDatabase; const Root,IdentitySQL:string);
var Query:TSQLiteQuery; Actual,Source:string; Book:TBookRecord; Sources:TDictionary<string,string>;
begin
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_temp_master WHERE type=''table'' '+
    'AND name=''InpxCompressedSizes''')=0 then Exit;
  Query:=DB.NewQuery('SELECT FileKey,Source,SourceIdentity FROM temp.InpxCompressionSources');
  try
    Query.Open;
    while not Query.Eof do
    begin
      Actual:='';
      try Actual:=ArchiveDeletionSourceIdentity(Query.FieldAsString(1));
      except
        on E:EOSError do Actual:='';
        on E:EFOpenError do Actual:='';
        on E:EReadError do Actual:='';
      end;
      if Actual<>Query.FieldAsString(2) then
        DB.ExecSQL('DELETE FROM temp.InpxCompressedSizes WHERE FileKey=?',[Query.FieldAsString(0)]);
      Query.Next;
    end;
  finally Query.Free; end;
  DB.ExecSQL('CREATE TEMP TABLE InpxCompressionRestores(BookID INTEGER PRIMARY KEY,BookSize INTEGER NOT NULL)');
  // INPX may spell the same archive with different slashes or a ZIP/7z alias.
  // Prove the rebuilt row's physical source instead of trusting its folder text
  // or borrowing a size solely because the publisher reused a library ID.
  Sources:=TDictionary<string,string>.Create;
  Query:=nil;
  try
    Query:=DB.NewQuery('SELECT b.BookID,b.Folder,b.FileName,b.Ext,b.InsideNo,'+
      's.BookSize,c.SourceIdentity FROM '+
      '(SELECT BookID,'+IdentitySQL+' AS Identity,Folder,FileName,Ext,InsideNo FROM Books) b '+
      'JOIN temp.InpxCompressedSizes s ON s.Identity=b.Identity '+
      'AND s.FileName=b.FileName AND s.Ext=b.Ext '+
      'JOIN temp.InpxCompressionSources c ON c.FileKey=s.FileKey');
    Query.Open;
    while not Query.Eof do
    begin
      Book:=Default(TBookRecord); Book.CollectionRoot:=Root;
      Book.Folder:=Query.FieldAsString(1); Book.FileName:=Query.FieldAsString(2);
      Book.FileExt:=Query.FieldAsString(3); Book.InsideNo:=Query.FieldAsInt(4);
      Source:=''; Actual:='';
      try
        Source:=Book.GetBookFileName;
        if not Sources.TryGetValue(Source,Actual) then
        begin
          Actual:=ArchiveDeletionSourceIdentity(Source);
          Sources.Add(Source,Actual);
        end;
      except
        on E:EOSError do Actual:='';
        on E:EFOpenError do Actual:='';
        on E:EReadError do Actual:='';
      end;
      if (Source<>'') and not Sources.ContainsKey(Source) then Sources.Add(Source,Actual);
      if (Actual<>'') and (Actual=Query.FieldAsString(6)) then
        DB.ExecSQL('INSERT OR REPLACE INTO temp.InpxCompressionRestores VALUES(?,?)',
          [Query.FieldAsInt(0),Query.FieldAsInt(5)]);
      Query.Next;
    end;
  finally Query.Free; Sources.Free; end;
  {$IFDEF MHL_COMPRESSION_TEST}
  Writeln('TRACE compressed size restores=',DB.QuerySingleInt('SELECT count(*) FROM temp.InpxCompressionRestores'));
  {$ENDIF}
  DB.ExecSQL('UPDATE Books SET BookSize=(SELECT BookSize FROM temp.InpxCompressionRestores r '+
    'WHERE r.BookID=Books.BookID) WHERE BookID IN (SELECT BookID FROM temp.InpxCompressionRestores)');
  DB.ExecSQL('DROP TABLE temp.InpxCompressionRestores');
  DB.ExecSQL('DROP TABLE temp.InpxCompressedSizes');
  DB.ExecSQL('DROP TABLE temp.InpxCompressionSources');
end;

end.
