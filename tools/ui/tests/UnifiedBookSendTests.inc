// Exercise the public Main command, its real options dialog and production worker.
type
  TUnifiedSendProbe = class
    Timer: TTimer;
    FormatIndex, ImageIndex, Dialogs, QualityDialogs: Integer;
    CancelOptions, CancelQuality, ShellSurrogate: Boolean;
    VerifyInitial: Boolean;
    Initial: TBookSendOptions;
    Destination, Failure, FolderMask: string;
    Deadline: UInt64;
    SavedModal, SavedShow: TNotifyEvent;
    SavedClose: unit_Events.TProgressCloseEvent;
    Worker: TExportToDeviceThread;
    Results: TBookExportResults;
    Messages: TStringList;
    procedure ModalBegin(Sender: TObject);
    procedure Shown(Sender: TObject);
    procedure Finished;
    procedure Tick(Sender: TObject);
    function Message(const Text: string; Flags: Longint): Integer;
  end;

procedure TUnifiedSendProbe.ModalBegin(Sender: TObject);
begin
  if Assigned(SavedModal) then SavedModal(Sender);
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TExportToDeviceProgressForm) and not Screen.Forms[I].Visible then
    begin
      var Progress:=TExportToDeviceProgressForm(Screen.Forms[I]);
      Worker:=TExportToDeviceThread(Progress.WorkerThread);
      Require(Worker.Suspended,'Unified send lost the pre-start export snapshot');
      if ShellSurrogate then
      begin
        var Item: IShellItem; var Marshaled: IStream;
        Require(Succeeded(SHCreateItemFromParsingName(PChar(Destination),nil,IShellItem,Item)),'Cannot create owned Shell destination');
        Require(Succeeded(CoMarshalInterThreadInterfaceInStream(IShellItem,Item,Marshaled)),'Cannot marshal owned Shell destination');
        Worker.UseMTP:=True; Worker.MarshalStream:=Marshaled;
      end;
      SavedShow:=Progress.OnShow; Progress.OnShow:=Shown; Exit;
    end;
end;

procedure TUnifiedSendProbe.Shown(Sender: TObject);
begin
  if Assigned(SavedShow) then SavedShow(Sender);
  Worker.OnShowMessage:=Message; SavedClose:=Worker.OnCloseProgress; Worker.OnCloseProgress:=Finished;
end;

procedure TUnifiedSendProbe.Finished;
begin Results:=Worker.Results; if Assigned(SavedClose) then SavedClose; end;

function TUnifiedSendProbe.Message(const Text: string; Flags: Longint): Integer;
begin Messages.Add(Text); if (Flags and $F)=MB_YESNO then Result:=IDYES else Result:=IDOK; end;

procedure TUnifiedSendProbe.Tick(Sender: TObject);
begin
  if GetTickCount64>Deadline then
  begin
    Failure:='Unified send timed out'; Timer.Enabled:=False;
    if Assigned(Worker) then Worker.Cancel;
    for var I:=Screen.FormCount-1 downto 0 do
      if Screen.Forms[I].Visible and (Screen.Forms[I]<>frmMain) and
        not (Screen.Forms[I] is TExportToDeviceProgressForm) then
        Screen.Forms[I].ModalResult:=mrCancel;
    Exit;
  end;
  for var I:=Screen.FormCount-1 downto 0 do
  begin
    var Dialog:=Screen.Forms[I]; if not Dialog.Visible then Continue;
    if Dialog is TBookSendOptionsForm then
    begin
      Inc(Dialogs);
      var Formats:=TComboBox(Dialog.FindComponent('SendFormat'));
      var Images:=TComboBox(Dialog.FindComponent('SendImages'));
      if VerifyInitial then
      begin
        Require(TComboBox(Dialog.FindComponent('SaveNameCollision')).ItemIndex=Ord(Initial.NameCollision),
          'Restored overwrite choice was lost');
        Require(TEdit(Dialog.FindComponent('SendDestination')).Text=Initial.Folder,'Restored save destination was replaced');
        Require(TEdit(Dialog.FindComponent('SaveNameTemplate')).Text=Initial.FileNameTemplate,'Restored filename mask was lost');
        Require(TCheckBox(Dialog.FindComponent('SaveSubfolders')).Checked and
          (TEdit(Dialog.FindComponent('SaveFolderTemplate')).Text=Initial.FolderTemplate),'Restored subfolders were lost');
        Require(not Assigned(Dialog.FindComponent('SendZIP')) and (Images.ItemIndex=2),'Obsolete ZIP checkbox returned or restored image choice was lost');
        Require((TComboBox(Dialog.FindComponent('SaveScanLayout')).ItemIndex=1) and
          (TEdit(Dialog.FindComponent('SaveScanExceptions')).Text='1,9-10'),'Restored scan layout or exclusions were lost');
        if Initial.Mode=emFB2Zip then
          Require(string(Formats.Text).Contains('FB2 в ZIP'),'Restored explicit FB2 ZIP choice was lost')
        else if Initial.KeepFB2EPUB then
          Require((Pos('FB2',Formats.Text)>0) and (Pos('EPUB',Formats.Text)>0),'Restored mixed source policy was lost')
        else Require(Formats.Text='Преобразовать в EPUB','Restored EPUB conversion policy was lost');
        var Preview:=TLabel(Dialog.FindComponent('SaveNamePreview'));
        Require(string(Preview.Hint).Contains(Initial.Folder) and
          string(Preview.Caption).StartsWith('Сохранить как'),
          'Save example omits its generated filename or full destination hint');
        Dialog.ModalResult:=mrCancel; Exit;
      end;
      Require(Assigned(Formats) and Assigned(Images),'Unified send controls are missing');
      Require(Images.Items.Count=4,'Save As must have exactly four image modes');
      var Collision:=TComboBox(Dialog.FindComponent('SaveNameCollision'));
      Require(Assigned(Collision) and (Collision.Items.Count=3) and
        not Assigned(Dialog.FindComponent('SaveOverwriteExisting')),'Save As still has an unclear overwrite checkbox');
      for var Caption in Formats.Items do
        Require(not Caption.StartsWith('TXT') and not Caption.Contains('внешний конвертер') and
          not Caption.StartsWith('Сценарий:'),'Legacy formats/scripts leaked into the Save As selector');
      Formats.ItemIndex:=0;
      if FormatIndex in [1,2] then
      begin
        var Caption:='Преобразовать в FB2'; if FormatIndex=2 then Caption:=Caption+' в ZIP';
        var Index:=Formats.Items.IndexOf(Caption);
        if Index>=0 then Formats.ItemIndex:=Index
        else
        begin
          Caption:='Оставить FB2'; if FormatIndex=2 then Caption:=Caption+' в ZIP';
          Index:=Formats.Items.IndexOf(Caption); Require(Index>=0,'Missing FB2 save policy'); Formats.ItemIndex:=Index;
        end;
      end
      else if FormatIndex=3 then
      begin
        var Index:=Formats.Items.IndexOf('Преобразовать в EPUB');
        if Index>=0 then Formats.ItemIndex:=Index
        else Require(Formats.Items[0]='Оставить EPUB','Missing EPUB save policy');
      end;
      Formats.OnChange(Formats);
      Require(not Assigned(Dialog.FindComponent('SendZIP')),'ZIP packaging must be an explicit FB2 format choice');
      Images.ItemIndex:=ImageIndex; Images.OnChange(Images);
      Require(Images.Enabled,'Mixed FB2/EPUB image processing is unexpectedly disabled');
      Require(Assigned(Dialog.FindComponent('SaveNameTemplate')) and Assigned(Dialog.FindComponent('SaveNamePreview')),
        'Filename template and example are not visible in Save As');
      TEdit(Dialog.FindComponent('SendDestination')).Text:=Destination;
      TCheckBox(Dialog.FindComponent('SaveSubfolders')).Checked:=FolderMask<>'';
      if FolderMask<>'' then TEdit(Dialog.FindComponent('SaveFolderTemplate')).Text:=FolderMask;
      var Files:=TListView(Dialog.FindComponent('SaveBookSizes'));
      var Preview:=TLabel(Dialog.FindComponent('SaveNamePreview'));
      if Files.Items.Count>1 then
      begin
        Require(not Files.HideSelection,'Editing a save mask hides the book used for its preview');
        for var Index in TArray<Integer>.Create(Files.Items.Count-1,0) do
        begin
          var Entry:=Files.Items[Index]; Files.Selected:=Entry; Files.OnData(Files,Entry);
          var Position:=Format('(%d из %d): ',[Index+1,Files.Items.Count]);
          var Suffix:='.'+LowerCase(Entry.SubItems[0]).Replace(' в zip','.zip');
          Require(string(Preview.Caption).Contains(Position) and string(Preview.Caption).EndsWith(Suffix),
            'Selected mixed book does not preview its own position and target extension');
          var Mask:=TEdit(Dialog.FindComponent('SaveNameTemplate')); var SavedMask:=Mask.Text;
          try
            Mask.Text:='проба-'+SavedMask;
            Require(string(Preview.Caption).Contains(Position) and string(Preview.Caption).Contains('проба-') and
              string(Preview.Caption).EndsWith(Suffix),'Editing a mask reverts the preview to another selected book');
          finally Mask.Text:=SavedMask; end;
          Require(string(Preview.Hint).Contains(Destination),'Selected-book preview lost the destination path');
        end;
      end;
      if CancelOptions then Dialog.ModalResult:=mrCancel
      else TButton(Dialog.FindComponent('SendBooks')).Perform(BM_CLICK,0,0);
      Exit;
    end;
    if string(Dialog.Caption).StartsWith('Качество изображений') then
    begin
      Inc(QualityDialogs);
      if CancelQuality then begin Dialog.ModalResult:=mrCancel; Exit; end;
      for var Component in Dialog do
      begin
        if (Component is TRadioButton) and string(TRadioButton(Component).Caption).StartsWith('Без изображений') then
        begin Require(TRadioButton(Component).Enabled,'Text-only choice is disabled for a textual fixture');
          TRadioButton(Component).Perform(BM_CLICK,0,0); end;
        if Component is TCheckBox then TCheckBox(Component).Checked:=True;
      end;
      for var Component in Dialog do if (Component is TButton) and (TButton(Component).Caption='Сохранить книгу') then
      begin TButton(Component).Perform(BM_CLICK,0,0); Exit; end;
    end;
  end;
end;

procedure TestUnifiedSendLayout;
var Dialog: TBookSendOptionsForm; SavedDark: Boolean;
  procedure Inspect(Parent: TWinControl);
  var Bounds: TRect;
  begin
    for var I:=0 to Parent.ControlCount-1 do
    begin
      var Control:=Parent.Controls[I]; if not Control.Visible then Continue;
      Require((Control.Left>=0) and (Control.Top>=0) and
        (Control.Left+Control.Width<=Parent.ClientWidth) and
        ((Control.Top+Control.Height<=Parent.ClientHeight) or
          ((Parent is TScrollBox) and (Control.Top+Control.Height<=TScrollBox(Parent).VertScrollBar.Range))),
        'Unified save control exceeds its parent: '+Control.ClassName);
      if Control is TLabel then
      begin
        var LabelControl:=TLabel(Control); Dialog.Canvas.Font.Assign(LabelControl.Font);
        Bounds:=Rect(0,0,LabelControl.Width,0);
        DrawText(Dialog.Canvas.Handle,PChar(LabelControl.Caption),Length(LabelControl.Caption),Bounds,
          DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
        Require(Bounds.Height<=LabelControl.Height,'Unified save explanation is clipped: '+LabelControl.Caption);
      end;
      if Control is TComboBox then
      begin
        var Combo:=TComboBox(Control); Dialog.Canvas.Font.Assign(Combo.Font);
        for var Caption in Combo.Items do Require(Dialog.Canvas.TextWidth(Caption)+MulDiv(32,Dialog.PixelsPerInch,96)<=Combo.Width,
          'Unified save format/image option is clipped: '+Caption);
      end;
      if Control is TWinControl then Inspect(TWinControl(Control));
    end;
  end;
begin
  SavedDark:=MHLThemeDark;
  try
    for var Dark in [False,True] do for var PPI in [96,144,192] do
    begin
      SetMHLTheme(Dark); Dialog:=TBookSendOptionsForm.Create(Application);
      try
        Dialog.ScaleForPPI(PPI); Dialog.Show; Application.ProcessMessages;
        var Destination:=TEdit(Dialog.FindComponent('SendDestination'));
        var Mask:=TEdit(Dialog.FindComponent('SaveNameTemplate'));
        var Subfolders:=TCheckBox(Dialog.FindComponent('SaveSubfolders'));
        var FolderMask:=TEdit(Dialog.FindComponent('SaveFolderTemplate'));
        var MaskHelp:=TLabel(Dialog.FindComponent('NameMaskHelp'));
        var FolderHelp:=TLabel(Dialog.FindComponent('FolderMaskHelp'));
        var HelpToggle:=TButton(Dialog.FindComponent('ToggleSaveMaskHelp'));
        var Collision:=TComboBox(Dialog.FindComponent('SaveNameCollision'));
        Require(not Destination.ReadOnly,'Save destination still looks editable but rejects typed paths');
        Require(not MaskHelp.Visible and not FolderHelp.Visible,'Save As starts with expanded mask instructions');
        Subfolders.Checked:=True; Subfolders.OnClick(Subfolders);
        var PreservedFolderMask:=FolderMask.Text; var ExpandedTop:=Collision.Top;
        Require(FolderMask.Visible and FolderMask.Enabled,'Enabled subfolders have no editable mask');
        Subfolders.Checked:=False; Subfolders.OnClick(Subfolders);
        Require(not FolderMask.Visible and not FolderHelp.Visible and not FolderMask.Enabled and
          (Collision.Top<ExpandedTop),'Disabling subfolders leaves an empty disabled row');
        Require(FolderMask.Text=PreservedFolderMask,'Hiding subfolders discarded the saved mask');
        HelpToggle.Click; Require(MaskHelp.Visible and not FolderHelp.Visible,'Mask help cannot be opened independently');
        Inspect(Dialog); HelpToggle.Click;
        Require(not MaskHelp.Visible,'Mask help cannot be collapsed');
        Subfolders.Checked:=True; Subfolders.OnClick(Subfolders);
        Require(FolderMask.Visible and (FolderMask.Text=PreservedFolderMask),'Re-enabling subfolders loses its mask');
        var PreviewFormats:=TComboBox(Dialog.FindComponent('SendFormat'));
        var EpubIndex:=PreviewFormats.Items.IndexOf('Преобразовать в EPUB');
        Require(EpubIndex>=0,'Layout fixture has no EPUB preview choice');
        PreviewFormats.ItemIndex:=EpubIndex; PreviewFormats.OnChange(PreviewFormats);
        Destination.Text:=Settings.TempPath+'выбранная папка'; Mask.Text:='копия %t';
        var Preview:=TLabel(Dialog.FindComponent('SaveNamePreview'));
        Require(string(Preview.Caption).Contains('копия Название книги.epub') and
          string(Preview.Hint).Contains(Destination.Text),'Changing the filename mask/path does not update the actual EPUB name');
        for var IncompletePath in ['C:','\Books','bad<path','"quoted"'] do
        begin
          Destination.Text:=IncompletePath;
          Require(string(Preview.Caption).EndsWith('.epub') and
            string(Preview.Hint).Contains('полный путь'),'Typing an incomplete/invalid folder breaks the filename preview');
        end;
        Destination.Text:=Settings.TempPath+'выбранная папка';
        for var FormatIndex:=0 to TComboBox(Dialog.FindComponent('SendFormat')).Items.Count-1 do for var ImageIndex:=0 to 3 do
        begin
          var Formats:=TComboBox(Dialog.FindComponent('SendFormat')); Formats.ItemIndex:=FormatIndex; Formats.OnChange(Formats);
          var Images:=TComboBox(Dialog.FindComponent('SendImages')); Images.ItemIndex:=ImageIndex; Images.OnChange(Images);
          Inspect(Dialog);
        end;
        Dialog.ClientWidth:=Dialog.ClientWidth+MulDiv(80,PPI,96);
        Dialog.ClientHeight:=Dialog.ClientHeight+MulDiv(80,PPI,96); Inspect(Dialog);
        Writeln('PASS unified save layout dark=',Ord(Dark),' ppi=',PPI); Flush(Output);
      finally Dialog.Free; end;
    end;
  finally SetMHLTheme(SavedDark); end;
end;

procedure TestUnifiedTXT(const Root: string);
const Body='<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>Не включать описание</book-title></title-info></description>'+
  '<body><section><title><p>Глава</p></title><p>До <strong>жирного</strong> &amp; после.</p><p>Второй</p></section></body>'+
  '<body name="notes"><section id="n"><p>Сноска</p></section></body></FictionBook>';
var Stream: TBytesStream; Encoding: TEncoding; Bytes: TBytes; OutputFile, XML, OriginalHash: string;
  Failed: Boolean;
  function ByteHash(const Value: TBytes): string;
  var Hash: THashSHA2;
  begin Hash:=THashSHA2.Create; Hash.Update(Value); Result:=Hash.HashAsString; end;
begin
  for var CodePage in TArray<Integer>.Create(65001,1251) do
  begin
    Encoding:=TEncoding.GetEncoding(CodePage);
    try
      var Name:='utf-8'; if CodePage=1251 then Name:='windows-1251';
      Bytes:=Encoding.GetBytes('<?xml version="1.0" encoding="'+Name+'"?>'+Body);
    finally Encoding.Free; end;
    OriginalHash:=ByteHash(Bytes); Stream:=TBytesStream.Create(Bytes);
    try
      Stream.Position:=3; OutputFile:=Root+'minified-'+IntToStr(CodePage)+'.txt';
      ConvertToTxt(OutputFile,enUTF8,Stream);
      Require(TFile.ReadAllText(OutputFile,TEncoding.UTF8)='Глава'+sLineBreak+'До жирного & после.'+sLineBreak+'Второй'+sLineBreak+'Сноска'+sLineBreak,
        'TXT lost minified paragraphs, XML encoding, entities, inline text or notes');
      Require((Stream.Position=3) and (ByteHash(Stream.Bytes)=OriginalHash),'TXT changed its source stream');
      Failed:=False;
      try ConvertToTxt(OutputFile,enUTF8,Stream); except on E: EInOutError do Failed:=True; end;
      Require(Failed and TFile.ReadAllText(OutputFile,TEncoding.UTF8).Contains('жирного'),'TXT overwrote an existing result');
    finally Stream.Free; end;
  end;
  for var Kind in [0,1,2] do
  begin
    XML:='<FictionBook><body><section><p>Незакрыто';
    if Kind=1 then XML:='<!DOCTYPE FictionBook SYSTEM "http://127.0.0.1:9/never-load"><FictionBook><body><p>Текст</p></body></FictionBook>';
    if Kind=2 then XML:='<FictionBook><body><section><image/></section></body></FictionBook>';
    Stream:=TBytesStream.Create(TEncoding.UTF8.GetBytes(XML)); OutputFile:=Root+'reject-'+IntToStr(Kind)+'.txt';
    try
      Failed:=False; Stream.Position:=3;
      try ConvertToTxt(OutputFile,enUTF8,Stream); except on E: EReadError do Failed:=True; end;
      Require(Failed and not FileExists(OutputFile) and (Stream.Position=3),'Invalid/no-text TXT export published output or changed source position');
    finally Stream.Free; end;
  end;
  Writeln('PASS unified TXT minified UTF8 CP1251 inline paragraphs notes source position existing target malformed XML DTD and no-text cases'); Flush(Output);
end;

procedure TestUnifiedBookSending;
const Text='Обычная иллюстрированная книга. Ёж, Україна, 中文.';
  Note='[Изображение не включено в эту копию]';
var Root, SourceFB2, SourceEPUB, ImageFile, XML, SavedFolder, SavedFile, SavedDevice, SavedSync: string;
  Collection: IBookCollection; Book: TBookRecord; CID, PreviousCID: Integer;
  Books: array[0..1] of TBookRecord; Hashes: array[0..1] of string;
  Probe: TUnifiedSendProbe; Menu: TMenuItem; SavedSelected, SavedRewrite, SavedPrompt: Boolean;
  SavedMode: TExportMode; SavedScript, ScriptCount: Integer; SavedEncoding: TTXTEncoding; PNG: TPngImage; Bitmap: TBitmap; Warnings: TStringList;
  Node: PVirtualNode; Row: PBookRecord; COMInitialized: Boolean;

  procedure SelectBooks;
  begin
    frmMain.FillBooksTree(frmMain.tvBooksSR,nil,Collection.GetBookIterator(bmAll,False),False,False,nil);
    Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Row:=frmMain.tvBooksSR.GetNodeData(Node);
      if Assigned(Row) and (Row^.NodeType=ntBookInfo) then frmMain.tvBooksSR.CheckState[Node]:=csCheckedNormal;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
  end;

  procedure CheckMarks(Succeeded: Boolean);
  var Count: Integer;
  begin
    Count:=0; Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Row:=frmMain.tvBooksSR.GetNodeData(Node);
      if Assigned(Row) and (Row^.NodeType=ntBookInfo) then
      begin
        Inc(Count);
        if Succeeded then Require(frmMain.tvBooksSR.CheckState[Node]=csUncheckedNormal,'Successful send retained its mark')
        else Require(frmMain.tvBooksSR.CheckState[Node]=csCheckedNormal,'Canceled send removed a mark');
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(Count=2,'Unified send changed the selected row set');
  end;

  procedure Run(const Name: string; FormatIndex, ImageIndex: Integer; RemoveImages, ExactCopy: Boolean;
    CancelOptions: Boolean=False; CancelQuality: Boolean=False; MTP: Boolean=False);
  var Outputs: TArray<string>; Document: TReaderDocument; Target, ExpectedExt: string;
    Zip: TZipFile; Bytes: TBytes;
  begin
    SelectBooks; Probe.Destination:=Root+Name; ForceDirectories(Probe.Destination);
    Settings.DeviceDir:=Probe.Destination;
    Probe.FormatIndex:=FormatIndex; Probe.ImageIndex:=ImageIndex;
    Probe.Dialogs:=0; Probe.QualityDialogs:=0; Probe.Results:=nil; Probe.Worker:=nil;
    Probe.CancelOptions:=CancelOptions; Probe.CancelQuality:=CancelQuality; Probe.ShellSurrogate:=MTP;
    Probe.Failure:=''; Probe.Messages.Clear; Probe.Deadline:=GetTickCount64+180000; Probe.Timer.Enabled:=True;
    frmMain.pmiSendToDevice.Click;
    Probe.Timer.Enabled:=False; Probe.Worker:=nil;
    Require(Probe.Failure='',Probe.Failure);
    Require(Probe.Dialogs=1,'Public send did not open exactly one combined options dialog');
    Require(Settings.FolderTemplate='','Unified send changed the saved folder template');
    Outputs:=TDirectory.GetFiles(Probe.Destination,'*',TSearchOption.soAllDirectories);
    if CancelOptions or CancelQuality then
    begin
      Require(Length(Outputs)=0,'Canceled unified send published a book'); CheckMarks(False);
      if CancelOptions then Require(Length(Probe.Results)=0,'Canceled options started a worker');
    end
    else
    begin
      if (Length(Outputs)<>2) or (SuccessfulBookExportCount(Probe.Results)<>2) then
      begin
        Writeln('TRACE unified failure ',Name,' files=',Length(Outputs),' results=',Length(Probe.Results));
        for var FileName in Outputs do Writeln('TRACE artifact ',FileName);
        for var Item in Probe.Results do Writeln('TRACE result state=',Ord(Item.State),' output=',Item.OutputFile,' error=',Item.ErrorText);
        Flush(Output);
      end;
      Require((Length(Outputs)=2) and (SuccessfulBookExportCount(Probe.Results)=2),
        'Unified send failed: '+Probe.Messages.Text);
      Require(Probe.QualityDialogs=0,'The four explicit image modes opened an extra chooser');
      Require(Settings.SyncExportDir=Probe.Destination,'The accepted destination was not remembered');
      for var I:=0 to High(Probe.Results) do
      begin
        var Item:=Probe.Results[I]; Target:=Item.OutputFile;
        if MTP then Target:=TPath.Combine(Probe.Destination,ExtractFileName(Target));
        Require(FileExists(Target),'Successful unified send has no actual artifact');
        Collection.GetBookRecord(Item.Book.BookKey,Book,True);
        ExpectedExt:=Book.FileExt;
        case FormatIndex of 1: ExpectedExt:='.fb2'; 2: ExpectedExt:='.zip';
          3: ExpectedExt:='.epub'; 4: ExpectedExt:='.txt'; end;
        Require(SameText(ExtractFileExt(Target),ExpectedExt),'Unified send silently changed the requested format');
        if ExactCopy then Require(UpdateSHA256(Target)=UpdateSHA256(Book.GetBookFileName),'As-is sending changed the original bytes');
        if (FormatIndex=0) and (ImageIndex in [1,2]) then
          Require(TFile.GetSize(Target)<TFile.GetSize(Book.GetBookFileName),Format('Image compression did not reduce %s: %d >= %d',[Book.FileExt,TFile.GetSize(Target),TFile.GetSize(Book.GetBookFileName)]));
        if FormatIndex=2 then
        begin
          Zip:=TZipFile.Create;
          try
            Zip.Open(Target,zmRead); Require(Zip.FileCount=1,'FB2 ZIP contains extra temporary files');
            Require(SameText(ExtractFileExt(Zip.FileNames[0]),'.fb2'),'ZIP contains an incorrect format');
            Zip.Read(Zip.FileNames[0],Bytes);
          finally Zip.Free; end;
          Target:=Root+'verify-'+IntToStr(I)+'.fb2'; TFile.WriteAllBytes(Target,Bytes);
        end;
        Document:=TReaderDocument.Create;
        try
          Document.Load(Target); Require(Document.PlainText.Contains(Text),'Unified send lost the complete Unicode text');
          if RemoveImages then
          begin Require(Document.ImageCount=0,'Text-only send retained an image');
            if FormatIndex<>4 then Require(Document.PlainText.Contains(Note),'Omitted illustration has no unambiguous note'); end
          else Require(Document.ImageCount=1,'Ordinary illustrated send lost an image');
        finally Document.Free; end;
      end;
      CheckMarks(True);
    end;
    Require((UpdateSHA256(SourceFB2)=Hashes[0]) and (UpdateSHA256(SourceEPUB)=Hashes[1]),'Unified send changed its source');
    Require(Length(TDirectory.GetDirectories(Settings.TempPath,'homelib-export-*'))=0,'Unified send retained an owned intermediate folder');
    Writeln('PASS unified send ',Name,' files=',Length(Outputs),' choices=',Probe.QualityDialogs); Flush(Output);
  end;

  procedure SourceVariants;
  var SavedBook: TBookRecord; SavedXML, FileName: string;
    procedure Start(const Name: string; FormatIndex: Integer);
    begin
      SelectBooks; Probe.Destination:=Root+Name; ForceDirectories(Probe.Destination);
      Settings.DeviceDir:=Probe.Destination; Probe.FormatIndex:=FormatIndex;
      Probe.ImageIndex:=3;
      Probe.Dialogs:=0; Probe.QualityDialogs:=0; Probe.Results:=nil; Probe.Worker:=nil;
      Probe.CancelOptions:=False; Probe.CancelQuality:=False; Probe.ShellSurrogate:=False;
      Probe.Messages.Clear; Probe.Failure:=''; Probe.Deadline:=GetTickCount64+180000; Probe.Timer.Enabled:=True;
      try frmMain.pmiSendToDevice.Click; finally Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
      Require((Probe.Failure='') and (Probe.Dialogs=1) and (Length(Probe.Results)=2),'Variant did not traverse the actual unified command');
    end;
    procedure Partial(FailedID: Integer; const ErrorFragment: string);
    var Kept, Cleared: Integer;
    begin
      Require((SuccessfulBookExportCount(Probe.Results)=1) and (Length(TDirectory.GetFiles(Probe.Destination,'*'))=1),
        'Failed conversion acknowledged or published a missing/wrong-format book');
      for var Item in Probe.Results do if Item.Book.BookKey.BookID=FailedID then
        Require((Item.State=besFailed) and Item.ErrorText.Contains(ErrorFragment),'The failed format did not explain its restriction');
      Kept:=0; Cleared:=0; Node:=frmMain.tvBooksSR.GetFirst;
      while Assigned(Node) do
      begin
        Row:=frmMain.tvBooksSR.GetNodeData(Node);
        if Assigned(Row) and (Row^.NodeType=ntBookInfo) then
          if Row^.BookKey.BookID=FailedID then
          begin Require(frmMain.tvBooksSR.CheckState[Node]=csCheckedNormal,'A failed book lost its mark'); Inc(Kept); end
          else begin Require(frmMain.tvBooksSR.CheckState[Node]=csUncheckedNormal,'The completed book retained its mark'); Inc(Cleared); end;
        Node:=frmMain.tvBooksSR.GetNext(Node);
      end;
      Require((Kept=1) and (Cleared=1),'Partial export changed its selected row set');
    end;
  begin
    Collection.GetBookRecord(Books[1].BookKey,SavedBook,True); SavedXML:=TFile.ReadAllText(SourceFB2,TEncoding.UTF8);
    try
      Book:=SavedBook; Book.FileExt:='.txt'; Collection.UpdateBook(Book);
      FileName:=Root+'source.txt'; TFile.WriteAllText(FileName,Text,TEncoding.UTF8);
      var TextHash:=UpdateSHA256(FileName); Start('source-txt-noop',0);
      Require(SuccessfulBookExportCount(Probe.Results)=2,'Plain TXT was rejected for an inapplicable image preference');
      for var Item in Probe.Results do if Item.Book.BookKey.BookID=Books[1].BookKey.BookID then
        Require(SameText(ExtractFileExt(Item.OutputFile),'.txt') and (UpdateSHA256(Item.OutputFile)=TextHash),
          'Plain TXT was converted or had its encoding changed by the image preference');
      Book.FileExt:='.png'; Collection.UpdateBook(Book); FileName:=Root+'source.png'; TFile.Copy(ImageFile,FileName,False);
      var ImageHash:=UpdateSHA256(FileName); Start('original-png-noop',0);
      Require(SuccessfulBookExportCount(Probe.Results)=2,'Keeping PNG requested an image conversion');
      for var Item in Probe.Results do if Item.Book.BookKey.BookID=Books[1].BookKey.BookID then
        Require(SameText(ExtractFileExt(Item.OutputFile),'.png') and (UpdateSHA256(Item.OutputFile)=ImageHash),
          'Keeping PNG changed its bytes or extension');
      Require(UpdateSHA256(FileName)=ImageHash,'Unsupported original-format image processing changed its source');
      Collection.UpdateBook(SavedBook);
      TFile.WriteAllText(SourceFB2,SavedXML.Replace('<p>'+Text+'</p>',''),TEncoding.UTF8);
      var ScanHash:=UpdateSHA256(SourceFB2); Start('no-images-no-text-failure',0);
      Partial(Books[0].BookKey.BookID,'нет отдельного текста');
      Require(UpdateSHA256(SourceFB2)=ScanHash,'Failed removal of scanned pages changed the original FB2');
      Writeln('PASS unified send original TXT stays byte-exact, original PNG stays byte-exact, scan-only textless copy is rejected'); Flush(Output);
    finally
      Collection.UpdateBook(SavedBook); TFile.WriteAllText(SourceFB2,SavedXML,TEncoding.UTF8);
    end;
    Require((UpdateSHA256(SourceFB2)=Hashes[0]) and (UpdateSHA256(SourceEPUB)=Hashes[1]),'Variant fixture restoration changed original bytes');
  end;

begin
  RequireIsolatedRegression; TestUnifiedSendLayout; PreviousCID:=Settings.ActiveCollection;
  SavedDevice:=Settings.DeviceDir; SavedSync:=Settings.SyncExportDir; SavedFolder:=Settings.FolderTemplate; SavedFile:=Settings.FileNameTemplate;
  SavedSelected:=Settings.SelectedIsChecked; SavedRewrite:=Settings.OverwriteFB2Info;
  SavedPrompt:=Settings.PromptDevicePath; SavedMode:=Settings.ExportMode; SavedEncoding:=Settings.TXTEncoding; SavedScript:=Settings.DefaultScript; ScriptCount:=Settings.Scripts.Count;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'unified-send-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  TestUnifiedTXT(Root);
  SourceFB2:=Root+'source.fb2'; SourceEPUB:=Root+'source.epub'; ImageFile:=Root+'picture.png';
  Bitmap:=TBitmap.Create; PNG:=TPngImage.Create;
  try
    Bitmap.PixelFormat:=pf24bit; Bitmap.SetSize(640,640);
    var State: Cardinal:=$12345678;
    for var Y:=0 to Bitmap.Height-1 do
    begin
      var Pixels:=PByte(Bitmap.ScanLine[Y]);
      for var X:=0 to Bitmap.Width*3-1 do
      begin State:=State xor (State shl 13); State:=State xor (State shr 17); State:=State xor (State shl 5);
        Pixels[X]:=Byte(State); end;
    end;
    PNG.Assign(Bitmap); PNG.SaveToFile(ImageFile);
  finally PNG.Free; Bitmap.Free; end;
  XML:='<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">'+
    '<description><title-info><book-title>Unified send fixture</book-title><lang>ru</lang></title-info></description>'+
    '<body><section><p>'+Text+'</p><image l:href="#pic"/></section></body><binary id="pic" content-type="image/png">'+
    TNetEncoding.Base64.EncodeBytesToString(TFile.ReadAllBytes(ImageFile))+'</binary></FictionBook>';
  TFile.WriteAllText(SourceFB2,XML,TEncoding.UTF8); Warnings:=TStringList.Create;
  try ConvertBasicBook(Settings.AppPath,Settings.TempPath,SourceFB2,'.fb2',SourceEPUB,nil,Warnings,nil);
  finally Warnings.Free; end;
  Hashes[0]:=UpdateSHA256(SourceFB2); Hashes[1]:=UpdateSHA256(SourceEPUB);
  CID:=SystemDB.CreateCollection('Unified send own sources',Root,Root+'catalog.hlc2',CT_EXTERNAL_LOCAL_NONFB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID);
  for var I:=0 to High(Books) do
  begin
    Book.Clear; Book.Title:='Unified '+IntToStr(I); Book.FileName:='source'; Book.FileExt:='.fb2';
    if I=1 then Book.FileExt:='.epub'; Book.LibID:='unified-'+IntToStr(I); Book.Lang:='ru'; Book.Size:=100;
    Book.Date:=EncodeDate(2026,10,24); TAuthorsHelper.Add(Book.Authors,'Unified','Own','');
    TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
    Book.BookKey:=CreateBookKey(Collection.InsertBook(Book,False,False),CID); Books[I]:=Book;
  end;
  Probe:=TUnifiedSendProbe.Create; Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick; Probe.Messages:=TStringList.Create;
  Probe.SavedModal:=Application.OnModalBegin; Menu:=TMenuItem.Create(nil); COMInitialized:=False;
  try
    COMInitialized:=Succeeded(CoInitializeEx(nil,COINIT_APARTMENTTHREADED));
    Menu.Tag:=CID; frmMain.miActiveCollectionClick(Menu);
    frmMain.pgControl.ActivePage:=frmMain.tsSearch; frmMain.pgControlChange(nil);
    Settings.TreeModes[PAGE_SEARCH]:=tmFlat; Settings.SelectedIsChecked:=False;
    Settings.OverwriteFB2Info:=True; Settings.PromptDevicePath:=False; Settings.ExportMode:=emFB2;
    Settings.FolderTemplate:=''; Settings.FileNameTemplate:='%t'; Settings.TXTEncoding:=enUTF8;
    Application.OnModalBegin:=Probe.ModalBegin;
    Require(frmMain.pmiSendToDevice.Tag=0,'Public context send still resolves to an old conversion command');
    for var Parent in TArray<TMenuItem>.Create(frmMain.pmiScripts,frmMain.mmiScripts,frmMain.pmScripts.Items) do
      for var Item in Parent do Require((Item.Tag<850) or (Item.Tag>856),'Duplicate built-in conversion remains in a menu');
    Run('cancel-options',0,0,False,False,True);
    Run('source-as-is',0,0,False,True);
    Run('source-no-images',0,3,True,False);
    for var Quality in [1,2] do Run('source-compressed-'+IntToStr(Quality),0,Quality,False,False);
    Run('fb2-original-images',1,0,False,False);
    Run('epub-original-images',3,0,False,False);
    Run('fb2-compressed',1,1,False,False);
    Run('epub-compressed',3,2,False,False);
    Run('fb2-no-images',1,3,True,False);
    Run('epub-no-images',3,3,True,False);
    Run('zip-no-images',2,3,True,False);
    Run('shell-source-no-images',0,3,True,False,False,False,True);
    SourceVariants;
    Settings.Scripts.Add('Unified own copy script','%COPY%','%NFT%'); Settings.DefaultScript:=Settings.Scripts.Count;
    Run('personal-default-does-not-replace-format',-1,0,False,True);
    Writeln('PASS unified send public command preserves source formats, explicit conversions, image presets, mixed batches, cancellation, marks and Shell delivery');
  finally
    while Settings.Scripts.Count>ScriptCount do Settings.Scripts.Delete(Settings.Scripts.Count-1); Settings.DefaultScript:=SavedScript;
    Application.OnModalBegin:=Probe.SavedModal; Probe.Timer.Free; Probe.Messages.Free; Probe.Free;
    Menu.Tag:=PreviousCID; frmMain.miActiveCollectionClick(Menu); Menu.Free;
    Settings.DeviceDir:=SavedDevice; Settings.SyncExportDir:=SavedSync; Settings.FolderTemplate:=SavedFolder; Settings.FileNameTemplate:=SavedFile;
    Settings.SelectedIsChecked:=SavedSelected; Settings.OverwriteFB2Info:=SavedRewrite;
    Settings.PromptDevicePath:=SavedPrompt; Settings.ExportMode:=SavedMode; Settings.TXTEncoding:=SavedEncoding;
    if COMInitialized then CoUninitialize;
  end;
end;
