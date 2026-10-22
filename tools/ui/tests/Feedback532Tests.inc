procedure TestImageComponents(const Collection: IBookCollection);
const WebPSample='UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
var Info: TProgramRelease; Target, Job, FileName, Held, JSON, Arch, Prefix, SavedPath: string;
  Zip: TZipFile; Files: TUpdateFiles; Missing, Rejected: Boolean; Data: TBytes;
  Source, Restored: TStream; Reader: TfrmBuiltinReader; Started: UInt64;
begin
  RequireIsolatedRegression;
  for var ID in ['JPEG XL','WebP'] do
    Require(IsOptionalComponent(ID) and not ComponentNotificationEnabled(ID,''),ID+' should be optional and quiet by default');
  Prefix:=Settings.AppPath+'image-components'; ForceDirectories(Prefix);
  FileName:=Settings.AppPath+'tools/webp/libwebp.dll'; Held:=FileName+'.held'; TFile.Move(FileName,Held);
  try
    Missing:=False;
    try Data:=ConvertWebPToPNG(TNetEncoding.Base64.DecodeStringToBytes(WebPSample));
    except on E: EMHLComponentRequired do Missing:=E.ComponentID='WebP'; end;
    Require(Missing,'Actual WebP bytes did not request the missing component');
    TFile.WriteAllText(Prefix+'/missing.fb2','<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><body><section><p>Visible text</p><image l:href="#pic"/></section></body><binary id="pic" content-type="image/webp">'+WebPSample+'</binary></FictionBook>',TEncoding.UTF8);
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.OpenBook(Prefix+'/missing.fb2','Missing image','missing',Prefix+'/reader.ini',''); Reader.Show;
      Started:=GetTickCount64;
      while (Reader.RequiredComponent='') and not Reader.LoadFinished and (GetTickCount64-Started<10000) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
      Require((Reader.RequiredComponent='WebP') and not Reader.Ready,'Async native reader silently skipped missing WebP');
    finally Reader.Free; end;

    Data:=TEncoding.ASCII.GetBytes('ordinary image');
    Require(Length(ConvertWebPToPNG(Data))=Length(Data),'Ordinary image attempted to load WebP');
  finally TFile.Move(Held,FileName); end;
  Data:=ConvertWebPToPNG(TNetEncoding.Base64.DecodeStringToBytes(WebPSample));
  Require((Length(Data)>8) and (Data[0]=$89) and (Data[1]=Ord('P')),'WebP decoder did not produce PNG');
  Writeln('PASS image-components WebP requested only for actual image bytes and decoded after installation');

  FileName:=Settings.AppPath+'WebP-1.6.0-'+ProgramUpdatePlatform+'.zip';
  JSON:='{"tag_name":"'+ALREADER_FIXED_TAG+'","assets":[{"name":"'+ExtractFileName(FileName)+
    '","browser_download_url":"https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+ExtractFileName(FileName)+
    '","digest":"sha256:'+UpdateSHA256(FileName)+'","size":'+IntToStr(TFile.GetSize(FileName))+'}]}';
  Require(ParseImageComponent(JSON,'WebP',Info) and (Info.ComponentVersion='1.6.0') and not Info.OfficialComponent,'WebP package release was not recognized');
  Require(not ParseImageComponent(JSON.Replace('sha256:','sha256:x'),'WebP',Info),'Malformed WebP digest accepted');
  Job:=Prefix+'/webp-job'; Files:=PrepareProgramUpdate(FileName,UpdateSHA256(FileName),ALREADER_FIXED_TAG,
    ProgramUpdatePlatform,Job,True,'WebP','1.6.0');
  Require((Length(Files)=5) and (InstalledComponentVersion(Job+'/payload','WebP')='1.6.0'),'WebP native manifest, PE architecture or descriptor failed');
  Target:=Prefix+'/target'; ForceDirectories(Target); TFile.Copy(ParamStr(0),Target+'/HomeLibRu.exe');
  InstallProgramUpdate(Job,Target);
  Require(not ComponentNeedsRepair(Target,'WebP'),'Fresh WebP install is incomplete');
  Rejected:=False;
  try Files:=PrepareProgramUpdate(FileName,UpdateSHA256(FileName),ALREADER_FIXED_TAG,
    ProgramUpdatePlatform,Prefix+'/wrong-version',True,'WebP','9.9.9');
  except on E: Exception do Rejected:=True; end;
  Require(Rejected,'WebP package accepted a different claimed version');
  Writeln('PASS image-components WebP package native verification, installation and version rejection');

  if ProgramUpdatePlatform='Win64' then Arch:='x64' else Arch:='x86';
  FileName:=Prefix+'/jxl.zip'; Zip:=TZipFile.Create;
  try
    Zip.Open(FileName,zmWrite);
    Zip.Add(Settings.AppPath+'tools/jpeg-xl/djxl.exe',Arch+'-windows-static/bin/djxl.exe');
    for var License in TDirectory.GetFiles(Settings.AppPath+'tools/jpeg-xl/licenses') do
      Zip.Add(License,Arch+'-windows-static/licenses/'+ExtractFileName(License));
  finally Zip.Free; end;
  JSON:='{"tag_name":"v0.12.0","assets":[{"name":"jxl-'+Arch+'-windows-static.zip",'+
    '"browser_download_url":"https://github.com/libjxl/libjxl/releases/download/v0.12.0/jxl-'+Arch+'-windows-static.zip",'+
    '"digest":"sha256:'+UpdateSHA256(FileName)+'","size":'+IntToStr(TFile.GetSize(FileName))+'}]}';
  Require(ParseImageComponent(JSON,'JPEG XL',Info) and Info.OfficialComponent and (Info.ComponentVersion='0.12.0'),'Official JXL release was not recognized');
  Require(not ParseImageComponent(JSON.Replace('"tag_name":','"draft":true,"tag_name":'),'JPEG XL',Info),'Draft JXL release accepted');
  Require(not IsOfficialComponentURL('JPEG XL','0.12.0','https://invalid.example/jxl.zip',ProgramUpdatePlatform,False),'Foreign JXL URL accepted');
  Require(IsOfficialComponentURL('JPEG XL','0.12.0','https://github.com/libjxl/libjxl/releases/download/v0.12.0/jxl-'+Arch+'-windows-static.zip',ProgramUpdatePlatform,False),'Official JXL URL rejected');
  Job:=Prefix+'/jxl-job';
  // AppPath has no unpacker: the official ZIP must install without 7-Zip.
  PrepareOfficialComponent(FileName,Job,'JPEG XL','0.12.0',ProgramUpdatePlatform,'',Prefix+'/empty');
  InstallProgramUpdate(Job,Target);
  Require(not ComponentNeedsRepair(Target,'JPEG XL') and
    (InstalledComponentVersion(Target,'JPEG XL')='0.12.0'),'JPEG XL ZIP without an unpacker failed');
  Writeln('PASS image-components official JPEG XL ZIP prepares and installs independently of 7-Zip');
  FileName:=Settings.AppPath+'official-jxl.zip';
  Require(FileExists(FileName),'The actual verified author ZIP is required for JPEG XL installation coverage');
  Job:=Prefix+'/jxl-author-job';
  PrepareOfficialComponent(FileName,Job,'JPEG XL','0.12.0',ProgramUpdatePlatform,'',Prefix+'/empty');
  Require(SameText(UpdateSHA256(Job+'/payload/tools/jpeg-xl/djxl.exe'),
    UpdateSHA256(Settings.AppPath+'tools/jpeg-xl/djxl.exe')),'Author ZIP decoder differs from the independently tested runtime');
  Writeln('PASS image-components actual author JPEG XL Deflate64 ZIP installs without an unpacker');
  TestFeedback529JXL(Collection);
  FileName:=Settings.AppPath+'tools/jpeg-xl/djxl.exe'; Held:=FileName+'.held'; TFile.Move(FileName,Held);
  SavedPath:=GetEnvironmentVariable('PATH');
  SetEnvironmentVariable('PATH',''); // The maintainer's global djxl is not part of this isolated profile.
  Source:=TFileStream.Create(Settings.AppPath+'feedback529-jxl\1.fb2',fmOpenRead or fmShareDenyWrite);
  try
    Missing:=False; Restored:=nil;
    try Restored:=RestoreFLibraryBook(Settings.AppPath+'feedback529-jxl\alpha.7z','1.fb2',Source);
    except on E: EMHLComponentRequired do Missing:=E.ComponentID='JPEG XL'; end;
    Restored.Free; Require(Missing,'FLibrary JXL bytes did not request the missing decoder');
  finally Source.Free; SetEnvironmentVariable('PATH',PChar(SavedPath)); TFile.Move(Held,FileName); end;
  Writeln('PASS image-components JPEG XL keeps alpha and requests its missing decoder on actual FLibrary input');
end;

type
  T532ArchiveChooser = class
    procedure Tick(Sender: TObject);
  end;

procedure T532ArchiveChooser.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible and (Screen.Forms[I].Caption='Какую книгу открыть?') then
      Screen.Forms[I].ModalResult:=mrOk;
end;

procedure TestCatalogueFormats;
var Root: TJSONValue; Items, Results: TJSONArray; Item: TJSONValue; Row: TJSONObject;
  FileName, Extension, Prepared, Source, OutputName, Hash, ErrorText: string;
  Book: TBookRecord; Reader: TfrmBuiltinReader; Document: TReaderDocument;
  Started: UInt64; Warnings: TStringList; Timer: TTimer; Chooser: T532ArchiveChooser;
  Count: Integer;
  LastProgress, Updates, TotalPages: Integer; CancelConversion, WasCanceled: Boolean;
  ProgressRows: TJSONArray;
begin
  RequireIsolatedRegression;
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'catalogue-examples/examples.json',TEncoding.UTF8));
  Results:=TJSONArray.Create; Warnings:=TStringList.Create; Count:=0;
  Timer:=TTimer.Create(nil); Chooser:=T532ArchiveChooser.Create;
  try
    Timer.Interval:=80; Timer.OnTimer:=Chooser.Tick; Timer.Enabled:=True;
    Items:=Root.GetValue<TJSONArray>('examples');
    Require(Items.Count>0,'The catalogue audit must contain at least one real book');
    for Item in Items do
    begin
      Inc(Count); Row:=TJSONObject.Create; Results.AddElement(Row);
      Extension:=Item.GetValue<string>('extension'); Row.AddPair('extension',Extension);
      Row.AddPair('id',TJSONNumber.Create(Item.GetValue<Integer>('id')));
      FileName:=TPath.Combine(Settings.AppPath,'catalogue-examples\'+Item.GetValue<string>('name'));
      Hash:=UpdateSHA256(FileName); Require(SameText(Hash,Item.GetValue<string>('sha256')),'Audit example changed before reading');
      Book.Clear; Book.NodeType:=ntBookInfo; Book.BookKey:=CreateBookKey(Count,900532);
      Book.CollectionRoot:=ExtractFilePath(FileName); Book.FileName:=TPath.GetFileNameWithoutExtension(FileName);
      Book.FileExt:=ExtractFileExt(FileName); Book.Title:='Catalogue format audit';
      Prepared:=''; Started:=GetTickCount64; ErrorText:='';
      try
        Prepared:=PrepareReaderFile(Book,True,nil,False,True,True);
        Row.AddPair('detected',ExtractFileExt(Prepared));
        if not ReaderSupportsReflow(Prepared) and not SameText(ExtractFileExt(Prepared),'.pdf') then
          Row.AddPair('read','unsupported')
        else
        begin
          Reader:=TfrmBuiltinReader.Create(nil);
          try
            Reader.OpenBook(Prepared,'Catalogue audit','audit-'+IntToStr(Count),Settings.AppPath+'audit-reader.ini',Settings.AppPath+'tools/pdfium/pdfium.dll');
            Reader.Show;
            while (((not Reader.Ready) and not Reader.LoadFinished) or Reader.PageLoading) and (GetTickCount64-Started<30000) do
            begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
            // PDF has no document loader; Ready/PageLoading are authoritative.
            if not Reader.Ready or Reader.PageLoading then raise Exception.Create(Reader.ReaderStatus.Caption);
            Require(Reader.TextLength>0,'Reader returned no text or pages');
            Row.AddPair('read','ok'); Row.AddPair('read_length',TJSONNumber.Create(Reader.TextLength));
            Row.AddPair('pictures',TJSONNumber.Create(Reader.PictureCount));
          finally Reader.Free; end;
        end;
      except on E: Exception do begin Row.AddPair('read','error'); Row.AddPair('read_error',E.Message); end; end;
      Row.AddPair('read_ms',TJSONNumber.Create(GetTickCount64-Started));
      for var Target in ['.fb2','.epub'] do
      begin
        Started:=GetTickCount64; OutputName:=Settings.AppPath+'catalogue-result-'+IntToStr(Count)+Target;
        try
          Source:=PrepareConversionSource(Book,nil,Target);
          if not IsConversionCandidate(ExtractFileExt(Source)) then Row.AddPair(Target,'unsupported')
          else
          begin
            if (Item.GetValue<Integer>('id')=777324) and (Target='.fb2') then
            begin
              CancelConversion:=False; WasCanceled:=False;
              try
                ConvertBasicBook(Settings.AppPath,Settings.TempDir,Source,ExtractFileExt(Source),OutputName,nil,Warnings,
                  function: Boolean begin Result:=CancelConversion; end,'','','',False,
                  procedure(Percent, Completed, Total: Integer; const Stage: string)
                  begin if (Stage='pages') and (Completed>=2) then CancelConversion:=True; end);
              except on E: EAbort do WasCanceled:=True; end;
              Require(WasCanceled and not FileExists(OutputName),'Page cancellation published a partial book');
              Row.AddPair('page_cancel','ok');
              Writeln('PASS catalogue page cancellation stops the contained converter without publishing a partial book'); Flush(Output);
            end;
            LastProgress:=-1; Updates:=0; TotalPages:=0;
            ProgressRows:=TJSONArray.Create; Row.AddPair(Target+'_progress',ProgressRows);
            ConvertBasicBook(Settings.AppPath,Settings.TempDir,Source,ExtractFileExt(Source),OutputName,nil,Warnings,
              nil,'','','',False,
              procedure(Percent, Completed, Total: Integer; const Stage: string)
              var Entry: TJSONObject;
              begin
                Require((Percent>=LastProgress) and (Percent<=100),'Conversion progress went backwards or exceeded 100');
                Require((Percent<>100) or FileExists(OutputName),'Conversion reported 100 before publishing its result');
                LastProgress:=Percent; Inc(Updates); TotalPages:=Total;
                if (Updates=1) or (Stage<>'pages') or (Completed mod 64=0) then
                begin
                  Entry:=TJSONObject.Create; ProgressRows.AddElement(Entry);
                  Entry.AddPair('percent',TJSONNumber.Create(Percent)); Entry.AddPair('page',TJSONNumber.Create(Completed));
                  Entry.AddPair('total',TJSONNumber.Create(Total)); Entry.AddPair('stage',Stage);
                  Entry.AddPair('ms',TJSONNumber.Create(GetTickCount64-Started));
                  Writeln('PROFILE conversion ',Target,' progress=',Percent,' page=',Completed,'/',Total,' stage=',Stage); Flush(Output);
                end;
              end);
            Require((LastProgress=100) and (Updates>=2),'Conversion did not finish its progress lifecycle');
            Row.AddPair(Target+'_progress_updates',TJSONNumber.Create(Updates));
            Row.AddPair(Target+'_pages',TJSONNumber.Create(TotalPages));
            Document:=TReaderDocument.Create;
            try Document.Load(OutputName); Require(Document.PlainText.Trim<>'','Conversion produced no readable text');
              Row.AddPair(Target,'ok'); Row.AddPair(Target+'_length',TJSONNumber.Create(Length(Document.PlainText)));
              Row.AddPair(Target+'_pictures',TJSONNumber.Create(Document.ImageCount));
            finally Document.Free; end;
            Row.AddPair(Target+'_warnings',Warnings.Text);
          end;
        except on E: Exception do begin Row.AddPair(Target,'error'); Row.AddPair(Target+'_error',E.Message); end; end;
        Row.AddPair(Target+'_ms',TJSONNumber.Create(GetTickCount64-Started));
        if FileExists(OutputName) then TFile.Delete(OutputName);
      end;
      Require(SameText(UpdateSHA256(FileName),Hash),'Reading/conversion changed its source example');
      TFile.WriteAllText(Settings.AppPath+'catalogue-format-results.json',Results.ToJSON,TEncoding.UTF8);
      Writeln('AUDIT catalogue format ',Extension,' example=',Count,' read=',Row.GetValue<string>('read'),
        ' fb2=',Row.Values['.fb2'].Value,' epub=',Row.Values['.epub'].Value); Flush(Output);
    end;
    Writeln('PASS catalogue-formats audit completed examples=',Count,'; inspect per-book outcomes');
  finally Timer.Free; Chooser.Free; Warnings.Free; Results.Free; Root.Free; end;
end;

procedure TestDownloadScenarios(const SystemData: ISystemData; Port: Integer);
var Collection: IBookCollection; CID, BID: Integer; Downloader: TDownloader;
  Book: TBookRecord; Expected, Actual: Boolean; Script: string;
begin
  Require((Port>0) and (Port<65536),'Download scenarios need an owned loopback server');
  Settings.UseIESettings:=False; Settings.ProxyType:=0; CreateOnlineResponse;
  CID:=SystemData.CreateCollection('Download scenario regression',Settings.AppPath,
    'download-scenarios.hlc2',CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemData.GetCollection(CID);
  Collection.SetProperty(PROP_URL,Format('http://127.0.0.1:%d/',[Port]));
  for var I:=1 to 9 do
  begin
    Script:='POST %URL%b/%LIBID%/get'+sLineBreak+'GET %RESURL%'+sLineBreak+'CHECK';
    if I=6 then Script:='GET %URL%b/%LIBID%/get'+sLineBreak+'GET %URL%b/%LIBID%/get'+sLineBreak+'CHECK';
    if I=9 then Script:='GET %URL%b/%LIBID%/get'+sLineBreak+'CHECK';
    Collection.SetProperty(PROP_CONNECTIONSCRIPT,Script);
    BID:=AddOnlineBook(Collection,'Scenario '+IntToStr(I),IntToStr(901000+I),not ((I=2) or (I=9)));
    Downloader:=TDownloader.Create;
    try Downloader.IgnoreErrors:=True; Actual:=Downloader.Download(SystemData,CreateBookKey(BID,CID));
    finally Downloader.Free; end;
    Expected:=not ((I=5) or (I=7) or (I=8));
    Require(Actual=Expected,'Download scenario result differs: '+IntToStr(I));
    Collection.GetBookRecord(CreateBookKey(BID,CID),Book,False);
    Require(FileExists(Book.GetBookFileName)=Expected,'Failed response published a book: '+IntToStr(I));
    Writeln('PASS download-scenarios case=',I,' result=',Ord(Actual)); Flush(Output);
  end;
end;

type
  T532ExportProgressForm = class(TExportToDeviceProgressForm)
  public
    SeenPage, CancelOnPage, CanceledOnPage: Boolean;
    ProgressComments: TStringList;
    procedure SetComment(const Comment: string); override;
    function ShowMessage(const Text: string; Flags: Longint = MB_OK): Integer; override;
  end;

procedure T532ExportProgressForm.SetComment(const Comment: string);
begin
  inherited;
  if Comment.Contains('стр.') and Comment.Contains('%') then
  begin
    SeenPage:=True; ProgressComments.Add(Comment);
    Canvas.Font.Assign(txtComment.Font);
    Require(Canvas.TextWidth(Comment)<=txtComment.Width,'Actual conversion page/percent caption is clipped');
    Require(btnCancel.Enabled,'Cancel is disabled during page conversion');
    if CancelOnPage and not Comment.Contains('стр. 0/') and not CanceledOnPage then
    begin CanceledOnPage:=True; WorkerThread.Cancel; end;
  end;
end;

function T532ExportProgressForm.ShowMessage(const Text: string; Flags: Longint): Integer;
begin Result:=IDOK; end;

procedure TestPagedExportProgress;
var Root, Destination, Source, SourceHash, SavedFolder, SavedFile: string;
  CID, BID: Integer; Collection: IBookCollection; Book: TBookRecord; List: TBookIdList;
  Worker: TExportToDeviceThread; Form: T532ExportProgressForm;
begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'paged-export'); ForceDirectories(Root);
  Source:=Settings.AppPath+'paged-export.pdf'; SourceHash:=UpdateSHA256(Source);
  TFile.Copy(Source,Root+'book.pdf');
  CID:=SystemDB.CreateCollection('Owned paged progress',Root,Root+'catalog.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID); Book.Clear;
  Book.Title:='Paged conversion'; Book.FileName:='book'; Book.FileExt:='.pdf'; Book.LibID:='owned-paged-progress';
  Book.Size:=TFile.GetSize(Source); Book.Lang:='en'; Include(Book.BookProps,bpIsLocal);
  TAuthorsHelper.Add(Book.Authors,'Progress','Own',''); TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
  BID:=Collection.InsertBook(Book,False,False); Require(BID>0,'Cannot create owned page-progress book');
  SetLength(List,1); List[0]:=Default(TBookIdStruct); List[0].BookKey:=CreateBookKey(BID,CID);
  SavedFolder:=Settings.FolderTemplate; SavedFile:=Settings.FileNameTemplate;
  Settings.FolderTemplate:=''; Settings.FileNameTemplate:='%t';
  try
    for var CancelCase in TArray<Boolean>.Create(False,True) do
    begin
      Destination:=Root+'output-'+BoolToStr(CancelCase,True); ForceDirectories(Destination);
      Worker:=TExportToDeviceThread.Create; Form:=T532ExportProgressForm.Create(nil);
      Form.ProgressComments:=TStringList.Create;
      try
        Form.CancelOnPage:=CancelCase; Worker.BookIdList:=List;
        Worker.DeviceDir:=Destination; Worker.ExportMode:=emFB2; Worker.ExplicitFormat:=True;
        Form.WorkerThread:=Worker; Form.ShowModal; Worker.WaitFor;
        Require(Form.SeenPage and (Form.ProgressComments.Count>0),'Actual export UI did not display page counts and percent');
        if CancelCase then
          Require(Form.CanceledOnPage and (Worker.Results[0].State=besCanceled) and
            (Length(TDirectory.GetFiles(Destination,'*',TSearchOption.soAllDirectories))=0),'Canceled page export published a result')
        else
          Require((Worker.Results[0].State=besSucceeded) and FileExists(Worker.Results[0].OutputFile),
            'Actual page export did not publish its complete result');
        Writeln('PASS paged export actual progress caption, bar, cancel enabled and source preservation cancel=',Ord(CancelCase)); Flush(Output);
      finally Form.ProgressComments.Free; Form.Free; Worker.Free; end;
    end;
    Require(UpdateSHA256(Source)=SourceHash,'Page export changed its source fixture');
  finally Settings.FolderTemplate:=SavedFolder; Settings.FileNameTemplate:=SavedFile; end;
end;
