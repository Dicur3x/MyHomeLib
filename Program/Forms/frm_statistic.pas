(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors Oleksiy Penkov   oleksiy.penkov@gmail.com
  *         Nick Rymanov     nrymanov@gmail.com
  * Created                  20.08.2008
  * Description
  *
  * $Id: frm_statistic.pas 840 2010-10-06 07:37:58Z nrymanov@gmail.com $
  *
  * History
  *
  ****************************************************************************** *)

unit frm_statistic;

interface

uses System.Classes, Vcl.Controls, Vcl.Forms, Vcl.ComCtrls, Vcl.StdCtrls,
  Vcl.ExtCtrls, unit_Interfaces, unit_CatalogSources;

type
  TCollectionStatisticsWorker = class(TThread)
  private
    FFileName: string;
    FSources: TCatalogSources;
    FDone: Integer;
    function QueryCanceled: Boolean;
  protected
    procedure Execute; override;
  public
    AuthorsCount, BooksCount, SeriesCount: Int64;
    LinkedCounts: TArray<Int64>;
    Error: string;
    constructor Create(const FileName: string; const Sources: TCatalogSources);
    function Done: Boolean;
  end;

  TfrmStat = class(TForm)
    btnClose: TButton;
    lvInfo: TListView;
  private
    FWorker: TCollectionStatisticsWorker;
    FTimer: TTimer;
    FDetails: TMemo;
    FStarted: Boolean;
    procedure StopWorker;
    procedure PollWorker(Sender: TObject);
    procedure InfoChanged(Sender: TObject; Item: TListItem; Change: TItemChange);
    procedure InfoTip(Sender: TObject; Item: TListItem; var InfoTip: string);
    function GetLoading: Boolean;
  protected
    procedure DoCreate; override;
    procedure Resize; override;
  public
    destructor Destroy; override;
    procedure LoadCollectionInfo(const Collection: IBookCollection);
    property Loading: Boolean read GetLoading;
  end;

var frmStat: TfrmStat;

implementation

uses System.SysUtils, System.Variants, System.SyncObjs, System.Math,
  unit_Consts, unit_Helpers, unit_Localization, unit_Settings, SQLiteWrap, dm_user;

{$R *.dfm}

constructor TCollectionStatisticsWorker.Create(const FileName: string; const Sources: TCatalogSources);
begin
  inherited Create(True);
  FFileName:=FileName; FSources:=Copy(Sources);
  SetLength(LinkedCounts,Length(Sources));
end;

function TCollectionStatisticsWorker.QueryCanceled: Boolean;
begin Result:=Terminated; end;

function TCollectionStatisticsWorker.Done: Boolean;
begin Result:=TInterlocked.CompareExchange(FDone,0,0)<>0; end;

procedure TCollectionStatisticsWorker.Execute;
var DB: TSQLiteDatabase; I: Integer; SavedCancel: TSQLiteCancelCallback;
begin
  SavedCancel:=SQLiteCancelCallback; SQLiteCancelCallback:=QueryCanceled; DB:=nil;
  try
    try
      if Terminated then Exit;
      // Separate read-only connection: no collection cache, migrations, UI
      // connection or VCL controls are touched by the statistics thread.
      DB:=TSQLiteDatabase.CreateReadOnly(FFileName);
      AuthorsCount:=DB.QuerySingleInt('SELECT COUNT(*) FROM Authors');
      BooksCount:=DB.QuerySingleInt('SELECT COUNT(*) FROM Books');
      SeriesCount:=DB.QuerySingleInt('SELECT COUNT(*) FROM Series');
      for I:=0 to High(FSources) do
      begin
        if Terminated then Exit;
        LinkedCounts[I]:=DB.QuerySingleInt('SELECT COUNT(DISTINCT l.BookID) FROM CatalogSourceBooks l '+
          'JOIN Books b ON b.BookID=l.BookID WHERE l.SourceKey>=? AND l.SourceKey<?',
          [FSources[I].ID+':',FSources[I].ID+';']);
      end;
    except on E: Exception do if not Terminated then Error:=E.Message; end;
  finally
    DB.Free; SQLiteCancelCallback:=SavedCancel;
    TInterlocked.Exchange(FDone,1);
  end;
end;

procedure TfrmStat.DoCreate;
begin
  inherited;
  Localize(Self); BorderStyle:=bsSizeable; Font.Name:='Segoe UI'; Font.Size:=9;
  Constraints.MinWidth:=660; Constraints.MinHeight:=420;
  ClientWidth:=720; ClientHeight:=470;
  lvInfo.DoubleBuffered:=True; lvInfo.ShowHint:=True;
  lvInfo.OnChange:=InfoChanged; lvInfo.OnInfoTip:=InfoTip;
  FDetails:=TMemo.Create(Self); FDetails.Parent:=Self;
  FDetails.Name:='mmStatisticDetails'; FDetails.ReadOnly:=True;
  FDetails.WordWrap:=True; FDetails.ScrollBars:=ssVertical;
  FDetails.SetBounds(8,ClientHeight-116,ClientWidth-16,76);
  FDetails.Anchors:=[akLeft,akRight,akBottom];
  lvInfo.Height:=ClientHeight-132;
  FTimer:=TTimer.Create(Self); FTimer.Enabled:=False; FTimer.Interval:=25;
  FTimer.OnTimer:=PollWorker;
end;

destructor TfrmStat.Destroy;
begin
  StopWorker;
  inherited;
end;

procedure TfrmStat.StopWorker;
begin
  if Assigned(FTimer) then FTimer.Enabled:=False;
  if not Assigned(FWorker) then Exit;
  FWorker.Terminate;
  if not FStarted then FWorker.Start;
  // No worker Synchronize/Queue callbacks: joining cannot reference a closing
  // form. SQLite progress/busy callbacks acknowledge cancellation promptly.
  FWorker.WaitFor; FreeAndNil(FWorker); FStarted:=False;
end;

function TfrmStat.GetLoading: Boolean;
begin Result:=Assigned(FWorker); end;

procedure TfrmStat.Resize;
begin
  inherited;
  if Assigned(lvInfo) and (lvInfo.Columns.Count>1) then
    lvInfo.Columns[1].Width:=Max(240,lvInfo.ClientWidth-lvInfo.Columns[0].Width-24);
end;

procedure TfrmStat.InfoTip(Sender: TObject; Item: TListItem; var InfoTip: string);
begin
  InfoTip:=Item.Caption;
  if Item.SubItems.Count>0 then InfoTip:=InfoTip+' '+Item.SubItems[0];
end;

procedure TfrmStat.InfoChanged(Sender: TObject; Item: TListItem; Change: TItemChange);
begin
  if Assigned(FDetails) and Assigned(Item) and Item.Selected and (Item.SubItems.Count>0) then
    FDetails.Text:=Item.Caption+' '+Item.SubItems[0];
end;

procedure TfrmStat.PollWorker(Sender: TObject);
var I: Integer;
begin
  if not Assigned(FWorker) then begin FTimer.Enabled:=False; Exit; end;
  if not FStarted then
  begin FStarted:=True; FWorker.Start; Exit; end;
  if not FWorker.Done then Exit;
  FWorker.WaitFor; FTimer.Enabled:=False;
  if FWorker.Error<>'' then
  begin
    for I:=4 to 6 do lvInfo.Items[I].SubItems[0]:='Не удалось подсчитать';
    FDetails.Text:='Не удалось подсчитать статистику: '+FWorker.Error;
  end
  else
  begin
    lvInfo.Items[4].SubItems[0]:=IntToStr(FWorker.AuthorsCount);
    lvInfo.Items[5].SubItems[0]:=IntToStr(FWorker.BooksCount);
    lvInfo.Items[6].SubItems[0]:=IntToStr(FWorker.SeriesCount);
    for I:=0 to High(FWorker.FSources) do
      lvInfo.Items[8+I].SubItems[0]:=IntToStr(FWorker.LinkedCounts[I])+
        ' связанных записей; '+FWorker.FSources[I].Root;
    if Assigned(lvInfo.Selected) then InfoChanged(lvInfo,lvInfo.Selected,ctText);
  end;
  FreeAndNil(FWorker); FStarted:=False;
end;

procedure TfrmStat.LoadCollectionInfo(const Collection: IBookCollection);
var Version: Variant; Sources: TCatalogSources; Source: TCatalogSource;
  Item: TListItem; SourceGroup: TListGroup;
begin
  Assert(Assigned(Collection)); StopWorker;
  lvInfo.Items.BeginUpdate;
  try
    lvInfo.Items[0].SubItems[0]:=Collection.GetProperty(PROP_DISPLAYNAME);
    lvInfo.Items[1].SubItems[0]:=DateToStr(Collection.GetProperty(PROP_CREATIONDATE));
    Version:=Collection.GetProperty(PROP_DATAVERSION);
    if VarIsEmpty(Version) then lvInfo.Items[2].SubItems[0]:='unknown'
    else lvInfo.Items[2].SubItems[0]:=VarToStr(Version);
    lvInfo.Items[3].Caption:='Описание исходного INPX:';
    lvInfo.Items[3].SubItems[0]:=Collection.GetProperty(PROP_NOTES);
    lvInfo.Items[5].Caption:='Записей книг:';
    lvInfo.Items[4].SubItems[0]:='Подсчёт…';
    lvInfo.Items[5].SubItems[0]:='Подсчёт…';
    lvInfo.Items[6].SubItems[0]:='Подсчёт…';
    while lvInfo.Items.Count>7 do lvInfo.Items.Delete(7);
    while lvInfo.Groups.Count>2 do lvInfo.Groups.Delete(2);
    Item:=lvInfo.Items.Add; Item.GroupID:=2; Item.Caption:='Подсчёт:';
    Item.SubItems.Add('Каждая запись один раз, независимо от числа серий');
    Sources:=LoadCatalogSources(Collection);
    if Length(Sources)>0 then
    begin
      SourceGroup:=lvInfo.Groups.Add; SourceGroup.GroupID:=3;
      SourceGroup.Header:='Дополнительные источники ('+IntToStr(Length(Sources))+')';
      for Source in Sources do
      begin
        Item:=lvInfo.Items.Add; Item.GroupID:=3; Item.Caption:=Source.Name;
        Item.SubItems.Add('Подсчёт…; '+Source.Root);
      end;
      Item:=lvInfo.Items.Add; Item.GroupID:=3; Item.Caption:='Примечание:';
      Item.SubItems.Add('Связи источников могут пересекаться. Разные файлы одного произведения считаются отдельно.');
    end;
    lvInfo.AutosizeColumn(0); Resize;
    lvInfo.Selected:=lvInfo.Items[lvInfo.Items.Count-1];
    InfoChanged(lvInfo,lvInfo.Selected,ctText);
  finally lvInfo.Items.EndUpdate; end;
  FWorker:=TCollectionStatisticsWorker.Create(Settings.ExpandCollectionFileName(
    VarToStr(Collection.GetProperty(PROP_DATAFILE))),Sources);
  FStarted:=False; FTimer.Enabled:=True;
end;

end.
