unit frm_CatalogNameMerge;

interface

uses
  System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, unit_Interfaces,
  unit_Globals, unit_SeriesAliases;

type
  TfrmCatalogNameMerge = class(TForm)
  private
    FCollection: IBookCollection;
    FKind: TCatalogNameKind;
    FIDs: TArray<Integer>;
    FAuthors: TBookAuthors;
    FSource, FTarget: TComboBox;
    FLast, FFirst, FMiddle: TEdit;
    FBooks: TMemo;
    FPrevious, FNext, FApply, FClose: TButton;
    FPageInfo: TLabel;
    FBackup: TCheckBox;
    FPage: Integer;
    FBusy: Boolean;
    procedure SourceChanged(Sender: TObject);
    procedure TargetChanged(Sender: TObject);
    procedure ChangePage(Sender: TObject);
    procedure LoadBooks;
    procedure Apply(Sender: TObject);
    procedure RunWorker(Worker: TSeriesAliasWorker; const Title: string);
    function GetTargetID: Integer;
  public
    constructor CreateFor(AOwner: TCustomForm; const Collection: IBookCollection;
      Kind: TCatalogNameKind; const IDs: TArray<Integer>);
    property TargetID: Integer read GetTargetID;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.Variants, System.Types, System.Math, Winapi.Windows,
  Vcl.Controls, Vcl.Dialogs, Vcl.FileCtrl, SQLiteWrap, unit_Settings, unit_Consts,
  dm_user, frm_ImportProgressFormEx;

const
  BooksPerPage = 100;
  BooksJoin: array[TCatalogNameKind] of string = (
    ' FROM Author_List r JOIN Books b ON b.BookID=r.BookID WHERE r.AuthorID=?',
    ' FROM Series_List r JOIN Books b ON b.BookID=r.BookID WHERE r.SeriesID=?');

constructor TfrmCatalogNameMerge.CreateFor(AOwner: TCustomForm; const Collection: IBookCollection;
  Kind: TCatalogNameKind; const IDs: TArray<Integer>);
var Header, Footer: TPanel; DB: TSQLiteDatabase; Q: TSQLiteQuery;
  Query, Display: string; Row: Integer;

  procedure AddLabel(Parent: TWinControl; const Text: string; X, Y: Integer; Field: TWinControl);
  var LabelControl: TLabel;
  begin
    LabelControl:=TLabel.Create(Self); LabelControl.Parent:=Parent;
    LabelControl.Caption:=Text; LabelControl.Left:=X; LabelControl.Top:=Y; LabelControl.FocusControl:=Field;
  end;

  function AddButton(const Text: string; X, Y, W: Integer; Click: TNotifyEvent): TButton;
  begin
    Result:=TButton.Create(Self); Result.Parent:=Footer;
    Result.SetBounds(X,Y,W,28); Result.Caption:=Text; Result.OnClick:=Click;
  end;

  function AddCombo(const Text: string; X, W: Integer): TComboBox;
  begin
    Result:=TComboBox.Create(Self); Result.Parent:=Header;
    Result.SetBounds(X,28,W,28); Result.Style:=csDropDownList;
    AddLabel(Header,Text,X,9,Result);
  end;

  function AddEdit(const Text: string; X, W, Limit: Integer): TEdit;
  begin
    Result:=TEdit.Create(Self); Result.Parent:=Header;
    Result.SetBounds(X,78,W,26); Result.MaxLength:=Limit;
    AddLabel(Header,Text,X,60,Result);
  end;

begin
  inherited CreateNew(AOwner);
  FCollection:=Collection;
  FKind:=Kind;
  FIDs:=Copy(IDs);
  if Length(FIDs)<2 then raise EArgumentException.Create('Выберите хотя бы две записи.');
  if Kind=cnAuthors then Caption:='Объединить выбранных авторов'
  else Caption:='Объединить выбранные серии';
  Position:=poOwnerFormCenter; PopupMode:=pmExplicit; PopupParent:=AOwner;
  BorderStyle:=bsSizeable; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=716; ClientHeight:=484;
  Constraints.MinWidth:=670; Constraints.MinHeight:=350;
  Header:=TPanel.Create(Self); Header.Parent:=Self; Header.Align:=alTop;
  Header.Height:=114; Header.BevelOuter:=bvNone;
  FSource:=AddCombo('Книги выбранной записи',12,332);
  FTarget:=AddCombo('Запись, которую оставляем',356,348);
  FTarget.Anchors:=[akLeft,akTop,akRight];
  if Kind=cnAuthors then
  begin
    FLast:=AddEdit('Фамилия / псевдоним',12,226,128);
    FFirst:=AddEdit('Имя',250,221,128);
    FMiddle:=AddEdit('Отчество',483,221,128);
    FMiddle.Anchors:=[akLeft,akTop,akRight];
  end
  else
  begin
    FLast:=AddEdit('Итоговое название серии',12,692,512);
    FLast.Anchors:=[akLeft,akTop,akRight];
  end;

  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom;
  Footer.Height:=82; Footer.BevelOuter:=bvNone;
  FPrevious:=AddButton('‹ Назад',12,6,94,ChangePage); FPrevious.Tag:=-1;
  FNext:=AddButton('Дальше ›',114,6,94,ChangePage); FNext.Tag:=1;
  FPageInfo:=TLabel.Create(Self); FPageInfo.Parent:=Footer;
  FPageInfo.SetBounds(220,12,485,18);
  FBackup:=TCheckBox.Create(Self); FBackup.Parent:=Footer;
  FBackup.SetBounds(12,48,342,19); FBackup.Caption:='Сохранить резервную копию и отчёт';
  FApply:=AddButton('Объединить…',466,43,129,Apply); FApply.Anchors:=[akTop,akRight];
  FClose:=AddButton('Отмена',606,43,98,nil); FClose.Anchors:=[akTop,akRight];
  FClose.Cancel:=True; FClose.ModalResult:=mrCancel;
  FBooks:=TMemo.Create(Self); FBooks.Parent:=Self; FBooks.Align:=alClient;
  FBooks.AlignWithMargins:=True; FBooks.Margins.SetBounds(12,0,12,0);
  FBooks.ReadOnly:=True; FBooks.ScrollBars:=ssVertical;
  FBooks.Hint:='Список книг выбранного автора или серии'; FBooks.ShowHint:=True;

  DB:=TSQLiteDatabase.CreateReadOnly(Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE))));
  try
    if Kind=cnAuthors then
    begin
      SetLength(FAuthors,Length(FIDs));
      Query:='SELECT LastName,FirstName,MiddleName FROM Authors WHERE AuthorID=?';
    end
    else Query:='SELECT SeriesTitle FROM Series WHERE SeriesID=?';
    for Row:=0 to High(FIDs) do
    begin
      Q:=DB.NewQuery(Query,[FIDs[Row]]);
      try
        Q.Open;
        if Q.Eof then raise EInvalidOperation.Create('Выбранная запись больше не существует.');
        if Kind=cnAuthors then
        begin
          FAuthors[Row].AuthorID:=FIDs[Row];
          FAuthors[Row].LastName:=Q.FieldAsString(0);
          FAuthors[Row].FirstName:=Q.FieldAsString(1);
          FAuthors[Row].MiddleName:=Q.FieldAsString(2);
          Display:=FAuthors[Row].GetFullName;
        end
        else Display:=Q.FieldAsString(0);
        FSource.Items.Add(Display); FTarget.Items.Add(Display);
      finally Q.Free; end;
    end;
  finally DB.Free; end;
  FSource.ItemIndex:=0; FTarget.ItemIndex:=0;
  FSource.OnChange:=SourceChanged; FTarget.OnChange:=TargetChanged;
  TargetChanged(nil);
  SourceChanged(nil);
  if AOwner<>nil then ScaleForPPI(AOwner.CurrentPPI);
end;

function TfrmCatalogNameMerge.GetTargetID: Integer;
begin
  Result:=FIDs[FTarget.ItemIndex];
end;

procedure TfrmCatalogNameMerge.TargetChanged(Sender: TObject);
var Author: TAuthorData;
begin
  if FTarget.ItemIndex<0 then Exit;
  if FKind=cnAuthors then
  begin
    Author:=FAuthors[FTarget.ItemIndex];
    FLast.Text:=Author.LastName; FFirst.Text:=Author.FirstName; FMiddle.Text:=Author.MiddleName;
  end
  else FLast.Text:=FTarget.Items[FTarget.ItemIndex];
end;

procedure TfrmCatalogNameMerge.SourceChanged(Sender: TObject);
begin
  FPage:=0;
  LoadBooks;
end;

procedure TfrmCatalogNameMerge.ChangePage(Sender: TObject);
begin
  Inc(FPage,TButton(Sender).Tag);
  LoadBooks;
end;

procedure TfrmCatalogNameMerge.LoadBooks;
var DB: TSQLiteDatabase; Q: TSQLiteQuery; ID, Count, Offset: Integer;
  Columns, Caption: string;
begin
  if FSource.ItemIndex<0 then Exit;
  ID:=FIDs[FSource.ItemIndex];
  DB:=TSQLiteDatabase.CreateReadOnly(Settings.ExpandCollectionFileName(
    VarToStr(FCollection.GetProperty(PROP_DATAFILE))));
  try
    Count:=DB.QuerySingleInt('SELECT COUNT(*)'+BooksJoin[FKind],[ID]);
    FPage:=Min(FPage,Max(0,Count-1) div BooksPerPage);
    Offset:=FPage*BooksPerPage;
    Columns:='b.Title,b.IsDeleted';
    if FKind=cnSeries then Columns:=Columns+',r.SeqNumber';
    Q:=DB.NewQuery('SELECT '+Columns+BooksJoin[FKind]+' ORDER BY r.BookID LIMIT ? OFFSET ?',
      [ID,BooksPerPage,Offset]);
    try
      Q.Open;
      FBooks.Lines.BeginUpdate;
      try
        FBooks.Clear;
        while not Q.Eof do
        begin
          Caption:=Q.FieldAsString(0);
          if (FKind=cnSeries) and (Q.FieldAsInt(2)<>0) then
            Caption:='№ '+Q.FieldAsString(2)+'  '+Caption;
          if Q.FieldAsInt(1)<>0 then Caption:=Caption+' [удалена]';
          FBooks.Lines.Add(Caption);
          Q.Next;
        end;
      finally FBooks.Lines.EndUpdate; end;
    finally Q.Free; end;
  finally DB.Free; end;
  FPrevious.Enabled:=FPage>0;
  FNext.Enabled:=Offset+BooksPerPage<Count;
  if Count=0 then FPageInfo.Caption:='В этой записи нет книг.'
  else FPageInfo.Caption:=Format('Книги %d–%d из %d',[Offset+1,Min(Offset+BooksPerPage,Count),Count]);
end;

procedure TfrmCatalogNameMerge.RunWorker(Worker: TSeriesAliasWorker; const Title: string);
var Progress: TImportProgressFormEx;
begin
  Progress:=TImportProgressFormEx.Create(Self);
  try
    Progress.Caption:=Title; Progress.WorkerThread:=Worker; Progress.CloseOnTimer:=True;
    Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self; Progress.Timer.Interval:=1;
    Progress.ShowModal;
    Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
  finally Progress.Free; end;
end;

procedure TfrmCatalogNameMerge.Apply(Sender: TObject);
var Plan: TSeriesAliasPlan; Worker: TSeriesAliasWorker; Author: TAuthorData;
  Confirmation, Folder, Backup: string;
begin
  if FBusy or (FTarget.ItemIndex<0) then Exit;
  FBusy:=True; FApply.Enabled:=False;
  try
    Author:=Default(TAuthorData);
    if FKind=cnAuthors then
    begin
      Author.LastName:=FLast.Text; Author.FirstName:=FFirst.Text; Author.MiddleName:=FMiddle.Text;
      Confirmation:='Объединить авторов под именем «'+Author.GetFullName+'»?';
    end
    else Confirmation:='Объединить серии под названием «'+Trim(FLast.Text)+'»?';
    Plan:=nil;
    try
      Worker:=TSeriesAliasWorker.CreateSelection(FCollection.CollectionID,FKind,FIDs,TargetID,Author,FLast.Text);
      try
        RunWorker(Worker,'Проверка выбранных записей');
        if not Worker.Success then
        begin MessageDlg(Worker.Error,mtWarning,[mbOK],0); Exit; end;
        Plan:=Worker.TakePlan;
      finally Worker.Free; end;
      if Plan.NumberConflicts>0 then Confirmation:=Confirmation+sLineBreak+sLineBreak+Plan.Report[0];
      if MessageDlg(Confirmation,mtConfirmation,[mbYes,mbNo],0,mbNo)<>mrYes then Exit;
      Backup:='';
      if FBackup.Checked then
      begin
        Folder:=TPath.Combine(Settings.DataPath,'Backups');
        if not ForceDirectories(Folder) then Folder:=Settings.DataPath;
        if not SelectDirectory('Куда сохранить резервную копию','',Folder,[sdNewUI,sdShowEdit]) then Exit;
        Backup:=TPath.Combine(Folder,'catalog-names-'+TGUID.NewGuid.ToString);
      end;
      Worker:=TSeriesAliasWorker.CreateApply(Plan,Backup);
      try
        RunWorker(Worker,'Объединение записей');
        if Worker.Success then ModalResult:=mrOk
        else MessageDlg(Worker.Error,mtWarning,[mbOK],0);
      finally Worker.Free; end;
    finally Plan.Free; end;
  finally FBusy:=False; FApply.Enabled:=True; end;
end;

end.
