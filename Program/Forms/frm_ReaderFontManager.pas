unit frm_ReaderFontManager;

interface

uses Vcl.Forms;

procedure ManageReaderFonts(Owner: TCustomForm; const SettingsFile: string;
  var Selected: string);

implementation

uses Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Dialogs, Vcl.Graphics,
  unit_ReaderFonts, unit_ReaderFontDownloads, unit_ReaderPalette;

type
  TReaderWindowsFontDialog = class(TForm)
  private
    FSearch: TEdit;
    FList: TListBox;
    FPreview: TLabel;
    FAdd: TButton;
    FNames: TStringList;
    procedure Filter(Sender: TObject);
    procedure SelectionChanged(Sender: TObject);
    procedure Accept(Sender: TObject);
  public
    constructor CreateFor(Owner: TCustomForm);
    destructor Destroy; override;
    function Chosen: string;
  end;

  TReaderFontManager = class(TForm)
  private
    FSettingsFile, FSelected: string;
    FList: TListView;
    FPreview, FStatus: TLabel;
    FRestore, FRemove, FPack: TButton;
    FWaiting: TStringList;
    FCookie: Cardinal;
    procedure Refresh(const Family: string);
    procedure SelectionChanged(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure WindowsClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure RestoreClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure PackClick(Sender: TObject);
    procedure QueueFont(const Family: string);
    procedure WMFontsReady(var Message: TMessage); message WM_READER_FONTS_READY;
    function Family: string;
    procedure ReportError(E: Exception);
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
  public
    constructor CreateFor(Owner: TCustomForm; const SettingsFile, Selected: string);
    destructor Destroy; override;
    property SelectedFamily: string read FSelected;
  end;

procedure ApplyOwnerPalette(Dialog, Owner: TCustomForm);
var RGBColor: Cardinal;
begin
  RGBColor:=ColorToRGB(Owner.Color);
  ApplyReaderPalette(Dialog,Owner.Color,Owner.Font.Color,
    Integer(GetRValue(RGBColor))+GetGValue(RGBColor)+GetBValue(RGBColor)<384);
end;

function AddButton(Form: TCustomForm; const Name, Caption: string;
  X,Y,Width: Integer; Click: TNotifyEvent): TButton;
begin
  Result:=TReaderPaletteButton.Create(Form); Result.Parent:=Form;
  Result.Name:=Name; Result.Caption:=Caption; Result.SetBounds(X,Y,Width,28);
  Result.OnClick:=Click;
end;

constructor TReaderWindowsFontDialog.CreateFor(Owner: TCustomForm);
begin
  inherited CreateNew(Owner);
  Name:='ReaderWindowsFontsDialog'; Caption:='Добавить шрифт Windows';
  PopupMode:=pmExplicit; PopupParent:=Owner; Position:=poOwnerFormCenter;
  BorderStyle:=bsDialog; ClientWidth:=460; ClientHeight:=422; Font.Assign(Owner.Font);
  FNames:=TStringList.Create; FNames.Sorted:=True; FNames.Duplicates:=dupIgnore;
  for var Family in Screen.Fonts do
    if (Family<>'') and not Family.StartsWith('@') then FNames.Add(Family);
  FSearch:=TEdit.Create(Self); FSearch.Parent:=Self; FSearch.Name:='ReaderWindowsFontSearch';
  FSearch.Text:='';
  FSearch.SetBounds(16,16,428,26); FSearch.TextHint:='Найти шрифт по названию'; FSearch.OnChange:=Filter;
  FList:=TListBox.Create(Self); FList.Parent:=Self; FList.Name:='ReaderWindowsFontResults';
  FList.SetBounds(16,50,428,242); FList.OnClick:=SelectionChanged; FList.OnDblClick:=Accept;
  FPreview:=TLabel.Create(Self); FPreview.Parent:=Self; FPreview.AutoSize:=False;
  FPreview.SetBounds(16,304,428,64); FPreview.WordWrap:=True;
  FAdd:=AddButton(Self,'ReaderWindowsFontAdd','Добавить',248,378,94,Accept); FAdd.Default:=True;
  with AddButton(Self,'ReaderWindowsFontCancel','Отмена',350,378,94,nil) do
  begin ModalResult:=mrCancel; Cancel:=True; end;
  Filter(nil); ActiveControl:=FSearch; ApplyOwnerPalette(Self,Owner);
end;

destructor TReaderWindowsFontDialog.Destroy;
begin FNames.Free; inherited; end;

function TReaderWindowsFontDialog.Chosen: string;
begin
  Result:='';
  if FList.ItemIndex>=0 then Result:=FList.Items[FList.ItemIndex];
end;

procedure TReaderWindowsFontDialog.Filter(Sender: TObject);
var Query: string;
begin
  Query:=LowerCase(Trim(FSearch.Text));
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for var Name in FNames do
      if (Query='') or (Pos(Query,LowerCase(Name))>0) then FList.Items.Add(Name);
    if FList.Count>0 then FList.ItemIndex:=0;
  finally FList.Items.EndUpdate; end;
  SelectionChanged(nil);
end;

procedure TReaderWindowsFontDialog.SelectionChanged(Sender: TObject);
begin
  FAdd.Enabled:=Chosen<>'';
  if Chosen='' then FPreview.Caption:='Ничего не найдено.'
  else
  begin
    FPreview.Font.Name:=Chosen; FPreview.Font.Size:=15;
    FPreview.Caption:='Съешь ещё этих мягких булок.'+sLineBreak+'The quick brown fox jumps over the lazy dog.';
  end;
end;

procedure TReaderWindowsFontDialog.Accept(Sender: TObject);
begin if Chosen<>'' then ModalResult:=mrOk; end;

constructor TReaderFontManager.CreateFor(Owner: TCustomForm; const SettingsFile, Selected: string);
var Info: TLabel;
begin
  inherited CreateNew(Owner);
  Name:='ReaderFontManager'; Caption:='Шрифты читалки';
  PopupMode:=pmExplicit; PopupParent:=Owner; Position:=poOwnerFormCenter;
  BorderStyle:=bsDialog; ClientWidth:=580; ClientHeight:=454; Font.Assign(Owner.Font);
  FSettingsFile:=SettingsFile; FSelected:=Selected; FWaiting:=TStringList.Create;
  Info:=TLabel.Create(Self); Info.Parent:=Self; Info.AutoSize:=False; Info.WordWrap:=True;
  Info.SetBounds(16,14,548,36);
  Info.Caption:='Добавьте нужные шрифты в читалку. Убранные можно вернуть.';
  AddButton(Self,'ReaderAddWindowsFont','Из Windows…',16,54,160,WindowsClick);
  AddButton(Self,'ReaderImportFontFile','Из файла TTF / OTF…',184,54,180,ImportClick);
  FPack:=AddButton(Self,'ReaderDownloadFontPack','Скачать набор…',372,54,192,PackClick);
  FPack.Hint:='PT Serif, PT Sans, Noto Serif и Noto Sans: кириллица и латиница, по четыре начертания.';
  FPack.ShowHint:=True;
  FList:=TListView.Create(Self); FList.Parent:=Self; FList.Name:='ReaderFontLibrary';
  FList.SetBounds(16,94,548,194); FList.ViewStyle:=vsReport;
  FList.ReadOnly:=True; FList.RowSelect:=True; FList.HideSelection:=False;
  FList.Columns.Add.Caption:='Шрифт'; FList.Columns[0].Width:=210;
  FList.Columns.Add.Caption:='Доступность'; FList.Columns[1].Width:=140;
  FList.Columns.Add.Caption:='Источник'; FList.Columns[2].Width:=170;
  FList.OnSelectItem:=SelectionChanged;
  FPreview:=TLabel.Create(Self); FPreview.Parent:=Self; FPreview.AutoSize:=False;
  FPreview.SetBounds(16,300,548,60); FPreview.WordWrap:=True;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Self; FStatus.Name:='ReaderFontManagerStatus';
  FStatus.AutoSize:=False; FStatus.WordWrap:=True; FStatus.SetBounds(16,366,548,42);
  FRestore:=AddButton(Self,'ReaderRestoreFont','Вернуть в список',16,410,176,RestoreClick);
  FRemove:=AddButton(Self,'ReaderRemoveFont','Убрать из списка',200,410,176,RemoveClick);
  with AddButton(Self,'ReaderFontManagerClose','Готово',450,410,114,nil) do
  begin ModalResult:=mrOk; Default:=True; Cancel:=True; end;
  Refresh(Selected); ApplyOwnerPalette(Self,Owner);
end;

destructor TReaderFontManager.Destroy;
begin
  if Assigned(FList) then FList.OnSelectItem:=nil;
  FWaiting.Free; inherited;
end;

procedure TReaderFontManager.CreateWnd;
begin inherited; FCookie:=RegisterReaderFontWindow(Handle); end;

procedure TReaderFontManager.DestroyWnd;
begin UnregisterReaderFontWindow(Handle); FCookie:=0; inherited; end;

function TReaderFontManager.Family: string;
begin
  Result:=''; if Assigned(FList.Selected) then Result:=FList.Selected.Caption;
end;

procedure TReaderFontManager.Refresh(const Family: string);
var Names: TStringList; Item: TListItem; Ready, Listed, Missing, NeedDownload, Pending: Boolean;
begin
  Names:=TStringList.Create;
  try
    ReaderFontKnownNames(FSettingsFile,Names);
    FList.Items.BeginUpdate;
    try
      FList.Items.Clear;
      for var Name in Names do
      begin
        Item:=FList.Items.Add; Item.Caption:=Name;
        Listed:=ReaderFontIsListed(FSettingsFile,Name);
        Ready:=Screen.Fonts.IndexOf(Name)>=0;
        if ReaderFontRequestPending(Name) then Item.SubItems.Add('Загружается…')
        else if Listed and Ready then Item.SubItems.Add('В списке чтения')
        else if Ready or ReaderFontFamilyCached(Name) then Item.SubItems.Add('Можно вернуть')
        else if ReaderFontDownloadBytes(Name)>0 then Item.SubItems.Add('Нужно скачать')
        else Item.SubItems.Add('Недоступен');
        Item.SubItems.Add(ReaderFontSource(FSettingsFile,Name));
        if SameText(Name,Family) then begin Item.Selected:=True; Item.Focused:=True; end;
      end;
      if not Assigned(FList.Selected) and (FList.Items.Count>0) then FList.Items[0].Selected:=True;
    finally FList.Items.EndUpdate; end;
    Missing:=False; NeedDownload:=False; Pending:=False;
    for var Name in ReaderFontPack do
    begin
      Ready:=(Screen.Fonts.IndexOf(Name)>=0) or ReaderFontFamilyCached(Name);
      Missing:=Missing or not Ready or not ReaderFontIsListed(FSettingsFile,Name);
      NeedDownload:=NeedDownload or not Ready;
      Pending:=Pending or ReaderFontRequestPending(Name);
    end;
    FPack.Enabled:=Missing and not Pending;
    if Pending then FPack.Caption:='Загрузка…'
    else if not Missing then FPack.Caption:='Набор добавлен'
    else if NeedDownload then FPack.Caption:='Скачать набор…'
    else FPack.Caption:='Вернуть весь набор';
    SelectionChanged(nil,FList.Selected,True);
  finally Names.Free; end;
end;

procedure TReaderFontManager.SelectionChanged(Sender: TObject; Item: TListItem; Selected: Boolean);
var Name: string; Ready, Listed, Pending: Boolean;
begin
  if not Assigned(FRemove) or not Assigned(FRestore) then Exit;
  Name:=Family; Ready:=(Name<>'') and (Screen.Fonts.IndexOf(Name)>=0);
  Listed:=(Name<>'') and ReaderFontIsListed(FSettingsFile,Name);
  Pending:=(Name<>'') and ReaderFontRequestPending(Name);
  if Listed and Ready and Selected then FSelected:=Name;
  FRemove.Enabled:=Listed and not SameText(Name,DefaultReaderFont(FSettingsFile)) and not Pending;
  FRestore.Enabled:=(Name<>'') and not Pending and (not Listed or not Ready) and
    (Ready or ReaderFontFamilyCached(Name) or (ReaderFontDownloadBytes(Name)>0));
  if Ready or ReaderFontFamilyCached(Name) then FRestore.Caption:='Вернуть в список'
  else FRestore.Caption:='Скачать и добавить';
  if Ready then
  begin
    FPreview.Font.Name:=Name; FPreview.Font.Size:=16;
    FPreview.Caption:='Съешь ещё этих мягких булок. The quick brown fox jumps over the lazy dog.';
  end
  else FPreview.Caption:='После загрузки здесь появится образец шрифта.';
  if SameText(Name,DefaultReaderFont(FSettingsFile)) then FStatus.Caption:='Шрифт по умолчанию всегда остаётся в читалке.'
  else FStatus.Caption:='«Убрать» скрывает гарнитуру в читалке. «Вернуть» добавляет её обратно без повторной загрузки, если она доступна.';
end;

procedure TReaderFontManager.ReportError(E: Exception);
begin FStatus.Caption:=E.Message; end;

procedure TReaderFontManager.WindowsClick(Sender: TObject);
var Dialog: TReaderWindowsFontDialog;
begin
  Dialog:=TReaderWindowsFontDialog.CreateFor(Self);
  try
    if Dialog.ShowModal<>mrOk then Exit;
    try
      AddReaderWindowsFont(FSettingsFile,Dialog.Chosen);
      FSelected:=Dialog.Chosen; Refresh(FSelected);
    except on E: Exception do ReportError(E); end;
  finally Dialog.Free; end;
end;

procedure TReaderFontManager.ImportClick(Sender: TObject);
var Picker: TFileOpenDialog; Before, After: TStringList;
begin
  Picker:=TFileOpenDialog.Create(Self); Before:=TStringList.Create; After:=TStringList.Create;
  try
    Picker.Title:='Добавить свой шрифт';
    Picker.Options:=Picker.Options+[fdoFileMustExist,fdoPathMustExist,fdoForceFileSystem];
    with Picker.FileTypes.Add do begin DisplayName:='Шрифты TrueType и OpenType'; FileMask:='*.ttf;*.otf'; end;
    if not Picker.Execute(Handle) then Exit;
    try
      ReaderFontLibraryNames(FSettingsFile,Before);
      ImportReaderProfileFont(FSettingsFile,Picker.FileName);
      ReaderFontLibraryNames(FSettingsFile,After);
      for var Name in After do if Before.IndexOf(Name)<0 then begin FSelected:=Name; Break; end;
      Refresh(FSelected);
    except on E: Exception do ReportError(E); end;
  finally After.Free; Before.Free; Picker.Free; end;
end;

procedure TReaderFontManager.QueueFont(const Family: string);
begin
  if EnsureReaderFont(Family) then
  begin AddReaderWindowsFont(FSettingsFile,Family); Exit; end;
  if ReaderFontDownloadBytes(Family)<=0 then
    raise EReadError.Create('Этот шрифт недоступен для загрузки. Добавьте его из Windows или из файла.');
  if FWaiting.IndexOf(Family)<0 then FWaiting.Add(Family);
  RequestReaderLibraryFont(FSettingsFile,Family);
end;

procedure TReaderFontManager.RestoreClick(Sender: TObject);
var Selected: string;
begin
  Selected:=Family; if Selected='' then Exit;
  try
    QueueFont(Selected); FSelected:=Selected; Refresh(Selected);
    if FWaiting.IndexOf(Selected)>=0 then FStatus.Caption:='Шрифт загружается. Окно можно закрыть.';
  except on E: Exception do ReportError(E); end;
end;

procedure TReaderFontManager.RemoveClick(Sender: TObject);
var Selected: string;
begin
  Selected:=Family; if Selected='' then Exit;
  try
    RemoveReaderFont(FSettingsFile,Selected);
    if SameText(FSelected,Selected) then FSelected:=DefaultReaderFont(FSettingsFile);
    Refresh(Selected);
  except on E: Exception do ReportError(E); end;
end;

procedure TReaderFontManager.PackClick(Sender: TObject);
var Bytes: Int64;
begin
  Bytes:=0;
  for var Name in ReaderFontPack do
    if not EnsureReaderFont(Name) then Inc(Bytes,ReaderFontDownloadBytes(Name));
  if (Bytes>0) and (MessageDlg(Format('Добавить набор PT Serif, PT Sans, Noto Serif и Noto Sans?'+sLineBreak+
    'Кириллица и латиница, четыре начертания каждой гарнитуры. Загрузка: до %.1f МБ.',[Bytes/1000000]),
    mtConfirmation,[mbYes,mbNo],0)<>mrYes) then Exit;
  try
    for var Name in ReaderFontPack do QueueFont(Name);
    Refresh(Family);
    if FWaiting.Count>0 then FStatus.Caption:='Загружаются только недостающие гарнитуры. Окно можно закрыть.';
  except on E: Exception do ReportError(E); end;
end;

procedure TReaderFontManager.WMFontsReady(var Message: TMessage);
var Name, Failed: string;
begin
  if Message.WParam<>FCookie then Exit;
  Failed:='';
  for var I:=FWaiting.Count-1 downto 0 do
  begin
    Name:=FWaiting[I]; if ReaderFontRequestPending(Name) then Continue;
    try
      if EnsureReaderFont(Name) then AddReaderWindowsFont(FSettingsFile,Name)
      else Failed:=Name;
    except on E: Exception do Failed:=Name; end;
    FWaiting.Delete(I);
  end;
  Refresh(Family);
  if Failed<>'' then FStatus.Caption:='Не удалось загрузить '+Failed+'. Проверьте подключение и повторите загрузку.';
end;

procedure ManageReaderFonts(Owner: TCustomForm; const SettingsFile: string; var Selected: string);
var Dialog: TReaderFontManager;
begin
  Dialog:=TReaderFontManager.CreateFor(Owner,SettingsFile,Selected);
  try
    Dialog.ShowModal;
    Selected:=Dialog.SelectedFamily;
    if not ReaderFontIsListed(SettingsFile,Selected) or (Screen.Fonts.IndexOf(Selected)<0) then
      Selected:=AvailableReaderFont(DefaultReaderFont(SettingsFile));
  finally Dialog.Free; end;
end;

end.
