unit unit_CollectionBackup;

interface

uses System.SysUtils, System.Classes, SQLiteWrap, unit_Interfaces;

type
  TCollectionBackupOperation = (cboUnknown, cboCollections, cboSeries, cboBooks);
  TCollectionBackupInfo = record
    CreatedAt: TDateTime;
    HasCreatedAt, DateFromFolderName: Boolean;
    Operation: TCollectionBackupOperation;
  end;
  TSnapshotCanceled = reference to function: Boolean;
  ISnapshotCollectionRestorer = interface
    ['{F80CB527-EDC1-48E4-B695-F139F4F27611}']
    // Register a new catalog and copy only its personal cards/groups in one
    // system-store transaction. The source connection is a read-only snapshot.
    function RegisterSnapshotCollection(const CatalogFile, DisplayName, Root, SourceRoot: string;
      Source: TSQLiteDatabase; SourceID: Integer;
      const Canceled: TSnapshotCanceled): Integer;
  end;

  TCollectionBackupPlan = class
  private
    FCatalog, FPersonal: TSQLiteDatabase;
    FFolder, FOriginalFile, FOriginalSystem, FTitle, FRoot, FSourceRoot: string;
    FRequiredBytes: Int64;
    FSourceID: Integer;
    FReport: TStringList;
    FReady: Boolean;
    FCanceled: TSnapshotCanceled;
    function QueryCanceled: Boolean;
    procedure CheckCanceled;
    procedure CloseSnapshots;
  public
    constructor Create(const Folder: string);
    destructor Destroy; override;
    procedure Preview(const Canceled: TSnapshotCanceled = nil);
    function RestoreAsNew(const SystemData: ISystemData; const Destination,
      DisplayName: string; const Canceled: TSnapshotCanceled = nil;
      const Progress: TSQLiteBackupProgress = nil): Integer;
    property Report: TStringList read FReport;
    property Title: string read FTitle;
    property Root: string read FRoot write FRoot;
    property Ready: Boolean read FReady;
  end;

procedure WriteCollectionBackupInfo(const Folder: string; Operation: TCollectionBackupOperation);
function ReadCollectionBackupInfo(const Folder: string): TCollectionBackupInfo;
function CollectionBackupOperationText(Operation: TCollectionBackupOperation): string;
function CollectionBackupDateText(const Info: TCollectionBackupInfo; IncludeOrigin: Boolean = True): string;

implementation

uses System.IOUtils, System.JSON, System.DateUtils, Winapi.Windows,
  unit_Consts, unit_Globals, unit_CollectionSpace;

const
  BackupOperationCodes: array[TCollectionBackupOperation] of string =
    ('unknown', 'collection-merge', 'series-aliases', 'book-duplicates');

function CollectionBackupOperationText(Operation: TCollectionBackupOperation): string;
begin
  case Operation of
    cboCollections: Result:='Объединение коллекций';
    cboSeries: Result:='Объединение названий серий';
    cboBooks: Result:='Объединение повторных книг';
  else Result:='Операция не указана'; end;
end;

function CollectionBackupDateText(const Info: TCollectionBackupInfo; IncludeOrigin: Boolean): string;
begin
  if not Info.HasCreatedAt then Exit('Дата и время не сохранены');
  Result:=FormatDateTime('dd.mm.yyyy hh:nn:ss',Info.CreatedAt);
  if IncludeOrigin then
    if Info.DateFromFolderName then Result:=Result+' (из имени папки)'
    else Result:=Result+' (местное время)';
end;

procedure WriteCollectionBackupInfo(const Folder: string; Operation: TCollectionBackupOperation);
var Data: TJSONObject;
begin
  Data:=TJSONObject.Create;
  try
    Data.AddPair('schemaVersion',TJSONNumber.Create(1));
    Data.AddPair('createdAtUtc',DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True));
    Data.AddPair('operation',BackupOperationCodes[Operation]);
    TFile.WriteAllText(TPath.Combine(Folder,'backup-info.json'),Data.ToJSON,TEncoding.UTF8);
  finally Data.Free; end;
end;

function ReadCollectionBackupInfo(const Folder: string): TCollectionBackupInfo;
var Name, Prefix, Stamp, FileName, Value: string; DatePart, TimePart, UTC: TDateTime;
  Y, M, D, H, N, S, Schema: Integer; Stream: TFileStream; Bytes: TBytes; Data: TJSONValue;
  procedure ReadLegacyName;
  begin
    Name:=ExtractFileName(ExcludeTrailingPathDelimiter(Folder)); Prefix:='';
    if Name.StartsWith('merge-',True) then
    begin Prefix:='merge-'; Result.Operation:=cboCollections; end
    else if Name.StartsWith('series-',True) then
    begin Prefix:='series-'; Result.Operation:=cboSeries; end
    else if Name.StartsWith('books-',True) then
    begin Prefix:='books-'; Result.Operation:=cboBooks; end;
    if Prefix='' then Exit;
    Stamp:=Copy(Name,Length(Prefix)+1,15);
    if (Length(Stamp)<>15) or (Stamp[9]<>'-') then Exit;
    for var I:=1 to Length(Stamp) do
      if (I<>9) and not CharInSet(Stamp[I],['0'..'9']) then Exit;
    if not (TryStrToInt(Copy(Stamp,1,4),Y) and TryStrToInt(Copy(Stamp,5,2),M) and
      TryStrToInt(Copy(Stamp,7,2),D) and TryStrToInt(Copy(Stamp,10,2),H) and
      TryStrToInt(Copy(Stamp,12,2),N) and TryStrToInt(Copy(Stamp,14,2),S)) then Exit;
    if not (TryEncodeDate(Y,M,D,DatePart) and TryEncodeTime(H,N,S,0,TimePart)) then Exit;
    Result.CreatedAt:=DatePart+TimePart; Result.HasCreatedAt:=True; Result.DateFromFolderName:=True;
  end;
begin
  Result:=Default(TCollectionBackupInfo); ReadLegacyName;
  FileName:=TPath.Combine(Folder,'backup-info.json');
  if not FileExists(FileName) then Exit;
  // Optional display metadata must not require opening SQLite or stop the
  // recovery of a valid old backup if its description is damaged.
  try
    Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
    try
      if Stream.Size>65536 then Exit;
      SetLength(Bytes,Integer(Stream.Size));
      if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
    finally Stream.Free; end;
    Value:=TEncoding.UTF8.GetString(Bytes);
    if (Value<>'') and (Value[1]=#$FEFF) then Delete(Value,1,1);
    Data:=TJSONObject.ParseJSONValue(Value);
    try
      if not (Data is TJSONObject) or not Data.TryGetValue<Integer>('schemaVersion',Schema) or (Schema<>1) then Exit;
      if Data.TryGetValue<string>('createdAtUtc',Value) and TryISO8601ToDate(Value,UTC,True) then
      begin
        Result.CreatedAt:=TTimeZone.Local.ToLocalTime(UTC);
        Result.HasCreatedAt:=True; Result.DateFromFolderName:=False;
      end;
      Result.Operation:=cboUnknown;
      if Data.TryGetValue<string>('operation',Value) then
        for var Operation:=Low(TCollectionBackupOperation) to High(TCollectionBackupOperation) do
          if Value=BackupOperationCodes[Operation] then begin Result.Operation:=Operation; Break; end;
    finally Data.Free; end;
  except
    // Keep the explicitly marked legacy folder date. Never substitute the
    // file modification date: copying or editing a backup can change it.
  end;
end;

constructor TCollectionBackupPlan.Create(const Folder: string);
begin
  inherited Create; FFolder:=TPath.GetFullPath(Folder); FReport:=TStringList.Create;
end;

procedure TCollectionBackupPlan.CloseSnapshots;
begin
  FreeAndNil(FPersonal); FreeAndNil(FCatalog); FReady:=False;
end;

destructor TCollectionBackupPlan.Destroy;
begin CloseSnapshots; FReport.Free; inherited; end;

function TCollectionBackupPlan.QueryCanceled: Boolean;
begin Result:=Assigned(FCanceled) and FCanceled(); end;

procedure TCollectionBackupPlan.CheckCanceled;
begin if QueryCanceled then Abort; end;

procedure TCollectionBackupPlan.Preview(const Canceled: TSnapshotCanceled);
var Lines: TStringList; Line, StoredFile, StoredRoot, Candidate: string;
  Q: TSQLiteQuery; Matches: Integer; Previous: TSQLiteCancelCallback; Info: TCollectionBackupInfo;
begin
  CloseSnapshots; FReport.Clear; FCanceled:=Canceled; FOriginalFile:=''; FOriginalSystem:=''; FRoot:='';
  Previous:=SQLiteCancelCallback; SQLiteCancelCallback:=QueryCanceled;
  try
  try
    CheckCanceled;
    if not FileExists(TPath.Combine(FFolder,'restore-paths.txt')) then
      raise Exception.Create('В папке нет описания резервной копии restore-paths.txt.');
    Lines:=TStringList.Create;
    try
      Lines.LoadFromFile(TPath.Combine(FFolder,'restore-paths.txt'),TEncoding.UTF8);
      for Line in Lines do
      begin
        if Line.StartsWith('Коллекция: ') then FOriginalFile:=Copy(Line,Length('Коллекция: ')+1,MaxInt);
        if Line.StartsWith('Назначение: ') then FOriginalFile:=Copy(Line,Length('Назначение: ')+1,MaxInt);
        if Line.StartsWith('Группы и настройки: ') then FOriginalSystem:=Copy(Line,Length('Группы и настройки: ')+1,MaxInt);
        if Line.StartsWith('Папка книг: ') then FRoot:=Copy(Line,Length('Папка книг: ')+1,MaxInt);
      end;
    finally Lines.Free; end;
    if (FOriginalFile='') or (FOriginalSystem='') then
      raise Exception.Create('Не удалось определить исходную коллекцию резервной копии.');
    FCatalog:=TSQLiteDatabase.CreateReadOnly(TPath.Combine(FFolder,'destination.hlc2'));
    FPersonal:=TSQLiteDatabase.CreateReadOnly(TPath.Combine(FFolder,'system.hlc2'));
    FCatalog.Start; FPersonal.Start;
    if (FCatalog.QuerySingleString('PRAGMA quick_check')<>'ok') or
      (FPersonal.QuerySingleString('PRAGMA quick_check')<>'ok') then
      raise Exception.Create('Резервная копия не прошла проверку SQLite.');
    Matches:=0; FSourceID:=INVALID_COLLECTION_ID;
    Q:=FPersonal.NewQuery('SELECT DatabaseID,BaseName,DBFileName,RootFolder,Code FROM Bases');
    try
      Q.Open;
      while not Q.Eof do
      begin
        CheckCanceled; StoredFile:=Q.FieldAsString(2);
        if ExtractFileExt(StoredFile)='' then StoredFile:=StoredFile+COLLECTION_EXTENSION;
        // Earlier backups store relative catalog names in Bases. Resolve them
        // against the recorded system-store folder, never today's profile.
        if TPath.IsPathRooted(StoredFile) then Candidate:=TPath.GetFullPath(StoredFile)
        else Candidate:=TPath.GetFullPath(TPath.Combine(ExtractFileDir(FOriginalSystem),StoredFile));
        if SameFileName(Candidate,TPath.GetFullPath(FOriginalFile)) then
        begin
          if isOnlineCollection(Q.FieldAsInt(4)) then
            raise Exception.Create('Восстановление сетевой коллекции этим способом не поддерживается.');
          Inc(Matches); FSourceID:=Q.FieldAsInt(0); FTitle:=Q.FieldAsString(1);
          StoredRoot:=Q.FieldAsString(3);
          if FRoot='' then
            if TPath.IsPathRooted(StoredRoot) then FRoot:=StoredRoot
            else
            begin
              FRoot:=TPath.GetFullPath(TPath.Combine(ExtractFileDir(ExtractFileDir(FOriginalSystem)),StoredRoot));
              FReport.Add('Старая копия содержит относительный путь к книгам. Проверьте поле «Папка книг» перед восстановлением.');
            end;
        end;
        Q.Next;
      end;
    finally Q.Free; end;
    if Matches<>1 then raise Exception.Create('В резервной копии не удалось однозначно найти исходную коллекцию.');
    FSourceRoot:=FRoot;
    FRequiredBytes:=FCatalog.QuerySingleInt('PRAGMA page_count')*FCatalog.QuerySingleInt('PRAGMA page_size');
    Info:=ReadCollectionBackupInfo(FFolder);
    FReport.Add('Дата и время: '+CollectionBackupDateText(Info));
    FReport.Add('Операция: '+CollectionBackupOperationText(Info.Operation));
    if Info.Operation<>cboUnknown then FReport.Add('Состояние сохранено перед указанной операцией.');
    FReport.Add('Коллекция: '+FTitle); FReport.Add('Резервная копия: '+FFolder);
    FReport.Add('Папка книг: '+FRoot);
    FReport.Add('Записей книг: '+IntToStr(FCatalog.QuerySingleInt('SELECT count(*) FROM Books')));
    FReport.Add('Личных карточек: '+IntToStr(FPersonal.QuerySingleInt('SELECT count(*) FROM Books WHERE DatabaseID=?',[FSourceID])));
    FReport.Add('Связей с группами: '+IntToStr(FPersonal.QuerySingleInt('SELECT count(*) FROM BookGroups WHERE DatabaseID=?',[FSourceID])));
    FReport.Add('Дополнительно для каталога: '+FormatFloat('0.0',FRequiredBytes/(1024.0*1024))+' МБ, плюс место для личных карточек.');
    FReport.Add(''); FReport.Add('Копия появится в меню «Коллекция» этой программы. Исходная коллекция и её текущее состояние сохранятся.');
    FReport.Add('Книги и архивы остаются в своих папках. Резервная копия содержит каталог и личные карточки, но не сами файлы книг.');
    FReport.Add('Группы с изменёнными заметками будут восстановлены отдельно, без замены текущих заметок.');
    if FileExists(TPath.Combine(FFolder,'reader.ini')) or FileExists(TPath.Combine(FFolder,'reader-notes.json')) then
      FReport.Add('В папке копии сохранены файлы читалки. Автоматический перенос истории, закладок и заметок на новый номер коллекции пока не выполняется; текущие файлы читалки не заменяются.')
    else FReport.Add('Отдельные файлы закладок и заметок читалки в этой резервной копии отсутствуют и не восстанавливаются.');
    if not DirectoryExists(FRoot) then FReport.Add('Папка книг сейчас недоступна. После восстановления можно указать её в свойствах коллекции.');
    CheckCanceled; FReady:=True;
  except CloseSnapshots; raise;
  end;
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
end;

function TCollectionBackupPlan.RestoreAsNew(const SystemData: ISystemData;
  const Destination, DisplayName: string; const Canceled: TSnapshotCanceled;
  const Progress: TSQLiteBackupProgress): Integer;
var Restorer: ISnapshotCollectionRestorer; Name, StageFolder, Stage: string; Created: Boolean; FreeBytes: Int64;
begin
  if not FReady then raise Exception.Create('Сначала проверьте резервную копию.');
  if Trim(DisplayName)='' then raise Exception.Create('Укажите название восстановленной коллекции.');
  if not TPath.IsPathRooted(FRoot) then raise Exception.Create('Укажите полный путь к папке книг.');
  if not Supports(SystemData,ISnapshotCollectionRestorer,Restorer) then
    raise Exception.Create('Хранилище не поддерживает восстановление личных карточек.');
  Name:=TPath.GetFullPath(Destination); Created:=False;
  if FileExists(Name) or FileExists(Name+'-wal') or FileExists(Name+'-shm') then
    raise Exception.Create('Для восстановленной коллекции нужен новый файл.');
  FreeBytes:=CollectionDiskFree(Name);
  if (FreeBytes>=0) and (FreeBytes<FRequiredBytes+FRequiredBytes div 20+Int64(16)*1024*1024) then
    raise Exception.Create('Недостаточно места для отдельного каталога и личных карточек.');
  StageFolder:=TPath.Combine(ExtractFileDir(Name),'restore-'+TGUID.NewGuid.ToString);
  if not CreateDir(StageFolder) then RaiseLastOSError;
  Stage:=TPath.Combine(StageFolder,'catalog.hlc2');
  FCanceled:=Canceled;
  try
    CheckCanceled;
    FCatalog.BackupTo(Stage,
      procedure(Done,Total: Integer)
      begin CheckCanceled; if Assigned(Progress) then Progress(Done,Total); end);
    CheckCanceled;
    // MoveFile never replaces an existing file, including one that appeared
    // after the initial validation. Cleanup owns only our new snapshot.
    if not MoveFile(PChar(Stage),PChar(Name)) then RaiseLastOSError;
    Created:=True;
    Result:=Restorer.RegisterSnapshotCollection(Name,Trim(DisplayName),FRoot,FSourceRoot,FPersonal,FSourceID,Canceled);
    Created:=False;
  finally
    FCanceled:=nil;
    if FileExists(Stage) then TFile.Delete(Stage);
    RemoveDir(StageFolder);
    if Created then
      for var Suffix in ['-wal','-shm',''] do
        if FileExists(Name+Suffix) then TFile.Delete(Name+Suffix);
  end;
end;
end.
