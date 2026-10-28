program HomeLibReader;

{$R *.res}
{$R '..\..\Program\MyhomeLib.dres'}
{$R '..\..\Program\lang.res'}
{$R '..\..\Program\HomeLibRuManifest.res'}

uses System.SysUtils, System.IOUtils, System.Win.ComObj, Winapi.Windows, Winapi.ActiveX, Vcl.Forms,
  unit_Settings, unit_ReaderStartup, unit_Diagnostics, unit_MHLTheme, dm_user, frm_ReaderHost;

var Startup: TReaderStartup; Arguments: TArray<string>;
begin
  SetLength(Arguments,ParamCount);
  for var I:=1 to ParamCount do Arguments[I-1]:=ParamStr(I);
  Startup:=ResolveReaderStartup(ParamStr(0),Arguments);
  ConfigureMHLHostProfile(Startup.Profile,'HomeLibReader.ini','reader-user.dbs2');
  Application.Initialize; Application.MainFormOnTaskbar:=True;
  Application.Title:='HomeLib Reader';
  OleCheck(CoInitializeEx(nil,COINIT_APARTMENTTHREADED));
  try
   try
    InitializeDiagnostics;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    SetMHLTheme(Settings.DarkTheme);
    Application.CreateForm(TfrmReaderHost,ReaderHost);
    ReaderHost.OpenInitialSession(Startup.SessionFile); ReaderHost.OpenInitialFile(Startup.Source);
    Application.Run;
  except
    on E: Exception do begin LogDiagnosticError('reader-startup-or-main-loop',E); raise; end;
   end;
  finally CoUninitialize; end;
end.
