(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             15.04.2010
  * Description         LinkLabel с исправленной поддержкой Themes
  *
  * $Id: MHLLinkLabel.pas 1166 2014-05-22 03:09:17Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit MHLLinkLabel;

interface

uses
  SysUtils,
  Classes,
  Messages,
  Windows,
  Controls,
  ExtCtrls;

type
  TMHLLinkLabel = class(TCustomLinkLabel)
  private
    procedure CNCtlColorStatic(var Message: TWMCtlColorStatic); message CN_CTLCOLORSTATIC;
    procedure CNNotify(var Message: TWMNotify); message CN_NOTIFY;
    procedure SetTransparent(const Value: Boolean);
    function GetTransparent: Boolean;

  public
    function GetIdealSize(const Link: string): TSize;

  published
    property Alignment;
    property Anchors;
    property AutoSize;
    property BevelEdges;
    property BevelInner;
    property BevelKind default bkNone;
    property BevelOuter;
    property Caption;
    property Color nodefault;
    property Constraints;
    property DragCursor;
    property DragKind;
    property DragMode;
    property Enabled;
    property Font;
    property ParentColor;
    property ParentFont;
    property ParentShowHint;
    property PopupMenu;
    property ShowHint;
    property TabOrder;
    property TabStop;
    property Touch;
    property Transparent: Boolean read GetTransparent write SetTransparent default True;
    property UseVisualStyle;
    property Visible;
    property OnClick;
    property OnContextPopup;
    property OnDblClick;
    property OnDragDrop;
    property OnDragOver;
    property OnEndDock;
    property OnEndDrag;
    property OnGesture;
    property OnMouseActivate;
    property OnMouseDown;
    property OnMouseEnter;
    property OnMouseLeave;
    property OnMouseMove;
    property OnMouseUp;
    property OnStartDock;
    property OnStartDrag;
    property OnLinkClick;
  end;

implementation

uses
  CommCtrl,
  Themes,
  Graphics,
  unit_MHLTheme;

function ParseLinks(const Caption: string): string;
type
  TParseSearchMode = (psmLinkStart, psmLinkEnd);
var
  Pos, LookAhead, Last, I: Integer;
  SearchMode: TParseSearchMode;
  Len: Integer;
begin
  if Length(Caption) = 0 then
  begin
    Result := '';
    Exit;
  end;

  SetLength(Result, Length(Caption));
  Pos := 1;
  SearchMode := psmLinkStart;
  Len := 0;
  Last := Length(Caption);

  while Pos <= Last do
  begin
    case Caption[Pos] of
      '<':
      begin
        LookAhead := Pos;

        if Pos = Last then
        begin
          Inc(Len);
          Result[Len] := Caption[Pos];
          Break;
        end;

        Inc(LookAhead);
        if SearchMode = psmLinkStart then
        begin
          if CharInSet(Caption[LookAhead], ['a', 'A']) then
          begin
            while (Caption[LookAhead] <> '>') and (LookAhead <= Last) do
              Inc(LookAhead);

            if LookAhead > Last then
            begin
              for I := 0 to LookAhead - Pos - 1 do
                Result[Len + 1 + I] := Caption[Pos + I];
              Inc(Len, LookAhead - Pos);
              Break;
            end
            else
            begin
              Pos := LookAhead + 1;
              SearchMode := psmLinkEnd;
            end;
          end
          else
          begin
            Inc(Len);
            Result[Len] := Caption[Pos];
            Inc(Pos);
          end;
        end
        else
        begin
          if (Caption[LookAhead] = '/') and
             (CharInSet(Caption[LookAhead + 1], ['a', 'A'])) and
             (Caption[LookAhead + 2] = '>') then
          begin
            Inc(Pos, 4);
            SearchMode := psmLinkStart;
          end
          else
          begin
            Inc(Len);
            Result[Len] := Caption[Pos];
            Inc(Pos);
          end;
        end;
      end
      else
      begin
        Inc(Len);
        Result[Len] := Caption[Pos];
        Inc(Pos);
      end;
    end;
  end;

  SetLength(Result, Len);
end;

function TMHLLinkLabel.GetIdealSize(const Link: string): TSize;
var
  DC: HDC;
  SaveFont: HFont;
  TextSize: TSize;
  Parsed: string;
begin
  DC := GetDC(0);
  try
    SaveFont := SelectObject(DC, Font.Handle);
    try
      if CheckWin32Version(5, 1) and UseThemes then
      begin
        Parsed := ParseLinks(Link);
        GetTextExtentPoint32(DC, Parsed, Length(Parsed), TextSize);
      end
      else
        GetTextExtentPoint32(DC, Caption, Length(Caption), TextSize);
    finally
      SelectObject(DC, SaveFont);
    end;
  finally
    ReleaseDC(0, DC);
  end;

  Result.cx := TextSize.cx + (GetSystemMetrics(SM_CXBORDER) * 4);
  Result.cy := TextSize.cy + (GetSystemMetrics(SM_CYBORDER) * 4);
end;

procedure TMHLLinkLabel.CNCtlColorStatic(var Message: TWMCtlColorStatic);
begin
  if StyleServices.Enabled and Transparent then
  begin
    SetBkMode(Message.ChildDC, Windows.TRANSPARENT);
    StyleServices.DrawParentBackground(Handle, Message.ChildDC, nil, False);
    { Return an empty brush to prevent Windows from overpainting what we just have created. }
    Message.Result := GetStockObject(NULL_BRUSH);
  end
  else
    inherited;
end;

procedure TMHLLinkLabel.CNNotify(var Message: TWMNotify);
var Draw: PNMCustomDraw;
begin
  inherited;
  if not MHLThemeDark or (Message.NMHdr.code <> NM_CUSTOMDRAW) then Exit;
  Draw := PNMCustomDraw(Message.NMHdr);
  case Draw.dwDrawStage of
    CDDS_PREPAINT: Message.Result := CDRF_NOTIFYITEMDRAW;
    CDDS_ITEMPREPAINT:
      begin
        // SysLink paints links with the system colour, ignoring Font.Color.
        if Draw.dwItemSpec = NativeUInt(-1) then
          SetTextColor(Draw.hdc, ColorToRGB(MHLThemeText))
        else SetTextColor(Draw.hdc, ColorToRGB(MHLThemeLink));
        Message.Result := CDRF_NEWFONT;
      end;
  end;
end;

procedure TMHLLinkLabel.SetTransparent(const Value: Boolean);
begin
  if Transparent <> Value then
  begin
    if Value then
      ControlStyle := ControlStyle - [csOpaque]
    else
      ControlStyle := ControlStyle + [csOpaque];
    Invalidate;
  end;
end;

function TMHLLinkLabel.GetTransparent: Boolean;
begin
  Result := not (csOpaque in ControlStyle);
end;

end.
