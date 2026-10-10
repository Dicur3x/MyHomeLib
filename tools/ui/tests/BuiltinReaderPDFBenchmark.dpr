program BuiltinReaderPDFBenchmark;
{$APPTYPE CONSOLE}

uses NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  System.Diagnostics, System.Hash, Winapi.Windows, Vcl.Forms, Vcl.Graphics,
  unit_ReaderPDF, frm_BuiltinReader;

procedure Require(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;

function RasterHash(Bitmap: TBitmap): string;
var Bytes: TBytes; Y: Integer; Stream: TBytesStream;
begin
  GdiFlush;
  SetLength(Bytes,Bitmap.Width*Bitmap.Height*4);
  for Y:=0 to Bitmap.Height-1 do
    Move(Bitmap.ScanLine[Y]^,Bytes[Y*Bitmap.Width*4],Bitmap.Width*4);
  Stream:=TBytesStream.Create(Bytes);
  try Result:=THashSHA2.GetHashString(Stream); finally Stream.Free; end;
end;

var PDF: TReaderPDF; Bitmap: TBitmap; Form: TfrmBuiltinReader;
  Watch: TStopwatch; I: Integer; BeforeHash: string; Raster: TPoint;
begin
  RequireIsolatedRegression;
  try
    Application.Initialize;
    BeforeHash:=THashSHA2.GetHashStringFromFile('sample.pdf');
    PDF:=TReaderPDF.Create('pdfium.dll','sample.pdf');
    try
      for I:=0 to 1 do
      begin
        Bitmap:=PDF.Render(1,640,960,I=1);
        try
          Writeln('RASTER night=',I,' hash=',RasterHash(Bitmap),
            ' upper=',ColorToRGB(Bitmap.Canvas.Pixels[100,180]),
            ' lower=',ColorToRGB(Bitmap.Canvas.Pixels[100,850])); Flush(Output);
          if I=0 then
          begin
            Require(ColorToRGB(Bitmap.Canvas.Pixels[100,180])<>$FFFFFF,'PDF rectangle is upside down');
            Require(ColorToRGB(Bitmap.Canvas.Pixels[100,850])=$FFFFFF,'PDF bottom margin is upside down');
          end;
        finally Bitmap.Free; end;
      end;
    finally PDF.Free; end;
    Form:=TfrmBuiltinReader.Create(nil);
    try
      Form.Show; Form.OpenBook('sample.pdf','PDF','pdf-benchmark','reader-pdf-benchmark.ini','pdfium.dll');
      Require(Form.Ready,'PDF reader not ready');
      Form.SetBounds(0,0,4096,2160); Watch:=TStopwatch.StartNew; Form.ChangeSize(20);
      Raster:=Form.PageRasterSize;
      Writeln('PROFILE high_zoom_ms=',Watch.ElapsedMilliseconds,' raster=',Raster.X,'x',Raster.Y); Flush(Output);
      Sleep(200);
      Watch:=TStopwatch.StartNew;
      for I:=1 to 6 do begin Form.NextPage; Form.ToggleNight; end;
      Writeln('PROFILE six_page_night_ms=',Watch.ElapsedMilliseconds); Flush(Output);
      Form.Close;
    finally Form.Free; end;
    Require(THashSHA2.GetHashStringFromFile('sample.pdf')=BeforeHash,'Source changed');
    Writeln('PASS PDF raster orientation, hashes, high zoom and repeated page changes');
  except on E: Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); ExitCode:=1; end; end;
end.
