// Select only this wrapper-owned uppercase-extension fixture through Computer Use.
procedure TestMainLegacyImportWorkflow(const One: IBookCollection; OneID: Integer);
var
  FileName, BeforeHash: string;
  BookID: Integer;
  Catalog, Personal: TBookRecord;
begin
  RequireIsolatedRegression;
  BookID := AddBook(One, '999001', 'Legacy import audit', 'ru', '', '0.1');
  One.AddBookToGroup(CreateBookKey(BookID, OneID), FAVORITES_GROUP_ID);
  FileName := Settings.AppPath + 'Перенос Ё.MHLUD';
  TFile.WriteAllText(FileName, '# Рейтинги' + sLineBreak + '999001 4' + sLineBreak, TEncoding.UTF8);
  BeforeHash := THashSHA2.GetHashStringFromFile(FileName);
  frmMain.Show; Application.ProcessMessages;
  Writeln('VISUAL main legacy import: select ', FileName); Flush(Output);
  frmMain.ImportUserDataExecute(nil);
  One.GetBookRecord(CreateBookKey(BookID, OneID), Catalog, True);
  SystemDB.GetBookRecord(CreateBookKey(BookID, OneID), Personal);
  Require((Catalog.Rate = 4) and (Personal.Rate = 4),
    'Actual Main uppercase legacy import did not preserve the rating in both cards');
  Require(THashSHA2.GetHashStringFromFile(FileName) = BeforeHash,
    'Actual Main legacy import changed its input file');
  Writeln('PASS Main uppercase MHLUD imports the actual file into catalog and personal cards with Unicode path'); Flush(Output);
  Writeln('VISUAL main legacy import: cancel the second file selection'); Flush(Output);
  frmMain.ImportUserDataExecute(nil);
  One.GetBookRecord(CreateBookKey(BookID, OneID), Catalog, True);
  SystemDB.GetBookRecord(CreateBookKey(BookID, OneID), Personal);
  Require((Catalog.Rate = 4) and (Personal.Rate = 4) and
    (THashSHA2.GetHashStringFromFile(FileName) = BeforeHash),
    'Canceling Main import changed its earlier imported values or source');
  Writeln('PASS Main legacy import cancel preserves earlier values and the source file');
end;
