program LangTest;

{$APPTYPE CONSOLE}

// The real embedded catalogs, so embedded-vs-file precedence is exercised.
// build.sh passes -R"Program" so this resolves.
{$R lang.res}

// Unsigned and badly signed catalogs (make_fixture_res.js); both must be refused.
{$R langtest_fixture.res}

// Usage: LangTest.exe uselocaldata <report.json>
// `uselocaldata` makes the exe's directory the work directory, so a scratch
// folder with its own ini and Lang\ is an isolated fixture. The report goes to
// a file because console output would mangle Cyrillic via the code page.

uses
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  Vcl.Forms,
  // No `in '...'` clauses: dcc64 resolves them against its working directory.
  unit_Settings,
  unit_Localization,
  unit_LangSignature;

var
  Report, LocaleObj, Translations, GenresObj: TJSONObject;
  Arr: TJSONArray;
  Probes: TJSONValue;
  Info: TLocaleInfo;
  I: Integer;
  ProbeFile, Source: string;
  Active: Boolean;
  TestSettings: TMHLSettings;
begin
  Report := TJSONObject.Create;
  try
    Active := InitLocalization;
    Report.AddPair('active', TJSONBool.Create(Active));
    Report.AddPair('status', LocalizationStatus);

    Arr := TJSONArray.Create;
    for Info in AvailableLocales do
    begin
      LocaleObj := TJSONObject.Create;
      LocaleObj.AddPair('code', Info.Code);
      LocaleObj.AddPair('name', Info.Name);
      Arr.AddElement(LocaleObj);
    end;
    Report.AddPair('locales', Arr);

    Translations := TJSONObject.Create;
    ProbeFile := ExtractFilePath(Application.ExeName) + 'probe.json';
    if FileExists(ProbeFile) then
    begin
      Probes := TJSONObject.ParseJSONValue(
        TFile.ReadAllText(ProbeFile, TEncoding.UTF8));
      try
        if Probes is TJSONArray then
          for I := 0 to TJSONArray(Probes).Count - 1 do
          begin
            Source := TJSONArray(Probes).Items[I].Value;
            Translations.AddPair(Source, TranslateText(Source));
          end;
      finally
        Probes.Free;
      end;
    end;
    Report.AddPair('translations', Translations);

    // Probes the verifier directly, independent of loader choice.
    Report.AddPair('verify', TJSONBool.Create(
      VerifyCatalogSignature(ExtractFilePath(Application.ExeName)
        + 'Lang' + PathDelim + 'verify.json')));

    // A separate TMHLSettings: the harness has no data module. File names only:
    // the scratch path differs on every run.
    GenresObj := TJSONObject.Create;
    TestSettings := TMHLSettings.Create;
    try
      TestSettings.LoadSettings;
      GenresObj.AddPair('fb2',
        ExtractFileName(TestSettings.SystemFileName[sfGenresFB2]));
      GenresObj.AddPair('nonfb2',
        ExtractFileName(TestSettings.SystemFileName[sfGenresNonFB2]));
    finally
      TestSettings.Free;
    end;
    Report.AddPair('genres', GenresObj);

    TFile.WriteAllText(ParamStr(ParamCount), Report.ToJSON, TEncoding.UTF8);
  finally
    Report.Free;
  end;
end.
