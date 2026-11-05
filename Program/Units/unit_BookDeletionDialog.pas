unit unit_BookDeletionDialog;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, unit_BookDeletionOperation;

type
  TBookDeletionProgress = class(TForm)
  private
    FStage, FArchive, FDetail: TLabel;
    FProgress: TProgressBar;
    FStop: TButton;
    procedure HideWhenClosed(Sender: TObject; var Action: TCloseAction);
  public
    constructor CreateProgress(AOwner: TForm; Stop: TNotifyEvent);
    procedure UpdateProgress(const State: TBookDeletionOperationStatus);
  end;

function ConfirmBookDeletion(const CollectionName: string; BookCount, ArchiveCount: Integer;
  RemoveRecords: Boolean; var RemoveFiles: Boolean): Boolean;

implementation

uses System.SysUtils, System.Math, Vcl.Controls, Vcl.ExtCtrls, unit_MHLTheme;

constructor TBookDeletionProgress.CreateProgress(AOwner:TForm; Stop:TNotifyEvent);
  function Line(const Text:string; Y,Height:Integer):TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=Self;
    Result.AutoSize:=False; Result.WordWrap:=True; Result.ShowAccelChar:=False;
    Result.Anchors:=[akLeft,akTop,akRight]; Result.SetBounds(16,Y,528,Height);
    Result.Caption:=Text;
  end;
begin
  inherited CreateNew(AOwner);
  Name:='BookDeletionProgress'; Caption:='Удаление файлов книг';
  PopupMode:=pmExplicit; PopupParent:=AOwner; Position:=poOwnerFormCenter;
  BorderStyle:=bsSizeable; BorderIcons:=[biSystemMenu];
  Font.Name:='Segoe UI'; Font.Size:=9; ClientWidth:=560; ClientHeight:=194;
  Constraints.MinWidth:=510; Constraints.MinHeight:=230;
  FStage:=Line('Подготовка удаления…',14,25);
  FArchive:=Line('',45,34);
  FProgress:=TProgressBar.Create(Self); FProgress.Parent:=Self;
  FProgress.Name:='BookDeletionProgressBar'; FProgress.Max:=1000;
  FProgress.Anchors:=[akLeft,akTop,akRight]; FProgress.SetBounds(16,86,528,15);
  FDetail:=Line('Можно продолжать работать с другими книгами.',110,36);
  FStop:=TButton.Create(Self); FStop.Parent:=Self; FStop.Name:='StopBookDeletion';
  FStop.Caption:='Остановить'; FStop.Anchors:=[akRight,akBottom];
  FStop.SetBounds(414,150,130,30); FStop.OnClick:=Stop;
  OnClose:=HideWhenClosed;
  ApplyMHLControlTheme(Self);
end;

procedure TBookDeletionProgress.HideWhenClosed(Sender:TObject; var Action:TCloseAction);
begin Action:=caHide; end;

procedure TBookDeletionProgress.UpdateProgress(const State:TBookDeletionOperationStatus);
begin
  if State.Stage<>'' then FStage.Caption:=State.Stage;
  FArchive.Caption:=ExtractFileName(State.Archive);
  if (State.ArchiveIndex>0) and (State.ArchiveCount>0) then
    FArchive.Caption:=Format('Архив %d из %d · %s',[State.ArchiveIndex,State.ArchiveCount,FArchive.Caption]);
  if State.Total>0 then
  begin
    if FProgress.Style<>pbstNormal then FProgress.Style:=pbstNormal;
    FProgress.Position:=EnsureRange(Trunc(1000.0*State.Done/State.Total),0,1000);
  end
  else if FProgress.Style<>pbstMarquee then FProgress.Style:=pbstMarquee;
  FStop.Enabled:=not State.Stopping;
  if State.Stopping then FDetail.Caption:='Останавливаемся. Если архив уже меняется, сначала закончим его.'
  else FDetail.Caption:=Format('Готово книг: %d. Можно продолжать работать с другими книгами.',
    [State.CompletedBooks]);
end;

function ConfirmBookDeletion(const CollectionName: string; BookCount, ArchiveCount: Integer;
  RemoveRecords: Boolean; var RemoveFiles: Boolean): Boolean;
var Dialog, Owner: TForm; Summary, Details: TLabel; Files: TCheckBox;
  Footer: TPanel; Button: TButton;
begin
  Result:=False;
  Owner:=Screen.ActiveForm; if not Assigned(Owner) then Owner:=Application.MainForm;
  Dialog:=TForm.CreateNew(Owner);
  try
    Dialog.Name:='BookDeletionConfirmation'; Dialog.Caption:='Удаление книг';
    Dialog.Position:=poOwnerFormCenter; Dialog.PopupMode:=pmExplicit; Dialog.PopupParent:=Owner;
    Dialog.BorderStyle:=bsSizeable; Dialog.BorderIcons:=[biSystemMenu];
    Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=9;
    Dialog.ClientWidth:=590; Dialog.ClientHeight:=264;
    Dialog.Constraints.MinWidth:=550; Dialog.Constraints.MinHeight:=290;
    Summary:=TLabel.Create(Dialog); Summary.Parent:=Dialog;
    Summary.SetBounds(20,18,550,50); Summary.Anchors:=[akLeft,akTop,akRight];
    Summary.AutoSize:=False; Summary.WordWrap:=True; Summary.ShowAccelChar:=False;
    Summary.Caption:=Format('Коллекция: %s'+sLineBreak+'Выбрано книг: %d',[CollectionName,BookCount]);
    Files:=TCheckBox.Create(Dialog); Files.Parent:=Dialog; Files.Name:='DeleteBookSourceFiles';
    Files.SetBounds(20,80,550,26); Files.Anchors:=[akLeft,akTop,akRight];
    Files.Caption:='Удалить файлы книг с диска'; Files.Checked:=RemoveFiles;
    Files.Enabled:=RemoveRecords;
    if not RemoveRecords then Files.Checked:=True;
    Details:=TLabel.Create(Dialog); Details.Parent:=Dialog;
    Details.SetBounds(20,116,550,86); Details.Anchors:=[akLeft,akTop,akRight,akBottom];
    Details.AutoSize:=False; Details.WordWrap:=True; Details.ShowAccelChar:=False;
    if RemoveRecords then
      Details.Caption:='Без галочки удаляются только записи из коллекции. Файлы книг остаются на диске.'
    else Details.Caption:='Будут удалены загруженные файлы. Записи в каталоге, оценки и заметки сохранятся.';
    if ArchiveCount>0 then
      Details.Caption:=Details.Caption+sLineBreak+sLineBreak+Format(
        'Книг в архивах: %d. При удалении файлов программа уберёт только выбранные книги. Пустой архив тоже может быть удалён.',[ArchiveCount]);
    Footer:=TPanel.Create(Dialog); Footer.Parent:=Dialog; Footer.Align:=alBottom;
    Footer.Height:=54; Footer.BevelOuter:=bvNone;
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='ConfirmBookDeletion';
    Button.Caption:='Удалить'; Button.ModalResult:=mrYes;
    Button.SetBounds(312,10,120,30); Button.Anchors:=[akTop,akRight];
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='CancelBookDeletion';
    Button.Caption:='Отмена'; Button.ModalResult:=mrNo; Button.Cancel:=True; Button.Default:=True;
    Button.SetBounds(444,10,126,30); Button.Anchors:=[akTop,akRight];
    ApplyMHLControlTheme(Dialog);
    Result:=Dialog.ShowModal=mrYes;
    // Cancelling must not change the caller's pending choice or its settings.
    if Result then RemoveFiles:=Files.Checked;
  finally Dialog.Free; end;
end;

end.
