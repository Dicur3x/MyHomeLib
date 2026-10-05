unit unit_ProgramUpdates;

interface

uses
  System.Classes, System.Net.HttpClient, Winapi.Windows, Winapi.Messages;

const
  WM_PROGRAM_UPDATE_CHECKED = WM_APP + $0501;
  PROGRAM_RELEASE_VERSION = '2.7.0_pre5.08';
  PROGRAM_RELEASES_API = 'https://api.github.com/repos/Dicur3x/MyHomeLib/releases?per_page=100';

type
  TProgramRelease = record
    Tag: string;
    URL: string;
  end;

  // The form owns this thread. Results are read only after WaitFor; the
  // Windows message carries no pointers and shutdown never synchronizes VCL.
  TProgramUpdateThread = class(TThread)
  private
    FHTTP: THTTPClient;
    FWindow: HWND;
    FURL: string;
    FSuccessful: Boolean;
    FRelease: TProgramRelease;
  protected
    procedure Execute; override;
  public
    constructor Create(AWindow: HWND; AHTTP: THTTPClient;
      const AURL: string = PROGRAM_RELEASES_API);
    destructor Destroy; override;
    property Successful: Boolean read FSuccessful;
    property ReleaseInfo: TProgramRelease read FRelease;
  end;

function CompareReleaseTags(const Left, Right: string; out Comparison: Integer): Boolean;
function ParseProgramReleases(const JSON: string; out ReleaseInfo: TProgramRelease): Boolean;

implementation

uses
  System.SysUtils, System.JSON, System.RegularExpressions;

type
  TReleaseNumbers = array[0..4] of Integer;

function ParseTag(const Tag: string; out Numbers: TReleaseNumbers): Boolean;
var
  Match: TMatch;
  I: Integer;
begin
  Result := False;
  Match := TRegEx.Match(Tag,
    '^v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:_pre([0-9]+)(?:\.([0-9]+))?)?$');
  if not Match.Success then
    Exit;
  for I := 0 to 2 do
    if not TryStrToInt(Match.Groups[I + 1].Value, Numbers[I]) then
      Exit;
  Numbers[3] := MaxInt; // a final release follows every pre-release
  Numbers[4] := 0;
  if (Match.Groups.Count > 4) and Match.Groups[4].Success then
  begin
    if not TryStrToInt(Match.Groups[4].Value, Numbers[3]) then
      Exit;
    if (Match.Groups.Count > 5) and Match.Groups[5].Success and
       not TryStrToInt(Match.Groups[5].Value, Numbers[4]) then
      Exit;
  end;
  Result := True;
end;

function CompareReleaseTags(const Left, Right: string; out Comparison: Integer): Boolean;
var
  A, B: TReleaseNumbers;
  I: Integer;
begin
  Comparison := 0;
  Result := ParseTag(Left, A) and ParseTag(Right, B);
  if not Result then
    Exit;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
    begin
      if A[I] > B[I] then Comparison := 1 else Comparison := -1;
      Exit;
    end;
end;

function ParseProgramReleases(const JSON: string; out ReleaseInfo: TProgramRelease): Boolean;
var
  Root, Item, Asset: TJSONValue;
  Obj: TJSONObject;
  Assets: TJSONArray;
  Draft, HasArchive: Boolean;
  Tag, Name: string;
  Comparison: Integer;
begin
  Result := False;
  ReleaseInfo := Default(TProgramRelease);
  Root := TJSONObject.ParseJSONValue(JSON);
  try
    if not (Root is TJSONArray) then
      Exit;
    for Item in TJSONArray(Root) do
    begin
      if not (Item is TJSONObject) then
        Continue;
      Obj := TJSONObject(Item);
      if not Obj.TryGetValue<Boolean>('draft', Draft) or Draft then
        Continue;
      if not Obj.TryGetValue<string>('tag_name', Tag) or
         not CompareReleaseTags(Tag, Tag, Comparison) then
        Continue;
      if not Obj.TryGetValue<TJSONArray>('assets', Assets) then
        Continue;
      HasArchive := False;
      for Asset in Assets do
        if (Asset is TJSONObject) and
           TJSONObject(Asset).TryGetValue<string>('name', Name) and
           ((Name = 'HomeLibRu.zip') or (Name = 'HomeLibRu_x64.zip')) then
          HasArchive := True;
      if not HasArchive then
        Continue;
      if (ReleaseInfo.Tag = '') or
         (CompareReleaseTags(Tag, ReleaseInfo.Tag, Comparison) and (Comparison > 0)) then
      begin
        ReleaseInfo.Tag := Tag;
        // Only our repository can be opened, never a URL supplied in JSON.
        ReleaseInfo.URL := 'https://github.com/Dicur3x/MyHomeLib/releases/tag/' + Tag;
      end;
    end;
    Result := ReleaseInfo.Tag <> '';
  finally
    Root.Free;
  end;
end;

constructor TProgramUpdateThread.Create(AWindow: HWND; AHTTP: THTTPClient; const AURL: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWindow := AWindow;
  FURL := AURL;
  FHTTP := AHTTP;
  FHTTP.UserAgent := 'HomeLib Ru';
  FHTTP.ConnectionTimeout := 4000;
  FHTTP.ResponseTimeout := 6000;
end;

destructor TProgramUpdateThread.Destroy;
begin
  // inherited waits for Execute before its HTTP client can be destroyed
  inherited;
  FHTTP.Free;
end;

procedure TProgramUpdateThread.Execute;
var
  Response: IHTTPResponse;
begin
  try
    if not Terminated then
    begin
      Response := FHTTP.Get(FURL);
      if (Response.StatusCode = 200) and not Terminated then
        FSuccessful := ParseProgramReleases(Response.ContentAsString(TEncoding.UTF8), FRelease);
    end;
  except
    // The form decides whether a failed check needs a manual-check message.
    FSuccessful := False;
  end;
  if not Terminated then
    PostMessage(FWindow, WM_PROGRAM_UPDATE_CHECKED, 0, 0);
end;

end.
