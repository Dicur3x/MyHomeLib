unit unit_MCP_FLibrarySelfTest;

interface

procedure RunFLibraryRestoreMode(const ContainerFileName, BookEntryName,
  OutputFileName: string);

implementation

uses
  System.Classes,
  System.SysUtils,
  System.Diagnostics,
  System.JSON,
  unit_MHLArchiveHelpers,
  unit_FLibraryCompat,
  unit_MCP_Transport;

procedure RunFLibraryRestoreMode(const ContainerFileName, BookEntryName,
  OutputFileName: string);
var
  Archive: TMHLZip;
  CoverStream: TStream;
  EffectiveStream: TStream;
  OutputStream: TFileStream;
  RestoredStream: TStream;
  SourceStream: TMemoryStream;
  Stopwatch: TStopwatch;
  CoverMilliseconds: Int64;
  ExtractMilliseconds: Int64;
  RestoreMilliseconds: Int64;
  Summary: TJSONObject;
  Transport: TMcpTransport;
begin
  if not IsSevenZipArchive(ContainerFileName) then
    raise Exception.Create('The FLibrary self-test requires a .7z container.');

  SourceStream := TMemoryStream.Create;
  RestoredStream := nil;
  CoverStream := nil;
  Archive := nil;
  try
    Stopwatch := TStopwatch.StartNew;
    CoverStream := ExtractFLibraryBookCover(ContainerFileName, BookEntryName);
    CoverMilliseconds := Stopwatch.ElapsedMilliseconds;

    Stopwatch := TStopwatch.StartNew;
    Archive := TMHLZip.Create(ContainerFileName, True);
    Archive.ExtractToStream(BookEntryName, SourceStream);
    SourceStream.Position := 0;
    ExtractMilliseconds := Stopwatch.ElapsedMilliseconds;

    Stopwatch := TStopwatch.StartNew;
    RestoredStream := RestoreFLibraryBook(ContainerFileName, BookEntryName,
      SourceStream);
    RestoreMilliseconds := Stopwatch.ElapsedMilliseconds;
    if Assigned(RestoredStream) then
      EffectiveStream := RestoredStream
    else
      EffectiveStream := SourceStream;

    EffectiveStream.Position := 0;
    OutputStream := TFileStream.Create(OutputFileName, fmCreate);
    try
      OutputStream.CopyFrom(EffectiveStream, 0);
    finally
      OutputStream.Free;
    end;

    Summary := TJSONObject.Create;
    try
      Summary.AddPair('restored', TJSONBool.Create(Assigned(RestoredStream)));
      Summary.AddPair('source_size', TJSONNumber.Create(SourceStream.Size));
      Summary.AddPair('output_size', TJSONNumber.Create(EffectiveStream.Size));
      Summary.AddPair('cover_found', TJSONBool.Create(Assigned(CoverStream)));
      if Assigned(CoverStream) then
        Summary.AddPair('cover_size', TJSONNumber.Create(CoverStream.Size))
      else
        Summary.AddPair('cover_size', TJSONNumber.Create(0));
      Summary.AddPair('cover_ms', TJSONNumber.Create(CoverMilliseconds));
      Summary.AddPair('extract_ms', TJSONNumber.Create(ExtractMilliseconds));
      Summary.AddPair('restore_ms', TJSONNumber.Create(RestoreMilliseconds));
      Transport := TMcpTransport.Create;
      try
        Transport.WriteMessage(Summary.ToJSON);
      finally
        Transport.Free;
      end;
    finally
      Summary.Free;
    end;
  finally
    CoverStream.Free;
    RestoredStream.Free;
    Archive.Free;
    SourceStream.Free;
  end;
end;

end.
