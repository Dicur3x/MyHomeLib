// Explicit interactive visual regression. Uses the isolated runner profile only.
procedure AuditExportPickerPreview;
var Reader: TfrmBuiltinReader; Store: TReaderAnnotations; Note: TReaderAnnotation;
  Profile,Hash: string;
begin
  SetCurrentDir(ExtractFilePath(ParamStr(0)));
  Application.MainFormOnTaskbar:=True;
  Application.CreateForm(TfrmBuiltinReader,Reader);
  TFile.WriteAllText('export-picker.txt','Текст книги для проверки экспорта.',TEncoding.UTF8);
  Profile:='export-picker.ini'; Store:=TReaderAnnotations.Create(Profile);
  try
    Note:=Default(TReaderAnnotation); Note.BookID:=Copy(THashSHA2.GetHashString('export-picker'),1,40);
    Note.BookTitle:='Проверка экспорта'; Note.Text:='Моя мысль ё 😀'; Note.Quote:='Текст книги';
    Note.Created:='2026-10-15T05:18:00Z'; Store.Put(Note);
  finally Store.Free; end;
  Hash:=THashSHA2.GetHashStringFromFile('reader-notes.json');
  for var Dark in [True,False] do
  begin
    SetMHLTheme(Dark);
    begin
      Reader.Show; Reader.OpenBook('export-picker.txt','Проверка экспорта','export-picker',Profile,'pdfium.dll'); WaitReady(Reader);
      var SavedHooks:=TStyleManager.SystemHooks;
      TThread.ForceQueue(nil,procedure
        begin
          var Manager: TForm; Manager:=nil;
          for var I:=0 to Screen.FormCount-1 do
            if Screen.Forms[I].Visible and Assigned(Screen.Forms[I].FindComponent('ExportBookNotes')) then Manager:=Screen.Forms[I];
          Require(Assigned(Manager),'Visible notes manager not found for native picker');
          TThread.ForceQueue(nil,procedure
            begin
              for var I:=0 to Screen.FormCount-1 do
                if Screen.Forms[I].Visible and (Screen.Forms[I].Caption='Экспорт заметок — оформление') then
                begin Screen.Forms[I].ModalResult:=mrOk; Exit; end;
              Require(False,'Visible export style dialog not found for native picker');
            end);
          Writeln('VISUAL native export picker dark=',Ord(Dark)); Flush(Output);
          TMenuItem(Manager.FindComponent('ExportBookNotes')).OnClick(Manager.FindComponent('ExportBookNotes'));
          Manager.ModalResult:=mrCancel;
        end);
      NoteDialogButton(Reader,'Заметки').OnClick(nil);
      Require(TStyleManager.SystemHooks=SavedHooks,'File picker failed to restore dialog style hooks');
      Require(THashSHA2.GetHashStringFromFile('reader-notes.json')=Hash,'Native export picker modified source notes');
      Writeln('PASS native export picker restores hooks and preserves notes dark=',Ord(Dark)); Flush(Output);
    end;
  end;
  TFile.WriteAllText(ExtractFilePath(ParamStr(0))+'export-picker-preview-result.txt','PASS dark and light native export pickers preserve notes and restore hooks',TEncoding.UTF8);
  Reader.Free;
end;
