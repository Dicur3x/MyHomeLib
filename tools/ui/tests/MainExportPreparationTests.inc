// Real Main export preparation, with no book read or external tool execution.
type
  EMainExportPreparationProbe = class(Exception);
  TMainExportPreparationProbe = class
    Seen: Boolean;
    procedure ModalBegin(Sender: TObject);
  end;

procedure TMainExportPreparationProbe.ModalBegin(Sender: TObject);
begin
  for var I := 0 to Screen.FormCount - 1 do
    if Screen.Forms[I] is TExportToDeviceProgressForm then
    begin
      Seen := True;
      raise EMainExportPreparationProbe.Create('Isolated failure before export worker Start');
    end;
end;

procedure TestMainExportPreparation(Interactive: Boolean);
var
  Node: PVirtualNode;
  Row: PBookRecord;
  Item: TMenuItem;
  Probe: TMainExportPreparationProbe;
  SavedModalBegin: TNotifyEvent;
  SavedDevice, SavedTemplate: string;
  SavedPrompt, SavedChecked: Boolean;
  ScriptIndex: Integer;
  FailureObserved: Boolean;
  CheckedKeys: TArray<Integer>;

  procedure MarkAndSnapshot;
  begin
    CheckedKeys := nil;
    Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Row := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Row) and (Row^.NodeType = ntBookInfo) and
        not frmMain.tvBooksA.IsEffectivelyFiltered[Node] then
      begin
        frmMain.tvBooksA.CheckState[Node] := csCheckedNormal;
        CheckedKeys := CheckedKeys + [Row^.BookKey.BookID];
      end;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
    Require(Length(CheckedKeys) >= 2, 'Export preparation fixture requires a multi-book selection');
  end;

  procedure RequireMarks;
  var Found: Integer;
  begin
    Found := 0;
    Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Row := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Row) and (Row^.NodeType = ntBookInfo) then
        for var Key in CheckedKeys do
          if Row^.BookKey.BookID = Key then
          begin
            Require(frmMain.tvBooksA.CheckState[Node] = csCheckedNormal,
              'Canceled destination selection removed a marked book');
            Inc(Found);
          end;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
    Require(Found = Length(CheckedKeys), 'Canceled destination selection changed visible books');
  end;

begin
  ShowPage(PAGE_AUTHORS);
  SavedDevice := Settings.DeviceDir;
  SavedTemplate := Settings.FolderTemplate;
  SavedPrompt := Settings.PromptDevicePath;
  SavedChecked := Settings.SelectedIsChecked;
  SavedModalBegin := Application.OnModalBegin;
  Item := TMenuItem.Create(nil);
  Probe := TMainExportPreparationProbe.Create;
  ScriptIndex := Settings.Scripts.Count;
  try
    Settings.DeviceDir := Settings.AppPath + 'Назначение экспорта ё';
    ForceDirectories(Settings.DeviceDir);
    Settings.FolderTemplate := 'Сохранённый шаблон ё\%a';
    Settings.SelectedIsChecked := False;
    MarkAndSnapshot;
    if Interactive then
    begin
      frmMain.Show;
      Application.ProcessMessages;
      for var Tag in TArray<Integer>.Create(799, 850) do
      begin
        Settings.PromptDevicePath := True;
        Item.Tag := Tag;
        Writeln('VISUAL export preparation: cancel destination, tag=', Tag);
        Flush(Output);
        frmMain.SendToDeviceExecute(Item);
        RequireMarks;
        Require(Settings.FolderTemplate = 'Сохранённый шаблон ё\%a',
          'Cancel changed the saved export folder template');
        Writeln('PASS Main export destination cancel preserves marked books tag=', Tag);
        Flush(Output);
      end;
    end
    else
    begin
      Settings.PromptDevicePath := False;
      Settings.Scripts.Add('Isolated NFT preparation', '%COPY%', '%NFT%');
      Item.Tag := 901 + ScriptIndex;
      Application.OnModalBegin := Probe.ModalBegin;
      FailureObserved := False;
      try
        frmMain.SendToDeviceExecute(Item);
      except
        on E: EMainExportPreparationProbe do FailureObserved := True;
      end;
      Require(Probe.Seen and FailureObserved, 'Export preparation did not reach its real failure before worker Start');
      Require(Settings.FolderTemplate = 'Сохранённый шаблон ё\%a',
        'Failed export permanently changed the saved folder template');
      Writeln('PASS Main failed NFT export restores the saved folder template before worker Start');
    end;
  finally
    Application.OnModalBegin := SavedModalBegin;
    while Settings.Scripts.Count > ScriptIndex do Settings.Scripts.Delete(Settings.Scripts.Count - 1);
    Settings.DeviceDir := SavedDevice;
    Settings.FolderTemplate := SavedTemplate;
    Settings.PromptDevicePath := SavedPrompt;
    Settings.SelectedIsChecked := SavedChecked;
    Probe.Free;
    Item.Free;
  end;
end;
