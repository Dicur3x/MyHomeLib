unit frm_ReaderCacheSettings;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls;

type
  TfrmReaderCacheSettings = class(TForm)
  private
    FPolicy, FUnit: TComboBox;
    FDays, FLimit, FPath: TEdit;
    FExit: TCheckBox;
    FUsage, FError: TLabel;
    FTimer: TTimer;
    procedure PolicyChanged(Sender: TObject);
    procedure UpdateUsage(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

procedure ConfigureReaderCache;

implementation

uses System.SysUtils, System.Math, Vcl.Controls, dm_user, unit_Settings, unit_BookCache,
  unit_Diagnostics, unit_MHLTheme;

constructor TfrmReaderCacheSettings.Create(AOwner: TComponent);
var LabelControl: TLabel; Button: TButton;
  procedure LabelAt(const Text: string; Top, Height: Integer);
  begin
    LabelControl:=TLabel.Create(Self); LabelControl.Parent:=Self;
    LabelControl.AutoSize:=False; LabelControl.WordWrap:=True;
    LabelControl.SetBounds(20,Top,520,Height); LabelControl.Anchors:=[akLeft,akTop,akRight];
    LabelControl.Caption:=Text;
  end;
begin
  inherited CreateNew(AOwner);
  Name:='ReaderCacheSettings'; Caption:='Кэш книг — HomeLibre Reader';
  Position:=poOwnerFormCenter; Font.Name:='Segoe UI'; Font.Size:=10;
  ClientWidth:=560; ClientHeight:=480; Constraints.MinWidth:=530; Constraints.MinHeight:=Height;
  LabelAt('Подготовленные файлы ускоряют повторное открытие книг. Выберите, когда их очищать.',20,44);
  LabelAt('Очищать:',80,24);
  FPolicy:=TComboBox.Create(Self); FPolicy.Parent:=Self; FPolicy.Name:='ReaderCachePolicy';
  FPolicy.SetBounds(190,76,350,26); FPolicy.Anchors:=[akLeft,akTop,akRight];
  FPolicy.Style:=csDropDownList;
  FPolicy.Items.Add('По объёму'); FPolicy.Items.Add('По сроку хранения');
  FPolicy.Items.Add('По объёму и сроку'); FPolicy.ItemIndex:=Ord(Settings.BookCachePolicy);
  FPolicy.OnChange:=PolicyChanged;
  LabelAt('Срок после открытия:',118,24);
  FDays:=TEdit.Create(Self); FDays.Parent:=Self; FDays.Name:='ReaderCacheDays';
  FDays.SetBounds(190,114,100,26); FDays.Text:=IntToStr(Settings.BookCacheKeepDays);
  LabelAt('дней',118,24); LabelControl.Left:=304; LabelControl.Width:=80;
  LabelAt('Максимальный объём:',156,24);
  FLimit:=TEdit.Create(Self); FLimit.Parent:=Self; FLimit.Name:='ReaderCacheLimit';
  FLimit.SetBounds(190,152,100,26);
  FUnit:=TComboBox.Create(Self); FUnit.Parent:=Self; FUnit.Name:='ReaderCacheUnit';
  FUnit.SetBounds(304,152,90,26); FUnit.Style:=csDropDownList;
  FUnit.Items.Add('МБ'); FUnit.Items.Add('ГБ');
  if Settings.BookCacheLimitMB mod 1024=0 then
  begin FUnit.ItemIndex:=1; FLimit.Text:=IntToStr(Settings.BookCacheLimitMB div 1024); end
  else begin FUnit.ItemIndex:=0; FLimit.Text:=IntToStr(Settings.BookCacheLimitMB); end;
  FExit:=TCheckBox.Create(Self); FExit.Parent:=Self; FExit.Name:='ReaderCacheOnExit';
  FExit.SetBounds(20,194,520,26); FExit.Anchors:=[akLeft,akTop,akRight];
  FExit.Caption:='Очищать при каждом выходе из читалки'; FExit.Checked:=Settings.ClearBookCacheOnExit;
  LabelAt('Исходные книги, позиции, закладки и заметки при очистке сохраняются.',230,42);
  LabelAt('Папка кэша:',282,22);
  FPath:=TEdit.Create(Self); FPath.Parent:=Self; FPath.Name:='ReaderCachePath';
  FPath.SetBounds(20,306,520,26); FPath.Anchors:=[akLeft,akTop,akRight];
  FPath.ReadOnly:=True; FPath.Text:=BookCachePath;
  LabelAt('',342,22); FUsage:=LabelControl; FUsage.Name:='ReaderCacheUsage';
  LabelAt('',368,44); FError:=LabelControl; FError.Name:='ReaderCacheError';
  FError.Anchors:=[akLeft,akRight,akBottom];
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.Name:='ReaderCacheClear';
  Button.SetBounds(20,430,180,30); Button.Anchors:=[akLeft,akBottom];
  Button.Caption:='Очистить кэш сейчас'; Button.OnClick:=ClearClick;
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.Name:='ReaderCacheApply';
  Button.SetBounds(310,430,110,30); Button.Anchors:=[akRight,akBottom];
  Button.Caption:='Сохранить'; Button.Default:=True; Button.OnClick:=ApplyClick;
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.Name:='ReaderCacheCancel';
  Button.SetBounds(430,430,110,30); Button.Anchors:=[akRight,akBottom];
  Button.Caption:='Отмена'; Button.Cancel:=True; Button.ModalResult:=mrCancel;
  PolicyChanged(nil); UpdateUsage(nil); ApplyMHLControlTheme(Self);
  FTimer:=TTimer.Create(Self); FTimer.Interval:=1000; FTimer.OnTimer:=UpdateUsage;
end;

procedure TfrmReaderCacheSettings.PolicyChanged(Sender: TObject);
begin
  FDays.Enabled:=FPolicy.ItemIndex<>0;
  FLimit.Enabled:=FPolicy.ItemIndex<>1; FUnit.Enabled:=FLimit.Enabled;
  if Assigned(FError) then FError.Caption:='';
end;

procedure TfrmReaderCacheSettings.UpdateUsage(Sender: TObject);
begin
  FUsage.Caption:='Занято: '+BookCacheSizeText(BookCacheUsage);
  if not BookCacheIndexReady then FUsage.Caption:=FUsage.Caption+' · подсчёт…';
end;

procedure TfrmReaderCacheSettings.ClearClick(Sender: TObject);
begin
  try ClearBookCache; FError.Caption:='Кэш очищен. Открытые файлы сохранятся до их закрытия.'; UpdateUsage(nil);
  except on E: Exception do begin LogDiagnosticError('reader-cache-clear',E); FError.Caption:=E.Message; end; end;
end;

procedure TfrmReaderCacheSettings.ApplyClick(Sender: TObject);
var Days, LimitMB: Integer; Limit: Double; Format: TFormatSettings;
begin
  FError.Caption:=''; Days:=Settings.BookCacheKeepDays; LimitMB:=Settings.BookCacheLimitMB;
  if FDays.Enabled and (not TryStrToInt(Trim(FDays.Text),Days) or (Days<1) or (Days>3650)) then
  begin FError.Caption:='Укажите срок от 1 до 3650 дней.'; if FDays.CanFocus then FDays.SetFocus; Exit; end;
  if FLimit.Enabled then
  begin
    Format:=TFormatSettings.Invariant;
    if not TryStrToFloat(Trim(FLimit.Text).Replace(',','.'),Limit,Format) or
      IsNan(Limit) or IsInfinite(Limit) or (Limit<=0) or
      ((FUnit.ItemIndex=1) and (Limit>1024)) or ((FUnit.ItemIndex=0) and (Limit>1048576)) then
    begin FError.Caption:='Укажите объём от 1 МБ до 1024 ГБ.'; if FLimit.CanFocus then FLimit.SetFocus; Exit; end;
    if FUnit.ItemIndex=1 then Limit:=Limit*1024;
    LimitMB:=Round(Limit);
    if LimitMB<1 then begin FError.Caption:='Минимальный объём — 1 МБ.'; if FLimit.CanFocus then FLimit.SetFocus; Exit; end;
  end;
  try
    Settings.BookCachePolicy:=TBookCachePolicy(FPolicy.ItemIndex);
    Settings.BookCacheKeepDays:=Days; Settings.BookCacheLimitMB:=LimitMB;
    Settings.ClearBookCacheOnExit:=FExit.Checked; Settings.SaveSettings;
    ScheduleBookCacheMaintenance; ModalResult:=mrOk;
  except on E: Exception do begin LogDiagnosticError('reader-cache-settings',E); FError.Caption:=E.Message; end; end;
end;

procedure ConfigureReaderCache;
var Dialog: TfrmReaderCacheSettings;
begin
  Dialog:=TfrmReaderCacheSettings.Create(Application);
  try Dialog.ShowModal; finally Dialog.Free; end;
end;

end.
