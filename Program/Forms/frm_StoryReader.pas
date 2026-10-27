unit frm_StoryReader;

interface

uses System.SysUtils, System.Classes, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls,
  Vcl.ExtCtrls, frm_BuiltinReader;

type
  TStoryWorker = class(TThread)
  private FAppPath, FSource, FWork, FContainer, FMember, FResourceRoot: string;
  protected procedure Execute; override;
  public Error: string;
    constructor Create(const AppPath, SourceFile, Work, Container, Member, ResourceRoot: string);
  end;

  TStoryExporter = class(TThread)
  private FAppPath, FSource, FTarget, FTitle, FTemp: string;
  protected procedure Execute; override;
  public Error: string;
    constructor Create(const AppPath, SourceFile, TargetFile, Title, Temp: string);
  end;

  TfrmStoryReader = class(TForm)
  private
    FWork, FProgressFile, FSourceHash, FAppPath, FSource, FBookTitle: string;
    FIdentity, FSettingsFile, FPDFLibrary, FExportTarget, FViewHash: string;
    FWorker: TStoryWorker;
    FExporter: TStoryExporter;
    FReader: TfrmBuiltinReader;
    FTimer: TTimer;
    FStatus, FHelp: TLabel;
    FImages: TCheckBox;
    FOptions: TListBox;
    FChoose, FSave, FReset: TButton;
    FInput: TArray<Boolean>;
    FSequence, FReceived, FVisited: Integer;
    FWaiting, FClosing, FFailed, FExportComplete: Boolean;
    FStarted: UInt64;
    procedure Tick(Sender: TObject);
    procedure ChooseClick(Sender: TObject);
    procedure OptionChanged(Sender: TObject);
    procedure ImagesClick(Sender: TObject);
    procedure OptionKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SaveClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure ExportFinished(Sender: TObject);
    procedure PublishCommand(const Command: string; Action: Integer = 0; const Text: string = ''; HasInput: Boolean = False);
    procedure ReleaseScene;
    procedure ShowFailure(const MessageText: string);
    procedure SaveProgress;
    function GetReady: Boolean;
    function GetBookText: string;
    function GetPictureCount: Integer;
  public
    constructor CreateStory(AOwner: TComponent; const AppPath, SourceFile, BookTitle,
      Identity, SettingsFile, PDFLibrary: string; const ResourceContainer: string = '';
      const ResourceMember: string = ''; const ResourceRoot: string = '');
    destructor Destroy; override;
    procedure Choose(Index: Integer; const Text: string = '');
    procedure SaveRoute(const TargetFile: string);
    property Ready: Boolean read GetReady;
    property Failed: Boolean read FFailed;
    property BookText: string read GetBookText;
    property PictureCount: Integer read GetPictureCount;
    property Choices: TListBox read FOptions;
    property VisitedCount: Integer read FVisited;
    property StatusText: TLabel read FStatus;
    property WorkDirectory: string read FWork;
    property ProgressFile: string read FProgressFile;
    property Exporting: TStoryExporter read FExporter;
  end;

procedure OpenInteractiveStory(Owner: TComponent; const AppPath, SourceFile, BookTitle,
  Identity, SettingsFile, PDFLibrary: string; const ResourceContainer: string = '';
  const ResourceMember: string = ''; const ResourceRoot: string = '');

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, System.Hash, System.Math, System.Generics.Collections,
  Vcl.Dialogs, unit_MHLExternalTools, unit_MHLTheme, unit_BookConversion,
  unit_ExportImageQuality, unit_Diagnostics;

constructor TStoryWorker.Create(const AppPath, SourceFile, Work, Container, Member, ResourceRoot: string);
begin
  inherited Create(True); FreeOnTerminate:=False;
  FAppPath:=AppPath; FSource:=SourceFile; FWork:=Work;
  FContainer:=Container; FMember:=Member; FResourceRoot:=ResourceRoot;
end;

procedure TStoryWorker.Execute;
var Log: TStringStream; Arguments: TList<string>;
begin
  Log:=TStringStream.Create('',TEncoding.UTF8);
  Arguments:=TList<string>.Create;
  try
    try
      Arguments.AddRange(TArray<string>.Create('-I','-B','-X','utf8',TPath.Combine(FAppPath,'tools\bookconvert\sm_reader.py'),
        '--source',FSource,'--workspace',FWork));
      if FContainer<>'' then Arguments.AddRange(TArray<string>.Create('--container',FContainer,'--member',FMember));
      if FResourceRoot<>'' then Arguments.AddRange(TArray<string>.Create('--resource-root',FResourceRoot));
      RunExternalToolToStream(TPath.Combine(FAppPath,'tools\kindle\python\python.exe'),
        Arguments.ToArray,Log,
        function: Boolean begin Result:=Terminated; end,0,True,384*1024*1024);
    except on E: Exception do
      if not Terminated then
      begin Error:=Copy(Log.DataString.Trim,1,2048); if Error='' then Error:=E.Message; end;
    end;
  finally Arguments.Free; Log.Free; end;
end;

constructor TStoryExporter.Create(const AppPath, SourceFile, TargetFile, Title, Temp: string);
begin
  inherited Create(True); FreeOnTerminate:=False;
  FAppPath:=AppPath; FSource:=SourceFile; FTarget:=TargetFile; FTitle:=Title; FTemp:=Temp;
end;

procedure TStoryExporter.Execute;
begin
  try
    ConvertBasicBook(FAppPath,FTemp,FSource,'.epub',FTarget,nil,nil,
      function: Boolean begin Result:=Terminated; end,FTitle,'','',False,nil,'ask',
      function(const Options: TBookImageQualityOptions): string
      var Choice: string; ApplyToAll: Boolean;
      begin
        Choice:='cancel';
        Synchronize(procedure
          begin if not Terminated then Choice:=ChooseExportImageQuality(FTitle,Options,False,ApplyToAll); end);
        Result:=Choice;
      end);
  except on E: Exception do if not Terminated then Error:=E.Message; end;
end;

constructor TfrmStoryReader.CreateStory(AOwner: TComponent; const AppPath, SourceFile,
  BookTitle, Identity, SettingsFile, PDFLibrary, ResourceContainer, ResourceMember, ResourceRoot: string);
var Footer, Buttons: TPanel; Button: TButton;
begin
  inherited CreateNew(AOwner);
  if not FileExists(TPath.Combine(AppPath,'tools\kindle\python\python.exe')) or
    not FileExists(TPath.Combine(AppPath,'tools\bookconvert\sm_reader.py')) then
    raise EMHLComponentRequired.Create('BookConverter','Для интерактивной книги нужен модуль подготовки книг.');
  FAppPath:=AppPath; FSource:=SourceFile; FBookTitle:=BookTitle; FIdentity:=Identity;
  FSettingsFile:=SettingsFile; FPDFLibrary:=PDFLibrary; FReceived:=-1; FWaiting:=True;
  Font.Name:='Segoe UI'; Font.Size:=9; Caption:='HomeLib Ru — '+BookTitle+' — Интерактивная книга';
  Position:=poOwnerFormCenter; ClientWidth:=960; ClientHeight:=760;
  Constraints.MinWidth:=680; Constraints.MinHeight:=520;
  if AOwner is TCustomForm then begin PopupMode:=pmExplicit; PopupParent:=TCustomForm(AOwner); end;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Self; FStatus.Align:=alTop;
  FStatus.Margins.SetBounds(10,8,10,8); FStatus.AlignWithMargins:=True;
  FStatus.WordWrap:=True; FStatus.Caption:='Подготовка интерактивной книги…';
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom;
  Footer.Height:=190; Footer.BevelOuter:=bvNone; Footer.Padding.SetBounds(10,4,10,6);
  Buttons:=TPanel.Create(Self); Buttons.Parent:=Footer;
  Buttons.SetBounds(10,146,Footer.ClientWidth-20,38);
  Buttons.Anchors:=[akLeft,akRight,akBottom]; Buttons.BevelOuter:=bvNone;
  FChoose:=TButton.Create(Self); FChoose.Parent:=Buttons; FChoose.Align:=alLeft;
  FChoose.Width:=130; FChoose.Caption:='Выбрать ответ'; FChoose.OnClick:=ChooseClick;
  FSave:=TButton.Create(Self); FSave.Parent:=Buttons; FSave.Align:=alLeft;
  FSave.Left:=MaxInt; FSave.Width:=240; FSave.Caption:='Сохранить пройденную ветку…'; FSave.OnClick:=SaveClick;
  FReset:=TButton.Create(Self); FReset.Parent:=Buttons; FReset.Align:=alLeft;
  FReset.Left:=MaxInt; FReset.Width:=150; FReset.Caption:='Начать заново…'; FReset.OnClick:=ResetClick;
  Button:=TButton.Create(Self); Button.Parent:=Buttons; Button.Align:=alRight;
  Button.Width:=90; Button.Caption:='Закрыть'; Button.ModalResult:=mrClose; Button.Cancel:=True;
  FHelp:=TLabel.Create(Self); FHelp.Parent:=Footer; FHelp.AutoSize:=False;
  FHelp.SetBounds(10,108,Footer.ClientWidth-220,34); FHelp.Anchors:=[akLeft,akRight,akBottom];
  FHelp.WordWrap:=True; FHelp.Caption:='Выберите ответ. Путь сохраняется автоматически. '+
    'В FB2/EPUB сохраняется только пройденная ветка.';
  FImages:=TCheckBox.Create(Self); FImages.Name:='cbStoryLargeIllustrations';
  FImages.Parent:=Footer; FImages.SetBounds(Footer.ClientWidth-200,108,190,34);
  FImages.Anchors:=[akRight,akBottom];
  FImages.Caption:='Крупные иллюстрации'; FImages.Enabled:=False;
  FImages.ShowHint:=True;
  FImages.Hint:='Увеличить иллюстрации до высоты страницы. Текст может перейти на следующую страницу. Исходное изображение не изменяется.';
  FImages.OnClick:=ImagesClick;
  FOptions:=TListBox.Create(Self); FOptions.Parent:=Footer;
  FOptions.SetBounds(10,4,Footer.ClientWidth-20,100); FOptions.Anchors:=[akLeft,akTop,akRight,akBottom];
  FOptions.OnClick:=OptionChanged; FOptions.OnDblClick:=ChooseClick; FOptions.OnKeyDown:=OptionKey;
  FTimer:=TTimer.Create(Self); FTimer.Enabled:=False; FTimer.Interval:=100; FTimer.OnTimer:=Tick;
  ApplyMHLControlTheme(Self); ScaleForPPI(Screen.PixelsPerInch);
  FWork:=TPath.Combine(TPath.GetTempPath,'HomeLibRu-story-'+TGUID.NewGuid.ToString);
  ForceDirectories(FWork);
  if not FileExists(FSource) or (TFile.GetSize(FSource)>8*1024*1024) then
    raise Exception.Create('Не найден исходник интерактивной книги или его размер превышает 8 МБ.');
  FSourceHash:=THashSHA2.GetHashStringFromFile(FSource);
  FProgressFile:=TPath.Combine(ExtractFileDir(FSettingsFile),'reader-story-'+FSourceHash+'.json');
  if FileExists(FProgressFile) then
  begin
    if TFile.GetSize(FProgressFile)>4*1024*1024 then raise Exception.Create('Сохранённый путь превышает 4 МБ.');
    TFile.Copy(FProgressFile,TPath.Combine(FWork,'state.json'),False);
  end;
  FWorker:=TStoryWorker.Create(FAppPath,FSource,FWork,ResourceContainer,ResourceMember,ResourceRoot); FStarted:=GetTickCount64;
  FWorker.Start; FTimer.Enabled:=True; OptionChanged(nil);
end;

procedure TfrmStoryReader.ReleaseScene;
begin
  if not Assigned(FReader) then Exit;
  // Save the reader's normal preferences using the outer window bounds;
  // never write an embedded child's (0,0) placement to reader.ini.
  FReader.Hide; FReader.Parent:=nil;
  FReader.SetBounds(Left,Top,Width,Height); FReader.Close;
  FreeAndNil(FReader);
end;

destructor TfrmStoryReader.Destroy;
var Directory, ParentPath: string;
begin
  FClosing:=True; if Assigned(FTimer) then FTimer.Enabled:=False;
  if Assigned(FExporter) then
  begin FExporter.OnTerminate:=nil; FExporter.Terminate; FExporter.WaitFor; FreeAndNil(FExporter); end;
  ReleaseScene;
  if Assigned(FWorker) then begin FWorker.Terminate; FWorker.WaitFor; FreeAndNil(FWorker); end;
  if FWork<>'' then
    try
      Directory:=TPath.GetFullPath(FWork); ParentPath:=TPath.GetFullPath(TPath.GetTempPath);
      if not SameText(ExcludeTrailingPathDelimiter(ExtractFileDir(Directory)),ExcludeTrailingPathDelimiter(ParentPath)) or
        not ExtractFileName(Directory).StartsWith('HomeLibRu-story-{') then
        raise Exception.Create('Рабочая папка читалки не принадлежит этому сеансу.');
      if DirectoryExists(Directory) then TDirectory.Delete(Directory,True);
    except on E: Exception do LogDiagnosticError('Очистка временных файлов интерактивной книги',E); end;
  inherited;
end;

function TfrmStoryReader.GetReady: Boolean;
begin Result:=not FClosing and not FFailed and not FWaiting and Assigned(FReader) and
  FReader.Ready and FReader.Visible and (FReader.Parent=Self) and not Assigned(FExporter); end;
function TfrmStoryReader.GetBookText: string;
begin Result:=''; if Assigned(FReader) and FReader.Ready then Result:=FReader.AllBookText; end;
function TfrmStoryReader.GetPictureCount: Integer;
begin Result:=0; if Assigned(FReader) and FReader.Ready then Result:=FReader.PictureCount; end;

procedure TfrmStoryReader.OptionChanged(Sender: TObject);
begin
  FChoose.Enabled:=Ready and (FOptions.ItemIndex>=0);
  FSave.Enabled:=Ready; FReset.Enabled:=not FWaiting and not Assigned(FExporter);
  FOptions.Enabled:=Ready;
  FImages.Enabled:=Ready and (PictureCount>0);
end;

procedure TfrmStoryReader.ImagesClick(Sender: TObject);
begin
  if not Assigned(FReader) then Exit;
  if FImages.Checked then FReader.SetIllustrationHeightPercent(100)
  else FReader.SetIllustrationHeightPercent(35);
end;

procedure TfrmStoryReader.ShowFailure(const MessageText: string);
begin
  FFailed:=True; FWaiting:=False; FExportTarget:='';
  FStatus.Caption:=MessageText+' Исходная книга и прежнее сохранение не изменены.';
  FOptions.Clear; FSave.Enabled:=False; FChoose.Enabled:=False; FReset.Enabled:=True;
  LogDiagnosticMessage('Интерактивная книга',MessageText);
end;

procedure TfrmStoryReader.SaveProgress;
var Source, Temporary: string;
begin
  Source:=TPath.Combine(FWork,'state.json');
  if not FileExists(Source) or (TFile.GetSize(Source)>4*1024*1024) then
    raise Exception.Create('Не удалось сохранить выбранный путь.');
  ForceDirectories(ExtractFileDir(FProgressFile));
  Temporary:=FProgressFile+'.'+TGUID.NewGuid.ToString+'.tmp';
  try
    TFile.Copy(Source,Temporary,False);
    if not MoveFileEx(PChar(Temporary),PChar(FProgressFile),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
  finally if FileExists(Temporary) then TFile.Delete(Temporary); end;
end;

function TryReadStoryReply(const FileName: string; out Value: TJSONValue): Boolean;
var Handle: THandle; Error: DWORD; Stream: THandleStream; Bytes: TBytes; Offset: Integer;
begin
  Result:=False; Value:=nil;
  // A published reply is immutable. Share the handle with scanners and allow
  // deletion; only a genuine transient sharing/locking conflict is retried.
  // IOUtils.OpenRead wraps EFOpenError in EInOutError, so catching the former
  // around TFile.ReadAllText did not protect the native poller on Windows.
  Handle:=CreateFile(PChar(FileName),GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then
  begin
    Error:=GetLastError;
    if (Error=ERROR_SHARING_VIOLATION) or (Error=ERROR_LOCK_VIOLATION) then Exit;
    RaiseLastOSError(Error);
  end;
  Stream:=nil;
  try
    Stream:=THandleStream.Create(Handle);
    if (Stream.Size<0) or (Stream.Size>256*1024) then
      raise Exception.Create('Повреждён ответ обработчика книги.');
    SetLength(Bytes,Integer(Stream.Size));
    if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
    Offset:=0;
    if (Length(Bytes)>=3) and (Bytes[0]=$EF) and (Bytes[1]=$BB) and (Bytes[2]=$BF) then Offset:=3;
    Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes,Offset,Length(Bytes)-Offset));
    Result:=True;
  finally Stream.Free; CloseHandle(Handle); end;
end;

procedure TfrmStoryReader.Tick(Sender: TObject);
var ReplyFile, Scene, MessageText, View: string; Value: TJSONValue; Items: TJSONArray;
  Number, Count, Action: Integer; IsInput: Boolean;
begin
  if FClosing then Exit;
  if FExportComplete and Assigned(FExporter) and FExporter.Finished then
  begin
    MessageText:=FExporter.Error; FreeAndNil(FExporter); FExportComplete:=False;
    if MessageText='' then FStatus.Caption:='Пройденная ветка сохранена. Другие ветки остаются в исходной интерактивной книге.'
    else begin FStatus.Caption:='Не удалось сохранить ветку: '+MessageText; LogDiagnosticMessage('Сохранение интерактивной книги',MessageText); end;
  end;
  if Assigned(FReader) and FReader.Ready and not FReader.Visible then
  begin
    FReader.BorderStyle:=bsNone; FReader.Parent:=Self; FReader.Align:=alClient;
    // A new view hash has no saved position. A resumed view keeps its actual
    // last page through the existing reader settings instead of jumping to 0.
    FReader.Show;
  end;
  if not FFailed and Assigned(FReader) and FReader.LoadFinished and not FReader.Ready then
    ShowFailure('Не удалось показать параграф: '+FReader.ReaderStatus.Caption);
  OptionChanged(nil);
  if not FWaiting then Exit;
  if GetTickCount64-FStarted>45000 then
  begin FWorker.Terminate; ShowFailure('Подготовка интерактивной книги превысила 45 секунд.'); Exit; end;
  ReplyFile:=TPath.Combine(FWork,'reply-'+IntToStr(FSequence)+'.json');
  if not FileExists(ReplyFile) then
  begin
    if FWorker.Finished then ShowFailure('Не удалось запустить обработчик книги. '+FWorker.Error);
    Exit;
  end;
  Value:=nil;
  try
  try
    if not TryReadStoryReply(ReplyFile,Value) then Exit;
    if not Assigned(Value) or not Value.TryGetValue<Integer>('id',Number) then
      raise Exception.Create('Не удалось прочитать ответ обработчика книги.');
    if Number=FReceived then Exit;
    if Number<>FSequence then raise Exception.Create('Нарушен порядок ответов обработчика книги.');
    FReceived:=Number;
    if Value.TryGetValue<string>('error',MessageText) then begin ShowFailure(MessageText); Exit; end;
    if not Value.TryGetValue<string>('source',MessageText) or not SameText(MessageText,FSourceHash) or
      not Value.TryGetValue<string>('scene',Scene) or (Scene<>'scene-'+IntToStr(Number)+'.epub') or
      not Value.TryGetValue<string>('view',View) or (Length(View)<>64) or
      not Value.TryGetValue<Integer>('visited',Count) or (Count<1) or
      not Value.TryGetValue<TJSONArray>('choices',Items) or (Items.Count>1000) then
      raise Exception.Create('Повреждены сведения интерактивной книги.');
    SaveProgress;
    if View<>FViewHash then
    begin
      ReleaseScene; FViewHash:=View;
      FReader:=TfrmBuiltinReader.Create(Self);
      ImagesClick(nil);
      FReader.OpenBook(TPath.Combine(FWork,Scene),FBookTitle,FIdentity+':SM:'+View,FSettingsFile,FPDFLibrary);
    end;
    FVisited:=Count; FOptions.Items.BeginUpdate;
    try
      FOptions.Clear; SetLength(FInput,Items.Count);
      for var I:=0 to Items.Count-1 do
      begin
        if not Items[I].TryGetValue<Integer>('id',Action) or (Action<=0) or
          not Items[I].TryGetValue<string>('label',MessageText) or (Length(MessageText)>2048) or
          not Items[I].TryGetValue<Boolean>('input',IsInput) then
          raise Exception.Create('Повреждён список ответов интерактивной книги.');
        FInput[I]:=IsInput; FOptions.Items.AddObject(MessageText,TObject(NativeInt(Action)));
      end;
      if Items.Count>0 then FOptions.ItemIndex:=0;
    finally FOptions.Items.EndUpdate; end;
    FFailed:=False; FWaiting:=False; FStatus.Caption:='Показано параграфов: '+IntToStr(FVisited)+' · Путь сохранён';
    if Value.TryGetValue<TJSONArray>('warnings',Items) and (Items.Count>0) then
      FStatus.Caption:=FStatus.Caption+sLineBreak+Items[0].Value;
    if FExportTarget<>'' then
    begin
      if not Value.TryGetValue<string>('snapshot',Scene) or (Scene<>'history.epub') then
        raise Exception.Create('Не подготовлена пройденная ветка книги.');
      FExporter:=TStoryExporter.Create(FAppPath,TPath.Combine(FWork,Scene),FExportTarget,
        FBookTitle+' — пройденная ветка',FWork);
      FExporter.OnTerminate:=ExportFinished; FExporter.Start;
      FStatus.Caption:='Сохранение пройденной ветки…'; FExportTarget:='';
    end;
    OptionChanged(nil);
  except on E: Exception do ShowFailure(E.Message); end;
  finally Value.Free; end;
end;

procedure TfrmStoryReader.PublishCommand(const Command: string; Action: Integer;
  const Text: string; HasInput: Boolean);
var Value: TJSONObject; Temporary, Target: string;
begin
  if FWaiting or not Assigned(FWorker) or FWorker.Finished then
    raise Exception.Create('Обработчик книги занят или завершён. Откройте книгу заново.');
  Inc(FSequence); Value:=TJSONObject.Create;
  try
    Value.AddPair('id',TJSONNumber.Create(FSequence)); Value.AddPair('command',Command);
    if Action>0 then Value.AddPair('action',TJSONNumber.Create(Action));
    if HasInput then Value.AddPair('text',Text);
    Target:=TPath.Combine(FWork,'request-'+IntToStr(FSequence)+'.json'); Temporary:=Target+'.pending';
    TFile.WriteAllText(Temporary,Value.ToJSON,TEncoding.UTF8);
    if not MoveFileEx(PChar(Temporary),PChar(Target),0) then RaiseLastOSError;
  finally Value.Free; end;
  FWaiting:=True; FStarted:=GetTickCount64; FStatus.Caption:='Выполнение выбранного действия…'; OptionChanged(nil);
end;

procedure TfrmStoryReader.Choose(Index: Integer; const Text: string);
begin
  if not Ready or (Index<0) or (Index>=FOptions.Items.Count) then raise Exception.Create('Выберите доступный ответ.');
  PublishCommand('choose',NativeInt(FOptions.Items.Objects[Index]),Text,FInput[Index]);
end;

procedure TfrmStoryReader.ChooseClick(Sender: TObject);
var Index: Integer; Text: string;
begin
  Index:=FOptions.ItemIndex; if not Ready or (Index<0) then Exit;
  Text:=''; if FInput[Index] and not InputQuery('Интерактивная книга','Введите ответ:',Text) then Exit;
  Choose(Index,Text);
end;

procedure TfrmStoryReader.OptionKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin if Key=VK_RETURN then begin Key:=0; ChooseClick(nil); end; end;

procedure TfrmStoryReader.ResetClick(Sender: TObject);
begin
  if MessageDlg('Начать эту интерактивную книгу заново? Выбранный путь будет заменён новым.',mtConfirmation,[mbYes,mbNo],0)=mrYes then
    PublishCommand('reset');
end;

procedure TfrmStoryReader.SaveRoute(const TargetFile: string);
begin
  if not Ready then raise Exception.Create('Дождитесь открытия параграфа книги.');
  if FileExists(TargetFile) then raise Exception.Create('Файл результата уже существует. Выберите другое имя.');
  if not SameText(ExtractFileExt(TargetFile),'.fb2') and not SameText(ExtractFileExt(TargetFile),'.epub') then
    raise Exception.Create('Выберите FB2 или EPUB.');
  FExportTarget:=TargetFile;
  try PublishCommand('snapshot'); except FExportTarget:=''; raise; end;
end;

procedure TfrmStoryReader.SaveClick(Sender: TObject);
var Dialog: TSaveDialog;
begin
  Dialog:=TSaveDialog.Create(Self);
  try
    Dialog.Title:='Сохранить показанный текст и выбранные ответы';
    Dialog.Filter:='Книга FB2 (*.fb2)|*.fb2|Книга EPUB (*.epub)|*.epub';
    Dialog.DefaultExt:='fb2'; Dialog.FileName:='Пройденная ветка.fb2';
    Dialog.Options:=Dialog.Options+[ofPathMustExist,ofNoReadOnlyReturn];
    if Dialog.Execute then SaveRoute(Dialog.FileName);
  finally Dialog.Free; end;
end;

procedure TfrmStoryReader.ExportFinished(Sender: TObject);
begin
  if FClosing then Exit;
  FExportComplete:=True;
end;

procedure OpenInteractiveStory(Owner: TComponent; const AppPath, SourceFile, BookTitle,
  Identity, SettingsFile, PDFLibrary, ResourceContainer, ResourceMember, ResourceRoot: string);
var Form: TfrmStoryReader;
begin
  Form:=TfrmStoryReader.CreateStory(Owner,AppPath,SourceFile,BookTitle,Identity,SettingsFile,PDFLibrary,
    ResourceContainer,ResourceMember,ResourceRoot);
  try Form.ShowModal; finally Form.Free; end;
end;

end.
