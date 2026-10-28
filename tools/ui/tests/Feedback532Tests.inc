procedure TestWebPLiveUpdate;
var Worker: TComponentUpdateThread; Info: TProgramRelease;
begin
  RequireIsolatedRegression;
  Worker:=TComponentUpdateThread.Create(0,THTTPClient.Create);
  try
    Worker.OnlyIDs:=TArray<string>.Create('WebP');
    Worker.Start; Worker.WaitFor;
    Require(Worker.Successful,'WebP update worker failed: '+Worker.ErrorText);
    Require(Worker.TryGetRelease(7,Info),'WebP update result was not published');
    Require((Info.ComponentError='') and (Info.DownloadURL<>'') and
      (Info.ComponentVersion='1.6.0') and (Info.Size>0) and IsUpdateSHA256(Info.SHA256),
      'Actual WebP endpoint failed: '+Info.ComponentError+' '+Info.ComponentErrorDetails);
    Writeln('PASS live WebP update check '+ProgramUpdatePlatform+' version='+Info.ComponentVersion+
      ' bytes='+IntToStr(Info.Size)+' sha256='+Info.SHA256);
  finally Worker.Free; end;
end;

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
    RequestedMember, SelectionError: string;
    SelectionCount: Integer;
    procedure Tick(Sender: TObject);
  end;

procedure T532ArchiveChooser.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible and ((Screen.Forms[I].Caption='Какую книгу открыть?') or
      (Screen.Forms[I].Caption='Какую книгу конвертировать?')) then
    begin
      if RequestedMember<>'' then
        for var Component in Screen.Forms[I] do
          if Component is TListBox then
          begin
            TListBox(Component).ItemIndex:=TListBox(Component).Items.IndexOf(RequestedMember);
            if TListBox(Component).ItemIndex<0 then SelectionError:='Requested archive member is absent: '+RequestedMember;
          end;
      Inc(SelectionCount);
      if SelectionError='' then Screen.Forms[I].ModalResult:=mrOk
      else Screen.Forms[I].ModalResult:=mrCancel;
    end;
end;

procedure TestSpecialFormatDetection;
var Source, Expected, Name, Pair: string; At: Integer; ProjectDB: TSQLiteDatabase;
begin
  RequireIsolatedRegression;
  for Pair in TArray<string>.Create('.sqlite|SQLite format 3'+#0+'.stub',
    '.ibk|ICEContainer 1.0!'+StringOfChar(#0,16),'.cr3|CoolReader 3 Cache File v3.03.09',
    '.jap|'+#13+'JAP-Frame-Set1'+#1#0#0,'.sm|ASMJS[::]64[::]0[::]html',
    '.b1|b1:as v:0.4 n:1 t:1','.rgo|'+StringOfChar(#0,60)+'.rgoCERI'+StringOfChar(#0,10)) do
  begin
    At:=Pos('|',Pair);Expected:=Copy(Pair,1,At-1);Source:=Copy(Pair,At+1,MaxInt);
    Name:=Settings.AppPath+'special-'+Expected+'.unknown';TFile.WriteAllBytes(Name,TEncoding.ANSI.GetBytes(Source));
    Require(DetectReaderExtension(Name)=Expected,'Special format was mistaken for ordinary text: '+Expected);
  end;
  Name:=Settings.AppPath+'saved-jutoh.wrong.pdf';
  ProjectDB:=TSQLiteDatabase.Create(Name);
  try
    ProjectDB.ExecSQL('CREATE TABLE ProjectObjects(Id TEXT,ParentId TEXT,Data BLOB)');
    ProjectDB.ExecSQL('CREATE TABLE ProjectVariables(Id TEXT)');
    ProjectDB.ExecSQL('CREATE TABLE ProjectIndex(DataType TEXT,Data BLOB)');
    ProjectDB.ExecSQL('INSERT INTO ProjectIndex VALUES(''Index'',X''0A00000070697869652D75746638'')');
  finally ProjectDB.Free; end;
  Source:=UpdateSHA256(Name);
  Require(DetectReaderExtension(Name)='.jutoh','Jutoh schema under a false extension was not detected');
  Require(IsBuiltinReaderFormat('.jutoh') and IsBasicConversionSource('.jutoh'),'Jutoh missing from reading or conversion');
  Require(Source=UpdateSHA256(Name),'Jutoh detection changed its source project');
  Require(not FileExists(Name+'-journal'),'Read-only Jutoh detection created a journal');
  Name:=Settings.AppPath+'ordinary-database.jutoh';
  ProjectDB:=TSQLiteDatabase.Create(Name);
  try ProjectDB.ExecSQL('CREATE TABLE Books(Id INTEGER)'); finally ProjectDB.Free; end;
  Require(DetectReaderExtension(Name)='.sqlite','An ordinary catalogue with a Jutoh suffix was accepted as a book');
  Writeln('PASS special container and project signatures ignore misleading filenames');Flush(Output);
end;

procedure TestCompoundContentDetection;
const SectorBytes=512;DirectorySector=256;FATSector=257;
var Data, NameBytes: TBytes; FileName: string; DirectoryOffset, FATOffset: Integer;
  procedure Put32(Offset: Integer; Value: Cardinal);
  begin for var I:=0 to 3 do Data[Offset+I]:=Byte(Value shr (I*8));end;
begin
  RequireIsolatedRegression;SetLength(Data,(FATSector+4)*SectorBytes);
  Data[0]:=$D0;Data[1]:=$CF;Data[2]:=$11;Data[3]:=$E0;Data[4]:=$A1;Data[5]:=$B1;Data[6]:=$1A;Data[7]:=$E1;
  Data[26]:=3;Data[28]:=$FE;Data[29]:=$FF;Data[30]:=9;
  Put32(44,3);Put32(48,DirectorySector);Put32(68,$FFFFFFFE);
  for var I:=0 to 108 do Put32(76+I*4,$FFFFFFFF);
  for var I:=0 to 2 do Put32(76+I*4,FATSector+I);
  DirectoryOffset:=(DirectorySector+1)*SectorBytes;
  FATOffset:=(FATSector+3)*SectorBytes;Put32(FATOffset+(DirectorySector mod 128)*4,$FFFFFFFE);
  NameBytes:=TEncoding.Unicode.GetBytes('WordDocument'+#0);
  Move(NameBytes[0],Data[DirectoryOffset],Length(NameBytes));Data[DirectoryOffset+64]:=Length(NameBytes);Data[DirectoryOffset+66]:=2;
  FileName:=Settings.AppPath+'compound-wrong.unknown';TFile.WriteAllBytes(FileName,Data);
  Require(DetectReaderExtension(FileName)='.doc','Compound directory beyond 128 KB was not inspected');
  Data[DirectoryOffset+66]:=0;Put32(FATOffset+(DirectorySector mod 128)*4,DirectorySector);
  FileName:=Settings.AppPath+'compound-cycle.unknown';TFile.WriteAllBytes(FileName,Data);
  Require(DetectReaderExtension(FileName)='','Cyclic compound directory was not bounded');
  Writeln('PASS compound format detection follows a bounded far directory and rejects a cyclic directory');Flush(Output);
end;

procedure TestContentDrivenBookNames;
const Text='Проверка полного текста — ё, ї, ў. Последняя строка книги.';
var Book: TBookRecord; Source, Prepared, Expected, OriginalHash, Folder: string;
  Document: TReaderDocument; Count: Integer;
begin
  RequireIsolatedRegression; Count:=0;
  TestSpecialFormatDetection;
  TestCompoundContentDetection;
  Folder:=Settings.AppPath+'content-driven-names';ForceDirectories(Folder);
  Book.Clear;Book.NodeType:=ntBookInfo;Book.BookKey:=CreateBookKey(533,900533);
  Book.CollectionRoot:=IncludeTrailingPathDelimiter(Folder);Book.Title:='Wrong filename audit';
  for var Kind in ['text','html','fb2'] do
  begin
    Expected:=Text;
    if Kind='html' then Expected:='<p>'+Text+'</p>'
    else if Kind='fb2' then Expected:='<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>'+Text+'</p></section></body></FictionBook>';
    for var Extension in ['.unknown','.dic','.317294','.pdf','.zip','.docx','.prc','.fb2','.приключение',''] do
    begin
      Book.FileName:=Kind+'-wrong';Book.FileExt:=Extension;
      Source:=Book.GetBookFileName;TFile.WriteAllText(Source,Expected,TEncoding.UTF8);
      OriginalHash:=UpdateSHA256(Source);
      Prepared:=PrepareReaderFile(Book,True,nil,False,True,True);
      Require(ExtractFileExt(Prepared)<>'.unknown','Unknown filename blocked content detection');
      Document:=TReaderDocument.Create;
      try
        Document.Load(Prepared);
        Require(Document.PlainText.Contains(Text),'Wrong filename lost actual book text: '+Kind+Extension);
      finally Document.Free;end;
      Require(UpdateSHA256(Source)=OriginalHash,'Content detection changed the original file');
      Inc(Count);TFile.Delete(Source);
    end;
  end;
  Writeln('PASS content-driven actual reader preparation preserves text across wrong suffixes cases=',Count);Flush(Output);
end;

procedure TestConverterInputValidation;
var Source, Target, Decoder, Held: string; Rejected, Missing: Boolean;
begin
  RequireIsolatedRegression;Source:=Settings.AppPath+'same-format-source.fb2';Target:=Settings.AppPath+'same-format-output.fb2';
  TFile.WriteAllText(Source,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>Exact original text.</p></section></body></FictionBook>',TEncoding.UTF8);
  ConvertBasicBook(Settings.AppPath,Settings.TempDir,Source,'.fb2',Target,nil,nil);
  Require(UpdateSHA256(Source)=UpdateSHA256(Target),'Same-format conversion changed original bytes');TFile.Delete(Target);
  TFile.WriteAllText(Source,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"/>',TEncoding.UTF8);
  Rejected:=False;
  try ConvertBasicBook(Settings.AppPath,Settings.TempDir,Source,'.fb2',Target,nil,nil);
  except on E: Exception do Rejected:=True;end;
  Require(Rejected and not FileExists(Target),'Same-format conversion published an invalid source');
  Source:=Settings.AppPath+'missing-decoder.webp';Target:=Settings.AppPath+'missing-decoder.epub';
  TFile.WriteAllBytes(Source,TNetEncoding.Base64.DecodeStringToBytes('UklGRjoAAABXRUJQVlA4TC4AAAAvAUAAEB8gJCBTshFGEAsmkcyfsFtIQBgm+79GFggQkqQ4sh4Eqt45foAQ0f8I'));
  Decoder:=Settings.AppPath+'tools\webp\libwebp.dll';Held:=Decoder+'.held';TFile.Move(Decoder,Held);
  try
    Missing:=False;
    try ConvertBasicBook(Settings.AppPath,Settings.TempDir,Source,'.webp',Target,nil,nil);
    except on E: EMHLComponentRequired do Missing:=E.ComponentID='WebP';end;
    Require(Missing and not FileExists(Target),'Nested converter dependency did not request its optional component');
  finally TFile.Move(Held,Decoder);end;
  Writeln('PASS converter validates exact copies and requests missing nested components without publishing partial books');Flush(Output);
end;

procedure TestMonochromeReaderPictures;
const
  Picture='iVBORw0KGgoAAAANSUhEUgAAAAcAAAADAQAAAAB3uChoAAAADklEQVR4nGOwZ7Bk+AkAAuUBciXe+80AAAAASUVORK5CYII=';
  Expected: array[0..2] of Byte=($3F,$39,$F9);
var Source: string; Doc: TReaderDocument; RTF: UTF8String;
  Info: TBitmapInfoHeader; Colors: array[0..1] of TRGBQuad;
  At, X, Y, ColorIndex: Integer; Pixel: Byte;
begin
  Source:=Settings.AppPath+'monochrome-reader.fb2';
  TFile.WriteAllText(Source,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink"><body><section><p>Black and white text glyphs</p><image l:href="#mono"/></section></body><binary id="mono" content-type="image/png">'+Picture+'</binary></FictionBook>',TEncoding.UTF8);
  Doc:=TReaderDocument.Create;
  try
    Doc.Load(Source); RTF:=Doc.RTF(960,1000);
    At:=Pos(UTF8String('\bin60 '),RTF);
    Require(At>0,'Monochrome reader picture expanded into a 24-bit DIB');
    Inc(At,Length('\bin60 '));
    Move(RTF[At],Info,SizeOf(Info)); Inc(At,SizeOf(Info));
    Require((Info.biBitCount=1) and (Info.biWidth=7) and (Info.biHeight=3) and
      (Info.biClrUsed=2) and (Info.biSizeImage=12),'Incorrect monochrome DIB layout');
    Move(RTF[At],Colors,SizeOf(Colors)); Inc(At,SizeOf(Colors));
    for Y:=0 to 2 do
      for X:=0 to 6 do
      begin
        ColorIndex:=(Byte(RTF[At+(2-Y)*4]) shr (7-X)) and 1;
        if (Expected[Y] and ($80 shr X))<>0 then Pixel:=255 else Pixel:=0;
        Require((Colors[ColorIndex].rgbRed=Pixel) and (Colors[ColorIndex].rgbGreen=Pixel) and
          (Colors[ColorIndex].rgbBlue=Pixel),'Monochrome glyph colors or scanlines changed');
      end;
    Require(Doc.ImageCount=1,'Monochrome picture disappeared from the reader document');
  finally Doc.Free; end;
  Writeln('PASS monochrome reader DIB preserves every pixel and palette at one bit per pixel'); Flush(Output);
end;

procedure TestCatalogueFormats;
var Root: TJSONValue; Items, Results: TJSONArray; Item: TJSONValue; Row: TJSONObject;
  FileName, Extension, Prepared, OriginalPrepared, Source, OutputName, Hash, ErrorText, Member: string;
  Members: TArray<string>;
  Book, ConvertedBook: TBookRecord; Reader: TfrmBuiltinReader; Document: TReaderDocument;
  Started: UInt64; Warnings: TStringList; Timer: TTimer; Chooser: T532ArchiveChooser;
  Count: Integer;
  LastProgress, Updates, TotalPages: Integer; CancelConversion, WasCanceled: Boolean;
  ProgressRows: TJSONArray;
begin
  RequireIsolatedRegression;
  TestContentDrivenBookNames;
  TestConverterInputValidation;
  TestMonochromeReaderPictures;
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'catalogue-examples/examples.json',TEncoding.UTF8));
  Results:=TJSONArray.Create; Warnings:=TStringList.Create; Count:=0;
  Timer:=TTimer.Create(nil); Chooser:=T532ArchiveChooser.Create;
  try
    Timer.Interval:=80; Timer.OnTimer:=Chooser.Tick; Timer.Enabled:=True;
    Items:=Root.GetValue<TJSONArray>('examples');
    Require(Items.Count>0,'The catalogue audit must contain at least one real book');
    for Item in Items do
    begin
      Members:=TArray<string>.Create('');
      if Item.GetValue<Integer>('id')=710610 then
        Members:=TArray<string>.Create('assets/artofwar.epub','assets/fiverings.epub');
      for Member in Members do
      begin
      Chooser.RequestedMember:=Member; Chooser.SelectionError:=''; Chooser.SelectionCount:=0;
      Inc(Count); Row:=TJSONObject.Create; Results.AddElement(Row);
      if Member<>'' then Row.AddPair('archive_member',Member);
      Extension:=Item.GetValue<string>('extension'); Row.AddPair('extension',Extension);
      Row.AddPair('id',TJSONNumber.Create(Item.GetValue<Integer>('id')));
      FileName:=TPath.Combine(Settings.AppPath,'catalogue-examples\'+Item.GetValue<string>('name'));
      Hash:=UpdateSHA256(FileName); Require(SameText(Hash,Item.GetValue<string>('sha256')),'Audit example changed before reading');
      if (Extension='.cbz') or (Extension='.cbr') or (Extension='.pages') or (Extension='.cr3') or (Extension='.b1') then
      begin
        // A false extension must retain the complete book through ordinary preparation.
        TFile.Copy(FileName,FileName+'.wrong.pdf',False);FileName:=FileName+'.wrong.pdf';
      end;
      Book.Clear; Book.NodeType:=ntBookInfo; Book.BookKey:=CreateBookKey(Count,900532);
      Book.CollectionRoot:=ExtractFilePath(FileName); Book.FileName:=TPath.GetFileNameWithoutExtension(FileName);
      Book.FileExt:=ExtractFileExt(FileName); Book.Title:='Catalogue format audit';
      Prepared:=''; Started:=GetTickCount64; ErrorText:='';
      try
        Prepared:=PrepareReaderFile(Book,True,nil,False,True,True);
        OriginalPrepared:=Prepared;
        if Member<>'' then
        begin
          Require((Chooser.SelectionError='') and (Chooser.SelectionCount>0),'The actual APK archive picker did not select the requested EPUB: '+Chooser.SelectionError);
          if Member='assets/artofwar.epub' then
            Require(SameText(UpdateSHA256(Prepared),'a8e1e627070dcdd9121bd3ffb8c4f9c29f0988e37c36a4cf5aeba8055f02cc01'),'APK selection changed Art of War bytes')
          else
            Require(SameText(UpdateSHA256(Prepared),'03c8e22e0d1fd60369e9c09e771d570659b706fcc862ee7f6d0d42989fa517b8'),'APK selection changed Five Rings bytes');
          Row.AddPair('archive_selection','exact EPUB bytes');
        end;
        Row.AddPair('detected',ExtractFileExt(Prepared));
        if Item.GetValue<Integer>('id')=748625 then
        begin
          Require(SameText(ExtractFileExt(Prepared),'.pdf'),'B1 PDF opening was unnecessarily converted to reflow text');
          Require(SameText(UpdateSHA256(Prepared),'2f639b72de568e9bb17325506b3b6c65c877c828dd6245a277f7797581b1d323'),
            'B1 handoff changed the original archived PDF');
          Row.AddPair('original_pdf_handoff','exact bytes');
        end;
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
          Require(Chooser.SelectionError='',Chooser.SelectionError);
          if Member<>'' then
            Require(UpdateSHA256(Source)=UpdateSHA256(OriginalPrepared),'Bundle export selected an HTML preview or a different EPUB');
          if not IsBasicConversionSource(ExtractFileExt(Source)) then Row.AddPair(Target,'unsupported')
          else
          begin
            if (Item.GetValue<Integer>('id')=767324) and (Target='.fb2') then
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
            try
              // Verify results through the same preparation used by an actual
              // Open Book action, including image-heavy FB2 above the DOM limit.
              ConvertedBook.Clear; ConvertedBook.NodeType:=ntBookInfo;
              ConvertedBook.BookKey:=CreateBookKey(Count+500000,900532);
              ConvertedBook.CollectionRoot:=ExtractFilePath(OutputName);
              ConvertedBook.FileName:=TPath.GetFileNameWithoutExtension(OutputName);
              ConvertedBook.FileExt:=ExtractFileExt(OutputName); ConvertedBook.Title:='Converted audit';
              Prepared:=PrepareReaderFile(ConvertedBook,True,nil,False,True,True);
              Document.Load(Prepared); Require(Document.PlainText.Trim<>'','Conversion produced no readable text');
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
