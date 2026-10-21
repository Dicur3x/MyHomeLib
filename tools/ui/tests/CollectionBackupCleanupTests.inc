type
  TBackupRemovalResponder = class
  public
    Timer: TTimer;
    Accept, Seen, SafeDefault, FullPaths: Boolean;
    Path, SecondPath: string;
    procedure Tick(Sender: TObject);
  end;

procedure TBackupRemovalResponder.Tick(Sender: TObject);
var Form: TForm; B: TButton;
begin
  for var I:=0 to Screen.FormCount-1 do
  begin
    Form:=Screen.Forms[I]; if Form.Name<>'ConfirmBackupRemoval' then Continue;
    Seen:=True;
    B:=Form.FindComponent('btnCancelBackupRemoval') as TButton;
    SafeDefault:=B.Default and B.Cancel and (Form.ActiveControl=B);
    for var J:=0 to Form.ComponentCount-1 do
      if Form.Components[J] is TMemo then FullPaths:=string(TMemo(Form.Components[J]).Text).Contains(Path) and string(TMemo(Form.Components[J]).Text).Contains(SecondPath);
    Timer.Enabled:=False;
    if Accept then B:=Form.FindComponent('btnConfirmBackupRemoval') as TButton;
    B.Click; Exit;
  end;
end;

procedure TestCollectionBackupCleanup;
var Base, A, B, Latest, Foreign, FileName, Hash, OtherHash, Added: string;
  Plan: TCollectionBackupRemovalPlan; Stream: TFileStream; Rejected: Boolean; Size: Int64;
  Dialog: TfrmCollectionBackup; List: TListBox; Button: TButton; Reply: TBackupRemovalResponder;
  OldTheme: Boolean;
  procedure Fixture(const Folder, Day: string; Complete: Boolean = True);
  begin
    ForceDirectories(Folder);
    TFile.WriteAllText(TPath.Combine(Folder,'backup-info.json'),
      '{"schemaVersion":1,"createdAtUtc":"2026-10-'+Day+'T01:02:03Z","operation":"book-duplicates"}',TEncoding.UTF8);
    TFile.WriteAllText(TPath.Combine(Folder,'restore-paths.txt'),'Isolated cleanup fixture',TEncoding.UTF8);
    TFile.WriteAllText(TPath.Combine(Folder,'system.hlc2'),'personal snapshot',TEncoding.UTF8);
    if Complete then TFile.WriteAllText(TPath.Combine(Folder,'destination.hlc2'),'catalogue snapshot',TEncoding.UTF8)
    else TFile.WriteAllText(TPath.Combine(Folder,'source-1.hlc2'),'unfinished legacy snapshot',TEncoding.UTF8);
  end;
  procedure Reject(const Folder: string);
  begin
    Rejected:=False; Plan:=nil;
    try
      try Plan:=TCollectionBackupRemovalPlan.Create(TArray<string>.Create(Folder));
      except on E: Exception do Rejected:=True; end;
    finally Plan.Free; Plan:=nil; end;
    Require(Rejected,'Cleanup accepted an unsafe backup path: '+Folder);
  end;
  procedure SelectDay(const Day: string);
  begin
    for var I:=0 to List.Items.Count-1 do
      if List.Items[I].Contains(Day+'.10.2026') then
      begin List.ClearSelection; List.ItemIndex:=I; List.Selected[I]:=True; List.OnClick(List); Exit; end;
    raise Exception.Create('Cleanup UI lost fixture day '+Day);
  end;
begin
  Base:=TPath.Combine(Settings.AppPath,'backup-cleanup-owned'); ForceDirectories(Base);
  A:=TPath.Combine(Base,'first'); B:=TPath.Combine(Base,'unfinished'); Latest:=TPath.Combine(Base,'latest');
  Fixture(A,'01'); Fixture(B,'02',False); Fixture(Latest,'03');
  FileName:=TPath.Combine(A,'destination.hlc2'); Hash:=THashSHA2.GetHashStringFromFile(FileName);
  OtherHash:=THashSHA2.GetHashStringFromFile(TPath.Combine(Latest,'destination.hlc2'));
  Size:=0;
  for var Folder in TArray<string>.Create(A,B) do
    for var FilePath in TDirectory.GetFiles(Folder) do Inc(Size,TFile.GetSize(FilePath));
  Plan:=TCollectionBackupRemovalPlan.Create(TArray<string>.Create(A,B));
  try
    Require(Plan.Bytes=Size,'Cleanup size includes another folder or omits backup files');
    Rejected:=not Winapi.Windows.MoveFile(PChar(A),PChar(A+'-moved'));
    if not Rejected then
    begin
      Rejected:=False;
      try Plan.Execute; except on E: Exception do Rejected:=True; end;
      Require(Rejected and FileExists(TPath.Combine(A+'-moved','destination.hlc2')),
        'Renamed backup path was accepted or original files were deleted');
      if not Winapi.Windows.MoveFile(PChar(A+'-moved'),PChar(A)) then RaiseLastOSError;
      Writeln('TRACE backup rename allowed by filesystem, then rejected by identity check');
    end;
    Added:=TPath.Combine(A,'new-book.fb2'); TFile.WriteAllText(Added,'new foreign file',TEncoding.UTF8);
    Rejected:=False;
    try Plan.Execute; except on E: Exception do Rejected:=True; end;
    Require(Rejected and FileExists(FileName) and FileExists(TPath.Combine(B,'source-1.hlc2')),
      'Changed inventory deleted some files before rejecting the complete batch');
  finally Plan.Free; Plan:=nil; end;
  TFile.Delete(Added);
  Stream:=TFileStream.Create(TPath.Combine(B,'source-1.hlc2'),fmOpenRead or fmShareExclusive);
  try
    Rejected:=False;
    try Plan:=TCollectionBackupRemovalPlan.Create(TArray<string>.Create(A,B));
    except on E: Exception do Rejected:=True; end;
    Plan.Free; Plan:=nil;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(FileName)=Hash),
      'Locked backup allowed a partially prepared destructive batch');
  finally Stream.Free; end;
  Foreign:=TPath.Combine(Base,'foreign'); Fixture(Foreign,'04');
  TFile.WriteAllText(TPath.Combine(Foreign,'real-book.fb2'),'personal book must remain',TEncoding.UTF8);
  Reject(Foreign);
  Reject(TPath.Combine(Settings.AppPath,'backup-cleanup-linked'));
  Reject(TPath.Combine(Settings.AppPath,'backup-cleanup-linked\nested-backup'));
  Reject(TPath.Combine(Settings.AppPath,'backup-cleanup-file-link'));
  Require(TFile.ReadAllText(TPath.Combine(Settings.AppPath,'backup-cleanup-link-target\destination.hlc2'),TEncoding.UTF8)=
    'live target sentinel','Cleanup followed a backup link into another folder');
  Require(FileExists(TPath.Combine(Foreign,'real-book.fb2')),'Cleanup removed an unexpected personal file');
  Writeln('PASS backup cleanup pins exact folders, sizes flat files, rejects changed batches, locks, foreign files and directory/file reparse points');

  Dialog:=TfrmCollectionBackup.Create(nil); Reply:=TBackupRemovalResponder.Create; OldTheme:=MHLThemeDark;
  Reply.Timer:=TTimer.Create(nil); Reply.Timer.Enabled:=False; Reply.Timer.Interval:=10; Reply.Timer.OnTimer:=Reply.Tick;
  try
    Dialog.AddFolder(A); Dialog.AddFolder(B); Dialog.AddFolder(Latest);
    Dialog.Show; Application.ProcessMessages;
    List:=Dialog.FindComponent('lbCollectionBackups') as TListBox;
    Button:=Dialog.FindComponent('btnDeleteBackups') as TButton;
    Require(List.MultiSelect and Button.Enabled,'Backup cleanup does not allow selected multiple rows');
    SelectDay('02');
    Require(List.Items[List.ItemIndex].Contains('неполный набор'),'Unfinished backup is hidden from cleanup');
    // External deletion must be reflected without constructing a new dialog.
    Plan:=TCollectionBackupRemovalPlan.Create(TArray<string>.Create(B));
    try Plan.Execute; finally Plan.Free; Plan:=nil; end;
    (Dialog.FindComponent('btnRefreshBackups') as TButton).Click;
    for var Text in List.Items do Require(not Text.Contains('02.10.2026'),'Refresh kept a deleted backup row');
    Fixture(B,'02',False); Dialog.AddFolder(B);
    SelectDay('01');
    for var I:=0 to List.Items.Count-1 do if List.Items[I].Contains('02.10.2026') then List.ItemIndex:=I;
    List.OnClick(List);
    Require((List.SelCount=1) and string((Dialog.FindComponent('mmBackupPreview') as TMemo).Text).Contains(A),
      'Backup details follow unselected caret instead of the single selected row');
    for var I:=0 to List.Items.Count-1 do if List.Items[I].Contains('02.10.2026') then List.Selected[I]:=True;
    List.OnClick(List); Require((List.SelCount=2) and not (Dialog.FindComponent('btnCheckBackup') as TButton).Enabled,
      'Multi-selection lost its second row or enabled ambiguous restoration');
    Reply.Path:=A; Reply.SecondPath:=B; Reply.Accept:=False; Reply.Timer.Enabled:=True;
    Button.Click;
    Require(Reply.Seen and Reply.SafeDefault and Reply.FullPaths and FileExists(TPath.Combine(B,'source-1.hlc2')) and (List.SelCount=2) and (THashSHA2.GetHashStringFromFile(FileName)=Hash),
      'Cleanup cancellation, default choice or full-path review is unsafe');
    Reply.Seen:=False; Reply.Accept:=True; Reply.Timer.Enabled:=True;
    Button.Click;
    Require(Reply.Seen and not DirectoryExists(A) and not DirectoryExists(B) and
      (THashSHA2.GetHashStringFromFile(TPath.Combine(Latest,'destination.hlc2'))=OtherHash),
      'Confirmed cleanup failed to delete exactly its selected backup');
    for var Dark in [False,True] do
    begin
      SetMHLTheme(Dark);
      for var DPI in [96,144,192] do
      begin
        Dialog.ScaleForPPI(DPI); Dialog.ClientWidth:=MulDiv(684,DPI,96); Application.ProcessMessages;
        var Refresh:=Dialog.FindComponent('btnRefreshBackups') as TButton;
        var Check:=Dialog.FindComponent('btnCheckBackup') as TButton;
        Require((Check.Left+Check.Width<Refresh.Left) and (Refresh.Left+Refresh.Width<Button.Left) and
          (Button.Left+Button.Width<=Dialog.ClientWidth), 'Backup controls overlap at minimum width or scaled DPI');
      end;
    end;
  finally Reply.Timer.Free; Reply.Free; Dialog.Free; SetMHLTheme(OldTheme); end;
  Require(FileExists(TPath.Combine(Latest,'destination.hlc2')) and FileExists(TPath.Combine(Foreign,'real-book.fb2')),
    'Backup UI changed an unselected snapshot or personal file');
  Writeln('PASS backup cleanup refreshes missing rows, shows unfinished copies, defaults to cancel and deletes only confirmed selection at both themes and 96/144/192 DPI');
end;
