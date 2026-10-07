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
    Header: TLabel;
    Body: TRichEdit;
    Title, Notes: string;
    Expanded: Boolean;
    BodyHeight: Integer;
  end;

  TUpdateNotesView = class(TScrollBox)
  private
    FSections: array of TUpdateNotesSection;
    FPrimaryNotes: TRichEdit;
    FLoading, FLayouting, FRedrawDisabled: Boolean;
    FLastNotes: string;
    FZoomPercent: Integer;
    FOnZoomChanged: TNotifyEvent;
    procedure BeginDisplayUpdate;
    procedure EndDisplayUpdate;
    procedure SetZoomPercent(Value: Integer);
    procedure Toggle(Sender: TObject);
    procedure LayoutSections;
  protected
    procedure Resize; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Load(const Notes: string);
    function SectionCount: Integer;
    function SectionHeader(Index: Integer): TLabel;
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

implementation

uses System.SysUtils, System.Math, System.RegularExpressions, System.NetEncoding,
  Vcl.Graphics, Winapi.Windows, Winapi.RichEdit, Winapi.CommCtrl;

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
  Result := TRegEx.IsMatch(Text, '^(?:HomeLib Ru |SQLite |SumatraPDF |v)?[0-9]+\.[0-9]+(?:\.[0-9]+)*(?:_pre[0-9]+(?:\.[0-9]+)*)?(?: — [0-9]{2}\.[0-9]{2}\.[0-9]{4})?$');
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
    Result := '\pard\f1\fs16\b0\cf1\li0\fi0\sb60\sa140 ' +
      RTFText(StringOfChar('─', Count)) + '\par ';
  finally Bitmap.Free; end;
end;

procedure LoadUpdateNotes(Control: TRichEdit; const Notes: string; ZoomPercent: Integer);
var Lines: TStringList; Stream: TStringStream; Builder: TStringBuilder;
  Line, Text, Divider: string; Heading, ListItem: TMatch; Level, Indent: Integer;
  Version, SeenVersion: Boolean;
begin
  Lines := TStringList.Create; Builder := TStringBuilder.Create;
  try
    Text := TRegEx.Replace(Notes, '\[([^\]]+)\]\((https://[^)]+)\)', '$1 ($2)');
    if Text.Trim = '' then Text := 'Автор не опубликовал описание изменений этого выпуска.';
    Lines.Text := AdjustLineBreaks(Text); SeenVersion := False; Divider := DividerRTF(Control);
    Builder.Append('{\rtf1\ansi\deff0\uc1{\fonttbl{\f0 Segoe UI;}{\f1 Consolas;}}{\colortbl;\red140\green140\blue140;}');
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
      Builder.Append('\pard\f0\fs').Append(MulDiv(20, ZoomPercent, 100)).Append('\b0\cf0\li0\fi0\sb0\sa80 ');
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
  FZoomPercent := 100;
  Color := clWindow;
  DoubleBuffered := True;
  HorzScrollBar.Visible := False;
  VertScrollBar.Tracking := True;
  FPrimaryNotes := TUpdateNotesEdit.Create(Self);
  TUpdateNotesEdit(FPrimaryNotes).FView := Self;
  FPrimaryNotes.Parent := Self;
  FPrimaryNotes.Visible := False;
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
    for I := 0 to High(FSections) do
    begin
      Start := FSections[I].Body.SelStart; Selection := FSections[I].Body.SelLength;
      FSections[I].Body.Font.Size := MulDiv(10, Value, 100);
      FSections[I].Header.Font.Size := MulDiv(12, Value, 100);
      LoadUpdateNotes(FSections[I].Body, FSections[I].Notes, Value);
      FSections[I].Body.SelStart := Start; FSections[I].Body.SelLength := Selection;
    end;
  finally EndDisplayUpdate; end;
  if Assigned(FOnZoomChanged) then FOnZoomChanged(Self);
end;

function TUpdateNotesView.SectionCount: Integer;
begin Result := Length(FSections); end;

function TUpdateNotesView.SectionHeader(Index: Integer): TLabel;
begin Result := FSections[Index].Header; end;

function TUpdateNotesView.SectionNotes(Index: Integer): TRichEdit;
begin Result := FSections[Index].Body; end;

function TUpdateNotesView.IsExpanded(Index: Integer): Boolean;
begin Result := FSections[Index].Expanded; end;

procedure TUpdateNotesView.SetExpanded(Index: Integer; Value: Boolean);
begin
  if (Index < 0) or (Index >= Length(FSections)) then Exit;
  if FSections[Index].Expanded = Value then Exit;
  BeginDisplayUpdate;
  try
  FSections[Index].Expanded := Value;
  finally EndDisplayUpdate; end;
end;

procedure TUpdateNotesView.Toggle(Sender: TObject);
var Index: Integer;
begin
  Index := TControl(Sender).Tag;
  if (Index >= 0) and (Index < Length(FSections)) then
    SetExpanded(Index, not FSections[Index].Expanded);
end;

procedure TUpdateNotesView.Resize;
begin
  inherited;
  if not FLoading then LayoutSections;
end;

procedure TUpdateNotesView.LayoutSections;
var I, Top, Width, Height, HeaderHeight, Padding, Pass: Integer;
begin
  if FLoading or FLayouting then Exit;
  FLayouting := True;
  try
    // A single scrollbar covers every expanded release. Reflow once more if
    // adding that scrollbar changes the available width; never recurse.
    for Pass := 1 to 2 do
    begin
    Top := -VertScrollBar.Position; Width := ClientWidth;
    HeaderHeight := MulDiv(MulDiv(34, FZoomPercent, 100), CurrentPPI, 96);
    Padding := MulDiv(8, CurrentPPI, 96);
    for I := 0 to High(FSections) do
    begin
      FSections[I].Panel.Width := Width;
      FSections[I].Body.Width := Max(1, Width - 2 * Padding);
      FSections[I].Body.Visible := FSections[I].Expanded;
      if FSections[I].Expanded then
        FSections[I].BodyHeight := TUpdateNotesEdit(FSections[I].Body).MeasureHeight;
      Height := HeaderHeight;
      if FSections[I].Expanded then Inc(Height, FSections[I].BodyHeight);
      FSections[I].Panel.SetBounds(0, Top, Width, Height);
      FSections[I].Header.SetBounds(Padding, 0, Max(0, Width - 2 * Padding), HeaderHeight - 1);
      if FSections[I].Expanded then FSections[I].Header.Caption := '▾  ' + FSections[I].Title
      else FSections[I].Header.Caption := '▸  ' + FSections[I].Title;
      FSections[I].Body.SetBounds(Padding, HeaderHeight, Max(0, Width - 2 * Padding),
        FSections[I].BodyHeight);
      FSections[I].Body.Visible := FSections[I].Expanded;
      Inc(Top, Height);
    end;
    VertScrollBar.Range := Max(0, Top + VertScrollBar.Position);
    if ClientWidth = Width then Break;
    end;
  finally FLayouting := False; end;
end;

procedure TUpdateNotesView.Load(const Notes: string);
var Lines, Titles, Bodies: TStringList; Line, Title, Body, Text: string;
  I: Integer; Separator: TBevel;
  procedure SaveSection;
  begin
    if (Title = '') and (Body.Trim = '') then Exit;
    if Title = '' then Title := 'Список изменений';
    Titles.Add(Title); Bodies.Add(Body.Trim); Title := ''; Body := '';
  end;
begin
  if (FLastNotes = Notes) and (Length(FSections) > 0) then Exit;
  Lines := TStringList.Create; Titles := TStringList.Create; Bodies := TStringList.Create;
  BeginDisplayUpdate;
  try
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
    // Keep the first editor stable for selection/copying and regression probes.
    FPrimaryNotes.Parent := Self;
    FPrimaryNotes.Visible := False;
    for I := 0 to High(FSections) do FSections[I].Panel.Free;
    SetLength(FSections, Titles.Count);
    VertScrollBar.Position := 0;
    for I := 0 to Titles.Count - 1 do
    begin
      FSections[I].Title := Titles[I];
      FSections[I].Notes := Bodies[I];
      FSections[I].Expanded := I = 0;
      FSections[I].Panel := TPanel.Create(Self);
      FSections[I].Panel.Parent := Self;
      FSections[I].Panel.BevelOuter := bvNone;
      FSections[I].Panel.Color := clWindow;
      // Release panels may be many screens high; only buffer the viewport.
      FSections[I].Panel.ParentDoubleBuffered := False;
      FSections[I].Panel.DoubleBuffered := False;
      FSections[I].Header := TLabel.Create(FSections[I].Panel);
      FSections[I].Header.Parent := FSections[I].Panel;
      FSections[I].Header.AutoSize := False;
      FSections[I].Header.Layout := tlCenter;
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
      FSections[I].Body.ReadOnly := True;
      FSections[I].Body.MaxLength := 400000;
      FSections[I].Body.BorderStyle := bsNone;
      FSections[I].Body.ScrollBars := ssNone;
      FSections[I].Body.WordWrap := True;
      FSections[I].Body.Font.Name := 'Segoe UI';
      FSections[I].Body.Font.Size := MulDiv(10, FZoomPercent, 100);
      FSections[I].Body.Width := Max(0, ClientWidth - 16);
      LoadUpdateNotes(FSections[I].Body, Bodies[I], FZoomPercent);
    end;
    FLastNotes := Notes;
  finally
    EndDisplayUpdate;
    Lines.Free; Titles.Free; Bodies.Free;
  end;
end;

end.
