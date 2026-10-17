// Managed payload identity: reuse is safe only while a real deny-write stream
// protects the bytes. Dependencies remain independently mutable and validated.
procedure TestReaderCachePerformance;
const WarmCalls = 12; DeleteAccess = $00010000;
var Source, Name, Temporary, TemporaryStamp, Stamp, ChangedStamp, OriginalHash: string;
  Payload: TBytes; Writer: TBookCacheWrite; Input, OtherInput: TStream;
  LockedWriter: TFileStream; Blocked, Canceled: Boolean; Worker: TThread;
  Started, ColdMS, WarmMS: UInt64;
  ByteValue: Byte;
  ReplaceHandle: THandle;
begin
  RequireIsolatedRegression;
  Require(TPath.GetFullPath(Settings.AppPath).StartsWith('G:\',True),
    'Cache identity performance gate must remain in its private G runtime');
  Source:=TPath.Combine(Settings.AppPath,'cache-performance-original.zip');
  TFile.WriteAllText(Source,'Protected physical original',TEncoding.UTF8);
  OriginalHash:=THashSHA2.GetHashStringFromFile(Source);
  Require(ForceDirectories(BookCachePath),'Could not create the private cache identity fixture');
  Name:=TPath.Combine(BookCachePath,'homelib-identity-'+TGUID.NewGuid.ToString+'.bin');
  SetLength(Payload,8*1024*1024); FillChar(Payload[0],Length(Payload),$31);
  Writer:=TBookCacheWrite.Create(Source);
  try
    Temporary:=Writer.TemporaryName(Name); TemporaryStamp:=Writer.TemporaryName(Name+'.source');
    TFile.WriteAllBytes(Temporary,Payload); Payload:=nil;
    TFile.WriteAllText(TemporaryStamp,'Dependency A',TEncoding.UTF8);
    Writer.Publish(Temporary,Name,TemporaryStamp);
  finally Writer.Free; end;
  Input:=OpenCachedBookFile(Name); OtherInput:=nil;
  try
    Started:=GetTickCount64; Stamp:=BookCacheInputStamp(Name,Source); ColdMS:=GetTickCount64-Started;
    Started:=GetTickCount64;
    for var I:=1 to WarmCalls do
      Require(BookCacheInputStamp(Name,Source)=Stamp,'Held input changed its verified identity');
    WarmMS:=GetTickCount64-Started;
    Writeln('PROFILE managed input 8MB cold_ms=',ColdMS,' warm_12_ms=',WarmMS);
    Flush(Output);
    TFile.WriteAllText(Name+'.source','Dependency B',TEncoding.UTF8);
    Require(BookCacheInputStamp(Name,Source)<>Stamp,'Held input reused changed dependency metadata');
    TFile.WriteAllText(Name+'.source','Dependency A',TEncoding.UTF8);
    Require(BookCacheInputStamp(Name,Source)=Stamp,'Restored dependency did not restore exact identity');
    Blocked:=False; LockedWriter:=nil;
    try
      try LockedWriter:=TFileStream.Create(Name,fmOpenWrite or fmShareDenyNone);
      except on E: EFOpenError do Blocked:=True; end;
    finally LockedWriter.Free; end;
    Require(Blocked,'Performance fixture failed to hold a real native deny-write input');
    ReplaceHandle:=CreateFile(PChar(Name),DeleteAccess,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    if ReplaceHandle<>INVALID_HANDLE_VALUE then CloseHandle(ReplaceHandle);
    Require(ReplaceHandle=INVALID_HANDLE_VALUE,'Held payload permits replacement through a native delete-access handle');
    OtherInput:=OpenCachedBookFile(UpperCase(Name)); FreeAndNil(Input);
    Require(BookCacheInputStamp(Name,Source)=Stamp,'Closing one of two held readers lost the verified identity');
    Canceled:=False;
    Worker:=TThread.CreateAnonymousThread(procedure
      begin
        TThread.CurrentThread.Terminate;
        try BookCacheInputStamp(Name,Source);
        except on E: EAbort do Canceled:=True; end;
      end);
    Worker.FreeOnTerminate:=False;
    try Worker.Start; Worker.WaitFor; finally Worker.Free; end;
    Require(Canceled,'Warm identity bypassed a terminated preparation worker');
  finally OtherInput.Free; Input.Free; end;
  LockedWriter:=TFileStream.Create(Name,fmOpenReadWrite or fmShareDenyWrite);
  try
    LockedWriter.Position:=LockedWriter.Size-1;
    ByteValue:=$32; LockedWriter.WriteBuffer(ByteValue,1);
  finally LockedWriter.Free; end;
  Input:=OpenCachedBookFile(Name);
  try
    ChangedStamp:=BookCacheInputStamp(Name,Source);
    Require(ChangedStamp<>Stamp,'Last reader release retained a hash across same-size payload replacement');
    Require(BookCacheInputStamp(Name,Source)=ChangedStamp,'Reopened input identity is unstable');
  finally Input.Free; end;
  Stamp:=BookCacheInputStamp(Name,Source);
  LockedWriter:=TFileStream.Create(Name,fmOpenReadWrite or fmShareDenyWrite);
  try
    LockedWriter.Position:=LockedWriter.Size-1;
    ByteValue:=$33; LockedWriter.WriteBuffer(ByteValue,1);
  finally LockedWriter.Free; end;
  Require(BookCacheInputStamp(Name,Source)<>Stamp,'Unheld input reused a digest after its payload changed');
  Require(THashSHA2.GetHashStringFromFile(Source)=OriginalHash,'Identity profiling changed the physical original');
  Writeln('PASS managed input identity preserves native locks, dependency edits, overlapping readers, cancellation and same-size replacement after release');
  Flush(Output);
  Require(WarmMS<ColdMS*WarmCalls div 2+25,
    Format('Managed input repeatedly hashes protected unchanged payload: cold=%d warm12=%d',
      [ColdMS,WarmMS]));
  Writeln('PASS held managed input avoids repeated full payload scans');
  Flush(Output);
end;
