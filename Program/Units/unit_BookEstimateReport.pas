unit unit_BookEstimateReport;

interface

uses System.Classes, Vcl.Forms, unit_Globals, unit_BookSavePolicy, unit_BookSendEstimates;

function BookEstimateSizeText(Bytes: Int64): string;
function BookEstimateResultText(const Item: TBookSaveEstimateItem; Bytes: Int64): string;
function BookEstimateReport(const Books: TArray<TBookRecord>; const Items: TBookSaveEstimateItems;
  const Plan: TBookSaveChoice; Quality, ScanLayout: Integer; const Status: string): string;
procedure SaveBookEstimateReport(const FileName, Report: string; Overwrite: Boolean=False);

type
  TBookEstimateReportForm = class(TForm)
  private
    FReport: string;
    procedure CopyClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
  public
    constructor CreateReport(AOwner: TComponent; const Report: string);
  end;

implementation

uses System.SysUtils, System.Math, System.IOUtils, System.StrUtils, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.Controls, Vcl.Dialogs, Vcl.Clipbrd, unit_MHLTheme, unit_BookOutput;

const QualityNames: array[0..3] of string = ('Как есть','Сбалансированный','Экономный','Без изображений');

function BookEstimateSizeText(Bytes: Int64): string;
begin
  if Bytes>=1024*1024*1024 then Result:=FormatFloat('0.00',Bytes/1024/1024/1024)+' ГБ'
  else if Bytes>=1024*1024 then Result:=FormatFloat('0.0',Bytes/1024/1024)+' МБ'
  else if Bytes>=1024 then Result:=FormatFloat('0.0',Bytes/1024)+' КБ'
  else Result:=IntToStr(Bytes)+' Б';
end;

function BookEstimateResultText(const Item: TBookSaveEstimateItem; Bytes: Int64): string;
begin
  if Item.ErrorText<>'' then
  begin
    if Bytes>0 then Result:='Размер известен; '+Item.ErrorText
    else Result:=Item.ErrorText;
  end
  else if Bytes>0 then
  begin
    if Item.Options.FirstSamples then Result:='Приблизительно, по первым страницам'
    else if Item.Completed then Result:='Рассчитано'
    else Result:='Известен размер исходной копии';
  end
  else if not Item.Completed then Result:='Расчёт не завершён'
  else if Item.Options.ScanPages then Result:='Для этого режима сканов оценка недоступна'
  else Result:='Оценка недоступна';
end;

function BookEstimateReport(const Books: TArray<TBookRecord>; const Items: TBookSaveEstimateItems;
  const Plan: TBookSaveChoice; Quality, ScanLayout: Integer; const Status: string): string;
var Text: TStringBuilder; Entry: TBookSaveEstimateItem; Layout, Errors: Integer;
begin
  Text:=TStringBuilder.Create;
  try
    Text.AppendLine('HomeLib — оценка размера книг');
    Text.AppendLine(FormatDateTime('dd.mm.yyyy hh:nn:ss',Now));
    Text.AppendLine('Это оценка размера, а не результат сохранения. Неудачная оценка не означает, что сохранить книгу невозможно.');
    Text.AppendLine('Выбрано: '+QualityNames[EnsureRange(Quality,0,3)]);
    Text.AppendLine(Status); Text.AppendLine; Errors:=0;
    for var I:=0 to High(Books) do
    begin
      Entry:=Default(TBookSaveEstimateItem); if I<Length(Items) then Entry:=Items[I];
      if Entry.ErrorText<>'' then Inc(Errors);
      Text.AppendLine(IntToStr(I+1)+'. '+Books[I].Title);
      Text.AppendLine(Format('BookID: %d; коллекция: %d; ID источника: %s',
        [Books[I].BookKey.BookID,Books[I].BookKey.DatabaseID,Books[I].LibID]));
      var Target:=UpperCase(Entry.TargetExtension.TrimLeft(['.']));
      if BookSaveZipsTarget(Entry.TargetExtension,Plan.Mode) then Target:=Target+' в ZIP';
      Text.AppendLine('Формат: '+UpperCase(Entry.SourceExtension.TrimLeft(['.']))+' → '+Target);
      Layout:=0; if Entry.Options.ScanPages then Layout:=EnsureRange(ScanLayout,0,2);
      for var Q:=0 to 3 do
      begin
        var Bytes:=Entry.Options.OutputBytes[Layout,Q];
        if BookSaveZipsTarget(Entry.TargetExtension,Plan.Mode) then Bytes:=Entry.Options.ZipOutputBytes[Layout,Q];
        var Value:='не рассчитано';
        if Bytes>0 then Value:='≈ '+BookEstimateSizeText(Bytes)
        else if Entry.Completed and (Entry.ErrorText='') and Entry.Options.ScanPages and (Q=3) then
          Value:='недоступно для страниц-сканов';
        if Bytes>20*1024*1024 then Value:=Value+' — крупнее 20 МБ';
        Text.AppendLine('  '+QualityNames[Q]+': '+Value);
      end;
      if Entry.ErrorText<>'' then Text.AppendLine('Причина: '+Entry.ErrorText)
      else if not Entry.Completed then Text.AppendLine('Расчёт этой книги не завершён.');
      var Needed:=Entry.RequiredComponents;
      if (Length(Needed)=0) and (Entry.RequiredComponent<>'') then Needed:=TArray<string>.Create(Entry.RequiredComponent);
      if Length(Needed)>0 then Text.AppendLine('Нужны компоненты: '+string.Join(', ',Needed));
      if Entry.ImagesUnchanged then Text.AppendLine('Исходный формат копируется без изменения изображений.');
      if Entry.Options.FirstSamples then Text.AppendLine('Для длинных сканов проверены первые страницы; итоговый размер может отличаться.');
      Text.AppendLine;
    end;
    Text.AppendLine(Format('Всего книг: %d. С ошибкой при оценке: %d.',[Length(Books),Errors]));
    Result:=Text.ToString;
  finally Text.Free; end;
end;

procedure SaveBookEstimateReport(const FileName, Report: string; Overwrite: Boolean);
var Stage: string;
begin
  Stage:=CreateBookOutputStage(FileName);
  try
    TFile.WriteAllText(Stage,Report,TEncoding.UTF8);
    PublishBookOutput(Stage,FileName,Overwrite); Stage:='';
  finally DeleteBookOutputStage(Stage); end;
end;

constructor TBookEstimateReportForm.CreateReport(AOwner: TComponent; const Report: string);
var Intro: TLabel; Memo: TMemo; Footer: TPanel; Button: TButton;
begin
  inherited CreateNew(AOwner); Name:='BookSaveEstimateReport'; Caption:='Результаты оценки размера';
  FReport:=Report; Font.Name:='Segoe UI'; Font.Size:=9; Position:=poOwnerFormCenter;
  BorderStyle:=bsSizeable; ClientWidth:=740; ClientHeight:=480;
  Constraints.MinWidth:=540; Constraints.MinHeight:=320;
  Intro:=TLabel.Create(Self); Intro.Parent:=Self; Intro.Align:=alTop; Intro.Height:=52;
  Intro.AlignWithMargins:=True; Intro.Margins.SetBounds(12,8,12,0);
  Intro.AutoSize:=False; Intro.WordWrap:=True;
  Intro.Caption:='Все выбранные книги, размеры по режимам и причины отсутствующей оценки. Этот отчёт не означает, что книги уже сохранены.';
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom;
  Footer.Height:=52; Footer.BevelOuter:=bvNone;
  Memo:=TMemo.Create(Self); Memo.Parent:=Self; Memo.Name:='EstimateReportText';
  Memo.Align:=alClient; Memo.AlignWithMargins:=True; Memo.Margins.SetBounds(12,8,12,0);
  Memo.ReadOnly:=True; Memo.ScrollBars:=ssVertical; Memo.WordWrap:=True; Memo.Text:=Report;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.Name:='CopyEstimateReport';
  Button.SetBounds(12,11,140,30); Button.Caption:='Копировать'; Button.OnClick:=CopyClick;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.Name:='SaveEstimateReport';
  Button.SetBounds(164,11,180,30); Button.Caption:='Сохранить отчёт…'; Button.OnClick:=SaveClick;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.Name:='CloseEstimateReport';
  Button.SetBounds(ClientWidth-122,11,110,30); Button.Caption:='Закрыть'; Button.Anchors:=[akTop,akRight];
  Button.ModalResult:=mrClose; Button.Cancel:=True;
  ApplyMHLControlTheme(Self); ScaleForPPI(Screen.PixelsPerInch);
end;

procedure TBookEstimateReportForm.CopyClick(Sender: TObject);
begin
  try Clipboard.AsText:=FReport;
  except on E: Exception do MessageDlg('Не удалось скопировать отчёт: '+E.Message,mtError,[mbOK],0); end;
end;

procedure TBookEstimateReportForm.SaveClick(Sender: TObject);
var Dialog: TSaveDialog;
begin
  Dialog:=TSaveDialog.Create(Self);
  try
    Dialog.Title:='Сохранить результаты оценки размера'; Dialog.DefaultExt:='txt';
    Dialog.Filter:='Текстовый отчёт (*.txt)|*.txt'; Dialog.Options:=[ofOverwritePrompt,ofPathMustExist,ofEnableSizing,ofNoChangeDir];
    Dialog.FileName:='HomeLib-size-estimate-'+FormatDateTime('yyyymmdd-hhnnss',Now)+'.txt';
    if Dialog.Execute then
      try SaveBookEstimateReport(Dialog.FileName,FReport,True);
      except on E: Exception do MessageDlg('Не удалось сохранить отчёт: '+E.Message,mtError,[mbOK],0); end;
  finally Dialog.Free; end;
end;

end.
