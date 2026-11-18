unit unit_BookCompressionRestored;

interface

uses System.SysUtils, System.JSON;

// Materialize complete before/after streams through the same reader used by
// HomeLibre. All output lives in the owned preparation workspace.
function CaptureRestoredCompressionBooks(const Source, Candidate, Workspace: string;
  const Payloads, Books: TJSONArray; const OriginalImages, PreparedImages: TArray<string>;
  const Cancelled: TFunc<Boolean> = nil; const Progress: TProc<Int64,Int64> = nil): TJSONArray;

procedure CompleteExternalCompressionReport(const Source, Identity, Workspace: string;
  Captured: TJSONArray; Report: TJSONObject; BackupOriginals, PreviewImages: Boolean;
  const Worker: TFunc<TJSONObject,TJSONObject>; const Cancelled: TFunc<Boolean>;
  const Progress: TProc<Int64,Int64>);

implementation

uses System.Classes, System.IOUtils, System.Hash, Winapi.Windows,
  unit_MHLArchiveHelpers, unit_FLibraryCompat, unit_ZipMemberDeletion, unit_BookCompressionImages;

const MaxCompleteBook=Int64(512)*1024*1024;

type
  TCompressionBookStream = class(TMemoryStream)
  public
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

function TCompressionBookStream.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count<0) or (Position>MaxCompleteBook-Count) then
    raise EReadError.Create('Книга слишком велика для полной проверки сжатия.');
  Result:=inherited Write(Buffer,Count);
end;

function CaptureRestoredCompressionBooks(const Source, Candidate, Workspace: string;
  const Payloads, Books: TJSONArray; const OriginalImages, PreparedImages: TArray<string>;
  const Cancelled: TFunc<Boolean>; const Progress: TProc<Int64,Int64>): TJSONArray;
var BeforeArchive, AfterArchive: TMHLZip; Folder: string;
  procedure CheckStop;
  begin if Assigned(Cancelled) and Cancelled() then Abort; end;
  function CompleteBook(Archive: TMHLZip; const Member, ExpectedSHA256: string;
    const Images: TArray<string>): TStream;
  var Raw: TCompressionBookStream;
  begin
    CheckStop; Raw:=TCompressionBookStream.Create;
    try
      Archive.ExtractToStream(Member,Raw); Raw.Position:=0;
      if not SameText(THashSHA2.GetHashString(Raw),ExpectedSHA256) then
        raise EReadError.Create('Содержимое выбранной книги изменилось перед полной проверкой.');
      Raw.Position:=0;
      Result:=RestoreFLibraryBookWithImageSources(Source,Member,Raw,Images);
      if Result=nil then begin Result:=Raw; Raw:=nil; end;
      if Result.Size>MaxCompleteBook then
      begin Result.Free; raise EReadError.Create('Восстановленная книга превышает предел полной проверки.'); end;
    finally Raw.Free; end;
  end;
  function SaveBook(Stream: TStream; const Name: string): TJSONObject;
  var FileName, SystemRoot: string; Output: TFileStream; Available, Capacity: UInt64;
  begin
    CheckStop;
    SystemRoot:=GetEnvironmentVariable('SystemDrive')+'\';
    if not GetDiskFreeSpaceEx(PChar(SystemRoot),Available,Capacity,nil) then RaiseLastOSError;
    if Available<UInt64(8)*1024*1024*1024 then
      raise EWriteError.Create('На системном диске осталось меньше 8 ГБ. Проверка остановлена; исходники не изменены.');
    if not GetDiskFreeSpaceEx(PChar(DeletionNativePath(Folder)),Available,Capacity,nil) then RaiseLastOSError;
    if Available<UInt64(Stream.Size)+512*1024*1024 then
      raise EWriteError.Create('Недостаточно места для проверки полной книги. Исходники не изменены.');
    FileName:=TPath.Combine(Folder,Name); Stream.Position:=0;
    var Hash:=THashSHA2.GetHashString(Stream); Stream.Position:=0;
    Output:=TFileStream.Create(DeletionNativePath(FileName),fmCreate);
    try Output.CopyFrom(Stream,Stream.Size); finally Output.Free; end;
    Result:=TJSONObject.Create;
    Result.AddPair('path',FileName); Result.AddPair('sha256',Hash);
  end;
begin
  Result:=nil; BeforeArchive:=nil; AfterArchive:=nil;
  if not Assigned(Payloads) or not Assigned(Books) or (Payloads.Count=0) or
    (Payloads.Count<>Books.Count) or (Payloads.Count>100000) or
    (Length(OriginalImages)<>2) or (Length(PreparedImages)<>2) then
    raise EArgumentException.Create('Нужны полные сведения о выбранных книгах и источниках картинок.');
  Folder:=TPath.Combine(Workspace,'full-books');
  if not CreateDirectory(PChar(DeletionNativePath(Folder)),nil) then RaiseLastOSError;
  try
    try
    BeforeArchive:=TMHLZip.Create(DeletionNativePath(Source),True,False,Cancelled);
    if Candidate<>'' then AfterArchive:=TMHLZip.Create(DeletionNativePath(Candidate),True,False,Cancelled);
    Result:=TJSONArray.Create;
    for var I:=0 to Payloads.Count-1 do
    begin
      CheckStop;
      var Payload:=TJSONObject(Payloads.Items[I]); var Book:=TJSONObject(Books.Items[I]);
      var Member:=Payload.GetValue<string>('member');
      if (Member='') or (Book.GetValue<string>('member')<>Member) then
        raise EReadError.Create('Порядок выбранных книг изменился перед полной проверкой.');
      var Before:=CompleteBook(BeforeArchive,Member,Payload.GetValue<string>('input_sha256'),OriginalImages);
      try
        var Archive:=AfterArchive; if Archive=nil then Archive:=BeforeArchive;
        var After:=CompleteBook(Archive,Member,Payload.GetValue<string>('output_sha256'),PreparedImages);
        try
          var First:=SaveBook(Before,IntToStr(I)+'-before.bin');
          try
            var Second:=SaveBook(After,IntToStr(I)+'-after.bin');
            try
              var Item:=TJSONObject.Create; Result.AddElement(Item);
              Item.AddPair('member',Member); Item.AddPair('format',Book.GetValue<string>('format'));
              Item.AddPair('before',First.GetValue<string>('path'));
              Item.AddPair('before_sha256',First.GetValue<string>('sha256'));
              Item.AddPair('after',Second.GetValue<string>('path'));
              Item.AddPair('after_sha256',Second.GetValue<string>('sha256'));
              Item.AddPair('raw_changed',TJSONBool.Create(Payload.GetValue<string>('input_sha256')<>
                Payload.GetValue<string>('output_sha256')));
            finally Second.Free; end;
          finally First.Free; end;
        finally After.Free; end;
      finally Before.Free; end;
      if Assigned(Progress) then Progress(I+1,Payloads.Count);
    end;
  except
    Result.Free; Result:=nil; raise;
    end;
  finally
    AfterArchive.Free; BeforeArchive.Free;
  end;
end;

procedure CompleteExternalCompressionReport(const Source, Identity, Workspace: string;
  Captured: TJSONArray; Report: TJSONObject; BackupOriginals, PreviewImages: Boolean;
  const Worker: TFunc<TJSONObject,TJSONObject>; const Cancelled: TFunc<Boolean>;
  const Progress: TProc<Int64,Int64>);
var Dependencies, Files, Snapshots: TJSONArray; Receipt, Request, Measured: TJSONObject;
  Guards,PeerGuards: TArray<TFileStream>; OriginalImages, PreparedImages: TArray<string>;
  Candidate: string; InputBytes, OutputBytes: Int64;
  procedure Put(Data:TJSONObject; const Name:string; Value:TJSONValue);
  begin Data.RemovePair(Name).Free; Data.AddPair(Name,Value); end;
  procedure AddFile(const Path, Prepared, SourceIdentity, BeforeHash, AfterHash:string);
  begin
    var Item:=TJSONObject.Create; Files.AddElement(Item);
    Item.AddPair('source',Path); Item.AddPair('candidate',Prepared);
    Item.AddPair('source_identity',SourceIdentity);
    Item.AddPair('source_sha256',BeforeHash); Item.AddPair('result_sha256',AfterHash);
  end;
begin
  var External:=Report.GetValue<TJSONObject>('external_images',nil); if External=nil then Exit;
  if (Captured=nil) or (Captured.Count<>2) or not SameFileName(External.GetValue<string>('source'),Source) then
    raise EReadError.Create('Внешние изображения относятся к другому архиву.');
  Candidate:=Report.GetValue<string>('candidate','');
  Receipt:=Report.GetValue<TJSONObject>('receipt',nil);
  if Receipt=nil then Receipt:=Report.GetValue<TJSONObject>('inspection_receipt');
  if Receipt=nil then raise EReadError.Create('Нет описания результата сжатия книг.');
  Dependencies:=Captured.Clone as TJSONArray; Files:=TJSONArray.Create; Snapshots:=nil;
  SetLength(OriginalImages,2); SetLength(PreparedImages,2); Guards:=nil;
  try
    InputBytes:=Report.GetValue<Int64>('input_bytes'); OutputBytes:=Report.GetValue<Int64>('output_bytes');
    if Candidate<>'' then AddFile(Source,Candidate,Identity,Report.GetValue<string>('source_sha256'),
      Report.GetValue<string>('result_sha256'));
    var Found:=0;
    for var I:=0 to 1 do
    begin
      var Dep:=Dependencies.Items[I] as TJSONObject;
      var Path:=Dep.GetValue<string>('path'); var Kind:=Dep.GetValue<string>('kind');
      OriginalImages[I]:=Path; PreparedImages[I]:=Path;
      if Path='' then Continue;
      var Witness:TJSONObject:=nil;
      for var Value in External.GetValue<TJSONArray>('dependencies') do
        if Value.GetValue<string>('kind')=Kind then
        begin
          if Witness<>nil then raise EReadError.Create('Повторный источник картинок.');
          Witness:=Value as TJSONObject;
        end;
      if (Witness=nil) or not SameFileName(Witness.GetValue<string>('path'),Path) then
        raise EReadError.Create('Обработчик использовал другие внешние изображения.');
      Inc(Found);
      var BeforeHash:=Witness.GetValue<string>('sha256'); var AfterHash:=BeforeHash;
      for var Value in External.GetValue<TJSONArray>('archives') do
      begin
        var Archive:=Value as TJSONObject;
        if Archive.GetValue<string>('kind')<>Kind then Continue;
        if not SameFileName(Archive.GetValue<string>('source'),Path) or
          (Archive.GetValue<string>('source_sha256')<>BeforeHash) then
          raise EReadError.Create('Архив изображений не совпал с исходным.');
        var Prepared:=Archive.GetValue<string>('candidate','');
        if Prepared='' then Continue;
        var Expected:=TPath.Combine(ExtractFileDir(Workspace),'external-images\prepared-'+Kind+'.bin');
        if not SameFileName(Prepared,Expected) then raise EReadError.Create('Неверный путь подготовленных картинок.');
        var Old:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
        try
          var NewFile:=TFileStream.Create(DeletionNativePath(Prepared),fmOpenRead or fmShareDenyWrite);
          try
            if (NewFile.Size<=0) or (NewFile.Size>=Old.Size) then
              raise EReadError.Create('Подготовленный архив картинок не стал меньше.');
            AfterHash:=Archive.GetValue<string>('result_sha256');
            if not SameText(THashSHA2.GetHashString(NewFile),AfterHash) then
              raise EReadError.Create('Подготовленные картинки изменились.');
            Inc(InputBytes,Old.Size); Inc(OutputBytes,NewFile.Size);
          finally NewFile.Free; end;
        finally Old.Free; end;
        PreparedImages[I]:=Prepared;
        AddFile(Path,Prepared,Dep.GetValue<string>('source_identity'),BeforeHash,AfterHash);
      end;
      Dep.AddPair('source_sha256',BeforeHash); Dep.AddPair('result_sha256',AfterHash);
    end;
    if Found<>External.GetValue<TJSONArray>('dependencies').Count then
      raise EReadError.Create('В отчёте посторонние источники изображений.');
    if External.GetValue('peer_sources') is TJSONArray then
    begin
      var Peers:=External.GetValue<TJSONArray>('peer_sources');
      if Receipt.GetValue('image_peer_archives')<>nil then raise EReadError.Create('Повторная привязка соседних архивов.');
      PeerGuards:=GuardCompressionPeerSources(Source,Peers,Cancelled);
      Receipt.AddPair('image_peer_archives',Peers.Clone as TJSONArray);
    end;
    Guards:=GuardCompressionImageSources(Source,Dependencies,nil);
    if (Receipt.GetValue('group_files')<>nil) or (Receipt.GetValue('image_dependencies')<>nil) then
      raise EReadError.Create('Обработчик подменил привязку связанных архивов.');
    Snapshots:=CaptureRestoredCompressionBooks(Source,Candidate,Workspace,
      Receipt.GetValue<TJSONArray>('payloads'),Report.GetValue<TJSONArray>('books'),
      OriginalImages,PreparedImages,Cancelled,Progress);
    Request:=TJSONObject.Create;
    try
      Request.AddPair('version',TJSONNumber.Create(1)); Request.AddPair('kind','HomeLibre restored book validation');
      Request.AddPair('source',Source); Request.AddPair('source_sha256',Report.GetValue<string>('source_sha256'));
      Request.AddPair('workspace',Workspace); Request.AddPair('books',Snapshots.Clone as TJSONArray);
      Request.AddPair('backup_originals',TJSONBool.Create(BackupOriginals and (Files.Count>0)));
      Request.AddPair('preview_images',TJSONBool.Create(PreviewImages and (Files.Count>0)));
      Measured:=Worker(Request);
      try
        var Full:=Measured.GetValue<TJSONArray>('restored_payloads');
        var Payloads:=Receipt.GetValue<TJSONArray>('payloads');
        if Full.Count<>Payloads.Count then raise EReadError.Create('Измерены не все полные книги.');
        for var I:=0 to Full.Count-1 do
        begin
          var Item:=Full.Items[I] as TJSONObject;
          if (Item.GetValue<string>('member')<>Payloads.Items[I].GetValue<string>('member')) or
            (Item.GetValue<string>('input_sha256')<>Snapshots.Items[I].GetValue<string>('before_sha256')) or
            (Item.GetValue<string>('output_sha256')<>Snapshots.Items[I].GetValue<string>('after_sha256')) then
            raise EReadError.Create('Измерение не соответствует восстановленной книге.');
          (Payloads.Items[I] as TJSONObject).AddPair('restored',Item.Clone as TJSONObject);
        end;
        for var Name in ['originals','preview'] do
          if Measured.GetValue(Name) is TJSONObject then Put(Report,Name,Measured.GetValue(Name).Clone as TJSONValue);
      finally Measured.Free; end;
    finally Request.Free; end;
    Receipt.AddPair('image_dependencies',Dependencies); Dependencies:=nil;
    if Files.Count>0 then begin Receipt.AddPair('group_files',Files); Files:=nil; end;
    Put(Report,'input_bytes',TJSONNumber.Create(InputBytes)); Put(Report,'output_bytes',TJSONNumber.Create(OutputBytes));
  finally
    for var PeerGuard in PeerGuards do PeerGuard.Free;
    for var Guard in Guards do Guard.Free;
    Snapshots.Free; Files.Free; Dependencies.Free;
  end;
end;

end.
