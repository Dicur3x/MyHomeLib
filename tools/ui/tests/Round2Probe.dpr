program Round2Probe;
{$APPTYPE CONSOLE}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}
uses System.SysUtils, System.StrUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  System.Types, Winapi.Windows, Vcl.Forms, Vcl.Controls, Vcl.Graphics,
  Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.ComCtrls, VirtualTrees, VirtualTrees.Types, BookTreeView, unit_Globals, unit_Consts,
  unit_BookColumnFilters, unit_BookGallery, unit_FB2Utils, unit_ReaderCache, unit_SearchUtils, unit_MHLOperationStatus, unit_BookCache, unit_SeriesAliases,
  unit_Interfaces, unit_Settings, unit_Localization, unit_Columns, System.IniFiles, SQLiteWrap, System.Variants, System.Zip, dm_user, NativeRegressionGuard,
  unit_ReaderLaunch, unit_ReaderFormats, unit_ReaderOffice, unit_ReaderPDF, System.Diagnostics, System.Hash,
  unit_CatalogSources, unit_CollectionMerge, frm_CatalogSources;
type
  TDialogProbe = class
    Timer: TTimer;
    Cancel, Remember, ExpectBuiltin: Boolean;
    Seen: Boolean;
    procedure Respond(Sender: TObject);
  end;
  TProbe = class
    procedure FreeBook(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure Text(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex;
      TextType: TVSTTextType; var CellText: string);
  end;
procedure Require(Condition: Boolean; const Text: string); forward;
procedure Pump(Duration: Cardinal); forward;
procedure TDialogProbe.Respond(Sender: TObject);
var Dialog: TForm; I: Integer; List: TListBox; HasBuiltin: Boolean; Bitmap: TBitmap;
begin
  Dialog:=Screen.ActiveCustomForm as TForm;
  if not Assigned(Dialog) or (Dialog.Caption<>'Где открыть книгу?') then Exit;
  Timer.Enabled:=False; Seen:=True; List:=nil;
  for I:=0 to Dialog.ControlCount-1 do
  begin
    if Dialog.Controls[I] is TListBox then List:=TListBox(Dialog.Controls[I]);
    if Dialog.Controls[I] is TCheckBox then TCheckBox(Dialog.Controls[I]).Checked:=Remember;
  end;
  HasBuiltin:=Assigned(List) and (List.Items.Count>0) and ContainsText(List.Items[0],'Встроенная');
  if HasBuiltin<>ExpectBuiltin then begin Dialog.ModalResult:=mrCancel; raise Exception.Create('Reader choice capability incorrect'); end;
  if Assigned(List) then List.ItemIndex:=0;
  Bitmap:=Dialog.GetFormImage; try Bitmap.SaveToFile('reader-choice.bmp'); finally Bitmap.Free; end;
  if Cancel then Dialog.ModalResult:=mrCancel else Dialog.ModalResult:=mrOk;
end;

procedure ReaderChoices;
const MobiMagic: array[0..7] of AnsiChar = ('B','O','O','K','M','O','B','I');
var Probe: TDialogProbe; Builtin, Accepted: Boolean; Path, Prepared, Hash: string; Ini: TMemIniFile;
  Bytes: TBytes;
begin
  RequireIsolatedRegression; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  SetLength(Bytes,68);
  Bytes[0]:=$49; Bytes[1]:=$49; Bytes[2]:=$2A; Bytes[3]:=0;
  TFile.WriteAllBytes('scan.1121-84',Bytes);
  Hash:=THashSHA2.GetHashStringFromFile('scan.1121-84');
  Require(DetectReaderExtension('scan.1121-84')='.tif','Numeric TIFF filename was not recognized');
  Prepared:=PrepareDetectedReaderFile('scan.1121-84','scan.1121-84');
  Require(SameText(ExtractFileExt(Prepared),'.tif') and
    (THashSHA2.GetHashStringFromFile(Prepared)=Hash) and
    (THashSHA2.GetHashStringFromFile('scan.1121-84')=Hash),'TIFF detection changed source bytes');
  Bytes[0]:=$4D; Bytes[1]:=$4D; Bytes[2]:=0; Bytes[3]:=$2A;
  TFile.WriteAllBytes('scan-big-endian.325949',Bytes);
  Require(DetectReaderExtension('scan-big-endian.325949')='.tif','Big-endian TIFF was not recognized');
  FillChar(Bytes[0],Length(Bytes),0);
  Move(MobiMagic[0],Bytes[60],8);
  TFile.WriteAllBytes('book.mob',Bytes);
  Require(DetectReaderExtension('book.mob')='.mobi','MOB alias header was not recognized');
  Bytes[60]:=0; Move(MobiMagic[0],Bytes[10],8);
  TFile.WriteAllBytes('ordinary.txt',Bytes);
  Require(DetectReaderExtension('ordinary.txt')='','MOBI marker outside its header position was accepted');
  Writeln('PASS TIFF endian signatures and MOB alias select detected copies without changing source');
  Probe:=TDialogProbe.Create;
  try
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False; Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Respond;
    Probe.ExpectBuiltin:=True; Probe.Remember:=True; Probe.Timer.Enabled:=True;
    Accepted:=ChooseBookReader(nil,'test.pdf','.pdf',Builtin,Path,True);
    Require(Accepted and Builtin and Probe.Seen,'Builtin reader choice failed');
    Probe.Seen:=False;
    Require(Settings.UseBuiltinReaderByDefault,'Fresh profile must prefer builtin reader');
    Require(ChooseBookReader(nil,'test.pdf','.pdf',Builtin,Path) and Builtin and not Probe.Seen,'Saved choice reopened dialog');
    Settings.UseBuiltinReaderByDefault:=False;
    Require(ChooseBookReader(nil,'test.pdf','.pdf',Builtin,Path) and not Builtin and not Probe.Seen,'Disabled default ignored saved builtin choice');
    Settings.UseBuiltinReaderByDefault:=True;
    Require(ChooseBookReader(nil,'unknown.rgo','.rgo',Builtin,Path) and not Builtin and not Probe.Seen,'Unsupported automatic format did not fall back externally');
    Probe.Cancel:=True; Probe.Timer.Enabled:=True;
    Require(not ChooseBookReader(nil,'test.pdf','.pdf',Builtin,Path,True),'Forced choice ignored cancellation');
    Ini:=TMemIniFile.Create(Settings.DataDir+'reader.ini',TEncoding.UTF8);
    try Require(Ini.ReadString('OpenWith','.pdf','')='@builtin','Cancellation erased saved choice'); finally Ini.Free; end;
    Probe.Cancel:=False; Probe.Remember:=False; Probe.Timer.Enabled:=True;
    Require(ChooseBookReader(nil,'test.pdf','.pdf',Builtin,Path,True) and Builtin,'Forced builtin choice failed');
    Ini:=TMemIniFile.Create(Settings.DataDir+'reader.ini',TEncoding.UTF8);
    try Require(Ini.ReadString('OpenWith','.pdf','')='','Unchecking remember did not clear choice'); finally Ini.Free; end;
    Probe.ExpectBuiltin:=FindReaderOffice<>''; Probe.Cancel:=True; Probe.Timer.Enabled:=True;
    Require(not ChooseBookReader(nil,'presentation.ppt','.ppt',Builtin,Path,True),'Unsupported format dialog cancellation ignored');
    Probe.ExpectBuiltin:=True; Probe.Cancel:=False; Probe.Remember:=True; Probe.Timer.Enabled:=True;
    Require(ChooseBookReader(nil,'test.pdf','.325949',Builtin,Path,True) and Builtin,'Detected format choice failed');
    Ini:=TMemIniFile.Create(Settings.DataDir+'reader.ini',TEncoding.UTF8);
    try
      Require(Ini.ReadString('OpenWith','.pdf','')='@builtin','Malformed extension preference not normalized');
      Require(Ini.ReadString('OpenWith','.325949','')='','Malformed extension saved as preference key');
    finally Ini.Free; end;
    Writeln('Archive manager: ',FindArchiveManager);
    Writeln('PASS reader choices capability, remember, force/cancel and removal of saved choice');
  finally Probe.Timer.Free; Probe.Free; DMUser.Free; DMUser:=nil; end;
end;

procedure ReaderCacheStamps;
var Bytes: TBytes; Prepared, Updated, Hash: string; Locked: TFileStream;
  SavedFormat: TFormatSettings;
begin
  RequireIsolatedRegression; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    SetLength(Bytes,68); Bytes[0]:=$49; Bytes[1]:=$49; Bytes[2]:=$2A;
    TFile.WriteAllBytes('changed.1121-84',Bytes);
    TFile.SetLastWriteTimeUtc('changed.1121-84',EncodeDate(2026,10,10)+EncodeTime(6,0,0,100));
    Prepared:=PrepareDetectedReaderFile('changed.1121-84','cache-stamp-test');
    Require(THashSHA2.GetHashStringFromFile(Prepared)=THashSHA2.GetHashStringFromFile('changed.1121-84'),'Initial detected copy differs');
    Bytes[12]:=42; TFile.WriteAllBytes('changed.1121-84',Bytes);
    TFile.SetLastWriteTimeUtc('changed.1121-84',EncodeDate(2026,10,10)+EncodeTime(6,0,0,200));
    Hash:=THashSHA2.GetHashStringFromFile('changed.1121-84');
    Updated:=PrepareDetectedReaderFile('changed.1121-84','cache-stamp-test');
    Require(THashSHA2.GetHashStringFromFile(Updated)=Hash,'Same-size replacement within one second reused stale detected copy');
    SavedFormat:=FormatSettings;
    try
      FormatSettings.ShortDateFormat:='yyyy/MM/dd'; FormatSettings.DateSeparator:='/';
      FormatSettings.LongTimeFormat:='hh:nn:ss.zzz';
      Require(PrepareDetectedReaderFile('changed.1121-84','cache-stamp-test')=Updated,'Locale change duplicated detected copy');
    finally FormatSettings:=SavedFormat; end;
    Locked:=TFileStream.Create('changed.1121-84',fmOpenRead or fmShareExclusive);
    try
      Require(PrepareDetectedReaderFile('changed.1121-84','cache-stamp-test')=Updated,'Detected cache hit reopened exclusively locked source');
    finally Locked.Free; end;
    Require(THashSHA2.GetHashStringFromFile('changed.1121-84')=Hash,'Detected cache changed source');
    Writeln('PASS detected cache subsecond replacement, locale-independent key and locked-source hit');
  finally DMUser.Free; DMUser:=nil; end;
end;

procedure OfficeReader;
var Prepared, Second, Hash: string; PDF: TReaderPDF; Match: TPDFMatch;
  Watch: TStopwatch; Canceled: Boolean; Checks: Integer; Book: TBookRecord;
begin
  RequireIsolatedRegression; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    Require(FindReaderOffice<>'','LibreOffice runtime unavailable for this optional integration test');
    Require(DetectReaderExtension('office-sample.odp')='.odp','Office presentation misidentified as loose ZIP');
    Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath;
    Book.FileName:='office-sample'; Book.FileExt:='.odp';
    Hash:=THashSHA2.GetHashStringFromFile('office-sample.odp'); Watch:=TStopwatch.StartNew;
    Prepared:=PrepareReaderFile(Book,True,nil,False,False,True);
    Writeln('PROFILE Office PDF preparation_ms=',Watch.ElapsedMilliseconds);
    Require(SameText(ExtractFileExt(Prepared),'.pdf') and FileExists(Prepared),'Office preparation did not publish PDF');
    PDF:=TReaderPDF.Create('pdfium.dll',Prepared);
    try
      Require(PDF.PageCount=2,'Office PDF lost a slide');
      Require(PDF.FindOnPage(0,'Office needle',0,Match),'Office slide text not readable');
    finally PDF.Free; end;
    Watch:=TStopwatch.StartNew;
    Second:=PrepareOfficeReaderFile(Settings.AppPath+'office-sample.odp',Settings.AppPath+'office-sample.odp');
    Require((Second=Prepared) and (Watch.ElapsedMilliseconds<1000),'Office cache failed to avoid conversion');
    Writeln('PROFILE Office cached_open_ms=',Watch.ElapsedMilliseconds);
    Require(THashSHA2.GetHashStringFromFile('office-sample.odp')=Hash,'Office conversion changed source');
    Hash:=THashSHA2.GetHashStringFromFile('office-sample.ppt');
    Prepared:=PrepareOfficeReaderFile(Settings.AppPath+'office-sample.ppt',Settings.AppPath+'office-sample.ppt');
    PDF:=TReaderPDF.Create('pdfium.dll',Prepared);
    try Require((PDF.PageCount=2) and PDF.FindOnPage(0,'Office needle',0,Match),'Legacy PPT conversion lost slides/text');
    finally PDF.Free; end;
    Require(THashSHA2.GetHashStringFromFile('office-sample.ppt')=Hash,'Legacy PPT conversion changed source');
    Canceled:=False; Checks:=0;
    try
      PrepareOfficeReaderFile(Settings.AppPath+'office-cancel.odp',Settings.AppPath+'office-cancel.odp',nil,
        function: Boolean begin Inc(Checks); Result:=Checks>3; end);
    except on E: EAbort do Canceled:=True; end;
    Require(Canceled and (Checks>3),'Office helper ignored cancellation after launch');
    Require(Length(TDirectory.GetDirectories(Settings.TempDir,'homelib-office-*'))=0,'Office helper left temporary conversion profiles');
    Writeln('PASS Office ODP/PPT PDF slides/text/cache/source preservation and process cancellation');
  finally DMUser.Free; DMUser:=nil; end;
end;

function FindControl(Control: TWinControl; Kind: TClass; const Caption: string = ''): TControl;
var I: Integer;
begin
  Result:=nil;
  for I:=0 to Control.ControlCount-1 do
  begin
    if Control.Controls[I].InheritsFrom(Kind) then
      if (Caption='') or ((Control.Controls[I] is TButton) and (TButton(Control.Controls[I]).Caption=Caption)) then Exit(Control.Controls[I]);
    if Control.Controls[I] is TWinControl then
    begin Result:=FindControl(TWinControl(Control.Controls[I]),Kind,Caption); if Assigned(Result) then Exit; end;
  end;
end;

procedure SourcesWindow;
var C: IBookCollection; ID: Integer; Form: TfrmCatalogSources; Sources: TCatalogSources;
  List: TListView; B: TButton; Book: TBookRecord; First: string; Bitmap: TBitmap;
begin
  RequireIsolatedRegression; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    ID:=SystemDB.CreateCollection('Sources regression',Settings.AppPath,'sources.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    C:=SystemDB.GetCollection(ID); SetLength(Sources,2);
    Sources[0].ID:=TCatalogSource.NewID; Sources[0].Name:='Mixed library'; Sources[0].INPXFile:=Settings.AppPath+'missing.inpx';
    Sources[0].Root:=Settings.AppPath; Sources[0].LibraryNamespace:='mixed';
    Sources[1].ID:=TCatalogSource.NewID; Sources[1].Name:='Missing folder'; Sources[1].INPXFile:=Settings.AppPath+'missing2.inpx';
    Sources[1].Root:=Settings.AppPath+'absent'; Sources[1].LibraryNamespace:='flibusta'; SaveCatalogSources(C,Sources);
    Form:=TfrmCatalogSources.CreateForCollection(nil,C);
    try
      if FileExists('sources-preview.marker') then begin Form.ShowModal; Exit; end;
      Form.Show; Pump(100);
      List:=TListView(FindControl(Form,TListView)); Require(Assigned(List) and (List.Items.Count=2),'Sources not shown');
      B:=TButton(FindControl(Form,TButton,'1. Обновить список книг'));
      Require((List.Top>0) and Assigned(B) and (B.Parent.Top>=List.Top+List.Height),'Source panels appear in reversed order');
      B:=TButton(FindControl(Form,TButton,'Закрыть'));
      Require(Assigned(B) and (B.Left>=0) and (B.Left+B.Width<=B.Parent.ClientWidth),'Source close button is outside the window');
      Require((List.Columns.Count=5) and (List.Items[0].SubItems[2]='Флибуста + Либрусек'),'Mixed library not described');
      Require((List.Items[0].SubItems[3]='INPX не найден') and (List.Items[1].SubItems[3]='Нет папки книг'),'Missing source diagnostics wrong');
      B:=TButton(FindControl(Form,TButton,'3. Применить объединение')); Require(Assigned(B) and not B.Enabled,'Apply enabled without preview');
      List.Items[0].Selected:=True; Pump(30);
      Require(not TButton(FindControl(Form,TButton,'↑')).Enabled,'Move first source up enabled');
      Require(TButton(FindControl(Form,TButton,'↓')).Enabled,'Move first source down disabled');
      List.Items[1].Selected:=True; Pump(30);
      Require(TButton(FindControl(Form,TButton,'↑')).Enabled,'Move last source up disabled');
      Require(not TButton(FindControl(Form,TButton,'↓')).Enabled,'Move last source down enabled');
      Bitmap:=Form.GetFormImage; try Bitmap.SaveToFile('sources-window.bmp'); finally Bitmap.Free; end;
      Form.Close;
    finally Form.Free; end;
    Sources[0].ID:='broken-id'; Sources[0].INPXFile:=Settings.AppPath+'present.inpx';
    TFile.WriteAllText(Sources[0].INPXFile,'test'); SaveCatalogSources(C,Sources);
    Form:=TfrmCatalogSources.CreateForCollection(nil,C);
    try
      Form.Show; Pump(50); List:=TListView(FindControl(Form,TListView));
      Require(List.Items[0].SubItems[3]='Повреждена запись источника','Malformed source ID crashed or remained unclear');
      Form.Close;
    finally Form.Free; end;
    Book:=Default(TBookRecord); Book.Title:='A book'; Book.Size:=1024; Book.Lang:='ru'; Book.FileExt:='.fb2'; Book.LibID:='123';
    Require(BookLibraryIdentity(Book,'mixed')='','Mixed library blindly trusted naked numeric ID');
    First:=BookLibraryIdentity(Book,'flibusta'); Require(First<>'','Known library identity missing');
    Require(First<>BookLibraryIdentity(Book,'librusec'),'Library ID collision merged');
    Book.LibID:='flibusta:123'; Require(BookLibraryIdentity(Book,'mixed')=First,'Qualified mixed ID not recognized');
    Writeln('PASS sources descriptions/states/selection, preview gate, mixed-library identity safety');
  finally C:=nil; DMUser.Free; DMUser:=nil; end;
end;
procedure TProbe.FreeBook(Sender: TBaseVirtualTree; Node: PVirtualNode);
begin Finalize(PBookRecord(Sender.GetNodeData(Node))^); end;
procedure TProbe.Text(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex;
  TextType: TVSTTextType; var CellText: string);
begin CellText:=PBookRecord(Sender.GetNodeData(Node))^.Title; end;
procedure Images(const FileName: string);
var Loader: TGalleryLoader; Picture: TGalleryPicture; Bitmap: TBitmap; Image: TImage;
  X,Y: Integer; Colors: TDictionary<TColor,Byte>; Source: TFunc<TStream>;
begin
  Source:=function: TStream begin Result:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite); end;
  Loader:=TGalleryLoader.Create(Source,'.fb2'); Loader.FreeOnTerminate:=False;
  Bitmap:=TBitmap.Create; Colors:=TDictionary<TColor,Byte>.Create; Image:=TImage.Create(nil);
  try
    Loader.Start; Loader.WaitFor;
    Writeln('Gallery pictures=',Loader.Pictures.Count,' placeholders=',Loader.PlaceholderCount,' error=',Loader.ErrorText);
    for Picture in Loader.Pictures do
    begin
      Image.Picture.Assign(Picture.Graphic);
      Bitmap.SetSize(64,64); Bitmap.Canvas.Brush.Color:=clGray; Bitmap.Canvas.FillRect(Rect(0,0,64,64));
      Bitmap.Canvas.StretchDraw(Rect(0,0,64,64),Image.Picture.Graphic); Colors.Clear;
      for Y:=0 to 63 do for X:=0 to 63 do Colors.TryAdd(Bitmap.Canvas.Pixels[X,Y],0);
      Writeln('IMAGE ',Picture.Name,' ',Picture.Graphic.ClassName,' ',Picture.Graphic.Width,'x',Picture.Graphic.Height,
        ' empty=',Picture.Graphic.Empty,' colors=',Colors.Count); Flush(Output);
    end;
  finally Image.Free; Colors.Free; Bitmap.Free; Loader.Free; end;
end;
procedure Require(Condition: Boolean; const Text: string);
begin if not Condition then raise Exception.Create(Text); end;
procedure Pump(Duration: Cardinal);
var Started: UInt64;
begin
  Started := GetTickCount64;
  repeat Application.ProcessMessages; CheckSynchronize(0); Sleep(10);
  until GetTickCount64-Started >= Duration;
end;
function HideOwnHint(Window: HWND; Parameter: LPARAM): BOOL; stdcall;
var Name: array[0..127] of Char; ProcessID: Cardinal;
begin
  Result := True; GetWindowThreadProcessId(Window,@ProcessID);
  if ProcessID <> GetCurrentProcessId then Exit;
  GetClassName(Window,Name,Length(Name));
  if ContainsText(string(Name),'HintWindow') and IsWindowVisible(Window) then
  begin ShowWindow(Window,SW_HIDE); Inc(PInteger(Parameter)^); end;
end;
procedure StatusRecovery;
var Status: TMHLOperationStatus; Hidden, I: Integer;
begin
  Status := TMHLOperationStatus.Create('Проверка подсказки при распаковке…');
  try
    Require(not Status.Visible,'Fast operation flashed cursor status'); Pump(550);
    Require(Status.Visible,'Status did not appear after delay');
    for I := 1 to 5 do
    begin
      Hidden := 0; EnumThreadWindows(GetCurrentThreadID,@HideOwnHint,LPARAM(@Hidden));
      Require(Hidden=1,'Isolated status hint window not found');
      Require(not Status.Visible,'Forced hint hiding did not take effect'); Pump(150);
      Require(Status.Visible,'Unchanged cursor status did not recover after hiding');
    end;
  finally Status.Free; end;
  Writeln('PASS delayed cursor status recovers after five forced hides without changing text');
end;
procedure AsyncRead;
var Owner: TForm; Book: TBookRecord; Ready: Boolean; Started, Last, Gap, MaxGap: UInt64;
  Ticks: Integer; FileName: string; Status: TMHLOperationStatus;
begin
  RequireIsolatedRegression;
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  Owner := TForm.CreateNew(nil); Owner.Caption := 'HomeLib Ru — проверка фоновой распаковки';
  Owner.SetBounds(80,80,600,280); Owner.Show; Pump(100);
  try
    ClearBookCache;
    Status := TMHLOperationStatus.Create('Проверка статуса распаковки…');
    try Pump(550); Require(Status.Visible,'Long-operation status did not become visible');
      Pump(200); Require(Status.Visible,'Unchanged status vanished');
    finally Status.Free; end;
    Book := Default(TBookRecord); Book.CollectionRoot := ExtractFilePath(ParamStr(2));
    Book.Folder := ExtractFileName(ParamStr(2)); Book.FileName := '793007'; Book.FileExt := '.fb2';
    Started := GetTickCount64; Ready := False; FileName := '';
    PrepareReaderFileInBackground(Owner,Book,True,
      procedure(Name: string) begin FileName := Name; Ready := True; end);
    Require(GetTickCount64-Started < 500,'Preparation blocked initial UI call');
    Ticks := 0; MaxGap := 0; Last := GetTickCount64;
    while not Ready and (GetTickCount64-Started < 30000) do
    begin
      Application.ProcessMessages; CheckSynchronize(0); Sleep(10); Inc(Ticks);
      Gap := GetTickCount64-Last; if Gap > MaxGap then MaxGap := Gap; Last := GetTickCount64;
    end;
    Require(Ready and FileExists(FileName),'Background extraction did not complete');
    Writeln('PROFILE async cold book ms=',GetTickCount64-Started,' UI ticks=',Ticks,' largest gap ms=',MaxGap);
    Require(MaxGap < 1000,'UI event loop froze during extraction');
    ClearBookCache; Ready := False;
    PrepareReaderFileInBackground(Owner,Book,True,procedure(Name: string) begin Ready := True; end);
    CancelReaderPreparations(Owner); Pump(200);
    Require(not Ready,'Reader callback ran after cancellation');
    Writeln('PASS background extraction, status visibility, owner cancellation'); Flush(Output);
  finally Owner.Free; FinishBookCacheSession; DMUser.Free; DMUser := nil; end;
end;
procedure Kindle;
var Book: TBookRecord; Prepared, Again: string; Started: UInt64;
begin
  RequireIsolatedRegression; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    Book := Default(TBookRecord); Book.CollectionRoot := ExtractFilePath(ParamStr(2));
    Book.FileName := ChangeFileExt(ExtractFileName(ParamStr(2)),''); Book.FileExt := '.azw3';
    Started := GetTickCount64; Prepared := PrepareReaderFile(Book,True,nil,False,True);
    Require(SameText(ExtractFileExt(Prepared),'.epub') and FileExists(Prepared),'KF8 was not prepared as EPUB');
    Writeln('PROFILE native Kindle first ms=',GetTickCount64-Started,' file=',Prepared);
    Started := GetTickCount64; Again := PrepareReaderFile(Book,True,nil,False,True);
    Require(SameFileName(Again,Prepared),'Repeated Kindle preparation bypassed cache');
    Writeln('PROFILE native Kindle cached ms=',GetTickCount64-Started);
    Writeln('PASS native Kindle compatibility cache'); Flush(Output);
  finally DMUser.Free; DMUser := nil; end;
end;
procedure SearchSpellings;
var Filter, Word: string; DB: TSQLiteDatabase;
begin
  Filter := ''; AddToFilter('Title',PrepareQuery('Конек',True),True,Filter);
  Require(Filter.Contains('REPLACE'),'Search does not normalize e/yo');
  Filter := ''; AddToFilter('Title',PrepareQuery('Books',True),True,Filter);
  Require(not Filter.Contains('REPLACE'),'LIKE operator disabled unrelated search indexes');
  DB := TSQLiteDatabase.Create(':memory:');
  try
    DB.ExecSQL('CREATE TABLE Spellings(Title TEXT)');
    DB.ExecSQL('INSERT INTO Spellings VALUES (''Конек''),(''Конёк''),(''Books'')');
    for Word in ['Конек','Конёк'] do
    begin
      Filter := ''; AddToFilter('Title',PrepareQuery(Word,False),False,Filter);
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Spellings WHERE '+Filter)=2,'SQL e/yo matching is asymmetric');
    end;
  finally DB.Free; end;
  Writeln('PASS search e/yo literals and unrelated indexed expressions');
end;
procedure SeriesAliases;
var C: IBookCollection; ID, Tagged, Plain, Other, A: Integer; B, GroupBook: TBookRecord;
  Plan: TSeriesAliasPlan; DB: TSQLiteDatabase; Folder, FileName: string; Cancelled, Rejected: Boolean;
  function Add(const Title, Author, Series: string): Integer;
  var Book: TBookRecord;
  begin
    Book := Default(TBookRecord); Book.Title:=Title; Book.FileName:=Title;
    Book.FileExt:='.fb2'; Book.LibID:=Title; Book.Series:=Series; Book.Size:=100;
    TAuthorsHelper.Add(Book.Authors,Author,'',''); Include(Book.BookProps,bpIsLocal);
    Result:=C.InsertBook(Book,False,False);
  end;
  function Scalar(const SQL: string): Integer;
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(FileName);
    try Result:=DB.QuerySingleInt(SQL); finally DB.Free; end;
  end;
begin
  RequireIsolatedRegression; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    ID:=SystemDB.CreateCollection('Series alias regression',Settings.AppPath,
      'aliases-'+TGUID.NewGuid.ToString+'.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    C:=SystemDB.GetCollection(ID); FileName:=Settings.ExpandCollectionFileName(VarToStr(C.GetProperty(PROP_DATAFILE)));
    Plain:=Add('First','Douglas Adams','Автостопом по Галактике');
    Tagged:=Add('Second','Douglas Adams','Автостопом по Галактике[a]');
    C.SetRate(CreateBookKey(Tagged,ID),4); C.SetProgress(CreateBookKey(Tagged,ID),37);
    C.AddBookToGroup(CreateBookKey(Tagged,ID),FAVORITES_GROUP_ID);
    Other:=Add('Publisher','Douglas Adams','Автостопом по Галактике[p]');
    Add('Author conflict one','Different one','Shared'); Add('Author conflict two','Different two','Shared[a]');
    Add('Double bracket one','Same','Double'); Add('Double bracket two','Same','Double[[a]]');
    C.AddBookSeries(Tagged,'Other cycle',2);
    Plan:=TSeriesAliasPlan.Create(C,SystemDB);
    try
      Plan.Preview(nil); Require(Plan.Count=2,'Aliases include publisher or conflicting authors, or miss [[a]]');
      Cancelled:=False; Folder:=Settings.DataDir+'alias-cancel-'+TGUID.NewGuid.ToString;
      Rejected:=False;
      try Plan.Apply(Folder,
        procedure(const Stage: string; Current, Total: Integer)
        begin if Stage='Объединение названий серий' then Cancelled:=True; end,
        function: Boolean begin Result:=Cancelled; end);
      except on E:EAbort do Rejected:=True; end;
      Require(Rejected and (Scalar('SELECT COUNT(*) FROM Series WHERE SeriesTitle LIKE ''%[a]''')=2),
        'Cancelled alias changes were committed');
      Plan.Preview(nil); Folder:=Settings.DataDir+'alias-success-'+TGUID.NewGuid.ToString;
      Plan.Apply(Folder,nil,nil);
      Require(FileExists(Folder+'\destination.hlc2') and FileExists(Folder+'\system.hlc2'),'Alias backup incomplete');
      Require(Scalar('SELECT COUNT(*) FROM Books')=7,'Alias normalization changed book count');
      Require(Scalar('SELECT COUNT(*) FROM Series WHERE SeriesTitle=''Автостопом по Галактике[a]''')=0,'Author alias remains');
      Require(Scalar('SELECT COUNT(*) FROM Series WHERE SeriesTitle=''Автостопом по Галактике[p]''')=1,'Publisher cycle was removed');
      C.GetBookRecord(CreateBookKey(Tagged,ID),B,False); C.GetBookRecord(CreateBookKey(Plain,ID),GroupBook,False);
      Require((B.SeriesID=GroupBook.SeriesID) and (B.Rate=4) and (B.Progress=37),'Alias merge lost primary series or user values');
      SystemDB.GetBookRecord(CreateBookKey(Tagged,ID),GroupBook);
      Require(GroupBook.SeriesID=B.SeriesID,'Favorite group series mirror is stale');
      Require(Length(C.GetBookSeries(CreateBookKey(Tagged,ID)))=2,'Additional membership was removed');
      Plan.Preview(nil); Require(Plan.Count=0,'Alias normalization is not idempotent');
      Add('Stale clean','Stale','Stale'); Add('Stale tagged','Stale','Stale[a]'); Plan.Preview(nil);
      A:=Add('After preview','After',''); Rejected:=False;
      try Plan.Apply(Settings.DataDir+'alias-stale-'+TGUID.NewGuid.ToString,nil,nil);
      except on E:Exception do Rejected:=True; end;
      Require(Rejected and (A>0),'Stale alias preview was accepted');
      Writeln('PASS series aliases preserve editions, memberships, user values, groups; rollback, backup, stale preview, idempotence');
    finally Plan.Free; end;
  finally C:=nil; DMUser.Free; DMUser:=nil; end;
end;
procedure Widths;
var Form: TForm; Tree: TBookTree; Probe: TProbe; Node: PVirtualNode; Book: PBookRecord;
  Filters: TBookColumnFilters; Names: TStringList; I: Integer; Started: UInt64;
begin
  Probe:=TProbe.Create; Form:=TForm.CreateNew(nil); Names:=TStringList.Create;
  try
    Form.SetBounds(80,80,900,600); Tree:=TBookTree.Create(Form); Tree.Parent:=Form; Tree.Align:=alClient;
    Tree.NodeDataSize:=SizeOf(TBookRecord); Tree.OnFreeNode:=Probe.FreeBook; Tree.OnGetText:=Probe.Text;
    Tree.Header.Options:=Tree.Header.Options+[hoVisible,hoColumnResize];
    with Tree.Header.Columns.Add do begin Text:='Название'; Tag:=COL_TITLE; Width:=400; end;
    Tree.BeginUpdate;
    try for I:=1 to 500000 do
    begin
      Node:=Tree.AddChild(nil); Book:=Tree.GetNodeData(Node); Book^:=Default(TBookRecord);
      Book.NodeType:=ntBookInfo; Book.Title:=Format('Книга %.6d',[I]); Book.Series:='Серия '+IntToStr(I mod 100000);
    end; finally Tree.EndUpdate; end;
    Form.Show; Application.ProcessMessages; Filters:=TBookColumnFilters.ForTree(Tree);
    Started:=GetTickCount64; Filters.GetOptions(COL_SERIES,Names);
    Writeln('PROFILE options 500000 rows / ',Names.Count,' values ms=',GetTickCount64-Started); Flush(Output);
    Started:=GetTickCount64; Filters.GetOptions(COL_SERIES,Names);
    Writeln('PROFILE cached options ms=',GetTickCount64-Started);
    if ParamStr(1)='popup' then begin EditBookColumnFilter(Tree,COL_SERIES); Exit; end;
    Names.Clear; Names.Add('Серия 1'); Names.Add('Серия 2'); Filters.SetSelectedValues(COL_SERIES,Names);
    Require(Filters.Apply=10,'Multiple exact series failed');
    Names.Add('Серия 3'); Filters.SetSelectedValues(COL_SERIES,Names);
    Require(Filters.Apply=15,'Expanding selection omitted previously hidden rows');
    Filters.Clear; Names.Clear;
    for I:=1 to 15 do Names.Add('Серия '+IntToStr(I*6000));
    Filters.SetSelectedValues(COL_SERIES,Names); Require(Filters.Apply=75,'Distributed sparse result count incorrect');
    Pump(600); Node:=Tree.GetFirstVisibleNoInit; I:=0;
    while Assigned(Node) do
    begin
      if I>0 then Require(Tree.GetNextVisibleNoInit(Tree.GetPreviousVisibleNoInit(Node))=Node,'Sparse previous/next cache differs');
      Inc(I); Node:=Tree.GetNextVisibleNoInit(Node); Require(I<=75,'Sparse cache loop');
    end;
    Require(I=75,'Sparse iterator omitted distributed rows');
    Started:=GetTickCount64;
    for I:=1 to 20 do begin Tree.Header.Columns[0].Width:=390+I; Tree.Repaint; end;
    Writeln('PROFILE 20 width repaints / 75 distributed visible / 500000 loaded ms=',GetTickCount64-Started);
    Filters.Clear; Filters.SetValue(COL_TITLE,'500000'); Filters.Apply;
    for I:=1 to 20 do begin Application.ProcessMessages; CheckSynchronize(0); Sleep(25); end;
    Writeln('CACHE visible=',Tree.VisibleCount,' valid=',tsUseCache in Tree.TreeStates);
    if Tree.GetFirstVisibleNoInit <> Tree.FocusedNode then raise Exception.Create('Sparse first visible differs');
    if Tree.GetNextVisibleNoInit(Tree.FocusedNode) <> nil then raise Exception.Create('Sparse last visible differs');
    Started:=GetTickCount64;
    for I:=1 to 20 do begin Tree.Header.Columns[0].Width:=390+I; Tree.Repaint; end;
    Writeln('PROFILE 20 visible repaints last matching book / 500000 loaded ms=',GetTickCount64-Started); Flush(Output);
  finally Names.Free; Form.Free; Probe.Free; end;
end;
procedure FilterValues;
var Form: TForm; Tree: TBookTree; Probe: TProbe; Filters: TBookColumnFilters;
  Names: TStringList; Book: PBookRecord; I: Integer;
begin
  Probe:=TProbe.Create; Form:=TForm.CreateNew(nil); Names:=TStringList.Create;
  try
    Tree:=TBookTree.Create(Form); Tree.Parent:=Form; Tree.NodeDataSize:=SizeOf(TBookRecord);
    Tree.OnFreeNode:=Probe.FreeBook;
    for I:=1 to 3 do
    begin
      Book:=Tree.GetNodeData(Tree.AddChild(nil)); Book^:=Default(TBookRecord); Book.NodeType:=ntBookInfo;
      case I of
        1: begin Book.Title:='Конёк'; Book.Series:='Дворяне'; Book.FileExt:='.pdf'; Book.CollectionName:='One'; end;
        2: begin Book.Title:='конек'; Book.Series:='Воры'; Book.FileExt:='.azw3'; Book.CollectionName:='Two'; end;
        3: begin Book.Title:='Other'; Book.Series:='Other'; Book.FileExt:='.fb2'; Book.CollectionName:='Three'; end;
      end;
      TAuthorsHelper.Add(Book.Authors,'Автор '+IntToStr(I),'','');
      if I=1 then TAuthorsHelper.Add(Book.Authors,'Второй автор','','');
    end;
    Filters:=TBookColumnFilters.ForTree(Tree); Filters.SetValue(COL_TITLE,'конек');
    Require(Filters.Apply=2,'Column title is not case/e-yo insensitive');
    Filters.SetCaseSensitive(COL_TITLE,True); Require(Filters.Apply=1,'Case switch did not narrow title');
    Filters.Clear; Filters.GetOptions(COL_AUTHOR,Names);
    Require((Names.Count=4) and (Names.IndexOf('Второй автор')>=0),'Author options are combined records');
    Names.Clear; Names.Add('Автор 1'); Names.Add('Автор 3'); Filters.SetSelectedValues(COL_AUTHOR,Names);
    Require(Filters.Apply=2,'Multiple individual authors do not match');
    Filters.GetOptions(COL_TYPE,Names); Require((Names.Count=2) and (Names.IndexOf('pdf')>=0),'Type options ignore remaining author filter');
    Filters.Clear; Names.Clear; Names.Add('pdf'); Names.Add('azw3'); Filters.SetSelectedValues(COL_TYPE,Names);
    Require(Filters.Apply=2,'Multiple file types do not match');
    Filters.GetOptions(COL_SERIES,Names); Require((Names.Count=2) and (Names.IndexOf('Воры')>=0),'Series options ignore remaining type filter');
    Names.Clear; Names.Add('Two'); Filters.SetSelectedValues(COL_COLLECTION,Names);
    Require(Filters.Apply=1,'Collection choice does not combine with selected types');
    Filters.Clear; Require(Filters.Apply=3,'Clear did not restore all loaded rows');
    Writeln('PASS multiselect author/type/collection, remaining-row choices, case switch and e/yo');
  finally Names.Free; Form.Free; Probe.Free; end;
end;
procedure CancelledFilters;
var Form: TForm; Tree: TBookTree; Probe: TProbe; Filters: TBookColumnFilters;
  Parent, Node, Selected: PVirtualNode; Book: PBookRecord; I, Calls, Visible: Integer;
  Cancelled: Boolean;
begin
  Probe:=TProbe.Create; Form:=TForm.CreateNew(nil);
  try
    Tree:=TBookTree.Create(Form); Tree.Parent:=Form; Tree.NodeDataSize:=SizeOf(TBookRecord);
    Tree.OnFreeNode:=Probe.FreeBook; Parent:=Tree.AddChild(nil);
    Book:=Tree.GetNodeData(Parent); Book^:=Default(TBookRecord); Book.NodeType:=ntAuthorInfo;
    Selected:=nil;
    for I:=1 to 600 do
    begin
      Node:=Tree.AddChild(Parent); Book:=Tree.GetNodeData(Node); Book^:=Default(TBookRecord);
      Book.NodeType:=ntBookInfo; Book.Title:='old '+IntToStr(I);
      if I>400 then Book.Title:='old keep '+IntToStr(I);
      if I=500 then Selected:=Node;
    end;
    Filters:=TBookColumnFilters.ForTree(Tree); Filters.SetValue(COL_TITLE,'old');
    Require(Filters.Apply=600,'Cancellation fixture is incomplete');
    Tree.FocusedNode:=Selected; Tree.Selected[Selected]:=True; Selected.CheckState:=csCheckedNormal;
    Filters.SetValue(COL_TITLE,'old keep'); Calls:=0; Cancelled:=False;
    try Filters.Apply(True,function: Boolean begin Inc(Calls); Result:=True; end);
    except on E:EAbort do Cancelled:=True; end;
    Require(Cancelled and (Calls=1),'Filter cancellation was not handled');
    Visible:=0; Node:=Tree.GetFirst;
    while Assigned(Node) do
    begin
      Book:=Tree.GetNodeData(Node);
      if (Book.NodeType=ntBookInfo) and not Tree.IsFiltered[Node] then Inc(Visible);
      Node:=Tree.GetNext(Node);
    end;
    Require((Visible=600) and not Tree.IsFiltered[Parent],'Cancelled filter partially hid rows or groups');
    Require((Tree.FocusedNode=Selected) and Tree.Selected[Selected] and
      (Selected.CheckState=csCheckedNormal),'Cancelled filter changed selection or check marks');
    Require(Filters.Apply=200,'Retry after cancelled narrowing omitted books');
    Filters.Clear; Require(Filters.Apply=600,'Reset after cancelled filtering lost books');
    Filters.SetValue(COL_TITLE,'unmatched'); Cancelled:=False;
    try Filters.Apply(True,function: Boolean begin Result:=True; end);
    except on E:EAbort do Cancelled:=True; end;
    Require(Cancelled and (Tree.VisibleCount>0),'Cancelled full scan erased prior result');
    Writeln('PASS cancelled filters preserve rows, groups, selection and checks; retry/reset');
  finally Form.Free; Probe.Free; end;
end;
procedure CancelledAliases;
var C: IBookCollection; ID, I, Calls, BookID: Integer; Plan: TSeriesAliasPlan; Book: TBookRecord;
  FileName: string; Cancelled: Boolean;
begin
  RequireIsolatedRegression; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    ID:=SystemDB.CreateCollection('Cancelled alias regression',Settings.AppPath,
      'alias-cancel-'+TGUID.NewGuid.ToString+'.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    C:=SystemDB.GetCollection(ID); FileName:=Settings.ExpandCollectionFileName(VarToStr(C.GetProperty(PROP_DATAFILE)));
    Book:=Default(TBookRecord); Book.Title:='Cancellation'; Book.FileName:='cancel'; Book.LibID:='cancel'; Book.FileExt:='.fb2';
    BookID:=C.InsertBook(Book,False,False); C.BeginBulkOperation;
    try
      for I:=1 to 20000 do C.AddBookSeries(BookID,'Unmatched '+IntToStr(I)+'[a]',I);
      C.EndBulkOperation(True);
    except C.EndBulkOperation(False); raise; end;
    Plan:=TSeriesAliasPlan.Create(C,SystemDB);
    try
      Calls:=0; Cancelled:=False;
      try Plan.Preview(function: Boolean begin Inc(Calls); Result:=Calls>=3; end);
      except on E:EAbort do Cancelled:=True; end;
      Require(Cancelled and (Calls>=3),'Empty-result alias query ignored cancellation');
      Require(not Assigned(SQLiteCancelCallback),'Alias cancellation callback leaked into later queries');
      Plan.Preview(nil); Require(Plan.Count=0,'Cancelled query damaged subsequent preview');
      Writeln('PASS SQL cancellation during empty-result alias preview and clean retry');
    finally Plan.Free; end;
  finally C:=nil; DMUser.Free; DMUser:=nil; end;
end;
procedure ArchiveInspection;
var Book: TBookRecord; Zip: TZipFile; Source, ResultFile, Hash, Extension: string;
begin
  RequireIsolatedRegression; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  try
    Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath;
    Book.FileName:='inspection'; Book.FileExt:='.zip'; Source:=Book.GetBookFileName;
    Zip:=TZipFile.Create;
    try Zip.Open(Source,zmWrite); Zip.Add(TEncoding.UTF8.GetBytes('CBZ member unchanged'),'inner.cbz');
      Zip.Add(TEncoding.UTF8.GetBytes('<FictionBook><body/></FictionBook>'),'book.fb2'); Zip.Close;
    finally Zip.Free; end;
    Require(SameFileName(PrepareReaderFile(Book,False,nil,True),Source),'Open archive opened a member');
    Book.Folder:='inspection.zip'; Book.FileName:='inner'; Book.FileExt:='.cbz';
    ResultFile:=PrepareReaderFile(Book,False,nil,True);
    Require(SameText(ExtractFileExt(ResultFile),'.cbz') and
      (TFile.ReadAllText(ResultFile,TEncoding.UTF8)='CBZ member unchanged'),'Open inner archive changed member bytes');
    Book.FileName:='book'; Book.FileExt:='.fb2';
    Require(SameFileName(PrepareReaderFile(Book,False,nil,True),Source),'Open enclosing archive extracted FB2');
    Require(IsReaderArchive('book.cbr') and IsReaderArchive('book.7z') and not IsReaderArchive('book.fb2'),'Archive action availability incorrect');
    for Extension in ['.cab','.7z'] do
    begin
      Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath;
      Book.FileName:='loose-book'; Book.FileExt:=Extension; Source:=Book.GetBookFileName;
      Require(FileExists(Source),'Missing archive regression fixture '+Extension);
      Hash:=THashSHA2.GetHashStringFromFile(Source);
      ResultFile:=PrepareReaderFile(Book,True);
      Require(SameText(ExtractFileExt(ResultFile),'.fb2') and
        ContainsText(TFile.ReadAllText(ResultFile,TEncoding.UTF8),'Archive needle'),'Container failed to extract reading member '+Extension);
      Require(SameFileName(PrepareReaderFile(Book,True,nil,True),Source),'Container inspection extracted reading member '+Extension);
      Require(THashSHA2.GetHashStringFromFile(Source)=Hash,'Container changed source '+Extension);
    end;
    Writeln('PASS Open archive preserves outer ZIP and nested CBZ; enclosing archive for FB2');
    Writeln('PASS loose CAB and 7z reading, source preservation, raw archive inspection');
  finally DMUser.Free; DMUser:=nil; end;
end;

procedure ColumnLayoutRecovery;
var Ini: TIniFile; Columns: TColumns; Tree: TVirtualStringTree; Name: string;
begin
  RequireIsolatedRegression;
  Name:=ExtractFilePath(ParamStr(0))+'damaged-columns.ini';
  Ini:=TIniFile.Create(Name);
  try
    Ini.WriteString(SECTION_A_FLAT,'Column0','11;broken;0');
    Ini.WriteString(SECTION_A_FLAT,'Column1','20;240;1');
    Ini.WriteString(SECTION_A_FLAT,'Column2','11;300;2');
    Ini.WriteString(SECTION_A_FLAT,'Column3','11;450;3');
    Ini.WriteString(SECTION_A_FLAT,'Column4','100000;250;4');
    Ini.WriteString(SECTION_A_FLAT,'Column5','12;200;99999999');
    Ini.WriteString(SECTION_A_FLAT,'Column6','14;99999999999999999;6');
    Ini.WriteString(SECTION_S_FLAT,'Column0','bad;width;position');
  finally Ini.Free; end;
  Columns:=TColumns.Create(Name); Tree:=TVirtualStringTree.Create(nil);
  try
    Columns.Load(SECTION_A_FLAT,tmFlat);
    Require(Columns.Count=2,'Damaged layout did not keep exactly two valid unique columns');
    Require((Columns[0].Tag=COL_AUTHOR) and (Columns[0].Width=240) and
      (Columns[1].Tag=COL_TITLE) and (Columns[1].Width=300),'Valid column preferences changed during recovery');
    Columns.SetColumns(Tree.Header.Columns);
    Require(Tree.Header.Columns.Count=2,'Recovered layout could not be applied to the real header');
    Columns.Load(SECTION_S_FLAT,tmFlat);
    Require(Columns.Count>=5,'Entirely damaged layout did not restore defaults');
    Columns.SetColumns(Tree.Header.Columns);
    Columns.Save(SECTION_S_FLAT);
    Columns.Load(SECTION_S_FLAT,tmFlat);
    Require(Columns.Count>=5,'Recovered default layout could not be saved and reloaded');
    Writeln('PASS damaged column layout preserves valid preferences and restores defaults safely');
  finally Tree.Free; Columns.Free; end;
end;
begin
  try
    Application.Initialize;
    InitLocalization;
    SearchSpellings;
    if ParamStr(1)='reader-choices' then begin ReaderChoices; Exit; end;
    if ParamStr(1)='reader-cache-stamps' then begin ReaderCacheStamps; Exit; end;
    if ParamStr(1)='office-reader' then begin OfficeReader; Exit; end;
    if ParamStr(1)='sources-window' then begin SourcesWindow; Exit; end;
    if ParamStr(1)='column-layout' then begin ColumnLayoutRecovery; Exit; end;
    if ParamStr(1)='status' then begin StatusRecovery; Exit; end;
    if ParamStr(1)='kindle' then begin Kindle; Exit; end;
    if ParamStr(1)='async' then begin AsyncRead; Exit; end;
    if ParamStr(1)='aliases' then begin SeriesAliases; Exit; end;
    if ParamStr(1)='filters' then begin FilterValues; Exit; end;
    if ParamStr(1)='cancel-filters' then begin CancelledFilters; Exit; end;
    if ParamStr(1)='cancel-aliases' then begin CancelledAliases; Exit; end;
    if ParamStr(1)='archives' then begin ArchiveInspection; Exit; end;
    if ParamStr(1)='images' then Images(ParamStr(2)) else Widths;
  except on E: Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); Halt(1); end; end;
end.
