unit unit_FileBooks;

interface

uses System.Classes, System.SysUtils, unit_Globals, unit_BookSendOptions,
  unit_BookExportResults;

function FileBook(const FileName: string): TBookRecord;
function SaveFileBook(const Book: TBookRecord; const Options: TBookSendOptions;
  out RequiredComponent: string): TBookExportResults;

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
var Worker: TExportToDeviceThread; Progress: TExportToDeviceProgressForm;
  Marshalled: IStream;
begin
  RequiredComponent:='';
  Worker:=TExportToDeviceThread.Create;
  try
    Worker.StandaloneBooks:=[Book];
    Worker.DeviceDir:=Options.Folder; Worker.ExportMode:=Options.Mode;
    Worker.ExplicitFormat:=Options.ExplicitFormat; Worker.ExtractOnly:=False;
    Worker.KeepSourceFormat:=Options.KeepSourceFormat;
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
    RequiredComponent:=Worker.RequiredComponent;
    Result:=Worker.Results;
    if Assigned(Worker.FatalException) then
      raise Exception.Create('Сохранение остановлено: '+Exception(Worker.FatalException).Message);
  finally Worker.Free; end;
end;

end.
