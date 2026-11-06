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

procedure ImportSelectedBook(const CollectionID: Integer; const FileName: string;
  out CommittedChanges: Boolean);
procedure ImportFBD(const CollectionID: Integer); overload;
procedure ImportFBD(const CollectionID: Integer; out CommittedChanges: Boolean); overload;

implementation

uses
  Forms,
  unit_ImportFB2Thread,
  unit_ImportFBDThread,
  unit_CollectionWorkerThread,
  frm_ImportProgressForm,
  frm_ImportProgressFormEx,
  unit_Consts;

procedure RunImport(Worker: TCollectionWorker; out CommittedChanges: Boolean);
var
  Progress: TImportProgressFormEx;
begin
  CommittedChanges := False;
  try
    Progress := TImportProgressFormEx.Create(Application);
    try
      Progress.WorkerThread := Worker;
      Progress.btnSaveLog.Visible := True;
      Progress.ShowModal;
      Worker.WaitFor;
      CommittedChanges := Worker.CommittedChanges;
    finally
      Progress.Free;
    end;
  finally
    Worker.Free;
  end;
end;

procedure ImportSelectedBook(const CollectionID: Integer; const FileName: string;
  out CommittedChanges: Boolean);
begin
  RunImport(TImportLocalBookThread.Create(CollectionID,FileName),CommittedChanges);
end;

procedure ImportFB2(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat);
var CommittedChanges: Boolean;
begin
  ImportFB2(CollectionID, ArchiveFormat, CommittedChanges);
end;

procedure ImportFB2(const CollectionID: Integer; const ArchiveFormat: TArchiveFormat;
  out CommittedChanges: Boolean);
begin
  RunImport(TImportFB2Thread.Create(CollectionID,ArchiveFormat),CommittedChanges);
end;



procedure ImportFBD(const CollectionID: Integer);
var CommittedChanges: Boolean;
begin
  ImportFBD(CollectionID, CommittedChanges);
end;

procedure ImportFBD(const CollectionID: Integer; out CommittedChanges: Boolean);
begin
  RunImport(TImportFBDThread.Create(CollectionID),CommittedChanges);
end;

end.

