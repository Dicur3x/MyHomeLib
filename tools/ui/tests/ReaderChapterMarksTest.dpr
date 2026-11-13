program ReaderChapterMarksTest;
{$APPTYPE CONSOLE}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}
uses NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  System.Diagnostics, System.Math, System.Hash, Winapi.Windows, Winapi.Messages,
  Winapi.ActiveX, Vcl.Forms, Vcl.ExtCtrls, Vcl.Graphics, Vcl.Imaging.pngimage, Vcl.StdCtrls,
  unit_ReaderProgressMarks, unit_ReaderDocument, frm_BuiltinReader, dm_user;

procedure Require(Value:Boolean; const MessageText:string);
begin if not Value then raise Exception.Create(MessageText); end;

procedure WaitReady(Reader:TfrmBuiltinReader);
var Watch:TStopwatch;
begin
  Watch:=TStopwatch.StartNew;
  while not Reader.LoadFinished and (Watch.ElapsedMilliseconds<15000) do
  begin Application.ProcessMessages; CheckSynchronize(5); end;
  Require(Reader.Ready,'Reader not ready: '+Reader.ReaderStatus.Caption);
end;

procedure CheckChapterMarkLayout;
var Marks:TReaderProgressTicks; Pixel,Count:Integer;
begin
  SetLength(Marks,1024);
  // A normal book with 48 chapters must not lose marks to a 32-bucket cap.
  for var I:=1 to 48 do IncludeReaderProgressTick(Marks,I*1900,100000,0);
  Count:=0; for var Mark in Marks do if Mark<>0 then Inc(Count);
  Require(Count=48,'A 48-chapter book loses distinguishable progress marks');
  for var I:=13 to 16 do
  begin
    Pixel:=MulDiv(1023,I*1900,100000);
    Require(Marks[Pixel]<>0,'Chapter 13 to 16 disappeared from the progress strip');
  end;
  SetLength(Marks,0); SetLength(Marks,1024);
  IncludeReaderProgressTick(Marks,1000,100000,0);
  IncludeReaderProgressTick(Marks,1800,100000,1);
  IncludeReaderProgressTick(Marks,2600,100000,1);
  Require((Marks[MulDiv(1023,1000,100000)]<0) and
    (Marks[MulDiv(1023,1800,100000)]>0) and
    (Marks[MulDiv(1023,2600,100000)]>0),
    'Near the beginning, a part suppresses its separate subchapters');
  SetLength(Marks,0); SetLength(Marks,320);
  IncludeReaderProgressTick(Marks,10000,100000,1);
  IncludeReaderProgressTick(Marks,10001,100000,0);
  Require(Marks[MulDiv(319,10000,100000)]<0,'A true pixel collision loses the major section');
  Count:=0; for var Mark in Marks do if Mark<>0 then Inc(Count);
  Require(Count=1,'The same physical pixel creates artificial duplicate marks');
  IncludeReaderProgressTick(Marks,50000,100000,2);
  Require(Marks[MulDiv(319,50000,100000)]=0,'An unwanted third heading level is visible');
  IncludeReaderProgressTick(Marks,-1,100000,0);
  IncludeReaderProgressTick(Marks,100000,100000,0);
  Writeln('PASS chapter marks retain 48 chapters close subchapters and one nesting level with only physical pixel collisions');
end;

procedure AuditRealChapterMarks;
var Reader: TfrmBuiltinReader; Doc: TReaderDocument; Bar: TPaintBox;
  Name, OriginalHash: string; BookIndex, Width, Theme, Position, Pixel, Marks, MajorCount, MinorCount: Integer;
  Layout: TReaderPageLayout; Paint: TBitmap; PNG: TPngImage; Chapters: TArray<TReaderChapter>;
  Expected: TArray<ShortInt>; Seen: TArray<Boolean>;
  procedure CaptureBar;
  var DC:HDC; OldBitmap:HGDIOBJ;
  begin
    Paint.PixelFormat:=pf32bit; Paint.SetSize(Bar.Width,Bar.Height);
    DC:=CreateCompatibleDC(0); Require(DC<>0,'Cannot create progress capture DC');
    OldBitmap:=SelectObject(DC,Paint.Handle);
    try
      Bar.Perform(WM_PAINT,WPARAM(DC),0); GdiFlush;
    finally SelectObject(DC,OldBitmap); DeleteDC(DC); end;
  end;
begin
  CheckChapterMarkLayout;
  Application.CreateForm(TDMUser,DMUser); DMUser.Init;
  BookIndex:=0;
  for Name in ['750572.fb2','777922.fb2'] do
  begin
    Inc(BookIndex); OriginalHash:=THashSHA2.GetHashStringFromFile(Name);
    Doc:=TReaderDocument.Create;
    try Doc.Load(Name); Chapters:=Doc.Chapters; finally Doc.Free; end;
    MajorCount:=0; MinorCount:=0;
    for var Chapter in Chapters do
      if Chapter.Depth=0 then Inc(MajorCount) else if Chapter.Depth=1 then Inc(MinorCount);
    if BookIndex=1 then Require(MajorCount=48,'Real Winner fixture no longer has all 48 chapters')
    else Require(MinorCount=82,'Real Wool fixture no longer has all 82 subchapters');
    Reader:=TfrmBuiltinReader.Create(nil); Paint:=TBitmap.Create; PNG:=TPngImage.Create;
    try
      Reader.Show; Reader.OpenBook(Name,Name,'marks-'+Name,'marks-'+Name+'.ini','pdfium.dll'); WaitReady(Reader);
      Require(Reader.ChapterCount=Length(Chapters),'Reader lost a real table-of-contents item');
      Bar:=Reader.FindComponent('ReaderProgressLine') as TPaintBox;
      Require(Assigned(Bar),'Real Reader has no progress strip');
      for Width in TArray<Integer>.Create(600,1024) do
      begin
        Reader.ClientWidth:=Width;
        for Layout in [rplSingle,rplContinuous] do
        begin
          Reader.SetPageLayout(Layout);
          for Theme in [1,5] do
          begin
            Reader.SetTheme(Theme);
            for Position in [0,3] do
            begin
              Reader.GoToPosition(MulDiv(Reader.TextLength,Position,4)); Application.ProcessMessages;
              CaptureBar;
              PNG.Assign(Paint);
              PNG.SaveToFile(Format('marks-%d-%d-%d-%d-%d.png',[BookIndex,Width,Ord(Layout),Theme,Position]));
              SetLength(Expected,0); SetLength(Expected,Bar.Width);
              SetLength(Seen,0); SetLength(Seen,Bar.Width);
              for var Chapter in Chapters do
                if (Chapter.Depth<=1) and (Chapter.Position>0) and (Chapter.Position<Reader.TextLength) then
                begin
                  Pixel:=MulDiv(Bar.Width-1,Chapter.Position,Reader.TextLength);
                  Seen[Pixel]:=True;
                  if Chapter.Depth<=0 then Expected[Pixel]:=-1
                  else if Expected[Pixel]=0 then Expected[Pixel]:=1;
                  Require(Paint.Canvas.Pixels[Pixel,0]<>Paint.Canvas.Pixels[Pixel,Bar.Height-1],
                    Format('Unpainted real chapter %s at position %d pixel %d, width %d height %d layout %d theme %d position %d, first reader position %d, colors %x %x',
                      [Chapter.Title,Chapter.Position,Pixel,Bar.Width,Bar.Height,Ord(Layout),Theme,Position,
                      NativeInt((Reader.FindComponent('ReaderChapterSelector') as TComboBox).Items.Objects[0]),
                      Paint.Canvas.Pixels[Pixel,0],Paint.Canvas.Pixels[Pixel,Bar.Height-1]]));
                end;
              Marks:=0; for var I:=0 to High(Seen) do if Seen[I] then Inc(Marks);
              for var I:=0 to High(Expected) do
                if (Expected[I]<>0) and ((I=0) or (Expected[I-1]=0)) and
                  ((I=High(Expected)) or (Expected[I+1]=0)) then
                begin
                  var PaintedHeight:=0;
                  while (PaintedHeight<Bar.Height) and
                    (Paint.Canvas.Pixels[I,PaintedHeight]<>Paint.Canvas.Pixels[I,Bar.Height-1]) do Inc(PaintedHeight);
                  Require(PaintedHeight<Bar.Height,'Chapter mark covers the complete progress strip');
                  if Expected[I]>0 then Require(PaintedHeight<=MulDiv(Bar.Height,1,3),'Subchapter mark is as tall as a major chapter');
                end;
              PNG.Assign(Paint);
              PNG.SaveToFile(Format('marks-%d-%d-%d-%d-%d.png',[BookIndex,Width,Ord(Layout),Theme,Position]));
              Writeln(Format('PASS real chapter paint book=%s chapters=%d subchapters=%d marks=%d width=%d layout=%d theme=%d progress=%d',
                [Name,MajorCount,MinorCount,Marks,Bar.Width,Ord(Layout),Theme,Position])); Flush(Output);
            end;
          end;
        end;
      end;
      Reader.Close;
    finally PNG.Free; Paint.Free; Reader.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Name)=OriginalHash,'Real book changed while checking chapter marks');
  end;
  Writeln('PASS real chapter marks visible on filled and unread track in paged and continuous reading');
end;


var Preview:TfrmBuiltinReader; Name:string;
begin
  RequireIsolatedRegression; CoInitialize(nil);
  try
    Application.Initialize; Application.MainFormOnTaskBar:=True;
    if (ParamCount>0) and (ParamStr(1)='preview') then
    begin
      Application.CreateForm(TDMUser,DMUser); DMUser.Init;
      Application.CreateForm(TfrmBuiltinReader,Preview);
      Name:=ExtractFileName(ParamStr(2));
      Preview.Show; Preview.ClientWidth:=1024;
      Preview.OpenBook(Name,'HomeLibre chapter mark preview','chapter-preview','preview.ini','pdfium.dll');
      WaitReady(Preview); Preview.SetTheme(1); Preview.GoToChapter(14);
      Application.Run;
    end
    else AuditRealChapterMarks;
    Writeln('PASS Reader real chapter mark regression');
  except on E:Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); Flush(Output); Halt(1); end; end;
  CoUninitialize;
end.
