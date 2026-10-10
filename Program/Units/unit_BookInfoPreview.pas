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
    FPending, FClosing, FCover, FAnnotation, FMetadata: Boolean;
    procedure Tick(Sender: TObject);
    procedure Completed(Sender: TObject);
  public
    constructor CreateFor(Owner: TComponent; Panel: TInfoPanel);
    destructor Destroy; override;
    procedure Cancel;
    procedure Load(const Book: TBookRecord; Cover, Annotation, Metadata: Boolean);
    function Busy: Boolean;
  end;

implementation

uses Winapi.Windows, Winapi.ActiveX, Vcl.Graphics, FictionBook_21, unit_FB2Utils;

type
  TPreviewThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Book: TBookRecord;
    Generation: Integer;
    NeedCover, NeedAnnotation, NeedMetadata: Boolean;
    Annotation, MetadataXML, Status: string;
    HasDescriptor, CoverAssigned, DamagedTitle, TitleDiffers: Boolean;
    MetadataTitle: string;
    Cover: TGraphic;
    destructor Destroy; override;
  end;

destructor TPreviewThread.Destroy;
begin Cover.Free; inherited; end;

procedure TPreviewThread.Execute;
var Stream: TStream; Document: IXMLFictionBook; HR: HRESULT;
begin
  HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try
    try
      if Terminated then Exit;
      if NeedCover then
      begin
        Stream:=Book.GetBookPreviewCoverStream;
        try Cover:=CreateGraphicFromStream(Stream); finally Stream.Free; end;
      end;
      if Terminated then Exit;
      if (NeedAnnotation or NeedMetadata or (NeedCover and not Assigned(Cover))) then
      begin
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
          if NeedAnnotation then
            try Annotation:=GetBookAnnotation(Document); except Annotation:=''; end;
          // COM nodes stay in the worker apartment. Only the small description
          // and a raster image are handed to the UI; the full FB2 is released here.
          if NeedMetadata then MetadataXML:='<FictionBook xmlns="'+TargetNamespace+'">'+
            Document.Description.XML+'</FictionBook>';
        finally Document:=nil; Stream.Free; end;
      end;
      if NeedAnnotation and (Trim(Annotation)='') then
        if HasDescriptor then Status:='В файле нет аннотации.'
        else Status:='Аннотация для этого файла недоступна.';
      if NeedCover and not Assigned(Cover) then
      begin
        if Status<>'' then Status:=Status+sLineBreak;
        if CoverAssigned then Status:=Status+'Не удалось прочитать обложку из файла.'
        else if HasDescriptor then Status:=Status+'Обложка в метаданных не задана.'
        else Status:=Status+'Обложка для этого файла недоступна.';
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
    except
      Status:='Не удалось прочитать дополнительные сведения из файла. Показаны данные каталога.';
    end;
  finally
    Document:=nil;
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

procedure TBookInfoPreview.Load(const Book: TBookRecord; Cover, Annotation, Metadata: Boolean);
begin
  Cancel; FBook:=Book; FCover:=Cover; FAnnotation:=Annotation; FMetadata:=Metadata;
  FPending:=Cover or Annotation or Metadata;
  if FPending then FPanel.SetPreviewStatus('Загрузка дополнительных сведений из файла…');
  FTimer.Enabled:=FPending or Assigned(FWorker);
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
  Worker.OnTerminate:=Completed; Worker.Start;
end;

procedure TBookInfoPreview.Completed(Sender: TObject);
var Worker: TPreviewThread; Stream: TStringStream; Document: IXMLFictionBook;
begin
  FreeAndNil(FLoadStatus);
  Worker:=TPreviewThread(Sender);
  if FClosing or Worker.Terminated or (Worker.Generation<>FGeneration) then Exit;
  FPanel.BeginUpdate;
  try
    FPanel.SetPreviewStatus(Worker.Status);
    if Worker.NeedCover then FPanel.SetBookCover(Worker.Cover);
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
