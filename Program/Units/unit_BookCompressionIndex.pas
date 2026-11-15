unit unit_BookCompressionIndex;

interface

uses SQLiteWrap;

// Keep physical sizes across a full index rebuild, inside its existing
// transaction. A library ID alone is never a physical-file witness.
procedure CaptureCompressionIndexSizes(DB:TSQLiteDatabase; const Root,IdentitySQL:string);
procedure RestoreCompressionIndexSizes(DB:TSQLiteDatabase; const Root,IdentitySQL:string);

implementation

uses System.SysUtils, System.Classes, System.Generics.Collections,
  unit_Globals, unit_ZipMemberDeletion, unit_BookCompressionImages;

procedure CaptureCompressionIndexSizes(DB:TSQLiteDatabase; const Root,IdentitySQL:string);
var Query,Proof:TSQLiteQuery; Book:TBookRecord; Source,Actual,Key,SQL,Stamp,Snapshot:string;
    Sources:TDictionary<string,string>;
    ImageMatches:TDictionary<string,Boolean>; HasCopies:Boolean;
  function ImagesMatch(const Source,Stamp,Snapshot:string):Boolean;
  begin
    if Stamp='' then Exit(True);
    var Key:=UpperCase(ExpandFileName(Source))+#0+Stamp;
    if not ImageMatches.TryGetValue(Key,Result) then
    begin
      Result:=CompressionImageSnapshotMatches(Source,Snapshot,False);
      ImageMatches.Add(Key,Result);
    end;
  end;
begin
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressedSizes');
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressionSources');
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressionWitness');
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressionRestores');
  DB.ExecSQL('DROP TABLE IF EXISTS temp.InpxCompressionCopyRestores');
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND '+
    'name IN (''HomeLibreBookCompression'',''HomeLibreCompressionChecks'')')<>2 then Exit;
  DB.ExecSQL('CREATE TEMP TABLE InpxCompressedSizes(Identity TEXT NOT NULL,Folder TEXT NOT NULL,'+
    'FileName TEXT NOT NULL,Ext TEXT NOT NULL,FileKey TEXT NOT NULL,BookSize INTEGER NOT NULL,ImageStamp TEXT NOT NULL,Kind INTEGER NOT NULL,'+
    'PRIMARY KEY(Kind,Identity,Folder,FileName,Ext)) WITHOUT ROWID');
  DB.ExecSQL('CREATE TEMP TABLE InpxCompressionSources(FileKey TEXT NOT NULL,Source TEXT NOT NULL,'+
    'SourceIdentity TEXT NOT NULL,ImageStamp TEXT NOT NULL,SourcesJSON TEXT NOT NULL,'+
    'PRIMARY KEY(FileKey,ImageStamp)) WITHOUT ROWID');
  SQL:='CREATE TEMP TABLE InpxCompressionWitness AS SELECT DISTINCT '+
    'h.FileKey,h.Member,h.BookSize,c.SourceIdentity,'''' AS ImageStamp,'''' AS SourcesJSON FROM HomeLibreBookCompression h '+
    'JOIN HomeLibreCompressionChecks c ON c.FileKey=h.FileKey AND c.Member=h.Member '+
    'AND c.PayloadSHA256=h.OutputSHA256 WHERE h.BookSize>0 '+
    'AND h.InputSHA256<>h.OutputSHA256';
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND '+
    'name IN (''HomeLibreRestoredBookSizes'',''HomeLibreCompressionImageSets'')')=2 then
    SQL:=SQL+' AND NOT EXISTS(SELECT 1 FROM HomeLibreRestoredBookSizes f '+
      'WHERE f.FileKey=h.FileKey AND f.Member=h.Member) UNION ALL '+
      'SELECT f.FileKey,f.Member,f.BookSize,f.SourceIdentity,f.ImageStamp,s.SourcesJSON '+
      'FROM HomeLibreRestoredBookSizes f JOIN HomeLibreBookCompression h '+
      'ON h.FileKey=f.FileKey AND h.Member=f.Member AND h.OutputSHA256=f.PayloadSHA256 '+
      'JOIN HomeLibreCompressionImageSets s ON s.FileKey=f.FileKey AND s.Stamp=f.ImageStamp WHERE f.BookSize>0';
  DB.ExecSQL(SQL);
  DB.ExecSQL('CREATE INDEX temp.InpxCompressionWitnessFile ON InpxCompressionWitness(FileKey,SourceIdentity,Member)');
  DB.ExecSQL('CREATE INDEX temp.InpxCompressionWitnessMember ON InpxCompressionWitness(Member)');
  DB.ExecSQL('CREATE INDEX temp.InpxCompressionWitnessSize ON InpxCompressionWitness(BookSize) WHERE Member=''''');
  Sources:=TDictionary<string,string>.Create;
  ImageMatches:=TDictionary<string,Boolean>.Create;
  Query:=nil; Proof:=nil;
  try
    // The empty member names a standalone file, not an archive member. Its
    // old size narrows candidates; the physical key/identity below is still
    // mandatory, so equal-sized unrelated books cannot borrow its witness.
    HasCopies:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')<>0;
    SQL:='SELECT '+IdentitySQL+',Folder,FileName,Ext,InsideNo,0 AS Kind,'''' AS Root FROM Books '+
      'WHERE FileName||coalesce(Ext,'''') IN (SELECT Member FROM temp.InpxCompressionWitness WHERE Member<>'''') '+
      'OR BookSize IN (SELECT BookSize FROM temp.InpxCompressionWitness WHERE Member='''')';
    // A shared card may name several physical copies. Keep their source keys
    // and roots separate from the card identity and from each other.
    if HasCopies then SQL:=SQL+' UNION ALL SELECT SourceKey,Folder,FileName,coalesce(Ext,''''),InsideNo,1,Root FROM CatalogBookCopies '+
      'WHERE FileName||coalesce(Ext,'''') IN (SELECT Member FROM temp.InpxCompressionWitness WHERE Member<>'''') '+
      'OR BookSize IN (SELECT BookSize FROM temp.InpxCompressionWitness WHERE Member='''')';
    Query:=DB.NewQuery(SQL);
    Proof:=DB.NewQuery('SELECT FileKey,BookSize,ImageStamp,SourcesJSON FROM temp.InpxCompressionWitness '+
      'WHERE FileKey=? AND SourceIdentity=? AND (Member=? OR Member='''') LIMIT 1');
    Query.Open;
    while not Query.Eof do
    begin
      Book:=Default(TBookRecord); Book.CollectionRoot:=Query.FieldAsString(6);
      if Book.CollectionRoot='' then Book.CollectionRoot:=Root;
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
          Stamp:=Proof.FieldAsString(2); Snapshot:=Proof.FieldAsString(3);
          if not ImagesMatch(Source,Stamp,Snapshot) then
          begin Query.Next; Continue; end;
          Key:=Proof.FieldAsString(0);
          DB.ExecSQL('INSERT OR IGNORE INTO temp.InpxCompressionSources VALUES(?,?,?,?,?)',[Key,Source,Actual,Stamp,Snapshot]);
          DB.ExecSQL('INSERT OR REPLACE INTO temp.InpxCompressedSizes VALUES(?,?,?,?,?,?,?,?)',
            [Query.FieldAsString(0),Book.Folder,Book.FileName,Book.FileExt,Key,Proof.FieldAsInt(1),Stamp,Query.FieldAsInt(5)]);
        end;
      end;
      Query.Next;
    end;
  finally ImageMatches.Free; Proof.Free; Query.Free; Sources.Free; end;
  DB.ExecSQL('CREATE INDEX temp.InpxCompressedSizesMember ON InpxCompressedSizes(Identity,FileName,Ext)');
  {$IFDEF MHL_COMPRESSION_TEST}
  Writeln('TRACE compressed size snapshots=',DB.QuerySingleInt('SELECT count(*) FROM temp.InpxCompressedSizes'));
  {$ENDIF}
  DB.ExecSQL('DROP TABLE temp.InpxCompressionWitness');
end;

procedure RestoreCompressionIndexSizes(DB:TSQLiteDatabase; const Root,IdentitySQL:string);
var Query:TSQLiteQuery; Actual,Source,SQL:string; Book:TBookRecord; Sources:TDictionary<string,string>;
    ImageMatches:TDictionary<string,Boolean>; HasCopies:Boolean;
begin
  if DB.QuerySingleInt('SELECT count(*) FROM sqlite_temp_master WHERE type=''table'' '+
    'AND name=''InpxCompressedSizes''')=0 then Exit;
  Query:=DB.NewQuery('SELECT FileKey,Source,SourceIdentity,ImageStamp,SourcesJSON FROM temp.InpxCompressionSources');
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
      if (Actual<>Query.FieldAsString(2)) or ((Query.FieldAsString(3)<>'') and
        not CompressionImageSnapshotMatches(Query.FieldAsString(1),Query.FieldAsString(4),False)) then
        DB.ExecSQL('DELETE FROM temp.InpxCompressedSizes WHERE FileKey=? AND ImageStamp=?',
          [Query.FieldAsString(0),Query.FieldAsString(3)]);
      Query.Next;
    end;
  finally Query.Free; end;
  DB.ExecSQL('CREATE TEMP TABLE InpxCompressionRestores(BookID INTEGER PRIMARY KEY,BookSize INTEGER NOT NULL)');
  HasCopies:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogBookCopies''')<>0;
  if HasCopies then DB.ExecSQL('CREATE TEMP TABLE InpxCompressionCopyRestores(SourceKey TEXT PRIMARY KEY,BookSize INTEGER NOT NULL) WITHOUT ROWID');
  // INPX may spell the same archive with different slashes or a ZIP/7z alias.
  // Prove the rebuilt row's physical source instead of trusting its folder text
  // or borrowing a size solely because the publisher reused a library ID.
  Sources:=TDictionary<string,string>.Create;
  ImageMatches:=TDictionary<string,Boolean>.Create;
  Query:=nil;
  try
    SQL:='SELECT BookID,'+IdentitySQL+' AS Identity,Folder,FileName,Ext,InsideNo,0 AS Kind,'''' AS Root,'''' AS CopyKey FROM Books';
    if HasCopies then SQL:=SQL+' UNION ALL SELECT BookID,SourceKey,Folder,FileName,coalesce(Ext,''''),InsideNo,1,Root,SourceKey FROM CatalogBookCopies';
    Query:=DB.NewQuery('SELECT b.BookID,b.Folder,b.FileName,b.Ext,b.InsideNo,'+
      's.BookSize,c.SourceIdentity,c.ImageStamp,c.SourcesJSON,b.Kind,b.Root,b.CopyKey FROM ('+SQL+') b '+
      'JOIN temp.InpxCompressedSizes s ON s.Identity=b.Identity AND s.Kind=b.Kind '+
      'AND s.FileName=b.FileName AND s.Ext=b.Ext '+
      'JOIN temp.InpxCompressionSources c ON c.FileKey=s.FileKey AND c.ImageStamp=s.ImageStamp');
    Query.Open;
    while not Query.Eof do
    begin
      Book:=Default(TBookRecord); Book.CollectionRoot:=Query.FieldAsString(10);
      if Book.CollectionRoot='' then Book.CollectionRoot:=Root;
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
      var ImagesValid:=True;
      if (Source<>'') and (Query.FieldAsString(7)<>'') then
      begin
        var Key:=UpperCase(ExpandFileName(Source))+#0+Query.FieldAsString(7);
        if not ImageMatches.TryGetValue(Key,ImagesValid) then
        begin
          ImagesValid:=CompressionImageSnapshotMatches(Source,Query.FieldAsString(8),False);
          ImageMatches.Add(Key,ImagesValid);
        end;
      end;
      if (Actual<>'') and (Actual=Query.FieldAsString(6)) and ImagesValid then
        if Query.FieldAsInt(9)=0 then
          DB.ExecSQL('INSERT OR REPLACE INTO temp.InpxCompressionRestores VALUES(?,?)',
            [Query.FieldAsInt(0),Query.FieldAsInt(5)])
        else
          DB.ExecSQL('INSERT OR REPLACE INTO temp.InpxCompressionCopyRestores VALUES(?,?)',
            [Query.FieldAsString(11),Query.FieldAsInt(5)]);
      Query.Next;
    end;
  finally ImageMatches.Free; Query.Free; Sources.Free; end;
  {$IFDEF MHL_COMPRESSION_TEST}
  Writeln('TRACE compressed size restores=',DB.QuerySingleInt('SELECT count(*) FROM temp.InpxCompressionRestores'));
  {$ENDIF}
  DB.ExecSQL('UPDATE Books SET BookSize=(SELECT BookSize FROM temp.InpxCompressionRestores r '+
    'WHERE r.BookID=Books.BookID) WHERE BookID IN (SELECT BookID FROM temp.InpxCompressionRestores)');
  if HasCopies then
  begin
    DB.ExecSQL('UPDATE CatalogBookCopies SET BookSize=(SELECT BookSize FROM temp.InpxCompressionCopyRestores r '+
      'WHERE r.SourceKey=CatalogBookCopies.SourceKey) WHERE SourceKey IN (SELECT SourceKey FROM temp.InpxCompressionCopyRestores)');
    DB.ExecSQL('DROP TABLE temp.InpxCompressionCopyRestores');
  end;
  DB.ExecSQL('DROP TABLE temp.InpxCompressionRestores');
  DB.ExecSQL('DROP TABLE temp.InpxCompressedSizes');
  DB.ExecSQL('DROP TABLE temp.InpxCompressionSources');
end;

end.
