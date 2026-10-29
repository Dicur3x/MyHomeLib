unit unit_BookCollisionDialog;

interface

function ChooseBookNameCollision(const FileName: string;
  out ReplaceFile, ApplyToAll: Boolean): Boolean;

implementation

uses System.Classes, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls,
  unit_MHLTheme;

function ChooseBookNameCollision(const FileName: string;
  out ReplaceFile, ApplyToAll: Boolean): Boolean;
var Dialog, Parent: TForm; LabelText: TLabel; Path: TMemo;
  All: TCheckBox; Footer: TPanel; Button: TButton; Answer: Integer;
begin
  ReplaceFile:=False; ApplyToAll:=False;
  Parent:=Screen.ActiveForm; if not Assigned(Parent) then Parent:=Application.MainForm;
  Dialog:=TForm.CreateNew(Parent);
  try
    Dialog.Name:='BookNameCollision'; Dialog.Caption:='Файл уже существует';
    Dialog.Position:=poOwnerFormCenter; Dialog.PopupMode:=pmExplicit; Dialog.PopupParent:=Parent;
    Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=9;
    Dialog.BorderStyle:=bsSizeable; Dialog.BorderIcons:=[biSystemMenu];
    Dialog.ClientWidth:=650; Dialog.ClientHeight:=240;
    Dialog.Constraints.MinWidth:=590; Dialog.Constraints.MinHeight:=260;
    LabelText:=TLabel.Create(Dialog); LabelText.Parent:=Dialog;
    LabelText.SetBounds(20,18,610,22); LabelText.Caption:='В папке сохранения уже есть файл с таким именем:';
    LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.ShowAccelChar:=False;
    Path:=TMemo.Create(Dialog); Path.Parent:=Dialog; Path.Name:='ExistingOutputFile';
    Path.SetBounds(20,46,610,78); Path.Anchors:=[akLeft,akTop,akRight,akBottom];
    Path.ReadOnly:=True; Path.WordWrap:=True; Path.ScrollBars:=ssVertical; Path.Text:=FileName;
    All:=TCheckBox.Create(Dialog); All.Parent:=Dialog; All.Name:='ApplyToRemainingCollisions';
    All.SetBounds(20,140,610,24); All.Anchors:=[akLeft,akRight,akBottom];
    All.Caption:='Применить ко всем совпадениям в этом сохранении';
    Footer:=TPanel.Create(Dialog); Footer.Parent:=Dialog; Footer.Align:=alBottom;
    Footer.Height:=56; Footer.BevelOuter:=bvNone;
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='ReplaceOutputFile';
    Button.Caption:='Заменить файл'; Button.SetBounds(20,12,150,30); Button.ModalResult:=mrYes;
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='KeepBothOutputFiles';
    Button.Caption:='Сохранить оба'; Button.SetBounds(182,12,150,30);
    Button.ModalResult:=mrNo; Button.Default:=True;
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='CancelOutputSaving';
    Button.Caption:='Отменить сохранение'; Button.SetBounds(452,12,178,30);
    Button.Anchors:=[akRight,akTop]; Button.ModalResult:=mrCancel; Button.Cancel:=True;
    ApplyMHLControlTheme(Dialog);
    Answer:=Dialog.ShowModal; Result:=Answer in [mrYes,mrNo];
    if Result then begin ReplaceFile:=Answer=mrYes; ApplyToAll:=All.Checked; end;
  finally Dialog.Free; end;
end;

end.
