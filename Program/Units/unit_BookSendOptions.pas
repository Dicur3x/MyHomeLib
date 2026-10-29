unit unit_BookSendOptions;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  ShlObj, unit_Globals, unit_BookSavePolicy, unit_BookSendEstimates, unit_BookOutput;

type
  TBookSendOptions = record
    Folder: string;
    ShellItem: IShellItem;
    UseMTP, ExplicitFormat, KeepSourceFormat, KeepFB2EPUB, ZipEachBook: Boolean;
    NameCollision: TBookNameCollision;
    Mode: TExportMode;
    ImageQuality, FileNameTemplate, FolderTemplate, RequiredComponent: string;
    RequiredComponents: TArray<string>;
    ScriptIndex: Integer;
  end;
  PBookSendOptions = ^TBookSendOptions;

  TBookSendOptionsForm = class(TForm)
  private
    FShellItem: IShellItem;
    FDestination, FNameMask, FFolderMask, FExcept: TEdit;
    FFormat, FImages, FScans, FCollision: TComboBox;
    FSubfolders: TCheckBox;
    FContent: TScrollBox;
    FIntro, FFormatLabel, FImagesLabel, FSummary, FNote, FScanLabel,
      FExceptLabel, FMaskLabel, FMaskHelp, FFolderHelp, FCollisionLabel, FPreview, FStatus: TLabel;
    FCalculate, FSend: TButton;
    FList: TListView;
    FTimer: TTimer;
    FBooks: TArray<TBookRecord>;
    FChoices: TArray<TBookSaveChoice>;
    FItems: TBookSaveEstimateItems;
    FEstimate: TBookSendEstimateThread;
    FRevision: Integer;
    FRequiredComponent: string;
    FClosing, FReflowing, FInitializing: Boolean;
    procedure Browse(Sender: TObject);
    procedure Changed(Sender: TObject);
    procedure Send(Sender: TObject);
    procedure Calculate(Sender: TObject);
    procedure Tick(Sender: TObject);
    procedure QueryClose(Sender: TObject; var CanClose: Boolean);
    procedure Reflow(Sender: TObject);
    procedure ListData(Sender: TObject; Item: TListItem);
    procedure ListInfoTip(Sender: TObject; Item: TListItem; var InfoTip: string);
    procedure UpdateSummary;
    procedure UpdatePreview;
    procedure SetBooks(const Books: TArray<TBookRecord>);
    function Choice: TBookSaveChoice;
    function EstimateBytes(const Item: TBookSaveEstimateItem; Quality: Integer): Int64;
    function HasScanConversion: Boolean;
  public
    procedure ScaleForPPI(NewPPI: Integer); override;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

function ChooseBookSendOptions(BookCount: Integer; const InitialFolder: string;
  DefaultMode: TExportMode; out Options: TBookSendOptions;
  AllowScripts: Boolean = True; const Books: TArray<TBookRecord> = nil;
  InitialOptions: PBookSendOptions = nil): Boolean;

implementation

uses System.SysUtils, System.StrUtils, System.IOUtils, System.Math, Winapi.Windows, Winapi.ActiveX,
  Vcl.Controls, Vcl.Dialogs, Vcl.Graphics, unit_Helpers, unit_MHLTheme, dm_user,
  unit_Templater, unit_BookConversion;

const
  Qualities: array[0..3] of string = ('original','balanced','economy','none');
  QualityCaptions: array[0..3] of string = ('Как есть','Сбалансированный','Экономный','Без изображений');

type
  TSaveScrollBox = class(TScrollBox)
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  end;

function TSaveScrollBox.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if VertScrollBar.Range>ClientHeight then
  begin VertScrollBar.Position:=VertScrollBar.Position-WheelDelta div WHEEL_DELTA*MulDiv(48,CurrentPPI,96); Result:=True; end
  else Result:=inherited;
end;

function SizeText(Bytes: Int64): string;
begin
  if Bytes>=1024*1024*1024 then Result:=FormatFloat('0.00',Bytes/1024/1024/1024)+' ГБ'
  else if Bytes>=1024*1024 then Result:=FormatFloat('0.0',Bytes/1024/1024)+' МБ'
  else Result:=FormatFloat('0.0',Bytes/1024)+' КБ';
end;

constructor TBookSendOptionsForm.Create(AOwner: TComponent);
var Footer: TPanel; Button: TButton;
  function LabelControl(const Name, Text: string): TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=FContent; Result.Name:=Name;
    Result.Caption:=Text; Result.AutoSize:=False; Result.WordWrap:=True;
    Result.ShowAccelChar:=False;
  end;
  function Combo(const Name: string): TComboBox;
  begin
    Result:=TComboBox.Create(Self); Result.Parent:=FContent; Result.Name:=Name;
    Result.Style:=csDropDownList; Result.OnChange:=Changed;
  end;
begin
  inherited CreateNew(AOwner); FInitializing:=True;
  Name:='BookSendOptions'; Caption:='Сохранить как';
  Position:=poMainFormCenter; BorderStyle:=bsSizeable;
  Font.Name:='Segoe UI'; Font.Size:=9; ClientWidth:=780; ClientHeight:=680;
  Constraints.MinWidth:=640+Width-ClientWidth; Constraints.MinHeight:=430+Height-ClientHeight;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom;
  Footer.BevelOuter:=bvNone; Footer.Height:=56;
  FContent:=TSaveScrollBox.Create(Self); FContent.Parent:=Self; FContent.Align:=alClient;
  FContent.BorderStyle:=bsNone; FContent.HorzScrollBar.Visible:=False;
  FIntro:=LabelControl('SaveIntro','Куда сохранить: папка компьютера, облачной синхронизации или подключённой читалки.');
  FDestination:=TEdit.Create(Self); FDestination.Parent:=FContent; FDestination.Name:='SendDestination';
  FDestination.ReadOnly:=True; FDestination.ShowHint:=True;
  Button:=TButton.Create(Self); Button.Parent:=FContent; Button.Name:='BrowseDestination';
  Button.Caption:='Выбрать…'; Button.OnClick:=Browse;
  FFormatLabel:=LabelControl('FormatLabel','Формат книг:'); FFormat:=Combo('SendFormat');
  FImagesLabel:=LabelControl('ImagesLabel','Изображения:'); FImages:=Combo('SendImages');
  for var Text in QualityCaptions do FImages.Items.Add(Text);
  FImages.ItemIndex:=0;
  FCalculate:=TButton.Create(Self); FCalculate.Parent:=FContent; FCalculate.Name:='EstimateSaveSize';
  FCalculate.Caption:='Оценить размер'; FCalculate.OnClick:=Calculate;
  FSummary:=LabelControl('SaveSizeSummary','');
  FStatus:=LabelControl('SaveEstimateStatus','Для конвертации и сжатия размер оценивается по кнопке.');
  FList:=TListView.Create(Self); FList.Parent:=FContent; FList.Name:='SaveBookSizes';
  FList.ViewStyle:=vsReport; FList.ReadOnly:=True; FList.RowSelect:=True;
  FList.OwnerData:=True; FList.OnData:=ListData; FList.ShowHint:=True; FList.OnInfoTip:=ListInfoTip;
  FList.Columns.Add.Caption:='Книга'; FList.Columns.Add.Caption:='Формат копии'; FList.Columns.Add.Caption:='Размер';
  FScanLabel:=LabelControl('ScanLabel','Сканы разворотов при преобразовании в FB2/EPUB:');
  FScans:=Combo('SaveScanLayout'); FScans.Items.Add('Не разделять — оставить как есть');
  FScans.Items.Add('Автоматически по сгибу или свободному промежутку');
  FScans.Items.Add('По центру горизонтального скана'); FScans.ItemIndex:=0;
  FExceptLabel:=LabelControl('ScanExceptionsLabel','Не разделять сканы № (например, 1, 98-100):');
  FExcept:=TEdit.Create(Self); FExcept.Parent:=FContent; FExcept.Name:='SaveScanExceptions';
  FExcept.MaxLength:=256; FExcept.OnChange:=Changed;
  FNote:=LabelControl('SaveImagesNote','');
  FMaskLabel:=LabelControl('NameMaskLabel','Маска имени файла:');
  FNameMask:=TEdit.Create(Self); FNameMask.Parent:=FContent; FNameMask.Name:='SaveNameTemplate';
  FNameMask.Text:=Settings.FileNameTemplate; if FNameMask.Text='' then FNameMask.Text:='%t';
  FNameMask.OnChange:=Changed;
  FMaskHelp:=LabelControl('NameMaskHelp','%t — название; %f — автор; %s — серия; %n — номер. Например, [%n — ]%t: номер пропускается, если его нет. Расширение добавится автоматически.');
  FSubfolders:=TCheckBox.Create(Self); FSubfolders.Parent:=FContent; FSubfolders.Name:='SaveSubfolders';
  FSubfolders.Caption:='Создавать подпапки по маске'; FSubfolders.Checked:=Settings.SaveAsUseSubfolders;
  FSubfolders.OnClick:=Changed;
  FFolderMask:=TEdit.Create(Self); FFolderMask.Parent:=FContent; FFolderMask.Name:='SaveFolderTemplate';
  FFolderMask.Text:=Settings.SaveAsFolderTemplate; if FFolderMask.Text='' then FFolderMask.Text:='%f';
  FFolderMask.OnChange:=Changed;
  FFolderHelp:=LabelControl('FolderMaskHelp','Без галочки все книги сохранятся в выбранную папку. Примеры подпапок: %f — по автору; %f\%s — автор и серия.');
  FPreview:=LabelControl('SaveNamePreview','');
  FCollisionLabel:=LabelControl('NameCollisionLabel','Если файл с таким именем уже существует:');
  FCollision:=Combo('SaveNameCollision');
  FCollision.Items.Add('Спросить'); FCollision.Items.Add('Заменить файл');
  FCollision.Items.Add('Сохранить оба — добавить номер');
  FCollision.ItemIndex:=Ord(Settings.SaveAsNameCollision);
  FSend:=TButton.Create(Self); FSend.Parent:=Footer; FSend.Name:='SendBooks'; FSend.Caption:='Сохранить';
  FSend.SetBounds(510,13,120,30); FSend.Anchors:=[akTop,akRight]; FSend.Default:=True; FSend.OnClick:=Send;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.Name:='CancelSending'; Button.Caption:='Отмена';
  Button.SetBounds(640,13,120,30); Button.Anchors:=[akTop,akRight]; Button.Cancel:=True; Button.ModalResult:=mrCancel;
  FTimer:=TTimer.Create(Self); FTimer.Enabled:=False; FTimer.Interval:=150; FTimer.OnTimer:=Tick;
  OnResize:=Reflow; OnCloseQuery:=QueryClose;
  FInitializing:=False; SetBooks(nil); ApplyMHLControlTheme(Self); Changed(FFormat);
end;

destructor TBookSendOptionsForm.Destroy;
begin
  FTimer.Enabled:=False;
  if Assigned(FEstimate) then begin FEstimate.Terminate; FEstimate.Free; end;
  inherited;
end;

procedure TBookSendOptionsForm.ScaleForPPI(NewPPI: Integer);
var OldPPI, W, H: Integer;
begin
  OldPPI:=PixelsPerInch; W:=ClientWidth; H:=ClientHeight; inherited;
  if (OldPPI>0) and (NewPPI<>OldPPI) then
  begin ClientWidth:=MulDiv(W,NewPPI,OldPPI); ClientHeight:=MulDiv(H,NewPPI,OldPPI); end;
  Reflow(nil);
end;

procedure TBookSendOptionsForm.SetBooks(const Books: TArray<TBookRecord>);
var Extensions: TArray<string>;
begin
  FBooks:=Copy(Books); SetLength(Extensions,Length(Books));
  for var I:=0 to High(Books) do
    try Extensions[I]:=BookSaveKnownExtension(Books[I]); except Extensions[I]:=LowerCase(Books[I].FileExt); end;
  FChoices:=BookSaveChoices(Extensions); FFormat.Items.BeginUpdate;
  try FFormat.Items.Clear; for var Entry in FChoices do FFormat.Items.Add(Entry.Caption);
  finally FFormat.Items.EndUpdate; end;
  FFormat.ItemIndex:=0; FItems:=KnownBookSaveEstimates(FBooks,Choice);
  FList.Items.Count:=Length(FBooks); Changed(FFormat);
end;

function TBookSendOptionsForm.Choice: TBookSaveChoice;
begin
  if (FFormat.ItemIndex>=0) and (FFormat.ItemIndex<Length(FChoices)) then Result:=FChoices[FFormat.ItemIndex]
  else Result:=Default(TBookSaveChoice);
end;

procedure TBookSendOptionsForm.Browse(Sender: TObject);
var Folder: string; Item: IShellItem;
begin
  Folder:=FDestination.Text;
  if not GetFolderShellItem(Handle,'Куда сохранить книги',Folder,Item) then Exit;
  FShellItem:=Item; FDestination.Text:=Folder; FDestination.Hint:=Folder; Changed(FDestination);
end;

function TBookSendOptionsForm.HasScanConversion: Boolean;
begin
  Result:=False;
  for var Item in FItems do
    if BookSaveIsScanSource(Item.SourceExtension) and not SameText(Item.SourceExtension,Item.TargetExtension) then Exit(True);
end;

function TBookSendOptionsForm.EstimateBytes(const Item: TBookSaveEstimateItem; Quality: Integer): Int64;
var Layout: Integer;
begin
  Layout:=0;
  if Item.Options.ScanPages and FScans.Enabled then
    case FScans.ItemIndex of 1: Layout:=2; 2: Layout:=1; end;
  if BookSaveZipsTarget(Item.TargetExtension,Choice.Mode) then Result:=Item.Options.ZipOutputBytes[Layout,Quality]
  else Result:=Item.Options.OutputBytes[Layout,Quality];
end;

procedure TBookSendOptionsForm.UpdateSummary;
var Text: string; Total: Int64; Unknown, Large: Integer;
begin
  Text:='';
  for var Q:=0 to 3 do
  begin
    Total:=0; Unknown:=0; Large:=0;
    for var Item in FItems do
    begin
      var Bytes:=EstimateBytes(Item,Q);
      if Bytes>0 then begin Inc(Total,Bytes); if Bytes>20*1024*1024 then Inc(Large); end else Inc(Unknown);
    end;
    if Q>0 then Text:=Text+sLineBreak;
    Text:=Text+QualityCaptions[Q]+': ';
    if Length(FItems)=0 then Text:=Text+'нет оценки'
    else if Unknown=Length(FItems) then Text:=Text+'не рассчитано'
    else begin Text:=Text+'≈ '+SizeText(Total); if Unknown>0 then Text:=Text+Format(' + ещё %d без оценки',[Unknown]); end;
    if Large>0 then Text:=Text+Format(' · крупнее 20 МБ: %d',[Large]);
  end;
  FSummary.Caption:=Text;
  FList.Invalidate;
end;

procedure TBookSendOptionsForm.UpdatePreview;
var Templater: TTemplater; Book: TBookRecord; Ext, FileName, Folder: string;
begin
  Templater:=TTemplater.Create;
  try
    if (Trim(FNameMask.Text)='') or (Templater.SetTemplate(FNameMask.Text,TpFile)<>ErFine) then
    begin FPreview.Caption:='Проверьте маску имени: неизвестный параметр или непарные скобки.'; Exit; end;
    Book:=Default(TBookRecord); Book.Title:='Название книги';
    if Length(FBooks)>0 then Book:=FBooks[0];
    FileName:=Trim(Templater.ParseString(Book,TpFile));
    Folder:=FDestination.Text;
    if FSubfolders.Checked then
    begin
      if (Trim(FFolderMask.Text)='') or not IsValidBookSaveFolderTemplate(FFolderMask.Text) or
        (Templater.SetTemplate(FFolderMask.Text,TpPath)<>ErFine) then
      begin FPreview.Caption:='Проверьте маску подпапок.'; Exit; end;
      Folder:=TPath.Combine(Folder,BookSaveRelativeFolder(Templater.ParseString(Book,TpPath)));
    end;
    Ext:=BookSaveTargetExtension(BookSaveKnownExtension(Book),Choice.Mode,Choice.KeepOriginal,Choice.KeepFB2EPUB);
    if BookSaveZipsTarget(Ext,Choice.Mode) then Ext:=Ext+'.zip';
    FileName:=BookOutputName(FileName,Ext,Book.BookKey.BookID);
    if FileName='' then FPreview.Caption:='Для первой книги маска даёт пустое имя. Добавьте %t или %id.'
    else
    begin
      FPreview.Caption:='Пример: '+TPath.Combine(Folder,FileName+Ext)+sLineBreak;
      case TBookNameCollision(FCollision.ItemIndex) of
        bncAsk: FPreview.Caption:=FPreview.Caption+'При совпадении имени программа предложит заменить файл или сохранить оба.';
        bncReplace: FPreview.Caption:=FPreview.Caption+'Файл заменится только после успешного сохранения нового. Исходная книга не перезаписывается.';
        bncKeepBoth: FPreview.Caption:=FPreview.Caption+'При совпадении имени добавится номер, например «Название (1).fb2».';
      end;
    end;
  finally Templater.Free; end;
end;

procedure TBookSendOptionsForm.Changed(Sender: TObject);
var CanProcess, Opaque: Boolean;
begin
  if FInitializing then Exit;
  if Sender=FFormat then
  begin FItems:=KnownBookSaveEstimates(FBooks,Choice); FRequiredComponent:=''; FCalculate.Caption:='Оценить размер'; end;
  CanProcess:=Length(FBooks)=0; Opaque:=False;
  for var Item in FItems do
    if (Item.TargetExtension='.fb2') or (Item.TargetExtension='.epub') then CanProcess:=True else Opaque:=True;
  FImages.Enabled:=CanProcess;
  if not CanProcess then FImages.ItemIndex:=0;
  FScans.Enabled:=HasScanConversion;
  FScanLabel.Visible:=FScans.Enabled; FScans.Visible:=FScans.Enabled;
  FExceptLabel.Visible:=FScans.Enabled; FExcept.Visible:=FScans.Enabled;
  FExcept.Enabled:=FScans.Enabled and (FScans.ItemIndex>0);
  FNote.Caption:='Параметры меняют только сохраняемые копии. Исходные книги в коллекции сохраняются.';
  if Opaque then FNote.Caption:=FNote.Caption+' Настройка изображений действует на FB2/EPUB; остальные исходные форматы копируются как есть.';
  if FImages.ItemIndex=3 then FNote.Caption:=FNote.Caption+' На месте картинок будет пометка «Изображение не включено в эту копию». Для страниц-сканов этот режим недоступен.';
  if FExcept.Enabled and (Trim(FExcept.Text)<>'') then FNote.Caption:=FNote.Caption+' При исключениях сканов оценка размера особенно приблизительная.';
  FNote.Caption:=FNote.Caption+' Отметка 20 МБ — подсказка для крупных файлов, а не ограничение формата. Для уменьшения размера выберите другой режим изображений.';
  FFolderMask.Enabled:=FSubfolders.Checked;
  UpdateSummary; UpdatePreview; Reflow(nil);
end;

procedure TBookSendOptionsForm.ListData(Sender: TObject; Item: TListItem);
begin
  if (Item.Index<0) or (Item.Index>=Length(FItems)) then Exit;
  var Entry:=FItems[Item.Index]; Item.Caption:=FBooks[Item.Index].Title; Item.SubItems.Clear;
  var Ext:=UpperCase(Entry.TargetExtension.TrimLeft(['.']));
  if BookSaveZipsTarget(Entry.TargetExtension,Choice.Mode) then Ext:=Ext+' в ZIP';
  Item.SubItems.Add(Ext);
  var Bytes:=EstimateBytes(Entry,Max(0,FImages.ItemIndex));
  if Bytes>0 then Item.SubItems.Add('≈ '+SizeText(Bytes))
  else if Entry.ErrorText<>'' then Item.SubItems.Add('Нет оценки')
  else Item.SubItems.Add('Не рассчитано');
end;

procedure TBookSendOptionsForm.ListInfoTip(Sender: TObject; Item: TListItem; var InfoTip: string);
begin
  if (Item.Index>=0) and (Item.Index<Length(FItems)) then
    InfoTip:=FBooks[Item.Index].Title+sLineBreak+FItems[Item.Index].ErrorText;
end;

procedure TBookSendOptionsForm.Calculate(Sender: TObject);
begin
  if FRequiredComponent<>'' then begin ModalResult:=mrRetry; Exit; end;
  if Assigned(FEstimate) then
  begin FEstimate.Terminate; FStatus.Caption:='Останавливаем оценку…'; Exit; end;
  if Length(FBooks)=0 then begin FStatus.Caption:='Список книг для оценки не передан.'; Exit; end;
  FRevision:=-1; FEstimate:=TBookSendEstimateThread.Create(FBooks,Choice,Settings.AppPath,Settings.TempPath);
  FFormat.Enabled:=False; FSend.Enabled:=False; FCalculate.Caption:='Остановить';
  FStatus.Caption:='Оценка по образцам изображений. Для длинных сканов потребуется время…';
  FTimer.Enabled:=True; FEstimate.Start;
end;

procedure TBookSendOptionsForm.Tick(Sender: TObject);
var Items: TBookSaveEstimateItems; Status: string; Complete: Boolean; ChangedSnapshot: Boolean;
begin
  if not Assigned(FEstimate) then Exit;
  ChangedSnapshot:=FEstimate.Poll(FRevision,Items,Status,Complete);
  if ChangedSnapshot then begin FItems:=Items; FStatus.Caption:=Status; UpdateSummary; Reflow(nil); end;
  if not Complete then Exit;
  FTimer.Enabled:=False;
  if FEstimate.FatalException is Exception then FStatus.Caption:='Оценка остановлена: '+Exception(FEstimate.FatalException).Message
  else if Status.StartsWith('Оценка остановлена') then FStatus.Caption:=Status
  else
  begin
    var Errors:=0; var FirstError:=''; var Limited:=False;
    for var Item in FItems do
    begin
      if Item.ErrorText<>'' then begin Inc(Errors); if FirstError='' then FirstError:=Item.ErrorText; end;
      if (FRequiredComponent='') and (Item.RequiredComponent<>'') then FRequiredComponent:=Item.RequiredComponent;
      Limited:=Limited or Item.Options.FirstSamples;
    end;
    if Errors>0 then FStatus.Caption:=Format('Не удалось оценить %d книг: %s',[Errors,FirstError])
    else if Limited then FStatus.Caption:='Размер ориентировочный: для длинных сканов проверены первые страницы. Результат может отличаться.'
    else FStatus.Caption:='Оценка по образцам готова. Итоговый размер может немного отличаться.';
  end;
  FreeAndNil(FEstimate); FFormat.Enabled:=True; FSend.Enabled:=True; FCalculate.Caption:='Оценить размер';
  if FRequiredComponent<>'' then
    if Length(BookSaveMissingComponents(FItems))>1 then FCalculate.Caption:='Установить модули…'
    else FCalculate.Caption:='Установить модуль…';
  if FClosing then ModalResult:=mrCancel else Changed(FImages);
end;

procedure TBookSendOptionsForm.QueryClose(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:=not Assigned(FEstimate);
  if not CanClose then begin FClosing:=True; FEstimate.Terminate; FStatus.Caption:='Останавливаем оценку и удаляем временные данные…'; end;
end;

procedure TBookSendOptionsForm.Reflow(Sender: TObject);
var Y, W, Margin, Gap, SavedScroll, RowHeight: Integer;
  function S(Value: Integer): Integer;
  begin Result:=MulDiv(Value,PixelsPerInch,96); end;
  procedure Place(Control: TControl; Height: Integer);
  begin
    if not Control.Visible then Exit;
    Control.SetBounds(Margin,Y,W,Height); Inc(Y,Height+Gap);
  end;
  procedure Text(Control: TLabel);
  var Bounds: TRect;
  begin
    if not Control.Visible then Exit;
    Canvas.Font.Assign(Control.Font); Bounds:=Rect(0,0,W,0);
    DrawText(Canvas.Handle,PChar(Control.Caption),Length(Control.Caption),Bounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Place(Control,Max(S(18),Bounds.Height+S(2)));
  end;
begin
  if FInitializing or FReflowing or not Assigned(FContent) or not Assigned(FPreview) then Exit;
  FReflowing:=True; SavedScroll:=FContent.VertScrollBar.Position;
  try
    FContent.VertScrollBar.Position:=0; Margin:=S(20); Gap:=S(8); RowHeight:=S(28);
    for var Pass:=1 to 2 do
    begin
      Y:=S(16); W:=Max(S(300),FContent.ClientWidth-2*Margin);
      Text(FIntro);
      FDestination.SetBounds(Margin,Y,W-S(130),RowHeight);
      TControl(FindComponent('BrowseDestination')).SetBounds(Margin+W-S(120),Y,S(120),RowHeight); Inc(Y,RowHeight+S(16));
      Text(FFormatLabel); Place(FFormat,RowHeight);
      Text(FImagesLabel); FImages.SetBounds(Margin,Y,W-S(160),RowHeight);
      FCalculate.SetBounds(Margin+W-S(150),Y,S(150),RowHeight); Inc(Y,RowHeight+Gap);
      Text(FSummary); Text(FStatus);
      FList.Visible:=Length(FBooks)>1;
      if FList.Visible then
      begin
        Place(FList,S(140)); FList.Columns[0].Width:=Max(S(120),W-S(290));
        FList.Columns[1].Width:=S(140); FList.Columns[2].Width:=S(120);
      end;
      Text(FScanLabel); Place(FScans,RowHeight); Text(FExceptLabel); Place(FExcept,RowHeight);
      Text(FNote); Inc(Y,S(6)); Text(FMaskLabel); Place(FNameMask,RowHeight);
      Text(FMaskHelp); Place(FSubfolders,S(24)); Place(FFolderMask,RowHeight);
      Text(FFolderHelp); Text(FCollisionLabel); Place(FCollision,RowHeight); Text(FPreview);
      FContent.VertScrollBar.Range:=Y+S(12);
    end;
  finally FContent.VertScrollBar.Position:=SavedScroll; FReflowing:=False; end;
end;

procedure TBookSendOptionsForm.Send(Sender: TObject);
var Templater: TTemplater;
begin
  if Assigned(FEstimate) then Exit;
  if Trim(FDestination.Text)='' then begin Browse(nil); if Trim(FDestination.Text)='' then Exit; end;
  if IsShellPath(FDestination.Text) then
  begin
    if not Assigned(FShellItem) and Failed(SHCreateItemFromParsingName(PChar(FDestination.Text),nil,IShellItem,FShellItem)) then
    begin MessageDlg('Устройство недоступно. Подключите его и выберите папку снова.',mtInformation,[mbOK],0); Exit; end;
  end
  else if not TPath.IsPathRooted(FDestination.Text) then
  begin MessageDlg('Выберите папку, в которую нужно сохранить книги.',mtInformation,[mbOK],0); Exit; end;
  Templater:=TTemplater.Create;
  try
    if (Trim(FNameMask.Text)='') or (Templater.SetTemplate(FNameMask.Text,TpFile)<>ErFine) then
    begin MessageDlg('Проверьте маску имени файла.',mtInformation,[mbOK],0); FNameMask.SetFocus; Exit; end;
    if FSubfolders.Checked and ((Trim(FFolderMask.Text)='') or
      not IsValidBookSaveFolderTemplate(FFolderMask.Text)) then
    begin MessageDlg('Проверьте маску подпапок.',mtInformation,[mbOK],0); FFolderMask.SetFocus; Exit; end;
    for var Book in FBooks do
      if (Book.FileName<>'') and (Trim(Templater.ParseString(Book,TpFile))='') then
      begin MessageDlg('Маска даёт пустое имя для книги «'+Book.Title+'». Добавьте %t или %id.',mtInformation,[mbOK],0); Exit; end;
  finally Templater.Free; end;
  if FExcept.Enabled and not IsValidScanPageExclusions(FExcept.Text) then
  begin MessageDlg('Укажите номера сканов, например 1, 98-100.',mtInformation,[mbOK],0); FExcept.SetFocus; Exit; end;
  ModalResult:=mrOk;
end;

function ChooseBookSendOptions(BookCount: Integer; const InitialFolder: string;
  DefaultMode: TExportMode; out Options: TBookSendOptions; AllowScripts: Boolean;
  const Books: TArray<TBookRecord>; InitialOptions: PBookSendOptions): Boolean;
var Dialog: TBookSendOptionsForm; Selected: TBookSaveChoice;
begin
  Result:=False; Options:=Default(TBookSendOptions);
  // In the standalone reader the main launcher is hidden while the book is
  // modal. Own and center this dialog on the visible book, not that launcher.
  var ParentForm:=Screen.ActiveForm;
  if not Assigned(ParentForm) then ParentForm:=Application.MainForm;
  Dialog:=TBookSendOptionsForm.Create(ParentForm);
  try
    if Assigned(ParentForm) then
    begin
      Dialog.PopupMode:=pmExplicit; Dialog.PopupParent:=ParentForm;
      Dialog.Position:=poOwnerFormCenter;
    end;
    Dialog.SetBooks(Books); Dialog.Caption:=Format('Сохранить как · книг: %d',[BookCount]);
    var Folder:=Settings.SyncExportDir; if Folder='' then Folder:=InitialFolder;
    Dialog.FDestination.Text:=Folder; Dialog.FDestination.Hint:=Folder;
    if Assigned(InitialOptions) then
    begin
      // Restoring a scan exclusion or folder edit fires Changed. Until the
      // final format/estimate snapshot is in place it still describes an
      // unchanged PDF/DjVu, which would reset the restored image quality.
      Dialog.FInitializing:=True;
      try
      Dialog.FDestination.Text:=InitialOptions.Folder;
      Dialog.FNameMask.Text:=InitialOptions.FileNameTemplate;
      Dialog.FCollision.ItemIndex:=Ord(InitialOptions.NameCollision);
      Dialog.FSubfolders.Checked:=InitialOptions.FolderTemplate<>'';
      if Dialog.FSubfolders.Checked then Dialog.FFolderMask.Text:=InitialOptions.FolderTemplate;
      var InitialMode:=InitialOptions.Mode;
      if InitialMode=emEpubZip then InitialMode:=emEpub
      else if InitialOptions.ZipEachBook and (InitialMode=emFB2) then InitialMode:=emFB2Zip;
      for var I:=0 to High(Dialog.FChoices) do
        if (Dialog.FChoices[I].KeepOriginal=InitialOptions.KeepSourceFormat) and
          (Dialog.FChoices[I].KeepFB2EPUB=InitialOptions.KeepFB2EPUB) and
          (Dialog.FChoices[I].Mode=InitialMode) then
        begin Dialog.FFormat.ItemIndex:=I; Break; end;
      var Parts:=InitialOptions.ImageQuality.Split(['|']);
      if Length(Parts)>0 then for var I:=0 to High(Qualities) do
        if Parts[0]=Qualities[I] then Dialog.FImages.ItemIndex:=I;
      if Length(Parts)>1 then
        if Parts[1]='auto' then Dialog.FScans.ItemIndex:=1
        else if Parts[1]='split' then Dialog.FScans.ItemIndex:=2;
      if (Length(Parts)>2) and Parts[2].StartsWith('except=') then Dialog.FExcept.Text:=Parts[2].Substring(7);
      Dialog.FItems:=KnownBookSaveEstimates(Dialog.FBooks,Dialog.Choice);
      finally Dialog.FInitializing:=False; end;
    end;
    Dialog.Changed(nil);
    var Answer:=Dialog.ShowModal;
    if not (Answer in [mrOk,mrRetry]) then Exit;
    Options.Folder:=Dialog.FDestination.Text; Options.ShellItem:=Dialog.FShellItem;
    Options.UseMTP:=IsShellPath(Options.Folder); Selected:=Dialog.Choice;
    Options.KeepSourceFormat:=Selected.KeepOriginal; Options.KeepFB2EPUB:=Selected.KeepFB2EPUB;
    Options.ExplicitFormat:=not Selected.KeepOriginal; Options.ScriptIndex:=-1;
    Options.Mode:=Selected.Mode; Options.ZipEachBook:=False;
    Options.NameCollision:=TBookNameCollision(Dialog.FCollision.ItemIndex);
    Options.FileNameTemplate:=Dialog.FNameMask.Text;
    if Dialog.FSubfolders.Checked then Options.FolderTemplate:=Dialog.FFolderMask.Text;
    if Answer=mrRetry then
    begin
      Options.RequiredComponent:=Dialog.FRequiredComponent;
      Options.RequiredComponents:=BookSaveMissingComponents(Dialog.FItems);
    end;
    Options.ImageQuality:='original';
    if Dialog.FImages.Enabled then Options.ImageQuality:=Qualities[Dialog.FImages.ItemIndex];
    if Dialog.FScans.Enabled and (Dialog.FScans.ItemIndex>0) and (Dialog.FImages.ItemIndex<>3) then
    begin
      if Dialog.FScans.ItemIndex=1 then Options.ImageQuality:=Options.ImageQuality+'|auto'
      else Options.ImageQuality:=Options.ImageQuality+'|split';
      if Trim(Dialog.FExcept.Text)<>'' then Options.ImageQuality:=Options.ImageQuality+'|except='+Trim(Dialog.FExcept.Text);
    end;
    Settings.SyncExportDir:=Options.Folder; Settings.FileNameTemplate:=Options.FileNameTemplate;
    Settings.SaveAsUseSubfolders:=Dialog.FSubfolders.Checked;
    Settings.SaveAsNameCollision:=Options.NameCollision;
    Settings.SaveAsFolderTemplate:=Dialog.FFolderMask.Text;
    Settings.SaveSettings;
    Result:=Answer=mrOk;
  finally Dialog.Free; end;
end;

end.
