program ReaderInitialScaleTest;
{$APPTYPE CONSOLE}
{$R '..\..\..\Program\HomeLibre.res'}
{$R '..\..\..\Program\HomeLibre.dres'}
{$R '..\..\..\Program\lang.res'}
uses NativeRegressionGuard, System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.IOUtils, System.IniFiles, System.Diagnostics, System.Math, System.Hash,
  System.Zip, Winapi.Windows, Winapi.ActiveX, Vcl.Forms, Vcl.ExtCtrls,
  Vcl.StdCtrls, Vcl.Graphics, Vcl.Imaging.pngimage, Vcl.Imaging.jpeg,
  frm_BuiltinReader, dm_user, unit_Interfaces, unit_Consts, unit_ReaderCache, unit_Globals;

procedure Require(Value: Boolean; const Text: string);
begin if not Value then raise Exception.Create(Text); end;

procedure Pump;
begin Application.ProcessMessages; CheckSynchronize(5); end;

type
  TInitialScaleProbe = class
    Timer: TTimer;
    Expected, Choose: Integer;
    Accept, Seen: Boolean;
    Failure: string;
    procedure Tick(Sender: TObject);
  end;

procedure TInitialScaleProbe.Tick(Sender: TObject);
var Dialog: TCustomForm; Choice, Layout, Current: TComboBox;
begin
  for var I:=0 to Screen.FormCount-1 do
  begin
    Dialog:=Screen.Forms[I];
    if (Dialog.Name<>'ReaderAppearanceDialog') or not Dialog.Visible then Continue;
    Timer.Enabled:=False; Seen:=True;
    try
      Choice:=Dialog.FindComponent('ReaderInitialRasterScale') as TComboBox;
      Layout:=Dialog.FindComponent('cbReaderPageLayout') as TComboBox;
      Current:=Dialog.FindComponent('ReaderRasterScale') as TComboBox;
      Require(Assigned(Choice) and Assigned(Layout) and Assigned(Current),'Missing image scale choices');
      Require((Choice.Items.Count=3) and (Choice.ItemIndex=Expected) and
        Choice.Items[2].Contains('предыдущей'),'The initial scale choice is unclear or not restored');
      Layout.ItemIndex:=Ord(rplSingle); Layout.OnChange(Layout);
      Require(Choice.Enabled and not Current.Enabled,'New-file preference is disabled in page mode');
      Layout.ItemIndex:=Ord(rplContinuous); Layout.OnChange(Layout);
      Require(Choice.Enabled and Current.Enabled,'Continuous image scale choices are disabled');
      Choice.ItemIndex:=Choose;
      Require((Choice.Left>=0) and (Choice.Top>=0) and
        (Choice.BoundsRect.Right<=Dialog.ClientWidth) and (Choice.BoundsRect.Bottom<=Dialog.ClientHeight),
        'Image scale choice is outside the dialog');
      if Accept then Dialog.ModalResult:=mrOk else Dialog.ModalResult:=mrCancel;
    except on E: Exception do begin Failure:=E.Message; Dialog.ModalResult:=mrCancel; end; end;
    Exit;
  end;
end;

procedure SetInitialScale(Reader: TfrmBuiltinReader; Expected, Choose: Integer; Accept: Boolean);
var Probe: TInitialScaleProbe;
begin
  Probe:=TInitialScaleProbe.Create;
  try
    Probe.Expected:=Expected; Probe.Choose:=Choose; Probe.Accept:=Accept;
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=20; Probe.Timer.OnTimer:=Probe.Tick;
    TButton(Reader.FindComponent('ReaderAppearance')).Click;
    Require(Probe.Seen and (Probe.Failure=''),'Scale preferences dialog: '+Probe.Failure);
  finally Probe.Timer.Free; Probe.Free; end;
end;

procedure CreateFixtures;
var Bitmap: TBitmap; PNG: TPngImage; JPEG: TJPEGImage; Zip: TZipFile;
begin
  Bitmap:=TBitmap.Create; PNG:=TPngImage.Create; JPEG:=TJPEGImage.Create;
  try
    Bitmap.SetSize(900,1800); Bitmap.Canvas.Brush.Color:=RGB(52,86,145);
    Bitmap.Canvas.FillRect(Rect(0,0,900,1800));
    Bitmap.Canvas.Pen.Color:=clWhite;
    for var Y:=0 to 17 do Bitmap.Canvas.Rectangle(15,Y*100+15,885,Y*100+85);
    PNG.Assign(Bitmap); PNG.SaveToFile('page.png');
    JPEG.Assign(Bitmap); JPEG.SaveToFile('page.jpg');
  finally JPEG.Free; PNG.Free; Bitmap.Free; end;
  for var Name in ['pages.cbz','scanned-document.zip'] do
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(Name,zmWrite); Zip.Add('page.png','001.png'); Zip.Add('page.jpg','002.jpg');
      Zip.Close;
    finally Zip.Free; end;
  end;
  TFile.WriteAllText('ordinary.txt','Ordinary text must not replace the last image scale.',TEncoding.UTF8);
end;

procedure TestInitialRasterScale;
var Reader: TfrmBuiltinReader; Ini: TMemIniFile; Profile, Name, Identity: string;
  Watch: TStopwatch; FitWidth: Integer; SourceHash: string;
  function OpenImage(const Key: string): TfrmBuiltinReader;
  var Book: TBookRecord; FileName: string;
  begin
    Result:=TfrmBuiltinReader.Create(nil);
    try
      FileName:=Name;
      if ExtractFileExt(Name)='.zip' then
      begin
        Book:=Default(TBookRecord); Book.CollectionRoot:=GetCurrentDir;
        Book.FileName:=ChangeFileExt(Name,''); Book.FileExt:='.zip';
        Book.LibID:='image-fixture'; Book.BookProps:=[bpIsLocal];
        FileName:=PrepareReaderFile(Book,True);
        Require(ExtractFileExt(FileName)='.cbz','Image archive preparation did not produce comic pages');
      end;
      Result.OpenBook(FileName,'Document with neutral title',Key,Profile,''); Result.Show;
      Watch:=TStopwatch.StartNew;
      while (not Result.Ready or Result.PageLoading) and (Watch.ElapsedMilliseconds<15000) do Pump;
      Require(Result.Ready,'Image did not open: '+Result.ReaderStatus.Caption);
      Result.SetPageLayout(rplContinuous);
      FitWidth:=Result.ReadingSurface.ClientWidth-MulDiv(24,Result.CurrentPPI,96);
    except Result.Free; raise; end;
  end;
  procedure CheckWidth(Expected: Integer);
  begin
    Watch:=TStopwatch.StartNew;
    while ((Reader.PageRasterSize.X<>Expected) or Reader.PageLoading) and
      (Watch.ElapsedMilliseconds<10000) do Pump;
    Require(Reader.PageRasterSize.X=Expected,Format('%s: expected width %d, actual %d',
      [Name,Expected,Reader.PageRasterSize.X]));
  end;
  procedure CloseImage;
  begin
    Reader.Close; Watch:=TStopwatch.StartNew;
    while Reader.Visible and (Watch.ElapsedMilliseconds<10000) do Pump;
    Require(not Reader.Visible,'Image reader did not close'); FreeAndNil(Reader);
  end;
  function ReadScaleKey(const Key: string; Default: Integer): Integer;
  begin
    Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
    try Result:=Ini.ReadInteger('Reader',Key,Default); finally Ini.Free; end;
  end;
begin
  CreateFixtures;
  for Name in ['page.png','page.jpg','pages.cbz','scanned-document.zip'] do
  begin
    Profile:=Name+'.ini'; SourceHash:=THashSHA2.GetHashStringFromFile(Name);
    Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
    try Ini.WriteInteger('Reader','PageLayout',Ord(rplContinuous)); Ini.UpdateFile; finally Ini.Free; end;
    Reader:=OpenImage('book-A');
    try
      CheckWidth(FitWidth); SetInitialScale(Reader,0,1,True);
      CheckWidth(FitWidth); // Choosing a future default must not resize this book.
      CloseImage;
    finally Reader.Free; end;
    Require(ReadScaleKey('InitialRasterScale',-1)=1,'Original-size preference was not saved');
    Reader:=OpenImage('book-B');
    try
      CheckWidth(900); SetInitialScale(Reader,1,0,False); CheckWidth(900); CloseImage;
    finally Reader.Free; end;
    Require(ReadScaleKey('InitialRasterScale',-1)=1,'Cancel saved the changed preference');
    Reader:=OpenImage('book-C');
    try
      CheckWidth(900); SetInitialScale(Reader,1,2,True); CloseImage;
    finally Reader.Free; end;
    Reader:=OpenImage('book-previous-original');
    try
      CheckWidth(900); Reader.ChangeSize(3);
      CheckWidth(MulDiv(FitWidth,130,100)); CloseImage;
    finally Reader.Free; end;
    Require((ReadScaleKey('InitialRasterScale',-1)=2) and (ReadScaleKey('LastRasterZoom',-1)=130),
      'Previous image scale was not saved');
    Reader:=OpenImage('book-D');
    try
      CheckWidth(MulDiv(FitWidth,130,100)); SetInitialScale(Reader,2,0,True); CloseImage;
    finally Reader.Free; end;
    Reader:=OpenImage('book-A');
    try CheckWidth(FitWidth); CloseImage; finally Reader.Free; end;
    Reader:=OpenImage('book-B');
    try CheckWidth(900); CloseImage; finally Reader.Free; end;
    Reader:=OpenImage('book-C');
    try CheckWidth(900); CloseImage; finally Reader.Free; end;
    Reader:=OpenImage('book-E');
    try CheckWidth(FitWidth); CloseImage; finally Reader.Free; end;
    // An old profile containing only per-book zoom still overrides a new default.
    Identity:='Book.'+Copy(THashSHA2.GetHashString('old-book'),1,40);
    Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
    try
      Ini.WriteInteger(Identity,'Zoom',80); Ini.WriteInteger('Reader','InitialRasterScale',1);
      Ini.WriteInteger('Reader','LastRasterZoom',170); Ini.WriteBool('Reader','LastRasterOriginalScale',True);
      Ini.UpdateFile;
    finally Ini.Free; end;
    Reader:=OpenImage('old-book');
    try CheckWidth(MulDiv(FitWidth,80,100)); CloseImage; finally Reader.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Name)=SourceHash,'Initial-scale regression changed its source');
    Writeln('PASS initial image scale ',Name,' fit original previous cancel and existing-book priority');
  end;
  Name:='ordinary.txt'; Profile:='page.png.ini';
  Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
  try
    Ini.WriteInteger('Reader','LastRasterZoom',170); Ini.WriteBool('Reader','LastRasterOriginalScale',True);
    Ini.UpdateFile;
  finally Ini.Free; end;
  Reader:=OpenImage('ordinary-text');
  try
    Require(Reader.PDFZoom=100,'Image preferences changed ordinary text zoom'); CloseImage;
  finally Reader.Free; end;
  Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
  try
    Require((Ini.ReadInteger('Reader','LastRasterZoom',0)=170) and
      Ini.ReadBool('Reader','LastRasterOriginalScale',False),'Ordinary text overwrote the previous image scale');
  finally Ini.Free; end;
  Writeln('PASS ordinary text leaves previous image scale unchanged');
end;

begin
  RequireIsolatedRegression; CoInitialize(nil);
  try
    Application.Initialize;
    Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    TestInitialRasterScale;
    Writeln('PASS initial raster scale regression');
  except on E: Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); Flush(Output); Halt(1); end; end;
  CoUninitialize;
end.
