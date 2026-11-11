type
  TPaletteEditorProbe = class
    Timer:TTimer;
    Accept:Boolean;
    Calls:Integer;
    procedure Tick(Sender:TObject);
    procedure Open(Parent:TfrmSettings; Confirm:Boolean);
  end;

procedure TPaletteEditorProbe.Tick(Sender:TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TInterfaceColorsDialog) and Screen.Forms[I].Visible then
    begin
      Timer.Enabled:=False; Inc(Calls);
      TButton(Screen.Forms[I].FindComponent('PaletteReset')).Click;
      if Accept then Screen.Forms[I].ModalResult:=mrOk else Screen.Forms[I].ModalResult:=mrCancel;
      Exit;
    end;
end;

procedure TPaletteEditorProbe.Open(Parent:TfrmSettings; Confirm:Boolean);
begin
  Accept:=Confirm; Timer.Enabled:=True;
  TButton(Parent.FindComponent('btnInterfaceColors')).Click;
  Require(not Timer.Enabled,'Palette editor was not visited through Settings');
end;

type TPaletteBookTree = class(TBookTree)
  public
    procedure PaintSelected(Node:PVirtualNode; const Target:TCanvas);
  end;

procedure TPaletteBookTree.PaintSelected(Node:PVirtualNode; const Target:TCanvas);
begin DoPaintText(Node,Target,0,ttNormal); end;

procedure TestCataloguePalettes;
var Saved, Values, Loaded: TMHLThemePalettes; OldDark: Boolean;
  Ini: TMemIniFile; Host: TForm; Edit: TEdit; Tree: TPaletteBookTree;
  Dialog: TInterfaceColorsDialog; Box: TComboBox; Bitmap: TBitmap;
  LegacyFont, LegacyLocal, LegacyDeleted: TColor; NodeHeight: Cardinal;
  Preferences:TfrmSettings; Driver:TPaletteEditorProbe;
begin
  RequireIsolatedRegression;
  Saved:=MHLThemePalettes; OldDark:=MHLThemeDark;
  LegacyFont:=Settings.FontColor; LegacyLocal:=Settings.LocalColor; LegacyDeleted:=Settings.DeletedColor;
  Host:=TForm.CreateNew(nil); Ini:=TMemIniFile.Create(''); Bitmap:=TBitmap.Create;
  try
    Values[False]:=EmptyMHLThemePalette; Values[True]:=EmptyMHLThemePalette;
    Values[False].Colors[prWindow]:=RGB(242,235,222);
    Values[False].Colors[prField]:=RGB(250,246,238);
    Values[False].Colors[prText]:=RGB(45,37,61);
    Values[False].Colors[prLink]:=RGB(108,48,126);
    Values[False].Colors[prSelection]:=RGB(80,48,99);
    Values[False].Colors[prSelectionText]:=RGB(255,250,244);
    Values[True].Colors[prWindow]:=RGB(28,36,36);
    Values[True].Colors[prField]:=RGB(20,28,28);
    Values[True].Colors[prText]:=RGB(222,234,224);
    Values[True].Colors[prLink]:=RGB(146,211,177);
    Values[True].Colors[prSelection]:=RGB(51,90,77);
    Values[True].Colors[prSelectionText]:=RGB(250,255,250);
    SetMHLThemePalettes(Values); Ini.WriteString('Personal','Keep','Unrelated'); SaveMHLThemePalettes(Ini);
    SetMHLThemePalettes(Saved); LoadMHLThemePalettes(Ini); Loaded:=MHLThemePalettes;
    for var Dark:=False to True do
      for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
        Require(Loaded[Dark].Colors[Role]=Values[Dark].Colors[Role],'Palette persistence changed a colour');
    Require(Ini.ReadString('Personal','Keep','')='Unrelated','Palette storage changed another section');
    Ini.WriteString('InterfaceColors.Light','Link','-2');
    Ini.WriteString('InterfaceColors.Dark','Selection','16777216'); LoadMHLThemePalettes(Ini);
    Loaded:=MHLThemePalettes;
    Require(Loaded[False].Colors[prLink]=clDefault,'Invalid negative colour accepted');
    Require(Loaded[True].Colors[prSelection]=clDefault,'Invalid RGB colour accepted');
    SetMHLThemePalettes(Values);
    Host.SetBounds(0,0,520,320);
    Edit:=TEdit.Create(Host); Edit.Parent:=Host; Edit.SetBounds(10,10,300,26); Edit.Text:='Книга';
    Tree:=TPaletteBookTree.Create(Host); Tree.Parent:=Host; Tree.SetBounds(10,50,400,180);
    Tree.RootNodeCount:=10000; NodeHeight:=Tree.DefaultNodeHeight;
    for var Dark in [False,True,False] do
    begin
      SetMHLTheme(Dark); ApplyMHLControlTheme(Host);
      Require(ColorToRGB(Host.Color)=Values[Dark].Colors[prWindow],'Window ignores palette');
      Require(ColorToRGB(Edit.Color)=Values[Dark].Colors[prField],'Input ignores palette');
      Require(ColorToRGB(Edit.Font.Color)=Values[Dark].Colors[prText],'Input text ignores palette');
      Require(ColorToRGB(Tree.Color)=Values[Dark].Colors[prField],'Book list ignores palette');
      Require(ColorToRGB(Tree.Colors.FocusedSelectionColor)=Values[Dark].Colors[prSelection],'Selection ignores palette');
      Tree.Selected[Tree.GetFirst]:=True; Tree.PaintSelected(Tree.GetFirst,Bitmap.Canvas);
      Require(ColorToRGB(Bitmap.Canvas.Font.Color)=Values[Dark].Colors[prSelectionText],'Selected text ignores palette');
      Require((Tree.RootNodeCount=10000) and (Tree.DefaultNodeHeight=NodeHeight),'Palette changes book row metrics');
      for var DPI in [96,144,192,240,288] do
      begin
        Dialog:=TInterfaceColorsDialog.CreateFor(Host,Values,Dark);
        try
          Dialog.ScaleForPPI(DPI); ApplyMHLControlTheme(Dialog);
          Dialog.Show; Application.ProcessMessages;
          Bitmap.Canvas.Font.Assign(Dialog.Font);
          for var I:=0 to Dialog.ComponentCount-1 do
          begin
            var Control:=Dialog.Components[I];
            if Control is TButton then
              Require(Bitmap.Canvas.TextWidth(TButton(Control).Caption)+MulDiv(12,DPI,96)<=TButton(Control).ClientWidth,
                'Palette button clips at '+IntToStr(DPI)+': '+TButton(Control).Caption);
            if (Control is TLabel) and not TLabel(Control).AutoSize then
              Require(Bitmap.Canvas.TextWidth(TLabel(Control).Caption)<=TLabel(Control).ClientWidth,'Palette label clips at '+IntToStr(DPI)+': '+TLabel(Control).Caption);
          end;
          Box:=TComboBox(Dialog.FindComponent('PaletteTheme'));
          Require(Box.ItemIndex=Ord(Dark),'Palette editor selects the wrong theme');
          TButton(Dialog.FindComponent('PaletteReset')).Click;
          Loaded:=Dialog.Values;
          for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
          begin
            Require(Loaded[Dark].Colors[Role]=clDefault,'Reset left an override');
            Require(Loaded[not Dark].Colors[Role]=Values[not Dark].Colors[Role],'Reset changed the other theme');
          end;
          TButton(Dialog.FindComponent('PaletteCancel')).Click;
          Require(MHLPaletteColor(Dark,prWindow)=Values[Dark].Colors[prWindow],'Cancelled editor changed the running palette');
        finally Dialog.Free; end;
      end;
    end;
    Driver:=TPaletteEditorProbe.Create;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=10; Driver.Timer.OnTimer:=Driver.Tick;
    try
      Preferences:=TfrmSettings.Create(nil);
      try
        Preferences.LoadSetting;
        Driver.Open(Preferences,False); Preferences.SaveSettings;
        Require(MHLPaletteColor(MHLThemeDark,prWindow)=Values[MHLThemeDark].Colors[prWindow],
          'Cancelling nested editor changed saved Settings');
        Driver.Open(Preferences,True);
      finally Preferences.Free; end;
      Require(MHLPaletteColor(MHLThemeDark,prWindow)=Values[MHLThemeDark].Colors[prWindow],
        'Discarding Settings applied its accepted colour draft');
      Preferences:=TfrmSettings.Create(nil);
      try
        Preferences.LoadSetting; Driver.Open(Preferences,True); Preferences.SaveSettings;
        Require(not MHLPaletteCustomized(MHLThemeDark) and MHLPaletteCustomized(not MHLThemeDark),
          'Saving Settings did not apply reset to only the chosen theme');
      finally Preferences.Free; end;
      Require(Driver.Calls=3,'Settings colour editor flow was incomplete');
    finally Driver.Timer.Free; Driver.Free; end;
    SetMHLThemePalettes(Values);
    Settings.SaveSettings; SetMHLThemePalettes(Saved); Settings.LoadSettings;
    Loaded:=MHLThemePalettes;
    Require(Loaded[True].Colors[prLink]=Values[True].Colors[prLink],'Palette did not survive profile reload');
    Require((Settings.FontColor=LegacyFont) and (Settings.LocalColor=LegacyLocal) and
      (Settings.DeletedColor=LegacyDeleted),'Palette changed book status colours');
    Values[False]:=EmptyMHLThemePalette; Values[True]:=EmptyMHLThemePalette;
    SetMHLThemePalettes(Values); SaveMHLThemePalettes(Ini); LoadMHLThemePalettes(Ini);
    Require(not MHLPaletteCustomized(False) and not MHLPaletteCustomized(True),'Reset does not restore native defaults');
    Require(ColorToRGB(MHLPaletteColor(True,prLink))=RGB(114,167,232),'Dark default was changed');
    Writeln('PASS catalogue palettes persist independently preview cancel reset and retain book colours at 100 to 300 percent');
  finally
    SetMHLThemePalettes(Saved); SetMHLTheme(OldDark); RefreshMHLTheme;
    Bitmap.Free; Ini.Free; Host.Free;
  end;
end;
