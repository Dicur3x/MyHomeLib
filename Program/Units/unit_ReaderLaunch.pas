unit unit_ReaderLaunch;

interface

uses System.Classes, unit_Globals;

function FindArchiveManager: string;
procedure OpenInArchiveManager(const FileName: string);
procedure ShowBookLocation(Owner: TComponent; const Book: TBookRecord);
function ChooseBookReader(Owner: TComponent; const FileName, OriginalExtension: string;
  out Builtin: Boolean; out ReaderPath: string; ForceChoice: Boolean = False): Boolean;

implementation

uses System.SysUtils, System.IOUtils, System.IniFiles, System.Win.Registry,
  Winapi.Windows, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.Clipbrd,
  unit_ReaderFormats, unit_ReaderOffice, unit_Settings, unit_Readers, unit_Helpers, unit_ReaderCache, dm_user;

function FindArchiveManager: string;
const Roots: array[0..1] of HKEY = (HKEY_CURRENT_USER,HKEY_LOCAL_MACHINE);
  Views: array[0..1] of Cardinal = (KEY_READ or KEY_WOW64_64KEY, KEY_READ or KEY_WOW64_32KEY);
var Registry: TRegistry; Root: HKEY; Flags: Cardinal; Name, Candidate, Base, ProgID: string;
begin
  Result:='';
  for Root in Roots do
    for Flags in Views do
    begin
      Registry:=TRegistry.Create(Flags);
      try
        Registry.RootKey:=Root;
        for Name in ['WinRAR.exe','7zFM.exe','peazip.exe'] do
          if Registry.OpenKeyReadOnly('\Software\Microsoft\Windows\CurrentVersion\App Paths\'+Name) then
          begin
            Candidate:=Registry.ReadString('').Trim(['"']); Registry.CloseKey;
            if FileExists(Candidate) then Exit(Candidate);
          end;
      finally Registry.Free; end;
    end;
  for Base in [GetEnvironmentVariable('ProgramW6432'),GetEnvironmentVariable('ProgramFiles'),GetEnvironmentVariable('ProgramFiles(x86)')] do
    for Name in ['WinRAR\WinRAR.exe','7-Zip\7zFM.exe','PeaZip\peazip.exe'] do
    begin Candidate:=TPath.Combine(Base,Name); if FileExists(Candidate) then Exit(Candidate); end;
  Registry:=TRegistry.Create(KEY_READ);
  try
    Registry.RootKey:=HKEY_CLASSES_ROOT;
    if Registry.OpenKeyReadOnly('.zip') then
    begin ProgID:=Registry.ReadString(''); Registry.CloseKey; end;
    if (ProgID<>'') and Registry.OpenKeyReadOnly(ProgID+'\shell\open\command') then
    begin
      Candidate:=Trim(Registry.ReadString(''));
      if Candidate.StartsWith('"') then Candidate:=Copy(Candidate,2,Pos('"',Candidate,2)-2)
      else Candidate:=Copy(Candidate,1,Pos(' ',Candidate+' ')-1);
      Name:=ExtractFileName(Candidate);
      if (SameText(Name,'WinRAR.exe') or SameText(Name,'7zFM.exe') or SameText(Name,'peazip.exe')) and FileExists(Candidate) then Result:=Candidate;
    end;
  finally Registry.Free; end;
end;

procedure OpenInArchiveManager(const FileName: string);
var Manager: string; Code: HINST;
begin
  if not FileExists(FileName) then raise EFileNotFoundException.Create('Архив не найден: '+FileName);
  Manager:=FindArchiveManager;
  if Manager='' then raise Exception.Create('Не найден установленный архиватор. Для просмотра содержимого установите WinRAR, 7-Zip или PeaZip.');
  Code:=SimpleShellExecute(Application.Handle,Manager,FileName);
  if Code<=32 then raise Exception.Create('Не удалось открыть архиватор: '+Manager+#13#10+SysErrorMessage(Code));
end;

type
  TBookLocationForm=class(TForm)
  private
    FContainer,FMember: string;
    procedure CopyName(Sender: TObject);
    procedure OpenContainer(Sender: TObject);
    procedure ShowFolder(Sender: TObject);
  end;

procedure TBookLocationForm.CopyName(Sender: TObject);
begin Clipboard.AsText:=FMember; end;
procedure TBookLocationForm.OpenContainer(Sender: TObject);
begin OpenInArchiveManager(FContainer); end;
procedure TBookLocationForm.ShowFolder(Sender: TObject);
var Folder: string;
begin
  Folder:=ExtractFilePath(FContainer);
  if FileExists(FContainer) then SimpleShellExecute(Handle,'explorer.exe','/select,"'+FContainer+'"')
  else if DirectoryExists(Folder) then SimpleShellExecute(Handle,Folder)
  else raise EFileNotFoundException.Create('Папка не найдена: '+Folder);
end;

procedure ShowBookLocation(Owner: TComponent; const Book: TBookRecord);
var Dialog: TBookLocationForm; LabelText: TLabel; Edit: TEdit; B: TButton;
  procedure Field(const Caption, Value: string; Y: Integer);
  begin
    LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.SetBounds(12,Y,650,20); LabelText.Caption:=Caption;
    Edit:=TEdit.Create(Dialog); Edit.Parent:=Dialog; Edit.SetBounds(12,Y+22,650,26); Edit.ReadOnly:=True; Edit.Text:=Value;
  end;
begin
  Dialog:=TBookLocationForm.CreateNew(Owner);
  try
    Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=9; Dialog.Caption:='Где хранится книга';
    Dialog.Position:=poOwnerFormCenter; Dialog.BorderStyle:=bsDialog; Dialog.ClientWidth:=674; Dialog.ClientHeight:=250;
    Dialog.FContainer:=Book.GetBookFileName; Dialog.FMember:=Book.FileName+Book.FileExt;
    Field('Файл или архив коллекции:',Dialog.FContainer,12);
    if Book.GetBookFormat in [bfFb2Archive,bfRawArchive,bfFbd] then
      Field('Точное имя книги внутри архива (можно скопировать для поиска):',Dialog.FMember,76)
    else Field('Имя файла:',ExtractFileName(Dialog.FContainer),76);
    LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.AutoSize:=False;
    LabelText.SetBounds(12,140,650,32); LabelText.WordWrap:=True;
    if FileExists(Dialog.FContainer) then LabelText.Caption:='В архиваторе найдите файл по этому имени. Книги часто названы номером, а не названием.'
    else LabelText.Caption:='Файл коллекции отсутствует. Проверьте папку книг; это не означает, что сама книга повреждена.';
    B:=TButton.Create(Dialog); B.Parent:=Dialog; B.SetBounds(12,182,160,28); B.Caption:='Скопировать имя'; B.OnClick:=Dialog.CopyName;
    B:=TButton.Create(Dialog); B.Parent:=Dialog; B.SetBounds(180,182,220,28); B.Caption:='Открыть архив коллекции'; B.OnClick:=Dialog.OpenContainer;
    B.Enabled:=FileExists(Dialog.FContainer) and IsReaderArchive(Dialog.FContainer);
    B:=TButton.Create(Dialog); B.Parent:=Dialog; B.SetBounds(408,182,150,28); B.Caption:='Показать в папке'; B.OnClick:=Dialog.ShowFolder;
    B:=TButton.Create(Dialog); B.Parent:=Dialog; B.SetBounds(566,182,96,28); B.Caption:='Закрыть'; B.ModalResult:=mrClose; B.Cancel:=True;
    Dialog.ScaleForPPI(Screen.PixelsPerInch); Dialog.ShowModal;
  finally Dialog.Free; end;
end;

function ChooseBookReader(Owner: TComponent; const FileName, OriginalExtension: string;
  out Builtin: Boolean; out ReaderPath: string; ForceChoice: Boolean): Boolean;
var Dialog: TForm; List: TListBox; Remember: TCheckBox; LabelText: TLabel; B: TButton;
  Ini: TMemIniFile; Paths: TStringList; Choice, Ext, Path, PreferenceKey: string;
  Reader: TReaderDesc; CanBuiltin, ValidKey, HasLetter: Boolean; I: Integer; Ch: Char;
  procedure Add(const Caption, Value: string);
  begin if Paths.IndexOf(Value)>=0 then Exit; List.Items.Add(Caption); Paths.Add(Value); end;
begin
  Result:=False; Builtin:=False; ReaderPath:='';
  Ext:=LowerCase(ExtractFileExt(FileName)); CanBuiltin:=IsBuiltinReaderFormat(Ext);
  if IsOfficeReaderFormat(Ext) then CanBuiltin:=FindReaderOffice<>'';
  PreferenceKey:=LowerCase(OriginalExtension);
  ValidKey:=(Length(PreferenceKey)>=2) and (Length(PreferenceKey)<=11) and PreferenceKey.StartsWith('.');
  HasLetter:=False;
  for Ch in Copy(PreferenceKey,2,MaxInt) do
  begin
    if CharInSet(Ch,['a'..'z']) then HasLetter:=True
    else if not CharInSet(Ch,['0'..'9']) then ValidKey:=False;
  end;
  if not ValidKey or not HasLetter then PreferenceKey:=Ext;
  if (Ext='.exe') or (Ext='.com') or (Ext='.msi') or (Ext='.bat') or (Ext='.cmd') or (Ext='.ps1') or (Ext='.apk') then
    raise Exception.Create('Этот файл не является книгой: '+Ext);
  // Automatic reading is governed by the global setting. Manual menu choices
  // remain available and remembered without replacing configured external paths.
  if not ForceChoice then
  begin Builtin:=CanBuiltin and Settings.UseBuiltinReaderByDefault; Exit(True); end;
  Ini:=TMemIniFile.Create(Settings.DataDir+'reader.ini',TEncoding.UTF8);
  Dialog:=nil; Paths:=TStringList.Create;
  try
    Choice:=Ini.ReadString('OpenWith',PreferenceKey,'');
    Dialog:=TForm.CreateNew(Owner); Dialog.Caption:='Где открыть книгу?'; Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=9;
    Dialog.Position:=poOwnerFormCenter; Dialog.BorderStyle:=bsDialog; Dialog.ClientWidth:=440; Dialog.ClientHeight:=296;
    LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog; LabelText.AutoSize:=False;
    LabelText.SetBounds(12,10,416,42); LabelText.WordWrap:=True; LabelText.Caption:=Ext.TrimLeft(['.'])+' · '+ReaderAvailability(Ext);
    List:=TListBox.Create(Dialog); List.Parent:=Dialog; List.SetBounds(12,58,416,132);
    if CanBuiltin then Add('Встроенная читалка (экспериментально)','@builtin');
    Reader:=Settings.Readers.Find(Ext);
    if Assigned(Reader) and (Reader.Path<>'') then
    begin
      Path:=Reader.Path; if not TPath.IsPathRooted(Path) then Path:=TPath.Combine(Settings.AppPath,Path);
      if FileExists(Path) then Add(ExtractFileName(Path)+' — настроено для этого типа',Path);
    end;
    if Pos('|'+Ext+'|','|.fb2|.doc|.docx|.rtf|.txt|.htm|.html|')>0 then
    begin Path:=Settings.AppPath+'Readers\AlReader\AlReader2.exe'; if FileExists(Path) then Add('AlReader',Path); end;
    if Pos('|'+Ext+'|','|.pdf|.epub|.mobi|.azw|.azw3|.prc|.djvu|.djv|.xps|.oxps|.chm|.cbr|.cbz|.cb7|.jpg|.jpeg|.png|.gif|.tif|.tiff|.webp|')>0 then
    begin Path:=Settings.AppPath+'Readers\SumatraPDF\SumatraPDF.exe'; if FileExists(Path) then Add('SumatraPDF',Path); end;
    Add('Программа по умолчанию для этого типа','@configured');
    List.ItemIndex:=0;
    for I:=0 to Paths.Count-1 do if Paths[I]=Choice then List.ItemIndex:=I;
    Remember:=TCheckBox.Create(Dialog); Remember.Parent:=Dialog; Remember.SetBounds(12,202,416,24);
    Remember.Caption:='Запомнить выбор в этом меню для '+PreferenceKey; Remember.Checked:=Choice<>'';
    B:=TButton.Create(Dialog); B.Parent:=Dialog; B.SetBounds(212,246,104,28); B.Caption:='Открыть'; B.Default:=True; B.ModalResult:=mrOk;
    B:=TButton.Create(Dialog); B.Parent:=Dialog; B.SetBounds(324,246,104,28); B.Caption:='Отмена'; B.Cancel:=True; B.ModalResult:=mrCancel;
    Dialog.ScaleForPPI(Screen.PixelsPerInch);
    if (Dialog.ShowModal<>mrOk) or (List.ItemIndex<0) then Exit;
    Choice:=Paths[List.ItemIndex]; Builtin:=Choice='@builtin';
    if (Choice<>'@builtin') and (Choice<>'@configured') then ReaderPath:=Choice;
    if Remember.Checked then Ini.WriteString('OpenWith',PreferenceKey,Choice)
    else Ini.DeleteKey('OpenWith',PreferenceKey);
    Ini.UpdateFile; Result:=True;
  finally Dialog.Free; Paths.Free; Ini.Free; end;
end;

end.
