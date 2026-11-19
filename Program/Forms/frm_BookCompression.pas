unit frm_BookCompression;

interface

uses System.Classes, System.SysUtils, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.Controls, unit_BookCompressionOperation, frm_CatalogSources, unit_ContextToolGuide;

type
  TCompressionReviewEvent = procedure(Decision: TCompressionReview; const BackupFolder: string) of object;

  TfrmBookCompressionOptions = class(TSourceDialogForm)
  private
    FProfile: TComboBox;
    FGray, FReview, FBackup: TCheckBox;
    FExplanation, FSpace, FWorkLabel, FBackupNote: TLabel;
    FWork, FBackupFolder: TEdit;
    FWorkBrowse, FBackupBrowse, FStart, FCancel, FEstimate: TButton;
    FOptions: TBookCompressionOperationOptions;
    FLayoutScale: Integer;
    FToolGuide:TContextToolGuide;
    procedure ProfileChanged(Sender: TObject);
    procedure BrowseWork(Sender: TObject);
    procedure BrowseBackup(Sender: TObject);
    procedure BackupChanged(Sender: TObject);
    procedure Accept(Sender: TObject);
  protected
    procedure DoShow; override;
    procedure DoHide; override;
  public
    constructor CreateOptions(AOwner: TComponent; BookCount: Integer;
      const Options: TBookCompressionOperationOptions);
    procedure ScaleForPPI(NewPPI: Integer); override;
    function SelectedOptions: TBookCompressionOperationOptions;
  end;

  // A modeless observer. The catalogue owns the worker, timer and refresh;
  // destroying this view never destroys a live compression operation.
  TfrmBookCompressionProgress = class(TSourceDialogForm)
  private
    FStage, FSource, FMember, FCounts, FSizes, FNote: TLabel;
    FProgress: TProgressBar;
    FStop, FApply, FApplyAll, FSkip, FPin, FCompare, FTrial, FStorage: TButton;
    FResult: TBookCompressionOperationStatus;
    FPreviewFile, FPreviewSHA256, FBackupPath: string;
    FOnStop: TNotifyEvent;
    FOnReview: TCompressionReviewEvent;
    FFinished, FChooseBackupOnApply: Boolean;
    procedure StopClick(Sender: TObject);
    procedure ReviewClick(Sender: TObject);
    procedure PinClick(Sender: TObject);
    procedure CloseView(Sender: TObject; var Action: TCloseAction);
    procedure CompareClick(Sender: TObject);
    procedure StorageClick(Sender: TObject);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor CreateProgress(AOwner: TComponent; Stop: TNotifyEvent;
      Review: TCompressionReviewEvent);
    procedure UpdateProgress(const State: TBookCompressionOperationStatus);
    procedure ShowResult(const State: TBookCompressionOperationStatus;
      const RefreshError: string = '');
  end;

function ChooseSelectedCompressionOptions(Owner: TForm; BookCount: Integer;
  var Options: TBookCompressionOperationOptions; AfterInstall: Boolean = False): Boolean;

implementation

uses Winapi.Windows, Winapi.ShellAPI, System.Math, System.IOUtils, Vcl.Dialogs, Vcl.Graphics, Vcl.ExtCtrls,
  unit_MHLTheme, unit_CollectionSpace, frm_BookCompressionCompare;

const Profiles: array[0..3] of string = ('original','balanced','economy','maximum');

type
  TCompressionStorageReport = class(TSourceDialogForm)
  private
    FPaths: TArray<string>;
    FBackups: TListView;
    FSelectedPath: TEdit;
    FOpen: TButton;
    procedure BackupData(Sender: TObject; Item: TListItem);
    procedure BackupSelected(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure OpenBackup(Sender: TObject);
  public
    constructor CreateForResult(Owner: TCustomForm; const State: TBookCompressionOperationStatus);
  end;

function SizeText(Bytes: Int64): string;
begin
  if Bytes>=Int64(1024)*1024*1024 then Result:=FormatFloat('0.00',Bytes/(Int64(1024)*1024*1024))+' ГБ'
  else if Bytes>=1024*1024 then Result:=FormatFloat('0.0',Bytes/(1024*1024))+' МБ'
  else if Bytes>=1024 then Result:=FormatFloat('0.0',Bytes/1024)+' КБ'
  else Result:=IntToStr(Bytes)+' Б';
end;

function CompressionNetText(NetBytes: Int64): string;
begin
  if NetBytes > 0 then Result := 'Освобождено ' + SizeText(NetBytes)
  else if NetBytes < 0 then Result := 'Дополнительно занято ' + SizeText(-NetBytes)
  else Result := 'Без изменения места';
end;

function MakeLabel(Owner: TForm; const Name: string; Y, Height: Integer): TLabel;
begin
  Result:=TLabel.Create(Owner); Result.Parent:=Owner; Result.Name:=Name;
  Result.AutoSize:=False; Result.WordWrap:=True;
  Result.SetBounds(16,Y,Owner.ClientWidth-32,Height);
  Result.Anchors:=[akLeft,akTop,akRight];
end;

function MakeButton(Owner: TForm; const Name, Caption: string; X, Y, Width: Integer;
  Click: TNotifyEvent): TButton;
begin
  Result:=TButton.Create(Owner); Result.Parent:=Owner; Result.Name:=Name;
  Result.Caption:=Caption; Result.SetBounds(X,Y,Width,30);
  Result.Anchors:=[akRight,akBottom]; Result.OnClick:=Click;
end;

constructor TCompressionStorageReport.CreateForResult(Owner: TCustomForm;
  const State: TBookCompressionOperationStatus);
var Summary: TMemo; Footer: TPanel; Button: TButton;
begin
  inherited CreateNew(Owner);
  Name := 'CompressionStorageReport'; Caption := 'Место на дисках и оригиналы';
  Position := poOwnerFormCenter; PopupMode := pmExplicit; PopupParent := Owner;
  BorderStyle := bsSizeable; Font.Name := 'Segoe UI'; Font.Size := 9;
  ClientWidth := 750; ClientHeight := 490; Constraints.MinWidth := 540; Constraints.MinHeight := 390;
  FPaths := State.BackupPaths;
  Footer := TPanel.Create(Self); Footer.Parent := Self; Footer.Align := alBottom;
  Footer.Height := 52; Footer.BevelOuter := bvNone;
  Button := TButton.Create(Self); Button.Parent := Footer; Button.Name := 'CompressionStorageClose';
  Button.Caption := 'Закрыть'; Button.SetBounds(622, 10, 116, 30);
  Button.Anchors := [akTop, akRight]; Button.ModalResult := mrCancel; Button.Cancel := True;
  Summary := TMemo.Create(Self); Summary.Parent := Self; Summary.Name := 'CompressionDiskBalance';
  Summary.Clear;
  Summary.ReadOnly := True; Summary.ScrollBars := ssVertical; Summary.Height := 185;
  Summary.AlignWithMargins := True; Summary.Margins.SetBounds(12, 12, 12, 6);
  if Length(FPaths) > 0 then Summary.Align := alTop else Summary.Align := alClient;
  Summary.Lines.Add('Изменение места по размерам файлов');
  for var Disk in State.Disks do
    Summary.Lines.Add(Format('%s · Рабочие файлы уменьшились на %s · ZIP оригиналов %s · %s',
      [ExcludeTrailingPathDelimiter(Disk.Volume), SizeText(Disk.ReductionBytes),
       SizeText(Disk.BackupBytes), CompressionNetText(Disk.ReductionBytes - Disk.BackupBytes)]));
  Summary.Lines.Add('');
  Summary.Lines.Add('Всего · ' + CompressionNetText(State.SavedBytes - State.BackupBytes));
  if Length(FPaths) > 0 then
  begin
    Summary.Lines.Add('');
    Summary.Lines.Add('Откройте ZIP и извлеките нужную книгу из папки books в отдельную папку. ' +
      'Добавьте её в коллекцию и проверьте путь и открытие в карточке книги. ' +
      'Для книги из общего архива ZIP оригиналов содержит выбранные книги. ' +
      'В HomeLibre-originals.json указано их исходное расположение.');
    FSelectedPath := TEdit.Create(Self); FSelectedPath.Parent := Self;
    FSelectedPath.Name := 'CompressionOriginalZipPath'; FSelectedPath.Clear;
    FSelectedPath.ReadOnly := True; FSelectedPath.Align := alBottom;
    FSelectedPath.AlignWithMargins := True; FSelectedPath.Margins.SetBounds(12, 6, 12, 0);
    FSelectedPath.Hint := 'Полный путь к выбранному ZIP. Его можно скопировать.';
    FSelectedPath.ShowHint := True;
    FBackups := TListView.Create(Self); FBackups.Parent := Self; FBackups.Name := 'CompressionOriginalZips';
    FBackups.Align := alClient; FBackups.AlignWithMargins := True;
    FBackups.Margins.SetBounds(12, 0, 12, 0);
    FBackups.ViewStyle := vsReport; FBackups.OwnerData := True; FBackups.ReadOnly := True;
    FBackups.RowSelect := True; FBackups.HideSelection := False;
    with FBackups.Columns.Add do begin Caption := 'ZIP оригиналов'; Width := 310; end;
    with FBackups.Columns.Add do begin Caption := 'Папка'; Width := 370; end;
    FBackups.OnData := BackupData; FBackups.OnSelectItem := BackupSelected;
    FBackups.OnDblClick := OpenBackup; FBackups.Items.Count := Length(FPaths);
    FOpen := TButton.Create(Self); FOpen.Parent := Footer; FOpen.Name := 'CompressionOpenOriginalZip';
    FOpen.Caption := 'Открыть ZIP'; FOpen.SetBounds(12, 10, 132, 30);
    FOpen.OnClick := OpenBackup; FOpen.Enabled := False;
  end;
  ScaleForPPI(Owner.CurrentPPI);
  ApplyMHLControlTheme(Self);
  if Assigned(FBackups) then FBackups.Selected := FBackups.Items[0];
end;

procedure TCompressionStorageReport.BackupData(Sender: TObject; Item: TListItem);
begin
  Item.Caption := ExtractFileName(FPaths[Item.Index]);
  Item.SubItems.Add(ExtractFileDir(FPaths[Item.Index]));
end;

procedure TCompressionStorageReport.BackupSelected(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if not Assigned(FOpen) then Exit;
  var Current := FBackups.Selected;
  FOpen.Enabled := Assigned(Current);
  if Assigned(Current) then FSelectedPath.Text := FPaths[Current.Index]
  else FSelectedPath.Clear;
end;

procedure TCompressionStorageReport.OpenBackup(Sender: TObject);
begin
  if not Assigned(FBackups.Selected) then Exit;
  var Path := FPaths[FBackups.Selected.Index];
  if NativeInt(ShellExecute(Handle, 'open', PChar(Path), nil, nil, SW_SHOWNORMAL)) <= 32 then
    ShowMessage('Не удалось открыть ZIP оригиналов. ' + Path);
end;

constructor TfrmBookCompressionOptions.CreateOptions(AOwner: TComponent;
  BookCount: Integer; const Options: TBookCompressionOperationOptions);
begin
  inherited CreateNew(AOwner); Name:='BookCompressionOptions';
  if BookCount=0 then Caption:='Сжать текущую коллекцию'
  else Caption:=Format('Сжать выбранные книги · %d',[BookCount]);
  if Options.OnlyNew then Caption:='Сжать новые книги';
  Position:=poOwnerFormCenter; BorderStyle:=bsDialog;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=640; ClientHeight:=412; FOptions:=Options; FLayoutScale:=96;
  MakeLabel(Self,'CompressionOptionsIntro',16,46).Caption:=
    'Книги останутся на прежних местах. Соседние книги в общих архивах не меняются. '+
    'Результат заменит исходный файл, только если станет меньше.';
  if BookCount=0 then TLabel(FindComponent('CompressionOptionsIntro')).Caption:=
    'Доступные книги текущей коллекции и её источников останутся на прежних местах. '+
    'Архив или файл заменится, только если станет меньше.';
  if Options.OnlyNew then TLabel(FindComponent('CompressionOptionsIntro')).Caption:=
    'Проверим новые и изменившиеся файлы. Уже проверенные с теми же настройками пропускаются. '+
    'При смене качества могут проверяться и прежние книги.';
  MakeLabel(Self,'CompressionProfileLabel',72,20).Caption:='Как сжимать (запоминается для этой коллекции)';
  FProfile:=TComboBox.Create(Self); FProfile.Parent:=Self; FProfile.Name:='CompressionProfile';
  FProfile.SetBounds(16,96,608,26); FProfile.Style:=csDropDownList;
  FProfile.Items.Add('Без пересжатия цветных изображений');
  FProfile.Items.Add('Сбалансированно'); FProfile.Items.Add('Экономно');
  FProfile.Items.Add('Максимальная экономия'); FProfile.ItemIndex:=1;
  for var I:=0 to High(Profiles) do if Profiles[I]=Options.Profile then FProfile.ItemIndex:=I;
  FProfile.OnChange:=ProfileChanged;
  FExplanation:=MakeLabel(Self,'CompressionProfileExplanation',132,48);
  FGray:=TCheckBox.Create(Self); FGray.Parent:=Self; FGray.Name:='CompressionGrayscale';
  FGray.SetBounds(16,184,608,24); FGray.Caption:='Перевести изображения в оттенки серого';
  FGray.Checked:=Options.Grayscale; FGray.OnClick:=ProfileChanged;
  FReview:=TCheckBox.Create(Self); FReview.Parent:=Self; FReview.Name:='CompressionReview';
  FReview.SetBounds(16,212,608,24); FReview.Caption:='Проверять результат перед заменой каждого архива или файла';
  FReview.Checked:=Options.ReviewResults;
  FBackup:=TCheckBox.Create(Self); FBackup.Parent:=Self; FBackup.Name:='CompressionBackup';
  FBackup.SetBounds(16,240,608,24); FBackup.Caption:='Сохранить оригиналы выбранных книг';
  if BookCount=0 then FBackup.Caption:='Сохранить оригиналы обрабатываемых книг';
  FBackup.Checked:=Options.BackupOriginals; FBackup.OnClick:=BackupChanged;
  FBackupFolder:=TEdit.Create(Self); FBackupFolder.Parent:=Self; FBackupFolder.Name:='CompressionBackupFolder';
  FBackupFolder.ReadOnly:=True; FBackupFolder.SetBounds(16,270,484,25);
  FBackupFolder.Text:=Options.BackupFolder; FBackupFolder.ShowHint:=True;
  FBackupBrowse:=MakeButton(Self,'CompressionBackupBrowse','Выбрать…',508,268,116,BrowseBackup);
  FBackupBrowse.Anchors:=[akTop,akRight];
  FBackupNote:=MakeLabel(Self,'CompressionBackupNote',306,40);
  FBackupNote.Caption:='Только выбранные оригиналы в ZIP, без копии всей коллекции или общего архива. Папка сохранения:';
  FWorkLabel:=MakeLabel(Self,'CompressionWorkLabel',282,20);
  FWorkLabel.Caption:='Временные файлы — это не копия всей коллекции';
  FWork:=TEdit.Create(Self); FWork.Parent:=Self; FWork.Name:='CompressionWorkFolder';
  FWork.ReadOnly:=True; FWork.SetBounds(16,274,484,25); FWork.Text:=Options.WorkRoot;
  FWorkBrowse:=MakeButton(Self,'CompressionWorkBrowse','Выбрать…',508,272,116,BrowseWork);
  FWorkBrowse.Anchors:=[akTop,akRight];
  FSpace:=MakeLabel(Self,'CompressionWorkSpace',308,44);
  FCancel:=MakeButton(Self,'CompressionCancel','Отмена',508,366,116,nil);
  FCancel.ModalResult:=mrCancel; FCancel.Cancel:=True;
  FStart:=MakeButton(Self,'CompressionStart','Подготовить сжатие',316,366,180,Accept);
  FEstimate:=MakeButton(Self,'CompressionEstimate','Оценить размер',16,366,180,Accept);
  FEstimate.Anchors:=[akLeft,akBottom];
  FEstimate.Hint:='Расчёт по образцам, до 10 секунд на книгу. Книги не заменяются, общие архивы не перепаковываются.';
  FEstimate.ShowHint:=True;
  FStart.Default:=True;
  TLabel(FindComponent('CompressionOptionsIntro')).Width:=566;
  FToolGuide:=TContextToolGuide.CreateForTool(Self,Self,'book-compression','Как сжимать книги',
    'Сначала попробуйте сжатие на нескольких книгах и сравните изображения.',
    '«Оценить размер» проверяет образцы и не заменяет книги. Прогноз может отличаться от результата.'+sLineBreak+
    '«Подготовить сжатие» обрабатывает книги по нынешним путям. За раз готовится один архив или файл; соседние книги сохраняются.'+sLineBreak+
    'Режимы с уменьшением качества могут ухудшить мелкий текст и схемы. Включите проверку результата и смотрите образцы в масштабе 100%.'+sLineBreak+
    'Для побайтового восстановления JPEG в FB2, EPUB и PDF выберите «Коллекция → Создать сжатую копию… → JPEG XL без потери качества». Эта команда создаёт отдельную коллекцию.'+sLineBreak+
    'Для возврата включите сохранение оригиналов и выберите папку. Это копии обрабатываемых книг, а не всей коллекции; журнал восстановления не заменяет оригиналы.',
    110,'compression');
  FToolGuide.Name:='CompressionContextGuide';
  BackupChanged(nil); ProfileChanged(nil); ApplyMHLControlTheme(Self);
end;

procedure TfrmBookCompressionOptions.DoShow;
begin inherited; FToolGuide.FirstUse; end;

procedure TfrmBookCompressionOptions.DoHide;
begin if Assigned(FToolGuide) then FToolGuide.Hide; inherited; end;

procedure TfrmBookCompressionOptions.BackupChanged(Sender: TObject);
var WorkY, Extra: Integer;
  function Px(Value: Integer): Integer;
  begin Result:=MulDiv(Value,FLayoutScale,96); end;
begin
  if not Assigned(FCancel) then Exit;
  Extra:=0; if FBackup.Checked then Extra:=80;
  ClientHeight:=Px(446+Extra); WorkY:=282+Extra;
  FBackupFolder.Visible:=FBackup.Checked; FBackupBrowse.Visible:=FBackup.Checked;
  FBackupNote.Visible:=FBackup.Checked; FBackupFolder.Hint:=FBackupFolder.Text;
  FWorkLabel.Top:=Px(WorkY); FWork.Top:=Px(WorkY+24);
  FWorkBrowse.Top:=Px(WorkY+22); FSpace.Top:=Px(WorkY+58);
  FCancel.Top:=Px(400+Extra); FStart.Top:=FCancel.Top;
end;

procedure TfrmBookCompressionOptions.ScaleForPPI(NewPPI: Integer);
begin
  inherited;
  FLayoutScale:=NewPPI;
  if Assigned(FCancel) then BackupChanged(nil);
end;

procedure TfrmBookCompressionOptions.BrowseBackup(Sender: TObject);
var Picker: TFileOpenDialog;
begin
  Picker:=TFileOpenDialog.Create(Self);
  try
    Picker.Title:='Куда сохранить оригиналы выбранных книг';
    Picker.Options:=[fdoPickFolders,fdoForceFileSystem,fdoPathMustExist];
    if DirectoryExists(FBackupFolder.Text) then Picker.DefaultFolder:=FBackupFolder.Text;
    if Picker.Execute(Handle) then
    begin FBackupFolder.Text:=Picker.FileName; FBackupFolder.Hint:=Picker.FileName; end;
  finally Picker.Free; end;
end;

procedure TfrmBookCompressionOptions.ProfileChanged(Sender: TObject);
var ProfileIndex: Integer; OriginalCaption: string;
begin
  ProfileIndex := FProfile.ItemIndex;
  if FGray.Checked then OriginalCaption := 'Только перевод в оттенки серого'
  else OriginalCaption := 'Без пересжатия цветных изображений';
  if FProfile.Items[0] <> OriginalCaption then
  begin
    FProfile.Items[0] := OriginalCaption;
    FProfile.ItemIndex := ProfileIndex;
  end;
  case ProfileIndex of
    0: if FGray.Checked then
         FExplanation.Caption := 'Цветные изображения будут переведены в оттенки серого. Сжатие иллюстраций для уменьшения размеров и детализации отключено.'
       else
         FExplanation.Caption := 'Изображения и текст сохраняются. Размер файлов может уменьшиться за счёт упаковки.';
    1: FExplanation.Caption:='Умеренное сжатие иллюстраций FB2, EPUB, ODT, DOCX и страниц CBZ. Текст сохраняется; сложные изображения стоит проверить.';
    2: FExplanation.Caption:='Более сильное сжатие иллюстраций FB2, EPUB, ODT, DOCX и страниц CBZ. Размер и детализация изображений могут уменьшиться.';
    3: FExplanation.Caption:='Сильнее уменьшает иллюстрации FB2, EPUB, ODT, DOCX, страницы CBZ и фон подходящих сканов DjVu. Мелкие детали могут стать хуже видны.';
  end;
  var Free:=CollectionDiskFree(FWork.Text);
  FSpace.Caption:='Место проверяется перед обработкой. За раз подготавливается один архив или файл.';
  if Free>=0 then FSpace.Caption:=FSpace.Caption+' Свободно: '+SizeText(Free)+'.';
end;

procedure TfrmBookCompressionOptions.BrowseWork(Sender: TObject);
var Picker: TFileOpenDialog;
begin
  Picker:=TFileOpenDialog.Create(Self);
  try
    Picker.Title:='Где хранить временные файлы сжатия';
    Picker.Options:=[fdoPickFolders,fdoForceFileSystem,fdoPathMustExist];
    if DirectoryExists(FWork.Text) then Picker.DefaultFolder:=FWork.Text;
    if Picker.Execute(Handle) then
    begin FWork.Text:=TPath.Combine(Picker.FileName,'HomeLibre-compression-work'); ProfileChanged(nil); end;
  finally Picker.Free; end;
end;

function TfrmBookCompressionOptions.SelectedOptions: TBookCompressionOperationOptions;
begin
  Result:=FOptions; Result.Profile:=Profiles[EnsureRange(FProfile.ItemIndex,0,High(Profiles))];
  Result.Grayscale:=FGray.Checked; Result.ReviewResults:=FReview.Checked;
  Result.WorkRoot:=FWork.Text;
  Result.BackupOriginals:=FBackup.Checked; Result.BackupFolder:=FBackupFolder.Text;
end;

procedure TfrmBookCompressionOptions.Accept(Sender: TObject);
begin
  if (FWork.Text='') or not TPath.IsPathRooted(FWork.Text) then
    raise EArgumentException.Create('Выберите папку для временных файлов сжатия.');
  if (Sender <> FEstimate) and FBackup.Checked and not CompressionBackupFolderAvailable(FBackupFolder.Text) then
    raise EArgumentException.Create('Выберите папку для оригиналов или снимите галочку их сохранения.');
  FOptions.EstimateFirst:=Sender=FEstimate;
  ModalResult:=mrOk;
end;

function ChooseSelectedCompressionOptions(Owner: TForm; BookCount: Integer;
  var Options: TBookCompressionOperationOptions; AfterInstall: Boolean): Boolean;
var Dialog: TfrmBookCompressionOptions;
begin
  Dialog:=TfrmBookCompressionOptions.CreateOptions(Owner,BookCount,Options);
  if AfterInstall then Dialog.Caption:=Dialog.Caption+' — после установки компонентов';
  try
    Result:=Dialog.ShowModal=mrOk;
    if Result then Options:=Dialog.SelectedOptions;
  finally Dialog.Free; end;
end;

constructor TfrmBookCompressionProgress.CreateProgress(AOwner: TComponent;
  Stop: TNotifyEvent; Review: TCompressionReviewEvent);
begin
  inherited CreateNew(AOwner); Name:='BookCompressionProgress'; Caption:='Сжатие книг';
  Position:=poOwnerFormCenter; BorderStyle:=bsSizeable;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=700; ClientHeight:=460; Constraints.MinWidth:=650; Constraints.MinHeight:=480;
  FOnStop:=Stop; FOnReview:=Review;
  FStage:=MakeLabel(Self,'CompressionStage',16,44); FStage.Font.Style:=[fsBold];
  FSource:=MakeLabel(Self,'CompressionSource',68,24); FSource.WordWrap:=False;
  FSource.EllipsisPosition:=epPathEllipsis; FSource.ShowHint:=True;
  FMember:=MakeLabel(Self,'CompressionMember',98,24); FMember.WordWrap:=False;
  FMember.EllipsisPosition:=epPathEllipsis; FMember.ShowHint:=True;
  FProgress:=TProgressBar.Create(Self); FProgress.Parent:=Self; FProgress.Name:='CompressionProgress';
  FProgress.SetBounds(16,138,668,18); FProgress.Anchors:=[akLeft,akTop,akRight]; FProgress.Max:=1000;
  FCounts:=MakeLabel(Self,'CompressionCounts',170,30);
  FSizes:=MakeLabel(Self,'CompressionSizes',206,44);
  FNote:=MakeLabel(Self,'CompressionNote',258,86);
  FCompare:=MakeButton(Self,'CompressionCompare','Сравнить изображения…',16,354,220,CompareClick);
  FCompare.Anchors:=[akLeft,akBottom];
  FStorage:=MakeButton(Self,'CompressionStorage','Место и оригиналы…',16,354,220,StorageClick);
  FStorage.Anchors:=[akLeft,akBottom];
  FApply:=MakeButton(Self,'CompressionApply','Применить',16,414,126,ReviewClick); FApply.Tag:=Ord(crApply);
  FApply.Anchors:=[akLeft,akBottom];
  FApplyAll:=MakeButton(Self,'CompressionApplyAll','Применять остальные',150,414,184,ReviewClick); FApplyAll.Tag:=Ord(crApplyRemaining);
  FApplyAll.Anchors:=[akLeft,akBottom];
  FTrial:=MakeButton(Self,'CompressionTrial','Пробная упаковка…',150,414,184,ReviewClick);
  FTrial.Tag:=Ord(crTrial); FTrial.Anchors:=[akLeft,akBottom];
  FSkip:=MakeButton(Self,'CompressionSkip','Пропустить',342,414,126,ReviewClick); FSkip.Tag:=Ord(crSkip);
  FSkip.Anchors:=[akLeft,akBottom];
  FStop:=MakeButton(Self,'CompressionStop','Остановить',558,414,126,StopClick);
  FPin:=MakeButton(Self,'CompressionPin','Поверх окон',558,12,126,PinClick); FPin.Anchors:=[akTop,akRight];
  FStage.Width:=526; FStage.Anchors:=[akLeft,akTop,akRight];
  OnClose:=CloseView;
  UpdateProgress(Default(TBookCompressionOperationStatus)); ApplyMHLControlTheme(Self);
end;

procedure TfrmBookCompressionProgress.CreateParams(var Params: TCreateParams);
begin
  inherited; Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW) and not WS_EX_TOOLWINDOW;
end;

procedure TfrmBookCompressionProgress.PinClick(Sender: TObject);
begin
  if FormStyle=fsStayOnTop then begin FormStyle:=fsNormal; FPin.Caption:='Поверх окон'; end
  else begin FormStyle:=fsStayOnTop; FPin.Caption:='Открепить'; end;
end;

procedure TfrmBookCompressionProgress.CloseView(Sender: TObject; var Action: TCloseAction);
begin Action:=caHide; end;

procedure TfrmBookCompressionProgress.StopClick(Sender: TObject);
begin
  if FFinished then begin Hide; Exit; end;
  FStop.Enabled:=False;
  if Assigned(FOnStop) then FOnStop(Self);
end;

procedure TfrmBookCompressionProgress.ReviewClick(Sender: TObject);
var Decision: TCompressionReview; Folder: string; Picker: TFileOpenDialog;
begin
  Decision := TCompressionReview(TButton(Sender).Tag);
  Folder := '';
  if FChooseBackupOnApply and (Decision = crApply) and not CompressionBackupFolderAvailable(FBackupPath) then
  begin
    Picker := TFileOpenDialog.Create(Self);
    try
      Picker.Title := 'Выберите папку для оригиналов книг';
      Picker.Options := [fdoPickFolders, fdoForceFileSystem, fdoPathMustExist];
      if not Picker.Execute(Handle) then Exit;
      Folder := Picker.FileName;
    finally Picker.Free; end;
  end;
  FApply.Enabled:=False; FApplyAll.Enabled:=False; FSkip.Enabled:=False; FTrial.Enabled:=False;
  if Assigned(FOnReview) then FOnReview(Decision, Folder);
end;

procedure TfrmBookCompressionProgress.CompareClick(Sender:TObject);
var Dialog:TfrmBookCompressionCompare;
begin
  try
    Dialog:=TfrmBookCompressionCompare.CreateComparison(Self,FPreviewFile,FPreviewSHA256);
    try Dialog.ShowModal; finally Dialog.Free; end;
  except on E:Exception do
    MessageDlg('Не удалось открыть сравнение. '+E.Message,mtWarning,[mbOK],0);
  end;
end;

procedure TfrmBookCompressionProgress.StorageClick(Sender: TObject);
var Dialog: TCompressionStorageReport;
begin
  Dialog := TCompressionStorageReport.CreateForResult(Self, FResult);
  try Dialog.ShowModal; finally Dialog.Free; end;
end;

procedure TfrmBookCompressionProgress.UpdateProgress(const State: TBookCompressionOperationStatus);
begin
  FFinished:=State.Finished; FStage.Caption:=State.Stage;
  if FStage.Caption='' then FStage.Caption:='Подготавливаем сжатие…';
  FSource.Caption:=State.Source; FSource.Hint:=State.Source;
  FMember.Caption:=State.Member; FMember.Hint:=State.Member;
  FChooseBackupOnApply := State.AwaitingEstimate and State.BackupRequested;
  FBackupPath := State.BackupFolder;
  FProgress.Visible := not (State.Finished or State.AwaitingReview);
  if (State.Total>0) and FProgress.Visible then
  begin
    FProgress.Style:=pbstNormal;
    FProgress.Position:=Round(EnsureRange(State.Current/State.Total,0.0,1.0)*1000);
  end
  else if FProgress.Visible then FProgress.Style:=pbstMarquee;
  if State.FilesTotal>0 then
  begin
    if State.Recovery then FCounts.Caption:=Format('Архивы и файлы: %d из %d',[State.FilesDone,State.FilesTotal])
    else FCounts.Caption:=Format('Архивы и файлы: %d из %d · Книги: %d из %d',
      [State.FilesDone,State.FilesTotal,State.BooksDone,State.BooksTotal]);
  end
  else if State.Recovery then
  begin
    if State.Finished then FCounts.Caption:='Проверка незавершённого сжатия завершена.'
    else FCounts.Caption:='Проверяем незавершённое сжатие…';
  end
  else FCounts.Caption:='Проверяем выбранные книги…';
  if State.AwaitingEstimate or State.EstimateOnly then
  begin
    if State.EstimateUnknownBooks=0 then
      FSizes.Caption:='Выбранные книги: '+SizeText(State.EstimateInputBytes)+' → ≈ '+SizeText(State.EstimateOutputBytes)
    else FSizes.Caption:='Оценённая часть: '+SizeText(State.EstimateKnownInputBytes)+' → ≈ '+
      SizeText(State.EstimateOutputBytes)+' · Без оценки: '+IntToStr(State.EstimateUnknownBooks);
    if State.TrialReady then
    begin
      var Scope:='Файлы и архивы';
      if State.TrialSharedFiles>0 then Scope:='Измеренная часть';
      FSizes.Caption:=FSizes.Caption+sLineBreak+Scope+': '+SizeText(State.TrialInputBytes)+' → '+
        SizeText(State.TrialOutputBytes)+' · Уменьшение: '+SizeText(State.TrialInputBytes-State.TrialOutputBytes);
    end
    else FSizes.Caption:=FSizes.Caption+sLineBreak+'На диске: файлы и общие архивы целиком — '+SizeText(State.EstimateArchiveBytes);
    FCounts.Caption:=Format('Выбрано книг: %d · Архивов и отдельных файлов: %d',[State.BooksTotal,State.FilesTotal]);
  end
  else if State.TrialRunning then FSizes.Caption:='Пробная упаковка · исходные файлы сохраняются.'
  else if State.Estimating then FSizes.Caption:='Оценка ещё идёт. Исходные файлы не изменяются.'
  else if State.AwaitingReview then FSizes.Caption:='Этот файл: '+SizeText(State.InputBytes)+' → '+
    SizeText(State.OutputBytes)+' · Уменьшение: '+SizeText(State.InputBytes-State.OutputBytes)
  else if State.SavingsKnown and (State.BackupFiles > 0) then
    FSizes.Caption := 'Рабочие файлы уменьшились на ' + SizeText(State.SavedBytes) +
      ' · ZIP оригиналов ' + SizeText(State.BackupBytes) + sLineBreak +
      'Итог — ' + CompressionNetText(State.SavedBytes - State.BackupBytes)
  else if State.SavingsKnown then FSizes.Caption:='Освобождено: '+SizeText(State.SavedBytes)
  else if State.Finished then FSizes.Caption:='Экономия места при восстановлении не пересчитывалась.'
  else FSizes.Caption:='Завершаем ранее начатое сжатие. Размер экономии сейчас не подсчитывается.';
  if State.WorkingBytes>0 then FSizes.Caption:=FSizes.Caption+sLineBreak+
    'Ориентир временного места для текущего файла: '+SizeText(State.WorkingBytes);
  FApply.Visible:=State.AwaitingReview; FApplyAll.Visible:=State.AwaitingReview and not State.AwaitingEstimate;
  FTrial.Visible:=State.AwaitingEstimate and not State.TrialReady; FTrial.Enabled:=FTrial.Visible and not State.Stopping;
  FSkip.Visible:=State.AwaitingReview;
  if State.AwaitingEstimate then
  begin FApply.Caption:='Начать сжатие'; FSkip.Caption:='Закончить оценку'; end
  else begin FApply.Caption:='Применить'; FSkip.Caption:='Пропустить'; end;
  FPreviewFile:=State.PreviewFile; FPreviewSHA256:=State.PreviewSHA256;
  FCompare.Visible:=State.AwaitingReview and not State.AwaitingEstimate and (FPreviewFile<>'');
  FCompare.Enabled:=FCompare.Visible and not State.Stopping;
  FStorage.Visible := State.Finished and (Length(State.Disks) > 0);
  if FStorage.Visible then FResult := State;
  FApply.Enabled:=State.AwaitingReview and not State.Stopping;
  FApplyAll.Enabled:=FApply.Enabled; FSkip.Enabled:=FApply.Enabled;
  FStop.Enabled:=not State.Stopping or State.Finished;
  if State.Finished then FStop.Caption:='Закрыть' else FStop.Caption:='Остановить';
  if State.Stopping and not State.Finished then
    FNote.Caption:='Останавливаем обработку. Если запись архива уже началась, сначала безопасно завершим её.'
  else if State.TrialRunning then
    FNote.Caption:='Каждый архив упаковывается во временной папке. После измерения временная копия удаляется.'
  else if State.Estimating then
    FNote.Caption:='Проверяем выбранные книги и образцы иллюстраций. Полный архив для оценки не создаётся. '+
      'На одну книгу выделяется до 10 секунд; расчёт всего набора может занять дольше. '+
      'Начать сжатие можно будет отдельно после расчёта.'
  else if State.AwaitingEstimate then
    FNote.Caption:='В первой строке — выбранные книги до внешней упаковки; во второй — архивы целиком, с остальными книгами. '+
      '«Пробная упаковка» измерит результат во временной папке. Она займёт примерно столько же времени, сколько сжатие.'
  else if State.AwaitingReview then
    FNote.Caption:='Исходный файл ещё не изменён. «Применить» заменит его подготовленным результатом. '+
      '«Пропустить» сохранит исходник. Текст и остальные книги проверены автоматически.'
  else FNote.Caption:='Можно продолжать работу с каталогом. Закрытие этого окна не останавливает сжатие.';
  if State.AwaitingReview and not State.AwaitingEstimate and (State.ImageChanges=0) then
    FNote.Caption:=FNote.Caption+sLineBreak+'Изображения не изменялись; меняется только упаковка.'
  else if State.AwaitingReview and not State.AwaitingEstimate and (State.PreviewNote<>'') then
    FNote.Caption:=FNote.Caption+sLineBreak+State.PreviewNote
  else if State.AwaitingReview and not State.AwaitingEstimate and (FPreviewFile='') then
    FNote.Caption:=FNote.Caption+sLineBreak+'Визуальное сравнение для этих изображений пока недоступно.';
  if State.Finished then
  begin
    if State.EstimateOnly then FNote.Caption:='Оценка завершена. Исходные книги, архивы и каталог не изменены. '+
      'Размеры книг показаны до внешней упаковки; итог на диске будет известен после подготовки.'
    else if State.Recovery then
    begin
      FNote.Caption:=Format('Завершено операций из сохранённых журналов: %d.',[State.FilesDone]);
      if State.DiscardedPreparations>0 then
        FNote.Caption:=FNote.Caption+sLineBreak+Format('Убрано незавершённых подготовок: %d.',[State.DiscardedPreparations]);
    end
    else FNote.Caption:=Format('Уменьшено файлов: %d · Без уменьшения: %d · Пропущено по вашему выбору: %d.',
      [State.ChangedFiles,State.UnchangedFiles,State.SkippedFiles]);
    if State.Error<>'' then FNote.Caption:=FNote.Caption+sLineBreak+State.Error;
    if State.Warning<>'' then FNote.Caption:=FNote.Caption+sLineBreak+State.Warning;
  end;
  if State.TrialReady and (State.AwaitingEstimate or State.EstimateOnly) then
  begin
    FNote.Caption:='Показан размер подготовленных файлов, включая архивы обложек и картинок. '+
      'Отдельные резервные копии сюда не входят. Временные файлы удалены.';
    if State.TrialSharedFiles>0 then FNote.Caption:=FNote.Caption+sLineBreak+
      Format('Не включено общих архивов: %d. Их изменение зависит от нескольких заданий.',[State.TrialSharedFiles]);
    if State.AwaitingEstimate then FNote.Caption:=FNote.Caption+' Для записи нажмите «Начать сжатие».';
    if State.Warning<>'' then FNote.Caption:=FNote.Caption+sLineBreak+State.Warning;
  end;
  if State.AwaitingEstimate and not State.TrialReady and (State.EstimateDjvuBooks>0) then
    FNote.Caption:=FNote.Caption+sLineBreak+Format('Проверено DjVu в архивах: %d. Страниц с подходящим фоном: %d. '+
      'Размер отдельного DjVu сохраняется.',[State.EstimateDjvuBooks,State.EstimateDjvuPages]);
  if State.PreviouslyProcessedBooks>0 then FNote.Caption:=FNote.Caption+sLineBreak+
    Format('Ранее проверено книг с этими настройками: %d.',[State.PreviouslyProcessedBooks]);
  if State.BackupFiles>0 then FNote.Caption:=FNote.Caption+sLineBreak+
    Format('Оригиналы сохранены в ZIP (%d). Размер и имена архивов — в «Место и оригиналы».',[State.BackupFiles]);
  FNote.Hint:=FNote.Caption; FNote.ShowHint:=True;
end;

procedure TfrmBookCompressionProgress.ShowResult(const State: TBookCompressionOperationStatus;
  const RefreshError: string);
begin
  UpdateProgress(State);
  if RefreshError<>'' then
  begin FNote.Caption:=FNote.Caption+sLineBreak+RefreshError; FNote.Hint:=FNote.Caption; end;
  Show; BringToFront; FlashWindow(Handle,True);
end;

end.
