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
  end;

implementation

uses Winapi.Windows, Winapi.ActiveX, Vcl.Graphics, FictionBook_21, unit_FB2Utils,
  unit_Interfaces, unit_ReaderCache, unit_Consts, System.Variants, dm_user,
  unit_BookMetadataCache, unit_PackageBookCover, unit_ReaderRaster, unit_ReaderPDFWorker,
  unit_XpsBookCover, unit_MHLExternalTools, unit_KindleBookCover;

type
  TPreviewThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Book: TBookRecord;
    Generation: Integer;
    NeedCover, NeedAnnotation, NeedMetadata, LocalSource: Boolean;
    Annotation, MetadataXML, Status: string;
    HasDescriptor, CoverAssigned, DamagedTitle, TitleDiffers: Boolean;
    MetadataTitle: string;
    Cover: TGraphic;
    RasterPixels:TBytes;
    RasterWidth,RasterHeight:Integer;
    destructor Destroy; override;
  end;

destructor TPreviewThread.Destroy;
begin Cover.Free; inherited; end;

procedure TPreviewThread.Execute;
var Stream: TStream; Document: IXMLFictionBook; HR: HRESULT; NeedFileAnnotation: Boolean;
  User: ISystemData; Collection: IBookCollection; Stored: TBookRecord;
  CoverBytes:TBytes; CoverStatus,PreviewKind:string; Image:TBytesStream;
  Raster:TReaderRaster; PDF:TReaderPDFWorker; GenericArchive,IsPDF:Boolean;
begin
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
            try Cover:=GetBookCover(Document); except end;
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
      if LocalSource and NeedCover and not Assigned(Cover) and IsBookCoverPackage(Book.FileExt) then
      begin
        try
          Stream:=OpenRawBookSource(Book,nil,function:Boolean begin Result:=Terminated; end);
          try
            CoverBytes:=ReadPackageBookCover(Stream,Book.FileExt,CoverStatus,
              function:Boolean begin Result:=Terminated; end);
          finally Stream.Free; end;
          if Terminated then Exit;
          if Length(CoverBytes)>0 then
          begin
            CoverAssigned:=True; Image:=TBytesStream.Create(CoverBytes);
            try Cover:=CreateGraphicFromStream(Image,64*1024*1024); finally Image.Free; end;
            if not Assigned(Cover) then CoverStatus:='Формат встроенной обложки пока недоступен для предпросмотра.';
          end;
          CoverBytes:=nil;
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Не удалось прочитать встроенную обложку: '+E.Message;
        end;
      end;
      if Terminated then Exit;
      if LocalSource and NeedCover and not Assigned(Cover) and IsKindleCoverFormat(Book.FileExt) then
      begin
        try
          Stream:=OpenRawBookSource(Book,nil,function:Boolean begin Result:=Terminated; end);
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
      if LocalSource and NeedCover and not Assigned(Cover) and SameText(Book.FileExt,'.xps') then
      begin
        try
          Stream:=OpenRawBookSource(Book,nil,function:Boolean begin Result:=Terminated; end);
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
      GenericArchive:=SameText(Book.FileExt,'.zip') or SameText(Book.FileExt,'.7z') or SameText(Book.FileExt,'.rar');
      IsPDF:=SameText(Book.FileExt,'.pdf');
      if LocalSource and NeedCover and not Assigned(Cover) and
        (IsRasterReaderFormat(Book.FileExt) or GenericArchive or IsPDF) then
      begin
        // Decode only page 0. PDFium stays in its existing isolated worker,
        // never in the catalogue's background apartment or Reader UI state.
        // Keep the cache lease open while reading an outer archive's member.
        try
          if IsPDF and not PDFWorkerAvailable then
            raise EReadError.Create('Для предпросмотра PDF нужен модуль чтения PDF (PDFium).');
          Stream:=OpenRawBookSource(Book,nil,function:Boolean begin Result:=Terminated; end);
          try
            if not (Stream is TFileStream) then raise EReadError.Create('Нет локального файла для предпросмотра.');
            if IsPDF then
            begin
              PDF:=TReaderPDFWorker.Create(TFileStream(Stream).FileName);
              try PDF.RenderPage(0,RasterPixels,RasterWidth,RasterHeight,600);
              finally PDF.Free; end;
            end
            else
            begin
              Raster:=TReaderRaster.Create(TFileStream(Stream).FileName,600,GenericArchive);
              try
                if Terminated then Exit;
                RasterPixels:=Raster.PreparedPagePixels(0,RasterWidth,RasterHeight);
              finally Raster.Free; end;
            end;
            PreviewKind:='Предпросмотр первой страницы.';
          finally Stream.Free; end;
        except
          on E:EAbort do Exit;
          on E:Exception do CoverStatus:='Предпросмотр первой страницы недоступен: '+E.Message;
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
        if CoverStatus<>'' then Status:=Status+CoverStatus
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
    Document:=nil; Collection:=nil;
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
  Bitmap:TBitmap;
begin
  FreeAndNil(FLoadStatus);
  Worker:=TPreviewThread(Sender);
  if FClosing or Worker.Terminated or (Worker.Generation<>FGeneration) then Exit;
  FPanel.BeginUpdate;
  try
    FPanel.SetPreviewStatus(Worker.Status);
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
