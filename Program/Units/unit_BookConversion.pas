unit unit_BookConversion;

interface

uses System.SysUtils, System.Classes;

// Source streams remain owned by the caller. Output is published only after a
// complete conversion; an existing output file is never replaced.
function IsBasicConversionSource(const Extension: string): Boolean;
procedure ConvertBasicBook(const AppPath, TempRoot, SourceFile, SourceExtension,
  TargetFile: string; Source: TStream; Warnings: TStrings;
  const IsCanceled: TFunc<Boolean> = nil; const Title: string = '';
  const Author: string = ''; const Language: string = '');

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, unit_MHLExternalTools, unit_ReaderDOC;

function IsBasicConversionSource(const Extension: string): Boolean;
begin
  Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|',
    '|fb2|epub|fb3|txt|html|htm|xhtml|rtf|docx|odt|doc|dot|md|markdown|mobi|azw|azw3|prc|')>0;
end;

procedure ConvertBasicBook(const AppPath, TempRoot, SourceFile, SourceExtension,
  TargetFile: string; Source: TStream; Warnings: TStrings;
  const IsCanceled: TFunc<Boolean>; const Title, Author, Language: string);
var Work, InputName, OutputName, ReportName, Tool, Script, TargetTemporary: string;
  Input, Writer: TStream; SavedPosition: Int64; Log: TStringStream;
  Started, DOCStarted: UInt64; Report: TJSONValue; ArrayValue: TJSONValue; I: Integer;
  Extension, TargetExtension: string; Check: TProc;
begin
  Extension:=LowerCase(SourceExtension); TargetExtension:=LowerCase(ExtractFileExt(TargetFile));
  if not IsBasicConversionSource(Extension) or
     not ((TargetExtension='.fb2') or (TargetExtension='.epub')) then
    raise Exception.Create('Этот формат пока не поддерживается конвертером FB2/EPUB.');
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
    if IsDirectDOCFormat(Extension) then
    begin
      var DOCReader:=FindDirectDOCReader;
      if DOCReader='' then raise Exception.Create('Не найден встроенный компонент DocSharp для DOC. Проверьте полный пакет программы.');
      var DOCXName:=TPath.Combine(Work,'prepared.docx'); DOCStarted:=GetTickCount64;
      try
        RunExternalToolToStream(DOCReader,[InputName,DOCXName],Log,
          function: Boolean
          begin
            Check; Result:=False;
            if GetTickCount64-DOCStarted>30000 then raise Exception.Create('Чтение DOC превысило 30 секунд.');
          end,0,True,384*1024*1024);
      except
        on E: EMHLExternalToolError do
        begin
          if Log.DataString.Contains('ERROR PASSWORD') then
            raise Exception.Create('Этот DOC защищён паролем. Конвертация не выполнена.')
          else if Log.DataString.Contains('ERROR OLD') then
            raise Exception.Create('Этот DOC создан в Word 95 или более старой версии. Такой вариант пока не поддерживается.')
          else raise Exception.Create('DocSharp не смог прочитать DOC. Возможно, файл повреждён или использует неподдерживаемый вариант формата.');
        end;
      end;
      if not FileExists(DOCXName) then raise Exception.Create('Компонент DocSharp не смог прочитать этот DOC.');
      InputName:=DOCXName; Extension:='.docx'; Log.Clear;
    end;
    if Extension=TargetExtension then TFile.Copy(InputName,OutputName,False)
    else
      try
        var Arguments:=TArray<string>.Create('-I','-B','-X','utf8',Script,InputName,OutputName,'--report',ReportName,
          '--title',Title,'--author',Author,'--language',Language);
        if ((Extension='.html') or (Extension='.htm') or (Extension='.xhtml') or (Extension='.md') or (Extension='.markdown')) and
          SameText(ExtractFileExt(SourceFile),Extension) then
          Arguments:=Arguments+TArray<string>.Create('--resource-root',ExtractFilePath(TPath.GetFullPath(SourceFile)));
        RunExternalToolToStream(Tool,Arguments,Log,
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
