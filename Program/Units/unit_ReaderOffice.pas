unit unit_ReaderOffice;

interface

uses System.SysUtils;

function IsOfficeReaderFormat(const Extension: string): Boolean;
function FindReaderOffice: string;
function PrepareOfficeReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.NetEncoding,
  System.Win.Registry, Winapi.Windows, unit_BookCache, unit_MHLExternalTools,
  unit_Settings, dm_user;

function IsOfficeReaderFormat(const Extension: string): Boolean;
begin
  Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|',
    '|doc|docm|dot|wps|wpd|ppt|pptx|pptm|pps|ppsx|odp|xls|xlsx|ods|')>0;
end;

procedure DeleteConversionDirectory(const Directory: string);
var Data: TWin32FindData; Search: THandle; Child: string;
begin
  // Office profiles contain paths beyond MAX_PATH. Use the Unicode Windows
  // functions with an extended absolute path; never follow directory links.
  Search:=FindFirstFile(PChar(IncludeTrailingPathDelimiter(Directory)+'*'),Data);
  if Search<>INVALID_HANDLE_VALUE then
  try
    repeat
      if (string(Data.cFileName)='.') or (string(Data.cFileName)='..') then Continue;
      Child:=IncludeTrailingPathDelimiter(Directory)+string(Data.cFileName);
      if Data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY<>0 then
      begin
        if Data.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT=0 then
          DeleteConversionDirectory(Child)
        else if not RemoveDirectory(PChar(Child)) then RaiseLastOSError;
      end
      else
      begin
        if Data.dwFileAttributes and FILE_ATTRIBUTE_READONLY<>0 then
          if not SetFileAttributes(PChar(Child),Data.dwFileAttributes and not FILE_ATTRIBUTE_READONLY) then RaiseLastOSError;
        if not DeleteFile(PChar(Child)) then RaiseLastOSError;
      end;
    until not FindNextFile(Search,Data);
    if GetLastError<>ERROR_NO_MORE_FILES then RaiseLastOSError;
  finally Winapi.Windows.FindClose(Search); end
  else if GetLastError<>ERROR_FILE_NOT_FOUND then RaiseLastOSError;
  if not RemoveDirectory(PChar(Directory)) then RaiseLastOSError;
end;

function FindReaderOffice: string;
const Roots: array[0..1] of HKEY = (HKEY_CURRENT_USER,HKEY_LOCAL_MACHINE);
  Views: array[0..1] of Cardinal = (KEY_READ or KEY_WOW64_64KEY,KEY_READ or KEY_WOW64_32KEY);
var Registry: TRegistry; Root: HKEY; Flags: Cardinal; Candidate, Base: string;
begin
  Result:='';
  for Base in [GetEnvironmentVariable('ProgramW6432'),GetEnvironmentVariable('ProgramFiles'),GetEnvironmentVariable('ProgramFiles(x86)')] do
  begin
    if Base='' then Continue;
    Candidate:=TPath.Combine(Base,'LibreOffice\program\soffice.com');
    if FileExists(Candidate) then Exit(Candidate);
  end;
  for Root in Roots do for Flags in Views do
  begin
    Registry:=TRegistry.Create(Flags);
    try
      Registry.RootKey:=Root;
      if Registry.OpenKeyReadOnly('\Software\Microsoft\Windows\CurrentVersion\App Paths\soffice.exe') then
      begin
        Candidate:=TPath.Combine(ExtractFilePath(Registry.ReadString('').Trim(['"'])),'soffice.com');
        if FileExists(Candidate) then Exit(Candidate);
      end;
    finally Registry.Free; end;
  end;
end;

function PrepareOfficeReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Tool, Work, Profile, WorkingInput, Converted, Stamp, StampFile, Temporary, TemporaryStamp, ProfileURI: string;
  Input, CopyStream: TStream; Writer: TBookCacheWrite; Log: TStringStream;
  Attributes, ToolAttributes: TWin32FileAttributeData; Started: UInt64; Header: array[0..4] of AnsiChar; Attempt: Integer;
begin
  Result:=SourceFile;
  if not IsOfficeReaderFormat(ExtractFileExt(SourceFile)) then Exit;
  if Assigned(IsCanceled) and IsCanceled() then Abort;
  Tool:=FindReaderOffice;
  if Tool='' then raise Exception.Create('Для чтения этого документа во встроенной читалке нужен установленный LibreOffice. Можно открыть его внешней программой.');
  Input:=OpenCachedBookFile(SourceFile);
  try
    if not GetFileAttributesEx(PChar(SourceFile),GetFileExInfoStandard,@Attributes) or
      not GetFileAttributesEx(PChar(Tool),GetFileExInfoStandard,@ToolAttributes) then RaiseLastOSError;
    Stamp:='office-pdf-v1|'+SourceFile+'|'+IntToStr(Input.Size)+'|'+
      IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime)+'|'+
      Tool+'|'+IntToStr(ToolAttributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(ToolAttributes.ftLastWriteTime.dwLowDateTime);
    Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-office-'+Copy(THashSHA2.GetHashString(SourceFile),1,32)+'.pdf'));
    StampFile:=Result+'.source';
    if FileExists(Result) and FileExists(StampFile) then
      try
        if TFile.ReadAllText(StampFile,TEncoding.UTF8)=Stamp then
        begin RegisterBookCacheFile(Result,OriginalSource); if Assigned(OnStage) then OnStage('Открытие документа из кэша…'); Exit; end;
      except end;
    if Assigned(OnStage) then OnStage('Подготовка документа к чтению (LibreOffice)…');
    ForceDirectories(ExtractFileDir(Result));
    Writer:=TBookCacheWrite.Create(OriginalSource); Log:=TStringStream.Create('',TEncoding.UTF8);
    Work:=TPath.Combine(Settings.TempDir,'homelib-office-'+TGUID.NewGuid.ToString);
    try
      Profile:=TPath.Combine(Work,'profile'); ForceDirectories(Profile);
      WorkingInput:=TPath.Combine(Work,ExtractFileName(SourceFile));
      CopyStream:=TFileStream.Create(WorkingInput,fmCreate);
      try Input.Position:=0; CopyStream.CopyFrom(Input,0); finally CopyStream.Free; end;
      // A private conversion profile cannot reuse or alter an open Office session.
      TFile.WriteAllText(TPath.Combine(Profile,'registrymodifications.xcu'),
        '<?xml version="1.0" encoding="UTF-8"?><oor:items xmlns:oor="http://openoffice.org/2001/registry">'+
        '<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>'+
        '<prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item></oor:items>',TEncoding.UTF8);
      // LibreOffice expands bootstrap variables introduced by '$', including
      // the application's local $tmp folder. Encode it as a path character.
      ProfileURI:='file:///'+TNetEncoding.URL.Encode(TPath.GetFullPath(Profile).Replace('\','/')).Replace('+','%20').Replace('%2F','/').Replace('%3A',':').Replace('$','%24');
      Started:=GetTickCount64;
      RunExternalToolToStream(Tool,['-env:UserInstallation='+ProfileURI,'--headless','--nologo','--nodefault','--norestore',
        '--convert-to','pdf','--outdir',Work,WorkingInput],Log,
        function: Boolean
        begin
          Result:=Assigned(IsCanceled) and IsCanceled();
          if GetCurrentThreadID<>MainThreadID then Result:=Result or TThread.CheckTerminated;
          if GetTickCount64-Started>60000 then raise Exception.Create('Подготовка документа превысила минуту. Откройте его внешней офисной программой.');
        end,0,True);
      Converted:=TPath.Combine(Work,ChangeFileExt(ExtractFileName(SourceFile),'.pdf'));
      if not FileExists(Converted) then raise Exception.Create('LibreOffice не смог подготовить этот документ для чтения. Возможно, он повреждён или защищён паролем.');
      with TFileStream.Create(Converted,fmOpenRead or fmShareDenyWrite) do
      try
        if Size<5 then raise Exception.Create('LibreOffice создал пустой результат.');
        ReadBuffer(Header,SizeOf(Header));
        if (Header[0]<>'%') or (Header[1]<>'P') or (Header[2]<>'D') or (Header[3]<>'F') or (Header[4]<>'-') then
          raise Exception.Create('Результат подготовки не является PDF.');
      finally Free; end;
      Temporary:=Writer.TemporaryName(Result); TemporaryStamp:=Writer.TemporaryName(StampFile);
      TFile.Copy(Converted,Temporary,True); TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8);
      Writer.Publish(Temporary,Result,TemporaryStamp);
    finally
      try
        if TPath.GetFullPath(Work).StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(Settings.TempDir)),True) and
          DirectoryExists(Work) and (GetFileAttributes(PChar(Work)) and FILE_ATTRIBUTE_REPARSE_POINT=0) then
          for Attempt:=0 to 19 do
          begin
            try
              if Work.StartsWith('\\') then
                DeleteConversionDirectory('\\?\UNC\'+Copy(TPath.GetFullPath(Work),3,MaxInt))
              else DeleteConversionDirectory('\\?\'+TPath.GetFullPath(Work));
              Break;
            except
              // Closing the conversion job terminates its child processes;
              // their profile handles can take a moment to be released.
              if Attempt<19 then Sleep(50);
            end;
          end;
      except end;
      Log.Free; Writer.Free;
    end;
  finally Input.Free; end;
end;

end.
