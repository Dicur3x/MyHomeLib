unit frm_ExportToDeviceProgressForm;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, frm_ImportProgressForm, StdCtrls, ComCtrls, Menus, unit_Globals;

type
  TExportToDeviceProgressForm = class(TImportProgressForm)
  private const
    MaxVisibleLogLines = 200;
    MaxVisibleLogCharacters = 24000;
  private
    FConversionLog: TMemo;
    FVisibleLog: TStringList;
    FVisibleLogCharacters: Integer;
    FCopySelection: TMenuItem;
    FLogWasTruncated: Boolean;
    FWorkerStarted: Boolean;
    procedure CopyConversionLog(Sender: TObject);
    procedure ConversionLogMenuPopup(Sender: TObject);
    procedure ConversionLogKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure CheckExportClose(Sender: TObject; var CanClose: Boolean);
    procedure CancelExport(Sender: TObject);
  protected
    procedure DoCreate; override;
    procedure StartWorker; override;
    procedure ShowTeletype(const Msg: string; Severity: TTeletypeSeverity); override;
  public
    destructor Destroy; override;
  end;

var
  ExportToDeviceProgressForm: TExportToDeviceProgressForm;

implementation

uses
  Clipbrd, unit_MHLTheme;

{$R *.dfm}

procedure TExportToDeviceProgressForm.DoCreate;
begin
  inherited;
  // Geometry-only previews can exist before a worker is assigned. The base
  // progress form assumes a worker in these two event handlers.
  OnCloseQuery := CheckExportClose;
  btnCancel.OnClick := CancelExport;
  ApplyMHLControlTheme(Self);
end;

destructor TExportToDeviceProgressForm.Destroy;
var I: Integer;
begin
  // Join while controls and the log still exist, then remove only callbacks
  // owned by this form. The caller retains and frees the completed worker.
  if Assigned(WorkerThread) then
  begin
    if FWorkerStarted or WorkerThread.Finished then WorkerThread.WaitFor;
    if TMethod(WorkerThread.OnOpenProgress).Data = Self then WorkerThread.OnOpenProgress := nil;
    if TMethod(WorkerThread.OnProgressHint).Data = Self then WorkerThread.OnProgressHint := nil;
    if TMethod(WorkerThread.OnProgress).Data = Self then WorkerThread.OnProgress := nil;
    if TMethod(WorkerThread.OnCloseProgress).Data = Self then WorkerThread.OnCloseProgress := nil;
    if TMethod(WorkerThread.OnTeletype).Data = Self then WorkerThread.OnTeletype := nil;
    if TMethod(WorkerThread.OnSetComment).Data = Self then WorkerThread.OnSetComment := nil;
    if TMethod(WorkerThread.OnShowMessage).Data = Self then WorkerThread.OnShowMessage := nil;
    // An assigned but never started worker remains the caller's responsibility;
    // the base destructor must not wait forever on its suspended thread.
    WorkerThread := nil;
  end;
  if Assigned(FConversionLog) then
  begin
    FConversionLog.OnKeyDown := nil;
    if Assigned(FConversionLog.PopupMenu) then
    begin
      FConversionLog.PopupMenu.OnPopup := nil;
      for I := 0 to FConversionLog.PopupMenu.Items.Count - 1 do
        FConversionLog.PopupMenu.Items[I].OnClick := nil;
    end;
  end;
  try
    FreeAndNil(FVisibleLog);
  finally
    inherited;
  end;
end;

procedure TExportToDeviceProgressForm.StartWorker;
begin
  inherited;
  FWorkerStarted := Assigned(WorkerThread);
end;

procedure TExportToDeviceProgressForm.CheckExportClose(Sender: TObject;
  var CanClose: Boolean);
begin
  if not Assigned(WorkerThread) then CanClose := True
  else FormCloseQuery(Sender, CanClose);
end;

procedure TExportToDeviceProgressForm.CancelExport(Sender: TObject);
begin
  if Assigned(WorkerThread) then btnCancelClick(Sender);
end;

procedure TExportToDeviceProgressForm.CopyConversionLog(Sender: TObject);
var Text: string;
begin
  if not Assigned(FConversionLog) then Exit;
  if (Sender is TMenuItem) and (TMenuItem(Sender).Tag = 1) then
    Text := FConversionLog.Text
  else
  begin
    if FConversionLog.SelLength=0 then Exit;
    Text := FConversionLog.SelText;
  end;
  // WM_COPY can silently do nothing while another application briefly owns
  // the clipboard. Publish the selected Unicode text explicitly, with a
  // short bounded retry; never replace a failed selection with the full log.
  for var Attempt:=0 to 19 do
    try Clipboard.AsText:=Text; Exit;
    except on E: EClipboardException do
      if Attempt=19 then raise else Sleep(10);
    end;
end;

procedure TExportToDeviceProgressForm.ConversionLogMenuPopup(Sender: TObject);
begin
  FCopySelection.Enabled := Assigned(FConversionLog) and
    (FConversionLog.SelLength > 0);
end;

procedure TExportToDeviceProgressForm.ConversionLogKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  if not (ssCtrl in Shift) or not Assigned(FConversionLog) then Exit;
  if Key = Ord('A') then
  begin
    FConversionLog.SelectAll;
    Key := 0;
  end
  else if Key = Ord('C') then
  begin
    CopyConversionLog(nil);
    Key := 0;
  end;
end;

procedure TExportToDeviceProgressForm.ShowTeletype(const Msg: string;
  Severity: TTeletypeSeverity);
var
  Margin, ExtraHeight, OriginalHeight, LogTop, I, FirstLine, LayoutPPI: Integer;
  Menu: TPopupMenu;
  Item: TMenuItem;
  Incoming: TStringList;
  Preview: string;
begin
  if not Assigned(FConversionLog) then
  begin
    // ScaleForPPI can scale the font/children before a hidden form's CurrentPPI
    // follows them. Size the new area in the same pixels as its existing UI.
    LayoutPPI := Font.PixelsPerInch;
    if LayoutPPI <= 0 then LayoutPPI := CurrentPPI;
    if LayoutPPI <= 0 then LayoutPPI := 96;
    Margin := MulDiv(10, LayoutPPI, 96);
    ExtraHeight := MulDiv(160, LayoutPPI, 96);
    OriginalHeight := ClientHeight;
    ClientHeight := OriginalHeight + ExtraHeight;
    // The inherited Cancel button is anchored to the bottom. Keep the log
    // above it after the dialog grows rather than covering the button.
    btnCancel.Top := ClientHeight - Margin - btnCancel.Height;
    btnCancel.Left := ClientWidth - Margin - btnCancel.Width;
    LogTop := ProgressBar.Top + ProgressBar.Height + Margin;
    FConversionLog := TMemo.Create(Self);
    FConversionLog.Name := 'ConversionNotes';
    FConversionLog.Parent := Self;
    FConversionLog.SetBounds(Margin, LogTop, ClientWidth - 2 * Margin,
      btnCancel.Top - Margin - LogTop);
    FConversionLog.Anchors := [akLeft, akTop, akRight, akBottom];
    FConversionLog.ReadOnly := True;
    // Native memo Lines.Count includes soft wraps. Keep one warning line as
    // one displayed row so the bound is independent of DPI and window width.
    FConversionLog.WordWrap := False;
    FConversionLog.ScrollBars := ssBoth;
    FConversionLog.HideSelection := False;
    FConversionLog.TabStop := True;
    FConversionLog.TabOrder := 1;
    btnCancel.TabOrder := 2;
    FConversionLog.OnKeyDown := ConversionLogKeyDown;
    FConversionLog.StyleElements := FConversionLog.StyleElements - [seFont, seClient];
    FVisibleLog := TStringList.Create;
    FVisibleLog.Add('Примечания к конвертации');
    FVisibleLogCharacters := Length(FVisibleLog[0]) + Length(sLineBreak);
    Menu := TPopupMenu.Create(Self);
    Menu.Name := 'ConversionNotesMenu';
    Menu.OnPopup := ConversionLogMenuPopup;
    FCopySelection := TMenuItem.Create(Menu);
    FCopySelection.Caption := 'Копировать выделенное';
    FCopySelection.OnClick := CopyConversionLog;
    Menu.Items.Add(FCopySelection);
    Item := TMenuItem.Create(Menu);
    Item.Caption := 'Копировать всё';
    Item.Tag := 1;
    Item.OnClick := CopyConversionLog;
    Menu.Items.Add(Item);
    FConversionLog.PopupMenu := Menu;
    ApplyMHLControlTheme(Self);
  end;

  Incoming := TStringList.Create;
  try
    // Limit the preview before handing it to the native memo. The complete
    // report remains in the export log; long batches must not slow the UI.
    Incoming.Text := Copy(Msg, 1, MaxVisibleLogCharacters - 256);
    FLogWasTruncated := FLogWasTruncated or
      (Length(Msg) > MaxVisibleLogCharacters - 256);
    FirstLine := 0;
    if Incoming.Count >= MaxVisibleLogLines then
    begin
      FirstLine := Incoming.Count - MaxVisibleLogLines + 1;
      FLogWasTruncated := True;
    end;
    // Native memo line reads/deletes retrieve and shift its entire window text.
    // Do all truncation in a bounded list, then send one text update per warning.
    for I := FirstLine to Incoming.Count - 1 do
    begin
      FVisibleLog.Add(Incoming[I]);
      Inc(FVisibleLogCharacters, Length(Incoming[I]) + Length(sLineBreak));
    end;
    while (FVisibleLog.Count > MaxVisibleLogLines) or
      ((FVisibleLogCharacters > MaxVisibleLogCharacters - 128) and
      (FVisibleLog.Count > 2)) do
    begin
      Dec(FVisibleLogCharacters, Length(FVisibleLog[1]) + Length(sLineBreak));
      FVisibleLog.Delete(1);
      FLogWasTruncated := True;
    end;
    if FLogWasTruncated then
    begin
      Dec(FVisibleLogCharacters, Length(FVisibleLog[0]));
      FVisibleLog[0] :=
        'Последние примечания. Полный отчёт сохранён в журнале экспорта.';
      Inc(FVisibleLogCharacters, Length(FVisibleLog[0]));
    end;
    FConversionLog.Lines.BeginUpdate;
    try
      Preview := FVisibleLog.Text;
      // TStringList adds a final line break; the native edit would otherwise
      // count one extra empty line beyond the preview's limit.
      while (Length(Preview) > 0) and
        CharInSet(Preview[Length(Preview)], [#13, #10]) do
        SetLength(Preview, Length(Preview) - 1);
      // Bypass TMemoStrings.SetTextStr, which can reintroduce a terminal CRLF.
      FConversionLog.Text := Preview;
    finally
      FConversionLog.Lines.EndUpdate;
    end;
  finally
    Incoming.Free;
  end;
end;

end.
