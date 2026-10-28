procedure TestReaderPortableStartup;
var Root, Executable, Roaming, Marker, Explicit, Book, Session, Sentinel, SentinelHash: string;
  Value: TReaderStartup; Failed: Boolean;
  procedure Check(const Arguments: TArray<string>; const Profile: string; Portable: Boolean);
  begin
    Value:=ResolveReaderStartup(Executable,Arguments);
    Require(SameFileName(Value.Profile,Profile) and (Value.Portable=Portable),
      'Reader chose a different profile from its startup policy');
  end;
begin
  Root:=TPath.Combine(Settings.AppPath,'portable-startup-Ё');
  Executable:=TPath.Combine(Root,'Читалка с пробелами\HomeLibReader.exe');
  Roaming:=TPath.Combine(Root,'roaming'); Explicit:=TPath.Combine(Root,'catalogue-profile');
  Book:=TPath.Combine(Root,'Книга ё.fb2'); Session:=TPath.Combine(Root,'session.json');
  Marker:=TPath.Combine(ExtractFilePath(Executable),'uselocaldata');
  ForceDirectories(ExtractFilePath(Executable)); ForceDirectories(Roaming);
  Sentinel:=TPath.Combine(Roaming,'previous-reader-profile.ini');
  TFile.WriteAllText(Sentinel,'Existing history, notes and settings remain untouched. ё',TEncoding.UTF8);
  SentinelHash:=THashSHA2.GetHashStringFromFile(Sentinel);
  Check(TArray<string>.Create(Book),ExcludeTrailingPathDelimiter(ExtractFilePath(Executable)),True);
  Require((Value.Source=Book) and (Value.SessionFile='') and not Value.ExplicitProfile,'Ordinary book argument lost');
  for var Flag in TArray<string>.Create('uselocaldata','USELOCALDATA','--portable') do
  begin
    Check(TArray<string>.Create(Flag,Book),ExcludeTrailingPathDelimiter(ExtractFilePath(Executable)),True);
    Require(Value.Source=Book,'Portable flag was mistaken for a book filename');
  end;
  TFile.WriteAllText(Marker,'',TEncoding.ASCII);
  Check(nil,ExcludeTrailingPathDelimiter(ExtractFilePath(Executable)),True);
  Require(Value.Source='','Portable standalone launch invented a book');
  Value:=ResolveReaderStartup(Executable,nil);
  Require(Value.Portable,'Portable launch unnecessarily depends on APPDATA');
  for var Arguments in TArray<TArray<string>>.Create(
    TArray<string>.Create('--profile='+Explicit,'--portable','--open='+Book,'--session='+Session),
    TArray<string>.Create('--portable','--session='+Session,'--profile='+Explicit,'--open='+Book)) do
  begin
    Check(Arguments,Explicit,False);
    Require(Value.ExplicitProfile and (Value.Source=Book) and (Value.SessionFile=Session),
      'Catalogue/restart profile did not override the portable marker or lost its session');
  end;
  Failed:=False;
  try ResolveReaderStartup(Executable,TArray<string>.Create('--profile='));
  except on E:EArgumentException do Failed:=True; end;
  Require(Failed,'An empty explicit profile silently wrote into another profile');
  TFile.Delete(Marker);
  Check(nil,ExcludeTrailingPathDelimiter(ExtractFilePath(Executable)),True);
  var CatalogueMarker:=Settings.AppPath+'uselocaldata';
  var HadMarker:=FileExists(CatalogueMarker);
  var MarkerBytes:TBytes:=nil;
  if HadMarker then begin MarkerBytes:=TFile.ReadAllBytes(CatalogueMarker); TFile.Delete(CatalogueMarker); end;
  try
    var Paths:=ResolveMHLPaths;
    Require(SameFileName(Paths.WorkDir,ExcludeTrailingPathDelimiter(Paths.AppPath)),
      'Catalogue without marker reverted to AppData');
  finally if HadMarker then TFile.WriteAllBytes(CatalogueMarker,MarkerBytes); end;
  Require((THashSHA2.GetHashStringFromFile(Sentinel)=SentinelHash) and
    not DirectoryExists(Explicit) and not DirectoryExists(TPath.Combine(Roaming,'HomeLibReader')),
    'Resolving portable mode moved, created or overwrote user data');
  Writeln('PASS portable catalogue and standalone reader default without marker explicit profile Unicode books sessions and unchanged existing data');
end;
