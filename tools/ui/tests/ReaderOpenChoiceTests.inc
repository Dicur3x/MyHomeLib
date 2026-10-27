type
  TReaderOpenChoiceDriver = class
    Timer: TTimer;
    Reader: TfrmBuiltinReader;
    ExpectedTheme: Integer;
    Accept, Seen: Boolean;
    Error: string;
    procedure Respond(Sender: TObject);
  end;

procedure TReaderOpenChoiceDriver.Respond(Sender: TObject);
var Dialog: TCustomForm; List: TListBox; Remember: TCheckBox;
begin
  Dialog:=nil;
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Caption='Где открыть книгу?' then
      begin Dialog:=Screen.Forms[I]; Break; end;
  if not Assigned(Dialog) then Exit;
  Timer.Enabled:=False; Seen:=True; List:=nil; Remember:=nil;
  Writeln('TRACE reader choice timer found modal'); Flush(Output);
  try
    Require((Reader.ThemeIndex=ExpectedTheme) and
      (Reader.Color=ReaderThemeBackground(ExpectedTheme)),
      'Open-book choice changed the independent reading theme');
    Require(Dialog.Color=MHLThemeBackground,
      'Open-book choice inherited reader or system colours instead of catalogue colours');
    Require(Dialog.Font.Color=MHLThemeText,'Open-book choice text has the wrong palette');
    for var I:=0 to Dialog.ControlCount-1 do
    begin
      if Dialog.Controls[I] is TListBox then List:=TListBox(Dialog.Controls[I]);
      if Dialog.Controls[I] is TCheckBox then Remember:=TCheckBox(Dialog.Controls[I]);
    end;
    Require(Assigned(List) and Assigned(Remember),'Open-book choice controls are missing');
    Require((List.Items.Count>0) and (List.Items[0]='HomeLib Reader'),
      'Open-book choice lost the available reader');
    Require(List.Font.Color=MHLThemeText,'Open-book choice list text is unreadable');
    if MHLThemeDark then Require(List.Color=RGB(30,31,34),'Dark catalogue choice list is white')
    else Require(List.Color=clWindow,'Light catalogue choice list retained dark reader colours');
    List.ItemIndex:=0; Remember.Checked:=Accept;
    if Accept then Dialog.ModalResult:=mrOk else Dialog.ModalResult:=mrCancel;
  except
    on E: Exception do begin Error:=E.Message; Dialog.ModalResult:=mrCancel; end;
  end;
end;

procedure TestReaderOpenChoice;
var Driver: TReaderOpenChoiceDriver; Reader: TfrmBuiltinReader; Host: TfrmReaderHost;
  SavedDark, Builtin, Accepted: Boolean; Path, Choice: string; Ini: TMemIniFile;
begin
  RequireIsolatedRegression; SavedDark:=MHLThemeDark;
  Driver:=TReaderOpenChoiceDriver.Create; Reader:=nil; Host:=nil;
  try
    Reader:=TfrmBuiltinReader.Create(nil); Driver.Reader:=Reader;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Respond;
    for var Dark in [False,True] do
    begin
      if Dark then Driver.ExpectedTheme:=1 else Driver.ExpectedTheme:=4;
      Reader.SetTheme(Driver.ExpectedTheme); SetMHLTheme(Dark);
      Require(Reader.ThemeIndex=Driver.ExpectedTheme,'Catalogue theme changed reading theme');
      Host:=TfrmReaderHost.Create(nil);
      try
        Require(Host.Color=MHLThemeBackground,'Open-book launcher does not use catalogue palette');
        for var Confirm in [False,True] do
        begin
          Driver.Accept:=Confirm; Driver.Seen:=False; Driver.Error:=''; Driver.Timer.Enabled:=True;
          Writeln('TRACE reader choice show catalogue_dark=',Ord(Dark),' accept=',Ord(Confirm)); Flush(Output);
          Accepted:=ChooseBookReader(nil,'test.fb2','.fb2',Builtin,Path,True);
          Driver.Timer.Enabled:=False;
          Require(Driver.Error='',Driver.Error);
          Require(Driver.Seen and (Accepted=Confirm),'Reader choice ignored accept or cancel');
          if Confirm then Require(Builtin and (Path=''),'Reader choice did not choose HomeLib Reader');
          Ini:=TMemIniFile.Create(Settings.DataDir+'reader.ini',TEncoding.UTF8);
          try Choice:=Ini.ReadString('OpenWith','.fb2',''); finally Ini.Free; end;
          if Confirm then Require(Choice='@builtin','Reader choice was not remembered')
          else if not Dark then Require(Choice='','Cancel changed the remembered reader');
          Require((MHLThemeDark=Dark) and (Reader.ThemeIndex=Driver.ExpectedTheme),
            'Choosing a reader changed catalogue or reading theme');
        end;
      finally FreeAndNil(Host); end;
    end;
    Writeln('PASS catalogue open-book choice keeps catalogue colours while reading theme stays independent; accept cancel and remembered choice work');
  finally
    Driver.Timer.Free; Driver.Free; Host.Free; Reader.Free; SetMHLTheme(SavedDark);
  end;
end;
