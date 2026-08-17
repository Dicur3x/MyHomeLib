(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2023 Oleksiy Penkov
  *
  * Author(s)           Oleksiy Penkov
  * Created             20.05.2011
  * Reworked            20.03.2023
  * Description
  *
  *
  * History
  *
  ****************************************************************************** *)

unit unit_MHLArchiveHelpers;

interface

uses
  Classes,
  System.Zip,
  System.Masks;
type

  TStreamSource = record
    Name: string;
    Stream: TStream;
  end;

  TMHLZip = class(TObject)
    private
      FZip: TZipFile;
      FLastID: Integer;
      FSearchPattern: string;
      FSearchMask: TMask;
      FSearchMatchAll: Boolean;
      FSearchBaseNameOnly: Boolean;
      FHeader: TZipHeader;
      FFileNames: TArray<string>;
      procedure RefreshFileNames;
      function EntryMatches(const Index: Integer): Boolean;
      function FindFrom(const StartIndex: Integer): Boolean;
      function FindEntryIndex(const AFileName: string): Integer;
      procedure CopyEntryToStream(const Index: Integer; const Destination: TStream);
      function GetLastSize: Integer;
      function GetLastName: string;
      function GetLastIndex: Integer;
      function GetFileCount: Integer;


    public
      constructor Create(const AFileName: string; RO: Boolean;
        UpdateExisting: Boolean = False);
      destructor Destroy; override;

      function ExtractToStream(No: integer): TMemoryStream; overload;
      procedure ExtractToStream(const No: Integer; const Stream: TStream); overload;
      procedure ExtractToStream(const AFileName: string; const Stream: TMemoryStream); overload;
      procedure ExtractToStream(const AFileName: string; const Stream: TStream); overload;
      function GetIdxByExt(const Ext: string):Integer;
      function FileNameAt(const Index: Integer): string;
      function ExtractToString(AFileName: string):string;

      function Find(AFileName: string): Boolean;
      function FindNext: Boolean;
      function Test(const AFileName: string): Boolean;


      procedure AddFiles(const FileNames: string);
      procedure AddFromStream(const AFileName: string; AStream: TStream);
      procedure DeleteFile(const AFileName: string);
      procedure RenameFile(const OldFileName, NewFileName: string);

      property LastName: string read GetLastName;
      property LastIndex: Integer read GetLastIndex;
      property FileCount: Integer read GetFileCount;
      property LastSize: Integer read GetLastSize;
  end;

  // Supported archive formats (only ones that work for both input and output)
  TArchiveFormat = (
    afZip
  );

function IsArchiveExt(const FileName: string): Boolean;

const
  ZIP_EXTENSION = '.zip';

implementation

uses
  SysUtils;

function IsArchiveExt(const FileName: string): Boolean;
var
  ext: string;
begin
  ext := AnsiLowercase(ExtractFileExt(FileName));
  Result := (ext = ZIP_EXTENSION);
end;

function IsValidUTF8(const Bytes: TBytes; const StartIndex: Integer): Boolean;
var
  I, Count: Integer;
  B, B2: Byte;

  function IsContinuation(const Value: Byte): Boolean; inline;
  begin
    Result := (Value and $C0) = $80;
  end;
begin
  I := StartIndex;
  Count := Length(Bytes);
  while I < Count do
  begin
    B := Bytes[I];
    if B <= $7F then
      Inc(I)
    else if (B >= $C2) and (B <= $DF) then
    begin
      if I + 1 >= Count then
        Exit(False);
      if not IsContinuation(Bytes[I + 1]) then
        Exit(False);
      Inc(I, 2);
    end
    else if (B >= $E0) and (B <= $EF) then
    begin
      if I + 2 >= Count then
        Exit(False);
      B2 := Bytes[I + 1];
      if not IsContinuation(Bytes[I + 2]) or
         ((B = $E0) and ((B2 < $A0) or (B2 > $BF))) or
         ((B = $ED) and ((B2 < $80) or (B2 > $9F))) or
         ((B <> $E0) and (B <> $ED) and not IsContinuation(B2)) then
        Exit(False);
      Inc(I, 3);
    end
    else if (B >= $F0) and (B <= $F4) then
    begin
      if I + 3 >= Count then
        Exit(False);
      B2 := Bytes[I + 1];
      if not IsContinuation(Bytes[I + 2]) or
         not IsContinuation(Bytes[I + 3]) or
         ((B = $F0) and ((B2 < $90) or (B2 > $BF))) or
         ((B = $F4) and ((B2 < $80) or (B2 > $8F))) or
         ((B <> $F0) and (B <> $F4) and not IsContinuation(B2)) then
        Exit(False);
      Inc(I, 4);
    end
    else
      Exit(False);
  end;
  Result := True;
end;

{ TMHLZip }

procedure TMHLZip.RefreshFileNames;
begin
  // TZipFile.FileNames materialises and decodes the complete array on every
  // access.  Cache it once so wildcard scans stay O(n), not O(n^2).
  FFileNames := FZip.FileNames;
end;

function TMHLZip.EntryMatches(const Index: Integer): Boolean;
var
  EntryName: string;
  DelimiterPos: Integer;
begin
  EntryName := FFileNames[Index];

  // MatchesMask follows DOS wildcard rules.  Treat *.* as "all entries"
  // explicitly: unlike FindFirst on Windows, generic mask implementations may
  // otherwise omit names without a dot.
  if FSearchMatchAll then
    Exit(True);

  if not Assigned(FSearchMask) then
    Exit(False);

  if FSearchBaseNameOnly then
  begin
    // ZIP entries use '/', but accept '\' as well for archives produced by
    // non-conforming tools.  Find('*.fb2') must also match dir/book.fb2.
    DelimiterPos := LastDelimiter('/\', EntryName);
    if DelimiterPos > 0 then
      EntryName := Copy(EntryName, DelimiterPos + 1, MaxInt);
  end
  else if Pos('\', EntryName) > 0 then
    EntryName := StringReplace(EntryName, '\', '/', [rfReplaceAll]);

  // System.Masks.TMask has no case-sensitivity constructor overload in the
  // Delphi versions supported by this project.  Normalising both operands
  // keeps archive lookup deterministic for non-ASCII file names as well.
  Result := FSearchMask.Matches(LowerCase(EntryName));
end;

function TMHLZip.FindFrom(const StartIndex: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := StartIndex to FZip.FileCount - 1 do
    if EntryMatches(I) then
    begin
      FLastID := I;
      Exit(True);
    end;

  FLastID := -1;
end;

function TMHLZip.FindEntryIndex(const AFileName: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to FZip.FileCount - 1 do
    if SameText(FFileNames[I], AFileName) then
      Exit(I);
end;

procedure TMHLZip.CopyEntryToStream(const Index: Integer; const Destination: TStream);
var
  Source: TStream;
begin
  if not Assigned(Destination) then
    raise EArgumentNilException.Create('Destination');
  if (Index < 0) or (Index >= FZip.FileCount) then
    raise ERangeError.CreateFmt('Archive entry index %d is out of range', [Index]);

  Source := nil;
  try
    // Verify the original CRC while streaming.  This prevents an editor
    // rebuild from silently repackaging already-corrupt data with a fresh CRC.
    FZip.Read(Index, Source, FHeader, True);
    if not Assigned(Source) then
      raise EZipException.CreateFmt('Unable to read archive entry %d', [Index]);

    Source.Position := 0;
    Destination.Position := 0;
    Destination.Size := 0;
    Destination.CopyFrom(Source, 0);
    Destination.Position := 0;
    FLastID := Index;
  finally
    FreeAndNil(Source);
  end;
end;

function TMHLZip.ExtractToStream(No: integer): TMemoryStream;
begin
  Result := TMemoryStream.Create;
  try
    CopyEntryToStream(No, Result);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

procedure TMHLZip.ExtractToStream(const No: Integer; const Stream: TStream);
begin
  CopyEntryToStream(No, Stream);
end;

procedure TMHLZip.ExtractToStream(const AFileName: string; const Stream: TMemoryStream);
begin
  ExtractToStream(AFileName, TStream(Stream));
end;

procedure TMHLZip.ExtractToStream(const AFileName: string; const Stream: TStream);
var
  Index: Integer;
begin
  Index := FindEntryIndex(AFileName);
  if Index < 0 then
    raise EZipException.CreateFmt('Archive entry "%s" was not found', [AFileName]);
  CopyEntryToStream(Index, Stream);
end;

function TMHLZip.ExtractToString(AFileName: string): string;
var
  Bytes: TBytes;
  Encoding: TEncoding;
  Index: Integer;
  Offset: Integer;
begin
  Index := FindEntryIndex(AFileName);
  if Index < 0 then
    raise EZipException.CreateFmt('Archive entry "%s" was not found', [AFileName]);

  FZip.Read(Index, Bytes);
  FLastID := Index;

  Offset := 0;
  if Length(Bytes) >= 3 then
    if (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
      Offset := 3;

  // Current INPX metadata is UTF-8; legacy exports used the active Windows
  // code page without a BOM.  Validate first because Delphi's UTF-8 decoder
  // replaces malformed bytes instead of exposing a strict-decoding option.
  if IsValidUTF8(Bytes, Offset) then
    Result := TEncoding.UTF8.GetString(Bytes, Offset, Length(Bytes) - Offset)
  else
  begin
    Encoding := TEncoding.Default;
    Result := Encoding.GetString(Bytes, Offset, Length(Bytes) - Offset);
  end;
end;
function TMHLZip.Find(AFileName: string): Boolean;
var
  NewMask: TMask;
  NormalizedPattern: string;
  NewMatchAll: Boolean;
  NewBaseNameOnly: Boolean;
begin
  NormalizedPattern := StringReplace(AFileName, '\', '/', [rfReplaceAll]);
  NewMatchAll := (NormalizedPattern = '*') or
    (NormalizedPattern = '*.*');
  NewBaseNameOnly := (Pos('/', NormalizedPattern) = 0) and
    ((Pos('*', NormalizedPattern) > 0) or
     (Pos('?', NormalizedPattern) > 0) or
     (Pos('[', NormalizedPattern) > 0));

  NewMask := nil;
  if not NewMatchAll then
    NewMask := TMask.Create(LowerCase(NormalizedPattern));
  FreeAndNil(FSearchMask);
  FSearchMask := NewMask;
  FSearchPattern := AFileName;
  FSearchMatchAll := NewMatchAll;
  FSearchBaseNameOnly := NewBaseNameOnly;

  Result := FindFrom(0);
end;

function TMHLZip.FindNext: Boolean;
begin
  if (FLastID < 0) or (FSearchPattern = '') then
    Exit(False);
  Result := FindFrom(FLastID + 1);
end;

function TMHLZip.GetFileCount: Integer;
begin
  Result := FZip.FileCount;
end;

function TMHLZip.GetIdxByExt(const Ext: string): Integer;
var
  i: Integer;
  FN: string;
begin
  Result := -1;
  FSearchPattern := '';
  FreeAndNil(FSearchMask);
  FSearchMatchAll := False;
  FSearchBaseNameOnly := False;
  FLastID := -1;
  for i := 0 to FZip.FileCount - 1 do
  begin
    FN := FFileNames[i];
    if SameText(ExtractFileExt(FN), Ext) then
    begin
      Result := i;
      FLastID := i;
      Break;
    end;
  end;
end;

function TMHLZip.FileNameAt(const Index: Integer): string;
begin
  if (Index < 0) or (Index >= FZip.FileCount) then
    raise ERangeError.CreateFmt('Archive entry index %d is out of range', [Index]);
  Result := FFileNames[Index];
end;

function TMHLZip.GetLastName: string;
begin
  if (FLastID < 0) or (FLastID >= FZip.FileCount) then
    raise ERangeError.Create('No current archive entry');
  Result := FFileNames[FLastID];
end;

function TMHLZip.GetLastIndex: Integer;
begin
  Result := FLastID;
end;

function TMHLZip.GetLastSize: Integer;
begin
  if (FLastID < 0) or (FLastID >= FZip.FileCount) then
    raise ERangeError.Create('No current archive entry');
  if FZip.FileInfos[FLastID].UncompressedSize > High(Integer) then
    raise ERangeError.CreateFmt('Archive entry "%s" is too large', [FFileNames[FLastID]]);
  Result := Integer(FZip.FileInfos[FLastID].UncompressedSize);
end;

procedure TMHLZip.RenameFile(const OldFileName, NewFileName: string);
var
  Index: Integer;
begin
  Index := FindEntryIndex(OldFileName);
  if Index < 0 then
    raise EZipException.CreateFmt('Archive entry "%s" was not found', [OldFileName]);
  FZip.Rename(Index, NewFileName);
  FFileNames[Index] := NewFileName;
  FLastID := Index;
end;

function TMHLZip.Test(const AFileName: string): Boolean;
begin
 //
  Result := FZip.IsValid(AFileName)
end;

procedure TMHLZip.AddFiles(const FileNames: string);
begin
  FZip.Add(FileNames);
  RefreshFileNames;
end;
procedure TMHLZip.AddFromStream(const AFileName: string; AStream: TStream);
var
  SavedPosition: Int64;
begin
  if not Assigned(AStream) then
    raise EArgumentNilException.Create('AStream');

  SavedPosition := AStream.Position;
  try
    AStream.Position := 0;
    FZip.Add(AStream, AFileName);
    RefreshFileNames;
  finally
    AStream.Position := SavedPosition;
  end;
end;

procedure TMHLZip.DeleteFile(const AFileName: string);
var
  Index: Integer;
begin
  Index := FindEntryIndex(AFileName);
  if Index < 0 then
    raise EZipException.CreateFmt('Archive entry "%s" was not found', [AFileName]);

  FZip.Delete(Index);
  RefreshFileNames;
  if Length(FFileNames) = 0 then
    FLastID := -1
  else if Index < Length(FFileNames) then
    FLastID := Index
  else
    FLastID := High(FFileNames);
end;

constructor TMHLZip.Create(const AFileName: string; RO: Boolean;
  UpdateExisting: Boolean);
begin
  Inherited Create;

  FZip := nil;
  FLastID := -1;
  FSearchPattern := '';
  FSearchMask := nil;
  FSearchMatchAll := False;
  FSearchBaseNameOnly := False;

  if RO and not(FileExists(AFileName)) then
    raise Exception.Create(Format('Архив %s не найден!',[AFileName]));
  FZip := TZipFile.Create;
  if RO then
    FZip.Open(AFileName, zmRead)
  else if UpdateExisting then
  begin
    if not FileExists(AFileName) then
      raise Exception.Create(Format('Архив %s не найден!', [AFileName]));
    // zmWrite replaces the complete archive.  Renaming an entry therefore
    // requires zmReadWrite or the copied book container would be truncated.
    FZip.Open(AFileName, zmReadWrite);
  end
  else
    FZip.Open(AFileName, zmWrite);

  RefreshFileNames;
  // Several long-standing callers use LastName/LastSize immediately after
  // opening an archive.  Preserve that public contract while still keeping an
  // empty archive in an explicit "no current entry" state.
  if FZip.FileCount > 0 then
    FLastID := 0;
end;

destructor TMHLZip.Destroy;
begin
  // TZipFile.Destroy closes an open archive itself.  Keeping this nil-safe is
  // essential because Delphi invokes Destroy automatically when Create raises.
  FreeAndNil(FSearchMask);
  FreeAndNil(FZip);
  inherited;
end;

end.
