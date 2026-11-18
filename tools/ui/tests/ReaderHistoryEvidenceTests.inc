procedure TestReaderHistoryEvidence;
var Before,After,AbsoluteBook:TBookRecord; RelativeName,AbsoluteName,Profile,NotesFile:string;
  Evidence:TReaderHistoryEvidence; DB:TSQLiteDatabase; Writer:TReaderHistoryAliasWriter;
  Ini:TMemIniFile; Refused:Boolean;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'History evidence fixture requires G:');
  Before:=Default(TBookRecord); Before.BookKey:=CreateBookKey(1,42);
  Before.LibID:=''; Before.CollectionRoot:=Settings.AppPath+'history-evidence-source\';
  Before.Folder:='books.zip'; Before.FileName:='empty'; Before.FileExt:='.fb2';
  AbsoluteBook:=Before; AbsoluteBook.Folder:=TPath.Combine(Before.CollectionRoot,Before.Folder);
  After:=Before; After.Folder:=Settings.AppPath+'history-evidence-destination\books.zip';
  RelativeName:=ReaderBaseHistoryName(Before,''); AbsoluteName:=ReaderBaseHistoryName(AbsoluteBook,'');
  Require(RelativeName<>AbsoluteName,'Fixture did not preserve both legacy name forms');
  Profile:=ResolveReaderSettingsFile(Settings.DataDir); NotesFile:=TPath.Combine(ExtractFileDir(Profile),'reader-notes.json');
  Require(not FileExists(Profile) and not FileExists(NotesFile),'History evidence requires a fresh private profile');
  Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
  try
    Ini.WriteString('Book.'+ReaderNoteIdentity(RelativeName),'Title','Metadata only');
    Ini.WriteInteger('Book.'+ReaderNoteIdentity(RelativeName),'CatalogBookID',1);
    Ini.WriteInteger('Book.'+ReaderNoteIdentity(AbsoluteName),'Position',33);
    Ini.UpdateFile;
  finally Ini.Free; end;
  var ProfileSHA:=THashSHA2.GetHashStringFromFile(Profile);
  Evidence:=TReaderHistoryEvidence.Create;
  try
    Require(Evidence.Contains(AbsoluteName) and not Evidence.Contains(RelativeName),
      'Registry-only metadata was treated as another saved reader position');
    Refused:=False;
    try
      var Stream:=TFileStream.Create(Profile,fmOpenWrite or fmShareDenyNone);
      Stream.Free;
    except on E:EFOpenError do Refused:=True; end;
    Require(Refused,'Reader evidence did not retain its profile against writes');
    TFile.WriteAllText(NotesFile,'new profile data',TEncoding.UTF8); Refused:=False;
    try Evidence.Contains(AbsoluteName); except on E:EReadError do Refused:=True; end;
    Require(Refused,'A newly created notes file was ignored by an active evidence snapshot');
  finally Evidence.Free; end;
  TFile.Delete(NotesFile);
  Require(THashSHA2.GetHashStringFromFile(Profile)=ProfileSHA,'Evidence reader rewrote the profile');
  Writeln('PASS history evidence ignores registry-only metadata holds existing files and detects newly created state without rewriting it');

  DB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]); Writer:=nil;
  try
    DB.Start;
    try
      Writer:=TReaderHistoryAliasWriter.Create(DB,TGUID.NewGuid.ToString,StringOfChar('a',64));
      Writer.RecordMove(Before,After,False); Writer.RecordMove(AbsoluteBook,After,False);
      var Q:=DB.NewQuery('SELECT OriginalName FROM HomeLibreReaderHistoryAliases WHERE CollectionID=42 AND BookID=1');
      try Q.Open; Require(not Q.Eof and (Q.FieldAsString(0)=AbsoluteName),'The actually saved legacy history was not selected');
        Q.Next; Require(Q.Eof,'Equivalent source representations produced duplicate destination histories');
      finally Q.Free; end;
    finally FreeAndNil(Writer); DB.Rollback; end;
    Require(THashSHA2.GetHashStringFromFile(Profile)=ProfileSHA,'Alias selection rewrote reader state');
    Writeln('PASS history alias selects the single saved absolute-path history for both physical representations');

    Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
    try Ini.WriteInteger('Book.'+ReaderNoteIdentity(RelativeName),'Position',11); Ini.UpdateFile;
    finally Ini.Free; end;
    ProfileSHA:=THashSHA2.GetHashStringFromFile(Profile); Refused:=False;
    Evidence:=TReaderHistoryEvidence.Create;
    try
      Require(Evidence.Contains(RelativeName) and Evidence.Contains(AbsoluteName),
        'Both actual saved positions must be visible before testing refusal');
    finally Evidence.Free; end;
    DB.Start;
    try
      Writer:=TReaderHistoryAliasWriter.Create(DB,TGUID.NewGuid.ToString,StringOfChar('b',64));
      try Writer.RecordMove(Before,After,False);
      except on E:EReadError do
        begin
          Writeln('TRACE ambiguous history refusal: '+E.Message);
          Refused:=E.Message.Contains('две истории');
        end;
      end;
      Require(Refused,'Two saved histories were silently merged');
      Require(DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''HomeLibreReaderHistoryAliases''')=0,
        'Refusing ambiguous histories published an alias table');
    finally FreeAndNil(Writer); DB.Rollback; end;
    Require(THashSHA2.GetHashStringFromFile(Profile)=ProfileSHA,'Refusal changed one of the two saved histories');
    Writeln('PASS two actual legacy reading histories refuse alias publication and preserve both saved positions');
  finally Writer.Free; DB.Free; end;
end;
