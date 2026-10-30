procedure TestAdaptiveBookPreview;
var Infos: TArray<TInfoPanel>; Trees: TArray<TBookTree>; Panel: TInfoPanel;
  OldBounds: TRect; OldPage, DPI, Width, Index, Cases, WideCases, BeforeHeight, BeforePreferred: Integer;
  OldTheme, OldVisible, Dark: Boolean; Annotation: TMemo; Viewport: TScrollBox;
  Content: TWinControl; DescriptionBounds: TRect; Bitmap: TBitmap; Png: TPngImage;
  Source, Hash, XML: string; Images: TMemoryStream; Started: UInt64;

  procedure SelectView(I: Integer);
  begin
    case I of
      0: frmMain.pgControl.ActivePage:=frmMain.tsByAuthor;
      1: frmMain.pgControl.ActivePage:=frmMain.tsBySerie;
      2: frmMain.pgControl.ActivePage:=PublisherView.Tab;
      3: frmMain.pgControl.ActivePage:=frmMain.tsByGenre;
      4: frmMain.pgControl.ActivePage:=frmMain.tsSearch;
      5: frmMain.pgControl.ActivePage:=frmMain.tsByGroup;
    end;
    frmMain.pgControlChange(nil);
    // This fixture supplies its own metadata. Retire any real selection preview
    // before it can overwrite that fixture; asynchronous loading has its own case.
    for var C:=0 to frmMain.ComponentCount-1 do
      if frmMain.Components[C] is TBookInfoPreview then TBookInfoPreview(frmMain.Components[C]).Cancel;
  end;

  procedure Fill(Info: TInfoPanel; LongDescription: Boolean);
  var Description: string;
  begin
    Description:='Книга о путешествии, открытиях и удивительных встречах. Иллюстрации дополняют рассказ.';
    if LongDescription then
      for var N:=1 to 30 do Description:=Description+sLineBreak+'Новая глава сохраняет подробности истории и её героев.';
    Info.BeginUpdate;
    try
      Info.Clear; Info.ShowAnnotation:=True;
      Info.SetBookInfo('Путешествие к новым берегам', '<a href="101">Автор книги</a>',
        '<a href="201">Приключения</a>', '<a href="sf">Фантастика</a>');
      Info.SetReadingSupport('Можно читать во встроенной читалке');
      Info.SetBookCover(Bitmap); Info.SetBookAnnotationText(Description);
      Info.DetailsButton.Visible:=True;
      Info.Gallery.SetBook('adaptive-'+Info.Name,'.fb2',
        function: TStream
        begin Result:=TFileStream.Create(Source,fmOpenRead or fmShareDenyWrite); end);
    finally Info.EndUpdate; end;
  end;

  procedure FindDetails;
  begin
    Viewport:=InfoFooterViewport(Panel); Content:=InfoFooterContent(Viewport);
    Annotation:=nil;
    for var I:=0 to Content.ControlCount-1 do
      if Content.Controls[I] is TMemo then Annotation:=TMemo(Content.Controls[I]);
    Require(Assigned(Annotation),'Adaptive preview lost its description');
  end;

begin
  RequireIsolatedRegression;
  Infos:=TArray<TInfoPanel>.Create(frmMain.ipnlAuthors,frmMain.ipnlSeries,PublisherView.Info,
    frmMain.ipnlGenres,frmMain.ipnlSearch,frmMain.ipnlFavorites);
  Trees:=TArray<TBookTree>.Create(frmMain.tvBooksA,frmMain.tvBooksS,PublisherView.Books,
    frmMain.tvBooksG,frmMain.tvBooksSR,frmMain.tvBooksF);
  OldBounds:=frmMain.BoundsRect; OldPage:=frmMain.pgControl.ActivePageIndex;
  OldTheme:=MHLThemeDark; OldVisible:=Settings.ShowInfoPanel; Cases:=0; WideCases:=0;
  Bitmap:=TBitmap.Create; Png:=TPngImage.Create; Images:=TMemoryStream.Create;
  try
    Bitmap.SetSize(120,160); XML:='<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><body><section>';
    for Index:=1 to 3 do XML:=XML+'<p><image l:href="#image'+Index.ToString+'"/></p>';
    XML:=XML+'</section></body>';
    for Index:=1 to 3 do
    begin
      Bitmap.Canvas.Brush.Color:=RGB(30*Index,60,180); Bitmap.Canvas.FillRect(Rect(0,0,120,160));
      Png.Assign(Bitmap); Images.Clear; Png.SaveToStream(Images);
      XML:=XML+'<binary id="image'+Index.ToString+'" content-type="image/png">'+
        TNetEncoding.Base64.EncodeBytesToString(Images.Memory,Images.Size)+'</binary>';
    end;
    Source:=TPath.Combine(Settings.TempDir,'adaptive-gallery.fb2');
    TFile.WriteAllText(Source,XML+'</FictionBook>',TEncoding.UTF8); Hash:=THashSHA2.GetHashStringFromFile(Source);
    if not Settings.ShowInfoPanel then frmMain.ShowBookInfoPanelExecute(nil);
    frmMain.WindowState:=wsNormal; frmMain.Show; Application.ProcessMessages;
    for Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark);
      for DPI in TArray<Integer>.Create(96,144,192) do
      begin
        frmMain.ScaleForPPI(DPI);
        for Width in TArray<Integer>.Create(800,1280) do
        begin
          frmMain.SetBounds(0,0,MulDiv(Width,DPI,96),MulDiv(850,DPI,96));
          for Index:=0 to High(Infos) do
          begin
            SelectView(Index); Panel:=Infos[Index]; Fill(Panel,True); Application.ProcessMessages;
            FindDetails;
            Require(Assigned(Panel.OnContentSizeChanged),'Actual Main did not connect automatic preview fitting');
            Require((Panel.Height>=Panel.Constraints.MinHeight) and
              (Panel.Height<=Max(Panel.Constraints.MinHeight,Panel.Parent.ClientHeight div 2)),
              'Automatic preview consumed more than its bounded share of the list');
            Require(Trees[Index].ClientHeight>=3*Trees[Index].DefaultNodeHeight,'Automatic fitting hid book rows');
            Require(Annotation.Visible and (Annotation.Height>0),'Description has no visible area');
            Require(Pos('Новая глава',Annotation.Text)>0,'Selection preview overwrote the explicit layout fixture');
            Writeln('TRACE adaptive before view=',Index,' dark=',Ord(Dark),' dpi=',DPI,
              ' width=',Width,' height=',Panel.Height,' preferred=',Panel.PreferredHeight,
              ' viewport=',Viewport.ClientWidth,' annotation_y=',Annotation.Top); Flush(Output);
            BeforeHeight:=Panel.Height; BeforePreferred:=Panel.PreferredHeight;
            DescriptionBounds:=Annotation.BoundsRect;
            Panel.GalleryButton.Click;
            Started:=GetTickCount64;
            while Panel.Gallery.Loading and (GetTickCount64-Started<10000) do
            begin Application.ProcessMessages; CheckSynchronize(2); Sleep(2); end;
            Require(Panel.Gallery.Expanded and (Panel.Gallery.ImageCount=3),'Adaptive gallery lost decoded illustrations');
            for var StripIndex:=0 to Panel.Gallery.ControlCount-1 do
              if Panel.Gallery.Controls[StripIndex] is TScrollBox then
              begin
                var Strip:=TScrollBox(Panel.Gallery.Controls[StripIndex]);
                for var ThumbIndex:=0 to Strip.ControlCount-1 do
                  if Strip.Controls[ThumbIndex] is TImage then
                  begin
                    var Thumb:=TImage(Strip.Controls[ThumbIndex]);
                    Require((Thumb.Picture.Width=120) and (Thumb.Picture.Height=160),'Thumbnail source grid changed');
                    Png.Assign(Thumb.Picture.Graphic);
                    Require(ColorToRGB(Png.Canvas.Pixels[5,5])=RGB(30*(Thumb.Tag+1),60,180),'Thumbnail original pixels changed');
                  end;
              end;
            Require((Panel.Height=BeforeHeight) and (Panel.PreferredHeight=BeforePreferred),
              'Expanding illustrations increased the outer preview height');
            if Panel.Gallery.Top=0 then
            begin
              Inc(WideCases);
              Require(Panel.Gallery.Left>=Panel.GalleryButton.BoundsRect.Right,
                'Wide thumbnails overlap metadata');
              Require(Annotation.BoundsRect=DescriptionBounds,'Wide gallery moved or reduced the description');
            end;
            Panel.GalleryButton.Click;
            Require(not Panel.Gallery.Expanded and (Panel.Height=BeforeHeight),'Collapsing gallery changed preview height');
            Fill(Panel,False);
            // Native theme frame settling can change parent capacity by a pixel.
            // Compare content demand itself, then verify the current actual bound.
            Require(Panel.PreferredHeight<=BeforePreferred,'A shorter description requested more room');
            Require(Panel.Height<=Max(Panel.Constraints.MinHeight,Panel.Parent.ClientHeight div 2),
              'Short-description fitting exceeded the current list share');
            Inc(Cases);
          end;
        end;
      end;
    end;
    Require((Cases=72) and (WideCases>=6),'Adaptive preview did not exercise wide/narrow six-view DPI cases');
    Writeln('PASS adaptive preview uses actual Main bounded automatic height in all six views cases=',Cases);
    Writeln('PASS expanded illustrations keep panel height and wide description position');
    Require(THashSHA2.GetHashStringFromFile(Source)=Hash,'Gallery layout changed source book bytes');
    Writeln('PASS adaptive preview keeps thumbnail pixels and original source unchanged'); Flush(Output);
    if FileExists(Settings.AppPath+'preview-adaptive-visual.flag') then
    begin
      SetMHLTheme(False); frmMain.ScaleForPPI(96); frmMain.SetBounds(40,40,1280,900);
      SelectView(0); Panel:=Infos[0]; Fill(Panel,False); Panel.GalleryButton.Click;
      frmMain.ShowInTaskBar:=True; frmMain.Show; frmMain.BringToFront;
      Started:=GetTickCount64; Writeln('TRACE adaptive preview ready'); Flush(Output);
      while frmMain.Visible and (GetTickCount64-Started<180000) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(20); end;
    end;
  finally
    for Panel in Infos do Panel.Clear;
    SetMHLTheme(OldTheme); frmMain.ScaleForPPI(96); frmMain.BoundsRect:=OldBounds;
    frmMain.pgControl.ActivePageIndex:=OldPage; frmMain.pgControlChange(nil);
    if Settings.ShowInfoPanel<>OldVisible then frmMain.ShowBookInfoPanelExecute(nil);
    Images.Free; Png.Free; Bitmap.Free;
  end;
end;
