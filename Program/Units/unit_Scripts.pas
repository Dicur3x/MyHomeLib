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
  * $Id: unit_Scripts.pas 613 2010-08-23 09:07:43Z nrymanov@gmail.com $
  *
  * History
  * NickR 15.02.2010    Код переформатирован
  *
  ****************************************************************************** *)

unit unit_Scripts;

interface

uses Classes;

type
  TScriptDesc = class(TCollectionItem)
  strict private
    FTitle: string;
    FPath: string;
    FParams: string;
    FTmpParams: string;
    FStandalone: Boolean;

  protected
    procedure AssignTo(Dest: TPersistent); override;

  public
    procedure Run;

    property Title: string read FTitle write FTitle;
    property Path: string read FPath write FPath;
    property Params: string read FParams write FParams;
    property TmpParams: string read FTmpParams write FTmpParams;
    property Standalone: Boolean read FStandalone write FStandalone;
  end;

  TScripts = class(TCollection)
  strict private
    function GetScript(Index: Integer): TScriptDesc;
    procedure SetScript(Index: Integer; const Value: TScriptDesc);

    function AddScript: TScriptDesc;

  public
    constructor Create;
    procedure Add(const Title: string; const Path: string; const Params: string; Standalone: Boolean = False);

    property Items[Index: Integer]: TScriptDesc read GetScript write SetScript; default;
  end;

implementation

uses
  Windows,
  ShellAPI,
  SysUtils,
  Forms,
  unit_Errors,
  StrUtils,
  unit_Helpers;


procedure TScriptDesc.AssignTo(Dest: TPersistent);
var
  Other: TScriptDesc;
begin
  if Dest is TScriptDesc then
  begin
    Other := TScriptDesc(Dest);
    Other.Title := Title;
    Other.Path := Path;
    Other.Params := Params;
    Other.Standalone := Standalone;
  end
  else
    inherited AssignTo(Dest);
end;

procedure TScriptDesc.Run;
var
  AHInst: HINST;
  P, Directory: string;
begin
  P := IfThen(TmpParams = '', Params, TmpParams);
  if Standalone then
  begin
    // Parameters are already a user-authored command line. Quoting the entire
    // string would collapse several arguments into one.
    P := Params;
    Directory := ExtractFilePath(ExpandFileName(Path));
    AHInst := ShellAPI.ShellExecute(Application.Handle, 'open', PChar(Path),
      PChar(P), PChar(Directory), SW_SHOWNORMAL);
  end
  else AHInst := SimpleShellExecute(Application.Handle, Path, P, '');
  TmpParams := '';
  if AHInst <= 32 then
    raise Exception.Create(SysErrorMessage(AHInst));
end;


constructor TScripts.Create;
begin
  inherited Create(TScriptDesc);
end;

function TScripts.GetScript(Index: Integer): TScriptDesc;
begin
  Result := TScriptDesc(inherited Items[Index]);
end;

procedure TScripts.SetScript(Index: Integer; const Value: TScriptDesc);
begin
  inherited Items[Index] := Value;
end;

function TScripts.AddScript: TScriptDesc;
begin
  Result := TScriptDesc(inherited Add);
end;

procedure TScripts.Add(const Title, Path, Params: string; Standalone: Boolean);
var
  Script: TScriptDesc;
begin
  if (Title = '') or (Path = '')  then
    raise EMHLError.Create(rstrErrorInvalidArgument);

  BeginUpdate;
  try
    Script := AddScript;
    try
      Script.Title := Title;
      Script.Path := Path;
      Script.Params := Params;
      Script.Standalone := Standalone;
    except
      Script.Free;
      raise;
    end;
  finally
    EndUpdate;
  end;
end;

end.
