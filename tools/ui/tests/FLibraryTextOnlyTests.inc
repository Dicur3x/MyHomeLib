// Explicit text-only export must not install or run an image decoder first.
// All file moves affect only the guarded native regression profile.
procedure TestFLibraryExplicitTextOnlyExport(const Book: TBookRecord; const RestoredSource: string);
var Decoder, HeldDecoder, SavedPath, Prepared, Target, SourceHash: string;
  Warnings: TStringList; Document: TReaderDocument; MissingRequested: Boolean;
  UncachedBook: TBookRecord;
begin
  Require(FileExists(Settings.AppPath+'native-regression.marker'),'Text-only module test requires the isolated profile');
  Decoder:=FindExternalTool('djxl.exe','jpeg-xl');
  Require((Decoder<>'') and StartsText(IncludeTrailingPathDelimiter(TPath.GetFullPath(Settings.AppPath)),TPath.GetFullPath(Decoder)),
    'Text-only test may hold only its isolated JPEG XL helper');
  HeldDecoder:=Decoder+'.explicit-none-held'; Require(not FileExists(HeldDecoder),'Decoder hold target already exists');
  SavedPath:=GetEnvironmentVariable('PATH'); SourceHash:=UpdateSHA256(RestoredSource);
  Warnings:=TStringList.Create;
  TFile.Move(Decoder,HeldDecoder);
  try
    Require(SetEnvironmentVariable('PATH',''),'Cannot isolate decoder search');
    Require(FindExternalTool('djxl.exe','jpeg-xl')='','JPEG XL helper remains discoverable');
    UncachedBook:=Book; UncachedBook.LibID:=Book.LibID+'-explicit-none';
    Prepared:=PrepareConversionSource(UncachedBook,nil,'.fb2',False);
    Require((Prepared<>'') and not SameFileName(Prepared,RestoredSource),'Text source reused a restored reading copy');
    Require(not TFile.ReadAllText(Prepared,TEncoding.UTF8).Contains('<binary'),'Text source unexpectedly restored a JXL image');
    for var Extension in ['.fb2','.epub'] do
    begin
      Target:=Settings.AppPath+'flibrary-without-decoder'+Extension;
      ConvertBasicBook(Settings.AppPath,Settings.TempPath,Prepared,'.fb2',Target,nil,
        Warnings,nil,'','','',False,nil,'none');
      Document:=TReaderDocument.Create;
      try
        Document.Load(Target);
        Require((Document.ImageCount=0) and Document.PlainText.Contains('Текст с иллюстрацией'),
          'Text-only FLibrary export without a decoder lost its readable text');
        Require(Document.PlainText.Contains('Изображение не включено в эту копию'),
          'Text-only FLibrary export did not explain the omitted picture');
      finally Document.Free; end;
    end;
    MissingRequested:=False;
    try
      PrepareConversionSource(UncachedBook,nil,'.fb2');
    except on E: EMHLComponentRequired do MissingRequested:=E.ComponentID='JPEG XL'; end;
    Require(MissingRequested,'Ordinary export reused the intermediate source without its pictures');
  finally
    SetEnvironmentVariable('PATH',PChar(SavedPath));
    TFile.Move(HeldDecoder,Decoder); Warnings.Free;
  end;
  Require(UpdateSHA256(RestoredSource)=SourceHash,'Text-only export changed the restored reading source');
  Require(PrepareConversionSource(Book,nil,'.fb2')=RestoredSource,'Restoring the decoder lost the normal reading/export cache');
  Writeln('PASS explicit FLibrary text-only export needs no JPEG XL decoder and cannot replace a restored reading copy');
end;
