(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov    nrymanov@gmail.com
  *                     Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             22.02.2010
  * Description
  *
  * $Id: unit_Import.pas 1105 2012-02-02 08:24:58Z koreec $
  *
  * History
  * NickR 02.03.2010    Код переформатирован
  * NickR 08.04.2010    Убраны ненужные зависимости
  *
  ****************************************************************************** *)

unit unit_Import;

interface

uses
  unit_Globals,
  unit_Interfaces,
  unit_MHLArchiveHelpers;
  
procedure ImportFB2(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat); overload;
procedure ImportFB2(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat;
  out CommittedChanges: Boolean); overload;

procedure ImportFBD(const CollectionID: Integer); overload;
procedure ImportFBD(const CollectionID: Integer; out CommittedChanges: Boolean); overload;

implementation

uses
  Forms,
  unit_ImportFB2Thread,
  unit_ImportFBDThread,
  frm_ImportProgressForm,
  frm_ImportProgressFormEx,
  unit_Consts;

procedure ImportFB2(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat);
var CommittedChanges: Boolean;
begin
  ImportFB2(CollectionID, ArchiveFormat, CommittedChanges);
end;

procedure ImportFB2(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat;
  out CommittedChanges: Boolean);
var
  worker: TImportFB2Thread;
  frmProgress: TImportProgressFormEx;
begin
  CommittedChanges := False;
  worker := TImportFB2Thread.Create(CollectionID, ArchiveFormat);
  try
    frmProgress := TImportProgressFormEx.Create(Application);
    try
      frmProgress.WorkerThread := worker;
      frmProgress.btnSaveLog.Visible := True;
      frmProgress.ShowModal;
      worker.WaitFor;
      CommittedChanges := worker.CommittedChanges;
    finally
      frmProgress.Free;
    end;
  finally
    worker.Free;
  end;
end;



procedure ImportFBD(const CollectionID: Integer);
var CommittedChanges: Boolean;
begin
  ImportFBD(CollectionID, CommittedChanges);
end;

procedure ImportFBD(const CollectionID: Integer; out CommittedChanges: Boolean);
var
  worker: TImportFBDThread;
  frmProgress: TImportProgressFormEx;
begin
  CommittedChanges := False;
  worker := TImportFBDThread.Create(CollectionID);
  try
    frmProgress := TImportProgressFormEx.Create(Application);
    try
      frmProgress.WorkerThread := worker;
      frmProgress.btnSaveLog.Visible := True;
      frmProgress.ShowModal;
      worker.WaitFor;
      CommittedChanges := worker.CommittedChanges;
    finally
      frmProgress.Free;
    end;
  finally
    worker.Free;
  end;
end;

end.

