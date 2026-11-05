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
    FCategory, FRating: TComboBox;
    FHidden: TCheckBox;
    FUpdating: Boolean;
    FList: TListView;
    FRemove, FClose: TButton;
    FChanged: Boolean;
    procedure Rebuild(Sender: TObject);
    procedure Selected(Sender: TObject; Item: TListItem; IsSelected: Boolean);
    procedure RemoveSelected(Sender: TObject);
    procedure PersonalChanged(Sender: TObject);
    procedure RefreshEntries;
    function SelectedAuthors: TArray<TAuthorFavoriteEntry>;
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
  Name:='AuthorFavoritesForm'; Caption:='Мои авторы'; Position:=poOwnerFormCenter;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=760; ClientHeight:=480; Constraints.MinWidth:=600; Constraints.MinHeight:=350;
  FHelp:=TLabel.Create(Self); FHelp.Parent:=Self; FHelp.AutoSize:=False; FHelp.WordWrap:=True;
  FHelp.Caption:='Любимые, скрытые и оценённые авторы из всех коллекций. '+
    'Можно выбрать несколько авторов и изменить их настройки вместе.';
  FCategory:=TComboBox.Create(Self); FCategory.Parent:=Self; FCategory.Style:=csDropDownList;
  FCategory.Name:='cbPersonalAuthorCategory';
  FCategory.Items.AddStrings(['Любимые','Скрытые','С оценкой','Все мои авторы']);
  FCategory.ItemIndex:=0; FCategory.OnChange:=Rebuild;
  FSearch:=TEdit.Create(Self); FSearch.Parent:=Self; FSearch.Name:='edAllFavoriteAuthorsSearch';
  FSearch.Text:='';
  FSearch.TextHint:='Найти в любимых авторах'; FSearch.OnChange:=Rebuild;
  FList:=TListView.Create(Self); FList.Parent:=Self; FList.Name:='lvAllFavoriteAuthors';
  FList.ViewStyle:=vsReport; FList.ReadOnly:=True; FList.RowSelect:=True;
  FList.MultiSelect:=True; FList.HideSelection:=False; FList.OnSelectItem:=Selected;
  FList.Columns.Add.Caption:='Полное имя'; FList.Columns.Add.Caption:='Добавлен (UTC)';
  FList.Columns.Add.Caption:='Оценка'; FList.Columns.Add.Caption:='Скрыт';
  FList.Columns.Add.Caption:='Любимый';
  FRating:=TComboBox.Create(Self); FRating.Parent:=Self; FRating.Style:=csDropDownList;
  FRating.Name:='cbPersonalAuthorRating';
  FRating.Items.AddStrings(['Без личной оценки','1','2','3','4','5']);
  FRating.ItemIndex:=0; FRating.Enabled:=False; FRating.OnChange:=PersonalChanged;
  FHidden:=TCheckBox.Create(Self); FHidden.Parent:=Self; FHidden.Name:='cbPersonalAuthorHidden';
  FHidden.Caption:='Скрывать автора и его книги'; FHidden.Enabled:=False;
  FHidden.OnClick:=PersonalChanged;
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
  FCategory.SetBounds(P,Px(60),Px(165),Px(26));
  FSearch.SetBounds(P+Px(173),Px(60),ClientWidth-2*P-Px(173),Px(26));
  FRating.SetBounds(P,Px(94),Px(165),Px(26));
  FHidden.SetBounds(P+Px(181),Px(94),ClientWidth-2*P-Px(181),Px(26));
  FList.SetBounds(P,Px(130),ClientWidth-2*P,ButtonY-Px(162));
  FCount.SetBounds(P,FList.Top+FList.Height+Gap,ClientWidth-2*P,Px(20));
  FRemove.SetBounds(P,ButtonY,Px(265),Px(30));
  FClose.SetBounds(ClientWidth-P-Px(110),ButtonY,Px(110),Px(30));
  FList.Columns[0].Width:=FList.ClientWidth-Px(350);
  FList.Columns[1].Width:=Px(140);
  FList.Columns[2].Width:=Px(65);
  FList.Columns[3].Width:=Px(55);
  FList.Columns[4].Width:=Px(70);
end;

procedure TfrmAuthorFavorites.Load(Store: TAuthorFavorites);
begin
  FStore:=Store; RefreshEntries; Rebuild(nil);
end;

procedure TfrmAuthorFavorites.RefreshEntries;
var Seen: TDictionary<string,Boolean>; Entries: TList<TAuthorFavoriteEntry>;
begin
  Entries:=TList<TAuthorFavoriteEntry>.Create; Seen:=TDictionary<string,Boolean>.Create;
  try
    for var Entry in FStore.Entries do begin Entries.Add(Entry); Seen.Add(Entry.Key,True); end;
    for var Personal in FStore.PersonalEntries do
      if not Seen.ContainsKey(Personal.Author.Key) then Entries.Add(Personal.Author);
    FEntries:=Entries.ToArray;
  finally Seen.Free; Entries.Free; end;
end;

procedure TfrmAuthorFavorites.Rebuild(Sender: TObject);
var Entry: TAuthorFavoriteEntry; Item: TListItem; I: Integer; Stamp, Needle: string;
  Personal: TAuthorPersonalEntry; Favorite: Boolean;
begin
  Needle:=Trim(FSearch.Text);
  FList.Items.BeginUpdate;
  try
    FList.Clear;
    for I:=0 to High(FEntries) do
    begin
      Entry:=FEntries[I];
      Personal:=FStore.PersonalEntry(Entry.LastName,Entry.FirstName,Entry.MiddleName);
      Favorite:=FStore.IsFavorite(Entry.LastName,Entry.FirstName,Entry.MiddleName);
      case FCategory.ItemIndex of
        0: if not Favorite then Continue;
        1: if not Personal.Hidden then Continue;
        2: if Personal.Rating=0 then Continue;
      end;
      if (Needle<>'') and not ContainsText(Entry.DisplayName,Needle) then Continue;
      Item:=FList.Items.Add; Item.Caption:=Entry.DisplayName;
      Item.Data:=Pointer(NativeInt(I+1));
      Stamp:=StringReplace(Entry.CreatedUTC,'T',' ',[]);
      if Stamp='' then Stamp:=StringReplace(Personal.UpdatedUTC,'T',' ',[]);
      if Stamp.EndsWith('Z') then Delete(Stamp,Length(Stamp),1);
      Item.SubItems.Add(Stamp);
      if Personal.Rating=0 then Item.SubItems.Add('—') else Item.SubItems.Add(IntToStr(Personal.Rating));
      if Personal.Hidden then Item.SubItems.Add('Да') else Item.SubItems.Add('');
      if Favorite then Item.SubItems.Add('Да') else Item.SubItems.Add('');
    end;
  finally FList.Items.EndUpdate; end;
  FCount.Caption:=Format('Показано: %d из %d',[FList.Items.Count,Length(FEntries)]);
  if Length(FEntries)=0 then FCount.Caption:='Личных настроек авторов пока нет.';
  FRemove.Enabled:=False; FRating.Enabled:=False; FHidden.Enabled:=False;
end;

procedure TfrmAuthorFavorites.Selected(Sender: TObject; Item: TListItem; IsSelected: Boolean);
var First, MixedRating, MixedHidden, Hidden: Boolean; Rating: Integer;
begin
  if FUpdating or not Assigned(FRemove) or not Assigned(FStore) then Exit;
  FRemove.Enabled:=False;
  First:=True; MixedRating:=False; MixedHidden:=False; Rating:=0; Hidden:=False;
  for var Row in FList.Items do
    if Row.Selected then
    begin
      var Entry:=FEntries[NativeInt(Row.Data)-1];
      FRemove.Enabled:=FRemove.Enabled or FStore.IsFavorite(Entry.LastName,Entry.FirstName,Entry.MiddleName);
      var Personal:=FStore.PersonalEntry(Entry.LastName,Entry.FirstName,Entry.MiddleName);
      if First then
      begin Rating:=Personal.Rating; Hidden:=Personal.Hidden; First:=False; end
      else
      begin
        MixedRating:=MixedRating or (Rating<>Personal.Rating);
        MixedHidden:=MixedHidden or (Hidden<>Personal.Hidden);
      end;
    end;
  FRating.Enabled:=not First; FHidden.Enabled:=FRating.Enabled;
  if not FRating.Enabled then Exit;
  FUpdating:=True;
  try
    if MixedRating then FRating.ItemIndex:=-1 else FRating.ItemIndex:=Rating;
    FHidden.AllowGrayed:=MixedHidden;
    if MixedHidden then FHidden.State:=cbGrayed else FHidden.Checked:=Hidden;
  finally FUpdating:=False; end;
end;

function TfrmAuthorFavorites.SelectedAuthors: TArray<TAuthorFavoriteEntry>;
var Entries: TList<TAuthorFavoriteEntry>;
begin
  Entries:=TList<TAuthorFavoriteEntry>.Create;
  try
    for var Row in FList.Items do
      if Row.Selected then Entries.Add(FEntries[NativeInt(Row.Data)-1]);
    Result:=Entries.ToArray;
  finally Entries.Free; end;
end;

procedure TfrmAuthorFavorites.PersonalChanged(Sender: TObject);
var Entries: TArray<TAuthorFavoriteEntry>;
begin
  if FUpdating or not Assigned(FStore) or (FList.SelCount=0) then Exit;
  if (Sender=FRating) and (FRating.ItemIndex<0) then Exit;
  if (Sender=FHidden) and (FHidden.State=cbGrayed) then Exit;
  Entries:=SelectedAuthors;
  try
    if Sender=FRating then FStore.SetPersonalRatings(Entries,FRating.ItemIndex)
    else FStore.SetHiddenAuthors(Entries,FHidden.Checked);
    FChanged:=True;
  except on E: Exception do MessageDlg(E.Message,mtError,[mbOK],0); end;
  RefreshEntries; Rebuild(nil);
  for var Row in FList.Items do
    for var Entry in Entries do
      if FEntries[NativeInt(Row.Data)-1].Key=Entry.Key then
      begin Row.Selected:=True; Break; end;
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
        if (Index>=0) and (Index<Length(FEntries)) and
          FStore.IsFavorite(FEntries[Index].LastName,FEntries[Index].FirstName,FEntries[Index].MiddleName) then
          Keys.Add(FEntries[Index].Key);
      end;
    if Keys.Count=0 then Exit;
    if MessageDlg(Format('Убрать выбранных авторов из любимых: %d?',[Keys.Count])+#13#10+
      'Книги и остальные любимые авторы сохранятся.',mtConfirmation,[mbYes,mbNo],0,mbNo)<>mrYes then Exit;
    try
      if FStore.RemoveFavorites(Keys.ToArray) then FChanged:=True;
      RefreshEntries; Rebuild(nil);
    except
      on E: Exception do MessageDlg('Не удалось изменить список любимых авторов.'+#13#10+E.Message,mtError,[mbOK],0);
    end;
  finally Keys.Free; end;
end;

end.
