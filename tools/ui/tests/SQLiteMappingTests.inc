procedure TestSQLiteMapping;
const Count = 260; LabelText = 'Книга Ёжик — 日本語';
var DB, Writer: TSQLiteDatabase; Query: TSQLiteQuery;
  FileName, BackupFile: string; Seen: Integer; LargeSize: Int64;
begin
  RequireIsolatedRegression;
  FileName:=TPath.Combine(Settings.AppPath,'mapped-fixture.db');
  BackupFile:=TPath.Combine(Settings.AppPath,'mapped-backup.db');
  DB:=TSQLiteDatabase.Create(FileName); Writer:=nil; Query:=nil;
  try
{$IFDEF WIN64}
    Require(DB.QuerySingleInt('PRAGMA mmap_size')=2147418112,'Win64 read map limit was not applied');
{$ELSE}
    Require(DB.QuerySingleInt('PRAGMA mmap_size')=67108864,'Win32 map exceeded its address-space limit');
{$ENDIF}
    DB.ExecSQL('CREATE TABLE MappingProbe(ID INTEGER PRIMARY KEY,Label TEXT,Payload BLOB)');
    DB.Start;
    try
      for var I:=1 to Count do
        DB.ExecSQL('INSERT INTO MappingProbe VALUES(?,?,zeroblob(1048576))',[I,LabelText]);
      DB.Commit;
    except DB.Rollback; raise; end;
    Require(DB.QuerySingleInt('PRAGMA wal_checkpoint(TRUNCATE)')=0,'Large map fixture checkpoint failed');
    LargeSize:=TFile.GetSize(FileName);
    Require(LargeSize>268435456,'Regression did not exercise pages past the former Win64 map limit');
    Query:=DB.NewQuery('SELECT ID,Label,hex(substr(Payload,1048576,1)) FROM MappingProbe ORDER BY ID');
    Query.Open; Seen:=0;
    Writer:=TSQLiteDatabase.Create(FileName);
    // The streaming reader must keep its old snapshot while a separate
    // connection commits to a row whose original page is beyond 256 MB.
    Writer.ExecSQL('UPDATE MappingProbe SET Label=? WHERE ID=?',['Обновлённая книга',Count]);
    while not Query.Eof do
    begin
      Inc(Seen);
      Require((Query.FieldAsInt(0)=Seen) and (Query.FieldAsString(1)=LabelText) and
        (Query.FieldAsString(2)='00'),'Mapped snapshot changed, lost Unicode or read the wrong overflow page');
      Query.Next;
    end;
    FreeAndNil(Query);
    Require(Seen=Count,'Mapped scan lost rows');
    Require(DB.QuerySingleString('SELECT Label FROM MappingProbe WHERE ID=260')='Обновлённая книга',
      'New mapped query did not observe a committed write');
    Writer.Start;
    Writer.ExecSQL('UPDATE MappingProbe SET Label=''rollback'' WHERE ID=260');
    Writer.Rollback;
    Require(DB.QuerySingleString('SELECT Label FROM MappingProbe WHERE ID=260')='Обновлённая книга',
      'Mapped connection ignored transaction rollback');
    FreeAndNil(Writer);
    DB.BackupTo(BackupFile);
    DB.ExecSQL('DELETE FROM MappingProbe WHERE ID>1');
    DB.RestoreFrom(BackupFile);
    Require((DB.QuerySingleInt('SELECT COUNT(*) FROM MappingProbe')=Count) and
      (DB.QuerySingleString('SELECT Label FROM MappingProbe WHERE ID=260')='Обновлённая книга'),
      'Backup/restore changed mapped catalogue records');
    Require(DB.QuerySingleString('PRAGMA integrity_check')='ok','Mapped restore failed integrity check');
    DB.ExecSQL('DELETE FROM MappingProbe WHERE ID>1');
    DB.CompactDatabase;
    Require(DB.QuerySingleInt('PRAGMA wal_checkpoint(TRUNCATE)')=0,'Mapped compaction checkpoint failed');
    Require((TFile.GetSize(FileName)<LargeSize div 4) and
      (DB.QuerySingleInt('SELECT COUNT(*) FROM MappingProbe')=1),
      'Mapped database did not shrink after its readers closed');
    Require(DB.QuerySingleString('PRAGMA integrity_check')='ok','Mapped compaction damaged the database');
    Writeln('PASS SQLite mapped reads beyond 256 MB preserve concurrent snapshots Unicode rollback backup restore and compaction');
  finally Query.Free; Writer.Free; DB.Free; end;
end;
