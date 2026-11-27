unit unit_BookInfoPreview;

interface

uses unit_MHLOperationStatus, System.Classes, System.SysUtils, Vcl.ExtCtrls, BookInfoPanel, unit_Globals;

type
  // One background reader per view, with a single pending (latest) selection.
  TBookInfoPreview = class(TComponent)
  private
    FLoadStatus: TMHLOperationStatus;
    FPanel: TInfoPanel;
    FTimer: TTimer;
    FWorker: TThread;
    FBook: TBookRecord;
    FGeneration: Integer;
    FPending, FClosing, FCover, FAnnotation, FMetadata, FLocalSource: Boolean;
    FOnRequestComponent: TProc<string>;
    procedure Tick(Sender: TObject);
    procedure Completed(Sender: TObject);
  public
    constructor CreateFor(Owner: TComponent; Panel: TInfoPanel);
    destructor Destroy; override;
    procedure Cancel;
    procedure Load(const Book: TBookRecord; Cover, Annotation, Metadata: Boolean;
      LocalSource: Boolean = True);
    procedure UpdateReadingProgress(const Book: TBookRecord);
    function Busy: Boolean;
    property OnRequestComponent: TProc<string> read FOnRequestComponent write FOnRequestComponent;
  end;

implementation

uses Winapi.Windows, Winapi.ActiveX, Winapi.RichEdit, Vcl.Graphics, FictionBook_21, unit_FB2Utils,
  System.StrUtils, System.Zip, unit_ReaderDocument, unit_ReaderRichEdit,
  unit_Interfaces, unit_ReaderCache, unit_Consts, System.Variants, dm_user,
  unit_BookMetadataCache, unit_PackageBookCover, unit_ReaderRaster, unit_ReaderPDFWorker,
  unit_XpsBookCover, unit_MHLExternalTools, unit_KindleBookCover, unit_KfxBookCover,
  unit_SvgBookCover, unit_BookCache, unit_ReaderFormats;

type
  TPreviewThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Book: TBookRecord;
    Generation: Integer;
    NeedCover, NeedAnnotation, NeedMetadata, LocalSource: Boolean;
    Annotation, MetadataXML, Status, RequiredCoverComponent: string;
    HasDescriptor, CoverAssigned, DamagedTitle, TitleDiffers: Boolean;
    MetadataTitle: string;
    Cover: TGraphic;
    RasterPixels:TBytes;
    RasterWidth,RasterHeight:Integer;
    destructor Destroy; override;
  end;

destructor TPreviewThread.Destroy;
begin Cover.Free; inherited; end;

function RenderReflowOpeningPage(Source: TStream; const Extension: string; const Canceled: TFunc<Boolean>;
  out Pixels: TBytes; out Width, Height: Integer): Boolean;
const
  PageWidth=380;
  PageHeight=540;
  Margin=22;
  MaxSourceBytes=8*1024*1024;
  MaxUnpackedBytes=32*1024*1024;
var
  Archive: TZipFile;
  Unpacked: UInt64;
  Deadline: UInt64;
  Document: TReaderDocument;
  LibraryHandle: HMODULE;
  SystemDirectory: array[0..MAX_PATH] of Char;
  EditWindow: HWND;
  Callback: IInterface;
  RTF: TReaderRTFStream;
  DC: HDC;
  Bitmap: HBITMAP;
  Previous: HGDIOBJ;
  View: Pointer;
  Info: TBitmapInfo;
  Range: TFormatRange;
  EndPosition, DPI: Integer;
  PicturePositions: TArray<Integer>;
  PastDeadline: TFunc<Boolean>;

begin
  Result:=False;
  if not (Source is TFileStream) or (Source.Size>MaxSourceBytes) then Exit;
  if MatchText(Extension,['.epub','.fb3','.docx','.odt']) then
  begin
    Archive:=TZipFile.Create;
    try
      Archive.Open(TFileStream(Source).FileName,zmRead);
      Unpacked:=0;
      for var Index:=0 to Archive.FileCount-1 do
      begin
        if Canceled() then Abort;
        var PartSize:=Archive.FileInfo[Index].UncompressedSize64;
        if PartSize>MaxUnpackedBytes-Unpacked then Exit;
        Inc(Unpacked,PartSize);
      end;
    finally Archive.Free; end;
  end;

  Deadline:=GetTickCount64+1800;
  PastDeadline:=function: Boolean
    begin Result:=Canceled() or (GetTickCount64>=Deadline); end;
  Document:=TReaderDocument.Create;
  LibraryHandle:=0; EditWindow:=0; DC:=0; Bitmap:=0; Previous:=0;
  try
    Document.Load(TFileStream(Source).FileName,PastDeadline);
    if PastDeadline() then Abort;
    if GetSystemDirectory(SystemDirectory,Length(SystemDirectory))=0 then RaiseLastOSError;
    LibraryHandle:=LoadLibrary(PChar(IncludeTrailingPathDelimiter(SystemDirectory)+'Msftedit.dll'));
    if LibraryHandle=0 then RaiseLastOSError;
    EditWindow:=CreateWindowEx(0,'RICHEDIT50W',nil,WS_POPUP or ES_MULTILINE,0,0,PageWidth,PageHeight,0,0,0,nil);
    if EditWindow=0 then RaiseLastOSError;
    Callback:=AttachReaderPictures(EditWindow,False);
    SendMessage(EditWindow,EM_SETUNDOLIMIT,0,0);
    RTF:=TReaderRTFStream.Create(Document.RTF(PageWidth-2*Margin,PageHeight-3*Margin,True,clWhite));
    try ReaderLoadRTF(EditWindow,RTF); finally RTF.Free; end;
    if ReaderTextLength(EditWindow)=0 then Exit;

    FillChar(Info,SizeOf(Info),0);
    Info.bmiHeader.biSize:=SizeOf(Info.bmiHeader);
    Info.bmiHeader.biWidth:=PageWidth;
    Info.bmiHeader.biHeight:=-PageHeight;
    Info.bmiHeader.biPlanes:=1;
    Info.bmiHeader.biBitCount:=32;
    DC:=CreateCompatibleDC(0);
    if DC=0 then RaiseLastOSError;
    Bitmap:=CreateDIBSection(DC,Info,DIB_RGB_COLORS,View,0,0);
    if Bitmap=0 then RaiseLastOSError;
    Previous:=SelectObject(DC,Bitmap);
    if Previous=0 then RaiseLastOSError;
    PatBlt(DC,0,0,PageWidth,PageHeight,WHITENESS);
    DPI:=GetDeviceCaps(DC,LOGPIXELSY);
    FillChar(Range,SizeOf(Range),0);
    Range.hdc:=DC; Range.hdcTarget:=DC;
    Range.rcPage:=Rect(0,0,MulDiv(PageWidth,1440,DPI),MulDiv(PageHeight,1440,DPI));
    Range.rc:=Range.rcPage;
    InflateRect(Range.rc,-MulDiv(Margin,1440,DPI),-MulDiv(Margin,1440,DPI));
    Range.chrg.cpMax:=-1;
    EndPosition:=SendMessage(EditWindow,EM_FORMATRANGE,0,LPARAM(@Range));
    SendMessage(EditWindow,EM_FORMATRANGE,0,0);
    if EndPosition<=0 then Exit;
    PicturePositions:=ReaderPicturePositions(EditWindow);
    for var Index:=0 to High(PicturePositions) do
    begin
      if PicturePositions[Index]>=EndPosition then Break;
      if PastDeadline() then Abort;
      RTF:=TReaderRTFStream.Create(UTF8String('{\rtf1\ansi ')+
        Document.PictureRTF(Index,PageWidth-2*Margin,PageHeight-3*Margin,False,clWhite)+UTF8String('}'));
      try ReaderReplaceRTFRange(EditWindow,RTF,PicturePositions[Index],1); finally RTF.Free; end;
    end;
    Range.chrg.cpMax:=EndPosition;
    if PastDeadline() then Abort;
    if SendMessage(EditWindow,EM_FORMATRANGE,1,LPARAM(@Range))<=0 then Exit;
    GdiFlush;
    SetLength(Pixels,PageWidth*PageHeight*4);
    Move(View^,Pixels[0],Length(Pixels));
    Width:=PageWidth; Height:=PageHeight; Result:=True;
  finally
    if Previous<>0 then SelectObject(DC,Previous);
    if Bitmap<>0 then DeleteObject(Bitmap);
    if DC<>0 then DeleteDC(DC);
    if EditWindow<>0 then
    begin
      SendMessage(EditWindow,EM_FORMATRANGE,0,0);
      DestroyWindow(EditWindow);
    end;
    Callback:=nil;
    if LibraryHandle<>0 then FreeLibrary(LibraryHandle);
    Document.Free;
  end;
end;

procedure TPreviewThread.Execute;
var Stream, ArchiveStream, PreviewLease: TStream; Corrected: TFileStream; Document: IXMLFictionBook; HR: HRESULT; NeedFileAnnotation: Boolean;
  User: ISystemData; Collection: IBookCollection; Stored: TBookRecord;
  CoverBytes:TBytes; CoverStatus,PreviewKind,PreviewFile,PreviewExtension:string; Image:TBytesStream;
  Raster:TReaderRaster; PDF:TReaderPDFWorker; IsPDF:Boolean;
  function OpenCoverSource: TStream;
  begin
    if Assigned(PreviewLease) then Result:=OpenCachedBookFile(PreviewFile)
    else Result:=OpenRawBookSource(Book,nil,function:Boolean begin Result:=Terminated; end);
  end;
begin
  ArchiveStream:=nil; PreviewLease:=nil; PreviewExtension:=Book.FileExt;
  HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try
    try
      if Terminated then Exit;
      if NeedAnnotation then
      begin
        Annotation:=Book.Annotation;
        if (Trim(Annotation)='') and (Book.BookKey.BookID>0) then
        try
          User:=DMUser.GetSystemDBConnection;
          Collection:=User.GetCollection(Book.BookKey.DatabaseID);
          Collection.GetBookRecord(Book.BookKey,Stored,True);
          if ReaderBookMatchesExpectedIdentity(Book.LibID,ReaderBookPhysicalIdentity(Book),Stored,
            VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY))) then Annotation:=Stored.Annotation;
        except
          // A temporarily disconnected catalog must not prevent a local file
          // preview. The captured book remains the identity of this request.
        end;
        Collection:=nil;
        if Assigned(User) then User.ClearCollectionCache;
        User:=nil;
      end;
      NeedFileAnnotation:=NeedAnnotation and (Trim(Annotation)='');
      if LocalSource and NeedCover then
      begin
        // A broken optional sidecar cover must not suppress the book's own
        // description/cover or the annotation already obtained from the catalog.
        try
          Stream:=Book.GetBookPreviewCoverStream(function:Boolean begin Result:=Terminated; end);
          try Cover:=CreateGraphicFromStream(Stream,64*1024*1024); finally Stream.Free; end;
        except on E:EAbort do Exit;
          on E: EMHLComponentRequired do
          begin
            if E.ComponentID='JPEG XL' then RequiredCoverComponent:=E.ComponentID
            else Status:='Не удалось прочитать отдельную обложку: '+E.Message;
          end;
          on E: Exception do
          Status:='Не удалось прочитать отдельную обложку: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      if LocalSource and (NeedFileAnnotation or NeedMetadata or (NeedCover and not Assigned(Cover))) then
      begin
        try
        Stream:=Book.GetBookDescriptorStream(False);
        if Assigned(Stream) then
        try
          if Terminated then Exit;
          Document:=LoadFB2Description(Stream,NeedCover and not Assigned(Cover));
          if Terminated then Exit;
          HasDescriptor:=True;
          CoverAssigned:=Document.Description.Titleinfo.Coverpage.Count>0;
          MetadataTitle:=Trim(Document.Description.Titleinfo.Booktitle.Text);
          DamagedTitle:=Pos(Char($FFFD),MetadataTitle)>0;
          TitleDiffers:=(MetadataTitle<>'') and (Trim(Book.Title)<>'') and
            not SameText(MetadataTitle,Trim(Book.Title));
          if NeedCover and not Assigned(Cover) then
            try
              Cover:=GetBookCover(Document,Settings.TempDir,function:Boolean begin Result:=Terminated; end);
            except
              on E:EAbort do raise;
              on E:Exception do CoverStatus:='Не удалось прочитать обложку FB2: '+E.Message;
            end;
          if NeedFileAnnotation then
            try Annotation:=GetBookAnnotation(Document); except Annotation:=''; end;
          // COM nodes stay in the worker apartment. Only the small description
          // and a raster image are handed to the UI; the full FB2 is released here.
          if NeedMetadata then MetadataXML:='<FictionBook xmlns="'+TargetNamespace+'">'+
            Document.Description.XML+'</FictionBook>';
        finally Document:=nil; Stream.Free; end;
        except
          on E:EAbort do Exit;
          on E:EOutOfMemory do raise;
          on E:Exception do Status:='Не удалось прочитать описание файла: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      if LocalSource and NeedCover and not Assigned(Cover) and IsReaderContainer(Book.FileName+Book.FileExt) then
      begin
        PreviewExtension:='';
        try
          ArchiveStream:=OpenRawBookSource(Book,nil,function:Boolean begin Result:=Terminated; end);
          if not (ArchiveStream is TFileStream) then
            raise EReadError.Create('Нет локального файла для предпросмотра.');
          PreviewFile:=PrepareArchivePreviewFile(Book,TFileStream(ArchiveStream).FileName,
            function:Boolean begin Result:=Terminated; end);
          if Terminated then Exit;
          if PreviewFile<>'' then
          begin
            PreviewLease:=OpenCachedBookFile(PreviewFile);
            PreviewExtension:=ExtractFileExt(PreviewFile);
          end;
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Обложка книги в архиве недоступна. '+E.Message;
        end;
      end;
      if Assigned(PreviewLease) and SameText(PreviewExtension,'.fb2') then
      begin
        try
          Document:=LoadFB2Description(PreviewLease,True);
          CoverAssigned:=Document.Description.Titleinfo.Coverpage.Count>0;
          Cover:=GetBookCover(Document,Settings.TempDir,function:Boolean begin Result:=Terminated; end);
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Не удалось прочитать обложку FB2: '+E.Message;
        end;
        Document:=nil;
      end;
      if Terminated then Exit;
      if LocalSource and NeedCover and not Assigned(Cover) and IsBookCoverPackage(PreviewExtension) then
      begin
        try
          Stream:=OpenCoverSource;
          try
            CoverBytes:=ReadPackageBookCover(Stream,PreviewExtension,CoverStatus,
              function:Boolean begin Result:=Terminated; end,
              function(Data:TBytes):TBytes
              begin
                Result:=RenderSvgBookCover(Data,FindExternalTool('resvg.exe','kfx-export'),
                  Settings.TempDir,function:Boolean begin Result:=Terminated; end);
              end);
          finally Stream.Free; end;
          if Terminated then Exit;
          if Length(CoverBytes)>0 then
          begin
            CoverAssigned:=True;
            Cover:=CreatePackageCoverGraphic(CoverBytes,64*1024*1024);
            if not Assigned(Cover) then CoverStatus:='Формат встроенной обложки пока недоступен для предпросмотра.';
          end;
          CoverBytes:=nil;
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Не удалось прочитать встроенную обложку: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      if LocalSource and NeedCover and not Assigned(Cover) and IsKindleCoverFormat(PreviewExtension) then
      begin
        try
          Stream:=OpenCoverSource;
          try
            CoverBytes:=ReadKindleBookCover(Stream,CoverStatus,function:Boolean begin Result:=Terminated; end);
          finally Stream.Free; end;
          if Terminated then Exit;
          if Length(CoverBytes)>0 then
          begin
            CoverAssigned:=True; Image:=TBytesStream.Create(CoverBytes);
            try Cover:=CreateGraphicFromStream(Image,64*1024*1024); finally Image.Free; end;
            if Assigned(Cover) then PreviewKind:=CoverStatus
            else CoverStatus:='Не удалось прочитать изображение обложки Kindle.';
          end;
          CoverBytes:=nil;
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Не удалось прочитать обложку Kindle: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      if LocalSource and NeedCover and not Assigned(Cover) and
        (SameText(PreviewExtension,'.kfx') or SameText(PreviewExtension,'.azw8')) then
      begin
        try
          Stream:=OpenCoverSource;
          try
            if not (Stream is TFileStream) then raise EReadError.Create('Нет локального файла для чтения обложки KFX.');
            CoverBytes:=ReadKfxBookCover(TFileStream(Stream).FileName,
              FindExternalTool('boko.exe','kfx-export'),function:Boolean begin Result:=Terminated; end);
          finally Stream.Free; end;
          if Terminated then Exit;
          if Length(CoverBytes)>0 then
          begin
            CoverAssigned:=True; Image:=TBytesStream.Create(CoverBytes);
            try Cover:=CreateGraphicFromStream(Image,64*1024*1024); finally Image.Free; end;
            if not Assigned(Cover) then CoverStatus:='Не удалось прочитать изображение обложки KFX.';
          end;
          CoverBytes:=nil;
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Обложка KFX недоступна: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      if LocalSource and NeedCover and not Assigned(Cover) and
        (SameText(PreviewExtension,'.xps') or SameText(PreviewExtension,'.oxps')) then
      begin
        try
          Stream:=OpenCoverSource;
          try
            if not (Stream is TFileStream) then raise EReadError.Create('Нет локального файла для предпросмотра.');
            CoverBytes:=ReadXpsBookCover(TFileStream(Stream).FileName,
              FindExternalTool('HomeLibXps.exe','xps'),Settings.TempDir,
              function:Boolean begin Result:=Terminated; end);
          finally Stream.Free; end;
          if Terminated then Exit;
          Image:=TBytesStream.Create(CoverBytes);
          try Cover:=CreateGraphicFromStream(Image,64*1024*1024); finally Image.Free; end;
          CoverBytes:=nil;
          if Assigned(Cover) then PreviewKind:='Предпросмотр первой страницы.'
          else CoverStatus:='Не удалось прочитать предпросмотр XPS.';
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Предпросмотр первой страницы недоступен: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      IsPDF:=SameText(PreviewExtension,'.pdf');
      if LocalSource and NeedCover and not Assigned(Cover) and
        (IsRasterReaderFormat(PreviewExtension) or IsPDF) then
      begin
        // Decode only page 0. PDFium stays in its isolated worker.
        try
          Stream:=OpenCoverSource;
          Corrected:=nil;
          try
            if not (Stream is TFileStream) then raise EReadError.Create('Нет локального файла для предпросмотра.');
            PreviewFile:=TFileStream(Stream).FileName;
            if IsPDF then
            begin
              if not PDFWorkerAvailable then
                raise EReadError.Create('Для предпросмотра PDF нужен модуль чтения PDF (PDFium).');
              Corrected:=OpenCorrectedPDF(PreviewFile);
              if Assigned(Corrected) then PreviewFile:=Corrected.FileName;
              PDF:=TReaderPDFWorker.Create(PreviewFile);
              try PDF.RenderPage(0,RasterPixels,RasterWidth,RasterHeight,600);
              finally PDF.Free; end;
            end
            else
            begin
              Raster:=TReaderRaster.Create(PreviewFile,600);
              try
                if Terminated then Exit;
                RasterPixels:=Raster.PreparedPagePixels(0,RasterWidth,RasterHeight);
              finally Raster.Free; end;
            end;
            PreviewKind:='Предпросмотр первой страницы.';
          finally Corrected.Free; Stream.Free; end;
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Предпросмотр первой страницы недоступен: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      if LocalSource and NeedCover and not Assigned(Cover) and (Length(RasterPixels)=0) and
        (RequiredCoverComponent='') and MatchText(PreviewExtension,
          ['.fb2','.fb3','.epub','.txt','.html','.htm','.xhtml','.rtf','.docx','.odt']) then
      begin
        try
          Stream:=OpenCoverSource;
          try
            if RenderReflowOpeningPage(Stream,PreviewExtension,function:Boolean begin Result:=Terminated; end,
              RasterPixels,RasterWidth,RasterHeight) then PreviewKind:='Предпросмотр первой страницы.';
          finally Stream.Free; end;
        except
          on E:EAbort do if Terminated then Exit;
          on E:EMHLComponentRequired do if E.ComponentID='JPEG XL' then RequiredCoverComponent:=E.ComponentID;
          on E:Exception do if CoverStatus='' then CoverStatus:='Предпросмотр первой страницы недоступен: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      if NeedAnnotation and (Trim(Annotation)='') then
      begin
        if Status<>'' then Status:=Status+sLineBreak;
        if HasDescriptor then Status:=Status+'В файле нет аннотации.'
        else Status:=Status+'Аннотация для этого файла недоступна.';
      end;
      if NeedCover and not Assigned(Cover) and (Length(RasterPixels)=0) then
      begin
        if Status<>'' then Status:=Status+sLineBreak;
        if RequiredCoverComponent='JPEG XL' then Status:=Status+'Для этой обложки нужен декодер JPEG XL.'
        else if CoverStatus<>'' then Status:=Status+CoverStatus
        else if CoverAssigned then Status:=Status+'Не удалось прочитать обложку из файла.'
        else if HasDescriptor then Status:=Status+'Обложка в метаданных не задана.'
        else Status:=Status+'Обложка для этого файла недоступна.';
      end;
      if (Assigned(Cover) or (Length(RasterPixels)>0)) and (PreviewKind<>'') then
      begin
        if Status<>'' then Status:=Status+sLineBreak;
        Status:=Status+PreviewKind;
      end;
      if DamagedTitle then
      begin
        if Status<>'' then Status:=Status+sLineBreak;
        Status:=Status+'Название в метаданных повреждено; показано название из каталога.';
      end
      else if TitleDiffers then
      begin
        if Status<>'' then Status:=Status+sLineBreak;
        Status:=Status+'Название в файле отличается от каталога: «'+Copy(MetadataTitle,1,120)+
          '». Показано название из каталога.';
      end;
    except on E: Exception do
      Status:='Не удалось прочитать дополнительные сведения из файла: '+E.Message+
        sLineBreak+'Показаны данные каталога. Книга: '+Book.FileName+Book.FileExt;
    end;
  finally
    Document:=nil; PreviewLease.Free; ArchiveStream.Free; Collection:=nil;
    if Assigned(User) then User.ClearCollectionCache;
    User:=nil;
    if Succeeded(HR) then CoUninitialize;
  end;
end;

constructor TBookInfoPreview.CreateFor(Owner: TComponent; Panel: TInfoPanel);
begin
  inherited Create(Owner); FPanel:=Panel;
  FTimer:=TTimer.Create(Self); FTimer.Interval:=100; FTimer.Enabled:=False;
  FTimer.OnTimer:=Tick;
end;

destructor TBookInfoPreview.Destroy;
begin
  FClosing:=True; FreeAndNil(FLoadStatus); FTimer.Enabled:=False;
  if Assigned(FWorker) then
  begin FWorker.Terminate; FWorker.WaitFor; FreeAndNil(FWorker); end;
  inherited;
end;

procedure TBookInfoPreview.Cancel;
begin
  Inc(FGeneration); FPending:=False; FreeAndNil(FLoadStatus);
  FPanel.SetPreviewAction('');
  if Assigned(FWorker) then FWorker.Terminate else FTimer.Enabled:=False;
end;

procedure TBookInfoPreview.Load(const Book: TBookRecord; Cover, Annotation, Metadata, LocalSource: Boolean);
begin
  Cancel; FBook:=Book; FCover:=Cover; FAnnotation:=Annotation; FMetadata:=Metadata; FLocalSource:=LocalSource;
  FPanel.SetBookKeywords(Book.KeyWords);
  FPanel.SetReadingProgress(Book.Progress);
  FPending:=Cover or Annotation or Metadata;
  if FPending then FPanel.SetPreviewStatus('Загрузка дополнительных сведений из файла…');
  FTimer.Enabled:=FPending or Assigned(FWorker);
end;

procedure TBookInfoPreview.UpdateReadingProgress(const Book: TBookRecord);
begin
  if FPanel.DetailsButton.Visible and FBook.BookKey.IsSameAs(Book.BookKey) then
    FPanel.SetReadingProgress(Book.Progress);
end;

function TBookInfoPreview.Busy: Boolean;
begin Result:=FPending or Assigned(FWorker); end;

procedure TBookInfoPreview.Tick(Sender: TObject);
var Worker: TPreviewThread;
begin
  if Assigned(FWorker) then
  begin
    if not FWorker.Finished then Exit;
    FWorker.WaitFor; FreeAndNil(FWorker);
  end;
  if not FPending then begin FTimer.Enabled:=False; Exit; end;
  FPending:=False;
  FLoadStatus:=TMHLOperationStatus.Create('Чтение сведений о книге из архива…');
  Worker:=TPreviewThread.Create(True); FWorker:=Worker; Worker.FreeOnTerminate:=False;
  Worker.Book:=FBook; Worker.Generation:=FGeneration;
  Worker.NeedCover:=FCover; Worker.NeedAnnotation:=FAnnotation; Worker.NeedMetadata:=FMetadata;
  Worker.LocalSource:=FLocalSource;
  Worker.OnTerminate:=Completed; Worker.Start;
end;

procedure TBookInfoPreview.Completed(Sender: TObject);
var Worker: TPreviewThread; Stream: TStringStream; Document: IXMLFictionBook;
  Bitmap:TBitmap; RequiredComponent: string; RequestComponent: TProc<string>;
begin
  FreeAndNil(FLoadStatus);
  Worker:=TPreviewThread(Sender);
  if FClosing or Worker.Terminated or (Worker.Generation<>FGeneration) then Exit;
  FPanel.BeginUpdate;
  try
    FPanel.SetPreviewStatus(Worker.Status);
    RequiredComponent:=Worker.RequiredCoverComponent;
    if (RequiredComponent='JPEG XL') and not Assigned(Worker.Cover) and
      (Length(Worker.RasterPixels)=0) and Assigned(FOnRequestComponent) then
    begin
      RequestComponent:=FOnRequestComponent;
      FPanel.SetPreviewAction('Установить JPEG XL…',
        procedure begin RequestComponent(RequiredComponent); end);
    end;
    if Worker.HasDescriptor then FPanel.Gallery.UseDescriptorImages;
    if Worker.NeedCover then
      if Length(Worker.RasterPixels)>0 then
      begin
        Bitmap:=TBitmap.Create;
        try
          Bitmap.PixelFormat:=pf32bit; Bitmap.SetSize(Worker.RasterWidth,Worker.RasterHeight);
          // VCL ScanLine already maps visual top-to-bottom rows to its DIB.
          for var Y:=0 to Worker.RasterHeight-1 do
            Move(Worker.RasterPixels[Y*Worker.RasterWidth*4],
              Bitmap.ScanLine[Y]^,Worker.RasterWidth*4);
          FPanel.SetBookCover(Bitmap);
        finally Bitmap.Free; end;
      end
      else FPanel.SetBookCover(Worker.Cover);
    if Worker.NeedAnnotation then FPanel.SetBookAnnotationText(Worker.Annotation);
    if Worker.MetadataXML<>'' then
    begin
      Stream:=TStringStream.Create(Worker.MetadataXML,TEncoding.UTF8);
      try
        try
          Document:=LoadFictionBook(Stream);
          FPanel.SetFb2Info(Document,Worker.Book.Folder,Worker.Book.FileName+Worker.Book.FileExt);
        except end;
      finally Document:=nil; Stream.Free; end;
    end;
  finally FPanel.EndUpdate; end;
end;

end.
