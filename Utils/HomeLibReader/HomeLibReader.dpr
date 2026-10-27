program HomeLibReader;

{$R *.res}
{$R '..\..\Program\MyhomeLib.dres'}
{$R '..\..\Program\lang.res'}
{$R '..\..\Program\HomeLibRuManifest.res'}

uses System.SysUtils, System.IOUtils, System.Win.ComObj, Winapi.Windows, Winapi.ActiveX, Vcl.Forms,
  unit_Settings, unit_Diagnostics, unit_MHLTheme, dm_user, frm_ReaderHost;

var Profile, Source, SessionFile: string;
begin
  Profile:=TPath.Combine(GetEnvironmentVariable('APPDATA'),'HomeLibReader');
  Source:=''; SessionFile:='';
  for var I:=1 to ParamCount do
    if ParamStr(I).StartsWith('--profile=') then Profile:=ParamStr(I).Substring(10)
    else if ParamStr(I).StartsWith('--open=') then Source:=ParamStr(I).Substring(7)
    else if ParamStr(I).StartsWith('--session=') then SessionFile:=ParamStr(I).Substring(10)
    else if not ParamStr(I).StartsWith('--') and (Source='') then Source:=ParamStr(I);
  ConfigureMHLHostProfile(TPath.GetFullPath(Profile),'HomeLibReader.ini','reader-user.dbs2');
  Application.Initialize; Application.MainFormOnTaskbar:=True;
  Application.Title:='HomeLib Reader';
  OleCheck(CoInitializeEx(nil,COINIT_APARTMENTTHREADED));
  try
   try
    InitializeDiagnostics;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    SetMHLTheme(Settings.DarkTheme);
    Application.CreateForm(TfrmReaderHost,ReaderHost);
    ReaderHost.OpenInitialSession(SessionFile); ReaderHost.OpenInitialFile(Source);
    Application.Run;
  except
    on E: Exception do begin LogDiagnosticError('reader-startup-or-main-loop',E); raise; end;
   end;
  finally CoUninitialize; end;
end.
