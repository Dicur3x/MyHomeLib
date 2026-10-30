unit unit_ReaderBookSkin;

interface

uses System.Types, Vcl.Graphics;

type
  // A paint-only skin: the source raster and all text/hit-test coordinates
  // remain owned by the reader. The reusable strip keeps gradients cheap.
  TReaderBookSkin = class
  private
    FStrip: TBitmap;
    procedure Shade(Canvas: TCanvas; const R: TRect; Color: TColor;
      Alpha: Integer; Reverse: Boolean; Crest: Boolean = False);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Paint(Canvas: TCanvas; const Viewport: TRect;
      const Pages: array of TRect; Paper: TColor; Night, Reflow: Boolean;
      PPI: Integer; Progress: Double);
  end;

implementation

uses Winapi.Windows, System.Math, unit_ReaderPalette;

constructor TReaderBookSkin.Create;
begin
  inherited;
  FStrip:=Vcl.Graphics.TBitmap.Create; FStrip.PixelFormat:=pf32bit; FStrip.SetSize(256,1);
end;

destructor TReaderBookSkin.Destroy;
begin FStrip.Free; inherited; end;

procedure TReaderBookSkin.Shade(Canvas: TCanvas; const R: TRect;
  Color: TColor; Alpha: Integer; Reverse, Crest: Boolean);
var Blend: TBlendFunction; Pixel: PRGBQuad; RGBColor: COLORREF;
  X, A: Integer; Fraction, Strength: Double;
begin
  if R.IsEmpty or (Alpha<=0) then Exit;
  RGBColor:=ColorToRGB(Color);
  Pixel:=FStrip.ScanLine[0];
  for X:=0 to FStrip.Width-1 do
  begin
    Fraction:=X/(FStrip.Width-1);
    if Reverse then Fraction:=1-Fraction;
    if Crest then Strength:=Sqr(Sin(Pi*Fraction))
    else Strength:=Sqr(1-Fraction);
    A:=EnsureRange(Round(Alpha*Strength),0,255);
    Pixel.rgbRed:=MulDiv(GetRValue(RGBColor),A,255);
    Pixel.rgbGreen:=MulDiv(GetGValue(RGBColor),A,255);
    Pixel.rgbBlue:=MulDiv(GetBValue(RGBColor),A,255);
    Pixel.rgbReserved:=A; Inc(Pixel);
  end;
  Blend.BlendOp:=AC_SRC_OVER; Blend.BlendFlags:=0;
  Blend.SourceConstantAlpha:=255; Blend.AlphaFormat:=AC_SRC_ALPHA;
  Winapi.Windows.AlphaBlend(Canvas.Handle,R.Left,R.Top,R.Width,R.Height,
    FStrip.Canvas.Handle,0,0,FStrip.Width,1,Blend);
end;

procedure TReaderBookSkin.Paint(Canvas: TCanvas; const Viewport: TRect;
  const Pages: array of TRect; Paper: TColor; Night, Reflow: Boolean;
  PPI: Integer; Progress: Double);
var Book, R, CoverRect: TRect; Desk, Cover, Edge, ShadowColor: TColor;
  Count, Saved, Depth, MaximumDepth, LeftDepth, RightDepth,
  BottomDepth, FoldWidth, Mid, I, Direction, CoverDC: Integer;
  Face: array[0..3] of TPoint;
  function Px(Value: Integer): Integer;
  begin Result:=Max(1,MulDiv(Value,PPI,96)); end;
  procedure Line(X1,Y1,X2,Y2: Integer; Color: TColor);
  begin
    Canvas.Pen.Style:=psSolid; Canvas.Pen.Color:=Color;
    Canvas.MoveTo(X1,Y1); Canvas.LineTo(X2,Y2);
  end;
  procedure Block(Index, BlockDepth, Sign: Integer);
  var Page: TRect; BottomFace, Back: array[0..3] of TPoint;
    Drop, OtherDrop, Outside, Layer, X, Y, J: Integer;
  begin
    Page:=Pages[Index]; Drop:=Max(Px(1),Min(Px(10),BlockDepth*2 div 3));
    OtherDrop:=Drop;
    if Count=1 then OtherDrop:=Max(Px(1),Min(Px(10),RightDepth*2 div 3));
    // The front sheet is rectangular. Only the exposed leaves beneath it
    // taper towards the binding; its top edge never tilts or masks text.
    if Sign<0 then Outside:=Page.Left else Outside:=Page.Right;
    Canvas.Pen.Style:=psClear; Canvas.Brush.Color:=Edge;
    Face[0]:=Point(Outside,Page.Top+Px(1));
    Face[1]:=Point(Outside,Page.Bottom);
    Face[2]:=Point(Outside+Sign*BlockDepth,Page.Bottom+Drop);
    Face[3]:=Point(Outside+Sign*BlockDepth,Page.Top+Drop);
    Canvas.Polygon(Face);
    for Layer:=1 to BlockDepth do
    begin
      X:=Outside+Sign*Layer; Y:=MulDiv(Drop,Layer,Max(1,BlockDepth));
      Line(X,Page.Top+Y,X,Page.Bottom+Y,
        ReaderBlendColor(Edge,Cover,IfThen(Layer mod Px(3)=0,62,12)));
    end;
    if (Count=2) or (Sign<0) then
    begin
      BottomFace[0]:=Point(Page.Left,Page.Bottom);
      BottomFace[1]:=Point(Page.Right,Page.Bottom);
      if Count=1 then
      begin
        BottomFace[2]:=Point(Page.Right+RightDepth,Page.Bottom+OtherDrop);
        BottomFace[3]:=Point(Page.Left-LeftDepth,Page.Bottom+Drop);
      end
      else
      begin
        BottomFace[2]:=Point(Page.Right+Sign*BlockDepth,Page.Bottom+Drop);
        BottomFace[3]:=Point(Page.Left+Sign*BlockDepth,Page.Bottom+Drop);
      end;
      // A cover follows each stack's depth, rather than leaving a solid bar
      // under the thinner half of an early/late spread.
      for J:=0 to 3 do Back[J]:=BottomFace[J];
      for J:=2 to 3 do begin Inc(Back[J].Y,Px(3)); Inc(Back[J].X,Sign*Px(2)); end;
      Canvas.Pen.Style:=psClear; Canvas.Brush.Color:=Cover; Canvas.Polygon(Back);
      Canvas.Brush.Color:=Edge; Canvas.Polygon(BottomFace);
      for Layer:=1 to Max(Drop,OtherDrop) do
      begin
        if Count=1 then
          Line(Page.Left-MulDiv(LeftDepth,Layer,Max(Drop,OtherDrop)),
            Page.Bottom+MulDiv(Drop,Layer,Max(Drop,OtherDrop)),
            Page.Right+MulDiv(RightDepth,Layer,Max(Drop,OtherDrop)),
            Page.Bottom+MulDiv(OtherDrop,Layer,Max(Drop,OtherDrop)),
            ReaderBlendColor(Edge,Cover,IfThen(Layer mod Px(2)=0,68,16)))
        else
          Line(Page.Left+Sign*MulDiv(BlockDepth,Layer,Drop),Page.Bottom+Layer,
            Page.Right+Sign*MulDiv(BlockDepth,Layer,Drop),Page.Bottom+Layer,
            ReaderBlendColor(Edge,Cover,IfThen(Layer mod Px(2)=0,68,16)));
      end;
    end;
  end;
begin
  Count:=Length(Pages); if (Count=0) or (Count>2) then Exit;
  for I:=0 to Count-1 do if Pages[I].IsEmpty then Exit;
  Book:=Pages[0]; if Count=2 then UnionRect(Book,Book,Pages[1]);
  MaximumDepth:=Min(Px(16),Max(Px(2),Pages[0].Left-Viewport.Left-Px(4)));
  if not Reflow then MaximumDepth:=Px(6);
  Progress:=EnsureRange(Progress,0.0,1.0);
  LeftDepth:=Max(Px(1),Round(MaximumDepth*Progress));
  RightDepth:=Max(Px(1),MaximumDepth-LeftDepth);
  BottomDepth:=Max(Px(1),Min(Px(10),Max(LeftDepth,RightDepth)*2 div 3));
  Desk:=ReaderBlendColor(Paper,RGB(52,43,33),IfThen(Night,70,75));
  Cover:=ReaderBlendColor(Paper,RGB(77,54,27),IfThen(Night,85,185));
  Edge:=ReaderBlendColor(Paper,RGB(121,107,82),IfThen(Night,45,68));
  ShadowColor:=ReaderBlendColor(clBlack,RGB(70,49,25),IfThen(Night,0,90));
  Saved:=SaveDC(Canvas.Handle);
  try
    IntersectClipRect(Canvas.Handle,Viewport.Left,Viewport.Top,Viewport.Right,Viewport.Bottom);
    // Desk, cover and leaves are clipped to the space outside the finished
    // page rasters. This also protects fixed-layout scans when zoomed/panned.
    CoverDC:=SaveDC(Canvas.Handle);
    try
      for I:=0 to Count-1 do
        ExcludeClipRect(Canvas.Handle,Pages[I].Left,Pages[I].Top,Pages[I].Right,Pages[I].Bottom);
      Canvas.Brush.Style:=bsSolid; Canvas.Brush.Color:=Desk;
      if Reflow then Canvas.FillRect(Viewport);
      CoverRect:=Rect(Book.Left-LeftDepth-Px(3),Book.Top+Px(2),
        Book.Right+RightDepth+Px(3),Book.Bottom+BottomDepth+Px(3));
      var BodyDC:=SaveDC(Canvas.Handle);
      try
        IntersectClipRect(Canvas.Handle,Viewport.Left,Viewport.Top,Viewport.Right,Book.Bottom);
        Canvas.Pen.Style:=psClear; Canvas.Brush.Color:=ReaderBlendColor(Desk,clBlack,45);
        R:=CoverRect; OffsetRect(R,Px(2),Px(3)); Canvas.RoundRect(R,Px(8),Px(8));
        Canvas.Brush.Color:=Cover; Canvas.RoundRect(CoverRect,Px(6),Px(6));
      finally RestoreDC(Canvas.Handle,BodyDC); end;
      Block(0,LeftDepth,-1); Block(Count-1,RightDepth,1);
    finally RestoreDC(Canvas.Handle,CoverDC); end;
    for I:=0 to Count-1 do
    begin
      R:=Pages[I]; Depth:=Min(Px(96),R.Width div 4);
      FoldWidth:=Max(Px(12),Depth);
      // Broad reflected light next to a soft fold gives the page a convex
      // surface. There is no opaque bevel or stretched source bitmap.
      if (Count=1) or (I=1) then
      begin
        Shade(Canvas,Rect(R.Left,R.Top,R.Left+FoldWidth,R.Bottom),ShadowColor,IfThen(Night,80,94),False);
        Shade(Canvas,Rect(R.Left+FoldWidth div 3,R.Top,R.Left+FoldWidth*2,R.Bottom),clWhite,IfThen(Night,8,14),False,True);
      end
      else
      begin
        Shade(Canvas,Rect(R.Right-FoldWidth,R.Top,R.Right,R.Bottom),ShadowColor,IfThen(Night,80,94),True);
        Shade(Canvas,Rect(R.Right-FoldWidth*2,R.Top,R.Right-FoldWidth div 3,R.Bottom),clWhite,IfThen(Night,8,14),False,True);
      end;
      // Quiet outside roll, straight highlight, and a fine lower paper edge.
      Direction:=1; if I=0 then Direction:=-1;
      if Direction<0 then Shade(Canvas,Rect(R.Left,R.Top,R.Left+Px(14),R.Bottom),ShadowColor,20,False)
      else Shade(Canvas,Rect(R.Right-Px(14),R.Top,R.Right,R.Bottom),ShadowColor,20,True);
      Line(R.Left,R.Top,R.Right,R.Top,ReaderBlendColor(Paper,clWhite,IfThen(Night,16,78)));
      Line(R.Left,R.Bottom-1,R.Right,R.Bottom-1,ReaderBlendColor(Paper,Cover,52));
    end;
    if Count=2 then
    begin
      Mid:=(Pages[0].Right+Pages[1].Left) div 2;
      if Pages[1].Left-Pages[0].Right<=Px(4) then
      begin
        Line(Mid-1,Book.Top+Px(1),Mid-1,Book.Bottom,ReaderBlendColor(Paper,ShadowColor,120));
        Line(Mid,Book.Top+Px(1),Mid,Book.Bottom,ReaderBlendColor(Paper,clWhite,IfThen(Night,18,44)));
      end;
    end;
  finally RestoreDC(Canvas.Handle,Saved); end;
end;

end.
