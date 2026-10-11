program MHLMcpServer;

{$APPTYPE CONSOLE}

// DDL scripts for --make-fixture; see MHLMcpServer_SQL.rc.
{$R MHLMcpServer_SQL.res}

uses
  Vcl.Forms,
  System.Classes,
  System.SysUtils,
  System.JSON,
  dm_user in '..\..\Program\DataModules\dm_user.pas' {DMUser: TDataModule},
  unit_MCP_Transport in 'unit_MCP_Transport.pas',
  unit_MCP_Protocol in 'unit_MCP_Protocol.pas',
  unit_MCP_Tools_Library in 'unit_MCP_Tools_Library.pas',
  unit_MCP_Tools_Text in 'unit_MCP_Tools_Text.pas',
  unit_MCP_Fb2Extract in 'unit_MCP_Fb2Extract.pas',
  unit_MCP_TextCache in 'unit_MCP_TextCache.pas',
  unit_MCP_CacheSelfTest in 'unit_MCP_CacheSelfTest.pas',
  unit_MCP_Fixture in 'unit_MCP_Fixture.pas';

procedure RunExtractMode(const FileName: string);
var
  Stream: TFileStream;
  Extraction: TFb2Extraction;
  Root: TJSONObject;
  Arr: TJSONArray;
  Entry: TJSONObject;
  Transport: TMcpTransport;
  I: Integer;
begin
  Transport := TMcpTransport.Create;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      Extraction := ExtractFb2(Stream);
    finally
      Stream.Free;
    end;

    Arr := TJSONArray.Create;
    try
      for I := 0 to High(Extraction.Sections) do
      begin
        Entry := TJSONObject.Create;
        try
          Entry.AddPair('title', Extraction.Sections[I].Title);
          Entry.AddPair('level', TJSONNumber.Create(Extraction.Sections[I].Level));
          Entry.AddPair('offset', TJSONNumber.Create(Extraction.Sections[I].Offset));
          Entry.AddPair('length', TJSONNumber.Create(Extraction.Sections[I].Length));
        except
          Entry.Free;
          raise;
        end;
        Arr.AddElement(Entry);
      end;
    except
      Arr.Free;
      raise;
    end;

    Root := TJSONObject.Create;
    try
      Root.AddPair('text', Extraction.Text);
      Root.AddPair('sections', Arr);
      Root.AddPair('structured', TJSONBool.Create(Extraction.Structured));
      Root.AddPair('total_length', TJSONNumber.Create(Length(Extraction.Text)));
      Transport.WriteMessage(Root.ToJSON);
    finally
      Root.Free;
    end;
  finally
    Transport.Free;
  end;
end;

// Nothing may write to stdout except TMcpTransport: a stray WriteLn corrupts
// every JSON-RPC response.
//
// No FirstHinstanceRunning: several servers may run alongside the app.
//
// DMUser is created lazily on the first tool call (EnsureLibraryInitialized),
// so a missing system database becomes a system_db_missing tool error instead
// of TDMUser.Init silently creating a new one.

var
  Server: TMcpServer;

begin
  // Checked on ParamStr(1), not ParamCount = 2: an unquoted path with spaces
  // would otherwise fall through to server mode and block on stdin.
  if (ParamCount >= 1) and (ParamStr(1) = '--extract') then
  begin
    if ParamCount <> 2 then
    begin
      Writeln(ErrOutput,
        Format('--extract requires exactly one file path argument (got %d). ' +
          'If the path contains spaces, quote it.', [ParamCount - 1]));
      Halt(1);
    end;

    try
      RunExtractMode(ParamStr(2));
    except
      on E: Exception do
      begin
        Writeln(ErrOutput, 'FB2 extraction failed: ' + E.Message);
        Halt(1);
      end;
    end;
    Exit;
  end;

  if (ParamCount >= 1) and (ParamStr(1) = '--cache-selftest') then
  begin
    try
      RunCacheSelfTestMode;
    except
      on E: Exception do
      begin
        Writeln(ErrOutput, 'Cache self-test failed: ' + E.Message);
        Halt(1);
      end;
    end;
    Exit;
  end;

  Application.Initialize;

  // Deletes a system database, settings file and collection folder; the
  // targets come from the caller's switches, so RunMakeFixtureMode refuses
  // any whose name lacks FIXTURE_USER_NAME (protects the real user.dbs2).
  if (ParamCount >= 1) and (ParamStr(1) = '--make-fixture') then
  begin
    try
      RunMakeFixtureMode;
    except
      on E: Exception do
      begin
        Writeln(ErrOutput, 'Fixture creation failed: ' + E.Message);
        if Assigned(DMUser) then
          FreeAndNil(DMUser);
        Halt(1);
      end;
    end;
    if Assigned(DMUser) then
      FreeAndNil(DMUser);
    Exit;
  end;

  // Eviction is advisory: it must never stop the server from starting.
  try
    EvictCache;
  except
    on E: Exception do
      Writeln(ErrOutput, 'Cache eviction skipped at startup: ' + E.Message);
  end;

  Server := TMcpServer.Create;
  try
    RegisterLibraryTools(Server);
    RegisterTextTools(Server);
    Server.Run;
  finally
    Server.Free;
    if Assigned(DMUser) then
      FreeAndNil(DMUser);
  end;
end.
