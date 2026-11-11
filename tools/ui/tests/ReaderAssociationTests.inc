procedure TestReaderAssociations;
var Registry:TRegistry; Root,Original,Moved,ClassRoot:string; Names:TStringList;
  Dialog:TReaderAssociationsForm;
  function Read(const Key,Name:string):string;
  begin
    Result:='';
    if Registry.OpenKey(Key,False) then
    try if Registry.ValueExists(Name) then Result:=Registry.ReadString(Name);
    finally Registry.CloseKey; end;
  end;
  procedure Write(const Key,Name,Value:string);
  begin Require(Registry.OpenKey(Key,True),'Private registry fixture cannot be created');
    try Registry.WriteString(Name,Value); finally Registry.CloseKey; end; end;
  procedure RemoveTree(const Key:string);
  var Children:TStringList;
  begin
    Children:=TStringList.Create;
    try
      if Registry.OpenKey(Key,False) then
      begin
        try Registry.GetKeyNames(Children); finally Registry.CloseKey; end;
        for var Child in Children do RemoveTree(Key+'\'+Child);
      end;
      Registry.DeleteKey(Key);
    finally Children.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Root:='Software\HomeLibreOwnedTests\Associations-'+TGUID.NewGuid.ToString;
  ClassRoot:=Root+'\Classes\'; Original:=ParamStr(0);
  Moved:=Settings.AppPath+'Читалка в новой папке\HomeLibre Reader.exe';
  ForceDirectories(ExtractFilePath(Moved)); TFile.Copy(Original,Moved,False);
  Registry:=TRegistry.Create(KEY_READ or KEY_WRITE or KEY_WOW64_64KEY);
  Names:=TStringList.Create;
  try
    Registry.RootKey:=HKEY_CURRENT_USER;
    Write(ClassRoot+'.epub','','Another.Reader');
    Write(ClassRoot+'.epub\OpenWithProgids','Another.Reader','');
    Write(Root+'\Explorer\FileExts\.epub\UserChoice','Hash','Protected choice sentinel');
    RegisterReaderAssociations(Original,[ragBooks,ragDocuments,ragImages,ragArchives],Root);
    Require(ReaderAssociationsRegistered(Original,Root),'Reader registration was not visible');
    for var Ext in ReaderAssociationExtensions([ragBooks,ragDocuments,ragImages,ragArchives]) do
    begin
      Require(Names.IndexOf(Ext)<0,'Duplicate supported association'); Names.Add(Ext);
      Require(Read(Root+'\HomeLibre\ReaderAssociations\Capabilities\FileAssociations',Ext)='HomeLibre.Reader.Document',
        'Supported format was not registered: '+Ext);
    end;
    Require((Names.Count>70) and (Read(ClassRoot+'.epub','')='Another.Reader') and
      (Read(Root+'\Explorer\FileExts\.epub\UserChoice','Hash')='Protected choice sentinel'),
      'Registration overwrote a default application or user choice');
    RegisterReaderAssociations(Moved,[ragBooks],Root);
    Require(ReaderAssociationsRegistered(Moved,Root) and not ReaderAssociationsRegistered(Original,Root) and
      (Read(ClassRoot+'HomeLibre.Reader.Document\shell\open\command','')='"'+Moved+'" "%1"'),
      'Portable move did not repair the Unicode/space executable command');
    Require(not UnregisterReaderAssociations(Original,Root),'Old portable instance removed the current registration');
    Write(ClassRoot+'HomeLibre.Reader.Document\shell\open\command','','Replaced command');
    var Refused:=False;
    try UnregisterReaderAssociations(Moved,Root); except on E:ERegistryException do Refused:=True; end;
    Require(Refused and ReaderAssociationsRegistered(Moved,Root),'Unregistration removed a modified command');
    RegisterReaderAssociations(Moved,[ragDocuments],Root);
    Require(Read(Root+'\HomeLibre\ReaderAssociations\Capabilities\FileAssociations','.epub')='',
      'Changing groups kept an unwanted association');
    Require(UnregisterReaderAssociations(Moved,Root) and not ReaderAssociationsRegistered(Moved,Root),
      'Reader registration was not removed');
    Require((Read(ClassRoot+'.epub','')='Another.Reader') and
      (Read(Root+'\Explorer\FileExts\.epub\UserChoice','Hash')='Protected choice sentinel'),
      'Removing registration changed somebody else''s defaults');
    Require(Registry.OpenKey(ClassRoot+'.epub\OpenWithProgids',False),'Removing reader erased Open With');
    try Require(Registry.ValueExists('Another.Reader') and not Registry.ValueExists('HomeLibre.Reader.Document'),
      'Removing reader erased another handler or left its own candidate'); finally Registry.CloseKey; end;
    Dialog:=TReaderAssociationsForm.Create(frmMain);
    try
      for var PPI in TArray<Integer>.Create(96,144,192,288) do
      begin
        Dialog.ScaleForPPI(PPI);
        for var Component in Dialog do
          if Component is TButton then Require((TButton(Component).Parent is TScrollBox) or
            (TButton(Component).BoundsRect.Bottom<=TButton(Component).Parent.ClientHeight),
            'Association actions clip at scaled DPI '+IntToStr(PPI));
      end;
    finally Dialog.Free; end;
    Writeln('PASS private association registration portable repair removal and defaults preservation on x86/x64');
  finally
    Registry.CloseKey; RemoveTree(Root); Registry.Free; Names.Free;
    TFile.Delete(Moved); RemoveDir(ExtractFilePath(Moved));
  end;
end;
