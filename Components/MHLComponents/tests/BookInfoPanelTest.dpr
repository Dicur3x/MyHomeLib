program BookInfoPanelTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  System.Types,
  System.IOUtils,
  Winapi.Windows,
  Winapi.Messages,
  Winapi.CommCtrl,
  Winapi.ActiveX,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.ComCtrls,
  Vcl.ExtCtrls,
  Vcl.StdCtrls,
  fictionbook_21 in '..\fictionbook_21.pas',
  unit_FB2Utils in '..\unit_FB2Utils.pas',
  BookInfoPanel in '..\BookInfoPanel.pas',
  MHLLinkLabel in '..\MHLLinkLabel.pas';

type
  TTestLinkItem = record
    Mask: Cardinal;
    Index: Integer;
    State: Cardinal;
    StateMask: Cardinal;
    ID: array[0..47] of WideChar;
    URL: array[0..2083] of WideChar;
  end;

  TTestLinkHit = record
    Point: TPoint;
    Item: TTestLinkItem;
  end;

  TLinkProbe = class
  public
    LastLink: string;
    procedure Clicked(Sender: TObject; const Link: string;
      LinkType: TSysLinkType);
  end;

procedure TLinkProbe.Clicked(Sender: TObject; const Link: string;
  LinkType: TSysLinkType);
begin
  LastLink := Link;
end;

var
  Report: TStringList;
  Failures: Integer;

procedure Check(Condition: Boolean; const Name: string);
begin
  if Condition then
    Report.Add('PASS ' + Name)
  else
  begin
    Report.Add('FAIL ' + Name);
    Inc(Failures);
  end;
end;

function PanelViewport(Panel: TInfoPanel): TScrollBox;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to Panel.ControlCount - 1 do
    if Panel.Controls[I] is TScrollBox then
      Exit(TScrollBox(Panel.Controls[I]));
end;

function PanelContent(Panel: TInfoPanel): TWinControl;
var
  Viewport: TScrollBox;
  I: Integer;
begin
  Result := nil;
  Viewport := PanelViewport(Panel);
  if not Assigned(Viewport) then Exit;
  for I := 0 to Viewport.ControlCount - 1 do
    if Viewport.Controls[I] is TPanel then
      Exit(TWinControl(Viewport.Controls[I]));
end;

function FindPanelLink(Panel: TInfoPanel; const Href: string): TMHLLinkLabel;
var
  I: Integer;
  Content: TWinControl;
begin
  Result := nil;
  Content := PanelContent(Panel);
  if not Assigned(Content) then Exit;
  for I := 0 to Content.ControlCount - 1 do
    if (Content.Controls[I] is TMHLLinkLabel) and
      (Pos('href="' + Href + '"', TMHLLinkLabel(Content.Controls[I]).Caption) > 0) then
      Exit(TMHLLinkLabel(Content.Controls[I]));
end;

function ShowLinkPoint(Link: TMHLLinkLabel; const P: TPoint): Boolean;
var
  Viewport: TScrollBox;
  Parent: TWinControl;
  PointInViewport: TPoint;
begin
  Parent := Link.Parent;
  while Assigned(Parent) and not (Parent is TScrollBox) do Parent := Parent.Parent;
  if not Assigned(Parent) then Exit(False);
  Viewport := TScrollBox(Parent);
  PointInViewport := Viewport.ScreenToClient(Link.ClientToScreen(P));
  Viewport.VertScrollBar.Position := Viewport.VertScrollBar.Position +
    PointInViewport.Y - Viewport.ClientHeight div 2;
  PointInViewport := Viewport.ScreenToClient(Link.ClientToScreen(P));
  Result := (PointInViewport.X >= 0) and (PointInViewport.Y >= 0) and
    (PointInViewport.X < Viewport.ClientWidth) and
    (PointInViewport.Y < Viewport.ClientHeight);
end;

function NativeFontHeight(Link: TMHLLinkLabel): Integer;
var
  FontInfo: TLogFont;
  NativeFont: HFONT;
begin
  Result := 0;
  if not Assigned(Link) then Exit;
  NativeFont := HFONT(SendMessage(Link.Handle, WM_GETFONT, 0, 0));
  FillChar(FontInfo, SizeOf(FontInfo), 0);
  if GetObject(NativeFont, SizeOf(FontInfo), @FontInfo) <> 0 then
    Result := FontInfo.lfHeight;
end;

function NativeLineHeight(Link: TMHLLinkLabel): Integer;
var
  IdealSize: TSize;
begin
  Result := 0;
  if not Assigned(Link) then Exit;
  FillChar(IdealSize, SizeOf(IdealSize), 0);
  SendMessage(Link.Handle, LM_GETIDEALSIZE, 32767, LPARAM(@IdealSize));
  Result := IdealSize.cy;
end;

function ClickNativeLink(Link: TMHLLinkLabel; Index: Integer;
  const Expected: string; Probe: TLinkProbe): Boolean;
var
  X, Y: Integer;
  Hit: TTestLinkHit;
begin
  Result := False;
  Y := 2;
  while (Y < Link.Height) and not Result do
  begin
    X := 2;
    while (X < Link.Width) and not Result do
    begin
      FillChar(Hit, SizeOf(Hit), 0);
      Hit.Point := Point(X, Y);
      Hit.Item.Index := -1;
      if (SendMessage(Link.Handle, LM_HITTEST, 0, LPARAM(@Hit)) <> 0) and
        (Hit.Item.Index = Index) and ShowLinkPoint(Link, Point(X, Y)) then
      begin
        Probe.LastLink := '';
        SendMessage(Link.Handle, WM_LBUTTONDOWN, MK_LBUTTON, MakeLParam(X, Y));
        SendMessage(Link.Handle, WM_LBUTTONUP, 0, MakeLParam(X, Y));
        Result := Probe.LastLink = Expected;
      end;
      Inc(X, 4);
    end;
    Inc(Y, 4);
  end;
end;

procedure CheckLinks(Panel: TInfoPanel; Probe: TLinkProbe;
  const Scenario: string);
const
  ExpectedLinks: array[0..2] of string = ('101', '201', 'sf');
var
  Content: TWinControl;
  Link: TMHLLinkLabel;
  J, K, LinkIndex, ExpectedIndex, IdealHeight: Integer;
  Buffer: array[0..4095] of Char;
  IdealSize: TSize;
  FontInfo: TLogFont;
begin
  LinkIndex := 0;
  Content := PanelContent(Panel);
  Check(Assigned(Content), Scenario + ' scroll content exists');
  if not Assigned(Content) then Exit;
  for J := 0 to Content.ControlCount - 1 do
    if Content.Controls[J] is TMHLLinkLabel then
    begin
      Link := TMHLLinkLabel(Content.Controls[J]);
      if not Link.Visible then Continue;
      ExpectedIndex := -1;
      for K := Low(ExpectedLinks) to High(ExpectedLinks) do
        if Pos('href="' + ExpectedLinks[K] + '"', Link.Caption) > 0 then
          ExpectedIndex := K;
      if ExpectedIndex < 0 then Continue;
      GetWindowText(Link.Handle, Buffer, Length(Buffer));
      FillChar(IdealSize, SizeOf(IdealSize), 0);
      IdealHeight := SendMessage(Link.Handle, LM_GETIDEALSIZE,
        Link.Width, LPARAM(@IdealSize));
      Report.Add(Format('%s link=%d rect=%d,%d,%d,%d ideal=%d text=%s',
        [Scenario, LinkIndex, Link.Left, Link.Top, Link.Width,
        Link.Height, IdealHeight, string(Buffer)]));
      Check(Link.Visible and (Link.Width > 0) and (Link.Height > 0),
        Scenario + ' visible link ' + IntToStr(LinkIndex));
      Check((IdealHeight > 0) and (Link.Height >= IdealHeight),
        Scenario + ' complete link ' + IntToStr(LinkIndex));
      Check((Link.Left >= 0) and
        (Link.Left + Link.Width <= Content.ClientWidth),
        Scenario + ' horizontal bounds ' + IntToStr(LinkIndex));
      Check((Link.Top >= 0) and (Link.Top + Link.Height <= Content.ClientHeight),
        Scenario + ' complete row in scroll content ' + IntToStr(LinkIndex));
      Check(ShowLinkPoint(Link, Point(1, 1)) and
        ShowLinkPoint(Link, Point(Link.Width - 1, Link.Height - 1)),
        Scenario + ' row extremes reachable without viewport clipping ' + IntToStr(LinkIndex));
      Check(Link.Font.Size = Panel.Font.Size,
        Scenario + ' inherited font ' + IntToStr(LinkIndex));
      FillChar(FontInfo, SizeOf(FontInfo), 0);
      GetObject(Link.Font.Handle, SizeOf(FontInfo), @FontInfo);
      Check((NativeFontHeight(Link) <> 0) and
        (NativeFontHeight(Link) = FontInfo.lfHeight),
        Scenario + ' native font matches VCL ' + IntToStr(LinkIndex));
      Check(NativeLineHeight(Link) >= Abs(FontInfo.lfHeight),
        Scenario + ' native glyph layout uses chosen font ' + IntToStr(LinkIndex));
      for K := 0 to Content.ControlCount - 1 do
        if ((Content.Controls[K] is TMemo) or
          (Content.Controls[K] is TListView)) and Content.Controls[K].Visible then
          Check((Content.Controls[K].Height = 0) or
            (Content.Controls[K].Top >= Link.Top + Link.Height),
            Scenario + ' no annotation overlap ' + IntToStr(LinkIndex));
      Check(ClickNativeLink(Link, 0, ExpectedLinks[ExpectedIndex], Probe),
        Scenario + ' native click ' + IntToStr(LinkIndex));
      if ExpectedIndex = 1 then
      begin
        Check(Pos('<br>', LowerCase(string(Buffer))) = 0,
          Scenario + ' native series line break');
        Check(ClickNativeLink(Link, 1, '202', Probe),
          Scenario + ' second series native click');
      end;
      Inc(LinkIndex);
    end;
  Check(LinkIndex = 3, Scenario + ' three link controls');
end;

procedure FillPanel(Panel: TInfoPanel);
begin
  Panel.SetBookInfo('Test book',
    '<a href="101">Достоевский Фёдор Михайлович</a> <a href="102">Толстой Лев Николаевич</a>',
    '<a href="201">Собрание произведений русской литературы</a><br>' +
    '<a href="202">Библиотека мировой классической литературы</a>',
    '<a href="sf">Научная фантастика</a> <a href="adventure">Приключения</a>');
end;

procedure CheckPublisherSeries(Panel: TInfoPanel; Probe: TLinkProbe);
const
  PublisherText = 'Библиотека & коллекция <романы>; Издательская книжная серия (2)';
var
  J, GenreTop: Integer;
  Content: TWinControl;
  Publisher: TLabel;
  Genre: TMHLLinkLabel;
begin
  Panel.SetPublisherSeries(PublisherText);
  Publisher := nil;
  Genre := nil;
  Content := PanelContent(Panel);
  Check(Assigned(Content), 'publisher scroll content exists');
  if not Assigned(Content) then Exit;
  for J := 0 to Content.ControlCount - 1 do
  begin
    if (Content.Controls[J] is TLabel) and
      (TLabel(Content.Controls[J]).Caption = PublisherText) then
      Publisher := TLabel(Content.Controls[J]);
    if (Content.Controls[J] is TMHLLinkLabel) and
      (Pos('href="sf"', TMHLLinkLabel(Content.Controls[J]).Caption) > 0) then
      Genre := TMHLLinkLabel(Content.Controls[J]);
  end;
  Check(Assigned(Publisher) and Assigned(Genre), 'publisher row exists');
  if not Assigned(Publisher) or not Assigned(Genre) then
    Exit;
  Check(Publisher.Visible and not Publisher.ShowAccelChar,
    'publisher series shown as literal text');
  Check(Genre.Top >= Publisher.Top + Publisher.Height, 'publisher row does not overlap genres');
  GenreTop := Genre.Top;
  CheckLinks(Panel, Probe, 'publisher series');
  Panel.SetPublisherSeries('');
  Check(not Publisher.Visible and (Genre.Top < GenreTop), 'empty publisher row collapses');
  Panel.SetPublisherSeries(PublisherText);
  FillPanel(Panel);
  Check(not Publisher.Visible and (Publisher.Caption = ''), 'next book clears publisher series');
  Panel.SetPublisherSeries(PublisherText);
  Panel.Clear;
  Check(not Publisher.Visible and (Publisher.Caption = ''), 'clear resets publisher series');
  FillPanel(Panel);
end;

procedure CheckPublisherLinks(Panel: TInfoPanel; Probe: TLinkProbe);
const
  UnsafeTitle = 'Библиотека & <романы> </a><a href="999">чужая ссылка</a> <br>';
var
  Publisher, Genre: TMHLLinkLabel;
  Caption: string;
  Item: TTestLinkItem;
  RawSize, LiteralSize: TSize;
  GenreTop: Integer;
begin
  // Matches GetLinkList(..., LiteralTitles=True), whose producer is tested by MCP.
  Caption := '<a href="301">' +
    StringReplace(UnsafeTitle, '<', '<' + #$200B, [rfReplaceAll]) +
    '</a><br><a href="302">Вторая издательская серия</a>';
  Panel.SetPublisherSeriesLinks(Caption);
  Publisher := FindPanelLink(Panel, '301');
  Genre := FindPanelLink(Panel, 'sf');
  Check(Assigned(Publisher) and Assigned(Genre), 'publisher link controls exist');
  if not Assigned(Publisher) or not Assigned(Genre) then Exit;
  Check(Publisher.Visible, 'publisher link row is visible');
  Check((GetWindowLong(Publisher.Handle, GWL_STYLE) and $00000004) <> 0,
    'publisher native LWS_NOPREFIX preserves ampersands');
  Check((Pos(' & ', Publisher.Caption) > 0) and
    (Pos('<' + #$200B + 'br>', Publisher.Caption) > 0) and
    (Pos(sLineBreak, Publisher.Caption) > 0),
    'literal title markup is distinct from actual row separator');
  FillChar(Item, SizeOf(Item), 0);
  Item.Mask := LIF_ITEMINDEX or LIF_URL;
  Item.Index := 0;
  Check((SendMessage(Publisher.Handle, LM_GETITEM, 0, LPARAM(@Item)) <> 0) and
    (string(PWideChar(@Item.URL[0])) = '301'), 'publisher first native destination');
  FillChar(Item, SizeOf(Item), 0);
  Item.Mask := LIF_ITEMINDEX or LIF_URL;
  Item.Index := 1;
  Check((SendMessage(Publisher.Handle, LM_GETITEM, 0, LPARAM(@Item)) <> 0) and
    (string(PWideChar(@Item.URL[0])) = '302'), 'publisher second native destination');
  FillChar(Item, SizeOf(Item), 0);
  Item.Mask := LIF_ITEMINDEX or LIF_URL;
  Item.Index := 2;
  Check(SendMessage(Publisher.Handle, LM_GETITEM, 0, LPARAM(@Item)) = 0,
    'literal title cannot inject a third native link');
  Check(ClickNativeLink(Publisher, 0, '301', Probe), 'publisher first native click');
  Check(ClickNativeLink(Publisher, 1, '302', Probe), 'publisher second native click');
  Check(Genre.Top >= Publisher.Top + Publisher.Height,
    'publisher links do not overlap genres');
  Check((Publisher.Top + Publisher.Height <= Publisher.Parent.ClientHeight) and
    ShowLinkPoint(Publisher, Point(1, 1)) and
    ShowLinkPoint(Publisher, Point(Publisher.Width - 1, Publisher.Height - 1)),
    'long publisher row remains reachable through viewport');
  CheckLinks(Panel, Probe, 'clickable publisher series');
  GenreTop := Genre.Top;
  Panel.SetPublisherSeriesLinks('');
  Check(not Publisher.Visible and (Genre.Top < GenreTop),
    'empty publisher link row collapses');

  Panel.SetPublisherSeriesLinks('<a href="301">A & <Classics></a>');
  FillChar(RawSize, SizeOf(RawSize), 0);
  SendMessage(Publisher.Handle, LM_GETIDEALSIZE, 4096, LPARAM(@RawSize));
  Panel.SetPublisherSeriesLinks('<a href="301">A & <' + #$200B + 'Classics></a>');
  FillChar(LiteralSize, SizeOf(LiteralSize), 0);
  SendMessage(Publisher.Handle, LM_GETIDEALSIZE, 4096, LPARAM(@LiteralSize));
  Check((RawSize.cx > 0) and (RawSize.cx = LiteralSize.cx) and
    (RawSize.cy = LiteralSize.cy), 'native literal guard has no visible glyph width');
  Panel.SetPublisherSeries('plain publisher title');
  Check(not Publisher.Visible and (Publisher.Caption = ''),
    'plain publisher row replaces links');
  Panel.SetPublisherSeriesLinks(Caption);
  FillPanel(Panel);
  Check(not Publisher.Visible and (Publisher.Caption = ''),
    'next book clears publisher links');
  Panel.SetPublisherSeriesLinks(Caption);
  Panel.Clear;
  Check(not Publisher.Visible and (Publisher.Caption = ''),
    'clear resets publisher links');
  FillPanel(Panel);
end;

procedure CheckPublisherMetadata;
  function ReadPublisherSeries(const Description: string;
    const IncludeBody: Boolean = True): string;
  var
    XML: string;
    Stream: TStringStream;
    Book: IXMLFictionBook;
  begin
    XML := '<?xml version="1.0" encoding="utf-8"?>' +
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' +
      '<description>' + Description + '</description>';
    if IncludeBody then
      XML := XML + '<body><section><p>Text</p></section></body>';
    XML := XML + '</FictionBook>';
    Stream := TStringStream.Create(XML, TEncoding.UTF8);
    try
      Book := fictionbook_21.LoadFictionBook(Stream);
      Result := GetBookPublisherSeries(Book);
    finally
      Stream.Free;
    end;
  end;

begin
  CoInitialize(nil);
  try
    Check(GetBookPublisherSeries(nil) = '', 'publisher metadata handles nil book');
    Check(ReadPublisherSeries('<title-info><sequence name="Author cycle"/>' +
      '</title-info>') = '', 'author cycles are not publisher series');
    Check(ReadPublisherSeries('<publish-info>' +
      '<sequence name="  Classics &amp; &lt;More&gt;  " number="7"/>' +
      '<sequence name="Another series"/>' +
      '</publish-info>') = 'Classics & <More> (7); Another series',
      'multiple publisher series preserve literal titles and optional numbers');
    Check(ReadPublisherSeries('<publish-info>' +
      '<sequence name="Invalid" number="oops"/>' +
      '<sequence name="Zero" number="0"/>' +
      '<sequence name="Negative" number="-2"/>' +
      '<sequence name="Overflow" number="999999999999999999999"/>' +
      '<sequence name="   " number="8"/>' +
      '</publish-info>') = 'Invalid; Zero; Negative; Overflow',
      'invalid publisher numbers and empty titles are nonfatal');
    Check(ReadPublisherSeries('<publish-info>' +
      '<sequence name="Parent" number="1">' +
      '<sequence name="Child" number="2"/></sequence>' +
      '</publish-info>') = 'Parent (1); Child (2)',
      'nested publisher sequences are included');
    Check(ReadPublisherSeries('<publish-info>' +
      '<sequence name="FBD series" number="4"/>' +
      '</publish-info>', False) = 'FBD series (4)',
      'description-only FBD metadata is supported');
  finally
    CoUninitialize;
  end;
end;

var
  Form: TForm;
  Panel: TInfoPanel;
  Probe: TLinkProbe;
  Output: string;
  InitialFontHeight, InitialLineHeight: Integer;
  Viewport: TScrollBox;
begin
  Failures := 0;
  Report := TStringList.Create;
  try
    try
      Application.Initialize;
      Application.ShowMainForm := False;
      CheckPublisherMetadata;
      Form := TForm.CreateNew(nil);
      Probe := TLinkProbe.Create;
      try
        Form.SetBounds(0, 0, 1000, 650);
        Panel := TInfoPanel.Create(Form);
        Panel.Parent := Form;
        Panel.SetBounds(0, 0, 950, 400);
        Panel.OnAuthorLinkClicked := Probe.Clicked;
        Panel.OnSeriesLinkClicked := Probe.Clicked;
        Panel.OnGenreLinkClicked := Probe.Clicked;
        Panel.OnPublisherSeriesLinkClicked := Probe.Clicked;
        FillPanel(Panel);
        CheckLinks(Panel, Probe, 'initial');
        InitialFontHeight := Abs(NativeFontHeight(FindPanelLink(Panel, '101')));
        InitialLineHeight := NativeLineHeight(FindPanelLink(Panel, '101'));
        Panel.Clear;
        FillPanel(Panel);
        CheckLinks(Panel, Probe, 'clear/refill');
        Panel.Font.Size := 18;
        CheckLinks(Panel, Probe, 'font change');
        Check(Abs(NativeFontHeight(FindPanelLink(Panel, '101'))) > InitialFontHeight,
          'font size 18 increases actual native font height');
        Check(NativeLineHeight(FindPanelLink(Panel, '101')) > InitialLineHeight,
          'font size 18 increases native glyph layout height');
        Panel.ShowCover := False;
        Panel.Width := 400;
        CheckLinks(Panel, Probe, 'narrow/no cover');
        CheckPublisherSeries(Panel, Probe);
        CheckPublisherLinks(Panel, Probe);
        Panel.Height := 150;
        CheckLinks(Panel, Probe, 'short panel');
        Viewport := PanelViewport(Panel);
        Check(Assigned(Viewport), 'short panel retains metadata viewport');
        if Assigned(Viewport) then
        begin
          Check(Viewport.VertScrollBar.Range > Viewport.ClientHeight,
            'short panel enables vertical metadata scrolling');
          Viewport.VertScrollBar.Position := Viewport.VertScrollBar.Range;
          FillPanel(Panel);
          Check(Viewport.VertScrollBar.Position = 0,
            'next book resets metadata scroll position');
          Viewport.VertScrollBar.Position := Viewport.VertScrollBar.Range;
          Panel.Clear;
          Check(Viewport.VertScrollBar.Position = 0,
            'clear resets metadata scroll position');
        end;
      finally
        Probe.Free;
        Form.Free;
      end;
    except
      on E: Exception do
      begin
        Report.Add(E.ClassName + ': ' + E.Message);
        Inc(Failures);
      end;
    end;
    Report.Add('Failures: ' + IntToStr(Failures));
    Output := ChangeFileExt(ParamStr(0), '.log');
    if ParamCount > 0 then
      Output := ParamStr(1);
    Report.SaveToFile(Output, TEncoding.UTF8);
  finally
    Report.Free;
  end;
  ExitCode := Ord(Failures <> 0);
end.
