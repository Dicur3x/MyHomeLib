unit unit_MCP_PublisherSourceSelfTest;

interface

procedure RunPublisherSourceSelfTestMode;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.SysUtils,
  System.IOUtils,
  System.Diagnostics,
  System.JSON,
  System.StrUtils,
  unit_Globals,
  unit_MHLArchiveHelpers,
  unit_MHLExternalTools,
  unit_PublisherSeriesSource,
  unit_MCP_Transport,
  dm_user;

const
  BookCount = 4;
  BookBytes = 20 * 1024 * 1024;
  BufferBytes = 64 * 1024;
  BookFooter: AnsiString = '</p></section></body></FictionBook>';

function BookHeader(const Index: Integer): AnsiString;
begin
  Result := AnsiString('<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' +
    '<description><title-info><book-title>Book ' + IntToStr(Index) +
    '</book-title></title-info><publish-info><sequence name="Source fixture"' +
    ' number="' + IntToStr(Index) + '"/></publish-info></description>' +
    '<body><section><p>');
end;

procedure WriteBook(const Path: string; const Index: Integer);
var
  Stream: TFileStream;
  Header: AnsiString;
  Buffer: array[0..BufferBytes - 1] of Byte;
  Remaining, Count: Integer;
begin
  Header := BookHeader(Index);
  FillChar(Buffer, SizeOf(Buffer), Ord('A') + Index);
  Stream := TFileStream.Create(Path, fmCreate);
  try
    Stream.WriteBuffer(PAnsiChar(Header)^, Length(Header));
    Remaining := BookBytes - Length(Header) - Length(BookFooter);
    while Remaining > 0 do
    begin
      Count := Remaining;
      if Count > SizeOf(Buffer) then Count := SizeOf(Buffer);
      Stream.WriteBuffer(Buffer, Count);
      Dec(Remaining, Count);
    end;
    Stream.WriteBuffer(PAnsiChar(BookFooter)^, Length(BookFooter));
  finally
    Stream.Free;
  end;
end;

procedure CheckBook(const Stream: TStream; const Index: Integer);
var
  Header: AnsiString;
  Buffer, Expected: array[0..BufferBytes - 1] of Byte;
  Remaining, Count: Integer;
begin
  if not Assigned(Stream) or (Stream.Size <> BookBytes) then
    raise Exception.Create('Publisher source: incomplete output size');
  Stream.Position := 0;
  Header := BookHeader(Index);
  Stream.ReadBuffer(Buffer, Length(Header));
  if not CompareMem(@Buffer[0], PAnsiChar(Header), Length(Header)) then
    raise Exception.Create('Publisher source: wrong output header');
  FillChar(Expected, SizeOf(Expected), Ord('A') + Index);
  Remaining := BookBytes - Length(Header) - Length(BookFooter);
  while Remaining > 0 do
  begin
    Count := Remaining;
    if Count > SizeOf(Buffer) then Count := SizeOf(Buffer);
    Stream.ReadBuffer(Buffer, Count);
    if not CompareMem(@Buffer[0], @Expected[0], Count) then
      raise Exception.Create('Publisher source: output payload mismatch');
    Dec(Remaining, Count);
  end;
  Stream.ReadBuffer(Buffer, Length(BookFooter));
  if not CompareMem(@Buffer[0], PAnsiChar(BookFooter), Length(BookFooter)) then
    raise Exception.Create('Publisher source: stdout tail was lost');
end;

procedure RestoreEnvironment(const Name, Value: string);
begin
  if Value = '' then
    Winapi.Windows.SetEnvironmentVariable(PChar(Name), nil)
  else
    Winapi.Windows.SetEnvironmentVariable(PChar(Name), PChar(Value));
end;

procedure RunPublisherSourceSelfTestMode;
var
  Root, InputDirectory, ArchivePath, ToolPath, Name: string;
  SavedTemp, SavedTmp, OriginalTempPath: string;
  ID: TGUID;
  Arguments: TArray<string>;
  Books: TArray<TBookRecord>;
  Source: TPublisherSeriesSource;
  Archive: TMHLZip;
  Stream: TStream;
  Output: TMemoryStream;
  Summary: TJSONObject;
  Checks: TJSONArray;
  Transport: TMcpTransport;
  I, Calls, Count: Integer;
  CancelRequested, SawBatchFile, Aborted: Boolean;
  Watch: TStopwatch;

  procedure Check(const Caption: string; const Condition: Boolean);
  var
    Item: TJSONObject;
  begin
    if not Condition then
      raise Exception.Create('Publisher source: ' + Caption);
    Item := TJSONObject.Create;
    Item.AddPair('name', Caption);
    Item.AddPair('pass', TJSONBool.Create(True));
    Checks.AddElement(Item);
  end;

  function BatchDirectories: TArray<string>;
  begin
    Result := TDirectory.GetDirectories(Root, 'homelib-publisher-*');
  end;

begin
  if (ParamCount <> 1) or (ParamStr(1) <> '--publisher-source-selftest') then
    raise Exception.Create('Publisher source self-test takes no profile or path arguments');
  if Assigned(DMUser) then
    raise Exception.Create('Publisher source self-test requires an uninitialized profile');
  OriginalTempPath := IncludeTrailingPathDelimiter(ExpandFileName(TPath.GetTempPath));
  SavedTemp := GetEnvironmentVariable('TEMP');
  SavedTmp := GetEnvironmentVariable('TMP');
  CreateGUID(ID);
  Root := TPath.Combine(OriginalTempPath, 'homelib-source-selftest-' + GUIDToString(ID));
  TDirectory.CreateDirectory(Root);
  Summary := TJSONObject.Create;
  try
    Checks := TJSONArray.Create;
    Summary.AddPair('checks', Checks);
    // With no profile arguments the settings constructor does not copy an INI.
    // Do not call Init/LoadSettings/SaveSettings: no user database is involved.
    DMUser := TDMUser.Create(nil);
    Settings.ReadDir := Root;
    if not Winapi.Windows.SetEnvironmentVariable('TEMP', PChar(Root)) or
       not Winapi.Windows.SetEnvironmentVariable('TMP', PChar(Root)) then
      RaiseLastOSError;
    InputDirectory := TPath.Combine(Root, 'input');
    TDirectory.CreateDirectory(InputDirectory);
    ArchivePath := TPath.Combine(Root, 'source.7z');
    ToolPath := FindExternalTool('7zz.exe', '7zip');
    if ToolPath = '' then ToolPath := FindExternalTool('7za.exe', '7zip');
    if ToolPath = '' then ToolPath := FindExternalTool('7z.exe', '7zip');
    if ToolPath = '' then raise Exception.Create('7-Zip is required for this self-test');
    SetLength(Arguments, 9 + BookCount);
    Arguments[0] := 'a';
    Arguments[1] := '-t7z';
    Arguments[2] := '-mx=1';
    Arguments[3] := '-ms=on';
    Arguments[4] := '-mmt=1';
    Arguments[5] := '-y';
    Arguments[6] := '-bsp0';
    Arguments[7] := '--';
    Arguments[8] := ArchivePath;
    SetLength(Books, BookCount);
    for I := 0 to BookCount - 1 do
    begin
      Name := 'book' + IntToStr(I) + '.fb2';
      Arguments[9 + I] := TPath.Combine(InputDirectory, Name);
      WriteBook(Arguments[9 + I], I);
      Books[I].Clear;
      Books[I].CollectionRoot := Root;
      Books[I].Folder := 'source.7z';
      Books[I].FileName := ChangeFileExt(Name, '');
      Books[I].FileExt := '.fb2';
      Books[I].InsideNo := I;
      Books[I].LibID := IntToStr(I);
      Include(Books[I].BookProps, bpIsLocal);
    end;
    Output := TMemoryStream.Create;
    try
      RunExternalToolToStream(ToolPath, Arguments, Output);
    finally
      Output.Free;
    end;
    for I := 0 to BookCount - 1 do TFile.Delete(Arguments[9 + I]);
    TDirectory.Delete(InputDirectory);
    Check('solid fixture is four 20-MiB books in a compact archive',
      TFile.GetSize(ArchivePath) < 1024 * 1024);

    Source := TPublisherSeriesSource.Create(nil);
    try
      for I := 0 to BookCount - 1 do
      begin
        Source.SetUpcoming(Books, I);
        Stream := Source.OpenDescriptor(Books[I]);
        try
          CheckBook(Stream, I);
        finally
          Stream.Free;
        end;
      end;
      Check('64-MiB cap uses one three-book batch plus one single-entry fallback',
        Source.BatchCount = 1);
      Check('archive listing is reused across all four descriptors', Source.ArchiveOpenCount = 1);
      Check('all 80 MiB match the expected bytes including the final stdout tail', True);
    finally
      Source.Free;
    end;
    Check('completed batches leave no extraction directory', Length(BatchDirectories) = 0);

    Calls := 0;
    Archive := TMHLZip.Create(ArchivePath, True, False,
      function: Boolean
      begin
        Inc(Calls);
        Result := True;
      end);
    try
      Watch := TStopwatch.StartNew;
      Aborted := False;
      try
        Count := Archive.FileCount;
      except
        on E: EAbort do Aborted := True;
      end;
      Check('archive listing observes cancellation promptly',
        Aborted and (Calls > 0) and (Watch.ElapsedMilliseconds < 10000));
    finally
      Archive.Free;
    end;

    CancelRequested := False;
    Calls := 0;
    Archive := TMHLZip.Create(ArchivePath, True, False,
      function: Boolean
      begin
        Inc(Calls);
        Result := CancelRequested;
      end);
    try
      Count := Archive.FileCount;
      Check('single-entry cancellation fixture has all four entries', Count = BookCount);
      Calls := 0;
      CancelRequested := True;
      Output := TMemoryStream.Create;
      try
        Watch := TStopwatch.StartNew;
        Aborted := False;
        try
          Archive.ExtractToStream('book3.fb2', Output);
        except
          on E: EAbort do Aborted := True;
        end;
        Check('single-entry solid extraction observes cancellation promptly',
          Aborted and (Calls > 0) and (Watch.ElapsedMilliseconds < 10000));
      finally
        Output.Free;
      end;
    finally
      Archive.Free;
    end;

    CancelRequested := False;
    SawBatchFile := False;
    Source := TPublisherSeriesSource.Create(
      function: Boolean
      var
        Directory: string;
      begin
        if not CancelRequested then
          for Directory in TDirectory.GetDirectories(Root, 'homelib-publisher-*') do
            if Length(TDirectory.GetFiles(Directory, '*.fb2')) > 0 then
            begin
              SawBatchFile := True;
              CancelRequested := True;
              Break;
            end;
        Result := CancelRequested;
      end);
    try
      Source.SetUpcoming(Books, 0);
      Watch := TStopwatch.StartNew;
      Aborted := False;
      try
        Stream := Source.OpenDescriptor(Books[0]);
        Stream.Free;
      except
        on E: EAbort do Aborted := True;
      end;
      Check('batch extraction can be canceled after creating partial files',
        Aborted and SawBatchFile and (Watch.ElapsedMilliseconds < 10000));
      Check('canceled batch is not counted as completed', Source.BatchCount = 0);
      Check('canceled partial files are removed before fallback', Length(BatchDirectories) = 0);
    finally
      Source.Free;
    end;
    Check('canceled source disposal leaves no batch directory', Length(BatchDirectories) = 0);
    Transport := TMcpTransport.Create;
    try
      Transport.WriteMessage(Summary.ToJSON);
    finally
      Transport.Free;
    end;
  finally
    FreeAndNil(DMUser);
    RestoreEnvironment('TEMP', SavedTemp);
    RestoreEnvironment('TMP', SavedTmp);
    Summary.Free;
    if not StartsText(OriginalTempPath, ExpandFileName(Root)) or
       not StartsText('homelib-source-selftest-', ExtractFileName(Root)) then
      raise Exception.Create('Refusing cleanup outside the source self-test directory');
    TDirectory.Delete(Root, True);
  end;
end;

end.
