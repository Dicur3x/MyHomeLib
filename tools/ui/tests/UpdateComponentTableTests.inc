procedure CheckUpdateComponentTable(Form: TfrmProgramUpdate; const Stage: string);
var View: TListView; Bitmap: TBitmap; Png: TPngImage; R: TRect;
  DC: HDC; Matching, Samples, X, Y: Integer; Expected: TColor; Artifacts: string;
  VisibleRows: Integer;
  ExpectedPixel: Cardinal; RowPixels: Pointer;
begin
  View:=Form.FindComponent('UpdateComponents') as TListView;
  Require(Assigned(View) and View.Enabled,'Update component list must stay readable and copyable: '+Stage);
  Require(ColorToRGB(View.Font.Color)=ColorToRGB(MHLThemeText),'Update table lost theme text: '+Stage);
  if not View.Visible then Exit;
  Artifacts:=TPath.Combine(Settings.AppPath,'update-table-artifacts'); ForceDirectories(Artifacts);
  Form.Show; Form.BringToFront; Form.Update; View.Repaint; Application.ProcessMessages;
  Bitmap:=TBitmap.Create; Png:=TPngImage.Create;
  try
    Bitmap.SetSize(View.ClientWidth,View.ClientHeight); Bitmap.PixelFormat:=pf32bit;
    Bitmap.Canvas.Brush.Color:=clFuchsia; Bitmap.Canvas.FillRect(Rect(0,0,Bitmap.Width,Bitmap.Height));
    // Native report lists do not implement VCL PaintTo client painting.
    // Read the visible control's own DC after the real WM_PAINT has completed.
    DC:=GetDC(View.Handle);
    try
      Require(BitBlt(Bitmap.Canvas.Handle,0,0,Bitmap.Width,Bitmap.Height,DC,0,0,SRCCOPY),
        'Cannot capture the native update table');
    finally ReleaseDC(View.Handle,DC); end;
    Png.Assign(Bitmap); Png.SaveToFile(TPath.Combine(Artifacts,
      Stage+'-dark-'+IntToStr(Ord(MHLThemeDark))+'-dpi-'+IntToStr(Form.CurrentPPI)+'.png'));
    Expected:=ColorToRGB(View.Color);
    ExpectedPixel:=RGB(GetBValue(Expected),GetGValue(Expected),GetRValue(Expected));
    VisibleRows:=0;
    for var Item in View.Items do
    begin
      if Item.Selected then Continue;
      R:=Item.DisplayRect(drBounds); Matching:=0; Samples:=0;
      // A native list can scroll once more independent components are listed.
      // Its DC contains only the viewport, so offscreen rows have no pixels.
      if (R.Bottom<=3) or (R.Top+3>=Bitmap.Height) or
        (R.Right<=4) or (R.Left+4>=Bitmap.Width) then Continue;
      Inc(VisibleRows);
      for Y:=Max(0,R.Top+3) to Min(R.Bottom-3,Bitmap.Height-1) do
      begin
        RowPixels:=Bitmap.ScanLine[Y];
        for X:=Max(0,R.Left+4) to Min(R.Right-4,Bitmap.Width-4) do
        begin
          Inc(Samples);
          if (PCardinal(NativeUInt(RowPixels)+NativeUInt(X)*4)^ and $FFFFFF)=ExpectedPixel then Inc(Matching);
        end;
      end;
      Require((Samples>0) and (Matching>Samples div 2),
        Format('Update table native row colours differ: %s row=%d matching=%d samples=%d',
          [Stage,Item.Index,Matching,Samples]));
    end;
    Require((View.Items.Count<=1) or (VisibleRows>0),'No visible update rows were inspected: '+Stage);
  finally Png.Free; Bitmap.Free; end;
end;
