program XpsCoverTest;
{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, Winapi.Windows,
  NativeRegressionGuard, unit_XpsBookCover;

var Root, Mode, Tool, Source, MessageText: string; Request, Output: TJSONObject;
  Data: TBytes; Checks: Integer; Canceled, Failed: Boolean; Started: UInt64; Input: TStream;
begin
  try
    RequireIsolatedRegression;
    Root:=ExtractFilePath(ParamStr(0));
    Request:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Root+'request.json',TEncoding.UTF8)) as TJSONObject;
    try
      Mode:=Request.GetValue<string>('mode'); Tool:=Request.GetValue<string>('tool');
      Source:=Request.GetValue<string>('source');
    finally Request.Free; end;
    Checks:=0; Canceled:=False; Failed:=False; MessageText:=''; Started:=GetTickCount64;
    ForceDirectories(Root+'Temp');
    Input:=TFileStream.Create(Source,fmOpenRead or fmShareDenyWrite);
    try
    try
      Data:=ReadXpsBookCover(Source,Tool,Root+'Temp',function:Boolean
        begin Inc(Checks); Result:=(Mode='cancel') and (GetTickCount64-Started>=1000); end);
    except
      on E:EAbort do Canceled:=True;
      on E:EReadError do begin Failed:=True; MessageText:=E.Message; end;
    end;
    finally Input.Free; end;
    if (Mode='cover') and (Length(Data)=0) then raise Exception.Create('No cover');
    if (Mode='cancel') and not Canceled then raise Exception.Create('Cancellation ignored');
    if (Mode='reject') and not Failed then raise Exception.Create('Invalid input accepted');
    if Length(TDirectory.GetDirectories(Root+'Temp','homelibre-xps-cover-*'))<>0 then
      raise Exception.Create('Temporary cover directory remains');
    if Length(Data)>0 then TFile.WriteAllBytes(Root+'cover.png',Data);
    Output:=TJSONObject.Create;
    try
      Output.AddPair('status','PASS'); Output.AddPair('mode',Mode);
      Output.AddPair('canceled',TJSONBool.Create(Canceled));
      Output.AddPair('failed',TJSONBool.Create(Failed)); Output.AddPair('message',MessageText);
      Output.AddPair('bytes',TJSONNumber.Create(Length(Data)));
      Output.AddPair('cancel_checks',TJSONNumber.Create(Checks));
      TFile.WriteAllText(Root+'result.json',Output.ToJSON,TEncoding.UTF8);
    finally Output.Free; end;
  except on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end; end;
end.
