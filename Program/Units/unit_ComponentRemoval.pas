unit unit_ComponentRemoval;

interface

uses System.SysUtils, unit_ProgramUpdateInstaller;

type
  TComponentRemovalDisposition = (crRemove, crMissing, crKeepCore, crKeepSettings,
    crKeepShared, crKeepChanged);
  TComponentRemovalFile = record
    ComponentID: string;
    FileInfo: TUpdateFile;
    Disposition: TComponentRemovalDisposition;
    Reason: string;
  end;
  TComponentRemovalPlan = record
    AppPath: string;
    IDs, ManifestSources, Blockers, Warnings: TArray<string>;
    Files: TArray<TComponentRemovalFile>;
    Bytes: Int64;
    Fingerprint: string;
    function CanRemove: Boolean;
  end;

// The plan is a snapshot. The executor must rebuild and compare it before
// changing files, since another instance may have installed a shared module.
function BuildComponentRemovalPlan(const AppPath: string; const IDs: TArray<string>;
  const ManifestSources: TArray<string> = nil; const IsCanceled: TFunc<Boolean> = nil): TComponentRemovalPlan;
function ComponentRemovalCoreFile(const Name: string): Boolean;
function ExecuteComponentRemovalPlan(const Plan: TComponentRemovalPlan; FailAfter: Integer = -1;
  const IsCanceled: TFunc<Boolean> = nil): string;
function RecoverComponentRemovals(const AppPath: string): TArray<string>;

implementation

uses System.IOUtils, System.Hash, System.JSON, System.Classes, Winapi.Windows, System.Generics.Collections,
  System.Generics.Defaults, unit_ComponentUpdates;

function TComponentRemovalPlan.CanRemove: Boolean;
begin Result:=(Length(IDs)>0) and (Length(Blockers)=0); end;

function ComponentRemovalCoreFile(const Name: string): Boolean;
begin
  Result:=SameText(Name,'HomeLibRu.exe') or SameText(Name,'HomeLibRuUpdater.exe') or
    SameText(Name,'sqlite3.dll') or SameText(Name,'LICENSE') or SameText(Name,'NOTICE') or
    Name.StartsWith('tools/fonts/',True);
end;

function BuildComponentRemovalPlan(const AppPath: string; const IDs: TArray<string>;
  const ManifestSources: TArray<string>; const IsCanceled: TFunc<Boolean>): TComponentRemovalPlan;
var Requested: TDictionary<string,Boolean>; Names: TDictionary<string,Integer>; Retained: TDictionary<string,string>;
  Item: TComponentRemovalFile; Files: TUpdateFiles; PathName, Source, ID, ErrorText: string;
  Fingerprint: TStringBuilder;
  procedure Block(const Text: string);
  begin Result.Blockers:=Result.Blockers+TArray<string>.Create(Text); end;
  function Title(const Value: string): string;
  begin
    Result:=Value;
    for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
      if UPDATE_COMPONENTS[I].ID=Value then Exit(ComponentTitle(I));
  end;
  function Selected(const Value: string): Boolean;
  begin Result:=Requested.ContainsKey(Value); end;
  procedure AddCandidate(const Value: TComponentRemovalFile);
  var Index: Integer;
  begin
    if Names.TryGetValue(Value.FileInfo.Name,Index) then
    begin
      // Two selected components can own different historical versions of a
      // shared file. A match against either selected verified inventory proves
      // ownership, unless a retained module/core/user setting still needs it.
      if (Result.Files[Index].Disposition=crKeepChanged) and (Value.Disposition=crRemove) then
      begin Result.Files[Index]:=Value; Inc(Result.Bytes,Value.FileInfo.Size); end;
      Exit;
    end;
    Names.Add(Value.FileInfo.Name,Length(Result.Files));
    Result.Files:=Result.Files+TArray<TComponentRemovalFile>.Create(Value);
    if Value.Disposition=crRemove then Inc(Result.Bytes,Value.FileInfo.Size);
  end;
begin
  Result:=Default(TComponentRemovalPlan);
  AssertUpdatePath(AppPath); Result.AppPath:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(AppPath));
  if not FileExists(CheckedUpdateChildPath(AppPath,'HomeLibRu.exe')) and
    not FileExists(CheckedUpdateChildPath(AppPath,'HomeLibReader.exe')) then
    raise Exception.Create('В выбранной папке нет HomeLibre или HomeLibre Reader.');
  Result.ManifestSources:=Copy(ManifestSources);
  Result.ManifestSources:=Result.ManifestSources+TArray<string>.Create(
    CheckedUpdateChildPath(AppPath,UPDATE_MANIFEST));
  Requested:=TDictionary<string,Boolean>.Create(TIStringComparer.Ordinal);
  Names:=TDictionary<string,Integer>.Create(TIStringComparer.Ordinal);
  Retained:=TDictionary<string,string>.Create(TIStringComparer.Ordinal);
  Fingerprint:=TStringBuilder.Create;
  try
    for ID in IDs do
    begin
      if not IsOptionalComponent(ID) then
      begin Block('Этот компонент нужен для работы программы: '+Title(ID)); Continue; end;
      if Requested.ContainsKey(ID) then Continue;
      if ComponentFileName(ID)='' then begin Block('Неизвестный компонент: '+ID); Continue; end;
      Requested.Add(ID,True); Result.IDs:=Result.IDs+TArray<string>.Create(ID);
    end;
    // Retain shared paths even for older installations without receipts. Only
    // the selected component's explicit inventory can ever nominate removals.
    for var Component in UPDATE_COMPONENTS do if not Selected(Component.ID) and
      (FileExists(CheckedUpdateChildPath(AppPath,ComponentFileName(Component.ID))) or
       FileExists(CheckedUpdateChildPath(AppPath,ComponentReceiptName(Component.ID)))) then
      Retained.AddOrSetValue(Component.ID,Title(Component.ID));
    for ID in Result.IDs do
    begin
      if Assigned(IsCanceled) and IsCanceled() then Abort;
      Files:=nil; ErrorText:='';
      try Files:=InstalledComponentFiles(AppPath,ID);
      except on E: Exception do ErrorText:=E.Message; end;
      if Length(Files)=0 then
        for Source in Result.ManifestSources do
        begin
          try Files:=ComponentFilesFromManifest(Source,ID);
          except on E: Exception do ErrorText:=E.Message; end;
          if Length(Files)>0 then Break;
        end;
      if Length(Files)=0 then
      begin
        Block('Для «'+Title(ID)+'» нет проверенного списка файлов. Нужно получить пакет установленной версии; переустановка не требуется. '+ErrorText);
        Continue;
      end;
      for var Info in Files do
      begin
        if Assigned(IsCanceled) and IsCanceled() then Abort;
        Item:=Default(TComponentRemovalFile); Item.ComponentID:=ID; Item.FileInfo:=Info;
        PathName:=CheckedUpdateChildPath(AppPath,Info.Name);
        if ComponentRemovalCoreFile(Info.Name) then
        begin Item.Disposition:=crKeepCore; Item.Reason:='Нужен основной программе'; end
        else if SameText(Info.Name,'Readers/AlReader/$savevtut.ini') then
        begin Item.Disposition:=crKeepSettings; Item.Reason:='Настройки пользователя'; end
        else
        begin
          Item.Disposition:=crRemove;
          for var Other in Retained do if SafeComponentFile(Other.Key,Info.Name) then
          begin Item.Disposition:=crKeepShared; Item.Reason:='Нужен «'+Other.Value+'»'; Break; end;
          if not FileExists(PathName) then
          begin Item.Disposition:=crMissing; Item.Reason:='Файл уже отсутствует'; end
          else if Item.Disposition=crRemove then
          begin
            if (TFile.GetSize(PathName)<>Info.Size) or not SameText(UpdateSHA256(PathName),Info.SHA256) then
            begin Item.Disposition:=crKeepChanged; Item.Reason:='Файл изменён после установки'; end;
          end;
        end;
        if SameText(Info.Name,ComponentFileName(ID)) and
          (Item.Disposition in [crKeepShared,crKeepChanged]) then
          Block('Нельзя удалить «'+Title(ID)+'»: '+Item.Reason+'. '+Info.Name);
        AddCandidate(Item);
      end;
      // A receipt itself is managed state, never a user profile. Keep it in
      // the transaction too so cancellation/failure can restore ownership.
      PathName:=CheckedUpdateChildPath(AppPath,ComponentReceiptName(ID));
      if FileExists(PathName) then
      begin
        Item:=Default(TComponentRemovalFile); Item.ComponentID:=ID;
        Item.FileInfo.Name:=ComponentReceiptName(ID); Item.FileInfo.Size:=TFile.GetSize(PathName);
        Item.FileInfo.SHA256:=UpdateSHA256(PathName); Item.Disposition:=crRemove;
        AddCandidate(Item);
      end;
    end;
    if Selected('BookProcessing') then
      for var Other in Retained do if (Other.Key='Kindle') or (Other.Key='LegacyBooks') or
        (Other.Key='LegacyOffice') or (Other.Key='KindleExport') or
        (Other.Key='FB2Export') or (Other.Key='KoboExport') or (Other.Key='EpubPdfExport') then
        Result.Warnings:=Result.Warnings+TArray<string>.Create(
          'При следующем использовании «'+Other.Value+'» программа может снова предложить модуль подготовки книг.');
    Fingerprint.Append(Result.AppPath);
    for ID in Result.IDs do Fingerprint.Append('|id:').Append(ID);
    for Item in Result.Files do Fingerprint.Append('|file:').Append(Item.FileInfo.Name).Append(':')
      .Append(Item.FileInfo.Size).Append(':').Append(Item.FileInfo.SHA256).Append(':').Append(Ord(Item.Disposition));
    for Source in Result.Blockers do Fingerprint.Append('|blocked:').Append(Source);
    Result.Fingerprint:=THashSHA2.GetHashString(Fingerprint.ToString);
  finally Fingerprint.Free; Retained.Free; Names.Free; Requested.Free; end;
end;

const REMOVAL_KIND = 'HomeLibre component removal v1';

procedure WriteRemovalState(const Job: string; Root: TJSONObject);
var Bytes: TBytes; Stream: TFileStream; Name, Temporary: string;
begin
  Name:=CheckedUpdateChildPath(Job,'state.json'); Temporary:=CheckedUpdateChildPath(Job,'state.json.new');
  Bytes:=TEncoding.UTF8.GetBytes(Root.ToJSON);
  Stream:=TFileStream.Create(Temporary,fmCreate or fmShareExclusive);
  try
    if Length(Bytes)>0 then Stream.WriteBuffer(Bytes,Length(Bytes));
    if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError;
  finally Stream.Free; end;
  if not MoveFileEx(PChar(Temporary),PChar(Name),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
end;

function RemovalJournal(const Job, AppPath: string): TJSONObject;
var Name, Target, ID, Member: string; Files, IDs: TJSONArray;
  Selected, Names: TDictionary<string,Boolean>; Size: Int64; Parsed: TJSONValue;
begin
  Result:=nil; Name:=CheckedUpdateChildPath(Job,'state.json');
  if not FileExists(Name) or (TFile.GetSize(Name)>4*1024*1024) then
    raise Exception.Create('Повреждён журнал удаления модуля.');
  Parsed:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Name,TEncoding.UTF8));
  if not (Parsed is TJSONObject) then
  begin Parsed.Free; raise Exception.Create('Повреждён журнал удаления модуля.'); end;
  Result:=TJSONObject(Parsed);
  try
    if not Assigned(Result) or (Result.GetValue<string>('kind','')<>REMOVAL_KIND) or
      not Result.TryGetValue<string>('target',Target) or
      not SameText(ExcludeTrailingPathDelimiter(TPath.GetFullPath(Target)),ExcludeTrailingPathDelimiter(TPath.GetFullPath(AppPath))) or
      not Result.TryGetValue<TJSONArray>('ids',IDs) or (IDs.Count<1) or (IDs.Count>20) or
      not Result.TryGetValue<TJSONArray>('files',Files) or (Files.Count>12000) then
      raise Exception.Create('Журнал удаления не относится к этой программе.');
    Selected:=TDictionary<string,Boolean>.Create(TIStringComparer.Ordinal);
    Names:=TDictionary<string,Boolean>.Create(TIStringComparer.Ordinal);
    try
      for var Value in IDs do
      begin
        if not (Value is TJSONString) then raise Exception.Create('Повреждён список модулей удаления.');
        ID:=Value.Value;
        if not IsOptionalComponent(ID) or (ComponentFileName(ID)='') or Selected.ContainsKey(ID) then
          raise Exception.Create('Недопустимый модуль в журнале удаления.');
        Selected.Add(ID,True);
      end;
      for var Value in Files do
      begin
        if not (Value is TJSONObject) then raise Exception.Create('Повреждён список файлов удаления.');
        ID:=Value.GetValue<string>('component',''); Member:=Value.GetValue<string>('path','');
        if not Selected.ContainsKey(ID) or Names.ContainsKey(Member) or
          not IsUpdateSHA256(Value.GetValue<string>('sha256','')) or
          not Value.TryGetValue<Int64>('size',Size) or (Size<0) or (Size>128*1024*1024) or
          not ((SafeComponentFile(ID,Member) and not ComponentRemovalCoreFile(Member) and
            not SameText(Member,'Readers/AlReader/$savevtut.ini')) or SameText(Member,ComponentReceiptName(ID))) then
          raise Exception.Create('Недопустимый файл в журнале удаления.');
        CheckedUpdateChildPath(AppPath,Member); CheckedUpdateChildPath(Job,'files/'+Member);
        Names.Add(Member,True);
      end;
    finally Names.Free; Selected.Free; end;
  except Result.Free; Result:=nil; raise; end;
end;

procedure PruneEmptyRemovalFolders(const Directory, Boundary: string);
var Current, Parent: string;
begin
  Current:=ExcludeTrailingPathDelimiter(Directory);
  while Current.StartsWith(IncludeTrailingPathDelimiter(Boundary),True) do
  begin
    AssertUpdatePath(Current);
    if not RemoveDir(Current) then Break;
    Parent:=ExtractFileDir(Current); if Parent=Current then Break; Current:=Parent;
  end;
end;

function CleanRemovalJob(const Job: string; Root: TJSONObject): Boolean;
var Name: string;
begin
  // Delete only journaled files, after checking that quarantined bytes have
  // not changed. Unknown files prevent folder removal and are never erased.
  Result:=False;
  for var Entry in TJSONArray(Root.GetValue('files')) do
  begin
    Name:=CheckedUpdateChildPath(Job,'files/'+Entry.GetValue<string>('path'));
    if FileExists(Name) then
    begin
      if (TFile.GetSize(Name)<>Entry.GetValue<Int64>('size')) or
        not SameText(UpdateSHA256(Name),Entry.GetValue<string>('sha256')) then Exit;
      TFile.Delete(Name);
    end;
    PruneEmptyRemovalFolders(ExtractFileDir(Name),Job);
  end;
  if Length(TDirectory.GetFileSystemEntries(Job))<>1 then Exit;
  Name:=CheckedUpdateChildPath(Job,'state.json'); TFile.Delete(Name);
  Result:=RemoveDir(Job);
end;

procedure RollbackRemoval(const Job, AppPath: string; Root: TJSONObject);
var Name, Destination: string;
begin
  for var Entry in TJSONArray(Root.GetValue('files')) do
  begin
    Name:=CheckedUpdateChildPath(Job,'files/'+Entry.GetValue<string>('path'));
    if not FileExists(Name) then Continue;
    if (TFile.GetSize(Name)<>Entry.GetValue<Int64>('size')) or
      not SameText(UpdateSHA256(Name),Entry.GetValue<string>('sha256')) then
      raise Exception.Create('Не удалось восстановить изменённый временный файл: '+Name);
    Destination:=CheckedUpdateChildPath(AppPath,Entry.GetValue<string>('path'));
    // Never overwrite a new file created by another program after removal.
    if FileExists(Destination) or DirectoryExists(Destination) then
      raise Exception.Create('Восстановлению мешает новый файл. Сохранённая копия: '+Name);
    ForceDirectories(ExtractFileDir(Destination));
    if not MoveFileEx(PChar(Name),PChar(Destination),MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
    PruneEmptyRemovalFolders(ExtractFileDir(Name),Job);
  end;
  Root.RemovePair('state').Free; Root.AddPair('state','rolled-back'); WriteRemovalState(Job,Root);
end;

function RecoverComponentRemovals(const AppPath: string): TArray<string>;
var Folder, Job, State: string; Root: TJSONObject;
begin
  Result:=nil; Folder:=CheckedUpdateChildPath(AppPath,'tools/component-state');
  if not DirectoryExists(Folder) then Exit;
  for var Item in TDirectory.GetDirectories(Folder,'remove-*',TSearchOption.soTopDirectoryOnly) do
  begin
    Root:=nil;
    try
      Job:=CheckedUpdateChildPath(AppPath,'tools/component-state/'+ExtractFileName(Item));
      Root:=RemovalJournal(Job,AppPath); State:=Root.GetValue<string>('state','');
      if State='removing' then RollbackRemoval(Job,AppPath,Root)
      else if (State<>'removed') and (State<>'rolled-back') then
        raise Exception.Create('Неизвестное состояние удаления модуля.');
      if not CleanRemovalJob(Job,Root) then
        Result:=Result+TArray<string>.Create('Сохранены временные файлы удаления: '+Job);
    except on E: Exception do Result:=Result+TArray<string>.Create(E.Message); end;
    Root.Free;
  end;
end;

function ExecuteComponentRemovalPlan(const Plan: TComponentRemovalPlan; FailAfter: Integer;
  const IsCanceled: TFunc<Boolean>): string;
var Fresh: TComponentRemovalPlan; Job, Source, Destination: string; Root, Entry: TJSONObject;
  Files, IDs: TJSONArray; Applied: Integer; Handle: THandle; Completed: Boolean;
begin
  Result:='';
  Fresh:=BuildComponentRemovalPlan(Plan.AppPath,Plan.IDs,Plan.ManifestSources,IsCanceled);
  if not Fresh.CanRemove or (Fresh.Fingerprint<>Plan.Fingerprint) then
    raise Exception.Create('Состав файлов изменился. Проверьте список удаления ещё раз.');
  for var Item in Fresh.Files do if Item.Disposition=crRemove then
  begin
    Source:=CheckedUpdateChildPath(Plan.AppPath,Item.FileInfo.Name);
    Handle:=CreateFile(PChar(Source),GENERIC_READ or GENERIC_WRITE,0,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    if Handle=INVALID_HANDLE_VALUE then
      raise Exception.Create('Файл занят или недоступен. Закройте использующую его читалку: '+Item.FileInfo.Name);
    CloseHandle(Handle);
  end;
  Job:=CheckedUpdateChildPath(Plan.AppPath,'tools/component-state/remove-'+TGUID.NewGuid.ToString);
  ForceDirectories(Job); Root:=TJSONObject.Create; Completed:=False;
  try
    Root.AddPair('kind',REMOVAL_KIND); Root.AddPair('target',Plan.AppPath); Root.AddPair('state','removing');
    IDs:=TJSONArray.Create; Root.AddPair('ids',IDs); for var ID in Fresh.IDs do IDs.Add(ID);
    Files:=TJSONArray.Create; Root.AddPair('files',Files);
    for var Item in Fresh.Files do if Item.Disposition=crRemove then
    begin
      Entry:=TJSONObject.Create; Entry.AddPair('component',Item.ComponentID); Entry.AddPair('path',Item.FileInfo.Name);
      Entry.AddPair('sha256',Item.FileInfo.SHA256); Entry.AddPair('size',TJSONNumber.Create(Item.FileInfo.Size)); Files.AddElement(Entry);
    end;
    WriteRemovalState(Job,Root); Applied:=0;
    try
      for var Item in Fresh.Files do if Item.Disposition=crRemove then
      begin
        if Assigned(IsCanceled) and IsCanceled() then Abort;
        Source:=CheckedUpdateChildPath(Plan.AppPath,Item.FileInfo.Name);
        if (TFile.GetSize(Source)<>Item.FileInfo.Size) or not SameText(UpdateSHA256(Source),Item.FileInfo.SHA256) then
          raise Exception.Create('Файл изменился во время удаления: '+Item.FileInfo.Name);
        Destination:=CheckedUpdateChildPath(Job,'files/'+Item.FileInfo.Name); ForceDirectories(ExtractFileDir(Destination));
        if not MoveFileEx(PChar(Source),PChar(Destination),MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
        Inc(Applied);
        if (FailAfter>=0) and (Applied>=FailAfter) then raise Exception.Create('Имитированная ошибка удаления');
      end;
      if Assigned(IsCanceled) and IsCanceled() then Abort;
      Root.RemovePair('state').Free; Root.AddPair('state','removed'); WriteRemovalState(Job,Root); Completed:=True;
    except
      RollbackRemoval(Job,Plan.AppPath,Root);
      try CleanRemovalJob(Job,Root); except end;
      raise;
    end;
    try if not CleanRemovalJob(Job,Root) then Result:=Job;
    except Result:=Job; end;
    if Completed then for var Item in Fresh.Files do if Item.Disposition=crRemove then
      PruneEmptyRemovalFolders(ExtractFileDir(CheckedUpdateChildPath(Plan.AppPath,Item.FileInfo.Name)),Plan.AppPath);
  finally Root.Free; end;
end;

end.
