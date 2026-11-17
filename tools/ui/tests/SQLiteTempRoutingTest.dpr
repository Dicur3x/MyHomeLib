program SQLiteTempRoutingTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  Winapi.Windows, SQLite3, SQLiteWrap, SQLiteTempVFS, unit_BookCompressionPlanStore;

function FindVFS(Name:PUTF8Char):PSQLiteVFS; cdecl; external SQLiteDLL name 'sqlite3_vfs_find';

function Native(const Path:string):string;
begin
  Result:=TPath.GetFullPath(Path);
  if not Result.StartsWith('\\?\') then Result:='\\?\'+Result;
end;

procedure Require(Value:Boolean; const Message:string);
begin if not Value then raise EReadError.Create(Message); end;

function TempFiles(const Folder:string):Integer;
begin Result:=Length(TDirectory.GetFiles(Native(Folder),'sqlite-temp-*')); end;

procedure FillTemp(DB:TSQLiteDatabase);
begin
  DB.ExecSQL('PRAGMA temp_store=FILE'); DB.ExecSQL('PRAGMA temp.cache_size=8');
  DB.ExecSQL('CREATE TEMP TABLE TempRows AS WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<12000) '+
    'SELECT x,zeroblob(2048) AS p FROM n');
  Require(DB.QuerySingleInt('SELECT sum(x) FROM TempRows')=72006000,'Temporary data changed');
  Require(DB.TemporaryFilesCreated>0,'No anonymous file reached the connection VFS');
end;

procedure ReadSort(DB:TSQLiteDatabase);
begin
  DB.ExecSQL('PRAGMA temp_store=FILE'); DB.ExecSQL('PRAGMA temp.cache_size=8');
  var ID:=DB.QuerySingleInt('SELECT x FROM MainRows ORDER BY p,x DESC');
  Require((ID>=1) and (ID<=12000),'Readonly sort changed data');
  Require(DB.TemporaryFilesCreated>0,'Readonly sort did not spill');
end;

var Root,First,Second,OSTemp,BeforeTemp,BeforeTmp,Mode:string; DB,Other:TSQLiteDatabase;
    Output:TJSONObject; DefaultVFS:PSQLiteVFS;
begin
  DB:=nil; Other:=nil; Output:=nil;
  try
    Root:=TPath.GetFullPath(ParamStr(1)); Mode:=ParamStr(2);
    Require(Root.StartsWith('G:\HL-b14-external\',True),'Only the owned G: fixture is allowed');
    Require(TFile.ReadAllText(TPath.Combine(Root,'sqlite-temp-regression.marker'),TEncoding.UTF8)=
      'HomeLibre SQLite temporary routing regression v1','Missing private marker');
    OSTemp:=GetEnvironmentVariable('TEMP'); BeforeTemp:=OSTemp; BeforeTmp:=GetEnvironmentVariable('TMP');
    DefaultVFS:=FindVFS(nil); Require(DefaultVFS<>nil,'No default VFS');
    First:=TPath.Combine(Root,'Первая папка # %'); Second:=TPath.Combine(Root,'Вторая папка');
    TDirectory.CreateDirectory(First); TDirectory.CreateDirectory(Second);
    Output:=TJSONObject.Create;
    if Mode='two-roots' then
    begin
      DB:=TSQLiteDatabase.Create(TPath.Combine(Root,'first.sqlite'),False,False,First);
      Other:=TSQLiteDatabase.Create(TPath.Combine(Root,'second.sqlite'),False,False,Second);
      FillTemp(DB); FillTemp(Other);
      Require((TempFiles(First)>0) and (TempFiles(Second)>0),'Temporary files are outside their connection roots');
      Require(Length(TDirectory.GetFiles(OSTemp))=0,'Process temp directory was used');
      Output.AddPair('first_files',TJSONNumber.Create(DB.TemporaryFilesCreated));
      Output.AddPair('second_files',TJSONNumber.Create(Other.TemporaryFilesCreated));
      FreeAndNil(DB); FreeAndNil(Other);
      Require((TempFiles(First)=0) and (TempFiles(Second)=0),'Closed connections retained temporary files');
    end
    else if Mode='plan-store' then
    begin
      var Plan:=TCompressionPlanStore.Create(First);
      var Folder:=Plan.Folder;
      try
        FillTemp(Plan.DB); Require(TempFiles(Folder)>0,'Plan spill is outside its work folder');
        Plan.DB.ExecSQL('CREATE TABLE MainRows AS SELECT * FROM TempRows'); Plan.Seal;
        Require(TempFiles(Folder)=0,'Sealing did not release the old temp database');
        ReadSort(Plan.DB);
        Plan.Edit(procedure(Value:TSQLiteDatabase) begin FillTemp(Value); end);
        ReadSort(Plan.DB);
        Output.AddPair('sealed_files',TJSONNumber.Create(Plan.DB.TemporaryFilesCreated));
      finally Plan.Free; end;
      Require(not TDirectory.Exists(Native(Folder)),'Plan folder was not cleaned');
    end
    else if Mode='locks' then
    begin
      var FileName:=TPath.Combine(Root,'shared.sqlite');
      DB:=TSQLiteDatabase.Create(FileName,True,False,First);
      DB.ExecSQL('CREATE TABLE MainRows(x INTEGER PRIMARY KEY,p BLOB)');
      Other:=TSQLiteDatabase.Create(FileName); Other.SetTimeout(250);
      DB.ExecSQL('BEGIN IMMEDIATE'); var Busy:=False;
      try Other.ExecSQL('BEGIN IMMEDIATE'); except on E:ESQLiteException do Busy:=True; end;
      Require(Busy,'Custom and default VFS connections bypassed writer locks');
      DB.Rollback; Other.ExecSQL('BEGIN IMMEDIATE'); Other.Rollback;
      Output.AddPair('lock_refused',TJSONBool.Create(Busy));
    end
    else if Mode='no-fallback' then
    begin
      DB:=TSQLiteDatabase.Create(TPath.Combine(Root,'refused.sqlite'),False,False,First);
      var SavedSystem:=GetEnvironmentVariable('SystemDrive'); var Refused:=False;
      Require(SetEnvironmentVariable('SystemDrive',PChar(TPath.Combine(Root,'missing-volume'))),'Cannot inject private volume-query failure');
      try
        try FillTemp(DB); except on E:ESQLiteException do Refused:=True; end;
      finally SetEnvironmentVariable('SystemDrive',PChar(SavedSystem)); end;
      Require(Refused,'Temporary storage failure was ignored');
      Require(DB.TemporaryFilesCreated=0,'A file was allocated after the reserve check failed');
      Require((TempFiles(First)=0) and (Length(TDirectory.GetFiles(OSTemp))=0),'Failure fell back to another temp folder');
      Output.AddPair('fallback_refused',TJSONBool.Create(Refused));
    end
    else if Mode='long-path' then
    begin
      for var I:=1 to 5 do First:=TPath.Combine(First,StringOfChar('x',60));
      ForceDirectories(Native(First));
      DB:=TSQLiteDatabase.Create(TPath.Combine(Root,'long.sqlite'),False,False,First);
      FillTemp(DB); Require(TempFiles(First)>0,'Long temporary path was not used');
      FreeAndNil(DB); Require(TempFiles(First)=0,'Long-path temporary file remained');
    end
    else raise EArgumentException.Create('Unknown native mode');
    FreeAndNil(DB); FreeAndNil(Other);
    Require(FindVFS(nil)=DefaultVFS,'Default SQLite VFS changed');
    Require((BeforeTemp=GetEnvironmentVariable('TEMP')) and (BeforeTmp=GetEnvironmentVariable('TMP')),'Process temp environment changed');
    Output.AddPair('status','PASS'); Output.AddPair('mode',Mode);
    TFile.WriteAllText(TPath.Combine(Root,'result.json'),Output.ToJSON,TEncoding.UTF8);
    Writeln('PASS SQLite temporary routing');
  except on E:Exception do begin Writeln(E.ClassName+': '+E.Message); ExitCode:=1; end; end;
  Output.Free; Other.Free; DB.Free;
end.
