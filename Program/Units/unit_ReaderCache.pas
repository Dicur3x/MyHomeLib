unit unit_ReaderCache;

interface

uses
  System.Classes, System.SysUtils, unit_Globals, unit_Interfaces;

function ReaderCopyName(const Book: TBookRecord): string;
function PrepareReaderFile(const Book: TBookRecord; const PreserveImages: Boolean = False; const OnStage: TProc<string> = nil; OpenArchive: Boolean = False; ConvertKindle: Boolean = False; ConvertOffice: Boolean = False): string;
procedure PrepareReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive: Boolean = False; ConvertKindle: Boolean = False; ConvertOffice: Boolean = False);
function IsReaderArchive(const FileName: string): Boolean;
procedure CancelReaderPreparations(Owner: TComponent);
function ResolveReaderBook(const Collection: IBookCollection; const Book: TBookRecord): TBookRecord;

implementation

uses
  System.IOUtils, System.Hash,
  System.Generics.Collections, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls,
  Vcl.ExtCtrls, System.SyncObjs, unit_MHLOperationStatus,
  Winapi.Windows, unit_ReaderFormats, unit_ReaderKindle, unit_ReaderOffice, unit_Settings, unit_Consts, unit_FLibraryCompat, unit_MHLExternalTools,
  unit_MHLArchiveHelpers, unit_WebPCompat, unit_BookMetadataCache, unit_BookCache, dm_user, unit_ProgramUpdates;

type TReaderThreadAccess = class(TThread);

function IsReaderArchive(const FileName: string): Boolean;
var Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  Result := (Ext = '.zip') or (Ext = '.7z') or (Ext = '.rar') or
    (Ext = '.cbz') or (Ext = '.cbr') or (Ext = '.cb7') or (Ext = '.tar') or
    (Ext = '.gz') or (Ext = '.bz2') or (Ext = '.xz') or (Ext = '.cab') or (Ext = '.tgz') or (Ext = '.7zip');
end;

function IsReaderContainer(const FileName: string): Boolean;
var Ext: string;
begin
  Ext:=LowerCase(ExtractFileExt(FileName));
  // Comic archives remain intact for a comic reader, preserving image order.
  Result:=IsReaderArchive(FileName) and (Ext<>'.cbr') and (Ext<>'.cbz') and (Ext<>'.cb7');
end;

function ReaderCopyName(const Book: TBookRecord): string;
var Identity, Extension: string;
begin
  Identity := Book.LibID;
  if Identity = '' then
    Identity := LowerCase(Book.Folder + #1 + Book.FileName + Book.FileExt);
  // BookID, author and title can change after a full INPX import.
  Extension:='.'+Book.GetFileType;
  if (Pos(' ',Extension)>0) or (Length(Extension)>11) then Extension:='.bin';
  Result := 'homelib-' + IntToStr(Book.BookKey.DatabaseID) + '-' +
    Copy(THashSHA2.GetHashString(Identity), 1, 32) + Extension;
end;

function ResolveReaderBook(const Collection: IBookCollection; const Book: TBookRecord): TBookRecord;
var CopyBook: TBookRecord;
begin
  Result := Book;
  if FileExists(Book.GetBookFileName) or not Assigned(Collection) then Exit;
  for CopyBook in Collection.GetCatalogBookCopies(Book.BookKey) do
    if FileExists(CopyBook.GetBookFileName) then
    begin
      Result.Folder := CopyBook.Folder; Result.CollectionRoot := CopyBook.CollectionRoot;
      Result.FileName := CopyBook.FileName; Result.FileExt := CopyBook.FileExt;
      Result.InsideNo := CopyBook.InsideNo; Result.Size := CopyBook.Size;
      Include(Result.BookProps, bpIsLocal); Exit;
    end;
end;

function FileStamp(const Source: string; Required: Boolean): string;
var Data: TWin32FileAttributeData;
begin
  if not GetFileAttributesEx(PChar(Source), GetFileExInfoStandard, @Data) then
  begin
    if Required then RaiseLastOSError;
    Exit(Source + '|absent');
  end;
  Result := LowerCase(TPath.GetFullPath(Source)) + '|' +
    IntToStr(Data.nFileSizeHigh) + ':' + IntToStr(Data.nFileSizeLow) + '|' +
    IntToStr(Data.ftLastWriteTime.dwHighDateTime) + ':' + IntToStr(Data.ftLastWriteTime.dwLowDateTime);
end;

function SourceStamp(const Book: TBookRecord; const Source: string; const ConvertImages: Boolean): string;
var Dependency: string;
begin
  Result := 'reader-cache-v1|' + FileStamp(Source, True) + '|' +
    Book.FileName + Book.FileExt + '|' + IntToStr(Book.InsideNo) + '|' +
    BoolToStr(ConvertImages, True) + '|' + PROGRAM_RELEASE_VERSION;
  if SameText(ExtractFileExt(Source), '.7z') then
    for Dependency in FLibraryImageSourceFiles(Source) do
      Result := Result + '|' + FileStamp(Dependency, False);
  Result := Result + '|' + FileStamp(FindExternalTool('djxl.exe', 'jpeg-xl'), False) +
    '|' + FileStamp(Settings.AppPath + 'tools\webp\libwebp.dll', False);
end;

function PrepareLooseArchive(const Book: TBookRecord; const Source: string; const ConvertImages: Boolean; const OnStage: TProc<string>): string;
var Archive: TMHLZip; Candidates: TList<Integer>; I, Entry: Integer;
  Member, Extension, Folder, Stamp, StampFile, Temporary: string;
  Dialog: TForm; Names: TListBox; OpenButton, CancelButton: TButton; LabelControl: TLabel;
  Extracted: TFileStream; Converted: TStream; Writer: TBookCacheWrite; RequestingThread: TThread;
begin
  RequestingThread := TThread.CurrentThread;
  if Assigned(OnStage) then OnStage('Просмотр содержимого архива…');
  Result := '';
  Archive := TMHLZip.Create(Source, True, False,
    function: Boolean begin Result:=(GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated; end,
    not SameText(ExtractFileExt(Source),'.zip'));
  Candidates := TList<Integer>.Create;
  try
    for I := 0 to Archive.FileCount - 1 do
    begin
      Extension := LowerCase(ExtractFileExt(Archive.FileNames[I]));
      // Only reading formats; archive entry paths are never used as output paths.
      if (Extension = '.fb2') or (Extension = '.epub') or (Extension = '.pdf') or
        (Extension = '.djvu') or (Extension = '.djv') or (Extension = '.mobi') or
        (Extension = '.azw') or (Extension = '.azw3') or (Extension = '.rtf') or
        (Extension = '.txt') or (Extension = '.doc') or (Extension = '.docx') or
        (Extension = '.htm') or (Extension = '.html') or (Extension = '.xhtml') or
        (Extension = '.odt') or (Extension = '.chm') or (Extension = '.mht') or
        (Extension = '.mhtml') or (Extension = '.wri') or (Extension = '.ppt') or
        (Extension = '.pptx') or (Extension = '.md') or (Extension = '.fb3') or
        IsOfficeReaderFormat(Extension) then Candidates.Add(I);
    end;
    if Candidates.Count = 0 then raise Exception.Create('В архиве не найдены книги подходящего для чтения формата.');
    Entry := Candidates[0];
    if Candidates.Count > 1 then
    begin
      Entry := -1;
      TThread.Synchronize(nil,
      procedure
      begin
      if Application.Terminated or TReaderThreadAccess(RequestingThread).Terminated then Exit;
      Dialog := TForm.CreateNew(nil);
      try
        Dialog.Caption := 'Какую книгу открыть?'; Dialog.Position := poMainFormCenter;
        Dialog.ClientWidth := 620; Dialog.ClientHeight := 360;
        Dialog.Font.Name := 'Segoe UI'; Dialog.Font.Size := 9;
        Dialog.Constraints.MinWidth := 420; Dialog.Constraints.MinHeight := 240;
        LabelControl := TLabel.Create(Dialog); LabelControl.Parent := Dialog;
        LabelControl.SetBounds(12, 12, 590, 24); LabelControl.Caption := 'В архиве несколько книг. Выберите файл для чтения:';
        Names := TListBox.Create(Dialog); Names.Parent := Dialog;
        Names.SetBounds(12, 40, 596, 266); Names.Anchors := [akLeft, akTop, akRight, akBottom];
        for var CandidateIndex in Candidates do Names.Items.Add(Archive.FileNames[CandidateIndex]); Names.ItemIndex := 0;
        OpenButton := TButton.Create(Dialog); OpenButton.Parent := Dialog;
        OpenButton.SetBounds(380, 318, 110, 30); OpenButton.Anchors := [akRight, akBottom];
        OpenButton.Caption := 'Открыть'; OpenButton.Default := True; OpenButton.ModalResult := mrOk;
        CancelButton := TButton.Create(Dialog); CancelButton.Parent := Dialog;
        CancelButton.SetBounds(498, 318, 110, 30); CancelButton.Anchors := [akRight, akBottom];
        CancelButton.Caption := 'Отмена'; CancelButton.Cancel := True; CancelButton.ModalResult := mrCancel;
        Dialog.ScaleForPPI(Screen.PixelsPerInch);
        if Dialog.ShowModal <> mrOk then Exit;
        if Names.ItemIndex < 0 then Exit;
        Entry := Candidates[Names.ItemIndex];
      finally Dialog.Free; end;
      end);
      if Entry < 0 then Exit;
    end;
    Member := Archive.FileNames[Entry]; Extension := LowerCase(ExtractFileExt(Member));
    Folder:=BookCachePath;
    if (Extension = FB2_EXTENSION) and ConvertImages then
      Folder := TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER);
    ForceDirectories(Folder);
    Result := TPath.Combine(Folder, 'homelib-archive-' + Copy(THashSHA2.GetHashString(
      LowerCase(TPath.GetFullPath(Source)) + #1 + Member), 1, 32) + Extension);
    Stamp := SourceStamp(Book, Source, ConvertImages) + '|member:' + Member;
    Result:=ExistingBookCacheFile(Result);
    StampFile := Result + '.source';
    if FileExists(Result) and FileExists(StampFile) then
      try if TFile.ReadAllText(StampFile, TEncoding.UTF8) = Stamp then
      begin RegisterBookCacheFile(Result,Book.GetBookFileName);
        if Assigned(OnStage) then OnStage('Открытие книги из кэша…'); Exit; end;
      except end;
    if Assigned(OnStage) then OnStage('Распаковка книги из архива…');
    Writer:=TBookCacheWrite.Create(Book.GetBookFileName);
    Converted:=nil;
    try
      Temporary:=Writer.TemporaryName(Result);
      Extracted := TFileStream.Create(Temporary, fmCreate);
      try
        Archive.ExtractToStream(Entry, Extracted); Extracted.Position := 0;
        if (Extension = FB2_EXTENSION) and ConvertImages then
          Converted := NormalizeEmbeddedWebPFb2(Extracted);
        if Assigned(Converted) then
        begin Extracted.Size := 0; Extracted.Position := 0; Converted.Position := 0; Extracted.CopyFrom(Converted, 0); end;
      finally Extracted.Free; end;
      // A missing/old stamp is a miss. Publish the bytes before marking them current.
      StampFile:=Writer.TemporaryName(Result+'.source');
      TFile.WriteAllText(StampFile,Stamp,TEncoding.UTF8);
      Writer.Publish(Temporary,Result,StampFile);
    finally Converted.Free; Writer.Free; end;
  finally Candidates.Free; Archive.Free; end;
end;

function PrepareReaderFileCore(const Book: TBookRecord; const PreserveImages: Boolean; const OnStage: TProc<string>; OpenArchive: Boolean): string;
var Source, Folder, Stamp, StampFile, Temporary, TemporaryStamp: string;
  Format: TBookFormat; Stream, Converted: TStream; Target: TFileStream; ConvertImages: Boolean;
  Corrected: TBookRecord; Writer: TBookCacheWrite;
begin
  Source := Book.GetBookFileName;
  Format := Book.GetBookFormat;
  if not FileExists(Source) then
    raise EFileNotFoundException.Create('Не найден файл или архив коллекции: '+Source+#13#10+
      'Книга: '+Book.FileName+Book.FileExt+#13#10+'Проверьте папку книг и наличие архива, указанного в INPX.');
  ConvertImages := Settings.ConvertWebPToPNG and not PreserveImages;
  Corrected:=ResolveArchivedBook(Book);
  if (Corrected.FileName<>Book.FileName) or (Corrected.FileExt<>Book.FileExt) then
    Exit(PrepareReaderFileCore(Corrected,PreserveImages,OnStage,OpenArchive));
  if OpenArchive and not IsReaderArchive(Book.FileName+Book.FileExt) then Exit(Source);
  if not OpenArchive and (Format in [bfRaw,bfFbd]) and IsReaderContainer(Source) then Exit(PrepareLooseArchive(Book, Source, ConvertImages,OnStage));
  if not (Format in [bfFb2Archive, bfFbd, bfRawArchive]) and
    not ((Format = bfFb2) and ConvertImages) then Exit(Source);

  Folder:=BookCachePath;
  if (Format in [bfFb2, bfFb2Archive]) and ConvertImages then
    Folder := TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER);
  ForceDirectories(Folder);
  Result := TPath.Combine(Folder, ReaderCopyName(Book));
  Result:=ExistingBookCacheFile(Result);
  StampFile := Result + '.source';
  Stamp := SourceStamp(Book, Source, ConvertImages);
  if FileExists(Result) and FileExists(StampFile) then
    try
      if TFile.ReadAllText(StampFile, TEncoding.UTF8) = Stamp then
      begin
        RegisterBookCacheFile(Result,Source);
        if Assigned(OnStage) then OnStage('Открытие книги из кэша…');
        if not OpenArchive and IsReaderContainer(Result) then Result := PrepareLooseArchive(Book,Result,ConvertImages,OnStage);
        Exit;
      end;
    except
      // An incomplete stamp is a cache miss, never a reason to use stale bytes.
    end;

  if Assigned(OnStage) then
    if Format in [bfFb2Archive,bfRawArchive,bfFbd] then OnStage('Распаковка книги из архива…')
    else OnStage('Подготовка книги для чтения…');
  Stream := nil;
  Writer:=TBookCacheWrite.Create(Source);
  try
    Temporary:=Writer.TemporaryName(Result); TemporaryStamp:=Writer.TemporaryName(StampFile);
    if (Format in [bfFb2Archive,bfRawArchive]) and not IsSevenZipArchive(Source) then
    begin
      // Share original bytes with the gallery and metadata reader. Conversion
      // belongs only to the external-reader copy, never the original cache.
      Stream := OpenRawBookSource(Book,Writer);
      if (Format=bfFb2Archive) and ConvertImages then
      begin
        if Assigned(OnStage) then OnStage('Подготовка изображений для читалки…');
        Converted := NormalizeEmbeddedWebPFb2(Stream);
        if Assigned(Converted) then begin Stream.Free; Stream := Converted; end;
      end;
      Stream.Position := 0;
    end
    else Stream := Book.GetBookStream(PreserveImages);
    // Ordinary FB2 keeps its original path and external reader history.
    if (Format = bfFb2) and (Stream is TFileStream) then Exit(Source);
    if not Assigned(Stream) then raise Exception.Create('Не удалось подготовить книгу для чтения.');
    Target := TFileStream.Create(Temporary, fmCreate);
    try Target.CopyFrom(Stream, 0); finally Target.Free; end;
    TFile.WriteAllText(TemporaryStamp, Stamp, TEncoding.UTF8);
    Writer.Publish(Temporary,Result,TemporaryStamp);
  finally
    Stream.Free;
    Writer.Free;
  end;
  if not OpenArchive and IsReaderContainer(Result) then Result := PrepareLooseArchive(Book,Result,ConvertImages,OnStage);
end;

function PrepareReaderFile(const Book: TBookRecord; const PreserveImages: Boolean;
  const OnStage: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean): string;
begin
  Result := PrepareReaderFileCore(Book,PreserveImages,OnStage,OpenArchive);
  if (Result <> '') and not OpenArchive then
  begin
    Result:=PrepareDetectedReaderFile(Result,Book.GetBookFileName);
    // The archive's extension can differ from its selected readable member.
    // Preserve a custom Kindle reader, but prepare KF8 for Sumatra as well.
    if not ConvertKindle then
      with Settings.Readers do
        if Assigned(Find(ExtractFileExt(Result))) then
          ConvertKindle := SameText(ExtractFileName(Find(ExtractFileExt(Result)).Path),'SumatraPDF.exe');
    if ConvertKindle then Result := PrepareKindleReflow(Result,Book.GetBookFileName,OnStage);
    if ConvertOffice then Result := PrepareOfficeReaderFile(Result,Book.GetBookFileName,OnStage);
  end;
end;

type
  TReaderPreparation = class(TComponent)
  private
    FWorker: TThread;
    FTimer: TTimer;
    FStatus: TMHLOperationStatus;
    FLock: TCriticalSection;
    FStage, FResult, FError: string;
    FReady: TProc<string>;
    procedure Tick(Sender: TObject);
  public
    constructor CreateTask(Owner: TComponent; const Book: TBookRecord;
      PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean);
    destructor Destroy; override;
  end;

constructor TReaderPreparation.CreateTask(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean);
var Snapshot: TBookRecord;
begin
  inherited Create(Owner);
  Snapshot := Book; FReady := OnReady; FLock := TCriticalSection.Create;
  FStage := 'Подготовка книги для чтения…'; FStatus := TMHLOperationStatus.Create(FStage);
  FWorker := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        FResult := PrepareReaderFile(Snapshot,PreserveImages,
          procedure(Stage: string)
          begin
            if FWorker.CheckTerminated then Abort;
            FLock.Enter;
            try FStage := Stage; finally FLock.Leave; end;
          end,OpenArchive,ConvertKindle,ConvertOffice);
      except
        on E: EAbort do FResult := '';
        on E: Exception do FError := E.Message;
      end;
    end);
  FWorker.FreeOnTerminate := False;
  FTimer := TTimer.Create(Self); FTimer.Interval := 50; FTimer.OnTimer := Tick;
  FWorker.Start;
end;

destructor TReaderPreparation.Destroy;
begin
  FReady := nil; FTimer.Free; FTimer := nil;
  if Assigned(FWorker) then
  begin
    FWorker.Terminate;
    // Finish outstanding archive I/O before owner settings and cache unload.
    // Synchronize is needed only for the optional archive member chooser.
    FWorker.WaitFor; FWorker.Free;
  end;
  FStatus.Free; FLock.Free;
  inherited;
end;

procedure TReaderPreparation.Tick(Sender: TObject);
var Stage, ErrorText: string; Ready: TProc<string>; WorkFile: string;
begin
  FLock.Enter;
  try Stage := FStage; finally FLock.Leave; end;
  FStatus.SetStage(Stage);
  if WaitForSingleObject(FWorker.Handle,0) <> WAIT_OBJECT_0 then Exit;
  FTimer.Enabled := False;
  Ready := FReady; FReady := nil; WorkFile := FResult; ErrorText := FError;
  // The callback can run a modal reader or destroy its owner. Release the
  // worker and hint first so neither can survive reading or be freed twice.
  Free;
  if ErrorText <> '' then raise Exception.Create(ErrorText);
  if (WorkFile <> '') and Assigned(Ready) and not Application.Terminated then Ready(WorkFile);
end;

procedure CancelReaderPreparations(Owner: TComponent);
var I: Integer;
begin
  for I := Owner.ComponentCount-1 downto 0 do
    if Owner.Components[I] is TReaderPreparation then Owner.Components[I].Free;
end;

procedure PrepareReaderFileInBackground(Owner: TComponent; const Book: TBookRecord;
  PreserveImages: Boolean; const OnReady: TProc<string>; OpenArchive, ConvertKindle, ConvertOffice: Boolean);
var Component: TComponent;
begin
  // A double click while preparing must not start duplicate decompression.
  for Component in Owner do if Component is TReaderPreparation then Exit;
  TReaderPreparation.CreateTask(Owner,Book,PreserveImages,OnReady,OpenArchive,ConvertKindle,ConvertOffice);
end;

end.
