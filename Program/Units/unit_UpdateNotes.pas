unit unit_UpdateNotes;

interface

uses System.Classes, System.Types, Vcl.Controls, Vcl.ComCtrls, Vcl.Forms,
  Vcl.StdCtrls, Vcl.ExtCtrls, Winapi.Messages;

type
  TUpdateNotesView = class;
  TUpdateNotesEdit = class(TRichEdit)
  private
    FView: TUpdateNotesView;
    FTextHeight: Integer;
    procedure CNNotify(var Message: TWMNotify); message CN_NOTIFY;
  protected
    procedure WndProc(var Message: TMessage); override;
  public
    function MeasureHeight: Integer;
  end;

  TUpdateNotesSection = record
    Panel: TPanel;
    Header: TButton;
    Body: TRichEdit;
    Title, Notes: string;
    Expanded: Boolean;
    BodyHeight, MeasuredWidth, MeasuredPPI, LoadedZoomPercent: Integer;
  end;

  TUpdateNotesView = class(TScrollBox)
  private
    FSections: array of TUpdateNotesSection;
    FSpareSections: array of TUpdateNotesSection;
    FPrimaryNotes: TRichEdit;
    FMore: TButton;
    FHistoryTitles, FHistoryBodies: TArray<string>;
    FShownLimit: Integer;
    FAppending: Boolean;
    FLoading, FLayouting, FRedrawDisabled: Boolean;
    FLastNotes: string;
    FZoomPercent: Integer;
    FOnZoomChanged: TNotifyEvent;
    procedure ShowMore(Sender: TObject);
    procedure MoreFocused(Sender: TObject);
    procedure BeginDisplayUpdate;
    procedure EndDisplayUpdate;
    procedure SetZoomPercent(Value: Integer);
    procedure Toggle(Sender: TObject);
    procedure HeaderFocused(Sender: TObject);
    procedure LayoutSections;
  protected
    procedure Resize; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Load(const Notes: string);
    procedure ApplyTheme;
    function SectionCount: Integer;
    function SectionHeader(Index: Integer): TButton;
    function SectionNotes(Index: Integer): TRichEdit;
    function IsExpanded(Index: Integer): Boolean;
    procedure SetExpanded(Index: Integer; Value: Boolean);
    procedure ScrollWheel(Delta: Integer; Zoom: Boolean);
    property PrimaryNotes: TRichEdit read FPrimaryNotes;
    property ZoomPercent: Integer read FZoomPercent write SetZoomPercent;
    property OnZoomChanged: TNotifyEvent read FOnZoomChanged write FOnZoomChanged;
  end;

function SQLiteNotesToMarkdown(const HTML: string): string;
procedure LoadUpdateNotes(Control: TRichEdit; const Notes: string; ZoomPercent: Integer = 100);

{$IFDEF MHL_RELEASE_PERFORMANCE}
var UpdateNotesParseMS, UpdateNotesControlsMS, UpdateNotesFormatMS,
    UpdateNotesThemeMS, UpdateNotesLayoutMS: UInt64;
{$ENDIF}

implementation

uses System.SysUtils, System.Math, System.RegularExpressions, System.NetEncoding,
  Vcl.Graphics, Winapi.Windows, Winapi.RichEdit, Winapi.CommCtrl, unit_MHLTheme;

function SQLiteNotesToMarkdown(const HTML: string): string;
var Token: TMatch; Tag, Line, Text: string; Lines: TStringList;
  Depth, LineDepth: Integer; InItem: Boolean;
  procedure Flush;
  var Value: string;
  begin
    Value := TRegEx.Replace(Line, '\s+', ' ').Trim;
    if Value <> '' then
    begin
      if InItem then
        Value := StringOfChar(' ', 2 * (LineDepth - 1)) + '- ' + Value
      else if Value.EndsWith(':') then Value := '## ' + Value;
      Lines.Add(Value);
    end;
    Line := '';
  end;
begin
  Lines := TStringList.Create;
  try
    Depth := 0; LineDepth := 1; InItem := False; Line := '';
    // The feed is data only: never instantiate a browser or execute its HTML.
    Text := TRegEx.Replace(HTML, '(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>', '');
    for Token in TRegEx.Matches(Text, '<[^>]*>|[^<]+') do
    begin
      Tag := LowerCase(Token.Value);
      if Tag.StartsWith('<ol') or Tag.StartsWith('<ul') then
      begin
        Flush; Inc(Depth); InItem := False;
      end
      else if Tag.StartsWith('</ol') or Tag.StartsWith('</ul') then
      begin
        Flush; Depth := Max(0, Depth - 1); InItem := False;
      end
      else if Tag.StartsWith('<li') then
      begin
        Flush; InItem := True; LineDepth := Max(1, Min(Depth, 16));
      end
      else if Tag.StartsWith('</li') then
      begin Flush; InItem := False; end
      else if Tag.StartsWith('<p>') or Tag.StartsWith('<p ') or
              Tag.StartsWith('</p') or Tag.StartsWith('<br') then Flush
      else if Tag.StartsWith('<code') or Tag.StartsWith('</code') then Line := Line + '`'
      else if not Tag.StartsWith('<') then
      begin
        Tag := StringReplace(Token.Value, '&emsp;', ' ', [rfReplaceAll]);
        Tag := StringReplace(Tag, '&larr;', '←', [rfReplaceAll]);
        Tag := StringReplace(Tag, '&harr;', '↔', [rfReplaceAll]);
        Line := Line + TNetEncoding.HTML.Decode(Tag);
      end;
    end;
    Flush;
    Result := Lines.Text.Trim;
  finally Lines.Free; end;
end;

function IsReleaseHeading(const Text: string): Boolean;
begin
  Result := TRegEx.IsMatch(Text, '^(?:HomeLib Ru |SQLite |SumatraPDF |DjVuLibre |v)?[0-9]+\.[0-9]+(?:\.[0-9]+)*(?:_pre[0-9]+(?:\.[0-9]+)*)?(?: — [0-9]{2}\.[0-9]{2}\.[0-9]{4})?$');
end;

function RTFText(const Text: string): string;
var C: Char; Builder: TStringBuilder; Code: Integer;
begin
  Builder := TStringBuilder.Create;
  try
    for C in Text do
      case C of
        '\', '{', '}': Builder.Append('\').Append(C);
        #9: Builder.Append('\tab ');
      else
        if Ord(C) < 128 then Builder.Append(C)
        else
        begin
          Code := Ord(C); if Code > 32767 then Dec(Code, 65536);
          Builder.Append('\u').Append(Code).Append('?');
        end;
      end;
    Result := Builder.ToString;
  finally Builder.Free; end;
end;

function InlineRTF(const Text: string): string;
var I: Integer; Bold, Code: Boolean;
begin
  Result := ''; I := 1; Bold := False; Code := False;
  while I <= Length(Text) do
  begin
    if (Copy(Text, I, 2) = '**') or (Copy(Text, I, 2) = '__') then
    begin
      Bold := not Bold; if Bold then Result := Result + '\b ' else Result := Result + '\b0 ';
      Inc(I, 2);
    end
    else if Text[I] = '`' then
    begin
      Code := not Code; if Code then Result := Result + '\f1 ' else Result := Result + '\f0 ';
      Inc(I);
    end
    else begin Result := Result + RTFText(Text[I]); Inc(I); end;
  end;
end;

function DividerRTF(Control: TRichEdit): string;
var Bitmap: Vcl.Graphics.TBitmap; Count: Integer;
begin
  Bitmap := Vcl.Graphics.TBitmap.Create;
  try
    Bitmap.Canvas.Font.Name := 'Consolas';
    Bitmap.Canvas.Font.PixelsPerInch := Control.Font.PixelsPerInch;
    Bitmap.Canvas.Font.Size := 8;
    Count := Max(8, Min(150, (Control.ClientWidth - GetSystemMetrics(SM_CXVSCROLL) - 12) div
      Max(1, Bitmap.Canvas.TextWidth('─'))));
    Result := '\pard\f1\fs16\b0\cf2\li0\fi0\sb60\sa140 ' +
      RTFText(StringOfChar('─', Count)) + '\par ';
  finally Bitmap.Free; end;
end;

procedure LoadUpdateNotes(Control: TRichEdit; const Notes: string; ZoomPercent: Integer);
var Lines: TStringList; Stream: TStringStream; Builder: TStringBuilder;
  Line, Text, Divider: string; Heading, ListItem: TMatch; Level, Indent: Integer;
  Version, SeenVersion: Boolean; BodyColor, DividerColor: TColor;
  function RTFColor(Value: TColor): string;
  var RGB: Cardinal;
  begin
    RGB := ColorToRGB(Value);
    Result := '\red'+IntToStr(GetRValue(RGB))+'\green'+IntToStr(GetGValue(RGB))+
      '\blue'+IntToStr(GetBValue(RGB))+';';
  end;
begin
  Lines := TStringList.Create; Builder := TStringBuilder.Create;
  try
    Text := TRegEx.Replace(Notes, '\[([^\]]+)\]\((https://[^)]+)\)', '$1 ($2)');
    if Text.Trim = '' then Text := 'Автор не опубликовал описание изменений этого выпуска.';
    Lines.Text := AdjustLineBreaks(Text); SeenVersion := False; Divider := DividerRTF(Control);
    BodyColor := MHLThemeText;
    if MHLThemeDark then DividerColor := RGB(125,130,140) else DividerColor := RGB(140,140,140);
    Builder.Append('{\rtf1\ansi\deff0\uc1{\fonttbl{\f0 Segoe UI;}{\f1 Consolas;}}{\colortbl;')
      .Append(RTFColor(BodyColor)).Append(RTFColor(DividerColor)).Append('}');
    for Line in Lines do
    begin
      Text := Line.Trim;
      Heading := TRegEx.Match(Text, '^(#{1,6})\s+(.+)$');
      Level := 0;
      if Heading.Success then begin Level := Length(Heading.Groups[1].Value); Text := Heading.Groups[2].Value; end;
      Version := IsReleaseHeading(Text);
      if Version and SeenVersion then
        Builder.Append(Divider);
      if Version then SeenVersion := True;
      Builder.Append('\pard\f0\fs').Append(MulDiv(20, ZoomPercent, 100)).Append('\b0\cf1\li0\fi0\sb0\sa80 ');
      ListItem := TRegEx.Match(Line, '^(\s*)([-*+•]|[0-9]+[.)])\s+(.+)$');
      if ListItem.Success and not Heading.Success then
      begin
        Indent := 220 + Min(Length(ListItem.Groups[1].Value), 32) * 110;
        Builder.Append('\li').Append(Indent).Append('\fi-180 ');
        Text := ListItem.Groups[3].Value;
        if (Length(Text) < 100) and Text.EndsWith(':') then Builder.Append('\b ');
        Builder.Append(RTFText(ListItem.Groups[2].Value)).Append('\tab ');
      end;
      if Version then Builder.Append('\fs').Append(MulDiv(28, ZoomPercent, 100)).Append('\b\sb120\sa120 ')
      else if Level > 0 then Builder.Append('\fs').Append(MulDiv(22, ZoomPercent, 100)).Append('\b\sb120 ')
      else if (Length(Text) < 100) and Text.EndsWith(':') then Builder.Append('\b\sb100 ');
      if TRegEx.IsMatch(Text, '^(?:-{3,}|={3,}|\*{3,})$') then
        Builder.Append(Divider)
      else Builder.Append(InlineRTF(Text));
      Builder.Append('\par ');
    end;
    Builder.Append('}');
    Stream := TStringStream.Create(Builder.ToString, TEncoding.ASCII);
    try
      Control.Lines.BeginUpdate;
      try Control.PlainText := False; Control.Lines.LoadFromStream(Stream); Control.SelStart := 0;
      finally Control.Lines.EndUpdate; end;
    finally Stream.Free; end;
  finally Lines.Free; Builder.Free; end;
end;

constructor TUpdateNotesView.Create(AOwner: TComponent);
begin
  inherited;
  FZoomPercent := 100; FShownLimit := 3;
  Color := clWindow;
  DoubleBuffered := True;
  HorzScrollBar.Visible := False;
  VertScrollBar.Tracking := True;
  FMore := TButton.Create(Self); FMore.Name := 'UpdateNotesMore';
  FMore.Parent := Self; FMore.Visible := False; FMore.TabStop := False;
  FMore.Caption := 'Показать ещё 3'; FMore.WordWrap := True;
  FMore.Font.Name := 'Segoe UI'; FMore.Font.Size := 12;
  FMore.ShowHint := True; FMore.Hint := 'Показать следующие выпуски из истории изменений.';
  FMore.OnClick := ShowMore; FMore.OnEnter := MoreFocused;
  FPrimaryNotes := TUpdateNotesEdit.Create(Self);
  TUpdateNotesEdit(FPrimaryNotes).FView := Self;
  FPrimaryNotes.Parent := Self;
  FPrimaryNotes.Visible := False;
  ApplyTheme;
end;

procedure TUpdateNotesView.ApplyTheme;
var I: Integer; Background: TColor; Format: TCharFormat2;
  procedure ThemeBody(Body: TRichEdit);
  begin
    Body.StyleElements := Body.StyleElements - [seClient,seFont];
    Body.Color := Background;
    if not Body.HandleAllocated then Exit;
    FillChar(Format,SizeOf(Format),0);
    Format.cbSize := SizeOf(Format); Format.dwMask := CFM_COLOR;
    Format.crTextColor := ColorToRGB(MHLThemeText);
    SendMessage(Body.Handle,EM_SETCHARFORMAT,SCF_ALL,LPARAM(@Format));
    SendMessage(Body.Handle,EM_SETBKGNDCOLOR,0,ColorToRGB(Background));
    Body.Invalidate;
  end;
begin
  if MHLThemeDark then Background := RGB(30,31,34) else Background := clWindow;
  Color := Background;
  if Assigned(FMore) then FMore.Font.Color := MHLThemeText;
  // RichEdit font changes can allocate its native window. Wait until this
  // dynamically created view has been attached to its parent form.
  if Parent = nil then Exit;
  if Assigned(FPrimaryNotes) then ThemeBody(FPrimaryNotes);
  for I := 0 to High(FSections) do
  begin
    FSections[I].Panel.Color := MHLThemeBackground;
    FSections[I].Header.Font.Color := MHLThemeText;
    if FSections[I].Body <> FPrimaryNotes then ThemeBody(FSections[I].Body);
  end;
  for I := 0 to High(FSpareSections) do
  begin
    FSpareSections[I].Panel.Color := MHLThemeBackground;
    FSpareSections[I].Header.Font.Color := MHLThemeText;
    ThemeBody(FSpareSections[I].Body);
  end;
  Invalidate;
end;

type
  PNotesResize = ^TNotesResize;
  TNotesResize = record
    Header: TNMHDR;
    Bounds: TRect;
  end;

procedure TUpdateNotesEdit.CNNotify(var Message: TWMNotify);
begin
  if Message.NMHdr^.code = EN_REQUESTRESIZE then
  begin
    FTextHeight := PNotesResize(Message.NMHdr)^.Bounds.Height;
    Message.Result := 0;
  end
  else inherited;
end;

function TUpdateNotesEdit.MeasureHeight: Integer;
var Bounds: TRect;
begin
  // A previously collapsed editor can retain its initial narrow formatting
  // rectangle. Force native reflow at the final width before requesting the
  // content height; old control height must not become a minimum document size.
  Height := 1;
  Bounds := Rect(0, 0, ClientWidth, 1);
  Perform(EM_SETRECT, 0, LPARAM(@Bounds));
  FTextHeight := 0;
  Perform(EM_SETEVENTMASK, 0, Perform(EM_GETEVENTMASK, 0, 0) or ENM_REQUESTRESIZE);
  Perform(EM_REQUESTRESIZE, 0, 0);
  Result := Max(MulDiv(42, CurrentPPI, 96), FTextHeight + MulDiv(8, CurrentPPI, 96));
end;

procedure TUpdateNotesEdit.WndProc(var Message: TMessage);
begin
  if (Message.Msg = WM_MOUSEWHEEL) and Assigned(FView) then
  begin
    FView.ScrollWheel(SmallInt(HiWord(Message.WParam)),
      (LoWord(Message.WParam) and MK_CONTROL) <> 0);
    Message.Result := 1;
  end
  else inherited;
end;

procedure TUpdateNotesView.ScrollWheel(Delta: Integer; Zoom: Boolean);
var Lines: UINT; Step: Integer;
begin
  if Delta = 0 then Exit;
  if Zoom then
  begin
    if Delta > 0 then ZoomPercent := FZoomPercent + 10
    else ZoomPercent := FZoomPercent - 10;
    Exit;
  end;
  Lines := 3;
  SystemParametersInfo(SPI_GETWHEELSCROLLLINES, 0, @Lines, 0);
  if Lines = WHEEL_PAGESCROLL then Step := Max(1, ClientHeight - 30)
  else Step := MulDiv(20 * Integer(Min(Lines, 100)), CurrentPPI, 96);
  VertScrollBar.Position := VertScrollBar.Position - MulDiv(Delta, Step, WHEEL_DELTA);
end;

function TUpdateNotesView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  ScrollWheel(WheelDelta, ssCtrl in Shift);
  Result := True;
end;

procedure TUpdateNotesView.BeginDisplayUpdate;
begin
  FLoading := True;
  DisableAlign;
  FRedrawDisabled := HandleAllocated and IsWindowVisible(Handle);
  if FRedrawDisabled then SendMessage(Handle, WM_SETREDRAW, 0, 0);
end;

procedure TUpdateNotesView.EndDisplayUpdate;
begin
  EnableAlign;
  FLoading := False;
  LayoutSections;
  if FRedrawDisabled then
  begin
    SendMessage(Handle, WM_SETREDRAW, 1, 0);
    RedrawWindow(Handle, nil, 0, RDW_INVALIDATE or RDW_ALLCHILDREN);
  end;
  FRedrawDisabled := False;
end;

procedure TUpdateNotesView.SetZoomPercent(Value: Integer);
var I, Start, Selection: Integer;
begin
  Value := EnsureRange(Value, 80, 200);
  if Value = FZoomPercent then Exit;
  BeginDisplayUpdate;
  try
    FZoomPercent := Value;
    FMore.Font.Size := MulDiv(12, Value, 100);
    for I := 0 to High(FSections) do
    begin
      Start := FSections[I].Body.SelStart; Selection := FSections[I].Body.SelLength;
      FSections[I].Body.Font.Size := MulDiv(10, Value, 100);
      FSections[I].Header.Font.Size := MulDiv(12, Value, 100);
      LoadUpdateNotes(FSections[I].Body, FSections[I].Notes, Value);
      FSections[I].LoadedZoomPercent := Value; FSections[I].BodyHeight := 0;
      FSections[I].Body.SelStart := Start; FSections[I].Body.SelLength := Selection;
    end;
  finally EndDisplayUpdate; end;
  if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
end;

function TUpdateNotesView.SectionCount: Integer;
begin Result := Length(FSections); end;

function TUpdateNotesView.SectionHeader(Index: Integer): TButton;
begin Result := FSections[Index].Header; end;

function TUpdateNotesView.SectionNotes(Index: Integer): TRichEdit;
begin Result := FSections[Index].Body; end;

function TUpdateNotesView.IsExpanded(Index: Integer): Boolean;
begin Result := FSections[Index].Expanded; end;

procedure TUpdateNotesView.SetExpanded(Index: Integer; Value: Boolean);
begin
  if (Index < 0) or (Index >= Length(FSections)) then Exit;
  if FSections[Index].Expanded = Value then Exit;
  if not Value and FSections[Index].Body.Focused then
    FSections[Index].Header.SetFocus;
  BeginDisplayUpdate;
  try
  FSections[Index].Expanded := Value;
  finally EndDisplayUpdate; end;
  if FSections[Index].Header.Focused then HeaderFocused(FSections[Index].Header);
end;

procedure TUpdateNotesView.Toggle(Sender: TObject);
var Index: Integer;
begin
  Index := TControl(Sender).Tag;
  if (Index >= 0) and (Index < Length(FSections)) then
    SetExpanded(Index, not FSections[Index].Expanded);
end;

procedure TUpdateNotesView.MoreFocused(Sender: TObject);
begin ScrollInView(FMore); end;

procedure TUpdateNotesView.ShowMore(Sender: TObject);
var FirstNew: Integer; FollowFocus: Boolean;
begin
  if FAppending or (Length(FSections)>=Length(FHistoryTitles)) then Exit;
  FirstNew := Length(FSections); FollowFocus := FMore.Focused;
  FShownLimit := Min(Length(FHistoryTitles), FirstNew + 3);
  FAppending := True;
  try Load(FLastNotes); finally FAppending := False; end;
  // Continue keyboard navigation at the newly added releases, including the
  // final batch where the More button disappears.
  if FollowFocus and (FirstNew<Length(FSections)) and FSections[FirstNew].Header.CanFocus then
    FSections[FirstNew].Header.SetFocus;
end;

procedure TUpdateNotesView.HeaderFocused(Sender: TObject);
var Header: TButton; Top, Bottom: Integer;
begin
  Header := TButton(Sender);
  Top := Header.Parent.Top + Header.Top;
  Bottom := Top + Header.Height;
  if Top < 0 then VertScrollBar.Position := VertScrollBar.Position + Top
  else if Bottom > ClientHeight then
    VertScrollBar.Position := VertScrollBar.Position + Bottom - ClientHeight;
end;

procedure TUpdateNotesView.Resize;
begin
  inherited;
  if not FLoading then LayoutSections;
end;

procedure TUpdateNotesView.LayoutSections;
var I, Top, Width, Height, HeaderHeight, Padding, Pass, LayoutPPI: Integer;
  Measure: Vcl.Graphics.TBitmap; Bounds: TRect;
begin
  if FLoading or FLayouting then Exit;
  FLayouting := True; Measure := Vcl.Graphics.TBitmap.Create;
  try
    // A single scrollbar covers every expanded release. Reflow once more if
    // adding that scrollbar changes the available width; never recurse.
    for Pass := 1 to 2 do
    begin
    Top := -VertScrollBar.Position; Width := ClientWidth;
    LayoutPPI := Font.PixelsPerInch; if LayoutPPI <= 0 then LayoutPPI := CurrentPPI;
    Padding := MulDiv(8, LayoutPPI, 96);
    for I := 0 to High(FSections) do
    begin
      FSections[I].Panel.Width := Width;
      FSections[I].Body.Width := Max(1, Width - 2 * Padding);
      FSections[I].Body.Visible := FSections[I].Expanded;
      if FSections[I].Expanded and ((FSections[I].BodyHeight = 0) or
        (FSections[I].MeasuredWidth <> FSections[I].Body.ClientWidth) or
        (FSections[I].MeasuredPPI <> LayoutPPI)) then
      begin
        FSections[I].BodyHeight := TUpdateNotesEdit(FSections[I].Body).MeasureHeight;
        FSections[I].MeasuredWidth := FSections[I].Body.ClientWidth;
        FSections[I].MeasuredPPI := LayoutPPI;
      end;
      if FSections[I].Expanded then
      begin
        FSections[I].Header.Caption := '▾  ' + FSections[I].Title + ' (развёрнуто)';
        FSections[I].Header.Hint := 'Enter или пробел — свернуть этот выпуск.';
      end
      else
      begin
        FSections[I].Header.Caption := '▸  ' + FSections[I].Title + ' (свёрнуто)';
        FSections[I].Header.Hint := 'Enter или пробел — развернуть этот выпуск.';
      end;
      Measure.Canvas.Font.Assign(FSections[I].Header.Font);
      Bounds := Rect(0,0,Max(1,Width-2*Padding-MulDiv(24,LayoutPPI,96)),0);
      DrawText(Measure.Canvas.Handle,PChar(FSections[I].Header.Caption),
        Length(FSections[I].Header.Caption),Bounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      HeaderHeight := Max(MulDiv(MulDiv(34,FZoomPercent,100),LayoutPPI,96),
        Bounds.Height + MulDiv(16,LayoutPPI,96));
      Height := HeaderHeight;
      if FSections[I].Expanded then Inc(Height, FSections[I].BodyHeight);
      FSections[I].Panel.SetBounds(0, Top, Width, Height);
      FSections[I].Header.SetBounds(Padding, 0, Max(0, Width - 2 * Padding), HeaderHeight - 1);
      FSections[I].Body.SetBounds(Padding, HeaderHeight, Max(0, Width - 2 * Padding),
        FSections[I].BodyHeight);
      FSections[I].Body.Visible := FSections[I].Expanded;
      Inc(Top, Height);
    end;
    if Assigned(FMore) and FMore.Visible then
    begin
      FMore.SetBounds(Padding, Top + Padding, Max(1,Width-2*Padding),
        MulDiv(MulDiv(38,FZoomPercent,100),LayoutPPI,96));
      Inc(Top,FMore.Height+2*Padding);
    end;
    VertScrollBar.Range := Max(0, Top + VertScrollBar.Position);
    if ClientWidth = Width then Break;
    end;
  finally Measure.Free; FLayouting := False; end;
end;

procedure TUpdateNotesView.Load(const Notes: string);
var Lines, Titles, Bodies: TStringList; Line, Title, Body, Text: string;
  I, J, FocusedSection, RestoreSection, SpareIndex, VisibleCount: Integer; FocusedTitle: string; Separator: TBevel;
  OldTitles: TArray<string>; OldExpanded: TArray<Boolean>;
  ReloadBody, NewControls, MoreHadFocus, KeepCount: Boolean;
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted: UInt64;{$ENDIF}
  procedure SaveSection;
  begin
    if (Title = '') and (Body.Trim = '') then Exit;
    if Title = '' then Title := 'Список изменений';
    Titles.Add(Title); Bodies.Add(Body.Trim); Title := ''; Body := '';
  end;
begin
  if not FAppending and (FLastNotes = Notes) and (Length(FSections) > 0) then Exit;
  MoreHadFocus := FMore.Focused;
  FocusedSection := -1; FocusedTitle := '';
  SetLength(OldTitles,Length(FSections)); SetLength(OldExpanded,Length(FSections));
  for I := 0 to High(FSections) do
  begin OldTitles[I]:=FSections[I].Title; OldExpanded[I]:=FSections[I].Expanded; end;
  for I := 0 to High(FSections) do
    if FSections[I].Header.Focused or FSections[I].Body.Focused then
    begin FocusedSection := I; FocusedTitle := FSections[I].Title; Break; end;
  Lines := TStringList.Create; Titles := TStringList.Create; Bodies := TStringList.Create;
  BeginDisplayUpdate;
  try
    {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted:=GetTickCount64;{$ENDIF}
    if FAppending then
    begin
      for I:=0 to High(FHistoryTitles) do begin Titles.Add(FHistoryTitles[I]); Bodies.Add(FHistoryBodies[I]); end;
    end
    else
    begin
    Lines.Text := AdjustLineBreaks(Notes);
    Title := ''; Body := '';
    for Line in Lines do
    begin
      Text := TRegEx.Replace(Line.Trim, '^#{1,6}\s+', '');
      if IsReleaseHeading(Text) then
      begin
        if Title <> '' then SaveSection;
        Title := Text;
      end
      else Body := Body + Line + sLineBreak;
    end;
    SaveSection;
    if Titles.Count = 0 then
    begin Titles.Add('Список изменений'); Bodies.Add('История ещё не получена. Нажмите кнопку проверки обновлений.'); end;
    KeepCount := (Length(FHistoryTitles)>0) and (FHistoryTitles[0]=Titles[0]);
    if not KeepCount then
    begin
      FShownLimit:=3;
      if FocusedTitle<>'' then
      begin J:=Titles.IndexOf(FocusedTitle); if J>=0 then FShownLimit:=Max(3,J+1); end;
    end;
    SetLength(FHistoryTitles,Titles.Count); SetLength(FHistoryBodies,Bodies.Count);
    for I:=0 to Titles.Count-1 do begin FHistoryTitles[I]:=Titles[I]; FHistoryBodies[I]:=Bodies[I]; end;
    end;
    VisibleCount := Min(FShownLimit,Titles.Count);
    {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(UpdateNotesParseMS,GetTickCount64-ProfileStarted); ProfileStarted:=GetTickCount64;{$ENDIF}
    // Reuse native controls while switching components. Reparenting the first
    // RichEdit and recreating every header also recreates their native windows.
    // Keep inactive tail controls for another component with a longer history.
    // The pool is bounded by the largest history shown in this view.
    for I := VisibleCount to High(FSections) do
    begin
      FSections[I].Panel.Visible := False;
      FSections[I].Header.Name := '';
      SpareIndex := Length(FSpareSections);
      SetLength(FSpareSections, SpareIndex + 1);
      FSpareSections[SpareIndex] := FSections[I];
    end;
    SetLength(FSections, VisibleCount);
    NewControls := False;
    if not FAppending and (VertScrollBar.Position <> 0) then VertScrollBar.Position := 0;
    for I := 0 to VisibleCount - 1 do
    begin
      if (FSections[I].Panel = nil) and (Length(FSpareSections) > 0) then
      begin
        SpareIndex := High(FSpareSections);
        FSections[I] := FSpareSections[SpareIndex];
        SetLength(FSpareSections, SpareIndex);
      end;
      ReloadBody := (FSections[I].Panel = nil) or (FSections[I].Notes <> Bodies[I]) or
        (FSections[I].LoadedZoomPercent <> FZoomPercent);
      FSections[I].Title := Titles[I];
      FSections[I].Notes := Bodies[I];
      FSections[I].Expanded := I = 0;
      for J := 0 to High(OldTitles) do
        if OldTitles[J]=Titles[I] then begin FSections[I].Expanded:=OldExpanded[J]; Break; end;
      if FSections[I].Panel = nil then
      begin
      NewControls := True;
      FSections[I].Panel := TPanel.Create(Self);
      FSections[I].Panel.Parent := Self;
      FSections[I].Panel.BevelOuter := bvNone;
      FSections[I].Panel.Color := clWindow;
      // Release panels may be many screens high; only buffer the viewport.
      FSections[I].Panel.ParentDoubleBuffered := False;
      FSections[I].Panel.DoubleBuffered := False;
      FSections[I].Panel.TabOrder := I;
      FSections[I].Header := TButton.Create(FSections[I].Panel);
      FSections[I].Header.Name := 'UpdateReleaseHeader' + IntToStr(I);
      FSections[I].Header.Parent := FSections[I].Panel;
      FSections[I].Header.TabOrder := 0;
      FSections[I].Header.TabStop := True;
      FSections[I].Header.WordWrap := True;
      FSections[I].Header.ShowHint := True;
      FSections[I].Header.OnEnter := HeaderFocused;
      FSections[I].Header.Font.Name := 'Segoe UI';
      FSections[I].Header.Font.Size := MulDiv(12, FZoomPercent, 100);
      FSections[I].Header.Font.Style := [fsBold];
      FSections[I].Header.Cursor := crHandPoint;
      FSections[I].Header.Tag := I;
      FSections[I].Header.OnClick := Toggle;
      Separator := TBevel.Create(FSections[I].Panel);
      Separator.Parent := FSections[I].Panel;
      Separator.Align := alTop; Separator.Height := 1; Separator.Shape := bsTopLine;
      if I = 0 then FSections[I].Body := FPrimaryNotes
      else FSections[I].Body := TUpdateNotesEdit.Create(FSections[I].Panel);
      TUpdateNotesEdit(FSections[I].Body).FView := Self;
      FSections[I].Body.Parent := FSections[I].Panel;
      FSections[I].Body.TabOrder := 1;
      FSections[I].Body.ReadOnly := True;
      FSections[I].Body.MaxLength := 400000;
      FSections[I].Body.BorderStyle := bsNone;
      FSections[I].Body.ScrollBars := ssNone;
      FSections[I].Body.WordWrap := True;
      FSections[I].Body.Font.Name := 'Segoe UI';
      FSections[I].Body.Font.Size := MulDiv(10, FZoomPercent, 100);
      FSections[I].Body.Width := Max(0, ClientWidth - 16);
      end;
      FSections[I].Panel.TabOrder := I;
      FSections[I].Panel.Visible := True;
      FSections[I].Header.Name := 'UpdateReleaseHeader' + IntToStr(I);
      FSections[I].Header.Tag := I;
      FSections[I].Header.Font.Size := MulDiv(12, FZoomPercent, 100);
      FSections[I].Body.Font.Size := MulDiv(10, FZoomPercent, 100);
      {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(UpdateNotesControlsMS,GetTickCount64-ProfileStarted); ProfileStarted:=GetTickCount64;{$ENDIF}
      if ReloadBody then
      begin
        FSections[I].Body.Width := Max(1, ClientWidth - 2 * MulDiv(8, CurrentPPI, 96));
        LoadUpdateNotes(FSections[I].Body, Bodies[I], FZoomPercent);
        FSections[I].LoadedZoomPercent := FZoomPercent;
        FSections[I].BodyHeight := 0;
      end;
      {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(UpdateNotesFormatMS,GetTickCount64-ProfileStarted); ProfileStarted:=GetTickCount64;{$ENDIF}
    end;
    FLastNotes := Notes;
    FMore.Caption := 'Показать ещё ' + IntToStr(Min(3,Titles.Count-VisibleCount));
    FMore.TabOrder := VisibleCount; FMore.TabStop := Titles.Count>VisibleCount;
    FMore.Visible := FMore.TabStop;
    if NewControls then ApplyTheme;
    {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(UpdateNotesThemeMS,GetTickCount64-ProfileStarted); ProfileStarted:=GetTickCount64;{$ENDIF}
  finally
    EndDisplayUpdate;
    {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(UpdateNotesLayoutMS,GetTickCount64-ProfileStarted);{$ENDIF}
    Lines.Free; Titles.Free; Bodies.Free;
  end;
  if not FAppending and MoreHadFocus then
  begin
    if FMore.Visible and FMore.CanFocus then FMore.SetFocus
    else if (Length(FSections)>0) and FSections[High(FSections)].Header.CanFocus then
      FSections[High(FSections)].Header.SetFocus;
  end;
  if (FocusedSection >= 0) and (Length(FSections) > 0) then
  begin
    RestoreSection := Min(FocusedSection,High(FSections));
    for I := 0 to High(FSections) do
      if FSections[I].Title = FocusedTitle then begin RestoreSection := I; Break; end;
    if FSections[RestoreSection].Header.CanFocus then
      FSections[RestoreSection].Header.SetFocus;
  end;
end;

end.
