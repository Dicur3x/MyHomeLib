program StoryReaderTest;
{$APPTYPE CONSOLE}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}

uses NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  System.Hash, System.Diagnostics, System.Generics.Collections, System.NetEncoding, System.Zip, Winapi.Windows,
  Winapi.ActiveX, Vcl.Forms, Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls, frm_StoryReader, unit_ReaderFormats,
  unit_ReaderDocument, dm_user;

procedure Require(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;

type TQualityProbe = class
  public Timer: TTimer; Count: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Tick(Sender: TObject);
  end;

  TReplyLockProbe = class
  private
    FTimer: TTimer; FForm: TfrmStoryReader; FPath: string;
    FHandle: THandle; FStarted: UInt64;
    procedure Tick(Sender: TObject);
  public
    Acquired, Completed, Premature: Boolean;
    constructor Create(Form: TfrmStoryReader);
    destructor Destroy; override;
  end;

constructor TReplyLockProbe.Create(Form: TfrmStoryReader);
begin
  inherited Create; FForm:=Form; FHandle:=INVALID_HANDLE_VALUE;
  FPath:=TPath.Combine(Form.WorkDirectory,'reply-1.json');
  FTimer:=TTimer.Create(nil); FTimer.Interval:=5; FTimer.OnTimer:=Tick;
end;

destructor TReplyLockProbe.Destroy;
begin
  FTimer.Free;
  if FHandle<>INVALID_HANDLE_VALUE then CloseHandle(FHandle);
  inherited;
end;

procedure TReplyLockProbe.Tick(Sender: TObject);
begin
  if not Acquired then
  begin
    if not FileExists(FPath) then Exit;
    // A scanner-like read handle deliberately denies other readers. Keep
    // deletion shared so this does not interfere with atomic publication.
    FHandle:=CreateFile(PChar(FPath),GENERIC_READ,FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    if FHandle=INVALID_HANDLE_VALUE then Exit;
    Premature:=FForm.Ready;
    Acquired:=True; FStarted:=GetTickCount64;
  end;
  if GetTickCount64-FStarted<700 then
    Premature:=Premature or FForm.Ready
  else
  begin
    CloseHandle(FHandle); FHandle:=INVALID_HANDLE_VALUE;
    Completed:=True; FTimer.Enabled:=False;
  end;
end;

constructor TQualityProbe.Create;
begin
  inherited; Timer:=TTimer.Create(nil); Timer.Interval:=50; Timer.OnTimer:=Tick;
end;
destructor TQualityProbe.Destroy;
begin Timer.Free; inherited; end;
procedure TQualityProbe.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible and string(Screen.Forms[I].Caption).StartsWith('Качество изображений') then
    begin Inc(Count); Screen.Forms[I].ModalResult:=mrOk; end;
end;

procedure WaitReady(Form: TfrmStoryReader);
var Clock: TStopwatch;
begin
  Clock:=TStopwatch.StartNew;
  repeat
    Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
    if Form.Failed then raise Exception.Create('Story failed: '+Form.StatusText.Caption);
    if Clock.ElapsedMilliseconds>60000 then raise Exception.Create('Story timeout: '+Form.StatusText.Caption);
  until Form.Ready;
end;

procedure Select(Form: TfrmStoryReader; const LabelText: string; const Text: string = '');
var Index: Integer;
begin
  Index:=Form.Choices.Items.IndexOf(LabelText);
  Require(Index>=0,'Missing actual native story choice: '+LabelText);
  Form.Choose(Index,Text); WaitReady(Form);
end;

procedure Save(Form: TfrmStoryReader; const Target: string; const Expected: TArray<string>);
var Clock: TStopwatch; Document: TReaderDocument;
begin
  Form.SaveRoute(Target); Clock:=TStopwatch.StartNew;
  repeat
    Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
    if Form.Failed then raise Exception.Create('Story export failed: '+Form.StatusText.Caption);
    if Clock.ElapsedMilliseconds>60000 then raise Exception.Create('Story export timeout: '+Form.StatusText.Caption);
  until Form.Ready;
  Require(FileExists(Target),'Native story export missing: '+Form.StatusText.Caption);
  Document:=TReaderDocument.Create;
  try
    Document.Load(Target);
    for var Text in Expected do Require(Pos(Text,Document.PlainText)>0,'Missing native route export text: '+Text);
    if Pos('actual-',ExtractFileName(Target))<>1 then Require(Document.ImageCount>0,'Native route export lost companion images');
    Require(Pos('Текст другой ветки',Document.PlainText)=0,'Untaken branch leaked into native export');
  finally Document.Free; end;
end;

var Root, Source, SettingsFile, Work, Progress, Hash, Text, Name: string;
  Form: TfrmStoryReader; NativeSource: string; Visited: Integer; Unique: TDictionary<string,Boolean>;
  Archive: TZipFile; Picture: TBytesStream; Quality: TQualityProbe; ReplyLock: TReplyLockProbe;
  LargeImages: TCheckBox;
begin
  try
    RequireIsolatedRegression; Application.Initialize; Application.ShowMainForm:=False;
    CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
    try
      Application.CreateForm(TDMUser,DMUser); DMUser.Init;
      Root:=ExtractFilePath(ParamStr(0)); Source:=Root+'story.wrong.pdf'; SettingsFile:=Root+'Data\story-reader.ini';
      if FindCmdLineSwitch('visual') then
      begin
        NativeSource:='';
        for var I:=1 to ParamCount do if ParamStr(I).StartsWith('--actual-source=') then NativeSource:=ParamStr(I).Substring(16);
        Form:=TfrmStoryReader.CreateStory(nil,Root,NativeSource,'Миры сбываются','visual-804498',SettingsFile,'');
        try Form.ShowModal; finally Form.Free; end;
        Writeln('PASS native SM visual preview closed normally'); Flush(Output); Exit;
      end;
      ForceDirectories(ExtractFileDir(SettingsFile));
      TFile.WriteAllText(Source,'ASMJS[::]64[::]0[::]0[::]1[::]mw[::]html'+sLineBreak+
        ':: StoryTitle[::]0[::]0'+sLineBreak+'История с выбором'+sLineBreak+
        ':: Start[::]0[::]0'+sLineBreak+'picture("files/background.png");'+sLineBreak+
        '\ <img src="files/inline.png"/> Начало истории [[Выбрать|Ask {$chosen=1;}]] [[Мимо|Ask {$chosen=0;}]]'+sLineBreak+
        ':: Ask[::]0[::]0'+sLineBreak+'if($chosen){'+sLineBreak+'\ Текст выбранной ветки'+sLineBreak+
        '}else{'+sLineBreak+'\ Текст другой ветки'+sLineBreak+'}'+sLineBreak+'input("End");'+sLineBreak+
        ':: End[::]0[::]0'+sLineBreak+'print("Ответ: "+$$input);'+sLineBreak,TEncoding.UTF8);
      Hash:=THashSHA2.GetHashStringFromFile(Source);
      Archive:=TZipFile.Create;
      try
        Archive.Open(Root+'story-source.zip',zmWrite); Archive.Add(Source,'novel/original.sm');
        Picture:=TBytesStream.Create(TNetEncoding.Base64.DecodeStringToBytes('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg=='));
        try
          Archive.Add(Picture,'novel/files/background.png'); Picture.Position:=0;
          Archive.Add(Picture,'novel/files/inline.png');
        finally Picture.Free; end;
      finally Archive.Free; end;
      Require(DetectReaderExtension(Source)='.sm','SM content under false suffix not detected');
      Require(IsBuiltinReaderFormat('.sm'),'SM unavailable in native reader choice');
      Form:=TfrmStoryReader.CreateStory(nil,Root,Source,'История с выбором','synthetic-story',SettingsFile,'',Root+'story-source.zip','novel/original.sm');
      Quality:=TQualityProbe.Create;
      try
        Form.Show; WaitReady(Form); Work:=Form.WorkDirectory; Progress:=Form.ProgressFile;
        Require(Pos('Начало истории',Form.BookText)>0,'Native SM Start text missing');
        Require(Form.PictureCount=2,'Native SM background and inline image missing from original archive');
        LargeImages:=Form.FindComponent('cbStoryLargeIllustrations') as TCheckBox;
        Require(Assigned(LargeImages) and LargeImages.Enabled and not LargeImages.Checked,
          'Native SM large illustration control unavailable');
        Text:=Form.BookText; LargeImages.Checked:=True; LargeImages.OnClick(LargeImages);
        WaitReady(Form);
        Require((Form.BookText=Text) and (Form.PictureCount=2),
          'Enlarging native SM illustrations changed text or lost media');
        ReplyLock:=TReplyLockProbe.Create(Form);
        try
          Select(Form,'Выбрать');
          Require(ReplyLock.Acquired and ReplyLock.Completed and not ReplyLock.Premature,
            'Native transient reply lock was not exercised before consumption');
        finally ReplyLock.Free; end;
        Require(Pos('Текст выбранной ветки',Form.BookText)>0,'Selected native SM branch missing');
        Require(Form.PictureCount=1,'Native SM persistent illustration lost after transition');
        Require(LargeImages.Checked and LargeImages.Enabled,
          'Large illustration preference lost at the next SM scene');
        LargeImages.Checked:=False; LargeImages.OnClick(LargeImages); WaitReady(Form);
        Require(Pos('Текст другой ветки',Form.BookText)=0,'Wrong branch shown in native SM reader');
        Select(Form,'Ввести текст','Привет ё 😀');
        Require(Pos('Ответ: Привет ё 😀',Form.BookText)>0,'Native SM input text lost');
        Text:=Form.BookText;
        Save(Form,Root+'route.fb2',TArray<string>.Create('Это пройденная ветка','Начало истории','Выбран ответ: Выбрать','Текст выбранной ветки','Ответ: Привет ё 😀'));
        Save(Form,Root+'route.epub',TArray<string>.Create('Это пройденная ветка','Начало истории','Текст выбранной ветки','Ответ: Привет ё 😀'));
        Require(Quality.Count>=2,'Native route export did not offer image quality for both formats');
        try Form.SaveRoute(Root+'route.fb2'); Require(False,'Existing native route replaced');
        except on E: Exception do Require(Pos('уже существует',E.Message)>0,'Unexpected overwrite guard'); end;
        Form.Close;
      finally Quality.Free; Form.Free; end;
      Require(not DirectoryExists(Work),'Native story workspace not cleaned');
      Require(FileExists(Progress),'Native story choices not saved');
      Form:=TfrmStoryReader.CreateStory(nil,Root,Source,'История с выбором','synthetic-story',SettingsFile,'',Root+'story-source.zip','novel/original.sm');
      try
        Form.Show; WaitReady(Form); Work:=Form.WorkDirectory;
        Require(Form.BookText=Text,'Reopened native SM branch differs'); Require(Form.VisitedCount=3,'Reopened SM route lost steps'); Form.Close;
        Require(Form.PictureCount=1,'Reopened native SM illustration lost');
      finally Form.Free; end;
      Require(not DirectoryExists(Work),'Reopened native story workspace not cleaned');
      Form:=TfrmStoryReader.CreateStory(nil,Root,Source,'Closing','closing-story',Root+'cancel\reader.ini','',Root+'story-source.zip','novel/original.sm');
      try Work:=Form.WorkDirectory; Form.Show; Application.ProcessMessages; finally Form.Free; end;
      Require(not DirectoryExists(Work),'Cancelled native story workspace not cleaned');
      Require(THashSHA2.GetHashStringFromFile(Source)=Hash,'Native SM source changed');
      Writeln('PASS native SM false suffix, real controls, conditional branch, Unicode input, FB2 EPUB route export, verified resume, existing target and cancellation cleanup'); Flush(Output);
      Writeln('PASS native SM large illustrations preserve text, source media and scene transitions'); Flush(Output);
      Writeln('PASS native SM retries a 700 ms reply sharing violation without losing the chosen branch'); Flush(Output);
      NativeSource:='';
      for var I:=1 to ParamCount do if ParamStr(I).StartsWith('--actual-source=') then NativeSource:=ParamStr(I).Substring(16);
      if NativeSource<>'' then
      begin
        Hash:=THashSHA2.GetHashStringFromFile(NativeSource);
        Form:=TfrmStoryReader.CreateStory(nil,Root,NativeSource,'Миры сбываются','actual-804498',Root+'actual\reader.ini','');
        Unique:=TDictionary<string,Boolean>.Create;
        try
          Form.Show; WaitReady(Form); Work:=Form.WorkDirectory;
          for var Step:=1 to 40 do
          begin
            Unique.AddOrSetValue(THashSHA2.GetHashString(Form.BookText),True);
            Visited:=-1;
            for var I:=0 to Form.Choices.Items.Count-1 do
            begin
              Name:=Form.Choices.Items[I].ToLower;
              if (Pos('предыдущ',Name)=0) and (Pos('начал',Name)=0) then begin Visited:=I; Break; end;
            end;
            Require(Visited>=0,'Actual native SM route ended before 40 choices');
            Form.Choose(Visited); WaitReady(Form);
          end;
          Require(Unique.Count>=10,'Actual native SM route repeated the same scene');
          Text:=Form.BookText;
          Save(Form,Root+'actual-route.fb2',TArray<string>.Create('Это пройденная ветка'));
          Save(Form,Root+'actual-route.epub',TArray<string>.Create('Это пройденная ветка'));
          Form.Close;
        finally Unique.Free; Form.Free; end;
        Require(not DirectoryExists(Work),'Actual native story workspace not cleaned');
        Form:=TfrmStoryReader.CreateStory(nil,Root,NativeSource,'Миры сбываются','actual-804498',Root+'actual\reader.ini','');
        try
          Form.Show; WaitReady(Form); Work:=Form.WorkDirectory;
          Require(Form.BookText=Text,'Actual native SM saved path differs after reopening');
          Require(Form.VisitedCount=41,'Actual native SM saved path lost choices'); Form.Close;
        finally Form.Free; end;
        Require(not DirectoryExists(Work),'Actual reopened story workspace not cleaned');
        Require(THashSHA2.GetHashStringFromFile(NativeSource)=Hash,'Actual SM input changed');
        Writeln('PASS actual native SM 804498 40 choices, distinct scenes, FB2 EPUB explicit route exports, exact resume and source/workspace preservation'); Flush(Output);
      end;
    finally FreeAndNil(DMUser); CoUninitialize; end;
  except on E: Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); Flush(Output); Halt(1); end; end;
end.
