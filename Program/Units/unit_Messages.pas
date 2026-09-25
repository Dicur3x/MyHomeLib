(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             12.02.2010
  * Description
  *
  * $Id: unit_Messages.pas 588 2010-08-20 01:15:40Z eg_ $
  *
  * History
  * NickR 15.02.2010    Код переформатирован
  *
  ****************************************************************************** *)

unit unit_Messages;

interface

uses
  Windows,
  Messages,
  unit_Globals;

const
  WM_MHL_BASE = WM_APP + $0500;

  WM_MHL_CHANGELOCALSTATUS = WM_MHL_BASE + 0;

type
  PBookLocalStatus = ^TBookLocalStatus;
  TBookLocalStatus = record
    BookKey: TBookKey;
    LocalStatus: Boolean;
  end;

  TLocalStatusChangedMessage = packed record
    Msg: Cardinal;
    // Match TMessage: Win64 aligns WPARAM/LPARAM on an eight-byte boundary.
{$IFDEF WIN64}
    MsgFiller: Cardinal;
{$ENDIF}
    Unused: WPARAM;
    Params: PBookLocalStatus;
    Result: LRESULT;
  end;

procedure BookLocalStatusChanged(
  const BookKey: TBookKey;
  LocalStatus: Boolean
);

implementation

uses
  Forms;

procedure BookLocalStatusChanged(
  const BookKey: TBookKey;
  LocalStatus: Boolean
);
var
  Param: PBookLocalStatus;
begin
  if Application.MainForm = nil then
    Exit;

  New(Param);
  Param^.BookKey := BookKey;
  Param^.LocalStatus := LocalStatus;

  if not PostMessage(
    Application.MainFormHandle,
    WM_MHL_CHANGELOCALSTATUS,
    0,
    LPARAM(Param)
  ) then
    Dispose(Param);
end;

end.
