{******************************************************************************}
{                                                                              }
{ MyHomeLib                                                                    }
{                                                                              }
{ Version 0.9                                                                  }
{ 20.08.2008                                                                   }
{ Copyright (c) Oleksiy Penkov  oleksiy.penkov@gmail.com                          }
{                                                                              }
{ @author Nick Rymanov nrymanov@gmail.com                                      }
{                                                                              }
{******************************************************************************}

unit frame_NCWDownload;

interface

uses
  Windows,
  Messages,
  Variants,
  Classes,
  Graphics,
  Controls,
  Forms,
  Dialogs,
  frame_InteriorPageBase,
  StdCtrls,
  ExtCtrls,
  ComCtrls,
  System.Net.HttpClient,
  unit_ProgressBarEx;

type
  TframeNCWDownload = class(TInteriorPageBase)
    lblStatus: TLabel;
    Bar: TProgressBar;

  private
    FHTTPClient: THTTPClient;
    FStartDate: TDateTime;
    FTerminated: Boolean;
    procedure HTTPReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64; var AAbort: Boolean);

  public
    function Activate(LoadData: Boolean): Boolean; override;
    function Deactivate(CheckData: Boolean): Boolean; override;

    function Download: Boolean;
    procedure Stop;
  end;

var
  frameNCWDownload: TframeNCWDownload;

implementation

uses
  SysUtils,
  DateUtils,
  System.IOUtils,
  unit_NCWParams,
  unit_MHLHttpClient;

resourcestring
  rstrConnecting = 'Подключение...';
  rstrSpeed = 'Загружено %d из %d КБ (%n КБ/с)';
  rstrDownloadComplete = 'Загрузка завершена';

{$R *.dfm}


function TframeNCWDownload.Activate(LoadData: Boolean): Boolean;
begin
  Assert(FPParams^.Operation = otInpxDownload);

  lblStatus.Caption := rstrConnecting;
  Bar.Position := 0;

  Result := True;
end;

function TframeNCWDownload.Deactivate(CheckData: Boolean): Boolean;
begin
  Result := True;
end;

function TframeNCWDownload.Download: Boolean;
var
  Response: TFileStream;
  Status: Integer;
  StagedIndex: string;
begin
  Result := False;
  FTerminated := False;
  StagedIndex := TPath.Combine(ExtractFilePath(FPParams^.INPXFile), 'INPX-' + TGUID.NewGuid.ToString + '.tmp');

  FHTTPClient := CreateHTTPClientUpdate;
  try
    FHTTPClient.OnReceiveData := HTTPReceiveData;
    FStartDate := Now;

    Response := TFileStream.Create(StagedIndex, fmCreate);
    try
      Status := FHTTPClient.Get(FPParams^.INPXUrl, Response).StatusCode;
    finally
      Response.Free;
    end;
    if FTerminated then Exit;
    if (Status < 200) or (Status >= 300) then
      raise Exception.CreateFmt('Сервер вернул HTTP %d.', [Status]);
    if not MoveFileEx(PChar(StagedIndex), PChar(FPParams^.INPXFile), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
    FPParams^.Operation := otInpx;
    Result := True;
  finally
    DeleteFile(StagedIndex);
    FreeAndNil(FHTTPClient);
  end;
end;

procedure TframeNCWDownload.HTTPReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64; var AAbort: Boolean);
var
  ElapsedTime: Cardinal;
  KB: Int64;
begin
  if FTerminated then
  begin
    AAbort := True;
    Exit;
  end;

  KB := AReadCount div 1024;

  if AContentLength > 0 then
    Bar.Position := AReadCount * 100 div AContentLength;

  ElapsedTime := SecondsBetween(Now, FStartDate);
  if ElapsedTime > 0 then
    lblStatus.Caption := Format(rstrSpeed, [KB, AContentLength div 1024, KB / ElapsedTime]);

  Application.ProcessMessages;
end;

procedure TframeNCWDownload.Stop;
begin
  FTerminated := True;
end;

end.
