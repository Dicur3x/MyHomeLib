// Real archived-book operations followed by main-form destruction.
var
  ExportCacheExitRoot: string;
  ExportCacheSourceFiles, ExportCacheSourceHashes: TArray<string>;

procedure CheckExportCacheSources;
begin
  for var I:=0 to High(ExportCacheSourceFiles) do
    Require(FileExists(ExportCacheSourceFiles[I]) and
      SameText(UpdateSHA256(ExportCacheSourceFiles[I]),ExportCacheSourceHashes[I]),
      'Cache lifecycle changed an original fixture: '+ExportCacheSourceFiles[I]);
end;

function ExportCacheManagedFiles: Integer;
begin
  Result:=0;
  if DirectoryExists(ExportCacheExitRoot) then
    for var Name in TDirectory.GetFiles(ExportCacheExitRoot,'homelib-*',TSearchOption.soAllDirectories) do
      Inc(Result);
end;

procedure CheckExportCacheLifecycleAfterClose;
begin
  CheckExportCacheSources;
  Require(ExportCacheManagedFiles=0,'Main-form exit left managed cache payloads or sidecars');
  Writeln('PASS real main-form exit clears archived-book estimate and export caches while preserving every original');
end;

procedure TestExportCacheLifecycle;
var
  Root, WorkRoot, GoodXML, BadXML: string;
  Books: TArray<TBookRecord>;
  Plan: TBookSaveChoice;
  Capture: TBBEExportCapture;
  function OperationDirectories(const Prefix: string): TArray<string>;
  begin
    Result:=nil;
    if DirectoryExists(WorkRoot) then Result:=TDirectory.GetDirectories(WorkRoot,Prefix+'*');
  end;
  procedure CheckOperationCleanup;
  begin
    for var Prefix in ['homelib-save-estimate-','homelib-convert-','homelib-export-'] do
      Require(Length(OperationDirectories(Prefix))=0,'Operation left temporary work: '+Prefix);
    for var Name in TDirectory.GetFiles(Root,'*',TSearchOption.soAllDirectories) do
      Require(not ExtractFileName(Name).StartsWith('.homelib-book-'),
        'Export left an atomic output stage: '+Name);
    CheckExportCacheSources;
  end;
  function Estimate(const Book: TBookRecord; CancelInFlight: Boolean): TBookSaveEstimateItems;
  var
    Worker: TBookSendEstimateThread;
    Revision: Integer;
    Complete, Cancelled: Boolean;
    Status: string;
    Deadline: UInt64;
  begin
    Worker:=TBookSendEstimateThread.Create(TArray<TBookRecord>.Create(Book),Plan,Settings.AppPath,WorkRoot);
    try
      Revision:=-1; Complete:=False; Cancelled:=False; Deadline:=GetTickCount64+60000;
      Worker.Start;
      repeat
        Application.ProcessMessages;
        if CancelInFlight and not Cancelled and
          (Length(OperationDirectories('homelib-save-estimate-'))>0) then
        begin Worker.Terminate; Cancelled:=True; end;
        Worker.Poll(Revision,Result,Status,Complete);
        if GetTickCount64>Deadline then
        begin Worker.Terminate; raise Exception.Create('Cache lifecycle estimate timeout: '+Status); end;
        if not Complete then Sleep(1);
      until Complete;
      Require(not Assigned(Worker.FatalException),'Cache estimate raised a fatal exception');
      Require(not CancelInFlight or Cancelled,'Estimate cancellation was not exercised inside real work');
    finally Worker.Terminate; Worker.Free; end;
    CheckOperationCleanup;
  end;
  function ExportBook(const Book: TBookRecord; const Folder: string;
    CancelBeforeStart: Boolean): TBookExportResults;
  var Worker: TExportToDeviceThread;
  begin
    Capture.Messages.Clear; Capture.Warnings.Clear;
    Worker:=TExportToDeviceThread.Create;
    try
      Worker.StandaloneBooks:=TArray<TBookRecord>.Create(Book);
      Worker.DeviceDir:=TPath.Combine(Root,Folder); ForceDirectories(Worker.DeviceDir);
      Worker.FileNameTemplate:='%t'; Worker.FolderTemplate:='';
      Worker.KeepSourceFormat:=False; Worker.ImageQuality:='original'; Worker.ExportMode:=emEpub;
      Worker.NameCollision:=bncKeepBoth;
      Worker.OnShowMessage:=Capture.Message; Worker.OnTeletype:=Capture.Warning;
      if CancelBeforeStart then Worker.Cancel;
      Worker.Start; Worker.WaitFor;
      Require(not Assigned(Worker.FatalException),'Cache export raised a fatal exception');
      Result:=Worker.Results;
    finally Worker.Free; end;
    CheckOperationCleanup;
  end;
begin
  RequireIsolatedRegression;
  Root:=TPath.Combine(Settings.AppPath,'export-cache-fixtures'); ForceDirectories(Root);
  WorkRoot:=Settings.TempPath;
  ExportCacheExitRoot:=BookCachePath;
  Settings.ClearBookCacheOnExit:=True;
  ClearBookCache;
  GoodXML:='<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
    '<description><title-info><book-title>Кэш Ё</book-title><lang>ru</lang></title-info></description><body><section>';
  var Text:=TStringBuilder.Create;
  try
    Text.Append(GoodXML);
    for var I:=0 to 19999 do
      Text.Append('<p>Полный текст для проверки временных файлов, отмены и сохранности исходной книги. Абзац ').Append(I).Append('.</p>');
    Text.Append('</section></body></FictionBook>'); GoodXML:=Text.ToString;
  finally Text.Free; end;
  BadXML:='<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '+
    'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Ошибка</book-title><lang>ru</lang></title-info></description>'+
    '<body><section><p>Текст остаётся в исходной книге.</p><image l:href="#broken"/></section></body>'+
    '<binary id="broken" content-type="image/jpeg">%%%invalid-base64%%%</binary></FictionBook>';
  SetLength(Books,2); SetLength(ExportCacheSourceFiles,4); SetLength(ExportCacheSourceHashes,4);
  for var I:=0 to 1 do
  begin
    var Raw:=TPath.Combine(Root,'original-'+IntToStr(I)+'.fb2');
    if I=0 then TFile.WriteAllText(Raw,GoodXML,TEncoding.UTF8)
    else TFile.WriteAllText(Raw,BadXML,TEncoding.UTF8);
    var ZipName:=TPath.Combine(Root,'original-'+IntToStr(I)+'.zip');
    var Archive:=TZipFile.Create;
    try Archive.Open(ZipName,zmWrite); Archive.Add(Raw,'book.fb2'); Archive.Close;
    finally Archive.Free; end;
    ExportCacheSourceFiles[I*2]:=Raw; ExportCacheSourceFiles[I*2+1]:=ZipName;
    Books[I]:=Default(TBookRecord); Books[I].CollectionRoot:=Root;
    Books[I].Folder:=ExtractFileName(ZipName); Books[I].FileName:='book'; Books[I].FileExt:='.fb2';
    Books[I].BookProps:=[bpIsLocal]; Books[I].NodeType:=ntBookInfo;
    Books[I].Title:='Cache '+IntToStr(I); Books[I].Size:=TFile.GetSize(Raw);
    Require(SameFileName(Books[I].GetBookFileName,ZipName),'Archived cache fixture resolved another source');
  end;
  for var I:=0 to High(ExportCacheSourceFiles) do
    ExportCacheSourceHashes[I]:=UpdateSHA256(ExportCacheSourceFiles[I]);
  Plan:=Default(TBookSaveChoice); Plan.Mode:=emEpub;
  Capture:=TBBEExportCapture.Create;
  try
    var Items:=Estimate(Books[0],False);
    Require((Length(Items)=1) and Items[0].Completed and (Items[0].ErrorText='') and
      (Items[0].Options.OutputBytes[0,0]>0),'Archived source estimate failed');
    Require(ExportCacheManagedFiles>0,'Archived source did not exercise the persistent book cache');
    Writeln('PASS real archived-book estimate removes work immediately and retains reusable cached sources until exit');
    Items:=Estimate(Books[1],False);
    Require((Length(Items)=1) and (Items[0].ErrorText<>''),'Corrupt image did not exercise estimate failure cleanup');
    Writeln('PASS failed archived-book estimate removes all operation work and preserves original archives');
    Estimate(Books[0],True);
    Writeln('PASS in-flight estimate cancellation removes operation work and preserves original archives');
    var Results:=ExportBook(Books[0],'successful-export',False);
    Require((Length(Results)=1) and (Results[0].State=besSucceeded) and FileExists(Results[0].OutputFile),
      'Real archived-book EPUB export failed');
    Results:=ExportBook(Books[1],'failed-export',False);
    Require((Length(Results)=1) and (Results[0].State=besFailed) and (Results[0].ErrorText<>''),
      'Corrupt image did not exercise failed export cleanup');
    Results:=ExportBook(Books[0],'cancelled-export',True);
    Require(Length(TDirectory.GetFiles(TPath.Combine(Root,'cancelled-export'),'*',TSearchOption.soAllDirectories))=0,
      'Cancelled export published an output');
    Writeln('PASS successful failed and cancelled real exports remove operation work and preserve source files');
  finally Capture.Free; end;
end;
