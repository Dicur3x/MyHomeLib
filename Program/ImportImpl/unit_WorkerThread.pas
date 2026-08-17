(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2023 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             20.08.2008
  * Description
  *
  * $Id: unit_WorkerThread.pas 875 2010-10-25 09:10:20Z nrymanov@gmail.com $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_WorkerThread;

interface

uses
  Classes,
  Windows,
  SysUtils,
  SyncObjs,
  ComCtrls,
  unit_Globals,
  unit_Events,
  unit_ProgressEngine;

type
  TWorker = class(TThread)
  strict private
    FFinished: Integer;
    FCancel: Integer;
    FComInitialized: Boolean;

    FProgressStyle: TProgressBarStyle;
    FProgressState: TProgressBarState;
    FPercent: Integer;
    FComment: string;
    FSeverity: TTeletypeSeverity;
    FTeletypeMessage: string;

    FMessageText: string;
    FMessageFlags: Integer;
    FMessageResult: Integer;

  strict private
    FOnProgress: TProgressEvent;
    FProgressHint: TProgressHintEvent;
    FOnOpenProgress: TProgressOpenEvent;
    FOnCloseProgress: TProgressCloseEvent;
    FOnTeletype: TProgressTeletypeEvent;
    FOnSetComment: TProgressSetCommentEvent;
    FOnShowMessage: TProgressShowMessageEvent;

    procedure DoOpenProgress;
    procedure DoProgressHint;
    procedure DoSetProgress;
    procedure DoCloseProgress;
    procedure DoTeletype;
    procedure DoSetComment;
    procedure DoShowMessage;
    function GetCanceled: Boolean;
    procedure SetCanceled(const Value: Boolean);
    function GetFinished: Boolean;

  strict protected
    FProgressEngine: TProgressEngine;

  protected
    const ProcessedItemThreshold = 100;

  protected
    procedure OpenProgress;
    procedure SetProgressHint(Style: TProgressBarStyle; State: TProgressBarState = pbsNormal);
    procedure SetProgress(APercent: Integer);
    procedure CloseProgress;
    procedure Teletype(const Msg: string; Severity: TTeletypeSeverity = tsInfo);
    procedure SetComment(const Comment: string);
    function ShowMessage(const Text: string; Flags: Longint {= MB_OK}): Integer;

    procedure Initialize; virtual;
    procedure Uninitialize; virtual;

    procedure Execute; override;
    procedure WorkFunction; virtual; abstract;

  public
    constructor Create;
    procedure Cancel;

  public
    property OnOpenProgress: TProgressOpenEvent read FOnOpenProgress write FOnOpenProgress;
    property OnProgressHint: TProgressHintEvent read FProgressHint write FProgressHint;
    property OnProgress: TProgressEvent read FOnProgress write FOnProgress;
    property OnCloseProgress: TProgressCloseEvent read FOnCloseProgress write FOnCloseProgress;
    property OnTeletype: TProgressTeletypeEvent read FOnTeletype write FOnTeletype;
    property OnSetComment: TProgressSetCommentEvent read FOnSetComment write FOnSetComment;
    property OnShowMessage: TProgressShowMessageEvent read FOnShowMessage write FOnShowMessage;

    property Canceled: Boolean read GetCanceled write SetCanceled;
    property Finished: Boolean read GetFinished;
  end;

implementation

uses
  ActiveX,
  ComObj;

// ============================================================================
constructor TWorker.Create;
begin
  inherited Create(True);

  TInterlocked.Exchange(FFinished, 0);
  TInterlocked.Exchange(FCancel, 0);
  FComInitialized := False;
  FPercent := 0;

  FMessageFlags := 0;
  FMessageResult := 0;
end;

// ============================================================================
procedure TWorker.DoOpenProgress;
begin
  if Assigned(FOnOpenProgress) then
    FOnOpenProgress;
end;

procedure TWorker.OpenProgress;
begin
  TInterlocked.Exchange(FFinished, 0);
  FPercent := 0;

  FProgressEngine.BeginOperation(0, '', '');

  Synchronize(DoOpenProgress);
  Synchronize(DoSetProgress);
end;

// ============================================================================
procedure TWorker.DoProgressHint;
begin
  if Assigned(FProgressHint) then
    FProgressHint(FProgressStyle, FProgressState);
end;

procedure TWorker.SetProgressHint(Style: TProgressBarStyle; State: TProgressBarState = pbsNormal);
begin
  FProgressStyle := Style;
  FProgressState := State;
  Synchronize(DoProgressHint);
end;

// ============================================================================
procedure TWorker.DoSetProgress;
begin
  if Assigned(FOnProgress) then
    FOnProgress(FPercent);
end;

procedure TWorker.SetProgress(APercent: integer);
begin
  if FPercent <> APercent then
  begin
    FPercent := APercent;
    Synchronize(DoSetProgress);
  end;
end;

// ============================================================================
procedure TWorker.DoTeletype;
begin
  if Assigned(FOnTeletype) then
    FOnTeletype(FTeletypeMessage, FSeverity);
end;

procedure TWorker.Teletype(const Msg: string; Severity: TTeletypeSeverity);
begin
  FTeletypeMessage := Msg;
  FSeverity := Severity;
  Synchronize(DoTeletype);
end;

// ============================================================================
procedure TWorker.DoCloseProgress;
begin
  if Assigned(FOnCloseProgress) then
    FOnCloseProgress;
end;

procedure TWorker.CloseProgress;
begin
  try
    if Assigned(FProgressEngine) then
      FProgressEngine.EndOperation;
  finally
    // Publish completion even when progress finalisation raises.  Forms use
    // this flag to decide whether they may close, so leaving it False traps a
    // modal import window forever.
    TInterlocked.Exchange(FFinished, 1);
    Synchronize(DoCloseProgress);
  end;
end;

// ============================================================================
procedure TWorker.DoSetComment;
begin
  if Assigned(FOnSetComment) then
    FOnSetComment(FComment);
end;

procedure TWorker.SetComment(const Comment: string);
begin
  FComment := Comment;
  Synchronize(DoSetComment);
end;

// ============================================================================
procedure TWorker.DoShowMessage;
begin
  if Assigned(FOnShowMessage) then
    FMessageResult := FOnShowMessage(FMessageText, FMessageFlags)
  else
    FMessageResult := 0;
end;

function TWorker.ShowMessage(const Text: string; Flags: Longint {= MB_OK}): Integer;
begin
  FMessageText := Text;
  FMessageFlags := Flags;
  FMessageResult := 0;
  Synchronize(DoShowMessage);
  Result := FMessageResult;
end;

// ============================================================================
procedure TWorker.Cancel;
begin
  SetCanceled(True);
  Terminate;
end;

function TWorker.GetCanceled: Boolean;
begin
  Result := TInterlocked.CompareExchange(FCancel, 0, 0) <> 0;
end;

procedure TWorker.SetCanceled(const Value: Boolean);
begin
  TInterlocked.Exchange(FCancel, Ord(Value));
end;

function TWorker.GetFinished: Boolean;
begin
  Result := TInterlocked.CompareExchange(FFinished, 0, 0) <> 0;
end;

// ============================================================================
procedure TWorker.Initialize;
var
  HR: HRESULT;
begin
  FComInitialized := False;
  HR := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  if Succeeded(HR) then
    FComInitialized := True
  else if HR <> RPC_E_CHANGED_MODE then
    OleCheck(HR);
end;

// ============================================================================
procedure TWorker.Uninitialize;
begin
  if FComInitialized then
  begin
    CoUninitialize;
    FComInitialized := False;
  end;
end;

// ============================================================================
procedure TWorker.Execute;
begin
  FProgressEngine := nil;
  try
    Initialize;
    try
      FProgressEngine := TProgressEngine.Create;
      FProgressEngine.OnSetProgress := SetProgress;
      FProgressEngine.OnSetComment := SetComment;
      FProgressEngine.OnProgressHint := SetProgressHint;

      try
        OpenProgress;
        WorkFunction;
      finally
        CloseProgress;
      end;
    finally
      FreeAndNil(FProgressEngine);
    end;
  finally
    try
      Uninitialize;
    finally
      // Initialize (or even allocation of the progress engine) can fail before
      // CloseProgress is reached.  The UI must still receive its completion
      // notification so the modal form/wizard cannot become uncloseable.
      if not Finished then
      begin
        TInterlocked.Exchange(FFinished, 1);
        Synchronize(DoCloseProgress);
      end;
    end;
  end;
end;

end.

