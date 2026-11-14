unit frm_BookCompression;

interface

uses System.Classes, System.SysUtils, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls,
  Vcl.Controls, unit_BookCompressionOperation, frm_CatalogSources;

type
  TCompressionReviewEvent = procedure(Decision: TCompressionReview) of object;

  TfrmBookCompressionOptions = class(TSourceDialogForm)
  private
    FProfile: TComboBox;
    FGray, FReview, FBackup: TCheckBox;
    FExplanation, FSpace, FWorkLabel, FBackupNote: TLabel;
    FWork, FBackupFolder: TEdit;
    FWorkBrowse, FBackupBrowse, FStart, FCancel, FEstimate: TButton;
    FOptions: TBookCompressionOperationOptions;
    FLayoutScale: Integer;
    procedure ProfileChanged(Sender: TObject);
    procedure BrowseWork(Sender: TObject);
    procedure BrowseBackup(Sender: TObject);
    procedure BackupChanged(Sender: TObject);
    procedure Accept(Sender: TObject);
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
    FStop, FApply, FApplyAll, FSkip, FPin, FCompare: TButton;
    FPreviewFile, FPreviewSHA256: string;
    FOnStop: TNotifyEvent;
    FOnReview: TCompressionReviewEvent;
    FFinished: Boolean;
    procedure StopClick(Sender: TObject);
    procedure ReviewClick(Sender: TObject);
    procedure PinClick(Sender: TObject);
    procedure CloseView(Sender: TObject; var Action: TCloseAction);
    procedure CompareClick(Sender: TObject);
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

uses Winapi.Windows, System.Math, System.IOUtils, Vcl.Dialogs, Vcl.Graphics,
  unit_MHLTheme, unit_CollectionSpace, frm_BookCompressionCompare;

const Profiles: array[0..3] of string = ('original','balanced','economy','maximum');

function SizeText(Bytes: Int64): string;
begin
  if Bytes>=Int64(1024)*1024*1024 then Result:=FormatFloat('0.00',Bytes/(Int64(1024)*1024*1024))+' ГБ'
  else if Bytes>=1024*1024 then Result:=FormatFloat('0.0',Bytes/(1024*1024))+' МБ'
  else if Bytes>=1024 then Result:=FormatFloat('0.0',Bytes/1024)+' КБ'
  else Result:=IntToStr(Bytes)+' Б';
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
  FProfile.Items.Add('Без изменения изображений');
  FProfile.Items.Add('Сбалансированно'); FProfile.Items.Add('Экономно');
  FProfile.Items.Add('Максимальная экономия'); FProfile.ItemIndex:=1;
  for var I:=0 to High(Profiles) do if Profiles[I]=Options.Profile then FProfile.ItemIndex:=I;
  FProfile.OnChange:=ProfileChanged;
  FExplanation:=MakeLabel(Self,'CompressionProfileExplanation',132,48);
  FGray:=TCheckBox.Create(Self); FGray.Parent:=Self; FGray.Name:='CompressionGrayscale';
  FGray.SetBounds(16,184,608,24); FGray.Caption:='Перевести изображения в оттенки серого';
  FGray.Checked:=Options.Grayscale;
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
  BackupChanged(nil); ProfileChanged(nil); ApplyMHLControlTheme(Self);
end;

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
begin
  case FProfile.ItemIndex of
    0: FExplanation.Caption:='Содержимое книг и качество изображений сохраняются. Экономия возможна за счёт упаковки.';
    1: FExplanation.Caption:='Умеренное сжатие крупных иллюстраций FB2 и EPUB. Текст сохраняется; сложные изображения стоит проверить.';
    2: FExplanation.Caption:='Более сильное сжатие иллюстраций FB2 и EPUB. Размер и детализация изображений могут уменьшиться.';
    3: FExplanation.Caption:='Сильнее уменьшает иллюстрации FB2 и EPUB и фон подходящих сканов DjVu. Мелкие детали могут стать хуже видны.';
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
  if FBackup.Checked and ((FBackupFolder.Text='') or
    not TPath.IsPathRooted(FBackupFolder.Text) or not DirectoryExists(FBackupFolder.Text)) then
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
  FApply:=MakeButton(Self,'CompressionApply','Применить',16,414,126,ReviewClick); FApply.Tag:=Ord(crApply);
  FApply.Anchors:=[akLeft,akBottom];
  FApplyAll:=MakeButton(Self,'CompressionApplyAll','Применять остальные',150,414,184,ReviewClick); FApplyAll.Tag:=Ord(crApplyRemaining);
  FApplyAll.Anchors:=[akLeft,akBottom];
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
begin
  FApply.Enabled:=False; FApplyAll.Enabled:=False; FSkip.Enabled:=False;
  if Assigned(FOnReview) then FOnReview(TCompressionReview(TButton(Sender).Tag));
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

procedure TfrmBookCompressionProgress.UpdateProgress(const State: TBookCompressionOperationStatus);
begin
  FFinished:=State.Finished; FStage.Caption:=State.Stage;
  if FStage.Caption='' then FStage.Caption:='Подготавливаем сжатие…';
  FSource.Caption:=State.Source; FSource.Hint:=State.Source;
  FMember.Caption:=State.Member; FMember.Hint:=State.Member;
  if (State.Total>0) and not State.Finished then
  begin
    FProgress.Style:=pbstNormal;
    FProgress.Position:=Round(EnsureRange(State.Current/State.Total,0.0,1.0)*1000);
  end
  else if State.Finished or State.AwaitingReview then
  begin FProgress.Style:=pbstNormal; FProgress.Position:=1000; end
  else FProgress.Style:=pbstMarquee;
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
    FSizes.Caption:=FSizes.Caption+sLineBreak+'На диске: файлы и общие архивы целиком — '+SizeText(State.EstimateArchiveBytes);
    FCounts.Caption:=Format('Выбрано книг: %d · Архивов и отдельных файлов: %d',[State.BooksTotal,State.FilesTotal]);
  end
  else if State.Estimating then FSizes.Caption:='Оценка ещё идёт. Исходные файлы не изменяются.'
  else if State.AwaitingReview then FSizes.Caption:='Этот файл: '+SizeText(State.InputBytes)+' → '+
    SizeText(State.OutputBytes)+' · Уменьшение: '+SizeText(State.InputBytes-State.OutputBytes)
  else if State.SavingsKnown then FSizes.Caption:='Освобождено: '+SizeText(State.SavedBytes)
  else if State.Finished then FSizes.Caption:='Экономия места при восстановлении не пересчитывалась.'
  else FSizes.Caption:='Завершаем ранее начатое сжатие. Размер экономии сейчас не подсчитывается.';
  if State.WorkingBytes>0 then FSizes.Caption:=FSizes.Caption+sLineBreak+
    'Ориентир временного места для текущего файла: '+SizeText(State.WorkingBytes);
  FApply.Visible:=State.AwaitingReview; FApplyAll.Visible:=State.AwaitingReview and not State.AwaitingEstimate;
  FSkip.Visible:=State.AwaitingReview;
  if State.AwaitingEstimate then
  begin FApply.Caption:='Начать сжатие'; FSkip.Caption:='Закончить оценку'; end
  else begin FApply.Caption:='Применить'; FSkip.Caption:='Пропустить'; end;
  FPreviewFile:=State.PreviewFile; FPreviewSHA256:=State.PreviewSHA256;
  FCompare.Visible:=State.AwaitingReview and not State.AwaitingEstimate and (FPreviewFile<>'');
  FCompare.Enabled:=FCompare.Visible and not State.Stopping;
  FApply.Enabled:=State.AwaitingReview and not State.Stopping;
  FApplyAll.Enabled:=FApply.Enabled; FSkip.Enabled:=FApply.Enabled;
  FStop.Enabled:=not State.Stopping or State.Finished;
  if State.Finished then FStop.Caption:='Закрыть' else FStop.Caption:='Остановить';
  if State.Stopping and not State.Finished then
    FNote.Caption:='Останавливаем обработку. Если запись архива уже началась, сначала безопасно завершим её.'
  else if State.Estimating then
    FNote.Caption:='Проверяем выбранные книги и образцы иллюстраций. Полный архив для оценки не создаётся. '+
      'На одну книгу выделяется до 10 секунд; расчёт всего набора может занять дольше. '+
      'Начать сжатие можно будет отдельно после расчёта.'
  else if State.AwaitingEstimate then
    FNote.Caption:='В первой строке — выбранные книги до внешней упаковки; во второй — архивы целиком, с остальными книгами. '+
      'Расчёт по образцам. Экономия на диске зависит от архива. '+
      '«Начать сжатие» подготовит результат; «Закончить оценку» ничего не изменит.'
  else if State.AwaitingReview then
    FNote.Caption:='Исходный файл ещё не изменён. «Применить» заменит его подготовленным результатом. '+
      '«Пропустить» сохранит исходник. Текст и остальные книги проверены автоматически.'
  else FNote.Caption:='Можно продолжать работу с каталогом. Закрытие этого окна не останавливает сжатие.';
  if State.AwaitingReview and not State.AwaitingEstimate and (State.ImageChanges=0) then
    FNote.Caption:=FNote.Caption+sLineBreak+'Изображения не изменялись; меняется только упаковка.'
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
  if State.PreviouslyProcessedBooks>0 then FNote.Caption:=FNote.Caption+sLineBreak+
    Format('Ранее проверено книг с этими настройками: %d.',[State.PreviouslyProcessedBooks]);
  if State.BackupFiles>0 then FNote.Caption:=FNote.Caption+sLineBreak+
    Format('Оригиналы сохранены: %d ZIP · %s',[State.BackupFiles,State.BackupFolder]);
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
