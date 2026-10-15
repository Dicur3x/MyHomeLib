// The real Shell picker is inspected through Computer Use; only its test folder
// may be selected. The timer observes style state without operating the window.
type
  TNativeFolderHookProbe = class
    Ticks: Integer;
    PartialSkinObserved: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TNativeFolderHookProbe.Tick(Sender: TObject);
begin
  Inc(Ticks);
  if shDialogs in TStyleManager.SystemHooks then PartialSkinObserved := True;
end;

procedure TestNativeFolderPicker;
var
  Probe: TNativeFolderHookProbe;
  Timer: TTimer;
  Folder, Expected, Caption: string;
  Item: IShellItem;
  Selected, ShouldSelect: Boolean;
  OwnerForm: TForm;
begin
  var COMResult := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  Require(Succeeded(COMResult), 'Native folder fixture requires an STA COM apartment');
  var OriginalHooks := TStyleManager.SystemHooks;
  var OriginalDark := MHLThemeDark;
  Probe := TNativeFolderHookProbe.Create;
  Timer := TTimer.Create(nil);
  try
    Timer.Enabled := False;
    Timer.Interval := 25;
    Timer.OnTimer := Probe.Tick;
    Expected := Settings.AppPath + 'Назначение экспорта ё';
    ForceDirectories(Expected);
    for var Index := 0 to 3 do
    begin
      TStyleManager.SystemHooks := OriginalHooks + [shDialogs];
      SetMHLTheme(Index mod 2 = 0);
      Application.ProcessMessages;
      var Before := TStyleManager.SystemHooks;
      Folder := Expected;
      ShouldSelect := (Index = 1) or (Index = 2);
      Caption := 'Проверка папки ' + IntToStr(Index + 1) + '/4 — ';
      if ShouldSelect then Caption := Caption + 'выберите текущую папку'
      else Caption := Caption + 'нажмите Отмена';
      Probe.Ticks := 0;
      Probe.PartialSkinObserved := False;
      var COMDialog: IFileOpenDialog;
      var HR := CoCreateInstance(CLSID_FileOpenDialog, nil, CLSCTX_INPROC_SERVER, IFileOpenDialog, COMDialog);
      Require(Succeeded(HR), 'Cannot create native folder dialog: ' + IntToHex(HR, 8));
      COMDialog := nil;
      Writeln('VISUAL ', Caption);
      Flush(Output);
      OwnerForm := TForm.Create(nil);
      try
        OwnerForm.Caption := 'Native folder picker isolated test';
        OwnerForm.Show;
        Application.ProcessMessages;
        Require(IsWindow(OwnerForm.Handle), 'Native picker owner handle is invalid');
        Probe.Ticks := 0;
        Timer.Enabled := True;
        if Index < 2 then
          Selected := GetFolderShellItem(OwnerForm.Handle, Caption, Folder, Item)
        else
          Selected := GetFolderName(OwnerForm.Handle, Caption, Folder);
      finally
        Timer.Enabled := False;
        OwnerForm.Free;
      end;
      Require(Probe.Ticks > 0, 'Native Shell modal loop was not observed');
      Require(not Probe.PartialSkinObserved, 'VCL skin touched the native folder picker');
      Require(TStyleManager.SystemHooks = Before, 'Native folder picker changed style hooks');
      Require(Selected = ShouldSelect, 'Unexpected selection/cancel outcome');
      Require(SameFileName(Folder, Expected), 'Folder selection/cancel lost the Unicode path');
      if Index < 2 then Require(Assigned(Item) = Selected, 'Shell item lifetime differs from selection');
      Item := nil;
      Writeln('PASS native folder picker case ', Index + 1,
        ' native skin, unchanged hooks, Unicode folder and selection/cancel');
      Flush(Output);
    end;
  finally
    Timer.Free;
    Probe.Free;
    TStyleManager.SystemHooks := OriginalHooks;
    SetMHLTheme(OriginalDark);
    CoUninitialize;
  end;
end;
