program LibraryUpdateSourcesTest;
{$APPTYPE CONSOLE}
{$R *.res}
uses System.SysUtils, System.Classes, System.IOUtils, unit_LibraryUpdateSources;

procedure Check(Value: Boolean; const Reason: string);
begin if not Value then raise Exception.Create(Reason); end;

var Sources, Restored: TLibraryUpdateSources; Text, Warnings, Saved: string;
  Source: TLibraryUpdateSource; Rejected: Boolean;
begin
  try
    Source:=TLibraryUpdateSource.NewSource;
    Source.Name:='Индекс ё'; Source.Location:='G:\новые книги'; Source.IndexFile:='новый.inpx';
    Source.BooksRoot:='G:\книги'; Source.CatalogSourceID:=TGUID.NewGuid.ToString;
    Sources:=[Source]; Saved:=WriteLibraryUpdateSources(Sources);
    Restored:=ReadLibraryUpdateSources(Saved);
    Check(Length(Restored)=1,'JSON count'); Check(Restored[0].ID=Source.ID,'Stable profile ID');
    Check(Restored[0].CatalogSourceID=Source.CatalogSourceID,'Stable catalogue source binding');
    Check(Restored[0].LocalFile='G:\новые книги\новый.inpx','Unicode local source');
    Restored[0].Name:='Переименован';
    Restored:=ReadLibraryUpdateSources(WriteLibraryUpdateSources(Restored));
    Check(Restored[0].ID=Source.ID,'Rename changed ID');
    Restored:=ImportLegacyUpdateSources(ExportLegacyUpdateSources(Sources),'',Warnings);
    Check(Warnings='','Export/import warnings: '+Warnings);
    Check(WriteLibraryUpdateSources(Restored)=Saved,'Legacy roundtrip lost fields');
    Source.Location:='https://example.invalid/individual/'; Sources:=[Source];
    Restored:=ImportLegacyUpdateSources(ExportLegacyUpdateSources(Sources),'https://other.invalid/',Warnings);
    Check(Restored[0].Location=Source.Location,'Individual endpoint replaced by global URL');
    Check(Restored[0].IsRemote,'HTTP source not recognized');
    Rejected:=False; Source.IndexFile:='../other.inpx';
    try Source.Validate; except on E:EArgumentException do Rejected:=True; end;
    Check(Rejected,'Traversal was accepted');
    Source.IndexFile:='new.inpx'; Source.Location:='G:relative'; Rejected:=False;
    try Source.Validate; except on E:EArgumentException do Rejected:=True; end;
    Check(Rejected,'Drive-relative source folder was accepted');
    Source.Location:='\current-drive'; Rejected:=False;
    try Source.Validate; except on E:EArgumentException do Rejected:=True; end;
    Check(Rejected,'Current-drive source folder was accepted');
    Rejected:=False;
    try ReadLibraryUpdateSources('{"version":2,"sources":[]}'); except on E:Exception do Rejected:=True; end;
    Check(Rejected,'Unknown schema accepted');
    Rejected:=False;
    try ReadLibraryUpdateSources('{"version":1,"sources":[{}]}'); except on E:Exception do Rejected:=True; end;
    Check(Rejected,'Missing fields accepted');
    if ParamCount>0 then
    begin
      Text:=TFile.ReadAllText(ParamStr(1),TEncoding.UTF8);
      Sources:=ImportLegacyUpdateSources(Text,'G:\папка обновлений',Warnings);
      Check(Length(Sources)=11,'Duplicate Update9 lost a record');
      Check(Pos('update9',LowerCase(Warnings))>0,'Duplicate key not diagnosed');
      Check(Pos('group5',LowerCase(Warnings))>0,'Undefined INPX group not diagnosed');
      Check(Sources[9].Name<>Sources[10].Name,'Duplicate entries collapsed');
      Restored:=ReadLibraryUpdateSources(WriteLibraryUpdateSources(Sources));
      Check(Length(Restored)=11,'Imported profiles did not survive JSON');
    end;
    Writeln('PASS: stable sources, Unicode, individual endpoints, legacy duplicate/group diagnostics, strict paths/schema');
  except on E:Exception do begin Writeln(E.ClassName+': '+E.Message); ExitCode:=1; end; end;
end.
