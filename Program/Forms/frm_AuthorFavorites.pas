unit frm_AuthorFavorites;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, unit_AuthorFavorites, frm_CatalogSources;

type
  TfrmAuthorFavorites = class(TSourceDialogForm)
  private
    FStore: TAuthorFavorites;
    FEntries: TArray<TAuthorFavoriteEntry>;
    FHelp, FCount: TLabel;
    FSearch: TEdit;
    FList: TListView;
    FRemove, FClose: TButton;
    FChanged: Boolean;
    procedure Rebuild(Sender: TObject);
    procedure Selected(Sender: TObject; Item: TListItem; IsSelected: Boolean);
    procedure RemoveSelected(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Load(Store: TAuthorFavorites);
    property Changed: Boolean read FChanged;
  end;

implementation

uses Winapi.Windows, System.SysUtils, System.StrUtils, System.Generics.Collections,
  Vcl.Controls, Vcl.Dialogs, unit_MHLTheme;

constructor TfrmAuthorFavorites.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Name:='AuthorFavoritesForm'; Caption:='Все любимые авторы'; Position:=poOwnerFormCenter;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=760; ClientHeight:=480; Constraints.MinWidth:=600; Constraints.MinHeight:=350;
  FHelp:=TLabel.Create(Self); FHelp.Parent:=Self; FHelp.AutoSize:=False; FHelp.WordWrap:=True;
  FHelp.Caption:='Весь список, включая авторов, которых нет в текущей коллекции. '+
    'Если имя в каталоге изменилось, старая запись может остаться отдельной строкой.';
  FSearch:=TEdit.Create(Self); FSearch.Parent:=Self; FSearch.Name:='edAllFavoriteAuthorsSearch';
  FSearch.Text:='';
  FSearch.TextHint:='Найти в любимых авторах'; FSearch.OnChange:=Rebuild;
  FList:=TListView.Create(Self); FList.Parent:=Self; FList.Name:='lvAllFavoriteAuthors';
  FList.ViewStyle:=vsReport; FList.ReadOnly:=True; FList.RowSelect:=True;
  FList.MultiSelect:=True; FList.HideSelection:=False; FList.OnSelectItem:=Selected;
  FList.Columns.Add.Caption:='Полное имя'; FList.Columns.Add.Caption:='Добавлен (UTC)';
  FCount:=TLabel.Create(Self); FCount.Parent:=Self; FCount.AutoSize:=False;
  FRemove:=TButton.Create(Self); FRemove.Parent:=Self; FRemove.Name:='btnRemoveFavoriteAuthors';
  FRemove.Caption:='Убрать выбранных из любимых…'; FRemove.OnClick:=RemoveSelected; FRemove.Enabled:=False;
  FClose:=TButton.Create(Self); FClose.Parent:=Self; FClose.Name:='btnCloseFavoriteAuthors';
  FClose.Caption:='Закрыть'; FClose.ModalResult:=mrClose; FClose.Cancel:=True;
  Resize; ActiveControl:=FSearch; ApplyMHLControlTheme(Self);
end;

procedure TfrmAuthorFavorites.Resize;
var P, Gap, ButtonY: Integer;
  function Px(Value: Integer): Integer;
  begin Result:=MulDiv(Value,PixelsPerInch,96); end;
begin
  inherited;
  if not Assigned(FClose) then Exit;
  P:=Px(12); Gap:=Px(8); ButtonY:=ClientHeight-P-Px(30);
  FHelp.SetBounds(P,P,ClientWidth-2*P,Px(42));
  FSearch.SetBounds(P,Px(60),ClientWidth-2*P,Px(26));
  FList.SetBounds(P,Px(96),ClientWidth-2*P,ButtonY-Px(128));
  FCount.SetBounds(P,FList.Top+FList.Height+Gap,ClientWidth-2*P,Px(20));
  FRemove.SetBounds(P,ButtonY,Px(265),Px(30));
  FClose.SetBounds(ClientWidth-P-Px(110),ButtonY,Px(110),Px(30));
  FList.Columns[0].Width:=FList.ClientWidth-Px(190);
  FList.Columns[1].Width:=Px(160);
end;

procedure TfrmAuthorFavorites.Load(Store: TAuthorFavorites);
begin
  FStore:=Store; FEntries:=Store.Entries; Rebuild(nil);
end;

procedure TfrmAuthorFavorites.Rebuild(Sender: TObject);
var Entry: TAuthorFavoriteEntry; Item: TListItem; I: Integer; Stamp, Needle: string;
begin
  Needle:=Trim(FSearch.Text);
  FList.Items.BeginUpdate;
  try
    FList.Clear;
    for I:=0 to High(FEntries) do
    begin
      Entry:=FEntries[I];
      if (Needle<>'') and not ContainsText(Entry.DisplayName,Needle) then Continue;
      Item:=FList.Items.Add; Item.Caption:=Entry.DisplayName;
      Item.Data:=Pointer(NativeInt(I+1));
      Stamp:=StringReplace(Entry.CreatedUTC,'T',' ',[]);
      if Stamp.EndsWith('Z') then Delete(Stamp,Length(Stamp),1);
      Item.SubItems.Add(Stamp);
    end;
  finally FList.Items.EndUpdate; end;
  FCount.Caption:=Format('Показано: %d из %d',[FList.Items.Count,Length(FEntries)]);
  if Length(FEntries)=0 then FCount.Caption:='Любимых авторов пока нет.';
  FRemove.Enabled:=False;
end;

procedure TfrmAuthorFavorites.Selected(Sender: TObject; Item: TListItem; IsSelected: Boolean);
begin
  if Assigned(FRemove) then FRemove.Enabled:=FList.SelCount>0;
end;

procedure TfrmAuthorFavorites.RemoveSelected(Sender: TObject);
var Keys: TList<string>; Item: TListItem; Index: NativeInt;
begin
  if not Assigned(FStore) or (FList.SelCount=0) then Exit;
  Keys:=TList<string>.Create;
  try
    for Item in FList.Items do
      if Item.Selected then
      begin
        Index:=NativeInt(Item.Data)-1;
        if (Index>=0) and (Index<Length(FEntries)) then Keys.Add(FEntries[Index].Key);
      end;
    if Keys.Count=0 then Exit;
    if MessageDlg(Format('Убрать выбранных авторов из любимых: %d?',[Keys.Count])+#13#10+
      'Книги и остальные любимые авторы сохранятся.',mtConfirmation,[mbYes,mbNo],0,mbNo)<>mrYes then Exit;
    try
      if FStore.RemoveFavorites(Keys.ToArray) then FChanged:=True;
      FEntries:=FStore.Entries; Rebuild(nil);
    except
      on E: Exception do MessageDlg('Не удалось изменить список любимых авторов.'+#13#10+E.Message,mtError,[mbOK],0);
    end;
  finally Keys.Free; end;
end;

end.
