program ExportToDeviceTest;

{$APPTYPE CONSOLE}
{$R *.res}
{$R '..\..\..\Program\HomeLibre.res'}
{$R '..\..\..\Program\HomeLibre.dres'}
{$R '..\..\..\Program\lang.res'}

uses
  System.SysUtils, System.IOUtils, System.Hash, System.Zip,
  Vcl.Forms, Xml.XMLDoc, Xml.XMLIntf,
  dm_user, unit_Consts, unit_Globals, unit_Interfaces, unit_Localization,
  unit_Settings, unit_BookExportResults, unit_ExportToDeviceThread,
  NativeRegressionGuard;

procedure Require(Value: Boolean; const Message: string);
begin
  if not Value then raise Exception.Create(Message);
end;

procedure TestFB2ExportMetadata;
const Body = 'Отдельный абзац проверки, который должен встретиться ровно один раз.';
var Root, SourceFB2, SourceZip, Folder, SavedTitle, SavedFile, SavedFolder: string;
  SourceHash, ArchiveHash: string;
  SavedOverwrite: Boolean;
  CID: Integer;
  Collection: IBookCollection;
  Book: TBookRecord;
  Keys: TBookIdList;
  Worker: TExportToDeviceThread;
  Zip: TZipFile;
  Files: TArray<string>;
  Data: TBytes;
  Document: IXMLDocument;
begin
  RequireIsolatedRegression;
  Root := TPath.Combine(Settings.AppPath, 'fb2-export-metadata');
  ForceDirectories(Root);
  SourceFB2 := TPath.Combine(Root, 'original.fb2');
  SourceZip := TPath.Combine(Root, 'original.zip');
  TFile.WriteAllText(SourceFB2, '<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' +
    '<description><title-info><genre>sf</genre><author><nickname>Автор</nickname></author>' +
    '<book-title>' + StringOfChar('Я', 400) + '</book-title><lang>ru</lang></title-info></description>' +
    '<body><section><p>' + Body + '</p></section></body></FictionBook>', TEncoding.UTF8);
  Zip := TZipFile.Create;
  try
    Zip.Open(SourceZip, zmWrite);
    Zip.Add(SourceFB2, 'original.fb2');
  finally Zip.Free; end;
  SourceHash := THashSHA2.GetHashStringFromFile(SourceFB2);
  ArchiveHash := THashSHA2.GetHashStringFromFile(SourceZip);
  CID := SystemDB.CreateCollection('FB2 export metadata', IncludeTrailingPathDelimiter(Root),
    TPath.Combine(Root, 'catalog.hlc2'), CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID);
  SavedOverwrite := Settings.OverwriteFB2Info;
  SavedTitle := Settings.BookHeaderTemplate;
  SavedFile := Settings.FileNameTemplate;
  SavedFolder := Settings.FolderTemplate;
  try
    Settings.OverwriteFB2Info := True;
    Settings.BookHeaderTemplate := '%t';
    Settings.FileNameTemplate := '%t';
    Settings.FolderTemplate := '';
    for var Archived in [False, True] do
    begin
      Book.Clear;
      Book.Title := 'Название из каталога ' + IntToStr(Ord(Archived));
      Book.FileName := 'original';
      Book.FileExt := '.fb2';
      if Archived then Book.Folder := 'original.zip';
      Book.LibID := IntToStr(1 + Ord(Archived));
      Book.Lang := 'ru';
      Book.Date := EncodeDate(2026, 11, 21);
      TAuthorsHelper.Add(Book.Authors, 'Проверка', 'Автор', '');
      TGenresHelper.Add(Book.Genres, '', '', 'sf');
      Include(Book.BookProps, bpIsLocal);
      SetLength(Keys, 1);
      Keys[0].BookKey := CreateBookKey(Collection.InsertBook(Book, False, False), CID);
      Require(Keys[0].BookKey.BookID > 0, 'Could not register FB2 metadata fixture');
      for var Mode in [emFB2, emFB2Zip] do
      begin
        Folder := TPath.Combine(Root, Format('result-%d-%d', [Ord(Archived), Ord(Mode)]));
        ForceDirectories(Folder);
        Worker := TExportToDeviceThread.Create;
        try
          Worker.BookIdList := Keys;
          Worker.DeviceDir := Folder;
          Worker.ExportMode := Mode;
          Worker.Start;
          Worker.WaitFor;
          Require(SuccessfulBookExportCount(Worker.Results) = 1, 'FB2 metadata export failed');
        finally Worker.Free; end;
        Files := TDirectory.GetFiles(Folder);
        Require(Length(Files) = 1, 'Unexpected number of results after FB2 metadata export');
        if Mode = emFB2Zip then
        begin
          Zip := TZipFile.Create;
          try
            Zip.Open(Files[0], zmRead);
            Require(Zip.FileCount = 1, 'Unexpected number of books in FB2.ZIP');
            Zip.Read(0, Data);
          finally Zip.Free; end;
        end
        else Data := TFile.ReadAllBytes(Files[0]);
        var Content := TEncoding.UTF8.GetString(Data);
        Document := TXMLDocument.Create(nil);
        Document.LoadFromXML(Content.TrimLeft([#$FEFF]));
        Require(Document.DocumentElement.ChildNodes['description'].ChildNodes['title-info'].
          ChildNodes['book-title'].Text = Book.Title, 'The exported FB2 did not get the catalogue title');
        Require(Document.DocumentElement.ChildNodes['body'].ChildNodes['section'].ChildNodes['p'].Text = Body,
          'The exported FB2 lost or duplicated its body paragraph');
        Document := nil;
      end;
    end;
    Require((THashSHA2.GetHashStringFromFile(SourceFB2) = SourceHash) and (THashSHA2.GetHashStringFromFile(SourceZip) = ArchiveHash),
      'FB2 metadata export changed an original file');
    Writeln('PASS loose and archived FB2 export rewrites metadata without duplicating XML or modifying the source');
  finally
    Settings.OverwriteFB2Info := SavedOverwrite;
    Settings.BookHeaderTemplate := SavedTitle;
    Settings.FileNameTemplate := SavedFile;
    Settings.FolderTemplate := SavedFolder;
  end;
end;

begin
  try
    RequireIsolatedRegression;
    Application.Initialize;
    InitLocalization;
    Application.CreateForm(TDMUser, DMUser);
    try
      DMUser.Init;
      TestFB2ExportMetadata;
    finally FreeAndNil(DMUser); end;
  except
    on E: Exception do
    begin
      Writeln('FAIL ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
