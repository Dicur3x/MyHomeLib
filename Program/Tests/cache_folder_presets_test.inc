// Include before the native test program's final begin/end; requires its
// existing Require helper and frm_settings/cache/hash/VCL units. Run in a fresh
// isolated G runtime only. It creates no real user collections or book copies.
procedure TestCacheFolderPresets;
var Configuration: TfrmSettings; DirectoryEdit, ResolvedEdit: TEdit;
  HelpLabel: TLabel; ChooseButton: TButton; Menu: TPopupMenu; Page: TWinControl; Bounds: TRect;
  InitialDirectory, SavedTemp, SavedTmp, SavedLocal, TempRoot, LocalRoot, CustomRoot: string;
  Original, Owned, Destination, ProfileFile, NotesFile, SourceHash, ProfileHash, NotesHash, IniBefore: string;
  SavedExit: Boolean; SavedLimit, PPI, I: Integer; Started, EditStarted: UInt64;
  procedure WaitIdle;
  var Deadline: UInt64;
  begin
    Deadline:=GetTickCount64+5000;
    while BookCacheMigrationBusy and (GetTickCount64<Deadline) do begin Application.ProcessMessages; Sleep(10); end;
    Require(not BookCacheMigrationBusy,'Private preset migration did not stop');
  end;
  procedure SelectPreset(Tag: Integer; const Base, Root: string);
  begin
    EditStarted:=GetTickCount64; Menu.Items[Tag].Click;
    Require(SameFileName(DirectoryEdit.Text,Base) or ((Base='') and (DirectoryEdit.Text='')),'Preset base mapping incorrect');
    Require(SameFileName(ResolvedEdit.Text,Root),'Resolved preset root is incomplete/incorrect');
    Require(Settings.BookCacheDirectory=InitialDirectory,'Preset selection changed committed settings before Apply');
    Require(TFile.ReadAllText(Settings.AppPath+'myhomelib2.ini',TEncoding.UTF8)=IniBefore,'Draft preset rewrote settings file');
    Require(GetTickCount64-EditStarted<250,'Preset selection blocks on filesystem/migration');
  end;
  procedure CheckControls;
  begin
    Require(Menu.Items.Count=4,'Folder preset menu count differs');
    Require(Menu.Items[0].Caption='Рядом с данными программы','Default preset is unclear');
    Require(Menu.Items[1].Caption='Временная папка Windows','Temp preset missing');
    Require(Menu.Items[2].Caption='Локальные данные Windows','Local-data preset missing');
    Require(Menu.Items[3].Caption='Другая папка…','Custom browse missing');
    Require(Assigned(Menu.Items[3].OnClick),'Existing custom browse was disconnected');
    Require(Assigned(ChooseButton.OnClick) and (ChooseButton.Caption='Выбрать папку'),'Compact choose button missing');
    Require(ResolvedEdit.ReadOnly and ResolvedEdit.Enabled,'Full cache path cannot be selected/copied');
    Page:=DirectoryEdit.Parent;
    Writeln('PROFILE cache preset requested_dpi=',PPI,' current_ppi=',Configuration.CurrentPPI,
      ' form_ppi=',Configuration.PixelsPerInch,' client=',Configuration.ClientWidth,'x',Configuration.ClientHeight,
      ' page=',Page.ClientWidth,'x',Page.ClientHeight,' help_top=',HelpLabel.Top,
      ' help_height=',HelpLabel.Height,' help_bottom=',HelpLabel.Top+HelpLabel.Height); Flush(Output);
    Require((DirectoryEdit.Left>=0) and (DirectoryEdit.Top>=0) and
      (DirectoryEdit.Left+DirectoryEdit.Width<=ChooseButton.Left),'Folder edit overlaps choose button');
    Require(ChooseButton.Left+ChooseButton.Width<=Page.ClientWidth,'Choose button is clipped');
    Require(ResolvedEdit.Left+ResolvedEdit.Width<=Page.ClientWidth,'Resolved path is clipped');
    Require(HelpLabel.Top+HelpLabel.Height<=Page.ClientHeight,
      Format('Folder explanation is clipped at %d DPI: bottom=%d, page=%d, form=%d',
        [PPI,HelpLabel.Top+HelpLabel.Height,Page.ClientHeight,Configuration.ClientHeight]));
    Configuration.Canvas.Font.Assign(HelpLabel.Font); Bounds:=Rect(0,0,HelpLabel.Width,0);
    DrawText(Configuration.Canvas.Handle,PChar(HelpLabel.Caption),Length(HelpLabel.Caption),
      Bounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Require(Bounds.Height<=HelpLabel.Height,'Wrapped folder explanation text is clipped');
    Configuration.Canvas.Font.Assign(ChooseButton.Font);
    Require(Configuration.Canvas.TextWidth(ChooseButton.Caption)+MulDiv(16,PPI,96)<=ChooseButton.Width,
      'Choose-folder button text is clipped at this DPI');
    Writeln('PROFILE cache preset DPI=',PPI,' page=',Page.ClientWidth,'x',Page.ClientHeight,
      ' button=',ChooseButton.Width,'x',ChooseButton.Height,' resolved=',ResolvedEdit.Width,
      ' help_bottom=',HelpLabel.Top+HelpLabel.Height); Flush(Output);
  end;
  procedure ApplyBase(const Base, ExpectedRoot: string);
  begin
    DirectoryEdit.Text:=Base; Configuration.SaveSettings;
    Require(SameFileName(BookCachePath,ExpectedRoot),'Apply used a different cache root');
    Destination:=TPath.Combine(BookCachePath,ExtractFileName(Owned)); Started:=GetTickCount64;
    while (not FileExists(Destination) or not FileExists(Destination+'.origin')) and (GetTickCount64-Started<5000) do begin Application.ProcessMessages; Sleep(10); end;
    Require(FileExists(Destination) and FileExists(Destination+'.origin'),'Cache did not migrate after Apply');
    Require(THashSHA2.GetHashStringFromFile(Destination)=THashSHA2.GetHashStringFromFile(Owned),'Migration changed cached book bytes');
    Require(TFile.ReadAllText(Destination+'.origin',TEncoding.UTF8)=Original,'Migration lost source provenance');
    StopBookCacheMigration; WaitIdle;
    Require(THashSHA2.GetHashStringFromFile(Original)=SourceHash,'Folder preset changed original book');
    Require(THashSHA2.GetHashStringFromFile(ProfileFile)=ProfileHash,'Folder preset changed reading profile/history');
    Require(THashSHA2.GetHashStringFromFile(NotesFile)=NotesHash,'Folder preset changed personal notes');
  end;
begin
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Cache presets require isolated G runtime');
  InitialDirectory:=TPath.Combine(Settings.AppPath,'existing-custom-cache');
  SavedTemp:=GetEnvironmentVariable('TEMP'); SavedTmp:=GetEnvironmentVariable('TMP');
  SavedLocal:=GetEnvironmentVariable('LOCALAPPDATA'); SavedExit:=Settings.ClearBookCacheOnExit;
  SavedLimit:=Settings.BookCacheLimitMB; Settings.ClearBookCacheOnExit:=False; Settings.BookCacheLimitMB:=5120;
  TempRoot:=TPath.Combine(Settings.AppPath,'private-windows-temp'); LocalRoot:=TPath.Combine(Settings.AppPath,'private-local-data');
  CustomRoot:=TPath.Combine(Settings.AppPath,'another-custom-cache');
  Require(SetEnvironmentVariable('TEMP',PChar(TempRoot)) and SetEnvironmentVariable('TMP',PChar(TempRoot)) and
    SetEnvironmentVariable('LOCALAPPDATA',PChar(LocalRoot)),'Could not isolate Windows folder presets');
  Configuration:=nil;
  try
    Require(Settings.BookCacheDirectory='','Native preset fixture must start with the unchanged default');
    Configuration:=TfrmSettings.Create(nil); Configuration.LoadSetting;
    try
      ResolvedEdit:=TEdit(Configuration.FindComponent('edBookCacheResolved'));
      HelpLabel:=TLabel(Configuration.FindComponent('lblBookCacheLocationInfo'));
      Require(Assigned(ResolvedEdit) and SameFileName(ResolvedEdit.Text,TPath.Combine(Settings.DataPath,'BookCache')),
        'Fresh empty default did not show its full cache root');
      Require(Assigned(HelpLabel) and string(HelpLabel.Caption).Contains('галочкой выше'),'Fresh default has no folder explanation');
    finally Configuration.Free; Configuration:=nil; end;
    ChangeBookCacheDirectory(InitialDirectory); WaitIdle;
    Original:=TPath.Combine(Settings.AppPath,'private-original-preset.fb2');
    ProfileFile:=TPath.Combine(Settings.DataPath,'reader.ini');
    NotesFile:=TPath.Combine(Settings.DataPath,'reader-notes.json');
    TFile.WriteAllText(Original,'Исходная книга: ё, і, ї, ў, English.',TEncoding.UTF8);
    if not FileExists(ProfileFile) then TFile.WriteAllText(ProfileFile,'[Reader]'+#13#10+'Position=72'+#13#10+'Font=PT Serif',TEncoding.UTF8);
    if not FileExists(NotesFile) then TFile.WriteAllText(NotesFile,'{"version":1,"notes":[{"id":"preset","book":"private","text":"Личная мысль ё і","position":72}]}',TEncoding.UTF8);
    SourceHash:=THashSHA2.GetHashStringFromFile(Original); ProfileHash:=THashSHA2.GetHashStringFromFile(ProfileFile);
    NotesHash:=THashSHA2.GetHashStringFromFile(NotesFile);
    ForceDirectories(BookCachePath); Owned:=TPath.Combine(BookCachePath,'homelib-cache-preset-owned.fb2');
    TFile.Copy(Original,Owned,False); TFile.WriteAllText(Owned+'.origin',Original,TEncoding.UTF8);
    RegisterBookCacheFile(Owned,Original); RefreshBookCache(True); Settings.SaveSettings;
    IniBefore:=TFile.ReadAllText(Settings.AppPath+'myhomelib2.ini',TEncoding.UTF8);
    for I:=0 to 2 do
    begin
      case I of 0:PPI:=96; 1:PPI:=144; else PPI:=192; end;
      Configuration:=TfrmSettings.Create(nil); Configuration.LoadSetting;
      Configuration.ScaleForPPI(PPI);
      try
        DirectoryEdit:=TEdit(Configuration.FindComponent('edBookCacheDirectory'));
        ResolvedEdit:=TEdit(Configuration.FindComponent('edBookCacheResolved'));
        HelpLabel:=TLabel(Configuration.FindComponent('lblBookCacheLocationInfo'));
        ChooseButton:=TButton(Configuration.FindComponent('btnChooseBookCacheDirectory'));
        Menu:=TPopupMenu(Configuration.FindComponent('pmBookCacheDirectory'));
        Require(Assigned(DirectoryEdit) and Assigned(ResolvedEdit) and Assigned(HelpLabel) and
          Assigned(ChooseButton) and Assigned(Menu),'Cache preset controls were not created');
        Require(SameFileName(DirectoryEdit.Text,InitialDirectory),'Opening settings changed explicit custom path');
        CheckControls;
        SelectPreset(0,'',TPath.Combine(Settings.DataPath,'BookCache'));
        SelectPreset(1,TempRoot,TPath.Combine(TempRoot,'HomeLibRu-BookCache'));
        Require(string(HelpLabel.Caption).Contains('Windows может очистить'),'Temporary-folder lifetime unexplained');
        SelectPreset(2,TPath.Combine(LocalRoot,'HomeLibRu'),TPath.Combine(TPath.Combine(LocalRoot,'HomeLibRu'),'HomeLibRu-BookCache'));
        Require(string(HelpLabel.Caption).Contains('галочкой выше'),'Persistent-folder lifetime ignores exit-cleanup toggle');
      finally Configuration.Free; Configuration:=nil; end;
    end;
    Require(Settings.BookCacheDirectory=InitialDirectory,'Cancel/close applied a draft preset');
    Configuration:=TfrmSettings.Create(nil); Configuration.LoadSetting;
    DirectoryEdit:=TEdit(Configuration.FindComponent('edBookCacheDirectory'));
    ApplyBase(TempRoot,TPath.Combine(TempRoot,'HomeLibRu-BookCache'));
    ApplyBase(TPath.Combine(LocalRoot,'HomeLibRu'),TPath.Combine(TPath.Combine(LocalRoot,'HomeLibRu'),'HomeLibRu-BookCache'));
    ApplyBase(CustomRoot,TPath.Combine(CustomRoot,'HomeLibRu-BookCache'));
    ApplyBase('',TPath.Combine(Settings.DataPath,'BookCache'));
    Require(Settings.BookCacheDirectory='','Data preset did not retain the empty default setting');
    Writeln('PASS cache folder presets preserve custom/default settings until Apply, full selectable roots, 96/144/192 DPI and private G migration/books/history/notes'); Flush(Output);
  finally
    Configuration.Free; StopBookCacheMigration; WaitIdle;
    SetEnvironmentVariable('TEMP',PChar(SavedTemp)); SetEnvironmentVariable('TMP',PChar(SavedTmp));
    SetEnvironmentVariable('LOCALAPPDATA',PChar(SavedLocal)); Settings.ClearBookCacheOnExit:=SavedExit;
    Settings.BookCacheLimitMB:=SavedLimit;
  end;
end;
