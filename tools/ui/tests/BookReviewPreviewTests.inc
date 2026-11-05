procedure TestReviewPreviewHTTP(const Collection: IBookCollection; BookID: Integer);
const Initial = 'Прежний отзыв не терять';
var Panel: TInfoPanel; Tree: TBookTree; Toggle, Download: TButton;
  Memo: TMemo; Status: TLabel; Key: TBookKey; Data: PBookRecord;
  Original, Changed, Stored: TBookRecord; URL, Namespace, GoodText: string;
  Selected, Other: PVirtualNode; Started: UInt64;
  procedure Pump(Duration: Cardinal);
  var Since: UInt64;
  begin
    Since := GetTickCount64;
    repeat Application.ProcessMessages; CheckSynchronize(10); until GetTickCount64-Since>=Duration;
  end;
  procedure ConfigureID(const ID: string);
  begin
    Collection.GetBookRecord(Key,Changed,True); Changed.LibID := ID;
    Collection.UpdateBook(Changed);
    Data := Tree.GetNodeData(Selected); Data^ := Changed;
    Tree.FocusedNode := Selected;
    frmMain.tvBooksTreeChange(Tree, Selected);
    Require(not Panel.ReviewsVisible and Toggle.Visible, 'Book change did not reset review view');
    Toggle.Click;
    Require(Panel.ReviewsVisible and Download.Enabled, 'Review loading is unavailable in the lower panel');
  end;
  procedure WaitDone;
  var Since: UInt64;
  begin
    Since := GetTickCount64;
    while Download.Caption='Отменить' do
    begin Pump(10); Require(GetTickCount64-Since<12000,'Lower review request hung: '+Status.Caption); end;
  end;
  procedure StartDelayed;
  var Since: UInt64;
  begin
    System.SysUtils.DeleteFile(Settings.AppPath+'review-request-started.marker');
    ConfigureID('4'); Download.Click; Since := GetTickCount64;
    while not FileExists(Settings.AppPath+'review-request-started.marker') do
    begin Pump(10); Require(GetTickCount64-Since<5000,'Delayed review did not reach HTTP'); end;
  end;
  procedure Preserved(const Text: string);
  begin
    Require(Collection.GetReview(Key)=Text, 'Request changed the previous stored review');
    Require(Pos(Text.Trim,Memo.Text)>0, 'Request discarded the visible previous review');
    Collection.GetBookRecord(Key,Stored,True);
    Require(Stored.Annotation=Original.Annotation,'Review request replaced the book annotation');
  end;
begin
  RequireIsolatedRegression;
  Key := CreateBookKey(BookID, Collection.CollectionID);
  Collection.GetBookRecord(Key,Original,True);
  Collection.SetReview(Key,Initial);
  Collection.SetProperty(PROP_URL,'http://127.0.0.1:'+ParamStr(2)+'/');
  Namespace := VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
  Tree := frmMain.tvBooksA; Selected := Tree.FocusedNode;
  Require(Assigned(Selected),'Review preview fixture has no selected book');
  Panel := frmMain.ipnlAuthors;
  if not Settings.ShowInfoPanel then frmMain.ShowBookInfoPanelExecute(nil);
  frmMain.WindowState:=wsNormal; frmMain.SetBounds(0,0,900,650); frmMain.Show;
  Toggle := Panel.FindComponent('BookReviewsToggle') as TButton;
  Download := Panel.FindComponent('BookReviewDownload') as TButton;
  Memo := Panel.FindComponent('BookSavedReviews') as TMemo;
  Status := Panel.FindComponent('BookReviewStatus') as TLabel;
  ConfigureID('1'); URL := Collection.GetViewURL('1');
  Require(URL='http://127.0.0.1:'+ParamStr(2)+'/b/1/','Review fixture must stay on its loopback source');
  Require((Download.Caption='Обновить') and (Pos(Initial,Memo.Text)>0),'Saved reviews did not offer refresh');
  Download.Click; WaitDone;
  GoodText := Collection.GetReview(Key);
  Require((Pos('Источник: '+URL,GoodText)=1) and (Pos('Очень хорошая книга',GoodText)>0) and
    (Pos('Второй абзац.',GoodText)>0) and (Pos('Другой читатель:',GoodText)>0) and
    (Pos('сохранены',Status.Caption)>0),'Review download did not save formatted text with source');
  Preserved(GoodText);
  Download.Click; WaitDone;
  Require(Collection.GetReview(Key)=GoodText,'Refreshing duplicated the source or review body');
  Toggle.Click; Toggle.Click;
  Require(Pos(GoodText.Trim,Memo.Text)>0,'Returning to reviews lost the new saved text');
  ConfigureID('2'); Download.Click; WaitDone; Preserved(GoodText);
  Require(Pos('HTTP 503',Status.Caption)>0,'Lower panel hid HTTP failure');
  ConfigureID('3'); Download.Click; WaitDone; Preserved(GoodText);
  Require(Pos('Не удалось',Status.Caption)=1,'Lower panel hid blocked response');
  ConfigureID('5'); Download.Click; WaitDone; Preserved(GoodText);
  Require(Pos('нет отзывов',Status.Caption)>0,'Lower panel hid an empty response');
  Writeln('PASS lower review panel loads refreshes and preserves previous text on empty or failed responses'); Flush(Output);

  StartDelayed; Started:=GetTickCount64; Download.Click;
  Require(GetTickCount64-Started<200,'Lower panel cancel waited for HTTP');
  WaitDone; Preserved(GoodText);
  Require(Pos('отменена',Status.Caption)>0,'Lower panel cancel status missing');

  StartDelayed;
  Other := Tree.GetFirst;
  while Assigned(Other) and (Other=Selected) do Other:=Tree.GetNext(Other);
  Require(Assigned(Other),'Review fixture needs another selected book');
  Data:=Tree.GetNodeData(Other); Changed:=Data^;
  Tree.FocusedNode:=Other; frmMain.tvBooksTreeChange(Tree,Other);
  Require(not Panel.ReviewsVisible and not Download.Visible,'Switching book left the obsolete request visible');
  Pump(1300);
  Require(Collection.GetReview(Key)=GoodText,'Old response was saved after switching book');
  Require(Collection.GetReview(Changed.BookKey)='','Old response was written into another book');
  Toggle.Click;
  Require(Pos(GoodText.Trim,Memo.Text)=0,'Another book displayed the old response');

  StartDelayed;
  Collection.SetProperty(PROP_SOURCE_LIBRARY,'changed-source');
  WaitDone;
  Require(Collection.GetReview(Key)=GoodText,'Response wrote to a replaced collection source');
  Require(Pos('недоступна',Status.Caption)>0,'Changed source rejection was not explained');
  Collection.SetProperty(PROP_SOURCE_LIBRARY,Namespace);

  StartDelayed; Collection.SetReview(Key,'Отзыв изменён в другом окне');
  WaitDone;
  Require(Collection.GetReview(Key)='Отзыв изменён в другом окне','Response overwrote a concurrent review edit');
  Require(Pos('другом окне',Status.Caption)>0,'Concurrent edit rejection was not explained');
  Writeln('PASS lower review panel cancels and ignores obsolete book source and concurrent edits'); Flush(Output);
end;
