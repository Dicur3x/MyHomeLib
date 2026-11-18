unit unit_ReaderHistoryEvidence;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections;

type
  // Read-only evidence for legacy relative/absolute history-name variants.
  // Existing profile files are held against replacement during this writer.
  TReaderHistoryEvidence=class
  private
    FNames:TDictionary<string,Boolean>;
    FFiles:TObjectList<TFileStream>;
    FAbsent:TStringList;
    FLoaded:Boolean;
    function Hold(const FileName:string):Boolean;
    procedure Load;
  public
    constructor Create;
    destructor Destroy; override;
    function Contains(const HistoryName:string):Boolean;
    procedure CheckStable;
  end;

implementation

uses System.IniFiles, System.IOUtils, System.Hash, System.StrUtils, Winapi.Windows, unit_Settings, dm_user,
  unit_ReaderAnnotations, unit_ZipMemberDeletion;

function HistoryFilePresent(const FileName:string):Boolean;
begin
  var Attributes:=GetFileAttributes(PChar(DeletionNativePath(FileName)));
  if Attributes=INVALID_FILE_ATTRIBUTES then
  begin
    var Code:=GetLastError;
    if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
    Exit(False);
  end;
  if (Attributes and FILE_ATTRIBUTE_DIRECTORY)<>0 then
    raise EReadError.Create('Вместо файла истории чтения найдена папка.');
  Result:=True;
end;

constructor TReaderHistoryEvidence.Create;
begin
  inherited Create; FNames:=TDictionary<string,Boolean>.Create;
  FFiles:=TObjectList<TFileStream>.Create; FAbsent:=TStringList.Create;
end;

destructor TReaderHistoryEvidence.Destroy;
begin FAbsent.Free; FFiles.Free; FNames.Free; inherited; end;

function TReaderHistoryEvidence.Hold(const FileName:string):Boolean;
begin
  Result:=HistoryFilePresent(FileName);
  if not Result then begin FAbsent.Add(FileName); Exit; end;
  var Stream:=TFileStream.Create(DeletionNativePath(FileName),fmOpenRead or fmShareDenyWrite);
  try
    if Stream.Size>64*1024*1024 then
      raise EReadError.Create('Файл истории чтения слишком велик для безопасного сопоставления.');
    FFiles.Add(Stream); Stream:=nil;
  finally Stream.Free; end;
end;

procedure TReaderHistoryEvidence.Load;
var Ini:TMemIniFile; Sections,Keys:TStringList; Notes:TReaderAnnotations;
begin
  if FLoaded then Exit;
  // Same read precedence as ResolveReaderSettingsFile, without migration or writes.
  var FileName:=TPath.Combine(Settings.DataDir,'reader.ini');
  var Present:=Hold(FileName);
  if not Present then
  begin
    var Legacy:=ExcludeTrailingPathDelimiter(Settings.DataDir)+'reader.ini';
    if Hold(Legacy) then begin FileName:=Legacy; Present:=True; end;
  end;
  if Present then
  begin
    Ini:=TMemIniFile.Create(FileName,TEncoding.UTF8); Sections:=TStringList.Create; Keys:=TStringList.Create;
    try
      Ini.ReadSections(Sections);
      for var Section in Sections do
      begin
        var Identity:=''; var Lower:=LowerCase(Section);
        if Lower.StartsWith('bookmarks.') then Identity:=Copy(Lower,11,MaxInt)
        else if Lower.StartsWith('book.') then
        begin
          Ini.ReadSection(Section,Keys);
          for var Key in Keys do
            // Registry-only metadata does not represent another saved position.
            if not MatchText(Key,['CollectionID','CatalogBookID','LibID','PhysicalIdentity','Title','Library']) then
            begin Identity:=Copy(Lower,6,MaxInt); Break; end;
        end;
        if Length(Identity)=40 then FNames.AddOrSetValue(Identity,True);
      end;
    finally Keys.Free; Sections.Free; Ini.Free; end;
  end;
  var NotesFile:=TPath.Combine(ExtractFileDir(FileName),'reader-notes.json');
  if Hold(NotesFile) then
  begin
    Notes:=TReaderAnnotations.Create(FileName);
    try for var Note in Notes.Items do FNames.AddOrSetValue(LowerCase(Note.BookID),True);
    finally Notes.Free; end;
  end
  else if Hold(NotesFile+'.bak') then
    raise EReadError.Create('Основной файл заметок не найден; сохранённую копию нужно восстановить до переноса.');
  FLoaded:=True; CheckStable;
end;

procedure TReaderHistoryEvidence.CheckStable;
begin
  for var FileName in FAbsent do
    if HistoryFilePresent(FileName) then
      raise EReadError.Create('История чтения изменилась во время переноса. Повторите операцию после закрытия читалки.');
end;

function TReaderHistoryEvidence.Contains(const HistoryName:string):Boolean;
begin
  Load; CheckStable;
  Result:=FNames.ContainsKey(LowerCase(Copy(THashSHA2.GetHashString(HistoryName),1,40)));
end;

end.
