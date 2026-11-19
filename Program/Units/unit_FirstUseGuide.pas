unit unit_FirstUseGuide;

interface

uses System.Classes, Winapi.Messages, Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls;

type
  // Inline help: no modal window, focus change, or work started by opening it.
  TFirstUseGuide = class(TPanel)
  private
    FSummary, FDetails: TLabel;
    FToggle, FMore, FHelp: TButton;
    FNever: TCheckBox;
    FTopic, FVersion, FPreferences: string;
    FExpanded, FLayout: Boolean;
    FLayoutPPI: Integer;
    FOnMore: TNotifyEvent;
    procedure Toggle(Sender: TObject);
    procedure ShowGuide(Sender: TObject);
    procedure More(Sender: TObject);
    procedure SetOnMore(const Value: TNotifyEvent);
    procedure Layout;
    procedure Remember;
    procedure CMFontChanged(var Message:TMessage); message CM_FONTCHANGED;
  protected
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; IsDpiChange: Boolean); override;
  public
    constructor CreateGuide(AOwner: TComponent; AParent: TWinControl;
      const Topic, Version, Preferences, Summary, Details: string;
      ShowHelpButton:Boolean=True; UseReaderPalette:Boolean=False);
    procedure Expand;
    procedure Dismiss;
    property Expanded: Boolean read FExpanded;
    property OnMore: TNotifyEvent read FOnMore write SetOnMore;
  end;

implementation

uses Winapi.Windows, System.SysUtils, System.IniFiles, System.Math,
  System.Types, unit_AtomicIniFile, unit_ReaderPalette;

constructor TFirstUseGuide.CreateGuide(AOwner: TComponent; AParent: TWinControl;
  const Topic, Version, Preferences, Summary, Details: string;
  ShowHelpButton,UseReaderPalette:Boolean);
var Ini: TMemIniFile; Suppressed: Boolean;
begin
  inherited Create(AOwner);
  BevelOuter := bvNone; ShowCaption := False;
  FTopic := Topic; FVersion := Version; FPreferences := Preferences;
  FExpanded := True;
  Ini := nil; Suppressed := False;
  try
    try
      Ini := TMemIniFile.Create(Preferences, TEncoding.UTF8);
      Suppressed := Ini.ReadBool('ToolGuidesDisabled', Topic, False);
      FExpanded := not Suppressed and
        (Ini.ReadString('ToolGuidesSeen', Topic, '') <> Version);
    except
      // An unavailable help preference must not prevent opening the tool.
      FExpanded := True;
    end;
  finally Ini.Free; end;
  FSummary := TLabel.Create(Self); FSummary.Parent := Self;
  FSummary.Name := 'GuideSummary'; FSummary.Caption := Summary;
  FSummary.AutoSize := False; FSummary.WordWrap := True;
  FDetails := TLabel.Create(Self); FDetails.Parent := Self;
  FDetails.Name := 'GuideDetails'; FDetails.Caption := Details;
  FDetails.AutoSize := False; FDetails.WordWrap := True;
  if UseReaderPalette then
  begin
    FToggle:=TReaderPaletteButton.Create(Self);
    FMore:=TReaderPaletteButton.Create(Self);
    FNever:=TReaderPaletteCheckBox.Create(Self);
  end
  else
  begin
    FToggle:=TButton.Create(Self);
    FMore:=TButton.Create(Self);
    FNever:=TCheckBox.Create(Self);
  end;
  FToggle.Parent := Self;
  FToggle.Name := 'GuideToggle'; FToggle.OnClick := Toggle;
  FMore.Parent := Self;
  FMore.Name := 'GuideMore'; FMore.Caption := 'Подробнее…'; FMore.OnClick := More;
  FNever.Parent := Self;
  FNever.Name := 'GuideNever'; FNever.Caption := 'Не раскрывать автоматически'; FNever.Checked := Suppressed;
  if ShowHelpButton then
  begin
    FHelp := TButton.Create(Self); FHelp.Parent := Self;
    FHelp.Name := 'GuideContextHelp'; FHelp.Caption := '?';
    FHelp.Hint := 'Об этом разделе'; FHelp.ShowHint := True; FHelp.OnClick := ShowGuide;
  end;
  Parent := AParent; Align := alTop; Top := 0;
  Layout;
end;

procedure TFirstUseGuide.Layout;
var Margin, Gap, WidthAvailable, Y, ButtonHeight, WidthBefore: Integer;
  function S(Value: Integer): Integer;
  begin
    if FLayoutPPI>0 then Result:=MulDiv(Value,FLayoutPPI,96)
    else Result:=MulDiv(Value,CurrentPPI,96);
  end;
  function Fit(LabelControl: TLabel): Integer;
  var Bounds: TRect;
  begin
    Canvas.Font.PixelsPerInch:=LabelControl.Font.PixelsPerInch;
    Canvas.Font.Assign(LabelControl.Font); Bounds := Rect(0,0,WidthAvailable,0);
    DrawText(Canvas.Handle,PChar(LabelControl.Caption),Length(LabelControl.Caption),
      Bounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Result := Bounds.Height + S(4);
  end;
begin
  if FLayout or (csDestroying in ComponentState) or not Assigned(FNever) then Exit;
  WidthBefore:=ClientWidth;
  FLayout := True;
  try
    Margin := S(6); Gap := S(6); WidthAvailable := Max(S(100),ClientWidth-2*Margin);
    Y := Margin;
    if Assigned(FHelp) then
    begin
      FHelp.Visible := not FExpanded;
      if FHelp.Visible then
      begin
        FHelp.SetBounds(ClientWidth-Margin-S(28),Margin,S(28),S(28));
        Dec(WidthAvailable,S(36));
      end;
    end;
    FSummary.SetBounds(Margin,Y,WidthAvailable,Max(S(28),Fit(FSummary)));
    WidthAvailable:=Max(S(100),ClientWidth-2*Margin); Inc(Y,FSummary.Height+Gap);
    FDetails.Visible := FExpanded; FNever.Visible := FExpanded;
    FToggle.Visible := FExpanded; FMore.Visible := FExpanded and Assigned(FOnMore);
    if FExpanded then
    begin
      FDetails.SetBounds(Margin,Y,WidthAvailable,Fit(FDetails)); Inc(Y,FDetails.Height+Gap);
      FNever.SetBounds(Margin,Y,WidthAvailable,S(24)); Inc(Y,FNever.Height+Gap);
      FToggle.Caption := 'Понятно';
    end
    else begin Height := Y; Exit; end;
    ButtonHeight := S(28);
    FToggle.SetBounds(Margin,Y,Min(S(155),(WidthAvailable-Gap) div 2),ButtonHeight);
    FMore.SetBounds(FToggle.Left+FToggle.Width+Gap,Y,Min(S(100),(WidthAvailable-Gap) div 2),ButtonHeight);
    Height := Y+ButtonHeight+Margin;
  finally
    FLayout := False;
    // A scroll parent can gain/lose its vertical bar while this height changes.
    // Reflow once more at the resulting width instead of retaining clipped actions.
    if ClientWidth<>WidthBefore then Layout;
  end;
end;

procedure TFirstUseGuide.Remember;
var Ini: TMemIniFile;
begin
  Ini := TMemIniFile.Create(FPreferences,TEncoding.UTF8);
  try
    Ini.WriteString('ToolGuidesSeen',FTopic,FVersion);
    Ini.WriteBool('ToolGuidesDisabled',FTopic,FNever.Checked);
    SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
end;

procedure TFirstUseGuide.Toggle(Sender: TObject);
var ReturnFocus: Boolean;
begin
  ReturnFocus := Assigned(FHelp) and FToggle.Focused;
  if FExpanded then
    try
      Remember;
      FToggle.ShowHint := False;
    except
      on E: Exception do
      begin
        // Help must remain usable even in a read-only portable installation.
        FToggle.Hint := 'Не удалось запомнить просмотр. При следующем открытии подсказка повторится. '+E.Message;
        FToggle.ShowHint := True;
      end;
    end;
  FExpanded := not FExpanded;
  Layout;
  if ReturnFocus and FHelp.CanFocus then FHelp.SetFocus;
end;

procedure TFirstUseGuide.ShowGuide(Sender: TObject);
var MoveFocus: Boolean;
begin
  MoveFocus := Assigned(FHelp) and FHelp.Focused;
  FExpanded := True;
  Layout;
  if MoveFocus and FToggle.CanFocus then FToggle.SetFocus;
end;

procedure TFirstUseGuide.Expand;
begin ShowGuide(nil); end;

procedure TFirstUseGuide.Dismiss;
begin if FExpanded then Toggle(nil); end;

procedure TFirstUseGuide.SetOnMore(const Value: TNotifyEvent);
begin
  FOnMore:=Value;
  Layout;
end;

procedure TFirstUseGuide.More(Sender: TObject);
begin if Assigned(FOnMore) then FOnMore(Self); end;

procedure TFirstUseGuide.Resize;
begin inherited; Layout; end;

procedure TFirstUseGuide.ChangeScale(M,D: Integer; IsDpiChange: Boolean);
begin
  if IsDpiChange then FLayoutPPI:=M;
  inherited; Layout;
end;

procedure TFirstUseGuide.CMFontChanged(var Message:TMessage);
begin
  inherited;
  Layout;
end;

end.
