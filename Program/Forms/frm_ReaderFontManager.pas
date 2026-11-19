unit frm_ReaderFontManager;

interface

uses Vcl.Forms;

procedure ManageReaderFonts(Owner: TCustomForm; const SettingsFile: string;
  var Selected: string);

implementation

uses Winapi.Windows, Winapi.Messages, Winapi.CommCtrl, System.Types, System.Math, System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Dialogs, Vcl.Graphics, Vcl.ExtCtrls,
  unit_ReaderFonts, unit_ReaderFontDownloads, unit_ReaderPalette, unit_ContextToolGuide;

type
  TReaderFontListView = class(TListView)
  private
    procedure WMNotify(var Message: TWMNotify); message WM_NOTIFY;
  end;

  TReaderFontPreview = class(TPanel)
  private
    FSample: TLabel;
    FPosition, FDragOffset, FWheelRemainder: Integer;
    function ScrollLimit: Integer;
    function Track: TRect;
    function Thumb(const Bar: TRect): TRect;
    procedure ScrollTo(Position: Integer);
    procedure WMGetDlgCode(var Message: TWMGetDlgCode); message WM_GETDLGCODE;
  protected
    procedure Resize; override;
    procedure Paint; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X,Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X,Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X,Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Fit(ResetPosition: Boolean = False);
    property Sample: TLabel read FSample;
  end;

  TReaderWindowsFontDialog = class(TForm)
  private
    FSearch: TEdit;
    FList: TListBox;
    FPreview: TLabel;
    FPreviewArea: TReaderFontPreview;
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
    FPreviewArea: TReaderFontPreview;
    FRestore, FRemove, FPack: TButton;
    FToolGuide:TContextToolGuide;
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
    procedure DoShow; override;
    procedure DoHide; override;
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

constructor TReaderFontPreview.Create(AOwner: TComponent);
begin
  inherited;
  BevelOuter:=bvNone; ParentBackground:=False;
  FDragOffset:=-1;
  FSample:=TLabel.Create(Self); FSample.Parent:=Self; FSample.AutoSize:=False;
  FSample.WordWrap:=True; FSample.ShowAccelChar:=False;
end;

function TReaderFontPreview.ScrollLimit: Integer;
begin
  Result:=Max(0,FSample.Height-ClientHeight);
end;

function TReaderFontPreview.Track: TRect;
begin
  Result:=Rect(ClientWidth-MulDiv(14,CurrentPPI,96),0,ClientWidth,ClientHeight);
end;

function TReaderFontPreview.Thumb(const Bar: TRect): TRect;
var Height: Integer;
begin
  Height:=EnsureRange(MulDiv(Bar.Height,ClientHeight,FSample.Height),
    Min(Bar.Height,MulDiv(14,CurrentPPI,96)),Bar.Height);
  Result:=Bar;
  Result.Top:=Bar.Top+MulDiv(Bar.Height-Height,FPosition,ScrollLimit);
  Result.Bottom:=Result.Top+Height;
end;

procedure TReaderFontPreview.ScrollTo(Position: Integer);
begin
  FPosition:=EnsureRange(Position,0,ScrollLimit);
  FSample.Top:=-FPosition;
  Invalidate;
end;

procedure TReaderFontPreview.Fit(ResetPosition: Boolean);
var Bounds: TRect; DC: HDC; DCState: Integer;
begin
  if not Assigned(FSample) or (csDestroying in ComponentState) then Exit;
  DC:=GetDC(Handle);
  DCState:=SaveDC(DC);
  try
    SelectObject(DC,FSample.Font.Handle);
    Bounds:=Rect(0,0,Max(1,ClientWidth-MulDiv(24,CurrentPPI,96)),0);
    DrawText(DC,PChar(FSample.Caption),Length(FSample.Caption),Bounds,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FSample.SetBounds(MulDiv(4,CurrentPPI,96),-FPosition,Bounds.Width,
      Bounds.Height+MulDiv(6,CurrentPPI,96));
  finally
    RestoreDC(DC,DCState);
    ReleaseDC(Handle,DC);
  end;
  if ResetPosition then
  begin
    FPosition:=0;
    FWheelRemainder:=0;
  end;
  TabStop:=ScrollLimit>0;
  ScrollTo(FPosition);
end;

procedure TReaderFontPreview.Resize;
begin
  inherited;
  Fit;
end;

procedure TReaderFontPreview.Paint;
begin
  Canvas.Brush.Color:=Color; Canvas.FillRect(ClientRect);
  if not Assigned(FSample) or (ScrollLimit=0) then Exit;
  var Bar:=Track;
  Canvas.Brush.Color:=ReaderBlendColor(Color,Font.Color,36); Canvas.FillRect(Bar);
  if Focused then Canvas.Brush.Color:=ReaderBlendColor(Color,Font.Color,176)
  else Canvas.Brush.Color:=ReaderBlendColor(Color,Font.Color,132);
  Canvas.FillRect(Thumb(Bar));
end;

procedure TReaderFontPreview.WMGetDlgCode(var Message: TWMGetDlgCode);
begin
  inherited;
  Message.Result:=Message.Result or DLGC_WANTARROWS;
end;

procedure TReaderFontPreview.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited;
  if ScrollLimit=0 then Exit;
  var Line:=MulDiv(16,CurrentPPI,96);
  case Key of
    VK_UP: ScrollTo(FPosition-Line);
    VK_DOWN: ScrollTo(FPosition+Line);
    VK_PRIOR: ScrollTo(FPosition-ClientHeight);
    VK_NEXT: ScrollTo(FPosition+ClientHeight);
    VK_HOME: ScrollTo(0);
    VK_END: ScrollTo(ScrollLimit);
  else Exit;
  end;
  Key:=0;
end;

function TReaderFontPreview.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  if ScrollLimit=0 then Exit(inherited DoMouseWheel(Shift,WheelDelta,MousePos));
  Inc(FWheelRemainder,WheelDelta);
  var Steps:=FWheelRemainder div WHEEL_DELTA;
  FWheelRemainder:=FWheelRemainder mod WHEEL_DELTA;
  if Steps<>0 then ScrollTo(FPosition-Steps*MulDiv(48,CurrentPPI,96));
  Result:=True;
end;

procedure TReaderFontPreview.MouseDown(Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
begin
  inherited;
  if (Button<>mbLeft) or (ScrollLimit=0) then Exit;
  var Bar:=Track;
  if not Bar.Contains(Point(X,Y)) then Exit;
  if CanFocus then SetFocus;
  var HandleRect:=Thumb(Bar);
  if HandleRect.Contains(Point(X,Y)) then
  begin
    FDragOffset:=Y-HandleRect.Top;
    MouseCapture:=True;
    Invalidate;
  end
  else if Y<HandleRect.Top then ScrollTo(FPosition-ClientHeight)
  else ScrollTo(FPosition+ClientHeight);
end;

procedure TReaderFontPreview.MouseMove(Shift: TShiftState; X,Y: Integer);
begin
  inherited;
  if (FDragOffset<0) or not (ssLeft in Shift) or (ScrollLimit=0) then Exit;
  var Bar:=Track;
  var Travel:=Bar.Height-Thumb(Bar).Height;
  if Travel>0 then ScrollTo(MulDiv(Y-FDragOffset-Bar.Top,ScrollLimit,Travel));
end;

procedure TReaderFontPreview.MouseUp(Button: TMouseButton; Shift: TShiftState; X,Y: Integer);
begin
  if (Button=mbLeft) and (FDragOffset>=0) then
  begin
    FDragOffset:=-1;
    MouseCapture:=False;
  end;
  inherited;
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
  FPreviewArea:=TReaderFontPreview.Create(Self); FPreviewArea.Parent:=Self;
  FPreviewArea.Name:='ReaderWindowsFontPreviewArea';
  FPreviewArea.SetBounds(16,304,428,64); FPreviewArea.Anchors:=[akLeft,akRight,akBottom];
  FPreview:=FPreviewArea.Sample; FPreview.Name:='ReaderWindowsFontPreview';
  FAdd:=AddButton(Self,'ReaderWindowsFontAdd','Добавить',248,378,94,Accept); FAdd.Default:=True; FAdd.Anchors:=[akRight,akBottom];
  with AddButton(Self,'ReaderWindowsFontCancel','Отмена',350,378,94,nil) do
  begin ModalResult:=mrCancel; Cancel:=True; Anchors:=[akRight,akBottom]; end;
  Filter(nil); ActiveControl:=FSearch; ApplyOwnerPalette(Self,Owner);
end;

destructor TReaderWindowsFontDialog.Destroy;
begin
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
  FPreviewArea.Fit(True);
end;

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
  Info.Name:='ReaderFontsIntro'; Info.SetBounds(16,14,508,36);
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
  FPreviewArea:=TReaderFontPreview.Create(Self); FPreviewArea.Parent:=Self;
  FPreviewArea.Name:='ReaderFontPreviewArea';
  FPreviewArea.SetBounds(16,300,548,60);
  FPreview:=FPreviewArea.Sample; FPreview.Name:='ReaderFontPreview';
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Self; FStatus.Name:='ReaderFontManagerStatus';
  FStatus.AutoSize:=False; FStatus.WordWrap:=True; FStatus.SetBounds(16,366,548,42);
  FRestore:=AddButton(Self,'ReaderRestoreFont','Вернуть в список',16,410,176,RestoreClick);
  FRemove:=AddButton(Self,'ReaderRemoveFont','Убрать из списка',200,410,176,RemoveClick);
  with AddButton(Self,'ReaderFontManagerClose','Готово',450,410,114,nil) do
  begin ModalResult:=mrOk; Default:=True; Cancel:=True; end;
  FToolGuide:=TContextToolGuide.CreateForTool(Self,Self,'reader-fonts','Как добавить шрифт для чтения',
    'Выберите установленный шрифт через «Из Windows…» или добавьте свой файл TTF или OTF. «Скачать набор…» добавляет шрифты для чтения через интернет.',
    'Выделите шрифт, чтобы увидеть образец. «Убрать из списка» скрывает шрифт из выбора, а «Вернуть в список» снова делает доступным уже загруженный шрифт. После «Готово» выберите нужный шрифт в настройках текста.',
    0,'',SettingsFile);
  FToolGuide.Name:='ReaderFontsContextGuide';
  Refresh(Selected); ApplyOwnerPalette(Self,Owner);
end;

procedure TReaderFontManager.DoShow;
begin
  inherited;
  FToolGuide.FirstUse;
end;

procedure TReaderFontManager.DoHide;
begin
  if Assigned(FToolGuide) then FToolGuide.Hide;
  inherited;
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
  else
  begin
    FPreview.Font.Assign(Font);
    FPreview.Caption:='После загрузки здесь появится образец шрифта.';
  end;
  FPreviewArea.Fit(True);
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
