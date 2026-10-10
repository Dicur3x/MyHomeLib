program BuiltinReaderLibraryProbe;
{$APPTYPE CONSOLE}

uses NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  System.Diagnostics, System.Hash, Winapi.ActiveX, Vcl.Forms,
  unit_ReaderDocument, frm_BuiltinReader;

var Doc: TReaderDocument; Form: TfrmBuiltinReader; Name, BeforeHash: string;
  Clock: TStopwatch; Characters, Images, Pages, I: Integer;
begin
  RequireIsolatedRegression;
  CoInitialize(nil);
  try
    Application.Initialize;
    for Name in TDirectory.GetFiles(ExtractFilePath(ParamStr(0)), '*.fb2') do
    begin
      BeforeHash := THashSHA2.GetHashStringFromFile(Name);
      Doc := TReaderDocument.Create;
      try
        Clock := TStopwatch.StartNew;
        Doc.Load(Name);
        Characters := Length(Doc.PlainText); Images := Doc.ImageCount;
        if Characters = 0 then raise Exception.Create('No reading text');
        Writeln('DOCUMENT file=', ExtractFileName(Name), ' chars=', Characters,
          ' images=', Images, ' skipped=', Doc.SkippedImages,
          ' chapters=', Length(Doc.Chapters), ' load_ms=', Clock.ElapsedMilliseconds);
      finally Doc.Free; end;
      Form := TfrmBuiltinReader.Create(nil);
      try
        Clock := TStopwatch.StartNew;
        Form.OpenBook(Name, ExtractFileName(Name), BeforeHash,
          ExtractFilePath(ParamStr(0))+'Data\reader.ini', '');
        Form.Show;
        while not Form.LoadFinished and (Clock.ElapsedMilliseconds < 30000) do
        begin Application.ProcessMessages; CheckSynchronize(5); end;
        if not Form.Ready then raise Exception.Create(Form.ReaderStatus.Caption);
        Writeln('PICTURES expected=', Images, ' actual=', Form.PictureCount, ' text_length=', Form.TextLength);
        if Form.PictureCount <> Images then raise Exception.Create('Image count differs');
        Writeln('PRESENTATION file=', ExtractFileName(Name),
          ' load_ms=', Clock.ElapsedMilliseconds, ' text_length=', Form.TextLength);
        Clock := TStopwatch.StartNew; Pages := 0;
        for I := 1 to 10 do
        begin
          Characters := Form.TextPosition; Form.NextPage;
          if Form.TextPosition > Characters then Inc(Pages);
        end;
        Writeln('PAGES file=', ExtractFileName(Name), ' moved=', Pages,
          ' elapsed_ms=', Clock.ElapsedMilliseconds);
        Form.PreviousPage; Form.ChangeSize(1); Form.ToggleNight;
        Form.SetBounds(90, 100, 600, 480);
        Application.ProcessMessages;
        Form.SetTypography('Georgia',110,48);
        if Form.PictureCount<>Images then raise Exception.Create('Resize or style lost images');
        Form.Close;
      finally Form.Free; end;
      if BeforeHash <> THashSHA2.GetHashStringFromFile(Name) then
        raise Exception.Create('Source was modified');
      Writeln('PASS real library copy unchanged: ', ExtractFileName(Name));
    end;
    Writeln('PASS isolated real library reader probe');
  finally CoUninitialize; end;
end.
