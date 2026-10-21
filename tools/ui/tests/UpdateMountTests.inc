// A private filesystem fixture mounts only the same TEMP volume. No drive
// letters or mount-manager entries are changed; every link is detached first.
procedure TestUpdateMountedVolume;
var Volume: array[0..63] of Char; Mount, AliasRoot, Target, TargetAlias, Job, JobAlias,
  Archive, Outside, HelpName, Nested, Link: string; Root: TJSONObject; Items: TJSONArray;
  Zip: TZipFile; Rejected: Boolean;
  procedure Attach(const Path, Substitute: string);
  var Handle: THandle; Bytes, Text: TBytes; Returned: DWORD;
    procedure WordAt(Offset: Integer; Value: Word);
    begin Move(Value,Bytes[Offset],SizeOf(Value)); end;
  begin
    Require(not DirectoryExists(Path),'Mount fixture already exists'); ForceDirectories(Path);
    Handle:=CreateFile(PChar(Path),GENERIC_WRITE,FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS,0);
    if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
    try
      Text:=TEncoding.Unicode.GetBytes(Substitute); SetLength(Bytes,20+Length(Text));
      PDWORD(@Bytes[0])^:=$A0000003; WordAt(4,12+Length(Text));
      WordAt(8,0); WordAt(10,Length(Text)); WordAt(12,Length(Text)+2); WordAt(14,0);
      Move(Text[0],Bytes[16],Length(Text));
      if not DeviceIoControl(Handle,$000900A4,@Bytes[0],Length(Bytes),nil,0,Returned,nil) then RaiseLastOSError;
    finally CloseHandle(Handle); end;
  end;
  procedure Detach(const Path: string);
  var Handle: THandle; Header: array[0..1] of DWORD; Returned: DWORD;
  begin
    if not DirectoryExists(Path) then Exit;
    Handle:=CreateFile(PChar(Path),GENERIC_WRITE,FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_BACKUP_SEMANTICS,0);
    if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
    try
      Header[0]:=$A0000003; Header[1]:=0;
      if not DeviceIoControl(Handle,$000900AC,@Header[0],SizeOf(Header),nil,0,Returned,nil) then RaiseLastOSError;
    finally CloseHandle(Handle); end;
    Require(RemoveDir(Path),'Cannot remove detached fixture');
  end;
  procedure Add(const Name, Value: string);
  var FileName: string;
  begin
    FileName:=Settings.AppPath+'mount-payload-'+IntToStr(Items.Count);
    TFile.WriteAllText(FileName,Value,TEncoding.UTF8); Zip.Add(FileName,Name);
    Items.AddElement(TJSONObject.Create.AddPair('path',Name).AddPair('size',TJSONNumber.Create(TFile.GetSize(FileName))).AddPair('sha256',UpdateSHA256(FileName)));
  end;
  procedure MustRejectInstall(const Reason: string);
  begin
    Rejected:=False;
    try InstallProgramUpdate(JobAlias,TargetAlias); except on E: Exception do Rejected:=E.Message.Contains('ссылку'); end;
    Require(Rejected,Reason);
    Require(TFile.ReadAllText(Outside,TEncoding.UTF8)='outside sentinel','A redirected update escaped the private target');
    Require(TFile.ReadAllText(Target+'\HomeLibRu.exe',TEncoding.UTF8)='old application','Preflight changed the application before rejecting a child link');
  end;
begin
  Require(GetVolumeNameForVolumeMountPoint(PChar(IncludeTrailingPathDelimiter(ExtractFileDrive(Settings.AppPath))),Volume,Length(Volume)),
    'Cannot obtain the private TEMP volume identity');
  Mount:=Settings.AppPath+'mounted-volume'; Target:=Settings.AppPath+'mount-target'; Job:=Settings.AppPath+'HomeLibRu-update-mounted';
  Outside:=Settings.AppPath+'mount-outside\sentinel.txt'; ForceDirectories(ExtractFileDir(Outside));
  TFile.WriteAllText(Outside,'outside sentinel',TEncoding.UTF8);
  ForceDirectories(Target+'\Data'); TFile.WriteAllText(Target+'\Data\personal.txt','protected profile',TEncoding.UTF8);
  TFile.WriteAllText(Target+'\HomeLibRu.exe','old application',TEncoding.UTF8); TFile.WriteAllText(Target+'\LICENSE','old license',TEncoding.UTF8);
  AliasRoot:=Mount+'\'+Copy(Settings.AppPath,4,MaxInt); TargetAlias:=AliasRoot+'mount-target'; JobAlias:=AliasRoot+'HomeLibRu-update-mounted';
  HelpName:='Help/'+StringReplace(Copy(Outside,4,MaxInt),'\','/',[rfReplaceAll]);
  Archive:=Settings.AppPath+'mount-release.zip'; Root:=TJSONObject.Create; Zip:=TZipFile.Create;
  try
    Root.AddPair('format',TJSONNumber.Create(1)).AddPair('release','mount-test').AddPair('platform',ProgramUpdatePlatform);
    Items:=TJSONArray.Create; Root.AddPair('files',Items); Zip.Open(Archive,zmWrite);
    Add('HomeLibRu.exe','new application'); Add('LICENSE','new license'); Add('NOTICE','new notice'); Add(HelpName,'new help');
    Zip.Add(TEncoding.UTF8.GetBytes(Root.ToJSON),UPDATE_MANIFEST); Zip.Close;
  finally Zip.Free; Root.Free; end;
  Attach(Mount,'\??\'+Copy(string(Volume),5,MaxInt));
  try
    AssertUpdatePath(TargetAlias); AssertUpdatePath(JobAlias);
    PrepareProgramUpdate(Archive,UpdateSHA256(Archive),'mount-test',ProgramUpdatePlatform,JobAlias,False);
    InstallProgramUpdate(JobAlias,TargetAlias);
    Require(TFile.ReadAllText(Target+'\HomeLibRu.exe',TEncoding.UTF8)='new application','Mounted-volume install did not replace the application');
    Require(TFile.ReadAllText(Target+'\Data\personal.txt',TEncoding.UTF8)='protected profile','Mounted-volume update changed profile data');
    CleanProgramUpdate(JobAlias);
    TFile.WriteAllText(Target+'\HomeLibRu.exe','old application',TEncoding.UTF8);
    TFile.WriteAllText(Target+'\LICENSE','old license',TEncoding.UTF8);
    PrepareProgramUpdate(Archive,UpdateSHA256(Archive),'mount-test',ProgramUpdatePlatform,JobAlias,False);
    Rejected:=False;
    try InstallProgramUpdate(JobAlias,TargetAlias,nil,4);
    except on E: Exception do Rejected:=E.Message.Contains('Имитированная ошибка'); end;
    Require(Rejected,'Mounted-volume rollback fixture did not reach the final replacement');
    Require(TFile.ReadAllText(Target+'\HomeLibRu.exe',TEncoding.UTF8)='old application','Mounted-volume rollback did not restore the application');
    CleanProgramUpdate(JobAlias); Require(not DirectoryExists(Job),'Mounted-volume job did not clean up');
    Writeln('PASS real volume-GUID mount accepts update preparation, install, rollback and cleanup while preserving profile data');
    PrepareProgramUpdate(Archive,UpdateSHA256(Archive),'mount-test',ProgramUpdatePlatform,JobAlias,False);
    Nested:=Target+'\Help'; if DirectoryExists(Nested) then TDirectory.Delete(Nested,True);
    Attach(Nested,'\??\'+Copy(string(Volume),5,MaxInt));
    try MustRejectInstall('A mounted-volume child was accepted inside the managed target'); finally Detach(Nested); end;
    CleanProgramUpdate(JobAlias);
    Link:=Settings.AppPath+'ordinary-junction'; Attach(Link,'\??\'+Target);
    try
      Rejected:=False; try AssertUpdatePath(Link+'\LICENSE'); except on E: Exception do Rejected:=E.Message.Contains('ссылку'); end;
      Require(Rejected,'An ordinary directory junction was accepted as a volume mount');
    finally Detach(Link); end;
    ForceDirectories(Job); Link:=Job+'\mounted-child'; Attach(Link,'\??\'+Copy(string(Volume),5,MaxInt));
    try
      Rejected:=False; try CleanProgramUpdate(JobAlias); except on E: Exception do Rejected:=E.Message.Contains('ссылку'); end;
      Require(Rejected,'Recursive cleanup followed a mounted-volume child');
      Require(TFile.ReadAllText(Outside,TEncoding.UTF8)='outside sentinel','Cleanup escaped the owned job');
    finally Detach(Link); end;
    CleanProgramUpdate(JobAlias);
    Writeln('PASS mounted-volume descendants remain rejected during target writes and recursive cleanup; ordinary junctions remain rejected');
  finally Detach(Mount); end;
end;
