program BookCompressionUiTest;

{$APPTYPE CONSOLE}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}

uses System.SysUtils, System.Classes, System.IOUtils, System.IniFiles, System.Generics.Collections,
  Winapi.Windows, Winapi.ActiveX, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.Graphics,
  Vcl.ComCtrls, unit_Settings, unit_MHLTheme, unit_FormatComponents,
  frm_BookCompression, unit_BookCompressionRuntime, unit_BookCompressionOperation,
  {$IFDEF HL_LINK_CATALOGUE} frm_main, {$ENDIF} System.Types;

type
  TProbe = class
    Stops: Integer;
    Decision: TCompressionReview;
    procedure Stop(Sender: TObject);
    procedure Review(Value: TCompressionReview);
  end;

procedure TProbe.Stop(Sender: TObject);
begin Inc(Stops); end;
procedure TProbe.Review(Value: TCompressionReview);
begin Decision:=Value; end;

procedure Check(Condition: Boolean; const MessageText: string);
begin if not Condition then raise Exception.Create(MessageText); end;

procedure CheckButtons(Form: TForm);
var Control: TControl;
begin
  for var I:=0 to Form.ComponentCount-1 do
  begin
    if not (Form.Components[I] is TButton) then Continue;
    Control:=TControl(Form.Components[I]);
    Check((Control.Left>=0) and (Control.Top>=0) and
      (Control.Left+Control.Width<=Form.ClientWidth) and
      (Control.Top+Control.Height<=Form.ClientHeight),Format('Button outside client: %s PPI %d (%d,%d,%d,%d) in %dx%d',
      [Control.Name,Form.CurrentPPI,Control.Left,Control.Top,Control.Width,Control.Height,Form.ClientWidth,Form.ClientHeight]));
    Form.Canvas.Font:=TButton(Control).Font;
    Check(Form.Canvas.TextWidth(TButton(Control).Caption)+MulDiv(12,Form.CurrentPPI,96)<=Control.Width,
      'Clipped button: '+Control.Name);
  end;
end;

var Root, Registry: string; Options, Readback: TBookCompressionOperationOptions;
    Dialog: TfrmBookCompressionOptions; View: TfrmBookCompressionProgress;
    Probe: TProbe; State: TBookCompressionOperationStatus; Checks: Integer;
begin
  try
    Root:=ExpandFileName(ParamStr(1));
    Check(ExtractFileName(Root).StartsWith('HomeLibre-compression-ui-test-'),'Use a private fixture directory');
    Check(TFile.ReadAllText(TPath.Combine(Root,'fixture.marker'),TEncoding.UTF8)='HomeLibre isolated compression UI v1',
      'Missing private fixture marker');
    ConfigureMHLHostProfile(Root,'ui-test.ini','ui-test.dbs2');
    CoInitializeEx(nil,COINIT_APARTMENTTHREADED); Application.Initialize;
    Registry:=TPath.Combine(Root,'compression-work.ini');
    Options:=Default(TBookCompressionOperationOptions);
    LoadCompressionPreferences(Registry,TPath.Combine(Root,'work'),Options);
    Check((Options.Profile='balanced') and Options.ReviewResults and not Options.Grayscale and
      not Options.BackupOriginals,'Initial choices; backup optional');
    Options.Profile:='maximum'; Options.Grayscale:=True; Options.ReviewResults:=False;
    Options.BackupFolder:=TPath.Combine(Root,'оригиналы'); Options.BackupOriginals:=True;
    RememberCompressionWork(Registry,Options); RememberCompressionWork(Registry,Options);
    Readback:=Default(TBookCompressionOperationOptions);
    LoadCompressionPreferences(Registry,'',Readback);
    Check((Readback.Profile='maximum') and Readback.Grayscale and not Readback.ReviewResults and
      (Readback.WorkRoot=Options.WorkRoot) and Readback.BackupOriginals and
      (Readback.BackupFolder=Options.BackupFolder),'Preferences round trip');
    Check(Length(CompressionWorkRoots(Registry))=1,'Do not duplicate recovery roots');
    Options.WorkRoot:=TPath.Combine(Root,'другая рабочая папка'); RememberCompressionWork(Registry,Options);
    Check(Length(CompressionWorkRoots(Registry))=2,'Keep previous recovery root');
    Check(not DirectoryExists(Options.WorkRoot),'Remembering a work root does not create payloads');
    Check((Options.QueueName<>'') and (Options.QueueName=Readback.QueueName),'Stable profile queue');
    LoadCompressionPreferences(TPath.Combine(Root,'second-profile.ini'),Options.WorkRoot,Readback);
    Check(CompressionQueueRoot(Options)<>CompressionQueueRoot(Readback),'Separate profiles sharing one workspace');
    Readback.Profile:='original'; Readback.Grayscale:=True;
    var Missing:=ResolveSelectedCompressionTools(Root,Readback);
    Check(TArray.IndexOf<string>(Missing,'BookProcessing')>=0,'Missing preparation component requested');
    Check(TArray.IndexOf<string>(Missing,'ImageProcessing')>=0,'Grayscale requires images even without resizing');
    Readback.QueueName:='..\another-profile'; var Rejected:=False;
    try CompressionQueueRoot(Readback); except on E:EArgumentException do Rejected:=True; end;
    Check(Rejected,'Reject a queue name that escapes the work folder');
    Check(TArray.IndexOf<string>(FormatComponentRequiredFiles('BookProcessing','3.0.0.13'),
      SELECTED_COMPRESSION_WORKER)<0,'Old module requirements retained');
    Check(TArray.IndexOf<string>(FormatComponentRequiredFiles('BookProcessing','3.0.0.14'),
      SELECTED_COMPRESSION_WORKER)>=0,'New module requires the selected-book worker');
    Probe:=TProbe.Create; Checks:=13;
    try
      for var Dark in [False,True] do
      begin
        SetMHLTheme(Dark);
        for var PPI in TArray<Integer>.Create(96,144,192,288) do
        begin
          Options.Profile:='original'; Options.ReviewResults:=True; Options.BackupOriginals:=False;
          Dialog:=TfrmBookCompressionOptions.CreateOptions(nil,10,Options);
          try
            Dialog.HandleNeeded; Dialog.ScaleForPPI(PPI); CheckButtons(Dialog);
            Check(Dialog.SelectedOptions.Grayscale,'Grayscale also available without resizing');
            Check(Dialog.SelectedOptions.Profile='original','Original choice retained');
            Check(TComboBox(Dialog.FindComponent('CompressionProfile')).Items.Count=4,'Do not advertise unimplemented JPEG XL mode');
            Check(Dialog.Color=MHLThemeBackground,'Options theme'); Inc(Checks);
            var InitialHeight:=Dialog.ClientHeight;
            Check(not TEdit(Dialog.FindComponent('CompressionBackupFolder')).Visible,'Backup folder hidden when disabled');
            var BackupChoice:=TCheckBox(Dialog.FindComponent('CompressionBackup'));
            BackupChoice.Checked:=True; BackupChoice.OnClick(BackupChoice);
            CheckButtons(Dialog);
            Check(Dialog.ClientHeight>InitialHeight,Format('Room for optional backup folder: %d PPI %d → %d',
              [Dialog.CurrentPPI,InitialHeight,Dialog.ClientHeight]));
            Check(TEdit(Dialog.FindComponent('CompressionBackupFolder')).Visible,'Backup folder visible when enabled');
            Check(Dialog.SelectedOptions.BackupOriginals and
              (Dialog.SelectedOptions.BackupFolder=Options.BackupFolder),'Selected backup options');
            BackupChoice.Checked:=False; BackupChoice.OnClick(BackupChoice);
            // VCL styles can adjust a newly created native dialog border by
            // a few pixels. The optional section must collapse, not remain
            // as an empty 80px gap after removing the checkbox.
            Check(Abs(Dialog.ClientHeight-InitialHeight)<=MulDiv(4,PPI,96),Format('Disabled backup collapses again: %d PPI %d → %d',
              [Dialog.CurrentPPI,InitialHeight,Dialog.ClientHeight]));
            CheckButtons(Dialog);
          finally Dialog.Free; end;
          View:=TfrmBookCompressionProgress.CreateProgress(nil,Probe.Stop,Probe.Review);
          try
            View.HandleNeeded; View.ScaleForPPI(PPI); CheckButtons(View);
            State:=Default(TBookCompressionOperationStatus); State.SavingsKnown:=True;
            State.Stage:='Подготовка'; State.FilesTotal:=2; State.BooksTotal:=12;
            State.AwaitingReview:=True; State.InputBytes:=30000000; State.OutputBytes:=10000000;
            State.Source:=TPath.Combine(Root,'Общий архив с двенадцатью книгами.zip');
            State.Member:='Автор/Выбранная книга.fb2'; View.UpdateProgress(State);
            Check(TButton(View.FindComponent('CompressionApply')).Visible,'Review actions visible');
            Check(Pos('→',TLabel(View.FindComponent('CompressionSizes')).Caption)>0,'Before and after sizes shown');
            TButton(View.FindComponent('CompressionSkip')).Click; Check(Probe.Decision=crSkip,'Skip event');
            View.UpdateProgress(State); TButton(View.FindComponent('CompressionApplyAll')).Click;
            Check(Probe.Decision=crApplyRemaining,'Apply remaining event');
            State.AwaitingReview:=False; View.UpdateProgress(State);
            TButton(View.FindComponent('CompressionStop')).Click;
            Check(Probe.Stops>0,'Stop event');
            State.Stopping:=True; View.UpdateProgress(State);
            Check(not TButton(View.FindComponent('CompressionStop')).Enabled,'Stopping waits for safe boundary');
            State.Finished:=True; State.Error:='Проверенная тестовая ошибка';
            State.ChangedFiles:=1; State.SavedBytes:=20000000; View.UpdateProgress(State);
            Check(TButton(View.FindComponent('CompressionStop')).Caption='Закрыть','Result stays in this window');
            Check(not TButton(View.FindComponent('CompressionApply')).Visible,'No stale review after finish');
            Check(Pos(State.Error,TLabel(View.FindComponent('CompressionNote')).Caption)>0,'Result error visible');
            Check(View.Color=MHLThemeBackground,'Progress theme'); Inc(Checks);
          finally View.Free; end;
        end;
      end;
    finally Probe.Free; FinalizeMHLTheme; end;
    Writeln('PASS ',Checks,' compression UI checks; no user files touched.');
  except on E:Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); Halt(1); end; end;
end.
