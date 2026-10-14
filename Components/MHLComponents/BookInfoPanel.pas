(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             14.04.2010
  * Description         Панель информации о книге
  *
  * $Id: BookInfoPanel.pas 1166 2014-05-22 03:09:17Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit BookInfoPanel;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.CommCtrl,
  System.Types,
  System.Generics.Collections,
  Controls,
  Forms,
  Graphics,
  Classes,
  StdCtrls,
  ComCtrls,
  ExtCtrls,
  SysUtils,
  Math,
  Clipbrd,
  Menus,
  FictionBook_21,
  StrUtils,
  unit_MHLHelpers,
  unit_FB2Utils,
  MHLLinkLabel,
  unit_BookGallery;

type
  TInfoPanelLayoutStage = (ipsSuspendRedraw, ipsFlushTexts, ipsRestoreAlign,
    ipsFlushVisibility, ipsLayout, ipsFooter, ipsLayoutPass, ipsLinkBounds,
    ipsDetailBounds, ipsPassAlign, ipsRestoreRedraw);
  TInfoPanelLayoutProfileEvent = procedure(Sender: TObject;
    Stage: TInfoPanelLayoutStage; Starting: Boolean) of object;

  TInfoLinkMetrics = record
    Valid, Dark, VisualStyle: Boolean;
    Caption: string;
    Font: TFont;
    Window: HWND;
    PPI, RowHeight, NextSlot: Integer;
    Widths, Heights: array[0..1] of Integer;
  end;

  TInfoPanel = class(TPanel)
  private
    FCover: TImage;
    FInfoViewport: TScrollBox;
    FInfoPanel: TPanel;
    FTitle: TLabel;
    FAuthors: TMHLLinkLabel;
    FSerieLabel: TLabel;
    FSeries: TMHLLinkLabel;
    FPublisherSerieLabel: TLabel;
    FPublisherSeries: TLabel;
    FPublisherSeriesLinks: TMHLLinkLabel;
    FGenreLabel: TLabel;
    FGenres: TMHLLinkLabel;
    FAnnotation: TMemo;
    FFb2Info: TListView;
    FGallery: TBookGallery;
    FDetailsButton: TButton;
    FPreviewStatus, FReadingSupport: TLabel;

    FOnAuthorLinkClicked: TSysLinkEvent;
    FOnGenreLinkClicked: TSysLinkEvent;
    FOnSeriesLinkClicked: TSysLinkEvent;
    FOnPublisherSeriesLinkClicked: TSysLinkEvent;
    FMenu: TPopupMenu;

    FInfoPriority: Boolean;
    FUpdatingLayout: Boolean;
    FUpdateCount: Integer;
    FRedrawSuspended: Boolean;
    FRedrawWindow: HWND;
    FLinkMetrics: array[0..3] of TInfoLinkMetrics;
    FLayoutProfile: TInfoPanelLayoutProfileEvent;
    FPendingTexts: TDictionary<TControl, string>;

    function GetShowCover: boolean;
    procedure SetShowCover(const Value: boolean);

    function GetShowAnnotation: Boolean;
    procedure SetShowAnnotation(const Value: Boolean);

    procedure UpdateLinkTexts;

    procedure OnLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure OnAnnotationClicked(Sender: TObject);
    procedure SetInfoPriority(const Value: Boolean);
    procedure CopyToClipboard(Sender: TObject);
    procedure ApplyInfoText(Control: TControl; const Value: string);
    procedure SetInfoText(Control: TControl; const Value: string);
    function InfoText(Control: TControl): string;
    procedure FlushInfoTexts;
    procedure SuspendInfoRedraw;
    procedure RestoreInfoRedraw;
    procedure ProfileLayout(Stage: TInfoPanelLayoutStage; Starting: Boolean); inline;
    procedure LayoutControls;
    procedure InfoPanelResize(Sender: TObject);
    procedure CMFontChanged(var Message: TMessage); message CM_FONTCHANGED;

  protected
    procedure CreateWnd; override;
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    // Optional bounded instrumentation used by the native regression fixture.
    // No callback or timing work is performed by ordinary application panels.
    property LayoutProfile: TInfoPanelLayoutProfileEvent read FLayoutProfile write FLayoutProfile;

  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure SetBookInfo(
      const BookTitle: string;
      const Autors: string;
      const Series: string;
      const Genres: string
    );

    procedure SetBookCover(
      BookCover: TGraphic
      );

    procedure SetPublisherSeries(const Value: string);
    procedure SetPublisherSeriesLinks(const Value: string);

    procedure SetFb2Info(
      book: IXMLFictionBook;
      const Folder: string = '';
      const FileName: string = ''
      );


    procedure SetBookAnnotationText(const Value: string);
    procedure SetPreviewStatus(const Value: string);
    procedure SetReadingSupport(const Value: string);
    function PreviewStatusText: string;

    procedure SetBookAnnotation(
      book: IXMLFictionBook
      );

    procedure BeginUpdate;
    procedure EndUpdate;
    procedure Clear;
    property Gallery: TBookGallery read FGallery;
    property DetailsButton: TButton read FDetailsButton;

  published
    property ShowCover: Boolean read GetShowCover write SetShowCover default True;
    property ShowAnnotation: Boolean read GetShowAnnotation write SetShowAnnotation default True;
    property InfoPriority: Boolean read FInfoPriority write SetInfoPriority default False;

    property OnAuthorLinkClicked: TSysLinkEvent read FOnAuthorLinkClicked write FOnAuthorLinkClicked;
    property OnSeriesLinkClicked: TSysLinkEvent read FOnSeriesLinkClicked write FOnSeriesLinkClicked;
    property OnPublisherSeriesLinkClicked: TSysLinkEvent read FOnPublisherSeriesLinkClicked write FOnPublisherSeriesLinkClicked;
    property OnGenreLinkClicked: TSysLinkEvent read FOnGenreLinkClicked write FOnGenreLinkClicked;
  end;

implementation

uses unit_MHLTheme;

type
  TInfoPreviewViewport = class(TScrollBox)
  protected
    procedure WndProc(var Message: TMessage); override;
  end;

  TInfoPreviewMemo = class(TMemo)
  protected
    procedure WndProc(var Message: TMessage); override;
  end;

  TInfoDetailsButton = class(TButton)
  private
    FVisibilityPending, FFlushingVisibility: Boolean;
    procedure CMVisibleChanged(var Message: TMessage); message CM_VISIBLECHANGED;
    procedure CMFontChanged(var Message: TMessage); message CM_FONTCHANGED;
  public
    procedure FlushVisibility;
  end;

  TPublisherSeriesLinkLabel = class(TMHLLinkLabel)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

resourcestring
  rstrSerieLabel = 'Серия:';
  rstrPublisherSeriesLabel = 'Книжные серии:';
  rstrGenreLabel = 'Жанр(ы):';
  rstrNoAnnotationHint = 'Аннотация отсутствует';
  rsrtCopyLabel = 'Копировать';
  rsrtFiledLabel = 'Поле';
  rsrtValueLabel = 'Значение';

const
  PanelPadding = 10;
  CoverGap = 12;
  RowSpacing = 5;
  AnnotationGap = 8;
  LabelColumn = 70;   // width of the "Серия:"/"Жанр(ы):" caption column

function GetCoverWidth(Height: Integer): Integer;
begin
  Result := Height * 2 div 3;
end;

function InfoFontsEqual(Left, Right: TFont): Boolean;
begin
  Result := (Left.Name = Right.Name) and (Left.Height = Right.Height) and
    (Left.Style = Right.Style) and (Left.Charset = Right.Charset) and
    (Left.Pitch = Right.Pitch) and (Left.Quality = Right.Quality) and
    (Left.Orientation = Right.Orientation) and (Left.Color = Right.Color) and
    (Left.PixelsPerInch = Right.PixelsPerInch);
end;

function DeferInfoPreviewPaint(Control: TWinControl; var Message: TMessage): Boolean;
var Ancestor: TWinControl;
begin
  Result := False;
  if not (Message.Msg in [WM_PAINT, WM_ERASEBKGND, WM_NCPAINT]) or
    not MHLThemeDark or (csDestroying in Control.ComponentState) then Exit;
  Ancestor := Control.Parent;
  while Assigned(Ancestor) and not (Ancestor is TInfoPanel) do Ancestor := Ancestor.Parent;
  if not Assigned(Ancestor) or (csDestroying in Ancestor.ComponentState) or
    not TInfoPanel(Ancestor).FRedrawSuspended then Exit;
  // The custom VCL style eagerly paints scroll-box backgrounds (including
  // native memo text) during synchronous text/size/scroll changes. Suppress
  // only those transient paint messages inside the existing outer book batch.
  // Text, scrolling, style/font, range and visibility messages remain normal.
  if (Message.Msg = WM_PAINT) and (Message.WParam = 0) and Control.HandleAllocated then
    ValidateRect(Control.Handle, nil);
  if Message.Msg = WM_ERASEBKGND then Message.Result := 1 else Message.Result := 0;
  Result := True;
  // RestoreInfoRedraw clears the flag before its coalesced native invalidation
  // (including frame/children), so the actual final style is painted normally.
end;

procedure TInfoPreviewViewport.WndProc(var Message: TMessage);
begin
  if not DeferInfoPreviewPaint(Self, Message) then inherited;
end;

procedure TInfoPreviewMemo.WndProc(var Message: TMessage);
begin
  if not DeferInfoPreviewPaint(Self, Message) then inherited;
end;

procedure TInfoDetailsButton.CMVisibleChanged(var Message: TMessage);
begin
  if (Owner is TInfoPanel) and not (csDestroying in Owner.ComponentState) and
    (TInfoPanel(Owner).FUpdateCount > 0) and not FFlushingVisibility then
  begin
    // Visible already contains the final requested logical value. Defer only
    // the native show/hide while the panel is applying a book-selection batch.
    FVisibilityPending := True;
    Exit;
  end;
  inherited;
  if (Owner is TInfoPanel) and not (csDestroying in Owner.ComponentState) then
    TInfoPanel(Owner).LayoutControls;
end;

procedure TInfoDetailsButton.FlushVisibility;
begin
  if not FVisibilityPending then Exit;
  FVisibilityPending := False; FFlushingVisibility := True;
  try Perform(CM_VISIBLECHANGED, 0, 0);
  finally FFlushingVisibility := False; end;
end;

procedure TInfoDetailsButton.CMFontChanged(var Message: TMessage);
begin
  inherited;
  if (Owner is TInfoPanel) and not (csDestroying in Owner.ComponentState) then
    TInfoPanel(Owner).LayoutControls;
end;

procedure TPublisherSeriesLinkLabel.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := Params.Style or $00000004; // LWS_NOPREFIX: literal ampersands in titles.
end;

procedure TInfoPanel.CopyToClipboard(Sender: TObject);
begin
  Clipboard.AsText := FFb2Info.Selected.SubItems[0];
end;

constructor TInfoPanel.Create(AOwner: TComponent);
var
  Item: TMenuItem;
  I: Integer;
begin
  inherited Create(AOwner);
  FPendingTexts := TDictionary<TControl, string>.Create;
  for I := Low(FLinkMetrics) to High(FLinkMetrics) do
    FLinkMetrics[I].Font := TFont.Create;

  FMenu := TPopupMenu.Create(Self);
  Item := TMenuItem.Create(Self);
  Item.Caption := rsrtCopyLabel;
  Item.ShortCut := TextToShortCut('Ctrl+C');
  Item.OnClick :=  CopyToClipboard;
  FMenu.Items.Add(Item);

  SetBounds(0, 0, 500, 200);

  BevelOuter := bvNone;

  // Keep the aligned children away from the panel edge. Margins are honoured
  // by TWinControl.AlignControls and do not require a third-party panel.
  FCover := TImage.Create(Self);
  FCover.Parent := Self;
  FCover.SetBounds(0, 0, GetCoverWidth(200), 200);
  FCover.Align := alLeft;
  FCover.AlignWithMargins := True;
  FCover.Margins.SetBounds(PanelPadding, PanelPadding, 0, PanelPadding);
  FCover.Center := True;
  FCover.Proportional := True;
  FCover.Stretch := True;

  FInfoViewport := TInfoPreviewViewport.Create(Self);
  FInfoViewport.Parent := Self;
  FInfoViewport.Align := alClient;
  // This private viewport has one explicitly laid-out content panel and no
  // horizontal scrolling. Set its final logical extent in LayoutControls;
  // automatic range scans otherwise repaint styled scrollbars twice even
  // when scrolling the same unchanged content through AlignControls.
  FInfoViewport.AutoScroll := False;
  FInfoViewport.AlignWithMargins := True;
  FInfoViewport.Margins.SetBounds(CoverGap, PanelPadding, PanelPadding, PanelPadding);
  FInfoViewport.BorderStyle := bsNone;
  FInfoViewport.ParentColor := True;
  FInfoViewport.HorzScrollBar.Visible := False;
  FInfoViewport.VertScrollBar.Tracking := True;
  FInfoViewport.VertScrollBar.Smooth := True;
  FInfoPanel := TPanel.Create(Self);
  FInfoPanel.Parent := FInfoViewport;
  FInfoPanel.Align := alTop;
  FInfoPanel.Height := 200;
  FInfoPanel.BevelOuter := bvNone;
  FInfoPanel.ParentColor := True;
  // This solid content surface already paints its complete client area. Do not
  // ask the styled scroll box to paint behind it again for every child repaint
  // and scroll step; normal themed panel/child painting remains unchanged.
  FInfoPanel.ParentBackground := False;

  FTitle := TLabel.Create(FInfoPanel);
  FTitle.Parent := FInfoPanel;
  FTitle.Anchors := [akLeft, akTop, akRight];
  FTitle.AutoSize := False;
  FTitle.Font.Style := [fsBold];

  FAuthors := TMHLLinkLabel.Create(FInfoPanel);
  FAuthors.AutoSize := False;
  FAuthors.Parent := FInfoPanel;
  // SysLink's visual-style flag ignores the chosen font and always draws at theme size.
  FAuthors.UseVisualStyle := False;
  FAuthors.OnLinkClick := OnLinkClicked;

  FSerieLabel := TLabel.Create(FInfoPanel);
  FSerieLabel.Parent := FInfoPanel;
  FSerieLabel.Caption := rstrSerieLabel;
  FSerieLabel.AutoSize := False;
  FSerieLabel.Font.Style := [fsBold];

  FSeries := TMHLLinkLabel.Create(FInfoPanel);
  FSeries.AutoSize := False;
  FSeries.Parent := FInfoPanel;
  FSeries.UseVisualStyle := False;
  FSeries.OnLinkClick := OnLinkClicked;

  FPublisherSerieLabel := TLabel.Create(FInfoPanel);
  FPublisherSerieLabel.Parent := FInfoPanel;
  FPublisherSerieLabel.Caption := rstrPublisherSeriesLabel;
  FPublisherSerieLabel.AutoSize := False;
  FPublisherSerieLabel.Font.Style := [fsBold];
  FPublisherSerieLabel.Visible := False;

  FPublisherSeries := TLabel.Create(FInfoPanel);
  FPublisherSeries.Parent := FInfoPanel;
  FPublisherSeries.AutoSize := False;
  FPublisherSeries.WordWrap := True;
  FPublisherSeries.ShowAccelChar := False;
  FPublisherSeries.Visible := False;
  FPublisherSeriesLinks := TPublisherSeriesLinkLabel.Create(FInfoPanel);
  FPublisherSeriesLinks.Parent := FInfoPanel;
  FPublisherSeriesLinks.AutoSize := False;
  FPublisherSeriesLinks.UseVisualStyle := False;
  FPublisherSeriesLinks.Visible := False;
  FPublisherSeriesLinks.OnLinkClick := OnLinkClicked;

  FGenreLabel := TLabel.Create(FInfoPanel);
  FGenreLabel.Parent := FInfoPanel;
  FGenreLabel.Caption := rstrGenreLabel;
  FGenreLabel.AutoSize := False;
  FGenreLabel.Font.Style := [fsBold];

  FGenres := TMHLLinkLabel.Create(FInfoPanel);
  FGenres.AutoSize := False;
  FGenres.Parent := FInfoPanel;
  FGenres.UseVisualStyle := False;
  FGenres.OnLinkClick := OnLinkClicked;

  FGallery := TBookGallery.Create(Self);
  FGallery.Parent := FInfoPanel;
  FGallery.OnLayout := InfoPanelResize;

  FReadingSupport:=TLabel.Create(FInfoPanel); FReadingSupport.Parent:=FInfoPanel;
  FReadingSupport.AutoSize:=False; FReadingSupport.WordWrap:=True; FReadingSupport.ShowAccelChar:=False;
  FReadingSupport.Visible:=False;
  FPreviewStatus:=TLabel.Create(FInfoPanel); FPreviewStatus.Parent:=FInfoPanel;
  FPreviewStatus.AutoSize:=False; FPreviewStatus.WordWrap:=True;
  FPreviewStatus.ShowAccelChar:=False; FPreviewStatus.Font.Color:=clGrayText;
  FPreviewStatus.Visible:=False;

  FAnnotation := TInfoPreviewMemo.Create(FInfoPanel);
  FAnnotation.Parent := FInfoPanel;
  FAnnotation.Anchors := [akLeft, akTop];
  FAnnotation.BorderStyle := bsNone;
  FAnnotation.ParentColor := True;
  FAnnotation.ReadOnly := True;
  FAnnotation.TextHint := rstrNoAnnotationHint;
  FAnnotation.ScrollBars := ssVertical;
  FAnnotation.OnDblClick := OnAnnotationClicked;
  FAnnotation.Visible := not FInfoPriority;

  FFb2Info := TListView.Create(FInfoPanel);

  with FFb2Info do
  begin
    Parent := FInfoPanel;
    BorderStyle := bsNone;
    ParentColor := True;
    with Columns.Add do begin
      Caption := rsrtFiledLabel;
      Width := 175;
    end;
    with Columns.Add do begin
      Caption := rsrtValueLabel;
      AutoSize := True;
    end;
    ColumnClick := False;
    GroupView := True;
    ReadOnly := True;
    RowSelect := True;
    TabOrder := 0;
    ViewStyle := vsReport;
    Anchors := [akLeft, akTop];
    OnDblClick := OnAnnotationClicked;
    Visible := FInfoPriority;
    PopupMenu := FMenu;
  end;


  FDetailsButton := TInfoDetailsButton.Create(Self);
  // The action stays outside the scrolling metadata and annotation content.
  FDetailsButton.Parent := Self;
  FDetailsButton.Caption := 'Информация о книге';
  FDetailsButton.Visible := False;


  if csDesigning in ComponentState then
  begin
    FTitle.Caption := 'Название книги';
    FAuthors.Caption := '<a>Автор книги</a> <a>Автор книги</a>';
    FSeries.Caption := '<a>Название серии</a>';
    FGenres.Caption := '<a>Название жанра</a> <a>Название жанра</a> <a>Название жанра</a>';
  end;

  FTitle.SetBounds(0, 0, 300, 20);
  FAuthors.SetBounds(0, 20, 300, 20);
  FSerieLabel.SetBounds(0, 40, 70, 20);  FSeries.SetBounds(70, 40, 140, 20);
  FGenreLabel.SetBounds(0, 60, 70, 20);  FGenres.SetBounds(70, 60, 140, 20);
  FAnnotation.SetBounds(0, 80, 300, 120);
  FFb2Info.SetBounds(0, 80, 300, 120);

  Constraints.MinHeight := 150;
  FInfoPanel.OnResize := InfoPanelResize;
  FInfoViewport.OnResize := InfoPanelResize;
  LayoutControls;
end;

destructor TInfoPanel.Destroy;
var I: Integer;
begin
  inherited;
  FPendingTexts.Free;
  for I := Low(FLinkMetrics) to High(FLinkMetrics) do FLinkMetrics[I].Font.Free;
end;

procedure TInfoPanel.ApplyInfoText(Control: TControl; const Value: string);
begin
  // Use each public setter so its own text cache/notifications stay intact.
  if Control is TMemo then
  begin
    if TMemo(Control).Text <> Value then TMemo(Control).Text := Value;
  end
  else if Control is TMHLLinkLabel then
  begin
    if TMHLLinkLabel(Control).Caption <> Value then TMHLLinkLabel(Control).Caption := Value;
  end
  else if Control is TLabel then
  begin
    if TLabel(Control).Caption <> Value then TLabel(Control).Caption := Value;
  end
  else raise EArgumentException.Create('Unsupported book-preview text control');
  if Control = FAnnotation then
  begin FAnnotation.SelStart := 0; FAnnotation.SelLength := 0; end;
end;

procedure TInfoPanel.SetInfoText(Control: TControl; const Value: string);
begin
  if FUpdateCount > 0 then FPendingTexts.AddOrSetValue(Control, Value)
  else ApplyInfoText(Control, Value);
end;

function TInfoPanel.InfoText(Control: TControl): string;
begin
  if FPendingTexts.TryGetValue(Control, Result) then Exit;
  if Control is TMemo then Result := TMemo(Control).Text
  else if Control is TMHLLinkLabel then Result := TMHLLinkLabel(Control).Caption
  else if Control is TLabel then Result := TLabel(Control).Caption
  else raise EArgumentException.Create('Unsupported book-preview text control');
end;

procedure TInfoPanel.FlushInfoTexts;
var Item: TPair<TControl, string>;
begin
  for Item in FPendingTexts do ApplyInfoText(Item.Key, Item.Value);
  FPendingTexts.Clear;
end;

procedure TInfoPanel.ProfileLayout(Stage: TInfoPanelLayoutStage; Starting: Boolean);
begin
  if Assigned(FLayoutProfile) then FLayoutProfile(Self, Stage, Starting);
end;

procedure TInfoPanel.SuspendInfoRedraw;
begin
  FRedrawSuspended := HandleAllocated and IsWindowVisible(Handle);
  if not FRedrawSuspended then Exit;
  FRedrawWindow := Handle;
  // Suspending each descendant is measurably more expensive on Windows than
  // the existing outer-panel batch. Keep the native redraw scope unchanged.
  SendMessage(FRedrawWindow, WM_SETREDRAW, 0, 0);
end;

procedure TInfoPanel.RestoreInfoRedraw;
var RequestedVisible: Boolean;
begin
  if not FRedrawSuspended then Exit;
  FRedrawSuspended := False;
  if HandleAllocated and (Handle = FRedrawWindow) then
  begin
    RequestedVisible := Showing;
    SendMessage(FRedrawWindow, WM_SETREDRAW, 1, 0);
    if not RequestedVisible then ShowWindow(FRedrawWindow, SW_HIDE)
    else RedrawWindow(FRedrawWindow, nil, 0,
      RDW_INVALIDATE or RDW_ERASE or RDW_FRAME or RDW_ALLCHILDREN);
  end;
  FRedrawWindow := 0;
end;

procedure TInfoPanel.SetBookAnnotationText(const Value: string);
begin
  SetInfoText(FAnnotation,Value); FAnnotation.Visible:=not FInfoPriority;
  FAnnotation.SelStart:=0; FAnnotation.SelLength:=0;
end;

procedure TInfoPanel.SetReadingSupport(const Value: string);
begin SetInfoText(FReadingSupport,Value); FReadingSupport.Visible:=Value<>''; LayoutControls; end;

procedure TInfoPanel.SetPreviewStatus(const Value: string);
begin
  SetInfoText(FPreviewStatus,Value); FPreviewStatus.Visible:=Value<>'';
  LayoutControls;
end;

function TInfoPanel.PreviewStatusText: string;
begin Result:=InfoText(FPreviewStatus); end;

procedure TInfoPanel.SetBookAnnotation;
var I: Integer; AnnotationLines: TStringList;
begin
  AnnotationLines := TStringList.Create;
  try
    if book <> nil then
      try
        with book.Description.Titleinfo do
          for I := 0 to Annotation.p.Count - 1 do
            AnnotationLines.Add(Annotation.p[I].OnlyText);
      except
        // Preserve the existing partial/empty-preview behavior for malformed
        // optional descriptions, without overwriting a later queued annotation.
      end;
    SetBookAnnotationText(AnnotationLines.Text);
  finally AnnotationLines.Free; end;
end;

procedure TInfoPanel.Resize;
begin
  if Assigned(FCover) then
    FCover.Width := GetCoverWidth(FCover.Height);
  LayoutControls;
  inherited;
end;

procedure TInfoPanel.CreateWnd;
begin
  inherited;
  LayoutControls;
end;

procedure TInfoPanel.InfoPanelResize(Sender: TObject);
begin
  LayoutControls;
end;

procedure TInfoPanel.CMFontChanged(var Message: TMessage);
begin
  inherited;
  LayoutControls;
end;

procedure TInfoPanel.LayoutControls;
var
  RowH, LinkH, Gap, LblW, W, H, Y, DetailH, Pass: Integer;
  LayoutPPI, FooterH, FooterW, Padding, ViewportBottom, CoverW: Integer;
  TextRect: TRect;

  function LinkHeight(Link: TMHLLinkLabel; AvailableWidth: Integer): Integer;
  var
    IdealSize: TSize;
    Index, Slot: Integer;
    NativeWindow: HWND;
    CurrentCaption: string;
  begin
    Result := RowH;
    if not HandleAllocated or (AvailableWidth <= 0) then Exit;
    CurrentCaption := Link.Caption;
    if CurrentCaption = '' then Exit;
    if Link = FAuthors then Index := 0
    else if Link = FSeries then Index := 1
    else if Link = FGenres then Index := 2
    else Index := 3;
    NativeWindow := Link.Handle;
    // A cached measurement never authorizes a stale actual native font.
    if HFONT(SendMessage(NativeWindow, WM_GETFONT, 0, 0)) <> Link.Font.Handle then
    begin
      SendMessage(NativeWindow, WM_SETFONT, WPARAM(Link.Font.Handle), 0);
      FLinkMetrics[Index].Valid := False;
    end;
    with FLinkMetrics[Index] do
    begin
      // Four fixed link controls, two recent wrapping widths each. Text/font/
      // DPI/handle/theme changes invalidate both slots; no per-book cache grows.
      if not Valid or (Caption <> CurrentCaption) or
        (Window <> NativeWindow) or
        (PPI <> LayoutPPI) or (RowHeight <> RowH) or (Dark <> MHLThemeDark) or
        (VisualStyle <> Link.UseVisualStyle) or not InfoFontsEqual(Font, Link.Font) then
      begin
        Valid := False;
        Caption := CurrentCaption;
        Window := NativeWindow;
        PPI := LayoutPPI; RowHeight := RowH; Dark := MHLThemeDark;
        VisualStyle := Link.UseVisualStyle; Font.Assign(Link.Font);
        Widths[0] := -1; Widths[1] := -1; NextSlot := 0;
        Valid := True;
      end;
      for Slot := 0 to 1 do
        if Widths[Slot] = AvailableWidth then Exit(Heights[Slot]);
      IdealSize.cx := 0; IdealSize.cy := 0;
      SendMessage(NativeWindow, LM_GETIDEALSIZE, AvailableWidth, LPARAM(@IdealSize));
      Result := Max(RowH, IdealSize.cy + MulDiv(RowSpacing, LayoutPPI, 96));
      Widths[NextSlot] := AvailableWidth; Heights[NextSlot] := Result;
      NextSlot := 1 - NextSlot;
    end;
  end;

  procedure UseMeasuredFont(LabelControl: TLabel);
  begin
    if not InfoFontsEqual(LabelControl.Font, Canvas.Font) then
      LabelControl.Font.Assign(Canvas.Font);
  end;

begin
  if (csDestroying in ComponentState) or (FUpdateCount > 0) or FUpdatingLayout or not Assigned(FFb2Info) or
    not Assigned(FDetailsButton) or not Assigned(Parent) then
    Exit;

  // Reading client bounds may create child windows and trigger OnResize.
  // Keep the guard set through those reads and scrollbar-related realignment.
  FUpdatingLayout := True;
  ProfileLayout(ipsLayout, True);
  try
    ProfileLayout(ipsFooter, True);
    try
    // Font.PixelsPerInch also follows ScaleForPPI when VCL CurrentPPI has not
    // caught up during a resize notification. Measure the actual button font.
    LayoutPPI := Max(1, Font.PixelsPerInch);
    Padding := MulDiv(PanelPadding, LayoutPPI, 96);
    Gap := MulDiv(AnnotationGap, LayoutPPI, 96);
    ViewportBottom := Padding;
    if FDetailsButton.Visible then
    begin
      Canvas.Font.Assign(FDetailsButton.Font);
      FooterH := Max(MulDiv(32, LayoutPPI, 96),
        Canvas.TextHeight('Wg') + MulDiv(12, LayoutPPI, 96));
      FooterW := Max(MulDiv(180, LayoutPPI, 96),
        Canvas.TextWidth(FDetailsButton.Caption) + MulDiv(24, LayoutPPI, 96));
      Inc(ViewportBottom, FooterH + Gap);
    end
    else
    begin
      FooterH := 0;
      FooterW := 0;
    end;
    // A tall, narrow preview must leave enough horizontal room for the full
    // action caption. The image remains proportional inside its original-height
    // container; only its available width is reduced when space is scarce.
    CoverW := GetCoverWidth(Max(0, ClientHeight - FCover.Margins.Top - FCover.Margins.Bottom));
    if FDetailsButton.Visible and FCover.Visible then
      CoverW := Min(CoverW, Max(0, ClientWidth - FCover.Margins.Left - FCover.Margins.Right -
        FInfoViewport.Margins.Left - FInfoViewport.Margins.Right - FooterW));
    if FCover.Width <> CoverW then FCover.Width := CoverW;
    if FInfoViewport.Margins.Bottom <> ViewportBottom then
      FInfoViewport.Margins.Bottom := ViewportBottom;
    if FDetailsButton.Visible then
      FDetailsButton.SetBounds(FInfoViewport.Left,
        Max(0, ClientHeight - Padding - FooterH),
        Min(FInfoViewport.Width, FooterW), FooterH);
    finally ProfileLayout(ipsFooter, False); end;

    for Pass := 1 to 3 do
    begin
      ProfileLayout(ipsLayoutPass, True);
      FInfoPanel.DisableAlign;
      FInfoViewport.DisableAlign;
      try
      W := FInfoPanel.ClientWidth;
      H := FInfoViewport.ClientHeight;
      if (W <= 0) or (H <= 0) then
        Exit;

      // Bold captions do not inherit the parent font after Font.Style is set.
      // Build the desired font once without toggling each control to regular
      // and back to bold on every resize/selection.
      Canvas.Font.Assign(FInfoPanel.Font);
      Canvas.Font.Style := [fsBold];
      UseMeasuredFont(FTitle);
      UseMeasuredFont(FSerieLabel);
      UseMeasuredFont(FGenreLabel);
      UseMeasuredFont(FPublisherSerieLabel);
      RowH := Canvas.TextHeight('Wg') + MulDiv(RowSpacing, LayoutPPI, 96);
      Gap := MulDiv(AnnotationGap, LayoutPPI, 96);
      LblW := Max(MulDiv(LabelColumn, LayoutPPI, 96),
        Max(Canvas.TextWidth(FSerieLabel.Caption), Canvas.TextWidth(FGenreLabel.Caption)) + Gap);
      if FPublisherSerieLabel.Visible then
        LblW := Max(LblW, Canvas.TextWidth(FPublisherSerieLabel.Caption) + Gap);
      LblW := Min(LblW, W);

      ProfileLayout(ipsLinkBounds, True);
      try
      Y := 0;
      FTitle.SetBounds(0, Y, W, RowH);
      Inc(Y, RowH);
      LinkH := LinkHeight(FAuthors, W);
      FAuthors.SetBounds(0, Y, W, LinkH);
      Inc(Y, LinkH);
      LinkH := LinkHeight(FSeries, W - LblW);
      FSerieLabel.SetBounds(0, Y, LblW, RowH);
      FSeries.SetBounds(LblW, Y, W - LblW, LinkH);
      Inc(Y, LinkH);
      if FPublisherSeriesLinks.Visible then
      begin
        LinkH := LinkHeight(FPublisherSeriesLinks, W - LblW);
        FPublisherSerieLabel.SetBounds(0, Y, LblW, RowH);
        FPublisherSeriesLinks.SetBounds(LblW, Y, W - LblW, LinkH);
        Inc(Y, LinkH);
      end
      else if FPublisherSeries.Visible then
      begin
        Canvas.Font := FPublisherSeries.Font;
        TextRect := Rect(0, 0, Max(1, W - LblW), 0);
        DrawText(Canvas.Handle, PChar(FPublisherSeries.Caption), Length(FPublisherSeries.Caption),
          TextRect, DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
        LinkH := Max(RowH, TextRect.Height + MulDiv(RowSpacing, LayoutPPI, 96));
        FPublisherSerieLabel.SetBounds(0, Y, LblW, RowH);
        FPublisherSeries.SetBounds(LblW, Y, W - LblW, LinkH);
        Inc(Y, LinkH);
      end;
      LinkH := LinkHeight(FGenres, W - LblW);
      FGenreLabel.SetBounds(0, Y, LblW, RowH);
      FGenres.SetBounds(LblW, Y, W - LblW, LinkH);
      Inc(Y, LinkH + Gap);
      if FReadingSupport.Visible then
      begin
        Canvas.Font.Assign(FInfoPanel.Font);
        if MHLThemeDark then Canvas.Font.Color:=RGB(146,180,153) else Canvas.Font.Color:=$0063482E;
        UseMeasuredFont(FReadingSupport); TextRect:=Rect(0,0,Max(1,W),0);
        DrawText(Canvas.Handle,PChar(FReadingSupport.Caption),Length(FReadingSupport.Caption),TextRect,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
        LinkH:=Max(RowH,TextRect.Height); FReadingSupport.SetBounds(0,Y,W,LinkH); Inc(Y,LinkH+Gap);
      end;
      if FPreviewStatus.Visible then
      begin
        Canvas.Font.Assign(FInfoPanel.Font);
        if MHLThemeDark then Canvas.Font.Color:=RGB(150,152,156) else Canvas.Font.Color:=clGrayText;
        UseMeasuredFont(FPreviewStatus); TextRect:=Rect(0,0,Max(1,W),0);
        DrawText(Canvas.Handle,PChar(FPreviewStatus.Caption),Length(FPreviewStatus.Caption),
          TextRect,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
        LinkH:=Max(RowH,TextRect.Height);
        FPreviewStatus.SetBounds(0,Y,W,LinkH); Inc(Y,LinkH+Gap);
      end;
      if FGallery.Visible then
      begin
        FGallery.SetBounds(0, Y, W, FGallery.Height);
        Inc(Y, FGallery.Height + Gap);
      end;
      finally ProfileLayout(ipsLinkBounds, False); end;
      ProfileLayout(ipsDetailBounds, True);
      try
      // Even a very short panel must not leave the old annotation over the links.
      DetailH := Max(0, H - Y);
      if (DetailH < MulDiv(80, LayoutPPI, 96)) and
        (FAnnotation.Visible or FFb2Info.Visible) then
        DetailH := MulDiv(80, LayoutPPI, 96);
      FInfoPanel.Height := Y + DetailH;
      if FInfoViewport.VertScrollBar.Range <> FInfoPanel.Height then
        FInfoViewport.VertScrollBar.Range := FInfoPanel.Height;
      // Resize only the currently displayed detail view. Its public toggle
      // immediately lays out the other view before that view can be used.
      if FAnnotation.Visible then FAnnotation.SetBounds(0, Y, W, DetailH);
      if FFb2Info.Visible then FFb2Info.SetBounds(0, Y, W, DetailH);
      finally ProfileLayout(ipsDetailBounds, False); end;
      finally
        // Manual SetBounds must not realign/scan all siblings for every child.
        // Restore VCL alignment once, including scroll range/anchor callbacks,
        // before checking whether a new scrollbar width requires another pass.
        ProfileLayout(ipsPassAlign, True);
        try
          try FInfoViewport.EnableAlign;
          finally FInfoPanel.EnableAlign; end;
        finally
          ProfileLayout(ipsPassAlign, False);
          ProfileLayout(ipsLayoutPass, False);
        end;
      end;
      // A scrollbar changes wrapping width. Preserve the bounded retry.
      if FInfoPanel.ClientWidth = W then Break;
    end;
  finally
    FUpdatingLayout := False;
    ProfileLayout(ipsLayout, False);
  end;
end;

procedure TInfoPanel.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  LayoutControls;
end;

procedure TInfoPanel.OnAnnotationClicked(Sender: TObject);
begin
  BeginUpdate;
  try
    FFb2Info.Visible := not FFb2Info.Visible;
    FAnnotation.Visible := not FAnnotation.Visible;
  finally EndUpdate; end;
end;

procedure TInfoPanel.OnLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
begin
  if Sender = FAuthors then
  begin
    if Assigned(FOnAuthorLinkClicked) then
      FOnAuthorLinkClicked(Self, Link, LinkType);
  end
  else if Sender = FSeries then
  begin
    if Assigned(FOnSeriesLinkClicked) then
      FOnSeriesLinkClicked(Self, Link, LinkType);
  end
  else if Sender = FGenres then
  begin
    if Assigned(FOnGenreLinkClicked) then
      FOnGenreLinkClicked(Self, Link, LinkType);
  end
  else if Sender = FPublisherSeriesLinks then
  begin
    if Assigned(FOnPublisherSeriesLinkClicked) then
      FOnPublisherSeriesLinkClicked(Self, Link, LinkType);
  end
  else
    Assert(False);
end;

procedure TInfoPanel.SetBookInfo(
  const BookTitle: string;
  const Autors: string;
  const Series: string;
  const Genres: string
);
begin
  FInfoViewport.VertScrollBar.Position := 0;
  SetInfoText(FTitle, BookTitle);
  SetInfoText(FAuthors, Autors);
  // SysLink supports anchor tags; explicit line breaks must be plain CRLF.
  SetInfoText(FSeries, StringReplace(Series, '<br>', sLineBreak, [rfReplaceAll, rfIgnoreCase]));
  SetInfoText(FGenres, Genres);
  SetPublisherSeries('');
end;

procedure TInfoPanel.SetPublisherSeries(const Value: string);
begin
  SetInfoText(FPublisherSeriesLinks, '');
  FPublisherSeriesLinks.Visible := False;
  SetInfoText(FPublisherSeries, Trim(Value));
  FPublisherSeries.Visible := Trim(Value) <> '';
  FPublisherSerieLabel.Visible := FPublisherSeries.Visible;
  LayoutControls;
end;

procedure TInfoPanel.SetPublisherSeriesLinks(const Value: string);
begin
  SetInfoText(FPublisherSeries, '');
  FPublisherSeries.Visible := False;
  SetInfoText(FPublisherSeriesLinks, StringReplace(Trim(Value), '<br>', sLineBreak, [rfReplaceAll, rfIgnoreCase]));
  FPublisherSeriesLinks.Visible := Trim(Value) <> '';
  FPublisherSerieLabel.Visible := FPublisherSeriesLinks.Visible;
  LayoutControls;
end;


procedure TInfoPanel.SetFb2Info(book: IXMLFictionBook; const Folder, FileName: string);
var
  i: integer;
  tmpStr: string;

  procedure AddItem(listView: TListView; const Field: string; const Value: string; GroupID: integer = -1);
  var
    item: TListItem;
  begin
    if Trim(Value) <> '' then
    begin
      item := listView.Items.Add;
      item.Caption := Field;
      item.SubItems.Add(Value);
      item.GroupID := GroupID;
    end;
  end;

begin

  ffb2info.Clear;
  FFb2Info.Visible := FInfoPriority;

  with ffb2Info.Groups.Add do
  begin
    Header := rstrFileInfo;
    AddItem(ffb2Info, rstrFolder, Folder, GroupID);
    AddItem(ffb2Info, rstrFile, FileName, GroupID);
  end;

  if (book = nil) then   Exit;

  try
    with book.Description.Titleinfo, ffb2info.Groups.Add do
    begin
      Header := rstrGeneralInfo;

      AddItem(ffb2info, rstrTitle, Booktitle.Text, GroupID);

      for i := 0 to Author.Count - 1 do
      begin
        with Author[i] do
          tmpStr := FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(ffb2info, IfThen(i = 0, rstrAuthors), tmpStr, GroupID);
      end;

      for i := 0 to Sequence.Count - 1 do
      begin
        AddItem(ffb2info, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name + ' ' + IntToStr(Sequence[i].Number), GroupID);
      end;

      for i := 0 to Genre.Count - 1 do
      begin
        AddItem(ffb2info, IfThen(i = 0, rstrGenre), Genre[i], GroupID);
      end;

      AddItem(ffb2info, rstrKeywords, Keywords.Text, GroupID);
      AddItem(ffb2info, rstrDate, Date.Text, GroupID);
      AddItem(ffb2info, rstrBookLanguage, Lang, GroupID);
      AddItem(ffb2info, rstrSourceLanguage, Srclang, GroupID);

      for i := 0 to Translator.Count - 1 do
      begin
        with Translator[i] do
          tmpStr := FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(ffb2info, IfThen(i = 0, rstrTranslators), tmpStr, GroupID);
      end;
    end;
  except
  end;

  try
    with book.Description.Srctitleinfo, ffb2info.Groups.Add do
    begin
      Header := rstrSrclInfo;

      AddItem(ffb2info, rstrTitle, Booktitle.Text, GroupID);

      for i := 0 to Author.Count - 1 do
      begin
        with Author[i] do
          tmpStr := FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(ffb2info, IfThen(i = 0, rstrAuthors), tmpStr, GroupID);
      end;

      for i := 0 to Sequence.Count - 1 do
      begin
        AddItem(ffb2info, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name + ' ' + IntToStr(Sequence[i].Number), GroupID);
      end;

      AddItem(ffb2info, rstrKeywords, Keywords.Text, GroupID);
      AddItem(ffb2info, rstrDate, Date.Text, GroupID);
      AddItem(ffb2info, rstrBookLanguage, Lang, GroupID);
      AddItem(ffb2info, rstrSourceLanguage, Srclang, GroupID);
    end;
  except
  end;

  try
    with book.Description.Publishinfo, ffb2info.Groups.Add do
    begin
      Header := rstrPublisherInfo;

      AddItem(ffb2info, rstrTitle, Bookname.Text, GroupID);

      AddItem(ffb2info, rstrPublisher, Publisher.Text, GroupID);
      AddItem(ffb2info, rstrCity, City.Text, GroupID);
      AddItem(ffb2info, rstrYear, Year, GroupID);
      AddItem(ffb2info, rstrISBN, Isbn.Text, GroupID);

      for i := 0 to Sequence.Count - 1 do
        AddItem(ffb2info, IfThen(i = 0, rstrSingleSeries), Sequence[i].Name + ' ' + IntToStr(Sequence[i].Number), GroupID);
    end;
  except
  end;

  try
    with book.Description.Documentinfo, ffb2info.Groups.Add do
    begin
      Header := rstrOCRInfo;
      for i := 0 to Author.Count - 1 do
      begin
        with Author[i] do
          tmpStr := FormatName(Lastname.Text, Firstname.Text, Middlename.Text, NickName.Text);
        AddItem(ffb2info, IfThen(i = 0, rstrAuthors), tmpStr, GroupID);
      end;

      AddItem(ffb2info, rstrProgram, Programused.Text, GroupID);
      AddItem(ffb2info, rstrDate, Date.Text, GroupID);
      AddItem(ffb2info, rstrID, book.Description.Documentinfo.Id, GroupID);
      AddItem(ffb2info, rstrVersion, Version, GroupID);

      for i := 0 to Srcurl.Count - 1 do
        AddItem(ffb2info, IfThen(i = 0, rstrSource), Srcurl[i], GroupID);

      AddItem(ffb2info, rstrSourceAuthor, Srcocr.Text, GroupID);

      for i := 0 to History.p.Count - 1 do
        AddItem(ffb2info, IfThen(i = 0, rstrHistory), History.p[i].OnlyText, GroupID);
    end;
  except
  end;

end;

procedure TInfoPanel.SetInfoPriority(const Value: Boolean);
begin
  BeginUpdate;
  try
    FInfoPriority := Value;
    FFb2Info.Visible := FInfoPriority;
    FAnnotation.Visible := not FInfoPriority;
  finally EndUpdate; end;
end;

procedure TInfoPanel.SetBookCover(
  BookCover: TGraphic
  );
begin
  FCover.Picture.Assign(BookCover);
end;


procedure TInfoPanel.BeginUpdate;
begin
  Inc(FUpdateCount);
  if FUpdateCount <> 1 then Exit;
  DisableAlign;
  FInfoViewport.DisableAlign;
  FInfoPanel.DisableAlign;
  ProfileLayout(ipsSuspendRedraw, True);
  try SuspendInfoRedraw;
  finally ProfileLayout(ipsSuspendRedraw, False); end;
end;

procedure TInfoPanel.EndUpdate;
begin
  Assert(FUpdateCount > 0);
  if FUpdateCount > 1 then
  begin
    Dec(FUpdateCount);
    Exit;
  end;
  try
    // Alignment can send several child resize notifications. Keep the batch
    // active through both realignments and lay out the final bounds once.
    try
      // Apply the final text once: Clear followed by SetBookInfo must not
      // rebuild three identical native SysLinks through an intermediate blank.
      try
        ProfileLayout(ipsFlushTexts, True);
        try FlushInfoTexts;
        finally ProfileLayout(ipsFlushTexts, False); end;
      finally
        ProfileLayout(ipsRestoreAlign, True);
        try
          // Resolve the final outer viewport before its content and anchors.
          // Otherwise a cover/visibility change lays out the scroll range once
          // at the previous width and again after the outer panel realigns.
          try EnableAlign;
          finally
            try FInfoViewport.EnableAlign;
            finally FInfoPanel.EnableAlign; end;
          end;
        finally ProfileLayout(ipsRestoreAlign, False); end;
        ProfileLayout(ipsFlushVisibility, True);
        try TInfoDetailsButton(FDetailsButton).FlushVisibility;
        finally ProfileLayout(ipsFlushVisibility, False); end;
      end;
    finally Dec(FUpdateCount); end;
    LayoutControls;
  finally
    ProfileLayout(ipsRestoreRedraw, True);
    try RestoreInfoRedraw;
    finally ProfileLayout(ipsRestoreRedraw, False); end;
  end;
end;

procedure TInfoPanel.Clear;
begin
  SetPreviewStatus(''); SetReadingSupport('');
  FGallery.Clear;
  FDetailsButton.Visible := False;
  FInfoViewport.VertScrollBar.Position := 0;
  SetInfoText(FTitle, '');
  SetInfoText(FAuthors, '');
  SetInfoText(FSeries, '');
  SetInfoText(FGenres, '');
  SetInfoText(FAnnotation, '');
  if FFb2Info.Items.Count > 0 then FFb2Info.Items.Clear;
  FCover.Picture.Assign(nil);
  SetPublisherSeries('');
end;


function TInfoPanel.GetShowAnnotation: Boolean;
begin
  Result := FAnnotation.Visible;
end;

procedure TInfoPanel.SetShowAnnotation(const Value: Boolean);
begin
  if GetShowAnnotation <> Value then
  begin
    FAnnotation.Visible := Value;
    if Value then
      Constraints.MinHeight := MulDiv(150, Max(1, Font.PixelsPerInch), 96)
    else
      Constraints.MinHeight := MulDiv(80, Max(1, Font.PixelsPerInch), 96);
    LayoutControls;
  end;
end;

function TInfoPanel.GetShowCover: boolean;
begin
  Result := FCover.Visible;
end;

procedure TInfoPanel.SetShowCover(const Value: boolean);
begin
  if GetShowCover <> Value then
  begin
    FCover.Visible := Value;
    UpdateLinkTexts;
  end;
end;

procedure TInfoPanel.UpdateLinkTexts;
begin
end;

end.
