(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov   oleksiy.penkov@gmail.com
  * Created             25.07.2026
  * Description         Смуга прогресу з відсотком усередині
  *
  ****************************************************************************** *)

unit unit_ProgressBarEx;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.CommCtrl,
  System.Classes,
  System.SysUtils,
  System.Types,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.ComCtrls,
  Vcl.Themes;

type
  // Інтерпозер: модуль має стояти ОСТАННІМ у uses форми, після ComCtrls. DFM не
  // змінюється: TReader.FindComponentClass бере тип опублікованого поля форми,
  // а для успадкованих форм шукає компонент за іменем, ігноруючи клас у DFM.
  //
  // Смуга малюється власноруч: анімація теми Windows 10/11 перемальовує рідний
  // контрол поза нашим WM_PAINT і стирала б текст.
  TProgressBar = class(Vcl.ComCtrls.TProgressBar)
  private
    FShowPercent: Boolean;
    procedure SetShowPercent(Value: Boolean);
    function UseCustomPaint: Boolean;
    procedure WMPaint(var Message: TWMPaint); message WM_PAINT;
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;

  protected
    procedure PaintBar(DC: HDC);
    procedure PaintPercent(DC: HDC; const ABarRect, AChunkRect: TRect);
    procedure WndProc(var Message: TMessage); override;

  public
    constructor Create(AOwner: TComponent); override;

  published
    property ShowPercent: Boolean read FShowPercent write SetShowPercent default True;
  end;

implementation

constructor TProgressBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FShowPercent := True;
  // csOverrideStylePaint: інакше за ввімкненого стилю VCL WM_PAINT піде в
  // TProgressBarStyleHook і наш обробник не спрацює.
  ControlStyle := ControlStyle + [csOpaque, csOverrideStylePaint];
end;

procedure TProgressBar.SetShowPercent(Value: Boolean);
begin
  if FShowPercent <> Value then
  begin
    FShowPercent := Value;
    Invalidate;
  end;
end;

// pbsError/pbsPaused власне малювання не відтворює - їх малює рідний контрол.
function TProgressBar.UseCustomPaint: Boolean;
begin
  Result := FShowPercent and (Style = pbstNormal) and (State = pbsNormal) and
    not (csDesigning in ComponentState);
end;

procedure TProgressBar.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  if UseCustomPaint then
    Message.Result := 1
  else
    inherited;
end;

procedure TProgressBar.WMPaint(var Message: TWMPaint);
var
  PS: TPaintStruct;
  DC: HDC;
begin
  if not UseCustomPaint then
  begin
    inherited;
    Exit;
  end;

  if Message.DC <> 0 then
  begin
    PaintBar(Message.DC);
    Exit;
  end;

  DC := BeginPaint(Handle, PS);
  try
    PaintBar(DC);
  finally
    EndPaint(Handle, PS);
  end;
end;

// Рідний контрол перемальовується після PBM_* сам, але на це не покладаємось,
// щоб відсоток не відставав від позиції.
procedure TProgressBar.WndProc(var Message: TMessage);
begin
  inherited WndProc(Message);

  case Message.Msg of
    PBM_SETPOS, PBM_DELTAPOS, PBM_STEPIT, PBM_SETRANGE, PBM_SETRANGE32, PBM_SETSTATE:
      if UseCustomPaint and HandleAllocated then
        Invalidate;
  end;
end;

procedure TProgressBar.PaintBar(DC: HDC);
var
  BarRect, ChunkRect: TRect;
  Span: Integer;
  Details: TThemedElementDetails;
  LStyle: TCustomStyleServices;
  Brush: HBRUSH;
begin
  BarRect := ClientRect;

  ChunkRect := BarRect;
  InflateRect(ChunkRect, -1, -1);
  Span := Max - Min;
  if (Span > 0) and (Position > Min) then
    ChunkRect.Right := ChunkRect.Left + MulDiv(ChunkRect.Width, Position - Min, Span)
  else
    ChunkRect.Right := ChunkRect.Left;

  LStyle := StyleServices;
  if LStyle.Available then
  begin
    // Як у TProgressBarStyleHook: tpChunk вписаний на 1 піксель у tpBar.
    Details := LStyle.GetElementDetails(tpBar);
    LStyle.DrawElement(DC, Details, BarRect);
    if ChunkRect.Right > ChunkRect.Left then
    begin
      Details := LStyle.GetElementDetails(tpChunk);
      LStyle.DrawElement(DC, Details, ChunkRect);
    end;
  end
  else
  begin
    Brush := CreateSolidBrush(ColorToRGB(clBtnFace));
    try
      FillRect(DC, BarRect, Brush);
    finally
      DeleteObject(Brush);
    end;
    DrawEdge(DC, BarRect, BDR_SUNKENOUTER, BF_RECT);
    if ChunkRect.Right > ChunkRect.Left then
    begin
      Brush := CreateSolidBrush(ColorToRGB(clHighlight));
      try
        FillRect(DC, ChunkRect, Brush);
      finally
        DeleteObject(Brush);
      end;
    end;
  end;

  PaintPercent(DC, BarRect, ChunkRect);
end;

procedure TProgressBar.PaintPercent(DC: HDC; const ABarRect, AChunkRect: TRect);
var
  S: string;
  OldFont: HGDIOBJ;
  Rgn: HRGN;
  R: TRect;
begin
  S := Format('%d%%', [Position]);

  OldFont := SelectObject(DC, Font.Handle);
  SetBkMode(DC, TRANSPARENT);
  try
    // Текст двічі з різним відсіканням, щоб цифри були видні і над заповненою
    // частиною, і над порожньою.
    Rgn := CreateRectRgn(ABarRect.Left, ABarRect.Top, AChunkRect.Right, ABarRect.Bottom);
    try
      SelectClipRgn(DC, Rgn);
      SetTextColor(DC, ColorToRGB(clHighlightText));
      R := ABarRect;
      Winapi.Windows.DrawText(DC, PChar(S), Length(S), R,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
    finally
      DeleteObject(Rgn);
    end;

    Rgn := CreateRectRgn(AChunkRect.Right, ABarRect.Top, ABarRect.Right, ABarRect.Bottom);
    try
      SelectClipRgn(DC, Rgn);
      SetTextColor(DC, ColorToRGB(clWindowText));
      R := ABarRect;
      Winapi.Windows.DrawText(DC, PChar(S), Length(S), R,
        DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
    finally
      DeleteObject(Rgn);
    end;

    SelectClipRgn(DC, 0);
  finally
    SelectObject(DC, OldFont);
  end;
end;

end.
