program BuiltinReaderBenchmark;
{$APPTYPE CONSOLE}

uses NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  System.Diagnostics, System.Hash, Winapi.Windows, Winapi.ActiveX, Vcl.Forms,
  frm_BuiltinReader;

procedure Require(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;

var Form: TfrmBuiltinReader; Watch: TStopwatch; Name, BeforeHash: string;
  I, Position: Integer;
begin
  RequireIsolatedRegression;
  CoInitialize(nil);
  try
    Application.Initialize;
    Name:=ParamStr(1);
    Require((ExtractFileName(Name)=Name) and FileExists(Name),'Use an isolated fixture name');
    BeforeHash:=THashSHA2.GetHashStringFromFile(Name);
    Form:=TfrmBuiltinReader.Create(nil);
    try
      Form.Show; Watch:=TStopwatch.StartNew;
      Form.OpenBook(Name,Name,'benchmark-'+Name,'reader-benchmark.ini','pdfium.dll');
      while not Form.LoadFinished and (Watch.ElapsedMilliseconds<120000) do
      begin Application.ProcessMessages; CheckSynchronize(5); end;
      Require(Form.Ready,'Reader not ready: '+Form.ReaderStatus.Caption);
      Writeln('PROFILE load_ms=',Watch.ElapsedMilliseconds,' chars=',Form.TextLength); Flush(Output);
      Watch:=TStopwatch.StartNew;
      for I:=1 to 30 do Form.NextPage;
      Require(Form.TextPosition>0,'Pagination did not advance');
      Writeln('PROFILE next_30_ms=',Watch.ElapsedMilliseconds); Flush(Output);
      Watch:=TStopwatch.StartNew; Form.FindText('TAIL_MARKER_20261009');
      Position:=Form.TextPosition;
      Require(Position>Form.TextLength div 2,'Tail search did not find the last paragraph');
      Writeln('PROFILE search_tail_ms=',Watch.ElapsedMilliseconds); Flush(Output);
      Watch:=TStopwatch.StartNew; Form.AddBookmark;
      Writeln('PROFILE bookmark_ms=',Watch.ElapsedMilliseconds); Flush(Output);
      Watch:=TStopwatch.StartNew; Form.PreviousPage;
      Require(Form.TextPosition<Position,'Resumed previous page did not go back');
      Writeln('PROFILE resumed_previous_ms=',Watch.ElapsedMilliseconds); Flush(Output);
      Watch:=TStopwatch.StartNew; Form.ChangeSize(1);
      Writeln('PROFILE font_change_ms=',Watch.ElapsedMilliseconds); Flush(Output);
      Form.Close;
    finally Form.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Name)=BeforeHash,'Source changed');
    Writeln('PASS large reader fixture preserved and navigated');
  except
    on E: Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); ExitCode:=1; end;
  end;
  CoUninitialize;
end.
