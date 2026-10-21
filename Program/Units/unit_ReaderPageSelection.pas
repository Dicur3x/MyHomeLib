unit unit_ReaderPageSelection;

interface

uses System.Classes, System.Types, Vcl.ComCtrls, Vcl.Controls, Vcl.StdCtrls, Vcl.Forms;

type
  // Build a native hit-test layout only for the visible page, on first selection.
  // The whole book keeps its bounded, bitmap-based pagination path.
  TReaderPageSelection = class
  private
    FEdit: TRichEdit;
    FOle: IInterface;
    FStart, FLength, FOffsetX: Integer;
    FReady: Boolean;
    function CharacterPoint(Index: Integer): TPoint;
  public
    constructor Create(Owner: TComponent; Parent: TWinControl);
    destructor Destroy; override;
    procedure Clear;
    procedure Prepare(Source: TRichEdit; Start, Count, Width, Height, DPI: Integer; const Content: TRect; OffsetX: Integer = 0);
    function CharacterAt(X,Y: Integer): Integer;
    function Rectangles(Start, Finish: Integer): TArray<TRect>;
    property Ready: Boolean read FReady;
  end;

implementation

uses Winapi.Windows, Winapi.Messages, Winapi.RichEdit, System.SysUtils,
  System.Math, System.Generics.Collections, unit_ReaderRichEdit;

constructor TReaderPageSelection.Create(Owner: TComponent; Parent: TWinControl);
begin
  inherited Create;
  FEdit:=TRichEdit.Create(Owner); FEdit.Parent:=Parent; FEdit.Visible:=False;
  FEdit.StyleElements:=[]; FEdit.BorderStyle:=bsNone; FEdit.ScrollBars:=ssNone;
  FEdit.ReadOnly:=True; FEdit.WordWrap:=True;
  SendMessage(FEdit.Handle,EM_SETUNDOLIMIT,0,0);
  FOle:=AttachReaderPictures(FEdit);
end;

destructor TReaderPageSelection.Destroy;
begin FOle:=nil; FEdit.Free; inherited; end;

procedure TReaderPageSelection.Clear;
begin FReady:=False; FStart:=0; FLength:=0; FOffsetX:=0; FEdit.Clear; end;

procedure TReaderPageSelection.Prepare(Source: TRichEdit; Start, Count, Width, Height, DPI: Integer; const Content: TRect; OffsetX: Integer);
var Stream: TMemoryStream; Bounds: TRect; Scroll: TPoint;
  Paragraph: TParaFormat2; Selection: TCharRange; Previous: string;
begin
  FReady:=False;
  if (Count<=0) or (Count>262144) then Exit;
  Stream:=TMemoryStream.Create;
  try
    // Keep a bounded continuation after the page. Otherwise the clone treats
    // the last visible line as the end of its paragraph and stops justifying it.
    ReaderSaveRTFRange(Source,Stream,Start,Count+4096); Stream.Position:=0;
    FEdit.SetBounds(0,0,Width,Height);
    ReaderLoadRTF(FEdit,Stream);
    if Start>0 then
    begin
      Previous:=ReaderTextRange(Source,Start-1,1);
      if (Previous<>#13) and (Previous<>#10) then
      begin
        // A selected RTF range becomes a new paragraph in the clone. The
        // native page renderer continues the original paragraph here, so
        // its first-line indent, spacing and list marker must not repeat.
        Selection.cpMin:=0; Selection.cpMax:=0;
        SendMessage(FEdit.Handle,EM_EXSETSEL,0,LPARAM(@Selection));
        FillChar(Paragraph,SizeOf(Paragraph),0); Paragraph.cbSize:=SizeOf(Paragraph);
        SendMessage(FEdit.Handle,EM_GETPARAFORMAT,0,LPARAM(@Paragraph));
        Paragraph.dwMask:=PFM_STARTINDENT or PFM_OFFSET or PFM_SPACEBEFORE or PFM_NUMBERING;
        Inc(Paragraph.dxStartIndent,Paragraph.dxOffset); Paragraph.dxOffset:=0;
        Paragraph.dySpaceBefore:=0; Paragraph.wNumbering:=0;
        SendMessage(FEdit.Handle,EM_SETPARAFORMAT,0,LPARAM(@Paragraph));
      end;
    end;
    // Match the drawing DC rather than the monitor's control zoom.
    SendMessage(FEdit.Handle,EM_SETZOOM,DPI,Max(1,FEdit.Font.PixelsPerInch));
    Bounds:=Content; SendMessage(FEdit.Handle,EM_SETRECT,0,LPARAM(@Bounds));
    Scroll:=Point(0,0); SendMessage(FEdit.Handle,EM_SETSCROLLPOS,0,LPARAM(@Scroll));
    FOffsetX:=OffsetX; FStart:=Start; FLength:=Min(Count,ReaderTextLength(FEdit)); FReady:=True;
  finally Stream.Free; end;
end;

function TReaderPageSelection.CharacterPoint(Index: Integer): TPoint;
begin
  Result:=Point(0,0);
  SendMessage(FEdit.Handle,EM_POSFROMCHAR,WPARAM(@Result),EnsureRange(Index,0,FLength));
end;

function TReaderPageSelection.CharacterAt(X,Y: Integer): Integer;
var P: TPoint; Index: Integer;
begin
  Result:=-1; if not FReady then Exit;
  P:=Point(EnsureRange(X-FOffsetX,0,Max(0,FEdit.ClientWidth-1)),EnsureRange(Y,0,Max(0,FEdit.ClientHeight-1)));
  Index:=SendMessage(FEdit.Handle,EM_CHARFROMPOS,0,LPARAM(@P));
  if (Index<0) or (Index>FLength) then Exit;
  Result:=FStart+ReaderCharacterStart(FEdit,Index);
end;

function TReaderPageSelection.Rectangles(Start, Finish: Integer): TArray<TRect>;
var Boxes: TList<TRect>; First, Last, Line, LineStart, LineEnd, NextLine, A,B: Integer;
  P,Q,Next: TPoint; R: TRect;
begin
  Result:=nil; if not FReady then Exit;
  First:=EnsureRange(Min(Start,Finish)-FStart,0,FLength);
  Last:=EnsureRange(Max(Start,Finish)-FStart,0,FLength);
  if Last<=First then Exit;
  Boxes:=TList<TRect>.Create;
  try
    Line:=SendMessage(FEdit.Handle,EM_LINEFROMCHAR,First,0);
    while Line<SendMessage(FEdit.Handle,EM_GETLINECOUNT,0,0) do
    begin
      LineStart:=SendMessage(FEdit.Handle,EM_LINEINDEX,Line,0);
      if (LineStart<0) or (LineStart>=Last) then Break;
      NextLine:=SendMessage(FEdit.Handle,EM_LINEINDEX,Line+1,0);
      if NextLine<0 then LineEnd:=FLength else LineEnd:=NextLine;
      A:=Max(First,LineStart); B:=Min(Last,LineEnd);
      P:=CharacterPoint(A); Q:=CharacterPoint(B);
      if Q.Y<>P.Y then
      begin
        Q:=CharacterPoint(Max(A,B-1));
        Inc(Q.X,Max(2,MulDiv(FEdit.Font.Size,FEdit.Font.PixelsPerInch,144)));
      end;
      if NextLine>=0 then Next:=CharacterPoint(NextLine)
      else Next:=Point(P.X,P.Y+Max(12,MulDiv(FEdit.Font.Size,96,60)));
      R:=Rect(Min(P.X,Q.X),P.Y,Max(P.X,Q.X),Max(P.Y+12,Next.Y));
      if (R.Width>0) and (R.Top<FEdit.ClientHeight) then begin OffsetRect(R,FOffsetX,0); Boxes.Add(R); end;
      Inc(Line);
    end;
    Result:=Boxes.ToArray;
  finally Boxes.Free; end;
end;

end.
