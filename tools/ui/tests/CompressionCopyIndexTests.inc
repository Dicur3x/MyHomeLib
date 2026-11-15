procedure TestCompressionCopyIndexBoundaries;
var Root,A,B,C,Identity,Key:string; DB:TSQLiteDatabase; SizeA,SizeB:Integer;
  procedure Archive(const Path,Text:string);
  var Zip:TZipFile;
  begin ForceDirectories(TPath.GetDirectoryName(Path)); Zip:=TZipFile.Create;
    try Zip.Open(Path,zmWrite); Zip.Add(TEncoding.UTF8.GetBytes(Text),'same.txt'); finally Zip.Free; end; end;
  procedure Witness(const Path,Text:string);
  var Hash:string; Hasher:THashSHA2; Bytes:TBytes;
  begin
    Identity:=ArchiveDeletionSourceIdentity(Path); Key:=UpperCase(Copy(Identity,1,25));
    Bytes:=TEncoding.UTF8.GetBytes(Text); Hasher:=THashSHA2.Create; Hasher.Update(Bytes); Hash:=Hasher.HashAsString;
    DB.ExecSQL('INSERT INTO HomeLibreBookCompression VALUES(?,?,?,?,?)',[Key,'same.txt',Length(TEncoding.UTF8.GetBytes(Text)),Hash,'different-input']);
    DB.ExecSQL('INSERT INTO HomeLibreCompressionChecks VALUES(?,?,?,?)',[Key,'same.txt',Identity,Hash]);
  end;
  procedure Seed;
  begin
    DB.ExecSQL('DELETE FROM Books'); DB.ExecSQL('DELETE FROM CatalogBookCopies');
    DB.ExecSQL('DELETE FROM HomeLibreBookCompression'); DB.ExecSQL('DELETE FROM HomeLibreCompressionChecks');
    Archive(A,'compressed A'); Archive(B,'another compressed B'); Archive(C,'unrelated C');
    SizeA:=Length(TEncoding.UTF8.GetBytes('compressed A')); SizeB:=Length(TEncoding.UTF8.GetBytes('another compressed B'));
    Witness(A,'compressed A'); Witness(B,'another compressed B');
    DB.ExecSQL('INSERT INTO Books VALUES(1,''same-id'',?,''same'',''.txt'',0,?)',[A,SizeA]);
    // Deliberately collide one copy's source key with the main row's identity.
    DB.ExecSQL('INSERT INTO CatalogBookCopies VALUES(''same-id'',1,?,''same.zip'',''same'',''.txt'',0,?)',[IncludeTrailingPathDelimiter(TPath.GetDirectoryName(A)),SizeA]);
    DB.ExecSQL('INSERT INTO CatalogBookCopies VALUES(''source-B'',1,?,''same.zip'',''same'',''.txt'',0,?)',[IncludeTrailingPathDelimiter(TPath.GetDirectoryName(B)),SizeB]);
  end;
  procedure BeginRefresh;
  begin CaptureCompressionIndexSizes(DB,Root,'LibID'); DB.ExecSQL('UPDATE Books SET BookSize=999'); DB.ExecSQL('UPDATE CatalogBookCopies SET BookSize=999'); end;
  procedure FinishRefresh(ExpectedB:Integer; const Name:string);
  begin
    RestoreCompressionIndexSizes(DB,Root,'LibID');
    Require((DB.QuerySingleInt('SELECT BookSize FROM Books')=SizeA) and
      (DB.QuerySingleInt('SELECT BookSize FROM CatalogBookCopies WHERE SourceKey=''same-id''')=SizeA) and
      (DB.QuerySingleInt('SELECT BookSize FROM CatalogBookCopies WHERE SourceKey=''source-B''')=ExpectedB),
      'Compressed-copy boundary failed: '+Name);
    Require(DB.QuerySingleInt('SELECT count(*) FROM sqlite_temp_master WHERE name LIKE ''InpxCompress%''')=0,
      'Copy-size tracking leaked temporary tables: '+Name);
  end;
begin
  Root:=Settings.AppPath+'compression-copy-boundaries\'; ForceDirectories(Root);
  A:=Root+'A\same.zip'; B:=Root+'B\same.zip'; C:=Root+'C\same.zip';
  DB:=TSQLiteDatabase.Create(Root+'index.sqlite');
  try
    DB.ExecSQL('CREATE TABLE Books(BookID INTEGER PRIMARY KEY,LibID TEXT,Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER)');
    DB.ExecSQL('CREATE TABLE CatalogBookCopies(SourceKey TEXT PRIMARY KEY,BookID INTEGER,Root TEXT,Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER)');
    DB.ExecSQL('CREATE TABLE HomeLibreBookCompression(FileKey TEXT,Member TEXT,BookSize INTEGER,OutputSHA256 TEXT,InputSHA256 TEXT)');
    DB.ExecSQL('CREATE TABLE HomeLibreCompressionChecks(FileKey TEXT,Member TEXT,SourceIdentity TEXT,PayloadSHA256 TEXT)');
    Seed; BeginRefresh; FinishRefresh(SizeB,'same-name archives and colliding card/copy identities');
    Seed; BeginRefresh; DB.ExecSQL('UPDATE CatalogBookCopies SET Root=? WHERE SourceKey=''source-B''',[IncludeTrailingPathDelimiter(TPath.GetDirectoryName(C))]);
    FinishRefresh(999,'reused source key at another physical archive');
    Seed; BeginRefresh; TFile.AppendAllText(B,'changed after capture',TEncoding.ASCII);
    FinishRefresh(999,'archive changed during the update');
    Seed; DB.ExecSQL('UPDATE HomeLibreCompressionChecks SET SourceIdentity=''stale'' WHERE FileKey=?',[Key]);
    BeginRefresh; FinishRefresh(999,'stale physical witness before capture');
    Seed; DB.ExecSQL('UPDATE HomeLibreCompressionChecks SET PayloadSHA256=''wrong'' WHERE FileKey=?',[Key]);
    BeginRefresh; FinishRefresh(999,'payload proof mismatch');
    Seed; DB.ExecSQL('UPDATE HomeLibreBookCompression SET BookSize=-1 WHERE FileKey=?',[Key]);
    BeginRefresh; FinishRefresh(999,'unknown size cannot replace publisher metadata');
    Seed; DB.ExecSQL('UPDATE HomeLibreBookCompression SET InputSHA256=OutputSHA256 WHERE FileKey=?',[Key]);
    BeginRefresh; FinishRefresh(999,'unchanged legacy inspection is not a measured size');
    Seed; DB.ExecSQL('UPDATE CatalogBookCopies SET FileName=''same.txt'',Ext=NULL WHERE SourceKey=''source-B''');
    BeginRefresh; FinishRefresh(SizeB,'NULL copy extension with a complete member name');
    Seed; DB.ExecSQL('UPDATE CatalogBookCopies SET Root=NULL,Folder=''B\same.zip'' WHERE SourceKey=''source-B''');
    BeginRefresh; FinishRefresh(SizeB,'NULL copy root falls back to the collection root');
    Seed; DB.Start; BeginRefresh; DB.Rollback;
    Require((DB.QuerySingleInt('SELECT BookSize FROM CatalogBookCopies WHERE SourceKey=''source-B''')=SizeB) and
      (DB.QuerySingleInt('SELECT count(*) FROM sqlite_temp_master WHERE name LIKE ''InpxCompress%''')=0),
      'Rolled-back copy update changed sizes or leaked its capture');
    Writeln('PASS ten compressed-copy boundaries preserve independent physical witnesses nullable locators and rollback');
  finally DB.Free; end;
end;
