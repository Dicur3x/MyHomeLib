type TInfoPanelSplitterAccess = class(TMHLSplitter);

procedure TestAdaptiveBookPreview;
var Infos: TArray<TInfoPanel>; Trees: TArray<TBookTree>; Panel: TInfoPanel;
  OldBounds: TRect; OldPage, DPI, Width, Index, Cases, WideCases, BeforeHeight, BeforePreferred: Integer;
  OldTheme, OldVisible, Dark: Boolean; Annotation: TMemo; Viewport: TScrollBox;
  ReadingProgress: TPaintBox;
  Content: TWinControl; DescriptionBounds: TRect; Bitmap: TBitmap; Png: TPngImage;
  Source, Hash, XML: string; Images: TMemoryStream; Started: UInt64;
  OldManualHeight: Integer;

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
  OldManualHeight:=Settings.ManualInfoPanelHeight;
  Settings.ManualInfoPanelHeight:=0;
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
            Require(not Assigned(Annotation.OnDblClick),'Double-click can still swap the description for metadata');
            Require(Pos('Новая глава',Annotation.Text)>0,'Selection preview overwrote the explicit layout fixture');
            Writeln('TRACE adaptive before view=',Index,' dark=',Ord(Dark),' dpi=',DPI,
              ' width=',Width,' height=',Panel.Height,' preferred=',Panel.PreferredHeight,
              ' viewport=',Viewport.ClientWidth,' annotation_y=',Annotation.Top); Flush(Output);
            BeforeHeight:=Panel.Height; BeforePreferred:=Panel.PreferredHeight;
            DescriptionBounds:=Annotation.BoundsRect;
            ReadingProgress:=Panel.FindComponent('BookReadingProgress') as TPaintBox;
            Require(Assigned(ReadingProgress) and not ReadingProgress.Visible,'No-progress book showed a stale badge');
            Panel.SetReadingProgress(42);
            Require((Panel.Height=BeforeHeight) and (Panel.PreferredHeight=BeforePreferred) and
              (Annotation.BoundsRect=DescriptionBounds),'Reading progress changed the preview footprint');
            if Width=1280 then Require(ReadingProgress.Visible,'Wide preview did not display reading progress');
            if ReadingProgress.Visible then
              Require((ReadingProgress.Left>=Panel.DetailsButton.BoundsRect.Right) and
                (ReadingProgress.Top>=Panel.DetailsButton.Top) and
                (ReadingProgress.BoundsRect.Bottom<=Panel.DetailsButton.BoundsRect.Bottom) and
                (ReadingProgress.BoundsRect.Right<=Panel.ClientWidth),
                'Reading progress overlaps the footer or leaves the panel');
            Require(ReadingProgress.Hint='Прочитано 42%','Reading progress did not show the saved value');
            Panel.SetReadingProgress(100);
            Require(ReadingProgress.Hint='Прочитано 100%','Reading progress did not refresh');
            Panel.SetReadingProgress(0);
            Require(not ReadingProgress.Visible,'Clearing reading progress left the badge visible');
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
    Writeln('PASS reading progress fits the footer and preserves the description bounds');
    Require(THashSHA2.GetHashStringFromFile(Source)=Hash,'Gallery layout changed source book bytes');
    Writeln('PASS adaptive preview keeps thumbnail pixels and original source unchanged'); Flush(Output);
    frmMain.ScaleForPPI(96); frmMain.SetBounds(0,0,1280,900);
    SelectView(0); Panel:=Infos[0]; Fill(Panel,False);
    BeforeHeight:=Panel.Height;
    var Splitter:=TInfoPanelSplitterAccess(frmMain.AuthorBookInfoSplitter);
    Splitter.MouseDown(mbLeft,[ssLeft],10,1);
    Splitter.MouseUp(mbLeft,[],10,1);
    Require(Settings.ManualInfoPanelHeight=0,'Clicking the splitter disabled automatic fitting');
    Splitter.MouseDown(mbLeft,[ssLeft],10,1);
    Splitter.MouseMove([ssLeft],10,-89);
    Splitter.MouseUp(mbLeft,[],10,-89);
    var ManualHeight:=Settings.ManualInfoPanelHeight;
    Require((ManualHeight>BeforeHeight) and (ManualHeight=Panel.Height),'Real splitter resize did not capture manual height');
    for Index:=0 to High(Infos) do
    begin
      SelectView(Index); Fill(Infos[Index],Index mod 2=0);
      Require(Infos[Index].Height=ManualHeight,'Selecting another book or view replaced manual height');
    end;
    frmMain.SetBounds(0,0,800,410);
    Require((Infos[5].Height<ManualHeight) and (Settings.ManualInfoPanelHeight=ManualHeight),
      'Small window failed to clamp the panel without overwriting its preference');
    frmMain.SetBounds(0,0,1280,900);
    Require(Infos[5].Height=ManualHeight,'Restoring window size did not restore manual height');
    frmMain.SetBounds(0,0,1920,1350); frmMain.ScaleForPPI(144);
    Require((Settings.ManualInfoPanelHeight=ManualHeight) and
      (Infos[5].Font.PixelsPerInch=144) and (Infos[5].Height=MulDiv(ManualHeight,144,96)),
      Format('DPI change did not scale saved height (stored %d, actual %d, DPI %d, original %d)',
        [Settings.ManualInfoPanelHeight,Infos[5].Height,Infos[5].Font.PixelsPerInch,ManualHeight]));
    Settings.SaveSettings;
    Settings.ManualInfoPanelHeight:=0;
    Settings.LoadSettings;
    Require(Settings.ManualInfoPanelHeight=ManualHeight,'Manual height was not restored from the profile');
    TMenuItem(frmMain.FindComponent('miAutoFitInfoPanel')).Click;
    Require((Settings.ManualInfoPanelHeight=0) and
      (Infos[5].Height<=Infos[5].Parent.ClientHeight div 2),'Automatic height could not be restored');
    Writeln('PASS manual preview height survives new books, views, DPI and profile reload'); Flush(Output);
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
    Settings.ManualInfoPanelHeight:=OldManualHeight;
    for Panel in Infos do Panel.Clear;
    SetMHLTheme(OldTheme); frmMain.ScaleForPPI(96); frmMain.BoundsRect:=OldBounds;
    frmMain.pgControl.ActivePageIndex:=OldPage; frmMain.pgControlChange(nil);
    if Settings.ShowInfoPanel<>OldVisible then frmMain.ShowBookInfoPanelExecute(nil);
    Images.Free; Png.Free; Bitmap.Free;
  end;
end;

procedure TestSavedReviewPreview(const Collection: IBookCollection; BookID: Integer);
const SavedText = 'Сохранённый отзыв — проверка ё.';
var Panel: TInfoPanel; Tree: TBookTree; Button, Download: TButton; Review: TMemo;
  Status: TLabel;
  Viewport: TScrollBox; Key: TBookKey; Data: PBookRecord; DPI: Integer; Dark: Boolean;
  OtherNode: PVirtualNode;
begin
  RequireIsolatedRegression;
  Key := CreateBookKey(BookID, Collection.CollectionID);
  Collection.SetReview(Key, SavedText);
  if not Settings.ShowInfoPanel then frmMain.ShowBookInfoPanelExecute(nil);
  frmMain.WindowState := wsNormal;
  frmMain.Show;
  frmMain.pgControl.ActivePage := frmMain.tsByAuthor;
  frmMain.pgControlChange(nil);
  Panel := frmMain.ipnlAuthors;
  Tree := frmMain.tvBooksA;
  Data := Tree.GetNodeData(Tree.FocusedNode);
  Require(Assigned(Data) and Data^.BookKey.IsSameAs(Key),
    'Saved review fixture must select the expected book');
  frmMain.tvBooksTreeChange(Tree, Tree.FocusedNode);
  Button := Panel.FindComponent('BookReviewsToggle') as TButton;
  Review := Panel.FindComponent('BookSavedReviews') as TMemo;
  Download := Panel.FindComponent('BookReviewDownload') as TButton;
  Status := Panel.FindComponent('BookReviewStatus') as TLabel;
  Viewport := InfoFooterViewport(Panel);
  Require(Button.Visible and not Review.Visible and not Review.HandleAllocated,
    'Saved reviews must open on demand');
  for Dark in TArray<Boolean>.Create(False, True) do
  begin
    SetMHLTheme(Dark);
    for DPI in TArray<Integer>.Create(96, 144, 192) do
    begin
      frmMain.ScaleForPPI(DPI);
      frmMain.SetBounds(0, 0, MulDiv(800, DPI, 96), MulDiv(640, DPI, 96));
      Button.Click;
      Require(Panel.ReviewsVisible and Review.ReadOnly and not Viewport.Visible and
        (Pos(SavedText, Review.Text)>0) and (Pos('источник не записан', Review.Text)>0),
        'Review preview did not read the selected book or preserve provenance');
      Require((Review.Height>0) and (Review.BoundsRect.Bottom<=Button.Top) and
        (Panel.DetailsButton.BoundsRect.Right<Button.Left) and (Button.BoundsRect.Right<=Panel.ClientWidth),
        'Review text or footer overlaps at scaled small-window bounds');
      Require(Download.Visible and not Download.Enabled and Status.Visible and
        (Download.Caption='Обновить') and (Pos('нет адреса',Status.Caption)>0) and
        (Download.BoundsRect.Bottom<=Review.Top) and (Status.BoundsRect.Right<Download.Left) and
        (Download.BoundsRect.Right<=Panel.ClientWidth),
        'Review load controls overlap or offer a request without a valid source');
      Panel.SetBookAnnotationText('Аннотация обновилась в фоне.');
      Require(not Viewport.Visible and (Pos(SavedText, Review.Text)>0),
        'Asynchronous annotation overwrote the review view');
      Button.Click;
      Require(Viewport.Visible and not Panel.ReviewsVisible, 'Returning from reviews lost metadata');
    end;
  end;
  Button.Click;
  OtherNode := Tree.GetFirst;
  while Assigned(OtherNode) do
  begin
    Data := Tree.GetNodeData(OtherNode);
    if Assigned(Data) and (Data^.NodeType=ntBookInfo) and not Data^.BookKey.IsSameAs(Key) then Break;
    OtherNode := Tree.GetNext(OtherNode);
  end;
  Require(Assigned(OtherNode), 'The review fixture needs a second book');
  Tree.FocusedNode := OtherNode;
  frmMain.tvBooksTreeChange(Tree, OtherNode);
  Require(not Panel.ReviewsVisible and Button.Visible and Viewport.Visible and (Review.Text=''),
    'Selection change left the previous book review visible or cached');
  Button.Click;
  Require((Pos('Сохранённых отзывов нет', Review.Text)>0) and (Pos(SavedText, Review.Text)=0),
    'An empty second book displayed the first book review');
  Require(Collection.GetReview(Key)=SavedText, 'Read-only review preview changed stored text');
  Writeln('PASS saved review preview reads the selected catalogue record in both themes at 96/144/192 DPI');
end;
