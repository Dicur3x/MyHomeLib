unit unit_FileBooks;

interface

uses System.Classes, System.SysUtils, unit_Globals, unit_BookSendOptions,
  unit_BookExportResults;

function FileBook(const FileName: string): TBookRecord;
function SaveFileBook(const Book: TBookRecord; const Options: TBookSendOptions;
  out RequiredComponent: string): TBookExportResults; overload;
function SaveFileBooks(const Books: TArray<TBookRecord>; const Options: TBookSendOptions;
  out RequiredComponent: string): TBookExportResults; overload;

function SaveFileBooks(const Books: TArray<TBookRecord>; const Options: TBookSendOptions;
  out RequiredComponents: TArray<string>): TBookExportResults; overload;
function SaveFileBook(const Book: TBookRecord; const Options: TBookSendOptions;
  out RequiredComponents: TArray<string>): TBookExportResults; overload;

implementation

uses System.IOUtils, System.Hash, System.Win.ComObj, Winapi.ActiveX, ShlObj, Vcl.Forms,
  unit_ExportToDeviceThread, frm_ExportToDeviceProgressForm;

function FileBook(const FileName: string): TBookRecord;
var FullName: string; Probe: TFileStream;
begin
  FullName:=TPath.GetFullPath(FileName);
  // Probe the selected file itself. There is no collection lookup, database
  // registration or temporary catalogue import in the standalone path.
  Probe:=TFileStream.Create(FullName,fmOpenRead or fmShareDenyNone);
  try
    Result:=Default(TBookRecord);
    Result.Size:=Probe.Size;
  finally Probe.Free; end;
  Result.BookKey:=CreateBookKey(1,0); Result.NodeType:=ntBookInfo;
  Result.CollectionRoot:=ExtractFilePath(FullName);
  Result.FileExt:=ExtractFileExt(FullName);
  Result.FileName:=ChangeFileExt(ExtractFileName(FullName),'');
  Result.Title:=Result.FileName;
  Result.LibID:='local-file:'+THashSHA2.GetHashString(FullName);
  Include(Result.BookProps,bpIsLocal);
end;

function SaveFileBook(const Book: TBookRecord; const Options: TBookSendOptions;
  out RequiredComponent: string): TBookExportResults;
begin Result:=SaveFileBooks([Book],Options,RequiredComponent); end;

function SaveFileBooks(const Books: TArray<TBookRecord>; const Options: TBookSendOptions;
  out RequiredComponent: string): TBookExportResults;
var IDs:TArray<string>;
begin
  Result:=SaveFileBooks(Books,Options,IDs); RequiredComponent:='';
  if Length(IDs)>0 then RequiredComponent:=IDs[0];
end;

function SaveFileBook(const Book: TBookRecord; const Options: TBookSendOptions;
  out RequiredComponents: TArray<string>): TBookExportResults;
begin Result:=SaveFileBooks([Book],Options,RequiredComponents); end;

function SaveFileBooks(const Books: TArray<TBookRecord>; const Options: TBookSendOptions;
  out RequiredComponents: TArray<string>): TBookExportResults;
var Worker: TExportToDeviceThread; Progress: TExportToDeviceProgressForm;
  Marshalled: IStream;
begin
  RequiredComponents:=nil;
  Worker:=TExportToDeviceThread.Create;
  try
    Worker.StandaloneBooks:=Books;
    Worker.DeviceDir:=Options.Folder; Worker.ExportMode:=Options.Mode;
    Worker.ExplicitFormat:=Options.ExplicitFormat; Worker.ExtractOnly:=False;
    Worker.KeepSourceFormat:=Options.KeepSourceFormat;
    Worker.KeepFB2EPUB:=Options.KeepFB2EPUB; Worker.ZipEachBook:=Options.ZipEachBook;
    if Options.FileNameTemplate<>'' then Worker.FileNameTemplate:=Options.FileNameTemplate;
    Worker.FolderTemplate:=Options.FolderTemplate;
    Worker.ImageQuality:=Options.ImageQuality; Worker.ShowImageQualityChoice:=True;
    Worker.UseMTP:=Options.UseMTP;
    if Options.UseMTP and Assigned(Options.ShellItem) then
    begin
      OleCheck(CoMarshalInterThreadInterfaceInStream(IShellItem,Options.ShellItem,Marshalled));
      Worker.MarshalStream:=Marshalled;
    end;
    Progress:=TExportToDeviceProgressForm.Create(Application);
    try
      Progress.Caption:='Сохранить книгу как'; Progress.WorkerThread:=Worker;
      Progress.ShowModal;
    finally Progress.Free; end;
    RequiredComponents:=Copy(Worker.RequiredComponents);
    if (Length(RequiredComponents)=0) and (Worker.RequiredComponent<>'') then
      RequiredComponents:=TArray<string>.Create(Worker.RequiredComponent);
    Result:=Worker.Results;
    if Assigned(Worker.FatalException) then
      raise Exception.Create('Сохранение остановлено: '+Exception(Worker.FatalException).Message);
  finally Worker.Free; end;
end;

end.
