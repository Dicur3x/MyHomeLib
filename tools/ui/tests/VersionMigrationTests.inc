procedure TestVersionMigration;
var Comparison: Integer; Info: TProgramRelease; Popup: TfrmProgramUpdate;
  View: TListView; PreviousTheme, CaptionFound: Boolean;
  procedure OrderTag(const Left, Right: string);
  begin Require(CompareReleaseTags(Left,Right,Comparison) and (Comparison<0),
    'Transport release order changed: '+Left+' / '+Right); end;
  procedure OrderFile(const Left, Right: string);
  begin Require(CompareComponentVersions(Left,Right,Comparison) and (Comparison<0),
    'First-party numeric order changed: '+Left+' / '+Right); end;
  function ReleaseJSON(const Tag: string): string;
  var Name: string;
  begin
    Name:={$IFDEF WIN64}'HomeLibRu_x64.zip'{$ELSE}'HomeLibRu.zip'{$ENDIF};
    Result:='{"tag_name":"'+Tag+'","draft":false,"body":"Owned version fixture","assets":['+
      '{"name":"'+Name+'","browser_download_url":"https://github.com/Dicur3x/MyHomeLib/releases/download/'+
      Tag+'/'+Name+'","digest":"sha256:'+StringOfChar('a',64)+'","size":123}]}';
  end;
begin
  RequireIsolatedRegression;
  Require((PROGRAM_RELEASE_VERSION='3.0.0_pre1.1') and (PROGRAM_FILE_VERSION='3.0.0.1'),'Unexpected release identity');
  Require(ReleaseDisplayVersion(PROGRAM_RELEASE_VERSION)='3.0 beta 1','Wrong public beta label');
  Require(ReleaseDisplayVersion('3.0.0_pre1.2')='3.0 beta 2','Wrong next beta label');
  Require(ReleaseDisplayVersion('3.0.0')='3.0 release','Wrong final label');
  Require(ReleaseDisplayVersion('3.0.1')='3.0.1','Wrong patch label');
  Require(ReleaseDisplayVersion('3.1.0')='3.1 release','Wrong feature label');
  Require(ReleaseDisplayVersion('2.7.0_pre5.37')='2.7.0_pre5.37','Legacy tag relabelled');
  Require(ReleaseDisplayVersion('3.0.0_pre1.65535')='3.0.0_pre1.65535','Reserved final revision accepted as beta');
  OrderTag('2.7.0_pre5.33',PROGRAM_RELEASE_VERSION); OrderTag('2.7.0_pre5.37',PROGRAM_RELEASE_VERSION);
  OrderTag('3.0.0_pre1.1','3.0.0_pre1.2'); OrderTag('3.0.0_pre1.2','3.0.0');
  OrderTag('3.0.0','3.0.1'); OrderTag('3.0.1','3.1.0');
  Require(not CompareReleaseTags('3.0 beta 1',PROGRAM_RELEASE_VERSION,Comparison),'Display text accepted as tag');
  Require(not CompareReleaseTags('3.0.0_pre1.1/other',PROGRAM_RELEASE_VERSION,Comparison),'Unsafe tag accepted');
  Writeln('PASS 3.x display labels preserve legacy transport grammar and beta final patch ordering');

  OrderFile('2.7.0.1105','3.0.0.1'); OrderFile('3.0.0.1','3.0.0.2');
  OrderFile('3.0.0.65534','3.0.0.65535'); OrderFile('3.0.0.65535','3.0.1.1');
  OrderFile('3.0.1.1','3.0.1.65535'); OrderFile('3.0.1.65535','3.1.0.1');
  for var ID in TArray<string>.Create('HomeLibReader','BookConverter','BookProcessing',
    'ImageProcessing','Kindle','LegacyBooks','LegacyOffice','XPS','MHLMcpServer') do
  begin
    Require(ComponentDisplayVersion(ID,'3.0.0.1')='3.0 beta 1',ID+' beta 1');
    Require(ComponentDisplayVersion(ID,'3.0.0.2')='3.0 beta 2',ID+' beta 2');
    Require(ComponentDisplayVersion(ID,'3.0.0.65535')='3.0 release',ID+' final');
    Require(ComponentDisplayVersion(ID,'3.0.1.65535')='3.0.1',ID+' patch');
    Require(ComponentDisplayVersion(ID,'3.1.0.65535')='3.1 release',ID+' feature');
    Require(ComponentDisplayVersion(ID,'2.7.0.1105')='2.7.0.1105',ID+' legacy');
    Require(ComponentDisplayVersion(ID,'3.0.0.0')='3.0.0.0',ID+' unallocated revision');
  end;
  Require(ComponentDisplayVersion('PDFium','157.0.8086.0')='157.0.8086.0','PDFium relabelled');
  Require(ComponentDisplayVersion('WebP','3.0.0.1')='3.0.0.1','Upstream version relabelled');
  Require(ComponentDisplayVersion('DocSharp','0.21.0.0')='0.21.0','DocSharp display regressed');
  Writeln('PASS first-party components share beta labels while numeric ordering and upstream versions remain intact');

  Require(ParseProgramReleases('['+ReleaseJSON('2.7.0_pre5.37')+','+
    ReleaseJSON(PROGRAM_RELEASE_VERSION)+','+ReleaseJSON('3.0.0_pre1.2')+']',Info),'New feed rejected');
  Require((Info.Tag='3.0.0_pre1.2') and Info.DownloadURL.Contains('/3.0.0_pre1.2/'),'Download tag relabelled');
  Require(Info.Changelog.Contains('3.0 beta 2') and not Info.Changelog.Contains('2.7.0_pre5.37'),'Wrong new changelog');
  Require(ReleaseNotesHeading(PROGRAM_RELEASE_VERSION,'2026-10-30T00:00:00Z')=
    '3.0 beta 1 — 30.10.2026','Friendly dated heading lost');
  Writeln('PASS new-series feed retains exact download tags digests and legacy history');

  PreviousTheme:=MHLThemeDark;
  try
    for var Dark in [False,True] do
    begin
      SetMHLTheme(Dark); Popup:=TfrmProgramUpdate.Create(frmMain);
      try
        Info:=Default(TProgramRelease); Info.Tag:=PROGRAM_RELEASE_VERSION; Popup.SetCurrent(Info);
        View:=Popup.FindComponent('UpdateComponents') as TListView;
        Require(Assigned(View) and (View.Items.Count>0),'No native updater table');
        Require((View.Items[0].Caption='HomeLibre') and
          (View.Items[0].SubItems[0]='3.0 beta 1') and (View.Items[0].SubItems[1]='3.0 beta 1'),
          'Application table exposes transport tag');
        CaptionFound:=False;
        for var C in Popup do if C is TLabel then
          if TLabel(C).Caption='Текущая версия: 3.0 beta 1' then CaptionFound:=True;
        Require(CaptionFound,'Current-version caption not unified');
        Info.Tag:='3.0.0_pre1.2'; Info.PublishedAt:='2026-10-30';
        Popup.SetRelease(Info); CaptionFound:=False;
        for var C in Popup do if C is TLabel then
          if string(TLabel(C).Caption).Contains('HomeLibre 3.0 beta 2 — 30.10.2026') and
            not string(TLabel(C).Caption).Contains('3.0.0_pre1.2') then CaptionFound:=True;
        Require(CaptionFound,'Application proposal heading exposes the transport tag');
        Info.ComponentID:='HomeLibReader'; Info.ComponentVersion:='3.0.0.2'; Info.Tag:=ALREADER_FIXED_TAG;
        Popup.SetRelease(Info); CaptionFound:=False;
        for var C in Popup do if C is TLabel then
          if string(TLabel(C).Caption).Contains('HomeLibReader 3.0 beta 2 — 30.10.2026') and
            not string(TLabel(C).Caption).Contains('3.0.0.2') then CaptionFound:=True;
        Require(CaptionFound,'Component proposal heading exposes the numeric build');

      finally Popup.Free; end;
    end;
  finally SetMHLTheme(PreviousTheme); end;
  Require(frmMain.spInfo.Caption='3.0 beta 1','Catalogue status exposes numeric build');
  Writeln('PASS actual updater table current caption and catalogue status use unified public version in both themes');
end;
