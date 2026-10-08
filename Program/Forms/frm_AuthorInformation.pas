unit frm_AuthorInformation;

interface

uses System.Classes, System.SysUtils, Vcl.Forms, Vcl.ComCtrls, Vcl.StdCtrls, Vcl.ExtCtrls,
  unit_AuthorInfo, unit_BookGallery;

type
  TAuthorInformationWorker = class(TThread)
  private
    FFolder, FName: string;
  protected
    procedure Execute; override;
  public
    Information: TAuthorInformation;
    ErrorText: string;
    constructor Create(const Folder, Name: string);
  end;

  TAuthorInformationPanel = class(TPanel)
  private
    FWorker: TAuthorInformationWorker;
    FText: TRichEdit;
    FStatus: TLabel;
    FPhotos: TBookGallery;
    FAuthors: TComboBox;
    FRoot, FFolder: string;
    FActivated, FClosing: Boolean;
    FSaveFolder: TProc<string>;
    procedure WorkerFinished(Sender: TObject);
    procedure SelectAuthor(Sender: TObject);
    procedure ChooseFolder(Sender: TObject);
    procedure StopWorker;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Configure(const Root, Folder: string; const Names: TArray<string>;
      const SaveFolder: TProc<string>);
    procedure Activate;
    property Photographs: TBookGallery read FPhotos;
    property Text: TRichEdit read FText;
    property Status: TLabel read FStatus;
  end;

implementation

uses System.IOUtils, Vcl.Controls, Vcl.Dialogs,
  unit_UpdateNotes, unit_Settings, dm_user;

constructor TAuthorInformationWorker.Create(const Folder, Name: string);
begin
  inherited Create(True); FreeOnTerminate := False; FFolder := Folder; FName := Name;
end;

procedure TAuthorInformationWorker.Execute;
begin
  try
    Information := ReadAuthorInformation(FFolder, FName,
      function: Boolean begin Result := Terminated; end);
  except on E: Exception do ErrorText := E.Message; end;
end;

constructor TAuthorInformationPanel.Create(AOwner: TComponent);
var Bar: TPanel; FolderButton: TButton;
begin
  inherited;
  BevelOuter := bvNone; Font.Name := 'Segoe UI'; Font.Size := 9;
  DoubleBuffered := True;
  Bar := TPanel.Create(Self); Bar.Parent := Self; Bar.Align := alTop;
  Bar.Height := 36; Bar.BevelOuter := bvNone;
  FolderButton := TButton.Create(Self); FolderButton.Parent := Bar;
  FolderButton.Align := alRight; FolderButton.Width := 160;
  FolderButton.AlignWithMargins := True; FolderButton.Caption := 'Папка сведений...';
  FolderButton.OnClick := ChooseFolder;
  FAuthors := TComboBox.Create(Self); FAuthors.Parent := Bar;
  FAuthors.Align := alClient; FAuthors.AlignWithMargins := True;
  FAuthors.Style := csDropDownList; FAuthors.OnChange := SelectAuthor;
  FStatus := TLabel.Create(Self); FStatus.Parent := Self; FStatus.AutoSize := False;
  FStatus.Top := 36; FStatus.Align := alTop; FStatus.Height := 42; FStatus.WordWrap := True;
  FStatus.AlignWithMargins := True; FStatus.Margins.Left := 12; FStatus.ShowAccelChar := False;
  FStatus.Caption := 'Откройте вкладку, чтобы прочитать сведения из архивов FLibrary.';
  FPhotos := TBookGallery.Create(Self); FPhotos.Parent := Self; FPhotos.Align := alBottom;
  FPhotos.Title := 'Фотографии'; FPhotos.Visible := False;
  FPhotos.PreviewSettingsFile := TPath.Combine(Settings.DataPath, 'author-photo-window.ini');
  FText := TRichEdit.Create(Self); FText.Parent := Self; FText.Align := alClient;
  FText.ReadOnly := True; FText.WordWrap := True; FText.ScrollBars := ssVertical;
  FText.AlignWithMargins := True; FText.Margins.Left := 12; FText.Margins.Right := 12;
end;

procedure TAuthorInformationPanel.StopWorker;
begin
  if not Assigned(FWorker) then Exit;
  FWorker.OnTerminate := nil; FWorker.Terminate; FWorker.WaitFor;
  FreeAndNil(FWorker);
end;

destructor TAuthorInformationPanel.Destroy;
begin
  FClosing := True; StopWorker; inherited;
end;

procedure TAuthorInformationPanel.Configure(const Root, Folder: string;
  const Names: TArray<string>; const SaveFolder: TProc<string>);
var Name: string;
begin
  StopWorker; FRoot := Root; FFolder := Folder; FSaveFolder := SaveFolder;
  FActivated := False; FPhotos.Clear; FText.Clear; FAuthors.Items.Clear;
  for Name in Names do
    if FAuthors.Items.IndexOf(Name) < 0 then FAuthors.Items.Add(Name);
  if FAuthors.Items.Count > 0 then FAuthors.ItemIndex := 0;
end;

procedure TAuthorInformationPanel.Activate;
begin
  if FActivated then Exit;
  FActivated := True; SelectAuthor(nil);
end;

procedure TAuthorInformationPanel.SelectAuthor(Sender: TObject);
var Folder: string;
begin
  if not FActivated then Exit;
  StopWorker; FPhotos.Clear; FText.Clear;
  if FAuthors.ItemIndex < 0 then
  begin FStatus.Caption := 'В книге не указан автор.'; Exit; end;
  try Folder := FindAuthorInfoFolder(FRoot, FFolder);
  except on E: Exception do
    begin FStatus.Caption := 'Не удалось открыть папку: ' + E.Message; Exit; end;
  end;
  if Folder = '' then
  begin
    FStatus.Caption := 'В INPX нет биографий. Если у вас есть архивы FLibrary, ' +
      'выберите папку дополнительных сведений (authors/*.7z).'; Exit;
  end;
  FStatus.Caption := 'Загрузка сведений об авторе...';
  FWorker := TAuthorInformationWorker.Create(Folder, FAuthors.Text);
  FWorker.OnTerminate := WorkerFinished; FWorker.Start;
end;

procedure TAuthorInformationPanel.ChooseFolder(Sender: TObject);
var Dialog: TFileOpenDialog; Folder: string;
begin
  Dialog := TFileOpenDialog.Create(Self);
  try
    Dialog.Title := 'Папка дополнительных сведений FLibrary';
    Dialog.Options := [fdoPickFolders, fdoPathMustExist];
    if DirectoryExists(FFolder) then Dialog.DefaultFolder := FFolder;
    if not Dialog.Execute then Exit;
    Folder := FindAuthorInfoFolder('', Dialog.FileName);
    if Folder = '' then
    begin FStatus.Caption := 'В выбранной папке нет authors/*.7z или *.7z.'; Exit; end;
    FFolder := Folder;
    if Assigned(FSaveFolder) then FSaveFolder(Folder);
    FActivated := True; SelectAuthor(nil);
  finally Dialog.Free; end;
end;

procedure TAuthorInformationPanel.WorkerFinished(Sender: TObject);
var Info: TAuthorInformation; ArchiveFile, Hash: string;
begin
  if FClosing then Exit;
  if FWorker.ErrorText <> '' then
  begin FStatus.Caption := 'Не удалось прочитать сведения: ' + FWorker.ErrorText; Exit; end;
  Info := FWorker.Information;
  if not Info.Found then
  begin FStatus.Caption := 'В дополнительных архивах нет сведений для этого имени автора.'; Exit; end;
  FStatus.Caption := 'Источник: локальные архивы FLibrary. Текст можно выделить и скопировать.';
  LoadUpdateNotes(FText, SQLiteNotesToMarkdown(Info.HTML));
  if Info.HTML.Trim = '' then FText.Lines.Text := 'Описание автора отсутствует.';
  FPhotos.Visible := Info.PhotoArchive <> '';
  if FPhotos.Visible then
  begin
    ArchiveFile := Info.PhotoArchive; Hash := Info.Hash;
    FPhotos.SetBook(Hash, '.epub',
      function: TStream begin Result := AuthorPhotographs(ArchiveFile, Hash); end);
  end;
end;

end.
