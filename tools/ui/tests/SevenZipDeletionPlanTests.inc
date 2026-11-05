procedure TestSevenZipDeletionPlan;
var Root, ArchivePath, BeforeHash: string; Source, Target:TFileStream;
  Layout:TSevenZipDeletionLayout; Bytes:TBytes; Hash:THashSHA2; Rejected:Boolean;
begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath+'sevenzip-delete-plan\';
  for var Kind in ['ppmd','lzma2'] do
  begin
    ArchivePath:=Root+Kind+'.7z'; BeforeHash:=THashSHA2.GetHashStringFromFile(ArchivePath);
    Source:=TFileStream.Create(ArchivePath,fmOpenRead or fmShareDenyWrite);
    try
      // Planning is physically incapable of writing this read-only handle.
      Layout:=PlanSevenZipDeletion(Source,['selected\one.fb2','selected/two.fb2']);
      Require((Length(Layout.Remaining)>=1) and (Layout.FinalSize<Source.Size) and
        (Length(Layout.Header)=32) and (Length(Layout.Tail)<128*1024),
        '7z planner did not produce a bounded deletion layout');
      Target:=TFileStream.Create(Root+'planned-'+Kind+'.7z',fmCreate);
      try
        Target.WriteBuffer(Layout.Header[0],Length(Layout.Header));
        for var Range in Layout.Ranges do
        begin
          Require((Range.Bytes<=4*1024*1024) and (Range.Source>=Range.Target),'Unbounded or right-moving 7z payload');
          SetLength(Bytes,Range.Bytes); Source.Position:=Range.Source;
          Source.ReadBuffer(Bytes[0],Length(Bytes)); Hash:=THashSHA2.Create; Hash.Update(Bytes);
          Require(Hash.HashAsString=Range.SHA256,'7z planned compressed block hash differs');
          Target.Position:=Range.Target; Target.WriteBuffer(Bytes[0],Length(Bytes));
        end;
        Target.Position:=Layout.TailOffset;
        if Length(Layout.Tail)>0 then Target.WriteBuffer(Layout.Tail[0],Length(Layout.Tail));
        Target.Size:=Layout.FinalSize;
        VerifySevenZipInventory(Target,Layout.Remaining);
      finally Target.Free; end;
    finally Source.Free; end;
    Require(THashSHA2.GetHashStringFromFile(ArchivePath)=BeforeHash,'7z planning changed its original archive');
  end;
  Writeln('PASS read-only 7z deletion planner retains original compressed blocks and metadata with bounded virtual output'); Flush(Output);
  ArchivePath:=Root+'solid.7z'; BeforeHash:=THashSHA2.GetHashStringFromFile(ArchivePath);
  Source:=TFileStream.Create(ArchivePath,fmOpenRead or fmShareDenyWrite);
  try
    Rejected:=False;
    try Layout:=PlanSevenZipDeletion(Source,['selected/one.fb2']);
    except on E:ENotSupportedException do Rejected:=Pos('solid',E.Message)>0; end;
    Require(Rejected,'7z planner silently re-encoded a partial solid block');
  finally Source.Free; end;
  Require(THashSHA2.GetHashStringFromFile(ArchivePath)=BeforeHash,'Rejected solid plan changed the archive');
  Writeln('PASS partial solid 7z removal is rejected before any source mutation'); Flush(Output);
end;
