unit unit_IBKRuntime;

interface

uses System.SysUtils;

const
  IBK_VERSION = '9.6.5';
  IBK_MIRROR_PREFIX = 'https://github.com/Dicur3x/MyHomeLib/releases/download/optional-alreader-2.5.1009.25/';
  IBK_MIRROR_NAME = 'ICE-Book-Reader-Russian-9.6.5-original.zip';
  IBK_EXTRACTOR_MIRROR_NAME = 'innoextract-1.9-windows-original.zip';
  IBK_PACKAGE_PAGE = 'https://www.bestfree.ru/soft/office/bookreader-en-downloader.php';
  IBK_PACKAGE_SIZE = 6444324;
  IBK_PACKAGE_SHA256 = 'd2b2c4edfb3c6383627fa98c0f81fd46e7703f617d6c85e6a0efd14c777f0c3d';
  IBK_EXTRACTOR_URL = 'https://constexpr.org/innoextract/files/innoextract-1.9-windows.zip';
  IBK_EXTRACTOR_SIZE = 520705;
  IBK_EXTRACTOR_SHA256 = '6989342c9b026a00a72a38f23b62a8e6a22cc5de69805cf47d68ac2fec993065';
  IBK_EXTRACTOR_EXE_SHA256 = '946bd06d8b3722a791fea4d84f496139eef6faef61640924cb72f5f1998a68e1';
  IBK_INSTALLER_SHA256 = '0ff4d0afd619fd29b27b443d3853622c9af0c8293c8737aca4ca3a3aeab60c3f';
  IBK_FILES: array[0..2] of string = ('Rus.key','License.txt','ICEBookReader-original.zip');
  IBK_HASHES: array[0..2] of string = (
    '0c6ec71c2c1c9f3cdf7d2f99c3ebfaaf480d01021f28d710d2464b0d560cb9f1',
    '6ae2062ebba781d1f9539150bf1bfbdbdad0111b8e49c867a9adc3c1ddf2a448',
    IBK_PACKAGE_SHA256);

function IBKPackageURL(const HTML: string): string;
function IsIBKPackageURL(const URL: string): Boolean;
function IBKRuntimeAvailable(const AppPath: string): Boolean;

implementation

uses System.Classes, System.RegularExpressions, System.IOUtils, System.Hash;

function IsIBKPackageURL(const URL: string): Boolean;
begin
  Result:=TRegEx.IsMatch(URL,'\Ahttps://www\.bestfree\.ru/soft/office/ICE_Book_Reader_v9\.6\.5\.Rus\.zip\?e=[0-9]{10}&s=[0-9a-f]{64}\z');
end;

function IBKPackageURL(const HTML: string): string;
var Match: TMatch;
begin
  Result:='';
  if Length(HTML)>1024*1024 then Exit;
  Match:=TRegEx.Match(HTML,'href="(/soft/office/ICE_Book_Reader_v9\.6\.5\.Rus\.zip\?e=[0-9]{10}&amp;s=[0-9a-f]{64})"');
  if Match.Success then Result:='https://www.bestfree.ru'+Match.Groups[1].Value.Replace('&amp;','&');
  if not IsIBKPackageURL(Result) then Result:='';
end;

function IBKRuntimeAvailable(const AppPath: string): Boolean;
var FileName: string; Stream: TFileStream;
begin
  Result:=False;
  try
    for var I:=Low(IBK_FILES) to High(IBK_FILES) do
    begin
      FileName:=TPath.Combine(AppPath,'tools/ibk/'+IBK_FILES[I]);
      if not FileExists(FileName) then Exit;
      Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
      try
        if (Stream.Size<1) or (Stream.Size>8*1024*1024) or
          not SameText(THashSHA2.GetHashString(Stream),IBK_HASHES[I]) then Exit;
      finally Stream.Free; end;
    end;
    Result:=True;
  except Result:=False; end;
end;

end.
