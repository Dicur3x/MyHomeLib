// Native Windows persistence regression; uses unit_AtomicIniFile, System.IniFiles.
// Every path is inside a new GUID folder in this process's isolated G: profile.
procedure TestAtomicIniFile;
var
  Root, Target, LegacyFile, ForeignTemporary, ForeignHash, BeforeHash: string;
  MainProfile, MainBefore, Blocker, BlockerHash, DirectoryTarget: string;
  Ini, Legacy, Reopened: TMemIniFile;
  Lock: TFileStream; ID: TGUID; OldAttributes: DWORD; Failed: Boolean;
  UnicodeText, LargeText: string;

  procedure CheckNoPublicationTemporary;
  var Files: TArray<string>;
  begin
    Files := TDirectory.GetFiles(Root, '*.homelib-ini-*');
    Require((Length(Files) = 1) and SameFileName(Files[0], ForeignTemporary),
      'Atomic INI save left an owned publication temporary or backup');
    Require(THashSHA2.GetHashStringFromFile(ForeignTemporary) = ForeignHash,
      'Atomic INI cleanup changed an unrelated temporary file');
    Require((MainBefore = '') or
      (THashSHA2.GetHashStringFromFile(MainProfile) = MainBefore),
      'Atomic INI fixture changed the active main profile');
  end;

  procedure CheckEncodingCompatibility(const Name: string; Encoding: TEncoding);
  var AtomicPath, LegacyPath: string; AtomicValue, LegacyValue, Loaded: TMemIniFile;
  begin
    AtomicPath := TPath.Combine(Root, Name + '-atomic.ini');
    LegacyPath := TPath.Combine(Root, Name + '-legacy.ini');
    AtomicValue := TMemIniFile.Create(AtomicPath, Encoding);
    LegacyValue := TMemIniFile.Create(LegacyPath, Encoding); Loaded := nil;
    try
      AtomicValue.WriteString('Unknown', 'Value', UnicodeText);
      LegacyValue.WriteString('Unknown', 'Value', UnicodeText);
      LegacyValue.UpdateFile;
      SaveMemIniFileAtomically(AtomicValue);
      Require(THashSHA2.GetHashStringFromFile(AtomicPath) = THashSHA2.GetHashStringFromFile(LegacyPath),
        'Atomic INI differs from RTL for ' + Name + ' encoding/BOM');
      Loaded := TMemIniFile.Create(AtomicPath, Encoding);
      if Encoding = TEncoding.Unicode then
        Require(Loaded.ReadString('Unknown', 'Value', '') = UnicodeText,
          'Atomic UTF16 INI lost Unicode data');
    finally Loaded.Free; LegacyValue.Free; AtomicValue.Free; end;
  end;

  procedure FillProfile(Value: TMemIniFile);
  begin
    Value.WriteString('Reader', 'FontName', 'Georgia');
    Value.WriteInteger('Reader', 'FontSize', 20);
    Value.WriteInteger('Book.known-identity', 'Position', 1876347);
    Value.WriteString('Book.known-identity', 'Title', UnicodeText);
    Value.WriteInteger('Bookmarks.known-identity', 'Count', 2);
    Value.WriteString('Bookmarks.known-identity', 'Title0', 'Моя мысль — ' + UnicodeText);
    Value.WriteInteger('Bookmarks.known-identity', 'Position0', 1234567);
    Value.WriteString('Bookmarks.known-identity', 'Title1', 'Вторая закладка');
    Value.WriteInteger('Bookmarks.known-identity', 'Position1', 765432);
    Value.WriteBool('SYSTEM', 'HideDeleted', True);
    Value.WriteString('PATH', 'DeviceDir', 'Знакомый путь\Україна\Беларусь');
    Value.WriteString('FutureUnknownSection', 'UnknownKey', 'Не терять: ' + UnicodeText);
    Value.WriteString('FutureUnknownSection', 'LongValue', LargeText);
  end;

  procedure CheckReopened(Position, Count: Integer; const FirstTitle: string);
  begin
    FreeAndNil(Reopened); Reopened := TMemIniFile.Create(Target, TEncoding.UTF8);
    Require((Reopened.ReadString('Book.known-identity', 'Title', '') = UnicodeText) and
      (Reopened.ReadInteger('Book.known-identity', 'Position', -1) = Position) and
      (Reopened.ReadInteger('Bookmarks.known-identity', 'Count', -1) = Count) and
      (Reopened.ReadString('Bookmarks.known-identity', 'Title0', '') = FirstTitle) and
      Reopened.ReadBool('SYSTEM', 'HideDeleted', False) and
      (Reopened.ReadString('PATH', 'DeviceDir', '') = 'Знакомый путь\Україна\Беларусь') and
      (Reopened.ReadString('FutureUnknownSection', 'UnknownKey', '') = 'Не терять: ' + UnicodeText) and
      (Reopened.ReadString('FutureUnknownSection', 'LongValue', '') = LargeText),
      'Atomic INI reopen lost reading positions, bookmarks, main preferences or unknown Unicode data');
  end;

  procedure ExpectPreservedFailure(const LabelText: string);
  begin
    BeforeHash := THashSHA2.GetHashStringFromFile(Target); Failed := False;
    try SaveMemIniFileAtomically(Ini); except on E: EOSError do Failed := True; end;
    Require(Failed and Ini.Modified and not Ini.AutoSave,
      LabelText + ' did not report the failed save while retaining its unsaved memory');
    Require(THashSHA2.GetHashStringFromFile(Target) = BeforeHash,
      LabelText + ' truncated or replaced the previous complete profile');
    CheckNoPublicationTemporary;
  end;

begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(ParamStr(0)), 'G:'), 'Atomic INI fixture must stay on G');
  CreateGUID(ID); Root := TPath.Combine(ExtractFilePath(ParamStr(0)), 'atomic-ini-' + GUIDToString(ID));
  Require(ExpandFileName(Root).StartsWith(ExpandFileName(ExtractFilePath(ParamStr(0))), True),
    'Atomic INI fixture escaped its isolated directory');
  TDirectory.CreateDirectory(Root);
  Target := TPath.Combine(Root, 'reader — ё, ї, ў.ini');
  LegacyFile := TPath.Combine(Root, 'legacy-serializer.ini');
  ForeignTemporary := Target + '.homelib-ini-{UNRELATED}.tmp';
  TFile.WriteAllText(ForeignTemporary, 'Unrelated sentinel — never remove', TEncoding.UTF8);
  ForeignHash := THashSHA2.GetHashStringFromFile(ForeignTemporary);
  MainProfile := Settings.SettingsFileName; MainBefore := '';
  if FileExists(MainProfile) then MainBefore := THashSHA2.GetHashStringFromFile(MainProfile);
  UnicodeText := 'Ёж — Україна, Беларусь, Ελληνικά, العربية, 中文 😀';
  LargeText := StringOfChar('я', 2 * 1024 * 1024) + UnicodeText;
  Ini := nil; Legacy := nil; Reopened := nil; Lock := nil;
  try
    Ini := TMemIniFile.Create(Target, TEncoding.UTF8);
    Legacy := TMemIniFile.Create(LegacyFile, TEncoding.UTF8);
    FillProfile(Ini); FillProfile(Legacy);
    Legacy.UpdateFile; // Independent actual RTL compatibility oracle, own fixture only.
    SaveMemIniFileAtomically(Ini);
    Require(not Ini.Modified and not Ini.AutoSave,
      'Atomic INI success did not reset Modified or disabled unsafe destructor retry');
    Require(THashSHA2.GetHashStringFromFile(Target) = THashSHA2.GetHashStringFromFile(LegacyFile),
      'Atomic INI serialization changed the legacy UTF-8/BOM/line-ending bytes');
    var Bytes := TFile.ReadAllBytes(Target);
    Require((Length(Bytes) > 4 * 1024 * 1024) and
      (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF),
      'Atomic INI large UTF-8 fixture is truncated or has an incompatible BOM');
    CheckReopened(1876347, 2, 'Моя мысль — ' + UnicodeText); CheckNoPublicationTemporary;
    Writeln('PASS atomic INI initial large UTF8 bytes match RTL; unknown sections and bookmarks reopen');
    CheckEncodingCompatibility('UTF16', TEncoding.Unicode);
    CheckEncodingCompatibility('RTL-default', nil); CheckNoPublicationTemporary;
    Writeln('PASS atomic INI UTF16 and RTL default encoding/BOM bytes match legacy');

    Ini.WriteInteger('Book.known-identity', 'Position', 321);
    Ini.WriteString('Bookmarks.known-identity', 'Title0', 'Отредактировано: ' + UnicodeText);
    Ini.WriteInteger('Bookmarks.known-identity', 'Count', 1);
    Ini.DeleteKey('Bookmarks.known-identity', 'Title1');
    Ini.DeleteKey('Bookmarks.known-identity', 'Position1');
    SaveMemIniFileAtomically(Ini);
    CheckReopened(321, 1, 'Отредактировано: ' + UnicodeText); CheckNoPublicationTemporary;
    Require(not Reopened.ValueExists('Bookmarks.known-identity', 'Title1'),
      'Atomic INI persisted a deleted bookmark key');
    Writeln('PASS atomic INI replacement persists edit/delete and keeps every unrelated section');

    Ini.WriteInteger('Book.known-identity', 'Position', 654);
    OldAttributes := GetFileAttributes(PChar(Target));
    Require(SetFileAttributes(PChar(Target), OldAttributes or FILE_ATTRIBUTE_READONLY),
      'Could not create the read-only INI failure fixture');
    try ExpectPreservedFailure('Read-only destination');
    finally SetFileAttributes(PChar(Target), OldAttributes); end;
    SaveMemIniFileAtomically(Ini); CheckReopened(654, 1, 'Отредактировано: ' + UnicodeText);
    CheckNoPublicationTemporary;
    Writeln('PASS atomic INI read-only failure preserves old bytes and later retry saves retained memory');

    Ini.WriteInteger('Book.known-identity', 'Position', 999); Ini.AutoSave := True;
    Lock := TFileStream.Create(Target, fmOpenRead or fmShareDenyWrite);
    try ExpectPreservedFailure('Locked destination'); finally FreeAndNil(Lock); end;
    FreeAndNil(Ini);
    Require(THashSHA2.GetHashStringFromFile(Target) = BeforeHash,
      'TMemIniFile destructor retried a failed save non-atomically after its lock was released');
    CheckReopened(654, 1, 'Отредактировано: ' + UnicodeText); CheckNoPublicationTemporary;
    Writeln('PASS atomic INI lock failure and destructor retain the last complete profile');

    Blocker := TPath.Combine(Root, 'not-a-directory');
    TFile.WriteAllText(Blocker, 'Keep existing parent sentinel', TEncoding.UTF8);
    BlockerHash := THashSHA2.GetHashStringFromFile(Blocker);
    Ini := TMemIniFile.Create(TPath.Combine(Blocker, 'settings.ini'), TEncoding.UTF8);
    Ini.WriteString('SYSTEM', 'Value', UnicodeText); Failed := False;
    try SaveMemIniFileAtomically(Ini); except on E: EOSError do Failed := True; end;
    Require(Failed and Ini.Modified and (THashSHA2.GetHashStringFromFile(Blocker) = BlockerHash),
      'Invalid parent save changed the existing parent file or falsely succeeded');
    FreeAndNil(Ini); CheckNoPublicationTemporary;
    Ini := TMemIniFile.Create(TPath.Combine(Root, 'missing-parent\settings.ini'), TEncoding.UTF8);
    Ini.WriteString('SYSTEM', 'Value', UnicodeText); Failed := False;
    try SaveMemIniFileAtomically(Ini); except on E: EOSError do Failed := True; end;
    Require(Failed and not TDirectory.Exists(TPath.Combine(Root, 'missing-parent')),
      'Missing-parent save falsely succeeded or created an unrequested directory');
    FreeAndNil(Ini); CheckNoPublicationTemporary;
    Writeln('PASS atomic INI invalid/missing directory faults preserve existing files');

    DirectoryTarget := TPath.Combine(Root, 'directory.ini'); TDirectory.CreateDirectory(DirectoryTarget);
    Ini := TMemIniFile.Create(DirectoryTarget, TEncoding.UTF8);
    Ini.WriteString('SYSTEM', 'Value', UnicodeText); Failed := False;
    try SaveMemIniFileAtomically(Ini); except on E: EOSError do Failed := True; end;
    Require(Failed and TDirectory.Exists(DirectoryTarget) and Ini.Modified,
      'Directory destination was replaced or falsely reported as a saved INI');
    FreeAndNil(Ini); CheckNoPublicationTemporary;
    Failed := False;
    try SaveMemIniFileAtomically(nil); except on E: EArgumentNilException do Failed := True; end;
    Require(Failed, 'Atomic INI accepted a nil memory file');
    Ini := TMemIniFile.Create('', TEncoding.UTF8); Ini.WriteString('SYSTEM', 'Value', UnicodeText);
    Failed := False;
    try SaveMemIniFileAtomically(Ini); except on E: EArgumentException do Failed := True; end;
    Require(Failed and Ini.Modified and not Ini.AutoSave, 'Atomic INI accepted an empty destination');
    CheckNoPublicationTemporary;
    Writeln('PASS atomic INI directory/nil/empty targets reject without destructive fallback');
    Writeln('PASS atomic INI data preservation all native cases'); Flush(Output);
  finally Lock.Free; Reopened.Free; Legacy.Free; Ini.Free; end;
end;
