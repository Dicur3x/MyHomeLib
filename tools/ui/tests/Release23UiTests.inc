// Exercises every real column-filter editor, including empty lists.
procedure TestRelease23Filters(Tree: TBookTree);
const Tags: array[0..18] of Integer = (COL_AUTHOR,COL_TITLE,COL_SERIES,COL_PUBLISHER_SERIES,
  COL_PUBLISHER,COL_TRANSLATORS,COL_CITY,COL_PUBYEAR,COL_ISBN,COL_NO,COL_GENRE,
  COL_SIZE,COL_RATE,COL_DATE,COL_TYPE,COL_COLLECTION,COL_LANG,COL_LIBRATE,COL_LIBID);
  Titles: array[0..18] of string = ('Автор','Название','Серия','Книжная серия','Издательство',
    'Переводчики','Город издания','Год издания','ISBN','№','Жанр','Размер','Моя оценка',
    'Добавлено','Тип','Коллекция','Язык','Рейтинг библиотеки','ID в библиотеке');
var Probe: TFCTModalProbe; SavedTheme: Boolean; Empty: TBookTree; Target: TBookTree;
  Artifacts, ClassName, Subcase: string; Cases, Index, ExpectedCases: Integer;
begin
  RequireIsolatedRegression; SavedTheme:=MHLThemeDark; Empty:=TBookTree.Create(nil); Cases:=0;
  Subcase:=ParamStr(2); ExpectedCases:=228;
  if Subcase<>'' then
  begin
    Require(MatchText(Subcase,['populated-light','empty-light','populated-dark','empty-dark']),
      'Unknown filter audit subcase'); ExpectedCases:=57;
  end;
  Artifacts:=TPath.Combine(Settings.AppPath,'release23-filter-artifacts'); ForceDirectories(Artifacts);
  try
    var Reader:=TfrmBuiltinReader.Create(nil);
    try
      var FontOffer:=Reader.FindComponent('ReaderLanguageFonts') as TPanel;
      Require(Assigned(FontOffer) and (FontOffer.Caption=''),
        'Reader font offer exposes a layout caption');
      Writeln('PASS reader font offer does not expose its internal panel name');
    finally Reader.Free; end;
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      if (Subcase<>'') and (ContainsText(Subcase,'dark')<>Dark) then Continue;
      SetMHLTheme(Dark);
      for var IsEmpty in TArray<Boolean>.Create(False,True) do
      begin
        if (Subcase<>'') and (Subcase.StartsWith('empty-')<>IsEmpty) then Continue;
        if IsEmpty then Target:=Empty else Target:=Tree;
        for Index:=Low(Tags) to High(Tags) do
        begin
          if Tags[Index] in [COL_AUTHOR,COL_SERIES,COL_PUBLISHER_SERIES,COL_PUBLISHER,
            COL_TRANSLATORS,COL_CITY,COL_GENRE,COL_TYPE,COL_COLLECTION,COL_LANG] then
            ClassName:='TListFilterEditor' else ClassName:='TFilterEditor';
          Probe:=TFCTModalProbe.Create(ClassName,'Фильтр: '+Titles[Index],
            procedure(Popup: TForm)
            var Bitmap: TBitmap; Png: TPngImage;
            begin
              if ClassName='TListFilterEditor' then
              begin
                var Values:=Popup.FindComponent('FilterOptionList') as TVirtualStringTree;
                var Count:=Values.TotalCount;
                Require(Values.EmptyListMessage<>'','Empty filter has no useful explanation');
                for var Component in Popup do
                  if Component is TEdit then
                  begin
                    var Search:=TEdit(Component);
                    Search.Text:='no-match-'+TGUID.NewGuid.ToString;
                    Require(Values.TotalCount=0,'Unmatched option search still shows values');
                    if Count>0 then Require(Values.EmptyListMessage.StartsWith('Ничего не найдено'),
                      'Unmatched option search incorrectly claims that the book list is empty');
                    Search.Text:=''; Require(Values.TotalCount=Count,'Clearing option search lost its original values');
                  end;
              end;
              for var DPI in TArray<Integer>.Create(96,144,192) do
              begin
                Popup.ScaleForPPI(DPI); Application.ProcessMessages;
                for var Component in Popup do
                  if Component is TPanel then
                    Require(TPanel(Component).Caption='', 'Filter exposes layout caption: '+Component.Name)
                  else if Component is TButton then
                  begin
                    var Button:=TButton(Component);
                    Require((Button.Left>=0) and (Button.Top>=0) and
                      (Button.BoundsRect.Right<=Button.Parent.ClientWidth) and
                      (Button.BoundsRect.Bottom<=Button.Parent.ClientHeight),
                      'Filter button lies outside its parent: '+Titles[Index]+' / '+Button.Caption);
                    Popup.Canvas.Font.Assign(Button.Font);
                    Require(Popup.Canvas.TextWidth(Button.Caption)<=Button.Width,
                      'Filter button caption clipped: '+Titles[Index]+' / '+Button.Caption);
                  end;
                if ClassName='TListFilterEditor' then FCTCheckFilterControls(Popup,DPI);
                Bitmap:=Popup.GetFormImage; Png:=TPngImage.Create;
                try
                  Png.Assign(Bitmap); Png.SaveToFile(TPath.Combine(Artifacts,
                    Format('filter-%d-empty-%d-dark-%d-dpi-%d.png',[Tags[Index],Ord(IsEmpty),Ord(Dark),DPI])));
                finally Png.Free; Bitmap.Free; end;
                Inc(Cases);
              end;
              Popup.ModalResult:=mrCancel;
            end);
          try
            Require(not EditBookColumnFilter(Target,Tags[Index]),'UI audit unexpectedly applied a filter');
            Require(Probe.Completed,'Filter modal did not receive its UI audit');
          finally Probe.Free; end;
        end;
      end;
    end;
    Require(Cases=ExpectedCases,'Not all column editor states were inspected');
    Writeln('PASS release23 all 19 actual filter editors empty and populated in both themes at 96 144 192 DPI cases=',Cases);
  finally Empty.Free; SetMHLTheme(SavedTheme); end;
end;
