// Native caption/layout tests; include after Require is declared.
// Uses already present in CollectionViewsTest: Vcl.Forms/Controls/StdCtrls,
// unit_BookColumnFilters, unit_MHLTheme, VirtualTrees, System.Math/IOUtils,
// Winapi.Windows, Vcl.Imaging.pngimage, frm_main.

// A queued callback can run while a styled form is still being constructed.
// Probe the actual modal instead of assuming Screen.ActiveForm already changed.
type
  TFCTModalProbe = class
  private
    FTimer: TTimer;
    FClassName, FCaption: string;
    FDeadline: UInt64;
    FReady: TProc<TForm>;
    FCompleted: Boolean;
    procedure Tick(Sender: TObject);
  public
    constructor Create(const ExpectedClassName, ExpectedCaption: string;
      const Ready: TProc<TForm>);
    destructor Destroy; override;
    property Completed: Boolean read FCompleted;
  end;

constructor TFCTModalProbe.Create(const ExpectedClassName, ExpectedCaption: string;
  const Ready: TProc<TForm>);
begin
  inherited Create;
  FClassName := ExpectedClassName; FCaption := ExpectedCaption; FReady := Ready;
  FDeadline := GetTickCount64 + 5000;
  FTimer := TTimer.Create(nil); FTimer.Enabled := False;
  FTimer.Interval := 10; FTimer.OnTimer := Tick; FTimer.Enabled := True;
end;

destructor TFCTModalProbe.Destroy;
begin
  FTimer.Free; FReady := nil;
  inherited;
end;

procedure TFCTModalProbe.Tick(Sender: TObject);
var
  Popup: TForm;
  Ready: TProc<TForm>;
  Details: string;
begin
  for var Index := Screen.FormCount - 1 downto 0 do
  begin
    Popup := Screen.Forms[Index];
    if (Popup.ClassName = FClassName) and (string(Popup.Caption) = FCaption) and
      Popup.Visible and Popup.HandleAllocated and (fsModal in Popup.FormState) and
      not (fsCreating in Popup.FormState) and not (fsShowing in Popup.FormState) and
      IsWindowVisible(Popup.Handle) then
    begin
      FTimer.Enabled := False; Ready := FReady; FReady := nil;
      Writeln('PROFILE modal ready class=', Popup.ClassName, ' caption=', Popup.Caption,
        ' visible=', Ord(Popup.Visible), ' modal=', Ord(fsModal in Popup.FormState)); Flush(Output);
      Ready(Popup); FCompleted := True;
      Exit;
    end;
  end;
  if GetTickCount64 < FDeadline then Exit;
  FTimer.Enabled := False;
  Details := '';
  if Assigned(Screen.ActiveForm) then
    Details := ' active=' + Screen.ActiveForm.ClassName + ':' + string(Screen.ActiveForm.Caption);
  for var Index := 0 to Screen.FormCount - 1 do
  begin
    Popup := Screen.Forms[Index];
    Details := Details + Format(' [%s:%s visible=%d modal=%d]',
      [Popup.ClassName, string(Popup.Caption), Ord(Popup.Visible), Ord(fsModal in Popup.FormState)]);
  end;
  Require(False, 'Expected actual visible modal ' + FClassName + ':' + FCaption + Details);
end;

function FCTCheckedSignature(Tree: TCustomVirtualStringTree): string;
var Node: PVirtualNode;
begin
  Result := ''; Node := Tree.GetFirst;
  while Assigned(Node) do
  begin
    Tree.ValidateNode(Node, False);
    Result := Result + IntToStr(Node.Index) + ':' + IntToStr(Ord(Node.CheckState)) + ';';
    Node := Tree.GetNext(Node);
  end;
end;

procedure FCTCheckFilterControls(Popup: TForm; DPI: Integer);
var
  Button, Select, Clear, Reset, Apply, Cancel: TButton;
  LabelControl: TLabel;
  Bounds, Intersection: TRect;
  MinimumTextWidth: Integer;
begin
  Select := Popup.FindComponent('SelectFoundButton') as TButton;
  Clear := Popup.FindComponent('ClearSelectionButton') as TButton;
  Reset := Popup.FindComponent('ResetFilterButton') as TButton;
  Apply := Popup.FindComponent('ApplyFilterButton') as TButton;
  Cancel := Popup.FindComponent('CancelFilterButton') as TButton;
  Require(Assigned(Select) and Assigned(Clear) and Assigned(Reset) and
    Assigned(Apply) and Assigned(Cancel), 'List filter lacks its named actions');
  for var Component in Popup do
    if Component is TPanel then
      Require(TPanel(Component).Caption='', 'Filter exposes a layout component name: '+Component.Name);
  Writeln('PROFILE filter layout requested_dpi=', DPI, ' current_ppi=', Popup.CurrentPPI,
    ' form_ppi=', Popup.PixelsPerInch, ' client=', Popup.ClientWidth, 'x', Popup.ClientHeight,
    ' select=', Select.Left, ',', Select.Top, ',', Select.Width, ',', Select.Height,
    ' clear=', Clear.Left, ',', Clear.Top, ',', Clear.Width, ',', Clear.Height,
    ' actual_gap=', Clear.Left - Select.Left - Select.Width); Flush(Output);
  Require(Select.Width > Clear.Width, 'Long Select found action has no extra width');
  Require(Clear.Left >= Select.Left + Select.Width + MulDiv(8, DPI, 96),
    Format('Select found and Clear overlap or have no separation at %d DPI: current=%d, gap=%d, required=%d',
      [DPI, Popup.CurrentPPI, Clear.Left - Select.Left - Select.Width, MulDiv(8, DPI, 96)]));
  Require(Clear.Left + Clear.Width <= Clear.Parent.ClientWidth - MulDiv(10, DPI, 96),
    'Clear extends beyond the right margin');
  Require(Apply.Left >= Reset.Left + Reset.Width + MulDiv(8, DPI, 96),
    'Reset and Apply footer actions overlap');
  Require(Cancel.Left >= Apply.Left + Apply.Width + MulDiv(8, DPI, 96),
    'Apply and Cancel footer actions overlap');
  for var Component in Popup do
    if Component is TButton then
    begin
      Button := TButton(Component);
      Require(Button.Visible and Button.Enabled, 'Filter action is invisible/disabled: ' + Button.Caption);
      Require((Button.Left >= 0) and (Button.Top >= 0) and
        (Button.Left + Button.Width <= Button.Parent.ClientWidth) and
        (Button.Top + Button.Height <= Button.Parent.ClientHeight),
        'Filter action is outside its parent at ' + IntToStr(DPI) + ': ' + Button.Caption);
      Popup.Canvas.Font.Assign(Button.Font);
      MinimumTextWidth := Popup.Canvas.TextWidth(Button.Caption) + MulDiv(16, DPI, 96);
      Require(MinimumTextWidth <= Button.Width,
        Format('Filter caption is clipped at %d DPI: %s; needs %d, has %d',
          [DPI, string(Button.Caption), MinimumTextWidth, Button.Width]));
      Require(Popup.Canvas.TextHeight('ЙдAg') + MulDiv(8, DPI, 96) <= Button.Height,
        'Filter action text is vertically clipped: ' + Button.Caption);
    end
    else if Component is TLabel then
    begin
      LabelControl := TLabel(Component);
      Require((LabelControl.Left >= 0) and (LabelControl.Top >= 0) and
        (LabelControl.Left + LabelControl.Width <= LabelControl.Parent.ClientWidth) and
        (LabelControl.Top + LabelControl.Height <= LabelControl.Parent.ClientHeight),
        'Filter explanation is outside its parent: ' + LabelControl.Name);
      Popup.Canvas.Font.Assign(LabelControl.Font);
      Bounds := Rect(0, 0, LabelControl.Width, 0);
      DrawText(Popup.Canvas.Handle, PChar(LabelControl.Caption), Length(LabelControl.Caption),
        Bounds, DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      Require(Bounds.Height <= LabelControl.Height,
        'Filter explanation is vertically clipped: ' + LabelControl.Name);
    end;
  Require(not IntersectRect(Intersection, Select.BoundsRect, Clear.BoundsRect),
    'Filter selection buttons intersect');
end;

procedure TestFilterCaptionLayout(Tree: TBookTree);
var
  Filters: TBookColumnFilters;
  Probe: TFCTModalProbe;
  PreviousValue, OriginalChecks, Artifacts: string;
  PreviousSensitive, OriginalTheme: Boolean;
  Started: UInt64;
begin
  Started:=GetTickCount64;
  Writeln('TRACE filter caption suite started tick_ms=', Started); Flush(Output);
  Require(Assigned(Tree), 'Filter caption test requires a populated book tree');
  Require(Tree.TotalCount > 0, 'Filter caption fixture tree is empty');
  Require(SameText(ExtractFileDrive(Settings.AppPath), 'G:'),
    'Filter caption artifacts must run on G');
  Artifacts := TPath.Combine(Settings.AppPath, 'filter-caption-artifacts');
  ForceDirectories(Artifacts);
  Filters := TBookColumnFilters.ForTree(Tree);
  PreviousValue := Filters.Value(COL_TYPE);
  PreviousSensitive := Filters.CaseSensitive(COL_TYPE);
  OriginalChecks := FCTCheckedSignature(Tree);
  OriginalTheme := MHLThemeDark;
  try
    for var Dark in TArray<Boolean>.Create(False, True) do
    begin
      SetMHLTheme(Dark);
      Probe := TFCTModalProbe.Create('TListFilterEditor', 'Фильтр: Тип',
        procedure(Popup: TForm)
        var
          Values: TVirtualStringTree;
          Select, Clear: TButton;
          SelectionAfterClick: string;
          OriginalFontSize: Integer;
          Bitmap: TBitmap;
          Png: TPngImage;
          Node: PVirtualNode;
        begin
          Require((Popup.ClassName = 'TListFilterEditor') and
            (string(Popup.Caption) = 'Фильтр: Тип'),
            'Expected the actual native list filter popup');
          Values := Popup.FindComponent('FilterOptionList') as TVirtualStringTree;
          Select := Popup.FindComponent('SelectFoundButton') as TButton;
          Clear := Popup.FindComponent('ClearSelectionButton') as TButton;
          Require(Assigned(Values) and (Values.TotalCount > 0) and
            Assigned(Select) and Assigned(Clear), 'Native filter options/actions are absent');
          Select.Click;
          Node := Values.GetFirst;
          while Assigned(Node) do
          begin
            Values.ValidateNode(Node, False);
            Require(Node.CheckState = csCheckedNormal, 'Select found no longer checks its found values');
            Node := Values.GetNext(Node);
          end;
          SelectionAfterClick := FCTCheckedSignature(Values);
          for var DPI in TArray<Integer>.Create(96, 144, 192) do
          begin
            Popup.ScaleForPPI(DPI);
            Popup.ClientWidth := MulDiv(420, DPI, 96);
            Popup.ClientHeight := MulDiv(440, DPI, 96);
            FCTCheckFilterControls(Popup, DPI);
            Require(FCTCheckedSignature(Values) = SelectionAfterClick,
              'DPI layout changed checked filter values');
            Popup.Width := Popup.Constraints.MinWidth;
            FCTCheckFilterControls(Popup, DPI);
            Require(FCTCheckedSignature(Values) = SelectionAfterClick,
              'Minimum window size changed checked filter values');
            Popup.ClientWidth := Popup.ClientWidth + MulDiv(200, DPI, 96);
            FCTCheckFilterControls(Popup, DPI);
            Require(FCTCheckedSignature(Values) = SelectionAfterClick,
              'Resizing changed checked filter values');
            OriginalFontSize := Popup.Font.Size;
            Popup.Font.Size := OriginalFontSize + 2;
            Popup.ClientWidth := Popup.ClientWidth + 1;
            FCTCheckFilterControls(Popup, DPI);
            Popup.Width := Popup.Constraints.MinWidth;
            FCTCheckFilterControls(Popup, DPI);
            Popup.Font.Size := OriginalFontSize;
            Popup.ClientWidth := MulDiv(420, DPI, 96);
            Popup.ClientHeight := MulDiv(440, DPI, 96);
            FCTCheckFilterControls(Popup, DPI);
            Require(FCTCheckedSignature(Values) = SelectionAfterClick,
              'Font-aware layout changed checked filter values');
            Bitmap := Popup.GetFormImage; Png := TPngImage.Create;
            try
              Png.Assign(Bitmap);
              Png.SaveToFile(TPath.Combine(Artifacts,
                Format('filter-dark-%d-dpi-%d.png', [Ord(Dark), DPI])));
            finally Png.Free; Bitmap.Free; end;
            Writeln('PASS filter captions dark=', Ord(Dark), ' dpi=', DPI,
              ' select_width=', Select.Width, ' clear_width=', Clear.Width,
              ' minimum_width=', Popup.Constraints.MinWidth);
          end;
          Clear.Click;
          Node := Values.GetFirst;
          while Assigned(Node) do
          begin
            Values.ValidateNode(Node, False);
            Require(Node.CheckState = csUncheckedNormal, 'Clear no longer removes checked filter values');
            Node := Values.GetNext(Node);
          end;
          Popup.ModalResult := mrCancel;
        end);
      try
        Require(not EditBookColumnFilter(Tree, COL_TYPE), 'Caption test unexpectedly applied a filter');
        Require(Probe.Completed, 'Caption modal closed before its strict layout checks ran');
      finally Probe.Free; end;
      Require((Filters.Value(COL_TYPE) = PreviousValue) and
        (Filters.CaseSensitive(COL_TYPE) = PreviousSensitive), 'Cancelling the caption test changed the filter');
      Require(FCTCheckedSignature(Tree) = OriginalChecks,
        'Filter caption geometry or Select found changed the book-tree checks');
    end;
  finally SetMHLTheme(OriginalTheme); end;
  Writeln('PASS caption font measurements, resized minimums, 100/150/200 percent DPI and both themes preserve filter selection semantics elapsed_ms=', GetTickCount64-Started); Flush(Output);
end;

procedure TestAnnotationCaptionLayout(ThemeIndex: Integer = -1);
var
  OriginalTheme, OriginalCollapsed: Boolean;
  OriginalDPI, OriginalWidth, OriginalHeight: Integer;
  RestoreStarted, AnnotationStarted: UInt64;

  procedure TraceStage(const Stage: string);
  begin
    Writeln('TRACE annotation stage ', Stage, ' elapsed_ms=', GetTickCount64-AnnotationStarted,
      ' tick_ms=', GetTickCount64); Flush(Output);
  end;

  procedure TraceRestore(const Stage: string);
  begin
    Writeln('TRACE annotation restore ', Stage, ' elapsed_ms=', GetTickCount64 - RestoreStarted,
      ' original_ppi=', OriginalDPI, ' original_width=', OriginalWidth, ' original_height=', OriginalHeight,
      ' current_ppi=', frmMain.CurrentPPI, ' font_ppi=', frmMain.Font.PixelsPerInch,
      ' width=', frmMain.Width, ' height=', frmMain.Height,
      ' category_height=', frmMain.ctpBook.Height, ' collapsed=', Ord(frmMain.ctpBook.Collapsed));
    Flush(Output);
  end;

  procedure CheckLayout(Dark: Boolean; DPI: Integer; const State: string);
  var LabelControl: TLabel; Surface: TWinControl; Bounds: TRect; CheckStarted: UInt64;

    procedure TraceCheck(const Stage: string);
    begin
      Writeln('TRACE annotation check ', State, ' dark=', Ord(Dark), ' dpi=', DPI,
        ' stage=', Stage, ' elapsed_ms=', GetTickCount64-CheckStarted,
        ' annotation_elapsed_ms=', GetTickCount64-AnnotationStarted); Flush(Output);
    end;

  begin
    CheckStarted:=GetTickCount64;
    LabelControl := frmMain.Label7; Surface := LabelControl.Parent;
    TraceCheck('before-realign');
    Surface.Realign;
    TraceCheck('after-realign');
    Writeln('TRACE annotation ', State, ' dark=', Ord(Dark), ' dpi=', DPI,
      ' form_current_ppi=', frmMain.CurrentPPI, ' form_font_ppi=', frmMain.Font.PixelsPerInch,
      ' category_height=', frmMain.ctpBook.Height,
      ' surface_height=', Surface.Height, ' surface_client_height=', Surface.ClientHeight,
      ' label_top=', LabelControl.Top, ' label_height=', LabelControl.Height,
      ' editor_top=', frmMain.edFAnnotation.Top, ' editor_height=', frmMain.edFAnnotation.Height,
      ' editor_bottom_margin=', frmMain.edFAnnotation.Margins.Bottom,
      ' editor_font_ppi=', frmMain.edFAnnotation.Font.PixelsPerInch);
    Flush(Output);
    TraceCheck('before-flow-assert');
    Require(LabelControl.AutoSize and (LabelControl.Align = alTop) and
      (frmMain.edFAnnotation.Align = alTop), 'Annotation label and editor do not follow the same flow');
    TraceCheck('after-flow-assert-before-font-assign');
    frmMain.Canvas.Font.Assign(LabelControl.Font);
    TraceCheck('after-font-assign');
    Bounds := Rect(0, 0, LabelControl.Width, 0);
    TraceCheck('before-drawtext');
    DrawText(frmMain.Canvas.Handle, PChar(LabelControl.Caption), Length(LabelControl.Caption),
      Bounds, DT_CALCRECT or DT_NOPREFIX);
    TraceCheck('after-drawtext');
    Writeln('TRACE annotation measured bounds=', Bounds.Width, 'x', Bounds.Height,
      ' label=', LabelControl.Width, 'x', LabelControl.Height); Flush(Output);
    TraceCheck('before-caption-assert');
    Require((Bounds.Width <= LabelControl.Width) and (Bounds.Height <= LabelControl.Height),
      'Annotation caption text is clipped at ' + IntToStr(DPI));
    TraceCheck('after-caption-assert-before-keyword-assert');
    Require(frmMain.edFKeyWords.Top + frmMain.edFKeyWords.Height <= LabelControl.Top,
      'Annotation caption overlaps the preceding keywords field');
    TraceCheck('after-keyword-assert-before-editor-overlap-assert');
    Require(LabelControl.Top + LabelControl.Height <= frmMain.edFAnnotation.Top,
      'Annotation caption overlaps its editor');
    TraceCheck('after-editor-overlap-assert-before-editor-bounds-assert');
    Require(frmMain.edFAnnotation.Top + frmMain.edFAnnotation.Height +
      frmMain.edFAnnotation.Margins.Bottom <= Surface.ClientHeight,
      'Annotation editor is outside the book search category');
    TraceCheck('after-editor-bounds-assert');
    Writeln('PASS annotation caption ', State, ' dark=', Ord(Dark), ' dpi=', DPI,
      ' category_height=', frmMain.ctpBook.Height,
      ' surface_height=', Surface.Height,
      ' actual_header_frame=', frmMain.ctpBook.Height - Surface.Height,
      ' last_bottom=', frmMain.edFAnnotation.Top + frmMain.edFAnnotation.Height +
        frmMain.edFAnnotation.Margins.Bottom); Flush(Output);
    TraceCheck('after-pass');
  end;

begin
  AnnotationStarted:=GetTickCount64;
  TraceStage('suite-start');
  Require((ThemeIndex >= -1) and (ThemeIndex <= 1),
    'Annotation caption theme index must be -1, 0 or 1');
  Require(Assigned(frmMain), 'Annotation caption test requires the native main form');
  OriginalTheme := MHLThemeDark; OriginalDPI := frmMain.Font.PixelsPerInch;
  if OriginalDPI <= 0 then OriginalDPI := frmMain.CurrentPPI;
  OriginalWidth := frmMain.Width; OriginalHeight := frmMain.Height;
  OriginalCollapsed := frmMain.ctpBook.Collapsed;
  try
    frmMain.ctpBook.Collapsed := False;
    for var Dark in TArray<Boolean>.Create(False, True) do
    begin
      if (ThemeIndex >= 0) and (Ord(Dark) <> ThemeIndex) then Continue;
      TraceStage('before-theme-dark-'+IntToStr(Ord(Dark)));
      SetMHLTheme(Dark);
      TraceStage('after-theme-dark-'+IntToStr(Ord(Dark)));
      for var DPI in TArray<Integer>.Create(96, 144, 192) do
      begin
        TraceStage('before-expanded-scale-dark-'+IntToStr(Ord(Dark))+'-dpi-'+IntToStr(DPI));
        frmMain.ScaleForPPI(DPI);
        TraceStage('after-expanded-scale-dark-'+IntToStr(Ord(Dark))+'-dpi-'+IntToStr(DPI));
        CheckLayout(Dark, DPI, 'expanded');
      end;
      TraceStage('before-collapse-dark-'+IntToStr(Ord(Dark)));
      frmMain.ctpBook.Collapsed := True;
      TraceStage('after-collapse-dark-'+IntToStr(Ord(Dark)));
      for var DPI in TArray<Integer>.Create(96, 144, 192) do
      begin
        TraceStage('before-collapsed-scale-dark-'+IntToStr(Ord(Dark))+'-dpi-'+IntToStr(DPI));
        frmMain.ScaleForPPI(DPI);
        TraceStage('after-collapsed-scale-dark-'+IntToStr(Ord(Dark))+'-dpi-'+IntToStr(DPI));
        Require(frmMain.ctpBook.Collapsed, 'DPI layout reopened a user-collapsed search category');
      end;
      TraceStage('before-reexpand-dark-'+IntToStr(Ord(Dark)));
      frmMain.ctpBook.Collapsed := False;
      TraceStage('after-reexpand-dark-'+IntToStr(Ord(Dark)));
      CheckLayout(Dark, 192, 'reexpanded');
    end;
  finally
    RestoreStarted := GetTickCount64;
    TraceRestore('before-scale');
    frmMain.ScaleForPPI(OriginalDPI);
    TraceRestore('after-scale');
    frmMain.Width := OriginalWidth;
    TraceRestore('after-width');
    frmMain.Height := OriginalHeight;
    TraceRestore('after-height');
    frmMain.ctpBook.Collapsed := OriginalCollapsed;
    TraceRestore('after-collapsed');
    SetMHLTheme(OriginalTheme);
    TraceRestore('after-theme');
    Require(frmMain.Font.PixelsPerInch = OriginalDPI,
      'Annotation caption test did not restore its original font DPI');
    Require((frmMain.Width = OriginalWidth) and (frmMain.Height = OriginalHeight),
      'Annotation caption test did not restore its original window dimensions');
    Require(frmMain.ctpBook.Collapsed = OriginalCollapsed,
      'Annotation caption test did not restore the user category state');
    Require(MHLThemeDark = OriginalTheme,
      'Annotation caption test did not restore its original theme');
    TraceRestore('strict-restoration-verified');
  end;
  Writeln('PASS annotation caption complete theme=', ThemeIndex); Flush(Output);
  Writeln('TRACE annotation test completed'); Flush(Output);
end;
