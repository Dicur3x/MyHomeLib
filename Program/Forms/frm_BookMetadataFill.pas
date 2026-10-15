unit frm_BookMetadataFill;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  unit_Globals, unit_MetadataSyncTypes, unit_CollectionWorkerThread, unit_CollectionMetadataSync;

type
  TfrmBookMetadataFill = class(TForm)
  private
    FCollectionID: Integer;
    FPlan: TCollectionMetadataPlan;
    FWorker: TMetadataProgressWorker;
    FFields: array[TMetadataSyncField] of TCheckBox;
    FCounts: array[TMetadataSyncField] of TLabel;
    FSummary, FReason, FComment, FAnnotationNote, FTimingInfo: TLabel;
    FTiming: TMetadataTiming;
    FTimingUpdatedAt: UInt64;
    FPreview, FApply, FStop, FClose: TButton;
    FProgress: TProgressBar;
    FReport: TMemo;
    FTimer: TTimer;
    FRequestedFields: TMetadataSyncFields;
    FApplying, FCloseWhenReady, FDestroying, FCommittedChanges, FLayoutBusy: Boolean;
    procedure LayoutFooter;
    procedure Resize; override;
    function GetBusy: Boolean;
    function SelectedFields: TMetadataSyncFields;
    procedure OptionsChanged(Sender: TObject);
    procedure UpdateButtons;
    procedure InvalidatePlan(const Reason: string);
    procedure ShowCounts(const Counts: TMetadataSyncCounts);
    procedure StartWorker(Worker: TMetadataProgressWorker; Applying: Boolean);
    procedure UpdateTiming;
    procedure PreviewClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure PollWorker(Sender: TObject);
    procedure ProgressChanged(Percent: Integer);
    procedure CommentChanged(const Text: string);
    procedure ReportLine(const Text: string; Severity: TTeletypeSeverity);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateForCollection(AOwner: TComponent; CollectionID: Integer);
    destructor Destroy; override;
    procedure ScaleForPPI(NewPPI: Integer); override;
    property CollectionID: Integer read FCollectionID;
    property CommittedChanges: Boolean read FCommittedChanges;
    property Busy: Boolean read GetBusy;
  end;

function FillMissingBookMetadata(AOwner: TComponent; CollectionID: Integer): Boolean;

implementation

uses System.SysUtils, System.Types, System.Math, Winapi.Windows, Vcl.Controls,
  Vcl.Graphics, unit_MHLTheme, dm_user;

const
  FieldNames: array[TMetadataSyncField] of string =
    ('Издательство', 'Город издания', 'Год издания', 'ISBN', 'Переводчики', 'Аннотации — описания книг');

constructor TfrmBookMetadataFill.CreateForCollection(AOwner: TComponent; CollectionID: Integer);
var Body: TScrollBox; Options, Footer: TPanel; Intro: TLabel; WorkArea: TRect;

  function LabelAt(Parent: TWinControl; const Name, Text: string;
    X, Y, W, H: Integer): TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=Parent; Result.Name:=Name;
    Result.AutoSize:=False; Result.WordWrap:=True; Result.SetBounds(X,Y,W,H);
    Result.Caption:=Text; Result.Anchors:=[akLeft,akTop,akRight];
  end;

  function ButtonAt(const Name, Text: string; X, W: Integer; Handler: TNotifyEvent): TButton;
  begin
    Result:=TButton.Create(Self); Result.Parent:=Footer; Result.Name:=Name;
    Result.SetBounds(X,82,W,32); Result.Caption:=Text; Result.OnClick:=Handler;
  end;

begin
  inherited CreateNew(AOwner);
  FCollectionID:=CollectionID; Name:='frmBookMetadataFill';
  Caption:='Сведения из книг — '+SystemDB.GetCollectionInfo(CollectionID).DisplayName;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  Position:=poOwnerFormCenter; BorderStyle:=bsSizeable; ClientWidth:=740; ClientHeight:=620;
  Constraints.MinWidth:=708; Constraints.MinHeight:=440;
  DisableAlign;
  try
    Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.BevelOuter:=bvNone;
    Footer.SetBounds(0,ClientHeight-126,ClientWidth,126); Footer.Align:=alBottom;
    FReason:=LabelAt(Footer,'lblMetadataFillReason','',12,8,716,38);
    FTimingInfo:=LabelAt(Footer,'lblMetadataFillTiming','',12,48,716,26);
    FPreview:=ButtonAt('btnMetadataPreview','1. Проверить книги',12,184,PreviewClick);
    FApply:=ButtonAt('btnMetadataApply','2. Заполнить сведения',204,208,ApplyClick);
    FStop:=ButtonAt('btnMetadataStop','Остановить',420,128,StopClick);
    FClose:=ButtonAt('btnMetadataClose','Закрыть',600,128,CloseClick);
    FClose.Anchors:=[akTop,akRight]; FClose.Cancel:=True;
    Body:=TScrollBox.Create(Self); Body.Parent:=Self; Body.Align:=alClient;
    Body.BorderStyle:=bsNone; Body.HorzScrollBar.Visible:=False;
    Options:=TPanel.Create(Self); Options.Parent:=Body; Options.BevelOuter:=bvNone;
    Options.SetBounds(0,0,ClientWidth,376); Options.Align:=alTop;
    Intro:=LabelAt(Options,'lblMetadataFillScope',
      'Недостающие сведения берутся из местных FB2, FB3, EPUB, DOCX и ODT, в том числе в ZIP/7z (PPMd). '+
      'Имеющиеся значения, файлы книг, заметки и прогресс чтения сохраняются.',12,10,716,48);
    Intro.Font.Style:=[fsBold];
    LabelAt(Options,'lblMetadataFillFields','Какие сведения заполнить',12,68,380,22);
    LabelAt(Options,'lblMetadataFillAvailable','Можно заполнить в книгах',424,68,304,22);
    for var Field:=Low(TMetadataSyncField) to High(TMetadataSyncField) do
    begin
      FFields[Field]:=TCheckBox.Create(Self); FFields[Field].Parent:=Options;
      FFields[Field].Name:='cbMetadataField'+IntToStr(Ord(Field));
      FFields[Field].SetBounds(12,94+Ord(Field)*27,400,24);
      FFields[Field].Caption:=FieldNames[Field];
      FFields[Field].Checked:=Field in METADATA_SYNC_DEFAULT_FIELDS;
      FFields[Field].OnClick:=OptionsChanged;
      FCounts[Field]:=LabelAt(Options,'lblMetadataCount'+IntToStr(Ord(Field)),
        'После проверки',424,94+Ord(Field)*27,304,24);
    end;
    FAnnotationNote:=LabelAt(Options,'lblMetadataAnnotationSize',
      'Прочитанные сведения сохраняются для продолжения. Аннотации заполняют только пустые описания в каталоге и могут увеличить его. Выбор полей можно менять после проверки.',12,264,716,36);
    FSummary:=LabelAt(Options,'lblMetadataFillSummary','',12,306,716,42);
    FComment:=LabelAt(Options,'lblMetadataFillProgress','',12,350,716,24);
    FProgress:=TProgressBar.Create(Self); FProgress.Parent:=Body;
    FProgress.SetBounds(12,376,716,18); FProgress.Align:=alTop;
    FProgress.AlignWithMargins:=True; FProgress.Margins.Left:=12; FProgress.Margins.Right:=12;
    FReport:=TMemo.Create(Self); FReport.Parent:=Body; FReport.Name:='mmMetadataFillReport';
    FReport.SetBounds(12,400,716,110); FReport.Align:=alClient; FReport.ReadOnly:=True;
    FReport.ScrollBars:=ssVertical; FReport.WordWrap:=True; FReport.AlignWithMargins:=True;
    FReport.Margins.Left:=12; FReport.Margins.Right:=12; FReport.Margins.Bottom:=8;
    FReport.Lines.Text:='Выберите сведения и нажмите «1. Проверить книги». '+
      'Проверка не изменяет каталог. Заполнение доступно только после завершённой проверки.'+#13#10+
      'Нужны местные FB2, FB3, EPUB, DOCX, ODT или архивы с ними, указанные в каталоге. Одного списка INPX недостаточно. '+
      'Другие форматы пропускаются. Недоступные файлы и неоднозначные архивы перечисляются в отчёте.'+#13#10+
      'Прочитанные сведения сохраняются между запусками. Повторная проверка использует их для неизменившихся файлов.';
    FTimer:=TTimer.Create(Self); FTimer.Enabled:=False; FTimer.Interval:=50; FTimer.OnTimer:=PollWorker;
    OnCloseQuery:=FormCloseQuery;
  finally EnableAlign; end;
  InvalidatePlan('Сначала проверьте книги с выбранными сведениями.');
  ScaleForPPI(Screen.PixelsPerInch); WorkArea:=Monitor.WorkareaRect;
  Height:=Min(Height,Max(Constraints.MinHeight,WorkArea.Height-48));
  ApplyMHLControlTheme(Self); LayoutFooter;
end;

destructor TfrmBookMetadataFill.Destroy;
begin
  FDestroying:=True;
  if Assigned(FTimer) then FTimer.Enabled:=False;
  if Assigned(FWorker) then
  begin
    FWorker.Cancel; FWorker.OnProgress:=nil; FWorker.OnSetComment:=nil; FWorker.OnTeletype:=nil;
    FWorker.WaitFor; FreeAndNil(FWorker);
  end;
  FPlan.Free;
  inherited;
end;

procedure TfrmBookMetadataFill.ScaleForPPI(NewPPI: Integer);
var OldPPI, NewWidth, NewHeight, MinWidth, MinHeight: Integer;
begin
  OldPPI:=Font.PixelsPerInch;
  if (OldPPI<=0) or (NewPPI<=0) or (OldPPI=NewPPI) then begin inherited; Exit; end;
  NewWidth:=MulDiv(ClientWidth,NewPPI,OldPPI); NewHeight:=MulDiv(ClientHeight,NewPPI,OldPPI);
  MinWidth:=MulDiv(Constraints.MinWidth,NewPPI,OldPPI); MinHeight:=MulDiv(Constraints.MinHeight,NewPPI,OldPPI);
  DisableAlign;
  try
    inherited; Constraints.MinWidth:=MinWidth; Constraints.MinHeight:=MinHeight;
    ClientWidth:=NewWidth; ClientHeight:=NewHeight;
  finally EnableAlign; end;
  LayoutFooter;
end;

procedure TfrmBookMetadataFill.Resize;
begin
  inherited; LayoutFooter;
end;

procedure TfrmBookMetadataFill.LayoutFooter;
var PPI, Margin, Gap, X, RequiredWidth: Integer; Buttons: array[0..3] of TButton;
  Widths: array[0..3] of Integer; Footer: TWinControl;
const MinimumWidths: array[0..3] of Integer = (184,208,128,128);
begin
  if FLayoutBusy or not Assigned(FClose) then Exit;
  FLayoutBusy:=True;
  try
    PPI:=Max(96,Font.PixelsPerInch); Margin:=MulDiv(12,PPI,96); Gap:=MulDiv(8,PPI,96);
    Footer:=FPreview.Parent; Buttons[0]:=FPreview; Buttons[1]:=FApply; Buttons[2]:=FStop; Buttons[3]:=FClose;
    RequiredWidth:=Margin*2+Gap*3;
    for var I:=0 to High(Buttons) do
    begin
      Canvas.Font.Assign(Buttons[I].Font);
      Widths[I]:=Max(MulDiv(MinimumWidths[I],PPI,96),Canvas.TextWidth(Buttons[I].Caption)+Margin*2);
      Inc(RequiredWidth,Widths[I]);
    end;
    // Constraints are outer-window pixels; use the actual themed nonclient width.
    Constraints.MinWidth:=Max(MulDiv(708,PPI,96),RequiredWidth+Max(0,Width-ClientWidth));
    if ClientWidth<RequiredWidth then ClientWidth:=RequiredWidth;
    X:=Margin;
    for var I:=0 to High(Buttons) do
    begin
      if I=High(Buttons) then X:=Footer.ClientWidth-Margin-Widths[I];
      Buttons[I].SetBounds(X,MulDiv(82,PPI,96),Widths[I],MulDiv(32,PPI,96));
      Inc(X,Widths[I]+Gap);
    end;
    FReason.SetBounds(Margin,MulDiv(8,PPI,96),Footer.ClientWidth-Margin*2,MulDiv(38,PPI,96));
    FTimingInfo.SetBounds(Margin,MulDiv(48,PPI,96),Footer.ClientWidth-Margin*2,MulDiv(26,PPI,96));
  finally FLayoutBusy:=False; end;
end;

function TfrmBookMetadataFill.SelectedFields: TMetadataSyncFields;
begin
  Result:=[];
  for var Field:=Low(TMetadataSyncField) to High(TMetadataSyncField) do
    if FFields[Field].Checked then Include(Result,Field);
end;

function TfrmBookMetadataFill.GetBusy: Boolean;
begin Result:=Assigned(FWorker); end;

procedure TfrmBookMetadataFill.UpdateButtons;
var Working: Boolean;
begin
  Working:=Assigned(FWorker);
  for var Field:=Low(TMetadataSyncField) to High(TMetadataSyncField) do FFields[Field].Enabled:=not Working;
  FPreview.Enabled:=not Working and (SelectedFields<>[]);
  FApply.Enabled:=not Working and Assigned(FPlan) and (FPlan.Counts.BooksPlanned>0);
  FStop.Enabled:=Working; FPreview.Default:=not FApply.Enabled; FApply.Default:=FApply.Enabled;
end;

procedure TfrmBookMetadataFill.InvalidatePlan(const Reason: string);
begin
  FreeAndNil(FPlan); FReason.Caption:=Reason; UpdateButtons;
end;

procedure TfrmBookMetadataFill.OptionsChanged(Sender: TObject);
begin
  if Assigned(FWorker) then Exit;
  if Assigned(FPlan) then
  begin
    FRequestedFields:=SelectedFields; FPlan.SelectFields(FRequestedFields);
    ShowCounts(FPlan.Counts); UpdateButtons;
    if FRequestedFields=[] then FReason.Caption:='Выберите хотя бы один вид сведений.'
    else FReason.Caption:='Выбор изменён. Повторно читать книги не нужно. Нажмите «2. Заполнить сведения».';
    Exit;
  end;
  for var Field:=Low(TMetadataSyncField) to High(TMetadataSyncField) do FCounts[Field].Caption:='После проверки';
  FSummary.Caption:='';
  FAnnotationNote.Caption:='Прочитанные сведения сохраняются для продолжения. Аннотации заполняют только пустые описания в каталоге и могут увеличить его. Выбор полей можно менять после проверки.';
  if SelectedFields=[] then InvalidatePlan('Выберите хотя бы один вид сведений.')
  else InvalidatePlan('Выбор изменён. Проверьте книги ещё раз.');
end;

procedure TfrmBookMetadataFill.ShowCounts(const Counts: TMetadataSyncCounts);
var SizeText: string; Available: TMetadataSyncCounts;
begin
  Available:=Counts; if Assigned(FPlan) then Available:=FPlan.AvailableCounts;
  for var Field:=Low(TMetadataSyncField) to High(TMetadataSyncField) do
    if Field in FRequestedFields then FCounts[Field].Caption:=IntToStr(Counts.FieldCounts[Field])
    else if Assigned(FPlan) then FCounts[Field].Caption:=IntToStr(Available.FieldCounts[Field])+' (не выбрано)'
    else FCounts[Field].Caption:='Не выбрано';
  FSummary.Caption:=Format('Проверено книг: %d из %d. Есть недостающие сведения: %d. '+
    'Пропущено: %d; ошибки чтения: %d.',[Counts.BooksChecked,Counts.BooksTotal,Counts.BooksPlanned,Counts.BooksSkipped,Counts.BooksFailed]);
  if Assigned(FPlan) or (msfAnnotation in FRequestedFields) then
  begin
    if Available.AnnotationBytes<1024 then SizeText:=IntToStr(Available.AnnotationBytes)+' байт'
    else if Available.AnnotationBytes<1024*1024 then SizeText:=FormatFloat('0.0',Available.AnnotationBytes/1024.0)+' КБ'
    else SizeText:=FormatFloat('0.0',Available.AnnotationBytes/(1024.0*1024))+' МБ';
    FAnnotationNote.Caption:=Format('Доступно описаний: %d, примерно %s текста. Только для пустых описаний в каталоге. '+
      'Аннотации можно выбрать без повторного чтения книг.',
      [Available.FieldCounts[msfAnnotation],SizeText]);
  end;
end;

procedure TfrmBookMetadataFill.StartWorker(Worker: TMetadataProgressWorker; Applying: Boolean);
begin
  FWorker:=Worker; FApplying:=Applying; FProgress.Position:=0; FReport.Clear;
  FComment.Caption:=''; FTiming.Reset(GetTickCount64); FTimingUpdatedAt:=0; UpdateTiming;
  FWorker.OnProgress:=ProgressChanged; FWorker.OnSetComment:=CommentChanged; FWorker.OnTeletype:=ReportLine;
  UpdateButtons; FTimer.Enabled:=True;
  try FWorker.Start;
  except FTimer.Enabled:=False; FreeAndNil(FWorker); FApplying:=False;
    FTimingInfo.Caption:=FTiming.Description(GetTickCount64,False); UpdateButtons; raise; end;
end;

procedure TfrmBookMetadataFill.UpdateTiming;
var NowMS: UInt64; Checked, Total: Int64;
begin
  if not Assigned(FWorker) then Exit;
  NowMS:=GetTickCount64;
  if not FWorker.Finished and (FTimingUpdatedAt<>0) and (NowMS-FTimingUpdatedAt<1000) then Exit;
  FTimingUpdatedAt:=NowMS; FWorker.GetBookProgress(Checked,Total);
  FTiming.Sample(Checked,Total,NowMS);
  FTimingInfo.Caption:=FTiming.Description(NowMS,not FWorker.Finished and not FWorker.Canceled);
  if FApplying and (Total>0) then FComment.Caption:=Format('Обработано книг: %d из %d',[Checked,Total]);
end;

procedure TfrmBookMetadataFill.PreviewClick(Sender: TObject);
begin
  if Assigned(FWorker) or (SelectedFields=[]) then Exit;
  FRequestedFields:=SelectedFields; InvalidatePlan('Проверяем книги. Заполнение станет доступно после проверки.');
  try StartWorker(TMetadataPreviewThread.Create(FCollectionID,FRequestedFields),False);
  except on E: Exception do
  begin FReason.Caption:='Не удалось начать проверку: '+E.Message; ReportLine(E.Message,tsError); UpdateButtons; end; end;
end;

procedure TfrmBookMetadataFill.ApplyClick(Sender: TObject);
begin
  if Assigned(FWorker) or not Assigned(FPlan) or not FApply.Enabled then Exit;
  if SelectedFields<>FPlan.Fields then begin InvalidatePlan('Выбор изменён. Проверьте книги ещё раз.'); Exit; end;
  FReason.Caption:='Заполняем только недостающие сведения. Завершённые записи сохраняются.';
  try StartWorker(TMetadataApplyThread.Create(FPlan),True);
  except on E: Exception do
  begin FReason.Caption:='Не удалось начать заполнение: '+E.Message; ReportLine(E.Message,tsError); UpdateButtons; end; end;
end;

procedure TfrmBookMetadataFill.StopClick(Sender: TObject);
begin
  if not Assigned(FWorker) then Exit;
  FWorker.Cancel; FStop.Enabled:=False; FReason.Caption:='Останавливаем обработку. Дождитесь завершения текущей записи.';
end;

procedure TfrmBookMetadataFill.CloseClick(Sender: TObject);
begin Close; end;

procedure TfrmBookMetadataFill.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:=not Assigned(FWorker);
  if not CanClose then begin FCloseWhenReady:=True; StopClick(Sender); end;
end;

procedure TfrmBookMetadataFill.ProgressChanged(Percent: Integer);
begin if not FDestroying then FProgress.Position:=EnsureRange(Percent,0,100); end;

procedure TfrmBookMetadataFill.CommentChanged(const Text: string);
begin if not FDestroying then FComment.Caption:=Text; end;

procedure TfrmBookMetadataFill.ReportLine(const Text: string; Severity: TTeletypeSeverity);
begin
  if FDestroying then Exit;
  if FReport.Lines.Count<500 then FReport.Lines.Add(Text)
  else if FReport.Lines.Count=500 then FReport.Lines.Add('В окне показаны первые 500 сообщений. Дальнейшие ошибки отражены в итоговых счётчиках.');
end;

procedure TfrmBookMetadataFill.PollWorker(Sender: TObject);
var ErrorText: string; Preview: TMetadataPreviewThread; Apply: TMetadataApplyThread;
begin
  if FDestroying or not Assigned(FWorker) then Exit;
  UpdateTiming;
  if not FWorker.Finished then Exit;
  FTimer.Enabled:=False; FWorker.WaitFor; ErrorText:='';
  try
    FCommittedChanges:=FCommittedChanges or FWorker.CommittedChanges;
    if FWorker.FatalException is Exception then ErrorText:=Exception(FWorker.FatalException).Message;
    if FApplying then
    begin
      Apply:=TMetadataApplyThread(FWorker);
      FSummary.Caption:=Format('Сохранено книг: %d. Пропущено: %d; ошибки: %d.',
        [Apply.BooksCommitted,Apply.BooksSkipped,Apply.BooksFailed]);
      if Apply.Completed and (Apply.Counts.BooksStale=0) and (Apply.BooksFailed=0) then
      begin
        FPlan.MarkSelectionApplied; ShowCounts(FPlan.Counts);
        FSummary.Caption:=Format('Сохранено книг: %d. Пропущено: %d; ошибки: %d.',
          [Apply.BooksCommitted,Apply.BooksSkipped,Apply.BooksFailed]);
      end;
      if ErrorText<>'' then
      begin FreeAndNil(FPlan); FReason.Caption:='Заполнение не завершено: '+ErrorText; end
      else if not Apply.Completed then FReason.Caption:='Обработка остановлена. Завершённые записи сохранены. Нажмите «2. Заполнить сведения», чтобы продолжить.'
      else if Apply.Counts.BooksStale>0 then
        FReason.Caption:='Часть книг или источников изменилась. Повторите проверку: сохранённые сведения неизменившихся книг будут использованы снова.'
      else FReason.Caption:='Заполнение завершено. Можно выбрать другие сведения без нового чтения книг.';
    end
    else
    begin
      Preview:=TMetadataPreviewThread(FWorker);
      if (ErrorText='') and Preview.Completed then FPlan:=Preview.TakePlan;
      ShowCounts(Preview.Counts);
      ReportLine(Format('Прочитано файлов: %d; использовано сохранённых сведений: %d.',
        [Preview.Counts.FilesRead,Preview.Counts.BooksReused]),tsInfo);
      var Counts:=Preview.Counts;
      if Counts.AnnotationsOmitted>0 then ReportLine(Format(
        'Слишком большие аннотации пропущены: %d. Остальные сведения этих книг обработаны.',
        [Counts.AnnotationsOmitted]),tsInfo);
      if Counts.BooksFailed=0 then ReportLine('Ошибок чтения нет.',tsInfo)
      else
      begin
        ReportLine('Причины ошибок чтения:',tsInfo);
        for var Kind:=Low(TMetadataReadFailure) to High(TMetadataReadFailure) do
          if Counts.ErrorCounts[Kind]>0 then
            ReportLine(MetadataFailureName(Kind)+': '+IntToStr(Counts.ErrorCounts[Kind]),tsInfo);
        ReportLine('Примеры (до 40 записей; итоговые счётчики учитывают все книги):',tsInfo);
        for var Example in Counts.ErrorExamples do ReportLine(Example,tsError);
      end;
      if ErrorText<>'' then FReason.Caption:='Проверка не завершена: '+ErrorText
      else if not Preview.Completed then FReason.Caption:='Проверка остановлена. Прочитанные сведения сохранены. Нажмите «1. Проверить книги», чтобы продолжить.'
      else if SelectedFields<>FRequestedFields then FReason.Caption:='Выбор изменён. Проверьте книги ещё раз.'
      else
      begin
        if not Assigned(FPlan) or (FPlan.Counts.BooksPlanned=0) then
          FReason.Caption:='Недостающих сведений для заполнения не найдено. Для проверки нужны доступные местные файлы поддерживаемых форматов.'
        else FReason.Caption:='Проверка завершена. Нажмите «2. Заполнить сведения».';
      end;
    end;
    if ErrorText<>'' then ReportLine(ErrorText,tsError);
  finally FreeAndNil(FWorker); FApplying:=False; UpdateButtons; end;
  if FCloseWhenReady then Close;
end;

function FillMissingBookMetadata(AOwner: TComponent; CollectionID: Integer): Boolean;
var Dialog: TfrmBookMetadataFill;
begin
  Dialog:=TfrmBookMetadataFill.CreateForCollection(AOwner,CollectionID);
  try Dialog.ShowModal; Result:=Dialog.CommittedChanges;
  finally Dialog.Free; end;
end;

end.
