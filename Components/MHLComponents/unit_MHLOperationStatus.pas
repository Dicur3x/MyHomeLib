unit unit_MHLOperationStatus;

interface
uses System.Classes, System.SysUtils, Vcl.Controls, Vcl.ExtCtrls;
type
  // UI thread only. Timers handle background work; helper polls handle a
  // synchronous decoder without pumping arbitrary/reentrant application input.
  TMHLOperationStatus = class
  private
    FHint: THintWindow;
    FTimer: TTimer;
    FText, FShownText: string;
    FStarted, FLastPulse: UInt64;
    FPreviousHeartbeat: TProc;
    FTrackDecoder: Boolean;
    procedure Tick(Sender: TObject);
  public
    constructor Create(const Stage: string; TrackDecoder: Boolean = False);
    destructor Destroy; override;
    procedure SetStage(const Stage: string);
    procedure Pulse;
    function Visible: Boolean;
  end;
implementation
uses Winapi.Windows, System.Types, Vcl.Forms, Vcl.Graphics, unit_MHLExternalTools;

constructor TMHLOperationStatus.Create(const Stage: string; TrackDecoder: Boolean);
begin
  inherited Create;
  FText:=Stage; FStarted:=GetTickCount64;
  FHint:=THintWindow.Create(nil); FHint.Font.Name:='Segoe UI'; FHint.Font.Size:=9;
  FHint.Color:=RGB(244,247,250); FHint.Font.Color:=RGB(45,60,75);
  FTrackDecoder:=TrackDecoder;
  if TrackDecoder then
  begin
    FPreviousHeartbeat:=MHLExternalToolHeartbeat;
    MHLExternalToolHeartbeat:=procedure begin Pulse; end;
  end;
  FTimer:=TTimer.Create(nil); FTimer.Interval:=50; FTimer.OnTimer:=Tick;
end;

destructor TMHLOperationStatus.Destroy;
begin
  FTimer.Free;
  if FTrackDecoder then MHLExternalToolHeartbeat:=FPreviousHeartbeat;
  FHint.Free; inherited;
end;

procedure TMHLOperationStatus.SetStage(const Stage: string);
begin FText:=Stage; Pulse; end;

procedure TMHLOperationStatus.Tick(Sender: TObject);
begin Pulse; end;

function TMHLOperationStatus.Visible: Boolean;
begin Result:=IsWindowVisible(FHint.Handle); end;

procedure TMHLOperationStatus.Pulse;
var Position: TPoint; Bounds, Area: TRect; Now: UInt64;
begin
  Now:=GetTickCount64;
  if (Now-FStarted<400) or (Now-FLastPulse<50) then Exit;
  FLastPulse:=Now;
  GetCursorPos(Position); Area:=Screen.MonitorFromPoint(Position).WorkareaRect;
  Bounds:=FHint.CalcHintRect(360,FText,nil);
  OffsetRect(Bounds,Position.X+18,Position.Y+24);
  if Bounds.Right>Area.Right then OffsetRect(Bounds,Area.Right-Bounds.Right,0);
  if Bounds.Bottom>Area.Bottom then OffsetRect(Bounds,0,Area.Bottom-Bounds.Bottom);
  if Bounds.Left<Area.Left then OffsetRect(Bounds,Area.Left-Bounds.Left,0);
  if not IsWindowVisible(FHint.Handle) or (FShownText<>FText) or
    not EqualRect(Bounds,FHint.BoundsRect) then
  begin FHint.ActivateHint(Bounds,FText); FShownText:=FText; FHint.Update; end;
end;
end.
