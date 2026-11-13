procedure TestCataloguePlacementShutdown;
var SavedState: Integer; Ini: TMemIniFile;
begin
  frmMain.WindowState:=wsNormal;
  frmMain.SetBounds(80,60,1000,740);
  frmMain.Show;
  frmMain.WindowState:=wsMaximized;
  Application.ProcessMessages;
  Require(frmMain.WindowState=wsMaximized,'Placement fixture did not maximize');
  Writeln('TRACE placement before shutdown ',Ord(frmMain.WindowState),' ',frmMain.Width,'x',frmMain.Height);
  if ParamStr(2)='finalize-first' then
  begin
    // The production DPR detaches the style engine before VCL exit procedures
    // destroy the still-owned main form. Exercise that real shutdown order.
    FinalizeMHLTheme;
    Writeln('TRACE placement after theme detach ',Ord(frmMain.WindowState),' ',frmMain.Width,'x',frmMain.Height);
  end;
  FreeAndNil(frmMain);
  SavedState:=Settings.WindowState;
  Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
  try
    Writeln('TRACE saved placement ',SavedState,' ',Ini.ReadInteger('INTERFACE','WindowState',-1));
    Require(SavedState=Ord(wsMaximized),'Maximized catalogue state lost during shutdown');
    Require(Ini.ReadInteger('INTERFACE','WindowState',-1)=Ord(wsMaximized),
      'Persisted catalogue state lost during shutdown');
  finally Ini.Free; end;
  Writeln('PASS maximized catalogue placement survives actual shutdown order');
end;
