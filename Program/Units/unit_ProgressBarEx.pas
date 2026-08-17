(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov   oleksiy.penkov@gmail.com
  * Created             25.07.2026
  * Description         Полоса прогресса с процентом внутри
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
  //
  // Класс-перехватчик стандартного TProgressBar: дорисовывает процент внутри полосы.
  //
  // Подключается добавлением этого модуля ПОСЛЕДНИМ в uses модуля формы - после
  // ComCtrls. DFM не изменяется: TReader.FindComponentClass ищет класс в DFM
  // среди опубликованных полей формы и берет тип поля, а не зарегистрированный класс.
  // Наследуемые формы, которые переопределяют `inherited ProgressBar: TProgressBar`,
  // тоже получают его - для наследуемого чтения компонент ищется по
  // имени, а имя класса в DFM игнорируется.
  //
  // Полоса с точным прогрессом рисуется вручную, а не поверх родного
  // элемента управления: тема Windows 10/11 плавно «доезжает» до заданной позиции
  // собственной анимацией, которая перерисовывает элемент вне нашего WM_PAINT и стирала бы текст.
  // Для pbstMarquee рисование отдается базовому классу - там Position не имеет
  // смысла, и процент не показывается.
  //
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

{ TProgressBar }

constructor TProgressBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FShowPercent := True;
  //
  // csOpaque - фон рисуем сами, родительский не нужен.
  // csOverrideStylePaint - TWinControl.WndProc передает сообщения хуку
  // TProgressBarStyleHook, как только включен пользовательский стиль VCL, и наш
  // обработчик WM_PAINT туда бы не дошёл. Сейчас пользовательские стили не применяются, но
  // этот флажок оставляет рисование за нами, если их когда-нибудь включат.
  //
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

//
// Состояния pbsError/pbsPaused программа не использует (TProgressEngine всегда
// посылает pbsNormal), а собственная отрисовка их не воспроизводит. Передадим такие случаи
// родному контролу.
//
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

//
// Родной контрол после PBM_* перерисовывается сам, но полагаться на это не
// стоит: явно просим перерисовку, чтобы процент не отставал от позиции.
// Мерцания нет - csOpaque плюс WM_ERASEBKGND, который ничего не стирает.
//
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
    //
    // Те же элементы темы, которыми рисует штатный TProgressBarStyleHook:
    // tpBar - желоб на всю площадь, tpChunk - заполнение, вписанное на 1 пиксель.
    //
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
    //
// Классическая тема без uxtheme.
    //
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
    //
    // Текст рисуется дважды с разной обрезкой: над заполненной частью
    // светлым, над пустой — обычным цветом. Иначе цифры терялись бы под
    // набегающей полосой.
    //
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
