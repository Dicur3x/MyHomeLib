// Regression for selecting the actual painted text below a large illustration.
// Run only in an explicitly isolated native profile, after desktop checks resume.
type
  TIllustratedOleObject = record
    cbStruct: DWORD;
    cp: Longint;
    clsid: TGUID;
    poleobj, pstg, polesite: Pointer;
    sizel: TSize;
    dvaspect, dwFlags, dwUser: DWORD;
  end;
  IIllustratedOleLayout = interface(IUnknown)
    ['{00020D00-0000-0000-C000-000000000046}']
    function GetClientSite(out Site: IOleClientSite): HResult; stdcall;
    function GetObjectCount: Integer; stdcall;
    function GetLinkCount: Integer; stdcall;
    function GetObject(Index: Longint; var Item: TIllustratedOleObject; Flags: DWORD): HResult; stdcall;
  end;

function PreviousIllustrationPosition(Buffer: TRichEdit; Before: Integer): Integer;
var Objects: IIllustratedOleLayout; Item: TIllustratedOleObject;
begin
  Result:=-1; Objects:=nil;
  Require(SendMessage(Buffer.Handle,EM_GETOLEINTERFACE,0,LPARAM(@Objects))<>0,'Native picture positions are unavailable');
  for var I:=0 to Objects.GetObjectCount-1 do
  begin
    FillChar(Item,SizeOf(Item),0); Item.cbStruct:=SizeOf(Item);
    OleCheck(Objects.GetObject(I,Item,0)); // REO_GETOBJ_NO_INTERFACES: position only.
    Require((Item.poleobj=nil) and (Item.pstg=nil) and (Item.polesite=nil),'Picture-position query returned unexpected interfaces');
    if (Item.cp<Before) and (Item.cp>Result) then Result:=Item.cp;
  end;
end;

procedure AuditIllustratedTextSelection;
const Query = 'восприятия';
var Reader: TfrmBuiltinReader; Surface: TWinControl; Painted: TBitmap;
  FileName, SourceHash, OriginalText: string; FontSize, Theme, X,Y, L,R,T,B, StartPosition, At: Integer;
  Files: TArray<string>;
begin
  Files:=TArray<string>.Create('illustrated-selection.fb2','illustrated-selection-dense.fb2');
  if FileExists('illustrated-selection-real.fb2') then Files:=Files+['illustrated-selection-real.fb2'];
  for FileName in Files do
  begin
    SourceHash:=THashSHA2.GetHashStringFromFile(FileName);
    Reader:=TfrmBuiltinReader.Create(nil); Painted:=TBitmap.Create;
    try
      Reader.SetBounds(60,60,944,1031); Reader.Show;
      Reader.OpenBook(FileName,FileName,FileName,FileName+'.ini','pdfium.dll'); WaitReady(Reader);
      Reader.SetBounds(60,60,944,1031);
      Require(Reader.SelectionEnabled,'Illustrated text selection was disabled');
      Require(Reader.PictureCount>0,'Illustrated selection fixture lost its pictures');
      OriginalText:=Reader.BookText;
      StartPosition:=0;
      if FileName='illustrated-selection-real.fb2' then
      begin
        Reader.FindText('Лицевой профиль ребенка'); At:=Reader.MatchPosition;
        Require(At>=0,'Reported paragraph is absent from the actual book');
        StartPosition:=PreviousIllustrationPosition(ReaderFormattingBuffer(Reader),At);
        Require(StartPosition>=0,'Reported paragraph has no preceding illustration');
        Writeln('TRACE actual reported picture=',StartPosition,' paragraph=',At); Flush(Output);
      end;
      Reader.SetPageLayout(rplSingle); Reader.SetTypography('Georgia',110,32);
      Reader.SetInitialsMode(rimParagraph); Reader.SetMaxTextWidth(960);
      for FontSize in [14,19] do for Theme in [1,4] do
      begin
        Reader.ChangeSize(FontSize-Reader.ReaderFontSize); Reader.SetTheme(Theme);
        Reader.GoToPosition(StartPosition); Reader.SetHighlightColor(clLime);
        Reader.SetSearchOptions(True,False,False);
        Writeln('TRACE illustrated font=',FontSize,' theme=',Theme,' before=',Reader.TextPosition,
          ' surface=',Reader.ReadingSurface.Width,'x',Reader.ReadingSurface.Height,
          ' page=',Copy(Reader.PageText.Replace(#13,' '),1,180)); Flush(Output);
        Reader.FindText('SELECTION_534_no_such_phrase'); Reader.FindText(Query);
        Require(Reader.TextPosition=StartPosition,'Selection probe did not retain the preceding illustration');
        Surface:=Reader.ReadingSurface; Painted.SetSize(Surface.Width,Surface.Height);
        Surface.PaintTo(Painted.Canvas.Handle,0,0);
        L:=Surface.Width; R:=-1; T:=Surface.Height; B:=-1;
        for Y:=0 to Surface.Height-1 do for X:=0 to Surface.Width-1 do
          if ColorToRGB(Painted.Canvas.Pixels[X,Y])=ColorToRGB(clLime) then
          begin L:=Min(L,X); R:=Max(R,X); T:=Min(T,Y); B:=Max(B,Y); end;
        Require((R>L) and (B>T),'No visible native text marker below the illustration');
        SendMessage(Surface.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MakeLParam(L-1,(T+B) div 2));
        SendMessage(Surface.Handle,WM_MOUSEMOVE,MK_LBUTTON,MakeLParam(R+1,(T+B) div 2));
        SendMessage(Surface.Handle,WM_LBUTTONUP,0,MakeLParam(R+1,(T+B) div 2));
        Require(Reader.SelectedText=Query,Format('Illustrated mouse selection differs: %s font=%d theme=%d got=[%s]',
          [FileName,FontSize,Theme,Reader.SelectedText]));
        Require(Reader.BookText=OriginalText,'Selecting an illustrated quote changed the book text');
      end;
      Reader.Close;
      if FileName='illustrated-selection-real.fb2' then Writeln('PASS actual Anthropoesthetics paragraph mouse selection in Paper and Dark at sizes14 and19');
    finally Painted.Free; Reader.Free; end;
    Require(THashSHA2.GetHashStringFromFile(FileName)=SourceHash,'Illustrated selection changed the source');
  end;
  Writeln('PASS illustrated mouse selection matches painted text below a large image and with dense following pictures');
end;
