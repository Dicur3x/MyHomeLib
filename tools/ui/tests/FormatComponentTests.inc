procedure TestFormatComponents;
var Folder, Metadata, Feed, ID, Version, Name, Job, Target, Source, OutputFile, Hash: string;
  Info: TProgramRelease; Root: TJSONValue; Entries: TJSONArray;
  Original: TBytes; Rejected: Boolean; Count: Integer;
  procedure ConversionRequires(const Expected, Input, Destination: string);
  var Required: Boolean;
  begin
    Required:=False;
    try ConvertBasicBook(Target,Settings.TempDir,Input,ExtractFileExt(Input),Destination,nil,nil);
    except on E: EMHLComponentRequired do Required:=E.ComponentID=Expected; end;
    Require(Required,'Wrong dependency for conversion: '+Expected);
    Require(not FileExists(Destination),'Missing dependency published output');
  end;
begin
  RequireIsolatedRegression;
  Folder:=GetEnvironmentVariable('HOMELIB_FORMAT_COMPONENT_PACKAGES');
  Require(Folder<>'','Format component checks require actual packages');
  Metadata:=TFile.ReadAllText(TPath.Combine(Folder,'local-mirror-release.json'),TEncoding.UTF8);
  Feed:=TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8);
  Target:=Settings.AppPath+'format-target'; ForceDirectories(Target+'\Data');
  TFile.WriteAllText(Target+'\HomeLibRu.exe','unchanged application');
  TFile.WriteAllText(Target+'\Data\reader-notes.json','unchanged notes');
  Source:=Target+'\original.fb2';
  TFile.WriteAllText(Source,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
    '<description><title-info><genre>prose</genre><book-title>Format test</book-title><lang>en</lang></title-info></description>'+
    '<body><section><p>Readable original text.</p></section></body></FictionBook>',TEncoding.UTF8);
  Hash:=UpdateSHA256(Source);
  ConversionRequires('BookProcessing',Source,Target+'\before.epub');
  Count:=0; Root:=TJSONObject.ParseJSONValue(Feed);
  try
    Require((Root is TJSONObject) and Root.TryGetValue<TJSONArray>('components',Entries),'Invalid format feed');
    for var Entry in Entries do
    begin
      if Entry.GetValue<string>('platform','')<>ProgramUpdatePlatform then Continue;
      ID:=Entry.GetValue<string>('id'); Version:=Entry.GetValue<string>('version');
      Require(IsFormatComponent(ID),'Unexpected format component');
      Require(IsOptionalComponent(ID) and not ComponentNotificationEnabled(ID,''),'Unrequested format not optional');
      Require(not SafeComponentFile(ID,'HomeLibRu.exe') and not SafeComponentFile(ID,'Data/reader-notes.json'),
        'Format package gained application or user data');
      Require(ParseComponentMirror(Metadata,Feed,ID,Version,Info),'Format component metadata rejected: '+ID);
      Name:=ComponentVersionedArchiveName(ID,Version,ProgramUpdatePlatform);
      Job:=Settings.AppPath+'HomeLibRu-update-format-'+ID;
      try
        PrepareProgramUpdate(TPath.Combine(Folder,Name),Info.SHA256,Info.Tag,ProgramUpdatePlatform,Job,True,ID,Version);
        VerifyPreparedProgramUpdate(Job,Info.Tag,ProgramUpdatePlatform);
        Name:=TPath.Combine(Job,'payload/'+FormatComponentFile(ID));
        Original:=TFile.ReadAllBytes(Name); var Broken:=Copy(Original); Broken[0]:=Broken[0] xor 1;
        TFile.WriteAllBytes(Name,Broken); Rejected:=False;
        try
          try VerifyPreparedProgramUpdate(Job,Info.Tag,ProgramUpdatePlatform);
          except on E: Exception do Rejected:=True; end;
        finally TFile.WriteAllBytes(Name,Original); end;
        Require(Rejected,'Modified format component was accepted: '+ID);
        InstallProgramUpdate(Job,Target);
        Require((InstalledComponentVersion(Target,ID)=Version) and not ComponentNeedsRepair(Target,ID),
          'Installed format identity mismatch: '+ID);
        Require(TFile.ReadAllText(Target+'\HomeLibRu.exe')='unchanged application','Format install replaced app');
        Require(TFile.ReadAllText(Target+'\Data\reader-notes.json')='unchanged notes','Format install changed notes');
        if ID='BookProcessing' then
        begin
          for var Unrelated in ['kindle','office','xps','images','pdfium','djvu'] do
            Require(not DirectoryExists(Target+'\tools\'+Unrelated),'Base processing installed '+Unrelated);
          OutputFile:=Target+'\base.epub';
          ConvertBasicBook(Target,Settings.TempDir,Source,'.fb2',OutputFile,nil,nil);
          Require(FileExists(OutputFile) and (UpdateSHA256(Source)=Hash),'Minimal FB2 conversion failed or changed source');
          TFile.WriteAllText(Target+'\source.pdf','%PDF-1.4'+sLineBreak,TEncoding.ASCII);
          ConversionRequires('PDFium',Target+'\source.pdf',Target+'\pdf.epub');
          Writeln('PASS independent format base converts FB2 to EPUB without Kindle Office XPS and requests PDFium for PDF'); Flush(Output);
        end;
        Writeln('PASS independent format component prepare verify install ',ID,' ',ProgramUpdatePlatform); Flush(Output);
        Inc(Count);
      finally CleanProgramUpdate(Job); end;
    end;
    Require(Count=6,'Every independent format component must be verified');
    Require(UpdateSHA256(Source)=Hash,'Format checks changed original book');
  finally Root.Free; end;
end;
