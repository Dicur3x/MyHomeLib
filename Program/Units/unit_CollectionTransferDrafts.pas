unit unit_CollectionTransferDrafts;

interface

uses System.SysUtils, System.Generics.Collections, Winapi.Windows;

type
  TTransferDrafts=class
  public
    class procedure Save(Lease:THandle; const Directory,DirectoryKey,CopiesKey:string;
      Files:TDictionary<string,string>); static;
    class procedure Ready(Lease:THandle); static;
    class procedure RecordEntry(Lease:THandle; const Name,Key:string; Directory:Boolean); static;
    class function CleanDirectory(const WorkRoot,Directory:string; const Cancelled:TFunc<Boolean>=nil):Boolean; static;
    class function CleanAbandoned(const WorkRoot:string; const Cancelled:TFunc<Boolean>=nil):Integer; static;
  end;

{$IFDEF MHL_TRANSFER_TEST}
var TransferDraftTestPoint:TProc<string,string>;
{$ENDIF}

implementation

uses System.Classes, System.IOUtils, System.JSON, System.Hash,
  unit_CollectionTransferPlan, unit_CollectionTransferCopy, unit_ZipMemberDeletion;

const Kind='HomeLibre disposable transfer preparation v1'; Prefix='collection-transfer-';
  MaxClaimBytes=1024*1024;
  MaxLeaseBytes=16*1024*1024;
  EntryKind='HomeLibre transfer draft entry v1'; Snapshots='catalogue-snapshots';

function FileKey(Handle:THandle; Directory:Boolean):string;
begin
  var Info:TByHandleFileInformation;
  if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
  if ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY<>0)<>Directory) or
    (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
    (not Directory and ((Info.nNumberOfLinks<>1) or (Info.dwFileAttributes and FILE_ATTRIBUTE_READONLY<>0))) or
    ((Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0)) then raise EReadError.Create('Рабочий объект переноса изменён.');
  Result:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
end;

function DraftGetInformation(Handle:THandle; InfoClass:Integer; Data:Pointer; Bytes:DWORD):BOOL;
  stdcall; external kernel32 name 'GetFileInformationByHandleEx';
function DraftSetInformation(Handle:THandle; InfoClass:Integer; Data:Pointer; Bytes:DWORD):BOOL;
  stdcall; external kernel32 name 'SetFileInformationByHandle';

procedure DefaultStream(Handle:THandle; Directory:Boolean);
begin
  var Buffer:array[0..63] of UInt64; FillChar(Buffer,SizeOf(Buffer),0);
  if not DraftGetInformation(Handle,7,@Buffer[0],SizeOf(Buffer)) then
  begin
    var Code:=GetLastError;
    if Directory and (Code=ERROR_HANDLE_EOF) then Exit;
    RaiseLastOSError(Code);
  end;
  if Directory then raise EReadError.Create('В черновой папке появился дополнительный поток.');
  var Next,NameBytes:DWORD; Move(Buffer[0],Next,4); Move(PByte(@Buffer[0])[4],NameBytes,4);
  var Name:string;
  if (Next<>0) or (NameBytes<>14) then raise EReadError.Create('В черновом файле появился дополнительный поток.');
  SetString(Name,PWideChar(PByte(@Buffer[0])+24),7);
  if Name<>'::$DATA' then raise EReadError.Create('Неизвестный поток чернового файла.');
end;

function Hold(const Path,Expected:string; Directory:Boolean; ReadData:Boolean=False; NeedDelete:Boolean=True):THandle;
begin
  var Access:DWORD:=FILE_READ_ATTRIBUTES;
  if NeedDelete then Access:=Access or Winapi.Windows._DELETE;
  if ReadData then Access:=Access or GENERIC_READ;
  var Share:DWORD:=0; if Directory then Share:=FILE_SHARE_READ or FILE_SHARE_WRITE;
  Result:=CreateFile(PChar(DeletionNativePath(Path)),Access,Share,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Result=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    var Key:=FileKey(Result,Directory);
    if ((Expected<>'') and (Key<>Expected)) or
      not SameFileName(DeletionNativePath(TransferFinalHandlePath(Result)),DeletionNativePath(Path)) then
      raise EReadError.Create('Черновой объект заменён или перенаправлен.');
    if NeedDelete then DefaultStream(Result,Directory);
  except CloseHandle(Result); raise; end;
end;

procedure Point(const Stage,Directory:string);
begin
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferDraftTestPoint) then TransferDraftTestPoint(Stage,Directory);
{$ENDIF}
end;

procedure CheckEntryName(const Name:string; Directory:Boolean);
begin
  if Directory then
  begin
    if Name<>Snapshots then raise EReadError.Create('Неизвестная папка чернового снимка.');
  end
  else
  begin
    if not Name.StartsWith(Snapshots+'/') then raise EReadError.Create('Неизвестный путь чернового снимка.');
    var Leaf:=Copy(Name,Length(Snapshots)+2,MaxInt);
    if not Leaf.EndsWith('.hlc2') then raise EReadError.Create('Неизвестный файл чернового снимка.');
    var ID:=StringToGUID(Copy(Leaf,1,Length(Leaf)-5));
    if Leaf<>GUIDToString(ID)+'.hlc2' then raise EReadError.Create('Неверное имя чернового снимка.');
  end;
end;

class procedure TTransferDrafts.RecordEntry(Lease:THandle; const Name,Key:string; Directory:Boolean);
begin
  CheckEntryName(Name,Directory);
  if Length(Key)<>25 then raise EReadError.Create('Нет физического ключа чернового снимка.');
  var Data:=TJSONObject.Create;
  try
    Data.AddPair('kind',EntryKind); Data.AddPair('name',Name); Data.AddPair('key',Key);
    Data.AddPair('directory',TJSONBool.Create(Directory));
    var Raw:=Data.ToJSON; var Bytes:=TEncoding.UTF8.GetBytes(Raw); var Size:DWORD:=Length(Bytes);
    var Hash:=TEncoding.ASCII.GetBytes(THashSHA2.GetHashString(Raw));
    var Stream:=THandleStream.Create(Lease);
    try
      if (Stream.Size<69) or (Size>MaxClaimBytes) or (Stream.Size+Int64(Size)+68>MaxLeaseBytes) then
        raise EWriteError.Create('Слишком большая запись владения черновиком.');
      Stream.Seek(0,soEnd); Stream.WriteBuffer(Size,SizeOf(Size));
      Stream.WriteBuffer(Bytes[0],Size); Stream.WriteBuffer(Hash[0],Length(Hash));
      if not FlushFileBuffers(Lease) then RaiseLastOSError;
    finally Stream.Free; end;
  finally Data.Free; end;
end;

function ReadFrame(Stream:TStream):TJSONObject;
begin
  Result:=nil;
  var Size:DWORD;
  if Stream.Size-Stream.Position<4 then raise EReadError.Create('Неполная запись владения черновиком.');
  Stream.ReadBuffer(Size,SizeOf(Size));
  if (Size=0) or (Size>MaxClaimBytes) or (Stream.Size-Stream.Position<Int64(Size)+64) then
    raise EReadError.Create('Неверная запись владения черновиком.');
  var Bytes:TBytes; SetLength(Bytes,Size); Stream.ReadBuffer(Bytes[0],Size);
  var Raw:=TEncoding.UTF8.GetString(Bytes); SetLength(Bytes,64); Stream.ReadBuffer(Bytes[0],64);
  if TEncoding.ASCII.GetString(Bytes)<>THashSHA2.GetHashString(Raw) then
    raise EReadError.Create('Повреждена запись владения черновиком.');
  var Parsed:=TJSONObject.ParseJSONValue(Raw);
  if not (Parsed is TJSONObject) then begin Parsed.Free; raise EReadError.Create('Неверный формат владения черновиком.'); end;
  Result:=TJSONObject(Parsed);
end;

class procedure TTransferDrafts.Save(Lease:THandle; const Directory,DirectoryKey,CopiesKey:string;
  Files:TDictionary<string,string>);
begin
  var Data:=TJSONObject.Create;
  try
    Data.AddPair('kind',Kind); Data.AddPair('directory',Directory); Data.AddPair('directory_key',DirectoryKey);
    Data.AddPair('copies_key',CopiesKey); var Entries:=TJSONObject.Create; Data.AddPair('files',Entries);
    for var Name in ['lease','review.sqlite','state.sqlite'] do Entries.AddPair(Name,Files[Name]);
    var Raw:=Data.ToJSON; var Bytes:=TEncoding.UTF8.GetBytes(Raw); var Size:DWORD:=Length(Bytes);
    if Size>MaxClaimBytes then raise EWriteError.Create('Слишком большая запись владения черновиком.');
    var Hash:=TEncoding.ASCII.GetBytes(THashSHA2.GetHashString(Raw));
    var Stream:=THandleStream.Create(Lease);
    try
      Stream.Position:=0; Stream.WriteBuffer(Size,SizeOf(Size));
      Stream.WriteBuffer(Bytes[0],Length(Bytes)); Stream.WriteBuffer(Hash[0],Length(Hash));
      if not SetEndOfFile(Lease) or not FlushFileBuffers(Lease) then RaiseLastOSError;
    finally Stream.Free; end;
  finally Data.Free; end;
end;

class procedure TTransferDrafts.Ready(Lease:THandle);
begin
  // Any extra tail, including a torn ready write, makes the draft ineligible.
  // Flush this protection before the constructor may return to a payload caller.
  var Bytes:=TEncoding.ASCII.GetBytes('ready'); var Stream:=THandleStream.Create(Lease);
  try Stream.Seek(0,soEnd); Stream.WriteBuffer(Bytes[0],Length(Bytes));
    if not FlushFileBuffers(Lease) then RaiseLastOSError;
  finally Stream.Free; end;
end;

function RemoveDraft(const Directory:string; const Cancelled:TFunc<Boolean>):Boolean;
var Root,Lease,Copies,SnapshotRoot:THandle; Files:TList<THandle>; Data:TJSONObject;
  Stage,SnapshotKey:string; SnapshotFiles:TDictionary<string,string>;
  function ClaimedKey(Entries:TJSONObject; const Name:string):string;
  begin
    // Filenames contain dots; compare literal pairs, not JSON-path expressions.
    for var Pair in Entries do if Pair.JsonString.Value=Name then
    begin
      if not (Pair.JsonValue is TJSONString) then raise EReadError.Create('Повреждён ключ чернового файла.');
      Exit(Pair.JsonValue.Value);
    end;
    raise EReadError.Create('Нет ключа чернового файла.');
  end;
  procedure Stop;
  begin
    if Assigned(Cancelled) and Cancelled() then raise EAbort.Create('Уборка черновиков переноса остановлена.');
  end;
  procedure RemoveDirectoryHandle(var Handle:THandle);
  begin
    if Handle=0 then Exit;
    var DeleteFlag:Byte:=1;
    if not DraftSetInformation(Handle,4,@DeleteFlag,1) then RaiseLastOSError;
    CloseHandle(Handle); Handle:=0;
  end;
begin
  Result:=False; Root:=0; Lease:=0; Copies:=0; SnapshotRoot:=0; Data:=nil;
  Files:=TList<THandle>.Create; SnapshotFiles:=TDictionary<string,string>.Create; Stage:='directory';
  try
    try
      Root:=Hold(Directory,'',True); Stage:='lease';
      Lease:=Hold(TPath.Combine(Directory,'lease'),'',False,True); Stage:='claim-bytes';
      var Stream:=THandleStream.Create(Lease);
      try
        if (Stream.Size<69) or (Stream.Size>MaxLeaseBytes) then Exit;
        Data:=ReadFrame(Stream); Stage:='claim-fields';
        if (Data.Count<>5) or (Data.GetValue<string>('kind')<>Kind) or
          not SameFileName(Data.GetValue<string>('directory'),Directory) or
          (Data.GetValue<string>('directory_key')<>FileKey(Root,True)) then Exit;
        while Stream.Position<Stream.Size do
        begin
          Stop;
          var Entry:=ReadFrame(Stream);
          try
            if (Entry.Count<>4) or (Entry.GetValue<string>('kind')<>EntryKind) then Exit;
            var Name:=Entry.GetValue<string>('name'); var Key:=Entry.GetValue<string>('key');
            var IsDirectory:=Entry.GetValue<Boolean>('directory'); CheckEntryName(Name,IsDirectory);
            if Length(Key)<>25 then Exit;
            if IsDirectory then
            begin
              if SnapshotKey<>'' then Exit;
              SnapshotKey:=Key;
            end
            else
            begin
              if SnapshotKey='' then Exit;
              var Leaf:=Copy(Name,Length(Snapshots)+2,MaxInt);
              if SnapshotFiles.ContainsKey(Leaf) then Exit;
              SnapshotFiles.Add(Leaf,Key);
            end;
          finally Entry.Free; end;
        end;
      finally Stream.Free; end;
      var Expected:=Data.GetValue<TJSONObject>('files'); Stage:='claim-files';
      if (Expected=nil) or (Expected.Count<>3) or (ClaimedKey(Expected,'lease')<>FileKey(Lease,False)) then Exit;
      if (Length(ClaimedKey(Expected,'review.sqlite'))<>25) or (Length(ClaimedKey(Expected,'state.sqlite'))<>25) then Exit;
      // A previous cleanup may already have removed known objects. Missing
      // disposable entries are allowed; every present entry still needs its ID.
      Stage:='entries';
      for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(Directory)) do
      begin
        Stop; var Name:=ExtractFileName(Path);
        if Name='lease' then Continue;
        if Name='copies' then
        begin
          Copies:=Hold(Path,Data.GetValue<string>('copies_key'),True);
          if Length(TDirectory.GetFileSystemEntries(Path))<>0 then Exit;
        end
        else if Name=Snapshots then
        begin
          if SnapshotKey='' then Exit;
          SnapshotRoot:=Hold(Path,SnapshotKey,True);
          for var Child in TDirectory.GetFileSystemEntries(Path) do
          begin
            Stop; var Key:string;
            if not SnapshotFiles.TryGetValue(ExtractFileName(Child),Key) then Exit;
            Files.Add(Hold(Child,Key,False));
          end;
        end
        else
        begin
          if (Name<>'review.sqlite') and (Name<>'state.sqlite') then Exit;
          Files.Add(Hold(Path,ClaimedKey(Expected,Name),False));
        end;
      end;
      Stop; Point('draft-before-unlink',Directory);
      var DeleteFlag:Byte:=1; Stage:='unlink';
      while Files.Count>0 do
      begin
        var Handle:=Files.Last;
        var IsSnapshot:=SameFileName(IncludeTrailingPathDelimiter(ExtractFileDir(TransferFinalHandlePath(Handle))),
          IncludeTrailingPathDelimiter(TPath.Combine(Directory,Snapshots)));
        if not DraftSetInformation(Handle,4,@DeleteFlag,1) then RaiseLastOSError;
        CloseHandle(Handle); Files.Delete(Files.Count-1);
        Point('draft-file-unlinked',Directory);
        if IsSnapshot then Point('draft-snapshot-unlinked',Directory);
      end;
      RemoveDirectoryHandle(SnapshotRoot); RemoveDirectoryHandle(Copies);
      Point('draft-directories-unlinked',Directory);
      if not DraftSetInformation(Lease,4,@DeleteFlag,1) then RaiseLastOSError;
      CloseHandle(Lease); Lease:=0; Point('draft-claim-unlinked',Directory);
      if not DraftSetInformation(Root,4,@DeleteFlag,1) then RaiseLastOSError;
      Result:=True;
    except on E:EAbort do raise; on E:Exception do begin Result:=False; Stage:=Stage+' '+E.ClassName+': '+E.Message; end; end;
  finally
    if not Result then Point('draft-retained '+Stage,Directory);
    Data.Free; SnapshotFiles.Free; for var Handle in Files do CloseHandle(Handle); Files.Free;
    if Lease<>0 then CloseHandle(Lease); if Copies<>0 then CloseHandle(Copies);
    if SnapshotRoot<>0 then CloseHandle(SnapshotRoot); if Root<>0 then CloseHandle(Root);
  end;
end;

class function TTransferDrafts.CleanDirectory(const WorkRoot,Directory:string; const Cancelled:TFunc<Boolean>):Boolean;
begin
  Result:=False;
  var Base:=ExcludeTrailingPathDelimiter(TransferCanonicalDirectory(WorkRoot));
  var Candidate:=ExcludeTrailingPathDelimiter(ExpandFileName(Directory));
  if not SameFileName(DeletionNativePath(ExtractFileDir(Candidate)),DeletionNativePath(Base)) then Exit;
  var Name:=ExtractFileName(Candidate); var ID:TGUID;
  if not Name.StartsWith(Prefix) then Exit;
  try ID:=StringToGUID(Copy(Name,Length(Prefix)+1,MaxInt)); except on E:EConvertError do Exit; end;
  if Name<>Prefix+GUIDToString(ID) then Exit;
  var Guard:=Hold(Base,'',True,False,False);
  try Result:=RemoveDraft(Candidate,Cancelled); finally CloseHandle(Guard); end;
end;

class function TTransferDrafts.CleanAbandoned(const WorkRoot:string; const Cancelled:TFunc<Boolean>):Integer;
begin
  Result:=0; var Base:=ExcludeTrailingPathDelimiter(TransferCanonicalDirectory(WorkRoot));
  var Guard:=Hold(Base,'',True,False,False);
  try
    for var Path in TDirectory.GetDirectories(DeletionNativePath(Base),Prefix+'*') do
    begin
      if Assigned(Cancelled) and Cancelled() then raise EAbort.Create('Уборка черновиков переноса остановлена.');
      var Name:=ExtractFileName(Path); var ID:TGUID;
      try ID:=StringToGUID(Copy(Name,Length(Prefix)+1,MaxInt)); except on E:EConvertError do Continue; end;
      if Name<>Prefix+GUIDToString(ID) then Continue;
      if RemoveDraft(TPath.Combine(Base,Name),Cancelled) then Inc(Result);
    end;
  finally CloseHandle(Guard); end;
end;

end.
