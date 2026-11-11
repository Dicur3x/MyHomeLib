type
  TStatisticsPaintProbe = class
    Previous:TLVAdvancedCustomDrawEvent;
    Frames, PalettePixels:Integer;
    procedure Observe(Sender:TCustomListView; const ARect:TRect;
      Stage:TCustomDrawStage; var DefaultDraw:Boolean);
  end;

procedure TStatisticsPaintProbe.Observe(Sender:TCustomListView; const ARect:TRect;
  Stage:TCustomDrawStage; var DefaultDraw:Boolean);
var Image:TBitmap; Bounds:TRect;
begin
  Previous(Sender,ARect,Stage,DefaultDraw);
  if (Stage<>cdPostPaint) or not MHLThemeDark then Exit;
  Inc(Frames); PalettePixels:=0;
  Image:=TBitmap.Create;
  try
    Image.SetSize(Sender.ClientWidth,Sender.ClientHeight);
    Win32Check(BitBlt(Image.Canvas.Handle,0,0,Image.Width,Image.Height,Sender.Canvas.Handle,0,0,SRCCOPY));
    if GetEnvironmentVariable('HOMELIB_STATS_BITMAP')<>'' then
      Image.SaveToFile(GetEnvironmentVariable('HOMELIB_STATS_BITMAP'));
    if ListView_GetGroupRect(Sender.Handle,0,LVGGR_HEADER,Bounds)=0 then Exit;
    for var Y:=Max(0,Bounds.Top) to Min(Image.Height,Bounds.Bottom)-1 do
      for var X:=Max(0,Bounds.Left) to Min(Image.Width,Bounds.Right)-1 do
        if ColorToRGB(Image.Canvas.Pixels[X,Y])=ColorToRGB(MHLThemeLink) then Inc(PalettePixels);
  finally Image.Free; end;
end;

procedure TestStatisticsGroupTheme;
var Root:string; CID:Integer; Collection:IBookCollection; Form:TfrmStat;
  SavedDark:Boolean; Paint:TStatisticsPaintProbe;
begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'statistics-theme'); ForceDirectories(Root);
  CID:=SystemDB.CreateCollection('Statistics palette',Root,Root+'books.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Collection:=SystemDB.GetCollection(CID); SavedDark:=MHLThemeDark;
  try
    for var Recreated:=0 to 1 do
    begin
      Form:=TfrmStat.Create(nil); Paint:=TStatisticsPaintProbe.Create;
      try
        Paint.Previous:=Form.lvInfo.OnAdvancedCustomDraw;
        Require(Assigned(Paint.Previous),'Statistics did not subscribe to native post-paint');
        Form.lvInfo.OnAdvancedCustomDraw:=Paint.Observe;
        Form.LoadCollectionInfo(Collection); WaitCollectionStatistics(Form);
        var Group:=Form.lvInfo.Groups.Add; Group.GroupID:=3; Group.Header:='Дополнительные источники (3)';
        var Row:=Form.lvInfo.Items.Add; Row.Caption:='Проверка источника'; Row.GroupID:=3;
        Form.Show; Application.ProcessMessages;
        for var DPI in [96,144,192,240,288] do
        begin
          Form.ScaleForPPI(DPI);
          for var Dark in [False,True,False,True] do
          begin
            SetMHLTheme(Dark); ApplyMHLControlTheme(Form); Paint.Frames:=0;
            Form.lvInfo.Invalidate; Form.lvInfo.Update;
            if Dark then
            begin
              var DC:=GetDC(Form.lvInfo.Handle);
              try
                for var G:=0 to Form.lvInfo.Groups.Count-1 do
                begin
                  var Bounds:TRect;
                  if ListView_GetGroupRect(Form.lvInfo.Handle,Form.lvInfo.Groups[G].GroupID,LVGGR_HEADER,Bounds)=0 then Continue;
                  if (Bounds.Top<0) or (Bounds.Bottom>Form.lvInfo.ClientHeight) then Continue;
                  Require(GetPixel(DC,Bounds.Right-20,(Bounds.Top+Bounds.Bottom) div 2)<>RGB(255,255,255),
                    'Statistics header retains a white strip after native painting');
                end;
              finally ReleaseDC(Form.lvInfo.Handle,DC); end;
            end;
            if Dark then Require((Paint.Frames>0) and (Paint.PalettePixels>8),
              Format('Live statistics heading palette missing at %d DPI: frames=%d pixels=%d',
                [DPI,Paint.Frames,Paint.PalettePixels]));
          end;
        end;
        Form.LoadCollectionInfo(Collection); WaitCollectionStatistics(Form);
        Require(Form.lvInfo.Items[5].SubItems[0]='0','Theme painting changed the statistics result');
      finally Form.lvInfo.OnAdvancedCustomDraw:=Paint.Previous; Paint.Free; Form.Free; end;
    end;
  finally SetMHLTheme(SavedDark); end;
  Writeln('PASS statistics group headings use the readable dark palette across theme changes recreation and 100 to 300 percent');
end;
