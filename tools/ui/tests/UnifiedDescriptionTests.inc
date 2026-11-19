type
  TUnifiedDescriptionProbe = class
    Timer: TTimer;
    Expected, Origin, Draft, Failure, Capture: string;
    Operation: Integer;
    Deadline: UInt64;
    Done, EditEntry: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TUnifiedDescriptionProbe.Tick(Sender: TObject);
var Details: TfrmBookDetails; Save, Restore: TButton; Bitmap: TBitmap; PNG: TPngImage;
begin
  for var I:=0 to Screen.FormCount-1 do
  begin
    if not (Screen.Forms[I] is TfrmBookDetails) or not Screen.Forms[I].Visible then Continue;
    Details:=TfrmBookDetails(Screen.Forms[I]);
    if Assigned(Details.Downloading) and (GetTickCount64<Deadline) then Exit;
    Timer.Enabled:=False;
    try
      Require(not Assigned(Details.Downloading),'Initial description worker did not finish');
      Save:=Details.FindComponent('btnSaveDescription') as TButton;
      Restore:=Details.FindComponent('btnRestoreDescription') as TButton;
      Require(Assigned(Save) and Save.Visible and Save.Enabled and Assigned(Restore),
        'The two description entry points do not offer explicit save and cancel');
      Require((Details.btnClose.Caption='Отмена') and (Save.Caption='Сохранить'),
        'Book details still imply saving on Close');
      Require((Details.Annotation.Trim=Expected) and not Details.ReviewChanged and not Details.AnnotationChanged,
        'Initial description differs between entries or viewing it counts as an edit');
      Require(string(Details.lblAnnotationState.Caption).Contains(Origin) and
        string(Details.lblAnnotationState.Caption).Contains('Файл книги не меняется'),
        'Description source or storage destination is not explained');
      if EditEntry then
        Require(Details.pcBookInfo.ActivePage=Details.tsAnnotation,
          'The edit command did not open the description tab')
      else
        Details.pcBookInfo.ActivePage:=Details.tsAnnotation;
      if Capture<>'' then
      begin
        Bitmap:=Details.GetFormImage; PNG:=TPngImage.Create;
        try PNG.Assign(Bitmap); PNG.SaveToFile(Capture); finally PNG.Free; Bitmap.Free; end;
      end;
      case Operation of
        0: Details.Close; // X/Cancel does not save an implicit file preview.
        1: begin Details.mmoAnnotation.Text:=Draft; Details.mmReview.Text:='Cancelled review'; Details.btnClose.Click; end;
        2: begin Details.mmoAnnotation.Text:=Draft; Save.Click; end;
        3: begin
          Details.mmoAnnotation.Text:=Draft; Details.mmReview.Text:='Review retained after description undo';
          Require(Restore.Enabled,'Description undo was not enabled after editing'); Restore.Click;
          Require((Details.Annotation.Trim=Expected) and not Details.AnnotationChanged and
            string(Details.mmReview.Text).Contains('retained'),'Undo description also changed reviews');
          Save.Click;
        end;
        4: begin Details.mmReview.Text:='Only review changed'; Save.Click; end;
        5: begin Details.btnAnnotationFile.Click; Require(Details.AnnotationChanged,'Explicit source selection was not marked'); Save.Click; end;
        6: Save.Click;
        7: begin Details.mmoAnnotation.Text:=Draft; Details.Close; end;
      end;
      Done:=True;
    except on E:Exception do begin Failure:=E.ClassName+': '+E.Message; Details.Close; end; end;
    Exit;
  end;
end;

procedure TestUnifiedDescription(const Collection: IBookCollection; CollectionID: Integer);
const FileDescription='Описание из книги — ё, ї, ў.';
  SavedDescription='Своё описание в HomeLibre — ё 😀';
var Key: TBookKey; Book, RowBook: TBookRecord; SourceFile, SourceHash: string;
  Probe: TUnifiedDescriptionProbe;
  procedure OpenEntry(EditEntry: Boolean; Operation: Integer; const Expected, Origin, Draft, StoredAfter: string);
  begin
    Collection.GetBookRecord(Key,RowBook,True);
    frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Collection.GetBookIterator(bmAll,False),False,False,@Key);
    frmMain.tvBooksSR.FocusedNode:=frmMain.tvBooksSR.GetFirstSelected;
    Probe:=TUnifiedDescriptionProbe.Create;
    try
      Probe.Expected:=Expected; Probe.Origin:=Origin; Probe.Draft:=Draft; Probe.Operation:=Operation;
      Probe.EditEntry:=EditEntry;
      Probe.Deadline:=GetTickCount64+15000;
      if Operation=0 then Probe.Capture:='description-'+IntToStr(Ord(EditEntry))+'.png';
      Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=25; Probe.Timer.OnTimer:=Probe.Tick;
      if EditEntry then frmMain.acEditBook.Execute else frmMain.acBookDetails.Execute;
      Require(Probe.Done and (Probe.Failure=''),'Unified description: '+Probe.Failure);
    finally Probe.Timer.Free; Probe.Free; end;
    Collection.GetBookRecord(Key,Book,True);
    Require((Book.Annotation.Trim=StoredAfter) and (Book.KeyWords='Unchanged keywords') and
      (UpdateSHA256(SourceFile)=SourceHash),
      Format('Description action %d stored unexpected metadata or changed the source book',[Operation]));
  end;
begin
  RequireIsolatedRegression;
  Key:=CreateBookKey(AddBook(Collection,'unified-description','Description','ru','Unified description fixture','0.1'),CollectionID);
  Collection.GetBookRecord(Key,Book,True); Book.KeyWords:='Unchanged keywords'; Collection.UpdateBook(Book);
  SourceFile:=Book.GetBookFileName;
  TFile.WriteAllText(SourceFile,'<?xml version="1.0" encoding="UTF-8"?>'+
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
    '<genre>prose_contemporary</genre><author><nickname>Fixture</nickname></author><book-title>Fixture</book-title>'+
    '<annotation><p>'+FileDescription+'</p></annotation></title-info></description><body><section><p>Book text.</p>'+
    '</section></body></FictionBook>',TEncoding.UTF8);
  SourceHash:=UpdateSHA256(SourceFile);
  ShowPage(PAGE_SEARCH); frmMain.Show;
  OpenEntry(False,0,FileDescription,'из файла','','');
  OpenEntry(True,0,FileDescription,'из файла','','');
  OpenEntry(False,4,FileDescription,'из файла','','');
  Require(Book.Review.Trim='Only review changed','Explicit review save failed');
  OpenEntry(False,2,FileDescription,'из файла',SavedDescription,SavedDescription);
  OpenEntry(False,1,SavedDescription,'сохранённое','Cancelled from ordinary details',SavedDescription);
  OpenEntry(False,7,SavedDescription,'сохранённое','Cancelled by window close',SavedDescription);
  OpenEntry(True,1,SavedDescription,'сохранённое','Must be cancelled',SavedDescription);
  Require(Book.Review.Trim='Only review changed','Cancel saved an unrelated review change');
  OpenEntry(False,3,SavedDescription,'сохранённое','Temporary draft',SavedDescription);
  Require(Book.Review.Trim='Review retained after description undo','Undo discarded an explicit review edit');
  OpenEntry(True,5,SavedDescription,'сохранённое','','');
  OpenEntry(False,6,FileDescription,'из файла','','');
  Writeln('PASS unified description Main entries save cancel source preview explicit file restore and unchanged book');
end;

procedure TestDescriptionPackagePreview;
var Book: TBookRecord; Form: TfrmBookDetails; Zip: TZipFile; SourceFile, SourceHash: string; Watch: TStopwatch;
begin
  Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath;
  Book.FileName:='unified-package'; Book.FileExt:='.epub';
  SourceFile:=Book.GetBookFileName;
  Zip:=TZipFile.Create;
  try
    Zip.Open(SourceFile,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'+
      '<rootfiles><rootfile full-path="book.opf"/></rootfiles></container>'),'META-INF/container.xml');
    Zip.Add(TEncoding.UTF8.GetBytes('<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'+
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fixture</dc:title>'+
      '<dc:description>Package description — ё.</dc:description></metadata></package>'),'book.opf');
    Zip.Close;
  finally Zip.Free; end;
  SourceHash:=UpdateSHA256(SourceFile);
  for var Editable in [False,True] do
  begin
    Form:=TfrmBookDetails.Create(nil);
    try
      Form.ConfigureDescription(Book,Editable,True); Form.Review:='Saved review'; Form.LoadDescription('');
      Watch:=TStopwatch.StartNew;
      while Assigned(Form.Downloading) and (Watch.ElapsedMilliseconds<10000) do
      begin Application.ProcessMessages; CheckSynchronize(5); end;
      Require(not Assigned(Form.Downloading) and (Form.Annotation.Trim='Package description — ё.') and
        not Form.AnnotationChanged and not Form.ReviewChanged and (Form.mmoAnnotation.ReadOnly=not Editable),
        'Initial EPUB description preview edited data or changed permissions');
      Require((Form.Review.Trim='Saved review') and (UpdateSHA256(SourceFile)=SourceHash),
        'Initial EPUB metadata preview changed review or source');
    finally Form.Free; end;
  end;
  Writeln('PASS editable and read-only EPUB initial description uses metadata without changing stored text or source');
end;

type
  TDescriptionServer = class
    HTTP: TIdHTTPServer;
    Mode: Integer;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  end;

procedure TDescriptionServer.Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
begin
  if Request.Document<>'/b/1/' then begin Response.ResponseNo:=404; Exit; end;
  if Mode=1 then begin Response.ResponseNo:=403; Exit; end;
  Response.ContentType:='text/html'; Response.CharSet:='utf-8';
  if Mode=2 then Response.ContentText:='<html><h2>Аннотация</h2><form></form></html>'
  else Response.ContentText:='<html><h2>Аннотация</h2><p>Site description — ё.</p><form></form>'+
    '<h2>Отзывы</h2><a href="/polka/show/1">Reader</a><br><p>Site review.</p><div id="newann"></div></html>';
end;

procedure TestDescriptionSiteAndLayout;
var Book:TBookRecord; Form:TfrmBookDetails; Server:TDescriptionServer; Watch:TStopwatch;
  SavedDark:Boolean; Save,Restore:TButton; Bitmap:TBitmap; PNG:TPngImage;
  procedure WaitText;
  begin
    Watch:=TStopwatch.StartNew;
    while Assigned(Form.Downloading) and (Watch.ElapsedMilliseconds<10000) do
    begin Application.ProcessMessages; CheckSynchronize(5); end;
    Require(not Assigned(Form.Downloading),'Description request did not finish');
  end;
begin
  Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath;
  Book.FileName:='unified-package'; Book.FileExt:='.epub';
  Server:=TDescriptionServer.Create; Server.HTTP:=TIdHTTPServer.Create(nil);
  SavedDark:=MHLThemeDark;
  try
    Server.HTTP.OnCommandGet:=Server.Command; Server.HTTP.KeepAlive:=False;
    with Server.HTTP.Bindings.Add do begin IP:='127.0.0.1'; Port:=0; end;
    Server.HTTP.Active:=True;
    Form:=TfrmBookDetails.Create(nil);
    try
      Form.ConfigureDescription(Book,True,True); Form.Review:='Original review'; Form.LoadDescription('');
      Form.AllowOnlineReview(Format('http://127.0.0.1:%d/b/1/',[Server.HTTP.Bindings[0].Port]));
      Form.Download; // A review request queues behind the automatic local metadata preview.
      WaitText;
      Require((Form.Annotation.Trim='Package description — ё.') and not Form.AnnotationChanged and
        Form.Review.Contains('Site review.'),'Queued reviews overwrote the initial file description or were lost');
      Form.Review:='Review to preserve'; Form.ReviewChanged:=False;
      Form.btnAnnotationSite.Click; WaitText;
      Require((Form.Annotation.Trim='Site description — ё.') and Form.AnnotationChanged and Form.ReviewChanged and
        (Form.Review.Trim='Review to preserve') and string(Form.lblAnnotationState.Caption).Contains('с сайта'),
        'Explicit site description changed review or hid its source');
      Restore:=Form.FindComponent('btnRestoreDescription') as TButton; Restore.Click;
      Require((Form.Annotation.Trim='Package description — ё.') and not Form.AnnotationChanged,
        'Undo did not return the initial file preview after a site replacement');
      Server.Mode:=1; Form.btnAnnotationSite.Click; WaitText;
      Require((Form.Annotation.Trim='Package description — ё.') and not Form.AnnotationChanged and
        string(Form.lblAnnotationState.Caption).Contains('Не удалось'),'Failed site request erased the description');
      Server.Mode:=2; Form.btnAnnotationSite.Click; WaitText;
      Require((Form.Annotation.Trim='Package description — ё.') and not Form.AnnotationChanged and
        string(Form.lblAnnotationState.Caption).Contains('нет описания'),'Empty site response erased the description');
    finally Form.Free; end;
    Writeln('PASS queued review request explicit site description source error empty response and undo preserve other text');
    for var Dark in [False,True] do
      for var DPI in [96,216] do
      begin
        SetMHLTheme(Dark); Form:=TfrmBookDetails.Create(nil);
        try
          Form.ConfigureDescription(Book,True,True); Form.LoadDescription('Saved description');
          Form.ScaleForPPI(DPI); ApplyMHLControlTheme(Form); Form.Show;
          var Guide:=Form.FindComponent('BookDescriptionContextGuide') as TContextToolGuide;
          var BeforeShow:=GetTickCount64+60;
          repeat Application.ProcessMessages; Sleep(1); until GetTickCount64>=BeforeShow;
          Require(not IsWindowVisible(Guide.HelpButton.Handle) and (Guide.FindComponent('ToolGuidePopupbookdescription')=nil),
            'Description guide appeared on a different tab');
          Form.FocusDescription;
          Application.ProcessMessages;
          Save:=Form.FindComponent('btnSaveDescription') as TButton;
          Restore:=Form.FindComponent('btnRestoreDescription') as TButton;
          Require((Save.BoundsRect.Right+MulDiv(8,DPI,96)=Form.btnClose.Left) and
            (Form.btnClose.BoundsRect.Right+MulDiv(12,DPI,96)=Form.pnButtons.ClientWidth) and
            (Save.BoundsRect.Bottom<=Save.Parent.ClientHeight) and
            (Restore.BoundsRect.Right<=Restore.Parent.ClientWidth) and
            (Form.mmoAnnotation.Height>MulDiv(120,DPI,96)),
            'Description controls overlap or lose useful editor space at scaled DPI');
          Require((Form.lblAnnotationState.BoundsRect.Right<=Guide.HelpButton.Left) and
            (Form.pnAnnotationHeader.BoundsRect.Bottom<=Form.mmoAnnotation.Top),
            'Description source, question button and editor overlap');
          Form.mmoAnnotation.Text:='Черновик'; Form.mmReview.Text:='Правка отзыва';
          Guide.HelpButton.Click;
          var Popup:=Guide.FindComponent('ToolGuidePopupbookdescription') as TForm;
          Require(Popup.Visible,'Manual description guide did not open');
          Form.pcBookInfo.SetFocus;
          var TabPoint:=Form.pcBookInfo.TabRect(Form.tsReview.TabIndex).CenterPoint;
          var ClickPos:=MakeLParam(TabPoint.X,TabPoint.Y);
          Form.pcBookInfo.Perform(WM_LBUTTONDOWN,MK_LBUTTON,ClickPos);
          Form.pcBookInfo.Perform(WM_LBUTTONUP,0,ClickPos); Application.ProcessMessages;
          Require(Form.pcBookInfo.ActivePage=Form.tsReview,'Clicking Reviews did not switch the tab');
          Require(not Popup.Visible and not IsWindowVisible(Guide.HelpButton.Handle),
            'Description guide followed the user to the reviews tab');
          Form.FocusDescription;
          Require((Form.Annotation.Trim='Черновик') and (Form.Review.Trim='Правка отзыва') and
            Form.AnnotationChanged and Restore.Enabled,'Help or switching tabs discarded a draft');
          Restore.Click;
          Require((Form.Annotation.Trim='Saved description') and (Form.Review.Trim='Правка отзыва'),
            'Undo after contextual help also reverted the review');
          Guide.HelpButton.Click; Form.Hide; Application.ProcessMessages;
          Require(not Popup.Visible,'Hiding book details left its description guide open');
          Form.Show; Application.ProcessMessages;
          Bitmap:=Form.GetFormImage; PNG:=TPngImage.Create;
          try
            PNG.Assign(Bitmap); PNG.SaveToFile(Format('description-layout-%d-%d.png',[Ord(Dark),DPI]));
          finally PNG.Free; Bitmap.Free; end;
          Writeln('PASS description dialog layout theme=',Ord(Dark),' dpi=',DPI);
          Form.Close;
        finally Form.Free; end;
      end;
  finally
    SetMHLTheme(SavedDark); Server.HTTP.Active:=False; Server.HTTP.Free; Server.Free;
  end;
end;
