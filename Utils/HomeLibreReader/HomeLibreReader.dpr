program HomeLibreReader;

{$R *.res}
{$R '..\..\Program\HomeLibre.dres'}
{$R '..\..\Program\lang.res'}
{$R '..\..\Program\HomeLibreManifest.res'}

uses System.SysUtils, System.IOUtils, System.Win.ComObj, Winapi.Windows, Winapi.ActiveX, Vcl.Forms,
  unit_Settings, unit_ReaderStartup, unit_Diagnostics, unit_MHLTheme, dm_user, frm_ReaderHost,
  unit_ProgramUpdateInstaller, unit_ProfileIni;

var Startup: TReaderStartup; Arguments: TArray<string>;
begin
  SetLength(Arguments,ParamCount);
  for var I:=1 to ParamCount do Arguments[I-1]:=ParamStr(I);
  Startup:=ResolveReaderStartup(ParamStr(0),Arguments);
  ConfigureMHLHostProfile(Startup.Profile,READER_SETTINGS_FILE_NAME,'reader-user.dbs2');
  Application.Initialize; Application.MainFormOnTaskbar:=True;
  Application.Icon.LoadFromResourceName(HInstance,'ZZ_HOME_LIBRE_READER_ICON');
  Application.Title:='HomeLibre Reader';
  OleCheck(CoInitializeEx(nil,COINIT_APARTMENTTHREADED));
  try
   try
    InitializeDiagnostics;
    try
      CompleteLegacyReaderName(ParamStr(0));
    except
      on E: Exception do LogDiagnosticError('reader-name-migration',E);
    end;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    SetMHLTheme(Settings.DarkTheme);
    Application.CreateForm(TfrmReaderHost,ReaderHost);
    ReaderHost.OpenInitialSession(Startup.SessionFile); ReaderHost.OpenInitialFile(Startup.Source);
    Application.ShowMainForm:=False;
    ReaderHost.ShowStartPage;
    Application.Run;
  except
    on E: Exception do begin LogDiagnosticError('reader-startup-or-main-loop',E); raise; end;
   end;
  finally
    try FinalizeMHLTheme; finally CoUninitialize; end;
  end;
end.
