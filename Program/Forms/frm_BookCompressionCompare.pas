unit frm_BookCompressionCompare;

interface

uses System.Classes, System.JSON, System.Zip, Winapi.Messages, Vcl.Forms, Vcl.Controls,
  Vcl.StdCtrls, Vcl.ExtCtrls, frm_CatalogSources;

type
  TComparisonScrollEvent = procedure(Sender: TObject; Horizontal, Vertical: Boolean) of object;

  TComparisonScrollBox = class(TScrollBox)
  private
    FOnScroll: TComparisonScrollEvent;
  protected
    procedure WndProc(var Message: TMessage); override;
  end;

  TfrmBookCompressionCompare = class(TSourceDialogForm)
  private
    FData: TMemoryStream;
    FZip: TZipFile;
    FManifest: TJSONObject;
    FList: TComboBox;
    FFit, FLink: TCheckBox;
    FBefore, FAfter: TComparisonScrollBox;
    FSyncingScroll: Boolean;
    FOriginal, FResult: TImage;
    FLeftTitle, FRightTitle, FIntro, FNote: TLabel;
    FClose: TButton;
    FScale: Integer;
    procedure Layout(Sender: TObject);
    procedure Choose(Sender: TObject);
    procedure FitChanged(Sender: TObject);
    procedure FitImages;
    procedure ScrollChanged(Sender: TObject; Horizontal, Vertical: Boolean);
    procedure LinkChanged(Sender: TObject);
  public
    constructor CreateComparison(Owner: TComponent; const FileName, ExpectedSHA256: string);
    destructor Destroy; override;
    procedure ScaleForPPI(NewPPI: Integer); override;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Hash, System.Math, System.Types,
  Winapi.Windows, Winapi.ActiveX, Winapi.Wincodec, System.Win.ComObj, Vcl.Graphics,
  unit_FB2Utils, unit_MHLTheme, unit_MHLExternalTools;

const
  ComparisonDecodeBudget = 32*1024*1024;

// Read the first frame at its original size. Check dimensions before allocating pixels.
function FirstComparisonFrame(Stream:TStream):TGraphic;
var Adapter:IStream; Decoder:IWICBitmapDecoder; Frame:IWICBitmapFrameDecode;
  Converter:IWICFormatConverter; Bitmap:IWICBitmap; Factory:IWICImagingFactory; W,H:UINT;
begin
  Result:=nil; Stream.Position:=0;
  Adapter:=TStreamAdapter.Create(Stream,soReference);
  OleCheck(CoCreateInstance(CLSID_WICImagingFactory,nil,CLSCTX_INPROC_SERVER,IWICImagingFactory,Factory));
  OleCheck(Factory.CreateDecoderFromStream(Adapter,GUID_NULL,WICDecodeMetadataCacheOnDemand,Decoder));
  OleCheck(Decoder.GetFrame(0,Frame));
  OleCheck(Frame.GetSize(W,H));
  if (W=0) or (H=0) or (UInt64(W)*H>ComparisonDecodeBudget div 4) then Exit;
  OleCheck(Factory.CreateFormatConverter(Converter));
  OleCheck(Converter.Initialize(Frame,GUID_WICPixelFormat32bppPBGRA,WICBitmapDitherTypeNone,nil,0,WICBitmapPaletteTypeCustom));
  OleCheck(Factory.CreateBitmapFromSource(Converter,WICBitmapCacheOnLoad,Bitmap));
  var Image:=TWICImage.Create;
  try Image.Handle:=Bitmap; Result:=Image;
  except Image.Free; raise; end;
end;

procedure TComparisonScrollBox.WndProc(var Message: TMessage);
var X, Y: Integer;
begin
  case Message.Msg of
    WM_HSCROLL, WM_VSCROLL, WM_MOUSEWHEEL, CM_MOUSEWHEEL:
      begin
        X := HorzScrollBar.Position; Y := VertScrollBar.Position;
        inherited;
        if Assigned(FOnScroll) and
          ((X <> HorzScrollBar.Position) or (Y <> VertScrollBar.Position)) then
          FOnScroll(Self, X <> HorzScrollBar.Position, Y <> VertScrollBar.Position);
      end;
  else inherited;
  end;
end;

constructor TfrmBookCompressionCompare.CreateComparison(Owner: TComponent;
  const FileName, ExpectedSHA256: string);
var Input:TFileStream; Bytes:TBytes; Pairs:TJSONArray;
  function LabelFor(const Name:string):TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=Self; Result.Name:=Name;
    Result.AutoSize:=False; Result.WordWrap:=True;
  end;
  function Pane(const Name:string; out Picture:TImage):TComparisonScrollBox;
  begin
    Result:=TComparisonScrollBox.Create(Self); Result.Parent:=Self; Result.Name:=Name;
    Result.FOnScroll := ScrollChanged;
    Result.HorzScrollBar.Tracking:=True; Result.VertScrollBar.Tracking:=True;
    Picture:=TImage.Create(Self); Picture.Parent:=Result;
    Picture.Name:=Name+'Image';
    Picture.Stretch:=True; Picture.Proportional:=True;
  end;
begin
  inherited CreateNew(Owner); Name:='BookCompressionComparison';
  Caption:='Сравнить изображения до сжатия и после';
  Position:=poOwnerFormCenter; BorderStyle:=bsSizeable;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; FScale:=96;
  Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=980; ClientHeight:=680; Constraints.MinWidth:=760; Constraints.MinHeight:=500;
  FData:=TMemoryStream.Create;
  Input:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
  try
    if (Input.Size<=0) or (Input.Size>50*1024*1024) then
      raise EReadError.Create('Слишком большой файл сравнения изображений.');
    FData.CopyFrom(Input,Input.Size);
  finally Input.Free; end;
  FData.Position:=0;
  if not SameText(THashSHA2.GetHashString(FData),ExpectedSHA256) then
    raise EReadError.Create('Файл сравнения изображений изменился. Исходная книга сохранена.');
  FData.Position:=0; FZip:=TZipFile.Create; FZip.Open(FData,zmRead);
  var ManifestIndex:=FZip.IndexOf('comparison.json');
  if (ManifestIndex<0) or (FZip.FileInfo[ManifestIndex].UncompressedSize>65536) then
    raise EReadError.Create('Некорректный список изображений для сравнения.');
  FZip.Read('comparison.json',Bytes);
  FManifest:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes)) as TJSONObject;
  if not Assigned(FManifest) or (FManifest.GetValue<Integer>('schema',0)<>1) or
    not (FManifest.GetValue('pairs') is TJSONArray) then
    raise EReadError.Create('Некорректный список изображений для сравнения.');
  Pairs:=FManifest.GetValue<TJSONArray>('pairs');
  if (Pairs.Count=0) or (Pairs.Count>12) then raise EReadError.Create('Некорректное число изображений для сравнения.');
  FIntro:=LabelFor('ComparisonIntro');
  FIntro.Caption:='Слева — оригинал, справа — подготовленный результат. В масштабе 100% видны настоящие пиксели. '+
    'Изменения ещё не применены.';
  FList:=TComboBox.Create(Self); FList.Parent:=Self; FList.Name:='ComparisonImages';
  FList.Style:=csDropDownList; FList.ShowHint:=True; FList.OnChange:=Choose;
  for var Pair in Pairs do
    FList.Items.Add(Pair.GetValue<string>('member','')+' · '+Pair.GetValue<string>('image',''));
  FFit:=TCheckBox.Create(Self); FFit.Parent:=Self; FFit.Name:='ComparisonFit';
  FFit.Caption:='Вписать в окно'; FFit.Checked:=False; FFit.OnClick:=FitChanged;
  FLink := TCheckBox.Create(Self); FLink.Parent := Self; FLink.Name := 'ComparisonLinkScroll';
  FLink.Caption := 'Связать прокрутку'; FLink.Checked := True; FLink.OnClick := LinkChanged;
  FLeftTitle:=LabelFor('ComparisonBeforeTitle'); FRightTitle:=LabelFor('ComparisonAfterTitle');
  FBefore:=Pane('ComparisonBefore',FOriginal); FAfter:=Pane('ComparisonAfter',FResult);
  FNote:=LabelFor('ComparisonNote');
  FClose:=TButton.Create(Self); FClose.Parent:=Self; FClose.Name:='ComparisonClose';
  FClose.Caption:='Готово'; FClose.ModalResult:=mrOk; FClose.Cancel:=True; FClose.Default:=True;
  OnResize:=Layout; Layout(nil); ApplyMHLControlTheme(Self);
  FList.ItemIndex:=0; Choose(nil);
end;

destructor TfrmBookCompressionCompare.Destroy;
begin FManifest.Free; FZip.Free; FData.Free; inherited; end;

procedure TfrmBookCompressionCompare.ScaleForPPI(NewPPI:Integer);
begin inherited; FScale:=NewPPI; Layout(nil); end;

procedure TfrmBookCompressionCompare.Layout(Sender:TObject);
var Gap, Half, Top, Height:Integer;
  function Px(Value:Integer):Integer;
  begin Result:=MulDiv(Value,FScale,96); end;
begin
  if not Assigned(FClose) then Exit;
  Gap:=Px(16); Half:=(ClientWidth-3*Gap) div 2; Top:=Px(130);
  Height:=Max(Px(180),ClientHeight-Top-Px(90));
  FIntro.SetBounds(Gap,Gap,ClientWidth-2*Gap,Px(40));
  FList.SetBounds(Gap,Px(66),ClientWidth-Px(386),Px(26));
  FFit.SetBounds(ClientWidth-Px(352),Px(66),Px(150),Px(26));
  FLink.SetBounds(ClientWidth-Px(190),Px(66),Px(174),Px(26));
  FLeftTitle.SetBounds(Gap,Px(104),Half,Px(22));
  FRightTitle.SetBounds(2*Gap+Half,Px(104),Half,Px(22));
  FBefore.SetBounds(Gap,Top,Half,Height); FAfter.SetBounds(2*Gap+Half,Top,Half,Height);
  FNote.SetBounds(Gap,ClientHeight-Px(78),ClientWidth-Px(160),Px(64));
  FClose.SetBounds(ClientWidth-Px(132),ClientHeight-Px(46),Px(116),Px(30));
  FitImages;
end;

procedure TfrmBookCompressionCompare.FitImages;
  procedure Fit(Image:TImage; Area:TScrollBox);
  begin
    if Image.Picture.Graphic=nil then Exit;
    if FFit.Checked then Image.SetBounds(0,0,Max(1,Area.ClientWidth-4),Max(1,Area.ClientHeight-4))
    else Image.SetBounds(0,0,Image.Picture.Width,Image.Picture.Height);
  end;
begin Fit(FOriginal,FBefore); Fit(FResult,FAfter); end;

procedure TfrmBookCompressionCompare.FitChanged(Sender:TObject);
begin
  FLink.Enabled := not FFit.Checked;
  FitImages;
end;

procedure TfrmBookCompressionCompare.LinkChanged(Sender: TObject);
begin
  ScrollChanged(FBefore, True, True);
end;

procedure TfrmBookCompressionCompare.ScrollChanged(Sender: TObject; Horizontal, Vertical: Boolean);
var Source, Target: TComparisonScrollBox; SourceImage, TargetImage: TImage;
  function PositionFor(Position, SourceExtent, SourceViewport, TargetExtent, TargetViewport: Integer): Integer;
  var TargetLimit: Integer;
  begin
    TargetLimit := Max(0, TargetExtent - TargetViewport);
    if (Position <= 0) or (SourceExtent <= SourceViewport) then Exit(0);
    if Position >= SourceExtent - SourceViewport then Exit(TargetLimit);
    Result := EnsureRange(Round((Position + SourceViewport / 2) * TargetExtent / SourceExtent -
      TargetViewport / 2), 0, TargetLimit);
  end;
begin
  if FSyncingScroll or not Assigned(FLink) or not FLink.Checked or FFit.Checked or
    not Assigned(FBefore) or not Assigned(FAfter) then Exit;
  if Sender = FBefore then
  begin Source := FBefore; Target := FAfter; SourceImage := FOriginal; TargetImage := FResult; end
  else
  begin Source := FAfter; Target := FBefore; SourceImage := FResult; TargetImage := FOriginal; end;
  FSyncingScroll := True;
  try
    if Horizontal and (SourceImage.Width > Source.ClientWidth) then
      Target.HorzScrollBar.Position := PositionFor(Source.HorzScrollBar.Position, SourceImage.Width,
        Source.ClientWidth, TargetImage.Width, Target.ClientWidth);
    if Vertical and (SourceImage.Height > Source.ClientHeight) then
      Target.VertScrollBar.Position := PositionFor(Source.VertScrollBar.Position, SourceImage.Height,
        Source.ClientHeight, TargetImage.Height, Target.ClientHeight);
  finally FSyncingScroll := False; end;
end;

procedure TfrmBookCompressionCompare.Choose(Sender:TObject);
var Pair:TJSONValue;
  procedure Load(Image:TImage; Title:TLabel; const Key, Caption:string);
  var Name:string; Bytes:TBytes; Stream:TBytesStream; Graphic:TGraphic; Index:Integer; IsTiff:Boolean;
  begin
    Image.Picture.Assign(nil); Name:=Pair.GetValue<string>(Key,''); Index:=FZip.IndexOf(Name);
    if (Name<>Format('%.2d-%s',[FList.ItemIndex,Key])) or (Index<0) or
      (FZip.FileInfo[Index].UncompressedSize>8*1024*1024) then
      raise EReadError.Create('Некорректное изображение для сравнения.');
    FZip.Read(Name,Bytes); Stream:=TBytesStream.Create(Bytes); Graphic:=nil;
    try
      // TIFF samples keep their original encoded bytes, including additional pages.
      IsTiff:=(Length(Bytes)>=4) and (((Bytes[0]=$49) and (Bytes[1]=$49) and (Bytes[2]=$2A) and (Bytes[3]=0)) or
        ((Bytes[0]=$4D) and (Bytes[1]=$4D) and (Bytes[2]=0) and (Bytes[3]=$2A)));
      if IsTiff then
      begin
        try Graphic:=FirstComparisonFrame(Stream); except on E:EOleSysError do Graphic:=nil; end;
      end
      else
      try
        Graphic:=CreateGraphicFromStream(Stream,ComparisonDecodeBudget);
      except
        on E:EMHLComponentRequired do
        begin
          // Windows may already have a WebP decoder, even on a minimal installation.
          try Graphic:=FirstComparisonFrame(Stream); except on DecodeError:EOleSysError do Graphic:=nil; end;
          if Graphic=nil then
          begin Title.Caption:=Caption+' · для просмотра нужен модуль WebP'; Exit; end;
        end;
      end;
      if Graphic=nil then
      begin
        Title.Caption:=Caption+' · слишком большое или неподдерживаемое изображение';
        Exit;
      end;
      Image.Picture.Assign(Graphic);
      if Pair.GetValue<string>('kind','')='djvu_fragment' then
        Title.Caption:=Format('%s · %d × %d пикс.',[Caption,Graphic.Width,Graphic.Height])
      else
      begin
        Title.Caption:=Format('%s · %d × %d · %.1f КБ',[Caption,Graphic.Width,Graphic.Height,Length(Bytes)/1024]);
        if IsTiff then Title.Caption:=Title.Caption+' · страница 1';
      end;
    finally Graphic.Free; Stream.Free; end;
  end;
begin
  if FList.ItemIndex<0 then Exit;
  Pair:=FManifest.GetValue<TJSONArray>('pairs').Items[FList.ItemIndex];
  Load(FOriginal,FLeftTitle,'before','Оригинал'); Load(FResult,FRightTitle,'after','После сжатия');
  FList.Hint:=FList.Text;
  FBefore.HorzScrollBar.Position:=0; FBefore.VertScrollBar.Position:=0;
  FAfter.HorzScrollBar.Position:=0; FAfter.VertScrollBar.Position:=0;
  FNote.Caption:=Format('Изображение %d из %d. Для сравнения берётся до 12 иллюстраций выбранных книг. '+
    'Проверьте мелкий текст и важные детали перед применением.',[FList.ItemIndex+1,FList.Items.Count]);
  if Pair.GetValue<string>('kind','')='djvu_fragment' then
    FNote.Caption:='Показан один и тот же участок исходной и подготовленной страницы DjVu. '+
      'Снимите «Вписать в окно», чтобы проверить мелкие детали фона в масштабе 100%.';
  FitImages;
end;

end.
