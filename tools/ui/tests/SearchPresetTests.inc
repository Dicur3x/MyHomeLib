// Native preset safety regression; run after the isolated main form exists.
// Additional uses: unit_SearchPresets, unit_xmlUtils.

procedure TestXMLPublicationPaths;
var Root, Folder, Name, Payload, BeforeHash: string; Data, Reopened: TUserData;
  Locked: TFileStream; Failed: Boolean;
begin
  RequireIsolatedRegression;
  Root:=TPath.Combine(Settings.AppPath,'xml-paths-ё'); Folder:=Root;
  for var I:=1 to 4 do Folder:=TPath.Combine(Folder,StringOfChar('x',55)+IntToStr(I));
  Require(Length(Folder)>MAX_PATH,'XML path fixture must exceed the Win32 limit');
  Require(ForceDirectories(DeletionNativePath(Folder)),'Cannot create isolated long XML directory');
  Payload:='Группа ё — 中文 & <literal>';
  for var Compressed in [False,True] do
  begin
    Name:=TPath.Combine(Folder,'groups-'+BoolToStr(Compressed,True)+'.cxml2');
    var XML:=TMSXMLHelper.CreateEmptyDocument;
    var Element:=XML.createElement('probe'); Element.text:=Payload; XML.appendChild(Element);
    TMSXMLHelper.SaveToFile(XML,Name,Compressed);
    var Loaded:=TMSXMLHelper.LoadFromFile(Name,Compressed);
    Require(Loaded.documentElement.text=Payload,'Long XML path changed compressed/plain Unicode content');
    Loaded:=nil; XML.documentElement.text:='Changed draft'; Failed:=False;
    Locked:=TFileStream.Create(DeletionNativePath(Name),fmOpenRead or fmShareExclusive);
    try
      try TMSXMLHelper.SaveToFile(XML,Name,Compressed);
      except on E:EOSError do
        begin
          Writeln('TRACE locked XML publication error=',E.ErrorCode);
          // Windows rename can report either access denied or sharing violation
          // for a target that denies deletion. Both must retain the old file.
          Failed:=E.ErrorCode in [ERROR_ACCESS_DENIED,ERROR_SHARING_VIOLATION];
        end;
      end;
      Require(Failed,'Locked long XML replacement must report a target lock/access error');
    finally Locked.Free; end;
    Loaded:=TMSXMLHelper.LoadFromFile(Name,Compressed);
    Require(Loaded.documentElement.text=Payload,'Failed long XML publication changed the old complete document');
    Loaded:=nil; XML:=nil;
  end;
  // This leaf fits Windows' component limit; appending the old temporary suffix did not.
  Name:=TPath.Combine(Root,StringOfChar('n',240)+'.cxml2');
  Data:=TUserData.Create; Reopened:=TUserData.Create;
  try
    Data.Groups.AddGroup(17,Payload).AddBook(42,'source:ё'); Data.Save(Name); Reopened.Load(Name);
    Require((Reopened.Groups.Count=1) and (Reopened.Groups[0].GroupName=Payload) and
      (Reopened.Groups[0].Count=1) and (Reopened.Groups[0][0].LibID='source:ё'),
      'Maximum-length user-data leaf changed group membership during save/reopen');
    BeforeHash:=THashSHA2.GetHashStringFromFile(DeletionNativePath(Name));
    Failed:=False;
    try TMSXMLHelper.SaveToZFile(nil,Name); except on E:EArgumentNilException do Failed:=True; end;
    Require(Failed and (THashSHA2.GetHashStringFromFile(DeletionNativePath(Name))=BeforeHash),
      'Invalid XML input changed an existing long user-data filename');
  finally Reopened.Free; Data.Free; end;
  Require(Length(TDirectory.GetFiles(DeletionNativePath(Folder),'.homelib-xml-*.tmp'))=0,
    'Long XML publication left its temporary file after success or a locked failure');
  Require(Length(TDirectory.GetFiles(DeletionNativePath(Root),'.homelib-xml-*.tmp'))=0,
    'Long XML leaf publication left its temporary file');
  Writeln('PASS XML publication handles long directories and filename components, reopens Unicode groups, preserves locked targets and removes owned temporaries');
end;

procedure TestSearchPresetSafety;
var
  PresetFile, Name, SecondName, LongFilter, UnicodeFilter: string;
  BeforeHash, BeforeName, Draft, ProtectedBook, ProtectedHistory: string;
  ProtectedPaths, ProtectedHashes: TStringList;
  Reopened: TSearchPresets;
  Locked: TFileStream;
  Failure, ErrorShown: Boolean;
  OldAttributes: DWORD;

  procedure CheckNoOwnedTemporary;
  begin
    Require(Length(TDirectory.GetFiles(ExtractFilePath(PresetFile),
      '*.homelib-*.tmp')) + Length(TDirectory.GetFiles(ExtractFilePath(PresetFile),
      '.homelib-xml-*.tmp')) = 0,
      'Preset save left an owned publication temporary file');
  end;

  procedure ReopenPresets;
  begin
    FreeAndNil(Reopened);
    Reopened := TSearchPresets.Create;
    Reopened.Load(PresetFile);
  end;

  procedure SelectStored(const PresetName: string);
  begin
    frmMain.cbPresetName.Text := PresetName;
    frmMain.cbPresetNameSelect(nil);
  end;

  procedure RememberProtected(const FileName: string);
  begin
    if not FileExists(FileName) or (ProtectedPaths.IndexOf(FileName) >= 0) then Exit;
    ProtectedPaths.Add(FileName);
    ProtectedHashes.Add(THashSHA2.GetHashStringFromFile(FileName));
  end;

  procedure CheckProtected;
  begin
    for var I := 0 to ProtectedPaths.Count - 1 do
      Require(FileExists(ProtectedPaths[I]) and
        (THashSHA2.GetHashStringFromFile(ProtectedPaths[I]) = ProtectedHashes[I]),
        'Preset operation changed collection, history or book: ' + ProtectedPaths[I]);
  end;

begin
  RequireIsolatedRegression;
  Require(Assigned(frmMain), 'Preset regression requires its main form');
  PresetFile := Settings.SystemFileName[sfPresets];
  Require(not FileExists(PresetFile) and (frmMain.cbPresetName.Items.Count = 0),
    'Preset regression requires a new isolated profile');
  Name := 'Чтение — ё, ї, ў, 中文';
  SecondName := 'Другой пресет';
  LongFilter := '<="Ёж" | ' + StringOfChar('я', 18000) + ' | "текст & <граница>"';
  UnicodeFilter := 'Ёж, Україна, Беларусь, Ελληνικά, العربية, 中文 😀';
  Reopened := nil;
  Locked := nil;
  ProtectedPaths := TStringList.Create;
  ProtectedHashes := TStringList.Create;
  try
    ProtectedBook := Settings.AppPath + 'preset-protected-book.fb2';
    ProtectedHistory := Settings.AppPath + 'preset-protected-history.ini';
    TFile.WriteAllText(ProtectedBook, '<FictionBook>Сохранённая книга ё</FictionBook>', TEncoding.UTF8);
    TFile.WriteAllText(ProtectedHistory, '[reader]' + sLineBreak + 'position=12345', TEncoding.UTF8);
    RememberProtected(ProtectedBook);
    RememberProtected(ProtectedHistory);
    RememberProtected(Settings.SystemFileName[sfSystemDB]);
    RememberProtected(Settings.SystemFileName[sfCollectionsStore]);
    for var FileName in TDirectory.GetFiles(Settings.DataPath) do
      RememberProtected(FileName);

    frmMain.cbPresetName.ItemIndex := -1;
    frmMain.cbPresetName.Text := '  ' + Name + '  ';
    frmMain.edFTitle.Text := LongFilter;
    frmMain.edFAnnotation.Text := UnicodeFilter;
    frmMain.cbDeleted.Checked := True;
    frmMain.SaveSearchPreset(nil);
    Require((frmMain.cbPresetName.ItemIndex >= 0) and
      (frmMain.cbPresetName.Text = Name), 'Newly saved preset was not selected');
    ReopenPresets;
    Require((Reopened.Count = 1) and
      (Reopened.GetPreset(Name).Items[SF_TITLE] = LongFilter) and
      (Reopened.GetPreset(Name).Items[SF_ANNOTATION] = UnicodeFilter) and
      StrToBool(Reopened.GetPreset(Name).Items[SF_DELETED]),
      'Compressed XML reopen lost Unicode, long filters or deletion condition');
    var LegacyXML := TMSXMLHelper.LoadFromZFile(PresetFile);
    Require(LegacyXML.documentElement.nodeName = 'Presets',
      'Atomic preset save changed legacy XML structure or compression');
    LegacyXML := nil;
    CheckNoOwnedTemporary;
    CheckProtected;

    // A typed case variant resolves to the actual stored name, never a phantom duplicate.
    frmMain.cbPresetName.ItemIndex := -1;
    frmMain.cbPresetName.Text := AnsiLowerCase(Name);
    frmMain.SaveSearchPreset(nil);
    ReopenPresets;
    Require((Reopened.Count = 1) and (frmMain.cbPresetName.Items.Count = 1) and
      (frmMain.cbPresetName.Text = Name) and
      (Reopened.GetPreset(Name).Items[SF_TITLE] = LongFilter),
      'Mixed-case typed save created a duplicate or changed the canonical preset name');
    CheckProtected;

    // Locked replacement must retain both disk data and the live presets.
    BeforeHash := THashSHA2.GetHashStringFromFile(PresetFile);
    BeforeName := frmMain.cbPresetName.Text;
    Draft := 'Несохранённое изменение';
    frmMain.edFTitle.Text := Draft;
    Locked := TFileStream.Create(PresetFile, fmOpenRead or fmShareExclusive);
    try
      Failure := False;
      ErrorShown := False;
      try frmMain.SaveSearchPreset(nil);
      except
        on E: Exception do
        begin
          Failure := True;
          ErrorShown := E.Message.Contains('Не удалось сохранить пресет');
        end;
      end;
      Require(Failure and ErrorShown, 'Locked save did not report a useful preset error');
      Require((frmMain.cbPresetName.Text = BeforeName) and
        (frmMain.edFTitle.Text = Draft), 'Failed save erased the name or edited draft');
      CheckNoOwnedTemporary;
    finally FreeAndNil(Locked); end;
    Require(THashSHA2.GetHashStringFromFile(PresetFile) = BeforeHash,
      'Locked save truncated or replaced the prior presets');
    SelectStored(Name);
    Require(frmMain.edFTitle.Text = LongFilter,
      'Failed save changed the in-memory stored preset');

    frmMain.cbPresetName.ItemIndex := -1;
    frmMain.cbPresetName.Text := '  ' + Name + '  ';
    frmMain.DeletePresetUpdate(nil);
    Require(frmMain.acDeletePreset.Enabled, 'Typed existing preset cannot be deleted');
    Locked := TFileStream.Create(PresetFile, fmOpenRead or fmShareExclusive);
    try
      Failure := False;
      ErrorShown := False;
      try frmMain.DeleteSearchPreset(nil);
      except
        on E: Exception do
        begin
          Failure := True;
          ErrorShown := E.Message.Contains('Не удалось удалить пресет');
        end;
      end;
      Require(Failure and ErrorShown and (frmMain.cbPresetName.Items.IndexOf(Name) >= 0),
        'Failed delete removed the live preset or hid the failure');
      CheckNoOwnedTemporary;
    finally FreeAndNil(Locked); end;
    Require(THashSHA2.GetHashStringFromFile(PresetFile) = BeforeHash,
      'Failed delete changed stored preset bytes');
    SelectStored(Name);
    Require(frmMain.edFTitle.Text = LongFilter, 'Failed delete removed the live preset');
    CheckProtected;

    // A nonexistent typed name is harmless even if the handler is called directly.
    frmMain.cbPresetName.ItemIndex := -1;
    frmMain.cbPresetName.Text := 'Не существует';
    frmMain.DeletePresetUpdate(nil);
    Require(not frmMain.acDeletePreset.Enabled, 'Delete is enabled for a nonexistent preset');
    frmMain.DeleteSearchPreset(nil);
    Require(THashSHA2.GetHashStringFromFile(PresetFile) = BeforeHash,
      'Deleting a nonexistent typed name changed the file');
    SelectStored(Name);
    Require(frmMain.edFTitle.Text = LongFilter, 'Nonexistent deletion changed stored conditions');

    // Read-only replacement is another publication failure after full serialization.
    OldAttributes := GetFileAttributes(PChar(PresetFile));
    Require(OldAttributes <> INVALID_FILE_ATTRIBUTES, 'Preset attributes are unavailable');
    Require(SetFileAttributes(PChar(PresetFile), OldAttributes or FILE_ATTRIBUTE_READONLY),
      'Read-only preset fixture could not be prepared');
    try
      frmMain.edFTitle.Text := Draft;
      Failure := False;
      try frmMain.SaveSearchPreset(nil);
      except on E: Exception do Failure := True; end;
      Require(Failure, 'Read-only preset replacement unexpectedly succeeded');
      Require(THashSHA2.GetHashStringFromFile(PresetFile) = BeforeHash,
        'Read-only failure changed the original file');
      CheckNoOwnedTemporary;
    finally
      Require(SetFileAttributes(PChar(PresetFile), OldAttributes),
        'Read-only fixture attributes could not be restored');
    end;
    SelectStored(Name);
    Require(frmMain.edFTitle.Text = LongFilter, 'Read-only failure changed stored conditions');

    frmMain.cbPresetName.ItemIndex := -1;
    frmMain.cbPresetName.Text := SecondName;
    frmMain.edFTitle.Text := 'Вторая книга';
    frmMain.SaveSearchPreset(nil);
    ReopenPresets;
    Require((Reopened.Count = 2) and
      (Reopened.GetPreset(Name).Items[SF_TITLE] = LongFilter),
      'Adding another preset changed the existing conditions');
    frmMain.cbPresetName.ItemIndex := -1;
    frmMain.cbPresetName.Text := AnsiLowerCase(Name);
    frmMain.DeletePresetUpdate(nil);
    Require(frmMain.acDeletePreset.Enabled, 'Mixed-case existing name cannot be deleted');
    frmMain.DeleteSearchPreset(nil);
    ReopenPresets;
    Require((Reopened.Count = 1) and
      (Reopened.GetPreset(SecondName).Items[SF_TITLE] = 'Вторая книга') and
      (frmMain.cbPresetName.Items.IndexOf(Name) < 0),
      'Typed existing deletion affected the wrong preset');

    BeforeHash := THashSHA2.GetHashStringFromFile(PresetFile);
    Failure := False;
    try TMSXMLHelper.SaveToZFile(nil, PresetFile);
    except on E: Exception do Failure := True; end;
    Require(Failure and (THashSHA2.GetHashStringFromFile(PresetFile) = BeforeHash),
      'Invalid XML input changed the last complete preset file');
    SelectStored(SecondName);
    frmMain.DeleteSearchPreset(nil);
    ReopenPresets;
    Require((Reopened.Count = 0) and (frmMain.cbPresetName.Items.Count = 0),
      'Save followed by delete cannot remove the final selected preset');
    CheckNoOwnedTemporary;
    CheckProtected;
    TestXMLPublicationPaths;
    Writeln('PASS presets preserve typed names, Unicode and long filters across save/delete/reopen, locked/read-only failures keep old disk and memory data, and books/collections/history remain unchanged');
  finally
    Locked.Free;
    Reopened.Free;
    ProtectedHashes.Free;
    ProtectedPaths.Free;
  end;
end;
