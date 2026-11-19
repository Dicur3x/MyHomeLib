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

unit frame_NCWCollectionFileTypes;

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
  unit_StaticTip;

type
  TframeNCWCollectionFileTypes = class(TInteriorPageBase)
    Panel3: TPanel;
    rbSoreAnyFiles: TRadioButton;
    rbSoreFB2Files: TRadioButton;
    pageHint: TMHLStaticTip;
    cbAutoImport: TCheckBox;
    procedure OnSetFileType(Sender: TObject);

  private

  public
    function Activate(LoadData: Boolean): Boolean; override;
    function Deactivate(CheckData: Boolean): Boolean; override;
  end;

var
  frameNCWCollectionFileTypes: TframeNCWCollectionFileTypes;

implementation

uses
  unit_NCWParams;

resourcestring
   rstrCollectionTypeFB2 = 'Стандартные жанры FictionBook и импорт FB2 из папки или архива. Отдельные файлы, например EPUB и PDF, тоже можно добавлять.';
   rstrCollectionTypeAny = 'Выберите стандартные или свои жанры на следующем шаге. Отдельные FB2, EPUB, PDF и другие книги можно добавлять вручную.';
{$R *.dfm}


function TframeNCWCollectionFileTypes.Activate(LoadData: Boolean): Boolean;
var
  rb: TRadioButton;
begin
  Assert(FPParams^.Operation = otNew);

  if LoadData then
  begin
    if ftFB2 = FPParams^.FileTypes then
      rb := rbSoreFB2Files
    else
      rb := rbSoreAnyFiles;

    rb.Checked := True;
    OnSetFileType(rb);
  end;

  cbAutoImport.Enabled := rbSoreFB2Files.Checked;

  Result := True;
end;

function TframeNCWCollectionFileTypes.Deactivate(CheckData: Boolean): Boolean;
begin
  if rbSoreFB2Files.Checked then
    FPParams^.FileTypes := ftFB2
  else
    FPParams^.FileTypes := ftAny;

  FPParams^.AutoImport := cbAutoImport.Checked;
  Result := True;
end;

procedure TframeNCWCollectionFileTypes.OnSetFileType(Sender: TObject);
begin
  if Sender = rbSoreFB2Files then
    pageHint.Caption := rstrCollectionTypeFB2
  else if Sender = rbSoreAnyFiles  then
    pageHint.Caption := rstrCollectionTypeAny;

  cbAutoImport.Enabled := rbSoreFB2Files.Checked;
end;

end.
