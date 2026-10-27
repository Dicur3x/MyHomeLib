// The Main callback must not prepare an already prepared small FB2 forever.
procedure TestMainSmallFB2Opening;
var Collection: IBookCollection; Book: TBookRecord; CID, BID: Integer;
  Source, Hash, Body, ReaderSection: string; Menu: TMenuItem;
  Driver: TRMFMainReaderDriver; Languages: TComboBox; Action: TAction;
  Ini: TMemIniFile; Node: PVirtualNode; Preparations, BusyPreviews, Readers: Integer;
  OldBuiltin: Boolean;
begin
  CID:=SystemDB.CreateCollection('Small FB2 reader',Settings.AppPath,'small-reader.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID);
  BID:=AddBook(Collection,'small-original','Reader','ru','','prose_contemporary');
  Collection.GetBookRecord(CreateBookKey(BID,CID),Book,True);
  Source:=Book.GetBookFileName;
  Body:='';
  for var I:=1 to 320 do Body:=Body+'<p>Небольшая исходная FB2, абзац '+IntToStr(I)+
    ': обычное чтение и повторное открытие должны сохранять весь текст книги.</p>';
  TFile.WriteAllText(Source,'<?xml version="1.0" encoding="utf-8"?>'+
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
    '<description><title-info><book-title>Small FB2</book-title><lang>ru</lang></title-info></description>'+
    '<body><section>'+Body+'</section></body></FictionBook>',TEncoding.UTF8);
  Require(TFile.GetSize(Source)<1024*1024,'Small FB2 fixture unexpectedly needs isolated conversion');
  Hash:=THashSHA2.GetHashStringFromFile(Source);
  Trace('small reader before direct preparation');
  // The unchanged extension is intentional, not an unfinished conversion.
  Require(PrepareReaderFile(Book,True,nil,False,True,True)=Source,'Ordinary FB2 left the native direct path');
  Trace('small reader after direct preparation');
  Menu:=TMenuItem.Create(nil);
  try Menu.Tag:=CID; frmMain.miActiveCollectionClick(Menu); finally Menu.Free; end;
  Trace('small reader collection active');
  Languages:=TComboBox.Create(nil); Driver:=TRMFMainReaderDriver.Create;
  OldBuiltin:=Settings.UseBuiltinReaderByDefault;
  try
    Settings.UseBuiltinReaderByDefault:=True;
    Languages.Parent:=frmMain; Languages.Visible:=False; Languages.Items.Add('-'); Languages.ItemIndex:=0;
    frmMain.pgControl.ActivePage:=frmMain.tsSearch; frmMain.pgControlChange(nil);
    Trace('small reader before tree fill');
    frmMain.FillBooksTree(frmMain.tvBooksSR,Languages,Collection.GetBookIterator(bmAll,False),True,True,nil);
    Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      var Data:=PBookRecord(frmMain.tvBooksSR.GetNodeData(Node));
      if Assigned(Data) and (Data.NodeType=ntBookInfo) then Break;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(Assigned(Node),'Small FB2 actual Main book row missing');
    frmMain.tvBooksSR.ClearSelection; frmMain.tvBooksSR.Selected[Node]:=True;
    frmMain.tvBooksSR.FocusedNode:=Node; frmMain.Show;
    Trace('small reader tree ready');
    ReaderSection:='Book.'+Copy(THashSHA2.GetHashString(ReaderHistoryName(Book,
      VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)))),1,40);
    for var Trial:=0 to 1 do
    begin
      Ini:=TMemIniFile.Create(ResolveReaderSettingsFile(Settings.DataDir),TEncoding.UTF8);
      try Ini.WriteInteger(ReaderSection,'Position',0); Ini.UpdateFile; finally Ini.Free; end;
      if Trial=0 then Action:=TAction(frmMain.FindComponent('acReadBuiltin'))
      else Action:=frmMain.acBookRead;
      Require(Assigned(Action),'Small FB2 actual Main read action missing');
      Action.Update; Require(Action.Enabled,'Small FB2 actual Main read action disabled');
      Trace('small reader before action');
      Driver.BeginRead(Book.Title); Require(Action.Execute,'Small FB2 actual Main read action did not execute');
      while not Driver.Finished and (GetTickCount64-Driver.Started<20000) do
      begin Application.ProcessMessages; CheckSynchronize(5); Sleep(2); end;
      Require(Driver.Finished and (Driver.Failure=''),'Small FB2 preparation loop or reader failure: '+Driver.Failure);
      Require((Driver.PageIndex=5) and (Driver.OpenMS>=0),'Small FB2 did not open and turn actual native pages');
      RMFTaskCounts(Preparations,BusyPreviews,Readers);
      Require((Preparations=0) and (Readers=0),'Small FB2 reader/preparation survived its close');
      Require(THashSHA2.GetHashStringFromFile(Source)=Hash,'Small FB2 source was rewritten');
      Trace('small reader before progress lookup');
      var SavedBook: TBookRecord;
      Collection.GetBookRecord(Book.BookKey,SavedBook,True);
      Require(SavedBook.Progress>0,'Independent reader did not return its progress to the catalogue');
    end;
    Writeln('PASS actual Main small unchanged FB2 opens and pages through explicit builtin and default reader actions without repeated preparation');
  finally
    Driver.Timer.Enabled:=False; CancelReaderPreparations(frmMain);
    Settings.UseBuiltinReaderByDefault:=OldBuiltin;
    Driver.Free; Languages.Free; Collection:=nil; frmMain.Hide;
  end;
end;
