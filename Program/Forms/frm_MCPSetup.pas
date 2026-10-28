unit frm_MCPSetup;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls;

function MCPClientConfiguration(const Executable, ProfileDatabase: string): string;

type
  TfrmMCPSetup = class(TForm)
  private
    FConfiguration: TMemo;
    procedure CopyConfiguration(Sender: TObject);
  public
    constructor CreateForProfile(AOwner: TComponent; const Executable, ProfileDatabase: string);
  end;

implementation

uses System.SysUtils, System.JSON, Vcl.Controls, Vcl.ExtCtrls, Vcl.Clipbrd,
  unit_MHLTheme, unit_Consts;

function MCPClientConfiguration(const Executable, ProfileDatabase: string): string;
var Root, Servers, Server: TJSONObject; Arguments: TJSONArray;
begin
  Root:=TJSONObject.Create;
  try
    Servers:=TJSONObject.Create; Root.AddPair('mcpServers',Servers);
    Server:=TJSONObject.Create; Servers.AddPair('HomeLibRu',Server);
    Server.AddPair('command',Executable);
    Arguments:=TJSONArray.Create; Server.AddPair('args',Arguments);
    // The catalogue's existing "user <name>" profile switch is understood
    // by the server through the same settings resolver.
    if not SameText(ExtractFileName(ProfileDatabase),SYSTEM_DATABASE_FILENAME) then
    begin Arguments.Add('user'); Arguments.Add(ChangeFileExt(ExtractFileName(ProfileDatabase),'')); end;
    Result:=Root.Format(2);
  finally Root.Free; end;
end;

constructor TfrmMCPSetup.CreateForProfile(AOwner: TComponent; const Executable, ProfileDatabase: string);
var Body, Buttons: TPanel; Hint: TLabel; CopyButton, CloseButton: TButton;
begin
  inherited CreateNew(AOwner);
  Name:='frmMCPSetup'; Caption:='Подключение AI-ассистента';
  Position:=poOwnerFormCenter; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=660; ClientHeight:=420;
  Constraints.MinWidth:=500; Constraints.MinHeight:=360;
  Body:=TPanel.Create(Self); Body.Parent:=Self; Body.Align:=alClient; Body.BevelOuter:=bvNone;
  Body.Padding.SetBounds(16,14,16,12);
  Hint:=TLabel.Create(Self); Hint.Name:='MCPSetupHint'; Hint.Parent:=Body;
  Hint.Align:=alTop; Hint.WordWrap:=True; Hint.AutoSize:=True;
  Hint.Caption:='Модуль позволяет выбранному AI-приложению искать книги в ваших коллекциях и читать их текст.'+
    sLineBreak+sLineBreak+'В настройках AI-приложения добавьте локальный MCP-сервер (stdio). '+
    'Ниже пример для приложений с настройками в формате mcpServers. Подключение здесь не запускается.';
  FConfiguration:=TMemo.Create(Self); FConfiguration.Name:='MCPConfiguration'; FConfiguration.Parent:=Body;
  FConfiguration.Align:=alClient; FConfiguration.ReadOnly:=True;
  FConfiguration.ScrollBars:=ssBoth; FConfiguration.WordWrap:=False;
  FConfiguration.Font.Name:='Consolas'; FConfiguration.Font.Size:=9;
  FConfiguration.Lines.Text:=MCPClientConfiguration(Executable,ProfileDatabase);
  Buttons:=TPanel.Create(Self); Buttons.Parent:=Self; Buttons.Align:=alBottom;
  Buttons.Height:=52; Buttons.BevelOuter:=bvNone;
  CopyButton:=TButton.Create(Self); CopyButton.Name:='MCPCopyConfiguration'; CopyButton.Parent:=Buttons;
  CopyButton.SetBounds(ClientWidth-344,10,210,28); CopyButton.Anchors:=[akTop,akRight];
  CopyButton.Caption:='Копировать настройки'; CopyButton.OnClick:=CopyConfiguration;
  CloseButton:=TButton.Create(Self); CloseButton.Parent:=Buttons;
  CloseButton.SetBounds(ClientWidth-122,10,106,28); CloseButton.Anchors:=[akTop,akRight];
  CloseButton.Caption:='Закрыть'; CloseButton.ModalResult:=mrCancel;
  CloseButton.Default:=True; CloseButton.Cancel:=True;
  ApplyMHLControlTheme(Self);
end;

procedure TfrmMCPSetup.CopyConfiguration(Sender: TObject);
begin Clipboard.AsText:=FConfiguration.Lines.Text; end;

end.
