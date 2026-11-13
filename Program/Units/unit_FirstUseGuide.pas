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
    procedure Layout;
    procedure Remember;
    procedure CMFontChanged(var Message:TMessage); message CM_FONTCHANGED;
  protected
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; IsDpiChange: Boolean); override;
  public
    constructor CreateGuide(AOwner: TComponent; AParent: TWinControl;
      const Topic, Version, Preferences, Summary, Details: string);
    property Expanded: Boolean read FExpanded;
    property OnMore: TNotifyEvent read FOnMore write FOnMore;
  end;

implementation

uses Winapi.Windows, System.SysUtils, System.IniFiles, System.Math,
  System.Types, unit_AtomicIniFile;

constructor TFirstUseGuide.CreateGuide(AOwner: TComponent; AParent: TWinControl;
  const Topic, Version, Preferences, Summary, Details: string);
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
  FToggle := TButton.Create(Self); FToggle.Parent := Self;
  FToggle.Name := 'GuideToggle'; FToggle.OnClick := Toggle;
  FMore := TButton.Create(Self); FMore.Parent := Self;
  FMore.Name := 'GuideMore'; FMore.Caption := 'Подробнее…'; FMore.OnClick := More;
  FNever := TCheckBox.Create(Self); FNever.Parent := Self;
  FNever.Name := 'GuideNever'; FNever.Caption := 'Не раскрывать автоматически'; FNever.Checked := Suppressed;
  FHelp := TButton.Create(Self); FHelp.Parent := Self;
  FHelp.Name := 'GuideContextHelp'; FHelp.Caption := '?';
  FHelp.Hint := 'Об этом разделе'; FHelp.ShowHint := True; FHelp.OnClick := ShowGuide;
  Parent := AParent; Align := alTop; Top := 0;
  Layout;
end;

procedure TFirstUseGuide.Layout;
var Margin, Gap, WidthAvailable, Y, ButtonHeight: Integer;
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
  if FLayout or (csDestroying in ComponentState) or not Assigned(FHelp) then Exit;
  FLayout := True;
  try
    Margin := S(6); Gap := S(6); WidthAvailable := Max(S(100),ClientWidth-2*Margin);
    Y := Margin;
    FHelp.SetBounds(ClientWidth-Margin-S(28),Margin,S(28),S(28));
    Dec(WidthAvailable,S(36));
    FSummary.SetBounds(Margin,Y,WidthAvailable,Max(S(28),Fit(FSummary)));
    Inc(WidthAvailable,S(36)); Inc(Y,FSummary.Height+Gap);
    FDetails.Visible := FExpanded; FNever.Visible := FExpanded;
    FToggle.Visible := FExpanded; FMore.Visible := FExpanded;
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
  finally FLayout := False; end;
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
begin
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
end;

procedure TFirstUseGuide.ShowGuide(Sender: TObject);
begin FExpanded := True; Layout; end;

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
