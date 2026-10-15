// Real bridge regression; requires Require, unit_BookConversion,
// unit_ReaderDocument, System.IOUtils, System.Hash and System.NetEncoding.
procedure TestReaderConversionAudit(const Root, AppPath: string);
const
  Picture = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg==';
  Marker = 'Точный текст ё ї є ґ ў';
var
  SourceRoot, TempRoot, OutputRoot, SourceName, PictureName, OutputName,
    SourceHash, PictureHash, Content, ArchiveName: string;
  Source: TMemoryStream;
  Document: TReaderDocument;
  Warnings: TStringList;
  Failed: Boolean;
  Count: Integer;

  procedure RequireFailure(const SourceFile, Extension, Name: string);
  begin
    OutputName := TPath.Combine(OutputRoot, Name + '.epub'); Failed := False;
    Source.Clear; Source.LoadFromFile(SourceName); Source.Position := 3;
    try
      ConvertBasicBook(AppPath, TempRoot, SourceFile, Extension, OutputName,
        Source, Warnings);
    except
      on E: Exception do Failed := True;
    end;
    Require(Failed and not FileExists(OutputName),
      'Conversion allowed missing/external/outside-root resources: ' + Name);
    Require(Source.Position = 3, 'Failed conversion changed caller stream position');
  end;

begin
  Require(SameText(ExtractFileDrive(TPath.GetFullPath(Root)), 'G:') or
    SameText(ExtractFileDrive(TPath.GetFullPath(Root)), 'C:'),
    'Reader conversion audit requires its own fixture on C or G');
  Require(TPath.GetFullPath(Root).StartsWith(
    IncludeTrailingPathDelimiter(TPath.GetFullPath(AppPath)), True),
    'Reader conversion audit must stay within its isolated application root');
  SourceRoot := TPath.Combine(Root, 'Исходники Ё');
  TempRoot := TPath.Combine(Root, 'work');
  OutputRoot := TPath.Combine(Root, 'results');
  ForceDirectories(SourceRoot); ForceDirectories(TempRoot); ForceDirectories(OutputRoot);
  PictureName := TPath.Combine(SourceRoot, 'картинка Ё.png');
  TFile.WriteAllBytes(PictureName, TNetEncoding.Base64.DecodeStringToBytes(Picture));
  PictureHash := THashSHA2.GetHashStringFromFile(PictureName);
  Source := TMemoryStream.Create; Warnings := TStringList.Create; Count := 0;
  try
    for var Extension in TArray<string>.Create('.html', '.htm', '.xhtml', '.shtml', '.md', '.markdown') do
    begin
      if (Extension = '.md') or (Extension = '.markdown') then
        Content := '# Глава' + sLineBreak + sLineBreak + Marker + sLineBreak +
          sLineBreak + '![Иллюстрация](<картинка Ё.png>)'
      else
        Content := '<html><head><title>Локальная книга</title></head><body><h1>Глава</h1><p>' +
          Marker + '</p><p><img src="картинка%20Ё.png"/></p></body></html>';
      SourceName := TPath.Combine(SourceRoot, 'книга #1' + Extension);
      TFile.WriteAllText(SourceName, Content, TEncoding.UTF8);
      SourceHash := THashSHA2.GetHashStringFromFile(SourceName);
      for var AsStream in TArray<Boolean>.Create(False, True) do
        for var TargetExtension in TArray<string>.Create('.epub', '.fb2') do
        begin
          OutputName := TPath.Combine(OutputRoot,
            Copy(Extension, 2, MaxInt) + '-' + BoolToStr(AsStream, True) + TargetExtension);
          if AsStream then
          begin
            Source.Clear; Source.LoadFromFile(SourceName); Source.Position := 3;
            ConvertBasicBook(AppPath, TempRoot, SourceName, Extension,
              OutputName, Source, Warnings);
            Require(Source.Position = 3, 'Conversion changed caller stream position');
          end
          else
            ConvertBasicBook(AppPath, TempRoot, SourceName, Extension,
              OutputName, nil, Warnings);
          Document := TReaderDocument.Create;
          try
            Document.Load(OutputName);
            Require(Document.PlainText.Contains(Marker), 'Converted local document lost Unicode prose');
            Require(Document.ImageCount = 1, 'Converted local document lost its adjacent image');
          finally Document.Free; end;
          Require(THashSHA2.GetHashStringFromFile(SourceName) = SourceHash,
            'Conversion changed its source document');
          Require(THashSHA2.GetHashStringFromFile(PictureName) = PictureHash,
            'Conversion changed its source image');
          Inc(Count);
        end;
    end;
    // A supplied archive member stream must not gain access to files beside
    // the containing archive, even when those names happen to match.
    SourceName := TPath.Combine(SourceRoot, 'archive-member.htm');
    TFile.WriteAllText(SourceName, '<html><body><p>' + Marker +
      '</p><img src="картинка%20Ё.png"/></body></html>', TEncoding.UTF8);
    ArchiveName := TPath.Combine(SourceRoot, 'archive.zip');
    RequireFailure(ArchiveName, '.htm', 'archive-adjacent-resources');
    // Local resource resolution remains confined to the source folder.
    TFile.WriteAllBytes(TPath.Combine(Root, 'outside.png'), TFile.ReadAllBytes(PictureName));
    TFile.WriteAllText(SourceName, '<html><body><p>' + Marker +
      '</p><img src="../outside.png"/></body></html>', TEncoding.UTF8);
    RequireFailure(SourceName, '.htm', 'outside-root-resources');
    TFile.WriteAllText(SourceName, '<html><body><p>' + Marker +
      '</p><img src="https://invalid.example/never-fetch.png"/></body></html>', TEncoding.UTF8);
    RequireFailure(SourceName, '.htm', 'external-resources');
    Require(THashSHA2.GetHashStringFromFile(PictureName) = PictureHash,
      'Failure path changed the source image');
    Require((Length(TDirectory.GetDirectories(TempRoot)) = 0) and
      (Length(TDirectory.GetFiles(TempRoot)) = 0),
      'Conversion left its owned temporary files after success/failure');
    Writeln('PASS reader-conversion-audit local_html_markdown=', Count,
      ' rejected_resources=3 source_and_stream_preserved=1');
  finally Warnings.Free; Source.Free; end;
end;
