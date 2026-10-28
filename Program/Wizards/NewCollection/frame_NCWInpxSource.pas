(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors Nick Rymanov     nrymanov@gmail.com
  *         Oleksiy Penkov   oleksiy.penkov@gmail.com
  *
  * History
  *
  ****************************************************************************** *)

unit frame_NCWInpxSource;

interface

uses
  Windows,
  Messages,
  SysUtils,
  Variants,
  Classes,
  Graphics,
  Controls,
  Forms,
  Dialogs,
  frame_InteriorPageBase,
  StdCtrls,
  ExtCtrls,
  unit_StaticTip,
  unit_NCWParams,
  Mask,
  ComCtrls,
  MHLSimplePanel,
  unit_AutoCompleteEdit;

type
  TCollectionDesc = record
    Group: integer;
    Title: string;
    Desc: string;
    INPX: string;
  end;

  TframeNCWInpxSource = class(TInteriorPageBase)
    Panel1: TMHLSimplePanel;
    pageHint: TMHLStaticTip;
    rbLocal: TRadioButton;
    edINPXPath: TMHLAutoCompleteEdit;
    rbDownload: TRadioButton;
    lvCollections: TListView;
    MHLSimplePanel1: TMHLSimplePanel;
    btnSelectINPX: TButton;
    procedure OnSetINPXSource(Sender: TObject);
    procedure edINPXPathButtonClick(Sender: TObject);
    procedure lvCollectionsChange(Sender: TObject; Item: TListItem; Change: TItemChange);

  private
    FGroups: array of string;
    FCollections: array of TCollectionDesc;

    FCollection: TCollectionDesc;

    procedure LoadDescriptions;
    procedure FillList;

  public
    function Activate(LoadData: Boolean): Boolean; override;
    function Deactivate(CheckData: Boolean): Boolean; override;
  end;

var
  frameNCWInpxSource: TframeNCWInpxSource;

implementation

uses
  IOUtils,
  unit_Settings,
  dm_user,
  unit_CatalogComponents,
  unit_Helpers,
  IniFiles;

resourcestring
  rstrServerDownload = 'Выбранный файл INPX будет загружен с сервера.';
  rstrLocal = 'Коллекция на основе файла *.inpx. Укажите путь к файлу.';
  rstrMetabibLocal = 'Укажите файл каталога metabib (*.jsonl, *.jsonl.zst, *.jsonl.gz или zip с jsonl внутри)';
  rstrInpxSourceTitle = 'Источник INPX';
  rstrInpxSourceSubTitle = 'Выберите файл INPX для создания коллекции';
  rstrMetabibSourceTitle = 'Источник metabib';
  rstrMetabibSourceSubTitle = 'Выберите файл каталога metabib для создания коллекции';
  //rstrLibrusecOnline = 'Книги скачиваются по запросу с сервера lib.rus.ec (необходима регистрация)';

{$R *.dfm}

const
  INPX_SECTION = 'INPX';
  INPX_GROUP_SECTION = 'GROUPS';
  INPX_KEY_PREFIX = 'Inpx';
  INPX_GROUP_KEY_PREFIX = 'Group';


procedure TframeNCWInpxSource.LoadDescriptions;
var
  I: integer;
  sl: TStringList;
  slHelper: TStringList;
  INIFile: TMemIniFile;
begin
  INIFile := TMemIniFile.Create(Settings.SystemFileName[sfCollectionsStore]);
  try
    INIFile.Encoding := TEncoding.UTF8;

    sl := TStringList.Create;
    try
      INIFile.ReadSection(INPX_GROUP_SECTION, sl);
      if sl.Count > 0 then
      begin
        SetLength(FGroups, sl.Count);
        for I := 0 to sl.Count - 1 do
          if Pos(INPX_GROUP_KEY_PREFIX, sl[I]) = 1 then
            FGroups[I] := INIFile.ReadString(INPX_GROUP_SECTION, sl[I], '');
      end
      else
      begin
      end;

      INIFile.ReadSection(INPX_SECTION, sl);
      if sl.Count > 0 then
      begin
        SetLength(FCollections, sl.Count);
        slHelper := TIniStringList.Create;
        try
          for I := 0 to sl.Count - 1 do
          begin
            if Pos(INPX_KEY_PREFIX, sl[I]) = 1 then
            begin
              slHelper.DelimitedText := INIFile.ReadString(INPX_SECTION, sl[I], '');
              if slHelper.Count > 4 then
              begin
                FCollections[I].Group := StrToInt(slHelper[0]);
                FCollections[I].Title := slHelper[1];
                FCollections[I].Desc := slHelper[2];
                FCollections[I].INPX := slHelper[3];
              end;
            end;
          end;
        finally
          slHelper.Free;
        end;
      end
      else
      begin
      end;
    finally
      sl.Free;
    end;
  finally
    INIFile.Free;
  end;
end;

procedure TframeNCWInpxSource.FillList;
var
  I: integer;
  G: TListGroup;
  Item: TListItem;
begin
  LoadDescriptions;

  lvCollections.Items.BeginUpdate;
  try
    lvCollections.Groups.Clear;
    lvCollections.Items.Clear;

    for I := 0 to High(FGroups) do
    begin
      G := lvCollections.Groups.Add;
      G.Header := FGroups[I];
    end;

    for I := 0 to High(FCollections) do
    begin
      Item := lvCollections.Items.Add;
      Item.Caption := FCollections[I].Title;
      Item.GroupID := FCollections[I].Group;
    end;

    if lvCollections.Items.Count > 0 then
    begin
      lvCollections.Selected := lvCollections.Items[0];
      lvCollections.ItemFocused := lvCollections.Selected;
      FCollection := FCollections[0];
    end;
  finally
    lvCollections.Items.EndUpdate;
  end;
end;

function TframeNCWInpxSource.Activate(LoadData: Boolean): Boolean;
begin
  Assert(FPParams^.Operation in [otInpx, otInpxDownload, otMetabib]);
  if LoadData then
  begin
    if FPParams^.Operation = otMetabib then
    begin
      rbLocal.Visible := False;
      rbDownload.Visible := False;
      lvCollections.Visible := False;

      edINPXPath.Enabled := True;
      btnSelectINPX.Enabled := True;

      pageHint.Caption := rstrMetabibLocal;
      Title := rstrMetabibSourceTitle;
      SubTitle := rstrMetabibSourceSubTitle;
    end
    else
    begin
      rbLocal.Visible := True;
      rbDownload.Visible := True;
      lvCollections.Visible := True;

      Title := rstrInpxSourceTitle;
      SubTitle := rstrInpxSourceSubTitle;

      FillList;
      rbLocal.Checked := True;
      rbDownload.Enabled := (lvCollections.Items.Count > 0) and (Settings.InpxURL.Trim <> '');
      rbDownload.ShowHint := True;
      if Settings.InpxURL.Trim = '' then
        rbDownload.Hint := 'Для загрузки каталогов задайте свой сервер INPX в настройках. Можно выбрать локальный файл.'
      else rbDownload.Hint := '';

      OnSetINPXSource(rbLocal);
    end;
  end;
  Result := True;
end;

function TframeNCWInpxSource.Deactivate(CheckData: Boolean): Boolean;
begin
  if FPParams^.Operation = otMetabib then
  begin
    FPParams^.INPXFile := edINPXPath.Text;
    if CheckData and not EnsureCatalogReaderComponent(Self,FPParams^.INPXFile) then Exit(False);
    Exit(True);
  end;

  Assert(Assigned(lvCollections.Selected));

  if rbLocal.Checked then
  begin
    FPParams^.INPXFile := edINPXPath.Text;
  end
  else
  begin
    FPParams^.Operation := otInpxDownload;
    FPParams^.INPXFile := TPath.Combine(Settings.WorkPath, FCollection.INPX);
    if Settings.InpxURL.Trim = '' then Exit(False);
    FPParams^.INPXUrl := IncludeTrailingPathDelimiter(Settings.InpxURL).Replace('\','/') + FCollection.INPX;
  end;

  Result := True;
end;

procedure TframeNCWInpxSource.edINPXPathButtonClick(Sender: TObject);
var
  AFileName: string;
  key: TMHLFileName;
begin
  if FPParams^.Operation = otMetabib then
    key := fnOpenMetabib
  else
    key := fnOpenINPX;

  if GetFileName(key, AFileName) then
  begin
    edINPXPath.Text := AFileName;
  end;
end;

procedure TframeNCWInpxSource.lvCollectionsChange(Sender: TObject; Item: TListItem; Change: TItemChange);
begin
  if (Change = ctState) and Assigned(lvCollections.Selected) then
  begin
    FCollection := FCollections[lvCollections.ItemIndex];
    pageHint.Caption := FCollection.Desc;
  end;
end;

procedure TframeNCWInpxSource.OnSetINPXSource(Sender: TObject);
begin
  if Sender = rbLocal then
    pageHint.Caption := rstrLocal
  else
  begin
    Assert(lvCollections.Items.Count > 0);

    if not Assigned(lvCollections.Selected) then
      lvCollections.Selected := lvCollections.ItemFocused;
    if not Assigned(lvCollections.Selected) then
      lvCollections.Selected := lvCollections.Items[0];

    Assert(Assigned(lvCollections.Selected));
    lvCollectionsChange(Self, lvCollections.Selected, ctState);
  end;

  edINPXPath.Enabled := rbLocal.Checked;
  btnSelectINPX.Enabled := rbLocal.Checked;
  lvCollections.Enabled := rbDownload.Checked;
end;

end.
