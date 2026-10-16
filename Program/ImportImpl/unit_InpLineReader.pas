unit unit_InpLineReader;

interface

uses System.Classes, System.SysUtils, unit_MHLArchiveHelpers;

const INP_DISK_THRESHOLD = 8 * 1024 * 1024;

type
  // Extraction still verifies the complete ZIP CRC before rows are published.
  // Large members live in an owned temporary file rather than a second full
  // in-memory copy alongside the relation dictionaries.
  TInpLineReader = class
  private
    FInput: TStream;
    FReader: TStreamReader;
    FTempFile: string;
    FLineNumber: Integer;
    FCanceled: TFunc<Boolean>;
    function GetBytePosition: Int64;
    function GetSize: Int64;
  public
    constructor Create(Archive: TMHLZip; Index: Integer; const TempPath: string;
      const IsCanceled: TFunc<Boolean> = nil);
    destructor Destroy; override;
    function ReadLine(out Line: string): Boolean;
    property LineNumber: Integer read FLineNumber;
    property BytePosition: Int64 read GetBytePosition;
    property Size: Int64 read GetSize;
    property SpoolFileName: string read FTempFile;
  end;

implementation

uses System.IOUtils;

type
  TCancelableInpStream = class(TStream)
  private
    FStream: TStream;
    FCanceled: TFunc<Boolean>;
  protected
    procedure SetSize(const NewSize: Int64); override;
  public
    constructor Create(Stream: TStream; const Canceled: TFunc<Boolean>);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TCancelableInpStream.Create(Stream: TStream; const Canceled: TFunc<Boolean>);
begin inherited Create; FStream := Stream; FCanceled := Canceled; end;
destructor TCancelableInpStream.Destroy;
begin FStream.Free; inherited; end;
procedure TCancelableInpStream.SetSize(const NewSize: Int64);
begin FStream.Size := NewSize; end;
function TCancelableInpStream.Read(var Buffer; Count: Longint): Longint;
begin
  if Assigned(FCanceled) and FCanceled() then Abort;
  Result := FStream.Read(Buffer, Count);
end;
function TCancelableInpStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Assigned(FCanceled) and FCanceled() then Abort;
  Result := FStream.Write(Buffer, Count);
end;
function TCancelableInpStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin Result := FStream.Seek(Offset, Origin); end;

constructor TInpLineReader.Create(Archive: TMHLZip; Index: Integer;
  const TempPath: string; const IsCanceled: TFunc<Boolean> = nil);
begin
  inherited Create;
  FCanceled := IsCanceled;
  if Assigned(FCanceled) and FCanceled() then Abort;
  if Archive.FileSizes[Index] > INP_DISK_THRESHOLD then
  begin
    if not ForceDirectories(TempPath) then
      raise EFCreateError.CreateFmt('Не удалось создать временную папку импорта: %s', [TempPath]);
    FTempFile := TPath.Combine(TempPath, 'homelib-inp-' + TGUID.NewGuid.ToString + '.tmp');
    FInput := TFileStream.Create(FTempFile, fmCreate);
  end
  else FInput := TMemoryStream.Create;
  if Assigned(IsCanceled) then FInput := TCancelableInpStream.Create(FInput, IsCanceled);
  Archive.ExtractToStream(Index, FInput);
  if Assigned(FCanceled) and FCanceled() then Abort;
  FInput.Position := 0;
  FReader := TStreamReader.Create(FInput, TEncoding.UTF8, True, 65536);
end;

destructor TInpLineReader.Destroy;
begin
  FReader.Free;
  FInput.Free;
  if FTempFile <> '' then
    try
      if FileExists(FTempFile) then TFile.Delete(FTempFile);
    except
      // A locked owned spool can be cleaned later; never mask the import's
      // error or cancellation, and never touch other temporary files.
    end;
  inherited;
end;

function TInpLineReader.ReadLine(out Line: string): Boolean;
begin
  Line := '';
  if Assigned(FCanceled) and FCanceled() then Abort;
  Result := not FReader.EndOfStream;
  if Result then
  begin
    Line := FReader.ReadLine;
    Inc(FLineNumber);
  end;
end;

function TInpLineReader.GetBytePosition: Int64;
begin Result := FInput.Position; end;

function TInpLineReader.GetSize: Int64;
begin Result := FInput.Size; end;

end.
