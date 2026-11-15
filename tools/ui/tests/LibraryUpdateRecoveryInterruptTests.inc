procedure PrepareLibraryRecoveryInterruptProbe(const Collection:IBookCollection);
var DB:TSQLiteDatabase;
begin
  if not FileExists(Settings.AppPath+'library-recovery-interrupt.json') then Exit;
  DB:=TSQLiteDatabase.Create(VarToStr(Collection.GetProperty(PROP_DATAFILE)));
  try
    DB.ExecSQL('CREATE TABLE RecoveryInterruptProbe(ID INTEGER PRIMARY KEY,Payload BLOB NOT NULL)');
    DB.ExecSQL('INSERT INTO RecoveryInterruptProbe VALUES(1,zeroblob(4194304))');
  finally DB.Free; end;
end;

procedure VerifyLibraryRecoveryInterruptProbe(const Collection:IBookCollection);
var DB:TSQLiteDatabase;
begin
  if not FileExists(Settings.AppPath+'library-recovery-interrupt.json') then Exit;
  DB:=TSQLiteDatabase.CreateReadOnly(VarToStr(Collection.GetProperty(PROP_DATAFILE)));
  try
    Require(DB.QuerySingleInt('SELECT count(*) FROM RecoveryInterruptProbe WHERE ID=1 AND Payload=zeroblob(4194304)')=1,
      'Interrupted recovery changed its complete multi-step database payload');
  finally DB.Free; end;
end;

procedure ArmLibraryRecoveryInterrupt;
{$IFDEF MHL_COMPRESSION_TEST}
var Root,Phase:string; Config:TJSONObject;
begin
  if not ((ParamStr(1)='library-update-recovery-open') or (ParamStr(1)='library-flibrary-recovery-open')) then Exit;
  Root:=ExtractFilePath(ParamStr(0));
  if not FileExists(Root+'library-recovery-interrupt-arm.json') then Exit;
  Config:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Root+'library-recovery-interrupt-arm.json',TEncoding.UTF8)) as TJSONObject;
  try Phase:=Config.GetValue<string>('phase'); finally Config.Free; end;
  LibraryUpdateRecoveryTestPoint:=procedure(Point:string; Copied,Total:Integer)
  var Proof:TJSONObject;
  begin
    if Point<>Phase then Exit;
    Proof:=TJSONObject.Create;
    try
      Proof.AddPair('phase',Point); Proof.AddPair('copied',TJSONNumber.Create(Copied)); Proof.AddPair('total',TJSONNumber.Create(Total));
      TFile.WriteAllText(Root+'library-recovery-interrupt-crash.json',Proof.ToJSON,TEncoding.UTF8);
    finally Proof.Free; end;
    Writeln('TRACE actual library recovery terminated at ',Point,' pages ',Copied,'/',Total); Flush(Output);
    if not TerminateProcess(GetCurrentProcess,74) then RaiseLastOSError;
  end;
end;
{$ELSE}
begin end;
{$ENDIF}
