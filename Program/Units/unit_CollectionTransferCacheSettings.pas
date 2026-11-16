unit unit_CollectionTransferCacheSettings;

interface

uses System.SysUtils, System.JSON, SQLiteWrap, unit_CollectionTransferLayout;

// Metadata planning only. Store is an owned work database in the caller's
// transaction. No cache, raw index, setting or source directory is changed.
type TTransferCacheSettingsPlan=class
  private
    FStore:TSQLiteDatabase;
    FLayout:TCollectionTransferLayout;
    FCheck:TProc;
    FVersionForJob:TFunc<string,string>;
    procedure Check;
    function AddJob(const ID,Version,BeforeRoot,AfterRoot,Namespace:string):string;
    function AddInput(const Job,SourceFile,ExpectedSHA:string):string;
    function AfterVersion(const Job:string):string;
  public
    constructor Create(Review,Store:TSQLiteDatabase; const Cancelled:TProc=nil;
      const VersionForJob:TFunc<string,string>=nil);
    destructor Destroy; override;
    function ProjectSources(const Before:string; MoveRoots:Boolean):string;
    function ProjectHistory(const Before:string; MoveRoots:Boolean):string;
    function Jobs:TJSONArray;
    function Inputs:TJSONArray;
  end;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.Generics.Collections, unit_CatalogSources;

const MaxSettings=16*1024*1024; MaxJobs=4096;

function Full(const Path:string):string;
begin
  if (Path='') or not TPath.IsPathRooted(Path) or (Pos(#0,Path)>0) then
    raise EReadError.Create('Не указана абсолютная папка или файл сохранённого источника.');
  Result:=ExpandFileName(Path.Replace('/','\'));
end;

function Root(const Path:string):string;
begin Result:=IncludeTrailingPathDelimiter(Full(Path)); end;

procedure SetText(Obj:TJSONObject; const Name,Value:string);
begin
  var Count:=0; for var Pair in Obj do if Pair.JsonString.Value=Name then Inc(Count);
  if Count>1 then raise EReadError.Create('Повторяющееся поле сохранённого источника: '+Name);
  Obj.RemovePair(Name).Free; Obj.AddPair(Name,Value);
end;

function Parse(const Text:string):TJSONValue;
begin
  if Length(Text)>MaxSettings then raise EReadError.Create('Слишком большие настройки сохранённых источников.');
  Result:=TJSONObject.ParseJSONValue(Text);
  if Result=nil then raise EReadError.Create('Не прочитаны настройки сохранённых источников.');
end;

constructor TTransferCacheSettingsPlan.Create(Review,Store:TSQLiteDatabase; const Cancelled:TProc;
  const VersionForJob:TFunc<string,string>);
begin
  inherited Create;
  if (Store=nil) or not Store.InTransaction then raise EArgumentException.Create('Нужна транзакция собственной рабочей базы кэша.');
  FStore:=Store; FCheck:=Cancelled; FVersionForJob:=VersionForJob; FLayout:=TCollectionTransferLayout.Create(Review); Check;
  // Do not use TEMP: SQLiteWrap defaults it to memory.
  FStore.ExecSQL('CREATE TABLE TransferCacheSettingJobs('+
    'Job TEXT PRIMARY KEY,SourceID TEXT NOT NULL,BeforeVersion TEXT NOT NULL,AfterVersion TEXT NOT NULL,'+
    'BeforeRoot TEXT NOT NULL,AfterRoot TEXT NOT NULL,Library TEXT NOT NULL,BeforeFile TEXT NOT NULL,AfterFile TEXT NOT NULL) WITHOUT ROWID');
  FStore.ExecSQL('CREATE TABLE TransferCacheSettingInputs('+
    'Job TEXT NOT NULL,SourceKey TEXT NOT NULL,SourceFile TEXT NOT NULL,ExpectedSHA TEXT NOT NULL,TargetFile TEXT NOT NULL,'+
    'PRIMARY KEY(Job,SourceKey)) WITHOUT ROWID');
end;

destructor TTransferCacheSettingsPlan.Destroy;
begin FLayout.Free; inherited; end;

procedure TTransferCacheSettingsPlan.Check;
begin if Assigned(FCheck) then FCheck; end;

function TTransferCacheSettingsPlan.AddJob(const ID,Version,BeforeRoot,AfterRoot,Namespace:string):string;
var Source:TCatalogSource;
begin
  Check; Source:=Default(TCatalogSource); Source.ID:=ID; Source.CacheVersion:=Version;
  var FileName:=Full(Source.CacheFile); var OldRoot:=Root(BeforeRoot); var NewRoot:=Root(AfterRoot);
  // Keep exact IDs/namespaces in the signature: existing source keys may carry
  // their original spelling. Native paths themselves compare case-insensitively.
  Result:=THashSHA2.GetHashString(ID+#0+LowerCase(FileName)+#0+LowerCase(OldRoot)+#0+LowerCase(NewRoot)+#0+Namespace);
  if FStore.QuerySingleInt('SELECT count(*) FROM TransferCacheSettingJobs WHERE Job=?',[Result])<>0 then Exit;
  if FStore.QuerySingleInt('SELECT count(*) FROM TransferCacheSettingJobs')>=MaxJobs then
    raise EReadError.Create('Слишком много разных версий кэша для одного переноса.');
  if Assigned(FVersionForJob) then Source.CacheVersion:=FVersionForJob(Result)
  else Source.CacheVersion:=TCatalogSource.NewID;
  if Source.CacheVersion='' then raise EReadError.Create('В намерении нет выбранной версии кэша.');
  var AfterFile:=Full(Source.CacheFile);
  if SameFileName(FileName,AfterFile) then raise EReadError.Create('Новая версия кэша совпала с исходной.');
  FStore.ExecSQL('INSERT INTO TransferCacheSettingJobs VALUES(?,?,?,?,?,?,?,?,?)',
    [Result,ID,Version,Source.CacheVersion,OldRoot,NewRoot,Namespace,FileName,AfterFile]);
end;

function TTransferCacheSettingsPlan.AfterVersion(const Job:string):string;
begin Result:=FStore.QuerySingleString('SELECT AfterVersion FROM TransferCacheSettingJobs WHERE Job=?',[Job]); end;

function TTransferCacheSettingsPlan.AddInput(const Job,SourceFile,ExpectedSHA:string):string;
begin
  Check; if SourceFile='' then Exit('');
  var Source:=Full(SourceFile); var SHA:=LowerCase(ExpectedSHA);
  if SHA<>'' then
  begin
    if Length(SHA)<>64 then raise EReadError.Create('Неверная контрольная сумма сохранённого индекса.');
    for var C in SHA do if not CharInSet(C,['0'..'9','a'..'f']) then
      raise EReadError.Create('Неверная контрольная сумма сохранённого индекса.');
  end;
  var Folder:=ExtractFilePath(FStore.QuerySingleString('SELECT AfterFile FROM TransferCacheSettingJobs WHERE Job=?',[Job]));
  if Folder='' then raise EReadError.Create('Нет новой версии для исходного индекса.');
  Result:=TPath.Combine(Folder,'index-'+THashSHA2.GetHashString(LowerCase(Source))+ExtractFileExt(Source));
  var Q:=FStore.NewQuery('SELECT ExpectedSHA,TargetFile FROM TransferCacheSettingInputs WHERE Job=? AND SourceKey=?',
    [Job,LowerCase(Source)]);
  try
    Q.Open;
    if not Q.Eof then
    begin
      if ((SHA<>'') and (Q.FieldAsString(0)<>'') and (SHA<>Q.FieldAsString(0))) or (Q.FieldAsString(1)<>Result) then
        raise EReadError.Create('Один сохранённый индекс имеет разные контрольные суммы.');
      if (SHA<>'') and (Q.FieldAsString(0)='') then
        FStore.ExecSQL('UPDATE TransferCacheSettingInputs SET ExpectedSHA=? WHERE Job=? AND SourceKey=?',[SHA,Job,LowerCase(Source)]);
      Exit;
    end;
  finally Q.Free; end;
  FStore.ExecSQL('INSERT INTO TransferCacheSettingInputs VALUES(?,?,?,?,?)',[Job,LowerCase(Source),Source,SHA,Result]);
end;

function TTransferCacheSettingsPlan.ProjectSources(const Before:string; MoveRoots:Boolean):string;
var Original,Projected:TJSONValue; Seen:TDictionary<string,Boolean>;
begin
  Check; Result:=FLayout.ProjectSources(Before,MoveRoots); if Before='' then Exit;
  Original:=nil; Projected:=nil; Seen:=nil;
  try
    Original:=Parse(Before); Projected:=Parse(Result); Seen:=TDictionary<string,Boolean>.Create;
    if not (Original is TJSONArray) or not (Projected is TJSONArray) or
      (TJSONArray(Original).Count<>TJSONArray(Projected).Count) or (TJSONArray(Original).Count>MaxJobs) then
      raise EReadError.Create('Повреждён список источников кэша.');
    var Changed:=False;
    for var I:=0 to TJSONArray(Original).Count-1 do
    begin
      Check; var Old:=TJSONArray(Original).Items[I] as TJSONObject; var New:=TJSONArray(Projected).Items[I] as TJSONObject;
      var ID:=Old.GetValue<string>('id');
      if Seen.ContainsKey(LowerCase(ID)) then raise EReadError.Create('Источник повторяется в настройках кэша.');
      Seen.Add(LowerCase(ID),True);
      var Input:=Old.GetValue<string>('inpx',''); if Input='' then Continue;
      var Job:=AddJob(ID,Old.GetValue<string>('cache_version',''),Old.GetValue<string>('root',''),
        New.GetValue<string>('root',''),Old.GetValue<string>('library',''));
      SetText(New,'cache_version',AfterVersion(Job)); Changed:=True;
      var OldFile:=FStore.QuerySingleString('SELECT BeforeFile FROM TransferCacheSettingJobs WHERE Job=?',[Job]);
      // A user-selected INPX outside the cache remains the refresh source.
      // Only an owned retained input moves together with its cache version.
      if SameFileName(ExtractFilePath(Full(Input)),ExtractFilePath(OldFile)) then
        SetText(New,'inpx',AddInput(Job,Input,''));
    end;
    if Changed then Result:=Projected.ToJSON;
  finally Seen.Free; Projected.Free; Original.Free; end;
end;

function TTransferCacheSettingsPlan.ProjectHistory(const Before:string; MoveRoots:Boolean):string;
var Data:TJSONValue;
begin
  Check; Result:=Before; if Before='' then Exit;
  Data:=Parse(Before);
  try
    if not (Data is TJSONObject) then raise EReadError.Create('Повреждена история кэша.');
    var Obj:=TJSONObject(Data);
    var Items:=Obj.GetValue<TJSONArray>('sources',nil);
    if (Obj.GetValue<Integer>('version',0)<>1) or (Items=nil) or (Items.Count>256) then
      raise EReadError.Create('Неизвестная история кэша.');
    for var Value in Items do
    begin
      Check; var Row:=Value as TJSONObject; var ID:=Row.GetValue<string>('source','');
      var Binding:=Row.GetValue<string>('binding',''); var Profile:=Row.GetValue<string>('profile','');
      if ((Binding<>'') and not SameText(ID,Binding)) or ((Binding='') and not SameText(ID,Profile)) then
        raise EReadError.Create('Не совпала привязка истории сохранённого источника.');
      var Version:=Row.GetValue<string>('cache','');
      if Version='' then raise EReadError.Create('В истории не указана версия исходного кэша.');
      var BeforeRoot:=Row.GetValue<string>('root',''); var AfterRoot:=BeforeRoot;
      if MoveRoots then AfterRoot:=FLayout.RelocatePath(BeforeRoot);
      var Job:=AddJob(ID,Version,BeforeRoot,AfterRoot,Row.GetValue<string>('library',''));
      SetText(Row,'root',AfterRoot); SetText(Row,'cache',AfterVersion(Job));
      var Input:=Row.GetValue<string>('index','');
      if Input<>'' then SetText(Row,'index',AddInput(Job,Input,Row.GetValue<string>('sha256','')));
    end;
    Result:=Data.ToJSON;
  finally Data.Free; end;
end;

function TTransferCacheSettingsPlan.Jobs:TJSONArray;
begin
  Result:=TJSONArray.Create;
  var Q:=FStore.NewQuery('SELECT Job,SourceID,BeforeVersion,AfterVersion,BeforeRoot,AfterRoot,Library,BeforeFile,AfterFile FROM TransferCacheSettingJobs ORDER BY Job');
  try try
    Q.Open; while not Q.Eof do
    begin
      Check; var Row:=TJSONObject.Create; Result.AddElement(Row);
      var Names:TArray<string>:= ['job','source','before_version','after_version','before_root','after_root','library','before_file','after_file'];
      for var I:=0 to High(Names) do Row.AddPair(Names[I],Q.FieldAsString(I)); Q.Next;
    end;
  except Result.Free; raise;
  end;
  finally Q.Free; end;
end;

function TTransferCacheSettingsPlan.Inputs:TJSONArray;
begin
  Result:=TJSONArray.Create;
  var Q:=FStore.NewQuery('SELECT Job,SourceFile,ExpectedSHA,TargetFile FROM TransferCacheSettingInputs ORDER BY Job,SourceFile');
  try try
    Q.Open; while not Q.Eof do
    begin
      Check; var Row:=TJSONObject.Create; Result.AddElement(Row);
      Row.AddPair('job',Q.FieldAsString(0)); Row.AddPair('source_file',Q.FieldAsString(1));
      Row.AddPair('sha256',Q.FieldAsString(2)); Row.AddPair('target_file',Q.FieldAsString(3)); Q.Next;
    end;
  except Result.Free; raise;
  end;
  finally Q.Free; end;
end;

end.
