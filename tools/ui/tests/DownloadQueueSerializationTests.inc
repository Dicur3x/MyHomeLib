// Native queue node wire-format gate. Only this isolated G runtime is used.
// Callbacks come from the actual controller; no catalog or live queue is edited.

function DQSSameRecord(const A,B: TDownloadData): Boolean;
begin
  Result:=A.BookKey.IsSameAs(B.BookKey) and (A.Author=B.Author) and (A.Title=B.Title) and
    (A.Size=B.Size) and (A.FileName=B.FileName) and (A.URL=B.URL) and (A.State=B.State) and
    (A.HasExpectedIdentity=B.HasExpectedIdentity) and (A.ExpectedLibID=B.ExpectedLibID) and
    (A.ExpectedPhysicalIdentity=B.ExpectedPhysicalIdentity);
end;

function DQSBuildRawNode(const Value: TDownloadData; LegacyOdd: Boolean): TMemoryStream;
var ZeroByte: Byte; ZeroWord: Word;

  procedure PutString(const Text: string);
  var Count: Integer;
  begin
    Count:=Length(Text)*SizeOf(Char)+SizeOf(Char);
    if LegacyOdd then Dec(Count);
    Result.WriteBuffer(Count,SizeOf(Count));
    if Text<>'' then Result.WriteBuffer(PChar(Text)^,Length(Text)*SizeOf(Char));
    if LegacyOdd then Result.WriteBuffer(ZeroByte,SizeOf(ZeroByte))
    else Result.WriteBuffer(ZeroWord,SizeOf(ZeroWord));
  end;

begin
  Result:=TMemoryStream.Create; ZeroByte:=0; ZeroWord:=0;
  try
    Result.WriteBuffer(Value.BookKey,SizeOf(Value.BookKey));
    PutString(Value.Title); PutString(Value.Author);
    Result.WriteBuffer(Value.Size,SizeOf(Value.Size));
    PutString(Value.FileName); PutString(Value.URL);
    Result.WriteBuffer(Value.State,SizeOf(Value.State));
    Result.Position:=0;
  except Result.Free; raise; end;
end;

procedure TestDownloadQueueSerialization;
var Tree: TBookTree; Controller: TTreeController; Node: PVirtualNode; Data: PDownloadData;
  Original, Expected, ProtectedValue: TDownloadData;
  Raw, Saved, Framed: TMemoryStream; Root: string; PassedBad: Integer;

  procedure LoadExactly(Stream: TStream; const Value: TDownloadData; const Scenario: string);
  begin
    Data^:=ProtectedValue;
    Tree.OnLoadNode(Tree,Node,Stream);
    Require(DQSSameRecord(Data^,Value),Scenario+': actual queue callback changed a wire field');
  end;

  procedure RejectWithoutMutation(Stream: TStream; const Scenario: string);
  var Rejected: Boolean;
  begin
    Data^:=ProtectedValue; Rejected:=False;
    try Tree.OnLoadNode(Tree,Node,Stream);
    except on E: EReadError do Rejected:=True; end;
    Require(Rejected,Scenario+': malformed queue node was accepted');
    Require(DQSSameRecord(Data^,ProtectedValue),Scenario+': failed parse published partial queue data');
    Inc(PassedBad);
  end;

  procedure CheckNewEvenLayout(Stream: TMemoryStream);
  var Key: TBookKey; Count, Size: Integer; State: Cardinal; Bytes: TBytes;
  begin
    Stream.Position:=0; Stream.ReadBuffer(Key,SizeOf(Key));
    Require(Key.IsSameAs(Expected.BookKey),'New queue writer changed the original key layout');
    for var I:=0 to 3 do
    begin
      Stream.ReadBuffer(Count,SizeOf(Count));
      Require((Count>=2) and not Odd(Count),'New queue writer emitted an odd or missing UTF16 terminator');
      SetLength(Bytes,Count); Stream.ReadBuffer(Bytes[0],Count);
      Require((Bytes[Count-1]=0) and (Bytes[Count-2]=0),'New queue writer did not emit exactly a complete terminal code unit');
      if I=1 then Stream.ReadBuffer(Size,SizeOf(Size));
    end;
    State:=0; Stream.ReadBuffer(State,SizeOf(TDownloadState));
    Require((State=Ord(Expected.State)) and (Stream.Position=Stream.Size),
      'New queue writer changed scalar ordering or appended unrelated record bytes');
  end;

  procedure PutInteger(Stream: TMemoryStream; At: Int64; Value: Integer);
  begin Stream.Position:=At; Stream.WriteBuffer(Value,SizeOf(Value)); Stream.Position:=0; end;

  function MakeFrame(Payload: TMemoryStream; ChunkSize: Integer; TailBytes: Integer): TMemoryStream;
  var Header: TChunkHeader; ByteValue: Byte;
  begin
    Result:=TMemoryStream.Create;
    try
      Header.ChunkType:=UserChunk; Header.ChunkSize:=ChunkSize;
      Result.WriteBuffer(Header,SizeOf(Header));
      Payload.Position:=0; Result.CopyFrom(Payload,Payload.Size);
      ByteValue:=$A7;
      for var I:=1 to TailBytes do Result.WriteBuffer(ByteValue,1);
      Result.Position:=SizeOf(Header);
    except Result.Free; raise; end;
  end;

  function Envelope(const URL,LibID,Physical: string): string;
  var JSON: TJSONObject;
  begin
    JSON:=TJSONObject.Create;
    try
      JSON.AddPair('url',URL); JSON.AddPair('libid',LibID); JSON.AddPair('physical',Physical);
      Result:='#MHL-download-identity-v1#'+JSON.ToJSON;
    finally JSON.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Require(TPath.GetFullPath(Settings.AppPath).StartsWith('G:\',True),'Queue serializer gate must remain on G');
  Root:=TPath.Combine(Settings.AppPath,'queue-serialization-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  Tree:=TBookTree.Create(nil); Controller:=nil; Raw:=nil; Saved:=nil; Framed:=nil; PassedBad:=0;
  try
    Tree.Parent:=frmMain; Tree.Visible:=False;
    Controller:=TTreeController.Create(SystemDB); Controller.ConnectDownloadTree(Tree);
    Node:=Tree.AddChild(nil); Data:=Tree.GetNodeData(Node);
    Require(Assigned(Data) and Assigned(Tree.OnLoadNode) and Assigned(Tree.OnSaveNode),
      'Actual queue serialization callbacks are missing');
    Original:=Default(TDownloadData); Original.BookKey:=CreateBookKey(42,3);
    Original.Title:='Своя книга ё, ї, ў '+Char($D83E)+Char($DDEA)+#0+'tail'+#0;
    Original.Author:='Власны аўтар'; Original.Size:=1234;
    Original.FileName:=TPath.Combine(Root,'исходная-книга.fb2');
    Original.URL:='http://127.0.0.1:9/own?name='+#0+'keep'+#0; Original.State:=dsError;
    ProtectedValue:=Original; ProtectedValue.BookKey:=CreateBookKey(77,8);
    ProtectedValue.Title:='Protected original node'; ProtectedValue.Author:='Protected author';
    ProtectedValue.FileName:='Protected path'; ProtectedValue.URL:='Protected URL';
    ProtectedValue.Size:=77; ProtectedValue.State:=dsWait;
    ProtectedValue.HasExpectedIdentity:=True; ProtectedValue.ExpectedLibID:='Protected ID';
    ProtectedValue.ExpectedPhysicalIdentity:='Protected physical';

    for var LegacyOdd in TArray<Boolean>.Create(True,False) do
    begin
      Expected:=Original; Raw:=DQSBuildRawNode(Expected,LegacyOdd);
      try
        LoadExactly(Raw,Expected,'Unicode/NUL node legacyOdd='+IntToStr(Ord(LegacyOdd)));
        Require(Raw.Position=Raw.Size,'Direct queue node did not consume exactly its own payload');
        Saved:=TMemoryStream.Create;
        try
          Tree.OnSaveNode(Tree,Node,Saved); CheckNewEvenLayout(Saved);
          Saved.SaveToFile(TPath.Combine(Root,'unicode-'+IntToStr(Ord(LegacyOdd))+'-new-even.bin'));
          Saved.Position:=0; LoadExactly(Saved,Expected,'New even queue re-read');
        finally FreeAndNil(Saved); end;
        Framed:=MakeFrame(Raw,Raw.Size,32);
        try
          LoadExactly(Framed,Expected,'Bounded real UserChunk with following bytes');
          Require(Framed.Position=SizeOf(TChunkHeader)+Raw.Size,'Queue parser consumed another user/header chunk');
        finally FreeAndNil(Framed); end;
      finally FreeAndNil(Raw); end;
      Expected:=Original; Expected.Title:=''; Expected.Author:=''; Expected.FileName:=''; Expected.URL:='';
      Raw:=DQSBuildRawNode(Expected,LegacyOdd);
      try LoadExactly(Raw,Expected,'Empty queue strings legacyOdd='+IntToStr(Ord(LegacyOdd)));
      finally FreeAndNil(Raw); end;
    end;
    Writeln('PASS queue serializer legacy odd and new even preserve exact Unicode, emoji, embedded/trailing NUL and empty fields'); Flush(Output);

    Expected:=Original; Expected.HasExpectedIdentity:=True;
    Expected.ExpectedLibID:='flibusta:42'; Expected.ExpectedPhysicalIdentity:=Original.FileName;
    var Wire:=Original; Wire.URL:=Envelope(Expected.URL,Expected.ExpectedLibID,Expected.ExpectedPhysicalIdentity);
    for var LegacyOdd in TArray<Boolean>.Create(True,False) do
    begin
      Raw:=DQSBuildRawNode(Wire,LegacyOdd);
      try
        LoadExactly(Raw,Expected,'Typed v1 envelope');
        Saved:=TMemoryStream.Create;
        try Tree.OnSaveNode(Tree,Node,Saved); Saved.Position:=0; LoadExactly(Saved,Expected,'Typed envelope newwriter reopen');
        finally FreeAndNil(Saved); end;
      finally FreeAndNil(Raw); end;
    end;
    Writeln('PASS queue serializer restores versioned identity and its exact original logical URL'); Flush(Output);

    for var BadURL in TArray<string>.Create(
      '#MHL-download-identity-v1#{bad', '#MHL-download-identity-v1#{}',
      '#MHL-download-identity-v1#{"url":"own","libid":"42"}',
      '#MHL-download-identity-v1#{"url":"own","libid":"42","physical":99}',
      '#MHL-download-identity-v1#{"url":"own","libid":"42","physical":"path","future":"retain"}',
      '#MHL-download-identity-v1#{"url":"own","libid":"42","physical":"path"}garbage',
      '#MHL-download-identity-v2#{"url":"future","identity":"preserve raw"}') do
    begin
      Wire:=Original; Wire.URL:=BadURL; Expected:=Wire;
      Expected.HasExpectedIdentity:=True; Expected.ExpectedLibID:=''; Expected.ExpectedPhysicalIdentity:='';
      Raw:=DQSBuildRawNode(Wire,True);
      try
        LoadExactly(Raw,Expected,'Malformed/future envelope retained fail-closed');
        Saved:=TMemoryStream.Create;
        try
          Tree.OnSaveNode(Tree,Node,Saved); Saved.Position:=0;
          LoadExactly(Saved,Expected,'Malformed raw envelope survives save/reopen');
        finally FreeAndNil(Saved); end;
      finally FreeAndNil(Raw); end;
    end;
    Writeln('PASS queue serializer malformed/future identity remains fail-closed while retaining every raw envelope byte through save/reopen'); Flush(Output);

    Raw:=DQSBuildRawNode(Original,True);
    try
      var SourceBytes: TBytes; SetLength(SourceBytes,Raw.Size);
      if Length(SourceBytes)>0 then Move(Raw.Memory^,SourceBytes[0],Length(SourceBytes));
      for var Cut:=0 to Length(SourceBytes)-1 do
      begin
        Saved:=TMemoryStream.Create;
        try
          if Cut>0 then Saved.WriteBuffer(SourceBytes[0],Cut);
          Saved.Position:=0; RejectWithoutMutation(Saved,'Truncated byte '+IntToStr(Cut));
        finally FreeAndNil(Saved); end;
      end;
      for var BadSize in TArray<Integer>.Create(-1,0,High(Integer)) do
      begin
        Saved:=TMemoryStream.Create;
        try
          Saved.WriteBuffer(SourceBytes[0],Length(SourceBytes)); PutInteger(Saved,SizeOf(TBookKey),BadSize);
          RejectWithoutMutation(Saved,'Negative/empty/oversize string length');
        finally FreeAndNil(Saved); end;
      end;
      Saved:=TMemoryStream.Create;
      try
        Saved.WriteBuffer(SourceBytes[0],Length(SourceBytes));
        Saved.Position:=SizeOf(TBookKey)+SizeOf(Integer)+Length(Original.Title)*SizeOf(Char);
        var BadTerminal: Byte:=$7F; Saved.WriteBuffer(BadTerminal,1); Saved.Position:=0;
        RejectWithoutMutation(Saved,'Legacy missing one-byte terminator');
      finally FreeAndNil(Saved); end;
      Saved:=TMemoryStream.Create;
      try
        Saved.WriteBuffer(SourceBytes[0],Length(SourceBytes)); Saved.Position:=Saved.Size-SizeOf(TDownloadState);
        var BadState: Cardinal:=255; Saved.WriteBuffer(BadState,SizeOf(TDownloadState)); Saved.Position:=0;
        RejectWithoutMutation(Saved,'Invalid serialized state enum');
      finally FreeAndNil(Saved); end;
      Framed:=MakeFrame(Raw,Raw.Size-1,1024);
      try RejectWithoutMutation(Framed,'Truncated UserChunk with following valid stream bytes');
      finally FreeAndNil(Framed); end;
      Framed:=MakeFrame(Raw,-1,32);
      try RejectWithoutMutation(Framed,'Negative UserChunk');
      finally FreeAndNil(Framed); end;
      Framed:=MakeFrame(Raw,Raw.Size+1024,0);
      try RejectWithoutMutation(Framed,'UserChunk extends beyond file');
      finally FreeAndNil(Framed); end;
      Saved:=TMemoryStream.Create;
      try
        Saved.WriteBuffer(SourceBytes[0],Length(SourceBytes)); PutInteger(Saved,SizeOf(TBookKey),Length(SourceBytes)+16);
        Framed:=MakeFrame(Saved,Saved.Size,1024);
        try RejectWithoutMutation(Framed,'String length crosses UserChunk despite available next-chunk bytes');
        finally FreeAndNil(Framed); end;
      finally FreeAndNil(Saved); end;
    finally FreeAndNil(Raw); end;
    Raw:=DQSBuildRawNode(Original,False);
    try
      Raw.Position:=SizeOf(TBookKey)+SizeOf(Integer)+Length(Original.Title)*SizeOf(Char);
      var BadTerminalWord: Word:=$007F; Raw.WriteBuffer(BadTerminalWord,SizeOf(BadTerminalWord)); Raw.Position:=0;
      RejectWithoutMutation(Raw,'New even missing complete UTF16 terminator');
    finally FreeAndNil(Raw); end;
    Data^:=Original; Data^.Title:=StringOfChar('x',2*1024*1024);
    Saved:=TMemoryStream.Create;
    try
      var Rejected:=False;
      try Tree.OnSaveNode(Tree,Node,Saved);
      except on E: EWriteError do Rejected:=True; end;
      Require(Rejected,'New queue writer accepted a string exceeding its bounded UTF16 wire size');
      Require(Data^.Title=StringOfChar('x',2*1024*1024),'Queue writer changed an input field while rejecting its size');
    finally FreeAndNil(Saved); end;
    Require(PassedBad>100,'Queue serializer malformed/truncation gate did not exercise its complete byte range');
    Writeln('PASS queue serializer rejects truncation, negative/oversize lengths, missing terminators, invalid enum and UserChunk crossing without publishing partial data; cases=',PassedBad); Flush(Output);
  finally
    Framed.Free; Saved.Free; Raw.Free;
    Tree.Free; Controller.Free;
  end;
end;
