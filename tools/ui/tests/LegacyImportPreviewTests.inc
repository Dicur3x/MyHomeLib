// DPR uses: unit_LegacyUserDataPreview, frm_LegacyUserDataPreview.
procedure TestLegacyImportPreviewProposals;
var
  FileName, BeforeRevision, BeforeHash: string;
  Preview: TLegacyUserDataPreview;
  Dialog: TfrmLegacyUserDataPreview;
  Data: TUserData;
  Text: TStringBuilder;
  Rejected: Boolean;
  DPI: Integer;
begin
  RequireIsolatedRegression;
  FileName := Settings.AppPath + 'Предпросмотр переноса ё.MHLUD';
  TFile.WriteAllText(FileName, '# Группы'#13#10'Первая'#13#10'Историческая вторая'#13#10 +
    '# Рейтинги'#13#10'11 5'#13#10'# Прочитанное'#13#10'11 100'#13#10 +
    '# Рецензии'#13#10'11 Моя #заметка ё'#13#10 +
    '# Избранное'#13#10'11'#13#10'12 Неизвестная группа'#13#10'13 Первая', TEncoding.UTF8);
  BeforeHash := THashSHA2.GetHashStringFromFile(FileName);
  BeforeRevision := SystemDB.GetDataRevision;
  Data := TUserData.Create;
  try
    Data.Extras.AddExtra(0, 'preserved', 3, 60, 'До импорта');
    Preview := TLegacyUserDataPreview.Create(FileName);
    try
      Require((Preview.RatingCount = 1) and (Preview.ProgressCount = 1) and
        (Preview.ReviewCount = 1) and (Preview.GroupCount = 2) and
        (Preview.GroupBookCount = 3) and (Preview.MappingCount = 2) and not Preview.Ready,
        'Legacy preview summary or unresolved mappings are wrong');
      Require((Preview.Mappings[0].SourceName = '') and (Preview.Mappings[0].TargetName = ''),
        'Bare ID silently selected the historical second group');
      Rejected := False;
      try Preview.AppendTo(Data); except on E: EConvertError do Rejected := True; end;
      Require(Rejected and (Data.Extras.Count = 1) and (Data.Groups.Count = 0),
        'Unresolved preview exposed partial data');
      Dialog := TfrmLegacyUserDataPreview.CreatePreview(nil, Preview, SystemDB);
      try
        Require(not Dialog.ImportButton.Enabled and not Assigned(Dialog.MappingList.Selected) and
          (Dialog.TargetEdit.ItemIndex = -1) and (Dialog.TargetEdit.Text = '') and not Dialog.TargetEdit.Enabled,
          'Unselected unresolved preview exposes an invented target or enabled import');
        Dialog.Show; Application.ProcessMessages;
        Require((Dialog.TargetEdit.Text = '') and not Dialog.ImportButton.Enabled,
          'Showing the preview restored a component name as its target');
        Dialog.MappingList.Items[0].Selected := True;
        Dialog.TargetEdit.Text := 'Явно выбранная группа ё';
        Dialog.TargetEdit.OnChange(Dialog.TargetEdit);
        Require(not Dialog.ImportButton.Enabled, 'One unresolved mapping was accepted');
        Dialog.MappingList.Items[1].Selected := True;
        Dialog.TargetEdit.Text := 'Первая';
        Dialog.TargetEdit.OnChange(Dialog.TargetEdit);
        Require(Dialog.ImportButton.Enabled and Preview.Ready, 'Explicit mappings did not unlock import');
        for DPI in [96, 144, 192] do
        begin
          Dialog.ScaleForPPI(DPI); Application.ProcessMessages;
          Require((Dialog.MappingList.ClientHeight > 80) and
            (Dialog.TargetEdit.Width <= Dialog.ClientWidth) and
            (Dialog.ImportButton.Width >= MulDiv(100, DPI, 96)),
            'Legacy mapping list/editor/footer clipped after DPI scaling');
        end;
        Require((SystemDB.GetDataRevision = BeforeRevision) and (Data.Extras.Count = 1),
          'Opening or editing preview wrote personal data');
        Dialog.ModalResult := mrCancel; Dialog.Hide;
      finally Dialog.Free; end;
      Require((Data.Extras.Count = 1) and (Data.Groups.Count = 0), 'Canceled preview exposed staged data');
      Dialog := TfrmLegacyUserDataPreview.CreatePreview(nil, Preview, SystemDB);
      try
        Require(Dialog.ImportButton.Enabled and Preview.Ready and
          not Assigned(Dialog.MappingList.Selected) and (Dialog.TargetEdit.Text = ''),
          'Reopening ready mappings invented a target or lost their ready state');
        Dialog.Show; Application.ProcessMessages;
        Dialog.MappingList.Items[0].Selected := True;
        Require(Dialog.TargetEdit.Enabled and (Dialog.TargetEdit.Text = 'Явно выбранная группа ё'),
          'Selecting a saved mapping did not restore its explicit target');
        Dialog.Hide;
      finally Dialog.Free; end;
      Preview.AppendTo(Data);
      Require((Data.Extras.Count = 4) and (Data.Groups.Count = 3) and
        (Data.Groups[0].Count = 2) and (Data.Groups[2].GroupName = 'Явно выбранная группа ё') and
        (Data.Groups[2].Count = 1) and (Data.Groups[2][0].LibID = '11'),
        'Explicit group mappings changed or lost memberships');
    finally Preview.Free; end;
    Require(THashSHA2.GetHashStringFromFile(FileName) = BeforeHash, 'Preview changed its source file');

    Preview := TLegacyUserDataPreview.Create(FileName);
    try
      Preview.SetTarget(0, 'Новая'); Preview.SetTarget(1, 'Первая');
      TFile.AppendAllText(FileName, #13#10'14 Первая', TEncoding.UTF8);
      Rejected := False;
      try Preview.AppendTo(Data); except on E: EConvertError do Rejected := True; end;
      Require(Rejected and (Data.Extras.Count = 4), 'Changed source was accepted after preview');
    finally Preview.Free; end;

    Text := TStringBuilder.Create;
    try
      Text.AppendLine('# Избранное');
      for var I := 1 to 1500 do Text.Append(I).Append(' Группа ё ').Append(I).AppendLine;
      TFile.WriteAllText(FileName, Text.ToString, TEncoding.UTF8);
    finally Text.Free; end;
    Preview := TLegacyUserDataPreview.Create(FileName);
    try
      Require(Preview.MappingCount = 1500, 'Large own mapping list lost unresolved names');
      Dialog := TfrmLegacyUserDataPreview.CreatePreview(nil, Preview, SystemDB);
      try
        Require(Dialog.MappingList.OwnerData and (Dialog.MappingList.Items.Count = 1500),
          'Large preview allocated separate controls instead of its virtual list');
        Dialog.Show; Application.ProcessMessages;
        Dialog.MappingList.Items[1499].Selected := True;
        Dialog.MappingList.Items[1499].MakeVisible(False);
        Dialog.TargetEdit.Text := 'Последняя группа'; Dialog.TargetEdit.OnChange(Dialog.TargetEdit);
        Require((Preview.Mappings[1499].TargetName = 'Последняя группа') and not Preview.Ready,
          'Virtual last-row editor updated the wrong mapping');
        Dialog.Hide;
      finally Dialog.Free; end;
    finally Preview.Free; end;
    Require(SystemDB.GetDataRevision = BeforeRevision, 'Preview-only scenarios changed the system DB');
  finally Data.Free; end;
  Writeln('PASS proposal legacy target editor starts empty until row selection and restores explicitly saved mappings');
  Writeln('PASS proposal legacy preview counts, explicit ambiguous mappings, cancel, stale-source rejection and 1500-row virtual editor');
end;

type
  TLegacyPreviewVisualDriver = class
    procedure Shown(Sender: TObject);
  end;

procedure TLegacyPreviewVisualDriver.Shown(Sender: TObject);
begin
  TForm(Sender).ScaleForPPI(192);
  ApplyMHLControlTheme(TForm(Sender));
end;

procedure TestCatalogProposalsVisual;
var
  FileName, Revision, SourceHash: string;
  Preview: TLegacyUserDataPreview;
  Dialog: TfrmLegacyUserDataPreview;
  Driver: TLegacyPreviewVisualDriver;
  SavedTheme: Boolean;
begin
  RequireIsolatedRegression;
  FileName := Settings.AppPath + 'Наглядный перенос ё.MHLUD';
  TFile.WriteAllText(FileName, '# Группы'#13#10'Избранные книги'#13#10'Вторая группа'#13#10 +
    '# Рейтинги'#13#10'101 5'#13#10'# Прочитанное'#13#10'101 72'#13#10 +
    '# Рецензии'#13#10'101 Моя заметка #ё 日本語'#13#10 +
    '# Избранное'#13#10'101'#13#10'102 Неизвестная группа ё', TEncoding.UTF8);
  Revision := SystemDB.GetDataRevision; SourceHash := THashSHA2.GetHashStringFromFile(FileName);
  Preview := TLegacyUserDataPreview.Create(FileName); Driver := TLegacyPreviewVisualDriver.Create;
  SavedTheme := MHLThemeDark;
  try
    SetMHLTheme(True);
    Dialog := TfrmLegacyUserDataPreview.CreatePreview(nil, Preview, SystemDB);
    try
      Dialog.Caption := Dialog.Caption + ' — собственный тест';
      Dialog.OnShow := Driver.Shown;
      Writeln('VISUAL proposal legacy preview dark 192 DPI: choose mappings or close with Cancel; no automatic acceptance');
      Flush(Output);
      Dialog.ShowModal;
    finally Dialog.Free; end;
    Require((SystemDB.GetDataRevision = Revision) and
      (THashSHA2.GetHashStringFromFile(FileName) = SourceHash), 'Visual preview changed catalog/source');
  finally SetMHLTheme(SavedTheme); Driver.Free; Preview.Free; end;
  Writeln('PASS proposal legacy visual preview closed without catalog/source changes');
end;
