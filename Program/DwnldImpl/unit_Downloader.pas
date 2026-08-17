(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2023 Oleksiy Penkov (aka Koreec)
  *
  * Authors             Oleksiy Penkov   oleksiy.penkov@gmail.com
  *                     Nick Rymanov     nrymanov@gmail.com
  *                     Eugene Sadovoi   evgeni@eniks.com
  * Created
  * Description
  *
  * $Id: unit_Downloader.pas 1158 2014-04-17 01:26:26Z koreec $
  *
  * History
  * 2014-03-23 - Added support for generic online libraries
  * 2026-03-08 - Fixed nil callback crashes in HTTP event handlers
  *            - Fixed uninitialized archiver variable in CheckResponce
  *            - Added logging to Stop method instead of silent exception swallowing
  *            - Fixed missing Result initialization in CheckResponce
  *
  ****************************************************************************** *)

unit unit_Downloader;

interface

uses
  Windows,
  Classes,
  SysUtils,
  Dialogs,
  IdHTTP,
  IdSocks,
  IdSSLOpenSSL,
  IdURI,
  IdComponent,
  IdStack,
  IdStackConsts,
  IdWinsock2,
  IdMultipartFormData,
  unit_Globals,
  unit_Interfaces;

type
  TQueryKind = (qkGet, qkPost);

  EInvalidLogin = class(Exception);

  TCommand = record
    Code: Integer;
    Params: array of string;
  end;

  TScenarioCommands = array of TCommand;

  TSetCommentEvent = procedure(const Current, Total: string) of object;
  TProgressEvent = procedure(Current, Total: Integer) of object;

  TDownloader = class
  private
    URL: string;
    FidHTTP: TidHttp;
    FidSocksInfo: TIdSocksInfo;
    FidSSLIOHandlerSocketOpenSSL: TIdSSLIOHandlerSocketOpenSSL;

    FParams: TIdMultiPartFormDataStream;
    FResponse: TMemoryStream;

    FOnSetProgress: TProgressEvent;
    FOnSetComment: TSetCommentEvent;

    FNewURL: string;
    FNoProgress: boolean;
    Canceled: boolean;
    FDownloadSize: Integer;

    FStartDate: TDateTime;
    FIgnoreErrors: boolean;

    FFile: string;
    FErrorMessage: string;

    function AddParam(const Name: string; const Value: string): boolean;
    function Query(Kind: TQueryKind; const Uri: string): boolean;
    function CheckRedirect(): boolean;
    function CheckResponce(): boolean;
    function IsDownloadedFileValid(const FileName: string): Boolean;
    function Pause(Time: Integer): boolean;

    function DoDownload(const Collection: IBookCollection; const BookRecord: TBookRecord): boolean;

    procedure HTTPWorkBegin(ASender: TObject; AWorkMode: TWorkMode; AWorkCountMax: Int64);
    procedure HTTPWorkEnd(ASender: TObject; AWorkMode: TWorkMode);
    procedure HTTPWork(ASender: TObject; AWorkMode: TWorkMode; AWorkCount: Int64);
    procedure HTTPRedirect(Sender: TObject; var dest: string; var NumRedirect: Integer; var Handled: boolean; var VMethod: string);

    procedure ProcessError(const LongMsg, ShortMsg, AFileName: string);
    procedure ShowError;

    function ParseCommands(const scenario: string; const macros: TStrings) : TScenarioCommands;

  public
    constructor Create;
    destructor Destroy; override;

    function Download(const ASystemDB: ISystemData; const BookKey: TBookKey): boolean;
    procedure Stop;

    property IgnoreErrors: boolean read FIgnoreErrors write FIgnoreErrors;

    property OnProgress: TProgressEvent read FOnSetProgress write FOnSetProgress;
    property OnSetComment: TSetCommentEvent read FOnSetComment write FOnSetComment;
  end;

implementation

uses
  Forms,
  RTTI,
  HTTPApp,
  StrUtils,
  DateUtils,
  unit_Settings,
  dm_user,
  unit_Consts,
  unit_MHL_strings,
  unit_Messages,
  unit_Helpers,
  unit_ImportInpxThread,
  unit_MHLArchiveHelpers;

resourcestring
rstrWrongCredentials = 'Неправильный логин/пароль';
   rstrDownloadBlockedByServer = 'Загрузка файла заблокирована сервером!' + CRLF
     + 'Ответ сервера можно просмотреть в файле "server_error.html"';
   rstrBlockedByServer = 'Заблокирован сервером';
   rstrSpeed = 'Загрузка: %s Kb/s';
   rstrDownloadError = 'Ошибка закачки';
   rstrServerNotFound = 'Загрузка не удалась! Сервер не найден.';
   rstrError = 'Ошибка';
   rstrTimeout = 'Загрузка не удалась! Превышено время ожидания.';
   rstrConnectionError = 'Загрузка не удалась! Ошибка подключения.';
   rstrServerError =
     'Загрузка не удалась! Сервер сообщает об ошибке "%s".' + CRLF;
   rstrErrorCode = 'Код ошибки';

const
  CommandList: array [0 .. 5] of string = ('CHECK', 'REDIR', 'PAUSE', 'GET', 'POST', 'ADD');

  { TDownloader }

constructor TDownloader.Create;
begin
  inherited Create;

  FidHTTP := TidHttp.Create;
  FidSocksInfo := TIdSocksInfo.Create;
  FidSSLIOHandlerSocketOpenSSL := TIdSSLIOHandlerSocketOpenSSL.Create;
  FidHTTP.OnWork := HTTPWork;
  FidHTTP.OnWorkBegin := HTTPWorkBegin;
  FidHTTP.OnWorkEnd := HTTPWorkEnd;
  FidHTTP.OnRedirect := HTTPRedirect;
  FidHTTP.HandleRedirects := True;

  SetProxySettingsGlobal(FidHTTP, FidSocksInfo, FidSSLIOHandlerSocketOpenSSL);

  FIgnoreErrors := False;
end;

destructor TDownloader.Destroy;
begin
  FreeAndNil(FidSSLIOHandlerSocketOpenSSL);
  FreeAndNil(FidSocksInfo);
  FreeAndNil(FidHTTP);

  inherited Destroy;
end;

function TDownloader.AddParam(const Name: string; const Value: string): boolean;
begin
  FParams.AddFormField(Name, Value);
  Result := True;
end;

function TDownloader.CheckRedirect(): boolean;
begin
  Result := (FNewURL <> '');
  if not Result then
    raise EInvalidLogin.Create(rstrWrongCredentials);
end;

function TDownloader.CheckResponce(): boolean;
const
  RESPONSE_SNIFF_SIZE = 4096;
var
  Path: string;
  PartFile: string;
  Header: AnsiString;
  HeaderLower: string;
  BytesToRead: Integer;
begin
  Result := False;
  Path := ExtractFileDir(FFile);
  CreateFolders('', Path);
  FResponse.Position := 0;

  // Only the beginning is needed to recognize an HTML/text error. Loading a
  // complete FB2/ZIP into TStringList duplicated every download in memory and
  // decoded binary data as text before it could be saved.
  if FResponse.Size > RESPONSE_SNIFF_SIZE then
    BytesToRead := RESPONSE_SNIFF_SIZE;
  else
    BytesToRead := Integer(FResponse.Size);
  if BytesToRead <= 0 then
    Exit;

  SetLength(Header, BytesToRead);
  FResponse.ReadBuffer(Header[1], BytesToRead);
  HeaderLower := LowerCase(string(Header));

  if (Pos('<!doctype', HeaderLower) <> 0) or
     (Pos('overload', HeaderLower) <> 0) or
     (Pos('not found', HeaderLower) <> 0) then
  begin
    ProcessError(rstrDownloadBlockedByServer, rstrBlockedByServer, FFile);
    FResponse.Position := 0;
    FResponse.SaveToFile(Settings.SystemFileName[sfServerErrorLog]);
  end
  else
  begin
    // Keep an interrupted or invalid response away from the final file.
    // Retaining the real extension allows archive validation before rename.
    PartFile := ChangeFileExt(FFile, '.part' + ExtractFileExt(FFile));
    if FileExists(PartFile) then
      DeleteFile(PartFile);
    try
      FResponse.Position := 0;
      FResponse.SaveToFile(PartFile);
      Result := IsDownloadedFileValid(PartFile);
      if Result then
      begin
        if FileExists(FFile) then
        begin
          Result := IsDownloadedFileValid(FFile);
          if not Result and DeleteFile(FFile) then
            Result := RenameFile(PartFile, FFile);
        end
        else
          Result := RenameFile(PartFile, FFile);
      end;
    finally
      if FileExists(PartFile) then
        DeleteFile(PartFile);
    end;
  end;
end;

function TDownloader.IsDownloadedFileValid(const FileName: string): Boolean;
var
  FileStream: TFileStream;
  archiver: TMHLZip;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;

  try
    FileStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
    try
      Result := FileStream.Size > 0;
    finally
      FileStream.Free;
    end;
  except
    Exit(False);
  end;

  if Result and IsArchiveExt(FileName) then
  begin
    archiver := nil;
    try
      try
        archiver := TMHLZip.Create(FileName, True);
        Result := archiver.Test(FileName);
      except
        Result := False;
      end;
    finally
      archiver.Free;
    end;
  end;
end;

function TDownloader.Download(const ASystemDB: ISystemData; const BookKey: TBookKey): boolean;
var
  Collection: IBookCollection;
  BookRecord: TBookRecord;
begin
  Result := False;

  Collection := ASystemDB.GetCollection(BookKey.DatabaseID);
  Collection.GetBookRecord(BookKey, BookRecord, False);

  FFile := BookRecord.GetBookFileName;
  if IsDownloadedFileValid(FFile) or DoDownload(Collection, BookRecord) then
  begin
    Collection.SetLocal(BookKey, True);
    unit_Messages.BookLocalStatusChanged(BookKey, True);
    Result := True;
  end;
end;

procedure TDownloader.HTTPRedirect(Sender: TObject; var dest: string; var NumRedirect: Integer; var Handled: boolean; var VMethod: string);
begin
  if EndsText(FB2ZIP_EXTENSION, dest) then
    FNewURL := dest
  else
    FNewURL := '';
end;

procedure TDownloader.HTTPWork(ASender: TObject; AWorkMode: TWorkMode; AWorkCount: Int64);
var
  ElapsedTime: Cardinal;
  Speed: string;
begin
  if FNoProgress then
    Exit;

  if Canceled then
  begin
    FidHTTP.Disconnect;
    Exit;
  end;

  if (FDownloadSize <> 0) and Assigned(FOnSetProgress) then
    FOnSetProgress(AWorkCount * 100 div FDownloadSize, -1);

  ElapsedTime := SecondsBetween(Now, FStartDate);
  if ElapsedTime > 0 then
  begin
    Speed := FormatFloat('0.00', AWorkCount / 1024 / ElapsedTime);
    if Assigned(FOnSetComment) then
      FOnSetComment(Format(rstrSpeed, [Speed]), '');
  end;
end;

procedure TDownloader.HTTPWorkBegin(ASender: TObject; AWorkMode: TWorkMode; AWorkCountMax: Int64);
begin
  if FNoProgress then
    Exit;
  FDownloadSize := AWorkCountMax;
  FStartDate := Now;
  if Assigned(FOnSetProgress) then
    FOnSetProgress(1, -1);
end;

procedure TDownloader.HTTPWorkEnd(ASender: TObject; AWorkMode: TWorkMode);
begin
  if FNoProgress then
    Exit;
  if Assigned(FOnSetProgress) then
    FOnSetProgress(100, -1);
  if Assigned(FOnSetComment) then
    FOnSetComment(rstrReadyMessage, '');
end;

function TDownloader.DoDownload(const Collection: IBookCollection; const BookRecord: TBookRecord): boolean;
var
  ctx: TRttiContext;
  ConstParams: TStringList;
  Commands: TScenarioCommands;
  field: TRttiField;
  data, name: string;
  i: Integer;

begin
  Result := False;
  FNewURL := '';
  ConstParams := nil;
  FParams := nil;
  FResponse := nil;
  ctx := Default(TRttiContext);

  try
    ctx := TRttiContext.Create;
    ConstParams := TStringList.Create;
    FParams := TIdMultiPartFormDataStream.Create;

    // Add macro from collection info
    ConstParams.Values['%USER%'] := Collection.GetProperty(PROP_LIBUSER);
    ConstParams.Values['%PASS%'] := Collection.GetProperty(PROP_LIBPASSWORD);
    ConstParams.Values['%URL%'] := Collection.GetProperty(PROP_URL);

    // Build macro dictionary from book info
    for field in ctx.GetType(TypeInfo(TBookRecord)).GetFields do
    begin
      if (nil <> field) and (nil <> field.FieldType) and
        (('string' = field.FieldType.Name) or ('Integer' = field.FieldType.Name))
      then
      begin
        name := '%' + UpperCase(field.Name) + '%';
        if ('%FOLDER%' = name) or ('%COLLECTIONROOT%' = name) then
          begin
            data := DosPathToUnixPath(field.GetValue(Addr(BookRecord)).ToString());
          end
        else
          data := field.GetValue(Addr(BookRecord)).ToString();

        ConstParams.Values[name] := data;
      end;
    end;

    // Execute scenario
    Commands := ParseCommands(Collection.GetProperty(PROP_CONNECTIONSCRIPT), ConstParams);
    FResponse := TMemoryStream.Create;
    for i := 0 to Length(Commands) - 1 do
    begin
      if Canceled then
      begin
        Result := False;
        Break;
      end;

      case Commands[i].Code of
        0: Result := CheckResponce;
        1: Result := CheckRedirect;
        2: Result := Pause(StrToInt(Commands[i].Params[0]));
        3: Result := Query(qkGet, Commands[i].Params[0]);
        4: Result := Query(qkPost, Commands[i].Params[0]);
        5: Result := AddParam(Commands[i].Params[0], Commands[i].Params[1]);
      end;

      if not Result then
        Break;
    end;
    Result := Result and (not Canceled) and IsDownloadedFileValid(FFile);

  finally
    FreeAndNil(FResponse);
    FreeAndNil(FParams);
    ctx.Free;
    ConstParams.Free;
  end;
end;

function TDownloader.ParseCommands(const scenario: string; const macros: TStrings): TScenarioCommands;
var
  parameters: TStringList;
  commandStr: TStringList;
  data, command: string;
  commnadIndx: Integer;
  commnadType: Integer;
  index, param: Integer;
  Commands: TScenarioCommands;

begin
  parameters := nil;
  commandStr := nil;
  try
    parameters := TStringList.Create;
    commandStr := TStringList.Create;

    // Parse each command in scenario
    commandStr.Text := scenario;
    SetLength(Commands, commandStr.Count);
    for commnadIndx := 0 to (commandStr.Count - 1) do
    begin
      Commands[commnadIndx].Code := -1;

      // Get command
      data := commandStr[commnadIndx];
      index := Pos(' ', data);
      if index <> 0 then
      begin
        command := Copy(data, 1, index - 1);
        Delete(data, 1, index);
      end
      else
        command := data;

      // Identify and process command
      for commnadType := 0 to (Length(CommandList) - 1) do
      begin
        if CommandList[commnadType] = command then
        begin
          Commands[commnadIndx].Code := commnadType;

          case commnadType of
            0 .. 1: // 'CHECK', 'REDIR'  - no parameters
              SetLength(Commands[commnadIndx].Params, 0);

            2: // 'PAUSE' - just one parameter
              begin
                SetLength(Commands[commnadIndx].Params, 1);
                Commands[commnadIndx].Params[0] := data;
              end;

            3 .. 4: // 'GET', 'POST' - just one parameter
              begin
                // Replace all macros
                for index := 0 to macros.Count - 1 do
                  StrReplace(macros.Names[index],
                    macros.ValueFromIndex[index], data);
                // Save parameter
                SetLength(Commands[commnadIndx].Params, 1);
                Commands[commnadIndx].Params[0] := data;
              end;

          else // ADD and etc. - space delimited parameters
            begin
              parameters.Clear();
              ExtractStrings([' '], [], PWideChar(data), parameters);
              SetLength(Commands[commnadIndx].Params, parameters.Count);
              for param := 0 to parameters.Count - 1 do
              begin
                data := parameters[param];
                // Replace all macros
                for index := 0 to macros.Count - 1 do
                  StrReplace(macros.Names[index],
                    macros.ValueFromIndex[index], data);
                // Save parameter
                Commands[commnadIndx].Params[param] := data;
              end;
            end;
          end;

          Break;
        end;
      end;
    end;

  Result := Commands;

  finally
    FreeAndNil(parameters);
    FreeAndNil(commandStr);
  end;
end;

function TDownloader.Pause(Time: Integer): boolean;
const
  PAUSE_SLICE_MS = 100;
var
  Delay: Integer;
begin
  while (Time > 0) and not Canceled do
  begin
    Delay := Time;
    if Delay > PAUSE_SLICE_MS then
      Delay := PAUSE_SLICE_MS;
    Sleep(Delay);
    Dec(Time, Delay);
  end;
  Result := not Canceled;
end;

procedure TDownloader.ProcessError(const LongMsg, ShortMsg, AFileName: string);
var
  F: Text;
  FileName: string;
begin
  if Settings.ErrorLog then
  begin
    FileName := Settings.SystemFileName[sfDownloadErrorLog];
    AssignFile(F, FileName);
    if FileExists(FileName) then
      Append(F)
    else
      Rewrite(F);
    try
      Writeln(F, Format('%s %s >> %s', [DateTimeToStr(Now), ShortMsg,
        AFileName]));
    finally
      CloseFile(F);
    end;
  end;
  if not FIgnoreErrors and not Canceled then
  begin
    FErrorMessage := LongMsg + {$IFDEF LINUX} AnsiChar(#10) {$ENDIF}
      {$IFDEF MSWINDOWS} AnsiString(CRLF) {$ENDIF} + URL;
    TThread.Synchronize(nil, ShowError);
  end;
end;

procedure TDownloader.ShowError;
begin
  Application.MessageBox(PChar(FErrorMessage), PChar(rstrDownloadError));
end;

function TDownloader.Query(Kind: TQueryKind; const Uri: string): boolean;
begin
  Result := False;

  URL := Uri;
  // Add result of last operation
  StrReplace('%RESURL%', FNewURL, URL);

  // A scenario can issue multiple HTTP commands. Indy writes at the current
  // stream position, so an old response must never be left in the buffer.
  FResponse.Size := 0;
  FResponse.Position := 0;

  try
    case Kind of
      qkGet:
        begin
          FNoProgress := False;
          FidHTTP.Get(TIdURI.URLEncode(URL), FResponse);
        end;

      qkPost:
        begin
          FNoProgress := True;
          FidHTTP.Post(TIdURI.URLEncode(URL), FParams, FResponse);
        end;
    end;
    Result := True;
  except
    on E: EIdSocketError do
      if Canceled then
        Result := False
      else if not FIgnoreErrors then
      begin
        case E.LastError of
          WSAHOST_NOT_FOUND:
            ProcessError(rstrServerNotFound,
              rstrError + IntToStr(E.LastError), FFile);

          Id_WSAETIMEDOUT:
            ProcessError(rstrTimeout, rstrError + IntToStr(E.LastError), FFile);
        else
          ProcessError(rstrConnectionError,
            rstrError + IntToStr(E.LastError), FFile);
        end; // case
      end;

    on E: Exception do
      if Canceled then
        Result := False
      else if (FidHTTP.ResponseCode <> 405) and
        not((FidHTTP.ResponseCode = 404) and (FNewURL <> '')) then
        ProcessError(Format(rstrServerError, [E.Message]),
          rstrErrorCode + IntToStr(FidHTTP.ResponseCode), FFile)
      else
        Result := True;
  end; // try ... except
end;

procedure TDownloader.Stop;
begin
  Canceled := True;
  try
    FidHTTP.Disconnect;
  except
    on E: Exception do
      ; // Disconnect errors during forced stop are expected and non-fatal
  end;
end;

end.
