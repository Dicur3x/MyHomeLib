unit frm_ReaderFontManager;

interface

uses Vcl.Forms;

procedure ManageReaderFonts(Owner: TCustomForm; const SettingsFile: string;
  var Selected: string);

implementation

uses Winapi.Windows, Winapi.Messages, Winapi.CommCtrl, System.Types, System.Math, System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Dialogs, Vcl.Graphics, Vcl.ExtCtrls,
  unit_ReaderFonts, unit_ReaderFontDownloads, unit_ReaderPalette;

type
  TReaderFontListView = class(TListView)
  private
    procedure WMNotify(var Message: TWMNotify); message WM_NOTIFY;
  end;

  TReaderWindowsFontDialog = class(TForm)
  private
    FSearch: TEdit;
    FList: TListBox;
    FPreview: TLabel;
    FPreviewArea: TScrollBox;
    FAdd: TButton;
    FNames: TStringList;
    procedure Filter(Sender: TObject);
    procedure SelectionChanged(Sender: TObject);
    procedure Accept(Sender: TObject);
    procedure PreviewResize(Sender: TObject);
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
    FPreviewArea: TScrollBox;
    FRestore, FRemove, FPack: TButton;
    FWaiting: TStringList;
    FCookie: Cardinal;
    procedure Refresh(const Family: string);
    procedure PreviewResize(Sender: TObject);
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

procedure TReaderFontListView.WMNotify(var Message: TWMNotify);
var Draw: PNMCustomDraw; Bounds: TRect; DCState: Integer; Brush: HBRUSH;
begin
  if not (csDestroying in ComponentState) and (Message.NMHdr <> nil) and (Message.NMHdr.hwndFrom = ListView_GetHeader(Handle)) and
    (Message.NMHdr.code = NM_CUSTOMDRAW) then
  begin
    Draw := PNMCustomDraw(Message.NMHdr);
    case Draw.dwDrawStage of
      CDDS_PREPAINT:
        begin Message.Result := CDRF_NOTIFYITEMDRAW or CDRF_NOTIFYPOSTPAINT; Exit; end;
      CDDS_ITEMPREPAINT:
        if Draw.dwItemSpec < NativeUInt(Columns.Count) then
        begin
          DCState := SaveDC(Draw.hdc);
          Brush := CreateSolidBrush(ColorToRGB(Color));
          try
            Bounds := Draw.rc; FillRect(Draw.hdc,Bounds,Brush);
            SelectObject(Draw.hdc,Font.Handle); SetTextColor(Draw.hdc,ColorToRGB(Font.Color));
            SetBkMode(Draw.hdc,TRANSPARENT);
            InflateRect(Bounds,-MulDiv(6,CurrentPPI,96),0);
            var Caption := Columns[Integer(Draw.dwItemSpec)].Caption;
            DrawText(Draw.hdc,PChar(Caption),Length(Caption),Bounds,
              DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS or DT_NOPREFIX);
          finally DeleteObject(Brush); RestoreDC(Draw.hdc,DCState); end;
          Message.Result := CDRF_SKIPDEFAULT; Exit;
        end;
      CDDS_POSTPAINT:
        begin
          Winapi.Windows.GetClientRect(Message.NMHdr.hwndFrom,Bounds);
          if Columns.Count > 0 then
          begin
            var Last: TRect;
            if Header_GetItemRect(Message.NMHdr.hwndFrom,Columns.Count-1,@Last) then
              Bounds.Left := Last.Right
            else Bounds.Left := Bounds.Right;
          end;
          Brush := CreateSolidBrush(ColorToRGB(Color));
          try FillRect(Draw.hdc,Bounds,Brush); finally DeleteObject(Brush); end;
          Message.Result := CDRF_DODEFAULT; Exit;
        end;
    end;
  end;
  inherited;
end;

procedure FitFontPreview(Area: TScrollBox; Preview: TLabel);
var Bounds: TRect;
begin
  if not Assigned(Preview) then Exit;
  var DC := GetDC(Area.Handle);
  var DCState := SaveDC(DC);
  SelectObject(DC,Preview.Font.Handle);
  try
    Bounds := Rect(0,0,Max(32,Area.ClientWidth-MulDiv(24,Area.CurrentPPI,96)),0);
    DrawText(DC,PChar(Preview.Caption),Length(Preview.Caption),Bounds,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Preview.SetBounds(MulDiv(4,Area.CurrentPPI,96),0,Bounds.Width,
      Bounds.Height+MulDiv(6,Area.CurrentPPI,96));
  finally RestoreDC(DC,DCState); ReleaseDC(Area.Handle,DC); end;
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
  BorderStyle:=bsSizeable; AutoScroll:=False;
  ClientWidth:=460; ClientHeight:=422; Font.Assign(Owner.Font);
  Constraints.MinWidth:=440; Constraints.MinHeight:=440;
  FNames:=TStringList.Create; FNames.Sorted:=True; FNames.Duplicates:=dupIgnore;
  for var Family in Screen.Fonts do
    if (Family<>'') and not Family.StartsWith('@') then FNames.Add(Family);
  FSearch:=TEdit.Create(Self); FSearch.Parent:=Self; FSearch.Name:='ReaderWindowsFontSearch';
  FSearch.Text:=''; FSearch.Anchors:=[akLeft,akTop,akRight];
  FSearch.SetBounds(16,16,428,26); FSearch.TextHint:='Найти шрифт по названию'; FSearch.OnChange:=Filter;
  FList:=TListBox.Create(Self); FList.Parent:=Self; FList.Name:='ReaderWindowsFontResults';
  FList.SetBounds(16,50,428,242); FList.Anchors:=[akLeft,akTop,akRight,akBottom];
  FList.OnClick:=SelectionChanged; FList.OnDblClick:=Accept;
  FPreviewArea:=TScrollBox.Create(Self); FPreviewArea.Parent:=Self;
  FPreviewArea.Name:='ReaderWindowsFontPreviewArea'; FPreviewArea.BorderStyle:=bsNone;
  FPreviewArea.SetBounds(16,304,428,64); FPreviewArea.Anchors:=[akLeft,akRight,akBottom];
  FPreviewArea.HorzScrollBar.Visible:=False; FPreviewArea.VertScrollBar.Tracking:=True;
  FPreview:=TLabel.Create(Self); FPreview.Parent:=FPreviewArea; FPreview.AutoSize:=False;
  FPreview.Name:='ReaderWindowsFontPreview'; FPreview.WordWrap:=True;
  FPreviewArea.OnResize:=PreviewResize;
  FAdd:=AddButton(Self,'ReaderWindowsFontAdd','Добавить',248,378,94,Accept); FAdd.Default:=True; FAdd.Anchors:=[akRight,akBottom];
  with AddButton(Self,'ReaderWindowsFontCancel','Отмена',350,378,94,nil) do
  begin ModalResult:=mrCancel; Cancel:=True; Anchors:=[akRight,akBottom]; end;
  Filter(nil); ActiveControl:=FSearch; ApplyOwnerPalette(Self,Owner);
end;

destructor TReaderWindowsFontDialog.Destroy;
begin
  if Assigned(FPreviewArea) then FPreviewArea.OnResize:=nil;
  FNames.Free; inherited;
end;

function TReaderWindowsFontDialog.Chosen: string;
begin
  Result:='';
  if FList.ItemIndex>=0 then Result:=FList.Items[FList.ItemIndex];
end;

procedure TReaderWindowsFontDialog.Filter(Sender: TObject);
var Query: string; Extent: Integer;
begin
  Query:=LowerCase(Trim(FSearch.Text));
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for var Name in FNames do
      if (Query='') or (Pos(Query,LowerCase(Name))>0) then FList.Items.Add(Name);
    if FList.Count>0 then FList.ItemIndex:=0;
  finally FList.Items.EndUpdate; end;
  Canvas.Font.Assign(FList.Font); Extent:=0;
  for var Name in FList.Items do Extent:=Max(Extent,Canvas.TextWidth(Name));
  FList.ScrollWidth:=Extent+MulDiv(18,CurrentPPI,96);
  SelectionChanged(nil);
end;

procedure TReaderWindowsFontDialog.SelectionChanged(Sender: TObject);
begin
  FAdd.Enabled:=Chosen<>'';
  if Chosen='' then
  begin FPreview.Font.Assign(Font); FPreview.Caption:='Ничего не найдено.'; end
  else
  begin
    FPreview.Font.Name:=Chosen; FPreview.Font.Size:=15;
    FPreview.Caption:='Съешь ещё этих мягких булок.'+sLineBreak+'The quick brown fox jumps over the lazy dog.';
  end;
  FPreviewArea.VertScrollBar.Position:=0;
  FitFontPreview(FPreviewArea,FPreview);
end;

procedure TReaderWindowsFontDialog.PreviewResize(Sender: TObject);
begin FitFontPreview(FPreviewArea,FPreview); end;

procedure TReaderWindowsFontDialog.Accept(Sender: TObject);
begin if Chosen<>'' then ModalResult:=mrOk; end;

constructor TReaderFontManager.CreateFor(Owner: TCustomForm; const SettingsFile, Selected: string);
var Info: TLabel;
begin
  inherited CreateNew(Owner);
  Name:='ReaderFontManager'; Caption:='Шрифты читалки';
  PopupMode:=pmExplicit; PopupParent:=Owner; Position:=poOwnerFormCenter;
  BorderStyle:=bsDialog; AutoScroll:=False;
  ClientWidth:=580; ClientHeight:=454; Font.Assign(Owner.Font);
  FSettingsFile:=SettingsFile; FSelected:=Selected; FWaiting:=TStringList.Create;
  Info:=TLabel.Create(Self); Info.Parent:=Self; Info.AutoSize:=False; Info.WordWrap:=True;
  Info.SetBounds(16,14,548,36);
  Info.Caption:='Добавьте нужные шрифты в читалку. Убранные можно вернуть.';
  AddButton(Self,'ReaderAddWindowsFont','Из Windows…',16,54,160,WindowsClick);
  AddButton(Self,'ReaderImportFontFile','Из файла TTF / OTF…',184,54,180,ImportClick);
  FPack:=AddButton(Self,'ReaderDownloadFontPack','Скачать набор…',372,54,192,PackClick);
  FPack.Hint:='PT Serif, PT Sans, Noto Serif и Noto Sans: кириллица и латиница, по четыре начертания.';
  FPack.ShowHint:=True;
  FList:=TReaderFontListView.Create(Self); FList.Parent:=Self; FList.Name:='ReaderFontLibrary';
  FList.SetBounds(16,94,548,194); FList.ViewStyle:=vsReport;
  FList.ReadOnly:=True; FList.RowSelect:=True; FList.HideSelection:=False;
  FList.Columns.Add.Caption:='Шрифт'; FList.Columns[0].Width:=210;
  FList.Columns.Add.Caption:='Доступность'; FList.Columns[1].Width:=140;
  FList.Columns.Add.Caption:='Источник'; FList.Columns[2].Width:=170;
  FList.OnSelectItem:=SelectionChanged;
  FPreviewArea:=TScrollBox.Create(Self); FPreviewArea.Parent:=Self;
  FPreviewArea.Name:='ReaderFontPreviewArea'; FPreviewArea.BorderStyle:=bsNone;
  FPreviewArea.SetBounds(16,300,548,60); FPreviewArea.HorzScrollBar.Visible:=False;
  FPreviewArea.VertScrollBar.Tracking:=True;
  FPreview:=TLabel.Create(Self); FPreview.Parent:=FPreviewArea;
  FPreview.Name:='ReaderFontPreview'; FPreview.AutoSize:=False; FPreview.WordWrap:=True;
  FPreviewArea.OnResize:=PreviewResize;
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
  if Assigned(FPreviewArea) then FPreviewArea.OnResize:=nil;
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
  else
  begin
    FPreview.Font.Assign(Font);
    FPreview.Caption:='После загрузки здесь появится образец шрифта.';
  end;
  FPreviewArea.VertScrollBar.Position:=0;
  FitFontPreview(FPreviewArea,FPreview);
  if SameText(Name,DefaultReaderFont(FSettingsFile)) then FStatus.Caption:='Шрифт по умолчанию всегда остаётся в читалке.'
  else FStatus.Caption:='«Убрать» скрывает гарнитуру в читалке. «Вернуть» добавляет её обратно без повторной загрузки, если она доступна.';
end;

procedure TReaderFontManager.PreviewResize(Sender: TObject);
begin FitFontPreview(FPreviewArea,FPreview); end;

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
