unit unit_CollectionTransferLayout;

interface

uses System.SysUtils, System.Generics.Collections, SQLiteWrap;

type
  TTransferFinalRoot=record ID,Input,Destination:string; Observed:Boolean; end;
  TTransferFutureLocator=record
    BindingID,BookID:Int64;
    Kind:Integer;
    SourceKey,Source,Folder,FileName,CopyRoot:string;
  end;
  TTransferFutureVisitor=reference to procedure(const Locator:TTransferFutureLocator);

  // Deterministic read-only projection from the owning journal's frozen review.
  // No directory, book, setting, registration or completion marker is written.
  TCollectionTransferLayout=class
  private
    FReview:TSQLiteDatabase;
    FDestination,FContentRoot:string;
    FRoots:TDictionary<string,TTransferFinalRoot>;
    FOrdered:TList<TTransferFinalRoot>;
    function MappedPath(const Path:string; out Mapped:string):Boolean;
    procedure ReadRoots;
    function FutureLocator(Q:TSQLiteQuery):TTransferFutureLocator;
  public
    constructor Create(Review:TSQLiteDatabase);
    destructor Destroy; override;
    function Roots:TArray<TTransferFinalRoot>;
    function RootDestination(const ID:string):string;
    function RelocatePath(const Path:string):string;
    function SourceSettings:string;
    function ProjectSources(const Current:string; MoveRoots:Boolean):string;
    function UpdateSettings(const Current:string):string;
    procedure ForEachFutureLocator(const Visit:TTransferFutureVisitor);
    function TryMainFuture(BookID:Int64; out Locator:TTransferFutureLocator):Boolean;
  end;

implementation

uses System.Classes, System.IOUtils, System.JSON, System.Hash, System.Generics.Defaults, unit_Globals,
  unit_Settings, dm_user, unit_CollectionTransferCatalogue, unit_LibraryUpdateSources;

function Folder(const Path:string):string;
begin
  if (Path='') or not TPath.IsPathRooted(Path) or (Length(TPath.GetPathRoot(Path))<3) or
    (Pos(#0,Path)>0) then raise EReadError.Create('Неверная папка итогового размещения коллекции.');
  Result:=IncludeTrailingPathDelimiter(ExpandFileName(Path.Replace('/','\')));
end;

function Within(const Path,Root:string):Boolean;
begin Result:=Path.StartsWith(Root,True); end;

procedure SetText(Obj:TJSONObject; const Name,Value:string);
begin
  var Count:=0;
  for var Pair in Obj do if Pair.JsonString.Value=Name then Inc(Count);
  if Count>1 then raise EReadError.Create('Повторяющееся поле настройки: '+Name);
  Obj.RemovePair(Name).Free; Obj.AddPair(Name,Value);
end;

constructor TCollectionTransferLayout.Create(Review:TSQLiteDatabase);
begin
  inherited Create;
  if (Review=nil) or (Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''kind''')<>
    'HomeLibre collection transfer preparation v1') then raise EArgumentException.Create('Нужен проверенный план переноса.');
  FReview:=Review;
  FDestination:=Folder(Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''destination'''));
  FContentRoot:=Folder(Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''content_root'''));
  if not Within(FContentRoot,FDestination) then raise EReadError.Create('Папка содержимого выходит за пределы назначения.');
  FRoots:=TDictionary<string,TTransferFinalRoot>.Create;
  FOrdered:=TList<TTransferFinalRoot>.Create; ReadRoots;
end;

destructor TCollectionTransferLayout.Destroy;
begin FOrdered.Free; FRoots.Free; inherited; end;

procedure TCollectionTransferLayout.ReadRoots;
var Q:TSQLiteQuery; Pending:TList<TTransferFinalRoot>;
begin
  Pending:=TList<TTransferFinalRoot>.Create;
  Q:=FReview.NewQuery('SELECT ID,InputPath,CanonicalPath,Destination FROM Roots ORDER BY ID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      var Root:TTransferFinalRoot; Root.ID:=Q.FieldAsString(0); Root.Input:=Folder(Q.FieldAsString(1));
      Root.Observed:=Q.FieldAsString(2)<>''; Root.Destination:=Q.FieldAsString(3);
      if Root.Observed then
      begin
        Root.Destination:=Folder(Root.Destination);
        if not Within(Root.Destination,FDestination) then raise EReadError.Create('Источник выходит за пределы назначения.');
        FRoots.Add(Root.ID,Root); FOrdered.Add(Root);
      end
      else Pending.Add(Root);
      if FOrdered.Count+Pending.Count>4096 then raise EReadError.Create('Слишком много папок итогового размещения.');
      Q.Next;
    end;
    Pending.Sort(TComparer<TTransferFinalRoot>.Construct(
      function(const A,B:TTransferFinalRoot):Integer
      begin Result:=Length(A.Input)-Length(B.Input); if Result=0 then Result:=CompareText(A.Input,B.Input); end));
    for var PendingRoot in Pending do
    begin
      var Root:=PendingRoot; var Mapped:string;
      if not MappedPath(Root.Input,Mapped) then
      begin
        // No observed ancestor/alias grants a shared physical layout. Reserve a
        // distinct future folder inside this operation, without probing a disk.
        Mapped:=FContentRoot+'future-'+THashSHA2.GetHashString(LowerCase(Root.Input))+'\';
      end;
      Root.Destination:=Folder(Mapped); FRoots.Add(Root.ID,Root); FOrdered.Add(Root);
    end;
    if not FRoots.ContainsKey('collection') then raise EReadError.Create('Нет исходной папки коллекции в плане.');
  finally Q.Free; Pending.Free; end;
end;

function TCollectionTransferLayout.Roots:TArray<TTransferFinalRoot>;
begin Result:=FOrdered.ToArray; end;

function TCollectionTransferLayout.RootDestination(const ID:string):string;
begin
  var Root:TTransferFinalRoot;
  if not FRoots.TryGetValue(ID,Root) then raise EReadError.Create('Неизвестный источник итогового размещения: '+ID);
  Result:=Root.Destination;
end;

function TCollectionTransferLayout.MappedPath(const Path:string; out Mapped:string):Boolean;
var Best:Integer; Normal:string;
begin
  Mapped:=''; if Path='' then Exit(False);
  Normal:=Folder(Path); Best:=0; Mapped:='';
  for var Root in FOrdered do
    if Within(Normal,Root.Input) and (Length(Root.Input)>Best) then
    begin Best:=Length(Root.Input); Mapped:=Root.Destination+Copy(Normal,Best+1,MaxInt); end;
  Result:=Best>0; if Result then Mapped:=Folder(Mapped);
end;

function TCollectionTransferLayout.RelocatePath(const Path:string):string;
begin
  if not MappedPath(Path,Result) then Result:=Path;
end;

function TCollectionTransferLayout.SourceSettings:string;
begin Result:=ProjectSources(FReview.QuerySingleString('SELECT Value FROM Context WHERE Name=''sources_json'''),True); end;

function TCollectionTransferLayout.ProjectSources(const Current:string; MoveRoots:Boolean):string;
var Data:TJSONValue; Changed:Boolean;
begin
  Result:=Current;
  if Result='' then Exit;
  Changed:=False;
  Data:=TJSONObject.ParseJSONValue(Result);
  try
    if not (Data is TJSONArray) then raise EReadError.Create('Повреждён список источников итогового размещения.');
    for var Value in TJSONArray(Data) do
    begin
      if not (Value is TJSONObject) then raise EReadError.Create('Повреждена запись источника итогового размещения.');
      var Obj:=TJSONObject(Value); var ID:=Obj.GetValue<string>('id');
      var Path:=Obj.GetValue<string>('root','');
      if MoveRoots and (Path<>'') then
      begin
        var Root:TTransferFinalRoot;
        if not FRoots.TryGetValue('source:'+ID,Root) or
          not SameFileName(Folder(Settings.ExpandCollectionRoot(Path)),Root.Input) then
          raise EReadError.Create('Папка источника не совпала с замороженным планом.');
        Changed:=Changed or (Path<>Root.Destination); SetText(Obj,'root',Root.Destination);
      end;
      if (Obj.GetValue<string>('inpx','')='') and (Obj.GetValue<Integer>('collection',-1)>0) then
      begin
        var Q:=FReview.NewQuery('SELECT r.Catalogue,f.Destination FROM ForkMembers m '+
          'JOIN CatalogueForks f ON f.ID=m.ForkID '+
          'JOIN ReferenceRegistrations r ON r.RegistrationID=m.RegistrationID WHERE m.RegistrationID=?',
          [Obj.GetValue<Integer>('collection')]);
        try
          Q.Open;
          if not Q.Eof then
          begin
            var FileName:=Obj.GetValue<string>('file','');
            if (FileName='') or not SameFileName(Settings.ExpandCollectionFileName(FileName),Q.FieldAsString(0)) then
              raise EReadError.Create('Файл исходной коллекции не совпал с замороженным планом.');
            Changed:=Changed or (FileName<>Q.FieldAsString(1)); SetText(Obj,'file',Q.FieldAsString(1));
          end;
        finally Q.Free; end;
      end;
    end;
    if Changed then Result:=Data.ToJSON;
  finally Data.Free; end;
end;

function TCollectionTransferLayout.UpdateSettings(const Current:string):string;
var Data:TJSONValue;
begin
  Result:=Current; if Current='' then Exit;
  var Validated:=ReadLibraryUpdateSources(Current);
  Data:=TJSONObject.ParseJSONValue(Current);
  try
    if not (Data is TJSONObject) then raise EReadError.Create('Повреждены настройки обновления итогового размещения.');
    var Items:=TJSONObject(Data).GetValue<TJSONArray>('sources');
    if Items.Count<>Length(Validated) then raise EReadError.Create('Не совпал список настроек обновления.');
    for var Value in Items do
    begin
      var Obj:=TJSONObject(Value); var Path:=Obj.GetValue<string>('books_root','');
      if Path<>'' then
      begin
        var Mapped:=RelocatePath(Path);
        if not SameFileName(Folder(Path),Folder(Mapped)) then SetText(Obj,'books_root',Mapped);
      end;
    end;
    Result:=Data.ToJSON;
  finally Data.Free; end;
end;

function TCollectionTransferLayout.FutureLocator(Q:TSQLiteQuery):TTransferFutureLocator;
begin
  Result:=Default(TTransferFutureLocator);
  Result.BindingID:=Q.FieldAsInt(0); Result.Kind:=Q.FieldAsInt(1); Result.BookID:=Q.FieldAsInt(2);
  Result.SourceKey:=Q.FieldAsString(9);
  var Root:TTransferFinalRoot;
  if not FRoots.TryGetValue(Q.FieldAsString(11),Root) then raise EReadError.Create('Нет будущей папки отсутствующей книги.');
  var Source:=ExpandFileName(Q.FieldAsString(10));
  if not Within(Source,Root.Input) then raise EReadError.Create('Будущий файл выходит за пределы исходного источника.');
  Result.Source:=Root.Destination+Copy(Source,Length(Root.Input)+1,MaxInt);
  if not Within(Result.Source,FDestination) then raise EReadError.Create('Будущий файл выходит за пределы назначения.');
  var Before:=Default(TBookRecord);
  Before.CollectionRoot:=Folder(FReview.QuerySingleString('SELECT Value FROM Context WHERE Name=''collection_root'''));
  Before.LibID:=Q.FieldAsString(3); Before.Folder:=Q.FieldAsString(4); Before.FileName:=Q.FieldAsString(5);
  Before.FileExt:=Q.FieldAsString(6); Before.InsideNo:=Q.FieldAsInt(7);
  if Q.FieldAsString(8)<>'' then Before.CollectionRoot:=Folder(Settings.ExpandCollectionRoot(Q.FieldAsString(8)));
  var Format:=Before.GetBookFormat(TPath.Combine(Before.CollectionRoot,Before.Folder));
  var After:=Before; After.CollectionRoot:=Root.Destination;
  if Format in [bfFb2Archive,bfRawArchive] then After.Folder:=Result.Source
  else
  begin
    After.Folder:=IncludeTrailingPathDelimiter(ExtractFileDir(Result.Source));
    After.FileName:=ExtractFileName(Result.Source);
    if Format<>bfFbd then
    begin
      if not After.FileName.EndsWith(After.FileExt,True) then raise EReadError.Create('Расширение будущего файла изменилось.');
      SetLength(After.FileName,Length(After.FileName)-Length(After.FileExt));
    end;
    if After.GetBookFormat(TPath.Combine(After.CollectionRoot,After.Folder))<>Format then
    begin
      After.Folder:=''; After.FileName:=Result.Source;
      if Format<>bfFbd then SetLength(After.FileName,Length(After.FileName)-Length(After.FileExt));
    end;
  end;
  var Container:=TPath.Combine(After.CollectionRoot,After.Folder);
  if (After.GetBookFormat(Container)<>Format) or not SameFileName(ExpandFileName(After.GetBookFileName(Container)),Result.Source) then
    raise EReadError.Create('Будущий адрес меняет способ чтения книги.');
  Result.Folder:=After.Folder; Result.FileName:=After.FileName;
  if Q.FieldAsString(8)<>'' then Result.CopyRoot:=RelocatePath(Settings.ExpandCollectionRoot(Q.FieldAsString(8)));
end;

procedure TCollectionTransferLayout.ForEachFutureLocator(const Visit:TTransferFutureVisitor);
begin
  if not Assigned(Visit) then Exit;
  var Q:=FReview.NewQuery('SELECT ID,Kind,BookID,LibID,Folder,FileName,Ext,InsideNo,Root,SourceKey,Source,RootID FROM Bindings '+
    'WHERE State=? AND FileID IS NULL AND FileName<>'''' AND Source<>'''' ORDER BY ID',[Ord(tbsMissing)]);
  try Q.Open; while not Q.Eof do begin Visit(FutureLocator(Q)); Q.Next; end;
  finally Q.Free; end;
end;

function TCollectionTransferLayout.TryMainFuture(BookID:Int64; out Locator:TTransferFutureLocator):Boolean;
begin
  Locator:=Default(TTransferFutureLocator);
  var Q:=FReview.NewQuery('SELECT ID,Kind,BookID,LibID,Folder,FileName,Ext,InsideNo,Root,SourceKey,Source,RootID FROM Bindings '+
    'WHERE Kind=0 AND BookID=? AND State=? AND FileID IS NULL AND FileName<>'''' AND Source<>''''',[BookID,Ord(tbsMissing)]);
  try Q.Open; Result:=not Q.Eof; if Result then Locator:=FutureLocator(Q);
  finally Q.Free; end;
end;

end.
