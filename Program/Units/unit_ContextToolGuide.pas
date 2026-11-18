unit unit_ContextToolGuide;

interface

uses System.Classes, System.SysUtils, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls,
  unit_FirstUseGuide;

type
  // A permanent tool-local button; the owned, modeless guide leaves the
  // existing controls in place and uses the shared per-topic preferences.
  TContextToolGuide = class(TComponent)
  private
    FHost:TCustomForm;
    FButton:TButton;
    FPopup:TForm;
    FBody:TScrollBox;
    FGuide:TFirstUseGuide;
    FTimer:TTimer;
    FTopic,FTitle,FSummary,FDetails,FAnchor:string;
    FContextID:Integer;
    FLayout,FDestroying:Boolean;
    procedure EnsurePopup;
    procedure LayoutPopup;
    procedure PopupResized(Sender:TObject);
    procedure PopupClose(Sender:TObject; var Action:TCloseAction);
    procedure PopupKey(Sender:TObject; var Key:Word; Shift:TShiftState);
    procedure GuideResized(Sender:TObject);
    procedure More(Sender:TObject);
    procedure Tick(Sender:TObject);
    procedure Click(Sender:TObject);
    procedure ShowGuide(Automatic:Boolean);
  public
    constructor CreateForTool(Host:TCustomForm; Header:TWinControl;
      const Topic,Title,Summary,Details:string; ContextID:Integer; const Anchor:string);
    destructor Destroy; override;
    procedure FirstUse;
    procedure Hide;
    property HelpButton:TButton read FButton;
  end;

{$IFDEF MHL_COMPRESSION_TEST}
var ContextGuideShowProbe:TProc<Boolean>;
{$ENDIF}

implementation

uses System.Math, Winapi.Windows, Winapi.Messages, Vcl.Graphics,
  dm_user, unit_ProgramUpdates, unit_MHLTheme, unit_HelpTopics;

type
  TContextGuidePopup=class(TForm)
  private
    FPassive:Boolean;
    procedure CMShowingChanged(var Message:TMessage); message CM_SHOWINGCHANGED;
  public
    procedure ShowPassive;
  end;

procedure TContextGuidePopup.CMShowingChanged(var Message:TMessage);
begin
  if FPassive and Showing then
  begin
    DoShow;
    ShowWindow(Handle,SW_SHOWNOACTIVATE);
  end
  else inherited;
end;

procedure TContextGuidePopup.ShowPassive;
begin
  FPassive:=True;
  try Visible:=True; finally FPassive:=False; end;
end;

constructor TContextToolGuide.CreateForTool(Host:TCustomForm; Header:TWinControl;
  const Topic,Title,Summary,Details:string; ContextID:Integer; const Anchor:string);
begin
  inherited Create(Host);
  FHost:=Host; FTopic:=Topic; FTitle:=Title; FSummary:=Summary; FDetails:=Details;
  FContextID:=ContextID; FAnchor:=Anchor;
  FButton:=TButton.Create(Self); FButton.Parent:=Header; FButton.Name:='ToolContextHelp';
  FButton.Caption:='?'; FButton.Font.Style:=[fsBold];
  FButton.SetBounds(Header.ClientWidth-40,8,28,28); FButton.Anchors:=[akTop,akRight];
  FButton.Hint:='Как пользоваться этим инструментом'; FButton.ShowHint:=True;
  FButton.OnClick:=Click;
  FTimer:=TTimer.Create(Self); FTimer.Enabled:=False; FTimer.Interval:=1; FTimer.OnTimer:=Tick;
end;

destructor TContextToolGuide.Destroy;
begin
  FDestroying:=True; FTimer.Enabled:=False;
  if Assigned(FGuide) then FGuide.OnResize:=nil;
  if Assigned(FPopup) then begin FPopup.OnClose:=nil; FPopup.OnResize:=nil; end;
  FreeAndNil(FPopup);
  inherited;
end;

procedure TContextToolGuide.EnsurePopup;
begin
  if Assigned(FPopup) then Exit;
  FPopup:=TContextGuidePopup.CreateNew(Self); FPopup.Name:='ToolGuidePopup'+FTopic.Replace('-','');
  FPopup.Caption:=FTitle; FPopup.BorderStyle:=bsSizeToolWin; FPopup.Position:=poDesigned;
  FPopup.PopupMode:=pmExplicit; FPopup.PopupParent:=FHost;
  FPopup.PixelsPerInch:=96; FPopup.Font.PixelsPerInch:=96;
  FPopup.Font.Name:='Segoe UI'; FPopup.Font.Size:=9;
  FPopup.ClientWidth:=520; FPopup.ClientHeight:=260;
  FBody:=TScrollBox.Create(FPopup); FBody.Parent:=FPopup; FBody.Align:=alClient;
  FBody.Name:='ToolGuideBody'; FBody.BorderStyle:=bsNone;
  FBody.HorzScrollBar.Visible:=False; FBody.VertScrollBar.Tracking:=True;
  FGuide:=TFirstUseGuide.CreateGuide(FPopup,FBody,FTopic,PROGRAM_RELEASE_VERSION,
    Settings.SettingsFileName,FSummary,FDetails);
  FGuide.Name:='ToolFirstUseGuide'; FGuide.OnMore:=More; FGuide.OnResize:=GuideResized;
  FPopup.OnResize:=PopupResized; FPopup.OnClose:=PopupClose;
  FPopup.KeyPreview:=True; FPopup.OnKeyDown:=PopupKey;
  FLayout:=True;
  try FPopup.ScaleForPPI(Max(96,FHost.Font.PixelsPerInch)); finally FLayout:=False; end;
  ApplyMHLControlTheme(FPopup);
end;

procedure TContextToolGuide.LayoutPopup;
begin
  if FLayout or FDestroying or not Assigned(FGuide) then Exit;
  FLayout:=True;
  try
    var PPI:=Max(96,FHost.Font.PixelsPerInch);
    var Work:=FHost.Monitor.WorkareaRect; var Margin:=MulDiv(12,PPI,96);
    FPopup.ClientWidth:=Min(MulDiv(520,PPI,96),Max(200,Work.Width-2*Margin));
    FGuide.Width:=FBody.ClientWidth;
    var Frame:=FPopup.Height-FPopup.ClientHeight;
    FPopup.Height:=Min(FGuide.Height+Frame,Max(100,Work.Height-2*Margin));
    FPopup.Left:=EnsureRange(FHost.Left+FHost.Width-FPopup.Width,Work.Left,Max(Work.Left,Work.Right-FPopup.Width));
    FPopup.Top:=EnsureRange(FHost.Top+Margin,Work.Top,Max(Work.Top,Work.Bottom-FPopup.Height));
  finally FLayout:=False; end;
end;

procedure TContextToolGuide.PopupResized(Sender:TObject);
begin
  if FLayout or FDestroying then Exit;
  if Assigned(FGuide) then FGuide.Width:=FBody.ClientWidth;
end;

procedure TContextToolGuide.GuideResized(Sender:TObject);
begin
  if FDestroying then Exit;
  if not FGuide.Expanded then begin if FPopup.Visible then FPopup.Hide; Exit; end;
  if not FLayout and not FPopup.Visible then LayoutPopup;
end;

procedure TContextToolGuide.PopupClose(Sender:TObject; var Action:TCloseAction);
begin
  FGuide.Dismiss; Action:=caHide;
end;

procedure TContextToolGuide.PopupKey(Sender:TObject; var Key:Word; Shift:TShiftState);
begin
  if Key=VK_ESCAPE then begin Key:=0; FPopup.Close; end;
end;

procedure TContextToolGuide.More(Sender:TObject);
begin ShowHelpTopic(FContextID,FAnchor); end;

procedure TContextToolGuide.FirstUse;
begin FTimer.Enabled:=True; end;

procedure TContextToolGuide.Hide;
begin
  FTimer.Enabled:=False;
  if Assigned(FPopup) then FPopup.Hide;
end;

procedure TContextToolGuide.Tick(Sender:TObject);
begin
  FTimer.Enabled:=False;
  if FDestroying or not FHost.Visible or not FHost.Enabled then Exit;
  ShowGuide(True);
end;

procedure TContextToolGuide.Click(Sender:TObject);
begin ShowGuide(False); end;

procedure TContextToolGuide.ShowGuide(Automatic:Boolean);
begin
{$IFDEF MHL_COMPRESSION_TEST}
  if Automatic and Assigned(ContextGuideShowProbe) then ContextGuideShowProbe(False);
{$ENDIF}
  try
  EnsurePopup;
  if Automatic and not FGuide.Expanded then Exit;
  FGuide.Expand; LayoutPopup; FBody.VertScrollBar.Position:=0;
  if Automatic then
  begin
    // Keep the first-use explanation modeless and out of the host's focus.
    TContextGuidePopup(FPopup).ShowPassive;
  end
  else FPopup.Show;
  finally
{$IFDEF MHL_COMPRESSION_TEST}
    if Automatic and Assigned(ContextGuideShowProbe) then ContextGuideShowProbe(True);
{$ENDIF}
  end;
end;

end.
