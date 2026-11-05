unit unit_BookDeletionDialog;

interface

function ConfirmBookDeletion(const CollectionName: string; BookCount, ArchiveCount: Integer;
  RemoveRecords: Boolean; var RemoveFiles: Boolean): Boolean;

implementation

uses System.Classes, System.SysUtils, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls,
  Vcl.ExtCtrls, unit_MHLTheme;

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
        'Книг в архивах: %d. ZIP и 7z не удаляются и не изменяются: в них могут находиться другие книги.',[ArchiveCount]);
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
