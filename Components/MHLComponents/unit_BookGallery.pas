unit unit_BookGallery;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  Winapi.Windows, Vcl.Forms, Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.Graphics;

type
  TGalleryPicture = class
    Name: string;
    Graphic: TGraphic;
    destructor Destroy; override;
  end;

  TGalleryLoader = class(TThread)
  private
    FSource: TFunc<TStream>;
    FExtension: string;
    FBytes: Int64;
    procedure ReadImage(const Name: string; Stream: TStream);
  protected
    procedure Execute; override;
  public
    Pictures: TObjectList<TGalleryPicture>;
    ErrorText: string;
    Limited: Boolean;
    constructor Create(const Source: TFunc<TStream>; const Extension: string);
    destructor Destroy; override;
  end;

  TBookGallery = class(TPanel)
  private
    FToggle: TButton;
    FStrip: TScrollBox;
    FStatus: TLabel;
    FImages: TList<TImage>;
    FRetiredHandles: TList<THandle>;
    FLoader: TGalleryLoader;
    FSource: TFunc<TStream>;
    FExtension, FBookIdentity, FTitle: string;
    FPreviewSettingsFile: string;
    FExpanded, FLoaded: Boolean;
    FOnLayout: TNotifyEvent;
    procedure ToggleClick(Sender: TObject);
    procedure WorkerFinished(Sender: TObject);
    procedure ThumbnailClick(Sender: TObject);
    procedure ResetImages;
    procedure CancelLoad;
    procedure UpdateLayout;
    procedure SetTitle(const Value: string);
    function GetImageCount: Integer;
    function GetLoading: Boolean;
  protected
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetBook(const Identity, Extension: string; const Source: TFunc<TStream>);
    procedure Clear;
    procedure SetExpanded(Value: Boolean);
    procedure OpenImage(Index: Integer);
    property Expanded: Boolean read FExpanded write SetExpanded;
    property ImageCount: Integer read GetImageCount;
    property Loading: Boolean read GetLoading;
    property PreviewSettingsFile: string read FPreviewSettingsFile write FPreviewSettingsFile;
    property OnLayout: TNotifyEvent read FOnLayout write FOnLayout;
    property Title: string read FTitle write SetTitle;
  end;

implementation

uses
  Winapi.ActiveX, System.Zip, System.NetEncoding,
  System.Math, System.Types, System.IniFiles, Xml.XMLDoc, Xml.XMLIntf, unit_FB2Utils;

const
  MaxImages = 256;
  MaxImageBytes = 16 * 1024 * 1024;
  MaxGalleryBytes = 64 * 1024 * 1024;
  MaxBookBytes = 128 * 1024 * 1024;

type
  TGalleryPreview = class(TForm)
  private
    FGallery: TBookGallery;
    FImage: TImage;
    FPrevious, FNext: TButton;
    FPosition: TLabel;
    FIndex: Integer;
    FNormalBounds: TRect;
    procedure LoadBounds;
    procedure SaveBounds;
    procedure RememberBounds(Sender: TObject);
    procedure Navigate(Sender: TObject);
    procedure CMDialogKey(var Message: TCMDialogKey); message CM_DIALOGKEY;
    procedure ShowIndex(Index: Integer);
  public
    constructor CreateGallery(Gallery: TBookGallery; Index: Integer);
    destructor Destroy; override;
  end;

destructor TGalleryPicture.Destroy;
begin
  Graphic.Free;
  inherited;
end;

constructor TGalleryLoader.Create(const Source: TFunc<TStream>; const Extension: string);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FSource := Source;
  FExtension := Extension;
  Pictures := TObjectList<TGalleryPicture>.Create(True);
end;

destructor TGalleryLoader.Destroy;
begin
  Pictures.Free;
  inherited;
end;

procedure TGalleryLoader.ReadImage(const Name: string; Stream: TStream);
var Graphic: TGraphic; Picture: TGalleryPicture; Size: Int64;
begin
  if Terminated or not Assigned(Stream) then Exit;
  if (Pictures.Count >= MaxImages) or (Stream.Size > MaxImageBytes) then
  begin Limited := True; Exit; end;
  Graphic := nil;
  try
    try Graphic := CreateGraphicFromStream(Stream); except Exit; end;
    if not Assigned(Graphic) then Exit;
    // Bound decoded pictures too, since highly compressed scans may be enormous.
    Size := Int64(Graphic.Width) * Graphic.Height * 4;
    if (Size <= 0) or (FBytes + Size > MaxGalleryBytes) then
    begin Limited := True; Exit; end;
    Picture := TGalleryPicture.Create;
    Picture.Name := Name;
    Picture.Graphic := Graphic;
    Graphic := nil;
    Pictures.Add(Picture);
    Inc(FBytes, Size);
  finally
    Graphic.Free;
  end;
end;

procedure TGalleryLoader.Execute;
var Source, Image: TStream; Doc: IXMLDocument; Binary: IXMLNode; Zip: TZipFile;
  I: Integer; Bytes: TBytes; Header: TZipHeader; Ext: string; ComResult: HRESULT;
begin
  ComResult := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  Source := nil;
  try
    try
      if Terminated then Exit;
      Source := FSource();
      if not Assigned(Source) then raise Exception.Create('Файл книги недоступен.');
      if Source.Size > MaxBookBytes then
        raise Exception.Create('Книга слишком велика для галереи. Откройте её в читалке.');
      if Terminated then Exit;
      Source.Position := 0;
      if SameText(FExtension, '.fb2') then
      begin
        Doc := TXMLDocument.Create(nil);
        Doc.LoadFromStream(Source);
        if not Assigned(Doc.DocumentElement) or
          not SameText(Doc.DocumentElement.LocalName, 'FictionBook') then
          raise Exception.Create('Не удалось прочитать изображения книги.');
        // Binary is a direct child in every FB2 namespace, including 2.1/2.2
        // and producers which omit the namespace. Do not bind it to FB2 2.0.
        for I := 0 to Doc.DocumentElement.ChildNodes.Count - 1 do
        begin
          if Terminated or (Pictures.Count >= MaxImages) then Break;
          Binary := Doc.DocumentElement.ChildNodes[I];
          if not SameText(Binary.LocalName, 'binary') then Continue;
          if Length(Binary.Text) > MaxImageBytes * 4 div 3 + 1024 then
          begin Limited := True; Continue; end;
          try
            Bytes := TNetEncoding.Base64.DecodeStringToBytes(Binary.Text);
            Image := TBytesStream.Create(Bytes);
            try
              if Binary.HasAttribute('id') then Ext := Binary.AttributeNodes['id'].Text
              else Ext := IntToStr(I + 1);
              ReadImage(Ext, Image);
            finally Image.Free; end;
          except
            // One malformed or unsupported binary must not hide other illustrations.
          end;
        end;
      end
      else if SameText(FExtension, '.epub') then
      begin
        Zip := TZipFile.Create;
        try
          Zip.Open(Source, zmRead);
          for I := 0 to Zip.FileCount - 1 do
          begin
            if Terminated or (Pictures.Count >= MaxImages) then Break;
            Ext := LowerCase(ExtractFileExt(Zip.FileNames[I]));
            if not ((Ext = '.png') or (Ext = '.jpg') or (Ext = '.jpeg') or
              (Ext = '.webp') or (Ext = '.gif') or (Ext = '.bmp')) then Continue;
            Header := Zip.FileInfo[I];
            if Header.UncompressedSize > MaxImageBytes then
            begin Limited := True; Continue; end;
            Image := nil;
            try
              try
                Zip.Read(I, Image, Header);
                ReadImage(Zip.FileNames[I], Image);
              except
                // Damaged images are isolated without extracting paths to disk.
              end;
            finally Image.Free; end;
          end;
        finally Zip.Free; end;
      end;
      if Pictures.Count >= MaxImages then Limited := True;
    except
      on E: Exception do ErrorText := E.Message;
    end;
  finally
    Binary := nil;
    Doc := nil;
    Source.Free;
    FSource := nil;
    if Succeeded(ComResult) then CoUninitialize;
  end;
end;

constructor TBookGallery.Create(AOwner: TComponent);
begin
  inherited;
  FTitle := 'Иллюстрации';
  BevelOuter := bvNone;
  ParentColor := True;
  FImages := TList<TImage>.Create;
  FRetiredHandles := TList<THandle>.Create;
  FToggle := TButton.Create(Self);
  FToggle.Name := 'GalleryToggle';
  FToggle.Parent := Self;
  FToggle.Caption := FTitle + ' ▸';
  FToggle.OnClick := ToggleClick;
  FStrip := TScrollBox.Create(Self);
  FStrip.Parent := Self;
  FStrip.BorderStyle := bsNone;
  FStrip.ParentColor := True;
  FStrip.VertScrollBar.Visible := False;
  FStrip.HorzScrollBar.Tracking := True;
  FStrip.Visible := False;
  FStatus := TLabel.Create(Self);
  FStatus.Parent := FStrip;
  FStatus.AutoSize := False;
  FStatus.WordWrap := True;
  FStatus.ShowAccelChar := False;
  Visible := False;
  Height := 28;
end;

destructor TBookGallery.Destroy;
var WorkerHandle: THandle;
begin
  CancelLoad;
  // Cancelled workers may still be finishing extraction. Keep the runtime and
  // decoder libraries alive until they exit; a new book never waits for them.
  for WorkerHandle in FRetiredHandles do
  begin
    while WaitForSingleObject(WorkerHandle, 10) = WAIT_TIMEOUT do CheckSynchronize(0);
    CloseHandle(WorkerHandle);
  end;
  FRetiredHandles.Free;
  ResetImages;
  FImages.Free;
  inherited;
end;

procedure TBookGallery.CancelLoad;
var WorkerHandle: THandle; I: Integer;
begin
  for I := FRetiredHandles.Count - 1 downto 0 do
    if WaitForSingleObject(FRetiredHandles[I], 0) = WAIT_OBJECT_0 then
    begin
      CloseHandle(FRetiredHandles[I]);
      FRetiredHandles.Delete(I);
    end;
  if Assigned(FLoader) then
  begin
    if not DuplicateHandle(GetCurrentProcess, FLoader.Handle, GetCurrentProcess,
      @WorkerHandle, SYNCHRONIZE, False, 0) then RaiseLastOSError;
    FRetiredHandles.Add(WorkerHandle);
    FLoader.OnTerminate := nil;
    FLoader.Terminate;
    FLoader := nil; // The worker owns its temporary graphics until it terminates.
  end;
end;

procedure TBookGallery.ResetImages;
var Image: TImage;
begin
  for Image in FImages do Image.Free;
  FImages.Clear;
  if Assigned(Parent) then FStrip.HorzScrollBar.Position := 0;
  FLoaded := False;
end;

procedure TBookGallery.SetTitle(const Value: string);
begin
  FTitle := Value;
  if FExpanded then FToggle.Caption := FTitle + ' ▾'
  else FToggle.Caption := FTitle + ' ▸';
end;

procedure TBookGallery.Clear;
begin
  CancelLoad;
  ResetImages;
  FSource := nil;
  FBookIdentity := '';
  FExpanded := False;
  FStrip.Visible := False;
  Visible := False;
  UpdateLayout;
end;

procedure TBookGallery.SetBook(const Identity, Extension: string; const Source: TFunc<TStream>);
begin
  if (Identity = FBookIdentity) and Visible then Exit;
  Clear;
  FBookIdentity := Identity;
  FExtension := Extension;
  FSource := Source;
  Visible := Assigned(Source) and (SameText(Extension, '.fb2') or SameText(Extension, '.epub'));
  FToggle.Caption := FTitle + ' ▸';
  UpdateLayout;
end;

procedure TBookGallery.ToggleClick(Sender: TObject);
begin
  SetExpanded(not FExpanded);
end;

procedure TBookGallery.SetExpanded(Value: Boolean);
begin
  if not Visible or (FExpanded = Value) then Exit;
  FExpanded := Value;
  FStrip.Visible := Value;
  if Value then
  begin
    FToggle.Caption := FTitle + ' ▾';
    if not FLoaded and not Assigned(FLoader) and Assigned(FSource) then
    begin
      ResetImages;
      FStatus.Visible := True;
      FStatus.Caption := 'Загрузка изображений…';
      FLoader := TGalleryLoader.Create(FSource, FExtension);
      FLoader.OnTerminate := WorkerFinished;
      FLoader.Start;
    end;
  end
  else FToggle.Caption := FTitle + ' ▸';
  UpdateLayout;
end;

procedure TBookGallery.WorkerFinished(Sender: TObject);
var Loader: TGalleryLoader; Picture: TGalleryPicture; Image: TImage;
begin
  if Sender <> FLoader then Exit;
  Loader := FLoader;
  FLoader := nil;
  FLoaded := Loader.ErrorText = '';
  for Picture in Loader.Pictures do
  begin
    Image := TImage.Create(Self);
    Image.Parent := FStrip;
    Image.Picture.Assign(Picture.Graphic);
    Image.Hint := Picture.Name;
    Image.ShowHint := True;
    Image.Tag := FImages.Count;
    Image.Center := True;
    Image.Proportional := True;
    Image.Stretch := True;
    Image.Cursor := crHandPoint;
    Image.OnClick := ThumbnailClick;
    FImages.Add(Image);
  end;
  FStatus.Visible := (FImages.Count = 0) or Loader.Limited or (Loader.ErrorText <> '');
  if Loader.ErrorText <> '' then
    FStatus.Caption := 'Не удалось загрузить галерею: ' + Loader.ErrorText +
      ' Сверните и раскройте её для повторной попытки.'
  else if FImages.Count = 0 then FStatus.Caption := 'В книге нет поддерживаемых иллюстраций.'
  else if Loader.Limited then FStatus.Caption := 'Показана часть изображений.';
  UpdateLayout;
end;

procedure TBookGallery.UpdateLayout;
var I, HeaderH, StripH, ThumbW, Gap: Integer;
begin
  if not Assigned(FToggle) or not Assigned(Parent) then Exit;
  HeaderH := MulDiv(28, CurrentPPI, 96);
  StripH := MulDiv(172, CurrentPPI, 96);
  ThumbW := MulDiv(120, CurrentPPI, 96);
  Gap := MulDiv(10, CurrentPPI, 96);
  FToggle.SetBounds(0, 0, Min(Width, MulDiv(220, CurrentPPI, 96)), HeaderH);
  if FExpanded then
  begin
    if (FImages.Count = 0) and not Loading then StripH := MulDiv(65, CurrentPPI, 96);
    FStrip.SetBounds(0, HeaderH + Gap, Width, StripH);
    for I := 0 to FImages.Count - 1 do
      FImages[I].SetBounds(I * (ThumbW + Gap), 0, ThumbW, StripH - MulDiv(24, CurrentPPI, 96));
    FStatus.SetBounds(FImages.Count * (ThumbW + Gap), 0, Max(180, Width - Gap), StripH - Gap);
    Height := HeaderH + Gap + StripH;
  end
  else Height := HeaderH;
  if Assigned(FOnLayout) then FOnLayout(Self);
end;

procedure TBookGallery.Resize;
begin
  inherited;
  UpdateLayout;
end;

procedure TBookGallery.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  UpdateLayout;
end;

function TBookGallery.GetImageCount: Integer;
begin
  Result := FImages.Count;
end;

function TBookGallery.GetLoading: Boolean;
begin
  Result := Assigned(FLoader);
end;

procedure TBookGallery.ThumbnailClick(Sender: TObject);
begin
  OpenImage(TImage(Sender).Tag);
end;

procedure TBookGallery.OpenImage(Index: Integer);
var Preview: TGalleryPreview;
begin
  if (Index < 0) or (Index >= FImages.Count) then Exit;
  Preview := TGalleryPreview.CreateGallery(Self, Index);
  try Preview.ShowModal; finally Preview.Free; end;
end;

constructor TGalleryPreview.CreateGallery(Gallery: TBookGallery; Index: Integer);
var Bar: TPanel;
begin
  inherited CreateNew(Gallery);
  FGallery := Gallery;
  Caption := FGallery.Title;
  BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMaximize];
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  DoubleBuffered := True;
  Position := poScreenCenter;
  Width := Min(680, Screen.WorkAreaWidth - 32);
  Height := Min(520, Screen.WorkAreaHeight - 48);
  Constraints.MinWidth := 400;
  Constraints.MinHeight := 300;
  Color := clWindow;
  Bar := TPanel.Create(Self);
  Bar.Parent := Self;
  Bar.Align := alBottom;
  Bar.Height := 44;
  Bar.BevelOuter := bvNone;
  FPrevious := TButton.Create(Self);
  FPrevious.Parent := Bar;
  FPrevious.Align := alLeft;
  FPrevious.Width := 140;
  FPrevious.Caption := '← Предыдущая';
  FPrevious.Tag := -1;
  FPrevious.OnClick := Navigate;
  FNext := TButton.Create(Self);
  FNext.Parent := Bar;
  FNext.Align := alRight;
  FNext.Width := 140;
  FNext.Caption := 'Следующая →';
  FNext.Tag := 1;
  FNext.OnClick := Navigate;
  FPosition := TLabel.Create(Self);
  FPosition.Parent := Bar;
  FPosition.Align := alClient;
  FPosition.Alignment := taCenter;
  FPosition.Layout := tlCenter;
  FImage := TImage.Create(Self);
  FImage.Parent := Self;
  FImage.Align := alClient;
  FImage.Center := True;
  FImage.Stretch := True;
  FImage.Proportional := True;
  ShowIndex(Index);
  LoadBounds;
  FNormalBounds := BoundsRect;
  OnResize := RememberBounds;
  OnShow := RememberBounds;
end;

destructor TGalleryPreview.Destroy;
begin
  SaveBounds;
  inherited;
end;

procedure TGalleryPreview.RememberBounds(Sender: TObject);
begin
  if WindowState = wsNormal then FNormalBounds := BoundsRect;
end;

procedure TGalleryPreview.LoadBounds;
var Ini: TMemIniFile; Bounds, Work: TRect; PPI: Integer; SavedMaximized: Boolean;
begin
  if (FGallery.PreviewSettingsFile = '') or not FileExists(FGallery.PreviewSettingsFile) then Exit;
  try
    Ini := TMemIniFile.Create(FGallery.PreviewSettingsFile, TEncoding.UTF8);
    try
      PPI := EnsureRange(Ini.ReadInteger('Gallery', 'PPI', 96), 72, 480);
      Bounds.Left := Ini.ReadInteger('Gallery', 'Left', Left);
      Bounds.Top := Ini.ReadInteger('Gallery', 'Top', Top);
      Bounds.Width := Max(400, MulDiv(EnsureRange(Ini.ReadInteger('Gallery', 'Width', 680), 400, 8192), CurrentPPI, PPI));
      Bounds.Height := Max(300, MulDiv(EnsureRange(Ini.ReadInteger('Gallery', 'Height', 520), 300, 8192), CurrentPPI, PPI));
      SavedMaximized := Ini.ReadBool('Gallery', 'Maximized', False);
    finally Ini.Free; end;
    Work := Screen.MonitorFromRect(Bounds, mdNearest).WorkareaRect;
    Bounds.Width := Min(Bounds.Width, Work.Width);
    Bounds.Height := Min(Bounds.Height, Work.Height);
    Bounds.Offset(EnsureRange(Bounds.Left, Work.Left, Work.Right - Bounds.Width) - Bounds.Left,
      EnsureRange(Bounds.Top, Work.Top, Work.Bottom - Bounds.Height) - Bounds.Top);
    Position := poDesigned;
    SetBounds(Bounds.Left, Bounds.Top, Bounds.Width, Bounds.Height);
    FNormalBounds := Bounds;
    if SavedMaximized then WindowState := wsMaximized;
  except
    // A damaged/unwritable preference file must not prevent reading illustrations.
  end;
end;

procedure TGalleryPreview.SaveBounds;
var Ini: TMemIniFile;
begin
  if (FGallery.PreviewSettingsFile = '') or FNormalBounds.IsEmpty then Exit;
  if WindowState = wsNormal then FNormalBounds := BoundsRect;
  try
    ForceDirectories(ExtractFilePath(FGallery.PreviewSettingsFile));
    Ini := TMemIniFile.Create(FGallery.PreviewSettingsFile, TEncoding.UTF8);
    try
      Ini.WriteInteger('Gallery', 'Left', FNormalBounds.Left);
      Ini.WriteInteger('Gallery', 'Top', FNormalBounds.Top);
      Ini.WriteInteger('Gallery', 'Width', FNormalBounds.Width);
      Ini.WriteInteger('Gallery', 'Height', FNormalBounds.Height);
      Ini.WriteInteger('Gallery', 'PPI', CurrentPPI);
      Ini.WriteBool('Gallery', 'Maximized', WindowState = wsMaximized);
      Ini.UpdateFile;
    finally Ini.Free; end;
  except end;
end;

procedure TGalleryPreview.ShowIndex(Index: Integer);
begin
  if (Index < 0) or (Index >= FGallery.ImageCount) then Exit;
  FIndex := Index;
  FImage.Picture.Assign(FGallery.FImages[Index].Picture);
  FPosition.Caption := IntToStr(Index + 1) + ' из ' + IntToStr(FGallery.ImageCount);
  Caption := FGallery.Title + ' — ' + FPosition.Caption;
  FPrevious.Enabled := Index > 0;
  FNext.Enabled := Index < FGallery.ImageCount - 1;
end;

procedure TGalleryPreview.Navigate(Sender: TObject);
begin
  ShowIndex(FIndex + TButton(Sender).Tag);
end;

procedure TGalleryPreview.CMDialogKey(var Message: TCMDialogKey);
begin
  case Message.CharCode of
    VK_LEFT: ShowIndex(FIndex - 1);
    VK_RIGHT: ShowIndex(FIndex + 1);
    VK_ESCAPE: ModalResult := mrCancel;
  else
    inherited;
    Exit;
  end;
  Message.Result := 1;
end;

end.
