// The completed real JPEG XL download is reused across theme/zoom cases.
// Only download transport is redirected; the official archive and verifier are unchanged.
procedure TestUpdatePopulatedDPI;
var Server:TRepairServer; Setup:TRepairForm; Dialog:TInitialDpiUpdateForm;
  ReleaseInfo:TProgramRelease; Releases:TComponentReleases;
  Metadata, Ready:TJSONObject; Fixture, Cache, Job, ManifestHash:string;
  Primary:TButton; View:TListView; Notes:TUpdateNotesView; Tabs:TTabControl;
  Measure, Frame:TBitmap; PNG:TPngImage; SavedMessage:TFont;
  SavedPPI, Checks:Integer; SavedDark:Boolean; Deadline:UInt64;
  procedure InspectReady(const Phase:string);
  var TextHeight:Integer;
  begin
    View:=Dialog.FindComponent('UpdateComponents') as TListView;
    Primary:=Dialog.FindComponent('UpdatePrimary') as TButton;
    Notes:=nil; Tabs:=nil;
    for var Control in Dialog do
    begin
      if Control is TUpdateNotesView then Notes:=TUpdateNotesView(Control);
      if Control is TTabControl then Tabs:=TTabControl(Control);
    end;
    Require(Assigned(Notes) and Assigned(Tabs),'Populated updater has no notes or tabs');
    Require((Notes.SectionCount>0) and string(Notes.SectionNotes(0).Text).Contains('Security'),
      'Restored official JPEG XL release notes are empty or replaced by a placeholder');
    Frame:=Dialog.GetFormImage;
    try PNG.Assign(Frame); PNG.SaveToFile('populated-dpi-'+Phase+'.png'); finally Frame.Free; end;
    Require(Dialog.Visible,'Prepared updater disappeared');
    Require(Primary.Enabled and (Primary.Caption='Установить и перезапустить'),
      'Prepared updater lost its installation action');
    Require(not Dialog.PendingInstall,'DPI inspection unexpectedly requested installation');
    Require(View.Items.Count>=10,'Published components did not populate the updater');
    Measure.Canvas.Font.Assign(View.Font); TextHeight:=Measure.Canvas.TextHeight('Mg');
    Require(Abs(Abs(View.Font.Height)-27)<=1,'Populated 225-percent list font was scaled twice');
    Require(View.Height>=TextHeight*5,'Populated component list shows fewer than four rows');
    for var I:=1 to View.Columns.Count-1 do
      Require(View.Columns[I].Width>=Measure.Canvas.TextWidth(View.Columns[I].Caption)+MulDiv(10,216,96),
        'Populated updater column header clipped: '+View.Columns[I].Caption);
    Require(Notes.Height>=MulDiv(72,216,96),'Ready download left no useful release-notes area');
    Require((Tabs.BoundsRect.Right<=Dialog.ClientWidth) and
      (Tabs.BoundsRect.Right<=(Dialog.FindComponent('UpdateCheckComponents') as TButton).Left),
      'Populated updater tabs overlap their check button');
    for var Control in Dialog do
      if (Control is TButton) and TButton(Control).Visible then
      begin
        var Button:=TButton(Control); Measure.Canvas.Font.Assign(Button.Font);
        Require((Button.Left>=0) and (Button.Top>=0) and
          (Button.BoundsRect.Right<=Dialog.ClientWidth) and (Button.BoundsRect.Bottom<=Dialog.ClientHeight),
          'Populated updater button lies outside its client: '+Button.Caption);
        Require(Button.Width>=Measure.Canvas.TextWidth(Button.Caption)+MulDiv(12,216,96),
          'Populated updater button caption clipped: '+Button.Caption);
      end;
    Require(UpdateSHA256(TPath.Combine(Job,'manifest.json'))=ManifestHash,'DPI check changed prepared update files');
    Inc(Checks); Writeln('PASS populated ready updater 225-percent '+Phase+' rows='+IntToStr(View.Items.Count)); Flush(Output);
    if (Phase='1-100') and FileExists(Settings.AppPath+'populated-dpi-preview.flag') then
    begin
      Writeln('TRACE populated ready 225-percent preview'); Flush(Output);
      var PreviewDeadline:=GetTickCount64+45000;
      while Dialog.Visible and (GetTickCount64<PreviewDeadline) do
      begin Application.ProcessMessages; CheckSynchronize(0); Sleep(10); end;
    end;
  end;
begin
  RequireIsolatedRegression;
  SavedMessage:=TFont.Create; SavedMessage.Assign(Screen.MessageFont);
  SavedPPI:=Screen.MessageFont.PixelsPerInch; SavedDark:=MHLThemeDark;
  Measure:=TBitmap.Create; PNG:=TPngImage.Create; Server:=nil; Setup:=nil; Dialog:=nil; Job:=''; Checks:=0;
  Fixture:=TPath.Combine(Settings.AppPath,'image-fixtures');
  try
    Require(ParseImageComponent(TFile.ReadAllText(TPath.Combine(Fixture,'release.json'),TEncoding.UTF8),
      'JPEG XL',ReleaseInfo),'Populated DPI fixture has no official JPEG XL release');
    Metadata:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Fixture,'components-release.json'),TEncoding.UTF8)) as TJSONObject;
    try
      Require(Assigned(Metadata) and ParseComponentFeed(
        TFile.ReadAllText(TPath.Combine(Fixture,'components.json'),TEncoding.UTF8),
        Metadata.GetValue<string>('tag_name'),Metadata.GetValue<TJSONArray>('assets').ToJSON,Releases,True,True),
        'Populated DPI fixture component feed failed verification');
    finally Metadata.Free; end;
    Releases[IndexText('JPEG XL',ComponentIDs)]:=ReleaseInfo;
    Server:=TRepairServer.Create; Server.URLs.Add(ReleaseInfo.DownloadURL);
    if ProgramUpdatePlatform='Win64' then Server.Files.Add(TPath.Combine(Fixture,'jxl-x64-windows-static.zip'))
    else Server.Files.Add(TPath.Combine(Fixture,'jxl-x86-windows-static.zip'));
    // Prepare only JPEG XL. Other published entries populate the later views,
    // without accidentally starting their downloads as one combined operation.
    Setup:=TRepairForm.CreateForServer(Server);
    Setup.SetRelease(ReleaseInfo);
    Writeln('TRACE populated before primary ',TButton(Setup.FindComponent('UpdatePrimary')).Caption,
      ' status=',TLabel(Setup.FindComponent('UpdateStatus')).Caption); Flush(Output);
    Primary:=Setup.FindComponent('UpdatePrimary') as TButton; Primary.Click;
    Writeln('TRACE populated after primary ',Primary.Caption,
      ' status=',TLabel(Setup.FindComponent('UpdateStatus')).Caption); Flush(Output);
    Deadline:=GetTickCount64+90000;
    repeat
      Application.ProcessMessages; CheckSynchronize(0); Sleep(1);
      Require(GetTickCount64<Deadline,'Populated DPI official download timed out: '+Primary.Caption+
        '; '+TLabel(Setup.FindComponent('UpdateStatus')).Caption+'; requests='+IntToStr(Server.Requests));
      Require(not (Primary.Enabled and (Primary.Caption='Повторить загрузку')),'Populated DPI official download failed');
    until Primary.Enabled and (Primary.Caption='Установить и перезапустить');
    Cache:=ProgramUpdateCache(Settings.AppPath);
    Ready:=TJSONObject.ParseJSONValue(TFile.ReadAllText(TPath.Combine(Cache,'ready.json'),TEncoding.UTF8)) as TJSONObject;
    try Require(Assigned(Ready),'Populated DPI download has no ready receipt'); Job:=Ready.GetValue<string>('job'); finally Ready.Free; end;
    VerifyPreparedProgramUpdate(Job,ReleaseInfo.ComponentVersion,ProgramUpdatePlatform);
    ManifestHash:=UpdateSHA256(TPath.Combine(Job,'manifest.json')); FreeAndNil(Setup);
    for var Dark in [False,True] do
    begin
      Screen.MessageFont.PixelsPerInch:=216; Screen.MessageFont.Height:=-27; SetMHLTheme(Dark);
      Dialog:=TInitialDpiUpdateForm.Create(nil);
      try
        Dialog.Caption:='HomeLibre — проверка готового обновления 225%';
        Dialog.ComponentsReceived(Releases,True,'');
        TInitialDpiUpdateForm(Dialog).ScaleAtFixturePPI(216);
        Require(Dialog.RestoreReady,'Populated 225-percent form could not restore the official ready package');
        Dialog.Show;
        Dialog.ClientWidth:=Min(MulDiv(960,216,96),Screen.WorkAreaWidth-60);
        Dialog.ClientHeight:=Min(MulDiv(760,216,96),Screen.WorkAreaHeight-80);
        Dialog.Left:=Screen.WorkAreaRect.Left+Max(0,(Screen.WorkAreaWidth-Dialog.Width) div 2);
        Dialog.Top:=Screen.WorkAreaRect.Top+Max(0,(Screen.WorkAreaHeight-Dialog.Height) div 2);
        Application.ProcessMessages;
        for var Control in Dialog do if Control is TUpdateNotesView then Notes:=TUpdateNotesView(Control);
        for var Zoom in [90,100,110] do
        begin
          Notes.ZoomPercent:=Zoom; Application.ProcessMessages;
          InspectReady(IntToStr(Ord(Dark))+'-'+IntToStr(Zoom));
        end;
        Tabs.TabIndex:=1; Tabs.OnChange(Tabs); Application.ProcessMessages;
        InspectReady(IntToStr(Ord(Dark))+'-history');
        Tabs.TabIndex:=0; Tabs.OnChange(Tabs); Dialog.Close; Application.ProcessMessages;
        Require(not Dialog.Visible and not Dialog.PendingInstall,'Closing a ready updater installed or reopened it');
      finally FreeAndNil(Dialog); end;
    end;
    Require((Checks=8) and (Server.Requests=1),'Populated DPI cases redownloaded the package or omitted a case');
    Writeln('PASS populated updater preserves ready package, close state and component list at 225 percent');
  finally
    Dialog.Free; Setup.Free; Server.Free;
    if Job<>'' then CleanProgramUpdate(Job);
    if (Cache<>'') and FileExists(TPath.Combine(Cache,'ready.json')) then TFile.Delete(TPath.Combine(Cache,'ready.json'));
    Screen.MessageFont.PixelsPerInch:=SavedPPI; Screen.MessageFont.Assign(SavedMessage);
    SavedMessage.Free; PNG.Free; Measure.Free; SetMHLTheme(SavedDark);
  end;
end;
