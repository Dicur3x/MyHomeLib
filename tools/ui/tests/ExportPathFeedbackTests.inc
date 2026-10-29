procedure TestExportPathFeedback;
const XML='<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
  '<description><title-info><book-title>Книга Ё</book-title><lang>ru</lang></title-info></description>'+
  '<body><section><p>Исходный текст для точного сохранения.</p></section></body></FictionBook>';
var Root, Source, Hash, Stage, Target, FolderMask: string; Book: TBookRecord;
  Capture: TBBEExportCapture; Results: TBookExportResults; Archive: TZipFile;
  Bytes: TBytes; Raised: Boolean; BeforePosition: Int64;
  function Run(const Books: TArray<TBookRecord>; const Folder: string; Mode: TExportMode;
    Overwrite: Boolean = False): TBookExportResults;
  var Worker: TExportToDeviceThread;
  begin
    Capture.Messages.Clear; Capture.Warnings.Clear;
    Worker:=TExportToDeviceThread.Create;
    try
      Worker.StandaloneBooks:=Books; Worker.DeviceDir:=Root;
      Worker.FolderTemplate:=Folder; Worker.FileNameTemplate:='%t';
      Worker.KeepSourceFormat:=True; Worker.ImageQuality:='original'; Worker.ExportMode:=Mode;
      if Overwrite then Worker.NameCollision:=bncReplace else Worker.NameCollision:=bncKeepBoth;
      Worker.OnShowMessage:=Capture.Message; Worker.OnTeletype:=Capture.Warning;
      Worker.Start; Worker.WaitFor;
      Require(not Assigned(Worker.FatalException),'Export path worker raised a fatal exception');
      Result:=Worker.Results;
    finally Worker.Free; end;
  end;
begin
  Root:=Settings.AppPath+'export-path-feedback'; ForceDirectories(Root);
  Source:=TPath.Combine(Root,'source.fb2'); TFile.WriteAllText(Source,XML,TEncoding.UTF8);
  Hash:=UpdateSHA256(Source); Book:=FileBook(Source); Capture:=TBBEExportCapture.Create;
  try
    Book.Title:='Ученики Ворона — '+string.Create('я',240);
    FolderMask:='Автор Ё\Серия '+string.Create('ф',90)+'\Выпуск';
    Results:=Run([Book],FolderMask,emFB2Zip);
    Require((Length(Results)=1) and (Results[0].State=besSucceeded),
      'Long Unicode ZIP output failed: '+Results[0].ErrorText+Capture.Messages.Text);
    Target:=Results[0].OutputFile;
    Require((Length(Target)>260) and BookOutputExists(Target),'Long path output was truncated or not published');
    Require(Target.Contains(FolderMask),'The complete target directory path was truncated');
    Archive:=TZipFile.Create;
    try
      Archive.Open(BookOutputPath(Target),zmRead); Require(Archive.FileCount=1,'ZIP contains extra temporary files');
      Archive.Read(Archive.FileNames[0],Bytes); var FirstSourceBytes:=TFile.ReadAllBytes(Source);
      Require((Length(Bytes)=Length(FirstSourceBytes)) and CompareMem(@Bytes[0],@FirstSourceBytes[0],Length(Bytes)),
        'ZIP changed original FB2 bytes');
    finally Archive.Free; end;
    var FirstTarget:=Target;
    Results:=Run([Book],FolderMask,emFB2Zip);
    Require((Results[0].State=besSucceeded) and (Results[0].OutputFile<>FirstTarget) and BookOutputExists(FirstTarget),
      'Default collision handling replaced an existing copy');
    TFile.WriteAllText(BookOutputPath(FirstTarget),'old saved copy',TEncoding.UTF8);
    Results:=Run([Book],FolderMask,emFB2Zip,True);
    Require((Results[0].State=besSucceeded) and (Results[0].OutputFile=FirstTarget),
      'Explicit overwrite created a numbered sibling instead of replacing the saved copy');
    Archive:=TZipFile.Create;
    try Archive.Open(BookOutputPath(FirstTarget),zmRead); Archive.Read(Archive.FileNames[0],Bytes);
      var ReplacedSourceBytes:=TFile.ReadAllBytes(Source);
      Require((Length(Bytes)=Length(ReplacedSourceBytes)) and CompareMem(@Bytes[0],@ReplacedSourceBytes[0],Length(Bytes)),
        'Replaced saved ZIP changed the source bytes');
    finally Archive.Free; end;
    FolderMask:=string.Create('а',90)+'\'+string.Create('б',90)+'\'+string.Create('в',90);
    Book.Title:='Короткое название'; Results:=Run([Book],FolderMask,emFB2);
    Require((Results[0].State=besSucceeded) and (Length(ExtractFilePath(Results[0].OutputFile))>260),
      'Deep target directory failed: '+Results[0].ErrorText);
    Require(UpdateSHA256(BookOutputPath(Results[0].OutputFile))=Hash,'Deep directory copy changed book bytes');
    Target:=TPath.Combine(Root,'direct\'+string.Create('д',200)+'.fb2');
    ConvertBasicBook(Settings.AppPath,Settings.TempPath,Source,'.fb2',Target,nil,nil);
    Require(UpdateSHA256(BookOutputPath(Target))=Hash,'Direct same-format conversion failed on a long target');
    var LongName:=BookOutputName(string.Create('а',227)+#$D83D#$DE00+string.Create('б',40),'.fb2.zip',41);
    Require((Length(LongName)+Length('.fb2.zip')+16<=255) and LongName.EndsWith('-41') and
      (Pos(#$D83D,LongName)=0),'Generated filename cuts a Unicode surrogate or exceeds component bound');
    Writeln('PASS export long Unicode filenames complete deep directories native ZIP exact bytes collisions and same-format copies'); Flush(Output);

    Target:=TPath.Combine(Root,'race\protected.fb2'); Stage:=CreateBookOutputStage(Target);
    try
      TFile.WriteAllText(Stage,'new copy',TEncoding.UTF8); TFile.WriteAllText(Target,'existing copy',TEncoding.UTF8);
      Raised:=False; try PublishBookOutput(Stage,Target); except on E: EOSError do Raised:=True; end;
      Require(Raised and (TFile.ReadAllText(Target,TEncoding.UTF8)='existing copy'),
        'Atomic publication replaced a file created after the collision check');
    finally DeleteBookOutputStage(Stage); end;
    Require(not FileExists(Stage),'Failed publication retained its owned stage');
    var Input:=TMemoryStream.Create;
    try
      Bytes:=TEncoding.UTF8.GetBytes(XML+string.Create(' ',1024*1024)); Input.WriteBuffer(Bytes[0],Length(Bytes));
      Input.Position:=7; BeforePosition:=Input.Position;
      Target:=TPath.Combine(Root,'cancelled\book.fb2'); var Checks:=0; Raised:=False;
      try
        ConvertBasicBook(Settings.AppPath,Settings.TempPath,Source,'.fb2',Target,Input,nil,
          function: Boolean begin Inc(Checks); Result:=Checks>=4; end);
      except on E: EAbort do Raised:=True; end;
      Require(Raised and not BookOutputExists(Target) and (Input.Position=BeforePosition),
        'Cancelled publication wrote output or changed caller stream position');
    finally Input.Free; end;
    Writeln('PASS atomic output race and cancellation preserve existing files sources and caller stream position'); Flush(Output);

    var AliasName:=TPath.Combine(Root,'source-alias.fb2');
    Require(CreateHardLink(PChar(AliasName),PChar(Source),nil),'Cannot create owned source identity alias');
    Require(SameBookOutputFile(Source,AliasName),'Source hard-link alias was not recognized');
    Stage:=CreateBookOutputStage(AliasName);
    try
      TFile.WriteAllText(Stage,'must not replace source',TEncoding.UTF8); Raised:=False;
      try PublishBookOutput(Stage,AliasName,True,Source); except on E: EInOutError do Raised:=True; end;
      Require(Raised and (UpdateSHA256(Source)=Hash) and (UpdateSHA256(AliasName)=Hash),
        'Explicit overwrite replaced the source through an alias');
    finally DeleteBookOutputStage(Stage); end;
    Book.Title:='source'; Results:=Run([Book],'',emFB2,True);
    Require((Results[0].State=besFailed) and Results[0].ErrorText.Contains('исходной книгой') and
      (UpdateSHA256(Source)=Hash),'Overwrite replaced a selected source book');
    Target:=TPath.Combine(Root,'cancelled-replacement.fb2');
    TFile.WriteAllText(Target,'keep existing copy',TEncoding.UTF8); var ReplacementChecks:=0; Raised:=False;
    try
      ConvertBasicBook(Settings.AppPath,Settings.TempPath,Source,'.fb2',Target,nil,nil,
        function: Boolean begin Inc(ReplacementChecks); Result:=ReplacementChecks>=4; end,
        '','','',False,nil,'original',nil,True);
    except on E: EAbort do Raised:=True; end;
    Require(Raised and (TFile.ReadAllText(Target,TEncoding.UTF8)='keep existing copy'),
      'Cancelled replacement changed the previous saved copy');
    Writeln('PASS explicit overwrite replaces only saved copies and rejects original identities including hard links'); Flush(Output);

    var ShellFolder:=TPath.Combine(Root,'shell'); ForceDirectories(ShellFolder);
    var HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED); var UninitCOM:=Succeeded(HR);
    Require(UninitCOM or (HR=RPC_E_CHANGED_MODE),'Cannot initialize Shell copy test');
    try
      var Item:IShellItem;
      Require(Succeeded(SHCreateItemFromParsingName(PChar(ShellFolder),nil,IShellItem,Item)),
        'Cannot obtain owned Shell folder');
      Require(ShellCopyFile(Source,Item,'copy.fb2',False,Source),'Initial Shell copy failed');
      Require(ShellCopyFile(Source,Item,'copy.fb2',False,Source),'Shell collision copy failed');
      Require(Length(TDirectory.GetFiles(ShellFolder))=2,'Default Shell copy did not retain both copies');
      TFile.WriteAllText(TPath.Combine(ShellFolder,'copy.fb2'),'old shell copy',TEncoding.UTF8);
      Require(ShellCopyFile(Source,Item,'copy.fb2',True,Source),'Explicit Shell replacement failed');
      Require((Length(TDirectory.GetFiles(ShellFolder))=2) and
        (UpdateSHA256(TPath.Combine(ShellFolder,'copy.fb2'))=Hash),'Shell replacement made another sibling or wrong content');
      Item:=nil;
    finally if UninitCOM then CoUninitialize; end;
    Writeln('PASS Shell copy keeps numbered duplicates by default and replaces saved copies only when requested'); Flush(Output);

    TFile.WriteAllText(TPath.Combine(Root,'blocker'),'keep this existing file',TEncoding.UTF8);
    var FailedBooks:TArray<TBookRecord>:=TArray<TBookRecord>.Create(Book,Book,Book);
    for var I:=0 to High(FailedBooks) do FailedBooks[I].Title:='Ошибка книги '+IntToStr(I);
    Results:=Run(FailedBooks,'blocker\child',emFB2Zip);
    Require((Length(Results)=3) and (Capture.Messages.Count=1),'Batch failure displayed repeated continuation dialogs');
    for var Item in Results do Require((Item.State=besFailed) and (Item.ErrorText<>''),'Batch error lost a book result');
    var Log:=TFile.ReadAllText(Settings.SystemFileName[sfExportErrorLog],TEncoding.UTF8);
    for var Item in FailedBooks do Require(Log.Contains(Item.Title),'Batch report omits failed book '+Item.Title);
    Require((TFile.ReadAllText(TPath.Combine(Root,'blocker'),TEncoding.UTF8)='keep this existing file') and
      (UpdateSHA256(Source)=Hash),'Failed export changed a source or pre-existing destination file');
    Writeln('PASS batch export failures retain every book reason use one final summary and preserve existing paths'); Flush(Output);
    TFile.WriteAllText(Settings.AppPath+'estimate-source.fb2',XML,TEncoding.UTF8);
    TFile.WriteAllText(Settings.AppPath+'estimate-source.pdf','%PDF-1.4 copy only',TEncoding.ASCII);
    TestRestoredSaveOptions;
    TestBookSaveContinuation;
    TestBookNameCollisions;
  finally Capture.Free; end;
end;
