unit unit_BookConversion;

interface

uses System.SysUtils, System.Classes;

// Source streams remain owned by the caller. Output is published only after a
// complete conversion; an existing output file is never replaced.
procedure ConvertBasicBook(const AppPath, TempRoot, SourceFile, SourceExtension,
  TargetFile: string; Source: TStream; Warnings: TStrings;
  const IsCanceled: TFunc<Boolean> = nil);

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, unit_MHLExternalTools;

procedure ConvertBasicBook(const AppPath, TempRoot, SourceFile, SourceExtension,
  TargetFile: string; Source: TStream; Warnings: TStrings;
  const IsCanceled: TFunc<Boolean>);
var Work, InputName, OutputName, ReportName, Tool, Script, TargetTemporary: string;
  Input, Writer: TStream; SavedPosition: Int64; Log: TStringStream;
  Started: UInt64; Report: TJSONValue; ArrayValue: TJSONValue; I: Integer;
  Extension, TargetExtension: string; Check: TProc;
begin
  Extension:=LowerCase(SourceExtension); TargetExtension:=LowerCase(ExtractFileExt(TargetFile));
  if not ((Extension='.fb2') or (Extension='.epub')) or
     not ((TargetExtension='.fb2') or (TargetExtension='.epub')) then
    raise Exception.Create('Пока доступна конвертация FB2 и EPUB друг в друга.');
  if FileExists(TargetFile) then raise Exception.Create('Файл результата уже существует. Выберите другое имя.');
  if Assigned(Warnings) then Warnings.Clear;
  Tool:=TPath.Combine(AppPath,'tools\kindle\python\python.exe');
  Script:=TPath.Combine(AppPath,'tools\bookconvert\convert_book.py');
  if not FileExists(Tool) or not FileExists(Script) then
    raise Exception.Create('Не найден встроенный конвертер FB2/EPUB. Проверьте комплектность программы.');
  Work:=TPath.Combine(TPath.GetFullPath(TempRoot),'homelib-convert-'+TGUID.NewGuid.ToString);
  ForceDirectories(Work);
  InputName:=TPath.Combine(Work,'source'+Extension);
  OutputName:=TPath.Combine(Work,'result'+TargetExtension);
  ReportName:=TPath.Combine(Work,'report.json');
  TargetTemporary:=''; Log:=TStringStream.Create('',TEncoding.UTF8);
  Started:=GetTickCount64;
  Check:=procedure
    begin
      if Assigned(IsCanceled) and IsCanceled() then raise EAbort.Create('Конвертация отменена.');
      if GetTickCount64-Started>180000 then
        raise Exception.Create('Конвертация превысила допустимое время. Исходная книга сохранена.');
    end;
  try
    Check;
    Input:=Source;
    if not Assigned(Input) then Input:=TFileStream.Create(SourceFile,fmOpenRead or fmShareDenyWrite);
    try
      if Input.Size>64*1024*1024 then raise Exception.Create('Книга превышает предел конвертации (64 МБ).');
      SavedPosition:=Input.Position;
      try
        Input.Position:=0; Writer:=TFileStream.Create(InputName,fmCreate);
        try Writer.CopyFrom(Input,Input.Size); finally Writer.Free; end;
      finally Input.Position:=SavedPosition; end;
    finally if not Assigned(Source) then Input.Free; end;
    Check;
    if Extension=TargetExtension then TFile.Copy(InputName,OutputName,False)
    else
      try
        RunExternalToolToStream(Tool,['-I','-B','-X','utf8',Script,InputName,OutputName,'--report',ReportName],Log,
          function: Boolean begin Check; Result:=False; end,0,True,512*1024*1024);
      except
        on E: EMHLExternalToolError do
        begin
          if FileExists(ReportName) then
          begin
            Report:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ReportName,TEncoding.UTF8));
            try
              if (Report is TJSONObject) and (TJSONObject(Report).GetValue('error')<>nil) then
                raise Exception.Create(TJSONObject(Report).GetValue('error').Value);
            finally Report.Free; end;
          end;
          raise;
        end;
      end;
    Check;
    if not FileExists(OutputName) then raise Exception.Create('Конвертер не создал книгу.');
    if Assigned(Warnings) and FileExists(ReportName) then
    begin
      Report:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ReportName,TEncoding.UTF8));
      try
        if Report is TJSONObject then
        begin
          ArrayValue:=TJSONObject(Report).GetValue('warnings');
          if ArrayValue is TJSONArray then
            for I:=0 to TJSONArray(ArrayValue).Count-1 do Warnings.Add(TJSONArray(ArrayValue).Items[I].Value);
        end;
      finally Report.Free; end;
    end;
    ForceDirectories(ExtractFilePath(TPath.GetFullPath(TargetFile)));
    TargetTemporary:=TargetFile+'.homelib-new-'+TGUID.NewGuid.ToString;
    TFile.Copy(OutputName,TargetTemporary,False);
    with TFileStream.Create(TargetTemporary,fmOpenReadWrite or fmShareDenyWrite) do
      try if not FlushFileBuffers(Handle) then RaiseLastOSError; finally Free; end;
    Check;
    if not MoveFile(PChar(TargetTemporary),PChar(TargetFile)) then RaiseLastOSError;
    TargetTemporary:='';
  finally
    if (TargetTemporary<>'') and FileExists(TargetTemporary) then TFile.Delete(TargetTemporary);
    Log.Free;
    if Work.StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(TempRoot)),True) and
      DirectoryExists(Work) and (GetFileAttributes(PChar(Work)) and FILE_ATTRIBUTE_REPARSE_POINT=0) then
      TDirectory.Delete(Work,True);
  end;
end;

end.
