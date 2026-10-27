procedure TestStandaloneReaderCacheSettings;
var Dialog: TfrmReaderCacheSettings; Policy, Units: TComboBox; Days, Limit: TEdit;
  Apply, Clear: TButton; CopySettings: TMHLSettings; Origin, Cache, Personal, SettingsText: string;
  Input: TStream; BeforePolicy: TBookCachePolicy;
begin
  RequireIsolatedRegression;
  Settings.ClearBookCacheOnExit:=False; Settings.BookCachePolicy:=bcpSize;
  Settings.BookCacheLimitMB:=5120; Settings.BookCacheKeepDays:=7;
  Origin:=TPath.Combine(Settings.AppPath,'owned-reader-cache-origin.fb2');
  Personal:=TPath.Combine(Settings.DataPath,'reader-notes.json');
  ForceDirectories(Settings.DataPath);
  TFile.WriteAllText(Origin,'original book, never a cache file',TEncoding.UTF8);
  TFile.WriteAllText(Personal,'owned saved notes',TEncoding.UTF8);
  var ReaderSettings:=TPath.Combine(Settings.DataPath,'reader.ini');
  SettingsText:='[Book.owned]'+sLineBreak+'Position=12345'+sLineBreak+
    '[Bookmarks.owned]'+sLineBreak+'Count=1'+sLineBreak+'Position0=4321';
  TFile.WriteAllText(ReaderSettings,SettingsText,TEncoding.UTF8);
  Dialog:=TfrmReaderCacheSettings.Create(nil);
  try
    Dialog.Show; Application.ProcessMessages;
    Require(Dialog.BorderStyle=bsSizeable,'Standalone cache dialog cannot resize');
    Policy:=Dialog.FindComponent('ReaderCachePolicy') as TComboBox;
    Days:=Dialog.FindComponent('ReaderCacheDays') as TEdit;
    Limit:=Dialog.FindComponent('ReaderCacheLimit') as TEdit;
    Units:=Dialog.FindComponent('ReaderCacheUnit') as TComboBox;
    Apply:=Dialog.FindComponent('ReaderCacheApply') as TButton;
    Policy.ItemIndex:=1; Policy.OnChange(Policy);
    Require(Days.Enabled and not Limit.Enabled and not Units.Enabled,'Age policy controls are incorrect');
    Days.Text:='0'; Apply.Click;
    Require((Dialog.ModalResult<>mrOk) and (Settings.BookCacheKeepDays=7),'Invalid cache age was saved');
    Days.Text:='14'; Apply.Click;
    Require((Dialog.ModalResult=mrOk) and (Settings.BookCacheKeepDays=14) and
      (Settings.BookCachePolicy=bcpAge),'Reader cache age not applied');
  finally Dialog.Free; end;
  CopySettings:=TMHLSettings.Create;
  try
    CopySettings.LoadSettings;
    Require((CopySettings.BookCachePolicy=bcpAge) and (CopySettings.BookCacheKeepDays=14),
      'Standalone cache settings did not survive reload');
  finally CopySettings.Free; end;
  Dialog:=TfrmReaderCacheSettings.Create(nil);
  try
    Policy:=Dialog.FindComponent('ReaderCachePolicy') as TComboBox;
    Policy.ItemIndex:=2; Policy.OnChange(Policy);
    Days:=Dialog.FindComponent('ReaderCacheDays') as TEdit;
    Limit:=Dialog.FindComponent('ReaderCacheLimit') as TEdit;
    Units:=Dialog.FindComponent('ReaderCacheUnit') as TComboBox;
    Require(Days.Enabled and Limit.Enabled and Units.Enabled,'Combined policy controls are incorrect');
    Limit.Text:='1,5'; Units.ItemIndex:=1;
    TButton(Dialog.FindComponent('ReaderCacheApply')).Click;
    Require((Settings.BookCacheLimitMB=1536) and (Settings.BookCachePolicy=bcpSizeAndAge),
      'Reader cache fractional GiB was not saved');
  finally Dialog.Free; end;
  BeforePolicy:=Settings.BookCachePolicy;
  Dialog:=TfrmReaderCacheSettings.Create(nil);
  try
    Policy:=Dialog.FindComponent('ReaderCachePolicy') as TComboBox; Policy.ItemIndex:=0;
    Policy.OnChange(Policy); Dialog.ModalResult:=mrCancel;
  finally Dialog.Free; end;
  Require(Settings.BookCachePolicy=BeforePolicy,'Cancel changed reader cache policy');
  ForceDirectories(BookCachePath); Cache:=TPath.Combine(BookCachePath,'homelib-owned-reader-settings.fb2');
  TFile.WriteAllText(Cache,'owned prepared book',TEncoding.UTF8); RegisterBookCacheFile(Cache,Origin);
  RefreshBookCache(True); Input:=OpenCachedBookFile(Cache);
  try
    Dialog:=TfrmReaderCacheSettings.Create(nil);
    try
      Clear:=Dialog.FindComponent('ReaderCacheClear') as TButton; Clear.Click;
      Require(FileExists(Cache),'Cache clear deleted a file still open for reading');
      Require(TFile.ReadAllText(Origin,TEncoding.UTF8)='original book, never a cache file','Cache clear changed original');
      Require(TFile.ReadAllText(Personal,TEncoding.UTF8)='owned saved notes','Cache clear changed notes');
      Require(TFile.ReadAllText(ReaderSettings,TEncoding.UTF8)=SettingsText,'Cache clear changed positions/bookmarks');
    finally Dialog.Free; end;
  finally Input.Free; end;
  TrimBookCache;
  Require(not FileExists(Cache),'Closed retired reader cache file was not removed');
  Writeln('PASS standalone reader cache settings preserve books notes positions and active files with age size cancel and reload');
end;
